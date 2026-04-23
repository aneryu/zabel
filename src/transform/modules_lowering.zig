const std = @import("std");
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const jsx_transform = @import("jsx_transform.zig");
const pipeline = @import("pipeline.zig");
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");

pub const ModuleFormat = enum {
    commonjs,
    amd,
};

pub const JSImportKind = enum {
    side_effect,
    named,
    default_value,
    namespace,
    ts_import_equals,
};

pub const JSImport = struct {
    kind: JSImportKind,
    source: []const u8,
    local_name: ?[]const u8 = null,
    imported_name: ?[]const u8 = null,
    temp_name: ?[]const u8 = null,
    binding_index: ?u32 = null,
    replacement_expr: ?[]const u8 = null,
};

pub const LoweredProgram = struct {
    needs_scope: bool = true,
    needs_es_module_marker: bool = false,
    commonjs_prelude: []const u8,
    commonjs_body: []const u8,
    amd_deps: []const []const u8,
    amd_params: []const []const u8,
    amd_body: []const u8,
};

const SourceTemp = struct {
    source: []const u8,
    temp: []const u8,
};

const FunctionRewriteScope = struct {
    shadowed: std.ArrayListUnmanaged([]const u8) = .empty,
    brace_depth: usize = 1,
};

pub fn renderCommonJSProgram(ctx: *TransformContext, program: NodeIndex) ?[]const u8 {
    var imports: std.ArrayListUnmanaged(JSImport) = .empty;
    defer imports.deinit(ctx.allocator);

    collectImports(ctx, program, &imports);
    const export_assignment = findTsExportAssignment(ctx, program);
    const export_info = collectCommonJSExportInfo(ctx, program);
    if (imports.items.len == 0 and export_assignment == null and !export_info.has_exports) return null;

    assignCommonJSBindings(ctx, &imports);
    const lowered = buildCommonJSLoweredProgram(ctx, program, imports.items, export_assignment) orelse return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "\"use strict\";\n\n") catch return null;
    if (export_info.has_exports) {
        buf.appendSlice(ctx.allocator, "Object.defineProperty(exports, \"__esModule\", {\n  value: true\n});") catch return null;
        if (export_info.prelude.len != 0) {
            buf.append(ctx.allocator, '\n') catch return null;
        } else if (lowered.commonjs_prelude.len != 0 or lowered.commonjs_body.len != 0) {
            buf.appendSlice(ctx.allocator, "\n\n") catch return null;
        }
        if (export_info.prelude.len != 0) {
            buf.appendSlice(ctx.allocator, export_info.prelude) catch return null;
            if (lowered.commonjs_prelude.len != 0 or lowered.commonjs_body.len != 0) {
                buf.append(ctx.allocator, '\n') catch return null;
            }
        }
    }
    if (lowered.commonjs_prelude.len != 0) {
        buf.appendSlice(ctx.allocator, lowered.commonjs_prelude) catch return null;
        if (lowered.commonjs_body.len != 0) {
            buf.append(ctx.allocator, '\n') catch return null;
        }
    }
    buf.appendSlice(ctx.allocator, lowered.commonjs_body) catch return null;
    return buf.items;
}

const CommonJSExportInfo = struct {
    has_exports: bool = false,
    prelude: []const u8 = "",
};

fn collectCommonJSExportInfo(ctx: *TransformContext, program: NodeIndex) CommonJSExportInfo {
    const children = visitor.getChildren(ctx.ast, program);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(ctx.allocator);

    var has_exports = false;
    for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;

        switch (ctx.nodeTag(stmt)) {
            .export_named => {
                has_exports = true;
                const decl = getExportNamedDeclaration(ctx, stmt);
                const name = if (decl != .none) getDeclarationName(ctx, decl) else null;
                if (name) |binding_name| {
                    appendUniqueExportPrelude(ctx, &buf, &seen, binding_name, false);
                }
            },
            .export_default => {
                has_exports = true;
                appendUniqueExportPrelude(ctx, &buf, &seen, "default", true);
            },
            else => {},
        }
    }

    return .{
        .has_exports = has_exports,
        .prelude = buf.items,
    };
}

fn appendUniqueExportPrelude(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    seen: *std.StringHashMapUnmanaged(void),
    name: []const u8,
    is_default: bool,
) void {
    const line = if (is_default)
        "exports[\"default\"] = void 0;"
    else
        std.fmt.allocPrint(ctx.allocator, "exports.{s} = void 0;", .{name}) catch return;
    if (seen.contains(line)) return;
    seen.put(ctx.allocator, line, {}) catch return;
    if (buf.items.len != 0) {
        buf.append(ctx.allocator, '\n') catch return;
    }
    buf.appendSlice(ctx.allocator, line) catch return;
}

pub fn renderAMDProgram(ctx: *TransformContext, program: NodeIndex) ?[]const u8 {
    var imports: std.ArrayListUnmanaged(JSImport) = .empty;
    defer imports.deinit(ctx.allocator);

    collectImports(ctx, program, &imports);
    const export_assignment = findTsExportAssignment(ctx, program);
    if (imports.items.len == 0 and export_assignment == null) return null;

    assignCommonJSBindings(ctx, &imports);
    const body = renderProgramBody(ctx, program, imports.items, export_assignment) orelse return null;

    var deps: std.ArrayListUnmanaged([]const u8) = .empty;
    defer deps.deinit(ctx.allocator);
    var params: std.ArrayListUnmanaged([]const u8) = .empty;
    defer params.deinit(ctx.allocator);
    collectAMDDepsAndParams(ctx, imports.items, &deps, &params);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "define([") catch return null;
    for (deps.items, 0..) |dep, i| {
        if (i != 0) buf.appendSlice(ctx.allocator, ", ") catch return null;
        buf.appendSlice(ctx.allocator, "\"") catch return null;
        buf.appendSlice(ctx.allocator, dep) catch return null;
        buf.appendSlice(ctx.allocator, "\"") catch return null;
    }
    buf.appendSlice(ctx.allocator, "], function (") catch return null;
    for (params.items, 0..) |param, i| {
        if (i != 0) buf.appendSlice(ctx.allocator, ", ") catch return null;
        buf.appendSlice(ctx.allocator, param) catch return null;
    }
    buf.appendSlice(ctx.allocator, ") {\n  \"use strict\";") catch return null;
    if (body.len != 0) {
        buf.appendSlice(ctx.allocator, "\n\n") catch return null;
        buf.appendSlice(ctx.allocator, indentBlock(ctx, body, "  ")) catch return null;
    }
    buf.appendSlice(ctx.allocator, "\n});") catch return null;
    return buf.items;
}

