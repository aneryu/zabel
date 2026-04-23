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

// ── Configuration ───────────────────────────────────────────────────

pub const Config = struct {
    /// When true, use `== null` instead of `=== null || === void 0`.
    no_document_all: bool = false,
    /// When true, member access is considered pure (no temp var needed for intermediate access).
    pure_getters: bool = false,
    /// Loose mode: skip .call() context preservation, allow repeated member access without temps.
    /// This is separate from no_document_all which only affects the null check form.
    loose: bool = false,
};

var g_config: Config = .{};

/// Set of temp names already allocated (to avoid duplicates within a file).
var g_allocated_names: std.StringHashMapUnmanaged(void) = .empty;

/// Temp names grouped by their enclosing body node (for block_prefix_source).
pub var g_body_temps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)) = .empty;

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.optional_chain_expr));
    filter.set(@intFromEnum(Node.Tag.optional_computed_member_expr));
    filter.set(@intFromEnum(Node.Tag.optional_call_expr));
    filter.set(@intFromEnum(Node.Tag.member_expr));
    filter.set(@intFromEnum(Node.Tag.computed_member_expr));
    filter.set(@intFromEnum(Node.Tag.call_expr));
    return .{
        .name = "optional_chaining",
        .node_filter = filter,
        .enter = enterNode,
        .priority = 20,
    };
}

pub fn resetState() void {
    g_allocated_names = .{};
    g_body_temps = .{};
}

// ── Entry point ────────────────────────────────────────────────────

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (!containsOptionalChain(ctx, idx)) return .continue_traversal;

    // Only process if this is the outermost chain-containing node.
    if (isInsideChainParent(ctx, idx)) return .continue_traversal;

    const transform_idx = selectDefaultParamTransformRoot(ctx, idx);

    const temp_body_idx = findEnclosingBody(ctx, transform_idx);
    const temp_count_before = getBodyTempCount(temp_body_idx);
    const in_param_default = isInFunctionParameterDefault(ctx, transform_idx);

    const result = transformChain(ctx, transform_idx);
    if (result.len > 0) {
        const normalized_result = normalizeGeneratedSource(ctx, result);
        const wrapped_param_result = if (in_param_default)
            maybeWrapParameterDefaultIife(ctx, temp_body_idx, temp_count_before, normalized_result)
        else
            normalized_result;
        // For delete context, the replacement needs to go on the unary_expr (delete) node
        // instead of the chain node, so the codegen replaces the entire `delete expr` with
        // the transformed `expr || delete chain`.
        const context = determineContext(ctx, transform_idx);
        if (context == .delete_expr) {
            const parent = findParentOf(ctx, transform_idx);
            if (parent != .none) {
                ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(parent), wrapped_param_result) catch {};
                return .skip_children;
            }
        }

        // For expression context inside a unary prefix operator (+ - ~ typeof void !),
        // wrap in parens so the replacement binds correctly.
        var final_result = wrapped_param_result;
        var target_idx = transform_idx;
        if (context != .delete_expr) {
            while (true) {
                const wrapper_parent = findTransparentWrapperParent(ctx, target_idx);
                if (wrapper_parent == .none) break;
                if (in_param_default and
                    ctx.nodeTag(wrapper_parent) == .parenthesized_expr and
                    isImmediateIifeCallSource(final_result))
                {
                    target_idx = wrapper_parent;
                    continue;
                }
                final_result = applyParentTransparentWrapper(ctx, final_result, wrapper_parent, target_idx);
                target_idx = wrapper_parent;
            }
        }

        if (target_idx == transform_idx and shouldReplayMissingSourceParens(ctx, transform_idx)) {
            final_result = std.fmt.allocPrint(ctx.allocator, "({s})", .{final_result}) catch final_result;
        }
        if ((ctx.nodeTag(target_idx) == .sequence_expr and shouldReplayMissingSourceParens(ctx, target_idx)) or
            (ctx.ast.create_parenthesized_expressions and target_idx != transform_idx and ctx.nodeTag(target_idx) == .sequence_expr))
        {
            final_result = std.fmt.allocPrint(ctx.allocator, "({s})", .{stripOuterParens(final_result)}) catch final_result;
        }

        const parent = if (context != .delete_expr) findParentOf(ctx, target_idx) else NodeIndex.none;
        if (context == .expression and ctx.nodeTag(transform_idx) == .parenthesized_expr and isCallArgument(ctx, parent, target_idx)) {
            final_result = std.fmt.allocPrint(ctx.allocator, "({s})", .{final_result}) catch final_result;
        }
        if (context == .expression and
            !isCallArgument(ctx, parent, target_idx) and
            ctx.ast.create_parenthesized_expressions and
            target_idx == transform_idx and
            shouldReplayMissingSourceParens(ctx, transform_idx) and
            stripOuterParens(final_result).len != final_result.len)
        {
            final_result = std.fmt.allocPrint(ctx.allocator, "({s})", .{final_result}) catch final_result;
        }
        const needs_call_arg_parens = context == .expression and
            isCallArgument(ctx, parent, target_idx) and
            ((stripOuterParens(final_result).len == final_result.len) or
                (target_idx != transform_idx and ctx.nodeTag(target_idx) == .parenthesized_expr)) and
            (shouldReplayMissingSourceParens(ctx, transform_idx) or
                (target_idx != transform_idx and ctx.nodeTag(target_idx) == .parenthesized_expr));
        if (needs_call_arg_parens and
            !(ctx.ast.create_parenthesized_expressions and ctx.nodeTag(target_idx) == .parenthesized_expr))
        {
            final_result = std.fmt.allocPrint(ctx.allocator, "({s})", .{final_result}) catch final_result;
        }
        if (context == .expression and
            isCallArgument(ctx, parent, target_idx) and
            stripOuterParens(final_result).len == final_result.len and
            ctx.ast.create_parenthesized_expressions and
            ((target_idx == transform_idx and shouldReplayMissingSourceParens(ctx, transform_idx)) or
                (target_idx != transform_idx and ctx.nodeTag(target_idx) == .parenthesized_expr)))
        {
            final_result = std.fmt.allocPrint(ctx.allocator, "({s})", .{final_result}) catch final_result;
        }
        if (parent != .none and context == .expression and ctx.nodeTag(parent) == .logical_expr and
            stripOuterParens(final_result).len == final_result.len)
        {
            final_result = std.fmt.allocPrint(ctx.allocator, "({s})", .{final_result}) catch final_result;
        }
        if (parent != .none and ctx.nodeTag(parent) == .unary_expr) {
            final_result = std.fmt.allocPrint(ctx.allocator, "({s})", .{final_result}) catch final_result;
        }
        const enclosing_body = findEnclosingBody(ctx, transform_idx);
        if (enclosing_body != 0) {
            const arrow_idx: NodeIndex = @enumFromInt(enclosing_body);
            if (ctx.nodeTag(arrow_idx) == .arrow_function_expr) {
                const arrow_i = @intFromEnum(arrow_idx);
                const replacement = buildArrowExpressionBodyReplacement(ctx, arrow_idx, final_result);
                if (replacement.len > 0) {
                    _ = g_body_temps.remove(arrow_i);
                    ctx.ast.replacement_source.put(ctx.allocator, arrow_i, replacement) catch {};
                    ctx.ast.replacement_needs_reindent.put(ctx.allocator, arrow_i, {}) catch {};
                    return .skip_children;
                }
            }
        }

        ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(target_idx), final_result) catch {};
        return .skip_children;
    }
    return .continue_traversal;
}

fn selectDefaultParamTransformRoot(ctx: *TransformContext, idx: NodeIndex) NodeIndex {
    if (!isInFunctionParameterDefault(ctx, idx)) return idx;
    switch (ctx.nodeTag(idx)) {
        .member_expr, .computed_member_expr => {
            const lhs = ctx.nodeData(idx).binary.lhs;
            if (ctx.nodeTag(lhs) == .parenthesized_expr) {
                const inner = ctx.nodeData(lhs).unary;
                if (containsOptionalChain(ctx, inner)) return inner;
            }
        },
        else => {},
    }
    return idx;
}

fn getBodyTempCount(body_idx: u32) usize {
    if (g_body_temps.get(body_idx)) |temps| return temps.items.len;
    return 0;
}

fn maybeWrapParameterDefaultIife(
    ctx: *TransformContext,
    body_idx: u32,
    temp_count_before: usize,
    expr: []const u8,
) []const u8 {
    const temps = g_body_temps.getPtr(body_idx) orelse return expr;
    if (temps.items.len <= temp_count_before) return expr;

    const new_temps = temps.items[temp_count_before..];
    temps.items.len = temp_count_before;

    var params: []const u8 = "";
    if (new_temps.len == 1) {
        params = new_temps[0];
    } else {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(ctx.allocator, "(") catch return expr;
        for (new_temps, 0..) |name, i| {
            if (i > 0) buf.appendSlice(ctx.allocator, ", ") catch return expr;
            buf.appendSlice(ctx.allocator, name) catch return expr;
        }
        buf.appendSlice(ctx.allocator, ")") catch return expr;
        params = buf.items;
    }

    return std.fmt.allocPrint(ctx.allocator, "({s} => {s})()", .{ params, expr }) catch expr;
}

fn isInFunctionParameterDefault(ctx: *TransformContext, idx: NodeIndex) bool {
    var current = idx;
    var saw_default = false;

    while (true) {
        const parent = findParentOf(ctx, current);
        if (parent == .none) return false;

        switch (ctx.nodeTag(parent)) {
            .assignment_pattern => {
                if (ctx.nodeData(parent).binary.rhs != current) return false;
                saw_default = true;
                current = parent;
            },
            .property,
            .computed_property,
            .shorthand_property,
            .object_pattern,
            .array_pattern,
            .rest_element,
            .unary_expr,
            .binary_expr,
            .logical_expr,
            .conditional_expr,
            .member_expr,
            .optional_chain_expr,
            .computed_member_expr,
            .optional_computed_member_expr,
            .call_expr,
            .optional_call_expr,
            .sequence_expr,
            .parenthesized_expr,
            .ts_non_null_expression,
            .ts_as_expression,
            .ts_satisfies_expression,
            => current = parent,
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .arrow_function_expr,
            .class_method,
            .class_private_method,
            .computed_method,
            .method_definition,
            => return saw_default,
            else => return false,
        }
    }
}

fn isBeforeEnclosingBody(ctx: *TransformContext, idx: NodeIndex, body_idx: u32) bool {
    if (body_idx == 0) return false;
    const body: NodeIndex = @enumFromInt(body_idx);
    const body_tag = ctx.nodeTag(body);
    const body_start = switch (body_tag) {
        .block_statement => getNodeStart(ctx, body),
        .arrow_function_expr => blk: {
            const data = ctx.nodeData(body);
            const eidx = @intFromEnum(data.extra);
            if (eidx + 2 >= ctx.ast.extra_data.items.len) return false;
            const arrow_body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx + 2]);
            break :blk getNodeStart(ctx, arrow_body);
        },
        else => return false,
    };
    return getNodeEnd(ctx, idx) <= body_start;
}

fn isCallArgument(ctx: *TransformContext, parent: NodeIndex, child: NodeIndex) bool {
    if (parent == .none) return false;
    switch (ctx.nodeTag(parent)) {
        .call_expr, .optional_call_expr, .new_expr => {
            const data = ctx.nodeData(parent);
            const eidx = @intFromEnum(data.extra);
            if (eidx >= ctx.ast.extra_data.items.len) return false;
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
            return callee != child;
        },
        else => return false,
    }
}

fn hasExplicitParenthesizedCallArgumentWrapper(ctx: *TransformContext, idx: NodeIndex) bool {
    if (!ctx.ast.create_parenthesized_expressions) return false;
    const parent = findParentOf(ctx, idx);
    if (parent == .none or ctx.nodeTag(parent) != .parenthesized_expr or ctx.nodeData(parent).unary != idx) {
        return false;
    }
    const grandparent = findParentOf(ctx, parent);
    return isCallArgument(ctx, grandparent, parent);
}

fn findTransparentWrapperParent(ctx: *TransformContext, child: NodeIndex) NodeIndex {
    const parent = findParentOf(ctx, child);
    if (parent != .none) {
        const ptag = ctx.nodeTag(parent);
        switch (ptag) {
            .parenthesized_expr => {
                if (ctx.nodeData(parent).unary == child and shouldReplayParenthesizedWrapper(ctx, parent)) return parent;
            },
            .sequence_expr => {
                if (ctx.ast.create_parenthesized_expressions and sequenceExprContainsChild(ctx, parent, child)) return parent;
            },
            .ts_as_expression, .ts_satisfies_expression => {
                if (ctx.nodeData(parent).binary.lhs == child) return parent;
            },
            else => {},
        }
    }

    return findNearestTransparentWrapperParent(ctx, child);
}

fn findNearestTransparentWrapperParent(ctx: *TransformContext, child: NodeIndex) NodeIndex {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    var best: NodeIndex = .none;
    var best_span: u32 = std.math.maxInt(u32);

    for (tags, 0..) |tag, ni| {
        const node: NodeIndex = @enumFromInt(ni);
        const data = datas[ni];
        var matches = false;

        switch (tag) {
            .parenthesized_expr => {
                matches = data.unary == child and shouldReplayParenthesizedWrapper(ctx, node);
            },
            .ts_as_expression, .ts_satisfies_expression => {
                matches = data.binary.lhs == child;
            },
            .sequence_expr => {
                matches = ctx.ast.create_parenthesized_expressions and sequenceExprContainsChild(ctx, node, child);
            },
            else => {},
        }

        if (!matches) continue;

        const start = getRawNodeStart(ctx, node);
        const end = getRawNodeEnd(ctx, node);
        if (end <= start) continue;
        const span = end - start;
        if (span < best_span or (span == best_span and ni < @intFromEnum(best))) {
            best = node;
            best_span = span;
        }
    }

    return best;
}

fn shouldReplayMissingSourceParens(ctx: *TransformContext, idx: NodeIndex) bool {
    if (!ctx.ast.create_parenthesized_expressions) return false;

    const parent = findParentOf(ctx, idx);
    if (parent != .none and ctx.nodeTag(parent) == .parenthesized_expr and ctx.nodeData(parent).unary == idx) {
        return false;
    }

    const start = getNodeStart(ctx, idx);
    const end = getNodeEnd(ctx, idx);
    if (start < end and end <= ctx.ast.source.len) {
        if (ctx.ast.source[start] == '(' and ctx.ast.source[end - 1] == ')') return true;
    }
    if (start > 0 and end < ctx.ast.source.len and ctx.ast.source[start - 1] == '(' and ctx.ast.source[end] == ')') {
        return true;
    }

    const raw_start = getRawNodeStart(ctx, idx);
    const raw_end = getRawNodeEnd(ctx, idx);
    if (raw_start < raw_end and raw_end <= ctx.ast.source.len) {
        if (ctx.ast.source[raw_start] == '(' and ctx.ast.source[raw_end - 1] == ')') return true;
    }
    if (raw_start == 0 or raw_end >= ctx.ast.source.len) return false;
    return ctx.ast.source[raw_start - 1] == '(' and ctx.ast.source[raw_end] == ')';
}

