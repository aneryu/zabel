const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");
const scope_mod = @import("../scope.zig");

/// Configuration for the for-of transform.
pub const Config = struct {
    /// When true, use loose mode (createForOfIteratorHelperLoose).
    loose: bool = false,
    /// When true, assume iterables are arrays (simple for loop).
    iterable_is_array: bool = false,
    /// When true, use assumeArray mode (same output as iterableIsArray).
    assume_array: bool = false,
    /// When true, skip iterator closing (no try/catch/finally wrapper).
    /// Output is same as loose mode.
    skip_for_of_iterator_closing: bool = false,
    /// When true, pass `true` as second arg to createForOfIteratorHelper(Loose).
    allow_array_like: bool = false,
    /// When true, emit `var` for loop/body block-scoped bindings to match a
    /// subsequent block-scoping transform that cannot rewrite replacement strings.
    rewrite_block_scoped_bindings: bool = false,
};

var g_config: Config = .{};

/// Global counter for unique iterator/step variable names.
var g_counter: u32 = 0;
var g_array_loop_counter: u32 = 0;
var g_iterator_loop_counter: u32 = 0;
const CachedLabelInfo = struct {
    label_node_i_plus1: u32 = 0,
    comment_start: u32 = 0,
    comment_end: u32 = 0,
};
var g_known_array_ast: ?*Ast = null;
var g_known_array_cache: []u8 = &[_]u8{};
var g_label_parent_ast: ?*Ast = null;
var g_label_parent_cache: []CachedLabelInfo = &[_]CachedLabelInfo{};
var g_if_parent_ast: ?*Ast = null;
var g_if_parent_cache: []u32 = &[_]u32{};

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.for_of_statement));
    filter.set(@intFromEnum(Node.Tag.for_of_await_statement));
    return .{
        .name = "for_of",
        .node_filter = filter,
        .enter = enterNode,
        .exit = exitNode,
        .priority = 20,
    };
}

/// Track used temp names to avoid collisions.
var g_used_temp_names: std.StringHashMapUnmanaged(u32) = .empty;

pub fn resetState() void {
    g_counter = 0;
    g_array_loop_counter = 0;
    g_iterator_loop_counter = 0;
    g_node_counters = .{};
    g_array_node_counters = .{};
    g_iterator_node_counters = .{};
    g_used_temp_names = .{};
    g_known_array_ast = null;
    g_known_array_cache = &[_]u8{};
    g_label_parent_ast = null;
    g_label_parent_cache = &[_]CachedLabelInfo{};
    g_if_parent_ast = null;
    g_if_parent_cache = &[_]u32{};
}

/// Pre-assigned counter for each for-of node (set during enter, used during exit)
var g_node_counters: std.AutoHashMapUnmanaged(u32, u32) = .empty;
var g_array_node_counters: std.AutoHashMapUnmanaged(u32, u32) = .empty;
var g_iterator_node_counters: std.AutoHashMapUnmanaged(u32, u32) = .empty;

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    if (tag == .for_of_statement) {
        // Pre-assign counter in top-down order
        g_counter += 1;
        g_node_counters.put(ctx.allocator, @intFromEnum(idx), g_counter) catch {};

        const data = ctx.nodeData(idx);
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx + 1 < ctx.ast.extra_data.items.len) {
            const right_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            const is_known_array = isKnownArrayIterable(ctx, right_node);
            const is_array_mode = g_config.iterable_is_array or g_config.assume_array or is_known_array;
            if (is_array_mode) {
                g_array_loop_counter += 1;
                g_array_node_counters.put(ctx.allocator, @intFromEnum(idx), g_array_loop_counter) catch {};
            } else {
                g_iterator_loop_counter += 1;
                g_iterator_node_counters.put(ctx.allocator, @intFromEnum(idx), g_iterator_loop_counter) catch {};
            }
        }
    }
    return .continue_traversal;
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .for_of_statement => {
            handleForOf(idx, ctx);
        },
        .for_of_await_statement => {},
        else => {},
    }
    return .continue_traversal;
}

// ── Main handler ────────────────────────────────────────────────────

fn handleForOf(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const left_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const right_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
    const body_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);

    if (left_node == .none or right_node == .none) return;

    const original_right_src = getNodeSource(ctx, right_node);
    const runtime_right_node = getRuntimeIterableNode(ctx, right_node);
    const right_src = getNodeSource(ctx, runtime_right_node);
    const body_src = getBodySource(ctx, body_node);

    // Determine the left-hand-side: var/let/const declaration or assignment
    const left_info = parseLeftSide(ctx, left_node);

    // Check for label prefix — if labeled, set replacement on the label node instead
    const label_info = findLabelParent(ctx, idx);
    const label_prefix = if (label_info.label) |l|
        (if (label_info.has_comment)
            fmtStr(ctx, "{s}:\n  {s}\n  ", .{ l, label_info.comment.? })
        else
            fmtStr(ctx, "{s}: ", .{l}))
    else
        "";
    const effective_node = if (label_info.label_node_i) |_| (label_info.label_node_i.?) else @intFromEnum(idx);
    // Check if the for-of (or its label) is a direct body of an if-statement
    const if_parent = findIfParent(ctx, @enumFromInt(effective_node));
    const target_node_i = if (if_parent) |ip| ip else effective_node;

    // Build if-wrapper prefix/suffix if needed
    const if_prefix = if (if_parent != null) blk: {
        const if_idx: NodeIndex = @enumFromInt(if_parent.?);
        const if_data = ctx.nodeData(if_idx);
        // if_statement uses extra data: extra[0]=test
        const if_eidx = @intFromEnum(if_data.extra);
        const cond_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[if_eidx]);
        const cond_src = getNodeSource(ctx, cond_node);
        break :blk fmtStr(ctx, "if ({s}) {{\n", .{cond_src});
    } else "";
    const if_suffix = if (if_parent != null) "\n}" else "";

    // Determine if the iterable is a known array type, enabling array-mode optimization
    // even in spec mode (opt mode). Check the AST node tag of the right side.
    const is_known_array = isKnownArrayIterable(ctx, right_node);

    // Detect if loop binding is redeclared in body — if so, body needs block wrapping
    const needs_body_block = detectRedeclaration(ctx, left_info, body_node);

    // Only wrap in if-block for spec mode (array/loose modes produce single statements)
    const is_spec_mode = !(g_config.iterable_is_array or g_config.assume_array or is_known_array or g_config.loose or g_config.skip_for_of_iterator_closing);
    const is_array_mode = !is_spec_mode and (g_config.iterable_is_array or g_config.assume_array or is_known_array);
    const counter = if (is_array_mode)
        (g_array_node_counters.get(@intFromEnum(idx)) orelse 1)
    else
        (g_iterator_node_counters.get(@intFromEnum(idx)) orelse 1);
    const suffix = if (counter == 1) "" else numSuffix(ctx, counter);
    const effective_if_prefix = if (is_spec_mode) if_prefix else "";
    const effective_if_suffix = if (is_spec_mode) if_suffix else "";
    // For non-spec modes with if-parent, target the original node (not the if)
    const effective_target = if (!is_spec_mode and if_parent != null) effective_node else target_node_i;

    if (g_config.iterable_is_array or g_config.assume_array or is_known_array) {
        // Static optimization only applies when iterableIsArray or assumeArray is set
        // (not for auto-detected arrays in opt mode)
        const is_static = if (g_config.iterable_is_array or g_config.assume_array)
            isStaticIterable(ctx, right_node, right_src, body_src)
        else
            false;
        const prefer_generic_arr_temp = is_known_array and
            !g_config.iterable_is_array and
            !g_config.assume_array and
            hasArrayTypeCastHint(ctx, right_node);
        buildArrayMode(ctx, effective_target, left_info, right_src, original_right_src, prefer_generic_arr_temp, body_src, body_node, suffix, label_prefix, is_static, needs_body_block, is_known_array, effective_if_prefix, effective_if_suffix);
    } else if (g_config.loose or g_config.skip_for_of_iterator_closing) {
        buildLooseMode(ctx, effective_target, left_info, right_src, body_src, body_node, suffix, label_prefix, needs_body_block, effective_if_prefix, effective_if_suffix);
    } else {
        buildSpecMode(ctx, effective_target, left_info, right_src, body_src, body_node, suffix, label_prefix, needs_body_block, effective_if_prefix, effective_if_suffix);
    }
}