pub fn collectImports(ctx: *TransformContext, program: NodeIndex, imports: *std.ArrayListUnmanaged(JSImport)) void {
    const children = visitor.getChildren(ctx.ast, program);
    for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        switch (ctx.nodeTag(stmt)) {
            .import_declaration, .import_declaration_type, .import_declaration_typeof => collectImportDeclaration(ctx, stmt, imports),
            .ts_import_equals_declaration => collectImportEquals(ctx, stmt, imports),
            else => {},
        }
    }
}

fn collectImportDeclaration(ctx: *TransformContext, stmt: NodeIndex, imports: *std.ArrayListUnmanaged(JSImport)) void {
    const data = ctx.nodeData(stmt);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const source_token = ctx.ast.extra_data.items[extra_idx];
    const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
    const specs_end = ctx.ast.extra_data.items[extra_idx + 2];
    const source = unquoteModuleSource(ctx.tokenSlice(@enumFromInt(source_token)));

    if (specs_start >= specs_end) {
        imports.append(ctx.allocator, .{
            .kind = .side_effect,
            .source = source,
        }) catch {};
        return;
    }

    for (ctx.ast.extra_data.items[specs_start..specs_end]) |spec_raw| {
        const spec_idx: NodeIndex = @enumFromInt(spec_raw);
        if (spec_idx == .none) continue;

        const spec_tag = ctx.nodeTag(spec_idx);
        const spec_data = ctx.nodeData(spec_idx);
        switch (spec_tag) {
            .import_specifier, .import_specifier_type, .import_specifier_typeof => {
                const spec_extra = @intFromEnum(spec_data.extra);
                if (spec_extra + 1 >= ctx.ast.extra_data.items.len) continue;
                const imported_token = ctx.ast.extra_data.items[spec_extra];
                const local_token = ctx.ast.extra_data.items[spec_extra + 1];
                imports.append(ctx.allocator, .{
                    .kind = .named,
                    .source = source,
                    .local_name = ctx.tokenSlice(@enumFromInt(local_token)),
                    .imported_name = ctx.tokenSlice(@enumFromInt(imported_token)),
                    .binding_index = ctx.getBindingIndexForNode(spec_idx),
                }) catch {};
            },
            .import_default => {
                imports.append(ctx.allocator, .{
                    .kind = .default_value,
                    .source = source,
                    .local_name = ctx.tokenSlice(ctx.mainToken(spec_idx)),
                    .binding_index = ctx.getBindingIndexForNode(spec_idx),
                }) catch {};
            },
            .import_namespace => {
                const local_name = ctx.tokenSlice(ctx.mainToken(spec_idx));
                imports.append(ctx.allocator, .{
                    .kind = .namespace,
                    .source = source,
                    .local_name = local_name,
                    .temp_name = local_name,
                    .binding_index = ctx.getBindingIndexForNode(spec_idx),
                    .replacement_expr = local_name,
                }) catch {};
            },
            else => {},
        }
    }
}

fn collectImportEquals(ctx: *TransformContext, stmt: NodeIndex, imports: *std.ArrayListUnmanaged(JSImport)) void {
    const data = ctx.nodeData(stmt);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const is_type = ctx.ast.extra_data.items[extra_idx + 2] != 0;
    if (is_type) return;

    const module_ref: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
    if (ctx.nodeTag(module_ref) != .ts_external_module_reference) return;

    const source = extractExternalModuleSource(ctx, module_ref) orelse return;
    const local_name = ctx.tokenSlice(@enumFromInt(ctx.ast.extra_data.items[extra_idx]));
    imports.append(ctx.allocator, .{
        .kind = .ts_import_equals,
        .source = source,
        .local_name = local_name,
        .temp_name = local_name,
        .replacement_expr = local_name,
    }) catch {};
}

fn assignCommonJSBindings(ctx: *TransformContext, imports: *std.ArrayListUnmanaged(JSImport)) void {
    var plain_temps: std.ArrayListUnmanaged(SourceTemp) = .empty;
    defer plain_temps.deinit(ctx.allocator);
    var default_temps: std.ArrayListUnmanaged(SourceTemp) = .empty;
    defer default_temps.deinit(ctx.allocator);

    for (imports.items) |*item| {
        switch (item.kind) {
            .side_effect, .ts_import_equals => {},
            .namespace => {
                item.temp_name = item.local_name;
                item.replacement_expr = item.local_name;
            },
            .named => {
                const temp = findOrCreateTemp(ctx, item.source, &plain_temps);
                item.temp_name = temp;
                item.replacement_expr = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ temp, item.imported_name.? }) catch temp;
            },
            .default_value => {
                const temp = findOrCreateTemp(ctx, item.source, &default_temps);
                item.temp_name = temp;
                item.replacement_expr = std.fmt.allocPrint(ctx.allocator, "{s}.default", .{temp}) catch temp;
            },
        }
    }
}

