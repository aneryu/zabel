const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

/// Configuration for the template-literals transform.
pub const Config = struct {
    /// When true, use `taggedTemplateLiteralLoose` instead of `taggedTemplateLiteral`.
    mutable_template_object: bool = false,
    /// When true, use simple `+` concatenation instead of `.concat()`.
    ignore_to_primitive_hint: bool = false,
};

var g_config: Config = .{};

pub fn createPass(config: Config) Pass {
    g_config = config;
    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.template_literal));
    filter.set(@intFromEnum(Node.Tag.tagged_template_expr));
    return .{
        .name = "template_literals",
        .node_filter = filter,
        .enter = enterNode,
        .priority = 20,
    };
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .template_literal => handleTemplateLiteral(idx, ctx),
        .tagged_template_expr => {
            handleTaggedTemplate(idx, ctx);
            return .skip_children;
        },
        else => {},
    }
    return .continue_traversal;
}

// ── Untagged template literal ───────────────────────────────────────

/// Represents an item in the flattened nodes array: either a string literal
/// or an expression reference.
const NodeItem = union(enum) {
    string: []const u8, // cooked string content (without quotes)
    expr: NodeIndex,
};

fn handleTemplateLiteral(idx: NodeIndex, ctx: *TransformContext) void {
    const i = @intFromEnum(idx);
    const mt = ctx.mainToken(idx);
    const mt_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(mt)];

    if (mt_tag == .template_no_sub) {
        // No substitutions: `foo` -> "foo"
        handleNoSubTemplate(idx, ctx) catch return;
        return;
    }

    // Has substitutions — build flat nodes array following Babel's algorithm
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const num_expressions = ctx.ast.extra_data.items[extra_idx];
    const exprs_start = extra_idx + 1;
    const tokens_start = exprs_start + num_expressions;

    // Build nodes array: interleave cooked quasis strings and expressions
    var nodes: std.ArrayListUnmanaged(NodeItem) = .empty;

    var expr_index: u32 = 0;
    for (0..num_expressions + 1) |j| {
        const tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[tokens_start + j]);
        const cooked = getTemplateCookedString(ctx, tok);

        if (cooked.len > 0) {
            nodes.append(ctx.allocator, .{ .string = cooked }) catch return;
        }

        if (expr_index < num_expressions) {
            const expr_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[exprs_start + expr_index]);
            // Skip empty string literal expressions (Babel: !t.isStringLiteral(node, { value: "" }))
            if (!isEmptyStringLiteral(ctx, expr_node)) {
                nodes.append(ctx.allocator, .{ .expr = expr_node }) catch return;
            }
            expr_index += 1;
        }
    }

    // Ensure the first node is a string if first/second isn't
    if (nodes.items.len == 0) {
        // All empty — just produce ""
        ctx.ast.replacement_source.put(ctx.allocator, i, "\"\"") catch {};
        return;
    }

    const first_is_string = isStringItem(ctx, nodes.items[0]);
    const second_is_string = if (nodes.items.len > 1) isStringItem(ctx, nodes.items[1]) else false;

    if (!first_is_string and !(g_config.ignore_to_primitive_hint and second_is_string)) {
        nodes.insert(ctx.allocator, 0, .{ .string = "" }) catch return;
    }

    // Single node — emit directly
    if (nodes.items.len == 1) {
        switch (nodes.items[0]) {
            .string => |s| {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                appendQuotedString(&buf, ctx.allocator, s) catch return;
                ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch {};
                return;
            },
            .expr => |expr_node| {
                ctx.ast.replacement_source.put(ctx.allocator, i, getNodeSource(ctx, expr_node)) catch {};
                return;
            },
        }
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    if (g_config.ignore_to_primitive_hint) {
        // Check if we need to wrap in parens (when template is RHS of a binary +)
        const needs_outer_parens = needsContextParens(ctx, idx);

        if (needs_outer_parens) buf.append(ctx.allocator, '(') catch return;

        // Simple + concatenation: root = nodes[0]; for i=1..n: root = root + nodes[i]
        emitNodeItemForPlus(ctx, &buf, nodes.items[0]) catch return;
        for (nodes.items[1..]) |item| {
            buf.appendSlice(ctx.allocator, " + ") catch return;
            emitNodeItemForPlus(ctx, &buf, item) catch return;
        }

        if (needs_outer_parens) buf.append(ctx.allocator, ')') catch return;
    } else {
        // .concat() mode using buildConcatCallExpressions algorithm
        buildConcatCallExpressions(ctx, &buf, nodes.items) catch return;
    }

    ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch return;
}