// ── Left-side parsing ─────────────────────────────────────────────

const LeftInfo = struct {
    /// The keyword (var/let/const) or empty for assignment
    keyword: []const u8,
    /// The binding pattern or identifier source
    binding: []const u8,
    /// Whether this is a declaration (has keyword)
    is_decl: bool,
};

fn parseLeftSide(ctx: *TransformContext, left_node: NodeIndex) LeftInfo {
    const tag = ctx.nodeTag(left_node);

    switch (tag) {
        .var_declaration => return parseVarDecl(ctx, left_node, "var"),
        .let_declaration => return parseVarDecl(ctx, left_node, "let"),
        .const_declaration => return parseVarDecl(ctx, left_node, "const"),
        else => {
            // Assignment target (identifier, member expression, pattern)
            return .{
                .keyword = "",
                .binding = getNodeSource(ctx, left_node),
                .is_decl = false,
            };
        },
    }
}

fn parseVarDecl(ctx: *TransformContext, decl_node: NodeIndex, keyword: []const u8) LeftInfo {
    // var_declaration: extra = [range_start, range_end] where range has declarators
    const data = ctx.nodeData(decl_node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) {
        return .{ .keyword = keyword, .binding = "x", .is_decl = true };
    }

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    if (range_start >= range_end) {
        return .{ .keyword = keyword, .binding = "x", .is_decl = true };
    }

    // Get the first (and typically only) declarator
    const first_decl: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_start]);
    if (first_decl == .none) {
        return .{ .keyword = keyword, .binding = "x", .is_decl = true };
    }

    // Declarator: binary.lhs = name/pattern, binary.rhs = init (should be .none for for-of)
    const decl_data = ctx.nodeData(first_decl);
    const name_node = decl_data.binary.lhs;
    if (name_node == .none) {
        return .{ .keyword = keyword, .binding = "x", .is_decl = true };
    }

    return .{
        .keyword = keyword,
        .binding = getNodeSource(ctx, name_node),
        .is_decl = true,
    };
}

// ── Array mode (iterableIsArray / assumeArray) ────────────────────

fn buildArrayMode(
    ctx: *TransformContext,
    node_i: u32,
    left: LeftInfo,
    right_src: []const u8,
    temp_name_hint_src: []const u8,
    prefer_generic_arr_temp: bool,
    body_src: []const u8,
    body_node: NodeIndex,
    suffix: []const u8,
    label_prefix: []const u8,
    is_static: bool,
    needs_body_block: bool,
    is_known_array: bool,
    if_prefix: []const u8,
    if_suffix: []const u8,
) void {
    _ = body_node;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, if_prefix) catch return;

    const iter_name = fmtStr(ctx, "_i{s}", .{suffix});

    // When the iterable is known to be an array (opt mode) and not from
    // iterableIsArray assumption, use "var" instead of "let"
    const loop_var_keyword = if (is_known_array and !g_config.iterable_is_array and !g_config.assume_array) "var" else "let";

    if (is_static) {
        // Static optimization: use the iterable directly, no temp variable
        buf.appendSlice(ctx.allocator, label_prefix) catch return;
        buf.appendSlice(ctx.allocator, "for (") catch return;
        buf.appendSlice(ctx.allocator, loop_var_keyword) catch return;
        buf.appendSlice(ctx.allocator, " ") catch return;
        buf.appendSlice(ctx.allocator, iter_name) catch return;
        buf.appendSlice(ctx.allocator, " = 0; ") catch return;
        buf.appendSlice(ctx.allocator, iter_name) catch return;
        buf.appendSlice(ctx.allocator, " < ") catch return;
        buf.appendSlice(ctx.allocator, right_src) catch return;
        buf.appendSlice(ctx.allocator, ".length; ") catch return;
        buf.appendSlice(ctx.allocator, iter_name) catch return;
        buf.appendSlice(ctx.allocator, "++) {\n") catch return;

        // Assignment line
        emitLeftAssignment(&buf, ctx, left, fmtStr(ctx, "{s}[{s}]", .{ right_src, iter_name }));
    } else {
        // Non-static: use temp variable with unique naming
        const arr_name = if (prefer_generic_arr_temp)
            getUniqueTempName(ctx, "[]")
        else
            getUniqueTempName(ctx, temp_name_hint_src);

        buf.appendSlice(ctx.allocator, label_prefix) catch return;
        buf.appendSlice(ctx.allocator, "for (") catch return;
        buf.appendSlice(ctx.allocator, loop_var_keyword) catch return;
        buf.appendSlice(ctx.allocator, " ") catch return;
        buf.appendSlice(ctx.allocator, iter_name) catch return;
        buf.appendSlice(ctx.allocator, " = 0, ") catch return;
        buf.appendSlice(ctx.allocator, arr_name) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, right_src) catch return;
        buf.appendSlice(ctx.allocator, "; ") catch return;
        buf.appendSlice(ctx.allocator, iter_name) catch return;
        buf.appendSlice(ctx.allocator, " < ") catch return;
        buf.appendSlice(ctx.allocator, arr_name) catch return;
        buf.appendSlice(ctx.allocator, ".length; ") catch return;
        buf.appendSlice(ctx.allocator, iter_name) catch return;
        buf.appendSlice(ctx.allocator, "++) {\n") catch return;

        // Assignment line
        emitLeftAssignment(&buf, ctx, left, fmtStr(ctx, "{s}[{s}]", .{ arr_name, iter_name }));
    }

    // Body content — wrap in extra block if redeclaration detected
    if (needs_body_block) {
        buf.appendSlice(ctx.allocator, "  {\n") catch return;
        emitBodyWithIndent(&buf, ctx, body_src, "    ");
        buf.appendSlice(ctx.allocator, "  }\n") catch return;
    } else {
        emitBodyWithIndent(&buf, ctx, body_src, "  ");
    }

    buf.appendSlice(ctx.allocator, "}") catch return;
    buf.appendSlice(ctx.allocator, if_suffix) catch return;

    ctx.ast.replacement_source.put(ctx.allocator, node_i, buf.items) catch return;
    ctx.ast.replacement_needs_reindent.put(ctx.allocator, node_i, {}) catch {};
}

