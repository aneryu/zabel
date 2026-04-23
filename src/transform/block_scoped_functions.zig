const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");
const async_to_generator = @import("async_to_generator.zig");
const regenerator = @import("regenerator.zig");
var g_claimed_names: std.StringHashMapUnmanaged(void) = .empty;

pub const Config = struct {
    followed_by_block_scoping: bool = false,
    lower_async_to_generator: bool = false,
    lower_regenerator: bool = false,
    lower_async_generator_functions: bool = false,
};

var g_config: Config = .{};

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    // We need to visit block statements and switch statements to find
    // function declarations inside them
    filter.set(@intFromEnum(Node.Tag.block_statement));
    filter.set(@intFromEnum(Node.Tag.switch_statement));
    return .{
        .name = "block_scoped_functions",
        .node_filter = filter,
        .enter = enterNode,
        .priority = 25, // Run before block-scoping (30)
    };
}

pub fn resetState() void {
    g_claimed_names = .{};
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .block_statement => handleBlock(idx, ctx),
        .switch_statement => handleSwitch(idx, ctx),
        else => {},
    }
    return .continue_traversal;
}

/// Check if a block statement is a function body (the direct body of a function/arrow/program).
/// Function declarations at the top level of a function body don't need transformation.
fn isDirectFunctionBody(idx: NodeIndex, ctx: *TransformContext) bool {
    // Scan all function-like nodes in the AST to see if any of them
    // have this block as their body.
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .class_method,
            .class_private_method,
            .method_definition,
            .getter,
            .setter,
            .computed_method,
            => {
                const extra_idx = @intFromEnum(datas[ni].extra);
                const body: NodeIndex = switch (tag) {
                    .getter, .setter => if (extra_idx + 2 < ctx.ast.extra_data.items.len)
                        @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2])
                    else
                        .none,
                    else => if (extra_idx + 3 < ctx.ast.extra_data.items.len)
                        @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3])
                    else
                        .none,
                };
                if (body == idx) return true;
            },
            .arrow_function_expr => {
                const extra_idx = @intFromEnum(datas[ni].extra);
                if (extra_idx + 2 < ctx.ast.extra_data.items.len) {
                    const first = ctx.ast.extra_data.items[extra_idx];
                    const second = ctx.ast.extra_data.items[extra_idx + 1];
                    const third = ctx.ast.extra_data.items[extra_idx + 2];
                    // Old format: param, body, count
                    if (first == @intFromEnum(NodeIndex.none) or third == 1) {
                        const body: NodeIndex = @enumFromInt(second);
                        if (body == idx) return true;
                    } else {
                        // New format: range_start, range_end, body
                        const body: NodeIndex = @enumFromInt(third);
                        if (body == idx) return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

const scope_mod = @import("../scope.zig");

const RenameBinding = struct {
    original: []const u8,
    emitted: []const u8,
};

fn getFunctionBody(ctx: *TransformContext, func_node: NodeIndex) NodeIndex {
    const data = ctx.nodeData(func_node);
    const tag = ctx.nodeTag(func_node);

    switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        => {
            // extra[0]=name_token, [1]=params_start, [2]=params_end, [3]=body
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
            }
        },
        .function_expr => {
            // extra[0]=name_token, [1]=params_start, [2]=params_end, [3]=body
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
            }
        },
        .arrow_function_expr => {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 < ctx.ast.extra_data.items.len) {
                // Could be old or new format; try third element
                return @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);
            }
        },
        else => {},
    }
    return .none;
}

/// Handle a block statement: find function declarations inside it and transform them.
fn handleBlock(idx: NodeIndex, ctx: *TransformContext) void {
    // Don't transform function declarations that are directly in a function body
    if (isDirectFunctionBody(idx, ctx)) return;

    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    // Determine if we're in strict mode (affects let vs var)
    const is_strict = isInStrictMode(idx, ctx);

    // Collect function declarations and build prefix text
    var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;
    var renames: std.ArrayListUnmanaged(RenameBinding) = .empty;

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_idx| {
        if (stmt_idx >= ctx.ast.nodes.len) continue;
        const stmt_tag = ctx.ast.nodes.items(.tag)[stmt_idx];
        switch (stmt_tag) {
            .function_declaration => {
                if (buildFunctionTransform(ctx, @enumFromInt(stmt_idx), idx, is_strict, false, false, .block, &prefix_buf)) |binding| {
                    if (!std.mem.eql(u8, binding.original, binding.emitted)) {
                        renames.append(ctx.allocator, binding) catch {};
                    }
                }
            },
            .async_function_declaration => {
                if (buildFunctionTransform(ctx, @enumFromInt(stmt_idx), idx, is_strict, true, false, .block, &prefix_buf)) |binding| {
                    if (!std.mem.eql(u8, binding.original, binding.emitted)) {
                        renames.append(ctx.allocator, binding) catch {};
                    }
                }
            },
            .generator_declaration => {
                if (buildFunctionTransform(ctx, @enumFromInt(stmt_idx), idx, is_strict, false, true, .block, &prefix_buf)) |binding| {
                    if (!std.mem.eql(u8, binding.original, binding.emitted)) {
                        renames.append(ctx.allocator, binding) catch {};
                    }
                }
            },
            .async_generator_declaration => {
                if (buildFunctionTransform(ctx, @enumFromInt(stmt_idx), idx, is_strict, true, true, .block, &prefix_buf)) |binding| {
                    if (!std.mem.eql(u8, binding.original, binding.emitted)) {
                        renames.append(ctx.allocator, binding) catch {};
                    }
                }
            },
            else => {},
        }
    }

    if (renames.items.len > 0) {
        renameIdentifiersInSubtree(ctx, idx, renames.items);
    }

    // Set block prefix if we generated any transforms
    if (prefix_buf.items.len > 0) {
        ctx.ast.block_prefix_source.put(ctx.allocator, @intFromEnum(idx), prefix_buf.items) catch return;
    }
}