fn applyParentTransparentWrapper(ctx: *TransformContext, current: []const u8, parent: NodeIndex, child: NodeIndex) []const u8 {
    const ptag = ctx.nodeTag(parent);
    const wrapper_kind: TransparentWrapper.Kind = switch (ptag) {
        .parenthesized_expr => .parenthesized,
        .sequence_expr => .sequence,
        .ts_as_expression => .ts_as,
        .ts_satisfies_expression => .ts_satisfies,
        else => return current,
    };

    return applyTransparentWrapper(ctx, current, .{
        .kind = wrapper_kind,
        .node = parent,
        .child = child,
        .apply_after_link_count = 0,
    });
}

fn isImmediateIifeCallSource(src: []const u8) bool {
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    if (trimmed.len < 4) return false;
    if (trimmed[0] != '(' or trimmed[trimmed.len - 1] != ')') return false;
    return trimmed.len >= 3 and trimmed[trimmed.len - 2] == '(';
}

fn sequenceExprContainsChild(ctx: *TransformContext, sequence: NodeIndex, child: NodeIndex) bool {
    const data = ctx.nodeData(sequence);
    const eidx = @intFromEnum(data.extra);
    if (eidx + 1 >= ctx.ast.extra_data.items.len) return false;
    const range_start = ctx.ast.extra_data.items[eidx];
    const range_end = ctx.ast.extra_data.items[eidx + 1];
    if (range_end <= range_start) return false;
    for (ctx.ast.extra_data.items[range_start..range_end]) |item_raw| {
        const item: NodeIndex = @enumFromInt(item_raw);
        if (item == child) return true;
    }
    return false;
}

fn shouldReplayParenthesizedWrapper(ctx: *TransformContext, parenthesized: NodeIndex) bool {
    if (ctx.ast.create_parenthesized_expressions) return true;

    const gp = findParentOf(ctx, parenthesized);
    if (gp == .none) return false;

    switch (ctx.nodeTag(gp)) {
        .call_expr, .optional_call_expr, .new_expr => {
            const data = ctx.nodeData(gp);
            const eidx = @intFromEnum(data.extra);
            if (eidx < ctx.ast.extra_data.items.len) {
                const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
                return callee == parenthesized;
            }
        },
        .member_expr, .computed_member_expr, .optional_chain_expr, .optional_computed_member_expr => {
            return ctx.nodeData(gp).binary.lhs == parenthesized;
        },
        else => {},
    }

    return false;
}

fn normalizeGeneratedSource(ctx: *TransformContext, src: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '(' and i + 3 < src.len and src[i + 1] == '{' and src[i + 2] == '}' and src[i + 3] == ')') {
            buf.appendSlice(ctx.allocator, "{}") catch return src;
            i += 3;
            continue;
        }
        buf.append(ctx.allocator, src[i]) catch return src;
    }
    const normalized = if (buf.items.len > 0) buf.items else src;
    return collapseRedundantWrappedChainBase(ctx, normalized);
}

fn collapseRedundantWrappedChainBase(ctx: *TransformContext, src: []const u8) []const u8 {
    if (src.len < 4 or src[0] != '(' or src[1] != '(') return src;

    var depth: i32 = 0;
    var in_quote: ?u8 = null;
    var escaped = false;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                in_quote = null;
            }
            continue;
        }

        switch (c) {
            '\'', '"', '`' => in_quote = c,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0 and i + 1 < src.len) {
                    const next = src[i + 1];
                    if (next == '.' or next == '[' or next == '(') {
                        const inner = src[1..i];
                        const stripped_inner = stripAllOuterParens(inner);
                        if (splitTopLevelTsAs(stripped_inner) != null) break;
                        if (needsChainBaseParens(stripped_inner)) break;
                        return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ src[1..i], src[i + 1 ..] }) catch src;
                    }
                    break;
                }
            },
            else => {},
        }
    }

    return src;
}

fn buildArrowExpressionBodyReplacement(ctx: *TransformContext, arrow_idx: NodeIndex, body_result: []const u8) []const u8 {
    const ni = @intFromEnum(arrow_idx);
    const data = ctx.nodeData(arrow_idx);
    const eidx = @intFromEnum(data.extra);
    if (eidx + 2 >= ctx.ast.extra_data.items.len) return "";

    const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx + 2]);
    if (body == .none or ctx.nodeTag(body) == .block_statement) return "";

    const arrow_start = getNodeStart(ctx, arrow_idx);
    const body_start = getNodeStart(ctx, body);
    if (arrow_start >= body_start or body_start > ctx.ast.source.len) return "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, ctx.ast.source[arrow_start..body_start]) catch return "";
    buf.appendSlice(ctx.allocator, "{\n") catch return "";

    if (g_body_temps.get(ni)) |temps| {
        if (temps.items.len > 0) {
            buf.appendSlice(ctx.allocator, "  var ") catch return "";
            for (temps.items, 0..) |name, i| {
                if (i > 0) buf.appendSlice(ctx.allocator, ", ") catch {};
                buf.appendSlice(ctx.allocator, name) catch {};
            }
            buf.appendSlice(ctx.allocator, ";\n") catch return "";
        }
    }

    buf.appendSlice(ctx.allocator, "  return ") catch return "";
    buf.appendSlice(ctx.allocator, body_result) catch return "";
    buf.appendSlice(ctx.allocator, ";\n}") catch return "";
    return buf.items;
}

/// Check if the parent of `idx` is also a chain-extending node
/// (member_expr, computed_member_expr, call_expr, optional_*) whose
/// LHS/callee chain leads through `idx`.
fn isInsideChainParent(ctx: *TransformContext, idx: NodeIndex) bool {
    var child = idx;
    while (true) {
        const parent = findParentOf(ctx, child);
        if (parent == .none) break;
        switch (ctx.nodeTag(parent)) {
            .parenthesized_expr, .ts_non_null_expression => {
                if (ctx.nodeData(parent).unary != child) break;
                child = parent;
            },
            .ts_as_expression, .ts_satisfies_expression => {
                if (ctx.nodeData(parent).binary.lhs != child) break;
                child = parent;
            },
            .member_expr, .computed_member_expr, .optional_chain_expr, .optional_computed_member_expr => {
                if (ctx.nodeData(parent).binary.lhs == child) {
                    // idx is the LHS/object of a member access — parent will handle
                    return true;
                }
                break;
            },
            .call_expr, .optional_call_expr => {
                const extra_idx = @intFromEnum(ctx.nodeData(parent).extra);
                if (extra_idx < ctx.ast.extra_data.items.len and ctx.ast.extra_data.items[extra_idx] == @intFromEnum(child)) {
                    // idx is the callee of a call — parent will handle
                    return true;
                }
                break;
            },
            else => break,
        }
    }
    return false;
}

// ── Flat chain model ───────────────────────────────────────────────
// We flatten the nested AST into a linear list of chain links.

const ChainLink = struct {
    kind: Kind,
    is_optional: bool,
    node: NodeIndex,

    const Kind = enum {
        member, // .prop
        computed, // [expr]
        call, // (args)
    };
};

const TransparentWrapper = struct {
    kind: Kind,
    node: NodeIndex,
    child: NodeIndex,
    apply_after_link_count: usize,

    const Kind = enum {
        sequence,
        parenthesized,
        ts_non_null,
        ts_as,
        ts_satisfies,
    };
};

/// Check if a node is directly optional (has `?.` token vs chain-propagated `.` token).
fn isDirectlyOptional(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .optional_chain_expr, .optional_computed_member_expr => {
            const mtok = ctx.mainToken(node);
            const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(mtok)];
            return tok_tag == .optional_chain;
        },
        .optional_call_expr => {
            // Optional call always has the `?.` token OR is chain-propagated
            const mtok = ctx.mainToken(node);
            const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(mtok)];
            return tok_tag == .optional_chain;
        },
        else => return false,
    }
}

/// Flatten an optional chain AST into a list of links (innermost first).
/// Returns the "base" node (the expression before the first link).
fn flattenChain(
    ctx: *TransformContext,
    node: NodeIndex,
    links: *std.ArrayListUnmanaged(ChainLink),
    wrappers: *std.ArrayListUnmanaged(TransparentWrapper),
) NodeIndex {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .optional_chain_expr => {
            const d = ctx.nodeData(node);
            const base = flattenChain(ctx, d.binary.lhs, links, wrappers);
            const is_opt = isDirectlyOptional(ctx, node);
            links.append(ctx.allocator, .{ .kind = .member, .is_optional = is_opt, .node = node }) catch {};
            return base;
        },
        .member_expr => {
            const d = ctx.nodeData(node);
            if (containsOptionalChain(ctx, d.binary.lhs)) {
                const base = flattenChain(ctx, d.binary.lhs, links, wrappers);
                links.append(ctx.allocator, .{ .kind = .member, .is_optional = false, .node = node }) catch {};
                return base;
            }
            return node; // base
        },
        .optional_computed_member_expr => {
            const d = ctx.nodeData(node);
            const base = flattenChain(ctx, d.binary.lhs, links, wrappers);
            const is_opt = isDirectlyOptional(ctx, node);
            links.append(ctx.allocator, .{ .kind = .computed, .is_optional = is_opt, .node = node }) catch {};
            return base;
        },
        .computed_member_expr => {
            const d = ctx.nodeData(node);
            if (containsOptionalChain(ctx, d.binary.lhs)) {
                const base = flattenChain(ctx, d.binary.lhs, links, wrappers);
                links.append(ctx.allocator, .{ .kind = .computed, .is_optional = false, .node = node }) catch {};
                return base;
            }
            return node; // base
        },
        .optional_call_expr => {
            const d = ctx.nodeData(node);
            const eidx = @intFromEnum(d.extra);
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
            const base = flattenChain(ctx, callee, links, wrappers);
            const is_opt = isDirectlyOptional(ctx, node);
            links.append(ctx.allocator, .{ .kind = .call, .is_optional = is_opt, .node = node }) catch {};
            return base;
        },
        .call_expr => {
            const d = ctx.nodeData(node);
            const eidx = @intFromEnum(d.extra);
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
            if (containsOptionalChain(ctx, callee)) {
                const base = flattenChain(ctx, callee, links, wrappers);
                links.append(ctx.allocator, .{ .kind = .call, .is_optional = false, .node = node }) catch {};
                return base;
            }
            return node; // base
        },
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            const base = flattenChain(ctx, d.unary, links, wrappers);
            wrappers.append(ctx.allocator, .{
                .kind = .parenthesized,
                .node = node,
                .child = d.unary,
                .apply_after_link_count = links.items.len,
            }) catch {};
            return base;
        },
        .ts_non_null_expression => {
            const d = ctx.nodeData(node);
            const base = flattenChain(ctx, d.unary, links, wrappers);
            wrappers.append(ctx.allocator, .{
                .kind = .ts_non_null,
                .node = node,
                .child = d.unary,
                .apply_after_link_count = links.items.len,
            }) catch {};
            return base;
        },
        .ts_as_expression, .ts_satisfies_expression => {
            const d = ctx.nodeData(node);
            const base = flattenChain(ctx, d.binary.lhs, links, wrappers);
            wrappers.append(ctx.allocator, .{
                .kind = if (tag == .ts_as_expression) .ts_as else .ts_satisfies,
                .node = node,
                .child = d.binary.lhs,
                .apply_after_link_count = links.items.len,
            }) catch {};
            return base;
        },
        .sequence_expr => {
            const d = ctx.nodeData(node);
            const eidx = @intFromEnum(d.extra);
            if (eidx + 1 >= ctx.ast.extra_data.items.len) return node;
            const range_start = ctx.ast.extra_data.items[eidx];
            const range_end = ctx.ast.extra_data.items[eidx + 1];
            if (range_end <= range_start) return node;
            const last_item: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_end - 1]);
            const base = flattenChain(ctx, last_item, links, wrappers);
            wrappers.append(ctx.allocator, .{
                .kind = .sequence,
                .node = node,
                .child = last_item,
                .apply_after_link_count = links.items.len,
            }) catch {};
            return base;
        },
        else => return node, // base
    }
}

// ── Context Detection ──────────────────────────────────────────────

const ChainContext = enum {
    expression, // ternary: === null || === void 0 ? void 0 :
    statement, // short-circuit: === null || === void 0 ||
    boolean_cast, // AND form: !== null && !== void 0 &&
    delete_expr, // statement form but wrap result in delete
};