fn hasArrayTypeCastHint(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    return switch (ctx.nodeTag(node)) {
        .parenthesized_expr, .ts_non_null_expression => hasArrayTypeCastHint(ctx, ctx.nodeData(node).unary),
        .ts_as_expression, .ts_satisfies_expression => isArrayTypeAnnotation(ctx, ctx.nodeData(node).binary.rhs),
        .ts_type_assertion => isArrayTypeAnnotation(ctx, ctx.nodeData(node).binary.lhs),
        .flow_type_cast_expression => blk: {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) break :blk false;
            break :blk isArrayTypeAnnotation(ctx, @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]));
        },
        else => false,
    };
}

// ── Loose mode ────────────────────────────────────────────────────

fn buildLooseMode(
    ctx: *TransformContext,
    node_i: u32,
    left: LeftInfo,
    right_src: []const u8,
    body_src: []const u8,
    body_node: NodeIndex,
    suffix: []const u8,
    label_prefix: []const u8,
    needs_body_block: bool,
    if_prefix: []const u8,
    if_suffix: []const u8,
) void {
    _ = body_node;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, if_prefix) catch return;

    const iter_name = fmtStr(ctx, "_iterator{s}", .{suffix});
    const step_name = fmtStr(ctx, "_step{s}", .{suffix});
    const allow_array_like_arg = if (g_config.allow_array_like) ", true" else "";

    buf.appendSlice(ctx.allocator, label_prefix) catch return;
    buf.appendSlice(ctx.allocator, "for (var ") catch return;
    buf.appendSlice(ctx.allocator, iter_name) catch return;
    buf.appendSlice(ctx.allocator, " = babelHelpers.createForOfIteratorHelperLoose(") catch return;
    buf.appendSlice(ctx.allocator, right_src) catch return;
    buf.appendSlice(ctx.allocator, allow_array_like_arg) catch return;
    buf.appendSlice(ctx.allocator, "), ") catch return;
    buf.appendSlice(ctx.allocator, step_name) catch return;
    buf.appendSlice(ctx.allocator, "; !(") catch return;
    buf.appendSlice(ctx.allocator, step_name) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, iter_name) catch return;
    buf.appendSlice(ctx.allocator, "()).done;) {\n") catch return;

    // Assignment line
    emitLeftAssignment(&buf, ctx, left, fmtStr(ctx, "{s}.value", .{step_name}));

    // Body content
    if (needs_body_block) {
        buf.appendSlice(ctx.allocator, "  {\n") catch return;
        emitBodyWithIndent(&buf, ctx, body_src, "    ");
        buf.appendSlice(ctx.allocator, "  }\n") catch return;
    } else {
        emitBodyWithIndent(&buf, ctx, body_src, "  ");
    }

    buf.appendSlice(ctx.allocator, "}") catch return;
    buf.appendSlice(ctx.allocator, if_suffix) catch return;

    ctx.ast.replacement_source.put(ctx.allocator, node_i, buf.items) catch return;
    ctx.ast.replacement_needs_reindent.put(ctx.allocator, node_i, {}) catch {};
}

// ── Spec mode ─────────────────────────────────────────────────────

