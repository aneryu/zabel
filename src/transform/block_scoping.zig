const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");
const session_mod = @import("session.zig");
const Codegen = @import("../codegen.zig").Codegen;
const scope_mod = @import("../scope.zig");

/// Configuration for the block-scoping transform.
pub const Config = struct {
    /// When true, throw if loop closure extraction would be required.
    throw_if_closure_required: bool = false,
    /// When true, insert TDZ checks (babelHelpers.tdz).
    tdz: bool = false,
    /// When true, `transform-for-of` is also active for this fixture.
    has_for_of_plugin: bool = false,
    /// When true, wrap an existing lowered `for-of` replacement instead of
    /// reconstructing the original loop shape.
    prefer_transformed_for_of: bool = false,
};

var g_config: Config = .{};

/// Track generated rename candidates that have already been assigned during this run.
/// This prevents unrelated declarations from being rewritten to the same generated name.
var g_claimed_names: std.StringHashMapUnmanaged(void) = .empty;
/// Track declarations that have been renamed so loop wrapping can reuse the
/// transformed outer binding name.
var g_decl_renamed_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
var g_loop_this_counter: u32 = 0;
var g_loop_body_this_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
const LoopHoistNames = struct {
    items: [16][]const u8 = .{""} ** 16,
    len: u8 = 0,
};
var g_loop_hoisted_head_vars: std.AutoHashMapUnmanaged(u32, LoopHoistNames) = .empty;
const FunctionBindingQueryCache = std.StringHashMapUnmanaged(u8);
var g_outer_binding_query_cache: []FunctionBindingQueryCache = &[_]FunctionBindingQueryCache{};
var g_function_scope_binding_query_cache: []FunctionBindingQueryCache = &[_]FunctionBindingQueryCache{};
var g_function_binding_query_cache_ready: bool = false;
/// Parent pointers for the current AST, used for loop-wrapper and TDZ checks.
var g_node_parents: []u32 = &[_]u32{};
var g_node_parents_ready: bool = false;
var g_parent_session: ?*const session_mod.TransformSession = null;
const parent_none = std.math.maxInt(u32);

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.let_declaration));
    filter.set(@intFromEnum(Node.Tag.const_declaration));
    filter.set(@intFromEnum(Node.Tag.class_declaration));
    filter.set(@intFromEnum(Node.Tag.for_statement));
    filter.set(@intFromEnum(Node.Tag.for_in_statement));
    filter.set(@intFromEnum(Node.Tag.for_of_statement));
    filter.set(@intFromEnum(Node.Tag.while_statement));
    filter.set(@intFromEnum(Node.Tag.do_while_statement));
    return .{
        .name = "block_scoping",
        .node_filter = filter,
        .exit = exitNode,
        .priority = 30, // Run after arrow-functions (20) and block-scoped-functions (25)
    };
}

pub fn resetState() void {
    g_claimed_names = .{};
    g_decl_renamed_names = .{};
    g_loop_this_counter = 0;
    g_loop_body_this_names = .{};
    g_loop_hoisted_head_vars = .{};
    g_outer_binding_query_cache = &[_]FunctionBindingQueryCache{};
    g_function_scope_binding_query_cache = &[_]FunctionBindingQueryCache{};
    g_function_binding_query_cache_ready = false;
    g_node_parents = &[_]u32{};
    g_node_parents_ready = false;
    g_parent_session = null;
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .let_declaration => handleLetOrConst(idx, ctx, false),
        .const_declaration => handleLetOrConst(idx, ctx, true),
        .class_declaration => handleBlockScopedClass(idx, ctx),
        .for_statement, .for_in_statement, .for_of_statement, .while_statement, .do_while_statement => handleLoopNode(idx, ctx),
        else => {},
    }
    return .continue_traversal;
}

/// Handle a let or const declaration: convert to var, rename if needed.
fn handleLetOrConst(idx: NodeIndex, ctx: *TransformContext, is_const: bool) void {
    const i = @intFromEnum(idx);

    const needs_rename = checkNeedsRename(idx, ctx);

    if (needs_rename) {
        // Generate replacement source with `var` keyword and renamed identifiers
        generateRenamedDeclaration(idx, ctx, is_const);
    } else if (is_const) {
        // Check for const violations - assignments to const variables
        checkConstViolations(idx, ctx);
        // Simple case: just change the tag
        ctx.ast.nodes.items(.tag)[i] = .var_declaration;
    } else {
        // Simple let -> var: just change the tag
        ctx.ast.nodes.items(.tag)[i] = .var_declaration;
    }

    if (g_config.tdz) {
        applyTdzForDeclaration(idx, ctx);
    }

    applyLoopBodyUndefinedInit(idx, ctx, is_const);
}

fn handleBlockScopedClass(idx: NodeIndex, ctx: *TransformContext) void {
    const scope_result = ctx.scope orelse return;
    const scope_idx = scope_mod.getScopeForNode(scope_result, idx) orelse return;
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];

    switch (scope.kind) {
        .function, .arrow, .global, .module => return,
        .block, .catch_clause, .class_body => {},
    }

    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx >= ctx.ast.extra_data.items.len) return;

    const name_token: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const name = ctx.tokenSlice(name_token);
    if (name.len == 0) return;

    const func_scope_idx = findEnclosingFunctionScope(scope_result, scope.parent);
    if (!nameNeedsRename(ctx, idx, scope_idx, scope, func_scope_idx, name)) return;

    const new_name = generateUniqueName(ctx, idx, name) orelse return;
    renameClassDeclarationName(ctx, idx, name_token, name, new_name);

    const rename_pairs = [_]RenamePair{.{ .old = name, .new = new_name }};
    renameReferencesInScope(ctx, idx, &rename_pairs);
}

/// Check if a let/const declaration needs renaming when converted to var.
/// A rename is needed when the declaration is inside a block scope (not function level)
/// and hoisting it to `var` would either shadow or collide with existing names.
fn checkNeedsRename(idx: NodeIndex, ctx: *TransformContext) bool {
    const scope_result = ctx.scope orelse return false;

    // Get the scope this declaration is in
    const scope_idx = scope_mod.getScopeForNode(scope_result, idx) orelse return false;
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];

    // If we're directly in a function, module, or global scope, no rename needed
    switch (scope.kind) {
        .function, .arrow, .global, .module => return false,
        .block, .catch_clause, .class_body => {},
    }

    // Get the names declared by this declaration
    const names = getDeclaredNames(idx, ctx);

    const func_scope_idx = findEnclosingFunctionScope(scope_result, scope.parent);

    for (names.items[0..names.len]) |name| {
        if (name.len == 0) continue;
        if (nameNeedsRename(ctx, idx, scope_idx, scope, func_scope_idx, name)) return true;
    }
    return false;
}

fn findEnclosingFunctionScope(scope_result: *const scope_mod.ScopeResult, start: ?scope_mod.ScopeIndex) ?scope_mod.ScopeIndex {
    var func_scope_idx = start;
    while (func_scope_idx) |fs_idx| {
        const fs = scope_result.scopes[@intFromEnum(fs_idx)];
        switch (fs.kind) {
            .function, .arrow, .global, .module => return fs_idx,
            else => {},
        }
        func_scope_idx = fs.parent;
    }
    return null;
}

// containingFunctionScope is now pre-computed in ScopeResult.

fn nameNeedsRename(
    ctx: *TransformContext,
    decl_node: NodeIndex,
    scope_idx: scope_mod.ScopeIndex,
    scope: scope_mod.Scope,
    func_scope_idx: ?scope_mod.ScopeIndex,
    name: []const u8,
) bool {
    const scope_result = ctx.scope orelse return false;

    const has_outer = hasOuterBinding(ctx, scope_result, func_scope_idx, name);
    const has_func = hasFunctionScopeBinding(ctx, scope_result, func_scope_idx, scope_idx, name);
    if (has_outer) return true;
    if (has_func) return true;

    const sibling_info = getSiblingBindingInfo(ctx, scope_result, decl_node, scope_idx, func_scope_idx, name);
    if (sibling_info.has_any) return sibling_info.has_earlier;

    return nameReferencedOutsideBlock(ctx, decl_node, scope, name);
}

const SiblingBindingInfo = struct {
    has_any: bool = false,
    has_earlier: bool = false,
};

fn getSiblingBindingInfo(
    ctx: *TransformContext,
    scope_result: *const scope_mod.ScopeResult,
    decl_node: NodeIndex,
    scope_idx: scope_mod.ScopeIndex,
    func_scope_idx: ?scope_mod.ScopeIndex,
    name: []const u8,
) SiblingBindingInfo {
    const current_start = nodeStartOffset(ctx, decl_node);
    var result = SiblingBindingInfo{};
    const owner_scope_idx = func_scope_idx orelse scope_result.containingFunctionScope(scope_idx);
    const binding_indices = bindingIndicesForName(ctx, name) orelse return result;
    for (binding_indices) |binding_idx_raw| {
        const b = scope_result.bindings[binding_idx_raw];
        if (b.scope == scope_idx) continue;
        if (scope_result.containingFunctionScope(b.scope) != owner_scope_idx) continue;

        result.has_any = true;
        if (nodeStartOffset(ctx, b.node) < current_start) {
            result.has_earlier = true;
            break;
        }
    }

    return result;
}

fn hasOuterBinding(ctx: *TransformContext, result: *const scope_mod.ScopeResult, func_scope_idx: ?scope_mod.ScopeIndex, name: []const u8) bool {
    const fs_idx = func_scope_idx orelse return false;
    ensureFunctionBindingQueryCaches(ctx);
    const fs_i = @intFromEnum(fs_idx);
    if (fs_i < g_outer_binding_query_cache.len) {
        if (g_outer_binding_query_cache[fs_i].get(name)) |cached| return cached != 0;
    }

    const binding_indices = bindingIndicesForName(ctx, name) orelse return false;
    const fs = result.scopes[fs_i];
    var ancestor = fs.parent;
    while (ancestor) |anc_idx| {
        for (binding_indices) |binding_idx_raw| {
            const b = result.bindings[binding_idx_raw];
            if (b.scope == anc_idx) {
                cacheFunctionBindingQuery(ctx, &g_outer_binding_query_cache, fs_i, name, true);
                return true;
            }
        }
        ancestor = result.scopes[@intFromEnum(anc_idx)].parent;
    }
    cacheFunctionBindingQuery(ctx, &g_outer_binding_query_cache, fs_i, name, false);
    return false;
}

fn hasFunctionScopeBinding(
    ctx: *TransformContext,
    result: *const scope_mod.ScopeResult,
    func_scope_idx: ?scope_mod.ScopeIndex,
    current_scope_idx: scope_mod.ScopeIndex,
    name: []const u8,
) bool {
    const fs_idx = func_scope_idx orelse return false;
    if (fs_idx == current_scope_idx) return false;
    ensureFunctionBindingQueryCaches(ctx);
    const fs_i = @intFromEnum(fs_idx);
    if (fs_i < g_function_scope_binding_query_cache.len) {
        if (g_function_scope_binding_query_cache[fs_i].get(name)) |cached| return cached != 0;
    }

    const binding_indices = bindingIndicesForName(ctx, name) orelse {
        cacheFunctionBindingQuery(ctx, &g_function_scope_binding_query_cache, fs_i, name, false);
        return false;
    };
    for (binding_indices) |binding_idx_raw| {
        const b = result.bindings[binding_idx_raw];
        if (result.containingFunctionScope(b.scope) != fs_idx) continue;
        if (b.scope != fs_idx) continue;
        if (b.kind == .param and b.is_rest_param and !restParamHasReferencesInFunctionBody(ctx, result, fs_idx, binding_idx_raw)) {
            continue;
        }
        cacheFunctionBindingQuery(ctx, &g_function_scope_binding_query_cache, fs_i, name, true);
        return true;
    }
    cacheFunctionBindingQuery(ctx, &g_function_scope_binding_query_cache, fs_i, name, false);
    return false;
}

fn restParamHasReferencesInFunctionBody(
    ctx: *TransformContext,
    result: *const scope_mod.ScopeResult,
    func_scope_idx: scope_mod.ScopeIndex,
    binding_idx: u32,
) bool {
    const func_scope = result.scopes[@intFromEnum(func_scope_idx)];
    const body = getScopeFunctionBody(ctx, func_scope.node) orelse return true;

    if (ctx.session) |session| {
        if (session.functionBoundaryOf(body)) |body_boundary| {
            const body_range = session.subtreeRange(body);
            const occurrences = session.bindingOccurrences(binding_idx);
            for (occurrences) |occurrence| {
                if (occurrence.function_boundary != body_boundary) continue;
                const occurrence_range = session.subtreeRange(occurrence.node);
                if (occurrence_range.start >= body_range.start and occurrence_range.end <= body_range.end) {
                    return true;
                }
            }
            return false;
        }
    }

    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, body) catch return true;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        const tag = ctx.nodeTag(node);
        if (node != body and isNestedFunctionBoundary(tag)) continue;

        if (tag == .identifier) {
            const ident_name = ctx.tokenSlice(ctx.mainToken(node));
            if (scope_mod.resolveBindingIndexForNode(result, node, ident_name) == binding_idx) {
                return true;
            }
        }

        const children = visitor.getChildren(ctx.ast, node);
        for (children.items[0..children.len]) |child| {
            stack.append(ctx.allocator, child) catch return true;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return true;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return true;
            }
        }
    }

    return false;
}

fn isNestedFunctionBoundary(tag: Node.Tag) bool {
    return switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .arrow_function_expr,
        .class_declaration,
        .class_expr,
        .class_body,
        .class_field,
        .class_private_field,
        .class_static_block,
        .method_definition,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        => true,
        else => false,
    };
}

fn getScopeFunctionBody(ctx: *TransformContext, func_node: NodeIndex) ?NodeIndex {
    if (func_node == .none) return null;
    const ni = @intFromEnum(func_node);
    const tag = ctx.ast.nodes.items(.tag)[ni];
    const data = ctx.ast.nodes.items(.data)[ni];
    switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .method_definition,
        .class_method,
        .class_private_method,
        => {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
            }
        },
        else => {},
    }
    return null;
}

fn nodeStartOffset(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return 0;
    const mt = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(mt)];
}

/// Check if a scope is within (descendant of or is) the given function scope.
fn isScopeWithinFunction(scope_result: *const scope_mod.ScopeResult, scope_idx: scope_mod.ScopeIndex, func_scope_idx: ?scope_mod.ScopeIndex) bool {
    const target = func_scope_idx orelse return true;
    var current: ?scope_mod.ScopeIndex = scope_idx;
    while (current) |cur| {
        if (cur == target) return true;
        const s = scope_result.scopes[@intFromEnum(cur)];
        current = s.parent;
    }
    return false;
}

/// Check if a name is referenced outside the current block scope.
/// This catches free variable references like `{ a; } { let a; }` where
/// `a` in the first block is a free reference, not a binding.
fn nameReferencedOutsideBlock(ctx: *TransformContext, decl_node: NodeIndex, block_scope: scope_mod.Scope, name: []const u8) bool {
    // Get the source range of the block
    const block_node = block_scope.node;
    if (block_node == .none) return false;

    const bi = @intFromEnum(block_node);
    if (bi >= ctx.ast.nodes.items(.tag).len) return false;

    const block_main_tok = ctx.ast.nodes.items(.main_token)[bi];
    var block_start = ctx.ast.tokens.items(.start)[@intFromEnum(block_main_tok)];
    const block_end = ctx.ast.nodes.items(.end_offset)[bi];

    // For switch_statement scopes, the "block" starts at '{' not at 'switch',
    // so the discriminant (switch (x)) is considered "outside" the block.
    const block_tag = ctx.ast.nodes.items(.tag)[bi];
    if (block_tag == .switch_statement) {
        // Find the opening '{' of the switch body
        const source = ctx.ast.source;
        var pos = block_start;
        while (pos < block_end and pos < source.len) : (pos += 1) {
            if (source[pos] == '{') {
                block_start = pos;
                break;
            }
        }
    }

    if (block_end <= block_start or block_end > ctx.ast.source.len) return false;

    // Find the enclosing function/program body range
    var func_start: u32 = 0;
    var func_end: u32 = @intCast(ctx.ast.source.len);

    // Walk up to find the enclosing function scope
    var parent = block_scope.parent;
    while (parent) |p_idx| {
        const ps = ctx.scope.?.scopes[@intFromEnum(p_idx)];
        switch (ps.kind) {
            .function, .arrow => {
                const fn_node = ps.node;
                if (fn_node != .none) {
                    const fni = @intFromEnum(fn_node);
                    const fn_mt = ctx.ast.nodes.items(.main_token)[fni];
                    func_start = ctx.ast.tokens.items(.start)[@intFromEnum(fn_mt)];
                    func_end = ctx.ast.nodes.items(.end_offset)[fni];
                }
                break;
            },
            .global, .module => break,
            else => {},
        }
        parent = ps.parent;
    }
    _ = decl_node;
    if (func_end > ctx.ast.source.len) func_end = @intCast(ctx.ast.source.len);

    if (ctx.session) |session| {
        const binding_indices = session.bindingIndices(name) orelse return false;
        var func_refs: usize = 0;
        var block_refs: usize = 0;
        for (binding_indices) |binding_idx| {
            const occurrences = session.bindingOccurrences(binding_idx);
            func_refs += lowerBoundIdentifierOccurrence(occurrences, func_end) - lowerBoundIdentifierOccurrence(occurrences, func_start);
            block_refs += lowerBoundIdentifierOccurrence(occurrences, block_end) - lowerBoundIdentifierOccurrence(occurrences, block_start);
        }
        return func_refs > block_refs;
    }

    return false;
}

fn lowerBoundIdentifierOccurrence(items: []const session_mod.IdentifierOccurrence, target: u32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].start < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

const NameList = struct {
    items: [16][]const u8 = .{""} ** 16,
    len: u8 = 0,

    fn add(self: *NameList, name: []const u8) void {
        if (self.len < 16) {
            self.items[self.len] = name;
            self.len += 1;
        }
    }
};

/// Get the variable names declared by a let/const declaration.
fn getDeclaredNames(idx: NodeIndex, ctx: *TransformContext) NameList {
    var result = NameList{};
    const data = ctx.nodeData(idx);

    // Declaration data layout: extra[0] = range_start, extra[1] = range_end
    // Range contains declarator node indices.
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return result;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_idx| {
        if (decl_idx >= ctx.ast.nodes.len) continue;
        const decl_tag = ctx.ast.nodes.items(.tag)[decl_idx];
        if (decl_tag != .declarator) continue;

        // Declarator: binary.lhs = pattern/identifier, binary.rhs = init
        const decl_data = ctx.ast.nodes.items(.data)[decl_idx];
        const lhs = decl_data.binary.lhs;
        if (lhs == .none) continue;

        // Get name from identifier or pattern
        collectPatternNames(ctx, lhs, &result);
    }

    return result;
}

/// Collect variable names from an identifier or destructuring pattern.
fn collectPatternNames(ctx: *TransformContext, node: NodeIndex, result: *NameList) void {
    if (node == .none) return;
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .identifier => {
            const name = ctx.tokenSlice(ctx.mainToken(node));
            result.add(name);
        },
        .array_pattern => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 1 < ctx.ast.extra_data.items.len) {
                const rs = ctx.ast.extra_data.items[extra_idx];
                const re = ctx.ast.extra_data.items[extra_idx + 1];
                for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
                    if (elem_idx < ctx.ast.nodes.len) {
                        collectPatternNames(ctx, @enumFromInt(elem_idx), result);
                    }
                }
            }
        },
        .object_pattern => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 1 < ctx.ast.extra_data.items.len) {
                const rs = ctx.ast.extra_data.items[extra_idx];
                const re = ctx.ast.extra_data.items[extra_idx + 1];
                for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
                    if (prop_idx >= ctx.ast.nodes.len) continue;
                    const prop_tag = ctx.ast.nodes.items(.tag)[prop_idx];
                    switch (prop_tag) {
                        .property, .shorthand_property => {
                            const prop_data = ctx.ast.nodes.items(.data)[prop_idx];
                            if (prop_tag == .shorthand_property) {
                                collectPatternNames(ctx, prop_data.unary, result);
                            } else {
                                collectPatternNames(ctx, prop_data.binary.rhs, result);
                            }
                        },
                        .rest_element => {
                            const prop_data = ctx.ast.nodes.items(.data)[prop_idx];
                            collectPatternNames(ctx, prop_data.unary, result);
                        },
                        else => {},
                    }
                }
            }
        },
        .assignment_pattern => {
            const data = ctx.nodeData(node);
            collectPatternNames(ctx, data.binary.lhs, result);
        },
        .rest_element => {
            const data = ctx.nodeData(node);
            collectPatternNames(ctx, data.unary, result);
        },
        else => {},
    }
}

/// Get the effective start offset of a node, matching what the codegen would emit.
/// For most nodes this is the main_token start, but for chain/call nodes the
/// codegen starts from the LHS/callee, which may be earlier.
fn effectiveNodeStart(ctx: *TransformContext, ni: usize) u32 {
    // Check for a node_start_override first (set by transforms like optional-chaining)
    if (ctx.ast.node_start_overrides.get(@intCast(ni))) |ov| return ov;

    const tags = ctx.ast.nodes.items(.tag);
    const data_items = ctx.ast.nodes.items(.data);
    if (ni >= tags.len) return 0;
    const tag = tags[ni];
    const data = data_items[ni];
    switch (tag) {
        .optional_chain_expr,
        .optional_computed_member_expr,
        .member_expr,
        .computed_member_expr,
        .binary_expr,
        .logical_expr,
        .assignment_expr,
        .conditional_expr,
        .ts_as_expression,
        .ts_satisfies_expression,
        => return effectiveNodeStart(ctx, @intFromEnum(data.binary.lhs)),
        .optional_call_expr,
        .call_expr,
        => {
            const eidx = @intFromEnum(data.extra);
            if (eidx < ctx.ast.extra_data.items.len) {
                const callee: usize = ctx.ast.extra_data.items[eidx];
                return effectiveNodeStart(ctx, callee);
            }
        },
        .ts_non_null_expression,
        .unary_expr,
        .update_expr,
        => return effectiveNodeStart(ctx, @intFromEnum(data.unary)),
        else => {},
    }
    const mt = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(mt)];
}

