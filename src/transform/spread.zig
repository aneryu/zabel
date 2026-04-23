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

/// Configuration for the spread transform.
pub const Config = struct {
    /// When true, use iterableIsArray assumption (skip toConsumableArray).
    iterable_is_array: bool = false,
    /// When true, allow array-like objects.
    allow_array_like: bool = false,
    /// When true, TS-only wrappers should be dropped from emitted replacement text
    /// because a later TS strip pass cannot see inside replacement_source strings.
    strip_typescript_wrappers: bool = false,
};

var g_config: Config = .{};

/// Global counter for unique temp variable names (_obj, _obj2, etc.)
var g_temp_counter: u32 = 0;
/// Names allocated for temp variable declarations
var g_temp_names: std.ArrayListUnmanaged([]const u8) = .empty;
/// Per-node cache for isKnownArray() results: 0 unknown, 1 visiting, 2 false, 3 true.
var g_known_array_cache_ast: ?*Ast = null;
var g_known_array_cache: []u8 = &[_]u8{};

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.call_expr));
    filter.set(@intFromEnum(Node.Tag.new_expr));
    filter.set(@intFromEnum(Node.Tag.array_expr));
    return .{
        .name = "spread",
        .node_filter = filter,
        .enter = enterNode,
        .priority = 10, // Run before parameters (15) so spreads in function bodies are transformed
    };
}

pub fn resetState() void {
    g_temp_counter = 0;
    g_temp_names = .empty;
    g_known_array_cache_ast = null;
    g_known_array_cache = &[_]u8{};
}

/// Get temp variable declarations to prepend to the output.
pub fn getTempVarDeclarations(allocator: std.mem.Allocator) ?[]const u8 {
    if (g_temp_counter == 0) return null;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(allocator, "var ") catch return null;
    for (g_temp_names.items, 0..) |name, j| {
        if (j > 0) buf.appendSlice(allocator, ", ") catch return null;
        buf.appendSlice(allocator, name) catch return null;
    }
    buf.appendSlice(allocator, ";\n") catch return null;
    return buf.items;
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .call_expr => handleCallExpr(idx, ctx),
        .new_expr => handleNewExpr(idx, ctx),
        .array_expr => handleArrayExpr(idx, ctx),
        else => {},
    }
    return .continue_traversal;
}

// ── Call expression spread ────────────────────────────────────────

fn handleCallExpr(idx: NodeIndex, ctx: *TransformContext) void {
    const i = @intFromEnum(idx);
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const args_start = ctx.ast.extra_data.items[extra_idx + 1];
    const args_end = ctx.ast.extra_data.items[extra_idx + 2];

    if (args_start >= args_end) return;

    // Check if any argument is a spread element
    if (!hasSpreadArg(ctx, args_start, args_end)) return;

    // Unwrap transparent wrappers to find the real callee shape while still
    // preserving the original wrapper syntax in the emitted replacement.
    const real_callee = unwrapTransparent(ctx, callee);
    const callee_tag = ctx.nodeTag(real_callee);

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    if (callee_tag == .member_expr or callee_tag == .computed_member_expr) {
        // Method call: need to preserve `this` context
        handleMethodCallSpread(&buf, ctx, callee, real_callee, args_start, args_end);
    } else {
        // Regular function call (or super call without classes plugin)
        handleFunctionCallSpread(&buf, ctx, callee, args_start, args_end);
    }

    if (buf.items.len > 0) {
        ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch return;
    }
}

fn handleFunctionCallSpread(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, callee: NodeIndex, args_start: u32, args_end: u32) void {
    const callee_src = getNodeSource(ctx, callee);

    buf.appendSlice(ctx.allocator, callee_src) catch return;
    buf.appendSlice(ctx.allocator, ".apply(void 0, ") catch return;
    buildCallArgsArray(buf, ctx, args_start, args_end);
    buf.append(ctx.allocator, ')') catch return;
}

