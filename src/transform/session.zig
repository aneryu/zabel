const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const scope_mod = @import("../scope.zig");
const visitor = @import("visitor.zig");

const Allocator = std.mem.Allocator;
const FunctionBindingIndexMap = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32));
const resolved_binding_none = std.math.maxInt(u32);

pub const SubtreeRange = struct {
    start: u32,
    end: u32,
};

pub const IdentifierOccurrence = struct {
    node: NodeIndex,
    function_boundary: ?NodeIndex,
    start: u32,
};

pub const TransformSession = struct {
    ast: *const Ast,
    scope: ?*scope_mod.ScopeResult,
    parent_map: []NodeIndex,
    preorder_start: []u32,
    preorder_end: []u32,
    function_boundary_for_node: []NodeIndex,
    function_binding_name_node: []NodeIndex,
    resolved_binding_for_node: []u32,
    function_binding_indices: []FunctionBindingIndexMap,
    binding_occurrences: []std.ArrayListUnmanaged(IdentifierOccurrence),
    identifier_occurrences: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(IdentifierOccurrence)),
    this_occurrences: std.ArrayListUnmanaged(NodeIndex),

    pub fn init(allocator: Allocator, ast: *Ast, scope: ?*scope_mod.ScopeResult) !TransformSession {
        const node_count = ast.nodes.len;
        var session = TransformSession{
            .ast = ast,
            .scope = scope,
            .parent_map = try allocator.alloc(NodeIndex, node_count),
            .preorder_start = try allocator.alloc(u32, node_count),
            .preorder_end = try allocator.alloc(u32, node_count),
            .function_boundary_for_node = try allocator.alloc(NodeIndex, node_count),
            .function_binding_name_node = try allocator.alloc(NodeIndex, node_count),
            .resolved_binding_for_node = try allocator.alloc(u32, node_count),
            .function_binding_indices = &.{},
            .binding_occurrences = &.{},
            .identifier_occurrences = .empty,
            .this_occurrences = .empty,
        };
        errdefer session.deinit(allocator);

        @memset(session.parent_map, .none);
        @memset(session.preorder_start, 0);
        @memset(session.preorder_end, 0);
        @memset(session.function_boundary_for_node, .none);
        @memset(session.function_binding_name_node, .none);
        @memset(session.resolved_binding_for_node, resolved_binding_none);
        try session.initBindingOccurrences(allocator);

        try session.buildParentAndRanges(allocator);
        try session.buildFunctionBindingIndices(allocator);
        return session;
    }

    pub fn deinit(self: *TransformSession, allocator: Allocator) void {
        var occurrence_iter = self.identifier_occurrences.valueIterator();
        while (occurrence_iter.next()) |occurrences| {
            occurrences.deinit(allocator);
        }
        self.identifier_occurrences.deinit(allocator);
        self.this_occurrences.deinit(allocator);
        for (self.function_binding_indices) |*map| {
            var binding_iter = map.valueIterator();
            while (binding_iter.next()) |indices| {
                indices.deinit(allocator);
            }
            map.deinit(allocator);
        }
        if (self.function_binding_indices.len > 0) allocator.free(self.function_binding_indices);
        for (self.binding_occurrences) |*occurrences| {
            occurrences.deinit(allocator);
        }
        if (self.binding_occurrences.len > 0) allocator.free(self.binding_occurrences);
        allocator.free(self.parent_map);
        allocator.free(self.preorder_start);
        allocator.free(self.preorder_end);
        allocator.free(self.function_boundary_for_node);
        allocator.free(self.function_binding_name_node);
        allocator.free(self.resolved_binding_for_node);
        self.* = undefined;
    }

    pub fn parentOf(self: *const TransformSession, node: NodeIndex) ?NodeIndex {
        const raw = @intFromEnum(node);
        if (raw >= self.parent_map.len) return null;
        const parent = self.parent_map[raw];
        if (parent == .none) return null;
        return parent;
    }

    pub fn subtreeRange(self: *const TransformSession, node: NodeIndex) SubtreeRange {
        const raw = @intFromEnum(node);
        if (raw >= self.preorder_start.len) return .{ .start = 0, .end = 0 };
        return .{
            .start = self.preorder_start[raw],
            .end = self.preorder_end[raw],
        };
    }

    pub fn functionBoundaryOf(self: *const TransformSession, node: NodeIndex) ?NodeIndex {
        const raw = @intFromEnum(node);
        if (raw >= self.function_boundary_for_node.len) return null;
        const boundary = self.function_boundary_for_node[raw];
        if (boundary == .none) return null;
        return boundary;
    }

    pub fn identifierOccurrences(self: *const TransformSession, name: []const u8) ?[]const IdentifierOccurrence {
        const occurrences = self.identifier_occurrences.get(name) orelse return null;
        return occurrences.items;
    }

    pub fn thisOccurrences(self: *const TransformSession) []const NodeIndex {
        return self.this_occurrences.items;
    }

    pub fn bindingIndices(self: *const TransformSession, name: []const u8) ?[]const u32 {
        const scope = self.scope orelse return null;
        const indices = scope.binding_name_indices.get(name) orelse return null;
        return indices.items;
    }

    pub fn bindingOccurrences(self: *const TransformSession, binding_idx: u32) []const IdentifierOccurrence {
        if (binding_idx >= self.binding_occurrences.len) return &.{};
        return self.binding_occurrences[binding_idx].items;
    }

    pub fn resolvedBindingIndexFor(self: *const TransformSession, node: NodeIndex) ?u32 {
        const raw = @intFromEnum(node);
        if (raw >= self.resolved_binding_for_node.len) return null;
        const binding_idx = self.resolved_binding_for_node[raw];
        return if (binding_idx == resolved_binding_none) null else binding_idx;
    }

    pub fn functionBindingNode(self: *const TransformSession, node: NodeIndex) ?NodeIndex {
        const raw = @intFromEnum(node);
        if (raw >= self.function_binding_name_node.len) return null;
        const binding_node = self.function_binding_name_node[raw];
        if (binding_node == .none) return null;
        return binding_node;
    }

    pub fn functionBindingIndices(self: *const TransformSession, owner_scope_idx: scope_mod.ScopeIndex, name: []const u8) ?[]const u32 {
        const owner_scope_i = @intFromEnum(owner_scope_idx);
        if (owner_scope_i >= self.function_binding_indices.len) return null;
        const indices = self.function_binding_indices[owner_scope_i].get(name) orelse return null;
        return indices.items;
    }

    fn buildParentAndRanges(self: *TransformSession, allocator: Allocator) Allocator.Error!void {
        if (self.ast.nodes.len == 0) return;

        var cursor: u32 = 0;
        try self.visitNode(allocator, @enumFromInt(0), null, null, &cursor);

        if (cursor < self.ast.nodes.len) {
            for (0..self.ast.nodes.len) |raw| {
                if (self.preorder_end[raw] != 0) continue;
                try self.visitNode(allocator, @enumFromInt(raw), null, null, &cursor);
            }
        }

        self.sortOccurrences();
    }

    fn initBindingOccurrences(self: *TransformSession, allocator: Allocator) Allocator.Error!void {
        const scope = self.scope orelse return;
        self.binding_occurrences = try allocator.alloc(std.ArrayListUnmanaged(IdentifierOccurrence), scope.bindings.len);
        for (self.binding_occurrences) |*occurrences| occurrences.* = .empty;
    }

    fn buildFunctionBindingIndices(self: *TransformSession, allocator: Allocator) Allocator.Error!void {
        const scope = self.scope orelse return;
        self.function_binding_indices = try allocator.alloc(FunctionBindingIndexMap, scope.scopes.len);
        for (self.function_binding_indices) |*map| map.* = .{};

        for (scope.bindings, 0..) |binding, binding_idx| {
            const owner_scope_idx = containingFunctionScope(scope, binding.scope);
            const owner_scope_i = @intFromEnum(owner_scope_idx);
            if (owner_scope_i >= self.function_binding_indices.len) continue;

            const map = &self.function_binding_indices[owner_scope_i];
            const gop = try map.getOrPut(allocator, binding.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(allocator, @intCast(binding_idx));
        }
    }

    fn visitNode(
        self: *TransformSession,
        allocator: Allocator,
        node: NodeIndex,
        parent: ?NodeIndex,
        current_function: ?NodeIndex,
        cursor: *u32,
    ) Allocator.Error!void {
        if (node == .none) return;

        const raw = @intFromEnum(node);
        if (raw >= self.ast.nodes.len) return;
        if (self.preorder_end[raw] != 0) return;

        self.parent_map[raw] = parent orelse .none;
        self.function_boundary_for_node[raw] = current_function orelse .none;
        self.preorder_start[raw] = cursor.*;
        cursor.* += 1;

        const tag = self.ast.nodes.items(.tag)[raw];
        self.recordFunctionBindingNode(node, tag);
        if (tag == .identifier) {
            try self.recordIdentifierOccurrence(allocator, node, current_function);
        } else if (tag == .this_expr) {
            try self.this_occurrences.append(allocator, node);
        }

        const child_function = if (isFunctionBoundary(tag)) node else current_function;
        const children = visitor.getChildren(self.ast, node);
        for (children.items[0..children.len]) |child| {
            try self.visitNode(allocator, child, node, child_function, cursor);
        }

        try self.visitRange(allocator, children.range_start, children.range_end, node, child_function, cursor);
        try self.visitRange(allocator, children.range2_start, children.range2_end, node, child_function, cursor);

        self.preorder_end[raw] = cursor.*;
    }

    fn visitRange(
        self: *TransformSession,
        allocator: Allocator,
        start: u32,
        end: u32,
        parent: NodeIndex,
        current_function: ?NodeIndex,
        cursor: *u32,
    ) Allocator.Error!void {
        if (end <= start) return;
        for (self.ast.extra_data.items[start..end]) |raw_child| {
            if (raw_child == @intFromEnum(NodeIndex.none)) continue;
            if (raw_child >= self.ast.nodes.len) continue;
            try self.visitNode(allocator, @enumFromInt(raw_child), parent, current_function, cursor);
        }
    }

    fn recordIdentifierOccurrence(
        self: *TransformSession,
        allocator: Allocator,
        node: NodeIndex,
        current_function: ?NodeIndex,
    ) Allocator.Error!void {
        const raw = @intFromEnum(node);
        const name = self.ast.tokenSlice(self.ast.nodes.items(.main_token)[raw]);
        const gop = try self.identifier_occurrences.getOrPut(allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        const occurrence: IdentifierOccurrence = .{
            .node = node,
            .function_boundary = current_function,
            .start = self.ast.tokens.items(.start)[@intFromEnum(self.ast.nodes.items(.main_token)[raw])],
        };
        try gop.value_ptr.append(allocator, occurrence);
        if (self.scope) |scope| {
            if (scope_mod.resolveBindingIndexForNode(scope, node, name)) |binding_idx| {
                self.resolved_binding_for_node[raw] = binding_idx;
                if (binding_idx < self.binding_occurrences.len) {
                    try self.binding_occurrences[binding_idx].append(allocator, occurrence);
                }
            }
        }
    }

    fn sortOccurrences(self: *TransformSession) void {
        var occurrence_iter = self.identifier_occurrences.valueIterator();
        while (occurrence_iter.next()) |occurrences| {
            sortIdentifierOccurrencesIfNeeded(occurrences);
        }
        sortThisOccurrencesIfNeeded(self.ast, self.this_occurrences.items);
        for (self.binding_occurrences) |*occurrences| {
            sortIdentifierOccurrencesIfNeeded(occurrences);
        }
    }

    fn sortIdentifierOccurrencesIfNeeded(occurrences: *std.ArrayListUnmanaged(IdentifierOccurrence)) void {
        if (identifierOccurrencesAreSorted(occurrences.items)) return;
        std.mem.sort(IdentifierOccurrence, occurrences.items, {}, struct {
            fn lessThan(_: void, lhs: IdentifierOccurrence, rhs: IdentifierOccurrence) bool {
                if (lhs.start != rhs.start) return lhs.start < rhs.start;
                return @intFromEnum(lhs.node) < @intFromEnum(rhs.node);
            }
        }.lessThan);
    }

    fn identifierOccurrencesAreSorted(items: []const IdentifierOccurrence) bool {
        if (items.len < 2) return true;
        for (items[1..], items[0 .. items.len - 1]) |current, previous| {
            if (current.start < previous.start) return false;
            if (current.start == previous.start and @intFromEnum(current.node) < @intFromEnum(previous.node)) {
                return false;
            }
        }
        return true;
    }

    fn sortThisOccurrencesIfNeeded(ast: *const Ast, items: []NodeIndex) void {
        if (thisOccurrencesAreSorted(ast, items)) return;
        std.mem.sort(NodeIndex, items, ast, struct {
            fn lessThan(ast_ctx: *const Ast, lhs: NodeIndex, rhs: NodeIndex) bool {
                const lhs_start = ast_ctx.tokens.items(.start)[@intFromEnum(ast_ctx.nodes.items(.main_token)[@intFromEnum(lhs)])];
                const rhs_start = ast_ctx.tokens.items(.start)[@intFromEnum(ast_ctx.nodes.items(.main_token)[@intFromEnum(rhs)])];
                if (lhs_start != rhs_start) return lhs_start < rhs_start;
                return @intFromEnum(lhs) < @intFromEnum(rhs);
            }
        }.lessThan);
    }

    fn thisOccurrencesAreSorted(ast: *const Ast, items: []const NodeIndex) bool {
        if (items.len < 2) return true;
        for (items[1..], items[0 .. items.len - 1]) |current, previous| {
            const previous_start = ast.tokens.items(.start)[@intFromEnum(ast.nodes.items(.main_token)[@intFromEnum(previous)])];
            const current_start = ast.tokens.items(.start)[@intFromEnum(ast.nodes.items(.main_token)[@intFromEnum(current)])];
            if (current_start < previous_start) return false;
            if (current_start == previous_start and @intFromEnum(current) < @intFromEnum(previous)) {
                return false;
            }
        }
        return true;
    }

    fn recordFunctionBindingNode(self: *TransformSession, node: NodeIndex, tag: Node.Tag) void {
        switch (tag) {
            .declarator, .assignment_expr => {},
            else => return,
        }

        const data = self.ast.nodes.items(.data)[@intFromEnum(node)];
        const lhs = data.binary.lhs;
        const rhs = data.binary.rhs;
        if (lhs == .none or rhs == .none) return;
        if (self.ast.nodes.items(.tag)[@intFromEnum(lhs)] != .identifier) return;

        const rhs_tag = self.ast.nodes.items(.tag)[@intFromEnum(rhs)];
        if (!isBindableFunctionTag(rhs_tag)) return;
        self.function_binding_name_node[@intFromEnum(rhs)] = lhs;
    }

    fn isFunctionBoundary(tag: Node.Tag) bool {
        return switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .arrow_function_expr,
            .method_definition,
            .computed_method,
            .class_method,
            .class_private_method,
            .getter,
            .setter,
            => true,
            else => false,
        };
    }

    fn isBindableFunctionTag(tag: Node.Tag) bool {
        return switch (tag) {
            .arrow_function_expr,
            .function_expr,
            => true,
            else => false,
        };
    }

    fn containingFunctionScope(result: *const scope_mod.ScopeResult, scope_idx: scope_mod.ScopeIndex) scope_mod.ScopeIndex {
        var current: ?scope_mod.ScopeIndex = scope_idx;
        while (current) |idx| {
            const scope = result.scopes[@intFromEnum(idx)];
            switch (scope.kind) {
                .function, .arrow, .global, .module => return idx,
                else => current = scope.parent,
            }
        }
        return scope_idx;
    }
};