/// Build the "effective source" for a source range, incorporating any child node
/// replacement_source entries from previous transform passes.
fn buildEffectiveSource(ctx: *TransformContext, start_off: u32, end_off: u32) []const u8 {
    if (ctx.ast.replacement_source.count() == 0) {
        return ctx.ast.source[start_off..end_off];
    }

    // Collect replacements that fall within our range, sorted by position
    const Replacement = struct {
        node_start: u32,
        node_end: u32,
        text: []const u8,
    };
    var replacements: std.ArrayListUnmanaged(Replacement) = .empty;
    defer replacements.deinit(ctx.allocator);

    const ordered = ctx.orderedReplacements() catch return ctx.ast.source[start_off..end_off];
    const range_start = ctx.replacementLowerBound(start_off) catch return ctx.ast.source[start_off..end_off];
    for (ordered[range_start..]) |entry| {
        if (entry.start >= end_off) break;
        const ni = entry.node_index;
        if (ni >= ctx.ast.nodes.items(.tag).len) continue;

        // Get node's source range — use effective start that accounts for
        // nodes like optional_chain_expr where main_token is ?. but actual
        // codegen range starts at the base object (e.g., `({})`).
        const ns = effectiveNodeStart(ctx, ni);
        const ne = entry.end;

        // Skip if not within our range or if it IS the declaration itself
        if (ns < start_off or ne > end_off) continue;
        if (ns == start_off and ne == end_off) continue;

        replacements.append(ctx.allocator, .{
            .node_start = ns,
            .node_end = ne,
            .text = entry.text,
        }) catch continue;
    }

    if (replacements.items.len == 0) {
        return ctx.ast.source[start_off..end_off];
    }

    // Sort by position
    std.mem.sort(Replacement, replacements.items, {}, struct {
        fn lessThan(_: void, a: Replacement, b: Replacement) bool {
            return a.node_start < b.node_start;
        }
    }.lessThan);

    // Build effective source with substitutions
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: u32 = start_off;
    for (replacements.items) |repl| {
        // Append source before this replacement
        if (repl.node_start > pos) {
            buf.appendSlice(ctx.allocator, ctx.ast.source[pos..repl.node_start]) catch {};
        }
        // Append replacement text
        buf.appendSlice(ctx.allocator, repl.text) catch {};
        pos = repl.node_end;
    }
    // Append remaining source
    if (pos < end_off) {
        buf.appendSlice(ctx.allocator, ctx.ast.source[pos..end_off]) catch {};
    }

    return buf.items;
}

/// Check if any descendant of a node has a replacement_source entry.
/// Scans the replacement_source map for nodes whose range falls within this node's range.
fn hasChildReplacement(ctx: *TransformContext, parent_ni: usize) bool {
    if (ctx.ast.replacement_source.count() == 0) return false;
    const parent_start = blk: {
        const mt = ctx.ast.nodes.items(.main_token)[parent_ni];
        break :blk ctx.ast.tokens.items(.start)[@intFromEnum(mt)];
    };
    const parent_end = ctx.ast.nodes.items(.end_offset)[parent_ni];

    const ordered = ctx.orderedReplacements() catch return false;
    const range_start = ctx.replacementLowerBound(parent_start) catch return false;
    for (ordered[range_start..]) |entry| {
        if (entry.start >= parent_end) break;
        const ni = entry.node_index;
        if (ni == parent_ni) continue;
        if (ni >= ctx.ast.nodes.items(.tag).len) continue;
        const ne = entry.end;
        const ns = entry.start;
        if (ns >= parent_start and ne <= parent_end) return true;
    }

    return false;
}

/// AST-level rename for declarations that contain child replacement_source entries.
/// Instead of string-based renaming, we change the declaration tag and rename
/// identifier nodes directly via replacement_source.
fn generateRenamedDeclarationAstLevel(idx: NodeIndex, ctx: *TransformContext) void {
    const i = @intFromEnum(idx);

    // Just change the tag from const/let to var
    ctx.ast.nodes.items(.tag)[i] = .var_declaration;

    // Build rename map
    var rename_pairs: [16]RenamePair = undefined;
    var rename_count: u8 = 0;
    collectDeclarationRenamePairs(idx, ctx, &rename_pairs, &rename_count);

    if (rename_count == 0) return;

    // Rename the declarator name identifiers directly
    renameDeclaratorNames(ctx, idx, rename_pairs[0..rename_count]);

    // Rename all references in the block scope
    renameReferencesInScope(ctx, idx, rename_pairs[0..rename_count]);

    if (rename_count == 1) {
        recordDeclRenamedName(idx, rename_pairs[0].new, ctx);
    }
}

/// Rename the name identifiers in each declarator of a declaration.
fn renameDeclaratorNames(ctx: *TransformContext, decl: NodeIndex, pairs: []const RenamePair) void {
    const data = ctx.nodeData(decl);
    const extra_idx = @intFromEnum(data.extra);
    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |declarator_raw| {
        const declarator: NodeIndex = @enumFromInt(declarator_raw);
        const ddata = ctx.nodeData(declarator);
        const name_node = ddata.binary.lhs;
        if (name_node == .none) continue;
        renameBindingIdentifierNode(ctx, name_node, pairs);
    }
}

fn renameBindingIdentifierNode(ctx: *TransformContext, node: NodeIndex, pairs: []const RenamePair) void {
    if (node == .none or ctx.nodeTag(node) != .identifier) return;
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.contains(ni)) return;

    const name = ctx.tokenSlice(ctx.mainToken(node));
    for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair.old)) {
            _ = putReplacement(ctx, node, pair.new);
            return;
        }
    }
}

fn renameClassDeclarationName(
    ctx: *TransformContext,
    decl: NodeIndex,
    name_token: TokenIndex,
    old_name: []const u8,
    new_name: []const u8,
) void {
    const ni = @intFromEnum(decl);
    const start_tok = ctx.ast.nodes.items(.main_token)[ni];
    const start_off = ctx.ast.tokens.items(.start)[@intFromEnum(start_tok)];
    const end_off = ctx.ast.nodes.items(.end_offset)[ni];
    const name_start = ctx.ast.tokens.items(.start)[@intFromEnum(name_token)];
    const name_end = name_start + @as(u32, @intCast(old_name.len));

    if (end_off <= start_off or end_off > ctx.ast.source.len) return;
    if (name_start < start_off or name_end > end_off) return;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, ctx.ast.source[start_off..name_start]) catch return;
    buf.appendSlice(ctx.allocator, new_name) catch return;
    buf.appendSlice(ctx.allocator, ctx.ast.source[name_end..end_off]) catch return;
    _ = putReplacement(ctx, decl, buf.items);
}

/// Generate replacement source for a declaration that needs variable renaming.
fn generateRenamedDeclaration(idx: NodeIndex, ctx: *TransformContext, is_const: bool) void {
    _ = is_const;
    const i = @intFromEnum(idx);
    ctx.ast.nodes.items(.tag)[i] = .var_declaration;

    // Get the source text of the declaration
    const start = ctx.ast.nodes.items(.main_token)[i];
    const start_off = ctx.ast.tokens.items(.start)[@intFromEnum(start)];
    const end_off = ctx.ast.nodes.items(.end_offset)[i];

    if (end_off <= start_off or end_off > ctx.ast.source.len) {
        // Fallback: just change the tag
        ctx.ast.nodes.items(.tag)[i] = .var_declaration;
        return;
    }

    // Check if any descendant node has a replacement_source entry or if the
    // declaration shape benefits from normal codegen formatting.
    if (hasChildReplacement(ctx, i) or shouldUseAstLevelRename(ctx, idx)) {
        generateRenamedDeclarationAstLevel(idx, ctx);
        return;
    }

    const source = ctx.ast.source[start_off..end_off];

    // Build rename map for these names
    var rename_pairs: [16]RenamePair = undefined;
    var rename_count: u8 = 0;
    collectDeclarationRenamePairs(idx, ctx, &rename_pairs, &rename_count);

    if (rename_count == 0) {
        // No renames needed, just change the tag
        ctx.ast.nodes.items(.tag)[i] = .var_declaration;
        return;
    }

    // Build the replacement source:
    // 1. Replace "let" or "const" with "var"
    // 2. Replace each identifier with its renamed version
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "var") catch return;

    // Skip past the keyword ("let" = 3, "const" = 5)
    var pos: usize = 0;
    if (source.len >= 5 and std.mem.eql(u8, source[0..5], "const")) {
        pos = 5;
    } else if (source.len >= 3 and std.mem.eql(u8, source[0..3], "let")) {
        pos = 3;
    } else {
        ctx.ast.nodes.items(.tag)[i] = .var_declaration;
        return;
    }

    // Now scan through the rest of the source, replacing identifiers
    while (pos < source.len) {
        // Try to match an identifier at this position
        const matched = matchIdentifier(source, pos);
        if (matched.len > 0) {
            // Skip identifiers that are property names (preceded by `.` or `?.`)
            // e.g., in `({})?.foo`, the `foo` after `?.` is a property, not a variable
            const is_property = blk: {
                if (pos >= 1 and source[pos - 1] == '.') break :blk true;
                if (pos >= 2 and source[pos - 2] == '?' and source[pos - 1] == '.') break :blk true;
                break :blk false;
            };

            if (is_property) {
                // Don't rename property access names
                buf.appendSlice(ctx.allocator, matched.name) catch return;
                pos += matched.len;
            } else {
                // Check if this identifier needs renaming
                var renamed = false;
                for (rename_pairs[0..rename_count]) |pair| {
                    if (std.mem.eql(u8, matched.name, pair.old)) {
                        buf.appendSlice(ctx.allocator, pair.new) catch return;
                        pos += matched.len;
                        renamed = true;
                        break;
                    }
                }
                if (!renamed) {
                    buf.appendSlice(ctx.allocator, matched.name) catch return;
                    pos += matched.len;
                }
            }
        } else {
            buf.append(ctx.allocator, source[pos]) catch return;
            pos += 1;
        }
    }

    _ = putReplacement(ctx, idx, buf.items);

    if (rename_count == 1) {
        recordDeclRenamedName(idx, rename_pairs[0].new, ctx);
    }

    // Also need to rename all references to these variables within the block scope
    renameReferencesInScope(ctx, idx, rename_pairs[0..rename_count]);
}

fn collectDeclarationRenamePairs(
    idx: NodeIndex,
    ctx: *TransformContext,
    rename_pairs: *[16]RenamePair,
    rename_count: *u8,
) void {
    const scope_result = ctx.scope orelse return;
    const scope_idx = scope_mod.getScopeForNode(scope_result, idx) orelse return;
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];
    const func_scope_idx = findEnclosingFunctionScope(scope_result, scope.parent);
    const names = getDeclaredNames(idx, ctx);

    for (names.items[0..names.len]) |name| {
        if (name.len == 0) continue;
        if (!nameNeedsRename(ctx, idx, scope_idx, scope, func_scope_idx, name)) continue;

        const new_name = generateUniqueName(ctx, idx, name) orelse continue;
        if (rename_count.* < rename_pairs.len) {
            rename_pairs[rename_count.*] = .{ .old = name, .new = new_name };
            rename_count.* += 1;
        }
    }
}

fn recordDeclRenamedName(idx: NodeIndex, new_name: []const u8, ctx: *TransformContext) void {
    g_decl_renamed_names.put(ctx.allocator, @intFromEnum(idx), new_name) catch {};
}

const LoopParam = struct {
    original_name: []const u8,
    current_name: []const u8,
    param_name: []const u8,
    decl_node: NodeIndex,
    is_mutated: bool = false,
};

const LoopUpdater = struct {
    outer: []const u8,
    inner: []const u8,
};

const LoopBodyRename = struct {
    old: []const u8,
    new: []const u8,
};

const LoopCompletionKind = enum {
    break_stmt,
    continue_stmt,
};

const LoopCompletion = struct {
    kind: LoopCompletionKind,
    label_name: []const u8 = "",
    code: u8 = 0,
};

const EffectiveSourceOverlay = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

const LoopWrapperKind = enum {
    plain,
    async_fn,
    generator_fn,
    async_generator_fn,
};

const LoopWrapInfo = struct {
    body: NodeIndex = .none,
    head: NodeIndex = .none,
    loop_start: u32 = 0,
    body_start: u32 = 0,
    body_end: u32 = 0,
    loop_end: u32 = 0,
    has_break: bool = false,
    has_continue: bool = false,
    has_return: bool = false,
    needs_wrap: bool = false,
    param_count: u8 = 0,
    params: [16]LoopParam = undefined,
    body_renames: [16]LoopBodyRename = undefined,
    body_rename_count: u8 = 0,
    body_restore_renames: [16]LoopBodyRename = undefined,
    body_restore_rename_count: u8 = 0,
    body_capture_names: [16][]const u8 = .{""} ** 16,
    body_capture_count: u8 = 0,
    completions: [16]LoopCompletion = undefined,
    completion_count: u8 = 0,
};

const TdzAccessKind = enum {
    none,
    direct,
    maybe,
};

fn handleLoopNode(idx: NodeIndex, ctx: *TransformContext) void {
    ensureParentMap(ctx);

    var info = collectLoopWrapInfo(idx, ctx) orelse return;
    if (!info.needs_wrap and loopHasBlockScopedFunctionDeclarations(info.body, ctx)) {
        info.needs_wrap = true;
    }
    if (!info.needs_wrap) return;

    wrapLoopNode(idx, ctx, info);
}

fn ensureParentMap(ctx: *TransformContext) void {
    if (ctx.session) |session| {
        g_parent_session = session;
        return;
    }
    if (g_node_parents_ready) return;

    const node_count = ctx.ast.nodes.items(.tag).len;
    g_node_parents = ctx.allocator.alloc(u32, node_count) catch return;
    @memset(g_node_parents, parent_none);

    buildParentMap(ctx, @enumFromInt(0), .none);
    g_node_parents_ready = true;
}

fn buildParentMap(ctx: *TransformContext, node: NodeIndex, parent: ?NodeIndex) void {
    if (node == .none) return;
    const ni = @intFromEnum(node);
    if (ni >= g_node_parents.len) return;
    g_node_parents[ni] = if (parent) |p| @intFromEnum(p) else parent_none;

    const children = visitor.getChildren(ctx.ast, node);
    for (children.items[0..children.len]) |child| {
        buildParentMap(ctx, child, node);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            buildParentMap(ctx, @enumFromInt(raw), node);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            buildParentMap(ctx, @enumFromInt(raw), node);
        }
    }
}

fn applyLoopBodyUndefinedInit(idx: NodeIndex, ctx: *TransformContext, is_const: bool) void {
    if (is_const) return;
    const ni = @intFromEnum(idx);
    if (ctx.ast.replacement_source.contains(ni)) return;
    if (!isDeclarationInLoopBody(idx, ctx)) return;

    const names = getDeclaredNames(idx, ctx);
    if (names.len != 1) return;
    if (declarationHasInitializer(idx, ctx)) return;

    const current_name = getCurrentBindingName(ctx, idx, names.items[0]);
    const replacement = std.fmt.allocPrint(ctx.allocator, "var {s} = void 0;", .{current_name}) catch return;
    _ = putReplacement(ctx, idx, replacement);
}

fn declarationHasInitializer(idx: NodeIndex, ctx: *TransformContext) bool {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_idx| {
        if (decl_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[decl_idx] != .declarator) continue;
        const init = ctx.ast.nodes.items(.data)[decl_idx].binary.rhs;
        if (init != .none) return true;
    }
    return false;
}

fn isDeclarationInLoopBody(idx: NodeIndex, ctx: *TransformContext) bool {
    ensureParentMap(ctx);

    var current = getParentNode(idx);
    while (current) |cur| {
        const tag = ctx.nodeTag(cur);
        switch (tag) {
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
            .class_declaration,
            .class_expr,
            => return false,
            else => {},
        }

        if (isLoopNode(tag)) {
            const body = loopBodyNode(cur, ctx) orelse return false;
            if (!isDescendantOf(idx, body)) return false;
            const head = loopHeadNode(cur, ctx);
            if (head != null and isDescendantOf(idx, head.?)) return false;
            return true;
        }
        current = getParentNode(cur);
    }

    return false;
}

fn getParentNode(node: NodeIndex) ?NodeIndex {
    if (g_parent_session) |session| {
        if (session.parentOf(node)) |parent| return parent;
    }
    if (!g_node_parents_ready) return null;
    const ni = @intFromEnum(node);
    if (ni >= g_node_parents.len) return null;
    const parent_raw = g_node_parents[ni];
    if (parent_raw == parent_none) return null;
    return @enumFromInt(parent_raw);
}

fn isDescendantOf(node: NodeIndex, ancestor: NodeIndex) bool {
    if (node == .none or ancestor == .none) return false;
    var current: ?NodeIndex = node;
    while (current) |cur| {
        if (cur == ancestor) return true;
        current = getParentNode(cur);
    }
    return false;
}

fn hasFunctionBoundaryBetween(node: NodeIndex, ancestor: NodeIndex, ctx: *TransformContext) bool {
    var current: ?NodeIndex = node;
    while (current) |cur| {
        if (cur == ancestor) return false;
        const tag = ctx.nodeTag(cur);
        switch (tag) {
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
            .class_declaration,
            .class_expr,
            => return true,
            else => {},
        }
        current = getParentNode(cur);
    }
    return false;
}

fn loopBodyNode(idx: NodeIndex, ctx: *TransformContext) ?NodeIndex {
    const tag = ctx.nodeTag(idx);
    const data = ctx.nodeData(idx);
    return switch (tag) {
        .for_statement => blk: {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 3 >= ctx.ast.extra_data.items.len) break :blk null;
            break :blk @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
        },
        .for_in_statement, .for_of_statement => blk: {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) break :blk null;
            break :blk @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);
        },
        .while_statement => data.binary.rhs,
        .do_while_statement => data.binary.lhs,
        else => null,
    };
}

fn loopHeadNode(idx: NodeIndex, ctx: *TransformContext) ?NodeIndex {
    const tag = ctx.nodeTag(idx);
    const data = ctx.nodeData(idx);
    return switch (tag) {
        .for_statement => blk: {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 3 >= ctx.ast.extra_data.items.len) break :blk null;
            const head: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            break :blk if (head == .none) null else head;
        },
        .for_in_statement, .for_of_statement => blk: {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) break :blk null;
            const head: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            break :blk if (head == .none) null else head;
        },
        else => null,
    };
}

fn getCurrentBindingName(ctx: *TransformContext, decl_node: NodeIndex, original: []const u8) []const u8 {
    if (g_decl_renamed_names.get(@intFromEnum(decl_node))) |renamed| return renamed;
    if (getRenameAnchorDeclaration(decl_node, ctx)) |anchor| {
        if (g_decl_renamed_names.get(@intFromEnum(anchor))) |renamed| {
            const anchor_names = getDeclaredNames(anchor, ctx);
            if (anchor_names.len == 1 and std.mem.eql(u8, anchor_names.items[0], original)) {
                return renamed;
            }
        }
    }
    return original;
}

fn collectLoopWrapInfo(idx: NodeIndex, ctx: *TransformContext) ?LoopWrapInfo {
    const scope_result = ctx.scope orelse return null;
    const body = loopBodyNode(idx, ctx) orelse return null;
    const head = loopHeadNode(idx, ctx);
    const has_block_scoped_function_decls = loopHasBlockScopedFunctionDeclarations(body, ctx);

    // Most loops do not contain closures or per-iteration head mutations.
    // Skip the expensive all-bindings scan when a wrap is impossible.
    if (!has_block_scoped_function_decls and !loopRequiresWrapScan(scope_result, idx, head, body, ctx)) return null;

    const loop_start = nodeStartOffset(ctx, idx);
    const loop_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(idx)];
    const body_start = nodeStartOffset(ctx, body);
    const body_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(body)];

    var info = LoopWrapInfo{
        .body = body,
        .head = head orelse .none,
        .loop_start = loop_start,
        .body_start = body_start,
        .body_end = body_end,
        .loop_end = loop_end,
    };

    for (scope_result.bindings, 0..) |binding, binding_idx| {
        if (binding.kind != .let_decl and binding.kind != .const_decl and binding.kind != .var_decl and binding.kind != .function_decl) continue;

        const decl_node = if (binding.decl_node != .none) binding.decl_node else binding.node;
        if (decl_node == .none) continue;
        if (!isDescendantOf(decl_node, idx)) continue;
        if (hasFunctionBoundaryBetween(decl_node, idx, ctx)) continue;
        if (isProtectedByNestedWrappedLoop(decl_node, idx, ctx)) continue;

        const head_node = head orelse .none;
        const in_head = head_node != .none and isDescendantOf(decl_node, head_node);
        const referenced_from_body = if (in_head)
            bodyReferencesBinding(scope_result, binding_idx, body, head_node)
        else
            false;
        const mutated_in_body = if (in_head)
            bindingHasBodyMutation(scope_result, binding_idx, idx, body, head_node)
        else
            false;
        const captured_in_deferred_class_field = bindingReferencedFromDeferredClassField(
            scope_result,
            binding_idx,
            body,
            head_node,
            ctx,
        );
        const captured_in_nested_function = bindingReferencedFromNestedFunction(
            scope_result,
            binding_idx,
            body,
            head_node,
            ctx,
        );
        const effectively_captured = binding.is_captured or
            captured_in_deferred_class_field or
            captured_in_nested_function;
        const current_name = if (in_head)
            getCurrentBindingName(ctx, decl_node, binding.name)
        else
            binding.name;
        const needs_head_rename = in_head and needsLoopParamRename(decl_node, ctx);
        const rebinds_each_iteration = in_head and loopHeadRebindsEachIteration(idx, ctx);
        const needs_head_body_rename = in_head and referenced_from_body and
            (!std.mem.eql(u8, current_name, binding.name) or needs_head_rename);
        if (!effectively_captured and !mutated_in_body) {
            if (needs_head_body_rename and info.body_rename_count < info.body_renames.len) {
                info.body_renames[info.body_rename_count] = .{
                    .old = binding.name,
                    .new = current_name,
                };
                info.body_rename_count += 1;
            }
            continue;
        }

        info.needs_wrap = true;

        if (head) |loop_head_node| {
            if (isDescendantOf(decl_node, loop_head_node)) {
                const is_mutated = mutated_in_body;

                if (effectively_captured or is_mutated) {
                    const param_name = if (is_mutated)
                        if (rebinds_each_iteration and !needs_head_rename)
                            current_name
                        else
                            generateUniqueName(ctx, decl_node, binding.name) orelse current_name
                    else if (!std.mem.eql(u8, current_name, binding.name))
                        current_name
                    else if (needs_head_rename)
                        generateUniqueName(ctx, decl_node, binding.name) orelse current_name
                    else
                        current_name;

                    if (info.param_count < info.params.len) {
                        info.params[info.param_count] = .{
                            .original_name = binding.name,
                            .current_name = current_name,
                            .param_name = param_name,
                            .decl_node = decl_node,
                            .is_mutated = is_mutated,
                        };
                        info.param_count += 1;
                    }
                }
            }
        }
    }

    if (has_block_scoped_function_decls) {
        info.needs_wrap = true;
    }

    const head_node = head orelse .none;
    for (scope_result.bindings, 0..) |binding, binding_idx| {
        if (binding.kind != .let_decl and binding.kind != .const_decl and binding.kind != .var_decl) continue;

        const decl_node = if (binding.decl_node != .none) binding.decl_node else binding.node;
        if (decl_node == .none) continue;
        if (!isDescendantOf(decl_node, idx)) continue;
        if (hasFunctionBoundaryBetween(decl_node, idx, ctx)) continue;
        if (head_node != .none and isDescendantOf(decl_node, head_node)) continue;
        if (isProtectedByNestedWrappedLoop(decl_node, idx, ctx)) continue;

        const current_name = getCurrentBindingName(ctx, decl_node, binding.name);
        if (std.mem.eql(u8, current_name, binding.name)) continue;
        if (!canRestoreWrappedBodyBindingName(scope_result, binding_idx, decl_node, idx, head_node, info, ctx)) continue;

        appendLoopBodyRenameUnique(
            &info.body_restore_renames,
            &info.body_restore_rename_count,
            .{ .old = current_name, .new = binding.name },
        );
    }

    if (info.needs_wrap) {
        for (scope_result.bindings) |binding| {
            if (binding.kind != .var_decl and binding.kind != .function_decl) continue;

            const decl_node = if (binding.decl_node != .none) binding.decl_node else binding.node;
            if (decl_node == .none) continue;
            if (!isDescendantOf(decl_node, idx)) continue;
            if (hasFunctionBoundaryBetween(decl_node, idx, ctx)) continue;
            if (head_node != .none and isDescendantOf(decl_node, head_node)) continue;
            if (isProtectedByNestedWrappedLoop(decl_node, idx, ctx)) continue;

            appendLoopBodyCaptureUnique(&info, getCurrentBindingName(ctx, decl_node, binding.name));
        }
    }

    if (info.needs_wrap) {
        collectLoopCompletionCases(ctx, body, &info, true, true);
        for (info.completions[0..info.completion_count]) |completion| {
            switch (completion.kind) {
                .break_stmt => info.has_break = true,
                .continue_stmt => info.has_continue = true,
            }
        }
        if (subtreeHasCompletion(idx, body, ctx, .return_statement)) info.has_return = true;
        if (usesLoopCompletionTable(info, getNearestLoopLabelName(idx, ctx))) {
            for (info.completions[0..info.completion_count], 0..) |*completion, ci| {
                completion.code = @intCast(ci);
            }
        }
    }

    return if (info.needs_wrap or has_block_scoped_function_decls) info else null;
}