/// Babel's buildConcatCallExpressions algorithm:
/// - `avail` starts true (one free pass for first non-literal)
/// - Literals can always be inserted into current .concat() args
/// - First non-literal uses the free pass; subsequent non-literals start new .concat()
fn buildConcatCallExpressions(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    items: []const NodeItem,
) !void {
    if (items.len == 0) return;

    // Emit first item (always the "left" of the reduce)
    try emitNodeItem(ctx, buf, items[0]);

    var avail = true;
    var in_call = false; // whether "left" is currently a CallExpression (.concat(...))

    for (items[1..]) |right| {
        const is_literal = switch (right) {
            .string => true,
            .expr => |node| isLiteralNode(ctx, node),
        };

        var can_be_inserted = is_literal;
        if (!can_be_inserted and avail) {
            can_be_inserted = true;
            avail = false;
        }

        if (can_be_inserted and in_call) {
            // Push into existing .concat() args
            try buf.appendSlice(ctx.allocator, ", ");
            try emitNodeItem(ctx, buf, right);
        } else {
            // Close previous call if open
            if (in_call) {
                try buf.append(ctx.allocator, ')');
            }
            // Start new .concat(right)
            try buf.appendSlice(ctx.allocator, ".concat(");
            try emitNodeItem(ctx, buf, right);
            in_call = true;
        }
    }

    if (in_call) {
        try buf.append(ctx.allocator, ')');
    }
}

/// Check if a NodeItem is a string (either a cooked quasi string or a string literal expression).
fn isStringItem(ctx: *TransformContext, item: NodeItem) bool {
    return switch (item) {
        .string => true,
        .expr => |node| ctx.nodeTag(node) == .string_literal,
    };
}

fn emitNodeItem(ctx: *TransformContext, buf: *std.ArrayListUnmanaged(u8), item: NodeItem) !void {
    switch (item) {
        .string => |s| try appendQuotedString(buf, ctx.allocator, s),
        .expr => |node| try buf.appendSlice(ctx.allocator, getNodeSource(ctx, node)),
    }
}

/// Emit a node item for + concatenation, wrapping binary expressions in parens.
fn emitNodeItemForPlus(ctx: *TransformContext, buf: *std.ArrayListUnmanaged(u8), item: NodeItem) !void {
    switch (item) {
        .string => |s| try appendQuotedString(buf, ctx.allocator, s),
        .expr => |node| {
            const src = getNodeSource(ctx, node);
            // Wrap binary expressions in parens to preserve evaluation order
            if (needsParensInPlus(ctx, node)) {
                try buf.append(ctx.allocator, '(');
                try buf.appendSlice(ctx.allocator, src);
                try buf.append(ctx.allocator, ')');
            } else {
                try buf.appendSlice(ctx.allocator, src);
            }
        },
    }
}

/// Check if an expression node needs parentheses when used as an operand of +.
fn needsParensInPlus(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    return switch (ctx.nodeTag(node)) {
        // Binary expressions with + need parens (e.g., foo + bar -> (foo + bar))
        .binary_expr => true,
        else => false,
    };
}

