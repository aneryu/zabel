const std = @import("std");
const zig_babal = @import("zig_babal");

const PreparedCommandArgs = struct {
    telemetry_args: zig_babal.TelemetryArgs,
    filtered_args: std.ArrayList([]const u8),

    fn deinit(self: *PreparedCommandArgs, allocator: std.mem.Allocator) void {
        self.telemetry_args.deinit(allocator);
        self.filtered_args.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.minimal.environ;
    const args = try argsToSlice(arena, init.minimal.args);

    if (args.len < 2) {
        try printUsage(io);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "parse")) {
        try runParse(io, allocator, environ, args[2..]);
    } else if (std.mem.eql(u8, command, "print")) {
        try runPrint(io, allocator, environ, args[2..]);
    } else if (std.mem.eql(u8, command, "transform")) {
        try runTransform(io, allocator, environ, args[2..]);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(io);
    } else {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("unknown command: {s}\n", .{command});
        try stderr.flush();
        try printUsage(io);
        std.process.exit(1);
    }
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn prepareCommandArgs(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    raw_args: []const []const u8,
    run_label: []const u8,
) !PreparedCommandArgs {
    var prepared = PreparedCommandArgs{
        .telemetry_args = .{},
        .filtered_args = .empty,
    };
    errdefer prepared.deinit(allocator);

    try prepared.telemetry_args.applyEnv(allocator, environ);
    try prepared.telemetry_args.setRunLabel(allocator, run_label);

    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        if (try prepared.telemetry_args.maybeConsumeArg(raw_args, &i)) continue;
        try prepared.filtered_args.append(allocator, raw_args[i]);
    }

    return prepared;
}

fn announceTelemetry(session: *zig_babal.Telemetry.TelemetrySession) void {
    if (session.autoOutputDir()) |path| {
        std.debug.print("Telemetry artifacts: {s}\n", .{path});
    }
}

fn spanPtr(span: *?zig_babal.Telemetry.SpanHandle) ?*const zig_babal.Telemetry.SpanHandle {
    if (span.*) |*value| return value;
    return null;
}