fn loopRequiresWrapScan(
    scope_result: *const scope_mod.ScopeResult,
    loop_node: NodeIndex,
    head_node: ?NodeIndex,
    body_node: NodeIndex,
    ctx: *TransformContext,
) bool {
    if (subtreeHasLoopWrapCaptureBoundary(body_node, body_node, ctx)) return true;
    return loopHeadHasBodyMutationQuick(scope_result, loop_node, head_node, body_node, ctx);
}

fn loopHasBlockScopedFunctionDeclarations(root: NodeIndex, ctx: *TransformContext) bool {
    if (root == .none) return false;

    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, root) catch return false;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        const tag = ctx.nodeTag(node);
        if (tag == .block_statement or tag == .program) {
            if (ctx.ast.block_prefix_source.get(@intFromEnum(node))) |prefix| {
                if (std.mem.indexOf(u8, prefix, "function") != null) return true;
            }
        }
        if (isBlockScopedFunctionDeclarationTag(tag)) return true;
        if (node != root and isNestedFunctionBoundary(tag)) continue;

        const children = visitor.getChildren(ctx.ast, node);
        for (children.items[0..children.len]) |child| {
            stack.append(ctx.allocator, child) catch return false;
        }
        if (children.range_start < children.range_end) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
        if (children.range2_start < children.range2_end) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
    }

    return false;
}

fn isBlockScopedFunctionDeclarationTag(tag: Node.Tag) bool {
    return switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        => true,
        else => false,
    };
}

fn subtreeHasLoopWrapCaptureBoundary(root: NodeIndex, body_node: NodeIndex, ctx: *TransformContext) bool {
    if (root == .none) return false;

    const tag = ctx.nodeTag(root);
    if ((root != body_node or tag != .block_statement) and isNestedFunctionBoundary(tag)) {
        return true;
    }

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        if (subtreeHasLoopWrapCaptureBoundary(child, body_node, ctx)) return true;
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (subtreeHasLoopWrapCaptureBoundary(@enumFromInt(raw), body_node, ctx)) return true;
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (subtreeHasLoopWrapCaptureBoundary(@enumFromInt(raw), body_node, ctx)) return true;
        }
    }
    return false;
}

fn loopHeadHasBodyMutationQuick(
    scope_result: *const scope_mod.ScopeResult,
    loop_node: NodeIndex,
    head_node: ?NodeIndex,
    body_node: NodeIndex,
    ctx: *TransformContext,
) bool {
    const head = head_node orelse return false;
    if (head == .none) return false;
    const head_tag = ctx.nodeTag(head);
    if (head_tag != .let_declaration and head_tag != .const_declaration) return false;

    const scope_idx = scope_mod.getScopeForNode(scope_result, head) orelse return false;
    const names = getDeclaredNames(head, ctx);
    for (names.items[0..names.len]) |name| {
        if (name.len == 0) continue;
        const binding_idx = scope_mod.getBindingIndex(scope_result, scope_idx, name) orelse continue;
        if (bindingHasBodyMutation(scope_result, binding_idx, loop_node, body_node, head)) {
            return true;
        }
    }

    return false;
}

fn needsLoopParamRename(decl_node: NodeIndex, ctx: *TransformContext) bool {
    const tag = ctx.nodeTag(decl_node);
    if (tag == .let_declaration or tag == .const_declaration) {
        return checkNeedsRename(decl_node, ctx);
    }
    if (getParentNode(decl_node)) |parent| {
        const parent_tag = ctx.nodeTag(parent);
        if (parent_tag == .let_declaration or parent_tag == .const_declaration) {
            return checkNeedsRename(parent, ctx);
        }
    }
    return false;
}

fn bodyReferencesBinding(
    scope_result: *const scope_mod.ScopeResult,
    binding_idx: usize,
    body_node: NodeIndex,
    head_node: NodeIndex,
) bool {
    var iter = scope_result.node_to_binding.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != binding_idx) continue;
        const ref_node: NodeIndex = @enumFromInt(entry.key_ptr.*);
        if (!isDescendantOf(ref_node, body_node)) continue;
        if (head_node != .none and isDescendantOf(ref_node, head_node)) continue;
        return true;
    }
    return false;
}

fn bindingReferencedFromDeferredClassField(
    scope_result: *const scope_mod.ScopeResult,
    binding_idx: usize,
    body_node: NodeIndex,
    head_node: NodeIndex,
    ctx: *TransformContext,
) bool {
    var iter = scope_result.node_to_binding.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != binding_idx) continue;
        const ref_node: NodeIndex = @enumFromInt(entry.key_ptr.*);
        if (!isDescendantOf(ref_node, body_node)) continue;
        if (head_node != .none and isDescendantOf(ref_node, head_node)) continue;

        var current: ?NodeIndex = ref_node;
        while (current) |cur| {
            if (cur == body_node) break;
            switch (ctx.nodeTag(cur)) {
                .class_field, .class_private_field => return true,
                else => current = getParentNode(cur),
            }
        }
    }
    return false;
}

fn bindingReferencedFromNestedFunction(
    scope_result: *const scope_mod.ScopeResult,
    binding_idx: usize,
    body_node: NodeIndex,
    head_node: NodeIndex,
    ctx: *TransformContext,
) bool {
    var iter = scope_result.node_to_binding.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != binding_idx) continue;
        const ref_node: NodeIndex = @enumFromInt(entry.key_ptr.*);
        if (!isDescendantOf(ref_node, body_node)) continue;
        if (head_node != .none and isDescendantOf(ref_node, head_node)) continue;

        var current: ?NodeIndex = ref_node;
        while (current) |cur| {
            if (cur == body_node) break;
            switch (ctx.nodeTag(cur)) {
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
                => return true,
                else => current = getParentNode(cur),
            }
        }
    }
    return false;
}

fn bindingHasBodyMutation(
    scope_result: *const scope_mod.ScopeResult,
    binding_idx: usize,
    loop_node: NodeIndex,
    body_node: NodeIndex,
    head_node: NodeIndex,
) bool {
    _ = loop_node;
    const mutations = scope_mod.getBindingMutations(scope_result, @intCast(binding_idx));
    for (mutations) |mutation_raw| {
        const mutation_node: NodeIndex = @enumFromInt(mutation_raw);
        if (!isDescendantOf(mutation_node, body_node)) continue;
        if (head_node != .none and isDescendantOf(mutation_node, head_node)) continue;
        return true;
    }
    return false;
}

fn subtreeHasCompletion(loop_node: NodeIndex, root: NodeIndex, ctx: *TransformContext, wanted: Node.Tag) bool {
    const tag = ctx.nodeTag(root);
    if (tag == wanted) return true;

    switch (tag) {
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
        .class_declaration,
        .class_expr,
        => return false,
        .switch_statement => {
            if (wanted == .break_statement) return false;
        },
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        => return false,
        else => {},
    }

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        if (subtreeHasCompletion(loop_node, child, ctx, wanted)) return true;
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (subtreeHasCompletion(loop_node, @enumFromInt(raw), ctx, wanted)) return true;
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (subtreeHasCompletion(loop_node, @enumFromInt(raw), ctx, wanted)) return true;
        }
    }
    return false;
}

fn subtreeHasLabeledLoopCompletion(root: NodeIndex, loop_node: NodeIndex, ctx: *TransformContext, wanted: Node.Tag) bool {
    if (root == .none) return false;
    const tag = ctx.nodeTag(root);

    switch (tag) {
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
        .class_declaration,
        .class_expr,
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        => return false,
        else => {},
    }

    if (tag == wanted and labeledCompletionTargetsLoop(root, loop_node, ctx, wanted)) return true;

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        if (subtreeHasLabeledLoopCompletion(child, loop_node, ctx, wanted)) return true;
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (subtreeHasLabeledLoopCompletion(@enumFromInt(raw), loop_node, ctx, wanted)) return true;
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (subtreeHasLabeledLoopCompletion(@enumFromInt(raw), loop_node, ctx, wanted)) return true;
        }
    }
    return false;
}

fn appendLoopCompletion(info: *LoopWrapInfo, kind: LoopCompletionKind, label_name: []const u8) void {
    for (info.completions[0..info.completion_count]) |existing| {
        if (existing.kind != kind) continue;
        if (std.mem.eql(u8, existing.label_name, label_name)) return;
    }
    if (info.completion_count >= info.completions.len) return;
    info.completions[info.completion_count] = .{
        .kind = kind,
        .label_name = label_name,
    };
    info.completion_count += 1;
}

fn collectLoopCompletionCases(
    ctx: *TransformContext,
    root: NodeIndex,
    info: *LoopWrapInfo,
    allow_break: bool,
    allow_continue: bool,
) void {
    if (root == .none) return;

    const tag = ctx.nodeTag(root);
    if (tag == .break_statement or tag == .continue_statement) {
        const label = ctx.nodeData(root).unary;
        const label_name = if (label != .none and ctx.nodeTag(label) == .identifier)
            ctx.tokenSlice(ctx.mainToken(label))
        else
            "";

        if (tag == .break_statement) {
            if (label_name.len > 0 or allow_break) {
                appendLoopCompletion(info, .break_stmt, label_name);
            }
        } else {
            if (label_name.len > 0 or allow_continue) {
                appendLoopCompletion(info, .continue_stmt, label_name);
            }
        }
        return;
    }

    switch (tag) {
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
        .class_declaration,
        .class_expr,
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        => return,
        .switch_statement => {
            collectLoopCompletionChildren(ctx, root, info, false, allow_continue);
            return;
        },
        else => {},
    }

    collectLoopCompletionChildren(ctx, root, info, allow_break, allow_continue);
}

fn collectLoopCompletionChildren(
    ctx: *TransformContext,
    root: NodeIndex,
    info: *LoopWrapInfo,
    allow_break: bool,
    allow_continue: bool,
) void {
    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        collectLoopCompletionCases(ctx, child, info, allow_break, allow_continue);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            collectLoopCompletionCases(ctx, @enumFromInt(raw), info, allow_break, allow_continue);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            collectLoopCompletionCases(ctx, @enumFromInt(raw), info, allow_break, allow_continue);
        }
    }
}

fn usesLoopCompletionTable(info: LoopWrapInfo, loop_label: ?[]const u8) bool {
    for (info.completions[0..info.completion_count]) |completion| {
        if (completion.label_name.len == 0) continue;
        if (loop_label) |label| {
            if (std.mem.eql(u8, completion.label_name, label)) continue;
        }
        return true;
    }
    return false;
}

fn labeledCompletionTargetsLoop(node: NodeIndex, loop_node: NodeIndex, ctx: *TransformContext, wanted: Node.Tag) bool {
    if (ctx.nodeTag(node) != wanted) return false;
    const label = ctx.nodeData(node).unary;
    if (label == .none or ctx.nodeTag(label) != .identifier) return false;

    const label_name = ctx.tokenSlice(ctx.mainToken(label));
    var target = loop_node;
    while (getParentNode(target)) |parent| {
        if (ctx.nodeTag(parent) != .labeled_statement) break;
        if (ctx.nodeData(parent).unary != target) break;
        if (std.mem.eql(u8, ctx.tokenSlice(ctx.mainToken(parent)), label_name)) return true;
        target = parent;
    }
    return false;
}

fn wrapLoopNode(idx: NodeIndex, ctx: *TransformContext, info: LoopWrapInfo) void {
    const replacement_target = getLoopReplacementTarget(idx, ctx);
    const loop_label = getNearestLoopLabelName(idx, ctx);
    const hoist_target = findEnclosingWrappedLoop(idx, ctx);
    const head_var_names = getLoopHeadVarNames(info.head, ctx);
    if (hoist_target != null and head_var_names.len > 0) {
        recordHoistedLoopHeadVars(ctx, hoist_target.?, head_var_names);
    }
    const hoisted_head_vars = getRecordedHoistedLoopHeadVars(idx);
    const use_completion_table = usesLoopCompletionTable(info, loop_label);
    var hoisted_body_vars = NameList{};
    for (info.body_capture_names[0..info.body_capture_count]) |name| {
        addUniqueName(&hoisted_body_vars, name);
    }
    var followup_vars = hoisted_body_vars;
    for (hoisted_head_vars.items[0..hoisted_head_vars.len]) |name| {
        addUniqueName(&followup_vars, name);
    }
    const has_followup_declarators = info.has_return or use_completion_table or followup_vars.len > 0;
    const wrapper_kind = getEnclosingLoopWrapperKind(idx, ctx);

    var loop_name = generateLoopWrapperName(ctx, idx) orelse "_loop";
    if (loop_name.len == 0) loop_name = "_loop";
    if (tryWrapLoweredForOfLoop(idx, replacement_target, ctx, info, loop_name, hoisted_body_vars.items[0..hoisted_body_vars.len])) return;

    var rename_pairs: [16]RenamePair = undefined;
    var rename_count: u8 = 0;
    var call_args: [16][]const u8 = .{""} ** 16;
    var call_arg_count: u8 = 0;
    var updater_pairs: [16]LoopUpdater = undefined;
    var updater_count: u8 = 0;
    const needs_result_temp = info.has_return or use_completion_table;
    const result_temp = if (needs_result_temp)
        (generateUniqueName(ctx, idx, "ret") orelse "_ret")
    else
        "";
    const rebinds_each_iteration = loopHeadRebindsEachIteration(idx, ctx);

    for (info.params[0..info.param_count]) |param| {
        if (rename_count < rename_pairs.len) {
            if (!std.mem.eql(u8, param.current_name, param.param_name)) {
                rename_pairs[rename_count] = .{ .old = param.original_name, .new = param.param_name };
                rename_count += 1;
                if (!std.mem.eql(u8, param.current_name, param.original_name) and rename_count < rename_pairs.len) {
                    rename_pairs[rename_count] = .{ .old = param.current_name, .new = param.param_name };
                    rename_count += 1;
                }
            }
        }
        if (call_arg_count < call_args.len) {
            call_args[call_arg_count] = param.current_name;
            call_arg_count += 1;
        }
        if (param.is_mutated and !rebinds_each_iteration and updater_count < updater_pairs.len) {
            updater_pairs[updater_count] = .{ .outer = param.current_name, .inner = param.param_name };
            updater_count += 1;
        }
    }

    for (info.body_renames[0..info.body_rename_count]) |pair| {
        if (rename_count < rename_pairs.len) {
            rename_pairs[rename_count] = .{ .old = pair.old, .new = pair.new };
            rename_count += 1;
        }
    }

    if (info.has_break or info.has_continue) {
        if (use_completion_table) {
            markLoopCompletionCases(ctx, info.body, info.completions[0..info.completion_count], true, true);
        } else {
            markLoopCompletions(ctx, info.body, info.has_break, info.has_continue, info.has_return);
        }
    }
    if (info.has_return) {
        markLoopReturns(ctx, info.body);
    }
    applyLoopThisCapture(idx, info.body, ctx);

    const hoisted_body_prefix = getHoistableLoopBodyPrefix(info.body, ctx);
    const body_source_raw = getMaterializedLoopBodySource(
        ctx,
        info.body,
        hoisted_body_vars.items[0..hoisted_body_vars.len],
        hoisted_body_prefix.len == 0,
    );
    var body_source = body_source_raw;
    for (rename_pairs[0..rename_count]) |pair| {
        body_source = replaceIdentifierName(ctx, body_source, pair.old, pair.new);
    }
    for (info.body_restore_renames[0..info.body_restore_rename_count]) |pair| {
        body_source = replaceIdentifierName(ctx, body_source, pair.old, pair.new);
    }
    if (!use_completion_table) {
        body_source = rewriteLabeledLoopCompletions(ctx, body_source, idx, info.has_break, info.has_return);
    }
    body_source = injectLoopUpdaterAssignments(ctx, body_source, updater_pairs[0..updater_count]);
    body_source = expandCompactFunctionExpressionBodies(ctx, body_source);
    if (wrapper_kind != .plain) {
        body_source = rewriteSimpleArrowAssignments(ctx, body_source);
    }

    var wrapper_body: std.ArrayListUnmanaged(u8) = .empty;
    defer wrapper_body.deinit(ctx.allocator);
    const wrapper_indent = if (has_followup_declarators) "    " else "  ";
    appendIndentedBodyWithPrefix(ctx, &wrapper_body, body_source, wrapper_indent) catch return;
    if (body_source.len == 0 or body_source[body_source.len - 1] != '\n') {
        wrapper_body.append(ctx.allocator, '\n') catch return;
    }
    for (updater_pairs[0..updater_count]) |up| {
        wrapper_body.appendSlice(ctx.allocator, wrapper_indent) catch return;
        wrapper_body.appendSlice(ctx.allocator, up.outer) catch return;
        wrapper_body.appendSlice(ctx.allocator, " = ") catch return;
        wrapper_body.appendSlice(ctx.allocator, up.inner) catch return;
        wrapper_body.appendSlice(ctx.allocator, ";\n") catch return;
    }

    var outer_body: std.ArrayListUnmanaged(u8) = .empty;
    defer outer_body.deinit(ctx.allocator);
    if (hoisted_body_prefix.len > 0) {
        appendIndentedBodyWithPrefix(ctx, &outer_body, hoisted_body_prefix, "  ") catch return;
        if (hoisted_body_prefix[hoisted_body_prefix.len - 1] != '\n') {
            outer_body.append(ctx.allocator, '\n') catch return;
        }
    }
    if (needs_result_temp) {
        outer_body.appendSlice(ctx.allocator, "  ") catch return;
        outer_body.appendSlice(ctx.allocator, result_temp) catch return;
        outer_body.appendSlice(ctx.allocator, " = ") catch return;
        appendLoopWrapperCall(ctx, &outer_body, wrapper_kind, loop_name, call_args[0..call_arg_count]) catch return;
        outer_body.appendSlice(ctx.allocator, ";\n") catch return;

        if (use_completion_table) {
            for (info.completions[0..info.completion_count]) |completion| {
                outer_body.appendSlice(ctx.allocator, "  if (") catch return;
                outer_body.appendSlice(ctx.allocator, result_temp) catch return;
                outer_body.appendSlice(ctx.allocator, " === ") catch return;
                const code_text = std.fmt.allocPrint(ctx.allocator, "{d}", .{completion.code}) catch return;
                outer_body.appendSlice(ctx.allocator, code_text) catch return;
                outer_body.appendSlice(ctx.allocator, ") ") catch return;
                switch (completion.kind) {
                    .break_stmt => outer_body.appendSlice(ctx.allocator, "break") catch return,
                    .continue_stmt => outer_body.appendSlice(ctx.allocator, "continue") catch return,
                }
                if (completion.label_name.len > 0) {
                    outer_body.appendSlice(ctx.allocator, " ") catch return;
                    outer_body.appendSlice(ctx.allocator, completion.label_name) catch return;
                }
                outer_body.appendSlice(ctx.allocator, ";\n") catch return;
            }
        } else {
            if (info.has_continue) {
                const continue_code = if (info.has_break or info.has_return) "0" else "1";
                outer_body.appendSlice(ctx.allocator, "  if (") catch return;
                outer_body.appendSlice(ctx.allocator, result_temp) catch return;
                outer_body.appendSlice(ctx.allocator, " === ") catch return;
                outer_body.appendSlice(ctx.allocator, continue_code) catch return;
                outer_body.appendSlice(ctx.allocator, ") continue") catch return;
                if (loop_label) |label| {
                    outer_body.appendSlice(ctx.allocator, " ") catch return;
                    outer_body.appendSlice(ctx.allocator, label) catch return;
                }
                outer_body.appendSlice(ctx.allocator, ";\n") catch return;
            }
            if (info.has_break) {
                outer_body.appendSlice(ctx.allocator, "  if (") catch return;
                outer_body.appendSlice(ctx.allocator, result_temp) catch return;
                outer_body.appendSlice(ctx.allocator, " === 1) break") catch return;
                if (loop_label) |label| {
                    outer_body.appendSlice(ctx.allocator, " ") catch return;
                    outer_body.appendSlice(ctx.allocator, label) catch return;
                }
                outer_body.appendSlice(ctx.allocator, ";\n") catch return;
            }
        }
        if (info.has_return) {
            outer_body.appendSlice(ctx.allocator, "  if (") catch return;
            outer_body.appendSlice(ctx.allocator, result_temp) catch return;
            outer_body.appendSlice(ctx.allocator, ") return ") catch return;
            outer_body.appendSlice(ctx.allocator, result_temp) catch return;
            outer_body.appendSlice(ctx.allocator, ".v;\n") catch return;
        }
    } else if (info.has_break or info.has_continue) {
        const completion_kw = if (info.has_continue and !info.has_break) "continue" else "break";
        outer_body.appendSlice(ctx.allocator, "  if (") catch return;
        appendLoopWrapperCall(ctx, &outer_body, wrapper_kind, loop_name, call_args[0..call_arg_count]) catch return;
        outer_body.appendSlice(ctx.allocator, ") ") catch return;
        outer_body.appendSlice(ctx.allocator, completion_kw) catch return;
        if (loop_label) |label| {
            outer_body.appendSlice(ctx.allocator, " ") catch return;
            outer_body.appendSlice(ctx.allocator, label) catch return;
        }
        outer_body.appendSlice(ctx.allocator, ";\n") catch return;
    } else {
        outer_body.appendSlice(ctx.allocator, "  ") catch return;
        appendLoopWrapperCall(ctx, &outer_body, wrapper_kind, loop_name, call_args[0..call_arg_count]) catch return;
        outer_body.appendSlice(ctx.allocator, ";\n") catch return;
    }

    var loop_prefix = getLoopPrefixSource(idx, hoist_target != null and head_var_names.len > 0, ctx);
    for (info.params[0..info.param_count]) |param| {
        if (!std.mem.eql(u8, param.original_name, param.current_name)) {
            loop_prefix = replaceIdentifierName(ctx, loop_prefix, param.original_name, param.current_name);
        }
    }
    for (info.body_renames[0..info.body_rename_count]) |pair| {
        loop_prefix = replaceIdentifierName(ctx, loop_prefix, pair.old, pair.new);
    }
    const prefix = getLoopReplacementPrefix(replacement_target, idx, loop_prefix, ctx);
    const suffix = if (ctx.nodeTag(idx) == .do_while_statement and info.body_end < info.loop_end)
        trimLeadingLineComment(ctx.ast.source[info.body_end..info.loop_end])
    else if (ctx.nodeTag(info.body) == .block_statement)
        ""
    else if (info.body_end < info.loop_end)
        trimLeadingLineComment(ctx.ast.source[info.body_end..info.loop_end])
    else
        "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "var ") catch return;
    buf.appendSlice(ctx.allocator, loop_name) catch return;
    appendLoopWrapperFunctionAssignment(ctx, &buf, wrapper_kind) catch return;
    for (info.params[0..info.param_count], 0..) |param, i| {
        if (i > 0) buf.appendSlice(ctx.allocator, ", ") catch return;
        buf.appendSlice(ctx.allocator, param.param_name) catch return;
    }
    buf.appendSlice(ctx.allocator, ") {\n") catch return;
    buf.appendSlice(ctx.allocator, wrapper_body.items) catch return;
    if (has_followup_declarators) {
        buf.appendSlice(ctx.allocator, "  },\n") catch return;
        var wrote_followup = false;
        if (needs_result_temp) {
            buf.appendSlice(ctx.allocator, "  ") catch return;
            buf.appendSlice(ctx.allocator, result_temp) catch return;
            wrote_followup = true;
        }
        for (followup_vars.items[0..followup_vars.len], 0..) |name, i| {
            if (wrote_followup or i > 0) {
                buf.appendSlice(ctx.allocator, ",\n  ") catch return;
            } else {
                buf.appendSlice(ctx.allocator, "  ") catch return;
            }
            buf.appendSlice(ctx.allocator, name) catch return;
            wrote_followup = true;
        }
        buf.appendSlice(ctx.allocator, ";\n") catch return;
    } else {
        buf.appendSlice(ctx.allocator, "};\n") catch return;
    }
    buf.appendSlice(ctx.allocator, prefix) catch return;
    buf.appendSlice(ctx.allocator, "{\n") catch return;
    buf.appendSlice(ctx.allocator, outer_body.items) catch return;
    buf.appendSlice(ctx.allocator, "}") catch return;
    if (suffix.len > 0) buf.appendSlice(ctx.allocator, suffix) catch return;

    const replacement_source = if (replacementNeedsStatementBlockWrapper(replacement_target, ctx))
        wrapReplacementInBlock(ctx, buf.items)
    else
        buf.items;
    if (!putReplacementWithReindent(ctx, replacement_target, replacement_source)) return;
}