fn buildSpecMode(
    ctx: *TransformContext,
    node_i: u32,
    left: LeftInfo,
    right_src: []const u8,
    body_src: []const u8,
    body_node: NodeIndex,
    suffix: []const u8,
    label_prefix: []const u8,
    needs_body_block: bool,
    if_prefix: []const u8,
    if_suffix: []const u8,
) void {
    _ = body_node;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, if_prefix) catch return;

    const iter_name = fmtStr(ctx, "_iterator{s}", .{suffix});
    const step_name = fmtStr(ctx, "_step{s}", .{suffix});
    const allow_array_like_arg = if (g_config.allow_array_like) ", true" else "";

    // When inside an if-block, add extra indentation
    const in_if = if_prefix.len > 0;
    const p = if (in_if) "  " else ""; // prefix for each line

    // var _iterator = babelHelpers.createForOfIteratorHelper(arr),\n    _step;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "var ") catch return;
    buf.appendSlice(ctx.allocator, iter_name) catch return;
    buf.appendSlice(ctx.allocator, " = babelHelpers.createForOfIteratorHelper(") catch return;
    buf.appendSlice(ctx.allocator, right_src) catch return;
    buf.appendSlice(ctx.allocator, allow_array_like_arg) catch return;
    buf.appendSlice(ctx.allocator, "),\n") catch return;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "  ") catch return;
    buf.appendSlice(ctx.allocator, step_name) catch return;
    buf.appendSlice(ctx.allocator, ";\n") catch return;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "try {\n") catch return;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "  ") catch return;
    buf.appendSlice(ctx.allocator, label_prefix) catch return;
    buf.appendSlice(ctx.allocator, "for (") catch return;
    buf.appendSlice(ctx.allocator, iter_name) catch return;
    buf.appendSlice(ctx.allocator, ".s(); !(") catch return;
    buf.appendSlice(ctx.allocator, step_name) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, iter_name) catch return;
    buf.appendSlice(ctx.allocator, ".n()).done;) {\n") catch return;

    // Assignment line (inside try block, extra indent)
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "    ") catch return;
    emitLeftAssignmentInline(&buf, ctx, left, fmtStr(ctx, "{s}.value", .{step_name}));
    buf.append(ctx.allocator, '\n') catch return;

    // Body content (with extra indentation for try block)
    const body_indent = fmtStr(ctx, "{s}    ", .{p});
    const body_block_indent = fmtStr(ctx, "{s}      ", .{p});
    if (needs_body_block) {
        buf.appendSlice(ctx.allocator, p) catch return;
        buf.appendSlice(ctx.allocator, "    {\n") catch return;
        emitBodyWithIndent(&buf, ctx, body_src, body_block_indent);
        buf.appendSlice(ctx.allocator, p) catch return;
        buf.appendSlice(ctx.allocator, "    }\n") catch return;
    } else {
        emitBodyWithIndent(&buf, ctx, body_src, body_indent);
    }

    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "  }\n") catch return;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "} catch (err) {\n") catch return;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "  ") catch return;
    buf.appendSlice(ctx.allocator, iter_name) catch return;
    buf.appendSlice(ctx.allocator, ".e(err);\n") catch return;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "} finally {\n") catch return;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "  ") catch return;
    buf.appendSlice(ctx.allocator, iter_name) catch return;
    buf.appendSlice(ctx.allocator, ".f();\n") catch return;
    buf.appendSlice(ctx.allocator, p) catch return;
    buf.appendSlice(ctx.allocator, "}") catch return;
    buf.appendSlice(ctx.allocator, if_suffix) catch return;

    ctx.ast.replacement_source.put(ctx.allocator, node_i, buf.items) catch return;
    ctx.ast.replacement_needs_reindent.put(ctx.allocator, node_i, {}) catch {};
}

// ── Assignment helpers ────────────────────────────────────────────

fn emitLeftAssignment(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, left: LeftInfo, rhs: []const u8) void {
    buf.appendSlice(ctx.allocator, "  ") catch return;
    emitLeftAssignmentInline(buf, ctx, left, rhs);
    buf.append(ctx.allocator, '\n') catch return;
}

fn emitLeftAssignmentInline(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, left: LeftInfo, rhs: []const u8) void {
    const keyword = if (g_config.rewrite_block_scoped_bindings and
        (std.mem.eql(u8, left.keyword, "let") or std.mem.eql(u8, left.keyword, "const")))
        "var"
    else
        left.keyword;

    if (left.is_decl) {
        const trimmed = std.mem.trim(u8, left.binding, " \t\r\n");
        if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}' and std.mem.indexOfScalar(u8, trimmed, ',') != null) {
            buf.appendSlice(ctx.allocator, keyword) catch return;
            buf.appendSlice(ctx.allocator, " {\n") catch return;
            const inner = trimmed[1 .. trimmed.len - 1];
            var parts: [32][]const u8 = undefined;
            var part_count: usize = 0;
            var iter = std.mem.splitScalar(u8, inner, ',');
            while (iter.next()) |part| {
                const piece = std.mem.trim(u8, part, " \t\r\n");
                if (piece.len == 0) continue;
                if (part_count < parts.len) {
                    parts[part_count] = piece;
                    part_count += 1;
                }
            }
            for (parts[0..part_count], 0..) |piece, idx| {
                buf.appendSlice(ctx.allocator, "    ") catch return;
                buf.appendSlice(ctx.allocator, piece) catch return;
                if (idx + 1 < part_count) {
                    buf.appendSlice(ctx.allocator, ",\n") catch return;
                } else {
                    buf.appendSlice(ctx.allocator, "\n") catch return;
                }
            }
            buf.appendSlice(ctx.allocator, "  } = ") catch return;
            buf.appendSlice(ctx.allocator, rhs) catch return;
            buf.appendSlice(ctx.allocator, ";") catch return;
            return;
        }
        buf.appendSlice(ctx.allocator, keyword) catch return;
        buf.appendSlice(ctx.allocator, " ") catch return;
        buf.appendSlice(ctx.allocator, left.binding) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, rhs) catch return;
        buf.appendSlice(ctx.allocator, ";") catch return;
    } else {
        buf.appendSlice(ctx.allocator, left.binding) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, rhs) catch return;
        buf.appendSlice(ctx.allocator, ";") catch return;
    }
}

// ── Body content helpers ──────────────────────────────────────────

/// Emit body content (inner statements from a block) with given indentation.
/// Strips original indentation and re-indents with the specified prefix.
fn emitBodyWithIndent(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, body_src: []const u8, indent: []const u8) void {
    const open = std.mem.indexOf(u8, body_src, "{") orelse return;
    const close = std.mem.lastIndexOf(u8, body_src, "}") orelse return;
    if (close <= open + 1) return;

    const inner = body_src[open + 1 .. close];

    // Find minimum indentation of non-empty lines
    var min_indent: usize = std.math.maxInt(usize);
    var line_iter = std.mem.splitScalar(u8, inner, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const leading = line.len - trimmed.len;
        if (leading < min_indent) min_indent = leading;
    }
    if (min_indent == std.math.maxInt(usize)) return;

    // Re-emit lines with new indentation
    var line_iter2 = std.mem.splitScalar(u8, inner, '\n');
    var first = true;
    while (line_iter2.next()) |line| {
        const trimmed_right = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed_right.len == 0) {
            if (!first) {
                // Preserve empty lines between statements (skip leading empty lines)
            }
            continue;
        }
        first = false;
        const trimmed_left = std.mem.trimStart(u8, trimmed_right, " \t");
        if (trimmed_left.len == 0) continue;
        const rewritten_left = if (g_config.rewrite_block_scoped_bindings and std.mem.startsWith(u8, trimmed_left, "let "))
            fmtStr(ctx, "var{s}", .{trimmed_left[3..]})
        else if (g_config.rewrite_block_scoped_bindings and std.mem.startsWith(u8, trimmed_left, "const "))
            fmtStr(ctx, "var{s}", .{trimmed_left[5..]})
        else
            trimmed_left;

        // Calculate original indentation and subtract minimum
        const orig_indent = trimmed_right.len - trimmed_left.len;
        const extra_indent = if (orig_indent >= min_indent) orig_indent - min_indent else 0;

        buf.appendSlice(ctx.allocator, indent) catch {};
        // Add extra indentation (for nested structures)
        var ei: usize = 0;
        while (ei < extra_indent) : (ei += 1) {
            buf.append(ctx.allocator, ' ') catch {};
        }
        buf.appendSlice(ctx.allocator, rewritten_left) catch {};
        // Add missing semicolons to statement lines (ASI normalization)
        if (needsSemicolon(rewritten_left)) {
            buf.append(ctx.allocator, ';') catch {};
        }
        buf.append(ctx.allocator, '\n') catch {};
    }
}

