const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");
const Codegen = @import("../codegen.zig").Codegen;
const scope_mod = @import("../scope.zig");

/// Configuration for the destructuring transform.
pub const Config = struct {
    /// Use loose mode: use direct property access without babelHelpers.
    loose: bool = false,
    /// Use built-in helpers where Babel prefers them.
    use_builtins: bool = false,
    /// Use iterableIsArray assumption.
    iterable_is_array: bool = false,
    /// Use objectRestNoSymbols assumption.
    object_rest_no_symbols: bool = false,
    /// Use arrayLikeIsIterable assumption.
    array_like_is_iterable: bool = false,
    /// When true, emit `var` for let/const replacement strings to match a
    /// subsequent block-scoping transform that cannot rewrite replacement strings.
    rewrite_block_scoped_bindings: bool = false,
    /// When true, only lower object-rest/spread semantics and leave plain
    /// destructuring shapes intact.
    rest_only: bool = false,
};

var g_config: Config = .{};

/// Global counter for generating unique _ref names.
var g_ref_counter: u32 = 0;
pub var g_body_temps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)) = .empty;

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.var_declaration));
    filter.set(@intFromEnum(Node.Tag.let_declaration));
    filter.set(@intFromEnum(Node.Tag.const_declaration));
    filter.set(@intFromEnum(Node.Tag.for_in_statement));
    filter.set(@intFromEnum(Node.Tag.for_of_statement));
    filter.set(@intFromEnum(Node.Tag.assignment_expr));
    return .{
        .name = "destructuring",
        .node_filter = filter,
        .exit = enterNode,
        .priority = 28, // Run before block-scoping (30) but after block-scoped-functions (25)
    };
}

pub fn resetState() void {
    g_ref_counter = 0;
    g_used_names = .{};
    g_body_temps = .{};
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .var_declaration, .let_declaration, .const_declaration => handleVarDecl(idx, ctx),
        .for_in_statement, .for_of_statement => handleForInStatement(idx, ctx),
        .assignment_expr => handleAssignmentExpr(idx, ctx),
        else => {},
    }
    return .continue_traversal;
}

/// Handle a variable declaration that may contain destructuring patterns.
fn handleVarDecl(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const tag = ctx.nodeTag(idx);

    // Declaration data: extra[0] = range_start, extra[1] = range_end
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    if (range_end - range_start == 1) {
        const only_decl_idx = ctx.ast.extra_data.items[range_start];
        if (only_decl_idx < ctx.ast.nodes.len and ctx.ast.nodes.items(.tag)[only_decl_idx] == .declarator) {
            const only_decl_data = ctx.ast.nodes.items(.data)[only_decl_idx];
            const only_lhs = only_decl_data.binary.lhs;
            const only_rhs = only_decl_data.binary.rhs;
            if (only_lhs != .none and ctx.nodeTag(only_lhs) == .object_pattern) {
                const standalone = buildStandaloneNestedDefaultObjectDecl(ctx, only_lhs, only_rhs);
                if (standalone.len > 0) {
                    putVarDeclReplacement(ctx, idx, standalone, range_start, range_end);
                    return;
                }
            }
        }
    }

    if (isBareDestructuringForInLeft(ctx, idx, range_start, range_end)) return;

    // Check if any declarator has a destructuring pattern
    var has_destructuring = false;
    var needs_var_keyword = tag == .var_declaration;
    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_idx| {
        if (decl_idx >= ctx.ast.nodes.len) continue;
        const decl_tag = ctx.ast.nodes.items(.tag)[decl_idx];
        if (decl_tag != .declarator) continue;

        const decl_data = ctx.ast.nodes.items(.data)[decl_idx];
        const lhs = decl_data.binary.lhs;
        const rhs = decl_data.binary.rhs;
        if (lhs == .none) continue;

        const lhs_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(lhs)];
        if (lhs_tag == .object_pattern or lhs_tag == .array_pattern) {
            if (g_config.rest_only and !patternNeedsObjectRestTransform(ctx, lhs)) continue;
            has_destructuring = true;
            if (destructuringDeclNeedsVarKeyword(ctx, lhs, rhs)) {
                needs_var_keyword = true;
            }
            break;
        }
    }

    if (tag == .let_declaration and isInForHead(ctx, idx)) {
        needs_var_keyword = true;
    }

    if (!has_destructuring) return;

    const rewrite_block_scoped_keyword = g_config.rewrite_block_scoped_bindings and (tag == .let_declaration or tag == .const_declaration);
    const keyword = if (rewrite_block_scoped_keyword)
        "var"
    else if (tag == .const_declaration)
        "const"
    else if (tag == .let_declaration)
        (if (needs_var_keyword) "var" else "let")
    else
        "var";

    // Build replacement source for the entire declaration
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, keyword) catch return;
    buf.append(ctx.allocator, ' ') catch return;

    var first_declarator = true;

    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_idx| {
        if (decl_idx >= ctx.ast.nodes.len) continue;
        const decl_tag = ctx.ast.nodes.items(.tag)[decl_idx];
        if (decl_tag != .declarator) continue;

        const decl_data = ctx.ast.nodes.items(.data)[decl_idx];
        const lhs = decl_data.binary.lhs;
        const rhs = decl_data.binary.rhs;
        if (lhs == .none) continue;

        const lhs_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(lhs)];

        if (lhs_tag == .object_pattern) {
            // Check for empty object pattern: var {} = expr → babelHelpers.objectDestructuringEmpty(expr)
            if (isEmptyPattern(ctx, lhs)) {
                // Empty object pattern
                const init_source = if (rhs != .none) getNodeSource(ctx, rhs) else "undefined";
                // For empty patterns, emit as standalone statement (not part of var declaration)
                buf.items.len = 0; // Clear the "var " prefix
                buf.appendSlice(ctx.allocator, "babelHelpers.objectDestructuringEmpty(") catch return;
                buf.appendSlice(ctx.allocator, init_source) catch return;
                buf.appendSlice(ctx.allocator, ")") catch return;
                first_declarator = false;
            } else {
                emitObjectDestructuring(ctx, lhs, rhs, &buf, &first_declarator);
            }
        } else if (lhs_tag == .array_pattern) {
            emitArrayDestructuring(ctx, lhs, rhs, &buf, &first_declarator);
        } else {
            // Non-destructuring declarator: keep as-is
            if (!first_declarator) {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            }
            first_declarator = false;

            const lhs_source = rewriteLoopBodyBlockScopedBindingName(ctx, lhs, getNodeSource(ctx, lhs));
            buf.appendSlice(ctx.allocator, lhs_source) catch return;

            if (rhs != .none) {
                buf.appendSlice(ctx.allocator, " = ") catch return;
                const rhs_source = getNodeSource(ctx, rhs);
                buf.appendSlice(ctx.allocator, rhs_source) catch return;
            } else if (g_config.rewrite_block_scoped_bindings and (tag == .let_declaration or tag == .const_declaration) and !isInForHead(ctx, idx)) {
                buf.appendSlice(ctx.allocator, " = void 0") catch return;
            }
        }
    }

    if (first_declarator) {
        ctx.ast.nodes.items(.tag)[@intFromEnum(idx)] = .removed;
        return;
    }

    // Add semicolon since replacement_source bypasses the normal emitVarDeclaration
    // which adds it.
    buf.append(ctx.allocator, ';') catch return;

    const replacement = applyStatementIndent(ctx, idx, buf.items);
    putVarDeclReplacement(ctx, idx, replacement, range_start, range_end);
}

fn putVarDeclReplacement(
    ctx: *TransformContext,
    decl_idx: NodeIndex,
    replacement: []const u8,
    range_start: u32,
    range_end: u32,
) void {
    const target = findExportNamedDeclParent(ctx, decl_idx) orelse {
        ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(decl_idx), replacement) catch {};
        return;
    };
    const export_replacement = buildExportedDeclReplacement(ctx, replacement, range_start, range_end) orelse {
        ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(decl_idx), replacement) catch {};
        return;
    };
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(target), export_replacement) catch {};
}

fn applyStatementIndent(ctx: *TransformContext, node: NodeIndex, replacement: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, replacement, '\n') == null) return replacement;

    const indent = getNodeLineIndent(ctx, node);
    if (indent.len == 0) return replacement;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var start: usize = 0;
    while (start < replacement.len) {
        const nl = std.mem.indexOfScalarPos(u8, replacement, start, '\n') orelse {
            buf.appendSlice(ctx.allocator, replacement[start..]) catch return replacement;
            break;
        };
        buf.appendSlice(ctx.allocator, replacement[start .. nl + 1]) catch return replacement;
        if (nl + 1 < replacement.len) {
            buf.appendSlice(ctx.allocator, indent) catch return replacement;
        }
        start = nl + 1;
    }

    return buf.items;
}

fn getNodeLineIndent(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return "";
    const start = ctx.ast.tokens.items(.start)[@intFromEnum(ctx.ast.nodes.items(.main_token)[ni])];
    if (start == 0 or start > ctx.ast.source.len) return "";

    var line_start = start;
    while (line_start > 0 and ctx.ast.source[line_start - 1] != '\n' and ctx.ast.source[line_start - 1] != '\r') : (line_start -= 1) {}

    var pos = line_start;
    while (pos < start and (ctx.ast.source[pos] == ' ' or ctx.ast.source[pos] == '\t')) : (pos += 1) {}
    if (pos != start) return "";
    return ctx.ast.source[line_start..start];
}

fn findExportNamedDeclParent(ctx: *TransformContext, decl_idx: NodeIndex) ?NodeIndex {
    const parent = findParentOf(ctx, decl_idx) orelse return null;
    if (ctx.nodeTag(parent) != .export_named) return null;
    const data = ctx.nodeData(parent);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 3 >= ctx.ast.extra_data.items.len) return null;
    const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
    if (decl_raw != @intFromEnum(decl_idx)) return null;
    return parent;
}

fn buildExportedDeclReplacement(
    ctx: *TransformContext,
    replacement: []const u8,
    range_start: u32,
    range_end: u32,
) ?[]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_raw| {
        if (decl_raw >= ctx.ast.nodes.len) continue;
        const decl: NodeIndex = @enumFromInt(decl_raw);
        if (ctx.nodeTag(decl) != .declarator) continue;
        collectBoundNames(ctx, ctx.nodeData(decl).binary.lhs, &names);
    }
    if (names.items.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, replacement) catch return null;
    if (replacement.len == 0 or replacement[replacement.len - 1] != '\n') {
        buf.append(ctx.allocator, '\n') catch return null;
    }
    buf.appendSlice(ctx.allocator, "export { ") catch return null;
    for (names.items, 0..) |name, idx| {
        if (idx > 0) buf.appendSlice(ctx.allocator, ", ") catch return null;
        buf.appendSlice(ctx.allocator, name) catch return null;
    }
    buf.appendSlice(ctx.allocator, " };") catch return null;
    return buf.items;
}

fn collectBoundNames(ctx: *TransformContext, pattern: NodeIndex, names: *std.ArrayListUnmanaged([]const u8)) void {
    if (pattern == .none) return;
    switch (ctx.nodeTag(pattern)) {
        .identifier => appendUniqueBoundName(ctx, names, ctx.tokenSlice(ctx.mainToken(pattern))),
        .object_pattern => {
            const data = ctx.nodeData(pattern);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
            const props_start = ctx.ast.extra_data.items[extra_idx];
            const props_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[props_start..props_end]) |prop_raw| {
                if (prop_raw >= ctx.ast.nodes.len) continue;
                const prop: NodeIndex = @enumFromInt(prop_raw);
                switch (ctx.nodeTag(prop)) {
                    .rest_element => collectBoundNames(ctx, ctx.nodeData(prop).unary, names),
                    .shorthand_property => {
                        const value = ctx.nodeData(prop).unary;
                        if (value != .none) {
                            collectBoundNames(ctx, value, names);
                        } else {
                            appendUniqueBoundName(ctx, names, ctx.tokenSlice(ctx.mainToken(prop)));
                        }
                    },
                    .property => collectBoundNames(ctx, ctx.nodeData(prop).binary.rhs, names),
                    .assignment_pattern => collectBoundNames(ctx, ctx.nodeData(prop).binary.lhs, names),
                    else => {},
                }
            }
        },
        .array_pattern => {
            const data = ctx.nodeData(pattern);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
            const elems_start = ctx.ast.extra_data.items[extra_idx];
            const elems_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[elems_start..elems_end]) |elem_raw| {
                if (elem_raw >= ctx.ast.nodes.len) continue;
                collectBoundNames(ctx, @enumFromInt(elem_raw), names);
            }
        },
        .rest_element => collectBoundNames(ctx, ctx.nodeData(pattern).unary, names),
        .assignment_pattern => collectBoundNames(ctx, ctx.nodeData(pattern).binary.lhs, names),
        else => {},
    }
}

fn appendUniqueBoundName(
    ctx: *TransformContext,
    names: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
) void {
    if (name.len == 0) return;
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    names.append(ctx.allocator, name) catch {};
}

fn buildStandaloneNestedDefaultObjectDecl(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) []const u8 {
    if (pattern == .none or init == .none) return "";
    if (ctx.nodeTag(pattern) != .object_pattern or ctx.nodeTag(init) != .identifier) return "";

    const pattern_data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(pattern_data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return "";
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    if (re - rs != 1) return "";

    const prop_idx = ctx.ast.extra_data.items[rs];
    if (prop_idx >= ctx.ast.nodes.len) return "";
    if (ctx.ast.nodes.items(.tag)[prop_idx] != .property) return "";

    const prop_data = ctx.ast.nodes.items(.data)[prop_idx];
    const key_node = prop_data.binary.lhs;
    const value_node = prop_data.binary.rhs;
    if (key_node == .none or value_node == .none or ctx.nodeTag(value_node) != .assignment_pattern) return "";

    const assign_data = ctx.nodeData(value_node);
    const target = assign_data.binary.lhs;
    const default_val = assign_data.binary.rhs;
    if (target == .none or default_val == .none) return "";
    const target_tag = ctx.nodeTag(target);
    if (target_tag != .object_pattern and target_tag != .array_pattern) return "";

    const init_source = getInitSource(ctx, init);
    const key_source = getNodeSource(ctx, key_node);
    const temp_name = allocRefName(ctx, init_source, key_source);
    const default_source = getNodeSource(ctx, default_val);
    const access_source = buildPropertyAccessSource(ctx, init_source, key_source, false);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "var ") catch return "";
    buf.appendSlice(ctx.allocator, temp_name) catch return "";
    buf.appendSlice(ctx.allocator, " = ") catch return "";
    buf.appendSlice(ctx.allocator, access_source) catch return "";
    buf.appendSlice(ctx.allocator, ";\n") catch return "";
    buf.appendSlice(ctx.allocator, temp_name) catch return "";
    buf.appendSlice(ctx.allocator, " = ") catch return "";
    buf.appendSlice(ctx.allocator, temp_name) catch return "";
    buf.appendSlice(ctx.allocator, " === void 0 ? ") catch return "";
    buf.appendSlice(ctx.allocator, default_source) catch return "";
    buf.appendSlice(ctx.allocator, " : ") catch return "";
    buf.appendSlice(ctx.allocator, temp_name) catch return "";
    buf.appendSlice(ctx.allocator, ";\nvar ") catch return "";

    var nested_buf: std.ArrayListUnmanaged(u8) = .empty;
    var nested_first = true;
    switch (target_tag) {
        .object_pattern => emitObjectDestructuringStr(ctx, target, temp_name, &nested_buf, &nested_first),
        .array_pattern => {
            const count = countArrayPatternElements(ctx, target);
            const sliced_init = std.fmt.allocPrint(
                ctx.allocator,
                "babelHelpers.slicedToArray({s}, {d})",
                .{ temp_name, count },
            ) catch return "";
            emitArrayDestructuringStr(ctx, target, sliced_init, &nested_buf, &nested_first);
        },
        else => return "",
    }
    if (nested_buf.items.len == 0) return "";
    buf.appendSlice(ctx.allocator, nested_buf.items) catch return "";
    buf.append(ctx.allocator, ';') catch return "";
    return buf.items;
}

