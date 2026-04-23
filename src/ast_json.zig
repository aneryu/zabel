const std = @import("std");
const Ast = @import("ast.zig").Ast;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const CommentRange = @import("ast.zig").CommentRange;
const Comment = @import("lexer.zig").Comment;
const Token = @import("token.zig").Token;
const TokenIndex = @import("ast.zig").TokenIndex;
const Parser = @import("parser.zig").Parser;

// TypeScript class modifier bitmask constants (mirrored from parser.zig)
const TS_MOD_PUBLIC = Parser.TS_MOD_PUBLIC;
const TS_MOD_PRIVATE = Parser.TS_MOD_PRIVATE;
const TS_MOD_PROTECTED = Parser.TS_MOD_PROTECTED;
const TS_MOD_READONLY = Parser.TS_MOD_READONLY;
const TS_MOD_ABSTRACT = Parser.TS_MOD_ABSTRACT;
const TS_MOD_DECLARE = Parser.TS_MOD_DECLARE;
const TS_MOD_OVERRIDE = Parser.TS_MOD_OVERRIDE;
const TS_MOD_IN = Parser.TS_MOD_IN;
const TS_MOD_OUT = Parser.TS_MOD_OUT;

/// Parse a digit string in the given radix, matching Babel's error-recovery behavior:
/// invalid digits (value >= radix but <= 9) are treated as 0 and accumulation continues.
fn parseRadixBabelCompat(digits: []const u8, radix: u8) i64 {
    var total: i64 = 0;
    for (digits) |c| {
        var val: i64 = undefined;
        if (c >= '0' and c <= '9') {
            val = @intCast(c - '0');
        } else if (c >= 'a' and c <= 'f') {
            val = @intCast(c - 'a' + 10);
        } else if (c >= 'A' and c <= 'F') {
            val = @intCast(c - 'A' + 10);
        } else {
            break;
        }
        if (val >= radix) {
            // Babel treats invalid digits (<=9) as 0 and continues
            if (val <= 9) {
                val = 0;
            } else {
                break;
            }
        }
        total = total * radix + val;
    }
    return total;
}

/// Check if template content contains escape sequences that make cooked=null.
/// In template literals, legacy octal escapes (\8, \9, \0N, \1-\7) and
/// invalid unicode/hex escapes cause the cooked value to be null.
fn hasInvalidTemplateEscape(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 1;
            switch (content[i]) {
                '0' => {
                    // \0 followed by digit = legacy octal
                    if (i + 1 < content.len and content[i + 1] >= '0' and content[i + 1] <= '9') {
                        return true;
                    }
                    i += 1;
                },
                '1', '2', '3', '4', '5', '6', '7', '8', '9' => return true,
                'x' => {
                    // \xHH — need exactly 2 hex digits
                    i += 1;
                    if (i + 2 > content.len) return true;
                    _ = std.fmt.parseInt(u8, content[i .. i + 2], 16) catch return true;
                    i += 2;
                },
                'u' => {
                    i += 1;
                    if (i >= content.len) return true;
                    if (content[i] == '{') {
                        i += 1;
                        const close = std.mem.indexOfScalarPos(u8, content, i, '}') orelse return true;
                        // Check for valid hex without underscores
                        const hex_str = content[i..close];
                        if (hex_str.len == 0) return true;
                        for (hex_str) |c| {
                            if (!std.ascii.isHex(c)) return true;
                        }
                        const val = std.fmt.parseInt(u21, hex_str, 16) catch return true;
                        if (val > 0x10FFFF) return true;
                        i = close + 1;
                    } else {
                        // \uHHHH — need exactly 4 hex digits
                        if (i + 4 > content.len) return true;
                        for (content[i .. i + 4]) |c| {
                            if (!std.ascii.isHex(c)) return true;
                        }
                        _ = std.fmt.parseInt(u16, content[i .. i + 4], 16) catch return true;
                        i += 4;
                    }
                },
                else => {
                    i += 1;
                },
            }
        } else {
            i += 1;
        }
    }
    return false;
}

/// Decode HTML entities in a JSX string, writing the decoded result via the writer.
/// Handles: &name; (named entities), &#NNN; (decimal), &#xHHH; (hex).
/// Unknown or malformed entities are left as-is.
fn writeJsxDecodedString(writer: anytype, raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            // Try to parse an entity
            if (i + 1 < raw.len and raw[i + 1] == '#') {
                // Numeric entity
                if (i + 2 < raw.len and (raw[i + 2] == 'x' or raw[i + 2] == 'X')) {
                    // Hex: &#xHHH;
                    var j = i + 3;
                    while (j < raw.len and std.ascii.isHex(raw[j])) : (j += 1) {}
                    if (j > i + 3 and j < raw.len and raw[j] == ';') {
                        const hex_str = raw[i + 3 .. j];
                        const code_point = std.fmt.parseInt(u21, hex_str, 16) catch {
                            try writeJsonEscapedByte(writer, raw[i]);
                            i += 1;
                            continue;
                        };
                        try writeUtf8CodePoint(writer, code_point);
                        i = j + 1;
                        continue;
                    }
                } else {
                    // Decimal: &#NNN;
                    var j = i + 2;
                    while (j < raw.len and raw[j] >= '0' and raw[j] <= '9') : (j += 1) {}
                    if (j > i + 2 and j < raw.len and raw[j] == ';') {
                        const dec_str = raw[i + 2 .. j];
                        const code_point = std.fmt.parseInt(u21, dec_str, 10) catch {
                            try writeJsonEscapedByte(writer, raw[i]);
                            i += 1;
                            continue;
                        };
                        try writeUtf8CodePoint(writer, code_point);
                        i = j + 1;
                        continue;
                    }
                }
            } else {
                // Named entity: &name;
                var j = i + 1;
                while (j < raw.len and std.ascii.isAlphanumeric(raw[j])) : (j += 1) {}
                if (j > i + 1 and j < raw.len and raw[j] == ';') {
                    const name = raw[i + 1 .. j];
                    if (lookupHtmlEntity(name)) |code_point| {
                        try writeUtf8CodePoint(writer, code_point);
                        i = j + 1;
                        continue;
                    }
                }
            }
            // Not a valid entity — emit the `&` literally
            try writeJsonEscapedByte(writer, raw[i]);
            i += 1;
        } else {
            try writeJsonEscapedByte(writer, raw[i]);
            i += 1;
        }
    }
}

/// Write a single byte, applying JSON string escaping.
fn writeJsonEscapedByte(writer: anytype, c: u8) !void {
    switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        else => {
            if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            }
        },
    }
}

/// Write a Unicode code point as UTF-8, with JSON string escaping for control chars.
fn writeUtf8CodePoint(writer: anytype, code_point: u21) !void {
    if (code_point == 0) {
        // Null byte — emit as \0 or \u0000 for JSON
        try writer.writeAll("\\u0000");
        return;
    }
    if (code_point < 0x80) {
        const c: u8 = @intCast(code_point);
        try writeJsonEscapedByte(writer, c);
        return;
    }
    // Encode as UTF-8
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code_point, &buf) catch {
        // Invalid code point — emit replacement character
        try writer.writeAll("\xEF\xBF\xBD");
        return;
    };
    try writer.writeAll(buf[0..len]);
}

/// Look up an HTML entity name and return its Unicode code point.
fn lookupHtmlEntity(name: []const u8) ?u21 {
    // Common HTML5 entities (most frequently used in JSX)
    const entities = [_]struct { name: []const u8, code: u21 }{
        .{ .name = "amp", .code = '&' },
        .{ .name = "lt", .code = '<' },
        .{ .name = "gt", .code = '>' },
        .{ .name = "quot", .code = '"' },
        .{ .name = "apos", .code = '\'' },
        .{ .name = "nbsp", .code = 0xA0 },
        .{ .name = "iexcl", .code = 0xA1 },
        .{ .name = "cent", .code = 0xA2 },
        .{ .name = "pound", .code = 0xA3 },
        .{ .name = "curren", .code = 0xA4 },
        .{ .name = "yen", .code = 0xA5 },
        .{ .name = "brvbar", .code = 0xA6 },
        .{ .name = "sect", .code = 0xA7 },
        .{ .name = "uml", .code = 0xA8 },
        .{ .name = "copy", .code = 0xA9 },
        .{ .name = "ordf", .code = 0xAA },
        .{ .name = "laquo", .code = 0xAB },
        .{ .name = "not", .code = 0xAC },
        .{ .name = "shy", .code = 0xAD },
        .{ .name = "reg", .code = 0xAE },
        .{ .name = "macr", .code = 0xAF },
        .{ .name = "deg", .code = 0xB0 },
        .{ .name = "plusmn", .code = 0xB1 },
        .{ .name = "sup2", .code = 0xB2 },
        .{ .name = "sup3", .code = 0xB3 },
        .{ .name = "acute", .code = 0xB4 },
        .{ .name = "micro", .code = 0xB5 },
        .{ .name = "para", .code = 0xB6 },
        .{ .name = "middot", .code = 0xB7 },
        .{ .name = "cedil", .code = 0xB8 },
        .{ .name = "sup1", .code = 0xB9 },
        .{ .name = "ordm", .code = 0xBA },
        .{ .name = "raquo", .code = 0xBB },
        .{ .name = "frac14", .code = 0xBC },
        .{ .name = "frac12", .code = 0xBD },
        .{ .name = "frac34", .code = 0xBE },
        .{ .name = "iquest", .code = 0xBF },
        .{ .name = "Agrave", .code = 0xC0 },
        .{ .name = "Aacute", .code = 0xC1 },
        .{ .name = "Acirc", .code = 0xC2 },
        .{ .name = "Atilde", .code = 0xC3 },
        .{ .name = "Auml", .code = 0xC4 },
        .{ .name = "Aring", .code = 0xC5 },
        .{ .name = "AElig", .code = 0xC6 },
        .{ .name = "Ccedil", .code = 0xC7 },
        .{ .name = "Egrave", .code = 0xC8 },
        .{ .name = "Eacute", .code = 0xC9 },
        .{ .name = "Ecirc", .code = 0xCA },
        .{ .name = "Euml", .code = 0xCB },
        .{ .name = "Igrave", .code = 0xCC },
        .{ .name = "Iacute", .code = 0xCD },
        .{ .name = "Icirc", .code = 0xCE },
        .{ .name = "Iuml", .code = 0xCF },
        .{ .name = "ETH", .code = 0xD0 },
        .{ .name = "Ntilde", .code = 0xD1 },
        .{ .name = "Ograve", .code = 0xD2 },
        .{ .name = "Oacute", .code = 0xD3 },
        .{ .name = "Ocirc", .code = 0xD4 },
        .{ .name = "Otilde", .code = 0xD5 },
        .{ .name = "Ouml", .code = 0xD6 },
        .{ .name = "times", .code = 0xD7 },
        .{ .name = "Oslash", .code = 0xD8 },
        .{ .name = "Ugrave", .code = 0xD9 },
        .{ .name = "Uacute", .code = 0xDA },
        .{ .name = "Ucirc", .code = 0xDB },
        .{ .name = "Uuml", .code = 0xDC },
        .{ .name = "Yacute", .code = 0xDD },
        .{ .name = "THORN", .code = 0xDE },
        .{ .name = "szlig", .code = 0xDF },
        .{ .name = "agrave", .code = 0xE0 },
        .{ .name = "aacute", .code = 0xE1 },
        .{ .name = "acirc", .code = 0xE2 },
        .{ .name = "atilde", .code = 0xE3 },
        .{ .name = "auml", .code = 0xE4 },
        .{ .name = "aring", .code = 0xE5 },
        .{ .name = "aelig", .code = 0xE6 },
        .{ .name = "ccedil", .code = 0xE7 },
        .{ .name = "egrave", .code = 0xE8 },
        .{ .name = "eacute", .code = 0xE9 },
        .{ .name = "ecirc", .code = 0xEA },
        .{ .name = "euml", .code = 0xEB },
        .{ .name = "igrave", .code = 0xEC },
        .{ .name = "iacute", .code = 0xED },
        .{ .name = "icirc", .code = 0xEE },
        .{ .name = "iuml", .code = 0xEF },
        .{ .name = "eth", .code = 0xF0 },
        .{ .name = "ntilde", .code = 0xF1 },
        .{ .name = "ograve", .code = 0xF2 },
        .{ .name = "oacute", .code = 0xF3 },
        .{ .name = "ocirc", .code = 0xF4 },
        .{ .name = "otilde", .code = 0xF5 },
        .{ .name = "ouml", .code = 0xF6 },
        .{ .name = "divide", .code = 0xF7 },
        .{ .name = "oslash", .code = 0xF8 },
        .{ .name = "ugrave", .code = 0xF9 },
        .{ .name = "uacute", .code = 0xFA },
        .{ .name = "ucirc", .code = 0xFB },
        .{ .name = "uuml", .code = 0xFC },
        .{ .name = "yacute", .code = 0xFD },
        .{ .name = "thorn", .code = 0xFE },
        .{ .name = "yuml", .code = 0xFF },
        // Extended entities
        .{ .name = "OElig", .code = 0x152 },
        .{ .name = "oelig", .code = 0x153 },
        .{ .name = "Scaron", .code = 0x160 },
        .{ .name = "scaron", .code = 0x161 },
        .{ .name = "Yuml", .code = 0x178 },
        .{ .name = "fnof", .code = 0x192 },
        .{ .name = "circ", .code = 0x2C6 },
        .{ .name = "tilde", .code = 0x2DC },
        .{ .name = "Alpha", .code = 0x391 },
        .{ .name = "Beta", .code = 0x392 },
        .{ .name = "Gamma", .code = 0x393 },
        .{ .name = "Delta", .code = 0x394 },
        .{ .name = "Epsilon", .code = 0x395 },
        .{ .name = "Zeta", .code = 0x396 },
        .{ .name = "Eta", .code = 0x397 },
        .{ .name = "Theta", .code = 0x398 },
        .{ .name = "Iota", .code = 0x399 },
        .{ .name = "Kappa", .code = 0x39A },
        .{ .name = "Lambda", .code = 0x39B },
        .{ .name = "Mu", .code = 0x39C },
        .{ .name = "Nu", .code = 0x39D },
        .{ .name = "Xi", .code = 0x39E },
        .{ .name = "Omicron", .code = 0x39F },
        .{ .name = "Pi", .code = 0x3A0 },
        .{ .name = "Rho", .code = 0x3A1 },
        .{ .name = "Sigma", .code = 0x3A3 },
        .{ .name = "Tau", .code = 0x3A4 },
        .{ .name = "Upsilon", .code = 0x3A5 },
        .{ .name = "Phi", .code = 0x3A6 },
        .{ .name = "Chi", .code = 0x3A7 },
        .{ .name = "Psi", .code = 0x3A8 },
        .{ .name = "Omega", .code = 0x3A9 },
        .{ .name = "alpha", .code = 0x3B1 },
        .{ .name = "beta", .code = 0x3B2 },
        .{ .name = "gamma", .code = 0x3B3 },
        .{ .name = "delta", .code = 0x3B4 },
        .{ .name = "epsilon", .code = 0x3B5 },
        .{ .name = "zeta", .code = 0x3B6 },
        .{ .name = "eta", .code = 0x3B7 },
        .{ .name = "theta", .code = 0x3B8 },
        .{ .name = "iota", .code = 0x3B9 },
        .{ .name = "kappa", .code = 0x3BA },
        .{ .name = "lambda", .code = 0x3BB },
        .{ .name = "mu", .code = 0x3BC },
        .{ .name = "nu", .code = 0x3BD },
        .{ .name = "xi", .code = 0x3BE },
        .{ .name = "omicron", .code = 0x3BF },
        .{ .name = "pi", .code = 0x3C0 },
        .{ .name = "rho", .code = 0x3C1 },
        .{ .name = "sigmaf", .code = 0x3C2 },
        .{ .name = "sigma", .code = 0x3C3 },
        .{ .name = "tau", .code = 0x3C4 },
        .{ .name = "upsilon", .code = 0x3C5 },
        .{ .name = "phi", .code = 0x3C6 },
        .{ .name = "chi", .code = 0x3C7 },
        .{ .name = "psi", .code = 0x3C8 },
        .{ .name = "omega", .code = 0x3C9 },
        .{ .name = "thetasym", .code = 0x3D1 },
        .{ .name = "upsih", .code = 0x3D2 },
        .{ .name = "piv", .code = 0x3D6 },
        .{ .name = "ensp", .code = 0x2002 },
        .{ .name = "emsp", .code = 0x2003 },
        .{ .name = "thinsp", .code = 0x2009 },
        .{ .name = "zwnj", .code = 0x200C },
        .{ .name = "zwj", .code = 0x200D },
        .{ .name = "lrm", .code = 0x200E },
        .{ .name = "rlm", .code = 0x200F },
        .{ .name = "ndash", .code = 0x2013 },
        .{ .name = "mdash", .code = 0x2014 },
        .{ .name = "lsquo", .code = 0x2018 },
        .{ .name = "rsquo", .code = 0x2019 },
        .{ .name = "sbquo", .code = 0x201A },
        .{ .name = "ldquo", .code = 0x201C },
        .{ .name = "rdquo", .code = 0x201D },
        .{ .name = "bdquo", .code = 0x201E },
        .{ .name = "dagger", .code = 0x2020 },
        .{ .name = "Dagger", .code = 0x2021 },
        .{ .name = "bull", .code = 0x2022 },
        .{ .name = "hellip", .code = 0x2026 },
        .{ .name = "permil", .code = 0x2030 },
        .{ .name = "prime", .code = 0x2032 },
        .{ .name = "Prime", .code = 0x2033 },
        .{ .name = "lsaquo", .code = 0x2039 },
        .{ .name = "rsaquo", .code = 0x203A },
        .{ .name = "oline", .code = 0x203E },
        .{ .name = "frasl", .code = 0x2044 },
        .{ .name = "euro", .code = 0x20AC },
        .{ .name = "image", .code = 0x2111 },
        .{ .name = "weierp", .code = 0x2118 },
        .{ .name = "real", .code = 0x211C },
        .{ .name = "trade", .code = 0x2122 },
        .{ .name = "alefsym", .code = 0x2135 },
        .{ .name = "larr", .code = 0x2190 },
        .{ .name = "uarr", .code = 0x2191 },
        .{ .name = "rarr", .code = 0x2192 },
        .{ .name = "darr", .code = 0x2193 },
        .{ .name = "harr", .code = 0x2194 },
        .{ .name = "crarr", .code = 0x21B5 },
        .{ .name = "lArr", .code = 0x21D0 },
        .{ .name = "uArr", .code = 0x21D1 },
        .{ .name = "rArr", .code = 0x21D2 },
        .{ .name = "dArr", .code = 0x21D3 },
        .{ .name = "hArr", .code = 0x21D4 },
        .{ .name = "nabla", .code = 0x2207 },
        .{ .name = "isin", .code = 0x2208 },
        .{ .name = "notin", .code = 0x2209 },
        .{ .name = "ni", .code = 0x220B },
        .{ .name = "prod", .code = 0x220F },
        .{ .name = "sum", .code = 0x2211 },
        .{ .name = "minus", .code = 0x2212 },
        .{ .name = "lowast", .code = 0x2217 },
        .{ .name = "radic", .code = 0x221A },
        .{ .name = "prop", .code = 0x221D },
        .{ .name = "infin", .code = 0x221E },
        .{ .name = "ang", .code = 0x2220 },
        .{ .name = "and", .code = 0x2227 },
        .{ .name = "or", .code = 0x2228 },
        .{ .name = "cap", .code = 0x2229 },
        .{ .name = "cup", .code = 0x222A },
        .{ .name = "int", .code = 0x222B },
        .{ .name = "there4", .code = 0x2234 },
        .{ .name = "sim", .code = 0x223C },
        .{ .name = "cong", .code = 0x2245 },
        .{ .name = "asymp", .code = 0x2248 },
        .{ .name = "ne", .code = 0x2260 },
        .{ .name = "equiv", .code = 0x2261 },
        .{ .name = "le", .code = 0x2264 },
        .{ .name = "ge", .code = 0x2265 },
        .{ .name = "sub", .code = 0x2282 },
        .{ .name = "sup", .code = 0x2283 },
        .{ .name = "nsub", .code = 0x2284 },
        .{ .name = "sube", .code = 0x2286 },
        .{ .name = "supe", .code = 0x2287 },
        .{ .name = "oplus", .code = 0x2295 },
        .{ .name = "otimes", .code = 0x2297 },
        .{ .name = "perp", .code = 0x22A5 },
        .{ .name = "sdot", .code = 0x22C5 },
        .{ .name = "lceil", .code = 0x2308 },
        .{ .name = "rceil", .code = 0x2309 },
        .{ .name = "lfloor", .code = 0x230A },
        .{ .name = "rfloor", .code = 0x230B },
        .{ .name = "lang", .code = 0x2329 },
        .{ .name = "rang", .code = 0x232A },
        .{ .name = "loz", .code = 0x25CA },
        .{ .name = "spades", .code = 0x2660 },
        .{ .name = "clubs", .code = 0x2663 },
        .{ .name = "hearts", .code = 0x2665 },
        .{ .name = "diams", .code = 0x2666 },
    };

    for (entities) |ent| {
        if (std.mem.eql(u8, name, ent.name)) return ent.code;
    }
    return null;
}

const TokenTypeInfo = struct {
    label: []const u8,
    keyword: ?[]const u8 = null,
    before_expr: bool = false,
    starts_expr: bool = false,
    is_loop: bool = false,
    is_assign: bool = false,
    prefix: bool = false,
    postfix: bool = false,
    binop: ?u8 = null,
};

fn tokenTypeInfo(tag: Token.Tag) TokenTypeInfo {
    return switch (tag) {
        // Punctuation
        .l_paren => .{ .label = "(", .before_expr = true, .starts_expr = true },
        .r_paren => .{ .label = ")" },
        .l_brace => .{ .label = "{", .before_expr = true, .starts_expr = true },
        .r_brace => .{ .label = "}" },
        .l_bracket => .{ .label = "[", .before_expr = true, .starts_expr = true },
        .r_bracket => .{ .label = "]" },
        .semicolon => .{ .label = ";", .before_expr = true },
        .comma => .{ .label = ",", .before_expr = true },
        .dot => .{ .label = "." },
        .ellipsis => .{ .label = "...", .before_expr = true },
        .optional_chain => .{ .label = "?." },
        .question => .{ .label = "?", .before_expr = true },
        .colon => .{ .label = ":", .before_expr = true },
        .hash => .{ .label = "#" },
        // Operators
        .plus => .{ .label = "+/-", .before_expr = true, .starts_expr = true, .prefix = true, .binop = 9 },
        .minus => .{ .label = "+/-", .before_expr = true, .starts_expr = true, .prefix = true, .binop = 9 },
        .asterisk => .{ .label = "*", .before_expr = true, .binop = 10 },
        .slash => .{ .label = "/", .before_expr = true, .binop = 10 },
        .percent => .{ .label = "%", .before_expr = true, .binop = 10 },
        .power => .{ .label = "**", .before_expr = true },
        .ampersand => .{ .label = "&", .before_expr = true, .binop = 6 },
        .pipe => .{ .label = "|", .before_expr = true, .binop = 4 },
        .caret => .{ .label = "^", .before_expr = true, .binop = 5 },
        .tilde => .{ .label = "prefix", .before_expr = true, .starts_expr = true, .prefix = true },
        .bang => .{ .label = "prefix", .before_expr = true, .starts_expr = true, .prefix = true },
        .equal => .{ .label = "=", .before_expr = true, .is_assign = true },
        .less_than => .{ .label = "</>/<=/>=", .before_expr = true, .binop = 7 },
        .greater_than => .{ .label = "</>/<=/>=", .before_expr = true, .binop = 7 },
        .plus_plus => .{ .label = "++/--", .starts_expr = true, .prefix = true, .postfix = true },
        .minus_minus => .{ .label = "++/--", .starts_expr = true, .prefix = true, .postfix = true },
        .less_less => .{ .label = "<<", .before_expr = true, .binop = 8 },
        .greater_greater => .{ .label = ">>", .before_expr = true, .binop = 8 },
        .greater_greater_greater => .{ .label = ">>>", .before_expr = true, .binop = 8 },
        .equal_equal => .{ .label = "==/!=", .before_expr = true, .binop = 6 },
        .bang_equal => .{ .label = "==/!=", .before_expr = true, .binop = 6 },
        .equal_equal_equal => .{ .label = "===/!==", .before_expr = true, .binop = 6 },
        .bang_equal_equal => .{ .label = "===/!==", .before_expr = true, .binop = 6 },
        .less_equal => .{ .label = "</>/<=/>=", .before_expr = true, .binop = 7 },
        .greater_equal => .{ .label = "</>/<=/>=", .before_expr = true, .binop = 7 },
        .ampersand_ampersand => .{ .label = "&&", .before_expr = true, .binop = 2 },
        .pipe_pipe => .{ .label = "||", .before_expr = true, .binop = 1 },
        .question_question => .{ .label = "??", .before_expr = true, .binop = 1 },
        .arrow => .{ .label = "=>", .before_expr = true },
        // Assignment operators
        .plus_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .minus_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .asterisk_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .slash_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .percent_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .power_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .ampersand_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .pipe_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .caret_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .less_less_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .greater_greater_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .greater_greater_greater_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .ampersand_ampersand_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .pipe_pipe_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        .question_question_equal => .{ .label = "_=", .before_expr = true, .is_assign = true },
        // Literals
        .numeric => .{ .label = "num", .starts_expr = true },
        .bigint => .{ .label = "bigint", .starts_expr = true },
        .string => .{ .label = "string", .starts_expr = true },
        .template_no_sub => .{ .label = "...`", .starts_expr = true },
        .template_head => .{ .label = "...${", .before_expr = true, .starts_expr = true },
        .template_middle => .{ .label = "...${", .before_expr = true, .starts_expr = true },
        .template_tail => .{ .label = "...`", .starts_expr = true },
        .regex => .{ .label = "regexp", .starts_expr = true },
        // Keywords
        .kw_break => .{ .label = "break", .keyword = "break" },
        .kw_case => .{ .label = "case", .keyword = "case", .before_expr = true },
        .kw_catch => .{ .label = "catch", .keyword = "catch" },
        .kw_class => .{ .label = "class", .keyword = "class", .starts_expr = true },
        .kw_const => .{ .label = "const", .keyword = "const" },
        .kw_continue => .{ .label = "continue", .keyword = "continue" },
        .kw_debugger => .{ .label = "debugger", .keyword = "debugger" },
        .kw_default => .{ .label = "default", .keyword = "default", .before_expr = true },
        .kw_delete => .{ .label = "delete", .keyword = "delete", .before_expr = true, .starts_expr = true, .prefix = true },
        .kw_do => .{ .label = "do", .keyword = "do", .is_loop = true, .before_expr = true },
        .kw_else => .{ .label = "else", .keyword = "else", .before_expr = true },
        .kw_export => .{ .label = "export", .keyword = "export" },
        .kw_extends => .{ .label = "extends", .keyword = "extends", .before_expr = true },
        .kw_false => .{ .label = "false", .keyword = "false", .starts_expr = true },
        .kw_finally => .{ .label = "finally", .keyword = "finally" },
        .kw_for => .{ .label = "for", .keyword = "for", .is_loop = true },
        .kw_function => .{ .label = "function", .keyword = "function", .starts_expr = true },
        .kw_if => .{ .label = "if", .keyword = "if" },
        .kw_import => .{ .label = "import", .keyword = "import", .starts_expr = true },
        .kw_in => .{ .label = "in", .keyword = "in", .before_expr = true, .binop = 7 },
        .kw_instanceof => .{ .label = "instanceof", .keyword = "instanceof", .before_expr = true, .binop = 7 },
        .kw_let => .{ .label = "let", .keyword = "let" },
        .kw_new => .{ .label = "new", .keyword = "new", .before_expr = true, .starts_expr = true },
        .kw_null => .{ .label = "null", .keyword = "null", .starts_expr = true },
        .kw_return => .{ .label = "return", .keyword = "return", .before_expr = true },
        .kw_super => .{ .label = "super", .keyword = "super", .starts_expr = true },
        .kw_switch => .{ .label = "switch", .keyword = "switch" },
        .kw_this => .{ .label = "this", .keyword = "this", .starts_expr = true },
        .kw_throw => .{ .label = "throw", .keyword = "throw", .before_expr = true, .starts_expr = true, .prefix = true },
        .kw_true => .{ .label = "true", .keyword = "true", .starts_expr = true },
        .kw_try => .{ .label = "try", .keyword = "try" },
        .kw_typeof => .{ .label = "typeof", .keyword = "typeof", .before_expr = true, .starts_expr = true, .prefix = true },
        .kw_var => .{ .label = "var", .keyword = "var" },
        .kw_void => .{ .label = "void", .keyword = "void", .before_expr = true, .starts_expr = true, .prefix = true },
        .kw_while => .{ .label = "while", .keyword = "while", .is_loop = true },
        .kw_with => .{ .label = "with", .keyword = "with" },
        .kw_yield => .{ .label = "yield", .keyword = "yield", .before_expr = true, .starts_expr = true },
        .kw_async => .{ .label = "name", .starts_expr = true },
        .kw_await => .{ .label = "await", .keyword = "await", .before_expr = true, .starts_expr = true, .prefix = true },
        .kw_of => .{ .label = "name", .starts_expr = true },
        .kw_static => .{ .label = "name", .starts_expr = true },
        .kw_get => .{ .label = "name", .starts_expr = true },
        .kw_set => .{ .label = "name", .starts_expr = true },
        .kw_from => .{ .label = "name", .starts_expr = true },
        .kw_as => .{ .label = "name", .starts_expr = true },
        // Identifiers
        .identifier => .{ .label = "name", .starts_expr = true },
        // Special
        .eof => .{ .label = "eof" },
        .invalid => .{ .label = "invalid" },
    };
}

pub fn serializeEstree(ast: *const Ast, writer: anytype) !void {
    try @constCast(ast).ensureTypeSideTablesMaterialized();
    @constCast(ast).ensureCommentsAttached();
    var serializer = Serializer(@TypeOf(writer)){
        .ast = ast,
        .writer = writer,
        .estree = true,
    };
    try serializeImpl(&serializer);
}

pub fn serialize(ast: *const Ast, writer: anytype) !void {
    try @constCast(ast).ensureTypeSideTablesMaterialized();
    @constCast(ast).ensureCommentsAttached();
    var serializer = Serializer(@TypeOf(writer)){
        .ast = ast,
        .writer = writer,
    };
    try serializeImpl(&serializer);
}

fn serializeImpl(s: anytype) !void {
    var end = s.ast.source.len;
    while (end > 0) {
        const c = s.ast.source[end - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            end -= 1;
        } else break;
    }
    const file_end: u32 = @intCast(end);
    s.file_end = file_end;
    try s.writer.writeAll("{\"type\":\"File\",");
    try s.writePosition(0, file_end);
    try s.writer.writeAll(",\"errors\":[],\"program\":");
    try s.writeNode(@enumFromInt(0));
    try s.writer.writeAll(",\"comments\":[");
    for (s.ast.comments.items, 0..) |comment, i| {
        if (i > 0) try s.writer.writeAll(",");
        try s.writeCommentValue(comment);
    }
    try s.writer.writeByte(']');
    if (s.ast.emit_tokens) {
        try s.writer.writeAll(",\"tokens\":");
        try s.writeTokenArray();
    }
    try s.writer.writeByte('}');
}