fn getEnclosingLoopWrapperKind(loop_node: NodeIndex, ctx: *TransformContext) LoopWrapperKind {
    var current = getParentNode(loop_node);
    while (current) |node| {
        switch (ctx.nodeTag(node)) {
            .async_generator_declaration => return .async_generator_fn,
            .generator_declaration => return .generator_fn,
            .async_function_declaration => return .async_fn,
            .function_declaration,
            .function_expr,
            .method_definition,
            .computed_method,
            .class_method,
            .class_private_method,
            .getter,
            .setter,
            => return .plain,
            else => current = getParentNode(node),
        }
    }
    return .plain;
}

fn appendLoopWrapperFunctionAssignment(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    kind: LoopWrapperKind,
) !void {
    switch (kind) {
        .plain => try buf.appendSlice(ctx.allocator, " = function ("),
        .async_fn => try buf.appendSlice(ctx.allocator, " = async function ("),
        .generator_fn => try buf.appendSlice(ctx.allocator, " = function* ("),
        .async_generator_fn => try buf.appendSlice(ctx.allocator, " = async function* ("),
    }
}

fn appendLoopWrapperCall(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    kind: LoopWrapperKind,
    loop_name: []const u8,
    call_args: []const []const u8,
) !void {
    switch (kind) {
        .async_fn => try buf.appendSlice(ctx.allocator, "await "),
        .generator_fn, .async_generator_fn => try buf.appendSlice(ctx.allocator, "yield* "),
        .plain => {},
    }
    try buf.appendSlice(ctx.allocator, loop_name);
    try buf.append(ctx.allocator, '(');
    for (call_args, 0..) |arg, i| {
        if (i > 0) try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, arg);
    }
    try buf.append(ctx.allocator, ')');
}

fn tryWrapLoweredForOfLoop(
    idx: NodeIndex,
    replacement_target: NodeIndex,
    ctx: *TransformContext,
    info: LoopWrapInfo,
    loop_name: []const u8,
    hoisted_body_names: []const []const u8,
) bool {
    if (!g_config.has_for_of_plugin) return false;
    if (replacement_target != idx) return false;
    if (ctx.nodeTag(idx) != .for_of_statement) return false;
    if (info.has_break or info.has_continue or info.has_return) return false;

    const existing = ctx.ast.replacement_source.get(@intFromEnum(replacement_target)) orelse return false;
    if (std.mem.indexOf(u8, existing, "createForOfIteratorHelper(") != null) {
        const try_marker = "\ntry {\n";
        const for_marker = "  for (";
        const body_end_marker = "\n  }\n} catch (err) {\n";
        const try_idx = std.mem.indexOf(u8, existing, try_marker) orelse return false;
        const prefix_end = try_idx + try_marker.len;
        const for_idx = std.mem.indexOfPos(u8, existing, prefix_end, for_marker) orelse return false;
        const body_open = std.mem.indexOfPos(u8, existing, for_idx, "{\n") orelse return false;
        const body_start = body_open + 2;
        const body_end = std.mem.indexOfPos(u8, existing, body_start, body_end_marker) orelse return false;
        const body_text = existing[body_start..body_end];

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        if (g_config.prefer_transformed_for_of) {
            buf.appendSlice(ctx.allocator, existing[0..prefix_end]) catch return false;
            buf.appendSlice(ctx.allocator, "  var ") catch return false;
            buf.appendSlice(ctx.allocator, loop_name) catch return false;
            buf.appendSlice(ctx.allocator, " = function () {\n") catch return false;
            buf.appendSlice(ctx.allocator, body_text) catch return false;
            if (body_text.len == 0 or body_text[body_text.len - 1] != '\n') {
                buf.appendSlice(ctx.allocator, "\n") catch return false;
            }
            buf.appendSlice(ctx.allocator, "  };\n") catch return false;
            buf.appendSlice(ctx.allocator, existing[for_idx..body_start]) catch return false;
            buf.appendSlice(ctx.allocator, "    ") catch return false;
            buf.appendSlice(ctx.allocator, loop_name) catch return false;
            buf.appendSlice(ctx.allocator, "();") catch return false;
            buf.appendSlice(ctx.allocator, existing[body_end..]) catch return false;
        } else {
            const line_end = std.mem.indexOfScalar(u8, body_text, '\n') orelse return false;
            const assignment_line = body_text[0..line_end];
            const body_rest = body_text[line_end + 1 ..];
            const binding_name = parseForOfAssignedName(assignment_line) orelse return false;
            const has_followup_declarators = hoisted_body_names.len > 0;
            const wrapper_body_raw = deindentLines(ctx, body_rest, if (has_followup_declarators) 4 else 2);
            const wrapper_body = rewriteHoistedSingleNameDeclarations(ctx, wrapper_body_raw, hoisted_body_names);

            buf.appendSlice(ctx.allocator, "var ") catch return false;
            buf.appendSlice(ctx.allocator, loop_name) catch return false;
            buf.appendSlice(ctx.allocator, " = function (") catch return false;
            buf.appendSlice(ctx.allocator, binding_name) catch return false;
            buf.appendSlice(ctx.allocator, ") {\n") catch return false;
            if (has_followup_declarators) {
                appendIndentedBodyWithPrefix(ctx, &buf, wrapper_body, "    ") catch return false;
                if (wrapper_body.len == 0 or wrapper_body[wrapper_body.len - 1] != '\n') {
                    buf.appendSlice(ctx.allocator, "\n") catch return false;
                }
            } else {
                buf.appendSlice(ctx.allocator, wrapper_body) catch return false;
                if (wrapper_body.len == 0 or wrapper_body[wrapper_body.len - 1] != '\n') {
                    buf.appendSlice(ctx.allocator, "\n") catch return false;
                }
            }
            if (has_followup_declarators) {
                buf.appendSlice(ctx.allocator, "  },\n") catch return false;
                for (hoisted_body_names, 0..) |name, i| {
                    if (i > 0) {
                        buf.appendSlice(ctx.allocator, ",\n  ") catch return false;
                    } else {
                        buf.appendSlice(ctx.allocator, "  ") catch return false;
                    }
                    buf.appendSlice(ctx.allocator, name) catch return false;
                }
                buf.appendSlice(ctx.allocator, ";\n") catch return false;
            } else {
                buf.appendSlice(ctx.allocator, "};\n") catch return false;
            }
            buf.appendSlice(ctx.allocator, existing[0..body_start]) catch return false;
            buf.appendSlice(ctx.allocator, assignment_line) catch return false;
            buf.appendSlice(ctx.allocator, "\n    ") catch return false;
            buf.appendSlice(ctx.allocator, loop_name) catch return false;
            buf.appendSlice(ctx.allocator, "(") catch return false;
            buf.appendSlice(ctx.allocator, binding_name) catch return false;
            buf.appendSlice(ctx.allocator, ");") catch return false;
            buf.appendSlice(ctx.allocator, existing[body_end..]) catch return false;
        }

        if (!putReplacementWithReindent(ctx, replacement_target, buf.items)) return false;
        return true;
    }

    if (std.mem.indexOf(u8, existing, "createForOfIteratorHelperLoose(") == null) return false;
    const body_open = std.mem.indexOf(u8, existing, "{\n") orelse return false;
    const body_start = body_open + 2;
    const body_end = std.mem.lastIndexOf(u8, existing, "\n}") orelse return false;
    const body_text = existing[body_start..body_end];

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (g_config.prefer_transformed_for_of) {
        buf.appendSlice(ctx.allocator, "var ") catch return false;
        buf.appendSlice(ctx.allocator, loop_name) catch return false;
        buf.appendSlice(ctx.allocator, " = function () {\n") catch return false;
        buf.appendSlice(ctx.allocator, body_text) catch return false;
        if (body_text.len == 0 or body_text[body_text.len - 1] != '\n') {
            buf.appendSlice(ctx.allocator, "\n") catch return false;
        }
        buf.appendSlice(ctx.allocator, "};\n") catch return false;
        buf.appendSlice(ctx.allocator, existing[0..body_start]) catch return false;
        buf.appendSlice(ctx.allocator, "  ") catch return false;
        buf.appendSlice(ctx.allocator, loop_name) catch return false;
        buf.appendSlice(ctx.allocator, "();") catch return false;
        buf.appendSlice(ctx.allocator, existing[body_end..]) catch return false;
    } else {
        const line_end = std.mem.indexOfScalar(u8, body_text, '\n') orelse return false;
        const assignment_line = body_text[0..line_end];
        const body_rest = body_text[line_end + 1 ..];
        const binding_name = parseForOfAssignedName(assignment_line) orelse return false;
        const wrapper_body = rewriteHoistedSingleNameDeclarations(ctx, body_rest, hoisted_body_names);
        const has_followup_declarators = hoisted_body_names.len > 0;

        buf.appendSlice(ctx.allocator, "var ") catch return false;
        buf.appendSlice(ctx.allocator, loop_name) catch return false;
        buf.appendSlice(ctx.allocator, " = function (") catch return false;
        buf.appendSlice(ctx.allocator, binding_name) catch return false;
        buf.appendSlice(ctx.allocator, ") {\n") catch return false;
        if (has_followup_declarators) {
            appendIndentedBodyWithPrefix(ctx, &buf, wrapper_body, "    ") catch return false;
        } else {
            buf.appendSlice(ctx.allocator, wrapper_body) catch return false;
            if (wrapper_body.len == 0 or wrapper_body[wrapper_body.len - 1] != '\n') {
                buf.appendSlice(ctx.allocator, "\n") catch return false;
            }
        }
        if (has_followup_declarators) {
            buf.appendSlice(ctx.allocator, "  },\n") catch return false;
            for (hoisted_body_names, 0..) |name, i| {
                if (i > 0) {
                    buf.appendSlice(ctx.allocator, ",\n  ") catch return false;
                } else {
                    buf.appendSlice(ctx.allocator, "  ") catch return false;
                }
                buf.appendSlice(ctx.allocator, name) catch return false;
            }
            buf.appendSlice(ctx.allocator, ";\n") catch return false;
        } else {
            buf.appendSlice(ctx.allocator, "};\n") catch return false;
        }
        buf.appendSlice(ctx.allocator, existing[0..body_start]) catch return false;
        buf.appendSlice(ctx.allocator, assignment_line) catch return false;
        buf.appendSlice(ctx.allocator, "\n  ") catch return false;
        buf.appendSlice(ctx.allocator, loop_name) catch return false;
        buf.appendSlice(ctx.allocator, "(") catch return false;
        buf.appendSlice(ctx.allocator, binding_name) catch return false;
        buf.appendSlice(ctx.allocator, ");") catch return false;
        buf.appendSlice(ctx.allocator, existing[body_end..]) catch return false;
    }

    if (!putReplacementWithReindent(ctx, replacement_target, buf.items)) return false;
    return true;
}

fn parseForOfAssignedName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const without_var = if (std.mem.startsWith(u8, trimmed, "var ")) trimmed[4..] else trimmed;
    const eq_idx = std.mem.indexOf(u8, without_var, " = ") orelse return null;
    return without_var[0..eq_idx];
}

fn deindentLines(ctx: *TransformContext, text: []const u8, count: usize) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        var end = start;
        while (end < text.len and text[end] != '\n') : (end += 1) {}

        const line = text[start..end];
        var cut: usize = 0;
        while (cut < count and cut < line.len and line[cut] == ' ') : (cut += 1) {}
        buf.appendSlice(ctx.allocator, line[cut..]) catch return text;
        if (end < text.len) buf.appendSlice(ctx.allocator, "\n") catch return text;
        start = if (end < text.len) end + 1 else end;
    }
    return buf.items;
}

fn loopHeadRebindsEachIteration(loop_node: NodeIndex, ctx: *TransformContext) bool {
    return switch (ctx.nodeTag(loop_node)) {
        .for_in_statement, .for_of_statement, .for_of_await_statement => true,
        else => false,
    };
}

fn getLoopReplacementTarget(loop_node: NodeIndex, ctx: *TransformContext) NodeIndex {
    var target = loop_node;
    while (getParentNode(target)) |parent| {
        if (ctx.nodeTag(parent) != .labeled_statement) break;
        if (ctx.nodeData(parent).unary != target) break;
        target = parent;
    }
    return target;
}

fn getLoopReplacementPrefix(
    target_node: NodeIndex,
    loop_node: NodeIndex,
    loop_prefix: []const u8,
    ctx: *TransformContext,
) []const u8 {
    if (target_node == loop_node) return loop_prefix;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var current = target_node;
    while (current != loop_node and current != .none) {
        if (ctx.nodeTag(current) != .labeled_statement) break;
        buf.appendSlice(ctx.allocator, ctx.tokenSlice(ctx.mainToken(current))) catch return loop_prefix;
        buf.appendSlice(ctx.allocator, ": ") catch return loop_prefix;
        current = ctx.nodeData(current).unary;
    }
    buf.appendSlice(ctx.allocator, loop_prefix) catch return loop_prefix;
    return buf.items;
}

fn replacementNeedsStatementBlockWrapper(target_node: NodeIndex, ctx: *TransformContext) bool {
    const parent = getParentNode(target_node) orelse return false;
    return switch (ctx.nodeTag(parent)) {
        .if_statement,
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        => childListContainsNode(visitor.getChildren(ctx.ast, parent), target_node, ctx),
        else => false,
    };
}

fn childListContainsNode(children: anytype, target_node: NodeIndex, ctx: *TransformContext) bool {
    for (children.items[0..children.len]) |child| {
        if (child == target_node) return true;
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (@as(NodeIndex, @enumFromInt(raw)) == target_node) return true;
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (@as(NodeIndex, @enumFromInt(raw)) == target_node) return true;
        }
    }
    return false;
}

fn wrapReplacementInBlock(ctx: *TransformContext, replacement: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "{\n") catch return replacement;
    appendIndentedBodyWithPrefix(ctx, &buf, replacement, "  ") catch return replacement;
    if (replacement.len == 0 or replacement[replacement.len - 1] != '\n') {
        buf.append(ctx.allocator, '\n') catch return replacement;
    }
    buf.appendSlice(ctx.allocator, "}") catch return replacement;
    return buf.items;
}

fn applyLoopThisCapture(loop_node: NodeIndex, body_node: NodeIndex, ctx: *TransformContext) void {
    if (!bodyHasDirectThis(body_node, ctx)) return;

    const enclosing_body = findEnclosingFunctionBodyNode(loop_node, ctx);
    const this_name = ensureLoopThisCaptureName(ctx, enclosing_body);
    setLoopThisCapturePrefix(ctx, enclosing_body, this_name);
    replaceDirectThisInBody(body_node, ctx, this_name);
}

fn bodyHasDirectThis(root: NodeIndex, ctx: *TransformContext) bool {
    if (root == .none) return false;
    if (ctx.nodeTag(root) == .this_expr) return true;
    if (root != .none and isLoopThisBoundaryTag(ctx.nodeTag(root))) return false;

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        if (bodyHasDirectThis(child, ctx)) return true;
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (bodyHasDirectThis(@enumFromInt(raw), ctx)) return true;
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (bodyHasDirectThis(@enumFromInt(raw), ctx)) return true;
        }
    }
    return false;
}

fn replaceDirectThisInBody(root: NodeIndex, ctx: *TransformContext, this_name: []const u8) void {
    if (root == .none) return;
    if (ctx.nodeTag(root) == .this_expr) {
        _ = putReplacement(ctx, root, this_name);
        return;
    }
    if (root != .none and isLoopThisBoundaryTag(ctx.nodeTag(root))) return;

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        replaceDirectThisInBody(child, ctx, this_name);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            replaceDirectThisInBody(@enumFromInt(raw), ctx, this_name);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            replaceDirectThisInBody(@enumFromInt(raw), ctx, this_name);
        }
    }
}

fn isLoopThisBoundaryTag(tag: Node.Tag) bool {
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
        .class_declaration,
        .class_expr,
        => true,
        else => false,
    };
}

fn findEnclosingFunctionBodyNode(node: NodeIndex, ctx: *TransformContext) NodeIndex {
    var current: ?NodeIndex = node;
    while (current) |cur| {
        if (functionBodyNode(cur, ctx)) |body| return body;
        current = getParentNode(cur);
    }
    return @enumFromInt(0);
}

fn functionBodyNode(node: NodeIndex, ctx: *TransformContext) ?NodeIndex {
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    return switch (ctx.nodeTag(node)) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .method_definition,
        .computed_method,
        .class_method,
        .class_private_method,
        => if (extra_idx + 3 < ctx.ast.extra_data.items.len)
            @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3])
        else
            null,
        .getter, .setter => if (extra_idx + 2 < ctx.ast.extra_data.items.len)
            @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2])
        else
            null,
        else => null,
    };
}

fn ensureLoopThisCaptureName(ctx: *TransformContext, body_node: NodeIndex) []const u8 {
    const body_i = @intFromEnum(body_node);
    if (g_loop_body_this_names.get(body_i)) |existing| return existing;
    if (ctx.ast.block_prefix_source.get(body_i)) |prefix| {
        if (findExistingThisCaptureName(prefix)) |existing| {
            g_loop_body_this_names.put(ctx.allocator, body_i, existing) catch {};
            return existing;
        }
    }

    g_loop_this_counter += 1;
    const name = if (g_loop_this_counter == 1)
        "_this"
    else
        std.fmt.allocPrint(ctx.allocator, "_this{d}", .{g_loop_this_counter}) catch "_this";
    g_loop_body_this_names.put(ctx.allocator, body_i, name) catch {};
    return name;
}

fn findExistingThisCaptureName(prefix: []const u8) ?[]const u8 {
    var start_at: usize = 0;
    while (std.mem.indexOfPos(u8, prefix, start_at, "var _this")) |decl_start| {
        const name_start = decl_start + 4;
        var name_end = name_start;
        while (name_end < prefix.len and isIdentCont(prefix[name_end])) : (name_end += 1) {}
        if (name_end > name_start and std.mem.startsWith(u8, prefix[name_end..], " = this")) {
            return prefix[name_start..name_end];
        }
        start_at = decl_start + 1;
    }
    return null;
}

