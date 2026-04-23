const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub fn createPass() Pass {
    var filter = visitor.NodeTagBitSet.initEmpty();

    filter.set(@intFromEnum(Node.Tag.flow_type_alias));
    filter.set(@intFromEnum(Node.Tag.flow_declare_type_alias));
    filter.set(@intFromEnum(Node.Tag.flow_opaque_type));
    filter.set(@intFromEnum(Node.Tag.flow_interface_declaration));
    filter.set(@intFromEnum(Node.Tag.flow_declare_class));
    filter.set(@intFromEnum(Node.Tag.flow_declare_function));
    filter.set(@intFromEnum(Node.Tag.flow_declare_variable));
    filter.set(@intFromEnum(Node.Tag.flow_declare_module));
    filter.set(@intFromEnum(Node.Tag.flow_declare_module_exports));
    filter.set(@intFromEnum(Node.Tag.flow_declare_export_declaration));
    filter.set(@intFromEnum(Node.Tag.flow_declare_export_all_declaration));
    filter.set(@intFromEnum(Node.Tag.flow_declare_interface));
    filter.set(@intFromEnum(Node.Tag.flow_declare_opaque_type));
    filter.set(@intFromEnum(Node.Tag.flow_type_cast_expression));

    return .{
        .name = "flow_strip",
        .node_filter = filter,
        .enter = enterNode,
        .priority = 10,
    };
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (ctx.nodeTag(idx) == .flow_type_cast_expression) {
        const extra_idx = @intFromEnum(ctx.nodeData(idx).extra);
        if (extra_idx < ctx.ast.extra_data.items.len) {
            var expr: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            while (expr != .none and ctx.nodeTag(expr) == .parenthesized_expr) {
                expr = ctx.nodeData(expr).unary;
            }
            const replacement = getNodeSource(ctx, expr);
            const target = if (findParentOf(ctx, idx)) |parent|
                if (ctx.nodeTag(parent) == .parenthesized_expr) parent else idx
            else
                idx;
            ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(target), replacement) catch {};
        }
        return .continue_traversal;
    }
    return .remove_node;
}

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
    const tag = ctx.ast.nodes.items(.tag)[ni];
    const data = ctx.ast.nodes.items(.data)[ni];

    return switch (tag) {
        .call_expr, .optional_call_expr => blk: {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx < ctx.ast.extra_data.items.len) {
                const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
                break :blk getNodeStart(ctx, callee);
            }
            break :blk ctx.ast.tokens.items(.start)[@intFromEnum(ctx.ast.nodes.items(.main_token)[ni])];
        },
        .member_expr,
        .computed_member_expr,
        .optional_chain_expr,
        .optional_computed_member_expr,
        .binary_expr,
        .logical_expr,
        .assignment_expr,
        .conditional_expr,
        .ts_as_expression,
        .ts_satisfies_expression,
        => getNodeStart(ctx, data.binary.lhs),
        .ts_non_null_expression => getNodeStart(ctx, data.unary),
        else => ctx.ast.tokens.items(.start)[@intFromEnum(ctx.ast.nodes.items(.main_token)[ni])],
    };
}

fn findParentOf(ctx: *TransformContext, target: NodeIndex) ?NodeIndex {
    const target_i = @intFromEnum(target);
    const tags = ctx.ast.nodes.items(.tag);
    const data = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        switch (tag) {
            .member_expr, .optional_chain_expr => {
                if (@intFromEnum(data[ni].binary.lhs) == target_i) return @enumFromInt(ni);
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
                if (@intFromEnum(data[ni].binary.lhs) == target_i) return @enumFromInt(ni);
                if (@intFromEnum(data[ni].binary.rhs) == target_i) return @enumFromInt(ni);
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
            .rest_element,
            => {
                if (@intFromEnum(data[ni].unary) == target_i) return @enumFromInt(ni);
            },
            else => {},
        }
    }

    return null;
}