fn handleForInStatement(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const left: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);
    if (left == .none or body == .none) return;

    const left_tag = ctx.nodeTag(left);
    var pattern: NodeIndex = .none;
    var declare_targets = false;
    var left_keyword: []const u8 = "var";

    switch (left_tag) {
        .var_declaration, .let_declaration, .const_declaration => {
            const decl_data = ctx.nodeData(left);
            const decl_extra = @intFromEnum(decl_data.extra);
            if (decl_extra + 1 >= ctx.ast.extra_data.items.len) return;
            const range_start = ctx.ast.extra_data.items[decl_extra];
            const range_end = ctx.ast.extra_data.items[decl_extra + 1];
            if (range_end - range_start != 1) return;

            const declarator: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_start]);
            if (ctx.nodeTag(declarator) != .declarator) return;
            const declarator_data = ctx.nodeData(declarator);
            if (declarator_data.binary.rhs != .none) return;
            pattern = declarator_data.binary.lhs;
            declare_targets = true;
            left_keyword = switch (left_tag) {
                .var_declaration => "var",
                .let_declaration => if (g_config.rewrite_block_scoped_bindings) "var" else "let",
                .const_declaration => if (g_config.rewrite_block_scoped_bindings) "var" else "const",
                else => "var",
            };
        },
        .array_pattern, .object_pattern => {
            pattern = left;
        },
        else => return,
    }

    if (pattern == .none) return;
    const pattern_tag = ctx.nodeTag(pattern);
    if (pattern_tag != .array_pattern and pattern_tag != .object_pattern) return;
    if (g_config.rest_only and !patternNeedsObjectRestTransform(ctx, pattern)) return;

    const loop_temp = allocRef(ctx);
    const left_replacement = if (left_tag == .array_pattern or left_tag == .object_pattern)
        std.fmt.allocPrint(ctx.allocator, "var {s}", .{loop_temp}) catch return
    else
        std.fmt.allocPrint(ctx.allocator, "{s} {s}", .{ left_keyword, loop_temp }) catch return;
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(left), left_replacement) catch return;

    var prefix: std.ArrayListUnmanaged(u8) = .empty;
    var source_ref = loop_temp;
    if (!declare_targets) {
        source_ref = allocRef(ctx);
        appendBindingStatement(ctx, &prefix, "var", source_ref, loop_temp) catch return;
    }

    if (pattern_tag == .array_pattern) {
        var array_ref = source_ref;
        if (!g_config.iterable_is_array) {
            const helper_ref = allocRef(ctx);
            const helper_expr = if (g_config.array_like_is_iterable)
                std.fmt.allocPrint(ctx.allocator, "babelHelpers.maybeArrayLike(babelHelpers.toArray, {s})", .{source_ref}) catch return
            else
                std.fmt.allocPrint(ctx.allocator, "babelHelpers.slicedToArray({s}, {d})", .{ source_ref, countArrayPatternElements(ctx, pattern) }) catch return;
            appendBindingStatement(ctx, &prefix, "var", helper_ref, helper_expr) catch return;
            array_ref = helper_ref;
        }
        emitArrayPatternStatements(ctx, pattern, array_ref, declare_targets, left_keyword, &prefix);
    } else {
        emitObjectPatternStatements(ctx, pattern, source_ref, declare_targets, left_keyword, &prefix);
    }
    if (!declare_targets and pattern_tag == .array_pattern and ctx.nodeTag(idx) == .for_of_statement) {
        appendRawStatement(ctx, &prefix, "void 0") catch return;
    }
    if (pattern_tag == .object_pattern and objectPatternHasComputedProperty(ctx, pattern) and ctx.nodeTag(body) == .block_statement) {
        wrapBlockBodyWithPrefix(ctx, body, prefix.items);
        return;
    }
    appendPrefixToBody(ctx, body, prefix.items);
}

fn handleAssignmentExpr(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const lhs = data.binary.lhs;
    const rhs = data.binary.rhs;
    if (lhs == .none or rhs == .none) return;

    const lhs_tag = ctx.nodeTag(lhs);
    if (lhs_tag != .array_pattern and lhs_tag != .object_pattern) return;
    if (g_config.rest_only and !patternNeedsObjectRestTransform(ctx, lhs)) return;

    const main_tok = ctx.mainToken(idx);
    const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(main_tok)];
    if (tok_tag != .equal) return;

    const parent = findParentOf(ctx, idx) orelse return;
    const outer_parent = unwrapParenthesizedParent(ctx, parent);
    if (lhs_tag == .object_pattern) {
        if (isEmptyPattern(ctx, lhs)) {
            if (ctx.nodeTag(outer_parent) != .for_statement or !isForStatementTestOrUpdate(ctx, outer_parent, idx)) return;
            const body_node = getForStatementBodyNode(ctx, outer_parent) orelse return;
            const replacement = buildEmptyObjectForHeadAssignmentExpr(ctx, rhs, body_node);
            if (replacement.len == 0) return;
            ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), replacement) catch return;
            return;
        }
        if (ctx.nodeTag(outer_parent) == .expression_statement) {
            const preserve_completion = statementNeedsCompletionValue(ctx, outer_parent);
            const stmt_replacement = buildObjectAssignmentStatement(ctx, lhs, rhs, preserve_completion);
            if (stmt_replacement.len == 0) return;
            ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(outer_parent), stmt_replacement) catch return;
            ctx.ast.replacement_needs_reindent.put(ctx.allocator, @intFromEnum(outer_parent), {}) catch return;
        }
        return;
    }

    if (ctx.nodeTag(parent) == .arrow_function_expr and isArrowBodyNode(ctx, parent, idx)) {
        const arrow_replacement = buildArrowArrayAssignmentBody(ctx, lhs, rhs);
        if (arrow_replacement.len == 0) return;
        ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), arrow_replacement) catch return;
        ctx.ast.replacement_needs_reindent.put(ctx.allocator, @intFromEnum(idx), {}) catch return;
        return;
    }
    if (ctx.nodeTag(parent) == .sequence_expr and !isLastInSequenceExpr(ctx, idx, parent) and ctx.nodeTag(rhs) == .array_expr and canUseArrayLiteralInlineAssignment(ctx, lhs, rhs)) {
        const inline_replacement = buildInlineArrayLiteralAssignment(ctx, lhs, rhs);
        if (inline_replacement.len == 0) return;
        ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), inline_replacement) catch return;
        return;
    }
    if (ctx.nodeTag(parent) == .expression_statement) {
        const stmt_container = findParentOf(ctx, parent);
        const needs_block_wrapper = stmt_container != null and requiresStatementBlockWrapper(ctx, stmt_container.?, parent);
        const preserve_completion = statementNeedsCompletionValue(ctx, parent) or
            (needs_block_wrapper and stmt_container != null and statementNeedsCompletionValue(ctx, stmt_container.?));
        const statement_replacement = buildArrayAssignmentStatement(
            ctx,
            lhs,
            rhs,
            preserve_completion,
        );
        if (statement_replacement.len == 0) return;
        const final_replacement = if (needs_block_wrapper)
            wrapStatementBlock(ctx, statement_replacement)
        else
            statement_replacement;
        ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(parent), final_replacement) catch return;
        ctx.ast.replacement_needs_reindent.put(ctx.allocator, @intFromEnum(parent), {}) catch return;
        return;
    }

    const body_idx = findEnclosingBody(ctx, idx);
    const replacement = buildArrayAssignmentExpr(ctx, lhs, rhs, body_idx);
    if (replacement.len == 0) return;

    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), replacement) catch return;
}

fn unwrapParenthesizedParent(ctx: *TransformContext, node: NodeIndex) NodeIndex {
    var current = node;
    while (current != .none and ctx.nodeTag(current) == .parenthesized_expr) {
        current = findParentOf(ctx, current) orelse return node;
    }
    return current;
}

fn buildObjectAssignmentStatement(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex, preserve_completion: bool) []const u8 {
    if (pattern == .none or init == .none) return "";

    const init_source = getInitSource(ctx, init);
    const root_ref = if (ctx.nodeTag(init) == .identifier)
        allocRefFromName(ctx, init_source)
    else
        allocInitTemp(ctx, init);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendBindingStatement(ctx, &buf, "var", root_ref, init_source) catch return "";
    appendExpandedPatternStatements(ctx, &buf, buildObjectLiteralPatternStatements(ctx, pattern, root_ref, false)) catch return "";
    if (preserve_completion) {
        appendRawStatement(ctx, &buf, root_ref) catch return "";
    }
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
        _ = buf.pop();
    }
    return buf.items;
}

fn isForStatementTestOrUpdate(ctx: *TransformContext, for_stmt: NodeIndex, node: NodeIndex) bool {
    if (for_stmt == .none or node == .none or ctx.nodeTag(for_stmt) != .for_statement) return false;
    const data = ctx.nodeData(for_stmt);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return false;
    const test_expr: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
    const update: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);
    return test_expr == node or update == node;
}

fn getForStatementBodyNode(ctx: *TransformContext, for_stmt: NodeIndex) ?NodeIndex {
    if (for_stmt == .none or ctx.nodeTag(for_stmt) != .for_statement) return null;
    const data = ctx.nodeData(for_stmt);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 3 >= ctx.ast.extra_data.items.len) return null;
    const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
    if (body == .none) return null;
    return body;
}

fn buildEmptyObjectForHeadAssignmentExpr(ctx: *TransformContext, init: NodeIndex, body_node: NodeIndex) []const u8 {
    if (init == .none) return "";
    const init_source = getInitSource(ctx, init);
    const temp_name = if (ctx.nodeTag(init) == .identifier)
        allocSiblingRefName(ctx, init_source)
    else
        allocInitTemp(ctx, init);
    registerTempForBody(ctx, temp_name, @intFromEnum(body_node));

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, temp_name) catch return "";
    buf.appendSlice(ctx.allocator, " = ") catch return "";
    buf.appendSlice(ctx.allocator, init_source) catch return "";
    buf.appendSlice(ctx.allocator, ", ") catch return "";
    buf.appendSlice(ctx.allocator, "babelHelpers.objectDestructuringEmpty(") catch return "";
    buf.appendSlice(ctx.allocator, temp_name) catch return "";
    buf.appendSlice(ctx.allocator, "), ") catch return "";
    buf.appendSlice(ctx.allocator, temp_name) catch return "";
    return buf.items;
}

fn buildArrayAssignmentStatement(
    ctx: *TransformContext,
    pattern: NodeIndex,
    init: NodeIndex,
    preserve_completion: bool,
) []const u8 {
    if (pattern == .none or init == .none) return "";

    if (!preserve_completion and ctx.nodeTag(init) == .array_expr and canUsePureArrayLiteralFastPath(ctx, pattern, init)) {
        return expandCommaSequenceToStatementsWithTempDecls(ctx, buildInlineArrayLiteralAssignment(ctx, pattern, init));
    }

    if (!arrayPatternSupportsSimpleStatementLowering(ctx, pattern)) return "";

    if (!preserve_completion and ctx.nodeTag(init) == .array_expr and arrayPatternCanUseLiteralStatementLowering(ctx, pattern, init)) {
        return buildArrayLiteralAssignmentStatement(ctx, pattern, init);
    }

    const init_source = getInitSource(ctx, init);
    const init_tag = ctx.nodeTag(init);
    const root_ref = if (init_tag == .identifier)
        allocRefFromName(ctx, init_source)
    else
        allocInitTemp(ctx, init);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    appendBindingStatement(ctx, &buf, "var", root_ref, init_source) catch return "";

    var array_ref = root_ref;
    const helper_needed = init_tag != .array_expr and
        !(g_config.iterable_is_array and init_tag == .identifier);
    if (helper_needed) {
        const helper_ref = allocArrayHelperRef(ctx, root_ref);
        const helper_expr = if (g_config.array_like_is_iterable)
            std.fmt.allocPrint(ctx.allocator, "babelHelpers.maybeArrayLike(babelHelpers.toArray, {s})", .{root_ref}) catch return ""
        else
            std.fmt.allocPrint(ctx.allocator, "babelHelpers.slicedToArray({s}, {d})", .{ root_ref, countArrayPatternElements(ctx, pattern) }) catch return "";
        appendBindingStatement(ctx, &buf, "var", helper_ref, helper_expr) catch return "";
        array_ref = helper_ref;
    }

    emitArrayPatternStatements(ctx, pattern, array_ref, false, "", &buf);
    if (preserve_completion) {
        appendRawStatement(ctx, &buf, root_ref) catch return "";
    }
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
        _ = buf.pop();
    }
    return buf.items;
}

fn buildArrayLiteralAssignmentStatement(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) []const u8 {
    if (pattern == .none or init == .none) return "";

    const pattern_data = ctx.nodeData(pattern);
    const pattern_extra_idx = @intFromEnum(pattern_data.extra);
    if (pattern_extra_idx + 1 >= ctx.ast.extra_data.items.len) return "";
    const pattern_rs = ctx.ast.extra_data.items[pattern_extra_idx];
    const pattern_re = ctx.ast.extra_data.items[pattern_extra_idx + 1];

    const init_data = ctx.nodeData(init);
    const init_extra_idx = @intFromEnum(init_data.extra);
    if (init_extra_idx + 1 >= ctx.ast.extra_data.items.len) return "";
    const init_rs = ctx.ast.extra_data.items[init_extra_idx];
    const init_re = ctx.ast.extra_data.items[init_extra_idx + 1];
    const init_items = ctx.ast.extra_data.items[init_rs..init_re];

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (ctx.ast.extra_data.items[pattern_rs..pattern_re], 0..) |elem_idx, index| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem: NodeIndex = @enumFromInt(elem_idx);
        const elem_tag = ctx.nodeTag(elem);
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;

        if (elem_tag == .rest_element) {
            const rest_target = ctx.nodeData(elem).unary;
            if (rest_target == .none) return "";
            const rest_source = buildArrayLiteralSliceSource(ctx, init_items, index);
            switch (ctx.nodeTag(rest_target)) {
                .identifier => appendBindingStatement(ctx, &buf, "", getNodeSource(ctx, rest_target), rest_source) catch return "",
                .object_pattern => appendExpandedPatternStatements(ctx, &buf, buildObjectLiteralPatternStatements(ctx, rest_target, rest_source, false)) catch return "",
                .array_pattern => appendExpandedPatternStatements(ctx, &buf, buildArrayLiteralPatternStatements(ctx, rest_target, rest_source, false)) catch return "",
                else => return "",
            }
            continue;
        }

        const value_node = if (index < init_items.len) @as(NodeIndex, @enumFromInt(init_items[index])) else .none;
        const value_is_hole = isArrayLiteralHole(ctx, value_node);
        const value_source = getArrayLiteralValueSource(ctx, value_node);

        switch (elem_tag) {
            .identifier,
            .member_expr,
            .computed_member_expr,
            => appendBindingStatement(ctx, &buf, "", getNodeSource(ctx, elem), value_source) catch return "",
            .assignment_pattern => {
                const elem_data = ctx.nodeData(elem);
                const target = elem_data.binary.lhs;
                const default_val = elem_data.binary.rhs;
                if (target == .none or default_val == .none) return "";
                const default_source = getNodeSource(ctx, default_val);
                const final_source = if (value_is_hole) default_source else value_source;
                switch (ctx.nodeTag(target)) {
                    .identifier => appendBindingStatement(ctx, &buf, "", getNodeSource(ctx, target), final_source) catch return "",
                    .object_pattern => appendExpandedPatternStatements(ctx, &buf, buildObjectLiteralPatternStatements(ctx, target, final_source, value_is_hole and std.mem.eql(u8, default_source, "void 0"))) catch return "",
                    .array_pattern => appendExpandedPatternStatements(ctx, &buf, buildArrayLiteralPatternStatements(ctx, target, final_source, true)) catch return "",
                    else => return "",
                }
            },
            .object_pattern => appendExpandedPatternStatements(ctx, &buf, buildObjectLiteralPatternStatements(ctx, elem, value_source, value_is_hole)) catch return "",
            .array_pattern => appendExpandedPatternStatements(ctx, &buf, buildArrayLiteralPatternStatements(ctx, elem, value_source, true)) catch return "",
            else => return "",
        }
    }

    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
        _ = buf.pop();
    }
    return buf.items;
}

fn buildObjectLiteralPatternStatements(
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    allow_omit_undefined_arg: bool,
) []const u8 {
    if (pattern == .none) return "";
    if (isEmptyPattern(ctx, pattern)) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        appendObjectDestructuringEmptyCall(ctx, &buf, if (allow_omit_undefined_arg and std.mem.eql(u8, init_source, "void 0")) null else init_source) catch return "";
        return buf.items;
    }

    var nested_buf: std.ArrayListUnmanaged(u8) = .empty;
    var nested_first = true;
    emitObjectDestructuringStr(ctx, pattern, init_source, &nested_buf, &nested_first);
    return expandCommaSequenceToStatements(ctx, nested_buf.items);
}