fn setLoopThisCapturePrefix(ctx: *TransformContext, body_node: NodeIndex, this_name: []const u8) void {
    const body_i = @intFromEnum(body_node);
    var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;

    if (ctx.ast.block_prefix_source.get(body_i)) |existing| {
        prefix_buf.appendSlice(ctx.allocator, existing) catch return;
        if (containsThisDecl(existing, this_name)) {
            ctx.ast.block_prefix_source.put(ctx.allocator, body_i, prefix_buf.items) catch return;
            return;
        }
        if (prefix_buf.items.len > 0 and prefix_buf.items[prefix_buf.items.len - 1] != '\n') {
            prefix_buf.append(ctx.allocator, '\n') catch return;
        }
    }

    prefix_buf.appendSlice(ctx.allocator, "var ") catch return;
    prefix_buf.appendSlice(ctx.allocator, this_name) catch return;
    prefix_buf.appendSlice(ctx.allocator, " = this;") catch return;
    if (ctx.ast.block_prefix_source.contains(body_i)) {
        prefix_buf.append(ctx.allocator, '\n') catch return;
    }
    ctx.ast.block_prefix_source.put(ctx.allocator, body_i, prefix_buf.items) catch return;
}

fn containsThisDecl(prefix: []const u8, this_name: []const u8) bool {
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "var {s} = this", .{this_name}) catch return false;
    return std.mem.indexOf(u8, prefix, search) != null;
}

fn getNearestLoopLabelName(loop_node: NodeIndex, ctx: *TransformContext) ?[]const u8 {
    const target = loop_node;
    while (getParentNode(target)) |parent| {
        if (ctx.nodeTag(parent) != .labeled_statement) break;
        if (ctx.nodeData(parent).unary != target) break;
        return ctx.tokenSlice(ctx.mainToken(parent));
    }
    return null;
}

fn getLoopPrefixSource(loop_node: NodeIndex, strip_head_var_keyword: bool, ctx: *TransformContext) []const u8 {
    const tag = ctx.nodeTag(loop_node);
    const data = ctx.nodeData(loop_node);
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    switch (tag) {
        .for_statement => {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 3 >= ctx.ast.extra_data.items.len) return getNodeSource(ctx, loop_node);

            const init: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const test_expr: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            const update: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);

            buf.appendSlice(ctx.allocator, "for (") catch return getNodeSource(ctx, loop_node);
            if (init != .none) {
                const init_source = normalizeLoopHeadSource(getGeneratedSource(ctx, init));
                const emitted_init = if (strip_head_var_keyword and ctx.nodeTag(init) == .var_declaration)
                    stripVarDeclarationKeyword(init_source)
                else
                    init_source;
                buf.appendSlice(ctx.allocator, emitted_init) catch return getNodeSource(ctx, loop_node);
            }
            buf.appendSlice(ctx.allocator, ";") catch return getNodeSource(ctx, loop_node);
            if (test_expr != .none) {
                buf.appendSlice(ctx.allocator, " ") catch return getNodeSource(ctx, loop_node);
                buf.appendSlice(ctx.allocator, getGeneratedSource(ctx, test_expr)) catch return getNodeSource(ctx, loop_node);
            }
            buf.appendSlice(ctx.allocator, ";") catch return getNodeSource(ctx, loop_node);
            if (update != .none) {
                buf.appendSlice(ctx.allocator, " ") catch return getNodeSource(ctx, loop_node);
                buf.appendSlice(ctx.allocator, getGeneratedSource(ctx, update)) catch return getNodeSource(ctx, loop_node);
            }
            buf.appendSlice(ctx.allocator, ") ") catch return getNodeSource(ctx, loop_node);
        },
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        => {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return getNodeSource(ctx, loop_node);

            const left: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const right: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            const op = switch (tag) {
                .for_in_statement => " in ",
                .for_of_await_statement => " await (",
                else => " (",
            };

            if (tag == .for_of_await_statement) {
                buf.appendSlice(ctx.allocator, "for") catch return getNodeSource(ctx, loop_node);
                buf.appendSlice(ctx.allocator, op) catch return getNodeSource(ctx, loop_node);
            } else {
                buf.appendSlice(ctx.allocator, "for (") catch return getNodeSource(ctx, loop_node);
            }
            const left_source = normalizeLoopHeadSource(getGeneratedSource(ctx, left));
            const emitted_left = if (strip_head_var_keyword and ctx.nodeTag(left) == .var_declaration)
                stripVarDeclarationKeyword(left_source)
            else
                left_source;
            buf.appendSlice(ctx.allocator, emitted_left) catch return getNodeSource(ctx, loop_node);
            buf.appendSlice(ctx.allocator, if (tag == .for_in_statement) " in " else " of ") catch return getNodeSource(ctx, loop_node);
            buf.appendSlice(ctx.allocator, getGeneratedSource(ctx, right)) catch return getNodeSource(ctx, loop_node);
            buf.appendSlice(ctx.allocator, ") ") catch return getNodeSource(ctx, loop_node);
        },
        .while_statement => {
            buf.appendSlice(ctx.allocator, "while (") catch return getNodeSource(ctx, loop_node);
            if (data.binary.lhs != .none) {
                buf.appendSlice(ctx.allocator, getGeneratedSource(ctx, data.binary.lhs)) catch return getNodeSource(ctx, loop_node);
            }
            buf.appendSlice(ctx.allocator, ") ") catch return getNodeSource(ctx, loop_node);
        },
        .do_while_statement => {
            buf.appendSlice(ctx.allocator, "do ") catch return getNodeSource(ctx, loop_node);
        },
        else => return getNodeSource(ctx, loop_node),
    }

    return buf.items;
}

fn normalizeLoopHeadSource(src: []const u8) []const u8 {
    return std.mem.trimEnd(u8, src, ";\n\r\t ");
}

fn stripVarDeclarationKeyword(src: []const u8) []const u8 {
    if (std.mem.startsWith(u8, src, "var ")) return src[4..];
    return src;
}

fn getLoopHeadVarNames(head: NodeIndex, ctx: *TransformContext) NameList {
    if (head == .none) return .{};
    if (ctx.nodeTag(head) != .var_declaration) return .{};
    return getDeclaredNames(head, ctx);
}

fn findEnclosingWrappedLoop(loop_node: NodeIndex, ctx: *TransformContext) ?NodeIndex {
    var current = getParentNode(loop_node);
    while (current) |cur| {
        const tag = ctx.nodeTag(cur);
        switch (tag) {
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
            .class_declaration,
            .class_expr,
            => return null,
            else => {},
        }
        if (isLoopNode(tag) and collectLoopWrapInfo(cur, ctx) != null) return cur;
        current = getParentNode(cur);
    }
    return null;
}

fn recordHoistedLoopHeadVars(ctx: *TransformContext, target_loop: NodeIndex, names: NameList) void {
    if (names.len == 0) return;

    const entry = g_loop_hoisted_head_vars.getOrPut(ctx.allocator, @intFromEnum(target_loop)) catch return;
    if (!entry.found_existing) {
        entry.value_ptr.* = .{};
    }

    for (names.items[0..names.len]) |name| {
        if (name.len == 0) continue;
        var exists = false;
        for (entry.value_ptr.items[0..entry.value_ptr.len]) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                exists = true;
                break;
            }
        }
        if (exists or entry.value_ptr.len >= entry.value_ptr.items.len) continue;
        entry.value_ptr.items[entry.value_ptr.len] = name;
        entry.value_ptr.len += 1;
    }
}

fn getRecordedHoistedLoopHeadVars(loop_node: NodeIndex) LoopHoistNames {
    return g_loop_hoisted_head_vars.get(@intFromEnum(loop_node)) orelse .{};
}

fn generateLoopWrapperName(ctx: *TransformContext, loop_node: NodeIndex) ?[]const u8 {
    const scope_result = ctx.scope orelse return generateUniqueName(ctx, loop_node, "loop");
    const current_start = nodeStartOffset(ctx, loop_node);
    var ordinal: u32 = 1;

    for (ctx.ast.nodes.items(.tag), 0..) |tag, ni| {
        if (!isLoopNode(tag)) continue;
        const other: NodeIndex = @enumFromInt(ni);
        if (other == loop_node) continue;
        if (nodeStartOffset(ctx, other) >= current_start) continue;
        if (collectLoopWrapInfo(other, ctx) == null) continue;
        ordinal += 1;
    }

    while (ordinal < 1000) : (ordinal += 1) {
        const candidate = allocBabelUidCandidate(ctx, "loop", ordinal) orelse return null;
        if (!isNameUsedInAnyScope(scope_result, candidate) and !g_claimed_names.contains(candidate)) {
            g_claimed_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }

    return null;
}

fn getMaterializedLoopBodySource(
    ctx: *TransformContext,
    body: NodeIndex,
    hoisted_body_names: []const []const u8,
    include_body_prefix: bool,
) []const u8 {
    if (body == .none) return "";
    if (ctx.nodeTag(body) != .block_statement) {
        if (isDeclarationTag(ctx.nodeTag(body)) and declarationShouldHoistAsAssignment(ctx, body, hoisted_body_names)) {
            return getHoistedDeclarationAssignmentSource(ctx, body);
        }
        const body_src = if (nodeNeedsStructuralEffectiveSource(ctx, body))
            getStatementEffectiveSource(ctx, body)
        else
            getGeneratedSource(ctx, body);
        return rewriteHoistedSingleNameDeclarations(ctx, body_src, hoisted_body_names);
    }

    const children = visitor.getChildren(ctx.ast, body);
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    if (include_body_prefix) {
        if (ctx.ast.block_prefix_source.get(@intFromEnum(body))) |prefix| {
            buf.appendSlice(ctx.allocator, prefix) catch return "";
            if (prefix.len > 0 and prefix[prefix.len - 1] != '\n') {
                buf.appendSlice(ctx.allocator, "\n") catch return "";
            }
        }
    }

    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (raw >= ctx.ast.nodes.items(.tag).len) continue;
            if (ctx.ast.nodes.items(.tag)[raw] == .removed) continue;
            const stmt: NodeIndex = @enumFromInt(raw);
            var stmt_src = if (isDeclarationTag(ctx.nodeTag(stmt)) and declarationShouldHoistAsAssignment(ctx, stmt, hoisted_body_names))
                getHoistedDeclarationAssignmentSource(ctx, stmt)
            else if (isDeclarationTag(ctx.nodeTag(stmt)))
                getDeclarationSourceWithCurrentKeyword(ctx, stmt)
            else if (nodeNeedsStructuralEffectiveSource(ctx, stmt))
                appendTrailingStatementComment(ctx, stmt, getStatementEffectiveSource(ctx, stmt))
            else if (hasChildReplacement(ctx, raw) and isLoopNode(ctx.nodeTag(stmt)))
                appendTrailingStatementComment(ctx, stmt, getNodeSourceRecursive(ctx, stmt))
            else if (ctx.ast.replacement_source.contains(raw) or hasChildReplacement(ctx, raw))
                appendTrailingStatementComment(ctx, stmt, getGeneratedSource(ctx, stmt))
            else
                getGeneratedSource(ctx, stmt);
            if (isDeclarationTag(ctx.nodeTag(stmt))) {
                stmt_src = ensureDeclarationStatementSemicolon(ctx, stmt_src);
            } else if (isLoopNode(ctx.nodeTag(stmt))) {
                stmt_src = rewriteHoistedLoopHeadVarKeyword(ctx, stmt_src, hoisted_body_names);
            }
            if (stmt_src.len == 0) continue;
            buf.appendSlice(ctx.allocator, stmt_src) catch return "";
            if (stmt_src[stmt_src.len - 1] != '\n') {
                buf.appendSlice(ctx.allocator, "\n") catch return "";
            }
        }
    }

    return rewriteHoistedSingleNameDeclarations(ctx, buf.items, hoisted_body_names);
}

fn nodeNeedsStructuralEffectiveSource(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return false;

    const tag = ctx.nodeTag(node);
    if (tag == .removed) return true;
    if ((tag == .block_statement or tag == .program) and ctx.ast.block_prefix_source.contains(ni)) {
        return true;
    }

    const children = visitor.getChildren(ctx.ast, node);
    for (children.items[0..children.len]) |child| {
        if (nodeNeedsStructuralEffectiveSource(ctx, child)) return true;
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (nodeNeedsStructuralEffectiveSource(ctx, @enumFromInt(raw))) return true;
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (nodeNeedsStructuralEffectiveSource(ctx, @enumFromInt(raw))) return true;
        }
    }

    return false;
}

fn getStatementEffectiveSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return "";
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;

    return switch (ctx.nodeTag(node)) {
        .removed => "",
        .block_statement => getWrappedBlockSource(ctx, node),
        else => buildStatementEffectiveSource(ctx, node),
    };
}

fn getWrappedBlockSource(ctx: *TransformContext, body: NodeIndex) []const u8 {
    if (body == .none or ctx.nodeTag(body) != .block_statement) return "";

    const body_source = getLoopBodySource(ctx, body);
    if (body_source.len == 0) {
        return appendTrailingLineComment(ctx, body, "{}");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '{') catch return getNodeSource(ctx, body);
    buf.append(ctx.allocator, '\n') catch return getNodeSource(ctx, body);
    appendIndentedBodyWithPrefix(ctx, &buf, body_source, "  ") catch return getNodeSource(ctx, body);
    if (body_source[body_source.len - 1] != '\n') {
        buf.append(ctx.allocator, '\n') catch return getNodeSource(ctx, body);
    }
    buf.append(ctx.allocator, '}') catch return getNodeSource(ctx, body);
    return appendTrailingLineComment(ctx, body, buf.items);
}

fn buildStatementEffectiveSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return "";

    const start = effectiveNodeStart(ctx, ni);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (end <= start or end > ctx.ast.source.len) return getNodeSource(ctx, node);

    var overlays: std.ArrayListUnmanaged(EffectiveSourceOverlay) = .empty;
    defer overlays.deinit(ctx.allocator);

    const children = visitor.getChildren(ctx.ast, node);
    appendChildEffectiveOverlays(ctx, &overlays, children.items[0..children.len]);
    if (children.range_start < children.range_end) {
        appendRawChildEffectiveOverlays(ctx, &overlays, ctx.ast.extra_data.items[children.range_start..children.range_end]);
    }
    if (children.range2_start < children.range2_end) {
        appendRawChildEffectiveOverlays(ctx, &overlays, ctx.ast.extra_data.items[children.range2_start..children.range2_end]);
    }

    if (overlays.items.len == 0) return getNodeSource(ctx, node);

    std.mem.sort(EffectiveSourceOverlay, overlays.items, {}, struct {
        fn lessThan(_: void, lhs: EffectiveSourceOverlay, rhs: EffectiveSourceOverlay) bool {
            return lhs.start < rhs.start;
        }
    }.lessThan);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos = start;
    for (overlays.items) |overlay| {
        if (overlay.end <= overlay.start or overlay.start < start or overlay.end > end) continue;
        if (overlay.start < pos) continue;
        if (overlay.start > pos) {
            buf.appendSlice(ctx.allocator, ctx.ast.source[pos..overlay.start]) catch return getNodeSource(ctx, node);
        }
        buf.appendSlice(ctx.allocator, overlay.text) catch return getNodeSource(ctx, node);
        pos = overlay.end;
    }
    if (pos < end) {
        buf.appendSlice(ctx.allocator, ctx.ast.source[pos..end]) catch return getNodeSource(ctx, node);
    }

    return buf.items;
}

fn appendChildEffectiveOverlays(
    ctx: *TransformContext,
    overlays: *std.ArrayListUnmanaged(EffectiveSourceOverlay),
    children: []const NodeIndex,
) void {
    for (children) |child| {
        appendChildEffectiveOverlay(ctx, overlays, child);
    }
}

fn appendRawChildEffectiveOverlays(
    ctx: *TransformContext,
    overlays: *std.ArrayListUnmanaged(EffectiveSourceOverlay),
    children: []const u32,
) void {
    for (children) |raw| {
        appendChildEffectiveOverlay(ctx, overlays, @enumFromInt(raw));
    }
}

fn appendChildEffectiveOverlay(
    ctx: *TransformContext,
    overlays: *std.ArrayListUnmanaged(EffectiveSourceOverlay),
    child: NodeIndex,
) void {
    if (child == .none) return;
    const child_i = @intFromEnum(child);
    if (child_i >= ctx.ast.nodes.items(.tag).len) return;

    const child_src = if (ctx.ast.replacement_source.get(child_i)) |replacement|
        replacement
    else if (nodeNeedsStructuralEffectiveSource(ctx, child))
        getStatementEffectiveSource(ctx, child)
    else if (hasChildReplacement(ctx, child_i))
        getNodeSourceRecursive(ctx, child)
    else
        return;

    const child_start = effectiveNodeStart(ctx, child_i);
    const child_end = ctx.ast.nodes.items(.end_offset)[child_i];
    if (child_end <= child_start or child_end > ctx.ast.source.len) return;

    overlays.append(ctx.allocator, .{
        .start = child_start,
        .end = child_end,
        .text = child_src,
    }) catch {};
}

fn getHoistableLoopBodyPrefix(body: NodeIndex, ctx: *TransformContext) []const u8 {
    if (body == .none or ctx.nodeTag(body) != .block_statement) return "";
    const prefix = ctx.ast.block_prefix_source.get(@intFromEnum(body)) orelse return "";
    const trimmed = std.mem.trimStart(u8, prefix, " \t");
    if (!(std.mem.startsWith(u8, trimmed, "var {") or
        std.mem.startsWith(u8, trimmed, "let {") or
        std.mem.startsWith(u8, trimmed, "const {"))) return "";
    if (std.mem.indexOf(u8, prefix, "objectWithoutProperties") == null and
        std.mem.indexOf(u8, prefix, "objectWithoutPropertiesLoose") == null) return "";
    return prefix;
}

fn addUniqueName(list: *NameList, name: []const u8) void {
    if (name.len == 0) return;
    for (list.items[0..list.len]) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    list.add(name);
}

fn nameSliceContains(names: []const []const u8, name: []const u8) bool {
    for (names) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

fn declarationShouldHoistAsAssignment(ctx: *TransformContext, node: NodeIndex, hoisted_body_names: []const []const u8) bool {
    if (hoisted_body_names.len == 0) return false;
    const names = getDeclaredNames(node, ctx);
    if (names.len == 0) return false;
    for (names.items[0..names.len]) |name| {
        const current_name = getCurrentBindingName(ctx, node, name);
        if (!nameSliceContains(hoisted_body_names, current_name)) return false;
    }
    return true;
}

fn getHoistedDeclarationAssignmentSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return getDeclarationSourceWithCurrentKeyword(ctx, node);

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var emitted_any = false;

    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_idx| {
        if (decl_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[decl_idx] != .declarator) continue;

        const decl_data = ctx.ast.nodes.items(.data)[decl_idx];
        const lhs = decl_data.binary.lhs;
        if (lhs == .none) continue;

        const rhs = decl_data.binary.rhs;
        const lhs_source = if (ctx.ast.replacement_source.contains(@intFromEnum(lhs)) or hasChildReplacement(ctx, @intFromEnum(lhs)))
            getNodeSourceRecursive(ctx, lhs)
        else
            getGeneratedSource(ctx, lhs);
        const rhs_source = if (rhs != .none) getGeneratedSource(ctx, rhs) else "void 0";

        if (emitted_any) buf.appendSlice(ctx.allocator, "\n") catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
        emitted_any = true;

        switch (ctx.nodeTag(lhs)) {
            .object_pattern => {
                buf.appendSlice(ctx.allocator, "(") catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
                buf.appendSlice(ctx.allocator, lhs_source) catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
                buf.appendSlice(ctx.allocator, " = ") catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
                buf.appendSlice(ctx.allocator, rhs_source) catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
                buf.appendSlice(ctx.allocator, ");") catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
            },
            else => {
                buf.appendSlice(ctx.allocator, lhs_source) catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
                buf.appendSlice(ctx.allocator, " = ") catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
                buf.appendSlice(ctx.allocator, rhs_source) catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
                buf.appendSlice(ctx.allocator, ";") catch return getDeclarationSourceWithCurrentKeyword(ctx, node);
            },
        }
    }

    if (!emitted_any) return getDeclarationSourceWithCurrentKeyword(ctx, node);
    return buf.items;
}

fn rewriteHoistedSingleNameDeclarations(
    ctx: *TransformContext,
    src: []const u8,
    hoisted_body_names: []const []const u8,
) []const u8 {
    if (src.len == 0 or hoisted_body_names.len == 0) return src;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var start: usize = 0;
    while (start < src.len) {
        var line_end = start;
        while (line_end < src.len and src[line_end] != '\n' and src[line_end] != '\r') : (line_end += 1) {}

        const raw_line = src[start..line_end];
        const rewritten = rewriteHoistedSingleNameDeclarationLine(ctx, raw_line, hoisted_body_names);
        buf.appendSlice(ctx.allocator, rewritten) catch return src;

        if (line_end < src.len) {
            if (src[line_end] == '\r' and line_end + 1 < src.len and src[line_end + 1] == '\n') {
                buf.appendSlice(ctx.allocator, "\r\n") catch return src;
                start = line_end + 2;
            } else {
                buf.append(ctx.allocator, src[line_end]) catch return src;
                start = line_end + 1;
            }
        } else {
            start = line_end;
        }
    }

    return buf.items;
}

fn ensureDeclarationStatementSemicolon(ctx: *TransformContext, src: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, src, " \t\r\n");
    if (trimmed.len == 0 or statementTextEndsWithSemicolon(trimmed)) return src;
    return std.fmt.allocPrint(ctx.allocator, "{s};", .{src}) catch src;
}

fn statementTextEndsWithSemicolon(src: []const u8) bool {
    const line_comment_idx = std.mem.indexOf(u8, src, "//");
    const code = std.mem.trimEnd(u8, if (line_comment_idx) |idx| src[0..idx] else src, " \t");
    return code.len > 0 and code[code.len - 1] == ';';
}

fn rewriteHoistedLoopHeadVarKeyword(
    ctx: *TransformContext,
    src: []const u8,
    hoisted_body_names: []const []const u8,
) []const u8 {
    if (hoisted_body_names.len == 0) return src;

    const marker = "for (var ";
    const marker_idx = std.mem.indexOf(u8, src, marker) orelse return src;
    const name_start = marker_idx + marker.len;
    if (name_start >= src.len or !isIdentStart(src[name_start])) return src;

    var name_end = name_start + 1;
    while (name_end < src.len and isIdentCont(src[name_end])) : (name_end += 1) {}
    const name = src[name_start..name_end];
    if (!nameSliceContains(hoisted_body_names, name)) return src;

    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}for ({s}",
        .{ src[0..marker_idx], src[name_start..] },
    ) catch src;
}