fn handleMethodCallSpread(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, original_callee: NodeIndex, real_callee: NodeIndex, args_start: u32, args_end: u32) void {
    const callee_tag = ctx.nodeTag(real_callee);
    const callee_data = ctx.nodeData(real_callee);

    // Get the object and property parts
    const obj_node = callee_data.binary.lhs;
    const prop_node = callee_data.binary.rhs;
    const obj_tag = ctx.nodeTag(obj_node);
    const is_computed = callee_tag == .computed_member_expr;

    // Check if `super.method(...)` — use `this` as context
    if (obj_tag == .super_expr) {
        emitCalleeSrc(buf, ctx, real_callee);
        buf.appendSlice(ctx.allocator, ".apply(this, ") catch return;
        buildCallArgsArray(buf, ctx, args_start, args_end);
        buf.append(ctx.allocator, ')') catch return;
        return;
    }

    // `this.method(...)` — `this` is stable, no temp needed
    if (obj_tag == .this_expr) {
        buf.appendSlice(ctx.allocator, "this") catch return;
        emitPropAccess(buf, ctx, prop_node, is_computed);
        buf.appendSlice(ctx.allocator, ".apply(this, ") catch return;
        buildCallArgsArray(buf, ctx, args_start, args_end);
        buf.append(ctx.allocator, ')') catch return;
        return;
    }

    if (isStableMethodReceiver(ctx, obj_node) and hasRestParameterSpreadArg(ctx, args_start, args_end)) {
        wrapTransparentSource(buf, ctx, original_callee, real_callee, getNodeSource(ctx, real_callee), g_config.strip_typescript_wrappers);
        buf.appendSlice(ctx.allocator, ".apply(") catch return;
        buf.appendSlice(ctx.allocator, getNodeSource(ctx, obj_node)) catch return;
        buf.appendSlice(ctx.allocator, ", ") catch return;
        buildCallArgsArray(buf, ctx, args_start, args_end);
        buf.append(ctx.allocator, ')') catch return;
        return;
    }

    // All other cases: use temp var
    const temp_name = generateMethodTempName(ctx, obj_node);
    const obj_src = getNodeSource(ctx, obj_node);

    // Build: (_temp = obj).prop, then re-wrap any transparent TS/parens wrappers
    // around the original callee before appending .apply(...)
    var member_buf: std.ArrayListUnmanaged(u8) = .empty;
    member_buf.appendSlice(ctx.allocator, "(") catch return;
    member_buf.appendSlice(ctx.allocator, temp_name) catch return;
    member_buf.appendSlice(ctx.allocator, " = ") catch return;
    member_buf.appendSlice(ctx.allocator, obj_src) catch return;
    member_buf.appendSlice(ctx.allocator, ")") catch return;
    emitPropAccess(&member_buf, ctx, prop_node, is_computed);

    wrapTransparentSource(buf, ctx, original_callee, real_callee, member_buf.items, g_config.strip_typescript_wrappers);
    buf.appendSlice(ctx.allocator, ".apply(") catch return;
    buf.appendSlice(ctx.allocator, temp_name) catch return;
    buf.appendSlice(ctx.allocator, ", ") catch return;
    // For method calls with concat args, arguments needs Array.prototype.slice.call
    buildCallArgsArray(buf, ctx, args_start, args_end);
    buf.append(ctx.allocator, ')') catch return;
}

fn isStableMethodReceiver(ctx: *TransformContext, obj_node: NodeIndex) bool {
    if (obj_node == .none) return false;
    const real_obj = unwrapTransparent(ctx, obj_node);
    return ctx.nodeTag(real_obj) == .identifier;
}

fn hasRestParameterSpreadArg(ctx: *TransformContext, args_start: u32, args_end: u32) bool {
    if (args_end <= args_start) return false;
    for (ctx.ast.extra_data.items[args_start..args_end]) |arg_raw| {
        const arg: NodeIndex = @enumFromInt(arg_raw);
        if (arg == .none or ctx.nodeTag(arg) != .spread_element) continue;
        if (isRestParameter(ctx, getSpreadArgument(ctx, arg))) return true;
    }
    return false;
}

fn emitPropAccess(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, prop_node: NodeIndex, is_computed: bool) void {
    if (is_computed) {
        // computed_member_expr: rhs is a real expression node
        buf.append(ctx.allocator, '[') catch {};
        buf.appendSlice(ctx.allocator, getNodeSource(ctx, prop_node)) catch {};
        buf.append(ctx.allocator, ']') catch {};
    } else {
        // member_expr: rhs is a TOKEN index stored as NodeIndex
        const tok: TokenIndex = @enumFromInt(@intFromEnum(prop_node));
        buf.append(ctx.allocator, '.') catch {};
        buf.appendSlice(ctx.allocator, ctx.tokenSlice(tok)) catch {};
    }
}

