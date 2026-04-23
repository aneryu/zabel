const std = @import("std");
const zig_babal = @import("zig_babal");
const SourceMap = zig_babal.SourceMap;

const encodeVLQ = SourceMap.encodeVLQ;
const decodeVLQ = SourceMap.decodeVLQ;
const SourceMapBuilder = SourceMap.SourceMapBuilder;

// ---------------------------------------------------------------------------
// VLQ encoding tests
// ---------------------------------------------------------------------------

test "VLQ encode 0 => A" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeVLQ(&buf, std.testing.allocator, 0);
    try std.testing.expectEqualStrings("A", buf.items);
}

test "VLQ encode 16 => gB" {
    // 16 << 1 = 32; 32 & 0x1f = 0 with continuation bit (0x20) -> index 32 = 'g'
    // 32 >> 5 = 1; no more bits -> index 1 = 'B'
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeVLQ(&buf, std.testing.allocator, 16);
    try std.testing.expectEqualStrings("gB", buf.items);
}

test "VLQ encode -1 => D" {
    // (-1): (1 << 1) | 1 = 3; char at index 3 = 'D'
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeVLQ(&buf, std.testing.allocator, -1);
    try std.testing.expectEqualStrings("D", buf.items);
}

// ---------------------------------------------------------------------------
// VLQ roundtrip tests
// ---------------------------------------------------------------------------

test "VLQ roundtrip" {
    const values = [_]i32{ 0, 1, -1, 5, -5, 16, -16, 100, -100, 1000, -1000 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    for (values) |v| {
        buf.clearRetainingCapacity();
        try encodeVLQ(&buf, std.testing.allocator, v);
        var pos: usize = 0;
        const decoded = decodeVLQ(buf.items, &pos);
        try std.testing.expectEqual(v, decoded);
        try std.testing.expectEqual(buf.items.len, pos);
    }
}

// ---------------------------------------------------------------------------
// SourceMapBuilder tests
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// End-to-end source map integration test
// ---------------------------------------------------------------------------

test "source map: parse → generate → verify mappings" {
    const source = "var x = 1;\nfunction foo() {\n  return x;\n}\n";
    var result = try zig_babal.parse(std.testing.allocator, source);
    defer result.deinit();

    const gen = try zig_babal.Codegen.generate(&result.ast, .{ .source_maps = true }, std.testing.allocator);
    defer gen.deinit(std.testing.allocator);

    // Verify code is non-empty
    try std.testing.expect(gen.code.len > 0);

    // Verify map exists and contains valid Source Map v3 markers
    try std.testing.expect(gen.map != null);
    const map = gen.map.?;
    try std.testing.expect(std.mem.indexOf(u8, map, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, map, "\"mappings\":\"") != null);
}

test "SourceMapBuilder basic finalize" {
    var builder = SourceMapBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const src_idx = try builder.addSource("input.js", "var x = 1;");

    builder.addMapping(.{
        .gen_line = 0,
        .gen_col = 0,
        .orig_line = 0,
        .orig_col = 0,
        .source_index = src_idx,
    });
    builder.addMapping(.{
        .gen_line = 0,
        .gen_col = 4,
        .orig_line = 0,
        .orig_col = 4,
        .source_index = src_idx,
    });

    const result = try builder.finalize();
    defer std.testing.allocator.free(result);

    // Must contain version 3
    try std.testing.expect(std.mem.indexOf(u8, result, "\"version\":3") != null);
    // Must contain source file name
    try std.testing.expect(std.mem.indexOf(u8, result, "input.js") != null);
    // Must contain mappings key
    try std.testing.expect(std.mem.indexOf(u8, result, "\"mappings\":\"") != null);
}