/// Handle a switch statement: find function declarations in case/default clauses.
fn handleSwitch(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;
    const cases_start = ctx.ast.extra_data.items[extra_idx + 1];
    const cases_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (cases_end <= cases_start) return;

    const is_strict = isInStrictMode(idx, ctx);
    var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;
    var renames: std.ArrayListUnmanaged(RenameBinding) = .empty;

    for (ctx.ast.extra_data.items[cases_start..cases_end]) |case_raw| {
        const case_idx: NodeIndex = @enumFromInt(case_raw);
        if (case_idx == .none) continue;
        const case_data = ctx.nodeData(case_idx);
        const case_extra = @intFromEnum(case_data.extra);
        if (case_extra + 2 >= ctx.ast.extra_data.items.len) continue;
        const stmts_start = ctx.ast.extra_data.items[case_extra + 1];
        const stmts_end = ctx.ast.extra_data.items[case_extra + 2];
        if (stmts_end <= stmts_start) continue;

        for (ctx.ast.extra_data.items[stmts_start..stmts_end]) |stmt_raw| {
            if (stmt_raw >= ctx.ast.nodes.len) continue;
            const stmt_idx: NodeIndex = @enumFromInt(stmt_raw);
            const stmt_tag = ctx.nodeTag(stmt_idx);
            switch (stmt_tag) {
                .function_declaration => {
                    if (buildFunctionTransform(ctx, stmt_idx, idx, is_strict, false, false, .switch_stmt, &prefix_buf)) |binding| {
                        if (!std.mem.eql(u8, binding.original, binding.emitted)) {
                            renames.append(ctx.allocator, binding) catch {};
                        }
                    }
                },
                .async_function_declaration => {
                    if (buildFunctionTransform(ctx, stmt_idx, idx, is_strict, true, false, .switch_stmt, &prefix_buf)) |binding| {
                        if (!std.mem.eql(u8, binding.original, binding.emitted)) {
                            renames.append(ctx.allocator, binding) catch {};
                        }
                    }
                },
                .generator_declaration => {
                    if (buildFunctionTransform(ctx, stmt_idx, idx, is_strict, false, true, .switch_stmt, &prefix_buf)) |binding| {
                        if (!std.mem.eql(u8, binding.original, binding.emitted)) {
                            renames.append(ctx.allocator, binding) catch {};
                        }
                    }
                },
                .async_generator_declaration => {
                    if (buildFunctionTransform(ctx, stmt_idx, idx, is_strict, true, true, .switch_stmt, &prefix_buf)) |binding| {
                        if (!std.mem.eql(u8, binding.original, binding.emitted)) {
                            renames.append(ctx.allocator, binding) catch {};
                        }
                    }
                },
                else => {},
            }
        }
    }

    if (prefix_buf.items.len == 0) return;
    if (renames.items.len > 0) {
        renameIdentifiersInSubtree(ctx, idx, renames.items);
    }
    ctx.ast.block_prefix_source.put(ctx.allocator, @intFromEnum(idx), prefix_buf.items) catch return;
}

/// Build the transformed function expression and append to the prefix buffer.
/// Marks the original function declaration as removed.
const TransformContextKind = enum {
    block,
    switch_stmt,
};