fn emitCalleeSrc(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, callee: NodeIndex) void {
    buf.appendSlice(ctx.allocator, getNodeSource(ctx, callee)) catch {};
}

fn unwrapTransparent(ctx: *TransformContext, node: NodeIndex) NodeIndex {
    var current = node;
    while (true) {
        if (current == .none) return current;
        const tag = ctx.nodeTag(current);
        switch (tag) {
            .parenthesized_expr, .ts_non_null_expression => {
                current = ctx.nodeData(current).unary;
            },
            .ts_as_expression, .ts_satisfies_expression => {
                current = ctx.nodeData(current).binary.lhs;
            },
            .ts_type_assertion => {
                current = ctx.nodeData(current).binary.rhs;
            },
            .flow_type_cast_expression => {
                const extra_idx = @intFromEnum(ctx.nodeData(current).extra);
                if (extra_idx >= ctx.ast.extra_data.items.len) return current;
                current = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            },
            else => return current,
        }
    }
}

fn wrapTransparentSource(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    node: NodeIndex,
    real_node: NodeIndex,
    inner_src: []const u8,
    strip_ts_wrappers: bool,
) void {
    if (node == real_node) {
        buf.appendSlice(ctx.allocator, inner_src) catch {};
        return;
    }

    const tag = ctx.nodeTag(node);
    const data = ctx.nodeData(node);
    switch (tag) {
        .parenthesized_expr => {
            const child = data.unary;
            if (strip_ts_wrappers or ctx.nodeTag(child) == .flow_type_cast_expression) {
                wrapTransparentSource(buf, ctx, data.unary, real_node, inner_src, strip_ts_wrappers);
            } else {
                buf.append(ctx.allocator, '(') catch {};
                wrapTransparentSource(buf, ctx, data.unary, real_node, inner_src, strip_ts_wrappers);
                buf.append(ctx.allocator, ')') catch {};
            }
        },
        .ts_non_null_expression => {
            wrapTransparentSource(buf, ctx, data.unary, real_node, inner_src, strip_ts_wrappers);
            if (!strip_ts_wrappers) {
                buf.append(ctx.allocator, '!') catch {};
            }
        },
        .ts_as_expression => {
            wrapTransparentSource(buf, ctx, data.binary.lhs, real_node, inner_src, strip_ts_wrappers);
            if (!strip_ts_wrappers) {
                buf.appendSlice(ctx.allocator, " as ") catch {};
                buf.appendSlice(ctx.allocator, getNodeSource(ctx, data.binary.rhs)) catch {};
            }
        },
        .ts_satisfies_expression => {
            wrapTransparentSource(buf, ctx, data.binary.lhs, real_node, inner_src, strip_ts_wrappers);
            if (!strip_ts_wrappers) {
                buf.appendSlice(ctx.allocator, " satisfies ") catch {};
                buf.appendSlice(ctx.allocator, getNodeSource(ctx, data.binary.rhs)) catch {};
            }
        },
        .ts_type_assertion => {
            if (!strip_ts_wrappers) {
                buf.append(ctx.allocator, '<') catch {};
                buf.appendSlice(ctx.allocator, getNodeSource(ctx, data.binary.lhs)) catch {};
                buf.appendSlice(ctx.allocator, "> ") catch {};
            }
            wrapTransparentSource(buf, ctx, data.binary.rhs, real_node, inner_src, strip_ts_wrappers);
        },
        .flow_type_cast_expression => {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) {
                buf.appendSlice(ctx.allocator, inner_src) catch {};
                return;
            }
            const expr_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const type_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            buf.append(ctx.allocator, '(') catch {};
            wrapTransparentSource(buf, ctx, expr_node, real_node, inner_src, strip_ts_wrappers);
            buf.appendSlice(ctx.allocator, ": ") catch {};
            buf.appendSlice(ctx.allocator, getNodeSource(ctx, type_node)) catch {};
            buf.append(ctx.allocator, ')') catch {};
        },
        else => {
            buf.appendSlice(ctx.allocator, inner_src) catch {};
        },
    }
}

// ── New expression spread ─────────────────────────────────────────

