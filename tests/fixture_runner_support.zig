const std = @import("std");

pub const RuntimeContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,

    pub fn fromInit(init: std.process.Init) RuntimeContext {
        return .{
            .allocator = init.gpa,
            .io = init.io,
            .arena = init.arena.allocator(),
            .environ = init.minimal.environ,
        };
    }
};

pub const DiscoveryHooks = struct {
    user: ?*anyopaque = null,
    decide_fixture: *const fn (io: std.Io, dir: std.Io.Dir, dir_path: []const u8, user: ?*anyopaque) anyerror!FixtureDecision,
    on_fixture: *const fn (alloc: std.mem.Allocator, dir_path: []const u8, user: ?*anyopaque) anyerror!void,
    should_descend: ?*const fn (entry_name: []const u8, user: ?*anyopaque) bool = null,
};

pub const FixtureDecision = enum {
    descend,
    collect_and_stop,
    stop_without_collect,
};

pub fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const out = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| out[i] = arg;
    return out;
}

pub fn dirHasFile(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    return if (dir.access(io, name, .{})) |_| true else |_| false;
}

pub fn dirHasAnyFile(io: std.Io, dir: std.Io.Dir, names: []const []const u8) bool {
    for (names) |name| {
        if (dirHasFile(io, dir, name)) return true;
    }
    return false;
}

pub fn readFirstExistingFileAlloc(
    io: std.Io,
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    names: []const []const u8,
    limit: usize,
) ?[]const u8 {
    for (names) |name| {
        return dir.readFileAlloc(io, name, alloc, .limited(limit)) catch |err| {
            if (err != error.FileNotFound) return null;
            continue;
        };
    }
    return null;
}

pub fn discoverFixtureDirs(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    hooks: DiscoveryHooks,
) !void {
    var base_dir = std.Io.Dir.cwd().openDir(io, base_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open '{s}': {}\nHint: git submodule update --init\n", .{ base_path, err });
        return err;
    };
    defer base_dir.close(io);
    try walkFixtureDirsFromBase(alloc, io, base_dir, base_path, hooks);
}

pub fn walkFixtureDirsFromBase(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    hooks: DiscoveryHooks,
) !void {
    switch (try hooks.decide_fixture(io, dir, dir_path, hooks.user)) {
        .descend => {},
        .collect_and_stop => {
            try hooks.on_fixture(alloc, dir_path, hooks.user);
            return;
        },
        .stop_without_collect => return,
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (hooks.should_descend) |should_descend| {
            if (!should_descend(entry.name, hooks.user)) continue;
        }

        var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        try walkFixtureDirsFromBase(alloc, io, sub, child_path, hooks);
    }
}