fn buildFunctionTransform(
    ctx: *TransformContext,
    func_idx: NodeIndex,
    context_idx: NodeIndex,
    is_strict: bool,
    is_async: bool,
    is_generator: bool,
    location: TransformContextKind,
    prefix_buf: *std.ArrayListUnmanaged(u8),
) ?RenameBinding {
    const fi = @intFromEnum(func_idx);
    const data = ctx.ast.nodes.items(.data)[fi];

    // Get function name — extra[0] is name_token (NOT a node index)
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 3 >= ctx.ast.extra_data.items.len) return null;

    const name_token_raw = ctx.ast.extra_data.items[extra_idx];
    const name_token: TokenIndex = @enumFromInt(name_token_raw);
    const name = ctx.tokenSlice(name_token);
    if (name.len == 0) return null;

    // Get the full source range of the function declaration
    const end_off = ctx.ast.nodes.items(.end_offset)[fi];
    const main_tok = ctx.ast.nodes.items(.main_token)[fi];
    const start_off = ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];

    if (end_off <= start_off or end_off > ctx.ast.source.len) return null;

    // Find the position of the function name in the source
    const source = ctx.ast.source[start_off..end_off];

    // Find where '(' starts (after the function name)
    var paren_pos: usize = 0;
    var pos: usize = 0;
    if (is_async) {
        if (pos + 5 < source.len and std.mem.eql(u8, source[pos .. pos + 5], "async")) {
            pos += 5;
            while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or source[pos] == '\n' or source[pos] == '\r')) : (pos += 1) {}
        }
    }
    if (pos + 8 <= source.len and std.mem.eql(u8, source[pos .. pos + 8], "function")) {
        pos += 8;
    }
    while (pos < source.len and (source[pos] == ' ' or source[pos] == '*' or source[pos] == '\t' or source[pos] == '\n' or source[pos] == '\r')) : (pos += 1) {}
    while (pos < source.len and isIdentCont(source[pos])) : (pos += 1) {}
    while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or source[pos] == '\n' or source[pos] == '\r')) : (pos += 1) {}

    if (pos < source.len and source[pos] == '(') {
        paren_pos = pos;
    } else {
        return null;
    }

    const needs_alias = switch (location) {
        .block => if (g_config.followed_by_block_scoping)
            (is_async or is_generator or is_strict or (!isInLoopBody(ctx, func_idx) and needsRenameForBlockCollision(ctx, func_idx, name, is_strict)))
        else
            false,
        .switch_stmt => needsRenameForSwitchCollision(ctx, context_idx, func_idx, name),
    };
    const body_node = getFunctionBody(ctx, func_idx);

    const keyword = switch (location) {
        .block => if (is_strict and !g_config.followed_by_block_scoping) "let" else "var",
        .switch_stmt => if (is_strict and !needs_alias and !(g_config.lower_async_generator_functions and is_async and is_generator)) "let" else "var",
    };

    // Function body: from '(' to end, but strip the original declaration's
    // leading block indentation so codegen can re-indent it at the new site.
    const declaration_indent = getLineIndent(ctx.ast.source, start_off);
    const raw_function_suffix = dedentContinuationLines(ctx, source[paren_pos..], declaration_indent);
    const function_suffix = normalizeEmptyFunctionSuffix(ctx, raw_function_suffix);
    const should_lower_async_generator = g_config.lower_async_generator_functions and
        is_async and
        is_generator and
        body_node != .none and
        isEmptyBlockBody(ctx, body_node);
    const should_lower_async = g_config.lower_async_to_generator and
        is_async and
        !is_generator and
        body_node != .none and
        async_to_generator.canLowerAsyncFunction(ctx, func_idx);
    const should_lower_generator = g_config.lower_regenerator and
        is_generator and
        !is_async and
        regenerator.canLowerSimpleGeneratorFunction(ctx, func_idx);

    if (should_lower_async_generator) {
        const helper_name = generateUniqueName(ctx, name);
        const wrapper_name = generateUniqueName(ctx, name);
        const emit_name = if (needs_alias or location == .switch_stmt) generateUniqueName(ctx, name) else name;

        prefix_buf.appendSlice(ctx.allocator, keyword) catch return null;
        prefix_buf.append(ctx.allocator, ' ') catch return null;
        prefix_buf.appendSlice(ctx.allocator, wrapper_name) catch return null;
        prefix_buf.appendSlice(ctx.allocator, " = function ") catch return null;
        prefix_buf.appendSlice(ctx.allocator, helper_name) catch return null;
        prefix_buf.appendSlice(ctx.allocator, "() {\n") catch return null;
        prefix_buf.appendSlice(ctx.allocator, "    ") catch return null;
        prefix_buf.appendSlice(ctx.allocator, helper_name) catch return null;
        prefix_buf.appendSlice(ctx.allocator, " = babelHelpers.wrapAsyncGenerator(function*") catch return null;
        if (function_suffix.len > 0 and function_suffix[0] == '(') {
            prefix_buf.append(ctx.allocator, ' ') catch return null;
        }
        prefix_buf.appendSlice(ctx.allocator, function_suffix) catch return null;
        prefix_buf.appendSlice(ctx.allocator, ");\n") catch return null;
        prefix_buf.appendSlice(ctx.allocator, "    return ") catch return null;
        prefix_buf.appendSlice(ctx.allocator, helper_name) catch return null;
        prefix_buf.appendSlice(ctx.allocator, ".apply(this, arguments);\n") catch return null;
        prefix_buf.appendSlice(ctx.allocator, "  },\n  ") catch return null;
        prefix_buf.appendSlice(ctx.allocator, emit_name) catch return null;
        prefix_buf.appendSlice(ctx.allocator, " = function ") catch return null;
        prefix_buf.appendSlice(ctx.allocator, name) catch return null;
        prefix_buf.appendSlice(ctx.allocator, "() {\n    return ") catch return null;
        prefix_buf.appendSlice(ctx.allocator, wrapper_name) catch return null;
        prefix_buf.appendSlice(ctx.allocator, ".apply(this, arguments);\n  };\n") catch return null;

        ctx.ast.nodes.items(.tag)[fi] = .removed;
        return .{ .original = name, .emitted = emit_name };
    }

    const emit_name = if (needs_alias) generateUniqueName(ctx, name) else name;
    prefix_buf.appendSlice(ctx.allocator, keyword) catch return null;
    prefix_buf.append(ctx.allocator, ' ') catch return null;
    prefix_buf.appendSlice(ctx.allocator, emit_name) catch return null;
    prefix_buf.appendSlice(ctx.allocator, " = ") catch return null;

    if (should_lower_async) {
        const wrapper = async_to_generator.renderAsyncToGeneratorWrapperFromFunctionSuffix(ctx, emit_name, function_suffix) orelse
            return null;
        prefix_buf.appendSlice(ctx.allocator, wrapper) catch return null;
    } else if (should_lower_generator) {
        const wrapper = regenerator.renderSimpleGeneratorWrapperWithIndent(ctx, func_idx, "  ") orelse return null;
        prefix_buf.appendSlice(ctx.allocator, wrapper) catch return null;
    } else {
        if (is_async) {
            prefix_buf.appendSlice(ctx.allocator, "async ") catch return null;
        }
        prefix_buf.appendSlice(ctx.allocator, "function") catch return null;
        if (is_generator) prefix_buf.append(ctx.allocator, '*') catch return null;
        if (location == .switch_stmt) {
            prefix_buf.append(ctx.allocator, ' ') catch return null;
            prefix_buf.appendSlice(ctx.allocator, name) catch return null;
        }
        if (location == .block and function_suffix.len > 0 and function_suffix[0] == '(') {
            prefix_buf.append(ctx.allocator, ' ') catch return null;
        }
        prefix_buf.appendSlice(ctx.allocator, function_suffix) catch return null;
    }
    prefix_buf.append(ctx.allocator, ';') catch return null;
    prefix_buf.append(ctx.allocator, '\n') catch return null;

    // Mark the original function declaration as removed
    ctx.ast.nodes.items(.tag)[fi] = .removed;
    return .{ .original = name, .emitted = emit_name };
}

