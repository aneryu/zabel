const std = @import("std");

pub const FileRow = struct {
    project: []const u8,
    path: []const u8,
    bytes: u64,
    parse_ns: u64,
    transform_ns: u64,
    codegen_ns: u64,
    total_ns: u64,
};

pub const TransformProfileSharedRow = struct {
    project: []const u8,
    path: []const u8,
    pipeline_ns: u64,
    scope_analysis_ns: u64,
    transform_session_ns: u64,
    dispatch_table_build_ns: u64,
    traversal_ns: u64,
};

pub const TransformProfilePassRow = struct {
    project: []const u8,
    path: []const u8,
    name: []const u8,
    total_ns: u64,
    enter_calls: u64,
    exit_calls: u64,
};

pub const Summary = struct {
    total_ns: u64,
    total_bytes: u64,
    p50_total_ns: u64,
    p95_total_ns: u64,
    rows: []FileRow,

    pub fn deinit(self: Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
    }
};

pub fn aggregateRows(allocator: std.mem.Allocator, input: []const FileRow) !Summary {
    const rows = try allocator.dupe(FileRow, input);
    errdefer allocator.free(rows);

    var total_ns: u64 = 0;
    var total_bytes: u64 = 0;
    std.mem.sort(FileRow, rows, {}, struct {
        fn lessThan(_: void, a: FileRow, b: FileRow) bool {
            return a.total_ns < b.total_ns;
        }
    }.lessThan);

    for (rows) |row| {
        total_ns += row.total_ns;
        total_bytes += row.bytes;
    }

    return .{
        .total_ns = total_ns,
        .total_bytes = total_bytes,
        .p50_total_ns = rows[(rows.len - 1) / 2].total_ns,
        .p95_total_ns = rows[(rows.len * 95 + 99) / 100 - 1].total_ns,
        .rows = rows,
    };
}

pub fn formatBatchRow(allocator: std.mem.Allocator, row: FileRow) ![]u8 {
    return std.fmt.allocPrint(allocator, "file\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}", .{
        row.project,
        row.path,
        row.bytes,
        row.parse_ns,
        row.transform_ns,
        row.codegen_ns,
        row.total_ns,
    });
}

pub fn formatTransformProfileSharedRow(allocator: std.mem.Allocator, row: TransformProfileSharedRow) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "profile_shared\t{s}\t{s}\tpipeline_ns\t{d}\tscope_analysis_ns\t{d}\ttransform_session_ns\t{d}\tdispatch_table_build_ns\t{d}\ttraversal_ns\t{d}",
        .{
            row.project,
            row.path,
            row.pipeline_ns,
            row.scope_analysis_ns,
            row.transform_session_ns,
            row.dispatch_table_build_ns,
            row.traversal_ns,
        },
    );
}

pub fn formatTransformProfilePassRow(allocator: std.mem.Allocator, row: TransformProfilePassRow) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "profile_pass\t{s}\t{s}\t{s}\ttotal_ns\t{d}\tenter_calls\t{d}\texit_calls\t{d}",
        .{
            row.project,
            row.path,
            row.name,
            row.total_ns,
            row.enter_calls,
            row.exit_calls,
        },
    );
}

const ProjectSummary = struct {
    name: []const u8,
    file_count: usize,
    total_ns: u64,
};

pub fn renderSummary(allocator: std.mem.Allocator, rows: []const FileRow) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const summary = try aggregateRows(allocator, rows);
    defer summary.deinit(allocator);

    var project_summaries = std.ArrayList(ProjectSummary).empty;
    defer project_summaries.deinit(allocator);

    for (rows) |row| {
        var matched = false;
        for (project_summaries.items) |*project| {
            if (!std.mem.eql(u8, project.name, row.project)) continue;
            project.file_count += 1;
            project.total_ns += row.total_ns;
            matched = true;
            break;
        }
        if (!matched) {
            try project_summaries.append(allocator, .{
                .name = row.project,
                .file_count = 1,
                .total_ns = row.total_ns,
            });
        }
    }

    std.mem.sort(ProjectSummary, project_summaries.items, {}, struct {
        fn lessThan(_: void, a: ProjectSummary, b: ProjectSummary) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    const summary_line = try std.fmt.allocPrint(allocator, "summary\tfiles\t{d}\ttotal_ns\t{d}\tp95_total_ns\t{d}\n", .{
        rows.len,
        summary.total_ns,
        summary.p95_total_ns,
    });
    defer allocator.free(summary_line);
    try out.appendSlice(allocator, summary_line);
    for (project_summaries.items) |project| {
        const project_line = try std.fmt.allocPrint(allocator, "project\t{s}\tfiles\t{d}\ttotal_ns\t{d}\n", .{
            project.name,
            project.file_count,
            project.total_ns,
        });
        defer allocator.free(project_line);
        try out.appendSlice(allocator, project_line);
    }

    return out.toOwnedSlice(allocator);
}
