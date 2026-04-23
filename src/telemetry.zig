const std = @import("std");

const Allocator = std.mem.Allocator;

pub const LogLevel = enum(u8) {
    off = 0,
    err = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn parse(raw: []const u8) ?LogLevel {
        if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
        if (std.ascii.eqlIgnoreCase(raw, "error")) return .err;
        if (std.ascii.eqlIgnoreCase(raw, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(raw, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(raw, "trace")) return .trace;
        return null;
    }

    pub fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .off => "off",
            .err => "error",
            .info => "info",
            .debug => "debug",
            .trace => "trace",
        };
    }

    pub fn allows(self: LogLevel, target: LogLevel) bool {
        if (self == .off or target == .off) return false;
        return @intFromEnum(target) <= @intFromEnum(self);
    }
};

pub const TraceLevel = enum(u8) {
    off = 0,
    fixture = 1,
    pass = 2,

    pub fn parse(raw: []const u8) ?TraceLevel {
        if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
        if (std.ascii.eqlIgnoreCase(raw, "fixture")) return .fixture;
        if (std.ascii.eqlIgnoreCase(raw, "pass")) return .pass;
        return null;
    }

    pub fn allows(self: TraceLevel, target: TraceLevel) bool {
        if (self == .off or target == .off) return false;
        return @intFromEnum(target) <= @intFromEnum(self);
    }
};

