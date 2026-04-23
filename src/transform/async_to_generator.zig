const std = @import("std");
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub const Config = struct {};

var g_ref_counter: u32 = 0;

pub fn createPass(_: Config) Pass {
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.function_expr));
    filter.set(@intFromEnum(Node.Tag.arrow_function_expr));
    return .{
        .name = "async_to_generator",
        .node_filter = filter,
        .exit = exitNode,
        .priority = 40,
    };
}

pub fn resetState() void {
    g_ref_counter = 0;
}

pub fn canLowerAsyncFunction(ctx: *TransformContext, func_node: NodeIndex) bool {
    const body = getFunctionBody(ctx, func_node) orelse return false;
    return !containsAwaitOutsideNestedFunctions(ctx, body);
}

pub fn renderAsyncToGeneratorWrapperFromFunctionSuffix(
    ctx: *TransformContext,
    binding_name: ?[]const u8,
    function_suffix: []const u8,
) ?[]const u8 {
    if (function_suffix.len == 0 or function_suffix[0] != '(') return null;
    const indented_suffix = indentContinuationLines(ctx, function_suffix, "  ");

    g_ref_counter += 1;
    const ref_name = if (g_ref_counter == 1)
        "_ref"
    else
        std.fmt.allocPrint(ctx.allocator, "_ref{d}", .{g_ref_counter}) catch return null;

    const return_head = if (binding_name) |name|
        if (name.len == 0)
            "function ()"
        else
            std.fmt.allocPrint(ctx.allocator, "function {s}()", .{name}) catch return null
    else
        "function ()";

    return std.fmt.allocPrint(
        ctx.allocator,
        "/*#__PURE__*/function () {{\n  var {s} = babelHelpers.asyncToGenerator(function* {s});\n  return {s} {{\n    return {s}.apply(this, arguments);\n  }};\n}}()",
        .{ ref_name, indented_suffix, return_head, ref_name },
    ) catch null;
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (ctx.nodeTag(idx) != .function_expr) return .continue_traversal;
    if (!isAsyncFunctionExpr(ctx, idx)) return .continue_traversal;
    if (!canLowerAsyncFunction(ctx, idx)) return .continue_traversal;

    const function_src = getNodeSource(ctx, idx);
    const function_suffix = extractAsyncFunctionSuffix(function_src) orelse return .continue_traversal;
    const binding_name = getFunctionExpressionBindingName(ctx, idx);
    const wrapper = renderAsyncToGeneratorWrapperFromFunctionSuffix(ctx, binding_name, function_suffix) orelse
        return .continue_traversal;

    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), wrapper) catch return .continue_traversal;
    ctx.ast.replacement_needs_reindent.put(ctx.allocator, @intFromEnum(idx), {}) catch return .continue_traversal;
    return .continue_traversal;
}

fn isAsyncFunctionExpr(ctx: *TransformContext, node: NodeIndex) bool {
    if (ctx.nodeTag(node) != .function_expr) return false;
    const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
    if (extra_idx + 4 >= ctx.ast.extra_data.items.len) return false;
    const flags = ctx.ast.extra_data.items[extra_idx + 4];
    return (flags & 2) != 0 and (flags & 1) == 0;
}

fn getFunctionBody(ctx: *TransformContext, func_node: NodeIndex) ?NodeIndex {
    const data = ctx.nodeData(func_node);
    return switch (ctx.nodeTag(func_node)) {
        .function_expr,
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        => blk: {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 3 >= ctx.ast.extra_data.items.len) break :blk null;
            break :blk @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
        },
        else => null,
    };
}

fn containsAwaitOutsideNestedFunctions(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    switch (ctx.nodeTag(node)) {
        .await_expr => return true,
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .arrow_function_expr,
        .class_declaration,
        .class_expr,
        .class_body,
        .method_definition,
        .computed_method,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        => return false,
        else => {},
    }

    const children = visitor.getChildren(ctx.ast, node);
    for (children.items[0..children.len]) |child| {
        if (containsAwaitOutsideNestedFunctions(ctx, child)) return true;
    }
    if (children.range_end > children.range_start) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (containsAwaitOutsideNestedFunctions(ctx, @enumFromInt(raw))) return true;
        }
    }
    if (children.range2_end > children.range2_start) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (containsAwaitOutsideNestedFunctions(ctx, @enumFromInt(raw))) return true;
        }
    }
    return false;
}

fn extractAsyncFunctionSuffix(source: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    var pos: usize = 0;

    if (!std.mem.startsWith(u8, trimmed, "async")) return null;
    pos += "async".len;
    while (pos < trimmed.len and std.ascii.isWhitespace(trimmed[pos])) : (pos += 1) {}

    if (pos + "function".len > trimmed.len or !std.mem.eql(u8, trimmed[pos .. pos + "function".len], "function")) {
        return null;
    }
    pos += "function".len;
    while (pos < trimmed.len and (std.ascii.isWhitespace(trimmed[pos]) or trimmed[pos] == '*')) : (pos += 1) {}

    if (pos < trimmed.len and isIdentStart(trimmed[pos])) {
        pos += 1;
        while (pos < trimmed.len and isIdentCont(trimmed[pos])) : (pos += 1) {}
        while (pos < trimmed.len and std.ascii.isWhitespace(trimmed[pos])) : (pos += 1) {}
    }

    if (pos >= trimmed.len or trimmed[pos] != '(') return null;
    return trimmed[pos..];
}

fn getFunctionExpressionBindingName(ctx: *TransformContext, func_idx: NodeIndex) ?[]const u8 {
    const extra_idx = @intFromEnum(ctx.nodeData(func_idx).extra);
    if (extra_idx < ctx.ast.extra_data.items.len) {
        const name_token_raw = ctx.ast.extra_data.items[extra_idx];
        if (name_token_raw != 0) {
            const name_tok: TokenIndex = @enumFromInt(name_token_raw);
            return ctx.tokenSlice(name_tok);
        }
    }

    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    for (tags, 0..) |tag, ni| {
        switch (tag) {
            .declarator, .assignment_expr, .property => {
                const data = datas[ni];
                if (data.binary.rhs != func_idx) continue;
                const lhs = data.binary.lhs;
                if (lhs == .none or tags[@intFromEnum(lhs)] != .identifier) continue;
                return ctx.tokenSlice(ctx.mainToken(lhs));
            },
            else => {},
        }
    }
    return null;
}

fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;
    const start = ctx.ast.tokens.items(.start)[@intFromEnum(ctx.mainToken(node))];
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return ctx.ast.source[start..end];
}

fn indentContinuationLines(ctx: *TransformContext, src: []const u8, indent: []const u8) []const u8 {
    if (src.len == 0 or indent.len == 0 or std.mem.indexOfScalar(u8, src, '\n') == null) return src;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var cursor: usize = 0;
    var first_line = true;
    while (cursor < src.len) {
        const nl_rel = std.mem.indexOfScalar(u8, src[cursor..], '\n') orelse {
            if (!first_line) buf.appendSlice(ctx.allocator, indent) catch return src;
            buf.appendSlice(ctx.allocator, src[cursor..]) catch return src;
            return buf.items;
        };
        if (!first_line) buf.appendSlice(ctx.allocator, indent) catch return src;
        buf.appendSlice(ctx.allocator, src[cursor .. cursor + nl_rel + 1]) catch return src;
        cursor += nl_rel + 1;
        first_line = false;
    }
    return buf.items;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}