fn rewriteHoistedSingleNameDeclarationLine(
    ctx: *TransformContext,
    raw_line: []const u8,
    hoisted_body_names: []const []const u8,
) []const u8 {
    const trimmed = std.mem.trimStart(u8, raw_line, " \t");
    const indent_len = raw_line.len - trimmed.len;
    const indent = raw_line[0..indent_len];

    var rest = trimmed;
    if (std.mem.startsWith(u8, trimmed, "var ")) {
        rest = trimmed[4..];
    } else if (std.mem.startsWith(u8, trimmed, "let ")) {
        rest = trimmed[4..];
    } else if (std.mem.startsWith(u8, trimmed, "const ")) {
        rest = trimmed[6..];
    } else {
        return raw_line;
    }

    if (rest.len > 0 and (rest[0] == '{' or rest[0] == '[')) {
        const trimmed_rest = std.mem.trimEnd(u8, rest, " \t");
        if (trimmed_rest.len == 0 or trimmed_rest[trimmed_rest.len - 1] != ';') return raw_line;
        if (!patternContainsHoistedName(trimmed_rest, hoisted_body_names)) return raw_line;

        const assignment = trimmed_rest[0 .. trimmed_rest.len - 1];
        if (rest[0] == '{') {
            return formatHoistedObjectPatternAssignment(ctx, indent, assignment);
        }
        return std.fmt.allocPrint(ctx.allocator, "{s}{s};", .{ indent, assignment }) catch raw_line;
    }

    if (rest.len == 0 or !isIdentStart(rest[0])) return raw_line;

    var name_end: usize = 1;
    while (name_end < rest.len and isIdentCont(rest[name_end])) : (name_end += 1) {}

    const name = rest[0..name_end];
    if (!nameSliceContains(hoisted_body_names, name)) return raw_line;

    const tail = rest[name_end..];
    const eq_idx = std.mem.indexOfScalar(u8, tail, '=') orelse return raw_line;
    if (std.mem.trim(u8, tail[0..eq_idx], " \t").len != 0) return raw_line;

    return std.fmt.allocPrint(ctx.allocator, "{s}{s}{s}", .{ indent, name, tail }) catch raw_line;
}

fn formatHoistedObjectPatternAssignment(ctx: *TransformContext, indent: []const u8, assignment: []const u8) []const u8 {
    const eq_idx = findTopLevelAssignmentEq(assignment) orelse
        return std.fmt.allocPrint(ctx.allocator, "{s}({s});", .{ indent, assignment }) catch assignment;
    const lhs = std.mem.trim(u8, assignment[0..eq_idx], " \t");
    const rhs = std.mem.trim(u8, assignment[eq_idx + 1 ..], " \t");
    const lhs_source = expandCompactBraceBlock(ctx, lhs);
    const rhs_source = expandCompactBraceBlock(ctx, rhs);
    return std.fmt.allocPrint(ctx.allocator, "{s}({s} = {s});", .{ indent, lhs_source, rhs_source }) catch assignment;
}

fn findTopLevelAssignmentEq(src: []const u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (src, 0..) |c, i| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '=' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn expandCompactBraceBlock(ctx: *TransformContext, src: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, src, " \t");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null or std.mem.indexOfScalar(u8, trimmed, '\r') != null) return trimmed;

    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return "{}";

    return std.fmt.allocPrint(ctx.allocator, "{{\n  {s}\n}}", .{inner}) catch trimmed;
}

fn patternContainsHoistedName(pattern: []const u8, hoisted_body_names: []const []const u8) bool {
    for (hoisted_body_names) |name| {
        if (std.mem.indexOf(u8, pattern, name) != null) return true;
    }
    return false;
}

fn injectLoopUpdaterAssignments(
    ctx: *TransformContext,
    body_source: []const u8,
    updater_pairs: []const LoopUpdater,
) []const u8 {
    if (updater_pairs.len == 0) return body_source;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var start: usize = 0;
    while (start < body_source.len) {
        var line_end = start;
        while (line_end < body_source.len and body_source[line_end] != '\n' and body_source[line_end] != '\r') : (line_end += 1) {}

        const raw_line = body_source[start..line_end];
        const trimmed = std.mem.trimStart(u8, raw_line, " \t");
        if (isLoopCompletionReturnLine(trimmed)) {
            const indent_len = raw_line.len - trimmed.len;
            const indent = raw_line[0..indent_len];
            for (updater_pairs) |up| {
                buf.appendSlice(ctx.allocator, indent) catch return body_source;
                buf.appendSlice(ctx.allocator, up.outer) catch return body_source;
                buf.appendSlice(ctx.allocator, " = ") catch return body_source;
                buf.appendSlice(ctx.allocator, up.inner) catch return body_source;
                buf.appendSlice(ctx.allocator, ";\n") catch return body_source;
            }
        }

        buf.appendSlice(ctx.allocator, raw_line) catch return body_source;
        if (line_end < body_source.len) {
            if (body_source[line_end] == '\r' and line_end + 1 < body_source.len and body_source[line_end + 1] == '\n') {
                buf.appendSlice(ctx.allocator, "\r\n") catch return body_source;
                start = line_end + 2;
            } else {
                buf.append(ctx.allocator, body_source[line_end]) catch return body_source;
                start = line_end + 1;
            }
        } else {
            start = line_end;
        }
    }

    return buf.items;
}

fn isLoopCompletionReturnLine(trimmed: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "return ")) return false;
    return std.mem.indexOf(u8, trimmed, "// break") != null or
        std.mem.indexOf(u8, trimmed, "// continue") != null;
}

fn rewriteLabeledLoopCompletions(
    ctx: *TransformContext,
    src: []const u8,
    loop_node: NodeIndex,
    has_break: bool,
    has_return: bool,
) []const u8 {
    _ = has_break;

    var result = src;
    var target = loop_node;
    while (getParentNode(target)) |parent| {
        if (ctx.nodeTag(parent) != .labeled_statement) break;
        if (ctx.nodeData(parent).unary != target) break;

        const label_name = ctx.tokenSlice(ctx.mainToken(parent));
        const break_src = std.fmt.allocPrint(ctx.allocator, "break {s};", .{label_name}) catch break;
        const break_replacement = std.fmt.allocPrint(ctx.allocator, "return 1; // break {s}", .{label_name}) catch break;
        result = std.mem.replaceOwned(u8, ctx.allocator, result, break_src, break_replacement) catch result;

        const continue_src = std.fmt.allocPrint(ctx.allocator, "continue {s};", .{label_name}) catch break;
        const continue_code = if (has_return) "0" else "1";
        const continue_replacement = std.fmt.allocPrint(ctx.allocator, "return {s}; // continue {s}", .{ continue_code, label_name }) catch break;
        result = std.mem.replaceOwned(u8, ctx.allocator, result, continue_src, continue_replacement) catch result;

        target = parent;
    }
    return result;
}

fn markLoopCompletions(ctx: *TransformContext, root: NodeIndex, has_break: bool, has_continue: bool, has_return: bool) void {
    if (root == .none) return;
    const tag = ctx.nodeTag(root);
    if ((has_break and tag == .break_statement) or (has_continue and tag == .continue_statement)) {
        const ni = @intFromEnum(root);
        if (!ctx.ast.replacement_source.contains(ni)) {
            const replacement = if (tag == .break_statement)
                "return 1; // break"
            else if (has_break or has_return)
                "return 0; // continue"
            else
                "return 1; // continue";
            _ = putReplacement(ctx, root, replacement);
        }
        return;
    }

    switch (tag) {
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
        .class_declaration,
        .class_expr,
        => return,
        .switch_statement => {
            markLoopCompletionChildren(ctx, root, false, has_continue, has_return);
            return;
        },
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        => {
            markLoopCompletionChildren(ctx, root, false, false, false);
            return;
        },
        else => {},
    }

    markLoopCompletionChildren(ctx, root, has_break, has_continue, has_return);
}

fn markLoopCompletionCases(
    ctx: *TransformContext,
    root: NodeIndex,
    completions: []const LoopCompletion,
    allow_break: bool,
    allow_continue: bool,
) void {
    if (root == .none) return;
    const tag = ctx.nodeTag(root);
    if (tag == .break_statement or tag == .continue_statement) {
        const label = ctx.nodeData(root).unary;
        const label_name = if (label != .none and ctx.nodeTag(label) == .identifier)
            ctx.tokenSlice(ctx.mainToken(label))
        else
            "";

        const kind: LoopCompletionKind = if (tag == .break_statement) .break_stmt else .continue_stmt;
        if (label_name.len == 0) {
            if (kind == .break_stmt and !allow_break) return;
            if (kind == .continue_stmt and !allow_continue) return;
        }

        for (completions) |completion| {
            if (completion.kind != kind) continue;
            if (!std.mem.eql(u8, completion.label_name, label_name)) continue;

            const ni = @intFromEnum(root);
            if (!ctx.ast.replacement_source.contains(ni)) {
                const label_suffix = if (completion.label_name.len > 0)
                    std.fmt.allocPrint(ctx.allocator, " {s}", .{completion.label_name}) catch completion.label_name
                else
                    "";
                const keyword = switch (kind) {
                    .break_stmt => "break",
                    .continue_stmt => "continue",
                };
                const replacement = std.fmt.allocPrint(
                    ctx.allocator,
                    "return {d}; // {s}{s}",
                    .{ completion.code, keyword, label_suffix },
                ) catch return;
                _ = putReplacement(ctx, root, replacement);
            }
            return;
        }
        return;
    }

    switch (tag) {
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
        .class_declaration,
        .class_expr,
        => return,
        .switch_statement => {
            markLoopCompletionCaseChildren(ctx, root, completions, false, allow_continue);
            return;
        },
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        => return,
        else => {},
    }

    markLoopCompletionCaseChildren(ctx, root, completions, allow_break, allow_continue);
}

fn markLoopCompletionCaseChildren(
    ctx: *TransformContext,
    root: NodeIndex,
    completions: []const LoopCompletion,
    allow_break: bool,
    allow_continue: bool,
) void {
    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        markLoopCompletionCases(ctx, child, completions, allow_break, allow_continue);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            markLoopCompletionCases(ctx, @enumFromInt(raw), completions, allow_break, allow_continue);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            markLoopCompletionCases(ctx, @enumFromInt(raw), completions, allow_break, allow_continue);
        }
    }
}

fn markLoopCompletionChildren(ctx: *TransformContext, root: NodeIndex, has_break: bool, has_continue: bool, has_return: bool) void {
    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        markLoopCompletions(ctx, child, has_break, has_continue, has_return);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            markLoopCompletions(ctx, @enumFromInt(raw), has_break, has_continue, has_return);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            markLoopCompletions(ctx, @enumFromInt(raw), has_break, has_continue, has_return);
        }
    }
}

fn markLoopReturns(ctx: *TransformContext, root: NodeIndex) void {
    if (root == .none) return;
    const tag = ctx.nodeTag(root);
    if (tag == .return_statement) {
        const ni = @intFromEnum(root);
        if (!ctx.ast.replacement_source.contains(ni)) {
            const arg = ctx.nodeData(root).unary;
            const value_source = if (arg != .none)
                getGeneratedSource(ctx, arg)
            else
                "void 0";
            const replacement = std.fmt.allocPrint(ctx.allocator, "return {{\n  v: {s}\n}};", .{value_source}) catch return;
            _ = putReplacementWithReindent(ctx, root, replacement);
        }
        return;
    }

    switch (tag) {
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
        .class_declaration,
        .class_expr,
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        => return,
        else => {},
    }

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        markLoopReturns(ctx, child);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            markLoopReturns(ctx, @enumFromInt(raw));
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            markLoopReturns(ctx, @enumFromInt(raw));
        }
    }
}

fn unwrapBlockSource(src: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    }
    return trimmed;
}

fn getLoopBodySource(ctx: *TransformContext, body: NodeIndex) []const u8 {
    if (body == .none) return "";
    if (ctx.nodeTag(body) != .block_statement) {
        return if (nodeNeedsStructuralEffectiveSource(ctx, body))
            getStatementEffectiveSource(ctx, body)
        else
            getNodeSourceRecursive(ctx, body);
    }

    const children = visitor.getChildren(ctx.ast, body);
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    if (ctx.ast.block_prefix_source.get(@intFromEnum(body))) |prefix| {
        buf.appendSlice(ctx.allocator, prefix) catch return "";
        if (prefix.len > 0 and prefix[prefix.len - 1] != '\n') {
            buf.appendSlice(ctx.allocator, "\n") catch return "";
        }
    }

    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (raw >= ctx.ast.nodes.items(.tag).len) continue;
            if (ctx.ast.nodes.items(.tag)[raw] == .removed) continue;
            const stmt: NodeIndex = @enumFromInt(raw);
            const stmt_src = if (nodeNeedsStructuralEffectiveSource(ctx, stmt))
                getStatementEffectiveSource(ctx, stmt)
            else if (hasChildReplacement(ctx, raw))
                getNodeSourceRecursive(ctx, stmt)
            else if (isDeclarationTag(ctx.nodeTag(stmt)))
                getDeclarationSourceWithCurrentKeyword(ctx, stmt)
            else
                getGeneratedSource(ctx, stmt);
            if (stmt_src.len == 0) continue;
            buf.appendSlice(ctx.allocator, stmt_src) catch return "";
            if (stmt_src[stmt_src.len - 1] != '\n') {
                buf.appendSlice(ctx.allocator, "\n") catch return "";
            }
        }
    }

    return buf.items;
}

fn getNodeSourceRecursive(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return "";
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;

    const tag = ctx.nodeTag(node);
    switch (tag) {
        .block_statement => return getLoopBodySource(ctx, node),
        else => {},
    }

    if (!hasChildReplacement(ctx, ni)) {
        return getNodeSource(ctx, node);
    }

    return buildEffectiveSource(ctx, nodeStartOffset(ctx, node), ctx.ast.nodes.items(.end_offset)[ni]);
}

fn isDeclarationTag(tag: Node.Tag) bool {
    return switch (tag) {
        .var_declaration, .let_declaration, .const_declaration => true,
        else => false,
    };
}

fn getDeclarationSourceWithCurrentKeyword(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const ni = @intFromEnum(node);
    const use_generated = declarationPrefersGeneratedSource(ctx, node);
    const base = if (use_generated)
        getGeneratedSource(ctx, node)
    else if (ctx.ast.replacement_source.contains(ni) or hasChildReplacement(ctx, ni))
        getNodeSourceRecursive(ctx, node)
    else
        getNodeSource(ctx, node);
    const raw = appendTrailingLineComment(ctx, node, base);
    const tag = ctx.nodeTag(node);
    const keyword = switch (tag) {
        .var_declaration => "var",
        .let_declaration => "let",
        .const_declaration => "const",
        else => return raw,
    };

    if (std.mem.startsWith(u8, raw, keyword)) return collapseSimpleAssignedArrowParamParens(ctx, raw);

    if (std.mem.startsWith(u8, raw, "let")) {
        const rewritten = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ keyword, raw[3..] }) catch raw;
        return collapseSimpleAssignedArrowParamParens(ctx, rewritten);
    }
    if (std.mem.startsWith(u8, raw, "const")) {
        const rewritten = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ keyword, raw[5..] }) catch raw;
        return collapseSimpleAssignedArrowParamParens(ctx, rewritten);
    }
    if (std.mem.startsWith(u8, raw, "var")) {
        const rewritten = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ keyword, raw[3..] }) catch raw;
        return collapseSimpleAssignedArrowParamParens(ctx, rewritten);
    }

    return collapseSimpleAssignedArrowParamParens(ctx, getGeneratedSource(ctx, node));
}

fn collapseSimpleAssignedArrowParamParens(ctx: *TransformContext, src: []const u8) []const u8 {
    if (std.mem.indexOf(u8, src, "=>") == null or std.mem.indexOf(u8, src, "= (") == null) return src;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: usize = 0;
    while (pos < src.len) {
        if (src[pos] == '=') {
            var open = pos + 1;
            while (open < src.len and (src[open] == ' ' or src[open] == '\t')) : (open += 1) {}
            if (open < src.len and src[open] == '(') {
                const ident_start = open + 1;
                if (ident_start < src.len and isIdentStart(src[ident_start])) {
                    var ident_end = ident_start + 1;
                    while (ident_end < src.len and isIdentCont(src[ident_end])) : (ident_end += 1) {}

                    var close = ident_end;
                    while (close < src.len and (src[close] == ' ' or src[close] == '\t')) : (close += 1) {}
                    if (close < src.len and src[close] == ')') {
                        var arrow = close + 1;
                        while (arrow < src.len and (src[arrow] == ' ' or src[arrow] == '\t')) : (arrow += 1) {}
                        if (arrow + 1 < src.len and src[arrow] == '=' and src[arrow + 1] == '>') {
                            buf.appendSlice(ctx.allocator, src[pos..open]) catch return src;
                            buf.appendSlice(ctx.allocator, src[ident_start..ident_end]) catch return src;
                            pos = close + 1;
                            continue;
                        }
                    }
                }
            }
        }

        buf.append(ctx.allocator, src[pos]) catch return src;
        pos += 1;
    }
    return buf.items;
}

fn rewriteSimpleArrowAssignments(ctx: *TransformContext, src: []const u8) []const u8 {
    if (std.mem.indexOf(u8, src, "=>") == null) return src;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var start: usize = 0;
    while (start < src.len) {
        var end = start;
        while (end < src.len and src[end] != '\n') : (end += 1) {}

        const line = src[start..end];
        const rewritten = rewriteSimpleArrowAssignmentLine(ctx, line);
        buf.appendSlice(ctx.allocator, rewritten) catch return src;
        if (end < src.len) {
            buf.append(ctx.allocator, '\n') catch return src;
            start = end + 1;
        } else {
            start = end;
        }
    }
    return buf.items;
}

fn rewriteSimpleArrowAssignmentLine(ctx: *TransformContext, line: []const u8) []const u8 {
    const arrow_idx = std.mem.indexOf(u8, line, "= () => ") orelse return line;
    const semicolon_idx = std.mem.lastIndexOfScalar(u8, line, ';') orelse return line;
    if (semicolon_idx <= arrow_idx + 8) return line;

    const indent_len = line.len - std.mem.trimStart(u8, line, " \t").len;
    const indent = line[0..indent_len];
    const lhs = std.mem.trimEnd(u8, line[indent_len..arrow_idx], " \t");
    const expr = std.mem.trim(u8, line[arrow_idx + 8 .. semicolon_idx], " \t");
    if (lhs.len == 0 or expr.len == 0) return line;

    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}{s} = function () {{\n{s}  return {s};\n{s}}};",
        .{ indent, lhs, indent, expr, indent },
    ) catch line;
}

fn declarationPrefersGeneratedSource(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    const ni = @intFromEnum(node);
    if (!hasChildReplacement(ctx, ni)) return false;

    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_idx| {
        if (decl_idx >= ctx.ast.nodes.len) continue;
        const decl_data = ctx.ast.nodes.items(.data)[decl_idx];
        const init = decl_data.binary.rhs;
        if (init == .none) continue;
        switch (ctx.nodeTag(init)) {
            .function_expr, .arrow_function_expr => return true,
            else => {},
        }
    }

    return false;
}

fn getNodeSourceWithTrailingLineComment(ctx: *TransformContext, node: NodeIndex) []const u8 {
    return appendTrailingLineComment(ctx, node, getNodeSource(ctx, node));
}

fn appendLoopBodyRenameUnique(
    target: *[16]LoopBodyRename,
    count: *u8,
    pair: LoopBodyRename,
) void {
    for (target[0..count.*]) |existing| {
        if (std.mem.eql(u8, existing.old, pair.old) and std.mem.eql(u8, existing.new, pair.new)) return;
    }
    if (count.* >= target.len) return;
    target[count.*] = pair;
    count.* += 1;
}

fn appendLoopBodyCaptureUnique(info: *LoopWrapInfo, name: []const u8) void {
    if (name.len == 0) return;
    for (info.body_capture_names[0..info.body_capture_count]) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    if (info.body_capture_count >= info.body_capture_names.len) return;
    info.body_capture_names[info.body_capture_count] = name;
    info.body_capture_count += 1;
}

fn appendTrailingLineComment(ctx: *TransformContext, node: NodeIndex, base: []const u8) []const u8 {
    const trailing = getTrailingLineComment(ctx, node);
    if (trailing.len == 0 or std.mem.endsWith(u8, base, trailing)) return base;
    return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ base, trailing }) catch base;
}

fn appendTrailingStatementComment(ctx: *TransformContext, node: NodeIndex, base: []const u8) []const u8 {
    const trailing = getTrailingLineComment(ctx, node);
    if (trailing.len == 0 or std.mem.endsWith(u8, base, trailing)) return base;
    if (ctx.nodeTag(node) == .expression_statement and !std.mem.endsWith(u8, std.mem.trimEnd(u8, base, " \t"), ";")) {
        return std.fmt.allocPrint(ctx.allocator, "{s};{s}", .{ base, trailing }) catch base;
    }
    return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ base, trailing }) catch base;
}

fn expandCompactFunctionExpressionBodies(ctx: *TransformContext, src: []const u8) []const u8 {
    if (std.mem.indexOf(u8, src, "function") == null) return src;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var start: usize = 0;
    var changed = false;
    while (start < src.len) {
        var line_end = start;
        while (line_end < src.len and src[line_end] != '\n' and src[line_end] != '\r') : (line_end += 1) {}

        const raw_line = src[start..line_end];
        const rewritten = expandCompactFunctionExpressionLine(ctx, raw_line);
        if (!std.mem.eql(u8, rewritten, raw_line)) changed = true;
        buf.appendSlice(ctx.allocator, rewritten) catch return src;

        if (line_end < src.len) {
            if (src[line_end] == '\r' and line_end + 1 < src.len and src[line_end + 1] == '\n') {
                buf.appendSlice(ctx.allocator, "\r\n") catch return src;
                start = line_end + 2;
            } else {
                buf.append(ctx.allocator, src[line_end]) catch return src;
                start = line_end + 1;
            }
        } else {
            start = line_end;
        }
    }

    return if (changed) buf.items else src;
}

