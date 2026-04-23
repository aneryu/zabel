const std = @import("std");
const zb = @import("zig_babal");
const visitor = zb.Visitor;

fn transformClassPropertiesWithSnapshot(source: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var result = try zb.parseWithOptions(alloc, source, .{
        .source_type = .script,
        .language = .javascript,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();

    zb.ClassPropertiesTransform.resetState();
    try pipeline.addPass(createPrimeReplacementIndexPass());
    try pipeline.addPass(createReplaceStringLiteralPass());
    try pipeline.addPass(createReprimeReplacementIndexPass());
    try pipeline.addPass(zb.ClassPropertiesTransform.createPass(.{}));
    try pipeline.addPass(createProgramSnapshotPass());
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

fn createPrimeReplacementIndexPass() @TypeOf(zb.ClassPropertiesTransform.createPass(.{})) {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(zb.Node.Tag.program));
    return .{
        .name = "test_prime_replacement_index",
        .node_filter = filter,
        .enter = primeReplacementIndex,
        .priority = 1,
    };
}

fn primeReplacementIndex(_: zb.NodeIndex, ctx: *zb.TransformContext) visitor.VisitResult {
    _ = ctx.orderedReplacements() catch {};
    return .continue_traversal;
}

fn createReplaceStringLiteralPass() @TypeOf(zb.ClassPropertiesTransform.createPass(.{})) {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(zb.Node.Tag.string_literal));
    return .{
        .name = "test_replace_string_literal",
        .node_filter = filter,
        .exit = replaceStringLiteral,
        .priority = 2,
    };
}

fn createReprimeReplacementIndexPass() @TypeOf(zb.ClassPropertiesTransform.createPass(.{})) {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(zb.Node.Tag.class_body));
    return .{
        .name = "test_reprime_replacement_index",
        .node_filter = filter,
        .exit = reprimeReplacementIndex,
        .priority = 3,
    };
}

fn reprimeReplacementIndex(_: zb.NodeIndex, ctx: *zb.TransformContext) visitor.VisitResult {
    _ = ctx.orderedReplacements() catch {};
    return .continue_traversal;
}

fn replaceStringLiteral(idx: zb.NodeIndex, ctx: *zb.TransformContext) visitor.VisitResult {
    const text = ctx.tokenSlice(ctx.mainToken(idx));
    if (std.mem.eql(u8, text, "\"hello\"")) {
        ctx.putReplacementSource(idx, "\"world\"") catch {};
    }
    return .continue_traversal;
}

fn createProgramSnapshotPass() @TypeOf(zb.ClassPropertiesTransform.createPass(.{})) {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(zb.Node.Tag.program));
    return .{
        .name = "test_program_snapshot",
        .node_filter = filter,
        .exit = snapshotProgram,
        .priority = 255,
    };
}

fn snapshotProgram(idx: zb.NodeIndex, ctx: *zb.TransformContext) visitor.VisitResult {
    const rebuilt = rebuildRangeFromOrderedReplacements(ctx, 0, @intCast(ctx.ast.source.len));
    ctx.putReplacementSource(idx, rebuilt) catch {};
    return .continue_traversal;
}

fn rebuildRangeFromOrderedReplacements(ctx: *zb.TransformContext, start_off: u32, end_off: u32) []const u8 {
    if (start_off >= end_off or end_off > ctx.ast.source.len) return "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: u32 = start_off;
    var found_any = false;
    const ordered = ctx.orderedReplacements() catch return ctx.ast.source[start_off..end_off];
    const range_start = ctx.replacementLowerBound(start_off) catch return ctx.ast.source[start_off..end_off];
    for (ordered[range_start..]) |replacement| {
        if (replacement.start >= end_off) break;
        if (replacement.node_index >= ctx.ast.nodes.items(.tag).len) continue;

        const node_start = ctx.ast.node_start_overrides.get(@intCast(replacement.node_index)) orelse
            ctx.ast.tokens.items(.start)[@intFromEnum(ctx.ast.nodes.items(.main_token)[replacement.node_index])];
        const node_end = replacement.end;
        if (node_start < start_off or node_end > end_off) continue;
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

test "class properties preserve child rewrites and invalidate the shared replacement index" {
    const output = try transformClassPropertiesWithSnapshot(
        \\class A {
        \\  x = "hello";
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "constructor()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hello\"") == null);
}