fn arrayPatternCanUseLiteralStatementLowering(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) bool {
    if (pattern == .none or init == .none) return false;
    if (ctx.nodeTag(pattern) != .array_pattern or ctx.nodeTag(init) != .array_expr) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        switch (ctx.ast.nodes.items(.tag)[elem_idx]) {
            .removed, .empty_statement, .identifier => {},
            .member_expr, .computed_member_expr => return false,
            .rest_element => {
                const target = ctx.nodeData(@enumFromInt(elem_idx)).unary;
                if (target == .none or ctx.nodeTag(target) != .identifier) return false;
            },
            .assignment_pattern => {
                const target = ctx.nodeData(@enumFromInt(elem_idx)).binary.lhs;
                if (target == .none) return false;
                switch (ctx.nodeTag(target)) {
                    .identifier => {},
                    .object_pattern => {
                        if (!isEmptyPattern(ctx, target)) return false;
                    },
                    .array_pattern => {
                        if (!isEmptyPattern(ctx, target)) return false;
                    },
                    else => return false,
                }
            },
            .object_pattern => {
                if (!isEmptyPattern(ctx, @enumFromInt(elem_idx))) return false;
            },
            .array_pattern => {
                if (!isEmptyPattern(ctx, @enumFromInt(elem_idx))) return false;
            },
            else => return false,
        }
    }

    const init_data = ctx.nodeData(init);
    const init_extra_idx = @intFromEnum(init_data.extra);
    if (init_extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const init_rs = ctx.ast.extra_data.items[init_extra_idx];
    const init_re = ctx.ast.extra_data.items[init_extra_idx + 1];
    for (ctx.ast.extra_data.items[init_rs..init_re]) |item_idx| {
        if (item_idx >= ctx.ast.nodes.len) continue;
        switch (ctx.ast.nodes.items(.tag)[item_idx]) {
            .removed,
            .empty_statement,
            .numeric_literal,
            .string_literal,
            .template_literal,
            .boolean_literal,
            .null_literal,
            .array_expr,
            .object_expr,
            => {},
            else => return false,
        }
    }
    return true;
}

fn buildArrayLiteralPatternStatements(
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    use_helper: bool,
) []const u8 {
    if (pattern == .none) return "";

    if (isEmptyPattern(ctx, pattern)) {
        const temp_name = allocDiscardRef(ctx);
        const helper_source = if (use_helper)
            std.fmt.allocPrint(ctx.allocator, "babelHelpers.slicedToArray({s}, {d})", .{ init_source, countArrayPatternElements(ctx, pattern) }) catch return ""
        else
            init_source;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        appendBindingStatement(ctx, &buf, "var", temp_name, helper_source) catch return "";
        return buf.items;
    }

    const nested_init = if (use_helper)
        std.fmt.allocPrint(ctx.allocator, "babelHelpers.slicedToArray({s}, {d})", .{ init_source, countArrayPatternElements(ctx, pattern) }) catch return ""
    else
        init_source;
    var nested_buf: std.ArrayListUnmanaged(u8) = .empty;
    var nested_first = true;
    emitArrayDestructuringStr(ctx, pattern, nested_init, &nested_buf, &nested_first);
    return expandCommaSequenceToStatements(ctx, nested_buf.items);
}

fn appendExpandedPatternStatements(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    src: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    if (trimmed.len == 0) return;
    try buf.appendSlice(ctx.allocator, trimmed);
    if (trimmed[trimmed.len - 1] != '\n') {
        try buf.append(ctx.allocator, '\n');
    }
}

fn buildArrowArrayAssignmentBody(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) []const u8 {
    if (pattern == .none or init == .none) return "";
    if (!arrayPatternSupportsSimpleStatementLowering(ctx, pattern)) return "";

    const init_source = getInitSource(ctx, init);
    const init_tag = ctx.nodeTag(init);
    const root_ref = if (init_tag == .identifier)
        allocRefFromName(ctx, init_source)
    else
        allocInitTemp(ctx, init);

    var stmt_buf: std.ArrayListUnmanaged(u8) = .empty;
    appendBindingStatement(ctx, &stmt_buf, "var", root_ref, init_source) catch return "";

    var array_ref = root_ref;
    const helper_needed = init_tag != .array_expr and
        !(g_config.iterable_is_array and init_tag == .identifier);
    if (helper_needed) {
        const helper_ref = allocArrayHelperRef(ctx, root_ref);
        const helper_expr = if (g_config.array_like_is_iterable)
            std.fmt.allocPrint(ctx.allocator, "babelHelpers.maybeArrayLike(babelHelpers.toArray, {s})", .{root_ref}) catch return ""
        else
            std.fmt.allocPrint(ctx.allocator, "babelHelpers.slicedToArray({s}, {d})", .{ root_ref, countArrayPatternElements(ctx, pattern) }) catch return "";
        appendBindingStatement(ctx, &stmt_buf, "var", helper_ref, helper_expr) catch return "";
        array_ref = helper_ref;
    }

    emitArrayPatternStatements(ctx, pattern, array_ref, false, "", &stmt_buf);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "{\n") catch return "";
    appendIndentedBlockSource(ctx, &buf, stmt_buf.items, "  ");
    buf.appendSlice(ctx.allocator, "  return ") catch return "";
    buf.appendSlice(ctx.allocator, root_ref) catch return "";
    buf.appendSlice(ctx.allocator, ";\n}") catch return "";
    return buf.items;
}

fn canUseArrayLiteralInlineAssignment(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) bool {
    if (pattern == .none or init == .none) return false;
    if (ctx.nodeTag(pattern) != .array_pattern or ctx.nodeTag(init) != .array_expr) return false;

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        switch (ctx.ast.nodes.items(.tag)[elem_idx]) {
            .removed, .empty_statement, .identifier => {},
            .assignment_pattern => {
                const elem_data = ctx.ast.nodes.items(.data)[elem_idx];
                const target = elem_data.binary.lhs;
                if (target == .none) return false;
                switch (ctx.nodeTag(target)) {
                    .identifier => {},
                    else => return false,
                }
            },
            .rest_element => {
                const rest_target = ctx.nodeData(@enumFromInt(elem_idx)).unary;
                if (rest_target == .none or ctx.nodeTag(rest_target) != .identifier) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn buildInlineArrayLiteralAssignment(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    emitArrayLiteralDestructuring(ctx, pattern, init, &buf, &first);
    return compactInlineReplacement(ctx, buf.items);
}

fn expandCommaSequenceToStatements(ctx: *TransformContext, src: []const u8) []const u8 {
    return expandCommaSequenceToStatementsImpl(ctx, src, false);
}

fn expandCommaSequenceToStatementsWithTempDecls(ctx: *TransformContext, src: []const u8) []const u8 {
    return expandCommaSequenceToStatementsImpl(ctx, src, true);
}

fn expandCommaSequenceToStatementsImpl(ctx: *TransformContext, src: []const u8, declare_ref_temps: bool) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var start: usize = 0;
    var depth_paren: usize = 0;
    var depth_bracket: usize = 0;
    var depth_brace: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        switch (c) {
            '\'', '"' => {
                const quote = c;
                i += 1;
                while (i < src.len) : (i += 1) {
                    if (src[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (src[i] == quote) break;
                }
            },
            '`' => {
                i += 1;
                while (i < src.len) : (i += 1) {
                    if (src[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (src[i] == '`') break;
                }
            },
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            '{' => depth_brace += 1,
            '}' => {
                if (depth_brace > 0) depth_brace -= 1;
            },
            ',' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) {
                    const part = std.mem.trim(u8, src[start..i], " \t\r\n");
                    if (part.len > 0) {
                        appendExpandedCommaStatement(ctx, &buf, part, declare_ref_temps) catch return src;
                    }
                    start = i + 1;
                }
            },
            else => {},
        }
    }

    const tail = std.mem.trim(u8, src[start..], " \t\r\n");
    if (tail.len > 0) {
        appendExpandedCommaStatement(ctx, &buf, tail, declare_ref_temps) catch return src;
    }
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
        _ = buf.pop();
    }
    return buf.items;
}

fn appendExpandedCommaStatement(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    stmt: []const u8,
    declare_ref_temps: bool,
) !void {
    if (declare_ref_temps and shouldDeclareExpandedRefTemp(stmt)) {
        try buf.appendSlice(ctx.allocator, "var ");
    }
    try buf.appendSlice(ctx.allocator, stmt);
    try buf.appendSlice(ctx.allocator, ";\n");
}

fn shouldDeclareExpandedRefTemp(stmt: []const u8) bool {
    if (!std.mem.startsWith(u8, stmt, "_ref")) return false;
    if (std.mem.startsWith(u8, stmt, "var ")) return false;
    return std.mem.indexOf(u8, stmt, " = ") != null;
}

fn isBareDestructuringForInLeft(ctx: *TransformContext, decl: NodeIndex, range_start: u32, range_end: u32) bool {
    const parent = findParentOf(ctx, decl) orelse return false;
    const parent_tag = ctx.nodeTag(parent);
    if (parent_tag != .for_in_statement and parent_tag != .for_of_statement) return false;
    const parent_data = ctx.nodeData(parent);
    const extra_idx = @intFromEnum(parent_data.extra);
    if (extra_idx >= ctx.ast.extra_data.items.len) return false;
    const left: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    if (left != decl) return false;

    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_idx| {
        if (decl_idx >= ctx.ast.nodes.len or ctx.ast.nodes.items(.tag)[decl_idx] != .declarator) continue;
        const decl_data = ctx.ast.nodes.items(.data)[decl_idx];
        const lhs = decl_data.binary.lhs;
        const rhs = decl_data.binary.rhs;
        if (lhs == .none or rhs != .none) return false;
        const lhs_tag = ctx.nodeTag(lhs);
        if (lhs_tag != .array_pattern and lhs_tag != .object_pattern) return false;
    }
    return true;
}

/// Check if a destructuring pattern has no properties/elements.
fn isEmptyPattern(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none) return true;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return true;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    return rs >= re;
}

fn destructuringDeclNeedsVarKeyword(ctx: *TransformContext, lhs: NodeIndex, rhs: NodeIndex) bool {
    if (lhs == .none) return false;
    return switch (ctx.nodeTag(lhs)) {
        .object_pattern => objectDeclNeedsVarKeyword(ctx, lhs, rhs),
        .array_pattern => arrayDeclNeedsVarKeyword(ctx, rhs),
        else => false,
    };
}

fn objectDeclNeedsVarKeyword(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) bool {
    if (init == .none) return false;
    if (ctx.nodeTag(init) == .identifier) return false;

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    var prop_count: u32 = 0;
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const pt = ctx.ast.nodes.items(.tag)[prop_idx];
        if (pt == .shorthand_property or pt == .property or pt == .computed_property or pt == .rest_element) {
            prop_count += 1;
        }
    }

    return prop_count > 1 or
        hasNumericKeys(ctx, rs, re) or
        shouldTempObjectInit(ctx, init);
}

fn arrayDeclNeedsVarKeyword(ctx: *TransformContext, init: NodeIndex) bool {
    if (init == .none) return false;
    return switch (ctx.nodeTag(init)) {
        .identifier, .array_expr => false,
        else => true,
    };
}

fn isInForHead(ctx: *TransformContext, target: NodeIndex) bool {
    const parent = findParentOf(ctx, target) orelse return false;
    return switch (ctx.nodeTag(parent)) {
        .for_statement => {
            const data = ctx.nodeData(parent);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return false;
            const init: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            return init == target;
        },
        .for_in_statement, .for_of_statement, .for_of_await_statement => {
            const data = ctx.nodeData(parent);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return false;
            const left: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            return left == target;
        },
        else => false,
    };
}

fn isPatternInForHead(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none) return false;
    if (isInForHead(ctx, pattern)) return true;
    const parent = findParentOf(ctx, pattern) orelse return false;
    if (ctx.nodeTag(parent) == .declarator) {
        if (isInForHead(ctx, parent)) return true;
        const decl_parent = findParentOf(ctx, parent) orelse return false;
        return isInForHead(ctx, decl_parent);
    }
    return isInForHead(ctx, parent);
}

fn findParentOf(ctx: *TransformContext, target: NodeIndex) ?NodeIndex {
    const target_i = @intFromEnum(target);
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        const data = datas[ni];
        switch (tag) {
            .member_expr, .optional_chain_expr => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
            },
            .computed_member_expr,
            .optional_computed_member_expr,
            .binary_expr,
            .logical_expr,
            .assignment_expr,
            .conditional_expr,
            .ts_as_expression,
            .ts_satisfies_expression,
            .assignment_pattern,
            => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
                if (@intFromEnum(data.binary.rhs) == target_i) return @enumFromInt(ni);
            },
            .unary_expr,
            .update_expr,
            .parenthesized_expr,
            .ts_non_null_expression,
            .expression_statement,
            .return_statement,
            .throw_statement,
            .spread_element,
            .yield_expr,
            .await_expr,
            => {
                if (@intFromEnum(data.unary) == target_i) return @enumFromInt(ni);
            },
            .declarator => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
                if (@intFromEnum(data.binary.rhs) == target_i) return @enumFromInt(ni);
            },
            .call_expr, .optional_call_expr, .new_expr => {
                const eidx = @intFromEnum(data.extra);
                if (eidx < ctx.ast.extra_data.items.len and ctx.ast.extra_data.items[eidx] == target_i) {
                    return @enumFromInt(ni);
                }
                if (eidx + 2 < ctx.ast.extra_data.items.len) {
                    const args_start = ctx.ast.extra_data.items[eidx + 1];
                    const args_end = ctx.ast.extra_data.items[eidx + 2];
                    if (args_end > args_start and args_end <= ctx.ast.extra_data.items.len) {
                        for (ctx.ast.extra_data.items[args_start..args_end]) |arg_raw| {
                            if (arg_raw == target_i) return @enumFromInt(ni);
                        }
                    }
                }
            },
            .if_statement => {
                const eidx = @intFromEnum(data.extra);
                if (eidx + 2 < ctx.ast.extra_data.items.len) {
                    for (0..3) |offset| {
                        if (ctx.ast.extra_data.items[eidx + offset] == target_i) return @enumFromInt(ni);
                    }
                }
            },
            else => {},
        }

        const children = visitor.getChildren(ctx.ast, @enumFromInt(ni));
        for (children.items[0..children.len]) |child| {
            if (child == target) return @enumFromInt(ni);
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                if (raw == target_i) return @enumFromInt(ni);
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                if (raw == target_i) return @enumFromInt(ni);
            }
        }
    }
    return null;
}

/// Emit object destructuring with a string-based init source (for nested patterns).
fn emitObjectDestructuringStr(
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    if (pattern == .none) return;

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    emitObjectPropertiesFromSource(ctx, rs, re, init_source, buf, first);
}

/// Emit array destructuring with a string-based init source (for nested patterns).
fn emitArrayDestructuringStr(
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    if (pattern == .none) return;

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    emitArrayElementsFromSource(ctx, rs, re, init_source, buf, first, null);
}

/// Emit object destructuring: `{ a, b: c } = obj` -> `a = obj.a, c = obj.b`
fn emitObjectDestructuring(
    ctx: *TransformContext,
    pattern: NodeIndex,
    init: NodeIndex,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    if (pattern == .none) return;

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    // Get the init expression source
    const raw_init_source = if (init != .none) getInitSource(ctx, init) else "undefined";

    // If the init is a simple identifier, use it directly; otherwise create a temp ref
    const has_object_rest = objectPatternHasRestTag(ctx, rs, re);
    const init_is_simple = if (init != .none)
        ctx.ast.nodes.items(.tag)[@intFromEnum(init)] == .identifier
    else
        false;
    const force_loop_snapshot = init != .none and
        !init_is_simple and
        destructuringPatternInLoop(ctx, pattern);

    var init_source = raw_init_source;
    const prop_count = countObjectPatternProperties(ctx, rs, re);
    const force_init_snapshot = init != .none and (objectPatternNeedsInitSnapshot(ctx, rs, re) or
        (has_object_rest and init_is_simple and !isStaticIdentifierInit(ctx, init) and objectRestNeedsIdentifierSnapshot(ctx, rs, re)) or
        (init_is_simple and !isStaticIdentifierInit(ctx, init) and prop_count > 1 and objectPatternContainsNestedRest(ctx, pattern)) or
        force_loop_snapshot);
    if ((!init_is_simple or force_init_snapshot) and init != .none) {
        // Count how many properties we have — only need temp if >1 property access
        var property_count: u32 = 0;
        for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
            if (prop_idx >= ctx.ast.nodes.len) continue;
            const pt = ctx.ast.nodes.items(.tag)[prop_idx];
            if (pt == .shorthand_property or pt == .property or pt == .computed_property or pt == .rest_element) {
                property_count += 1;
            }
        }
        if (force_init_snapshot or
            property_count > 1 or
            hasNumericKeys(ctx, rs, re) or
            shouldTempObjectInit(ctx, init))
        {
            const ref_name = if (init_is_simple and force_init_snapshot)
                allocRefFromName(ctx, raw_init_source)
            else
                allocInitTemp(ctx, init);
            if (!first.*) {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            }
            first.* = false;
            buf.appendSlice(ctx.allocator, ref_name) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, raw_init_source) catch return;
            init_source = ref_name;
        }
    }

    emitObjectPropertiesFromSource(ctx, rs, re, init_source, buf, first);
}

fn objectPatternNeedsInitSnapshot(ctx: *TransformContext, rs: u32, re: u32) bool {
    var has_rest = false;
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop_tag = ctx.ast.nodes.items(.tag)[prop_idx];
        if (prop_tag == .rest_element) {
            has_rest = true;
            continue;
        }
        if (prop_tag != .computed_property) continue;

        const key_node = ctx.ast.nodes.items(.data)[prop_idx].binary.lhs;
        if (key_node != .none and isImpureComputedKey(ctx, key_node)) {
            return has_rest or objectPatternHasRestTag(ctx, rs, re);
        }
    }
    return false;
}