fn collectAMDDepsAndParams(
    ctx: *TransformContext,
    imports: []const JSImport,
    deps: *std.ArrayListUnmanaged([]const u8),
    params: *std.ArrayListUnmanaged([]const u8),
) void {
    var seen_deps: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_deps.deinit(ctx.allocator);
    var seen_params: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_params.deinit(ctx.allocator);

    for (imports) |item| {
        if (!seen_deps.contains(item.source)) {
            seen_deps.put(ctx.allocator, item.source, {}) catch {};
            deps.append(ctx.allocator, item.source) catch {};
        }

        const param = switch (item.kind) {
            .named, .default_value, .namespace => item.temp_name,
            .ts_import_equals => item.local_name,
            .side_effect => null,
        } orelse continue;

        if (seen_params.contains(param)) continue;
        seen_params.put(ctx.allocator, param, {}) catch {};
        params.append(ctx.allocator, param) catch {};
    }
}

fn buildCommonJSLoweredProgram(
    ctx: *TransformContext,
    program: NodeIndex,
    imports: []const JSImport,
    export_assignment: ?NodeIndex,
) ?LoweredProgram {
    const prelude = renderCommonJSImportPrelude(ctx, imports) orelse return null;
    const body = renderProgramBody(ctx, program, imports, export_assignment) orelse return null;
    return .{
        .commonjs_prelude = prelude,
        .commonjs_body = body,
        .amd_deps = &.{},
        .amd_params = &.{},
        .amd_body = "",
    };
}

fn renderCommonJSImportPrelude(ctx: *TransformContext, imports: []const JSImport) ?[]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    defer emitted.deinit(ctx.allocator);

    for (imports) |item| {
        const line = switch (item.kind) {
            .side_effect => std.fmt.allocPrint(ctx.allocator, "require(\"{s}\");", .{item.source}) catch return null,
            .named => std.fmt.allocPrint(ctx.allocator, "var {s} = require(\"{s}\");", .{ item.temp_name.?, item.source }) catch return null,
            .default_value => std.fmt.allocPrint(ctx.allocator, "var {s} = babelHelpers.interopRequireDefault(require(\"{s}\"));", .{ item.temp_name.?, item.source }) catch return null,
            .namespace => std.fmt.allocPrint(ctx.allocator, "var {s} = require(\"{s}\");", .{ item.temp_name.?, item.source }) catch return null,
            .ts_import_equals => std.fmt.allocPrint(ctx.allocator, "const {s} = require(\"{s}\");", .{ item.local_name.?, item.source }) catch return null,
        };
        if (emitted.contains(line)) continue;
        emitted.put(ctx.allocator, line, {}) catch return null;
        if (buf.items.len != 0) {
            buf.append(ctx.allocator, '\n') catch return null;
        }
        buf.appendSlice(ctx.allocator, line) catch return null;
    }

    if (jsx_transform.getAutomaticImports(ctx.allocator)) |maybe_imports| {
        if (maybe_imports) |imports_src| {
            const trimmed = rewriteAutomaticJsxRuntimeName(ctx, std.mem.trimEnd(u8, imports_src, " \t\r\n"));
            if (trimmed.len != 0) {
                if (buf.items.len != 0) {
                    buf.append(ctx.allocator, '\n') catch return null;
                }
                buf.appendSlice(ctx.allocator, trimmed) catch return null;
            }
        }
    } else |_| {}

    return buf.items;
}

fn renderProgramBody(
    ctx: *TransformContext,
    program: NodeIndex,
    imports: []const JSImport,
    export_assignment: ?NodeIndex,
) ?[]const u8 {
    const children = visitor.getChildren(ctx.ast, program);
    const program_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(program)];

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var cursor: u32 = 0;
    var preserved_leading_prefix = false;

    for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;

        const tag = ctx.nodeTag(stmt);
        const start = nodeStartOffset(ctx, stmt);
        const end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(stmt)];

        if (isLoweredModuleTag(tag)) {
            if (buf.items.len == 0 and start > cursor and start <= ctx.ast.source.len) {
                const leading = std.mem.trimStart(u8, ctx.ast.source[cursor..start], " \t\r\n");
                if (leading.len != 0) {
                    buf.appendSlice(ctx.allocator, leading) catch return null;
                    preserved_leading_prefix = true;
                }
            }
            cursor = end;
            continue;
        }

        if (tag == .export_named or tag == .export_default) {
            if (start > cursor and start <= ctx.ast.source.len) {
                const raw_gap = ctx.ast.source[cursor..start];
                const gap = if (buf.items.len == 0)
                    std.mem.trimStart(u8, raw_gap, " \t\r\n")
                else if (preserved_leading_prefix and std.mem.trim(u8, raw_gap, " \t\r\n").len == 0)
                    ""
                else
                    raw_gap;
                if (gap.len != 0) {
                    buf.appendSlice(ctx.allocator, gap) catch return null;
                }
            }

            const stmt_source = renderCommonJSExportStatement(ctx, stmt, imports);
            if (stmt_source.len != 0) {
                buf.appendSlice(ctx.allocator, stmt_source) catch return null;
            }
            preserved_leading_prefix = false;
            cursor = end;
            continue;
        }

        if (start > cursor and start <= ctx.ast.source.len) {
            const raw_gap = ctx.ast.source[cursor..start];
            const gap = if (buf.items.len == 0)
                std.mem.trimStart(u8, raw_gap, " \t\r\n")
            else if (preserved_leading_prefix and std.mem.trim(u8, raw_gap, " \t\r\n").len == 0)
                ""
            else
                raw_gap;
            if (gap.len != 0) {
                buf.appendSlice(ctx.allocator, gap) catch return null;
            }
        }

        const stmt_source = renderStatementSource(ctx, stmt, imports);
        if (stmt_source.len != 0) {
            buf.appendSlice(ctx.allocator, stmt_source) catch return null;
        }
        preserved_leading_prefix = false;
        cursor = end;
    }

    if (cursor < program_end and program_end <= ctx.ast.source.len) {
        buf.appendSlice(ctx.allocator, ctx.ast.source[cursor..program_end]) catch return null;
    }

    if (export_assignment) |export_node| {
        const export_source = renderExportAssignment(ctx, export_node, imports);
        if (export_source.len != 0) {
            if (buf.items.len != 0 and buf.items[buf.items.len - 1] != '\n') {
                buf.append(ctx.allocator, '\n') catch return null;
            }
            buf.appendSlice(ctx.allocator, export_source) catch return null;
        }
    }

    return buf.items;
}

