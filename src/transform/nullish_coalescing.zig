const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");
const scope_mod = @import("../scope.zig");

/// Configuration for the nullish-coalescing-operator transform.
pub const Config = struct {
    /// When true, use `!= null` instead of `!== null && !== void 0`.
    /// This is the "loose" plugin option or the "noDocumentAll" assumption.
    no_document_all: bool = false,
    /// When true, member access is considered pure (no temp var needed for foo.bar).
    pure_getters: bool = false,
};

var g_config: Config = .{};

/// Set of temp names already allocated (to avoid duplicates within a file).
var g_allocated_names: std.StringHashMapUnmanaged(void) = .empty;

/// Temp names grouped by their enclosing body node (for block_prefix_source).
/// Key = body node index (0 for program), value = list of temp names.
pub var g_body_temps: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)) = .empty;

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.logical_expr));
    filter.set(@intFromEnum(Node.Tag.assignment_expr));
    return .{
        .name = "nullish_coalescing",
        .node_filter = filter,
        .exit = exitNode,
        .priority = 30, // Run after logical-assignment (25) so ||=/&&= are already expanded
    };
}

pub fn resetState() void {
    g_allocated_names = .{};
    g_body_temps = .{};
}

/// Flush all accumulated temp var declarations into block_prefix_source entries.
/// Called by the test runner after pipeline.run() but before codegen.
pub fn flushTempDeclarations(ctx: *TransformContext) void {
    var iter = g_body_temps.iterator();
    while (iter.next()) |entry| {
        const body_idx = entry.key_ptr.*;
        const names = entry.value_ptr.items;
        if (names.len == 0) continue;

        var decl_buf: std.ArrayListUnmanaged(u8) = .empty;

        // Prepend to any existing block prefix
        if (ctx.ast.block_prefix_source.get(body_idx)) |existing| {
            decl_buf.appendSlice(ctx.allocator, existing) catch continue;
            // Existing prefix already has a trailing newline typically
        }

        decl_buf.appendSlice(ctx.allocator, "var ") catch continue;
        for (names, 0..) |name, j| {
            if (j > 0) decl_buf.appendSlice(ctx.allocator, ", ") catch continue;
            decl_buf.appendSlice(ctx.allocator, name) catch continue;
        }
        decl_buf.appendSlice(ctx.allocator, ";") catch continue;

        ctx.ast.block_prefix_source.put(ctx.allocator, body_idx, decl_buf.items) catch continue;
    }
}

/// Get all temp var names as a flat list (for test runner prepend fallback).
pub fn getAllTempNames() []const []const u8 {
    // Flatten all body temps into a single list
    var total: usize = 0;
    var iter = g_body_temps.iterator();
    while (iter.next()) |entry| {
        total += entry.value_ptr.items.len;
    }
    return &.{}; // Not used with block_prefix_source approach
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (ctx.ast.replacement_source.contains(@intFromEnum(idx))) return .continue_traversal;
    const tag = ctx.nodeTag(idx);
    if (tag == .logical_expr) {
        handleNullishCoalescing(idx, ctx);
    } else if (tag == .assignment_expr) {
        handleNullishAssignment(idx, ctx);
    }
    return .continue_traversal;
}

// ── Main transform ──────────────────────────────────────────────────

