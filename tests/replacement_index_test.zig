const std = @import("std");
const zb = @import("zig_babal");

fn firstIdentifierWithName(ast: *const zb.Ast, name: []const u8) ?zb.NodeIndex {
    const tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);
    for (tags, 0..) |tag, i| {
        if (tag != .identifier) continue;
        if (std.mem.eql(u8, ast.tokenSlice(main_tokens[i]), name)) {
            return @enumFromInt(i);
        }
    }
    return null;
}

test "replacement index orders replacements and rebuilds after invalidation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\function demo() {
        \\  return bar + foo;
        \\}
    ,
        .{
            .source_type = .script,
            .language = .typescript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    const bar = firstIdentifierWithName(&parsed.ast, "bar") orelse return error.ExpectedBar;
    const foo = firstIdentifierWithName(&parsed.ast, "foo") orelse return error.ExpectedFoo;

    try parsed.ast.replacement_source.put(alloc, @intFromEnum(foo), "FOO");
    try parsed.ast.replacement_source.put(alloc, @intFromEnum(bar), "BAR");

    var index = zb.ReplacementIndex{};
    defer index.deinit(alloc);

    const ordered = try index.ordered(alloc, &parsed.ast);
    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expectEqual(@intFromEnum(bar), ordered[0].node_index);
    try std.testing.expectEqualStrings("BAR", ordered[0].text);
    try std.testing.expectEqual(@intFromEnum(foo), ordered[1].node_index);
    try std.testing.expectEqualStrings("FOO", ordered[1].text);

    try parsed.ast.replacement_source.put(alloc, @intFromEnum(bar), "BAR2");
    index.invalidate();

    const rebuilt = try index.ordered(alloc, &parsed.ast);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.len);
    try std.testing.expectEqualStrings("BAR2", rebuilt[0].text);
}