fn determineContext(ctx: *TransformContext, idx: NodeIndex) ChainContext {
    const parent = findParentOf(ctx, idx);
    if (parent == .none) {
        return .expression;
    }

    const parent_tag = ctx.nodeTag(parent);
    if ((parent_tag == .ts_as_expression or parent_tag == .ts_satisfies_expression) and ctx.nodeData(parent).binary.lhs == idx) {
        const parent_ctx = determineContext(ctx, parent);
        return if (parent_ctx == .statement) .expression else parent_ctx;
    }
    if (parent_tag == .parenthesized_expr and ctx.nodeData(parent).unary == idx) {
        const grandparent = findParentOf(ctx, parent);
        if (grandparent != .none) {
            switch (ctx.nodeTag(grandparent)) {
                .member_expr, .computed_member_expr, .optional_chain_expr, .optional_computed_member_expr => {
                    if (ctx.nodeData(grandparent).binary.lhs != parent) {
                        return determineContext(ctx, parent);
                    }
                },
                .call_expr, .optional_call_expr => {
                    const eidx = @intFromEnum(ctx.nodeData(grandparent).extra);
                    if (eidx < ctx.ast.extra_data.items.len and @as(NodeIndex, @enumFromInt(ctx.ast.extra_data.items[eidx])) != parent) {
                        return determineContext(ctx, parent);
                    }
                },
                else => return determineContext(ctx, parent),
            }
        } else {
            return determineContext(ctx, parent);
        }
    }
    switch (parent_tag) {
        .unary_expr => {
            const mtok = ctx.mainToken(parent);
            const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(mtok)];
            if (tok_tag == .kw_delete) return .delete_expr;
            if (tok_tag == .bang) return .boolean_cast;
            // +, -, ~, typeof etc. → expression
            return .expression;
        },
        .expression_statement => return .statement,
        .if_statement => {
            const pdata = ctx.nodeData(parent);
            const eidx = @intFromEnum(pdata.extra);
            if (eidx < ctx.ast.extra_data.items.len) {
                const condition: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
                if (condition == idx) return .boolean_cast;
            }
            return .expression;
        },
        .while_statement => {
            const pdata = ctx.nodeData(parent);
            if (pdata.binary.lhs == idx) return .boolean_cast;
            return .expression;
        },
        .do_while_statement => {
            const pdata = ctx.nodeData(parent);
            if (pdata.binary.rhs == idx) return .boolean_cast;
            return .expression;
        },
        .for_statement => {
            const pdata = ctx.nodeData(parent);
            const eidx = @intFromEnum(pdata.extra);
            if (eidx + 1 < ctx.ast.extra_data.items.len) {
                const cond: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx + 1]);
                if (cond == idx) return .boolean_cast;
            }
            return .expression;
        },
        .conditional_expr => {
            const pdata = ctx.nodeData(parent);
            if (pdata.binary.lhs == idx) return .boolean_cast;
            return .expression;
        },
        .logical_expr => {
            // If in && or || and grandparent puts it in boolean context → boolean_cast
            const mtok = ctx.mainToken(parent);
            const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(mtok)];
            if (tok_tag == .ampersand_ampersand or tok_tag == .pipe_pipe) {
                // Check grandparent context
                const gp_ctx = determineContext(ctx, parent);
                if (gp_ctx == .boolean_cast or gp_ctx == .statement) return .boolean_cast;
            }
            return .expression;
        },
        .sequence_expr => {
            // Non-last items in sequence → boolean_cast; last → depends on parent
            const pdata = ctx.nodeData(parent);
            const eidx = @intFromEnum(pdata.extra);
            if (eidx + 1 < ctx.ast.extra_data.items.len) {
                const range_start = ctx.ast.extra_data.items[eidx];
                const range_end = ctx.ast.extra_data.items[eidx + 1];
                if (range_end > range_start) {
                    const last_item: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_end - 1]);
                    if (last_item != idx) {
                        return .boolean_cast;
                    }
                }
            }
            // Last item — inherit parent context
            return determineContext(ctx, parent);
        },
        else => return .expression,
    }
}

// ── Main transformation ────────────────────────────────────────────

fn transformChain(ctx: *TransformContext, root: NodeIndex) []const u8 {
    var links: std.ArrayListUnmanaged(ChainLink) = .empty;
    var wrappers: std.ArrayListUnmanaged(TransparentWrapper) = .empty;
    const base_node = flattenChain(ctx, root, &links, &wrappers);
    if (links.items.len == 0) return "";

    var has_optional = false;
    for (links.items) |link| {
        if (link.is_optional) {
            has_optional = true;
            break;
        }
    }
    if (!has_optional) return "";

    const context = determineContext(ctx, root);
    const body_idx = findEnclosingBody(ctx, root);

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    const base_src = getNodeSource(ctx, base_node);
    if (base_src.len == 0) return "";
    const base_is_eval = std.mem.eql(u8, stripAllOuterParens(base_src), "eval");

    var base_needs_temp = needsTempForBase(ctx, base_node);

    var total_opts: usize = 0;
    for (links.items) |link| {
        if (link.is_optional) total_opts += 1;
    }

    // In loose mode (no_document_all), when the chain consists ONLY of an optional
    // call (no member/computed links), skip the temp for any base expression.
    // e.g., foo?.(args) → foo == null || foo(args)  [no temp]
    //        foo.bar?.(args) → foo.bar == null || foo.bar(args)  [no temp, repeat member access]
    // But foo?.bar() still needs temp because there's a member link after the optional boundary.
    if ((g_config.loose or g_config.pure_getters) and base_needs_temp) {
        // Check if chain is just optional-call(s) with no member/computed links
        var has_non_call_link = false;
        for (links.items) |link| {
            if (link.kind != .call) {
                has_non_call_link = true;
                break;
            }
        }
        const can_repeat_call_only_base = switch (ctx.nodeTag(base_node)) {
            .identifier, .member_expr, .computed_member_expr, .optional_chain_expr, .optional_computed_member_expr, .this_expr, .super_expr => true,
            else => false,
        };
        if (!has_non_call_link and can_repeat_call_only_base) {
            base_needs_temp = false;
        }
    }

    if (g_config.pure_getters and base_needs_temp) {
        switch (ctx.nodeTag(base_node)) {
            .identifier, .member_expr, .computed_member_expr, .optional_chain_expr, .optional_computed_member_expr => {
                const keep_base_temp = links.items.len > 1 and
                    links.items.len > 0 and
                    (links.items[0].kind == .member or links.items[0].kind == .computed) and
                    links.items[1].kind == .call;
                if (!keep_base_temp) base_needs_temp = false;
            },
            else => {},
        }
    }

    if (base_needs_temp and base_is_eval and links.items.len > 0 and links.items[0].kind == .call and links.items[0].is_optional) {
        base_needs_temp = false;
    }

    // `ref` tracks the current expression string.
    // `temp` tracks the allocated temp var, if any.
    var ref: []const u8 = base_src;
    var temp: ?[]const u8 = null;
    var temp_from_call_result = false;
    var pending_sequence_temp = false;
    var last_non_optional_link_node: ?NodeIndex = null;
    var strip_null_check_parens = false;

    if (base_needs_temp) {
        temp = allocTempForNode(ctx, base_node, body_idx);
        if (temp == null) return "";
        temp_from_call_result = false;
    }

    var opt_idx: usize = 0; // Count of optional boundaries processed so far

    var i: usize = 0;
    var wrapper_i: usize = 0;
    while (i < links.items.len) {
        ref = applyPendingWrappers(ctx, ref, &wrappers, &wrapper_i, i, &pending_sequence_temp, &strip_null_check_parens);

        const link = links.items[i];

        if (link.is_optional) {
            const is_last_opt = opt_idx + 1 == total_opts;
            var check_ref = ref;
            if (hasParenthesizedWrapperAtLinkCount(&wrappers, i)) {
                check_ref = stripOuterParens(check_ref);
                ref = check_ref;
            }
            if (strip_null_check_parens) {
                check_ref = stripOuterParens(check_ref);
                strip_null_check_parens = false;
            }

            // Determine the null-check context for this boundary.
            // Statement contexts stay statement-style (`||`) throughout so
            // call/member chains keep Babel's output shape.
            // Expression contexts use statement-style checks until the final
            // optional boundary, then switch to ternary form.
            const wrapper_requires_value = hasValueWrapperAtLinkCount(&wrappers, i + 1);
            const sequence_wrapper_requires_value = hasSequenceWrapperAtLinkCount(&wrappers, i + 1);
            const callee_wrapper_requires_value = link.kind == .call and hasCallContextWrapperAtLinkCount(&wrappers, i);
            const trailing_parenthesized_wrapper = is_last_opt and hasParenthesizedWrapperAtLinkCount(&wrappers, i + 1);
            const materialize_optional_value = (sequence_wrapper_requires_value or trailing_parenthesized_wrapper) and
                i + 1 < links.items.len;
            const wrapped_followup_call = materialize_optional_value and
                i + 1 < links.items.len and
                links.items[i + 1].kind == .call and
                !links.items[i + 1].is_optional;
            const base_ctx_src = stripAllOuterParens(base_src);
            const loose_last_call_requires_value = g_config.loose and
                total_opts > 1 and
                is_last_opt and
                link.kind == .call and
                isSimpleCallContextSource(base_ctx_src) and
                shouldMemoizeSimpleContext(ctx, link.node, base_ctx_src);
            const check_ctx: ChainContext = switch (context) {
                .expression => if (is_last_opt) ChainContext.expression else ChainContext.statement,
                .statement => if (wrapper_requires_value or
                    loose_last_call_requires_value)
                    ChainContext.expression
                else if (willNeedWrappedFollowupCall(&wrappers, links.items, i))
                    ChainContext.expression
                else if (willNeedFollowupCallValue(links.items, i))
                    ChainContext.expression
                else if (callee_wrapper_requires_value)
                    ChainContext.expression
                else if (trailing_parenthesized_wrapper)
                    ChainContext.expression
                else
                    ChainContext.statement,
                else => context,
            };
            const prefers_value_last_call = context == .statement and
                !g_config.pure_getters and
                is_last_opt and
                link.kind == .call and
                opt_idx > 0 and
                i + 1 < links.items.len and
                !links.items[i + 1].is_optional and
                getCallMemberInfo(ctx, check_ref, temp) == null;
            const stripped_check_ref = stripOuterParens(check_ref);
            const prefers_value_last_member = context == .statement and
                is_last_opt and
                link.kind != .call and
                temp != null and
                std.mem.startsWith(u8, stripped_check_ref, temp.?) and
                (if (g_config.pure_getters)
                    true
                else
                    opt_idx > 1 and
                        (temp_from_call_result or
                            std.mem.indexOfScalar(u8, stripped_check_ref, '=') != null or
                            isBareTopLevelCallSource(stripped_check_ref)));
            const effective_check_ctx: ChainContext = if (prefers_value_last_call or prefers_value_last_member) .expression else check_ctx;

            if (link.kind == .call) {
                emitOptionalCallV2(ctx, &buf, link, &ref, &temp, &temp_from_call_result, effective_check_ctx, body_idx);
                if (!is_last_opt and temp == null) {
                    const new_temp = blk: {
                        if (pending_sequence_temp or hasSequenceWrapperSource(ref)) {
                            const seq_temp = sequenceWrapperTemp(ctx, ref, temp, last_non_optional_link_node, body_idx);
                            if (seq_temp.len > 0) break :blk seq_temp;
                        }
                        break :blk allocChainTemp(ctx, base_node, deriveContinuationPrefix(ctx, base_node, links.items, i), body_idx);
                    };
                    if (new_temp.len > 0) {
                        temp = new_temp;
                        temp_from_call_result = true;
                    }
                    pending_sequence_temp = false;
                }
            } else {
                const buf_prefix_len = buf.items.len;
                // At this boundary, the current `ref` is the expression to null-check.
                // If ref is a complex expression (not a simple identifier), we need a temp.

                if (temp) |t| {
                    var active_temp = t;
                    if (pending_sequence_temp or hasSequenceWrapperSource(ref)) {
                        const new_temp = sequenceWrapperTemp(ctx, ref, temp, last_non_optional_link_node, body_idx);
                        if (new_temp.len > 0) {
                            active_temp = new_temp;
                            temp = new_temp;
                            temp_from_call_result = false;
                        }
                        pending_sequence_temp = false;
                    }

                    if (opt_idx == 0) {
                        // First boundary with pre-allocated temp: (temp = base) null_check
                        emitTempNullCheck(&buf, ctx, active_temp, check_ref, effective_check_ctx);
                        // After check, ref becomes temp.prop
                        ref = applyLink(ctx, active_temp, link);
                        if (wrapped_followup_call) {
                            ref = bindWrappedCallContextSource(ctx, ref, body_idx);
                        }
                        if (materialize_optional_value) {
                            ref = materializeBufferedOptionalValue(ctx, &buf, buf_prefix_len, ref);
                        }
                    } else {
                        // Subsequent boundary: reassign temp: (temp = temp.chain) null_check
                        emitTempNullCheck(&buf, ctx, active_temp, check_ref, effective_check_ctx);
                        ref = applyLink(ctx, active_temp, link);
                        if (wrapped_followup_call) {
                            ref = bindWrappedCallContextSource(ctx, ref, body_idx);
                        }
                        if (materialize_optional_value) {
                            ref = materializeBufferedOptionalValue(ctx, &buf, buf_prefix_len, ref);
                        }
                    }
                } else {
                    // No temp yet — base is simple (param/local).
                    // After applying this link, the result will be a member expr.
                    // For the FIRST optional boundary on a simple base: no temp assignment needed
                    // because repeating `base` is fine (it's a declared variable).
                    emitDirectNullCheck(&buf, ctx, check_ref, effective_check_ctx);
                    ref = applyLink(ctx, ref, link);
                    if (wrapped_followup_call) {
                        ref = bindWrappedCallContextSource(ctx, ref, body_idx);
                    }
                    if (materialize_optional_value) {
                        ref = materializeBufferedOptionalValue(ctx, &buf, buf_prefix_len, ref);
                    }

                    // Now we need a temp for subsequent boundaries, because `ref` is now `base.prop`
                    // which is a member expression.
                    // Check if there are more optional boundaries coming
                    if (!is_last_opt and !canSkipContinuationTempAfterOptionalMember(ref, links.items, i)) {
                        // Allocate a temp for the chain continuation
                        const new_temp = blk: {
                            if (pending_sequence_temp or hasSequenceWrapperSource(ref)) {
                                const seq_temp = sequenceWrapperTemp(ctx, ref, temp, last_non_optional_link_node, body_idx);
                                if (seq_temp.len > 0) break :blk seq_temp;
                            }
                            break :blk allocChainTemp(ctx, base_node, deriveContinuationPrefix(ctx, base_node, links.items, i), body_idx);
                        };
                        if (new_temp.len > 0) {
                            temp = new_temp;
                            temp_from_call_result = false;
                        }
                        pending_sequence_temp = false;
                    }
                }
            }

            opt_idx += 1;
        } else {
            if (link.kind == .call and hasParenthesizedWrapperAtLinkCount(&wrappers, i)) {
                // Parenthesized call sites like `(obj?.m)()` need the optional
                // value materialized first, then called as a whole. If we keep
                // the replayed wrapper on `ref` here, we end up wrapping the
                // inner callee instead of the full ternary and accumulate
                // redundant parens such as `(((expr))())`.
                ref = stripAllOuterParens(ref);
                ref = bindWrappedCallContextSource(ctx, ref, body_idx);
                if (buf.items.len > 0) {
                    ref = materializeBufferedOptionalValue(ctx, &buf, 0, ref);
                }
                ref = hoistTypeAssertionOverOptionalTernary(ctx, ref);
            }
            if (link.kind == .call) {
                const spread_args_src = getSingleSpreadCallArgsSource(ctx, link.node);
                if (spread_args_src.len > 0) {
                    const call_base_ref = ref;
                    ref = applyNonOptionalCallWithSpread(ctx, ref, temp, body_idx, spread_args_src);
                    if (hasFutureNonOptionalCall(links.items, i)) {
                        const call_temp = allocCallResultTempForRef(ctx, call_base_ref, temp, body_idx);
                        if (call_temp.len > 0) {
                            ref = std.fmt.allocPrint(ctx.allocator, "({s} = {s})", .{ call_temp, ref }) catch ref;
                            temp = call_temp;
                        }
                    }
                    last_non_optional_link_node = link.node;
                    i += 1;
                    continue;
                }
            }
            // Non-optional link — extend current ref
            // ref already contains the accumulated chain (e.g., "_a.b"),
            // so we extend from ref to get "_a.b.c"
            const call_base_ref = ref;
            const non_optional_base = if (g_config.pure_getters and temp_from_call_result and temp != null and link.kind != .call)
                temp.?
            else
                ref;
            ref = applyLink(ctx, non_optional_base, link);
            if (link.kind == .call and hasFutureOptionalBoundary(links.items, i)) {
                const call_temp = blk: {
                    const callee_node = getCallCalleeNode(ctx, link.node);
                    if (callee_node != .none) break :blk allocTempForNode(ctx, callee_node, body_idx);
                    break :blk allocCallResultTempForRef(ctx, call_base_ref, temp, body_idx);
                };
                if (call_temp.len > 0) {
                    temp = call_temp;
                    temp_from_call_result = true;
                }
            }
            last_non_optional_link_node = link.node;
        }

        i += 1;
    }

    ref = applyPendingWrappers(ctx, ref, &wrappers, &wrapper_i, links.items.len, &pending_sequence_temp, &strip_null_check_parens);

    // Emit final value
    switch (context) {
        .delete_expr => {
            buf.appendSlice(ctx.allocator, "delete ") catch return "";
            buf.appendSlice(ctx.allocator, ref) catch return "";
        },
        else => {
            buf.appendSlice(ctx.allocator, ref) catch return "";
        },
    }

    return buf.items;
}