fn handleNewExpr(idx: NodeIndex, ctx: *TransformContext) void {
    const i = @intFromEnum(idx);
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const args_start = ctx.ast.extra_data.items[extra_idx + 1];
    const args_end = ctx.ast.extra_data.items[extra_idx + 2];

    if (args_start >= args_end) return;
    if (!hasSpreadArg(ctx, args_start, args_end)) return;

    const callee_src = getNodeSource(ctx, callee);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "babelHelpers.construct(") catch return;
    buf.appendSlice(ctx.allocator, callee_src) catch return;
    buf.appendSlice(ctx.allocator, ", ") catch return;
    buildCallArgsArray(&buf, ctx, args_start, args_end);
    buf.append(ctx.allocator, ')') catch return;

    ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch return;
}

// ── Array expression spread ───────────────────────────────────────

fn handleArrayExpr(idx: NodeIndex, ctx: *TransformContext) void {
    const i = @intFromEnum(idx);
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const elems_start = ctx.ast.extra_data.items[extra_idx];
    const elems_end = ctx.ast.extra_data.items[extra_idx + 1];

    if (elems_start >= elems_end) return;
    if (!hasSpreadElement(ctx, elems_start, elems_end)) return;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buildArraySpread(&buf, ctx, elems_start, elems_end);

    if (buf.items.len > 0) {
        ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch return;
    }
}

// ── Build args array for call/new spread ──────────────────────────

/// Build args array for call/new spread.
/// When there's a single `...arguments`, pass it directly.
/// Otherwise, use concat chain with Array.prototype.slice.call for arguments.
fn buildCallArgsArray(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, args_start: u32, args_end: u32) void {
    const args = ctx.ast.extra_data.items[args_start..args_end];

    // Single spread as only arg: f(...args) -> f.apply(void 0, args)
    if (args.len == 1) {
        const arg: NodeIndex = @enumFromInt(args[0]);
        if (arg != .none and ctx.nodeTag(arg) == .spread_element) {
            const inner = getSpreadArgument(ctx, arg);
            // Only pass `arguments` directly when it's the sole argument
            if (isArgumentsIdentifier(ctx, inner)) {
                buf.appendSlice(ctx.allocator, "arguments") catch {};
                return;
            }
            emitSpreadValue(buf, ctx, inner);
            return;
        }
    }

    // Multiple args with spread: use the array concat pattern
    // (arguments in concat position uses Array.prototype.slice.call)
    buildConcatChain(buf, ctx, args);
}

/// Build args array for array spread (arguments becomes Array.prototype.slice.call(arguments))
fn buildArgsArray(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, args_start: u32, args_end: u32) void {
    const args = ctx.ast.extra_data.items[args_start..args_end];

    if (args.len == 1) {
        const arg: NodeIndex = @enumFromInt(args[0]);
        if (arg != .none and ctx.nodeTag(arg) == .spread_element) {
            const inner = getSpreadArgument(ctx, arg);
            emitSpreadValue(buf, ctx, inner);
            return;
        }
    }

    buildConcatChain(buf, ctx, args);
}

// ── Build concat chain (grouping all segments into one .concat()) ──

const Segment = struct {
    kind: enum { array, spread },
    array_start: usize = 0,
    array_end: usize = 0,
    spread_node: NodeIndex,
};

fn collectSegments(segments: *std.ArrayListUnmanaged(Segment), ctx: *TransformContext, elements: []const u32) void {
    var current_array_start: ?usize = null;

    for (elements, 0..) |elem_raw, idx| {
        const elem: NodeIndex = @enumFromInt(elem_raw);
        const is_spread = elem != .none and ctx.nodeTag(elem) == .spread_element;
        if (is_spread) {
            if (current_array_start) |start| {
                segments.append(ctx.allocator, .{
                    .kind = .array,
                    .array_start = start,
                    .array_end = idx,
                    .spread_node = .none,
                }) catch return;
                current_array_start = null;
            }
            segments.append(ctx.allocator, .{
                .kind = .spread,
                .spread_node = elem,
            }) catch return;
            continue;
        }

        if (current_array_start == null) current_array_start = idx;
    }

    if (current_array_start) |start| {
        segments.append(ctx.allocator, .{
            .kind = .array,
            .array_start = start,
            .array_end = elements.len,
            .spread_node = .none,
        }) catch {};
    }
}

fn emitSegment(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, elements: []const u32, segment: Segment) void {
    switch (segment.kind) {
        .array => emitArrayLiteral(buf, ctx, elements[segment.array_start..segment.array_end]),
        .spread => emitSpreadValue(buf, ctx, getSpreadArgument(ctx, segment.spread_node)),
    }
}