/// Check if the template literal needs outer parentheses based on its context.
/// This is needed when the template is an operand of a binary expression.
fn needsContextParens(ctx: *TransformContext, idx: NodeIndex) bool {
    // Look at the source text before the template literal to detect if we're
    // the right operand of a binary + expression.
    const start = getNodeStart(ctx, idx);
    if (start == 0) return false;

    // Scan backwards past whitespace to find the preceding operator
    var pos = start;
    while (pos > 0) {
        pos -= 1;
        const ch = ctx.ast.source[pos];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') continue;
        // Check for + operator
        return ch == '+';
    }
    return false;
}

fn isEmptyStringLiteral(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    if (ctx.nodeTag(node) != .string_literal) return false;
    const src = getNodeSource(ctx, node);
    // Empty string literal: "" or ''
    return src.len == 2 and (src[0] == '"' or src[0] == '\'');
}

fn isLiteralNode(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    return switch (ctx.nodeTag(node)) {
        .string_literal,
        .numeric_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        => true,
        else => false,
    };
}

// ── Tagged template ─────────────────────────────────────────────────

fn handleTaggedTemplate(idx: NodeIndex, ctx: *TransformContext) void {
    const i = @intFromEnum(idx);
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const tag_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const quasi_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);

    // Get the quasi (template literal) information
    const quasi_data = ctx.nodeData(quasi_node);
    const quasi_mt = ctx.mainToken(quasi_node);
    const quasi_mt_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(quasi_mt)];

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    // Allocate unique template object name
    const template_obj_name = allocTemplateObjectName(ctx) catch return;

    // Get tag source text
    const tag_src = getNodeSource(ctx, tag_node);

    // Collect quasis (cooked and raw strings) and expressions
    var cooked_strings: std.ArrayListUnmanaged(CookedValue) = .empty;
    var raw_strings: std.ArrayListUnmanaged([]const u8) = .empty;
    var expr_sources: std.ArrayListUnmanaged([]const u8) = .empty;

    if (quasi_mt_tag == .template_no_sub) {
        // No substitutions: just the one quasi
        const tok_src = ctx.ast.tokenSlice(quasi_mt);
        const raw = rawTemplateString(ctx.allocator, tok_src) catch return;
        const cooked = cookTemplateStringForTagged(ctx.allocator, tok_src);
        cooked_strings.append(ctx.allocator, cooked) catch return;
        raw_strings.append(ctx.allocator, raw) catch return;
    } else {
        const qe_idx = @intFromEnum(quasi_data.extra);
        const num_expressions = ctx.ast.extra_data.items[qe_idx];
        const q_exprs_start = qe_idx + 1;
        const q_tokens_start = q_exprs_start + num_expressions;

        // Collect all quasis (num_expressions + 1 tokens)
        for (0..num_expressions + 1) |j| {
            const tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[q_tokens_start + j]);
            const tok_src = ctx.ast.tokenSlice(tok);
            const raw = rawTemplateString(ctx.allocator, tok_src) catch return;
            const cooked = cookTemplateStringForTagged(ctx.allocator, tok_src);
            cooked_strings.append(ctx.allocator, cooked) catch return;
            raw_strings.append(ctx.allocator, raw) catch return;
        }

        // Collect expression sources
        for (0..num_expressions) |j| {
            const expr_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[q_exprs_start + j]);
            const expr_src = getNodeSource(ctx, expr_node);
            expr_sources.append(ctx.allocator, expr_src) catch return;
        }
    }

    // Check if we need the raw array (only if any cooked != raw)
    var needs_raw = false;
    for (0..cooked_strings.items.len) |j| {
        const cooked = cooked_strings.items[j];
        const raw = raw_strings.items[j];
        if (cooked == .void_0) {
            needs_raw = true;
            break;
        }
        if (!std.mem.eql(u8, cooked.value, raw)) {
            needs_raw = true;
            break;
        }
    }

    const helper_name = if (g_config.mutable_template_object)
        "babelHelpers.taggedTemplateLiteralLoose"
    else
        "babelHelpers.taggedTemplateLiteral";

    // Build: tag(_templateObjectN || (_templateObjectN = babelHelpers.taggedTemplateLiteral([...], [...])), expr1, expr2, ...)
    buf.appendSlice(ctx.allocator, tag_src) catch return;
    buf.append(ctx.allocator, '(') catch return;

    buf.appendSlice(ctx.allocator, template_obj_name) catch return;
    buf.appendSlice(ctx.allocator, " || (") catch return;
    buf.appendSlice(ctx.allocator, template_obj_name) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    buf.appendSlice(ctx.allocator, helper_name) catch return;
    buf.append(ctx.allocator, '(') catch return;

    // Cooked array
    buf.append(ctx.allocator, '[') catch return;
    for (cooked_strings.items, 0..) |cooked, j| {
        if (j > 0) buf.appendSlice(ctx.allocator, ", ") catch return;
        switch (cooked) {
            .void_0 => buf.appendSlice(ctx.allocator, "void 0") catch return,
            .value => |v| {
                buf.append(ctx.allocator, '"') catch return;
                buf.appendSlice(ctx.allocator, v) catch return;
                buf.append(ctx.allocator, '"') catch return;
            },
        }
    }
    buf.append(ctx.allocator, ']') catch return;

    // Raw array (only if different from cooked)
    if (needs_raw) {
        buf.appendSlice(ctx.allocator, ", [") catch return;
        for (raw_strings.items, 0..) |raw, j| {
            if (j > 0) buf.appendSlice(ctx.allocator, ", ") catch return;
            buf.append(ctx.allocator, '"') catch return;
            buf.appendSlice(ctx.allocator, raw) catch return;
            buf.append(ctx.allocator, '"') catch return;
        }
        buf.append(ctx.allocator, ']') catch return;
    }

    buf.appendSlice(ctx.allocator, "))") catch return;

    // Expressions
    for (expr_sources.items) |expr_src| {
        buf.appendSlice(ctx.allocator, ", ") catch return;
        buf.appendSlice(ctx.allocator, expr_src) catch return;
    }

    buf.append(ctx.allocator, ')') catch return;

    ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch return;
}