fn getLineIndent(source: []const u8, start_off: u32) []const u8 {
    if (start_off == 0 or start_off > source.len) return "";
    var line_start: usize = start_off;
    while (line_start > 0) : (line_start -= 1) {
        const prev = source[line_start - 1];
        if (prev == '\n' or prev == '\r') break;
    }

    var indent_end = line_start;
    while (indent_end < start_off and (source[indent_end] == ' ' or source[indent_end] == '\t')) : (indent_end += 1) {}
    return source[line_start..indent_end];
}

fn dedentContinuationLines(ctx: *TransformContext, src: []const u8, indent: []const u8) []const u8 {
    if (src.len == 0 or indent.len == 0 or std.mem.indexOfScalar(u8, src, '\n') == null) return src;

    const body_extra_indent = getFunctionBodyExtraIndent(src, indent);
    const body_open_pos = findFunctionBodyOpenPos(src);
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var cursor: usize = 0;
    var saw_open_brace = false;
    var adjusted_body_line = false;
    while (cursor < src.len) {
        const line_start = cursor;
        const nl_rel = std.mem.indexOfScalar(u8, src[cursor..], '\n') orelse {
            result.appendSlice(ctx.allocator, src[cursor..]) catch return src;
            break;
        };
        const line = src[cursor .. cursor + nl_rel + 1];
        const nl = cursor + nl_rel;
        result.appendSlice(ctx.allocator, line) catch return src;
        cursor = nl + 1;
        if (!saw_open_brace) {
            if (body_open_pos) |open_pos| {
                if (line_start <= open_pos and open_pos < nl + 1) {
                    saw_open_brace = true;
                }
            }
        }
        if (cursor < src.len and std.mem.startsWith(u8, src[cursor..], indent)) {
            cursor += indent.len;
            if (saw_open_brace and body_extra_indent > 0 and !adjusted_body_line) {
                var extra = body_extra_indent;
                while (extra > 0 and cursor < src.len and src[cursor] == ' ') : (extra -= 1) {
                    cursor += 1;
                }
                adjusted_body_line = true;
            }
        }
    }
    return result.items;
}

fn getFunctionBodyExtraIndent(src: []const u8, indent: []const u8) usize {
    if (indent.len < 8) return 0;
    const open = findFunctionBodyOpenPos(src) orelse return 0;
    const body_start = std.mem.indexOfScalarPos(u8, src, open, '\n') orelse return 0;
    const cursor = body_start + 1;
    var spaces: usize = 0;
    while (cursor + spaces < src.len and src[cursor + spaces] == ' ') : (spaces += 1) {}
    if (spaces <= indent.len + 2) return 0;
    return spaces - indent.len - 2;
}

