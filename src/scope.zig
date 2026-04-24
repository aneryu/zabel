const std = @import("std");
const Ast = @import("ast.zig").Ast;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const ExtraIndex = @import("ast.zig").ExtraIndex;
const TokenIndex = @import("ast.zig").TokenIndex;
const visitor = @import("transform/visitor.zig");
const Allocator = std.mem.Allocator;

// ── Public Types ─────────────────────────────────────────────────────

pub const ScopeIndex = enum(u32) { root = 0, _ };

pub const ScopeKind = enum {
    global,
    module,
    function,
    arrow,
    block,
    class_body,
    catch_clause,
};

pub const Scope = struct {
    parent: ?ScopeIndex,
    kind: ScopeKind,
    node: NodeIndex,
    bindings_start: u32,
    bindings_end: u32,
};

pub const BindingKind = enum {
    var_decl,
    let_decl,
    const_decl,
    function_decl,
    class_decl,
    param,
    import_binding,
    catch_param,
};

pub const Binding = struct {
    name: []const u8,
    kind: BindingKind,
    scope: ScopeIndex,
    node: NodeIndex,
    decl_node: NodeIndex = .none,
    init_node: NodeIndex = .none,
    is_rest_param: bool = false,
    is_captured: bool = false,
    is_mutated: bool = false,
};

const dense_node_map_none = std.math.maxInt(u32);

fn DenseNodeMap(comptime T: type) type {
    return struct {
        const Self = @This();

        values: []u32 = &[_]u32{},

        const Entry = struct {
            key_ptr: *const u32,
            value_ptr: *const T,
        };

        const Iterator = struct {
            map: *const Self,
            index: usize = 0,
            key_storage: u32 = 0,
            value_storage: T = undefined,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.map.values.len) {
                    const idx = self.index;
                    self.index += 1;

                    const raw = self.map.values[idx];
                    if (raw == dense_node_map_none) continue;

                    self.key_storage = @intCast(idx);
                    self.value_storage = fromRaw(raw);
                    return .{
                        .key_ptr = &self.key_storage,
                        .value_ptr = &self.value_storage,
                    };
                }
                return null;
            }
        };

        fn toRaw(value: T) u32 {
            if (T == u32) return value;
            return @intFromEnum(value);
        }

        fn fromRaw(raw: u32) T {
            if (T == u32) return raw;
            return @enumFromInt(raw);
        }

        pub fn ensureNodeCount(self: *Self, allocator: Allocator, node_count: usize) Allocator.Error!void {
            if (self.values.len == node_count) return;
            if (self.values.len > 0) allocator.free(self.values);
            self.values = try allocator.alloc(u32, node_count);
            @memset(self.values, dense_node_map_none);
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.values.len > 0) allocator.free(self.values);
            self.* = .{};
        }

        pub fn get(self: *const Self, key: u32) ?T {
            if (key >= self.values.len) return null;
            const raw = self.values[key];
            if (raw == dense_node_map_none) return null;
            return fromRaw(raw);
        }

        pub fn put(self: *Self, allocator: Allocator, key: u32, value: T) Allocator.Error!void {
            _ = allocator;
            self.values[key] = toRaw(value);
        }

        /// Direct write without allocator parameter; array must already be sized.
        pub fn putDirect(self: *Self, key: u32, value: T) void {
            self.values[key] = toRaw(value);
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .map = self };
        }
    };
}

pub const ScopeResult = struct {
    scopes: []const Scope,
    bindings: []const Binding,
    binding_mutation_offsets: []const u32,
    binding_mutation_nodes: []const u32,
    binding_name_indices: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)),
    node_to_scope: DenseNodeMap(ScopeIndex),
    node_to_binding: DenseNodeMap(u32),
    /// Backing allocation for node_to_scope and node_to_binding (single block).
    dense_map_block: []u32 = &.{},
    /// Pre-computed containing function scope for each scope index.
    containing_fn_scope: []const ScopeIndex = &.{},
    allocator: Allocator,

    pub fn deinit(self: *ScopeResult) void {
        self.allocator.free(self.scopes);
        self.allocator.free(self.bindings);
        self.allocator.free(self.binding_mutation_offsets);
        self.allocator.free(self.binding_mutation_nodes);
        var binding_name_iter = self.binding_name_indices.valueIterator();
        while (binding_name_iter.next()) |indices| {
            indices.deinit(self.allocator);
        }
        self.binding_name_indices.deinit(self.allocator);
        if (self.dense_map_block.len > 0) {
            self.allocator.free(self.dense_map_block);
        } else {
            self.node_to_scope.deinit(self.allocator);
            self.node_to_binding.deinit(self.allocator);
        }
        if (self.containing_fn_scope.len > 0) self.allocator.free(self.containing_fn_scope);
    }

    pub fn containingFunctionScope(self: *const ScopeResult, scope_idx: ScopeIndex) ScopeIndex {
        const i = @intFromEnum(scope_idx);
        if (i < self.containing_fn_scope.len) return self.containing_fn_scope[i];
        return scope_idx;
    }
};

// ── Analysis Entry Point ─────────────────────────────────────────────

pub const AnalyzeOptions = struct {
    extra_globals: []const []const u8 = &.{},
};

pub fn analyze(ast: *const Ast, allocator: Allocator) !ScopeResult {
    return analyzeWithOptions(ast, allocator, .{});
}

pub fn analyzeWithOptions(ast: *const Ast, allocator: Allocator, options: AnalyzeOptions) !ScopeResult {
    var builder = Builder.init(ast, allocator, options);
    defer builder.deinit();

    try builder.run();

    // Transfer ownership of results
    const scopes = try builder.scopes.toOwnedSlice(allocator);
    const bindings = try builder.bindings.toOwnedSlice(allocator);
    const mutation_data = try builder.takeMutationData(allocator);
    const binding_name_indices = builder.binding_name_indices;
    builder.binding_name_indices = .{};
    const node_to_scope = builder.node_to_scope;
    builder.node_to_scope = .{};
    const node_to_binding = builder.node_to_binding;
    builder.node_to_binding = .{};
    const dense_map_block = builder.dense_map_block;
    builder.dense_map_block = &.{};

    // Pre-compute containing function scope for each scope.
    const containing_fn_scope = try buildContainingFnScope(allocator, scopes);

    return ScopeResult{
        .scopes = scopes,
        .bindings = bindings,
        .binding_mutation_offsets = mutation_data.offsets,
        .binding_mutation_nodes = mutation_data.nodes,
        .binding_name_indices = binding_name_indices,
        .node_to_scope = node_to_scope,
        .node_to_binding = node_to_binding,
        .dense_map_block = dense_map_block,
        .containing_fn_scope = containing_fn_scope,
        .allocator = allocator,
    };
}

