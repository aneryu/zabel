const std = @import("std");
const Token = @import("token.zig").Token;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const ExtraIndex = @import("ast.zig").ExtraIndex;
const TokenIndex = @import("ast.zig").TokenIndex;
const Parser = @import("parser.zig").Parser;

const Error = Parser.ParseError;

/// Check if a token tag starts with `>` (the lexer may combine `>` with adjacent chars).
fn isGreaterThanFamily(tag: @import("token.zig").Token.Tag) bool {
    return tag == .greater_than or tag == .greater_greater or tag == .greater_greater_greater or
        tag == .greater_equal or tag == .greater_greater_equal or tag == .greater_greater_greater_equal;
}

/// Expect a `>` token in JSX context. The lexer may produce `>>`, `>>>`, `>=`, etc.
/// when `>` appears adjacent to another `>` or `=`. In JSX, we always want just `>`.
/// Returns the token index and the source position after the first `>` character.
fn expectJsxGt(p: *Parser) Error!struct { token: TokenIndex, end_pos: u32 } {
    // Handle pending `>` from type parameter `>>` splitting
    if (p.pending_greater_than > 0) {
        p.pending_greater_than -= 1;
        // The `>` we're consuming is one position after the split point
        // For `>>`, the token start is at pos N, first `>` is N..N+1, second `>` is N+1..N+2
        const prev_tok: TokenIndex = @enumFromInt(p.token_index -| 1);
        const prev_start = p.token_starts[@intFromEnum(prev_tok)];
        const prev_end = p.token_ends[@intFromEnum(prev_tok)];
        // The end of our virtual `>` is one position before the end of the original multi-char token
        // For `>>` (2 chars), our `>` starts at prev_start+1 and ends at prev_start+2
        const gt_end = prev_end - p.pending_greater_than;
        _ = prev_start;
        return .{ .token = prev_tok, .end_pos = gt_end };
    }
    if (isGreaterThanFamily(p.currentTag())) {
        const tok = p.advance();
        const start = p.token_starts[@intFromEnum(tok)];
        return .{ .token = tok, .end_pos = start + 1 };
    }
    const tok = try p.expect(.greater_than);
    return .{ .token = tok, .end_pos = p.token_ends[@intFromEnum(tok)] };
}

/// Mark a token as a JSX token type (0=jsxTagStart, 1=jsxTagEnd, 2=jsxName)
fn markJsxToken(p: *Parser, tok: @import("ast.zig").TokenIndex, jsx_type: u8) void {
    p.jsx_token_flags.put(p.allocator, @intFromEnum(tok), jsx_type) catch {};
}