/// Check if a line of code needs an automatic semicolon.
/// Returns true for statement lines that don't end with ; { } or are not
/// control-flow keywords (if/else/for/while/do/try/catch/finally/switch).
fn needsSemicolon(line: []const u8) bool {
    if (line.len == 0) return false;
    const last = line[line.len - 1];
    // Already has a semicolon, or is a block/brace
    if (last == ';' or last == '{' or last == '}' or last == ',') return false;
    // Lines ending with // comment — check before the comment
    if (std.mem.indexOf(u8, line, "//") != null) return false;
    // Control flow keywords that don't need semicolons
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.startsWith(u8, trimmed, "if(")) return false;
    if (std.mem.startsWith(u8, trimmed, "else ") or std.mem.eql(u8, trimmed, "else")) return false;
    if (std.mem.startsWith(u8, trimmed, "for ") or std.mem.startsWith(u8, trimmed, "for(")) return false;
    if (std.mem.startsWith(u8, trimmed, "while ") or std.mem.startsWith(u8, trimmed, "while(")) return false;
    if (std.mem.startsWith(u8, trimmed, "do ") or std.mem.eql(u8, trimmed, "do")) return false;
    if (std.mem.startsWith(u8, trimmed, "try ") or std.mem.eql(u8, trimmed, "try")) return false;
    if (std.mem.startsWith(u8, trimmed, "catch ") or std.mem.startsWith(u8, trimmed, "catch(")) return false;
    if (std.mem.startsWith(u8, trimmed, "finally ") or std.mem.eql(u8, trimmed, "finally")) return false;
    if (std.mem.startsWith(u8, trimmed, "switch ") or std.mem.startsWith(u8, trimmed, "switch(")) return false;
    if (std.mem.startsWith(u8, trimmed, "case ")) return false;
    if (std.mem.startsWith(u8, trimmed, "default:")) return false;
    if (std.mem.startsWith(u8, trimmed, "function ") or std.mem.startsWith(u8, trimmed, "function(")) return false;
    if (std.mem.startsWith(u8, trimmed, "class ")) return false;
    // Label-like patterns (e.g. "actions:")
    if (last == ':' and !std.mem.startsWith(u8, trimmed, "return ")) return false;
    return true;
}

// ── Label handling ────────────────────────────────────────────────

const LabelInfo = struct {
    label: ?[]const u8,
    label_node_i: ?u32,
    has_comment: bool = false,
    comment: ?[]const u8 = null,
};

fn findLabelParent(ctx: *TransformContext, for_of_idx: NodeIndex) LabelInfo {
    ensureLabelParentCache(ctx);
    const for_of_i = @intFromEnum(for_of_idx);
    if (for_of_i >= g_label_parent_cache.len) {
        return .{ .label = null, .label_node_i = null };
    }
    const cached = g_label_parent_cache[for_of_i];
    if (cached.label_node_i_plus1 == 0) {
        return .{ .label = null, .label_node_i = null };
    }

    const label_node_i = cached.label_node_i_plus1 - 1;
    const label_tok = ctx.ast.nodes.items(.main_token)[label_node_i];
    const comment = if (cached.comment_end > cached.comment_start)
        ctx.ast.source[cached.comment_start..cached.comment_end]
    else
        null;

    return .{
        .label = ctx.tokenSlice(label_tok),
        .label_node_i = label_node_i,
        .has_comment = comment != null,
        .comment = comment,
    };
}

fn ensureLabelParentCache(ctx: *TransformContext) void {
    if (g_label_parent_ast == ctx.ast) return;
    g_label_parent_ast = ctx.ast;
    const node_count = ctx.ast.nodes.items(.tag).len;
    g_label_parent_cache = ctx.allocator.alloc(CachedLabelInfo, node_count) catch &[_]CachedLabelInfo{};
    for (g_label_parent_cache) |*entry| entry.* = .{};

    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        if (tag != .labeled_statement) continue;
        const body = datas[ni].unary;
        const body_i = @intFromEnum(body);
        if (body == .none or body_i >= g_label_parent_cache.len) continue;

        const label_tok = ctx.ast.nodes.items(.main_token)[ni];
        const label_src = ctx.tokenSlice(label_tok);
        const label_end = ctx.ast.tokens.items(.start)[@intFromEnum(label_tok)] + @as(u32, @intCast(label_src.len));
        const body_start = getNodeStart(ctx, body);
        var comment_start: u32 = 0;
        var comment_end: u32 = 0;
        if (body_start > label_end + 2) {
            const between = ctx.ast.source[label_end..body_start];
            if (std.mem.indexOf(u8, between, "//")) |offset| {
                comment_start = label_end + @as(u32, @intCast(offset));
                comment_end = comment_start;
                while (comment_end < body_start and ctx.ast.source[comment_end] != '\n') : (comment_end += 1) {}
            }
        }

        g_label_parent_cache[body_i] = .{
            .label_node_i_plus1 = @intCast(ni + 1),
            .comment_start = comment_start,
            .comment_end = comment_end,
        };
    }
}

/// Find if the given node is a direct child of an if-statement (no braces).
/// Returns the if-statement node index if found, so the replacement
/// targets the if-statement instead.
fn findIfParent(ctx: *TransformContext, node_idx: NodeIndex) ?u32 {
    ensureIfParentCache(ctx);
    const ni = @intFromEnum(node_idx);
    if (ni >= g_if_parent_cache.len) return null;
    const parent = g_if_parent_cache[ni];
    return if (parent == 0) null else parent - 1;
}