pub const OutputFormat = enum {
    text,
    json,
    both,

    pub fn parse(raw: []const u8) ?OutputFormat {
        if (std.ascii.eqlIgnoreCase(raw, "text")) return .text;
        if (std.ascii.eqlIgnoreCase(raw, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(raw, "both")) return .both;
        return null;
    }

    pub fn wantsText(self: OutputFormat) bool {
        return self == .text or self == .both;
    }

    pub fn wantsJson(self: OutputFormat) bool {
        return self == .json or self == .both;
    }
};

pub const SpanOutcome = enum {
    ok,
    err,
    fail,
    skip,

    pub fn asString(self: SpanOutcome) []const u8 {
        return switch (self) {
            .ok => "ok",
            .err => "error",
            .fail => "fail",
            .skip => "skip",
        };
    }
};

pub const FieldValue = union(enum) {
    string: []const u8,
    unsigned: u64,
    signed: i64,
    boolean: bool,
};

pub const Field = struct {
    key: []const u8,
    value: FieldValue,

    pub fn string(key: []const u8, value: []const u8) Field {
        return .{ .key = key, .value = .{ .string = value } };
    }

    pub fn unsigned(key: []const u8, value: u64) Field {
        return .{ .key = key, .value = .{ .unsigned = value } };
    }

    pub fn signed(key: []const u8, value: i64) Field {
        return .{ .key = key, .value = .{ .signed = value } };
    }

    pub fn boolean(key: []const u8, value: bool) Field {
        return .{ .key = key, .value = .{ .boolean = value } };
    }
};

pub const TelemetryConfig = struct {
    log_level: LogLevel = .off,
    trace_level: TraceLevel = .off,
    log_format: OutputFormat = .text,
    trace_format: OutputFormat = .both,
    log_path: ?[]const u8 = null,
    trace_events_path: ?[]const u8 = null,
    trace_summary_path: ?[]const u8 = null,
    run_label: []const u8 = "run",
    include_timestamps: bool = true,

    pub fn isEnabled(self: TelemetryConfig) bool {
        return self.log_level != .off or self.trace_level != .off;
    }
};

pub const SpanHandle = struct {
    started_ns: u64,
    started_ms: i64,
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_span_id: ?[16]u8,
    kind: []const u8,
    name: []const u8,
};

const Artifact = struct {
    kind: []const u8,
    path: []const u8,
};

const FailureSummary = struct {
    kind: []const u8,
    name: []const u8,
    message: ?[]const u8 = null,
};

const SlowSpan = struct {
    kind: []const u8,
    name: []const u8,
    status: []const u8,
    duration_ns: u64,
    trace_id: [32]u8,
    span_id: [16]u8,
};

pub const TelemetrySession = struct {
    allocator: Allocator,
    io: std.Io,
    config: TelemetryConfig,
    started_at_ms: i64,
    started_ns: u64,
    mutex: std.Io.Mutex = .init,

    text_file: ?std.Io.File = null,
    events_file: ?std.Io.File = null,
    summary_path: ?[]const u8 = null,
    auto_output_dir: ?[]const u8 = null,

    counts: std.StringHashMapUnmanaged(u64) = .empty,
    failures: std.ArrayListUnmanaged(FailureSummary) = .empty,
    artifacts: std.ArrayListUnmanaged(Artifact) = .empty,
    slowest_spans: std.ArrayListUnmanaged(SlowSpan) = .empty,

    pub fn init(allocator: Allocator, io: std.Io, config: TelemetryConfig) !TelemetrySession {
        var owned_config = config;
        owned_config.run_label = try allocator.dupe(u8, config.run_label);
        if (config.log_path) |path| {
            owned_config.log_path = try allocator.dupe(u8, path);
        }
        if (config.trace_events_path) |path| {
            owned_config.trace_events_path = try allocator.dupe(u8, path);
        }
        if (config.trace_summary_path) |path| {
            owned_config.trace_summary_path = try allocator.dupe(u8, path);
        }

        var session = TelemetrySession{
            .allocator = allocator,
            .io = io,
            .config = owned_config,
            .started_at_ms = nowMs(io),
            .started_ns = nowNs(io),
        };
        try session.initOutputs();
        return session;
    }

    pub fn deinit(self: *TelemetrySession) void {
        self.writeSummary() catch {};
        self.flush() catch {};
        if (self.text_file) |file| file.close(self.io);
        if (self.events_file) |file| file.close(self.io);
        self.counts.deinit(self.allocator);
        self.failures.deinit(self.allocator);
        self.artifacts.deinit(self.allocator);
        self.slowest_spans.deinit(self.allocator);
        if (self.auto_output_dir) |path| self.allocator.free(path);
        if (self.config.log_path) |path| self.allocator.free(path);
        if (self.config.trace_events_path) |path| self.allocator.free(path);
        if (self.config.trace_summary_path) |path| self.allocator.free(path);
        self.allocator.free(self.config.run_label);
    }

    pub fn autoOutputDir(self: *const TelemetrySession) ?[]const u8 {
        return self.auto_output_dir;
    }

    pub fn setCount(self: *TelemetrySession, key: []const u8, value: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const gop = self.counts.getOrPut(self.allocator, key) catch return;
        gop.value_ptr.* = value;
    }

    pub fn recordFailure(self: *TelemetrySession, kind: []const u8, name: []const u8, message: ?[]const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.failures.append(self.allocator, .{
            .kind = kind,
            .name = name,
            .message = message,
        }) catch {};
    }

    pub fn recordArtifact(self: *TelemetrySession, kind: []const u8, path: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.artifacts.append(self.allocator, .{
            .kind = kind,
            .path = path,
        }) catch {};
    }

    pub fn log(self: *TelemetrySession, level: LogLevel, scope: []const u8, message: []const u8, fields: []const Field) void {
        self.writeLog(level, scope, message, null, fields);
    }

    pub fn logInSpan(
        self: *TelemetrySession,
        level: LogLevel,
        scope: []const u8,
        message: []const u8,
        span: *const SpanHandle,
        fields: []const Field,
    ) void {
        self.writeLog(level, scope, message, span, fields);
    }

    pub fn startSpan(
        self: *TelemetrySession,
        parent: ?*const SpanHandle,
        minimum_level: TraceLevel,
        kind: []const u8,
        name: []const u8,
        fields: []const Field,
    ) ?SpanHandle {
        if (self.config.trace_level == .off) return null;
        if (minimum_level != .off and !self.config.trace_level.allows(minimum_level)) return null;

        var handle = SpanHandle{
            .started_ns = nowNs(self.io),
            .started_ms = nowMs(self.io),
            .trace_id = undefined,
            .span_id = undefined,
            .parent_span_id = null,
            .kind = kind,
            .name = name,
        };

        if (parent) |p| {
            handle.trace_id = p.trace_id;
            handle.parent_span_id = p.span_id;
        } else {
            randomHex(self.io, &handle.trace_id);
        }
        randomHex(self.io, &handle.span_id);

        self.writeSpanEvent("span_start", &handle, "started", 0, fields);
        return handle;
    }

    pub fn finishSpan(
        self: *TelemetrySession,
        handle: ?*const SpanHandle,
        outcome: SpanOutcome,
        fields: []const Field,
    ) void {
        const span = handle orelse return;
        const duration_ns = nowNs(self.io) - span.started_ns;
        self.writeSpanEvent("span_finish", span, outcome.asString(), duration_ns, fields);
        self.recordSlowSpan(span, outcome, duration_ns);
    }

    pub fn emitCompletedSpan(
        self: *TelemetrySession,
        parent: ?*const SpanHandle,
        minimum_level: TraceLevel,
        kind: []const u8,
        name: []const u8,
        outcome: SpanOutcome,
        duration_ns: u64,
        fields: []const Field,
    ) void {
        if (self.config.trace_level == .off) return;
        if (minimum_level != .off and !self.config.trace_level.allows(minimum_level)) return;

        var handle = SpanHandle{
            .started_ns = nowNs(self.io) - duration_ns,
            .started_ms = nowMs(self.io) - @as(i64, @intCast(duration_ns / std.time.ns_per_ms)),
            .trace_id = undefined,
            .span_id = undefined,
            .parent_span_id = null,
            .kind = kind,
            .name = name,
        };
        if (parent) |p| {
            handle.trace_id = p.trace_id;
            handle.parent_span_id = p.span_id;
        } else {
            randomHex(self.io, &handle.trace_id);
        }
        randomHex(self.io, &handle.span_id);
        self.writeSpanEvent("span_finish", &handle, outcome.asString(), duration_ns, fields);
        self.recordSlowSpan(&handle, outcome, duration_ns);
    }

    pub fn flush(self: *TelemetrySession) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.text_file) |file| try file.sync(self.io);
        if (self.events_file) |file| try file.sync(self.io);
    }

    fn initOutputs(self: *TelemetrySession) !void {
        if (!self.config.isEnabled()) return;

        const need_text = (self.config.log_level != .off and self.config.log_format.wantsText()) or
            (self.config.trace_level != .off and self.config.trace_format.wantsText());
        const need_events = (self.config.log_level != .off and self.config.log_format.wantsJson()) or
            (self.config.trace_level != .off and self.config.trace_format.wantsJson());
        const need_summary = self.config.trace_level != .off and self.config.trace_format.wantsJson();

        if (!need_text and !need_events and !need_summary) return;

        if (self.config.log_path == null or self.config.trace_events_path == null or self.config.trace_summary_path == null) {
            const auto_dir = try std.fmt.allocPrint(
                self.allocator,
                ".zig-cache/telemetry/{s}-{d}",
                .{ self.config.run_label, self.started_at_ms },
            );
            self.auto_output_dir = auto_dir;
        }

        if (need_text) {
            const path = if (self.config.log_path) |path|
                path
            else
                try std.fs.path.join(self.allocator, &.{ self.auto_output_dir.?, "run.log" });
            self.config.log_path = path;
            self.text_file = try createOutputFile(self.io, path);
            self.artifacts.append(self.allocator, .{ .kind = "log", .path = path }) catch {};
        }

        if (need_events) {
            const path = if (self.config.trace_events_path) |path|
                path
            else
                try std.fs.path.join(self.allocator, &.{ self.auto_output_dir.?, "events.jsonl" });
            self.config.trace_events_path = path;
            self.events_file = try createOutputFile(self.io, path);
            self.artifacts.append(self.allocator, .{ .kind = "events", .path = path }) catch {};
        }

        if (need_summary) {
            const path = if (self.config.trace_summary_path) |path|
                path
            else
                try std.fs.path.join(self.allocator, &.{ self.auto_output_dir.?, "summary.json" });
            self.config.trace_summary_path = path;
            self.summary_path = path;
            self.artifacts.append(self.allocator, .{ .kind = "summary", .path = path }) catch {};
        }
    }

    fn writeLog(
        self: *TelemetrySession,
        level: LogLevel,
        scope: []const u8,
        message: []const u8,
        span: ?*const SpanHandle,
        fields: []const Field,
    ) void {
        if (!self.config.log_level.allows(level)) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.writeTextLog(level, scope, message, span, fields) catch {};
        self.writeJsonLog(level, scope, message, span, fields) catch {};
    }

    fn writeSpanEvent(
        self: *TelemetrySession,
        event_type: []const u8,
        handle: *const SpanHandle,
        status: []const u8,
        duration_ns: u64,
        fields: []const Field,
    ) void {
        if (self.config.trace_level == .off) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.writeTextSpan(event_type, handle, status, duration_ns, fields) catch {};
        self.writeJsonSpan(event_type, handle, status, duration_ns, fields) catch {};
    }

    fn recordSlowSpan(self: *TelemetrySession, handle: *const SpanHandle, outcome: SpanOutcome, duration_ns: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.slowest_spans.append(self.allocator, .{
            .kind = handle.kind,
            .name = handle.name,
            .status = outcome.asString(),
            .duration_ns = duration_ns,
            .trace_id = handle.trace_id,
            .span_id = handle.span_id,
        }) catch return;

        std.mem.sort(SlowSpan, self.slowest_spans.items, {}, struct {
            fn lessThan(_: void, a: SlowSpan, b: SlowSpan) bool {
                return a.duration_ns > b.duration_ns;
            }
        }.lessThan);

        if (self.slowest_spans.items.len > 20) {
            self.slowest_spans.shrinkRetainingCapacity(20);
        }
    }

    fn writeSummary(self: *TelemetrySession) !void {
        const path = self.summary_path orelse return;
        var file = try createOutputFile(self.io, path);
        defer file.close(self.io);

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &buffer);
        const writer = &file_writer.interface;

        try writer.writeAll("{");
        try writeJsonKey(writer, "run_label");
        try writeJsonString(writer, self.config.run_label);
        try writer.writeAll(",");
        try writeJsonKey(writer, "run_kind");
        try writeJsonString(writer, self.config.run_label);
        try writer.writeAll(",");
        try writeJsonKey(writer, "status");
        try writeJsonString(writer, "ok");
        try writer.writeAll(",");
        try writeJsonKey(writer, "started_at");
        try writer.print("{d}", .{self.started_at_ms});
        try writer.writeAll(",");
        try writeJsonKey(writer, "duration_ns");
        try writer.print("{d}", .{nowNs(self.io) - self.started_ns});

        try writer.writeAll(",");
        try writeJsonKey(writer, "counts");
        try writer.writeAll("{");
        var count_iter = self.counts.iterator();
        var first_count = true;
        while (count_iter.next()) |entry| {
            if (!first_count) try writer.writeAll(",");
            first_count = false;
            try writeJsonKey(writer, entry.key_ptr.*);
            try writer.print("{d}", .{entry.value_ptr.*});
        }
        try writer.writeAll("}");

        try writer.writeAll(",");
        try writeJsonKey(writer, "failures");
        try writer.writeAll("[");
        for (self.failures.items, 0..) |failure, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writeJsonKey(writer, "kind");
            try writeJsonString(writer, failure.kind);
            try writer.writeAll(",");
            try writeJsonKey(writer, "name");
            try writeJsonString(writer, failure.name);
            try writer.writeAll(",");
            try writeJsonKey(writer, "message");
            if (failure.message) |message| {
                try writeJsonString(writer, message);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try writer.writeAll(",");
        try writeJsonKey(writer, "slowest_spans");
        try writer.writeAll("[");
        for (self.slowest_spans.items, 0..) |span, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writeJsonKey(writer, "kind");
            try writeJsonString(writer, span.kind);
            try writer.writeAll(",");
            try writeJsonKey(writer, "name");
            try writeJsonString(writer, span.name);
            try writer.writeAll(",");
            try writeJsonKey(writer, "status");
            try writeJsonString(writer, span.status);
            try writer.writeAll(",");
            try writeJsonKey(writer, "duration_ns");
            try writer.print("{d}", .{span.duration_ns});
            try writer.writeAll(",");
            try writeJsonKey(writer, "trace_id");
            try writeJsonString(writer, span.trace_id[0..]);
            try writer.writeAll(",");
            try writeJsonKey(writer, "span_id");
            try writeJsonString(writer, span.span_id[0..]);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try writer.writeAll(",");
        try writeJsonKey(writer, "artifacts");
        try writer.writeAll("[");
        for (self.artifacts.items, 0..) |artifact, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writeJsonKey(writer, "kind");
            try writeJsonString(writer, artifact.kind);
            try writer.writeAll(",");
            try writeJsonKey(writer, "path");
            try writeJsonString(writer, artifact.path);
            try writer.writeAll("}");
        }
        try writer.writeAll("]}");
        try writer.flush();
    }

    fn writeTextLog(
        self: *TelemetrySession,
        level: LogLevel,
        scope: []const u8,
        message: []const u8,
        span: ?*const SpanHandle,
        fields: []const Field,
    ) !void {
        if (!self.config.log_format.wantsText()) return;
        const file = self.text_file orelse return;
        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &buffer);
        const writer = &file_writer.interface;

        if (self.config.include_timestamps) {
            try writer.print("[{d}] ", .{nowMs(self.io)});
        }
        try writer.print("{s} {s}: {s}", .{ level.asString(), scope, message });
        if (span) |active| {
            try writer.print(" trace_id={s} span_id={s}", .{ active.trace_id[0..], active.span_id[0..] });
        }
        try writeTextFields(writer, fields);
        try writer.writeAll("\n");
        try writer.flush();
    }

    fn writeJsonLog(
        self: *TelemetrySession,
        level: LogLevel,
        scope: []const u8,
        message: []const u8,
        span: ?*const SpanHandle,
        fields: []const Field,
    ) !void {
        if (!self.config.log_format.wantsJson()) return;
        const file = self.events_file orelse return;
        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &buffer);
        const writer = &file_writer.interface;

        try writer.writeAll("{");
        try writeJsonKey(writer, "type");
        try writeJsonString(writer, "log");
        try writer.writeAll(",");
        try writeJsonKey(writer, "timestamp_ms");
        try writer.print("{d}", .{nowMs(self.io)});
        try writer.writeAll(",");
        try writeJsonKey(writer, "level");
        try writeJsonString(writer, level.asString());
        try writer.writeAll(",");
        try writeJsonKey(writer, "scope");
        try writeJsonString(writer, scope);
        try writer.writeAll(",");
        try writeJsonKey(writer, "message");
        try writeJsonString(writer, message);
        if (span) |active| {
            try writer.writeAll(",");
            try writeJsonKey(writer, "trace_id");
            try writeJsonString(writer, active.trace_id[0..]);
            try writer.writeAll(",");
            try writeJsonKey(writer, "span_id");
            try writeJsonString(writer, active.span_id[0..]);
        }
        try writeJsonFields(writer, fields);
        try writer.writeAll("}\n");
        try writer.flush();
    }

    fn writeTextSpan(
        self: *TelemetrySession,
        event_type: []const u8,
        handle: *const SpanHandle,
        status: []const u8,
        duration_ns: u64,
        fields: []const Field,
    ) !void {
        if (!self.config.trace_format.wantsText()) return;
        const file = self.text_file orelse return;
        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &buffer);
        const writer = &file_writer.interface;

        if (self.config.include_timestamps) {
            try writer.print("[{d}] ", .{nowMs(self.io)});
        }
        try writer.print("{s} {s} {s} trace_id={s} span_id={s}", .{
            event_type,
            handle.kind,
            handle.name,
            handle.trace_id[0..],
            handle.span_id[0..],
        });
        if (handle.parent_span_id) |parent| {
            try writer.print(" parent_span_id={s}", .{parent[0..]});
        }
        try writer.print(" status={s}", .{status});
        if (duration_ns > 0) {
            try writer.print(" duration_ns={d}", .{duration_ns});
        }
        try writeTextFields(writer, fields);
        try writer.writeAll("\n");
        try writer.flush();
    }

    fn writeJsonSpan(
        self: *TelemetrySession,
        event_type: []const u8,
        handle: *const SpanHandle,
        status: []const u8,
        duration_ns: u64,
        fields: []const Field,
    ) !void {
        if (!self.config.trace_format.wantsJson()) return;
        const file = self.events_file orelse return;
        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &buffer);
        const writer = &file_writer.interface;

        try writer.writeAll("{");
        try writeJsonKey(writer, "type");
        try writeJsonString(writer, event_type);
        try writer.writeAll(",");
        try writeJsonKey(writer, "timestamp_ms");
        try writer.print("{d}", .{nowMs(self.io)});
        try writer.writeAll(",");
        try writeJsonKey(writer, "kind");
        try writeJsonString(writer, handle.kind);
        try writer.writeAll(",");
        try writeJsonKey(writer, "name");
        try writeJsonString(writer, handle.name);
        try writer.writeAll(",");
        try writeJsonKey(writer, "trace_id");
        try writeJsonString(writer, handle.trace_id[0..]);
        try writer.writeAll(",");
        try writeJsonKey(writer, "span_id");
        try writeJsonString(writer, handle.span_id[0..]);
        if (handle.parent_span_id) |parent| {
            try writer.writeAll(",");
            try writeJsonKey(writer, "parent_span_id");
            try writeJsonString(writer, parent[0..]);
        }
        try writer.writeAll(",");
        try writeJsonKey(writer, "status");
        try writeJsonString(writer, status);
        if (duration_ns > 0) {
            try writer.writeAll(",");
            try writeJsonKey(writer, "duration_ns");
            try writer.print("{d}", .{duration_ns});
        }
        try writeJsonFields(writer, fields);
        try writer.writeAll("}\n");
        try writer.flush();
    }
};