fn objectPatternHasRestTag(ctx: *TransformContext, rs: u32, re: u32) bool {
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[prop_idx] == .rest_element) return true;
    }
    return false;
}

fn countObjectPatternProperties(ctx: *TransformContext, rs: u32, re: u32) u32 {
    var count: u32 = 0;
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const tag = ctx.ast.nodes.items(.tag)[prop_idx];
        if (tag == .shorthand_property or tag == .property or tag == .computed_property or tag == .rest_element) {
            count += 1;
        }
    }
    return count;
}

fn objectPatternContainsNestedRest(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .object_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop_tag = ctx.ast.nodes.items(.tag)[prop_idx];
        const value = switch (prop_tag) {
            .property, .computed_property => ctx.ast.nodes.items(.data)[prop_idx].binary.rhs,
            .shorthand_property, .rest_element => .none,
            else => .none,
        };
        if (value == .none) continue;
        switch (ctx.nodeTag(value)) {
            .object_pattern => {
                const value_data = ctx.nodeData(value);
                const value_extra_idx = @intFromEnum(value_data.extra);
                if (value_extra_idx + 1 >= ctx.ast.extra_data.items.len) continue;
                const value_rs = ctx.ast.extra_data.items[value_extra_idx];
                const value_re = ctx.ast.extra_data.items[value_extra_idx + 1];
                if (objectPatternHasRestTag(ctx, value_rs, value_re) or objectPatternContainsNestedRest(ctx, value)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn destructuringPatternInLoop(ctx: *TransformContext, pattern: NodeIndex) bool {
    var current = pattern;
    while (current != .none) {
        const parent = findParentOf(ctx, current) orelse return false;
        switch (ctx.nodeTag(parent)) {
            .for_statement, .for_in_statement, .for_of_statement, .for_of_await_statement, .while_statement, .do_while_statement => return true,
            else => current = parent,
        }
    }
    return false;
}

fn objectRestNeedsIdentifierSnapshot(ctx: *TransformContext, rs: u32, re: u32) bool {
    const computed_count = countComputedProperties(ctx, rs, re);
    if (computed_count == 0) return true;
    if (computed_count > 1) return false;

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[prop_idx] != .computed_property) continue;
        const key_node = ctx.ast.nodes.items(.data)[prop_idx].binary.lhs;
        if (key_node == .none) return false;
        return switch (ctx.nodeTag(key_node)) {
            .template_literal => false,
            else => true,
        };
    }
    return false;
}

fn isImpureComputedKey(ctx: *TransformContext, key_node: NodeIndex) bool {
    switch (ctx.nodeTag(key_node)) {
        .call_expr,
        .optional_call_expr,
        .new_expr,
        .assignment_expr,
        .update_expr,
        .yield_expr,
        .await_expr,
        => return true,
        else => return false,
    }
}

/// Check if an object pattern has any numeric or string literal keys.
fn hasNumericKeys(ctx: *TransformContext, rs: u32, re: u32) bool {
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop_tag = ctx.ast.nodes.items(.tag)[prop_idx];
        if (prop_tag == .property) {
            const prop_data = ctx.ast.nodes.items(.data)[prop_idx];
            const key_node = prop_data.binary.lhs;
            if (key_node != .none) {
                const key_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(key_node)];
                if (key_tag == .numeric_literal or key_tag == .string_literal) return true;
            }
        }
    }
    return false;
}

/// Shared implementation for emitting object destructuring properties.
fn emitObjectPropertiesFromSource(
    ctx: *TransformContext,
    rs: u32,
    re: u32,
    init_source: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    var computed_key_temps: [16]ComputedKeyTemp = undefined;
    var computed_key_temp_len: usize = 0;
    const computed_prop_count = countComputedProperties(ctx, rs, re);

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[prop_idx] != .computed_property) continue;

        const prop_data = ctx.ast.nodes.items(.data)[prop_idx];
        const key_node = prop_data.binary.lhs;
        if (key_node == .none or !shouldTempComputedProperty(ctx, @enumFromInt(prop_idx), computed_prop_count)) continue;
        if (computed_key_temp_len >= computed_key_temps.len) continue;

        const temp_name = allocInitTemp(ctx, key_node);
        if (!first.*) {
            buf.appendSlice(ctx.allocator, ",\n  ") catch return;
        }
        first.* = false;
        buf.appendSlice(ctx.allocator, temp_name) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, getNodeSource(ctx, key_node)) catch return;

        computed_key_temps[computed_key_temp_len] = .{
            .prop_idx = prop_idx,
            .temp_name = temp_name,
        };
        computed_key_temp_len += 1;
    }

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop_tag = ctx.ast.nodes.items(.tag)[prop_idx];

        switch (prop_tag) {
            .shorthand_property => {
                // { a } = obj -> a = obj.a
                const prop_data = ctx.ast.nodes.items(.data)[prop_idx];
                const value_node = prop_data.unary;
                if (value_node == .none) continue;

                const val_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(value_node)];
                if (val_tag == .assignment_pattern) {
                    emitPropertyWithDefault(ctx, value_node, init_source, null, buf, first);
                } else {
                    const raw_name = getNodeSource(ctx, value_node);
                    const name = rewriteLoopBodyBlockScopedBindingName(ctx, value_node, raw_name);
                    if (!first.*) {
                        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    }
                    first.* = false;
                    buf.appendSlice(ctx.allocator, name) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, init_source) catch return;
                    buf.append(ctx.allocator, '.') catch return;
                    buf.appendSlice(ctx.allocator, raw_name) catch return;
                }
            },
            .property => {
                // { a: b } = obj -> b = obj.a
                const prop_data = ctx.ast.nodes.items(.data)[prop_idx];
                const key_node = prop_data.binary.lhs;
                const value_node = prop_data.binary.rhs;
                if (key_node == .none or value_node == .none) continue;

                const key_source = getNodeSource(ctx, key_node);
                const key_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(key_node)];
                const val_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(value_node)];

                // Determine access style: .key for identifiers, [key] for numbers/strings
                const use_bracket = (key_tag == .numeric_literal or key_tag == .string_literal);

                if (val_tag == .assignment_pattern) {
                    emitPatternWithDefault(ctx, value_node, init_source, key_source, buf, first);
                } else if (val_tag == .object_pattern or val_tag == .array_pattern) {
                    // Nested destructuring
                    const access_source = buildPropertyAccessSource(ctx, init_source, key_source, use_bracket);
                    if (val_tag == .object_pattern and canInlineNestedObjectPattern(ctx, value_node)) {
                        emitObjectDestructuringStr(ctx, value_node, access_source, buf, first);
                        continue;
                    }

                    // Need a temp ref for obj.key
                    const ref_name = allocRefName(ctx, init_source, key_source);
                    if (!first.*) {
                        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    }
                    first.* = false;
                    buf.appendSlice(ctx.allocator, ref_name) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    if (val_tag == .array_pattern) {
                        const count = countArrayPatternElements(ctx, value_node);
                        const helper_source = std.fmt.allocPrint(
                            ctx.allocator,
                            "babelHelpers.slicedToArray({s}, {d})",
                            .{ access_source, count },
                        ) catch return;
                        buf.appendSlice(ctx.allocator, helper_source) catch return;
                    } else {
                        buf.appendSlice(ctx.allocator, access_source) catch return;
                    }

                    // Recurse into nested pattern using the ref_name as the new init
                    if (val_tag == .object_pattern) {
                        emitObjectDestructuringStr(ctx, value_node, ref_name, buf, first);
                    } else {
                        emitArrayDestructuringStr(ctx, value_node, ref_name, buf, first);
                    }
                } else {
                    const val_source = rewriteLoopBodyBlockScopedBindingName(ctx, value_node, getNodeSource(ctx, value_node));
                    if (!first.*) {
                        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    }
                    first.* = false;
                    buf.appendSlice(ctx.allocator, val_source) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, init_source) catch return;
                    if (use_bracket) {
                        buf.append(ctx.allocator, '[') catch return;
                        buf.appendSlice(ctx.allocator, key_source) catch return;
                        buf.append(ctx.allocator, ']') catch return;
                    } else {
                        buf.append(ctx.allocator, '.') catch return;
                        buf.appendSlice(ctx.allocator, key_source) catch return;
                    }
                }
            },
            .computed_property => {
                const prop_data = ctx.ast.nodes.items(.data)[prop_idx];
                const key_node = prop_data.binary.lhs;
                const value_node = prop_data.binary.rhs;
                if (key_node == .none or value_node == .none) continue;

                const key_source = getComputedKeySource(prop_idx, key_node, computed_key_temps[0..computed_key_temp_len], ctx);
                const val_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(value_node)];

                if (val_tag == .assignment_pattern) {
                    emitPatternWithDefault(ctx, value_node, init_source, key_source, buf, first);
                } else if (val_tag == .object_pattern or val_tag == .array_pattern) {
                    const access_source = std.fmt.allocPrint(ctx.allocator, "{s}[{s}]", .{ init_source, key_source }) catch return;
                    if (val_tag == .object_pattern and canInlineNestedObjectPattern(ctx, value_node)) {
                        emitObjectDestructuringStr(ctx, value_node, access_source, buf, first);
                        continue;
                    }

                    const ref_name = allocRefName(ctx, init_source, "ref");
                    if (!first.*) {
                        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    }
                    first.* = false;
                    buf.appendSlice(ctx.allocator, ref_name) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    if (val_tag == .array_pattern) {
                        const count = countArrayPatternElements(ctx, value_node);
                        const helper_source = std.fmt.allocPrint(
                            ctx.allocator,
                            "babelHelpers.slicedToArray({s}, {d})",
                            .{ access_source, count },
                        ) catch return;
                        buf.appendSlice(ctx.allocator, helper_source) catch return;
                    } else {
                        buf.appendSlice(ctx.allocator, access_source) catch return;
                    }

                    if (val_tag == .object_pattern) {
                        emitObjectDestructuringStr(ctx, value_node, ref_name, buf, first);
                    } else {
                        emitArrayDestructuringStr(ctx, value_node, ref_name, buf, first);
                    }
                } else {
                    const val_source = getNodeSource(ctx, value_node);
                    if (!first.*) {
                        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    }
                    first.* = false;
                    buf.appendSlice(ctx.allocator, val_source) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, init_source) catch return;
                    buf.append(ctx.allocator, '[') catch return;
                    buf.appendSlice(ctx.allocator, key_source) catch return;
                    buf.append(ctx.allocator, ']') catch return;
                }
            },
            .rest_element => {
                const rest_target = ctx.nodeData(@enumFromInt(prop_idx)).unary;
                if (rest_target == .none or ctx.nodeTag(rest_target) != .identifier) continue;
                const rest_value = buildObjectRestValueSource(ctx, init_source, rs, re, computed_key_temps[0..computed_key_temp_len], computed_prop_count);
                if (!first.*) {
                    buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                }
                first.* = false;
                buf.appendSlice(ctx.allocator, getNodeSource(ctx, rest_target)) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, rest_value) catch return;
            },
            else => {},
        }
    }
}

const ComputedKeyTemp = struct {
    prop_idx: u32,
    temp_name: []const u8,
};

fn getComputedKeySource(
    prop_idx: u32,
    key_node: NodeIndex,
    temps: []const ComputedKeyTemp,
    ctx: *TransformContext,
) []const u8 {
    for (temps) |temp| {
        if (temp.prop_idx == prop_idx) return temp.temp_name;
    }
    return getNodeSource(ctx, key_node);
}

fn shouldTempComputedProperty(ctx: *TransformContext, prop_node: NodeIndex, computed_prop_count: u32) bool {
    if (prop_node == .none or ctx.nodeTag(prop_node) != .computed_property) return false;
    const prop_data = ctx.nodeData(prop_node);
    const key_node = prop_data.binary.lhs;
    const value_node = prop_data.binary.rhs;
    if (key_node == .none) return false;

    if (ctx.nodeTag(key_node) == .identifier and value_node != .none and ctx.nodeTag(value_node) == .identifier) {
        if (std.mem.eql(u8, getNodeSource(ctx, key_node), getNodeSource(ctx, value_node))) {
            return false;
        }
    }

    switch (ctx.nodeTag(key_node)) {
        .identifier => return !isPureComputedIdentifier(ctx, key_node),
        .numeric_literal, .string_literal => return false,
        .template_literal => {
            return computed_prop_count > 1 and std.mem.indexOf(u8, getNodeSource(ctx, key_node), "${") != null;
        },
        else => return true,
    }
}

fn isPureComputedIdentifier(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none or ctx.nodeTag(node) != .identifier) return false;
    const scope_result = ctx.scope orelse return false;
    const scope_idx = scope_mod.getScopeForNode(scope_result, node) orelse return false;
    const name = getNodeSource(ctx, node);
    const binding = scope_mod.getBinding(scope_result, scope_idx, name) orelse return false;
    return !binding.is_mutated;
}

fn countComputedProperties(ctx: *TransformContext, rs: u32, re: u32) u32 {
    var count: u32 = 0;
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[prop_idx] == .computed_property) count += 1;
    }
    return count;
}

fn patternNeedsObjectRestTransform(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none) return false;
    return switch (ctx.nodeTag(pattern)) {
        .object_pattern => objectPatternNeedsObjectRestTransform(ctx, pattern),
        .array_pattern => arrayPatternNeedsObjectRestTransform(ctx, pattern),
        .rest_element => patternNeedsObjectRestTransform(ctx, ctx.nodeData(pattern).unary),
        else => false,
    };
}

fn objectPatternNeedsObjectRestTransform(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .object_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    if (objectPatternHasRestTag(ctx, rs, re)) return true;

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const value = switch (ctx.ast.nodes.items(.tag)[prop_idx]) {
            .property, .computed_property => ctx.ast.nodes.items(.data)[prop_idx].binary.rhs,
            .rest_element => ctx.ast.nodes.items(.data)[prop_idx].unary,
            else => .none,
        };
        if (patternNeedsObjectRestTransform(ctx, value)) return true;
    }
    return false;
}

fn arrayPatternNeedsObjectRestTransform(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .array_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem: NodeIndex = @enumFromInt(elem_idx);
        if (patternNeedsObjectRestTransform(ctx, elem)) return true;
    }
    return false;
}

fn buildObjectRestExcludedKeysSource(
    ctx: *TransformContext,
    rs: u32,
    re: u32,
    temps: []const ComputedKeyTemp,
    computed_prop_count: u32,
) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return "[]";
    var first = true;
    var has_computed = false;
    var needs_property_key_map = false;

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop_tag = ctx.ast.nodes.items(.tag)[prop_idx];
        if (prop_tag == .rest_element) continue;

        const key_source = switch (prop_tag) {
            .shorthand_property => blk: {
                const value = ctx.ast.nodes.items(.data)[prop_idx].unary;
                if (value == .none) continue;
                break :blk std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{getNodeSource(ctx, value)}) catch continue;
            },
            .property => blk: {
                const key = ctx.ast.nodes.items(.data)[prop_idx].binary.lhs;
                if (key == .none) continue;
                const key_tag = ctx.nodeTag(key);
                if (key_tag == .identifier) {
                    break :blk std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{getNodeSource(ctx, key)}) catch continue;
                }
                if (key_tag == .string_literal) {
                    break :blk normalizeStringLiteralForExcludeList(ctx, key);
                }
                break :blk getNodeSource(ctx, key);
            },
            .computed_property => blk: {
                const key = ctx.ast.nodes.items(.data)[prop_idx].binary.lhs;
                if (key == .none) continue;
                has_computed = true;
                needs_property_key_map = needs_property_key_map or computedKeyNeedsPropertyKeyMap(ctx, key);
                break :blk getComputedKeySource(prop_idx, key, temps, ctx);
            },
            else => continue,
        };

        if (!first) buf.appendSlice(ctx.allocator, ", ") catch return "[]";
        first = false;
        buf.appendSlice(ctx.allocator, key_source) catch return "[]";
    }

    buf.append(ctx.allocator, ']') catch return "[]";
    if (has_computed and (computed_prop_count > 1 or temps.len > 0 or needs_property_key_map)) {
        buf.appendSlice(ctx.allocator, ".map(babelHelpers.toPropertyKey)") catch return "[]";
    }
    return buf.items;
}

fn computedKeyNeedsPropertyKeyMap(ctx: *TransformContext, key_node: NodeIndex) bool {
    return switch (ctx.nodeTag(key_node)) {
        .identifier => true,
        .numeric_literal, .string_literal => false,
        .template_literal => false,
        else => true,
    };
}