fn buildConcatChain(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, elements: []const u32) void {
    var segments: std.ArrayListUnmanaged(Segment) = .empty;
    collectSegments(&segments, ctx, elements);
    if (segments.items.len == 0) return;

    emitSegment(buf, ctx, elements, segments.items[0]);

    if (segments.items.len > 1) {
        buf.appendSlice(ctx.allocator, ".concat(") catch return;
        var first = true;
        for (segments.items[1..]) |segment| {
            if (!first) buf.appendSlice(ctx.allocator, ", ") catch {};
            first = false;
            emitSegment(buf, ctx, elements, segment);
        }
        buf.append(ctx.allocator, ')') catch return;
    }
}

// ── Build array spread ────────────────────────────────────────────

fn buildArraySpread(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, elems_start: u32, elems_end: u32) void {
    const elems = ctx.ast.extra_data.items[elems_start..elems_end];

    // Check if [... single spread only]
    if (elems.len == 1) {
        const elem: NodeIndex = @enumFromInt(elems[0]);
        if (elem != .none and ctx.nodeTag(elem) == .spread_element) {
            const inner = getSpreadArgument(ctx, elem);
            // Known array: use [].concat(arr) for shallow copy
            if (isKnownArray(ctx, inner) and !isArrayLiteralWithHoles(ctx, inner)) {
                buf.appendSlice(ctx.allocator, "[].concat(") catch {};
                buf.appendSlice(ctx.allocator, getNodeSource(ctx, inner)) catch {};
                buf.append(ctx.allocator, ')') catch {};
                return;
            }
            emitSpreadValue(buf, ctx, inner);
            return;
        }
    }

    var segments: std.ArrayListUnmanaged(Segment) = .empty;
    collectSegments(&segments, ctx, elems);
    if (segments.items.len == 0) return;

    const first_is_spread = segments.items[0].kind == .spread;
    if (first_is_spread) {
        buf.appendSlice(ctx.allocator, "[].concat(") catch return;
        var first = true;
        for (segments.items) |segment| {
            if (!first) buf.appendSlice(ctx.allocator, ", ") catch {};
            first = false;
            emitSegment(buf, ctx, elems, segment);
        }
        buf.append(ctx.allocator, ')') catch return;
    } else {
        emitSegment(buf, ctx, elems, segments.items[0]);

        if (segments.items.len > 1) {
            buf.appendSlice(ctx.allocator, ".concat(") catch return;
            var first = true;
            for (segments.items[1..]) |segment| {
                if (!first) buf.appendSlice(ctx.allocator, ", ") catch {};
                first = false;
                emitSegment(buf, ctx, elems, segment);
            }
            buf.append(ctx.allocator, ')') catch return;
        }
    }
}

// ── Emit spread value (with appropriate helper) ───────────────────

fn emitSpreadValue(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, inner: NodeIndex) void {
    const inner_src = getNodeSource(ctx, inner);

    if (isArgumentsIdentifier(ctx, inner)) {
        buf.appendSlice(ctx.allocator, "Array.prototype.slice.call(arguments)") catch {};
        return;
    }

    if (isArrayLiteralWithHoles(ctx, inner)) {
        buf.appendSlice(ctx.allocator, "babelHelpers.arrayLikeToArray(") catch {};
        // Reconstruct array literal to normalize elision formatting (no space before elision comma)
        buf.appendSlice(ctx.allocator, reconstructArrayLiteral(ctx, inner)) catch {};
        buf.append(ctx.allocator, ')') catch {};
        return;
    }

    if (g_config.iterable_is_array) {
        buf.appendSlice(ctx.allocator, inner_src) catch {};
        return;
    }

    // Check if inner is an array literal (no holes) — can be used directly
    if (isArrayLiteralNoHoles(ctx, inner)) {
        buf.appendSlice(ctx.allocator, inner_src) catch {};
        return;
    }

    // Check if inner is a known array (e.g., variable bound to [])
    if (isKnownArray(ctx, inner)) {
        buf.appendSlice(ctx.allocator, inner_src) catch {};
        return;
    }

    if (g_config.allow_array_like) {
        buf.appendSlice(ctx.allocator, "babelHelpers.maybeArrayLike(babelHelpers.toConsumableArray, ") catch {};
        buf.appendSlice(ctx.allocator, inner_src) catch {};
        buf.append(ctx.allocator, ')') catch {};
    } else {
        buf.appendSlice(ctx.allocator, "babelHelpers.toConsumableArray(") catch {};
        buf.appendSlice(ctx.allocator, inner_src) catch {};
        buf.append(ctx.allocator, ')') catch {};
    }
}

