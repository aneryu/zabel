const std = @import("std");
const zig_babal = @import("zig_babal");
const support = @import("fixture_runner_support.zig");

const FIXTURE_BASE = "vendor/babel/packages/babel-generator/test/fixtures";

// Generator options that we skip (non-default formatting modes)
const SKIP_OPTIONS = [_][]const u8{
    "compact",
    "minified",
    "concise",
    "retainLines",
    "retainFunctionParens",
    "jsescOption",
    "sourceMaps",
    "importAttributesKeyword",
};

// Directories that use special modes not driven by options.json
const SKIP_DIRS = [_][]const u8{
    "preserveFormat-edgecases",
    "sourcemaps",
};

// Arena memory limit between fixtures (4 MB retained, rest freed to OS)
const ARENA_RETAIN_LIMIT = 4 * 1024 * 1024;

const NUM_THREADS = 1;

// When set, only run fixtures matching this substring and print detailed diff on failure
var g_filter: ?[]const u8 = null;
var g_diff_mode: bool = false;
var g_io: ?std.Io = null;
var g_telemetry: ?*zig_babal.Telemetry.TelemetrySession = null;
var g_run_span: ?zig_babal.Telemetry.SpanHandle = null;

const Stats = struct {
    pass: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    skip: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

const WorkContext = struct {
    paths: []const []const u8,
    stats: *Stats,
    work_index: *std.atomic.Value(usize),
};

const CodegenDiscovery = struct {
    paths: *std.ArrayList([]const u8),
    caller_alloc: std.mem.Allocator,

    fn decideFixture(io: std.Io, dir: std.Io.Dir, dir_path: []const u8, user: ?*anyopaque) !support.FixtureDecision {
        const self: *CodegenDiscovery = @ptrCast(@alignCast(user orelse return error.MissingDiscovery));

        if (!support.dirHasAnyFile(io, dir, INPUT_FILENAMES[0..])) return .descend;
        if (!support.dirHasFile(io, dir, "output.js")) return .descend;

        const opts = checkOptions(self.caller_alloc, dir_path) catch return .stop_without_collect;
        return if (opts.skip) .stop_without_collect else .collect_and_stop;
    }

    fn onFixture(alloc: std.mem.Allocator, dir_path: []const u8, user: ?*anyopaque) !void {
        const self: *CodegenDiscovery = @ptrCast(@alignCast(user orelse return error.MissingDiscovery));
        try self.paths.append(alloc, try alloc.dupe(u8, dir_path));
    }

    fn shouldDescend(entry_name: []const u8, user: ?*anyopaque) bool {
        _ = user;
        for (SKIP_DIRS) |dir_name| {
            if (std.mem.eql(u8, entry_name, dir_name)) return false;
        }
        return true;
    }
};

pub fn main(init: std.process.Init) !void {
    const runtime = support.RuntimeContext.fromInit(init);
    const alloc = runtime.allocator;
    const io = runtime.io;
    const environ = runtime.environ;
    const args = try support.argsToSlice(runtime.arena, init.minimal.args);
    g_io = io;
    defer g_io = null;

    // Parse args: optional filter substring and --diff flag
    var telemetry_args = zig_babal.TelemetryArgs{};
    defer telemetry_args.deinit(alloc);
    try telemetry_args.applyEnv(alloc, environ);
    try telemetry_args.setRunLabel(alloc, "codegen-test");

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        if (try telemetry_args.maybeConsumeArg(args, &arg_index)) continue;
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--diff")) {
            g_diff_mode = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            g_filter = arg;
        }
    }

    var telemetry_session: ?zig_babal.Telemetry.TelemetrySession = null;
    defer if (telemetry_session) |*session| session.deinit();
    if (telemetry_args.config.isEnabled()) {
        telemetry_session = try zig_babal.Telemetry.TelemetrySession.init(alloc, io, telemetry_args.config);
        if (telemetry_session) |*session| {
            g_telemetry = session;
            g_run_span = session.startSpan(null, .fixture, "run", "codegen-test", &.{});
            if (session.autoOutputDir()) |path| {
                std.debug.print("Telemetry artifacts: {s}\n", .{path});
            }
        }
    }
    defer {
        g_telemetry = null;
        g_run_span = null;
    }

    std.debug.print("Discovering codegen fixtures...\n", .{});
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }
    var base_dir = std.Io.Dir.cwd().openDir(io, FIXTURE_BASE, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open '{s}': {}\nHint: git submodule update --init\n", .{ FIXTURE_BASE, err });
        std.process.exit(1);
    };
    defer base_dir.close(io);
    var discovery = CodegenDiscovery{
        .paths = &paths,
        .caller_alloc = alloc,
    };
    try support.walkFixtureDirsFromBase(alloc, io, base_dir, FIXTURE_BASE, .{
        .user = &discovery,
        .decide_fixture = CodegenDiscovery.decideFixture,
        .on_fixture = CodegenDiscovery.onFixture,
        .should_descend = CodegenDiscovery.shouldDescend,
    });
    std.debug.print("Found {d} codegen fixture directories.\n", .{paths.items.len});
    if (g_telemetry) |session| {
        const fields = [_]zig_babal.Telemetry.Field{
            zig_babal.Telemetry.Field.unsigned("fixture_count", paths.items.len),
        };
        session.log(.info, "codegen-test", "discovered codegen fixtures", &fields);
    }

    var stats = Stats{};
    var work_index = std.atomic.Value(usize).init(0);
    const ctx = WorkContext{
        .paths = paths.items,
        .stats = &stats,
        .work_index = &work_index,
    };

    var threads: [NUM_THREADS]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..NUM_THREADS) |thread_index| {
        threads[thread_index] = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, workerThread, .{ctx}) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();

    const pass = stats.pass.load(.monotonic);
    const fail = stats.fail.load(.monotonic);
    const skip = stats.skip.load(.monotonic);
    const err_count = stats.err.load(.monotonic);

    const total = pass + fail;
    if (total > 0) {
        const rate = @as(f64, @floatFromInt(pass)) / @as(f64, @floatFromInt(total)) * 100.0;
        std.debug.print("\nCodegen conformance: {d:.1}% ({d} pass / {d} fail / {d} skip / {d} error)\n", .{ rate, pass, fail, skip, err_count });
    } else {
        std.debug.print("\nCodegen conformance: 0 pass / 0 fail / {d} skip / {d} error\n", .{ skip, err_count });
    }
    if (telemetry_session) |*session| {
        session.setCount("pass", pass);
        session.setCount("fail", fail);
        session.setCount("skip", skip);
        session.setCount("error", err_count);
        const fields = [_]zig_babal.Telemetry.Field{
            zig_babal.Telemetry.Field.unsigned("pass", pass),
            zig_babal.Telemetry.Field.unsigned("fail", fail),
            zig_babal.Telemetry.Field.unsigned("skip", skip),
            zig_babal.Telemetry.Field.unsigned("error", err_count),
        };
        session.finishSpan(spanPtr(&g_run_span), if (fail > 0 or err_count > 0) .fail else .ok, &fields);
    }
}

