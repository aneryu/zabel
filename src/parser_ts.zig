const std = @import("std");
const Token = @import("token.zig").Token;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const ExtraIndex = @import("ast.zig").ExtraIndex;
const TokenIndex = @import("ast.zig").TokenIndex;
const Parser = @import("parser.zig").Parser;
const Error = Parser.Error;

// ============================================================
// Helpers
// ============================================================

fn parseIdentifierNode(p: *Parser) Error!NodeIndex {
    const tok = p.advance();
    return p.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
}

fn keyNodeTag(tag: Token.Tag) Node.Tag {
    return switch (tag) {
        .string => .string_literal,
        .numeric => .numeric_literal,
        else => .identifier,
    };
}

fn eatInterfaceMemberSeparator(p: *Parser) void {
    if (p.currentTag() == .semicolon or p.currentTag() == .comma) {
        _ = p.advance();
    }
}

fn tsInterfaceModifierBit(tag: Token.Tag, soft: @import("parser.zig").SoftKeyword) u32 {
    if (tag == .kw_static) return Parser.TS_MOD_STATIC;
    return switch (soft) {
        .public_ => Parser.TS_MOD_PUBLIC,
        .private_ => Parser.TS_MOD_PRIVATE,
        .protected_ => Parser.TS_MOD_PROTECTED,
        .abstract_ => Parser.TS_MOD_ABSTRACT,
        .declare => Parser.TS_MOD_DECLARE,
        else => 0,
    };
}

fn parseTsInterfaceModifiers(p: *Parser) u32 {
    var mods: u32 = 0;
    while (p.currentTag() == .identifier or p.currentTag() == .kw_static) {
        const bit = tsInterfaceModifierBit(p.currentTag(), p.currentSoftKeyword());
        if (bit == 0) break;
        const la = p.lookAhead(1);
        if (la == .l_paren or la == .semicolon or la == .colon or la == .comma or la == .r_brace) break;
        if (la == .question) {
            const la2 = p.lookAhead(2);
            if (la2 == .colon or la2 == .semicolon or la2 == .comma or la2 == .r_brace) break;
        }
        mods |= bit;
        switch (bit) {
            Parser.TS_MOD_PUBLIC => p.errors.addError("Invalid interface member modifier.", p.currentStart()),
            Parser.TS_MOD_PRIVATE => p.errors.addError("Invalid interface member modifier.", p.currentStart()),
            Parser.TS_MOD_PROTECTED => p.errors.addError("Invalid interface member modifier.", p.currentStart()),
            Parser.TS_MOD_STATIC => p.errors.addError("Invalid interface member modifier.", p.currentStart()),
            Parser.TS_MOD_DECLARE => p.errors.addError("Invalid interface member modifier.", p.currentStart()),
            Parser.TS_MOD_ABSTRACT => p.errors.addError("Invalid interface member modifier.", p.currentStart()),
            else => {},
        }
        _ = p.advance();
    }
    return mods;
}

/// Check if the current token looks like a `>` closing a type parameter list,
/// handling `>>` and `>>>` token splitting via pending_greater_than.
fn isAtGreaterThan(p: *Parser) bool {
    return p.pending_greater_than > 0 or
        p.currentTag() == .greater_than or
        p.currentTag() == .greater_greater or
        p.currentTag() == .greater_greater_greater or
        p.currentTag() == .greater_equal or
        p.currentTag() == .greater_greater_equal or
        p.currentTag() == .greater_greater_greater_equal;
}

/// Consume a `>` that closes a type parameter list, splitting `>>` / `>>>` / `>=` / `>>=` / `>>>=` tokens
/// by advancing past the multi-char token and leaving pending state.
fn expectGreaterThanOrSplit(p: *Parser) Error!void {
    if (p.pending_greater_than > 0) {
        p.pending_greater_than -= 1;
        // For nested >>, the split end is 1 byte after the previous split
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
    } else if (p.currentTag() == .greater_equal) {
        // `>=` → consume as `>` + leave `=` pending
        const tok_start = p.token_starts[p.token_index];
        _ = p.advance();
        p.pending_equal = true;
        p.split_greater_end = tok_start + 1;
    } else if (p.currentTag() == .greater_greater_equal) {
        // `>>=` → consume as `>` + leave `>=` (i.e., `>` + `=`) pending
        const tok_start = p.token_starts[p.token_index];
        _ = p.advance();
        p.pending_greater_than = 1;
        p.pending_equal = true;
        p.split_greater_end = tok_start + 1;
    } else if (p.currentTag() == .greater_greater_greater_equal) {
        // `>>>=` → consume as `>` + leave `>>=` (i.e., `>>` + `=`) pending
        const tok_start = p.token_starts[p.token_index];
        _ = p.advance();
        p.pending_greater_than = 2;
        p.pending_equal = true;
        p.split_greater_end = tok_start + 1;
    } else {
        _ = try p.expect(.greater_than);
        p.split_greater_end = 0;
    }
}

// ============================================================
// TypeScript Type Parsing
// ============================================================

/// Parse `: Type` -- a type annotation.
pub fn parseTsTypeAnnotation(p: *Parser) Error!NodeIndex {
    const colon_token = try p.expect(.colon);
    const type_node = try parseTsType(p);
    return p.addNode(.{
        .tag = .ts_type_annotation,
        .main_token = colon_token,
        .data = .{ .unary = type_node },
    });
}

