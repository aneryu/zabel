const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");
const ast_ops = @import("ast_ops.zig");
const scope_mod = @import("../scope.zig");

/// Configuration for the arrow-functions transform.
pub const Config = struct {
    /// When true, use spec mode: wrap with `.bind(this)` and insert `babelHelpers.newArrowCheck`.
    spec: bool = false,
    /// When false, assume arrows are not newable — use `.bind(this)`.
    /// Default true means we assume arrows are NOT used with new.
    no_new_arrows: bool = true,
    /// When true, preserve inferred function names for bound arrows.
    function_name: bool = false,
};

var g_config: Config = .{};

/// Global counter for unique `_this` / `_arguments` name generation.
/// Babel uses file-wide incrementing counters: _this, _this2, _this3, ...
var g_this_counter: u32 = 0;
var g_arguments_counter: u32 = 0;
const arrow_binding_name_none = std.math.maxInt(u32);

/// Track which enclosing function bodies already have prefixes,
/// to avoid duplicating `var _this = this;` for multiple arrows in the same function.
var g_body_this_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
var g_body_arguments_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
var g_arrow_binding_name_ast: ?*Ast = null;
var g_arrow_binding_name_nodes: []u32 = &[_]u32{};
var g_arguments_replacement_ast: ?*Ast = null;
var g_has_literal_arguments_replacements = false;

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.arrow_function_expr));
    return .{
        .name = "arrow_functions",
        .node_filter = filter,
        .exit = exitNode,
        .priority = 20,
    };
}

pub fn resetState() void {
    g_this_counter = 0;
    g_arguments_counter = 0;
    g_body_this_names = .{};
    g_body_arguments_names = .{};
    g_arrow_binding_name_ast = null;
    g_arrow_binding_name_nodes = &[_]u32{};
    g_arguments_replacement_ast = null;
    g_has_literal_arguments_replacements = false;
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    if (tag == .arrow_function_expr) {
        handleArrowFunction(idx, ctx);
    }
    return .continue_traversal;
}

// ── Source range ────────────────────────────────────────────────────

const SourceRange = struct {
    start: u32,
    end: u32,
};

// ── Main handler ────────────────────────────────────────────────────

fn handleArrowFunction(idx: NodeIndex, ctx: *TransformContext) void {
    const i = @intFromEnum(idx);
    const data = ctx.nodeData(idx);

    // Check if async
    const mt = ctx.mainToken(idx);
    const mt_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(mt)];
    const is_async = (mt_tag == .kw_async) or ctx.ast.async_arrow_flags.contains(i);

    // Parse the arrow's extra data to get params and body
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const first = ctx.ast.extra_data.items[extra_idx];
    const second = ctx.ast.extra_data.items[extra_idx + 1];
    const third = ctx.ast.extra_data.items[extra_idx + 2];

    var body_node: NodeIndex = undefined;
    var params_start: u32 = 0;
    var params_end: u32 = 0;
    var is_old_format = false;
    var single_param: NodeIndex = .none;

    if (first == @intFromEnum(NodeIndex.none) or third == 1) {
        // Old format: param, body, count
        is_old_format = true;
        single_param = @enumFromInt(first);
        body_node = @enumFromInt(second);
    } else {
        // New format: range_start, range_end, body
        params_start = first;
        params_end = second;
        body_node = @enumFromInt(third);
    }

    if (body_node == .none) return;

    const body_tag = ctx.nodeTag(body_node);
    const is_expression_body = body_tag != .block_statement;
    const enclosing = findEnclosingFunction(ctx, idx);
    const body_may_reference_this = bodyMayReferenceThis(ctx, body_node);
    const body_may_reference_arguments = bodyMayReferenceArguments(ctx, body_node);

    var binding_name_node: NodeIndex = .none;
    var self_ref_name_node: NodeIndex = .none;
    if (getArrowBindingNameNode(ctx, idx)) |name_node| {
        binding_name_node = name_node;
        const binding_idx = ctx.getBindingIndexForNode(name_node);
        if (binding_idx) |target_binding_idx| {
            const original_name = ctx.tokenSlice(ctx.mainToken(name_node));
            if (hasDirectBindingReferenceInArrowBody(ctx, body_node, target_binding_idx)) {
                const emitted_name = (ctx.generateUniqueName(name_node, original_name) catch null) orelse
                    (std.fmt.allocPrint(ctx.allocator, "_{s}", .{original_name}) catch original_name);
                const rename_root = enclosing orelse @as(NodeIndex, @enumFromInt(0));
                renameResolvedBindingInSubtree(ctx, rename_root, target_binding_idx, emitted_name);
                self_ref_name_node = name_node;
            }
        }
    }

    // Scan the body subtree for `this` and `arguments` references
    var this_positions: std.ArrayListUnmanaged(SourceRange) = .empty;
    var arguments_positions: std.ArrayListUnmanaged(SourceRange) = .empty;
    var local_arguments_decl_positions: std.ArrayListUnmanaged(SourceRange) = .empty;
    var local_arguments_positions: std.ArrayListUnmanaged(SourceRange) = .empty;
    var lexical_arguments_bindings: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var has_this = false;
    var has_arguments = false;
    var has_local_arguments = false;

    var local_arguments_bindings: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer local_arguments_bindings.deinit(ctx.allocator);
    defer lexical_arguments_bindings.deinit(ctx.allocator);
    if (body_may_reference_arguments) {
        collectLocalArgumentsBindings(ctx, body_node, &local_arguments_bindings);
    }

    if (body_may_reference_this or body_may_reference_arguments) {
        scanReferences(
            ctx,
            idx,
            body_node,
            &local_arguments_bindings,
            &lexical_arguments_bindings,
            &this_positions,
            &arguments_positions,
            &local_arguments_decl_positions,
            &local_arguments_positions,
            &has_this,
            &has_arguments,
            &has_local_arguments,
        );
    }

    if (ctx.scope) |scope_result| {
        var lexical_iter = lexical_arguments_bindings.keyIterator();
        while (lexical_iter.next()) |binding_ptr| {
            g_arguments_counter += 1;
            const renamed = if (g_arguments_counter == 1) "_arguments" else allocArgumentsName(ctx, g_arguments_counter);
            const binding = scope_result.bindings[binding_ptr.*];
            const rename_root = scope_result.scopes[@intFromEnum(binding.scope)].node;
            renameResolvedBindingInSubtree(ctx, rename_root, binding_ptr.*, renamed);
        }
    }

    // In spec mode, always bind this (for newArrowCheck)
    if (useSpecMode()) {
        has_this = true;
    }

    // Generate unique names for _this and _arguments using file-wide counter
    var this_name: []const u8 = "_this";
    var arguments_name: []const u8 = "_arguments";

    if (has_this) {
        this_name = ensureThisCaptureName(ctx, enclosing);
    }
    if (has_arguments) {
        // Check if the enclosing function body already has a _arguments binding
        if (enclosing) |enc| {
            if (g_body_arguments_names.get(@intFromEnum(enc))) |existing| {
                arguments_name = existing;
            } else {
                g_arguments_counter += 1;
                arguments_name = if (g_arguments_counter == 1) "_arguments" else allocArgumentsName(ctx, g_arguments_counter);
                g_body_arguments_names.put(ctx.allocator, @intFromEnum(enc), arguments_name) catch {};
            }
        } else {
            g_arguments_counter += 1;
            arguments_name = if (g_arguments_counter == 1) "_arguments" else allocArgumentsName(ctx, g_arguments_counter);
        }
    } else if (has_local_arguments) {
        g_arguments_counter += 1;
        arguments_name = if (g_arguments_counter == 1) "_arguments" else allocArgumentsName(ctx, g_arguments_counter);
    }

    // For spec mode: use replacement_source approach (handles .bind(this) and newArrowCheck)
    if (useSpecMode()) {
        // In spec mode, `this` in the body stays as `this` because .bind(this) handles binding.
        // Only `arguments` references need replacement in the body.
        // Do NOT replace this_expr nodes — only newArrowCheck uses _this.
        for (arguments_positions.items) |pos| {
            setReplacementAtPosition(ctx, body_node, pos.start, .identifier, arguments_name);
        }
        for (local_arguments_positions.items) |pos| {
            setReplacementAtPosition(ctx, body_node, pos.start, .identifier, arguments_name);
        }
        if (has_local_arguments) {
            for (local_arguments_decl_positions.items) |pos| {
                setReplacementAtPosition(ctx, body_node, pos.start, .identifier, arguments_name);
            }
        }
        buildSpecReplacement(idx, ctx, is_async, is_old_format, single_param, params_start, params_end, body_node, is_expression_body, has_this, this_name);
        // Set prefix for spec mode too (var _this = this;)
        if ((has_this or has_arguments) and enclosing != null) {
            setEnclosingPrefix(ctx, enclosing.?, has_this, has_arguments, this_name, arguments_name);
        }
        return;
    }

    // Non-spec mode: transform the arrow AST node into a function_expr
    // Set replacement_source on individual this_expr and arguments identifier nodes
    for (this_positions.items) |pos| {
        setReplacementAtPosition(ctx, body_node, pos.start, .this_expr, this_name);
    }
    for (arguments_positions.items) |pos| {
        setReplacementAtPosition(ctx, body_node, pos.start, .identifier, arguments_name);
    }
    for (local_arguments_positions.items) |pos| {
        setReplacementAtPosition(ctx, body_node, pos.start, .identifier, arguments_name);
    }
    if (has_local_arguments) {
        for (local_arguments_decl_positions.items) |pos| {
            setReplacementAtPosition(ctx, body_node, pos.start, .identifier, arguments_name);
        }
    }

    if (!has_this and is_expression_body) {
        const body_i = @intFromEnum(body_node);
        if (ctx.ast.replacement_source.get(body_i)) |body_replacement| {
            if (containsBareIdentifierOutsideLiterals(body_replacement, "this")) {
                has_this = true;
                this_name = ensureThisCaptureName(ctx, enclosing);
                const updated = replaceBareIdentifierOutsideLiterals(ctx, body_replacement, "this", this_name);
                ctx.putReplacementSource(@enumFromInt(body_i), updated) catch {};
            }
        }
    }

    // Transform the arrow into a function_expr in the AST
    var final_body = body_node;
    if (is_expression_body) {
        final_body = wrapExpressionBody(ctx, body_node) orelse return;
        if (ctx.ast.block_prefix_source.get(i)) |prefix| {
            const final_body_i = @intFromEnum(final_body);
            if (ctx.ast.block_prefix_source.get(final_body_i)) |existing| {
                const combined = std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ prefix, existing }) catch existing;
                ctx.ast.block_prefix_source.put(ctx.allocator, final_body_i, combined) catch {};
            } else {
                ctx.ast.block_prefix_source.put(ctx.allocator, final_body_i, prefix) catch {};
            }
        }
    }

    // Build new extra_data for function_expr:
    // [name_token=0, params_start, params_end, body, flags]
    const func_flags: u32 = if (is_async) 2 else 0;

    if (is_old_format) {
        const function_name_token: u32 = if (self_ref_name_node != .none)
            @intFromEnum(ctx.mainToken(self_ref_name_node))
        else if (g_config.function_name and binding_name_node != .none)
            @intFromEnum(ctx.mainToken(binding_name_node))
        else
            0;
        if (single_param != .none) {
            const new_params_start = ctx.addExtra(@intFromEnum(single_param)) catch return;
            const new_extra_start = ctx.addExtra(function_name_token) catch return;
            _ = ctx.addExtra(new_params_start) catch return;
            _ = ctx.addExtra(new_params_start + 1) catch return;
            _ = ctx.addExtra(@intFromEnum(final_body)) catch return;
            _ = ctx.addExtra(func_flags) catch return;

            ctx.ast.nodes.items(.tag)[i] = .function_expr;
            ctx.ast.nodes.items(.data)[i] = .{ .extra = @enumFromInt(new_extra_start) };
        } else {
            const new_extra_start = ctx.addExtra(function_name_token) catch return;
            _ = ctx.addExtra(0) catch return;
            _ = ctx.addExtra(0) catch return;
            _ = ctx.addExtra(@intFromEnum(final_body)) catch return;
            _ = ctx.addExtra(func_flags) catch return;

            ctx.ast.nodes.items(.tag)[i] = .function_expr;
            ctx.ast.nodes.items(.data)[i] = .{ .extra = @enumFromInt(new_extra_start) };
        }
    } else {
        const function_name_token: u32 = if (self_ref_name_node != .none)
            @intFromEnum(ctx.mainToken(self_ref_name_node))
        else if (g_config.function_name and binding_name_node != .none)
            @intFromEnum(ctx.mainToken(binding_name_node))
        else
            0;
        const new_extra_start = ctx.addExtra(function_name_token) catch return;
        _ = ctx.addExtra(params_start) catch return;
        _ = ctx.addExtra(params_end) catch return;
        _ = ctx.addExtra(@intFromEnum(final_body)) catch return;
        _ = ctx.addExtra(func_flags) catch return;

        ctx.ast.nodes.items(.tag)[i] = .function_expr;
        ctx.ast.nodes.items(.data)[i] = .{ .extra = @enumFromInt(new_extra_start) };
    }

    // Set block_prefix_source on enclosing function body for _this/_arguments bindings
    var needs_arguments_prefix = has_arguments;
    if (needs_arguments_prefix and enclosing != null) {
        // Check if the enclosing scope already has `var arguments = X` — if so, rename it
        if (renameEnclosingScopeArguments(ctx, enclosing.?, arguments_name)) {
            needs_arguments_prefix = false;
        }
    }
    const needs_derived_this_capture = has_this and enclosing != null and isDerivedConstructorBody(ctx, enclosing.?);
    if (needs_derived_this_capture) {
        setDerivedThisPrefix(ctx, enclosing.?, this_name);
        patchDerivedConstructorSuperCaptures(ctx, enclosing.?, this_name);
    }
    if (((has_this and !needs_derived_this_capture) or needs_arguments_prefix) and enclosing != null) {
        setEnclosingPrefix(ctx, enclosing.?, has_this and !needs_derived_this_capture, needs_arguments_prefix, this_name, arguments_name);
    }
}

