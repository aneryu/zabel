const std = @import("std");
const Token = @import("token.zig").Token;
const Ast = @import("ast.zig").Ast;

pub const Severity = enum {
    @"error",
    warning,
};

pub const Diagnostic = struct {
    message: []const u8,
    token_start: u32,
    severity: Severity,
};

pub const DiagnosticList = struct {
    items: std.ArrayList(Diagnostic),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{ .items = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *DiagnosticList) void {
        self.items.deinit(self.allocator);
    }

    pub fn addError(self: *DiagnosticList, message: []const u8, token_start: u32) void {
        self.items.append(self.allocator, .{
            .message = message,
            .token_start = token_start,
            .severity = .@"error",
        }) catch {};
    }

    pub fn addWarning(self: *DiagnosticList, message: []const u8, token_start: u32) void {
        self.items.append(self.allocator, .{
            .message = message,
            .token_start = token_start,
            .severity = .warning,
        }) catch {};
    }

    pub fn hasErrors(self: *const DiagnosticList) bool {
        for (self.items.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    /// Format diagnostics with source context for human-readable output.
    pub fn format(self: *const DiagnosticList, ast: *const Ast, writer: anytype) !void {
        for (self.items.items) |d| {
            const pos = ast.resolvePosition(d.token_start);
            const severity_str = switch (d.severity) {
                .@"error" => "error",
                .warning => "warning",
            };
            try writer.print("{s}: {s} (at line {d}, col {d})\n", .{
                severity_str,
                d.message,
                pos.line + 1,
                pos.col + 1,
            });
        }
    }
};
