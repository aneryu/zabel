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

/// Configuration for the logical-assignment-operators transform.
pub const Config = struct {
    /// When true, skip ??= handling (nullish-coalescing pass will handle it).
    skip_nullish: bool = false,
    /// When true, preserve direct member/computed nullish forms for a follow-up
    /// nullish-coalescing pass instead of materializing the object upfront.
    nullish_followup: bool = false,
};

var g_config: Config = .{};

/// Set of temp names already allocated (to avoid duplicates within a file).
var g_allocated_names: std.StringHashMapUnmanaged(void) = .empty;

/// Temp names grouped by their enclosing body node (for block_prefix_source).
pub var g_body_temps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)) = .empty;

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.assignment_expr));
    return .{
        .name = "logical_assignment",
        .node_filter = filter,
        .exit = exitNode,
        .priority = 25, // Run before nullish-coalescing (30) so the ??= → ?? chain works
    };
}

pub fn resetState() void {
    g_allocated_names = .{};
    g_body_temps = .{};
}

/// Flush all accumulated temp var declarations into block_prefix_source entries.
pub fn flushTempDeclarations(ctx: *TransformContext) void {
    var iter = g_body_temps.iterator();
    while (iter.next()) |entry| {
        const body_idx = entry.key_ptr.*;
        const names = entry.value_ptr.items;
        if (names.len == 0) continue;

        var decl_buf: std.ArrayListUnmanaged(u8) = .empty;

        // Prepend to any existing block prefix
        if (ctx.ast.block_prefix_source.get(body_idx)) |existing| {
            decl_buf.appendSlice(ctx.allocator, existing) catch continue;
        }

        decl_buf.appendSlice(ctx.allocator, "var ") catch continue;
        for (names, 0..) |name, j| {
            if (j > 0) decl_buf.appendSlice(ctx.allocator, ", ") catch continue;
            decl_buf.appendSlice(ctx.allocator, name) catch continue;
        }
        decl_buf.appendSlice(ctx.allocator, ";") catch continue;

        ctx.ast.block_prefix_source.put(ctx.allocator, body_idx, decl_buf.items) catch continue;
    }
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    if (tag == .assignment_expr) {
        handleLogicalAssignment(idx, ctx);
    }
    return .continue_traversal;
}

// ── Main transform ──────────────────────────────────────────────────