// === Worker thread — each owns a reusable arena ===

fn workerThread(ctx: WorkContext) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (true) {
        const idx = ctx.work_index.fetchAdd(1, .monotonic);
        if (idx >= ctx.paths.len) break;

        // Filter mode: only run fixtures matching substring
        if (g_filter) |f| {
            if (std.mem.indexOf(u8, ctx.paths[idx], f) == null) {
                _ = ctx.stats.skip.fetchAdd(1, .monotonic);
                continue;
            }
        }
        const r = runFixture(arena.allocator(), ctx.paths[idx]);
        switch (r) {
            .pass => _ = ctx.stats.pass.fetchAdd(1, .monotonic),
            .fail => _ = ctx.stats.fail.fetchAdd(1, .monotonic),
            .skip => _ = ctx.stats.skip.fetchAdd(1, .monotonic),
            .err => _ = ctx.stats.err.fetchAdd(1, .monotonic),
        }

        // Release excess pages back to the OS while keeping a small working set.
        _ = arena.reset(.{ .retain_with_limit = ARENA_RETAIN_LIMIT });

        const done = ctx.stats.pass.load(.monotonic) +
            ctx.stats.fail.load(.monotonic) +
            ctx.stats.skip.load(.monotonic) +
            ctx.stats.err.load(.monotonic);
        if (done % 200 == 0 and done > 0) {
            if (g_telemetry) |session| {
                const fields = [_]zig_babal.Telemetry.Field{
                    zig_babal.Telemetry.Field.unsigned("done", done),
                    zig_babal.Telemetry.Field.unsigned("total", ctx.paths.len),
                };
                session.log(.info, "codegen-test", "progress", &fields);
            }
        }
    }
}