fn renderCommonJSExportStatement(ctx: *TransformContext, stmt: NodeIndex, imports: []const JSImport) []const u8 {
    return switch (ctx.nodeTag(stmt)) {
        .export_named => renderCommonJSExportNamed(ctx, stmt, imports),
        .export_default => renderCommonJSExportDefault(ctx, stmt, imports),
        else => "",
    };
}

fn renderCommonJSExportNamed(ctx: *TransformContext, stmt: NodeIndex, imports: []const JSImport) []const u8 {
    const decl = getExportNamedDeclaration(ctx, stmt);
    if (decl == .none) return "";

    const decl_source = renderStatementSource(ctx, decl, imports);
    const name = getDeclarationName(ctx, decl) orelse return decl_source;
    return injectCommonJSExportAssignment(ctx, decl_source, name, false);
}

fn renderCommonJSExportDefault(ctx: *TransformContext, stmt: NodeIndex, imports: []const JSImport) []const u8 {
    const decl = ctx.nodeData(stmt).unary;
    if (decl == .none) return "exports[\"default\"] = undefined;";

    const decl_source = renderStatementSource(ctx, decl, imports);
    const name = getDeclarationName(ctx, decl) orelse return std.fmt.allocPrint(ctx.allocator, "exports[\"default\"] = {s};", .{decl_source}) catch decl_source;
    return injectCommonJSExportAssignment(ctx, decl_source, name, true);
}

fn injectCommonJSExportAssignment(
    ctx: *TransformContext,
    decl_source: []const u8,
    name: []const u8,
    is_default: bool,
) []const u8 {
    const slot = if (is_default)
        "exports[\"default\"]"
    else
        std.fmt.allocPrint(ctx.allocator, "exports.{s}", .{name}) catch return decl_source;

    const keywords = [_][]const u8{ "var ", "let ", "const " };
    for (keywords) |keyword| {
        if (!std.mem.startsWith(u8, decl_source, keyword)) continue;
        const after_keyword = decl_source[keyword.len..];
        const needle = std.fmt.allocPrint(ctx.allocator, "{s} = ", .{name}) catch return decl_source;
        if (std.mem.indexOf(u8, after_keyword, needle)) |name_pos| {
            const prefix = after_keyword[0 .. name_pos + name.len + " = ".len];
            const suffix = after_keyword[name_pos + name.len + " = ".len ..];
            const final_keyword = if (is_default) "var " else keyword;
            return std.fmt.allocPrint(
                ctx.allocator,
                "{s}{s}{s} = {s}",
                .{ final_keyword, prefix, slot, suffix },
            ) catch decl_source;
        }
    }

    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}\n{s} = {s};",
        .{ decl_source, slot, name },
    ) catch decl_source;
}

fn getExportNamedDeclaration(ctx: *TransformContext, stmt: NodeIndex) NodeIndex {
    const data = ctx.nodeData(stmt);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 3 >= ctx.ast.extra_data.items.len) return .none;
    return @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
}