fn buildObjectRestValueSource(
    ctx: *TransformContext,
    init_source: []const u8,
    rs: u32,
    re: u32,
    temps: []const ComputedKeyTemp,
    computed_prop_count: u32,
) []const u8 {
    const excluded_keys = buildObjectRestExcludedKeysSource(ctx, rs, re, temps, computed_prop_count);
    if (std.mem.eql(u8, excluded_keys, "[]")) {
        return std.fmt.allocPrint(
            ctx.allocator,
            "{s}({{}}, (babelHelpers.objectDestructuringEmpty({s}), {s}))",
            .{
                if (g_config.use_builtins) "Object.assign" else "babelHelpers.extends",
                init_source,
                init_source,
            },
        ) catch "babelHelpers.extends({}, {})";
    }
    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}({s}, {s})",
        .{
            if (g_config.object_rest_no_symbols or g_config.loose) "babelHelpers.objectWithoutPropertiesLoose" else "babelHelpers.objectWithoutProperties",
            init_source,
            excluded_keys,
        },
    ) catch excluded_keys;
}

fn isStaticIdentifierInit(ctx: *TransformContext, init: NodeIndex) bool {
    if (init == .none or ctx.nodeTag(init) != .identifier) return false;
    const scope_result = ctx.scope orelse return false;
    const scope_idx = scope_mod.getScopeForNode(scope_result, init) orelse return false;
    const name = getNodeSource(ctx, init);
    const binding = scope_mod.getBinding(scope_result, scope_idx, name) orelse return false;

    return switch (binding.kind) {
        .function_decl, .class_decl, .import_binding => true,
        .const_decl => isConstBindingStaticValue(ctx, binding.node),
        else => false,
    };
}

fn isConstBindingStaticValue(ctx: *TransformContext, binding_node: NodeIndex) bool {
    const declarator = findParentOf(ctx, binding_node) orelse return false;
    if (ctx.nodeTag(declarator) != .declarator) return false;
    const init = ctx.nodeData(declarator).binary.rhs;
    if (init == .none) return false;
    return isStaticValueNode(ctx, init);
}

fn isStaticValueNode(ctx: *TransformContext, node: NodeIndex) bool {
    return switch (ctx.nodeTag(node)) {
        .object_expr,
        .array_expr,
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .function_expr,
        .arrow_function_expr,
        .class_expr,
        .regex_literal,
        => true,
        .template_literal => std.mem.indexOf(u8, getNodeSource(ctx, node), "${") == null,
        else => false,
    };
}

fn normalizeStringLiteralForExcludeList(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const source = getNodeSource(ctx, node);
    if (source.len >= 2 and (source[0] == '\'' or source[0] == '"') and source[source.len - 1] == source[0]) {
        return std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{source[1 .. source.len - 1]}) catch source;
    }
    return source;
}

fn canInlineNestedObjectPattern(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .object_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    var prop_count: u32 = 0;
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        switch (ctx.ast.nodes.items(.tag)[prop_idx]) {
            .shorthand_property, .property => prop_count += 1,
            .rest_element, .computed_property => return false,
            else => return false,
        }
    }
    return prop_count == 1 and !hasNumericKeys(ctx, rs, re);
}

/// Emit array destructuring: `[a, b] = arr` -> `_arr = arr, a = _arr[0], b = _arr[1]`
fn emitArrayDestructuring(
    ctx: *TransformContext,
    pattern: NodeIndex,
    init: NodeIndex,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    if (pattern == .none) return;

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    const init_source = if (init != .none) getInitSource(ctx, init) else "undefined";
    const init_tag = if (init != .none) ctx.ast.nodes.items(.tag)[@intFromEnum(init)] else .removed;
    const empty_pattern = isEmptyPattern(ctx, pattern);

    if (init_tag == .array_expr and empty_pattern and isEmptyArrayExpr(ctx, init)) {
        return;
    }

    if (init_tag == .array_expr and canUseArrayLiteralFastPath(ctx, pattern, init)) {
        emitArrayLiteralDestructuring(ctx, pattern, init, buf, first);
        return;
    }

    const has_rest = arrayPatternHasRest(ctx, pattern);
    const direct_helper = init_tag == .identifier and
        !isPatternInForHead(ctx, pattern) and
        !g_config.iterable_is_array and
        !g_config.array_like_is_iterable and
        !isKnownArrayIdentifierInit(ctx, init) and
        !isStaticIdentifierInit(ctx, init);

    const use_temp = isPatternInForHead(ctx, pattern) or
        init_tag != .identifier or
        direct_helper or
        ((g_config.iterable_is_array or g_config.array_like_is_iterable) and init_tag == .identifier and !isInForHead(ctx, pattern));

    // Use the original identifier directly when possible so we match Babel's
    // no-temp fast path for known arrays.
    const ref_name = if (use_temp)
        (if (init_tag == .identifier)
            allocRefFromName(ctx, init_source)
        else
            allocInitTemp(ctx, init))
    else
        init_source;

    // Emit a temp binding only when we actually introduced one.
    if (use_temp and !direct_helper) {
        if (!first.*) {
            buf.appendSlice(ctx.allocator, ",\n  ") catch return;
        }
        first.* = false;
        buf.appendSlice(ctx.allocator, ref_name) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, init_source) catch return;
    }

    const helper_needed = use_temp and
        init_tag != .array_expr and
        !(g_config.iterable_is_array and init_tag == .identifier);
    var array_ref = ref_name;
    if (helper_needed) {
        const helper_ref = if (direct_helper) ref_name else allocArrayHelperRef(ctx, ref_name);
        if (!first.*) {
            buf.appendSlice(ctx.allocator, ",\n  ") catch return;
        }
        first.* = false;
        buf.appendSlice(ctx.allocator, helper_ref) catch return;
        if (g_config.array_like_is_iterable) {
            buf.appendSlice(ctx.allocator, " = babelHelpers.maybeArrayLike(babelHelpers.toArray, ") catch return;
            buf.appendSlice(ctx.allocator, if (direct_helper) init_source else ref_name) catch return;
            buf.appendSlice(ctx.allocator, ")") catch return;
        } else {
            if (has_rest) {
                buf.appendSlice(ctx.allocator, " = babelHelpers.toArray(") catch return;
                buf.appendSlice(ctx.allocator, if (direct_helper) init_source else ref_name) catch return;
                buf.appendSlice(ctx.allocator, ")") catch return;
            } else {
                buf.appendSlice(ctx.allocator, " = babelHelpers.slicedToArray(") catch return;
                buf.appendSlice(ctx.allocator, if (direct_helper) init_source else ref_name) catch return;
                buf.appendSlice(ctx.allocator, ", ") catch return;
                const count = countArrayPatternElements(ctx, pattern);
                const count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{count}) catch return;
                buf.appendSlice(ctx.allocator, count_str) catch return;
                buf.appendSlice(ctx.allocator, ")") catch return;
            }
        }
        array_ref = helper_ref;
    }

    emitArrayElementsFromSource(ctx, rs, re, array_ref, buf, first, null);
}

fn buildArrayAssignmentExpr(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex, body_idx: u32) []const u8 {
    if (pattern == .none or init == .none) return "";

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return "";
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    const init_source = getInitSource(ctx, init);
    const init_tag = ctx.nodeTag(init);
    const root_ref = if (init_tag == .identifier)
        allocRefFromName(ctx, init_source)
    else
        allocInitTemp(ctx, init);
    registerTempForBody(ctx, root_ref, body_idx);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '(') catch return "";
    buf.appendSlice(ctx.allocator, root_ref) catch return "";
    buf.appendSlice(ctx.allocator, " = ") catch return "";
    buf.appendSlice(ctx.allocator, init_source) catch return "";

    const helper_needed = init_tag != .array_expr and
        !(g_config.iterable_is_array and init_tag == .identifier);
    var array_ref = root_ref;
    if (helper_needed) {
        const helper_ref = allocArrayHelperRef(ctx, root_ref);
        registerTempForBody(ctx, helper_ref, body_idx);
        buf.appendSlice(ctx.allocator, ",\n  ") catch return "";
        buf.appendSlice(ctx.allocator, helper_ref) catch return "";
        if (g_config.array_like_is_iterable) {
            buf.appendSlice(ctx.allocator, " = babelHelpers.maybeArrayLike(babelHelpers.toArray, ") catch return "";
            buf.appendSlice(ctx.allocator, root_ref) catch return "";
            buf.append(ctx.allocator, ')') catch return "";
        } else {
            buf.appendSlice(ctx.allocator, " = babelHelpers.slicedToArray(") catch return "";
            buf.appendSlice(ctx.allocator, root_ref) catch return "";
            buf.appendSlice(ctx.allocator, ", ") catch return "";
            const count = countArrayPatternElements(ctx, pattern);
            const count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{count}) catch return "";
            buf.appendSlice(ctx.allocator, count_str) catch return "";
            buf.append(ctx.allocator, ')') catch return "";
        }
        array_ref = helper_ref;
    }

    var first = false;
    emitArrayElementsFromSource(ctx, rs, re, array_ref, &buf, &first, body_idx);
    buf.appendSlice(ctx.allocator, ",\n  ") catch return "";
    buf.appendSlice(ctx.allocator, root_ref) catch return "";
    buf.append(ctx.allocator, ')') catch return "";
    return compactInlineReplacement(ctx, buf.items);
}

fn buildObjectAssignmentExpr(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex, body_idx: u32) []const u8 {
    if (pattern == .none or init == .none) return "";
    const init_source = getInitSource(ctx, init);
    const init_tag = ctx.nodeTag(init);
    const root_ref = if (init_tag == .identifier)
        allocRefFromName(ctx, init_source)
    else
        allocInitTemp(ctx, init);
    registerTempForBody(ctx, root_ref, body_idx);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = false;
    buf.append(ctx.allocator, '(') catch return "";
    buf.appendSlice(ctx.allocator, root_ref) catch return "";
    buf.appendSlice(ctx.allocator, " = ") catch return "";
    buf.appendSlice(ctx.allocator, init_source) catch return "";
    emitObjectDestructuringStr(ctx, pattern, root_ref, &buf, &first);
    buf.appendSlice(ctx.allocator, ",\n  ") catch return "";
    buf.appendSlice(ctx.allocator, root_ref) catch return "";
    buf.append(ctx.allocator, ')') catch return "";
    return compactInlineReplacement(ctx, buf.items);
}

fn canUseArrayLiteralFastPath(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) bool {
    if (pattern == .none or init == .none) return false;
    if (ctx.nodeTag(pattern) != .array_pattern or ctx.nodeTag(init) != .array_expr) return false;

    const init_data = ctx.nodeData(init);
    const init_extra_idx = @intFromEnum(init_data.extra);
    if (init_extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const init_rs = ctx.ast.extra_data.items[init_extra_idx];
    const init_re = ctx.ast.extra_data.items[init_extra_idx + 1];
    var has_hole = false;

    for (ctx.ast.extra_data.items[init_rs..init_re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) {
            has_hole = true;
            continue;
        }
        switch (ctx.ast.nodes.items(.tag)[elem_idx]) {
            .removed, .empty_statement => has_hole = true,
            .identifier,
            .numeric_literal,
            .string_literal,
            .template_literal,
            .boolean_literal,
            .null_literal,
            .array_expr,
            .object_expr,
            => {},
            else => return false,
        }
    }

    if (!has_hole) return canUsePureArrayLiteralFastPath(ctx, pattern, init);

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        switch (ctx.ast.nodes.items(.tag)[elem_idx]) {
            .removed,
            .empty_statement,
            .identifier,
            .assignment_pattern,
            .rest_element,
            .array_pattern,
            .object_pattern,
            => {},
            else => return false,
        }
    }

    return true;
}

fn canUsePureArrayLiteralFastPath(ctx: *TransformContext, pattern: NodeIndex, init: NodeIndex) bool {
    if (pattern == .none or init == .none) return false;
    if (ctx.nodeTag(pattern) != .array_pattern or ctx.nodeTag(init) != .array_expr) return false;

    const pattern_data = ctx.nodeData(pattern);
    const pattern_extra_idx = @intFromEnum(pattern_data.extra);
    if (pattern_extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const pattern_rs = ctx.ast.extra_data.items[pattern_extra_idx];
    const pattern_re = ctx.ast.extra_data.items[pattern_extra_idx + 1];
    const pattern_items = ctx.ast.extra_data.items[pattern_rs..pattern_re];

    const init_data = ctx.nodeData(init);
    const init_extra_idx = @intFromEnum(init_data.extra);
    if (init_extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const init_rs = ctx.ast.extra_data.items[init_extra_idx];
    const init_re = ctx.ast.extra_data.items[init_extra_idx + 1];
    const init_items = ctx.ast.extra_data.items[init_rs..init_re];

    var rest_index: ?usize = null;
    var required_count: usize = 0;
    for (pattern_items, 0..) |elem_idx, index| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem_tag = ctx.ast.nodes.items(.tag)[elem_idx];
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;
        if (elem_tag == .rest_element) {
            if (index + 1 != pattern_items.len) return false;
            rest_index = index;
            continue;
        }
        required_count += 1;
    }

    if (rest_index == null) {
        if (init_items.len != pattern_items.len) return false;
    } else {
        if (init_items.len < required_count) return false;
    }

    for (pattern_items, 0..) |elem_idx, index| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem: NodeIndex = @enumFromInt(elem_idx);
        const elem_tag = ctx.nodeTag(elem);
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;
        if (elem_tag == .rest_element) {
            var ri = index;
            while (ri < init_items.len) : (ri += 1) {
                if (!isPureFastPathLiteralNode(ctx, @enumFromInt(init_items[ri]))) return false;
            }
            return true;
        }

        if (index >= init_items.len) return false;
        const value_node: NodeIndex = @enumFromInt(init_items[index]);
        if (isArrayLiteralHole(ctx, value_node)) return false;

        switch (elem_tag) {
            .identifier => if (!isPureFastPathLiteralNode(ctx, value_node)) return false,
            .assignment_pattern => {
                const target = ctx.nodeData(elem).binary.lhs;
                if (target == .none) return false;
                switch (ctx.nodeTag(target)) {
                    .identifier => if (!isPureFastPathLiteralNode(ctx, value_node)) return false,
                    .array_pattern => {
                        if (ctx.nodeTag(value_node) != .array_expr) return false;
                        if (!isPureArrayLiteralExpr(ctx, value_node)) return false;
                    },
                    else => return false,
                }
            },
            .array_pattern => {
                if (ctx.nodeTag(value_node) != .array_expr) return false;
                if (!isPureArrayLiteralExpr(ctx, value_node)) return false;
            },
            .object_pattern => if (ctx.nodeTag(value_node) != .object_expr) return false,
            else => return false,
        }
    }

    return true;
}

fn isPureFastPathLiteralNode(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    return switch (ctx.nodeTag(node)) {
        .numeric_literal,
        .string_literal,
        .template_literal,
        .boolean_literal,
        .null_literal,
        .object_expr,
        => true,
        .array_expr => isPureArrayLiteralExpr(ctx, node),
        else => false,
    };
}

fn isPureArrayLiteralExpr(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none or ctx.nodeTag(node) != .array_expr) return false;
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        const elem: NodeIndex = @enumFromInt(elem_idx);
        if (isArrayLiteralHole(ctx, elem)) return false;
        if (!isPureFastPathLiteralNode(ctx, elem)) return false;
    }
    return true;
}

fn isEmptyArrayExpr(ctx: *TransformContext, init: NodeIndex) bool {
    if (init == .none or ctx.nodeTag(init) != .array_expr) return false;
    const data = ctx.nodeData(init);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    return ctx.ast.extra_data.items[extra_idx] == ctx.ast.extra_data.items[extra_idx + 1];
}

