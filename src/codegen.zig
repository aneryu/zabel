const std = @import("std");
const Ast = @import("ast.zig").Ast;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const ExtraIndex = @import("ast.zig").ExtraIndex;
const TokenIndex = @import("ast.zig").TokenIndex;
const Token = @import("token.zig").Token;
const Comment = @import("lexer.zig").Comment;
const CommentRange = @import("ast.zig").CommentRange;
const SourceMapBuilder = @import("source_map.zig").SourceMapBuilder;

const codegen_ts = @import("codegen_ts.zig");
const codegen_jsx = @import("codegen_jsx.zig");
const codegen_flow = @import("codegen_flow.zig");

pub const ChildPosition = enum {
    none,
    left,
    right,
    callee,
    object,
    tag,
    argument,
    test_expr,
    consequent,
    alternate,
    body,
};

pub const TokenContext = packed struct(u8) {
    expression_statement: bool = false,
    arrow_body: bool = false,
    export_default: bool = false,
    for_init_head: bool = false, // accumulates in `for(INIT;;)` — `in` operator needs parens
    for_in_head: bool = false, // left of `for (X in ...)`
    for_of_head: bool = false, // left of `for (X of ...)`
    arrow_flow_return_type: bool = false, // Flow: inside arrow function return type annotation
    _pad: u1 = 0,

    pub const empty: TokenContext = .{};
};

pub const Options = struct {
    source_maps: bool = false,
    source_filename: ?[]const u8 = null,
    /// When false, skip emitting all comments.
    comments: bool = true,
    es3_property_literals: bool = false,
    retain_lines: bool = false,
};

pub const GenerateResult = struct {
    code: []const u8,
    map: ?[]const u8,

    pub fn deinit(self: GenerateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        if (self.map) |m| allocator.free(m);
    }
};