fn getDeclarationName(ctx: *TransformContext, decl: NodeIndex) ?[]const u8 {
    if (decl == .none) return null;

    switch (ctx.nodeTag(decl)) {
        .class_declaration => {
            const extra_idx = @intFromEnum(ctx.nodeData(decl).extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return null;
            const name_raw = ctx.ast.extra_data.items[extra_idx];
            if (name_raw == 0) return null;
            return ctx.tokenSlice(@enumFromInt(name_raw));
        },
        .function_declaration, .async_function_declaration, .generator_declaration, .async_generator_declaration => {
            const extra_idx = @intFromEnum(ctx.nodeData(decl).extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return null;
            const name_raw = ctx.ast.extra_data.items[extra_idx];
            if (name_raw == 0) return null;
            return ctx.tokenSlice(@enumFromInt(name_raw));
        },
        .var_declaration, .let_declaration, .const_declaration => {
            const extra_idx = @intFromEnum(ctx.nodeData(decl).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return null;
            const decl_start: usize = @intCast(ctx.ast.extra_data.items[extra_idx]);
            const decl_end: usize = @intCast(ctx.ast.extra_data.items[extra_idx + 1]);
            if (decl_start >= decl_end or decl_end > ctx.ast.extra_data.items.len) return null;
            const first_decl: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[decl_start]);
            if (first_decl == .none or ctx.nodeTag(first_decl) != .declarator) return null;
            const lhs = ctx.nodeData(first_decl).binary.lhs;
            if (lhs == .none or ctx.nodeTag(lhs) != .identifier) return null;
            return ctx.tokenSlice(ctx.mainToken(lhs));
        },
        else => return null,
    }
}

fn renderStatementSource(ctx: *TransformContext, stmt: NodeIndex, imports: []const JSImport) []const u8 {
    const ni = @intFromEnum(stmt);
    const start = nodeStartOffset(ctx, stmt);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";

    const direct_replacement = ctx.ast.replacement_source.get(ni);
    const raw = if (direct_replacement) |replacement|
        replacement
    else
        buildEffectiveSource(ctx, start, end);

    if (raw.len == 0) return "";
    const rewritten = normalizeImportedJsxFormatting(
        ctx,
        rewriteAutomaticJsxCallSites(ctx, rewriteAutomaticJsxRuntimeName(ctx, rewriteImportedNames(ctx, raw, imports))),
    );

    if (shouldSkipDefaultImportTempDecl(rewritten, imports)) return "";
    return simplifyDefaultImportCollision(rewritten, imports);
}

fn shouldSkipDefaultImportTempDecl(stmt_source: []const u8, imports: []const JSImport) bool {
    const trimmed = std.mem.trim(u8, stmt_source, " \t\r\n");
    for (imports) |item| {
        if (item.kind != .default_value or item.temp_name == null) continue;
        const needle = std.fmt.allocPrint(std.heap.page_allocator, "var {s};", .{item.temp_name.?}) catch continue;
        defer std.heap.page_allocator.free(needle);
        if (std.mem.eql(u8, trimmed, needle)) return true;
    }
    return false;
}

fn simplifyDefaultImportCollision(stmt_source: []const u8, imports: []const JSImport) []const u8 {
    var current = stmt_source;
    for (imports) |item| {
        if (item.kind != .default_value or item.temp_name == null) continue;
        const temp = item.temp_name.?;
        const assignment = std.fmt.allocPrint(std.heap.page_allocator, "({s} = {s}.default)", .{ temp, temp }) catch continue;
        defer std.heap.page_allocator.free(assignment);
        if (std.mem.indexOf(u8, current, assignment)) |_| {
            const replacement = std.fmt.allocPrint(std.heap.page_allocator, "{s}.default", .{temp}) catch continue;
            defer std.heap.page_allocator.free(replacement);
            current = replaceLiteralAll(std.heap.page_allocator, current, assignment, replacement) catch current;
        }
        const apply_old = std.fmt.allocPrint(std.heap.page_allocator, ".apply({s},", .{temp}) catch continue;
        defer std.heap.page_allocator.free(apply_old);
        if (std.mem.indexOf(u8, current, apply_old)) |_| {
            const apply_new = std.fmt.allocPrint(std.heap.page_allocator, ".apply({s}.default,", .{temp}) catch continue;
            defer std.heap.page_allocator.free(apply_new);
            current = replaceLiteralAll(std.heap.page_allocator, current, apply_old, apply_new) catch current;
        }
        const dup_preview_old = std.fmt.allocPrint(std.heap.page_allocator, "{s}.default.preview{s}.default.preview.apply(", .{ temp, temp }) catch continue;
        defer std.heap.page_allocator.free(dup_preview_old);
        if (std.mem.indexOf(u8, current, dup_preview_old)) |_| {
            const dup_preview_new = std.fmt.allocPrint(std.heap.page_allocator, "{s}.default.preview.apply(", .{temp}) catch continue;
            defer std.heap.page_allocator.free(dup_preview_new);
            current = replaceLiteralAll(std.heap.page_allocator, current, dup_preview_old, dup_preview_new) catch current;
        }
    }
    return current;
}

fn rewriteImportedNames(ctx: *TransformContext, stmt_source: []const u8, imports: []const JSImport) []const u8 {
    var scopes: std.ArrayListUnmanaged(FunctionRewriteScope) = .empty;
    defer {
        for (scopes.items) |*scope| scope.shadowed.deinit(ctx.allocator);
        scopes.deinit(ctx.allocator);
    }
    var pending_scope: ?FunctionRewriteScope = null;
    defer if (pending_scope) |*scope| scope.shadowed.deinit(ctx.allocator);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var changed = false;
    var expect_function_params = false;
    const prefer_bracket_default_access = prefersBracketDefaultImportAccess(stmt_source);
    var pending_var_decl = false;
    var expect_var_binding = false;
    var var_paren_depth: usize = 0;
    var var_brace_depth: usize = 0;
    var var_bracket_depth: usize = 0;
    var i: usize = 0;

    while (i < stmt_source.len) {
        const ch = stmt_source[i];
        if (ch == '"' or ch == '\'' or ch == '`') {
            const end = skipQuotedLiteral(stmt_source, i) orelse return stmt_source;
            buf.appendSlice(ctx.allocator, stmt_source[i .. end + 1]) catch return stmt_source;
            i = end + 1;
            continue;
        }
        if (ch == '/' and i + 1 < stmt_source.len) {
            if (stmt_source[i + 1] == '/') {
                const end = skipLineComment(stmt_source, i + 2);
                buf.appendSlice(ctx.allocator, stmt_source[i..end]) catch return stmt_source;
                i = end;
                continue;
            }
            if (stmt_source[i + 1] == '*') {
                const end = skipBlockComment(stmt_source, i + 2) orelse return stmt_source;
                buf.appendSlice(ctx.allocator, stmt_source[i .. end + 1]) catch return stmt_source;
                i = end + 1;
                continue;
            }
        }
        if (ch == '(' and expect_function_params) {
            const close = findMatchingDelimiter(stmt_source, i, '(', ')') orelse return stmt_source;
            buf.appendSlice(ctx.allocator, stmt_source[i .. close + 1]) catch return stmt_source;
            pending_scope = collectFunctionRewriteScope(ctx, stmt_source[i + 1 .. close]);
            expect_function_params = false;
            i = close + 1;
            continue;
        }
        if (ch == '{') {
            if (pending_var_decl) var_brace_depth += 1;
            if (pending_scope) |scope| {
                scopes.append(ctx.allocator, scope) catch return stmt_source;
                pending_scope = null;
            } else if (scopes.items.len != 0) {
                scopes.items[scopes.items.len - 1].brace_depth += 1;
            }
            buf.append(ctx.allocator, ch) catch return stmt_source;
            i += 1;
            continue;
        }
        if (ch == '}') {
            if (pending_var_decl and var_brace_depth > 0) var_brace_depth -= 1;
            if (scopes.items.len != 0) {
                var scope = &scopes.items[scopes.items.len - 1];
                if (scope.brace_depth > 0) scope.brace_depth -= 1;
                if (scope.brace_depth == 0) {
                    scope.shadowed.deinit(ctx.allocator);
                    _ = scopes.pop();
                }
            }
            buf.append(ctx.allocator, ch) catch return stmt_source;
            i += 1;
            continue;
        }
        if (pending_var_decl) {
            switch (ch) {
                '(' => var_paren_depth += 1,
                ')' => {
                    if (var_paren_depth > 0) var_paren_depth -= 1;
                },
                '[' => var_bracket_depth += 1,
                ']' => {
                    if (var_bracket_depth > 0) var_bracket_depth -= 1;
                },
                ',' => if (var_paren_depth == 0 and var_brace_depth == 0 and var_bracket_depth == 0) {
                    expect_var_binding = true;
                },
                ';' => if (var_paren_depth == 0 and var_brace_depth == 0 and var_bracket_depth == 0) {
                    pending_var_decl = false;
                    expect_var_binding = false;
                },
                else => {},
            }
        }
        if (isIdentifierStart(ch)) {
            const end = readIdentifierEnd(stmt_source, i);
            const ident = stmt_source[i..end];
            if (std.mem.eql(u8, ident, "function")) {
                expect_function_params = true;
                buf.appendSlice(ctx.allocator, ident) catch return stmt_source;
                i = end;
                continue;
            }
            if (std.mem.eql(u8, ident, "var")) {
                pending_var_decl = true;
                expect_var_binding = true;
                var_paren_depth = 0;
                var_brace_depth = 0;
                var_bracket_depth = 0;
                buf.appendSlice(ctx.allocator, ident) catch return stmt_source;
                i = end;
                continue;
            }
            if (pending_var_decl and expect_var_binding and var_paren_depth == 0 and var_brace_depth == 0 and var_bracket_depth == 0) {
                if (scopes.items.len != 0) {
                    appendShadowedBinding(ctx, &scopes.items[scopes.items.len - 1], ident);
                }
                expect_var_binding = false;
            }

            if (findImportForLocal(imports, ident)) |item| {
                if (!isShadowedInScopes(scopes.items, ident) and shouldRewriteImportIdentifier(stmt_source, i, end)) {
                    var replacement = item.replacement_expr.?;
                    if (item.kind == .default_value and prefer_bracket_default_access and item.temp_name != null) {
                        replacement = std.fmt.allocPrint(ctx.allocator, "{s}[\"default\"]", .{item.temp_name.?}) catch replacement;
                    }
                    if (shouldWrapImportedCall(stmt_source, i, end, item)) {
                        replacement = std.fmt.allocPrint(ctx.allocator, "(0, {s})", .{replacement}) catch replacement;
                    }
                    buf.appendSlice(ctx.allocator, replacement) catch return stmt_source;
                    changed = true;
                    i = end;
                    continue;
                }
            }

            buf.appendSlice(ctx.allocator, ident) catch return stmt_source;
            i = end;
            continue;
        }

        buf.append(ctx.allocator, ch) catch return stmt_source;
        i += 1;
    }

    if (!changed) return stmt_source;
    return buf.items;
}

fn buildEffectiveSource(ctx: *TransformContext, start_off: u32, end_off: u32) []const u8 {
    if (start_off >= end_off or end_off > ctx.ast.source.len) return "";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: u32 = start_off;
    var found_any = false;
    const ordered = ctx.orderedReplacements() catch return ctx.ast.source[start_off..end_off];
    const range_start = ctx.replacementLowerBound(start_off) catch return ctx.ast.source[start_off..end_off];
    for (ordered[range_start..]) |replacement| {
        if (replacement.start >= end_off) break;
        if (replacement.node_index >= ctx.ast.nodes.items(.tag).len) continue;

        const node_start = nodeStartOffsetRaw(ctx, replacement.node_index);
        const node_end = replacement.end;
        if (node_start < start_off or node_end > end_off) continue;
        if (node_start == start_off and node_end == end_off) continue;
        if (node_start < pos) continue;

        if (node_start > pos) {
            buf.appendSlice(ctx.allocator, ctx.ast.source[pos..node_start]) catch return ctx.ast.source[start_off..end_off];
        }
        buf.appendSlice(ctx.allocator, replacement.text) catch return ctx.ast.source[start_off..end_off];
        pos = node_end;
        found_any = true;
    }
    if (!found_any) return ctx.ast.source[start_off..end_off];
    if (pos < end_off) {
        buf.appendSlice(ctx.allocator, ctx.ast.source[pos..end_off]) catch return ctx.ast.source[start_off..end_off];
    }
    return buf.items;
}

fn findOrCreateTemp(
    ctx: *TransformContext,
    source: []const u8,
    temps: *std.ArrayListUnmanaged(SourceTemp),
) []const u8 {
    for (temps.items) |entry| {
        if (std.mem.eql(u8, entry.source, source)) return entry.temp;
    }

    const temp = sanitizeModuleTempBase(ctx, source) orelse "_mod";
    temps.append(ctx.allocator, .{ .source = source, .temp = temp }) catch {};
    return temp;
}

fn sanitizeModuleTempBase(ctx: *TransformContext, source: []const u8) ?[]const u8 {
    const tail = if (std.mem.lastIndexOfScalar(u8, source, '/')) |idx|
        source[idx + 1 ..]
    else
        source;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '_') catch return null;

    var upper_next = false;
    for (tail) |ch| {
        if (isIdentOrDigit(ch)) {
            if (buf.items.len == 1) {
                buf.append(ctx.allocator, std.ascii.toLower(ch)) catch return null;
            } else if (upper_next) {
                buf.append(ctx.allocator, std.ascii.toUpper(ch)) catch return null;
                upper_next = false;
            } else {
                buf.append(ctx.allocator, ch) catch return null;
            }
        } else {
            upper_next = true;
        }
    }

    if (buf.items.len == 1) {
        buf.appendSlice(ctx.allocator, "mod") catch return null;
    }
    return buf.items;
}

fn replaceAllIdentifierAware(allocator: std.mem.Allocator, source: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0 or std.mem.eql(u8, needle, replacement)) return source;

    var changed = false;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (i + needle.len <= source.len and
            std.mem.eql(u8, source[i .. i + needle.len], needle) and
            isIdentifierBoundary(source, i, needle.len))
        {
            buf.appendSlice(allocator, replacement) catch return source;
            i += needle.len;
            changed = true;
            continue;
        }
        buf.append(allocator, source[i]) catch return source;
        i += 1;
    }
    if (!changed) return source;
    return buf.items;
}

