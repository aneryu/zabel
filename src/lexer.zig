const std = @import("std");
const Token = @import("token.zig").Token;

pub const Comment = struct {
    kind: enum { line, block },
    start: u32, // offset of // or /*
    end: u32, // offset after \n or after */
    value_start: u32, // offset of content after // or /*
    value_end: u32, // offset before \n or before */
};

pub const LexResult = struct {
    tokens: std.MultiArrayList(Token),
    line_offsets: std.ArrayList(u32),
    comments: std.ArrayList(Comment),
    hashbang_end: ?u32 = null,
    has_unterminated_comment: bool = false,
    unterminated_comment_offset: u32 = 0,
    has_invalid_unicode: bool = false,
    invalid_unicode_offset: u32 = 0,
    has_html_comment: bool = false,
    html_comment_offset: u32 = 0,
    has_unterminated_string: bool = false,
    unterminated_string_offset: u32 = 0,
};

pub const Lexer = struct {
    source: []const u8,
    index: u32,
    line_offsets: std.ArrayList(u32),
    allocator: std.mem.Allocator,
    is_module: bool = false,
    annex_b: bool = true,
    enable_flow_comments: bool = false,
    in_flow_comment: bool = false, // Currently inside a flow comment (/*:: or /*flow-include or /*:)
    flow_comment_type_only: bool = false, // Inside /*: (type annotation only, not full code)
    template_brace_stack: std.ArrayList(u32) = .empty,
    comments: std.ArrayList(Comment) = .empty,
    has_unterminated_comment: bool = false,
    unterminated_comment_offset: u32 = 0,
    has_invalid_unicode: bool = false,
    invalid_unicode_offset: u32 = 0,
    has_html_comment: bool = false,
    html_comment_offset: u32 = 0,
    has_unterminated_string: bool = false,
    unterminated_string_offset: u32 = 0,

    pub const TokenizeOptions = struct {
        is_module: bool = false,
        annex_b: bool = true,
        enable_flow_comments: bool = false,
    };

    pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) !LexResult {
        return tokenizeWithOptions(allocator, source, .{});
    }

    pub fn tokenizeWithOptions(allocator: std.mem.Allocator, source: []const u8, opts: TokenizeOptions) !LexResult {
        var line_offsets: std.ArrayList(u32) = .empty;
        const estimated_lines = @max(source.len / 32, 16);
        try line_offsets.ensureTotalCapacity(allocator, estimated_lines);
        try line_offsets.append(allocator, 0); // first line starts at offset 0

        // Skip hashbang (#!) at start of source
        var hashbang_end: ?u32 = null;
        var start_index: u32 = 0;
        if (source.len >= 2 and source[0] == '#' and source[1] == '!') {
            var i: u32 = 2;
            while (i < source.len and source[i] != '\n' and source[i] != '\r') : (i += 1) {}
            hashbang_end = i;
            start_index = i;
            // Skip the newline character(s)
            if (i < source.len and source[i] == '\r') {
                start_index += 1;
                if (start_index < source.len and source[start_index] == '\n') {
                    start_index += 1;
                }
            } else if (i < source.len and source[i] == '\n') {
                start_index += 1;
            }
            try line_offsets.append(allocator, start_index);
        }

        var lexer = Lexer{
            .source = source,
            .index = start_index,
            .line_offsets = line_offsets,
            .allocator = allocator,
            .is_module = opts.is_module,
            .annex_b = opts.annex_b,
            .enable_flow_comments = opts.enable_flow_comments,
        };
        const estimated_comments = @max(source.len / 256, 8);
        try lexer.comments.ensureTotalCapacity(allocator, estimated_comments);

        var tokens = std.MultiArrayList(Token){};
        // Pre-allocate: heuristic is source.len / 8 tokens
        const estimated = @max(source.len / 8, 16);
        try tokens.ensureTotalCapacity(allocator, estimated);

        while (true) {
            var token = lexer.nextToken();
            // Handle template literal context tracking
            if (token.tag == .template_head or token.tag == .template_middle) {
                // Entering a template expression: push brace depth 0
                try lexer.template_brace_stack.append(allocator, 0);
            } else if (token.tag == .l_brace and lexer.template_brace_stack.items.len > 0) {
                // Nested brace inside template expression
                lexer.template_brace_stack.items[lexer.template_brace_stack.items.len - 1] += 1;
            } else if (token.tag == .r_brace and lexer.template_brace_stack.items.len > 0) {
                const top = &lexer.template_brace_stack.items[lexer.template_brace_stack.items.len - 1];
                if (top.* == 0) {
                    // This '}' closes the template expression - back up past it
                    // so scanTemplateContinuation includes the '}' in the token
                    _ = lexer.template_brace_stack.pop();
                    lexer.index -= 1; // back up to include '}'
                    token = lexer.scanTemplateContinuation();
                    if (token.tag == .template_middle) {
                        // Re-entering a template expression
                        try lexer.template_brace_stack.append(allocator, 0);
                    }
                } else {
                    top.* -= 1;
                }
            }
            try tokens.append(allocator, token);
            if (token.tag == .eof) break;
        }

        lexer.template_brace_stack.deinit(allocator);

        // Unterminated flow comment check
        if (lexer.in_flow_comment) {
            lexer.has_unterminated_comment = true;
            // Use start of file as the offset (approximation)
            lexer.unterminated_comment_offset = 0;
        }

        return .{
            .tokens = tokens,
            .line_offsets = lexer.line_offsets,
            .comments = lexer.comments,
            .hashbang_end = hashbang_end,
            .has_unterminated_comment = lexer.has_unterminated_comment,
            .unterminated_comment_offset = lexer.unterminated_comment_offset,
            .has_invalid_unicode = lexer.has_invalid_unicode,
            .invalid_unicode_offset = lexer.invalid_unicode_offset,
            .has_html_comment = lexer.has_html_comment,
            .html_comment_offset = lexer.html_comment_offset,
            .has_unterminated_string = lexer.has_unterminated_string,
            .unterminated_string_offset = lexer.unterminated_string_offset,
        };
    }

    fn nextToken(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        const start = self.index;
        if (self.index >= self.source.len) return .{ .tag = .eof, .start = start, .end = start };

        // Check for end of flow comment: */
        if (self.in_flow_comment and self.source[self.index] == '*' and
            self.index + 1 < self.source.len and self.source[self.index + 1] == '/')
        {
            self.index += 2; // skip */
            self.in_flow_comment = false;
            self.flow_comment_type_only = false;
            return self.nextToken(); // continue to next real token
        }

        const c = self.source[self.index];
        switch (c) {
            '(' => return self.singleChar(.l_paren),
            ')' => return self.singleChar(.r_paren),
            '{' => return self.singleChar(.l_brace),
            '}' => return self.singleChar(.r_brace),
            '[' => return self.singleChar(.l_bracket),
            ']' => return self.singleChar(.r_bracket),
            ';' => return self.singleChar(.semicolon),
            ',' => return self.singleChar(.comma),
            '~' => return self.singleChar(.tilde),
            ':' => return self.singleChar(.colon),
            '#' => return self.singleChar(.hash),

            '.' => return self.scanDot(start),
            '?' => return self.scanQuestion(start),

            '+' => return self.scanPlus(start),
            '-' => return self.scanMinus(start),
            '*' => return self.scanAsterisk(start),
            '/' => return self.scanSlash(start),
            '%' => return self.scanPercent(start),
            '&' => return self.scanAmpersand(start),
            '|' => return self.scanPipe(start),
            '^' => return self.scanCaret(start),
            '!' => return self.scanBang(start),
            '=' => return self.scanEqual(start),
            '<' => return self.scanLessThan(start),
            '>' => return self.scanGreaterThan(start),

            '"', '\'' => return self.scanString(start),
            '`' => return self.scanTemplate(start),
            '0'...'9' => return self.scanNumber(start),
            'a'...'z', 'A'...'Z', '_', '$' => return self.scanIdentifierOrKeyword(start),
            '\\' => {
                // Backslash at start of identifier: \uXXXX or error-recovery for \\
                return self.scanIdentifierOrKeyword(start);
            },
            // Multi-byte UTF-8 (unicode identifier start)
            0xC0...0xDF, 0xE0...0xEF, 0xF0...0xF7 => {
                // Check for known non-identifier Unicode characters before treating as identifier
                if (!self.isUnicodeIdentifierStart()) {
                    self.skipUtf8Char();
                    return .{ .tag = .invalid, .start = start, .end = self.index };
                }
                return self.scanIdentifierOrKeyword(start);
            },

            '@' => {
                // Flow @@iterator / @@asyncIterator syntax
                if (self.peek(1) == @as(u8, '@') and self.peek(2) != null and (std.ascii.isAlphabetic(self.peek(2).?) or self.peek(2).? == '_' or self.peek(2).? == '$')) {
                    self.index += 2; // skip @@
                    // Continue scanning as identifier
                    while (self.index < self.source.len and (std.ascii.isAlphanumeric(self.source[self.index]) or self.source[self.index] == '_' or self.source[self.index] == '$')) {
                        self.index += 1;
                    }
                    return .{ .tag = .identifier, .start = start, .end = self.index };
                }
                self.index += 1;
                return .{ .tag = .invalid, .start = start, .end = self.index };
            },
            else => {
                self.index += 1;
                return .{ .tag = .invalid, .start = start, .end = self.index };
            },
        }
    }

    fn singleChar(self: *Lexer, tag: Token.Tag) Token {
        const start = self.index;
        self.index += 1;
        return .{ .tag = tag, .start = start, .end = self.index };
    }

    fn peek(self: *const Lexer, offset: u32) ?u8 {
        const idx = self.index + offset;
        if (idx < self.source.len) return self.source[idx];
        return null;
    }

    /// Check if current position holds a U+2028 (LINE SEPARATOR) or U+2029 (PARAGRAPH SEPARATOR).
    /// These are 3-byte UTF-8 sequences: E2 80 A8 and E2 80 A9.
    fn isLineSeparator(self: *const Lexer) bool {
        return self.index + 2 < self.source.len and
            self.source[self.index] == 0xE2 and
            self.source[self.index + 1] == 0x80 and
            (self.source[self.index + 2] == 0xA8 or self.source[self.index + 2] == 0xA9);
    }

    /// Check if current position holds a Unicode Zs (Space Separator) character.
    /// Covers: U+2000-U+200A (E2 80 80-8A), U+202F (E2 80 AF), U+205F (E2 81 9F).
    fn isUnicodeSpaceSeparator(self: *const Lexer) bool {
        if (self.index + 2 >= self.source.len or self.source[self.index] != 0xE2) return false;
        const b1 = self.source[self.index + 1];
        const b2 = self.source[self.index + 2];
        // U+2000-U+200A: E2 80 80 through E2 80 8A
        if (b1 == 0x80 and b2 >= 0x80 and b2 <= 0x8A) return true;
        // U+202F (NARROW NO-BREAK SPACE): E2 80 AF
        if (b1 == 0x80 and b2 == 0xAF) return true;
        // U+205F (MEDIUM MATHEMATICAL SPACE): E2 81 9F
        if (b1 == 0x81 and b2 == 0x9F) return true;
        return false;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t', 0x0B, 0x0C => self.index += 1,
                '\r' => {
                    self.index += 1;
                    // \r\n counts as one newline
                    if (self.index < self.source.len and self.source[self.index] == '\n') {
                        self.index += 1;
                    }
                    self.line_offsets.append(self.allocator, self.index) catch {};
                },
                '\n' => {
                    self.index += 1;
                    self.line_offsets.append(self.allocator, self.index) catch {};
                },
                // Handle Unicode whitespace (3-byte UTF-8 sequences starting with E1/E2/E3)
                0xE1 => {
                    // U+1680 (OGHAM SPACE MARK) = E1 9A 80
                    if (self.index + 2 < self.source.len and
                        self.source[self.index + 1] == 0x9A and self.source[self.index + 2] == 0x80)
                    {
                        self.index += 3;
                        continue;
                    }
                    return;
                },
                0xE2 => {
                    if (self.isLineSeparator()) {
                        // U+2028 or U+2029: line terminators per ECMAScript spec
                        self.index += 3;
                        self.line_offsets.append(self.allocator, self.index) catch {};
                        continue;
                    }
                    if (self.isUnicodeSpaceSeparator()) {
                        self.index += 3;
                        continue;
                    }
                    return;
                },
                0xE3 => {
                    // U+3000 (IDEOGRAPHIC SPACE) = E3 80 80
                    if (self.index + 2 < self.source.len and
                        self.source[self.index + 1] == 0x80 and self.source[self.index + 2] == 0x80)
                    {
                        self.index += 3;
                        continue;
                    }
                    return;
                },
                // U+00A0 (NBSP) = C2 A0
                0xC2 => {
                    if (self.index + 1 < self.source.len and self.source[self.index + 1] == 0xA0) {
                        self.index += 2;
                        continue;
                    }
                    return;
                },
                // U+FEFF (BOM) = EF BB BF
                0xEF => {
                    if (self.index + 2 < self.source.len and
                        self.source[self.index + 1] == 0xBB and self.source[self.index + 2] == 0xBF)
                    {
                        self.index += 3;
                        continue;
                    }
                    return;
                },
                '/' => {
                    if (self.peek(1)) |next| {
                        if (next == '/') {
                            self.skipLineComment();
                            continue;
                        } else if (next == '*') {
                            self.skipBlockComment();
                            continue;
                        }
                    }
                    return;
                },
                else => return,
            }
        }
    }

    fn skipLineComment(self: *Lexer) void {
        const start = self.index;
        self.index += 2; // skip //
        const value_start = self.index;
        while (self.index < self.source.len) {
            if (self.source[self.index] == '\n' or self.source[self.index] == '\r') break;
            // U+2028/U+2029 also terminate line comments
            if (self.isLineSeparator()) break;
            self.index += 1;
        }
        self.comments.append(self.allocator, .{
            .kind = .line,
            .start = start,
            .end = self.index,
            .value_start = value_start,
            .value_end = self.index,
        }) catch {};
    }

    fn skipBlockComment(self: *Lexer) void {
        const start = self.index;
        self.index += 2; // skip /*
        const value_start = self.index;

        // Flow comments: /*:: code */ or /*flow-include code */ or /*: type */
        if (self.enable_flow_comments) {
            // Check for nested flow comment (error)
            if (self.in_flow_comment) {
                var fc2_idx = self.index;
                while (fc2_idx < self.source.len and (self.source[fc2_idx] == ' ' or self.source[fc2_idx] == '\t')) {
                    fc2_idx += 1;
                }
                const rem2 = self.source[fc2_idx..];
                if ((rem2.len >= 2 and rem2[0] == ':' and rem2[1] == ':') or
                    (rem2.len >= 12 and std.mem.startsWith(u8, rem2, "flow-include")) or
                    (rem2.len >= 1 and rem2[0] == ':' and (rem2.len < 2 or rem2[1] != ':')))
                {
                    // Nested flow comment — mark as error
                    self.has_unterminated_comment = true;
                    self.unterminated_comment_offset = start;
                    // Continue parsing the normal block comment to consume it
                }
            }
            // Skip optional whitespace after /*
            var fc_idx = self.index;
            while (fc_idx < self.source.len and (self.source[fc_idx] == ' ' or self.source[fc_idx] == '\t')) {
                fc_idx += 1;
            }
            const remaining = self.source[fc_idx..];
            if (remaining.len >= 2 and remaining[0] == ':' and remaining[1] == ':') {
                // /*:: ... */ or /* :: ... */ — flow include (full code)
                self.index = @intCast(fc_idx + 2); // skip :: (and preceding whitespace)
                // Skip whitespace after ::
                while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) {
                    self.index += 1;
                }
                self.in_flow_comment = true;
                self.flow_comment_type_only = false;
                return; // Don't skip — let the lexer tokenize the content
            } else if (remaining.len >= 12 and std.mem.startsWith(u8, remaining, "flow-include")) {
                // /*flow-include ... */ — flow include (full code)
                self.index = @intCast(fc_idx + 12); // skip flow-include
                // Skip whitespace after flow-include
                while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) {
                    self.index += 1;
                }
                self.in_flow_comment = true;
                self.flow_comment_type_only = false;
                return;
            } else if (remaining.len >= 1 and remaining[0] == ':' and (remaining.len < 2 or remaining[1] != ':')) {
                // /*: type */ — flow type annotation only
                // Don't skip the ':' — it's needed for the parser to see `: Type`
                self.index = @intCast(fc_idx); // position at the ':'
                self.in_flow_comment = true;
                self.flow_comment_type_only = true;
                return;
            }
        }
        while (self.index + 1 < self.source.len) {
            const c = self.source[self.index];
            if (c == '\n') {
                self.line_offsets.append(self.allocator, self.index + 1) catch {};
            } else if (c == '\r') {
                // \r\n counts as one newline; standalone \r also counts
                if (self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
                    self.index += 1; // skip \r, the \n will be handled next iteration
                } else {
                    self.line_offsets.append(self.allocator, self.index + 1) catch {};
                }
            } else if (self.isLineSeparator()) {
                // U+2028/U+2029 are line terminators in block comments
                self.index += 3;
                self.line_offsets.append(self.allocator, self.index) catch {};
                continue;
            }
            if (c == '*') {
                // Inside a flow comment, nested block comments close at `*-/` instead of `*/`
                // (because `*/` would close the flow comment itself)
                if (self.in_flow_comment and self.index + 2 < self.source.len and
                    self.source[self.index + 1] == '-' and self.source[self.index + 2] == '/')
                {
                    const value_end = self.index;
                    self.index += 3; // skip *-/
                    self.comments.append(self.allocator, .{
                        .kind = .block,
                        .start = start,
                        .end = self.index,
                        .value_start = value_start,
                        .value_end = value_end,
                    }) catch {};
                    return;
                }
                if (self.source[self.index + 1] == '/') {
                    const value_end = self.index;
                    self.index += 2;
                    self.comments.append(self.allocator, .{
                        .kind = .block,
                        .start = start,
                        .end = self.index,
                        .value_start = value_start,
                        .value_end = value_end,
                    }) catch {};
                    return;
                }
            }
            self.index += 1;
        }
        self.has_unterminated_comment = true;
        self.unterminated_comment_offset = start;
        self.index = @intCast(self.source.len);
    }

    // === Multi-char operator scanners ===

    fn scanDot(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '.') and self.peek(1) == @as(u8, '.')) {
            self.index += 2;
            return .{ .tag = .ellipsis, .start = start, .end = self.index };
        }
        // Check for numeric literal starting with .
        if (self.index < self.source.len and self.source[self.index] >= '0' and self.source[self.index] <= '9') {
            return self.scanNumberAfterDot(start);
        }
        return .{ .tag = .dot, .start = start, .end = self.index };
    }

    fn scanQuestion(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '?')) {
            self.index += 1;
            if (self.peek(0) == @as(u8, '=')) {
                self.index += 1;
                return .{ .tag = .question_question_equal, .start = start, .end = self.index };
            }
            return .{ .tag = .question_question, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '.')) {
            // ?. but not ?.digit (that would be ? followed by .5)
            if (self.peek(1)) |next| {
                if (next >= '0' and next <= '9') return .{ .tag = .question, .start = start, .end = self.index };
            }
            self.index += 1;
            return .{ .tag = .optional_chain, .start = start, .end = self.index };
        }
        return .{ .tag = .question, .start = start, .end = self.index };
    }

    fn scanPlus(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '+')) {
            self.index += 1;
            return .{ .tag = .plus_plus, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .plus_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .plus, .start = start, .end = self.index };
    }

    fn scanMinus(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '-')) {
            // Check for --> HTML close comment (Annex B, script mode only)
            if (!self.is_module and self.annex_b and self.index + 1 < self.source.len and self.source[self.index + 1] == '>') {
                // --> is a line comment if at the beginning of a line
                // (preceded only by whitespace/comments)
                if (self.isStartOfLine(start)) {
                    self.index += 2;
                    while (self.index < self.source.len and self.source[self.index] != '\n' and self.source[self.index] != '\r') {
                        self.index += 1;
                    }
                    return self.nextToken();
                }
            }
            self.index += 1;
            return .{ .tag = .minus_minus, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .minus_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .minus, .start = start, .end = self.index };
    }

    fn isStartOfLine(self: *const Lexer, pos: u32) bool {
        // Check if only whitespace/comments precede pos on the current line
        if (pos == 0) return true;
        var i = pos;
        while (i > 0) {
            i -= 1;
            const c = self.source[i];
            if (c == '\n' or c == '\r') return true;
            if (c == ' ' or c == '\t') continue;
            // Could be end of a block comment
            if (c == '/' and i > 0 and self.source[i - 1] == '*') return true;
            return false;
        }
        return true; // start of file
    }

    fn scanAsterisk(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '*')) {
            self.index += 1;
            if (self.peek(0) == @as(u8, '=')) {
                self.index += 1;
                return .{ .tag = .power_equal, .start = start, .end = self.index };
            }
            return .{ .tag = .power, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .asterisk_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .asterisk, .start = start, .end = self.index };
    }

    fn scanSlash(self: *Lexer, start: u32) Token {
        // Note: comments are handled in skipWhitespaceAndComments.
        // If we get here, it's a division operator.
        self.index += 1;
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .slash_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .slash, .start = start, .end = self.index };
    }

    fn scanPercent(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .percent_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .percent, .start = start, .end = self.index };
    }

    fn scanAmpersand(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '&')) {
            self.index += 1;
            if (self.peek(0) == @as(u8, '=')) {
                self.index += 1;
                return .{ .tag = .ampersand_ampersand_equal, .start = start, .end = self.index };
            }
            return .{ .tag = .ampersand_ampersand, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .ampersand_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .ampersand, .start = start, .end = self.index };
    }

    fn scanPipe(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '|')) {
            self.index += 1;
            if (self.peek(0) == @as(u8, '=')) {
                self.index += 1;
                return .{ .tag = .pipe_pipe_equal, .start = start, .end = self.index };
            }
            return .{ .tag = .pipe_pipe, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .pipe_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .pipe, .start = start, .end = self.index };
    }

    fn scanCaret(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .caret_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .caret, .start = start, .end = self.index };
    }

    fn scanBang(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            if (self.peek(0) == @as(u8, '=')) {
                self.index += 1;
                return .{ .tag = .bang_equal_equal, .start = start, .end = self.index };
            }
            return .{ .tag = .bang_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .bang, .start = start, .end = self.index };
    }

    fn scanEqual(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            if (self.peek(0) == @as(u8, '=')) {
                self.index += 1;
                return .{ .tag = .equal_equal_equal, .start = start, .end = self.index };
            }
            return .{ .tag = .equal_equal, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '>')) {
            self.index += 1;
            return .{ .tag = .arrow, .start = start, .end = self.index };
        }
        return .{ .tag = .equal, .start = start, .end = self.index };
    }

    fn scanLessThan(self: *Lexer, start: u32) Token {
        self.index += 1;
        // HTML comment: <!-- treated as line comment in script mode only
        // In module mode, <!-- is NOT a comment; it should be parsed as < ! -- tokens
        if (!self.is_module and self.annex_b and self.peek(0) == @as(u8, '!') and self.peek(1) == @as(u8, '-') and self.peek(2) == @as(u8, '-')) {
            if (!self.has_html_comment) {
                self.has_html_comment = true;
                self.html_comment_offset = start;
            }
            self.index += 3; // skip !--
            // Skip to end of line (like a // comment but without the index += 2)
            while (self.index < self.source.len) {
                if (self.source[self.index] == '\n' or self.source[self.index] == '\r') break;
                if (self.isLineSeparator()) break;
                self.index += 1;
            }
            return self.nextToken(); // return next real token
        }
        if (self.peek(0) == @as(u8, '<')) {
            self.index += 1;
            if (self.peek(0) == @as(u8, '=')) {
                self.index += 1;
                return .{ .tag = .less_less_equal, .start = start, .end = self.index };
            }
            return .{ .tag = .less_less, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .less_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .less_than, .start = start, .end = self.index };
    }

    fn scanGreaterThan(self: *Lexer, start: u32) Token {
        self.index += 1;
        if (self.peek(0) == @as(u8, '>')) {
            self.index += 1;
            if (self.peek(0) == @as(u8, '>')) {
                self.index += 1;
                if (self.peek(0) == @as(u8, '=')) {
                    self.index += 1;
                    return .{ .tag = .greater_greater_greater_equal, .start = start, .end = self.index };
                }
                return .{ .tag = .greater_greater_greater, .start = start, .end = self.index };
            }
            if (self.peek(0) == @as(u8, '=')) {
                self.index += 1;
                return .{ .tag = .greater_greater_equal, .start = start, .end = self.index };
            }
            return .{ .tag = .greater_greater, .start = start, .end = self.index };
        }
        if (self.peek(0) == @as(u8, '=')) {
            self.index += 1;
            return .{ .tag = .greater_equal, .start = start, .end = self.index };
        }
        return .{ .tag = .greater_than, .start = start, .end = self.index };
    }

    // === Literal scanners ===

    fn scanString(self: *Lexer, start: u32) Token {
        const quote = self.source[self.index];
        self.index += 1; // skip opening quote
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == quote) {
                self.index += 1;
                return .{ .tag = .string, .start = start, .end = self.index };
            }
            if (c == '\\') {
                self.index += 1; // skip backslash
                if (self.index < self.source.len) {
                    if (self.source[self.index] == 'x') {
                        // \xHH hex escape — check for underscore (numeric separator)
                        const x_offset = self.index;
                        self.index += 1; // skip 'x'
                        var hex_count: u32 = 0;
                        while (hex_count < 2 and self.index < self.source.len) : (hex_count += 1) {
                            const hc = self.source[self.index];
                            if (hc == '_') {
                                self.has_invalid_unicode = true;
                                self.invalid_unicode_offset = x_offset;
                                self.index += 1;
                            } else if (std.ascii.isHex(hc)) {
                                self.index += 1;
                            } else break;
                        }
                        // Incomplete \xH (fewer than 2 hex digits) is a bad escape
                        if (hex_count < 2 and !self.has_invalid_unicode) {
                            self.has_invalid_unicode = true;
                            self.invalid_unicode_offset = x_offset;
                        }
                        continue;
                    }
                    if (self.source[self.index] == 'u' and self.index + 1 < self.source.len and self.source[self.index + 1] == '{') {
                        const backslash_offset = self.index - 1;
                        self.index += 2; // skip u{
                        const hex_start = self.index;
                        while (self.index < self.source.len and self.source[self.index] != '}' and self.source[self.index] != quote and self.source[self.index] != '\n') {
                            self.index += 1;
                        }
                        self.validateBracedUnicodeEscape(self.source[hex_start..self.index], backslash_offset);
                        if (self.index < self.source.len and self.source[self.index] == '}') {
                            self.index += 1;
                        } else {
                            // Unclosed \u{...} in string — flag as invalid
                            self.has_invalid_unicode = true;
                            self.invalid_unicode_offset = backslash_offset;
                        }
                        continue;
                    }
                    if (self.source[self.index] == '\n') {
                        self.line_offsets.append(self.allocator, self.index + 1) catch {};
                    } else if (self.source[self.index] == '\r') {
                        self.index += 1;
                        if (self.index < self.source.len and self.source[self.index] == '\n') {
                            self.index += 1;
                        }
                        self.line_offsets.append(self.allocator, self.index) catch {};
                        continue;
                    } else if (self.isLineSeparator()) {
                        // \<U+2028> or \<U+2029> line continuation
                        self.index += 3;
                        self.line_offsets.append(self.allocator, self.index) catch {};
                        continue;
                    }
                    self.index += 1; // skip escaped char
                }
                continue;
            }
            if (c == '\n') {
                // Check if this is a JSX multiline string by looking ahead for closing quote
                // before any character that would be invalid in a JSX string value.
                var scan = self.index + 1;
                var has_close = false;
                while (scan < self.source.len) : (scan += 1) {
                    if (self.source[scan] == quote) {
                        has_close = true;
                        break;
                    }
                    // Stop scanning at `<` which indicates JSX element boundaries
                    if (self.source[scan] == '<') break;
                }
                if (has_close) {
                    // Multiline string (JSX attribute value): track line and continue
                    if (!self.has_unterminated_string) {
                        self.has_unterminated_string = true;
                        self.unterminated_string_offset = start;
                    }
                    self.line_offsets.append(self.allocator, self.index + 1) catch {};
                    self.index += 1;
                    continue;
                }
                // Unterminated string: break and return just the quote
                break;
            }
            // U+2028/U+2029 are line terminators but allowed in strings (ES2019)
            if (self.isLineSeparator()) {
                self.index += 3;
                self.line_offsets.append(self.allocator, self.index) catch {};
                continue;
            }
            self.index += 1;
        }
        // Unterminated string: return just the quote character as invalid
        // so subsequent characters can be tokenized (important for JSX text)
        self.index = start + 1;
        return .{ .tag = .invalid, .start = start, .end = self.index };
    }

    /// Skip an escape sequence in a template literal, tracking line breaks for
    /// \<LF> and \<CR> continuations. Returns true if the caller should `continue`
    /// (i.e. the escape consumed a multi-byte LS/PS that was already advanced past).
    fn skipTemplateEscape(self: *Lexer) bool {
        self.index += 1; // skip backslash
        if (self.index >= self.source.len) return false;
        if (self.source[self.index] == '\n') {
            self.line_offsets.append(self.allocator, self.index + 1) catch {};
        } else if (self.source[self.index] == '\r') {
            if (self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
                self.index += 1;
            }
            self.line_offsets.append(self.allocator, self.index + 1) catch {};
        } else if (self.isLineSeparator()) {
            // \<LS> / \<PS> are escape sequences; skip without counting as a line break
            self.index += 3;
            return true;
        }
        self.index += 1;
        return false;
    }

    /// Track a bare (un-escaped) line terminator inside a template literal.
    /// Returns true if the caller should `continue` (multi-byte LS/PS already advanced).
    fn trackTemplateLine(self: *Lexer, c: u8) bool {
        if (c == '\n') {
            self.line_offsets.append(self.allocator, self.index + 1) catch {};
        } else if (c == '\r') {
            if (self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
                self.index += 1;
            }
            self.line_offsets.append(self.allocator, self.index + 1) catch {};
        } else if (self.isLineSeparator()) {
            self.index += 3;
            self.line_offsets.append(self.allocator, self.index) catch {};
            return true;
        }
        return false;
    }

    fn scanTemplate(self: *Lexer, start: u32) Token {
        self.index += 1; // skip `
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '`') {
                self.index += 1;
                return .{ .tag = .template_no_sub, .start = start, .end = self.index };
            }
            if (c == '\\') {
                if (self.skipTemplateEscape()) continue;
                continue;
            }
            if (c == '$' and self.peek(1) == @as(u8, '{')) {
                self.index += 2;
                return .{ .tag = .template_head, .start = start, .end = self.index };
            }
            if (self.trackTemplateLine(c)) continue;
            self.index += 1;
        }
        return .{ .tag = .invalid, .start = start, .end = self.index }; // unterminated
    }

    /// Called by the parser after a } to continue scanning a template literal.
    pub fn scanTemplateContinuation(self: *Lexer) Token {
        const start = self.index;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '`') {
                self.index += 1;
                return .{ .tag = .template_tail, .start = start, .end = self.index };
            }
            if (c == '\\') {
                if (self.skipTemplateEscape()) continue;
                continue;
            }
            if (c == '$' and self.peek(1) == @as(u8, '{')) {
                self.index += 2;
                return .{ .tag = .template_middle, .start = start, .end = self.index };
            }
            if (self.trackTemplateLine(c)) continue;
            self.index += 1;
        }
        return .{ .tag = .invalid, .start = start, .end = self.index };
    }

    fn scanNumber(self: *Lexer, start: u32) Token {
        // Handle 0x, 0b, 0o prefixes
        if (self.source[self.index] == '0' and self.index + 1 < self.source.len) {
            const next = self.source[self.index + 1];
            switch (next) {
                'x', 'X' => return self.scanHexNumber(start),
                'b', 'B' => return self.scanBinaryNumber(start),
                'o', 'O' => return self.scanOctalNumber(start),
                // Legacy octal: 0[0-7]+ (no decimal point or exponent allowed)
                '0'...'7' => return self.scanLegacyOctalNumber(start),
                else => {},
            }
        }
        return self.scanDecimalNumber(start);
    }

    fn scanDecimalNumber(self: *Lexer, start: u32) Token {
        self.skipDigits();
        // Decimal point
        if (self.index < self.source.len and self.source[self.index] == '.') {
            self.index += 1;
            self.skipDigits();
        }
        // Exponent
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            self.index += 1;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                self.index += 1;
            }
            self.skipDigits();
        }
        // BigInt suffix
        if (self.index < self.source.len and self.source[self.index] == 'n') {
            self.index += 1;
            return self.checkIdentifierAfterNumber(start, .bigint);
        }
        return self.checkIdentifierAfterNumber(start, .numeric);
    }

    fn scanNumberAfterDot(self: *Lexer, start: u32) Token {
        self.skipDigits();
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            self.index += 1;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                self.index += 1;
            }
            self.skipDigits();
        }
        return self.checkIdentifierAfterNumber(start, .numeric);
    }

    fn scanHexNumber(self: *Lexer, start: u32) Token {
        self.index += 2; // skip 0x
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '0'...'9', 'a'...'f', 'A'...'F', '_' => self.index += 1,
                else => break,
            }
        }
        if (self.index < self.source.len and self.source[self.index] == 'n') {
            self.index += 1;
            return self.checkIdentifierAfterNumber(start, .bigint);
        }
        return self.checkIdentifierAfterNumber(start, .numeric);
    }

    fn scanBinaryNumber(self: *Lexer, start: u32) Token {
        self.index += 2; // skip 0b
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '0'...'9', '_' => self.index += 1,
                else => break,
            }
        }
        if (self.index < self.source.len and self.source[self.index] == 'n') {
            self.index += 1;
            return self.checkIdentifierAfterNumber(start, .bigint);
        }
        return self.checkIdentifierAfterNumber(start, .numeric);
    }

    fn scanOctalNumber(self: *Lexer, start: u32) Token {
        self.index += 2; // skip 0o
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '0'...'9', '_' => self.index += 1,
                else => break,
            }
        }
        if (self.index < self.source.len and self.source[self.index] == 'n') {
            self.index += 1;
            return self.checkIdentifierAfterNumber(start, .bigint);
        }
        return self.checkIdentifierAfterNumber(start, .numeric);
    }

    /// Legacy octal: 0[0-7]+ — no decimal point or exponent allowed.
    /// If a digit 8 or 9 is found, fall back to decimal number scanning.
    fn scanLegacyOctalNumber(self: *Lexer, start: u32) Token {
        self.index += 1; // skip leading 0 (the next char is already a digit)
        var has_non_octal = false;
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '0'...'7' => self.index += 1,
                '8', '9' => {
                    has_non_octal = true;
                    self.index += 1;
                },
                '_' => self.index += 1,
                // If we see a dot or exponent, this is a decimal number after all (e.g., 09.5)
                '.', 'e', 'E' => {
                    if (has_non_octal) {
                        // 09.5 is a decimal literal
                        return self.continueDecimalAfterDigits(start);
                    }
                    // 07.5 — legacy octal stops before the dot
                    return .{ .tag = .numeric, .start = start, .end = self.index };
                },
                else => break,
            }
        }
        if (self.index < self.source.len and self.source[self.index] == 'n') {
            self.index += 1;
            return self.checkIdentifierAfterNumber(start, .bigint);
        }
        return self.checkIdentifierAfterNumber(start, .numeric);
    }

    /// Continue scanning a decimal number from after digits (handles . and exponent).
    fn continueDecimalAfterDigits(self: *Lexer, start: u32) Token {
        if (self.index < self.source.len and self.source[self.index] == '.') {
            self.index += 1;
            self.skipDigits();
        }
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            self.index += 1;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                self.index += 1;
            }
            self.skipDigits();
        }
        if (self.index < self.source.len and self.source[self.index] == 'n') {
            self.index += 1;
            return self.checkIdentifierAfterNumber(start, .bigint);
        }
        return self.checkIdentifierAfterNumber(start, .numeric);
    }

    fn skipDigits(self: *Lexer) void {
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '0'...'9', '_' => self.index += 1,
                else => break,
            }
        }
    }

    /// Check if the byte at current index is an identifier start character.
    fn isIdentifierStartAtIndex(self: *const Lexer) bool {
        if (self.index >= self.source.len) return false;
        const c = self.source[self.index];
        return switch (c) {
            'a'...'z', 'A'...'Z', '_', '$' => true,
            '\\' => (self.index + 1 < self.source.len and self.source[self.index + 1] == 'u'),
            0xC0...0xDF, 0xE0...0xEF, 0xF0...0xF7 => self.isUnicodeIdentifierStart(),
            else => false,
        };
    }

    /// If the character after a number literal is an identifier start, return invalid.
    fn checkIdentifierAfterNumber(self: *Lexer, start: u32, tag: Token.Tag) Token {
        if (self.isIdentifierStartAtIndex()) {
            // Consume the identifier chars too so we produce one error token
            while (self.index < self.source.len) {
                switch (self.source[self.index]) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => self.index += 1,
                    0x80...0xFF => {
                        if (self.isLineSeparator()) break;
                        if (self.isUnicodeSpaceSeparator()) break;
                        self.skipUtf8Char();
                    },
                    else => break,
                }
            }
            return .{ .tag = .invalid, .start = start, .end = self.index };
        }
        return .{ .tag = tag, .start = start, .end = self.index };
    }

    /// Validate a \u{...} hex escape and flag if the code point exceeds U+10FFFF.
    fn validateBracedUnicodeEscape(self: *Lexer, hex_str: []const u8, backslash_offset: u32) void {
        if (hex_str.len > 0) {
            const code_point = std.fmt.parseInt(u32, hex_str, 16) catch 0xFFFFFFFF;
            if (code_point > 0x10FFFF) {
                self.has_invalid_unicode = true;
                self.invalid_unicode_offset = backslash_offset;
            }
        }
    }

    /// Skip a \uXXXX or \u{XXXX+} escape sequence starting at the backslash.
    /// Returns true if a valid \u escape was consumed, false otherwise (index unchanged).
    fn skipUnicodeEscape(self: *Lexer) bool {
        if (self.index + 1 < self.source.len and self.source[self.index + 1] == 'u') {
            const backslash_offset = self.index;
            self.index += 2;
            if (self.index < self.source.len and self.source[self.index] == '{') {
                self.index += 1;
                const hex_start = self.index;
                while (self.index < self.source.len and self.source[self.index] != '}') {
                    // Stop at line terminators and whitespace — don't consume past boundaries
                    const ch = self.source[self.index];
                    if (ch == '\n' or ch == '\r' or ch == ' ' or ch == ';') break;
                    self.index += 1;
                }
                self.validateBracedUnicodeEscape(self.source[hex_start..self.index], backslash_offset);
                if (self.index < self.source.len and self.source[self.index] == '}') {
                    self.index += 1;
                } else {
                    // Unclosed \u{...} — flag as invalid unicode escape
                    self.has_invalid_unicode = true;
                    self.invalid_unicode_offset = backslash_offset;
                }
            } else {
                // \uHHHH — consume up to 4 hex/underscore chars (underscores flag error)
                const hex_start = self.index;
                var j: u32 = 0;
                while (j < 4 and self.index < self.source.len) : (j += 1) {
                    const ch = self.source[self.index];
                    if (ch == '_') {
                        // Numeric separator in unicode escape — flag error but consume
                        self.has_invalid_unicode = true;
                        self.invalid_unicode_offset = backslash_offset;
                        self.index += 1;
                    } else if (std.ascii.isHex(ch)) {
                        self.index += 1;
                    } else break;
                }
                // Validate: surrogate codepoints (U+D800-U+DFFF) are invalid in \uXXXX escapes
                if (j == 4) {
                    const cp = std.fmt.parseInt(u16, self.source[hex_start..self.index], 16) catch 0;
                    if (cp >= 0xD800 and cp <= 0xDFFF) {
                        if (!self.has_invalid_unicode) {
                            self.has_invalid_unicode = true;
                            self.invalid_unicode_offset = backslash_offset;
                        }
                    }
                }
            }
            return true;
        }
        return false;
    }

    /// Decode a UTF-8 code point at the current index. Returns null if invalid/incomplete.
    fn decodeUtf8(self: *const Lexer) ?u21 {
        if (self.index >= self.source.len) return null;
        const b0 = self.source[self.index];
        if (b0 < 0x80) return b0;
        if (b0 >= 0xC0 and b0 <= 0xDF) {
            if (self.index + 1 >= self.source.len) return null;
            const b1 = self.source[self.index + 1];
            return (@as(u21, b0 & 0x1F) << 6) | @as(u21, b1 & 0x3F);
        }
        if (b0 >= 0xE0 and b0 <= 0xEF) {
            if (self.index + 2 >= self.source.len) return null;
            const b1 = self.source[self.index + 1];
            const b2 = self.source[self.index + 2];
            return (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | @as(u21, b2 & 0x3F);
        }
        if (b0 >= 0xF0 and b0 <= 0xF7) {
            if (self.index + 3 >= self.source.len) return null;
            const b1 = self.source[self.index + 1];
            const b2 = self.source[self.index + 2];
            const b3 = self.source[self.index + 3];
            return (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) | (@as(u21, b2 & 0x3F) << 6) | @as(u21, b3 & 0x3F);
        }
        return null;
    }

    /// Check if the current multi-byte UTF-8 character is a valid Unicode ID_Start.
    /// Uses a simplified check covering the most common ranges.
    fn isUnicodeIdentifierStart(self: *const Lexer) bool {
        const cp = self.decodeUtf8() orelse return false;
        return isUnicodeIdStart(cp);
    }

    /// Simplified Unicode ID_Start check covering the ranges needed by ECMAScript.
    /// Broad ranges are used where many adjacent sub-ranges can be merged; the
    /// U+2000-U+2FFF gap ensures General Punctuation chars are rejected.
    fn isUnicodeIdStart(cp: u21) bool {
        if (cp < 0x80) {
            return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or cp == '_' or cp == '$';
        }

        // Latin-1 Supplement through Spacing Modifier Letters
        if (cp == 0xAA or cp == 0xB5 or cp == 0xBA) return true;
        if (cp >= 0xC0 and cp <= 0xD6) return true;
        if (cp >= 0xD8 and cp <= 0xF6) return true;
        if (cp >= 0xF8 and cp <= 0x02C1) return true;
        if (cp >= 0x02C6 and cp <= 0x02D1) return true;
        if (cp >= 0x02E0 and cp <= 0x02E4) return true;
        if (cp == 0x02EC or cp == 0x02EE) return true;

        // Greek, Cyrillic, Armenian, Hebrew, Arabic and other scripts up to U+1FFF
        if (cp >= 0x0370 and cp <= 0x0374) return true;
        if (cp >= 0x0376 and cp <= 0x0377) return true;
        if (cp >= 0x037A and cp <= 0x037D) return true;
        if (cp == 0x037F or cp == 0x0386) return true;
        if (cp >= 0x0388 and cp <= 0x038A) return true;
        if (cp == 0x038C) return true;
        if (cp >= 0x038E and cp <= 0x03A1) return true;
        if (cp >= 0x03A3 and cp <= 0x0588) return true;
        if (cp >= 0x05D0 and cp <= 0x05F2) return true;
        if (cp >= 0x0620 and cp <= 0x07EA) return true;
        if (cp == 0x07B1) return true;
        if (cp >= 0x0900 and cp <= 0x1FFF) return true;

        // U+2000-U+20FF: General Punctuation, currency, combining marks — NOT ID_Start
        // Letterlike Symbols (selective)
        if (cp == 0x2118 or cp == 0x212E or cp == 0x2126) return true;
        if (cp >= 0x212A and cp <= 0x212B) return true;
        if (cp >= 0x2160 and cp <= 0x2188) return true;

        // CJK, Hangul, and remaining BMP scripts
        if (cp >= 0x2C00 and cp <= 0xD7FF) return true;
        if (cp >= 0xF900 and cp <= 0xFDCF) return true;
        if (cp >= 0xFDF0 and cp <= 0xFDFB) return true;
        if (cp >= 0xFE70 and cp <= 0xFEFC) return true;
        if (cp >= 0xFF21 and cp <= 0xFF3A) return true;
        if (cp >= 0xFF41 and cp <= 0xFF5A) return true;
        if (cp >= 0xFF66 and cp <= 0xFFDC) return true;

        // Supplementary planes: scripts, CJK extensions
        if (cp >= 0x10000 and cp <= 0x100FA) return true;
        if (cp >= 0x10140 and cp <= 0x10174) return true;
        if (cp >= 0x10280 and cp <= 0x102D0) return true;
        if (cp >= 0x10300 and cp <= 0x10375) return true;
        if (cp >= 0x10380 and cp <= 0x103D5) return true;
        if (cp >= 0x10400 and cp <= 0x1049D) return true;
        if (cp >= 0x104B0 and cp <= 0x104FB) return true;
        if (cp >= 0x10500 and cp <= 0x10563) return true;
        if (cp >= 0x10570 and cp <= 0x105BC) return true;
        if (cp >= 0x10600 and cp <= 0x10767) return true;
        if (cp >= 0x10780 and cp <= 0x107BA) return true;
        if (cp >= 0x10800 and cp <= 0x112DE) return true;
        // SMP scripts: split into sub-ranges to exclude unassigned gaps
        if (cp >= 0x11300 and cp <= 0x11374) return true; // Grantha
        if (cp >= 0x11400 and cp <= 0x1145B) return true; // Newa
        if (cp >= 0x11480 and cp <= 0x114C7) return true; // Tirhuta
        if (cp >= 0x11580 and cp <= 0x115B5) return true; // Siddham
        if (cp >= 0x11600 and cp <= 0x11644) return true; // Modi
        if (cp >= 0x11680 and cp <= 0x116B8) return true; // Takri
        if (cp >= 0x11700 and cp <= 0x1171A) return true; // Ahom
        if (cp >= 0x11800 and cp <= 0x1184F) return true; // Dogra, etc
        if (cp >= 0x11900 and cp <= 0x119A7) return true; // Nandinagari
        if (cp >= 0x119AA and cp <= 0x119D7) return true; // Nandinagari continued
        if (cp >= 0x11A00 and cp <= 0x11A47) return true; // Zanabazar Square
        if (cp >= 0x11A50 and cp <= 0x11AA2) return true; // Soyombo
        if (cp >= 0x11AB0 and cp <= 0x11AF8) return true; // UCAS Extended-A + Pau Cin Hau
        if (cp >= 0x11C00 and cp <= 0x11C6C) return true; // Bhaiksuki
        if (cp >= 0x11C72 and cp <= 0x11C90) return true; // Marchen
        if (cp >= 0x11D00 and cp <= 0x11D36) return true; // Masaram Gondi
        if (cp >= 0x11D60 and cp <= 0x11D8E) return true; // Gunjala Gondi
        if (cp >= 0x11EE0 and cp <= 0x11EF6) return true; // Makasar
        if (cp >= 0x11F00 and cp <= 0x11F10) return true; // Syriac Supplement
        if (cp >= 0x11F12 and cp <= 0x11F3A) return true; // ...
        if (cp >= 0x11FB0 and cp <= 0x11FB0) return true; // Lisu Supplement
        if (cp >= 0x12000 and cp <= 0x12399) return true; // Cuneiform
        if (cp >= 0x12400 and cp <= 0x1246E) return true; // Cuneiform Numbers
        if (cp >= 0x12480 and cp <= 0x12543) return true; // Early Dynastic Cuneiform
        if (cp >= 0x12F90 and cp <= 0x12FF0) return true; // Cypro-Minoan
        if (cp >= 0x13000 and cp <= 0x1342F) return true; // Egyptian Hieroglyphs
        if (cp >= 0x13440 and cp <= 0x13455) return true; // Egyptian Hieroglyph Format Controls
        if (cp >= 0x14400 and cp <= 0x14646) return true; // Anatolian Hieroglyphs
        if (cp >= 0x16800 and cp <= 0x16A38) return true; // Bamum Supplement
        if (cp >= 0x16A40 and cp <= 0x16A5E) return true; // Mro
        if (cp >= 0x16A70 and cp <= 0x16ABE) return true; // Tangsa
        if (cp >= 0x16AD0 and cp <= 0x16AED) return true; // Bassa Vah
        if (cp >= 0x16B00 and cp <= 0x16B36) return true; // Pahawh Hmong
        if (cp >= 0x16B40 and cp <= 0x16B43) return true; // Pahawh Hmong continued
        if (cp >= 0x16E40 and cp <= 0x16E7F) return true; // Medefaidrin
        if (cp >= 0x16F00 and cp <= 0x16F4A) return true; // Miao
        if (cp >= 0x16F50 and cp <= 0x16F87) return true; // Miao continued
        if (cp >= 0x16F93 and cp <= 0x16F9F) return true; // Miao final
        if (cp >= 0x16FE0 and cp <= 0x16FE4) return true; // Ideographic Symbols
        if (cp >= 0x17000 and cp <= 0x187F7) return true; // Tangut
        if (cp >= 0x18800 and cp <= 0x18CD5) return true; // Tangut Components
        if (cp >= 0x18D00 and cp <= 0x18D07) return true; // Tangut Supplement
        if (cp >= 0x1AFF0 and cp <= 0x1AFEF) return true; // Kana Extended-B
        if (cp >= 0x1B000 and cp <= 0x1B2FF) return true;
        if (cp >= 0x1BC00 and cp <= 0x1BC99) return true;
        if (cp >= 0x1D400 and cp <= 0x1D7FF) return true;
        if (cp >= 0x1E000 and cp <= 0x1E943) return true;
        if (cp >= 0x1EE00 and cp <= 0x1EEFF) return true;
        // CJK Extension B..F and CJK Compatibility Ideographs Supplement
        if (cp >= 0x20000 and cp <= 0x2A6DF) return true; // Extension B
        if (cp >= 0x2A700 and cp <= 0x2B739) return true; // Extension C
        if (cp >= 0x2B740 and cp <= 0x2B81D) return true; // Extension D
        if (cp >= 0x2B820 and cp <= 0x2CEA1) return true; // Extension E
        if (cp >= 0x2CEB0 and cp <= 0x2EBE0) return true; // Extension F
        if (cp >= 0x2F800 and cp <= 0x2FA1F) return true; // CJK Compat Ideographs Supplement
        if (cp >= 0x30000 and cp <= 0x323AF) return true;

        return false;
    }

    /// Simplified Unicode ID_Continue check. Includes ID_Start plus combining marks,
    /// digits, connector punctuation (ZWJ/ZWNJ), and other continue-only characters.
    fn isUnicodeIdContinue(cp: u21) bool {
        // All ID_Start characters are also ID_Continue
        if (isUnicodeIdStart(cp)) return true;
        // ASCII digits handled elsewhere; non-ASCII digits and combining marks:
        // U+0300-U+036F: Combining Diacritical Marks
        if (cp >= 0x0300 and cp <= 0x036F) return true;
        // U+0483-U+0487: Cyrillic combining marks
        if (cp >= 0x0483 and cp <= 0x0487) return true;
        // U+0591-U+05BD, U+05BF, U+05C1-U+05C2, U+05C4-U+05C5, U+05C7: Hebrew marks
        if (cp >= 0x0591 and cp <= 0x05C7) return true;
        // U+0610-U+061A: Arabic marks
        if (cp >= 0x0610 and cp <= 0x061A) return true;
        // U+064B-U+065F, U+0670: Arabic combining
        if (cp >= 0x064B and cp <= 0x065F) return true;
        if (cp == 0x0670) return true;
        // U+06D6-U+06DC, U+06DF-U+06E4, U+06E7-U+06E8, U+06EA-U+06ED
        if (cp >= 0x06D6 and cp <= 0x06ED) return true;
        // U+0660-U+0669, U+06F0-U+06F9: Arabic-Indic digits
        if (cp >= 0x0660 and cp <= 0x0669) return true;
        if (cp >= 0x06F0 and cp <= 0x06F9) return true;
        // Devanagari, Bengali, and other Indic combining marks (broad)
        if (cp >= 0x0901 and cp <= 0x0903) return true;
        if (cp >= 0x093C and cp <= 0x094D) return true;
        if (cp >= 0x0951 and cp <= 0x0954) return true;
        if (cp >= 0x0962 and cp <= 0x0963) return true;
        if (cp >= 0x0966 and cp <= 0x096F) return true;
        // U+200C (ZWNJ) and U+200D (ZWJ) — connector punctuation
        if (cp == 0x200C or cp == 0x200D) return true;
        // U+20D0-U+20FF: Combining Diacritical Marks for Symbols
        if (cp >= 0x20D0 and cp <= 0x20FF) return true;
        // U+FE00-U+FE0F: Variation Selectors
        if (cp >= 0xFE00 and cp <= 0xFE0F) return true;
        // U+FE20-U+FE2F: Combining Half Marks
        if (cp >= 0xFE20 and cp <= 0xFE2F) return true;
        // Connector punctuation (Pc category) — valid ID_Continue per Unicode spec
        if (cp == 0x203F or cp == 0x2040 or cp == 0x2054) return true;
        if (cp == 0xFE33 or cp == 0xFE34) return true;
        if (cp >= 0xFE4D and cp <= 0xFE4F) return true;
        if (cp == 0xFF3F) return true;
        // Supplementary plane digits (Nd category) — valid ID_Continue
        // Osmanya digits U+104A0-U+104A9
        if (cp >= 0x104A0 and cp <= 0x104A9) return true;
        return false;
    }

    /// Skip a multi-byte UTF-8 sequence based on the leading byte.
    fn skipUtf8Char(self: *Lexer) void {
        const byte = self.source[self.index];
        if (byte >= 0xF0) self.index += 4 else if (byte >= 0xE0) self.index += 3 else if (byte >= 0xC0) self.index += 2 else self.index += 1;
        if (self.index > self.source.len) self.index = @intCast(self.source.len);
    }

    fn scanIdentifierOrKeyword(self: *Lexer, start: u32) Token {
        // Handle first character: backslash means unicode escape, high bytes mean UTF-8.
        if (self.source[self.index] == '\\') {
            if (!self.skipUnicodeEscape()) {
                // Invalid escape (e.g. \\ or \x) — consume the backslash and continue
                // to build a single identifier token (error recovery like Babel).
                self.index += 1;
            }
        } else if (self.source[self.index] >= 0x80) {
            self.skipUtf8Char();
        } else {
            self.index += 1;
        }
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => self.index += 1,
                '\\' => {
                    if (!self.skipUnicodeEscape()) {
                        // Invalid escape in identifier continuation — consume backslash
                        // and continue scanning (Babel error recovery).
                        self.index += 1;
                        continue;
                    }
                },
                // Multi-byte UTF-8 (non-ASCII identifier characters)
                0x80...0xFF => {
                    // U+2028/U+2029 are line terminators, not identifier chars
                    if (self.isLineSeparator()) break;
                    // Unicode Zs whitespace chars are not identifier chars
                    if (self.isUnicodeSpaceSeparator()) break;
                    // U+00A0 (NBSP, C2 A0) is whitespace
                    if (self.source[self.index] == 0xC2 and
                        self.index + 1 < self.source.len and self.source[self.index + 1] == 0xA0) break;
                    // U+1680 (OGHAM SPACE MARK, E1 9A 80) is whitespace
                    if (self.source[self.index] == 0xE1 and self.index + 2 < self.source.len and
                        self.source[self.index + 1] == 0x9A and self.source[self.index + 2] == 0x80) break;
                    // U+3000 (IDEOGRAPHIC SPACE, E3 80 80) is whitespace
                    if (self.source[self.index] == 0xE3 and self.index + 2 < self.source.len and
                        self.source[self.index + 1] == 0x80 and self.source[self.index + 2] == 0x80) break;
                    // U+FEFF (BOM, EF BB BF) is whitespace
                    if (self.source[self.index] == 0xEF and self.index + 2 < self.source.len and
                        self.source[self.index + 1] == 0xBB and self.source[self.index + 2] == 0xBF) break;
                    // Validate that the character is a valid ID_Continue
                    if (!isUnicodeIdContinue(self.decodeUtf8() orelse 0)) break;
                    self.skipUtf8Char();
                },
                else => break,
            }
        }
        const text = self.source[start..self.index];
        const kw = identifyKeyword(text);
        return .{ .tag = kw orelse .identifier, .start = start, .end = self.index };
    }

    /// Resolve \uXXXX and \u{XXXX} escapes in a raw identifier to its actual name.
    /// Returns the resolved name slice within the provided buffer, or empty on overflow.
    pub fn resolveEscapes(raw: []const u8, buf: *[32]u8) []const u8 {
        var i: usize = 0;
        var out: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == 'u') {
                i += 2;
                var cp: u21 = 0;
                if (i < raw.len and raw[i] == '{') {
                    i += 1;
                    while (i < raw.len and raw[i] != '}') : (i += 1) {
                        const d = hexDigitVal(raw[i]) orelse return buf[0..0];
                        cp = cp * 16 + d;
                    }
                    if (i < raw.len) i += 1;
                } else {
                    var j: usize = 0;
                    while (j < 4 and i < raw.len) : ({
                        j += 1;
                        i += 1;
                    }) {
                        const d = hexDigitVal(raw[i]) orelse return buf[0..0];
                        cp = cp * 16 + d;
                    }
                }
                const len = std.unicode.utf8Encode(cp, buf[out..][0..4]) catch return buf[0..0];
                out += len;
            } else {
                if (out >= buf.len) return buf[0..0];
                buf[out] = raw[i];
                out += 1;
                i += 1;
            }
        }
        return buf[0..out];
    }

    fn hexDigitVal(c: u8) ?u21 {
        if (c >= '0' and c <= '9') return @intCast(c - '0');
        if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
        if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
        return null;
    }

    pub fn identifyKeyword(bytes: []const u8) ?Token.Tag {
        switch (bytes.len) {
            2 => {
                if (eql(bytes, "if")) return .kw_if;
                if (eql(bytes, "in")) return .kw_in;
                if (eql(bytes, "do")) return .kw_do;
                if (eql(bytes, "of")) return .kw_of;
                if (eql(bytes, "as")) return .kw_as;
            },
            3 => {
                if (eql(bytes, "var")) return .kw_var;
                if (eql(bytes, "let")) return .kw_let;
                if (eql(bytes, "for")) return .kw_for;
                if (eql(bytes, "new")) return .kw_new;
                if (eql(bytes, "try")) return .kw_try;
                if (eql(bytes, "get")) return .kw_get;
                if (eql(bytes, "set")) return .kw_set;
            },
            4 => {
                if (eql(bytes, "this")) return .kw_this;
                if (eql(bytes, "else")) return .kw_else;
                if (eql(bytes, "case")) return .kw_case;
                if (eql(bytes, "void")) return .kw_void;
                if (eql(bytes, "with")) return .kw_with;
                if (eql(bytes, "null")) return .kw_null;
                if (eql(bytes, "true")) return .kw_true;
                if (eql(bytes, "from")) return .kw_from;
            },
            5 => {
                if (eql(bytes, "break")) return .kw_break;
                if (eql(bytes, "catch")) return .kw_catch;
                if (eql(bytes, "class")) return .kw_class;
                if (eql(bytes, "const")) return .kw_const;
                if (eql(bytes, "false")) return .kw_false;
                if (eql(bytes, "super")) return .kw_super;
                if (eql(bytes, "throw")) return .kw_throw;
                if (eql(bytes, "while")) return .kw_while;
                if (eql(bytes, "yield")) return .kw_yield;
                if (eql(bytes, "async")) return .kw_async;
                if (eql(bytes, "await")) return .kw_await;
            },
            6 => {
                if (eql(bytes, "return")) return .kw_return;
                if (eql(bytes, "switch")) return .kw_switch;
                if (eql(bytes, "typeof")) return .kw_typeof;
                if (eql(bytes, "delete")) return .kw_delete;
                if (eql(bytes, "export")) return .kw_export;
                if (eql(bytes, "import")) return .kw_import;
                if (eql(bytes, "static")) return .kw_static;
            },
            7 => {
                if (eql(bytes, "default")) return .kw_default;
                if (eql(bytes, "extends")) return .kw_extends;
                if (eql(bytes, "finally")) return .kw_finally;
            },
            8 => {
                if (eql(bytes, "continue")) return .kw_continue;
                if (eql(bytes, "debugger")) return .kw_debugger;
                if (eql(bytes, "function")) return .kw_function;
            },
            10 => {
                if (eql(bytes, "instanceof")) return .kw_instanceof;
            },
            else => {},
        }
        return null;
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};
