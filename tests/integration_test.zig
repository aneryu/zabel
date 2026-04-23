const std = @import("std");
const zig_babal = @import("zig_babal");

fn serializeAstJson(allocator: std.mem.Allocator, ast: *const zig_babal.Ast) ![]u8 {
    var json_output: std.ArrayList(u8) = .empty;
    errdefer json_output.deinit(allocator);

    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_output);
    try zig_babal.AstJson.serialize(ast, &writer.writer);
    json_output = writer.toArrayList();
    return try json_output.toOwnedSlice(allocator);
}

test "parse basic JavaScript" {
    const source =
        \\const greeting = "hello";
        \\
        \\function add(a, b) {
        \\    return a + b;
        \\}
        \\
        \\var x = 1 + 2;
        \\if (x > 0) { x = x - 1; }
        \\
        \\for (var i = 0; i < 10; i++) {}
        \\
        \\while (true) { break; }
        \\
        \\try { throw new Error(); } catch (e) {}
    ;

    var result = try zig_babal.parse(std.testing.allocator, source);
    defer result.deinit();

    if (result.errors.hasErrors()) {
        for (result.errors.items.items) |d| {
            std.debug.print("Error: {s} at offset {d}\n", .{ d.message, d.token_start });
        }
    }
    try std.testing.expect(!result.errors.hasErrors());

    // Should produce JSON output
    const json = try serializeAstJson(std.testing.allocator, &result.ast);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"Program\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"FunctionDeclaration\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"VariableDeclaration\"") != null);
}

test "parse empty file" {
    var result = try zig_babal.parse(std.testing.allocator, "");
    defer result.deinit();
    try std.testing.expect(!result.errors.hasErrors());
}

test "parse preserves token positions" {
    var result = try zig_babal.parse(std.testing.allocator, "var x = 42;\nvar y = 100;\n");
    defer result.deinit();
    try std.testing.expect(!result.errors.hasErrors());
    try std.testing.expect(result.ast.line_offsets.items.len >= 1);
    try std.testing.expectEqual(@as(u32, 0), result.ast.line_offsets.items[0]);
}
