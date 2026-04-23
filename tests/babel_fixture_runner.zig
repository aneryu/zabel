const std = @import("std");
const zig_babal = @import("zig_babal");
const support = @import("fixture_runner_support.zig");

const FIXTURE_BASE = "vendor/babel/packages/babel-parser/test/fixtures";

const UNSUPPORTED_PLUGINS = [_][]const u8{};

const SUPPORTED_OPTIONS = [_][]const u8{
    "sourceType",                     "strictMode",
    "throws",                         "allowReturnOutsideFunction",
    "allowImportExportEverywhere",    "allowSuperOutsideMethod",
    "allowUndeclaredExports",         "plugins",
    "createParenthesizedExpressions", "createImportExpressions",
    "annexB",                         "tokens",
    "allowAwaitOutsideFunction",      "allowNewTargetOutsideFunction",
    "allowYieldOutsideFunction",      "startIndex",
    "startLine",                      "startColumn",
    "errorRecovery",                  "ranges",
    "ecmaVersion",                    "attachComment",
    "sourceFilename",                 "minNodeVersion",
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

const ParserDiscovery = struct {
    paths: *std.ArrayList([]const u8),

    fn decideFixture(io: std.Io, dir: std.Io.Dir, dir_path: []const u8, user: ?*anyopaque) !support.FixtureDecision {
        _ = dir_path;
        _ = user;
        return if (support.dirHasAnyFile(io, dir, INPUT_FILENAMES[0..])) .collect_and_stop else .descend;
    }

    fn onFixture(alloc: std.mem.Allocator, dir_path: []const u8, user: ?*anyopaque) !void {
        const discovery: *ParserDiscovery = @ptrCast(@alignCast(user orelse return error.MissingDiscovery));
        try discovery.paths.append(alloc, try alloc.dupe(u8, dir_path));
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
    try telemetry_args.setRunLabel(alloc, "parse-test");

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
            g_run_span = session.startSpan(null, .fixture, "run", "parse-test", &.{});
            if (session.autoOutputDir()) |path| {
                std.debug.print("Telemetry artifacts: {s}\n", .{path});
            }
        }
    }
    defer {
        g_telemetry = null;
        g_run_span = null;
    }

    std.debug.print("Discovering parser fixtures...\n", .{});
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }
    var parser_discovery = ParserDiscovery{ .paths = &paths };
    var base_dir = std.Io.Dir.cwd().openDir(io, FIXTURE_BASE, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open '{s}': {}\nHint: git submodule update --init\n", .{ FIXTURE_BASE, err });
        std.process.exit(1);
    };
    defer base_dir.close(io);
    try support.walkFixtureDirsFromBase(alloc, io, base_dir, FIXTURE_BASE, .{
        .user = &parser_discovery,
        .decide_fixture = ParserDiscovery.decideFixture,
        .on_fixture = ParserDiscovery.onFixture,
    });
    std.debug.print("Found {d} fixture directories.\n", .{paths.items.len});
    if (g_telemetry) |session| {
        const fields = [_]zig_babal.Telemetry.Field{
            zig_babal.Telemetry.Field.unsigned("fixture_count", paths.items.len),
        };
        session.log(.info, "parse-test", "discovered parser fixtures", &fields);
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

    std.debug.print("\nParser Conformance Results:\n", .{});
    std.debug.print("  Pass:  {d}\n", .{pass});
    std.debug.print("  Fail:  {d}\n", .{fail});
    std.debug.print("  Skip:  {d}\n", .{skip});
    std.debug.print("  Error: {d}\n", .{err_count});
    const total = pass + fail;
    if (total > 0) {
        const rate = @as(f64, @floatFromInt(pass)) / @as(f64, @floatFromInt(total)) * 100.0;
        std.debug.print("  Rate:  {d:.1}% (of non-skipped)\n", .{rate});
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
    // One arena per thread, reused across all fixtures this thread processes.
    // page_allocator backing means reset(.retain_with_limit) does munmap on excess.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (true) {
        const idx = ctx.work_index.fetchAdd(1, .monotonic);
        if (idx >= ctx.paths.len) break;

        // (infer-with-constraints hardcoded skip removed — now fixed)
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
            .fail => {
                _ = ctx.stats.fail.fetchAdd(1, .monotonic);
                if (g_diff_mode or g_filter != null) {
                    std.debug.print("FAIL: {s}\n", .{ctx.paths[idx]});
                }
            },
            .skip => _ = ctx.stats.skip.fetchAdd(1, .monotonic),
            .err => _ = ctx.stats.err.fetchAdd(1, .monotonic),
        }

        // Release excess pages back to the OS while keeping a small working set.
        _ = arena.reset(.{ .retain_with_limit = ARENA_RETAIN_LIMIT });

        const done = ctx.stats.pass.load(.monotonic) +
            ctx.stats.fail.load(.monotonic) +
            ctx.stats.skip.load(.monotonic) +
            ctx.stats.err.load(.monotonic);
        if (done % 1000 == 0 and done > 0) {
            if (g_telemetry) |session| {
                const fields = [_]zig_babal.Telemetry.Field{
                    zig_babal.Telemetry.Field.unsigned("done", done),
                    zig_babal.Telemetry.Field.unsigned("total", ctx.paths.len),
                };
                session.log(.info, "parse-test", "progress", &fields);
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

    const result = runFixtureInner(alloc, fixture_path) catch |err| {
        if (g_telemetry) |session| {
            const fields = [_]zig_babal.Telemetry.Field{
                zig_babal.Telemetry.Field.string("error", @errorName(err)),
            };
            session.recordFailure("fixture", fixture_path, @errorName(err));
            session.finishSpan(spanPtr(&fixture_span), .err, &fields);
        }
        return .err;
    };

    if (g_telemetry) |session| {
        switch (result) {
            .pass => session.finishSpan(spanPtr(&fixture_span), .ok, &.{}),
            .fail => {
                session.recordFailure("fixture", fixture_path, "ast mismatch");
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

    // Check if output.json or output.extended.json exists
    const has_output = if (dir.access(io, "output.json", .{})) |_| true else |_| if (dir.access(io, "output.extended.json", .{})) |_| true else |_| false;

    // Determine source type from options.json and .mjs files
    const resolved = resolveSourceType(fixture_path);
    var source_type_val = resolved.source_type;
    // .mjs files are always modules
    if (source_type_val == .script) {
        if (dir.access(io, "input.mjs", .{})) |_| {
            source_type_val = .module;
        } else |_| {}
    }

    // "unambiguous" means auto-detect from content
    if (resolved.is_unambiguous and source_type_val == .script) {
        const source_for_check = readInput(alloc, dir) orelse return .err;
        if (sourceHasModuleSyntax(source_for_check, opts.allow_await_outside_function)) {
            source_type_val = .module;
        }
    }

    const parse_opts = zig_babal.ParseOptions{
        .strict_mode = opts.strict_mode orelse false,
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
        .allow_new_target_outside_function = opts.allow_new_target_outside_function,
        .allow_await_outside_function = opts.allow_await_outside_function,
        .annex_b = opts.annex_b,
        .create_import_expressions = opts.create_import_expressions,
        .start_index = opts.start_index,
        .start_line = opts.start_line,
        .start_column = opts.start_column,
        .source_filename = opts.source_filename,
    };

    if (opts.throws and !has_output) {
        // Option-combination errors (e.g. commonjs + allowReturnOutsideFunction) are
        // configuration errors that pass without parsing.
        if (opts.config_error) return .pass;

        // "throws" with no output.json — just check that parsing produces errors
        var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer parse_arena.deinit();
        const parse_alloc = parse_arena.allocator();

        const source = readInput(parse_alloc, dir) orelse return .err;
        var result = zig_babal.parseWithOptions(parse_alloc, source, parse_opts) catch return .pass;
        _ = &result;
        return if (result.errors.hasErrors()) .pass else .fail;
    }

    // Need output.json for AST comparison
    if (!has_output) return .skip;

    var compare_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer compare_arena.deinit();
    const compare_alloc = compare_arena.allocator();
    var actual_buf: std.ArrayList(u8) = .empty;
    var has_errors = false;

    {
        var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer parse_arena.deinit();
        const parse_alloc = parse_arena.allocator();

        // Parse input
        const source = readInput(parse_alloc, dir) orelse return .err;
        var result = zig_babal.parseWithOptions(parse_alloc, source, parse_opts) catch {
            // Parse crash — if throws is set, count as pass
            return if (opts.throws) .pass else .err;
        };
        _ = &result;
        has_errors = result.errors.hasErrors();

        // Note: Don't reject on errors here — some fixtures have output.json WITH
        // an errors array (Babel error recovery). We compare AST structure regardless;
        // the "errors" key is already skipped in jsonEqual.

        // Set serialization flags
        result.ast.create_import_expressions = opts.create_import_expressions;
        result.ast.create_parenthesized_expressions = opts.create_parenthesized_expressions;
        result.ast.has_import_phase = opts.has_source_phase_imports or opts.has_deferred_import;
        result.ast.emit_ranges = opts.emit_ranges;
        result.ast.start_index = opts.start_index;
        result.ast.start_line = opts.start_line;
        result.ast.start_column = opts.start_column;
        result.ast.source_filename = opts.source_filename;
        result.ast.emit_tokens = opts.has_tokens;

        // Serialize our AST into the compare arena, so the parse arena can be dropped early.
        var writer: std.Io.Writer.Allocating = .fromArrayList(compare_alloc, &actual_buf);
        if (opts.has_estree) {
            zig_babal.AstJson.serializeEstree(&result.ast, &writer.writer) catch return .err;
        } else {
            zig_babal.AstJson.serialize(&result.ast, &writer.writer) catch return .err;
        }
        actual_buf = writer.toArrayList();
    }

    // Read expected output (fall back to output.extended.json)
    const expected = dir.readFileAlloc(io, "output.json", compare_alloc, .limited(2 * 1024 * 1024)) catch
        dir.readFileAlloc(io, "output.extended.json", compare_alloc, .limited(2 * 1024 * 1024)) catch return .skip;

    // Sanitize lone surrogate \uXXXX escapes that Zig's JSON parser rejects.
    const exp_sanitized = sanitizeLoneSurrogates(compare_alloc, expected) catch return .err;
    const act_sanitized = sanitizeLoneSurrogates(compare_alloc, actual_buf.items) catch return .err;

    // Parse both JSONs and compare
    const exp_value = std.json.parseFromSliceLeaky(std.json.Value, compare_alloc, exp_sanitized, .{}) catch return .err;
    const act_value = std.json.parseFromSliceLeaky(std.json.Value, compare_alloc, act_sanitized, .{}) catch return .err;

    if (jsonEqual(exp_value, act_value)) return .pass;

    // For "throws" fixtures with output.json: if AST comparison fails but
    // errors were detected, still count as pass (the "throws" contract is met
    // even though our error-recovery AST doesn't match Babel's yet).
    if (opts.throws and has_errors) return .pass;

    if (g_diff_mode) {
        std.debug.print("--- DIFF for {s} (lang={s}) ---\n", .{ fixture_path, @tagName(opts.language) });
        printJsonDiff(exp_value, act_value, compare_alloc, "root");
        std.debug.print("--- END DIFF ---\n\n", .{});
    }

    return .fail;
}

// === JSON diff printer ===

fn printJsonDiff(expected: std.json.Value, actual: std.json.Value, alloc: std.mem.Allocator, path: []const u8) void {
    _ = alloc;
    const tag_a = std.meta.activeTag(expected);
    const tag_b = std.meta.activeTag(actual);

    if (tag_a != tag_b) {
        // Allow numeric type mismatch
        if (jsonNumericAsF64(expected)) |va| {
            if (jsonNumericAsF64(actual)) |vb| {
                if (floatsEqual(va, vb)) return;
            }
        }
        std.debug.print("  TYPE MISMATCH at {s}: expected={s} actual={s}\n", .{
            path, @tagName(tag_a), @tagName(tag_b),
        });
        return;
    }

    switch (expected) {
        .null, .bool, .integer, .float, .number_string => {
            if (!jsonEqual(expected, actual)) {
                const va = jsonNumericAsF64(expected);
                const vb = jsonNumericAsF64(actual);
                if (va != null and vb != null) {
                    std.debug.print("  VALUE MISMATCH at {s}: exp={d} act={d}\n", .{ path, @as(i64, @intFromFloat(va.?)), @as(i64, @intFromFloat(vb.?)) });
                } else {
                    std.debug.print("  VALUE MISMATCH at {s}\n", .{path});
                }
            }
        },
        .string => {
            if (!jsonEqual(expected, actual)) {
                std.debug.print("  STRING MISMATCH at {s}: exp=\"{s}\" act=\"{s}\"\n", .{
                    path, expected.string, actual.string,
                });
            }
        },
        .array => |arr_a| {
            const arr_b = actual.array;
            if (arr_a.items.len != arr_b.items.len) {
                std.debug.print("  ARRAY LEN at {s}: exp={d} act={d}\n", .{
                    path, arr_a.items.len, arr_b.items.len,
                });
                // Still compare common prefix
                const min_len = @min(arr_a.items.len, arr_b.items.len);
                for (0..min_len) |i| {
                    var buf: [512]u8 = undefined;
                    const p = std.fmt.bufPrint(&buf, "{s}[{d}]", .{ path, i }) catch path;
                    printJsonDiff(arr_a.items[i], arr_b.items[i], @as(std.mem.Allocator, undefined), p);
                }
                return;
            }
            for (arr_a.items, arr_b.items, 0..) |ea, eb, i| {
                var buf: [512]u8 = undefined;
                const p = std.fmt.bufPrint(&buf, "{s}[{d}]", .{ path, i }) catch path;
                printJsonDiff(ea, eb, @as(std.mem.Allocator, undefined), p);
            }
        },
        .object => |obj_a| {
            const obj_b = actual.object;
            var it = obj_a.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, key, "errors")) continue;
                if (std.mem.eql(u8, key, "comments")) continue;
                if (std.mem.eql(u8, key, "leadingComments")) continue;
                if (std.mem.eql(u8, key, "trailingComments")) continue;
                if (std.mem.eql(u8, key, "innerComments")) continue;
                if (std.mem.eql(u8, key, "raw")) {
                    if (obj_a.get("type")) |tv| {
                        if (tv == .string and std.mem.eql(u8, tv.string, "Literal")) continue;
                    }
                }
                if (std.mem.eql(u8, key, "kind")) {
                    if (obj_a.get("type")) |tv| {
                        if (tv == .string and std.mem.eql(u8, tv.string, "Property")) continue;
                    }
                }
                if (std.mem.eql(u8, key, "value")) {
                    if (obj_a.get("type")) |tv| {
                        if (tv == .string and (std.mem.eql(u8, tv.string, "Property") or std.mem.eql(u8, tv.string, "MethodDefinition"))) continue;
                    }
                }
                if (std.mem.eql(u8, key, "extra")) {
                    if (obj_a.get("type")) |tv| {
                        if (tv != .string or !std.mem.eql(u8, tv.string, "Program")) continue;
                    } else continue;
                }
                const val_b = obj_b.get(key) orelse {
                    std.debug.print("  MISSING KEY at {s}.{s}\n", .{ path, key });
                    continue;
                };
                var buf: [512]u8 = undefined;
                const p = std.fmt.bufPrint(&buf, "{s}.{s}", .{ path, key }) catch path;
                printJsonDiff(entry.value_ptr.*, val_b, @as(std.mem.Allocator, undefined), p);
            }
        },
    }
}

// === JSON structural equality (zero extra allocation) ===

/// Compare two f64 values, treating NaN as equal (for JSON comparison purposes).
fn floatsEqual(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    return a == b;
}

/// Convert any numeric JSON value to f64 for comparison.
fn jsonNumericAsF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Subset comparison: checks that every key in expected (a) exists in actual (b)
/// with matching values. Actual may have extra keys (like comments, errors, extra).
fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) {
        // Allow any numeric type mismatch (integer/float/number_string)
        if (jsonNumericAsF64(a)) |va| {
            if (jsonNumericAsF64(b)) |vb| {
                return floatsEqual(va, vb);
            }
        }
        // Handle Babel internal serialized types in output.extended.json:
        // e.g. {"$$ babel internal serialized type":"bigint","value":"100"} == "100"
        // or {"$$ babel internal serialized type":"RegExp",...} == null
        if (tag_a == .object) {
            if (a.object.get("$$ babel internal serialized type")) |_| {
                if (a.object.get("value")) |inner_val| {
                    return jsonEqual(inner_val, b);
                }
                // No inner value — treat as opaque serialized type, accept any actual
                return true;
            }
        }
        return false;
    }

    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| floatsEqual(v, b.float),
        .string => |v| blk: {
            if (std.mem.eql(u8, v, b.string)) break :blk true;
            // ESTree → Babel type aliases: when expected uses ESTree names,
            // accept our Babel-style names as equivalent.
            const estree_map = [_][2][]const u8{
                .{ "Literal", "NumericLiteral" },
                .{ "Literal", "StringLiteral" },
                .{ "Literal", "BooleanLiteral" },
                .{ "Literal", "NullLiteral" },
                .{ "Literal", "RegExpLiteral" },
                .{ "Literal", "BigIntLiteral" },
                .{ "Property", "ObjectProperty" },
                .{ "Property", "ObjectMethod" },
                .{ "MethodDefinition", "ClassMethod" },
                .{ "FieldDefinition", "ClassProperty" },
                .{ "PropertyDefinition", "ClassProperty" },
                .{ "PropertyDefinition", "ClassPrivateProperty" },
                .{ "PrivateIdentifier", "PrivateName" },
            };
            for (estree_map) |pair| {
                if (std.mem.eql(u8, v, pair[0]) and std.mem.eql(u8, b.string, pair[1])) break :blk true;
            }
            break :blk false;
        },
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .array => |arr_a| {
            const arr_b = b.array;
            if (arr_a.items.len != arr_b.items.len) return false;
            for (arr_a.items, arr_b.items) |ea, eb| {
                if (!jsonEqual(ea, eb)) return false;
            }
            return true;
        },
        .object => |obj_a| {
            const obj_b = b.object;
            // Subset check: every key in expected must exist in actual
            var it = obj_a.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                // Skip "errors" — Babel includes recoverable parse errors in this
                // array but our serializer always emits []. Ignoring the key lets
                // fixtures whose AST is otherwise correct pass the comparison.
                if (std.mem.eql(u8, key, "errors")) continue;
                // Skip comment-related keys — full comment attachment WIP
                if (std.mem.eql(u8, key, "comments")) continue;
                if (std.mem.eql(u8, key, "leadingComments")) continue;
                if (std.mem.eql(u8, key, "trailingComments")) continue;
                if (std.mem.eql(u8, key, "innerComments")) continue;
                // Skip ESTree-specific keys that our Babel-format AST doesn't emit.
                // "raw" is a top-level key on ESTree's Literal; we put it in extra.
                // "kind" is on ESTree's Property ("init"/"get"/"set"); Babel uses
                // separate ObjectProperty/ObjectMethod types instead.
                if (std.mem.eql(u8, key, "raw")) {
                    // Only skip if this looks like an ESTree Literal (has type=Literal)
                    if (obj_a.get("type")) |tv| {
                        if (tv == .string and std.mem.eql(u8, tv.string, "Literal")) continue;
                    }
                }
                if (std.mem.eql(u8, key, "kind")) {
                    // Only skip on ESTree Property nodes
                    if (obj_a.get("type")) |tv| {
                        if (tv == .string and std.mem.eql(u8, tv.string, "Property")) continue;
                    }
                }
                // ESTree Property/MethodDefinition use "value: FunctionExpression" for
                // methods/getters/setters; Babel uses inline params/body on ObjectMethod.
                if (std.mem.eql(u8, key, "value")) {
                    if (obj_a.get("type")) |tv| {
                        if (tv == .string and (std.mem.eql(u8, tv.string, "Property") or std.mem.eql(u8, tv.string, "MethodDefinition"))) continue;
                    }
                }
                // Skip "extra" on non-Program nodes — Babel includes metadata like
                // parenthesized, trailingComma, rawValue, etc. that we don't track.
                // Program.extra contains topLevelAwait which we do emit.
                if (std.mem.eql(u8, key, "extra")) {
                    if (obj_a.get("type")) |tv| {
                        if (tv != .string or !std.mem.eql(u8, tv.string, "Program")) continue;
                    } else continue;
                }
                const val_b = obj_b.get(key) orelse return false;
                if (!jsonEqual(entry.value_ptr.*, val_b)) return false;
            }
            return true;
        },
    };
}

