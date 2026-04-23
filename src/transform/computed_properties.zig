const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

/// Configuration for the computed-properties transform.
pub const Config = struct {
    /// When true, use `_obj[key] = val` instead of `babelHelpers.defineProperty(...)`.
    set_computed_properties: bool = false,
};

var g_config: Config = .{};

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.object_expr));
    return .{
        .name = "computed_properties",
        .node_filter = filter,
        .enter = enterNode,
        .priority = 20,
    };
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .object_expr => handleObjectExpr(idx, ctx),
        else => {},
    }
    return .continue_traversal;
}

// ── Property classification ─────────────────────────────────────────

const PropKind = enum {
    normal, // property, shorthand_property
    computed, // computed_property
    method, // method_definition
    computed_method, // computed_method
    getter, // getter (non-computed)
    setter, // setter (non-computed)
    getter_computed, // getter (computed)
    setter_computed, // setter (computed)
    proto_shorthand, // __proto__ shorthand
    proto_method, // __proto__() method
};

const PropInfo = struct {
    kind: PropKind,
    node: NodeIndex,
};

fn classifyProp(ctx: *TransformContext, node: NodeIndex) PropInfo {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .computed_property => return .{ .kind = .computed, .node = node },
        .computed_method => return .{ .kind = .computed_method, .node = node },
        .shorthand_property => {
            // Check if __proto__
            const data = ctx.nodeData(node);
            const name = getIdentName(ctx, data.unary) orelse "";
            if (std.mem.eql(u8, name, "__proto__")) {
                return .{ .kind = .proto_shorthand, .node = node };
            }
            return .{ .kind = .normal, .node = node };
        },
        .method_definition => {
            // Check if __proto__
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            const key_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const name = getIdentName(ctx, key_node) orelse "";
            if (std.mem.eql(u8, name, "__proto__")) {
                return .{ .kind = .proto_method, .node = node };
            }
            return .{ .kind = .method, .node = node };
        },
        .getter, .setter => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            const flags = if (extra_idx + 3 < ctx.ast.extra_data.items.len)
                ctx.ast.extra_data.items[extra_idx + 3]
            else
                0;
            const is_computed = (flags & 8) != 0;
            if (tag == .getter) {
                return .{ .kind = if (is_computed) .getter_computed else .getter, .node = node };
            } else {
                return .{ .kind = if (is_computed) .setter_computed else .setter, .node = node };
            }
        },
        .property => {
            return .{ .kind = .normal, .node = node };
        },
        else => return .{ .kind = .normal, .node = node },
    }
}

fn isComputedOrSpecial(kind: PropKind) bool {
    return switch (kind) {
        .computed,
        .computed_method,
        .getter,
        .setter,
        .getter_computed,
        .setter_computed,
        .proto_shorthand,
        .proto_method,
        .method,
        => true,
        .normal => false,
    };
}

// ── Main handler ────────��───────────────────────────────────────────

fn handleObjectExpr(idx: NodeIndex, ctx: *TransformContext) void {
    const i: u32 = @intCast(@intFromEnum(idx));
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    if (range_start >= range_end) return;

    const items = ctx.ast.extra_data.items[range_start..range_end];

    // Check if any property is computed or needs transformation
    var has_computed = false;
    for (items) |item| {
        const node: NodeIndex = @enumFromInt(item);
        const info = classifyProp(ctx, node);
        if (isComputedOrSpecial(info.kind)) {
            has_computed = true;
            break;
        }
    }

    if (!has_computed) return;

    // In spec mode: all properties become defineProperty/defineAccessor chains
    // In set mode: uses temp variable for computed properties
    if (g_config.set_computed_properties) {
        handleSetMode(ctx, idx, i, items) catch return;
    } else {
        handleSpecMode(ctx, idx, i, items) catch return;
    }
}

// ── Spec mode ───────���──────────────────────────────��────────────────