fn handleNullishCoalescing(idx: NodeIndex, ctx: *TransformContext) void {
    // Check that the operator is ??
    const main_tok = ctx.mainToken(idx);
    const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(main_tok)];
    if (tok_tag != .question_question) return;

    const data = ctx.nodeData(idx);
    const lhs = data.binary.lhs;
    const rhs = data.binary.rhs;

    const lhs_src = normalizeNullishLhsSource(ctx, lhs, getNodeSource(ctx, lhs));
    const rhs_src = normalizeNullishLhsSource(ctx, rhs, getNodeSource(ctx, rhs));

    if (lhs_src.len == 0 or rhs_src.len == 0) return;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const body_idx = findEnclosingBody(ctx, idx);
    const temp_count_before = getBodyTempCount(body_idx);
    const in_param_default = isInFunctionParameterDefault(ctx, idx) or isBeforeEnclosingBody(ctx, idx, body_idx);

    const allow_direct_default_param = g_config.pure_getters and isSimpleDefaultParameterNullish(ctx, idx, lhs);

    if (!allow_direct_default_param and needsTempVar(ctx, lhs)) {
        // Find enclosing body for temp var placement
        const temp_name = allocTempName(ctx, lhs, body_idx);
        if (temp_name.len == 0) return;

        if (g_config.no_document_all) {
            buf.appendSlice(ctx.allocator, "(") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, lhs_src) catch return;
            buf.appendSlice(ctx.allocator, ") != null ? ") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            buf.appendSlice(ctx.allocator, " : ") catch return;
            buf.appendSlice(ctx.allocator, rhs_src) catch return;
        } else {
            buf.appendSlice(ctx.allocator, "(") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, lhs_src) catch return;
            buf.appendSlice(ctx.allocator, ") !== null && ") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            buf.appendSlice(ctx.allocator, " !== void 0 ? ") catch return;
            buf.appendSlice(ctx.allocator, temp_name) catch return;
            buf.appendSlice(ctx.allocator, " : ") catch return;
            buf.appendSlice(ctx.allocator, rhs_src) catch return;
        }
    } else {
        if (g_config.no_document_all) {
            buf.appendSlice(ctx.allocator, lhs_src) catch return;
            buf.appendSlice(ctx.allocator, " != null ? ") catch return;
            buf.appendSlice(ctx.allocator, lhs_src) catch return;
            buf.appendSlice(ctx.allocator, " : ") catch return;
            buf.appendSlice(ctx.allocator, rhs_src) catch return;
        } else {
            buf.appendSlice(ctx.allocator, lhs_src) catch return;
            buf.appendSlice(ctx.allocator, " !== null && ") catch return;
            buf.appendSlice(ctx.allocator, lhs_src) catch return;
            buf.appendSlice(ctx.allocator, " !== void 0 ? ") catch return;
            buf.appendSlice(ctx.allocator, lhs_src) catch return;
            buf.appendSlice(ctx.allocator, " : ") catch return;
            buf.appendSlice(ctx.allocator, rhs_src) catch return;
        }
    }

    var normalized = canonicalizeRefTempOrdering(ctx, buf.items);
    if (in_param_default) {
        normalized = maybeWrapParameterDefaultIife(ctx, body_idx, temp_count_before, normalized);
    }
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), normalized) catch return;
}

fn getBodyTempCount(body_idx: u32) usize {
    if (g_body_temps.get(body_idx)) |temps| return temps.items.len;
    return 0;
}

fn maybeWrapParameterDefaultIife(
    ctx: *TransformContext,
    body_idx: u32,
    temp_count_before: usize,
    expr: []const u8,
) []const u8 {
    const temps = g_body_temps.getPtr(body_idx) orelse return expr;
    if (temps.items.len <= temp_count_before) return expr;

    const new_temps = temps.items[temp_count_before..];
    temps.items.len = temp_count_before;

    var params: []const u8 = "";
    if (new_temps.len == 1) {
        params = new_temps[0];
    } else {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(ctx.allocator, "(") catch return expr;
        for (new_temps, 0..) |name, i| {
            if (i > 0) buf.appendSlice(ctx.allocator, ", ") catch return expr;
            buf.appendSlice(ctx.allocator, name) catch return expr;
        }
        buf.appendSlice(ctx.allocator, ")") catch return expr;
        params = buf.items;
    }

    return std.fmt.allocPrint(ctx.allocator, "({s} => {s})()", .{ params, expr }) catch expr;
}

fn isInFunctionParameterDefault(ctx: *TransformContext, idx: NodeIndex) bool {
    var current = idx;
    var saw_default = false;

    while (true) {
        const parent = findParentOf(ctx, current);
        if (parent == .none) return false;

        switch (ctx.nodeTag(parent)) {
            .assignment_pattern => {
                if (ctx.nodeData(parent).binary.rhs != current) return false;
                saw_default = true;
                current = parent;
            },
            .property,
            .computed_property,
            .shorthand_property,
            .object_pattern,
            .array_pattern,
            .rest_element,
            => current = parent,
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .arrow_function_expr,
            .class_method,
            .class_private_method,
            .computed_method,
            .method_definition,
            => return saw_default,
            else => return false,
        }
    }
}

