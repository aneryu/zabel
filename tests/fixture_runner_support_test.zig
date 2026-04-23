const std = @import("std");
const support = @import("fixture_runner_support.zig");

test "dirHasAnyFile returns true only when one of the candidates exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "input.ts",
        .data = "const answer = 42;\n",
    });

    try std.testing.expect(support.dirHasAnyFile(
        std.testing.io,
        tmp.dir,
        &.{ "input.js", "input.ts" },
    ));

    try std.testing.expect(!support.dirHasAnyFile(
        std.testing.io,
        tmp.dir,
        &.{ "missing.js", "missing.ts" },
    ));
}

test "readFirstExistingFileAlloc returns the first readable candidate in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "input.js",
        .data = "const first = true;\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "input.ts",
        .data = "let value = 1;\n",
    });

    const data = support.readFirstExistingFileAlloc(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        &.{ "input.js", "input.ts" },
        1024,
    ) orelse return error.ExpectedFixtureInput;
    defer std.testing.allocator.free(data);

    try std.testing.expectEqualStrings("const first = true;\n", data);
}

test "walkFixtureDirsFromBase can stop without collecting or descending" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "fixture/child");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "fixture/input.js",
        .data = "fixture\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "fixture/output.js",
        .data = "output\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "fixture/child/input.js",
        .data = "nested\n",
    });

    var hits: usize = 0;
    const Hooks = struct {
        fn decide(io: std.Io, dir: std.Io.Dir, dir_path: []const u8, user: ?*anyopaque) !support.FixtureDecision {
            const count: *usize = @ptrCast(@alignCast(user orelse return error.MissingUser));
            _ = dir_path;
            count.* += 1;
            if (support.dirHasAnyFile(io, dir, &.{"input.js"}) and support.dirHasFile(io, dir, "output.js")) {
                return .stop_without_collect;
            }
            return .descend;
        }

        fn onFixture(alloc: std.mem.Allocator, dir_path: []const u8, user: ?*anyopaque) !void {
            _ = alloc;
            _ = dir_path;
            _ = user;
            return error.UnexpectedCollection;
        }
    };

    try support.walkFixtureDirsFromBase(std.testing.allocator, std.testing.io, tmp.dir, ".zig-cache/tmp", .{
        .user = &hits,
        .decide_fixture = Hooks.decide,
        .on_fixture = Hooks.onFixture,
    });

    try std.testing.expectEqual(@as(usize, 2), hits);
}