fn findFunctionBodyOpenPos(src: []const u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
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
            '{' => if (paren_depth == 0 and bracket_depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn normalizeEmptyFunctionSuffix(ctx: *TransformContext, suffix: []const u8) []const u8 {
    const open = std.mem.lastIndexOfScalar(u8, suffix, '{') orelse return suffix;
    var cursor = open + 1;
    while (cursor < suffix.len and (suffix[cursor] == ' ' or suffix[cursor] == '\t')) : (cursor += 1) {}
    if (cursor >= suffix.len or suffix[cursor] != '}') return suffix;

    var tail = cursor + 1;
    while (tail < suffix.len and (suffix[tail] == ' ' or suffix[tail] == '\t' or suffix[tail] == '\n' or suffix[tail] == '\r')) : (tail += 1) {}
    if (tail != suffix.len) return suffix;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, suffix[0 .. open + 1]) catch return suffix;
    buf.append(ctx.allocator, '}') catch return suffix;
    return buf.items;
}

fn isEmptyBlockBody(ctx: *TransformContext, body_node: NodeIndex) bool {
    if (body_node == .none or ctx.nodeTag(body_node) != .block_statement) return false;

    const extra_idx = @intFromEnum(ctx.nodeData(body_node).extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];
    return range_start == range_end;
}

fn renameIdentifiersInSubtree(ctx: *TransformContext, root: NodeIndex, renames: []const RenameBinding) void {
    if (root == .none or renames.len == 0) return;

    renameIdentifierNode(ctx, root, renames);

    const children = visitor.getChildren(ctx.ast, root);

    for (children.items[0..children.len]) |child| {
        if (child == .none) continue;
        if (subtreeShadowsRenamedName(ctx, child, renames)) continue;
        renameIdentifiersInSubtree(ctx, child, renames);
    }

    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |child_raw| {
            if (child_raw >= ctx.ast.nodes.len) continue;
            const child: NodeIndex = @enumFromInt(child_raw);
            if (subtreeShadowsRenamedName(ctx, child, renames)) continue;
            renameIdentifiersInSubtree(ctx, child, renames);
        }
    }

    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |child_raw| {
            if (child_raw >= ctx.ast.nodes.len) continue;
            const child: NodeIndex = @enumFromInt(child_raw);
            if (subtreeShadowsRenamedName(ctx, child, renames)) continue;
            renameIdentifiersInSubtree(ctx, child, renames);
        }
    }
}

fn subtreeShadowsRenamedName(ctx: *TransformContext, node: NodeIndex, renames: []const RenameBinding) bool {
    if (node == .none) return false;

    const tag = ctx.nodeTag(node);
    switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return false;
            const name_token: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const name = ctx.tokenSlice(name_token);
            for (renames) |binding| {
                if (std.mem.eql(u8, name, binding.original)) return true;
            }
        },
        else => {},
    }

    return false;
}

fn renameIdentifierNode(ctx: *TransformContext, node: NodeIndex, renames: []const RenameBinding) void {
    if (node == .none or ctx.nodeTag(node) != .identifier) return;

    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.contains(ni)) return;

    const name = ctx.tokenSlice(ctx.mainToken(node));
    for (renames) |binding| {
        if (std.mem.eql(u8, name, binding.original)) {
            ctx.ast.replacement_source.put(ctx.allocator, ni, binding.emitted) catch return;
            return;
        }
    }
}

fn hasReferencesInSubtree(ctx: *TransformContext, root: NodeIndex, name: []const u8) bool {
    if (root == .none) return false;
    switch (ctx.nodeTag(root)) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        => {
            const data = ctx.nodeData(root);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx < ctx.ast.extra_data.items.len) {
                const name_token: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
                if (std.mem.eql(u8, ctx.tokenSlice(name_token), name)) return false;
            }
        },
        else => {},
    }
    if (ctx.nodeTag(root) == .identifier) {
        return std.mem.eql(u8, ctx.tokenSlice(ctx.mainToken(root)), name);
    }

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        if (child != .none and hasReferencesInSubtree(ctx, child, name)) return true;
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |child_raw| {
            if (child_raw >= ctx.ast.nodes.len) continue;
            if (hasReferencesInSubtree(ctx, @enumFromInt(child_raw), name)) return true;
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |child_raw| {
            if (child_raw >= ctx.ast.nodes.len) continue;
            if (hasReferencesInSubtree(ctx, @enumFromInt(child_raw), name)) return true;
        }
    }
    return false;
}

