const std = @import("std");
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub const Config = struct {};

const FunctionKind = enum {
    generator,
    async_generator,
};

const BodyPattern = union(enum) {
    empty,
    return_expr: []const u8,
    throw_expr: []const u8,
};

var g_machine_counter: u32 = 0;

pub fn createPass(_: Config) Pass {
    var exit_filter = visitor.NodeTagBitSet.initEmpty();
    exit_filter.set(@intFromEnum(Node.Tag.function_expr));
    return .{
        .name = "regenerator",
        .node_filter = visitor.NodeTagBitSet.initEmpty(),
        .exit_filter = exit_filter,
        .exit = exitNode,
        .priority = 45,
    };
}

pub fn resetState() void {
    g_machine_counter = 0;
}

pub fn canLowerSimpleGeneratorFunction(ctx: *TransformContext, func_node: NodeIndex) bool {
    return analyzeSimpleGeneratorBody(ctx, func_node) != null;
}

pub fn renderSimpleGeneratorWrapper(ctx: *TransformContext, func_node: NodeIndex) ?[]const u8 {
    return renderSimpleGeneratorWrapperWithIndent(ctx, func_node, "    ");
}

pub fn renderSimpleGeneratorWrapperWithIndent(
    ctx: *TransformContext,
    func_node: NodeIndex,
    base_indent: []const u8,
) ?[]const u8 {
    const kind = getFunctionKind(ctx, func_node) orelse return null;
    const pattern = analyzeSimpleGeneratorBody(ctx, func_node) orelse return null;
    return renderSimpleGeneratorWrapperFromPattern(ctx, kind, pattern, base_indent);
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (ctx.nodeTag(idx) != .function_expr) return .continue_traversal;
    if (!canLowerSimpleGeneratorFunction(ctx, idx)) return .continue_traversal;

    const wrapper = renderSimpleGeneratorWrapper(ctx, idx) orelse return .continue_traversal;
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), wrapper) catch return .continue_traversal;
    ctx.ast.replacement_needs_reindent.put(ctx.allocator, @intFromEnum(idx), {}) catch return .continue_traversal;
    return .continue_traversal;
}

fn getFunctionKind(ctx: *TransformContext, func_node: NodeIndex) ?FunctionKind {
    return switch (ctx.nodeTag(func_node)) {
        .generator_declaration => .generator,
        .async_generator_declaration => .async_generator,
        .function_expr => blk: {
            const extra_idx = @intFromEnum(ctx.nodeData(func_node).extra);
            if (extra_idx + 4 >= ctx.ast.extra_data.items.len) break :blk null;
            const flags = ctx.ast.extra_data.items[extra_idx + 4];
            const is_generator = (flags & 1) != 0;
            const is_async = (flags & 2) != 0;
            if (!is_generator) break :blk null;
            break :blk if (is_async) .async_generator else .generator;
        },
        else => null,
    };
}

fn analyzeSimpleGeneratorBody(ctx: *TransformContext, func_node: NodeIndex) ?BodyPattern {
    const extra_idx = @intFromEnum(ctx.nodeData(func_node).extra);
    if (extra_idx + 3 >= ctx.ast.extra_data.items.len) return null;
    const params_start = ctx.ast.extra_data.items[extra_idx + 1];
    const params_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (params_start != params_end) return null;

    const body_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
    if (body_node == .none or ctx.nodeTag(body_node) != .block_statement) return null;

    const body_extra = @intFromEnum(ctx.nodeData(body_node).extra);
    if (body_extra + 1 >= ctx.ast.extra_data.items.len) return null;
    const stmts_start = ctx.ast.extra_data.items[body_extra];
    const stmts_end = ctx.ast.extra_data.items[body_extra + 1];

    var stmt_count: u32 = 0;
    var stmt_node: NodeIndex = .none;
    for (ctx.ast.extra_data.items[stmts_start..stmts_end]) |stmt_raw| {
        if (stmt_raw >= ctx.ast.nodes.items(.tag).len) continue;
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (ctx.nodeTag(stmt) == .removed or ctx.nodeTag(stmt) == .empty_statement) continue;
        stmt_count += 1;
        stmt_node = stmt;
    }

    if (stmt_count == 0) return .empty;
    if (stmt_count != 1 or stmt_node == .none) return null;

    return switch (ctx.nodeTag(stmt_node)) {
        .return_statement => blk: {
            const expr = ctx.nodeData(stmt_node).unary;
            if (expr == .none) break :blk .empty;
            break :blk BodyPattern{ .return_expr = getNodeSource(ctx, expr) };
        },
        .throw_statement => blk: {
            const expr = ctx.nodeData(stmt_node).unary;
            if (expr == .none) return null;
            break :blk BodyPattern{ .throw_expr = getNodeSource(ctx, expr) };
        },
        else => null,
    };
}

