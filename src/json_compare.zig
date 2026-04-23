const std = @import("std");

pub const Diff = struct {
    path: []const u8,
    expected: []const u8,
    actual: []const u8,
};

pub const CompareResult = struct {
    diffs: []Diff,
    diff_storage: std.ArrayList(Diff),
    string_storage: std.ArrayList(u8),

    pub fn deinit(self: *CompareResult, allocator: std.mem.Allocator) void {
        self.diff_storage.deinit(allocator);
        self.string_storage.deinit(allocator);
    }
};

pub fn compare(allocator: std.mem.Allocator, expected_json: []const u8, actual_json: []const u8) !CompareResult {
    const expected = try std.json.parseFromSliceLeaky(std.json.Value, allocator, expected_json, .{});
    const actual = try std.json.parseFromSliceLeaky(std.json.Value, allocator, actual_json, .{});

    var diff_storage: std.ArrayList(Diff) = .empty;
    var string_storage: std.ArrayList(u8) = .empty;

    var ctx = CompareContext{
        .allocator = allocator,
        .diffs = &diff_storage,
        .strings = &string_storage,
    };

    try ctx.compareValues(expected, actual, "");

    return .{
        .diffs = diff_storage.items,
        .diff_storage = diff_storage,
        .string_storage = string_storage,
    };
}

const MAX_DIFFS = 10;

const CompareContext = struct {
    allocator: std.mem.Allocator,
    diffs: *std.ArrayList(Diff),
    strings: *std.ArrayList(u8),

    fn addDiff(self: *CompareContext, path: []const u8, expected: []const u8, actual: []const u8) !void {
        if (self.diffs.items.len >= MAX_DIFFS) return;
        const path_start = self.strings.items.len;
        try self.strings.appendSlice(self.allocator, path);
        const exp_start = self.strings.items.len;
        try self.strings.appendSlice(self.allocator, expected);
        const act_start = self.strings.items.len;
        try self.strings.appendSlice(self.allocator, actual);
        const act_end = self.strings.items.len;

        try self.diffs.append(self.allocator, .{
            .path = self.strings.items[path_start..exp_start],
            .expected = self.strings.items[exp_start..act_start],
            .actual = self.strings.items[act_start..act_end],
        });
    }

    fn compareValues(self: *CompareContext, expected: std.json.Value, actual: std.json.Value, path: []const u8) !void {
        // Early exit: stop recursing once we have enough diffs
        if (self.diffs.items.len >= MAX_DIFFS) return;

        const exp_tag = std.meta.activeTag(expected);
        const act_tag = std.meta.activeTag(actual);

        if (exp_tag != act_tag) {
            try self.addDiff(path, @tagName(exp_tag), @tagName(act_tag));
            return;
        }

        switch (expected) {
            .null => {},
            .bool => |eb| {
                if (eb != actual.bool) {
                    try self.addDiff(path, if (eb) "true" else "false", if (actual.bool) "true" else "false");
                }
            },
            .integer => |ei| {
                if (ei != actual.integer) {
                    try self.addDiff(path, "integer", "integer");
                }
            },
            .float => |ef| {
                if (ef != actual.float) {
                    try self.addDiff(path, "float", "float");
                }
            },
            .string => |es| {
                if (!std.mem.eql(u8, es, actual.string)) {
                    try self.addDiff(path, es, actual.string);
                }
            },
            .array => |ea| {
                const aa = actual.array;
                if (ea.items.len != aa.items.len) {
                    var buf: [64]u8 = undefined;
                    const exp_len = std.fmt.bufPrint(&buf, "length={d}", .{ea.items.len}) catch "?";
                    var buf2: [64]u8 = undefined;
                    const act_len = std.fmt.bufPrint(&buf2, "length={d}", .{aa.items.len}) catch "?";
                    try self.addDiff(path, exp_len, act_len);
                    return;
                }
                for (ea.items, aa.items, 0..) |ev, av, i| {
                    if (self.diffs.items.len >= MAX_DIFFS) return;
                    var child_path_buf: [512]u8 = undefined;
                    const child_path = std.fmt.bufPrint(&child_path_buf, "{s}[{d}]", .{ path, i }) catch path;
                    try self.compareValues(ev, av, child_path);
                }
            },
            .object => |eo| {
                const ao = actual.object;
                var it = eo.iterator();
                while (it.next()) |entry| {
                    if (self.diffs.items.len >= MAX_DIFFS) return;
                    var child_path_buf: [512]u8 = undefined;
                    const child_path = if (path.len > 0)
                        std.fmt.bufPrint(&child_path_buf, "{s}.{s}", .{ path, entry.key_ptr.* }) catch path
                    else
                        std.fmt.bufPrint(&child_path_buf, "{s}", .{entry.key_ptr.*}) catch path;

                    if (ao.get(entry.key_ptr.*)) |actual_val| {
                        try self.compareValues(entry.value_ptr.*, actual_val, child_path);
                    } else {
                        try self.addDiff(child_path, "present", "missing");
                    }
                }
                var ait = ao.iterator();
                while (ait.next()) |entry| {
                    if (self.diffs.items.len >= MAX_DIFFS) return;
                    if (eo.get(entry.key_ptr.*) == null) {
                        var child_path_buf: [512]u8 = undefined;
                        const child_path = if (path.len > 0)
                            std.fmt.bufPrint(&child_path_buf, "{s}.{s}", .{ path, entry.key_ptr.* }) catch path
                        else
                            std.fmt.bufPrint(&child_path_buf, "{s}", .{entry.key_ptr.*}) catch path;
                        try self.addDiff(child_path, "missing", "present");
                    }
                }
            },
            .number_string => {},
        }
    }
};