fn hasSwitchReferencesForName(ctx: *TransformContext, switch_idx: NodeIndex, skip_decl: NodeIndex, name: []const u8) bool {
    const data = ctx.nodeData(switch_idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return false;

    const cases_start = ctx.ast.extra_data.items[extra_idx + 1];
    const cases_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (cases_end <= cases_start) return false;

    for (ctx.ast.extra_data.items[cases_start..cases_end]) |case_raw| {
        const case_idx: NodeIndex = @enumFromInt(case_raw);
        if (case_idx == .none) continue;
        const case_data = ctx.nodeData(case_idx);
        const case_extra = @intFromEnum(case_data.extra);
        if (case_extra + 2 >= ctx.ast.extra_data.items.len) continue;
        const stmts_start = ctx.ast.extra_data.items[case_extra + 1];
        const stmts_end = ctx.ast.extra_data.items[case_extra + 2];
        for (ctx.ast.extra_data.items[stmts_start..stmts_end]) |stmt_raw| {
            if (stmt_raw >= ctx.ast.nodes.len) continue;
            const stmt_idx: NodeIndex = @enumFromInt(stmt_raw);
            if (stmt_idx == skip_decl) continue;
            if (hasReferencesInSubtree(ctx, stmt_idx, name)) return true;
        }
    }

    return false;
}

fn hasOtherStatementsInSwitch(ctx: *TransformContext, switch_idx: NodeIndex, skip_decl: NodeIndex) bool {
    const data = ctx.nodeData(switch_idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return false;

    const cases_start = ctx.ast.extra_data.items[extra_idx + 1];
    const cases_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (cases_end <= cases_start) return false;

    for (ctx.ast.extra_data.items[cases_start..cases_end]) |case_raw| {
        const case_idx: NodeIndex = @enumFromInt(case_raw);
        if (case_idx == .none) continue;
        const case_data = ctx.nodeData(case_idx);
        const case_extra = @intFromEnum(case_data.extra);
        if (case_extra + 2 >= ctx.ast.extra_data.items.len) continue;
        const stmts_start = ctx.ast.extra_data.items[case_extra + 1];
        const stmts_end = ctx.ast.extra_data.items[case_extra + 2];
        for (ctx.ast.extra_data.items[stmts_start..stmts_end]) |stmt_raw| {
            if (stmt_raw >= ctx.ast.nodes.len) continue;
            const stmt_idx: NodeIndex = @enumFromInt(stmt_raw);
            if (stmt_idx == skip_decl or ctx.nodeTag(stmt_idx) == .removed) continue;
            return true;
        }
    }

    return false;
}

fn needsRenameForSwitchCollision(ctx: *TransformContext, switch_idx: NodeIndex, func_idx: NodeIndex, name: []const u8) bool {
    if (needsRenameForCollision(ctx, func_idx, name)) return true;

    const scope_result = ctx.scope orelse return false;
    const switch_scope_idx = scope_mod.getScopeForNode(scope_result, switch_idx) orelse return false;
    const switch_scope = scope_result.scopes[@intFromEnum(switch_scope_idx)];

    var ancestor_scope_idx = switch_scope.parent;
    while (ancestor_scope_idx) |scope_idx| {
        const scope = scope_result.scopes[@intFromEnum(scope_idx)];
        for (scope_result.bindings[scope.bindings_start..scope.bindings_end]) |binding| {
            if (binding.node == func_idx) continue;
            if (std.mem.eql(u8, binding.name, name)) return true;
        }
        ancestor_scope_idx = scope.parent;
    }

    return false;
}

/// Check if a function name collides with bindings in parent scopes.
/// Only rename in sloppy mode when the function becomes `var` (hoisted),
/// and the name collides with a binding in the enclosing function scope
/// or a sibling block within that function.
fn needsRenameForCollision(ctx: *TransformContext, func_idx: NodeIndex, name: []const u8) bool {
    const scope_result = ctx.scope orelse return false;
    const scope_idx = scope_mod.getScopeForNode(scope_result, func_idx) orelse return false;
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];
    const current_start = nodeStartOffset(ctx, func_idx);

    if (isInStrictMode(func_idx, ctx) and !g_config.followed_by_block_scoping) return false;

    // In sloppy mode, the function becomes `var` which hoists to the enclosing function.
    // Only rename if the name collides with a let/const binding in an intermediate or
    // enclosing scope. Var/function bindings don't conflict since they share function scope.

    // Find the enclosing function scope, checking intermediate block scopes
    var func_scope_idx: ?scope_mod.ScopeIndex = scope.parent;
    while (func_scope_idx) |fs_idx| {
        const fs = scope_result.scopes[@intFromEnum(fs_idx)];
        switch (fs.kind) {
            .function, .arrow, .global, .module => break,
            .block, .catch_clause, .class_body => {
                // Check let/const bindings in intermediate block scopes
                for (scope_result.bindings[fs.bindings_start..fs.bindings_end]) |b| {
                    if (b.node == func_idx) continue;
                    if (nodeStartOffset(ctx, b.node) >= current_start) continue;
                    if (std.mem.eql(u8, b.name, name)) return true;
                }
            },
        }
        func_scope_idx = fs.parent;
    }

    // Check the function scope itself for let/const bindings
    if (func_scope_idx) |fs_idx| {
        const fs = scope_result.scopes[@intFromEnum(fs_idx)];
        for (scope_result.bindings[fs.bindings_start..fs.bindings_end]) |b| {
            if (b.node == func_idx) continue;
            if (nodeStartOffset(ctx, b.node) >= current_start) continue;
            if (std.mem.eql(u8, b.name, name)) return true;
        }
    }

    return false;
}

fn nodeStartOffset(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return 0;
    const mt = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(mt)];
}

fn isInLoopBody(ctx: *TransformContext, node: NodeIndex) bool {
    const start = nodeStartOffset(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(node)];

    for (ctx.ast.nodes.items(.tag), 0..) |tag, ni| {
        const body = switch (tag) {
            .for_statement => blk: {
                const extra_idx = @intFromEnum(ctx.ast.nodes.items(.data)[ni].extra);
                if (extra_idx + 3 >= ctx.ast.extra_data.items.len) break :blk NodeIndex.none;
                break :blk @as(NodeIndex, @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]));
            },
            .for_in_statement, .for_of_statement => blk: {
                const extra_idx = @intFromEnum(ctx.ast.nodes.items(.data)[ni].extra);
                if (extra_idx + 2 >= ctx.ast.extra_data.items.len) break :blk NodeIndex.none;
                break :blk @as(NodeIndex, @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]));
            },
            .while_statement => ctx.ast.nodes.items(.data)[ni].binary.rhs,
            .do_while_statement => ctx.ast.nodes.items(.data)[ni].binary.lhs,
            else => NodeIndex.none,
        };
        if (body == .none) continue;

        const body_start = nodeStartOffset(ctx, body);
        const body_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(body)];
        if (start >= body_start and end <= body_end) return true;
    }

    return false;
}

