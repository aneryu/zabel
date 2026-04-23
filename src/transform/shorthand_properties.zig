const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub fn createPass() Pass {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.shorthand_property));
    filter.set(@intFromEnum(Node.Tag.method_definition));
    return .{
        .name = "shorthand_properties",
        .node_filter = filter,
        .enter = enterNode,
        .priority = 20,
    };
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .shorthand_property => handleShorthandProperty(idx, ctx),
        .method_definition => handleMethodDefinition(idx, ctx),
        else => {},
    }
    return .continue_traversal;
}

/// Transform `{ x }` → `{ x: x }` (or `{ ["__proto__"]: __proto__ }` for __proto__)
fn handleShorthandProperty(idx: NodeIndex, ctx: *TransformContext) void {
    const i = @intFromEnum(idx);
    const data = ctx.nodeData(idx);
    const value_node = data.unary;
    if (value_node == .none) return;

    // Get the identifier name from the value node
    const name = getNodeName(ctx, value_node) orelse return;

    if (std.mem.eql(u8, name, "__proto__")) {
        // __proto__ special case: use computed property syntax ["__proto__"]: __proto__
        const replacement = std.fmt.allocPrint(ctx.allocator, "[\"__proto__\"]: {s}", .{name}) catch return;
        ctx.ast.replacement_source.put(ctx.allocator, i, replacement) catch return;
    } else {
        // Normal case: mutate shorthand_property → property in-place.
        // data.unary (= binary.lhs) already points to the value identifier.
        // Set binary.rhs to the same node so codegen emits `key: value`.
        ctx.ast.nodes.items(.tag)[i] = .property;
        ctx.ast.nodes.items(.data)[i] = .{ .binary = .{
            .lhs = value_node,
            .rhs = value_node,
        } };
    }
}

/// Transform `{ method() {} }` → `{ method: function() {} }`
/// Getters/setters are NOT transformed (Babel leaves them as-is).
fn handleMethodDefinition(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);

    // Layout: extra[0]=key, [1]=params_start, [2]=params_end, [3]=body, [4]=flags
    const key_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const method_flags = if (extra_idx + 4 < ctx.ast.extra_data.items.len)
        ctx.ast.extra_data.items[extra_idx + 4]
    else
        0;
    const is_generator = (method_flags & 1) != 0;
    const is_async = (method_flags & 2) != 0;

    // Get the key name
    const key_name = getNodeName(ctx, key_node) orelse return;

    // Get source text for the portion from '(' to end of body (inclusive)
    // We need to find the '(' after the key in the source
    const node_i = @intFromEnum(idx);
    const end_off = ctx.ast.nodes.items(.end_offset)[node_i];
    if (end_off == 0) return;

    // Find the key's end position in source
    const key_i = @intFromEnum(key_node);
    const key_end = ctx.ast.nodes.items(.end_offset)[key_i];
    if (key_end == 0) return;

    // Scan from key end to find '(' — skip whitespace and type parameters
    var pos = key_end;
    // Skip past possible type parameter angle brackets (Flow/TS annotations)
    if (pos < ctx.ast.source.len and ctx.ast.source[pos] == '<') {
        var depth: u32 = 1;
        pos += 1;
        while (pos < ctx.ast.source.len and depth > 0) : (pos += 1) {
            if (ctx.ast.source[pos] == '<') depth += 1;
            if (ctx.ast.source[pos] == '>') depth -= 1;
        }
    }
    while (pos < ctx.ast.source.len and ctx.ast.source[pos] != '(') : (pos += 1) {}

    if (pos >= ctx.ast.source.len) return;

    // Extract from '(' to end of node — this is the params + body
    // We need up to the end of the source region for this node.
    // end_off is a byte offset in the source.
    const params_and_body = ctx.ast.source[pos..end_off];

    // Build the key prefix
    const key_prefix = if (std.mem.eql(u8, key_name, "__proto__"))
        "[\"__proto__\"]"
    else
        key_name;

    // Build: `key: function(params) { body }` or `key: async function*(params) { body }`
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, key_prefix) catch return;
    buf.appendSlice(ctx.allocator, ": ") catch return;
    if (is_async) buf.appendSlice(ctx.allocator, "async ") catch return;
    buf.appendSlice(ctx.allocator, "function") catch return;
    if (is_generator) buf.append(ctx.allocator, '*') catch return;
    // Babel inserts a space between `function` and `(` — `function (...)`
    buf.append(ctx.allocator, ' ') catch return;
    buf.appendSlice(ctx.allocator, params_and_body) catch return;

    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), buf.items) catch return;
}

fn getNodeName(ctx: *TransformContext, node: NodeIndex) ?[]const u8 {
    if (node == .none) return null;
    const token = ctx.mainToken(node);
    return ctx.tokenSlice(token);
}