pub const Codegen = struct {
    pub const Error = std.mem.Allocator.Error;

    ast: *const Ast,
    buf: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    source_map: ?*SourceMapBuilder,
    indent_level: u32 = 0,
    current_line: u32 = 0,
    current_col: u32 = 0,
    parent_tag: Node.Tag = .program,
    parent_data: Node.Data = .{ .none = {} },
    parent_main_token: TokenIndex = @enumFromInt(0),
    child_position: ChildPosition = .none,
    token_context: TokenContext = .{},
    was_parenthesized: bool = false,
    suppress_decorators: bool = false,
    suppress_trailing_comments: bool = false,
    /// When non-zero, trailing comments with source position >= this value are suppressed.
    /// Used to prevent trailing comments after ')' in for-statements from being emitted
    /// before the ')' is written.
    trailing_comment_source_limit: u32 = 0,
    arrow_type_params: bool = false,
    emit_comments: bool = true,
    es3_property_literals: bool = false,
    single_line_retain: bool = false,
    /// Set by emitStatementLeadingComments when the last comment was inline
    /// (single-line block comment on the same source line as the statement).
    /// When true, the caller should skip writeIndent() for the node.
    leading_comment_was_inline: bool = false,
    emitted_comments: std.DynamicBitSetUnmanaged = .{},

    // ---------------------------------------------------------------
    // Public entry point
    // ---------------------------------------------------------------

    pub fn generate(ast: *const Ast, options: Options, allocator: std.mem.Allocator) !GenerateResult {
        try @constCast(ast).ensureTypeSideTablesMaterialized();
        // Only build leading/trailing/inner comment maps when codegen will
        // actually emit comments.  When comments are disabled the maps are
        // never read, so the expensive sort + binary-search is skipped.
        if (options.comments) @constCast(ast).ensureCommentsAttached();
        var sm: ?SourceMapBuilder = if (options.source_maps) SourceMapBuilder.init(allocator) else null;
        const sm_ptr: ?*SourceMapBuilder = if (sm != null) &sm.? else null;

        const comment_count = ast.comments.items.len;
        var emitted = try std.DynamicBitSetUnmanaged.initEmpty(allocator, comment_count);
        // When comments option is false, mark all comments as already emitted
        // so all comment-related checks return false and no comments are output.
        if (!options.comments) {
            emitted.setRangeValue(.{ .start = 0, .end = comment_count }, true);
        }
        // Mark comments that were already consumed by transform passes (e.g., JSX
        // attribute comments emitted inline in the replacement source text).
        if (ast.consumed_comments.count() > 0) {
            const comments = ast.comments.items;
            for (comments, 0..) |comment, ci| {
                if (ast.consumed_comments.contains(comment.start)) {
                    emitted.set(ci);
                }
            }
        }
        var cg = Codegen{
            .ast = ast,
            .buf = .empty,
            .allocator = allocator,
            .source_map = sm_ptr,
            .emit_comments = options.comments,
            .es3_property_literals = options.es3_property_literals,
            .single_line_retain = options.retain_lines and
                std.mem.indexOfScalar(u8, ast.source, '\n') == null and
                std.mem.indexOfScalar(u8, ast.source, '\r') == null,
            .emitted_comments = emitted,
        };

        // Add source to source map
        if (sm_ptr) |smp| {
            _ = try smp.addSource(options.source_filename orelse "<input>", ast.source);
        }

        try cg.emitNode(@enumFromInt(0));

        const code = try allocator.dupe(u8, cg.buf.items);
        cg.buf.deinit(allocator);
        cg.emitted_comments.deinit(allocator);

        var map_str: ?[]const u8 = null;
        if (sm) |*s| {
            map_str = try s.finalize();
            s.deinit();
        }

        return GenerateResult{
            .code = code,
            .map = map_str,
        };
    }

    // ---------------------------------------------------------------
    // Output helpers (pub so sub-modules can call them)
    // ---------------------------------------------------------------

    pub fn writeStr(self: *Codegen, str: []const u8) !void {
        try self.buf.appendSlice(self.allocator, str);
        for (str) |c| {
            if (c == '\n') {
                self.current_line += 1;
                self.current_col = 0;
            } else {
                self.current_col += 1;
            }
        }
    }

    /// Write replacement source text, adding indentation after each newline.
    /// This ensures multi-line replacement_source text is properly indented
    /// to match the current codegen indent level.
    pub fn writeReplacementIndented(self: *Codegen, str: []const u8) !void {
        if (self.indent_level == 0) {
            return self.writeStr(str);
        }

        const line_indent = try self.allocator.dupe(u8, self.currentLineIndent());
        defer self.allocator.free(line_indent);
        const continuation_base_indent = continuationBaseIndent(str);
        const strip_base_indent = continuation_base_indent > 0 and line_indent.len == continuation_base_indent;
        var i: usize = 0;
        while (i < str.len) {
            const nl_pos = std.mem.indexOfScalar(u8, str[i..], '\n');
            if (nl_pos) |pos| {
                // Write up to and including the newline
                try self.writeStr(str[i .. i + pos + 1]);
                i += pos + 1;
                // If there's more content after the newline, add indentation
                if (i < str.len) {
                    try self.writeStr(line_indent);
                    const leading_len = str[i..].len - std.mem.trimStart(u8, str[i..], " \t").len;
                    if (leading_len > 0) {
                        const relative_start: usize = if (strip_base_indent)
                            @min(continuation_base_indent, leading_len)
                        else
                            0;
                        try self.writeStr(str[i + relative_start .. i + leading_len]);
                        i += leading_len;
                    }
                }
            } else {
                // No more newlines — write the rest
                try self.writeStr(str[i..]);
                break;
            }
        }
    }

    fn currentLineIndent(self: *Codegen) []const u8 {
        const buf = self.buf.items;
        const line_start = if (std.mem.lastIndexOfScalar(u8, buf, '\n')) |idx| idx + 1 else 0;
        var indent_end = line_start;
        while (indent_end < buf.len and (buf[indent_end] == ' ' or buf[indent_end] == '\t')) : (indent_end += 1) {}
        return buf[line_start..indent_end];
    }

    fn continuationBaseIndent(str: []const u8) usize {
        var min_indent: usize = std.math.maxInt(usize);
        var seen_first = false;
        var line_iter = std.mem.splitScalar(u8, str, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len == 0) continue;
            if (!seen_first) {
                seen_first = true;
                continue;
            }
            const leading = line.len - trimmed.len;
            if (leading < min_indent) min_indent = leading;
        }
        return if (min_indent == std.math.maxInt(usize)) 0 else min_indent;
    }

    pub fn writeChar(self: *Codegen, c: u8) !void {
        try self.buf.append(self.allocator, c);
        if (c == '\n') {
            self.current_line += 1;
            self.current_col = 0;
        } else {
            self.current_col += 1;
        }
    }

    pub fn space(self: *Codegen) !void {
        try self.writeChar(' ');
    }

    pub fn newline(self: *Codegen) !void {
        try self.writeChar('\n');
    }

    pub fn semicolon(self: *Codegen) !void {
        try self.writeChar(';');
    }

    pub fn indent(self: *Codegen) void {
        self.indent_level += 1;
    }

    pub fn dedent(self: *Codegen) void {
        if (self.indent_level > 0) {
            self.indent_level -= 1;
        }
    }

    pub fn writeIndent(self: *Codegen) !void {
        const count = self.indent_level * 2;
        try self.buf.appendNTimes(self.allocator, ' ', count);
        self.current_col += count;
    }

    pub fn emitToken(self: *Codegen, token_index: TokenIndex) !void {
        self.addMapping(token_index);
        const text = self.ast.tokenSlice(token_index);
        try self.writeStr(text);
    }

    fn keywordUsesIdentifierSemantics(tag: Token.Tag) bool {
        return switch (tag) {
            .kw_let,
            .kw_async,
            .kw_await,
            .kw_yield,
            .kw_of,
            .kw_static,
            .kw_get,
            .kw_set,
            .kw_from,
            .kw_as,
            => true,
            else => false,
        };
    }

    fn keywordText(tag: Token.Tag) []const u8 {
        return switch (tag) {
            .kw_let => "let",
            .kw_async => "async",
            .kw_await => "await",
            .kw_yield => "yield",
            .kw_of => "of",
            .kw_static => "static",
            .kw_get => "get",
            .kw_set => "set",
            .kw_from => "from",
            .kw_as => "as",
            else => "",
        };
    }

    fn identifierKeywordTag(self: *Codegen, token_index: TokenIndex) ?Token.Tag {
        const token_tag = self.ast.tokens.items(.tag)[@intFromEnum(token_index)];
        if (keywordUsesIdentifierSemantics(token_tag)) return token_tag;
        if (token_tag != .identifier) return null;

        const raw = self.ast.tokenSlice(token_index);
        if (std.mem.indexOf(u8, raw, "\\u") == null) return null;

        var buf: [32]u8 = undefined;
        const Lex = @import("lexer.zig").Lexer;
        const resolved = Lex.resolveEscapes(raw, &buf);
        if (resolved.len == 0) return null;
        const resolved_tag = Lex.identifyKeyword(resolved) orelse return null;
        if (!keywordUsesIdentifierSemantics(resolved_tag)) return null;
        return resolved_tag;
    }

    fn emitIdentifierToken(self: *Codegen, token_index: TokenIndex) !void {
        if (identifierKeywordTag(self, token_index)) |tag| {
            try self.emitKeyword(token_index, keywordText(tag));
            return;
        }
        try self.emitToken(token_index);
    }

    fn shouldWrapKeywordMemberObject(self: *Codegen, outer_parent_tag: Node.Tag, outer_child_pos: ChildPosition, object: NodeIndex) bool {
        if (object == .none) return false;
        if (self.ast.nodes.items(.tag)[@intFromEnum(object)] != .identifier) return false;
        const token = self.ast.nodes.items(.main_token)[@intFromEnum(object)];
        const kw = identifierKeywordTag(self, token) orelse return false;
        if (kw != .kw_let) return false;

        return switch (outer_parent_tag) {
            .expression_statement => true,
            .for_statement => self.token_context.for_init_head,
            .for_in_statement, .for_of_statement, .for_of_await_statement => outer_child_pos == .left,
            else => false,
        };
    }

    fn isSourceWrappedInParens(self: *Codegen, idx: NodeIndex) bool {
        const start = self.nodeSourceStart(idx);
        const end = self.nodeSourceEnd(idx);
        if (start == 0 or end >= self.ast.source.len) return false;

        var left = start;
        while (left > 0) {
            left -= 1;
            const c = self.ast.source[left];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
            return c == '(' and blk: {
                var right = end;
                while (right < self.ast.source.len) : (right += 1) {
                    const rc = self.ast.source[right];
                    if (rc == ' ' or rc == '\t' or rc == '\n' or rc == '\r') continue;
                    break :blk rc == ')';
                }
                break :blk false;
            };
        }
        return false;
    }

    fn nodeFollowedByInKeyword(self: *Codegen, idx: NodeIndex) bool {
        var pos = self.nodeSourceEnd(idx);
        while (pos < self.ast.source.len) : (pos += 1) {
            const c = self.ast.source[pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
            return pos + 1 < self.ast.source.len and c == 'i' and self.ast.source[pos + 1] == 'n' and
                (pos + 2 == self.ast.source.len or !std.ascii.isAlphabetic(self.ast.source[pos + 2]));
        }
        return false;
    }

    pub fn emitKeyword(self: *Codegen, token_index: TokenIndex, keyword: []const u8) !void {
        self.addMapping(token_index);
        try self.writeStr(keyword);
    }

    pub fn addMapping(self: *Codegen, token_index: TokenIndex) void {
        if (self.source_map) |sm| {
            const starts = self.ast.tokens.items(.start);
            const byte_offset = starts[@intFromEnum(token_index)];
            const pos = self.ast.resolvePosition(byte_offset);
            sm.addMapping(.{
                .gen_line = self.current_line,
                .gen_col = self.current_col,
                .orig_line = pos.line,
                .orig_col = pos.col,
                .source_index = 0,
            });
        }
    }

    pub fn emitNodeWithPosition(self: *Codegen, idx: NodeIndex, pos: ChildPosition) Error!void {
        const prev_pos = self.child_position;
        self.child_position = pos;
        try self.emitNode(idx);
        self.child_position = prev_pos;
    }

    pub fn emitCommaSeparated(self: *Codegen, start: u32, end: u32) Error!void {
        const items = self.ast.extra_data.items[start..end];
        for (items, 0..) |item, i| {
            if (i > 0) {
                // If previous element ends with a line comment, the comma needs
                // special handling to avoid being consumed by the comment.
                if (self.endsWithLineComment()) {
                    try self.newline();
                    try self.writeIndent();
                    try self.writeChar(',');
                    try self.space();
                } else {
                    try self.writeChar(',');
                    try self.space();
                }
                // Non-first elements are not at statement head
                self.clearHeadContext();
            }
            try self.emitNode(@enumFromInt(item));
        }
    }

    // ---------------------------------------------------------------
    // Parenthesization rules (matching Babel's parentheses.ts)
    // ---------------------------------------------------------------

    /// Operator precedence table for binary/logical expressions (matches Babel).
    fn operatorPrecedence(op: []const u8) ?u8 {
        if (std.mem.eql(u8, op, "||")) return 0;
        if (std.mem.eql(u8, op, "??")) return 1;
        if (std.mem.eql(u8, op, "&&")) return 2;
        if (std.mem.eql(u8, op, "|") or std.mem.eql(u8, op, "|>")) return 3;
        if (std.mem.eql(u8, op, "^")) return 4;
        if (std.mem.eql(u8, op, "&")) return 5;
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "===") or
            std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "!==")) return 6;
        if (std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, ">") or
            std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">=") or
            std.mem.eql(u8, op, "in") or std.mem.eql(u8, op, "instanceof")) return 7;
        if (std.mem.eql(u8, op, ">>") or std.mem.eql(u8, op, "<<") or
            std.mem.eql(u8, op, ">>>")) return 8;
        if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-")) return 9;
        if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "/") or
            std.mem.eql(u8, op, "%")) return 10;
        if (std.mem.eql(u8, op, "**")) return 11;
        return null;
    }

    /// Get the operator string for a given node index (binary/logical/assignment).
    fn nodeOperator(self: *Codegen, node_idx: NodeIndex) []const u8 {
        const ni = @intFromEnum(node_idx);
        if (self.ast.operator_overrides.get(ni)) |op_str| return op_str;
        const mt = self.ast.nodes.items(.main_token)[ni];
        return self.operatorStr(mt);
    }

    /// Unwrap parenthesized_expr nodes to find the inner node.
    fn unwrapParenthesized(self: *Codegen, node: NodeIndex) NodeIndex {
        var current = node;
        while (true) {
            const t = self.ast.nodes.items(.tag)[@intFromEnum(current)];
            if (t == .parenthesized_expr) {
                current = self.ast.nodes.items(.data)[@intFromEnum(current)].unary;
            } else {
                return current;
            }
        }
    }

    /// Check if the current node is the superClass child of a class parent.
    fn isClassExtendsClause(self: *Codegen, idx: NodeIndex) bool {
        switch (self.parent_tag) {
            .class_declaration, .class_expr => {
                const parent_data = self.parent_data;
                const extra_idx = @intFromEnum(parent_data.extra);
                if (extra_idx < self.ast.extra_data.items.len and extra_idx + 1 < self.ast.extra_data.items.len) {
                    const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
                    // The super_class might be wrapped in parenthesized_expr,
                    // but the inner node is what we compare against idx.
                    return super_class == idx or self.unwrapParenthesized(super_class) == idx;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Check if the current node is in a postfix position (callee, object, or tag).
    fn hasPostfixPart(self: *Codegen) bool {
        return switch (self.child_position) {
            .callee, .object, .tag => true,
            else => false,
        };
    }

    /// Returns true if the expression-statement or arrow-body context is set.
    fn needsParenBeforeExpressionBrace(self: *Codegen) bool {
        return self.token_context.expression_statement or self.token_context.arrow_body;
    }

    /// Clear head-position context flags before emitting a non-leading child.
    /// Call this before emitting rhs, arguments, etc. — anything that is NOT
    /// the leftmost token in the expression.
    fn clearHeadContext(self: *Codegen) void {
        self.token_context.expression_statement = false;
        self.token_context.arrow_body = false;
        self.token_context.export_default = false;
    }

    /// Check if the node IS or HAS a leading CallExpression (for new-callee rule).
    /// Does NOT unwrap parenthesized_expr — those are handled transparently.
    fn isOrHasLeadingCallExpr(self: *Codegen, node: NodeIndex) bool {
        if (node == .none) return false;
        const t = self.ast.nodes.items(.tag)[@intFromEnum(node)];
        return switch (t) {
            .call_expr, .import_expr => true,
            .member_expr, .computed_member_expr => {
                const d = self.ast.nodes.items(.data)[@intFromEnum(node)];
                return self.isOrHasLeadingCallExpr(d.binary.lhs);
            },
            .parenthesized_expr => {
                // Transparent parenthesized expressions don't emit parens,
                // so we need to check the inner node.
                if (!self.ast.create_parenthesized_expressions) {
                    const d = self.ast.nodes.items(.data)[@intFromEnum(node)];
                    return self.isOrHasLeadingCallExpr(d.unary);
                }
                return false;
            },
            else => false,
        };
    }

    /// Parent-level parens check (Babel's parentNeedsParens).
    fn parentNeedsParens(self: *Codegen, tag: Node.Tag, idx: NodeIndex) bool {
        const pt = self.parent_tag;
        switch (pt) {
            .new_expr => {
                if (self.child_position == .callee) {
                    // Skip transparent parenthesized_expr — the inner node will get
                    // its own needsParens check with the restored parent context.
                    if (tag == .parenthesized_expr and !self.ast.create_parenthesized_expressions) return false;
                    if (self.isOrHasLeadingCallExpr(idx)) return true;
                    if (tag == .optional_call_expr or tag == .optional_chain_expr or
                        tag == .optional_computed_member_expr) return true;
                }
            },
            .decorator => {
                // Decorator expressions need parens unless they are:
                // - a "decorator member expression" (Identifier or non-computed MemberExpression chain)
                // - a CallExpression whose callee is a decorator member expression
                // - a ParenthesizedExpression (handles its own parens)
                if (tag == .parenthesized_expr) return false;
                if (self.isDecoratorMemberExpr(idx)) return false;
                if (tag == .call_expr) {
                    const d = self.ast.nodes.items(.data)[@intFromEnum(idx)];
                    const extra_idx = @intFromEnum(d.extra);
                    const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
                    if (callee_idx != .none and self.isDecoratorMemberExpr(callee_idx)) return false;
                }
                return true;
            },
            else => {},
        }
        return false;
    }

    /// Check if a node is a valid "decorator member expression" — either an Identifier,
    /// or a chain of non-computed MemberExpressions ending in an Identifier.
    /// Private name properties (`.#x`) are NOT valid decorator member expressions.
    fn isDecoratorMemberExpr(self: *Codegen, node: NodeIndex) bool {
        if (node == .none) return false;
        const t = self.ast.nodes.items(.tag)[@intFromEnum(node)];
        return switch (t) {
            .identifier => true,
            .member_expr => {
                // member_expr is always non-computed (dot access), property is a token.
                // But private names (.#x) are not valid decorator member expressions.
                const d = self.ast.nodes.items(.data)[@intFromEnum(node)];
                const prop_token_idx = @intFromEnum(d.binary.rhs);
                const is_private = prop_token_idx > 0 and self.ast.tokens.items(.tag)[prop_token_idx - 1] == .hash;
                if (is_private) return false;
                return self.isDecoratorMemberExpr(d.binary.lhs);
            },
            else => false,
        };
    }

    fn needsParens(self: *Codegen, tag: Node.Tag, idx: NodeIndex) bool {
        // Check parent-level rules first (e.g., new callee)
        if (self.parentNeedsParens(tag, idx)) return true;

        const pt = self.parent_tag;

        return switch (tag) {
            // === Binary and Logical expressions ===
            .binary_expr => self.needsParensBinary(idx),
            .logical_expr => self.needsParensLogical(idx),

            // === Object expression — needs parens in statement position ===
            .object_expr => self.needsParenBeforeExpressionBrace(),

            // === Function expression — needs parens when it starts a statement ===
            .function_expr => self.token_context.expression_statement or self.token_context.export_default,

            // === Class expression ===
            .class_expr => self.token_context.expression_statement or self.token_context.export_default,

            // === Sequence expression — needs parens almost everywhere ===
            .sequence_expr => self.needsParensSequence(idx),

            // === Arrow function expression ===
            .arrow_function_expr => self.needsParensConditionalLike(idx),

            // === Conditional expression ===
            .conditional_expr => self.needsParensConditionalLike(idx),

            // === Assignment expression ===
            .assignment_expr => self.needsParensAssignment(idx),

            // === Yield expression ===
            .yield_expr, .yield_delegate_expr => self.needsParensYield(tag, idx),

            // === Await expression ===
            .await_expr => self.needsParensYield(tag, idx),

            // === Unary expression, SpreadElement ===
            .unary_expr, .spread_element => self.needsParensUnaryLike(idx),

            // === Update expression ===
            .update_expr => self.needsParensUpdate(idx),

            // === Do expression ===
            .do_expression => blk: {
                if (!self.token_context.expression_statement) break :blk false;
                // `async do {}` is unambiguous — starts with `async`
                // Plain `do {}` would look like a do-while statement and needs parens
                const is_async_do = self.ast.async_arrow_flags.contains(@intFromEnum(idx));
                break :blk !is_async_do;
            },

            // === TS expressions ===
            .ts_as_expression, .ts_satisfies_expression => self.needsParensTsAs(idx),
            .ts_non_null_expression => false,
            .ts_type_assertion => self.needsParensUnaryLike(idx),
            .ts_instantiation_expression => blk: {
                // Needs parens when callee of call, object of member, or in tagged template
                if (pt == .call_expr and self.child_position == .callee) break :blk true;
                if (pt == .new_expr and self.child_position == .callee) break :blk true;
                if ((pt == .member_expr or pt == .computed_member_expr) and self.child_position == .object) break :blk true;
                if (pt == .tagged_template_expr) break :blk true;
                if (pt == .ts_instantiation_expression) break :blk true;
                break :blk false;
            },
            .ts_union_type, .ts_intersection_type => self.needsParensTsUnionOrIntersection(tag),
            .ts_function_type, .ts_constructor_type => self.needsParensTsFunctionOrConstructorType(),
            .ts_conditional_type => self.needsParensTsConditionalType(),
            .ts_infer_type => self.needsParensTsInferType(idx),
            .ts_type_operator => self.needsParensTsTypeOperator(),

            // === Optional member/call expressions ===
            .optional_chain_expr, .optional_computed_member_expr => blk: {
                switch (pt) {
                    .call_expr => break :blk self.child_position == .callee,
                    .member_expr => break :blk self.child_position == .object,
                    else => break :blk false,
                }
            },
            .optional_call_expr => blk: {
                switch (pt) {
                    .call_expr => break :blk self.child_position == .callee,
                    .member_expr => break :blk self.child_position == .object,
                    else => break :blk false,
                }
            },

            // === Identifier with source-level parens in assignment LHS ===
            .identifier => self.needsParensIdentifier(idx),

            // === Flow type parenthesization ===
            .flow_nullable_type => pt == .flow_array_type,

            .flow_function_type_annotation => switch (pt) {
                .flow_union_type, .flow_intersection_type, .flow_array_type => true,
                else => self.token_context.arrow_flow_return_type,
            },

            .flow_union_type, .flow_intersection_type => switch (pt) {
                .flow_array_type, .flow_nullable_type, .flow_intersection_type, .flow_union_type => true,
                else => false,
            },

            .flow_optional_indexed_access_type => pt == .flow_indexed_access_type,

            else => false,
        };
    }

    /// Identifier needs parens: (f) = function () {} — preserves parens to prevent
    /// the function from getting the name `f`.
    fn needsParensIdentifier(self: *Codegen, idx: NodeIndex) bool {
        const main_token = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];

        if (identifierKeywordTag(self, main_token)) |tag| {
            switch (tag) {
                .kw_let => {
                    if (self.was_parenthesized and
                        (self.parent_tag == .member_expr or self.parent_tag == .computed_member_expr) and
                        self.child_position == .object) return true;
                    if ((self.parent_tag == .for_of_statement or self.parent_tag == .for_of_await_statement) and
                        self.child_position == .left) return true;
                },
                .kw_async => {
                    if (self.parent_tag == .for_of_statement and self.child_position == .left) return true;
                },
                else => {},
            }
        }

        // Only applies when the identifier was in source-level parens
        if (!self.was_parenthesized) return false;
        // Parent must be AssignmentExpression and this must be the left side
        if (self.parent_tag != .assignment_expr) return false;
        if (self.child_position != .left) return false;
        // Check if right side is anonymous FunctionExpression or ClassExpression
        const rhs = self.parent_data.binary.rhs;
        if (rhs == .none) return false;
        // Unwrap parenthesized_expr on rhs
        const rhs_unwrapped = self.unwrapParenthesized(rhs);
        const rhs_tag = self.ast.nodes.items(.tag)[@intFromEnum(rhs_unwrapped)];
        if (rhs_tag == .function_expr or rhs_tag == .class_expr) {
            // Check if anonymous (no name)
            const rhs_data = self.ast.nodes.items(.data)[@intFromEnum(rhs_unwrapped)];
            const extra_idx = @intFromEnum(rhs_data.extra);
            if (extra_idx < self.ast.extra_data.items.len) {
                const name_token_raw = self.ast.extra_data.items[extra_idx];
                if (name_token_raw == 0) return true; // anonymous
            }
        }
        return false;
    }

    /// BinaryExpression needs parens.
    fn needsParensBinary(self: *Codegen, idx: NodeIndex) bool {
        const pt = self.parent_tag;
        const cp = self.child_position;

        // `in` inside for-init head always needs parens
        const node_op = self.nodeOperator(idx);
        if (self.token_context.for_init_head and std.mem.eql(u8, node_op, "in") and self.was_parenthesized) {
            return true;
        }
        if (self.token_context.for_init_head and std.mem.eql(u8, node_op, "in")) {
            return true;
        }

        return self.needsParensBinaryLike(idx, node_op, pt, cp, false);
    }

    /// LogicalExpression needs parens.
    fn needsParensLogical(self: *Codegen, idx: NodeIndex) bool {
        const pt = self.parent_tag;
        const cp = self.child_position;
        const node_op = self.nodeOperator(idx);
        return self.needsParensBinaryLike(idx, node_op, pt, cp, true);
    }

    /// Shared logic for binary/logical expressions (BinaryLike in Babel).
    fn needsParensBinaryLike(
        self: *Codegen,
        idx: NodeIndex,
        node_op: []const u8,
        pt: Node.Tag,
        cp: ChildPosition,
        is_logical: bool,
    ) bool {
        // Class extends clause
        if (self.isClassExtendsClause(idx)) return true;

        // Postfix positions (callee, object, tag)
        if (self.hasPostfixPart()) return true;

        // Parent is unary, spread, or await
        if (pt == .unary_expr or pt == .spread_element or pt == .await_expr) return true;

        // Parent is binary or logical — compare precedence
        const node_prec = operatorPrecedence(node_op) orelse return false;

        const parent_prec: ?u8 = switch (pt) {
            .binary_expr, .logical_expr => blk: {
                // Get the parent's operator — we need to figure out the parent's idx
                // Since parent_data contains the binary node's data, we can use that
                // But we need the parent's main_token. Let me use parent_main_token.
                break :blk self.getParentBinaryPrecedence();
            },
            .ts_as_expression, .ts_satisfies_expression => 7, // `in` precedence
            else => null,
        };

        if (parent_prec) |pp| {
            if (pp > node_prec) return true;

            // Same precedence — check associativity
            if (pp == node_prec and pt == .binary_expr) {
                // ** is right-associative: (a ** b) ** c needs parens on left
                // Other ops are left-associative: a + (b + c) needs parens on right
                if (pp == 11) { // **
                    if (cp == .left) return true;
                } else {
                    if (cp == .right) return true;
                }
            }

            // Mixing ?? with || or && requires parens
            if (is_logical) {
                if (pt == .logical_expr) {
                    if (self.getParentBinaryPrecedence()) |pprec| {
                        if ((node_prec == 1 and pprec != 1) or (pprec == 1 and node_prec != 1)) {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }

    /// Get the precedence of the parent binary/logical operator.
    fn getParentBinaryPrecedence(self: *Codegen) ?u8 {
        // The parent is a binary/logical node. We need its operator.
        // We stored parent_main_token for this purpose.
        const parent_op = self.getParentOperator();
        return operatorPrecedence(parent_op);
    }

    /// Get the operator string for the parent node (must be binary/logical/assignment).
    fn getParentOperator(self: *Codegen) []const u8 {
        // We need the parent's main token to get its operator.
        // We store parent_main_token for this purpose.
        if (self.ast.operator_overrides.get(@intFromEnum(self.parent_main_token))) |op_str|
            return op_str;
        return self.operatorStr(self.parent_main_token);
    }

    /// SequenceExpression needs parens almost everywhere.
    fn needsParensSequence(self: *Codegen, idx: NodeIndex) bool {
        _ = idx;
        const pt = self.parent_tag;
        // Sequence inside sequence doesn't need parens
        if (pt == .sequence_expr) return false;
        if (pt == .parenthesized_expr) return false;
        // Sequence as computed property — no parens needed
        if ((pt == .member_expr or pt == .optional_chain_expr) and self.child_position == .right) return false;
        if ((pt == .computed_member_expr or pt == .optional_computed_member_expr) and self.child_position == .right) return false;
        // Template literal expression — no parens needed
        if (pt == .template_literal) return false;
        // Class declaration (for extends clause)
        if (pt == .class_declaration) return true;
        // for-of right
        if (pt == .for_of_statement or pt == .for_of_await_statement) {
            if (self.child_position == .right) return true;
        }
        // Export default
        if (pt == .export_default) return true;
        // Statements don't need parens (the sequence IS the expression)
        if (isStatementTag(pt)) return false;
        // For-statement init/update — don't need parens
        if (pt == .for_statement) return false;
        // Everything else needs parens
        return true;
    }

    /// ConditionalExpression and ArrowFunctionExpression need parens.
    fn needsParensConditionalLike(self: *Codegen, idx: NodeIndex) bool {
        const pt = self.parent_tag;
        switch (pt) {
            .unary_expr, .spread_element => return true,
            .binary_expr, .logical_expr => return true,
            .await_expr => return true,
            .conditional_expr => {
                if (self.child_position == .test_expr) return true;
            },
            .ts_as_expression, .ts_satisfies_expression => return true,
            else => {},
        }

        // UnaryLike: hasPostfixPart or exponentiation left
        if (self.hasPostfixPart()) return true;
        if (pt == .binary_expr and self.child_position == .left) {
            const parent_op = self.getParentOperator();
            if (std.mem.eql(u8, parent_op, "**")) return true;
        }
        if (self.isClassExtendsClause(idx)) return true;

        return false;
    }

    /// AssignmentExpression needs parens.
    fn needsParensAssignment(self: *Codegen, idx: NodeIndex) bool {
        // If in expression statement or arrow body with ObjectPattern LHS, needs parens
        if (self.needsParenBeforeExpressionBrace()) {
            // Check if lhs is an ObjectPattern
            const data = self.ast.nodes.items(.data)[@intFromEnum(idx)];
            const lhs_tag = self.ast.nodes.items(.tag)[@intFromEnum(data.binary.lhs)];
            if (lhs_tag == .object_pattern) return true;
        }
        // Same rules as conditional
        return self.needsParensConditionalLike(idx);
    }

    /// YieldExpression and AwaitExpression need parens.
    fn needsParensYield(self: *Codegen, tag: Node.Tag, idx: NodeIndex) bool {
        const pt = self.parent_tag;
        switch (pt) {
            .binary_expr, .logical_expr => return true,
            .unary_expr, .spread_element => return true,
            .await_expr => {
                // await (yield ...) needs parens, but await await does NOT
                if (tag == .yield_expr or tag == .yield_delegate_expr) return true;
            },
            .conditional_expr => {
                if (self.child_position == .test_expr) return true;
            },
            .ts_as_expression, .ts_satisfies_expression, .ts_type_assertion => return true,
            else => {},
        }

        if (self.hasPostfixPart()) return true;
        if (self.isClassExtendsClause(idx)) return true;

        return false;
    }

    /// UnaryExpression / SpreadElement need parens.
    fn needsParensUnaryLike(self: *Codegen, idx: NodeIndex) bool {
        // hasPostfixPart
        if (self.hasPostfixPart()) return true;
        // Left operand of **
        const pt = self.parent_tag;
        if (pt == .binary_expr and self.child_position == .left) {
            const parent_op = self.getParentOperator();
            if (std.mem.eql(u8, parent_op, "**")) return true;
        }
        if (self.isClassExtendsClause(idx)) return true;
        return false;
    }

    /// UpdateExpression needs parens.
    fn needsParensUpdate(self: *Codegen, idx: NodeIndex) bool {
        // hasPostfixPart
        if (self.hasPostfixPart()) return true;
        if (self.isClassExtendsClause(idx)) return true;
        return false;
    }

    /// TSAsExpression / TSSatisfiesExpression need parens.
    fn needsParensTsAs(self: *Codegen, idx: NodeIndex) bool {
        const pt = self.parent_tag;
        // If parent is AssignmentExpression/AssignmentPattern and this is the left
        if ((pt == .assignment_expr or pt == .assignment_pattern) and self.child_position == .left) {
            return true;
        }
        // If parent is BinaryExpression with | or & operator and this is left
        if (pt == .binary_expr and self.child_position == .left) {
            const parent_op = self.getParentOperator();
            if (std.mem.eql(u8, parent_op, "|") or std.mem.eql(u8, parent_op, "&")) {
                return true;
            }
        }
        // Use BinaryLike rules with precedence 7 (in)
        const node_prec: u8 = 7;
        if (self.isClassExtendsClause(idx)) return true;
        if (self.hasPostfixPart()) return true;
        if (pt == .unary_expr or pt == .spread_element or pt == .await_expr) return true;
        const parent_prec: ?u8 = switch (pt) {
            .binary_expr, .logical_expr => self.getParentBinaryPrecedence(),
            .ts_as_expression, .ts_satisfies_expression => @as(?u8, 7),
            else => null,
        };
        if (parent_prec) |pp| {
            if (pp > node_prec) return true;
            if (pp == node_prec and pt == .binary_expr) {
                if (pp == 11) {
                    if (self.child_position == .left) return true;
                } else {
                    if (self.child_position == .right) return true;
                }
            }
        }
        return false;
    }

    fn needsParensTsUnionOrIntersection(self: *Codegen, tag: Node.Tag) bool {
        return switch (self.parent_tag) {
            .ts_array_type, .ts_optional_type, .ts_type_operator => true,
            .ts_indexed_access_type => self.child_position == .left,
            .ts_intersection_type => tag == .ts_union_type,
            .ts_conditional_type => self.child_position == .left or self.child_position == .right,
            else => false,
        };
    }

    fn needsParensTsFunctionOrConstructorType(self: *Codegen) bool {
        return switch (self.parent_tag) {
            .ts_union_type,
            .ts_intersection_type,
            .ts_array_type,
            .ts_type_operator,
            .ts_optional_type,
            => true,
            .ts_indexed_access_type => self.child_position == .left,
            .ts_conditional_type => self.child_position == .left or self.child_position == .right,
            else => false,
        };
    }

    fn needsParensTsConditionalType(self: *Codegen) bool {
        return switch (self.parent_tag) {
            .ts_array_type,
            .ts_optional_type,
            .ts_union_type,
            .ts_intersection_type,
            .ts_type_operator,
            => true,
            .ts_indexed_access_type => self.child_position == .left,
            .ts_type_parameter => true,
            .ts_conditional_type => self.child_position == .left or self.child_position == .right,
            else => false,
        };
    }

    fn needsParensTsInferType(self: *Codegen, idx: NodeIndex) bool {
        return switch (self.parent_tag) {
            .ts_array_type, .ts_optional_type => true,
            .ts_indexed_access_type => self.child_position == .left,
            .ts_type_operator => self.inferTypeHasConstraint(idx),
            .ts_union_type, .ts_intersection_type => self.inferTypeHasConstraint(idx),
            else => false,
        };
    }

    fn needsParensTsTypeOperator(self: *Codegen) bool {
        return switch (self.parent_tag) {
            .ts_array_type, .ts_optional_type => true,
            .ts_indexed_access_type => self.child_position == .left,
            else => false,
        };
    }

    fn inferTypeHasConstraint(self: *Codegen, idx: NodeIndex) bool {
        const infer_data = self.ast.nodes.items(.data)[@intFromEnum(idx)];
        const type_param = infer_data.unary;
        if (type_param == .none) return false;
        const tp_data = self.ast.nodes.items(.data)[@intFromEnum(type_param)];
        const extra_idx = @intFromEnum(tp_data.extra);
        if (extra_idx >= self.ast.extra_data.items.len) return false;
        return @as(NodeIndex, @enumFromInt(self.ast.extra_data.items[extra_idx])) != .none;
    }

    /// Check if a tag is a statement (not an expression).
    fn isStatementTag(t: Node.Tag) bool {
        return switch (t) {
            .program,
            .removed,
            .block_statement,
            .expression_statement,
            .empty_statement,
            .if_statement,
            .for_statement,
            .for_in_statement,
            .for_of_statement,
            .for_of_await_statement,
            .while_statement,
            .do_while_statement,
            .switch_statement,
            .switch_case,
            .switch_default,
            .return_statement,
            .throw_statement,
            .try_statement,
            .catch_clause,
            .break_statement,
            .continue_statement,
            .labeled_statement,
            .with_statement,
            .debugger_statement,
            .var_declaration,
            .let_declaration,
            .const_declaration,
            .using_declaration,
            .await_using_declaration,
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .class_declaration,
            .import_declaration,
            .import_declaration_typeof,
            .export_named,
            .export_default,
            .export_all,
            .directive,
            => true,
            else => false,
        };
    }

    // ---------------------------------------------------------------
    // Operator string from token tag
    // ---------------------------------------------------------------

    fn operatorStr(self: *Codegen, main_token: TokenIndex) []const u8 {
        const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
        // Check for operator override (from split token like %===)
        return switch (tok_tag) {
            .plus => "+",
            .minus => "-",
            .asterisk => "*",
            .slash => "/",
            .percent => "%",
            .power => "**",
            .equal_equal => "==",
            .bang_equal => "!=",
            .equal_equal_equal => "===",
            .bang_equal_equal => "!==",
            .less_than => "<",
            .greater_than => ">",
            .less_equal => "<=",
            .greater_equal => ">=",
            .ampersand_ampersand => "&&",
            .pipe_pipe => "||",
            .question_question => "??",
            .ampersand => "&",
            .pipe => blk: {
                const pipe_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
                if (pipe_end < self.ast.source.len and self.ast.source[pipe_end] == '>') {
                    break :blk "|>";
                }
                break :blk "|";
            },
            .caret => "^",
            .less_less => "<<",
            .greater_greater => ">>",
            .greater_greater_greater => ">>>",
            .kw_instanceof => "instanceof",
            .kw_in => "in",
            .bang => "!",
            .tilde => "~",
            .kw_typeof => "typeof",
            .kw_void => "void",
            .kw_delete => "delete",
            .kw_throw => "throw",
            .equal => "=",
            .plus_equal => "+=",
            .minus_equal => "-=",
            .asterisk_equal => "*=",
            .slash_equal => "/=",
            .percent_equal => "%=",
            .power_equal => "**=",
            .ampersand_equal => "&=",
            .pipe_equal => "|=",
            .caret_equal => "^=",
            .less_less_equal => "<<=",
            .greater_greater_equal => ">>=",
            .greater_greater_greater_equal => ">>>=",
            .ampersand_ampersand_equal => "&&=",
            .pipe_pipe_equal => "||=",
            .question_question_equal => "??=",
            .plus_plus => "++",
            .minus_minus => "--",
            else => self.ast.tokenSlice(main_token),
        };
    }

    /// Check if an operator is a word operator that needs space separation
    fn isWordOperator(op: []const u8) bool {
        return std.mem.eql(u8, op, "typeof") or
            std.mem.eql(u8, op, "void") or
            std.mem.eql(u8, op, "delete") or
            std.mem.eql(u8, op, "throw") or
            std.mem.eql(u8, op, "in") or
            std.mem.eql(u8, op, "instanceof");
    }

    // ---------------------------------------------------------------
    // Main dispatch
    // ---------------------------------------------------------------

    pub fn emitNode(self: *Codegen, idx: NodeIndex) Error!void {
        if (idx == .none) return;

        const i = @intFromEnum(idx);
        const tag = self.ast.nodes.items(.tag)[i];
        if (tag == .removed) return; // Node removed by transform pass — emit nothing

        // Check for replacement source text set by transform passes
        if (self.ast.replacement_source.get(i)) |replacement| {
            // Use indent-aware writing if the transform flagged this replacement
            if (self.ast.replacement_needs_reindent.contains(i)) {
                try self.writeReplacementIndented(replacement);
            } else {
                try self.writeStr(replacement);
            }
            return;
        }

        const data = self.ast.nodes.items(.data)[i];
        const main_token = self.ast.nodes.items(.main_token)[i];

        // needsParens uses parent_tag/parent_data/child_position which are still
        // set to the PARENT's values at this point.
        const wrap = self.needsParens(tag, idx);
        if (wrap) try self.writeChar('(');

        // Save parent context, then set ourselves as the parent for children
        // Transparent nodes (parenthesized types when not creating them) don't
        // update parent context, so that inner nodes see the correct ancestor.
        const is_transparent = (tag == .flow_parenthesized_type or tag == .ts_parenthesized_type) and
            !self.ast.create_parenthesized_expressions;

        const saved_parent_tag = self.parent_tag;
        const saved_parent_data = self.parent_data;
        const saved_parent_main_token = self.parent_main_token;
        const saved_child_pos = self.child_position;
        const saved_token_context = self.token_context;
        defer {
            self.parent_tag = saved_parent_tag;
            self.parent_data = saved_parent_data;
            self.parent_main_token = saved_parent_main_token;
            self.child_position = saved_child_pos;
            self.token_context = saved_token_context;
        }
        if (!is_transparent) {
            self.parent_tag = tag;
            self.parent_data = data;
            self.parent_main_token = main_token;
            self.child_position = .none;
        }
        // Token context propagation rules:
        // - for_init_head: propagates to ALL descendants (any `in` needs parens)
        // - expression_statement/arrow_body: propagate only to the LEFTMOST child
        //   (the one whose first token starts the expression) — emit functions
        //   must clear these before emitting non-leading children
        // - export_default: propagates to the direct declaration child only
        // We keep all flags and let emit functions handle clearing for non-leading positions.

        // Emit expression-level leading comments (statement-level already handled by list emitters)
        if (tag != .program) {
            try self.emitExprLeadingComments(idx);
        }

        switch (tag) {
            // === Program ===
            .program => try self.emitProgram(data),

            // === Literals ===
            .numeric_literal,
            .string_literal,
            .boolean_literal,
            .null_literal,
            .bigint_literal,
            => try self.emitToken(main_token),

            .regex_literal => try self.emitRegexLiteral(idx, main_token),

            .template_literal => try self.emitTemplateLiteral(idx, main_token, data),

            // === Identifiers ===
            .identifier => try self.emitIdentifierToken(main_token),
            .private_name => try self.emitPrivateName(data),
            .v8_intrinsic_identifier => try self.emitV8Intrinsic(idx),
            .this_expr => try self.writeStr("this"),
            .super_expr => try self.writeStr("super"),

            // === Expressions ===
            .binary_expr, .logical_expr => try self.emitBinaryExpr(idx, main_token, data),
            .unary_expr => try self.emitUnaryExpr(main_token, data),
            .update_expr => try self.emitUpdateExpr(idx, main_token, data),
            .assignment_expr => try self.emitAssignmentExpr(idx, main_token, data),
            .conditional_expr => try self.emitConditionalExpr(data),
            .sequence_expr => try self.emitSequenceExpr(data),
            .call_expr => try self.emitCallExpr(idx, data),
            .optional_call_expr => try self.emitOptionalCallExpr(idx, main_token, data),
            .new_expr => try self.emitNewExpr(idx, main_token, data),
            .member_expr => try self.emitMemberExpr(saved_parent_tag, saved_child_pos, data),
            .computed_member_expr => try self.emitComputedMemberExpr(saved_parent_tag, saved_child_pos, data),
            .optional_chain_expr => try self.emitOptionalChainExpr(main_token, data),
            .optional_computed_member_expr => try self.emitOptionalComputedMemberExpr(main_token, data),
            .arrow_function_expr => try self.emitArrowFunctionExpr(saved_parent_tag, saved_child_pos, idx, data),
            .function_expr => try self.emitFunctionExpr(idx, data),
            .class_expr => try self.emitClassExpr(idx, data),
            .yield_expr => try self.emitYieldExpr(idx, data, false),
            .yield_delegate_expr => try self.emitYieldExpr(idx, data, true),
            .await_expr => try self.emitAwaitExpr(data),
            .spread_element => try self.emitSpreadElement(data),
            .tagged_template_expr => try self.emitTaggedTemplateExpr(idx, data),
            .meta_property => try self.emitMetaProperty(idx, main_token),
            .import_expr => try self.emitImportExpr(idx, data),
            .parenthesized_expr => {
                if (self.ast.create_parenthesized_expressions) {
                    // When createParenthesizedExpressions is set, always emit parens
                    // (matching Babel's ParenthesizedExpression node output).
                    // Clear head context so inner node doesn't add redundant parens.
                    self.clearHeadContext();
                    try self.writeChar('(');
                    // If the inner node has a leading line comment, put it on a new line
                    if (self.hasLeadingLineComment(data.unary)) {
                        try self.newline();
                    }
                    try self.emitNode(data.unary);
                    // If inner ended with a line comment, put ')' on new line with indent
                    if (self.endsWithLineComment()) {
                        try self.newline();
                        try self.writeIndent();
                    }
                    try self.writeChar(')');
                } else {
                    // Transparent: restore grandparent context so the inner node
                    // sees the real parent for parenthesization decisions.
                    self.parent_tag = saved_parent_tag;
                    self.parent_data = saved_parent_data;
                    self.parent_main_token = saved_parent_main_token;
                    self.child_position = saved_child_pos;
                    self.token_context = saved_token_context;
                    self.was_parenthesized = true;

                    // Check for PURE annotation comments that require preserving parens.
                    // When a call expression has a leading `@__PURE__` comment and is
                    // the object/callee of a member/call/tagged-template, parens must
                    // be preserved to keep the annotation correct.
                    const inner_tag = self.ast.nodes.items(.tag)[@intFromEnum(data.unary)];
                    if (self.token_context.for_init_head and (inner_tag == .binary_expr or inner_tag == .logical_expr)) {
                        const saved_for_init_head = self.token_context.for_init_head;
                        const saved_parent_tag2 = self.parent_tag;
                        const saved_parent_data2 = self.parent_data;
                        const saved_parent_main_token2 = self.parent_main_token;
                        const saved_child_pos2 = self.child_position;
                        self.token_context.for_init_head = false;
                        self.parent_tag = .program;
                        self.parent_data = .{ .none = {} };
                        self.parent_main_token = @enumFromInt(0);
                        self.child_position = .none;
                        try self.writeChar('(');
                        try self.emitNode(data.unary);
                        try self.writeChar(')');
                        self.parent_tag = saved_parent_tag2;
                        self.parent_data = saved_parent_data2;
                        self.parent_main_token = saved_parent_main_token2;
                        self.child_position = saved_child_pos2;
                        self.token_context.for_init_head = saved_for_init_head;
                        self.was_parenthesized = false;
                    } else {
                        const pure_needs_parens = blk_pure: {
                            if (inner_tag != .call_expr and inner_tag != .new_expr) break :blk_pure false;
                            const needs_position = switch (saved_parent_tag) {
                                .member_expr, .computed_member_expr => saved_child_pos == .object,
                                .call_expr => saved_child_pos == .callee,
                                .optional_chain_expr, .optional_computed_member_expr => saved_child_pos == .object,
                                .optional_call_expr => saved_child_pos == .callee,
                                .tagged_template_expr => saved_child_pos == .tag,
                                else => false,
                            };
                            if (!needs_position) break :blk_pure false;
                            // Check if inner node or its callee has a leading PURE annotation
                            if (self.hasPureAnnotationComment(data.unary)) break :blk_pure true;
                            // Also check the callee of call/new expressions
                            if (inner_tag == .call_expr or inner_tag == .new_expr) {
                                const inner_data2 = self.ast.nodes.items(.data)[@intFromEnum(data.unary)];
                                const inner_extra_idx = @intFromEnum(inner_data2.extra);
                                if (inner_extra_idx < self.ast.extra_data.items.len) {
                                    const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[inner_extra_idx]);
                                    if (callee != .none and self.hasPureAnnotationComment(callee)) break :blk_pure true;
                                }
                            }
                            break :blk_pure false;
                        };
                        if (pure_needs_parens) {
                            self.clearHeadContext();
                            try self.writeChar('(');
                            try self.emitNode(data.unary);
                            try self.writeChar(')');
                        } else {

                            // Pre-check: if the inner node has leading/trailing line comments
                            // and the parent context requires content after us, we need parens
                            // to prevent line comments from consuming subsequent tokens.
                            const parent_needs_continuation = switch (saved_parent_tag) {
                                .ts_satisfies_expression,
                                .ts_as_expression,
                                .binary_expr,
                                .logical_expr,
                                .assignment_expr,
                                .conditional_expr,
                                => true,
                                else => false,
                            };
                            const inner_has_line_comment = self.hasLeadingLineComment(data.unary) or
                                self.hasTrailingLineComment(data.unary);
                            const pre_wrap = parent_needs_continuation and inner_has_line_comment and
                                saved_child_pos != .callee;

                            if (pre_wrap) {
                                self.clearHeadContext();
                                try self.writeChar('(');
                                if (self.hasLeadingLineComment(data.unary)) {
                                    try self.newline();
                                }
                                try self.emitNode(data.unary);
                                // Emit any remaining unemitted trailing comments on the
                                // inner expression and on the parenthesized_expr itself
                                // (comments between the inner expression and closing paren).
                                try self.emitAllTrailingComments(data.unary);
                                try self.emitAllTrailingComments(idx);
                                try self.emitAllInnerComments(idx);
                                if (self.endsWithLineComment()) {
                                    try self.newline();
                                }
                                try self.writeChar(')');
                            } else {
                                const buf_before = self.buf.items.len;
                                try self.emitNode(data.unary);
                                // Post-check: if the inner expression ends with a line comment,
                                // wrap retroactively.
                                if (self.endsWithLineComment() and
                                    !(buf_before < self.buf.items.len and self.buf.items[buf_before] == '(') and
                                    saved_child_pos != .callee)
                                {
                                    if (parent_needs_continuation) {
                                        try self.buf.insert(self.allocator, buf_before, '(');
                                        self.current_col += 1;
                                        try self.newline();
                                        try self.writeIndent();
                                        try self.writeChar(')');
                                    }
                                }
                            }
                        } // end pure_needs_parens else
                        self.was_parenthesized = false;
                    }
                }
            },
            .object_expr => try self.emitObjectExpr(data),
            .array_expr => try self.emitArrayExpr(data),

            // === Object/Array internals ===
            .property => try self.emitProperty(idx, data),
            .shorthand_property => try self.emitShorthandProperty(data),
            .computed_property => try self.emitComputedProperty(data),
            .computed_method => try self.emitComputedMethod(idx, data),
            .method_definition => try self.emitMethodDefinition(idx, data),
            .getter => try self.emitGetterSetter(idx, data, "get"),
            .setter => try self.emitGetterSetter(idx, data, "set"),

            // === Patterns ===
            .array_pattern => try self.emitArrayPattern(data),
            .object_pattern => try self.emitObjectPattern(data),
            .assignment_pattern => try self.emitAssignmentPattern(data),
            .rest_element => try self.emitRestElement(data),

            // === Declarations ===
            .var_declaration => try self.emitVarDeclaration(data, "var"),
            .let_declaration => try self.emitVarDeclaration(data, "let"),
            .const_declaration => try self.emitVarDeclaration(data, "const"),
            .using_declaration => try self.emitVarDeclaration(data, "using"),
            .await_using_declaration => try self.emitAwaitUsingDeclaration(idx, data),
            .declarator => try self.emitDeclarator(idx, data),
            .function_declaration => try self.emitFunctionDeclaration(idx, .function_declaration, data),
            .async_function_declaration => try self.emitFunctionDeclaration(idx, .async_function_declaration, data),
            .generator_declaration => try self.emitFunctionDeclaration(idx, .generator_declaration, data),
            .async_generator_declaration => try self.emitFunctionDeclaration(idx, .async_generator_declaration, data),
            .class_declaration => try self.emitClassDeclaration(idx, data),

            // === Class internals ===
            .class_body => try self.emitClassBody(idx, data),
            .class_field, .class_private_field => try self.emitClassField(idx, tag, data),
            .class_static_block => try self.emitStaticBlock(data),
            .class_method, .class_private_method => try self.emitClassMethod(idx, tag, data),

            // === Statements ===
            .block_statement => try self.emitBlockStatement(idx, data),
            .expression_statement => try self.emitExpressionStatement(data),
            .removed => {}, // handled above; should not reach here
            .empty_statement => try self.semicolon(),
            .if_statement => try self.emitIfStatement(data),
            .for_statement => try self.emitForStatement(data),
            .for_in_statement => try self.emitForInStatement(data),
            .for_of_statement => try self.emitForOfStatement(data, false),
            .for_of_await_statement => try self.emitForOfStatement(data, true),
            .while_statement => try self.emitWhileStatement(data),
            .do_while_statement => try self.emitDoWhileStatement(data),
            .switch_statement => try self.emitSwitchStatement(idx, data),
            .switch_case => try self.emitSwitchCase(data, false),
            .switch_default => try self.emitSwitchCase(data, true),
            .return_statement => try self.emitReturnStatement(data),
            .throw_statement => try self.emitThrowStatement(data),
            .try_statement => try self.emitTryStatement(data),
            .catch_clause => try self.emitCatchClause(data),
            .break_statement => try self.emitBreakContinue(main_token, data, "break"),
            .continue_statement => try self.emitBreakContinue(main_token, data, "continue"),
            .labeled_statement => try self.emitLabeledStatement(main_token, data),
            .with_statement => try self.emitWithStatement(data),
            .debugger_statement => {
                try self.writeStr("debugger");
                try self.semicolon();
            },

            // === Module ===
            .import_declaration => try self.emitImportDeclaration(idx, data, false),
            .import_declaration_typeof => try self.emitImportDeclaration(idx, data, true),
            .import_specifier => try self.emitImportSpecifier(data),
            .import_default => try self.emitImportDefault(main_token),
            .import_namespace => try self.emitImportNamespace(main_token),
            .import_attribute => try self.emitImportAttribute(data),
            .export_named => try self.emitExportNamed(idx, data),
            .export_default => try self.emitExportDefault(idx, data),
            .export_all => try self.emitExportAll(data),
            .module_expression => try self.emitModuleExpression(idx, data),
            .export_specifier => try self.emitExportSpecifier(data, false),
            .export_specifier_type => try self.emitExportSpecifier(data, true),
            .export_namespace_specifier => try self.emitExportNamespaceSpecifier(data),

            // === Directives ===
            .directive => try self.emitDirective(data),
            .directive_literal => try self.emitToken(main_token),

            // === Proposals ===
            .decorator => try self.emitDecorator(data),
            .placeholder => try self.emitPlaceholder(idx, main_token),
            .do_expression => try self.emitDoExpression(idx, data),
            .throw_expression => try self.emitThrowExpression(data),
            .export_default_specifier => try self.emitToken(main_token),
            .bind_expression => try self.emitBindExpression(data),
            .topic_reference => {
                // Topic references like ^^, @@ may span beyond a single token
                self.addMapping(main_token);
                const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                const end = self.ast.nodes.items(.end_offset)[@intFromEnum(idx)];
                try self.writeStr(self.ast.source[start..end]);
            },

            // === JSX — delegate to codegen_jsx ===
            .jsx_element,
            .jsx_opening_element,
            .jsx_closing_element,
            .jsx_self_closing_element,
            .jsx_fragment,
            .jsx_opening_fragment,
            .jsx_closing_fragment,
            .jsx_attribute,
            .jsx_spread_attribute,
            .jsx_spread_child,
            .jsx_expression_container,
            .jsx_string_literal,
            .jsx_empty_expression,
            .jsx_text,
            .jsx_identifier,
            .jsx_member_expression,
            .jsx_namespaced_name,
            => try codegen_jsx.emitJsxNode(self, tag, idx, main_token, data),

            // === TypeScript — delegate to codegen_ts ===
            .ts_type_annotation,
            .ts_type_reference,
            .ts_keyword_type,
            .ts_array_type,
            .ts_tuple_type,
            .ts_union_type,
            .ts_intersection_type,
            .ts_function_type,
            .ts_constructor_type,
            .ts_parenthesized_type,
            .ts_optional_type,
            .ts_rest_type,
            .ts_literal_type,
            .ts_type_parameter,
            .ts_type_parameter_declaration,
            .ts_type_parameter_instantiation,
            .ts_qualified_name,
            .ts_conditional_type,
            .ts_infer_type,
            .ts_mapped_type,
            .ts_indexed_access_type,
            .ts_template_literal_type,
            .ts_typeof_type,
            .ts_type_operator,
            .ts_type_predicate,
            .ts_import_type,
            .ts_named_tuple_member,
            .ts_as_expression,
            .ts_satisfies_expression,
            .ts_non_null_expression,
            .ts_type_assertion,
            .ts_instantiation_expression,
            .ts_type_cast_expression,
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_interface_body,
            .ts_type_literal,
            .ts_property_signature,
            .ts_method_signature,
            .ts_index_signature,
            .ts_call_signature_declaration,
            .ts_construct_signature_declaration,
            .ts_enum_declaration,
            .ts_enum_member,
            .ts_module_declaration,
            .ts_module_block,
            .ts_declare_function,
            .ts_declare_variable,
            .ts_declare_method,
            .ts_parameter_property,
            .ts_import_equals_declaration,
            .ts_export_assignment,
            .ts_namespace_export_declaration,
            .ts_external_module_reference,
            .import_declaration_type,
            .import_specifier_type,
            .import_specifier_typeof,
            .export_named_type,
            => try codegen_ts.emitTsNode(self, tag, idx, main_token, data),

            // === Flow — delegate to codegen_flow ===
            .flow_type_annotation,
            .flow_generic_type,
            .flow_qualified_type_identifier,
            .flow_nullable_type,
            .flow_union_type,
            .flow_intersection_type,
            .flow_typeof_type,
            .flow_array_type,
            .flow_tuple_type,
            .flow_number_type,
            .flow_string_type,
            .flow_boolean_type,
            .flow_void_type,
            .flow_mixed_type,
            .flow_empty_type,
            .flow_any_type,
            .flow_symbol_type,
            .flow_bigint_type,
            .flow_null_literal_type,
            .flow_number_literal_type,
            .flow_string_literal_type,
            .flow_boolean_literal_type,
            .flow_bigint_literal_type,
            .flow_exists_type,
            .flow_object_type,
            .flow_object_type_property,
            .flow_object_type_spread_property,
            .flow_object_type_indexer,
            .flow_object_type_call_property,
            .flow_object_type_internal_slot,
            .flow_exact_object_type,
            .flow_type_alias,
            .flow_declare_type_alias,
            .flow_opaque_type,
            .flow_interface_declaration,
            .flow_interface_body,
            .flow_interface_extends,
            .flow_declare_class,
            .flow_declare_function,
            .flow_declare_variable,
            .flow_declare_module,
            .flow_declare_module_exports,
            .flow_declare_export_declaration,
            .flow_declare_export_all_declaration,
            .flow_declare_interface,
            .flow_declare_opaque_type,
            .flow_type_parameter,
            .flow_type_parameter_declaration,
            .flow_type_parameter_instantiation,
            .flow_type_cast_expression,
            .flow_function_type_annotation,
            .flow_function_type_param,
            .flow_indexed_access_type,
            .flow_optional_indexed_access_type,
            .flow_inferred_predicate,
            .flow_declared_predicate,
            .flow_this_type_annotation,
            .flow_interface_type_annotation,
            .flow_variance,
            .flow_parenthesized_type,
            .flow_enum_declaration,
            .flow_enum_boolean_body,
            .flow_enum_number_body,
            .flow_enum_string_body,
            .flow_enum_symbol_body,
            .flow_enum_boolean_member,
            .flow_enum_number_member,
            .flow_enum_string_member,
            .flow_enum_default_member,
            => try codegen_flow.emitFlowNode(self, tag, idx, main_token, data),
        }

        // Emit expression-level trailing comments (statement-level handled by list emitters)
        if (tag != .program) {
            try self.emitTrailingComments(idx);
        }

        if (wrap) {
            // If the expression ends with a line comment, put ')' on new line
            // to prevent it from being consumed by the comment.
            if (self.endsWithLineComment()) {
                try self.newline();
                try self.writeIndent();
            }
            try self.writeChar(')');
        }
    }

    // ---------------------------------------------------------------
    // Program / Directives
    // ---------------------------------------------------------------

    /// Suppress program-level leading comments when the first body items are removed,
    /// to prevent double-emission (the body loop handles them via
    /// emitRemovedNodePreservedComments). Only suppress when the first body item
    /// is a removed node — if the first item is surviving, its own leading
    /// comment handler picks up comments normally.
    fn markRemovedLeadingComments(self: *Codegen, program_idx: NodeIndex, items: []const u32, directive_count: usize, tags: []const Node.Tag) void {
        _ = directive_count;
        const prog_key = @intFromEnum(program_idx);
        const prog_range = self.ast.leading_comments.get(prog_key) orelse return;
        const comments = self.ast.comments.items;
        if (prog_range.start >= prog_range.end or prog_range.start >= comments.len) return;

        // Only suppress if the first body item is a removed node.
        // If the first item survives, program-level comments will be emitted
        // normally by emitStatementLeadingComments(program_idx, 0).
        if (items.len == 0) return;
        const first_item = items[0];
        if (first_item >= tags.len or tags[first_item] != .removed) return;

        // The first body item is removed. Program-level comments that precede
        // it will be handled by emitRemovedNodePreservedComments in the body loop.
        // Suppress them here to prevent double-emission.
        var ci = prog_range.start;
        while (ci < prog_range.end and ci < comments.len) : (ci += 1) {
            self.emitted_comments.set(ci);
        }
    }

    fn emitProgram(self: *Codegen, data: Node.Data) Error!void {
        const program_idx: NodeIndex = @enumFromInt(0);
        // Emit hashbang if present
        if (self.ast.hashbang_end) |end| {
            try self.writeStr(self.ast.source[0..end]);
            try self.newline();
        }

        const extra_idx = @intFromEnum(data.extra);
        const range_start = self.ast.extra_data.items[extra_idx];
        const range_end = self.ast.extra_data.items[extra_idx + 1];
        const items = self.ast.extra_data.items[range_start..range_end];
        const tags = self.ast.nodes.items(.tag);

        if (items.len == 0) {
            // Empty program — emit leading + inner comments
            // If source starts with a newline before comments, preserve the leading blank line.
            if (self.ast.source.len > 0 and self.ast.source[0] == '\n') {
                try self.newline();
            }
            try self.emitStatementLeadingComments(program_idx, 0);
            try self.emitProgramInnerComments(program_idx);
            return;
        }

        // Count leading directives
        var directive_count: usize = 0;
        for (items) |item| {
            if (tags[item] == .directive) {
                directive_count += 1;
            } else {
                break;
            }
        }

        // Emit Program's own leading comments (before any body items).
        // First, mark comments belonging to removed first-statements as emitted
        // so they don't appear in the output.
        self.markRemovedLeadingComments(program_idx, items, directive_count, tags);
        try self.emitStatementLeadingComments(program_idx, 0);

        // Emit directives
        for (items[0..directive_count]) |item| {
            try self.emitNode(@enumFromInt(item));
            if (!self.single_line_retain) try self.newline();
        }

        // Blank line after directives if there are body statements
        if (!self.single_line_retain and directive_count > 0 and directive_count < items.len) {
            try self.newline();
        }

        // Emit block prefix source for program level (e.g., `var _this = this;` from arrow-functions transform)
        if (self.ast.block_prefix_source.get(0)) |prefix| {
            try self.writeReplacementIndented(prefix);
            if (!self.single_line_retain and (prefix.len == 0 or prefix[prefix.len - 1] != '\n')) {
                try self.newline();
            }
        }

        // Emit body statements with comment handling
        var prev_end: u32 = if (self.ast.hashbang_end) |end| end else 0;
        if (directive_count > 0) {
            // prev_end is after the last directive
            const last_dir = items[directive_count - 1];
            prev_end = self.ast.nodes.items(.end_offset)[last_dir];
        }
        var prev_had_trailing = false;
        var first_body_stmt = true;
        for (items[directive_count..]) |item| {
            if (tags[item] == .removed) {
                // Emit preserved comments from removed nodes (e.g., JSDoc on removed type exports).
                const node_idx_rm: NodeIndex = @enumFromInt(item);
                const rm_end = self.getStatementEndWithTrailingComments(node_idx_rm);
                const removed_comments = try self.emitRemovedNodePreservedComments(node_idx_rm, prev_end, prev_had_trailing);
                if (rm_end > prev_end) prev_end = rm_end;
                // Only signal trailing content when removed-node comments were emitted
                // and we did not already preserve the trailing vertical gap ourselves.
                prev_had_trailing = removed_comments.emitted_any and !removed_comments.preserved_trailing_gap;
                continue;
            }
            const node_idx: NodeIndex = @enumFromInt(item);
            if (first_body_stmt and directive_count > 0) {
                try self.emitStatementLeadingCommentsNoBlank(node_idx, prev_end);
            } else {
                try self.emitStatementLeadingCommentsImplEx(node_idx, prev_end, true, prev_had_trailing);
            }
            try self.emitNode(node_idx);
            try self.emitRemainingStatementComments(node_idx);
            if (!self.single_line_retain) try self.newline();
            prev_had_trailing = self.statementHasDirectTrailingComments(node_idx);
            prev_end = self.getStatementEndWithTrailingComments(node_idx);
            first_body_stmt = false;
        }

        // Emit inner comments (comments after all body items)
        try self.emitProgramInnerComments(program_idx);
        // Emit trailing comments of Program
        try self.emitTrailingComments(program_idx);
    }

    fn emitExpressionStatement(self: *Codegen, data: Node.Data) Error!void {
        self.token_context.expression_statement = true;
        const start_len = self.buf.items.len;
        try self.emitNode(data.unary);
        const emitted = std.mem.trimEnd(u8, self.buf.items[start_len..], " \t\r\n");
        if (std.mem.endsWith(u8, emitted, ";")) return;
        try self.emitSemicolonAfterTrailingComment();
    }

    /// Emit a semicolon, inserting it before any trailing comment if one was
    /// just emitted. This prevents line comments from consuming the semicolon.
    pub fn emitSemicolonAfterTrailingComment(self: *Codegen) Error!void {
        if (self.buf.items.len >= 2) {
            if (self.findTrailingLineComment(self.buf.items)) |offset| {
                // Insert ';' before the trailing line comment
                try self.buf.append(self.allocator, 0); // make room
                const items = self.buf.items;
                std.mem.copyBackwards(u8, items[offset + 1 ..], items[offset .. items.len - 1]);
                items[offset] = ';';
                self.current_col += 1;
                return;
            }
        }
        try self.semicolon();
    }

    /// After inserting a character before a multi-line block comment,
    /// add 1 space to the start of each continuation line to maintain alignment.
    fn adjustMultiLineCommentAfterInsert(self: *Codegen, comment_start: usize) void {
        const items = self.buf.items;
        // Check if this is a multi-line block comment
        if (comment_start + 2 >= items.len) return;
        if (items[comment_start] != ' ') return; // expect space before /*
        if (comment_start + 3 >= items.len or items[comment_start + 1] != '/' or items[comment_start + 2] != '*') return;
        // Find continuation lines and add a space at each
        var pos: usize = comment_start + 3;
        while (pos < items.len) {
            if (items[pos] == '\n') {
                pos += 1;
                // Insert a space at the start of this continuation line
                self.buf.insert(self.allocator, pos, ' ') catch return;
                self.current_col += 0; // No col change needed (we're tracking end of buffer)
            } else {
                pos += 1;
            }
        }
    }

    /// Check if the output buffer currently ends with a line comment (//).
    /// Line comments consume the rest of the line, so any text after them
    /// needs to be on a new line.
    pub fn endsWithLineComment(self: *Codegen) bool {
        const buf = self.buf.items;
        if (buf.len < 2) return false;
        // Search backwards from end for '//' on the last line.
        // Track nesting depth: ')' increases depth, '(' decreases.
        // Only report a line comment if we find '//' at depth 0.
        var pos: usize = buf.len;
        var depth: u32 = 0;
        while (pos >= 2) {
            pos -= 1;
            if (buf[pos] == ')' or buf[pos] == ']' or buf[pos] == '}') {
                depth += 1;
            } else if (buf[pos] == '(' or buf[pos] == '[' or buf[pos] == '{') {
                if (depth > 0) depth -= 1;
            } else if (buf[pos] == '/' and buf[pos - 1] == '/') {
                if (depth == 0) return true;
            } else if (buf[pos] == '\n') {
                return false;
            }
        }
        return false;
    }

    /// Check if the buffer ends with a block comment (/* ... */).
    pub fn endsWithBlockComment(self: *Codegen) bool {
        const buf = self.buf.items;
        return buf.len >= 4 and buf[buf.len - 1] == '/' and buf[buf.len - 2] == '*';
    }

    /// Check if the buffer ends with a multi-line block comment (/* ... */ containing newlines).
    pub fn endsWithMultiLineBlockComment(self: *Codegen) bool {
        const buf = self.buf.items;
        if (buf.len < 4) return false;
        // Check if buffer ends with */
        if (buf[buf.len - 1] != '/' or buf[buf.len - 2] != '*') return false;
        // Search backwards for matching /*
        var pos: usize = buf.len - 3;
        var has_newline = false;
        while (pos >= 1) : (pos -= 1) {
            if (buf[pos] == '\n') has_newline = true;
            if (buf[pos] == '*' and buf[pos - 1] == '/') {
                return has_newline;
            }
            if (pos == 0) break;
        }
        return false;
    }

    /// Find the byte offset of a trailing comment in the emitted text.
    /// Returns the offset of the space before the comment start, or null if not found.
    /// Handles both line comments (//) and block comments (/* ... */) that are at the
    /// very end of the emitted text.
    fn findTrailingComment(self: *Codegen, text: []const u8) ?usize {
        _ = self;
        if (text.len < 2) return null;

        // Check for trailing line comment: text ends with "// ..." (no newline)
        // Search backwards from end for '//' on the last line.
        // Track nesting depth to skip comments inside parens/brackets/braces.
        {
            var pos: usize = text.len;
            var depth: u32 = 0;
            while (pos >= 2) {
                pos -= 1;
                if (text[pos] == ')' or text[pos] == ']' or text[pos] == '}') {
                    depth += 1;
                } else if (text[pos] == '(' or text[pos] == '[' or text[pos] == '{') {
                    if (depth > 0) depth -= 1;
                } else if (text[pos] == '/' and text[pos - 1] == '/') {
                    if (depth == 0) {
                        const comment_start = if (pos >= 2 and text[pos - 2] == ' ')
                            pos - 2
                        else
                            pos - 1;
                        return comment_start;
                    }
                } else if (text[pos] == '\n') break;
            }
        }

        // Check for trailing block comment: text ends with "/* ... */"
        if (text.len >= 4 and text[text.len - 1] == '/' and text[text.len - 2] == '*') {
            // Scan backwards from the end to find matching '/*'
            var bpos = text.len - 2;
            while (bpos >= 1) {
                if (text[bpos] == '*' and text[bpos - 1] == '/') {
                    const comment_start = if (bpos >= 2 and text[bpos - 2] == ' ')
                        bpos - 2
                    else
                        bpos - 1;
                    return comment_start;
                }
                if (bpos == 0) break;
                bpos -= 1;
            }
        }

        return null;
    }

    /// Find trailing line comment only (not block comments).
    /// Used for semicolon insertion — block comments don't consume the semicolon.
    fn findTrailingLineComment(self: *Codegen, text: []const u8) ?usize {
        _ = self;
        if (text.len < 2) return null;

        var pos: usize = text.len;
        var depth: u32 = 0;
        while (pos >= 2) {
            pos -= 1;
            if (text[pos] == ')' or text[pos] == ']' or text[pos] == '}') {
                depth += 1;
            } else if (text[pos] == '(' or text[pos] == '[' or text[pos] == '{') {
                if (depth > 0) depth -= 1;
            } else if (text[pos] == '/' and text[pos - 1] == '/') {
                if (depth == 0) {
                    const comment_start = if (pos >= 2 and text[pos - 2] == ' ')
                        pos - 2
                    else
                        pos - 1;
                    return comment_start;
                }
            } else if (text[pos] == '\n') break;
        }

        return null;
    }

    fn emitDirective(self: *Codegen, data: Node.Data) Error!void {
        try self.emitNode(data.unary);
        try self.semicolon();
    }

    // ---------------------------------------------------------------
    // Expressions
    // ---------------------------------------------------------------

    fn emitBinaryExpr(self: *Codegen, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) Error!void {
        // Check for operator override (from split token like %===)
        const op = if (self.ast.operator_overrides.get(@intFromEnum(idx))) |op_str|
            op_str
        else
            self.operatorStr(main_token);
        const shields_for_init = self.token_context.for_init_head and
            !std.mem.eql(u8, op, "in") and
            (self.needsParens(self.ast.nodes.items(.tag)[@intFromEnum(idx)], idx) or
                self.isSourceWrappedInParens(idx));
        const saved_for_init_head = self.token_context.for_init_head;
        if (shields_for_init) self.token_context.for_init_head = false;
        defer self.token_context.for_init_head = saved_for_init_head;

        self.child_position = .left;
        try self.emitNode(data.binary.lhs);
        // If the LHS ends with a line comment, put the operator on a new line
        // to prevent it from being consumed by the comment.
        if (self.endsWithLineComment()) {
            try self.newline();
            try self.writeIndent();
            try self.writeStr(op);
        } else {
            try self.space();
            try self.writeStr(op);
        }
        try self.space();
        self.child_position = .right;
        self.clearHeadContext();
        var rhs = data.binary.rhs;
        if (shields_for_init and rhs != .none and self.ast.nodes.items(.tag)[@intFromEnum(rhs)] == .parenthesized_expr) {
            const inner = self.ast.nodes.items(.data)[@intFromEnum(rhs)].unary;
            if (inner != .none and self.ast.nodes.items(.tag)[@intFromEnum(inner)] == .binary_expr and std.mem.eql(u8, self.nodeOperator(inner), "in")) {
                rhs = inner;
            }
        }
        try self.emitNode(rhs);
    }

    fn emitUnaryExpr(self: *Codegen, main_token: TokenIndex, data: Node.Data) Error!void {
        const op = self.operatorStr(main_token);
        try self.writeStr(op);
        if (isWordOperator(op)) {
            try self.space();
        } else if (data.unary != .none) {
            // Need space to avoid ambiguity: + +x, - -x, + ++x, - --x
            const arg_i = @intFromEnum(data.unary);
            const arg_tag = self.ast.nodes.items(.tag)[arg_i];
            const arg_mt = self.ast.nodes.items(.main_token)[arg_i];
            const arg_op = switch (arg_tag) {
                .unary_expr, .update_expr => self.operatorStr(arg_mt),
                else => "",
            };
            if ((std.mem.eql(u8, op, "+") and arg_op.len > 0 and arg_op[0] == '+') or
                (std.mem.eql(u8, op, "-") and arg_op.len > 0 and arg_op[0] == '-'))
            {
                try self.space();
            }
        }
        self.child_position = .argument;
        self.clearHeadContext();
        try self.emitNode(data.unary);
    }

    fn emitUpdateExpr(self: *Codegen, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) Error!void {
        const op = self.operatorStr(main_token);
        // Determine prefix: if main_token is before the argument, it's prefix
        const op_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
        const arg_idx = @intFromEnum(data.unary);
        const arg_main_token = self.ast.nodes.items(.main_token)[arg_idx];
        const arg_start = self.ast.tokens.items(.start)[@intFromEnum(arg_main_token)];
        _ = idx;
        const is_prefix = op_start < arg_start;
        self.child_position = .argument;
        if (is_prefix) {
            try self.writeStr(op);
            self.clearHeadContext();
            try self.emitNode(data.unary);
        } else {
            // Postfix: argument is the leading position (inherits head context)
            // If the argument has a trailing line comment, wrap in parens to prevent
            // the comment from consuming the operator.
            const needs_paren = self.hasTrailingLineComment(data.unary);
            if (needs_paren) try self.writeChar('(');
            try self.emitNode(data.unary);
            if (needs_paren) {
                try self.newline();
                try self.writeChar(')');
            }
            try self.writeStr(op);
        }
    }

    fn emitAssignmentExpr(self: *Codegen, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) Error!void {
        const op = if (self.ast.operator_overrides.get(@intFromEnum(idx))) |op_str|
            op_str
        else
            self.operatorStr(main_token);

        self.child_position = .left;
        try self.emitNode(data.binary.lhs);
        try self.space();
        try self.writeStr(op);
        try self.space();
        self.child_position = .right;
        self.clearHeadContext();
        try self.emitNode(data.binary.rhs);
    }

    fn emitConditionalExpr(self: *Codegen, data: Node.Data) Error!void {
        // data.binary.lhs = test, data.binary.rhs is an ExtraIndex into extra_data
        const extra_start = @intFromEnum(data.binary.rhs);
        const consequent: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_start]);
        const alternate: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_start + 1]);

        self.child_position = .test_expr;
        try self.emitNode(data.binary.lhs);
        try self.writeStr(" ? ");
        self.child_position = .consequent;
        self.clearHeadContext();
        try self.emitNode(consequent);
        try self.writeStr(" : ");
        self.child_position = .alternate;
        try self.emitNode(alternate);
    }

    fn emitSequenceExpr(self: *Codegen, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                try self.emitCommaSeparated(range_start, range_end);
            }
        }
    }

    fn emitCallExpr(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const args_start = self.ast.extra_data.items[extra_idx + 1];
        const args_end = self.ast.extra_data.items[extra_idx + 2];

        self.child_position = .callee;
        try self.emitNode(callee);
        self.clearHeadContext();
        self.child_position = .none;
        // TS: type arguments on call expression
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        try self.writeChar('(');
        if (args_start <= args_end and args_end <= self.ast.extra_data.items.len) {
            try self.emitCommaSeparated(args_start, args_end);
        }
        // If args end with a line comment, put ')' on new line
        if (self.endsWithLineComment()) {
            try self.newline();
            try self.writeIndent();
        }
        try self.writeChar(')');
    }

    fn emitOptionalCallExpr(self: *Codegen, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const args_start = self.ast.extra_data.items[extra_idx + 1];
        const args_end = self.ast.extra_data.items[extra_idx + 2];

        self.child_position = .callee;
        try self.emitNode(callee);
        self.clearHeadContext();
        self.child_position = .none;
        const is_direct = self.ast.tokens.items(.tag)[@intFromEnum(main_token)] == .optional_chain;
        if (is_direct) {
            try self.writeStr("?.");
        }
        // TS/Flow: type arguments on optional call expression
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        try self.writeChar('(');
        if (args_start <= args_end and args_end <= self.ast.extra_data.items.len) {
            try self.emitCommaSeparated(args_start, args_end);
        }
        try self.writeChar(')');
    }

    fn emitNewExpr(self: *Codegen, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) Error!void {
        try self.emitKeyword(main_token, "new");
        try self.space();
        const extra_idx = @intFromEnum(data.extra);
        const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const args_start = self.ast.extra_data.items[extra_idx + 1];
        const args_end = self.ast.extra_data.items[extra_idx + 2];

        self.child_position = .callee;
        self.clearHeadContext();
        try self.emitNode(callee);
        self.child_position = .none;
        // TS: type arguments on new expression
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        try self.writeChar('(');
        if (args_start <= args_end and args_end <= self.ast.extra_data.items.len) {
            try self.emitCommaSeparated(args_start, args_end);
        }
        try self.writeChar(')');
    }

    fn emitMemberExpr(self: *Codegen, outer_parent_tag: Node.Tag, outer_child_pos: ChildPosition, data: Node.Data) Error!void {
        const wrap_object = self.shouldWrapKeywordMemberObject(outer_parent_tag, outer_child_pos, data.binary.lhs);
        self.child_position = .object;
        if (wrap_object) try self.writeChar('(');
        try self.emitNode(data.binary.lhs);
        if (wrap_object) try self.writeChar(')');
        // Check if the property token is preceded by a # (private)
        const prop_token_idx = @intFromEnum(data.binary.rhs);
        const is_private = prop_token_idx > 0 and self.ast.tokens.items(.tag)[prop_token_idx - 1] == .hash;
        if (is_private) {
            try self.writeStr(".#");
        } else {
            try self.writeChar('.');
        }
        const prop_start = self.ast.tokens.items(.start)[prop_token_idx];
        const prop_end = self.ast.tokens.items(.end)[prop_token_idx];
        try self.writeStr(self.ast.source[prop_start..prop_end]);
    }

    fn emitComputedMemberExpr(self: *Codegen, outer_parent_tag: Node.Tag, outer_child_pos: ChildPosition, data: Node.Data) Error!void {
        const wrap_object = self.shouldWrapKeywordMemberObject(outer_parent_tag, outer_child_pos, data.binary.lhs);
        self.child_position = .object;
        if (wrap_object) try self.writeChar('(');
        try self.emitNode(data.binary.lhs);
        if (wrap_object) try self.writeChar(')');
        try self.writeChar('[');
        self.child_position = .right;
        self.clearHeadContext();
        try self.emitNode(data.binary.rhs);
        try self.writeChar(']');
    }

    fn emitOptionalChainExpr(self: *Codegen, main_token: TokenIndex, data: Node.Data) Error!void {
        self.child_position = .object;
        try self.emitNode(data.binary.lhs);
        // Check if this node is directly optional (?.xxx) or a continuation (.xxx within a chain)
        const is_direct = self.ast.tokens.items(.tag)[@intFromEnum(main_token)] == .optional_chain;
        const prop_token_idx = @intFromEnum(data.binary.rhs);
        const is_private = prop_token_idx > 0 and self.ast.tokens.items(.tag)[prop_token_idx - 1] == .hash;
        if (is_direct) {
            if (is_private) {
                try self.writeStr("?.#");
            } else {
                try self.writeStr("?.");
            }
        } else {
            if (is_private) {
                try self.writeStr(".#");
            } else {
                try self.writeChar('.');
            }
        }
        const prop_start = self.ast.tokens.items(.start)[prop_token_idx];
        const prop_end = self.ast.tokens.items(.end)[prop_token_idx];
        try self.writeStr(self.ast.source[prop_start..prop_end]);
    }

    fn emitOptionalComputedMemberExpr(self: *Codegen, main_token: TokenIndex, data: Node.Data) Error!void {
        self.child_position = .object;
        try self.emitNode(data.binary.lhs);
        const is_direct = self.ast.tokens.items(.tag)[@intFromEnum(main_token)] == .optional_chain;
        if (is_direct) {
            try self.writeStr("?.[");
        } else {
            try self.writeChar('[');
        }
        self.child_position = .right;
        self.clearHeadContext();
        try self.emitNode(data.binary.rhs);
        try self.writeChar(']');
    }

    /// Check if a single arrow function parameter can omit parentheses
    /// Only plain identifiers without type annotations/optional markers can omit parens
    /// Check if a single arrow function parameter can omit parentheses.
    /// Only plain identifiers (not keywords) without type annotations/optional markers can omit parens.
    fn canOmitArrowParens(self: *Codegen, param: NodeIndex) bool {
        const param_tag = self.ast.nodes.items(.tag)[@intFromEnum(param)];
        if (param_tag != .identifier) return false;
        // Check for type annotation (e.g., x: number => ...)
        if (self.ast.type_annotations.contains(@intFromEnum(param))) return false;
        // Check for optional parameter
        if (self.ast.ts_optional_params.contains(@intFromEnum(param))) return false;
        // Check if the token is a keyword (void, this, etc.) — needs parens
        const param_mt = self.ast.nodes.items(.main_token)[@intFromEnum(param)];
        const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(param_mt)];
        if (tok_tag.isKeyword()) return false;
        return true;
    }

    fn emitArrowBody(self: *Codegen, arrow_idx: NodeIndex, body: NodeIndex, wrap_for_init_in_body: bool) Error!void {
        if (body == .none) return;
        const body_tag = self.ast.nodes.items(.tag)[@intFromEnum(body)];
        const saved_for_init_head = self.token_context.for_init_head;
        if (self.isSourceWrappedInParens(arrow_idx)) {
            self.token_context.for_init_head = false;
        }
        defer self.token_context.for_init_head = saved_for_init_head;
        self.child_position = .body;
        self.clearHeadContext(); // Body is after => so not at statement head
        if (body_tag != .block_statement) {
            if (self.ast.block_prefix_source.get(@intFromEnum(arrow_idx))) |prefix| {
                try self.writeChar('{');
                self.indent_level += 1;

                try self.newline();
                try self.writeIndent();
                try self.writeReplacementIndented(prefix);
                if (prefix.len == 0 or prefix[prefix.len - 1] != '\n') {
                    try self.newline();
                }

                try self.writeIndent();
                try self.writeStr("return ");
                self.token_context.arrow_body = true;
                try self.emitNode(body);
                try self.semicolon();
                try self.newline();
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeChar('}');
                return;
            }

            // Expression body — set arrow_body context so objects get wrapped
            self.token_context.arrow_body = true;
        }
        if (wrap_for_init_in_body and body_tag == .binary_expr and std.mem.eql(u8, self.nodeOperator(body), "in")) {
            try self.writeChar('(');
            try self.emitNode(body);
            try self.writeChar(')');
            return;
        }
        try self.emitNode(body);
    }

    fn emitArrowFunctionExpr(self: *Codegen, outer_parent_tag: Node.Tag, outer_child_pos: ChildPosition, idx: NodeIndex, data: Node.Data) Error!void {
        // Check if async
        const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
        const mt_tag = self.ast.tokens.items(.tag)[@intFromEnum(mt)];
        const is_async = (mt_tag == .kw_async) or self.ast.async_arrow_flags.contains(@intFromEnum(idx));
        const outer_needs_parens = switch (outer_parent_tag) {
            .unary_expr, .spread_element, .binary_expr, .logical_expr, .await_expr, .ts_as_expression, .ts_satisfies_expression => true,
            .conditional_expr => outer_child_pos == .test_expr,
            .call_expr, .new_expr => outer_child_pos == .callee,
            .member_expr, .computed_member_expr, .optional_chain_expr, .optional_computed_member_expr => outer_child_pos == .object,
            .tagged_template_expr => outer_child_pos == .tag,
            else => false,
        };
        const wrap_for_init_in_body = self.token_context.for_init_head and !outer_needs_parens;

        if (is_async) {
            try self.writeStr("async");
            // Emit inner comments on arrow function between 'async' and params
            // (only those before the '(' position, not inside parens)
            {
                const async_mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                const async_end = self.ast.tokens.items(.start)[@intFromEnum(async_mt)] + @as(u32, @intCast(self.ast.tokenSlice(async_mt).len));
                // Find '(' position
                var async_paren: u32 = async_end;
                while (async_paren < self.ast.source.len) : (async_paren += 1) {
                    if (self.ast.source[async_paren] == '(') break;
                }
                try self.emitInnerCommentsBefore(idx, async_paren);
            }
            // Also check leading comments on body that are before the params
            {
                const extra_idx2 = @intFromEnum(data.extra);
                if (extra_idx2 < self.ast.extra_data.items.len and extra_idx2 + 2 < self.ast.extra_data.items.len) {
                    const body2: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx2 + 1]);
                    if (body2 != .none) {
                        // Find the '(' position
                        const async_tok = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                        const tok_start = self.ast.tokens.items(.start)[@intFromEnum(async_tok)];
                        const tok_slice = self.ast.tokenSlice(async_tok);
                        const async_end = tok_start + @as(u32, @intCast(tok_slice.len));
                        var paren_pos2: u32 = async_end;
                        while (paren_pos2 < self.ast.source.len) : (paren_pos2 += 1) {
                            // Skip block comments
                            if (paren_pos2 + 1 < self.ast.source.len and
                                self.ast.source[paren_pos2] == '/' and self.ast.source[paren_pos2 + 1] == '*')
                            {
                                paren_pos2 += 2;
                                while (paren_pos2 + 1 < self.ast.source.len) : (paren_pos2 += 1) {
                                    if (self.ast.source[paren_pos2] == '*' and self.ast.source[paren_pos2 + 1] == '/') {
                                        paren_pos2 += 1;
                                        break;
                                    }
                                }
                                continue;
                            }
                            if (self.ast.source[paren_pos2] == '(') break;
                        }
                        try self.emitLeadingCommentsBeforePos(body2, paren_pos2);
                    }
                }
            }
            try self.space();
        }

        // TS: type parameters (forces parens around single param)
        const has_type_params = self.ast.type_parameters.contains(@intFromEnum(idx));
        if (has_type_params) {
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                self.arrow_type_params = true;
                try self.emitNode(tp);
                self.arrow_type_params = false;
            }
        }

        // TS: return type (also forces parens)
        const has_return_type = self.ast.return_types.contains(@intFromEnum(idx));
        // Flow: predicate (also forces parens)
        const has_predicate = self.ast.predicate_map.contains(@intFromEnum(idx));

        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len and extra_idx + 2 < self.ast.extra_data.items.len) {
            const first = self.ast.extra_data.items[extra_idx];
            const second = self.ast.extra_data.items[extra_idx + 1];
            const third = self.ast.extra_data.items[extra_idx + 2];

            if (first == @intFromEnum(NodeIndex.none) or third == 1) {
                // Old format: param, body, count
                const param: NodeIndex = @enumFromInt(first);
                const body: NodeIndex = @enumFromInt(second);
                const has_comment_forcing_parens = if (param != .none) blk: {
                    if (is_async) {
                        // Async arrows: force parens only for comments INSIDE the source '()'.
                        // Comments between 'async' and '(' or between ')' and '=>' get repositioned.
                        const paren_open = self.findCharInSource(self.nodeSourceStart(idx), '(');
                        const paren_close = self.findMatchingParen(paren_open);
                        break :blk self.hasCommentsInsideRange(param, paren_open + 1, paren_close);
                    } else {
                        // Non-async: only line comments force parens
                        break :blk self.checkNodeLeadingLineComment(param) or self.hasTrailingLineComment(param);
                    }
                } else false;
                if (param != .none and self.canOmitArrowParens(param) and !has_type_params and !has_return_type and !has_predicate and !has_comment_forcing_parens) {
                    if (is_async) {
                        // Async arrows without parens: reposition leading comments to after param
                        // 1. Pre-mark leading comments as emitted so emitNode won't emit them
                        const leading_range = self.ast.leading_comments.get(@intFromEnum(param));
                        if (leading_range) |range| {
                            var li = range.start;
                            while (li < range.end and li < self.ast.comments.items.len) : (li += 1) {
                                self.emitted_comments.set(li);
                            }
                        }
                        try self.emitNode(param);
                        // 2. Emit the leading comments after param
                        if (leading_range) |range| {
                            var li = range.start;
                            while (li < range.end and li < self.ast.comments.items.len) : (li += 1) {
                                const comment = self.ast.comments.items[li];
                                try self.space();
                                try self.emitCommentText(comment);
                            }
                        }
                        // Also emit any inner comments on the arrow (e.g., between ')' and '=>')
                        try self.emitInnerComments(idx);
                    } else {
                        const saved_for_init_head = self.token_context.for_init_head;
                        self.token_context.for_init_head = false;
                        defer self.token_context.for_init_head = saved_for_init_head;
                        try self.emitNode(param);
                    }
                } else {
                    try self.writeChar('(');
                    // Add newline after '(' if first param has leading line comment
                    if (param != .none and self.checkNodeLeadingLineComment(param)) {
                        try self.newline();
                    }
                    if (param != .none) {
                        const saved_for_init_head = self.token_context.for_init_head;
                        self.token_context.for_init_head = false;
                        defer self.token_context.for_init_head = saved_for_init_head;
                        try self.emitTsParam(param);
                    } else {
                        // Check for comments inside empty parens (inner or body leading)
                        const has_inner = self.hasExpandedInnerComments(idx);
                        const has_body_leading = self.hasLeadingComments(body);
                        if (has_inner or has_body_leading) {
                            // For async arrows: check if we can move single-line comments
                            // before '()' instead of keeping them inside
                            const has_multiline = self.hasMultiLineInnerComments(idx) or self.hasMultiLineLeadingComments(body);
                            if (is_async and !has_multiline and !self.hasLineInnerComments(idx) and !self.hasLeadingLineComment(body)) {
                                // Move all single-line block comments before '()'
                                // Rewind: remove the '(' we just wrote
                                if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] == '(') {
                                    _ = self.buf.pop();
                                    self.current_col -= 1;
                                }
                                try self.emitInnerComments(idx);
                                try self.emitExprLeadingComments(body);
                                try self.writeStr(" (");
                                // No inner comments to emit inside parens now
                            } else if (self.hasLineInnerComments(idx) or self.hasLeadingLineComment(body)) {
                                // Line comments: expand parens with newlines
                                try self.newline();
                                self.indent();
                                try self.writeIndent();
                                try self.emitInnerComments(idx);
                                try self.emitExprLeadingComments(body);
                                self.dedent();
                                // Remove trailing whitespace indent before ')'
                                while (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] == ' ') {
                                    _ = self.buf.pop();
                                    self.current_col -= 1;
                                }
                            } else if (self.hasMultipleLeadingComments(body) or (has_inner and has_body_leading)) {
                                // Multiple comments with at least one multi-line: expanded format
                                // Newline after '(' , indent, emit all comments, dedent
                                try self.newline();
                                self.indent();
                                try self.writeIndent();
                                try self.emitInnerComments(idx);
                                try self.emitExprLeadingComments(body);
                                self.dedent();
                            } else {
                                // Single multi-line block comment: emit inline inside parens
                                try self.emitInnerComments(idx);
                                try self.emitExprLeadingComments(body);
                            }
                        }
                    }
                    try self.writeChar(')');
                }
                if (has_return_type) {
                    if (self.ast.return_types.get(@intFromEnum(idx))) |rt| {
                        self.token_context.arrow_flow_return_type = true;
                        try self.emitNode(rt);
                        self.token_context.arrow_flow_return_type = false;
                    }
                }
                // Flow: predicate
                if (self.ast.predicate_map.get(@intFromEnum(idx))) |pred| {
                    if (has_return_type) {
                        try self.writeChar(' ');
                    } else {
                        try self.writeStr(": ");
                    }
                    try self.emitNode(pred);
                }
                try self.writeStr(" => ");
                try self.emitArrowBody(idx, body, wrap_for_init_in_body);
            } else {
                // New format: range_start, range_end, body
                const range_start = first;
                const range_end = second;
                const body: NodeIndex = @enumFromInt(third);
                const param_count = range_end - range_start;
                if (param_count == 1 and range_start < self.ast.extra_data.items.len and !has_type_params and !has_return_type and !has_predicate) {
                    const single_param: NodeIndex = @enumFromInt(self.ast.extra_data.items[range_start]);
                    const has_comment_forcing_parens2 = blk2: {
                        if (is_async) {
                            // Async arrows: force parens only for comments INSIDE the source '()'.
                            const paren_open2 = self.findCharInSource(self.nodeSourceStart(idx), '(');
                            const paren_close2 = self.findMatchingParen(paren_open2);
                            break :blk2 self.hasCommentsInsideRange(single_param, paren_open2 + 1, paren_close2);
                        } else {
                            break :blk2 self.checkNodeLeadingLineComment(single_param) or self.hasTrailingLineComment(single_param);
                        }
                    };
                    if (self.canOmitArrowParens(single_param) and !has_comment_forcing_parens2) {
                        if (is_async) {
                            // Reposition leading comments to after param
                            const leading_range2 = self.ast.leading_comments.get(@intFromEnum(single_param));
                            if (leading_range2) |range| {
                                var li = range.start;
                                while (li < range.end and li < self.ast.comments.items.len) : (li += 1) {
                                    self.emitted_comments.set(li);
                                }
                            }
                            try self.emitNode(single_param);
                            if (leading_range2) |range| {
                                var li = range.start;
                                while (li < range.end and li < self.ast.comments.items.len) : (li += 1) {
                                    const comment = self.ast.comments.items[li];
                                    try self.space();
                                    try self.emitCommentText(comment);
                                }
                            }
                            // Also emit inner comments on the arrow (between ')' and '=>')
                            try self.emitInnerComments(idx);
                        } else {
                            const saved_for_init_head = self.token_context.for_init_head;
                            self.token_context.for_init_head = false;
                            defer self.token_context.for_init_head = saved_for_init_head;
                            try self.emitNode(single_param);
                        }
                    } else {
                        try self.writeChar('(');
                        if (self.checkNodeLeadingLineComment(single_param)) {
                            try self.newline();
                        }
                        const saved_for_init_head = self.token_context.for_init_head;
                        self.token_context.for_init_head = false;
                        defer self.token_context.for_init_head = saved_for_init_head;
                        try self.emitTsParam(single_param);
                        try self.writeChar(')');
                    }
                } else {
                    try self.writeChar('(');
                    // Check if first param has leading line comment
                    if (range_start < range_end and range_start < self.ast.extra_data.items.len) {
                        const first_param: NodeIndex = @enumFromInt(self.ast.extra_data.items[range_start]);
                        if (self.checkNodeLeadingLineComment(first_param)) {
                            try self.newline();
                        }
                    }
                    if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                        const saved_for_init_head = self.token_context.for_init_head;
                        self.token_context.for_init_head = false;
                        defer self.token_context.for_init_head = saved_for_init_head;
                        try self.emitTsParamList(range_start, range_end);
                    }
                    try self.writeChar(')');
                }
                if (has_return_type) {
                    if (self.ast.return_types.get(@intFromEnum(idx))) |rt| {
                        self.token_context.arrow_flow_return_type = true;
                        try self.emitNode(rt);
                        self.token_context.arrow_flow_return_type = false;
                    }
                }
                // Flow: predicate
                if (self.ast.predicate_map.get(@intFromEnum(idx))) |pred| {
                    if (has_return_type) {
                        try self.writeChar(' ');
                    } else {
                        try self.writeStr(": ");
                    }
                    try self.emitNode(pred);
                }
                try self.writeStr(" => ");
                try self.emitArrowBody(idx, body, wrap_for_init_in_body);
            }
        }
    }

    fn emitFunctionExpr(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const name_token_raw = self.ast.extra_data.items[extra_idx];
        const params_start = self.ast.extra_data.items[extra_idx + 1];
        const params_end = self.ast.extra_data.items[extra_idx + 2];
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
        // flags: bit 0=generator, bit 1=async
        const func_flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 4]
        else
            0;
        const is_generator = (func_flags & 1) != 0;
        const is_async = (func_flags & 2) != 0;

        if (is_async) {
            try self.writeStr("async ");
        }
        try self.writeStr("function");
        if (is_generator) {
            try self.writeChar('*');
        }
        // Name
        if (name_token_raw != 0) {
            try self.space();
            const name_start = self.ast.tokens.items(.start)[name_token_raw];
            const name_end = self.ast.tokens.items(.end)[name_token_raw];
            try self.writeStr(self.ast.source[name_start..name_end]);
        } else if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph| {
            try self.space();
            try self.emitNode(ph);
        } else {
            // Emit inner comments between 'function' and '(' (e.g., `function /* c */ ()`)
            try self.emitInnerComments(idx);
            // Also check body's leading comments that are between 'function' and '('
            if (body != .none and self.hasLeadingComments(body)) {
                const func_mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                const func_end = self.ast.tokens.items(.start)[@intFromEnum(func_mt)] + @as(u32, @intCast(self.ast.tokenSlice(func_mt).len));
                // Find '(' position
                var func_paren: u32 = func_end;
                while (func_paren < self.ast.source.len) : (func_paren += 1) {
                    if (self.ast.source[func_paren] == '(') break;
                }
                try self.emitLeadingCommentsBeforePos(body, func_paren);
            }
            // Babel: space before ( when anonymous
            try self.space();
        }
        // TS: type parameters
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        // Params — suppress trailing comments on last param to place them after ')'
        const saved_for_init_head = self.token_context.for_init_head;
        self.token_context.for_init_head = false;
        defer self.token_context.for_init_head = saved_for_init_head;
        try self.writeChar('(');
        if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
            const param_items = self.ast.extra_data.items[params_start..params_end];
            // For the last param, suppress trailing comments
            if (param_items.len > 0) {
                const last_param: NodeIndex = @enumFromInt(param_items[param_items.len - 1]);
                // Emit all params except the last normally
                if (param_items.len > 1) {
                    for (param_items[0 .. param_items.len - 1], 0..) |item, i| {
                        if (i > 0) {
                            try self.writeChar(',');
                            const node_idx2: NodeIndex = @enumFromInt(item);
                            if (self.checkNodeLeadingLineComment(node_idx2)) {
                                try self.newline();
                                try self.writeIndent();
                            } else {
                                try self.space();
                            }
                        }
                        try self.emitTsParam(@enumFromInt(item));
                    }
                    try self.writeChar(',');
                    if (self.checkNodeLeadingLineComment(last_param)) {
                        try self.newline();
                        try self.writeIndent();
                    } else {
                        try self.space();
                    }
                }
                // Emit last param with suppressed trailing comments
                self.suppress_trailing_comments = true;
                try self.emitTsParam(last_param);
                self.suppress_trailing_comments = false;
                try self.writeChar(')');
                // Now emit the suppressed trailing comments.
                // If they include line comments, emit them on new lines.
                if (self.hasTrailingLineComment(last_param)) {
                    try self.emitAllTrailingComments(last_param);
                } else {
                    try self.emitTrailingComments(last_param);
                }
            } else {
                try self.writeChar(')');
            }
        } else {
            try self.writeChar(')');
        }
        // TS/Flow: return type
        {
            const has_rt = self.ast.return_types.contains(@intFromEnum(idx));
            if (has_rt) {
                if (self.ast.return_types.get(@intFromEnum(idx))) |rt| {
                    try self.emitNode(rt);
                }
            }
            // Flow: predicate
            if (self.ast.predicate_map.get(@intFromEnum(idx))) |pred| {
                if (has_rt) {
                    try self.writeChar(' ');
                } else {
                    try self.writeStr(": ");
                }
                try self.emitNode(pred);
            }
        }
        // If trailing comments end with a line comment, emit body on new line
        if (self.endsWithLineComment()) {
            try self.newline();
        } else {
            try self.space();
        }
        try self.emitNode(body);
    }

    fn emitClassExpr(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const name_token_raw = self.ast.extra_data.items[extra_idx];
        const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

        // Decorators
        try self.emitDecorators(idx);

        try self.writeStr("class");
        if (name_token_raw != 0) {
            try self.space();
            const name_start = self.ast.tokens.items(.start)[name_token_raw];
            const name_end = self.ast.tokens.items(.end)[name_token_raw];
            try self.writeStr(self.ast.source[name_start..name_end]);
        } else if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph| {
            try self.space();
            try self.emitNode(ph);
        }
        // TS: type parameters
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        if (super_class != .none) {
            try self.writeStr(" extends ");
            try self.emitNode(super_class);
            // TS: super type arguments
            if (self.ast.super_type_parameters.get(@intFromEnum(idx))) |stp| {
                try self.emitNode(stp);
            }
        }
        // TS: implements clause
        try self.emitImplementsClause(idx);
        try self.space();
        try self.emitNode(body);
    }

    fn emitYieldExpr(self: *Codegen, idx: NodeIndex, data: Node.Data, delegate: bool) Error!void {
        try self.writeStr("yield");
        if (delegate) {
            // For yield*, emit leading comments on the argument that are
            // positioned between 'yield' and '*' in source
            if (data.unary != .none) {
                // Find the '*' position in source (skip comments)
                const yield_end = blk: {
                    const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                    const tok_start = self.ast.tokens.items(.start)[@intFromEnum(mt)];
                    const tok_slice = self.ast.tokenSlice(mt);
                    break :blk tok_start + @as(u32, @intCast(tok_slice.len));
                };
                var star_src_pos: u32 = yield_end;
                while (star_src_pos < self.ast.source.len) : (star_src_pos += 1) {
                    if (star_src_pos + 1 < self.ast.source.len and self.ast.source[star_src_pos] == '/' and self.ast.source[star_src_pos + 1] == '*') {
                        star_src_pos += 2;
                        while (star_src_pos + 1 < self.ast.source.len) : (star_src_pos += 1) {
                            if (self.ast.source[star_src_pos] == '*' and self.ast.source[star_src_pos + 1] == '/') {
                                star_src_pos += 1;
                                break;
                            }
                        }
                        continue;
                    }
                    if (self.ast.source[star_src_pos] == '*') break;
                }
                // Emit leading comments on argument (or its callee) before the '*'
                try self.emitLeadingCommentsBeforePos(data.unary, star_src_pos);
                // Also check the callee of the argument if it's a call expr
                const arg_tag = self.ast.nodes.items(.tag)[@intFromEnum(data.unary)];
                if (arg_tag == .call_expr) {
                    const arg_data2 = self.ast.nodes.items(.data)[@intFromEnum(data.unary)];
                    const arg_extra_idx = @intFromEnum(arg_data2.extra);
                    if (arg_extra_idx < self.ast.extra_data.items.len) {
                        const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[arg_extra_idx]);
                        if (callee != .none) {
                            try self.emitLeadingCommentsBeforePos(callee, star_src_pos);
                        }
                    }
                }
            }
            try self.writeChar('*');
        }
        if (data.unary != .none) {
            try self.space();
            self.child_position = .argument;
            self.clearHeadContext();
            try self.emitNode(data.unary);
        }
    }

    fn emitAwaitExpr(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("await ");
        self.child_position = .argument;
        self.clearHeadContext();
        try self.emitNode(data.unary);
    }

    fn emitSpreadElement(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("...");
        self.child_position = .argument;
        self.clearHeadContext();
        try self.emitNode(data.unary);
    }

    fn emitTaggedTemplateExpr(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const tag_expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const quasi: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        self.child_position = .tag;
        try self.emitNode(tag_expr);
        self.child_position = .none;
        self.clearHeadContext();
        // TS: type arguments on tagged template
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        try self.emitNode(quasi);
    }

    fn emitMetaProperty(self: *Codegen, idx: NodeIndex, main_token: TokenIndex) Error!void {
        _ = idx;
        // main_token is the meta (e.g., "new", "import")
        try self.emitToken(main_token);
        try self.writeChar('.');
        // The property token is the next identifier token after the dot
        // We need to find it: it's main_token + 2 (meta . property)
        const mt_idx = @intFromEnum(main_token);
        // Look at next tokens to find the property
        const tags = self.ast.tokens.items(.tag);
        var tok_idx = mt_idx + 1;
        while (tok_idx < tags.len) : (tok_idx += 1) {
            if (tags[tok_idx] == .dot) continue;
            // Found the property token
            const prop_start = self.ast.tokens.items(.start)[tok_idx];
            const prop_end = self.ast.tokens.items(.end)[tok_idx];
            try self.writeStr(self.ast.source[prop_start..prop_end]);
            break;
        }
    }

    fn emitImportExpr(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        // Check for import phase (source/defer)
        const phase_val = self.ast.ts_class_modifiers.get(@intFromEnum(idx));
        if (phase_val) |pv| {
            if (pv == 0x100) {
                try self.writeStr("import");
                // Emit all comments between `import` and the `(` of `.source(`
                const ie_mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                const ie_import_end = self.ast.tokens.items(.start)[@intFromEnum(ie_mt)] + @as(u32, @intCast(self.ast.tokenSlice(ie_mt).len));
                const source_kw = self.findKeywordAfter(ie_import_end, "source");
                const open_paren = self.findKeywordAfter(source_kw + 6, "(");
                try self.emitAllCommentsBetween(ie_import_end, open_paren);
                try self.writeStr(".source(");
            } else if (pv == 0x200) {
                try self.writeStr("import");
                const ie_mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                const ie_import_end = self.ast.tokens.items(.start)[@intFromEnum(ie_mt)] + @as(u32, @intCast(self.ast.tokenSlice(ie_mt).len));
                const defer_kw = self.findKeywordAfter(ie_import_end, "defer");
                const open_paren2 = self.findKeywordAfter(defer_kw + 5, "(");
                try self.emitAllCommentsBetween(ie_import_end, open_paren2);
                try self.writeStr(".defer(");
            } else {
                try self.writeStr("import");
                // Emit leading comments on first arg that are positioned
                // between `import` keyword and `(` in source
                try self.emitPreParenLeadingComments(idx, data.binary.lhs);
                try self.writeChar('(');
            }
        } else {
            try self.writeStr("import");
            try self.emitPreParenLeadingComments(idx, data.binary.lhs);
            try self.writeChar('(');
        }
        // Arguments are inside parens, so objects don't need extra wrapping
        self.clearHeadContext();
        if (data.binary.lhs != .none) {
            try self.emitNode(data.binary.lhs);
            if (data.binary.rhs != .none) {
                try self.writeStr(", ");
                try self.emitNode(data.binary.rhs);
            }
        }
        try self.writeChar(')');
    }

    fn emitObjectExpr(self: *Codegen, data: Node.Data) Error!void {
        const saved_for_init_head = self.token_context.for_init_head;
        self.token_context.for_init_head = false;
        defer self.token_context.for_init_head = saved_for_init_head;
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            if (range_start >= range_end) {
                try self.writeStr("{}");
                return;
            }
            try self.writeStr("{\n");
            self.indent();
            const items = self.ast.extra_data.items[range_start..range_end];
            var prev_end: u32 = 0; // Will be set properly
            for (items, 0..) |item, j| {
                const node_idx: NodeIndex = @enumFromInt(item);
                // Object properties don't preserve blank lines between them
                try self.emitStatementLeadingCommentsNoBlank(node_idx, prev_end);
                if (!self.leading_comment_was_inline) {
                    try self.writeIndent();
                }
                try self.emitNode(node_idx);
                if (j < items.len - 1) {
                    // If property ends with a line comment, put comma on new line
                    if (self.endsWithLineComment()) {
                        try self.newline();
                        try self.writeIndent();
                        try self.writeChar(',');
                    } else {
                        try self.writeChar(',');
                    }
                }
                try self.newline();
                prev_end = self.ast.nodes.items(.end_offset)[item];
            }
            self.dedent();
            try self.writeIndent();
            try self.writeChar('}');
        } else {
            try self.writeStr("{}");
        }
    }

    fn emitArrayExpr(self: *Codegen, data: Node.Data) Error!void {
        const saved_for_init_head = self.token_context.for_init_head;
        self.token_context.for_init_head = false;
        defer self.token_context.for_init_head = saved_for_init_head;
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            try self.writeChar('[');
            if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                // Array elements need special handling for elisions (holes)
                const items = self.ast.extra_data.items[range_start..range_end];
                const tags = self.ast.nodes.items(.tag);
                for (items, 0..) |item, j| {
                    const is_hole = item >= tags.len or tags[item] == .removed or tags[item] == .empty_statement;
                    if (j > 0) {
                        try self.writeChar(',');
                        if (!is_hole) {
                            try self.space();
                        }
                    }
                    if (!is_hole) {
                        try self.emitNode(@enumFromInt(item));
                    }
                }
                if (items.len > 0) {
                    const last = items[items.len - 1];
                    const last_is_hole = last >= tags.len or tags[last] == .removed or tags[last] == .empty_statement;
                    if (last_is_hole) {
                        try self.writeChar(',');
                    }
                }
            }
            // If elements end with a line comment, put ']' on new line
            if (self.endsWithLineComment()) {
                try self.newline();
                try self.writeIndent();
            }
            try self.writeChar(']');
        } else {
            try self.writeStr("[]");
        }
    }

    fn emitRegexLiteral(self: *Codegen, idx: NodeIndex, main_token: TokenIndex) Error!void {
        // Regex tokens store only the opening slash; the full regex text
        // (including pattern, closing slash, and flags) extends to the node's end_offset.
        self.addMapping(main_token);
        const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
        const end = self.ast.nodes.items(.end_offset)[@intFromEnum(idx)];
        try self.writeStr(self.ast.source[start..end]);
    }

    fn emitTemplateLiteral(self: *Codegen, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) Error!void {
        _ = idx;
        const mt_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
        if (mt_tag == .template_no_sub) {
            // No substitutions - just emit the full template token
            try self.emitToken(main_token);
        } else {
            // Has substitutions - data.extra layout:
            // [num_expressions, expr1, expr2, ..., head_tok, mid_tok1, ..., tail_tok]
            const extra_idx = @intFromEnum(data.extra);
            const num_expressions = self.ast.extra_data.items[extra_idx];
            const exprs_start = extra_idx + 1;
            const tokens_start = exprs_start + num_expressions;

            // Emit head token
            const head_tok: TokenIndex = @enumFromInt(self.ast.extra_data.items[tokens_start]);
            try self.emitToken(head_tok);

            // Interleave expressions and middle/tail tokens
            for (0..num_expressions) |j| {
                const expr_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[exprs_start + j]);
                try self.emitNode(expr_node);
                const next_tok: TokenIndex = @enumFromInt(self.ast.extra_data.items[tokens_start + j + 1]);
                try self.emitToken(next_tok);
            }
        }
    }

    fn emitPrivateName(self: *Codegen, data: Node.Data) Error!void {
        try self.writeChar('#');
        try self.emitNode(data.unary);
    }

    fn emitV8Intrinsic(self: *Codegen, idx: NodeIndex) Error!void {
        const i = @intFromEnum(idx);
        const main_token = self.ast.nodes.items(.main_token)[i];
        const end_offset = self.ast.nodes.items(.end_offset)[i];
        // main_token is the '%' token, emit from '%' start to end_offset (which includes the identifier)
        self.addMapping(main_token);
        const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
        try self.writeStr(self.ast.source[start..end_offset]);
    }

    // ---------------------------------------------------------------
    // Object/Array internals
    // ---------------------------------------------------------------

    fn emitProperty(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        _ = idx;
        if (self.es3_property_literals and shouldQuoteEs3ObjectKey(self.ast, data.binary.lhs)) {
            const key = self.ast.tokenSlice(self.ast.nodes.items(.main_token)[@intFromEnum(data.binary.lhs)]);
            try self.writeChar('"');
            try self.writeStr(key);
            try self.writeChar('"');
        } else {
            try self.emitNode(data.binary.lhs);
        }
        try self.writeStr(": ");
        try self.emitNode(data.binary.rhs);
    }

    fn shouldQuoteEs3ObjectKey(ast: *const Ast, key_node: NodeIndex) bool {
        if (key_node == .none or ast.nodes.items(.tag)[@intFromEnum(key_node)] != .identifier) return false;
        const key = ast.tokenSlice(ast.nodes.items(.main_token)[@intFromEnum(key_node)]);
        return isEs3ReservedWord(key);
    }

    fn isEs3ReservedWord(name: []const u8) bool {
        return std.mem.eql(u8, name, "abstract") or
            std.mem.eql(u8, name, "boolean") or
            std.mem.eql(u8, name, "break") or
            std.mem.eql(u8, name, "byte") or
            std.mem.eql(u8, name, "case") or
            std.mem.eql(u8, name, "catch") or
            std.mem.eql(u8, name, "char") or
            std.mem.eql(u8, name, "class") or
            std.mem.eql(u8, name, "const") or
            std.mem.eql(u8, name, "continue") or
            std.mem.eql(u8, name, "debugger") or
            std.mem.eql(u8, name, "default") or
            std.mem.eql(u8, name, "delete") or
            std.mem.eql(u8, name, "do") or
            std.mem.eql(u8, name, "double") or
            std.mem.eql(u8, name, "else") or
            std.mem.eql(u8, name, "enum") or
            std.mem.eql(u8, name, "export") or
            std.mem.eql(u8, name, "extends") or
            std.mem.eql(u8, name, "final") or
            std.mem.eql(u8, name, "finally") or
            std.mem.eql(u8, name, "float") or
            std.mem.eql(u8, name, "for") or
            std.mem.eql(u8, name, "function") or
            std.mem.eql(u8, name, "goto") or
            std.mem.eql(u8, name, "if") or
            std.mem.eql(u8, name, "implements") or
            std.mem.eql(u8, name, "import") or
            std.mem.eql(u8, name, "in") or
            std.mem.eql(u8, name, "instanceof") or
            std.mem.eql(u8, name, "int") or
            std.mem.eql(u8, name, "interface") or
            std.mem.eql(u8, name, "long") or
            std.mem.eql(u8, name, "native") or
            std.mem.eql(u8, name, "new") or
            std.mem.eql(u8, name, "package") or
            std.mem.eql(u8, name, "private") or
            std.mem.eql(u8, name, "protected") or
            std.mem.eql(u8, name, "public") or
            std.mem.eql(u8, name, "return") or
            std.mem.eql(u8, name, "short") or
            std.mem.eql(u8, name, "static") or
            std.mem.eql(u8, name, "super") or
            std.mem.eql(u8, name, "switch") or
            std.mem.eql(u8, name, "synchronized") or
            std.mem.eql(u8, name, "this") or
            std.mem.eql(u8, name, "throw") or
            std.mem.eql(u8, name, "throws") or
            std.mem.eql(u8, name, "transient") or
            std.mem.eql(u8, name, "try") or
            std.mem.eql(u8, name, "typeof") or
            std.mem.eql(u8, name, "var") or
            std.mem.eql(u8, name, "void") or
            std.mem.eql(u8, name, "volatile") or
            std.mem.eql(u8, name, "while") or
            std.mem.eql(u8, name, "with");
    }

    fn emitShorthandProperty(self: *Codegen, data: Node.Data) Error!void {
        try self.emitNode(data.unary);
    }

    fn emitComputedProperty(self: *Codegen, data: Node.Data) Error!void {
        try self.writeChar('[');
        // If the key has a leading line comment or multiline block comment,
        // put it on a new line inside the brackets (like Babel does).
        if (self.hasLeadingLineComment(data.binary.lhs) or self.hasLeadingMultiLineBlockComment(data.binary.lhs)) {
            try self.newline();
            try self.writeIndent();
        }
        try self.emitNode(data.binary.lhs);

        // Emit leading comments on the value that are inside `[...]`
        // (positioned before the `]` in source)
        const buf_before_bracket_comments = self.buf.items.len;
        if (data.binary.rhs != .none) {
            const key_end = self.nodeSourceEnd(data.binary.lhs);
            // Find ']' position after key
            var bracket_pos3: u32 = key_end;
            while (bracket_pos3 < self.ast.source.len) : (bracket_pos3 += 1) {
                if (bracket_pos3 + 1 < self.ast.source.len and
                    self.ast.source[bracket_pos3] == '/' and self.ast.source[bracket_pos3 + 1] == '*')
                {
                    bracket_pos3 += 2;
                    while (bracket_pos3 + 1 < self.ast.source.len) : (bracket_pos3 += 1) {
                        if (self.ast.source[bracket_pos3] == '*' and self.ast.source[bracket_pos3 + 1] == '/') {
                            bracket_pos3 += 1;
                            break;
                        }
                    }
                    continue;
                }
                if (self.ast.source[bracket_pos3] == ']') break;
            }
            // Emit leading comments, putting multi-line ones on new lines
            {
                const key2 = @intFromEnum(data.binary.rhs);
                const lc_range = self.ast.leading_comments.get(key2) orelse CommentRange{ .start = 0, .end = 0 };
                if (lc_range.start < lc_range.end) {
                    const lc_comments = self.ast.comments.items;
                    var li = lc_range.start;
                    while (li < lc_range.end and li < lc_comments.len) : (li += 1) {
                        if (self.emitted_comments.isSet(li)) continue;
                        const lc = lc_comments[li];
                        if (lc.end <= bracket_pos3) {
                            self.emitted_comments.set(li);
                            if (lc.kind == .line or self.isMultiLineBlock(lc)) {
                                try self.newline();
                                try self.writeIndent();
                                try self.emitCommentText(lc);
                            } else {
                                if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] != ' ') {
                                    try self.space();
                                }
                                try self.emitCommentText(lc);
                            }
                        }
                    }
                }
            }
        }
        _ = buf_before_bracket_comments;

        // If the key or bracket comments end with a line comment,
        // put the closing bracket on a new line with indent.
        // Multi-line block comments don't need a newline before ']'.
        if (self.endsWithLineComment()) {
            try self.newline();
            try self.writeIndent();
        }
        try self.writeStr("]: ");
        try self.emitNode(data.binary.rhs);
    }

    fn emitComputedMethod(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const params_start = self.ast.extra_data.items[extra_idx + 1];
        const params_end = self.ast.extra_data.items[extra_idx + 2];
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
        const cm_flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 4]
        else
            0;
        const is_generator = (cm_flags & 1) != 0;
        const is_async = (cm_flags & 2) != 0;

        if (is_async) {
            try self.writeStr("async ");
        }
        if (is_generator) {
            try self.writeChar('*');
        }
        try self.writeChar('[');
        try self.emitNode(key);
        try self.writeChar(']');
        // TS/Flow: type parameters
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        try self.writeChar('(');
        if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
            try self.emitTsParamList(params_start, params_end);
        }
        try self.writeChar(')');
        // TS/Flow: return type
        if (self.ast.return_types.get(@intFromEnum(idx))) |rt| {
            try self.emitNode(rt);
        }
        try self.writeStr(" ");
        try self.emitNode(body);
    }

    fn emitMethodDefinition(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const params_start = self.ast.extra_data.items[extra_idx + 1];
        const params_end = self.ast.extra_data.items[extra_idx + 2];
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
        const method_flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 4]
        else
            0;
        const is_generator = (method_flags & 1) != 0;
        const is_async = (method_flags & 2) != 0;

        if (is_async) {
            try self.writeStr("async ");
        }
        if (is_generator) {
            try self.writeChar('*');
        }
        try self.emitNode(key);
        // TS/Flow: type parameters
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        try self.writeChar('(');
        if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
            try self.emitTsParamList(params_start, params_end);
        }
        try self.writeChar(')');
        // TS/Flow: return type
        if (self.ast.return_types.get(@intFromEnum(idx))) |rt| {
            try self.emitNode(rt);
        }
        try self.writeStr(" ");
        try self.emitNode(body);
    }

    fn emitGetterSetter(self: *Codegen, idx: NodeIndex, data: Node.Data, kind: []const u8) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const gs_flags = if (extra_idx + 3 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 3]
        else
            0;
        const is_static = (gs_flags & 1) != 0;
        const is_computed = (gs_flags & 8) != 0;

        // Decorators
        try self.emitDecorators(idx);

        // TS: modifiers (accessibility, abstract, override)
        const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
        if (mods & 1 != 0) try self.writeStr("public ") // TS_MOD_PUBLIC
        else if (mods & 2 != 0) try self.writeStr("private ") // TS_MOD_PRIVATE
        else if (mods & 4 != 0) try self.writeStr("protected "); // TS_MOD_PROTECTED

        if (is_static) {
            try self.writeStr("static ");
        }
        if (mods & 16 != 0) try self.writeStr("abstract "); // TS_MOD_ABSTRACT
        if (mods & 64 != 0) try self.writeStr("override "); // TS_MOD_OVERRIDE

        try self.writeStr(kind);
        try self.space();

        // getter/setter: extra has [params_start, params_end, body, flags, computed_key]
        const gs_params_start = self.ast.extra_data.items[extra_idx];
        const gs_params_end = self.ast.extra_data.items[extra_idx + 1];
        const gs_body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

        if (is_computed) {
            const computed_key_node: NodeIndex = if (extra_idx + 4 < self.ast.extra_data.items.len)
                @enumFromInt(self.ast.extra_data.items[extra_idx + 4])
            else
                .none;
            try self.writeChar('[');
            if (computed_key_node != .none) {
                try self.emitNode(computed_key_node);
            }
            try self.writeChar(']');
        } else {
            // Key from main_token
            const gs_main = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            const key_start = self.ast.tokens.items(.start)[@intFromEnum(gs_main)];
            const key_end = self.ast.tokens.items(.end)[@intFromEnum(gs_main)];
            const is_private = (gs_flags & 4) != 0;
            if (is_private) {
                try self.writeChar('#');
            }
            try self.writeStr(self.ast.source[key_start..key_end]);
        }

        // TS: type parameters
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        try self.writeChar('(');
        if (gs_params_start <= gs_params_end and gs_params_end <= self.ast.extra_data.items.len) {
            try self.emitTsParamList(gs_params_start, gs_params_end);
        }
        try self.writeChar(')');
        // TS: return type
        if (self.ast.return_types.get(@intFromEnum(idx))) |rt| {
            try self.emitNode(rt);
        }
        if (gs_body != .none) {
            try self.space();
            try self.emitNode(gs_body);
        } else {
            try self.semicolon();
        }
    }

    // ---------------------------------------------------------------
    // Patterns
    // ---------------------------------------------------------------

    fn emitArrayPattern(self: *Codegen, data: Node.Data) Error!void {
        try self.writeChar('[');
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                try self.emitCommaSeparated(range_start, range_end);
            }
        }
        try self.writeChar(']');
    }

    fn emitObjectPattern(self: *Codegen, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            if (range_start >= range_end) {
                try self.writeStr("{}");
                return;
            }
            try self.writeStr("{\n");
            self.indent();
            const items = self.ast.extra_data.items[range_start..range_end];
            for (items, 0..) |item, j| {
                try self.writeIndent();
                try self.emitNode(@enumFromInt(item));
                if (j < items.len - 1) {
                    try self.writeChar(',');
                }
                try self.newline();
            }
            self.dedent();
            try self.writeIndent();
            try self.writeChar('}');
        } else {
            try self.writeStr("{}");
        }
    }

    fn emitAssignmentPattern(self: *Codegen, data: Node.Data) Error!void {
        self.child_position = .left;
        try self.emitNode(data.binary.lhs);
        try self.writeStr(" = ");
        self.child_position = .right;
        self.clearHeadContext();
        try self.emitNode(data.binary.rhs);
    }

    fn emitRestElement(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("...");
        try self.emitNode(data.unary);
    }

    // ---------------------------------------------------------------
    // Declarations
    // ---------------------------------------------------------------

    fn emitVarDeclaration(self: *Codegen, data: Node.Data, keyword: []const u8) Error!void {
        try self.writeStr(keyword);
        try self.space();
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                const items = self.ast.extra_data.items[range_start..range_end];
                if (items.len <= 1) {
                    // Single declarator - inline
                    try self.emitCommaSeparated(range_start, range_end);
                } else {
                    // Check if any declarator has an initializer
                    const datas = self.ast.nodes.items(.data);
                    var has_init = false;
                    for (items) |item| {
                        const decl_data = datas[item];
                        if (decl_data.binary.rhs != .none) {
                            has_init = true;
                            break;
                        }
                    }
                    if (has_init) {
                        // Multiple declarators with inits - each on its own line with indent
                        self.indent();
                        // If first declarator has leading line comments or multi-line block comments,
                        // put on a new line (block comments that fit inline stay on same line)
                        const first_decl: NodeIndex = @enumFromInt(items[0]);
                        const first_decl_lhs = self.ast.nodes.items(.data)[@intFromEnum(first_decl)].binary.lhs;
                        if (self.hasLeadingLineOrMultilineComment(first_decl) or
                            (first_decl_lhs != .none and self.hasLeadingLineOrMultilineComment(first_decl_lhs)))
                        {
                            // Remove the trailing space after keyword (from `var `)
                            if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] == ' ') {
                                _ = self.buf.pop();
                                self.current_col -= 1;
                            }
                            try self.newline();
                            try self.writeIndent();
                        }
                        for (items, 0..) |item, j| {
                            if (j > 0) {
                                try self.writeChar(',');
                                try self.newline();
                                try self.writeIndent();
                            }
                            try self.emitNode(@enumFromInt(item));
                        }
                        self.dedent();
                    } else {
                        // Multiple declarators without inits - inline
                        try self.emitCommaSeparated(range_start, range_end);
                    }
                }
            }
        }
        try self.emitSemicolonAfterTrailingComment();
    }

    /// Emit `await using` declaration with inter-keyword comments.
    /// Comments between `await` and `using` are emitted between the keywords.
    fn emitAwaitUsingDeclaration(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        // Find 'using' keyword position in source (next token after main_token 'await')
        const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
        const await_end = self.ast.tokens.items(.start)[@intFromEnum(mt)] + @as(u32, @intCast(self.ast.tokenSlice(mt).len));
        // Scan to find 'using' keyword position
        var using_pos: u32 = await_end;
        while (using_pos + 5 <= self.ast.source.len) : (using_pos += 1) {
            if (std.mem.eql(u8, self.ast.source[using_pos .. using_pos + 5], "using")) break;
        }

        try self.writeStr("await");
        // Emit comments between 'await' and 'using'
        try self.emitLeadingCommentsBetweenPositions(idx, data, await_end, using_pos);
        try self.writeStr(" using ");
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                const items = self.ast.extra_data.items[range_start..range_end];
                if (items.len <= 1) {
                    try self.emitCommaSeparated(range_start, range_end);
                } else {
                    const datas = self.ast.nodes.items(.data);
                    var has_init = false;
                    for (items) |item| {
                        const decl_data = datas[item];
                        if (decl_data.binary.rhs != .none) {
                            has_init = true;
                            break;
                        }
                    }
                    if (has_init) {
                        self.indent();
                        const first_decl: NodeIndex = @enumFromInt(items[0]);
                        const first_decl_lhs = self.ast.nodes.items(.data)[@intFromEnum(first_decl)].binary.lhs;
                        if (self.hasLeadingLineOrMultilineComment(first_decl) or
                            (first_decl_lhs != .none and self.hasLeadingLineOrMultilineComment(first_decl_lhs)))
                        {
                            if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] == ' ') {
                                _ = self.buf.pop();
                                self.current_col -= 1;
                            }
                            try self.newline();
                            try self.writeIndent();
                        }
                        for (items, 0..) |item, j| {
                            if (j > 0) {
                                try self.writeChar(',');
                                try self.newline();
                                try self.writeIndent();
                            }
                            try self.emitNode(@enumFromInt(item));
                        }
                        self.dedent();
                    } else {
                        try self.emitCommaSeparated(range_start, range_end);
                    }
                }
            }
        }
        try self.emitSemicolonAfterTrailingComment();
    }

    /// Emit `await using` for-init without trailing semicolon, with inter-keyword comments.
    fn emitForAwaitUsingDeclaration(self: *Codegen, node_idx: NodeIndex) Error!void {
        // Emit leading comments (not called through emitNode)
        try self.emitExprLeadingComments(node_idx);
        const i = @intFromEnum(node_idx);
        const data = self.ast.nodes.items(.data)[i];
        const mt = self.ast.nodes.items(.main_token)[i];
        const await_end = self.ast.tokens.items(.start)[@intFromEnum(mt)] + @as(u32, @intCast(self.ast.tokenSlice(mt).len));
        var using_pos: u32 = await_end;
        while (using_pos + 5 <= self.ast.source.len) : (using_pos += 1) {
            if (std.mem.eql(u8, self.ast.source[using_pos .. using_pos + 5], "using")) break;
        }

        try self.writeStr("await");
        try self.emitLeadingCommentsBetweenPositions(node_idx, data, await_end, using_pos);
        try self.writeStr(" using ");
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                try self.emitCommaSeparated(range_start, range_end);
            }
        }
    }

    /// Emit leading comments on descendant nodes that fall between two source positions.
    /// Used for inter-keyword comments in multi-word keywords like `await using`.
    fn emitLeadingCommentsBetweenPositions(self: *Codegen, parent_idx: NodeIndex, parent_data: Node.Data, after_pos: u32, before_pos: u32) Error!void {
        _ = parent_data;
        // First check inner comments on the parent node itself
        if (self.ast.inner_comments.get(@intFromEnum(parent_idx))) |range| {
            const comments = self.ast.comments.items;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                if (self.emitted_comments.isSet(i)) continue;
                const comment = comments[i];
                if (comment.start >= after_pos and comment.end <= before_pos) {
                    self.emitted_comments.set(i);
                    try self.space();
                    try self.emitCommentText(comment);
                }
            }
        }
        // Then check leading comments on all descendant nodes
        var it = self.ast.leading_comments.iterator();
        while (it.next()) |entry| {
            const range = entry.value_ptr.*;
            const comments = self.ast.comments.items;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                if (self.emitted_comments.isSet(i)) continue;
                const comment = comments[i];
                if (comment.start >= after_pos and comment.end <= before_pos) {
                    self.emitted_comments.set(i);
                    try self.space();
                    try self.emitCommentText(comment);
                }
            }
        }
    }

    fn emitDeclarator(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        try self.emitNode(data.binary.lhs);
        // TS: definite assignment assertion (!) - stored on declarator
        const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx));
        if (mods != null) {
            try self.writeChar('!');
        }
        // TS: type annotation from side table (stored on the binding/identifier node)
        if (data.binary.lhs != .none) {
            if (self.ast.type_annotations.get(@intFromEnum(data.binary.lhs))) |ta| {
                try self.emitNode(ta);
            }
        }
        if (data.binary.rhs != .none) {
            try self.writeStr(" = ");
            try self.emitNode(data.binary.rhs);
        }
    }

    fn emitFunctionDeclaration(self: *Codegen, idx: NodeIndex, tag: Node.Tag, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const name_token_raw = self.ast.extra_data.items[extra_idx];
        const params_start = self.ast.extra_data.items[extra_idx + 1];
        const params_end = self.ast.extra_data.items[extra_idx + 2];
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);

        // Decorators
        try self.emitDecorators(idx);

        const is_async = tag == .async_function_declaration or tag == .async_generator_declaration;
        const is_generator = tag == .generator_declaration or tag == .async_generator_declaration;

        if (is_async) {
            try self.writeStr("async ");
        }
        try self.writeStr("function");
        if (is_generator) {
            try self.writeChar('*');
        }
        // Name
        if (name_token_raw != 0) {
            try self.space();
            const name_start = self.ast.tokens.items(.start)[name_token_raw];
            const name_end = self.ast.tokens.items(.end)[name_token_raw];
            try self.writeStr(self.ast.source[name_start..name_end]);
        } else if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph| {
            try self.space();
            try self.emitNode(ph);
        } else {
            // Babel: space before ( when anonymous (e.g. export default function () {})
            try self.space();
        }
        // TS: type parameters
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        // Params
        const saved_for_init_head = self.token_context.for_init_head;
        self.token_context.for_init_head = false;
        defer self.token_context.for_init_head = saved_for_init_head;
        try self.writeChar('(');
        if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
            try self.emitTsParamList(params_start, params_end);
        }
        // If params end with a line comment, put ')' on a new line
        if (self.endsWithLineComment()) {
            try self.newline();
        }
        try self.writeChar(')');
        // TS/Flow: return type
        const has_return_type = self.ast.return_types.contains(@intFromEnum(idx));
        if (has_return_type) {
            if (self.ast.return_types.get(@intFromEnum(idx))) |rt| {
                try self.emitNode(rt);
            }
        }
        // Flow: predicate (%checks / %checks(expr))
        if (self.ast.predicate_map.get(@intFromEnum(idx))) |pred| {
            if (has_return_type) {
                try self.writeChar(' ');
            } else {
                try self.writeStr(": ");
            }
            try self.emitNode(pred);
        }
        try self.space();
        try self.emitNode(body);
    }

    fn emitClassDeclaration(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const name_token_raw = self.ast.extra_data.items[extra_idx];
        const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

        // Decorators
        try self.emitDecorators(idx);

        // TS: class modifiers (declare, abstract)
        try self.emitClassModifierKeywords(idx);

        try self.writeStr("class");
        if (name_token_raw != 0) {
            // Emit body leading comments that are between 'class' keyword and name
            const class_mt_cd = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            const class_tok_start_cd = self.ast.tokens.items(.start)[@intFromEnum(class_mt_cd)];
            const class_kw_end_cd = class_tok_start_cd + @as(u32, @intCast(self.ast.tokenSlice(class_mt_cd).len));
            const name_start = self.ast.tokens.items(.start)[name_token_raw];
            const name_end = self.ast.tokens.items(.end)[name_token_raw];
            const had_comment = self.emitLeadingCommentsInRangeCheck(body, class_kw_end_cd, name_start);
            if (!had_comment) try self.space();
            try self.writeStr(self.ast.source[name_start..name_end]);
        } else if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph| {
            try self.space();
            try self.emitNode(ph);
        }
        // TS: type parameters
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        if (super_class != .none) {
            try self.writeStr(" extends ");
            try self.emitNode(super_class);
            // TS: super type arguments
            if (self.ast.super_type_parameters.get(@intFromEnum(idx))) |stp| {
                try self.emitNode(stp);
            }
        }
        // TS: implements clause
        try self.emitImplementsClause(idx);
        // Emit remaining body leading comments between name/extends/implements and '{'
        if (body != .none and name_token_raw != 0) {
            const body_src_start = self.nodeSourceStart(body);
            const after_pos = if (super_class != .none) self.nodeSourceEnd(super_class) else self.ast.tokens.items(.end)[name_token_raw];
            _ = self.emitLeadingCommentsInRangeCheck(body, after_pos, body_src_start);
        }
        try self.space();
        try self.emitNode(body);
    }

    // ---------------------------------------------------------------
    // Class internals
    // ---------------------------------------------------------------

    fn emitClassBody(self: *Codegen, body_idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            // Check if body is empty (or all items removed by transforms)
            const is_empty = blk_empty: {
                if (range_start >= range_end) break :blk_empty true;
                const pre_tags = self.ast.nodes.items(.tag);
                for (self.ast.extra_data.items[range_start..range_end]) |item| {
                    if (pre_tags[item] != .removed) break :blk_empty false;
                }
                break :blk_empty true;
            };
            if (is_empty) {
                // Empty class body — check for inner comments
                if (self.hasLineInnerComments(body_idx) or self.hasMultipleInnerComments(body_idx)) {
                    try self.writeStr("{\n");
                    self.indent();
                    try self.emitBlockInnerComments(body_idx, self.nodeSourceStart(body_idx));
                    self.dedent();
                    try self.writeIndent();
                    try self.writeChar('}');
                } else {
                    try self.writeChar('{');
                    try self.emitInnerComments(body_idx);
                    try self.writeChar('}');
                }
                return;
            }
            try self.writeStr("{\n");
            self.indent();
            const items = self.ast.extra_data.items[range_start..range_end];
            const tags_cls = self.ast.nodes.items(.tag);
            var prev_end: u32 = self.nodeSourceStart(body_idx);
            var prev_had_trailing_cls = false;
            var first_cls_member = true;
            for (items) |item| {
                if (tags_cls[item] == .removed) continue; // Skip removed nodes
                const node_idx: NodeIndex = @enumFromInt(item);
                if (first_cls_member) {
                    try self.emitStatementLeadingCommentsNoBlank(node_idx, prev_end);
                    first_cls_member = false;
                } else {
                    try self.emitStatementLeadingCommentsImplEx(node_idx, prev_end, true, prev_had_trailing_cls);
                }
                if (!self.leading_comment_was_inline) {
                    try self.writeIndent();
                }
                try self.emitNode(node_idx);
                try self.emitRemainingStatementComments(node_idx);
                try self.newline();
                prev_had_trailing_cls = self.statementHasDirectTrailingComments(node_idx);
                prev_end = self.getStatementEndWithTrailingComments(node_idx);
            }
            // Emit inner comments at end of class body (e.g., trailing comments
            // after the last member that weren't attached to any member).
            try self.emitBlockInnerComments(body_idx, prev_end);
            self.dedent();
            try self.writeIndent();
            try self.writeChar('}');
        } else {
            try self.writeChar('{');
            try self.emitInnerComments(body_idx);
            try self.writeChar('}');
        }
    }

    fn emitClassField(self: *Codegen, idx: NodeIndex, tag: Node.Tag, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const value: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const flags = if (extra_idx + 2 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 2]
        else
            0;
        const is_static = (flags & 1) != 0;
        const is_computed = (flags & 2) != 0;
        const is_accessor = (flags & 64) != 0;
        // In Flow, bit 16 means `declare`; in TS, bit 16 means `optional`
        const is_flow_declare = self.ast.language == .flow and (flags & 16) != 0;
        const is_optional = if (self.ast.language == .flow) false else (flags & 16) != 0;
        const is_definite = (flags & 32) != 0;

        // Decorators
        try self.emitDecorators(idx);

        // TS: class member modifiers (declare, accessibility, static handled below, abstract, override, readonly)
        const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
        const is_private_field = tag == .class_private_field;
        const is_public_field = tag == .class_field;

        // declare (Flow: from flags bit 16; TS: from ts_class_modifiers)
        if (is_flow_declare) {
            try self.writeStr("declare ");
        } else if (is_public_field and (mods & 32) != 0) { // TS_MOD_DECLARE
            try self.writeStr("declare ");
        }
        // accessibility (not for private fields)
        if (!is_private_field) {
            if (mods & 1 != 0) try self.writeStr("public ") // TS_MOD_PUBLIC
            else if (mods & 2 != 0) try self.writeStr("private ") // TS_MOD_PRIVATE
            else if (mods & 4 != 0) try self.writeStr("protected "); // TS_MOD_PROTECTED
        }

        if (is_static) {
            try self.writeStr("static ");
        }
        // abstract (not for private fields)
        if (!is_private_field and (mods & 16) != 0) { // TS_MOD_ABSTRACT
            try self.writeStr("abstract ");
        }
        // override (not for private fields)
        if (!is_private_field and (mods & 64) != 0) { // TS_MOD_OVERRIDE
            try self.writeStr("override ");
        }
        // readonly
        if ((mods & 8) != 0) { // TS_MOD_READONLY
            try self.writeStr("readonly ");
        }

        if (is_accessor) {
            try self.writeStr("accessor");
            if (is_computed) {
                // Emit comments between 'accessor' and '[' (e.g., `accessor /* 7 */ [...]`)
                const field_mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                const field_mt_start = self.ast.tokens.items(.start)[@intFromEnum(field_mt)];
                const accessor_end_pos = field_mt_start + 8; // "accessor".len
                // Find '[' position after accessor
                const bracket_pos = self.findCharInSource(accessor_end_pos, '[');
                try self.emitAllCommentsBetween(accessor_end_pos, bracket_pos);
                try self.writeStr(" [");
            } else {
                try self.writeStr(" ");
            }
        } else {
            if (is_computed) {
                try self.writeChar('[');
            }
        }
        // Flow: variance annotation
        if (self.ast.variance_map.get(@intFromEnum(idx))) |var_node| {
            try self.emitNode(var_node);
        }
        if (is_private_field) {
            try self.writeChar('#');
        }
        // For accessor with computed key: limit trailing comments on key to before ']'
        var accessor_close_bracket: u32 = 0;
        if (is_accessor and is_computed) {
            const key_end_pos2 = self.nodeSourceEnd(key);
            var cb: u32 = key_end_pos2;
            while (cb < self.ast.source.len) : (cb += 1) {
                // Skip block comments when looking for ']'
                if (cb + 1 < self.ast.source.len and self.ast.source[cb] == '/' and self.ast.source[cb + 1] == '*') {
                    cb += 2;
                    while (cb + 1 < self.ast.source.len) : (cb += 1) {
                        if (self.ast.source[cb] == '*' and self.ast.source[cb + 1] == '/') {
                            cb += 1;
                            break;
                        }
                    }
                    continue;
                }
                if (self.ast.source[cb] == ']') break;
            }
            accessor_close_bracket = cb;
            self.trailing_comment_source_limit = cb;
        }
        try self.emitNode(key);
        if (is_accessor and is_computed) {
            self.trailing_comment_source_limit = 0;
        }
        if (is_computed) {
            try self.writeChar(']');
            // For accessor with computed key: emit multi-line comments between ']' and '='
            // on a new indented line
            if (is_accessor and value != .none and accessor_close_bracket > 0) {
                // Find '=' after ']'
                const eq_pos = self.findCharInSource(accessor_close_bracket + 1, '=');
                // Check if there are multi-line comments between ']' and '='
                if (self.hasMultiLineCommentsBetween(accessor_close_bracket + 1, eq_pos)) {
                    try self.newline();
                    self.indent();
                    try self.writeIndent();
                    // Emit comments without adding leading space (indent already written)
                    const comments = self.ast.comments.items;
                    for (comments, 0..) |comment, ci| {
                        if (self.emitted_comments.isSet(ci)) continue;
                        if (comment.start >= accessor_close_bracket + 1 and comment.end <= eq_pos) {
                            self.emitted_comments.set(ci);
                            try self.emitCommentText(comment);
                        }
                    }
                    self.dedent();
                }
            }
        }
        // TS: optional
        if (is_optional) {
            try self.writeChar('?');
        }
        // TS: definite assignment assertion
        if (is_definite) {
            try self.writeChar('!');
        }
        // TS: type annotation
        if (self.ast.type_annotations.get(@intFromEnum(idx))) |ta| {
            try self.emitNode(ta);
        }
        if (value != .none) {
            try self.writeStr(" = ");
            try self.emitNode(value);
        }
        try self.semicolon();
    }

    fn emitStaticBlock(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("static ");
        try self.emitNode(data.unary);
    }

    fn emitClassMethod(self: *Codegen, idx: NodeIndex, tag: Node.Tag, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const params_start = self.ast.extra_data.items[extra_idx + 1];
        const params_end = self.ast.extra_data.items[extra_idx + 2];
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
        // flags: bit 0=static, bit 1=computed, bit 2=generator, bit 3=async
        const flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 4]
        else
            0;
        const is_static = (flags & 1) != 0;
        const is_computed = (flags & 2) != 0;
        const is_generator = (flags & 4) != 0;
        const is_async = (flags & 8) != 0;
        const is_optional = (flags & 16) != 0;

        // Decorators
        try self.emitDecorators(idx);

        // TS: class method modifiers
        const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
        const is_private_method = tag == .class_private_method;

        // declare (non-private only)
        if (!is_private_method and (mods & 32) != 0) { // TS_MOD_DECLARE
            try self.writeStr("declare ");
        }
        // accessibility (non-private only)
        if (!is_private_method) {
            if (mods & 1 != 0) try self.writeStr("public ") // TS_MOD_PUBLIC
            else if (mods & 2 != 0) try self.writeStr("private ") // TS_MOD_PRIVATE
            else if (mods & 4 != 0) try self.writeStr("protected "); // TS_MOD_PROTECTED
        }

        if (is_static) {
            try self.writeStr("static ");
        }
        // abstract (non-private only)
        if (!is_private_method and (mods & 16) != 0) { // TS_MOD_ABSTRACT
            try self.writeStr("abstract ");
        }
        // override (non-private only)
        if (!is_private_method and (mods & 64) != 0) { // TS_MOD_OVERRIDE
            try self.writeStr("override ");
        }

        // Handle comment placement for class methods.
        // Comments attached to the key need to be placed at different structural positions:
        // - Trailing comments on key between `(` and `)` in source → inside `()`
        // - Trailing comments on key after `)` in source → after `)`
        // - For async+generator/computed: leading comments before `*`/`[` → after `async`
        // - For async+generator/computed: trailing comments inside `()` → after `async`

        // Find structural positions in source
        const open_paren_pos = self.findOpenParen(idx, key);
        const close_paren_pos = self.findCloseParen(idx, body);

        // Determine position of `*` in source (if generator), skipping comments
        const star_pos: u32 = if (is_generator) blk: {
            const method_start = self.nodeSourceStart(idx);
            var k: u32 = method_start;
            while (k < self.ast.source.len) : (k += 1) {
                if (k + 1 < self.ast.source.len and self.ast.source[k] == '/' and self.ast.source[k + 1] == '*') {
                    // Skip block comment
                    k += 2;
                    while (k + 1 < self.ast.source.len) : (k += 1) {
                        if (self.ast.source[k] == '*' and self.ast.source[k + 1] == '/') {
                            k += 1;
                            break;
                        }
                    }
                    continue;
                }
                if (self.ast.source[k] == '*') break :blk k;
            }
            break :blk method_start;
        } else 0;

        // Determine position of `[` in source (if computed), skipping comments
        const bracket_pos: u32 = if (is_computed) blk: {
            const method_start = self.nodeSourceStart(idx);
            var k: u32 = method_start;
            while (k < self.ast.source.len) : (k += 1) {
                if (k + 1 < self.ast.source.len and self.ast.source[k] == '/' and self.ast.source[k + 1] == '*') {
                    k += 2;
                    while (k + 1 < self.ast.source.len) : (k += 1) {
                        if (self.ast.source[k] == '*' and self.ast.source[k + 1] == '/') {
                            k += 1;
                            break;
                        }
                    }
                    continue;
                }
                if (self.ast.source[k] == '[') break :blk k;
            }
            break :blk method_start;
        } else 0;

        if (is_async) {
            try self.writeStr("async ");
        }

        // For async+generator/computed: move certain comments to before `*`/`[`
        if (is_async and (is_generator or is_computed)) {
            // Leading comments on key before `*`/`[` → emit after `async `
            // For generator+computed, use bracket_pos to move comments before `[`
            const before_limit = if (is_computed) bracket_pos else if (is_generator) star_pos else self.nodeSourceStart(key);
            try self.emitLeadingCommentsBeforePos(key, before_limit);
            // For computed methods: also move trailing comments between `]` and `(`
            // to before `[`, but NOT comments inside `[...]`
            if (is_computed) {
                // Find closing bracket position
                const close_bracket_pos = blk: {
                    const key_end = self.nodeSourceEnd(key);
                    var k: u32 = key_end;
                    while (k < self.ast.source.len) : (k += 1) {
                        if (self.ast.source[k] == ']') break :blk k;
                    }
                    break :blk key_end;
                };
                // Only move comments after `]`
                try self.emitTrailingCommentsBetweenPos(key, close_bracket_pos, open_paren_pos);
            }
            // Trailing comments inside empty parens → also emit after `async `
            try self.emitTrailingCommentsBetweenPos(key, open_paren_pos, close_paren_pos);
            // Ensure space before `*`/`[`
            if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] != ' ') {
                try self.space();
            }
        }

        if (is_generator) {
            try self.writeChar('*');
            // Add space before key's leading comments if any remain
            // (but not for computed keys, where `[` follows `*` directly)
            if (!is_computed and self.hasLeadingComments(key)) {
                try self.space();
            }
        }
        if (is_computed) {
            try self.writeChar('[');
        }
        if (is_private_method) {
            try self.writeChar('#');
        }

        // Suppress trailing comments on key — we'll place them manually
        self.suppress_trailing_comments = true;
        try self.emitNode(key);
        self.suppress_trailing_comments = false;

        if (is_computed) {
            // Emit trailing comments on key that are inside `[...]`
            // (between key end and closing bracket in source)
            const close_bracket_pos2 = blk: {
                const key_end = self.nodeSourceEnd(key);
                var k: u32 = key_end;
                while (k < self.ast.source.len) : (k += 1) {
                    if (self.ast.source[k] == ']') break :blk k;
                }
                break :blk key_end;
            };
            try self.emitTrailingCommentsBeforePos(key, close_bracket_pos2);
            try self.writeChar(']');
        }
        // TS: optional
        if (is_optional) {
            try self.writeChar('?');
        }

        // Emit trailing comments on key that are before the opening paren
        try self.emitTrailingCommentsBeforePos(key, open_paren_pos);

        // TS: type parameters
        if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
            try self.emitNode(tp);
        }
        try self.writeChar('(');

        // Emit trailing comments on key that are inside the parens
        // (for async+generator/computed these were already moved above)
        if (!(is_async and (is_generator or is_computed))) {
            try self.emitTrailingCommentsBetweenPos(key, open_paren_pos, close_paren_pos);
        }

        if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
            try self.emitTsParamList(params_start, params_end);
        }
        try self.writeChar(')');

        // Emit trailing comments on key that are after the closing paren
        const buf_before_post_paren = self.buf.items.len;
        try self.emitTrailingCommentsAfterPos(key, close_paren_pos);
        const had_post_paren_comments = self.buf.items.len > buf_before_post_paren;

        // TS: return type
        if (self.ast.return_types.get(@intFromEnum(idx))) |rt| {
            try self.emitNode(rt);
        }
        // Only add space before body if no comment was just emitted
        if (!had_post_paren_comments) {
            try self.space();
        }
        try self.emitNode(body);
    }

    // ---------------------------------------------------------------
    // Statements
    // ---------------------------------------------------------------

    fn emitBlockStatement(self: *Codegen, block_idx: NodeIndex, data: Node.Data) Error!void {
        // Block boundary: clear all head context — statements inside a block
        // have their own expression_statement/arrow_body context.
        self.clearHeadContext();
        self.token_context.for_init_head = false;
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            // Check if block is empty (or all items removed by transforms)
            const blk_is_empty = blk_be: {
                if (range_start >= range_end) break :blk_be true;
                const pre_tags_blk = self.ast.nodes.items(.tag);
                for (self.ast.extra_data.items[range_start..range_end]) |item| {
                    if (pre_tags_blk[item] != .removed) break :blk_be false;
                }
                break :blk_be true;
            };
            if (blk_is_empty) {
                // Check for block_prefix_source even when block body is empty
                // (e.g., block-scoped-functions transforms all statements but adds prefix text)
                if (self.ast.block_prefix_source.get(@intFromEnum(block_idx))) |prefix| {
                    try self.writeStr("{\n");
                    self.indent();
                    try self.writeIndent();
                    try self.writeReplacementIndented(prefix);
                    if (prefix.len == 0 or prefix[prefix.len - 1] != '\n') {
                        try self.newline();
                    }
                    self.dedent();
                    try self.writeIndent();
                    try self.writeChar('}');
                    return;
                }
                // Empty block — check for inner comments
                if (self.hasExpandedInnerComments(block_idx)) {
                    // Inner comments with line comments need expanded block layout
                    try self.writeStr("{\n");
                    self.indent();
                    try self.emitBlockInnerComments(block_idx, self.nodeSourceStart(block_idx));
                    self.dedent();
                    try self.writeIndent();
                    try self.writeChar('}');
                } else {
                    try self.writeChar('{');
                    try self.emitInnerComments(block_idx);
                    try self.writeChar('}');
                }
                return;
            }
            try self.writeStr("{\n");
            self.indent();
            const items = self.ast.extra_data.items[range_start..range_end];
            const tags_blk = self.ast.nodes.items(.tag);

            // Count leading directives — either .directive nodes or
            // expression_statement with string_literal body (function bodies)
            var blk_directive_count: usize = 0;
            const datas_blk = self.ast.nodes.items(.data);
            for (items) |item| {
                if (tags_blk[item] == .directive) {
                    blk_directive_count += 1;
                } else if (tags_blk[item] == .expression_statement) {
                    const inner = datas_blk[item].unary;
                    if (inner != .none and tags_blk[@intFromEnum(inner)] == .string_literal) {
                        blk_directive_count += 1;
                    } else break;
                } else break;
            }

            var prev_end: u32 = self.nodeSourceStart(block_idx); // start of '{'
            var prev_had_trailing_blk = false;

            // Emit directives
            for (items[0..blk_directive_count], 0..) |item, j| {
                const node_idx: NodeIndex = @enumFromInt(item);
                if (j == 0) {
                    try self.emitStatementLeadingCommentsNoBlank(node_idx, prev_end);
                } else {
                    try self.emitStatementLeadingCommentsImplEx(node_idx, prev_end, true, prev_had_trailing_blk);
                }
                if (!self.leading_comment_was_inline) {
                    try self.writeIndent();
                }
                // Suppress trailing comments on last directive when there are body items
                const is_last_dir_with_body = (j == blk_directive_count - 1 and blk_directive_count < items.len);
                if (is_last_dir_with_body) {
                    self.suppress_trailing_comments = true;
                }
                try self.emitNode(node_idx);
                self.suppress_trailing_comments = false;
                if (!is_last_dir_with_body) {
                    try self.emitRemainingStatementComments(node_idx);
                }
                try self.newline();
                prev_had_trailing_blk = self.statementHasDirectTrailingComments(node_idx);
                prev_end = self.getStatementEndWithTrailingComments(node_idx);
            }

            // Blank line after directives if there are body statements
            if (blk_directive_count > 0 and blk_directive_count < items.len) {
                try self.newline();
                // Emit last directive's trailing comments as indented comments
                const last_dir_idx: NodeIndex = @enumFromInt(items[blk_directive_count - 1]);
                try self.emitDeferredTrailingComments(last_dir_idx);
            }

            // Emit block prefix source (e.g., `var _this = this;` from arrow-functions transform)
            if (self.ast.block_prefix_source.get(@intFromEnum(block_idx))) |prefix| {
                try self.writeIndent();
                try self.writeReplacementIndented(prefix);
                if (prefix.len == 0 or prefix[prefix.len - 1] != '\n') {
                    try self.newline();
                }
            }

            // Emit body statements after directives
            var first_body = true;
            for (items[blk_directive_count..]) |item| {
                if (tags_blk[item] == .removed) continue; // Skip removed nodes
                const node_idx: NodeIndex = @enumFromInt(item);
                if (first_body) {
                    if (blk_directive_count > 0) {
                        try self.emitStatementLeadingCommentsNoBlank(node_idx, prev_end);
                    } else {
                        try self.emitStatementLeadingCommentsNoBlank(node_idx, prev_end);
                    }
                    first_body = false;
                } else {
                    try self.emitStatementLeadingCommentsImplEx(node_idx, prev_end, true, prev_had_trailing_blk);
                }
                if (!self.leading_comment_was_inline) {
                    try self.writeIndent();
                }
                try self.emitNode(node_idx);
                try self.emitRemainingStatementComments(node_idx);
                try self.newline();
                prev_had_trailing_blk = self.statementHasDirectTrailingComments(node_idx);
                prev_end = self.getStatementEndWithTrailingComments(node_idx);
            }
            // Emit inner comments (after all items, e.g., trailing block comments)
            try self.emitBlockInnerComments(block_idx, prev_end);
            self.dedent();
            try self.writeIndent();
            try self.writeChar('}');
        } else {
            try self.writeChar('{');
            try self.emitInnerComments(block_idx);
            try self.writeChar('}');
        }
    }

    fn emitIfStatement(self: *Codegen, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const condition: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const consequent: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const alternate: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

        try self.writeStr("if (");
        try self.emitNode(condition);
        try self.writeChar(')');
        // Check if consequent has a leading comment — if so, put on new line
        if (self.hasLeadingComments(consequent)) {
            try self.newline();
            try self.writeIndent();
            self.indent();
            try self.writeIndent();
            try self.emitNode(consequent);
            self.dedent();
        } else {
            try self.space();
            try self.emitNode(consequent);
        }
        if (alternate != .none) {
            if (self.endsWithLineComment()) {
                try self.newline();
                try self.writeIndent();
            } else {
                try self.writeChar(' ');
            }
            try self.writeStr("else ");
            try self.emitNode(alternate);
        }
    }

    /// Emit a statement body (after if/for/while etc.)
    /// Adds space before block statements, no space before semicolons
    fn emitStatementBody(self: *Codegen, body: NodeIndex) Error!void {
        if (body == .none) return;
        const body_tag = self.ast.nodes.items(.tag)[@intFromEnum(body)];
        if (body_tag == .empty_statement) {
            // Emit leading comments on the empty statement (e.g., between ')' and ';')
            if (self.hasLeadingComments(body)) {
                try self.space();
                try self.emitExprLeadingComments(body);
            }
            try self.semicolon();
        } else {
            try self.space();
            try self.emitNode(body);
        }
    }

    fn emitForStatement(self: *Codegen, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const init: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const test_expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const update: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);

        // Emit "for" keyword with inter-keyword comments
        try self.writeStr("for");
        // Emit comments between 'for' and '(' using source positions
        {
            const for_idx_node = self.parent_main_token; // main_token of for_statement
            const for_tok_start = self.ast.tokens.items(.start)[@intFromEnum(for_idx_node)];
            const for_tok_end = for_tok_start + 3; // "for" is 3 chars
            // Find '(' position
            var paren_pos_for: u32 = for_tok_end;
            while (paren_pos_for < self.ast.source.len) : (paren_pos_for += 1) {
                if (self.ast.source[paren_pos_for] == '(') break;
            }
            // Emit comments between 'for' and '(', also grab empty-slot comments
            // For empty test/update, their inner comments appear between ';' positions
            try self.emitAllCommentsBetween(for_tok_end, paren_pos_for);
            // If we have no test and no update, their comments should go here too
            if (test_expr == .none and update == .none) {
                // Find the ';' positions inside the for-parens
                const search_pos = paren_pos_for + 1;
                // Skip to first ';'
                var first_semi: u32 = search_pos;
                var depth: u32 = 0;
                while (first_semi < self.ast.source.len) : (first_semi += 1) {
                    if (self.ast.source[first_semi] == '(') depth += 1 else if (self.ast.source[first_semi] == ')') {
                        if (depth == 0) break;
                        depth -= 1;
                    } else if (self.ast.source[first_semi] == ';' and depth == 0) break;
                }
                if (first_semi < self.ast.source.len and self.ast.source[first_semi] == ';') {
                    var second_semi = first_semi + 1;
                    depth = 0;
                    while (second_semi < self.ast.source.len) : (second_semi += 1) {
                        if (self.ast.source[second_semi] == '(') depth += 1 else if (self.ast.source[second_semi] == ')') {
                            if (depth == 0) break;
                            depth -= 1;
                        } else if (self.ast.source[second_semi] == ';' and depth == 0) break;
                    }
                    if (second_semi < self.ast.source.len and self.ast.source[second_semi] == ';') {
                        // Find closing ')'
                        var close_paren: u32 = second_semi + 1;
                        depth = 0;
                        while (close_paren < self.ast.source.len) : (close_paren += 1) {
                            if (self.ast.source[close_paren] == '(') depth += 1 else if (self.ast.source[close_paren] == ')') {
                                if (depth == 0) break;
                                depth -= 1;
                            }
                        }
                        // Emit comments in empty test slot (between first_semi and second_semi)
                        try self.emitAllCommentsBetween(first_semi + 1, second_semi);
                        // Emit comments in empty update slot (between second_semi and close_paren)
                        try self.emitAllCommentsBetween(second_semi + 1, close_paren);
                    }
                }
            }
        }
        try self.writeStr(" (");
        if (init != .none) {
            // Check if init is a variable declaration - if so, we need to emit without trailing semicolon
            const init_tag = self.ast.nodes.items(.tag)[@intFromEnum(init)];
            switch (init_tag) {
                .var_declaration => try self.emitForVarDeclaration(init, "var"),
                .let_declaration => try self.emitForVarDeclaration(init, "let"),
                .const_declaration => try self.emitForVarDeclaration(init, "const"),
                .using_declaration => try self.emitForVarDeclaration(init, "using"),
                .await_using_declaration => try self.emitForAwaitUsingDeclaration(init),
                else => {
                    self.token_context.for_init_head = true;
                    try self.emitNode(init);
                },
            }
        }
        try self.semicolon();
        if (test_expr != .none) {
            try self.space();
            try self.emitNode(test_expr);
        }
        try self.semicolon();
        if (update != .none) {
            try self.space();
            try self.emitNode(update);
        }
        try self.writeChar(')');
        try self.emitStatementBody(body);
    }

    /// Emit a variable declaration without trailing semicolon (for `for` init)
    fn emitForVarDeclaration(self: *Codegen, idx: NodeIndex, keyword: []const u8) Error!void {
        // Emit leading comments (not called through emitNode)
        try self.emitExprLeadingComments(idx);
        if (self.ast.replacement_source.get(@intFromEnum(idx))) |replacement| {
            try self.writeStr(self.normalizeForHeadReplacement(replacement));
            return;
        }
        const i = @intFromEnum(idx);
        const data = self.ast.nodes.items(.data)[i];
        const saved_for_init_head = self.token_context.for_init_head;
        self.token_context.for_init_head = true;
        defer self.token_context.for_init_head = saved_for_init_head;
        try self.writeStr(keyword);
        try self.space();
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx < self.ast.extra_data.items.len) {
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                try self.emitCommaSeparated(range_start, range_end);
            }
        }
    }

    fn normalizeForHeadReplacement(self: *Codegen, replacement: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, replacement, ";\n\r\t ");
        if (std.mem.indexOfScalar(u8, trimmed, '\n') == null and std.mem.indexOfScalar(u8, trimmed, '\r') == null) {
            return trimmed;
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var last_was_space = false;
        var in_quote: ?u8 = null;
        var escaped = false;
        for (trimmed) |c| {
            if (in_quote) |q| {
                buf.append(self.allocator, c) catch return trimmed;
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == q) {
                    in_quote = null;
                }
                continue;
            }

            switch (c) {
                '\'', '"', '`' => {
                    buf.append(self.allocator, c) catch return trimmed;
                    in_quote = c;
                    last_was_space = false;
                    escaped = false;
                },
                ' ', '\n', '\r', '\t' => {
                    if (!last_was_space) {
                        buf.append(self.allocator, ' ') catch return trimmed;
                        last_was_space = true;
                    }
                },
                else => {
                    buf.append(self.allocator, c) catch return trimmed;
                    last_was_space = false;
                },
            }
        }
        return std.mem.trim(u8, buf.items, " ");
    }

    fn emitForInStatement(self: *Codegen, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const left: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const right: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

        try self.writeStr("for (");
        const saved_for_init_head = self.token_context.for_init_head;
        self.token_context.for_init_head = true;
        self.child_position = .left;
        try self.emitForInOfLeft(left);
        self.token_context.for_init_head = saved_for_init_head;
        try self.writeStr(" in ");
        self.child_position = .right;
        try self.emitNode(right);
        try self.writeChar(')');
        try self.emitStatementBody(body);
    }

    fn emitForOfStatement(self: *Codegen, data: Node.Data, is_await: bool) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const left: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const right: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

        // Emit "for" with inter-keyword comments
        try self.writeStr("for");
        const for_of_mt = self.parent_main_token;
        const for_of_tok_start = self.ast.tokens.items(.start)[@intFromEnum(for_of_mt)];
        const for_of_tok_end = for_of_tok_start + 3; // "for" is 3 chars
        // Find '(' position, skipping 'await' if present
        var fo_paren_pos: u32 = for_of_tok_end;
        while (fo_paren_pos < self.ast.source.len) : (fo_paren_pos += 1) {
            if (self.ast.source[fo_paren_pos] == '(') break;
        }
        if (is_await) {
            // Find 'await' position between 'for' and '('
            const await_pos = self.findKeywordAfter(for_of_tok_end, "await");
            // Emit comments between 'for' and 'await', then between 'await' and '('
            try self.emitAllCommentsBetween(for_of_tok_end, await_pos);
            try self.emitAllCommentsBetween(await_pos + 5, fo_paren_pos);
            try self.writeStr(" await (");
        } else {
            try self.emitAllCommentsBetween(for_of_tok_end, fo_paren_pos);
            try self.writeStr(" (");
        }
        // Find closing ')' position in source (for trailing comment limit)
        var fo_close_paren: u32 = fo_paren_pos + 1;
        {
            var depth2: u32 = 0;
            while (fo_close_paren < self.ast.source.len) : (fo_close_paren += 1) {
                if (self.ast.source[fo_close_paren] == '(') {
                    depth2 += 1;
                } else if (self.ast.source[fo_close_paren] == ')') {
                    if (depth2 == 0) break;
                    depth2 -= 1;
                }
            }
        }
        self.child_position = .left;
        try self.emitForInOfLeft(left);
        try self.writeStr(" of ");
        self.child_position = .right;
        // Limit trailing comments to not emit past the closing ')'
        self.trailing_comment_source_limit = fo_close_paren;
        try self.emitNode(right);
        self.trailing_comment_source_limit = 0;
        try self.writeChar(')');
        // Emit comments between ')' and body (e.g., `for (...) /*comment*/ ;`)
        if (fo_close_paren < self.ast.source.len) {
            const body_start = if (body != .none) self.nodeSourceStart(body) else fo_close_paren + 1;
            try self.emitAllCommentsBetween(fo_close_paren + 1, body_start);
        }
        try self.emitStatementBody(body);
    }

    /// Emit the left side of for-in/for-of (variable declaration without semicolon, or expression)
    fn emitForInOfLeft(self: *Codegen, left: NodeIndex) Error!void {
        if (left == .none) return;
        const left_tag = self.ast.nodes.items(.tag)[@intFromEnum(left)];
        switch (left_tag) {
            .var_declaration => try self.emitForVarDeclaration(left, "var"),
            .let_declaration => try self.emitForVarDeclaration(left, "let"),
            .const_declaration => try self.emitForVarDeclaration(left, "const"),
            .using_declaration => try self.emitForVarDeclaration(left, "using"),
            .await_using_declaration => try self.emitForAwaitUsingDeclaration(left),
            else => try self.emitNode(left),
        }
    }

    fn emitWhileStatement(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("while (");
        try self.emitNode(data.binary.lhs);
        try self.writeChar(')');
        try self.emitStatementBody(data.binary.rhs);
    }

    fn emitDoWhileStatement(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("do ");
        try self.emitNode(data.binary.lhs);
        // If the body ended with a line comment, emit newline before 'while'
        if (self.endsWithLineComment()) {
            try self.newline();
        } else {
            try self.writeChar(' ');
        }
        try self.writeStr("while (");
        try self.emitNode(data.binary.rhs);
        try self.writeStr(");");
    }

    fn emitSwitchStatement(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const discriminant: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const cases_start = self.ast.extra_data.items[extra_idx + 1];
        const cases_end = self.ast.extra_data.items[extra_idx + 2];
        const prefix = self.ast.block_prefix_source.get(@intFromEnum(idx));

        if (prefix) |p| {
            try self.writeStr("{\n");
            self.indent();
            try self.writeIndent();
            try self.writeReplacementIndented(p);
            if (p.len == 0 or p[p.len - 1] != '\n') {
                try self.newline();
            }
            try self.writeIndent();
        }

        try self.writeStr("switch (");
        try self.emitNode(discriminant);
        try self.writeStr(") ");
        if (cases_start >= cases_end) {
            try self.writeStr("{}");
            if (prefix != null) {
                self.dedent();
                try self.newline();
                try self.writeIndent();
                try self.writeChar('}');
            }
            return;
        }
        try self.writeStr("{\n");
        self.indent();
        if (cases_start <= cases_end and cases_end <= self.ast.extra_data.items.len) {
            const cases = self.ast.extra_data.items[cases_start..cases_end];
            for (cases) |c| {
                try self.writeIndent();
                try self.emitNode(@enumFromInt(c));
                try self.newline();
            }
        }
        self.dedent();
        try self.writeIndent();
        try self.writeChar('}');
        if (prefix != null) {
            self.dedent();
            try self.newline();
            try self.writeIndent();
            try self.writeChar('}');
        }
    }

    fn emitSwitchCase(self: *Codegen, data: Node.Data, is_default: bool) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const test_expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const stmts_start = self.ast.extra_data.items[extra_idx + 1];
        const stmts_end = self.ast.extra_data.items[extra_idx + 2];

        if (is_default) {
            try self.writeStr("default:");
        } else {
            try self.writeStr("case ");
            try self.emitNode(test_expr);
            try self.writeChar(':');
        }

        if (stmts_start < stmts_end and stmts_end <= self.ast.extra_data.items.len) {
            const tags = self.ast.nodes.items(.tag);
            var emitted_count: usize = 0;
            for (self.ast.extra_data.items[stmts_start..stmts_end]) |s| {
                if (s >= tags.len) continue;
                if (tags[s] != .removed) emitted_count += 1;
            }
            if (emitted_count == 0) return;

            try self.newline();
            self.indent();
            const stmts = self.ast.extra_data.items[stmts_start..stmts_end];
            var emitted_index: usize = 0;
            for (stmts) |s| {
                if (s >= tags.len or tags[s] == .removed) continue;
                try self.writeIndent();
                try self.emitNode(@enumFromInt(s));
                emitted_index += 1;
                if (emitted_index < emitted_count) {
                    try self.newline();
                }
            }
            self.dedent();
        }
    }

    fn emitReturnStatement(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("return");
        if (data.unary != .none) {
            // If the argument has a leading line comment, wrap in parens to prevent
            // the comment from terminating the return statement.
            if (self.hasLeadingLineComment(data.unary)) {
                try self.writeStr(" (\n");
                self.indent();
                try self.writeIndent();
                // emitNode will call emitExprLeadingComments internally
                try self.emitNode(data.unary);
                try self.newline();
                self.dedent();
                try self.writeIndent();
                try self.writeChar(')');
            } else {
                try self.space();
                try self.emitNode(data.unary);
            }
        }
        try self.emitSemicolonAfterTrailingComment();
    }

    fn emitThrowStatement(self: *Codegen, data: Node.Data) Error!void {
        if (self.hasLeadingLineComment(data.unary)) {
            try self.writeStr("throw (\n");
            self.indent();
            try self.writeIndent();
            try self.emitNode(data.unary);
            try self.newline();
            self.dedent();
            try self.writeIndent();
            try self.writeChar(')');
        } else {
            try self.writeStr("throw ");
            try self.emitNode(data.unary);
        }
        try self.emitSemicolonAfterTrailingComment();
    }

    fn emitTryStatement(self: *Codegen, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const block: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
        const handler: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
        const finalizer: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

        try self.writeStr("try ");
        try self.emitNode(block);
        if (handler != .none) {
            if (self.endsWithLineComment()) {
                try self.newline();
                try self.writeIndent();
            } else {
                try self.space();
            }
            try self.emitNode(handler);
        }
        if (finalizer != .none) {
            if (self.endsWithLineComment()) {
                try self.newline();
                try self.writeIndent();
            } else {
                try self.writeChar(' ');
            }
            try self.writeStr("finally ");
            try self.emitNode(finalizer);
        }
    }

    fn emitCatchClause(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("catch");
        if (data.binary.lhs != .none) {
            try self.writeStr(" (");
            try self.emitNode(data.binary.lhs);
            // TS: type annotation on catch parameter
            if (self.ast.type_annotations.get(@intFromEnum(data.binary.lhs))) |ta| {
                try self.emitNode(ta);
            }
            try self.writeStr(") ");
        } else {
            try self.space();
        }
        try self.emitNode(data.binary.rhs);
    }

    fn emitBreakContinue(self: *Codegen, main_token: TokenIndex, data: Node.Data, keyword: []const u8) Error!void {
        try self.emitKeyword(main_token, keyword);
        if (data.unary != .none) {
            try self.space();
            try self.emitNode(data.unary);
        }
        try self.semicolon();
    }

    fn emitLabeledStatement(self: *Codegen, main_token: TokenIndex, data: Node.Data) Error!void {
        try self.emitToken(main_token);
        try self.writeStr(": ");
        try self.emitNode(data.unary);
    }

    fn emitWithStatement(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("with (");
        try self.emitNode(data.binary.lhs);
        try self.writeStr(") ");
        try self.emitNode(data.binary.rhs);
    }

    // ---------------------------------------------------------------
    // Module
    // ---------------------------------------------------------------

    fn emitImportDeclaration(self: *Codegen, idx: NodeIndex, data: Node.Data, is_typeof: bool) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const source_token_raw = self.ast.extra_data.items[extra_idx];
        const specs_start = self.ast.extra_data.items[extra_idx + 1];
        const specs_end = self.ast.extra_data.items[extra_idx + 2];

        // Get main_token (import keyword) position
        const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
        const import_start = self.ast.tokens.items(.start)[@intFromEnum(mt)];
        const import_slice = self.ast.tokenSlice(mt);
        var cursor: u32 = import_start + @as(u32, @intCast(import_slice.len));

        // Check for import phase (source/defer)
        const phase_val = self.ast.ts_class_modifiers.get(@intFromEnum(idx));
        const has_phase = phase_val != null and (phase_val.? == 0x100 or phase_val.? == 0x200);

        if (is_typeof) {
            try self.writeStr("import typeof ");
        } else {
            try self.writeStr("import");
        }

        if (has_phase) {
            const pv = phase_val.?;
            if (pv == 0x100) {
                // Find 'source' keyword position
                const source_kw_pos = self.findKeywordAfter(cursor, "source");
                try self.emitAllCommentsBetween(cursor, source_kw_pos);
                try self.writeStr(" source");
                cursor = source_kw_pos + 6;
            } else if (pv == 0x200) {
                const defer_kw_pos = self.findKeywordAfter(cursor, "defer");
                try self.emitAllCommentsBetween(cursor, defer_kw_pos);
                try self.writeStr(" defer");
                cursor = defer_kw_pos + 5;
            }
        }

        if (specs_start < specs_end and specs_end <= self.ast.extra_data.items.len) {
            const specs = self.ast.extra_data.items[specs_start..specs_end];
            const tags = self.ast.nodes.items(.tag);

            // Emit comments between last keyword and first specifier
            if (specs.len > 0) {
                const first_spec_start = self.getNodeSourceStart(@enumFromInt(specs[0]));
                try self.emitAllCommentsBetween(cursor, first_spec_start);
            }
            // Add space before specifiers (after 'import', 'import source', etc.)
            // Only needed when buffer doesn't end with space or block comment
            if (!self.endsWithBlockComment() and self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] != ' ') {
                try self.space();
            }

            // Group specifiers: default first, then namespace, then named
            var has_default = false;
            var has_namespace = false;
            var named_start: ?usize = null;
            var named_end: usize = 0;

            for (specs, 0..) |s, j| {
                const spec_tag = tags[s];
                if (spec_tag == .import_default) {
                    has_default = true;
                    try self.emitNode(@enumFromInt(s));
                    cursor = self.nodeSourceEnd(@enumFromInt(s));
                    // Check what follows
                    const has_more = j + 1 < specs.len;
                    if (has_more) {
                        try self.writeStr(", ");
                    }
                } else if (spec_tag == .import_namespace) {
                    has_namespace = true;
                    try self.emitNode(@enumFromInt(s));
                    cursor = self.nodeSourceEnd(@enumFromInt(s));
                } else {
                    if (named_start == null) named_start = j;
                    named_end = j + 1;
                }
            }

            if (named_start) |ns| {
                try self.writeStr("{ ");
                var first = true;
                for (specs[ns..named_end]) |s| {
                    if (!first) try self.writeStr(", ");
                    first = false;
                    try self.emitNode(@enumFromInt(s));
                }
                try self.writeStr(" }");
            }

            if (has_default or has_namespace or named_start != null) {
                // Find 'from' keyword position in source
                const source_tok2: TokenIndex = @enumFromInt(source_token_raw);
                const source_tok_start = self.ast.tokens.items(.start)[@intFromEnum(source_tok2)];
                const from_pos = self.findKeywordBefore(source_tok_start, "from");
                // Emit comments between last specifier and 'from'
                try self.emitAllCommentsBetween(cursor, from_pos);
                try self.writeStr(" from");
                cursor = from_pos + 4;
                // Emit comments between 'from' and source token
                try self.emitAllCommentsBetween(cursor, source_tok_start);
                // Only add space if buffer doesn't end with a block comment (Babel joins comment to token)
                if (!self.endsWithBlockComment()) {
                    try self.space();
                }
            }
        }

        // Ensure space before source token (unless preceded by block comment)
        if (!self.endsWithBlockComment() and self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] != ' ') {
            try self.space();
        }

        // Source
        const source_tok: TokenIndex = @enumFromInt(source_token_raw);
        try self.emitToken(source_tok);
        const source_tok_end2 = self.ast.tokens.items(.start)[@intFromEnum(source_tok)] +
            @as(u32, @intCast(self.ast.tokenSlice(source_tok).len));

        // Attributes
        const has_attrs = extra_idx + 4 < self.ast.extra_data.items.len;
        if (has_attrs) {
            const attrs_start = self.ast.extra_data.items[extra_idx + 3];
            const attrs_end = self.ast.extra_data.items[extra_idx + 4];
            if (attrs_start < attrs_end and attrs_end <= self.ast.extra_data.items.len) {
                try self.writeStr(" with { ");
                try self.emitCommaSeparated(attrs_start, attrs_end);
                try self.writeStr(" }");
            }
        }

        // Emit comments between source token and semicolon
        const node_end = self.nodeSourceEnd(idx);
        try self.emitAllCommentsBetween(source_tok_end2, node_end);
        try self.semicolon();
    }

    /// Find a keyword in source starting from the given position.
    fn findKeywordAfter(self: *Codegen, start: u32, keyword: []const u8) u32 {
        var pos = start;
        while (pos + keyword.len <= self.ast.source.len) : (pos += 1) {
            if (std.mem.eql(u8, self.ast.source[pos .. pos + keyword.len], keyword)) return pos;
        }
        return start;
    }

    /// Find a keyword in source scanning backwards from the given position.
    fn findKeywordBefore(self: *Codegen, end: u32, keyword: []const u8) u32 {
        if (end < keyword.len) return 0;
        var pos = end;
        while (pos >= keyword.len) {
            pos -= 1;
            if (pos + keyword.len <= self.ast.source.len and
                std.mem.eql(u8, self.ast.source[pos .. pos + keyword.len], keyword))
            {
                return pos;
            }
        }
        return 0;
    }

    /// Get the source start of a node, considering node_start_overrides.
    fn getNodeSourceStart(self: *Codegen, idx: NodeIndex) u32 {
        if (self.ast.node_start_overrides.get(@intFromEnum(idx))) |override| return override;
        return self.nodeSourceStart(idx);
    }

    fn emitImportSpecifier(self: *Codegen, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const imported_token_raw = self.ast.extra_data.items[extra_idx];
        const local_token_raw = self.ast.extra_data.items[extra_idx + 1];

        const imported_tok: TokenIndex = @enumFromInt(imported_token_raw);
        const local_tok: TokenIndex = @enumFromInt(local_token_raw);

        try self.emitToken(imported_tok);
        // If imported != local, emit " as local"
        const imported_text = self.ast.tokenSlice(imported_tok);
        const local_text = self.ast.tokenSlice(local_tok);
        if (!std.mem.eql(u8, imported_text, local_text)) {
            try self.writeStr(" as ");
            try self.emitToken(local_tok);
        }
    }

    fn emitImportDefault(self: *Codegen, main_token: TokenIndex) Error!void {
        try self.emitToken(main_token);
    }

    fn emitImportNamespace(self: *Codegen, main_token: TokenIndex) Error!void {
        try self.writeStr("* as ");
        try self.emitToken(main_token);
    }

    fn emitImportAttribute(self: *Codegen, data: Node.Data) Error!void {
        try self.emitNode(data.binary.lhs);
        try self.writeStr(": ");
        try self.emitNode(data.binary.rhs);
    }

    fn emitExportNamed(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const source_token_raw = self.ast.extra_data.items[extra_idx];
        const specs_start = self.ast.extra_data.items[extra_idx + 1];
        const specs_end = self.ast.extra_data.items[extra_idx + 2];

        // Check if there's a declaration (4th extra element)
        const has_decl = extra_idx + 3 < self.ast.extra_data.items.len and
            self.ast.extra_data.items[extra_idx + 3] != @intFromEnum(NodeIndex.none);
        const decl_raw = if (extra_idx + 3 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 3]
        else
            @intFromEnum(NodeIndex.none);

        if (has_decl and decl_raw != @intFromEnum(NodeIndex.none)) {
            const decl_node: NodeIndex = @enumFromInt(decl_raw);
            // Determine whether decorators should go before or after 'export'.
            // If the first decorator starts before the export keyword, emit
            // decorators first (e.g. `@dec export class A {}`).
            // Otherwise, emit `export` first and let the class print its own
            // decorators (e.g. `export @dec class A {}`).
            const export_start = self.nodeSourceStart(idx);
            const dec_range = self.ast.decorators_map.get(@intFromEnum(decl_node));
            const decs_before_export = if (dec_range) |dr| blk: {
                if (dr.start < dr.end) {
                    const first_dec: NodeIndex = @enumFromInt(self.ast.extra_data.items[dr.start]);
                    break :blk self.nodeSourceStart(first_dec) < export_start;
                }
                break :blk false;
            } else false;

            if (decs_before_export) {
                // Skip decorator emission when the class has been replaced by
                // a transform (e.g. legacy decorator lowering) — the replacement
                // text already encodes the decorator semantics.
                const decl_replaced = self.ast.replacement_source.contains(@intFromEnum(decl_node));
                if (!decl_replaced) try self.emitDecorators(decl_node);
                try self.writeStr("export ");
                self.suppress_decorators = true;
                try self.emitNode(decl_node);
                self.suppress_decorators = false;
            } else {
                // Decorators are after export — emit export, then decorators on separate lines
                const decl_tag = self.ast.nodes.items(.tag)[@intFromEnum(decl_node)];
                const has_decorators = (decl_tag == .class_declaration or decl_tag == .class_expr) and
                    self.ast.decorators_map.contains(@intFromEnum(decl_node));
                if (has_decorators) {
                    // Emit everything manually with precise comment placement
                    const export_mt2 = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                    const export_end2 = self.ast.tokens.items(.start)[@intFromEnum(export_mt2)] + 6; // "export".len

                    try self.writeStr("export");

                    // Get decorator range
                    const dr = self.ast.decorators_map.get(@intFromEnum(decl_node)).?;
                    const decs = self.ast.extra_data.items[dr.start..dr.end];

                    // Find 'class' keyword position to limit comment marking
                    var class_kw_pos_limit: u32 = export_end2;
                    if (decs.len > 0) {
                        const last_d: NodeIndex = @enumFromInt(decs[decs.len - 1]);
                        class_kw_pos_limit = self.findKeywordAfter(self.nodeSourceEnd(last_d), "class");
                    }

                    // Mark comments between export and 'class' keyword as emitted
                    // (we'll manually emit them at the right positions)
                    // Don't mark comments inside the class body.
                    self.markAllCommentsInRange(export_end2, class_kw_pos_limit);

                    // Emit each decorator with preceding comments
                    var prev_end: u32 = export_end2;
                    for (decs) |dec_raw| {
                        const dec: NodeIndex = @enumFromInt(dec_raw);
                        const dec_start = self.nodeSourceStart(dec);
                        const dec_end = self.nodeSourceEnd(dec);

                        // Emit comments between previous position and this decorator
                        if (self.hasAnyCommentsBetween(prev_end, dec_start)) {
                            try self.emitCommentsBetweenNoSpace(prev_end, dec_start);
                        } else {
                            // No comments — ensure space after keyword
                            if (self.buf.items.len > 0) {
                                const last_ch = self.buf.items[self.buf.items.len - 1];
                                if (last_ch != ' ' and last_ch != '\n' and last_ch != '\t') {
                                    try self.space();
                                }
                            }
                        }

                        // Emit the decorator directly (not via emitNode which adds newline+indent)
                        try self.writeChar('@');
                        const dec_data = self.ast.nodes.items(.data)[@intFromEnum(dec)];
                        try self.emitNode(dec_data.unary);

                        prev_end = dec_end;

                        // Newline after each decorator
                        try self.newline();
                    }

                    // Emit comments between last decorator and 'class'
                    if (decs.len > 0) {
                        const last_dec: NodeIndex = @enumFromInt(decs[decs.len - 1]);
                        const last_dec_end = self.nodeSourceEnd(last_dec);
                        const class_kw_pos = self.findKeywordAfter(last_dec_end, "class");
                        try self.emitCommentsBetweenNoSpace(last_dec_end, class_kw_pos);
                    }

                    // Emit class with decorators suppressed (comments already marked emitted)
                    self.suppress_decorators = true;
                    try self.emitNode(decl_node);
                    self.suppress_decorators = false;
                } else {
                    try self.writeStr("export ");
                    try self.emitNode(decl_node);
                }
            }
        } else {
            try self.writeStr("export ");

            // Check for export_namespace_specifier (export * as ns from)
            if (specs_start < specs_end and specs_end <= self.ast.extra_data.items.len) {
                const specs = self.ast.extra_data.items[specs_start..specs_end];
                if (specs.len == 1) {
                    const spec_node: NodeIndex = @enumFromInt(specs[0]);
                    const spec_tag = self.ast.nodes.items(.tag)[@intFromEnum(spec_node)];
                    if (spec_tag == .export_namespace_specifier) {
                        try self.emitNode(spec_node);
                        if (source_token_raw != 0) {
                            try self.writeStr(" from ");
                            const source_tok: TokenIndex = @enumFromInt(source_token_raw);
                            try self.emitToken(source_tok);
                        }
                        try self.semicolon();
                        return;
                    }
                }
            }

            if (specs_start < specs_end and specs_end <= self.ast.extra_data.items.len) {
                const specs = self.ast.extra_data.items[specs_start..specs_end];
                const tags = self.ast.nodes.items(.tag);

                // Separate export_default_specifier from named specifiers
                var default_spec_idx: ?usize = null;
                for (specs, 0..) |s, j| {
                    if (tags[s] == .export_default_specifier) {
                        default_spec_idx = j;
                        break;
                    }
                }

                if (default_spec_idx) |di| {
                    // Emit the default specifier without braces
                    try self.emitNode(@enumFromInt(specs[di]));
                    // Check if there are also named specifiers
                    var has_named = false;
                    for (specs, 0..) |s, j| {
                        if (j == di) continue;
                        if (!has_named) {
                            try self.writeStr(", { ");
                            has_named = true;
                        } else {
                            try self.writeStr(", ");
                        }
                        try self.emitNode(@enumFromInt(s));
                    }
                    if (has_named) {
                        try self.writeStr(" }");
                    }
                } else {
                    try self.writeStr("{ ");
                    var first = true;
                    for (specs) |s| {
                        if (!first) try self.writeStr(", ");
                        first = false;
                        try self.emitNode(@enumFromInt(s));
                    }
                    try self.writeStr(" }");
                }
            } else {
                try self.writeStr("{}");
            }

            if (source_token_raw != 0) {
                try self.writeStr(" from ");
                const source_tok: TokenIndex = @enumFromInt(source_token_raw);
                try self.emitToken(source_tok);
            }

            // Attributes
            const has_attrs = extra_idx + 5 < self.ast.extra_data.items.len;
            if (has_attrs) {
                const attrs_start = self.ast.extra_data.items[extra_idx + 4];
                const attrs_end = self.ast.extra_data.items[extra_idx + 5];
                if (attrs_start < attrs_end and attrs_end <= self.ast.extra_data.items.len) {
                    try self.writeStr(" with { ");
                    try self.emitCommaSeparated(attrs_start, attrs_end);
                    try self.writeStr(" }");
                }
            }

            try self.semicolon();
        }
    }

    fn emitExportDefault(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        if (data.unary != .none) {
            // Determine whether decorators should go before or after 'export default'.
            const export_start = self.nodeSourceStart(idx);
            const dec_range = self.ast.decorators_map.get(@intFromEnum(data.unary));
            const decs_before_export = if (dec_range) |dr| blk: {
                if (dr.start < dr.end) {
                    const first_dec: NodeIndex = @enumFromInt(self.ast.extra_data.items[dr.start]);
                    break :blk self.nodeSourceStart(first_dec) < export_start;
                }
                break :blk false;
            } else false;

            if (decs_before_export) {
                try self.emitDecorators(data.unary);
            }
            const decl_tag = self.ast.nodes.items(.tag)[@intFromEnum(data.unary)];
            const has_decs_after = !decs_before_export and
                (decl_tag == .class_declaration or decl_tag == .class_expr) and
                self.ast.decorators_map.contains(@intFromEnum(data.unary));

            if (has_decs_after) {
                // export default @dec class — format with each keyword/decorator on its own line
                const export_mt_ed = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                const export_start_ed = self.ast.tokens.items(.start)[@intFromEnum(export_mt_ed)];
                const export_end_ed = export_start_ed + 6; // "export".len
                // Find 'default' keyword
                const default_pos = self.findKeywordAfter(export_end_ed, "default");
                const default_end = default_pos + 7; // "default".len

                try self.writeStr("export");
                // Comments between 'export' and 'default'
                const has_export_default_comments = self.hasAnyCommentsBetween(export_end_ed, default_pos);
                if (has_export_default_comments) {
                    try self.emitAllCommentsBetween(export_end_ed, default_pos);
                    try self.newline();
                    try self.writeStr("default");
                } else {
                    try self.writeStr(" default");
                }

                // Get decorators
                const dr = self.ast.decorators_map.get(@intFromEnum(data.unary)).?;
                const decs_ed = self.ast.extra_data.items[dr.start..dr.end];
                const decl_src_end_ed = self.nodeSourceEnd(data.unary);

                // Mark comments between 'default' and class end as emitted
                // (we'll emit them manually)
                const class_kw_pos_ed = self.findKeywordAfter(if (decs_ed.len > 0) self.nodeSourceEnd(@enumFromInt(decs_ed[decs_ed.len - 1])) else default_end, "class");
                self.markAllCommentsInRange(default_end, class_kw_pos_ed);
                _ = decl_src_end_ed;

                // Emit each decorator
                var prev_end_ed: u32 = default_end;
                for (decs_ed) |dec_raw| {
                    const dec: NodeIndex = @enumFromInt(dec_raw);
                    const dec_start_ed = self.nodeSourceStart(dec);
                    const dec_end_ed = self.nodeSourceEnd(dec);

                    if (self.hasAnyCommentsBetween(prev_end_ed, dec_start_ed)) {
                        try self.emitCommentsBetweenNoSpace(prev_end_ed, dec_start_ed);
                    } else {
                        if (self.buf.items.len > 0) {
                            const last_ch2 = self.buf.items[self.buf.items.len - 1];
                            if (last_ch2 != ' ' and last_ch2 != '\n' and last_ch2 != '\t') {
                                try self.space();
                            }
                        }
                    }

                    // Emit decorator directly (without newline/indent from emitDecorator)
                    try self.writeChar('@');
                    const dec_data_ed = self.ast.nodes.items(.data)[@intFromEnum(dec)];
                    try self.emitNode(dec_data_ed.unary);

                    prev_end_ed = dec_end_ed;
                    try self.newline();
                }

                // Emit comments between last decorator and 'class'
                if (decs_ed.len > 0) {
                    const last_dec_ed: NodeIndex = @enumFromInt(decs_ed[decs_ed.len - 1]);
                    const last_dec_end_ed = self.nodeSourceEnd(last_dec_ed);
                    try self.emitCommentsBetweenNoSpace(last_dec_end_ed, class_kw_pos_ed);
                }

                // Emit class with decorators suppressed
                self.suppress_decorators = true;
                self.token_context.export_default = true;
                try self.emitNode(data.unary);
                self.suppress_decorators = false;
            } else {
                try self.writeStr("export default ");
                if (decs_before_export) {
                    self.suppress_decorators = true;
                }
                self.token_context.export_default = true;
                try self.emitNode(data.unary);
                self.suppress_decorators = false;
            }
            // Add semicolon for non-declaration exports
            switch (decl_tag) {
                .function_declaration,
                .async_function_declaration,
                .generator_declaration,
                .async_generator_declaration,
                .class_declaration,
                .ts_interface_declaration,
                .ts_type_alias_declaration,
                .ts_enum_declaration,
                .ts_module_declaration,
                .ts_declare_function,
                .ts_declare_variable,
                => {},
                else => try self.semicolon(),
            }
        }
    }

    fn emitExportAll(self: *Codegen, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const source_token_raw = self.ast.extra_data.items[extra_idx];

        // TS: export type *
        const is_type_export = if (extra_idx + 3 < self.ast.extra_data.items.len)
            self.ast.extra_data.items[extra_idx + 3] != 0
        else
            false;
        if (is_type_export) {
            try self.writeStr("export type * from ");
        } else {
            try self.writeStr("export * from ");
        }
        const source_tok: TokenIndex = @enumFromInt(source_token_raw);
        try self.emitToken(source_tok);

        // Attributes
        if (extra_idx + 2 < self.ast.extra_data.items.len) {
            const attrs_start = self.ast.extra_data.items[extra_idx + 1];
            const attrs_end = self.ast.extra_data.items[extra_idx + 2];
            if (attrs_start < attrs_end and attrs_end <= self.ast.extra_data.items.len) {
                try self.writeStr(" with { ");
                try self.emitCommaSeparated(attrs_start, attrs_end);
                try self.writeStr(" }");
            }
        }

        try self.semicolon();
    }

    fn emitExportSpecifier(self: *Codegen, data: Node.Data, is_type: bool) Error!void {
        if (is_type) {
            try self.writeStr("type ");
        }
        const extra_idx = @intFromEnum(data.extra);
        const local_token_raw = self.ast.extra_data.items[extra_idx];
        const exported_token_raw = self.ast.extra_data.items[extra_idx + 1];

        const local_tok: TokenIndex = @enumFromInt(local_token_raw);
        const exported_tok: TokenIndex = @enumFromInt(exported_token_raw);

        try self.emitToken(local_tok);
        const local_text = self.ast.tokenSlice(local_tok);
        const exported_text = self.ast.tokenSlice(exported_tok);
        if (!std.mem.eql(u8, local_text, exported_text)) {
            try self.writeStr(" as ");
            try self.emitToken(exported_tok);
        }
    }

    fn emitExportNamespaceSpecifier(self: *Codegen, data: Node.Data) Error!void {
        // data.unary stores the exported name token (as NodeIndex cast from TokenIndex)
        const name_token_raw = @intFromEnum(data.unary);
        const name_tok: TokenIndex = @enumFromInt(name_token_raw);
        try self.writeStr("* as ");
        try self.emitToken(name_tok);
    }

    fn emitModuleExpression(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const extra_idx = @intFromEnum(data.extra);
        const range_start = self.ast.extra_data.items[extra_idx];
        const range_end = self.ast.extra_data.items[extra_idx + 1];
        if (range_start >= range_end) {
            // Empty module body — emit inner comments split around '{'
            // Comments before '{' go between 'module' and '{';
            // comments after '{' go inside '{}'.
            const key = @intFromEnum(idx);
            const ic_range = self.ast.inner_comments.get(key);
            if (ic_range) |icr| {
                const comments = self.ast.comments.items;
                // Find '{' position in source
                const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                const tok_start = self.ast.tokens.items(.start)[@intFromEnum(mt)];
                const tok_slice = self.ast.tokenSlice(mt);
                const module_end = tok_start + @as(u32, @intCast(tok_slice.len));
                var brace_pos: u32 = module_end;
                while (brace_pos < self.ast.source.len) : (brace_pos += 1) {
                    if (self.ast.source[brace_pos] == '{') break;
                }
                // Emit comments before '{'
                try self.writeStr("module");
                var emitted_before = false;
                var i = icr.start;
                while (i < icr.end and i < comments.len) : (i += 1) {
                    if (self.emitted_comments.isSet(i)) continue;
                    const comment = comments[i];
                    if (comment.start < brace_pos) {
                        self.emitted_comments.set(i);
                        try self.space();
                        try self.emitCommentText(comment);
                        emitted_before = true;
                    }
                }
                if (emitted_before) {
                    try self.space();
                } else {
                    try self.space();
                }
                // Emit '{' and comments after '{'
                try self.writeChar('{');
                i = icr.start;
                while (i < icr.end and i < comments.len) : (i += 1) {
                    if (self.emitted_comments.isSet(i)) continue;
                    const comment = comments[i];
                    self.emitted_comments.set(i);
                    if (comment.kind == .line or self.isMultiLineBlock(comment)) {
                        try self.newline();
                        try self.emitCommentText(comment);
                        try self.newline();
                    } else {
                        try self.emitCommentText(comment);
                    }
                }
                try self.writeChar('}');
            } else {
                try self.writeStr("module {}");
            }
            return;
        }
        try self.writeStr("module {\n");
        self.indent();
        const items = self.ast.extra_data.items[range_start..range_end];
        const tags = self.ast.nodes.items(.tag);

        // Count leading directives
        var directive_count: usize = 0;
        for (items) |item| {
            if (tags[item] == .directive) {
                directive_count += 1;
            } else {
                break;
            }
        }

        // Emit directives
        for (items[0..directive_count]) |item| {
            try self.writeIndent();
            try self.emitNode(@enumFromInt(item));
            try self.newline();
        }

        // Blank line after directives if there are body statements
        if (directive_count > 0 and directive_count < items.len) {
            try self.newline();
        }

        for (items[directive_count..]) |item| {
            try self.writeIndent();
            try self.emitNode(@enumFromInt(item));
            try self.newline();
        }
        self.dedent();
        try self.writeIndent();
        try self.writeChar('}');
    }

    // ---------------------------------------------------------------
    // Proposals
    // ---------------------------------------------------------------

    fn emitDecorator(self: *Codegen, data: Node.Data) Error!void {
        try self.writeChar('@');
        try self.emitNode(data.unary);
        try self.newline();
        try self.writeIndent();
    }

    pub fn emitDecorators(self: *Codegen, idx: NodeIndex) Error!void {
        if (self.suppress_decorators) return;
        if (self.ast.decorators_map.get(@intFromEnum(idx))) |dec_range| {
            for (self.ast.extra_data.items[dec_range.start..dec_range.end]) |dec_raw| {
                try self.emitNode(@enumFromInt(dec_raw));
            }
        }
    }

    fn emitPlaceholder(self: *Codegen, idx: NodeIndex, main_token: TokenIndex) Error!void {
        try self.writeStr("%%");
        try self.emitToken(main_token);
        try self.writeStr("%%");
        if (self.ast.placeholder_contexts.get(@intFromEnum(idx))) |ctx| {
            if (std.mem.eql(u8, ctx, "Statement")) {
                try self.semicolon();
            }
        }
    }

    fn emitDoExpression(self: *Codegen, idx: NodeIndex, data: Node.Data) Error!void {
        const is_async = self.ast.async_arrow_flags.contains(@intFromEnum(idx));
        if (is_async) {
            try self.writeStr("async");
            // Emit leading comments on the body that are between 'async' and 'do' in source
            if (data.unary != .none) {
                const async_end = blk: {
                    const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                    const tok_start = self.ast.tokens.items(.start)[@intFromEnum(mt)];
                    const tok_slice = self.ast.tokenSlice(mt);
                    break :blk tok_start + @as(u32, @intCast(tok_slice.len));
                };
                // Find 'do' keyword position
                var do_pos: u32 = async_end;
                while (do_pos + 1 < self.ast.source.len) : (do_pos += 1) {
                    if (self.ast.source[do_pos] == 'd' and self.ast.source[do_pos + 1] == 'o') break;
                }
                try self.emitLeadingCommentsBeforePos(data.unary, do_pos);
            }
            try self.writeStr(" ");
        }
        try self.writeStr("do ");
        // Emit leading comments on body between 'do' and '{' in source
        if (data.unary != .none) {
            const body_start = self.nodeSourceStart(data.unary);
            try self.emitLeadingCommentsBeforePos(data.unary, body_start);
        }
        // For empty blocks with only simple block comments, emit inline
        if (data.unary != .none) {
            const body_tag = self.ast.nodes.items(.tag)[@intFromEnum(data.unary)];
            if (body_tag == .block_statement) {
                const body_data = self.ast.nodes.items(.data)[@intFromEnum(data.unary)];
                const body_extra_idx = @intFromEnum(body_data.extra);
                if (body_extra_idx < self.ast.extra_data.items.len) {
                    const body_range_start = self.ast.extra_data.items[body_extra_idx];
                    const body_range_end = self.ast.extra_data.items[body_extra_idx + 1];
                    if (body_range_start >= body_range_end and self.hasExpandedInnerComments(data.unary) and !self.hasLineInnerComments(data.unary)) {
                        // Empty block with only block comments — emit inline
                        try self.emitExprLeadingComments(data.unary);
                        try self.writeChar('{');
                        try self.emitInnerComments(data.unary);
                        try self.writeChar('}');
                        try self.emitTrailingComments(data.unary);
                        return;
                    }
                }
            }
        }
        try self.emitNode(data.unary);
    }

    fn emitThrowExpression(self: *Codegen, data: Node.Data) Error!void {
        try self.writeStr("throw ");
        try self.emitNode(data.unary);
    }

    fn emitBindExpression(self: *Codegen, data: Node.Data) Error!void {
        if (data.binary.lhs != .none) {
            try self.emitNode(data.binary.lhs);
        }
        try self.writeStr("::");
        try self.emitNode(data.binary.rhs);
    }

    // ---------------------------------------------------------------
    // TS helpers (used by codegen.zig and codegen_ts.zig)
    // ---------------------------------------------------------------

    /// Emit a parameter with TS optional marker and type annotation
    pub fn emitTsParam(self: *Codegen, param: NodeIndex) Error!void {
        if (param == .none) return;
        const param_i = @intFromEnum(param);
        const param_tag = self.ast.nodes.items(.tag)[param_i];

        switch (param_tag) {
            .identifier => {
                try self.emitNode(param);
                if (self.ast.ts_optional_params.contains(param_i)) {
                    try self.writeChar('?');
                }
                if (self.ast.type_annotations.get(param_i)) |ta| {
                    try self.emitNode(ta);
                }
            },
            .assignment_pattern => {
                const ap_data = self.ast.nodes.items(.data)[param_i];
                try self.emitTsParam(ap_data.binary.lhs);
                try self.writeStr(" = ");
                try self.emitNode(ap_data.binary.rhs);
            },
            .rest_element => {
                try self.writeStr("...");
                const re_data = self.ast.nodes.items(.data)[param_i];
                try self.emitTsParam(re_data.unary);
                // Type annotation on the rest element itself
                if (self.ast.type_annotations.get(param_i)) |ta| {
                    try self.emitNode(ta);
                }
            },
            .object_pattern, .array_pattern => {
                try self.emitNode(param);
                if (self.ast.ts_optional_params.contains(param_i)) {
                    try self.writeChar('?');
                }
                if (self.ast.type_annotations.get(param_i)) |ta| {
                    try self.emitNode(ta);
                }
            },
            .ts_parameter_property => {
                try self.emitNode(param);
            },
            .this_expr => {
                // Flow/TS: `this` parameter with type annotation
                try self.emitNode(param);
                if (self.ast.type_annotations.get(param_i)) |ta| {
                    try self.emitNode(ta);
                }
            },
            else => {
                try self.emitNode(param);
            },
        }
    }

    /// Emit comma-separated params with TS annotations
    pub fn emitTsParamList(self: *Codegen, start: u32, end: u32) Error!void {
        const items = self.ast.extra_data.items[start..end];
        for (items, 0..) |item, i| {
            const node_idx: NodeIndex = @enumFromInt(item);
            if (i > 0) {
                try self.writeChar(',');
                // If this param has a leading line comment, put it on a new line
                if (self.checkNodeLeadingLineComment(node_idx)) {
                    try self.newline();
                    try self.writeIndent();
                } else {
                    try self.space();
                }
            }
            try self.emitTsParam(node_idx);
        }
    }

    /// Emit class modifier keywords (declare, abstract) before 'class'
    fn emitClassModifierKeywords(self: *Codegen, idx: NodeIndex) Error!void {
        const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
        if (mods & 32 != 0) { // TS_MOD_DECLARE
            try self.writeStr("declare ");
        }
        if (mods & 16 != 0) { // TS_MOD_ABSTRACT
            try self.writeStr("abstract ");
        }
    }

    /// Emit implements clause for classes
    fn emitImplementsClause(self: *Codegen, idx: NodeIndex) Error!void {
        if (self.ast.implements_list.get(@intFromEnum(idx))) |impl_range| {
            const items = self.ast.extra_data.items[impl_range.start..impl_range.end];
            if (items.len > 0) {
                try self.writeStr(" implements ");
                for (items, 0..) |item, i| {
                    if (i > 0) {
                        try self.writeStr(", ");
                    }
                    const impl_node: NodeIndex = @enumFromInt(item);
                    const impl_tag = self.ast.nodes.items(.tag)[@intFromEnum(impl_node)];
                    if (impl_tag == .ts_type_reference) {
                        const impl_data = self.ast.nodes.items(.data)[@intFromEnum(impl_node)];
                        try self.emitNode(impl_data.binary.lhs);
                        if (impl_data.binary.rhs != .none) {
                            try self.emitNode(impl_data.binary.rhs);
                        }
                    } else {
                        try self.emitNode(impl_node);
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // Stub for unimplemented nodes
    // ---------------------------------------------------------------

    fn emitStub(self: *Codegen) !void {
        try self.writeStr("/* TODO */");
    }

    // ---------------------------------------------------------------
    // Comment emission
    // ---------------------------------------------------------------

    /// Check if the original source has a blank line (2+ newlines with only
    /// whitespace between them) between byte offsets `from` and `to`.
    fn hasBlankLineBetween(self: *Codegen, from: u32, to: u32) bool {
        if (from >= to or to > self.ast.source.len) return false;
        const slice = self.ast.source[from..to];
        var newline_count: u32 = 0;
        for (slice) |c| {
            if (c == '\n') {
                newline_count += 1;
                if (newline_count >= 2) return true;
            } else if (c != '\r' and c != ' ' and c != '\t') {
                newline_count = 0;
            }
        }
        return false;
    }

    /// Emit a single comment's raw text (// or /* ... */).
    pub fn emitCommentText(self: *Codegen, comment: Comment) !void {
        if (comment.kind == .line) {
            try self.writeStr("//");
            try self.writeStr(self.ast.source[comment.value_start..comment.value_end]);
        } else {
            const text = self.ast.source[comment.value_start..comment.value_end];
            if (std.mem.indexOfScalar(u8, text, '\n') == null) {
                // Single-line block comment — emit as-is
                try self.writeStr("/*");
                try self.writeStr(text);
                try self.writeStr("*/");
            } else {
                // Multi-line block comment — re-align continuation lines
                // Preserve original relative alignment between /* and continuation
                const orig_col = self.getOriginalColumn(comment.start);
                const output_col = self.current_col;
                try self.writeStr("/*");
                var lines = std.mem.splitScalar(u8, text, '\n');
                if (lines.next()) |first_line| {
                    try self.writeStr(first_line);
                }
                while (lines.next()) |line| {
                    try self.newline();
                    const trimmed = std.mem.trimStart(u8, line, " \t");
                    const orig_leading: u32 = @intCast(line.len - trimmed.len);
                    // Shift by difference between output column and original column
                    const delta: i64 = @as(i64, output_col) - @as(i64, orig_col);
                    const shifted: u32 = if (delta >= 0)
                        orig_leading + @as(u32, @intCast(delta))
                    else if (orig_leading >= @as(u32, @intCast(-delta)))
                        orig_leading - @as(u32, @intCast(-delta))
                    else
                        0;
                    // Ensure at least output_col alignment (min column of /*)
                    const new_leading: u32 = @max(shifted, output_col);
                    var j: u32 = 0;
                    while (j < new_leading) : (j += 1) {
                        try self.writeChar(' ');
                    }
                    try self.writeStr(trimmed);
                }
                try self.writeStr("*/");
            }
        }
    }

    /// Get the column (0-indexed) of a source position.
    fn getOriginalColumn(self: *Codegen, pos: u32) u32 {
        if (pos == 0) return 0;
        var col: u32 = 0;
        var i: u32 = pos;
        while (i > 0) {
            i -= 1;
            if (self.ast.source[i] == '\n') break;
            col += 1;
        }
        return col;
    }

    /// Find the position of a character in source starting from a given position.
    fn findCharInSource(self: *Codegen, from: u32, ch: u8) u32 {
        var pos = from;
        while (pos < self.ast.source.len) : (pos += 1) {
            // Skip block comments
            if (pos + 1 < self.ast.source.len and self.ast.source[pos] == '/' and self.ast.source[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < self.ast.source.len) : (pos += 1) {
                    if (self.ast.source[pos] == '*' and self.ast.source[pos + 1] == '/') {
                        pos += 1;
                        break;
                    }
                }
                continue;
            }
            if (self.ast.source[pos] == ch) return pos;
        }
        return pos;
    }

    /// Find the closing ')' that matches an opening '(' at the given position.
    fn findMatchingParen(self: *Codegen, open_pos: u32) u32 {
        if (open_pos >= self.ast.source.len or self.ast.source[open_pos] != '(') return open_pos;
        var pos = open_pos + 1;
        var depth: u32 = 0;
        while (pos < self.ast.source.len) : (pos += 1) {
            if (self.ast.source[pos] == '(') {
                depth += 1;
            } else if (self.ast.source[pos] == ')') {
                if (depth == 0) return pos;
                depth -= 1;
            }
        }
        return pos;
    }

    /// Check if a node has any leading or trailing comments with source position inside a range.
    fn hasCommentsInsideRange(self: *Codegen, node_idx: NodeIndex, range_start: u32, range_end: u32) bool {
        const key = @intFromEnum(node_idx);
        // Check leading comments
        if (self.ast.leading_comments.get(key)) |range| {
            const comments = self.ast.comments.items;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                if (!self.emitted_comments.isSet(i)) {
                    const comment = comments[i];
                    if (comment.start >= range_start and comment.end <= range_end) return true;
                }
            }
        }
        // Check trailing comments
        if (self.ast.trailing_comments.get(key)) |range| {
            const comments = self.ast.comments.items;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                if (!self.emitted_comments.isSet(i)) {
                    const comment = comments[i];
                    if (comment.start >= range_start and comment.end <= range_end) return true;
                }
            }
        }
        return false;
    }

    /// Emit leading comments on a node in a range, returning true if any were emitted.
    fn emitLeadingCommentsInRangeCheck(self: *Codegen, node_idx: NodeIndex, range_start: u32, range_end: u32) bool {
        const key = @intFromEnum(node_idx);
        const range = self.ast.leading_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;

        var emitted = false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.start >= range_start and comment.end <= range_end) {
                self.emitted_comments.set(i);
                self.space() catch {};
                self.emitCommentText(comment) catch {};
                emitted = true;
            }
        }
        return emitted;
    }

    /// Emit leading comments on a node that are within a source position range.
    fn emitLeadingCommentsInRange(self: *Codegen, node_idx: NodeIndex, range_start: u32, range_end: u32) Error!void {
        const key = @intFromEnum(node_idx);
        const range = self.ast.leading_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.start >= range_start and comment.end <= range_end) {
                self.emitted_comments.set(i);
                try self.space();
                try self.emitCommentText(comment);
            }
        }
    }

    /// Mark all comments in a source range as emitted (to prevent double-emission).
    fn markAllCommentsInRange(self: *Codegen, after_pos: u32, before_pos: u32) void {
        const comments = self.ast.comments.items;
        for (comments, 0..) |comment, ci| {
            if (comment.start >= after_pos and comment.end <= before_pos) {
                self.emitted_comments.set(ci);
            }
        }
    }

    /// Emit comments in a source range without adding a leading space.
    /// Instead, emits each comment's text directly.
    fn emitCommentsBetweenNoSpace(self: *Codegen, after_pos: u32, before_pos: u32) Error!void {
        const comments = self.ast.comments.items;
        var first = true;
        for (comments) |comment| {
            if (comment.start >= after_pos and comment.end <= before_pos) {
                // Add space before first comment if buffer doesn't already end with whitespace
                if (first) {
                    if (self.buf.items.len > 0) {
                        const last = self.buf.items[self.buf.items.len - 1];
                        if (last != ' ' and last != '\n' and last != '\t') {
                            try self.space();
                        }
                    }
                    first = false;
                }
                try self.emitCommentText(comment);
            }
        }
    }

    /// Check if there are any unemitted comments in a source range.
    fn hasCommentsBetween(self: *Codegen, after_pos: u32, before_pos: u32) bool {
        const comments = self.ast.comments.items;
        for (comments, 0..) |comment, ci| {
            if (self.emitted_comments.isSet(ci)) continue;
            if (comment.start >= after_pos and comment.end <= before_pos) return true;
        }
        return false;
    }

    /// Check if there are any comments in a source range (ignoring emitted flag).
    fn hasAnyCommentsBetween(self: *Codegen, after_pos: u32, before_pos: u32) bool {
        const comments = self.ast.comments.items;
        for (comments) |comment| {
            if (comment.start >= after_pos and comment.end <= before_pos) return true;
        }
        return false;
    }

    /// Check if there are multi-line block comments in a source range.
    fn hasMultiLineCommentsBetween(self: *Codegen, after_pos: u32, before_pos: u32) bool {
        const comments = self.ast.comments.items;
        for (comments, 0..) |comment, ci| {
            if (self.emitted_comments.isSet(ci)) continue;
            if (comment.start >= after_pos and comment.end <= before_pos) {
                if (comment.kind == .block and self.isMultiLineBlock(comment)) return true;
            }
        }
        return false;
    }

    /// Check if a comment is a multi-line block comment (contains newlines).
    fn isMultiLineBlock(self: *Codegen, comment: Comment) bool {
        if (comment.kind != .block) return false;
        const text = self.ast.source[comment.value_start..comment.value_end];
        return std.mem.indexOfScalar(u8, text, '\n') != null;
    }

    /// Get the source byte offset for the start of a node (from its main_token).
    fn nodeSourceStart(self: *Codegen, idx: NodeIndex) u32 {
        const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
        return self.ast.tokens.items(.start)[@intFromEnum(mt)];
    }

    /// Get the source byte offset for the end of a node.
    fn nodeSourceEnd(self: *Codegen, idx: NodeIndex) u32 {
        return self.ast.nodes.items(.end_offset)[@intFromEnum(idx)];
    }

    /// Emit leading comments for a statement-level node.
    /// Must be called BEFORE the caller writes the indent for the node.
    /// The cursor should be at the beginning of a new line (col 0).
    /// After this function, the cursor will be at col 0 of a new line,
    /// ready for the caller to write indent + node.
    fn emitStatementLeadingComments(self: *Codegen, idx: NodeIndex, prev_end: u32) !void {
        return self.emitStatementLeadingCommentsImpl(idx, prev_end, true);
    }

    fn emitStatementLeadingCommentsNoBlank(self: *Codegen, idx: NodeIndex, prev_end: u32) !void {
        return self.emitStatementLeadingCommentsImpl(idx, prev_end, false);
    }

    fn emitStatementLeadingCommentsImpl(self: *Codegen, idx: NodeIndex, prev_end: u32, allow_leading_blank: bool) Error!void {
        return self.emitStatementLeadingCommentsImplEx(idx, prev_end, allow_leading_blank, false);
    }

    fn emitStatementLeadingCommentsImplEx(self: *Codegen, idx: NodeIndex, prev_end: u32, allow_leading_blank: bool, prev_had_trailing: bool) Error!void {
        self.leading_comment_was_inline = false;
        var target_idx = idx;
        if (self.ast.leading_comments.get(@intFromEnum(target_idx)) == null and
            self.ast.nodes.items(.tag)[@intFromEnum(idx)] == .expression_statement)
        {
            const expr = self.ast.nodes.items(.data)[@intFromEnum(idx)].unary;
            if (expr != .none and self.ast.leading_comments.get(@intFromEnum(expr)) != null) {
                target_idx = expr;
            }
        }
        const node_start = self.nodeSourceStart(target_idx);
        const had_output_blank_before_comments = self.endsWithBlankLine();
        const key = @intFromEnum(target_idx);
        const range = self.ast.leading_comments.get(key) orelse {
            // No leading comments — but if the previous statement had trailing
            // comments, check for blank line between prev_end and this node.
            if (prev_had_trailing and allow_leading_blank and self.hasBlankLineBetween(prev_end, node_start)) {
                try self.newline();
            }
            return;
        };
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) {
            if (prev_had_trailing and allow_leading_blank and self.hasBlankLineBetween(prev_end, node_start)) {
                try self.newline();
            }
            return;
        }

        // Check if all comments were already emitted
        var has_unemitted = false;
        {
            var ci = range.start;
            while (ci < range.end and ci < comments.len) : (ci += 1) {
                if (!self.emitted_comments.isSet(ci)) {
                    has_unemitted = true;
                    break;
                }
            }
        }
        if (!has_unemitted) {
            if (prev_had_trailing and allow_leading_blank and self.hasBlankLineBetween(prev_end, node_start)) {
                try self.newline();
            }
            return;
        }

        var cur_prev_end = prev_end;
        var emitted_any = false;
        var last_was_inline = false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            self.emitted_comments.set(i);
            const comment = comments[i];

            // Check for blank line before this comment.
            // For the first comment, only if allow_leading_blank is true.
            const check_blank = if (!emitted_any) allow_leading_blank else true;
            if (check_blank and self.hasBlankLineBetween(cur_prev_end, comment.start)) {
                if (last_was_inline) {
                    try self.newline();
                    last_was_inline = false;
                }
                try self.newline();
            }

            // Single-line block comments on the same source line as the statement:
            // emit inline (like Babel does for /*0*/import(...))
            // But if the comment starts on a new source line relative to
            // previous content (not just the block's opening brace),
            // emit it on its own line.
            const comment_on_new_line_from_content = !emitted_any and
                cur_prev_end > 0 and self.hasNewlineBetween(cur_prev_end, comment.start) and
                !self.isAtBlockOpening(cur_prev_end);
            const is_inline_block = comment.kind == .block and
                !self.isMultiLineBlock(comment) and
                !self.hasNewlineBetween(comment.end, node_start) and
                !comment_on_new_line_from_content;
            if (is_inline_block) {
                if (!last_was_inline) {
                    try self.writeIndent();
                }
                try self.emitCommentText(comment);
                last_was_inline = true;
            } else {
                if (last_was_inline) {
                    try self.newline();
                    last_was_inline = false;
                }
                try self.writeIndent();
                try self.emitCommentText(comment);
                try self.newline();
            }

            cur_prev_end = comment.end;
            emitted_any = true;
        }

        if (emitted_any) {
            if (last_was_inline) {
                // Signal to caller that the last comment was inline — don't add indent
                self.leading_comment_was_inline = true;
            } else if (!(had_output_blank_before_comments and !allow_leading_blank) and
                self.hasBlankLineBetween(cur_prev_end, node_start))
            {
                try self.newline();
            }
        }
    }

    fn endsWithBlankLine(self: *Codegen) bool {
        var newline_count: u32 = 0;
        var i = self.buf.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.buf.items[i];
            switch (c) {
                '\n' => {
                    newline_count += 1;
                    if (newline_count >= 2) return true;
                },
                ' ', '\t', '\r' => continue,
                else => return false,
            }
        }
        return false;
    }

    /// Emit leading comments for an expression-level node (inline).
    pub fn emitExprLeadingComments(self: *Codegen, idx: NodeIndex) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;
        const node_start = self.nodeSourceStart(idx);

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            self.emitted_comments.set(i);
            const comment = comments[i];
            try self.emitCommentText(comment);
            // Line comments always need newline (they consume rest of line)
            // Multi-line block comments also need newline + indent.
            // Single-line block comments that were on their own source line
            // should stay statement-like rather than gluing to the expression.
            if (comment.kind == .line) {
                try self.newline();
                try self.writeIndent();
            } else if (self.isMultiLineBlock(comment) or self.hasNewlineBetween(comment.end, node_start)) {
                try self.newline();
                try self.writeIndent();
            }
        }
    }

    /// Emit trailing comments for a node (same-line only from emitNode).
    /// Different-line trailing comments are left for statement list emitters.
    pub fn emitTrailingComments(self: *Codegen, idx: NodeIndex) !void {
        if (self.suppress_trailing_comments) return;
        const key = @intFromEnum(idx);
        const range = self.ast.trailing_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        const node_end = self.nodeSourceEnd(idx);

        var i = range.start;
        var prev_was_line = false;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];

            // Only emit same-line trailing comments
            const same_line = !self.hasNewlineBetween(node_end, comment.start);
            if (same_line) {
                // Skip comments past the source limit (e.g., after ')' in for-statements)
                if (self.trailing_comment_source_limit > 0 and comment.start >= self.trailing_comment_source_limit) continue;
                self.emitted_comments.set(i);
                // After a line comment, subsequent comments go on new lines
                if (prev_was_line) {
                    try self.newline();
                } else {
                    try self.space();
                }
                try self.emitCommentText(comment);
                prev_was_line = (comment.kind == .line);
            }
        }
    }

    /// Emit all unemitted trailing comments on a node, including different-line ones.
    /// Used when we need to capture trailing comments inside parens before closing.
    pub fn emitAllTrailingComments(self: *Codegen, idx: NodeIndex) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.trailing_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            self.emitted_comments.set(i);
            const comment = comments[i];
            // Emit on a new line (inside parens)
            try self.newline();
            try self.emitCommentText(comment);
        }
    }

    /// Emit all unemitted inner comments on a node, each on a new line.
    /// Used when we need to capture inner comments inside explicit parens.
    pub fn emitAllInnerComments(self: *Codegen, idx: NodeIndex) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.inner_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            self.emitted_comments.set(i);
            const comment = comments[i];
            try self.newline();
            try self.emitCommentText(comment);
        }
    }

    /// Emit ALL remaining unemitted comments whose original source position
    /// falls near the given statement. Used after a full statement (including
    /// semicolon) has been emitted, to catch "deep" trailing comments that
    /// were deferred by emitTrailingComments.
    /// Emit any unemitted trailing comments attached to this statement node
    /// (including different-line ones that were deferred by emitTrailingComments).
    /// Also scans for unemitted trailing comments on all entries in the map that
    /// fall within this statement's source range.
    pub fn emitRemainingStatementComments(self: *Codegen, stmt_idx: NodeIndex) !void {
        const comments = self.ast.comments.items;
        const stmt_end = self.nodeSourceEnd(stmt_idx);

        // 1. Emit any unemitted trailing comments directly on this statement
        if (self.ast.trailing_comments.get(@intFromEnum(stmt_idx))) |range| {
            var prev_comment_end = stmt_end;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                if (self.emitted_comments.isSet(i)) continue;
                self.emitted_comments.set(i);
                const comment = comments[i];
                const same_line = !self.hasNewlineBetween(stmt_end, comment.start);
                if (same_line) {
                    try self.space();
                    try self.emitCommentText(comment);
                } else {
                    // Check for blank line before comment
                    if (self.hasBlankLineBetween(prev_comment_end, comment.start)) {
                        try self.newline();
                    }
                    try self.newline();
                    try self.writeIndent();
                    try self.emitCommentText(comment);
                }
                prev_comment_end = comment.end;
            }
        }

        // 2. Scan for unemitted trailing comments on descendant nodes.
        //    A descendant node's trailing comment should be within or just after
        //    the statement's source range.
        const stmt_start = self.nodeSourceStart(stmt_idx);
        var it = self.ast.trailing_comments.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == @intFromEnum(stmt_idx)) continue; // Already handled
            // The node must be within the statement's range
            const descendant_start = self.ast.tokens.items(.start)[@intFromEnum(self.ast.nodes.items(.main_token)[entry.key_ptr.*])];
            if (descendant_start < stmt_start or descendant_start > stmt_end) continue;

            const range = entry.value_ptr.*;
            var prev_desc_end = stmt_end;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                if (self.emitted_comments.isSet(i)) continue;
                const comment = comments[i];
                self.emitted_comments.set(i);
                const same_line = !self.hasNewlineBetween(stmt_end, comment.start);
                if (same_line) {
                    try self.space();
                    try self.emitCommentText(comment);
                } else {
                    if (self.hasBlankLineBetween(prev_desc_end, comment.start)) {
                        try self.newline();
                    }
                    try self.newline();
                    try self.writeIndent();
                    try self.emitCommentText(comment);
                }
                prev_desc_end = comment.end;
            }
        }
    }

    /// Get the source-end offset of the last trailing comment on a statement,
    /// or the statement's own end if it has no trailing comments.
    /// Used to compute `prev_end` for blank-line checks between statements.
    pub fn getStatementEndWithTrailingComments(self: *Codegen, stmt_idx: NodeIndex) u32 {
        const stmt_end = self.nodeSourceEnd(stmt_idx);
        var max_end = stmt_end;

        // Check direct trailing comments
        if (self.ast.trailing_comments.get(@intFromEnum(stmt_idx))) |range| {
            const comments = self.ast.comments.items;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                // For line comments, use value_end (before newline) to avoid
                // consuming the newline that separates statements.
                const ce = if (comments[i].kind == .line) comments[i].value_end else comments[i].end;
                if (ce > max_end) {
                    max_end = ce;
                }
            }
        }

        // Check trailing comments on descendant nodes within this statement
        const stmt_start = self.nodeSourceStart(stmt_idx);
        var it = self.ast.trailing_comments.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == @intFromEnum(stmt_idx)) continue;
            const descendant_start = self.ast.tokens.items(.start)[@intFromEnum(self.ast.nodes.items(.main_token)[entry.key_ptr.*])];
            if (descendant_start < stmt_start or descendant_start > stmt_end) continue;
            const range = entry.value_ptr.*;
            const comments = self.ast.comments.items;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                const ce = if (comments[i].kind == .line) comments[i].value_end else comments[i].end;
                if (ce > max_end) {
                    max_end = ce;
                }
            }
        }

        return max_end;
    }

    /// Emit preserved comments from a removed statement node.
    /// When a type-only statement (e.g., `export type Foo = ...`) is removed,
    /// its leading and trailing comments (e.g., JSDoc) should still appear in output.
    /// Uses source-position scanning to find ALL comments in the gap between
    /// prev_end and the removed node's end (including trailing comments).
    /// Returns true if any comments were emitted.
    const RemovedCommentsResult = struct {
        emitted_any: bool = false,
        preserved_trailing_gap: bool = false,
    };

    fn emitRemovedNodePreservedComments(self: *Codegen, rm_idx: NodeIndex, prev_end: u32, prev_had_comments: bool) Error!RemovedCommentsResult {
        // Only preserve comments from removed export/import statements.
        // Other removed nodes (type-only namespaces, declare classes, etc.) should
        // have their comments suppressed, matching Babel's behavior.
        const rm_start = self.nodeSourceStart(rm_idx);
        if (!self.isRemovedExportOrImport(rm_start)) {
            // Mark comments as emitted (suppress them) for non-export/import removed nodes
            const rm_end_with_trailing = self.getStatementEndWithTrailingComments(rm_idx);
            const comments2 = self.ast.comments.items;
            for (comments2, 0..) |comment, ci| {
                if (self.emitted_comments.isSet(ci)) continue;
                if (comment.start < prev_end) continue;
                if (comment.start > rm_end_with_trailing) continue;
                self.emitted_comments.set(ci);
            }
            return .{};
        }

        const comments = self.ast.comments.items;
        const rm_end_with_trailing = self.getStatementEndWithTrailingComments(rm_idx);

        // For export/import removed nodes, clear the emitted flag on comments in range
        // so that program-level suppression doesn't prevent their emission.
        for (comments, 0..) |comment, ci| {
            if (comment.start < prev_end) continue;
            if (comment.start > rm_end_with_trailing) continue;
            if (self.emitted_comments.isSet(ci)) {
                self.emitted_comments.unset(ci);
            }
        }

        // Scan all comments whose source position falls between prev_end and the
        // removed node's end (including trailing comments). Emit them as standalone lines.
        var result: RemovedCommentsResult = .{};
        var last_emitted_end = prev_end;
        var last_comment_was_line = false;
        for (comments, 0..) |comment, ci| {
            if (self.emitted_comments.isSet(ci)) continue;
            // Comment must be after prev_end and before (or at) the removed node's end
            if (comment.start < prev_end) continue;
            if (comment.start > rm_end_with_trailing) continue;

            self.emitted_comments.set(ci);

            // Check for blank line before this comment.
            // Also add a separator between comment groups from different removed statements.
            // But don't emit a leading blank line when nothing has been output yet.
            if (self.buf.items.len > 0) {
                if (!result.emitted_any and prev_had_comments) {
                    // First comment from this removed node, but previous node also had comments.
                    // Add a blank line separator (Babel behavior).
                    try self.newline();
                } else if (self.hasBlankLineBetween(last_emitted_end, comment.start)) {
                    try self.newline();
                }
            }
            try self.writeIndent();
            try self.emitCommentText(comment);
            try self.newline();
            last_emitted_end = comment.end;
            result.emitted_any = true;
            last_comment_was_line = comment.kind == .line;
        }

        // If the removed statement had source lines after the last preserved comment,
        // preserve that vertical gap so the next surviving statement doesn't collapse
        // up against line comments. Block comments/JSDoc should stay tight.
        if (result.emitted_any and last_comment_was_line and last_emitted_end < rm_end_with_trailing and self.hasNewlineBetween(last_emitted_end, rm_end_with_trailing)) {
            try self.newline();
            result.preserved_trailing_gap = true;
        }
        return result;
    }

    /// Check if a removed node was originally an export or import statement
    /// by inspecting the source text at its main_token position.
    fn isRemovedExportOrImport(self: *Codegen, src_start: u32) bool {
        const source = self.ast.source;
        if (src_start + 6 <= source.len and std.mem.eql(u8, source[src_start .. src_start + 6], "export")) return true;
        if (src_start + 6 <= source.len and std.mem.eql(u8, source[src_start .. src_start + 6], "import")) return true;
        return false;
    }

    /// Check if a source position is at or right after a block opening brace '{'.
    fn isAtBlockOpening(self: *Codegen, pos: u32) bool {
        if (pos >= self.ast.source.len) return false;
        // Check if the character at pos itself is '{'
        if (self.ast.source[pos] == '{') return true;
        // Check if the last non-whitespace at or before pos is '{'
        var p = pos;
        while (p > 0) {
            p -= 1;
            const c = self.ast.source[p];
            if (c == '{') return true;
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return false;
        }
        return false;
    }

    /// Check if there is any newline between `from` and `to` in original source.
    fn hasNewlineBetween(self: *Codegen, from: u32, to: u32) bool {
        if (from >= to or to > self.ast.source.len) return false;
        const slice = self.ast.source[from..to];
        return std.mem.indexOfScalar(u8, slice, '\n') != null;
    }

    /// Emit inner comments on a node that are before a given source position.
    pub fn emitInnerCommentsBefore(self: *Codegen, idx: NodeIndex, before_pos: u32) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.inner_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.start < before_pos) {
                self.emitted_comments.set(i);
                try self.space();
                try self.emitCommentText(comment);
            }
        }
    }

    /// Check if a node has multiple (2+) unemitted inner comments.
    pub fn hasMultipleInnerComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.inner_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var count: u32 = 0;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i)) {
                count += 1;
                if (count >= 2) return true;
            }
        }
        return false;
    }

    /// Check if a node's inner comments need expanded block layout.
    /// Block statements always expand inner comments.
    pub fn hasExpandedInnerComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.inner_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i)) return true;
        }
        return false;
    }

    /// Check if a node's inner comments include any line comments.
    pub fn hasLineInnerComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.inner_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i) and comments[i].kind == .line) return true;
        }
        return false;
    }

    /// Check if a node's inner comments include any multi-line block comments.
    pub fn hasMultiLineInnerComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.inner_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i) and comments[i].kind == .block and self.isMultiLineBlock(comments[i])) return true;
        }
        return false;
    }

    /// Check if a node has 2+ unemitted leading comments.
    pub fn hasMultipleLeadingComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var count: u32 = 0;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i)) {
                count += 1;
                if (count >= 2) return true;
            }
        }
        return false;
    }

    /// Check if a node's trailing comments include any multi-line block comments.
    pub fn hasMultiLineTrailingComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.trailing_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i) and comments[i].kind == .block and self.isMultiLineBlock(comments[i])) return true;
        }
        return false;
    }

    /// Check if a node's leading comments include any multi-line block comments.
    pub fn hasMultiLineLeadingComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i) and comments[i].kind == .block and self.isMultiLineBlock(comments[i])) return true;
        }
        return false;
    }

    /// Emit inner comments for a node (e.g., inside empty block `{}`).
    pub fn emitInnerComments(self: *Codegen, idx: NodeIndex) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.inner_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            self.emitted_comments.set(i);
            const comment = comments[i];
            if (comment.kind == .line) {
                try self.emitCommentText(comment);
                try self.newline();
            } else {
                try self.emitCommentText(comment);
            }
        }
    }

    /// Emit leading comments on a node that are positioned before a given source position.
    fn emitLeadingCommentsBeforePos(self: *Codegen, idx: NodeIndex, before_pos: u32) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.end <= before_pos) {
                self.emitted_comments.set(i);
                // Add space before comment if buffer doesn't already end with one
                if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] != ' ') {
                    try self.space();
                }
                try self.emitCommentText(comment);
            }
        }
    }

    /// Check if a node has a leading PURE annotation comment
    /// (e.g., `@__PURE__`, `#__PURE__`, `@__INLINE__`, `#__INLINE__`).
    fn hasPureAnnotationComment(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.kind != .line) {
                const text = self.ast.source[comment.start..comment.end];
                if (std.mem.indexOf(u8, text, "@__PURE__") != null or
                    std.mem.indexOf(u8, text, "#__PURE__") != null or
                    std.mem.indexOf(u8, text, "@__INLINE__") != null or
                    std.mem.indexOf(u8, text, "#__INLINE__") != null)
                {
                    return true;
                }
            }
        }
        return false;
    }

    /// Find the opening paren '(' in source after the key node in a method definition.
    fn findOpenParen(self: *Codegen, _: NodeIndex, key: NodeIndex) u32 {
        const key_end = self.nodeSourceEnd(key);
        var k: u32 = key_end;
        while (k < self.ast.source.len) : (k += 1) {
            if (self.ast.source[k] == '(') return k;
        }
        return key_end;
    }

    /// Find the closing paren ')' in source before the body of a method definition.
    fn findCloseParen(self: *Codegen, _: NodeIndex, body: NodeIndex) u32 {
        const body_start = self.nodeSourceStart(body);
        if (body_start == 0) return 0;
        var k: u32 = body_start;
        while (k > 0) {
            k -= 1;
            if (self.ast.source[k] == ')') return k;
        }
        return 0;
    }

    /// Emit trailing comments on a node that are positioned before a given source position.
    fn emitTrailingCommentsBeforePos(self: *Codegen, idx: NodeIndex, before_pos: u32) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.trailing_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.start < before_pos) {
                self.emitted_comments.set(i);
                try self.space();
                try self.emitCommentText(comment);
            }
        }
    }

    /// Emit trailing comments on a node that are between two source positions.
    fn emitTrailingCommentsBetweenPos(self: *Codegen, idx: NodeIndex, after_pos: u32, before_pos: u32) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.trailing_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.start > after_pos and comment.end <= before_pos) {
                self.emitted_comments.set(i);
                // Add space before comment if buffer doesn't end with space or '('
                if (self.buf.items.len > 0) {
                    const last = self.buf.items[self.buf.items.len - 1];
                    if (last != ' ' and last != '(') {
                        try self.space();
                    }
                }
                try self.emitCommentText(comment);
            }
        }
    }

    /// Emit trailing comments on a node that are positioned after a given source position.
    fn emitTrailingCommentsAfterPos(self: *Codegen, idx: NodeIndex, after_pos: u32) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.trailing_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.start >= after_pos) {
                self.emitted_comments.set(i);
                try self.space();
                try self.emitCommentText(comment);
            }
        }
    }

    /// Emit deferred trailing comments of a directive as statement-level comments.
    /// Used when a directive's trailing comments should appear after a blank line
    /// rather than on the same line as the directive.
    fn emitDeferredTrailingComments(self: *Codegen, stmt_idx: NodeIndex) Error!void {
        const comments = self.ast.comments.items;
        var emitted_any = false;
        var needs_newline = false;
        for (comments, 0..) |comment, ci| {
            if (self.emitted_comments.isSet(ci)) continue;
            // Check if it's in the trailing comments of this node or descendants
            if (!self.isTrailingCommentOf(stmt_idx, @intCast(ci))) continue;

            self.emitted_comments.set(ci);
            if (!emitted_any) {
                try self.writeIndent();
                emitted_any = true;
            } else if (needs_newline) {
                try self.newline();
                try self.writeIndent();
            } else {
                try self.space();
            }
            try self.emitCommentText(comment);
            needs_newline = comment.kind == .line or self.isMultiLineBlock(comment);
        }
        if (emitted_any) {
            try self.newline();
        }
    }

    /// Check if a comment index is in the trailing comments of a statement or its descendants.
    fn isTrailingCommentOf(self: *Codegen, stmt_idx: NodeIndex, ci: u32) bool {
        const stmt_end = self.nodeSourceEnd(stmt_idx);
        const stmt_start = self.nodeSourceStart(stmt_idx);
        // Check direct trailing
        if (self.ast.trailing_comments.get(@intFromEnum(stmt_idx))) |range| {
            if (ci >= range.start and ci < range.end) return true;
        }
        // Check descendants
        var it = self.ast.trailing_comments.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == @intFromEnum(stmt_idx)) continue;
            const desc_start = self.ast.tokens.items(.start)[@intFromEnum(self.ast.nodes.items(.main_token)[entry.key_ptr.*])];
            if (desc_start < stmt_start or desc_start > stmt_end) continue;
            const range = entry.value_ptr.*;
            if (ci >= range.start and ci < range.end) return true;
        }
        return false;
    }

    /// Emit ALL unemitted comments (from any comment map) whose source positions
    /// fall within [after_pos, before_pos). Used for inter-keyword comments.
    pub fn emitAllCommentsBetween(self: *Codegen, after_pos: u32, before_pos: u32) Error!void {
        const comments = self.ast.comments.items;
        for (comments, 0..) |comment, ci| {
            if (self.emitted_comments.isSet(ci)) continue;
            if (comment.start >= after_pos and comment.end <= before_pos) {
                self.emitted_comments.set(ci);
                try self.space();
                try self.emitCommentText(comment);
            }
        }
    }

    /// Emit inner comments on a class method that are between the 'async'
    /// keyword and the next structural token (* or key).
    fn emitMethodInnerCommentsBefore(self: *Codegen, method_idx: NodeIndex, key: NodeIndex, is_generator: bool, is_computed: bool) !void {
        // Check for inner comments on the method node
        const method_key = @intFromEnum(method_idx);
        const range = self.ast.inner_comments.get(method_key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        // Find the position limit: before the '*' or '[' or key start
        const key_start = self.nodeSourceStart(key);
        _ = is_generator;
        _ = is_computed;

        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.end <= key_start) {
                self.emitted_comments.set(i);
                try self.emitCommentText(comment);
                try self.space();
            }
        }
    }

    /// Emit leading comments on a child node that are positioned before
    /// a structural delimiter (like `(`) in the source. These are comments
    /// that appear between a keyword and the opening paren, e.g., `import /*c*/ (`.
    /// The parent's keyword end position is determined from its main_token.
    pub fn emitPreParenLeadingComments(self: *Codegen, parent_idx: NodeIndex, child_idx: NodeIndex) !void {
        if (child_idx == .none) return;
        const key = @intFromEnum(child_idx);
        const range = self.ast.leading_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        // Find the parent's keyword end position
        const parent_main_tok = self.ast.nodes.items(.main_token)[@intFromEnum(parent_idx)];
        const tok_start = self.ast.tokens.items(.start)[@intFromEnum(parent_main_tok)];
        const tok_slice = self.ast.tokenSlice(parent_main_tok);
        const keyword_end = tok_start + @as(u32, @intCast(tok_slice.len));

        // Find the opening paren '(' between keyword end and the first child
        const child_start = self.nodeSourceStart(child_idx);
        const paren_pos = blk: {
            var k: u32 = keyword_end;
            while (k < child_start and k < self.ast.source.len) : (k += 1) {
                if (self.ast.source[k] == '(') break :blk k;
            }
            break :blk child_start; // no paren found, use child_start as limit
        };

        // Emit leading comments on child that are between the keyword and the paren
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const comment = comments[i];
            if (comment.start >= keyword_end and comment.end <= paren_pos) {
                self.emitted_comments.set(i);
                try self.space();
                try self.emitCommentText(comment);
            }
        }
    }

    /// Emit inner comments of a block/class body after all items.
    /// These are comments inside the body that come after the last child.
    /// `prev_end` is the end offset of the last body item.
    pub fn emitBlockInnerComments(self: *Codegen, body_idx: NodeIndex, prev_end: u32) !void {
        const key = @intFromEnum(body_idx);
        const range = self.ast.inner_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var cur_prev_end = prev_end;
        var line_started = false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            self.emitted_comments.set(i);
            const comment = comments[i];

            // Check if this comment is on the same line as the previous
            const same_line = !self.hasNewlineBetween(cur_prev_end, comment.start);
            if (same_line and line_started) {
                // Same line as previous comment — emit with space separator
                try self.space();
                try self.emitCommentText(comment);
            } else {
                // Different line — check for blank line before this comment
                if (line_started) {
                    // End the previous line
                    try self.newline();
                }
                if (self.hasBlankLineBetween(cur_prev_end, comment.start)) {
                    try self.newline();
                }
                try self.writeIndent();
                try self.emitCommentText(comment);
                line_started = true;
            }

            cur_prev_end = comment.end;
        }
        if (line_started) {
            try self.newline();
        }
    }

    /// Emit inner comments of Program (comments after all body items,
    /// or in an empty program).
    fn emitProgramInnerComments(self: *Codegen, idx: NodeIndex) !void {
        const key = @intFromEnum(idx);
        const range = self.ast.inner_comments.get(key) orelse return;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return;

        var prev_end: u32 = 0;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            self.emitted_comments.set(i);
            const comment = comments[i];

            // Check for blank line before this comment
            if (self.hasBlankLineBetween(prev_end, comment.start)) {
                try self.newline();
            }

            try self.emitCommentText(comment);
            if (comment.kind == .line) {
                try self.newline();
            } else {
                // Block comments: check if more comments follow
                if (i + 1 < range.end and i + 1 < comments.len) {
                    try self.newline();
                }
            }
            prev_end = comment.end;
        }
    }

    /// Check if a node has any unemitted leading LINE comment.
    /// Used by return/throw to decide if the argument needs parens.
    /// Unwraps parenthesized_expr to check the inner expression too.
    pub fn hasLeadingLineComment(self: *Codegen, idx: NodeIndex) bool {
        if (self.checkNodeLeadingLineComment(idx)) return true;
        // Unwrap parenthesized_expr
        const tags = self.ast.nodes.items(.tag);
        const datas = self.ast.nodes.items(.data);
        var cur = idx;
        while (tags[@intFromEnum(cur)] == .parenthesized_expr) {
            cur = datas[@intFromEnum(cur)].unary;
            if (cur == .none) break;
            if (self.checkNodeLeadingLineComment(cur)) return true;
        }
        return false;
    }

    /// Check if a node has any unemitted trailing LINE comment.
    /// Used to decide if an expression needs wrapping in parens to prevent
    /// a trailing line comment from consuming subsequent keywords.
    /// Unwraps parenthesized_expr to check the inner expression too.
    pub fn hasTrailingLineComment(self: *Codegen, idx: NodeIndex) bool {
        if (self.checkNodeTrailingLineComment(idx)) return true;
        // Unwrap parenthesized_expr
        const tags = self.ast.nodes.items(.tag);
        const datas = self.ast.nodes.items(.data);
        var cur = idx;
        while (tags[@intFromEnum(cur)] == .parenthesized_expr) {
            cur = datas[@intFromEnum(cur)].unary;
            if (cur == .none) break;
            if (self.checkNodeTrailingLineComment(cur)) return true;
        }
        return false;
    }

    fn checkNodeTrailingLineComment(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.trailing_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i) and comments[i].kind == .line) return true;
        }
        return false;
    }

    fn checkNodeLeadingLineComment(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i) and comments[i].kind == .line) return true;
        }
        return false;
    }

    /// Check if a node has leading comments that are line comments or multi-line block comments.
    /// Single-line block comments (like /* x */) return false — they can stay inline.
    fn hasLeadingLineOrMultilineComment(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            const c = comments[i];
            if (c.kind == .line) return true;
            // Multi-line block comment: check if the comment text contains a newline
            if (c.kind == .block) {
                const text = self.ast.source[c.start..c.end];
                for (text) |ch| {
                    if (ch == '\n') return true;
                }
            }
        }
        return false;
    }

    /// Check if a node has any unemitted leading multi-line block comment.
    pub fn hasLeadingMultiLineBlockComment(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (self.emitted_comments.isSet(i)) continue;
            if (comments[i].kind == .block and self.isMultiLineBlock(comments[i])) return true;
        }
        return false;
    }

    /// Check if a node has any unemitted leading comments.
    pub fn hasLeadingComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.leading_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i)) return true;
        }
        return false;
    }

    /// Check if a statement has same-line trailing comments (on the statement itself
    /// or on the expression inside an ExpressionStatement). Used for blank-line
    /// preservation: blank lines after statements with trailing comments should be
    /// preserved if the comment is at the end of the statement (same-line).
    pub fn statementHasDirectTrailingComments(self: *Codegen, stmt_idx: NodeIndex) bool {
        const stmt_end = self.nodeSourceEnd(stmt_idx);
        // Check trailing comments on the statement node itself
        if (self.checkNodeHasSameLineTrailing(stmt_idx, stmt_end)) return true;
        // For ExpressionStatement, also check the expression child
        const tags = self.ast.nodes.items(.tag);
        const tag = tags[@intFromEnum(stmt_idx)];
        if (tag == .expression_statement) {
            const data = self.ast.nodes.items(.data)[@intFromEnum(stmt_idx)];
            if (data.unary != .none) {
                if (self.checkNodeHasSameLineTrailing(data.unary, stmt_end)) return true;
            }
        }
        return false;
    }

    fn checkNodeHasSameLineTrailing(self: *Codegen, idx: NodeIndex, stmt_end: u32) bool {
        const range = self.ast.trailing_comments.get(@intFromEnum(idx)) orelse return false;
        const comments = self.ast.comments.items;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            // Only consider comments on the same line as the statement end
            if (!self.hasNewlineBetween(stmt_end, comments[i].start) or
                !self.hasNewlineBetween(self.nodeSourceEnd(idx), comments[i].start))
            {
                return true;
            }
        }
        return false;
    }

    /// Check if a node has any unemitted trailing comments.
    pub fn hasTrailingComments(self: *Codegen, idx: NodeIndex) bool {
        const key = @intFromEnum(idx);
        const range = self.ast.trailing_comments.get(key) orelse return false;
        const comments = self.ast.comments.items;
        if (range.start >= range.end or range.start >= comments.len) return false;
        var i = range.start;
        while (i < range.end and i < comments.len) : (i += 1) {
            if (!self.emitted_comments.isSet(i)) return true;
        }
        return false;
    }
};