fn runParse(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8) !void {
    var prepared = try prepareCommandArgs(allocator, environ, args, "parse");
    defer prepared.deinit(allocator);
    const cmd_args = prepared.filtered_args.items;

    if (cmd_args.len == 0) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try stderr.writeAll("error: missing input file\nusage: zig-babal parse <file>\n");
        try stderr.flush();
        std.process.exit(1);
    }

    const file_path = cmd_args[0];

    // Read source file
    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(50 * 1024 * 1024)) catch |err| {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("error: cannot read file '{s}': {}\n", .{ file_path, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(source);

    var telemetry_session: ?zig_babal.Telemetry.TelemetrySession = null;
    defer if (telemetry_session) |*session| session.deinit();
    var run_span: ?zig_babal.Telemetry.SpanHandle = null;
    if (prepared.telemetry_args.config.isEnabled()) {
        telemetry_session = try zig_babal.Telemetry.TelemetrySession.init(allocator, io, prepared.telemetry_args.config);
        if (telemetry_session) |*session| {
            announceTelemetry(session);
            run_span = session.startSpan(null, .fixture, "run", "parse", &.{
                zig_babal.Telemetry.Field.string("file", file_path),
            });
        }
    }

    // Parse
    var parse_span = if (telemetry_session) |*session|
        session.startSpan(spanPtr(&run_span), .pass, "phase", "parse", &.{})
    else
        null;
    var result = try zig_babal.parse(allocator, source);
    defer result.deinit();
    if (telemetry_session) |*session| {
        session.finishSpan(spanPtr(&parse_span), if (result.errors.hasErrors()) .fail else .ok, &.{
            zig_babal.Telemetry.Field.unsigned("node_count", @intCast(result.ast.nodes.len)),
        });
    }

    // Report errors
    if (result.errors.hasErrors()) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try result.errors.format(&result.ast, stderr);
        try stderr.flush();
    }

    // Serialize to JSON
    var stdout_buf: [65536]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try zig_babal.AstJson.serialize(&result.ast, stdout);
    try stdout.writeAll("\n");
    try stdout.flush();
    if (telemetry_session) |*session| {
        session.finishSpan(spanPtr(&run_span), if (result.errors.hasErrors()) .fail else .ok, &.{
            zig_babal.Telemetry.Field.boolean("has_errors", result.errors.hasErrors()),
        });
    }
}

fn runPrint(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8) !void {
    var prepared = try prepareCommandArgs(allocator, environ, args, "print");
    defer prepared.deinit(allocator);
    const cmd_args = prepared.filtered_args.items;

    if (cmd_args.len == 0) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try stderr.writeAll("error: missing input file\nusage: zig-babal print <file> [--source-map]\n");
        try stderr.flush();
        std.process.exit(1);
    }

    const file_path = cmd_args[0];

    // Check for --source-map flag
    var has_source_map = false;
    for (cmd_args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--source-map")) {
            has_source_map = true;
        }
    }

    // Read source file
    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(50 * 1024 * 1024)) catch |err| {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("error: cannot read file '{s}': {}\n", .{ file_path, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(source);

    var telemetry_session: ?zig_babal.Telemetry.TelemetrySession = null;
    defer if (telemetry_session) |*session| session.deinit();
    var run_span: ?zig_babal.Telemetry.SpanHandle = null;
    if (prepared.telemetry_args.config.isEnabled()) {
        telemetry_session = try zig_babal.Telemetry.TelemetrySession.init(allocator, io, prepared.telemetry_args.config);
        if (telemetry_session) |*session| {
            announceTelemetry(session);
            run_span = session.startSpan(null, .fixture, "run", "print", &.{
                zig_babal.Telemetry.Field.string("file", file_path),
                zig_babal.Telemetry.Field.boolean("source_map", has_source_map),
            });
        }
    }

    // Parse
    var parse_span = if (telemetry_session) |*session|
        session.startSpan(spanPtr(&run_span), .pass, "phase", "parse", &.{})
    else
        null;
    var result = try zig_babal.parse(allocator, source);
    defer result.deinit();
    if (telemetry_session) |*session| {
        session.finishSpan(spanPtr(&parse_span), if (result.errors.hasErrors()) .fail else .ok, &.{
            zig_babal.Telemetry.Field.unsigned("node_count", @intCast(result.ast.nodes.len)),
        });
    }

    // Report parse errors
    if (result.errors.hasErrors()) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try result.errors.format(&result.ast, stderr);
        try stderr.flush();
    }

    // Generate code
    var codegen_span = if (telemetry_session) |*session|
        session.startSpan(spanPtr(&run_span), .pass, "phase", "codegen", &.{})
    else
        null;
    const gen = try zig_babal.Codegen.generate(&result.ast, .{ .source_maps = has_source_map }, allocator);
    defer gen.deinit(allocator);
    if (telemetry_session) |*session| {
        session.finishSpan(spanPtr(&codegen_span), .ok, &.{
            zig_babal.Telemetry.Field.unsigned("generated_len", @intCast(gen.code.len)),
        });
    }

    // Write generated code to stdout
    var stdout_buf: [65536]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(gen.code);
    try stdout.writeAll("\n");
    try stdout.flush();

    // If --source-map, write map to stderr
    if (has_source_map) {
        if (gen.map) |map| {
            var stderr_buf: [65536]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
            const stderr = &stderr_writer.interface;
            try stderr.writeAll(map);
            try stderr.writeAll("\n");
            try stderr.flush();
        }
    }
    if (telemetry_session) |*session| {
        session.finishSpan(spanPtr(&run_span), if (result.errors.hasErrors()) .fail else .ok, &.{
            zig_babal.Telemetry.Field.boolean("has_errors", result.errors.hasErrors()),
        });
    }
}

fn runTransform(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ, args: []const []const u8) !void {
    var prepared = try prepareCommandArgs(allocator, environ, args, "transform");
    defer prepared.deinit(allocator);
    const cmd_args = prepared.filtered_args.items;

    if (cmd_args.len == 0) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try stderr.writeAll("error: missing input file\nusage: zig-babal transform <file> [--jsx-runtime classic|automatic] [--target es2015|es2016|es2017|es2018|es2019|es2020|es2021|es2022|es2023|es2024|es2025|esnext] [--source-map]\n");
        try stderr.flush();
        std.process.exit(1);
    }

    const file_path = cmd_args[0];

    // Detect language from file extension
    const language: zig_babal.Language = blk: {
        if (std.mem.endsWith(u8, file_path, ".tsx")) break :blk .tsx;
        if (std.mem.endsWith(u8, file_path, ".ts")) break :blk .typescript;
        if (std.mem.endsWith(u8, file_path, ".jsx")) break :blk .jsx;
        break :blk .javascript;
    };

    // Parse --jsx-runtime and --target flags
    var jsx_runtime: zig_babal.JsxTransform.JsxRuntime = .classic;
    var target = zig_babal.Target.esnext;
    var has_source_map = false;
    var i: usize = 1;
    while (i < cmd_args.len) : (i += 1) {
        if (std.mem.eql(u8, cmd_args[i], "--jsx-runtime")) {
            i += 1;
            if (i >= cmd_args.len) {
                var stderr_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
                const stderr = &stderr_writer.interface;
                try stderr.writeAll("error: --jsx-runtime requires a value (classic|automatic)\n");
                try stderr.flush();
                std.process.exit(1);
            }
            if (std.mem.eql(u8, cmd_args[i], "automatic")) {
                jsx_runtime = .automatic;
            } else if (std.mem.eql(u8, cmd_args[i], "classic")) {
                jsx_runtime = .classic;
            } else {
                var stderr_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
                const stderr = &stderr_writer.interface;
                try stderr.print("error: unknown --jsx-runtime value: {s}\n", .{cmd_args[i]});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, cmd_args[i], "--target")) {
            i += 1;
            if (i >= cmd_args.len) {
                var stderr_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
                const stderr = &stderr_writer.interface;
                try stderr.writeAll("error: --target requires a value (e.g. es2015)\n");
                try stderr.flush();
                std.process.exit(1);
            }
            if (zig_babal.Target.parse(cmd_args[i])) |parsed_target| {
                target = parsed_target;
            } else {
                var stderr_buf: [4096]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
                const stderr = &stderr_writer.interface;
                try stderr.print("error: unknown --target value: {s}\n", .{cmd_args[i]});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, cmd_args[i], "--source-map")) {
            has_source_map = true;
        }
    }

    // Read source file
    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(50 * 1024 * 1024)) catch |err| {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("error: cannot read file '{s}': {}\n", .{ file_path, err });
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(source);

    var telemetry_session: ?zig_babal.Telemetry.TelemetrySession = null;
    defer if (telemetry_session) |*session| session.deinit();
    var run_span: ?zig_babal.Telemetry.SpanHandle = null;
    if (prepared.telemetry_args.config.isEnabled()) {
        telemetry_session = try zig_babal.Telemetry.TelemetrySession.init(allocator, io, prepared.telemetry_args.config);
        if (telemetry_session) |*session| {
            announceTelemetry(session);
            run_span = session.startSpan(null, .fixture, "run", "transform", &.{
                zig_babal.Telemetry.Field.string("file", file_path),
                zig_babal.Telemetry.Field.string("language", @tagName(language)),
                zig_babal.Telemetry.Field.string("target", @tagName(target)),
                zig_babal.Telemetry.Field.boolean("source_map", has_source_map),
            });
        }
    }

    // Parse with language-appropriate options
    var parse_span = if (telemetry_session) |*session|
        session.startSpan(spanPtr(&run_span), .pass, "phase", "parse", &.{})
    else
        null;
    var result = try zig_babal.parseWithOptions(allocator, source, .{
        .source_type = .module,
        .language = language,
        .defer_comment_attachment = true,
    });
    defer result.deinit();
    if (telemetry_session) |*session| {
        session.finishSpan(spanPtr(&parse_span), if (result.errors.hasErrors()) .fail else .ok, &.{
            zig_babal.Telemetry.Field.unsigned("node_count", @intCast(result.ast.nodes.len)),
        });
    }

    // Report parse errors
    if (result.errors.hasErrors()) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try result.errors.format(&result.ast, stderr);
        try stderr.flush();
    }

    // Build and run pipeline
    var pipeline = zig_babal.Pipeline.init(allocator);
    defer pipeline.deinit();
    pipeline.telemetry_session = if (telemetry_session) |*session| session else null;
    if (run_span) |span| pipeline.telemetry_parent_span = span;

    const transform_config = zig_babal.TransformConfig{
        .target = target,
        .ts_strip = language == .typescript or language == .tsx,
        .jsx = .{
            .runtime = switch (jsx_runtime) {
                .classic => .classic,
                .automatic => .automatic,
            },
        },
    };

    if (transform_config.ts_strip) {
        try pipeline.addPass(zig_babal.TsStrip.createPass(.{ .language = language }));
    }
    if (language == .tsx or language == .jsx) {
        try pipeline.addPass(zig_babal.JsxTransform.createPass(.{ .runtime = jsx_runtime }));
    }
    if (hasScopeDrivenTransform(transform_config)) {
        pipeline.needs_scope = true;
    }
    if (transform_config.needsTransform(.shorthand_properties)) {
        try pipeline.addPass(zig_babal.ShorthandProperties.createPass());
    }
    if (transform_config.needsTransform(.template_literals)) {
        zig_babal.TemplateLiterals.resetState();
        try pipeline.addPass(zig_babal.TemplateLiterals.createPass(.{}));
    }
    if (transform_config.needsTransform(.computed_properties)) {
        zig_babal.ComputedProperties.resetState();
        try pipeline.addPass(zig_babal.ComputedProperties.createPass(.{}));
    }
    if (transform_config.needsTransform(.arrow_functions)) {
        zig_babal.ArrowFunctions.resetState();
        try pipeline.addPass(zig_babal.ArrowFunctions.createPass(.{}));
    }
    if (transform_config.needsTransform(.spread)) {
        zig_babal.Spread.resetState();
        try pipeline.addPass(zig_babal.Spread.createPass(.{
            .strip_typescript_wrappers = language == .typescript or language == .tsx,
        }));
    }
    if (transform_config.needsTransform(.parameters)) {
        zig_babal.Parameters.resetState();
        try pipeline.addPass(zig_babal.Parameters.createPass(.{}));
    }
    if (transform_config.needsTransform(.for_of)) {
        zig_babal.ForOf.resetState();
        try pipeline.addPass(zig_babal.ForOf.createPass(.{}));
    }
    if (transform_config.needsTransform(.optional_chaining)) {
        zig_babal.OptionalChaining.resetState();
        try pipeline.addPass(zig_babal.OptionalChaining.createPass(.{}));
    }
    if (transform_config.needsTransform(.logical_assignment)) {
        zig_babal.LogicalAssignment.resetState();
        try pipeline.addPass(zig_babal.LogicalAssignment.createPass(.{
            .nullish_followup = transform_config.needsTransform(.nullish_coalescing),
        }));
    }
    if (transform_config.needsTransform(.nullish_coalescing)) {
        zig_babal.NullishCoalescing.resetState();
        try pipeline.addPass(zig_babal.NullishCoalescing.createPass(.{}));
    }
    if (transform_config.needsTransform(.block_scoped_functions)) {
        zig_babal.BlockScopedFunctions.resetState();
        try pipeline.addPass(zig_babal.BlockScopedFunctions.createPass(.{
            .followed_by_block_scoping = transform_config.needsTransform(.block_scoping),
        }));
    }
    if (transform_config.needsTransform(.destructuring)) {
        zig_babal.Destructuring.resetState();
        try pipeline.addPass(zig_babal.Destructuring.createPass(.{
            .rewrite_block_scoped_bindings = transform_config.needsTransform(.block_scoping),
        }));
    }
    if (transform_config.needsTransform(.block_scoping)) {
        zig_babal.BlockScoping.resetState();
        try pipeline.addPass(zig_babal.BlockScoping.createPass(.{}));
    }

    try pipeline.run(&result.ast);

    flushCombinedTempDeclarations(&result.ast, allocator);

    // Generate code
    var codegen_span = if (telemetry_session) |*session|
        session.startSpan(spanPtr(&run_span), .pass, "phase", "codegen", &.{})
    else
        null;
    const gen = try zig_babal.Codegen.generate(&result.ast, .{ .source_maps = has_source_map }, allocator);
    defer gen.deinit(allocator);
    if (telemetry_session) |*session| {
        session.finishSpan(spanPtr(&codegen_span), .ok, &.{
            zig_babal.Telemetry.Field.unsigned("generated_len", @intCast(gen.code.len)),
        });
    }

    var final_code = gen.code;
    if (transform_config.needsTransform(.template_literals) or
        transform_config.needsTransform(.computed_properties) or
        transform_config.needsTransform(.spread))
    {
        if (zig_babal.TemplateLiterals.getTemplateObjectDeclarations(allocator)) |decl| {
            final_code = std.fmt.allocPrint(allocator, "{s}{s}", .{ decl, final_code }) catch final_code;
        }
        if (zig_babal.ComputedProperties.getTempVarDeclarations(allocator)) |decl| {
            final_code = std.fmt.allocPrint(allocator, "{s}{s}", .{ decl, final_code }) catch final_code;
        }
        if (zig_babal.Spread.getTempVarDeclarations(allocator)) |decl| {
            final_code = std.fmt.allocPrint(allocator, "{s}{s}", .{ decl, final_code }) catch final_code;
        }
    }

    // Write generated code to stdout
    var stdout_buf: [65536]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(final_code);
    try stdout.writeAll("\n");
    try stdout.flush();

    if (has_source_map) {
        if (gen.map) |map| {
            var stderr_buf: [65536]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
            const stderr = &stderr_writer.interface;
            try stderr.writeAll(map);
            try stderr.writeAll("\n");
            try stderr.flush();
        }
    }
    if (telemetry_session) |*session| {
        session.finishSpan(spanPtr(&run_span), if (result.errors.hasErrors()) .fail else .ok, &.{
            zig_babal.Telemetry.Field.boolean("has_errors", result.errors.hasErrors()),
        });
    }
}

