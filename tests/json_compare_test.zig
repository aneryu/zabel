const std = @import("std");
const zig_babal = @import("zig_babal");
const JsonCompare = zig_babal.JsonCompare;

fn testCompare(a: []const u8, b: []const u8) !JsonCompare.CompareResult {
    // Use arena so parseFromSliceLeaky allocations are properly managed
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    return JsonCompare.compare(arena.allocator(), a, b);
}

test "identical objects match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try JsonCompare.compare(arena.allocator(), "{\"type\":\"File\",\"start\":0}", "{\"type\":\"File\",\"start\":0}");
    try std.testing.expectEqual(@as(usize, 0), result.diffs.len);
}

test "different values produce diff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try JsonCompare.compare(arena.allocator(), "{\"type\":\"File\",\"start\":0}", "{\"type\":\"File\",\"start\":5}");
    try std.testing.expectEqual(@as(usize, 1), result.diffs.len);
    try std.testing.expect(std.mem.indexOf(u8, result.diffs[0].path, "start") != null);
}

test "missing key produces diff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try JsonCompare.compare(arena.allocator(), "{\"type\":\"File\",\"start\":0}", "{\"type\":\"File\"}");
    try std.testing.expect(result.diffs.len > 0);
}

test "array length mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try JsonCompare.compare(arena.allocator(), "[1,2,3]", "[1,2]");
    try std.testing.expect(result.diffs.len > 0);
}

test "nested diff reports full path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try JsonCompare.compare(arena.allocator(), "{\"body\":[{\"type\":\"A\"}]}", "{\"body\":[{\"type\":\"B\"}]}");
    try std.testing.expect(result.diffs.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.diffs[0].path, "body[0].type") != null);
}

test "identical nested objects match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = "{\"a\":{\"b\":{\"c\":1}},\"d\":[1,2,3]}";
    const result = try JsonCompare.compare(arena.allocator(), json, json);
    try std.testing.expectEqual(@as(usize, 0), result.diffs.len);
}