fn isBeforeEnclosingBody(ctx: *TransformContext, idx: NodeIndex, body_idx: u32) bool {
    if (body_idx == 0) return false;
    const body: NodeIndex = @enumFromInt(body_idx);
    const body_tag = ctx.nodeTag(body);
    const body_start = switch (body_tag) {
        .block_statement => getNodeStart(ctx, body),
        .arrow_function_expr => blk: {
            const data = ctx.nodeData(body);
            const eidx = @intFromEnum(data.extra);
            if (eidx + 2 >= ctx.ast.extra_data.items.len) return false;
            const arrow_body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx + 2]);
            break :blk getNodeStart(ctx, arrow_body);
        },
        else => return false,
    };
    return ctx.ast.nodes.items(.end_offset)[@intFromEnum(idx)] <= body_start;
}

/// Handle ??= (nullish assignment) — produces the full nullish check with assignment.
/// a ??= b → a !== null && a !== void 0 ? a : a = b
/// o.a ??= 1 → (_o$a = (_o = o).a) !== null && _o$a !== void 0 ? _o$a : _o.a = 1
fn handleNullishAssignment(idx: NodeIndex, ctx: *TransformContext) void {
    const main_tok = ctx.mainToken(idx);
    const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(main_tok)];
    if (tok_tag != .question_question_equal) return;

    const data = ctx.nodeData(idx);
    const lhs = data.binary.lhs;
    const rhs = data.binary.rhs;
    const rhs_src = getNodeSource(ctx, rhs);
    if (rhs_src.len == 0) return;

    const body_idx = findEnclosingBody(ctx, idx);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const lhs_tag = ctx.nodeTag(lhs);

    switch (lhs_tag) {
        .identifier => {
            // a ??= b → a !== null && a !== void 0 ? a : a = b
            const lhs_src = getNodeSource(ctx, lhs);
            if (lhs_src.len == 0) return;
            if (g_config.no_document_all) {
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " != null ? ") catch return;
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " : ") catch return;
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
            } else {
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " !== null && ") catch return;
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " !== void 0 ? ") catch return;
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " : ") catch return;
                buf.appendSlice(ctx.allocator, lhs_src) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
            }
        },
        .member_expr => {
            const mem_data = ctx.nodeData(lhs);
            const obj_node = mem_data.binary.lhs;
            const prop_tok_raw = @intFromEnum(mem_data.binary.rhs);
            const prop_name = ctx.ast.tokenSlice(@enumFromInt(prop_tok_raw));
            const obj_src = getNodeSource(ctx, obj_node);
            const obj_is_global = isWellKnownGlobalNode(ctx, obj_node);

            if (obj_is_global) {
                // Well-known global: no object temp needed
                const obj_raw_prefix = deriveTempPrefix(ctx, obj_node);
                const result_prefix = std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_raw_prefix, prop_name }) catch return;
                const result_temp = allocUniqueName(ctx, result_prefix, body_idx);
                if (result_temp.len == 0) return;

                emitNullishCheck(&buf, ctx, result_temp, std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ obj_src, prop_name }) catch return, g_config.no_document_all);
                buf.appendSlice(ctx.allocator, " : ") catch return;
                buf.appendSlice(ctx.allocator, obj_src) catch return;
                buf.appendSlice(ctx.allocator, ".") catch return;
                buf.appendSlice(ctx.allocator, prop_name) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
            } else {
                const obj_temp = allocTempName(ctx, obj_node, body_idx);
                if (obj_temp.len == 0) return;

                const obj_base = if (obj_temp.len > 1 and obj_temp[0] == '_') obj_temp[1..] else obj_temp;
                const result_prefix = std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_base, prop_name }) catch return;
                const result_temp = allocUniqueName(ctx, result_prefix, body_idx);
                if (result_temp.len == 0) return;

                emitNullishCheck(&buf, ctx, result_temp, std.fmt.allocPrint(ctx.allocator, "({s} = {s}).{s}", .{ obj_temp, obj_src, prop_name }) catch return, g_config.no_document_all);
                buf.appendSlice(ctx.allocator, " : ") catch return;
                buf.appendSlice(ctx.allocator, obj_temp) catch return;
                buf.appendSlice(ctx.allocator, ".") catch return;
                buf.appendSlice(ctx.allocator, prop_name) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
            }
        },
        .computed_member_expr => {
            const mem_data = ctx.nodeData(lhs);
            const obj_node = mem_data.binary.lhs;
            const key_node = mem_data.binary.rhs;
            const obj_src = getNodeSource(ctx, obj_node);
            const key_src = getNodeSource(ctx, key_node);
            const obj_is_global = isWellKnownGlobalNode(ctx, obj_node);

            if (obj_is_global) {
                const key_prefix = deriveKeyPrefix(ctx, key_node);
                const key_temp = allocUniqueName(ctx, key_prefix, body_idx);
                if (key_temp.len == 0) return;
                const obj_raw_prefix = deriveTempPrefix(ctx, obj_node);
                const result_prefix = std.fmt.allocPrint(ctx.allocator, "{s}$_{s}", .{ obj_raw_prefix, key_prefix }) catch return;
                const result_temp = allocUniqueName(ctx, result_prefix, body_idx);
                if (result_temp.len == 0) return;

                emitNullishCheck(&buf, ctx, result_temp, std.fmt.allocPrint(ctx.allocator, "{s}[{s} = {s}]", .{ obj_src, key_temp, key_src }) catch return, g_config.no_document_all);
                buf.appendSlice(ctx.allocator, " : ") catch return;
                buf.appendSlice(ctx.allocator, obj_src) catch return;
                buf.appendSlice(ctx.allocator, "[") catch return;
                buf.appendSlice(ctx.allocator, key_temp) catch return;
                buf.appendSlice(ctx.allocator, "] = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
            } else {
                // Allocate obj temp first, then key, then result (matches Babel ordering)
                const obj_temp = allocTempName(ctx, obj_node, body_idx);
                if (obj_temp.len == 0) return;
                const key_prefix = deriveKeyPrefix(ctx, key_node);
                const key_temp = allocUniqueName(ctx, key_prefix, body_idx);
                if (key_temp.len == 0) return;

                const obj_base = if (obj_temp.len > 1 and obj_temp[0] == '_') obj_temp[1..] else obj_temp;
                const result_prefix = std.fmt.allocPrint(ctx.allocator, "{s}$_{s}", .{ obj_base, key_prefix }) catch return;
                const result_temp = allocUniqueName(ctx, result_prefix, body_idx);
                if (result_temp.len == 0) return;

                emitNullishCheck(&buf, ctx, result_temp, std.fmt.allocPrint(ctx.allocator, "({s} = {s})[{s} = {s}]", .{ obj_temp, obj_src, key_temp, key_src }) catch return, g_config.no_document_all);
                buf.appendSlice(ctx.allocator, " : ") catch return;
                buf.appendSlice(ctx.allocator, obj_temp) catch return;
                buf.appendSlice(ctx.allocator, "[") catch return;
                buf.appendSlice(ctx.allocator, key_temp) catch return;
                buf.appendSlice(ctx.allocator, "] = ") catch return;
                buf.appendSlice(ctx.allocator, rhs_src) catch return;
            }
        },
        else => return,
    }

    const normalized = canonicalizeRefTempOrdering(ctx, buf.items);
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), normalized) catch return;
}