fn Serializer(comptime Writer: type) type {
    return struct {
        ast: *const Ast,
        writer: Writer,
        /// File/Program end position (source length minus trailing whitespace)
        file_end: u32 = 0,
        /// When set, the next written node should include extra.parenthesized
        paren_start: ?u32 = null,
        /// When true, emit ESTree format instead of Babel format
        estree: bool = false,
        /// Tracks whether we are inside an optional chain (for ESTree ChainExpression)
        in_opt_chain: bool = false,

        const Self = @This();

        fn writeNode(self: *Self, idx: NodeIndex) anyerror!void {
            if (idx == .none) {
                try self.writer.writeAll("null");
                return;
            }

            const i = @intFromEnum(idx);
            const tag = self.ast.nodes.items(.tag)[i];
            const data = self.ast.nodes.items(.data)[i];
            const main_token = self.ast.nodes.items(.main_token)[i];

            switch (tag) {
                .program => try self.writeProgram(idx, data),
                .numeric_literal => try self.writeNumericLiteral(idx, main_token),
                .string_literal => try self.writeStringLiteral(idx, main_token),
                .bigint_literal => try self.writeBigIntLiteral(idx, main_token),
                .boolean_literal => try self.writeBooleanLiteral(idx, main_token),
                .null_literal => {
                    if (self.estree) {
                        try self.writer.writeAll("{\"type\":\"Literal\",");
                        try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                        try self.writeParenExtra();
                        try self.writer.writeAll(",\"value\":null,\"raw\":\"null\"}");
                    } else {
                        try self.writer.writeAll("{\"type\":\"NullLiteral\",");
                        try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                        try self.writeParenExtra();
                        try self.writer.writeAll("}");
                    }
                },
                .regex_literal => try self.writeRegExpLiteral(idx, main_token),
                .template_literal => try self.writeTemplateLiteral(idx, main_token, data),
                .identifier => try self.writeIdentifier(idx, main_token),
                .v8_intrinsic_identifier => try self.writeV8IntrinsicIdentifier(idx, main_token),
                .this_expr => {
                    try self.writer.writeAll("{\"type\":\"ThisExpression\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    // Flow: type annotation on `this` parameter in arrow functions
                    if (self.ast.type_annotations.get(@intFromEnum(idx))) |ann| {
                        try self.writer.writeAll(",\"typeAnnotation\":");
                        try self.writeNode(ann);
                    }
                    try self.writeParenExtra();
                    try self.writer.writeAll("}");
                },
                .super_expr => {
                    try self.writer.writeAll("{\"type\":\"Super\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writeParenExtra();
                    try self.writer.writeAll("}");
                },
                .binary_expr => try self.writeBinaryExpr(idx, main_token, data),
                .logical_expr => try self.writeLogicalExpr(idx, main_token, data),
                .unary_expr => try self.writeUnaryExpr(idx, main_token, data),
                .update_expr => try self.writeUpdateExpr(idx, main_token, data),
                .assignment_expr => try self.writeAssignmentExpr(idx, main_token, data),
                .conditional_expr => try self.writeConditionalExpr(idx, data),
                .sequence_expr => try self.writeSequenceExpr(idx, data),
                .call_expr => try self.writeCallExpr(idx, data),
                .new_expr => try self.writeNewExpr(idx, main_token, data),
                .member_expr => try self.writeMemberExpr(idx, data),
                .computed_member_expr => try self.writeComputedMemberExpr(idx, data),
                .optional_chain_expr => try self.writeOptionalChainExpr(idx, data),
                .optional_computed_member_expr => try self.writeOptionalComputedMemberExpr(idx, data),
                .optional_call_expr => try self.writeOptionalCallExpr(idx, data),
                .arrow_function_expr => try self.writeArrowFunctionExpr(idx, data),
                .function_expr => try self.writeFunctionExpr(idx, data),
                .class_expr => try self.writeClassExpr(idx, data),
                .yield_expr => try self.writeYieldExpr(idx, main_token, data, false),
                .yield_delegate_expr => try self.writeYieldExpr(idx, main_token, data, true),
                .await_expr => try self.writeAwaitExpr(idx, data),
                .spread_element => try self.writeSpreadElement(idx, data),
                .tagged_template_expr => try self.writeTaggedTemplateExpr(idx, data),
                .meta_property => try self.writeMetaProperty(idx, main_token),
                .import_expr => try self.writeImportExpr(idx, data),
                .private_name => try self.writePrivateName(data.unary),
                .parenthesized_expr => {
                    if (self.ast.create_parenthesized_expressions) {
                        // Emit ParenthesizedExpression node
                        try self.writer.writeAll("{\"type\":\"ParenthesizedExpression\",");
                        try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                        try self.writer.writeAll(",\"expression\":");
                        try self.writeNode(data.unary);
                        try self.writer.writeAll("}");
                    } else {
                        // Set flag so the inner node emits extra.parenthesized
                        // Only set if not already set — for nested parens like (((x))),
                        // Babel wants the outermost paren position.
                        const paren_pos = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                        const prev_paren = self.paren_start;
                        if (self.paren_start == null) {
                            self.paren_start = paren_pos;
                        }
                        try self.writeNode(data.unary);
                        self.paren_start = prev_paren;
                    }
                },
                .object_expr => try self.writeObjectExpr(idx, data),
                .array_expr => try self.writeArrayExpr(idx, data),
                .property => try self.writeObjectProperty(idx, main_token, data, false, false),
                .shorthand_property => try self.writeShorthandProperty(idx, main_token, data),
                .computed_property => try self.writeComputedProperty(idx, data),
                .computed_method => try self.writeComputedMethod(idx, data),
                .method_definition => try self.writeObjectMethod(idx, main_token, data, "method"),
                .getter => try self.writeObjectMethod(idx, main_token, data, "get"),
                .setter => try self.writeObjectMethod(idx, main_token, data, "set"),
                .array_pattern => try self.writeArrayPattern(idx, data),
                .object_pattern => try self.writeObjectPattern(idx, data),
                .assignment_pattern => try self.writeAssignmentPattern(idx, data),
                .rest_element => try self.writeRestElement(idx, data),
                .expression_statement => try self.writeExpressionStatement(idx, data),
                .var_declaration, .let_declaration, .const_declaration, .using_declaration, .await_using_declaration => try self.writeVariableDeclaration(idx, tag, data),
                .declarator => try self.writeDeclarator(idx, data),
                .function_declaration,
                .async_function_declaration,
                .generator_declaration,
                .async_generator_declaration,
                => try self.writeFunctionDeclaration(idx, tag, data),
                .class_declaration => try self.writeClassDeclaration(idx, data),
                .class_body => try self.writeClassBody(idx, data),
                .class_field, .class_private_field => try self.writeClassProperty(idx, tag, data),
                .class_static_block => try self.writeStaticBlock(idx, data),
                .class_method, .class_private_method => try self.writeClassMethod(idx, tag, main_token, data),
                .block_statement => try self.writeBlockStatement(idx, data),
                .removed => {}, // Removed by transform — skip entirely
                .empty_statement => {
                    try self.writer.writeAll("{\"type\":\"EmptyStatement\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll("}");
                },
                .if_statement => try self.writeIfStatement(idx, data),
                .for_statement => try self.writeForStatement(idx, data),
                .for_in_statement => try self.writeForInStatement(idx, data),
                .for_of_statement, .for_of_await_statement => try self.writeForOfStatement(idx, tag, data),
                .while_statement => try self.writeWhileStatement(idx, data),
                .do_while_statement => try self.writeDoWhileStatement(idx, data),
                .switch_statement => try self.writeSwitchStatement(idx, data),
                .switch_case, .switch_default => try self.writeSwitchCase(idx, tag, data),
                .return_statement => try self.writeReturnStatement(idx, data),
                .throw_statement => try self.writeThrowStatement(idx, data),
                .try_statement => try self.writeTryStatement(idx, data),
                .catch_clause => try self.writeCatchClause(idx, data),
                .break_statement => try self.writeBreakContinue(idx, "BreakStatement", data),
                .continue_statement => try self.writeBreakContinue(idx, "ContinueStatement", data),
                .labeled_statement => try self.writeLabeledStatement(idx, main_token, data),
                .with_statement => try self.writeWithStatement(idx, data),
                .debugger_statement => {
                    try self.writer.writeAll("{\"type\":\"DebuggerStatement\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll("}");
                },
                .import_declaration => try self.writeImportDeclaration(idx, main_token, data, .import_declaration),
                .import_specifier => try self.writeImportSpecifier(idx, main_token, data, .import_specifier),
                .import_default => try self.writeImportDefaultSpecifier(idx, main_token),
                .import_namespace => try self.writeImportNamespaceSpecifier(idx, main_token),
                .import_attribute => try self.writeImportAttribute(idx, data),
                .export_named => try self.writeExportNamedDeclaration(idx, data, .export_named),
                .export_default => try self.writeExportDefault(idx, data),
                .export_all => try self.writeExportAllDeclaration(idx, data, .export_all),
                .module_expression => try self.writeModuleExpression(idx, data),
                .export_specifier => try self.writeExportSpecifier(idx, main_token, data, .export_specifier),
                .export_specifier_type => try self.writeExportSpecifier(idx, main_token, data, .export_specifier_type),
                .export_namespace_specifier => try self.writeExportNamespaceSpecifier(idx, data),
                .directive => try self.writeDirective(idx, data),
                .directive_literal => try self.writeDirectiveLiteral(idx, main_token),

                // === Flow Types ===
                .flow_type_annotation => try self.writeFlowTypeAnnotation(idx, data),
                .flow_generic_type => try self.writeFlowGenericType(idx, data),
                .flow_qualified_type_identifier => try self.writeFlowQualifiedTypeIdentifier(idx, main_token, data),
                .flow_nullable_type => try self.writeFlowNullableType(idx, data),
                .flow_union_type => try self.writeFlowUnionOrIntersectionType(idx, data, "UnionTypeAnnotation"),
                .flow_intersection_type => try self.writeFlowUnionOrIntersectionType(idx, data, "IntersectionTypeAnnotation"),
                .flow_typeof_type => try self.writeFlowTypeofType(idx, data),
                .flow_array_type => try self.writeFlowArrayType(idx, data),
                .flow_tuple_type => try self.writeFlowTupleType(idx, data),
                .flow_number_type => try self.writeFlowSimpleType(idx, "NumberTypeAnnotation"),
                .flow_string_type => try self.writeFlowSimpleType(idx, "StringTypeAnnotation"),
                .flow_boolean_type => try self.writeFlowSimpleType(idx, "BooleanTypeAnnotation"),
                .flow_void_type => try self.writeFlowSimpleType(idx, "VoidTypeAnnotation"),
                .flow_mixed_type => try self.writeFlowSimpleType(idx, "MixedTypeAnnotation"),
                .flow_empty_type => try self.writeFlowSimpleType(idx, "EmptyTypeAnnotation"),
                .flow_any_type => try self.writeFlowSimpleType(idx, "AnyTypeAnnotation"),
                .flow_symbol_type => try self.writeFlowSimpleType(idx, "SymbolTypeAnnotation"),
                .flow_bigint_type => try self.writeFlowSimpleType(idx, "BigIntTypeAnnotation"),
                .flow_null_literal_type => try self.writeFlowSimpleType(idx, "NullLiteralTypeAnnotation"),
                .flow_number_literal_type => try self.writeFlowNumberLiteralType(idx, main_token),
                .flow_string_literal_type => try self.writeFlowStringLiteralType(idx, main_token),
                .flow_boolean_literal_type => try self.writeFlowBooleanLiteralType(idx, main_token),
                .flow_bigint_literal_type => try self.writeFlowBigIntLiteralType(idx, main_token),
                .flow_exists_type => try self.writeFlowSimpleType(idx, "ExistsTypeAnnotation"),
                .flow_object_type, .flow_exact_object_type => try self.writeFlowObjectType(idx, tag, data),
                .flow_object_type_property => try self.writeFlowObjectTypeProperty(idx, main_token, data),
                .flow_object_type_spread_property => try self.writeFlowObjectTypeSpreadProperty(idx, data),
                .flow_object_type_indexer => try self.writeFlowObjectTypeIndexer(idx, data),
                .flow_object_type_call_property => try self.writeFlowObjectTypeCallProperty(idx, data),
                .flow_object_type_internal_slot => try self.writeFlowObjectTypeInternalSlot(idx, data),
                .flow_type_alias => try self.writeFlowTypeAlias(idx, data),
                .flow_declare_type_alias => try self.writeFlowDeclareTypeAlias(idx, data),
                .flow_opaque_type => try self.writeFlowOpaqueType(idx, data),
                .flow_interface_declaration => try self.writeFlowInterfaceDeclaration(idx, data),
                .flow_interface_body => try self.writeFlowSimpleType(idx, "InterfaceBody"),
                .flow_interface_extends => try self.writeFlowInterfaceExtends(idx, data),
                .flow_declare_class => try self.writeFlowDeclareClass(idx, data),
                .flow_declare_function => try self.writeFlowDeclareFunction(idx, data),
                .flow_declare_variable => try self.writeFlowDeclareVariable(idx, data),
                .flow_declare_module => try self.writeFlowDeclareModule(idx, data),
                .flow_declare_module_exports => try self.writeFlowDeclareModuleExports(idx, data),
                .flow_declare_export_declaration => try self.writeFlowDeclareExportDeclaration(idx, data),
                .flow_declare_export_all_declaration => try self.writeFlowDeclareExportAllDeclaration(idx, data),
                .flow_declare_interface => try self.writeFlowDeclareInterface(idx, data),
                .flow_declare_opaque_type => try self.writeFlowDeclareOpaqueType(idx, data),
                .flow_type_parameter => try self.writeFlowTypeParameter(idx, main_token, data),
                .flow_type_parameter_declaration => try self.writeFlowTypeParameterDeclaration(idx, data),
                .flow_type_parameter_instantiation => try self.writeFlowTypeParameterInstantiation(idx, data),
                .flow_type_cast_expression => try self.writeFlowTypeCastExpression(idx, data),
                .flow_function_type_annotation => try self.writeFlowFunctionTypeAnnotation(idx, data),
                .flow_function_type_param => try self.writeFlowFunctionTypeParam(idx, main_token, data),
                .flow_indexed_access_type => try self.writeFlowIndexedAccessType(idx, data),
                .flow_optional_indexed_access_type => try self.writeFlowOptionalIndexedAccessType(idx, data),
                .flow_inferred_predicate => try self.writeFlowSimpleType(idx, "InferredPredicate"),
                .flow_declared_predicate => try self.writeFlowDeclaredPredicate(idx, data),
                .flow_this_type_annotation => try self.writeFlowSimpleType(idx, if (self.ast.language.isTypeScript()) "TSThisType" else "ThisTypeAnnotation"),
                .flow_interface_type_annotation => try self.writeFlowInterfaceTypeAnnotation(idx, data),
                .flow_variance => try self.writeFlowVariance(idx, main_token),
                .flow_parenthesized_type => {
                    // Unwrap parenthesized type transparently (like ts_parenthesized_type)
                    try self.writeNode(data.unary);
                },
                .flow_enum_declaration => try self.writeFlowEnumDeclaration(idx, data),
                .flow_enum_boolean_body => try self.writeFlowEnumBody(idx, data, "EnumBooleanBody"),
                .flow_enum_number_body => try self.writeFlowEnumBody(idx, data, "EnumNumberBody"),
                .flow_enum_string_body => try self.writeFlowEnumBody(idx, data, "EnumStringBody"),
                .flow_enum_symbol_body => try self.writeFlowEnumBody(idx, data, "EnumSymbolBody"),
                .flow_enum_boolean_member => try self.writeFlowEnumMember(idx, main_token, data, "EnumBooleanMember"),
                .flow_enum_number_member => try self.writeFlowEnumMember(idx, main_token, data, "EnumNumberMember"),
                .flow_enum_string_member => try self.writeFlowEnumMember(idx, main_token, data, "EnumStringMember"),
                .flow_enum_default_member => try self.writeFlowEnumDefaultMember(idx, main_token),

                // === JSX ===
                .jsx_element => try self.writeJsxElement(idx, data),
                .jsx_opening_element => try self.writeJsxOpeningElement(idx, data),
                .jsx_closing_element => try self.writeJsxClosingElement(idx, data),
                .jsx_self_closing_element => try self.writeJsxSelfClosingElement(idx, data),
                .jsx_fragment => try self.writeJsxFragment(idx, data),
                .jsx_opening_fragment => {
                    try self.writer.writeAll("{\"type\":\"JSXOpeningFragment\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll("}");
                },
                .jsx_closing_fragment => {
                    try self.writer.writeAll("{\"type\":\"JSXClosingFragment\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll("}");
                },
                .jsx_attribute => try self.writeJsxAttribute(idx, data),
                .jsx_spread_attribute => try self.writeJsxSpreadAttribute(idx, data),
                .jsx_spread_child => try self.writeJsxSpreadChild(idx, data),
                .jsx_expression_container => try self.writeJsxExpressionContainer(idx, data),
                .jsx_empty_expression => {
                    // JSXEmptyExpression position: after { to before }
                    // main_token points to {, so start = end of {
                    const mt = @intFromEnum(main_token);
                    const brace_end = self.ast.tokens.items(.end)[mt];
                    // End position: start of the next token (}) if available, else same as start
                    const rbrace_start = if (mt + 1 < self.ast.tokens.items(.start).len)
                        self.ast.tokens.items(.start)[mt + 1]
                    else
                        brace_end;
                    try self.writer.writeAll("{\"type\":\"JSXEmptyExpression\",");
                    try self.writePosition(brace_end, rbrace_start);
                    try self.writer.writeAll("}");
                },
                .jsx_text => try self.writeJsxText(idx, main_token),
                .jsx_string_literal => try self.writeJsxStringLiteral(idx, main_token),
                .jsx_identifier => try self.writeJsxIdentifier(idx, main_token),
                .jsx_member_expression => try self.writeJsxMemberExpression(idx, data),
                .jsx_namespaced_name => try self.writeJsxNamespacedName(idx, data),

                // === TypeScript nodes ===
                .ts_type_annotation => try self.writeTsTypeAnnotation(idx, data),
                .ts_type_reference => try self.writeTsTypeReference(idx, data),
                .ts_keyword_type => try self.writeTsKeywordType(idx, main_token),
                .ts_array_type => try self.writeTsArrayType(idx, data),
                .ts_tuple_type => try self.writeTsTupleType(idx, data),
                .ts_union_type => try self.writeTsUnionOrIntersectionType(idx, "TSUnionType", data),
                .ts_intersection_type => try self.writeTsUnionOrIntersectionType(idx, "TSIntersectionType", data),
                .ts_function_type => try self.writeTsFunctionType(idx, "TSFunctionType", data),
                .ts_constructor_type => try self.writeTsFunctionType(idx, "TSConstructorType", data),
                .ts_parenthesized_type => try self.writeTsParenthesizedType(idx, data),
                .ts_optional_type => try self.writeTsOptionalType(idx, data),
                .ts_rest_type => try self.writeTsRestType(idx, data),
                .ts_literal_type => try self.writeTsLiteralType(idx, data),
                .ts_type_parameter => try self.writeTsTypeParameter(idx, main_token, data),
                .ts_type_parameter_declaration => try self.writeTsTypeParameterDeclaration(idx, data),
                .ts_type_parameter_instantiation => try self.writeTsTypeParameterInstantiation(idx, data),
                .ts_qualified_name => try self.writeTsQualifiedName(idx, data),
                .ts_conditional_type => try self.writeTsConditionalType(idx, data),
                .ts_infer_type => try self.writeTsInferType(idx, data),
                .ts_mapped_type => try self.writeTsMappedType(idx, data),
                .ts_indexed_access_type => try self.writeTsIndexedAccessType(idx, data),
                .ts_template_literal_type => try self.writeTsTemplateLiteralType(idx, main_token, data),
                .ts_typeof_type => try self.writeTsTypeofType(idx, data),
                .ts_type_operator => try self.writeTsTypeOperator(idx, main_token, data),
                .ts_type_predicate => try self.writeTsTypePredicate(idx, data),
                .ts_import_type => try self.writeTsImportType(idx, data),
                .ts_named_tuple_member => try self.writeTsNamedTupleMember(idx, data),
                .ts_as_expression => try self.writeTsAsExpression(idx, data),
                .ts_satisfies_expression => try self.writeTsSatisfiesExpression(idx, data),
                .ts_non_null_expression => try self.writeTsNonNullExpression(idx, data),
                .ts_type_assertion => try self.writeTsTypeAssertion(idx, data),
                .ts_instantiation_expression => try self.writeTsInstantiationExpression(idx, data),
                .ts_type_cast_expression => try self.writeTsTypeCastExpression(idx, data),
                .ts_type_alias_declaration => try self.writeTsTypeAliasDeclaration(idx, data),
                .ts_interface_declaration => try self.writeTsInterfaceDeclaration(idx, data),
                .ts_interface_body => try self.writeTsInterfaceBody(idx, data),
                .ts_type_literal => try self.writeTsTypeLiteral(idx, data),
                .ts_property_signature => try self.writeTsPropertySignature(idx, main_token, data),
                .ts_method_signature => try self.writeTsMethodSignature(idx, main_token, data),
                .ts_index_signature => try self.writeTsIndexSignature(idx, data),
                .ts_call_signature_declaration => try self.writeTsSignatureDeclaration(idx, data, "TSCallSignatureDeclaration"),
                .ts_construct_signature_declaration => try self.writeTsSignatureDeclaration(idx, data, "TSConstructSignatureDeclaration"),
                .ts_enum_declaration => try self.writeTsEnumDeclaration(idx, data),
                .ts_enum_member => try self.writeTsEnumMember(idx, main_token, data),
                .ts_module_declaration => try self.writeTsModuleDeclaration(idx, main_token, data),
                .ts_module_block => try self.writeTsModuleBlock(idx, data),
                .ts_declare_function => try self.writeTsDeclareFunction(idx, data),
                .ts_declare_variable => try self.writeTsDeclareVariable(idx, main_token, data),
                .ts_declare_method => try self.writeTsDeclareMethod(idx, data),
                .ts_parameter_property => try self.writeTsParameterProperty(idx, data),
                .ts_import_equals_declaration => try self.writeTsImportEqualsDeclaration(idx, data),
                .ts_export_assignment => try self.writeTsExportAssignment(idx, data),
                .ts_namespace_export_declaration => try self.writeTsNamespaceExportDeclaration(idx, data),
                .ts_external_module_reference => try self.writeTsExternalModuleReference(idx, data),
                .import_declaration_typeof => try self.writeImportDeclaration(idx, main_token, data, .import_declaration_typeof),
                .import_declaration_type => try self.writeImportDeclaration(idx, main_token, data, .import_declaration_type),
                .import_specifier_typeof => try self.writeImportSpecifier(idx, main_token, data, .import_specifier_typeof),
                .import_specifier_type => try self.writeImportSpecifier(idx, main_token, data, .import_specifier_type),
                .export_named_type => try self.writeExportNamedDeclaration(idx, data, .export_named_type),

                // === Proposals ===
                .topic_reference => {
                    // Check if this is a partial-application `?` (ArgumentPlaceholder) or a pipeline topic
                    const tr_tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
                    if (tr_tok_tag == .question) {
                        try self.writer.writeAll("{\"type\":\"ArgumentPlaceholder\",");
                    } else {
                        try self.writer.writeAll("{\"type\":\"TopicReference\",");
                    }
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll("}");
                },
                .decorator => {
                    try self.writer.writeAll("{\"type\":\"Decorator\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll(",\"expression\":");
                    try self.writeNode(data.unary);
                    try self.writer.writeAll("}");
                },
                .placeholder => {
                    try self.writer.writeAll("{\"type\":\"Placeholder\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    // name: Identifier node for the name inside %%...%%
                    const name_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                    const name_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
                    const name_text = self.ast.source[name_start..name_end];
                    try self.writer.writeAll(",\"name\":{\"type\":\"Identifier\",");
                    try self.writePositionWithIdentName(name_start, name_end, name_text);
                    try self.writer.writeAll(",\"name\":\"");
                    try self.writer.writeAll(name_text);
                    try self.writer.writeAll("\"}");
                    // expectedNode
                    const ctx = self.ast.placeholder_contexts.get(@intFromEnum(idx)) orelse "Expression";
                    try self.writer.writeAll(",\"expectedNode\":\"");
                    try self.writer.writeAll(ctx);
                    try self.writer.writeByte('"');
                    // TypeScript type annotation on placeholder
                    try self.writeFlowTypeAnnotationForNode(idx);
                    try self.writer.writeByte('}');
                },
                .do_expression => {
                    try self.writer.writeAll("{\"type\":\"DoExpression\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    const is_async_do = self.ast.async_arrow_flags.contains(@intFromEnum(idx));
                    if (is_async_do) {
                        try self.writer.writeAll(",\"async\":true,\"body\":");
                    } else {
                        try self.writer.writeAll(",\"async\":false,\"body\":");
                    }
                    try self.writeNode(data.unary);
                    try self.writer.writeAll("}");
                },
                .throw_expression => {
                    try self.writer.writeAll("{\"type\":\"ThrowExpression\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll(",\"argument\":");
                    try self.writeNode(data.unary);
                    try self.writer.writeAll("}");
                },
                .export_default_specifier => {
                    try self.writer.writeAll("{\"type\":\"ExportDefaultSpecifier\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll(",\"exported\":");
                    try self.writeIdentifier(idx, main_token);
                    try self.writer.writeAll("}");
                },
                .bind_expression => {
                    try self.writer.writeAll("{\"type\":\"BindExpression\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll(",\"object\":");
                    if (data.binary.lhs == .none) {
                        try self.writer.writeAll("null");
                    } else {
                        try self.writeNode(data.binary.lhs);
                    }
                    try self.writer.writeAll(",\"callee\":");
                    try self.writeNode(data.binary.rhs);
                    try self.writer.writeAll("}");
                },
            }
        }

        // === Program ===

        fn writeProgram(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            _ = idx;
            try self.writer.writeAll("{\"type\":\"Program\",");
            // In Babel, Program.start=0 and Program.end excludes trailing whitespace
            try self.writePosition(0, self.file_end);
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            const items = self.ast.extra_data.items[range_start..range_end];
            const tags = self.ast.nodes.items(.tag);
            if (self.ast.source_type == .module) {
                try self.writer.writeAll(",\"sourceType\":\"module\",\"interpreter\":");
            } else {
                try self.writer.writeAll(",\"sourceType\":\"script\",\"interpreter\":");
            }
            if (self.ast.hashbang_end) |hb_end| {
                const value = self.ast.source[2..hb_end];
                try self.writer.writeAll("{\"type\":\"InterpreterDirective\",");
                try self.writePosition(0, hb_end);
                try self.writer.writeAll(",\"value\":\"");
                try self.writeJsonEscaped(value);
                try self.writer.writeAll("\"}");
            } else {
                try self.writer.writeAll("null");
            }
            if (self.estree) {
                // ESTree: directives are in body as ExpressionStatement with directive field
                try self.writer.writeAll(",\"body\":[");
                var first = true;
                for (items) |item| {
                    if (!first) try self.writer.writeAll(",");
                    first = false;
                    if (tags[item] == .directive) {
                        try self.writeDirectiveAsEstreeExprStmt(@enumFromInt(item));
                    } else {
                        try self.writeNode(@enumFromInt(item));
                    }
                }
                try self.writer.writeAll("]");
            } else {
                try self.writer.writeAll(",\"body\":[");
                // Count leading directives to separate them from body
                var directive_count: usize = 0;
                for (items) |item| {
                    if (tags[item] == .directive) {
                        directive_count += 1;
                    } else {
                        break;
                    }
                }
                // Write body (non-directive items)
                var first = true;
                for (items[directive_count..]) |item| {
                    if (!first) try self.writer.writeAll(",");
                    first = false;
                    try self.writeNode(@enumFromInt(item));
                }
                try self.writer.writeAll("],\"directives\":[");
                // Write directives
                first = true;
                for (items[0..directive_count]) |item| {
                    if (!first) try self.writer.writeAll(",");
                    first = false;
                    try self.writeNode(@enumFromInt(item));
                }
                try self.writer.writeAll("]");
            }
            const has_top_level_await = self.hasTopLevelAwait();
            if (has_top_level_await) {
                try self.writer.writeAll(",\"extra\":{\"topLevelAwait\":true}}");
            } else {
                try self.writer.writeAll(",\"extra\":{\"topLevelAwait\":false}}");
            }
        }

        /// Check whether the AST contains any await expression that is NOT
        /// inside a function, method, arrow, class field initializer, or static block.
        fn hasTopLevelAwait(self: *Self) bool {
            const all_tags = self.ast.nodes.items(.tag);
            const all_data = self.ast.nodes.items(.data);
            const all_starts = self.ast.nodes.items(.main_token);
            const all_ends = self.ast.nodes.items(.end_offset);
            const tok_starts = self.ast.tokens.items(.start);

            for (all_tags, 0..) |t, i| {
                if (t != .await_expr and t != .for_of_await_statement and t != .await_using_declaration) continue;

                // Skip `declare await using` — not real top-level await
                if (t == .await_using_declaration) {
                    const main_tok = all_starts[i];
                    if (std.mem.eql(u8, self.ast.tokenSlice(main_tok), "declare")) continue;
                }

                const await_pos = tok_starts[@intFromEnum(all_starts[i])];
                var inside_function = false;

                // Check if this await is enclosed by any function/scope boundary node
                for (all_tags, 0..) |ft, fi| {
                    const is_func = ft == .function_declaration or ft == .async_function_declaration or
                        ft == .generator_declaration or ft == .async_generator_declaration or
                        ft == .function_expr or ft == .arrow_function_expr or
                        ft == .method_definition or ft == .getter or ft == .setter or
                        ft == .computed_method or ft == .class_method or ft == .class_private_method or
                        ft == .class_static_block or ft == .ts_module_declaration;
                    const is_field = ft == .class_field or ft == .class_private_field;
                    if (!is_func and !is_field) continue;

                    if (is_field) {
                        const extra_idx = @intFromEnum(all_data[fi].extra);
                        if (extra_idx + 1 < self.ast.extra_data.items.len) {
                            const value_node: u32 = self.ast.extra_data.items[extra_idx + 1];
                            if (value_node > 0 and value_node < all_tags.len) {
                                const val_start = tok_starts[@intFromEnum(all_starts[value_node])];
                                const val_end = all_ends[value_node];
                                if (await_pos >= val_start and await_pos < val_end) {
                                    inside_function = true;
                                    break;
                                }
                            }
                        }
                    } else {
                        const fn_start = tok_starts[@intFromEnum(all_starts[fi])];
                        const fn_end = all_ends[fi];
                        if (await_pos > fn_start and await_pos < fn_end) {
                            inside_function = true;
                            break;
                        }
                    }
                }

                if (!inside_function) return true;
            }
            return false;
        }

        /// Check whether any await expression exists in a source range that is NOT
        /// inside a function/method/arrow/class-field/static-block within that range.
        fn hasTopLevelAwaitInRange(self: *Self, range_start: u32, range_end: u32) bool {
            const all_tags = self.ast.nodes.items(.tag);
            const all_data = self.ast.nodes.items(.data);
            const all_mains = self.ast.nodes.items(.main_token);
            const all_ends = self.ast.nodes.items(.end_offset);
            const tok_starts = self.ast.tokens.items(.start);

            for (all_tags, 0..) |t, i| {
                if (t != .await_expr and t != .for_of_await_statement and t != .await_using_declaration) continue;
                const await_pos = tok_starts[@intFromEnum(all_mains[i])];
                if (await_pos < range_start or await_pos >= range_end) continue;

                var inside_function = false;
                for (all_tags, 0..) |ft, fi| {
                    const is_func = ft == .function_declaration or ft == .async_function_declaration or
                        ft == .generator_declaration or ft == .async_generator_declaration or
                        ft == .function_expr or ft == .arrow_function_expr or
                        ft == .method_definition or ft == .getter or ft == .setter or
                        ft == .computed_method or ft == .class_method or ft == .class_private_method or
                        ft == .class_static_block or ft == .ts_module_declaration;
                    const is_field = ft == .class_field or ft == .class_private_field;
                    if (!is_func and !is_field) continue;
                    const fn_start = tok_starts[@intFromEnum(all_mains[fi])];
                    if (fn_start < range_start or fn_start >= range_end) continue;
                    if (is_field) {
                        const extra_idx = @intFromEnum(all_data[fi].extra);
                        if (extra_idx + 1 < self.ast.extra_data.items.len) {
                            const value_node: u32 = self.ast.extra_data.items[extra_idx + 1];
                            if (value_node > 0 and value_node < all_tags.len) {
                                const val_start = tok_starts[@intFromEnum(all_mains[value_node])];
                                const val_end = all_ends[value_node];
                                if (await_pos >= val_start and await_pos < val_end) {
                                    inside_function = true;
                                    break;
                                }
                            }
                        }
                    } else {
                        const fn_end = all_ends[fi];
                        if (await_pos > fn_start and await_pos < fn_end) {
                            inside_function = true;
                            break;
                        }
                    }
                }
                if (!inside_function) return true;
            }
            return false;
        }

        // === Literals ===

        fn writeNumericLiteral(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const raw = self.ast.source[start..end];
            try self.writer.writeAll("{\"type\":\"NumericLiteral\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"extra\":{\"rawValue\":");
            try self.writeNumericValue(raw);
            try self.writer.writeAll(",\"raw\":\"");
            try self.writer.writeAll(raw);
            try self.writer.writeAll("\"");
            _ = try self.consumeParenFields(true);
            try self.writer.writeAll("},\"value\":");
            try self.writeNumericValue(raw);
            try self.writer.writeAll("}");
        }

        fn writeNumericValue(self: *Self, raw: []const u8) anyerror!void {
            if (raw.len == 0) {
                try self.writer.writeAll("0");
                return;
            }
            // Strip numeric separators for parsing
            var buf: [64]u8 = undefined;
            var blen: usize = 0;
            for (raw) |c| {
                if (c != '_') {
                    if (blen < buf.len) {
                        buf[blen] = c;
                        blen += 1;
                    }
                }
            }
            const clean = buf[0..blen];
            if (clean.len >= 2 and clean[0] == '0') {
                if (clean[1] == 'x' or clean[1] == 'X') {
                    // hex — incomplete prefix "0x" has no digits → null
                    if (clean.len == 2) {
                        try self.writer.writeAll("null");
                        return;
                    }
                    const val = std.fmt.parseInt(i64, clean[2..], 16) catch 0;
                    try self.writeI64(val);
                    return;
                }
                if (clean[1] == 'b' or clean[1] == 'B') {
                    // binary — incomplete prefix "0b"/"0B" has no digits → null
                    if (clean.len == 2) {
                        try self.writer.writeAll("null");
                        return;
                    }
                    const val = parseRadixBabelCompat(clean[2..], 2);
                    try self.writeI64(val);
                    return;
                }
                if (clean[1] == 'o' or clean[1] == 'O') {
                    // octal — incomplete prefix "0o"/"0O" has no digits → null
                    if (clean.len == 2) {
                        try self.writer.writeAll("null");
                        return;
                    }
                    const val = parseRadixBabelCompat(clean[2..], 8);
                    try self.writeI64(val);
                    return;
                }
                // Legacy octal: 0[0-7]+
                if (clean.len > 1 and clean[1] >= '0' and clean[1] <= '7') {
                    var is_octal = true;
                    for (clean[1..]) |c| {
                        if (c < '0' or c > '7') {
                            if (c == '.' or c == 'e' or c == 'E' or c == '8' or c == '9') {
                                is_octal = false;
                                break;
                            }
                        }
                    }
                    if (is_octal) {
                        const val = std.fmt.parseInt(i64, clean[1..], 8) catch 0;
                        try self.writeI64(val);
                        return;
                    }
                }
            }
            // Decimal (possibly with . or exponent)
            // Try parsing as-is first; if that fails, strip incomplete exponent suffix
            // (e.g. "3e", "3e+", "3e-") and retry, matching Babel's parseFloat behavior
            var parse_str = clean;
            const val = std.fmt.parseFloat(f64, parse_str) catch blk: {
                var strip_len = parse_str.len;
                if (strip_len > 0 and (parse_str[strip_len - 1] == '+' or parse_str[strip_len - 1] == '-')) {
                    strip_len -= 1;
                }
                if (strip_len > 0 and (parse_str[strip_len - 1] == 'e' or parse_str[strip_len - 1] == 'E')) {
                    strip_len -= 1;
                }
                if (strip_len < parse_str.len and strip_len > 0) {
                    parse_str = parse_str[0..strip_len];
                    break :blk std.fmt.parseFloat(f64, parse_str) catch 0;
                }
                break :blk @as(f64, 0);
            };
            // Check if it's an integer
            if (val == @floor(val) and val >= -9007199254740992 and val <= 9007199254740992 and
                !hasDecimalPoint(parse_str) and !hasExponent(parse_str))
            {
                try self.writeI64(@intFromFloat(val));
            } else {
                try self.writeF64(val);
            }
        }

        fn hasDecimalPoint(s: []const u8) bool {
            for (s) |c| {
                if (c == '.') return true;
            }
            return false;
        }

        fn hasExponent(s: []const u8) bool {
            for (s) |c| {
                if (c == 'e' or c == 'E') return true;
            }
            return false;
        }

        fn writeStringLiteral(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const raw = self.ast.source[start..end];
            // value is string content without quotes
            const value = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            try self.writer.writeAll("{\"type\":\"StringLiteral\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"extra\":{\"rawValue\":");
            try self.writeJsResolvedJsonString(value);
            try self.writer.writeAll(",\"raw\":\"");
            try self.writeJsonEscaped(raw);
            try self.writer.writeAll("\"");
            _ = try self.consumeParenFields(true);
            try self.writer.writeAll("},\"value\":");
            try self.writeJsResolvedJsonString(value);
            try self.writer.writeAll("}");
        }

        /// Convert a BigInt literal value (without trailing 'n') to its decimal string.
        /// Handles 0x, 0o, 0b prefixes. Legacy octal (0-prefixed digits like 016432n)
        /// and non-octal decimal (089n) are treated as decimal with leading zeros stripped,
        /// matching Babel's behavior for invalid BigInt literals.
        fn bigintToDecimal(value: []const u8, buf: *[32]u8) []const u8 {
            if (value.len < 2) return value;
            if (value[0] != '0') return value;
            return switch (value[1]) {
                'x', 'X' => parseBigintBase(value[2..], 16, buf) orelse value,
                'o', 'O' => parseBigintBase(value[2..], 8, buf) orelse value,
                'b', 'B' => parseBigintBase(value[2..], 2, buf) orelse value,
                '0'...'9' => parseBigintBase(value[1..], 10, buf) orelse value,
                else => value,
            };
        }

        fn parseBigintBase(digits: []const u8, base: u8, buf: *[32]u8) ?[]const u8 {
            var n: u128 = 0;
            for (digits) |c| {
                if (c == '_') continue;
                const d: u128 = switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'f' => c - 'a' + 10,
                    'A'...'F' => c - 'A' + 10,
                    else => return null,
                };
                n = n * base + d;
            }
            return std.fmt.bufPrint(buf, "{d}", .{n}) catch null;
        }

        fn writeBigIntLiteral(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const raw = self.ast.source[start..end];
            // Remove trailing 'n'
            const value_raw = if (raw.len > 0 and raw[raw.len - 1] == 'n') raw[0 .. raw.len - 1] else raw;
            // Check if this is an invalid BigInt (decimal with '.' or exponent 'e'/'E')
            // Skip check for hex literals where e/E are valid digits
            const is_hex = value_raw.len >= 2 and value_raw[0] == '0' and (value_raw[1] == 'x' or value_raw[1] == 'X');
            const is_invalid = if (is_hex) false else blk: {
                for (value_raw) |c| {
                    if (c == '.' or c == 'e' or c == 'E') break :blk true;
                }
                break :blk false;
            };
            // Convert non-decimal bases to decimal
            var dec_buf: [32]u8 = undefined;
            const value = if (is_invalid) value_raw else bigintToDecimal(value_raw, &dec_buf);
            if (self.estree) {
                try self.writer.writeAll("{\"type\":\"Literal\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writeParenExtra();
                try self.writer.writeAll(",\"value\":\"");
                try self.writer.writeAll(if (is_invalid) "" else value);
                try self.writer.writeAll("\",\"raw\":\"");
                try self.writer.writeAll(raw);
                try self.writer.writeAll("\",\"bigint\":\"");
                try self.writer.writeAll(if (is_invalid) "" else value);
                try self.writer.writeAll("\"}");
            } else {
                try self.writer.writeAll("{\"type\":\"BigIntLiteral\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                if (is_invalid) {
                    try self.writer.writeAll(",\"extra\":{\"rawValue\":null,\"raw\":\"");
                    try self.writer.writeAll(raw);
                    try self.writer.writeAll("\"},\"value\":null}");
                } else {
                    try self.writer.writeAll(",\"extra\":{\"rawValue\":\"");
                    try self.writer.writeAll(value);
                    try self.writer.writeAll("\",\"raw\":\"");
                    try self.writer.writeAll(raw);
                    try self.writer.writeAll("\"},\"value\":\"");
                    try self.writer.writeAll(value);
                    try self.writer.writeAll("\"}");
                }
            }
        }

        fn writeBooleanLiteral(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
            const value = if (tag == .kw_true) "true" else if (tag == .kw_false) "false" else blk: {
                const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                const end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
                const raw = self.ast.source[start..end];
                var buf: [32]u8 = undefined;
                const resolved = @import("lexer.zig").Lexer.resolveEscapes(raw, &buf);
                break :blk if (std.mem.eql(u8, resolved, "true")) "true" else "false";
            };
            try self.writer.writeAll("{\"type\":\"BooleanLiteral\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"value\":");
            try self.writer.writeAll(value);
            try self.writer.writeAll("}");
        }

        fn writeRegExpLiteral(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end = self.nodeEnd(idx); // Use node end which was set to regex end
            const raw = self.ast.source[start..end];
            // Find closing / (respecting character classes and escape sequences)
            var pattern_end: usize = 1;
            var in_class = false;
            while (pattern_end < raw.len) {
                if (raw[pattern_end] == '\\' and pattern_end + 1 < raw.len) {
                    pattern_end += 2;
                    continue;
                }
                if (raw[pattern_end] == '[') {
                    in_class = true;
                    pattern_end += 1;
                    continue;
                }
                if (raw[pattern_end] == ']') {
                    in_class = false;
                    pattern_end += 1;
                    continue;
                }
                if (raw[pattern_end] == '/' and !in_class) break;
                pattern_end += 1;
            }
            const pattern = raw[1..pattern_end];
            const flags = if (pattern_end + 1 < raw.len) raw[pattern_end + 1 ..] else "";
            if (self.estree) {
                try self.writer.writeAll("{\"type\":\"Literal\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writeParenExtra();
                try self.writer.writeAll(",\"value\":null,\"raw\":\"");
                try self.writeJsonEscaped(raw);
                try self.writer.writeAll("\",\"regex\":{\"pattern\":\"");
                try self.writeJsonEscaped(pattern);
                try self.writer.writeAll("\",\"flags\":\"");
                try self.writeJsonEscaped(flags);
                try self.writer.writeAll("\"}}");
            } else {
                try self.writer.writeAll("{\"type\":\"RegExpLiteral\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writer.writeAll(",\"extra\":{\"raw\":\"");
                try self.writeJsonEscaped(raw);
                try self.writer.writeAll("\"");
                _ = try self.consumeParenFields(true);
                try self.writer.writeAll("},\"pattern\":\"");
                try self.writeJsonEscaped(pattern);
                try self.writer.writeAll("\",\"flags\":\"");
                try self.writeJsonEscaped(flags);
                try self.writer.writeAll("\"}");
            }
        }

        fn writeTemplateLiteral(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            _ = main_token;
            try self.writer.writeAll("{\"type\":\"TemplateLiteral\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"expressions\":[");
            // For template_no_sub, no expressions/quasis detail needed beyond empty arrays
            // For complex templates with data.extra, serialize expressions
            const tag_at = self.ast.nodes.items(.tag)[@intFromEnum(idx)];
            _ = tag_at;
            const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            const mt_tag = self.ast.tokens.items(.tag)[@intFromEnum(mt)];
            if (mt_tag == .template_no_sub) {
                // No substitutions - just one quasi
                try self.writer.writeAll("],\"quasis\":[");
                try self.writeTemplateElement(mt, true);
                try self.writer.writeAll("]}");
            } else {
                // Has substitutions - data.extra layout:
                // [num_expressions, expr1, expr2, ..., head_tok, mid_tok1, ..., tail_tok]
                const extra_idx = @intFromEnum(data.extra);
                const num_expressions = self.ast.extra_data.items[extra_idx];
                const exprs_start = extra_idx + 1;
                const tokens_start = exprs_start + num_expressions;
                const num_tokens = num_expressions + 1; // head + middles + tail

                // Write expressions
                for (0..num_expressions) |j| {
                    if (j > 0) try self.writer.writeAll(",");
                    const expr_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[exprs_start + j]);
                    try self.writeNode(expr_node);
                }
                try self.writer.writeAll("],\"quasis\":[");

                // Write quasis from template tokens
                for (0..num_tokens) |j| {
                    if (j > 0) try self.writer.writeAll(",");
                    const tok: TokenIndex = @enumFromInt(self.ast.extra_data.items[tokens_start + j]);
                    const is_tail = (j == num_tokens - 1);
                    try self.writeTemplateElement(tok, is_tail);
                }
                try self.writer.writeAll("]}");
            }
        }

        fn writeTemplateElement(self: *Self, token: TokenIndex, tail: bool) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(token)];
            // Babel TemplateElement positions exclude delimiters:
            // start+1 skips opening ` or }, end-1 skips closing `, end-2 skips ${
            const elem_start = start + 1;
            const elem_end = if (tail) end -| 1 else end -| 2;
            try self.writer.writeAll("{\"type\":\"TemplateElement\",");
            try self.writePosition(elem_start, elem_end);
            try self.writer.writeAll(",\"value\":{\"raw\":\"");
            // Raw value is content between ` and ` (or ${ )
            const raw = self.ast.source[start..end];
            // Strip delimiters
            const content_start: usize = 1; // skip ` or }
            var content_end: usize = raw.len;
            if (content_end > 0) {
                const last = raw[content_end - 1];
                if (last == '`') {
                    content_end -= 1;
                } else if (content_end >= 2 and raw[content_end - 2] == '$' and raw[content_end - 1] == '{') {
                    content_end -= 2;
                }
            }
            if (content_start <= content_end) {
                try self.writeTemplateRawEscaped(raw[content_start..content_end]);
            }
            try self.writer.writeAll("\",\"cooked\":");
            if (content_start <= content_end) {
                const content = raw[content_start..content_end];
                // Template literals with invalid escapes have cooked=null
                if (hasInvalidTemplateEscape(content)) {
                    try self.writer.writeAll("null");
                } else {
                    try self.writeTemplateCookedString(content);
                }
            } else {
                try self.writer.writeAll("\"\"");
            }
            try self.writer.writeAll("},\"tail\":");
            try self.writer.writeAll(if (tail) "true" else "false");
            try self.writer.writeAll("}");
        }

        // === Identifiers ===

        fn writeIdentifier(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            // VoidPattern: `void` as binding pattern with discard-binding plugin
            if (self.ast.async_arrow_flags.contains(@intFromEnum(idx))) {
                const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
                if (tok_tag == .kw_void) {
                    try self.writer.writeAll("{\"type\":\"VoidPattern\",");
                    try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                    try self.writer.writeAll("}");
                    return;
                }
            }
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const name = self.ast.source[start..end];
            try self.writer.writeAll("{\"type\":\"Identifier\",");
            try self.writePositionWithIdentName(self.nodeStart(idx), self.nodeEnd(idx), name);
            try self.writeParenExtra();

            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"");
            try self.writeTsOptionalFlag(idx);
            // Flow/TS: type annotation
            try self.writeFlowTypeAnnotationForNode(idx);
            // Babel emits an empty decorators array on all Identifier nodes
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        fn writeV8IntrinsicIdentifier(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            _ = main_token;
            const node_start = self.nodeStart(idx);
            const node_end = self.nodeEnd(idx);
            // Source slice includes leading '%', while name excludes it.
            const raw = self.ast.source[node_start..node_end];
            const name = if (raw.len > 0 and raw[0] == '%') raw[1..] else raw;
            try self.writer.writeAll("{\"type\":\"V8IntrinsicIdentifier\",");
            try self.writePositionWithIdentName(node_start, node_end, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"}");
        }

        // === Expressions ===

        fn writeBinaryExpr(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"BinaryExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"left\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"operator\":\"");
            // Check for operator override (from split token like %===)
            if (self.ast.operator_overrides.get(@intFromEnum(idx))) |op_str| {
                try self.writer.writeAll(op_str);
            } else {
                try self.writeOperator(main_token);
            }
            try self.writer.writeAll("\",\"right\":");
            try self.writeNode(data.binary.rhs);

            try self.writer.writeAll("}");
        }

        fn writeLogicalExpr(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"LogicalExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"left\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"operator\":\"");
            try self.writeOperator(main_token);
            try self.writer.writeAll("\",\"right\":");
            try self.writeNode(data.binary.rhs);

            try self.writer.writeAll("}");
        }

        fn writeUnaryExpr(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"UnaryExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"operator\":\"");
            try self.writeOperator(main_token);
            try self.writer.writeAll("\",\"prefix\":true,\"argument\":");
            try self.writeNode(data.unary);

            try self.writer.writeAll("}");
        }

        fn writeUpdateExpr(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            // Determine prefix: if main_token is before the argument, it's prefix
            const op_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const arg_start = self.nodeStart(data.unary);
            const is_prefix = op_start < arg_start;
            try self.writer.writeAll("{\"type\":\"UpdateExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"operator\":\"");
            try self.writeOperator(main_token);
            try self.writer.writeAll("\",\"prefix\":");
            try self.writer.writeAll(if (is_prefix) "true" else "false");
            try self.writer.writeAll(",\"argument\":");
            try self.writeNode(data.unary);

            try self.writer.writeAll("}");
        }

        fn writeAssignmentExpr(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"AssignmentExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"operator\":\"");
            try self.writeOperator(main_token);
            try self.writer.writeAll("\",\"left\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"right\":");
            try self.writeNode(data.binary.rhs);

            try self.writer.writeAll("}");
        }

        fn writeConditionalExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_start = @intFromEnum(data.binary.rhs);
            const consequent: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_start]);
            const alternate: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_start + 1]);
            try self.writer.writeAll("{\"type\":\"ConditionalExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"test\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"consequent\":");
            try self.writeNode(consequent);
            try self.writer.writeAll(",\"alternate\":");
            try self.writeNode(alternate);

            try self.writer.writeAll("}");
        }

        fn writeSequenceExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"SequenceExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"expressions\":[");
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx < self.ast.extra_data.items.len) {
                const range_start = self.ast.extra_data.items[extra_idx];
                const range_end = self.ast.extra_data.items[extra_idx + 1];
                if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                    const items = self.ast.extra_data.items[range_start..range_end];
                    for (items, 0..) |item, j| {
                        if (j > 0) try self.writer.writeAll(",");
                        try self.writeNode(@enumFromInt(item));
                    }
                }
            }
            try self.writer.writeAll("]");

            try self.writer.writeAll("}");
        }

        fn writeCallExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const args_start = self.ast.extra_data.items[extra_idx + 1];
            const args_end = self.ast.extra_data.items[extra_idx + 2];
            const call_end = self.nodeEnd(idx);
            try self.writer.writeAll("{\"type\":\"CallExpression\",");
            try self.writePosition(self.nodeStart(idx), call_end);
            try self.writeExtraObject(self.findTrailingComma(call_end));
            try self.writer.writeAll(",\"callee\":");
            try self.writeNode(callee);
            try self.writer.writeAll(",\"arguments\":[");
            const args = self.ast.extra_data.items[args_start..args_end];
            for (args, 0..) |arg, j| {
                if (j > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(arg));
            }
            try self.writer.writeAll("],\"optional\":false");
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeArguments\":");
                try self.writeNode(tp);
            } else if (self.ast.language != .javascript) {
                try self.writer.writeAll(",\"typeArguments\":null");
            }

            try self.writer.writeAll("}");
        }

        fn writeNewExpr(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            _ = main_token;
            try self.writer.writeAll("{\"type\":\"NewExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            // Always uses extra format: callee, args_start, args_end
            const extra_idx = @intFromEnum(data.extra);
            const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const args_start = self.ast.extra_data.items[extra_idx + 1];
            const args_end = self.ast.extra_data.items[extra_idx + 2];
            try self.writer.writeAll(",\"callee\":");
            try self.writeNode(callee);
            try self.writer.writeAll(",\"arguments\":[");
            if (args_start <= args_end and args_end <= self.ast.extra_data.items.len) {
                const args = self.ast.extra_data.items[args_start..args_end];
                for (args, 0..) |arg, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(arg));
                }
            }
            try self.writer.writeAll("]");
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeArguments\":");
                try self.writeNode(tp);
            } else if (self.ast.language != .javascript) {
                try self.writer.writeAll(",\"typeArguments\":null");
            }

            try self.writer.writeAll("}");
        }

        fn writeMemberExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"MemberExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"object\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"computed\":false,\"property\":");
            try self.writeInlinePropertyFromToken(data.binary.rhs);
            try self.writer.writeAll(",\"optional\":false");

            try self.writer.writeAll("}");
        }

        fn writeComputedMemberExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"MemberExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"object\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"computed\":true,\"property\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll(",\"optional\":false");

            try self.writer.writeAll("}");
        }

        /// Begin ESTree ChainExpression wrapper if this is the outermost optional chain node.
        /// Returns true if a wrapper was opened (caller must close it with endChainWrap).
        fn beginChainWrap(self: *Self, idx: NodeIndex) anyerror!bool {
            if (!self.estree or self.in_opt_chain) return false;
            try self.writer.writeAll("{\"type\":\"ChainExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"expression\":");
            self.in_opt_chain = true;
            return true;
        }

        fn endChainWrap(self: *Self, need_wrap: bool) anyerror!void {
            if (need_wrap) {
                try self.writer.writeAll("}");
                self.in_opt_chain = false;
            }
        }

        fn writeOptionalChainExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const need_chain_wrap = try self.beginChainWrap(idx);

            if (self.estree) {
                try self.writer.writeAll("{\"type\":\"MemberExpression\",");
            } else {
                try self.writer.writeAll("{\"type\":\"OptionalMemberExpression\",");
            }
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (!need_chain_wrap) try self.writeParenExtra();
            try self.writer.writeAll(",\"object\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"computed\":false,\"property\":");
            try self.writeInlinePropertyFromToken(data.binary.rhs);
            try self.writer.writeAll(if (self.isDirectOptional(idx)) ",\"optional\":true}" else ",\"optional\":false}");

            try self.endChainWrap(need_chain_wrap);
        }

        fn writeOptionalComputedMemberExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const need_chain_wrap = try self.beginChainWrap(idx);

            if (self.estree) {
                try self.writer.writeAll("{\"type\":\"MemberExpression\",");
            } else {
                try self.writer.writeAll("{\"type\":\"OptionalMemberExpression\",");
            }
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (!need_chain_wrap) try self.writeParenExtra();
            try self.writer.writeAll(",\"object\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"computed\":true,\"property\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll(if (self.isDirectOptional(idx)) ",\"optional\":true}" else ",\"optional\":false}");

            try self.endChainWrap(need_chain_wrap);
        }

        fn writeOptionalCallExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const need_chain_wrap = try self.beginChainWrap(idx);

            if (self.estree) {
                try self.writer.writeAll("{\"type\":\"CallExpression\",");
            } else {
                try self.writer.writeAll("{\"type\":\"OptionalCallExpression\",");
            }
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (!need_chain_wrap) try self.writeParenExtra();
            const extra_idx = @intFromEnum(data.extra);
            const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const args_start = self.ast.extra_data.items[extra_idx + 1];
            const args_end = self.ast.extra_data.items[extra_idx + 2];
            try self.writer.writeAll(",\"callee\":");
            try self.writeNode(callee);
            try self.writer.writeAll(",\"arguments\":[");
            if (args_start <= args_end and args_end <= self.ast.extra_data.items.len) {
                const args = self.ast.extra_data.items[args_start..args_end];
                for (args, 0..) |arg, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(arg));
                }
            }
            try self.writer.writeAll("]");
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeArguments\":");
                try self.writeNode(tp);
            } else if (self.ast.language != .javascript) {
                try self.writer.writeAll(",\"typeArguments\":null");
            }
            try self.writer.writeAll(if (self.isDirectOptional(idx)) ",\"optional\":true}" else ",\"optional\":false}");

            try self.endChainWrap(need_chain_wrap);
        }

        fn writeArrowFunctionExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ArrowFunctionExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            // Check if main_token is 'async' keyword or async_arrow_flags side table
            const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            const mt_tag = self.ast.tokens.items(.tag)[@intFromEnum(mt)];
            const is_async = (mt_tag == .kw_async) or self.ast.async_arrow_flags.contains(@intFromEnum(idx));
            try self.writer.writeAll(",\"id\":null,\"generator\":false,\"async\":");
            try self.writer.writeAll(if (is_async) "true" else "false");
            try self.writer.writeAll(",\"params\":[");
            // Parse extra data - format varies based on how arrow was parsed
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx < self.ast.extra_data.items.len) {
                const first = self.ast.extra_data.items[extra_idx];
                const second = self.ast.extra_data.items[extra_idx + 1];
                // Check if this is the new format (range_start, range_end, body)
                // or old format (param, body, count)
                if (extra_idx + 2 < self.ast.extra_data.items.len) {
                    const third = self.ast.extra_data.items[extra_idx + 2];
                    // Old format: single-param arrow has (param_node, body_node, param_count)
                    // New format: multi-param has (range_start, range_end, body_node)
                    // Old format: param_count is 0 or 1. If 0, first==none (0xFFFFFFFF).
                    // If 1, first is a valid node. Check reliably to avoid
                    // false match when range_end happens to be 0 or 1.
                    if (first == @intFromEnum(NodeIndex.none) or third == 1) {
                        // Old format: param, body, count
                        const param: NodeIndex = @enumFromInt(first);
                        const body: NodeIndex = @enumFromInt(second);
                        if (param != .none) {
                            try self.writeNode(param);
                        }
                        try self.writer.writeAll("],\"body\":");
                        try self.writeNode(body);
                        // Check if body is expression (not block)
                        const body_tag = self.ast.nodes.items(.tag)[@intFromEnum(body)];
                        try self.writer.writeAll(",\"expression\":");
                        try self.writer.writeAll(if (body_tag != .block_statement) "true" else "false");
                    } else {
                        // New format: range_start, range_end, body
                        const range_start = first;
                        const range_end = second;
                        const body: NodeIndex = @enumFromInt(third);
                        if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                            const params = self.ast.extra_data.items[range_start..range_end];
                            for (params, 0..) |p, j| {
                                if (j > 0) try self.writer.writeAll(",");
                                try self.writeNode(@enumFromInt(p));
                            }
                        }
                        try self.writer.writeAll("],\"body\":");
                        try self.writeNode(body);
                        const body_tag = self.ast.nodes.items(.tag)[@intFromEnum(body)];
                        try self.writer.writeAll(",\"expression\":");
                        try self.writer.writeAll(if (body_tag != .block_statement) "true" else "false");
                    }
                }
            } else {
                try self.writer.writeAll("],\"body\":null,\"expression\":false");
            }
            try self.writeFlowPredicateForNode(idx);
            try self.writeReturnTypeAndTypeParams(idx);
            try self.writer.writeAll("}");
        }

        fn writeFunctionExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"FunctionExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const params_start = self.ast.extra_data.items[extra_idx + 1];
            const params_end = self.ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
            // id
            try self.writer.writeAll(",\"id\":");
            // Placeholder as function name
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_name| {
                try self.writeNode(ph_name);
            } else if (name_token_raw != 0) {
                const name_start = self.ast.tokens.items(.start)[name_token_raw];
                const name_end = self.ast.tokens.items(.end)[name_token_raw];
                const name = self.ast.source[name_start..name_end];
                try self.writer.writeAll("{\"type\":\"Identifier\",");
                try self.writePositionWithIdentName(name_start, name_end, name);
                try self.writer.writeAll(",\"name\":\"");
                try self.writeIdentName(name);
                try self.writer.writeAll("\"}");
            } else {
                try self.writer.writeAll("null");
            }
            // flags: bit 0=generator, bit 1=async
            const func_flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 4]
            else
                0;
            try self.writer.writeAll(",\"generator\":");
            try self.writer.writeAll(if ((func_flags & 1) != 0) "true" else "false");
            try self.writer.writeAll(",\"async\":");
            try self.writer.writeAll(if ((func_flags & 2) != 0) "true" else "false");
            try self.writer.writeAll(",\"params\":[");
            if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                const params = self.ast.extra_data.items[params_start..params_end];
                for (params, 0..) |p, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(p));
                }
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            try self.writeReturnTypeAndTypeParams(idx);
            try self.writeFlowPredicateForNode(idx);
            try self.writer.writeAll(",\"expression\":false");

            try self.writer.writeAll("}");
        }

        fn writeClassExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ClassExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll(",\"id\":");
            // Placeholder as class name
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_name| {
                try self.writeNode(ph_name);
            } else {
                try self.writeOptionalTokenAsIdent(name_token_raw);
            }
            // Type parameters
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(tp);
            }
            try self.writer.writeAll(",\"superClass\":");
            try self.writeNode(super_class);
            try self.writeClassTypeExtras(idx);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(body);
            try self.writeDecorators(idx);

            try self.writer.writeAll("}");
        }

        fn writeYieldExpr(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data, delegate: bool) anyerror!void {
            _ = main_token;
            try self.writer.writeAll("{\"type\":\"YieldExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"delegate\":");
            try self.writer.writeAll(if (delegate) "true" else "false");
            try self.writer.writeAll(",\"argument\":");
            try self.writeChildIsolated(data.unary);
            try self.writeParenExtra();
            try self.writer.writeAll("}");
        }

        fn writeAwaitExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"AwaitExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"argument\":");
            try self.writeChildIsolated(data.unary);
            try self.writeParenExtra();
            try self.writer.writeAll("}");
        }

        fn writeSpreadElement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"SpreadElement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"argument\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTaggedTemplateExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const tag_expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const quasi: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            try self.writer.writeAll("{\"type\":\"TaggedTemplateExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"tag\":");
            try self.writeNode(tag_expr);
            try self.writer.writeAll(",\"quasi\":");
            try self.writeNode(quasi);
            // Emit typeArguments if present (from type_parameters side table)
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeArguments\":");
                try self.writeNode(tp);
            }
            try self.writer.writeAll("}");
        }

        fn writeMetaProperty(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const mt_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
            const meta_name = if (mt_tag == .kw_new) "new" else if (mt_tag == .kw_import) "import" else if (mt_tag == .kw_function) "function" else blk: {
                const raw = self.ast.source[self.ast.tokens.items(.start)[@intFromEnum(main_token)]..self.ast.tokens.items(.end)[@intFromEnum(main_token)]];
                var buf: [32]u8 = undefined;
                const resolved = @import("lexer.zig").Lexer.resolveEscapes(raw, &buf);
                break :blk if (std.mem.eql(u8, resolved, "new")) "new" else if (std.mem.eql(u8, resolved, "function")) "function" else "import";
            };
            try self.writer.writeAll("{\"type\":\"MetaProperty\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"meta\":{\"type\":\"Identifier\",");
            const mt_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const mt_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            try self.writePositionWithIdentName(mt_start, mt_end, meta_name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writer.writeAll(meta_name);
            try self.writer.writeAll("\"},\"property\":");
            // Property node is stored in .unary
            const data = self.ast.nodes.items(.data)[@intFromEnum(idx)];
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeImportExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            // Always uses binary format: lhs = source, rhs = options (.none if absent)
            const has_options = data.binary.rhs != .none;
            const has_source = data.binary.lhs != .none;
            const source_node = data.binary.lhs;

            // Lone import (no parentheses) — serialize as Import node
            if (!has_source and !has_options and self.ast.async_arrow_flags.contains(@intFromEnum(idx))) {
                try self.writer.writeAll("{\"type\":\"Import\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writer.writeAll("}");
                return;
            }

            // Phase imports always use ImportExpression format even when createImportExpressions is false
            const ie_has_phase = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) != null;
            if (!self.ast.create_import_expressions and !self.estree and !ie_has_phase) {
                // Serialize as CallExpression with Import callee
                try self.writer.writeAll("{\"type\":\"CallExpression\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writeParenExtra();
                // callee: Import node
                const main_token = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                const import_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                const import_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
                try self.writer.writeAll(",\"callee\":{\"type\":\"Import\",");
                try self.writePosition(import_start, import_end);
                try self.writer.writeAll("},\"arguments\":[");
                if (has_source) {
                    try self.writeNode(source_node);
                    if (has_options) {
                        try self.writer.writeAll(",");
                        try self.writeNode(data.binary.rhs);
                    }
                    // Extra arguments (3+ args) stored in implements_list
                    if (self.ast.implements_list.get(@intFromEnum(idx))) |extra_range| {
                        const extras = self.ast.extraRange(extra_range.start, extra_range.end);
                        for (extras) |extra_idx| {
                            try self.writer.writeByte(',');
                            try self.writeNode(@enumFromInt(extra_idx));
                        }
                    }
                }
                try self.writer.writeAll("]}");
            } else {
                try self.writer.writeAll("{\"type\":\"ImportExpression\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                // Import phase (source/defer)
                const ie_phase = self.ast.ts_class_modifiers.get(@intFromEnum(idx));
                if (ie_phase) |pv| {
                    if (pv == 0x100) {
                        try self.writer.writeAll(",\"phase\":\"source\"");
                    } else if (pv == 0x200) {
                        try self.writer.writeAll(",\"phase\":\"defer\"");
                    }
                } else {
                    try self.writer.writeAll(",\"phase\":null");
                }
                try self.writer.writeAll(",\"source\":");
                try self.writeNode(source_node);
                if (has_options) {
                    try self.writer.writeAll(",\"options\":");
                    try self.writeNode(data.binary.rhs);
                } else {
                    try self.writer.writeAll(",\"options\":null");
                }
                try self.writer.writeAll("}");
            }
        }

        // === Object / Array ===

        fn writeObjectExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ObjectExpression\",");
            const obj_end = self.nodeEnd(idx);
            try self.writePosition(self.nodeStart(idx), obj_end);
            try self.writeExtraObject(self.findTrailingComma(obj_end));
            try self.writer.writeAll(",\"properties\":[");
            try self.writeExtraRange(data);
            try self.writer.writeAll("]}");
        }

        fn writeArrayExpr(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ArrayExpression\",");
            const arr_end = self.nodeEnd(idx);
            try self.writePosition(self.nodeStart(idx), arr_end);
            try self.writeExtraObject(self.findTrailingComma(arr_end));
            try self.writer.writeAll(",\"elements\":[");
            try self.writeExtraRange(data);
            try self.writer.writeAll("]}");
        }

        fn writeObjectProperty(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data, computed: bool, method: bool) anyerror!void {
            _ = computed;
            _ = method;
            try self.writer.writeAll("{\"type\":\"ObjectProperty\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"method\":false,\"key\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"computed\":false,\"shorthand\":false,\"value\":");
            try self.writeNode(data.binary.rhs);
            _ = main_token;
            if (self.estree) {
                try self.writer.writeAll(",\"optional\":false");
            }
            // Write decorators if present (decorators-legacy or decorators plugin)
            if (self.ast.decorators_map.contains(@intFromEnum(idx))) {
                try self.writeDecorators(idx);
            }
            try self.writer.writeAll("}");
        }

        fn writeShorthandProperty(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            _ = main_token;
            try self.writer.writeAll("{\"type\":\"ObjectProperty\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"method\":false,\"key\":");
            // For shorthand with default ({ x = 1 }), value is AssignmentPattern;
            // the key is the LHS of the assignment pattern (the identifier).
            const value_tag = self.ast.nodes.items(.tag)[@intFromEnum(data.unary)];
            if (value_tag == .assignment_pattern) {
                const ap_data = self.ast.nodes.items(.data)[@intFromEnum(data.unary)];
                try self.writeNode(ap_data.binary.lhs);
            } else {
                try self.writeNode(data.unary);
            }
            try self.writer.writeAll(",\"computed\":false,\"shorthand\":true,\"value\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeComputedProperty(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ObjectProperty\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"method\":false,\"key\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"computed\":true,\"shorthand\":false,\"value\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeComputedMethod(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const params_start = self.ast.extra_data.items[extra_idx + 1];
            const params_end = self.ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
            // Optional flags at extra_idx + 4: bit 0 = generator, bit 1 = async
            const cm_flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 4]
            else
                0;
            const is_generator = (cm_flags & 1) != 0;
            const is_async = (cm_flags & 2) != 0;
            if (self.estree) {
                // ESTree: ObjectMethod -> Property with value: FunctionExpression
                try self.writer.writeAll("{\"type\":\"Property\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writer.writeAll(",\"method\":true,\"key\":");
                try self.writeNode(key);
                try self.writer.writeAll(",\"computed\":true,\"kind\":\"init\",\"value\":");
                const key_end = self.nodeEnd(key);
                const method_end = self.nodeEnd(idx);
                try self.writer.writeAll("{\"type\":\"FunctionExpression\",");
                try self.writePosition(key_end, method_end);
                try self.writer.writeAll(",\"id\":null,\"generator\":");
                try self.writer.writeAll(if (is_generator) "true" else "false");
                try self.writer.writeAll(",\"async\":");
                try self.writer.writeAll(if (is_async) "true" else "false");
                try self.writer.writeAll(",\"expression\":false,\"params\":[");
                if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                    const params = self.ast.extra_data.items[params_start..params_end];
                    for (params, 0..) |p, j| {
                        if (j > 0) try self.writer.writeAll(",");
                        try self.writeNode(@enumFromInt(p));
                    }
                }
                try self.writer.writeAll("],\"body\":");
                try self.writeNode(body);
                try self.writer.writeAll("},\"shorthand\":false");
                // TypeScript ESTree Property: add optional field
                if (self.ast.language.isTypeScript()) {
                    try self.writer.writeAll(",\"optional\":false");
                }
                try self.writer.writeAll("}");
                return;
            }
            try self.writer.writeAll("{\"type\":\"ObjectMethod\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"method\":true,\"key\":");
            try self.writeNode(key);
            try self.writer.writeAll(",\"computed\":true,\"shorthand\":false,\"kind\":\"method\",\"id\":null,\"generator\":");
            try self.writer.writeAll(if (is_generator) "true" else "false");
            try self.writer.writeAll(",\"async\":");
            try self.writer.writeAll(if (is_async) "true" else "false");
            try self.writer.writeAll(",\"params\":[");
            if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                const params = self.ast.extra_data.items[params_start..params_end];
                for (params, 0..) |p, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(p));
                }
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll("}");
        }

        fn writeObjectMethod(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data, kind: []const u8) anyerror!void {
            _ = main_token;
            // For getter/setter, extra has [params_start, params_end, body, flags, computed_key]
            // flags: bit 0=static, bit 1=class context, bit 2=private (only set in class bodies)
            // For method_definition (kind=="method"), extra has [key, params_start, params_end, body, flags]
            // where flags has bit 0=generator, bit 1=async — no class context bits.
            const gs_extra_idx = @intFromEnum(data.extra);
            const is_getter_setter = std.mem.eql(u8, kind, "get") or std.mem.eql(u8, kind, "set");
            const gs_flags = if (is_getter_setter and gs_extra_idx + 3 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[gs_extra_idx + 3]
            else
                0;
            const is_static = (gs_flags & 1) != 0;
            const is_class_context = (gs_flags & 2) != 0;
            const is_private = (gs_flags & 4) != 0;
            // Check for body-less getter/setter in TypeScript (TSDeclareMethod)
            const gs_body_for_check: NodeIndex = if (is_getter_setter and gs_extra_idx + 2 < self.ast.extra_data.items.len)
                @enumFromInt(self.ast.extra_data.items[gs_extra_idx + 2])
            else
                .none;
            const gs_has_body = gs_body_for_check != .none;
            if (self.estree) {
                if (is_class_context) {
                    try self.writer.writeAll("{\"type\":\"MethodDefinition\",");
                } else {
                    try self.writer.writeAll("{\"type\":\"Property\",");
                }
            } else if (self.ast.language.isTypeScript() and is_class_context and !gs_has_body) {
                try self.writer.writeAll("{\"type\":\"TSDeclareMethod\",");
            } else if (is_class_context and is_private) {
                try self.writer.writeAll("{\"type\":\"ClassPrivateMethod\",");
            } else if (is_class_context) {
                try self.writer.writeAll("{\"type\":\"ClassMethod\",");
            } else {
                try self.writer.writeAll("{\"type\":\"ObjectMethod\",");
            }
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (is_class_context) {
                try self.writer.writeAll(",\"static\":");
                try self.writer.writeAll(if (is_static) "true" else "false");
            } else {
                try self.writer.writeAll(",\"method\":");
                try self.writer.writeAll(if (std.mem.eql(u8, kind, "method")) "true" else "false");
            }
            try self.writer.writeAll(",\"key\":");
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const params_start = self.ast.extra_data.items[extra_idx + 1];
            const params_end = self.ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
            // For get/set, key is stored differently
            if (std.mem.eql(u8, kind, "get") or std.mem.eql(u8, kind, "set")) {
                // getter/setter: extra has [params_start, params_end, body, flags, computed_key]
                const gs_params_start = self.ast.extra_data.items[extra_idx];
                const gs_params_end = self.ast.extra_data.items[extra_idx + 1];
                const gs_body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
                const is_computed = (gs_flags & 8) != 0;
                const computed_key_node: NodeIndex = if (is_computed and extra_idx + 4 < self.ast.extra_data.items.len)
                    @enumFromInt(self.ast.extra_data.items[extra_idx + 4])
                else
                    .none;

                if (is_computed and computed_key_node != .none) {
                    // Write the computed key expression
                    try self.writeNode(computed_key_node);
                } else {
                    // For getter/setter, main_token is the key token
                    const gs_main = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                    const gs_tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(gs_main)];
                    const key_start2 = self.ast.tokens.items(.start)[@intFromEnum(gs_main)];
                    const key_end2 = self.ast.tokens.items(.end)[@intFromEnum(gs_main)];
                    const key_name2 = self.ast.source[key_start2..key_end2];
                    if (is_private) {
                        const pn_start = if (key_start2 > 0) key_start2 - 1 else key_start2;
                        if (self.estree) {
                            // ESTree: PrivateIdentifier
                            try self.writer.writeAll("{\"type\":\"PrivateIdentifier\",");
                            try self.writePosition(pn_start, key_end2);
                            try self.writer.writeAll(",\"name\":\"");
                            try self.writeJsonEscaped(key_name2);
                            try self.writer.writeAll("\"}");
                        } else {
                            // Babel: Wrap in PrivateName
                            try self.writer.writeAll("{\"type\":\"PrivateName\",");
                            try self.writePosition(pn_start, key_end2);
                            try self.writer.writeAll(",\"id\":");
                            try self.writer.writeAll("{\"type\":\"Identifier\",");
                            try self.writePositionWithIdentName(key_start2, key_end2, key_name2);
                            try self.writer.writeAll(",\"name\":\"");
                            try self.writeJsonEscaped(key_name2);
                            try self.writer.writeAll("\"}}");
                        }
                    } else if (gs_tok_tag == .string) {
                        try self.writeStringLiteralFromToken(gs_main);
                    } else if (gs_tok_tag == .numeric) {
                        try self.writeNumericLiteralFromToken(gs_main);
                    } else if (gs_tok_tag == .bigint) {
                        try self.writeBigIntLiteralFromToken(gs_main);
                    } else {
                        try self.writer.writeAll("{\"type\":\"Identifier\",");
                        try self.writePositionWithIdentName(key_start2, key_end2, key_name2);
                        try self.writer.writeAll(",\"name\":\"");
                        try self.writeJsonEscaped(key_name2);
                        try self.writer.writeAll("\"");
                        if (self.ast.language.isTypeScript()) {
                            try self.writer.writeAll(",\"decorators\":[],\"optional\":false");
                        }
                        try self.writer.writeAll("}");
                    }
                }
                try self.writer.writeAll(",\"computed\":");
                try self.writer.writeAll(if (is_computed) "true" else "false");
                try self.writer.writeAll(",\"shorthand\":false,\"kind\":\"");
                try self.writer.writeAll(kind);
                const gs_is_generator = (gs_flags & 16) != 0;
                try self.writer.writeAll("\",\"id\":null,\"generator\":");
                try self.writer.writeAll(if (gs_is_generator) "true" else "false");
                try self.writer.writeAll(",\"async\":false,\"params\":[");
                if (gs_params_start <= gs_params_end and gs_params_end <= self.ast.extra_data.items.len) {
                    const gs_params = self.ast.extra_data.items[gs_params_start..gs_params_end];
                    for (gs_params, 0..) |p, j| {
                        if (j > 0) try self.writer.writeAll(",");
                        try self.writeNode(@enumFromInt(p));
                    }
                }
                try self.writer.writeAll("]");
                if (gs_has_body) {
                    try self.writer.writeAll(",\"body\":");
                    try self.writeNode(gs_body);
                }
                try self.writeReturnTypeAndTypeParams(idx);
                if (is_class_context) {
                    try self.writeTsClassModifiers(idx);
                    if (gs_has_body) try self.writer.writeAll(",\"expression\":false");
                    // ESTree MethodDefinition: override, optional
                    if (self.estree and self.ast.language.isTypeScript()) {
                        const cm_mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
                        if (cm_mods & TS_MOD_OVERRIDE == 0) try self.writer.writeAll(",\"override\":false");
                        try self.writer.writeAll(",\"optional\":false");
                    }
                    try self.writeDecorators(idx);
                    try self.writer.writeAll("}");
                } else {
                    // TypeScript ESTree Property: add optional field
                    if (self.estree and self.ast.language.isTypeScript()) {
                        try self.writer.writeAll(",\"optional\":false");
                    }
                    try self.writer.writeAll("}");
                }
                return;
            }
            try self.writeNode(key);
            // flags stored as extra[4]: bit 0 = generator, bit 1 = async
            const method_flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 4]
            else
                0;
            const is_generator_method = (method_flags & 1) != 0 or blk: {
                // Fallback: check if main_token is *
                const method_main = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                break :blk self.ast.tokens.items(.tag)[@intFromEnum(method_main)] == .asterisk;
            };
            const is_async_method = (method_flags & 2) != 0;
            try self.writer.writeAll(",\"computed\":false,\"shorthand\":false,\"kind\":\"");
            try self.writer.writeAll(kind);
            try self.writer.writeAll("\",\"id\":null,\"generator\":");
            try self.writer.writeAll(if (is_generator_method) "true" else "false");
            try self.writer.writeAll(",\"async\":");
            try self.writer.writeAll(if (is_async_method) "true" else "false");
            try self.writer.writeAll(",\"params\":[");
            if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                const params = self.ast.extra_data.items[params_start..params_end];
                for (params, 0..) |p, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(p));
                }
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            try self.writeReturnTypeAndTypeParams(idx);
            // TypeScript ESTree Property: add optional field
            if (self.estree and self.ast.language.isTypeScript()) {
                try self.writer.writeAll(",\"optional\":false");
            }
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        // === Patterns ===

        fn writeArrayPattern(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ArrayPattern\",");
            const end = self.nodeEnd(idx);
            try self.writePosition(self.nodeStart(idx), end);
            try self.writeExtraObject(self.findTrailingComma(end));
            try self.writer.writeAll(",\"elements\":[");
            try self.writeExtraRange(data);
            try self.writer.writeAll("]");
            try self.writeTsOptionalFlag(idx);
            try self.writeFlowTypeAnnotationForNode(idx);
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        fn writeObjectPattern(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ObjectPattern\",");
            const end = self.nodeEnd(idx);
            try self.writePosition(self.nodeStart(idx), end);
            try self.writeExtraObject(self.findTrailingComma(end));
            try self.writer.writeAll(",\"properties\":[");
            try self.writeExtraRange(data);
            try self.writer.writeAll("]");
            try self.writeTsOptionalFlag(idx);
            try self.writeFlowTypeAnnotationForNode(idx);
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        fn writeAssignmentPattern(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"AssignmentPattern\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"left\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"right\":");
            try self.writeNode(data.binary.rhs);
            try self.writeFlowTypeAnnotationForNode(idx);
            try self.writer.writeAll("}");
        }

        fn writeRestElement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"RestElement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"argument\":");
            try self.writeNode(data.unary);
            try self.writeFlowTypeAnnotationForNode(idx);
            if (self.ast.ts_optional_params.get(@intFromEnum(idx))) |_| {
                try self.writer.writeAll(",\"optional\":true");
            }
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        // === Statements ===

        fn writeExpressionStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ExpressionStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeDirective(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"Directive\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"value\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeDirectiveLiteral(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const raw = self.ast.source[start..end];
            // value is string content without quotes
            const value = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            try self.writer.writeAll("{\"type\":\"DirectiveLiteral\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"extra\":{\"raw\":\"");
            try self.writeJsonEscaped(raw);
            try self.writer.writeAll("\",\"rawValue\":");
            try self.writeJsonString(value);
            try self.writer.writeAll(",\"expressionValue\":");
            try self.writeJsResolvedJsonString(value);
            try self.writer.writeAll("},\"value\":");
            try self.writeJsonString(value);
            try self.writer.writeAll("}");
        }

        /// Write a DirectiveLiteral from a string_literal token (used when converting
        /// expression statements to directives in block statements/function bodies).
        fn writeDirectiveLiteralFromStringToken(self: *Self, main_token: TokenIndex, expr_stmt_idx: NodeIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const raw = self.ast.source[start..end];
            const value = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            // Use the string literal node's positions
            const datas = self.ast.nodes.items(.data);
            const string_node = datas[@intFromEnum(expr_stmt_idx)].unary;
            try self.writer.writeAll("{\"type\":\"DirectiveLiteral\",");
            try self.writePosition(self.nodeStart(string_node), self.nodeEnd(string_node));
            try self.writer.writeAll(",\"extra\":{\"raw\":\"");
            try self.writeJsonEscaped(raw);
            try self.writer.writeAll("\",\"rawValue\":");
            try self.writeJsonString(value);
            try self.writer.writeAll(",\"expressionValue\":");
            try self.writeJsResolvedJsonString(value);
            try self.writer.writeAll("},\"value\":");
            try self.writeJsonString(value);
            try self.writer.writeAll("}");
        }

        /// ESTree: write a directive as ExpressionStatement { expression: Literal, directive: "..." }
        fn writeEstreeDirectiveExprStmt(self: *Self, stmt_idx: NodeIndex, lit_node: NodeIndex, token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(token)];
            const raw = self.ast.source[start..end];
            const value = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;

            try self.writer.writeAll("{\"type\":\"ExpressionStatement\",");
            try self.writePosition(self.nodeStart(stmt_idx), self.nodeEnd(stmt_idx));
            try self.writer.writeAll(",\"expression\":{\"type\":\"Literal\",");
            try self.writePosition(self.nodeStart(lit_node), self.nodeEnd(lit_node));
            try self.writer.writeAll(",\"value\":");
            try self.writeJsResolvedJsonString(value);
            try self.writer.writeAll(",\"raw\":\"");
            try self.writeJsonEscaped(raw);
            try self.writer.writeAll("\"},\"directive\":");
            try self.writeJsonString(value);
            try self.writer.writeAll("}");
        }

        fn writeDirectiveAsEstreeExprStmt(self: *Self, idx: NodeIndex) anyerror!void {
            const data = self.ast.nodes.items(.data)[@intFromEnum(idx)];
            const lit_idx = data.unary;
            const lit_main_token = self.ast.nodes.items(.main_token)[@intFromEnum(lit_idx)];
            try self.writeEstreeDirectiveExprStmt(idx, lit_idx, lit_main_token);
        }

        fn writeStringExprStmtAsEstreeDirective(self: *Self, idx: NodeIndex) anyerror!void {
            const expr_idx = self.ast.nodes.items(.data)[@intFromEnum(idx)].unary;
            const main_tok = self.ast.nodes.items(.main_token)[@intFromEnum(expr_idx)];
            try self.writeEstreeDirectiveExprStmt(idx, expr_idx, main_tok);
        }

        // === JSX serialization ===

        fn writeJsxElement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXElement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            const extra_idx = @intFromEnum(data.extra);
            const opening: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const closing: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const children_start = self.ast.extra_data.items[extra_idx + 2];
            const children_end = self.ast.extra_data.items[extra_idx + 3];
            try self.writer.writeAll(",\"openingElement\":");
            try self.writeNode(opening);
            try self.writer.writeAll(",\"closingElement\":");
            try self.writeNode(closing);
            try self.writer.writeAll(",\"children\":[");
            try self.writeNodeRange(children_start, children_end);
            // Handle parenthesized: extra.parenthesized
            if (self.paren_start != null) {
                try self.writer.writeAll("],\"extra\":{");
                _ = try self.consumeParenFields(false);
                try self.writer.writeAll("}}");
            } else {
                try self.writer.writeAll("]}");
            }
        }

        fn writeJsxOpeningElement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXOpeningElement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeJsxOpeningElementInternals(idx, data, false);
            try self.writer.writeAll("}");
        }

        fn writeJsxClosingElement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXClosingElement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"name\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeJsxSelfClosingElement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXElement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"openingElement\":{\"type\":\"JSXOpeningElement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeJsxOpeningElementInternals(idx, data, true);
            if (self.paren_start != null) {
                try self.writer.writeAll("},\"closingElement\":null,\"children\":[],\"extra\":{");
                _ = try self.consumeParenFields(false);
                try self.writer.writeAll("}}");
            } else {
                try self.writer.writeAll("},\"closingElement\":null,\"children\":[]}");
            }
        }

        /// Shared helper: writes name, typeArguments, attributes, and selfClosing fields for a JSX opening element.
        fn writeJsxOpeningElementInternals(self: *Self, idx: NodeIndex, data: Node.Data, self_closing: bool) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const attr_start = self.ast.extra_data.items[extra_idx + 1];
            const attr_end = self.ast.extra_data.items[extra_idx + 2];
            try self.writer.writeAll(",\"name\":");
            try self.writeNode(name);
            // Emit typeArguments if present (for TSX: <Component<T> ...>)
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeArguments\":");
                try self.writeNode(tp);
            }
            try self.writer.writeAll(",\"attributes\":[");
            try self.writeNodeRange(attr_start, attr_end);
            try self.writer.writeAll("],\"selfClosing\":");
            try self.writer.writeAll(if (self_closing) "true" else "false");
        }

        fn writeJsxFragment(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXFragment\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            const extra_idx = @intFromEnum(data.extra);
            const opening: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const closing: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const children_start = self.ast.extra_data.items[extra_idx + 2];
            const children_end = self.ast.extra_data.items[extra_idx + 3];
            try self.writer.writeAll(",\"openingFragment\":");
            try self.writeNode(opening);
            try self.writer.writeAll(",\"closingFragment\":");
            try self.writeNode(closing);
            try self.writer.writeAll(",\"children\":[");
            try self.writeNodeRange(children_start, children_end);
            try self.writer.writeAll("]}");
        }

        fn writeJsxAttribute(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXAttribute\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"name\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"value\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeJsxSpreadAttribute(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXSpreadAttribute\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"argument\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeJsxSpreadChild(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXSpreadChild\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeJsxExpressionContainer(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXExpressionContainer\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeJsxText(self: *Self, idx: NodeIndex, _: TokenIndex) anyerror!void {
            const i = @intFromEnum(idx);
            const data = self.ast.nodes.items(.data)[i];
            const extra_idx = @intFromEnum(data.extra);
            const text_start = self.ast.extra_data.items[extra_idx];
            const text_end = self.ast.extra_data.items[extra_idx + 1];
            const raw = self.ast.source[text_start..text_end];
            try self.writer.writeAll("{\"type\":\"JSXText\",");
            try self.writePosition(text_start, text_end);
            // rawValue and value get HTML-entity-decoded text; raw keeps original
            try self.writer.writeAll(",\"extra\":{\"rawValue\":\"");
            try writeJsxDecodedString(self.writer, raw);
            try self.writer.writeAll("\",\"raw\":");
            try self.writeJsonString(raw);
            try self.writer.writeAll("},\"value\":\"");
            try writeJsxDecodedString(self.writer, raw);
            try self.writer.writeAll("\"}");
        }

        fn writeJsxStringLiteral(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const raw = self.ast.source[start..end];
            // value is string content without quotes, HTML-entity-decoded
            const content = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            try self.writer.writeAll("{\"type\":\"StringLiteral\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"extra\":{\"rawValue\":\"");
            try writeJsxDecodedString(self.writer, content);
            try self.writer.writeAll("\",\"raw\":\"");
            try self.writeJsonEscaped(raw);
            try self.writer.writeAll("\"},\"value\":\"");
            try writeJsxDecodedString(self.writer, content);
            try self.writer.writeAll("\"}");
        }

        fn writeJsxIdentifier(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end_off = self.nodeEnd(idx);
            // For hyphenated JSX names (e.g. "my-component"), end_offset spans
            // multiple tokens. Use it to get the full identifier name.
            const name = self.ast.source[start..end_off];
            try self.writer.writeAll("{\"type\":\"JSXIdentifier\",");
            try self.writePosition(self.nodeStart(idx), end_off);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeJsonEscaped(name);
            try self.writer.writeAll("\"}");
        }

        fn writeJsxMemberExpression(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXMemberExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"object\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"property\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeJsxNamespacedName(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"JSXNamespacedName\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"namespace\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"name\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        // === TypeScript serialization ===

        // === TypeScript Serialization ===

        fn tsKeywordTypeName(text: []const u8) []const u8 {
            if (std.mem.eql(u8, text, "string")) return "TSStringKeyword";
            if (std.mem.eql(u8, text, "number")) return "TSNumberKeyword";
            if (std.mem.eql(u8, text, "boolean")) return "TSBooleanKeyword";
            if (std.mem.eql(u8, text, "symbol")) return "TSSymbolKeyword";
            if (std.mem.eql(u8, text, "bigint")) return "TSBigIntKeyword";
            if (std.mem.eql(u8, text, "any")) return "TSAnyKeyword";
            if (std.mem.eql(u8, text, "unknown")) return "TSUnknownKeyword";
            if (std.mem.eql(u8, text, "never")) return "TSNeverKeyword";
            if (std.mem.eql(u8, text, "undefined")) return "TSUndefinedKeyword";
            if (std.mem.eql(u8, text, "object")) return "TSObjectKeyword";
            if (std.mem.eql(u8, text, "void")) return "TSVoidKeyword";
            if (std.mem.eql(u8, text, "null")) return "TSNullKeyword";
            if (std.mem.eql(u8, text, "this")) return "TSThisType";
            if (std.mem.eql(u8, text, "intrinsic")) return "TSIntrinsicKeyword";
            return "TSTypeReference";
        }

        fn writeTsTypeAnnotation(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsTypeReference(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSTypeReference\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"typeName\":");
            try self.writeNode(data.binary.lhs);
            if (data.binary.rhs != .none) {
                try self.writer.writeAll(",\"typeArguments\":");
                try self.writeNode(data.binary.rhs);
            }
            try self.writer.writeAll("}");
        }

        fn writeTsKeywordType(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const text = self.ast.tokenSlice(main_token);
            const type_name = tsKeywordTypeName(text);
            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll("}");
        }

        fn writeTsArrayType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSArrayType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"elementType\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsTupleType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            try self.writer.writeAll("{\"type\":\"TSTupleType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"elementTypes\":[");
            try self.writeNodeRange(range_start, range_end);
            try self.writer.writeAll("]}");
        }

        fn writeTsUnionOrIntersectionType(self: *Self, idx: NodeIndex, type_name: []const u8, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"types\":[");
            try self.writeNodeRange(range_start, range_end);
            try self.writer.writeAll("]}");
        }

        fn writeTsFunctionType(self: *Self, idx: NodeIndex, type_name: []const u8, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const type_params = @as(NodeIndex, @enumFromInt(self.ast.extra_data.items[extra_idx]));
            const params_start = self.ast.extra_data.items[extra_idx + 1];
            const params_end = self.ast.extra_data.items[extra_idx + 2];
            const return_type = @as(NodeIndex, @enumFromInt(self.ast.extra_data.items[extra_idx + 3]));
            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (type_params != .none) {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(type_params);
            }
            try self.writer.writeAll(",\"params\":[");
            try self.writeNodeRange(params_start, params_end);
            try self.writer.writeAll("],\"returnType\":");
            if (return_type != .none) {
                // Wrap in TSTypeAnnotation — start position is the arrow token
                const arrow_tok_raw = if (extra_idx + 4 < self.ast.extra_data.items.len)
                    self.ast.extra_data.items[extra_idx + 4]
                else
                    0;
                const ret_start = if (arrow_tok_raw != 0)
                    self.ast.tokens.items(.start)[arrow_tok_raw]
                else
                    self.nodeStart(return_type);
                try self.writer.writeAll("{\"type\":\"TSTypeAnnotation\",");
                try self.writePosition(ret_start, self.nodeEnd(return_type));
                try self.writer.writeAll(",\"typeAnnotation\":");
                try self.writeNode(return_type);
                try self.writer.writeAll("}");
            } else {
                try self.writer.writeAll("null");
            }
            // TSConstructorType needs "abstract" field
            const node_tag = self.ast.nodes.items(.tag)[@intFromEnum(idx)];
            if (node_tag == .ts_constructor_type) {
                // Check if main_token is 'abstract' (set by parser when abstract constructor type)
                // or if 'abstract' precedes 'new'
                const is_abstract = blk_abs: {
                    const mt = @intFromEnum(self.ast.nodes.items(.main_token)[@intFromEnum(idx)]);
                    // First check if main_token itself is "abstract"
                    const mt_tag = self.ast.tokens.items(.tag)[mt];
                    if (mt_tag == .identifier) {
                        const mt_start = self.ast.tokens.items(.start)[mt];
                        const mt_end = self.ast.tokens.items(.end)[mt];
                        if (std.mem.eql(u8, self.ast.source[mt_start..mt_end], "abstract")) {
                            break :blk_abs true;
                        }
                    }
                    // Fallback: check previous token
                    if (mt > 0) {
                        const prev_tag = self.ast.tokens.items(.tag)[mt - 1];
                        if (prev_tag == .identifier) {
                            const prev_start = self.ast.tokens.items(.start)[mt - 1];
                            const prev_end = self.ast.tokens.items(.end)[mt - 1];
                            break :blk_abs std.mem.eql(u8, self.ast.source[prev_start..prev_end], "abstract");
                        }
                    }
                    break :blk_abs false;
                };
                try self.writer.writeAll(",\"abstract\":");
                try self.writer.writeAll(if (is_abstract) "true" else "false");
            }
            try self.writer.writeAll("}");
        }

        fn writeTsParenthesizedType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            if (self.ast.create_parenthesized_expressions) {
                // When createParenthesizedExpressions is true, emit TSParenthesizedType wrapper
                try self.writer.writeAll("{\"type\":\"TSParenthesizedType\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writer.writeAll(",\"typeAnnotation\":");
                try self.writeNode(data.unary);
                try self.writer.writeByte('}');
                return;
            }
            // Babel unwraps parenthesized types and adds extra.parenthesized on the inner type
            const main_tok = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            const paren_pos = self.ast.tokens.items(.start)[@intFromEnum(main_tok)];
            const prev_paren = self.paren_start;
            if (self.paren_start == null) {
                self.paren_start = paren_pos;
            }
            try self.writeNode(data.unary);
            self.paren_start = prev_paren;
        }

        fn writeTsOptionalType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSOptionalType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsRestType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSRestType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsLiteralType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSLiteralType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"literal\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsTypeParameter(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const constraint: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const default_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            // Third extra slot stores the name token index (may differ from main_token when modifiers present)
            const name_token_raw = self.ast.extra_data.items[extra_idx + 2];
            const flags = self.ast.extra_data.items[extra_idx + 3];
            const has_in = (flags & 1) != 0;
            const has_out = (flags & 2) != 0;
            const has_const = (flags & 4) != 0;
            const accessibility = (flags >> 3) & 3; // 0=none, 1=public, 2=private, 3=protected
            const name_tok: TokenIndex = if (name_token_raw != @intFromEnum(NodeIndex.none))
                @enumFromInt(name_token_raw)
            else
                main_token;
            const name = self.ast.tokenSlice(name_tok);
            const tok_start = self.ast.tokens.items(.start)[@intFromEnum(name_tok)];
            const tok_end = self.ast.tokens.items(.end)[@intFromEnum(name_tok)];
            try self.writer.writeAll("{\"type\":\"TSTypeParameter\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (accessibility != 0) {
                try self.writer.writeAll(",\"accessibility\":\"");
                switch (accessibility) {
                    1 => try self.writer.writeAll("public"),
                    2 => try self.writer.writeAll("private"),
                    3 => try self.writer.writeAll("protected"),
                    else => {},
                }
                try self.writer.writeAll("\"");
            }
            // Babel expects name as an Identifier node
            try self.writer.writeAll(",\"name\":{\"type\":\"Identifier\",");
            try self.writePositionWithIdentName(tok_start, tok_end, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"},\"constraint\":");
            if (constraint != .none) try self.writeNode(constraint) else try self.writer.writeAll("null");
            try self.writer.writeAll(",\"default\":");
            if (default_type != .none) try self.writeNode(default_type) else try self.writer.writeAll("null");
            if (has_in) try self.writer.writeAll(",\"in\":true") else try self.writer.writeAll(",\"in\":false");
            if (has_out) try self.writer.writeAll(",\"out\":true") else try self.writer.writeAll(",\"out\":false");
            if (has_const) try self.writer.writeAll(",\"const\":true") else try self.writer.writeAll(",\"const\":false");
            try self.writer.writeAll("}");
        }

        fn writeTsTypeParameterDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSTypeParameterDeclaration\",");
            const node_end = self.nodeEnd(idx);
            try self.writePosition(self.nodeStart(idx), node_end);
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            try self.writer.writeAll(",\"params\":[");
            try self.writeNodeRange(range_start, range_end);
            try self.writer.writeAll("]");
            // Detect trailing comma before closing `>`
            const trailing_comma = self.findTrailingComma(node_end);
            if (trailing_comma != null)
                try self.writeExtraObject(trailing_comma);
            try self.writer.writeAll("}");
        }

        fn writeTsTypeParameterInstantiation(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSTypeParameterInstantiation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            try self.writer.writeAll(",\"params\":[");
            try self.writeNodeRange(range_start, range_end);
            try self.writer.writeAll("]}");
        }

        fn writeTsQualifiedName(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSQualifiedName\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"left\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"right\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeTsConditionalType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            try self.writer.writeAll("{\"type\":\"TSConditionalType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"checkType\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx]));
            try self.writer.writeAll(",\"extendsType\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 1]));
            try self.writer.writeAll(",\"trueType\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 2]));
            try self.writer.writeAll(",\"falseType\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 3]));
            try self.writer.writeAll("}");
        }

        fn writeTsInferType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSInferType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeExtraObject(null);
            try self.writer.writeAll(",\"typeParameter\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsMappedType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const type_param = @as(NodeIndex, @enumFromInt(self.ast.extra_data.items[extra_idx]));
            const type_ann = @as(NodeIndex, @enumFromInt(self.ast.extra_data.items[extra_idx + 1]));
            const name_type = @as(NodeIndex, @enumFromInt(self.ast.extra_data.items[extra_idx + 2]));
            const optional_mod = self.ast.extra_data.items[extra_idx + 3];
            const readonly_mod = self.ast.extra_data.items[extra_idx + 4];

            // Decompose the TSTypeParameter into key (Identifier) and constraint
            const tp_extra_idx = @intFromEnum(self.ast.nodes.items(.data)[@intFromEnum(type_param)].extra);
            const constraint: NodeIndex = @enumFromInt(self.ast.extra_data.items[tp_extra_idx]);
            const name_token_raw = self.ast.extra_data.items[tp_extra_idx + 2];
            const tp_main_token = self.ast.nodes.items(.main_token)[@intFromEnum(type_param)];
            const name_tok: TokenIndex = if (name_token_raw != @intFromEnum(NodeIndex.none))
                @enumFromInt(name_token_raw)
            else
                tp_main_token;
            const name = self.ast.tokenSlice(name_tok);
            const tok_start = self.ast.tokens.items(.start)[@intFromEnum(name_tok)];
            const tok_end = self.ast.tokens.items(.end)[@intFromEnum(name_tok)];

            try self.writer.writeAll("{\"type\":\"TSMappedType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));

            // Write key as an Identifier node
            try self.writer.writeAll(",\"key\":{\"type\":\"Identifier\",");
            try self.writePositionWithIdentName(tok_start, tok_end, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"}");

            // Write constraint
            try self.writer.writeAll(",\"constraint\":");
            if (constraint != .none) try self.writeNode(constraint) else try self.writer.writeAll("null");

            try self.writer.writeAll(",\"nameType\":");
            if (name_type != .none) try self.writeNode(name_type) else try self.writer.writeAll("null");
            try self.writer.writeAll(",\"typeAnnotation\":");
            if (type_ann != .none) try self.writeNode(type_ann) else try self.writer.writeAll("null");
            try self.writer.writeAll(",\"optional\":");
            try self.writeTsModifier(optional_mod);
            try self.writer.writeAll(",\"readonly\":");
            try self.writeTsModifier(readonly_mod);
            try self.writer.writeAll("}");
        }

        fn writeTsModifier(self: *Self, mod: u32) anyerror!void {
            switch (mod) {
                1 => try self.writer.writeAll("true"),
                2 => try self.writer.writeAll("\"+\""),
                3 => try self.writer.writeAll("\"-\""),
                else => try self.writer.writeAll("false"),
            }
        }

        fn writeTsIndexedAccessType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSIndexedAccessType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"objectType\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"indexType\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeTsTemplateLiteralType(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSTemplateLiteralType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            const tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
            if (tag == .template_no_sub) {
                // Simple template - emit with single quasi and no types
                try self.writer.writeAll(",\"types\":[],\"quasis\":[");
                try self.writeTemplateElement(main_token, true);
                try self.writer.writeAll("]}");
                return;
            }
            const extra_idx = @intFromEnum(data.extra);
            const types_start = self.ast.extra_data.items[extra_idx];
            const types_end = self.ast.extra_data.items[extra_idx + 1];
            const tpl_toks_start = self.ast.extra_data.items[extra_idx + 2];
            const tpl_toks_end = self.ast.extra_data.items[extra_idx + 3];
            // Write types
            try self.writer.writeAll(",\"types\":[");
            try self.writeNodeRange(types_start, types_end);
            try self.writer.writeAll("]");
            // Write quasis from template tokens: head, then middle/tail tokens
            try self.writer.writeAll(",\"quasis\":[");
            try self.writeTemplateElement(main_token, false);
            if (tpl_toks_start < tpl_toks_end and tpl_toks_end <= self.ast.extra_data.items.len) {
                for (self.ast.extra_data.items[tpl_toks_start..tpl_toks_end]) |tok_idx| {
                    try self.writer.writeAll(",");
                    const tok_tag = self.ast.tokens.items(.tag)[tok_idx];
                    try self.writeTemplateElement(@enumFromInt(tok_idx), tok_tag == .template_tail);
                }
            }
            try self.writer.writeAll("]}");
        }

        fn writeTsTypeofType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSTypeQuery\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"exprName\":");
            try self.writeNode(data.unary);
            // typeArguments from side table
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeArguments\":");
                try self.writeNode(tp);
            }
            try self.writer.writeAll("}");
        }

        fn writeTsTypeOperator(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSTypeOperator\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"operator\":\"");
            try self.writer.writeAll(self.ast.tokenSlice(main_token));
            try self.writer.writeAll("\",\"typeAnnotation\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsTypePredicate(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const param_name: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const type_ann: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const asserts_flag = self.ast.extra_data.items[extra_idx + 2];
            try self.writer.writeAll("{\"type\":\"TSTypePredicate\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"parameterName\":");
            try self.writeNode(param_name);
            try self.writer.writeAll(",\"typeAnnotation\":");
            if (type_ann != .none) {
                try self.writeNode(type_ann);
            } else {
                try self.writer.writeAll("null");
            }
            try self.writer.writeAll(",\"asserts\":");
            try self.writer.writeAll(if (asserts_flag != 0) "true" else "false");
            try self.writer.writeAll("}");
        }

        fn writeTsImportType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const argument: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const qualifier: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll("{\"type\":\"TSImportType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            // Unit 2's version with options from extra_data[3]
            try self.writer.writeAll(",\"source\":");
            try self.writeNode(argument);
            try self.writer.writeAll(",\"options\":");
            if (self.ast.extra_data.items.len > extra_idx + 3)
                try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 3]))
            else
                try self.writer.writeAll("null");
            try self.writer.writeAll(",\"qualifier\":");
            try self.writeNode(qualifier);
            try self.writer.writeAll(",\"typeArguments\":");
            try self.writeNode(type_params);
            try self.writer.writeAll("}");
        }

        fn writeTsNamedTupleMember(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const rhs = data.binary.rhs;
            const rhs_tag = self.ast.nodes.items(.tag)[@intFromEnum(rhs)];
            const is_optional = rhs_tag == .ts_optional_type;
            try self.writer.writeAll("{\"type\":\"TSNamedTupleMember\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"label\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"elementType\":");
            if (is_optional) {
                // Unwrap the optional type to get the inner type
                const inner = self.ast.nodes.items(.data)[@intFromEnum(rhs)].unary;
                try self.writeNode(inner);
            } else {
                try self.writeNode(rhs);
            }
            try self.writer.writeAll(if (is_optional) ",\"optional\":true}" else ",\"optional\":false}");
        }

        fn writeTsAsExpression(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSAsExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeChildIsolated(data.binary.lhs);
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeChildIsolated(data.binary.rhs);
            try self.writeExtraObject(null);
            try self.writer.writeAll("}");
        }

        fn writeTsSatisfiesExpression(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSSatisfiesExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeChildIsolated(data.binary.lhs);
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeChildIsolated(data.binary.rhs);
            try self.writeExtraObject(null);
            try self.writer.writeAll("}");
        }

        fn writeTsNonNullExpression(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSNonNullExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsInstantiationExpression(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSInstantiationExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeParenExtra();
            try self.writer.writeAll(",\"expression\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"typeArguments\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeTsTypeAssertion(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSTypeAssertion\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeChildIsolated(data.binary.lhs);
            try self.writer.writeAll(",\"expression\":");
            try self.writeChildIsolated(data.binary.rhs);
            try self.writeExtraObject(null);
            try self.writer.writeAll("}");
        }

        fn writeTsTypeCastExpression(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const type_ann: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);

            try self.writer.writeAll("{\"type\":\"TSTypeCastExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeChildIsolated(expr);
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(type_ann);
            try self.writeExtraObject(null);
            try self.writer.writeAll("}");
        }

        fn writeTsTypeAliasDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            try self.writer.writeAll("{\"type\":\"TSTypeAliasDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx]));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 1]));
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 2]));
            // Always emit declare field for TypeScript
            if (self.isDeclareNode(idx))
                try self.writer.writeAll(",\"declare\":true")
            else if (self.ast.language.isTypeScript())
                try self.writer.writeAll(",\"declare\":false");
            try self.writer.writeAll("}");
        }

        fn writeTsInterfaceDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            try self.writer.writeAll("{\"type\":\"TSInterfaceDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeTsClassModifiers(idx);
            try self.writer.writeAll(",\"id\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx]));
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 1]));
            const extends_start = self.ast.extra_data.items[extra_idx + 3];
            const extends_end = self.ast.extra_data.items[extra_idx + 4];
            if (extends_start < extends_end) {
                try self.writer.writeAll(",\"extends\":[");
                const items = self.ast.extra_data.items[extends_start..extends_end];
                for (items, 0..) |item, i| {
                    if (i > 0) try self.writer.writeAll(",");
                    const ref_idx: NodeIndex = @enumFromInt(item);
                    try self.writeTsInterfaceHeritage(ref_idx);
                }
                try self.writer.writeAll("]");
            } else {
                try self.writer.writeAll(",\"extends\":[]");
            }
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 2]));
            if (self.isDeclareNode(idx)) try self.writer.writeAll(",\"declare\":true");
            try self.writer.writeAll("}");
        }

        /// Write a TSInterfaceHeritage node from a ts_type_reference AST node.
        fn writeTsInterfaceHeritage(self: *Self, ref_idx: NodeIndex) anyerror!void {
            const ref_tag = self.ast.nodes.items(.tag)[@intFromEnum(ref_idx)];
            try self.writer.writeAll("{\"type\":\"TSInterfaceHeritage\",");
            try self.writePosition(self.nodeStart(ref_idx), self.nodeEnd(ref_idx));
            if (ref_tag == .ts_type_reference) {
                const ref_data = self.ast.nodes.items(.data)[@intFromEnum(ref_idx)];
                try self.writer.writeAll(",\"expression\":");
                try self.writeTsEntityNameAsExpr(ref_data.binary.lhs);
                if (ref_data.binary.rhs != .none) {
                    try self.writer.writeAll(",\"typeArguments\":");
                    try self.writeNode(ref_data.binary.rhs);
                } else {
                    try self.writer.writeAll(",\"typeArguments\":null");
                }
            } else {
                try self.writer.writeAll(",\"expression\":");
                try self.writeNode(ref_idx);
                try self.writer.writeAll(",\"typeArguments\":null");
            }
            try self.writer.writeAll("}");
        }

        /// Write a TS entity name (Identifier or TSQualifiedName) in expression form.
        fn writeTsEntityNameAsExpr(self: *Self, name_idx: NodeIndex) anyerror!void {
            const tag = self.ast.nodes.items(.tag)[@intFromEnum(name_idx)];
            if (tag == .ts_qualified_name) {
                const data = self.ast.nodes.items(.data)[@intFromEnum(name_idx)];
                try self.writer.writeAll("{\"type\":\"MemberExpression\",");
                try self.writePosition(self.nodeStart(name_idx), self.nodeEnd(name_idx));
                try self.writer.writeAll(",\"object\":");
                try self.writeTsEntityNameAsExpr(data.binary.lhs);
                try self.writer.writeAll(",\"computed\":false,\"property\":");
                try self.writeNode(data.binary.rhs);
                try self.writer.writeAll("}");
            } else {
                try self.writeNode(name_idx);
            }
        }

        fn writeTsInterfaceBody(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            try self.writer.writeAll("{\"type\":\"TSInterfaceBody\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"body\":[");
            try self.writeNodeRange(range_start, range_end);
            try self.writer.writeAll("]}");
        }

        fn writeTsTypeLiteral(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            try self.writer.writeAll("{\"type\":\"TSTypeLiteral\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeExtraObject(null);
            try self.writer.writeAll(",\"members\":[");
            try self.writeNodeRange(range_start, range_end);
            try self.writer.writeAll("]}");
        }

        fn writeTsPropertySignature(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            _ = main_token;
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const type_ann: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const flags = self.ast.extra_data.items[extra_idx + 2];
            const is_optional = (flags & 1) != 0;
            const is_readonly = (flags & 2) != 0;
            const is_computed = (flags & 4) != 0;
            try self.writer.writeAll("{\"type\":\"TSPropertySignature\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeTsClassModifiers(idx);
            if (is_readonly) {
                try self.writer.writeAll(",\"readonly\":true");
            }
            try self.writer.writeAll(",\"key\":");
            try self.writeNode(key);
            try self.writer.writeAll(",\"computed\":");
            try self.writer.writeAll(if (is_computed) "true" else "false");
            if (is_optional) {
                try self.writer.writeAll(",\"optional\":true");
            }
            if (type_ann != .none) {
                try self.writer.writeAll(",\"typeAnnotation\":");
                try self.writeNode(type_ann);
            }
            try self.writer.writeAll("}");
        }

        fn writeTsMethodSignature(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            _ = main_token;
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const return_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 4]);
            const flags = self.ast.extra_data.items[extra_idx + 5];
            const kind_code = self.ast.extra_data.items[extra_idx + 6];
            const is_optional = (flags & 1) != 0;
            const is_computed = (flags & 4) != 0;
            const kind = switch (kind_code) {
                1 => "get",
                2 => "set",
                else => "method",
            };
            try self.writer.writeAll("{\"type\":\"TSMethodSignature\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeTsClassModifiers(idx);
            try self.writer.writeAll(",\"key\":");
            try self.writeNode(key);
            try self.writer.writeAll(",\"computed\":");
            try self.writer.writeAll(if (is_computed) "true" else "false");
            if (is_optional) {
                try self.writer.writeAll(",\"optional\":true");
            }
            if (type_params != .none) {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(type_params);
            }
            try self.writer.writeAll(",\"params\":[");
            try self.writeNodeRange(self.ast.extra_data.items[extra_idx + 2], self.ast.extra_data.items[extra_idx + 3]);
            try self.writer.writeAll("]");
            if (return_type != .none) {
                try self.writer.writeAll(",\"returnType\":");
                try self.writeNode(return_type);
            }
            try self.writer.writeAll(",\"kind\":\"");
            try self.writer.writeAll(kind);
            try self.writer.writeAll("\"}");
        }

        fn writeTsIndexSignature(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            try self.writer.writeAll("{\"type\":\"TSIndexSignature\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"parameters\":[");
            // Write parameter (Identifier with typeAnnotation stored in side table)
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx]));
            try self.writer.writeAll("],\"typeAnnotation\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 2]));
            // Emit modifier flags from class modifiers side table
            try self.writeTsClassModifiers(idx);
            try self.writer.writeAll("}");
        }

        fn writeTsSignatureDeclaration(self: *Self, idx: NodeIndex, data: Node.Data, type_name: []const u8) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const return_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (type_params != .none) {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(type_params);
            }
            try self.writer.writeAll(",\"params\":[");
            try self.writeNodeRange(self.ast.extra_data.items[extra_idx + 1], self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll("]");
            if (return_type != .none) {
                try self.writer.writeAll(",\"returnType\":");
                try self.writeNode(return_type);
            }
            try self.writer.writeAll("}");
        }

        fn writeTsEnumDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            try self.writer.writeAll("{\"type\":\"TSEnumDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx]));
            const is_const = self.ast.extra_data.items[extra_idx + 3] != 0;
            if (is_const) try self.writer.writeAll(",\"const\":true") else try self.writer.writeAll(",\"const\":false");
            // TSEnumBody: use lbrace/rbrace tokens for position
            const lbrace_raw = self.ast.extra_data.items[extra_idx + 4];
            const rbrace_raw = self.ast.extra_data.items[extra_idx + 5];
            const body_start = self.ast.tokens.items(.start)[lbrace_raw];
            const body_end = self.ast.tokens.items(.end)[rbrace_raw];
            try self.writer.writeAll(",\"body\":{\"type\":\"TSEnumBody\",");
            try self.writePosition(body_start, body_end);
            try self.writer.writeAll(",\"members\":[");
            try self.writeNodeRange(self.ast.extra_data.items[extra_idx + 1], self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll("]}");
            // Always emit declare field for TypeScript
            if (self.isDeclareNode(idx))
                try self.writer.writeAll(",\"declare\":true")
            else if (self.ast.language.isTypeScript())
                try self.writer.writeAll(",\"declare\":false");
            try self.writer.writeAll("}");
        }

        fn writeTsEnumMember(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSEnumMember\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeTokenAsIdentOrString(main_token);
            try self.writer.writeAll(",\"computed\":false");
            try self.writer.writeAll(",\"initializer\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsModuleDeclaration(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const kind_code = if (extra_idx + 2 < self.ast.extra_data.items.len) self.ast.extra_data.items[extra_idx + 2] else 0;
            const kind = switch (kind_code) {
                1 => "namespace",
                2 => "global",
                else => "module",
            };
            try self.writer.writeAll("{\"type\":\"TSModuleDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"kind\":\"");
            try self.writer.writeAll(kind);
            try self.writer.writeAll("\"");
            try self.writer.writeAll(",\"id\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx]));
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 1]));
            _ = main_token;
            if (self.estree) {
                try self.writer.writeAll(if (kind_code == 2) ",\"global\":true" else ",\"global\":false");
            } else {
                if (kind_code == 2) try self.writer.writeAll(",\"global\":true");
            }
            if (self.isDeclareNode(idx)) try self.writer.writeAll(",\"declare\":true");
            try self.writer.writeAll("}");
        }

        fn writeTsModuleBlock(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            try self.writer.writeAll("{\"type\":\"TSModuleBlock\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"body\":[");
            try self.writeNodeRange(self.ast.extra_data.items[extra_idx], self.ast.extra_data.items[extra_idx + 1]);
            try self.writer.writeAll("]}");
        }

        fn writeTsDeclareFunction(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const return_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 4]);
            const body: NodeIndex = if (extra_idx + 5 < self.ast.extra_data.items.len) @enumFromInt(self.ast.extra_data.items[extra_idx + 5]) else .none;
            try self.writer.writeAll("{\"type\":\"TSDeclareFunction\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx]));
            // "declare" is true when the main_token is the `declare` keyword identifier
            // (set by parseTsDeclareStatement), false for function overloads.
            const main_token = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            const mt_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
            const is_declare = mt_tag == .identifier and std.mem.eql(u8, self.ast.tokenSlice(main_token), "declare");
            try self.writer.writeAll(",\"generator\":false,\"async\":false");
            if (is_declare) {
                try self.writer.writeAll(",\"declare\":true");
            }
            if (type_params != .none) {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(type_params);
            }
            try self.writer.writeAll(",\"params\":[");
            try self.writeNodeRange(self.ast.extra_data.items[extra_idx + 2], self.ast.extra_data.items[extra_idx + 3]);
            try self.writer.writeAll("]");
            if (return_type != .none) {
                try self.writer.writeAll(",\"returnType\":");
                try self.writeNode(return_type);
            }
            if (body != .none) {
                try self.writer.writeAll(",\"body\":");
                try self.writeNode(body);
            }
            try self.writer.writeAll("}");
        }

        fn writeTsDeclareVariable(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
            // main_token may be 'declare' identifier (when overridden by parseTsDeclare),
            // so check the next token for the actual var/let/const keyword.
            const kind_tag = if (tok_tag == .identifier)
                self.ast.tokens.items(.tag)[@intFromEnum(main_token) + 1]
            else
                tok_tag;
            const kind_str = switch (kind_tag) {
                .kw_var => "var",
                .kw_let => "let",
                .kw_const => "const",
                else => "var",
            };
            try self.writer.writeAll("{\"type\":\"VariableDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"declarations\":[");
            try self.writeNodeRange(self.ast.extra_data.items[extra_idx], self.ast.extra_data.items[extra_idx + 1]);
            try self.writer.writeAll("],\"kind\":\"");
            try self.writer.writeAll(kind_str);
            try self.writer.writeAll("\",\"declare\":true}");
        }

        fn writeTsDeclareMethod(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const params_start = self.ast.extra_data.items[extra_idx + 1];
            const params_end = self.ast.extra_data.items[extra_idx + 2];
            const flags = if (extra_idx + 4 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 4]
            else
                0;
            const is_static = (flags & 1) != 0;
            const is_computed = (flags & 2) != 0;
            const is_generator = (flags & 4) != 0;
            const is_async = (flags & 8) != 0;
            const is_optional = (flags & 16) != 0;
            const key_name = self.getNodeName(key);
            const kind = if (!is_static and !is_computed and !is_async and !is_generator and std.mem.eql(u8, key_name, "constructor")) "constructor" else "method";

            // Check if abstract via modifiers
            const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
            const is_abstract = (mods & TS_MOD_ABSTRACT) != 0;
            const is_private_name = self.ast.nodes.items(.tag)[@intFromEnum(key)] == .identifier and blk: {
                // Check if the key is preceded by a # in the source
                const key_start = self.nodeStart(key);
                break :blk key_start > 0 and self.ast.source[key_start - 1] == '#';
            };

            if (self.estree) {
                // ESTree: abstract -> TSAbstractMethodDefinition, others -> MethodDefinition
                if (is_abstract) {
                    try self.writer.writeAll("{\"type\":\"TSAbstractMethodDefinition\",");
                } else {
                    try self.writer.writeAll("{\"type\":\"MethodDefinition\",");
                }
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writer.writeAll(",\"static\":");
                try self.writer.writeAll(if (is_static) "true" else "false");
                try self.writer.writeAll(",\"key\":");
                if (is_private_name) {
                    try self.writePrivateName(key);
                } else {
                    try self.writeNode(key);
                }
                try self.writer.writeAll(",\"computed\":");
                try self.writer.writeAll(if (is_computed) "true" else "false");
                try self.writer.writeAll(",\"kind\":\"");
                try self.writer.writeAll(kind);
                // ESTree wraps in TSEmptyBodyFunctionExpression as "value"
                try self.writer.writeAll("\",\"value\":");
                const key_end = self.nodeEnd(key);
                const method_end = self.nodeEnd(idx);
                try self.writer.writeAll("{\"type\":\"TSEmptyBodyFunctionExpression\",");
                try self.writePosition(key_end, method_end);
                try self.writer.writeAll(",\"id\":null,\"generator\":");
                try self.writer.writeAll(if (is_generator) "true" else "false");
                try self.writer.writeAll(",\"async\":");
                try self.writer.writeAll(if (is_async) "true" else "false");
                try self.writer.writeAll(",\"expression\":false,\"params\":[");
                if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                    const params = self.ast.extra_data.items[params_start..params_end];
                    for (params, 0..) |p, j| {
                        if (j > 0) try self.writer.writeAll(",");
                        try self.writeNode(@enumFromInt(p));
                    }
                }
                try self.writer.writeAll("]");
                try self.writeOptionalReturnTypeAndTypeParams(idx);
                try self.writer.writeAll(",\"body\":null,\"declare\":false}");
                // MethodDefinition fields
                if (mods & TS_MOD_DECLARE != 0)
                    try self.writer.writeAll(",\"declare\":true");
                try self.writer.writeAll(",\"override\":");
                try self.writer.writeAll(if (mods & TS_MOD_OVERRIDE != 0) "true" else "false");
                try self.writer.writeAll(",\"optional\":");
                try self.writer.writeAll(if (is_optional) "true" else "false");
                try self.writeDecorators(idx);
                try self.writer.writeAll("}");
                return;
            }

            try self.writer.writeAll("{\"type\":\"TSDeclareMethod\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writeTsClassModifiers(idx);
            try self.writer.writeAll(",\"static\":");
            try self.writer.writeAll(if (is_static) "true" else "false");
            // Detect private: check if token before key is #
            const key_main = self.ast.nodes.items(.main_token)[@intFromEnum(key)];
            const key_idx = @intFromEnum(key_main);
            const is_private_key = key_idx > 0 and self.ast.tokens.items(.tag)[key_idx - 1] == .hash;
            try self.writer.writeAll(",\"key\":");
            if (is_private_key) {
                try self.writePrivateName(key);
            } else {
                try self.writeNode(key);
            }
            try self.writer.writeAll(",\"computed\":");
            try self.writer.writeAll(if (is_computed) "true" else "false");
            if (is_optional) {
                try self.writer.writeAll(",\"optional\":true");
            }
            try self.writer.writeAll(",\"kind\":\"");
            try self.writer.writeAll(kind);
            try self.writer.writeAll("\",\"id\":null,\"generator\":");
            try self.writer.writeAll(if (is_generator) "true" else "false");
            try self.writer.writeAll(",\"async\":");
            try self.writer.writeAll(if (is_async) "true" else "false");
            try self.writer.writeAll(",\"params\":[");
            if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                const params = self.ast.extra_data.items[params_start..params_end];
                for (params, 0..) |p, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(p));
                }
            }
            try self.writer.writeAll("]");
            try self.writeOptionalReturnTypeAndTypeParams(idx);
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        fn writeTsParameterProperty(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const param: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const param_flags = if (extra_idx + 1 < self.ast.extra_data.items.len) self.ast.extra_data.items[extra_idx + 1] else 0;
            try self.writer.writeAll("{\"type\":\"TSParameterProperty\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"parameter\":");
            try self.writeNode(param);
            // Accessibility
            if ((param_flags & (1 << 4)) != 0) try self.writer.writeAll(",\"accessibility\":\"public\"") else if ((param_flags & (1 << 5)) != 0) try self.writer.writeAll(",\"accessibility\":\"private\"") else if ((param_flags & (1 << 6)) != 0) try self.writer.writeAll(",\"accessibility\":\"protected\"");
            try self.writer.writeAll(",\"readonly\":");
            try self.writer.writeAll(if ((param_flags & (1 << 7)) != 0) "true" else "false");
            if ((param_flags & (1 << 8)) != 0) try self.writer.writeAll(",\"override\":true");
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        fn writeTsImportEqualsDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            try self.writer.writeAll("{\"type\":\"TSImportEqualsDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            // extra format: id_token, module_reference, is_type_flag
            const is_type = self.ast.extra_data.items[extra_idx + 2] != 0;
            try self.writer.writeAll(",\"importKind\":");
            if (is_type)
                try self.writer.writeAll("\"type\"")
            else
                try self.writer.writeAll("\"value\"");
            try self.writer.writeAll(",\"id\":");
            try self.writeTokenAsIdent(@enumFromInt(self.ast.extra_data.items[extra_idx]));
            try self.writer.writeAll(",\"moduleReference\":");
            try self.writeNode(@enumFromInt(self.ast.extra_data.items[extra_idx + 1]));
            try self.writer.writeAll("}");
        }

        fn writeTsExportAssignment(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSExportAssignment\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTsNamespaceExportDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSNamespaceExportDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeTokenAsIdent(data.token);
            try self.writer.writeAll("}");
        }

        fn writeTsExternalModuleReference(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TSExternalModuleReference\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeBlockStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"BlockStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));

            // Extract the range of child nodes
            const extra_idx = @intFromEnum(data.extra);
            const tags = self.ast.nodes.items(.tag);
            const datas = self.ast.nodes.items(.data);
            if (extra_idx < self.ast.extra_data.items.len) {
                const range_start = self.ast.extra_data.items[extra_idx];
                const range_end = self.ast.extra_data.items[extra_idx + 1];
                if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                    const items = self.ast.extra_data.items[range_start..range_end];

                    if (self.estree) {
                        // ESTree: directives stay in body as ExpressionStatement
                        try self.writer.writeAll(",\"body\":[");
                        var first = true;
                        for (items) |item| {
                            if (!first) try self.writer.writeAll(",");
                            first = false;
                            if (tags[item] == .directive) {
                                try self.writeDirectiveAsEstreeExprStmt(@enumFromInt(item));
                            } else if (tags[item] == .expression_statement) {
                                const expr_idx = datas[item].unary;
                                if (tags[@intFromEnum(expr_idx)] == .string_literal) {
                                    try self.writeStringExprStmtAsEstreeDirective(@enumFromInt(item));
                                } else {
                                    try self.writeNode(@enumFromInt(item));
                                }
                            } else {
                                try self.writeNode(@enumFromInt(item));
                            }
                        }
                        try self.writer.writeAll("]}");
                        return;
                    }

                    // Count leading directives: expression statements whose expression
                    // is a string literal (Babel moves these to "directives" in function bodies)
                    var directive_count: usize = 0;
                    for (items) |item| {
                        if (tags[item] == .expression_statement) {
                            const expr_idx = datas[item].unary;
                            if (tags[@intFromEnum(expr_idx)] == .string_literal) {
                                directive_count += 1;
                                continue;
                            }
                        }
                        // Also handle already-converted directive nodes
                        if (tags[item] == .directive) {
                            directive_count += 1;
                            continue;
                        }
                        break;
                    }

                    // Write body (non-directive items)
                    try self.writer.writeAll(",\"body\":[");
                    var first = true;
                    for (items[directive_count..]) |item| {
                        if (!first) try self.writer.writeAll(",");
                        first = false;
                        try self.writeNode(@enumFromInt(item));
                    }
                    try self.writer.writeAll("],\"directives\":[");

                    // Write directives
                    first = true;
                    for (items[0..directive_count]) |item| {
                        if (!first) try self.writer.writeAll(",");
                        first = false;
                        if (tags[item] == .directive) {
                            try self.writeNode(@enumFromInt(item));
                        } else {
                            // Convert expression_statement + string_literal to Directive format
                            const expr_idx = datas[item].unary;
                            const main_tok = self.ast.nodes.items(.main_token)[@intFromEnum(expr_idx)];
                            try self.writer.writeAll("{\"type\":\"Directive\",");
                            try self.writePosition(self.nodeStart(@enumFromInt(item)), self.nodeEnd(@enumFromInt(item)));
                            try self.writer.writeAll(",\"value\":");
                            try self.writeDirectiveLiteralFromStringToken(main_tok, @enumFromInt(item));
                            try self.writer.writeAll("}");
                        }
                    }
                    try self.writer.writeAll("]}");
                    return;
                }
            }

            // Fallback: no items
            if (self.estree) {
                try self.writer.writeAll(",\"body\":[]}");
            } else {
                try self.writer.writeAll(",\"body\":[],\"directives\":[]}");
            }
        }

        fn writeIfStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const condition: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const consequent: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const alternate: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll("{\"type\":\"IfStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"test\":");
            try self.writeNode(condition);
            try self.writer.writeAll(",\"consequent\":");
            try self.writeNode(consequent);
            try self.writer.writeAll(",\"alternate\":");
            try self.writeNode(alternate);
            try self.writer.writeAll("}");
        }

        fn writeForStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const init: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const test_expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const update: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
            try self.writer.writeAll("{\"type\":\"ForStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"init\":");
            try self.writeNode(init);
            try self.writer.writeAll(",\"test\":");
            try self.writeNode(test_expr);
            try self.writer.writeAll(",\"update\":");
            try self.writeNode(update);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll("}");
        }

        fn writeForInStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const left: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const right: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll("{\"type\":\"ForInStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"left\":");
            try self.writeNode(left);
            try self.writer.writeAll(",\"right\":");
            try self.writeNode(right);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll(",\"each\":false}");
        }

        fn writeForOfStatement(self: *Self, idx: NodeIndex, tag: Node.Tag, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const left: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const right: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll("{\"type\":\"ForOfStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            const is_await = tag == .for_of_await_statement;
            try self.writer.writeAll(if (is_await) ",\"await\":true,\"left\":" else ",\"await\":false,\"left\":");
            try self.writeNode(left);
            try self.writer.writeAll(",\"right\":");
            try self.writeNode(right);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll("}");
        }

        fn writeWhileStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"WhileStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"test\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeDoWhileStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"DoWhileStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"test\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeSwitchStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const discriminant: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const cases_start = self.ast.extra_data.items[extra_idx + 1];
            const cases_end = self.ast.extra_data.items[extra_idx + 2];
            try self.writer.writeAll("{\"type\":\"SwitchStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"discriminant\":");
            try self.writeNode(discriminant);
            try self.writer.writeAll(",\"cases\":[");
            if (cases_start <= cases_end and cases_end <= self.ast.extra_data.items.len) {
                const cases = self.ast.extra_data.items[cases_start..cases_end];
                for (cases, 0..) |c, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(c));
                }
            }
            try self.writer.writeAll("]}");
        }

        fn writeSwitchCase(self: *Self, idx: NodeIndex, tag: Node.Tag, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const test_expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const stmts_start = self.ast.extra_data.items[extra_idx + 1];
            const stmts_end = self.ast.extra_data.items[extra_idx + 2];
            try self.writer.writeAll("{\"type\":\"SwitchCase\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"test\":");
            if (tag == .switch_default) {
                try self.writer.writeAll("null");
            } else {
                try self.writeNode(test_expr);
            }
            try self.writer.writeAll(",\"consequent\":[");
            if (stmts_start <= stmts_end and stmts_end <= self.ast.extra_data.items.len) {
                const stmts = self.ast.extra_data.items[stmts_start..stmts_end];
                for (stmts, 0..) |s, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(s));
                }
            }
            try self.writer.writeAll("]}");
        }

        fn writeReturnStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ReturnStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"argument\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeThrowStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ThrowStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"argument\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeTryStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const block: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const handler: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const finalizer: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll("{\"type\":\"TryStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"block\":");
            try self.writeNode(block);
            try self.writer.writeAll(",\"handler\":");
            try self.writeNode(handler);
            try self.writer.writeAll(",\"finalizer\":");
            try self.writeNode(finalizer);
            try self.writer.writeAll("}");
        }

        fn writeCatchClause(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"CatchClause\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"param\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        fn writeBreakContinue(self: *Self, idx: NodeIndex, type_name: []const u8, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"label\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeLabeledStatement(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"LabeledStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"label\":");
            // Placeholder as label
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_label| {
                try self.writeNode(ph_label);
            } else {
                // Write label as identifier
                const label_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                const label_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
                const label_name = self.ast.source[label_start..label_end];
                try self.writer.writeAll("{\"type\":\"Identifier\",");
                try self.writePositionWithIdentName(label_start, label_end, label_name);
                try self.writer.writeAll(",\"name\":\"");
                try self.writer.writeAll(label_name);
                try self.writer.writeAll("\"}");
            }
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeWithStatement(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"WithStatement\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"object\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        // === Declarations ===

        fn writeVariableDeclaration(self: *Self, idx: NodeIndex, tag: Node.Tag, data: Node.Data) anyerror!void {
            const kind = switch (tag) {
                .var_declaration => "var",
                .let_declaration => "let",
                .const_declaration => "const",
                .using_declaration => "using",
                .await_using_declaration => "await using",
                else => unreachable,
            };
            try self.writer.writeAll("{\"type\":\"VariableDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"declarations\":[");
            // Always uses extra range format
            try self.writeExtraRange(data);
            try self.writer.writeAll("],\"kind\":\"");
            try self.writer.writeAll(kind);
            try self.writer.writeAll("\"");
            // TypeScript: declare field
            if (self.ast.language.isTypeScript()) {
                if (self.isDeclareNode(idx))
                    try self.writer.writeAll(",\"declare\":true")
                else
                    try self.writer.writeAll(",\"declare\":false");
            }
            try self.writer.writeAll("}");
        }

        fn writeDeclarator(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"VariableDeclarator\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"init\":");
            try self.writeNode(data.binary.rhs);
            // TypeScript: definite field (x!: type)
            if (self.ast.language.isTypeScript()) {
                const is_definite = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) != null;
                try self.writer.writeAll(",\"definite\":");
                try self.writer.writeAll(if (is_definite) "true" else "false");
            }
            try self.writer.writeAll("}");
        }

        fn writeFunctionDeclaration(self: *Self, idx: NodeIndex, tag: Node.Tag, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"FunctionDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const params_start = self.ast.extra_data.items[extra_idx + 1];
            const params_end = self.ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
            try self.writer.writeAll(",\"id\":");
            // Placeholder as function name
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_name| {
                try self.writeNode(ph_name);
            } else {
                try self.writeOptionalTokenAsIdent(name_token_raw);
            }
            try self.writer.writeAll(",\"generator\":");
            try self.writer.writeAll(if (tag == .generator_declaration or tag == .async_generator_declaration) "true" else "false");
            try self.writer.writeAll(",\"async\":");
            try self.writer.writeAll(if (tag == .async_function_declaration or tag == .async_generator_declaration) "true" else "false");
            try self.writer.writeAll(",\"params\":[");
            if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                const params = self.ast.extra_data.items[params_start..params_end];
                for (params, 0..) |p, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(p));
                }
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            // Flow: predicate (must come before returnType for correct field ordering)
            try self.writeFlowPredicateForNode(idx);
            // Flow: return type
            if (self.ast.return_types.get(@intFromEnum(idx))) |ret_type| {
                try self.writer.writeAll(",\"returnType\":");
                try self.writeNode(ret_type);
            } else if (self.ast.predicate_map.get(@intFromEnum(idx)) != null) {
                // When there's a predicate but no return type, emit null
                try self.writer.writeAll(",\"returnType\":null");
            }
            // Flow: type parameters
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(tp);
            }
            try self.writer.writeAll(",\"expression\":false}");
        }

        // === Class ===

        fn writeClassDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ClassDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            try self.writer.writeAll(",\"id\":");
            // Placeholder as class name
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_name| {
                try self.writeNode(ph_name);
            } else {
                try self.writeOptionalTokenAsIdent(name_token_raw);
            }
            // Flow: type parameters
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(tp);
            }
            try self.writer.writeAll(",\"superClass\":");
            try self.writeNode(super_class);
            try self.writeClassTypeExtras(idx);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(body);
            try self.writeTsClassModifiers(idx);
            // TypeScript: ensure abstract, declare, implements are always present
            if (self.ast.language.isTypeScript()) {
                const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
                if (mods & TS_MOD_ABSTRACT == 0)
                    try self.writer.writeAll(",\"abstract\":false");
                if (mods & TS_MOD_DECLARE == 0)
                    try self.writer.writeAll(",\"declare\":false");
                // implements: [] when not present
                if (!self.ast.implements_list.contains(@intFromEnum(idx)))
                    try self.writer.writeAll(",\"implements\":[]");
            }
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        fn writeDecorators(self: *Self, idx: NodeIndex) anyerror!void {
            if (self.ast.decorators_map.get(@intFromEnum(idx))) |dec_range| {
                try self.writer.writeAll(",\"decorators\":[");
                var first = true;
                for (self.ast.extra_data.items[dec_range.start..dec_range.end]) |dec_raw| {
                    if (!first) try self.writer.writeAll(",");
                    first = false;
                    try self.writeNode(@enumFromInt(dec_raw));
                }
                try self.writer.writeAll("]");
            } else {
                try self.writer.writeAll(",\"decorators\":[]");
            }
        }

        fn writeClassBody(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ClassBody\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"body\":[");
            try self.writeExtraRange(data);
            try self.writer.writeAll("]}");
        }

        fn writeClassProperty(self: *Self, idx: NodeIndex, tag: Node.Tag, data: Node.Data) anyerror!void {
            // extra_data: [key, value, flags]
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const value: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const flags = if (extra_idx + 2 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 2]
            else
                0;
            const is_static = (flags & 1) != 0;
            const is_computed = (flags & 2) != 0;
            const is_optional = (flags & 16) != 0;
            const is_definite = (flags & 32) != 0;
            const is_accessor = (flags & 64) != 0;
            const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
            const is_abstract = (mods & TS_MOD_ABSTRACT) != 0;
            if (self.estree) {
                // ESTree: abstract -> TSAbstractPropertyDefinition, otherwise PropertyDefinition
                if (is_abstract) {
                    try self.writer.writeAll("{\"type\":\"TSAbstractPropertyDefinition\",");
                } else if (is_accessor) {
                    try self.writer.writeAll("{\"type\":\"AccessorProperty\",");
                } else {
                    try self.writer.writeAll("{\"type\":\"PropertyDefinition\",");
                }
            } else if (is_accessor) {
                try self.writer.writeAll("{\"type\":\"ClassAccessorProperty\",");
            } else if (tag == .class_private_field) {
                try self.writer.writeAll("{\"type\":\"ClassPrivateProperty\",");
            } else {
                try self.writer.writeAll("{\"type\":\"ClassProperty\",");
            }
            const is_declare = (flags & 16) != 0;
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (self.ast.language == .flow and is_declare) {
                try self.writer.writeAll(",\"declare\":true");
            }
            try self.writer.writeAll(",\"key\":");
            if (tag == .class_private_field) {
                try self.writePrivateName(key);
            } else {
                try self.writeNode(key);
            }
            try self.writer.writeAll(",\"static\":");
            try self.writer.writeAll(if (is_static) "true" else "false");
            try self.writer.writeAll(",\"computed\":");
            try self.writer.writeAll(if (is_computed) "true" else "false");
            if (self.ast.language == .flow) {
                if (self.ast.variance_map.get(@intFromEnum(idx))) |var_node| {
                    try self.writer.writeAll(",\"variance\":");
                    try self.writeNode(var_node);
                } else {
                    try self.writer.writeAll(",\"variance\":null");
                }
            }
            try self.writer.writeAll(",\"value\":");
            try self.writeNode(value);
            try self.writeFlowTypeAnnotationForNode(idx);
            try self.writeTsClassModifiers(idx);
            if (self.ast.language.isTypeScript()) {
                // Ensure all TS class property fields are present
                if (mods & TS_MOD_DECLARE == 0) try self.writer.writeAll(",\"declare\":false");
                try self.writer.writeAll(",\"definite\":");
                try self.writer.writeAll(if (is_definite) "true" else "false");
                if (mods & TS_MOD_READONLY == 0) try self.writer.writeAll(",\"readonly\":false");
                if (mods & TS_MOD_OVERRIDE == 0) try self.writer.writeAll(",\"override\":false");
                try self.writer.writeAll(",\"optional\":");
                try self.writer.writeAll(if (is_optional) "true" else "false");
            }
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        fn writeStaticBlock(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"StaticBlock\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"body\":[");
            // data.unary is the block statement; we need its body
            const block_idx = @intFromEnum(data.unary);
            const block_data = self.ast.nodes.items(.data)[block_idx];
            try self.writeExtraRange(block_data);
            try self.writer.writeAll("]");
            try self.writeTsClassModifiers(idx);
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        fn writeClassMethod(self: *Self, idx: NodeIndex, tag: Node.Tag, main_token: TokenIndex, data: Node.Data) anyerror!void {
            _ = main_token;
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
            const is_declare = (flags & 16) != 0;
            const is_optional = (flags & 16) != 0;

            // Determine kind based on key name — only non-static, non-async, non-generator,
            // non-private, non-computed "constructor" is a constructor
            const key_name = self.getNodeName(key);
            const kind = if (tag != .class_private_method and !is_static and !is_computed and !is_async and !is_generator and std.mem.eql(u8, key_name, "constructor")) "constructor" else "method";

            if (self.estree) {
                // ESTree: ClassMethod/ClassPrivateMethod -> MethodDefinition
                try self.writer.writeAll("{\"type\":\"MethodDefinition\",");
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writer.writeAll(",\"static\":");
                try self.writer.writeAll(if (is_static) "true" else "false");
                try self.writer.writeAll(",\"key\":");
                if (tag == .class_private_method) {
                    try self.writePrivateName(key);
                } else {
                    try self.writeNode(key);
                }
                try self.writer.writeAll(",\"computed\":");
                try self.writer.writeAll(if (is_computed) "true" else "false");
                try self.writer.writeAll(",\"kind\":\"");
                try self.writer.writeAll(kind);
                // ESTree wraps method body+params in FunctionExpression as "value"
                try self.writer.writeAll("\",\"value\":");
                // Compute the FunctionExpression start position (after the key)
                const key_end = self.nodeEnd(key);
                const body_end = self.nodeEnd(idx);
                try self.writer.writeAll("{\"type\":\"FunctionExpression\",");
                try self.writePosition(key_end, body_end);
                try self.writer.writeAll(",\"id\":null,\"generator\":");
                try self.writer.writeAll(if (is_generator) "true" else "false");
                try self.writer.writeAll(",\"async\":");
                try self.writer.writeAll(if (is_async) "true" else "false");
                try self.writer.writeAll(",\"expression\":false,\"params\":[");
                if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                    const params = self.ast.extra_data.items[params_start..params_end];
                    for (params, 0..) |p, j| {
                        if (j > 0) try self.writer.writeAll(",");
                        try self.writeNode(@enumFromInt(p));
                    }
                }
                try self.writer.writeAll("],\"body\":");
                try self.writeNode(body);
                try self.writer.writeAll("}");
                // ESTree MethodDefinition: override, optional, decorators
                if (self.ast.language.isTypeScript()) {
                    const mods = self.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
                    try self.writer.writeAll(",\"override\":");
                    try self.writer.writeAll(if (mods & TS_MOD_OVERRIDE != 0) "true" else "false");
                    try self.writer.writeAll(",\"optional\":");
                    try self.writer.writeAll(if (is_optional) "true" else "false");
                }
                try self.writeDecorators(idx);
                try self.writer.writeAll("}");
                return;
            }

            if (tag == .class_private_method) {
                try self.writer.writeAll("{\"type\":\"ClassPrivateMethod\",");
            } else {
                try self.writer.writeAll("{\"type\":\"ClassMethod\",");
            }
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (self.ast.language == .flow and is_declare) {
                try self.writer.writeAll(",\"declare\":true");
            }
            try self.writer.writeAll(",\"static\":");
            try self.writer.writeAll(if (is_static) "true" else "false");
            try self.writer.writeAll(",\"key\":");
            if (tag == .class_private_method) {
                try self.writePrivateName(key);
            } else {
                try self.writeNode(key);
            }
            try self.writer.writeAll(",\"computed\":");
            try self.writer.writeAll(if (is_computed) "true" else "false");
            try self.writer.writeAll(",\"kind\":\"");
            try self.writer.writeAll(kind);
            try self.writer.writeAll("\",\"id\":null,\"generator\":");
            try self.writer.writeAll(if (is_generator) "true" else "false");
            try self.writer.writeAll(",\"async\":");
            try self.writer.writeAll(if (is_async) "true" else "false");
            try self.writer.writeAll(",\"params\":[");
            if (params_start <= params_end and params_end <= self.ast.extra_data.items.len) {
                const params = self.ast.extra_data.items[params_start..params_end];
                for (params, 0..) |p, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(p));
                }
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            try self.writeOptionalReturnTypeAndTypeParams(idx);
            try self.writeTsClassModifiers(idx);
            if (self.ast.language.isTypeScript() and is_optional) {
                try self.writer.writeAll(",\"optional\":true");
            }
            try self.writer.writeAll(",\"expression\":false");
            try self.writeDecorators(idx);
            try self.writer.writeAll("}");
        }

        // === Module ===

        fn writeImportDeclaration(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data, tag: Node.Tag) anyerror!void {
            _ = main_token;
            try self.writer.writeAll("{\"type\":\"ImportDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"specifiers\":[");

            // Always uses extra format: source_token, specs_start, specs_end
            const extra_idx = @intFromEnum(data.extra);
            const source_token_raw = self.ast.extra_data.items[extra_idx];
            const specs_start = self.ast.extra_data.items[extra_idx + 1];
            const specs_end = self.ast.extra_data.items[extra_idx + 2];

            if (specs_start <= specs_end and specs_end <= self.ast.extra_data.items.len) {
                const specs = self.ast.extra_data.items[specs_start..specs_end];
                for (specs, 0..) |s, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(s));
                }
            }

            try self.writer.writeAll("],\"source\":");
            // Placeholder as source: `import %%FILE%%` or `import x from %%FILE%%`
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_source| {
                try self.writeNode(ph_source);
            } else {
                try self.writeStringLiteralFromToken(@enumFromInt(source_token_raw));
            }
            // importKind for Flow import type/typeof forms; "value" otherwise
            // Check for import phase (source/defer)
            const phase_val = self.ast.ts_class_modifiers.get(@intFromEnum(idx));
            if (phase_val) |pv| {
                if (pv == 0x100) {
                    try self.writer.writeAll(",\"phase\":\"source\"");
                } else if (pv == 0x200) {
                    try self.writer.writeAll(",\"phase\":\"defer\"");
                }
                // Phase imports: emit attributes from extra data
                const has_attrs_ph = extra_idx + 4 < self.ast.extra_data.items.len;
                if (has_attrs_ph) {
                    const aps = self.ast.extra_data.items[extra_idx + 3];
                    const ape = self.ast.extra_data.items[extra_idx + 4];
                    try self.writer.writeAll(",\"attributes\":[");
                    try self.writeNodeRange(aps, ape);
                    try self.writer.writeAll("]}");
                } else {
                    try self.writer.writeAll(",\"attributes\":[]}");
                }
            } else {
                // Emit "phase":null when the plugin is active but this import has no phase
                if (self.ast.has_import_phase) {
                    try self.writer.writeAll(",\"phase\":null");
                }
                if (tag == .import_declaration_type) {
                    try self.writer.writeAll(",\"importKind\":\"type\"");
                } else if (tag == .import_declaration_typeof) {
                    try self.writer.writeAll(",\"importKind\":\"typeof\"");
                } else {
                    try self.writer.writeAll(",\"importKind\":\"value\"");
                }
                // Import attributes from extra data
                const has_attrs = extra_idx + 4 < self.ast.extra_data.items.len;
                if (has_attrs) {
                    const attrs_start2 = self.ast.extra_data.items[extra_idx + 3];
                    const attrs_end2 = self.ast.extra_data.items[extra_idx + 4];
                    try self.writer.writeAll(",\"assertions\":[");
                    try self.writeNodeRange(attrs_start2, attrs_end2);
                    try self.writer.writeAll("],\"attributes\":[");
                    try self.writeNodeRange(attrs_start2, attrs_end2);
                    try self.writer.writeAll("]}");
                } else {
                    try self.writer.writeAll(",\"assertions\":[],\"attributes\":[]}");
                }
            }
        }

        fn writeImportSpecifier(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data, tag: Node.Tag) anyerror!void {
            _ = main_token;
            try self.writer.writeAll("{\"type\":\"ImportSpecifier\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            // Placeholder handling for import specifiers
            const imported_ph = self.ast.placeholder_name_nodes.get(@intFromEnum(idx));
            const local_ph = self.ast.variance_map.get(@intFromEnum(idx));
            if (imported_ph != null or local_ph != null) {
                try self.writer.writeAll(",\"imported\":");
                if (imported_ph) |ph| {
                    try self.writeNode(ph);
                } else {
                    const extra_idx = @intFromEnum(data.extra);
                    const imported_tok = self.ast.extra_data.items[extra_idx];
                    try self.writeTokenAsIdentOrString(@enumFromInt(imported_tok));
                }
                try self.writer.writeAll(",\"local\":");
                if (local_ph) |lph| {
                    try self.writeNode(lph);
                } else {
                    // Check if there's a regular local token stored
                    const extra_idx3 = @intFromEnum(data.extra);
                    const local_tok = self.ast.extra_data.items[extra_idx3 + 1];
                    if (local_tok != 0) {
                        try self.writeTokenAsIdentOrString(@enumFromInt(local_tok));
                    } else if (imported_ph) |ph| {
                        // No alias — placeholder is both imported and local
                        try self.writeNode(ph);
                    } else {
                        try self.writer.writeAll("null");
                    }
                }
            } else {
                // Always uses extra format: imported_token, local_token
                const extra_idx = @intFromEnum(data.extra);
                const imported_token_raw = self.ast.extra_data.items[extra_idx];
                const local_token_raw = self.ast.extra_data.items[extra_idx + 1];
                try self.writer.writeAll(",\"imported\":");
                try self.writeTokenAsIdentOrString(@enumFromInt(imported_token_raw));
                try self.writer.writeAll(",\"local\":");
                try self.writeTokenAsIdentOrString(@enumFromInt(local_token_raw));
            }
            // In Flow mode, specifier importKind is null unless individually typed.
            if (tag == .import_specifier_type) {
                try self.writer.writeAll(",\"importKind\":\"type\"}");
            } else if (tag == .import_specifier_typeof) {
                try self.writer.writeAll(",\"importKind\":\"typeof\"}");
            } else if (self.ast.language == .flow) {
                try self.writer.writeAll(",\"importKind\":null}");
            } else {
                try self.writer.writeAll(",\"importKind\":\"value\"}");
            }
        }

        fn writeImportDefaultSpecifier(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ImportDefaultSpecifier\",");
            // Placeholder as local: adjust position to span the placeholder
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_node| {
                try self.writePosition(self.nodeStart(ph_node), self.nodeEnd(ph_node));
                try self.writer.writeAll(",\"local\":");
                try self.writeNode(ph_node);
            } else {
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writer.writeAll(",\"local\":");
                try self.writeTokenAsIdent(main_token);
            }
            try self.writer.writeAll("}");
        }

        fn writeImportNamespaceSpecifier(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ImportNamespaceSpecifier\",");
            // Placeholder as local: use node position (includes * and as)
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_node| {
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(ph_node));
                try self.writer.writeAll(",\"local\":");
                try self.writeNode(ph_node);
            } else {
                try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
                try self.writer.writeAll(",\"local\":");
                try self.writeTokenAsIdent(main_token);
            }
            try self.writer.writeAll("}");
        }

        fn writeImportAttribute(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ImportAttribute\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"key\":");
            try self.writeNode(data.binary.lhs);
            try self.writer.writeAll(",\"value\":");
            try self.writeNode(data.binary.rhs);
            try self.writer.writeAll("}");
        }

        /// For ESTree mode: compute the export node's start position, skipping decorators.
        fn estreeExportStart(self: *Self, idx: NodeIndex) u32 {
            if (self.estree) {
                // Use the export keyword (main_token) position instead of node start
                // which may include preceding decorators
                const mt = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
                return self.ast.tokens.items(.start)[@intFromEnum(mt)];
            }
            return self.nodeStart(idx);
        }

        fn writeExportNamedDeclaration(self: *Self, idx: NodeIndex, data: Node.Data, tag: Node.Tag) anyerror!void {
            // Extra format: source_token, specs_start, specs_end, declaration, attrs_start, attrs_end
            const extra_idx = @intFromEnum(data.extra);
            const source_token_raw = self.ast.extra_data.items[extra_idx];
            const specs_start = self.ast.extra_data.items[extra_idx + 1];
            const specs_end = self.ast.extra_data.items[extra_idx + 2];

            // Read attrs range (indices 4 and 5)
            const attrs_start = if (extra_idx + 5 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 4]
            else
                0;
            const attrs_end = if (extra_idx + 5 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 5]
            else
                attrs_start;

            const export_kind = if (tag == .export_named_type) "\"type\"" else "\"value\"";

            // ESTree: `export * as ns from 'source'` becomes ExportAllDeclaration
            if (self.estree and specs_start < specs_end) {
                const specs = self.ast.extra_data.items[specs_start..specs_end];
                if (specs.len == 1) {
                    const spec_node: NodeIndex = @enumFromInt(specs[0]);
                    const spec_tag = self.ast.nodes.items(.tag)[@intFromEnum(spec_node)];
                    if (spec_tag == .export_namespace_specifier) {
                        try self.writer.writeAll("{\"type\":\"ExportAllDeclaration\",");
                        try self.writePosition(self.estreeExportStart(idx), self.nodeEnd(idx));
                        // exported: the name from the namespace specifier
                        const spec_data = self.ast.nodes.items(.data)[@intFromEnum(spec_node)];
                        const name_token_raw = @intFromEnum(spec_data.unary);
                        try self.writer.writeAll(",\"exported\":");
                        try self.writeTokenAsIdentOrString(@enumFromInt(name_token_raw));
                        try self.writer.writeAll(",\"source\":");
                        if (source_token_raw != 0) {
                            try self.writeStringLiteralFromToken(@enumFromInt(source_token_raw));
                        } else {
                            try self.writer.writeAll("null");
                        }
                        try self.writer.writeAll(",\"exportKind\":");
                        try self.writer.writeAll(export_kind);
                        try self.writeExportAttrs(attrs_start, attrs_end);
                        try self.writer.writeAll("}");
                        return;
                    }
                }
            }

            try self.writer.writeAll("{\"type\":\"ExportNamedDeclaration\",");
            try self.writePosition(self.estreeExportStart(idx), self.nodeEnd(idx));

            // Check if there's a declaration (4th extra element)
            const has_decl = extra_idx + 3 < self.ast.extra_data.items.len and
                self.ast.extra_data.items[extra_idx + 3] != @intFromEnum(NodeIndex.none);
            const decl_raw = if (extra_idx + 3 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 3]
            else
                @intFromEnum(NodeIndex.none);

            if (has_decl and decl_raw != @intFromEnum(NodeIndex.none)) {
                try self.writer.writeAll(",\"declaration\":");
                try self.writeNode(@enumFromInt(decl_raw));
                try self.writer.writeAll(",\"specifiers\":[],\"source\":null,\"exportKind\":");
                try self.writer.writeAll(export_kind);
                try self.writeExportAttrs(attrs_start, attrs_end);
                try self.writer.writeAll("}");
            } else {
                try self.writer.writeAll(",\"declaration\":null,\"specifiers\":[");
                if (specs_start <= specs_end and specs_end <= self.ast.extra_data.items.len) {
                    const specs = self.ast.extra_data.items[specs_start..specs_end];
                    for (specs, 0..) |s, j| {
                        if (j > 0) try self.writer.writeAll(",");
                        try self.writeNode(@enumFromInt(s));
                    }
                }
                try self.writer.writeAll("],\"source\":");
                // Placeholder as source
                if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_source| {
                    try self.writeNode(ph_source);
                } else if (source_token_raw != 0) {
                    try self.writeStringLiteralFromToken(@enumFromInt(source_token_raw));
                } else {
                    try self.writer.writeAll("null");
                }
                try self.writer.writeAll(",\"exportKind\":");
                try self.writer.writeAll(export_kind);
                try self.writeExportAttrs(attrs_start, attrs_end);
                try self.writer.writeAll("}");
            }
        }

        fn writeModuleExpression(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ModuleExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            // Body is an inline Program node
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            const items = self.ast.extra_data.items[range_start..range_end];
            // The body Program spans from after '{' to before '}'
            // main_token is "module", the '{' is the next significant token
            const module_main = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            // Find the position of the '{' (token after module)
            const lbrace_tok_idx = @intFromEnum(module_main) + 1;
            const body_start = if (lbrace_tok_idx < self.ast.tokens.items(.start).len)
                self.ast.tokens.items(.start)[lbrace_tok_idx] + 1
            else
                self.nodeStart(idx);
            // Body end is before the '}' — use the node end minus 1
            const node_end = self.nodeEnd(idx);
            const body_end = if (node_end > 0) node_end - 1 else node_end;
            try self.writer.writeAll(",\"body\":{\"type\":\"Program\",");
            try self.writePosition(body_start, body_end);
            try self.writer.writeAll(",\"sourceType\":\"module\",\"interpreter\":null,\"body\":[");
            const tags = self.ast.nodes.items(.tag);
            // Separate directives from body
            var directive_count: usize = 0;
            for (items) |item| {
                if (tags[item] == .directive) {
                    directive_count += 1;
                } else {
                    break;
                }
            }
            var first = true;
            for (items[directive_count..]) |item| {
                if (!first) try self.writer.writeAll(",");
                first = false;
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("],\"directives\":[");
            first = true;
            for (items[0..directive_count]) |item| {
                if (!first) try self.writer.writeAll(",");
                first = false;
                try self.writeNode(@enumFromInt(item));
            }
            // Check for top-level await in the module body by scanning all nodes in range
            const has_tla = self.hasTopLevelAwaitInRange(body_start, node_end);
            if (has_tla) {
                try self.writer.writeAll("],\"extra\":{\"topLevelAwait\":true}}");
            } else {
                try self.writer.writeAll("],\"extra\":{\"topLevelAwait\":false}}");
            }
            try self.writer.writeAll("}");
        }

        fn writeExportDefault(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ExportDefaultDeclaration\",");
            try self.writePosition(self.estreeExportStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"declaration\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll(",\"exportKind\":\"value\"}");
        }

        fn writeExportAllDeclaration(self: *Self, idx: NodeIndex, data: Node.Data, tag: Node.Tag) anyerror!void {
            _ = tag;
            try self.writer.writeAll("{\"type\":\"ExportAllDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"source\":");
            // Extra format: source_token, attrs_start, attrs_end, is_type_export
            const extra_idx = @intFromEnum(data.extra);
            const source_token_raw = self.ast.extra_data.items[extra_idx];
            const ea_start = if (extra_idx + 2 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 1]
            else
                0;
            const ea_end = if (extra_idx + 2 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 2]
            else
                ea_start;
            const is_type_export = if (extra_idx + 3 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 3] != 0
            else
                false;
            // Placeholder as source
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_source| {
                try self.writeNode(ph_source);
            } else {
                try self.writeStringLiteralFromToken(@enumFromInt(source_token_raw));
            }
            if (is_type_export) {
                try self.writer.writeAll(",\"exported\":null,\"exportKind\":\"type\"");
            } else {
                try self.writer.writeAll(",\"exported\":null,\"exportKind\":\"value\"");
            }
            try self.writeExportAttrs(ea_start, ea_end);
            try self.writer.writeAll("}");
        }

        /// Helper: write ",\"assertions\":[...],\"attributes\":[...]" for export nodes
        fn writeExportAttrs(self: *Self, attrs_start: u32, attrs_end: u32) anyerror!void {
            if (attrs_start < attrs_end and attrs_end <= self.ast.extra_data.items.len) {
                const attrs = self.ast.extra_data.items[attrs_start..attrs_end];
                try self.writer.writeAll(",\"assertions\":[");
                for (attrs, 0..) |a, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(a));
                }
                try self.writer.writeAll("],\"attributes\":[");
                for (attrs, 0..) |a, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(a));
                }
                try self.writer.writeAll("]");
            } else {
                try self.writer.writeAll(",\"assertions\":[],\"attributes\":[]");
            }
        }

        fn writeExportSpecifier(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data, tag: Node.Tag) anyerror!void {
            _ = main_token;
            try self.writer.writeAll("{\"type\":\"ExportSpecifier\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            // Placeholder handling for export specifiers
            const local_ph = self.ast.placeholder_name_nodes.get(@intFromEnum(idx));
            const exported_ph = self.ast.variance_map.get(@intFromEnum(idx));
            if (local_ph != null or exported_ph != null) {
                try self.writer.writeAll(",\"local\":");
                if (local_ph) |ph| {
                    try self.writeNode(ph);
                } else {
                    const extra_idx = @intFromEnum(data.extra);
                    const local_tok = self.ast.extra_data.items[extra_idx];
                    try self.writeTokenAsIdentOrString(@enumFromInt(local_tok));
                }
                try self.writer.writeAll(",\"exported\":");
                if (exported_ph) |eph| {
                    try self.writeNode(eph);
                } else {
                    // Check if there's a regular exported token stored
                    const extra_idx2 = @intFromEnum(data.extra);
                    const exported_tok = self.ast.extra_data.items[extra_idx2 + 1];
                    if (exported_tok != 0) {
                        try self.writeTokenAsIdentOrString(@enumFromInt(exported_tok));
                    } else if (local_ph) |ph| {
                        // No alias — placeholder is both local and exported
                        try self.writeNode(ph);
                    } else {
                        try self.writer.writeAll("null");
                    }
                }
            } else {
                // Always uses extra format: local_token, exported_token
                const extra_idx = @intFromEnum(data.extra);
                const local_token_raw = self.ast.extra_data.items[extra_idx];
                const exported_token_raw = self.ast.extra_data.items[extra_idx + 1];
                try self.writer.writeAll(",\"local\":");
                try self.writeTokenAsIdentOrString(@enumFromInt(local_token_raw));
                try self.writer.writeAll(",\"exported\":");
                try self.writeTokenAsIdentOrString(@enumFromInt(exported_token_raw));
            }
            if (tag == .export_specifier_type) {
                try self.writer.writeAll(",\"exportKind\":\"type\"}");
            } else {
                try self.writer.writeAll(",\"exportKind\":\"value\"}");
            }
        }

        fn writeExportNamespaceSpecifier(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ExportNamespaceSpecifier\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"exported\":");
            // Placeholder as exported name
            if (self.ast.placeholder_name_nodes.get(@intFromEnum(idx))) |ph_name| {
                try self.writeNode(ph_name);
            } else {
                // data.unary stores the exported name token (as NodeIndex cast from TokenIndex)
                const name_token_raw = @intFromEnum(data.unary);
                try self.writeTokenAsIdentOrString(@enumFromInt(name_token_raw));
            }
            try self.writer.writeAll("}");
        }

        // === Position helpers ===

        /// Compute the index offset from startIndex/startColumn options.
        /// If startIndex is explicitly set (non-zero), use it; else use startColumn.
        fn indexOffset(self: *Self) u32 {
            if (self.ast.start_index != 0) return self.ast.start_index;
            return self.ast.start_column;
        }

        /// Compute the first-line column offset from startColumn/startIndex options.
        /// If startColumn is explicitly set (non-zero), use it; else use startIndex.
        fn columnOffset(self: *Self) u32 {
            if (self.ast.start_column != 0) return self.ast.start_column;
            return self.ast.start_index;
        }

        fn writePosition(self: *Self, start_offset: u32, end_offset: u32) anyerror!void {
            const idx_off = self.indexOffset();
            const cp_start = self.byteToCodePoint(start_offset) + idx_off;
            const cp_end = self.byteToCodePoint(end_offset) + idx_off;
            try self.writer.writeAll("\"start\":");
            try self.writeU32(cp_start);
            try self.writer.writeAll(",\"end\":");
            try self.writeU32(cp_end);
            try self.writer.writeAll(",\"loc\":{\"start\":");
            try self.writeLocPoint(start_offset, cp_start);
            try self.writer.writeAll(",\"end\":");
            try self.writeLocPoint(end_offset, cp_end);
            if (self.ast.source_filename) |filename| {
                try self.writer.writeAll(",\"filename\":\"");
                try self.writeJsonEscaped(filename);
                try self.writer.writeByte('"');
            }
            try self.writer.writeAll("}");
            if (self.ast.emit_ranges) {
                try self.writer.writeAll(",\"range\":[");
                try self.writeU32(cp_start);
                try self.writer.writeByte(',');
                try self.writeU32(cp_end);
                try self.writer.writeByte(']');
            }
        }

        fn writePositionWithIdentName(self: *Self, start_offset: u32, end_offset: u32, name: []const u8) anyerror!void {
            const idx_off = self.indexOffset();
            const cp_start = self.byteToCodePoint(start_offset) + idx_off;
            const cp_end = self.byteToCodePoint(end_offset) + idx_off;
            try self.writer.writeAll("\"start\":");
            try self.writeU32(cp_start);
            try self.writer.writeAll(",\"end\":");
            try self.writeU32(cp_end);
            try self.writer.writeAll(",\"loc\":{\"start\":");
            try self.writeLocPoint(start_offset, cp_start);
            try self.writer.writeAll(",\"end\":");
            try self.writeLocPoint(end_offset, cp_end);
            try self.writer.writeAll(",\"identifierName\":\"");
            try self.writeIdentName(name);
            try self.writer.writeByte('"');
            if (self.ast.source_filename) |filename| {
                try self.writer.writeAll(",\"filename\":\"");
                try self.writeJsonEscaped(filename);
                try self.writer.writeByte('"');
            }
            try self.writer.writeAll("}");
            if (self.ast.emit_ranges) {
                try self.writer.writeAll(",\"range\":[");
                try self.writeU32(cp_start);
                try self.writer.writeByte(',');
                try self.writeU32(cp_end);
                try self.writer.writeByte(']');
            }
        }

        fn writeLocPoint(self: *Self, byte_offset: u32, cp_offset: u32) anyerror!void {
            const pos = self.ast.resolvePosition(byte_offset);
            // Column should also be in code points, not bytes
            const line_start_byte: u32 = if (pos.line < self.ast.line_offsets.items.len)
                @intCast(self.ast.line_offsets.items[pos.line])
            else
                0;
            var cp_col = self.byteToCodePoint(byte_offset) - self.byteToCodePoint(line_start_byte);
            // Apply column offset on the first line only
            if (pos.line == 0) cp_col += self.columnOffset();
            // Apply line offset from startLine option
            const line_num = pos.line + self.ast.start_line;
            try self.writer.writeAll("{\"line\":");
            try self.writeU32(line_num);
            try self.writer.writeAll(",\"column\":");
            try self.writeU32(cp_col);
            try self.writer.writeAll(",\"index\":");
            try self.writeU32(cp_offset);
            try self.writer.writeAll("}");
        }

        /// Convert a byte offset to a UTF-16 code unit offset.
        /// Babel uses UTF-16 code units for positions: non-BMP characters
        /// (4-byte UTF-8 / surrogate pairs) count as 2 units.
        fn byteToCodePoint(self: *Self, byte_offset: u32) u32 {
            var cp_count: u32 = 0;
            var i: u32 = 0;
            while (i < byte_offset and i < self.ast.source.len) {
                const b = self.ast.source[i];
                if (b < 0x80) {
                    i += 1;
                    cp_count += 1;
                } else if (b < 0xC0) {
                    // Continuation byte (shouldn't start a char, but advance)
                    i += 1;
                    cp_count += 1;
                } else if (b < 0xE0) {
                    i += 2;
                    cp_count += 1;
                } else if (b < 0xF0) {
                    i += 3;
                    cp_count += 1;
                } else {
                    // Non-BMP: 4 bytes in UTF-8 = 2 UTF-16 code units (surrogate pair)
                    i += 4;
                    cp_count += 2;
                }
            }
            return cp_count;
        }

        fn writeU32(self: *Self, value: u32) anyerror!void {
            var buf: [10]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
            try self.writer.writeAll(s);
        }

        /// Check if an optional chain node was the original `?.` (true) or chain-propagated (false).
        fn isDirectOptional(self: *Self, idx: NodeIndex) bool {
            const main_tok = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            return self.ast.tokens.items(.tag)[@intFromEnum(main_tok)] == .optional_chain;
        }

        fn isDeclareNode(self: *Self, idx: NodeIndex) bool {
            const main_tok = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            return std.mem.eql(u8, self.ast.tokenSlice(main_tok), "declare");
        }

        /// Wrap an Identifier node in a PrivateName { id: Identifier } structure.
        /// The PrivateName start includes the # prefix.
        /// Wrap an Identifier node in a PrivateName { id: Identifier } structure.
        /// In ESTree mode, emit PrivateIdentifier { name: "foo" } instead.
        /// The PrivateName/PrivateIdentifier start includes the # prefix.
        fn writePrivateName(self: *Self, ident_idx: NodeIndex) anyerror!void {
            const ident_start = self.nodeStart(ident_idx);
            const ident_end = self.nodeEnd(ident_idx);
            // PrivateName includes the # character, so start is one before the identifier
            const pn_start = if (ident_start > 0) ident_start - 1 else ident_start;
            if (self.estree) {
                try self.writer.writeAll("{\"type\":\"PrivateIdentifier\",");
                try self.writePosition(pn_start, ident_end);
                try self.writer.writeAll(",\"name\":\"");
                const name = self.getNodeName(ident_idx);
                try self.writeJsonEscaped(name);
                try self.writer.writeAll("\"}");
                return;
            }
            try self.writer.writeAll("{\"type\":\"PrivateName\",");
            try self.writePosition(pn_start, ident_end);
            try self.writeParenExtra();
            try self.writer.writeAll(",\"id\":");
            try self.writeChildIsolated(ident_idx);
            try self.writeParenExtra();
            try self.writer.writeAll("}");
        }

        /// Write a member expression property from a token index.
        /// Handles PrivateName (Babel) / PrivateIdentifier (ESTree) wrapping for private members.
        fn writeInlinePropertyFromToken(self: *Self, rhs: NodeIndex) anyerror!void {
            const prop_token_idx = @intFromEnum(rhs);
            const prop_start = self.ast.tokens.items(.start)[prop_token_idx];
            const prop_end = self.ast.tokens.items(.end)[prop_token_idx];
            const prop_name = self.ast.source[prop_start..prop_end];
            const is_private = prop_token_idx > 0 and self.ast.tokens.items(.tag)[prop_token_idx - 1] == .hash;
            if (is_private) {
                const hash_start = self.ast.tokens.items(.start)[prop_token_idx - 1];
                if (self.estree) {
                    try self.writer.writeAll("{\"type\":\"PrivateIdentifier\",");
                    try self.writePosition(hash_start, prop_end);
                    try self.writer.writeAll(",\"name\":\"");
                    try self.writeJsonEscaped(prop_name);
                    try self.writer.writeAll("\"}");
                    return;
                }
                try self.writer.writeAll("{\"type\":\"PrivateName\",");
                try self.writePosition(hash_start, prop_end);
                try self.writer.writeAll(",\"id\":");
            }
            try self.writer.writeAll("{\"type\":\"Identifier\",");
            try self.writePositionWithIdentName(prop_start, prop_end, prop_name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writer.writeAll(prop_name);
            try self.writer.writeAll("\"");
            if (self.estree) {
                try self.writer.writeAll(",\"decorators\":[],\"optional\":false");
            }
            try self.writer.writeAll("}");
            if (is_private) {
                try self.writer.writeAll("}");
            }
        }

        fn writeParenExtra(self: *Self) anyerror!void {
            try self.writeExtraObject(null);
        }

        /// Write a child node while shielding it from the current paren_start.
        /// The child won't see (or consume) the outer parenthesized context.
        fn writeChildIsolated(self: *Self, child: NodeIndex) anyerror!void {
            const saved = self.paren_start;
            self.paren_start = null;
            try self.writeNode(child);
            self.paren_start = saved;
        }

        /// Consume paren_start and write parenthesized fields into an already-open
        /// extra object. Call this inside a `{...}` that was already opened by the caller.
        /// Returns true if any fields were written (caller may need a leading comma).
        fn consumeParenFields(self: *Self, need_leading_comma: bool) anyerror!bool {
            const ps = self.paren_start;
            if (ps != null) self.paren_start = null;
            if (ps) |p| {
                if (need_leading_comma) try self.writer.writeAll(",");
                try self.writer.writeAll("\"parenthesized\":true,\"parenStart\":");
                try self.writeU32(p);
                return true;
            }
            return false;
        }

        fn writeExtraObject(self: *Self, trailing_comma: ?u32) anyerror!void {
            const ps = self.paren_start;
            if (ps != null) self.paren_start = null;
            if (ps == null and trailing_comma == null) return;
            try self.writer.writeAll(",\"extra\":{");
            var need_comma = false;
            if (trailing_comma) |tc| {
                try self.writer.writeAll("\"trailingComma\":");
                try self.writeU32(tc);
                need_comma = true;
            }
            if (ps) |p| {
                if (need_comma) try self.writer.writeAll(",");
                try self.writer.writeAll("\"parenthesized\":true,\"parenStart\":");
                try self.writeU32(p);
            }
            try self.writer.writeAll("}");
        }

        fn findTrailingComma(self: *Self, end_pos: u32) ?u32 {
            if (end_pos == 0) return null;
            var pos: u32 = end_pos - 1;
            while (pos > 0) {
                pos -= 1;
                const c = self.ast.source[pos];
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
                // Skip block comments: scan backward past /* ... */
                if (c == '/' and pos > 0 and self.ast.source[pos - 1] == '*') {
                    if (pos < 2) return null;
                    pos -= 2;
                    while (pos > 0) {
                        if (self.ast.source[pos] == '*' and pos > 0 and self.ast.source[pos - 1] == '/') {
                            pos -= 1;
                            break;
                        }
                        pos -= 1;
                    }
                    continue;
                }
                // Skip line comments: if we're at the end of a // comment,
                // scan backward to find the // and skip it
                if (c != ',' and c != ')' and c != ']' and c != '}') {
                    // Could be inside a line comment — find start of this line
                    const line_start = blk: {
                        var lp = pos;
                        while (lp > 0 and self.ast.source[lp - 1] != '\n') lp -= 1;
                        break :blk lp;
                    };
                    // Check if there's a // on this line before pos
                    var lp = line_start;
                    while (lp + 1 <= pos) : (lp += 1) {
                        if (self.ast.source[lp] == '/' and self.ast.source[lp + 1] == '/') {
                            // This is a line comment; skip to before it
                            if (lp == 0) return null;
                            pos = lp;
                            break;
                        }
                    } else {
                        // Not a line comment — unknown char
                        return null;
                    }
                    continue;
                }
                if (c == ',') return pos;
                return null;
            }
            return null;
        }

        fn writeI64(self: *Self, value: i64) anyerror!void {
            var buf: [21]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
            try self.writer.writeAll(s);
        }

        fn writeF64(self: *Self, value: f64) anyerror!void {
            // Use scientific notation for very large/small values, decimal otherwise.
            // JS uses e+ for positive exponents (6.02214179e+23).
            var buf: [64]u8 = undefined;
            const abs = @abs(value);
            if (abs != 0 and (abs >= 1e21 or abs < 1e-6)) {
                const e = std.fmt.bufPrint(&buf, "{e}", .{value}) catch "0";
                for (e, 0..) |c, i| {
                    if (c == 'e' and i + 1 < e.len and e[i + 1] != '-' and e[i + 1] != '+') {
                        try self.writer.writeAll(e[0 .. i + 1]);
                        try self.writer.writeAll("+");
                        try self.writer.writeAll(e[i + 1 ..]);
                        return;
                    }
                }
                try self.writer.writeAll(e);
            } else {
                const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
                try self.writer.writeAll(s);
            }
        }

        fn nodeStart(self: *Self, idx: NodeIndex) u32 {
            const i = @intFromEnum(idx);
            // Check for explicit start position override
            if (self.ast.node_start_overrides.get(i)) |override| {
                return override;
            }
            const tag = self.ast.nodes.items(.tag)[i];
            const data = self.ast.nodes.items(.data)[i];

            // For nodes whose start is determined by their first child, not main_token
            switch (tag) {
                .jsx_text => {
                    // JSXText stores [source_start, source_end] in extra_data
                    const extra_idx = @intFromEnum(data.extra);
                    return self.ast.extra_data.items[extra_idx];
                },
                .program => {
                    // Program always starts at position 0 (beginning of file)
                    return 0;
                },
                .call_expr, .optional_call_expr => {
                    // Start is the start of the callee
                    const extra_idx = @intFromEnum(data.extra);
                    const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
                    return self.nodeStart(callee);
                },
                .ts_conditional_type => {
                    // Start is the start of the checkType (first extra data element)
                    const extra_idx = @intFromEnum(data.extra);
                    const check_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
                    return self.nodeStart(check_type);
                },
                .member_expr, .computed_member_expr => {
                    // Start is the start of the object
                    return self.nodeStart(data.binary.lhs);
                },
                .binary_expr,
                .logical_expr,
                .assignment_expr,
                .assignment_pattern,
                .ts_as_expression,
                .ts_satisfies_expression,
                .ts_indexed_access_type,
                .ts_instantiation_expression,
                => {
                    // Start is the start of the left operand
                    return self.nodeStart(data.binary.lhs);
                },
                .conditional_expr => {
                    // Start is the start of the test
                    return self.nodeStart(data.binary.lhs);
                },
                .update_expr => {
                    // For prefix: main_token is correct; for postfix: start is the argument
                    const main_token = self.ast.nodes.items(.main_token)[i];
                    const op_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                    const arg_start = self.nodeStart(data.unary);
                    return @min(op_start, arg_start);
                },
                .tagged_template_expr => {
                    // Start is the start of the tag
                    const extra_idx = @intFromEnum(data.extra);
                    const tag_expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
                    return self.nodeStart(tag_expr);
                },
                .optional_chain_expr, .optional_computed_member_expr => {
                    // Start is the start of the object
                    return self.nodeStart(data.binary.lhs);
                },
                .expression_statement => {
                    // Start is the start of the expression
                    return self.nodeStart(data.unary);
                },
                .placeholder => {
                    // Start is the first % token
                    const start_tok = data.token;
                    return self.ast.tokens.items(.start)[@intFromEnum(start_tok)];
                },
                .ts_non_null_expression, .flow_array_type, .ts_array_type => {
                    // Start is the start of the operand/element type
                    return self.nodeStart(data.unary);
                },
                .ts_type_reference => {
                    // Start is the start of the name/expression (lhs)
                    return self.nodeStart(data.binary.lhs);
                },
                .flow_type_cast_expression => {
                    // Start is the start of the expression
                    const extra_idx2 = @intFromEnum(data.extra);
                    const expr2: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx2]);
                    return self.nodeStart(expr2);
                },
                .flow_qualified_type_identifier => {
                    // Start is the start of the qualification chain (first part)
                    const qi_extra = @intFromEnum(data.extra);
                    const qual: NodeIndex = @enumFromInt(self.ast.extra_data.items[qi_extra]);
                    return self.nodeStart(qual);
                },
                .flow_indexed_access_type, .flow_optional_indexed_access_type => {
                    // Start is the start of the object type
                    const fi_extra = @intFromEnum(data.extra);
                    const obj_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[fi_extra]);
                    return self.nodeStart(obj_type);
                },
                .sequence_expr => {
                    // Start is the start of the first element
                    const extra_idx = @intFromEnum(data.extra);
                    if (extra_idx < self.ast.extra_data.items.len) {
                        const range_start = self.ast.extra_data.items[extra_idx];
                        const range_end = self.ast.extra_data.items[extra_idx + 1];
                        if (range_start < range_end and range_end <= self.ast.extra_data.items.len) {
                            const first: NodeIndex = @enumFromInt(self.ast.extra_data.items[range_start]);
                            return self.nodeStart(first);
                        }
                    }
                    const main_token = self.ast.nodes.items(.main_token)[i];
                    return self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                },
                .flow_union_type, .flow_intersection_type => {
                    // Start is the leading |/& token if present, else first element
                    const main_token = self.ast.nodes.items(.main_token)[i];
                    const main_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                    const extra_idx = @intFromEnum(data.extra);
                    if (extra_idx < self.ast.extra_data.items.len) {
                        const range_start = self.ast.extra_data.items[extra_idx];
                        const range_end = self.ast.extra_data.items[extra_idx + 1];
                        if (range_start < range_end and range_end <= self.ast.extra_data.items.len) {
                            const first: NodeIndex = @enumFromInt(self.ast.extra_data.items[range_start]);
                            const first_start = self.nodeStart(first);
                            return @min(main_start, first_start);
                        }
                    }
                    return main_start;
                },
                .new_expr => {
                    // Start is 'new' keyword - use main_token
                    const main_token = self.ast.nodes.items(.main_token)[i];
                    return self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                },
                .import_namespace => {
                    // ImportNamespaceSpecifier: `* as foo` — main_token is `foo`,
                    // but start should be at `*` (two tokens back).
                    const main_token = self.ast.nodes.items(.main_token)[i];
                    const mt = @intFromEnum(main_token);
                    if (mt >= 2 and self.ast.tokens.items(.tag)[mt - 2] == .asterisk) {
                        return self.ast.tokens.items(.start)[mt - 2];
                    }
                    return self.ast.tokens.items(.start)[mt];
                },
                .getter, .setter => {
                    // Walk backwards from main_token (the key) to find the earliest
                    // modifier: skip optional `#`, optional `*`, then expect `get`/`set`, then optional `static`,
                    // then optional TS modifier identifiers.
                    const main_token = self.ast.nodes.items(.main_token)[i];
                    var pos = @intFromEnum(main_token);
                    // Skip hash (private name marker)
                    if (pos > 0 and self.ast.tokens.items(.tag)[pos - 1] == .hash) {
                        pos -= 1;
                    }
                    // Skip asterisk (invalid generator getter/setter, error recovery)
                    if (pos > 0 and self.ast.tokens.items(.tag)[pos - 1] == .asterisk) {
                        pos -= 1;
                    }
                    // Expect get/set keyword
                    if (pos > 0) {
                        const prev_tag = self.ast.tokens.items(.tag)[pos - 1];
                        if (prev_tag == .kw_get or prev_tag == .kw_set) {
                            pos -= 1;
                        }
                    }
                    // Check for static keyword
                    if (pos > 0 and self.ast.tokens.items(.tag)[pos - 1] == .kw_static) {
                        pos -= 1;
                    }
                    // Walk past TS modifier identifiers (declare, abstract, override, etc.)
                    while (pos > 0 and self.ast.tokens.items(.tag)[pos - 1] == .identifier) {
                        const tok_text = self.ast.source[self.ast.tokens.items(.start)[pos - 1]..self.ast.tokens.items(.end)[pos - 1]];
                        if (Parser.tsModifierBit(tok_text) != 0) {
                            pos -= 1;
                        } else break;
                    }
                    return self.ast.tokens.items(.start)[pos];
                },
                else => {
                    const main_token = self.ast.nodes.items(.main_token)[i];
                    const start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
                    // For nodes created from `<<` token splitting, the second `<` starts
                    // 1 byte after the `<<` token start. Detect by checking if main_token
                    // is a `<<` token and the node is for the inner (second) `<`.
                    if (self.ast.tokens.items(.tag)[@intFromEnum(main_token)] == .less_less) {
                        if (tag == .ts_type_parameter_declaration or tag == .ts_function_type or tag == .ts_constructor_type or
                            tag == .flow_type_parameter_declaration or tag == .flow_function_type_annotation)
                        {
                            return start + 1;
                        }
                    }
                    return start;
                },
            }
        }

        fn nodeEnd(self: *Self, idx: NodeIndex) u32 {
            const i = @intFromEnum(idx);
            const end_off = self.ast.nodes.items(.end_offset)[i];
            if (end_off > 0) return end_off;
            // Fallback to main_token end
            const main_token = self.ast.nodes.items(.main_token)[i];
            return self.ast.tokens.items(.end)[@intFromEnum(main_token)];
        }

        // === Helpers ===

        fn writeExtraRange(self: *Self, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx < self.ast.extra_data.items.len) {
                const range_start = self.ast.extra_data.items[extra_idx];
                const range_end = self.ast.extra_data.items[extra_idx + 1];
                if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                    const items = self.ast.extra_data.items[range_start..range_end];
                    for (items, 0..) |item, j| {
                        if (j > 0) try self.writer.writeAll(",");
                        try self.writeNode(@enumFromInt(item));
                    }
                }
            }
        }

        /// Write a range of NodeIndex values from extra_data as a comma-separated list.
        fn writeNodeRange(self: *Self, range_start: u32, range_end: u32) anyerror!void {
            if (range_start <= range_end and range_end <= self.ast.extra_data.items.len) {
                const items = self.ast.extra_data.items[range_start..range_end];
                for (items, 0..) |item, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(item));
                }
            }
        }

        fn writeOptionalTokenAsIdent(self: *Self, token_raw: u32) anyerror!void {
            if (token_raw == 0) {
                try self.writer.writeAll("null");
                return;
            }
            try self.writeTokenAsIdent(@enumFromInt(token_raw));
        }

        fn writeTokenAsIdentOrString(self: *Self, token: TokenIndex) anyerror!void {
            const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(token)];
            if (tok_tag == .string) {
                try self.writeStringLiteralFromToken(token);
            } else {
                try self.writeTokenAsIdent(token);
            }
        }

        fn writeTokenAsIdent(self: *Self, token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(token)];
            const name = self.ast.source[start..end];
            try self.writer.writeAll("{\"type\":\"Identifier\",");
            try self.writePositionWithIdentName(start, end, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"");
            // In TypeScript mode, Babel emits decorators and optional on Identifier nodes
            if (self.ast.language.isTypeScript()) {
                try self.writer.writeAll(",\"decorators\":[],\"optional\":false");
            }
            try self.writer.writeAll("}");
        }

        fn writeNumericLiteralFromToken(self: *Self, token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(token)];
            const raw = self.ast.source[start..end];
            try self.writer.writeAll("{\"type\":\"NumericLiteral\",");
            try self.writePosition(start, end);
            try self.writer.writeAll(",\"extra\":{\"rawValue\":");
            try self.writeNumericValue(raw);
            try self.writer.writeAll(",\"raw\":\"");
            try self.writer.writeAll(raw);
            try self.writer.writeAll("\"},\"value\":");
            try self.writeNumericValue(raw);
            try self.writer.writeAll("}");
        }

        fn writeBigIntLiteralFromToken(self: *Self, token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(token)];
            const raw = self.ast.source[start..end];
            const value_raw = if (raw.len > 0 and raw[raw.len - 1] == 'n') raw[0 .. raw.len - 1] else raw;
            var dec_buf: [32]u8 = undefined;
            const value = bigintToDecimal(value_raw, &dec_buf);
            try self.writer.writeAll("{\"type\":\"BigIntLiteral\",");
            try self.writePosition(start, end);
            try self.writer.writeAll(",\"extra\":{\"rawValue\":\"");
            try self.writer.writeAll(value);
            try self.writer.writeAll("\",\"raw\":\"");
            try self.writer.writeAll(raw);
            try self.writer.writeAll("\"},\"value\":\"");
            try self.writer.writeAll(value);
            try self.writer.writeAll("\"}");
        }

        fn writeStringLiteralFromToken(self: *Self, token: TokenIndex) anyerror!void {
            const start = self.ast.tokens.items(.start)[@intFromEnum(token)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(token)];
            const raw = self.ast.source[start..end];
            const value = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
            try self.writer.writeAll("{\"type\":\"StringLiteral\",");
            try self.writePosition(start, end);
            try self.writer.writeAll(",\"extra\":{\"rawValue\":");
            try self.writeJsResolvedJsonString(value);
            try self.writer.writeAll(",\"raw\":\"");
            try self.writeJsonEscaped(raw);
            try self.writer.writeAll("\"},\"value\":");
            try self.writeJsResolvedJsonString(value);
            try self.writer.writeAll("}");
        }

        fn getNodeName(self: *Self, idx: NodeIndex) []const u8 {
            if (idx == .none) return "";
            const i = @intFromEnum(idx);
            const mt = self.ast.nodes.items(.main_token)[i];
            const start = self.ast.tokens.items(.start)[@intFromEnum(mt)];
            const end = self.ast.tokens.items(.end)[@intFromEnum(mt)];
            const raw = self.ast.source[start..end];
            // Strip quotes for string literals
            if (raw.len >= 2 and (raw[0] == '\'' or raw[0] == '"')) {
                return raw[1 .. raw.len - 1];
            }
            return raw;
        }

        fn writeOperator(self: *Self, main_token: TokenIndex) anyerror!void {
            const tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
            const op = switch (tag) {
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
                    // Check if this is a pipeline operator (|>)
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
                else => "?",
            };
            try self.writer.writeAll(op);
        }

        fn writeJsonString(self: *Self, s: []const u8) anyerror!void {
            try self.writer.writeAll("\"");
            try self.writeJsonEscaped(s);
            try self.writer.writeAll("\"");
        }

        /// Write string content with JSON escaping (for use between quotes)
        fn writeStringContent(self: *Self, s: []const u8) anyerror!void {
            try self.writeJsonEscaped(s);
        }

        /// Write an identifier name with unicode escape sequences resolved.
        /// E.g., `\u0061_` becomes `a_`, `\u{0061}` becomes `a`.
        /// Also handles malformed escapes with underscores (numeric separators)
        /// by stripping underscores before parsing hex digits.
        fn writeIdentName(self: *Self, s: []const u8) anyerror!void {
            var i: usize = 0;
            while (i < s.len) {
                if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == 'u') {
                    i += 2; // skip \u
                    if (i < s.len and s[i] == '{') {
                        // \u{XXXX} form
                        i += 1; // skip {
                        const hex_start = i;
                        while (i < s.len and s[i] != '}') : (i += 1) {}
                        const has_close = (i < s.len and s[i] == '}');
                        const hex = s[hex_start..i];
                        if (has_close) {
                            i += 1; // skip }
                            // Validate hex content — empty or non-hex → drop (Babel behavior)
                            if (hex.len == 0) continue;
                            var all_hex = true;
                            for (hex) |hc| {
                                if (hc != '_' and !std.ascii.isHex(hc)) {
                                    all_hex = false;
                                    break;
                                }
                            }
                            if (!all_hex) continue;
                            const cp = parseHexStrippingUnderscores(hex);
                            if (cp > 0x10FFFF) continue;
                            try self.writeUtf8CodePoint(cp);
                        } else {
                            // Unclosed \u{...} — Babel error recovery: consume \u{ + first hex digit,
                            // remaining hex chars become literal identifier chars
                            i = hex_start;
                            if (i < s.len and std.ascii.isHex(s[i])) i += 1; // skip one hex digit
                        }
                    } else {
                        // \uXXXX form — consume exactly 4 hex digits or underscores
                        var char_count: usize = 0;
                        while (char_count < 4 and i + char_count < s.len and
                            (std.ascii.isHex(s[i + char_count]) or s[i + char_count] == '_')) : (char_count += 1)
                        {}
                        if (char_count == 4) {
                            const cp = parseHexStrippingUnderscores(s[i..][0..4]);
                            i += 4;
                            // Handle surrogate pairs: high surrogate followed by \uXXXX low surrogate
                            if (cp >= 0xD800 and cp <= 0xDBFF) {
                                // Look ahead for low surrogate \uXXXX
                                if (i + 5 < s.len and s[i] == '\\' and s[i + 1] == 'u') {
                                    var lo_hex_count: usize = 0;
                                    while (lo_hex_count < 4 and i + 2 + lo_hex_count < s.len and std.ascii.isHex(s[i + 2 + lo_hex_count])) : (lo_hex_count += 1) {}
                                    if (lo_hex_count == 4) {
                                        const lo = parseHexStrippingUnderscores(s[i + 2 ..][0..4]);
                                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                            i += 6; // skip \uXXXX
                                            const combined: u21 = @intCast(((cp - 0xD800) << 10) + (lo - 0xDC00) + 0x10000);
                                            try self.writeUtf8CodePoint(combined);
                                            continue;
                                        }
                                    }
                                }
                            }
                            try self.writeUtf8CodePoint(cp);
                        } else {
                            // Malformed escape — skip available hex/underscore chars (Babel drops them)
                            i += char_count;
                        }
                    }
                } else {
                    try self.writeJsonEscapedChar(s[i]);
                    i += 1;
                }
            }
        }

        /// Parse a hex string, stripping underscore separators.
        fn parseHexStrippingUnderscores(hex: []const u8) u21 {
            var buf: [8]u8 = undefined;
            var len: usize = 0;
            for (hex) |c| {
                if (c != '_' and len < buf.len) {
                    buf[len] = c;
                    len += 1;
                }
            }
            return std.fmt.parseInt(u21, buf[0..len], 16) catch 0xFFFD;
        }

        /// Write a single unicode code point as UTF-8, JSON-escaped.
        fn writeUtf8CodePoint(self: *Self, cp: u21) anyerror!void {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch {
                try self.writer.writeAll("\xEF\xBF\xBD"); // U+FFFD
                return;
            };
            for (buf[0..len]) |b| {
                try self.writeJsonEscapedChar(b);
            }
        }

        /// Write template raw value with CR normalization.
        /// In template raw strings, \r\n → \n and lone \r → \n.
        fn writeTemplateRawEscaped(self: *Self, s: []const u8) anyerror!void {
            var i: usize = 0;
            while (i < s.len) {
                const c = s[i];
                switch (c) {
                    '"' => {
                        try self.writer.writeAll("\\\"");
                        i += 1;
                    },
                    '\\' => {
                        try self.writer.writeAll("\\\\");
                        i += 1;
                    },
                    '\r' => {
                        // Normalize CR and CRLF to LF
                        try self.writer.writeAll("\\n");
                        i += 1;
                        if (i < s.len and s[i] == '\n') i += 1;
                    },
                    '\n' => {
                        try self.writer.writeAll("\\n");
                        i += 1;
                    },
                    '\t' => {
                        try self.writer.writeAll("\\t");
                        i += 1;
                    },
                    else => {
                        if (c < 0x20) {
                            var buf: [6]u8 = undefined;
                            const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch {
                                i += 1;
                                continue;
                            };
                            try self.writer.writeAll(hex);
                        } else {
                            try self.writer.writeAll(&[_]u8{c});
                        }
                        i += 1;
                    },
                }
            }
        }

        /// Write template cooked value (escape-resolved) with CR normalization.
        /// Like writeJsResolvedJsonString but also normalizes bare CR→LF and CRLF→LF.
        fn writeTemplateCookedString(self: *Self, s: []const u8) anyerror!void {
            try self.writer.writeAll("\"");
            var i: usize = 0;
            while (i < s.len) {
                if (s[i] == '\\' and i + 1 < s.len) {
                    i += 1;
                    switch (s[i]) {
                        'n' => {
                            try self.writer.writeAll("\\n");
                            i += 1;
                        },
                        'r' => {
                            try self.writer.writeAll("\\r");
                            i += 1;
                        },
                        't' => {
                            try self.writer.writeAll("\\t");
                            i += 1;
                        },
                        'v' => {
                            try self.writer.writeAll("\\u000b");
                            i += 1;
                        },
                        'b' => {
                            try self.writer.writeAll("\\b");
                            i += 1;
                        },
                        'f' => {
                            try self.writer.writeAll("\\f");
                            i += 1;
                        },
                        '\\' => {
                            try self.writer.writeAll("\\\\");
                            i += 1;
                        },
                        '\'' => {
                            try self.writer.writeAll("'");
                            i += 1;
                        },
                        '"' => {
                            try self.writer.writeAll("\\\"");
                            i += 1;
                        },
                        '`' => {
                            try self.writer.writeAll("`");
                            i += 1;
                        },
                        '$' => {
                            try self.writer.writeAll("$");
                            i += 1;
                        },
                        '0' => {
                            if (i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '9') {
                                const result = parseLegacyOctal(s, i);
                                try self.writeJsonCodepoint(result.value);
                                i = result.end;
                            } else {
                                try self.writer.writeAll("\\u0000");
                                i += 1;
                            }
                        },
                        '1', '2', '3', '4', '5', '6', '7' => {
                            const result = parseLegacyOctal(s, i);
                            try self.writeJsonCodepoint(result.value);
                            i = result.end;
                        },
                        '8', '9' => {
                            try self.writer.writeAll(&[_]u8{s[i]});
                            i += 1;
                        },
                        'x' => {
                            i += 1;
                            if (i + 2 <= s.len) {
                                const val = std.fmt.parseInt(u8, s[i .. i + 2], 16) catch {
                                    // Invalid \xHH — write raw \x and let remaining chars be literal
                                    try self.writer.writeAll("\\x");
                                    while (i < s.len and std.ascii.isHex(s[i])) : (i += 1) {
                                        try self.writer.writeAll(&[_]u8{s[i]});
                                    }
                                    continue;
                                };
                                try self.writeJsonCodepoint(@intCast(val));
                                i += 2;
                            } else {
                                // Incomplete \xH — write raw characters
                                try self.writer.writeAll("\\x");
                                while (i < s.len and std.ascii.isHex(s[i])) : (i += 1) {
                                    try self.writer.writeAll(&[_]u8{s[i]});
                                }
                            }
                        },
                        'u' => {
                            i += 1;
                            if (i < s.len and s[i] == '{') {
                                i += 1;
                                const close = std.mem.indexOfScalarPos(u8, s, i, '}') orelse {
                                    while (i < s.len and std.ascii.isHex(s[i])) i += 1;
                                    continue;
                                };
                                const val = std.fmt.parseInt(u21, s[i..close], 16) catch {
                                    i = close + 1;
                                    continue;
                                };
                                try self.writeJsonCodepoint(val);
                                i = close + 1;
                            } else if (i + 4 <= s.len) {
                                const val = std.fmt.parseInt(u16, s[i .. i + 4], 16) catch {
                                    while (i < s.len and std.ascii.isHex(s[i])) i += 1;
                                    continue;
                                };
                                try self.writeJsonCodepoint(@intCast(val));
                                i += 4;
                            } else {
                                while (i < s.len and std.ascii.isHex(s[i])) i += 1;
                            }
                        },
                        '\n' => {
                            // Line continuation — skip
                            i += 1;
                            if (i < s.len and s[i] == '\r') i += 1;
                        },
                        '\r' => {
                            // Line continuation — skip
                            i += 1;
                            if (i < s.len and s[i] == '\n') i += 1;
                        },
                        0xE2 => {
                            // Possible \<LS> or \<PS> — line continuation
                            if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
                                i += 3;
                            } else {
                                try self.writeJsonEscapedChar(s[i]);
                                i += 1;
                            }
                        },
                        else => |c| {
                            try self.writeJsonEscapedChar(c);
                            i += 1;
                        },
                    }
                } else if (s[i] == '\r') {
                    // Bare CR or CRLF → LF in cooked
                    try self.writer.writeAll("\\n");
                    i += 1;
                    if (i < s.len and s[i] == '\n') i += 1;
                } else {
                    try self.writeJsonEscapedChar(s[i]);
                    i += 1;
                }
            }
            try self.writer.writeAll("\"");
        }

        fn writeJsonEscaped(self: *Self, s: []const u8) anyerror!void {
            for (s) |c| {
                switch (c) {
                    '"' => try self.writer.writeAll("\\\""),
                    '\\' => try self.writer.writeAll("\\\\"),
                    '\n' => try self.writer.writeAll("\\n"),
                    '\r' => try self.writer.writeAll("\\r"),
                    '\t' => try self.writer.writeAll("\\t"),
                    else => {
                        if (c < 0x20) {
                            var buf: [6]u8 = undefined;
                            const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                            try self.writer.writeAll(hex);
                        } else {
                            try self.writer.writeAll(&[_]u8{c});
                        }
                    },
                }
            }
        }

        /// Write a JSON string with JS escape sequences resolved.
        /// Input `s` is the raw string content between quotes (e.g., `use\x20strict`).
        /// Output is a JSON-encoded string with escapes interpreted (e.g., `"use strict"`).
        fn writeJsResolvedJsonString(self: *Self, s: []const u8) anyerror!void {
            try self.writer.writeAll("\"");
            var i: usize = 0;
            while (i < s.len) {
                if (s[i] == '\\' and i + 1 < s.len) {
                    i += 1;
                    switch (s[i]) {
                        'n' => {
                            try self.writer.writeAll("\\n");
                            i += 1;
                        },
                        'r' => {
                            try self.writer.writeAll("\\r");
                            i += 1;
                        },
                        't' => {
                            try self.writer.writeAll("\\t");
                            i += 1;
                        },
                        'v' => {
                            try self.writer.writeAll("\\u000b");
                            i += 1;
                        },
                        'b' => {
                            try self.writer.writeAll("\\b");
                            i += 1;
                        },
                        'f' => {
                            try self.writer.writeAll("\\f");
                            i += 1;
                        },
                        '\\' => {
                            try self.writer.writeAll("\\\\");
                            i += 1;
                        },
                        '\'' => {
                            try self.writer.writeAll("'");
                            i += 1;
                        },
                        '"' => {
                            try self.writer.writeAll("\\\"");
                            i += 1;
                        },
                        '0' => {
                            // \0 is null if not followed by another digit
                            if (i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '9') {
                                // Legacy octal — parse the octal value
                                const result = parseLegacyOctal(s, i);
                                try self.writeJsonCodepoint(result.value);
                                i = result.end;
                            } else {
                                try self.writer.writeAll("\\u0000");
                                i += 1;
                            }
                        },
                        '1', '2', '3', '4', '5', '6', '7' => {
                            // Legacy octal escape
                            const result = parseLegacyOctal(s, i);
                            try self.writeJsonCodepoint(result.value);
                            i = result.end;
                        },
                        '8', '9' => {
                            // \8 and \9 are themselves (non-octal decimal escape)
                            try self.writer.writeAll(&[_]u8{s[i]});
                            i += 1;
                        },
                        'x' => {
                            i += 1;
                            // Consume up to 2 hex digits or underscores (separators)
                            var hex_val: u16 = 0;
                            var consumed: usize = 0;
                            var valid = true;
                            while (consumed < 2 and i < s.len) {
                                const hc = s[i];
                                if (hc == '_') {
                                    // Numeric separator — consume but don't add to value
                                    i += 1;
                                    consumed += 1;
                                } else if (std.ascii.isHex(hc)) {
                                    hex_val = hex_val * 16 + @as(u16, switch (hc) {
                                        '0'...'9' => hc - '0',
                                        'a'...'f' => hc - 'a' + 10,
                                        'A'...'F' => hc - 'A' + 10,
                                        else => unreachable,
                                    });
                                    i += 1;
                                    consumed += 1;
                                } else {
                                    valid = false;
                                    break;
                                }
                            }
                            if (consumed == 2) {
                                try self.writeJsonCodepoint(@intCast(hex_val));
                            }
                            // If consumed < 2: invalid escape — produce nothing,
                            // unconsumed chars become literal (handled by outer loop)
                        },
                        'u' => {
                            i += 1;
                            if (i < s.len and s[i] == '{') {
                                // \u{HHHH...}
                                i += 1;
                                const close = std.mem.indexOfScalarPos(u8, s, i, '}') orelse {
                                    // No closing brace — Babel error recovery: skip one hex digit,
                                    // remaining chars become literal
                                    if (i < s.len and std.ascii.isHex(s[i])) i += 1;
                                    continue;
                                };
                                const val = std.fmt.parseInt(u21, s[i..close], 16) catch {
                                    i = close + 1;
                                    continue;
                                };
                                try self.writeJsonCodepoint(val);
                                i = close + 1;
                            } else {
                                // \uHHHH — also accept underscores in the 4-char span
                                var char_count: usize = 0;
                                while (char_count < 4 and i + char_count < s.len and
                                    (std.ascii.isHex(s[i + char_count]) or s[i + char_count] == '_')) : (char_count += 1)
                                {}
                                if (char_count == 4) {
                                    const cp = parseHexStrippingUnderscores(s[i..][0..4]);
                                    try self.writeJsonCodepoint(@intCast(cp));
                                    i += 4;
                                } else {
                                    i += char_count;
                                }
                            }
                        },
                        '\n' => {
                            // Line continuation — skip
                            i += 1;
                            if (i < s.len and s[i] == '\r') i += 1;
                        },
                        '\r' => {
                            // Line continuation — skip
                            i += 1;
                            if (i < s.len and s[i] == '\n') i += 1;
                        },
                        0xE2 => {
                            // Possible \<LS> (E2 80 A8) or \<PS> (E2 80 A9) — line continuation
                            if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
                                i += 3; // skip the 3-byte UTF-8 sequence
                            } else {
                                try self.writeJsonEscapedChar(s[i]);
                                i += 1;
                            }
                        },
                        else => |c| {
                            // Unknown escape — emit the character itself
                            try self.writeJsonEscapedChar(c);
                            i += 1;
                        },
                    }
                } else {
                    try self.writeJsonEscapedChar(s[i]);
                    i += 1;
                }
            }
            try self.writer.writeAll("\"");
        }

        fn writeJsonEscapedChar(self: *Self, c: u8) anyerror!void {
            switch (c) {
                '"' => try self.writer.writeAll("\\\""),
                '\\' => try self.writer.writeAll("\\\\"),
                '\n' => try self.writer.writeAll("\\n"),
                '\r' => try self.writer.writeAll("\\r"),
                '\t' => try self.writer.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch return;
                        try self.writer.writeAll(hex);
                    } else {
                        try self.writer.writeAll(&[_]u8{c});
                    }
                },
            }
        }

        fn writeJsonCodepoint(self: *Self, cp: u21) anyerror!void {
            if (cp < 0x80) {
                const c: u8 = @intCast(cp);
                try self.writeJsonEscapedChar(c);
            } else if (cp < 0x10000) {
                var buf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{cp}) catch return;
                try self.writer.writeAll(hex);
            } else {
                // Surrogate pair
                const adjusted = cp - 0x10000;
                const hi: u16 = @intCast(0xD800 + (adjusted >> 10));
                const lo: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
                var buf: [12]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}\\u{x:0>4}", .{ hi, lo }) catch return;
                try self.writer.writeAll(hex);
            }
        }

        fn parseLegacyOctal(s: []const u8, start: usize) struct { value: u21, end: usize } {
            var val: u21 = 0;
            var pos = start;
            const first = s[pos] - '0';
            val = first;
            pos += 1;
            if (pos < s.len and s[pos] >= '0' and s[pos] <= '7') {
                val = val * 8 + (s[pos] - '0');
                pos += 1;
                if (first <= 3 and pos < s.len and s[pos] >= '0' and s[pos] <= '7') {
                    val = val * 8 + (s[pos] - '0');
                    pos += 1;
                }
            }
            return .{ .value = val, .end = pos };
        }

        // === Comment serialization ===

        fn writeCommentValue(self: *Self, comment: Comment) anyerror!void {
            const type_str = switch (comment.kind) {
                .line => "CommentLine",
                .block => "CommentBlock",
            };
            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_str);
            try self.writer.writeAll("\",\"value\":\"");
            // Write comment value with JSON escaping
            const value = self.ast.source[comment.value_start..comment.value_end];
            try self.writeJsonEscaped(value);
            try self.writer.writeAll("\",");
            try self.writePosition(comment.start, comment.end);
            try self.writer.writeAll("}");
        }

        fn writeCommentArray(self: *Self, range: CommentRange) anyerror!void {
            try self.writer.writeAll("[");
            const comments = self.ast.comments.items;
            var first = true;
            var i = range.start;
            while (i < range.end and i < comments.len) : (i += 1) {
                if (!first) try self.writer.writeAll(",");
                try self.writeCommentValue(comments[i]);
                first = false;
            }
            try self.writer.writeAll("]");
        }

        // === Token Serialization ===

        fn writeTokenArray(self: *Self) anyerror!void {
            const tags = self.ast.tokens.items(.tag);
            const starts = self.ast.tokens.items(.start);
            const ends = self.ast.tokens.items(.end);
            try self.writer.writeByte('[');
            var first = true;
            var i: usize = 0;
            while (i < tags.len) {
                const tag = tags[i];
                // Skip invalid tokens
                if (tag == .invalid) {
                    i += 1;
                    continue;
                }
                if (!first) try self.writer.writeByte(',');
                first = false;
                // Merge # + identifier into a single #name token (Babel private name token)
                if (tag == .hash and i + 1 < tags.len and tags[i + 1] == .identifier) {
                    try self.writePrivateNameToken(starts[i], ends[i + 1]);
                    i += 2;
                    continue;
                }
                // For eof token, use file_end position
                if (tag == .eof) {
                    try self.writeTokenValue(tag, self.file_end, self.file_end);
                } else if (self.ast.jsx_token_flags.get(@intCast(i))) |jsx_type| {
                    try self.writeTokenValueJsx(tag, starts[i], ends[i], jsx_type);
                } else {
                    try self.writeTokenValue(tag, starts[i], ends[i]);
                }
                i += 1;
            }
            try self.writer.writeByte(']');
        }

        fn writePrivateNameToken(self: *Self, start: u32, end: u32) anyerror!void {
            try self.writer.writeAll("{\"type\":");
            // #name token type
            try self.writer.writeAll("{\"label\":\"#name\",\"beforeExpr\":false,\"startsExpr\":true,\"rightAssociative\":false,\"isLoop\":false,\"isAssign\":false,\"prefix\":false,\"postfix\":false,\"binop\":null}");
            // Value: the identifier (without #)
            try self.writer.writeAll(",\"value\":\"");
            const name_start = start + 1; // skip #
            try self.writeJsonEscaped(self.ast.source[name_start..end]);
            try self.writer.writeAll("\",");
            try self.writePosition(start, end);
            try self.writer.writeByte('}');
        }

        fn writeTokenValue(self: *Self, tag: Token.Tag, start: u32, end: u32) anyerror!void {
            try self.writer.writeAll("{\"type\":");
            try self.writeTokenType(tag);
            // Write value field
            try self.writeTokenValueField(tag, start, end);
            try self.writer.writeByte(',');
            try self.writePosition(start, end);
            try self.writer.writeByte('}');
        }

        fn writeTokenValueJsx(self: *Self, tag: Token.Tag, start: u32, end: u32, jsx_type: u8) anyerror!void {
            try self.writer.writeAll("{\"type\":");
            try self.writeJsxTokenType(tag, jsx_type);
            // Write value field for jsxName tokens
            if (jsx_type == 2) {
                try self.writer.writeAll(",\"value\":\"");
                try self.writeJsonEscaped(self.ast.source[start..end]);
                try self.writer.writeByte('"');
            }
            try self.writer.writeByte(',');
            try self.writePosition(start, end);
            try self.writer.writeByte('}');
        }

        fn writeJsxTokenType(self: *Self, _: Token.Tag, jsx_type: u8) anyerror!void {
            switch (jsx_type) {
                0 => try self.writer.writeAll("{\"label\":\"jsxTagStart\",\"beforeExpr\":false,\"startsExpr\":true,\"rightAssociative\":false,\"isLoop\":false,\"isAssign\":false,\"prefix\":false,\"postfix\":false,\"binop\":null}"),
                1 => try self.writer.writeAll("{\"label\":\"jsxTagEnd\",\"beforeExpr\":false,\"startsExpr\":false,\"rightAssociative\":false,\"isLoop\":false,\"isAssign\":false,\"prefix\":false,\"postfix\":false,\"binop\":null}"),
                2 => try self.writer.writeAll("{\"label\":\"jsxName\",\"beforeExpr\":false,\"startsExpr\":false,\"rightAssociative\":false,\"isLoop\":false,\"isAssign\":false,\"prefix\":false,\"postfix\":false,\"binop\":null}"),
                else => unreachable,
            }
        }

        fn writeTokenValueField(self: *Self, tag: Token.Tag, start: u32, end: u32) anyerror!void {
            switch (tag) {
                .numeric => {
                    try self.writer.writeAll(",\"value\":");
                    const raw = self.ast.source[start..end];
                    // Parse as number value
                    try self.writeNumericTokenValue(raw);
                },
                .bigint => {
                    try self.writer.writeAll(",\"value\":\"");
                    // BigInt token: strip the trailing 'n'
                    const raw = self.ast.source[start..end];
                    if (raw.len > 0 and raw[raw.len - 1] == 'n') {
                        try self.writeJsonEscaped(raw[0 .. raw.len - 1]);
                    } else {
                        try self.writeJsonEscaped(raw);
                    }
                    try self.writer.writeByte('"');
                },
                .string => {
                    try self.writer.writeAll(",\"value\":\"");
                    const raw = self.ast.source[start..end];
                    // Strip quotes
                    if (raw.len >= 2) {
                        try self.writeJsonEscaped(raw[1 .. raw.len - 1]);
                    }
                    try self.writer.writeByte('"');
                },
                .identifier => {
                    try self.writer.writeAll(",\"value\":\"");
                    try self.writeJsonEscaped(self.ast.source[start..end]);
                    try self.writer.writeByte('"');
                },
                .regex => {
                    try self.writer.writeAll(",\"value\":");
                    try self.writeRegexTokenValue(start, end);
                },
                .template_no_sub, .template_head, .template_middle, .template_tail => {
                    const raw = self.ast.source[start..end];
                    // Get inner content for escape validation (strip delimiters)
                    const content_start: usize = if (raw.len > 0 and (raw[0] == '`' or raw[0] == '}')) 1 else 0;
                    var content_end: usize = raw.len;
                    if (content_end > 0) {
                        if (raw[content_end - 1] == '`') {
                            content_end -= 1;
                        } else if (content_end >= 2 and raw[content_end - 2] == '$' and raw[content_end - 1] == '{') {
                            content_end -= 2;
                        }
                    }
                    const content = if (content_start < content_end) raw[content_start..content_end] else "";
                    // Check for invalid escape sequences
                    if (hasInvalidTemplateEscape(content)) {
                        try self.writer.writeAll(",\"value\":null");
                    } else {
                        // Babel includes the delimiters in the token value
                        try self.writer.writeAll(",\"value\":\"");
                        try self.writeJsonEscaped(raw);
                        try self.writer.writeByte('"');
                    }
                },
                else => {
                    // Keywords: emit value as the source text
                    if (tag.isKeyword()) {
                        try self.writer.writeAll(",\"value\":\"");
                        try self.writeJsonEscaped(self.ast.source[start..end]);
                        try self.writer.writeByte('"');
                    } else {
                        // Operators with value in Babel: = and all assignment/binary operators
                        const info = tokenTypeInfo(tag);
                        if (info.is_assign or info.binop != null or info.prefix) {
                            try self.writer.writeAll(",\"value\":\"");
                            try self.writeJsonEscaped(self.ast.source[start..end]);
                            try self.writer.writeByte('"');
                        }
                    }
                },
            }
        }

        fn writeNumericTokenValue(self: *Self, raw: []const u8) anyerror!void {
            // Strip numeric separators
            var buf: [64]u8 = undefined;
            var len: usize = 0;
            for (raw) |c| {
                if (c != '_' and len < buf.len) {
                    buf[len] = c;
                    len += 1;
                }
            }
            const cleaned = buf[0..len];
            // Try to parse as integer first, then float
            if (cleaned.len > 2 and cleaned[0] == '0') {
                if (cleaned[1] == 'x' or cleaned[1] == 'X') {
                    const v = std.fmt.parseInt(i64, cleaned[2..], 16) catch 0;
                    try self.writeI64(v);
                    return;
                } else if (cleaned[1] == 'o' or cleaned[1] == 'O') {
                    const v = std.fmt.parseInt(i64, cleaned[2..], 8) catch 0;
                    try self.writeI64(v);
                    return;
                } else if (cleaned[1] == 'b' or cleaned[1] == 'B') {
                    const v = std.fmt.parseInt(i64, cleaned[2..], 2) catch 0;
                    try self.writeI64(v);
                    return;
                }
            }
            // Decimal — try integer then float
            if (std.mem.indexOfScalar(u8, cleaned, '.') == null and
                std.mem.indexOfScalar(u8, cleaned, 'e') == null and
                std.mem.indexOfScalar(u8, cleaned, 'E') == null)
            {
                if (std.fmt.parseInt(i64, cleaned, 10)) |v| {
                    try self.writeI64(v);
                    return;
                } else |_| {}
            }
            const f = std.fmt.parseFloat(f64, cleaned) catch 0.0;
            try self.writeF64(f);
        }

        fn writeRegexTokenValue(self: *Self, start: u32, end: u32) anyerror!void {
            const raw = self.ast.source[start..end];
            // Find last / to split pattern and flags
            var last_slash: usize = raw.len;
            var i: usize = raw.len;
            while (i > 1) {
                i -= 1;
                if (raw[i] == '/') {
                    last_slash = i;
                    break;
                }
            }
            const pattern = if (last_slash > 1) raw[1..last_slash] else "";
            const flags = if (last_slash + 1 < raw.len) raw[last_slash + 1 ..] else "";
            try self.writer.writeAll("{\"pattern\":\"");
            try self.writeJsonEscaped(pattern);
            try self.writer.writeAll("\",\"flags\":\"");
            try self.writeJsonEscaped(flags);
            try self.writer.writeAll("\"}");
        }

        fn writeTokenType(self: *Self, tag: Token.Tag) anyerror!void {
            // Map token tag to Babel token type descriptor
            const info = tokenTypeInfo(tag);
            try self.writer.writeAll("{\"label\":\"");
            try self.writer.writeAll(info.label);
            try self.writer.writeByte('"');
            if (info.keyword) |kw| {
                try self.writer.writeAll(",\"keyword\":\"");
                try self.writer.writeAll(kw);
                try self.writer.writeByte('"');
            }
            try self.writer.writeAll(",\"beforeExpr\":");
            try self.writer.writeAll(if (info.before_expr) "true" else "false");
            try self.writer.writeAll(",\"startsExpr\":");
            try self.writer.writeAll(if (info.starts_expr) "true" else "false");
            try self.writer.writeAll(",\"rightAssociative\":false,\"isLoop\":");
            try self.writer.writeAll(if (info.is_loop) "true" else "false");
            try self.writer.writeAll(",\"isAssign\":");
            try self.writer.writeAll(if (info.is_assign) "true" else "false");
            try self.writer.writeAll(",\"prefix\":");
            try self.writer.writeAll(if (info.prefix) "true" else "false");
            try self.writer.writeAll(",\"postfix\":");
            try self.writer.writeAll(if (info.postfix) "true" else "false");
            try self.writer.writeAll(",\"binop\":");
            if (info.binop) |bp| {
                var buf2: [8]u8 = undefined;
                const s = std.fmt.bufPrint(&buf2, "{d}", .{bp}) catch "null";
                try self.writer.writeAll(s);
            } else {
                try self.writer.writeAll("null");
            }
            try self.writer.writeByte('}');
        }
        // === Flow Type Serialization ===

        fn writeFlowTypeAnnotation(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeFlowGenericType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const id_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            try self.writer.writeAll("{\"type\":\"GenericTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeNode(id_node);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll("}");
        }

        fn writeFlowQualifiedTypeIdentifier(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const qualification: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const member_token: TokenIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            _ = member_token;
            try self.writer.writeAll("{\"type\":\"QualifiedTypeIdentifier\",");
            try self.writePosition(self.nodeStart(qualification), self.nodeEnd(idx));
            try self.writer.writeAll(",\"qualification\":");
            try self.writeNode(qualification);
            try self.writer.writeAll(",\"id\":");
            // Write the member identifier
            const tok_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const tok_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const name = self.ast.source[tok_start..tok_end];
            try self.writer.writeAll("{\"type\":\"Identifier\",");
            try self.writePositionWithIdentName(tok_start, tok_end, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"}");
            try self.writer.writeAll("}");
        }

        fn writeFlowNullableType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"NullableTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeFlowUnionOrIntersectionType(self: *Self, idx: NodeIndex, data: Node.Data, type_name: []const u8) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            const items = self.ast.extra_data.items[range_start..range_end];

            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"types\":[");
            for (items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("]}");
        }

        fn writeFlowTypeofType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"TypeofTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"argument\":");
            const arg = data.unary;
            const arg_tag = self.ast.nodes.items(.tag)[@intFromEnum(arg)];
            const arg_main = self.ast.nodes.items(.main_token)[@intFromEnum(arg)];
            const arg_token_tag = self.ast.tokens.items(.tag)[@intFromEnum(arg_main)];
            if (arg_tag == .identifier) {
                // For typeof, reserved type names become their proper type annotation nodes
                const tok_start = self.ast.tokens.items(.start)[@intFromEnum(arg_main)];
                const tok_end = self.ast.tokens.items(.end)[@intFromEnum(arg_main)];
                const name = self.ast.source[tok_start..tok_end];
                if (self.writeFlowTypeofReservedType(arg, name)) |_| {
                    // Written by helper
                } else |_| {
                    // Not a reserved type
                    if (arg_token_tag == .identifier) {
                        // Regular identifier: wrap as GenericTypeAnnotation
                        try self.writer.writeAll("{\"type\":\"GenericTypeAnnotation\",");
                        try self.writePosition(self.nodeStart(arg), self.nodeEnd(arg));
                        try self.writer.writeAll(",\"id\":");
                        try self.writeNode(arg);
                        try self.writer.writeAll(",\"typeParameters\":null}");
                    } else if (!arg_token_tag.isReservedKeyword()) {
                        // Contextual keywords (static, let, get, set, etc.):
                        // wrap as GenericTypeAnnotation like regular identifiers
                        try self.writer.writeAll("{\"type\":\"GenericTypeAnnotation\",");
                        try self.writePosition(self.nodeStart(arg), self.nodeEnd(arg));
                        try self.writer.writeAll(",\"id\":");
                        try self.writeNode(arg);
                        try self.writer.writeAll(",\"typeParameters\":null}");
                    } else {
                        // Reserved keywords (default, etc.): write as bare Identifier
                        try self.writeNode(arg);
                    }
                }
            } else if (arg_tag == .flow_qualified_type_identifier) {
                try self.writer.writeAll("{\"type\":\"GenericTypeAnnotation\",");
                try self.writePosition(self.nodeStart(arg), self.nodeEnd(arg));
                try self.writer.writeAll(",\"id\":");
                try self.writeNode(arg);
                try self.writer.writeAll(",\"typeParameters\":null}");
            } else {
                try self.writeNode(arg);
            }
            try self.writer.writeAll("}");
        }

        /// Write a reserved type for typeof argument. Returns error if not a reserved type name.
        fn writeFlowTypeofReservedType(self: *Self, arg: NodeIndex, name: []const u8) anyerror!void {
            const start = self.nodeStart(arg);
            const end = self.nodeEnd(arg);
            const type_name: ?[]const u8 = if (std.mem.eql(u8, name, "any"))
                "AnyTypeAnnotation"
            else if (std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "boolean"))
                "BooleanTypeAnnotation"
            else if (std.mem.eql(u8, name, "number"))
                "NumberTypeAnnotation"
            else if (std.mem.eql(u8, name, "string"))
                "StringTypeAnnotation"
            else if (std.mem.eql(u8, name, "mixed"))
                "MixedTypeAnnotation"
            else if (std.mem.eql(u8, name, "empty"))
                "EmptyTypeAnnotation"
            else if (std.mem.eql(u8, name, "symbol"))
                "SymbolTypeAnnotation"
            else
                null;

            if (type_name) |tn| {
                try self.writer.writeAll("{\"type\":\"");
                try self.writer.writeAll(tn);
                try self.writer.writeAll("\",");
                try self.writePosition(start, end);
                try self.writer.writeAll("}");
                return;
            }

            if (std.mem.eql(u8, name, "null")) {
                try self.writer.writeAll("{\"type\":\"NullLiteralTypeAnnotation\",");
                try self.writePosition(start, end);
                try self.writer.writeAll("}");
                return;
            }
            if (std.mem.eql(u8, name, "void")) {
                try self.writer.writeAll("{\"type\":\"VoidTypeAnnotation\",");
                try self.writePosition(start, end);
                try self.writer.writeAll("}");
                return;
            }
            if (std.mem.eql(u8, name, "true")) {
                try self.writer.writeAll("{\"type\":\"BooleanLiteralTypeAnnotation\",");
                try self.writePosition(start, end);
                try self.writer.writeAll(",\"value\":true}");
                return;
            }
            if (std.mem.eql(u8, name, "false")) {
                try self.writer.writeAll("{\"type\":\"BooleanLiteralTypeAnnotation\",");
                try self.writePosition(start, end);
                try self.writer.writeAll(",\"value\":false}");
                return;
            }

            return error.NotReservedType;
        }

        fn writeFlowArrayType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ArrayTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"elementType\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeFlowTupleType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            const items = self.ast.extra_data.items[range_start..range_end];

            try self.writer.writeAll("{\"type\":\"TupleTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"types\":[");
            for (items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("]}");
        }

        fn writeFlowSimpleType(self: *Self, idx: NodeIndex, type_name: []const u8) anyerror!void {
            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll("}");
        }

        fn writeFlowNumberLiteralType(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            _ = main_token;
            const node_start = self.nodeStart(idx);
            const node_end = self.nodeEnd(idx);
            const full_raw = self.ast.source[node_start..node_end];
            try self.writer.writeAll("{\"type\":\"NumberLiteralTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            // Parse the numeric value (handle binary 0b, octal 0o, hex 0x, with optional -)
            const val: f64 = blk_num: {
                const is_neg = full_raw.len > 0 and full_raw[0] == '-';
                const abs_raw = if (is_neg) full_raw[1..] else full_raw;
                const sign: f64 = if (is_neg) -1.0 else 1.0;
                if (abs_raw.len > 2) {
                    if (abs_raw[0] == '0' and (abs_raw[1] == 'b' or abs_raw[1] == 'B')) {
                        break :blk_num sign * @as(f64, @floatFromInt(std.fmt.parseInt(i64, abs_raw[2..], 2) catch 0));
                    }
                    if (abs_raw[0] == '0' and (abs_raw[1] == 'o' or abs_raw[1] == 'O')) {
                        break :blk_num sign * @as(f64, @floatFromInt(std.fmt.parseInt(i64, abs_raw[2..], 8) catch 0));
                    }
                    if (abs_raw[0] == '0' and (abs_raw[1] == 'x' or abs_raw[1] == 'X')) {
                        break :blk_num sign * @as(f64, @floatFromInt(std.fmt.parseInt(i64, abs_raw[2..], 16) catch 0));
                    }
                }
                break :blk_num std.fmt.parseFloat(f64, full_raw) catch 0.0;
            };
            try self.writer.writeAll(",\"extra\":{\"rawValue\":");
            try self.writeF64(val);
            try self.writer.writeAll(",\"raw\":\"");
            try self.writeStringContent(full_raw);
            try self.writer.writeAll("\"}");
            try self.writer.writeAll(",\"value\":");
            try self.writeF64(val);
            try self.writer.writeAll(",\"raw\":\"");
            try self.writeStringContent(full_raw);
            try self.writer.writeAll("\"}");
        }

        fn writeFlowStringLiteralType(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const tok_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const tok_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const raw = self.ast.source[tok_start..tok_end];
            try self.writer.writeAll("{\"type\":\"StringLiteralTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"extra\":{\"rawValue\":");
            if (raw.len >= 2) {
                try self.writer.writeAll("\"");
                try self.writeStringContent(raw[1 .. raw.len - 1]);
                try self.writer.writeAll("\"");
            } else {
                try self.writer.writeAll("\"\"");
            }
            try self.writer.writeAll(",\"raw\":\"");
            try self.writeStringContent(raw);
            try self.writer.writeAll("\"}");
            try self.writer.writeAll(",\"value\":");
            // The raw includes quotes; use it directly as JSON string content
            if (raw.len >= 2) {
                try self.writer.writeAll("\"");
                try self.writeStringContent(raw[1 .. raw.len - 1]);
                try self.writer.writeAll("\"");
            } else {
                try self.writer.writeAll("\"\"");
            }
            try self.writer.writeAll(",\"raw\":\"");
            try self.writeStringContent(raw);
            try self.writer.writeAll("\"}");
        }

        fn writeFlowBooleanLiteralType(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const tok_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const tok_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const raw = self.ast.source[tok_start..tok_end];
            const is_true = std.mem.eql(u8, raw, "true");
            try self.writer.writeAll("{\"type\":\"BooleanLiteralTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"value\":");
            try self.writer.writeAll(if (is_true) "true" else "false");
            try self.writer.writeAll(",\"raw\":\"");
            try self.writer.writeAll(raw);
            try self.writer.writeAll("\"}");
        }

        fn writeFlowBigIntLiteralType(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
            const is_negative = tok_tag == .minus;
            const bigint_tok: TokenIndex = if (is_negative) @enumFromInt(@intFromEnum(main_token) + 1) else main_token;
            const bs = self.ast.tokens.items(.start)[@intFromEnum(bigint_tok)];
            const be = self.ast.tokens.items(.end)[@intFromEnum(bigint_tok)];
            const raw = self.ast.source[bs..be];
            const raw_value = if (raw.len > 0 and raw[raw.len - 1] == 'n') raw[0 .. raw.len - 1] else raw;
            // Strip numeric separator underscores for rawValue
            var stripped_buf: [128]u8 = undefined;
            var stripped_len: usize = 0;
            for (raw_value) |ch| {
                if (ch != '_' and stripped_len < stripped_buf.len) {
                    stripped_buf[stripped_len] = ch;
                    stripped_len += 1;
                }
            }
            const stripped = stripped_buf[0..stripped_len];

            try self.writer.writeAll("{\"type\":\"BigIntLiteralTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (is_negative) {
                // Negative bigint: rawValue and value as numbers, raw as string
                // Try i64 first; fall back to f64 for values that overflow
                if (std.fmt.parseInt(i64, stripped, 0)) |num| {
                    var num_buf: [32]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{-num}) catch "0";
                    try self.writer.writeAll(",\"extra\":{\"rawValue\":");
                    try self.writer.writeAll(num_str);
                    try self.writer.writeAll(",\"raw\":\"-");
                    try self.writer.writeAll(raw);
                    try self.writer.writeAll("\"},\"value\":");
                    try self.writer.writeAll(num_str);
                } else |_| {
                    // Overflow: use f64 approximation (like JavaScript's Number())
                    const fval = parseBigIntAsFloat(stripped);
                    var num_buf: [64]u8 = undefined;
                    const num_str = formatJsNumber(-fval, &num_buf);
                    try self.writer.writeAll(",\"extra\":{\"rawValue\":");
                    try self.writer.writeAll(num_str);
                    try self.writer.writeAll(",\"raw\":\"-");
                    try self.writer.writeAll(raw);
                    try self.writer.writeAll("\"},\"value\":");
                    try self.writer.writeAll(num_str);
                }
            } else {
                // Positive bigint: rawValue and value as strings
                try self.writer.writeAll(",\"extra\":{\"rawValue\":\"");
                try self.writer.writeAll(stripped);
                try self.writer.writeAll("\",\"raw\":\"");
                try self.writer.writeAll(raw);
                try self.writer.writeAll("\"},\"value\":\"");
                try self.writer.writeAll(stripped);
                try self.writer.writeAll("\"");
            }
            try self.writer.writeAll("}");
        }

        fn writeFlowObjectType(self: *Self, idx: NodeIndex, tag: Node.Tag, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            const inexact_flag = self.ast.extra_data.items[extra_idx + 2];
            const items = self.ast.extra_data.items[range_start..range_end];
            const is_exact = tag == .flow_exact_object_type;

            try self.writer.writeAll("{\"type\":\"ObjectTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"callProperties\":[");
            // Separate call properties, indexers, internal slots, and regular properties
            var first = true;
            for (items) |item| {
                const item_tag = self.ast.nodes.items(.tag)[@intFromEnum(@as(NodeIndex, @enumFromInt(item)))];
                if (item_tag == .flow_object_type_call_property) {
                    if (!first) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(item));
                    first = false;
                }
            }
            try self.writer.writeAll("],\"properties\":[");
            first = true;
            for (items) |item| {
                const item_tag = self.ast.nodes.items(.tag)[@intFromEnum(@as(NodeIndex, @enumFromInt(item)))];
                if (item_tag == .flow_object_type_property or item_tag == .flow_object_type_spread_property) {
                    if (!first) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(item));
                    first = false;
                }
            }
            try self.writer.writeAll("],\"indexers\":[");
            first = true;
            for (items) |item| {
                const item_tag = self.ast.nodes.items(.tag)[@intFromEnum(@as(NodeIndex, @enumFromInt(item)))];
                if (item_tag == .flow_object_type_indexer) {
                    if (!first) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(item));
                    first = false;
                }
            }
            try self.writer.writeAll("],\"internalSlots\":[");
            first = true;
            for (items) |item| {
                const item_tag = self.ast.nodes.items(.tag)[@intFromEnum(@as(NodeIndex, @enumFromInt(item)))];
                if (item_tag == .flow_object_type_internal_slot) {
                    if (!first) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(item));
                    first = false;
                }
            }
            try self.writer.writeAll("],\"exact\":");
            try self.writer.writeAll(if (is_exact) "true" else "false");
            try self.writer.writeAll(",\"inexact\":");
            try self.writer.writeAll(if (inexact_flag != 0) "true" else "false");
            try self.writer.writeAll("}");
        }

        fn writeFlowObjectTypeProperty(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            _ = main_token;
            const extra_idx = @intFromEnum(data.extra);
            const value_or_func: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const key_token_raw = self.ast.extra_data.items[extra_idx + 1];
            const variance_token_raw = self.ast.extra_data.items[extra_idx + 2];
            const flags = self.ast.extra_data.items[extra_idx + 3];
            const is_optional = (flags & 1) != 0;
            const is_method = (flags & 128) != 0;
            const kind = if (is_method and (flags & 8) != 0)
                "get"
            else if (is_method and (flags & 16) != 0)
                "set"
            else
                "init";

            try self.writer.writeAll("{\"type\":\"ObjectTypeProperty\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"key\":");
            // Write key as identifier
            const key_token: TokenIndex = @enumFromInt(key_token_raw);
            const tok_start = self.ast.tokens.items(.start)[@intFromEnum(key_token)];
            const tok_end = self.ast.tokens.items(.end)[@intFromEnum(key_token)];
            const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(key_token)];
            const name = self.ast.source[tok_start..tok_end];
            if (tok_tag == .string) {
                try self.writer.writeAll("{\"type\":\"StringLiteral\",");
                try self.writePosition(tok_start, tok_end);
                try self.writer.writeAll(",\"value\":");
                if (name.len >= 2) {
                    try self.writer.writeAll("\"");
                    try self.writeStringContent(name[1 .. name.len - 1]);
                    try self.writer.writeAll("\"");
                } else {
                    try self.writer.writeAll("\"\"");
                }
                try self.writer.writeAll("}");
            } else if (tok_tag == .numeric) {
                try self.writer.writeAll("{\"type\":\"NumericLiteral\",");
                try self.writePosition(tok_start, tok_end);
                try self.writer.writeAll(",\"value\":");
                const val = std.fmt.parseFloat(f64, name) catch 0.0;
                try self.writeF64(val);
                try self.writer.writeAll("}");
            } else {
                try self.writer.writeAll("{\"type\":\"Identifier\",");
                try self.writePositionWithIdentName(tok_start, tok_end, name);
                try self.writer.writeAll(",\"name\":\"");
                try self.writeIdentName(name);
                try self.writer.writeAll("\"}");
            }
            try self.writer.writeAll(",\"value\":");
            if (is_method) {
                // For getter/setter methods, the FunctionTypeAnnotation starts at get/set keyword
                // For regular methods, it starts at the function signature (the `(` or `<` token)
                const is_getter_or_setter = (flags & 8) != 0 or (flags & 16) != 0;
                const value_start = if (is_getter_or_setter) self.nodeStart(idx) else self.nodeStart(value_or_func);
                try self.writeFlowFunctionTypeAnnotationAt(value_or_func, value_start);
            } else {
                try self.writeNode(value_or_func);
            }
            try self.writer.writeAll(",\"kind\":\"");
            try self.writer.writeAll(kind);
            try self.writer.writeAll("\"");
            try self.writer.writeAll(",\"method\":");
            try self.writer.writeAll(if (is_method) "true" else "false");
            try self.writer.writeAll(",\"optional\":");
            try self.writer.writeAll(if (is_optional) "true" else "false");
            // Static
            const is_static = (flags & 2) != 0;
            try self.writer.writeAll(",\"static\":");
            try self.writer.writeAll(if (is_static) "true" else "false");
            // Proto
            const is_proto = (flags & 4) != 0;
            try self.writer.writeAll(",\"proto\":");
            try self.writer.writeAll(if (is_proto) "true" else "false");
            // Variance
            if (!is_method and (flags & 32) != 0) {
                // plus variance
                try self.writer.writeAll(",\"variance\":{\"type\":\"Variance\",");
                // Position from variance token
                if (variance_token_raw != 0) {
                    const vt: TokenIndex = @enumFromInt(variance_token_raw);
                    const vs = self.ast.tokens.items(.start)[@intFromEnum(vt)];
                    const ve = self.ast.tokens.items(.end)[@intFromEnum(vt)];
                    try self.writePosition(vs, ve);
                } else {
                    try self.writePosition(self.nodeStart(idx), self.nodeStart(idx) + 1);
                }
                try self.writer.writeAll(",\"kind\":\"plus\"}");
            } else if (!is_method and (flags & 64) != 0) {
                // minus variance
                try self.writer.writeAll(",\"variance\":{\"type\":\"Variance\",");
                if (variance_token_raw != 0) {
                    const vt: TokenIndex = @enumFromInt(variance_token_raw);
                    const vs = self.ast.tokens.items(.start)[@intFromEnum(vt)];
                    const ve = self.ast.tokens.items(.end)[@intFromEnum(vt)];
                    try self.writePosition(vs, ve);
                } else {
                    try self.writePosition(self.nodeStart(idx), self.nodeStart(idx) + 1);
                }
                try self.writer.writeAll(",\"kind\":\"minus\"}");
            } else {
                try self.writer.writeAll(",\"variance\":null");
            }
            try self.writer.writeAll("}");
        }

        fn writeFlowObjectTypeSpreadProperty(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"ObjectTypeSpreadProperty\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"argument\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeFlowObjectTypeIndexer(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const key_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const value_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            const flags = if (extra_idx + 3 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 3]
            else
                @as(u32, 0);
            const is_static = (flags & 1) != 0;

            try self.writer.writeAll("{\"type\":\"ObjectTypeIndexer\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            if (name_token_raw != 0) {
                const nt: TokenIndex = @enumFromInt(name_token_raw);
                const ns = self.ast.tokens.items(.start)[@intFromEnum(nt)];
                const ne = self.ast.tokens.items(.end)[@intFromEnum(nt)];
                const name = self.ast.source[ns..ne];
                try self.writer.writeAll("{\"type\":\"Identifier\",");
                try self.writePositionWithIdentName(ns, ne, name);
                try self.writer.writeAll(",\"name\":\"");
                try self.writeIdentName(name);
                try self.writer.writeAll("\"}");
            } else {
                try self.writer.writeAll("null");
            }
            try self.writer.writeAll(",\"key\":");
            try self.writeNode(key_type);
            try self.writer.writeAll(",\"value\":");
            try self.writeNode(value_type);
            try self.writer.writeAll(",\"variance\":");
            if (self.ast.variance_map.get(@intFromEnum(idx))) |var_node| {
                try self.writeNode(var_node);
            } else {
                try self.writer.writeAll("null");
            }
            try self.writer.writeAll(",\"static\":");
            try self.writer.writeAll(if (is_static) "true" else "false");
            try self.writer.writeAll("}");
        }

        fn writeFlowObjectTypeCallProperty(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const func_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const flags = self.ast.extra_data.items[extra_idx + 1];
            const is_static = (flags & 1) != 0;

            try self.writer.writeAll("{\"type\":\"ObjectTypeCallProperty\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"value\":");
            try self.writeNode(func_type);
            try self.writer.writeAll(",\"static\":");
            try self.writer.writeAll(if (is_static) "true" else "false");
            try self.writer.writeAll("}");
        }

        fn writeFlowObjectTypeInternalSlot(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const value_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const flags = self.ast.extra_data.items[extra_idx + 2];
            const is_optional = (flags & 1) != 0;
            const is_method = self.ast.nodes.items(.tag)[@intFromEnum(value_type)] == .flow_function_type_annotation;

            const nt: TokenIndex = @enumFromInt(name_token_raw);
            const ns = self.ast.tokens.items(.start)[@intFromEnum(nt)];
            const ne = self.ast.tokens.items(.end)[@intFromEnum(nt)];
            const name = self.ast.source[ns..ne];

            try self.writer.writeAll("{\"type\":\"ObjectTypeInternalSlot\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":{\"type\":\"Identifier\",");
            try self.writePositionWithIdentName(ns, ne, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"}");
            try self.writer.writeAll(",\"value\":");
            try self.writeNode(value_type);
            const is_static = (flags & 2) != 0;
            try self.writer.writeAll(",\"optional\":");
            try self.writer.writeAll(if (is_optional) "true" else "false");
            try self.writer.writeAll(",\"static\":");
            try self.writer.writeAll(if (is_static) "true" else "false");
            try self.writer.writeAll(",\"method\":");
            try self.writer.writeAll(if (is_method) "true" else "false");
            try self.writer.writeAll("}");
        }

        fn writeFlowTypeAlias(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writeFlowTypeAliasImpl(idx, data, "TypeAlias");
        }

        fn writeFlowDeclareTypeAlias(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writeFlowTypeAliasImpl(idx, data, "DeclareTypeAlias");
        }

        fn writeFlowTypeAliasImpl(self: *Self, idx: NodeIndex, data: Node.Data, type_name: []const u8) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const right: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

            const nt: TokenIndex = @enumFromInt(name_token_raw);

            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(nt);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll(",\"right\":");
            try self.writeNode(right);
            try self.writer.writeAll("}");
        }

        fn writeFlowOpaqueType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const supertype: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            const impl_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);

            const nt: TokenIndex = @enumFromInt(name_token_raw);

            try self.writer.writeAll("{\"type\":\"OpaqueType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(nt);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll(",\"supertype\":");
            try self.writeNode(supertype);
            try self.writer.writeAll(",\"impltype\":");
            try self.writeNode(impl_type);
            try self.writer.writeAll("}");
        }

        fn writeFlowInterfaceDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const extends_start = self.ast.extra_data.items[extra_idx + 2];
            const extends_end = self.ast.extra_data.items[extra_idx + 3];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 4]);

            const nt: TokenIndex = @enumFromInt(name_token_raw);

            try self.writer.writeAll("{\"type\":\"InterfaceDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(nt);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll(",\"extends\":[");
            const ext_items = self.ast.extra_data.items[extends_start..extends_end];
            for (ext_items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll("}");
        }

        fn writeFlowInterfaceTypeAnnotation(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const extends_start = self.ast.extra_data.items[extra_idx];
            const extends_end = self.ast.extra_data.items[extra_idx + 1];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);

            try self.writer.writeAll("{\"type\":\"InterfaceTypeAnnotation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"extends\":[");
            const ext_items = self.ast.extra_data.items[extends_start..extends_end];
            for (ext_items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll("}");
        }

        fn writeFlowInterfaceExtends(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const id: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);

            try self.writer.writeAll("{\"type\":\"InterfaceExtends\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeNode(id);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll("}");
        }

        fn writeFlowDeclareClass(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const extends_start = self.ast.extra_data.items[extra_idx + 2];
            const extends_end = self.ast.extra_data.items[extra_idx + 3];
            const impl_start = self.ast.extra_data.items[extra_idx + 4];
            const impl_end = self.ast.extra_data.items[extra_idx + 5];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 6]);
            const mixins_start = self.ast.extra_data.items[extra_idx + 7];
            const mixins_end = self.ast.extra_data.items[extra_idx + 8];

            const nt: TokenIndex = @enumFromInt(name_token_raw);

            try self.writer.writeAll("{\"type\":\"DeclareClass\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(nt);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll(",\"extends\":[");
            if (extends_start < extends_end) {
                const ext_items = self.ast.extra_data.items[extends_start..extends_end];
                for (ext_items, 0..) |item, i| {
                    if (i > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(item));
                }
            }
            try self.writer.writeAll("],\"implements\":[");
            const impl_items = self.ast.extra_data.items[impl_start..impl_end];
            for (impl_items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                const impl_node: NodeIndex = @enumFromInt(item);
                const impl_data = self.ast.nodes.items(.data)[@intFromEnum(impl_node)];
                const impl_extra = @intFromEnum(impl_data.extra);
                const impl_id: NodeIndex = @enumFromInt(self.ast.extra_data.items[impl_extra]);
                const impl_tp: NodeIndex = @enumFromInt(self.ast.extra_data.items[impl_extra + 1]);
                try self.writer.writeAll("{\"type\":\"ClassImplements\",");
                try self.writePosition(self.nodeStart(impl_node), self.nodeEnd(impl_node));
                try self.writer.writeAll(",\"id\":");
                try self.writeNode(impl_id);
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(impl_tp);
                try self.writer.writeAll("}");
            }
            try self.writer.writeAll("],\"mixins\":[");
            if (mixins_start < mixins_end) {
                const mixin_items = self.ast.extra_data.items[mixins_start..mixins_end];
                for (mixin_items, 0..) |item, i| {
                    if (i > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(item));
                }
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll("}");
        }

        fn writeFlowDeclareFunction(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const type_params_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const func_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            const predicate: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
            _ = type_params_node;

            const nt: TokenIndex = @enumFromInt(name_token_raw);
            const ns = self.ast.tokens.items(.start)[@intFromEnum(nt)];
            const ne = self.ast.tokens.items(.end)[@intFromEnum(nt)];
            const name = self.ast.source[ns..ne];

            try self.writer.writeAll("{\"type\":\"DeclareFunction\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            // Write identifier with typeAnnotation wrapping the func_type
            try self.writer.writeAll("{\"type\":\"Identifier\",");
            const id_end = if (func_type != .none) self.nodeEnd(func_type) else ne;
            try self.writePositionWithIdentName(ns, id_end, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"");
            if (func_type != .none) {
                try self.writer.writeAll(",\"typeAnnotation\":{\"type\":\"TypeAnnotation\",");
                try self.writePosition(self.nodeStart(func_type), self.nodeEnd(func_type));
                try self.writer.writeAll(",\"typeAnnotation\":");
                try self.writeNode(func_type);
                try self.writer.writeAll("}");
            }
            try self.writer.writeAll("}");
            try self.writer.writeAll(",\"predicate\":");
            try self.writeNode(predicate);
            try self.writer.writeAll("}");
        }

        fn writeFlowDeclareVariable(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const kind_token_raw = self.ast.extra_data.items[extra_idx];
            const name_token_raw = self.ast.extra_data.items[extra_idx + 1];
            const type_annotation: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            _ = kind_token_raw;

            const nt: TokenIndex = @enumFromInt(name_token_raw);

            try self.writer.writeAll("{\"type\":\"DeclareVariable\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            // Identifier with optional typeAnnotation
            const ns = self.ast.tokens.items(.start)[@intFromEnum(nt)];
            const ne = self.ast.tokens.items(.end)[@intFromEnum(nt)];
            const name = self.ast.source[ns..ne];
            try self.writer.writeAll("{\"type\":\"Identifier\",");
            const id_end = if (type_annotation != .none) self.nodeEnd(type_annotation) else ne;
            try self.writePositionWithIdentName(ns, id_end, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"");
            if (type_annotation != .none) {
                try self.writer.writeAll(",\"typeAnnotation\":");
                try self.writeNode(type_annotation);
            }
            try self.writer.writeAll("}");
            try self.writer.writeAll("}");
        }

        fn writeFlowDeclareModule(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const lbrace_token_raw = self.ast.extra_data.items[extra_idx + 1];
            const range_start = self.ast.extra_data.items[extra_idx + 2];
            const range_end = self.ast.extra_data.items[extra_idx + 3];

            const nt: TokenIndex = @enumFromInt(name_token_raw);
            const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(nt)];
            const lbrace_tok: TokenIndex = @enumFromInt(lbrace_token_raw);

            var kind: []const u8 = "CommonJS";
            const body_items = self.ast.extra_data.items[range_start..range_end];
            for (body_items) |item| {
                const child_idx: NodeIndex = @enumFromInt(item);
                const child_tag = self.ast.nodes.items(.tag)[@intFromEnum(child_idx)];
                if (child_tag == .flow_declare_export_all_declaration) {
                    kind = "ES";
                } else if (child_tag == .flow_declare_export_declaration) {
                    const child_data = self.ast.nodes.items(.data)[@intFromEnum(child_idx)];
                    const ced_extra = @intFromEnum(child_data.extra);
                    const decl_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[ced_extra]);
                    const ced_specs_start = self.ast.extra_data.items[ced_extra + 3];
                    const ced_specs_end = self.ast.extra_data.items[ced_extra + 4];
                    if (ced_specs_start < ced_specs_end) {
                        kind = "ES";
                    } else if (decl_node != .none) {
                        const decl_tag = self.ast.nodes.items(.tag)[@intFromEnum(decl_node)];
                        if (decl_tag != .flow_type_alias and decl_tag != .flow_interface_declaration and
                            decl_tag != .flow_declare_interface)
                        {
                            kind = "ES";
                        }
                    }
                } else if (child_tag == .flow_declare_module_exports) {
                    kind = "CommonJS";
                }
            }

            try self.writer.writeAll("{\"type\":\"DeclareModule\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            if (tok_tag == .string) {
                try self.writeStringLiteralFromToken(nt);
            } else {
                try self.writeFlowIdentFromToken(nt);
            }

            const block_start = self.ast.tokens.items(.start)[@intFromEnum(lbrace_tok)];
            const block_end = self.nodeEnd(idx);
            try self.writer.writeAll(",\"body\":{\"type\":\"BlockStatement\",");
            try self.writePosition(block_start, block_end);
            try self.writer.writeAll(",\"body\":[");
            for (body_items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("]}");
            try self.writer.print(",\"kind\":\"{s}\"}}", .{kind});
        }

        fn writeFlowDeclareModuleExports(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const colon_token_raw = self.ast.extra_data.items[extra_idx];
            const type_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const colon_tok: TokenIndex = @enumFromInt(colon_token_raw);
            const colon_start = self.ast.tokens.items(.start)[@intFromEnum(colon_tok)];
            const type_end = self.nodeEnd(type_node);

            try self.writer.writeAll("{\"type\":\"DeclareModuleExports\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writer.writeAll("{\"type\":\"TypeAnnotation\",");
            try self.writePosition(colon_start, type_end);
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(type_node);
            try self.writer.writeAll("}");
            try self.writer.writeAll("}");
        }

        fn writeFlowDeclareExportDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const declaration: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const flags = self.ast.extra_data.items[extra_idx + 1];
            const source_token_raw = self.ast.extra_data.items[extra_idx + 2];
            const specs_start = self.ast.extra_data.items[extra_idx + 3];
            const specs_end = self.ast.extra_data.items[extra_idx + 4];
            const is_default = (flags & 1) != 0;

            try self.writer.writeAll("{\"type\":\"DeclareExportDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));

            const has_specifiers = specs_start < specs_end;

            if (has_specifiers) {
                try self.writer.writeAll(",\"specifiers\":[");
                const specs = self.ast.extra_data.items[specs_start..specs_end];
                for (specs, 0..) |s, j| {
                    if (j > 0) try self.writer.writeAll(",");
                    try self.writeNode(@enumFromInt(s));
                }
                try self.writer.writeAll("],\"source\":");
                if (source_token_raw != 0) {
                    try self.writeStringLiteralFromToken(@enumFromInt(source_token_raw));
                } else {
                    try self.writer.writeAll("null");
                }
                try self.writer.writeAll(",\"declaration\":null");
                try self.writer.writeAll(",\"attributes\":[]");
            } else {
                try self.writer.writeAll(",\"specifiers\":[],\"source\":null,\"attributes\":[],\"declaration\":");
                if (declaration != .none) {
                    try self.writeNode(declaration);
                } else {
                    try self.writer.writeAll("null");
                }
            }

            if (is_default) {
                try self.writer.writeAll(",\"default\":true}");
            } else {
                try self.writer.writeAll(",\"default\":false}");
            }
        }

        /// Extra layout: [source_token, exportKind_flag]
        fn writeFlowDeclareExportAllDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const source_token_raw = self.ast.extra_data.items[extra_idx];
            const export_kind_flag = self.ast.extra_data.items[extra_idx + 1];

            try self.writer.writeAll("{\"type\":\"DeclareExportAllDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            if (export_kind_flag != 0) {
                try self.writer.writeAll(",\"exportKind\":\"type\"");
            } else {
                try self.writer.writeAll(",\"exportKind\":\"value\"");
            }
            try self.writer.writeAll(",\"source\":");
            try self.writeStringLiteralFromToken(@enumFromInt(source_token_raw));
            try self.writer.writeAll(",\"attributes\":[]}");
        }

        fn writeFlowDeclareInterface(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const extends_start = self.ast.extra_data.items[extra_idx + 2];
            const extends_end = self.ast.extra_data.items[extra_idx + 3];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 4]);

            const nt: TokenIndex = @enumFromInt(name_token_raw);

            try self.writer.writeAll("{\"type\":\"DeclareInterface\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(nt);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll(",\"extends\":[");
            const ext_items = self.ast.extra_data.items[extends_start..extends_end];
            for (ext_items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("],\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll("}");
        }

        fn writeFlowDeclareOpaqueType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const supertype: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            const impl_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);

            const nt: TokenIndex = @enumFromInt(name_token_raw);

            try self.writer.writeAll("{\"type\":\"DeclareOpaqueType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(nt);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll(",\"supertype\":");
            try self.writeNode(supertype);
            try self.writer.writeAll(",\"impltype\":");
            try self.writeNode(impl_type);
            try self.writer.writeAll("}");
        }

        fn writeFlowTypeParameter(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const bound: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const default_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            const variance_flag = self.ast.extra_data.items[extra_idx + 2];
            const variance_token_raw = self.ast.extra_data.items[extra_idx + 3];

            // Get the name token: if variance is present, main_token is the variance token,
            // and the name token is the one after it
            const name_token = if (variance_flag != 0)
                @as(TokenIndex, @enumFromInt(@intFromEnum(main_token) + 1))
            else
                main_token;

            const ns = self.ast.tokens.items(.start)[@intFromEnum(name_token)];
            const ne = self.ast.tokens.items(.end)[@intFromEnum(name_token)];
            const name = self.ast.source[ns..ne];

            try self.writer.writeAll("{\"type\":\"TypeParameter\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"");
            try self.writer.writeAll(",\"bound\":");
            try self.writeNode(bound);
            try self.writer.writeAll(",\"default\":");
            try self.writeNode(default_type);
            try self.writer.writeAll(",\"variance\":");
            if (variance_flag != 0 and variance_token_raw != 0) {
                const vt: TokenIndex = @enumFromInt(variance_token_raw);
                const vs = self.ast.tokens.items(.start)[@intFromEnum(vt)];
                const ve = self.ast.tokens.items(.end)[@intFromEnum(vt)];
                try self.writer.writeAll("{\"type\":\"Variance\",");
                try self.writePosition(vs, ve);
                try self.writer.writeAll(",\"kind\":\"");
                try self.writer.writeAll(if (variance_flag == 1) "plus" else "minus");
                try self.writer.writeAll("\"}");
            } else {
                try self.writer.writeAll("null");
            }
            try self.writer.writeAll("}");
        }

        fn writeFlowTypeParameterDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            const items = self.ast.extra_data.items[range_start..range_end];

            try self.writer.writeAll("{\"type\":\"TypeParameterDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"params\":[");
            for (items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("]}");
        }

        fn writeFlowTypeParameterInstantiation(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            const items = self.ast.extra_data.items[range_start..range_end];

            try self.writer.writeAll("{\"type\":\"TypeParameterInstantiation\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"params\":[");
            for (items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("]}");
        }

        fn writeFlowTypeCastExpression(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const expr: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const ty: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);

            try self.writer.writeAll("{\"type\":\"TypeCastExpression\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"expression\":");
            try self.writeChildIsolated(expr);
            try self.writer.writeAll(",\"typeAnnotation\":");
            // Wrap in TypeAnnotation — start includes the colon
            const type_start = self.nodeStart(ty);
            const colon_start = if (type_start >= 2) type_start - 2 else type_start;
            // Scan backwards from type start to find the colon
            var ann_start = type_start;
            if (type_start > 0) {
                var pos = type_start - 1;
                while (pos > 0) : (pos -= 1) {
                    const c = self.ast.source[pos];
                    if (c == ':') {
                        ann_start = pos;
                        break;
                    }
                    if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
                }
                if (pos == 0 and self.ast.source[0] == ':') ann_start = 0;
            }
            _ = colon_start;
            try self.writer.writeAll("{\"type\":\"TypeAnnotation\",");
            try self.writePosition(ann_start, self.nodeEnd(ty));
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(ty);
            try self.writer.writeAll("}");
            // Write extra object with parenthesized info
            try self.writeExtraObject(null);
            try self.writer.writeAll("}");
        }

        fn writeFlowFunctionTypeAnnotation(self: *Self, idx: NodeIndex, _: Node.Data) anyerror!void {
            try self.writeFlowFunctionTypeAnnotationAt(idx, self.nodeStart(idx));
        }

        /// Write FunctionTypeAnnotation with an overridden start position (used for method properties)
        fn writeFlowFunctionTypeAnnotationAt(self: *Self, idx: NodeIndex, start_pos: u32) anyerror!void {
            const data = self.ast.nodes.items(.data)[@intFromEnum(idx)];
            const extra_idx = @intFromEnum(data.extra);
            const params_start = self.ast.extra_data.items[extra_idx];
            const params_end = self.ast.extra_data.items[extra_idx + 1];
            const return_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 2]);
            const rest_param: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 3]);
            const type_params: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 4]);
            const this_param: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 5]);

            const param_items = self.ast.extra_data.items[params_start..params_end];

            try self.writer.writeAll("{\"type\":\"FunctionTypeAnnotation\",");
            try self.writePosition(start_pos, self.nodeEnd(idx));
            try self.writer.writeAll(",\"params\":[");
            for (param_items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("],\"rest\":");
            try self.writeNode(rest_param);
            try self.writer.writeAll(",\"typeParameters\":");
            try self.writeNode(type_params);
            try self.writer.writeAll(",\"returnType\":");
            try self.writeNode(return_type);
            try self.writer.writeAll(",\"this\":");
            try self.writeNode(this_param);
            try self.writer.writeAll("}");
        }

        fn writeFlowFunctionTypeParam(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const ty: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const flags = self.ast.extra_data.items[extra_idx + 1];
            const is_optional = (flags & 1) != 0;
            const is_unnamed = (flags & 2) != 0;

            // Check if this has a name — use the unnamed flag if set,
            // otherwise use heuristic based on token tag
            const has_name = if (is_unnamed)
                false
            else blk: {
                const tok_tag = self.ast.tokens.items(.tag)[@intFromEnum(main_token)];
                break :blk tok_tag == .identifier or tok_tag.isKeyword();
            };

            try self.writer.writeAll("{\"type\":\"FunctionTypeParam\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"name\":");
            if (has_name) {
                try self.writeFlowIdentFromToken(main_token);
            } else {
                try self.writer.writeAll("null");
            }
            try self.writer.writeAll(",\"optional\":");
            try self.writer.writeAll(if (is_optional) "true" else "false");
            try self.writer.writeAll(",\"typeAnnotation\":");
            try self.writeNode(ty);
            try self.writer.writeAll("}");
        }

        fn writeFlowIndexedAccessType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const object_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const index_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);

            try self.writer.writeAll("{\"type\":\"IndexedAccessType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"objectType\":");
            try self.writeNode(object_type);
            try self.writer.writeAll(",\"indexType\":");
            try self.writeNode(index_type);
            try self.writer.writeAll("}");
        }

        fn writeFlowOptionalIndexedAccessType(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const object_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx]);
            const index_type: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);
            // Check if this is a directly optional access (?.) or a chained non-optional access ([])
            const main_token = self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
            const is_optional = self.ast.tokens.items(.tag)[@intFromEnum(main_token)] == .optional_chain;

            try self.writer.writeAll("{\"type\":\"OptionalIndexedAccessType\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"objectType\":");
            try self.writeNode(object_type);
            try self.writer.writeAll(",\"indexType\":");
            try self.writeNode(index_type);
            if (is_optional) {
                try self.writer.writeAll(",\"optional\":true}");
            } else {
                try self.writer.writeAll(",\"optional\":false}");
            }
        }

        fn writeFlowDeclaredPredicate(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            try self.writer.writeAll("{\"type\":\"DeclaredPredicate\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"value\":");
            try self.writeNode(data.unary);
            try self.writer.writeAll("}");
        }

        fn writeFlowVariance(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            const tok_start = self.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const tok_end = self.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const text = self.ast.source[tok_start..tok_end];
            try self.writer.writeAll("{\"type\":\"Variance\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"kind\":\"");
            if (std.mem.eql(u8, text, "+")) {
                try self.writer.writeAll("plus");
            } else {
                try self.writer.writeAll("minus");
            }
            try self.writer.writeAll("\"}");
        }

        fn writeFlowEnumDeclaration(self: *Self, idx: NodeIndex, data: Node.Data) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = self.ast.extra_data.items[extra_idx];
            const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_idx + 1]);

            const nt: TokenIndex = @enumFromInt(name_token_raw);

            try self.writer.writeAll("{\"type\":\"EnumDeclaration\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(nt);
            try self.writer.writeAll(",\"body\":");
            try self.writeNode(body);
            try self.writer.writeAll("}");
        }

        fn writeFlowEnumBody(self: *Self, idx: NodeIndex, data: Node.Data, type_name: []const u8) anyerror!void {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = self.ast.extra_data.items[extra_idx];
            const range_end = self.ast.extra_data.items[extra_idx + 1];
            const has_unknown = self.ast.extra_data.items[extra_idx + 2];
            const explicit_type = if (extra_idx + 3 < self.ast.extra_data.items.len)
                self.ast.extra_data.items[extra_idx + 3]
            else
                0;
            const items = self.ast.extra_data.items[range_start..range_end];

            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"members\":[");
            for (items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writeNode(@enumFromInt(item));
            }
            try self.writer.writeAll("],\"explicitType\":");
            try self.writer.writeAll(if (explicit_type != 0) "true" else "false");
            try self.writer.writeAll(",\"hasUnknownMembers\":");
            try self.writer.writeAll(if (has_unknown != 0) "true" else "false");
            try self.writer.writeAll("}");
        }

        fn writeFlowEnumMember(self: *Self, idx: NodeIndex, main_token: TokenIndex, data: Node.Data, type_name: []const u8) anyerror!void {
            const nt = main_token;
            try self.writer.writeAll("{\"type\":\"");
            try self.writer.writeAll(type_name);
            try self.writer.writeAll("\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(nt);
            try self.writer.writeAll(",\"init\":");
            // Write the init value
            const val_token = data.token;
            const vs = self.ast.tokens.items(.start)[@intFromEnum(val_token)];
            const ve = self.ast.tokens.items(.end)[@intFromEnum(val_token)];
            const val_tag = self.ast.tokens.items(.tag)[@intFromEnum(val_token)];
            const val_text = self.ast.source[vs..ve];
            if (val_tag == .string) {
                try self.writer.writeAll("{\"type\":\"StringLiteral\",");
                try self.writePosition(vs, ve);
                try self.writer.writeAll(",\"extra\":{\"rawValue\":");
                if (val_text.len >= 2) {
                    try self.writer.writeAll("\"");
                    try self.writeStringContent(val_text[1 .. val_text.len - 1]);
                    try self.writer.writeAll("\"");
                } else {
                    try self.writer.writeAll("\"\"");
                }
                try self.writer.writeAll(",\"raw\":\"");
                try self.writeStringContent(val_text);
                try self.writer.writeAll("\"},\"value\":");
                if (val_text.len >= 2) {
                    try self.writer.writeAll("\"");
                    try self.writeStringContent(val_text[1 .. val_text.len - 1]);
                    try self.writer.writeAll("\"");
                } else {
                    try self.writer.writeAll("\"\"");
                }
                try self.writer.writeAll("}");
            } else if (val_tag == .numeric) {
                try self.writer.writeAll("{\"type\":\"NumericLiteral\",");
                try self.writePosition(vs, ve);
                try self.writer.writeAll(",\"extra\":{\"rawValue\":");
                const v = std.fmt.parseFloat(f64, val_text) catch 0.0;
                try self.writeF64(v);
                try self.writer.writeAll(",\"raw\":\"");
                try self.writer.writeAll(val_text);
                try self.writer.writeAll("\"},\"value\":");
                try self.writeF64(v);
                try self.writer.writeAll("}");
            } else if (val_tag == .kw_true or val_tag == .kw_false) {
                try self.writer.writeAll("{\"type\":\"BooleanLiteral\",");
                try self.writePosition(vs, ve);
                try self.writer.writeAll(",\"value\":");
                try self.writer.writeAll(val_text);
                try self.writer.writeAll("}");
            } else {
                try self.writer.writeAll("null");
            }
            try self.writer.writeAll("}");
        }

        fn writeFlowEnumDefaultMember(self: *Self, idx: NodeIndex, main_token: TokenIndex) anyerror!void {
            try self.writer.writeAll("{\"type\":\"EnumDefaultedMember\",");
            try self.writePosition(self.nodeStart(idx), self.nodeEnd(idx));
            try self.writer.writeAll(",\"id\":");
            try self.writeFlowIdentFromToken(main_token);
            try self.writer.writeAll("}");
        }

        /// Helper: write an Identifier node from a token
        fn writeFlowIdentFromToken(self: *Self, token: TokenIndex) anyerror!void {
            const ns = self.ast.tokens.items(.start)[@intFromEnum(token)];
            const ne = self.ast.tokens.items(.end)[@intFromEnum(token)];
            const name = self.ast.source[ns..ne];
            try self.writer.writeAll("{\"type\":\"Identifier\",");
            try self.writePositionWithIdentName(ns, ne, name);
            try self.writer.writeAll(",\"name\":\"");
            try self.writeIdentName(name);
            try self.writer.writeAll("\"}");
        }

        /// Helper: write predicate on node if present (for functions/arrows)
        fn writeFlowPredicateForNode(self: *Self, idx: NodeIndex) anyerror!void {
            if (self.ast.predicate_map.get(@intFromEnum(idx))) |pred| {
                try self.writer.writeAll(",\"predicate\":");
                try self.writeNode(pred);
            } else if (self.ast.language == .flow) {
                try self.writer.writeAll(",\"predicate\":null");
            }
        }

        /// Helper: write type annotation on node if present
        fn writeFlowTypeAnnotationForNode(self: *Self, idx: NodeIndex) anyerror!void {
            if (self.ast.language != .flow and !self.ast.language.isTypeScript()) return;
            if (self.ast.type_annotations.get(@intFromEnum(idx))) |type_ann| {
                if (type_ann != .none and @intFromEnum(type_ann) < self.ast.nodes.len) {
                    try self.writer.writeAll(",\"typeAnnotation\":");
                    try self.writeNode(type_ann);
                }
            }
        }

        /// Helper: write returnType and typeParameters from side tables, with null fallback
        fn writeReturnTypeAndTypeParams(self: *Self, idx: NodeIndex) anyerror!void {
            if (self.ast.return_types.get(@intFromEnum(idx))) |ret_type| {
                try self.writer.writeAll(",\"returnType\":");
                try self.writeNode(ret_type);
            } else {
                try self.writer.writeAll(",\"returnType\":null");
            }
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(tp);
            } else {
                try self.writer.writeAll(",\"typeParameters\":null");
            }
        }

        /// Helper: write returnType and typeParameters from side tables, omitting when absent
        fn writeOptionalReturnTypeAndTypeParams(self: *Self, idx: NodeIndex) anyerror!void {
            if (self.ast.return_types.get(@intFromEnum(idx))) |ret_type| {
                try self.writer.writeAll(",\"returnType\":");
                try self.writeNode(ret_type);
            }
            if (self.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try self.writer.writeAll(",\"typeParameters\":");
                try self.writeNode(tp);
            }
        }

        /// Helper: write superTypeParameters and implements from side tables for class nodes
        fn writeClassTypeExtras(self: *Self, idx: NodeIndex) anyerror!void {
            if (self.ast.super_type_parameters.get(@intFromEnum(idx))) |stp| {
                try self.writer.writeAll(",\"superTypeArguments\":");
                try self.writeNode(stp);
            }
            if (self.ast.implements_list.get(@intFromEnum(idx))) |impl_range| {
                try self.writer.writeAll(",\"implements\":[");
                const impl_items = self.ast.extra_data.items[impl_range.start..impl_range.end];
                for (impl_items, 0..) |item, i| {
                    if (i > 0) try self.writer.writeAll(",");
                    const impl_node: NodeIndex = @enumFromInt(item);
                    const impl_data = self.ast.nodes.items(.data)[@intFromEnum(impl_node)];
                    const impl_tag = self.ast.nodes.items(.tag)[@intFromEnum(impl_node)];
                    if (self.ast.language.isTypeScript()) {
                        const impl_expr = if (impl_tag == .ts_type_reference) impl_data.binary.lhs else impl_node;
                        const impl_args = if (impl_tag == .ts_type_reference) impl_data.binary.rhs else @as(NodeIndex, .none);
                        try self.writer.writeAll("{\"type\":\"TSClassImplements\",");
                        try self.writePosition(self.nodeStart(impl_node), self.nodeEnd(impl_node));
                        try self.writer.writeAll(",\"expression\":");
                        try self.writeTsEntityNameAsExpr(impl_expr);
                        try self.writer.writeAll(",\"typeArguments\":");
                        try self.writeNode(impl_args);
                    } else {
                        const impl_extra = @intFromEnum(impl_data.extra);
                        const impl_id: NodeIndex = @enumFromInt(self.ast.extra_data.items[impl_extra]);
                        const impl_tp: NodeIndex = @enumFromInt(self.ast.extra_data.items[impl_extra + 1]);
                        try self.writer.writeAll("{\"type\":\"ClassImplements\",");
                        try self.writePosition(self.nodeStart(impl_node), self.nodeEnd(impl_node));
                        try self.writer.writeAll(",\"id\":");
                        try self.writeNode(impl_id);
                        try self.writer.writeAll(",\"typeParameters\":");
                        try self.writeNode(impl_tp);
                    }
                    try self.writer.writeAll("}");
                }
                try self.writer.writeAll("]");
            }
        }

        /// Write TypeScript class member modifier properties (accessibility, readonly, abstract, declare, override)
        fn writeTsClassModifiers(self: *Self, idx: NodeIndex) anyerror!void {
            if (self.ast.ts_class_modifiers.get(@intFromEnum(idx))) |mods| {
                if (mods & TS_MOD_PUBLIC != 0) {
                    try self.writer.writeAll(",\"accessibility\":\"public\"");
                } else if (mods & TS_MOD_PRIVATE != 0) {
                    try self.writer.writeAll(",\"accessibility\":\"private\"");
                } else if (mods & TS_MOD_PROTECTED != 0) {
                    try self.writer.writeAll(",\"accessibility\":\"protected\"");
                }
                if (mods & Parser.TS_MOD_STATIC != 0) try self.writer.writeAll(",\"static\":true");
                if (mods & TS_MOD_READONLY != 0) try self.writer.writeAll(",\"readonly\":true");
                if (mods & TS_MOD_ABSTRACT != 0) try self.writer.writeAll(",\"abstract\":true");
                if (mods & TS_MOD_DECLARE != 0) try self.writer.writeAll(",\"declare\":true");
                if (mods & TS_MOD_OVERRIDE != 0) try self.writer.writeAll(",\"override\":true");
                if (mods & TS_MOD_IN != 0) try self.writer.writeAll(",\"in\":true");
                if (mods & TS_MOD_OUT != 0) try self.writer.writeAll(",\"out\":true");
            }
        }

        /// Emit `,"optional":true` if the node is marked as a TS optional parameter.
        fn writeTsOptionalFlag(self: *Self, idx: NodeIndex) anyerror!void {
            if (self.ast.ts_optional_params.contains(@intFromEnum(idx))) {
                try self.writer.writeAll(",\"optional\":true");
            } else if (self.ast.language.isTypeScript()) {
                try self.writer.writeAll(",\"optional\":false");
            }
        }

        fn writeNodeComments(self: *Self, idx: NodeIndex) anyerror!void {
            const key = @intFromEnum(idx);
            if (self.ast.leading_comments.get(key)) |range| {
                try self.writer.writeAll(",\"leadingComments\":");
                try self.writeCommentArray(range);
            }
            if (self.ast.inner_comments.get(key)) |range| {
                try self.writer.writeAll(",\"innerComments\":");
                try self.writeCommentArray(range);
            }
            if (self.ast.trailing_comments.get(key)) |range| {
                try self.writer.writeAll(",\"trailingComments\":");
                try self.writeCommentArray(range);
            }
        }
    };
}