fn createOutputFile(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
    }
    return std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
}

fn randomHex(io: std.Io, out: anytype) void {
    var bytes: [out.len / 2]u8 = undefined;
    io.random(&bytes);
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds());
}

fn writeTextFields(writer: anytype, fields: []const Field) !void {
    for (fields) |field| {
        try writer.print(" {s}=", .{field.key});
        switch (field.value) {
            .string => |value| try writer.print("{s}", .{value}),
            .unsigned => |value| try writer.print("{d}", .{value}),
            .signed => |value| try writer.print("{d}", .{value}),
            .boolean => |value| try writer.print("{}", .{value}),
        }
    }
}

fn writeJsonFields(writer: anytype, fields: []const Field) !void {
    for (fields) |field| {
        try writer.writeAll(",");
        try writeJsonKey(writer, field.key);
        switch (field.value) {
            .string => |value| try writeJsonString(writer, value),
            .unsigned => |value| try writer.print("{d}", .{value}),
            .signed => |value| try writer.print("{d}", .{value}),
            .boolean => |value| try writer.print("{}", .{value}),
        }
    }
}

fn writeJsonKey(writer: anytype, key: []const u8) !void {
    try writeJsonString(writer, key);
    try writer.writeAll(":");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |c| switch (c) {
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
                try writer.print("{c}", .{c});
            }
        },
    };
    try writer.writeAll("\"");
}