/// Parse a JSX element or fragment starting from `<`.
/// Handles: `<div>...</div>`, `<Component />`, `<>...</>`
pub fn parseJsxElement(p: *Parser) Error!NodeIndex {
    const lt_token = p.advance(); // consume `<`
    markJsxToken(p, lt_token, 0); // jsxTagStart

    // Fragment: `<>...</>`
    if (p.currentTag() == .greater_than) {
        return parseJsxFragment(p, lt_token);
    }

    // Parse opening element name
    const name = try parseJsxElementName(p);

    // Parse type arguments in TSX/Flow mode: <Component<number> ...>
    var type_args: NodeIndex = .none;
    if (p.isTypeScript() and (p.currentTag() == .less_than or p.currentTag() == .less_less)) {
        const parser_ts = @import("parser_ts.zig");
        type_args = try parser_ts.parseTsTypeParameterInstantiation(p);
    } else if (p.isFlow() and (p.currentTag() == .less_than or p.currentTag() == .less_less)) {
        const flow_mod = @import("parser_flow.zig");
        type_args = try flow_mod.parseFlowTypeParameterInstantiation(p);
    }

    // Parse attributes
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (!isGreaterThanFamily(p.currentTag()) and
        p.currentTag() != .slash and
        p.currentTag() != .eof and
        p.pending_greater_than == 0)
    {
        const attr = try parseJsxAttribute(p);
        try p.scratch.append(p.allocator, attr);
    }

    const attrs = p.scratch.items[scratch_start..];
    const attr_range = try p.addExtraRange(attrs);

    // Self-closing: `<name ... />`
    if (p.currentTag() == .slash and p.pending_greater_than == 0) {
        _ = p.advance(); // consume `/`
        const gt_tok = try p.expect(.greater_than);
        markJsxToken(p, gt_tok, 1); // jsxTagEnd

        // Store: name, attr_range_start, attr_range_end
        const extra_start = try p.addExtra(@intFromEnum(name));
        _ = try p.addExtra(attr_range.start);
        _ = try p.addExtra(attr_range.end);

        const self_closing_node = try p.addNode(.{
            .tag = .jsx_self_closing_element,
            .main_token = lt_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        if (type_args != .none) {
            try p.putTypeParameters(self_closing_node, type_args);
        }
        return self_closing_node;
    }

    // Opening element: `<name ...>`
    // Use JSX-aware `>` consumption — the lexer may combine `>` with adjacent `>` chars
    const gt_result = try expectJsxGt(p);
    markJsxToken(p, gt_result.token, 1); // jsxTagEnd
    const after_open_tag_pos = gt_result.end_pos;

    // Store opening element info
    const opening_extra = try p.addExtra(@intFromEnum(name));
    _ = try p.addExtra(attr_range.start);
    _ = try p.addExtra(attr_range.end);

    const opening = try p.addNode(.{
        .tag = .jsx_opening_element,
        .main_token = lt_token,
        .data = .{ .extra = @enumFromInt(opening_extra) },
    });
    // Fix end_offset: the JSX-aware `>` may have consumed a multi-character token (e.g., `>>`)
    // but the opening element should end at the first `>` character only
    p.nodes.items(.end_offset)[@intFromEnum(opening)] = after_open_tag_pos;
    if (type_args != .none) {
        try p.putTypeParameters(opening, type_args);
    }

    // Parse children (including JSXText nodes for text gaps)
    const children_scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(children_scratch_start);

    try parseJsxChildren(p, after_open_tag_pos);

    const children = p.scratch.items[children_scratch_start..];
    const children_range = try p.addExtraRange(children);

    // Parse closing element: `</name>` or `</>` with error recovery
    const closing_lt = try p.expect(.less_than);
    markJsxToken(p, closing_lt, 0); // jsxTagStart
    _ = try p.expect(.slash);

    var closing: NodeIndex = undefined;
    if (p.currentTag() == .greater_than) {
        // Error recovery: `<name></>`  — fragment closing for named element
        p.errors.addError("Expected corresponding JSX closing tag for element.", p.token_starts[@intFromEnum(closing_lt)]);
        const closing_gt = p.advance(); // consume `>`
        markJsxToken(p, closing_gt, 1); // jsxTagEnd
        closing = try p.addNode(.{
            .tag = .jsx_closing_fragment,
            .main_token = closing_lt,
            .data = .{ .none = {} },
        });
    } else {
        const closing_name = try parseJsxElementName(p);
        const closing_gt = try p.expect(.greater_than);
        markJsxToken(p, closing_gt, 1); // jsxTagEnd
        closing = try p.addNode(.{
            .tag = .jsx_closing_element,
            .main_token = closing_lt,
            .data = .{ .unary = closing_name },
        });
    }

    // JSX element: opening, closing, children range
    const elem_extra = try p.addExtra(@intFromEnum(opening));
    _ = try p.addExtra(@intFromEnum(closing));
    _ = try p.addExtra(children_range.start);
    _ = try p.addExtra(children_range.end);

    return p.addNode(.{
        .tag = .jsx_element,
        .main_token = lt_token,
        .data = .{ .extra = @enumFromInt(elem_extra) },
    });
}

/// Parse a JSX fragment: `<>children</>`
fn parseJsxFragment(p: *Parser, lt_token: TokenIndex) Error!NodeIndex {
    const gt_token = p.advance(); // consume `>` (of `<>`)
    const after_open_tag_pos = p.token_ends[@intFromEnum(gt_token)];

    const opening = try p.addNode(.{
        .tag = .jsx_opening_fragment,
        .main_token = lt_token,
        .data = .{ .none = {} },
    });

    // Parse children (including JSXText nodes for text gaps)
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    try parseJsxChildren(p, after_open_tag_pos);

    const children = p.scratch.items[scratch_start..];
    const children_range = try p.addExtraRange(children);

    // `</>`  (or `</name>` with error recovery for mismatched tags)
    const closing_lt = try p.expect(.less_than);
    _ = try p.expect(.slash);

    var closing: NodeIndex = undefined;
    if (p.currentTag() == .greater_than) {
        // Normal case: `</>`
        _ = p.advance();
        closing = try p.addNode(.{
            .tag = .jsx_closing_fragment,
            .main_token = closing_lt,
            .data = .{ .none = {} },
        });
    } else if (p.currentTag() == .identifier or p.currentTag().isKeyword()) {
        // Error recovery: `<></name>` — wrong closing tag for fragment
        // Babel produces: error + JSXFragment with closingFragment being a JSXClosingElement
        p.errors.addError("Expected corresponding JSX closing tag for <>.", p.token_starts[@intFromEnum(lt_token)]);
        const closing_name = try parseJsxElementName(p);
        _ = try p.expect(.greater_than);
        closing = try p.addNode(.{
            .tag = .jsx_closing_element,
            .main_token = closing_lt,
            .data = .{ .unary = closing_name },
        });
    } else {
        _ = try p.expect(.greater_than);
        closing = try p.addNode(.{
            .tag = .jsx_closing_fragment,
            .main_token = closing_lt,
            .data = .{ .none = {} },
        });
    }

    // Fragment: opening, closing, children range
    const elem_extra = try p.addExtra(@intFromEnum(opening));
    _ = try p.addExtra(@intFromEnum(closing));
    _ = try p.addExtra(children_range.start);
    _ = try p.addExtra(children_range.end);

    return p.addNode(.{
        .tag = .jsx_fragment,
        .main_token = lt_token,
        .data = .{ .extra = @enumFromInt(elem_extra) },
    });
}

/// Check if the current token is immediately adjacent to the previous token (no whitespace).
fn isAdjacentToken(p: *const Parser) bool {
    if (p.token_index == 0) return false;
    return p.token_ends[p.token_index - 1] == p.token_starts[p.token_index];
}

/// Consume a JSX identifier, including hyphens: `abc-def-ghi` is one identifier.
/// Returns the first token of the identifier (the rest are consumed).
fn consumeJsxIdentifier(p: *Parser) TokenIndex {
    const first_token = p.advance();
    markJsxToken(p, first_token, 2); // jsxName
    // Consume hyphenated parts: `-identifier` with no whitespace
    while (p.currentTag() == .minus and isAdjacentToken(p)) {
        _ = p.advance(); // consume `-`
        if ((p.currentTag() == .identifier or p.currentTag().isKeyword()) and isAdjacentToken(p)) {
            _ = p.advance(); // consume the next part
        } else {
            break;
        }
    }
    return first_token;
}

/// Parse a JSX element name: identifier, member expression, or namespaced name.
fn parseJsxElementName(p: *Parser) Error!NodeIndex {
    // Accept identifiers and keywords as JSX tag names
    if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
        p.errors.addError("expected JSX element name", p.currentStart());
        return error.ParseError;
    }

    // Validate: JSX identifiers must not contain unicode escape sequences
    {
        const ident_start = p.token_starts[p.token_index];
        if (ident_start < p.source.len and p.source[ident_start] == '\\') {
            p.errors.addError("Unexpected token", ident_start);
            return error.ParseError;
        }
    }

    const first_token = consumeJsxIdentifier(p);
    var name = try p.addNode(.{
        .tag = .jsx_identifier,
        .main_token = first_token,
        .data = .{ .none = {} },
    });

    // Member expression: `a.b.c`
    while (p.currentTag() == .dot) {
        _ = p.advance(); // consume `.`
        if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
            p.errors.addError("expected identifier after '.'", p.currentStart());
            return error.ParseError;
        }
        const prop_token = consumeJsxIdentifier(p);
        const prop = try p.addNode(.{
            .tag = .jsx_identifier,
            .main_token = prop_token,
            .data = .{ .none = {} },
        });

        name = try p.addNode(.{
            .tag = .jsx_member_expression,
            .main_token = first_token,
            .data = .{ .binary = .{ .lhs = name, .rhs = prop } },
        });
    }

    // Namespaced name: `a:b` (not allowed after member expression: `a.b:c` is invalid)
    if (p.currentTag() == .colon) {
        // Check if 'name' is a member expression — reject if so
        const name_tag = p.nodes.items(.tag)[@intFromEnum(name)];
        if (name_tag == .jsx_member_expression) {
            p.errors.addError("Unexpected token", p.currentStart());
            return error.ParseError;
        }
        _ = p.advance(); // consume `:`
        if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
            p.errors.addError("expected identifier after ':'", p.currentStart());
            return error.ParseError;
        }
        const ns_token = consumeJsxIdentifier(p);
        const ns_name = try p.addNode(.{
            .tag = .jsx_identifier,
            .main_token = ns_token,
            .data = .{ .none = {} },
        });

        name = try p.addNode(.{
            .tag = .jsx_namespaced_name,
            .main_token = first_token,
            .data = .{ .binary = .{ .lhs = name, .rhs = ns_name } },
        });
    }

    return name;
}