fn canonicalizeRefTempOrdering(ctx: *TransformContext, src: []const u8) []const u8 {
    var mapping: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer mapping.deinit(ctx.allocator);

    var next_index: u32 = 1;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '_' and i + 4 <= src.len and std.mem.startsWith(u8, src[i..], "_ref")) {
            const start = i;
            i += 4;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
            const end = i;
            const prev_ok = start == 0 or !isIdentChar(src[start - 1]);
            const next_ok = end >= src.len or !isIdentChar(src[end]);
            if (!prev_ok or !next_ok) continue;

            const original = src[start..end];
            if (!mapping.contains(original)) {
                const canonical = if (next_index == 1)
                    "_ref"
                else
                    std.fmt.allocPrint(ctx.allocator, "_ref{d}", .{next_index}) catch return src;
                mapping.put(ctx.allocator, original, canonical) catch return src;
                next_index += 1;
            }
            continue;
        }
        i += 1;
    }

    if (mapping.count() == 0) return src;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    i = 0;
    while (i < src.len) {
        if (src[i] == '_' and i + 4 <= src.len and std.mem.startsWith(u8, src[i..], "_ref")) {
            const start = i;
            i += 4;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
            const end = i;
            const prev_ok = start == 0 or !isIdentChar(src[start - 1]);
            const next_ok = end >= src.len or !isIdentChar(src[end]);
            if (prev_ok and next_ok) {
                const original = src[start..end];
                if (mapping.get(original)) |canonical| {
                    buf.appendSlice(ctx.allocator, canonical) catch return src;
                    continue;
                }
            }
            buf.appendSlice(ctx.allocator, src[start..end]) catch return src;
            continue;
        }
        buf.append(ctx.allocator, src[i]) catch return src;
        i += 1;
    }

    return buf.items;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// Helper to emit the nullish check pattern: (temp = expr) !== null && temp !== void 0 ? temp