fn handleSpecMode(ctx: *TransformContext, idx: NodeIndex, i: u32, items: []const u32) !void {
    // In spec mode, once we encounter the first computed/special property,
    // ALL remaining properties (including normal ones) get chained through defineProperty.
    //
    // The pattern:
    // - Collect leading normal properties into a literal object: { a: 1, b: 2 }
    // - Then chain defineProperty/defineAccessor calls for all remaining properties
    //
    // Wait, looking at the fixtures more carefully:
    // spec/mixed: { ["x"+heh]: "heh", ["y"+noo]: "noo", [foo]: "foo1", foo: "foo2", bar: "bar" }
    //   -> defineProperty(defineProperty(defineProperty(defineProperty(defineProperty({}, ...heh...), ...noo...), foo, "foo1"), "foo", "foo2"), "bar", "bar")
    // ALL properties become defineProperty, even foo and bar at the end.
    //
    // spec/two: { first: "first", ["second"]: "second" }
    //   -> defineProperty({ first: "first" }, "second", "second")
    // Only the computed one, with leading normals in literal.
    //
    // So the rule: once a computed property is seen, ALL remaining properties
    // (including normal ones) are chained as defineProperty calls.
    // Leading normal properties stay in the literal object.

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var prop_chain: std.ArrayListUnmanaged(PropCall) = .empty;

    // Find first computed/special property
    var first_special: usize = items.len;
    for (items, 0..) |item, j| {
        const node: NodeIndex = @enumFromInt(item);
        const info = classifyProp(ctx, node);
        if (isComputedOrSpecial(info.kind)) {
            first_special = j;
            break;
        }
    }

    // Build leading literal object
    var literal_props: std.ArrayListUnmanaged([]const u8) = .empty;
    for (items[0..first_special]) |item| {
        const node: NodeIndex = @enumFromInt(item);
        const prop_src = getNodeSource(ctx, node);
        literal_props.append(ctx.allocator, prop_src) catch return;
    }

    // Build chain of defineProperty/defineAccessor calls for remaining properties
    for (items[first_special..]) |item| {
        const node: NodeIndex = @enumFromInt(item);
        const info = classifyProp(ctx, node);
        const call = buildPropCall(ctx, info) catch continue;
        prop_chain.append(ctx.allocator, call) catch return;
    }

    // Check if we need a temp variable (for > 10 defineProperty calls)
    const need_temp = prop_chain.items.len > 10;
    var temp_name: ?[]const u8 = null;

    if (need_temp) {
        temp_name = generateTempName(ctx, idx) catch null;
    }

    if (need_temp and temp_name != null) {
        // Pattern: (_obj = {leading}, defineProperty(defineProperty(..._obj...), ...), defineProperty(defineProperty(..._obj...), ...), _obj)
        // Actually looking at spec/multiple more carefully:
        // var manyProps = (_manyProps = {}, defineProperty(defineProperty(... _manyProps ..., ...), ...), defineProperty(defineProperty(... _manyProps ..., ...), ...), _manyProps)
        // The temp var pattern: groups of 10 defineProperty calls, each group chains from the temp var.
        try buildTempVarChain(ctx, &buf, temp_name.?, literal_props.items, prop_chain.items);
    } else {
        // Simple chain without temp variable
        try buildSimpleChain(ctx, &buf, literal_props.items, prop_chain.items);
    }

    ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch {};
}

const PropCall = struct {
    kind: enum { define_property, define_accessor },
    accessor_kind: ?[]const u8 = null, // "get" or "set"
    key: []const u8,
    value: []const u8,
};

