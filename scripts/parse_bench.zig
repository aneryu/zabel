const std = @import("std");
const zb = @import("zig_babal");

const CommentsMode = enum {
    deferred,
    attached,
};

fn parseLanguage(raw: []const u8) ?zb.Language {
    if (std.mem.eql(u8, raw, "javascript")) return .javascript;
    if (std.mem.eql(u8, raw, "jsx")) return .jsx;
    if (std.mem.eql(u8, raw, "typescript")) return .typescript;
    if (std.mem.eql(u8, raw, "tsx")) return .tsx;
    if (std.mem.eql(u8, raw, "flow")) return .flow;
    return null;
}

fn parseSourceType(raw: []const u8) ?zb.SourceType {
    if (std.mem.eql(u8, raw, "script")) return .script;
    if (std.mem.eql(u8, raw, "module")) return .module;
    return null;
}

fn parseCommentsMode(raw: []const u8) ?CommentsMode {
    if (std.mem.eql(u8, raw, "deferred")) return .deferred;
    if (std.mem.eql(u8, raw, "default")) return .attached;
    return null;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  parse_bench <input> <language> <source_type> <comments_mode> <warmups> <iterations>
        \\
        \\  language: javascript | jsx | typescript | tsx | flow
        \\  source_type: script | module
        \\  comments_mode: deferred | default
        \\
    , .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 7) {
        printUsage();
        std.process.exit(1);
    }

    const input_path = args[1];
    const language = parseLanguage(args[2]) orelse {
        std.debug.print("error: invalid language '{s}'\n", .{args[2]});
        std.process.exit(1);
    };
    const source_type = parseSourceType(args[3]) orelse {
        std.debug.print("error: invalid source_type '{s}'\n", .{args[3]});
        std.process.exit(1);
    };
    const comments_mode = parseCommentsMode(args[4]) orelse {
        std.debug.print("error: invalid comments_mode '{s}'\n", .{args[4]});
        std.process.exit(1);
    };
    const warmups = std.fmt.parseUnsigned(usize, args[5], 10) catch {
        std.debug.print("error: invalid warmups '{s}'\n", .{args[5]});
        std.process.exit(1);
    };
    const iterations = std.fmt.parseUnsigned(usize, args[6], 10) catch {
        std.debug.print("error: invalid iterations '{s}'\n", .{args[6]});
        std.process.exit(1);
    };

    const source = std.fs.cwd().readFileAlloc(allocator, input_path, 50 * 1024 * 1024) catch |err| {
        std.debug.print("error: cannot read file '{s}': {}\n", .{ input_path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const total_iters = warmups + iterations;
    var elapsed_ns: u64 = 0;
    var sink: usize = 0;

    for (0..total_iters) |iter| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const bench_alloc = arena.allocator();

        var timer = try std.time.Timer.start();
        const result = try zb.parseWithOptions(bench_alloc, source, .{
            .source_type = source_type,
            .language = language,
            .defer_comment_attachment = comments_mode == .deferred,
        });
        const elapsed = timer.read();

        sink +%= result.ast.nodes.len;
        sink +%= result.ast.tokens.len;
        sink +%= result.ast.extra_data.items.len;
        sink +%= result.errors.items.items.len;
        std.mem.doNotOptimizeAway(sink);

        if (iter >= warmups) elapsed_ns +%= elapsed;
    }

    var buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("parse\t{d}\t{d}\t{d}\n", .{ iterations, elapsed_ns, sink });
    try stdout.flush();
}
