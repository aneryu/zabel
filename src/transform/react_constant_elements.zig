const std = @import("std");
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub fn resetState() void {}

pub fn createPass() Pass {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.declarator));
    return .{
        .name = "react_constant_elements",
        .node_filter = filter,
        .exit = exitNode,
        .priority = 204,
    };
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (ctx.nodeTag(idx) != .declarator) return .continue_traversal;

    const data = ctx.nodeData(idx);
    const lhs = data.binary.lhs;
    const rhs = data.binary.rhs;
    if (rhs == .none) return .continue_traversal;

    const rhs_tag = ctx.nodeTag(rhs);
    if (rhs_tag != .jsx_element and rhs_tag != .jsx_fragment) return .continue_traversal;

    const rhs_source = normalizeJsxIndent(ctx, getNodeSource(ctx, rhs)) catch return .continue_traversal;
    if (!isConstantJsxSource(rhs_source)) return .continue_traversal;

    const lhs_source = getNodeSource(ctx, lhs);
    const temp_name = "_div";
    const replacement = std.fmt.allocPrint(
        ctx.allocator,
        "{s} = {s} || ({s} = {s})",
        .{ lhs_source, temp_name, temp_name, rhs_source },
    ) catch return .continue_traversal;
    ctx.putReplacementSource(idx, replacement) catch return .continue_traversal;
    ensureProgramPrefix(ctx, temp_name);
    return .skip_children;
}

fn isConstantJsxSource(source: []const u8) bool {
    return std.mem.indexOfScalar(u8, source, '{') == null;
}

fn ensureProgramPrefix(ctx: *TransformContext, temp_name: []const u8) void {
    const line = std.fmt.allocPrint(ctx.allocator, "var {s};\n", .{temp_name}) catch return;
    if (ctx.ast.block_prefix_source.get(0)) |existing| {
        if (std.mem.indexOf(u8, existing, line) != null) return;
        const combined = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ existing, line }) catch return;
        ctx.ast.block_prefix_source.put(ctx.allocator, 0, combined) catch {};
        return;
    }
    ctx.ast.block_prefix_source.put(ctx.allocator, 0, line) catch {};
}

fn normalizeJsxIndent(ctx: *TransformContext, source: []const u8) ![]const u8 {
    return ctx.allocator.dupe(u8, source);
}

fn getNodeSource(ctx: *TransformContext, idx: NodeIndex) []const u8 {
    if (idx == .none) return "";
    const ni = @intFromEnum(idx);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;

    const start = nodeStartOffset(ctx, idx);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return buildEffectiveSource(ctx, start, end);
}

fn nodeStartOffset(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    return ctx.ast.node_start_overrides.get(ni) orelse ctx.ast.tokens.items(.start)[@intFromEnum(ctx.mainToken(node))];
}

fn nodeStartOffsetRaw(ctx: *TransformContext, ni: usize) u32 {
    return ctx.ast.node_start_overrides.get(@intCast(ni)) orelse ctx.ast.tokens.items(.start)[@intFromEnum(ctx.ast.nodes.items(.main_token)[ni])];
}

fn buildEffectiveSource(ctx: *TransformContext, start_off: u32, end_off: u32) []const u8 {
    if (start_off >= end_off or end_off > ctx.ast.source.len) return "";
    if (ctx.ast.replacement_source.count() == 0) return ctx.ast.source[start_off..end_off];

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: u32 = start_off;
    var found_any = false;
    const ordered = ctx.orderedReplacements() catch return ctx.ast.source[start_off..end_off];
    const range_start = ctx.replacementLowerBound(start_off) catch return ctx.ast.source[start_off..end_off];
    for (ordered[range_start..]) |replacement| {
        if (replacement.start >= end_off) break;
        if (replacement.node_index >= ctx.ast.nodes.items(.tag).len) continue;

        const node_start = nodeStartOffsetRaw(ctx, replacement.node_index);
        const node_end = replacement.end;
        if (node_start < start_off or node_end > end_off) continue;
        if (node_start == start_off and node_end == end_off) continue;
        if (node_start < pos) continue;

        if (node_start > pos) {
            buf.appendSlice(ctx.allocator, ctx.ast.source[pos..node_start]) catch return ctx.ast.source[start_off..end_off];
        }
        buf.appendSlice(ctx.allocator, replacement.text) catch return ctx.ast.source[start_off..end_off];
        pos = node_end;
        found_any = true;
    }
    if (!found_any) return ctx.ast.source[start_off..end_off];
    if (pos < end_off) {
        buf.appendSlice(ctx.allocator, ctx.ast.source[pos..end_off]) catch return ctx.ast.source[start_off..end_off];
    }
    return buf.items;
}