fn buildPropCall(ctx: *TransformContext, info: PropInfo) !PropCall {
    switch (info.kind) {
        .computed => {
            const data = ctx.nodeData(info.node);
            const key_src = getNodeSource(ctx, data.binary.lhs);
            const val_src = getNodeSource(ctx, data.binary.rhs);
            return .{ .kind = .define_property, .key = key_src, .value = val_src };
        },
        .computed_method => {
            const data = ctx.nodeData(info.node);
            const extra_idx = @intFromEnum(data.extra);
            const key_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const key_src = getNodeSource(ctx, key_node);
            const func_src = try buildMethodFunction(ctx, info.node, extra_idx);
            return .{ .kind = .define_property, .key = key_src, .value = func_src };
        },
        .method => {
            // Non-computed method after computed properties
            const data = ctx.nodeData(info.node);
            const extra_idx = @intFromEnum(data.extra);
            const key_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const key_src = getNodeSource(ctx, key_node);
            const func_src = try buildMethodFunction(ctx, info.node, extra_idx);
            const quoted_key = quoteIfNeeded(ctx.allocator, key_src);
            return .{ .kind = .define_property, .key = quoted_key, .value = func_src };
        },
        .getter_computed, .setter_computed => {
            const data = ctx.nodeData(info.node);
            const extra_idx = @intFromEnum(data.extra);
            const computed_key: NodeIndex = if (extra_idx + 4 < ctx.ast.extra_data.items.len)
                @enumFromInt(ctx.ast.extra_data.items[extra_idx + 4])
            else
                .none;
            const key_src = if (computed_key != .none) getNodeSource(ctx, computed_key) else "";
            const func_src = try buildGetterSetterFunction(ctx, info.node, extra_idx);
            const accessor_kind: []const u8 = if (info.kind == .getter_computed) "get" else "set";
            return .{ .kind = .define_accessor, .accessor_kind = accessor_kind, .key = key_src, .value = func_src };
        },
        .getter, .setter => {
            // Non-computed getter/setter after computed properties
            const mt = ctx.mainToken(info.node);
            const key_src = ctx.ast.tokenSlice(mt);
            const data = ctx.nodeData(info.node);
            const extra_idx = @intFromEnum(data.extra);
            const func_src = try buildGetterSetterFunction(ctx, info.node, extra_idx);
            const accessor_kind: []const u8 = if (info.kind == .getter) "get" else "set";
            const quoted_key = quoteIfNeeded(ctx.allocator, key_src);
            return .{ .kind = .define_accessor, .accessor_kind = accessor_kind, .key = quoted_key, .value = func_src };
        },
        .proto_shorthand => {
            // __proto__ shorthand -> defineProperty({}, "__proto__", __proto__)
            const data = ctx.nodeData(info.node);
            const val_src = getNodeSource(ctx, data.unary);
            return .{ .kind = .define_property, .key = "\"__proto__\"", .value = val_src };
        },
        .proto_method => {
            // __proto__() method -> defineProperty({}, "__proto__", function() {})
            const data = ctx.nodeData(info.node);
            const extra_idx = @intFromEnum(data.extra);
            const func_src = try buildMethodFunction(ctx, info.node, extra_idx);
            return .{ .kind = .define_property, .key = "\"__proto__\"", .value = func_src };
        },
        .normal => {
            // Normal property after computed — treat as defineProperty with quoted key
            const data = ctx.nodeData(info.node);
            const tag = ctx.nodeTag(info.node);
            if (tag == .property) {
                const key_src = getNodeSource(ctx, data.binary.lhs);
                const val_src = getNodeSource(ctx, data.binary.rhs);
                // Key might be an identifier or string literal
                const quoted_key = quoteKeyIfNeeded(ctx, data.binary.lhs, key_src);
                return .{ .kind = .define_property, .key = quoted_key, .value = val_src };
            } else if (tag == .shorthand_property) {
                const val_src = getNodeSource(ctx, data.unary);
                const quoted_key = quoteIfNeeded(ctx.allocator, val_src);
                return .{ .kind = .define_property, .key = quoted_key, .value = val_src };
            }
            return error.UnsupportedProperty;
        },
    }
}

fn buildMethodFunction(ctx: *TransformContext, node: NodeIndex, extra_idx: u32) ![]const u8 {
    _ = node;
    // Extract params and body from method
    const params_start = ctx.ast.extra_data.items[extra_idx + 1];
    const params_end = ctx.ast.extra_data.items[extra_idx + 2];
    const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
    const flags = if (extra_idx + 4 < ctx.ast.extra_data.items.len)
        ctx.ast.extra_data.items[extra_idx + 4]
    else
        0;
    const is_generator = (flags & 1) != 0;
    const is_async = (flags & 2) != 0;

    // Build: function(params) { body } or async function*(params) { body }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (is_async) try buf.appendSlice(ctx.allocator, "async ");
    try buf.appendSlice(ctx.allocator, "function");
    if (is_generator) try buf.append(ctx.allocator, '*');
    try buf.appendSlice(ctx.allocator, " (");

    // Emit parameters
    try emitParamList(ctx, &buf, params_start, params_end);
    try buf.appendSlice(ctx.allocator, ") ");

    // Emit body with de-indented formatting
    const body_src = getNodeSource(ctx, body);
    const deindented = deindentBlock(ctx.allocator, body_src) catch body_src;
    try buf.appendSlice(ctx.allocator, deindented);

    return buf.items;
}

fn buildGetterSetterFunction(ctx: *TransformContext, node: NodeIndex, extra_idx: u32) ![]const u8 {
    _ = node;
    const params_start = ctx.ast.extra_data.items[extra_idx];
    const params_end = ctx.ast.extra_data.items[extra_idx + 1];
    const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "function (");
    try emitParamList(ctx, &buf, params_start, params_end);
    try buf.appendSlice(ctx.allocator, ") ");
    const body_src = getNodeSource(ctx, body);
    const deindented = deindentBlock(ctx.allocator, body_src) catch body_src;
    try buf.appendSlice(ctx.allocator, deindented);

    return buf.items;
}