// === Single fixture ===

const Result = enum { pass, fail, skip, err };

fn runFixture(alloc: std.mem.Allocator, fixture_path: []const u8) Result {
    var fixture_span = if (g_telemetry) |session|
        session.startSpan(runSpanPtr(), .fixture, "fixture", fixture_path, &.{})
    else
        null;

    const result = runFixtureInner(alloc, fixture_path) catch |e| {
        if (g_diff_mode or g_filter != null) {
            std.debug.print("ERROR: {s}: {}\n", .{ fixture_path, e });
        }
        if (g_telemetry) |session| {
            const fields = [_]zig_babal.Telemetry.Field{
                zig_babal.Telemetry.Field.string("error", @errorName(e)),
            };
            session.recordFailure("fixture", fixture_path, @errorName(e));
            session.finishSpan(spanPtr(&fixture_span), .err, &fields);
        }
        return .err;
    };

    if (g_telemetry) |session| {
        switch (result) {
            .pass => session.finishSpan(spanPtr(&fixture_span), .ok, &.{}),
            .fail => {
                session.recordFailure("fixture", fixture_path, "codegen mismatch");
                session.finishSpan(spanPtr(&fixture_span), .fail, &.{
                    zig_babal.Telemetry.Field.string("result", "fail"),
                });
            },
            .skip => session.finishSpan(spanPtr(&fixture_span), .skip, &.{}),
            .err => {
                session.recordFailure("fixture", fixture_path, "runner error");
                session.finishSpan(spanPtr(&fixture_span), .err, &.{
                    zig_babal.Telemetry.Field.string("result", "error"),
                });
            },
        }
    }

    return result;
}

fn runSpanPtr() ?*const zig_babal.Telemetry.SpanHandle {
    if (g_run_span) |*span| return span;
    return null;
}

fn spanPtr(span: *?zig_babal.Telemetry.SpanHandle) ?*const zig_babal.Telemetry.SpanHandle {
    if (span.*) |*value| return value;
    return null;
}

