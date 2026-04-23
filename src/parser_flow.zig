const std = @import("std");
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const TokenIndex = @import("ast.zig").TokenIndex;
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;

const Error = Parser.Error;

/// Sentinel for "no token" in extra data (token index 0 is always valid, but
/// we use 0 as a sentinel to mean "absent" for optional tokens like source in
/// declare export).
const no_token: TokenIndex = @enumFromInt(0);

// ============================================================================
// Flow Type Parsing
// ============================================================================

/// Parse a Flow type annotation (the full type after `:`)
/// Returns a flow_type_annotation wrapper node
/// Callers that need to suppress anonymous function-type parsing for
/// disambiguation must do so explicitly via `flow_no_anon_function_type`
/// before calling this helper.
pub fn parseFlowTypeAnnotation(p: *Parser) Error!NodeIndex {
    const colon_token = try p.expect(.colon);
    const ty = try parseFlowType(p);
    // If a pending_equal was set during type parsing (e.g. `*=` split into `*` + `=`),
    // the type's end_offset reflects the split position. We need to use that for the
    // annotation node's end, since addNode would use the full `*=` token end.
    const use_ty_end = p.pending_equal;
    const node = try p.addNode(.{
        .tag = .flow_type_annotation,
        .main_token = colon_token,
        .data = .{ .unary = ty },
    });
    if (use_ty_end) {
        const ty_end = p.nodes.items(.end_offset)[@intFromEnum(ty)];
        if (ty_end > 0) {
            p.nodes.items(.end_offset)[@intFromEnum(node)] = ty_end;
        }
    }
    return node;
}

/// Parse a Flow arrow return type annotation (`: T`) while suppressing
/// anonymous function types like `T => U`, which would otherwise consume
/// the outer arrow function's `=>`.
pub fn parseFlowArrowReturnTypeAnnotation(p: *Parser) Error!NodeIndex {
    const saved_no_anon = p.flow_no_anon_function_type;
    p.flow_no_anon_function_type = true;
    defer p.flow_no_anon_function_type = saved_no_anon;
    return parseFlowTypeAnnotation(p);
}