fn emitParamList(ctx: *TransformContext, buf: *std.ArrayListUnmanaged(u8), params_start: u32, params_end: u32) !void {
    if (params_start >= params_end) return;
    var first = true;
    for (ctx.ast.extra_data.items[params_start..params_end]) |entry| {
        const param_node: NodeIndex = @enumFromInt(entry);
        if (param_node == .none) continue;
        if (!first) try buf.appendSlice(ctx.allocator, ", ");
        first = false;
        const param_src = getNodeSource(ctx, param_node);
        try buf.appendSlice(ctx.allocator, param_src);
    }
}

fn buildSimpleChain(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    literal_props: []const []const u8,
    prop_chain: []const PropCall,
) !void {
    // Build the innermost: the literal object or {}
    // Then wrap with defineProperty/defineAccessor calls

    // Build from inside out:
    // innermost: literal object
    // then: babelHelpers.defineProperty(inner, key, val)
    // or: babelHelpers.defineAccessor("get", inner, key, fn)

    // Start with literal object
    var inner: std.ArrayListUnmanaged(u8) = .empty;
    if (literal_props.len > 0) {
        try inner.appendSlice(ctx.allocator, "{\n");
        for (literal_props, 0..) |prop, j| {
            try inner.appendSlice(ctx.allocator, "  ");
            try inner.appendSlice(ctx.allocator, prop);
            if (j < literal_props.len - 1) {
                try inner.appendSlice(ctx.allocator, ",");
            }
            try inner.appendSlice(ctx.allocator, "\n");
        }
        try inner.appendSlice(ctx.allocator, "}");
    } else {
        try inner.appendSlice(ctx.allocator, "{}");
    }

    // Chain defineProperty/defineAccessor calls
    for (prop_chain) |call| {
        var outer: std.ArrayListUnmanaged(u8) = .empty;
        switch (call.kind) {
            .define_property => {
                try outer.appendSlice(ctx.allocator, "babelHelpers.defineProperty(");
                try outer.appendSlice(ctx.allocator, inner.items);
                try outer.appendSlice(ctx.allocator, ", ");
                try outer.appendSlice(ctx.allocator, call.key);
                try outer.appendSlice(ctx.allocator, ", ");
                try outer.appendSlice(ctx.allocator, call.value);
                try outer.append(ctx.allocator, ')');
            },
            .define_accessor => {
                try outer.appendSlice(ctx.allocator, "babelHelpers.defineAccessor(\"");
                try outer.appendSlice(ctx.allocator, call.accessor_kind.?);
                try outer.appendSlice(ctx.allocator, "\", ");
                try outer.appendSlice(ctx.allocator, inner.items);
                try outer.appendSlice(ctx.allocator, ", ");
                try outer.appendSlice(ctx.allocator, call.key);
                try outer.appendSlice(ctx.allocator, ", ");
                try outer.appendSlice(ctx.allocator, call.value);
                try outer.append(ctx.allocator, ')');
            },
        }
        inner = outer;
    }

    try buf.appendSlice(ctx.allocator, inner.items);
}

fn buildTempVarChain(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    temp_name: []const u8,
    literal_props: []const []const u8,
    prop_chain: []const PropCall,
) !void {
    // Pattern: (_obj = {literal}, defineProperty(defineProperty(_obj, ...), ...), ..., _obj)
    // Groups of up to 10 defineProperty calls
    try buf.append(ctx.allocator, '(');
    try buf.appendSlice(ctx.allocator, temp_name);
    try buf.appendSlice(ctx.allocator, " = ");

    if (literal_props.len > 0) {
        try buf.appendSlice(ctx.allocator, "{\n");
        for (literal_props, 0..) |prop, j| {
            try buf.appendSlice(ctx.allocator, "  ");
            try buf.appendSlice(ctx.allocator, prop);
            if (j < literal_props.len - 1) try buf.appendSlice(ctx.allocator, ",");
            try buf.appendSlice(ctx.allocator, "\n");
        }
        try buf.append(ctx.allocator, '}');
    } else {
        try buf.appendSlice(ctx.allocator, "{}");
    }

    // Group into batches of 10
    var pos: usize = 0;
    while (pos < prop_chain.len) {
        const batch_end = @min(pos + 10, prop_chain.len);
        const batch = prop_chain[pos..batch_end];

        try buf.appendSlice(ctx.allocator, ", ");

        // Build chain for this batch starting from temp_name
        var inner: std.ArrayListUnmanaged(u8) = .empty;
        try inner.appendSlice(ctx.allocator, temp_name);

        for (batch) |call| {
            var outer: std.ArrayListUnmanaged(u8) = .empty;
            switch (call.kind) {
                .define_property => {
                    try outer.appendSlice(ctx.allocator, "babelHelpers.defineProperty(");
                    try outer.appendSlice(ctx.allocator, inner.items);
                    try outer.appendSlice(ctx.allocator, ", ");
                    try outer.appendSlice(ctx.allocator, call.key);
                    try outer.appendSlice(ctx.allocator, ", ");
                    try outer.appendSlice(ctx.allocator, call.value);
                    try outer.append(ctx.allocator, ')');
                },
                .define_accessor => {
                    try outer.appendSlice(ctx.allocator, "babelHelpers.defineAccessor(\"");
                    try outer.appendSlice(ctx.allocator, call.accessor_kind.?);
                    try outer.appendSlice(ctx.allocator, "\", ");
                    try outer.appendSlice(ctx.allocator, inner.items);
                    try outer.appendSlice(ctx.allocator, ", ");
                    try outer.appendSlice(ctx.allocator, call.key);
                    try outer.appendSlice(ctx.allocator, ", ");
                    try outer.appendSlice(ctx.allocator, call.value);
                    try outer.append(ctx.allocator, ')');
                },
            }
            inner = outer;
        }

        try buf.appendSlice(ctx.allocator, inner.items);
        pos = batch_end;
    }

    try buf.append(ctx.allocator, ')');
}