fn collectFunctionRewriteScope(ctx: *TransformContext, params_source: []const u8) FunctionRewriteScope {
    var scope = FunctionRewriteScope{};
    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
    var depth_bracket: usize = 0;
    var segment_start: usize = 0;
    var i: usize = 0;
    while (i < params_source.len) : (i += 1) {
        const ch = params_source[i];
        switch (ch) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '{' => depth_brace += 1,
            '}' => {
                if (depth_brace > 0) depth_brace -= 1;
            },
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            '"', '\'', '`' => {
                i = skipQuotedLiteral(params_source, i) orelse break;
            },
            '/' => if (i + 1 < params_source.len) {
                if (params_source[i + 1] == '/') {
                    i = skipLineComment(params_source, i + 2);
                    continue;
                }
                if (params_source[i + 1] == '*') {
                    i = skipBlockComment(params_source, i + 2) orelse break;
                    continue;
                }
            },
            ',' => if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) {
                appendLeadingParamBinding(ctx, &scope, params_source[segment_start..i]);
                segment_start = i + 1;
            },
            else => {},
        }
    }
    appendLeadingParamBinding(ctx, &scope, params_source[segment_start..]);
    return scope;
}

fn appendLeadingParamBinding(ctx: *TransformContext, scope: *FunctionRewriteScope, raw_segment: []const u8) void {
    var segment = std.mem.trim(u8, raw_segment, " \t\r\n");
    if (segment.len == 0) return;
    if (std.mem.startsWith(u8, segment, "...")) {
        segment = std.mem.trimStart(u8, segment[3..], " \t\r\n");
    }
    if (segment.len == 0) return;
    if (segment[0] == '{' or segment[0] == '[') return;
    if (!isIdentifierStart(segment[0])) return;

    const end = readIdentifierEnd(segment, 0);
    const ident = segment[0..end];
    for (scope.shadowed.items) |existing| {
        if (std.mem.eql(u8, existing, ident)) return;
    }
    scope.shadowed.append(ctx.allocator, ident) catch {};
}

