const std = @import("std");
const zb = @import("zig_babal");

test "aggregateRows computes totals and p95 from file rows" {
    const rows = [_]zb.RealProjectBench.FileRow{
        .{ .project = "react-native", .path = "a.js", .bytes = 100, .parse_ns = 10, .transform_ns = 20, .codegen_ns = 5, .total_ns = 35 },
        .{ .project = "antd", .path = "b.js", .bytes = 300, .parse_ns = 30, .transform_ns = 40, .codegen_ns = 10, .total_ns = 80 },
    };

    const summary = try zb.RealProjectBench.aggregateRows(std.testing.allocator, &rows);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 115), summary.total_ns);
    try std.testing.expectEqual(@as(u64, 400), summary.total_bytes);
    try std.testing.expect(summary.p95_total_ns >= 80);
}

test "formatBatchRow emits machine-readable file rows" {
    const row = zb.RealProjectBench.FileRow{
        .project = "antd",
        .path = "es/form/Form.js",
        .bytes = 1234,
        .parse_ns = 10,
        .transform_ns = 20,
        .codegen_ns = 5,
        .total_ns = 35,
    };

    const line = try zb.RealProjectBench.formatBatchRow(std.testing.allocator, row);
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "file\tantd\tes/form/Form.js") != null);
}

test "renderSummary includes per-project totals and p95" {
    const rows = [_]zb.RealProjectBench.FileRow{
        .{ .project = "react-native", .path = "a.js", .bytes = 100, .parse_ns = 10, .transform_ns = 20, .codegen_ns = 5, .total_ns = 35 },
        .{ .project = "antd", .path = "b.js", .bytes = 200, .parse_ns = 15, .transform_ns = 25, .codegen_ns = 5, .total_ns = 45 },
    };

    const output = try zb.RealProjectBench.renderSummary(std.testing.allocator, &rows);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "project\treact-native") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "p95_total_ns") != null);
}

test "formatTransformProfileSharedRow emits machine-readable shared timing rows" {
    const line = try zb.RealProjectBench.formatTransformProfileSharedRow(std.testing.allocator, .{
        .project = "antd",
        .path = "es/form/Form.js",
        .pipeline_ns = 100,
        .scope_analysis_ns = 20,
        .transform_session_ns = 10,
        .dispatch_table_build_ns = 5,
        .traversal_ns = 40,
    });
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "profile_shared\tantd\tes/form/Form.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "dispatch_table_build_ns\t5") != null);
}

test "formatTransformProfilePassRow emits machine-readable pass timing rows" {
    const line = try zb.RealProjectBench.formatTransformProfilePassRow(std.testing.allocator, .{
        .project = "antd",
        .path = "es/form/Form.js",
        .name = "parameters",
        .total_ns = 30,
        .enter_calls = 4,
        .exit_calls = 2,
    });
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "profile_pass\tantd\tes/form/Form.js\tparameters") != null);
}