// ── Set mode (assumption: setComputedProperties) ────────────────────

fn handleSetMode(ctx: *TransformContext, idx: NodeIndex, i: u32, items: []const u32) !void {
    // Check if we have ONLY a single accessor — use spec mode for that case
    if (items.len == 1) {
        const node: NodeIndex = @enumFromInt(items[0]);
        const info = classifyProp(ctx, node);
        if (info.kind == .getter_computed or info.kind == .setter_computed or
            info.kind == .getter or info.kind == .setter)
        {
            // Single accessor — use spec mode (defineAccessor)
            var prop_chain: std.ArrayListUnmanaged(PropCall) = .empty;
            const call = buildPropCall(ctx, info) catch return;
            prop_chain.append(ctx.allocator, call) catch return;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buildSimpleChain(ctx, &buf, &.{}, prop_chain.items);
            ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch {};
            return;
        }
    }

    // Need a temp variable
    const temp_name = generateTempName(ctx, idx) catch return;

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    // Find the first computed/special property
    var first_special: usize = items.len;
    for (items, 0..) |item, j| {
        const node: NodeIndex = @enumFromInt(item);
        const info = classifyProp(ctx, node);
        if (isComputedOrSpecial(info.kind)) {
            first_special = j;
            break;
        }
    }

    // Build: (_obj = {leading_normals}, _obj[key1] = val1, ..., _obj)
    try buf.append(ctx.allocator, '(');
    try buf.appendSlice(ctx.allocator, temp_name);
    try buf.appendSlice(ctx.allocator, " = ");

    // Leading normal properties as literal object
    if (first_special > 0) {
        try buf.appendSlice(ctx.allocator, "{\n");
        for (items[0..first_special], 0..) |item, j| {
            const node: NodeIndex = @enumFromInt(item);
            const prop_src = getNodeSource(ctx, node);
            try buf.appendSlice(ctx.allocator, "  ");
            try buf.appendSlice(ctx.allocator, prop_src);
            if (j < first_special - 1) try buf.appendSlice(ctx.allocator, ",");
            try buf.appendSlice(ctx.allocator, "\n");
        }
        try buf.append(ctx.allocator, '}');
    } else {
        try buf.appendSlice(ctx.allocator, "{}");
    }

    // Remaining properties as assignments
    for (items[first_special..]) |item| {
        const node: NodeIndex = @enumFromInt(item);
        const info = classifyProp(ctx, node);

        try buf.appendSlice(ctx.allocator, ", ");

        switch (info.kind) {
            .computed => {
                const data = ctx.nodeData(node);
                const key_src = getNodeSource(ctx, data.binary.lhs);
                const val_src = getNodeSource(ctx, data.binary.rhs);
                try buf.appendSlice(ctx.allocator, temp_name);
                try buf.append(ctx.allocator, '[');
                try buf.appendSlice(ctx.allocator, key_src);
                try buf.appendSlice(ctx.allocator, "] = ");
                try buf.appendSlice(ctx.allocator, val_src);
            },
            .computed_method => {
                const data = ctx.nodeData(node);
                const extra_idx = @intFromEnum(data.extra);
                const key_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
                const key_src = getNodeSource(ctx, key_node);
                const func_src = buildMethodFunction(ctx, node, extra_idx) catch continue;
                try buf.appendSlice(ctx.allocator, temp_name);
                try buf.append(ctx.allocator, '[');
                try buf.appendSlice(ctx.allocator, key_src);
                try buf.appendSlice(ctx.allocator, "] = ");
                try buf.appendSlice(ctx.allocator, func_src);
            },
            .method => {
                const data = ctx.nodeData(node);
                const extra_idx = @intFromEnum(data.extra);
                const key_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
                const key_src = getNodeSource(ctx, key_node);
                const func_src = buildMethodFunction(ctx, node, extra_idx) catch continue;
                try buf.appendSlice(ctx.allocator, temp_name);
                try buf.append(ctx.allocator, '.');
                try buf.appendSlice(ctx.allocator, key_src);
                try buf.appendSlice(ctx.allocator, " = ");
                try buf.appendSlice(ctx.allocator, func_src);
            },
            .getter_computed, .setter_computed, .getter, .setter => {
                const data = ctx.nodeData(node);
                const extra_idx = @intFromEnum(data.extra);
                const acc_kind: []const u8 = if (info.kind == .getter_computed or info.kind == .getter) "get" else "set";
                const key_src = blk: {
                    if (info.kind == .getter_computed or info.kind == .setter_computed) {
                        const computed_key: NodeIndex = if (extra_idx + 4 < ctx.ast.extra_data.items.len)
                            @enumFromInt(ctx.ast.extra_data.items[extra_idx + 4])
                        else
                            .none;
                        break :blk if (computed_key != .none) getNodeSource(ctx, computed_key) else "";
                    } else {
                        const mt = ctx.mainToken(node);
                        const name = ctx.ast.tokenSlice(mt);
                        break :blk quoteIfNeeded(ctx.allocator, name);
                    }
                };
                const func_src = buildGetterSetterFunction(ctx, node, extra_idx) catch continue;
                try buf.appendSlice(ctx.allocator, "babelHelpers.defineAccessor(\"");
                try buf.appendSlice(ctx.allocator, acc_kind);
                try buf.appendSlice(ctx.allocator, "\", ");
                try buf.appendSlice(ctx.allocator, temp_name);
                try buf.appendSlice(ctx.allocator, ", ");
                try buf.appendSlice(ctx.allocator, key_src);
                try buf.appendSlice(ctx.allocator, ", ");
                try buf.appendSlice(ctx.allocator, func_src);
                try buf.append(ctx.allocator, ')');
            },
            .proto_shorthand => {
                const data = ctx.nodeData(node);
                const val_src = getNodeSource(ctx, data.unary);
                try buf.appendSlice(ctx.allocator, temp_name);
                try buf.appendSlice(ctx.allocator, "[\"__proto__\"] = ");
                try buf.appendSlice(ctx.allocator, val_src);
            },
            .proto_method => {
                const data = ctx.nodeData(node);
                const extra_idx = @intFromEnum(data.extra);
                const func_src = buildMethodFunction(ctx, node, extra_idx) catch continue;
                try buf.appendSlice(ctx.allocator, temp_name);
                try buf.appendSlice(ctx.allocator, "[\"__proto__\"] = ");
                try buf.appendSlice(ctx.allocator, func_src);
            },
            .normal => {
                // Normal property after computed — use dot notation
                const data = ctx.nodeData(node);
                const tag = ctx.nodeTag(node);
                if (tag == .property) {
                    const key_src = getNodeSource(ctx, data.binary.lhs);
                    const val_src = getNodeSource(ctx, data.binary.rhs);
                    try buf.appendSlice(ctx.allocator, temp_name);
                    try buf.append(ctx.allocator, '.');
                    try buf.appendSlice(ctx.allocator, key_src);
                    try buf.appendSlice(ctx.allocator, " = ");
                    try buf.appendSlice(ctx.allocator, val_src);
                } else if (tag == .shorthand_property) {
                    const val_src = getNodeSource(ctx, data.unary);
                    try buf.appendSlice(ctx.allocator, temp_name);
                    try buf.append(ctx.allocator, '.');
                    try buf.appendSlice(ctx.allocator, val_src);
                    try buf.appendSlice(ctx.allocator, " = ");
                    try buf.appendSlice(ctx.allocator, val_src);
                }
            },
        }
    }

    try buf.appendSlice(ctx.allocator, ", ");
    try buf.appendSlice(ctx.allocator, temp_name);
    try buf.append(ctx.allocator, ')');

    ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch {};
}

