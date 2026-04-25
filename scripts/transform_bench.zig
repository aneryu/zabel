const std = @import("std");
const zb = @import("zig_babal");

fn spanPtr(span: *?zb.Telemetry.SpanHandle) ?*const zb.Telemetry.SpanHandle {
    if (span.*) |*value| return value;
    return null;
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn startTimer(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn readTimerNs(io: std.Io, started: std.Io.Timestamp) u64 {
    return @intCast(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
}

fn buildStagePipeline(
    alloc: std.mem.Allocator,
    stage: usize,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    telemetry_parent_span: ?*const zb.Telemetry.SpanHandle,
) !zb.Pipeline {
    var pipeline = zb.Pipeline.init(alloc);
    pipeline.telemetry_session = telemetry_session;
    if (telemetry_parent_span) |span| pipeline.telemetry_parent_span = span.*;
    var idx: usize = 0;

    idx += 1;
    if (stage >= idx) try pipeline.addPass(zb.TsStrip.createPass(.{}));

    pipeline.needs_scope = stage >= 5;

    idx += 1;
    if (stage >= idx) try pipeline.addPass(zb.ShorthandProperties.createPass());

    idx += 1;
    if (stage >= idx) {
        zb.TemplateLiterals.resetState();
        try pipeline.addPass(zb.TemplateLiterals.createPass(.{}));
    }

    idx += 1;
    if (stage >= idx) {
        zb.ComputedProperties.resetState();
        try pipeline.addPass(zb.ComputedProperties.createPass(.{}));
    }

    idx += 1;
    if (stage >= idx) {
        zb.ArrowFunctions.resetState();
        try pipeline.addPass(zb.ArrowFunctions.createPass(.{}));
    }

    idx += 1;
    if (stage >= idx) {
        zb.Spread.resetState();
        try pipeline.addPass(zb.Spread.createPass(.{ .strip_typescript_wrappers = true }));
    }

    idx += 1;
    if (stage >= idx) {
        zb.Parameters.resetState();
        try pipeline.addPass(zb.Parameters.createPass(.{}));
    }

    idx += 1;
    if (stage >= idx) {
        zb.ForOf.resetState();
        try pipeline.addPass(zb.ForOf.createPass(.{}));
    }

    idx += 1;
    if (stage >= idx) {
        zb.BlockScoping.resetState();
        pipeline.needs_scope = true;
        try pipeline.addPass(zb.BlockScoping.createPass(.{}));
    }

    return pipeline;
}

fn buildFullPipeline(
    alloc: std.mem.Allocator,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    telemetry_parent_span: ?*const zb.Telemetry.SpanHandle,
) !zb.Pipeline {
    var pipeline = zb.Pipeline.init(alloc);
    pipeline.telemetry_session = telemetry_session;
    if (telemetry_parent_span) |span| pipeline.telemetry_parent_span = span.*;
    const config = zb.TransformConfig{ .target = .es2015, .ts_strip = true };

    if (config.ts_strip) try pipeline.addPass(zb.TsStrip.createPass(.{}));
    pipeline.needs_scope = true;

    if (config.needsTransform(.shorthand_properties)) try pipeline.addPass(zb.ShorthandProperties.createPass());
    if (config.needsTransform(.template_literals)) {
        zb.TemplateLiterals.resetState();
        try pipeline.addPass(zb.TemplateLiterals.createPass(.{}));
    }
    if (config.needsTransform(.computed_properties)) {
        zb.ComputedProperties.resetState();
        try pipeline.addPass(zb.ComputedProperties.createPass(.{}));
    }
    if (config.needsTransform(.arrow_functions)) {
        zb.ArrowFunctions.resetState();
        try pipeline.addPass(zb.ArrowFunctions.createPass(.{}));
    }
    if (config.needsTransform(.spread)) {
        zb.Spread.resetState();
        try pipeline.addPass(zb.Spread.createPass(.{ .strip_typescript_wrappers = true }));
    }
    if (config.needsTransform(.parameters)) {
        zb.Parameters.resetState();
        try pipeline.addPass(zb.Parameters.createPass(.{}));
    }
    if (config.needsTransform(.for_of)) {
        zb.ForOf.resetState();
        try pipeline.addPass(zb.ForOf.createPass(.{}));
    }
    if (config.needsTransform(.block_scoping)) {
        zb.BlockScoping.resetState();
        try pipeline.addPass(zb.BlockScoping.createPass(.{}));
    }

    return pipeline;
}

fn parseSource(alloc: std.mem.Allocator, source: []const u8, language: zb.Language) !zb.ParseResult {
    return zb.parseWithOptions(alloc, source, .{
        .source_type = .script,
        .language = language,
        .defer_comment_attachment = true,
    });
}

fn parseTs(alloc: std.mem.Allocator, source: []const u8) !zb.ParseResult {
    return parseSource(alloc, source, .typescript);
}

fn languageFromPath(path: []const u8) zb.Language {
    if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
    if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
    if (std.mem.endsWith(u8, path, ".jsx")) return .jsx;
    if (std.mem.endsWith(u8, path, ".flow.js")) return .flow;
    return .javascript;
}

fn benchStage(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    stage: usize,
    warmups: usize,
    iterations: usize,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    parent_span: ?*const zb.Telemetry.SpanHandle,
) !void {
    var stage_span = if (telemetry_session) |session|
        session.startSpan(parent_span, .fixture, "phase", "bench_stage", &.{
            zb.Telemetry.Field.unsigned("stage", stage),
            zb.Telemetry.Field.unsigned("warmups", warmups),
            zb.Telemetry.Field.unsigned("iterations", iterations),
        })
    else
        null;
    var elapsed_ns: u64 = 0;
    var sink: usize = 0;

    for (0..warmups + iterations) |iter| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var result = try parseTs(alloc, source);
        var pipeline = try buildStagePipeline(alloc, stage, telemetry_session, spanPtr(&stage_span));
        defer pipeline.deinit();

        const timer = startTimer(io);
        try pipeline.run(&result.ast);
        const elapsed = readTimerNs(io, timer);

        sink +%= result.ast.nodes.len;
        if (iter >= warmups) elapsed_ns +%= elapsed;
    }

    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("stage\t{d}\t{d}\t{d}\t{d}\n", .{ stage, iterations, elapsed_ns, sink });
    try stdout.flush();
    if (telemetry_session) |session| {
        session.finishSpan(spanPtr(&stage_span), .ok, &.{
            zb.Telemetry.Field.unsigned("elapsed_ns", elapsed_ns),
            zb.Telemetry.Field.unsigned("sink", sink),
        });
    }
}

fn benchPhase(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    warmups: usize,
    iterations: usize,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    parent_span: ?*const zb.Telemetry.SpanHandle,
) !void {
    var phase_span = if (telemetry_session) |session|
        session.startSpan(parent_span, .fixture, "phase", "bench_phase", &.{
            zb.Telemetry.Field.unsigned("warmups", warmups),
            zb.Telemetry.Field.unsigned("iterations", iterations),
        })
    else
        null;
    const total_iters = warmups + iterations;
    var parse_ns: u64 = 0;
    var pipeline_ns: u64 = 0;
    var codegen_ns: u64 = 0;
    var sink: usize = 0;

    for (0..total_iters) |iter| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const parse_timer = startTimer(io);
        var result = try parseTs(alloc, source);
        const parse_elapsed = readTimerNs(io, parse_timer);

        var pipeline = try buildFullPipeline(alloc, telemetry_session, spanPtr(&phase_span));
        defer pipeline.deinit();

        const pipeline_timer = startTimer(io);
        try pipeline.run(&result.ast);
        const pipeline_elapsed = readTimerNs(io, pipeline_timer);

        const codegen_timer = startTimer(io);
        const gen = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
        const codegen_elapsed = readTimerNs(io, codegen_timer);

        sink +%= gen.code.len + result.ast.nodes.len;
        if (zb.TemplateLiterals.getTemplateObjectDeclarations(alloc)) |decl| sink +%= decl.len;
        if (zb.ComputedProperties.getTempVarDeclarations(alloc)) |decl| sink +%= decl.len;
        if (zb.Spread.getTempVarDeclarations(alloc)) |decl| sink +%= decl.len;
        std.mem.doNotOptimizeAway(sink);

        if (iter >= warmups) {
            parse_ns +%= parse_elapsed;
            pipeline_ns +%= pipeline_elapsed;
            codegen_ns +%= codegen_elapsed;
        }
    }

    var buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("phase\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ iterations, parse_ns, pipeline_ns, codegen_ns, sink });
    try stdout.flush();
    if (telemetry_session) |session| {
        session.finishSpan(spanPtr(&phase_span), .ok, &.{
            zb.Telemetry.Field.unsigned("parse_ns", parse_ns),
            zb.Telemetry.Field.unsigned("pipeline_ns", pipeline_ns),
            zb.Telemetry.Field.unsigned("codegen_ns", codegen_ns),
        });
    }
}

fn benchTotal(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    warmups: usize,
    iterations: usize,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    parent_span: ?*const zb.Telemetry.SpanHandle,
) !void {
    var total_span = if (telemetry_session) |session|
        session.startSpan(parent_span, .fixture, "phase", "bench_total", &.{
            zb.Telemetry.Field.unsigned("warmups", warmups),
            zb.Telemetry.Field.unsigned("iterations", iterations),
        })
    else
        null;
    var elapsed_ns: u64 = 0;
    var sink: usize = 0;

    for (0..warmups + iterations) |iter| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const timer = startTimer(io);
        var result = try parseTs(alloc, source);
        var pipeline = try buildFullPipeline(alloc, telemetry_session, spanPtr(&total_span));
        defer pipeline.deinit();
        try pipeline.run(&result.ast);
        const gen = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
        const elapsed = readTimerNs(io, timer);

        sink +%= gen.code.len + result.ast.nodes.len;
        if (zb.TemplateLiterals.getTemplateObjectDeclarations(alloc)) |decl| sink +%= decl.len;
        if (zb.ComputedProperties.getTempVarDeclarations(alloc)) |decl| sink +%= decl.len;
        if (zb.Spread.getTempVarDeclarations(alloc)) |decl| sink +%= decl.len;
        std.mem.doNotOptimizeAway(sink);

        if (iter >= warmups) elapsed_ns +%= elapsed;
    }

    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("total\t{d}\t{d}\t{d}\n", .{ iterations, elapsed_ns, sink });
    try stdout.flush();
    if (telemetry_session) |session| {
        session.finishSpan(spanPtr(&total_span), .ok, &.{
            zb.Telemetry.Field.unsigned("elapsed_ns", elapsed_ns),
            zb.Telemetry.Field.unsigned("sink", sink),
        });
    }
}

fn benchFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    tier: []const u8,
    list_path: []const u8,
    iterations: usize,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    parent_span: ?*const zb.Telemetry.SpanHandle,
) !void {
    var files_span = if (telemetry_session) |session|
        session.startSpan(parent_span, .fixture, "phase", "bench_files", &.{
            zb.Telemetry.Field.string("tier", tier),
            zb.Telemetry.Field.unsigned("iterations", iterations),
        })
    else
        null;

    const list_source = try std.Io.Dir.cwd().readFileAlloc(io, list_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(list_source);

    var buf: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;

    var lines = std.mem.tokenizeScalar(u8, list_source, '\n');
    var emitted_rows: usize = 0;
    var collected_rows = std.ArrayList(zb.RealProjectBench.FileRow).empty;
    defer collected_rows.deinit(allocator);
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len == 0) continue;

        var fields = std.mem.splitScalar(u8, trimmed, '\t');
        const project = fields.next() orelse return error.InvalidFileList;
        _ = fields.next() orelse return error.InvalidFileList;
        const file_path = fields.next() orelse return error.InvalidFileList;
        if (fields.next() != null) return error.InvalidFileList;

        var total_row = zb.RealProjectBench.FileRow{
            .project = project,
            .path = file_path,
            .bytes = 0,
            .parse_ns = 0,
            .transform_ns = 0,
            .codegen_ns = 0,
            .total_ns = 0,
        };

        var source_cache: ?[]u8 = null;
        defer if (source_cache) |source| allocator.free(source);

        for (0..iterations) |_| {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const source = if (source_cache) |cached|
                cached
            else blk: {
                const loaded = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(64 * 1024 * 1024));
                source_cache = loaded;
                total_row.bytes = loaded.len;
                break :blk loaded;
            };

            const lang = languageFromPath(file_path);
            const parse_timer = startTimer(io);
            var result = try parseSource(alloc, source, lang);
            total_row.parse_ns +%= readTimerNs(io, parse_timer);

            var pipeline = try buildFullPipeline(alloc, telemetry_session, spanPtr(&files_span));
            defer pipeline.deinit();

            const pipeline_timer = startTimer(io);
            try pipeline.run(&result.ast);
            total_row.transform_ns +%= readTimerNs(io, pipeline_timer);

            const codegen_timer = startTimer(io);
            const gen = try zb.Codegen.generate(&result.ast, .{ .comments = false }, alloc);
            total_row.codegen_ns +%= readTimerNs(io, codegen_timer);

            total_row.total_ns = total_row.parse_ns + total_row.transform_ns + total_row.codegen_ns;
            std.mem.doNotOptimizeAway(gen.code.len);
        }

        const line_out = try zb.RealProjectBench.formatBatchRow(allocator, total_row);
        defer allocator.free(line_out);
        try stdout.print("{s}\n", .{line_out});
        try collected_rows.append(allocator, total_row);
        emitted_rows += 1;
    }

    if (collected_rows.items.len != 0) {
        const summary_out = try zb.RealProjectBench.renderSummary(allocator, collected_rows.items);
        defer allocator.free(summary_out);
        try stdout.print("{s}", .{summary_out});
    }

    try stdout.flush();
    if (telemetry_session) |session| {
        session.finishSpan(spanPtr(&files_span), .ok, &.{
            zb.Telemetry.Field.unsigned("rows", emitted_rows),
        });
    }
}

