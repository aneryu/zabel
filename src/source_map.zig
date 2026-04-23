const std = @import("std");

/// Base64 characters used for VLQ encoding (RFC 4648 alphabet)
pub const VLQ_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Reverse lookup: base64 char -> 6-bit value. 255 = invalid.
const VLQ_DECODE: [128]u8 = blk: {
    var table = [_]u8{255} ** 128;
    for (VLQ_CHARS, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    break :blk table;
};

/// Encode a signed integer as Base64 VLQ and append to `out`.
/// VLQ format: sign bit in LSB, then groups of 5 bits (LSB first)
/// with continuation bit (0x20) in the high bit of each group except the last.
/// `allocator` must be the allocator that manages `out`'s memory.
pub fn encodeVLQ(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
    // Convert signed to unsigned VLQ: low bit = sign, remaining bits = magnitude
    const unsigned: u32 = if (value < 0)
        @as(u32, @intCast(-value)) << 1 | 1
    else
        @as(u32, @intCast(value)) << 1;

    var v = unsigned;
    var scratch: [8]u8 = undefined;
    var len: usize = 0;
    while (true) {
        var digit: u32 = v & 0x1f; // take 5 bits
        v >>= 5;
        if (v > 0) {
            digit |= 0x20; // set continuation bit
        }
        scratch[len] = VLQ_CHARS[digit];
        len += 1;
        if (v == 0) break;
    }
    const old_len = out.items.len;
    try out.resize(allocator, old_len + len);
    @memcpy(out.items[old_len..][0..len], scratch[0..len]);
}

/// Decode a Base64 VLQ integer from `data` starting at `pos`.
/// Advances `pos` past the consumed bytes.
pub fn decodeVLQ(data: []const u8, pos: *usize) i32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (pos.* < data.len) {
        const c = data[pos.*];
        pos.* += 1;
        if (c >= 128) break; // out of ASCII range
        const digit = VLQ_DECODE[c];
        if (digit == 255) break; // invalid char
        result |= @as(u32, digit & 0x1f) << shift;
        shift += 5;
        if (digit & 0x20 == 0) break; // no continuation bit
    }
    // Decode sign from low bit
    if (result & 1 != 0) {
        return -@as(i32, @intCast(result >> 1));
    } else {
        return @as(i32, @intCast(result >> 1));
    }
}

/// A single source mapping entry.
pub const Mapping = struct {
    gen_line: u32,
    gen_col: u32,
    orig_line: u32,
    orig_col: u32,
    source_index: u16 = 0,
    name_index: ?u16 = null,
};

/// Builds a Source Map v3 JSON document.
pub const SourceMapBuilder = struct {
    allocator: std.mem.Allocator,
    mappings: std.ArrayList(Mapping),
    sources: std.ArrayList([]const u8),
    sources_content: std.ArrayList([]const u8),
    names: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) SourceMapBuilder {
        return .{
            .allocator = allocator,
            .mappings = .empty,
            .sources = .empty,
            .sources_content = .empty,
            .names = .empty,
        };
    }

    pub fn deinit(self: *SourceMapBuilder) void {
        self.mappings.deinit(self.allocator);
        for (self.sources.items) |s| self.allocator.free(s);
        self.sources.deinit(self.allocator);
        for (self.sources_content.items) |s| self.allocator.free(s);
        self.sources_content.deinit(self.allocator);
        for (self.names.items) |s| self.allocator.free(s);
        self.names.deinit(self.allocator);
    }

    /// Add a source file. Returns its index for use in Mapping.source_index.
    pub fn addSource(self: *SourceMapBuilder, name: []const u8, content: []const u8) !u16 {
        const idx: u16 = @intCast(self.sources.items.len);
        try self.sources.append(self.allocator, try self.allocator.dupe(u8, name));
        try self.sources_content.append(self.allocator, try self.allocator.dupe(u8, content));
        return idx;
    }

    /// Add a mapping entry. Entries should be added in gen_line/gen_col order for
    /// correct VLQ diff encoding; finalize() sorts them automatically.
    pub fn addMapping(self: *SourceMapBuilder, mapping: Mapping) void {
        self.mappings.append(self.allocator, mapping) catch {};
    }

    /// Produce the full Source Map v3 JSON string. Caller owns the returned slice.
    pub fn finalize(self: *SourceMapBuilder) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        var aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &out);
        const w = &aw.writer;

        // Sort mappings by (gen_line, gen_col)
        std.mem.sort(Mapping, self.mappings.items, {}, mappingLessThan);

        try w.writeAll("{\"version\":3,\"sources\":[");

        for (self.sources.items, 0..) |src, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonString(w, src);
        }

        try w.writeAll("],\"sourcesContent\":[");

        for (self.sources_content.items, 0..) |sc, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonString(w, sc);
        }

        try w.writeAll("],\"names\":[");

        for (self.names.items, 0..) |name, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonString(w, name);
        }

        try w.writeAll("],\"mappings\":\"");

        // Encode mappings as VLQ
        var vlq_buf: std.ArrayList(u8) = .empty;
        defer vlq_buf.deinit(self.allocator);
        try encodeMappings(self.allocator, self.mappings.items, &vlq_buf);
        try w.writeAll(vlq_buf.items);

        try w.writeAll("\"}");

        out = aw.toArrayList();
        return try out.toOwnedSlice(self.allocator);
    }
};