fn emitNullishCheck(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, temp: []const u8, expr: []const u8, no_doc_all: bool) void {
    if (no_doc_all) {
        buf.appendSlice(ctx.allocator, "(") catch return;
        buf.appendSlice(ctx.allocator, temp) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, expr) catch return;
        buf.appendSlice(ctx.allocator, ") != null ? ") catch return;
        buf.appendSlice(ctx.allocator, temp) catch return;
    } else {
        buf.appendSlice(ctx.allocator, "(") catch return;
        buf.appendSlice(ctx.allocator, temp) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, expr) catch return;
        buf.appendSlice(ctx.allocator, ") !== null && ") catch return;
        buf.appendSlice(ctx.allocator, temp) catch return;
        buf.appendSlice(ctx.allocator, " !== void 0 ? ") catch return;
        buf.appendSlice(ctx.allocator, temp) catch return;
    }
}

/// Check if a node is a "static" reference — declared in scope or a well-known global.
/// Such references are safe to repeat without side effects and without temp vars.
fn isStaticRef(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .identifier => {
            const name = ctx.tokenSlice(ctx.mainToken(node));
            if (isWellKnownGlobal(name)) return true;
            if (ctx.scope) |scope_result| {
                const scope_idx = scope_mod.getScopeForNode(scope_result, node) orelse return false;
                return scope_mod.getBinding(scope_result, scope_idx, name) != null;
            }
            return false;
        },
        .this_expr => return false, // `this` is safe but Babel still uses temp
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            return isStaticRef(ctx, d.unary);
        },
        else => return false,
    }
}

fn isSimpleRef(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    return switch (tag) {
        .identifier, .this_expr => true,
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            return isSimpleRef(ctx, d.unary);
        },
        else => false,
    };
}

fn isLiteral(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    return switch (tag) {
        .string_literal, .numeric_literal, .boolean_literal, .null_literal => true,
        else => false,
    };
}

/// Well-known globals that are always available and safe to reference multiple times.
fn isWellKnownGlobal(name: []const u8) bool {
    const globals = [_][]const u8{
        "globalThis", "undefined",    "NaN",                "Infinity",
        "console",    "window",       "document",           "navigator",
        "Math",       "JSON",         "Object",             "Array",
        "String",     "Number",       "Boolean",            "Symbol",
        "BigInt",     "Date",         "RegExp",             "Map",
        "Set",        "WeakMap",      "WeakSet",            "Promise",
        "Error",      "TypeError",    "RangeError",         "SyntaxError",
        "parseInt",   "parseFloat",   "isNaN",              "isFinite",
        "encodeURI",  "decodeURI",    "encodeURIComponent", "decodeURIComponent",
        "setTimeout", "clearTimeout", "setInterval",        "clearInterval",
        "require",    "module",       "exports",            "__dirname",
        "__filename", "process",      "Buffer",
    };
    for (globals) |g| {
        if (std.mem.eql(u8, name, g)) return true;
    }
    return false;
}

fn isWellKnownGlobalNode(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    if (tag != .identifier) return false;
    const name = ctx.tokenSlice(ctx.mainToken(node));
    return isWellKnownGlobal(name);
}

fn allocTempForExpr(ctx: *TransformContext, node: NodeIndex, body_idx: u32) []const u8 {
    const prefix = deriveTempPrefix(ctx, node);
    return allocUniqueName(ctx, prefix, body_idx);
}

// ── Temp variable logic ─────────────────────────────────────────────