// ── Helpers ───────────────────────────────────────────────────────

fn hasSpreadArg(ctx: *TransformContext, args_start: u32, args_end: u32) bool {
    for (ctx.ast.extra_data.items[args_start..args_end]) |arg_raw| {
        const arg: NodeIndex = @enumFromInt(arg_raw);
        if (arg == .none) continue;
        if (ctx.nodeTag(arg) == .spread_element) return true;
    }
    return false;
}

fn hasSpreadElement(ctx: *TransformContext, start: u32, end: u32) bool {
    for (ctx.ast.extra_data.items[start..end]) |elem_raw| {
        const elem: NodeIndex = @enumFromInt(elem_raw);
        if (elem == .none) continue;
        if (ctx.nodeTag(elem) == .spread_element) return true;
    }
    return false;
}

fn getSpreadArgument(ctx: *TransformContext, spread_node: NodeIndex) NodeIndex {
    const data = ctx.nodeData(spread_node);
    return data.unary;
}

fn isArgumentsIdentifier(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    if (ctx.nodeTag(node) != .identifier) return false;
    const name = ctx.tokenSlice(ctx.mainToken(node));
    return std.mem.eql(u8, name, "arguments");
}

fn isArrayLiteralWithHoles(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    if (ctx.nodeTag(node) != .array_expr) return false;
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const start = ctx.ast.extra_data.items[extra_idx];
    const end = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[start..end]) |elem_raw| {
        const elem: NodeIndex = @enumFromInt(elem_raw);
        if (elem == .none) return true;
    }
    return false;
}

/// Reconstruct an array literal from AST elements, normalizing elision formatting.
/// Produces `[1,, 3]` instead of `[1, , 3]` (no space before elision comma).
fn reconstructArrayLiteral(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "[]";
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return "[]";
    const start = ctx.ast.extra_data.items[extra_idx];
    const end = ctx.ast.extra_data.items[extra_idx + 1];

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return "[]";

    var first = true;
    for (ctx.ast.extra_data.items[start..end]) |elem_raw| {
        const elem: NodeIndex = @enumFromInt(elem_raw);
        if (elem == .none) {
            // Elision: emit comma directly with no space
            if (!first) {
                buf.append(ctx.allocator, ',') catch {};
            }
            first = false;
            continue;
        }
        if (!first) {
            buf.appendSlice(ctx.allocator, ", ") catch {};
        }
        first = false;
        buf.appendSlice(ctx.allocator, getNodeSource(ctx, elem)) catch {};
    }

    buf.append(ctx.allocator, ']') catch {};
    return buf.items;
}

/// Check if the node is a known array — either an array literal or
/// an identifier bound to an array-producing expression.
fn isKnownArray(ctx: *TransformContext, node: NodeIndex) bool {
    ensureKnownArrayCache(ctx);
    if (node == .none) return false;
    const ni = @intFromEnum(node);
    if (ni < g_known_array_cache.len) {
        switch (g_known_array_cache[ni]) {
            1, 2 => return false,
            3 => return true,
            else => {},
        }
        g_known_array_cache[ni] = 1;
    }
    const result = computeKnownArray(ctx, node);
    if (ni < g_known_array_cache.len) {
        g_known_array_cache[ni] = if (result) 3 else 2;
    }
    return result;
}

fn ensureKnownArrayCache(ctx: *TransformContext) void {
    if (g_known_array_cache_ast == ctx.ast) return;
    g_known_array_cache_ast = ctx.ast;
    g_known_array_cache = ctx.allocator.alloc(u8, ctx.ast.nodes.items(.tag).len) catch &[_]u8{};
    @memset(g_known_array_cache, 0);
}