fn needsRenameForBlockCollision(ctx: *TransformContext, func_idx: NodeIndex, name: []const u8, is_strict: bool) bool {
    const scope_result = ctx.scope orelse return false;
    const scope_idx = scope_mod.getScopeForNode(scope_result, func_idx) orelse return false;
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];
    const current_start = nodeStartOffset(ctx, func_idx);
    const binding_idx = ctx.getBindingIndexForNode(func_idx) orelse return false;

    var func_scope_idx: ?scope_mod.ScopeIndex = scope.parent;
    while (func_scope_idx) |fs_idx| {
        const fs = scope_result.scopes[@intFromEnum(fs_idx)];
        switch (fs.kind) {
            .function, .arrow, .global, .module => break,
            .block, .catch_clause, .class_body => {
                for (scope_result.bindings[fs.bindings_start..fs.bindings_end]) |b| {
                    if (b.node == func_idx) continue;
                    if (nodeStartOffset(ctx, b.node) >= current_start) continue;
                    if (!std.mem.eql(u8, b.name, name)) continue;
                    if (is_strict or b.kind == .let_decl or b.kind == .const_decl) return true;
                }
            },
        }
        func_scope_idx = fs.parent;
    }

    if (func_scope_idx) |fs_idx| {
        const fs = scope_result.scopes[@intFromEnum(fs_idx)];
        for (scope_result.bindings[fs.bindings_start..fs.bindings_end]) |b| {
            if (b.node == func_idx) continue;
            if (nodeStartOffset(ctx, b.node) >= current_start) continue;
            if (!std.mem.eql(u8, b.name, name)) continue;
            if (is_strict or b.kind == .let_decl or b.kind == .const_decl) return true;
        }
    }

    if (g_config.followed_by_block_scoping) {
        const current_block = scope.node;
        const current_block_start = nodeStartOffset(ctx, current_block);
        var outer_scope_idx = scope.parent;
        while (outer_scope_idx) |os_idx| {
            const os = scope_result.scopes[@intFromEnum(os_idx)];
            switch (os.kind) {
                .function, .arrow, .global, .module => {
                    if (hasResolvedBindingReferenceBeforeOffsetInSubtree(ctx, os.node, current_block, binding_idx, current_block_start)) return true;
                    break;
                },
                else => {},
            }
            outer_scope_idx = os.parent;
        }
    }

    return false;
}

fn hasResolvedBindingReferenceBeforeOffsetInSubtree(
    ctx: *TransformContext,
    root: NodeIndex,
    skip_root: NodeIndex,
    binding_idx: u32,
    max_start: u32,
) bool {
    if (root == .none or root == skip_root) return false;
    if (nodeStartOffset(ctx, root) >= max_start) return false;

    const scope_result = ctx.scope orelse return false;
    const tag = ctx.nodeTag(root);
    switch (tag) {
        .identifier => {
            const name = ctx.tokenSlice(ctx.mainToken(root));
            if ((if (ctx.session) |session| session.resolvedBindingIndexFor(root) else scope_mod.resolveBindingIndexForNode(scope_result, root, name))) |resolved_idx| {
                const resolved = scope_result.bindings[resolved_idx];
                if (resolved_idx != binding_idx and (resolved.kind == .let_decl or resolved.kind == .const_decl)) return true;
            }
        },
        .member_expr, .optional_chain_expr => {
            const data = ctx.nodeData(root);
            return hasResolvedBindingReferenceBeforeOffsetInSubtree(ctx, data.binary.lhs, skip_root, binding_idx, max_start);
        },
        else => {},
    }

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        if (child != .none and hasResolvedBindingReferenceBeforeOffsetInSubtree(ctx, child, skip_root, binding_idx, max_start)) return true;
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |child_raw| {
            if (child_raw >= ctx.ast.nodes.len) continue;
            if (hasResolvedBindingReferenceBeforeOffsetInSubtree(ctx, @enumFromInt(child_raw), skip_root, binding_idx, max_start)) return true;
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |child_raw| {
            if (child_raw >= ctx.ast.nodes.len) continue;
            if (hasResolvedBindingReferenceBeforeOffsetInSubtree(ctx, @enumFromInt(child_raw), skip_root, binding_idx, max_start)) return true;
        }
    }

    return false;
}

/// Generate a unique name by prepending underscore(s).
fn generateUniqueName(ctx: *TransformContext, original: []const u8) []const u8 {
    const scope_result = ctx.scope orelse return original;

    // Try _name first, then _name2, _name3, ...
    const first = std.fmt.allocPrint(ctx.allocator, "_{s}", .{original}) catch return original;
    if (!isNameUsedInAnyScope(scope_result, first) and !g_claimed_names.contains(first)) {
        g_claimed_names.put(ctx.allocator, first, {}) catch {};
        return first;
    }

    var counter: u32 = 2;
    while (counter < 100) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ original, counter }) catch return original;
        if (!isNameUsedInAnyScope(scope_result, candidate) and !g_claimed_names.contains(candidate)) {
            g_claimed_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    return first;
}

