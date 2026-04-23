const std = @import("std");
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const lowering = @import("classes_lowering.zig");
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub const Config = struct {
    legacy_decorators: bool = false,
};

var g_config: Config = .{};

pub fn resetState() void {
    g_config = .{};
}

pub fn createPass(config: Config) Pass {
    g_config = config;

    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.class_declaration));
    filter.set(@intFromEnum(Node.Tag.class_expr));

    return .{
        .name = "private_methods",
        .node_filter = filter,
        .exit = exitNode,
        .priority = 18,
    };
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const rendered = lowering.lowerClass(ctx, idx, .{
        .mode = .preserve_class_surface,
        .private_methods = true,
        .legacy_decorators = g_config.legacy_decorators,
    }) orelse return .continue_traversal;

    if (rendered.prelude.len != 0) {
        const target = @intFromEnum(lowering.findPreludeTarget(ctx, idx));
        if (ctx.ast.block_prefix_source.get(target)) |existing| {
            const combined = std.fmt.allocPrint(ctx.allocator, "{s}{s}\n", .{ existing, rendered.prelude }) catch existing;
            ctx.ast.block_prefix_source.put(ctx.allocator, target, combined) catch {};
        } else {
            const prelude = std.fmt.allocPrint(ctx.allocator, "{s}\n", .{rendered.prelude}) catch rendered.prelude;
            ctx.ast.block_prefix_source.put(ctx.allocator, target, prelude) catch {};
        }
    }

    ctx.putReplacementSource(idx, rendered.replacement) catch {};
    if (std.mem.indexOfScalar(u8, rendered.replacement, '\n') != null) {
        ctx.markReplacementNeedsReindent(idx) catch {};
    }
    return .skip_children;
}