fn renderSimpleGeneratorWrapperFromPattern(
    ctx: *TransformContext,
    kind: FunctionKind,
    pattern: BodyPattern,
    base_indent: []const u8,
) ?[]const u8 {
    g_machine_counter += 1;
    const callee_name = if (g_machine_counter == 1)
        "_callee"
    else
        std.fmt.allocPrint(ctx.allocator, "_callee{d}", .{g_machine_counter}) catch return null;
    const context_name = if (g_machine_counter == 1)
        "_context"
    else
        std.fmt.allocPrint(ctx.allocator, "_context{d}", .{g_machine_counter}) catch return null;

    const return_indent = base_indent;
    const while_indent = std.fmt.allocPrint(ctx.allocator, "{s}  ", .{base_indent}) catch return null;
    const outer_close_indent = if (base_indent.len >= 2) base_indent[0 .. base_indent.len - 2] else "";
    const case_body = renderCaseBody(ctx, context_name, pattern, base_indent) orelse return null;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "/*#__PURE__*/babelHelpers.regenerator().m(function ") catch return null;
    buf.appendSlice(ctx.allocator, callee_name) catch return null;
    buf.appendSlice(ctx.allocator, "() {\n") catch return null;
    buf.appendSlice(ctx.allocator, return_indent) catch return null;
    switch (kind) {
        .generator => buf.appendSlice(ctx.allocator, "return babelHelpers.regenerator().w(function (") catch return null,
        .async_generator => buf.appendSlice(ctx.allocator, "return babelHelpers.regeneratorAsyncGen(function (") catch return null,
    }
    buf.appendSlice(ctx.allocator, context_name) catch return null;
    buf.appendSlice(ctx.allocator, ") {\n") catch return null;
    buf.appendSlice(ctx.allocator, while_indent) catch return null;
    buf.appendSlice(ctx.allocator, "while (1) switch (") catch return null;
    buf.appendSlice(ctx.allocator, context_name) catch return null;
    buf.appendSlice(ctx.allocator, ".n) {\n") catch return null;
    buf.appendSlice(ctx.allocator, case_body) catch return null;
    buf.appendSlice(ctx.allocator, while_indent) catch return null;
    buf.appendSlice(ctx.allocator, "}\n") catch return null;
    buf.appendSlice(ctx.allocator, base_indent) catch return null;
    buf.appendSlice(ctx.allocator, "}, ") catch return null;
    buf.appendSlice(ctx.allocator, callee_name) catch return null;
    if (kind == .async_generator) {
        buf.appendSlice(ctx.allocator, ", null, null, Promise") catch return null;
    }
    buf.appendSlice(ctx.allocator, ");\n") catch return null;
    buf.appendSlice(ctx.allocator, outer_close_indent) catch return null;
    buf.appendSlice(ctx.allocator, "})") catch return null;
    return buf.items;
}

fn renderCaseBody(
    ctx: *TransformContext,
    context_name: []const u8,
    pattern: BodyPattern,
    base_indent: []const u8,
) ?[]const u8 {
    const case_indent = std.fmt.allocPrint(ctx.allocator, "{s}    ", .{base_indent}) catch return null;
    const body_indent = std.fmt.allocPrint(ctx.allocator, "{s}      ", .{base_indent}) catch return null;
    return switch (pattern) {
        .empty => std.fmt.allocPrint(
            ctx.allocator,
            "{s}case 0:\n{s}return {s}.a(2);\n",
            .{ case_indent, body_indent, context_name },
        ) catch null,
        .return_expr => |expr| std.fmt.allocPrint(
            ctx.allocator,
            "{s}case 0:\n{s}return {s}.a(2, {s});\n",
            .{ case_indent, body_indent, context_name, expr },
        ) catch null,
        .throw_expr => |expr| std.fmt.allocPrint(
            ctx.allocator,
            "{s}case 0:\n{s}throw {s};\n{s}case 1:\n{s}return {s}.a(2);\n",
            .{ case_indent, body_indent, expr, case_indent, body_indent, context_name },
        ) catch null,
    };
}

fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;
    const start = ctx.ast.tokens.items(.start)[@intFromEnum(ctx.mainToken(node))];
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return ctx.ast.source[start..end];
}