fn emitArrayLiteralDestructuring(
    ctx: *TransformContext,
    pattern: NodeIndex,
    init: NodeIndex,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    const pattern_data = ctx.nodeData(pattern);
    const pattern_extra_idx = @intFromEnum(pattern_data.extra);
    if (pattern_extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
    const pattern_rs = ctx.ast.extra_data.items[pattern_extra_idx];
    const pattern_re = ctx.ast.extra_data.items[pattern_extra_idx + 1];

    const init_data = ctx.nodeData(init);
    const init_extra_idx = @intFromEnum(init_data.extra);
    if (init_extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
    const init_rs = ctx.ast.extra_data.items[init_extra_idx];
    const init_re = ctx.ast.extra_data.items[init_extra_idx + 1];
    const init_items = ctx.ast.extra_data.items[init_rs..init_re];

    for (ctx.ast.extra_data.items[pattern_rs..pattern_re], 0..) |elem_idx, index| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem: NodeIndex = @enumFromInt(elem_idx);
        const elem_tag = ctx.nodeTag(elem);
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;

        if (elem_tag == .rest_element) {
            const rest_target = ctx.nodeData(elem).unary;
            if (rest_target == .none) return;
            const rest_source = buildArrayLiteralSliceSource(ctx, init_items, index);
            switch (ctx.nodeTag(rest_target)) {
                .identifier => emitLiteralBinding(ctx, buf, first, getNodeSource(ctx, rest_target), rest_source),
                .object_pattern => emitObjectDestructuringStr(ctx, rest_target, rest_source, buf, first),
                .array_pattern => emitArrayDestructuringStr(ctx, rest_target, rest_source, buf, first),
                else => return,
            }
            continue;
        }

        const value_node = if (index < init_items.len) @as(NodeIndex, @enumFromInt(init_items[index])) else .none;
        const value_source = getArrayLiteralValueSource(ctx, value_node);
        switch (elem_tag) {
            .identifier => emitLiteralBinding(ctx, buf, first, getNodeSource(ctx, elem), value_source),
            .assignment_pattern => {
                const elem_data = ctx.nodeData(elem);
                const target = elem_data.binary.lhs;
                const default_val = elem_data.binary.rhs;
                if (target == .none) return;
                const default_source = getNodeSource(ctx, default_val);
                const final_source = if (isArrayLiteralHole(ctx, value_node)) default_source else value_source;
                switch (ctx.nodeTag(target)) {
                    .identifier => emitLiteralBinding(ctx, buf, first, getNodeSource(ctx, target), final_source),
                    .object_pattern => emitObjectDestructuringStr(ctx, target, final_source, buf, first),
                    .array_pattern => {
                        if (value_node != .none and ctx.nodeTag(value_node) == .array_expr and canUsePureArrayLiteralFastPath(ctx, target, value_node)) {
                            emitArrayLiteralDestructuring(ctx, target, value_node, buf, first);
                        } else if (value_node != .none and ctx.nodeTag(value_node) == .array_expr) {
                            const nested_ref = allocRef(ctx);
                            emitLiteralBinding(ctx, buf, first, nested_ref, final_source);
                            emitArrayDestructuringStr(ctx, target, nested_ref, buf, first);
                        } else {
                            emitArrayDestructuringStr(ctx, target, final_source, buf, first);
                        }
                    },
                    else => return,
                }
            },
            .object_pattern => emitObjectDestructuringStr(ctx, elem, value_source, buf, first),
            .array_pattern => {
                if (value_node != .none and ctx.nodeTag(value_node) == .array_expr and canUsePureArrayLiteralFastPath(ctx, elem, value_node)) {
                    emitArrayLiteralDestructuring(ctx, elem, value_node, buf, first);
                } else if (value_node != .none and ctx.nodeTag(value_node) == .array_expr) {
                    const nested_ref = allocRef(ctx);
                    emitLiteralBinding(ctx, buf, first, nested_ref, value_source);
                    emitArrayDestructuringStr(ctx, elem, nested_ref, buf, first);
                } else {
                    emitArrayDestructuringStr(ctx, elem, value_source, buf, first);
                }
            },
            else => return,
        }
    }
}

fn emitLiteralBinding(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
    name: []const u8,
    expr: []const u8,
) void {
    if (first.*) {
        first.* = false;
    } else {
        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
    }
    buf.appendSlice(ctx.allocator, name) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, expr) catch return;
}

fn buildArrayLiteralSliceSource(ctx: *TransformContext, items: []const u32, start_index: usize) []const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    result.append(ctx.allocator, '[') catch return "[]";
    var first = true;
    var i = start_index;
    while (i < items.len) : (i += 1) {
        if (!first) result.appendSlice(ctx.allocator, ", ") catch return "[]";
        first = false;
        const node: NodeIndex = @enumFromInt(items[i]);
        result.appendSlice(ctx.allocator, getArrayLiteralValueSource(ctx, node)) catch return "[]";
    }
    result.append(ctx.allocator, ']') catch return "[]";
    return result.items;
}

fn getArrayLiteralValueSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (isArrayLiteralHole(ctx, node)) return "void 0";
    return getNodeSource(ctx, node);
}

fn compactInlineReplacement(ctx: *TransformContext, src: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src, '\n') == null) return src;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            buf.append(ctx.allocator, ' ') catch return src;
            while (i + 1 < src.len and (src[i + 1] == ' ' or src[i + 1] == '\t')) : (i += 1) {}
            continue;
        }
        buf.append(ctx.allocator, src[i]) catch return src;
    }
    return buf.items;
}

fn isArrayLiteralHole(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return true;
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return true;
    const tag = ctx.ast.nodes.items(.tag)[ni];
    return tag == .removed or tag == .empty_statement;
}

/// Shared implementation for emitting array destructuring elements.
fn emitArrayElementsFromSource(
    ctx: *TransformContext,
    rs: u32,
    re: u32,
    ref_name: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
    temp_body_idx: ?u32,
) void {
    // Emit each element: a = _ref[0], b = _ref[1], ...
    var index: u32 = 0;
    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        defer index += 1;
        if (elem_idx >= ctx.ast.nodes.len) continue;

        const elem_tag = ctx.ast.nodes.items(.tag)[elem_idx];

        // Skip holes (empty slots)
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;

        if (elem_tag == .rest_element) {
            // ...rest = _ref.slice(index)
            const elem_data = ctx.ast.nodes.items(.data)[elem_idx];
            const rest_target = elem_data.unary;
            if (rest_target == .none) continue;

            const rest_name = rewriteLoopBodyBlockScopedBindingName(ctx, rest_target, getNodeSource(ctx, rest_target));
            if (first.*) {
                first.* = false;
            } else {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            }
            buf.appendSlice(ctx.allocator, rest_name) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, "babelHelpers.arrayLikeToArray(") catch return;
            buf.appendSlice(ctx.allocator, ref_name) catch return;
            buf.appendSlice(ctx.allocator, ").slice(") catch return;
            const idx_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{index}) catch return;
            buf.appendSlice(ctx.allocator, idx_str) catch return;
            buf.append(ctx.allocator, ')') catch return;
            continue;
        }

        if (elem_tag == .assignment_pattern) {
            const elem_data = ctx.ast.nodes.items(.data)[elem_idx];
            const target = elem_data.binary.lhs;
            const default_val = elem_data.binary.rhs;
            if (target == .none) continue;

            const default_source = getNodeSource(ctx, default_val);
            const temp_base = std.fmt.allocPrint(ctx.allocator, "{s}$", .{ref_name}) catch return;
            const temp_name = allocNextRefName(ctx, temp_base);
            if (temp_body_idx) |body_idx| registerTempForBody(ctx, temp_name, body_idx);

            if (first.*) {
                first.* = false;
            } else {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            }
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, ref_name) catch return;
            buf.append(ctx.allocator, '[') catch return;
            const idx_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{index}) catch return;
            buf.appendSlice(ctx.allocator, idx_str) catch return;
            buf.append(ctx.allocator, ']') catch return;

            const target_tag = ctx.nodeTag(target);
            switch (target_tag) {
                .identifier => {
                    const target_name = rewriteLoopBodyBlockScopedBindingName(ctx, target, getNodeSource(ctx, target));
                    buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    buf.appendSlice(ctx.allocator, target_name) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, temp_name) catch return;
                    buf.appendSlice(ctx.allocator, " === void 0 ? ") catch return;
                    buf.appendSlice(ctx.allocator, default_source) catch return;
                    buf.appendSlice(ctx.allocator, " : ") catch return;
                    buf.appendSlice(ctx.allocator, temp_name) catch return;
                },
                .object_pattern => {
                    const default_ref = allocNextRefName(ctx, temp_name);
                    if (temp_body_idx) |body_idx| registerTempForBody(ctx, default_ref, body_idx);
                    buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    buf.appendSlice(ctx.allocator, default_ref) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, temp_name) catch return;
                    buf.appendSlice(ctx.allocator, " === void 0 ? ") catch return;
                    buf.appendSlice(ctx.allocator, default_source) catch return;
                    buf.appendSlice(ctx.allocator, " : ") catch return;
                    buf.appendSlice(ctx.allocator, temp_name) catch return;
                    emitObjectDestructuringStr(ctx, target, default_ref, buf, first);
                },
                .array_pattern => {
                    const default_ref = allocNextRefName(ctx, temp_name);
                    if (temp_body_idx) |body_idx| registerTempForBody(ctx, default_ref, body_idx);
                    buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    buf.appendSlice(ctx.allocator, default_ref) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, temp_name) catch return;
                    buf.appendSlice(ctx.allocator, " === void 0 ? ") catch return;
                    buf.appendSlice(ctx.allocator, default_source) catch return;
                    buf.appendSlice(ctx.allocator, " : ") catch return;
                    buf.appendSlice(ctx.allocator, temp_name) catch return;
                    const nested_ref = allocNextRefName(ctx, temp_name);
                    if (temp_body_idx) |body_idx| registerTempForBody(ctx, nested_ref, body_idx);
                    buf.appendSlice(ctx.allocator, ",\n  ") catch return;
                    buf.appendSlice(ctx.allocator, nested_ref) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    const count = countArrayPatternElements(ctx, target);
                    buf.appendSlice(ctx.allocator, "babelHelpers.slicedToArray(") catch return;
                    buf.appendSlice(ctx.allocator, default_ref) catch return;
                    buf.appendSlice(ctx.allocator, ", ") catch return;
                    const count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{count}) catch return;
                    buf.appendSlice(ctx.allocator, count_str) catch return;
                    buf.appendSlice(ctx.allocator, ")") catch return;
                    emitArrayDestructuringStr(ctx, target, nested_ref, buf, first);
                },
                else => {},
            }
            continue;
        }

        // Simple element
        if (elem_tag == .identifier or elem_tag == .member_expr or elem_tag == .computed_member_expr) {
            const elem: NodeIndex = @enumFromInt(elem_idx);
            const name = rewriteLoopBodyBlockScopedBindingName(ctx, elem, getNodeSource(ctx, elem));
            if (first.*) {
                first.* = false;
            } else {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            }
            buf.appendSlice(ctx.allocator, name) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, ref_name) catch return;
            buf.append(ctx.allocator, '[') catch return;
            const idx_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{index}) catch return;
            buf.appendSlice(ctx.allocator, idx_str) catch return;
            buf.append(ctx.allocator, ']') catch return;
        } else if (elem_tag == .array_pattern or elem_tag == .object_pattern) {
            // Nested destructuring: need a temp for _ref[index]
            const nested_base = std.fmt.allocPrint(ctx.allocator, "{s}$", .{ref_name}) catch return;
            const nested_ref = allocNextRefName(ctx, nested_base);
            if (temp_body_idx) |body_idx| registerTempForBody(ctx, nested_ref, body_idx);
            if (first.*) {
                first.* = false;
            } else {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            }
            buf.appendSlice(ctx.allocator, nested_ref) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, "babelHelpers.slicedToArray(") catch return;
            buf.appendSlice(ctx.allocator, ref_name) catch return;
            buf.append(ctx.allocator, '[') catch return;
            const idx_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{index}) catch return;
            buf.appendSlice(ctx.allocator, idx_str) catch return;
            buf.appendSlice(ctx.allocator, "], ") catch return;
            const count = countArrayPatternElements(ctx, @enumFromInt(elem_idx));
            const count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{count}) catch return;
            buf.appendSlice(ctx.allocator, count_str) catch return;
            buf.appendSlice(ctx.allocator, ")") catch return;

            var nested_first = false;
            if (elem_tag == .object_pattern) {
                emitObjectDestructuringStr(ctx, @enumFromInt(elem_idx), nested_ref, buf, &nested_first);
            } else {
                emitArrayDestructuringStr(ctx, @enumFromInt(elem_idx), nested_ref, buf, &nested_first);
            }
        }
    }
}

fn emitArrayPatternStatements(
    ctx: *TransformContext,
    pattern: NodeIndex,
    ref_name: []const u8,
    declare_targets: bool,
    decl_keyword: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
) void {
    if (pattern == .none or ctx.nodeTag(pattern) != .array_pattern) return;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[rs..re], 0..) |elem_idx, index| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem: NodeIndex = @enumFromInt(elem_idx);
        const elem_tag = ctx.nodeTag(elem);
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;

        const access = std.fmt.allocPrint(ctx.allocator, "{s}[{d}]", .{ ref_name, index }) catch return;
        switch (elem_tag) {
            .identifier,
            .member_expr,
            .computed_member_expr,
            => {
                const keyword = if (declare_targets) decl_keyword else "";
                appendBindingStatement(ctx, buf, keyword, getNodeSource(ctx, elem), access) catch return;
            },
            .object_pattern => {
                if (!isEmptyPattern(ctx, elem)) return;
                appendObjectDestructuringEmptyStatement(ctx, buf, access) catch return;
            },
            .array_pattern => {
                const nested_count = countArrayPatternElements(ctx, elem);
                const nested_source = std.fmt.allocPrint(
                    ctx.allocator,
                    "babelHelpers.slicedToArray({s}, {d})",
                    .{ access, nested_count },
                ) catch return;
                const nested_ref = if (isEmptyPattern(ctx, elem))
                    allocDiscardRef(ctx)
                else
                    allocRef(ctx);
                appendBindingStatement(ctx, buf, "var", nested_ref, nested_source) catch return;
                if (!isEmptyPattern(ctx, elem)) {
                    emitArrayPatternStatements(ctx, elem, nested_ref, declare_targets, decl_keyword, buf);
                }
            },
            else => return,
        }
    }
}

fn emitObjectPatternStatements(
    ctx: *TransformContext,
    pattern: NodeIndex,
    ref_name: []const u8,
    declare_targets: bool,
    decl_keyword: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
) void {
    if (pattern == .none or ctx.nodeTag(pattern) != .object_pattern) return;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    if (declare_targets and objectPatternHasRestTag(ctx, rs, re)) {
        emitLoopHeadObjectPatternWithRest(ctx, pattern, ref_name, decl_keyword, rs, re, buf);
        return;
    }

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop: NodeIndex = @enumFromInt(prop_idx);
        switch (ctx.nodeTag(prop)) {
            .shorthand_property => {
                const value = ctx.nodeData(prop).unary;
                if (value == .none) return;
                const keyword = if (declare_targets) decl_keyword else "";
                const name = getNodeSource(ctx, value);
                const access = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ ref_name, name }) catch return;
                appendBindingStatement(ctx, buf, keyword, name, access) catch return;
            },
            .property => {
                const prop_data = ctx.nodeData(prop);
                const key = prop_data.binary.lhs;
                const value = prop_data.binary.rhs;
                if (key == .none or value == .none) return;
                if (ctx.nodeTag(value) == .object_pattern and isEmptyPattern(ctx, value)) {
                    const access = buildPropertyAccessSource(ctx, ref_name, getNodeSource(ctx, key), false);
                    appendObjectDestructuringEmptyStatement(ctx, buf, access) catch return;
                    continue;
                }
                if (ctx.nodeTag(value) != .identifier and ctx.nodeTag(value) != .member_expr and ctx.nodeTag(value) != .computed_member_expr) return;
                const keyword = if (declare_targets) decl_keyword else "";
                const access = buildPropertyAccessSource(ctx, ref_name, getNodeSource(ctx, key), false);
                appendBindingStatement(ctx, buf, keyword, getNodeSource(ctx, value), access) catch return;
            },
            .computed_property => {
                const prop_data = ctx.nodeData(prop);
                const key = prop_data.binary.lhs;
                const value = prop_data.binary.rhs;
                if (key == .none or value == .none) return;
                if (ctx.nodeTag(value) != .identifier and ctx.nodeTag(value) != .member_expr and ctx.nodeTag(value) != .computed_member_expr) return;
                const keyword = if (declare_targets) decl_keyword else "";
                const access = std.fmt.allocPrint(ctx.allocator, "{s}[{s}]", .{ ref_name, getNodeSource(ctx, key) }) catch return;
                appendBindingStatement(ctx, buf, keyword, getNodeSource(ctx, value), access) catch return;
            },
            .rest_element => return,
            else => return,
        }
    }
}

fn emitLoopHeadObjectPatternWithRest(
    ctx: *TransformContext,
    pattern: NodeIndex,
    ref_name: []const u8,
    decl_keyword: []const u8,
    rs: u32,
    re: u32,
    buf: *std.ArrayListUnmanaged(u8),
) void {
    const pattern_source = buildObjectPatternSourceWithoutRest(ctx, pattern, rs, re);
    const rest_target = getObjectPatternRestIdentifier(ctx, rs, re) orelse {
        if (pattern_source.len == 0) return;
        buf.appendSlice(ctx.allocator, decl_keyword) catch return;
        buf.append(ctx.allocator, ' ') catch return;
        buf.appendSlice(ctx.allocator, pattern_source) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, ref_name) catch return;
        buf.appendSlice(ctx.allocator, ";\n") catch return;
        return;
    };

    const excluded_source = buildObjectRestExcludedKeysSource(ctx, rs, re, &.{}, countComputedProperties(ctx, rs, re));
    const excluded_ref = hoistLoopHeadExcludedKeys(ctx, pattern, excluded_source);
    const helper_name = if (g_config.object_rest_no_symbols or g_config.loose)
        "babelHelpers.objectWithoutPropertiesLoose"
    else
        "babelHelpers.objectWithoutProperties";
    const rest_value = std.fmt.allocPrint(
        ctx.allocator,
        "{s}({s}, {s})",
        .{ helper_name, ref_name, excluded_ref },
    ) catch return;

    buf.appendSlice(ctx.allocator, decl_keyword) catch return;
    buf.append(ctx.allocator, ' ') catch return;
    if (pattern_source.len > 0) {
        buf.appendSlice(ctx.allocator, pattern_source) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, ref_name) catch return;
        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
    }
    buf.appendSlice(ctx.allocator, getNodeSource(ctx, rest_target)) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, rest_value) catch return;
    buf.appendSlice(ctx.allocator, ";\n") catch return;
}