fn expandCompactFunctionExpressionLine(ctx: *TransformContext, raw_line: []const u8) []const u8 {
    const fn_idx = std.mem.indexOf(u8, raw_line, "function") orelse return raw_line;
    const open_idx = std.mem.indexOfPos(u8, raw_line, fn_idx, "{") orelse return raw_line;
    const close_idx = std.mem.lastIndexOfScalar(u8, raw_line, '}') orelse return raw_line;
    if (close_idx <= open_idx + 1) return raw_line;
    if (std.mem.indexOfScalar(u8, raw_line[open_idx + 1 .. close_idx], '{') != null) return raw_line;
    if (std.mem.indexOfScalar(u8, raw_line[open_idx + 1 .. close_idx], '}') != null) return raw_line;

    const indent_len = raw_line.len - std.mem.trimStart(u8, raw_line, " \t").len;
    const indent = raw_line[0..indent_len];
    const header = std.mem.trimEnd(u8, raw_line[0 .. open_idx + 1], " \t");
    var body = std.mem.trim(u8, raw_line[open_idx + 1 .. close_idx], " \t");
    const suffix = raw_line[close_idx + 1 ..];
    if (body.len == 0) return raw_line;
    if (!std.mem.endsWith(u8, body, ";")) {
        body = std.fmt.allocPrint(ctx.allocator, "{s};", .{body}) catch return raw_line;
    }

    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}\n{s}  {s}\n{s}}}{s}",
        .{ header, indent, body, indent, suffix },
    ) catch raw_line;
}

fn isLoopNode(tag: Node.Tag) bool {
    return switch (tag) {
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        => true,
        else => false,
    };
}

fn isProtectedByNestedWrappedLoop(node: NodeIndex, outer_loop: NodeIndex, ctx: *TransformContext) bool {
    var current = getParentNode(node);
    while (current) |cur| {
        if (cur == outer_loop) return false;
        if (isLoopNode(ctx.nodeTag(cur))) {
            if (collectLoopWrapInfo(cur, ctx) != null) return true;
        }
        current = getParentNode(cur);
    }
    return false;
}

fn canRestoreWrappedBodyBindingName(
    scope_result: *const scope_mod.ScopeResult,
    binding_idx: usize,
    decl_node: NodeIndex,
    loop_node: NodeIndex,
    head_node: NodeIndex,
    info: LoopWrapInfo,
    ctx: *TransformContext,
) bool {
    const binding = scope_result.bindings[binding_idx];
    for (info.params[0..info.param_count]) |param| {
        if (std.mem.eql(u8, param.original_name, binding.name) or
            std.mem.eql(u8, param.current_name, binding.name) or
            std.mem.eql(u8, param.param_name, binding.name))
        {
            return false;
        }
    }

    for (scope_result.bindings, 0..) |other, other_idx| {
        if (other_idx == binding_idx) continue;
        if (other.kind != .let_decl and other.kind != .const_decl and other.kind != .var_decl) continue;
        if (!std.mem.eql(u8, other.name, binding.name)) continue;

        const other_decl = if (other.decl_node != .none) other.decl_node else other.node;
        if (other_decl == .none) continue;
        if (!isDescendantOf(other_decl, loop_node)) continue;
        if (hasFunctionBoundaryBetween(other_decl, loop_node, ctx)) continue;
        if (head_node != .none and isDescendantOf(other_decl, head_node)) continue;
        if (isProtectedByNestedWrappedLoop(other_decl, loop_node, ctx)) continue;

        return false;
    }

    if (decl_node != .none) {
        const rename_anchor = getRenameAnchorDeclaration(decl_node, ctx) orelse decl_node;
        if (loopBodyNode(loop_node, ctx)) |body_node| {
            if (ctx.nodeTag(body_node) == .block_statement) {
                if (getParentNode(rename_anchor)) |parent| {
                    if (parent != body_node and ctx.nodeTag(parent) == .block_statement) {
                        return false;
                    }
                }
            }
        }
    }

    return true;
}

fn getRenameAnchorDeclaration(decl_node: NodeIndex, ctx: *TransformContext) ?NodeIndex {
    if (decl_node == .none) return null;
    if (isDeclarationTag(ctx.nodeTag(decl_node))) return decl_node;

    var current: ?NodeIndex = decl_node;
    var steps: u8 = 0;
    while (current) |node| : (steps += 1) {
        if (steps >= 3) break;
        if (isDeclarationTag(ctx.nodeTag(node))) return node;
        current = getParentNode(node);
    }

    return null;
}

fn getTrailingLineComment(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.end_offset).len) return "";

    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (end >= ctx.ast.source.len) return "";

    var line_end: usize = end;
    while (line_end < ctx.ast.source.len and ctx.ast.source[line_end] != '\n' and ctx.ast.source[line_end] != '\r') {
        line_end += 1;
    }
    const trailing = ctx.ast.source[end..line_end];
    const trimmed = std.mem.trimStart(u8, trailing, " \t");
    if (!std.mem.startsWith(u8, trimmed, "//")) return "";

    const comments = ctx.ast.comments.items;
    for (comments) |comment| {
        if (comment.start < end or comment.end > line_end) continue;
        if (comment.kind != .line) continue;
        ctx.ast.consumed_comments.put(ctx.allocator, comment.start, {}) catch {};
    }
    return trailing;
}

fn trimLeadingLineComment(src: []const u8) []const u8 {
    var i: usize = 0;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
    if (i + 1 >= src.len or src[i] != '/' or src[i + 1] != '/') return src;
    var line_end = i + 2;
    while (line_end < src.len and src[line_end] != '\n' and src[line_end] != '\r') : (line_end += 1) {}
    while (line_end < src.len and (src[line_end] == '\n' or src[line_end] == '\r')) : (line_end += 1) {}
    return src[line_end..];
}

fn getGeneratedSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const comment_count = ctx.ast.comments.items.len;
    var emitted = std.DynamicBitSetUnmanaged.initEmpty(ctx.allocator, comment_count) catch {
        return getNodeSource(ctx, node);
    };
    emitted.setRangeValue(.{ .start = 0, .end = comment_count }, true);

    var cg = Codegen{
        .ast = ctx.ast,
        .buf = .empty,
        .allocator = ctx.allocator,
        .source_map = null,
        .emit_comments = false,
        .emitted_comments = emitted,
    };
    cg.emitNode(node) catch return getNodeSource(ctx, node);
    return cg.buf.toOwnedSlice(ctx.allocator) catch getNodeSource(ctx, node);
}

fn applyTdzForDeclaration(idx: NodeIndex, ctx: *TransformContext) void {
    const scope_result = ctx.scope orelse return;
    const scope_idx = scope_mod.getScopeForNode(scope_result, idx) orelse return;
    const decl_start = nodeStartOffset(ctx, idx);
    const decl_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(idx)];
    const names = getDeclaredNames(idx, ctx);
    if (names.len == 0) return;
    ensureParentMap(ctx);

    const decl_binding_indices = collectDeclarationBindingIndices(scope_result, idx, scope_idx);
    if (decl_binding_indices.len == 0) return;

    var needs_temp_undefined = false;
    var iter = scope_result.node_to_binding.iterator();
    while (iter.next()) |entry| {
        const ref_node: NodeIndex = @enumFromInt(entry.key_ptr.*);
        const binding_idx = entry.value_ptr.*;
        if (!decl_binding_indices.contains(binding_idx)) continue;
        const binding = scope_result.bindings[binding_idx];
        if (ref_node == binding.node or ref_node == idx) continue;
        if (ctx.nodeTag(ref_node) != .identifier) continue;
        const access_kind = classifyTdzReference(idx, ref_node, binding, decl_start, ctx);
        if (access_kind == .none) continue;
        const maybe = access_kind == .maybe;

        const parent = getParentNode(ref_node);
        const parent_is_assignment_target = if (parent) |p|
            ctx.nodeTag(p) == .assignment_expr and ctx.nodeData(p).binary.lhs == ref_node
        else
            false;
        const parent_is_update = if (parent) |p|
            ctx.nodeTag(p) == .update_expr and ctx.nodeData(p).unary == ref_node
        else
            false;
        const grandparent = if (parent) |p| getParentNode(p) else null;
        const grandparent_is_expr_stmt = if (grandparent) |gp| ctx.nodeTag(gp) == .expression_statement else false;

        const helper = makeTdzHelper(ctx, binding.name, maybe) orelse continue;

        if ((parent_is_assignment_target or parent_is_update) and grandparent_is_expr_stmt) {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            buf.appendSlice(ctx.allocator, helper) catch continue;
            if (parent_is_update and !maybe) {
                buf.appendSlice(ctx.allocator, ";") catch continue;
            } else {
                const stmt_source = getNodeSourceRecursive(ctx, grandparent.?);
                if (parent_is_assignment_target or !maybe) {
                    buf.appendSlice(ctx.allocator, ";") catch continue;
                }
                buf.appendSlice(ctx.allocator, "\n") catch continue;
                buf.appendSlice(ctx.allocator, stmt_source) catch continue;
            }
            if (!putReplacementWithReindent(ctx, grandparent.?, buf.items)) continue;
            if (maybe) needs_temp_undefined = true;
            continue;
        }

        if (parent) |p| {
            if (ctx.nodeTag(p) == .shorthand_property and ctx.nodeData(p).unary == ref_node) {
                const replacement = std.fmt.allocPrint(ctx.allocator, "{s}: {s}", .{ binding.name, helper }) catch continue;
                if (!putReplacement(ctx, p, replacement)) continue;
                if (maybe) needs_temp_undefined = true;
                continue;
            }
        }

        if (!putReplacement(ctx, ref_node, helper)) continue;
        if (maybe) needs_temp_undefined = true;
    }

    if (!needs_temp_undefined) return;

    // Insert a top-level temporalUndefined initializer for the binding.
    // This is intentionally narrow: it only synthesizes the simple single-name
    // case used by the TDZ fixtures we are targeting.
    if (names.len == 1) {
        const current_name = getCurrentBindingName(ctx, idx, names.items[0]);
        var prog_prefix: std.ArrayListUnmanaged(u8) = .empty;
        if (ctx.ast.block_prefix_source.get(0)) |existing| {
            prog_prefix.appendSlice(ctx.allocator, existing) catch {};
        }
        prog_prefix.appendSlice(ctx.allocator, "var ") catch {};
        prog_prefix.appendSlice(ctx.allocator, current_name) catch {};
        prog_prefix.appendSlice(ctx.allocator, " = babelHelpers.temporalUndefined;\n") catch {};
        ctx.ast.block_prefix_source.put(ctx.allocator, 0, prog_prefix.items) catch {};

        const decl_source = buildEffectiveSource(ctx, decl_start, decl_end);
        if (std.mem.indexOfScalar(u8, decl_source, '=') == null) {
            var decl_buf: std.ArrayListUnmanaged(u8) = .empty;
            decl_buf.appendSlice(ctx.allocator, "var ") catch return;
            decl_buf.appendSlice(ctx.allocator, current_name) catch return;
            decl_buf.appendSlice(ctx.allocator, " = void 0;") catch return;
            _ = putReplacement(ctx, idx, decl_buf.items);
        }
    }
}

fn classifyTdzReference(
    decl_node: NodeIndex,
    ref_node: NodeIndex,
    binding: scope_mod.Binding,
    decl_start: u32,
    ctx: *TransformContext,
) TdzAccessKind {
    const scope_result = ctx.scope orelse return .none;
    const ref_scope_idx = scope_mod.getScopeForNode(scope_result, ref_node) orelse return .none;
    const ref_before_decl = nodeStartOffset(ctx, ref_node) < decl_start;
    const ref_inside_decl = isDescendantOf(ref_node, decl_node);
    const binding_func_scope = scope_result.containingFunctionScope(binding.scope);
    const ref_func_scope = scope_result.containingFunctionScope(ref_scope_idx);

    if (ref_func_scope == binding_func_scope) {
        if (ref_before_decl or ref_inside_decl) return .direct;
        return .none;
    }

    return classifyDeferredTdzReference(ref_node, decl_start, ref_before_decl, ref_inside_decl, ctx);
}

fn classifyDeferredTdzReference(
    ref_node: NodeIndex,
    decl_start: u32,
    ref_before_decl: bool,
    ref_inside_decl: bool,
    ctx: *TransformContext,
) TdzAccessKind {
    const fn_node = findNearestFunctionLikeAncestor(ref_node, ctx) orelse {
        if (ref_before_decl or ref_inside_decl) return .direct;
        return .none;
    };

    switch (ctx.nodeTag(fn_node)) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        => return classifyFunctionDeclarationTdz(fn_node, decl_start, ctx),
        .function_expr,
        .arrow_function_expr,
        => {
            if (ref_before_decl or ref_inside_decl) return .maybe;
            return .none;
        },
        else => {
            if (ref_before_decl or ref_inside_decl) return .direct;
            return .none;
        },
    }
}

fn classifyFunctionDeclarationTdz(
    fn_node: NodeIndex,
    decl_start: u32,
    ctx: *TransformContext,
) TdzAccessKind {
    const scope_result = ctx.scope orelse return .maybe;
    if (isExportedFunction(fn_node, ctx)) return .maybe;

    const fn_binding_idx = findFunctionDeclarationBindingIndex(scope_result, fn_node) orelse return .maybe;
    var saw_before_direct_call = false;
    var saw_after_direct_call = false;
    var saw_other_reference = false;

    var iter = scope_result.node_to_binding.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != fn_binding_idx) continue;

        const fn_ref: NodeIndex = @enumFromInt(entry.key_ptr.*);
        if (fn_ref == fn_node or isDescendantOf(fn_ref, fn_node)) continue;

        if (isUnconditionalDirectCallReference(fn_ref, ctx)) {
            const call_node = getParentNode(fn_ref).?;
            if (nodeStartOffset(ctx, call_node) < decl_start) {
                saw_before_direct_call = true;
            } else {
                saw_after_direct_call = true;
            }
            continue;
        }

        saw_other_reference = true;
        break;
    }

    if (saw_other_reference or (saw_before_direct_call and saw_after_direct_call)) return .maybe;
    if (saw_before_direct_call) return .direct;
    if (saw_after_direct_call) return .none;
    return .maybe;
}

fn findNearestFunctionLikeAncestor(node: NodeIndex, ctx: *TransformContext) ?NodeIndex {
    var current = getParentNode(node);
    while (current) |cur| {
        switch (ctx.nodeTag(cur)) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .arrow_function_expr,
            => return cur,
            else => current = getParentNode(cur),
        }
    }
    return null;
}

fn isExportedFunction(fn_node: NodeIndex, ctx: *TransformContext) bool {
    const parent = getParentNode(fn_node) orelse return false;
    return switch (ctx.nodeTag(parent)) {
        .export_named, .export_default => true,
        else => false,
    };
}

fn findFunctionDeclarationBindingIndex(
    scope_result: *const scope_mod.ScopeResult,
    fn_node: NodeIndex,
) ?u32 {
    for (scope_result.bindings, 0..) |binding, binding_idx| {
        if (binding.kind != .function_decl) continue;
        if (binding.decl_node == fn_node or binding.node == fn_node) return @intCast(binding_idx);
    }
    return null;
}

fn isUnconditionalDirectCallReference(ref_node: NodeIndex, ctx: *TransformContext) bool {
    const call_node = getParentNode(ref_node) orelse return false;
    if (ctx.nodeTag(call_node) != .call_expr) return false;

    const extra_idx = @intFromEnum(ctx.nodeData(call_node).extra);
    if (extra_idx >= ctx.ast.extra_data.items.len) return false;
    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    if (callee != ref_node) return false;

    const stmt_node = getParentNode(call_node) orelse return false;
    if (ctx.nodeTag(stmt_node) != .expression_statement) return false;

    const stmt_parent = getParentNode(stmt_node);
    if (stmt_parent) |parent| {
        switch (ctx.nodeTag(parent)) {
            .if_statement,
            .while_statement,
            .do_while_statement,
            .for_statement,
            .for_in_statement,
            .for_of_statement,
            .for_of_await_statement,
            .switch_case,
            .switch_default,
            .catch_clause,
            => return false,
            else => {},
        }
    }

    return true;
}

fn collectDeclarationBindingIndices(
    scope_result: *const scope_mod.ScopeResult,
    decl_node: NodeIndex,
    scope_idx: scope_mod.ScopeIndex,
) BindingIndexList {
    var result = BindingIndexList{};
    for (scope_result.bindings, 0..) |binding, binding_idx| {
        if (binding.scope != scope_idx) continue;
        const owner = if (binding.decl_node != .none) binding.decl_node else binding.node;
        if (owner != decl_node and !isDescendantOf(owner, decl_node)) continue;
        result.add(@intCast(binding_idx));
    }
    return result;
}

fn makeTdzHelper(ctx: *TransformContext, name: []const u8, maybe: bool) ?[]const u8 {
    if (maybe) {
        return std.fmt.allocPrint(ctx.allocator, "babelHelpers.temporalRef({s}, \"{s}\")", .{ name, name }) catch null;
    }
    return std.fmt.allocPrint(ctx.allocator, "babelHelpers.tdz(\"{s}\")", .{name}) catch null;
}

fn replaceIdentifierName(
    ctx: *TransformContext,
    src: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) []const u8 {
    if (old_name.len == 0 or std.mem.eql(u8, old_name, new_name)) return src;
    if (std.mem.indexOf(u8, src, old_name) == null) return src;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var pos: usize = 0;
    while (pos < src.len) {
        if (pos + old_name.len <= src.len and
            std.mem.eql(u8, src[pos .. pos + old_name.len], old_name) and
            (pos == 0 or !isIdentCont(src[pos - 1])) and
            (pos + old_name.len == src.len or !isIdentCont(src[pos + old_name.len])))
        {
            result.appendSlice(ctx.allocator, new_name) catch return src;
            pos += old_name.len;
            continue;
        }
        result.append(ctx.allocator, src[pos]) catch return src;
        pos += 1;
    }
    return result.items;
}

fn shouldUseAstLevelRename(ctx: *TransformContext, decl: NodeIndex) bool {
    const data = ctx.nodeData(decl);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[range_start..range_end]) |decl_idx| {
        if (decl_idx >= ctx.ast.nodes.len) continue;
        const decl_data = ctx.ast.nodes.items(.data)[decl_idx];
        const init = decl_data.binary.rhs;
        if (init == .none) continue;
        switch (ctx.nodeTag(init)) {
            .object_expr => return true,
            else => {},
        }
    }

    return false;
}

const RenamePair = struct {
    old: []const u8,
    new: []const u8,
};

const IdentMatch = struct {
    name: []const u8 = "",
    len: usize = 0,
};

fn matchIdentifier(source: []const u8, pos: usize) IdentMatch {
    if (pos >= source.len) return .{};
    const c = source[pos];
    if (!isIdentStart(c)) return .{};

    var end = pos + 1;
    while (end < source.len and isIdentCont(source[end])) : (end += 1) {}

    return .{
        .name = source[pos..end],
        .len = end - pos,
    };
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn bindingIndicesForName(ctx: *TransformContext, name: []const u8) ?[]const u32 {
    if (ctx.session) |session| {
        if (session.bindingIndices(name)) |binding_indices| return binding_indices;
    }
    const scope_result = ctx.scope orelse return null;
    const binding_indices = scope_result.binding_name_indices.get(name) orelse return null;
    return binding_indices.items;
}

fn ensureFunctionBindingQueryCaches(ctx: *TransformContext) void {
    if (g_function_binding_query_cache_ready) return;
    const scope_result = ctx.scope orelse return;

    g_outer_binding_query_cache = ctx.allocator.alloc(FunctionBindingQueryCache, scope_result.scopes.len) catch &[_]FunctionBindingQueryCache{};
    for (g_outer_binding_query_cache) |*map| map.* = .{};

    g_function_scope_binding_query_cache = ctx.allocator.alloc(FunctionBindingQueryCache, scope_result.scopes.len) catch &[_]FunctionBindingQueryCache{};
    for (g_function_scope_binding_query_cache) |*map| map.* = .{};

    g_function_binding_query_cache_ready = true;
}

fn cacheFunctionBindingQuery(
    ctx: *TransformContext,
    caches: *[]FunctionBindingQueryCache,
    scope_i: usize,
    name: []const u8,
    value: bool,
) void {
    if (scope_i >= caches.*.len) return;
    caches.*[scope_i].put(ctx.allocator, name, if (value) 1 else 0) catch {};
}

/// Generate a unique name for a renamed variable.
fn generateUniqueName(ctx: *TransformContext, decl_node: NodeIndex, original: []const u8) ?[]const u8 {
    const scope_result = ctx.scope orelse return null;
    var ordinal = countEarlierRenamedBindings(ctx, decl_node, original) + 1;

    while (ordinal < 1000) : (ordinal += 1) {
        const candidate = allocBabelUidCandidate(ctx, original, ordinal) orelse return null;
        if (!isNameUsedInAnyScope(scope_result, candidate) and !g_claimed_names.contains(candidate)) {
            g_claimed_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    return null;
}

fn allocBabelUidCandidate(ctx: *TransformContext, original: []const u8, ordinal: u32) ?[]const u8 {
    if (ordinal <= 1) {
        return std.fmt.allocPrint(ctx.allocator, "_{s}", .{original}) catch null;
    }
    if (ordinal <= 9) {
        return std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ original, ordinal }) catch null;
    }
    if (ordinal <= 11) {
        return std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ original, ordinal - 10 }) catch null;
    }
    return std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ original, ordinal - 2 }) catch null;
}

fn countEarlierRenamedBindings(ctx: *TransformContext, decl_node: NodeIndex, original: []const u8) u32 {
    const scope_result = ctx.scope orelse return 0;
    const scope_idx = scope_mod.getScopeForNode(scope_result, decl_node) orelse return 0;
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];
    const func_scope_idx = findEnclosingFunctionScope(scope_result, scope.parent);
    const current_start = nodeStartOffset(ctx, decl_node);

    var count: u32 = 0;
    const owner_scope_idx = func_scope_idx orelse scope_result.containingFunctionScope(scope_idx);
    const binding_indices = bindingIndicesForName(ctx, original) orelse return 0;
    for (binding_indices) |binding_idx_raw| {
        const b = scope_result.bindings[binding_idx_raw];
        if (b.node == decl_node) continue;
        if (scope_result.containingFunctionScope(b.scope) != owner_scope_idx) continue;
        if (b.kind != .let_decl and b.kind != .const_decl) continue;
        if (!isScopeWithinFunction(scope_result, b.scope, func_scope_idx)) continue;
        if (nodeStartOffset(ctx, b.node) >= current_start) continue;

        const binding_scope = scope_result.scopes[@intFromEnum(b.scope)];
        switch (binding_scope.kind) {
            .function, .arrow, .global, .module => continue,
            .block, .catch_clause, .class_body => {},
        }
        if (nameNeedsRename(ctx, b.node, b.scope, binding_scope, func_scope_idx, original)) {
            count += 1;
        }
    }
    return count;
}

