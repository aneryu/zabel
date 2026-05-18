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

/// Lightweight structural data produced by a single DFS.
/// Used to accelerate Scope Analysis and to allow TransformSession
/// to avoid redundant structural work (Phase 3 Option A).
pub const StructuralData = struct {
    parent_map: []NodeIndex,
    function_boundary_for_node: []NodeIndex,
    /// Pre-computed during the structural pass.
    /// For each AST node, the nearest enclosing function/arrow/global/module node.
    /// This is the structural equivalent of "containing function scope" and
    /// can be used after Scope Analysis to quickly get the containing ScopeIndex.
    containing_function_node: []NodeIndex,

    /// Identifiers discovered during the structural DFS, along with their
    /// function boundary at the time of discovery. This allows TransformSession
    /// to skip re-discovering identifiers in its second pass.
    identifier_occurrences: []PrecollectedIdentifier,

    /// Pre-collected function binding name information (e.g. the "foo" in
    /// `function foo() {}`). This allows skipping `recordFunctionBindingNode`
    /// work in the second pass.
    function_binding_name_nodes: []NodeIndex,

    /// Pre-computed preorder traversal numbering (start and end) from the
    /// single structural DFS. When provided, TransformSession can skip the
    /// expensive second buildParentAndRanges DFS entirely.
    preorder_start: []u32,
    preorder_end: []u32,

    /// this_expr nodes collected during the structural DFS.
    /// Allows skipping this_expr collection in the second pass.
    this_occurrences: []NodeIndex,

    /// Pre-computed during the structural pass.
    /// Same as `function_boundary_for_node`, but also treats
    /// `.class_declaration` and `.class_expr` as boundaries.
    /// This enables O(1) "has function or class boundary between two nodes"
    /// queries, which `block_scoping` needs for correct closure extraction.
    capture_boundary_for_node: []NodeIndex,
};

pub const PrecollectedIdentifier = struct {
    node: NodeIndex,
    function_boundary: ?NodeIndex,
};

/// Information about a function binding name (e.g., the identifier "foo" in `function foo() {}`).
pub const PrecollectedFunctionBinding = struct {
    binding_name_node: NodeIndex,
    function_node: NodeIndex,
};