// ── Wrap expression body in block + return ──────────────────────────

fn wrapExpressionBody(ctx: *TransformContext, expr_node: NodeIndex) ?NodeIndex {
    // Create return_statement: tag=.return_statement, data.unary=expr_node
    const return_node = ctx.addNewNode(.{
        .tag = .return_statement,
        .main_token = ctx.mainToken(expr_node), // Reuse token
        .data = .{ .unary = expr_node },
    }) catch return null;

    // Set end_offset for return_statement
    const ni = @intFromEnum(return_node);
    if (ni < ctx.ast.nodes.items(.end_offset).len) {
        ctx.ast.nodes.items(.end_offset)[ni] = ctx.ast.nodes.items(.end_offset)[@intFromEnum(expr_node)];
    }

    // Create block_statement: tag=.block_statement, data.extra=[range_start, range_end]
    const range_start = ctx.addExtra(@intFromEnum(return_node)) catch return null;
    const block_extra_start = ctx.addExtra(range_start) catch return null;
    _ = ctx.addExtra(range_start + 1) catch return null; // range_end

    const block_node = ctx.addNewNode(.{
        .tag = .block_statement,
        .main_token = ctx.mainToken(expr_node), // Reuse token
        .data = .{ .extra = @enumFromInt(block_extra_start) },
    }) catch return null;

    // Set end_offset for block_statement
    const bni = @intFromEnum(block_node);
    if (bni < ctx.ast.nodes.items(.end_offset).len) {
        ctx.ast.nodes.items(.end_offset)[bni] = ctx.ast.nodes.items(.end_offset)[@intFromEnum(expr_node)];
    }

    return block_node;
}

// ── Set replacement on individual nodes ─────────────────────────────

fn setReplacementAtPosition(ctx: *TransformContext, _: NodeIndex, abs_pos: u32, expected_tag: Node.Tag, replacement: []const u8) void {
    // Find the node at the given absolute source position
    const tags = ctx.ast.nodes.items(.tag);
    const main_tokens = ctx.ast.nodes.items(.main_token);
    const token_starts = ctx.ast.tokens.items(.start);

    for (tags, 0..) |tag, ni| {
        if (tag != expected_tag) continue;
        const tok_start = token_starts[@intFromEnum(main_tokens[ni])];
        if (tok_start == abs_pos) {
            ctx.putReplacementSource(@enumFromInt(ni), replacement) catch {};
            return;
        }
    }
}

// ── Spec mode replacement builder ───────────────────────────────────