// ── No-sub template handling ────────────────────────────────────────

fn handleNoSubTemplate(idx: NodeIndex, ctx: *TransformContext) !void {
    const i = @intFromEnum(idx);
    const mt = ctx.mainToken(idx);
    const tok_src = ctx.ast.tokenSlice(mt);

    // tok_src is like `foo` — extract the content between backticks
    if (tok_src.len < 2) return;
    const content = tok_src[1 .. tok_src.len - 1];

    // Convert to double-quoted string
    const cooked = try cookContent(ctx.allocator, content);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(ctx.allocator, '"');
    try buf.appendSlice(ctx.allocator, cooked);
    try buf.append(ctx.allocator, '"');
    ctx.ast.replacement_source.put(ctx.allocator, i, buf.items) catch {};
}

// ── Template object name allocation ─────────────────────────────────

var g_template_counter: u32 = 0;
var g_template_names: std.ArrayListUnmanaged([]const u8) = .empty;

pub fn resetState() void {
    g_template_counter = 0;
    g_template_names = .empty;
}

fn allocTemplateObjectName(ctx: *TransformContext) ![]const u8 {
    g_template_counter += 1;
    const name = if (g_template_counter == 1)
        try std.fmt.allocPrint(ctx.allocator, "_templateObject", .{})
    else
        try std.fmt.allocPrint(ctx.allocator, "_templateObject{d}", .{g_template_counter});
    g_template_names.append(ctx.allocator, name) catch {};
    return name;
}