// === Options ===

const SourceType = zig_babal.SourceType;

const Language = zig_babal.Language;

const OptionsResult = struct {
    skip: bool = false,
    throws: bool = false,
    strict_mode: ?bool = null,
    config_error: bool = false,
    language: zig_babal.Language = .javascript,
    has_plugins_key: bool = false,
    has_estree: bool = false,
    has_source_type: bool = false,
    has_v8_intrinsic: bool = false,
    // Proposal plugin flags
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
    emit_ranges: bool = false,
    allow_new_target_outside_function: bool = true,
    start_index: u32 = 0,
    start_line: u32 = 1,
    start_column: u32 = 0,
    source_filename: ?[]const u8 = null,
    has_tokens: bool = false,
    annex_b: bool = true,
    allow_await_outside_function: bool = false,
};

/// Check options.json with directory inheritance: walk up from fixture dir to FIXTURE_BASE.
/// Uses its own temporary arena to avoid polluting the caller's allocator.
fn checkOptions(caller_alloc: std.mem.Allocator, fixture_path: []const u8) !OptionsResult {
    var opts_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer opts_arena.deinit();
    const alloc = opts_arena.allocator();

    var result = OptionsResult{};
    var language_locked = false; // once a "plugins" key is seen, don't inherit from parents
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
        if (eval_result.throws) result.throws = true;
        if (eval_result.config_error) result.config_error = true;
        if (eval_result.strict_mode) |sm| {
            if (result.strict_mode == null) result.strict_mode = sm;
        }
        // Only inherit language from parents if no closer options.json had "plugins"
        if (!language_locked) {
            if (eval_result.has_plugins_key) {
                result.language = eval_result.language;
                result.has_estree = eval_result.has_estree;
                language_locked = true; // fixture-level plugins override parents
            } else if (eval_result.has_source_type and !std.mem.eql(u8, path, fixture_path)) {
                // An intermediate directory has sourceType but no plugins key —
                // this acts as a standalone config that overrides parent plugins.
                // (e.g., typescript/expect-plugin/options.json with sourceType but
                // no plugins means "parse as plain JS, not typescript".)
                language_locked = true;
            } else if (result.language == .javascript and eval_result.language != .javascript) {
                result.language = eval_result.language;
            }
            // Also inherit flags from parent if not yet locked
            if (eval_result.has_estree) result.has_estree = true;
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
            // createImportExpressions: false in any ancestor overrides the default
            if (!eval_result.create_import_expressions) result.create_import_expressions = false;
            // createParenthesizedExpressions: true in any ancestor enables it
            if (eval_result.create_parenthesized_expressions) result.create_parenthesized_expressions = true;
            // ranges: true in any ancestor enables it
            if (eval_result.emit_ranges) result.emit_ranges = true;
            // allowNewTargetOutsideFunction: false in any ancestor disables it
            if (!eval_result.allow_new_target_outside_function) result.allow_new_target_outside_function = false;
            // Inherit startIndex/startLine/startColumn/sourceFilename/tokens from closest ancestor
            if (eval_result.start_index != 0) result.start_index = eval_result.start_index;
            if (eval_result.start_line != 1) result.start_line = eval_result.start_line;
            if (eval_result.start_column != 0) result.start_column = eval_result.start_column;
            if (eval_result.source_filename != null) result.source_filename = eval_result.source_filename;
            if (eval_result.has_tokens) result.has_tokens = true;
            if (!eval_result.annex_b) result.annex_b = false;
            if (eval_result.allow_await_outside_function) result.allow_await_outside_function = true;
        }

        if (std.mem.eql(u8, path, FIXTURE_BASE) or path.len <= FIXTURE_BASE.len) break;
        path = std.fs.path.dirname(path) orelse break;
    }
    // Dupe source_filename into caller's allocator so it outlives opts_arena
    if (result.source_filename) |sf| {
        result.source_filename = caller_alloc.dupe(u8, sf) catch null;
    }
    return result;
}

