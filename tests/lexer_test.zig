const std = @import("std");
const zig_babal = @import("zig_babal");
const Lexer = zig_babal.Lexer;
const Token = zig_babal.Token;

fn expectTokens(source: []const u8, expected_tags: []const Token.Tag) !void {
    const result = try Lexer.tokenize(std.testing.allocator, source);
    defer {
        var tokens = result.tokens;
        tokens.deinit(std.testing.allocator);
        var line_offsets = result.line_offsets;
        line_offsets.deinit(std.testing.allocator);
        var comments = result.comments;
        comments.deinit(std.testing.allocator);
    }
    const tags = result.tokens.items(.tag);
    try std.testing.expectEqual(expected_tags.len, tags.len);
    for (expected_tags, tags) |expected, actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

test "empty source" {
    try expectTokens("", &.{.eof});
}

test "whitespace only" {
    try expectTokens("  \t\n  ", &.{.eof});
}

test "single char punctuation" {
    try expectTokens("( ) { } [ ] ; , :", &.{
        .l_paren, .r_paren, .l_brace, .r_brace,
        .l_bracket, .r_bracket, .semicolon, .comma, .colon, .eof,
    });
}

test "operators" {
    try expectTokens("+ - * / % = < > !", &.{
        .plus, .minus, .asterisk, .slash, .percent,
        .equal, .less_than, .greater_than, .bang, .eof,
    });
}

test "multi-char operators" {
    try expectTokens("=== !== == != <= >= && || ??", &.{
        .equal_equal_equal, .bang_equal_equal,
        .equal_equal, .bang_equal,
        .less_equal, .greater_equal,
        .ampersand_ampersand, .pipe_pipe, .question_question, .eof,
    });
}

test "arrow and ellipsis" {
    try expectTokens("=> ...", &.{ .arrow, .ellipsis, .eof });
}

test "line comment" {
    try expectTokens("a // comment\nb", &.{ .identifier, .identifier, .eof });
}

test "block comment" {
    try expectTokens("a /* block */ b", &.{ .identifier, .identifier, .eof });
}

test "identifiers" {
    try expectTokens("foo bar _private $jquery", &.{
        .identifier, .identifier, .identifier, .identifier, .eof,
    });
}

test "keywords" {
    try expectTokens("var let const function class if else", &.{
        .kw_var, .kw_let, .kw_const, .kw_function, .kw_class, .kw_if, .kw_else, .eof,
    });
}

test "contextual keywords" {
    try expectTokens("async await yield of from as get set static", &.{
        .kw_async, .kw_await, .kw_yield, .kw_of, .kw_from, .kw_as, .kw_get, .kw_set, .kw_static, .eof,
    });
}

test "numeric literals" {
    try expectTokens("42 3.14 0xff 0b101 0o77 1_000 .5", &.{
        .numeric, .numeric, .numeric, .numeric, .numeric, .numeric, .numeric, .eof,
    });
}

test "bigint literals" {
    try expectTokens("42n 0xFFn 0b101n", &.{
        .bigint, .bigint, .bigint, .eof,
    });
}

test "string literals" {
    try expectTokens(
        \\"hello" 'world' "escaped\"quote"
    , &.{
        .string, .string, .string, .eof,
    });
}

test "template literals" {
    try expectTokens("`no sub`", &.{ .template_no_sub, .eof });
    try expectTokens("`hello ${", &.{ .template_head, .eof });
}

test "assignment operators" {
    try expectTokens("+= -= *= /= %= **= &&= ||= ??=", &.{
        .plus_equal, .minus_equal, .asterisk_equal, .slash_equal,
        .percent_equal, .power_equal, .ampersand_ampersand_equal,
        .pipe_pipe_equal, .question_question_equal, .eof,
    });
}

test "shift operators" {
    try expectTokens("<< >> >>> <<= >>= >>>=", &.{
        .less_less, .greater_greater, .greater_greater_greater,
        .less_less_equal, .greater_greater_equal, .greater_greater_greater_equal, .eof,
    });
}

test "optional chain" {
    try expectTokens("a?.b", &.{ .identifier, .optional_chain, .identifier, .eof });
}

test "hash for private fields" {
    try expectTokens("#foo", &.{ .hash, .identifier, .eof });
}

test "token positions" {
    const result = try Lexer.tokenize(std.testing.allocator, "a + b");
    defer {
        var tokens = result.tokens;
        tokens.deinit(std.testing.allocator);
        var line_offsets = result.line_offsets;
        line_offsets.deinit(std.testing.allocator);
        var comments = result.comments;
        comments.deinit(std.testing.allocator);
    }
    const starts = result.tokens.items(.start);
    try std.testing.expectEqual(@as(u32, 0), starts[0]); // a
    try std.testing.expectEqual(@as(u32, 2), starts[1]); // +
    try std.testing.expectEqual(@as(u32, 4), starts[2]); // b
}
