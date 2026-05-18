const std = @import("std");
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const lowering = @import("classes_lowering.zig");
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub const Config = struct {
    lower_runtime: bool = false,
    legacy_decorators: bool = false,
};

var g_config: Config = .{};

pub fn resetState() void {
    g_config = .{};
}

pub fn createPass(config: Config) Pass {
    g_config = config;

    var exit_filter = visitor.NodeTagBitSet.initEmpty();
    exit_filter.set(@intFromEnum(Node.Tag.class_declaration));
    exit_filter.set(@intFromEnum(Node.Tag.class_expr));

    return .{
        .name = "classes",
        .node_filter = visitor.NodeTagBitSet.initEmpty(),
        .exit_filter = exit_filter,
        .exit = exitNode,
        .priority = 19,
    };
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const rendered = lowering.lowerClass(ctx, idx, .{
        .mode = if (g_config.lower_runtime) .runtime_lowered else .preserve_class_surface,
        .legacy_decorators = g_config.legacy_decorators,
    }) orelse return .continue_traversal;

    if (rendered.prelude.len != 0) {
        const target = @intFromEnum(lowering.findPreludeTarget(ctx, idx));
        if (ctx.ast.block_prefix_source.get(target)) |existing| {
            const combined = mergePreludeWithExisting(ctx, existing, rendered.prelude);
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

fn mergePreludeWithExisting(ctx: *TransformContext, existing: []const u8, prelude: []const u8) []const u8 {
    if (existing.len == 0) return std.fmt.allocPrint(ctx.allocator, "{s}\n", .{prelude}) catch prelude;

    const trimmed = std.mem.trim(u8, existing, " \t\r\n");
    const prepend = !(std.mem.startsWith(u8, trimmed, "var ") or
        std.mem.startsWith(u8, trimmed, "let ") or
        std.mem.startsWith(u8, trimmed, "const ") or
        std.mem.startsWith(u8, trimmed, "function "));

    return if (prepend)
        std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ prelude, existing }) catch existing
    else
        std.fmt.allocPrint(ctx.allocator, "{s}{s}\n", .{ existing, prelude }) catch existing;
}