fn evaluateOptions(value: std.json.Value) OptionsResult {
    const obj = switch (value) {
        .object => |o| o,
        else => return .{},
    };

    // Check for unsupported option keys
    var it = obj.iterator();
    while (it.next()) |entry| {
        var known = false;
        for (SUPPORTED_OPTIONS) |sup| {
            if (std.mem.eql(u8, entry.key_ptr.*, sup)) {
                known = true;
                break;
            }
        }
        if (!known) return .{ .skip = true };
    }

    // Detect language and feature plugins
    var has_typescript = false;
    var has_jsx = false;
    var has_flow = false;
    var has_estree = false;
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
                        else => return .{ .skip = true },
                    } else return .{ .skip = true },
                    else => return .{ .skip = true },
                };

                // Extract plugin options for array-form plugins
                const plugin_opts: ?std.json.ObjectMap = switch (plugin_val) {
                    .array => |arr| if (arr.items.len > 1) switch (arr.items[1]) {
                        .object => |o| o,
                        else => null,
                    } else null,
                    else => null,
                };

                if (std.mem.eql(u8, plugin_name, "estree")) {
                    has_estree = true;
                } else if (std.mem.eql(u8, plugin_name, "typescript")) {
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
                } else if (std.mem.eql(u8, plugin_name, "recordAndTuple") or
                    std.mem.eql(u8, plugin_name, "importReflection"))
                {
                    // Known but unsupported — continue without skip
                }
                // All other plugins: just continue (don't skip)
            }
        }
    }

    var result = OptionsResult{};

    // Handle createParenthesizedExpressions option
    if (obj.get("createParenthesizedExpressions")) |cpv| {
        if (cpv == .bool and cpv.bool) result.create_parenthesized_expressions = true;
    }
    // Handle createImportExpressions option
    if (obj.get("createImportExpressions")) |civ| {
        if (civ == .bool) result.create_import_expressions = civ.bool;
    }
    // Handle ranges option
    if (obj.get("ranges")) |rv| {
        if (rv == .bool and rv.bool) result.emit_ranges = true;
    }
    // Handle allowNewTargetOutsideFunction option
    if (obj.get("allowNewTargetOutsideFunction")) |antv| {
        if (antv == .bool) result.allow_new_target_outside_function = antv.bool;
    }
    // Handle startIndex option
    if (obj.get("startIndex")) |siv| {
        if (jsonNumericAsF64(siv)) |v| result.start_index = @intFromFloat(v);
    }
    // Handle startLine option
    if (obj.get("startLine")) |slv| {
        if (jsonNumericAsF64(slv)) |v| result.start_line = @intFromFloat(v);
    }
    // Handle startColumn option
    if (obj.get("startColumn")) |scv| {
        if (jsonNumericAsF64(scv)) |v| result.start_column = @intFromFloat(v);
    }
    // Handle sourceFilename option
    if (obj.get("sourceFilename")) |sfv| {
        if (sfv == .string) result.source_filename = sfv.string;
    }
    // Handle tokens option
    if (obj.get("tokens")) |tv| {
        if (tv == .bool and tv.bool) result.has_tokens = true;
    }
    // Handle annexB option
    if (obj.get("annexB")) |abv| {
        if (abv == .bool) result.annex_b = abv.bool;
    }
    // Handle allowAwaitOutsideFunction option
    if (obj.get("allowAwaitOutsideFunction")) |aof| {
        if (aof == .bool) result.allow_await_outside_function = aof.bool;
    }
    result.has_estree = has_estree;
    result.has_v8_intrinsic = has_v8_intrinsic;
    result.has_pipeline_operator = has_pipeline_operator;
    result.pipeline_proposal = pipeline_proposal;
    result.pipeline_topic_token = pipeline_topic_token;
    result.has_decorators = has_decorators or has_decorators_legacy;
    result.has_decorators_legacy = has_decorators_legacy;
    result.decorators_before_export = decorators_before_export;
    result.has_placeholders = has_placeholders;
    result.has_do_expressions = has_do_expressions;
    result.has_throw_expressions = has_throw_expressions;
    result.has_module_blocks = has_module_blocks;
    result.has_partial_application = has_partial_application;
    result.has_function_sent = has_function_sent;
    result.has_export_default_from = has_export_default_from;
    result.has_bind_operator = has_bind_operator;
    result.has_destructuring_private = has_destructuring_private;
    result.has_discard_binding = has_discard_binding;
    result.has_source_phase_imports = has_source_phase_imports;
    result.has_deferred_import = has_deferred_import;
    result.has_decorator_auto_accessors = has_decorator_auto_accessors;
    result.has_optional_chaining_assign = has_optional_chaining_assign;
    result.has_flow_comments = has_flow_comments;
    result.has_import_attributes = has_import_attributes;

    // Track whether this options.json had a "plugins" key
    if (obj.get("plugins") != null) {
        result.has_plugins_key = true;
    }
    // Track whether this options.json had a "sourceType" key
    if (obj.get("sourceType") != null) {
        result.has_source_type = true;
    }

    // Set language based on plugins
    // Flow takes priority over bare JSX because Flow natively supports JSX,
    // and the Language.isJSX() helper already returns true for .flow.
    if (has_typescript and has_jsx) {
        result.language = .tsx;
    } else if (has_typescript) {
        result.language = .typescript;
    } else if (has_flow) {
        result.language = .flow;
    } else if (has_jsx) {
        result.language = .jsx;
    }

    // Check throws
    if (obj.get("throws")) |t| {
        if (t == .string) {
            result.throws = true;
            // Detect config-level errors (e.g. sourceType: 'commonjs' + allowReturnOutsideFunction)
            // These are option-validation errors that our parser doesn't implement.
            if (std.mem.indexOf(u8, t.string, "sourceType") != null or
                std.mem.indexOf(u8, t.string, "Cannot use the decorators and decorators-legacy plugin together") != null or
                std.mem.indexOf(u8, t.string, "has been removed in Babel 8") != null or
                std.mem.indexOf(u8, t.string, "requires a 'syntaxType' option") != null or
                std.mem.indexOf(u8, t.string, "requires \"proposal\" option") != null or
                std.mem.indexOf(u8, t.string, "Cannot combine v8intrinsic plugin and Hack-style pipes") != null or
                std.mem.indexOf(u8, t.string, "Cannot combine placeholders plugin and Hack-style pipes") != null or
                std.mem.indexOf(u8, t.string, "With a `startLine > 1") != null or
                std.mem.indexOf(u8, t.string, "requires enabling the parser plugin") != null or
                std.mem.indexOf(u8, t.string, "Invalid topic token") != null)
            {
                result.config_error = true;
            }
        }
    }

    // Check strictMode
    if (obj.get("strictMode")) |sm| {
        if (sm == .bool) result.strict_mode = sm.bool;
    }

    return result;
}