pub const TransformSession = struct {
    ast: *const Ast,
    scope: ?*scope_mod.ScopeResult,
    node_data_block: []u32,
    parent_map: []NodeIndex,
    preorder_start: []u32,
    preorder_end: []u32,
    function_boundary_for_node: []NodeIndex,
    capture_boundary_for_node: []NodeIndex = &.{},
    function_binding_name_node: []NodeIndex,
    resolved_binding_for_node: []u32,
    function_binding_indices: []FunctionBindingIndexMap,
    function_binding_indices_built: bool = false,
    binding_occurrences: []std.ArrayListUnmanaged(IdentifierOccurrence),
    /// Occurrences for identifiers that did not resolve to any binding
    /// (globals, free references, or when scope analysis is absent).
    unresolved_occurrences: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(IdentifierOccurrence)),
    this_occurrences: std.ArrayListUnmanaged(NodeIndex),

    /// Pre-collected identifiers from the structural pre-pass.
    /// When available, TransformSession can use this to avoid re-discovering
    /// identifiers during its own DFS.
    precollected_identifiers: []PrecollectedIdentifier = &.{},

    /// Whether parent_map was provided externally (so we can skip writing it during traversal).
    parent_map_provided: bool = false,
    /// Whether function_boundary_for_node was provided externally.
    function_boundary_provided: bool = false,
    /// Whether function binding name information was pre-collected.
    function_binding_names_provided: bool = false,
    /// Whether identifier occurrences were pre-collected (so visitNode can skip recordIdentifierOccurrence).
    identifiers_preprovided: bool = false,
    /// Whether preorder_start/preorder_end were provided (allows skipping the entire buildParentAndRanges DFS).
    preorder_provided: bool = false,
    /// Whether this_occurrences were pre-collected.
    this_occurrences_provided: bool = false,
    /// Whether capture_boundary_for_node was provided (function + class boundaries).
    capture_boundary_provided: bool = false,

    // Consolidated block layout (7 slices of node_count u32 each):
    // [parent_map | fn_boundary | fn_binding_name | resolved_binding | capture_boundary | preorder_start | preorder_end]
    // First 5 slices init to maxInt(u32), last 2 init to 0.
    const slices_with_max_init = 5;
    const total_slices = 7;

    pub fn init(allocator: Allocator, ast: *Ast, scope: ?*scope_mod.ScopeResult) !TransformSession {
        return initWithPrebuiltBoundaries(allocator, ast, scope, null);
    }

    pub fn initWithPrebuiltBoundaries(
        allocator: Allocator,
        ast: *Ast,
        scope: ?*scope_mod.ScopeResult,
        prebuilt_boundaries: ?[]const NodeIndex,
    ) !TransformSession {
        // For backward compatibility during transition
        var structural: ?StructuralData = null;
        if (prebuilt_boundaries) |b| {
            const node_count = ast.nodes.len;
            if (b.len == node_count) {
                const boundaries = try allocator.alloc(NodeIndex, node_count);
                @memcpy(boundaries, b);
                structural = .{
                    .parent_map = &.{},
                    .function_boundary_for_node = boundaries,
                    .containing_function_node = &.{},
                    .identifier_occurrences = &.{},
                    .function_binding_name_nodes = &.{},
                    .preorder_start = &.{},
                    .preorder_end = &.{},
                    .this_occurrences = &.{},
                    .capture_boundary_for_node = &.{},
                };
            }
        }
        return initWithStructuralData(allocator, ast, scope, structural);
    }

    fn freeStructuralData(allocator: Allocator, structural: StructuralData) void {
        if (structural.parent_map.len > 0) allocator.free(structural.parent_map);
        if (structural.function_boundary_for_node.len > 0) allocator.free(structural.function_boundary_for_node);
        if (structural.containing_function_node.len > 0) allocator.free(structural.containing_function_node);
        if (structural.identifier_occurrences.len > 0) allocator.free(structural.identifier_occurrences);
        if (structural.function_binding_name_nodes.len > 0) allocator.free(structural.function_binding_name_nodes);
        if (structural.preorder_start.len > 0) allocator.free(structural.preorder_start);
        if (structural.preorder_end.len > 0) allocator.free(structural.preorder_end);
        if (structural.this_occurrences.len > 0) allocator.free(structural.this_occurrences);
        if (structural.capture_boundary_for_node.len > 0) allocator.free(structural.capture_boundary_for_node);
    }

    /// Preferred entry point for Phase 3 Option A.
    /// Accepts pre-built structural data from a single DFS so that
    /// the expensive structural work can be done only once.
    pub fn initWithStructuralData(
        allocator: Allocator,
        ast: *Ast,
        scope: ?*scope_mod.ScopeResult,
        structural: ?StructuralData,
    ) !TransformSession {
        const node_count = ast.nodes.len;
        const block = try allocator.alloc(u32, total_slices * node_count);
        errdefer allocator.free(block);

        @memset(block[0 .. slices_with_max_init * node_count], std.math.maxInt(u32));
        @memset(block[slices_with_max_init * node_count ..], 0);

        var session = TransformSession{
            .ast = ast,
            .scope = scope,
            .node_data_block = block,
            .parent_map = @ptrCast(block[0..node_count]),
            .function_boundary_for_node = @ptrCast(block[node_count .. 2 * node_count]),
            .function_binding_name_node = @ptrCast(block[2 * node_count .. 3 * node_count]),
            .resolved_binding_for_node = block[3 * node_count .. 4 * node_count],
            .capture_boundary_for_node = @ptrCast(block[4 * node_count .. 5 * node_count]),
            .preorder_start = block[5 * node_count .. 6 * node_count],
            .preorder_end = block[6 * node_count .. 7 * node_count],
            .function_binding_indices = &.{},
            .binding_occurrences = &.{},
            .unresolved_occurrences = .empty,
            .this_occurrences = .empty,
            .precollected_identifiers = &.{},
        };
        errdefer session.deinit(allocator);
        var structural_freed = false;
        errdefer if (!structural_freed) {
            if (structural) |s| freeStructuralData(allocator, s);
        };

        var precollected_identifiers: []PrecollectedIdentifier = &.{};
        if (structural) |s| {
            if (s.parent_map.len == node_count) {
                @memcpy(session.parent_map, s.parent_map);
                session.parent_map_provided = true;
            }
            if (s.function_boundary_for_node.len == node_count) {
                @memcpy(session.function_boundary_for_node, s.function_boundary_for_node);
                session.function_boundary_provided = true;
            }
            if (s.function_binding_name_nodes.len == node_count) {
                @memcpy(session.function_binding_name_node, s.function_binding_name_nodes);
                session.function_binding_names_provided = true;
            }
            if (s.identifier_occurrences.len > 0) {
                session.identifiers_preprovided = true;
                precollected_identifiers = s.identifier_occurrences;
            }
            if (s.preorder_start.len == node_count and s.preorder_end.len == node_count) {
                @memcpy(session.preorder_start, s.preorder_start);
                @memcpy(session.preorder_end, s.preorder_end);
                session.preorder_provided = true;
            }
            if (s.this_occurrences.len > 0) {
                // Populate this_occurrences directly from structural data
                session.this_occurrences = .empty;
                for (s.this_occurrences) |n| {
                    try session.this_occurrences.append(allocator, n);
                }
                session.this_occurrences_provided = true;
            }
            if (s.capture_boundary_for_node.len == node_count) {
                @memcpy(session.capture_boundary_for_node, s.capture_boundary_for_node);
                session.capture_boundary_provided = true;
            }
        }

        try session.initBindingOccurrences(allocator);

        if (session.identifiers_preprovided) {
            // Temporarily assign so the existing processPrecollectedIdentifiers (which reads self.precollected_identifiers)
            // can iterate the list. We clear immediately after and free the backing memory below.
            session.precollected_identifiers = precollected_identifiers;
            try session.processPrecollectedIdentifiers(allocator);
            session.precollected_identifiers = &.{};
        }

        // Pre-size unresolved_occurrences to reduce rehashing during traversal.
        const estimated_unresolved: u32 = @intCast(@max(node_count / 32, 16));
        try session.unresolved_occurrences.ensureTotalCapacity(allocator, estimated_unresolved);

        try session.buildParentAndRanges(allocator);

        // Now that we've consumed the structural data (parent/boundary copied, identifiers processed,
        // function_binding copied), free the temporary allocations from buildStructuralData.
        // This prevents leaks and avoids dangling references when session is retained.
        if (structural) |s| {
            freeStructuralData(allocator, s);
            structural_freed = true;
        }

        return session;
    }

    pub fn deinit(self: *TransformSession, allocator: Allocator) void {
        var unresolved_iter = self.unresolved_occurrences.valueIterator();
        while (unresolved_iter.next()) |occurrences| {
            occurrences.deinit(allocator);
        }
        self.unresolved_occurrences.deinit(allocator);
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
        allocator.free(self.node_data_block);
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

    /// Returns true if `descendant` is inside the subtree rooted at `ancestor`.
    /// Uses the pre-computed preorder ranges from the single structural DFS (O(1)).
    /// Passes should prefer this over manual parent walking when a TransformSession is available.
    pub fn contains(self: *const TransformSession, ancestor: NodeIndex, descendant: NodeIndex) bool {
        const a = self.subtreeRange(ancestor);
        const d = self.subtreeRange(descendant);
        return a.start <= d.start and d.end <= a.end;
    }

    pub fn functionBoundaryOf(self: *const TransformSession, node: NodeIndex) ?NodeIndex {
        const raw = @intFromEnum(node);
        if (raw >= self.function_boundary_for_node.len) return null;
        const boundary = self.function_boundary_for_node[raw];
        if (boundary == .none) return null;
        return boundary;
    }

    /// Returns the nearest enclosing function or class node (capture boundary).
    /// This is useful for block_scoping closure detection.
    pub fn captureBoundaryOf(self: *const TransformSession, node: NodeIndex) ?NodeIndex {
        if (!self.capture_boundary_provided or self.capture_boundary_for_node.len == 0) return null;
        const raw = @intFromEnum(node);
        if (raw >= self.capture_boundary_for_node.len) return null;
        const boundary = self.capture_boundary_for_node[raw];
        if (boundary == .none) return null;
        return boundary;
    }

    /// Lightweight structural pre-pass: builds only the function boundary map.
    /// This data can be passed to Scope Analysis via AnalyzeOptions to
    /// accelerate nearestFunctionScope / crossesFunctionBoundary (Phase 3 Option A).
    pub fn buildFunctionBoundaries(allocator: Allocator, ast: *const Ast) ![]NodeIndex {
        if (ast.nodes.len == 0) return &.{};

        const node_count = ast.nodes.items(.tag).len;
        const boundaries = try allocator.alloc(NodeIndex, node_count);
        @memset(boundaries, .none);

        buildFunctionBoundariesImpl(ast, boundaries, @enumFromInt(0), .none);

        return boundaries;
    }

    /// Builds both parent_map and function_boundary_for_node in a single DFS.
    /// This is the recommended lightweight structural pre-pass for Phase 3 Option A.
    pub fn buildStructuralData(allocator: Allocator, ast: *const Ast) !StructuralData {
        if (ast.nodes.len == 0) {
            return .{
                .parent_map = &.{},
                .function_boundary_for_node = &.{},
                .containing_function_node = &.{},
                .identifier_occurrences = &.{},
                .function_binding_name_nodes = &.{},
                .preorder_start = &.{},
                .preorder_end = &.{},
                .this_occurrences = &.{},
                .capture_boundary_for_node = &.{},
            };
        }

        const node_count = ast.nodes.items(.tag).len;

        const parent_map = try allocator.alloc(NodeIndex, node_count);
        errdefer allocator.free(parent_map);
        @memset(parent_map, .none);

        const function_boundary = try allocator.alloc(NodeIndex, node_count);
        errdefer allocator.free(function_boundary);
        @memset(function_boundary, .none);

        const containing_function = try allocator.alloc(NodeIndex, node_count);
        errdefer allocator.free(containing_function);
        @memset(containing_function, .none);

        const function_binding_names = try allocator.alloc(NodeIndex, node_count);
        errdefer allocator.free(function_binding_names);
        @memset(function_binding_names, .none);

        const capture_boundary = try allocator.alloc(NodeIndex, node_count);
        errdefer allocator.free(capture_boundary);
        @memset(capture_boundary, .none);

        const preorder_start = try allocator.alloc(u32, node_count);
        errdefer allocator.free(preorder_start);
        @memset(preorder_start, 0);
        const preorder_end = try allocator.alloc(u32, node_count);
        errdefer allocator.free(preorder_end);
        @memset(preorder_end, 0);

        var identifiers: std.ArrayListUnmanaged(PrecollectedIdentifier) = .empty;
        defer identifiers.deinit(allocator);

        var this_list: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer this_list.deinit(allocator);

        var cursor: u32 = 0;
        try buildStructuralDataImpl(
            allocator,
            ast,
            parent_map,
            function_boundary,
            containing_function,
            function_binding_names,
            capture_boundary,
            &identifiers,
            preorder_start,
            preorder_end,
            &this_list,
            &cursor,
            @enumFromInt(0),
            .none,
            .none,
            .none,
        );

        const identifier_slice = try identifiers.toOwnedSlice(allocator);
        errdefer if (identifier_slice.len > 0) allocator.free(identifier_slice);
        const this_slice = try this_list.toOwnedSlice(allocator);
        errdefer if (this_slice.len > 0) allocator.free(this_slice);

        return .{
            .parent_map = parent_map,
            .function_boundary_for_node = function_boundary,
            .containing_function_node = containing_function,
            .identifier_occurrences = identifier_slice,
            .function_binding_name_nodes = function_binding_names,
            .preorder_start = preorder_start,
            .preorder_end = preorder_end,
            .this_occurrences = this_slice,
            .capture_boundary_for_node = capture_boundary,
        };
    }

    fn buildStructuralDataImpl(
        allocator: Allocator,
        ast: *const Ast,
        parent_map: []NodeIndex,
        function_boundary: []NodeIndex,
        containing_function: []NodeIndex,
        function_binding_names: []NodeIndex,
        capture_boundary: []NodeIndex,
        identifiers: *std.ArrayListUnmanaged(PrecollectedIdentifier),
        preorder_start: []u32,
        preorder_end: []u32,
        this_list: *std.ArrayListUnmanaged(NodeIndex),
        cursor: *u32,
        node: NodeIndex,
        parent: ?NodeIndex,
        current_function: ?NodeIndex,
        current_capture: ?NodeIndex,
    ) Allocator.Error!void {
        if (node == .none) return;
        const raw = @intFromEnum(node);
        if (raw >= parent_map.len) return;

        parent_map[raw] = parent orelse .none;

        const tag = ast.nodes.items(.tag)[raw];
        const next_function = if (isFunctionBoundary(tag)) node else current_function;
        function_boundary[raw] = next_function orelse .none;
        containing_function[raw] = next_function orelse .none;

        const is_class = tag == .class_declaration or tag == .class_expr;
        const next_capture = if (isFunctionBoundary(tag) or is_class) node else current_capture;
        capture_boundary[raw] = next_capture orelse .none;

        // Preorder numbering on entry (same as visitNode in TransformSession)
        preorder_start[raw] = cursor.*;
        cursor.* += 1;

        if (tag == .identifier) {
            try identifiers.append(allocator, .{
                .node = node,
                .function_boundary = next_function,
            });
        }

        if (tag == .this_expr) {
            try this_list.append(allocator, node);
        }

        // Pre-collect function binding name information (same logic as recordFunctionBindingNode)
        if (tag == .declarator or tag == .assignment_expr) {
            const data = ast.nodes.items(.data)[raw];
            const lhs = data.binary.lhs;
            const rhs = data.binary.rhs;
            if (lhs != .none and rhs != .none and
                ast.nodes.items(.tag)[@intFromEnum(lhs)] == .identifier and
                isBindableFunctionTag(ast.nodes.items(.tag)[@intFromEnum(rhs)]))
            {
                function_binding_names[@intFromEnum(rhs)] = lhs;
            }
        }

        switch (visitor.childLayout(tag)) {
            .leaf => {},
            .unary => {
                const data = ast.nodes.items(.data)[raw];
                try buildStructuralDataImpl(allocator, ast, parent_map, function_boundary, containing_function, function_binding_names, capture_boundary, identifiers, preorder_start, preorder_end, this_list, cursor, data.unary, node, next_function, next_capture);
            },
            .binary => {
                const data = ast.nodes.items(.data)[raw];
                try buildStructuralDataImpl(allocator, ast, parent_map, function_boundary, containing_function, function_binding_names, capture_boundary, identifiers, preorder_start, preorder_end, this_list, cursor, data.binary.lhs, node, next_function, next_capture);
                try buildStructuralDataImpl(allocator, ast, parent_map, function_boundary, containing_function, function_binding_names, capture_boundary, identifiers, preorder_start, preorder_end, this_list, cursor, data.binary.rhs, node, next_function, next_capture);
            },
            .binary_lhs => {
                const data = ast.nodes.items(.data)[raw];
                try buildStructuralDataImpl(allocator, ast, parent_map, function_boundary, containing_function, function_binding_names, capture_boundary, identifiers, preorder_start, preorder_end, this_list, cursor, data.binary.lhs, node, next_function, next_capture);
            },
            .complex => {
                const children = visitor.getChildren(ast, node);
                for (children.items[0..children.len]) |child| {
                    try buildStructuralDataImpl(allocator, ast, parent_map, function_boundary, containing_function, function_binding_names, capture_boundary, identifiers, preorder_start, preorder_end, this_list, cursor, child, node, next_function, next_capture);
                }
                if (children.range_start < children.range_end) {
                    for (ast.extra_data.items[children.range_start..children.range_end]) |raw_child| {
                        try buildStructuralDataImpl(allocator, ast, parent_map, function_boundary, containing_function, function_binding_names, capture_boundary, identifiers, preorder_start, preorder_end, this_list, cursor, @enumFromInt(raw_child), node, next_function, next_capture);
                    }
                }
                if (children.range2_start < children.range2_end) {
                    for (ast.extra_data.items[children.range2_start..children.range2_end]) |raw_child| {
                        try buildStructuralDataImpl(allocator, ast, parent_map, function_boundary, containing_function, function_binding_names, capture_boundary, identifiers, preorder_start, preorder_end, this_list, cursor, @enumFromInt(raw_child), node, next_function, next_capture);
                    }
                }
            },
        }

        // Preorder end after children visited (post-order numbering complete for subtree)
        preorder_end[raw] = cursor.*;
    }

    fn buildFunctionBoundariesImpl(
        ast: *const Ast,
        boundaries: []NodeIndex,
        node: NodeIndex,
        current_function: ?NodeIndex,
    ) void {
        if (node == .none) return;
        const raw = @intFromEnum(node);
        if (raw >= boundaries.len) return;

        const tag = ast.nodes.items(.tag)[raw];
        const next_function = if (isFunctionBoundary(tag)) node else current_function;

        boundaries[raw] = next_function orelse .none;

        switch (visitor.childLayout(tag)) {
            .leaf => {},
            .unary => {
                const data = ast.nodes.items(.data)[raw];
                buildFunctionBoundariesImpl(ast, boundaries, data.unary, next_function);
            },
            .binary => {
                const data = ast.nodes.items(.data)[raw];
                buildFunctionBoundariesImpl(ast, boundaries, data.binary.lhs, next_function);
                buildFunctionBoundariesImpl(ast, boundaries, data.binary.rhs, next_function);
            },
            .binary_lhs => {
                const data = ast.nodes.items(.data)[raw];
                buildFunctionBoundariesImpl(ast, boundaries, data.binary.lhs, next_function);
            },
            .complex => {
                const children = visitor.getChildren(ast, node);
                for (children.items[0..children.len]) |child| {
                    buildFunctionBoundariesImpl(ast, boundaries, child, next_function);
                }
                if (children.range_start < children.range_end) {
                    for (ast.extra_data.items[children.range_start..children.range_end]) |raw_child| {
                        buildFunctionBoundariesImpl(ast, boundaries, @enumFromInt(raw_child), next_function);
                    }
                }
                if (children.range2_start < children.range2_end) {
                    for (ast.extra_data.items[children.range2_start..children.range2_end]) |raw_child| {
                        buildFunctionBoundariesImpl(ast, boundaries, @enumFromInt(raw_child), next_function);
                    }
                }
            },
        }
    }

    pub fn identifierOccurrences(self: *const TransformSession, name: []const u8) ?[]const IdentifierOccurrence {
        // Check unresolved occurrences first (no-scope case, globals, free refs).
        if (self.unresolved_occurrences.get(name)) |occs| {
            if (occs.items.len > 0) return occs.items;
        }
        // Derive from binding_occurrences via scope's binding_name_indices.
        const scope = self.scope orelse return null;
        const binding_indices = scope.binding_name_indices.get(name) orelse return null;
        for (binding_indices.items) |idx| {
            if (idx < self.binding_occurrences.len) {
                const items = self.binding_occurrences[idx].items;
                if (items.len > 0) return items;
            }
        }
        return null;
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

    pub fn unresolvedOccurrences(self: *const TransformSession, name: []const u8) []const IdentifierOccurrence {
        const occs = self.unresolved_occurrences.get(name) orelse return &.{};
        return occs.items;
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

    pub fn functionBindingIndices(self: *TransformSession, owner_scope_idx: scope_mod.ScopeIndex, name: []const u8) ?[]const u32 {
        if (!self.function_binding_indices_built) {
            self.ensureFunctionBindingIndices() catch return null;
        }
        const owner_scope_i = @intFromEnum(owner_scope_idx);
        if (owner_scope_i >= self.function_binding_indices.len) return null;
        const indices = self.function_binding_indices[owner_scope_i].get(name) orelse return null;
        return indices.items;
    }

    fn ensureFunctionBindingIndices(self: *TransformSession) Allocator.Error!void {
        if (self.function_binding_indices_built) return;
        const scope = self.scope orelse {
            // No scope: nothing to build; mark as built so we don't repeatedly
            // re-check on every functionBindingIndices call.
            self.function_binding_indices_built = true;
            return;
        };
        const allocator = scope.allocator;
        self.function_binding_indices = try allocator.alloc(FunctionBindingIndexMap, scope.scopes.len);
        for (self.function_binding_indices) |*map| map.* = .{};
        // Mark as built before population: any partial allocations are owned
        // by `function_binding_indices` and will be cleaned up by `deinit`.
        // Without this, an OOM mid-loop would leave a partial allocation that
        // a retry call would overwrite, leaking the previous array.
        self.function_binding_indices_built = true;

        for (scope.bindings, 0..) |binding, binding_idx| {
            const owner_scope_idx = scope.containingFunctionScope(binding.scope);
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

    fn buildParentAndRanges(self: *TransformSession, allocator: Allocator) Allocator.Error!void {
        if (self.ast.nodes.len == 0) return;

        // Fast path: when full StructuralData (including preorder) was provided,
        // the expensive second DFS is completely unnecessary.
        if (self.preorder_provided) {
            // this_occurrences should already be populated in the copy block above.
            self.sortOccurrences();
            return;
        }

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

    /// Process identifiers that were pre-collected during the structural pre-pass.
    /// This allows us to avoid discovering identifiers during the main DFS.
    fn processPrecollectedIdentifiers(self: *TransformSession, allocator: Allocator) Allocator.Error!void {
        if (self.precollected_identifiers.len == 0) return;

        for (self.precollected_identifiers) |pre| {
            // Use the pre-known function_boundary from the structural pass.
            // This allows us to potentially short-circuit some visibility checks
            // inside recordIdentifierOccurrence in a future refinement.
            try self.recordIdentifierOccurrence(allocator, pre.node, pre.function_boundary);
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

        if (!self.parent_map_provided) {
            self.parent_map[raw] = parent orelse .none;
        }
        if (!self.function_boundary_provided) {
            self.function_boundary_for_node[raw] = current_function orelse .none;
        }
        self.preorder_start[raw] = cursor.*;
        cursor.* += 1;

        const tag = self.ast.nodes.items(.tag)[raw];
        if (!self.function_binding_names_provided) {
            self.recordFunctionBindingNode(node, tag);
        }
        if (tag == .identifier) {
            if (!self.identifiers_preprovided) {
                const fn_boundary = if (self.function_boundary_provided) blk: {
                    const b = self.function_boundary_for_node[raw];
                    break :blk if (b == .none) null else b;
                } else current_function;
                try self.recordIdentifierOccurrence(allocator, node, fn_boundary);
            }
            // If identifiers were preprovided, recordIdentifierOccurrence was done in processPrecollectedIdentifiers.
        } else if (tag == .this_expr) {
            try self.this_occurrences.append(allocator, node);
        }

        switch (visitor.childLayout(tag)) {
            .leaf => {},
            .unary => {
                const child_function = if (self.function_boundary_provided)
                    null
                else if (isFunctionBoundary(tag)) node else current_function;
                const data = self.ast.nodes.items(.data)[raw];
                try self.visitNode(allocator, data.unary, node, child_function, cursor);
            },
            .binary => {
                const child_function = if (self.function_boundary_provided)
                    null
                else if (isFunctionBoundary(tag)) node else current_function;
                const data = self.ast.nodes.items(.data)[raw];
                try self.visitNode(allocator, data.binary.lhs, node, child_function, cursor);
                try self.visitNode(allocator, data.binary.rhs, node, child_function, cursor);
            },
            .binary_lhs => {
                const child_function = if (self.function_boundary_provided)
                    null
                else if (isFunctionBoundary(tag)) node else current_function;
                const data = self.ast.nodes.items(.data)[raw];
                try self.visitNode(allocator, data.binary.lhs, node, child_function, cursor);
            },
            .complex => {
                const child_function = if (self.function_boundary_provided)
                    null
                else if (isFunctionBoundary(tag)) node else current_function;
                const children = visitor.getChildren(self.ast, node);
                for (children.items[0..children.len]) |child| {
                    try self.visitNode(allocator, child, node, child_function, cursor);
                }
                try self.visitRange(allocator, children.range_start, children.range_end, node, child_function, cursor);
                try self.visitRange(allocator, children.range2_start, children.range2_end, node, child_function, cursor);
            },
        }

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
        const main_token = self.ast.nodes.items(.main_token)[raw];
        const occurrence: IdentifierOccurrence = .{
            .node = node,
            .function_boundary = current_function,
            .start = self.ast.tokens.items(.start)[@intFromEnum(main_token)],
        };
        if (self.scope) |scope| {
            // Scope analysis already resolved all resolvable identifiers into
            // node_to_binding; an O(1) array read is sufficient.
            if (scope_mod.getBindingIndexForNode(scope, node)) |idx| {
                self.resolved_binding_for_node[raw] = idx;
                if (idx < self.binding_occurrences.len) {
                    try self.binding_occurrences[idx].append(allocator, occurrence);
                }
                return;
            }
        }
        // Unresolved or no scope: record in unresolved_occurrences hash map.
        const name = self.ast.tokenSlice(main_token);
        const gop = try self.unresolved_occurrences.getOrPut(allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, occurrence);
    }

    fn sortOccurrences(self: *TransformSession) void {
        sortThisOccurrencesIfNeeded(self.ast, self.this_occurrences.items);
        for (self.binding_occurrences) |*occurrences| {
            sortIdentifierOccurrencesIfNeeded(occurrences);
        }
        var unresolved_iter = self.unresolved_occurrences.valueIterator();
        while (unresolved_iter.next()) |occurrences| {
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
};