/// Parse a single JSX attribute or spread attribute.
fn parseJsxAttribute(p: *Parser) Error!NodeIndex {
    // Spread: `{...expr}`
    if (p.currentTag() == .l_brace) {
        const brace_token = p.advance();
        _ = try p.expect(.ellipsis);
        const expr = try p.parseAssignmentExpression();
        _ = try p.expect(.r_brace);
        return p.addNode(.{
            .tag = .jsx_spread_attribute,
            .main_token = brace_token,
            .data = .{ .unary = expr },
        });
    }

    // Normal attribute: `name` or `name=value` or `name:ns=value`
    if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
        p.errors.addError("expected attribute name", p.currentStart());
        return error.ParseError;
    }

    const name_token = consumeJsxIdentifier(p);
    var attr_name = try p.addNode(.{
        .tag = .jsx_identifier,
        .main_token = name_token,
        .data = .{ .none = {} },
    });

    // Namespaced attribute: `ns:name`
    if (p.currentTag() == .colon) {
        _ = p.advance();
        if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
            p.errors.addError("expected identifier after ':'", p.currentStart());
            return error.ParseError;
        }
        const ns_token = consumeJsxIdentifier(p);
        const ns_name = try p.addNode(.{
            .tag = .jsx_identifier,
            .main_token = ns_token,
            .data = .{ .none = {} },
        });
        attr_name = try p.addNode(.{
            .tag = .jsx_namespaced_name,
            .main_token = name_token,
            .data = .{ .binary = .{ .lhs = attr_name, .rhs = ns_name } },
        });
    }

    // Value: `=value`
    var value: NodeIndex = .none;
    if (p.currentTag() == .equal) {
        _ = p.advance(); // consume `=`
        value = try parseJsxAttributeValue(p);
    }

    return p.addNode(.{
        .tag = .jsx_attribute,
        .main_token = name_token,
        .data = .{ .binary = .{ .lhs = attr_name, .rhs = value } },
    });
}