fn buildObjectPatternSourceWithoutRest(
    ctx: *TransformContext,
    pattern: NodeIndex,
    rs: u32,
    re: u32,
) []const u8 {
    _ = pattern;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var emitted_any = false;

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop: NodeIndex = @enumFromInt(prop_idx);
        if (ctx.nodeTag(prop) == .rest_element) continue;

        if (!emitted_any) {
            buf.appendSlice(ctx.allocator, "{\n") catch return "";
        } else {
            buf.appendSlice(ctx.allocator, ",\n") catch return "";
        }
        emitted_any = true;
        buf.appendSlice(ctx.allocator, "    ") catch return "";
        buf.appendSlice(ctx.allocator, getNodeSource(ctx, prop)) catch return "";
    }

    if (!emitted_any) return "";
    buf.appendSlice(ctx.allocator, "\n  }") catch return "";
    return buf.items;
}

fn getObjectPatternRestIdentifier(ctx: *TransformContext, rs: u32, re: u32) ?NodeIndex {
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[prop_idx] != .rest_element) continue;
        const rest_target = ctx.ast.nodes.items(.data)[prop_idx].unary;
        if (rest_target == .none or ctx.nodeTag(rest_target) != .identifier) return null;
        return rest_target;
    }
    return null;
}

fn hoistLoopHeadExcludedKeys(ctx: *TransformContext, pattern: NodeIndex, excluded: []const u8) []const u8 {
    if (excluded.len == 0 or std.mem.eql(u8, excluded, "[]")) return excluded;
    if (std.mem.indexOfScalar(u8, excluded, '`') != null or std.mem.indexOfScalar(u8, excluded, '[') != 0) return excluded;
    if (std.mem.indexOf(u8, excluded, ".map(") != null) return excluded;

    const body_idx = findEnclosingBody(ctx, pattern);
    const name = allocNextRefName(ctx, "_excluded");
    const keyword = if (g_config.rewrite_block_scoped_bindings) "var" else "const";
    const prefix = std.fmt.allocPrint(ctx.allocator, "{s} {s} = {s};", .{ keyword, name, excluded }) catch return excluded;
    appendPrefixToBlockOrProgram(ctx, body_idx, prefix);
    return name;
}

fn appendPrefixToBlockOrProgram(ctx: *TransformContext, body_idx: u32, prefix: []const u8) void {
    if (prefix.len == 0) return;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (ctx.ast.block_prefix_source.get(body_idx)) |existing| {
        buf.appendSlice(ctx.allocator, existing) catch return;
        if (existing.len > 0 and existing[existing.len - 1] != '\n') {
            buf.append(ctx.allocator, '\n') catch return;
        }
    }
    buf.appendSlice(ctx.allocator, prefix) catch return;
    ctx.ast.block_prefix_source.put(ctx.allocator, body_idx, buf.items) catch return;
}

fn objectPatternHasComputedProperty(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .object_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[prop_idx] == .computed_property) return true;
    }
    return false;
}

fn arrayPatternSupportsSimpleStatementLowering(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .array_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        switch (ctx.ast.nodes.items(.tag)[elem_idx]) {
            .removed, .empty_statement, .identifier, .member_expr, .computed_member_expr => {},
            .object_pattern => {
                if (!isEmptyPattern(ctx, @enumFromInt(elem_idx))) return false;
            },
            .array_pattern => {
                if (!arrayPatternSupportsSimpleStatementLowering(ctx, @enumFromInt(elem_idx))) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn appendObjectDestructuringEmptyStatement(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    expr: []const u8,
) !void {
    try appendObjectDestructuringEmptyCall(ctx, buf, expr);
    try buf.append(ctx.allocator, '\n');
}

fn appendObjectDestructuringEmptyCall(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    expr: ?[]const u8,
) !void {
    try buf.appendSlice(ctx.allocator, "babelHelpers.objectDestructuringEmpty(");
    if (expr) |src| try buf.appendSlice(ctx.allocator, src);
    try buf.appendSlice(ctx.allocator, ");");
}

fn appendBindingStatement(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    keyword: []const u8,
    name: []const u8,
    expr: []const u8,
) !void {
    if (keyword.len > 0) {
        try buf.appendSlice(ctx.allocator, keyword);
        try buf.append(ctx.allocator, ' ');
    }
    try buf.appendSlice(ctx.allocator, name);
    try buf.appendSlice(ctx.allocator, " = ");
    try buf.appendSlice(ctx.allocator, expr);
    try buf.appendSlice(ctx.allocator, ";\n");
}

fn appendRawStatement(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    src: []const u8,
) !void {
    try buf.appendSlice(ctx.allocator, src);
    try buf.appendSlice(ctx.allocator, ";\n");
}

fn appendIndentedBlockSource(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    src: []const u8,
    indent: []const u8,
) void {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        buf.appendSlice(ctx.allocator, indent) catch return;
        buf.appendSlice(ctx.allocator, line) catch return;
        buf.append(ctx.allocator, '\n') catch return;
    }
}

fn wrapStatementBlock(ctx: *TransformContext, src: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "{\n") catch return src;
    appendIndentedBlockSource(ctx, &buf, src, "  ");
    buf.append(ctx.allocator, '}') catch return src;
    return buf.items;
}

fn requiresStatementBlockWrapper(ctx: *TransformContext, container: NodeIndex, stmt: NodeIndex) bool {
    if (container == .none or stmt == .none) return false;
    switch (ctx.nodeTag(container)) {
        .if_statement => {
            const data = ctx.nodeData(container);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return false;
            const consequent: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            const alternate: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);
            return consequent == stmt or alternate == stmt;
        },
        else => return false,
    }
}

fn appendPrefixToBody(ctx: *TransformContext, body: NodeIndex, prefix: []const u8) void {
    if (prefix.len == 0 or body == .none) return;
    const body_i = @intFromEnum(body);
    if (ctx.nodeTag(body) == .block_statement) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        if (ctx.ast.block_prefix_source.get(body_i)) |existing| {
            buf.appendSlice(ctx.allocator, existing) catch return;
            if (existing.len > 0 and existing[existing.len - 1] != '\n') {
                buf.append(ctx.allocator, '\n') catch return;
            }
        }
        buf.appendSlice(ctx.allocator, prefix) catch return;
        ctx.ast.block_prefix_source.put(ctx.allocator, body_i, buf.items) catch return;
    }
}

fn wrapBlockBodyWithPrefix(ctx: *TransformContext, body: NodeIndex, prefix: []const u8) void {
    if (prefix.len == 0 or body == .none or ctx.nodeTag(body) != .block_statement) return;
    const body_src = getCurrentNodeSource(ctx, body);
    const inner_src = trimBlockBraces(body_src);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "{\n") catch return;
    appendIndentedBlockSource(ctx, &buf, prefix, "  ");
    buf.appendSlice(ctx.allocator, "  {\n") catch return;
    appendIndentedBlockSource(ctx, &buf, inner_src, "    ");
    buf.appendSlice(ctx.allocator, "  }\n}") catch return;
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(body), buf.items) catch return;
}

fn getCurrentNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;
    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    return ctx.ast.source[start..end];
}

fn trimBlockBraces(src: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    }
    return trimmed;
}

fn statementNeedsCompletionValue(ctx: *TransformContext, stmt: NodeIndex) bool {
    const parent = findParentOf(ctx, stmt) orelse return isLastStatementInRange(ctx, stmt, 0, getProgramRangeEnd(ctx));
    switch (ctx.nodeTag(parent)) {
        .program => {
            const data = ctx.nodeData(parent);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
            return isLastStatementInRange(ctx, stmt, ctx.ast.extra_data.items[extra_idx], ctx.ast.extra_data.items[extra_idx + 1]);
        },
        .switch_case, .switch_default => {
            const data = ctx.nodeData(parent);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return false;
            const start = ctx.ast.extra_data.items[extra_idx + 1];
            const end = ctx.ast.extra_data.items[extra_idx + 2];
            return isLastStatementInRange(ctx, stmt, start, end);
        },
        else => return false,
    }
}

fn getProgramRangeEnd(ctx: *TransformContext) u32 {
    const tags = ctx.ast.nodes.items(.tag);
    if (tags.len == 0 or tags[0] != .program) return 0;
    const data = ctx.ast.nodes.items(.data)[0];
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return 0;
    return ctx.ast.extra_data.items[extra_idx + 1];
}

fn isLastStatementInRange(ctx: *TransformContext, stmt: NodeIndex, range_start: u32, range_end: u32) bool {
    const stmt_i = @intFromEnum(stmt);
    if (range_end <= range_start or range_end > ctx.ast.extra_data.items.len) return false;

    var found_stmt = false;
    for (ctx.ast.extra_data.items[range_start..range_end]) |raw| {
        if (raw >= ctx.ast.nodes.items(.tag).len) continue;
        const tag = ctx.ast.nodes.items(.tag)[raw];
        if (tag == .removed) continue;
        if (!found_stmt) {
            if (raw == stmt_i) found_stmt = true;
            continue;
        }
        return false;
    }
    return found_stmt;
}

fn isLastInSequenceExpr(ctx: *TransformContext, node: NodeIndex, sequence: NodeIndex) bool {
    if (sequence == .none or ctx.nodeTag(sequence) != .sequence_expr) return false;
    const data = ctx.nodeData(sequence);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    if (re <= rs or re > ctx.ast.extra_data.items.len) return false;

    const node_i = @intFromEnum(node);
    var i = re;
    while (i > rs) {
        i -= 1;
        const raw = ctx.ast.extra_data.items[i];
        if (raw >= ctx.ast.nodes.items(.tag).len) continue;
        if (ctx.ast.nodes.items(.tag)[raw] == .removed) continue;
        return raw == node_i;
    }
    return false;
}

fn isArrowBodyNode(ctx: *TransformContext, arrow: NodeIndex, node: NodeIndex) bool {
    if (arrow == .none or ctx.nodeTag(arrow) != .arrow_function_expr) return false;
    const data = ctx.nodeData(arrow);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return false;
    const third = ctx.ast.extra_data.items[extra_idx + 2];
    if (third <= 1) {
        const body_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
        return body_node == node;
    }
    const body_node: NodeIndex = @enumFromInt(third);
    return body_node == node;
}

fn emitPropertyWithDefault(
    ctx: *TransformContext,
    assignment_pattern: NodeIndex,
    init_source: []const u8,
    key_source: ?[]const u8,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    const data = ctx.nodeData(assignment_pattern);
    const target = data.binary.lhs;
    const default_val = data.binary.rhs;
    if (target == .none) return;

    const raw_target_name = getNodeSource(ctx, target);
    const target_name = rewriteLoopBodyBlockScopedBindingName(ctx, target, raw_target_name);
    const default_source = getNodeSource(ctx, default_val);
    const prop_name = key_source orelse raw_target_name;

    // Generate temp: _init$prop = init.prop
    const temp_name = allocRefName(ctx, init_source, prop_name);

    if (!first.*) {
        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
    }
    first.* = false;
    buf.appendSlice(ctx.allocator, temp_name) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, init_source) catch return;
    buf.append(ctx.allocator, '.') catch return;
    buf.appendSlice(ctx.allocator, prop_name) catch return;

    buf.appendSlice(ctx.allocator, ",\n  ") catch return;
    buf.appendSlice(ctx.allocator, target_name) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, temp_name) catch return;
    buf.appendSlice(ctx.allocator, " === void 0 ? ") catch return;
    buf.appendSlice(ctx.allocator, default_source) catch return;
    buf.appendSlice(ctx.allocator, " : ") catch return;
    buf.appendSlice(ctx.allocator, temp_name) catch return;
}

fn emitPatternWithDefault(
    ctx: *TransformContext,
    assignment_pattern: NodeIndex,
    init_source: []const u8,
    key_source: ?[]const u8,
    buf: *std.ArrayListUnmanaged(u8),
    first: *bool,
) void {
    const data = ctx.nodeData(assignment_pattern);
    const target = data.binary.lhs;
    const default_val = data.binary.rhs;
    if (target == .none) return;

    const target_tag = ctx.nodeTag(target);
    if (target_tag != .object_pattern and target_tag != .array_pattern) {
        emitPropertyWithDefault(ctx, assignment_pattern, init_source, key_source, buf, first);
        return;
    }

    const default_source = getNodeSource(ctx, default_val);
    const prop_name = key_source orelse getNodeSource(ctx, target);
    const temp_name = allocRefName(ctx, init_source, prop_name);

    if (!first.*) {
        buf.appendSlice(ctx.allocator, ",\n  ") catch return;
    }
    first.* = false;
    buf.appendSlice(ctx.allocator, temp_name) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, init_source) catch return;
    buf.appendSlice(ctx.allocator, ".") catch return;
    buf.appendSlice(ctx.allocator, prop_name) catch return;

    switch (target_tag) {
        .object_pattern => {
            const default_ref = allocNextRefName(ctx, temp_name);
            if (!first.*) {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            }
            first.* = false;
            buf.appendSlice(ctx.allocator, default_ref) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            buf.appendSlice(ctx.allocator, " === void 0 ? ") catch return;
            buf.appendSlice(ctx.allocator, default_source) catch return;
            buf.appendSlice(ctx.allocator, " : ") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            emitObjectDestructuringStr(ctx, target, default_ref, buf, first);
        },
        .array_pattern => {
            const default_ref = allocNextRefName(ctx, temp_name);
            if (!first.*) {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            }
            first.* = false;
            buf.appendSlice(ctx.allocator, default_ref) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            buf.appendSlice(ctx.allocator, " === void 0 ? ") catch return;
            buf.appendSlice(ctx.allocator, default_source) catch return;
            buf.appendSlice(ctx.allocator, " : ") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            const nested_ref = allocNextRefName(ctx, temp_name);
            buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            buf.appendSlice(ctx.allocator, nested_ref) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            const count = countArrayPatternElements(ctx, target);
            buf.appendSlice(ctx.allocator, "babelHelpers.slicedToArray(") catch return;
            buf.appendSlice(ctx.allocator, default_ref) catch return;
            buf.appendSlice(ctx.allocator, ", ") catch return;
            const count_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{count}) catch return;
            buf.appendSlice(ctx.allocator, count_str) catch return;
            buf.appendSlice(ctx.allocator, ")") catch return;
            emitArrayDestructuringStr(ctx, target, nested_ref, buf, first);
        },
        else => emitPropertyWithDefault(ctx, assignment_pattern, init_source, key_source, buf, first),
    }
}

fn buildPropertyAccessSource(ctx: *TransformContext, init_source: []const u8, key_source: []const u8, use_bracket: bool) []const u8 {
    return if (use_bracket)
        std.fmt.allocPrint(ctx.allocator, "{s}[{s}]", .{ init_source, key_source }) catch init_source
    else
        std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ init_source, key_source }) catch init_source;
}

fn countArrayPatternElements(ctx: *TransformContext, pattern: NodeIndex) u32 {
    if (pattern == .none) return 0;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return 0;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    var count: u32 = 0;
    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem_tag = ctx.ast.nodes.items(.tag)[elem_idx];
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;
        count += 1;
    }
    return count;
}

fn arrayPatternHasRest(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .array_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[elem_idx] == .rest_element) return true;
    }
    return false;
}

fn isKnownArrayIdentifierInit(ctx: *TransformContext, init: NodeIndex) bool {
    if (init == .none or ctx.nodeTag(init) != .identifier) return false;
    const scope_result = ctx.scope orelse return false;
    const scope_idx = scope_mod.getScopeForNode(scope_result, init) orelse return false;
    const name = getNodeSource(ctx, init);
    const binding = scope_mod.getBinding(scope_result, scope_idx, name) orelse return false;
    const declarator = findParentOf(ctx, binding.node) orelse return false;
    if (ctx.nodeTag(declarator) != .declarator) return false;
    const rhs = ctx.nodeData(declarator).binary.rhs;
    return rhs != .none and ctx.nodeTag(rhs) == .array_expr;
}

fn allocRef(ctx: *TransformContext) []const u8 {
    return allocRefFromPrefix(ctx, "ref");
}

fn allocDiscardRef(ctx: *TransformContext) []const u8 {
    if (!g_used_names.contains("_")) {
        g_used_names.put(ctx.allocator, "_", {}) catch {};
        return "_";
    }
    var counter: u32 = 2;
    while (counter < 100) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "_{d}", .{counter}) catch return allocRef(ctx);
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    return allocRef(ctx);
}

/// Allocate a ref name based on the init expression name: _name, _name2, etc.
fn allocRefFromName(ctx: *TransformContext, name: []const u8) []const u8 {
    return allocRefFromPrefix(ctx, name);
}