fn buildContainingFnScope(allocator: Allocator, scopes: []const Scope) ![]ScopeIndex {
    const result = try allocator.alloc(ScopeIndex, scopes.len);
    for (scopes, 0..) |scope, i| {
        result[i] = switch (scope.kind) {
            .function, .arrow, .global, .module => @enumFromInt(@as(u32, @intCast(i))),
            else => if (scope.parent) |p| result[@intFromEnum(p)] else @enumFromInt(@as(u32, @intCast(i))),
        };
    }
    return result;
}

// ── Query Functions ──────────────────────────────────────────────────

pub fn getScopeForNode(result: *const ScopeResult, node: NodeIndex) ?ScopeIndex {
    return result.node_to_scope.get(@intFromEnum(node));
}

fn isScopeVisibleFrom(result: *const ScopeResult, start_scope: ScopeIndex, candidate_scope: ScopeIndex) bool {
    var current: ?ScopeIndex = start_scope;
    while (current) |scope_idx| {
        if (scope_idx == candidate_scope) return true;
        current = result.scopes[@intFromEnum(scope_idx)].parent;
    }
    return false;
}

pub fn getBinding(result: *const ScopeResult, scope_idx: ScopeIndex, name: []const u8) ?*const Binding {
    const binding_idx = getBindingIndex(result, scope_idx, name) orelse return null;
    return &result.bindings[binding_idx];
}

fn scopeDistanceToAncestor(result: *const ScopeResult, start_scope: ScopeIndex, candidate_scope: ScopeIndex) ?u32 {
    var current: ?ScopeIndex = start_scope;
    var distance: u32 = 0;
    while (current) |scope_idx| {
        if (scope_idx == candidate_scope) return distance;
        current = result.scopes[@intFromEnum(scope_idx)].parent;
        distance += 1;
    }
    return null;
}

fn bindingDeclStart(result: *const ScopeResult, binding_idx: u32) u32 {
    const binding = result.bindings[binding_idx];
    const decl_node = if (binding.decl_node != .none) binding.decl_node else binding.node;
    return @intFromEnum(decl_node);
}

fn bindingIsAvailableAtNode(result: *const ScopeResult, binding_idx: u32, node: NodeIndex) bool {
    const binding = result.bindings[binding_idx];
    const decl_start = bindingDeclStart(result, binding_idx);
    const node_start = @intFromEnum(node);
    if (decl_start <= node_start) return true;
    return switch (binding.kind) {
        .var_decl, .function_decl, .import_binding, .param, .catch_param => true,
        else => false,
    };
}

pub fn getBindingIndex(result: *const ScopeResult, scope_idx: ScopeIndex, name: []const u8) ?u32 {
    const binding_indices = result.binding_name_indices.get(name) orelse return null;
    var i = binding_indices.items.len;
    while (i > 0) {
        i -= 1;
        const binding_idx = binding_indices.items[i];
        const binding = result.bindings[binding_idx];
        if (isScopeVisibleFrom(result, scope_idx, binding.scope)) return binding_idx;
    }
    return null;
}

pub fn getBindingIndexForNode(result: *const ScopeResult, node: NodeIndex) ?u32 {
    return result.node_to_binding.get(@intFromEnum(node));
}

pub fn getBindingForNode(result: *const ScopeResult, node: NodeIndex) ?*const Binding {
    const binding_idx = getBindingIndexForNode(result, node) orelse return null;
    return &result.bindings[binding_idx];
}

pub fn resolveBindingIndexForNode(result: *const ScopeResult, node: NodeIndex, name: []const u8) ?u32 {
    const direct = getBindingIndexForNode(result, node);
    if (direct) |binding_idx| return binding_idx;

    const scope_idx = getScopeForNode(result, node) orelse return null;
    const binding_indices = result.binding_name_indices.get(name) orelse return null;

    var best_idx: ?u32 = null;
    var best_distance: u32 = std.math.maxInt(u32);
    var best_decl_start: u32 = 0;

    for (binding_indices.items) |binding_idx| {
        const binding = result.bindings[binding_idx];
        const distance = scopeDistanceToAncestor(result, scope_idx, binding.scope) orelse continue;
        if (!bindingIsAvailableAtNode(result, binding_idx, node)) continue;

        const decl_start = bindingDeclStart(result, binding_idx);
        if (best_idx == null or
            distance < best_distance or
            (distance == best_distance and decl_start >= best_decl_start))
        {
            best_idx = binding_idx;
            best_distance = distance;
            best_decl_start = decl_start;
        }
    }

    return best_idx;
}

pub fn resolveBindingForNode(result: *const ScopeResult, node: NodeIndex, name: []const u8) ?*const Binding {
    const binding_idx = resolveBindingIndexForNode(result, node, name) orelse return null;
    return &result.bindings[binding_idx];
}

pub fn getBindingMutations(result: *const ScopeResult, binding_idx: u32) []const u32 {
    if (binding_idx + 1 >= result.binding_mutation_offsets.len) return result.binding_mutation_nodes[0..0];
    const start = result.binding_mutation_offsets[binding_idx];
    const end = result.binding_mutation_offsets[binding_idx + 1];
    return result.binding_mutation_nodes[start..end];
}

pub fn isNameUsed(result: *const ScopeResult, scope_idx: ScopeIndex, name: []const u8) bool {
    return getBinding(result, scope_idx, name) != null;
}

pub fn generateUniqueName(result: *const ScopeResult, scope_idx: ScopeIndex, prefix: []const u8, allocator: Allocator) ![]const u8 {
    // Try _prefix first, then _prefix2, _prefix3, ...
    {
        const candidate = try std.fmt.allocPrint(allocator, "_{s}", .{prefix});
        if (!isNameUsedAnywhere(result, scope_idx, candidate)) return candidate;
        allocator.free(candidate);
    }
    var counter: u32 = 2;
    while (counter < 10000) : (counter += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "_{s}{d}", .{ prefix, counter });
        if (!isNameUsedAnywhere(result, scope_idx, candidate)) return candidate;
        allocator.free(candidate);
    }
    // Fallback — should never happen in practice
    return std.fmt.allocPrint(allocator, "_{s}_fallback", .{prefix});
}