fn ensureIfParentCache(ctx: *TransformContext) void {
    if (g_if_parent_ast == ctx.ast) return;
    g_if_parent_ast = ctx.ast;
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    g_if_parent_cache = ctx.allocator.alloc(u32, tags.len) catch &[_]u32{};
    @memset(g_if_parent_cache, 0);

    for (tags, 0..) |tag, parent_ni| {
        if (tag != .if_statement) continue;
        const d = datas[parent_ni];
        // if_statement: extra[0]=test, extra[1]=consequent, extra[2]=alternate
        const eidx = @intFromEnum(d.extra);
        if (eidx + 2 >= ctx.ast.extra_data.items.len) continue;
        const consequent_raw = ctx.ast.extra_data.items[eidx + 1];
        if (consequent_raw >= g_if_parent_cache.len) continue;
        const consequent: NodeIndex = @enumFromInt(consequent_raw);
        if (consequent == .none or ctx.nodeTag(consequent) == .block_statement) continue;
        g_if_parent_cache[consequent_raw] = @intCast(parent_ni + 1);
    }
}

// ── Utility helpers ───────────────────────────────────────────────

/// Detect if the right-hand side is a known array-producing expression:
/// - Array literal: `[]`, `[1, 2, 3]`
/// - `Array.from(...)`, `Object.keys(...)`, `Object.values(...)`, `Object.entries(...)`
fn isKnownArrayIterable(ctx: *TransformContext, right_node: NodeIndex) bool {
    if (right_node == .none) return false;
    ensureKnownArrayCache(ctx);
    const ni = @intFromEnum(right_node);
    if (ni < g_known_array_cache.len) {
        switch (g_known_array_cache[ni]) {
            1 => return false,
            2 => return true,
            else => {},
        }
    }
    const result = computeKnownArrayIterable(ctx, right_node);
    if (ni < g_known_array_cache.len) {
        g_known_array_cache[ni] = if (result) 2 else 1;
    }
    return result;
}

fn ensureKnownArrayCache(ctx: *TransformContext) void {
    if (g_known_array_ast == ctx.ast) return;
    g_known_array_ast = ctx.ast;
    g_known_array_cache = ctx.allocator.alloc(u8, ctx.ast.nodes.items(.tag).len) catch &[_]u8{};
    @memset(g_known_array_cache, 0);
}

fn computeKnownArrayIterable(ctx: *TransformContext, right_node: NodeIndex) bool {
    if (right_node == .none) return false;
    const tag = ctx.nodeTag(right_node);
    const src = getNodeSource(ctx, right_node);

    if (std.mem.indexOf(u8, src, " as Array<") != null or
        std.mem.indexOf(u8, src, " as readonly ") != null or
        std.mem.indexOf(u8, src, " as ") != null and std.mem.endsWith(u8, src, "[])"))
    {
        return true;
    }

    switch (tag) {
        .parenthesized_expr, .ts_non_null_expression => {
            return isKnownArrayIterable(ctx, ctx.nodeData(right_node).unary);
        },
        .ts_as_expression, .ts_satisfies_expression => {
            const data = ctx.nodeData(right_node);
            if (isArrayTypeAnnotation(ctx, data.binary.rhs)) return true;
            return isKnownArrayIterable(ctx, data.binary.lhs);
        },
        .ts_type_assertion => {
            const data = ctx.nodeData(right_node);
            if (isArrayTypeAnnotation(ctx, data.binary.lhs)) return true;
            return isKnownArrayIterable(ctx, data.binary.rhs);
        },
        .flow_type_cast_expression => {
            const extra_idx = @intFromEnum(ctx.nodeData(right_node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
            const expr_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const type_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            if (isArrayTypeAnnotation(ctx, type_node)) return true;
            return isKnownArrayIterable(ctx, expr_node);
        },
        else => {},
    }

    // Array literal
    if (tag == .array_expr) return true;

    // Check for Array.from(), Object.keys/values/entries()
    if (tag == .call_expr or tag == .optional_call_expr) {
        const data = ctx.nodeData(right_node);
        const eidx = @intFromEnum(data.extra);
        if (eidx >= ctx.ast.extra_data.items.len) return false;
        const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
        if (callee == .none) return false;

        const callee_src = getNodeSource(ctx, callee);
        if (std.mem.eql(u8, callee_src, "Array.from") or
            std.mem.eql(u8, callee_src, "Object.keys") or
            std.mem.eql(u8, callee_src, "Object.values") or
            std.mem.eql(u8, callee_src, "Object.entries"))
        {
            return true;
        }
    }

    // Check if the right side is an identifier bound to an array-producing expression
    // (e.g., `const arr = []` or `const arr = Object.entries(x)`)
    if (tag == .identifier) {
        if (isIdentifierBoundToArray(ctx, right_node)) return true;
        // Check if the identifier is a rest parameter (always an array)
        if (isRestParameter(ctx, right_node)) return true;
    }

    return false;
}

fn getRuntimeIterableNode(ctx: *TransformContext, node: NodeIndex) NodeIndex {
    if (node == .none) return node;
    return switch (ctx.nodeTag(node)) {
        .parenthesized_expr, .ts_non_null_expression => getRuntimeIterableNode(ctx, ctx.nodeData(node).unary),
        .ts_as_expression, .ts_satisfies_expression => getRuntimeIterableNode(ctx, ctx.nodeData(node).binary.lhs),
        .ts_type_assertion => getRuntimeIterableNode(ctx, ctx.nodeData(node).binary.rhs),
        .flow_type_cast_expression => blk: {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) break :blk node;
            break :blk getRuntimeIterableNode(ctx, @enumFromInt(ctx.ast.extra_data.items[extra_idx]));
        },
        else => node,
    };
}

fn isArrayTypeAnnotation(ctx: *TransformContext, type_node: NodeIndex) bool {
    if (type_node == .none) return false;
    const src = getNodeSource(ctx, type_node);
    if (src.len == 0) return false;
    if (std.mem.startsWith(u8, src, "Array<")) return true;
    if (std.mem.endsWith(u8, src, "[]")) return true;
    if (std.mem.eql(u8, src, "any[]")) return true;
    return false;
}

/// Check if an identifier is a rest parameter of an enclosing function.
/// Rest parameters are always arrays.
fn isRestParameter(ctx: *TransformContext, ident_node: NodeIndex) bool {
    const binding = resolveBinding(ctx, ident_node) orelse return false;
    return binding.is_rest_param;
}

/// Check if an identifier is bound to a known array-producing initializer
/// by scanning preceding var/let/const declarations.
fn isIdentifierBoundToArray(ctx: *TransformContext, ident_node: NodeIndex) bool {
    const binding = resolveBinding(ctx, ident_node) orelse return false;
    switch (binding.kind) {
        .var_decl, .let_decl, .const_decl => {},
        else => return false,
    }
    const init_node = getRuntimeIterableNode(ctx, binding.init_node);
    if (init_node == .none) return false;
    const init_tag = ctx.nodeTag(init_node);
    if (init_tag == .array_expr) return true;
    if (init_tag != .call_expr and init_tag != .optional_call_expr) return false;

    const init_data = ctx.nodeData(init_node);
    const init_eidx = @intFromEnum(init_data.extra);
    if (init_eidx >= ctx.ast.extra_data.items.len) return false;
    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[init_eidx]);
    if (callee == .none) return false;
    const callee_src = getNodeSource(ctx, callee);
    return std.mem.eql(u8, callee_src, "Array.from") or
        std.mem.eql(u8, callee_src, "Object.keys") or
        std.mem.eql(u8, callee_src, "Object.values") or
        std.mem.eql(u8, callee_src, "Object.entries");
}