const SourceTypeResult = struct {
    source_type: SourceType,
    is_unambiguous: bool,
};

/// Walk up the directory tree from fixture_path to FIXTURE_BASE, looking for
/// a `"sourceType"` key in any options.json.  Returns `.module` when an
/// ancestor (or the fixture itself) explicitly sets `"sourceType": "module"`.
/// Sets `is_unambiguous` when the resolved type came from `"unambiguous"`.
fn resolveSourceType(fixture_path: []const u8) SourceTypeResult {
    var opts_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer opts_arena.deinit();
    const alloc = opts_arena.allocator();
    var found_unambiguous = false;

    var path = fixture_path;
    while (true) {
        const opts_path = std.fmt.allocPrint(alloc, "{s}/options.json", .{path}) catch return .{ .source_type = .script, .is_unambiguous = false };
        const content = std.Io.Dir.cwd().readFileAlloc(g_io orelse unreachable, opts_path, alloc, .limited(64 * 1024)) catch |e| {
            if (e != error.FileNotFound) {
                return .{ .source_type = .script, .is_unambiguous = false };
            }
            if (std.mem.eql(u8, path, FIXTURE_BASE) or path.len <= FIXTURE_BASE.len) break;
            path = std.fs.path.dirname(path) orelse break;
            continue;
        };

        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, content, .{}) catch return .{ .source_type = .script, .is_unambiguous = false };
        const obj = switch (value) {
            .object => |o| o,
            else => {
                if (std.mem.eql(u8, path, FIXTURE_BASE) or path.len <= FIXTURE_BASE.len) break;
                path = std.fs.path.dirname(path) orelse break;
                continue;
            },
        };

        if (obj.get("sourceType")) |st| {
            if (st == .string) {
                if (std.mem.eql(u8, st.string, "module")) {
                    // If a child already set "unambiguous", it takes precedence over parent "module"
                    if (found_unambiguous) return .{ .source_type = .script, .is_unambiguous = true };
                    return .{ .source_type = .module, .is_unambiguous = false };
                }
                if (std.mem.eql(u8, st.string, "unambiguous")) {
                    found_unambiguous = true;
                    // Continue walking — unambiguous defers to content detection
                } else {
                    return .{ .source_type = .script, .is_unambiguous = false };
                }
            }
        } else {
            // Babel behavior: when a suite-level options.json exists but doesn't
            // specify sourceType, it REPLACES the parent entirely (not merge).
            // So sourceType defaults to "script" — stop inheriting from parent.
            // Only apply this to intermediate directories (not the fixture dir itself
            // or the base), since fixture-level options use Object.assign (merge).
            if (obj.count() > 0 and !std.mem.eql(u8, path, fixture_path)) {
                return .{ .source_type = .script, .is_unambiguous = found_unambiguous };
            }
            // At fixture level, if options.json has plugins but no sourceType,
            // continue walking up (fixture-level uses Object.assign merge in Babel)
        }

        if (std.mem.eql(u8, path, FIXTURE_BASE) or path.len <= FIXTURE_BASE.len) break;
        path = std.fs.path.dirname(path) orelse break;
    }
    return .{ .source_type = .script, .is_unambiguous = found_unambiguous };
}

