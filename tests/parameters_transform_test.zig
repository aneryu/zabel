const std = @import("std");
const zb = @import("zig_babal");

fn transformParameters(source: []const u8, emit_var_bindings: bool) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var result = try zb.parseWithOptions(alloc, source, .{
        .source_type = .script,
        .language = .typescript,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();
    pipeline.needs_scope = true;

    zb.Parameters.resetState();
    try pipeline.addPass(zb.Parameters.createPass(.{
        .emit_var_bindings = emit_var_bindings,
    }));
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

fn transformParametersWithSpread(source: []const u8, emit_var_bindings: bool) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
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
    try pipeline.addPass(zb.Spread.createPass(.{}));
    zb.Parameters.resetState();
    try pipeline.addPass(zb.Parameters.createPass(.{
        .emit_var_bindings = emit_var_bindings,
    }));
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

fn transformParametersWithClassWave(source: []const u8, emit_var_bindings: bool) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var result = try zb.parseWithOptions(alloc, source, .{
        .source_type = .script,
        .language = .typescript,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();
    pipeline.needs_scope = true;

    zb.Parameters.resetState();
    try pipeline.addPass(zb.Parameters.createPass(.{
        .emit_var_bindings = emit_var_bindings,
    }));
    zb.ClassesTransform.resetState();
    try pipeline.addPass(zb.ClassesTransform.createPass(.{
        .lower_runtime = true,
    }));
    zb.ClassPropertiesTransform.resetState();
    try pipeline.addPass(zb.ClassPropertiesTransform.createPass(.{}));
    try pipeline.run(&result.ast);

    const out = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
    return try std.testing.allocator.dupe(u8, out.code);
}

test "parameters transform lowers simple default parameter" {
    const output = try transformParameters(
        \\function demo(a = 1) { return a; }
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "arguments.length > 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "arguments[0] !== undefined") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return a;") != null);
}

test "parameters transform lowers rest parameter" {
    const output = try transformParameters(
        \\function demo(a, ...rest) { return rest.length + a; }
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "arguments.length <= 1 ? 0 : arguments.length - 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "...rest") == null);
}

test "parameters transform preserves complex destructuring path" {
    const output = try transformParameters(
        \\function demo({ a } = init(), ...rest) { return a + rest.length; }
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "init()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_ref.a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "arguments.length > 0") != null);
}

test "parameters transform lowers combined default and rest parameters" {
    const output = try transformParameters(
        \\function demo(a = seed(), ...rest) { return rest.length + a; }
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "arguments.length > 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "seed()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "arguments.length <= 1 ? 0 : arguments.length - 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rest.length") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+ a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "...rest") == null);
}

test "parameters transform honors emit_var_bindings" {
    const output = try transformParameters(
        \\function demo(a = 1, ...rest) { return a + rest.length; }
    , true);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var a = arguments.length > 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "let a =") == null);
}

test "parameters transform parenthesizes lowered arrow rest length in binary expression" {
    const output = try transformParameters(
        \\const demo = (a, ...rest) => rest.length + 1;
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "function (a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return (arguments.length <= 1 ? 0 : arguments.length - 1) + 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "...rest") == null);
}

test "parameters transform keeps generator default params on wrapped path" {
    const output = try transformParameters(
        \\function* demo(a = 1) { yield a; }
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "function demo() {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return function* () {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "}();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "function* demo") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "yield a;") != null);
}

test "parameters transform keeps async generator default params on wrapped path" {
    const output = try transformParameters(
        \\async function* demo(a = 1) { yield a; }
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "function demo() {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return async function* () {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "}();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "async function* demo") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "yield a;") != null);
}

test "parameters transform rewrites consecutive functions without stale reconstructed source" {
    const output = try transformParameters(
        \\function first(a = 1, ...rest) {
        \\  const len = rest.length;
        \\  return a + len;
        \\}
        \\
        \\const second = (b = 2, ...more) => {
        \\  const len = more.length;
        \\  return b + len;
        \\};
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "const len = arguments.length <= 1 ? 0 : arguments.length - 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return a + len;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return b + len;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "...rest") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "...more") == null);
}

test "parameters transform preserves spread-lowered loop call inside rest body" {
    const output = try transformParametersWithSpread(
        \\function runQueue(queue, ...args) {
        \\  for (let i = 0; i < queue.length; i++) {
        \\    queue[i](...args);
        \\  }
        \\}
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "for (var _len = arguments.length, args = new Array(_len > 1 ? _len - 1 : 0), _key = 1; _key < _len; _key++)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "queue[i].apply(queue, args);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "queue[i](...args)") == null);
}

test "parameters transform renames rest arguments binding through nested function bodies" {
    const output = try transformParameters(
        \\function demo(...arguments) {
        \\  return function() {
        \\    return arguments;
        \\  };
        \\}
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "_arguments = new Array") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return _arguments;") != null);
}

test "parameters transform materializes expression-body arrow rest inside wrapper" {
    const output = try transformParameters(
        \\const deepAssign = (...args) => args = [];
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "const deepAssign = function () {\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "\nfor (var _len = arguments.length") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  for (var _len = arguments.length, args = new Array(_len), _key = 0; _key < _len; _key++) {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  return args = [];\n") != null);
}

test "parameters transform keeps deferred class-field rest materialization inside arrow wrapper" {
    const output = try transformParameters(
        \\var innerclassproperties = (...args) => class {
        \\  static args = args;
        \\  args = args;
        \\};
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "var innerclassproperties = function () {\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "\nfor (var _len = arguments.length") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  for (var _len = arguments.length, args = new Array(_len), _key = 0; _key < _len; _key++) {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  return class {\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "...args") == null);
}

test "parameters transform keeps class preludes ahead of deferred rest loops" {
    const output = try transformParametersWithClassWave(
        \\var innerclassproperties = (...args) => class {
        \\  static args = args;
        \\  args = args;
        \\};
    , false);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "var innerclassproperties = function () {\n  var _Class;\n  for (var _len = arguments.length, args = new Array(_len), _key = 0; _key < _len; _key++) {\n") != null);
}