fn handleLogicalAssignment(idx: NodeIndex, ctx: *TransformContext) void {
    const main_tok = ctx.mainToken(idx);
    const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(main_tok)];

    // Skip ??= if nullish-coalescing pass will handle it
    if (tok_tag == .question_question_equal and g_config.skip_nullish) return;

    const op_str: []const u8 = switch (tok_tag) {
        .question_question_equal => "??",
        .pipe_pipe_equal => "||",
        .ampersand_ampersand_equal => "&&",
        else => return,
    };

    const data = ctx.nodeData(idx);
    const lhs = data.binary.lhs;
    const rhs = data.binary.rhs;

    const rhs_src = getNodeSource(ctx, rhs);
    if (rhs_src.len == 0) return;

    const body_idx = findEnclosingBody(ctx, idx);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const is_nullish = tok_tag == .question_question_equal;

    const lhs_tag = ctx.nodeTag(lhs);

    switch (lhs_tag) {
        .identifier => {
            // a OP= b → a OP (a = b)
            const lhs_src = getNodeSource(ctx, lhs);
            if (lhs_src.len == 0) return;
            if (is_nullish and g_config.nullish_followup) {
                appendNullishAssignExpr(&buf, ctx, lhs_src, lhs_src, lhs_src, rhs_src);
            } else {
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " ") catch return;
                buf.appendSlice(ctx.allocator, op_str) catch return;
                buf.appendSlice(ctx.allocator, " (") catch return;
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
                buf.appendSlice(ctx.allocator, ")") catch return;
            }
        },

        .member_expr => {
            const mem_data = ctx.nodeData(lhs);
            const obj_node = mem_data.binary.lhs;
            const prop_tok_raw = @intFromEnum(mem_data.binary.rhs);
            const prop_name = ctx.ast.tokenSlice(@enumFromInt(prop_tok_raw));
            if (is_nullish and g_config.nullish_followup) {
                const obj_src = getNodeSource(ctx, obj_node);
                if (obj_src.len == 0) return;
                if (isSimpleRef(ctx, obj_node)) {
                    const obj_prefix = deriveTempPrefix(ctx, obj_node);
                    const value_temp = allocUniqueName(ctx, std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_prefix, prop_name }) catch return, body_idx);
                    if (value_temp.len == 0) return;
                    const access_src = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ obj_src, prop_name }) catch return;
                    const checked_src = std.fmt.allocPrint(ctx.allocator, "({s} = {s})", .{ value_temp, access_src }) catch return;
                    appendNullishAssignExpr(&buf, ctx, checked_src, value_temp, access_src, rhs_src);
                } else {
                    const obj_temp = allocTempName(ctx, obj_node, body_idx);
                    if (obj_temp.len == 0) return;
                    const value_temp = allocUniqueName(ctx, std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ trimTempSigil(obj_temp), prop_name }) catch return, body_idx);
                    if (value_temp.len == 0) return;
                    const checked_src = std.fmt.allocPrint(ctx.allocator, "({s} = ({s} = {s}).{s})", .{ value_temp, obj_temp, obj_src, prop_name }) catch return;
                    const assign_target = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ obj_temp, prop_name }) catch return;
                    appendNullishAssignExpr(&buf, ctx, checked_src, value_temp, assign_target, rhs_src);
                }
            } else if (isSimpleRef(ctx, obj_node) and !is_nullish) {
                // Simple object with ||= or &&=: obj.a OP (obj.a = rhs)
                const obj_src = getNodeSource(ctx, obj_node);
                buf.appendSlice(ctx.allocator, obj_src) catch return;
                buf.appendSlice(ctx.allocator, ".") catch return;
                buf.appendSlice(ctx.allocator, prop_name) catch return;
                buf.appendSlice(ctx.allocator, " ") catch return;
                buf.appendSlice(ctx.allocator, op_str) catch return;
                buf.appendSlice(ctx.allocator, " (") catch return;
                buf.appendSlice(ctx.allocator, obj_src) catch return;
                buf.appendSlice(ctx.allocator, ".") catch return;
                buf.appendSlice(ctx.allocator, prop_name) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
                buf.appendSlice(ctx.allocator, ")") catch return;
            } else {
                // Complex or ??=: (_o = expr).a OP (_o.a = rhs)
                const obj_src = getNodeSource(ctx, obj_node);
                const obj_temp = allocTempName(ctx, obj_node, body_idx);
                if (obj_temp.len == 0) return;

                buf.appendSlice(ctx.allocator, "(") catch return;
                buf.appendSlice(ctx.allocator, obj_temp) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, obj_src) catch return;
                buf.appendSlice(ctx.allocator, ").") catch return;
                buf.appendSlice(ctx.allocator, prop_name) catch return;
                buf.appendSlice(ctx.allocator, " ") catch return;
                buf.appendSlice(ctx.allocator, op_str) catch return;
                buf.appendSlice(ctx.allocator, " (") catch return;
                buf.appendSlice(ctx.allocator, obj_temp) catch return;
                buf.appendSlice(ctx.allocator, ".") catch return;
                buf.appendSlice(ctx.allocator, prop_name) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
                buf.appendSlice(ctx.allocator, ")") catch return;
            }
        },

        .computed_member_expr => {
            const mem_data = ctx.nodeData(lhs);
            const obj_node = mem_data.binary.lhs;
            const key_node = mem_data.binary.rhs;
            const obj_src = getNodeSource(ctx, obj_node);
            const key_src = getNodeSource(ctx, key_node);
            // For ??=, always create key temps. For ||=/&&=, only if key has side effects.
            const key_is_simple = !is_nullish and (isSimpleRef(ctx, key_node) or isLiteral(ctx, key_node));

            if (is_nullish and g_config.nullish_followup) {
                if (isSimpleRef(ctx, obj_node)) {
                    const key_temp = allocTempName(ctx, key_node, body_idx);
                    if (key_temp.len == 0) return;
                    const value_temp = allocUniqueName(ctx, std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ deriveTempPrefix(ctx, obj_node), key_temp }) catch return, body_idx);
                    if (value_temp.len == 0) return;
                    const checked_src = std.fmt.allocPrint(ctx.allocator, "({s} = {s}[{s} = {s}])", .{ value_temp, obj_src, key_temp, key_src }) catch return;
                    const assign_target = std.fmt.allocPrint(ctx.allocator, "{s}[{s}]", .{ obj_src, key_temp }) catch return;
                    appendNullishAssignExpr(&buf, ctx, checked_src, value_temp, assign_target, rhs_src);
                } else {
                    const obj_temp = allocTempName(ctx, obj_node, body_idx);
                    if (obj_temp.len == 0) return;
                    const key_temp = allocTempName(ctx, key_node, body_idx);
                    if (key_temp.len == 0) return;
                    const value_temp = allocUniqueName(ctx, std.fmt.allocPrint(ctx.allocator, "{s}$_key", .{trimTempSigil(obj_temp)}) catch return, body_idx);
                    if (value_temp.len == 0) return;
                    const checked_src = std.fmt.allocPrint(ctx.allocator, "({s} = ({s} = {s})[{s} = {s}])", .{ value_temp, obj_temp, obj_src, key_temp, key_src }) catch return;
                    const assign_target = std.fmt.allocPrint(ctx.allocator, "{s}[{s}]", .{ obj_temp, key_temp }) catch return;
                    appendNullishAssignExpr(&buf, ctx, checked_src, value_temp, assign_target, rhs_src);
                }
            } else if (isSimpleRef(ctx, obj_node) and !is_nullish) {
                if (key_is_simple) {
                    // obj[k] OP (obj[k] = rhs)
                    buf.appendSlice(ctx.allocator, obj_src) catch return;
                    buf.appendSlice(ctx.allocator, "[") catch return;
                    buf.appendSlice(ctx.allocator, key_src) catch return;
                    buf.appendSlice(ctx.allocator, "] ") catch return;
                    buf.appendSlice(ctx.allocator, op_str) catch return;
                    buf.appendSlice(ctx.allocator, " (") catch return;
                    buf.appendSlice(ctx.allocator, obj_src) catch return;
                    buf.appendSlice(ctx.allocator, "[") catch return;
                    buf.appendSlice(ctx.allocator, key_src) catch return;
                    buf.appendSlice(ctx.allocator, "] = ") catch return;
                    buf.appendSlice(ctx.allocator, rhs_src) catch return;
                    buf.appendSlice(ctx.allocator, ")") catch return;
                } else {
                    // obj[_k = k] OP (obj[_k] = rhs)
                    const key_temp = allocTempName(ctx, key_node, body_idx);
                    if (key_temp.len == 0) return;
                    buf.appendSlice(ctx.allocator, obj_src) catch return;
                    buf.appendSlice(ctx.allocator, "[") catch return;
                    buf.appendSlice(ctx.allocator, key_temp) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, key_src) catch return;
                    buf.appendSlice(ctx.allocator, "] ") catch return;
                    buf.appendSlice(ctx.allocator, op_str) catch return;
                    buf.appendSlice(ctx.allocator, " (") catch return;
                    buf.appendSlice(ctx.allocator, obj_src) catch return;
                    buf.appendSlice(ctx.allocator, "[") catch return;
                    buf.appendSlice(ctx.allocator, key_temp) catch return;
                    buf.appendSlice(ctx.allocator, "] = ") catch return;
                    buf.appendSlice(ctx.allocator, rhs_src) catch return;
                    buf.appendSlice(ctx.allocator, ")") catch return;
                }
            } else {
                const obj_temp = allocTempName(ctx, obj_node, body_idx);
                if (obj_temp.len == 0) return;

                if (key_is_simple) {
                    // (_o = obj)[k] OP (_o[k] = rhs)
                    buf.appendSlice(ctx.allocator, "(") catch return;
                    buf.appendSlice(ctx.allocator, obj_temp) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, obj_src) catch return;
                    buf.appendSlice(ctx.allocator, ")[") catch return;
                    buf.appendSlice(ctx.allocator, key_src) catch return;
                    buf.appendSlice(ctx.allocator, "] ") catch return;
                    buf.appendSlice(ctx.allocator, op_str) catch return;
                    buf.appendSlice(ctx.allocator, " (") catch return;
                    buf.appendSlice(ctx.allocator, obj_temp) catch return;
                    buf.appendSlice(ctx.allocator, "[") catch return;
                    buf.appendSlice(ctx.allocator, key_src) catch return;
                    buf.appendSlice(ctx.allocator, "] = ") catch return;
                    buf.appendSlice(ctx.allocator, rhs_src) catch return;
                    buf.appendSlice(ctx.allocator, ")") catch return;
                } else {
                    const key_temp = allocTempName(ctx, key_node, body_idx);
                    if (key_temp.len == 0) return;
                    // (_o = obj)[_k = k] OP (_o[_k] = rhs)
                    buf.appendSlice(ctx.allocator, "(") catch return;
                    buf.appendSlice(ctx.allocator, obj_temp) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, obj_src) catch return;
                    buf.appendSlice(ctx.allocator, ")[") catch return;
                    buf.appendSlice(ctx.allocator, key_temp) catch return;
                    buf.appendSlice(ctx.allocator, " = ") catch return;
                    buf.appendSlice(ctx.allocator, key_src) catch return;
                    buf.appendSlice(ctx.allocator, "] ") catch return;
                    buf.appendSlice(ctx.allocator, op_str) catch return;
                    buf.appendSlice(ctx.allocator, " (") catch return;
                    buf.appendSlice(ctx.allocator, obj_temp) catch return;
                    buf.appendSlice(ctx.allocator, "[") catch return;
                    buf.appendSlice(ctx.allocator, key_temp) catch return;
                    buf.appendSlice(ctx.allocator, "] = ") catch return;
                    buf.appendSlice(ctx.allocator, rhs_src) catch return;
                    buf.appendSlice(ctx.allocator, ")") catch return;
                }
            }
        },

        else => return,
    }

    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), buf.items) catch return;
}