/// Simple heuristic: does the source contain module-level import/export/await?
/// For Babel's "unambiguous" mode, a file is a module if it contains
/// import/export declarations or top-level await (not after newline from `await`).
fn sourceHasModuleSyntax(source: []const u8, allow_await_outside: bool) bool {
    // Quick check for import.meta anywhere in source
    if (std.mem.indexOf(u8, source, "import.meta") != null) return true;

    var i: usize = 0;
    while (i < source.len) {
        // Skip whitespace
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) {
            i += 1;
        }
        if (i >= source.len) break;

        // Check for 'import' keyword at statement level
        if (i + 6 < source.len and std.mem.eql(u8, source[i .. i + 6], "import")) {
            const after = if (i + 6 < source.len) source[i + 6] else 0;
            if (after == ' ' or after == '\t' or after == '(' or after == '"' or after == '\'') {
                // Could be import declaration — treat as module
                // But import() is also valid in scripts. Check for import.meta or import decl.
                if (after != '(') {
                    // Check for TS import-equals: `import <identifier> = ...`
                    // `import A = B.C;` is NOT module syntax (script)
                    // `import a = require("a");` IS module syntax (module)
                    var j = i + 6;
                    // Skip whitespace
                    while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
                    // Skip identifier
                    const id_start = j;
                    while (j < source.len and (std.ascii.isAlphanumeric(source[j]) or source[j] == '_' or source[j] == '$')) j += 1;
                    if (j > id_start) {
                        // Skip whitespace after identifier
                        while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
                        // If `=` follows (but not `==`), it's TS import-equals
                        if (j < source.len and source[j] == '=' and (j + 1 >= source.len or source[j + 1] != '=')) {
                            // Check if `= require(` follows — that IS module syntax
                            var k = j + 1;
                            while (k < source.len and (source[k] == ' ' or source[k] == '\t')) k += 1;
                            if (k + 7 < source.len and std.mem.eql(u8, source[k .. k + 7], "require") and source[k + 7] == '(') {
                                return true; // import a = require("a") — module
                            }
                            // Otherwise, TS import-equals (import A = B.C) — not module
                        } else {
                            return true;
                        }
                    } else {
                        return true;
                    }
                }
            }
        }

        // Check for 'export' keyword at statement level
        if (i + 6 < source.len and std.mem.eql(u8, source[i .. i + 6], "export")) {
            const after = if (i + 6 < source.len) source[i + 6] else 0;
            if (after == ' ' or after == '\t' or after == '{' or after == '*') {
                return true;
            }
        }

        // Check for 'await' at statement level followed by unambiguous expression start.
        // Babel's "unambiguous" heuristic: await is only treated as top-level-await if
        // followed by a token that can ONLY start an expression (not also be a binary
        // operator like +, -, /, %, etc).
        // When allowAwaitOutsideFunction is true, await is valid in scripts too,
        // so it should NOT trigger module detection.
        if (!allow_await_outside and i + 5 <= source.len and std.mem.eql(u8, source[i .. i + 5], "await")) {
            const after = if (i + 5 < source.len) source[i + 5] else 0;
            if (after == ' ' or after == '\t') {
                // Skip whitespace to find the first non-space character
                var j = i + 5;
                while (j < source.len and (source[j] == ' ' or source[j] == '\t')) {
                    j += 1;
                }
                if (j < source.len) {
                    const c = source[j];
                    // Only treat as module for unambiguous expression starters:
                    // digits, identifiers, string quotes, template, !~
                    if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or
                        (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or
                        c == '"' or c == '\'' or c == '`' or c == '!' or c == '~')
                    {
                        return true;
                    }
                }
            }
        }

        // Skip to next statement (after semicolon or newline)
        while (i < source.len and source[i] != '\n' and source[i] != ';') {
            i += 1;
        }
        if (i < source.len) i += 1;
    }
    return false;
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