fn buildSpecReplacement(
    idx: NodeIndex,
    ctx: *TransformContext,
    is_async: bool,
    is_old_format: bool,
    single_param: NodeIndex,
    params_start: u32,
    params_end: u32,
    body_node: NodeIndex,
    is_expression_body: bool,
    has_this: bool,
    this_name: []const u8,
) void {
    // Get params source
    var params_source: []const u8 = "";
    if (is_old_format) {
        if (single_param != .none) {
            params_source = getNodeSourceRaw(ctx, single_param);
        }
    } else {
        if (params_start < params_end and params_end <= ctx.ast.extra_data.items.len) {
            const first_param: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[params_start]);
            const last_param: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[params_end - 1]);
            const ps = getNodeStart(ctx, first_param);
            const pe = ctx.ast.nodes.items(.end_offset)[@intFromEnum(last_param)];
            if (ps < pe and pe <= ctx.ast.source.len) {
                params_source = ctx.ast.source[ps..pe];
            }
        }
    }

    // Get body source with inner replacements
    const body_start = getNodeStart(ctx, body_node);
    const body_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(body_node)];
    if (body_start >= body_end or body_end > ctx.ast.source.len) return;
    const raw_body = ctx.ast.source[body_start..body_end];

    // Build substituted body (apply inner replacement_source entries + this/arguments)
    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    buildSubstitutedBody(&body_buf, ctx, raw_body, body_start, body_end);
    const substituted_body = body_buf.items;

    // Don't use source-based indent — writeReplacementIndented handles base indentation
    const indent: []const u8 = "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (is_async) buf.appendSlice(ctx.allocator, "async ") catch return;
    buf.appendSlice(ctx.allocator, "function") catch return;

    if (getArrowName(ctx, idx)) |name| {
        buf.append(ctx.allocator, ' ') catch return;
        buf.appendSlice(ctx.allocator, name) catch return;
        buf.appendSlice(ctx.allocator, "(") catch return;
    } else {
        // Anonymous: Babel adds space before (
        buf.appendSlice(ctx.allocator, " (") catch return;
    }
    buf.appendSlice(ctx.allocator, params_source) catch return;
    buf.appendSlice(ctx.allocator, ")") catch return;

    if (is_expression_body) {
        buf.appendSlice(ctx.allocator, " {\n") catch return;
        if (has_this) {
            buf.appendSlice(ctx.allocator, indent) catch return;
            buf.appendSlice(ctx.allocator, "  babelHelpers.newArrowCheck(this, ") catch return;
            buf.appendSlice(ctx.allocator, this_name) catch return;
            buf.appendSlice(ctx.allocator, ");\n") catch return;
        }
        buf.appendSlice(ctx.allocator, indent) catch return;
        buf.appendSlice(ctx.allocator, "  return ") catch return;
        buf.appendSlice(ctx.allocator, substituted_body) catch return;
        buf.appendSlice(ctx.allocator, ";\n") catch return;
        buf.appendSlice(ctx.allocator, indent) catch return;
        buf.appendSlice(ctx.allocator, "}") catch return;
    } else {
        buf.appendSlice(ctx.allocator, " ") catch return;
        if (has_this) {
            // Insert newArrowCheck after opening '{'
            if (substituted_body.len > 0 and substituted_body[0] == '{') {
                buf.appendSlice(ctx.allocator, "{\n") catch return;
                buf.appendSlice(ctx.allocator, indent) catch return;
                buf.appendSlice(ctx.allocator, "  babelHelpers.newArrowCheck(this, ") catch return;
                buf.appendSlice(ctx.allocator, this_name) catch return;
                buf.appendSlice(ctx.allocator, ");\n") catch return;
                // Re-indent the body content
                reindentBody(&buf, ctx, substituted_body[1..], indent);
            } else {
                buf.appendSlice(ctx.allocator, substituted_body) catch return;
            }
        } else {
            buf.appendSlice(ctx.allocator, substituted_body) catch return;
        }
    }

    buf.appendSlice(ctx.allocator, ".bind(this)") catch return;

    ctx.putReplacementSource(idx, buf.items) catch return;
    ctx.markReplacementNeedsReindent(idx) catch {};
}

fn buildSubstitutedBody(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, raw_body: []const u8, body_start: u32, body_end: u32) void {
    // Collect all replacement_source entries within the body range
    const Substitution = struct {
        abs_start: u32,
        abs_end: u32,
        replacement: []const u8,
    };

    var subs: std.ArrayListUnmanaged(Substitution) = .empty;
    defer subs.deinit(ctx.allocator);

    const ordered = ctx.orderedReplacements() catch {
        buf.appendSlice(ctx.allocator, raw_body) catch {};
        return;
    };
    const replacement_start = ctx.replacementLowerBound(body_start) catch {
        buf.appendSlice(ctx.allocator, raw_body) catch {};
        return;
    };

    for (ordered[replacement_start..]) |entry| {
        if (entry.start >= body_end) break;
        const ni = entry.node_index;
        if (ni >= ctx.ast.nodes.items(.tag).len) continue;
        const n_start = getNodeStart(ctx, @enumFromInt(ni));
        const n_end = entry.end;
        if (n_start >= body_start and n_end <= body_end) {
            subs.append(ctx.allocator, .{
                .abs_start = n_start,
                .abs_end = n_end,
                .replacement = entry.text,
            }) catch {};
        }
    }

    if (subs.items.len == 0) {
        buf.appendSlice(ctx.allocator, raw_body) catch {};
        return;
    }

    std.mem.sort(Substitution, subs.items, {}, struct {
        fn lt(_: void, a: Substitution, b: Substitution) bool {
            return a.abs_start < b.abs_start;
        }
    }.lt);

    var cursor: u32 = body_start;
    for (subs.items) |sub| {
        if (sub.abs_start < cursor) continue;
        if (sub.abs_start > cursor) {
            const rs = cursor - body_start;
            const re = sub.abs_start - body_start;
            if (re <= raw_body.len) buf.appendSlice(ctx.allocator, raw_body[rs..re]) catch {};
        }
        buf.appendSlice(ctx.allocator, sub.replacement) catch {};
        cursor = sub.abs_end;
    }
    if (cursor >= body_start) {
        const rs = cursor - body_start;
        if (rs < raw_body.len) buf.appendSlice(ctx.allocator, raw_body[rs..]) catch {};
    }
}

// ── Spec mode check ─────────────────────────────────────────────────

fn useSpecMode() bool {
    return !g_config.no_new_arrows;
}

fn ensureThisCaptureName(ctx: *TransformContext, enclosing: ?NodeIndex) []const u8 {
    if (enclosing) |enc| {
        if (g_body_this_names.get(@intFromEnum(enc))) |existing| {
            return existing;
        }
        g_this_counter += 1;
        const name = if (g_this_counter == 1) "_this" else allocThisName(ctx, g_this_counter);
        g_body_this_names.put(ctx.allocator, @intFromEnum(enc), name) catch {};
        return name;
    }
    g_this_counter += 1;
    return if (g_this_counter == 1) "_this" else allocThisName(ctx, g_this_counter);
}

fn containsBareIdentifierOutsideLiterals(src: []const u8, ident: []const u8) bool {
    return findBareIdentifierOutsideLiterals(src, ident, 0) != null;
}

fn replaceBareIdentifierOutsideLiterals(ctx: *TransformContext, src: []const u8, ident: []const u8, replacement: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var cursor: usize = 0;
    while (findBareIdentifierOutsideLiterals(src, ident, cursor)) |pos| {
        buf.appendSlice(ctx.allocator, src[cursor..pos]) catch return src;
        buf.appendSlice(ctx.allocator, replacement) catch return src;
        cursor = pos + ident.len;
    }
    if (cursor == 0) return src;
    buf.appendSlice(ctx.allocator, src[cursor..]) catch return src;
    return buf.items;
}

fn findBareIdentifierOutsideLiterals(src: []const u8, ident: []const u8, start_at: usize) ?usize {
    if (ident.len == 0 or start_at >= src.len) return null;

    var i = start_at;
    var in_quote: ?u8 = null;
    var escaped = false;
    var template_depth: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (in_quote) |quote| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (quote == '`' and c == '$' and i + 1 < src.len and src[i + 1] == '{') {
                template_depth += 1;
                i += 1;
            } else if (quote == '`' and c == '}' and template_depth > 0) {
                template_depth -= 1;
            } else if (template_depth == 0 and c == quote) {
                in_quote = null;
            }
            i += 1;
            continue;
        }

        if (c == '\'' or c == '"' or c == '`') {
            in_quote = c;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                i += 2;
                while (i < src.len and src[i] != '\n') : (i += 1) {}
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
                if (i + 1 < src.len) i += 2;
                continue;
            }
        }
        if (i + ident.len <= src.len and std.mem.eql(u8, src[i .. i + ident.len], ident)) {
            const before_ok = i == 0 or !isIdentifierChar(src[i - 1]);
            const after_ok = i + ident.len == src.len or !isIdentifierChar(src[i + ident.len]);
            if (before_ok and after_ok) return i;
        }
        i += 1;
    }

    return null;
}

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