/// Get the declaration string for all template objects.
/// Returns: "var _templateObject, _templateObject2;\n" or null.
pub fn getTemplateObjectDeclarations(allocator: std.mem.Allocator) ?[]const u8 {
    if (g_template_counter == 0) return null;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(allocator, "var ") catch return null;
    for (g_template_names.items, 0..) |name, j| {
        if (j > 0) buf.appendSlice(allocator, ", ") catch return null;
        buf.appendSlice(allocator, name) catch return null;
    }
    buf.appendSlice(allocator, ";\n") catch return null;
    return buf.items;
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Cooked value: either a valid string or void 0 (for invalid escapes).
const CookedValue = union(enum) {
    value: []const u8,
    void_0: void,
};

/// Get the "cooked" string content from a template token for untagged templates.
/// Returns the processed content (escape sequences resolved, newlines as \n).
fn getTemplateCookedString(ctx: *TransformContext, tok: TokenIndex) []const u8 {
    const tok_src = ctx.ast.tokenSlice(tok);
    const content = extractTemplateContent(ctx, tok, tok_src);
    return cookContent(ctx.allocator, content) catch "";
}

/// Get the cooked value for a tagged template quasi.
/// Returns void_0 for invalid escape sequences.
fn cookTemplateStringForTagged(allocator: std.mem.Allocator, tok_src: []const u8) CookedValue {
    const content = extractTemplateContentFromSrc(tok_src);
    // Check for invalid escape sequences
    if (hasInvalidEscape(content)) return .void_0;
    const cooked = cookContent(allocator, content) catch return .void_0;
    return .{ .value = cooked };
}

/// Extract the content portion from a template token source string.
fn extractTemplateContent(ctx: *TransformContext, tok: TokenIndex, tok_src: []const u8) []const u8 {
    _ = ctx;
    _ = tok;
    return extractTemplateContentFromSrc(tok_src);
}

fn extractTemplateContentFromSrc(tok_src: []const u8) []const u8 {
    if (tok_src.len < 2) return "";
    var start: usize = 0;
    var end: usize = tok_src.len;

    // Head: `text${  or no-sub: `text`
    // Middle: }text${
    // Tail: }text`
    if (tok_src[0] == '`' or tok_src[0] == '}') start = 1;
    if (tok_src[end - 1] == '`') {
        end -= 1;
    } else if (end >= 2 and tok_src[end - 1] == '{' and tok_src[end - 2] == '$') {
        end -= 2;
    }

    if (start >= end) return "";
    return tok_src[start..end];
}

/// Check if a template content string contains invalid escape sequences.
fn hasInvalidEscape(content: []const u8) bool {
    var pos: usize = 0;
    while (pos < content.len) {
        if (content[pos] == '\\') {
            pos += 1;
            if (pos >= content.len) return true;
            const c = content[pos];
            switch (c) {
                'x' => {
                    // \xHH — need exactly 2 hex digits
                    if (pos + 2 >= content.len or
                        !isHexDigit(content[pos + 1]) or
                        !isHexDigit(content[pos + 2]))
                    {
                        return true;
                    }
                    pos += 3;
                },
                'u' => {
                    pos += 1;
                    if (pos >= content.len) return true;
                    if (content[pos] == '{') {
                        // \u{XXXX} form
                        pos += 1;
                        var has_hex = false;
                        var valid = true;
                        while (pos < content.len and content[pos] != '}') {
                            if (!isHexDigit(content[pos])) {
                                valid = false;
                                break;
                            }
                            has_hex = true;
                            pos += 1;
                        }
                        if (!valid or !has_hex or pos >= content.len) return true;
                        pos += 1; // skip }
                    } else {
                        // \uXXXX form — need exactly 4 hex digits
                        var count: u32 = 0;
                        while (count < 4) : (count += 1) {
                            if (pos >= content.len or !isHexDigit(content[pos])) return true;
                            pos += 1;
                        }
                    }
                },
                '0' => {
                    // \0 followed by a digit is an octal escape (invalid in template)
                    pos += 1;
                    if (pos < content.len and content[pos] >= '0' and content[pos] <= '9') {
                        return true;
                    }
                },
                '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                    // Octal escapes are invalid in template literals
                    return true;
                },
                else => {
                    pos += 1;
                },
            }
        } else {
            pos += 1;
        }
    }
    return false;
}

