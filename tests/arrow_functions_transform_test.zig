const std = @import("std");
const zb = @import("zig_babal");

fn transformArrowFunctionsWithConfig(source: []const u8, config: zb.ArrowFunctions.Config) ![]const u8 {
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
    pipeline.needs_scope = true;

    zb.ArrowFunctions.resetState();
    try pipeline.addPass(zb.ArrowFunctions.createPass(config));
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

fn transformArrowFunctions(source: []const u8) ![]const u8 {
    return transformArrowFunctionsWithConfig(source, .{});
}

test "arrow functions transform keeps self-referential declarator arrows named" {
    const output = try transformArrowFunctions(
        \\var fact = n => n > 1 ? n * fact(n - 1) : 1;
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var _fact = function fact(n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_fact(n - 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "=>") == null);
}

test "arrow functions transform keeps self-referential assignment arrows named" {
    const output = try transformArrowFunctions(
        \\var fact;
        \\fact = n => n > 1 ? n * fact(n - 1) : 1;
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "_fact = function fact(n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_fact(n - 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "=>") == null);
}

test "arrow functions transform does not treat member properties as self references" {
    const output = try transformArrowFunctions(
        \\var fact = () => obj.fact;
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var fact = function fact(") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return obj.fact;") != null);
}

test "arrow functions transform ignores nested non-arrow self references" {
    const output = try transformArrowFunctions(
        \\var fact = () => function() { return fact; };
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var fact = function fact(") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return function ()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return fact;") != null);
}

test "arrow functions spec mode rebuilds expression bodies from ordered replacements" {
    const output = try transformArrowFunctionsWithConfig(
        \\function outer() {
        \\  var fn = () => arguments[0];
        \\}
    , .{
        .no_new_arrows = false,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var _arguments = arguments;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return _arguments[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "}.bind(this);") != null);
}
