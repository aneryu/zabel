const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const scope_mod = @import("../scope.zig");
const lowering = @import("modules_lowering.zig");
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub fn resetState() void {}

pub fn createPass() Pass {
    var exit_filter = visitor.NodeTagBitSet.initEmpty();
    exit_filter.set(@intFromEnum(Node.Tag.program));
    return .{
        .name = "modules_amd",
        .node_filter = visitor.NodeTagBitSet.initEmpty(),
        .exit_filter = exit_filter,
        .exit = exitNode,
        .priority = 250,
    };
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (ctx.scope) |_| {
        const rendered = lowering.renderAMDProgram(ctx, idx) orelse return .skip_children;
        ctx.putReplacementSource(idx, rendered) catch {};
        return .skip_children;
    }

    var local_scope = scope_mod.analyzeWithOptions(ctx.ast, ctx.allocator, .{}) catch return .skip_children;
    defer local_scope.deinit();

    var local_ctx = ctx.*;
    local_ctx.scope = &local_scope;

    const rendered = lowering.renderAMDProgram(&local_ctx, idx) orelse return .skip_children;
    ctx.putReplacementSource(idx, rendered) catch {};
    return .skip_children;
}