fn applyPendingWrappers(
    ctx: *TransformContext,
    ref: []const u8,
    wrappers: *const std.ArrayListUnmanaged(TransparentWrapper),
    wrapper_i: *usize,
    link_count: usize,
    pending_sequence_temp: *bool,
    strip_null_check_parens: *bool,
) []const u8 {
    var result = ref;
    while (wrapper_i.* < wrappers.items.len) {
        const wrapper = wrappers.items[wrapper_i.*];
        if (wrapper.apply_after_link_count != link_count) break;
        result = applyTransparentWrapper(ctx, result, wrapper);
        switch (wrapper.kind) {
            .sequence => pending_sequence_temp.* = true,
            .ts_as, .ts_satisfies => strip_null_check_parens.* = true,
            else => {},
        }
        wrapper_i.* += 1;
    }
    return result;
}

fn materializeBufferedOptionalValue(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    prefix_len: usize,
    value_ref: []const u8,
) []const u8 {
    const suffix = buf.items[prefix_len..];
    const expr = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ suffix, value_ref }) catch return value_ref;
    buf.items.len = prefix_len;
    return expr;
}

fn hasWrapperAtLinkCount(wrappers: *const std.ArrayListUnmanaged(TransparentWrapper), link_count: usize) bool {
    for (wrappers.items) |wrapper| {
        if (wrapper.apply_after_link_count == link_count) return true;
    }
    return false;
}

fn hasValueWrapperAtLinkCount(wrappers: *const std.ArrayListUnmanaged(TransparentWrapper), link_count: usize) bool {
    for (wrappers.items) |wrapper| {
        if (wrapper.apply_after_link_count != link_count) continue;
        switch (wrapper.kind) {
            .sequence, .ts_as, .ts_satisfies => return true,
            else => {},
        }
    }
    return false;
}

fn hasSequenceWrapperAtLinkCount(wrappers: *const std.ArrayListUnmanaged(TransparentWrapper), link_count: usize) bool {
    for (wrappers.items) |wrapper| {
        if (wrapper.apply_after_link_count == link_count and wrapper.kind == .sequence) return true;
    }
    return false;
}

fn willNeedWrappedFollowupCall(
    wrappers: *const std.ArrayListUnmanaged(TransparentWrapper),
    links: []const ChainLink,
    optional_link_index: usize,
) bool {
    var link_count = optional_link_index + 1;
    while (link_count < links.len and !links[link_count].is_optional) : (link_count += 1) {
        if (links[link_count].kind != .call) continue;
        if (!hasParenthesizedWrapperAtLinkCount(wrappers, link_count)) continue;
        return true;
    }
    return false;
}

fn willNeedFollowupCallValue(links: []const ChainLink, optional_link_index: usize) bool {
    var seen_non_optional = false;
    var link_count = optional_link_index + 1;
    while (link_count < links.len and !links[link_count].is_optional) : (link_count += 1) {
        if (links[link_count].kind == .call and seen_non_optional) return true;
        seen_non_optional = true;
    }
    return false;
}

fn hasFutureNonOptionalCall(links: []const ChainLink, current_index: usize) bool {
    var link_count = current_index + 1;
    while (link_count < links.len and !links[link_count].is_optional) : (link_count += 1) {
        if (links[link_count].kind == .call) return true;
    }
    return false;
}

fn hasFutureOptionalBoundary(links: []const ChainLink, current_index: usize) bool {
    var link_count = current_index + 1;
    while (link_count < links.len) : (link_count += 1) {
        if (links[link_count].is_optional) return true;
    }
    return false;
}

fn canSkipContinuationTempAfterOptionalMember(ref: []const u8, links: []const ChainLink, current_index: usize) bool {
    if (!(g_config.loose or g_config.pure_getters)) return false;
    if (current_index + 1 >= links.len) return false;
    const next = links[current_index + 1];
    return next.is_optional and next.kind == .call and isSimpleRepeatedMemberChainSource(ref);
}

fn isSimpleRepeatedMemberChainSource(src: []const u8) bool {
    if (src.len == 0) return false;
    const current = stripAllOuterParens(src);
    if (current.len == 0) return false;
    if (std.mem.eql(u8, current, "this") or std.mem.eql(u8, current, "super")) return true;

    var i: usize = 0;
    if (!isIdentStart(current[i])) return false;
    i += 1;
    while (i < current.len and isIdentCont(current[i])) : (i += 1) {}
    while (i < current.len) {
        if (current[i] != '.') return false;
        i += 1;
        if (i >= current.len or !isIdentStart(current[i])) return false;
        i += 1;
        while (i < current.len and isIdentCont(current[i])) : (i += 1) {}
    }
    return true;
}

fn hasCallContextWrapperAtLinkCount(wrappers: *const std.ArrayListUnmanaged(TransparentWrapper), link_count: usize) bool {
    for (wrappers.items) |wrapper| {
        if (wrapper.apply_after_link_count != link_count) continue;
        switch (wrapper.kind) {
            .ts_as, .ts_satisfies => return true,
            else => {},
        }
    }
    return false;
}

fn hasParenthesizedWrapperAtLinkCount(wrappers: *const std.ArrayListUnmanaged(TransparentWrapper), link_count: usize) bool {
    for (wrappers.items) |wrapper| {
        if (wrapper.apply_after_link_count != link_count) continue;
        if (wrapper.kind == .parenthesized) return true;
    }
    return false;
}

fn stripOuterParens(expr: []const u8) []const u8 {
    if (expr.len < 2 or expr[0] != '(' or expr[expr.len - 1] != ')') return expr;

    var depth: i32 = 0;
    for (expr[0 .. expr.len - 1], 0..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0 and i + 1 < expr.len - 1) return expr;
            },
            else => {},
        }
    }

    return expr[1 .. expr.len - 1];
}

fn hasSequenceWrapperSource(expr: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, expr, " \t");
    return std.mem.startsWith(u8, trimmed, "(0,");
}

fn sequenceWrapperTemp(
    ctx: *TransformContext,
    ref: []const u8,
    current_temp: ?[]const u8,
    last_non_optional_link_node: ?NodeIndex,
    body_idx: u32,
) []const u8 {
    const split = splitMemberAccessSource(ref, current_temp);
    if (split.prop.len > 0) {
        return allocUniqueName(ctx, sanitizeTempPrefix(ctx, split.prop), body_idx);
    }
    if (last_non_optional_link_node) |sequence_temp_node| {
        return allocTempForNode(ctx, sequence_temp_node, body_idx);
    }
    return "";
}

fn applyTransparentWrapper(ctx: *TransformContext, current: []const u8, wrapper: TransparentWrapper) []const u8 {
    switch (wrapper.kind) {
        .parenthesized => {
            const fallback = std.fmt.allocPrint(ctx.allocator, "({s})", .{current}) catch current;
            const child_tag = ctx.nodeTag(wrapper.child);
            if (needsChainBaseParens(current) or
                ((child_tag == .call_expr or child_tag == .optional_call_expr) and isBareTopLevelCallSource(current)))
            {
                return fallback;
            }
            const wrapper_start = getRawNodeStart(ctx, wrapper.node);
            const wrapper_end = getRawNodeEnd(ctx, wrapper.node);
            const child_start = getRawNodeStart(ctx, wrapper.child);
            const child_end = getRawNodeEnd(ctx, wrapper.child);
            if (wrapper_start >= wrapper_end or wrapper_end > ctx.ast.source.len) return fallback;
            if (child_start < wrapper_start or child_end > wrapper_end or child_start > child_end) return fallback;

            const wrapper_src = ctx.ast.source[wrapper_start..wrapper_end];
            const rel_start = child_start - wrapper_start;
            const rel_end = child_end - wrapper_start;
            if (rel_start > wrapper_src.len or rel_end > wrapper_src.len or rel_start > rel_end) return fallback;

            var buf: std.ArrayListUnmanaged(u8) = .empty;
            buf.appendSlice(ctx.allocator, wrapper_src[0..rel_start]) catch return fallback;
            buf.appendSlice(ctx.allocator, current) catch return fallback;
            buf.appendSlice(ctx.allocator, wrapper_src[rel_end..]) catch return fallback;
            return buf.items;
        },
        .ts_non_null => {
            const wrapped_current = if (needsChainBaseParens(current))
                std.fmt.allocPrint(ctx.allocator, "({s})", .{current}) catch current
            else
                current;
            return std.fmt.allocPrint(ctx.allocator, "{s}!", .{wrapped_current}) catch current;
        },
        .sequence => {
            const wrapper_start = getRawNodeStart(ctx, wrapper.node);
            const wrapper_end = getRawNodeEnd(ctx, wrapper.node);
            const child_start = getRawNodeStart(ctx, wrapper.child);
            const child_end = getRawNodeEnd(ctx, wrapper.child);
            if (wrapper_start >= wrapper_end or wrapper_end > ctx.ast.source.len) return current;
            if (child_start < wrapper_start or child_end > wrapper_end or child_start > child_end) return current;

            const wrapper_src = ctx.ast.source[wrapper_start..wrapper_end];
            const rel_start = child_start - wrapper_start;
            const rel_end = child_end - wrapper_start;
            if (rel_start > wrapper_src.len or rel_end > wrapper_src.len or rel_start > rel_end) return current;

            var buf: std.ArrayListUnmanaged(u8) = .empty;
            buf.appendSlice(ctx.allocator, wrapper_src[0..rel_start]) catch return current;
            buf.appendSlice(ctx.allocator, current) catch return current;
            buf.appendSlice(ctx.allocator, wrapper_src[rel_end..]) catch return current;
            return buf.items;
        },
        .ts_as, .ts_satisfies => {
            const wrapper_start = getRawNodeStart(ctx, wrapper.node);
            const wrapper_end = getRawNodeEnd(ctx, wrapper.node);
            const child_start = getRawNodeStart(ctx, wrapper.child);
            const child_end = getRawNodeEnd(ctx, wrapper.child);
            if (wrapper_start >= wrapper_end or wrapper_end > ctx.ast.source.len) return current;
            if (child_start < wrapper_start or child_end > wrapper_end or child_start > child_end) return current;

            const wrapper_src = ctx.ast.source[wrapper_start..wrapper_end];
            const rel_start = child_start - wrapper_start;
            const rel_end = child_end - wrapper_start;
            if (rel_start > wrapper_src.len or rel_end > wrapper_src.len or rel_start > rel_end) return current;

            const wrapped_current = if (needsTypeAssertionParens(current))
                std.fmt.allocPrint(ctx.allocator, "({s})", .{current}) catch current
            else
                current;

            var buf: std.ArrayListUnmanaged(u8) = .empty;
            buf.appendSlice(ctx.allocator, wrapper_src[0..rel_start]) catch return current;
            buf.appendSlice(ctx.allocator, wrapped_current) catch return current;
            buf.appendSlice(ctx.allocator, wrapper_src[rel_end..]) catch return current;
            return buf.items;
        },
    }
}

fn needsTypeAssertionParens(expr: []const u8) bool {
    if (expr.len == 0) return false;
    if (expr[0] == '(' and stripOuterParens(expr).len != expr.len) return false;

    var depth_paren: i32 = 0;
    var depth_bracket: i32 = 0;
    var depth_brace: i32 = 0;
    var in_quote: ?u8 = null;
    var escaped = false;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                in_quote = null;
            }
            continue;
        }

        switch (c) {
            '\'', '"', '`' => {
                in_quote = c;
                continue;
            },
            '(' => depth_paren += 1,
            ')' => depth_paren -= 1,
            '[' => depth_bracket += 1,
            ']' => depth_bracket -= 1,
            '{' => depth_brace += 1,
            '}' => depth_brace -= 1,
            '?' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) return true,
            ':' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) return true,
            ',' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) return true,
            '|' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 and i + 1 < expr.len and expr[i + 1] == '|') return true;
            },
            '&' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 and i + 1 < expr.len and expr[i + 1] == '&') return true;
            },
            '=' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) return true;
            },
            else => {},
        }
    }
    return false;
}

fn allocChainTemp(ctx: *TransformContext, base_node: NodeIndex, chain_prefix: []const u8, body_idx: u32) []const u8 {
    // The chain_prefix is the chain path name like "obj$a" used for temp naming
    _ = base_node;
    return allocUniqueName(ctx, chain_prefix, body_idx);
}