/// Check if a name exists anywhere in the scope chain (up and down from the given scope).
fn isNameUsedAnywhere(result: *const ScopeResult, scope_idx: ScopeIndex, name: []const u8) bool {
    // Walk up to root, checking each scope
    if (isNameUsed(result, scope_idx, name)) return true;

    // Also check child scopes — walk all scopes and check those
    // whose parent chain includes any ancestor of scope_idx
    for (result.scopes) |s| {
        for (result.bindings[s.bindings_start..s.bindings_end]) |b| {
            if (std.mem.eql(u8, b.name, name)) return true;
        }
    }
    return false;
}

// ── Builder (internal) ───────────────────────────────────────────────

const Builder = struct {
    ast: *const Ast,
    allocator: Allocator,
    scopes: std.ArrayListUnmanaged(Scope),
    bindings: std.ArrayListUnmanaged(Binding),
    binding_mutations: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)),
    binding_name_indices: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)),
    node_to_scope: DenseNodeMap(ScopeIndex),
    node_to_binding: DenseNodeMap(u32),
    /// Single backing allocation for both DenseNodeMaps.
    dense_map_block: []u32 = &.{},
    /// Stack of scope indices during traversal
    scope_stack: std.ArrayListUnmanaged(ScopeIndex),
    options: AnalyzeOptions,

    fn init(ast: *const Ast, allocator: Allocator, options: AnalyzeOptions) Builder {
        return .{
            .ast = ast,
            .allocator = allocator,
            .scopes = .empty,
            .bindings = .empty,
            .binding_mutations = .empty,
            .binding_name_indices = .empty,
            .node_to_scope = .{},
            .node_to_binding = .{},
            .scope_stack = .empty,
            .options = options,
        };
    }

    fn deinit(self: *Builder) void {
        self.scopes.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        for (self.binding_mutations.items) |*mutations| {
            mutations.deinit(self.allocator);
        }
        self.binding_mutations.deinit(self.allocator);
        var binding_name_iter = self.binding_name_indices.valueIterator();
        while (binding_name_iter.next()) |indices| {
            indices.deinit(self.allocator);
        }
        self.binding_name_indices.deinit(self.allocator);
        if (self.dense_map_block.len > 0) {
            self.allocator.free(self.dense_map_block);
        } else {
            self.node_to_scope.deinit(self.allocator);
            self.node_to_binding.deinit(self.allocator);
        }
        self.scope_stack.deinit(self.allocator);
    }

    fn takeMutationData(self: *Builder, allocator: Allocator) !struct { offsets: []u32, nodes: []u32 } {
        const binding_count = self.binding_mutations.items.len;
        const offsets = try allocator.alloc(u32, binding_count + 1);

        var total_nodes: usize = 0;
        for (self.binding_mutations.items, 0..) |mutations, idx| {
            offsets[idx] = @intCast(total_nodes);
            total_nodes += mutations.items.len;
        }
        offsets[binding_count] = @intCast(total_nodes);

        const nodes = try allocator.alloc(u32, total_nodes);
        var write_pos: usize = 0;
        for (self.binding_mutations.items) |*mutations| {
            @memcpy(nodes[write_pos .. write_pos + mutations.items.len], mutations.items);
            write_pos += mutations.items.len;
            mutations.deinit(self.allocator);
        }

        self.binding_mutations.deinit(self.allocator);
        self.binding_mutations = .empty;

        return .{
            .offsets = offsets,
            .nodes = nodes,
        };
    }

    fn run(self: *Builder) !void {
        if (self.ast.nodes.len == 0) return;
        const node_count = self.ast.nodes.items(.tag).len;
        // Single allocation for both dense node maps.
        self.dense_map_block = try self.allocator.alloc(u32, node_count * 2);
        @memset(self.dense_map_block, dense_node_map_none);
        self.node_to_scope.values = self.dense_map_block[0..node_count];
        self.node_to_binding.values = self.dense_map_block[node_count .. node_count * 2];

        // Create root scope
        const root_kind: ScopeKind = if (self.ast.source_type == .module) .module else .global;
        _ = try self.pushScope(root_kind, @enumFromInt(0));
        try self.addSyntheticRootGlobals();

        // Traverse from program node (index 0)
        try self.visit(@enumFromInt(0));

        // Finalize the root scope's bindings_end
        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn currentScope(self: *const Builder) ScopeIndex {
        return self.scope_stack.items[self.scope_stack.items.len - 1];
    }

    fn pushScope(self: *Builder, kind: ScopeKind, node: NodeIndex) !ScopeIndex {
        const idx: ScopeIndex = @enumFromInt(@as(u32, @intCast(self.scopes.items.len)));
        const parent: ?ScopeIndex = if (self.scope_stack.items.len > 0) self.currentScope() else null;
        try self.scopes.append(self.allocator, .{
            .parent = parent,
            .kind = kind,
            .node = node,
            .bindings_start = @intCast(self.bindings.items.len),
            .bindings_end = @intCast(self.bindings.items.len),
        });
        try self.scope_stack.append(self.allocator, idx);
        self.node_to_scope.putDirect(@intFromEnum(node), idx);
        return idx;
    }

    fn finalizeCurrentScope(self: *Builder) void {
        const idx = self.currentScope();
        self.scopes.items[@intFromEnum(idx)].bindings_end = @intCast(self.bindings.items.len);
    }

    const BindingOptions = struct {
        decl_node: NodeIndex = .none,
        init_node: NodeIndex = .none,
        is_rest_param: bool = false,
    };

    fn addBinding(self: *Builder, name: []const u8, kind: BindingKind, scope_idx: ScopeIndex, node: NodeIndex, options: BindingOptions) !void {
        const binding_idx: u32 = @intCast(self.bindings.items.len);
        try self.bindings.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .scope = scope_idx,
            .node = node,
            .decl_node = if (options.decl_node != .none) options.decl_node else node,
            .init_node = options.init_node,
            .is_rest_param = options.is_rest_param,
        });
        try self.binding_mutations.append(self.allocator, .empty);

        var gop = try self.binding_name_indices.getOrPut(self.allocator, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, binding_idx);
        if (node != .none) {
            self.node_to_binding.putDirect(@intFromEnum(node), binding_idx);
        }
    }

    fn addSyntheticRootGlobals(self: *Builder) !void {
        if (self.options.extra_globals.len == 0) return;
        const root_scope = self.currentScope();
        for (self.options.extra_globals) |name| {
            if (name.len == 0) continue;
            if (self.hasBindingInScope(root_scope, name)) continue;
            try self.addBinding(name, .var_decl, root_scope, .none, .{});
        }
    }

    fn hasBindingInScope(self: *const Builder, scope_idx: ScopeIndex, name: []const u8) bool {
        for (self.bindings.items) |binding| {
            if (binding.scope == scope_idx and std.mem.eql(u8, binding.name, name)) return true;
        }
        return false;
    }

    /// Find the nearest function-level scope (function, arrow, global, module) walking up from current.
    fn nearestFunctionScope(self: *const Builder) ScopeIndex {
        var i: usize = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const idx = self.scope_stack.items[i];
            const kind = self.scopes.items[@intFromEnum(idx)].kind;
            switch (kind) {
                .function, .arrow, .global, .module => return idx,
                else => {},
            }
        }
        return self.scope_stack.items[0]; // root
    }

    /// Check if an identifier node is across a function boundary from the binding scope.
    fn crossesFunctionBoundary(self: *const Builder, binding_scope: ScopeIndex) bool {
        // Walk up from current scope to binding_scope; if we pass a function/arrow scope, it's captured
        var i: usize = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const idx = self.scope_stack.items[i];
            if (@intFromEnum(idx) == @intFromEnum(binding_scope)) return false;
            const kind = self.scopes.items[@intFromEnum(idx)].kind;
            switch (kind) {
                .function, .arrow => return true,
                else => {},
            }
        }
        return false;
    }

    fn isScopeVisibleFromCurrent(self: *const Builder, candidate_scope: ScopeIndex) bool {
        var current: ?ScopeIndex = self.currentScope();
        while (current) |scope_idx| {
            if (scope_idx == candidate_scope) return true;
            current = self.scopes.items[@intFromEnum(scope_idx)].parent;
        }
        return false;
    }

    fn findVisibleBindingIndex(self: *const Builder, name: []const u8) ?u32 {
        const binding_indices = self.binding_name_indices.get(name) orelse return null;
        var i = binding_indices.items.len;
        while (i > 0) {
            i -= 1;
            const binding_idx = binding_indices.items[i];
            if (self.isScopeVisibleFromCurrent(self.bindings.items[binding_idx].scope)) return binding_idx;
        }
        return null;
    }

    fn visit(self: *Builder, idx: NodeIndex) Allocator.Error!void {
        if (idx == .none) return;
        const i = @intFromEnum(idx);
        const tags = self.ast.nodes.items(.tag);
        if (i >= tags.len) return;
        const tag = tags[i];
        if (tag == .removed) return;

        // Map this node to the current scope
        self.node_to_scope.putDirect(i, self.currentScope());

        // Leaf tags have no children; only .identifier needs binding resolution.
        if (visitor.isLeafTag(tag)) {
            if (tag == .identifier) self.visitIdentifierRef(idx);
            return;
        }

        const data = self.ast.nodes.items(.data)[i];

        switch (tag) {
            // ── Scope-creating nodes ─────────────────────────────────

            .program => try self.visitProgram(idx, data),

            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            => try self.visitFunctionDecl(idx, data),

            .function_expr => try self.visitFunctionExpr(idx, data),
            .arrow_function_expr => try self.visitArrowFunction(idx, data),

            .class_declaration => try self.visitClassDecl(idx, data),
            .class_expr => try self.visitClassExpr(idx, data),

            .block_statement => try self.visitBlockStatement(idx, data),

            .for_statement => try self.visitForStatement(idx, data),
            .for_in_statement,
            .for_of_statement,
            .for_of_await_statement,
            => try self.visitForInOfStatement(idx, data),

            .switch_statement => try self.visitSwitchStatement(idx, data),

            .catch_clause => try self.visitCatchClause(idx, data),

            .class_body => try self.visitClassBody(idx, data),

            // ── Declaration nodes (register bindings) ────────────────

            .var_declaration => try self.visitVarDeclaration(idx, data, .var_decl),
            .let_declaration => try self.visitVarDeclaration(idx, data, .let_decl),
            .const_declaration => try self.visitVarDeclaration(idx, data, .const_decl),

            .import_declaration,
            .import_declaration_type,
            .import_declaration_typeof,
            => try self.visitImportDeclaration(idx, data),

            // ── Assignment targets ───────────────────────────────────

            .assignment_expr => try self.visitAssignment(idx, data),

            .update_expr => try self.visitUpdate(idx, data),

            .property => try self.visitProperty(data),

            .class_field, .class_private_field => try self.visitClassField(data),

            // ── Method definitions (have params creating scopes) ─────

            .method_definition,
            .computed_method,
            .class_method,
            .class_private_method,
            => try self.visitMethodLike(idx, data),

            .getter, .setter => try self.visitGetterSetter(idx, data),

            // ── Default: recurse into children ───────────────────────
            else => try self.visitChildren(idx),
        }
    }

    fn visitProperty(self: *Builder, data: Node.Data) !void {
        // Non-computed object property keys are names, not identifier references.
        // The value side still contains runtime references in both object literals
        // and object-pattern assignment targets.
        try self.visit(data.binary.rhs);
    }

    fn visitClassField(self: *Builder, data: Node.Data) !void {
        const extra_idx = @intFromEnum(data.extra);
        const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const value: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const flags = if (extra_idx + 2 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 2]
        else
            0;
        const is_computed = (flags & 2) != 0;
        if (is_computed) {
            try self.visit(key);
        }
        try self.visit(value);
    }

    // ── Visitor Helpers ──────────────────────────────────────────────

    fn visitChildren(self: *Builder, idx: NodeIndex) !void {
        const children = visitor.getChildren(self.ast, idx);

        for (children.items[0..children.len]) |child| {
            try self.visit(child);
        }

        if (children.range_end > children.range_start) {
            for (self.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                try self.visit(@enumFromInt(raw));
            }
        }

        if (children.range2_end > children.range2_start) {
            for (self.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                try self.visit(@enumFromInt(raw));
            }
        }
    }

    fn visitProgram(self: *Builder, _: NodeIndex, data: Node.Data) !void {
        const extra_idx = @intFromEnum(data.extra);
        const range_start = self.ast.extra_data.items[extra_idx];
        const range_end = self.ast.extra_data.items[extra_idx + 1];

        try self.predeclareVarBindingsInRange(range_start, range_end);

        if (range_end > range_start) {
            for (self.ast.extra_data.items[range_start..range_end]) |raw| {
                try self.visit(@enumFromInt(raw));
            }
        }
    }

    fn visitFunctionDecl(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        const extra_idx = @intFromEnum(data.extra);
        const name_token_raw = self.ast.extra_data.items[extra_idx];

        // Register function name in nearest function scope (hoisted)
        if (name_token_raw != 0 and name_token_raw != @intFromEnum(NodeIndex.none)) {
            const name = self.ast.tokenSlice(@enumFromInt(name_token_raw));
            const fn_scope = self.nearestFunctionScope();
            try self.addBinding(name, .function_decl, fn_scope, idx, .{ .decl_node = idx });
        }

        // Create new function scope
        _ = try self.pushScope(.function, idx);

        // Register params
        const params_start = self.ast.extra_data.items[extra_idx + 1];
        const params_end = self.ast.extra_data.items[extra_idx + 2];
        try self.registerParams(params_start, params_end);

        // Visit body
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
        try self.visitBlockBody(body);

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitFunctionExpr(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        const extra_idx = @intFromEnum(data.extra);

        // Create new function scope
        _ = try self.pushScope(.function, idx);

        // Optional name — binds in function's own scope (NFE)
        const name_token_raw = self.ast.extra_data.items[extra_idx];
        if (name_token_raw != 0 and name_token_raw != @intFromEnum(NodeIndex.none)) {
            const name = self.ast.tokenSlice(@enumFromInt(name_token_raw));
            try self.addBinding(name, .function_decl, self.currentScope(), idx, .{ .decl_node = idx });
        }

        // Register params
        const params_start = self.ast.extra_data.items[extra_idx + 1];
        const params_end = self.ast.extra_data.items[extra_idx + 2];
        try self.registerParams(params_start, params_end);

        // Visit body
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
        try self.visitBlockBody(body);

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitArrowFunction(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        const extra_idx = @intFromEnum(data.extra);

        // Create new arrow scope
        _ = try self.pushScope(.arrow, idx);

        // Detect old vs new format (same heuristic as visitor.zig)
        if (extra_idx + 2 < self.ast.extra_data.items.len) {
            const first = self.ast.extra_data.items[extra_idx];
            const second = self.ast.extra_data.items[extra_idx + 1];
            const third = self.ast.extra_data.items[extra_idx + 2];

            if (first == @intFromEnum(NodeIndex.none) or third == 1) {
                // Old format: param, body, count
                const param_node: NodeIndex = @enumFromInt(first);
                if (param_node != .none) {
                    try self.collectBindingNames(param_node, .param);
                }
                const body: NodeIndex = @enumFromInt(second);
                try self.visit(body);
            } else {
                // New format: range_start, range_end, body
                try self.registerParams(first, second);
                const body: NodeIndex = @enumFromInt(third);
                try self.visit(body);
            }
        }

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitClassDecl(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        const extra_idx = @intFromEnum(data.extra);
        const name_token_raw = self.ast.extra_data.items[extra_idx];

        // Register class name in current block scope
        if (name_token_raw != 0 and name_token_raw != @intFromEnum(NodeIndex.none)) {
            const name = self.ast.tokenSlice(@enumFromInt(name_token_raw));
            try self.addBinding(name, .class_decl, self.currentScope(), idx, .{ .decl_node = idx });
        }

        // Visit super class
        const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        try self.visit(super_class);

        // Visit body (class_body will create its own scope)
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
        try self.visit(body);
    }

    fn visitClassExpr(self: *Builder, _: NodeIndex, data: Node.Data) !void {
        const extra_idx = @intFromEnum(data.extra);

        // Visit super class
        const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        try self.visit(super_class);

        // Visit body
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
        try self.visit(body);
    }

    fn visitClassBody(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        _ = try self.pushScope(.class_body, idx);

        // class_body: extra[0]=range_start, extra[1]=range_end
        const extra_idx = @intFromEnum(data.extra);
        const range_start = self.ast.extra_data.items[extra_idx];
        const range_end = self.ast.extra_data.items[extra_idx + 1];

        if (range_end > range_start) {
            for (self.ast.extra_data.items[range_start..range_end]) |raw| {
                try self.visit(@enumFromInt(raw));
            }
        }

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitBlockStatement(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        // Only skip creating a new block scope if this block IS the direct body
        // of a function (not a nested block within a function).
        const parent_creates_scope = blk: {
            if (self.scope_stack.items.len < 2) break :blk false;
            const parent_scope = self.scopes.items[@intFromEnum(self.currentScope())];
            if (parent_scope.node == .none) break :blk false;
            const parent_node = parent_scope.node;
            const parent_tag = self.ast.nodes.items(.tag)[@intFromEnum(parent_node)];
            // Check if this block is the DIRECT body of a function
            switch (parent_tag) {
                .function_declaration,
                .async_function_declaration,
                .generator_declaration,
                .async_generator_declaration,
                .function_expr,
                => {
                    // extra[3] = body node
                    const fn_extra = @intFromEnum(self.ast.nodes.items(.data)[@intFromEnum(parent_node)].extra);
                    if (fn_extra + 3 < self.ast.extra_data.items.len) {
                        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[fn_extra + 3]);
                        break :blk body == idx;
                    }
                    break :blk false;
                },
                .arrow_function_expr => {
                    const fn_extra = @intFromEnum(self.ast.nodes.items(.data)[@intFromEnum(parent_node)].extra);
                    if (fn_extra + 2 < self.ast.extra_data.items.len) {
                        const first = self.ast.extra_data.items[fn_extra];
                        const second = self.ast.extra_data.items[fn_extra + 1];
                        const third = self.ast.extra_data.items[fn_extra + 2];
                        if (first == @intFromEnum(NodeIndex.none) or third == 1) {
                            break :blk @as(NodeIndex, @enumFromInt(second)) == idx;
                        } else {
                            break :blk @as(NodeIndex, @enumFromInt(third)) == idx;
                        }
                    }
                    break :blk false;
                },
                .method_definition,
                .computed_method,
                .class_method,
                .class_private_method,
                => {
                    // extra[3] = body (for methods)
                    const fn_extra = @intFromEnum(self.ast.nodes.items(.data)[@intFromEnum(parent_node)].extra);
                    if (fn_extra + 3 < self.ast.extra_data.items.len) {
                        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[fn_extra + 3]);
                        break :blk body == idx;
                    }
                    break :blk false;
                },
                .getter, .setter => {
                    // getter/setter: extra[2] = body
                    const fn_extra = @intFromEnum(self.ast.nodes.items(.data)[@intFromEnum(parent_node)].extra);
                    if (fn_extra + 2 < self.ast.extra_data.items.len) {
                        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[fn_extra + 2]);
                        break :blk body == idx;
                    }
                    break :blk false;
                },
                else => break :blk false,
            }
        };

        if (!parent_creates_scope) {
            _ = try self.pushScope(.block, idx);
        }

        const extra_idx = @intFromEnum(data.extra);
        const range_start = self.ast.extra_data.items[extra_idx];
        const range_end = self.ast.extra_data.items[extra_idx + 1];

        try self.predeclareVarBindingsInRange(range_start, range_end);

        if (range_end > range_start) {
            for (self.ast.extra_data.items[range_start..range_end]) |raw| {
                try self.visit(@enumFromInt(raw));
            }
        }

        if (!parent_creates_scope) {
            self.finalizeCurrentScope();
            _ = self.scope_stack.pop();
        }
    }

    fn visitForStatement(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        _ = try self.pushScope(.block, idx);

        const extra_idx = @intFromEnum(data.extra);
        const init_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const test_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const update_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
        const body_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);

        try self.visit(init_node);
        try self.visit(test_node);
        try self.visit(update_node);
        try self.visit(body_node);

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitForInOfStatement(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        _ = try self.pushScope(.block, idx);

        const extra_idx = @intFromEnum(data.extra);
        const left_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const right_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const body_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

        // `for (x in/of y)` mutates an existing binding on each iteration.
        // Declarations like `for (const x of y)` are handled by visitVarDeclaration.
        if (left_node != .none) {
            const left_i = @intFromEnum(left_node);
            if (left_i < self.ast.nodes.items(.tag).len and self.ast.nodes.items(.tag)[left_i] == .identifier) {
                const mt = self.ast.nodes.items(.main_token)[left_i];
                const name = self.ast.tokenSlice(mt);
                self.markMutated(name, idx);
            }
        }

        try self.visit(left_node);
        try self.visit(right_node);
        try self.visit(body_node);

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitSwitchStatement(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        // switch_statement: extra[0]=discriminant, [1]=cases_start, [2]=cases_end
        // Switch bodies create a single block scope for all let/const declarations
        // across all case clauses.
        const extra_idx = @intFromEnum(data.extra);
        const discriminant: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const cases_start = self.ast.extra_data.items[extra_idx + 1];
        const cases_end = self.ast.extra_data.items[extra_idx + 2];

        // Visit discriminant in the current scope
        try self.visit(discriminant);

        // Push a block scope for the switch body
        _ = try self.pushScope(.block, idx);

        // Visit all case clauses within this scope
        if (cases_end > cases_start) {
            for (self.ast.extra_data.items[cases_start..cases_end]) |raw| {
                try self.visit(@enumFromInt(raw));
            }
        }

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitCatchClause(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        _ = try self.pushScope(.catch_clause, idx);

        // catch_clause: binary.lhs = param, binary.rhs = body
        const param_node = data.binary.lhs;
        if (param_node != .none) {
            try self.collectBindingNames(param_node, .catch_param);
        }

        // Visit body (block_statement)
        try self.visit(data.binary.rhs);

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitVarDeclaration(self: *Builder, _: NodeIndex, data: Node.Data, kind: BindingKind) !void {
        // var/let/const: extra[0]=declarators_start, extra[1]=declarators_end
        const extra_idx = @intFromEnum(data.extra);
        const decls_start = self.ast.extra_data.items[extra_idx];
        const decls_end = self.ast.extra_data.items[extra_idx + 1];

        if (decls_end > decls_start) {
            for (self.ast.extra_data.items[decls_start..decls_end]) |raw| {
                const decl_idx: NodeIndex = @enumFromInt(raw);
                if (decl_idx == .none) continue;
                const decl_i = @intFromEnum(decl_idx);
                if (decl_i >= self.ast.nodes.items(.tag).len) continue;
                const decl_tag = self.ast.nodes.items(.tag)[decl_i];
                if (decl_tag != .declarator) continue;

                const decl_data = self.ast.nodes.items(.data)[decl_i];
                // declarator: binary.lhs = binding pattern, binary.rhs = init
                const binding_node = decl_data.binary.lhs;

                // For var: register in nearest function scope (hoisted)
                // For let/const: register in current scope
                const target_scope = if (kind == .var_decl) self.nearestFunctionScope() else self.currentScope();
                try self.ensureBindingNamesInScope(binding_node, kind, target_scope, .{
                    .decl_node = decl_idx,
                    .init_node = decl_data.binary.rhs,
                });

                // Visit the initializer
                try self.visit(decl_data.binary.rhs);
            }
        }
    }

    fn visitImportDeclaration(self: *Builder, _: NodeIndex, data: Node.Data) !void {
        // import_declaration: extra[0]=source_token, [1]=specs_start, [2]=specs_end
        const extra_idx = @intFromEnum(data.extra);
        const specs_start = self.ast.extra_data.items[extra_idx + 1];
        const specs_end = self.ast.extra_data.items[extra_idx + 2];

        if (specs_end > specs_start) {
            for (self.ast.extra_data.items[specs_start..specs_end]) |raw| {
                const spec_idx: NodeIndex = @enumFromInt(raw);
                if (spec_idx == .none) continue;
                const spec_i = @intFromEnum(spec_idx);
                if (spec_i >= self.ast.nodes.items(.tag).len) continue;
                const spec_tag = self.ast.nodes.items(.tag)[spec_i];

                switch (spec_tag) {
                    .import_specifier, .import_specifier_type, .import_specifier_typeof => {
                        // import_specifier: extra[0]=imported_token, extra[1]=local_token
                        const spec_data = self.ast.nodes.items(.data)[spec_i];
                        const spec_extra = @intFromEnum(spec_data.extra);
                        const local_token_raw = self.ast.extra_data.items[spec_extra + 1];
                        if (local_token_raw != 0) {
                            const name = self.ast.tokenSlice(@enumFromInt(local_token_raw));
                            // Module scope for imports
                            try self.addBinding(name, .import_binding, self.scope_stack.items[0], spec_idx, .{ .decl_node = spec_idx });
                        }
                    },
                    .import_default => {
                        // import_default: main_token = local name
                        const mt = self.ast.nodes.items(.main_token)[spec_i];
                        const name = self.ast.tokenSlice(mt);
                        try self.addBinding(name, .import_binding, self.scope_stack.items[0], spec_idx, .{ .decl_node = spec_idx });
                    },
                    .import_namespace => {
                        // import_namespace: main_token = local name (the `foo` in `* as foo`)
                        const mt = self.ast.nodes.items(.main_token)[spec_i];
                        const name = self.ast.tokenSlice(mt);
                        try self.addBinding(name, .import_binding, self.scope_stack.items[0], spec_idx, .{ .decl_node = spec_idx });
                    },
                    else => {},
                }
            }
        }
    }

    fn visitMethodLike(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        // method_definition / computed_method / class_method / class_private_method:
        //   extra[0]=key, [1]=params_start, [2]=params_end, [3]=body
        const extra_idx = @intFromEnum(data.extra);
        const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const tag = self.ast.nodes.items(.tag)[@intFromEnum(idx)];
        const flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 4]
        else
            0;
        const is_computed = switch (tag) {
            .computed_method => true,
            .class_method, .class_private_method => (flags & 2) != 0,
            else => false,
        };
        if (is_computed) {
            try self.visit(key);
        }

        _ = try self.pushScope(.function, idx);

        const params_start = self.ast.extra_data.items[extra_idx + 1];
        const params_end = self.ast.extra_data.items[extra_idx + 2];
        try self.registerParams(params_start, params_end);

        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
        try self.visitBlockBody(body);

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitGetterSetter(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        // getter/setter: extra[0]=params_start, [1]=params_end, [2]=body, [3]=flags, [4]=computed_key
        const extra_idx = @intFromEnum(data.extra);

        _ = try self.pushScope(.function, idx);

        const params_start = self.ast.extra_data.items[extra_idx];
        const params_end = self.ast.extra_data.items[extra_idx + 1];
        try self.registerParams(params_start, params_end);

        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
        try self.visitBlockBody(body);

        self.finalizeCurrentScope();
        _ = self.scope_stack.pop();
    }

    fn visitIdentifierRef(self: *Builder, idx: NodeIndex) void {
        const i = @intFromEnum(idx);
        const mt = self.ast.nodes.items(.main_token)[i];
        const name = self.ast.tokenSlice(mt);

        const binding_idx = self.findVisibleBindingIndex(name) orelse return;
        self.node_to_binding.putDirect(i, binding_idx);
        if (self.crossesFunctionBoundary(self.bindings.items[binding_idx].scope)) {
            self.bindings.items[binding_idx].is_captured = true;
        }
    }

    fn visitAssignment(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        // assignment_expr: binary.lhs = target, binary.rhs = value
        // Mark the target as mutated if it's an identifier
        const target = data.binary.lhs;
        if (target != .none) {
            const target_i = @intFromEnum(target);
            if (target_i < self.ast.nodes.items(.tag).len) {
                const target_tag = self.ast.nodes.items(.tag)[target_i];
                if (target_tag == .identifier) {
                    const mt = self.ast.nodes.items(.main_token)[target_i];
                    const name = self.ast.tokenSlice(mt);
                    self.markMutated(name, idx);
                }
            }
        }
        // Visit both sides
        try self.visit(data.binary.lhs);
        try self.visit(data.binary.rhs);
    }

    fn visitUpdate(self: *Builder, idx: NodeIndex, data: Node.Data) !void {
        // update_expr: unary = argument
        const arg = data.unary;
        if (arg != .none) {
            const arg_i = @intFromEnum(arg);
            if (arg_i < self.ast.nodes.items(.tag).len) {
                const arg_tag = self.ast.nodes.items(.tag)[arg_i];
                if (arg_tag == .identifier) {
                    const mt = self.ast.nodes.items(.main_token)[arg_i];
                    const name = self.ast.tokenSlice(mt);
                    self.markMutated(name, idx);
                }
            }
        }
        try self.visit(data.unary);
    }

    fn markMutated(self: *Builder, name: []const u8, mutation_node: NodeIndex) void {
        const binding_idx = self.findVisibleBindingIndex(name) orelse return;
        self.bindings.items[binding_idx].is_mutated = true;
        self.binding_mutations.items[binding_idx].append(self.allocator, @intFromEnum(mutation_node)) catch {};
    }

    // ── Binding Name Collection ──────────────────────────────────────

    fn registerParams(self: *Builder, params_start: u32, params_end: u32) !void {
        if (params_end <= params_start) return;
        for (self.ast.extra_data.items[params_start..params_end]) |raw| {
            const param_idx: NodeIndex = @enumFromInt(raw);
            try self.collectBindingNames(param_idx, .param);
        }
    }

    fn predeclareVarBindingsInRange(self: *Builder, range_start: u32, range_end: u32) !void {
        if (range_end <= range_start) return;
        for (self.ast.extra_data.items[range_start..range_end]) |raw| {
            const stmt: NodeIndex = @enumFromInt(raw);
            if (stmt == .none) continue;
            const stmt_i = @intFromEnum(stmt);
            if (stmt_i >= self.ast.nodes.items(.tag).len) continue;

            const stmt_tag = self.ast.nodes.items(.tag)[stmt_i];
            const stmt_data = self.ast.nodes.items(.data)[stmt_i];
            switch (stmt_tag) {
                .var_declaration => try self.predeclareVarDeclaration(stmt_data, .var_decl),
                .let_declaration => try self.predeclareVarDeclaration(stmt_data, .let_decl),
                .const_declaration => try self.predeclareVarDeclaration(stmt_data, .const_decl),
                else => {},
            }
        }
    }

    fn predeclareVarDeclaration(self: *Builder, data: Node.Data, kind: BindingKind) !void {
        const extra_idx = @intFromEnum(data.extra);
        const decls_start = self.ast.extra_data.items[extra_idx];
        const decls_end = self.ast.extra_data.items[extra_idx + 1];

        if (decls_end <= decls_start) return;
        for (self.ast.extra_data.items[decls_start..decls_end]) |raw| {
            const decl_idx: NodeIndex = @enumFromInt(raw);
            if (decl_idx == .none) continue;
            const decl_i = @intFromEnum(decl_idx);
            if (decl_i >= self.ast.nodes.items(.tag).len) continue;
            if (self.ast.nodes.items(.tag)[decl_i] != .declarator) continue;

            const decl_data = self.ast.nodes.items(.data)[decl_i];
            const binding_node = decl_data.binary.lhs;
            const target_scope = if (kind == .var_decl) self.nearestFunctionScope() else self.currentScope();
            try self.ensureBindingNamesInScope(binding_node, kind, target_scope, .{
                .decl_node = decl_idx,
                .init_node = decl_data.binary.rhs,
            });
        }
    }

    /// Collect binding names from a pattern node and register them in the current scope.
    fn collectBindingNames(self: *Builder, node: NodeIndex, kind: BindingKind) !void {
        try self.ensureBindingNamesInScope(node, kind, self.currentScope(), .{});
    }

    /// Collect binding names from a pattern node and register them in the specified scope.
    fn ensureBindingNamesInScope(self: *Builder, node: NodeIndex, kind: BindingKind, target_scope: ScopeIndex, options: BindingOptions) !void {
        if (node == .none) return;
        const i = @intFromEnum(node);
        const tags = self.ast.nodes.items(.tag);
        if (i >= tags.len) return;
        const tag = tags[i];
        const data = self.ast.nodes.items(.data)[i];

        switch (tag) {
            .identifier => {
                const mt = self.ast.nodes.items(.main_token)[i];
                const name = self.ast.tokenSlice(mt);
                if (self.findBindingInScopeIndex(target_scope, name, kind)) |binding_idx| {
                    self.mergeBindingOptions(binding_idx, options);
                } else {
                    try self.addBinding(name, kind, target_scope, node, options);
                }
            },
            .array_pattern => {
                // extra[0]=range_start, extra[1]=range_end
                const extra_idx = @intFromEnum(data.extra);
                const range_start = self.ast.extra_data.items[extra_idx];
                const range_end = self.ast.extra_data.items[extra_idx + 1];
                if (range_end > range_start) {
                    for (self.ast.extra_data.items[range_start..range_end]) |raw| {
                        try self.ensureBindingNamesInScope(@enumFromInt(raw), kind, target_scope, options);
                    }
                }
            },
            .object_pattern => {
                // extra[0]=range_start, extra[1]=range_end
                const extra_idx = @intFromEnum(data.extra);
                const range_start = self.ast.extra_data.items[extra_idx];
                const range_end = self.ast.extra_data.items[extra_idx + 1];
                if (range_end > range_start) {
                    for (self.ast.extra_data.items[range_start..range_end]) |raw| {
                        const prop_idx: NodeIndex = @enumFromInt(raw);
                        if (prop_idx == .none) continue;
                        const prop_i = @intFromEnum(prop_idx);
                        if (prop_i >= tags.len) continue;
                        const prop_tag = tags[prop_i];
                        const prop_data = self.ast.nodes.items(.data)[prop_i];

                        switch (prop_tag) {
                            .property, .computed_property => {
                                // key=lhs, value=rhs — the value is the binding pattern
                                try self.ensureBindingNamesInScope(prop_data.binary.rhs, kind, target_scope, options);
                            },
                            .shorthand_property => {
                                // shorthand_property: unary = value (the identifier)
                                try self.ensureBindingNamesInScope(prop_data.unary, kind, target_scope, options);
                            },
                            .rest_element => {
                                var rest_options = options;
                                rest_options.is_rest_param = rest_options.is_rest_param or kind == .param;
                                try self.ensureBindingNamesInScope(prop_data.unary, kind, target_scope, rest_options);
                            },
                            else => {
                                // Might be assignment_pattern or identifier directly
                                try self.ensureBindingNamesInScope(prop_idx, kind, target_scope, options);
                            },
                        }
                    }
                }
            },
            .assignment_pattern => {
                // assignment_pattern: binary.lhs = left pattern, binary.rhs = default value
                try self.ensureBindingNamesInScope(data.binary.lhs, kind, target_scope, options);
            },
            .rest_element => {
                // rest_element: unary = argument
                var rest_options = options;
                rest_options.is_rest_param = rest_options.is_rest_param or kind == .param;
                try self.ensureBindingNamesInScope(data.unary, kind, target_scope, rest_options);
            },
            .ts_parameter_property => {
                // ts_parameter_property: extra[0]=parameter(node), [1]=flags
                const extra_idx = @intFromEnum(data.extra);
                const param_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
                try self.ensureBindingNamesInScope(param_node, kind, target_scope, options);
            },
            else => {},
        }
    }

    fn mergeBindingOptions(self: *Builder, binding_idx: u32, options: BindingOptions) void {
        if (binding_idx >= self.bindings.items.len) return;
        const binding = &self.bindings.items[binding_idx];
        if (binding.decl_node == .none and options.decl_node != .none) binding.decl_node = options.decl_node;
        if (binding.init_node == .none and options.init_node != .none) binding.init_node = options.init_node;
        if (options.is_rest_param) binding.is_rest_param = true;
    }

    fn findBindingInScopeIndex(self: *const Builder, scope_idx: ScopeIndex, name: []const u8, kind: BindingKind) ?u32 {
        const binding_indices = self.binding_name_indices.get(name) orelse return null;
        for (binding_indices.items) |binding_idx| {
            const binding = self.bindings.items[binding_idx];
            if (binding.scope == scope_idx and binding.kind == kind) return binding_idx;
        }
        return null;
    }

    /// Visit block body without creating a new scope (the function scope was already created).
    fn visitBlockBody(self: *Builder, body: NodeIndex) !void {
        if (body == .none) return;
        const i = @intFromEnum(body);
        if (i >= self.ast.nodes.items(.tag).len) return;
        try self.visit(body);
    }
};
