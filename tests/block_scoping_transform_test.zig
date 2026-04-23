const std = @import("std");
const zb = @import("zig_babal");

fn transformBlockScoping(source: []const u8) ![]const u8 {
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

    zb.BlockScoping.resetState();
    try pipeline.addPass(zb.BlockScoping.createPass(.{}));
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

fn transformBlockScopingThenBlockScopedFunctions(source: []const u8) ![]const u8 {
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

    zb.BlockScoping.resetState();
    zb.BlockScopedFunctions.resetState();
    try pipeline.addPass(zb.BlockScoping.createPass(.{}));
    try pipeline.addPass(zb.BlockScopedFunctions.createPass(.{
        .followed_by_block_scoping = true,
    }));
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

fn transformTemplateLiteralsThenBlockScoping(source: []const u8) ![]const u8 {
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

    zb.TemplateLiterals.resetState();
    zb.BlockScoping.resetState();
    try pipeline.addPass(zb.TemplateLiterals.createPass(.{}));
    try pipeline.addPass(zb.BlockScoping.createPass(.{}));
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

test "block scoping leaves simple loop without wrapper" {
    const output = try transformBlockScoping(
        \\function demo() {
        \\  var total = 0;
        \\  for (let i = 0; i < 3; i++) {
        \\    total += i;
        \\  }
        \\  return total;
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "for (var ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "for (let ") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_loop") == null);
}

test "block scoping still wraps loop closure" {
    const output = try transformBlockScoping(
        \\function demo(out) {
        \\  for (let i = 0; i < 3; i++) {
        \\    out.push(function() {
        \\      return i;
        \\    });
        \\  }
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var _loop = function") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_loop(") != null);
}

test "block scoping preserves for-of loop closure renames" {
    const output = try transformBlockScoping(
        \\function demo(list, callbacks) {
        \\  for (const value of list) {
        \\    callbacks.push(function() {
        \\      return value;
        \\    });
        \\  }
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var _loop = function") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_loop(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "for (const value of") == null);
}

test "block scoping handles for loop without initializer head" {
    const output = try transformBlockScoping(
        \\function demo() {
        \\  let i = 0;
        \\  for (; i < 3; i++) {
        \\    i += 1;
        \\  }
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "for (;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "i += 1;") != null);
}

test "block scoping ignores string literal text when deciding rename" {
    const output = try transformBlockScoping(
        \\function demo(flag, log) {
        \\  if (flag) {
        \\    let item = 1;
        \\    log(item);
        \\  }
        \\  log("item");
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var item = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var _item") == null);
}

test "block scoping preserves prior child replacements when renaming shadowed declarations" {
    const output = try transformTemplateLiteralsThenBlockScoping(
        \\function demo(flag) {
        \\  let value = 0;
        \\  if (flag) {
        \\    let value = `inner`;
        \\    return value;
        \\  }
        \\  return value;
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var _value = \"inner\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return _value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`inner`") == null);
}

test "block scoping wraps loop with block-scoped functions in bare if branch" {
    const output = try transformBlockScopingThenBlockScopedFunctions(
        \\function WithoutCurlyBraces() {
        \\  if (true)
        \\    for (let k in kv) {
        \\      function foo() { return this; }
        \\      function bar() { return foo.call(this); }
        \\      console.log(this, k);
        \\    }
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var _this = this;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var _loop = function () {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "if (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_loop();") != null);
}

test "block scoping wraps hoisted function declarations that capture loop heads" {
    const output = try transformBlockScopingThenBlockScopedFunctions(
        \\for (let i = 0; i < 3; i++) {
        \\  if (i === 0) {
        \\    function test() {
        \\      return i;
        \\    }
        \\  }
        \\  expect(test()).toBe(0);
        \\}
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var _loop = function (i) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test = function () {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_loop(i);") != null);
}