// ── Local arguments declaration check ───────────────────────────────

/// Check if the arrow body directly declares `var/let/const arguments = ...`.
fn hasLocalArgumentsDecl(ctx: *TransformContext, body_node: NodeIndex) bool {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    // For block_statement body, check direct children (statements)
    const body_tag = tags[@intFromEnum(body_node)];
    if (body_tag != .block_statement) return false;

    const body_data = datas[@intFromEnum(body_node)];
    const extra_idx = @intFromEnum(body_data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (stmt_raw >= tags.len) continue;
        const stmt_tag = tags[stmt_raw];
        if (stmt_tag != .var_declaration and stmt_tag != .let_declaration and stmt_tag != .const_declaration) continue;

        // Check declarators for `arguments` name
        const stmt_data = datas[stmt_raw];
        const decl_extra = @intFromEnum(stmt_data.extra);
        if (decl_extra + 1 >= ctx.ast.extra_data.items.len) continue;
        const decl_start = ctx.ast.extra_data.items[decl_extra];
        const decl_end = ctx.ast.extra_data.items[decl_extra + 1];

        for (ctx.ast.extra_data.items[decl_start..decl_end]) |decl_raw| {
            if (decl_raw >= tags.len) continue;
            if (tags[decl_raw] != .declarator) continue;
            const decl_data = datas[decl_raw];
            const name_node = decl_data.binary.lhs;
            if (name_node == .none) continue;
            if (tags[@intFromEnum(name_node)] != .identifier) continue;
            const name = ctx.tokenSlice(ctx.ast.nodes.items(.main_token)[@intFromEnum(name_node)]);
            if (std.mem.eql(u8, name, "arguments")) return true;
        }
    }
    return false;
}

// ── Local arguments declaration renaming ───────────────────────────

/// Rename `var arguments` declarations inside an arrow body to `_argumentsN`.
fn renameLocalArgumentsDecl(ctx: *TransformContext, body_node: NodeIndex, new_name: []const u8) void {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    const body_tag = tags[@intFromEnum(body_node)];
    if (body_tag != .block_statement) return;

    const body_data = datas[@intFromEnum(body_node)];
    const extra_idx = @intFromEnum(body_data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (stmt_raw >= tags.len) continue;
        const stmt_tag = tags[stmt_raw];
        if (stmt_tag != .var_declaration and stmt_tag != .let_declaration and stmt_tag != .const_declaration) continue;

        const stmt_data = datas[stmt_raw];
        const decl_extra = @intFromEnum(stmt_data.extra);
        if (decl_extra + 1 >= ctx.ast.extra_data.items.len) continue;
        const decl_start = ctx.ast.extra_data.items[decl_extra];
        const decl_end = ctx.ast.extra_data.items[decl_extra + 1];

        for (ctx.ast.extra_data.items[decl_start..decl_end]) |decl_raw| {
            if (decl_raw >= tags.len) continue;
            if (tags[decl_raw] != .declarator) continue;
            const decl_data = datas[decl_raw];
            const name_node = decl_data.binary.lhs;
            if (name_node == .none) continue;
            if (tags[@intFromEnum(name_node)] != .identifier) continue;
            const name = ctx.tokenSlice(ctx.ast.nodes.items(.main_token)[@intFromEnum(name_node)]);
            if (std.mem.eql(u8, name, "arguments")) {
                // Rename this identifier to the new name
                ctx.putReplacementSource(name_node, new_name) catch {};
            }
        }
    }
}

// ── Reference scanning (iterative) ─────────────────────────────────

fn scanReferences(
    ctx: *TransformContext,
    arrow_node: NodeIndex,
    node: NodeIndex,
    local_arguments_bindings: *const std.AutoHashMapUnmanaged(u32, void),
    lexical_arguments_bindings: *std.AutoHashMapUnmanaged(u32, void),
    this_positions: *std.ArrayListUnmanaged(SourceRange),
    arguments_positions: *std.ArrayListUnmanaged(SourceRange),
    local_arguments_decl_positions: *std.ArrayListUnmanaged(SourceRange),
    local_arguments_positions: *std.ArrayListUnmanaged(SourceRange),
    has_this: *bool,
    has_arguments: *bool,
    has_local_arguments: *bool,
) void {
    const WorkItem = struct {
        node: NodeIndex,
    };

    var work_stack: std.ArrayListUnmanaged(WorkItem) = .empty;
    defer work_stack.deinit(ctx.allocator);

    work_stack.append(ctx.allocator, .{ .node = node }) catch return;

    const has_literal_arguments_replacements = hasLiteralArgumentsReplacements(ctx);
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    while (work_stack.items.len > 0) {
        const item = work_stack.items[work_stack.items.len - 1];
        work_stack.items.len -= 1;
        if (item.node == .none) continue;
        const ni = @intFromEnum(item.node);
        if (ni >= tags.len) continue;

        const tag = tags[ni];

        // Stop at non-arrow function boundaries and class bodies
        switch (tag) {
            .function_expr,
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            => continue,
            .class_expr, .class_declaration, .class_body => continue,
            .method_definition,
            .class_method,
            .class_private_method,
            .getter,
            .setter,
            => continue,
            else => {},
        }

        if (tag == .this_expr) {
            has_this.* = true;
            const start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tokens[ni])];
            this_positions.append(ctx.allocator, .{ .start = start, .end = start + 4 }) catch {};
            continue;
        }

        if (tag == .identifier) {
            const name = ctx.tokenSlice(main_tokens[ni]);
            const is_arguments = blk: {
                if (std.mem.eql(u8, name, "arguments")) {
                    if (ctx.ast.replacement_source.get(ni)) |replacement| {
                        if (!std.mem.eql(u8, replacement, "arguments")) break :blk false;
                    }
                    break :blk true;
                }
                if (!has_literal_arguments_replacements) break :blk false;
                if (ctx.ast.replacement_source.get(ni)) |replacement| {
                    break :blk std.mem.eql(u8, replacement, "arguments");
                }
                break :blk false;
            };
            if (is_arguments) {
                const start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tokens[ni])];
                if (ctx.scope) |scope_result| {
                    const resolved_binding = if (ctx.session) |session|
                        session.resolvedBindingIndexFor(item.node)
                    else
                        (scope_mod.getBindingIndexForNode(scope_result, item.node) orelse
                            scope_mod.resolveBindingIndexForNode(scope_result, item.node, name));
                    if (resolved_binding) |binding_idx| {
                        if (local_arguments_bindings.contains(binding_idx)) {
                            const binding = scope_result.bindings[binding_idx];
                            if (binding.node == item.node or binding.decl_node == item.node) {
                                local_arguments_decl_positions.append(ctx.allocator, .{ .start = start, .end = start + 9 }) catch {};
                            } else {
                                has_local_arguments.* = true;
                                local_arguments_positions.append(ctx.allocator, .{ .start = start, .end = start + 9 }) catch {};
                            }
                            continue;
                        }
                        if (bindingIsInArrowLexicalChain(scope_result, arrow_node, binding_idx)) {
                            lexical_arguments_bindings.put(ctx.allocator, binding_idx, {}) catch {};
                            continue;
                        }
                    }
                }
                has_arguments.* = true;
                arguments_positions.append(ctx.allocator, .{ .start = start, .end = start + 9 }) catch {};
                continue;
            }
        }

        if (tag == .member_expr or tag == .optional_chain_expr) {
            const d = datas[ni];
            work_stack.append(ctx.allocator, .{ .node = d.binary.lhs }) catch {};
            continue;
        }

        const children = visitor.getChildren(ctx.ast, item.node);

        var ci: u8 = 0;
        while (ci < children.len) : (ci += 1) {
            work_stack.append(ctx.allocator, .{ .node = children.items[ci] }) catch {};
        }

        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch {};
            }
        }

        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch {};
            }
        }
    }
}

fn hasLiteralArgumentsReplacements(ctx: *TransformContext) bool {
    if (ctx.ast.replacement_source.count() == 0) return false;
    if (g_arguments_replacement_ast == ctx.ast) return g_has_literal_arguments_replacements;

    g_arguments_replacement_ast = ctx.ast;
    g_has_literal_arguments_replacements = false;

    var iter = ctx.ast.replacement_source.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, "arguments")) {
            g_has_literal_arguments_replacements = true;
            break;
        }
    }

    return g_has_literal_arguments_replacements;
}