fn runFixtureInner(alloc: std.mem.Allocator, fixture_path: []const u8) !Result {
    const io = g_io orelse unreachable;
    var dir = try std.Io.Dir.cwd().openDir(io, fixture_path, .{});
    defer dir.close(io);

    // Check options (walks up directory tree for inherited options.json)
    const opts = try checkOptions(alloc, fixture_path);
    if (opts.skip) return .skip;

    // Read expected output
    const expected_raw = dir.readFileAlloc(io, "output.js", alloc, .limited(2 * 1024 * 1024)) catch return .skip;

    // Determine source type from options (default to module for generator tests, matching Babel)
    var source_type_val: zig_babal.SourceType = if (opts.has_source_type) opts.source_type else .module;

    // .mjs files are always modules
    if (source_type_val == .script) {
        if (dir.access(io, "input.mjs", .{})) |_| {
            source_type_val = .module;
        } else |_| {}
    }

    const parse_opts = zig_babal.ParseOptions{
        .strict_mode = opts.strict_mode orelse true, // Babel generator defaults to strictMode: true
        .source_type = source_type_val,
        .language = opts.language,
        .enable_v8_intrinsic = opts.has_v8_intrinsic,
        .enable_pipeline_operator = opts.has_pipeline_operator,
        .pipeline_proposal = opts.pipeline_proposal,
        .pipeline_topic_token = opts.pipeline_topic_token,
        .enable_decorators = opts.has_decorators,
        .decorators_legacy = opts.has_decorators_legacy,
        .decorators_before_export = opts.decorators_before_export,
        .enable_placeholders = opts.has_placeholders,
        .enable_do_expressions = opts.has_do_expressions,
        .enable_throw_expression = opts.has_throw_expressions,
        .enable_module_blocks = opts.has_module_blocks,
        .enable_partial_application = opts.has_partial_application,
        .enable_function_sent = opts.has_function_sent,
        .enable_export_default_from = opts.has_export_default_from,
        .enable_bind_operator = opts.has_bind_operator,
        .enable_destructuring_private = opts.has_destructuring_private,
        .enable_discard_binding = opts.has_discard_binding,
        .enable_import_source_phase = opts.has_source_phase_imports,
        .enable_deferred_import = opts.has_deferred_import,
        .enable_decorator_auto_accessors = opts.has_decorator_auto_accessors,
        .enable_optional_chaining_assign = opts.has_optional_chaining_assign,
        .enable_flow_comments = opts.has_flow_comments,
        .create_parenthesized_expressions = opts.create_parenthesized_expressions,
        .create_import_expressions = opts.create_import_expressions,
    };

    // Parse input
    const source = readInput(alloc, dir) orelse return .err;
    var result = zig_babal.parseWithOptions(alloc, source, parse_opts) catch {
        if (opts.throws) return .pass;
        return .err;
    };
    _ = &result;

    if (opts.throws) {
        // "throws" fixture — we expect an error during generation or that parsing failed
        if (result.errors.hasErrors()) return .pass;
        // Try generating — if it throws, that's a pass
        _ = zig_babal.Codegen.generate(&result.ast, .{}, alloc) catch return .pass;
        return .fail;
    }

    if (result.errors.hasErrors()) {
        if (g_diff_mode or g_filter != null) {
            std.debug.print("PARSE-ERROR: {s}\n", .{fixture_path});
            var stderr_buf: [8192]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(g_io orelse unreachable, &stderr_buf);
            const stderr = &stderr_writer.interface;
            result.errors.format(&result.ast, stderr) catch {};
            stderr.flush() catch {};
        }
        return .err;
    }

    // Generate code
    const gen = zig_babal.Codegen.generate(&result.ast, .{ .comments = opts.emit_comments }, alloc) catch {
        if (g_diff_mode or g_filter != null) {
            std.debug.print("CODEGEN-ERROR: {s}\n", .{fixture_path});
        }
        return .err;
    };

    // Compare: trim trailing whitespace/newlines from both, then strict equality
    const actual = std.mem.trimEnd(u8, gen.code, " \t\r\n");
    const expected = std.mem.trimEnd(u8, expected_raw, " \t\r\n");

    if (std.mem.eql(u8, actual, expected)) return .pass;

    // Failure — print details if in diff mode
    if (g_diff_mode or g_filter != null) {
        std.debug.print("FAIL: {s}\n", .{fixture_path});
        printTextDiff(expected, actual, fixture_path);
    }

    return .fail;
}

// === Text diff printer ===

