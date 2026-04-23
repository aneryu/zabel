const std = @import("std");
const telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;

pub const TelemetryArgs = struct {
    config: telemetry.TelemetryConfig = .{},
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *TelemetryArgs, allocator: Allocator) void {
        for (self.owned_strings.items) |value| allocator.free(value);
        self.owned_strings.deinit(allocator);
    }

    pub fn setRunLabel(self: *TelemetryArgs, allocator: Allocator, run_label: []const u8) !void {
        const owned = try allocator.dupe(u8, run_label);
        try self.owned_strings.append(allocator, owned);
        self.config.run_label = owned;
    }

    pub fn applyEnv(self: *TelemetryArgs, allocator: Allocator, environ: std.process.Environ) !void {
        try self.applyLogLevelEnv(allocator, environ, "ZB_LOG_LEVEL");
        try self.applyTraceLevelEnv(allocator, environ, "ZB_TRACE_LEVEL");
        try self.applyFormatEnv(allocator, environ, "ZB_LOG_FORMAT", &self.config.log_format);
        try self.applyFormatEnv(allocator, environ, "ZB_TRACE_FORMAT", &self.config.trace_format);
        try self.applyPathEnv(allocator, environ, "ZB_LOG_PATH", &self.config.log_path);
        try self.applyPathEnv(allocator, environ, "ZB_TRACE_EVENTS_PATH", &self.config.trace_events_path);
        try self.applyPathEnv(allocator, environ, "ZB_TRACE_SUMMARY_PATH", &self.config.trace_summary_path);
    }

    pub fn maybeConsumeArg(
        self: *TelemetryArgs,
        args: []const []const u8,
        index: *usize,
    ) !bool {
        const arg = args[index.*];

        if (std.mem.eql(u8, arg, "--log-level")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingTelemetryValue;
            self.config.log_level = telemetry.LogLevel.parse(args[index.*]) orelse return error.InvalidTelemetryValue;
            return true;
        }
        if (std.mem.eql(u8, arg, "--trace-level")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingTelemetryValue;
            self.config.trace_level = telemetry.TraceLevel.parse(args[index.*]) orelse return error.InvalidTelemetryValue;
            return true;
        }
        if (std.mem.eql(u8, arg, "--log-format")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingTelemetryValue;
            self.config.log_format = telemetry.OutputFormat.parse(args[index.*]) orelse return error.InvalidTelemetryValue;
            return true;
        }
        if (std.mem.eql(u8, arg, "--trace-format")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingTelemetryValue;
            self.config.trace_format = telemetry.OutputFormat.parse(args[index.*]) orelse return error.InvalidTelemetryValue;
            return true;
        }
        if (std.mem.eql(u8, arg, "--log-path")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingTelemetryValue;
            self.config.log_path = args[index.*];
            return true;
        }
        if (std.mem.eql(u8, arg, "--trace-events-path")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingTelemetryValue;
            self.config.trace_events_path = args[index.*];
            return true;
        }
        if (std.mem.eql(u8, arg, "--trace-summary-path")) {
            index.* += 1;
            if (index.* >= args.len) return error.MissingTelemetryValue;
            self.config.trace_summary_path = args[index.*];
            return true;
        }

        return false;
    }

    fn applyLogLevelEnv(self: *TelemetryArgs, allocator: Allocator, environ: std.process.Environ, key: []const u8) !void {
        const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return,
            else => return err,
        };
        try self.owned_strings.append(allocator, raw);
        self.config.log_level = telemetry.LogLevel.parse(raw) orelse return error.InvalidTelemetryValue;
    }

    fn applyTraceLevelEnv(self: *TelemetryArgs, allocator: Allocator, environ: std.process.Environ, key: []const u8) !void {
        const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return,
            else => return err,
        };
        try self.owned_strings.append(allocator, raw);
        self.config.trace_level = telemetry.TraceLevel.parse(raw) orelse return error.InvalidTelemetryValue;
    }

    fn applyFormatEnv(
        self: *TelemetryArgs,
        allocator: Allocator,
        environ: std.process.Environ,
        key: []const u8,
        target: *telemetry.OutputFormat,
    ) !void {
        const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return,
            else => return err,
        };
        try self.owned_strings.append(allocator, raw);
        target.* = telemetry.OutputFormat.parse(raw) orelse return error.InvalidTelemetryValue;
    }

    fn applyPathEnv(
        self: *TelemetryArgs,
        allocator: Allocator,
        environ: std.process.Environ,
        key: []const u8,
        target: *?[]const u8,
    ) !void {
        const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return,
            else => return err,
        };
        try self.owned_strings.append(allocator, raw);
        target.* = raw;
    }
};