fn hasScopeDrivenTransform(config: zig_babal.TransformConfig) bool {
    return config.needsTransform(.arrow_functions) or
        config.needsTransform(.optional_chaining) or
        config.needsTransform(.nullish_coalescing) or
        config.needsTransform(.block_scoped_functions) or
        config.needsTransform(.block_scoping);
}

fn flushCombinedTempDeclarations(ast: *zig_babal.Ast, alloc: std.mem.Allocator) void {
    const NullishCoalescing = zig_babal.NullishCoalescing;
    const LogicalAssignment = zig_babal.LogicalAssignment;
    const OptionalChaining = zig_babal.OptionalChaining;
    const Destructuring = zig_babal.Destructuring;
    const preflush_gen = zig_babal.Codegen.generate(ast, .{}, alloc) catch null;
    defer if (preflush_gen) |gen| gen.deinit(alloc);
    const occurrence_source = if (preflush_gen) |gen| gen.code else "";

    var all_bodies: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer all_bodies.deinit(alloc);

    {
        var iter = LogicalAssignment.g_body_temps.iterator();
        while (iter.next()) |entry| {
            all_bodies.put(alloc, entry.key_ptr.*, {}) catch {};
        }
    }
    {
        var iter = NullishCoalescing.g_body_temps.iterator();
        while (iter.next()) |entry| {
            all_bodies.put(alloc, entry.key_ptr.*, {}) catch {};
        }
    }
    {
        var iter = OptionalChaining.g_body_temps.iterator();
        while (iter.next()) |entry| {
            all_bodies.put(alloc, entry.key_ptr.*, {}) catch {};
        }
    }
    {
        var iter = Destructuring.g_body_temps.iterator();
        while (iter.next()) |entry| {
            all_bodies.put(alloc, entry.key_ptr.*, {}) catch {};
        }
    }

    var body_iter = all_bodies.iterator();
    while (body_iter.next()) |entry| {
        const body_idx = entry.key_ptr.*;
        var decl_buf: std.ArrayListUnmanaged(u8) = .empty;

        if (ast.block_prefix_source.get(body_idx)) |existing| {
            decl_buf.appendSlice(alloc, existing) catch continue;
        }

        decl_buf.appendSlice(alloc, "var ") catch continue;
        var first = true;

        if (LogicalAssignment.g_body_temps.get(body_idx)) |la_names| {
            for (la_names.items) |name| {
                if (!first) decl_buf.appendSlice(alloc, ", ") catch {};
                decl_buf.appendSlice(alloc, name) catch {};
                first = false;
            }
        }

        const oc_names = OptionalChaining.g_body_temps.get(body_idx);
        const nc_names = NullishCoalescing.g_body_temps.get(body_idx);
        if (oc_names) |oc| {
            if (nc_names) |nc| {
                var combined_names: std.ArrayListUnmanaged([]const u8) = .empty;
                defer combined_names.deinit(alloc);
                combined_names.appendSlice(alloc, oc.items) catch {};
                combined_names.appendSlice(alloc, nc.items) catch {};
                appendOrderedOptionalTempNames(occurrence_source, alloc, &decl_buf, combined_names.items, &first);
            } else {
                appendOrderedOptionalTempNames(occurrence_source, alloc, &decl_buf, oc.items, &first);
            }
        } else if (nc_names) |nc| {
            for (nc.items) |name| {
                if (!first) decl_buf.appendSlice(alloc, ", ") catch {};
                decl_buf.appendSlice(alloc, name) catch {};
                first = false;
            }
        }

        if (Destructuring.g_body_temps.get(body_idx)) |d_names| {
            for (d_names.items) |name| {
                if (!first) decl_buf.appendSlice(alloc, ", ") catch {};
                decl_buf.appendSlice(alloc, name) catch {};
                first = false;
            }
        }

        if (first) continue;
        decl_buf.appendSlice(alloc, ";") catch continue;

        const body_node: zig_babal.NodeIndex = @enumFromInt(body_idx);
        const body_tag = ast.nodes.items(.tag)[body_idx];
        if (body_tag == .block_statement or body_tag == .program or body_tag == .arrow_function_expr) {
            ast.block_prefix_source.put(alloc, body_idx, decl_buf.items) catch continue;
            continue;
        }

        const body_src = getFlushNodeSource(ast, body_node);
        var wrapped: std.ArrayListUnmanaged(u8) = .empty;
        wrapped.appendSlice(alloc, "{\n  ") catch continue;
        wrapped.appendSlice(alloc, decl_buf.items) catch continue;
        wrapped.append(alloc, '\n') catch continue;
        appendIndentedLines(&wrapped, alloc, body_src, "  ");
        wrapped.appendSlice(alloc, "}") catch continue;
        ast.replacement_source.put(alloc, body_idx, wrapped.items) catch continue;
    }
}