// ── Temp variable generation ────────────────────────────────────────

var g_temp_counter: u32 = 0;
var g_temp_names: std.ArrayListUnmanaged([]const u8) = .empty;

pub fn resetState() void {
    g_temp_counter = 0;
    g_temp_names = .empty;
}

fn generateTempName(ctx: *TransformContext, idx: NodeIndex) ![]const u8 {
    // Derive a name from the context (e.g., var foo = {...} -> _foo)
    const prefix = deriveTempPrefix(ctx, idx);

    g_temp_counter += 1;
    const name = if (g_temp_counter == 1)
        try std.fmt.allocPrint(ctx.allocator, "_{s}", .{prefix})
    else
        try std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ prefix, g_temp_counter });
    g_temp_names.append(ctx.allocator, name) catch {};
    return name;
}

/// Derive a temp variable prefix from the object expression's context.
fn deriveTempPrefix(ctx: *TransformContext, idx: NodeIndex) []const u8 {
    // Look at source before the object literal to find: `var foo =`, `foo =`, `foo(`, etc.
    const start = getNodeStart(ctx, idx);
    if (start == 0) return "obj";

    // Scan backwards past whitespace and `=` to find identifier
    var pos: usize = start;

    // Skip whitespace before `{`
    while (pos > 0) {
        pos -= 1;
        const ch = ctx.ast.source[pos];
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') break;
    }
    if (pos == 0) return "obj";

    // Check for `=` (assignment context)
    if (ctx.ast.source[pos] == '=') {
        if (pos > 0 and ctx.ast.source[pos - 1] == '=') return "obj"; // ==
        pos -= 1;
        // Skip whitespace
        while (pos > 0) {
            if (ctx.ast.source[pos] != ' ' and ctx.ast.source[pos] != '\t') break;
            pos -= 1;
        }
        // Read identifier backwards
        const end_pos = pos + 1;
        while (pos > 0 and isIdentChar(ctx.ast.source[pos])) {
            pos -= 1;
        }
        if (!isIdentChar(ctx.ast.source[pos])) pos += 1;
        if (pos < end_pos) {
            return ctx.ast.source[pos..end_pos];
        }
    }

    // Check for `(` (function argument context)
    if (ctx.ast.source[pos] == '(' or ctx.ast.source[pos] == ',') {
        if (ctx.ast.source[pos] == '(') {
            pos -= 1;
            // Skip whitespace
            while (pos > 0 and (ctx.ast.source[pos] == ' ' or ctx.ast.source[pos] == '\t')) {
                pos -= 1;
            }
            // Read function name backwards
            const end_pos = pos + 1;
            while (pos > 0 and isIdentChar(ctx.ast.source[pos])) {
                pos -= 1;
            }
            if (!isIdentChar(ctx.ast.source[pos])) pos += 1;
            if (pos < end_pos) {
                return ctx.ast.source[pos..end_pos];
            }
        }
    }

    return "obj";
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// Get temp variable declarations to prepend.
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

// ── Helpers ────────���────────────────────────────────────────────────

fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return ctx.ast.source[start..end];
}