fn bindingIsInArrowLexicalChain(scope_result: *const scope_mod.ScopeResult, arrow_node: NodeIndex, binding_idx: u32) bool {
    const arrow_scope = scope_mod.getScopeForNode(scope_result, arrow_node) orelse return false;
    const binding_scope = scope_result.bindings[binding_idx].scope;

    var current: ?scope_mod.ScopeIndex = arrow_scope;
    while (current) |scope_idx| {
        const scope = scope_result.scopes[@intFromEnum(scope_idx)];
        switch (scope.kind) {
            .function, .global, .module => return false,
            else => {},
        }
        if (scope_idx == binding_scope) return true;
        current = scope.parent;
    }

    return false;
}

fn collectLocalArgumentsBindings(
    ctx: *TransformContext,
    node: NodeIndex,
    local_arguments_bindings: *std.AutoHashMapUnmanaged(u32, void),
) void {
    const scope_result = ctx.scope orelse return;
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    const WorkItem = struct {
        node: NodeIndex,
        is_nested_arrow: bool,
    };

    var work_stack: std.ArrayListUnmanaged(WorkItem) = .empty;
    defer work_stack.deinit(ctx.allocator);

    work_stack.append(ctx.allocator, .{ .node = node, .is_nested_arrow = false }) catch return;

    while (work_stack.items.len > 0) {
        const item = work_stack.items[work_stack.items.len - 1];
        work_stack.items.len -= 1;
        if (item.node == .none) continue;
        const ni = @intFromEnum(item.node);
        if (ni >= tags.len) continue;

        const tag = tags[ni];
        switch (tag) {
            .function_expr,
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .class_expr,
            .class_declaration,
            .class_body,
            .method_definition,
            .class_method,
            .class_private_method,
            .getter,
            .setter,
            => continue,
            .arrow_function_expr => if (item.is_nested_arrow) continue,
            else => {},
        }

        if (tag == .identifier) {
            const name = ctx.tokenSlice(main_tokens[ni]);
            if (std.mem.eql(u8, name, "arguments")) {
                const binding_idx = if (ctx.session) |session|
                    session.resolvedBindingIndexFor(item.node)
                else
                    scope_mod.getBindingIndexForNode(scope_result, item.node);
                if (binding_idx) |binding_idx_raw| {
                    const binding = scope_result.bindings[binding_idx_raw];
                    if ((binding.node == item.node or binding.decl_node == item.node) and
                        std.mem.eql(u8, binding.name, "arguments"))
                    {
                        local_arguments_bindings.put(ctx.allocator, binding_idx_raw, {}) catch return;
                    }
                }
            }
        }

        if (tag == .member_expr or tag == .optional_chain_expr) {
            const d = datas[ni];
            work_stack.append(ctx.allocator, .{ .node = d.binary.lhs, .is_nested_arrow = item.is_nested_arrow }) catch return;
            continue;
        }

        const children = visitor.getChildren(ctx.ast, item.node);
        var ci: u8 = 0;
        while (ci < children.len) : (ci += 1) {
            work_stack.append(ctx.allocator, .{
                .node = children.items[ci],
                .is_nested_arrow = item.is_nested_arrow or tag == .arrow_function_expr,
            }) catch return;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                work_stack.append(ctx.allocator, .{
                    .node = @enumFromInt(raw),
                    .is_nested_arrow = item.is_nested_arrow or tag == .arrow_function_expr,
                }) catch return;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                work_stack.append(ctx.allocator, .{
                    .node = @enumFromInt(raw),
                    .is_nested_arrow = item.is_nested_arrow or tag == .arrow_function_expr,
                }) catch return;
            }
        }
    }
}

fn bodyMayReferenceThis(ctx: *TransformContext, body_node: NodeIndex) bool {
    if (ctx.session) |session| {
        return hasRelevantThisOccurrence(session, ctx, body_node);
    }

    const body_source = getNodeSourceRaw(ctx, body_node);
    return std.mem.indexOf(u8, body_source, "this") != null;
}

fn bodyMayReferenceArguments(ctx: *TransformContext, body_node: NodeIndex) bool {
    if (ctx.session) |session| {
        if (hasRelevantIdentifierOccurrence(session, ctx, body_node, "arguments")) return true;
        return hasLiteralArgumentsReplacementInBody(session, ctx, body_node);
    }

    const body_source = getNodeSourceRaw(ctx, body_node);
    return std.mem.indexOf(u8, body_source, "arguments") != null;
}

fn hasRelevantThisOccurrence(
    session: anytype,
    ctx: *TransformContext,
    body_node: NodeIndex,
) bool {
    const body_range = session.subtreeRange(body_node);
    for (session.thisOccurrences()) |occurrence| {
        const occurrence_range = session.subtreeRange(occurrence);
        if (occurrence_range.start < body_range.start or occurrence_range.end > body_range.end) continue;
        if (isExcludedFromArrowDirectReference(session, ctx, body_node, occurrence)) continue;
        return true;
    }

    return false;
}

fn hasRelevantIdentifierOccurrence(
    session: anytype,
    ctx: *TransformContext,
    body_node: NodeIndex,
    name: []const u8,
) bool {
    const body_range = session.subtreeRange(body_node);

    // Check unresolved occurrences (globals, free refs — e.g. `arguments`).
    const unresolved = session.unresolvedOccurrences(name);
    for (unresolved) |occurrence| {
        const r = session.subtreeRange(occurrence.node);
        if (r.start < body_range.start or r.end > body_range.end) continue;
        if (isExcludedFromArrowDirectReference(session, ctx, body_node, occurrence.node)) continue;
        return true;
    }

    // Check resolved binding occurrences.
    if (session.bindingIndices(name)) |indices| {
        for (indices) |binding_idx| {
            for (session.bindingOccurrences(binding_idx)) |occurrence| {
                const r = session.subtreeRange(occurrence.node);
                if (r.start < body_range.start or r.end > body_range.end) continue;
                if (isExcludedFromArrowDirectReference(session, ctx, body_node, occurrence.node)) continue;
                return true;
            }
        }
    }

    return false;
}

fn hasLiteralArgumentsReplacementInBody(
    session: anytype,
    ctx: *TransformContext,
    body_node: NodeIndex,
) bool {
    if (!hasLiteralArgumentsReplacements(ctx)) return false;

    const body_range = session.subtreeRange(body_node);
    var iter = ctx.ast.replacement_source.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.*, "arguments")) continue;

        const node: NodeIndex = @enumFromInt(entry.key_ptr.*);
        const occurrence_range = session.subtreeRange(node);
        if (occurrence_range.start < body_range.start or occurrence_range.end > body_range.end) continue;
        if (isExcludedFromArrowDirectReference(session, ctx, body_node, node)) continue;
        return true;
    }

    return false;
}

// ── Find enclosing function ─────────────────────────────────────────

fn findEnclosingFunction(ctx: *TransformContext, arrow_idx: NodeIndex) ?NodeIndex {
    if (ctx.scope) |scope_result| {
        const scope_idx = scope_result.node_to_scope.get(@intFromEnum(arrow_idx)) orelse return null;
        var current: ?@import("../scope.zig").ScopeIndex = scope_idx;
        while (current) |si| {
            const scope = scope_result.scopes[@intFromEnum(si)];
            switch (scope.kind) {
                .function => return getFunctionBody(ctx, scope.node),
                .global, .module => return @enumFromInt(0),
                .arrow => {},
                else => {},
            }
            current = scope.parent;
        }
    }
    return findEnclosingFunctionBrute(ctx, arrow_idx);
}

fn getFunctionBody(ctx: *TransformContext, func_node: NodeIndex) ?NodeIndex {
    const ni = @intFromEnum(func_node);
    const tags = ctx.ast.nodes.items(.tag);
    if (ni >= tags.len) return null;
    const tag = tags[ni];

    switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        => {
            const d = ctx.ast.nodes.items(.data)[ni];
            const eidx = @intFromEnum(d.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
            }
        },
        .method_definition, .class_method, .class_private_method => {
            const d = ctx.ast.nodes.items(.data)[ni];
            const eidx = @intFromEnum(d.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
            }
        },
        else => {},
    }
    return null;
}

fn findEnclosingFunctionBrute(ctx: *TransformContext, arrow_idx: NodeIndex) ?NodeIndex {
    const arrow_start = getNodeStart(ctx, arrow_idx);
    const arrow_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(arrow_idx)];
    const tags = ctx.ast.nodes.items(.tag);

    var best_body: ?NodeIndex = @enumFromInt(0);
    var best_range: u64 = std.math.maxInt(u64);

    for (tags, 0..) |tag, ni| {
        const is_func = switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .method_definition,
            .class_method,
            .class_private_method,
            => true,
            else => false,
        };
        if (!is_func) continue;
        if (ni == @intFromEnum(arrow_idx)) continue;

        const d = ctx.ast.nodes.items(.data)[ni];
        const eidx = @intFromEnum(d.extra);
        if (eidx + 3 >= ctx.ast.extra_data.items.len) continue;
        const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
        if (body == .none) continue;

        const func_start = getNodeStart(ctx, @enumFromInt(ni));
        const func_end = ctx.ast.nodes.items(.end_offset)[ni];

        if (arrow_start >= func_start and arrow_end <= func_end) {
            const range = func_end - func_start;
            if (range < best_range) {
                best_body = body;
                best_range = range;
            }
        }
    }

    return best_body;
}