/// Cook template content: process escape sequences, convert newlines to \n.
fn cookContent(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: usize = 0;

    while (pos < content.len) {
        const ch = content[pos];
        if (ch == '\\') {
            if (pos + 1 < content.len) {
                const next = content[pos + 1];
                switch (next) {
                    'n' => {
                        try buf.appendSlice(allocator, "\\n");
                        pos += 2;
                        continue;
                    },
                    't' => {
                        try buf.appendSlice(allocator, "\\t");
                        pos += 2;
                        continue;
                    },
                    'r' => {
                        try buf.appendSlice(allocator, "\\r");
                        pos += 2;
                        continue;
                    },
                    '\\' => {
                        try buf.appendSlice(allocator, "\\\\");
                        pos += 2;
                        continue;
                    },
                    '`' => {
                        try buf.append(allocator, '`');
                        pos += 2;
                        continue;
                    },
                    '"' => {
                        try buf.appendSlice(allocator, "\\\"");
                        pos += 2;
                        continue;
                    },
                    '\'' => {
                        try buf.append(allocator, '\'');
                        pos += 2;
                        continue;
                    },
                    '$' => {
                        try buf.append(allocator, '$');
                        pos += 2;
                        continue;
                    },
                    '0' => {
                        try buf.appendSlice(allocator, "\\0");
                        pos += 2;
                        continue;
                    },
                    '\n' => {
                        // Line continuation — skip both chars
                        pos += 2;
                        continue;
                    },
                    'u' => {
                        // Unicode escape — resolve it
                        const esc_result = resolveUnicodeEscape(content, pos + 2);
                        if (esc_result.codepoint) |cp| {
                            var utf8_buf: [4]u8 = undefined;
                            const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                                // Invalid codepoint, keep as-is
                                try buf.append(allocator, '\\');
                                try buf.append(allocator, 'u');
                                pos += 2;
                                continue;
                            };
                            // Emit the actual character(s)
                            try buf.appendSlice(allocator, utf8_buf[0..utf8_len]);
                            pos = esc_result.end_pos;
                            continue;
                        }
                        // Keep as-is
                        try buf.append(allocator, '\\');
                        try buf.append(allocator, next);
                        pos += 2;
                        continue;
                    },
                    'x' => {
                        // Hex escape \xHH
                        if (pos + 3 < content.len and
                            isHexDigit(content[pos + 2]) and isHexDigit(content[pos + 3]))
                        {
                            const val = (hexVal(content[pos + 2]) << 4) | hexVal(content[pos + 3]);
                            // Emit the character
                            try buf.append(allocator, @intCast(val));
                            pos += 4;
                            continue;
                        }
                        try buf.append(allocator, '\\');
                        try buf.append(allocator, next);
                        pos += 2;
                        continue;
                    },
                    else => {
                        // Keep other escape sequences as-is
                        try buf.append(allocator, '\\');
                        try buf.append(allocator, next);
                        pos += 2;
                        continue;
                    },
                }
            }
        }

        if (ch == '"') {
            try buf.appendSlice(allocator, "\\\"");
        } else if (ch == '\n') {
            try buf.appendSlice(allocator, "\\n");
        } else if (ch == '\r') {
            if (pos + 1 < content.len and content[pos + 1] == '\n') {
                try buf.appendSlice(allocator, "\\n");
                pos += 2;
                continue;
            }
            try buf.appendSlice(allocator, "\\n");
        } else {
            try buf.append(allocator, ch);
        }
        pos += 1;
    }

    return buf.items;
}

const UnicodeEscapeResult = struct {
    codepoint: ?u21 = null,
    end_pos: usize = 0,
};