/// Derive a prefix string from a chain of links applied to a base.
/// For base "obj" + [?.a] → "obj$a"
/// For base "obj" + [?.a, .b, ?.c] → "obj$a$b$c" (but we only use up to current position)
fn deriveChainPrefix(ctx: *TransformContext, base_node: NodeIndex, links: []const ChainLink, up_to: usize) []const u8 {
    var prefix = deriveTempPrefix(ctx, base_node);
    for (links[0..up_to]) |link| {
        switch (link.kind) {
            .member => {
                const prop = getLinkPropName(ctx, link.node);
                if (prop.len > 0) {
                    prefix = std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ prefix, prop }) catch return prefix;
                }
            },
            .computed => {
                // For computed, just extend with the key name if it's a simple key
                const key = getLinkKeySource(ctx, link.node);
                if (key.len > 0 and key.len < 20 and !std.mem.containsAtLeast(u8, key, 1, ".")) {
                    prefix = std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ prefix, key }) catch return prefix;
                }
            },
            .call => {
                // Calls don't change the prefix naming
            },
        }
    }
    return prefix;
}

fn deriveContinuationPrefix(ctx: *TransformContext, base_node: NodeIndex, links: []const ChainLink, current_optional_index: usize) []const u8 {
    var up_to = current_optional_index + 1;
    while (up_to < links.len and !links[up_to].is_optional) : (up_to += 1) {}
    return deriveChainPrefix(ctx, base_node, links, up_to);
}

fn emitOptionalCallV2(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    link: ChainLink,
    ref: *[]const u8,
    temp: *?[]const u8,
    temp_from_call_result: *bool,
    check_ctx: ChainContext,
    body_idx: u32,
) void {
    const args_src = getCallArgsSource(ctx, link.node);
    const spread_args_src = getSingleSpreadCallArgsSource(ctx, link.node);
    const has_spread_args = spread_args_src.len > 0;
    const member_info = getCallMemberInfo(ctx, ref.*, temp.*);
    const direct_callee = normalizeDirectCallCalleeSource(ctx, ref.*);
    const callee_node = getCallCalleeNode(ctx, link.node);

    // The callee is the current `ref`. We need to determine if the callee
    // is a member expression that requires .call() for context preservation.
    // Pattern: `foo.bar?.()` → `(_foo$bar = foo.bar) == null ? void 0 : _foo$bar.call(foo)`
    // Pattern: `foo?.()` → `foo == null ? void 0 : foo()`
    // Pattern: `foo?.bar?.()` → after first ?., ref="_foo.bar", temp="_foo"
    //   → `(_foo$bar = _foo.bar) == null ? void 0 : _foo$bar.call(_foo)`

    // Check if the callee (ref) is a member access on some context object
    // We detect this by checking if ref has the form "X.Y" where we can identify the context
    const callee_is_member = member_info != null;
    const can_skip_context_memoize = callee_is_member and callee_node != .none and isSimplePureGetterCalleeNode(ctx, callee_node);

    // In loose mode (no_document_all), .call() context preservation is NOT used.
    // Instead, member expressions are repeated directly.
    if (callee_is_member and (!g_config.loose and !g_config.pure_getters or !can_skip_context_memoize)) {
        // Need .call() pattern (non-loose mode only)
        // Split ref into context and method
        const info = member_info orelse return;
        const is_super_member = std.mem.eql(u8, info.context, "super");
        const temp_is_context = if (temp.*) |existing_temp| blk: {
            if (!(std.mem.startsWith(u8, ref.*, existing_temp) and ref.*.len > existing_temp.len)) break :blk false;
            const next = ref.*[existing_temp.len];
            break :blk (next == '.' or next == '[');
        } else false;

        if (temp.*) |existing_temp| {
            if (!temp_is_context) {
                if (is_super_member) {
                    emitTempNullCheck(buf, ctx, existing_temp, stripOuterParens(ref.*), check_ctx);
                    if (has_spread_args) {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply(this, {s})", .{ existing_temp, spread_args_src }) catch "";
                    } else if (args_src.len > 0) {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call(this, {s})", .{ existing_temp, args_src }) catch "";
                    } else {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call(this)", .{existing_temp}) catch "";
                    }
                    return;
                }
                const memoize_simple_context = shouldMemoizeSimpleContext(ctx, link.node, info.context);
                if (std.mem.eql(u8, info.context, "eval") and splitTopLevelTsAs(stripAllOuterParens(ref.*)) == null) {
                    const effective_ctx: ChainContext = if (std.mem.eql(u8, info.context, "eval")) .expression else check_ctx;
                    emitTempNullCheck(buf, ctx, existing_temp, stripOuterParens(ref.*), effective_ctx);
                    if (has_spread_args) {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ existing_temp, info.context, spread_args_src }) catch "";
                    } else if (args_src.len > 0) {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s}, {s})", .{ existing_temp, info.context, args_src }) catch "";
                    } else {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s})", .{ existing_temp, info.context }) catch "";
                    }
                    return;
                }
                if (!memoize_simple_context and isSimpleCallContextSource(info.context) and splitTopLevelTsAs(stripAllOuterParens(ref.*)) == null) {
                    emitTempNullCheck(buf, ctx, existing_temp, stripOuterParens(ref.*), check_ctx);
                    if (has_spread_args) {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ existing_temp, info.context, spread_args_src }) catch "";
                    } else if (args_src.len > 0) {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s}, {s})", .{ existing_temp, info.context, args_src }) catch "";
                    } else {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s})", .{ existing_temp, info.context }) catch "";
                    }
                    return;
                }
                if (!memoize_simple_context and check_ctx != .expression and isSimpleCallContextSource(info.context) and splitTopLevelTsAs(stripAllOuterParens(ref.*)) != null) {
                    emitTempNullCheck(buf, ctx, existing_temp, stripOuterParens(ref.*), check_ctx);
                    if (has_spread_args) {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ existing_temp, info.context, spread_args_src }) catch "";
                    } else if (args_src.len > 0) {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s}, {s})", .{ existing_temp, info.context, args_src }) catch "";
                    } else {
                        ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s})", .{ existing_temp, info.context }) catch "";
                    }
                    return;
                }
                const raw_prefix = sanitizeTempPrefix(ctx, info.context);
                const prefix = if (raw_prefix.len > 0 and raw_prefix[0] == '_') raw_prefix[1..] else raw_prefix;
                const context_temp = allocUniqueName(ctx, prefix, body_idx);
                if (context_temp.len == 0) return;
                const accessor = getMemberAccessorSource(ref.*, temp.*);
                const method_rhs = if (accessor.len > 0)
                    std.fmt.allocPrint(ctx.allocator, "({s} = {s}){s}", .{ context_temp, info.context, accessor }) catch ""
                else
                    std.fmt.allocPrint(ctx.allocator, "({s} = {s}).{s}", .{ context_temp, info.context, info.prop }) catch "";
                emitTempNullCheck(buf, ctx, existing_temp, method_rhs, check_ctx);
                if (has_spread_args) {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ existing_temp, context_temp, spread_args_src }) catch "";
                } else if (args_src.len > 0) {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s}, {s})", .{ existing_temp, context_temp, args_src }) catch "";
                } else {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s})", .{ existing_temp, context_temp }) catch "";
                }
                return;
            }

            // Allocate temp for the method reference
            const method_temp = allocTempForCallCallee(ctx, link, ref.*, temp.*, body_idx);
            if (method_temp.len == 0) return;
            // Emit: (method_temp = ref) null_check
            emitTempNullCheck(buf, ctx, method_temp, ref.*, check_ctx);

            // Build: method_temp.call(context, args)
            if (is_super_member and has_spread_args) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply(this, {s})", .{ method_temp, spread_args_src }) catch "";
            } else if (is_super_member and args_src.len > 0) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call(this, {s})", .{ method_temp, args_src }) catch "";
            } else if (is_super_member) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call(this)", .{method_temp}) catch "";
            } else if (has_spread_args) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ method_temp, existing_temp, spread_args_src }) catch "";
            } else if (args_src.len > 0) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s}, {s})", .{ method_temp, existing_temp, args_src }) catch "";
            } else {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s})", .{ method_temp, existing_temp }) catch "";
            }
            temp.* = method_temp;
        } else {
            // Allocate temp for the method reference
            const method_temp = allocTempForCallCallee(ctx, link, ref.*, temp.*, body_idx);
            if (method_temp.len == 0) return;
            if (is_super_member) {
                emitTempNullCheck(buf, ctx, method_temp, ref.*, check_ctx);
                if (has_spread_args) {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply(this, {s})", .{ method_temp, spread_args_src }) catch "";
                } else if (args_src.len > 0) {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call(this, {s})", .{ method_temp, args_src }) catch "";
                } else {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call(this)", .{method_temp}) catch "";
                }
                temp.* = method_temp;
                return;
            }
            const context_temp = allocUniqueName(ctx, sanitizeTempPrefix(ctx, info.context), body_idx);
            if (context_temp.len == 0) return;
            const method_rhs = std.fmt.allocPrint(ctx.allocator, "({s} = {s}).{s}", .{ context_temp, info.context, info.prop }) catch "";
            emitTempNullCheck(buf, ctx, method_temp, method_rhs, check_ctx);
            if (has_spread_args) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ method_temp, context_temp, spread_args_src }) catch "";
            } else if (args_src.len > 0) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s}, {s})", .{ method_temp, context_temp, args_src }) catch "";
            } else {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s})", .{ method_temp, context_temp }) catch "";
            }
            temp.* = method_temp;
        }
    } else {
        // Simple call (or loose mode) — no .call() needed.
        // In loose mode, even member expression callees are called directly
        // (the receiver context is not preserved).
        if (callee_is_member and g_config.pure_getters and temp_from_call_result.* and temp.* != null) {
            const existing_temp = temp.*.?;
            const method_temp = allocTempForCallCallee(ctx, link, ref.*, temp.*, body_idx);
            if (method_temp.len == 0) return;
            emitTempNullCheck(buf, ctx, method_temp, ref.*, check_ctx);
            if (has_spread_args) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ method_temp, existing_temp, spread_args_src }) catch "";
            } else if (args_src.len > 0) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s}, {s})", .{ method_temp, existing_temp, args_src }) catch "";
            } else {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.call({s})", .{ method_temp, existing_temp }) catch "";
            }
            temp.* = method_temp;
            temp_from_call_result.* = false;
        } else if (callee_is_member and (g_config.loose or g_config.pure_getters)) {
            const info = member_info orelse return;
            if (std.mem.eql(u8, info.context, "eval")) {
                emitDirectNullCheck(buf, ctx, direct_callee, .expression);
                const call_callee = wrapDirectCallCalleeIfNeeded(ctx, direct_callee);
                if (has_spread_args) {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply(void 0, {s})", .{ call_callee, spread_args_src }) catch "";
                } else if (args_src.len > 0) {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}({s})", .{ call_callee, args_src }) catch "";
                } else {
                    ref.* = std.fmt.allocPrint(ctx.allocator, "{s}()", .{call_callee}) catch "";
                }
                return;
            }
            // Loose/pureGetters mode: emit null check for the member expression directly
            // e.g., foo.bar == null || foo.bar(args)
            emitDirectNullCheck(buf, ctx, direct_callee, check_ctx);
            const call_callee = wrapDirectCallCalleeIfNeeded(ctx, direct_callee);
            if (has_spread_args) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply(void 0, {s})", .{ call_callee, spread_args_src }) catch "";
            } else if (args_src.len > 0) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}({s})", .{ call_callee, args_src }) catch "";
            } else {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}()", .{call_callee}) catch "";
            }
        } else if (temp.*) |t| {
            emitTempNullCheck(buf, ctx, t, ref.*, check_ctx);
            if (has_spread_args) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply(void 0, {s})", .{ t, spread_args_src }) catch "";
            } else if (args_src.len > 0) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}({s})", .{ t, args_src }) catch "";
            } else {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}()", .{t}) catch "";
            }
        } else {
            emitDirectNullCheck(buf, ctx, direct_callee, check_ctx);
            const call_callee = wrapDirectCallCalleeIfNeeded(ctx, direct_callee);
            if (has_spread_args) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}.apply(void 0, {s})", .{ call_callee, spread_args_src }) catch "";
            } else if (args_src.len > 0) {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}({s})", .{ call_callee, args_src }) catch "";
            } else {
                ref.* = std.fmt.allocPrint(ctx.allocator, "{s}()", .{call_callee}) catch "";
            }
        }
    }
}

const CallMemberInfo = struct {
    context: []const u8,
    prop: []const u8,
};

fn getCallMemberInfo(ctx: *TransformContext, ref: []const u8, current_temp: ?[]const u8) ?CallMemberInfo {
    if (isBareTopLevelCallSource(stripOuterParens(ref))) return null;

    const direct = splitMemberAccessSource(ref, current_temp);
    if (direct.prop.len > 0) {
        return .{ .context = direct.context, .prop = direct.prop };
    }

    const stripped = stripOuterParens(ref);
    if (std.mem.eql(u8, stripped, ref)) return null;
    if (isBareTopLevelCallSource(stripped)) return null;

    const as_split = splitTopLevelTsAs(stripped) orelse return null;
    const inner = stripOuterParens(as_split.expr);
    if (isBareTopLevelCallSource(inner)) return null;
    const inner_split = splitMemberAccessSource(inner, current_temp);
    if (inner_split.prop.len == 0) return null;

    const prop_with_suffix = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ inner_split.prop, as_split.suffix }) catch return null;
    return .{ .context = inner_split.context, .prop = prop_with_suffix };
}

fn isBareTopLevelCallSource(expr: []const u8) bool {
    if (expr.len == 0 or expr[expr.len - 1] != ')') return false;

    var depth_paren: i32 = 0;
    var depth_bracket: i32 = 0;
    var depth_brace: i32 = 0;
    var last_top_level_sep: ?usize = null;
    var last_top_level_call_open: ?usize = null;

    for (expr, 0..) |c, i| {
        switch (c) {
            '(' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) {
                    last_top_level_call_open = i;
                }
                depth_paren += 1;
            },
            ')' => depth_paren -= 1,
            '[' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) {
                    last_top_level_sep = i;
                }
                depth_bracket += 1;
            },
            ']' => depth_bracket -= 1,
            '{' => depth_brace += 1,
            '}' => depth_brace -= 1,
            '.' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) {
                last_top_level_sep = i;
            },
            else => {},
        }
    }

    const call_open = last_top_level_call_open orelse return false;
    return last_top_level_sep == null or call_open > last_top_level_sep.?;
}