const ProfilePassStat = struct {
    name: []u8,
    total_ns: u64 = 0,
    enter_calls: u64 = 0,
    exit_calls: u64 = 0,
};

fn benchProfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    warmups: usize,
    iterations: usize,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    parent_span: ?*const zb.Telemetry.SpanHandle,
) !void {
    var profile_span = if (telemetry_session) |session|
        session.startSpan(parent_span, .fixture, "phase", "bench_profile", &.{
            zb.Telemetry.Field.unsigned("warmups", warmups),
            zb.Telemetry.Field.unsigned("iterations", iterations),
        })
    else
        null;
    const total_iters = warmups + iterations;
    var pipeline_ns: u64 = 0;
    var scope_analysis_ns: u64 = 0;
    var sink: usize = 0;
    var pass_totals: std.ArrayListUnmanaged(ProfilePassStat) = .empty;
    defer {
        for (pass_totals.items) |pass| allocator.free(pass.name);
        pass_totals.deinit(allocator);
    }

    for (0..total_iters) |iter| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var result = try parseTs(alloc, source);
        var pipeline = try buildFullPipeline(alloc, telemetry_session, spanPtr(&profile_span));
        defer pipeline.deinit();
        pipeline.collect_run_stats = true;
        pipeline.retain_transform_session = true;

        const timer = startTimer(io);
        try pipeline.run(&result.ast);
        const pipeline_elapsed = readTimerNs(io, timer);

        if (iter >= warmups) {
            pipeline_ns +%= pipeline_elapsed;
            if (pipeline.lastRunStats()) |stats| {
                scope_analysis_ns +%= stats.scope_analysis_ns orelse 0;
                if (pass_totals.items.len == 0) {
                    try pass_totals.ensureTotalCapacity(allocator, stats.passes.len);
                    for (stats.passes) |pass| {
                        try pass_totals.append(allocator, .{
                            .name = try allocator.dupe(u8, pass.name),
                            .total_ns = pass.total_ns,
                            .enter_calls = pass.enter_calls,
                            .exit_calls = pass.exit_calls,
                        });
                    }
                } else {
                    std.debug.assert(pass_totals.items.len == stats.passes.len);
                    for (pass_totals.items, stats.passes) |*totals, pass| {
                        totals.total_ns +%= pass.total_ns;
                        totals.enter_calls +%= pass.enter_calls;
                        totals.exit_calls +%= pass.exit_calls;
                    }
                }
            }
        }

        sink +%= result.ast.nodes.len;
    }

    var buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("profile\t{d}\t{d}\t{d}\t{d}\n", .{ iterations, pipeline_ns, scope_analysis_ns, sink });
    for (pass_totals.items) |pass| {
        try stdout.print("pass\t{s}\t{d}\t{d}\t{d}\n", .{ pass.name, pass.total_ns, pass.enter_calls, pass.exit_calls });
    }
    try stdout.flush();
    if (telemetry_session) |session| {
        session.finishSpan(spanPtr(&profile_span), .ok, &.{
            zb.Telemetry.Field.unsigned("pipeline_ns", pipeline_ns),
            zb.Telemetry.Field.unsigned("scope_analysis_ns", scope_analysis_ns),
            zb.Telemetry.Field.unsigned("sink", sink),
        });
    }
}