// ── Enclosing scope arguments rename ────────────────────────────────

/// Check if the enclosing scope (body_node) has `var arguments = X`.
/// If so, rename the identifier to `arguments_name` and return true.
fn renameEnclosingScopeArguments(ctx: *TransformContext, body_node: NodeIndex, arguments_name: []const u8) bool {
    const body_i = @intFromEnum(body_node);
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    // For the program root (node 0), scan top-level statements
    if (body_i == 0 and tags[0] == .program) {
        const prog_data = datas[0];
        const prog_extra = @intFromEnum(prog_data.extra);
        if (prog_extra + 1 < ctx.ast.extra_data.items.len) {
            const range_start = ctx.ast.extra_data.items[prog_extra];
            const range_end = ctx.ast.extra_data.items[prog_extra + 1];
            return scanAndRenameArgumentsInRange(ctx, tags, datas, range_start, range_end, arguments_name);
        }
        return false;
    }

    // For function bodies, scan block_statement children
    if (body_i >= tags.len) return false;
    if (tags[body_i] != .block_statement) return false;

    const body_data = datas[body_i];
    const extra_idx = @intFromEnum(body_data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    return scanAndRenameArgumentsInRange(ctx, tags, datas, range_start, range_end, arguments_name);
}

fn scanAndRenameArgumentsInRange(ctx: *TransformContext, tags: []const Node.Tag, datas: []const Node.Data, range_start: u32, range_end: u32, arguments_name: []const u8) bool {
    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (stmt_raw >= tags.len) continue;
        const stmt_tag = tags[stmt_raw];
        if (stmt_tag != .var_declaration and stmt_tag != .let_declaration and stmt_tag != .const_declaration) continue;

        const stmt_data = datas[stmt_raw];
        const decl_extra = @intFromEnum(stmt_data.extra);
        if (decl_extra + 1 >= ctx.ast.extra_data.items.len) continue;
        const decl_start = ctx.ast.extra_data.items[decl_extra];
        const decl_end = ctx.ast.extra_data.items[decl_extra + 1];

        for (ctx.ast.extra_data.items[decl_start..decl_end]) |decl_raw| {
            if (decl_raw >= tags.len) continue;
            if (tags[decl_raw] != .declarator) continue;
            const decl_data = datas[decl_raw];
            const name_node = decl_data.binary.lhs;
            if (name_node == .none) continue;
            if (tags[@intFromEnum(name_node)] != .identifier) continue;
            const name = ctx.tokenSlice(ctx.ast.nodes.items(.main_token)[@intFromEnum(name_node)]);
            if (std.mem.eql(u8, name, "arguments")) {
                // Rename the identifier
                ctx.putReplacementSource(name_node, arguments_name) catch {};
                return true;
            }
        }
    }
    return false;
}

// ── Set enclosing prefix ────────────────────────────────────────────

fn setEnclosingPrefix(ctx: *TransformContext, body_node: NodeIndex, needs_this: bool, needs_arguments: bool, this_name: []const u8, arguments_name: []const u8) void {
    const body_i = @intFromEnum(body_node);
    // At program level, use safe typeof check for arguments
    const is_program_level = (body_i == 0);
    const arguments_initializer = if (is_program_level and needs_arguments)
        "typeof arguments === \"undefined\" ? void 0 : arguments"
    else
        "arguments";

    var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;

    if (ctx.ast.block_prefix_source.get(body_i)) |existing| {
        prefix_buf.appendSlice(ctx.allocator, existing) catch return;
        if (needs_this and !containsDecl(existing, this_name)) {
            prefix_buf.appendSlice(ctx.allocator, "var ") catch return;
            prefix_buf.appendSlice(ctx.allocator, this_name) catch return;
            prefix_buf.appendSlice(ctx.allocator, " = this;\n") catch return;
        }
        if (needs_arguments and !containsDecl(existing, arguments_name)) {
            prefix_buf.appendSlice(ctx.allocator, "var ") catch return;
            prefix_buf.appendSlice(ctx.allocator, arguments_name) catch return;
            prefix_buf.appendSlice(ctx.allocator, " = ") catch return;
            prefix_buf.appendSlice(ctx.allocator, arguments_initializer) catch return;
            prefix_buf.appendSlice(ctx.allocator, ";\n") catch return;
        }
    } else {
        if (needs_this) {
            prefix_buf.appendSlice(ctx.allocator, "var ") catch return;
            prefix_buf.appendSlice(ctx.allocator, this_name) catch return;
            prefix_buf.appendSlice(ctx.allocator, " = this;") catch return;
        }
        if (needs_arguments) {
            if (needs_this) prefix_buf.appendSlice(ctx.allocator, "\n") catch return;
            prefix_buf.appendSlice(ctx.allocator, "var ") catch return;
            prefix_buf.appendSlice(ctx.allocator, arguments_name) catch return;
            prefix_buf.appendSlice(ctx.allocator, " = ") catch return;
            prefix_buf.appendSlice(ctx.allocator, arguments_initializer) catch return;
            prefix_buf.appendSlice(ctx.allocator, ";") catch return;
        }
    }

    if (prefix_buf.items.len > 0) {
        ctx.ast.block_prefix_source.put(ctx.allocator, body_i, prefix_buf.items) catch return;
    }
}

fn setDerivedThisPrefix(ctx: *TransformContext, body_node: NodeIndex, this_name: []const u8) void {
    const body_i = @intFromEnum(body_node);
    var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;

    if (ctx.ast.block_prefix_source.get(body_i)) |existing| {
        prefix_buf.appendSlice(ctx.allocator, existing) catch return;
        if (!containsBareVarDecl(existing, this_name)) {
            if (prefix_buf.items.len > 0 and prefix_buf.items[prefix_buf.items.len - 1] != '\n') {
                prefix_buf.append(ctx.allocator, '\n') catch return;
            }
            prefix_buf.appendSlice(ctx.allocator, "var ") catch return;
            prefix_buf.appendSlice(ctx.allocator, this_name) catch return;
            prefix_buf.appendSlice(ctx.allocator, ";") catch return;
        }
    } else {
        prefix_buf.appendSlice(ctx.allocator, "var ") catch return;
        prefix_buf.appendSlice(ctx.allocator, this_name) catch return;
        prefix_buf.appendSlice(ctx.allocator, ";") catch return;
    }

    if (prefix_buf.items.len > 0) {
        ctx.ast.block_prefix_source.put(ctx.allocator, body_i, prefix_buf.items) catch return;
    }
}

fn containsDecl(text: []const u8, name: []const u8) bool {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "var {s} = ", .{name}) catch return false;
    return std.mem.indexOf(u8, text, search) != null;
}

fn containsBareVarDecl(text: []const u8, name: []const u8) bool {
    var search_buf: [256]u8 = undefined;
    const bare_search = std.fmt.bufPrint(&search_buf, "var {s};", .{name}) catch return false;
    return std.mem.indexOf(u8, text, bare_search) != null or containsDecl(text, name);
}

fn isDerivedConstructorBody(ctx: *TransformContext, body_node: NodeIndex) bool {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        if (tag != .class_declaration and tag != .class_expr) continue;
        const class_extra = @intFromEnum(datas[ni].extra);
        if (class_extra + 2 >= ctx.ast.extra_data.items.len) continue;
        const super_class: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[class_extra + 1]);
        if (super_class == .none) continue;
        const class_body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[class_extra + 2]);
        if (class_body == .none or ctx.nodeTag(class_body) != .class_body) continue;

        const body_extra = @intFromEnum(ctx.nodeData(class_body).extra);
        if (body_extra + 1 >= ctx.ast.extra_data.items.len) continue;
        const elems_start = ctx.ast.extra_data.items[body_extra];
        const elems_end = ctx.ast.extra_data.items[body_extra + 1];
        for (ctx.ast.extra_data.items[elems_start..elems_end]) |elem_raw| {
            const elem: NodeIndex = @enumFromInt(elem_raw);
            const elem_tag = ctx.nodeTag(elem);
            if (elem_tag != .class_method and elem_tag != .method_definition) continue;
            const elem_extra = @intFromEnum(ctx.nodeData(elem).extra);
            if (elem_extra + 3 >= ctx.ast.extra_data.items.len) continue;
            const key: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[elem_extra]);
            const elem_body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[elem_extra + 3]);
            if (elem_body != body_node or key == .none or ctx.nodeTag(key) != .identifier) continue;
            if (std.mem.eql(u8, ctx.tokenSlice(ctx.mainToken(key)), "constructor")) return true;
        }
    }

    return false;
}