fn needsTempVar(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .identifier => {
            const name = ctx.tokenSlice(ctx.mainToken(node));
            // Well-known globals are always safe to reference multiple times
            if (isWellKnownGlobal(name)) return false;
            if (ctx.scope) |scope_result| {
                const scope_idx = scope_mod.getScopeForNode(scope_result, node) orelse return false;
                if (scope_mod.getBinding(scope_result, scope_idx, name) != null) {
                    return false;
                }
                // Undeclared — needs temp
                return true;
            }
            return false;
        },
        .this_expr => return true,
        .string_literal, .numeric_literal, .boolean_literal, .null_literal => return false,
        .member_expr, .computed_member_expr => return true,
        .call_expr, .new_expr => return true,
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            return needsTempVar(ctx, d.unary);
        },
        else => return true,
    }
}

fn isSimpleDefaultParameterNullish(ctx: *TransformContext, expr: NodeIndex, lhs: NodeIndex) bool {
    switch (ctx.nodeTag(lhs)) {
        .identifier, .member_expr => {},
        else => return false,
    }

    const parent = findParentOf(ctx, expr);
    if (parent == .none or ctx.nodeTag(parent) != .assignment_pattern) return false;
    if (ctx.nodeData(parent).binary.rhs != expr) return false;
    if (ctx.nodeTag(ctx.nodeData(parent).binary.lhs) != .identifier) return false;

    var current = parent;
    while (true) {
        const ancestor = findParentOf(ctx, current);
        if (ancestor == .none) return true;
        switch (ctx.nodeTag(ancestor)) {
            .property, .shorthand_property, .computed_property, .object_pattern, .array_pattern, .rest_element => return false,
            else => current = ancestor,
        }
    }
}

fn findParentOf(ctx: *TransformContext, target: NodeIndex) NodeIndex {
    const target_i = @intFromEnum(target);
    const tags = ctx.ast.nodes.items(.tag);
    const data_items = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        const data = data_items[ni];
        switch (tag) {
            .member_expr => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
            },
            .computed_member_expr,
            .binary_expr,
            .logical_expr,
            .assignment_expr,
            .conditional_expr,
            .assignment_pattern,
            .declarator,
            .property,
            .computed_property,
            => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
                if (@intFromEnum(data.binary.rhs) == target_i) return @enumFromInt(ni);
            },
            .shorthand_property => {
                if (@intFromEnum(data.unary) == target_i) return @enumFromInt(ni);
            },
            .unary_expr,
            .update_expr,
            .parenthesized_expr,
            .expression_statement,
            .return_statement,
            .throw_statement,
            .spread_element,
            .yield_expr,
            .await_expr,
            => {
                if (@intFromEnum(data.unary) == target_i) return @enumFromInt(ni);
            },
            .call_expr, .new_expr, .optional_call_expr => {
                const eidx = @intFromEnum(data.extra);
                if (eidx < ctx.ast.extra_data.items.len and ctx.ast.extra_data.items[eidx] == target_i) return @enumFromInt(ni);
                if (eidx + 2 < ctx.ast.extra_data.items.len) {
                    const args_start = ctx.ast.extra_data.items[eidx + 1];
                    const args_end = ctx.ast.extra_data.items[eidx + 2];
                    if (args_end > args_start and args_end <= ctx.ast.extra_data.items.len) {
                        for (ctx.ast.extra_data.items[args_start..args_end]) |arg_raw| {
                            if (arg_raw == target_i) return @enumFromInt(ni);
                        }
                    }
                }
            },
            .var_declaration, .let_declaration, .const_declaration, .array_expr, .array_pattern, .object_pattern => {
                const eidx = @intFromEnum(data.extra);
                if (eidx + 1 < ctx.ast.extra_data.items.len) {
                    const range_start = ctx.ast.extra_data.items[eidx];
                    const range_end = ctx.ast.extra_data.items[eidx + 1];
                    if (range_end > range_start and range_end <= ctx.ast.extra_data.items.len) {
                        for (ctx.ast.extra_data.items[range_start..range_end]) |item_raw| {
                            if (item_raw == target_i) return @enumFromInt(ni);
                        }
                    }
                }
            },
            .function_declaration,
            .async_function_declaration,
            .function_expr,
            .arrow_function_expr,
            .class_method,
            .class_private_method,
            .computed_method,
            .method_definition,
            => {
                const eidx = @intFromEnum(data.extra);
                if (eidx + 1 < ctx.ast.extra_data.items.len) {
                    const params_start = ctx.ast.extra_data.items[eidx];
                    const params_end = ctx.ast.extra_data.items[eidx + 1];
                    if (params_end > params_start and params_end <= ctx.ast.extra_data.items.len) {
                        for (ctx.ast.extra_data.items[params_start..params_end]) |param_raw| {
                            if (param_raw == target_i) return @enumFromInt(ni);
                        }
                    }
                }
            },
            else => {},
        }
    }
    return .none;
}