/// Parse a JSX attribute value: string literal, expression container, or JSX element.
fn parseJsxAttributeValue(p: *Parser) Error!NodeIndex {
    switch (p.currentTag()) {
        .string => {
            const tok = p.advance();
            return p.addNode(.{ .tag = .jsx_string_literal, .main_token = tok, .data = .{ .none = {} } });
        },
        .l_brace => {
            return parseJsxExpressionContainer(p);
        },
        .less_than => {
            return parseJsxElement(p);
        },
        else => {
            p.errors.addError("expected JSX attribute value", p.currentStart());
            return error.ParseError;
        },
    }
}

/// Parse a JSX expression container: `{expr}` or `{}`
fn parseJsxExpressionContainer(p: *Parser) Error!NodeIndex {
    const brace_token = p.advance(); // consume `{`

    if (p.currentTag() == .r_brace) {
        // Empty expression: `{}`
        const empty = try p.addNode(.{
            .tag = .jsx_empty_expression,
            .main_token = brace_token,
            .data = .{ .none = {} },
        });
        _ = p.advance(); // consume `}`
        return p.addNode(.{
            .tag = .jsx_expression_container,
            .main_token = brace_token,
            .data = .{ .unary = empty },
        });
    }

    // Spread child: `{...expr}` in children position
    if (p.currentTag() == .ellipsis) {
        _ = p.advance(); // consume `...`
        const expr = try p.parseAssignmentExpression();
        _ = try p.expect(.r_brace);
        return p.addNode(.{
            .tag = .jsx_spread_child,
            .main_token = brace_token,
            .data = .{ .unary = expr },
        });
    }

    const expr = try p.parseExpression();
    _ = try p.expect(.r_brace);

    return p.addNode(.{
        .tag = .jsx_expression_container,
        .main_token = brace_token,
        .data = .{ .unary = expr },
    });
}