/// Parse a TSTypeCastExpression: `expr : Type`
/// Consumes the colon and type, creates a TSTypeCastExpression node.
pub fn parseTsTypeCastExpression(p: *Parser, expr: NodeIndex) Error!NodeIndex {
    const type_ann = try parseTsTypeAnnotation(p);
    const extra_start = try p.addExtra(@intFromEnum(expr));
    _ = try p.addExtra(@intFromEnum(type_ann));
    const expr_main = p.nodes.items(.main_token)[@intFromEnum(expr)];
    const node = try p.addNode(.{
        .tag = .ts_type_cast_expression,
        .main_token = expr_main,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
    // Set end to the end of the type annotation node
    const ann_end = p.nodes.items(.end_offset)[@intFromEnum(type_ann)];
    if (ann_end > 0) {
        p.nodes.items(.end_offset)[@intFromEnum(node)] = ann_end;
    }
    return node;
}

/// Check if the token text (possibly with unicode escapes) resolves to a given name.
fn identifierMatches(p: *Parser, idx: u32, name: []const u8) bool {
    const text = p.tokenText(idx);
    if (p.identifierEquals(idx, name)) return true;
    // Check for escaped version (e.g. \u{61}sserts -> asserts)
    if (std.mem.indexOf(u8, text, "\\u") != null) {
        const Lex = @import("lexer.zig").Lexer;
        var buf: [32]u8 = undefined;
        const resolved = Lex.resolveEscapes(text, &buf);
        return std.mem.eql(u8, resolved, name);
    }
    return false;
}

/// Parse return type annotation, handling TSTypePredicate (asserts x, x is T, asserts x is T)
pub fn parseTsReturnTypeAnnotation(p: *Parser) Error!NodeIndex {
    const colon_token = try p.expect(.colon);

    // Check for `asserts` keyword (including escaped forms like \u{61}sserts)
    if (p.currentTag() == .identifier and identifierMatches(p, p.token_index, "asserts")) {
        // Could be: `asserts x`, `asserts x is T`, `asserts this`, or just `asserts` as type name
        const la1 = p.lookAhead(1);
        if (la1 == .identifier or la1 == .kw_this) {
            // `asserts x ...` or `asserts this ...`
            const asserts_tok = p.advance(); // consume 'asserts'
            const param_name = if (p.currentTag() == .kw_this)
                try p.addNode(.{ .tag = .ts_keyword_type, .main_token = p.advance(), .data = .{ .none = {} } })
            else
                try p.addNode(.{ .tag = .identifier, .main_token = p.advance(), .data = .{ .none = {} } });

            // Check for `is Type`
            var type_ann: NodeIndex = .none;
            if (p.identifierEquals(p.token_index, "is")) {
                _ = p.advance(); // consume 'is'
                const type_start_tok: TokenIndex = @enumFromInt(p.token_index);
                const is_type = try parseTsType(p);
                type_ann = try p.addNode(.{
                    .tag = .ts_type_annotation,
                    .main_token = type_start_tok,
                    .data = .{ .unary = is_type },
                });
            }

            const extra_start = try p.addExtra(@intFromEnum(param_name));
            _ = try p.addExtra(@intFromEnum(type_ann));
            _ = try p.addExtra(1); // asserts = true

            const predicate = try p.addNode(.{
                .tag = .ts_type_predicate,
                .main_token = asserts_tok,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });

            return p.addNode(.{
                .tag = .ts_type_annotation,
                .main_token = colon_token,
                .data = .{ .unary = predicate },
            });
        }
        // `asserts;` — just a type named "asserts", fall through
    }

    // Check for `x is T` (non-asserts predicate)
    if ((p.currentTag() == .identifier or p.currentTag() == .kw_this) and
        p.lookAhead(1) == .identifier)
    {
        if (p.identifierEquals(p.token_index + 1, "is")) {
            const start_tok: TokenIndex = @enumFromInt(p.token_index);
            const param_name = if (p.currentTag() == .kw_this)
                try p.addNode(.{ .tag = .ts_keyword_type, .main_token = p.advance(), .data = .{ .none = {} } })
            else
                try p.addNode(.{ .tag = .identifier, .main_token = p.advance(), .data = .{ .none = {} } });
            _ = p.advance(); // consume 'is'
            const type_start_tok: TokenIndex = @enumFromInt(p.token_index);
            const is_type = try parseTsType(p);
            const type_ann = try p.addNode(.{
                .tag = .ts_type_annotation,
                .main_token = type_start_tok,
                .data = .{ .unary = is_type },
            });

            const extra_start = try p.addExtra(@intFromEnum(param_name));
            _ = try p.addExtra(@intFromEnum(type_ann));
            _ = try p.addExtra(0); // asserts = false

            const predicate = try p.addNode(.{
                .tag = .ts_type_predicate,
                .main_token = start_tok,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });

            return p.addNode(.{
                .tag = .ts_type_annotation,
                .main_token = colon_token,
                .data = .{ .unary = predicate },
            });
        }
    }

    // Regular type annotation
    const type_node = try parseTsType(p);
    return p.addNode(.{
        .tag = .ts_type_annotation,
        .main_token = colon_token,
        .data = .{ .unary = type_node },
    });
}

/// Parse a full TypeScript type expression.
pub fn parseTsType(p: *Parser) Error!NodeIndex {
    return parseTsConditionalTypeOrLower(p);
}

/// Parse conditional type: T extends U ? X : Y
fn parseTsConditionalTypeOrLower(p: *Parser) Error!NodeIndex {
    var check_type = try parseTsUnionType(p);

    if (p.currentTag() == .kw_extends) {
        // Once we know it's a conditional type, `intrinsic` in sub-types is a type reference
        p.ts_in_type_alias = false;
        // Use the checkType's main_token as start for the whole conditional
        const check_start_tok = p.nodes.items(.main_token)[@intFromEnum(check_type)];
        _ = p.advance(); // consume extends
        const saved_cond_extends = p.ts_in_conditional_extends;
        p.ts_in_conditional_extends = true;
        const extends_type = try parseTsUnionType(p);
        p.ts_in_conditional_extends = saved_cond_extends;
        _ = try p.expect(.question);
        const true_type = try parseTsType(p);
        _ = try p.expect(.colon);
        const false_type = try parseTsType(p);

        const extra_start = try p.addExtra(@intFromEnum(check_type));
        _ = try p.addExtra(@intFromEnum(extends_type));
        _ = try p.addExtra(@intFromEnum(true_type));
        _ = try p.addExtra(@intFromEnum(false_type));

        check_type = try p.addNode(.{
            .tag = .ts_conditional_type,
            .main_token = check_start_tok,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    return check_type;
}

/// Parse union type: T | U | V
fn parseTsUnionType(p: *Parser) Error!NodeIndex {
    const has_leading_pipe = p.eat(.pipe) != null;
    const leading_pipe_tok: TokenIndex = if (has_leading_pipe) @enumFromInt(p.token_index - 1) else @enumFromInt(0);

    // If there's a leading pipe, `intrinsic` in this context is a type reference
    const saved_in_type_alias = p.ts_in_type_alias;
    if (has_leading_pipe) p.ts_in_type_alias = false;

    const first = try parseTsIntersectionType(p);
    if (p.currentTag() != .pipe and !has_leading_pipe) {
        p.ts_in_type_alias = saved_in_type_alias;
        return first;
    }

    // Once we know it's a union, `intrinsic` in subsequent members is a type reference
    p.ts_in_type_alias = false;

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    p.scratch.append(p.allocator, first) catch return error.ParseError;

    while (p.eat(.pipe) != null) {
        const member = try parseTsIntersectionType(p);
        p.scratch.append(p.allocator, member) catch return error.ParseError;
    }
    p.ts_in_type_alias = saved_in_type_alias;

    const items = p.scratch.items[scratch_top..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    // When there's a leading |, use its position as the start
    const main_tok = if (has_leading_pipe) leading_pipe_tok else p.nodes.items(.main_token)[@intFromEnum(first)];
    return p.addNode(.{
        .tag = .ts_union_type,
        .main_token = main_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse intersection type: T & U & V
fn parseTsIntersectionType(p: *Parser) Error!NodeIndex {
    const has_leading_amp = p.eat(.ampersand) != null;
    const leading_amp_tok: TokenIndex = if (has_leading_amp) @enumFromInt(p.token_index - 1) else @enumFromInt(0);

    // If there's a leading &, `intrinsic` in this context is a type reference
    const saved_in_type_alias = p.ts_in_type_alias;
    if (has_leading_amp) p.ts_in_type_alias = false;

    const first = try parseTsTypeOperatorOrLower(p);
    if (p.currentTag() != .ampersand and !has_leading_amp) {
        p.ts_in_type_alias = saved_in_type_alias;
        return first;
    }

    // Once we know it's an intersection, `intrinsic` in subsequent members is a type reference
    p.ts_in_type_alias = false;

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    p.scratch.append(p.allocator, first) catch return error.ParseError;

    while (p.eat(.ampersand) != null) {
        const member = try parseTsTypeOperatorOrLower(p);
        p.scratch.append(p.allocator, member) catch return error.ParseError;
    }
    p.ts_in_type_alias = saved_in_type_alias;

    const items = p.scratch.items[scratch_top..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    const main_tok = if (has_leading_amp) leading_amp_tok else p.nodes.items(.main_token)[@intFromEnum(first)];
    return p.addNode(.{
        .tag = .ts_intersection_type,
        .main_token = main_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse type operators: keyof T, unique symbol, readonly T[]
fn parseTsTypeOperatorOrLower(p: *Parser) Error!NodeIndex {
    if (p.currentTag() == .identifier) {
        switch (p.currentSoftKeyword()) {
            .keyof, .unique, .readonly => return parseTsTypeOperator(p),
            .infer => return parseTsInferType(p),
            else => {},
        }
    }
    if (p.currentTag() == .kw_typeof) {
        return parseTsTypeofType(p);
    }
    return parseTsPostfixType(p);
}

/// Parse `keyof T`, `unique symbol`, `readonly T[]`
pub fn parseTsTypeOperator(p: *Parser) Error!NodeIndex {
    const op_tok = p.advance();
    const operand = try parseTsTypeOperatorOrLower(p);
    return p.addNode(.{
        .tag = .ts_type_operator,
        .main_token = op_tok,
        .data = .{ .unary = operand },
    });
}

/// Parse `infer T`
pub fn parseTsInferType(p: *Parser) Error!NodeIndex {
    const infer_tok = p.advance();
    const name_tok = try p.expect(.identifier);

    var constraint: NodeIndex = .none;
    if (p.currentTag() == .kw_extends) {
        // Speculatively try parsing the constraint.
        // If the constraint is followed by `?`, this creates ambiguity with
        // conditional types. When we're inside the extends clause of a conditional type
        // (ts_in_conditional_extends), `?` terminates the infer constraint and starts
        // the conditional branches. Otherwise (e.g. inside parens), `?` means
        // `extends` is NOT the infer constraint but part of a nested conditional.
        const save = p.saveState();
        _ = p.advance(); // consume extends
        // Don't allow nested conditional types inside the infer constraint
        const saved_cond_extends = p.ts_in_conditional_extends;
        p.ts_in_conditional_extends = false;
        const parsed = parseTsUnionType(p) catch blk: {
            p.ts_in_conditional_extends = saved_cond_extends;
            p.restoreState(save);
            break :blk @as(NodeIndex, .none);
        };
        p.ts_in_conditional_extends = saved_cond_extends;
        if (parsed == .none or (p.currentTag() == .question and !saved_cond_extends)) {
            // Restore state — don't consume extends as constraint
            p.restoreState(save);
        } else {
            constraint = parsed;
        }
    }

    const extra_start = try p.addExtra(@intFromEnum(constraint));
    _ = try p.addExtra(@intFromEnum(@as(NodeIndex, .none)));
    _ = try p.addExtra(@intFromEnum(name_tok)); // name token for serializer

    const tp_node = try p.addNode(.{
        .tag = .ts_type_parameter,
        .main_token = name_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });

    return p.addNode(.{
        .tag = .ts_infer_type,
        .main_token = infer_tok,
        .data = .{ .unary = tp_node },
    });
}

/// Parse `typeof expr` (optionally with type arguments: `typeof x.y<T>`)
pub fn parseTsTypeofType(p: *Parser) Error!NodeIndex {
    const typeof_tok = p.advance();

    // Handle `typeof import("mod")` — TSTypeQuery wrapping TSImportType
    if (p.currentTag() == .kw_import) {
        const import_node = try parseTsImportType(p);
        return p.addNode(.{
            .tag = .ts_typeof_type,
            .main_token = typeof_tok,
            .data = .{ .unary = import_node },
        });
    }

    // Handle `typeof this` or `typeof this.x.y`
    const expr = if (p.currentTag() == .kw_this) blk: {
        const this_tok = p.advance();
        var node = try p.addNode(.{ .tag = .this_expr, .main_token = this_tok, .data = .{ .none = {} } });
        // After `this`, handle `.x.y` qualified access
        while (p.eat(.dot) != null) {
            if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
                p.errors.addError("expected identifier", p.currentStart());
                return error.ParseError;
            }
            const right_tok = p.advance();
            const right = try p.addNode(.{ .tag = .identifier, .main_token = right_tok, .data = .{ .none = {} } });
            node = try p.addNode(.{
                .tag = .ts_qualified_name,
                .main_token = this_tok,
                .data = .{ .binary = .{ .lhs = node, .rhs = right } },
            });
        }
        break :blk node;
    } else try parseTsEntityName(p);

    // Optional type arguments: typeof y.z<w>
    // Don't parse type arguments after a newline (ASI boundary)
    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than and !p.hasNewlineBefore()) {
        type_params = try parseTsTypeParameterInstantiation(p);
    }

    if (type_params != .none) {
        // Store type parameters in side table for the typeof node
        try p.putTypeParameters(@enumFromInt(p.nodes.len), type_params);
    }

    return p.addNode(.{
        .tag = .ts_typeof_type,
        .main_token = typeof_tok,
        .data = .{ .unary = expr },
    });
}

/// Parse postfix types: T[], T[K]
fn parseTsPostfixType(p: *Parser) Error!NodeIndex {
    var base = try parseTsPrimaryType(p);

    // `intrinsic` keyword type does not participate in postfix operations
    if (p.nodes.items(.tag)[@intFromEnum(base)] == .ts_keyword_type) {
        const base_tok = @intFromEnum(p.nodes.items(.main_token)[@intFromEnum(base)]);
        if (p.softKeywordAt(base_tok) == .intrinsic) return base;
    }

    while (true) {
        if (p.currentTag() == .l_bracket) {
            if (p.lookAhead(1) == .r_bracket) {
                _ = p.advance(); // [
                _ = p.advance(); // ]
                base = try p.addNode(.{
                    .tag = .ts_array_type,
                    .main_token = p.nodes.items(.main_token)[@intFromEnum(base)],
                    .data = .{ .unary = base },
                });
            } else {
                base = try parseTsIndexedAccessType(p, base);
            }
        } else {
            break;
        }
    }

    return base;
}

/// Parse T[K]
pub fn parseTsIndexedAccessType(p: *Parser, object_type: NodeIndex) Error!NodeIndex {
    const bracket_tok = p.advance();
    const index_type = try parseTsType(p);
    _ = try p.expect(.r_bracket);

    return p.addNode(.{
        .tag = .ts_indexed_access_type,
        .main_token = bracket_tok,
        .data = .{ .binary = .{ .lhs = object_type, .rhs = index_type } },
    });
}

/// Parse a primary type
fn parseTsPrimaryType(p: *Parser) Error!NodeIndex {
    // Handle pending_less_than: the second `<` from a `<<` split starts a function type
    if (p.pending_less_than) {
        return parseTsFunctionType(p);
    }
    switch (p.currentTag()) {
        .identifier => {
            const soft = p.currentSoftKeyword();
            if (isKeywordType(p.tokenText(p.token_index))) {
                return parseTsKeywordType(p);
            }
            // `intrinsic` is a keyword type ONLY in type alias context (`type X = intrinsic`)
            // and when not followed by `.` or `<` (which indicate it's a type reference)
            if (soft == .intrinsic and p.ts_in_type_alias and p.lookAhead(1) != .dot and p.lookAhead(1) != .less_than) {
                return parseTsKeywordType(p);
            }
            // `abstract new () => Type` — abstract constructor type
            if (soft == .abstract_ and p.lookAhead(1) == .kw_new) {
                const abstract_tok = p.advance(); // consume "abstract"
                const node = try parseTsConstructorType(p);
                // Set start to the `abstract` keyword
                p.nodes.items(.main_token)[@intFromEnum(node)] = abstract_tok;
                return node;
            }
            return parseTsTypeReference(p);
        },
        .kw_void => return parseTsKeywordType(p),
        .kw_typeof => return parseTsTypeofType(p),
        .kw_this => {
            const tok = p.advance();
            return p.addNode(.{
                .tag = .ts_keyword_type,
                .main_token = tok,
                .data = .{ .none = {} },
            });
        },
        .l_paren => return parseTsParenthesizedOrFunctionType(p),
        .l_bracket => return parseTsTupleType(p),
        .l_brace => return parseTsMappedOrObjectType(p),
        .kw_new => return parseTsConstructorType(p),
        .kw_import => return parseTsImportType(p),
        .string => {
            const tok = p.advance();
            const lit = try p.addNode(.{ .tag = .string_literal, .main_token = tok, .data = .{ .none = {} } });
            return p.addNode(.{ .tag = .ts_literal_type, .main_token = tok, .data = .{ .unary = lit } });
        },
        .numeric => {
            const tok = p.advance();
            const lit = try p.addNode(.{ .tag = .numeric_literal, .main_token = tok, .data = .{ .none = {} } });
            return p.addNode(.{ .tag = .ts_literal_type, .main_token = tok, .data = .{ .unary = lit } });
        },
        .bigint => {
            const tok = p.advance();
            const lit = try p.addNode(.{ .tag = .bigint_literal, .main_token = tok, .data = .{ .none = {} } });
            return p.addNode(.{ .tag = .ts_literal_type, .main_token = tok, .data = .{ .unary = lit } });
        },
        .kw_true, .kw_false => {
            const tok = p.advance();
            const lit = try p.addNode(.{ .tag = .boolean_literal, .main_token = tok, .data = .{ .none = {} } });
            return p.addNode(.{ .tag = .ts_literal_type, .main_token = tok, .data = .{ .unary = lit } });
        },
        .kw_null => {
            // Babel emits TSNullKeyword, not TSLiteralType wrapping NullLiteral
            const tok = p.advance();
            return p.addNode(.{ .tag = .ts_keyword_type, .main_token = tok, .data = .{ .none = {} } });
        },
        .minus => {
            const minus_tok = p.advance();
            if (p.currentTag() == .numeric or p.currentTag() == .bigint) {
                const is_bigint = p.currentTag() == .bigint;
                const num_tok = p.advance();
                const lit_tag: Node.Tag = if (is_bigint) .bigint_literal else .numeric_literal;
                const lit = try p.addNode(.{ .tag = lit_tag, .main_token = num_tok, .data = .{ .none = {} } });
                const neg = try p.addNode(.{ .tag = .unary_expr, .main_token = minus_tok, .data = .{ .unary = lit } });
                return p.addNode(.{ .tag = .ts_literal_type, .main_token = minus_tok, .data = .{ .unary = neg } });
            }
            p.errors.addError("expected numeric literal after -", p.currentStart());
            return error.ParseError;
        },
        .template_no_sub, .template_head => return parseTsTemplateLiteralType(p),
        .less_than => {
            // Generic function type: <T>(a: T) => T
            return parseTsFunctionType(p);
        },
        else => {
            p.errors.addError("expected type", p.currentStart());
            return error.ParseError;
        },
    }
}

fn isKeywordType(text: []const u8) bool {
    const keywords = [_][]const u8{
        "string", "number",  "boolean", "symbol",    "bigint",
        "any",    "unknown", "never",   "undefined", "object",
        "null",   "void",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, text, kw)) return true;
    }
    return false;
}

fn parseTsKeywordType(p: *Parser) Error!NodeIndex {
    const tok = p.advance();
    return p.addNode(.{
        .tag = .ts_keyword_type,
        .main_token = tok,
        .data = .{ .none = {} },
    });
}

/// Parse a type reference: Identifier, A.B.C, or Identifier<T, U>
pub fn parseTsTypeReference(p: *Parser) Error!NodeIndex {
    const name = try parseTsEntityName(p);

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than or p.currentTag() == .less_less) {
        type_params = try parseTsTypeParameterInstantiation(p);
    }

    const node = try p.addNode(.{
        .tag = .ts_type_reference,
        .main_token = p.nodes.items(.main_token)[@intFromEnum(name)],
        .data = .{ .binary = .{ .lhs = name, .rhs = type_params } },
    });

    // When type params had a split `>` (from `>>`), propagate the corrected end position
    if (type_params != .none) {
        const tp_end = p.nodes.items(.end_offset)[@intFromEnum(type_params)];
        if (tp_end > 0) {
            p.nodes.items(.end_offset)[@intFromEnum(node)] = tp_end;
        }
    }

    return node;
}

/// Parse A.B.C qualified name
fn parseTsEntityName(p: *Parser) Error!NodeIndex {
    return parseTsEntityNameImpl(p, false);
}

fn parseTsEntityNameAsIdentifier(p: *Parser) Error!NodeIndex {
    return parseTsEntityNameImpl(p, true);
}

fn parseTsEntityNameImpl(p: *Parser, this_as_identifier: bool) Error!NodeIndex {
    if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
        p.errors.addError("expected identifier", p.currentStart());
        return error.ParseError;
    }
    const name_tok = p.advance();
    // `this` keyword produces ThisExpression unless in import type qualifier context
    const node_tag: Node.Tag = if (p.token_tags[@intFromEnum(name_tok)] == .kw_this and !this_as_identifier) .this_expr else .identifier;
    var node = try p.addNode(.{ .tag = node_tag, .main_token = name_tok, .data = .{ .none = {} } });

    while (p.eat(.dot) != null) {
        if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
            p.errors.addError("expected identifier", p.currentStart());
            return error.ParseError;
        }
        const right_tok = p.advance();
        const right = try p.addNode(.{ .tag = .identifier, .main_token = right_tok, .data = .{ .none = {} } });
        node = try p.addNode(.{
            .tag = .ts_qualified_name,
            .main_token = name_tok,
            .data = .{ .binary = .{ .lhs = node, .rhs = right } },
        });
    }

    return node;
}

/// Parse parenthesized type or function type
fn parseTsParenthesizedOrFunctionType(p: *Parser) Error!NodeIndex {
    // Reset conditional extends flag inside parens — `(infer U extends T ? U : T)`
    // should parse `?` as a nested conditional, not the outer conditional's separator.
    const saved_cond_extends = p.ts_in_conditional_extends;
    p.ts_in_conditional_extends = false;
    defer p.ts_in_conditional_extends = saved_cond_extends;

    // Try function type first with backtracking
    const saved = p.saveState();

    if (parseTsFunctionType(p)) |func_node| {
        return func_node;
    } else |_| {
        p.restoreState(saved);
    }

    const paren_tok = p.advance(); // (
    const inner = try parseTsType(p);
    _ = try p.expect(.r_paren);

    return p.addNode(.{
        .tag = .ts_parenthesized_type,
        .main_token = paren_tok,
        .data = .{ .unary = inner },
    });
}

/// Parse function type: (params) => ReturnType
fn parseTsFunctionType(p: *Parser) Error!NodeIndex {
    var type_params: NodeIndex = .none;
    // When pending_less_than is set, the `<` is from a `<<` token split;
    // the start position is the `<<` token, not the current token.
    const start_tok: TokenIndex = if (p.pending_less_than)
        @enumFromInt(p.token_index -| 1)
    else
        @enumFromInt(p.token_index);

    if (p.currentTag() == .less_than or p.pending_less_than) {
        type_params = try parseTsTypeParameterDeclaration(p);
    }

    _ = try p.expect(.l_paren);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (p.currentTag() != .r_paren and p.currentTag() != .eof) {
        if (p.currentTag() == .ellipsis) {
            const rest_tok = p.advance();
            const param_name = try p.expect(.identifier);
            const name_node = try p.addNode(.{ .tag = .identifier, .main_token = param_name, .data = .{ .none = {} } });
            var rest_type_ann: NodeIndex = .none;
            if (p.currentTag() == .colon) {
                rest_type_ann = try parseTsTypeAnnotation(p);
            }
            const rest_node = try p.addNode(.{
                .tag = .rest_element,
                .main_token = rest_tok,
                .data = .{ .unary = name_node },
            });
            // Store type annotation on rest element, not on the identifier
            if (rest_type_ann != .none) {
                try p.storeTypeAnnotation(rest_node, rest_type_ann);
            }
            p.scratch.append(p.allocator, rest_node) catch return error.ParseError;
        } else if (p.currentTag() == .l_brace or p.currentTag() == .l_bracket) {
            // Destructuring pattern parameter: ({ x }, [a]) in function type
            const saved_ts_in_type_params = p.ts_in_type_params;
            p.ts_in_type_params = true;
            const pattern = try p.parseBindingPattern();
            p.ts_in_type_params = saved_ts_in_type_params;
            if (p.eat(.question) != null) {
                try p.ts_optional_params.put(p.allocator, @intFromEnum(pattern), {});
            }
            if (p.currentTag() == .colon) {
                const type_ann = try parseTsTypeAnnotation(p);
                try p.storeTypeAnnotation(pattern, type_ann);
            }
            p.scratch.append(p.allocator, pattern) catch return error.ParseError;
        } else {
            if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
                return error.ParseError;
            }
            const param_name = p.advance();
            const name_node = try p.addNode(.{ .tag = .identifier, .main_token = param_name, .data = .{ .none = {} } });
            if (p.eat(.question) != null) {
                try p.ts_optional_params.put(p.allocator, @intFromEnum(name_node), {});
            }
            if (p.currentTag() == .colon) {
                const type_ann = try parseTsTypeAnnotation(p);
                try p.storeTypeAnnotation(name_node, type_ann);
            }
            p.scratch.append(p.allocator, name_node) catch return error.ParseError;
        }
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_paren);
    const arrow_tok = try p.expect(.arrow);

    const return_type = try parseTsType(p);

    const items = p.scratch.items[scratch_top..];
    const range = try p.addExtraRange(items);

    const extra_start = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    _ = try p.addExtra(@intFromEnum(return_type));
    _ = try p.addExtra(@intFromEnum(arrow_tok)); // arrow token for returnType position

    return p.addNode(.{
        .tag = .ts_function_type,
        .main_token = start_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse constructor type: new (params) => RetType
fn parseTsConstructorType(p: *Parser) Error!NodeIndex {
    const new_tok = p.advance();

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseTsTypeParameterDeclaration(p);
    }

    _ = try p.expect(.l_paren);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (p.currentTag() != .r_paren and p.currentTag() != .eof) {
        if (p.currentTag() == .ellipsis) {
            const rest_tok = p.advance();
            if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) break;
            const param_name = p.advance();
            const name_node = try p.addNode(.{ .tag = .identifier, .main_token = param_name, .data = .{ .none = {} } });
            if (p.currentTag() == .colon) {
                const type_ann = try parseTsTypeAnnotation(p);
                try p.storeTypeAnnotation(name_node, type_ann);
            }
            const rest_node = try p.addNode(.{
                .tag = .rest_element,
                .main_token = rest_tok,
                .data = .{ .unary = name_node },
            });
            p.scratch.append(p.allocator, rest_node) catch return error.ParseError;
        } else {
            if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) break;
            const param_name = p.advance();
            const name_node = try p.addNode(.{ .tag = .identifier, .main_token = param_name, .data = .{ .none = {} } });
            if (p.eat(.question) != null) {
                try p.ts_optional_params.put(p.allocator, @intFromEnum(name_node), {});
            }
            if (p.currentTag() == .colon) {
                const type_ann = try parseTsTypeAnnotation(p);
                try p.storeTypeAnnotation(name_node, type_ann);
            }
            p.scratch.append(p.allocator, name_node) catch return error.ParseError;
        }
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_paren);
    const ctor_arrow_tok = try p.expect(.arrow);

    const return_type = try parseTsType(p);

    const items = p.scratch.items[scratch_top..];
    const range = try p.addExtraRange(items);

    const extra_start = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    _ = try p.addExtra(@intFromEnum(return_type));
    _ = try p.addExtra(@intFromEnum(ctor_arrow_tok)); // arrow token for returnType position

    return p.addNode(.{
        .tag = .ts_constructor_type,
        .main_token = new_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Check if current position looks like a labeled tuple member: `label:` or `label?:`
fn looksLikeTupleLabel(p: *Parser) bool {
    if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) return false;
    const next = p.lookAhead(1);
    if (next == .colon) return true;
    if (next == .question and p.lookAhead(2) == .colon) return true;
    return false;
}

/// Parse tuple type: [T, U, V] or labeled [foo: T, bar?: U]
fn parseTsTupleType(p: *Parser) Error!NodeIndex {
    const bracket_tok = p.advance();
    // Reset conditional extends flag inside brackets — `[infer U extends T ? U : T]`
    // should parse `?` as a nested conditional, not the outer conditional's separator.
    const saved_cond_extends = p.ts_in_conditional_extends;
    p.ts_in_conditional_extends = false;
    defer p.ts_in_conditional_extends = saved_cond_extends;

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (p.currentTag() != .r_bracket and p.currentTag() != .eof) {
        if (p.currentTag() == .ellipsis) {
            const rest_tok = p.advance();
            // Check for labeled rest: ...label: Type
            if (looksLikeTupleLabel(p)) {
                const label_tok = p.advance(); // label
                const label = try p.addNode(.{ .tag = .identifier, .main_token = label_tok, .data = .{ .none = {} } });
                _ = try p.expect(.colon); // :
                const elem = try parseTsType(p);
                const named = try p.addNode(.{
                    .tag = .ts_named_tuple_member,
                    .main_token = label_tok,
                    .data = .{ .binary = .{ .lhs = label, .rhs = elem } },
                });
                const rest_node = try p.addNode(.{
                    .tag = .ts_rest_type,
                    .main_token = rest_tok,
                    .data = .{ .unary = named },
                });
                p.scratch.append(p.allocator, rest_node) catch return error.ParseError;
            } else {
                const elem = try parseTsType(p);
                const rest_node = try p.addNode(.{
                    .tag = .ts_rest_type,
                    .main_token = rest_tok,
                    .data = .{ .unary = elem },
                });
                p.scratch.append(p.allocator, rest_node) catch return error.ParseError;
            }
        } else if (looksLikeTupleLabel(p)) {
            // Labeled tuple member: label: Type or label?: Type
            const label_tok = p.advance();
            const label = try p.addNode(.{ .tag = .identifier, .main_token = label_tok, .data = .{ .none = {} } });
            var is_optional = p.eat(.question) != null;
            _ = try p.expect(.colon);
            const elem = try parseTsType(p);
            // Detect `label: Type?` — the ? should be before the colon
            if (!is_optional and p.currentTag() == .question) {
                p.errors.addError("A labeled tuple optional element must be declared using a question mark after the name and before the colon (`name?: type`), rather than after the type (`name: type?`).", p.currentStart());
                _ = p.advance(); // consume the ?
                is_optional = true;
            }
            const rhs = if (is_optional)
                try p.addNode(.{
                    .tag = .ts_optional_type,
                    .main_token = label_tok,
                    .data = .{ .unary = elem },
                })
            else
                elem;
            const named = try p.addNode(.{
                .tag = .ts_named_tuple_member,
                .main_token = label_tok,
                .data = .{ .binary = .{ .lhs = label, .rhs = rhs } },
            });
            p.scratch.append(p.allocator, named) catch return error.ParseError;
        } else {
            const elem = try parseTsType(p);
            if (p.currentTag() == .colon) {
                // Invalid label: e.g. [x.y: A] or [x<y>: A]
                p.errors.addError("Tuple members must be labeled with a simple identifier.", p.currentStart());
                _ = p.advance(); // consume ':'
                const elem_type = try parseTsType(p);
                const named = try p.addNode(.{
                    .tag = .ts_named_tuple_member,
                    .main_token = p.nodes.items(.main_token)[@intFromEnum(elem)],
                    .data = .{ .binary = .{ .lhs = elem, .rhs = elem_type } },
                });
                p.scratch.append(p.allocator, named) catch return error.ParseError;
            } else if (p.currentTag() == .question) {
                _ = p.advance();
                const opt_node = try p.addNode(.{
                    .tag = .ts_optional_type,
                    .main_token = p.nodes.items(.main_token)[@intFromEnum(elem)],
                    .data = .{ .unary = elem },
                });
                p.scratch.append(p.allocator, opt_node) catch return error.ParseError;
            } else {
                p.scratch.append(p.allocator, elem) catch return error.ParseError;
            }
        }
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_bracket);

    const items = p.scratch.items[scratch_top..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    return p.addNode(.{
        .tag = .ts_tuple_type,
        .main_token = bracket_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse mapped type or object type literal
fn parseTsMappedOrObjectType(p: *Parser) Error!NodeIndex {
    if (looksLikeMappedType(p)) {
        return parseTsMappedType(p);
    }
    // Object type literal — reuse interface body parsing but with TSTypeLiteral tag
    return parseTsTypeLiteral(p);
}

fn looksLikeMappedType(p: *Parser) bool {
    if (p.currentTag() != .l_brace) return false;
    var offset: u32 = 1;
    const next = p.lookAhead(offset);
    if (next == .plus or next == .minus) {
        offset += 1;
        if (p.lookAhead(offset) == .identifier and p.softKeywordAt(p.token_index + offset) == .readonly) {
            offset += 1;
        }
    } else if (next == .identifier and p.softKeywordAt(p.token_index + offset) == .readonly) {
        offset += 1;
    }

    if (p.lookAhead(offset) != .l_bracket) return false;
    if (p.lookAhead(offset + 1) != .identifier) return false;
    return p.lookAhead(offset + 2) == .kw_in;
}

/// Parse mapped type: { [K in T]: V }
pub fn parseTsMappedType(p: *Parser) Error!NodeIndex {
    const brace_tok = p.advance();

    var readonly_modifier: u32 = 0;
    if (p.currentTag() == .plus or p.currentTag() == .minus) {
        readonly_modifier = if (p.currentTag() == .plus) 2 else 3;
        _ = p.advance();
        if (p.currentTag() == .identifier and p.currentSoftKeyword() == .readonly) {
            _ = p.advance();
        }
    } else if (p.currentTag() == .identifier and p.currentSoftKeyword() == .readonly) {
        readonly_modifier = 1;
        _ = p.advance();
    }

    _ = try p.expect(.l_bracket);

    const key_tok = try p.expect(.identifier);
    _ = try p.addNode(.{ .tag = .identifier, .main_token = key_tok, .data = .{ .none = {} } });

    _ = try p.expect(.kw_in);
    const constraint = try parseTsType(p);

    var name_type: NodeIndex = .none;
    if (p.currentTag() == .kw_as) {
        _ = p.advance();
        name_type = try parseTsType(p);
    }

    _ = try p.expect(.r_bracket);

    var optional_modifier: u32 = 0;
    if (p.currentTag() == .plus or p.currentTag() == .minus) {
        optional_modifier = if (p.currentTag() == .plus) 2 else 3;
        _ = p.advance();
        _ = p.eat(.question);
    } else if (p.eat(.question) != null) {
        optional_modifier = 1;
    }

    var type_annotation: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        _ = p.advance();
        type_annotation = try parseTsType(p);
    }

    _ = p.eat(.semicolon);
    _ = try p.expect(.r_brace);

    const tp_extra_start = try p.addExtra(@intFromEnum(constraint));
    _ = try p.addExtra(@intFromEnum(@as(NodeIndex, .none)));
    _ = try p.addExtra(@intFromEnum(key_tok)); // name token for serializer
    const type_param = try p.addNode(.{
        .tag = .ts_type_parameter,
        .main_token = key_tok,
        .data = .{ .extra = @enumFromInt(tp_extra_start) },
    });

    const extra_start = try p.addExtra(@intFromEnum(type_param));
    _ = try p.addExtra(@intFromEnum(type_annotation));
    _ = try p.addExtra(@intFromEnum(name_type));
    _ = try p.addExtra(optional_modifier);
    _ = try p.addExtra(readonly_modifier);

    return p.addNode(.{
        .tag = .ts_mapped_type,
        .main_token = brace_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse template literal type: `hello ${T}`
pub fn parseTsTemplateLiteralType(p: *Parser) Error!NodeIndex {
    if (p.currentTag() == .template_no_sub) {
        const tok = p.advance();
        // Template with no substitutions: wrap as TSLiteralType { literal: TemplateLiteral }
        const tpl_node = try p.addNode(.{
            .tag = .template_literal,
            .main_token = tok,
            .data = .{ .none = {} },
        });
        return p.addNode(.{
            .tag = .ts_literal_type,
            .main_token = tok,
            .data = .{ .unary = tpl_node },
        });
    }

    const head_tok = p.advance();

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    // Store types and template continuation tokens interleaved:
    // [type1, type2, ...], then [tail_or_middle_tok1, tail_or_middle_tok2, ...]
    var tpl_toks: std.ArrayList(u32) = .empty;
    defer tpl_toks.deinit(p.allocator);

    while (true) {
        const expr_type = try parseTsType(p);
        p.scratch.append(p.allocator, expr_type) catch return error.ParseError;

        if (p.currentTag() == .template_tail) {
            const tail_tok: u32 = p.token_index;
            tpl_toks.append(p.allocator, tail_tok) catch return error.ParseError;
            _ = p.advance();
            break;
        } else if (p.currentTag() == .template_middle) {
            const mid_tok: u32 = p.token_index;
            tpl_toks.append(p.allocator, mid_tok) catch return error.ParseError;
            _ = p.advance();
        } else {
            p.errors.addError("expected template continuation", p.currentStart());
            break;
        }
    }

    const items = p.scratch.items[scratch_top..];
    const range = try p.addExtraRange(items);
    // Store template token indices as raw u32 values
    const tpl_start: u32 = @intCast(p.extra_data.items.len);
    for (tpl_toks.items) |tok_idx| {
        try p.extra_data.append(p.allocator, tok_idx);
    }
    const tpl_end: u32 = @intCast(p.extra_data.items.len);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    _ = try p.addExtra(tpl_start);
    _ = try p.addExtra(tpl_end);

    return p.addNode(.{
        .tag = .ts_template_literal_type,
        .main_token = head_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse import("mod").Type
pub fn parseTsImportType(p: *Parser) Error!NodeIndex {
    const import_tok = p.advance();
    _ = try p.expect(.l_paren);

    // The argument must be a string literal; if not, report an error but
    // parse the type anyway for recovery.
    const arg_node = if (p.currentTag() == .string) blk: {
        const arg_tok = p.advance();
        break :blk try p.addNode(.{ .tag = .string_literal, .main_token = arg_tok, .data = .{ .none = {} } });
    } else blk: {
        p.errors.addError("Argument in a type import must be a string literal.", p.currentStart());
        break :blk try parseTsType(p);
    };

    // Parse optional options: import("mod", { with: {...} })
    var options_node: NodeIndex = .none;
    if (p.eat(.comma) != null) {
        // Validate: must start with `{`
        if (p.currentTag() != .l_brace) {
            p.errors.addError("expected \"{\"", p.currentStart());
            // Try to recover by parsing as expression
            options_node = try p.parseAssignmentExpression();
        } else {
            // Save position to validate structure after parsing
            const opts_start = p.currentStart();
            _ = opts_start;
            options_node = try parseTsImportTypeOptions(p);
        }
        // Trailing comma after options object is NOT allowed in import type
        if (p.currentTag() == .comma) {
            // Don't consume it - let expect(.r_paren) fail with the right error
        }
    }

    _ = try p.expect(.r_paren);

    var qualifier: NodeIndex = .none;
    if (p.eat(.dot) != null) {
        // In import type qualifier, `this` should be an Identifier (not ThisExpression)
        qualifier = try parseTsEntityNameAsIdentifier(p);
    }

    var type_params: NodeIndex = .none;
    if (p.currentTag() == .less_than) {
        type_params = try parseTsTypeParameterInstantiation(p);
    }

    const extra_start = try p.addExtra(@intFromEnum(arg_node));
    _ = try p.addExtra(@intFromEnum(qualifier));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(@intFromEnum(options_node));

    return p.addNode(.{
        .tag = .ts_import_type,
        .main_token = import_tok,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse import type options: `{ with: { key: "value", ... } }`
/// Validates the structure matches what TypeScript expects.
fn parseTsImportTypeOptions(p: *Parser) Error!NodeIndex {
    const outer_brace = p.advance(); // consume l_brace

    // Expect identifier `with` — not a string, not an escaped identifier
    if (p.currentTag() == .string) {
        // `{ "with": ... }` — "with" as string key is invalid
        p.errors.addError("expected \"with\"", p.currentStart());
    } else if (!((p.currentTag() == .identifier and p.currentSoftKeyword() == .with_) or p.currentTag() == .kw_with)) {
        // Check for unicode-escaped `with` (e.g. `w\u0069th`)
        // The lexer produces the un-escaped text, so if token text equals "with" but
        // the raw source contains a backslash, it's escaped.
        if (p.currentTag() == .identifier) {
            const tok_start = p.token_starts[p.token_index];
            const tok_end = p.token_ends[p.token_index];
            const raw = p.source[tok_start..tok_end];
            if (std.mem.indexOf(u8, raw, "\\") != null) {
                p.errors.addError("expected \"with\"", p.currentStart());
            } else {
                p.errors.addError("expected \"with\"", p.currentStart());
            }
        } else {
            p.errors.addError("expected \"with\"", p.currentStart());
        }
    }

    // Parse the outer object as a regular expression — handles all valid cases
    // (string keys in inner object, trailing commas, etc.) and allows
    // error recovery for invalid cases.
    // Reset back to the outer brace and parse as expression
    p.token_index = @intFromEnum(outer_brace);
    const node = try p.parseAssignmentExpression();

    // Post-parse validation: check inner object for invalid constructs
    // Walk the parsed AST nodes to find issues
    // (The error tests need to produce errors for spread elements, computed properties, etc.)
    validateImportTypeOptions(p, node);

    return node;
}

/// Validate that import type options don't contain invalid constructs
fn validateImportTypeOptions(p: *Parser, node: NodeIndex) void {
    if (node == .none) return;
    const i = @intFromEnum(node);
    if (i >= p.nodes.len) return;
    const tag = p.nodes.items(.tag)[i];
    const data = p.nodes.items(.data)[i];

    switch (tag) {
        .object_expr => {
            // Check properties
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx < p.extra_data.items.len) {
                const range_start = p.extra_data.items[extra_idx];
                const range_end = p.extra_data.items[extra_idx + 1];
                if (range_start <= range_end and range_end <= p.extra_data.items.len) {
                    for (p.extra_data.items[range_start..range_end]) |prop_raw| {
                        const prop: NodeIndex = @enumFromInt(prop_raw);
                        validateImportTypeOptions(p, prop);
                    }
                }
            }
        },
        .spread_element => {
            // Spread in import options is not allowed
            const mt = p.nodes.items(.main_token)[i];
            p.errors.addError("Unexpected token", p.token_starts[@intFromEnum(mt)]);
        },
        .computed_property => {
            // Computed properties in import options are not allowed
            const mt = p.nodes.items(.main_token)[i];
            p.errors.addError("Unexpected token", p.token_starts[@intFromEnum(mt)]);
        },
        .property, .shorthand_property => {
            // Check the value recursively
            if (tag == .property) {
                validateImportTypeOptions(p, data.binary.rhs);
            }
        },
        else => {},
    }
}

// ============================================================
// Type Parameters
// ============================================================

/// Parse `<T, U extends Foo = Default>` type parameter declaration.
/// Returns .none if no `<` is found.
pub fn parseTsTypeParameterDeclaration(p: *Parser) Error!NodeIndex {
    var lt_token: @import("token.zig").TokenIndex = undefined;
    if (p.pending_less_than) {
        // Second half of a `<<` split — use the same token
        p.pending_less_than = false;
        lt_token = @enumFromInt(p.token_index -| 1);
    } else if (p.currentTag() == .less_than) {
        lt_token = p.advance();
    } else {
        return .none;
    }

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (!isAtGreaterThan(p) and p.currentTag() != .eof) {
        const param = try parseTsTypeParameter(p);
        try p.scratch.append(p.allocator, param);
        if (p.eat(.comma) == null) break;
    }

    try expectGreaterThanOrSplit(p);

    // Capture the split greater end before addNode resets it
    const gt_end = p.split_greater_end;

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    const node = try p.addNode(.{
        .tag = .ts_type_parameter_declaration,
        .main_token = lt_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });

    // Fix end position when `>` was split from `>=`, `>>=`, etc.
    if (gt_end > 0) {
        p.nodes.items(.end_offset)[@intFromEnum(node)] = gt_end;
    }

    return node;
}

fn parseTsTypeParameter(p: *Parser) Error!NodeIndex {
    // Handle `in`, `out`, `const`, `public`/`private`/`protected` modifiers
    const first_token: TokenIndex = @enumFromInt(p.token_index);
    var flags: u32 = 0;
    while (p.currentTag() == .identifier or p.currentTag() == .kw_const or p.currentTag() == .kw_in) {
        const soft = p.currentSoftKeyword();
        if (p.currentTag() == .kw_in) {
            flags |= 1; // in
            _ = p.advance();
        } else if (soft == .out) {
            flags |= 2; // out
            _ = p.advance();
        } else if (p.currentTag() == .kw_const) {
            flags |= 4; // const
            _ = p.advance();
        } else if (soft == .public_) {
            flags |= (1 << 3); // accessibility: public
            _ = p.advance();
        } else if (soft == .private_) {
            flags |= (2 << 3); // accessibility: private
            _ = p.advance();
        } else if (soft == .protected_) {
            flags |= (3 << 3); // accessibility: protected
            _ = p.advance();
        } else break;
    }

    // Validate type parameter name is an identifier or keyword
    if (p.currentTag() != .identifier and !p.currentTag().isKeyword()) {
        p.errors.addError("Unexpected token", p.currentStart());
        return error.ParseError;
    }
    const name_token = p.advance();

    var constraint: NodeIndex = .none;
    if (p.currentTag() == .kw_extends) {
        _ = p.advance();
        constraint = try parseTsType(p);
    }

    var default_type: NodeIndex = .none;
    if (p.currentTag() == .equal) {
        _ = p.advance();
        default_type = try parseTsType(p);
    }

    // Extra data layout: [constraint, default_type, name_token_raw, flags]
    const extra_start = try p.addExtra(@intFromEnum(constraint));
    _ = try p.addExtra(@intFromEnum(default_type));
    _ = try p.addExtra(@intFromEnum(name_token));
    _ = try p.addExtra(flags);

    return p.addNode(.{
        .tag = .ts_type_parameter,
        .main_token = first_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse `<Type, Type>` type argument instantiation.
/// Returns .none if no `<` is found.
/// Also handles `<<` (bit-shift-left-like) by splitting into two `<` tokens.
pub fn parseTsTypeParameterInstantiation(p: *Parser) Error!NodeIndex {
    var lt_token: @import("token.zig").TokenIndex = undefined;
    if (p.pending_less_than) {
        // We already consumed the `<<` token; this `<` is the second half.
        p.pending_less_than = false;
        // Use the same token as main_token (it's the `<<` token, but position is ok)
        lt_token = @enumFromInt(p.token_index -| 1);
    } else if (p.currentTag() == .less_than) {
        lt_token = p.advance();
    } else if (p.currentTag() == .less_less) {
        // Split `<<` into `<` + `<`: consume the token and set pending_less_than
        lt_token = p.advance();
        p.pending_less_than = true;
    } else {
        return .none;
    }

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (!isAtGreaterThan(p) and p.currentTag() != .eof) {
        const arg = try parseTsType(p);
        try p.scratch.append(p.allocator, arg);
        if (p.eat(.comma) == null) break;
    }

    try expectGreaterThanOrSplit(p);

    const gt_end = p.split_greater_end;

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    const node = try p.addNode(.{
        .tag = .ts_type_parameter_instantiation,
        .main_token = lt_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });

    if (gt_end > 0) {
        p.nodes.items(.end_offset)[@intFromEnum(node)] = gt_end;
    }

    return node;
}

// ============================================================
// TypeScript Expression Extensions
// ============================================================

/// Parse `expr as Type`
pub fn parseTsAsExpression(p: *Parser, lhs: NodeIndex) Error!NodeIndex {
    const as_tok = p.advance();
    // `as const` — treat `const` as a type reference
    const type_node = if (p.currentTag() == .kw_const)
        try parseTsTypeReference(p)
    else
        try parseTsType(p);
    return p.addNode(.{
        .tag = .ts_as_expression,
        .main_token = as_tok,
        .data = .{ .binary = .{ .lhs = lhs, .rhs = type_node } },
    });
}

/// Parse `expr satisfies Type`
pub fn parseTsSatisfiesExpression(p: *Parser, lhs: NodeIndex) Error!NodeIndex {
    const sat_tok = p.advance();
    // `satisfies const` — treat `const` as a type reference
    const type_node = if (p.currentTag() == .kw_const)
        try parseTsTypeReference(p)
    else
        try parseTsType(p);
    return p.addNode(.{
        .tag = .ts_satisfies_expression,
        .main_token = sat_tok,
        .data = .{ .binary = .{ .lhs = lhs, .rhs = type_node } },
    });
}

/// Parse `expr!`
pub fn parseTsNonNullExpression(p: *Parser, lhs: NodeIndex) Error!NodeIndex {
    const bang_tok = p.advance();
    return p.addNode(.{
        .tag = .ts_non_null_expression,
        .main_token = bang_tok,
        .data = .{ .unary = lhs },
    });
}

/// Parse `<Type>expr`
pub fn parseTsTypeAssertion(p: *Parser) Error!NodeIndex {
    const lt_tok = p.advance();
    // `<const>expr` — treat `const` as a type reference
    const type_node = if (p.currentTag() == .kw_const)
        try parseTsTypeReference(p)
    else
        try parseTsType(p);
    _ = try p.expect(.greater_than);
    const expr = try p.parseExpressionPrec(.unary);
    return p.addNode(.{
        .tag = .ts_type_assertion,
        .main_token = lt_tok,
        .data = .{ .binary = .{ .lhs = type_node, .rhs = expr } },
    });
}

// ============================================================
// TypeScript Declaration Parsing
// ============================================================

/// Dispatch `declare ...` statements
pub fn parseTsDeclareStatement(p: *Parser) Error!NodeIndex {
    const declare_tok = p.advance(); // consume "declare"
    const saved_ambient = p.ts_in_ambient;
    p.ts_in_ambient = true;
    defer p.ts_in_ambient = saved_ambient;

    if (p.currentTag() == .kw_function or
        (p.currentTag() == .kw_async and p.lookAhead(1) == .kw_function))
    {
        const node = try parseTsDeclareFunction(p);
        p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
        return node;
    }

    // Check for "const enum" before the general variable declaration check
    if (p.isTsConstEnum()) {
        const node = try parseTsEnumDeclaration(p);
        p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
        return node;
    }

    if (p.currentTag() == .kw_var or p.currentTag() == .kw_let or p.currentTag() == .kw_const) {
        const node = try parseTsDeclareVariable(p);
        p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
        return node;
    }

    // declare using ... / declare await using ...
    if (p.currentTag() == .kw_await and p.lookAhead(1) == .identifier and
        p.softKeywordAt(p.token_index + 1) == .using_)
    {
        p.errors.addError("'declare' modifier cannot appear on a using declaration.", p.token_starts[@intFromEnum(declare_tok)]);
        const node = try p.parseAwaitUsingDeclaration();
        p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
        return node;
    }
    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .using_) {
        p.errors.addError("'declare' modifier cannot appear on a using declaration.", p.token_starts[@intFromEnum(declare_tok)]);
        const node = try p.parseUsingDeclaration();
        p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
        return node;
    }

    if (p.currentTag() == .kw_class) {
        const cls = try p.parseClassDeclaration();
        p.nodes.items(.main_token)[@intFromEnum(cls)] = declare_tok;
        const key = @intFromEnum(cls);
        const existing = p.ts_class_modifiers.get(key) orelse 0;
        try p.ts_class_modifiers.put(p.allocator, key, existing | Parser.TS_MOD_DECLARE);
        return cls;
    }

    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .abstract_ and p.lookAhead(1) == .kw_class and !p.hasNewlineAfterCurrent()) {
        _ = p.advance(); // abstract
        const cls = try p.parseClassDeclaration();
        p.nodes.items(.main_token)[@intFromEnum(cls)] = declare_tok;
        const key = @intFromEnum(cls);
        const existing = p.ts_class_modifiers.get(key) orelse 0;
        try p.ts_class_modifiers.put(p.allocator, key, existing | Parser.TS_MOD_DECLARE | Parser.TS_MOD_ABSTRACT);
        return cls;
    }

    if (p.currentTag() == .identifier) {
        switch (p.currentSoftKeyword()) {
            .enum_ => {
                const node = try parseTsEnumDeclaration(p);
                p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
                return node;
            },
            .namespace, .module => {
                if (!p.hasNewlineAfterCurrent()) {
                    const node = try parseTsModuleDeclaration(p);
                    p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
                    return node;
                }
            },
            .interface => {
                const node = try parseTsInterfaceDeclaration(p);
                p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
                return node;
            },
            .type_ => {
                const node = try parseTsTypeAliasDeclaration(p);
                p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
                return node;
            },
            .global => {
                const node = try parseTsModuleDeclaration(p);
                p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
                return node;
            },
            else => {},
        }
        if (p.identifierEquals(p.token_index, "const")) {
            const node = try parseTsEnumDeclaration(p);
            p.nodes.items(.main_token)[@intFromEnum(node)] = declare_tok;
            return node;
        }
    }

    p.errors.addError("unexpected token after 'declare'", p.currentStart());
    return error.ParseError;
}

/// Parse `type Foo<T> = Type;`
pub fn parseTsTypeAliasDeclaration(p: *Parser) Error!NodeIndex {
    const type_token = p.advance(); // consume "type"
    const id = try parseIdentifierNode(p);
    const type_params = try parseTsTypeParameterDeclaration(p);
    // Handle `>=` split: if `>` consumed a `>=` token, the `=` is pending
    if (p.pending_equal) {
        p.pending_equal = false;
    } else {
        _ = try p.expect(.equal);
    }
    const saved_in_type_alias = p.ts_in_type_alias;
    p.ts_in_type_alias = true;
    const type_ann = try parseTsType(p);
    p.ts_in_type_alias = saved_in_type_alias;
    p.expectSemicolon() catch {};

    const extra_start = try p.addExtra(@intFromEnum(id));
    _ = try p.addExtra(@intFromEnum(type_ann));
    _ = try p.addExtra(@intFromEnum(type_params));

    return p.addNode(.{
        .tag = .ts_type_alias_declaration,
        .main_token = type_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse `interface Foo<T> extends Bar, Baz { ... }`
pub fn parseTsInterfaceDeclaration(p: *Parser) Error!NodeIndex {
    const iface_token = p.advance(); // consume "interface"
    var id: NodeIndex = .none;
    if (p.currentTag() == .l_brace) {
        p.errors.addError("'interface' declarations must be followed by an identifier.", p.currentStart());
    } else {
        id = try parseIdentifierNode(p);
    }
    const type_params = try parseTsTypeParameterDeclaration(p);
    const extends_range = try parseTsInterfaceExtends(p);
    const body = try parseTsInterfaceBody(p);

    const extra_start = try p.addExtra(@intFromEnum(id));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(@intFromEnum(body));
    _ = try p.addExtra(extends_range.start);
    _ = try p.addExtra(extends_range.end);

    return p.addNode(.{
        .tag = .ts_interface_declaration,
        .main_token = iface_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn parseTsInterfaceExtends(p: *Parser) Error!Parser.Range {
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    if (p.currentTag() == .kw_extends) {
        _ = p.advance();
        // Handle empty extends (e.g., `interface Foo extends {}`)
        if (p.currentTag() != .l_brace) {
            while (true) {
                // Try type reference first (valid path: Identifier or Qualified.Name<T>)
                const save = p.saveState();
                if (parseTsTypeReference(p)) |ref| {
                    // Check for import.meta parsed as qualified name — should be MetaProperty
                    const ref_data = p.nodes.items(.data)[@intFromEnum(ref)];
                    const name_node = ref_data.binary.lhs;
                    const name_tag = p.nodes.items(.tag)[@intFromEnum(name_node)];
                    const is_import_meta = blk: {
                        if (name_tag != .ts_qualified_name) break :blk false;
                        const qn_data = p.nodes.items(.data)[@intFromEnum(name_node)];
                        const left_tok = p.nodes.items(.main_token)[@intFromEnum(qn_data.binary.lhs)];
                        break :blk p.token_tags[@intFromEnum(left_tok)] == .kw_import;
                    };
                    if (is_import_meta) {
                        // Re-parse as expression to get MetaProperty
                        p.restoreState(save);
                        p.errors.addError("'extends' list can only include identifiers or qualified-names with optional type arguments.", p.currentStart());
                        const wrapped = try parseTsInvalidExtendsItem(p);
                        try p.scratch.append(p.allocator, wrapped);
                    } else if (p.currentTag() == .comma or p.currentTag() == .l_brace) {
                        // Verify we consumed the full item: next must be `,` or `{`
                        try p.scratch.append(p.allocator, ref);
                    } else {
                        p.restoreState(save);
                        p.errors.addError("'extends' list can only include identifiers or qualified-names with optional type arguments.", p.currentStart());
                        const wrapped = try parseTsInvalidExtendsItem(p);
                        try p.scratch.append(p.allocator, wrapped);
                    }
                } else |_| {
                    p.restoreState(save);
                    p.errors.addError("'extends' list can only include identifiers or qualified-names with optional type arguments.", p.currentStart());
                    const wrapped = try parseTsInvalidExtendsItem(p);
                    try p.scratch.append(p.allocator, wrapped);
                }
                if (p.currentTag() != .comma) break;
                _ = p.advance();
            }
        }
    }

    const items = p.scratch.items[scratch_start..];
    return p.addExtraRange(items);
}

/// Parse an invalid extends item as a general expression, wrapped in ts_type_reference.
/// Unwraps parenthesized expressions and fixes start positions to match Babel.
fn parseTsInvalidExtendsItem(p: *Parser) Error!NodeIndex {
    var expr = try p.parseExpressionPrec(.call);
    // Unwrap parenthesized expression: (foo.bar) → foo.bar
    if (p.nodes.items(.tag)[@intFromEnum(expr)] == .parenthesized_expr) {
        expr = p.nodes.items(.data)[@intFromEnum(expr)].unary;
    }
    const main_tok = p.nodes.items(.main_token)[@intFromEnum(expr)];
    return p.addNode(.{
        .tag = .ts_type_reference,
        .main_token = main_tok,
        .data = .{ .binary = .{ .lhs = expr, .rhs = .none } },
    });
}

/// Parse `{ ... }` body with members. Used for both TSInterfaceBody and TSTypeLiteral.
fn parseTsBodyMembers(p: *Parser, tag: Node.Tag) Error!NodeIndex {
    const lbrace_token = try p.expect(.l_brace);

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (p.currentTag() != .r_brace and p.currentTag() != .eof) {
        const member = parseTsInterfaceMember(p) catch {
            skipToInterfaceMemberBoundary(p);
            continue;
        };
        try p.scratch.append(p.allocator, member);
    }

    _ = try p.expect(.r_brace);

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    return p.addNode(.{
        .tag = tag,
        .main_token = lbrace_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse `{ ... }` interface body with members.
pub fn parseTsInterfaceBody(p: *Parser) Error!NodeIndex {
    return parseTsBodyMembers(p, .ts_interface_body);
}

/// Parse `{ ... }` type literal with members.
fn parseTsTypeLiteral(p: *Parser) Error!NodeIndex {
    return parseTsBodyMembers(p, .ts_type_literal);
}

fn skipToInterfaceMemberBoundary(p: *Parser) void {
    while (p.currentTag() != .eof) {
        switch (p.currentTag()) {
            .r_brace => return,
            .semicolon => {
                _ = p.advance();
                return;
            },
            else => _ = p.advance(),
        }
    }
}

fn parseTsInterfaceMember(p: *Parser) Error!NodeIndex {
    const member_start: TokenIndex = @enumFromInt(p.token_index);
    if (p.currentTag() == .l_paren or p.currentTag() == .less_than) {
        return parseTsCallSignatureDeclaration(p);
    }
    if (p.currentTag() == .kw_new) {
        return parseTsConstructSignatureDeclaration(p);
    }
    if (p.currentTag() == .l_bracket) {
        if (isIndexSignature(p)) {
            return parseTsIndexSignature(p);
        }
    }

    var flags: u32 = 0;
    var kind: u32 = 0; // 0=method, 1=get, 2=set
    const ts_mods = parseTsInterfaceModifiers(p);

    // readonly modifier
    if (p.currentTag() == .identifier and p.currentSoftKeyword() == .readonly) {
        flags |= 2;
        _ = p.advance();
    }

    // get/set accessor-style signatures
    if ((p.currentTag() == .kw_get or p.currentTag() == .kw_set) and
        p.lookAhead(1) != .l_paren and p.lookAhead(1) != .semicolon and
        p.lookAhead(1) != .colon and p.lookAhead(1) != .comma and
        p.lookAhead(1) != .r_brace)
    {
        kind = if (p.currentTag() == .kw_get) 1 else 2;
        _ = p.advance();
    }

    var key: NodeIndex = .none;
    _ = if (p.currentTag() == .l_bracket) blk: {
        flags |= 4;
        const bracket_tok = try p.expect(.l_bracket);
        key = try p.parseAssignmentExpression();
        _ = try p.expect(.r_bracket);
        break :blk bracket_tok;
    } else if (p.currentTag() == .hash) blk: {
        // Private name: #identifier
        const hash_tok = p.advance();
        const ident_tok = p.advance();
        const ident_node = try p.addNode(.{ .tag = .identifier, .main_token = ident_tok, .data = .{ .none = {} } });
        key = try p.addNode(.{ .tag = .private_name, .main_token = hash_tok, .data = .{ .unary = ident_node } });
        p.errors.addError("Unexpected private name.", p.token_starts[@intFromEnum(hash_tok)]);
        break :blk hash_tok;
    } else blk: {
        const tok = p.advance();
        key = try p.addNode(.{ .tag = keyNodeTag(p.token_tags[@intFromEnum(tok)]), .main_token = tok, .data = .{ .none = {} } });
        break :blk tok;
    };

    if (p.currentTag() == .question) {
        flags |= 1;
        _ = p.advance();
    }

    if (p.currentTag() == .l_paren or p.currentTag() == .less_than) {
        const node = try parseTsMethodSignatureBody(p, member_start, key, flags, kind);
        if ((flags & 2) != 0) {
            p.errors.addError("Invalid interface member modifier.", p.token_starts[@intFromEnum(member_start)]);
        }
        // Include readonly in ts_mods for serialization
        const effective_mods = ts_mods | (if ((flags & 2) != 0) Parser.TS_MOD_READONLY else 0);
        try p.storeTsModifiers(node, effective_mods);
        return node;
    }

    if (kind != 0) {
        p.errors.addError("Invalid accessor signature.", p.token_starts[@intFromEnum(member_start)]);
        return error.ParseError;
    }

    var type_ann: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        type_ann = try parseTsTypeAnnotation(p);
    }
    if (p.currentTag() == .equal) {
        p.errors.addError("Property signatures cannot have initializers.", p.currentStart());
        return error.ParseError;
    }

    eatInterfaceMemberSeparator(p);

    const extra_start = try p.addExtra(@intFromEnum(key));
    _ = try p.addExtra(@intFromEnum(type_ann));
    _ = try p.addExtra(flags);

    const node = try p.addNode(.{
        .tag = .ts_property_signature,
        .main_token = member_start,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
    try p.storeTsModifiers(node, ts_mods);
    return node;
}

fn parseTsCallSignatureDeclaration(p: *Parser) Error!NodeIndex {
    const main_token: TokenIndex = @enumFromInt(p.token_index);
    const type_params = try parseTsTypeParameterDeclaration(p);
    const params_range = try parseTsFunctionParams(p);

    var return_type: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        return_type = try parseTsReturnTypeAnnotation(p);
    }

    eatInterfaceMemberSeparator(p);

    const extra_start = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(params_range.start);
    _ = try p.addExtra(params_range.end);
    _ = try p.addExtra(@intFromEnum(return_type));

    return p.addNode(.{
        .tag = .ts_call_signature_declaration,
        .main_token = main_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn parseTsConstructSignatureDeclaration(p: *Parser) Error!NodeIndex {
    const new_token = p.advance();
    const type_params = try parseTsTypeParameterDeclaration(p);
    const params_range = try parseTsFunctionParams(p);

    var return_type: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        return_type = try parseTsReturnTypeAnnotation(p);
    }

    eatInterfaceMemberSeparator(p);

    const extra_start = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(params_range.start);
    _ = try p.addExtra(params_range.end);
    _ = try p.addExtra(@intFromEnum(return_type));

    return p.addNode(.{
        .tag = .ts_construct_signature_declaration,
        .main_token = new_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn isIndexSignature(p: *Parser) bool {
    if (p.lookAhead(1) == .identifier and p.lookAhead(2) == .colon) return true;
    return false;
}

pub fn parseTsIndexSignature(p: *Parser) Error!NodeIndex {
    const lbracket_token = try p.expect(.l_bracket);
    const param_name = try parseIdentifierNode(p);

    var param_type: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        param_type = try parseTsTypeAnnotation(p);
        try p.storeTypeAnnotation(param_name, param_type);
    }

    _ = try p.expect(.r_bracket);

    var type_ann: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        type_ann = try parseTsTypeAnnotation(p);
    }

    eatInterfaceMemberSeparator(p);

    const extra_start = try p.addExtra(@intFromEnum(param_name));
    _ = try p.addExtra(@intFromEnum(param_type));
    _ = try p.addExtra(@intFromEnum(type_ann));

    return p.addNode(.{
        .tag = .ts_index_signature,
        .main_token = lbracket_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse a TypeScript index signature in class body context.
/// Called when we detect `[identifier :` pattern in a class body.
pub fn parseTsClassIndexSignature(p: *Parser, start_token: TokenIndex) Error!NodeIndex {
    _ = try p.expect(.l_bracket);
    const param_name = try parseIdentifierNode(p);

    var param_type: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        param_type = try parseTsTypeAnnotation(p);
    }

    // Store type annotation on parameter Identifier so the serializer can emit it
    if (param_type != .none) {
        try p.storeTypeAnnotation(param_name, param_type);
    }

    _ = try p.expect(.r_bracket);

    var type_ann: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        type_ann = try parseTsTypeAnnotation(p);
    }

    // Class index signatures end with ; (not , like interface members)
    if (p.currentTag() == .semicolon) _ = p.advance();

    const extra_start = try p.addExtra(@intFromEnum(param_name));
    _ = try p.addExtra(@intFromEnum(param_type));
    _ = try p.addExtra(@intFromEnum(type_ann));

    return p.addNode(.{
        .tag = .ts_index_signature,
        .main_token = start_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn parseTsMethodSignatureBody(p: *Parser, main_token: TokenIndex, key: NodeIndex, flags: u32, kind: u32) Error!NodeIndex {
    const type_params = try parseTsTypeParameterDeclaration(p);
    if (kind != 0 and type_params != .none) {
        p.errors.addError("An accessor cannot have type parameters.", p.token_starts[@intFromEnum(p.nodes.items(.main_token)[@intFromEnum(type_params)])]);
    }
    const params_range = try parseTsFunctionParams(p);

    var return_type: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        return_type = try parseTsReturnTypeAnnotation(p);
    }

    eatInterfaceMemberSeparator(p);

    const extra_start = try p.addExtra(@intFromEnum(key));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(params_range.start);
    _ = try p.addExtra(params_range.end);
    _ = try p.addExtra(@intFromEnum(return_type));
    _ = try p.addExtra(flags);
    _ = try p.addExtra(kind);

    return p.addNode(.{
        .tag = .ts_method_signature,
        .main_token = main_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse `enum Foo { A, B = 1, C }`
pub fn parseTsEnumDeclaration(p: *Parser) Error!NodeIndex {
    const is_const = (p.currentTag() == .identifier and p.identifierEquals(p.token_index, "const")) or
        p.currentTag() == .kw_const;
    var const_token: TokenIndex = undefined;
    if (is_const) {
        const_token = p.advance();
    }

    const enum_token = p.advance(); // consume "enum"
    const id = try parseIdentifierNode(p);

    const lbrace_token = try p.expect(.l_brace);

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (p.currentTag() != .r_brace and p.currentTag() != .eof) {
        const member = try parseTsEnumMember(p);
        try p.scratch.append(p.allocator, member);
        if (p.currentTag() == .comma) {
            _ = p.advance();
        }
    }

    const rbrace_token = try p.expect(.r_brace);

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);

    const extra_start = try p.addExtra(@intFromEnum(id));
    _ = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);
    _ = try p.addExtra(@intFromBool(is_const));
    _ = try p.addExtra(@intFromEnum(lbrace_token));
    _ = try p.addExtra(@intFromEnum(rbrace_token));

    return p.addNode(.{
        .tag = .ts_enum_declaration,
        .main_token = if (is_const) const_token else enum_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn parseTsEnumMember(p: *Parser) Error!NodeIndex {
    const main_token = p.advance();

    var init: NodeIndex = .none;
    if (p.currentTag() == .equal) {
        _ = p.advance();
        init = try p.parseAssignmentExpression();
    }

    return p.addNode(.{
        .tag = .ts_enum_member,
        .main_token = main_token,
        .data = .{ .unary = init },
    });
}

/// Parse `namespace Foo { ... }` or `module "foo" { ... }`
pub fn parseTsModuleDeclaration(p: *Parser) Error!NodeIndex {
    const mod_token = p.advance(); // consume "namespace" or "module" or "global"
    const mod_text = p.tokenText(@intFromEnum(mod_token));
    const is_namespace_keyword = std.mem.eql(u8, mod_text, "namespace");
    const is_global_keyword = std.mem.eql(u8, mod_text, "global");

    // For "global", the keyword itself is the identifier (no separate name)
    var id: NodeIndex = undefined;
    if (is_global_keyword) {
        id = try p.addNode(.{
            .tag = .identifier,
            .main_token = mod_token,
            .data = .{ .none = {} },
        });
    } else {
        // For dotted names like namespace A.B.C, parse the full qualified name
        id = try parseTsModuleName(p);
        while (p.currentTag() == .dot) {
            _ = p.advance(); // consume "."
            const right = try parseIdentifierNode(p);
            id = try p.addNode(.{
                .tag = .ts_qualified_name,
                .main_token = p.nodes.items(.main_token)[@intFromEnum(id)],
                .data = .{ .binary = .{ .lhs = id, .rhs = right } },
            });
        }
    }

    var body: NodeIndex = .none;
    if (p.currentTag() == .l_brace) {
        body = try parseTsModuleBlock(p);
    } else if (p.currentTag() == .semicolon) {
        // Shorthand: declare module "m"; — consume semicolon for correct end position
        _ = p.advance();
    }

    // Determine kind: "namespace" for namespace keyword or module with identifier name,
    // "global" for global keyword, "module" for module with string literal name.
    const id_tag = p.nodes.items(.tag)[@intFromEnum(id)];
    const kind_code: u32 = if (is_global_keyword) 2 else if (is_namespace_keyword or id_tag != .string_literal) 1 else 0;

    const extra_start = try p.addExtra(@intFromEnum(id));
    _ = try p.addExtra(@intFromEnum(body));
    _ = try p.addExtra(kind_code);

    return p.addNode(.{
        .tag = .ts_module_declaration,
        .main_token = mod_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn parseTsModuleName(p: *Parser) Error!NodeIndex {
    if (p.currentTag() == .string) {
        const tok = p.advance();
        return p.addNode(.{
            .tag = .string_literal,
            .main_token = tok,
            .data = .{ .none = {} },
        });
    }
    if (p.isPlaceholder()) {
        return p.parsePlaceholder("Identifier");
    }
    return parseIdentifierNode(p);
}

pub fn parseTsModuleBlock(p: *Parser) Error!NodeIndex {
    const lbrace_token = try p.expect(.l_brace);

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (p.currentTag() != .r_brace and p.currentTag() != .eof) {
        const failed_token_index = p.token_index;
        const stmt = p.parseStatementOrDeclaration() catch {
            p.recoverAfterError(failed_token_index);
            continue;
        };
        try p.scratch.append(p.allocator, stmt);
    }

    _ = try p.expect(.r_brace);

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    return p.addNode(.{
        .tag = .ts_module_block,
        .main_token = lbrace_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse `declare function foo(): void`
pub fn parseTsDeclareFunction(p: *Parser) Error!NodeIndex {
    if (p.currentTag() == .kw_async) {
        _ = p.advance();
    }

    const func_token = try p.expect(.kw_function);

    var id: NodeIndex = .none;
    if (p.currentTag() == .identifier) {
        id = try parseIdentifierNode(p);
    }

    const type_params = try parseTsTypeParameterDeclaration(p);
    const params_range = try parseTsFunctionParams(p);

    var return_type: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        return_type = try parseTsReturnTypeAnnotation(p);
    }

    var body: NodeIndex = .none;
    if (p.currentTag() == .l_brace) {
        p.errors.addError("An implementation cannot be declared in ambient contexts.", p.currentStart());
        body = try p.parseBlockStatement();
    } else {
        p.expectSemicolon() catch {};
    }

    const extra_start = try p.addExtra(@intFromEnum(id));
    _ = try p.addExtra(@intFromEnum(type_params));
    _ = try p.addExtra(params_range.start);
    _ = try p.addExtra(params_range.end);
    _ = try p.addExtra(@intFromEnum(return_type));
    _ = try p.addExtra(@intFromEnum(body));

    return p.addNode(.{
        .tag = .ts_declare_function,
        .main_token = func_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

/// Parse `declare var/let/const x: T`
pub fn parseTsDeclareVariable(p: *Parser) Error!NodeIndex {
    const kw_token = p.advance();

    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (true) {
        const decl = try parseTsDeclareVariableDeclarator(p);
        try p.scratch.append(p.allocator, decl);
        if (p.currentTag() != .comma) break;
        _ = p.advance();
    }

    p.expectSemicolon() catch {};

    const items = p.scratch.items[scratch_start..];
    const range = try p.addExtraRange(items);
    const extra_start = try p.addExtra(range.start);
    _ = try p.addExtra(range.end);

    return p.addNode(.{
        .tag = .ts_declare_variable,
        .main_token = kw_token,
        .data = .{ .extra = @enumFromInt(extra_start) },
    });
}

fn parseTsDeclareVariableDeclarator(p: *Parser) Error!NodeIndex {
    const start_token: TokenIndex = @enumFromInt(p.token_index);
    const id = try p.parseBindingPattern();

    if (p.currentTag() == .colon) {
        const type_ann = try parseTsTypeAnnotation(p);
        try p.storeTypeAnnotation(id, type_ann);
    }

    var init: NodeIndex = .none;
    if (p.currentTag() == .equal) {
        p.errors.addError("Initializers are not allowed in ambient contexts.", p.currentStart());
        _ = p.advance();
        init = try p.parseAssignmentExpression();
    }

    return p.addNode(.{
        .tag = .declarator,
        .main_token = start_token,
        .data = .{ .binary = .{ .lhs = id, .rhs = init } },
    });
}

// ============================================================
// Function Parameter Parsing (for TS signatures)
// ============================================================

fn parseTsFunctionParams(p: *Parser) Error!Parser.Range {
    _ = try p.expect(.l_paren);
    const range = try parseTsFunctionParamsInner(p);
    _ = try p.expect(.r_paren);
    return range;
}

fn parseTsFunctionParamsInner(p: *Parser) Error!Parser.Range {
    const scratch_start = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_start);

    while (p.currentTag() != .r_paren and p.currentTag() != .eof) {
        const is_rest = p.currentTag() == .ellipsis;
        var rest_tok: TokenIndex = undefined;
        if (is_rest) {
            rest_tok = p.advance();
        }

        var param = try p.parseBindingPattern();

        if (p.currentTag() == .question) {
            const q_tok = p.advance();
            try p.ts_optional_params.put(p.allocator, @intFromEnum(param), {});
            // Update param end to include the `?` token
            p.nodes.items(.end_offset)[@intFromEnum(param)] = p.token_ends[@intFromEnum(q_tok)];
        }

        // For rest elements, the type annotation goes on the rest element, not the argument
        var deferred_type_ann: NodeIndex = .none;
        if (p.currentTag() == .colon) {
            const type_ann = try parseTsTypeAnnotation(p);
            if (is_rest) {
                deferred_type_ann = type_ann;
            } else {
                try p.storeTypeAnnotation(param, type_ann);
            }
        }

        if (p.currentTag() == .equal) {
            _ = p.advance();
            const init = try p.parseAssignmentExpression();
            param = try p.addNode(.{
                .tag = .assignment_pattern,
                .main_token = p.nodes.items(.main_token)[@intFromEnum(param)],
                .data = .{ .binary = .{ .lhs = param, .rhs = init } },
            });
        }

        if (is_rest) {
            param = try p.addNode(.{
                .tag = .rest_element,
                .main_token = rest_tok,
                .data = .{ .unary = param },
            });
            if (deferred_type_ann != .none) {
                try p.storeTypeAnnotation(param, deferred_type_ann);
            }
        }

        try p.scratch.append(p.allocator, param);

        if (p.eat(.comma) == null) break;
    }

    const items = p.scratch.items[scratch_start..];
    return p.addExtraRange(items);
}

// ============================================================
// TSX Generic Arrow Function (backtracking)
// ============================================================

/// Try to parse `<T, U>(params) => body` as a generic arrow function in TSX mode.
/// Returns the arrow function node on success, or error on failure (caller restores state).
pub fn tryParseGenericArrowFunction(p: *Parser) Error!NodeIndex {
    const start_tok: TokenIndex = @enumFromInt(p.token_index);
    const deferred = p.beginDeferredParamMetadata();
    errdefer p.discardDeferredParamMetadata(deferred);

    // Parse type parameters <T, U extends V>
    const type_params = try parseTsTypeParameterDeclaration(p);

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
            const param = try p.parseBindingElement();
            p.scratch.append(p.allocator, param) catch return error.ParseError;
        }
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_paren);

    // Optional return type annotation
    var return_type: NodeIndex = .none;
    if (p.currentTag() == .colon) {
        return_type = try parseTsReturnTypeAnnotation(p);
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