fn mappingLessThan(_: void, a: Mapping, b: Mapping) bool {
    if (a.gen_line != b.gen_line) return a.gen_line < b.gen_line;
    return a.gen_col < b.gen_col;
}

/// Encode the mappings array as a VLQ string (diff-encoded, `;` for line breaks,
/// `,` between segments on the same line).
fn encodeMappings(allocator: std.mem.Allocator, mappings: []const Mapping, out: *std.ArrayList(u8)) !void {
    var prev_gen_line: u32 = 0;
    var prev_gen_col: i32 = 0;
    var prev_orig_line: i32 = 0;
    var prev_orig_col: i32 = 0;
    var prev_source: i32 = 0;
    var prev_name: i32 = 0;

    var first_on_line = true;

    for (mappings) |m| {
        // Emit `;` for each skipped generated line
        while (prev_gen_line < m.gen_line) {
            try out.append(allocator, ';');
            prev_gen_line += 1;
            prev_gen_col = 0;
            first_on_line = true;
        }

        if (!first_on_line) {
            try out.append(allocator, ',');
        }
        first_on_line = false;

        // 1. Generated column (delta)
        const delta_gen_col = @as(i32, @intCast(m.gen_col)) - prev_gen_col;
        try encodeVLQ(out, allocator, delta_gen_col);
        prev_gen_col = @as(i32, @intCast(m.gen_col));

        // 2. Source file index (delta)
        const delta_source = @as(i32, @intCast(m.source_index)) - prev_source;
        try encodeVLQ(out, allocator, delta_source);
        prev_source = @as(i32, @intCast(m.source_index));

        // 3. Original line (delta)
        const delta_orig_line = @as(i32, @intCast(m.orig_line)) - prev_orig_line;
        try encodeVLQ(out, allocator, delta_orig_line);
        prev_orig_line = @as(i32, @intCast(m.orig_line));

        // 4. Original column (delta)
        const delta_orig_col = @as(i32, @intCast(m.orig_col)) - prev_orig_col;
        try encodeVLQ(out, allocator, delta_orig_col);
        prev_orig_col = @as(i32, @intCast(m.orig_col));

        // 5. Names index (optional, delta)
        if (m.name_index) |ni| {
            const delta_name = @as(i32, @intCast(ni)) - prev_name;
            try encodeVLQ(out, allocator, delta_name);
            prev_name = @as(i32, @intCast(ni));
        }
    }
}

/// Write a JSON-escaped string (including surrounding quotes).
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                // Other control characters as \uXXXX
                try w.print("\\u{x:0>4}", .{c});
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}