/// Create a JSXText node for a range of source text.
/// Uses data.extra to store [source_start, source_end] in extra_data.
fn addJsxTextNode(p: *Parser, text_start: u32, text_end: u32, anchor_token: TokenIndex) Error!NodeIndex {
    if (text_start >= text_end) return .none;
    const extra_start = try p.addExtra(text_start);
    _ = try p.addExtra(text_end);
    var node = Node{
        .tag = .jsx_text,
        .main_token = anchor_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    };
    node.end_offset = text_end;
    const idx: u32 = @intCast(p.nodes.len);
    try p.nodes.append(p.allocator, node);
    return @enumFromInt(idx);
}

/// Scan raw source from `pos` to find the next `<` or `{` character.
/// Returns the index of the delimiter, or source.len if none found.
fn findNextJsxChildBoundary(source: []const u8, pos: u32) u32 {
    var i: u32 = pos;
    while (i < source.len) : (i += 1) {
        if (source[i] == '<' or source[i] == '{') return i;
    }
    return @intCast(source.len);
}

/// Advance the token index so the current token starts at or after `target_pos`.
fn syncTokenIndexTo(p: *Parser, target_pos: u32) void {
    while (p.token_index < p.token_starts.len) {
        if (p.token_starts[p.token_index] >= target_pos) break;
        p.token_index += 1;
    }
}

/// Parse JSX children, inserting JSXText nodes for text gaps between children.
/// Uses raw source scanning to find child boundaries (`<` and `{`) rather than
/// relying on the lexer, which can misinterpret JSX text content (e.g., `'`, `>`).
fn parseJsxChildren(p: *Parser, after_open_tag_pos: u32) Error!void {
    var pos: u32 = after_open_tag_pos;

    while (pos < p.source.len) {
        // Scan raw source for next child boundary
        const boundary = findNextJsxChildBoundary(p.source, pos);

        // Emit any text before the boundary as JSXText
        if (boundary > pos) {
            const text_node = try addJsxTextNode(p, pos, boundary, @enumFromInt(@min(p.token_index, @as(u32, @intCast(p.token_starts.len - 1)))));
            if (text_node != .none) try p.scratch.append(p.allocator, text_node);
        }

        if (boundary >= p.source.len) break;

        // Sync token index to the boundary position
        syncTokenIndexTo(p, boundary);

        const child: ?NodeIndex = if (p.source[boundary] == '<') blk: {
            // Check for closing tag `</`
            if (boundary + 1 < p.source.len and p.source[boundary + 1] == '/') {
                pos = boundary;
                break :blk null; // signal to break outer loop
            }
            break :blk try parseJsxElement(p);
        } else if (p.source[boundary] == '{') blk: {
            break :blk try parseJsxExpressionContainer(p);
        } else break;

        if (child) |c| {
            // Null child signals closing tag; break was already handled above
            if (c != .none) try p.scratch.append(p.allocator, c);
            pos = if (p.token_index > 0) p.token_ends[p.token_index - 1] else boundary + 1;
        } else break; // closing tag found
    }

    // Sync token index to closing tag position
    syncTokenIndexTo(p, pos);
}
