const std = @import("std");
const Ast = @import("../ast.zig").Ast;

const Allocator = std.mem.Allocator;

pub const ReplacementIndex = struct {
    ast: ?*const Ast = null,
    dirty: bool = true,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        node_index: u32,
        start: u32,
        end: u32,
        text: []const u8,
        needs_reindent: bool,
    };

    pub fn deinit(self: *ReplacementIndex, allocator: Allocator) void {
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn invalidate(self: *ReplacementIndex) void {
        self.dirty = true;
    }

    pub fn ordered(self: *ReplacementIndex, allocator: Allocator, ast: *const Ast) ![]const Entry {
        try self.ensureBuilt(allocator, ast);
        return self.entries.items;
    }

    pub fn lowerBound(self: *ReplacementIndex, allocator: Allocator, ast: *const Ast, target_start: u32) !usize {
        const ordered_entries = try self.ordered(allocator, ast);
        var lo: usize = 0;
        var hi: usize = ordered_entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ordered_entries[mid].start < target_start) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    fn ensureBuilt(self: *ReplacementIndex, allocator: Allocator, ast: *const Ast) !void {
        if (self.ast == ast and !self.dirty) return;

        self.ast = ast;
        self.dirty = false;
        self.entries.clearRetainingCapacity();

        const replacement_count = ast.replacement_source.count();
        if (replacement_count == 0) return;

        try self.entries.ensureTotalCapacityPrecise(allocator, replacement_count);
        var iter = ast.replacement_source.iterator();
        while (iter.next()) |entry| {
            const node_index = entry.key_ptr.*;
            if (node_index >= ast.nodes.len) continue;
            self.entries.appendAssumeCapacity(.{
                .node_index = node_index,
                .start = nodeStartOffsetRaw(ast, node_index),
                .end = ast.nodes.items(.end_offset)[node_index],
                .text = entry.value_ptr.*,
                .needs_reindent = ast.replacement_needs_reindent.contains(node_index),
            });
        }

        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
                if (lhs.start != rhs.start) return lhs.start < rhs.start;
                if (lhs.end != rhs.end) return lhs.end < rhs.end;
                return lhs.node_index < rhs.node_index;
            }
        }.lessThan);
    }

    fn nodeStartOffsetRaw(ast: *const Ast, node_index: u32) u32 {
        return ast.node_start_overrides.get(node_index) orelse
            ast.tokens.items(.start)[@intFromEnum(ast.nodes.items(.main_token)[node_index])];
    }
};
