const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const Allocator = std.mem.Allocator;

/// Replace a node in the AST with another node (copies tag, main_token, data, end_offset).
pub fn replaceNode(ast: *Ast, target: NodeIndex, replacement: NodeIndex) void {
    const t = @intFromEnum(target);
    const r = @intFromEnum(replacement);
    ast.nodes.items(.tag)[t] = ast.nodes.items(.tag)[r];
    ast.nodes.items(.main_token)[t] = ast.nodes.items(.main_token)[r];
    ast.nodes.items(.data)[t] = ast.nodes.items(.data)[r];
    ast.nodes.items(.end_offset)[t] = ast.nodes.items(.end_offset)[r];
}

/// Remove a node by setting its tag to .removed — codegen emits nothing.
pub fn removeNode(ast: *Ast, target: NodeIndex) void {
    const t = @intFromEnum(target);
    ast.nodes.items(.tag)[t] = .removed;
}

/// Set the tag of a node.
pub fn setNodeTag(ast: *Ast, target: NodeIndex, tag: Node.Tag) void {
    const t = @intFromEnum(target);
    ast.nodes.items(.tag)[t] = tag;
}

/// Set the data of a node.
pub fn setNodeData(ast: *Ast, target: NodeIndex, data: Node.Data) void {
    const t = @intFromEnum(target);
    ast.nodes.items(.data)[t] = data;
}

/// Append a new node to the AST and return its index.
pub fn addNewNode(ast: *Ast, allocator: Allocator, node: Node) !NodeIndex {
    const idx: u32 = @intCast(ast.nodes.len);
    try ast.nodes.append(allocator, node);
    return @enumFromInt(idx);
}

/// Append a single u32 value to extra_data and return its index.
pub fn addExtra(ast: *Ast, allocator: Allocator, value: u32) !u32 {
    const idx: u32 = @intCast(ast.extra_data.items.len);
    try ast.extra_data.append(allocator, value);
    return idx;
}

/// Append a slice of u32 values to extra_data and return the start index.
pub fn addExtraSlice(ast: *Ast, allocator: Allocator, values: []const u32) !u32 {
    const idx: u32 = @intCast(ast.extra_data.items.len);
    try ast.extra_data.appendSlice(allocator, values);
    return idx;
}

/// Remove a node from an extra_data range by setting it to @intFromEnum(NodeIndex.none).
/// `start` and `end` define the range in extra_data; `remove_idx` is the
/// extra_data index within that range to nullify.
pub fn removeFromRange(ast: *Ast, start: u32, end: u32, remove_idx: u32) void {
    if (remove_idx >= start and remove_idx < end) {
        ast.extra_data.items[remove_idx] = @intFromEnum(NodeIndex.none);
    }
}