fn appendOrderedOptionalTempNames(
    occurrence_source: []const u8,
    alloc: std.mem.Allocator,
    decl_buf: *std.ArrayListUnmanaged(u8),
    names: []const []const u8,
    first: *bool,
) void {
    const used = alloc.alloc(bool, names.len) catch return;
    defer alloc.free(used);
    @memset(used, false);

    var remaining = names.len;
    while (remaining > 0) : (remaining -= 1) {
        var best_idx: ?usize = null;
        var best_pos: usize = std.math.maxInt(usize);
        for (names, 0..) |name, i| {
            if (used[i]) continue;
            const pos = findIdentifierOccurrence(occurrence_source, name) orelse std.math.maxInt(usize);
            if (best_idx == null or pos < best_pos) {
                best_idx = i;
                best_pos = pos;
            }
        }
        const chosen = best_idx orelse break;
        used[chosen] = true;
        if (!first.*) decl_buf.appendSlice(alloc, ", ") catch {};
        decl_buf.appendSlice(alloc, names[chosen]) catch {};
        first.* = false;
    }
}

fn findIdentifierOccurrence(src: []const u8, name: []const u8) ?usize {
    if (name.len == 0 or src.len < name.len) return null;

    var i: usize = 0;
    while (i + name.len <= src.len) : (i += 1) {
        if (!std.mem.eql(u8, src[i .. i + name.len], name)) continue;
        const before_ok = i == 0 or !isIdentChar(src[i - 1]);
        const after_ok = i + name.len == src.len or !isIdentChar(src[i + name.len]);
        if (before_ok and after_ok) return i;
    }

    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or
        c == '$';
}

