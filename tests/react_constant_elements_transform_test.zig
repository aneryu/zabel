const std = @import("std");
const zb = @import("zig_babal");
const visitor = zb.Visitor;

fn transformReactConstantElementsWithPreReplacement(source: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var result = try zb.parseWithOptions(alloc, source, .{
        .source_type = .script,
        .language = .jsx,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();

    zb.ReactConstantElements.resetState();
    try pipeline.addPass(createPrimeReplacementIndexPass());
    try pipeline.addPass(createReplaceJsxTextPass());
    try pipeline.addPass(zb.ReactConstantElements.createPass());
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

fn createPrimeReplacementIndexPass() @TypeOf(zb.ReactConstantElements.createPass()) {
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

fn createReplaceJsxTextPass() @TypeOf(zb.ReactConstantElements.createPass()) {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(zb.Node.Tag.jsx_text));
    return .{
        .name = "test_replace_jsx_text",
        .node_filter = filter,
        .exit = replaceJsxText,
        .priority = 2,
    };
}

fn replaceJsxText(idx: zb.NodeIndex, ctx: *zb.TransformContext) visitor.VisitResult {
    const text = ctx.tokenSlice(ctx.mainToken(idx));
    if (std.mem.eql(u8, text, "hello")) {
        ctx.putReplacementSource(idx, "world") catch {};
    }
    return .continue_traversal;
}

test "react constant elements preserves prior jsx child replacements when hoisting" {
    const output = try transformReactConstantElementsWithPreReplacement(
        \\var el = <div>hello</div>;
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var _div;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_div = <div>world</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") == null);
}
