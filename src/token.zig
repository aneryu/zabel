const std = @import("std");

pub const TokenIndex = enum(u32) { _ };

pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    pub const Tag = enum(u8) {
        // === Punctuation ===
        l_paren, // (
        r_paren, // )
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]
        semicolon, // ;
        comma, // ,
        dot, // .
        ellipsis, // ...
        optional_chain, // ?.
        question, // ?
        colon, // :
        hash, // # (private fields)

        // === Operators ===
        plus, // +
        minus, // -
        asterisk, // *
        slash, // /
        percent, // %
        power, // **
        ampersand, // &
        pipe, // |
        caret, // ^
        tilde, // ~
        bang, // !
        equal, // =
        less_than, // <
        greater_than, // >
        plus_plus, // ++
        minus_minus, // --
        less_less, // <<
        greater_greater, // >>
        greater_greater_greater, // >>>
        equal_equal, // ==
        bang_equal, // !=
        equal_equal_equal, // ===
        bang_equal_equal, // !==
        less_equal, // <=
        greater_equal, // >=
        ampersand_ampersand, // &&
        pipe_pipe, // ||
        question_question, // ??
        arrow, // =>

        // === Assignment operators ===
        plus_equal, // +=
        minus_equal, // -=
        asterisk_equal, // *=
        slash_equal, // /=
        percent_equal, // %=
        power_equal, // **=
        ampersand_equal, // &=
        pipe_equal, // |=
        caret_equal, // ^=
        less_less_equal, // <<=
        greater_greater_equal, // >>=
        greater_greater_greater_equal, // >>>=
        ampersand_ampersand_equal, // &&=
        pipe_pipe_equal, // ||=
        question_question_equal, // ??=

        // === Literals ===
        numeric, // 42, 3.14, 0xff, 0b101, 0o77, 1_000
        bigint, // 42n
        string, // "hello", 'world'
        template_no_sub, // `no substitution`
        template_head, // `hello ${
        template_middle, // } world ${
        template_tail, // } end`
        regex, // /pattern/flags

        // === Keywords ===
        kw_break,
        kw_case,
        kw_catch,
        kw_class,
        kw_const,
        kw_continue,
        kw_debugger,
        kw_default,
        kw_delete,
        kw_do,
        kw_else,
        kw_export,
        kw_extends,
        kw_false,
        kw_finally,
        kw_for,
        kw_function,
        kw_if,
        kw_import,
        kw_in,
        kw_instanceof,
        kw_let,
        kw_new,
        kw_null,
        kw_return,
        kw_super,
        kw_switch,
        kw_this,
        kw_throw,
        kw_true,
        kw_try,
        kw_typeof,
        kw_var,
        kw_void,
        kw_while,
        kw_with,
        kw_yield,
        kw_async,
        kw_await,
        kw_of,
        kw_static,
        kw_get,
        kw_set,
        kw_from,
        kw_as,

        // === Identifiers ===
        identifier,

        // === Special ===
        eof,
        invalid,

        /// Returns true if this token is a keyword.
        pub fn isKeyword(self: Tag) bool {
            return @intFromEnum(self) >= @intFromEnum(Tag.kw_break) and
                @intFromEnum(self) <= @intFromEnum(Tag.kw_as);
        }

        /// Returns true if this keyword is a reserved word that cannot be used as a binding name.
        /// This excludes contextual keywords like get, set, let, of, static, async, await, from, as.
        pub fn isReservedKeyword(self: Tag) bool {
            return switch (self) {
                .kw_break, .kw_case, .kw_catch, .kw_class, .kw_const, .kw_continue,
                .kw_debugger, .kw_default, .kw_delete, .kw_do, .kw_else, .kw_export,
                .kw_extends, .kw_false, .kw_finally, .kw_for, .kw_function, .kw_if,
                .kw_import, .kw_in, .kw_instanceof, .kw_new, .kw_null, .kw_return,
                .kw_super, .kw_switch, .kw_this, .kw_throw, .kw_true, .kw_try,
                .kw_typeof, .kw_var, .kw_void, .kw_while, .kw_with,
                => true,
                else => false,
            };
        }

        /// Returns true if this token is an assignment operator.
        pub fn isAssignment(self: Tag) bool {
            return switch (self) {
                .equal,
                .plus_equal,
                .minus_equal,
                .asterisk_equal,
                .slash_equal,
                .percent_equal,
                .power_equal,
                .ampersand_equal,
                .pipe_equal,
                .caret_equal,
                .less_less_equal,
                .greater_greater_equal,
                .greater_greater_greater_equal,
                .ampersand_ampersand_equal,
                .pipe_pipe_equal,
                .question_question_equal,
                => true,
                else => false,
            };
        }
    };
};
