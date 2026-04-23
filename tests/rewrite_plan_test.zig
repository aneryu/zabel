const std = @import("std");
const zb = @import("zig_babal");

fn firstProgramChild(ast: *const zb.Ast) zb.NodeIndex {
    const program_data = ast.nodes.items(.data)[0];
    const extra_idx = @intFromEnum(program_data.extra);
    const range_start = ast.extra_data.items[extra_idx];
    return @enumFromInt(ast.extra_data.items[range_start]);
}

test "rewrite plan sorts replacements by source order and rejects overlap" {
    var plan = zb.RewritePlan.init(std.testing.allocator);
    defer plan.deinit();

    try plan.add(.{
        .start = 20,
        .end = 25,
        .text = "second",
        .needs_reindent = false,
    });
    try plan.add(.{
        .start = 10,
        .end = 15,
        .text = "first",
        .needs_reindent = true,
    });
    try std.testing.expectError(error.OverlappingReplacement, plan.add(.{
        .start = 12,
        .end = 14,
        .text = "bad",
        .needs_reindent = false,
    }));

    const ordered = try plan.ordered(std.testing.allocator);
    defer std.testing.allocator.free(ordered);

    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expectEqual(@as(u32, 10), ordered[0].start);
    try std.testing.expectEqualStrings("first", ordered[0].text);
    try std.testing.expect(ordered[0].needs_reindent);
    try std.testing.expectEqual(@as(u32, 20), ordered[1].start);
}

test "rewrite plan applies node replacements to ast replacement maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\function demo(a = 1) {
        \\  return a;
        \\}
    ,
        .{
            .source_type = .script,
            .language = .typescript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    const fn_node = firstProgramChild(&parsed.ast);
    const fn_index = @intFromEnum(fn_node);

    var plan = zb.RewritePlan.init(alloc);
    defer plan.deinit();
    try plan.add(.{
        .node_index = fn_index,
        .start = 0,
        .end = parsed.ast.nodes.items(.end_offset)[fn_index],
        .text = "function demo() { return 1; }",
        .needs_reindent = true,
    });

    try plan.applyToAst(&parsed.ast, alloc);

    try std.testing.expectEqualStrings("function demo() { return 1; }", parsed.ast.replacement_source.get(fn_index).?);
    try std.testing.expect(parsed.ast.replacement_needs_reindent.contains(fn_index));
}