fn splitTopLevelTsAs(expr: []const u8) ?struct { expr: []const u8, suffix: []const u8 } {
    var depth_paren: i32 = 0;
    var depth_bracket: i32 = 0;
    var depth_brace: i32 = 0;
    var in_quote: ?u8 = null;
    var escaped = false;
    var i: usize = 0;
    while (i + 3 < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                in_quote = null;
            }
            continue;
        }

        switch (c) {
            '\'', '"', '`' => in_quote = c,
            '(' => depth_paren += 1,
            ')' => depth_paren -= 1,
            '[' => depth_bracket += 1,
            ']' => depth_bracket -= 1,
            '{' => depth_brace += 1,
            '}' => depth_brace -= 1,
            ' ' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 and
                    i + 3 < expr.len and expr[i + 1] == 'a' and expr[i + 2] == 's' and expr[i + 3] == ' ')
                {
                    return .{
                        .expr = expr[0..i],
                        .suffix = expr[i..],
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn normalizeDirectCallCalleeSource(ctx: *TransformContext, expr: []const u8) []const u8 {
    const stripped = stripOuterParens(expr);
    const candidate = if (std.mem.eql(u8, stripped, expr)) expr else stripped;

    const as_split = splitTopLevelTsAs(candidate) orelse return candidate;
    const inner = stripOuterParens(as_split.expr);
    const inner_split = splitMemberAccessSource(inner, null);
    if (inner_split.prop.len == 0) return candidate;

    return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ inner, as_split.suffix }) catch candidate;
}

fn wrapDirectCallCalleeIfNeeded(ctx: *TransformContext, expr: []const u8) []const u8 {
    const stripped = stripAllOuterParens(expr);
    if (std.mem.eql(u8, stripped, "eval")) {
        return "(0, eval)";
    }
    if (splitTopLevelTsAs(expr) != null) {
        return std.fmt.allocPrint(ctx.allocator, "({s})", .{expr}) catch expr;
    }
    return expr;
}

fn isSimpleCallContextSource(src: []const u8) bool {
    if (src.len == 0) return false;
    if (!isIdentStart(src[0])) return false;
    for (src[1..]) |c| {
        if (!isIdentCont(c)) return false;
    }
    return true;
}

fn getCallCalleeNode(ctx: *TransformContext, call_node: NodeIndex) NodeIndex {
    const data = ctx.nodeData(call_node);
    const eidx = @intFromEnum(data.extra);
    if (eidx >= ctx.ast.extra_data.items.len) return .none;
    return @enumFromInt(ctx.ast.extra_data.items[eidx]);
}

fn isSimplePureGetterCalleeNode(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    switch (ctx.nodeTag(node)) {
        .identifier, .this_expr, .super_expr => return true,
        .member_expr, .optional_chain_expr => {
            const data = ctx.nodeData(node);
            return isSimplePureGetterCalleeNode(ctx, data.binary.lhs);
        },
        .ts_as_expression, .ts_satisfies_expression => {
            const data = ctx.nodeData(node);
            return isSimplePureGetterCalleeNode(ctx, data.binary.lhs);
        },
        .parenthesized_expr, .ts_non_null_expression => {
            const data = ctx.nodeData(node);
            return isSimplePureGetterCalleeNode(ctx, data.unary);
        },
        else => return false,
    }
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn shouldMemoizeSimpleContext(ctx: *TransformContext, node: NodeIndex, src: []const u8) bool {
    if (!isSimpleCallContextSource(src)) return true;
    if (std.mem.eql(u8, src, "this") or std.mem.eql(u8, src, "super")) return false;
    if (ctx.scope) |scope_result| {
        if (findNearestScopeForNode(ctx, node)) |scope_idx| {
            if (scope_mod.getBinding(scope_result, scope_idx, src) != null) return false;
        }
    }
    if (isFunctionParameterBindingIdentifier(ctx, node, src)) return false;
    return !isWellKnownGlobal(src);
}

/// Check if a ref string looks like "X.Y" (a member access)
fn isMemberExprString(ref: []const u8, current_temp: ?[]const u8) bool {
    // If the ref starts with the temp and has a `.` or `[` after it, it's member access
    if (current_temp) |t| {
        if (std.mem.startsWith(u8, ref, t) and ref.len > t.len) {
            const c = ref[t.len];
            if (c == '.' or c == '[') return true;
        }
    }
    // Also check for source-level member access like "foo.bar"
    // Simple heuristic: contains a `.` that's not inside brackets/parens
    var depth: i32 = 0;
    for (ref) |c| {
        if (c == '(' or c == '[') depth += 1;
        if (c == ')' or c == ']') depth -= 1;
        if (c == '.' and depth == 0) return true;
    }
    return false;
}

/// Extract the context object from a member expression ref string.
/// For "obj.method" returns "obj", for "_temp.method" returns "_temp".
fn getMemberContext(ref: []const u8, current_temp: ?[]const u8) []const u8 {
    // If we have a temp and ref starts with temp.something, context is the temp
    if (current_temp) |t| {
        if (std.mem.startsWith(u8, ref, t) and ref.len > t.len) {
            const c = ref[t.len];
            if (c == '.' or c == '[') return t;
        }
    }
    // Find the last `.` at depth 0 and return everything before it
    var depth: i32 = 0;
    var last_dot: ?usize = null;
    for (ref, 0..) |c, j| {
        if (c == '(' or c == '[') depth += 1;
        if (c == ')' or c == ']') depth -= 1;
        if (c == '.' and depth == 0) last_dot = j;
    }
    if (last_dot) |d| return ref[0..d];
    return ref;
}

fn splitMemberAccessSource(ref: []const u8, current_temp: ?[]const u8) struct { context: []const u8, prop: []const u8 } {
    if (current_temp) |t| {
        if (std.mem.startsWith(u8, ref, t) and ref.len > t.len) {
            const c = ref[t.len];
            if (c == '.' or c == '[') {
                return .{ .context = t, .prop = ref[t.len + 1 ..] };
            }
        }
    }

    var depth: i32 = 0;
    var last_sep: ?usize = null;
    for (ref, 0..) |c, j| {
        if (c == '(' or c == '[') depth += 1;
        if (c == ')' or c == ']') depth -= 1;
        if ((c == '.' or c == '[') and depth == 0) last_sep = j;
    }

    if (last_sep) |sep| {
        return .{ .context = ref[0..sep], .prop = ref[sep + 1 ..] };
    }
    return .{ .context = ref, .prop = "" };
}

fn splitMemberAccessWithAccessor(ref: []const u8, current_temp: ?[]const u8) struct { context: []const u8, accessor: []const u8 } {
    if (current_temp) |t| {
        if (std.mem.startsWith(u8, ref, t) and ref.len > t.len) {
            const c = ref[t.len];
            if (c == '.' or c == '[') {
                return .{ .context = t, .accessor = ref[t.len..] };
            }
        }
    }

    var depth: i32 = 0;
    var last_sep: ?usize = null;
    for (ref, 0..) |c, j| {
        if ((c == '.' or c == '[') and depth == 0) last_sep = j;
        if (c == '(' or c == '[') depth += 1;
        if (c == ')' or c == ']') depth -= 1;
    }

    if (last_sep) |sep| {
        return .{ .context = ref[0..sep], .accessor = ref[sep..] };
    }
    return .{ .context = ref, .accessor = "" };
}

fn bindWrappedCallContextSource(ctx: *TransformContext, ref: []const u8, body_idx: u32) []const u8 {
    const stripped = stripOuterParens(ref);
    const as_target = stripAllOuterParens(stripped);
    if (splitTopLevelTsAs(as_target)) |as_split| {
        const bound_inner = bindWrappedCallContextSource(ctx, as_split.expr, body_idx);
        if (std.mem.eql(u8, bound_inner, as_split.expr)) return ref;
        const wrapped_inner = if (needsTypeAssertionParens(bound_inner))
            std.fmt.allocPrint(ctx.allocator, "({s})", .{bound_inner}) catch bound_inner
        else
            bound_inner;
        return std.fmt.allocPrint(ctx.allocator, "({s}{s})", .{ wrapped_inner, as_split.suffix }) catch ref;
    }

    const split = splitMemberAccessWithAccessor(stripped, null);
    if (split.accessor.len == 0 or std.mem.startsWith(u8, split.accessor, ".bind(")) return ref;

    if (g_config.loose or g_config.pure_getters or isSimpleCallContextSource(split.context)) {
        return std.fmt.allocPrint(ctx.allocator, "{s}{s}.bind({s})", .{ split.context, split.accessor, split.context }) catch ref;
    }

    const raw_prefix = sanitizeTempPrefix(ctx, split.context);
    const prefix = if (raw_prefix.len > 0 and raw_prefix[0] == '_') raw_prefix[1..] else raw_prefix;
    const context_temp = allocUniqueName(ctx, prefix, body_idx);
    if (context_temp.len == 0) return ref;
    return std.fmt.allocPrint(ctx.allocator, "({s} = {s}){s}.bind({s})", .{ context_temp, split.context, split.accessor, context_temp }) catch ref;
}

fn applyNonOptionalCallWithSpread(
    ctx: *TransformContext,
    ref: []const u8,
    current_temp: ?[]const u8,
    body_idx: u32,
    spread_args_src: []const u8,
) []const u8 {
    if (!(g_config.loose or g_config.pure_getters)) {
        if (getCallMemberInfo(ctx, ref, current_temp)) |info| {
            if (current_temp) |t| {
                const split = splitMemberAccessSource(ref, t);
                if (split.prop.len > 0) {
                    return std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ ref, t, spread_args_src }) catch ref;
                }
            }

            if (isSimpleCallContextSource(info.context)) {
                return std.fmt.allocPrint(ctx.allocator, "{s}.apply({s}, {s})", .{ ref, info.context, spread_args_src }) catch ref;
            }

            const split = splitMemberAccessWithAccessor(ref, current_temp);
            if (split.accessor.len > 0) {
                const raw_prefix = sanitizeTempPrefix(ctx, split.context);
                const prefix = if (raw_prefix.len > 0 and raw_prefix[0] == '_') raw_prefix[1..] else raw_prefix;
                const context_temp = allocUniqueName(ctx, prefix, body_idx);
                if (context_temp.len > 0) {
                    return std.fmt.allocPrint(
                        ctx.allocator,
                        "({s} = {s}){s}.apply({s}, {s})",
                        .{ context_temp, split.context, split.accessor, context_temp, spread_args_src },
                    ) catch ref;
                }
            }
        }
    }

    return std.fmt.allocPrint(ctx.allocator, "{s}.apply(void 0, {s})", .{ ref, spread_args_src }) catch ref;
}

fn allocCallResultTempForRef(
    ctx: *TransformContext,
    ref: []const u8,
    current_temp: ?[]const u8,
    body_idx: u32,
) []const u8 {
    const accessor_split = splitMemberAccessWithAccessor(stripOuterParens(ref), current_temp);
    if (std.mem.startsWith(u8, accessor_split.accessor, ".bind(")) {
        return allocCallResultTempForRef(ctx, accessor_split.context, current_temp, body_idx);
    }

    if (current_temp) |t| {
        const split = splitMemberAccessSource(ref, t);
        if (split.prop.len > 0) {
            const base = if (t.len > 0 and t[0] == '_') t[1..] else t;
            const prop_prefix = sanitizeTempPrefix(ctx, split.prop);
            const prefix = std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ base, prop_prefix }) catch prop_prefix;
            return allocUniqueName(ctx, prefix, body_idx);
        }
    }

    const direct = splitMemberAccessSource(ref, null);
    if (direct.prop.len > 0) {
        const prefix = sanitizeTempPrefix(ctx, direct.prop);
        return allocUniqueName(ctx, prefix, body_idx);
    }

    return allocUniqueName(ctx, sanitizeTempPrefix(ctx, ref), body_idx);
}

fn hoistTypeAssertionOverOptionalTernary(ctx: *TransformContext, ref: []const u8) []const u8 {
    const stripped = std.mem.trim(u8, ref, " \t");
    const q_idx = std.mem.indexOfScalar(u8, stripped, '?') orelse return ref;
    if (q_idx + 8 >= stripped.len) return ref;
    if (!std.mem.eql(u8, stripped[q_idx..@min(q_idx + 8, stripped.len)], "? void 0")) return ref;
    const colon_idx = std.mem.lastIndexOfScalar(u8, stripped, ':') orelse return ref;
    if (colon_idx <= q_idx) return ref;

    const rhs = std.mem.trim(u8, stripped[colon_idx + 1 ..], " \t");
    const as_split = splitTopLevelTsAs(stripAllOuterParens(rhs)) orelse return ref;
    const inner = stripOuterParens(as_split.expr);
    return std.fmt.allocPrint(
        ctx.allocator,
        "(({s} ? void 0 : {s}){s})",
        .{
            std.mem.trimEnd(u8, stripped[0..q_idx], " \t"),
            inner,
            as_split.suffix,
        },
    ) catch ref;
}

fn stripAllOuterParens(expr: []const u8) []const u8 {
    var current = expr;
    while (true) {
        const next = stripOuterParens(current);
        if (next.len == current.len) return current;
        current = next;
    }
}

fn sanitizeTempPrefix(ctx: *TransformContext, source: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (source) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => buf.append(ctx.allocator, c) catch return "ref",
            '.', '[' => buf.append(ctx.allocator, '$') catch return "ref",
            ' ', '\t', '\n', '\r', ')', ']', '?', ':' => break,
            else => break,
        }
    }
    if (buf.items.len == 0) return "ref";
    return buf.items;
}

/// Allocate a temp name for the callee of an optional call
fn allocTempForCallCallee(
    ctx: *TransformContext,
    link: ChainLink,
    ref: []const u8,
    current_temp: ?[]const u8,
    body_idx: u32,
) []const u8 {
    const accessor = getMemberAccessorSource(ref, current_temp);
    if (accessor.len > 1) {
        const split = splitMemberAccessWithAccessor(ref, current_temp);
        const raw_base = if (split.context.len > 0 and split.context[0] == '_') split.context[1..] else sanitizeTempPrefix(ctx, split.context);
        const raw_prop = if (accessor[0] == '.') accessor[1..] else accessor[1 .. accessor.len - 1];
        const prop = sanitizeTempPrefix(ctx, raw_prop);
        if (raw_base.len > 0 and prop.len > 0) {
            const prefix = std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ raw_base, prop }) catch prop;
            return allocUniqueName(ctx, prefix, body_idx);
        }
    }

    // Get the callee node from the call's AST
    const data = ctx.nodeData(link.node);
    const eidx = @intFromEnum(data.extra);
    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
    return allocTempForNode(ctx, callee, body_idx);
}

fn getMemberAccessorSource(ref: []const u8, current_temp: ?[]const u8) []const u8 {
    const split = splitMemberAccessWithAccessor(ref, current_temp);
    return split.accessor;
}

// ── Null check emitters ────────────────────────────────────────────