fn computeKnownArray(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);

    switch (tag) {
        .array_expr => return true,
        .parenthesized_expr, .ts_non_null_expression => return isKnownArray(ctx, ctx.nodeData(node).unary),
        .ts_as_expression, .ts_satisfies_expression => {
            const data = ctx.nodeData(node);
            if (isArrayTypeSource(getNodeSource(ctx, data.binary.rhs))) return true;
            return isKnownArray(ctx, data.binary.lhs);
        },
        .ts_type_assertion => {
            const data = ctx.nodeData(node);
            if (isArrayTypeSource(getNodeSource(ctx, data.binary.lhs))) return true;
            return isKnownArray(ctx, data.binary.rhs);
        },
        .call_expr, .optional_call_expr => return isArrayReturningCall(ctx, node),
        .conditional_expr => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.binary.rhs);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
            const consequent: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const alternate: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            return isKnownArray(ctx, consequent) and isKnownArray(ctx, alternate);
        },
        .logical_expr => {
            const data = ctx.nodeData(node);
            return isKnownArray(ctx, data.binary.lhs) and isKnownArray(ctx, data.binary.rhs);
        },
        else => {},
    }

    if (tag == .identifier) {
        const binding = resolveBinding(ctx, node) orelse return false;
        if (binding.is_rest_param) return true;
        switch (binding.kind) {
            .var_decl, .let_decl, .const_decl => {
                if (binding.init_node == .none) return false;
                return isKnownArrayBindingInit(ctx, binding.init_node);
            },
            else => return false,
        }
    }

    return false;
}

fn isKnownArrayBindingInit(ctx: *TransformContext, init_node: NodeIndex) bool {
    const node = unwrapTransparent(ctx, init_node);
    if (node == .none) return false;

    switch (ctx.nodeTag(node)) {
        .array_expr => return true,
        .parenthesized_expr, .ts_non_null_expression => return isKnownArrayBindingInit(ctx, ctx.nodeData(node).unary),
        .ts_as_expression, .ts_satisfies_expression => {
            const data = ctx.nodeData(node);
            if (isArrayTypeSource(getNodeSource(ctx, data.binary.rhs))) return true;
            return isKnownArrayBindingInit(ctx, data.binary.lhs);
        },
        .ts_type_assertion => {
            const data = ctx.nodeData(node);
            if (isArrayTypeSource(getNodeSource(ctx, data.binary.lhs))) return true;
            return isKnownArrayBindingInit(ctx, data.binary.rhs);
        },
        .call_expr, .optional_call_expr => return isArrayReturningCall(ctx, node),
        .conditional_expr => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.binary.rhs);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
            const consequent: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const alternate: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            return isKnownArrayBindingInit(ctx, consequent) and isKnownArrayBindingInit(ctx, alternate);
        },
        .logical_expr => {
            const data = ctx.nodeData(node);
            return isKnownArrayBindingInit(ctx, data.binary.lhs) and isKnownArrayBindingInit(ctx, data.binary.rhs);
        },
        .identifier => return false,
        else => return false,
    }
}

fn isArrayReturningCall(ctx: *TransformContext, node: NodeIndex) bool {
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx >= ctx.ast.extra_data.items.len) return false;
    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    if (callee == .none) return false;
    if (isBuiltInArrayFactoryCall(ctx, callee)) return true;

    const real_callee = unwrapTransparent(ctx, callee);
    if (real_callee == .none or ctx.nodeTag(real_callee) != .identifier) return false;

    const binding = resolveBinding(ctx, real_callee) orelse return false;
    if (binding.kind == .function_decl and functionReturnsArray(ctx, binding.node)) return true;
    if (binding.init_node != .none and functionReturnsArray(ctx, binding.init_node)) return true;
    return false;
}

fn resolveBinding(ctx: *TransformContext, ident_node: NodeIndex) ?*const scope_mod.Binding {
    if (ident_node == .none or ctx.nodeTag(ident_node) != .identifier) return null;
    if (ctx.getBindingForNode(ident_node)) |binding| return binding;
    const scope_result = ctx.scope orelse return null;
    return scope_mod.resolveBindingForNode(scope_result, ident_node, ctx.tokenSlice(ctx.mainToken(ident_node)));
}

fn isBuiltInArrayFactoryCall(ctx: *TransformContext, callee: NodeIndex) bool {
    const callee_src = getNodeSource(ctx, callee);
    return std.mem.eql(u8, callee_src, "Array.from") or
        std.mem.eql(u8, callee_src, "Object.keys") or
        std.mem.eql(u8, callee_src, "Object.values") or
        std.mem.eql(u8, callee_src, "Object.entries");
}