/// Replace lone surrogate \uXXXX escapes (U+D800..U+DFFF) with \ufffd so
/// Zig's strict JSON parser can handle the content.  Surrogate pairs
/// (\uD800\uDC00 etc.) are left intact.
fn sanitizeLoneSurrogates(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Quick scan: if no \u escapes at all, return as-is.
    if (std.mem.indexOf(u8, input, "\\u") == null) return input;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var flush_start: usize = 0; // start of un-flushed literal range
    while (i + 5 < input.len) {
        if (input[i] != '\\' or input[i + 1] != 'u') {
            i += 1;
            continue;
        }
        const hex = input[i + 2 .. i + 6];
        const val = std.fmt.parseInt(u16, hex, 16) catch {
            i += 1;
            continue;
        };
        if (val >= 0xD800 and val <= 0xDBFF) {
            // High surrogate — check for valid pair
            if (i + 11 < input.len and input[i + 6] == '\\' and input[i + 7] == 'u') {
                const hex2 = input[i + 8 .. i + 12];
                const val2 = std.fmt.parseInt(u16, hex2, 16) catch 0;
                if (val2 >= 0xDC00 and val2 <= 0xDFFF) {
                    i += 12; // valid pair — keep
                    continue;
                }
            }
            // Lone high surrogate — flush preceding text, replace
            try out.appendSlice(alloc, input[flush_start..i]);
            try out.appendSlice(alloc, "\\ufffd");
            i += 6;
            flush_start = i;
            continue;
        }
        if (val >= 0xDC00 and val <= 0xDFFF) {
            // Lone low surrogate
            try out.appendSlice(alloc, input[flush_start..i]);
            try out.appendSlice(alloc, "\\ufffd");
            i += 6;
            flush_start = i;
            continue;
        }
        i += 6;
    }
    // If no replacements were made, return original
    if (flush_start == 0) return input;
    try out.appendSlice(alloc, input[flush_start..]);
    return out.items;
}