fn findImportForLocal(imports: []const JSImport, ident: []const u8) ?JSImport {
    for (imports) |item| {
        if (item.local_name == null or item.replacement_expr == null) continue;
        if (std.mem.eql(u8, item.local_name.?, ident)) return item;
    }
    return null;
}

fn isShadowedInScopes(scopes: []const FunctionRewriteScope, ident: []const u8) bool {
    var i = scopes.len;
    while (i > 0) {
        i -= 1;
        for (scopes[i].shadowed.items) |shadowed| {
            if (std.mem.eql(u8, shadowed, ident)) return true;
        }
    }
    return false;
}

fn appendShadowedBinding(ctx: *TransformContext, scope: *FunctionRewriteScope, ident: []const u8) void {
    for (scope.shadowed.items) |existing| {
        if (std.mem.eql(u8, existing, ident)) return;
    }
    scope.shadowed.append(ctx.allocator, ident) catch {};
}

fn shouldRewriteImportIdentifier(source: []const u8, start: usize, end: usize) bool {
    const prev_idx = prevSignificantIndex(source, start);
    const next_idx = nextSignificantIndex(source, end);

    if (prev_idx) |idx| {
        if (source[idx] == '.') return false;
    }
    if (next_idx) |idx| {
        if (source[idx] == ':') {
            if (prev_idx) |prev_i| {
                const prev = source[prev_i];
                if (prev == '{' or prev == ',') return false;
            } else {
                return false;
            }
        }
    }
    if (previousKeyword(source, start)) |keyword| {
        if (std.mem.eql(u8, keyword, "var") or
            std.mem.eql(u8, keyword, "let") or
            std.mem.eql(u8, keyword, "const") or
            std.mem.eql(u8, keyword, "function") or
            std.mem.eql(u8, keyword, "class") or
            std.mem.eql(u8, keyword, "catch"))
        {
            return false;
        }
    }
    return true;
}

fn shouldWrapImportedCall(source: []const u8, start: usize, end: usize, item: JSImport) bool {
    if (item.kind != .named and item.kind != .default_value) return false;
    const next_idx = nextSignificantIndex(source, end) orelse return false;
    if (source[next_idx] != '(') return false;
    if (previousKeyword(source, start)) |keyword| {
        if (std.mem.eql(u8, keyword, "new")) return false;
    }
    if (prevSignificantIndex(source, start)) |prev_idx| {
        if (source[prev_idx] == '.') return false;
    }
    return true;
}

fn prefersBracketDefaultImportAccess(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "babelHelpers.createClass(") != null or
        std.mem.indexOf(u8, source, "babelHelpers.inherits(") != null or
        std.mem.indexOf(u8, source, "babelHelpers.callSuper(") != null or
        std.mem.indexOf(u8, source, "babelHelpers.classCallCheck(") != null;
}

fn prevSignificantIndex(source: []const u8, start: usize) ?usize {
    if (start == 0) return null;
    var i = start;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(source[i])) return i;
    }
    return null;
}

fn nextSignificantIndex(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i < source.len) {
        if (std.ascii.isWhitespace(source[i])) {
            i += 1;
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len) {
            if (source[i + 1] == '/') {
                i = skipLineComment(source, i + 2);
                continue;
            }
            if (source[i + 1] == '*') {
                i = (skipBlockComment(source, i + 2) orelse return null) + 1;
                continue;
            }
        }
        return i;
    }
    return null;
}

fn previousKeyword(source: []const u8, start: usize) ?[]const u8 {
    const prev_idx = prevSignificantIndex(source, start) orelse return null;
    if (!isIdentOrDigit(source[prev_idx])) return null;

    var word_start = prev_idx;
    while (word_start > 0 and isIdentOrDigit(source[word_start - 1])) : (word_start -= 1) {}
    return source[word_start .. prev_idx + 1];
}

fn skipQuotedLiteral(source: []const u8, start: usize) ?usize {
    const quote = source[start];
    var i = start + 1;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += 1;
            continue;
        }
        if (source[i] == quote) return i;
    }
    return null;
}