fn patchDerivedConstructorSuperCaptures(ctx: *TransformContext, body_node: NodeIndex, this_name: []const u8) void {
    const body_tag = ctx.nodeTag(body_node);
    if (body_tag != .block_statement) return;

    const body_extra = @intFromEnum(ctx.nodeData(body_node).extra);
    if (body_extra + 1 >= ctx.ast.extra_data.items.len) return;
    const stmts_start = ctx.ast.extra_data.items[body_extra];
    const stmts_end = ctx.ast.extra_data.items[body_extra + 1];

    for (ctx.ast.extra_data.items[stmts_start..stmts_end]) |stmt_raw| {
        patchDerivedSuperInNode(ctx, @enumFromInt(stmt_raw), this_name);
    }
}

fn patchDerivedSuperInNode(ctx: *TransformContext, node: NodeIndex, this_name: []const u8) void {
    if (node == .none) return;
    const tag = ctx.nodeTag(node);

    switch (tag) {
        .function_expr,
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .class_expr,
        .class_declaration,
        .class_body,
        .method_definition,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        => return,
        else => {},
    }

    if (tag == .expression_statement) {
        const expr = ctx.nodeData(node).unary;
        if (isSuperCallExpr(ctx, expr)) {
            if (!ctx.ast.replacement_source.contains(@intFromEnum(node))) {
                const call_src = getNodeSourceRaw(ctx, expr);
                const replacement = std.fmt.allocPrint(ctx.allocator, "{s};\n{s} = this;", .{ call_src, this_name }) catch return;
                ctx.putReplacementSource(node, replacement) catch return;
                ctx.markReplacementNeedsReindent(node) catch {};
            }
            return;
        }
    }

    if (isSuperCallExpr(ctx, node)) {
        if (!ctx.ast.replacement_source.contains(@intFromEnum(node))) {
            const call_src = getNodeSourceRaw(ctx, node);
            const replacement = std.fmt.allocPrint(ctx.allocator, "({s}, {s} = this)", .{ call_src, this_name }) catch return;
            ctx.putReplacementSource(node, replacement) catch return;
        }
        return;
    }

    if (tag == .member_expr or tag == .optional_chain_expr) {
        patchDerivedSuperInNode(ctx, ctx.nodeData(node).binary.lhs, this_name);
        return;
    }

    const children = visitor.getChildren(ctx.ast, node);
    var ci: u8 = 0;
    while (ci < children.len) : (ci += 1) {
        patchDerivedSuperInNode(ctx, children.items[ci], this_name);
    }
    if (children.range_end > children.range_start) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            patchDerivedSuperInNode(ctx, @enumFromInt(raw), this_name);
        }
    }
    if (children.range2_end > children.range2_start) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            patchDerivedSuperInNode(ctx, @enumFromInt(raw), this_name);
        }
    }
}

fn isSuperCallExpr(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none or ctx.nodeTag(node) != .call_expr) return false;
    const call_extra = @intFromEnum(ctx.nodeData(node).extra);
    if (call_extra >= ctx.ast.extra_data.items.len) return false;
    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[call_extra]);
    return callee != .none and ctx.nodeTag(callee) == .super_expr;
}

// ── Counter-based name allocation ──────────────────────────────────

fn allocThisName(ctx: *TransformContext, counter: u32) []const u8 {
    return std.fmt.allocPrint(ctx.allocator, "_this{d}", .{counter}) catch "_this";
}

fn allocArgumentsName(ctx: *TransformContext, counter: u32) []const u8 {
    if (counter == 10) return "_arguments0";
    return std.fmt.allocPrint(ctx.allocator, "_arguments{d}", .{counter}) catch "_arguments";
}

// ── Arrow naming ────────────────────────────────────────────────────