/// Determine if the iterable is "static" — i.e. a simple identifier whose value
/// won't change during the loop, so we can use `iterable.length` and `iterable[_i]`
/// directly without creating a temporary `_array` variable.
///
/// An iterable is static if:
/// - It's a simple identifier AND
/// - It's declared as `const` or is an `import` binding
fn isStaticIterable(ctx: *TransformContext, right_node: NodeIndex, right_src: []const u8, body_src: []const u8) bool {
    // Must be a simple identifier
    if (!isSimpleIdentifier(right_src)) return false;

    // Check if the identifier is redeclared in the loop body
    // (e.g., `for (let o of arr) { const arr = ... }`)
    if (containsWholeWord(body_src, right_src)) {
        // Check if the body contains a declaration of this name
        // Simple heuristic: look for `const name`, `let name`, `var name`
        const patterns = [_][]const u8{ "const ", "let ", "var " };
        for (patterns) |kw| {
            var search_start: usize = 0;
            while (search_start < body_src.len) {
                const kw_pos = std.mem.indexOf(u8, body_src[search_start..], kw) orelse break;
                const abs_kw = search_start + kw_pos;
                const after_kw = abs_kw + kw.len;
                // Check if the name follows this keyword
                if (after_kw + right_src.len <= body_src.len and
                    std.mem.eql(u8, body_src[after_kw .. after_kw + right_src.len], right_src))
                {
                    // Make sure it's a whole word
                    const end_pos = after_kw + right_src.len;
                    if (end_pos >= body_src.len or
                        (!std.ascii.isAlphanumeric(body_src[end_pos]) and body_src[end_pos] != '_' and body_src[end_pos] != '$'))
                    {
                        return false; // Redeclared in body
                    }
                }
                search_start = abs_kw + 1;
            }
        }
    }

    // Check if the identifier is declared as const or is an import
    return isConstOrImportBinding(ctx, right_node, right_src);
}

/// Check if an identifier is declared as `const` or is an `import` binding.
fn isConstOrImportBinding(ctx: *TransformContext, ident_node: NodeIndex, name: []const u8) bool {
    if (resolveBinding(ctx, ident_node)) |binding| {
        return binding.kind == .const_decl or binding.kind == .import_binding;
    }
    const scope_result = ctx.scope orelse return false;
    const scope_idx = scope_mod.getScopeForNode(scope_result, ident_node) orelse return false;
    const binding = scope_mod.getBinding(scope_result, scope_idx, name) orelse return false;
    return binding.kind == .const_decl or binding.kind == .import_binding;
}

fn resolveBinding(ctx: *TransformContext, ident_node: NodeIndex) ?*const scope_mod.Binding {
    if (ident_node == .none or ctx.nodeTag(ident_node) != .identifier) return null;
    if (ctx.getBindingForNode(ident_node)) |binding| return binding;
    const scope_result = ctx.scope orelse return null;
    const name = ctx.tokenSlice(ctx.mainToken(ident_node));
    return scope_mod.resolveBindingForNode(scope_result, ident_node, name);
}

/// Check if text contains a whole-word occurrence of name.
fn containsWholeWord(text: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i + name.len <= text.len) {
        const pos = std.mem.indexOf(u8, text[i..], name) orelse return false;
        const abs = i + pos;
        const before_ok = abs == 0 or (!std.ascii.isAlphanumeric(text[abs - 1]) and text[abs - 1] != '_' and text[abs - 1] != '$');
        const after_pos = abs + name.len;
        const after_ok = after_pos >= text.len or (!std.ascii.isAlphanumeric(text[after_pos]) and text[after_pos] != '_' and text[after_pos] != '$');
        if (before_ok and after_ok) return true;
        i = abs + 1;
    }
    return false;
}

/// Detect if any of the binding names from the for-of left side are redeclared
/// in the loop body. If so, the body needs to be wrapped in an extra block.
fn detectRedeclaration(ctx: *TransformContext, left: LeftInfo, body_node: NodeIndex) bool {
    if (!left.is_decl) return false;
    if (body_node == .none) return false;

    // Get all binding names from the left side
    const binding = left.binding;

    // Check the body for const/let declarations with the same name
    return checkBodyForRedeclaration(ctx, binding, body_node);
}

fn checkBodyForRedeclaration(ctx: *TransformContext, binding: []const u8, body_node: NodeIndex) bool {
    const tag = ctx.nodeTag(body_node);
    if (tag != .block_statement) return false;

    const data = ctx.nodeData(body_node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    // Extract individual names from the binding pattern
    var names_buf: [16][]const u8 = undefined;
    var names_count: usize = 0;
    extractBindingNames(binding, &names_buf, &names_count);

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        const stmt_tag = ctx.nodeTag(stmt);

        if (stmt_tag == .const_declaration or stmt_tag == .let_declaration or stmt_tag == .var_declaration) {
            // Check if any declarator name matches a binding name
            const decl_data = ctx.nodeData(stmt);
            const decl_extra = @intFromEnum(decl_data.extra);
            if (decl_extra + 1 >= ctx.ast.extra_data.items.len) continue;
            const decl_start = ctx.ast.extra_data.items[decl_extra];
            const decl_end = ctx.ast.extra_data.items[decl_extra + 1];

            for (ctx.ast.extra_data.items[decl_start..decl_end]) |declarator_raw| {
                const declarator: NodeIndex = @enumFromInt(declarator_raw);
                if (declarator == .none) continue;
                const decl_d = ctx.nodeData(declarator);
                const name_node = decl_d.binary.lhs;
                if (name_node == .none) continue;
                const name_src = getNodeSource(ctx, name_node);

                for (names_buf[0..names_count]) |bname| {
                    if (std.mem.eql(u8, name_src, bname)) return true;
                }
            }
        }
    }
    return false;
}