fn skipLineComment(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    return i;
}

fn skipBlockComment(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] == '*' and source[i + 1] == '/') return i + 1;
    }
    return null;
}

fn findMatchingDelimiter(source: []const u8, open_index: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var i = open_index;
    while (i < source.len) : (i += 1) {
        const ch = source[i];
        if (ch == open) {
            depth += 1;
            continue;
        }
        if (ch == close) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
            continue;
        }
        if (ch == '"' or ch == '\'' or ch == '`') {
            i = skipQuotedLiteral(source, i) orelse return null;
            continue;
        }
        if (ch == '/' and i + 1 < source.len) {
            if (source[i + 1] == '/') {
                i = skipLineComment(source, i + 2);
            } else if (source[i + 1] == '*') {
                i = skipBlockComment(source, i + 2) orelse return null;
            }
        }
    }
    return null;
}

fn readIdentifierEnd(source: []const u8, start: usize) usize {
    var end = start + 1;
    while (end < source.len and isIdentOrDigit(source[end])) : (end += 1) {}
    return end;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$';
}

fn replaceLiteralAll(allocator: std.mem.Allocator, source: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0 or std.mem.eql(u8, needle, replacement)) return source;

    var changed = false;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |idx| {
        buf.appendSlice(allocator, source[cursor..idx]) catch return source;
        buf.appendSlice(allocator, replacement) catch return source;
        cursor = idx + needle.len;
        changed = true;
    }
    if (!changed) return source;
    buf.appendSlice(allocator, source[cursor..]) catch return source;
    return buf.items;
}

fn rewriteAutomaticJsxRuntimeName(ctx: *TransformContext, source: []const u8) []const u8 {
    return replaceLiteralAll(ctx.allocator, source, "_reactJsxRuntime", "_jsxRuntime") catch source;
}

fn rewriteAutomaticJsxCallSites(ctx: *TransformContext, source: []const u8) []const u8 {
    var current = replaceLiteralAll(ctx.allocator, source, "_jsxRuntime.jsx(", "(0, _jsxRuntime.jsx)(") catch source;
    current = replaceLiteralAll(ctx.allocator, current, "_jsxRuntime.jsxs(", "(0, _jsxRuntime.jsxs)(") catch current;
    return current;
}

fn normalizeImportedJsxFormatting(ctx: *TransformContext, source: []const u8) []const u8 {
    var current = replaceLiteralAll(ctx.allocator, source, "(\n    /*#__PURE__*/", "(/*#__PURE__*/") catch source;
    if (std.mem.indexOf(u8, current, "_jsxRuntime.") != null) {
        current = replaceLiteralAll(ctx.allocator, current, "}),\n    ", "}), ") catch current;
        current = replaceLiteralAll(ctx.allocator, current, "\n);", ");") catch current;
    }
    return current;
}

fn isIdentifierBoundary(source: []const u8, start: usize, len: usize) bool {
    const before_ok = start == 0 or !isIdentOrDigit(source[start - 1]);
    const end = start + len;
    const after_ok = end >= source.len or !isIdentOrDigit(source[end]);
    return before_ok and after_ok;
}

fn isIdentOrDigit(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '$';
}

fn isImportTag(tag: Node.Tag) bool {
    return switch (tag) {
        .import_declaration, .import_declaration_type, .import_declaration_typeof => true,
        else => false,
    };
}

fn isLoweredModuleTag(tag: Node.Tag) bool {
    return switch (tag) {
        .import_declaration, .import_declaration_type, .import_declaration_typeof => true,
        .ts_import_equals_declaration, .ts_export_assignment => true,
        else => false,
    };
}

fn nodeStartOffset(ctx: *TransformContext, node: NodeIndex) u32 {
    return nodeStartOffsetRaw(ctx, @intFromEnum(node));
}

fn nodeStartOffsetRaw(ctx: *TransformContext, ni: usize) u32 {
    const mt = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(mt)];
}

fn unquoteModuleSource(token_slice: []const u8) []const u8 {
    if (token_slice.len < 2) return token_slice;
    const first = token_slice[0];
    const last = token_slice[token_slice.len - 1];
    if ((first == '"' or first == '\'') and last == first) {
        return token_slice[1 .. token_slice.len - 1];
    }
    return token_slice;
}

fn indentBlock(ctx: *TransformContext, source: []const u8, prefix: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) buf.append(ctx.allocator, '\n') catch return source;
        first = false;
        if (line.len != 0) {
            buf.appendSlice(ctx.allocator, prefix) catch return source;
            buf.appendSlice(ctx.allocator, line) catch return source;
        }
    }
    return buf.items;
}

fn findTsExportAssignment(ctx: *TransformContext, program: NodeIndex) ?NodeIndex {
    const children = visitor.getChildren(ctx.ast, program);
    for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt != .none and ctx.nodeTag(stmt) == .ts_export_assignment) return stmt;
    }
    return null;
}

fn extractExternalModuleSource(ctx: *TransformContext, module_ref: NodeIndex) ?[]const u8 {
    if (ctx.nodeTag(module_ref) != .ts_external_module_reference) return null;
    const value_node = ctx.nodeData(module_ref).unary;
    return unquoteModuleSource(renderNodeSource(ctx, value_node));
}

fn renderExportAssignment(ctx: *TransformContext, export_node: NodeIndex, imports: []const JSImport) []const u8 {
    const expr = ctx.nodeData(export_node).unary;
    const expr_source = rewriteAutomaticJsxCallSites(
        ctx,
        rewriteAutomaticJsxRuntimeName(ctx, rewriteImportedNames(ctx, renderNodeSource(ctx, expr), imports)),
    );
    return std.fmt.allocPrint(ctx.allocator, "module.exports = {s};", .{expr_source}) catch "";
}

fn renderNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;

    const start = nodeStartOffset(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    return buildEffectiveSource(ctx, start, end);
}