fn getArrowName(ctx: *TransformContext, arrow_idx: NodeIndex) ?[]const u8 {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        switch (tag) {
            .declarator => {
                const d = datas[ni];
                if (d.binary.rhs == arrow_idx) {
                    const name_node = d.binary.lhs;
                    if (name_node != .none and tags[@intFromEnum(name_node)] == .identifier) {
                        return ctx.tokenSlice(ctx.mainToken(name_node));
                    }
                }
            },
            .property => {
                const d = datas[ni];
                if (d.binary.rhs == arrow_idx) {
                    const key_node = d.binary.lhs;
                    if (key_node != .none and tags[@intFromEnum(key_node)] == .identifier) {
                        return ctx.tokenSlice(ctx.mainToken(key_node));
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn getArrowBindingNameNode(ctx: *TransformContext, arrow_idx: NodeIndex) ?NodeIndex {
    if (ctx.session) |session| {
        if (session.functionBindingNode(arrow_idx)) |name_node| return name_node;
        // The shared session already indexes the same direct binding cases that the
        // legacy arrow-binding map covers. When the session has no answer, this arrow
        // is anonymous for our current naming logic, so avoid rebuilding the local map.
        return null;
    }
    ensureArrowBindingNameMap(ctx);
    const arrow_i = @intFromEnum(arrow_idx);
    if (arrow_i >= g_arrow_binding_name_nodes.len) return null;
    const name_i = g_arrow_binding_name_nodes[arrow_i];
    if (name_i == arrow_binding_name_none) return null;
    return @enumFromInt(name_i);
}

fn ensureArrowBindingNameMap(ctx: *TransformContext) void {
    const tags = ctx.ast.nodes.items(.tag);
    const node_count = tags.len;
    if (g_arrow_binding_name_ast == ctx.ast and g_arrow_binding_name_nodes.len == node_count) return;

    g_arrow_binding_name_ast = ctx.ast;
    g_arrow_binding_name_nodes = ctx.allocator.alloc(u32, node_count) catch &[_]u32{};
    @memset(g_arrow_binding_name_nodes, arrow_binding_name_none);

    const datas = ctx.ast.nodes.items(.data);
    for (tags, 0..) |tag, ni| {
        switch (tag) {
            .declarator, .assignment_expr => {
                const d = datas[ni];
                if (d.binary.rhs == .none) continue;
                const rhs_i = @intFromEnum(d.binary.rhs);
                if (rhs_i >= node_count) continue;
                const name_node = d.binary.lhs;
                if (name_node == .none or tags[@intFromEnum(name_node)] != .identifier) continue;
                g_arrow_binding_name_nodes[rhs_i] = @intFromEnum(name_node);
            },
            else => {},
        }
    }
}

fn hasDirectBindingReferenceInArrowBody(ctx: *TransformContext, body_node: NodeIndex, binding_idx: u32) bool {
    const scope_result = ctx.scope orelse return false;
    if (ctx.session) |session| {
        const body_range = session.subtreeRange(body_node);
        const occurrences = session.bindingOccurrences(binding_idx);
        for (occurrences) |occurrence| {
            const occurrence_range = session.subtreeRange(occurrence.node);
            if (occurrence_range.start < body_range.start or occurrence_range.end > body_range.end) continue;
            if (isExcludedFromArrowDirectReference(session, ctx, body_node, occurrence.node)) continue;
            return true;
        }
        return false;
    }

    const WorkItem = struct {
        node: NodeIndex,
    };

    var work_stack: std.ArrayListUnmanaged(WorkItem) = .empty;
    defer work_stack.deinit(ctx.allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(ctx.allocator);

    work_stack.append(ctx.allocator, .{ .node = body_node }) catch return false;

    while (work_stack.items.len > 0) {
        const item = work_stack.items[work_stack.items.len - 1];
        work_stack.items.len -= 1;
        if (item.node == .none) continue;
        const ni = @intFromEnum(item.node);
        if (ni >= ctx.ast.nodes.items(.tag).len) continue;
        if (visited.contains(@intCast(ni))) continue;
        visited.put(ctx.allocator, @intCast(ni), {}) catch return false;

        const tag = ctx.nodeTag(item.node);
        switch (tag) {
            .function_expr,
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .class_expr,
            .class_declaration,
            .class_body,
            .method_definition,
            .class_method,
            .class_private_method,
            .getter,
            .setter,
            => continue,
            else => {},
        }

        if (tag == .identifier) {
            const name = ctx.tokenSlice(ctx.mainToken(item.node));
            if (scope_mod.resolveBindingIndexForNode(scope_result, item.node, name) == binding_idx) {
                return true;
            }
        }

        if (tag == .member_expr or tag == .optional_chain_expr) {
            const d = ctx.nodeData(item.node);
            work_stack.append(ctx.allocator, .{ .node = d.binary.lhs }) catch return false;
            continue;
        }

        const children = visitor.getChildren(ctx.ast, item.node);
        var ci: u8 = 0;
        while (ci < children.len) : (ci += 1) {
            work_stack.append(ctx.allocator, .{ .node = children.items[ci] }) catch return false;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch return false;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch return false;
            }
        }
    }

    return false;
}

fn isExcludedFromArrowDirectReference(
    session: anytype,
    ctx: *TransformContext,
    body_node: NodeIndex,
    node: NodeIndex,
) bool {
    if (node == body_node) return false;

    var current = session.parentOf(node);
    while (current) |ancestor| : (current = session.parentOf(ancestor)) {
        if (isArrowDirectReferenceExcludedTag(ctx.nodeTag(ancestor))) return true;
        if (ancestor == body_node) return false;
    }
    return false;
}

fn isArrowDirectReferenceExcludedTag(tag: Node.Tag) bool {
    return switch (tag) {
        .function_expr,
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .class_expr,
        .class_declaration,
        .class_body,
        .method_definition,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        => true,
        else => false,
    };
}

fn renameResolvedBindingInSubtree(ctx: *TransformContext, root: NodeIndex, binding_idx: u32, new_name: []const u8) void {
    const scope_result = ctx.scope orelse return;
    if (ctx.session) |session| {
        const root_range = session.subtreeRange(root);
        const occurrences = session.bindingOccurrences(binding_idx);
        for (occurrences) |occurrence| {
            const occurrence_range = session.subtreeRange(occurrence.node);
            if (occurrence_range.start < root_range.start or occurrence_range.end > root_range.end) continue;
            ctx.putReplacementSource(occurrence.node, new_name) catch return;
        }
        return;
    }

    const WorkItem = struct {
        node: NodeIndex,
    };

    var work_stack: std.ArrayListUnmanaged(WorkItem) = .empty;
    defer work_stack.deinit(ctx.allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(ctx.allocator);

    work_stack.append(ctx.allocator, .{ .node = root }) catch return;

    while (work_stack.items.len > 0) {
        const item = work_stack.items[work_stack.items.len - 1];
        work_stack.items.len -= 1;
        if (item.node == .none) continue;
        const ni = @intFromEnum(item.node);
        if (ni >= ctx.ast.nodes.items(.tag).len) continue;
        if (visited.contains(@intCast(ni))) continue;
        visited.put(ctx.allocator, @intCast(ni), {}) catch return;

        const tag = ctx.nodeTag(item.node);
        if (tag == .identifier) {
            const name = ctx.tokenSlice(ctx.mainToken(item.node));
            if (scope_mod.resolveBindingIndexForNode(scope_result, item.node, name) == binding_idx) {
                ctx.putReplacementSource(@enumFromInt(ni), new_name) catch return;
            }
        }

        if (tag == .member_expr or tag == .optional_chain_expr) {
            const d = ctx.nodeData(item.node);
            work_stack.append(ctx.allocator, .{ .node = d.binary.lhs }) catch return;
            continue;
        }

        const children = visitor.getChildren(ctx.ast, item.node);
        var ci: u8 = 0;
        while (ci < children.len) : (ci += 1) {
            work_stack.append(ctx.allocator, .{ .node = children.items[ci] }) catch return;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch return;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch return;
            }
        }
    }
}

// ── Source text helpers ──────────────────────────────────────────────

/// Get the indentation (number of leading spaces) of the line containing position pos.
fn getLineIndent(source: []const u8, pos: u32) u32 {
    // Find start of line
    var line_start: u32 = pos;
    while (line_start > 0 and source[line_start - 1] != '\n') {
        line_start -= 1;
    }
    // Count leading spaces
    var spaces: u32 = 0;
    while (line_start + spaces < source.len and source[line_start + spaces] == ' ') {
        spaces += 1;
    }
    return spaces;
}

/// Re-indent body text with the given indent prefix.
/// For each newline followed by content, ensures proper indentation.
fn reindentBody(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, body: []const u8, indent: []const u8) void {
    _ = indent;
    if (std.mem.indexOfScalar(u8, body, '\n') != null) {
        buf.appendSlice(ctx.allocator, body) catch {};
        return;
    }

    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return;

    var depth: i32 = 1;
    var at_line_start = true;
    var prev_significant: ?u8 = null;
    var in_quote: ?u8 = null;
    var escaped = false;

    for (trimmed) |c| {
        if (in_quote) |quote| {
            if (at_line_start) {
                appendBodyIndent(buf, ctx, depth);
                at_line_start = false;
            }
            buf.append(ctx.allocator, c) catch return;
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == quote) {
                in_quote = null;
            }
            prev_significant = c;
            continue;
        }

        switch (c) {
            '\'', '"', '`' => {
                if (at_line_start) {
                    appendBodyIndent(buf, ctx, depth);
                    at_line_start = false;
                }
                buf.append(ctx.allocator, c) catch return;
                in_quote = c;
                prev_significant = c;
            },
            ' ', '\t', '\r' => {
                if (!at_line_start and prev_significant != ' ') {
                    buf.append(ctx.allocator, ' ') catch return;
                    prev_significant = ' ';
                }
            },
            '{' => {
                if (at_line_start) {
                    appendBodyIndent(buf, ctx, depth);
                }
                buf.append(ctx.allocator, '{') catch return;
                buf.append(ctx.allocator, '\n') catch return;
                depth += 1;
                at_line_start = true;
                prev_significant = '{';
            },
            ';' => {
                if (at_line_start) {
                    appendBodyIndent(buf, ctx, depth);
                    at_line_start = false;
                }
                buf.append(ctx.allocator, ';') catch return;
                buf.append(ctx.allocator, '\n') catch return;
                at_line_start = true;
                prev_significant = ';';
            },
            '}' => {
                if (prev_significant != null and prev_significant.? != '{' and prev_significant.? != ';' and prev_significant.? != '}') {
                    trimTrailingSpaces(buf);
                    buf.append(ctx.allocator, ';') catch return;
                    buf.append(ctx.allocator, '\n') catch return;
                } else if (!at_line_start) {
                    trimTrailingSpaces(buf);
                    buf.append(ctx.allocator, '\n') catch return;
                }
                depth -= 1;
                appendBodyIndent(buf, ctx, depth);
                buf.append(ctx.allocator, '}') catch return;
                at_line_start = false;
                prev_significant = '}';
                if (depth > 0) {
                    buf.append(ctx.allocator, '\n') catch return;
                    at_line_start = true;
                }
            },
            else => {
                if (at_line_start) {
                    appendBodyIndent(buf, ctx, depth);
                    at_line_start = false;
                }
                buf.append(ctx.allocator, c) catch return;
                prev_significant = c;
            },
        }
    }
}

fn appendBodyIndent(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, depth: i32) void {
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        buf.appendSlice(ctx.allocator, "  ") catch return;
    }
}

fn trimTrailingSpaces(buf: *std.ArrayListUnmanaged(u8)) void {
    while (buf.items.len > 0) {
        const c = buf.items[buf.items.len - 1];
        if (c != ' ' and c != '\t') break;
        buf.items.len -= 1;
    }
}

fn getNodeSourceRaw(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;
    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return ctx.ast.source[start..end];
}

fn getNodeStart(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ctx.ast.node_start_overrides.get(ni)) |override| return override;

    const tag = ctx.ast.nodes.items(.tag)[ni];
    const d = ctx.ast.nodes.items(.data)[ni];

    switch (tag) {
        .call_expr, .optional_call_expr => {
            const eidx = @intFromEnum(d.extra);
            if (eidx < ctx.ast.extra_data.items.len) {
                const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
                return getNodeStart(ctx, callee);
            }
        },
        .member_expr,
        .computed_member_expr,
        .optional_chain_expr,
        .optional_computed_member_expr,
        => return getNodeStart(ctx, d.binary.lhs),
        .binary_expr, .logical_expr, .assignment_expr => return getNodeStart(ctx, d.binary.lhs),
        .conditional_expr => return getNodeStart(ctx, d.binary.lhs),
        .ts_as_expression, .ts_satisfies_expression => return getNodeStart(ctx, d.binary.lhs),
        .ts_non_null_expression => return getNodeStart(ctx, d.unary),
        else => {},
    }

    const mt_idx = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(mt_idx)];
}