fn appendNullishAssignExpr(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    checked_src: []const u8,
    value_src: []const u8,
    assign_target_src: []const u8,
    rhs_src: []const u8,
) void {
    buf.appendSlice(ctx.allocator, checked_src) catch return;
    buf.appendSlice(ctx.allocator, " !== null && ") catch return;
    buf.appendSlice(ctx.allocator, value_src) catch return;
    buf.appendSlice(ctx.allocator, " !== void 0 ? ") catch return;
    buf.appendSlice(ctx.allocator, value_src) catch return;
    buf.appendSlice(ctx.allocator, " : ") catch return;
    buf.appendSlice(ctx.allocator, assign_target_src) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, rhs_src) catch return;
}

// ── Helpers ─────────────────────────────────────────────────────────

fn isSimpleRef(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    return switch (tag) {
        .identifier, .this_expr => true,
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            return isSimpleRef(ctx, d.unary);
        },
        else => false,
    };
}

fn isLiteral(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    return switch (tag) {
        .string_literal, .numeric_literal, .boolean_literal, .null_literal => true,
        else => false,
    };
}

fn trimTempSigil(name: []const u8) []const u8 {
    if (name.len > 0 and name[0] == '_') return name[1..];
    return name;
}

fn findEnclosingBody(ctx: *TransformContext, node: NodeIndex) u32 {
    if (ctx.scope) |scope_result| {
        if (scope_mod.getScopeForNode(scope_result, node)) |scope_idx| {
            var current: ?scope_mod.ScopeIndex = scope_idx;
            while (current) |si| {
                const scope = scope_result.scopes[@intFromEnum(si)];
                switch (scope.kind) {
                    .function => {
                        if (getFunctionBody(ctx, scope.node)) |body| {
                            return @intFromEnum(body);
                        }
                        return 0;
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

fn deriveTempPrefix(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .identifier => return ctx.tokenSlice(ctx.mainToken(node)),
        .this_expr => return "this",
        .string_literal => {
            const tok_slice = ctx.tokenSlice(ctx.mainToken(node));
            if (tok_slice.len >= 2) return tok_slice[1 .. tok_slice.len - 1];
            return tok_slice;
        },
        .update_expr => {
            // ++key → "key"
            const d = ctx.nodeData(node);
            return deriveTempPrefix(ctx, d.unary);
        },
        .member_expr => {
            const d = ctx.nodeData(node);
            const obj_prefix = deriveTempPrefix(ctx, d.binary.lhs);
            const prop_tok_raw = @intFromEnum(d.binary.rhs);
            const prop_name = ctx.ast.tokenSlice(@enumFromInt(prop_tok_raw));
            return std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_prefix, prop_name }) catch "ref";
        },
        .computed_member_expr => {
            const d = ctx.nodeData(node);
            const obj_prefix = deriveTempPrefix(ctx, d.binary.lhs);
            const key_prefix = deriveKeyPrefix(ctx, d.binary.rhs);
            return std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_prefix, key_prefix }) catch "ref";
        },
        .call_expr => {
            const d = ctx.nodeData(node);
            const extra_idx = @intFromEnum(d.extra);
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            return deriveTempPrefix(ctx, callee);
        },
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            return deriveTempPrefix(ctx, d.unary);
        },
        else => return "ref",
    }
}

fn allocTempName(ctx: *TransformContext, node: NodeIndex, body_idx: u32) []const u8 {
    const prefix = deriveTempPrefix(ctx, node);
    return allocUniqueName(ctx, prefix, body_idx);
}

fn deriveKeyPrefix(ctx: *TransformContext, key_node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(key_node);
    switch (tag) {
        .identifier => return ctx.tokenSlice(ctx.mainToken(key_node)),
        .string_literal => {
            const tok_slice = ctx.tokenSlice(ctx.mainToken(key_node));
            if (tok_slice.len >= 2) {
                return tok_slice[1 .. tok_slice.len - 1];
            }
            return tok_slice;
        },
        else => return "ref",
    }
}

fn allocUniqueName(ctx: *TransformContext, prefix: []const u8, body_idx: u32) []const u8 {
    const first = std.fmt.allocPrint(ctx.allocator, "_{s}", .{prefix}) catch return "";
    if (!g_allocated_names.contains(first)) {
        g_allocated_names.put(ctx.allocator, first, {}) catch {};
        registerTempForBody(ctx, first, body_idx);
        return first;
    }

    var counter: u32 = 2;
    while (counter < 10000) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ prefix, counter }) catch return "";
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
