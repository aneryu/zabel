const std = @import("std");
const zb = @import("zig_babal");
const visitor = zb.Visitor;

fn transformModulesCommonJSWithPreReplacement(source: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var result = try zb.parseWithOptions(alloc, source, .{
        .source_type = .module,
        .language = .javascript,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();
    pipeline.needs_scope = true;

    zb.ModulesCommonJS.resetState();
    try pipeline.addPass(createPrimeReplacementIndexPass());
    try pipeline.addPass(createReplaceStringLiteralPass());
    try pipeline.addPass(zb.ModulesCommonJS.createPass());
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

fn createPrimeReplacementIndexPass() @TypeOf(zb.ModulesCommonJS.createPass()) {
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

fn createReplaceStringLiteralPass() @TypeOf(zb.ModulesCommonJS.createPass()) {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(zb.Node.Tag.string_literal));
    return .{
        .name = "test_replace_string_literal",
        .node_filter = filter,
        .exit = replaceStringLiteral,
        .priority = 2,
    };
}

fn replaceStringLiteral(idx: zb.NodeIndex, ctx: *zb.TransformContext) visitor.VisitResult {
    const text = ctx.tokenSlice(ctx.mainToken(idx));
    if (std.mem.eql(u8, text, "\"hello\"")) {
        ctx.putReplacementSource(idx, "\"world\"") catch {};
    }
    return .continue_traversal;
}

test "modules commonjs preserves prior child replacements in preserved statements" {
    const output = try transformModulesCommonJSWithPreReplacement(
        \\import "foo";
        \\const msg = "hello";
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "require(\"foo\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const msg = \"world\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hello\"") == null);
}