fn resolveUnicodeEscape(content: []const u8, start: usize) UnicodeEscapeResult {
    var pos = start;
    if (pos >= content.len) return .{};

    if (content[pos] == '{') {
        // \u{XXXX} form
        pos += 1;
        var val: u32 = 0;
        var has_digits = false;
        while (pos < content.len and content[pos] != '}') {
            if (!isHexDigit(content[pos])) return .{};
            val = val * 16 + hexVal(content[pos]);
            has_digits = true;
            pos += 1;
        }
        if (!has_digits or pos >= content.len) return .{};
        pos += 1; // skip }
        if (val > 0x10FFFF) return .{};
        return .{ .codepoint = @intCast(val), .end_pos = pos };
    } else {
        // \uXXXX form
        var val: u32 = 0;
        var count: u32 = 0;
        while (count < 4 and pos < content.len) {
            if (!isHexDigit(content[pos])) return .{};
            val = val * 16 + hexVal(content[pos]);
            count += 1;
            pos += 1;
        }
        if (count < 4) return .{};
        // Check for surrogate pair (\uD800-\uDBFF followed by \uDC00-\uDFFF)
        if (val >= 0xD800 and val <= 0xDBFF) {
            // High surrogate — check for low surrogate
            if (pos + 5 < content.len and content[pos] == '\\' and content[pos + 1] == 'u') {
                var val2: u32 = 0;
                var count2: u32 = 0;
                var pos2 = pos + 2;
                while (count2 < 4 and pos2 < content.len) {
                    if (!isHexDigit(content[pos2])) break;
                    val2 = val2 * 16 + hexVal(content[pos2]);
                    count2 += 1;
                    pos2 += 1;
                }
                if (count2 == 4 and val2 >= 0xDC00 and val2 <= 0xDFFF) {
                    // Valid surrogate pair
                    const combined = 0x10000 + (val - 0xD800) * 0x400 + (val2 - 0xDC00);
                    return .{ .codepoint = @intCast(combined), .end_pos = pos2 };
                }
            }
        }
        if (val > 0x10FFFF) return .{};
        return .{ .codepoint = @intCast(val), .end_pos = pos };
    }
}

/// Get the raw string for a tagged template (preserving original escape sequences).
fn rawTemplateString(allocator: std.mem.Allocator, tok_src: []const u8) ![]const u8 {
    const content = extractTemplateContentFromSrc(tok_src);
    if (content.len == 0) return "";

    // For raw strings: double backslashes, escape quotes, convert newlines
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: usize = 0;

    while (pos < content.len) {
        const ch = content[pos];
        if (ch == '\\') {
            try buf.appendSlice(allocator, "\\\\");
            pos += 1;
            if (pos < content.len) {
                const next = content[pos];
                if (next == '\n') {
                    // \<newline> continuation
                    pos += 1;
                    continue;
                }
                if (next == '"') {
                    try buf.appendSlice(allocator, "\\\"");
                } else {
                    try buf.append(allocator, next);
                }
                pos += 1;
            }
            continue;
        }
        if (ch == '"') {
            try buf.appendSlice(allocator, "\\\"");
        } else if (ch == '\n') {
            try buf.appendSlice(allocator, "\\n");
        } else if (ch == '\r') {
            if (pos + 1 < content.len and content[pos + 1] == '\n') {
                try buf.appendSlice(allocator, "\\n");
                pos += 2;
                continue;
            }
            try buf.appendSlice(allocator, "\\n");
        } else {
            try buf.append(allocator, ch);
        }
        pos += 1;
    }

    return buf.items;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexVal(c: u8) u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

/// Get source text for a node, properly handling node_start_overrides.
fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return ctx.ast.source[start..end];
}

/// Get the true source start of a node.
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
        .tagged_template_expr => {
            const extra_idx_inner = @intFromEnum(data.extra);
            const tag_inner: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx_inner]);
            return getNodeStart(ctx, tag_inner);
        },
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

fn appendQuotedString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, content: []const u8) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, content);
    try buf.append(allocator, '"');
}