/// Parse a hex/decimal bigint string as an f64 (for values that overflow i64).
fn parseBigIntAsFloat(s: []const u8) f64 {
    if (s.len > 2 and (s[1] == 'x' or s[1] == 'X')) {
        // Hex
        var result: f64 = 0;
        for (s[2..]) |ch| {
            if (ch == '_') continue;
            const digit: f64 = switch (ch) {
                '0'...'9' => @floatFromInt(ch - '0'),
                'a'...'f' => @floatFromInt(ch - 'a' + 10),
                'A'...'F' => @floatFromInt(ch - 'A' + 10),
                else => 0,
            };
            result = result * 16.0 + digit;
        }
        return result;
    }
    // Decimal
    var result: f64 = 0;
    for (s) |ch| {
        if (ch == '_') continue;
        if (ch >= '0' and ch <= '9') {
            result = result * 10.0 + @as(f64, @floatFromInt(ch - '0'));
        }
    }
    return result;
}

/// Format an f64 in JavaScript-compatible number format (no trailing zeros, no +).
fn formatJsNumber(val: f64, buf: []u8) []const u8 {
    // Use scientific notation detection like JavaScript
    const abs_val = @abs(val);
    if (abs_val == 0) {
        return "0";
    }

    // JavaScript uses exponential notation for very large numbers
    // For bigint approximations, the number is large so use the compact format
    const result = std.fmt.bufPrint(buf, "{d}", .{val}) catch return "0";
    return result;
}