fn benchProfileFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project: []const u8,
    file_path: []const u8,
    source: []const u8,
    warmups: usize,
    iterations: usize,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    parent_span: ?*const zb.Telemetry.SpanHandle,
) !void {
    var profile_span = if (telemetry_session) |session|
        session.startSpan(parent_span, .fixture, "phase", "bench_profile_file", &.{
            zb.Telemetry.Field.string("project", project),
            zb.Telemetry.Field.string("file", file_path),
            zb.Telemetry.Field.unsigned("warmups", warmups),
            zb.Telemetry.Field.unsigned("iterations", iterations),
        })
    else
        null;
    const total_iters = warmups + iterations;
    var pipeline_ns: u64 = 0;
    var scope_analysis_ns: u64 = 0;
    var transform_session_ns: u64 = 0;
    var dispatch_table_build_ns: u64 = 0;
    var traversal_ns: u64 = 0;
    var sink: usize = 0;
    var pass_totals: std.ArrayListUnmanaged(ProfilePassStat) = .empty;
    defer {
        for (pass_totals.items) |pass| allocator.free(pass.name);
        pass_totals.deinit(allocator);
    }

    const lang = languageFromPath(file_path);
    for (0..total_iters) |iter| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var result = try parseSource(alloc, source, lang);
        var pipeline = try buildFullPipeline(alloc, telemetry_session, spanPtr(&profile_span));
        defer pipeline.deinit();
        pipeline.collect_run_stats = true;
        pipeline.retain_transform_session = true;

        const timer = startTimer(io);
        try pipeline.run(&result.ast);
        const pipeline_elapsed = readTimerNs(io, timer);

        if (iter >= warmups) {
            pipeline_ns +%= pipeline_elapsed;
            if (pipeline.lastRunStats()) |stats| {
                scope_analysis_ns +%= stats.scope_analysis_ns orelse 0;
                transform_session_ns +%= stats.transform_session_ns orelse 0;
                dispatch_table_build_ns +%= stats.dispatch_table_build_ns orelse 0;
                traversal_ns +%= stats.traversal_ns orelse 0;
                if (pass_totals.items.len == 0) {
                    try pass_totals.ensureTotalCapacity(allocator, stats.passes.len);
                    for (stats.passes) |pass| {
                        try pass_totals.append(allocator, .{
                            .name = try allocator.dupe(u8, pass.name),
                            .total_ns = pass.total_ns,
                            .enter_calls = pass.enter_calls,
                            .exit_calls = pass.exit_calls,
                        });
                    }
                } else {
                    std.debug.assert(pass_totals.items.len == stats.passes.len);
                    for (pass_totals.items, stats.passes) |*totals, pass| {
                        totals.total_ns +%= pass.total_ns;
                        totals.enter_calls +%= pass.enter_calls;
                        totals.exit_calls +%= pass.exit_calls;
                    }
                }
            }
        }

        sink +%= result.ast.nodes.len;
    }

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;
    const shared_line = try zb.RealProjectBench.formatTransformProfileSharedRow(allocator, .{
        .project = project,
        .path = file_path,
        .pipeline_ns = pipeline_ns,
        .scope_analysis_ns = scope_analysis_ns,
        .transform_session_ns = transform_session_ns,
        .dispatch_table_build_ns = dispatch_table_build_ns,
        .traversal_ns = traversal_ns,
    });
    defer allocator.free(shared_line);
    try stdout.print("{s}\n", .{shared_line});
    for (pass_totals.items) |pass| {
        const pass_line = try zb.RealProjectBench.formatTransformProfilePassRow(allocator, .{
            .project = project,
            .path = file_path,
            .name = pass.name,
            .total_ns = pass.total_ns,
            .enter_calls = pass.enter_calls,
            .exit_calls = pass.exit_calls,
        });
        defer allocator.free(pass_line);
        try stdout.print("{s}\n", .{pass_line});
    }
    try stdout.flush();
    if (telemetry_session) |session| {
        session.finishSpan(spanPtr(&profile_span), .ok, &.{
            zb.Telemetry.Field.unsigned("pipeline_ns", pipeline_ns),
            zb.Telemetry.Field.unsigned("scope_analysis_ns", scope_analysis_ns),
            zb.Telemetry.Field.unsigned("transform_session_ns", transform_session_ns),
            zb.Telemetry.Field.unsigned("dispatch_table_build_ns", dispatch_table_build_ns),
            zb.Telemetry.Field.unsigned("traversal_ns", traversal_ns),
            zb.Telemetry.Field.unsigned("sink", sink),
        });
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  transform_bench stage <input.ts> <stage> <warmups> <iterations>
        \\  transform_bench phase <input.ts> <warmups> <iterations>
        \\  transform_bench total <input.ts> <warmups> <iterations>
        \\  transform_bench files <tier> <list.txt> <iterations>
        \\  transform_bench profile <input.ts> <warmups> <iterations>
        \\  transform_bench profile-file <project> <input.ts> <warmups> <iterations>
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try argsToSlice(arena, init.minimal.args);

    var telemetry_args = zb.TelemetryArgs{};
    defer telemetry_args.deinit(allocator);
    try telemetry_args.applyEnv(allocator, init.minimal.environ);
    try telemetry_args.setRunLabel(allocator, "transform-bench");

    var filtered: std.ArrayList([]const u8) = .empty;
    defer filtered.deinit(allocator);
    const raw_args = args[1..];
    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        if (try telemetry_args.maybeConsumeArg(raw_args, &i)) continue;
        try filtered.append(allocator, raw_args[i]);
    }

    if (filtered.items.len < 1) {
        printUsage();
        return error.InvalidArgs;
    }

    var telemetry_session: ?zb.Telemetry.TelemetrySession = null;
    defer if (telemetry_session) |*session| session.deinit();
    var run_span: ?zb.Telemetry.SpanHandle = null;
    if (telemetry_args.config.isEnabled()) {
        telemetry_session = try zb.Telemetry.TelemetrySession.init(allocator, io, telemetry_args.config);
        if (telemetry_session) |*session| {
            if (session.autoOutputDir()) |path| {
                std.debug.print("Telemetry artifacts: {s}\n", .{path});
            }
            run_span = session.startSpan(null, .fixture, "run", "transform-bench", &.{});
        }
    }

    const mode = filtered.items[0];

    if (std.mem.eql(u8, mode, "stage")) {
        if (filtered.items.len != 5) {
            printUsage();
            return error.InvalidArgs;
        }

        const source = try std.Io.Dir.cwd().readFileAlloc(io, filtered.items[1], allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source);

        const stage = try std.fmt.parseInt(usize, filtered.items[2], 10);
        const warmups = try std.fmt.parseInt(usize, filtered.items[3], 10);
        const iterations = try std.fmt.parseInt(usize, filtered.items[4], 10);
        try benchStage(allocator, io, source, stage, warmups, iterations, if (telemetry_session) |*session| session else null, spanPtr(&run_span));
        if (telemetry_session) |*session| session.finishSpan(spanPtr(&run_span), .ok, &.{
            zb.Telemetry.Field.string("mode", "stage"),
        });
        return;
    }

    if (std.mem.eql(u8, mode, "phase")) {
        if (filtered.items.len != 4) {
            printUsage();
            return error.InvalidArgs;
        }

        const source = try std.Io.Dir.cwd().readFileAlloc(io, filtered.items[1], allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source);

        const warmups = try std.fmt.parseInt(usize, filtered.items[2], 10);
        const iterations = try std.fmt.parseInt(usize, filtered.items[3], 10);
        try benchPhase(allocator, io, source, warmups, iterations, if (telemetry_session) |*session| session else null, spanPtr(&run_span));
        if (telemetry_session) |*session| session.finishSpan(spanPtr(&run_span), .ok, &.{
            zb.Telemetry.Field.string("mode", "phase"),
        });
        return;
    }

    if (std.mem.eql(u8, mode, "total")) {
        if (filtered.items.len != 4) {
            printUsage();
            return error.InvalidArgs;
        }

        const source = try std.Io.Dir.cwd().readFileAlloc(io, filtered.items[1], allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source);

        const warmups = try std.fmt.parseInt(usize, filtered.items[2], 10);
        const iterations = try std.fmt.parseInt(usize, filtered.items[3], 10);
        try benchTotal(allocator, io, source, warmups, iterations, if (telemetry_session) |*session| session else null, spanPtr(&run_span));
        if (telemetry_session) |*session| session.finishSpan(spanPtr(&run_span), .ok, &.{
            zb.Telemetry.Field.string("mode", "total"),
        });
        return;
    }

    if (std.mem.eql(u8, mode, "files")) {
        if (filtered.items.len != 4) {
            printUsage();
            return error.InvalidArgs;
        }

        const tier = filtered.items[1];
        const list_path = filtered.items[2];
        const iterations = try std.fmt.parseInt(usize, filtered.items[3], 10);
        try benchFiles(allocator, io, tier, list_path, iterations, if (telemetry_session) |*session| session else null, spanPtr(&run_span));
        if (telemetry_session) |*session| session.finishSpan(spanPtr(&run_span), .ok, &.{
            zb.Telemetry.Field.string("mode", "files"),
            zb.Telemetry.Field.string("tier", tier),
        });
        return;
    }

    if (std.mem.eql(u8, mode, "profile")) {
        if (filtered.items.len != 4) {
            printUsage();
            return error.InvalidArgs;
        }

        const source = try std.Io.Dir.cwd().readFileAlloc(io, filtered.items[1], allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source);

        const warmups = try std.fmt.parseInt(usize, filtered.items[2], 10);
        const iterations = try std.fmt.parseInt(usize, filtered.items[3], 10);
        try benchProfile(allocator, io, source, warmups, iterations, if (telemetry_session) |*session| session else null, spanPtr(&run_span));
        if (telemetry_session) |*session| session.finishSpan(spanPtr(&run_span), .ok, &.{
            zb.Telemetry.Field.string("mode", "profile"),
        });
        return;
    }

    if (std.mem.eql(u8, mode, "profile-file")) {
        if (filtered.items.len != 5) {
            printUsage();
            return error.InvalidArgs;
        }

        const project = filtered.items[1];
        const file_path = filtered.items[2];
        const source = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source);

        const warmups = try std.fmt.parseInt(usize, filtered.items[3], 10);
        const iterations = try std.fmt.parseInt(usize, filtered.items[4], 10);
        try benchProfileFile(allocator, io, project, file_path, source, warmups, iterations, if (telemetry_session) |*session| session else null, spanPtr(&run_span));
        if (telemetry_session) |*session| session.finishSpan(spanPtr(&run_span), .ok, &.{
            zb.Telemetry.Field.string("mode", "profile-file"),
            zb.Telemetry.Field.string("project", project),
            zb.Telemetry.Field.string("file", file_path),
        });
        return;
    }

    printUsage();
    return error.InvalidArgs;
}