fn getNodeStart(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ctx.ast.node_start_overrides.get(ni)) |override| return override;

    const tag = ctx.ast.nodes.items(.tag)[ni];
    const data = ctx.ast.nodes.items(.data)[ni];

    switch (tag) {
        .call_expr, .optional_call_expr => {
            const extra_idx_inner = @intFromEnum(data.extra);
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx_inner]);
            return getNodeStart(ctx, callee);
        },
        .member_expr,
        .computed_member_expr,
        .optional_chain_expr,
        .optional_computed_member_expr,
        => return getNodeStart(ctx, data.binary.lhs),
        .binary_expr, .logical_expr, .assignment_expr => return getNodeStart(ctx, data.binary.lhs),
        .conditional_expr => return getNodeStart(ctx, data.binary.lhs),
        .sequence_expr => {
            const extra_idx_inner = @intFromEnum(data.extra);
            const range_start = ctx.ast.extra_data.items[extra_idx_inner];
            const range_end = ctx.ast.extra_data.items[extra_idx_inner + 1];
            if (range_start < range_end) {
                const first: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_start]);
                return getNodeStart(ctx, first);
            }
        },
        .ts_as_expression, .ts_satisfies_expression => return getNodeStart(ctx, data.binary.lhs),
        .ts_non_null_expression => return getNodeStart(ctx, data.unary),
        else => {},
    }

    const mt = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(mt)];
}