fn emitTempNullCheck(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, temp: []const u8, expr: []const u8, context: ChainContext) void {
    switch (context) {
        .boolean_cast => {
            if (g_config.no_document_all) {
                appendFmt(buf, ctx, "({s} = {s}) != null && ", .{ temp, expr });
            } else {
                appendFmt(buf, ctx, "({s} = {s}) !== null && {s} !== void 0 && ", .{ temp, expr, temp });
            }
        },
        .expression => {
            if (g_config.no_document_all) {
                appendFmt(buf, ctx, "({s} = {s}) == null ? void 0 : ", .{ temp, expr });
            } else {
                appendFmt(buf, ctx, "({s} = {s}) === null || {s} === void 0 ? void 0 : ", .{ temp, expr, temp });
            }
        },
        .statement, .delete_expr => {
            if (g_config.no_document_all) {
                appendFmt(buf, ctx, "({s} = {s}) == null || ", .{ temp, expr });
            } else {
                appendFmt(buf, ctx, "({s} = {s}) === null || {s} === void 0 || ", .{ temp, expr, temp });
            }
        },
    }
}

fn emitDirectNullCheck(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, expr: []const u8, context: ChainContext) void {
    switch (context) {
        .boolean_cast => {
            if (g_config.no_document_all) {
                appendFmt(buf, ctx, "{s} != null && ", .{expr});
            } else {
                appendFmt(buf, ctx, "{s} !== null && {s} !== void 0 && ", .{ expr, expr });
            }
        },
        .expression => {
            if (g_config.no_document_all) {
                appendFmt(buf, ctx, "{s} == null ? void 0 : ", .{expr});
            } else {
                appendFmt(buf, ctx, "{s} === null || {s} === void 0 ? void 0 : ", .{ expr, expr });
            }
        },
        .statement, .delete_expr => {
            if (g_config.no_document_all) {
                appendFmt(buf, ctx, "{s} == null || ", .{expr});
            } else {
                appendFmt(buf, ctx, "{s} === null || {s} === void 0 || ", .{ expr, expr });
            }
        },
    }
}

// ── Link application ───────────────────────────────────────────────

fn applyLink(ctx: *TransformContext, base_expr: []const u8, link: ChainLink) []const u8 {
    const base = if (needsChainBaseParens(base_expr))
        std.fmt.allocPrint(ctx.allocator, "({s})", .{base_expr}) catch base_expr
    else
        base_expr;
    switch (link.kind) {
        .member => {
            const prop = getLinkPropName(ctx, link.node);
            return std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ base, prop }) catch "";
        },
        .computed => {
            const key_src = getLinkKeySource(ctx, link.node);
            return std.fmt.allocPrint(ctx.allocator, "{s}[{s}]", .{ base, key_src }) catch "";
        },
        .call => {
            const args_src = getCallArgsSource(ctx, link.node);
            return std.fmt.allocPrint(ctx.allocator, "{s}({s})", .{ base, args_src }) catch "";
        },
    }
}

fn needsChainBaseParens(expr: []const u8) bool {
    var depth_paren: i32 = 0;
    var depth_bracket: i32 = 0;
    var depth_brace: i32 = 0;
    var in_quote: ?u8 = null;
    var escaped = false;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (in_quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                in_quote = null;
            }
            continue;
        }

        switch (c) {
            '\'', '"', '`' => in_quote = c,
            '(' => depth_paren += 1,
            ')' => depth_paren -= 1,
            '[' => depth_bracket += 1,
            ']' => depth_bracket -= 1,
            '{' => depth_brace += 1,
            '}' => depth_brace -= 1,
            '?' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) return true,
            ':' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) return true,
            ',' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) return true,
            '|' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 and i + 1 < expr.len and expr[i + 1] == '|') return true;
            },
            '&' => {
                if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 and i + 1 < expr.len and expr[i + 1] == '&') return true;
            },
            '=' => if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0) return true,
            else => {},
        }
    }
    return false;
}

fn extendRef(ctx: *TransformContext, ref: []const u8, ref_temp: ?[]const u8, link: ChainLink) []const u8 {
    const base = if (ref_temp) |t| t else ref;
    return applyLink(ctx, base, link);
}

fn getLinkPropName(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(node);
    if (tag == .optional_chain_expr or tag == .member_expr) {
        const data = ctx.nodeData(node);
        const prop_tok_raw = @intFromEnum(data.binary.rhs);
        return ctx.ast.tokenSlice(@enumFromInt(prop_tok_raw));
    }
    return "";
}

fn getLinkKeySource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(node);
    if (tag == .optional_computed_member_expr or tag == .computed_member_expr) {
        const data = ctx.nodeData(node);
        return getNodeSource(ctx, data.binary.rhs);
    }
    return "";
}

fn getCallArgsSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return "";
    const args_start = ctx.ast.extra_data.items[extra_idx + 1];
    const args_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (args_end <= args_start) return "";

    const first_arg: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[args_start]);
    const last_arg: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[args_end - 1]);
    const first_start = getNodeStart(ctx, first_arg);
    const last_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(last_arg)];
    if (first_start >= last_end or last_end > ctx.ast.source.len) return "";
    return ctx.ast.source[first_start..last_end];
}

fn getSingleSpreadCallArgsSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return "";

    const args_start = ctx.ast.extra_data.items[extra_idx + 1];
    const args_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (args_end != args_start + 1) return "";

    const arg: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[args_start]);
    if (arg == .none or ctx.nodeTag(arg) != .spread_element) return "";

    const inner = ctx.nodeData(arg).unary;
    if (inner == .none) return "";

    const inner_src = getNodeSource(ctx, inner);
    if (inner_src.len == 0) return "";
    if (std.mem.eql(u8, inner_src, "arguments")) return "arguments";
    return std.fmt.allocPrint(ctx.allocator, "babelHelpers.toConsumableArray({s})", .{inner_src}) catch "";
}

// ── Helper functions ───────────────────────────────────────────────

fn containsOptionalChain(ctx: *TransformContext, idx: NodeIndex) bool {
    if (idx == .none) return false;
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .optional_chain_expr, .optional_computed_member_expr, .optional_call_expr => return true,
        .member_expr, .computed_member_expr => {
            const data = ctx.nodeData(idx);
            return containsOptionalChain(ctx, data.binary.lhs);
        },
        .call_expr => {
            const data = ctx.nodeData(idx);
            const eidx = @intFromEnum(data.extra);
            if (eidx < ctx.ast.extra_data.items.len) {
                const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
                return containsOptionalChain(ctx, callee);
            }
            return false;
        },
        .parenthesized_expr => {
            const data = ctx.nodeData(idx);
            return containsOptionalChain(ctx, data.unary);
        },
        .ts_non_null_expression => {
            const data = ctx.nodeData(idx);
            return containsOptionalChain(ctx, data.unary);
        },
        .ts_as_expression, .ts_satisfies_expression => {
            const data = ctx.nodeData(idx);
            return containsOptionalChain(ctx, data.binary.lhs);
        },
        .sequence_expr => {
            const data = ctx.nodeData(idx);
            const eidx = @intFromEnum(data.extra);
            if (eidx + 1 >= ctx.ast.extra_data.items.len) return false;
            const range_start = ctx.ast.extra_data.items[eidx];
            const range_end = ctx.ast.extra_data.items[eidx + 1];
            if (range_end <= range_start) return false;
            const last_item: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_end - 1]);
            return containsOptionalChain(ctx, last_item);
        },
        else => return false,
    }
}

fn needsTempForBase(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .identifier => {
            const name = ctx.tokenSlice(ctx.mainToken(node));
            if (ctx.scope) |scope_result| {
                const scope_idx = findNearestScopeForNode(ctx, node) orelse return true;
                if (scope_mod.getBinding(scope_result, scope_idx, name) != null) return false;
                if (isFunctionParameterBindingIdentifier(ctx, node, name)) return false;
                return true; // undeclared
            }
            return !isWellKnownGlobal(name);
        },
        .this_expr => return false,
        .super_expr => return false,
        .string_literal, .numeric_literal, .boolean_literal => return false,
        .null_literal => return true, // Babel caches null literal in temp like any expression
        .member_expr, .computed_member_expr => {
            // super.X is always safe to repeat — no temp needed
            const d = ctx.nodeData(node);
            if (ctx.nodeTag(d.binary.lhs) == .super_expr) return false;
            return true;
        },
        .call_expr => return true,
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            return needsTempForBase(ctx, d.unary);
        },
        else => return true,
    }
}

fn findNearestScopeForNode(ctx: *TransformContext, node: NodeIndex) ?scope_mod.ScopeIndex {
    const scope_result = ctx.scope orelse return null;
    var current = node;
    while (true) {
        if (scope_mod.getScopeForNode(scope_result, current)) |scope_idx| return scope_idx;
        const parent = findParentOf(ctx, current);
        if (parent == .none) return null;
        current = parent;
    }
}

fn isFunctionParameterBindingIdentifier(ctx: *TransformContext, node: NodeIndex, name: []const u8) bool {
    var current = node;
    while (true) {
        const parent = findParentOf(ctx, current);
        if (parent == .none) return false;
        switch (ctx.nodeTag(parent)) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .arrow_function_expr,
            .class_method,
            .class_private_method,
            .computed_method,
            .method_definition,
            => return functionParamsContainBindingName(ctx, parent, name),
            else => current = parent,
        }
    }
}

fn functionParamsContainBindingName(ctx: *TransformContext, func: NodeIndex, name: []const u8) bool {
    const data = ctx.nodeData(func);
    const eidx = @intFromEnum(data.extra);
    if (ctx.nodeTag(func) == .arrow_function_expr) {
        if (eidx + 2 >= ctx.ast.extra_data.items.len) return false;
        const third_val = ctx.ast.extra_data.items[eidx + 2];
        if (third_val <= 1) {
            const param: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
            return patternContainsBindingName(ctx, param, name);
        }
        const params_start = ctx.ast.extra_data.items[eidx];
        const params_end = ctx.ast.extra_data.items[eidx + 1];
        if (params_end <= params_start or params_end > ctx.ast.extra_data.items.len) return false;

        for (ctx.ast.extra_data.items[params_start..params_end]) |param_raw| {
            const param: NodeIndex = @enumFromInt(param_raw);
            if (patternContainsBindingName(ctx, param, name)) return true;
        }
        return false;
    }

    if (eidx + 2 >= ctx.ast.extra_data.items.len) return false;
    const params_start = ctx.ast.extra_data.items[eidx + 1];
    const params_end = ctx.ast.extra_data.items[eidx + 2];
    if (params_end <= params_start or params_end > ctx.ast.extra_data.items.len) return false;

    for (ctx.ast.extra_data.items[params_start..params_end]) |param_raw| {
        const param: NodeIndex = @enumFromInt(param_raw);
        if (patternContainsBindingName(ctx, param, name)) return true;
    }
    return false;
}

fn patternContainsBindingName(ctx: *TransformContext, node: NodeIndex, name: []const u8) bool {
    switch (ctx.nodeTag(node)) {
        .identifier => return std.mem.eql(u8, ctx.tokenSlice(ctx.mainToken(node)), name),
        .assignment_pattern => return patternContainsBindingName(ctx, ctx.nodeData(node).binary.lhs, name),
        .rest_element => return patternContainsBindingName(ctx, ctx.nodeData(node).unary, name),
        .parenthesized_expr => return patternContainsBindingName(ctx, ctx.nodeData(node).unary, name),
        .array_pattern => {
            const data = ctx.nodeData(node);
            const eidx = @intFromEnum(data.extra);
            if (eidx + 1 >= ctx.ast.extra_data.items.len) return false;
            const range_start = ctx.ast.extra_data.items[eidx];
            const range_end = ctx.ast.extra_data.items[eidx + 1];
            if (range_end <= range_start or range_end > ctx.ast.extra_data.items.len) return false;
            for (ctx.ast.extra_data.items[range_start..range_end]) |item_raw| {
                const item: NodeIndex = @enumFromInt(item_raw);
                if (item != .none and patternContainsBindingName(ctx, item, name)) return true;
            }
            return false;
        },
        .object_pattern => {
            const data = ctx.nodeData(node);
            const eidx = @intFromEnum(data.extra);
            if (eidx + 1 >= ctx.ast.extra_data.items.len) return false;
            const range_start = ctx.ast.extra_data.items[eidx];
            const range_end = ctx.ast.extra_data.items[eidx + 1];
            if (range_end <= range_start or range_end > ctx.ast.extra_data.items.len) return false;
            for (ctx.ast.extra_data.items[range_start..range_end]) |item_raw| {
                const item: NodeIndex = @enumFromInt(item_raw);
                if (item != .none and patternContainsBindingName(ctx, item, name)) return true;
            }
            return false;
        },
        .property, .computed_property => return patternContainsBindingName(ctx, ctx.nodeData(node).binary.rhs, name),
        .shorthand_property => return patternContainsBindingName(ctx, ctx.nodeData(node).unary, name),
        else => return false,
    }
}

fn allocTempForNode(ctx: *TransformContext, node: NodeIndex, body_idx: u32) []const u8 {
    const prefix = deriveTempPrefix(ctx, node);
    return allocUniqueName(ctx, prefix, body_idx);
}

fn allocNextTemp(ctx: *TransformContext, expr: []const u8, body_idx: u32) []const u8 {
    // Derive a prefix from the expression string
    // For something like "_foo.bar", extract "foo$bar"
    _ = expr;
    return allocUniqueName(ctx, "ref", body_idx);
}

fn deriveTempPrefix(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .identifier => return ctx.tokenSlice(ctx.mainToken(node)),
        .this_expr => return "this",
        .super_expr => return "super",
        .member_expr, .optional_chain_expr => {
            const d = ctx.nodeData(node);
            if (ctx.nodeTag(d.binary.lhs) == .ts_non_null_expression) {
                const prop_tok = @intFromEnum(d.binary.rhs);
                return ctx.ast.tokenSlice(@enumFromInt(prop_tok));
            }
            const obj_prefix = deriveTempPrefix(ctx, d.binary.lhs);
            const prop_tok = @intFromEnum(d.binary.rhs);
            const prop_name = ctx.ast.tokenSlice(@enumFromInt(prop_tok));
            return std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_prefix, prop_name }) catch "ref";
        },
        .computed_member_expr, .optional_computed_member_expr => {
            const d = ctx.nodeData(node);
            const obj_prefix = deriveTempPrefix(ctx, d.binary.lhs);
            const key_prefix = deriveKeyPrefix(ctx, d.binary.rhs);
            if (key_prefix.len > 0) {
                return std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_prefix, key_prefix }) catch obj_prefix;
            }
            return obj_prefix;
        },
        .call_expr, .optional_call_expr => {
            const d = ctx.nodeData(node);
            const eidx = @intFromEnum(d.extra);
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
            return deriveTempPrefix(ctx, callee);
        },
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            return deriveTempPrefix(ctx, d.unary);
        },
        .ts_non_null_expression => {
            const d = ctx.nodeData(node);
            return deriveTempPrefix(ctx, d.unary);
        },
        .ts_as_expression, .ts_satisfies_expression => {
            const d = ctx.nodeData(node);
            return deriveTempPrefix(ctx, d.binary.lhs);
        },
        .sequence_expr => {
            const d = ctx.nodeData(node);
            const eidx = @intFromEnum(d.extra);
            if (eidx + 1 >= ctx.ast.extra_data.items.len) return "ref";
            const range_start = ctx.ast.extra_data.items[eidx];
            const range_end = ctx.ast.extra_data.items[eidx + 1];
            if (range_end <= range_start) return "ref";
            const last_item: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_end - 1]);
            return deriveTempPrefix(ctx, last_item);
        },
        .object_expr => return "ref",
        else => return "ref",
    }
}