fn isNameUsedInAnyScope(result: *const scope_mod.ScopeResult, name: []const u8) bool {
    for (result.bindings) |b| {
        if (std.mem.eql(u8, b.name, name)) return true;
    }
    return false;
}

fn isIdentCont(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or (c >= '0' and c <= '9');
}

/// Check if we're in strict mode by looking up the scope chain.
fn isInStrictMode(idx: NodeIndex, ctx: *TransformContext) bool {
    // Check if the source starts with "use strict" or if the file is a module
    if (ctx.ast.source_type == .module) return true;

    // Check for "use strict" directive at the beginning of the containing function or program
    // Look for string literal "use strict" at the start of a function body or program
    if (ctx.scope) |scope_result| {
        var scope_idx = scope_mod.getScopeForNode(scope_result, idx);
        while (scope_idx) |si| {
            const scope = scope_result.scopes[@intFromEnum(si)];
            switch (scope.kind) {
                .function, .arrow => {
                    // Check if the function body starts with "use strict"
                    if (checkBodyForUseStrict(ctx, scope.node)) return true;
                },
                .class_body => return true,
                .global, .module => {
                    // Check program body for "use strict"
                    return checkProgramForUseStrict(ctx);
                },
                else => {},
            }
            scope_idx = scope.parent;
        }
    }

    // Fallback: scan the source for "use strict" before this node
    return false;
}

fn checkProgramForUseStrict(ctx: *TransformContext) bool {
    if (ctx.ast.nodes.len == 0) return false;
    const prog_tag = ctx.ast.nodes.items(.tag)[0];
    if (prog_tag != .program) return false;

    const prog_data = ctx.ast.nodes.items(.data)[0];
    const extra_idx = @intFromEnum(prog_data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_idx| {
        if (stmt_idx >= ctx.ast.nodes.len) continue;
        const stmt_tag = ctx.ast.nodes.items(.tag)[stmt_idx];
        if (stmt_tag == .directive) {
            const stmt_data = ctx.ast.nodes.items(.data)[stmt_idx];
            const expr = stmt_data.unary;
            if (expr != .none) {
                const tok = ctx.ast.nodes.items(.main_token)[@intFromEnum(expr)];
                const text = ctx.ast.tokenSlice(tok);
                if (std.mem.eql(u8, text, "\"use strict\"") or std.mem.eql(u8, text, "'use strict'")) {
                    return true;
                }
            }
        } else if (stmt_tag == .expression_statement) {
            const stmt_data = ctx.ast.nodes.items(.data)[stmt_idx];
            const expr = stmt_data.unary;
            if (expr != .none) {
                const expr_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(expr)];
                if (expr_tag == .string_literal or expr_tag == .directive_literal) {
                    const tok = ctx.ast.nodes.items(.main_token)[@intFromEnum(expr)];
                    const text = ctx.ast.tokenSlice(tok);
                    if (std.mem.eql(u8, text, "\"use strict\"") or std.mem.eql(u8, text, "'use strict'")) {
                        return true;
                    }
                }
            }
        }
        // Only check the first statement (directives are at the top)
        break;
    }
    return false;
}

fn checkBodyForUseStrict(ctx: *TransformContext, func_node: NodeIndex) bool {
    if (func_node == .none) return false;
    const body = getFunctionBody(ctx, func_node);
    if (body == .none) return false;

    const body_tag = ctx.nodeTag(body);
    if (body_tag != .block_statement) return false;

    const body_data = ctx.nodeData(body);
    const extra_idx = @intFromEnum(body_data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_idx| {
        if (stmt_idx >= ctx.ast.nodes.len) continue;
        const stmt_tag = ctx.ast.nodes.items(.tag)[stmt_idx];
        if (stmt_tag == .directive) {
            const stmt_data = ctx.ast.nodes.items(.data)[stmt_idx];
            const expr = stmt_data.unary;
            if (expr != .none) {
                const tok = ctx.ast.nodes.items(.main_token)[@intFromEnum(expr)];
                const text = ctx.ast.tokenSlice(tok);
                if (std.mem.eql(u8, text, "\"use strict\"") or std.mem.eql(u8, text, "'use strict'")) {
                    return true;
                }
            }
        } else if (stmt_tag == .expression_statement) {
            const stmt_data = ctx.ast.nodes.items(.data)[stmt_idx];
            const expr = stmt_data.unary;
            if (expr != .none) {
                const expr_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(expr)];
                if (expr_tag == .string_literal or expr_tag == .directive_literal) {
                    const tok = ctx.ast.nodes.items(.main_token)[@intFromEnum(expr)];
                    const text = ctx.ast.tokenSlice(tok);
                    if (std.mem.eql(u8, text, "\"use strict\"") or std.mem.eql(u8, text, "'use strict'")) {
                        return true;
                    }
                }
            }
        }
        break;
    }
    return false;
}