/// Parse a Flow type (union level — top-level type)
pub fn parseFlowType(p: *Parser) Error!NodeIndex {
    // Handle leading `|` for union types: `| A | B`
    const leading_pipe: ?TokenIndex = if (p.currentTag() == .pipe)
        p.advance()
    else
        null;

    const first = try parseFlowIntersectionType(p);
    if (p.currentTag() != .pipe or
        (p.currentTag() == .pipe and p.lookAhead(1) == .r_brace))
    {
        // If there was a leading pipe but no subsequent pipes, it's still just one type
        // but position needs to be the pipe for consistency.
        // Also stop before `|}` which is the closing delimiter of an exact object type.
        return first;
    }

    // Union type: A | B | C
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);
    try p.scratch.append(p.allocator, first);
    while (p.currentTag() == .pipe and p.lookAhead(1) != .r_brace and p.eat(.pipe) != null) {
        const next = try parseFlowIntersectionType(p);
        try p.scratch.append(p.allocator, next);
    }
    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    return p.addNode(.{
        .tag = .flow_union_type,
        .main_token = leading_pipe orelse @enumFromInt(p.token_index),
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse intersection type: A & B & C
fn parseFlowIntersectionType(p: *Parser) Error!NodeIndex {
    // Handle leading `&` for intersection types: `& A & B`
    const leading_amp: ?TokenIndex = if (p.currentTag() == .ampersand)
        p.advance()
    else
        null;

    const first = try parseFlowPrimaryType(p);
    if (p.currentTag() != .ampersand) return first;

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);
    try p.scratch.append(p.allocator, first);
    while (p.eat(.ampersand) != null) {
        const next = try parseFlowPrimaryType(p);
        try p.scratch.append(p.allocator, next);
    }
    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    return p.addNode(.{
        .tag = .flow_intersection_type,
        .main_token = leading_amp orelse @enumFromInt(p.token_index),
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse a postfix type: T[], T?.[K], T[K]
fn parseFlowPostfixType(p: *Parser, base: NodeIndex) Error!NodeIndex {
    var result = base;
    var in_optional_chain = false;
    while (true) {
        if (p.currentTag() == .l_bracket and !p.hasNewlineBefore()) {
            // T[] or T[K]
            const bracket_token = p.advance(); // [
            if (p.currentTag() == .r_bracket) {
                _ = p.advance(); // ]
                result = try p.addNode(.{
                    .tag = .flow_array_type,
                    .main_token = bracket_token,
                    .data = .{ .unary = result },
                });
                in_optional_chain = false; // array postfix breaks optional chain
            } else {
                const index_type = try parseFlowType(p);
                _ = try p.expect(.r_bracket);
                const extra_start = try p.addExtra(@intFromEnum(result));
                _ = try p.addExtra(@intFromEnum(index_type));
                if (in_optional_chain) {
                    // Inside an optional chain: T?.[K1][K2] — [K2] is OptionalIndexedAccessType with optional=false
                    result = try p.addNode(.{
                        .tag = .flow_optional_indexed_access_type,
                        .main_token = bracket_token,
                        .data = .{ .extra = @enumFromInt(extra_start) },
                    });
                } else {
                    result = try p.addNode(.{
                        .tag = .flow_indexed_access_type,
                        .main_token = bracket_token,
                        .data = .{ .extra = @enumFromInt(extra_start) },
                    });
                }
            }
        } else if (p.currentTag() == .optional_chain) {
            // T?.[K]
            const opt_token = p.advance(); // ?.
            _ = try p.expect(.l_bracket);
            const index_type = try parseFlowType(p);
            _ = try p.expect(.r_bracket);
            const extra_start = try p.addExtra(@intFromEnum(result));
            _ = try p.addExtra(@intFromEnum(index_type));
            result = try p.addNode(.{
                .tag = .flow_optional_indexed_access_type,
                .main_token = opt_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
            in_optional_chain = true;
        } else {
            break;
        }
    }
    return result;
}

/// Parse a primary type without checking for no-parens function type arrow.
/// Used internally by nullable and other prefix type parsers to avoid
/// prematurely consuming `=>` that belongs to the outer context.
fn parseFlowPrimaryTypeNoArrow(p: *Parser) Error!NodeIndex {
    var result = try parseFlowPrimaryTypeInner(p);
    result = try parseFlowPostfixType(p, result);
    return result;
}

/// Parse primary type (non-union, non-intersection)
/// Also handles no-parens anonymous function types: `T => U`
fn parseFlowPrimaryType(p: *Parser) Error!NodeIndex {
    const start_tok_idx: TokenIndex = @enumFromInt(p.token_index);
    const result = try parseFlowPrimaryTypeNoArrow(p);

    // Check for no-parens function type: `Type => ReturnType`
    // Only in contexts where this is valid (not after `:` in return type annotations)
    if (p.currentTag() == .arrow and !p.flow_no_anon_function_type) {
        return parseFlowNoParensFunctionType(p, result, start_tok_idx);
    }

    return result;
}

/// Parse no-parens anonymous function type: `Type => ReturnType`
/// The param_type has already been parsed and is passed in.
fn parseFlowNoParensFunctionType(p: *Parser, param_type: NodeIndex, start_token: TokenIndex) Error!NodeIndex {
    _ = p.advance(); // =>

    // Save end position after `=>` for param end (Babel includes `=>` in param span)
    const param_end = p.token_ends[p.token_index - 1];

    // Create the param BEFORE parsing return type to get correct end position
    const param_extra = try p.addExtra(@intFromEnum(param_type));
    _ = try p.addExtra(@as(u32, 2)); // unnamed (bit 1)
    const param = try p.addNode(.{
        .tag = .flow_function_type_param,
        .main_token = start_token,
        .data = .{ .extra = @enumFromInt(param_extra) },
    });
    // Override the auto-set end_offset to end at `=>`, not at current position
    p.nodes.items(.end_offset)[@intFromEnum(param)] = param_end;

    // The return type is a full type (can include unions)
    const return_type = try parseFlowType(p);

    // Build function type with one param, no rest, no type params, no this
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);
    try p.scratch.append(p.allocator, param);

    const params = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(params);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    _ = try p.addExtra(@intFromEnum(return_type));
    _ = try p.addExtra(@intFromEnum(@as(NodeIndex, .none))); // no rest
    _ = try p.addExtra(@intFromEnum(@as(NodeIndex, .none))); // no type params
    _ = try p.addExtra(@intFromEnum(@as(NodeIndex, .none))); // no this

    return p.addNode(.{
        .tag = .flow_function_type_annotation,
        .main_token = start_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn parseFlowPrimaryTypeInner(p: *Parser) Error!NodeIndex {
    // Handle pending_less_than: the second `<` from a `<<` split starts a generic function type
    if (p.pending_less_than) {
        return parseFlowFunctionTypeParams(p);
    }
    switch (p.currentTag()) {
        .question => {
            // ?Type — nullable type
            // Use parseFlowPrimaryTypeNoArrow to prevent `?T => U` from
            // becoming `?(T => U)` instead of `(?T) => U`
            const q_token = p.advance();
            const inner = try parseFlowPrimaryTypeNoArrow(p);
            return p.addNode(.{
                .tag = .flow_nullable_type,
                .main_token = q_token,
                .data = .{ .unary = inner },
            });
        },
        .question_question => {
            // ??Type — double nullable: split `??` into two `?` nullable types
            const qq_token = p.advance();
            const qq_start = p.token_starts[@intFromEnum(qq_token)];
            const inner = try parseFlowPrimaryTypeNoArrow(p);
            // Inner nullable uses the second `?` position (qq_start + 1)
            const inner_nullable = try p.addNode(.{
                .tag = .flow_nullable_type,
                .main_token = qq_token,
                .data = .{ .unary = inner },
            });
            // Override start position for inner nullable to second `?`
            try p.node_start_overrides.put(p.allocator, @intFromEnum(inner_nullable), qq_start + 1);
            // Outer nullable uses the first `?` (qq_token) — default start is correct
            const outer = try p.addNode(.{
                .tag = .flow_nullable_type,
                .main_token = qq_token,
                .data = .{ .unary = inner_nullable },
            });
            return outer;
        },
        .kw_typeof => {
            // typeof expr
            const typeof_token = p.advance();
            const inner = try parseFlowTypeofTarget(p);
            return p.addNode(.{
                .tag = .flow_typeof_type,
                .main_token = typeof_token,
                .data = .{ .unary = inner },
            });
        },
        .asterisk => {
            // Exists type: *
            const star_token = p.advance();
            return p.addNode(.{
                .tag = .flow_exists_type,
                .main_token = star_token,
                .data = .{ .none = {} },
            });
        },
        .asterisk_equal => {
            // Exists type followed by `=`: split `*=` into `*` + `=`
            // e.g. `field:*=null` → type is `*`, initializer is `=null`
            const star_token = p.advance();
            p.pending_equal = true;
            const node = try p.addNode(.{
                .tag = .flow_exists_type,
                .main_token = star_token,
                .data = .{ .none = {} },
            });
            // Fix end position: the exists type ends at star_token start + 1 (just the `*`)
            p.nodes.items(.end_offset)[@intFromEnum(node)] = p.token_starts[@intFromEnum(star_token)] + 1;
            return node;
        },
        .kw_void => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .flow_void_type,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .kw_null => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .flow_null_literal_type,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .kw_true, .kw_false => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .flow_boolean_literal_type,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .kw_this => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .flow_this_type_annotation,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .kw_function, .kw_var => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .identifier,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .numeric => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .flow_number_literal_type,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .string => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .flow_string_literal_type,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .bigint => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .flow_bigint_literal_type,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .minus => {
            // Negative numeric/bigint literal type: -1, -1n
            const minus_tok = p.advance();
            if (p.currentTag() == .bigint) {
                _ = p.advance();
                return p.addNode(.{
                    .tag = .flow_bigint_literal_type,
                    .main_token = minus_tok,
                    .data = .{ .none = {} },
                });
            }
            if (p.currentTag() == .numeric) {
                _ = p.advance();
                return p.addNode(.{
                    .tag = .flow_number_literal_type,
                    .main_token = minus_tok,
                    .data = .{ .none = {} },
                });
            }
            p.errors.addError("unexpected token in type", p.currentStart());
            return error.ParseError;
        },
        .l_bracket => {
            // Tuple type: [A, B, C]
            return parseFlowTupleType(p);
        },
        .l_brace => {
            // Object type: { ... } or exact {| ... |}
            return parseFlowObjectType(p);
        },
        // Leading pipe/ampersand are now handled by parseFlowType/parseFlowIntersectionType
        .l_paren => {
            // Could be function type or parenthesized type
            return parseFlowParenthesizedOrFunctionType(p);
        },
        .less_than => {
            // Generic function type: <T>(x: T) => T
            return parseFlowFunctionTypeParams(p);
        },
        .identifier => {
            // Check for `interface` keyword (it's an identifier, not a keyword)
            const id_text = p.tokenText(p.token_index);
            if (std.mem.eql(u8, id_text, "interface")) {
                return parseFlowAnonymousInterfaceType(p);
            }
            return parseFlowIdentifierType(p);
        },
        else => {
            p.errors.addError("unexpected token in type", p.currentStart());
            return error.ParseError;
        },
    }
}

/// Parse typeof target (identifier with optional member access)
fn parseFlowTypeofTarget(p: *Parser) Error!NodeIndex {
    const tok = p.advance(); // identifier
    if (isInvalidSimpleTypeofName(p.tokenText(@intFromEnum(tok)))) {
        p.errors.addError(
            if (decodedIdentifierEquals(p.tokenText(@intFromEnum(tok)), "typeof"))
                "Unexpected reserved word typeof."
            else
                "Unexpected reserved type interface.",
            p.token_starts[@intFromEnum(tok)],
        );
    }
    var result = try p.addNode(.{
        .tag = .identifier,
        .main_token = tok,
        .data = .{ .none = {} },
    });

    while (p.currentTag() == .dot) {
        _ = p.advance(); // .
        const member_tok = p.advance(); // identifier
        if (isInvalidQualifiedTypeofName(p.tokenText(@intFromEnum(member_tok)))) {
            const member_text = if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "interface"))
                "interface"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "number"))
                "number"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "string"))
                "string"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "boolean"))
                "boolean"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "bool"))
                "bool"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "empty"))
                "empty"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "mixed"))
                "mixed"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "null"))
                "null"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "true"))
                "true"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "false"))
                "false"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "void"))
                "void"
            else if (decodedIdentifierEquals(p.tokenText(@intFromEnum(member_tok)), "any"))
                "any"
            else
                "typeof";
            var msg_buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Unexpected reserved type {s}.", .{member_text}) catch "Unexpected reserved type.";
            p.errors.addError(msg, p.token_starts[@intFromEnum(member_tok)]);
        }
        const extra_start = try p.addExtra(@intFromEnum(result));
        _ = try p.addExtra(@intFromEnum(@as(NodeIndex, @enumFromInt(@intFromEnum(member_tok)))));
        result = try p.addNode(.{
            .tag = .flow_qualified_type_identifier,
            .main_token = member_tok,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    // Type arguments after qualified name: typeof A.B<T>
    if (p.currentTag() == .less_than) {
        const type_args = try parseFlowTypeParameterInstantiation(p);
        const gt_end = p.split_greater_end;
        const extra_start = try p.addExtra(@intFromEnum(result));
        _ = try p.addExtra(@intFromEnum(type_args));
        const node = try p.addNode(.{
            .tag = .flow_generic_type,
            .main_token = tok, // Use the first identifier token for correct start position
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        if (gt_end > 0) {
            p.nodes.items(.end_offset)[@intFromEnum(node)] = gt_end;
            p.split_greater_end = 0;
        }
        result = node;
    }
    return result;
}

fn isInvalidSimpleTypeofName(raw: []const u8) bool {
    return decodedIdentifierEquals(raw, "interface") or decodedIdentifierEquals(raw, "typeof");
}

fn isInvalidQualifiedTypeofName(raw: []const u8) bool {
    return decodedIdentifierEquals(raw, "interface") or
        decodedIdentifierEquals(raw, "typeof") or
        decodedIdentifierEquals(raw, "any") or
        decodedIdentifierEquals(raw, "bool") or
        decodedIdentifierEquals(raw, "boolean") or
        decodedIdentifierEquals(raw, "empty") or
        decodedIdentifierEquals(raw, "mixed") or
        decodedIdentifierEquals(raw, "null") or
        decodedIdentifierEquals(raw, "number") or
        decodedIdentifierEquals(raw, "string") or
        decodedIdentifierEquals(raw, "true") or
        decodedIdentifierEquals(raw, "false") or
        decodedIdentifierEquals(raw, "void");
}

pub fn decodedIdentifierEquals(raw: []const u8, expected: []const u8) bool {
    var raw_i: usize = 0;
    var exp_i: usize = 0;

    while (raw_i < raw.len and exp_i < expected.len) {
        if (raw[raw_i] == '\\' and raw_i + 1 < raw.len and raw[raw_i + 1] == 'u') {
            raw_i += 2;
            const cp = decodeIdentifierEscape(raw, &raw_i) orelse return false;
            var utf8_buf: [4]u8 = undefined;
            const cp_len = std.unicode.utf8Encode(cp, &utf8_buf) catch return false;
            if (exp_i + cp_len > expected.len) return false;
            if (!std.mem.eql(u8, utf8_buf[0..cp_len], expected[exp_i .. exp_i + cp_len])) return false;
            exp_i += cp_len;
            continue;
        }
        if (raw[raw_i] != expected[exp_i]) return false;
        raw_i += 1;
        exp_i += 1;
    }

    return raw_i == raw.len and exp_i == expected.len;
}

fn decodeIdentifierEscape(raw: []const u8, index: *usize) ?u21 {
    if (index.* >= raw.len) return null;
    if (raw[index.*] == '{') {
        index.* += 1;
        const hex_start = index.*;
        while (index.* < raw.len and raw[index.*] != '}') : (index.* += 1) {}
        if (index.* >= raw.len or index.* == hex_start) return null;
        const hex = raw[hex_start..index.*];
        index.* += 1;
        return parseEscapedCodePoint(hex);
    }

    if (index.* + 4 > raw.len) return null;
    const hex = raw[index.* .. index.* + 4];
    index.* += 4;
    return parseEscapedCodePoint(hex);
}

fn parseEscapedCodePoint(hex: []const u8) ?u21 {
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    for (hex) |c| {
        if (c == '_') continue;
        if (!std.ascii.isHex(c)) return null;
        if (len >= buf.len) return null;
        buf[len] = c;
        len += 1;
    }
    if (len == 0) return null;
    return std.fmt.parseInt(u21, buf[0..len], 16) catch null;
}

/// Parse an identifier-based type: number, string, boolean, mixed, any, empty, symbol, Foo, Foo.Bar, Foo<T>
fn parseFlowIdentifierType(p: *Parser) Error!NodeIndex {
    const id_token = p.advance();
    const text = p.tokenText(@intFromEnum(id_token));

    // Built-in types
    if (std.mem.eql(u8, text, "number")) {
        return p.addNode(.{ .tag = .flow_number_type, .main_token = id_token, .data = .{ .none = {} } });
    }
    if (std.mem.eql(u8, text, "string")) {
        return p.addNode(.{ .tag = .flow_string_type, .main_token = id_token, .data = .{ .none = {} } });
    }
    if (std.mem.eql(u8, text, "boolean") or std.mem.eql(u8, text, "bool")) {
        return p.addNode(.{ .tag = .flow_boolean_type, .main_token = id_token, .data = .{ .none = {} } });
    }
    if (std.mem.eql(u8, text, "mixed")) {
        return p.addNode(.{ .tag = .flow_mixed_type, .main_token = id_token, .data = .{ .none = {} } });
    }
    if (std.mem.eql(u8, text, "any")) {
        return p.addNode(.{ .tag = .flow_any_type, .main_token = id_token, .data = .{ .none = {} } });
    }
    if (std.mem.eql(u8, text, "empty")) {
        return p.addNode(.{ .tag = .flow_empty_type, .main_token = id_token, .data = .{ .none = {} } });
    }
    if (std.mem.eql(u8, text, "symbol")) {
        return p.addNode(.{ .tag = .flow_symbol_type, .main_token = id_token, .data = .{ .none = {} } });
    }
    if (std.mem.eql(u8, text, "bigint")) {
        return p.addNode(.{ .tag = .flow_bigint_type, .main_token = id_token, .data = .{ .none = {} } });
    }

    // Named type (possibly generic, possibly qualified)
    var base_id = try p.addNode(.{
        .tag = .identifier,
        .main_token = id_token,
        .data = .{ .none = {} },
    });

    // Qualified: Foo.Bar.Baz
    while (p.currentTag() == .dot) {
        _ = p.advance(); // .
        const member_tok = p.advance();
        const extra_start = try p.addExtra(@intFromEnum(base_id));
        _ = try p.addExtra(@intFromEnum(@as(NodeIndex, @enumFromInt(@intFromEnum(member_tok)))));
        base_id = try p.addNode(.{
            .tag = .flow_qualified_type_identifier,
            .main_token = member_tok,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    // Type arguments: Foo<T, U>
    if (p.currentTag() == .less_than) {
        const type_args = try parseFlowTypeParameterInstantiation(p);
        // Capture split end before addNode
        const gt_end = p.split_greater_end;
        const extra_start = try p.addExtra(@intFromEnum(base_id));
        _ = try p.addExtra(@intFromEnum(type_args));
        const node = try p.addNode(.{
            .tag = .flow_generic_type,
            .main_token = id_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        // Fix end position when `>` was split from `>>` or `>>>`.
        if (gt_end > 0) {
            p.nodes.items(.end_offset)[@intFromEnum(node)] = gt_end;
        }
        return node;
    }

    // Plain identifier type — wrap as GenericTypeAnnotation with no type params
    // Babel uses GenericTypeAnnotation even for plain named types
    const extra_start = try p.addExtra(@intFromEnum(base_id));
    _ = try p.addExtra(@intFromEnum(@as(NodeIndex, .none))); // no type parameters
    return p.addNode(.{
        .tag = .flow_generic_type,
        .main_token = id_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse tuple type: [A, B, C]
fn parseFlowTupleType(p: *Parser) Error!NodeIndex {
    const bracket_token = p.advance(); // [
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (p.currentTag() != .r_bracket and p.currentTag() != .eof) {
        const ty = try parseFlowType(p);
        try p.scratch.append(p.allocator, ty);
        if (p.currentTag() != .r_bracket) {
            _ = try p.expect(.comma);
        }
    }
    _ = try p.expect(.r_bracket);

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    return p.addNode(.{
        .tag = .flow_tuple_type,
        .main_token = bracket_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse object type: { ... } or exact {| ... |}
pub fn parseFlowObjectType(p: *Parser) Error!NodeIndex {
    const brace_token = p.advance(); // {

    // Check for exact object type: {| ... |}
    const is_exact = p.currentTag() == .pipe;
    if (is_exact) _ = p.advance(); // |

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    var has_inexact = false;

    while (p.currentTag() != .r_brace and p.currentTag() != .eof) {
        // Check for exact closing: |}
        if (is_exact and p.currentTag() == .pipe and p.lookAhead(1) == .r_brace) {
            _ = p.advance(); // |
            break;
        }
        // Check for inexact marker: ... (at end, followed by separator/closing)
        // vs spread property: ...Type
        if (p.currentTag() == .ellipsis) {
            const after_ellipsis = p.lookAhead(1);
            if (after_ellipsis == .comma or after_ellipsis == .semicolon or
                after_ellipsis == .r_brace or after_ellipsis == .pipe)
            {
                // Inexact marker
                _ = p.advance(); // ...
                has_inexact = true;
                if (p.currentTag() == .comma or p.currentTag() == .semicolon) {
                    _ = p.advance();
                }
                continue;
            }
            // Fall through to parseFlowObjectTypeProperty which handles spread
        }
        const prop = try parseFlowObjectTypeProperty(p);
        try p.scratch.append(p.allocator, prop);
        // Separator: comma or semicolon
        if (p.currentTag() == .comma or p.currentTag() == .semicolon) {
            _ = p.advance();
        }
    }
    _ = try p.expect(.r_brace);

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    _ = try p.addExtra(@intFromBool(has_inexact));

    const tag: Node.Tag = if (is_exact) .flow_exact_object_type else .flow_object_type;
    return p.addNode(.{
        .tag = tag,
        .main_token = brace_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse a single object type member: property, indexer, call property, internal slot, spread
fn parseFlowObjectTypeProperty(p: *Parser) Error!NodeIndex {
    // Spread property: ...Type or +...Type or -...Type
    if (p.currentTag() == .ellipsis or
        ((p.currentTag() == .plus or p.currentTag() == .minus) and p.lookAhead(1) == .ellipsis))
    {
        // Consume optional variance prefix (position used as spread start)
        const spread_start_token: TokenIndex = @enumFromInt(p.token_index);
        if (p.currentTag() == .plus or p.currentTag() == .minus) {
            _ = p.advance();
        }
        _ = p.advance(); // ...
        const ty = try parseFlowType(p);
        return p.addNode(.{
            .tag = .flow_object_type_spread_property,
            .main_token = spread_start_token,
            .data = .{ .unary = ty },
        });
    }

    // Internal slot: [[Name]]: Type
    if (p.currentTag() == .l_bracket and p.lookAhead(1) == .l_bracket) {
        return parseFlowObjectTypeInternalSlot(p);
    }

    // Indexer: [key: Type]: Type
    if (p.currentTag() == .l_bracket) {
        return parseFlowObjectTypeIndexer(p);
    }

    // Call property: (params): ReturnType or <T>(params): ReturnType
    if (p.currentTag() == .l_paren or p.currentTag() == .less_than) {
        // Check if this is a call property (function signature)
        return parseFlowObjectTypeCallProperty(p, false);
    }

    const member_start_token: TokenIndex = @enumFromInt(p.token_index);

    // Variance annotations: +prop: Type, -prop: Type, +[key: K]: V, +(): T
    var variance: ?TokenIndex = null;
    if (p.currentTag() == .plus or p.currentTag() == .minus) {
        // Check if this is a variance annotation by looking ahead
        const la = p.lookAhead(1);
        if (la == .identifier or la == .string or la.isKeyword() or la == .l_bracket or la == .l_paren or la == .less_than) {
            variance = p.advance(); // + or -
        }
    }

    // Variance before indexer: +[k: K]: V, -[k: K]: V
    if (variance != null and p.currentTag() == .l_bracket and p.lookAhead(1) != .l_bracket) {
        // Create variance node NOW so end_offset is set from the variance token
        const variance_node = try createFlowVarianceNode(p, variance.?);
        const indexer = try parseFlowObjectTypeIndexer(p);
        // Store variance on the indexer node via variance_map
        try p.flow_variance_map.put(p.allocator, @intFromEnum(indexer), variance_node);
        // Adjust start position to include variance token
        p.nodes.items(.main_token)[@intFromEnum(indexer)] = member_start_token;
        return indexer;
    }

    // Variance before call property or method without key: +(): T, -(): T, +<T>(): T, -<T>(): T
    // These are invalid in Flow — emit an error
    if (variance != null and (p.currentTag() == .l_paren or p.currentTag() == .less_than)) {
        p.errors.addError("Unexpected token", p.token_starts[@intFromEnum(variance.?)]);
    }

    // "get" or "set" prefix for getter/setter
    var is_getter = false;
    var is_setter = false;
    if (p.currentTag() == .identifier or p.currentTag() == .kw_get or p.currentTag() == .kw_set) {
        const text = p.tokenText(p.token_index);
        if (std.mem.eql(u8, text, "get") and p.lookAhead(1) != .colon and
            p.lookAhead(1) != .question and p.lookAhead(1) != .less_than and p.lookAhead(1) != .l_paren)
        {
            is_getter = true;
            _ = p.advance();
        } else if (std.mem.eql(u8, text, "set") and p.lookAhead(1) != .colon and
            p.lookAhead(1) != .question and p.lookAhead(1) != .less_than and p.lookAhead(1) != .l_paren)
        {
            is_setter = true;
            _ = p.advance();
        }
    }

    // "static" modifier — don't treat `static` as modifier if followed by `(` or `<` (it's a method name),
    // unless we're in a declare class where `static ()` is a static call property.
    var is_static = false;
    if (p.currentTag() == .kw_static or
        (p.currentTag() == .identifier and std.mem.eql(u8, p.tokenText(p.token_index), "static")))
    {
        const la = p.lookAhead(1);
        if (p.flow_in_declare_class and (la == .l_paren or la == .less_than)) {
            // In declare class, `static ()` or `static <T>()` is a static call property
            is_static = true;
            _ = p.advance();
        } else if (la != .colon and la != .question and la != .l_paren and la != .less_than) {
            is_static = true;
            _ = p.advance();
        }
    }

    // "proto" modifier (only valid in declare class context, and not when static is already set)
    var is_proto = false;
    if (p.flow_in_declare_class and !is_static and p.currentTag() == .identifier and p.currentSoftKeyword() == .proto) {
        if (p.lookAhead(1) != .colon and p.lookAhead(1) != .question) {
            is_proto = true;
            _ = p.advance();
        }
    }

    // Variance after proto: proto +x: T, proto -x: T
    if (is_proto and variance == null and (p.currentTag() == .plus or p.currentTag() == .minus)) {
        const la = p.lookAhead(1);
        if (la == .identifier or la == .string or la.isKeyword()) {
            variance = p.advance(); // + or -
        }
    }

    // After modifiers, check for internal slot: static [[foo]]: Type
    if (p.currentTag() == .l_bracket and p.lookAhead(1) == .l_bracket) {
        // Variance on internal slots is not allowed
        if (variance != null) {
            p.errors.addError("Unexpected token", p.token_starts[@intFromEnum(variance.?)]);
        }
        const slot = try parseFlowObjectTypeInternalSlot(p);
        // Apply static flag and adjust start position
        if (is_static) {
            const slot_extra_idx = @intFromEnum(p.nodes.items(.data)[@intFromEnum(slot)].extra);
            p.extra_data.items[slot_extra_idx + 2] |= 2; // static flag
            p.nodes.items(.main_token)[@intFromEnum(slot)] = member_start_token;
        }
        return slot;
    }

    // After modifiers, check for indexer: static [key: Type]: Type
    if ((is_static or is_proto) and p.currentTag() == .l_bracket and p.lookAhead(1) != .l_bracket) {
        const indexer = try parseFlowObjectTypeIndexer(p);
        if (is_static) {
            const idx_extra = @intFromEnum(p.nodes.items(.data)[@intFromEnum(indexer)].extra);
            p.extra_data.items[idx_extra + 3] |= 1; // static flag
            p.nodes.items(.main_token)[@intFromEnum(indexer)] = member_start_token;
        }
        if (variance != null) {
            const variance_node = try createFlowVarianceNode(p, variance.?);
            try p.flow_variance_map.put(p.allocator, @intFromEnum(indexer), variance_node);
        }
        return indexer;
    }

    // After modifiers, check for call property: static (params): ReturnType
    if (p.currentTag() == .l_paren or p.currentTag() == .less_than) {
        const call_prop = try parseFlowObjectTypeCallProperty(p, is_static);
        // If static modifier consumed, adjust start position to include it
        if (is_static) {
            p.nodes.items(.main_token)[@intFromEnum(call_prop)] = member_start_token;
        }
        return call_prop;
    }

    // Check for method: name(params): ReturnType or name<T>(params): ReturnType
    // Need to look ahead past the key to see if ( or < follows
    const key_token = p.advance(); // property key

    var is_optional = false;
    if (p.eat(.question) != null) {
        is_optional = true;
    }

    if (p.currentTag() == .l_paren or p.currentTag() == .less_than) {
        // Variance on methods is invalid in Flow
        if (variance != null) {
            p.errors.addError("Unexpected token", p.token_starts[@intFromEnum(variance.?)]);
        }
        // Method property — parse as call property with key
        const func_type = try parseFlowFunctionTypeParams(p);
        p.nodes.items(.main_token)[@intFromEnum(func_type)] = member_start_token;
        // flags: optional(1), static(2), proto(4), getter(8), setter(16), method(128)
        var flags: u32 = 128; // method flag
        if (is_optional) flags |= 1;
        if (is_static) flags |= 2;
        if (is_proto) flags |= 4;
        if (is_getter) flags |= 8;
        if (is_setter) flags |= 16;

        const this_param = flowFunctionTypeThisParam(p, func_type);
        const param_count = flowFunctionTypeParamCount(p, func_type);
        if (this_param != .none and (is_getter or is_setter)) {
            p.errors.addError(
                if (is_getter)
                    "A getter cannot have a `this` parameter."
                else
                    "A setter cannot have a `this` parameter.",
                p.token_starts[@intFromEnum(p.nodes.items(.main_token)[@intFromEnum(this_param)])],
            );
        }
        if (is_setter and param_count != 1) {
            p.errors.addError("A 'set' accessor must have exactly one formal parameter.", p.token_starts[@intFromEnum(key_token)]);
        }
        if (p.flow_in_declare_class and !is_static and tokenRepresentsConstructor(p, key_token) and this_param != .none) {
            p.errors.addError(
                "Constructors cannot have a `this` parameter; constructors don't bind `this` like other functions.",
                p.token_starts[@intFromEnum(p.nodes.items(.main_token)[@intFromEnum(this_param)])],
            );
        }

        const extra_start = try p.addExtra(@intFromEnum(func_type));
        _ = try p.addExtra(@intFromEnum(key_token));
        _ = try p.addExtra(@intFromEnum(variance orelse @as(TokenIndex, @enumFromInt(0))));
        _ = try p.addExtra(flags);

        return p.addNode(.{
            .tag = .flow_object_type_property,
            .main_token = member_start_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    // Getter/setter without method syntax is invalid
    if (is_getter or is_setter) {
        p.errors.addError("Unexpected token", p.currentStart());
    }

    // Regular property: key: Type
    _ = try p.expect(.colon);
    const value_type = try parseFlowType(p);

    // flags: optional(1), static(2), proto(4), variance(+:32, -:64)
    var flags: u32 = 0;
    if (is_optional) flags |= 1;
    if (is_static) flags |= 2;
    if (is_proto) flags |= 4;
    if (variance) |v| {
        const vtext = p.tokenText(@intFromEnum(v));
        if (std.mem.eql(u8, vtext, "+")) flags |= 32;
        if (std.mem.eql(u8, vtext, "-")) flags |= 64;
    }

    const extra_start = try p.addExtra(@intFromEnum(value_type));
    _ = try p.addExtra(@intFromEnum(key_token));
    _ = try p.addExtra(@intFromEnum(variance orelse @as(TokenIndex, @enumFromInt(0))));
    _ = try p.addExtra(flags);

    return p.addNode(.{
        .tag = .flow_object_type_property,
        .main_token = member_start_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn flowFunctionTypeThisParam(p: *Parser, func_type: NodeIndex) NodeIndex {
    if (func_type == .none or p.nodes.items(.tag)[@intFromEnum(func_type)] != .flow_function_type_annotation) {
        return .none;
    }
    const extra_idx = @intFromEnum(p.nodes.items(.data)[@intFromEnum(func_type)].extra);
    return @enumFromInt(p.extra_data.items[extra_idx + 5]);
}

fn flowFunctionTypeParamCount(p: *Parser, func_type: NodeIndex) usize {
    if (func_type == .none or p.nodes.items(.tag)[@intFromEnum(func_type)] != .flow_function_type_annotation) {
        return 0;
    }
    const extra_idx = @intFromEnum(p.nodes.items(.data)[@intFromEnum(func_type)].extra);
    const params_start = p.extra_data.items[extra_idx];
    const params_end = p.extra_data.items[extra_idx + 1];
    return params_end - params_start;
}

fn tokenRepresentsConstructor(p: *Parser, tok: TokenIndex) bool {
    const text = p.tokenText(@intFromEnum(tok));
    return switch (p.token_tags[@intFromEnum(tok)]) {
        .identifier => std.mem.eql(u8, text, "constructor"),
        .string => text.len >= 2 and std.mem.eql(u8, text[1 .. text.len - 1], "constructor"),
        else => false,
    };
}

/// Parse indexer: [key: Type]: Type
fn parseFlowObjectTypeIndexer(p: *Parser) Error!NodeIndex {
    const bracket_token = p.advance(); // [

    // Could be [Type]: Type (unnamed) or [key: Type]: Type (named)
    var name_token: TokenIndex = @enumFromInt(0);
    var key_type: NodeIndex = undefined;

    // Lookahead: if next is identifier followed by colon, it's a named indexer
    if ((p.currentTag() == .identifier or p.currentTag().isKeyword()) and p.lookAhead(1) == .colon) {
        name_token = p.advance(); // key name
        _ = p.advance(); // :
        key_type = try parseFlowType(p);
    } else {
        key_type = try parseFlowType(p);
    }
    _ = try p.expect(.r_bracket);
    _ = try p.expect(.colon);
    const value_type = try parseFlowType(p);

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(key_type));
    _ = try p.addExtra(@intFromEnum(value_type));
    _ = try p.addExtra(@as(u32, 0)); // flags: bit 0 = static

    return p.addNode(.{
        .tag = .flow_object_type_indexer,
        .main_token = bracket_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse call property: (params): ReturnType
fn parseFlowObjectTypeCallProperty(p: *Parser, is_static: bool) Error!NodeIndex {
    const start_token: TokenIndex = @enumFromInt(p.token_index);
    const func_type = try parseFlowFunctionTypeParams(p);

    var flags: u32 = 0;
    if (is_static) flags |= 1;
    const extra_start = try p.addExtra(@intFromEnum(func_type));
    _ = try p.addExtra(flags);

    return p.addNode(.{
        .tag = .flow_object_type_call_property,
        .main_token = start_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse internal slot: [[Name]]: Type
fn parseFlowObjectTypeInternalSlot(p: *Parser) Error!NodeIndex {
    const first_bracket = p.advance(); // [
    _ = p.advance(); // [
    // Validate that the internal slot key is an identifier
    if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
        p.errors.addError("Unexpected token", p.currentStart());
    }
    const name_token = p.advance(); // identifier
    _ = try p.expect(.r_bracket);
    _ = try p.expect(.r_bracket);

    var is_optional = false;
    if (p.eat(.question) != null) {
        is_optional = true;
    }

    var value_type: NodeIndex = .none;
    if (p.currentTag() == .l_paren or p.currentTag() == .less_than) {
        // Method internal slot — start FunctionTypeAnnotation at the first bracket
        value_type = try parseFlowFunctionTypeParams(p);
        p.nodes.items(.main_token)[@intFromEnum(value_type)] = first_bracket;
    } else {
        _ = try p.expect(.colon);
        value_type = try parseFlowType(p);
    }

    var flags: u32 = 0;
    if (is_optional) flags |= 1;

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(value_type));
    _ = try p.addExtra(flags);

    return p.addNode(.{
        .tag = .flow_object_type_internal_slot,
        .main_token = first_bracket,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse a parenthesized type or function type: (Type) or (a: T) => V
fn parseFlowParenthesizedOrFunctionType(p: *Parser) Error!NodeIndex {
    // Try to determine if this is a function type by looking ahead
    // Function type: (params) => ReturnType
    // Parenthesized: (Type)

    // Save state for backtracking
    const saved = p.token_index;

    // Try to parse as function type
    if (isFlowFunctionType(p)) {
        return parseFlowFunctionTypeAnnotation(p);
    }
    // Restore and parse as parenthesized type
    p.token_index = saved;
    const paren_token = p.advance(); // (
    // Inside parentheses, re-enable no-parens function types
    const saved_no_anon = p.flow_no_anon_function_type;
    p.flow_no_anon_function_type = false;
    defer p.flow_no_anon_function_type = saved_no_anon;
    const inner = try parseFlowType(p);
    _ = try p.expect(.r_paren);
    // Wrap in a parenthesized type node so that position tracking
    // can see the opening paren (needed for T[] and T[K] start positions)
    return p.addNode(.{
        .tag = .flow_parenthesized_type,
        .main_token = paren_token,
        .data = .{ .unary = inner },
    });
}

/// Heuristic to check if `(` starts a function type
fn isFlowFunctionType(p: *Parser) bool {
    // Save token index for restoration
    const saved = p.token_index;
    defer p.token_index = saved;

    if (p.currentTag() != .l_paren) return false;
    p.token_index += 1; // skip (

    // Empty parens: () => ... is always a function type
    if (p.currentTag() == .r_paren) {
        p.token_index += 1;
        return p.currentTag() == .arrow;
    }

    // ... rest param: (...) => ...
    if (p.currentTag() == .ellipsis) return true;

    // Try to scan params
    var depth: u32 = 1;
    var saw_colon = false;
    var saw_comma = false;
    while (depth > 0 and p.currentTag() != .eof) {
        switch (p.currentTag()) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) {
                    p.token_index += 1;
                    // When in a return type annotation context (no_anon_function_type),
                    // `=>` after `)` is the outer arrow function arrow, not a type arrow.
                    // Only treat as function type if we saw `:` (named param), comma (multiple params),
                    // or if we're not suppressing anonymous function types.
                    if (p.currentTag() == .colon) return true;
                    if (p.currentTag() == .arrow) {
                        // In annotation context, only count as function type if
                        // we found evidence of function params (like `:` or `,`)
                        if (p.flow_no_anon_function_type and !saw_colon and !saw_comma) return false;
                        return true;
                    }
                    return false;
                }
            },
            .colon => {
                // If we see colon at depth 1, it's likely a function type (name: Type)
                if (depth == 1) {
                    saw_colon = true;
                    return true;
                }
            },
            .comma => {
                if (depth == 1) {
                    saw_comma = true;
                }
            },
            else => {},
        }
        p.token_index += 1;
    }
    return false;
}

/// Parse function type: (a: T, b: U) => V
pub fn parseFlowFunctionTypeAnnotation(p: *Parser) Error!NodeIndex {
    const start_token: TokenIndex = @enumFromInt(p.token_index);
    const func_type = try parseFlowFunctionTypeParams(p);
    _ = start_token;
    return func_type;
}

/// Parse function type params and return type: (params) => ReturnType or <T>(params) => ReturnType
fn parseFlowFunctionTypeParams(p: *Parser) Error!NodeIndex {
    // When pending_less_than is set, the `<` is from a `<<` token split;
    // use the previous token index as start.
    const start_token: TokenIndex = if (p.pending_less_than)
        @enumFromInt(p.token_index -| 1)
    else
        @enumFromInt(p.token_index);

    // Optional type parameters
    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than or p.pending_less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    _ = try p.expect(.l_paren);

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    var rest_param: NodeIndex = .none;
    var this_param: NodeIndex = .none;

    while (p.currentTag() != .r_paren and p.currentTag() != .eof) {
        // Rest param: ...name: Type
        if (p.currentTag() == .ellipsis) {
            _ = p.advance(); // ...
            rest_param = try parseFlowFunctionTypeParam(p);
            if (p.currentTag() == .comma) _ = p.advance();
            break;
        }

        // Check for 'this' parameter: `this:` or `this?`
        // In declare class methods, bare `this,` and `this)` are also this-annotations
        if (p.currentTag() == .kw_this and (p.lookAhead(1) == .colon or p.lookAhead(1) == .question or
            (p.flow_in_declare_class and (p.lookAhead(1) == .comma or p.lookAhead(1) == .r_paren))))
        {
            if (this_param != .none or p.scratch.items.len != scratch_start) {
                p.errors.addError("The `this` parameter must be the first function parameter.", p.currentStart());
                const param = try parseFlowFunctionTypeParam(p);
                try p.scratch.append(p.allocator, param);
                if (p.currentTag() == .comma) _ = p.advance();
                continue;
            }

            const this_tok = p.advance(); // this
            var flags: u32 = 2; // bit 2 = unnamed (this-param has no name in output)
            if (p.eat(.question) != null) {
                flags |= 1;
            }
            // If colon follows, parse the explicit type annotation
            // Otherwise (bare `this` followed by `,` or `)`), use ThisTypeAnnotation
            const this_type = if (p.currentTag() == .colon) blk: {
                _ = p.advance(); // consume ':'
                break :blk try parseFlowType(p);
            } else blk: {
                // Bare `this` — create a ThisTypeAnnotation node
                break :blk try p.addNode(.{
                    .tag = .flow_this_type_annotation,
                    .main_token = this_tok,
                    .data = .{ .none = {} },
                });
            };
            const this_extra = try p.addExtra(@intFromEnum(this_type));
            _ = try p.addExtra(flags);
            this_param = try p.addNode(.{
                .tag = .flow_function_type_param,
                .main_token = this_tok,
                .data = .{ .extra = @enumFromInt(this_extra) },
                .end_offset = p.nodes.items(.end_offset)[@intFromEnum(this_type)],
            });
            if (p.currentTag() == .comma) _ = p.advance();
            continue;
        }

        const param = try parseFlowFunctionTypeParam(p);
        try p.scratch.append(p.allocator, param);
        if (p.currentTag() != .r_paren) {
            if (p.currentTag() != .comma and p.currentTag() != .ellipsis) {
                // Missing comma between parameters
                p.errors.addError("Unexpected token, expected \",\"", p.currentStart());
            }
            if (p.currentTag() == .comma) {
                // Include comma in end position for unnamed params only (Babel compat),
                // UNLESS this is a non-last trailing comma in a multi-param list.
                const is_trailing_comma = p.lookAhead(1) == .r_paren;
                const is_first_param = (p.scratch.items.len - scratch_start) == 1;
                const include_comma = !is_trailing_comma or is_first_param;
                if (include_comma) {
                    const param_extra = @intFromEnum(p.nodes.items(.data)[@intFromEnum(param)].extra);
                    const param_flags = p.extra_data.items[param_extra + 1];
                    if (param_flags & 2 != 0) {
                        // Unnamed param — extend end to include comma
                        p.nodes.items(.end_offset)[@intFromEnum(param)] = p.token_ends[p.token_index];
                    }
                }
                _ = p.advance();
            }
        }
    }
    _ = try p.expect(.r_paren);

    // Return type: => Type or : Type
    var return_type: NodeIndex = .none;
    if (p.eat(.arrow) != null) {
        return_type = try parseFlowType(p);
    } else if (p.currentTag() == .colon) {
        _ = p.advance(); // :
        return_type = try parseFlowType(p);
    }

    const params = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(params);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    _ = try p.addExtra(@intFromEnum(return_type));
    _ = try p.addExtra(@intFromEnum(rest_param));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(@intFromEnum(this_param));

    return p.addNode(.{
        .tag = .flow_function_type_annotation,
        .main_token = start_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse a single function type param: name: Type or just Type
fn parseFlowFunctionTypeParam(p: *Parser) Error!NodeIndex {
    const param_start: TokenIndex = @enumFromInt(p.token_index);

    // Try to determine if this is "name: Type" or just "Type"
    // If current is identifier/keyword and next is : or ?, it's named
    if ((p.currentTag() == .identifier or p.currentTag().isKeyword()) and
        (p.lookAhead(1) == .colon or p.lookAhead(1) == .question))
    {
        const name_tok = p.advance();
        var is_optional = false;
        if (p.eat(.question) != null) {
            is_optional = true;
            // After ?, expect :
        }
        _ = try p.expect(.colon);
        const ty = try parseFlowType(p);

        var flags: u32 = 0;
        if (is_optional) flags |= 1;
        const extra_start = try p.addExtra(@intFromEnum(ty));
        _ = try p.addExtra(flags);

        return p.addNode(.{
            .tag = .flow_function_type_param,
            .main_token = name_tok,
            .data = .{ .extra = @enumFromInt(extra_start) },
            .end_offset = p.nodes.items(.end_offset)[@intFromEnum(ty)],
        });
    }

    // Unnamed param: just a type
    const ty = try parseFlowType(p);

    const extra_start = try p.addExtra(@intFromEnum(ty));
    _ = try p.addExtra(@as(u32, 2)); // flag bit 2 = unnamed

    return p.addNode(.{
        .tag = .flow_function_type_param,
        .main_token = param_start,
        .data = .{ .extra = @enumFromInt(extra_start) },
        .end_offset = p.nodes.items(.end_offset)[@intFromEnum(ty)],
    });
}

/// Parse anonymous interface type: interface { ... } or interface extends X { ... }
fn parseFlowAnonymousInterfaceType(p: *Parser) Error!NodeIndex {
    const iface_token = p.advance(); // interface

    // Optional extends
    const extends_scratch_start = p.scratch.items.len;
    if (p.currentTag() == .kw_extends) {
        _ = p.advance(); // extends
        while (true) {
            const ext = try parseFlowInterfaceExtends(p);
            try p.scratch.append(p.allocator, ext);
            if (p.currentTag() != .comma) break;
            _ = p.advance();
        }
    }
    const extends_items = p.scratch.items[extends_scratch_start..];
    const extends_range = try p.addExtraRange(extends_items);
    p.scratch.shrinkRetainingCapacity(extends_scratch_start);

    const body = try parseFlowObjectType(p);

    const extra_start = try p.addExtra(extends_range.start);
    _ = try p.addExtra(extends_range.end);
    _ = try p.addExtra(@intFromEnum(body));

    return p.addNode(.{
        .tag = .flow_interface_type_annotation,
        .main_token = iface_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Create a flow_variance node from a +/- token
pub fn createFlowVarianceNode(p: *Parser, variance_token: TokenIndex) Error!NodeIndex {
    return p.addNode(.{
        .tag = .flow_variance,
        .main_token = variance_token,
        .data = .{ .none = {} },
    });
}

// ============================================================================
// Type Parameters
// ============================================================================

/// Parse type parameter declaration: <T, U extends V, +W, -X>
pub fn parseFlowTypeParameterDeclaration(p: *Parser) Error!NodeIndex {
    var lt_token: @import("token.zig").TokenIndex = undefined;
    if (p.pending_less_than) {
        // Second `<` from a `<<` split
        p.pending_less_than = false;
        lt_token = @enumFromInt(p.token_index -| 1);
    } else {
        lt_token = try p.expect(.less_than);
    }
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    if (isAtFlowGreaterThan(p)) {
        // Empty type parameter declaration: type Foo<> = ...
        p.errors.addError("Type parameter list cannot be empty.", p.currentStart());
    }

    while (!isAtFlowGreaterThan(p) and p.currentTag() != .eof) {
        const param = try parseFlowTypeParameter(p);
        try p.scratch.append(p.allocator, param);
        if (p.currentTag() == .comma) {
            _ = p.advance();
        } else if (!isAtFlowGreaterThan(p)) {
            // Expected `,` or `>` after type parameter
            return error.ParseError;
        }
    }
    try expectFlowGreaterThanOrSplit(p);

    // Capture the split greater end before addNode resets it
    const gt_end = p.split_greater_end;

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    const node = try p.addNode(.{
        .tag = .flow_type_parameter_declaration,
        .main_token = lt_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });

    // Fix end position when `>` was split from `>>` or `>>>`
    if (gt_end > 0) {
        p.nodes.items(.end_offset)[@intFromEnum(node)] = gt_end;
    }

    return node;
}

/// Parse a single type parameter: T, T: bound, +T, -T, T = default
fn parseFlowTypeParameter(p: *Parser) Error!NodeIndex {
    // Variance annotation
    var variance_flag: u32 = 0; // 0=none, 1=plus, 2=minus
    var variance_token: TokenIndex = @enumFromInt(0);
    if (p.currentTag() == .plus) {
        variance_flag = 1;
        variance_token = p.advance();
    } else if (p.currentTag() == .minus) {
        variance_flag = 2;
        variance_token = p.advance();
    }

    // Expect an identifier for the type parameter name
    if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
        p.errors.addError("Unexpected token", p.currentStart());
        return error.ParseError;
    }
    const name_token = p.advance(); // identifier

    // Bound: T: Type (wrapped in TypeAnnotation)
    var bound: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        const colon_token = p.advance();
        const bound_type = try parseFlowType(p);
        // Capture split_greater_end before addNode (for >> splitting in nested generics)
        const bound_gt_end = p.split_greater_end;
        bound = try p.addNode(.{
            .tag = .flow_type_annotation,
            .main_token = colon_token,
            .data = .{ .unary = bound_type },
        });
        if (bound_gt_end > 0) {
            p.nodes.items(.end_offset)[@intFromEnum(bound)] = bound_gt_end;
        }
    }

    // Default: T = Type
    var default_type: NodeIndex = .none;
    if (p.currentTag() == .equal) {
        _ = p.advance();
        default_type = try parseFlowType(p);
    }

    const extra_start = try p.addExtra(@intFromEnum(bound));
    _ = try p.addExtra(@intFromEnum(default_type));
    _ = try p.addExtra(variance_flag);
    _ = try p.addExtra(@intFromEnum(variance_token));

    // Capture split_greater_end for the TypeParameter node itself
    const param_gt_end = p.split_greater_end;

    // Use variance token as main_token if present, so nodeStart includes the variance
    const start_token = if (variance_flag != 0) variance_token else name_token;
    const node = try p.addNode(.{
        .tag = .flow_type_parameter,
        .main_token = start_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
    if (param_gt_end > 0) {
        p.nodes.items(.end_offset)[@intFromEnum(node)] = param_gt_end;
    }
    return node;
}

/// Parse type parameter instantiation: <Type, Type>
pub fn parseFlowTypeParameterInstantiation(p: *Parser) Error!NodeIndex {
    var lt_token: @import("token.zig").TokenIndex = undefined;
    if (p.pending_less_than) {
        // We already consumed the `<<` token; this `<` is the second half.
        p.pending_less_than = false;
        lt_token = @enumFromInt(p.token_index -| 1);
    } else if (p.currentTag() == .less_than) {
        lt_token = p.advance();
    } else if (p.currentTag() == .less_less) {
        // Split `<<` into `<` + `<`: consume the token and set pending_less_than
        lt_token = p.advance();
        p.pending_less_than = true;
    } else {
        lt_token = try p.expect(.less_than);
    }
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    // Inside generic type arguments, re-enable all function type parsing
    // (the `>` delimiter handles scoping, so `(T) => U` is safe here)
    const saved_no_anon = p.flow_no_anon_function_type;
    p.flow_no_anon_function_type = false;
    while (!isAtFlowGreaterThan(p) and p.currentTag() != .eof) {
        const ty = try parseFlowType(p);
        try p.scratch.append(p.allocator, ty);
        if (p.currentTag() == .comma) {
            _ = p.advance();
        }
    }
    p.flow_no_anon_function_type = saved_no_anon;
    try expectFlowGreaterThanOrSplit(p);

    // Capture the split greater end before addNode resets it
    const gt_end = p.split_greater_end;

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    const node = try p.addNode(.{
        .tag = .flow_type_parameter_instantiation,
        .main_token = lt_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });

    // Fix end position when `>` was split from `>>` or `>>>`.
    if (gt_end > 0) {
        p.nodes.items(.end_offset)[@intFromEnum(node)] = gt_end;
    }

    return node;
}

/// Check if the current token looks like a `>` closing a type parameter list,
/// handling `>>` and `>>>` token splitting via pending_greater_than.
fn isAtFlowGreaterThan(p: *Parser) bool {
    return p.pending_greater_than > 0 or
        p.currentTag() == .greater_than or
        p.currentTag() == .greater_greater or
        p.currentTag() == .greater_greater_greater;
}

/// Consume a `>` that closes a type parameter list, splitting `>>` / `>>>` tokens
/// by advancing past the multi-char token and leaving pending state.
fn expectFlowGreaterThanOrSplit(p: *Parser) Error!void {
    if (p.pending_greater_than > 0) {
        p.pending_greater_than -= 1;
        if (p.split_greater_end > 0) {
            p.split_greater_end += 1;
        }
    } else if (p.currentTag() == .greater_greater) {
        const tok_start = p.token_starts[p.token_index];
        _ = p.advance();
        p.pending_greater_than = 1;
        p.split_greater_end = tok_start + 1;
    } else if (p.currentTag() == .greater_greater_greater) {
        const tok_start = p.token_starts[p.token_index];
        _ = p.advance();
        p.pending_greater_than = 2;
        p.split_greater_end = tok_start + 1;
    } else {
        _ = try p.expect(.greater_than);
        p.split_greater_end = 0;
    }
}

/// Try to parse a generic arrow function in Flow mode: `<T>(params): RetType => body`
/// Returns the arrow function node on success, or error.ParseError on failure.
/// Caller should save/restore state for backtracking.
pub fn tryParseFlowGenericArrowFunction(p: *Parser) Error!NodeIndex {
    const start_tok: TokenIndex = @enumFromInt(p.token_index);
    const deferred = p.beginDeferredParamMetadata();
    errdefer p.discardDeferredParamMetadata(deferred);

    // Parse type parameters <T, U: Bound>
    const type_params = try parseFlowTypeParameterDeclaration(p);

    // Must be followed by `(`
    if (p.currentTag() != .l_paren) return error.ParseError;

    // Parse parameter list using parseBindingElement for proper type annotation handling
    _ = try p.expect(.l_paren);
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (p.currentTag() != .r_paren and p.currentTag() != .eof) {
        if (p.currentTag() == .ellipsis) {
            const rest_tok = p.advance();
            const elem = try p.parseBindingElement();
            const rest_node = try p.addNode(.{ .tag = .rest_element, .main_token = rest_tok, .data = .{ .unary = elem } });
            try p.moveParamTypeAnnotationToRest(elem, rest_node);
            try p.moveOptionalParamToRest(elem, rest_node);
            p.scratch.append(p.allocator, rest_node) catch return error.ParseError;
        } else {
            // Try parsing as binding element first; if that fails (e.g. `b => c` expression
            // which is not a valid binding), fall back to expression-based parsing.
            // This is needed for Flow ternary arrow disambiguation where params may be
            // expression-like (e.g. `<T>(b => c): d => e`).
            const param_state = p.saveState();
            const param = p.parseBindingElement() catch blk: {
                p.restoreState(param_state);
                // Fall back to expression parsing
                var expr = try p.parseAssignmentOrSpread();
                // Flow typecast inside param: (expr: Type)
                if (p.currentTag() == .colon) {
                    _ = try p.removeTypeAnnotation(expr);
                    expr = try parseFlowTypeCastExpression(p, expr);
                }
                break :blk expr;
            };
            // Check if parsing succeeded but left the cursor at a position that's not
            // `,` or `)` — this means the binding was partial (e.g. parsed `b` from `b => c`).
            if (p.currentTag() != .comma and p.currentTag() != .r_paren and p.currentTag() != .eof) {
                // Incomplete binding — fall back to expression parsing
                p.restoreState(param_state);
                var expr = try p.parseAssignmentOrSpread();
                if (p.currentTag() == .colon) {
                    _ = try p.removeTypeAnnotation(expr);
                    expr = try parseFlowTypeCastExpression(p, expr);
                }
                p.scratch.append(p.allocator, expr) catch return error.ParseError;
            } else {
                p.scratch.append(p.allocator, param) catch return error.ParseError;
            }
        }
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_paren);

    // Optional return type annotation
    var return_type: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        return_type = try parseFlowArrowReturnTypeAnnotation(p);
    }

    // Must be followed by `=>`
    if (p.currentTag() != .arrow) return error.ParseError;

    _ = p.advance(); // consume =>

    // Arrow functions are never generators.
    const saved_gen = p.in_generator;
    p.in_generator = false;
    defer p.in_generator = saved_gen;

    // For async arrows, enable in_async for the body only
    const saved_async = p.in_async;
    if (p.pending_async_arrow) {
        p.in_async = true;
        p.pending_async_arrow = false;
    }

    const body = if (p.currentTag() == .l_brace)
        try p.parseBlockStatement()
    else
        try p.parseAssignmentExpression();
    p.in_async = saved_async;

    // Build the arrow node using the range format (range_start, range_end, body)
    const params = p.scratch.items[scratch_start..];
    const param_range = try p.addExtraRange(params);
    const extra_start = try p.addExtra(param_range.start);
    _ = try p.addExtra(param_range.end);
    _ = try p.addExtra(@intFromEnum(body));

    // Store type parameters and return type in side tables
    if (type_params != .none) {
        try p.putTypeParameters(@enumFromInt(p.nodes.len), type_params);
    }
    if (return_type != .none) {
        try p.putReturnType(@enumFromInt(p.nodes.len), return_type);
    }

    const node = try p.addNode(.{
        .tag = .arrow_function_expr,
        .main_token = start_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
    try p.commitDeferredParamMetadata(deferred);
    return node;
}

// ============================================================================
// Flow Statements
// ============================================================================

/// Parse type alias: type Foo = Type;
pub fn parseFlowTypeAlias(p: *Parser) Error!NodeIndex {
    const type_token = p.advance(); // 'type'

    // Check if this is actually a labeled statement or expression: type : ...
    // or `type` used as an identifier expression
    if (p.currentTag() != .identifier and p.currentTag() != .kw_of and
        p.currentTag() != .kw_get and p.currentTag() != .kw_set and
        p.currentTag() != .kw_async and p.currentTag() != .kw_let and
        p.currentTag() != .kw_static)
    {
        // Not a type alias, backtrack
        p.token_index = @intFromEnum(type_token);
        return p.parseExpressionOrLabeledStatement();
    }

    // Check for labeled statement: `type:` or assignment: `type =`
    if (p.lookAhead(1) != .equal and p.lookAhead(1) != .less_than and
        p.lookAhead(1) != .colon and p.currentTag() == .identifier)
    {
        // Could be expression: type(x) or type.foo
        if (p.lookAhead(1) == .l_paren or p.lookAhead(1) == .dot or
            p.lookAhead(1) == .semicolon or p.lookAhead(1) == .eof or
            p.lookAhead(1) == .pipe or p.lookAhead(1) == .ampersand)
        {
            // This is actually `type` used as an expression/identifier
            p.token_index = @intFromEnum(type_token);
            return p.parseExpressionOrLabeledStatement();
        }
    }

    const name_token = p.advance(); // identifier

    // Optional type parameters
    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    _ = try p.expect(.equal);
    const right = try parseFlowType(p);
    p.expectSemicolon() catch {};

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(@intFromEnum(right));

    return p.addNode(.{
        .tag = .flow_type_alias,
        .main_token = type_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse opaque type: opaque type Foo = Type;
pub fn parseFlowOpaqueType(p: *Parser) Error!NodeIndex {
    const opaque_token = p.advance(); // 'opaque'

    if (p.currentTag() != .identifier or p.currentSoftKeyword() != .type_) {
        // Not an opaque type, backtrack
        p.token_index = @intFromEnum(opaque_token);
        return p.parseExpressionOrLabeledStatement();
    }
    _ = p.advance(); // 'type'

    const name_token = p.advance(); // identifier

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    // Supertype: opaque type Foo: SuperType = Type
    var supertype: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        _ = p.advance();
        supertype = try parseFlowType(p);
    }

    _ = try p.expect(.equal);
    const impl_type = try parseFlowType(p);
    p.expectSemicolon() catch {};

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(@intFromEnum(supertype));
    _ = try p.addExtra(@intFromEnum(impl_type));

    return p.addNode(.{
        .tag = .flow_opaque_type,
        .main_token = opaque_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse interface declaration: interface Foo extends Bar { ... }
pub fn parseFlowInterfaceDeclaration(p: *Parser) Error!NodeIndex {
    const iface_token = p.advance(); // 'interface'

    // Check if this is actually an identifier expression
    if (p.currentTag() != .identifier and p.currentTag() != .kw_of and
        !p.currentTag().isKeyword())
    {
        p.token_index = @intFromEnum(iface_token);
        return p.parseExpressionOrLabeledStatement();
    }

    const name_token = p.advance(); // identifier

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    // extends
    const extends_scratch_start = p.scratch.items.len;
    if (p.currentTag() == .kw_extends) {
        _ = p.advance(); // extends
        while (true) {
            const ext = try parseFlowInterfaceExtends(p);
            try p.scratch.append(p.allocator, ext);
            if (p.currentTag() != .comma) break;
            _ = p.advance();
        }
    }
    const extends_items = p.scratch.items[extends_scratch_start..];
    const extends_range = try p.addExtraRange(extends_items);
    p.scratch.shrinkRetainingCapacity(extends_scratch_start);

    // Body
    const body = try parseFlowObjectType(p);

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(extends_range.start);
    _ = try p.addExtra(extends_range.end);
    _ = try p.addExtra(@intFromEnum(body));

    return p.addNode(.{
        .tag = .flow_interface_declaration,
        .main_token = iface_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse interface extends clause item: Foo or Foo<T>
pub fn parseFlowInterfaceExtends(p: *Parser) Error!NodeIndex {
    const name_token = p.advance(); // identifier
    var id = try p.addNode(.{
        .tag = .identifier,
        .main_token = name_token,
        .data = .{ .none = {} },
    });

    // Qualified name
    while (p.currentTag() == .dot) {
        _ = p.advance();
        const member = p.advance();
        const qextra_start = try p.addExtra(@intFromEnum(id));
        _ = try p.addExtra(@intFromEnum(@as(NodeIndex, @enumFromInt(@intFromEnum(member)))));
        id = try p.addNode(.{
            .tag = .flow_qualified_type_identifier,
            .main_token = member,
            .data = .{ .extra = @enumFromInt(qextra_start) },
        });
    }

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterInstantiation(p);
    }

    const extra_start = try p.addExtra(@intFromEnum(id));
    _ = try p.addExtra(@intFromEnum(type_params));

    return p.addNode(.{
        .tag = .flow_interface_extends,
        .main_token = name_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

// ============================================================================
// Declare statements
// ============================================================================

/// Parse declare statement: declare var/class/function/module/interface/opaque/export/...
pub fn parseFlowDeclareStatement(p: *Parser) Error!NodeIndex {
    const declare_token = p.advance(); // 'declare'

    // Check if this is not actually a declare statement
    if (p.currentTag() != .identifier and p.currentTag() != .kw_var and
        p.currentTag() != .kw_class and p.currentTag() != .kw_function and
        p.currentTag() != .kw_export and p.currentTag() != .kw_default and
        p.currentTag() != .kw_import)
    {
        // Check for "let", "const" which are contextual
        if (p.currentTag() == .kw_let or p.currentTag() == .kw_const) {
            return parseFlowDeclareVariable(p, declare_token);
        }
        p.token_index = @intFromEnum(declare_token);
        return p.parseExpressionOrLabeledStatement();
    }

    if (p.currentTag() == .kw_var or p.currentTag() == .kw_let or p.currentTag() == .kw_const) {
        return parseFlowDeclareVariable(p, declare_token);
    }
    if (p.currentTag() == .kw_function) {
        return parseFlowDeclareFunction(p, declare_token);
    }
    if (p.currentTag() == .kw_class) {
        return parseFlowDeclareClass(p, declare_token);
    }
    if (p.currentTag() == .kw_export) {
        return parseFlowDeclareExport(p, declare_token);
    }
    if (p.currentTag() == .identifier) {
        switch (p.currentSoftKeyword()) {
            .module => return parseFlowDeclareModule(p, declare_token),
            .type_ => {
                _ = p.advance(); // 'type'
                const alias = try parseFlowTypeAliasInner(p, declare_token, true);
                return alias;
            },
            .opaque_ => return parseFlowDeclareOpaqueType(p, declare_token),
            .interface => return parseFlowDeclareInterface(p, declare_token),
            .enum_ => return parseFlowEnumDeclaration(p),
            else => {},
        }
        // Fallback: not a declare statement
        p.token_index = @intFromEnum(declare_token);
        return p.parseExpressionOrLabeledStatement();
    }
    p.token_index = @intFromEnum(declare_token);
    return p.parseExpressionOrLabeledStatement();
}

/// Parse type alias body (shared between `type` and `declare type`)
fn parseFlowTypeAliasInner(p: *Parser, start_token: TokenIndex, is_declare: bool) Error!NodeIndex {
    const name_token = p.advance(); // identifier

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    _ = try p.expect(.equal);
    const right = try parseFlowType(p);
    p.expectSemicolon() catch {};

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(@intFromEnum(right));

    const tag: Node.Tag = if (is_declare) .flow_declare_type_alias else .flow_type_alias;
    return p.addNode(.{
        .tag = tag,
        .main_token = start_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse declare var/let/const
fn parseFlowDeclareVariable(p: *Parser, declare_token: TokenIndex) Error!NodeIndex {
    const kind_token = p.advance(); // var/let/const
    const name_token = p.advance(); // identifier

    var type_annotation: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        type_annotation = try parseFlowTypeAnnotation(p);
    }
    p.expectSemicolon() catch {};

    const extra_start = try p.addExtra(@intFromEnum(kind_token));
    _ = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_annotation));

    return p.addNode(.{
        .tag = .flow_declare_variable,
        .main_token = declare_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse declare function
fn parseFlowDeclareFunction(p: *Parser, declare_token: TokenIndex) Error!NodeIndex {
    _ = p.advance(); // 'function'
    const name_token = p.advance(); // identifier

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    // Function type params (the actual signature)
    const func_type = try parseFlowFunctionTypeParams(p);

    // Inject outer type params into the FunctionTypeAnnotation
    if (type_params != .none and func_type != .none) {
        const func_extra_idx = @intFromEnum(p.nodes.items(.data)[@intFromEnum(func_type)].extra);
        p.extra_data.items[func_extra_idx + 4] = @intFromEnum(type_params);
        // Also update main_token to include type params start
        p.nodes.items(.main_token)[@intFromEnum(func_type)] = p.nodes.items(.main_token)[@intFromEnum(type_params)];
    }

    // Check for predicate: %checks
    var predicate: NodeIndex = .none;
    if (p.currentTag() == .percent) {
        predicate = try parseFlowPredicate(p);
        // Extend FunctionTypeAnnotation end to include the predicate (Babel compat)
        if (func_type != .none) {
            p.nodes.items(.end_offset)[@intFromEnum(func_type)] = p.nodes.items(.end_offset)[@intFromEnum(predicate)];
        }
    }

    p.expectSemicolon() catch {};

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(@intFromEnum(func_type));
    _ = try p.addExtra(@intFromEnum(predicate));

    return p.addNode(.{
        .tag = .flow_declare_function,
        .main_token = declare_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse declare class
fn parseFlowDeclareClass(p: *Parser, declare_token: TokenIndex) Error!NodeIndex {
    _ = p.advance(); // 'class'
    const name_token = p.advance(); // identifier

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    // extends — use InterfaceExtends parsing to support qualified names like C.B.D
    // Note: declare class only allows a single extends (not comma-separated)
    const extends_scratch_start = p.scratch.items.len;
    if (p.currentTag() == .kw_extends) {
        _ = p.advance();
        const ext = try parseFlowInterfaceExtends(p);
        try p.scratch.append(p.allocator, ext);
    }
    const extends_items = p.scratch.items[extends_scratch_start..];
    const extends_range = try p.addExtraRange(extends_items);
    p.scratch.shrinkRetainingCapacity(extends_scratch_start);

    // mixins
    const mixin_scratch_start = p.scratch.items.len;
    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .mixins) {
        _ = p.advance();
        while (true) {
            const mixin = try parseFlowInterfaceExtends(p);
            try p.scratch.append(p.allocator, mixin);
            if (p.currentTag() != .comma) break;
            _ = p.advance();
        }
    }
    const mixin_items = p.scratch.items[mixin_scratch_start..];
    const mixin_range = try p.addExtraRange(mixin_items);
    p.scratch.shrinkRetainingCapacity(mixin_scratch_start);

    // implements
    const impl_scratch_start = p.scratch.items.len;
    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .implements) {
        _ = p.advance();
        while (true) {
            const impl = try parseFlowInterfaceExtends(p);
            try p.scratch.append(p.allocator, impl);
            if (p.currentTag() != .comma) break;
            _ = p.advance();
        }
    }
    const impl_items = p.scratch.items[impl_scratch_start..];
    const impl_range = try p.addExtraRange(impl_items);
    p.scratch.shrinkRetainingCapacity(impl_scratch_start);

    // Body — object type
    const saved_in_declare_class = p.flow_in_declare_class;
    p.flow_in_declare_class = true;
    defer p.flow_in_declare_class = saved_in_declare_class;
    const body = try parseFlowObjectType(p);

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(extends_range.start);
    _ = try p.addExtra(extends_range.end);
    _ = try p.addExtra(impl_range.start);
    _ = try p.addExtra(impl_range.end);
    _ = try p.addExtra(@intFromEnum(body));
    _ = try p.addExtra(mixin_range.start);
    _ = try p.addExtra(mixin_range.end);

    return p.addNode(.{
        .tag = .flow_declare_class,
        .main_token = declare_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse declare module
fn parseFlowDeclareModule(p: *Parser, declare_token: TokenIndex) Error!NodeIndex {
    _ = p.advance(); // 'module'

    // declare module.exports: Type
    if (p.currentTag() == .dot) {
        _ = p.advance(); // .
        // expect 'exports'
        if (p.currentTag() != .identifier or p.currentSoftKeyword() != .exports) {
            p.errors.addError("expected \"exports\"", p.currentStart());
            return error.ParseError;
        }
        _ = p.advance(); // 'exports'
        const colon_token = try p.expect(.colon);
        const ty = try parseFlowType(p);
        p.expectSemicolon() catch {};
        // Extra layout: [colon_token, type_node]
        const extra_start = try p.addExtra(@intFromEnum(colon_token));
        _ = try p.addExtra(@intFromEnum(ty));
        return p.addNode(.{
            .tag = .flow_declare_module_exports,
            .main_token = declare_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    // declare module "name" { ... } or declare module name { ... }
    const name_token = p.advance(); // string or identifier

    const lbrace_token = try p.expect(.l_brace);

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    const saved_in_declare_module = p.flow_in_declare_module;
    p.flow_in_declare_module = true;
    defer p.flow_in_declare_module = saved_in_declare_module;

    while (p.currentTag() != .r_brace and p.currentTag() != .eof) {
        const stmt = try parseFlowDeclareModuleStatement(p);
        try p.scratch.append(p.allocator, stmt);
    }
    _ = try p.expect(.r_brace);

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(lbrace_token));
    _ = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    return p.addNode(.{
        .tag = .flow_declare_module,
        .main_token = declare_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse a statement inside declare module { ... }
fn parseFlowDeclareModuleStatement(p: *Parser) Error!NodeIndex {
    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .declare) {
        return parseFlowDeclareStatement(p);
    }
    if (p.currentTag() == .kw_import) {
        return p.parseImportDeclaration();
    }
    // Allow export, type, interface, etc
    if (p.currentTag() == .kw_export) {
        return p.parseExportDeclaration();
    }
    return p.parseStatementOrDeclaration();
}

/// Helper to build a flow_declare_export_declaration node.
/// Extra layout: [declaration, flags, source_token, specs_start, specs_end]
/// flags: bit 0 = is_default
fn addFlowDeclareExportNode(p: *Parser, declare_token: TokenIndex, declaration: NodeIndex, is_default: bool, source_token: TokenIndex, specs_start: u32, specs_end: u32) Error!NodeIndex {
    var flags: u32 = 0;
    if (is_default) flags |= 1;
    const extra_start = try p.addExtra(@intFromEnum(declaration));
    _ = try p.addExtra(flags);
    _ = try p.addExtra(@intFromEnum(source_token));
    _ = try p.addExtra(specs_start);
    _ = try p.addExtra(specs_end);
    return p.addNode(.{
        .tag = .flow_declare_export_declaration,
        .main_token = declare_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse declare export
fn parseFlowDeclareExport(p: *Parser, declare_token: TokenIndex) Error!NodeIndex {
    _ = p.advance(); // 'export'

    // declare export default ...
    if (p.currentTag() == .kw_default) {
        _ = p.advance(); // 'default'
        var decl: NodeIndex = .none;
        if (p.currentTag() == .kw_function) {
            // Inner DeclareFunction starts at 'function' keyword
            const kw_token: TokenIndex = @enumFromInt(p.token_index);
            decl = try parseFlowDeclareFunction(p, kw_token);
        } else if (p.currentTag() == .kw_class) {
            const kw_token: TokenIndex = @enumFromInt(p.token_index);
            decl = try parseFlowDeclareClass(p, kw_token);
        } else {
            decl = try parseFlowType(p);
            p.expectSemicolon() catch {};
        }
        return addFlowDeclareExportNode(p, declare_token, decl, true, no_token, 0, 0);
    }

    // declare export type ...
    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .type_) {
        // Could be: declare export type Foo = ... OR declare export type * from "..."
        if (p.lookAhead(1) == .asterisk) {
            _ = p.advance(); // 'type'
            _ = p.advance(); // '*'
            _ = try p.expect(.kw_from);
            const src_token = try p.expect(.string);
            p.expectSemicolon() catch {};
            const extra_start = try p.addExtra(@intFromEnum(src_token));
            _ = try p.addExtra(@as(u32, 1)); // exportKind = type
            return p.addNode(.{
                .tag = .flow_declare_export_all_declaration,
                .main_token = declare_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
        }
        // Outside declare module, `declare export type` is not supported
        if (!p.flow_in_declare_module) {
            p.errors.addError("`declare export type` is not supported. Use `export type` instead.", p.currentStart());
            return error.ParseError;
        }
        // declare export type Foo = ... (type alias) — inside declare module produces TypeAlias
        const type_token: TokenIndex = @enumFromInt(p.token_index);
        _ = p.advance(); // 'type'
        const alias = try parseFlowTypeAliasInner(p, type_token, false);
        return addFlowDeclareExportNode(p, declare_token, alias, false, no_token, 0, 0);
    }

    // declare export var/let/const
    if (p.currentTag() == .kw_var or p.currentTag() == .kw_let or p.currentTag() == .kw_const) {
        if (p.currentTag() == .kw_let) {
            p.errors.addError("`declare export let` is not supported. Use `declare export var` instead.", p.currentStart());
        } else if (p.currentTag() == .kw_const) {
            p.errors.addError("`declare export const` is not supported. Use `declare export var` instead.", p.currentStart());
        }
        const kw_token: TokenIndex = @enumFromInt(p.token_index);
        const decl = try parseFlowDeclareVariable(p, kw_token);
        return addFlowDeclareExportNode(p, declare_token, decl, false, no_token, 0, 0);
    }
    // declare export function
    if (p.currentTag() == .kw_function) {
        const kw_token: TokenIndex = @enumFromInt(p.token_index);
        const decl = try parseFlowDeclareFunction(p, kw_token);
        return addFlowDeclareExportNode(p, declare_token, decl, false, no_token, 0, 0);
    }
    // declare export class
    if (p.currentTag() == .kw_class) {
        const kw_token: TokenIndex = @enumFromInt(p.token_index);
        const decl = try parseFlowDeclareClass(p, kw_token);
        return addFlowDeclareExportNode(p, declare_token, decl, false, no_token, 0, 0);
    }
    if (p.currentTag() == .identifier) {
        switch (p.currentSoftKeyword()) {
            .opaque_ => {
                const kw_token: TokenIndex = @enumFromInt(p.token_index);
                const decl = try parseFlowDeclareOpaqueType(p, kw_token);
                return addFlowDeclareExportNode(p, declare_token, decl, false, no_token, 0, 0);
            },
            .interface => {
                // Outside declare module, `declare export interface` is not supported
                if (!p.flow_in_declare_module) {
                    p.errors.addError("`declare export interface` is not supported. Use `export interface` instead.", p.currentStart());
                    return error.ParseError;
                }
                const decl = try parseFlowInterfaceDeclaration(p);
                return addFlowDeclareExportNode(p, declare_token, decl, false, no_token, 0, 0);
            },
            .enum_ => {
                const decl = try parseFlowEnumDeclaration(p);
                return addFlowDeclareExportNode(p, declare_token, decl, false, no_token, 0, 0);
            },
            else => {},
        }
    }

    // declare export { ... } [from "source"]
    if (p.currentTag() == .l_brace) {
        _ = p.advance(); // {
        const scratch_start = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_start);

        while (p.currentTag() != .r_brace and p.currentTag() != .eof) {
            const spec = try p.parseExportSpecifier();
            try p.scratch.append(p.allocator, spec);
            if (p.currentTag() != .r_brace) {
                _ = try p.expect(.comma);
            }
        }
        _ = try p.expect(.r_brace);

        var source_token: TokenIndex = @enumFromInt(0);
        if (p.eat(.kw_from) != null) {
            source_token = try p.expect(.string);
        }
        p.expectSemicolon() catch {};

        const specs = p.scratch.items[scratch_start..];
        const range = try p.addExtraRange(specs);
        return addFlowDeclareExportNode(p, declare_token, .none, false, source_token, range.start, range.end);
    }

    // declare export * from "source" OR declare export * as name from "source"
    if (p.currentTag() == .asterisk) {
        const star_token = p.advance(); // *
        if (p.eat(.kw_as) != null) {
            const ns_name_token = if (p.currentTag() == .identifier or p.currentTag() == .string or p.currentTag() == .kw_default or p.currentTag().isKeyword())
                p.advance()
            else
                try p.expect(.identifier);
            const ns_spec = try p.addNode(.{
                .tag = .export_namespace_specifier,
                .main_token = star_token,
                .data = .{ .unary = @enumFromInt(@intFromEnum(ns_name_token)) },
            });
            _ = try p.expect(.kw_from);
            const src_token = try p.expect(.string);
            p.expectSemicolon() catch {};
            const scratch_start = p.scratch.items.len;
            try p.scratch.append(p.allocator, ns_spec);
            const specs = p.scratch.items[scratch_start..];
            const range = try p.addExtraRange(specs);
            p.scratch.shrinkRetainingCapacity(scratch_start);
            return addFlowDeclareExportNode(p, declare_token, .none, false, src_token, range.start, range.end);
        }
        // declare export * from "source"
        _ = try p.expect(.kw_from);
        const src_token = try p.expect(.string);
        p.expectSemicolon() catch {};
        const extra_start = try p.addExtra(@intFromEnum(src_token));
        _ = try p.addExtra(@as(u32, 0)); // exportKind = value
        return p.addNode(.{
            .tag = .flow_declare_export_all_declaration,
            .main_token = declare_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    p.errors.addError("unexpected token after declare export", p.currentStart());
    return error.ParseError;
}

/// Parse declare interface
fn parseFlowDeclareInterface(p: *Parser, declare_token: TokenIndex) Error!NodeIndex {
    _ = p.advance(); // 'interface'
    const name_token = p.advance(); // identifier

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    // extends
    const extends_scratch_start = p.scratch.items.len;
    if (p.currentTag() == .kw_extends) {
        _ = p.advance();
        while (true) {
            const ext = try parseFlowInterfaceExtends(p);
            try p.scratch.append(p.allocator, ext);
            if (p.currentTag() != .comma) break;
            _ = p.advance();
        }
    }
    const extends_items = p.scratch.items[extends_scratch_start..];
    const extends_range = try p.addExtraRange(extends_items);
    p.scratch.shrinkRetainingCapacity(extends_scratch_start);

    const body = try parseFlowObjectType(p);

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(extends_range.start);
    _ = try p.addExtra(extends_range.end);
    _ = try p.addExtra(@intFromEnum(body));

    return p.addNode(.{
        .tag = .flow_declare_interface,
        .main_token = declare_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse declare opaque type
fn parseFlowDeclareOpaqueType(p: *Parser, declare_token: TokenIndex) Error!NodeIndex {
    _ = p.advance(); // 'opaque'
    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .type_) {
        _ = p.advance(); // 'type'
    }
    const name_token = p.advance(); // identifier

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseFlowTypeParameterDeclaration(p);
    }

    var supertype: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        _ = p.advance();
        supertype = try parseFlowType(p);
    }

    // declare opaque type does NOT allow `= implementation_type`
    // (only non-declare opaque type does)
    p.expectSemicolon() catch {};

    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(@intFromEnum(supertype));
    _ = try p.addExtra(@intFromEnum(@as(NodeIndex, .none)));

    return p.addNode(.{
        .tag = .flow_declare_opaque_type,
        .main_token = declare_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

// ============================================================================
// Predicates
// ============================================================================

/// Parse %checks or %checks(expr)
pub fn parseFlowPredicate(p: *Parser) Error!NodeIndex {
    const pct_token = p.advance(); // %
    // Expect 'checks'
    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .checks) {
        // Check for spaces between % and checks
        const pct_end = p.token_ends[@intFromEnum(pct_token)];
        const checks_start = p.token_starts[p.token_index];
        if (checks_start > pct_end) {
            p.errors.addError("Spaces between `%` and `checks` are not allowed here.", p.token_starts[@intFromEnum(pct_token)]);
        }
        _ = p.advance(); // 'checks'
        if (p.currentTag() == .l_paren) {
            _ = p.advance(); // (
            const expr = try p.parseAssignmentExpression();
            _ = try p.expect(.r_paren);
            return p.addNode(.{
                .tag = .flow_declared_predicate,
                .main_token = pct_token,
                .data = .{ .unary = expr },
            });
        }
        return p.addNode(.{
            .tag = .flow_inferred_predicate,
            .main_token = pct_token,
            .data = .{ .none = {} },
        });
    }
    p.errors.addError("expected 'checks'", p.currentStart());
    return error.ParseError;
}

// ============================================================================
// Flow Enum
// ============================================================================

/// Parse Flow enum declaration
pub fn parseFlowEnumDeclaration(p: *Parser) Error!NodeIndex {
    const enum_token = p.advance(); // 'enum'
    const name_token = p.advance(); // identifier
    _ = p.tokenText(@intCast(@intFromEnum(name_token)));

    // Optional: 'of' type
    var body_tag: Node.Tag = .flow_enum_string_body; // default
    var explicit_type = false;
    var invalid_explicit_type = false;
    var of_token: TokenIndex = @enumFromInt(0);
    if (p.currentTag() == .kw_of) {
        of_token = p.advance(); // 'of'
        explicit_type = true;
        if (p.currentTag() == .identifier) {
            const type_text = p.tokenText(p.token_index);
            if (std.mem.eql(u8, type_text, "boolean")) {
                body_tag = .flow_enum_boolean_body;
            } else if (std.mem.eql(u8, type_text, "number")) {
                body_tag = .flow_enum_number_body;
            } else if (std.mem.eql(u8, type_text, "string")) {
                body_tag = .flow_enum_string_body;
            } else if (std.mem.eql(u8, type_text, "symbol")) {
                body_tag = .flow_enum_symbol_body;
            } else {
                // Invalid explicit type
                invalid_explicit_type = true;
                p.errors.addError("Enum type is not valid. Use one of `boolean`, `number`, `string`, or `symbol`.", p.currentStart());
            }
            _ = p.advance(); // type name
        }
    }

    const lbrace_token = try p.expect(.l_brace);

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    var has_unknown_members = false;
    // Track init value types for implicit body type inference
    var has_boolean_init = false;
    var has_number_init = false;
    var has_string_init = false;
    var has_any_init = false;
    var has_defaulted = false;
    var total_members: u32 = 0;
    while (p.currentTag() != .r_brace and p.currentTag() != .eof) {
        // Check for ... (unknown members)
        if (p.currentTag() == .ellipsis) {
            _ = p.advance();
            has_unknown_members = true;
            // After ..., expect } (no trailing comma allowed)
            if (p.currentTag() != .r_brace) {
                p.errors.addError("Unexpected token", p.currentStart());
                // Skip to } for recovery
                while (p.currentTag() != .r_brace and p.currentTag() != .eof) {
                    _ = p.advance();
                }
            }
            break;
        }
        // Peek at the init value to determine body type for implicit enums
        const has_init = p.lookAhead(1) == .equal;
        if (has_init) {
            // Member has an initializer — check value type
            const val_tag = p.lookAhead(2);
            if (val_tag == .kw_true or val_tag == .kw_false) {
                has_boolean_init = true;
                has_any_init = true;
            } else if (val_tag == .numeric) {
                has_number_init = true;
                has_any_init = true;
            } else if (val_tag == .string) {
                has_string_init = true;
                has_any_init = true;
            }
        } else {
            has_defaulted = true;
        }
        total_members += 1;
        const member = try parseFlowEnumMember(p, body_tag);
        try p.scratch.append(p.allocator, member);
        if (p.currentTag() == .comma) {
            _ = p.advance();
        }
    }

    // Infer body type from member values if not explicit
    if (!explicit_type and has_any_init) {
        if (has_boolean_init and !has_number_init and !has_string_init) {
            body_tag = .flow_enum_boolean_body;
        } else if (has_number_init and !has_boolean_init and !has_string_init) {
            body_tag = .flow_enum_number_body;
        }
        // Otherwise keep default (EnumStringBody)
    }

    _ = try p.expect(.r_brace);

    var items = p.scratch.items[scratch_start..];

    // Fix member tags to match inferred body type
    if (!explicit_type) {
        for (items) |item| {
            const member_idx = @intFromEnum(item);
            const member_tag_ptr = &p.nodes.items(.tag)[member_idx];
            if (member_tag_ptr.* == .flow_enum_string_member or
                member_tag_ptr.* == .flow_enum_boolean_member or
                member_tag_ptr.* == .flow_enum_number_member)
            {
                member_tag_ptr.* = switch (body_tag) {
                    .flow_enum_boolean_body => .flow_enum_boolean_member,
                    .flow_enum_number_body => .flow_enum_number_member,
                    .flow_enum_string_body => .flow_enum_string_member,
                    else => .flow_enum_default_member,
                };
            }
        }
    }

    // === Enum validation ===
    // If invalid explicit type, drop all members and reset explicit_type
    // But preserve of_token for position (body starts at "of")
    if (invalid_explicit_type) {
        explicit_type = false;
        p.scratch.shrinkRetainingCapacity(scratch_start);
        items = p.scratch.items[scratch_start..];
    } else if (!explicit_type and has_any_init and has_defaulted) {
        // Implicit type with mixed initialized/defaulted members
        const mixed_types = (@as(u8, @intFromBool(has_boolean_init)) + @as(u8, @intFromBool(has_number_init)) + @as(u8, @intFromBool(has_string_init))) > 1;
        // Count defaulted vs initialized
        var n_defaulted: u32 = 0;
        var n_initialized: u32 = 0;
        for (p.scratch.items[scratch_start..]) |item| {
            if (p.nodes.items(.tag)[@intFromEnum(item)] == .flow_enum_default_member) {
                n_defaulted += 1;
            } else {
                n_initialized += 1;
            }
        }
        if (mixed_types or n_defaulted > n_initialized) {
            // Inconsistent member initializers — majority defaulted or mixed types
            p.errors.addError("Enum has inconsistent member initializers.", p.token_starts[@intFromEnum(name_token)]);
            p.scratch.shrinkRetainingCapacity(scratch_start);
            items = p.scratch.items[scratch_start..];
            body_tag = .flow_enum_string_body;
        } else {
            // Majority/equal initialized — infer type from inits, validate
            validateEnumMembers(p, scratch_start, body_tag, explicit_type);
            items = p.scratch.items[scratch_start..];
        }
    } else if (explicit_type and body_tag == .flow_enum_string_body and has_any_init and has_defaulted) {
        // Explicit string enum with mixed initialized/defaulted members
        var n_defaulted: u32 = 0;
        var n_initialized: u32 = 0;
        for (p.scratch.items[scratch_start..]) |item| {
            if (p.nodes.items(.tag)[@intFromEnum(item)] == .flow_enum_default_member) {
                n_defaulted += 1;
            } else {
                n_initialized += 1;
            }
        }
        p.errors.addError("Enum has inconsistent member initializers.", p.token_starts[@intFromEnum(name_token)]);
        // Drop the minority members
        var write_idx = scratch_start;
        for (p.scratch.items[scratch_start..]) |item| {
            const is_def = p.nodes.items(.tag)[@intFromEnum(item)] == .flow_enum_default_member;
            if (n_defaulted > n_initialized) {
                // Majority defaulted — keep defaulted members
                if (is_def) {
                    p.scratch.items[write_idx] = item;
                    write_idx += 1;
                }
            } else {
                // Majority initialized — keep initialized members
                if (!is_def) {
                    p.scratch.items[write_idx] = item;
                    write_idx += 1;
                }
            }
        }
        p.scratch.shrinkRetainingCapacity(write_idx);
        items = p.scratch.items[scratch_start..];
    } else if (explicit_type or (!explicit_type and has_any_init)) {
        // Explicit type or implicit with all initialized — validate each member
        validateEnumMembers(p, scratch_start, body_tag, explicit_type);
        items = p.scratch.items[scratch_start..];
    }

    const range = try p.addExtraRange(items);

    // Body node — use of_token (explicit) or lbrace_token (implicit)
    // so the position matches Babel's expectation.
    // extra: [range_start, range_end, has_unknown, explicit_type]
    const body_extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    _ = try p.addExtra(@intFromBool(has_unknown_members));
    _ = try p.addExtra(@intFromBool(explicit_type));

    const body_main_token = if ((explicit_type or invalid_explicit_type) and @intFromEnum(of_token) != 0) of_token else lbrace_token;
    const body_node = try p.addNode(.{
        .tag = body_tag,
        .main_token = body_main_token,
        .data = .{ .extra = @enumFromInt(body_extra_start) },
    });

    // Enum declaration node
    const extra_start = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(@intFromEnum(body_node));

    return p.addNode(.{
        .tag = .flow_enum_declaration,
        .main_token = enum_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn validateEnumMembers(p: *Parser, scratch_start: usize, body_tag: Node.Tag, _: bool) void {
    const items = p.scratch.items[scratch_start..];
    // Filter: keep only valid members, report errors for invalid ones
    var write_idx = scratch_start;
    for (items) |item| {
        const mi = @intFromEnum(item);
        const tag = p.nodes.items(.tag)[mi];
        const is_defaulted = tag == .flow_enum_default_member;
        var valid = true;

        // Check the actual init value token type
        var init_is_boolean = false;
        var init_is_number = false;
        var init_is_string = false;
        if (!is_defaulted) {
            const val_token = p.nodes.items(.data)[mi].token;
            const val_tt = p.token_tags[@intFromEnum(val_token)];
            init_is_boolean = (val_tt == .kw_true or val_tt == .kw_false);
            init_is_number = (val_tt == .numeric);
            init_is_string = (val_tt == .string);
        }

        switch (body_tag) {
            .flow_enum_boolean_body => {
                if (is_defaulted) {
                    p.errors.addError("Boolean enum members need to be initialized.", p.token_starts[@intFromEnum(p.nodes.items(.main_token)[mi])]);
                    valid = false;
                } else if (!init_is_boolean) {
                    p.errors.addError("Enum member initializer type mismatch.", p.token_starts[@intFromEnum(p.nodes.items(.main_token)[mi])]);
                    valid = false;
                }
            },
            .flow_enum_number_body => {
                if (is_defaulted) {
                    p.errors.addError("Number enum members need to be initialized.", p.token_starts[@intFromEnum(p.nodes.items(.main_token)[mi])]);
                    valid = false;
                } else if (!init_is_number) {
                    p.errors.addError("Enum member initializer type mismatch.", p.token_starts[@intFromEnum(p.nodes.items(.main_token)[mi])]);
                    valid = false;
                }
            },
            .flow_enum_symbol_body => {
                if (!is_defaulted) {
                    p.errors.addError("Symbol enum members cannot be initialized.", p.token_starts[@intFromEnum(p.nodes.items(.main_token)[mi])]);
                    valid = false;
                }
            },
            .flow_enum_string_body => {
                if (!is_defaulted and !init_is_string) {
                    p.errors.addError("Enum member initializer type mismatch.", p.token_starts[@intFromEnum(p.nodes.items(.main_token)[mi])]);
                    valid = false;
                }
            },
            else => {},
        }

        if (valid) {
            p.scratch.items[write_idx] = item;
            write_idx += 1;
        }
    }
    p.scratch.shrinkRetainingCapacity(write_idx);
}

/// Parse a single enum member
fn parseFlowEnumMember(p: *Parser, body_tag: Node.Tag) Error!NodeIndex {
    const name_token = p.advance(); // member name

    if (p.currentTag() == .equal) {
        _ = p.advance(); // =

        // Check if the initializer is a simple literal
        const val_tag = p.currentTag();
        const is_literal = val_tag == .kw_true or val_tag == .kw_false or
            val_tag == .numeric or val_tag == .string;

        if (!is_literal) {
            // Non-literal initializer — report error and skip to comma or closing brace
            const name_text = p.tokenText(@intFromEnum(name_token));
            _ = name_text;
            p.errors.addError("The enum member initializer needs to be a literal (either a boolean, number, or string).", p.currentStart());
            // Skip tokens until we find a comma or closing brace
            while (p.currentTag() != .comma and p.currentTag() != .r_brace and p.currentTag() != .eof) {
                _ = p.advance();
            }
            // Return a default member (it will be filtered by validation)
            return p.addNode(.{
                .tag = .flow_enum_default_member,
                .main_token = name_token,
                .data = .{ .none = {} },
            });
        }

        const value_token = p.advance(); // value

        const member_tag: Node.Tag = switch (body_tag) {
            .flow_enum_boolean_body => .flow_enum_boolean_member,
            .flow_enum_number_body => .flow_enum_number_member,
            .flow_enum_string_body => .flow_enum_string_member,
            // For symbol enums, use string_member as a marker so validation
            // recognizes it as initialized (not defaulted)
            .flow_enum_symbol_body => .flow_enum_string_member,
            else => .flow_enum_default_member,
        };

        return p.addNode(.{
            .tag = member_tag,
            .main_token = name_token,
            .data = .{ .token = value_token },
        });
    }

    // Default member (no initializer)
    return p.addNode(.{
        .tag = .flow_enum_default_member,
        .main_token = name_token,
        .data = .{ .none = {} },
    });
}

// ============================================================================
// Flow Type Annotations on Existing Nodes
// ============================================================================

/// After parsing a function param binding, check for and parse `: Type`
/// Returns the type annotation node or .none
pub fn tryParseFlowParamTypeAnnotation(p: *Parser, param_node: NodeIndex) Error!void {
    if (!p.isFlow()) return;
    if (p.currentTag() != .colon) return;

    const type_ann = try parseFlowTypeAnnotation(p);
    try p.storeParamTypeAnnotation(param_node, type_ann);
}

/// After parsing function params and before body, check for return type `: Type`
pub fn tryParseFlowReturnType(p: *Parser, func_node: NodeIndex) Error!void {
    if (!p.isFlow()) return;
    if (p.currentTag() != .colon) return;

    const type_ann = try parseFlowTypeAnnotation(p);
    try p.putReturnType(func_node, type_ann);

    // Check for predicate
    if (p.currentTag() == .percent) {
        const pred = try parseFlowPredicate(p);
        try p.flow_predicates.put(p.allocator, @intFromEnum(func_node), pred);
    }
}

/// After parsing function/class name, check for type parameters <T>
pub fn tryParseFlowTypeParameters(p: *Parser, node: NodeIndex) Error!void {
    if (!p.isFlow()) return;
    if (p.currentTag() != .less_than) return;

    const type_params = try parseFlowTypeParameterDeclaration(p);
    try p.putTypeParameters(node, type_params);
}

/// After `extends Foo`, check for super type parameters Foo<T>
pub fn tryParseFlowSuperTypeParameters(p: *Parser, node: NodeIndex) Error!void {
    if (!p.isFlow()) return;
    if (p.currentTag() != .less_than) return;

    const type_params = try parseFlowTypeParameterInstantiation(p);
    try p.flow_super_type_params.put(p.allocator, @intFromEnum(node), type_params);
}

/// After `extends`, check for `implements` clause
pub fn tryParseFlowImplements(p: *Parser, node: NodeIndex) Error!void {
    if (!p.isFlow()) return;
    if (p.currentTag() != .identifier or
        p.currentSoftKeyword() != .implements) return;

    _ = p.advance(); // implements
    const scratch_start = p.scratch.items.len;
    while (true) {
        const impl = try parseFlowInterfaceExtends(p);
        try p.scratch.append(p.allocator, impl);
        if (p.currentTag() != .comma) break;
        _ = p.advance();
    }
    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    p.scratch.shrinkRetainingCapacity(scratch_start);
    try p.flow_implements.put(p.allocator, @intFromEnum(node), .{ .start = range.start, .end = range.end });
}

/// Parse Flow type cast expression: (expr: Type)
/// Called when we detect ( expr : in Flow mode
pub fn parseFlowTypeCastExpression(p: *Parser, expr: NodeIndex) Error!NodeIndex {
    _ = p.advance(); // :
    const ty = try parseFlowType(p);
    const extra_start = try p.addExtra(@intFromEnum(expr));
    _ = try p.addExtra(@intFromEnum(ty));
    // main_token points to expression for start position; end_offset set to type end
    const expr_main = p.nodes.items(.main_token)[@intFromEnum(expr)];
    const node = try p.addNode(.{
        .tag = .flow_type_cast_expression,
        .main_token = expr_main,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
    // Set end to the end of the type node
    const ty_end = p.nodes.items(.end_offset)[@intFromEnum(ty)];
    const ty_main_end = p.token_ends[@intFromEnum(p.nodes.items(.main_token)[@intFromEnum(ty)])];
    p.nodes.items(.end_offset)[@intFromEnum(node)] = if (ty_end > 0) ty_end else ty_main_end;
    return node;
}