fn functionReturnsArray(ctx: *TransformContext, node: NodeIndex) bool {
    const real_node = unwrapTransparent(ctx, node);
    if (real_node == .none) return false;
    switch (ctx.nodeTag(real_node)) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .arrow_function_expr,
        => {
            if (ctx.ast.return_types.get(@intFromEnum(real_node))) |ret_ty| {
                if (isArrayTypeSource(getNodeSource(ctx, ret_ty))) return true;
            }
            return looksLikeFunctionArrayReturn(getNodeSource(ctx, real_node));
        },
        else => return false,
    }
}

fn isArrayTypeSource(src: []const u8) bool {
    if (src.len == 0) return false;
    if (std.mem.startsWith(u8, src, "Array<")) return true;
    if (std.mem.endsWith(u8, src, "[]")) return true;
    return false;
}

fn looksLikeFunctionArrayReturn(src: []const u8) bool {
    const header_end = std.mem.indexOfScalar(u8, src, '{') orelse src.len;
    const header = src[0..header_end];
    if (std.mem.indexOf(u8, header, "): Array<") != null) return true;
    if (std.mem.indexOf(u8, header, "): ") != null and std.mem.endsWith(u8, std.mem.trim(u8, header, " \t\r\n"), "[]")) {
        return true;
    }
    return false;
}

fn isArrayLiteralNoHoles(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    if (ctx.nodeTag(node) != .array_expr) return false;
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const start = ctx.ast.extra_data.items[extra_idx];
    const end = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[start..end]) |elem_raw| {
        const elem: NodeIndex = @enumFromInt(elem_raw);
        if (elem == .none) return false;
    }
    return true;
}

fn emitArrayLiteral(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, items: []const u32) void {
    buf.append(ctx.allocator, '[') catch return;
    for (items, 0..) |item_raw, j| {
        const item: NodeIndex = @enumFromInt(item_raw);
        if (j > 0) {
            buf.append(ctx.allocator, ',') catch {};
            // Add space before a real element (always, even after a hole)
            if (item != .none) {
                buf.append(ctx.allocator, ' ') catch {};
            }
        }
        if (item != .none) {
            buf.appendSlice(ctx.allocator, getNodeSource(ctx, item)) catch {};
        }
    }
    buf.append(ctx.allocator, ']') catch return;
}

// ── Method call temp name generation ──────────────────────────────

fn generateMethodTempName(ctx: *TransformContext, obj_node: NodeIndex) []const u8 {
    // Build a name from the member expression chain
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    name_buf.append(ctx.allocator, '_') catch {};
    buildMemberName(&name_buf, ctx, obj_node);

    const base = ctx.allocator.dupe(u8, name_buf.items) catch "";
    g_temp_counter += 1;
    g_temp_names.append(ctx.allocator, base) catch {};
    return base;
}

fn buildMemberName(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, node: NodeIndex) void {
    if (node == .none) return;
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .identifier => {
            buf.appendSlice(ctx.allocator, ctx.tokenSlice(ctx.mainToken(node))) catch {};
        },
        .member_expr => {
            const data = ctx.nodeData(node);
            buildMemberName(buf, ctx, data.binary.lhs);
            buf.append(ctx.allocator, '$') catch {};
            // rhs for member_expr is a token index stored as NodeIndex
            const tok: TokenIndex = @enumFromInt(@intFromEnum(data.binary.rhs));
            buf.appendSlice(ctx.allocator, ctx.tokenSlice(tok)) catch {};
        },
        else => {
            buf.appendSlice(ctx.allocator, "obj") catch {};
        },
    }
}

/// Check if an identifier resolves to a rest parameter binding.
fn isRestParameter(ctx: *TransformContext, ident_node: NodeIndex) bool {
    const binding = resolveBinding(ctx, ident_node) orelse return false;
    return binding.is_rest_param;
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

fn getNodeStart(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ctx.ast.node_start_overrides.get(ni)) |override| return override;

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
        .spread_element, .rest_element => return getNodeStart(ctx, d.unary),
        .new_expr => {
            const mt_idx = ctx.ast.nodes.items(.main_token)[ni];
            return ctx.ast.tokens.items(.start)[@intFromEnum(mt_idx)];
        },
        else => {},
    }

    const mt_idx = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(mt_idx)];
}