/// Find the enclosing function body (block_statement index) or program (0).
fn findEnclosingBody(ctx: *TransformContext, node: NodeIndex) u32 {
    if (ctx.scope) |scope_result| {
        if (scope_mod.getScopeForNode(scope_result, node)) |scope_idx| {
            var current: ?scope_mod.ScopeIndex = scope_idx;
            while (current) |si| {
                const scope = scope_result.scopes[@intFromEnum(si)];
                switch (scope.kind) {
                    .block => {
                        if (scope.node != .none) {
                            const block_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(scope.node)];
                            if (block_tag == .block_statement) {
                                return @intFromEnum(scope.node);
                            }
                        }
                    },
                    .function => {
                        if (getFunctionBody(ctx, scope.node)) |body| {
                            return @intFromEnum(body);
                        }
                        return 0;
                    },
                    .global, .module => return 0,
                    else => {},
                }
                current = scope.parent;
            }
        }
    }
    // Fallback: brute force search
    return findEnclosingBodyBrute(ctx, node);
}

fn getFunctionBody(ctx: *TransformContext, func_node: NodeIndex) ?NodeIndex {
    const ni = @intFromEnum(func_node);
    const tag = ctx.ast.nodes.items(.tag)[ni];
    const d = ctx.ast.nodes.items(.data)[ni];
    switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        => {
            const eidx = @intFromEnum(d.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
            }
        },
        .method_definition, .class_method, .class_private_method => {
            const eidx = @intFromEnum(d.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
            }
        },
        else => {},
    }
    return null;
}

fn findEnclosingBodyBrute(ctx: *TransformContext, target: NodeIndex) u32 {
    const target_start = getNodeStart(ctx, target);
    const target_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(target)];
    const tags = ctx.ast.nodes.items(.tag);

    var best_body: u32 = 0; // program level
    var best_range: u64 = std.math.maxInt(u64);

    for (tags, 0..) |tag, ni| {
        const is_func = switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .method_definition,
            .class_method,
            .class_private_method,
            => true,
            else => false,
        };
        if (!is_func) continue;

        const func_start = getNodeStart(ctx, @enumFromInt(ni));
        const func_end = ctx.ast.nodes.items(.end_offset)[ni];
        if (func_start > target_start or func_end < target_end) continue;

        const range: u64 = @as(u64, func_end) - @as(u64, func_start);
        if (range < best_range) {
            best_range = range;
            if (getFunctionBody(ctx, @enumFromInt(ni))) |body| {
                best_body = @intFromEnum(body);
            }
        }
    }

    return best_body;
}

fn allocTempName(ctx: *TransformContext, node: NodeIndex, body_idx: u32) []const u8 {
    const prefix = deriveTempPrefix(ctx, node);
    return allocUniqueName(ctx, prefix, body_idx);
}

fn deriveTempPrefix(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .identifier => return ctx.tokenSlice(ctx.mainToken(node)),
        .this_expr => return "this",
        .member_expr, .optional_chain_expr => {
            const d = ctx.nodeData(node);
            const obj_prefix = deriveTempPrefix(ctx, d.binary.lhs);
            const prop_tok = @intFromEnum(d.binary.rhs);
            const prop_name = ctx.ast.tokenSlice(@enumFromInt(prop_tok));
            return std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_prefix, prop_name }) catch "ref";
        },
        .computed_member_expr, .optional_computed_member_expr => {
            const d = ctx.nodeData(node);
            const obj_prefix = deriveTempPrefix(ctx, d.binary.lhs);
            const key_prefix = deriveKeyPrefix(ctx, d.binary.rhs);
            return std.fmt.allocPrint(ctx.allocator, "{s}${s}", .{ obj_prefix, key_prefix }) catch "ref";
        },
        .call_expr => {
            const d = ctx.nodeData(node);
            const extra_idx = @intFromEnum(d.extra);
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            return deriveTempPrefix(ctx, callee);
        },
        .parenthesized_expr => {
            const d = ctx.nodeData(node);
            return deriveTempPrefix(ctx, d.unary);
        },
        else => return "ref",
    }
}