/// Derive a prefix for a computed key expression (for temp naming).
fn deriveKeyPrefix(ctx: *TransformContext, key_node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(key_node);
    switch (tag) {
        .identifier => return ctx.tokenSlice(ctx.mainToken(key_node)),
        .string_literal => {
            const tok_slice = ctx.tokenSlice(ctx.mainToken(key_node));
            if (tok_slice.len >= 2) {
                return tok_slice[1 .. tok_slice.len - 1]; // strip quotes
            }
            return tok_slice;
        },
        .member_expr => {
            return deriveTempPrefix(ctx, key_node);
        },
        else => return "",
    }
}

fn appendFmt(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(ctx.allocator, fmt, args) catch return;
    buf.appendSlice(ctx.allocator, s) catch {};
}

// ── Temp variable management ───────────────────────────────────────

fn allocUniqueName(ctx: *TransformContext, prefix: []const u8, body_idx: u32) []const u8 {
    const first = std.fmt.allocPrint(ctx.allocator, "_{s}", .{prefix}) catch return "";
    if (!g_allocated_names.contains(first)) {
        g_allocated_names.put(ctx.allocator, first, {}) catch {};
        registerTempForBody(ctx, first, body_idx);
        return first;
    }

    var counter: u32 = 2;
    while (counter < 10000) : (counter += 1) {
        const rendered = if (counter == 10)
            0
        else if (counter == 11)
            1
        else
            counter;
        const candidate = std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ prefix, rendered }) catch return "";
        if (!g_allocated_names.contains(candidate)) {
            g_allocated_names.put(ctx.allocator, candidate, {}) catch {};
            registerTempForBody(ctx, candidate, body_idx);
            return candidate;
        }
    }
    return "";
}

fn registerTempForBody(ctx: *TransformContext, name: []const u8, body_idx: u32) void {
    const gop = g_body_temps.getOrPut(ctx.allocator, body_idx) catch return;
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }
    gop.value_ptr.append(ctx.allocator, name) catch {};
}

fn isWellKnownGlobal(name: []const u8) bool {
    const globals = [_][]const u8{
        "globalThis", "undefined",    "NaN",                "Infinity",
        "console",    "window",       "document",           "navigator",
        "Math",       "JSON",         "Object",             "Array",
        "String",     "Number",       "Boolean",            "Symbol",
        "BigInt",     "Date",         "RegExp",             "Map",
        "Set",        "WeakMap",      "WeakSet",            "Promise",
        "Error",      "TypeError",    "RangeError",         "SyntaxError",
        "parseInt",   "parseFloat",   "isNaN",              "isFinite",
        "encodeURI",  "decodeURI",    "encodeURIComponent", "decodeURIComponent",
        "setTimeout", "clearTimeout", "setInterval",        "clearInterval",
        "require",    "module",       "exports",            "__dirname",
        "__filename", "process",      "Buffer",             "eval",
    };
    for (globals) |g| {
        if (std.mem.eql(u8, name, g)) return true;
    }
    return false;
}

// ── Enclosing body ─────────────────────────────────────────────────

fn findEnclosingBody(ctx: *TransformContext, node: NodeIndex) u32 {
    if (findLoopConditionBody(ctx, node)) |loop_body| {
        return @intFromEnum(loop_body);
    }
    if (ctx.scope) |scope_result| {
        if (scope_mod.getScopeForNode(scope_result, node)) |scope_idx| {
            var current: ?scope_mod.ScopeIndex = scope_idx;
            while (current) |si| {
                const scope = scope_result.scopes[@intFromEnum(si)];
                switch (scope.kind) {
                    .function, .arrow => {
                        if (getFunctionBody(ctx, scope.node)) |body| {
                            return @intFromEnum(body);
                        }
                        if (ctx.nodeTag(scope.node) == .arrow_function_expr) {
                            return @intFromEnum(scope.node);
                        }
                        return 0;
                    },
                    .block => {
                        // For block scopes, use the block_statement node if it exists.
                        // This places temp var declarations inside the nearest block,
                        // matching Babel's behavior where var declarations appear at the
                        // top of the enclosing block rather than the function.
                        if (scope.node != .none) {
                            const block_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(scope.node)];
                            if (block_tag == .block_statement) {
                                return @intFromEnum(scope.node);
                            }
                        }
                    },
                    .global, .module => return 0,
                    else => {},
                }
                current = scope.parent;
            }
        }
    }
    return findEnclosingBodyBrute(ctx, node);
}

fn findLoopConditionBody(ctx: *TransformContext, node: NodeIndex) ?NodeIndex {
    var current = node;
    while (true) {
        const parent = findParentOf(ctx, current);
        if (parent == .none) return null;
        const pdata = ctx.nodeData(parent);
        switch (ctx.nodeTag(parent)) {
            .while_statement => {
                if (pdata.binary.lhs == current) return pdata.binary.rhs;
            },
            .do_while_statement => {
                if (pdata.binary.rhs == current) return pdata.binary.lhs;
            },
            .for_statement => {
                const eidx = @intFromEnum(pdata.extra);
                if (eidx + 3 < ctx.ast.extra_data.items.len) {
                    const cond: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx + 1]);
                    if (cond == current) {
                        return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
                    }
                }
            },
            else => {},
        }
        current = parent;
    }
}

fn getFunctionBody(ctx: *TransformContext, func_node: NodeIndex) ?NodeIndex {
    const ni = @intFromEnum(func_node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return null;
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
        .arrow_function_expr => {
            const eidx = @intFromEnum(d.extra);
            if (eidx + 2 < ctx.ast.extra_data.items.len) {
                const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx + 2]);
                if (ctx.nodeTag(body) == .block_statement) return body;
            }
        },
        else => {},
    }
    return null;
}

fn findEnclosingBodyBrute(ctx: *TransformContext, target: NodeIndex) u32 {
    const target_start = getNodeStart(ctx, target);
    const target_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(target)];
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
            .arrow_function_expr,
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
            } else if (tag == .arrow_function_expr) {
                best_body = @intCast(ni);
            }
        }
    }

    return best_body;
}

// ── Parent finding ─────────────────────────────────────────────────

fn findParentOf(ctx: *TransformContext, target: NodeIndex) NodeIndex {
    const target_i = @intFromEnum(target);
    const tags = ctx.ast.nodes.items(.tag);
    const data_items = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        const data = data_items[ni];
        switch (tag) {
            // member_expr / optional_chain_expr: rhs is a TOKEN index, not a node
            .member_expr, .optional_chain_expr => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
                // NOTE: data.binary.rhs is a token index for these, NOT a node index
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
            .property,
            .computed_property,
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
            .rest_element,
            .yield_expr,
            .await_expr,
            .shorthand_property,
            => {
                if (@intFromEnum(data.unary) == target_i) return @enumFromInt(ni);
            },
            .call_expr, .optional_call_expr, .new_expr => {
                const eidx = @intFromEnum(data.extra);
                if (eidx < ctx.ast.extra_data.items.len) {
                    if (ctx.ast.extra_data.items[eidx] == target_i) return @enumFromInt(ni);
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
            .while_statement, .do_while_statement => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
                if (@intFromEnum(data.binary.rhs) == target_i) return @enumFromInt(ni);
            },
            .declarator => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
                if (@intFromEnum(data.binary.rhs) == target_i) return @enumFromInt(ni);
            },
            .sequence_expr => {
                const eidx = @intFromEnum(data.extra);
                if (eidx + 1 < ctx.ast.extra_data.items.len) {
                    const range_start = ctx.ast.extra_data.items[eidx];
                    const range_end = ctx.ast.extra_data.items[eidx + 1];
                    if (range_end > range_start and range_end <= ctx.ast.extra_data.items.len) {
                        for (ctx.ast.extra_data.items[range_start..range_end]) |item_raw| {
                            if (item_raw == target_i) return @enumFromInt(ni);
                        }
                    }
                }
            },
            .for_statement => {
                const eidx = @intFromEnum(data.extra);
                if (eidx + 3 < ctx.ast.extra_data.items.len) {
                    for (0..4) |offset| {
                        if (ctx.ast.extra_data.items[eidx + offset] == target_i) return @enumFromInt(ni);
                    }
                }
            },
            .var_declaration, .let_declaration, .const_declaration, .array_expr, .array_pattern, .object_pattern => {
                // Check declarator children in range
                const eidx = @intFromEnum(data.extra);
                if (eidx + 1 < ctx.ast.extra_data.items.len) {
                    const range_start = ctx.ast.extra_data.items[eidx];
                    const range_end = ctx.ast.extra_data.items[eidx + 1];
                    if (range_end > range_start and range_end <= ctx.ast.extra_data.items.len) {
                        for (ctx.ast.extra_data.items[range_start..range_end]) |item_raw| {
                            if (item_raw == target_i) return @enumFromInt(ni);
                        }
                    }
                }
            },
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .arrow_function_expr,
            .class_method,
            .class_private_method,
            .computed_method,
            .method_definition,
            => {
                const eidx = @intFromEnum(data.extra);
                if (tag == .arrow_function_expr) {
                    if (eidx + 2 < ctx.ast.extra_data.items.len) {
                        const third_val = ctx.ast.extra_data.items[eidx + 2];
                        if (third_val <= 1) {
                            if (ctx.ast.extra_data.items[eidx] == target_i) return @enumFromInt(ni);
                        } else {
                            const range_start = ctx.ast.extra_data.items[eidx];
                            const range_end = ctx.ast.extra_data.items[eidx + 1];
                            if (range_end > range_start and range_end <= ctx.ast.extra_data.items.len) {
                                for (ctx.ast.extra_data.items[range_start..range_end]) |item_raw| {
                                    if (item_raw == target_i) return @enumFromInt(ni);
                                }
                            }
                        }
                    }
                } else if (eidx + 2 < ctx.ast.extra_data.items.len) {
                    const range_start = ctx.ast.extra_data.items[eidx + 1];
                    const range_end = ctx.ast.extra_data.items[eidx + 2];
                    if (range_end > range_start and range_end <= ctx.ast.extra_data.items.len) {
                        for (ctx.ast.extra_data.items[range_start..range_end]) |item_raw| {
                            if (item_raw == target_i) return @enumFromInt(ni);
                        }
                    }
                }
            },
            else => {},
        }
    }
    return .none;
}

// ── Source text helpers ─────────────────────────────────────────────

fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni_check = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(ni_check)) |replacement| return replacement;
    const start = getNodeStart(ctx, node);
    const end = getNodeEnd(ctx, node);
    if (start >= end or end > ctx.ast.source.len) return "";
    return ctx.ast.source[start..end];
}

fn getNodeEnd(ctx: *TransformContext, node: NodeIndex) u32 {
    var n = node;
    // For transparent wrappers, use the inner expression's end_offset so replacement
    // source does not accidentally retain parens or TS non-null assertions.
    while (true) {
        const tag = ctx.ast.nodes.items(.tag)[@intFromEnum(n)];
        const d = ctx.ast.nodes.items(.data)[@intFromEnum(n)];
        switch (tag) {
            .parenthesized_expr, .ts_non_null_expression => n = d.unary,
            else => break,
        }
    }
    return ctx.ast.nodes.items(.end_offset)[@intFromEnum(n)];
}

fn getNodeStart(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ctx.ast.node_start_overrides.get(ni)) |ov| return ov;

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
        .parenthesized_expr => return getNodeStart(ctx, d.unary),
        else => {},
    }

    const main_tok = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
}

fn getRawNodeStart(ctx: *TransformContext, node: NodeIndex) u32 {
    if (node == .none) return 0;
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .sequence_expr => {
            const d = ctx.nodeData(node);
            const eidx = @intFromEnum(d.extra);
            if (eidx + 1 >= ctx.ast.extra_data.items.len) return getNodeStart(ctx, node);
            const range_start = ctx.ast.extra_data.items[eidx];
            const range_end = ctx.ast.extra_data.items[eidx + 1];
            if (range_end <= range_start) return getNodeStart(ctx, node);
            const first_item: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_start]);
            return getRawNodeStart(ctx, first_item);
        },
        .parenthesized_expr => {
            const ni = @intFromEnum(node);
            const main_tok = ctx.ast.nodes.items(.main_token)[ni];
            return ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
        },
        .ts_as_expression, .ts_satisfies_expression => {
            const d = ctx.nodeData(node);
            return getRawNodeStart(ctx, d.binary.lhs);
        },
        .ts_non_null_expression => {
            const d = ctx.nodeData(node);
            return getRawNodeStart(ctx, d.unary);
        },
        else => return getNodeStart(ctx, node),
    }
}

fn getRawNodeEnd(ctx: *TransformContext, node: NodeIndex) u32 {
    if (node == .none) return 0;
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .sequence_expr => {
            const d = ctx.nodeData(node);
            const eidx = @intFromEnum(d.extra);
            if (eidx + 1 >= ctx.ast.extra_data.items.len) return getNodeEnd(ctx, node);
            const range_start = ctx.ast.extra_data.items[eidx];
            const range_end = ctx.ast.extra_data.items[eidx + 1];
            if (range_end <= range_start) return getNodeEnd(ctx, node);
            const last_item: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_end - 1]);
            return getRawNodeEnd(ctx, last_item);
        },
        .parenthesized_expr => {
            const ni = @intFromEnum(node);
            return ctx.ast.nodes.items(.end_offset)[ni];
        },
        .ts_as_expression, .ts_satisfies_expression, .ts_non_null_expression => {
            const ni = @intFromEnum(node);
            return ctx.ast.nodes.items(.end_offset)[ni];
        },
        else => return getNodeEnd(ctx, node),
    }
}