fn getIdentName(ctx: *TransformContext, node: NodeIndex) ?[]const u8 {
    if (node == .none) return null;
    const tag = ctx.nodeTag(node);
    if (tag != .identifier) return null;
    const mt = ctx.mainToken(node);
    return ctx.ast.tokenSlice(mt);
}

/// De-indent a block statement and format with Babel-style 2-space indentation.
/// Handles both multi-line and single-line blocks.
fn deindentBlock(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    if (src.len == 0) return src;

    // Check if this is a single-line block: { content }
    const has_newline = std.mem.indexOf(u8, src, "\n") != null;
    if (!has_newline) {
        // Single-line block like `{ return "heh"; }`
        // Expand to multi-line:
        // {\n  content\n}
        const trimmed = std.mem.trim(u8, src, " \t");
        if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
            const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
            if (inner.len > 0) {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                try buf.appendSlice(allocator, "{\n  ");
                try buf.appendSlice(allocator, inner);
                try buf.appendSlice(allocator, "\n}");
                return buf.items;
            }
        }
        return src;
    }

    // Multi-line block — find minimum indentation of content lines
    var min_indent: usize = std.math.maxInt(usize);
    var iter_pos: usize = 0;
    while (iter_pos < src.len) {
        const line_start = iter_pos;
        while (iter_pos < src.len and src[iter_pos] != '\n') : (iter_pos += 1) {}
        const line_end = iter_pos;
        if (iter_pos < src.len) iter_pos += 1;

        const line = src[line_start..line_end];
        const trimmed_line = std.mem.trimStart(u8, line, " \t");
        if (trimmed_line.len == 0) continue;
        if (trimmed_line[0] == '{' or trimmed_line[0] == '}') continue;

        var indent: usize = 0;
        for (line) |ch| {
            if (ch == ' ') {
                indent += 1;
            } else if (ch == '\t') {
                indent += 2;
            } else break;
        }
        min_indent = @min(min_indent, indent);
    }

    if (min_indent == std.math.maxInt(usize)) min_indent = 0;
    // We want content lines to have 2-space indent, so strip (min_indent - 2) spaces
    const base_indent = if (min_indent >= 2) min_indent - 2 else 0;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    iter_pos = 0;
    var first_line = true;
    while (iter_pos < src.len) {
        const line_start = iter_pos;
        while (iter_pos < src.len and src[iter_pos] != '\n') : (iter_pos += 1) {}
        const line_end = iter_pos;
        if (iter_pos < src.len) iter_pos += 1;

        const line = src[line_start..line_end];

        if (first_line) {
            try buf.appendSlice(allocator, std.mem.trimStart(u8, line, " \t"));
            try buf.append(allocator, '\n');
            first_line = false;
            continue;
        }

        const trimmed_line = std.mem.trimStart(u8, line, " \t");
        if (trimmed_line.len > 0 and trimmed_line[0] == '}' and iter_pos >= src.len) {
            try buf.appendSlice(allocator, trimmed_line);
            continue;
        }

        // Strip base_indent spaces
        var skip: usize = 0;
        var stripped: usize = 0;
        while (skip < line.len and stripped < base_indent) {
            if (line[skip] == ' ') {
                stripped += 1;
                skip += 1;
            } else if (line[skip] == '\t') {
                stripped += 2;
                skip += 1;
            } else break;
        }
        try buf.appendSlice(allocator, line[skip..]);
        try buf.append(allocator, '\n');
    }

    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n' and
        (src.len == 0 or src[src.len - 1] != '\n'))
    {
        _ = buf.pop();
    }

    return buf.items;
}

fn quoteKeyIfNeeded(ctx: *TransformContext, key_node: NodeIndex, key_src: []const u8) []const u8 {
    if (key_node == .none) return key_src;
    const tag = ctx.nodeTag(key_node);
    if (tag == .string_literal) return key_src; // Already quoted
    if (tag == .numeric_literal) return key_src; // Numbers don't need quoting
    // Identifier keys need quoting
    return std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{key_src}) catch key_src;
}

/// Quote a key string if it's not already a string literal or number.
fn quoteIfNeeded(allocator: std.mem.Allocator, key: []const u8) []const u8 {
    if (key.len == 0) return key;
    // Already quoted (string literal)?
    if (key[0] == '"' or key[0] == '\'') return key;
    // Numeric?
    if (key[0] >= '0' and key[0] <= '9') return key;
    // Identifier — quote it
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{key}) catch key;
}
