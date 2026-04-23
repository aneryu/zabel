const std = @import("std");
const Ast = @import("../ast.zig").Ast;

const Allocator = std.mem.Allocator;

pub const Replacement = struct {
    node_index: ?u32 = null,
    start: u32,
    end: u32,
    text: []const u8,
    needs_reindent: bool,
};

pub const RewritePlan = struct {
    allocator: Allocator,
    replacements: std.ArrayListUnmanaged(Replacement) = .empty,

    pub fn init(allocator: Allocator) RewritePlan {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RewritePlan) void {
        self.replacements.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *RewritePlan, replacement: Replacement) !void {
        for (self.replacements.items) |existing| {
            const disjoint = replacement.end <= existing.start or existing.end <= replacement.start;
            if (!disjoint) return error.OverlappingReplacement;
        }
        try self.replacements.append(self.allocator, replacement);
    }

    pub fn ordered(self: *const RewritePlan, allocator: Allocator) ![]Replacement {
        const result = try allocator.dupe(Replacement, self.replacements.items);
        std.mem.sort(Replacement, result, {}, struct {
            fn lessThan(_: void, lhs: Replacement, rhs: Replacement) bool {
                if (lhs.start != rhs.start) return lhs.start < rhs.start;
                return lhs.end < rhs.end;
            }
        }.lessThan);
        return result;
    }

    pub fn applyToAst(self: *const RewritePlan, ast: *Ast, allocator: Allocator) !void {
        const ordered_replacements = try self.ordered(allocator);
        defer allocator.free(ordered_replacements);

        for (ordered_replacements) |replacement| {
            const node_index = replacement.node_index orelse return error.MissingNodeIndex;
            try ast.replacement_source.put(allocator, node_index, replacement.text);
            if (replacement.needs_reindent) {
                try ast.replacement_needs_reindent.put(allocator, node_index, {});
            }
        }
    }
};