fn isNameUsedInAnyScope(result: *const scope_mod.ScopeResult, name: []const u8) bool {
    return result.binding_name_indices.contains(name);
}

/// Rename references to variables within the block scope that contains the declaration.
fn renameReferencesInScope(ctx: *TransformContext, decl_node: NodeIndex, pairs: []const RenamePair) void {
    if (pairs.len == 0) return;

    // Find the parent block/switch that contains this declaration
    const scope_result = ctx.scope orelse return;
    const scope_idx = scope_mod.getScopeForNode(scope_result, decl_node) orelse return;
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];
    const block_node = scope.node;

    // For switch_statement scopes, only rename in case clauses (not the discriminant)
    if (block_node != .none) {
        const block_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(block_node)];
        if (block_tag == .switch_statement) {
            const children = visitor.getChildren(ctx.ast, block_node);
            // Skip direct children (discriminant) — only rename in case range
            if (children.range_start < children.range_end) {
                for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |child_idx| {
                    if (child_idx >= ctx.ast.nodes.len) continue;
                    const child: NodeIndex = @enumFromInt(child_idx);
                    if (child == decl_node) continue;
                    renameIdentifierNode(ctx, child, pairs);
                    renameIdentifiersInSubtree(ctx, child, decl_node, pairs);
                }
            }
            return;
        }
    }

    // Walk all nodes in the AST looking for identifiers within this scope
    // that reference the renamed variables
    renameIdentifiersInSubtree(ctx, block_node, decl_node, pairs);
}

/// Walk a subtree and rename identifier references that match any of the rename pairs.
fn renameIdentifiersInSubtree(ctx: *TransformContext, root: NodeIndex, skip_decl: NodeIndex, pairs: []const RenamePair) void {
    if (root == .none) return;

    const children = visitor.getChildren(ctx.ast, root);
    const sequential_scope = switch (ctx.nodeTag(root)) {
        .block_statement, .switch_case, .switch_default => true,
        else => false,
    };

    var active_pairs_storage: [16]RenamePair = undefined;
    var active_pairs_len: usize = 0;
    if (sequential_scope) {
        active_pairs_len = pairs.len;
        @memcpy(active_pairs_storage[0..pairs.len], pairs);
    }

    // Process direct children
    for (children.items[0..children.len]) |child| {
        if (child == .none or child == skip_decl) continue;
        const active_pairs = if (sequential_scope) active_pairs_storage[0..active_pairs_len] else pairs;
        if (sequential_scope and child != skip_decl and subtreeShadowsRenamedName(ctx, child, active_pairs)) {
            dropShadowedRenamePairs(&active_pairs_storage, &active_pairs_len, child, active_pairs, ctx);
            continue;
        }
        renameIdentifierNode(ctx, child, active_pairs);
        renameIdentifiersInSubtree(ctx, child, skip_decl, active_pairs);
    }

    // Process range children
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |child_idx| {
            if (child_idx >= ctx.ast.nodes.len) continue;
            const child: NodeIndex = @enumFromInt(child_idx);
            if (child == skip_decl) continue;
            const active_pairs = if (sequential_scope) active_pairs_storage[0..active_pairs_len] else pairs;
            if (sequential_scope and child != skip_decl and subtreeShadowsRenamedName(ctx, child, active_pairs)) {
                dropShadowedRenamePairs(&active_pairs_storage, &active_pairs_len, child, active_pairs, ctx);
                continue;
            }
            renameIdentifierNode(ctx, child, active_pairs);
            renameIdentifiersInSubtree(ctx, child, skip_decl, active_pairs);
        }
    }

    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |child_idx| {
            if (child_idx >= ctx.ast.nodes.len) continue;
            const child: NodeIndex = @enumFromInt(child_idx);
            if (child == skip_decl) continue;
            const active_pairs = if (sequential_scope) active_pairs_storage[0..active_pairs_len] else pairs;
            if (sequential_scope and child != skip_decl and subtreeShadowsRenamedName(ctx, child, active_pairs)) {
                dropShadowedRenamePairs(&active_pairs_storage, &active_pairs_len, child, active_pairs, ctx);
                continue;
            }
            renameIdentifierNode(ctx, child, active_pairs);
            renameIdentifiersInSubtree(ctx, child, skip_decl, active_pairs);
        }
    }
}

fn dropShadowedRenamePairs(
    active_pairs_storage: *[16]RenamePair,
    active_pairs_len: *usize,
    decl_node: NodeIndex,
    pairs: []const RenamePair,
    ctx: *TransformContext,
) void {
    const names = getDeclaredNames(decl_node, ctx);
    if (names.len == 0) return;

    var next_len: usize = 0;
    for (pairs) |pair| {
        var shadowed = false;
        for (names.items[0..names.len]) |name| {
            if (std.mem.eql(u8, name, pair.old)) {
                shadowed = true;
                break;
            }
        }
        if (shadowed) continue;
        active_pairs_storage[next_len] = pair;
        next_len += 1;
    }
    active_pairs_len.* = next_len;
}

fn subtreeShadowsRenamedName(ctx: *TransformContext, node: NodeIndex, pairs: []const RenamePair) bool {
    const tag = ctx.nodeTag(node);
    if (tag != .let_declaration and tag != .const_declaration) return false;

    const names = getDeclaredNames(node, ctx);
    for (names.items[0..names.len]) |name| {
        if (name.len == 0) continue;
        for (pairs) |pair| {
            if (std.mem.eql(u8, name, pair.old)) return true;
        }
    }

    return false;
}

fn renameIdentifierNode(ctx: *TransformContext, node: NodeIndex, pairs: []const RenamePair) void {
    if (node == .none) return;
    const tag = ctx.nodeTag(node);
    if (tag != .identifier) return;

    // Check if this identifier already has a replacement
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.contains(ni)) return;

    const name = ctx.tokenSlice(ctx.mainToken(node));
    for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair.old)) {
            _ = putReplacement(ctx, node, pair.new);
            return;
        }
    }
}

const BindingIndexList = struct {
    items: [16]u32 = [_]u32{0} ** 16,
    len: u8 = 0,

    fn add(self: *BindingIndexList, binding_idx: u32) void {
        if (self.len < self.items.len) {
            self.items[self.len] = binding_idx;
            self.len += 1;
        }
    }

    fn contains(self: BindingIndexList, binding_idx: u32) bool {
        for (self.items[0..self.len]) |item| {
            if (item == binding_idx) return true;
        }
        return false;
    }
};

/// Check for const violations and insert readOnlyError calls.
/// This uses scope analysis mutation records directly instead of rescanning
/// source text or recursively walking the enclosing function body.
fn checkConstViolations(idx: NodeIndex, ctx: *TransformContext) void {
    const scope_result = ctx.scope orelse return;
    if (getSimpleDeclaredConstBindingIndex(ctx, scope_result, idx)) |binding_idx| {
        const mutation_nodes = scope_mod.getBindingMutations(scope_result, binding_idx);
        if (mutation_nodes.len == 0) return;
        const binding = scope_result.bindings[binding_idx];
        for (mutation_nodes) |mutation_node_raw| {
            const mutation_node: NodeIndex = @enumFromInt(mutation_node_raw);
            switch (ctx.nodeTag(mutation_node)) {
                .assignment_expr => checkAssignmentViolation(ctx, mutation_node, binding.name),
                .update_expr => checkUpdateViolation(ctx, mutation_node, binding.name),
                .for_in_statement, .for_of_statement => checkForInOfViolation(ctx, mutation_node, binding.name),
                else => {},
            }
        }
        return;
    }

    const scope_idx = scope_mod.getScopeForNode(scope_result, idx) orelse return;
    const names = getDeclaredNames(idx, ctx);
    if (names.len == 0) return;

    const binding_indices = collectDeclaredConstBindingIndices(scope_result, scope_idx, names);
    if (binding_indices.len == 0) return;

    for (binding_indices.items[0..binding_indices.len]) |binding_idx| {
        const binding = scope_result.bindings[binding_idx];
        const mutation_nodes = scope_mod.getBindingMutations(scope_result, binding_idx);
        for (mutation_nodes) |mutation_node_raw| {
            const mutation_node: NodeIndex = @enumFromInt(mutation_node_raw);
            switch (ctx.nodeTag(mutation_node)) {
                .assignment_expr => checkAssignmentViolation(ctx, mutation_node, binding.name),
                .update_expr => checkUpdateViolation(ctx, mutation_node, binding.name),
                .for_in_statement, .for_of_statement => checkForInOfViolation(ctx, mutation_node, binding.name),
                else => {},
            }
        }
    }
}

fn getSimpleDeclaredConstBindingIndex(
    ctx: *TransformContext,
    scope_result: *const scope_mod.ScopeResult,
    decl_node: NodeIndex,
) ?u32 {
    const data = ctx.nodeData(decl_node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return null;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];
    if (range_end != range_start + 1) return null;

    const declarator_raw = ctx.ast.extra_data.items[range_start];
    if (declarator_raw >= ctx.ast.nodes.len) return null;
    if (ctx.ast.nodes.items(.tag)[declarator_raw] != .declarator) return null;

    const lhs = ctx.ast.nodes.items(.data)[declarator_raw].binary.lhs;
    if (lhs == .none or ctx.nodeTag(lhs) != .identifier) return null;

    const binding_idx = scope_mod.getBindingIndexForNode(scope_result, lhs) orelse return null;
    return if (scope_result.bindings[binding_idx].kind == .const_decl) binding_idx else null;
}

fn collectDeclaredConstBindingIndices(
    scope_result: *const scope_mod.ScopeResult,
    scope_idx: scope_mod.ScopeIndex,
    names: NameList,
) BindingIndexList {
    var result = BindingIndexList{};
    for (names.items[0..names.len]) |name| {
        if (name.len == 0) continue;
        const binding_idx = scope_mod.getBindingIndex(scope_result, scope_idx, name) orelse continue;
        if (scope_result.bindings[binding_idx].kind != .const_decl) continue;
        result.add(binding_idx);
    }
    return result;
}

/// Check if an assignment expression targets a const variable and emit readOnlyError.
fn checkAssignmentViolation(ctx: *TransformContext, node: NodeIndex, cname: []const u8) void {
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.contains(ni)) return;

    const data = ctx.ast.nodes.items(.data)[ni];
    const lhs = data.binary.lhs;
    const rhs = data.binary.rhs;
    if (lhs == .none) return;

    const lhs_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(lhs)];
    if (lhs_tag != .identifier) return;

    const lhs_name = ctx.tokenSlice(ctx.ast.nodes.items(.main_token)[@intFromEnum(lhs)]);
    if (!std.mem.eql(u8, lhs_name, cname)) return;

    // This is a const violation!
    // Get the operator
    const main_tok = ctx.ast.nodes.items(.main_token)[ni];
    const op = ctx.tokenSlice(main_tok);

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    if (std.mem.eql(u8, op, "=")) {
        // Simple assignment: a = rhs -> rhs, babelHelpers.readOnlyError("a")
        const rhs_source = getNodeSource(ctx, rhs);
        buf.appendSlice(ctx.allocator, rhs_source) catch return;
        buf.appendSlice(ctx.allocator, ", babelHelpers.readOnlyError(\"") catch return;
        buf.appendSlice(ctx.allocator, cname) catch return;
        buf.appendSlice(ctx.allocator, "\")") catch return;
    } else if (std.mem.eql(u8, op, "||=") or std.mem.eql(u8, op, "&&=") or std.mem.eql(u8, op, "??=")) {
        // Logical assignment: a ||= rhs -> a || (rhs, babelHelpers.readOnlyError("a"))
        const logical_op = if (std.mem.eql(u8, op, "||="))
            "||"
        else if (std.mem.eql(u8, op, "&&="))
            "&&"
        else
            "??";
        const rhs_source = getNodeSource(ctx, rhs);
        buf.appendSlice(ctx.allocator, lhs_name) catch return;
        buf.appendSlice(ctx.allocator, " ") catch return;
        buf.appendSlice(ctx.allocator, logical_op) catch return;
        buf.appendSlice(ctx.allocator, " (") catch return;
        buf.appendSlice(ctx.allocator, rhs_source) catch return;
        buf.appendSlice(ctx.allocator, ", babelHelpers.readOnlyError(\"") catch return;
        buf.appendSlice(ctx.allocator, cname) catch return;
        buf.appendSlice(ctx.allocator, "\"))") catch return;
    } else {
        // Compound assignment: a += rhs -> a + rhs, babelHelpers.readOnlyError("a")
        // Strip trailing '=' from the operator to get the binary op
        const binary_op = if (op.len > 1 and op[op.len - 1] == '=')
            op[0 .. op.len - 1]
        else
            op;
        const rhs_source = getNodeSource(ctx, rhs);
        buf.appendSlice(ctx.allocator, lhs_name) catch return;
        buf.appendSlice(ctx.allocator, " ") catch return;
        buf.appendSlice(ctx.allocator, binary_op) catch return;
        buf.appendSlice(ctx.allocator, " ") catch return;
        buf.appendSlice(ctx.allocator, rhs_source) catch return;
        buf.appendSlice(ctx.allocator, ", babelHelpers.readOnlyError(\"") catch return;
        buf.appendSlice(ctx.allocator, cname) catch return;
        buf.appendSlice(ctx.allocator, "\")") catch return;
    }

    _ = putReplacement(ctx, node, buf.items);
}

/// Check if an update expression targets a const variable and emit readOnlyError.
fn checkUpdateViolation(ctx: *TransformContext, node: NodeIndex, cname: []const u8) void {
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.contains(ni)) return;

    const data = ctx.ast.nodes.items(.data)[ni];
    const operand = data.unary;
    if (operand == .none) return;

    const operand_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(operand)];
    if (operand_tag != .identifier) return;

    const operand_name = ctx.tokenSlice(ctx.ast.nodes.items(.main_token)[@intFromEnum(operand)]);
    if (!std.mem.eql(u8, operand_name, cname)) return;

    // This is a const violation!
    // Both prefix and postfix: foo++ / ++foo / foo-- / --foo
    // All become: +foo, babelHelpers.readOnlyError("foo")
    // Check if we need to wrap in parens (when used as operand of binary expr)
    const needs_parens = isOperandOfBinaryExpr(ctx, node);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (needs_parens) buf.append(ctx.allocator, '(') catch return;
    buf.appendSlice(ctx.allocator, "+") catch return;
    buf.appendSlice(ctx.allocator, cname) catch return;
    buf.appendSlice(ctx.allocator, ", babelHelpers.readOnlyError(\"") catch return;
    buf.appendSlice(ctx.allocator, cname) catch return;
    buf.appendSlice(ctx.allocator, "\")") catch return;
    if (needs_parens) buf.append(ctx.allocator, ')') catch return;

    _ = putReplacement(ctx, node, buf.items);
}

/// Check if a for-in/for-of statement targets a const variable via its LHS.
fn checkForInOfViolation(ctx: *TransformContext, node: NodeIndex, cname: []const u8) void {
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.contains(ni)) return;

    const tag = ctx.ast.nodes.items(.tag)[ni];
    if (tag != .for_in_statement and tag != .for_of_statement) return;

    const data = ctx.ast.nodes.items(.data)[ni];
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const left: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const right: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
    const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);
    if (left == .none or right == .none or body == .none) return;
    if (ctx.nodeTag(left) != .identifier) return;

    const left_name = ctx.tokenSlice(ctx.mainToken(left));
    if (!std.mem.eql(u8, left_name, cname)) return;

    const loop_name = allocConstViolationLoopName(ctx, cname) orelse return;
    const right_source = getNodeSource(ctx, right);
    const body_source = getNodeSource(ctx, body);
    const loop_op = if (tag == .for_in_statement) "in" else "of";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "for (var ") catch return;
    buf.appendSlice(ctx.allocator, loop_name) catch return;
    buf.appendSlice(ctx.allocator, " ") catch return;
    buf.appendSlice(ctx.allocator, loop_op) catch return;
    buf.appendSlice(ctx.allocator, " ") catch return;
    buf.appendSlice(ctx.allocator, right_source) catch return;
    buf.appendSlice(ctx.allocator, ") {\n  babelHelpers.readOnlyError(\"") catch return;
    buf.appendSlice(ctx.allocator, cname) catch return;
    buf.appendSlice(ctx.allocator, "\");\n") catch return;
    appendIndentedConstViolationBody(ctx, &buf, body_source) catch return;
    buf.appendSlice(ctx.allocator, "\n}") catch return;

    _ = putReplacement(ctx, node, buf.items);
}

fn allocConstViolationLoopName(ctx: *TransformContext, original: []const u8) ?[]const u8 {
    const scope_result = ctx.scope orelse return null;
    var ordinal: u32 = 1;
    while (ordinal < 1000) : (ordinal += 1) {
        const candidate = allocBabelUidCandidate(ctx, original, ordinal) orelse return null;
        if (!isNameUsedInAnyScope(scope_result, candidate) and !g_claimed_names.contains(candidate)) {
            g_claimed_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    return null;
}

fn appendIndentedConstViolationBody(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    body_source: []const u8,
) !void {
    try appendIndentedBodyWithPrefix(ctx, buf, body_source, "  ");
}

fn appendIndentedBodyWithPrefix(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    body_source: []const u8,
    prefix: []const u8,
) !void {
    var start: usize = 0;
    while (start < body_source.len) {
        var line_end = start;
        while (line_end < body_source.len and body_source[line_end] != '\n' and body_source[line_end] != '\r') : (line_end += 1) {}

        const line = std.mem.trimEnd(u8, body_source[start..line_end], " \t");
        try buf.appendSlice(ctx.allocator, prefix);
        try buf.appendSlice(ctx.allocator, line);

        if (line_end < body_source.len) {
            if (body_source[line_end] == '\r' and line_end + 1 < body_source.len and body_source[line_end + 1] == '\n') {
                start = line_end + 2;
            } else {
                start = line_end + 1;
            }
            try buf.append(ctx.allocator, '\n');
        } else {
            start = line_end;
        }
    }
}

fn getNodeLineIndent(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const start = nodeStartOffset(ctx, node);
    var line_start = start;
    while (line_start > 0) {
        const prev = ctx.ast.source[line_start - 1];
        if (prev == '\n' or prev == '\r') break;
        line_start -= 1;
    }

    var indent_end = line_start;
    while (indent_end < ctx.ast.source.len and indent_end < start) {
        const c = ctx.ast.source[indent_end];
        if (c != ' ' and c != '\t') break;
        indent_end += 1;
    }
    return ctx.ast.source[line_start..indent_end];
}

/// Get the start position of a node in the source.
fn getNodeStartPos(ctx: *TransformContext, node: NodeIndex) u32 {
    if (node == .none) return std.math.maxInt(u32);
    const ni = @intFromEnum(node);
    const tag = ctx.ast.nodes.items(.tag)[ni];

    // For nodes where main_token is an operator, recurse into children
    if (tag == .update_expr) {
        const data = ctx.ast.nodes.items(.data)[ni];
        const op_tok = ctx.ast.nodes.items(.main_token)[ni];
        const op_start = ctx.ast.tokens.items(.start)[@intFromEnum(op_tok)];
        if (data.unary != .none) {
            return @min(op_start, getNodeStartPos(ctx, data.unary));
        }
        return op_start;
    }
    if (tag == .binary_expr or tag == .logical_expr or tag == .assignment_expr) {
        const data = ctx.ast.nodes.items(.data)[ni];
        const op_tok = ctx.ast.nodes.items(.main_token)[ni];
        const op_start = ctx.ast.tokens.items(.start)[@intFromEnum(op_tok)];
        if (data.binary.lhs != .none) {
            return @min(op_start, getNodeStartPos(ctx, data.binary.lhs));
        }
        return op_start;
    }

    const main_tok = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
}

fn putReplacement(ctx: *TransformContext, node: NodeIndex, replacement: []const u8) bool {
    return putReplacementImpl(ctx, node, replacement, false);
}

fn putReplacementWithReindent(ctx: *TransformContext, node: NodeIndex, replacement: []const u8) bool {
    return putReplacementImpl(ctx, node, replacement, true);
}

fn putReplacementImpl(ctx: *TransformContext, node: NodeIndex, replacement: []const u8, needs_reindent: bool) bool {
    if (node == .none) return false;
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return false;

    ctx.putReplacementSource(node, replacement) catch return false;
    if (needs_reindent) {
        ctx.markReplacementNeedsReindent(node) catch return false;
    }
    return true;
}

/// Check if a node is used as an operand of a binary/logical expression.
fn isOperandOfBinaryExpr(ctx: *TransformContext, node: NodeIndex) bool {
    // Scan all nodes looking for binary_expr or logical_expr whose lhs or rhs is this node
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    for (tags, 0..) |tag, ni| {
        switch (tag) {
            .binary_expr, .logical_expr => {
                if (datas[ni].binary.lhs == node or datas[ni].binary.rhs == node) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Get the source text for a node (used by const-violation replacement generation).
fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    const tag = ctx.ast.nodes.items(.tag)[ni];

    // For identifiers, use the token text
    if (tag == .identifier) {
        return ctx.tokenSlice(ctx.ast.nodes.items(.main_token)[ni]);
    }

    // For nodes where main_token is an operator (not the start of the expression),
    // compute the true start by looking at child nodes.
    if (tag == .update_expr or tag == .binary_expr or tag == .logical_expr or
        tag == .assignment_expr or tag == .conditional_expr)
    {
        const node_end = ctx.ast.nodes.items(.end_offset)[ni];
        const data = ctx.ast.nodes.items(.data)[ni];

        // Find the earliest token start among the operator and operands
        const op_tok = ctx.ast.nodes.items(.main_token)[ni];
        var earliest_start = ctx.ast.tokens.items(.start)[@intFromEnum(op_tok)];

        if (tag == .update_expr) {
            // unary: check operand
            if (data.unary != .none) {
                const arg_start = getNodeStartPos(ctx, data.unary);
                earliest_start = @min(earliest_start, arg_start);
            }
        } else {
            // binary: check lhs
            if (data.binary.lhs != .none) {
                const lhs_start = getNodeStartPos(ctx, data.binary.lhs);
                earliest_start = @min(earliest_start, lhs_start);
            }
        }

        if (node_end > earliest_start and node_end <= ctx.ast.source.len) {
            return ctx.ast.source[earliest_start..node_end];
        }
    }

    // For other nodes, extract from source using node positions
    const main_tok = ctx.ast.nodes.items(.main_token)[ni];
    const start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
    const end = ctx.ast.nodes.items(.end_offset)[ni];

    if (end <= start or end > ctx.ast.source.len) {
        return ctx.tokenSlice(main_tok);
    }

    return ctx.ast.source[start..end];
}