/// Extract individual identifier names from a binding pattern string.
/// Handles simple identifiers, array patterns [a, b], object patterns {a, b}.
fn extractBindingNames(binding: []const u8, buf: [][]const u8, count: *usize) void {
    count.* = 0;
    const trimmed = std.mem.trim(u8, binding, " \t\r\n");
    if (trimmed.len == 0) return;

    // Simple identifier
    if (isSimpleIdentifier(trimmed)) {
        if (count.* < buf.len) {
            buf[count.*] = trimmed;
            count.* += 1;
        }
        return;
    }

    // Array or object pattern — extract identifiers
    var i: usize = 0;
    while (i < trimmed.len) {
        // Skip non-identifier chars
        while (i < trimmed.len and !std.ascii.isAlphabetic(trimmed[i]) and trimmed[i] != '_' and trimmed[i] != '$') : (i += 1) {}
        if (i >= trimmed.len) break;

        const start = i;
        while (i < trimmed.len and (std.ascii.isAlphanumeric(trimmed[i]) or trimmed[i] == '_' or trimmed[i] == '$')) : (i += 1) {}
        const name = trimmed[start..i];

        // Skip keywords like 'const', 'let', 'var'
        if (std.mem.eql(u8, name, "const") or std.mem.eql(u8, name, "let") or std.mem.eql(u8, name, "var")) continue;

        if (count.* < buf.len) {
            buf[count.*] = name;
            count.* += 1;
        }
    }
}

/// Get a unique temp variable name for the array, tracking used names.
/// First use of a base name gets no suffix, second gets "2", third gets "3", etc.
fn getUniqueTempName(ctx: *TransformContext, right_src: []const u8) []const u8 {
    const base = buildArrayTempBaseName(ctx, right_src);

    // Track how many times this base name has been used
    const gop = g_used_temp_names.getOrPut(ctx.allocator, base) catch return base;
    if (gop.found_existing) {
        gop.value_ptr.* += 1;
        return fmtStr(ctx, "{s}{d}", .{ base, gop.value_ptr.* });
    } else {
        gop.value_ptr.* = 1;
        return base;
    }
}

fn buildArrayTempBaseName(ctx: *TransformContext, right_src: []const u8) []const u8 {
    return buildArrayTempName(ctx, right_src, "");
}

fn buildArrayTempName(ctx: *TransformContext, right_src: []const u8, suffix: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, right_src, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '[') {
        const base = if (g_config.iterable_is_array or g_config.assume_array) "_ref" else "_arr";
        return fmtStr(ctx, "{s}{s}", .{ base, suffix });
    }
    // If the right side is a simple identifier, use _identifier as temp name
    if (isSimpleIdentifier(right_src)) {
        return fmtStr(ctx, "_{s}{s}", .{ right_src, suffix });
    }
    // For member expression calls like Array.from(x), Object.keys(x), etc.
    // Babel uses the pattern _Member$method: _Array$from, _Object$keys, etc.
    if (std.mem.indexOf(u8, right_src, ".")) |dot_pos| {
        // Check if it's a call expression: Obj.method(...)
        if (std.mem.indexOf(u8, right_src[dot_pos..], "(")) |_| {
            const obj = right_src[0..dot_pos];
            const rest = right_src[dot_pos + 1 ..];
            // Find end of method name (before '(')
            if (std.mem.indexOf(u8, rest, "(")) |paren_pos| {
                const method = rest[0..paren_pos];
                if (isSimpleIdentifier(obj) and isSimpleIdentifier(method)) {
                    return fmtStr(ctx, "_{s}${s}{s}", .{ obj, method, suffix });
                }
            }
        }
    }
    return fmtStr(ctx, "_arr{s}", .{suffix});
}

fn isSimpleIdentifier(src: []const u8) bool {
    if (src.len == 0) return false;
    if (!std.ascii.isAlphabetic(src[0]) and src[0] != '_' and src[0] != '$') return false;
    for (src[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    }
    return true;
}

fn isSimpleRightSide(src: []const u8) bool {
    for (src) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    }
    return src.len > 0;
}

/// Get the indentation (number of leading spaces) of the line containing position pos.
fn getLineIndent(source: []const u8, pos: u32) u32 {
    var line_start: u32 = pos;
    while (line_start > 0 and source[line_start - 1] != '\n') {
        line_start -= 1;
    }
    var spaces: u32 = 0;
    while (line_start + spaces < source.len and source[line_start + spaces] == ' ') {
        spaces += 1;
    }
    return spaces;
}

/// Build an indent string of n spaces.
fn makeIndent(ctx: *TransformContext, n: u32) []const u8 {
    if (n == 0) return "";
    const capped = @min(n, 64);
    const spaces = ctx.allocator.alloc(u8, capped) catch return "";
    @memset(spaces, ' ');
    return spaces;
}

fn numSuffix(ctx: *TransformContext, n: u32) []const u8 {
    return std.fmt.allocPrint(ctx.allocator, "{d}", .{n}) catch "";
}

fn fmtStr(ctx: *TransformContext, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(ctx.allocator, fmt, args) catch "";
}

fn getBodySource(ctx: *TransformContext, body_node: NodeIndex) []const u8 {
    if (body_node == .none) return "{}";
    const tag = ctx.nodeTag(body_node);

    if (tag == .empty_statement) return "{}";

    if (tag != .block_statement) {
        // Expression statement body — wrap in braces
        const stmt_src = getNodeSource(ctx, body_node);
        return fmtStr(ctx, "{{\n  {s}\n}}", .{stmt_src});
    }

    // For block statements, reconstruct from children to pick up replacements
    const data = ctx.nodeData(body_node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return "{}";

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    // Check if any child has a replacement_source
    var has_replacements = false;
    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (ctx.ast.replacement_source.get(stmt_raw) != null) {
            has_replacements = true;
            break;
        }
    }

    if (!has_replacements) {
        return getNodeSource(ctx, body_node);
    }

    // Reconstruct body with replacements (no extra indentation — callers handle it)
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "{\n") catch return "{}";

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        if (stmt_raw < ctx.ast.nodes.items(.tag).len and ctx.ast.nodes.items(.tag)[stmt_raw] == .removed) continue;

        const stmt_src = getNodeSource(ctx, stmt);
        if (stmt_src.len == 0) continue;

        buf.appendSlice(ctx.allocator, stmt_src) catch {};
        buf.append(ctx.allocator, '\n') catch {};
    }

    buf.appendSlice(ctx.allocator, "}") catch {};
    return buf.items;
}

// ── Source text helpers ──────────────────────────────────────────────

fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
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