fn getFlushNodeSource(ast: *zig_babal.Ast, idx: zig_babal.NodeIndex) []const u8 {
    const ni = @intFromEnum(idx);
    if (ast.replacement_source.get(ni)) |replacement| return replacement;
    const start = getFlushNodeStart(ast, idx);
    const end = ast.nodes.items(.end_offset)[ni];
    return ast.source[start..end];
}

fn getFlushNodeStart(ast: *zig_babal.Ast, idx: zig_babal.NodeIndex) usize {
    const ni = @intFromEnum(idx);
    return if (ast.node_start_overrides.get(ni)) |override| override else blk: {
        const mt = ast.nodes.items(.main_token)[ni];
        break :blk ast.tokens.items(.start)[@intFromEnum(mt)];
    };
}

fn appendIndentedLines(
    buf: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    src: []const u8,
    indent: []const u8,
) void {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        buf.appendSlice(alloc, indent) catch return;
        buf.appendSlice(alloc, line) catch return;
        buf.append(alloc, '\n') catch return;
    }
}

fn printUsage(io: std.Io) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\zig-babal - A high-performance JavaScript parser
        \\
        \\Usage:
        \\  zig-babal parse <file>              Parse and output AST as JSON
        \\  zig-babal print <file>              Output formatted JS code
        \\  zig-babal print <file> --source-map Output formatted JS; source map to stderr
        \\  zig-babal transform <file>          Strip TS/JSX and output JS
        \\  zig-babal transform <file> --jsx-runtime classic|automatic
        \\  zig-babal transform <file> --target es2015
        \\  zig-babal transform <file> --target es2015 --source-map
        \\
        \\Options:
        \\  -h, --help    Show this help
        \\
    );
    try stdout.flush();
}
