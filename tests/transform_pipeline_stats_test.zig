const std = @import("std");
const zb = @import("zig_babal");

test "pipeline exposes last-run pass stats in execution order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\const fn1 = (a = 1, ...rest) => [...rest, a];
        \\for (const value of [1, 2, 3]) {
        \\  console.log(value);
        \\}
    ;

    var result = try zb.parseWithOptions(alloc, source, .{
        .source_type = .script,
        .language = .typescript,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();

    pipeline.needs_scope = true;
    zb.Spread.resetState();
    var spread_pass = zb.Spread.createPass(.{ .strip_typescript_wrappers = true });
    spread_pass.priority = 10;
    try pipeline.addPass(spread_pass);
    try pipeline.addPass(zb.ArrowFunctions.createPass(.{}));
    zb.Parameters.resetState();
    try pipeline.addPass(zb.Parameters.createPass(.{}));
    zb.ForOf.resetState();
    var for_of_pass = zb.ForOf.createPass(.{});
    for_of_pass.priority = 21;
    try pipeline.addPass(for_of_pass);
    zb.BlockScoping.resetState();
    try pipeline.addPass(zb.BlockScoping.createPass(.{}));

    try pipeline.run(&result.ast);

    try std.testing.expect(pipeline.lastRunStats() == null);
    try std.testing.expect(pipeline.lastTransformSession() == null);
}

test "pipeline retains run stats and transform session when profiling is enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source =
        \\const fn1 = (a = 1, ...rest) => [...rest, a];
        \\for (const value of [1, 2, 3]) {
        \\  console.log(value);
        \\}
    ;

    var result = try zb.parseWithOptions(alloc, source, .{
        .source_type = .script,
        .language = .typescript,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();

    pipeline.needs_scope = true;
    pipeline.collect_run_stats = true;
    pipeline.retain_transform_session = true;
    zb.Spread.resetState();
    var spread_pass = zb.Spread.createPass(.{ .strip_typescript_wrappers = true });
    spread_pass.priority = 10;
    try pipeline.addPass(spread_pass);
    try pipeline.addPass(zb.ArrowFunctions.createPass(.{}));
    zb.Parameters.resetState();
    try pipeline.addPass(zb.Parameters.createPass(.{}));
    zb.ForOf.resetState();
    var for_of_pass = zb.ForOf.createPass(.{});
    for_of_pass.priority = 21;
    try pipeline.addPass(for_of_pass);
    zb.BlockScoping.resetState();
    try pipeline.addPass(zb.BlockScoping.createPass(.{}));

    try pipeline.run(&result.ast);

    const stats = pipeline.lastRunStats() orelse return error.ExpectedPipelineStats;

    try std.testing.expect(stats.passes.len == 5);
    try std.testing.expectEqualStrings("spread", stats.passes[0].name);
    try std.testing.expectEqualStrings("arrow_functions", stats.passes[1].name);
    try std.testing.expectEqualStrings("for_of", stats.passes[2].name);
    try std.testing.expectEqualStrings("block_scoping", stats.passes[3].name);
    try std.testing.expectEqualStrings("parameters", stats.passes[4].name);
    try std.testing.expect(stats.scope_analysis_ns != null);
    try std.testing.expect(stats.transform_session_ns != null);
    try std.testing.expect(stats.dispatch_table_build_ns != null);
    try std.testing.expect(stats.traversal_ns != null);
    try std.testing.expect(stats.nodes_visited > 0);
    try std.testing.expect(pipeline.lastTransformSession() != null);
}