fn allocRefFromPrefix(ctx: *TransformContext, prefix: []const u8) []const u8 {
    const first = std.fmt.allocPrint(ctx.allocator, "_{s}", .{prefix}) catch return "_ref";
    // Check if this name is already used (from a previous destructuring in this file)
    if (!g_used_names.contains(first)) {
        g_used_names.put(ctx.allocator, first, {}) catch {};
        return first;
    }
    var counter: u32 = 2;
    while (counter < 10) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ prefix, counter }) catch return "_ref";
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    for ([_]u32{ 0, 1 }) |special| {
        const candidate = std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ prefix, special }) catch return "_ref";
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    counter = 10;
    while (counter < 100) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ prefix, counter }) catch return "_ref";
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    return "_ref";
}

var g_used_names: std.StringHashMapUnmanaged(void) = .empty;

fn allocInitTemp(ctx: *TransformContext, init: NodeIndex) []const u8 {
    if (init == .none) return allocRef(ctx);
    const init_tag = ctx.nodeTag(init);
    if (init_tag == .identifier) {
        return allocRefFromName(ctx, getNodeSource(ctx, init));
    }
    if (init_tag == .numeric_literal) return allocDiscardRef(ctx);
    if (init_tag == .string_literal) {
        return allocRefFromSanitizedSource(ctx, getNodeSource(ctx, init));
    }
    if (init_tag == .object_expr) {
        if (getObjectExprTempNameSource(ctx, init)) |key_source| {
            return allocRefFromSanitizedSource(ctx, key_source);
        }
        return allocRefFromSanitizedSource(ctx, getNodeSource(ctx, init));
    }
    if (init_tag == .call_expr or init_tag == .optional_call_expr) {
        const data = ctx.nodeData(init);
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < ctx.ast.extra_data.items.len) {
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const callee_tag = ctx.nodeTag(callee);
            if (callee_tag == .member_expr or callee_tag == .optional_chain_expr) {
                const callee_data = ctx.nodeData(callee);
                const object = callee_data.binary.lhs;
                if (object != .none and ctx.nodeTag(object) != .identifier) {
                    const prop = getMemberPropertyName(ctx, callee);
                    if (prop.len > 0) return allocRefFromName(ctx, prop);
                }
                const callee_src = getNodeSource(ctx, callee);
                return allocRefFromSanitizedSource(ctx, callee_src);
            }
            if (callee_tag == .identifier) {
                return allocRefFromName(ctx, getNodeSource(ctx, callee));
            }
        }
        return allocRef(ctx);
    }
    return allocRef(ctx);
}

fn getObjectExprTempNameSource(ctx: *TransformContext, init: NodeIndex) ?[]const u8 {
    if (init == .none or ctx.nodeTag(init) != .object_expr) return null;
    const data = ctx.nodeData(init);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return null;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) return null;
        const prop: NodeIndex = @enumFromInt(prop_idx);
        const key_source = getObjectExprPropertyTempNameSource(ctx, prop) orelse return null;
        if (!first) buf.append(ctx.allocator, '$') catch return null;
        buf.appendSlice(ctx.allocator, key_source) catch return null;
        first = false;
    }
    if (first) return null;
    return buf.items;
}

fn getObjectExprPropertyTempNameSource(ctx: *TransformContext, prop: NodeIndex) ?[]const u8 {
    switch (ctx.nodeTag(prop)) {
        .property, .computed_property => {
            const key = ctx.nodeData(prop).binary.lhs;
            if (key == .none) return null;
            return getNodeSource(ctx, key);
        },
        .shorthand_property => {
            const value = ctx.nodeData(prop).unary;
            if (value == .none) return ctx.tokenSlice(ctx.mainToken(prop));
            if (ctx.nodeTag(value) == .assignment_pattern) {
                const lhs = ctx.nodeData(value).binary.lhs;
                if (lhs != .none) return getNodeSource(ctx, lhs);
            }
            return getNodeSource(ctx, value);
        },
        else => return null,
    }
}

fn allocArrayHelperRef(ctx: *TransformContext, base: []const u8) []const u8 {
    if (std.mem.eql(u8, base, "_")) return allocRefFromName(ctx, "ref");
    return allocSiblingRefName(ctx, base);
}

fn rewriteLoopBodyBlockScopedBindingName(ctx: *TransformContext, node: NodeIndex, name: []const u8) []const u8 {
    if (!g_config.rewrite_block_scoped_bindings) return name;
    const decl = findBindingDeclarationNode(ctx, node) orelse return name;
    if (isInForHead(ctx, decl)) return name;
    if (!destructuringPatternInLoop(ctx, decl)) return name;
    return allocRefFromName(ctx, name);
}

fn findBindingDeclarationNode(ctx: *TransformContext, node: NodeIndex) ?NodeIndex {
    var current = node;
    while (current != .none) {
        const parent = findParentOf(ctx, current) orelse return null;
        switch (ctx.nodeTag(parent)) {
            .var_declaration, .let_declaration, .const_declaration => return parent,
            else => current = parent,
        }
    }
    return null;
}

fn getMemberPropertyName(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const tag = ctx.nodeTag(node);
    if (tag != .member_expr and tag != .optional_chain_expr) return "";
    const data = ctx.nodeData(node);
    if (data.binary.rhs == .none) return "";
    return ctx.ast.tokenSlice(@enumFromInt(@intFromEnum(data.binary.rhs)));
}

fn allocRefFromSanitizedSource(ctx: *TransformContext, src: []const u8) []const u8 {
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    name_buf.append(ctx.allocator, '_') catch return allocRef(ctx);
    for (src) |c| {
        if (c == '.' or c == '[' or c == ']') {
            name_buf.append(ctx.allocator, '$') catch return allocRef(ctx);
        } else if (isIdentCont(c)) {
            name_buf.append(ctx.allocator, c) catch return allocRef(ctx);
        }
    }
    while (name_buf.items.len > 1 and name_buf.items[1] == '$') {
        _ = name_buf.orderedRemove(1);
    }
    while (name_buf.items.len > 1 and name_buf.items[name_buf.items.len - 1] == '$') {
        _ = name_buf.pop();
    }
    if (name_buf.items.len == 1) return allocRef(ctx);
    if (!g_used_names.contains(name_buf.items)) {
        g_used_names.put(ctx.allocator, name_buf.items, {}) catch return name_buf.items;
        return name_buf.items;
    }
    var counter: u32 = 2;
    while (counter < 10) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ name_buf.items, counter }) catch return allocRef(ctx);
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch return candidate;
            return candidate;
        }
    }
    for ([_]u32{ 0, 1 }) |special| {
        const candidate = std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ name_buf.items, special }) catch return allocRef(ctx);
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch return candidate;
            return candidate;
        }
    }
    counter = 10;
    while (counter < 100) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ name_buf.items, counter }) catch return allocRef(ctx);
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch return candidate;
            return candidate;
        }
    }
    return allocRef(ctx);
}

fn allocRefName(ctx: *TransformContext, base: []const u8, prop: []const u8) []const u8 {
    // Generate a name like _base$prop (following Babel convention)
    // Sanitize: replace dots with $
    const prop_part = if (prop.len > 2 and std.mem.endsWith(u8, prop, "es")) prop[0 .. prop.len - 2] else prop;
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    if (base.len == 0 or base[0] != '_') {
        name_buf.append(ctx.allocator, '_') catch return "_ref";
    }

    for (base) |c| {
        if (c == '.' or c == '[' or c == ']') {
            name_buf.append(ctx.allocator, '$') catch return "_ref";
        } else if (isIdentCont(c) or c == '_' or c == '$') {
            name_buf.append(ctx.allocator, c) catch return "_ref";
        }
    }
    name_buf.append(ctx.allocator, '$') catch return "_ref";
    name_buf.appendSlice(ctx.allocator, prop_part) catch return "_ref";

    if (!g_used_names.contains(name_buf.items)) {
        g_used_names.put(ctx.allocator, name_buf.items, {}) catch return name_buf.items;
        return name_buf.items;
    }
    var counter: u32 = 2;
    while (counter < 100) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ name_buf.items, counter }) catch return "_ref";
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch return candidate;
            return candidate;
        }
    }
    return name_buf.items;
}

fn allocNextRefName(ctx: *TransformContext, base: []const u8) []const u8 {
    if (!g_used_names.contains(base)) {
        g_used_names.put(ctx.allocator, base, {}) catch {};
        return base;
    }
    var counter: u32 = 2;
    while (counter < 100) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ base, counter }) catch return allocRef(ctx);
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    return allocRef(ctx);
}

fn allocSiblingRefName(ctx: *TransformContext, base: []const u8) []const u8 {
    var stem_end = base.len;
    while (stem_end > 0 and std.ascii.isDigit(base[stem_end - 1])) : (stem_end -= 1) {}
    if (stem_end < base.len) {
        const stem = base[0..stem_end];
        const suffix = std.fmt.parseUnsigned(u32, base[stem_end..], 10) catch return allocNextRefName(ctx, base);
        if (suffix == 9) {
            const zero_candidate = std.fmt.allocPrint(ctx.allocator, "{s}0", .{stem}) catch return allocRef(ctx);
            if (!g_used_names.contains(zero_candidate)) {
                g_used_names.put(ctx.allocator, zero_candidate, {}) catch {};
                return zero_candidate;
            }
        }
        var counter = suffix + 1;
        while (counter < 100) : (counter += 1) {
            const candidate = std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ stem, counter }) catch return allocRef(ctx);
            if (!g_used_names.contains(candidate)) {
                g_used_names.put(ctx.allocator, candidate, {}) catch {};
                return candidate;
            }
        }
    }
    return allocNextRefName(ctx, base);
}

fn registerTempForBody(ctx: *TransformContext, name: []const u8, body_idx: u32) void {
    const gop = g_body_temps.getOrPut(ctx.allocator, body_idx) catch return;
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }
    for (gop.value_ptr.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    gop.value_ptr.append(ctx.allocator, name) catch {};
}

fn findEnclosingBody(ctx: *TransformContext, node: NodeIndex) u32 {
    const target_start = getNodeStart(ctx, node);
    const target_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(node)];
    const tags = ctx.ast.nodes.items(.tag);

    var best_body: u32 = 0;
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

        const func_start = getNodeStart(ctx, @enumFromInt(ni));
        const func_end = ctx.ast.nodes.items(.end_offset)[ni];
        if (func_start > target_start or func_end < target_end) continue;

        const range: u64 = @as(u64, func_end) - @as(u64, func_start);
        if (range < best_range) {
            best_range = range;
            if (getFunctionBody(ctx, @enumFromInt(ni))) |body| {
                best_body = @intFromEnum(body);
            }
        }
    }

    return best_body;
}

fn getFunctionBody(ctx: *TransformContext, func_node: NodeIndex) ?NodeIndex {
    const ni = @intFromEnum(func_node);
    const tag = ctx.ast.nodes.items(.tag)[ni];
    const d = ctx.ast.nodes.items(.data)[ni];
    switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        => {
            const eidx = @intFromEnum(d.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
            }
        },
        .method_definition, .class_method, .class_private_method => {
            const eidx = @intFromEnum(d.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
            }
        },
        else => {},
    }
    return null;
}

fn isIdentCont(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or (c >= '0' and c <= '9');
}

fn shouldTempObjectInit(ctx: *TransformContext, init: NodeIndex) bool {
    if (init == .none) return false;
    return switch (ctx.nodeTag(init)) {
        .call_expr, .optional_call_expr, .new_expr, .sequence_expr => true,
        else => false,
    };
}

fn getInitSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "undefined";
    const tag = ctx.nodeTag(node);
    if (ctx.ast.replacement_source.get(@intFromEnum(node))) |replacement| {
        return if (tag == .object_expr or tag == .array_expr or ctx.had_ts_strip_pass)
            indentInlineSource(ctx, replacement, "  ")
        else
            replacement;
    }
    if (ctx.had_ts_strip_pass) {
        return indentInlineSource(ctx, getNodeGeneratedSource(ctx, node), "  ");
    }
    if (tag == .object_expr or tag == .array_expr) {
        return indentInlineSource(ctx, getNodeGeneratedSource(ctx, node), "  ");
    }
    if (tag == .call_expr or tag == .optional_call_expr or tag == .new_expr) {
        return getNodeGeneratedSource(ctx, node);
    }
    return getNodeSource(ctx, node);
}

fn getNodeGeneratedSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const comment_count = ctx.ast.comments.items.len;
    var emitted = std.DynamicBitSetUnmanaged.initEmpty(ctx.allocator, comment_count) catch {
        return getNodeSource(ctx, node);
    };
    emitted.setRangeValue(.{ .start = 0, .end = comment_count }, true);

    var cg = Codegen{
        .ast = ctx.ast,
        .buf = .empty,
        .allocator = ctx.allocator,
        .source_map = null,
        .emit_comments = false,
        .emitted_comments = emitted,
    };
    cg.emitNode(node) catch return getNodeSource(ctx, node);
    return cg.buf.toOwnedSlice(ctx.allocator) catch getNodeSource(ctx, node);
}

fn indentInlineSource(ctx: *TransformContext, src: []const u8, indent: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src, '\n') == null) return src;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            result.append(ctx.allocator, '\n') catch return src;
            result.appendSlice(ctx.allocator, indent) catch return src;
        }
        first = false;
        result.appendSlice(ctx.allocator, line) catch return src;
    }
    return result.items;
}

/// Get the source text for a node.
fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return "";

    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;
    if (!hasReplacementInSubtree(ctx, node)) {
        const start = getNodeStart(ctx, node);
        const end = ctx.ast.nodes.items(.end_offset)[ni];
        if (start >= end or end > ctx.ast.source.len) return "";
        return ctx.ast.source[start..end];
    }

    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";

    const Substitution = struct {
        abs_start: u32,
        abs_end: u32,
        replacement: []const u8,
    };
    var subs: std.ArrayListUnmanaged(Substitution) = .empty;

    var iter = ctx.ast.replacement_source.iterator();
    while (iter.next()) |entry| {
        const child_ni = entry.key_ptr.*;
        if (child_ni >= ctx.ast.nodes.items(.tag).len or child_ni == ni) continue;
        const child_start = getNodeStart(ctx, @enumFromInt(child_ni));
        const child_end = ctx.ast.nodes.items(.end_offset)[child_ni];
        if (child_start >= start and child_end <= end) {
            subs.append(ctx.allocator, .{
                .abs_start = child_start,
                .abs_end = child_end,
                .replacement = entry.value_ptr.*,
            }) catch return ctx.ast.source[start..end];
        }
    }

    if (subs.items.len == 0) return ctx.ast.source[start..end];

    std.mem.sort(Substitution, subs.items, {}, struct {
        fn lt(_: void, a: Substitution, b: Substitution) bool {
            return a.abs_start < b.abs_start;
        }
    }.lt);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var cursor = start;
    for (subs.items) |sub| {
        if (sub.abs_start < cursor) continue;
        if (sub.abs_start > cursor) {
            result.appendSlice(ctx.allocator, ctx.ast.source[cursor..sub.abs_start]) catch return ctx.ast.source[start..end];
        }
        result.appendSlice(ctx.allocator, sub.replacement) catch return ctx.ast.source[start..end];
        cursor = sub.abs_end;
    }
    if (cursor < end) {
        result.appendSlice(ctx.allocator, ctx.ast.source[cursor..end]) catch return ctx.ast.source[start..end];
    }
    return result.items;
}

fn hasReplacementInSubtree(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return false;
    if (ctx.ast.replacement_source.get(ni) != null) return true;

    const children = visitor.getChildren(ctx.ast, node);
    for (children.items[0..children.len]) |child| {
        if (hasReplacementInSubtree(ctx, child)) return true;
    }
    if (children.range_end > children.range_start) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (hasReplacementInSubtree(ctx, @enumFromInt(raw))) return true;
        }
    }
    if (children.range2_end > children.range2_start) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (hasReplacementInSubtree(ctx, @enumFromInt(raw))) return true;
        }
    }
    return false;
}

fn getNodeStart(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ctx.ast.node_start_overrides.get(ni)) |override| return override;

    const tag = ctx.ast.nodes.items(.tag)[ni];
    const data = ctx.ast.nodes.items(.data)[ni];
    switch (tag) {
        .call_expr, .optional_call_expr => {
            const eidx = @intFromEnum(data.extra);
            if (eidx < ctx.ast.extra_data.items.len) {
                const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
                return getNodeStart(ctx, callee);
            }
        },
        .member_expr,
        .computed_member_expr,
        .optional_chain_expr,
        .optional_computed_member_expr,
        => return getNodeStart(ctx, data.binary.lhs),
        .binary_expr,
        .logical_expr,
        .assignment_expr,
        .conditional_expr,
        .ts_as_expression,
        .ts_satisfies_expression,
        => return getNodeStart(ctx, data.binary.lhs),
        .ts_non_null_expression,
        .expression_statement,
        .return_statement,
        => return getNodeStart(ctx, data.unary),
        else => {},
    }

    const main_tok = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
}