fn printTextDiff(expected: []const u8, actual: []const u8, path: []const u8) void {
    // Find first difference location
    var line: usize = 1;
    var col: usize = 1;
    const min_len = @min(expected.len, actual.len);
    var diff_pos: usize = min_len; // default: difference is at end (length mismatch)
    for (0..min_len) |i| {
        if (expected[i] != actual[i]) {
            diff_pos = i;
            break;
        }
        if (expected[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }

    std.debug.print("  First diff at {s} line {d}:{d}\n", .{ path, line, col });

    // Show context around the difference
    const context_start = if (diff_pos > 60) diff_pos - 60 else 0;
    const exp_end = @min(diff_pos + 60, expected.len);
    const act_end = @min(diff_pos + 60, actual.len);

    std.debug.print("  Expected: ...{s}...\n", .{expected[context_start..exp_end]});
    std.debug.print("  Actual:   ...{s}...\n", .{actual[context_start..act_end]});
    std.debug.print("\n", .{});
}

fn dumpCommentAttachment(ast: *const zig_babal.Ast) void {
    const comments = ast.comments.items;
    if (comments.len == 0) return;
    const tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);
    const end_offsets = ast.nodes.items(.end_offset);

    std.debug.print("  === Comment Attachment ({d} comments) ===\n", .{comments.len});
    for (comments, 0..) |c, ci| {
        const text = ast.source[c.start..c.end];
        const short_text = if (text.len > 40) text[0..40] else text;
        std.debug.print("  C{d}: [{d}..{d}] {s}\n", .{ ci, c.start, c.end, short_text });
    }

    // Dump leading
    {
        var it = ast.leading_comments.iterator();
        while (it.next()) |entry| {
            const node_idx = entry.key_ptr.*;
            const range = entry.value_ptr.*;
            if (node_idx < tags.len) {
                const tag = tags[node_idx];
                const mt = @intFromEnum(main_tokens[node_idx]);
                const start = if (mt < ast.tokens.len) ast.tokens.items(.start)[mt] else 0;
                const end = end_offsets[node_idx];
                std.debug.print("  Leading on N{d}({s})[{d}..{d}]: C{d}..C{d}\n", .{
                    node_idx, @tagName(tag), start, end, range.start, range.end,
                });
            }
        }
    }
    // Dump trailing
    {
        var it = ast.trailing_comments.iterator();
        while (it.next()) |entry| {
            const node_idx = entry.key_ptr.*;
            const range = entry.value_ptr.*;
            if (node_idx < tags.len) {
                const tag = tags[node_idx];
                const mt = @intFromEnum(main_tokens[node_idx]);
                const start = if (mt < ast.tokens.len) ast.tokens.items(.start)[mt] else 0;
                const end = end_offsets[node_idx];
                std.debug.print("  Trailing on N{d}({s})[{d}..{d}]: C{d}..C{d}\n", .{
                    node_idx, @tagName(tag), start, end, range.start, range.end,
                });
            }
        }
    }
    // Dump inner
    {
        var it = ast.inner_comments.iterator();
        while (it.next()) |entry| {
            const node_idx = entry.key_ptr.*;
            const range = entry.value_ptr.*;
            if (node_idx < tags.len) {
                const tag = tags[node_idx];
                const mt = @intFromEnum(main_tokens[node_idx]);
                const start = if (mt < ast.tokens.len) ast.tokens.items(.start)[mt] else 0;
                const end = end_offsets[node_idx];
                std.debug.print("  Inner on N{d}({s})[{d}..{d}]: C{d}..C{d}\n", .{
                    node_idx, @tagName(tag), start, end, range.start, range.end,
                });
            }
        }
    }
    std.debug.print("  === End Comment Attachment ===\n", .{});
}

// === Options ===

const OptionsResult = struct {
    skip: bool = false,
    throws: bool = false,
    strict_mode: ?bool = null,
    language: zig_babal.Language = .javascript,
    source_type: zig_babal.SourceType = .module,
    has_source_type: bool = false,
    has_plugins_key: bool = false,
    has_v8_intrinsic: bool = false,
    has_pipeline_operator: bool = false,
    pipeline_proposal: zig_babal.ParseOptions.PipelineProposal = .hack,
    pipeline_topic_token: zig_babal.ParseOptions.PipelineTopicToken = .percent,
    has_decorators: bool = false,
    has_decorators_legacy: bool = false,
    decorators_before_export: bool = false,
    has_placeholders: bool = false,
    has_do_expressions: bool = false,
    has_throw_expressions: bool = false,
    has_module_blocks: bool = false,
    has_partial_application: bool = false,
    has_function_sent: bool = false,
    has_export_default_from: bool = false,
    has_bind_operator: bool = false,
    has_destructuring_private: bool = false,
    has_discard_binding: bool = false,
    has_source_phase_imports: bool = false,
    has_deferred_import: bool = false,
    has_decorator_auto_accessors: bool = false,
    has_optional_chaining_assign: bool = false,
    has_flow_comments: bool = false,
    has_import_attributes: bool = false,
    create_parenthesized_expressions: bool = false,
    create_import_expressions: bool = true,
    emit_comments: bool = true,
};

/// Check options.json with directory inheritance: walk up from fixture dir to FIXTURE_BASE.
fn checkOptions(caller_alloc: std.mem.Allocator, fixture_path: []const u8) !OptionsResult {
    _ = caller_alloc;
    var opts_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer opts_arena.deinit();
    const alloc = opts_arena.allocator();

    var result = OptionsResult{};
    var language_locked = false;
    var path = fixture_path;
    while (true) {
        const opts_path = try std.fmt.allocPrint(alloc, "{s}/options.json", .{path});
        const content = std.Io.Dir.cwd().readFileAlloc(g_io orelse unreachable, opts_path, alloc, .limited(64 * 1024)) catch |e| {
            if (e != error.FileNotFound) return .{ .skip = true };
            if (std.mem.eql(u8, path, FIXTURE_BASE) or path.len <= FIXTURE_BASE.len) break;
            path = std.fs.path.dirname(path) orelse break;
            continue;
        };

        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, content, .{}) catch return .{ .skip = true };
        const eval_result = evaluateOptions(value);
        if (eval_result.skip) return .{ .skip = true };
        if (eval_result.throws) return .{ .skip = true }; // skip throws fixtures (generator option validation)
        if (eval_result.strict_mode) |sm| {
            if (result.strict_mode == null) result.strict_mode = sm;
        }
        if (eval_result.has_source_type and !result.has_source_type) {
            result.source_type = eval_result.source_type;
            result.has_source_type = true;
        }
        // Only inherit language from parents if no closer options.json had "plugins"
        if (!language_locked) {
            if (eval_result.has_plugins_key) {
                result.language = eval_result.language;
                language_locked = true;
            } else if (result.language == .javascript and eval_result.language != .javascript) {
                result.language = eval_result.language;
            }
            if (eval_result.has_v8_intrinsic) result.has_v8_intrinsic = true;
            if (eval_result.has_pipeline_operator) {
                result.has_pipeline_operator = true;
                result.pipeline_proposal = eval_result.pipeline_proposal;
                result.pipeline_topic_token = eval_result.pipeline_topic_token;
            }
            if (eval_result.has_decorators) result.has_decorators = true;
            if (eval_result.has_decorators_legacy) result.has_decorators_legacy = true;
            if (eval_result.decorators_before_export) result.decorators_before_export = true;
            if (eval_result.has_placeholders) result.has_placeholders = true;
            if (eval_result.has_do_expressions) result.has_do_expressions = true;
            if (eval_result.has_throw_expressions) result.has_throw_expressions = true;
            if (eval_result.has_module_blocks) result.has_module_blocks = true;
            if (eval_result.has_partial_application) result.has_partial_application = true;
            if (eval_result.has_function_sent) result.has_function_sent = true;
            if (eval_result.has_export_default_from) result.has_export_default_from = true;
            if (eval_result.has_bind_operator) result.has_bind_operator = true;
            if (eval_result.has_destructuring_private) result.has_destructuring_private = true;
            if (eval_result.has_discard_binding) result.has_discard_binding = true;
            if (eval_result.has_source_phase_imports) result.has_source_phase_imports = true;
            if (eval_result.has_deferred_import) result.has_deferred_import = true;
            if (eval_result.has_decorator_auto_accessors) result.has_decorator_auto_accessors = true;
            if (eval_result.has_optional_chaining_assign) result.has_optional_chaining_assign = true;
            if (eval_result.has_flow_comments) result.has_flow_comments = true;
            if (eval_result.has_import_attributes) result.has_import_attributes = true;
            if (!eval_result.create_import_expressions) result.create_import_expressions = false;
            if (eval_result.create_parenthesized_expressions) result.create_parenthesized_expressions = true;
            if (!eval_result.emit_comments) result.emit_comments = false;
        }

        if (std.mem.eql(u8, path, FIXTURE_BASE) or path.len <= FIXTURE_BASE.len) break;
        path = std.fs.path.dirname(path) orelse break;
    }
    return result;
}