/// Derive a Babel-style prefix for a computed member key.
/// For string literals like "b", use the content "b" (without quotes).
/// For identifiers, use the identifier name.
/// For complex expressions, return "ref".
fn deriveKeyPrefix(ctx: *TransformContext, key_node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(key_node);
    switch (tag) {
        .identifier => return ctx.tokenSlice(ctx.mainToken(key_node)),
        .string_literal => {
            // Get the string content without quotes
            const tok_slice = ctx.tokenSlice(ctx.mainToken(key_node));
            if (tok_slice.len >= 2) {
                return tok_slice[1 .. tok_slice.len - 1]; // strip quotes
            }
            return tok_slice;
        },
        .update_expr => {
            const d = ctx.nodeData(key_node);
            return deriveKeyPrefix(ctx, d.unary);
        },
        .parenthesized_expr => {
            const d = ctx.nodeData(key_node);
            return deriveKeyPrefix(ctx, d.unary);
        },
        else => return "ref",
    }
}

fn allocUniqueName(ctx: *TransformContext, prefix: []const u8, body_idx: u32) []const u8 {
    // Try _prefix first
    const first = std.fmt.allocPrint(ctx.allocator, "_{s}", .{prefix}) catch return "";
    if (!g_allocated_names.contains(first)) {
        g_allocated_names.put(ctx.allocator, first, {}) catch {};
        registerTempForBody(ctx, first, body_idx);
        return first;
    }

    // Try _prefix2, _prefix3, ...
    var counter: u32 = 2;
    while (counter < 10000) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ prefix, counter }) catch return "";
        if (!g_allocated_names.contains(candidate)) {
            g_allocated_names.put(ctx.allocator, candidate, {}) catch {};
            registerTempForBody(ctx, candidate, body_idx);
            return candidate;
        }
    }
    return "";
}

fn registerTempForBody(ctx: *TransformContext, name: []const u8, body_idx: u32) void {
    const gop = g_body_temps.getOrPut(ctx.allocator, body_idx) catch return;
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }
    gop.value_ptr.append(ctx.allocator, name) catch {};
}

// ── Source text helpers ──────────────────────────────────────────────

fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;
    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return ctx.ast.source[start..end];
}

fn normalizeNullishLhsSource(ctx: *TransformContext, node: NodeIndex, src: []const u8) []const u8 {
    switch (ctx.nodeTag(node)) {
        .optional_chain_expr,
        .optional_computed_member_expr,
        .optional_call_expr,
        .parenthesized_expr,
        => return stripOuterParens(src),
        else => return src,
    }
}

fn stripOuterParens(expr: []const u8) []const u8 {
    if (expr.len < 2 or expr[0] != '(' or expr[expr.len - 1] != ')') return expr;

    var depth: i32 = 0;
    for (expr[0 .. expr.len - 1], 0..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0 and i + 1 < expr.len - 1) return expr;
            },
            else => {},
        }
    }

    return expr[1 .. expr.len - 1];
}

fn getNodeStart(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ctx.ast.node_start_overrides.get(ni)) |ov| return ov;

    const tag = ctx.ast.nodes.items(.tag)[ni];
    const d = ctx.ast.nodes.items(.data)[ni];

    switch (tag) {
        .call_expr, .optional_call_expr => {
            const eidx = @intFromEnum(d.extra);
            if (eidx < ctx.ast.extra_data.items.len) {
                const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
                return getNodeStart(ctx, callee);
            }
        },
        .member_expr,
        .computed_member_expr,
        .optional_chain_expr,
        .optional_computed_member_expr,
        => return getNodeStart(ctx, d.binary.lhs),
        .binary_expr, .logical_expr, .assignment_expr => return getNodeStart(ctx, d.binary.lhs),
        .conditional_expr => return getNodeStart(ctx, d.binary.lhs),
        .ts_as_expression, .ts_satisfies_expression => return getNodeStart(ctx, d.binary.lhs),
        .ts_non_null_expression => return getNodeStart(ctx, d.unary),
        .parenthesized_expr => return getNodeStart(ctx, d.unary),
        else => {},
    }

    const main_tok = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
}