fn evaluateOptions(value: std.json.Value) OptionsResult {
    const obj = switch (value) {
        .object => |o| o,
        else => return .{},
    };

    // Check for generator-specific skip options
    var it = obj.iterator();
    while (it.next()) |entry| {
        for (SKIP_OPTIONS) |skip_key| {
            if (std.mem.eql(u8, entry.key_ptr.*, skip_key)) {
                return .{ .skip = true };
            }
        }
    }

    // Detect language and feature plugins from "plugins" key
    var has_typescript = false;
    var has_jsx = false;
    var has_flow = false;
    var has_v8_intrinsic = false;
    var has_pipeline_operator = false;
    var pipeline_proposal: zig_babal.ParseOptions.PipelineProposal = .hack;
    var pipeline_topic_token: zig_babal.ParseOptions.PipelineTopicToken = .percent;
    var has_decorators = false;
    var decorators_before_export = false;
    var has_decorators_legacy = false;
    var has_placeholders = false;
    var has_do_expressions = false;
    var has_throw_expressions = false;
    var has_module_blocks = false;
    var has_partial_application = false;
    var has_function_sent = false;
    var has_export_default_from = false;
    var has_bind_operator = false;
    var has_destructuring_private = false;
    var has_discard_binding = false;
    var has_source_phase_imports = false;
    var has_deferred_import = false;
    var has_decorator_auto_accessors = false;
    var has_optional_chaining_assign = false;
    var has_flow_comments = false;
    var has_import_attributes = false;

    if (obj.get("plugins")) |pv| {
        if (pv == .array) {
            for (pv.array.items) |plugin_val| {
                const plugin_name = switch (plugin_val) {
                    .string => |s| s,
                    .array => |arr| if (arr.items.len > 0) switch (arr.items[0]) {
                        .string => |s| s,
                        else => continue,
                    } else continue,
                    else => continue,
                };

                // Extract plugin options for array-form plugins
                const plugin_opts: ?std.json.ObjectMap = switch (plugin_val) {
                    .array => |arr| if (arr.items.len > 1) switch (arr.items[1]) {
                        .object => |o| o,
                        else => null,
                    } else null,
                    else => null,
                };

                if (std.mem.eql(u8, plugin_name, "typescript")) {
                    has_typescript = true;
                } else if (std.mem.eql(u8, plugin_name, "jsx")) {
                    has_jsx = true;
                } else if (std.mem.eql(u8, plugin_name, "flow")) {
                    has_flow = true;
                } else if (std.mem.eql(u8, plugin_name, "v8intrinsic")) {
                    has_v8_intrinsic = true;
                } else if (std.mem.eql(u8, plugin_name, "pipelineOperator")) {
                    has_pipeline_operator = true;
                    if (plugin_opts) |opts_obj| {
                        if (opts_obj.get("proposal")) |pval| {
                            if (pval == .string) {
                                if (std.mem.eql(u8, pval.string, "fsharp")) pipeline_proposal = .fsharp else if (std.mem.eql(u8, pval.string, "minimal")) pipeline_proposal = .minimal;
                            }
                        }
                        if (opts_obj.get("topicToken")) |tval| {
                            if (tval == .string) {
                                if (std.mem.eql(u8, tval.string, "#")) pipeline_topic_token = .hash else if (std.mem.eql(u8, tval.string, "^")) pipeline_topic_token = .caret else if (std.mem.eql(u8, tval.string, "^^")) pipeline_topic_token = .double_caret else if (std.mem.eql(u8, tval.string, "@@")) pipeline_topic_token = .double_at;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, plugin_name, "decorators")) {
                    has_decorators = true;
                    if (plugin_opts) |opts_obj| {
                        if (opts_obj.get("decoratorsBeforeExport")) |dbv| {
                            if (dbv == .bool) decorators_before_export = dbv.bool;
                        }
                    }
                } else if (std.mem.eql(u8, plugin_name, "decorators-legacy")) {
                    has_decorators_legacy = true;
                } else if (std.mem.eql(u8, plugin_name, "placeholders")) {
                    has_placeholders = true;
                } else if (std.mem.eql(u8, plugin_name, "doExpressions") or std.mem.eql(u8, plugin_name, "asyncDoExpressions")) {
                    has_do_expressions = true;
                } else if (std.mem.eql(u8, plugin_name, "throwExpressions")) {
                    has_throw_expressions = true;
                } else if (std.mem.eql(u8, plugin_name, "moduleBlocks")) {
                    has_module_blocks = true;
                } else if (std.mem.eql(u8, plugin_name, "partialApplication")) {
                    has_partial_application = true;
                } else if (std.mem.eql(u8, plugin_name, "functionSent")) {
                    has_function_sent = true;
                } else if (std.mem.eql(u8, plugin_name, "exportDefaultFrom")) {
                    has_export_default_from = true;
                } else if (std.mem.eql(u8, plugin_name, "functionBind")) {
                    has_bind_operator = true;
                } else if (std.mem.eql(u8, plugin_name, "destructuringPrivate")) {
                    has_destructuring_private = true;
                } else if (std.mem.eql(u8, plugin_name, "discardBinding")) {
                    has_discard_binding = true;
                } else if (std.mem.eql(u8, plugin_name, "sourcePhaseImports")) {
                    has_source_phase_imports = true;
                } else if (std.mem.eql(u8, plugin_name, "deferredImportEvaluation")) {
                    has_deferred_import = true;
                } else if (std.mem.eql(u8, plugin_name, "decoratorAutoAccessors")) {
                    has_decorator_auto_accessors = true;
                } else if (std.mem.eql(u8, plugin_name, "optionalChainingAssign")) {
                    has_optional_chaining_assign = true;
                } else if (std.mem.eql(u8, plugin_name, "flowComments")) {
                    has_flow_comments = true;
                } else if (std.mem.eql(u8, plugin_name, "importAttributes") or std.mem.eql(u8, plugin_name, "importAssertions")) {
                    has_import_attributes = true;
                }
            }
        }
    }

    var result_opts = OptionsResult{};
    result_opts.has_v8_intrinsic = has_v8_intrinsic;
    result_opts.has_pipeline_operator = has_pipeline_operator;
    result_opts.pipeline_proposal = pipeline_proposal;
    result_opts.pipeline_topic_token = pipeline_topic_token;
    result_opts.has_decorators = has_decorators or has_decorators_legacy;
    result_opts.has_decorators_legacy = has_decorators_legacy;
    result_opts.decorators_before_export = decorators_before_export;
    result_opts.has_placeholders = has_placeholders;
    result_opts.has_do_expressions = has_do_expressions;
    result_opts.has_throw_expressions = has_throw_expressions;
    result_opts.has_module_blocks = has_module_blocks;
    result_opts.has_partial_application = has_partial_application;
    result_opts.has_function_sent = has_function_sent;
    result_opts.has_export_default_from = has_export_default_from;
    result_opts.has_bind_operator = has_bind_operator;
    result_opts.has_destructuring_private = has_destructuring_private;
    result_opts.has_discard_binding = has_discard_binding;
    result_opts.has_source_phase_imports = has_source_phase_imports;
    result_opts.has_deferred_import = has_deferred_import;
    result_opts.has_decorator_auto_accessors = has_decorator_auto_accessors;
    result_opts.has_optional_chaining_assign = has_optional_chaining_assign;
    result_opts.has_flow_comments = has_flow_comments;
    result_opts.has_import_attributes = has_import_attributes;

    // Track whether this options.json had a "plugins" key
    if (obj.get("plugins") != null) {
        result_opts.has_plugins_key = true;
    }

    // Set language based on plugins
    if (has_typescript and has_jsx) {
        result_opts.language = .tsx;
    } else if (has_typescript) {
        result_opts.language = .typescript;
    } else if (has_flow) {
        result_opts.language = .flow;
    } else if (has_jsx) {
        result_opts.language = .jsx;
    }

    // Check throws
    if (obj.get("throws")) |t| {
        if (t == .bool and t.bool) {
            result_opts.throws = true;
        } else if (t == .string) {
            result_opts.throws = true;
        }
    }
    if (obj.get("throwMsg")) |_| {
        result_opts.throws = true;
    }

    // Check strictMode
    if (obj.get("strictMode")) |sm| {
        if (sm == .bool) result_opts.strict_mode = sm.bool;
    }

    // Check comments option (controls whether comments are emitted)
    if (obj.get("comments")) |cv| {
        if (cv == .bool) result_opts.emit_comments = cv.bool;
    }

    // Check sourceType
    if (obj.get("sourceType")) |st| {
        if (st == .string) {
            result_opts.has_source_type = true;
            if (std.mem.eql(u8, st.string, "module")) {
                result_opts.source_type = .module;
            } else if (std.mem.eql(u8, st.string, "script")) {
                result_opts.source_type = .script;
            }
        }
    }

    // Handle parserOpts — extract createImportExpressions and createParenthesizedExpressions
    if (obj.get("parserOpts")) |po| {
        if (po == .object) {
            if (po.object.get("createImportExpressions")) |civ| {
                if (civ == .bool) result_opts.create_import_expressions = civ.bool;
            }
            if (po.object.get("createParenthesizedExpressions")) |cpv| {
                if (cpv == .bool and cpv.bool) result_opts.create_parenthesized_expressions = true;
            }
        }
    }

    return result_opts;
}

// === Helpers ===

const INPUT_FILENAMES = [_][]const u8{ "input.js", "input.mjs", "input.ts", "input.tsx" };

fn readInput(alloc: std.mem.Allocator, dir: std.Io.Dir) ?[]const u8 {
    return support.readFirstExistingFileAlloc(
        g_io orelse unreachable,
        alloc,
        dir,
        INPUT_FILENAMES[0..],
        1 * 1024 * 1024,
    );
}
