const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const ResolvedEnumValue = pipeline.ResolvedEnumValue;
const visitor = @import("visitor.zig");
const ast_ops = @import("ast_ops.zig");
const Codegen = @import("../codegen.zig").Codegen;
const scope_mod = @import("../scope.zig");

pub const TsStripConfig = struct {
    only_remove_type_imports: bool = false,
    optimize_const_enums: bool = false,
    /// When set, narrow the enter filter for non-TS languages so that
    /// only `.program` is dispatched (all other tags are no-ops for JS/Flow).
    language: ?@import("../ast.zig").Language = null,
};

var g_config: TsStripConfig = .{};

pub fn createPass(config: TsStripConfig) Pass {
    g_config = config;

    // For non-TS languages, only .program needs enter dispatch;
    // all other tags would hit the early-return at the top of enterNode.
    const is_ts = if (config.language) |lang| lang.isTypeScript() else true;

    var filter = visitor.NodeTagBitSet.initEmpty();

    // Pre-scan: handle program node to trigger import usage analysis
    filter.set(@intFromEnum(Node.Tag.program));

    if (is_ts) {
        // A) Remove entire node — pure type declarations
        filter.set(@intFromEnum(Node.Tag.ts_type_alias_declaration));
        filter.set(@intFromEnum(Node.Tag.ts_interface_declaration));
        filter.set(@intFromEnum(Node.Tag.ts_declare_function));
        filter.set(@intFromEnum(Node.Tag.ts_declare_variable));
        filter.set(@intFromEnum(Node.Tag.ts_declare_method));

        // B) Replace with inner expression — type casts/wrappers
        filter.set(@intFromEnum(Node.Tag.ts_as_expression));
        filter.set(@intFromEnum(Node.Tag.ts_satisfies_expression));
        filter.set(@intFromEnum(Node.Tag.ts_non_null_expression));
        filter.set(@intFromEnum(Node.Tag.ts_type_assertion));
        filter.set(@intFromEnum(Node.Tag.ts_instantiation_expression));
        filter.set(@intFromEnum(Node.Tag.ts_type_cast_expression));

        // C) Remove type annotations and type parameter declarations
        filter.set(@intFromEnum(Node.Tag.ts_type_annotation));
        filter.set(@intFromEnum(Node.Tag.ts_type_parameter_declaration));
        filter.set(@intFromEnum(Node.Tag.ts_type_parameter_instantiation));

        // D) Import/export type handling
        filter.set(@intFromEnum(Node.Tag.import_declaration_type));
        filter.set(@intFromEnum(Node.Tag.export_named_type));

        // E) Module declarations (declare namespace/module)
        filter.set(@intFromEnum(Node.Tag.ts_module_declaration));

        // F) Export handling — check if declaration is a TS type construct
        filter.set(@intFromEnum(Node.Tag.export_named));
        filter.set(@intFromEnum(Node.Tag.export_default));

        // G) Import handling — strip type specifiers from regular imports
        filter.set(@intFromEnum(Node.Tag.import_declaration));

        // H) Side table cleanup for functions, classes, etc.
        filter.set(@intFromEnum(Node.Tag.function_declaration));
        filter.set(@intFromEnum(Node.Tag.async_function_declaration));
        filter.set(@intFromEnum(Node.Tag.generator_declaration));
        filter.set(@intFromEnum(Node.Tag.async_generator_declaration));
        filter.set(@intFromEnum(Node.Tag.function_expr));
        filter.set(@intFromEnum(Node.Tag.arrow_function_expr));
        filter.set(@intFromEnum(Node.Tag.class_declaration));
        filter.set(@intFromEnum(Node.Tag.class_expr));
        filter.set(@intFromEnum(Node.Tag.class_method));
        filter.set(@intFromEnum(Node.Tag.class_private_method));
        filter.set(@intFromEnum(Node.Tag.class_field));
        filter.set(@intFromEnum(Node.Tag.class_private_field));
        filter.set(@intFromEnum(Node.Tag.method_definition));
        filter.set(@intFromEnum(Node.Tag.getter));
        filter.set(@intFromEnum(Node.Tag.setter));
        filter.set(@intFromEnum(Node.Tag.computed_method));
        filter.set(@intFromEnum(Node.Tag.declarator));

        // I) TS parameter property — replace with inner parameter
        filter.set(@intFromEnum(Node.Tag.ts_parameter_property));

        // J) TS enum declaration (for declare enum removal)
        filter.set(@intFromEnum(Node.Tag.ts_enum_declaration));
        filter.set(@intFromEnum(Node.Tag.member_expr));
        filter.set(@intFromEnum(Node.Tag.computed_member_expr));

        // N) export_all — handle `export type * from` removal
        filter.set(@intFromEnum(Node.Tag.export_all));

        // L) TS index signature (in class bodies — remove)
        filter.set(@intFromEnum(Node.Tag.ts_index_signature));

        // K) TS import equals, export assignment, namespace export
        filter.set(@intFromEnum(Node.Tag.ts_import_equals_declaration));
        filter.set(@intFromEnum(Node.Tag.ts_export_assignment));
        filter.set(@intFromEnum(Node.Tag.ts_namespace_export_declaration));
    }

    // Exit filter — exitNode only handles .program and .ts_module_declaration.
    var ef = visitor.NodeTagBitSet.initEmpty();
    ef.set(@intFromEnum(Node.Tag.program));
    if (is_ts) ef.set(@intFromEnum(Node.Tag.ts_module_declaration));

    return .{
        .name = "ts_strip",
        .node_filter = filter,
        .exit_filter = ef,
        .enter = enterNode,
        .exit = exitNode,
        .priority = 10,
    };
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);

    if (tag == .program) {
        ctx.had_ts_strip_pass = true;
        if (!ctx.ast.language.isTypeScript()) return .continue_traversal;
        scanImportUsage(ctx);
        // Bulk-clear dense TS side tables so per-node removes for
        // identifiers, declarators, patterns, and call-sites are
        // unnecessary (those tags are no longer in node_filter).
        bulkClearTsSideTables(ctx);
        return .continue_traversal;
    }

    // Non-TS files: side tables are unpopulated and TS-specific syntax is
    // absent, so every handler below would be a no-op.
    if (!ctx.ast.language.isTypeScript()) return .continue_traversal;

    switch (tag) {

        // ────────────────────────────────────────────────────────────
        // A) Remove entire node — pure type declarations
        // ────────────────────────────────────────────────────────────
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        .ts_declare_function,
        .ts_declare_variable,
        .ts_declare_method,
        => return .remove_node,

        // ────────────────────────────────────────────────────────────
        // B) Replace with inner expression — type casts/wrappers
        // ────────────────────────────────────────────────────────────
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_non_null_expression,
        .ts_type_assertion,
        .ts_instantiation_expression,
        .ts_type_cast_expression,
        => {
            unwrapTypeExpressions(idx, ctx);
            return .continue_traversal;
        },

        // ────────────────────────────────────────────────────────────
        // C) Remove type annotations and type parameter nodes
        // ────────────────────────────────────────────────────────────
        .ts_type_annotation,
        .ts_type_parameter_declaration,
        .ts_type_parameter_instantiation,
        => return .remove_node,

        // ────────────────────────────────────────────────────────────
        // D) Import/export type handling
        // ────────────────────────────────────────────────────────────
        .import_declaration_type => {
            // `import type { Foo } from "bar"` → remove entirely
            ctx.needs_module_marker = true;
            return .remove_node;
        },

        .export_named_type => {
            return handleExportNamedType(idx, ctx);
        },

        // ────────────────────────────────────────────────────────────
        // E) Module declarations — remove if declare, transform if namespace
        // ────────────────────────────────────────────────────────────
        .ts_module_declaration => {
            if (isDeclareNode(ctx, idx)) {
                return .remove_node;
            }
            return .continue_traversal;
        },

        // ────────────────────────────────────────────────────────────
        // F) Export handling — strip TS declarations from exports
        // ────────────────────────────────────────────────────────────
        .export_named => {
            return handleExportNamed(idx, ctx);
        },

        .export_default => {
            return handleExportDefault(idx, ctx);
        },

        // ────────────────────────────────────────────────────────────
        // G) Import handling — strip type specifiers
        // ────────────────────────────────────────────────────────────
        .import_declaration => {
            return handleImportDeclaration(idx, ctx);
        },

        // ────────────────────────────────────────────────────────────
        // H) Side table cleanup for functions, classes, etc.
        // ────────────────────────────────────────────────────────────
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        => {
            cleanSideTables(ctx, idx);
            // Strip `this` parameter from function params
            stripThisParameter(ctx, idx);
            return .continue_traversal;
        },

        .arrow_function_expr => {
            cleanSideTables(ctx, idx);
            // Arrow functions cannot have `this` parameter, skip stripping
            return .continue_traversal;
        },

        .class_declaration => {
            // Check if this is a declare class — remove entirely
            if (isDeclareClass(ctx, idx)) {
                return .remove_node;
            }
            cleanSideTables(ctx, idx);
            _ = ctx.ast.super_type_parameters.remove(@intFromEnum(idx));
            _ = ctx.ast.implements_list.remove(@intFromEnum(idx));
            // Remove abstract/declare modifiers from class
            _ = ctx.ast.ts_class_modifiers.remove(@intFromEnum(idx));
            return .continue_traversal;
        },

        .class_expr => {
            cleanSideTables(ctx, idx);
            _ = ctx.ast.super_type_parameters.remove(@intFromEnum(idx));
            _ = ctx.ast.implements_list.remove(@intFromEnum(idx));
            _ = ctx.ast.ts_class_modifiers.remove(@intFromEnum(idx));
            return .continue_traversal;
        },

        .class_method,
        .class_private_method,
        .method_definition,
        .getter,
        .setter,
        .computed_method,
        => {
            cleanSideTables(ctx, idx);
            // Strip `this` parameter from method params
            stripThisParameterFromMethod(ctx, idx);
            // Remove TS modifiers (public, private, protected, abstract, override, readonly)
            _ = ctx.ast.ts_class_modifiers.remove(@intFromEnum(idx));
            // Handle parameter properties (insert this.x = x assignments)
            if (tag == .class_method or tag == .method_definition) {
                handleParameterProperties(idx, ctx);
            }
            return .continue_traversal;
        },

        .class_field,
        .class_private_field,
        => {
            cleanSideTables(ctx, idx);
            const has_decorators = ctx.ast.decorators_map.contains(@intFromEnum(idx));
            // Remove declare/abstract fields entirely unless a decorator means the
            // field must remain in output after stripping TS-only syntax.
            if ((isDeclareClassMember(ctx, idx) and !has_decorators) or isAbstractClassMember(ctx, idx)) {
                return .remove_node;
            }
            // Remove TS modifiers but keep the field
            _ = ctx.ast.ts_class_modifiers.remove(@intFromEnum(idx));
            // Clear definite (!) and optional (?) flags from class field flags
            clearClassFieldTsFlags(ctx, idx);
            return .continue_traversal;
        },

        .declarator => {
            // type_annotations and ts_optional_params already bulk-cleared;
            // only ts_class_modifiers (definite !) needs per-node removal.
            _ = ctx.ast.ts_class_modifiers.remove(@intFromEnum(idx));
            return .continue_traversal;
        },

        // Note: .identifier, .rest_element, .assignment_pattern,
        // .object_pattern, .array_pattern are no longer in node_filter — their
        // side-table entries (type_annotations, ts_optional_params) are cleared
        // in bulk during the .program enter handler.
        // .call_expr, .new_expr, .optional_call_expr, .tagged_template_expr,
        // .jsx_opening_element, .jsx_self_closing_element are also removed —
        // type_parameters is bulk-cleared.

        // ────────────────────────────────────────────────────────────
        // I) TS parameter property — replace with inner param
        // ────────────────────────────────────────────────────────────
        .ts_parameter_property => {
            const data = ctx.nodeData(idx);
            const extra_idx = @intFromEnum(data.extra);
            const param: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            ctx.replaceNode(idx, param);
            return .continue_traversal;
        },

        // ────────────────────────────────────────────────────────────
        // J) TS enum declaration — transform to IIFE
        // ────────────────────────────────────────────────────────────
        .ts_enum_declaration => {
            if (isDeclareNode(ctx, idx) and !g_config.optimize_const_enums) {
                return .remove_node;
            }
            handleEnumDeclaration(idx, ctx);
            return .skip_children;
        },

        .member_expr,
        .computed_member_expr,
        => {
            inlineConstEnumMemberAccess(idx, ctx);
            return .continue_traversal;
        },

        // ────────────────────────────────────────────────────────────
        // K) Other TS declarations
        // ────────────────────────────────────────────────────────────
        .ts_import_equals_declaration => {
            return handleImportEquals(idx, ctx);
        },

        .ts_export_assignment => {
            // `export = expr` — this is CommonJS-style, keep it for now
            return .continue_traversal;
        },

        .ts_namespace_export_declaration => {
            // `export as namespace X` — remove
            return .remove_node;
        },

        // ────────────────────────────────────────────────────────────
        // L) TS index signature — remove from class body
        // ────────────────────────────────────────────────────────────
        .ts_index_signature => return .remove_node,

        // ────────────────────────────────────────────────────────────
        // N) export_all — remove `export type * from` entirely
        // ────────────────────────────────────────────────────────────
        .export_all => {
            return handleExportAll(idx, ctx);
        },

        else => return .continue_traversal,
    }
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (!ctx.ast.language.isTypeScript()) return .continue_traversal;
    const tag = ctx.nodeTag(idx);
    switch (tag) {
        .program => sanitizeTypeScriptReplacementSources(ctx),
        .ts_module_declaration => {
            if (!isDeclareNode(ctx, idx) and isInProgramBody(ctx, idx)) {
                handleNamespaceDeclaration(idx, ctx);
            }
        },
        else => {},
    }
    return .continue_traversal;
}

fn sanitizeTypeScriptReplacementSources(ctx: *TransformContext) void {
    var iter = ctx.ast.replacement_source.iterator();
    while (iter.next()) |entry| {
        const sanitized = stripPostfixNonNullAssertions(ctx, entry.value_ptr.*);
        entry.value_ptr.* = sanitized;
    }
}

fn stripPostfixNonNullAssertions(ctx: *TransformContext, src: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var changed = false;
    var in_quote: ?u8 = null;
    var escaped = false;

    for (src, 0..) |c, i| {
        if (in_quote) |q| {
            buf.append(ctx.allocator, c) catch return src;
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                in_quote = null;
            }
            continue;
        }

        switch (c) {
            '\'', '"', '`' => {
                in_quote = c;
                buf.append(ctx.allocator, c) catch return src;
                continue;
            },
            '!' => {
                const prev = previousNonWhitespace(src, i);
                const next = nextNonWhitespace(src, i + 1);
                if (isPostfixNonNullContext(prev, next)) {
                    changed = true;
                    continue;
                }
            },
            else => {},
        }

        buf.append(ctx.allocator, c) catch return src;
    }

    return if (changed) buf.items else src;
}

fn previousNonWhitespace(src: []const u8, end_idx: usize) ?u8 {
    var i = end_idx;
    while (i > 0) {
        i -= 1;
        const c = src[i];
        if (!std.ascii.isWhitespace(c)) return c;
    }
    return null;
}

fn nextNonWhitespace(src: []const u8, start_idx: usize) ?u8 {
    var i = start_idx;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (!std.ascii.isWhitespace(c)) return c;
    }
    return null;
}

fn isPostfixNonNullContext(prev: ?u8, next: ?u8) bool {
    const p = prev orelse return false;
    const n = next orelse return false;
    const prev_ok = std.ascii.isAlphanumeric(p) or p == '_' or p == '$' or p == ')' or p == ']';
    const next_ok = n == '.' or n == '[' or n == '(' or n == ')' or n == ',' or n == ';' or n == ':' or n == '?';
    return prev_ok and next_ok;
}

// ────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────

/// Unwrap nested type expression wrappers (as, satisfies, non-null, type assertion, etc.)
/// by repeatedly replacing the node with its inner expression until we reach a non-type node.
fn unwrapTypeExpressions(idx: NodeIndex, ctx: *TransformContext) void {
    var max_depth: u32 = 32; // prevent infinite loops
    while (max_depth > 0) : (max_depth -= 1) {
        const tag = ctx.nodeTag(idx);
        const inner = getTypeExpressionInner(ctx, idx, tag) orelse break;
        ctx.replaceNode(idx, inner);
        promoteOptionalChainContinuations(ctx, idx);
    }
}

fn promoteOptionalChainContinuations(ctx: *TransformContext, start_idx: NodeIndex) void {
    var current = start_idx;
    switch (ctx.nodeTag(current)) {
        .optional_chain_expr, .optional_computed_member_expr, .optional_call_expr => {},
        else => return,
    }
    while (true) {
        const parent = findChainParent(ctx, current) orelse break;
        const parent_tag = ctx.nodeTag(parent);
        switch (parent_tag) {
            .member_expr => ctx.ast.nodes.items(.tag)[@intFromEnum(parent)] = .optional_chain_expr,
            .computed_member_expr => ctx.ast.nodes.items(.tag)[@intFromEnum(parent)] = .optional_computed_member_expr,
            .call_expr => ctx.ast.nodes.items(.tag)[@intFromEnum(parent)] = .optional_call_expr,
            .optional_chain_expr, .optional_computed_member_expr, .optional_call_expr => {},
            else => break,
        }
        current = parent;
    }
}

fn findChainParent(ctx: *TransformContext, target: NodeIndex) ?NodeIndex {
    const target_i = @intFromEnum(target);
    const tags = ctx.ast.nodes.items(.tag);
    const data_items = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        const data = data_items[ni];
        switch (tag) {
            .member_expr, .computed_member_expr, .optional_chain_expr, .optional_computed_member_expr => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
            },
            .call_expr, .optional_call_expr => {
                const extra_idx = @intFromEnum(data.extra);
                if (extra_idx < ctx.ast.extra_data.items.len and ctx.ast.extra_data.items[extra_idx] == target_i) {
                    return @enumFromInt(ni);
                }
            },
            else => {},
        }
    }

    return null;
}

/// For a type expression wrapper node, return the inner expression node.
/// Returns null if the node is not a type expression wrapper.
fn getTypeExpressionInner(ctx: *TransformContext, idx: NodeIndex, tag: Node.Tag) ?NodeIndex {
    const data = ctx.nodeData(idx);
    return switch (tag) {
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_instantiation_expression,
        => data.binary.lhs,

        .ts_type_assertion => data.binary.rhs,

        .ts_non_null_expression => data.unary,

        .ts_type_cast_expression => blk: {
            const extra_idx = @intFromEnum(data.extra);
            break :blk @as(NodeIndex, @enumFromInt(ctx.ast.extra_data.items[extra_idx]));
        },

        else => null,
    };
}

fn isDeclareNode(ctx: *TransformContext, idx: NodeIndex) bool {
    const main_tok = ctx.mainToken(idx);
    return std.mem.eql(u8, ctx.tokenSlice(main_tok), "declare");
}

fn isDeclareClass(ctx: *TransformContext, idx: NodeIndex) bool {
    const node_id = @intFromEnum(idx);
    if (ctx.ast.ts_class_modifiers.get(node_id)) |mods| {
        if (mods & 32 != 0) return true; // TS_MOD_DECLARE = 32
    }
    // Also check main_token for "declare"
    return isDeclareNode(ctx, idx);
}

fn isDeclareClassMember(ctx: *TransformContext, idx: NodeIndex) bool {
    const node_id = @intFromEnum(idx);
    if (ctx.ast.ts_class_modifiers.get(node_id)) |mods| {
        // TS_MOD_DECLARE = 32
        if (mods & 32 != 0) return true;
    }
    return false;
}

fn isAbstractClassMember(ctx: *TransformContext, idx: NodeIndex) bool {
    const node_id = @intFromEnum(idx);
    if (ctx.ast.ts_class_modifiers.get(node_id)) |mods| {
        // TS_MOD_ABSTRACT = 16
        if (mods & 16 != 0) return true;
    }
    return false;
}

/// Clear TS-specific flag bits from class field extra data.
/// Bit 16 = optional (?), bit 32 = definite (!).
fn clearClassFieldTsFlags(ctx: *TransformContext, idx: NodeIndex) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 < ctx.ast.extra_data.items.len) {
        ctx.ast.extra_data.items[extra_idx + 2] &= ~@as(u32, 16 | 32); // clear optional & definite
    }
}

/// Strip the `this` parameter from a function/method's params range.
/// `params_start_slot` and `params_end_slot` are indices into extra_data
/// that hold the start/end of the parameter range.
fn stripThisParamFromRange(ctx: *TransformContext, params_start_slot: u32, params_end_slot: u32) void {
    const params_start = ctx.ast.extra_data.items[params_start_slot];
    const params_end = ctx.ast.extra_data.items[params_end_slot];
    if (params_start >= params_end) return;

    // Check if the first parameter is `this`
    const first_param_raw = ctx.ast.extra_data.items[params_start];
    const first_param: NodeIndex = @enumFromInt(first_param_raw);
    if (first_param == .none) return;

    // Navigate through ts_parameter_property wrapper if present
    var param_node = first_param;
    const param_tag = ctx.nodeTag(param_node);
    if (param_tag == .ts_parameter_property) {
        const prop_data = ctx.nodeData(param_node);
        const prop_extra = @intFromEnum(prop_data.extra);
        param_node = @enumFromInt(ctx.ast.extra_data.items[prop_extra]);
    }

    // Navigate through assignment_pattern if present (this: Type = default)
    const inner_tag = ctx.nodeTag(param_node);
    if (inner_tag == .assignment_pattern) {
        const ap_data = ctx.nodeData(param_node);
        param_node = ap_data.binary.lhs;
    }

    // Check if it's an identifier with `this` as the token text
    if (ctx.nodeTag(param_node) != .identifier) return;
    const main_tok = ctx.mainToken(param_node);
    const tok_text = ctx.tokenSlice(main_tok);
    if (!std.mem.eql(u8, tok_text, "this")) return;

    // Strip by advancing the start of the params range by 1
    ctx.ast.extra_data.items[params_start_slot] = params_start + 1;
}

/// Strip `this` parameter from function declarations/expressions.
/// Layout: extra[0]=name, extra[1]=params_start, extra[2]=params_end, extra[3]=body
fn stripThisParameter(ctx: *TransformContext, idx: NodeIndex) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;
    stripThisParamFromRange(ctx, extra_idx + 1, extra_idx + 2);
}

/// Strip `this` parameter from class methods (class_method, method_definition, computed_method).
/// Layout: extra[0]=key, extra[1]=params_start, extra[2]=params_end, extra[3]=body
/// Also handles getter/setter: extra[0]=params_start, extra[1]=params_end, extra[2]=body
fn stripThisParameterFromMethod(ctx: *TransformContext, idx: NodeIndex) void {
    const tag = ctx.nodeTag(idx);
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);

    switch (tag) {
        .getter, .setter => {
            // Getter/setter: extra[0]=params_start, extra[1]=params_end
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
            stripThisParamFromRange(ctx, extra_idx, extra_idx + 1);
        },
        else => {
            // class_method, class_private_method, method_definition, computed_method:
            // extra[0]=key, extra[1]=params_start, extra[2]=params_end
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;
            stripThisParamFromRange(ctx, extra_idx + 1, extra_idx + 2);
        },
    }
}

fn cleanSideTables(ctx: *TransformContext, idx: NodeIndex) void {
    const id = @intFromEnum(idx);
    _ = ctx.ast.type_annotations.remove(id);
    _ = ctx.ast.return_types.remove(id);
    _ = ctx.ast.type_parameters.remove(id);
    _ = ctx.ast.ts_optional_params.remove(id);
}

/// One-shot clear of the four dense TS side tables.  Called once during
/// the .program enter so that high-frequency tags (identifier,
/// rest_element, patterns, call_expr, etc.) no longer need per-node
/// dispatch just to remove entries from these tables.
fn bulkClearTsSideTables(ctx: *TransformContext) void {
    ctx.ast.type_annotations.clearRetainingCapacity();
    ctx.ast.return_types.clearRetainingCapacity();
    ctx.ast.type_parameters.clearRetainingCapacity();
    ctx.ast.ts_optional_params.clearRetainingCapacity();
}

fn isTsTypeDeclaration(tag: Node.Tag) bool {
    return switch (tag) {
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        .ts_declare_function,
        .ts_declare_variable,
        .ts_declare_method,
        => true,
        else => false,
    };
}

fn isDeclareEnumOrClassOrModule(ctx: *TransformContext, node: NodeIndex) bool {
    const tag = ctx.nodeTag(node);
    return switch (tag) {
        .ts_enum_declaration,
        .ts_module_declaration,
        => isDeclareNode(ctx, node),
        .class_declaration => isDeclareClass(ctx, node),
        else => false,
    };
}

fn handleExportNamed(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);

    // Check if there's a declaration (4th extra element)
    if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
        const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
        if (decl_raw != @intFromEnum(NodeIndex.none)) {
            const decl_node: NodeIndex = @enumFromInt(decl_raw);
            const decl_tag = ctx.nodeTag(decl_node);

            // If the declaration is a TS type construct, remove the entire export
            if (isTsTypeDeclaration(decl_tag) or isDeclareEnumOrClassOrModule(ctx, decl_node)) {
                // Interface/declare exports don't need module marker.
                // Type alias exports (export type X = ...) need it to preserve module status.
                if (ctx.ast.source_type == .module and decl_tag != .ts_interface_declaration and
                    decl_tag != .ts_declare_function and decl_tag != .ts_declare_variable and
                    decl_tag != .ts_declare_method)
                {
                    ctx.needs_module_marker = true;
                }
                return .remove_node;
            }

            // For enum/namespace declarations: mark as exported and handle merging.
            // For the first occurrence, the export_named wrapper stays (writes `export ` prefix).
            // For subsequent occurrences (merging), the export_named wrapper must be removed
            // so the replacement_source on the enum outputs just `E = ...;`.
            if (decl_tag == .ts_enum_declaration) {
                if (!isDeclareNode(ctx, decl_node)) {
                    const decl_data = ctx.nodeData(decl_node);
                    const decl_extra = @intFromEnum(decl_data.extra);
                    const name_node_idx: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[decl_extra]);
                    const name_tok = ctx.mainToken(name_node_idx);
                    const ename = ctx.tokenSlice(name_tok);
                    const is_first_export = !ctx.seen_enum_names.contains(ename);

                    ctx.exported_nodes.put(ctx.allocator, @intFromEnum(decl_node), {}) catch {};

                    if (!is_first_export) {
                        // Subsequent export of same enum name — remove the export wrapper,
                        // put the replacement_source on the export_named node instead.
                        // The enum itself will generate `E = ...;` and we store it on
                        // the export_named node.
                        handleEnumDeclaration(decl_node, ctx);
                        // Move the replacement from the enum node to the export node
                        if (ctx.ast.replacement_source.get(@intFromEnum(decl_node))) |repl| {
                            ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), repl) catch {};
                            _ = ctx.ast.replacement_source.remove(@intFromEnum(decl_node));
                        }
                        return .skip_children;
                    }
                }
            } else if (decl_tag == .ts_module_declaration) {
                if (!isDeclareNode(ctx, decl_node)) {
                    ctx.exported_nodes.put(ctx.allocator, @intFromEnum(decl_node), {}) catch {};
                    if (isInProgramBody(ctx, idx)) {
                        const ns_data = ctx.nodeData(decl_node);
                        const ns_extra = @intFromEnum(ns_data.extra);
                        const ns_name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_extra]);
                        const ns_name_tok = ctx.mainToken(ns_name_node);
                        const ns_name = ctx.tokenSlice(ns_name_tok);
                        const is_merge_or_clobber = isClobberingExistingDecl(ctx, ns_name) or ctx.seen_enum_names.contains(ns_name);
                        handleNamespaceDeclaration(decl_node, ctx);
                        // If namespace is clobbering or is a subsequent declaration,
                        // move the replacement to the export_named node to strip 'export'
                        if (is_merge_or_clobber) {
                            if (ctx.ast.replacement_source.get(@intFromEnum(decl_node))) |repl| {
                                ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), repl) catch {};
                                _ = ctx.ast.replacement_source.remove(@intFromEnum(decl_node));
                            }
                        }
                        return .skip_children;
                    }
                }
            }
        }
    }

    // Ensure import usage scan has been performed
    scanImportUsage(ctx);

    // Handle type-only export specifiers: { type Foo } and usage-based elision
    const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
    const specs_end = ctx.ast.extra_data.items[extra_idx + 2];
    const source_token_raw = ctx.ast.extra_data.items[extra_idx];

    if (specs_start < specs_end) {
        // If this has a `from` clause, only strip syntactically typed specifiers
        if (source_token_raw != 0) {
            stripTypeSpecifiers(ctx, extra_idx + 1, extra_idx + 2, true);
        } else {
            // No `from` clause — also strip specifiers referencing type-only names
            stripExportTypeOnlySpecifiers(ctx, extra_idx + 1, extra_idx + 2);
        }

        // After stripping, check if all specifiers were removed
        const new_end = ctx.ast.extra_data.items[extra_idx + 2];
        const new_start = ctx.ast.extra_data.items[extra_idx + 1];
        if (new_start >= new_end) {
            // All specifiers were removed
            ctx.ast.extra_data.items[extra_idx] = 0; // source_token_raw = 0
            ctx.needs_module_marker = true;
            ctx.force_module_marker = g_config.only_remove_type_imports;
            return .remove_node;
        }
    }

    return .continue_traversal;
}

fn handleExportNamedType(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);

    // Check if there's a declaration (export interface I {}, export type T = ...)
    if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
        const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
        if (decl_raw != @intFromEnum(NodeIndex.none)) {
            const decl_node: NodeIndex = @enumFromInt(decl_raw);
            const decl_tag = ctx.nodeTag(decl_node);
            // Interface declarations don't need module marker (Babel behavior).
            if (ctx.ast.source_type == .module and decl_tag != .ts_interface_declaration) {
                ctx.needs_module_marker = true;
                ctx.force_module_marker = g_config.only_remove_type_imports;
            }
            return .remove_node;
        }
    }

    // No declaration — this is `export type { ... }` or `export type { ... } from "..."`
    ctx.needs_module_marker = true;
    ctx.force_module_marker = g_config.only_remove_type_imports;
    return .remove_node;
}

fn handleExportDefault(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const data = ctx.nodeData(idx);
    if (data.unary != .none) {
        const decl_tag = ctx.nodeTag(data.unary);
        if (isTsTypeDeclaration(decl_tag)) {
            // `export default interface Foo {}` → remove entirely
            return .remove_node;
        }
        // Check if the exported identifier refers to a type-only name
        // e.g., `export default Bar;` where `interface Bar {}`
        if (decl_tag == .identifier) {
            scanImportUsage(ctx);
            const tok = ctx.mainToken(data.unary);
            const name = ctx.tokenSlice(tok);
            if (isTypeOnlyName(ctx, name)) {
                return .remove_node;
            }
        }
    }
    return .continue_traversal;
}

fn handleImportDeclaration(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    // Ensure import usage scan has been performed
    scanImportUsage(ctx);

    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
    const specs_end = ctx.ast.extra_data.items[extra_idx + 2];

    if (specs_start >= specs_end) return .continue_traversal;

    // Count type-only vs value specifiers, considering usage analysis
    const tags = ctx.ast.nodes.items(.tag);
    const main_tokens = ctx.ast.nodes.items(.main_token);
    const datas = ctx.ast.nodes.items(.data);
    var elide_count: u32 = 0;
    var keep_count: u32 = 0;
    const total = specs_end - specs_start;

    for (ctx.ast.extra_data.items[specs_start..specs_end]) |s| {
        const spec_tag = tags[s];
        switch (spec_tag) {
            .import_specifier_type, .import_specifier_typeof => elide_count += 1,
            .import_default, .import_namespace => {
                // Check if this name is type-only by usage
                const tok = main_tokens[s];
                const name = ctx.tokenSlice(tok);
                if (!g_config.only_remove_type_imports and ctx.type_only_imports.contains(name)) {
                    elide_count += 1;
                } else {
                    keep_count += 1;
                }
            },
            .import_specifier => {
                // Check local name against usage analysis
                const spec_data = datas[s];
                const spec_extra = @intFromEnum(spec_data.extra);
                const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra + 1]);
                const name = ctx.tokenSlice(local_tok);
                if (!g_config.only_remove_type_imports and ctx.type_only_imports.contains(name)) {
                    elide_count += 1;
                } else {
                    keep_count += 1;
                }
            },
            else => keep_count += 1,
        }
    }

    if (elide_count == 0) return .continue_traversal;

    if (keep_count == 0) {
        // In onlyRemoveTypeImports mode, preserve the import as a side-effect import.
        if (g_config.only_remove_type_imports) {
            stripTypeAndUnusedSpecifiers(ctx, extra_idx + 1, extra_idx + 2);
            return .continue_traversal;
        }
        // Otherwise, all specifiers are type-only → remove the entire import.
        ctx.needs_module_marker = true;
        return .remove_node;
    }

    // Mixed: remove type-only specifiers by compacting in-place
    stripTypeAndUnusedSpecifiers(ctx, extra_idx + 1, extra_idx + 2);
    _ = total;
    return .continue_traversal;
}

/// Strip type-only AND usage-based type-only specifiers from an import range.
fn stripTypeAndUnusedSpecifiers(ctx: *TransformContext, start_slot: u32, end_slot: u32) void {
    const specs_start = ctx.ast.extra_data.items[start_slot];
    const specs_end = ctx.ast.extra_data.items[end_slot];
    if (specs_start >= specs_end) return;

    const tags = ctx.ast.nodes.items(.tag);
    const main_tokens = ctx.ast.nodes.items(.main_token);
    const datas = ctx.ast.nodes.items(.data);

    var write_pos = specs_start;
    for (ctx.ast.extra_data.items[specs_start..specs_end]) |s| {
        const spec_tag = tags[s];
        const should_remove = switch (spec_tag) {
            .import_specifier_type, .import_specifier_typeof => true,
            .import_default, .import_namespace => blk: {
                const tok = main_tokens[s];
                const name = ctx.tokenSlice(tok);
                break :blk !g_config.only_remove_type_imports and ctx.type_only_imports.contains(name);
            },
            .import_specifier => blk: {
                const spec_data = datas[s];
                const spec_extra = @intFromEnum(spec_data.extra);
                const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra + 1]);
                const name = ctx.tokenSlice(local_tok);
                break :blk !g_config.only_remove_type_imports and ctx.type_only_imports.contains(name);
            },
            else => false,
        };

        if (!should_remove) {
            ctx.ast.extra_data.items[write_pos] = s;
            write_pos += 1;
        }
    }

    ctx.ast.extra_data.items[end_slot] = write_pos;
}

fn handleImportEquals(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);

    // Check if it's type-only — remove
    if (extra_idx + 2 < ctx.ast.extra_data.items.len) {
        const is_type = ctx.ast.extra_data.items[extra_idx + 2];
        if (is_type != 0) {
            return .remove_node;
        }
    }

    // Non-type import equals: `import foo = bar` → `var foo = bar`
    // `import foo = require("x")` → keep as-is (CJS) for now
    const module_ref: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
    const module_ref_tag = ctx.nodeTag(module_ref);

    if (module_ref_tag == .ts_external_module_reference) {
        // `import foo = require("x")` — CJS, keep as-is
        return .continue_traversal;
    }

    // Check if the bound name is used in value positions.
    // If not used, remove the import-equals entirely (elide unused import bindings).
    // But don't remove exported import-equals (they're always "used").
    const id_token_raw = ctx.ast.extra_data.items[extra_idx];
    const id_tok: TokenIndex = @enumFromInt(id_token_raw);
    const bound_name = ctx.tokenSlice(id_tok);

    // Check if the import-equals is exported by looking at the source
    // for an 'export' keyword before the 'import' keyword.
    const main_tok = ctx.mainToken(idx);
    const tok_start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
    const is_exported = tok_start >= 7 and std.mem.eql(u8, ctx.ast.source[tok_start - 7 .. tok_start], "export ");
    if (!is_exported and !g_config.only_remove_type_imports) {
        // Ensure usage scan has been performed
        scanImportUsage(ctx);

        // Check if the bound name is only used in type positions
        if (isImportEqualsUnused(ctx, bound_name, idx)) {
            return .remove_node;
        }
    }

    // `import foo = bar` or `import foo = ns.X` → `var foo = bar`
    // Transform in-place by creating new nodes

    // Create identifier node for the binding
    const id_node = ctx.addNewNode(.{
        .tag = .identifier,
        .main_token = @enumFromInt(id_token_raw),
        .data = .{ .none = {} },
    }) catch return .continue_traversal;

    // Create declarator node: foo = bar
    const decl_node = ctx.addNewNode(.{
        .tag = .declarator,
        .main_token = @enumFromInt(0),
        .data = .{ .binary = .{ .lhs = id_node, .rhs = module_ref } },
    }) catch return .continue_traversal;

    // Create extra_data range for var_declaration
    const range_start = ctx.addExtra(@intFromEnum(decl_node)) catch return .continue_traversal;
    const range_end = @as(u32, @intCast(ctx.ast.extra_data.items.len));

    // Create extra_data for var_declaration: [range_start, range_end]
    const var_extra = ctx.addExtra(range_start) catch return .continue_traversal;
    _ = ctx.addExtra(range_end) catch return .continue_traversal;

    // Replace the node in-place
    const i = @intFromEnum(idx);
    ctx.ast.nodes.items(.tag)[i] = .var_declaration;
    ctx.ast.nodes.items(.data)[i] = .{ .extra = @enumFromInt(var_extra) };

    return .skip_children;
}

/// Check if an import-equals binding name is unused in value positions.
/// Scans the AST for identifiers matching the name that are NOT inside
/// type annotations, type aliases, or the import-equals itself.
fn isImportEqualsUnused(ctx: *TransformContext, name: []const u8, self_idx: NodeIndex) bool {
    _ = self_idx;
    const tags = ctx.ast.nodes.items(.tag);
    const main_tokens = ctx.ast.nodes.items(.main_token);
    const end_offsets = ctx.ast.nodes.items(.end_offset);
    const tok_starts = ctx.ast.tokens.items(.start);

    // Collect source ranges of ALL ts_import_equals_declaration and removed nodes
    // (import-equals that were already processed) to skip identifiers within them.
    var skip_ranges: [64]struct { start: u32, end: u32 } = undefined;
    var skip_count: usize = 0;
    for (tags, 0..) |tag, i| {
        if ((tag == .ts_import_equals_declaration or tag == .removed) and skip_count < skip_ranges.len) {
            const eo = end_offsets[i];
            if (eo == 0) continue; // Synthetic node
            skip_ranges[skip_count] = .{
                .start = tok_starts[@intFromEnum(main_tokens[i])],
                .end = eo,
            };
            skip_count += 1;
        }
    }

    for (tags, 0..) |tag, i| {
        if (tag != .identifier) continue;
        const tok = main_tokens[i];
        const tok_text = ctx.tokenSlice(tok);
        if (!std.mem.eql(u8, tok_text, name)) continue;

        const id_pos = tok_starts[@intFromEnum(tok)];

        // Skip identifiers inside import-equals or removed declarations
        var in_skip = false;
        for (skip_ranges[0..skip_count]) |r| {
            if (id_pos >= r.start and id_pos < r.end) {
                in_skip = true;
                break;
            }
        }
        if (in_skip) continue;

        // Skip synthetic nodes (end_offset = 0)
        const end_off = end_offsets[i];
        if (end_off == 0) continue;

        // Check if this identifier is inside a type context
        if (isPositionInTypeContext(ctx, id_pos)) continue;

        return false; // Found a value usage
    }
    return true; // No value usage found
}

/// Check if a source position is inside a type annotation context.
/// Uses a heuristic: scan backward from the position for type annotation markers.
fn isPositionInTypeContext(ctx: *TransformContext, pos: u32) bool {
    // Check if this position is inside a type annotation node.
    // Simple approach: check all ts_type_annotation nodes and see if pos is within their range.
    const tags = ctx.ast.nodes.items(.tag);
    const main_tokens = ctx.ast.nodes.items(.main_token);
    const end_offsets = ctx.ast.nodes.items(.end_offset);
    const tok_starts = ctx.ast.tokens.items(.start);

    for (tags, 0..) |tag, i| {
        switch (tag) {
            .ts_type_annotation,
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_type_parameter_declaration,
            .ts_type_parameter_instantiation,
            => {
                const node_start = tok_starts[@intFromEnum(main_tokens[i])];
                const node_end = end_offsets[i];
                if (pos >= node_start and pos < node_end) return true;
            },
            else => {},
        }
    }
    return false;
}

fn handleExportAll(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);

    // Check the is_type_export flag (4th extra element, index +3)
    const is_type_export = if (extra_idx + 3 < ctx.ast.extra_data.items.len)
        ctx.ast.extra_data.items[extra_idx + 3] != 0
    else
        false;

    if (is_type_export) {
        // `export type * from 'source'` → remove entirely
        ctx.needs_module_marker = true;
        return .remove_node;
    }

    return .continue_traversal;
}

// ────────────────────────────────────────────────────────────────────────
// Enum → IIFE transform
// ────────────────────────────────────────────────────────────────────────

/// Value of an enum member after evaluation.
const EnumValue = struct {
    kind: Kind,
    /// Whether this value is syntactically determinable (no side effects).
    /// Used for /*#__PURE__*/ annotation.
    is_pure: bool = true,

    const Kind = union(enum) {
        number: f64,
        string: []const u8,
        /// Expression that couldn't be folded — store the source text
        expr: []const u8,
        /// Expression that is syntactically string-like (template/concat)
        string_expr: []const u8,
    };

    fn number(n: f64) EnumValue {
        return .{ .kind = .{ .number = n }, .is_pure = true };
    }
    fn string(s: []const u8) EnumValue {
        return .{ .kind = .{ .string = s }, .is_pure = true };
    }
    fn expr(s: []const u8) EnumValue {
        return .{ .kind = .{ .expr = s }, .is_pure = false };
    }
    fn pureExpr(s: []const u8) EnumValue {
        return .{ .kind = .{ .expr = s }, .is_pure = true };
    }
    fn stringExpr(s: []const u8) EnumValue {
        return .{ .kind = .{ .string_expr = s }, .is_pure = false };
    }
};

/// Information about a previously-resolved enum member.
const MemberInfo = struct {
    name: []const u8,
    value: EnumValue,
    /// Whether this member's value was non-foldable (its `expr` must use Foo.name references)
    non_foldable: bool = false,
    /// The original node index (for extracting leading comments)
    node: NodeIndex = .none,
};

fn handleEnumDeclaration(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);

    // Layout: extra[0]=name_node, extra[1]=members_start, extra[2]=members_end, extra[3]=is_const
    const name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const members_start = ctx.ast.extra_data.items[extra_idx + 1];
    const members_end = ctx.ast.extra_data.items[extra_idx + 2];
    const is_const = extra_idx + 3 < ctx.ast.extra_data.items.len and ctx.ast.extra_data.items[extra_idx + 3] != 0;

    // Get enum name text from the identifier node
    const name_token = ctx.mainToken(name_node);
    const enum_name = ctx.tokenSlice(name_token);

    if (g_config.optimize_const_enums and is_const) {
        handleOptimizedConstEnumDeclaration(idx, ctx, enum_name, members_start, members_end);
        return;
    }

    // Check if this is the first occurrence or a merge
    const is_first = !ctx.seen_enum_names.contains(enum_name);
    ctx.seen_enum_names.put(ctx.allocator, enum_name, {}) catch {};

    // Check if exported
    const is_exported = ctx.exported_nodes.contains(@intFromEnum(idx));

    // Check if block-scoped (not at program level)
    const is_block_scoped = !isInProgramBody(ctx, idx);

    // Compute indentation for the IIFE body.
    // The codegen writes `writeIndent()` before emitting the replacement text,
    // adding `indent_level * 2` spaces. Lines within the replacement text after \n
    // need ABSOLUTE indentation (from column 0).
    // Estimate the codegen's indent_level from the source nesting depth.
    const nesting_depth: usize = if (is_block_scoped) estimateBlockDepth(ctx, idx) else 0;
    const base_indent_len = nesting_depth * 2;
    const body_indent_len = base_indent_len + 2;
    const base_indent = blk: {
        if (base_indent_len == 0) break :blk "";
        const s = ctx.allocator.alloc(u8, base_indent_len) catch break :blk "";
        @memset(s, ' ');
        break :blk s;
    };
    const body_indent = blk: {
        const s = ctx.allocator.alloc(u8, body_indent_len) catch break :blk "  ";
        @memset(s, ' ');
        break :blk s;
    };

    // Build the IIFE string
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    // Write the prefix: `var E = `, `let E = `, or just `E = `
    if (is_first) {
        if (is_block_scoped) {
            buf.appendSlice(ctx.allocator, "let ") catch return;
        } else if (is_exported) {
            buf.appendSlice(ctx.allocator, "let ") catch return;
        } else {
            buf.appendSlice(ctx.allocator, "var ") catch return;
        }
        buf.appendSlice(ctx.allocator, enum_name) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
    } else {
        // Merging declaration — just assignment, no var/let
        buf.appendSlice(ctx.allocator, enum_name) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
    }

    // Generate the IIFE body
    // For first exported or block-scoped, use `{}` as argument; for others, use `E || {}`
    const use_empty_arg = is_first and (is_exported or is_block_scoped);
    generateEnumIife(ctx, enum_name, members_start, members_end, &buf, use_empty_arg, body_indent, base_indent) catch return;

    // Add semicolon
    buf.append(ctx.allocator, ';') catch return;

    // Store the replacement in the AST side table
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), buf.items) catch return;
}

fn handleOptimizedConstEnumDeclaration(
    idx: NodeIndex,
    ctx: *TransformContext,
    enum_name: []const u8,
    members_start: u32,
    members_end: u32,
) void {
    const is_first = !ctx.seen_enum_names.contains(enum_name);
    ctx.seen_enum_names.put(ctx.allocator, enum_name, {}) catch {};

    const keep_runtime_object = shouldKeepConstEnumRuntimeObject(ctx, idx, enum_name);
    const member_infos = collectEnumMemberInfos(ctx, members_start, members_end, enum_name) catch return;
    storeResolvedEnumMemberValues(ctx, enum_name, member_infos.items);

    if (!keep_runtime_object) {
        if (ctx.ast.source_type == .module and isConstEnumTypeExported(ctx, enum_name)) {
            ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), "export {};") catch {};
            return;
        }
        ctx.ast.nodes.items(.tag)[@intFromEnum(idx)] = .removed;
        return;
    }

    ctx.runtime_const_enums.put(ctx.allocator, enum_name, {}) catch {};

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const exported_decl = ctx.exported_nodes.contains(@intFromEnum(idx));

    if (is_first) {
        _ = exported_decl;
        buf.appendSlice(ctx.allocator, "const ") catch return;
        buf.appendSlice(ctx.allocator, enum_name) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        generateConstEnumObjectLiteral(ctx, member_infos.items, &buf, "") catch return;
        buf.appendSlice(ctx.allocator, ";") catch return;
    } else {
        buf.appendSlice(ctx.allocator, "Object.assign(") catch return;
        buf.appendSlice(ctx.allocator, enum_name) catch return;
        buf.appendSlice(ctx.allocator, ", ") catch return;
        generateConstEnumObjectLiteral(ctx, member_infos.items, &buf, "") catch return;
        buf.appendSlice(ctx.allocator, ");") catch return;
    }

    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), buf.items) catch return;
}

fn shouldKeepConstEnumRuntimeObject(ctx: *TransformContext, idx: NodeIndex, enum_name: []const u8) bool {
    if (hasDeclareKeywordInNodeSource(ctx, idx)) return false;
    if (!isInProgramBody(ctx, idx)) return false;
    if (ctx.exported_nodes.contains(@intFromEnum(idx))) return true;
    return isConstEnumValueExported(ctx, enum_name);
}

fn hasDeclareKeywordInNodeSource(ctx: *TransformContext, idx: NodeIndex) bool {
    const src = getNodeSourceText(ctx, idx);
    return std.mem.indexOf(u8, src, "declare") != null;
}

fn generateEnumIife(
    ctx: *TransformContext,
    enum_name: []const u8,
    members_start: u32,
    members_end: u32,
    buf: *std.ArrayListUnmanaged(u8),
    use_empty_arg: bool,
    indent: []const u8,
    closing_indent: []const u8,
) !void {
    const member_infos = try collectEnumMemberInfos(ctx, members_start, members_end, enum_name);
    storeResolvedEnumMemberValues(ctx, enum_name, member_infos.items);

    var all_pure = true;
    for (member_infos.items) |info| {
        if (!info.value.is_pure) {
            all_pure = false;
            break;
        }
    }

    // Generate the pure annotation if applicable
    const pure_annotation = if (all_pure) "/*#__PURE__*/" else "";

    // Write the IIFE
    try buf.appendSlice(ctx.allocator, pure_annotation);
    try buf.appendSlice(ctx.allocator, "function (");
    try buf.appendSlice(ctx.allocator, enum_name);
    try buf.appendSlice(ctx.allocator, ") {\n");

    // Emit each member assignment, preserving leading comments
    var prev_member_end: u32 = 0; // Track end of previous member for comment extraction
    for (member_infos.items, 0..) |info, mi| {
        // Extract and emit leading comments from between the previous member and this one
        if (info.node != .none) {
            const member_tok = ctx.mainToken(info.node);
            const member_start = ctx.ast.tokens.items(.start)[@intFromEnum(member_tok)];
            if (mi > 0 and prev_member_end > 0 and member_start > prev_member_end) {
                // Scan the gap between prev member end and this member start for comments
                const gap = ctx.ast.source[prev_member_end..member_start];
                try emitGapCommentsTracked(ctx, buf, ctx.allocator, gap, indent, prev_member_end);
            }
            // Update prev_member_end to end of this member's source range
            prev_member_end = getNodeSourceEnd(ctx, info.node);
        }
        try buf.appendSlice(ctx.allocator, indent);
        switch (info.value.kind) {
            .number => |n| {
                // Numeric: E[E["name"] = value] = "name";
                try buf.appendSlice(ctx.allocator, enum_name);
                try buf.appendSlice(ctx.allocator, "[");
                try buf.appendSlice(ctx.allocator, enum_name);
                try buf.appendSlice(ctx.allocator, "[\"");
                try buf.appendSlice(ctx.allocator, info.name);
                try buf.appendSlice(ctx.allocator, "\"] = ");
                try appendNumber(buf, ctx.allocator, n);
                try buf.appendSlice(ctx.allocator, "] = \"");
                try buf.appendSlice(ctx.allocator, info.name);
                try buf.appendSlice(ctx.allocator, "\";\n");
            },
            .string => |s| {
                // String: E["name"] = "value";
                try buf.appendSlice(ctx.allocator, enum_name);
                try buf.appendSlice(ctx.allocator, "[\"");
                try buf.appendSlice(ctx.allocator, info.name);
                try buf.appendSlice(ctx.allocator, "\"] = ");
                try buf.appendSlice(ctx.allocator, s);
                try buf.appendSlice(ctx.allocator, ";\n");
            },
            .expr => |e| {
                // Non-foldable numeric: E[E["name"] = expr] = "name";
                try buf.appendSlice(ctx.allocator, enum_name);
                try buf.appendSlice(ctx.allocator, "[");
                try buf.appendSlice(ctx.allocator, enum_name);
                try buf.appendSlice(ctx.allocator, "[\"");
                try buf.appendSlice(ctx.allocator, info.name);
                try buf.appendSlice(ctx.allocator, "\"] = ");
                try appendInlineExprWithIndent(ctx.allocator, buf, e, indent);
                try buf.appendSlice(ctx.allocator, "] = \"");
                try buf.appendSlice(ctx.allocator, info.name);
                try buf.appendSlice(ctx.allocator, "\";\n");
            },
            .string_expr => |e| {
                // Non-foldable string: E["name"] = expr;
                try buf.appendSlice(ctx.allocator, enum_name);
                try buf.appendSlice(ctx.allocator, "[\"");
                try buf.appendSlice(ctx.allocator, info.name);
                try buf.appendSlice(ctx.allocator, "\"] = ");
                try appendInlineExprWithIndent(ctx.allocator, buf, e, indent);
                try buf.appendSlice(ctx.allocator, ";\n");
            },
        }
    }

    // Handle trailing comment on the last member (emitted inline on same line)
    if (member_infos.items.len > 0 and prev_member_end > 0) {
        const last_info = member_infos.items[member_infos.items.len - 1];
        if (last_info.node != .none) {
            // Look for a trailing line comment on the same line as the last member
            const end_pos = prev_member_end;
            if (end_pos < ctx.ast.source.len) {
                var scan = end_pos;
                // Skip comma and whitespace on the same line
                while (scan < ctx.ast.source.len and ctx.ast.source[scan] != '\n') {
                    if (ctx.ast.source[scan] == '/' and scan + 1 < ctx.ast.source.len) {
                        if (ctx.ast.source[scan + 1] == '/') {
                            // Found a trailing line comment — emit it inline
                            // First, remove the trailing \n from the last member line
                            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
                                buf.items.len -= 1;
                            }
                            // Emit the comment inline
                            var comment_end = scan;
                            while (comment_end < ctx.ast.source.len and ctx.ast.source[comment_end] != '\n') {
                                comment_end += 1;
                            }
                            try buf.appendSlice(ctx.allocator, " ");
                            try buf.appendSlice(ctx.allocator, ctx.ast.source[scan..comment_end]);
                            try buf.appendSlice(ctx.allocator, "\n");
                            // Mark as consumed
                            ctx.ast.consumed_comments.put(ctx.allocator, scan, {}) catch {};
                            break;
                        } else if (ctx.ast.source[scan + 1] == '*') {
                            // Block comment — could also handle but skip for now
                            break;
                        }
                    }
                    scan += 1;
                }
            }
        }
    }

    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "return ");
    try buf.appendSlice(ctx.allocator, enum_name);
    try buf.appendSlice(ctx.allocator, ";\n");
    try buf.appendSlice(ctx.allocator, closing_indent);
    try buf.appendSlice(ctx.allocator, "}(");
    if (use_empty_arg) {
        try buf.appendSlice(ctx.allocator, "{})");
    } else {
        try buf.appendSlice(ctx.allocator, enum_name);
        try buf.appendSlice(ctx.allocator, " || {})");
    }
}

fn generateConstEnumObjectLiteral(
    ctx: *TransformContext,
    member_infos: []const MemberInfo,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
) !void {
    try buf.appendSlice(ctx.allocator, "{");
    if (member_infos.len == 0) {
        try buf.appendSlice(ctx.allocator, "}");
        return;
    }
    try buf.appendSlice(ctx.allocator, "\n");
    const member_indent = std.fmt.allocPrint(ctx.allocator, "{s}  ", .{indent}) catch "  ";
    for (member_infos, 0..) |info, i| {
        try buf.appendSlice(ctx.allocator, member_indent);
        try buf.appendSlice(ctx.allocator, info.name);
        try buf.appendSlice(ctx.allocator, ": ");
        try appendEnumValueSource(ctx, buf, info.value, member_indent);
        if (i + 1 < member_infos.len) {
            try buf.appendSlice(ctx.allocator, ",");
        }
        try buf.appendSlice(ctx.allocator, "\n");
    }
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "}");
}

fn appendEnumValueSource(
    ctx: *TransformContext,
    buf: *std.ArrayListUnmanaged(u8),
    value: EnumValue,
    indent: []const u8,
) !void {
    switch (value.kind) {
        .number => |n| try appendNumber(buf, ctx.allocator, n),
        .string => |s| try buf.appendSlice(ctx.allocator, s),
        .expr => |e| try appendInlineExprWithIndent(ctx.allocator, buf, e, indent),
        .string_expr => |e| try appendInlineExprWithIndent(ctx.allocator, buf, e, indent),
    }
}

fn collectEnumMemberInfos(
    ctx: *TransformContext,
    members_start: u32,
    members_end: u32,
    enum_name: []const u8,
) !std.ArrayListUnmanaged(MemberInfo) {
    const num_members = members_end - members_start;
    var member_infos: std.ArrayListUnmanaged(MemberInfo) = .empty;
    try member_infos.ensureTotalCapacity(ctx.allocator, num_members);

    var auto_counter: f64 = 0;
    var prev_was_nonfoldable = false;

    for (ctx.ast.extra_data.items[members_start..members_end]) |member_raw| {
        const member_idx: NodeIndex = @enumFromInt(member_raw);
        const member_main_token = ctx.mainToken(member_idx);
        const member_name = getMemberNameText(ctx, member_main_token);
        const member_data = ctx.nodeData(member_idx);
        const init_node = member_data.unary;

        if (init_node == .none) {
            if (prev_was_nonfoldable and member_infos.items.len > 0) {
                const prev_name = member_infos.items[member_infos.items.len - 1].name;
                const expr_text = std.fmt.allocPrint(ctx.allocator, "1 + {s}[\"{s}\"]", .{ enum_name, prev_name }) catch continue;
                member_infos.appendAssumeCapacity(.{
                    .name = member_name,
                    .value = EnumValue.expr(expr_text),
                    .non_foldable = true,
                    .node = member_idx,
                });
                prev_was_nonfoldable = true;
            } else {
                member_infos.appendAssumeCapacity(.{
                    .name = member_name,
                    .value = EnumValue.number(auto_counter),
                    .node = member_idx,
                });
                auto_counter += 1;
                prev_was_nonfoldable = false;
            }
        } else {
            const value = evaluateEnumInit(ctx, init_node, member_infos.items, enum_name);
            const is_nonfoldable = switch (value.kind) {
                .expr, .string_expr => true,
                else => false,
            };

            member_infos.appendAssumeCapacity(.{
                .name = member_name,
                .value = value,
                .non_foldable = is_nonfoldable,
                .node = member_idx,
            });

            switch (value.kind) {
                .number => |n| {
                    auto_counter = n + 1;
                    prev_was_nonfoldable = false;
                },
                .expr => prev_was_nonfoldable = true,
                else => prev_was_nonfoldable = false,
            }
        }
    }

    return member_infos;
}

fn storeResolvedEnumMemberValues(
    ctx: *TransformContext,
    enum_name: []const u8,
    member_infos: []const MemberInfo,
) void {
    for (member_infos) |info| {
        const key = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ enum_name, info.name }) catch continue;
        switch (info.value.kind) {
            .number => |n| {
                ctx.enum_member_values.put(ctx.allocator, key, .{ .kind = .{ .number = n }, .is_pure = info.value.is_pure }) catch {};
            },
            .string => |s| {
                ctx.enum_member_values.put(ctx.allocator, key, .{ .kind = .{ .string = s }, .is_pure = info.value.is_pure }) catch {};
            },
            else => {},
        }
    }
}

/// Get the text of a member name token, stripping quotes if it's a string.
fn getMemberNameText(ctx: *TransformContext, token: TokenIndex) []const u8 {
    const text = ctx.tokenSlice(token);
    // If it's a string literal like "y", strip the quotes
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
        return text[1 .. text.len - 1];
    }
    return text;
}

/// Estimate the block nesting depth of a node by scanning the source for `{` and `}` before it.
/// This gives us the codegen's indent_level at the point where the replacement text is emitted.
fn estimateBlockDepth(ctx: *TransformContext, idx: NodeIndex) usize {
    const tok = ctx.mainToken(idx);
    const tok_start = ctx.ast.tokens.items(.start)[@intFromEnum(tok)];
    const source = ctx.ast.source;

    var depth: usize = 0;
    var i: usize = 0;
    while (i < tok_start) {
        if (source[i] == '{') {
            depth += 1;
        } else if (source[i] == '}') {
            if (depth > 0) depth -= 1;
        } else if (source[i] == '\'' or source[i] == '"' or source[i] == '`') {
            // Skip string literals
            const quote = source[i];
            i += 1;
            while (i < tok_start and source[i] != quote) {
                if (source[i] == '\\' and i + 1 < tok_start) i += 1;
                i += 1;
            }
        } else if (source[i] == '/' and i + 1 < tok_start) {
            if (source[i + 1] == '/') {
                // Skip line comment
                while (i < tok_start and source[i] != '\n') i += 1;
            } else if (source[i + 1] == '*') {
                // Skip block comment
                i += 2;
                while (i + 1 < tok_start) {
                    if (source[i] == '*' and source[i + 1] == '/') {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            }
        }
        i += 1;
    }
    return depth;
}

/// Format a number like Babel does (integer or float).
fn appendNumber(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: f64) !void {
    // Check if it's a safe integer
    if (n == @trunc(n) and @abs(n) < 9007199254740992.0) {
        const i: i64 = @intFromFloat(n);
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch "0";
        try buf.appendSlice(allocator, s);
    } else {
        // Float formatting
        var tmp: [64]u8 = undefined;
        // Use a format that matches JavaScript's number representation
        const s = formatJsFloat(&tmp, n);
        try buf.appendSlice(allocator, s);
    }
}

/// Format a float to match JavaScript's default toString() for common cases.
fn formatJsFloat(buf: *[64]u8, n: f64) []const u8 {
    // For NaN and Infinity
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) {
        return if (n > 0) "Infinity" else "-Infinity";
    }

    // Try integer first
    if (n == @trunc(n) and @abs(n) < 9007199254740992.0) {
        const i: i64 = @intFromFloat(n);
        const s = std.fmt.bufPrint(buf, "{d}", .{i}) catch return "0";
        return s;
    }

    // Use decimal format with enough precision
    const s = std.fmt.bufPrint(buf, "{d}", .{n}) catch return "0";
    return s;
}

/// Evaluate an enum member initializer expression, returning the resolved value.
/// `prev_members` contains already-resolved members for inner references.
fn evaluateEnumInit(
    ctx: *TransformContext,
    node: NodeIndex,
    prev_members: []const MemberInfo,
    enum_name: []const u8,
) EnumValue {
    if (node == .none) return EnumValue.number(0);

    const tag = ctx.nodeTag(node);
    const node_data = ctx.nodeData(node);

    switch (tag) {
        .numeric_literal => {
            const tok = ctx.mainToken(node);
            const text = ctx.tokenSlice(tok);
            const val = std.fmt.parseFloat(f64, text) catch return EnumValue.pureExpr(text);
            return EnumValue.number(val);
        },
        .string_literal => {
            const tok = ctx.mainToken(node);
            const text = ctx.tokenSlice(tok);
            return EnumValue.string(text);
        },
        .boolean_literal => {
            const tok = ctx.mainToken(node);
            const text = ctx.tokenSlice(tok);
            // Boolean literals are syntactically pure (get reverse mapping like numbers)
            return EnumValue.pureExpr(text);
        },
        .template_literal => {
            // Check if it's a no-substitution template
            const tok = ctx.mainToken(node);
            const tok_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(tok)];
            if (tok_tag == .template_no_sub) {
                const text = ctx.tokenSlice(tok);
                // Convert `text` to "text" — strip backticks and replace with quotes
                if (text.len >= 2) {
                    const inner = text[1 .. text.len - 1];
                    const quoted = std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{inner}) catch
                        return stringExprFromNode(ctx, node);
                    return EnumValue.string(quoted);
                }
            }
            return evaluateTemplateLiteral(ctx, node, prev_members, enum_name);
        },
        .unary_expr => {
            const op_tok = ctx.mainToken(node);
            const op_text = ctx.tokenSlice(op_tok);
            const operand = node_data.unary;
            const inner = evaluateEnumInit(ctx, operand, prev_members, enum_name);
            switch (inner.kind) {
                .number => |n| {
                    if (std.mem.eql(u8, op_text, "+")) return EnumValue.number(n);
                    if (std.mem.eql(u8, op_text, "-")) return EnumValue.number(-n);
                    if (std.mem.eql(u8, op_text, "~")) {
                        const i: i64 = @intFromFloat(n);
                        return EnumValue.number(@floatFromInt(~i));
                    }
                    return exprFromNode(ctx, node, prev_members, enum_name);
                },
                else => return exprFromNode(ctx, node, prev_members, enum_name),
            }
        },
        .binary_expr, .logical_expr => {
            const lhs = node_data.binary.lhs;
            const rhs = node_data.binary.rhs;
            const op_tok = ctx.mainToken(node);
            const op_text = ctx.tokenSlice(op_tok);

            const left = evaluateEnumInit(ctx, lhs, prev_members, enum_name);
            const right = evaluateEnumInit(ctx, rhs, prev_members, enum_name);

            // String concatenation: "a" + "b" => "ab"
            if (std.mem.eql(u8, op_text, "+")) {
                switch (left.kind) {
                    .string => |ls| {
                        switch (right.kind) {
                            .string => |rs| {
                                const l_inner = if (ls.len >= 2 and ls[0] == '"') ls[1 .. ls.len - 1] else ls;
                                const r_inner = if (rs.len >= 2 and rs[0] == '"') rs[1 .. rs.len - 1] else rs;
                                const result = std.fmt.allocPrint(ctx.allocator, "\"{s}{s}\"", .{ l_inner, r_inner }) catch
                                    return exprFromNode(ctx, node, prev_members, enum_name);
                                return EnumValue.string(result);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
                // If left is a string, result is string (even if right isn't foldable)
                switch (left.kind) {
                    .string => return stringExprFromNode(ctx, node),
                    else => {},
                }
            }

            // Numeric operations
            switch (left.kind) {
                .number => |ln| {
                    switch (right.kind) {
                        .number => |rn| {
                            const result = evalBinaryNumeric(op_text, ln, rn);
                            if (result) |r| return EnumValue.number(r);
                        },
                        else => {},
                    }
                },
                else => {},
            }

            return exprFromNode(ctx, node, prev_members, enum_name);
        },
        .identifier => {
            const tok = ctx.mainToken(node);
            const text = ctx.tokenSlice(tok);

            // Check if it refers to a previous enum member (same enum declaration)
            for (prev_members) |m| {
                if (std.mem.eql(u8, m.name, text)) {
                    // If the referenced member was non-foldable, use Foo.name instead
                    if (m.non_foldable) {
                        const ref_text = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ enum_name, m.name }) catch return EnumValue.expr(text);
                        return EnumValue.expr(ref_text);
                    }
                    return m.value;
                }
            }

            // Check cross-enum resolution: for merging enums, look up EnumName.identifier
            // in the global map (e.g., `Cat` inside `enum Animals` → `Animals.Cat`)
            const cross_key = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ enum_name, text }) catch
                return EnumValue.pureExpr(text);
            if (ctx.enum_member_values.get(cross_key)) |resolved| {
                switch (resolved.kind) {
                    .number => |n| return EnumValue.number(n),
                    .string => |s| return EnumValue.string(s),
                }
            }

            // Handle special global constants (Infinity, NaN) —
            // Babel treats these as foldable even when shadowed by local variables.
            if (std.mem.eql(u8, text, "Infinity")) return EnumValue.number(std.math.inf(f64));
            if (std.mem.eql(u8, text, "NaN")) return EnumValue.number(std.math.nan(f64));

            // Try to resolve outer constant (const x = 10)
            scanOuterConstants(ctx);
            if (ctx.outer_const_values.get(text)) |resolved| {
                switch (resolved.kind) {
                    .number => |n| return EnumValue.number(n),
                    .string => |s| return EnumValue.string(s),
                }
            }

            if (lookupTopLevelConstValue(ctx, text, 0)) |resolved| {
                ctx.outer_const_values.put(ctx.allocator, text, resolved) catch {};
                switch (resolved.kind) {
                    .number => |n| return EnumValue.number(n),
                    .string => |s| return EnumValue.string(s),
                }
            }

            // Otherwise it's an outer reference — emit as-is
            // Identifier references are syntactically pure (no side effects)
            return EnumValue.pureExpr(text);
        },
        .member_expr => {
            // E.g., Foo.a — try to resolve cross-enum reference first
            const source_text = getNodeSourceText(ctx, node);
            // Try to look up in the global enum member values map
            if (ctx.enum_member_values.get(source_text)) |resolved| {
                switch (resolved.kind) {
                    .number => |n| return EnumValue.number(n),
                    .string => |s| return EnumValue.string(s),
                }
            }
            // Unresolved member access — not pure (could have side effects)
            return EnumValue.expr(source_text);
        },
        .parenthesized_expr => {
            // Unwrap
            const inner = node_data.unary;
            return evaluateEnumInit(ctx, inner, prev_members, enum_name);
        },
        .ts_as_expression, .ts_satisfies_expression => {
            // Strip type cast
            return evaluateEnumInit(ctx, node_data.binary.lhs, prev_members, enum_name);
        },
        .ts_non_null_expression => {
            // Strip non-null assertion
            return evaluateEnumInit(ctx, node_data.unary, prev_members, enum_name);
        },
        else => {
            return exprFromNode(ctx, node, prev_members, enum_name);
        },
    }
}

/// Extract source text for an expression node, with inner reference rewriting.
/// Rewrites bare identifiers that match non-foldable enum members to `EnumName.member`.
fn exprFromNode(ctx: *TransformContext, node: NodeIndex, prev_members: []const MemberInfo, enum_name: []const u8) EnumValue {
    const source_text = getNodeGeneratedSource(ctx, node);

    // Check if any member names appear in the source text and need rewriting
    var needs_rewrite = false;
    for (prev_members) |m| {
        if (std.mem.indexOf(u8, source_text, m.name) != null) {
            needs_rewrite = true;
            break;
        }
    }
    if (!needs_rewrite) {
        return EnumValue.expr(source_text);
    }

    // Do identifier-level replacement in the source text
    const rewritten = rewriteEnumMemberRefs(ctx.allocator, source_text, prev_members, enum_name) catch
        return EnumValue.expr(source_text);
    return EnumValue.expr(rewritten);
}

/// Rewrite identifiers in source text that match enum member names.
/// Only replaces identifiers at word boundaries (not inside strings or other identifiers).
fn rewriteEnumMemberRefs(
    allocator: std.mem.Allocator,
    source: []const u8,
    prev_members: []const MemberInfo,
    enum_name: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        // Skip string literals
        if (source[i] == '\'' or source[i] == '"' or source[i] == '`') {
            const quote = source[i];
            try buf.append(allocator, source[i]);
            i += 1;
            while (i < source.len and source[i] != quote) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    try buf.append(allocator, source[i]);
                    i += 1;
                }
                try buf.append(allocator, source[i]);
                i += 1;
            }
            if (i < source.len) {
                try buf.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        // Check for identifier at word boundary
        if (isIdentStart(source[i])) {
            const ident_start = i;
            while (i < source.len and isIdentContinue(source[i])) {
                i += 1;
            }
            const ident = source[ident_start..i];

            // Check if preceded by a dot (member access — don't rewrite)
            const preceded_by_dot = ident_start > 0 and source[ident_start - 1] == '.';

            // Check if this is a declaration keyword usage (const A, let A, var A — don't rewrite)
            const is_declaration = isDeclarationContext(source, ident_start);

            if (!preceded_by_dot and !is_declaration) {
                // Check if this identifier is inside a scope that shadows the name
                // by looking for a declaration of the same name before this position
                const is_shadowed = isShadowedInSource(source, ident, ident_start);

                if (!is_shadowed) {
                    // Check if this identifier matches any non-foldable enum member
                    var found = false;
                    for (prev_members) |m| {
                        if (std.mem.eql(u8, ident, m.name)) {
                            // Rewrite: name → EnumName.name
                            try buf.appendSlice(allocator, enum_name);
                            try buf.append(allocator, '.');
                            try buf.appendSlice(allocator, ident);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try buf.appendSlice(allocator, ident);
                    }
                } else {
                    try buf.appendSlice(allocator, ident);
                }
            } else {
                try buf.appendSlice(allocator, ident);
            }
            continue;
        }

        try buf.append(allocator, source[i]);
        i += 1;
    }
    return buf.items;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Check if an identifier at position `pos` is in a declaration context
/// (preceded by const/let/var keyword).
fn isDeclarationContext(source: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    // Walk backwards past whitespace
    var p = pos;
    while (p > 0 and (source[p - 1] == ' ' or source[p - 1] == '\t' or source[p - 1] == '\n')) {
        p -= 1;
    }
    // Check for const/let/var keywords before this position
    if (p >= 5 and std.mem.eql(u8, source[p - 5 .. p], "const")) {
        if (p == 5 or !isIdentContinue(source[p - 6])) return true;
    }
    if (p >= 3 and std.mem.eql(u8, source[p - 3 .. p], "let")) {
        if (p == 3 or !isIdentContinue(source[p - 4])) return true;
    }
    if (p >= 3 and std.mem.eql(u8, source[p - 3 .. p], "var")) {
        if (p == 3 or !isIdentContinue(source[p - 4])) return true;
    }
    return false;
}

/// Check if an identifier is shadowed by a local declaration in the same scope.
/// Looks for `const name`, `let name`, or `var name` patterns earlier in the source
/// within the same enclosing scope (tracked by brace depth).
fn isShadowedInSource(source: []const u8, name: []const u8, pos: usize) bool {
    // Find the innermost enclosing scope (arrow function or block)
    // by looking for `{` that opens the scope containing pos
    var scope_start: usize = 0;
    var j: usize = 0;
    while (j < pos) {
        if (source[j] == '{') {
            scope_start = j;
        }
        j += 1;
    }

    // Search for `const name` / `let name` / `var name` between scope_start and pos
    const search_region = source[scope_start..pos];
    const keywords = [_][]const u8{ "const ", "let ", "var " };
    for (keywords) |kw| {
        var search_pos: usize = 0;
        while (std.mem.indexOfPos(u8, search_region, search_pos, kw)) |idx| {
            const name_start = idx + kw.len;
            if (name_start + name.len <= search_region.len) {
                if (std.mem.eql(u8, search_region[name_start .. name_start + name.len], name)) {
                    // Check word boundary after the name
                    if (name_start + name.len >= search_region.len or
                        !isIdentContinue(search_region[name_start + name.len]))
                    {
                        return true;
                    }
                }
            }
            search_pos = idx + 1;
        }
    }
    return false;
}

/// Extract source text for an expression that is known to be string-typed.
fn stringExprFromNode(ctx: *TransformContext, node: NodeIndex) EnumValue {
    const source_text = getNodeGeneratedSource(ctx, node);
    return EnumValue.stringExpr(source_text);
}

fn evaluateTemplateLiteral(
    ctx: *TransformContext,
    node: NodeIndex,
    prev_members: []const MemberInfo,
    enum_name: []const u8,
) EnumValue {
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx >= ctx.ast.extra_data.items.len) return stringExprFromNode(ctx, node);

    const num_expressions = ctx.ast.extra_data.items[extra_idx];
    const exprs_start = extra_idx + 1;
    const tokens_start = exprs_start + num_expressions;
    if (tokens_start + num_expressions >= ctx.ast.extra_data.items.len) {
        return stringExprFromNode(ctx, node);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (0..num_expressions + 1) |part_idx| {
        const tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[tokens_start + part_idx]);
        const tok_text = ctx.tokenSlice(tok);
        const segment = switch (ctx.ast.tokens.items(.tag)[@intFromEnum(tok)]) {
            .template_head => if (tok_text.len >= 3) tok_text[1 .. tok_text.len - 2] else "",
            .template_middle => if (tok_text.len >= 3) tok_text[1 .. tok_text.len - 2] else "",
            .template_tail => if (tok_text.len >= 2) tok_text[1 .. tok_text.len - 1] else "",
            .template_no_sub => if (tok_text.len >= 2) tok_text[1 .. tok_text.len - 1] else "",
            else => "",
        };
        buf.appendSlice(ctx.allocator, segment) catch return stringExprFromNode(ctx, node);

        if (part_idx == num_expressions) break;

        const expr_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[exprs_start + part_idx]);
        const value = evaluateEnumInit(ctx, expr_node, prev_members, enum_name);
        switch (value.kind) {
            .number => |n| appendNumberString(&buf, ctx.allocator, n) catch return stringExprFromNode(ctx, node),
            .string => |s| buf.appendSlice(ctx.allocator, stripQuotedString(s)) catch return stringExprFromNode(ctx, node),
            else => return stringExprFromNode(ctx, node),
        }
    }

    const escaped = escapeJsString(ctx.allocator, buf.items) catch return stringExprFromNode(ctx, node);
    const quoted = std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{escaped}) catch return stringExprFromNode(ctx, node);
    return EnumValue.string(quoted);
}

fn appendNumberString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: f64) !void {
    if (n == @trunc(n) and @abs(n) < 9007199254740992.0) {
        const i: i64 = @intFromFloat(n);
        var tmp: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{i});
        try buf.appendSlice(allocator, s);
        return;
    }
    var tmp: [64]u8 = undefined;
    const s = formatJsFloat(&tmp, n);
    try buf.appendSlice(allocator, s);
}

fn stripQuotedString(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'')) return s[1 .. s.len - 1];
    return s;
}

fn escapeJsString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    return buf.items;
}

/// Get the original source text for a node, using token positions.
/// For nodes where main_token is not the leftmost token (e.g., call_expr
/// where main_token is '('), walk to the leftmost child to find the true start.
/// Get the end byte position of a node.
fn getNodeSourceEnd(ctx: *TransformContext, node: NodeIndex) u32 {
    const i = @intFromEnum(node);
    return ctx.ast.nodes.items(.end_offset)[i];
}

/// Scan a source gap between enum members for comments and emit them.
fn emitGapComments(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, gap: []const u8, indent: []const u8) !void {
    emitGapCommentsImpl(buf, alloc, gap, indent, null, 0) catch {};
}

fn emitGapCommentsTracked(ctx: *TransformContext, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, gap: []const u8, indent: []const u8, abs_offset: u32) !void {
    try emitGapCommentsImpl(buf, alloc, gap, indent, ctx, abs_offset);
}

fn emitGapCommentsImpl(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, gap: []const u8, indent: []const u8, ctx: ?*TransformContext, abs_offset: u32) !void {
    var i: usize = 0;
    while (i < gap.len) {
        if (gap[i] == '/' and i + 1 < gap.len) {
            if (gap[i + 1] == '/') {
                // Line comment
                const start = i;
                while (i < gap.len and gap[i] != '\n') i += 1;
                try buf.appendSlice(alloc, indent);
                try buf.appendSlice(alloc, gap[start..i]);
                try buf.append(alloc, '\n');
                if (i < gap.len) i += 1; // skip \n
                // Mark as consumed to prevent codegen duplication
                if (ctx) |c| {
                    c.ast.consumed_comments.put(c.allocator, abs_offset + @as(u32, @intCast(start)), {}) catch {};
                }
                continue;
            } else if (gap[i + 1] == '*') {
                // Block comment
                const start = i;
                i += 2;
                while (i + 1 < gap.len) {
                    if (gap[i] == '*' and gap[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                try buf.appendSlice(alloc, indent);
                try buf.appendSlice(alloc, gap[start..i]);
                try buf.append(alloc, '\n');
                // Mark as consumed to prevent codegen duplication
                if (ctx) |c| {
                    c.ast.consumed_comments.put(c.allocator, abs_offset + @as(u32, @intCast(start)), {}) catch {};
                }
                continue;
            }
        }
        i += 1;
    }
}

fn getNodeSourceText(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const i = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(i)) |replacement| {
        return replacement;
    }
    const end_off = ctx.ast.nodes.items(.end_offset)[i];
    const start = getNodeStartPos(ctx, node);
    if (end_off > start and end_off <= ctx.ast.source.len) {
        return ctx.ast.source[start..end_off];
    }
    // Fallback: just the main token
    const main_tok = ctx.ast.nodes.items(.main_token)[i];
    return ctx.tokenSlice(main_tok);
}

fn getNodeGeneratedSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const comment_count = ctx.ast.comments.items.len;
    var emitted = std.DynamicBitSetUnmanaged.initEmpty(ctx.allocator, comment_count) catch {
        return getNodeSourceText(ctx, node);
    };
    emitted.setRangeValue(.{ .start = 0, .end = comment_count }, true);

    var cg = Codegen{
        .ast = ctx.ast,
        .buf = .empty,
        .allocator = ctx.allocator,
        .source_map = null,
        .emit_comments = false,
        .emitted_comments = emitted,
    };
    cg.emitNode(node) catch return getNodeSourceText(ctx, node);
    return cg.buf.toOwnedSlice(ctx.allocator) catch getNodeSourceText(ctx, node);
}

fn appendIndentedMultiline(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
    src: []const u8,
) !void {
    var start: usize = 0;
    while (start < src.len) {
        const nl_rel = std.mem.indexOfScalar(u8, src[start..], '\n');
        const end = if (nl_rel) |n| start + n else src.len;
        try buf.appendSlice(allocator, indent);
        try buf.appendSlice(allocator, src[start..end]);
        try buf.appendSlice(allocator, "\n");
        if (nl_rel == null) break;
        start = end + 1;
    }
}

fn appendInlineExprWithIndent(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    src: []const u8,
    indent: []const u8,
) !void {
    var start: usize = 0;
    var first = true;
    while (start < src.len) {
        const nl_rel = std.mem.indexOfScalar(u8, src[start..], '\n');
        const end = if (nl_rel) |n| start + n else src.len;
        if (!first) try buf.appendSlice(allocator, indent);
        try buf.appendSlice(allocator, src[start..end]);
        if (nl_rel == null) break;
        try buf.append(allocator, '\n');
        first = false;
        start = end + 1;
    }
}

/// Find the start byte position of a node by walking to the leftmost descendant.
fn getNodeStartPos(ctx: *TransformContext, node: NodeIndex) u32 {
    const i = @intFromEnum(node);
    const tag = ctx.ast.nodes.items(.tag)[i];
    const data = ctx.ast.nodes.items(.data)[i];
    const main_tok = ctx.ast.nodes.items(.main_token)[i];
    const mt_start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];

    // For nodes with a leftmost child that starts before main_token
    switch (tag) {
        .call_expr, .optional_call_expr, .new_expr => {
            const extra_idx = @intFromEnum(data.extra);
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            if (callee != .none) {
                const callee_start = getNodeStartPos(ctx, callee);
                if (tag == .new_expr) {
                    // 'new' keyword is before callee
                    return @min(mt_start, callee_start);
                }
                return @min(callee_start, mt_start);
            }
        },
        .member_expr, .computed_member_expr => {
            const lhs_start = getNodeStartPos(ctx, data.binary.lhs);
            return @min(lhs_start, mt_start);
        },
        .binary_expr, .logical_expr => {
            const lhs_start = getNodeStartPos(ctx, data.binary.lhs);
            return @min(lhs_start, mt_start);
        },
        .unary_expr, .update_expr => {
            return mt_start; // unary operator is the main_token
        },
        .ts_as_expression, .ts_satisfies_expression => {
            const lhs_start = getNodeStartPos(ctx, data.binary.lhs);
            return @min(lhs_start, mt_start);
        },
        .ts_non_null_expression => {
            const inner_start = getNodeStartPos(ctx, data.unary);
            return @min(inner_start, mt_start);
        },
        .parenthesized_expr => {
            return mt_start; // '(' is the main_token
        },
        .arrow_function_expr => {
            // Check for async
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx < ctx.ast.extra_data.items.len) {
                const name_raw = ctx.ast.extra_data.items[extra_idx];
                if (name_raw != @intFromEnum(NodeIndex.none)) {
                    // has name node
                }
            }
            return mt_start;
        },
        else => return mt_start,
    }
    return mt_start;
}

/// Scan program body for const/var declarations with literal initializers.
/// Populates ctx.outer_const_values for enum constant folding.
fn scanOuterConstants(ctx: *TransformContext) void {
    if (ctx.outer_const_scan_done) return;
    ctx.outer_const_scan_done = true;

    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    if (tags.len == 0 or tags[0] != .program) return;

    const program_data = datas[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        const si = @intFromEnum(stmt);
        var tag = tags[si];

        // Unwrap export_named
        var decl_idx = stmt;
        if (tag == .export_named) {
            const ed = datas[si];
            const eidx = @intFromEnum(ed.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                const dr = ctx.ast.extra_data.items[eidx + 3];
                if (dr != @intFromEnum(NodeIndex.none)) {
                    decl_idx = @enumFromInt(dr);
                    tag = tags[@intFromEnum(decl_idx)];
                } else continue;
            } else continue;
        }

        if (tag != .var_declaration and tag != .const_declaration and tag != .let_declaration) continue;

        const dd = datas[@intFromEnum(decl_idx)];
        const dextra = @intFromEnum(dd.extra);
        if (dextra + 1 >= ctx.ast.extra_data.items.len) continue;
        const decls_start = ctx.ast.extra_data.items[dextra];
        const decls_end = ctx.ast.extra_data.items[dextra + 1];

        for (ctx.ast.extra_data.items[decls_start..decls_end]) |declarator_raw| {
            const declarator: NodeIndex = @enumFromInt(declarator_raw);
            if (declarator == .none) continue;
            const di = @intFromEnum(declarator);
            if (di >= tags.len or tags[di] != .declarator) continue;

            const decl_data = datas[di];
            const binding = decl_data.binary.lhs;
            const init = decl_data.binary.rhs;

            if (binding == .none or init == .none) continue;
            const bi = @intFromEnum(binding);
            if (bi >= tags.len or tags[bi] != .identifier) continue;

            const name = ctx.tokenSlice(main_tokens[bi]);

            const value = evaluateEnumInit(ctx, init, &[_]MemberInfo{}, "");
            switch (value.kind) {
                .number => |n| {
                    ctx.outer_const_values.put(ctx.allocator, name, .{ .kind = .{ .number = n }, .is_pure = value.is_pure }) catch {};
                },
                .string => |s| {
                    ctx.outer_const_values.put(ctx.allocator, name, .{ .kind = .{ .string = s }, .is_pure = value.is_pure }) catch {};
                },
                else => {},
            }
        }
    }
}

fn lookupTopLevelConstValue(ctx: *TransformContext, name: []const u8, depth: u8) ?ResolvedEnumValue {
    if (depth >= 8) return null;

    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    if (tags.len == 0 or tags[0] != .program) return null;

    const program_data = datas[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;

        var decl_idx = stmt;
        var tag = tags[@intFromEnum(stmt)];
        if (tag == .export_named) {
            const ed = datas[@intFromEnum(stmt)];
            const eidx = @intFromEnum(ed.extra);
            if (eidx + 3 >= ctx.ast.extra_data.items.len) continue;
            const dr = ctx.ast.extra_data.items[eidx + 3];
            if (dr == @intFromEnum(NodeIndex.none)) continue;
            decl_idx = @enumFromInt(dr);
            tag = tags[@intFromEnum(decl_idx)];
        }

        if (tag != .var_declaration and tag != .const_declaration and tag != .let_declaration) continue;

        const dd = datas[@intFromEnum(decl_idx)];
        const dextra = @intFromEnum(dd.extra);
        if (dextra + 1 >= ctx.ast.extra_data.items.len) continue;
        const decls_start = ctx.ast.extra_data.items[dextra];
        const decls_end = ctx.ast.extra_data.items[dextra + 1];

        for (ctx.ast.extra_data.items[decls_start..decls_end]) |declarator_raw| {
            const declarator: NodeIndex = @enumFromInt(declarator_raw);
            if (declarator == .none) continue;
            if (tags[@intFromEnum(declarator)] != .declarator) continue;

            const decl_data = datas[@intFromEnum(declarator)];
            const binding = decl_data.binary.lhs;
            const init = decl_data.binary.rhs;
            if (binding == .none or init == .none) continue;
            if (tags[@intFromEnum(binding)] != .identifier) continue;

            const binding_name = ctx.tokenSlice(main_tokens[@intFromEnum(binding)]);
            if (!std.mem.eql(u8, binding_name, name)) continue;

            const value = evaluateEnumInit(ctx, init, &[_]MemberInfo{}, "");
            return switch (value.kind) {
                .number => |n| .{ .kind = .{ .number = n }, .is_pure = value.is_pure },
                .string => |s| .{ .kind = .{ .string = s }, .is_pure = value.is_pure },
                else => null,
            };
        }
    }

    return null;
}

fn evalBinaryNumeric(op: []const u8, l: f64, r: f64) ?f64 {
    if (std.mem.eql(u8, op, "+")) return l + r;
    if (std.mem.eql(u8, op, "-")) return l - r;
    if (std.mem.eql(u8, op, "*")) return l * r;
    if (std.mem.eql(u8, op, "/")) return l / r;
    if (std.mem.eql(u8, op, "%")) return @mod(l, r);
    if (std.mem.eql(u8, op, "**")) return std.math.pow(f64, l, r);
    // Bitwise operations — need to convert to i32 first
    const li: i32 = @intFromFloat(@max(@min(l, 2147483647.0), -2147483648.0));
    const ri_u5: u5 = @intCast(@as(u32, @bitCast(@as(i32, @intFromFloat(@max(@min(r, 2147483647.0), -2147483648.0))))) & 0x1f);
    if (std.mem.eql(u8, op, "|")) return @floatFromInt(li | @as(i32, @intFromFloat(@max(@min(r, 2147483647.0), -2147483648.0))));
    if (std.mem.eql(u8, op, "&")) return @floatFromInt(li & @as(i32, @intFromFloat(@max(@min(r, 2147483647.0), -2147483648.0))));
    if (std.mem.eql(u8, op, "^")) return @floatFromInt(li ^ @as(i32, @intFromFloat(@max(@min(r, 2147483647.0), -2147483648.0))));
    if (std.mem.eql(u8, op, "<<")) return @floatFromInt(li << ri_u5);
    if (std.mem.eql(u8, op, ">>")) return @floatFromInt(li >> ri_u5);
    if (std.mem.eql(u8, op, ">>>")) {
        const ui: u32 = @bitCast(li);
        return @floatFromInt(ui >> ri_u5);
    }
    return null;
}

// ────────────────────────────────────────────────────────────────────────
// End of enum IIFE helpers
// ────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────
// Namespace → IIFE transform
// ────────────────────────────────────────────────────────────────────────

fn handleNamespaceDeclaration(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);

    // Layout: extra[0]=name_node, extra[1]=body_node, extra[2]=kind_code
    const name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const body_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);

    if (body_node == .none) return; // No body — already handled

    // Get namespace name
    const name_token = ctx.mainToken(name_node);
    const ns_name = ctx.tokenSlice(name_token);

    // Check if the name is a ts_qualified_name (dotted namespace: A.B.C)
    const name_tag = ctx.nodeTag(name_node);
    if (name_tag == .ts_qualified_name) {
        handleDottedNamespaceQualified(idx, ctx, name_node, body_node);
        return;
    }

    // Check if body is a ts_module_block
    const body_tag = ctx.nodeTag(body_node);
    if (body_tag != .ts_module_block) {
        // Nested dotted namespace: `namespace A.B { }` — body is another ts_module_declaration
        if (body_tag == .ts_module_declaration) {
            handleDottedNamespace(idx, ctx, ns_name, body_node);
            return;
        }
        return;
    }

    // Get body members
    const body_data = ctx.nodeData(body_node);
    const body_extra = @intFromEnum(body_data.extra);
    const body_start = ctx.ast.extra_data.items[body_extra];
    const body_end = ctx.ast.extra_data.items[body_extra + 1];

    // Check if exported
    const is_exported = ctx.exported_nodes.contains(@intFromEnum(idx));

    // Check if namespace has any runtime members (non-type declarations)
    const needs_empty_stub = nsNeedsEmptyStub(ctx, body_start, body_end);

    if (!nsHasRuntimeMembers(ctx, body_start, body_end)) {
        if (!is_exported and !needs_empty_stub) {
            // Non-exported namespace with only pure types → remove entirely
            // Mark the name as type-only so export { Name } is also removed
            ctx.type_only_decls.put(ctx.allocator, ns_name, {}) catch {};
            // Use .removed tag to also suppress leading comments
            ctx.ast.nodes.items(.tag)[@intFromEnum(idx)] = .removed;
            return;
        }
        // Exported namespace or has declare members → keep as empty IIFE with single `;`
    }

    // Check if first occurrence
    const is_first = !ctx.seen_enum_names.contains(ns_name);
    ctx.seen_enum_names.put(ctx.allocator, ns_name, {}) catch {};

    // Generate unique parameter name
    const param_name = generateUniqueParamName(ctx, ns_name) orelse return;

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    // For first occurrence and not clobbering: emit `let N;\n`
    // For clobbering (class/enum with same name exists), skip the `let` declaration
    if (is_first and !isClobberingExistingDecl(ctx, ns_name)) {
        if (is_exported) {
            buf.appendSlice(ctx.allocator, "let ") catch return;
        } else {
            buf.appendSlice(ctx.allocator, "let ") catch return;
        }
        buf.appendSlice(ctx.allocator, ns_name) catch return;
        buf.appendSlice(ctx.allocator, ";\n") catch return;
    }

    // Generate body into temp buffer to detect empty
    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    {
        const saved_seen = ctx.seen_enum_names;
        ctx.seen_enum_names = .{};
        generateNamespaceBody(ctx, body_start, body_end, param_name, &body_buf, "  ") catch return;
        ctx.seen_enum_names = saved_seen;
    }

    if (body_buf.items.len == 0 and !is_exported and !needs_empty_stub) {
        ctx.type_only_decls.put(ctx.allocator, ns_name, {}) catch {};
        ctx.ast.nodes.items(.tag)[@intFromEnum(idx)] = .removed;
        return;
    }

    if (isInProgramBody(ctx, idx) and ctx.ast.source_type == .module and programHasTopLevelValueTypeSyntax(ctx)) {
        ctx.needs_module_marker = true;
    }

    // Generate IIFE: `(function (_N) { ... })(N || (N = {}));`
    buf.appendSlice(ctx.allocator, "(function (") catch return;
    buf.appendSlice(ctx.allocator, param_name) catch return;
    if (body_buf.items.len == 0) {
        buf.appendSlice(ctx.allocator, ") {})(") catch return;
    } else {
        buf.appendSlice(ctx.allocator, ") {\n") catch return;
        buf.appendSlice(ctx.allocator, body_buf.items) catch return;
        buf.appendSlice(ctx.allocator, "})(") catch return;
    }
    buf.appendSlice(ctx.allocator, ns_name) catch return;
    buf.appendSlice(ctx.allocator, " || (") catch return;
    buf.appendSlice(ctx.allocator, ns_name) catch return;
    buf.appendSlice(ctx.allocator, " = {}));") catch return;

    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), buf.items) catch return;
}

/// Check if namespace has any runtime (non-type) members.
fn nsHasRuntimeMembers(ctx: *TransformContext, start: u32, end: u32) bool {
    for (ctx.ast.extra_data.items[start..end]) |member_raw| {
        const member: NodeIndex = @enumFromInt(member_raw);
        if (member == .none) continue;
        const tag = ctx.nodeTag(member);
        switch (tag) {
            // Type-only declarations
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_declare_function,
            .ts_declare_variable,
            .ts_declare_method,
            .import_declaration_type,
            .ts_index_signature,
            .ts_import_equals_declaration,
            => continue,
            // export_named might wrap a type-only declaration
            .export_named_type => {
                // export_named_type is always a type export — skip
                continue;
            },
            .export_named => {
                const ed = ctx.nodeData(member);
                const eidx = @intFromEnum(ed.extra);
                if (eidx + 3 < ctx.ast.extra_data.items.len) {
                    const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                    if (decl_raw != @intFromEnum(NodeIndex.none)) {
                        const decl_node: NodeIndex = @enumFromInt(decl_raw);
                        const dtag = ctx.nodeTag(decl_node);
                        if (isTsTypeDeclaration(dtag)) continue;
                        if (dtag == .ts_module_declaration and isDeclareNode(ctx, decl_node)) continue;
                        if (dtag == .ts_enum_declaration and isDeclareNode(ctx, decl_node)) continue;
                        if (dtag == .class_declaration and isDeclareClass(ctx, decl_node)) continue;
                        // Check for declare namespace without 'declare' keyword
                        if (dtag == .ts_module_declaration) {
                            // Nested namespace — check recursively
                            const ns_data = ctx.nodeData(decl_node);
                            const ns_extra = @intFromEnum(ns_data.extra);
                            const ns_body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_extra + 1]);
                            if (ns_body != .none and ctx.nodeTag(ns_body) == .ts_module_block) {
                                const nb_data = ctx.nodeData(ns_body);
                                const nb_extra = @intFromEnum(nb_data.extra);
                                const nb_start = ctx.ast.extra_data.items[nb_extra];
                                const nb_end = ctx.ast.extra_data.items[nb_extra + 1];
                                if (!nsHasRuntimeMembers(ctx, nb_start, nb_end)) continue;
                            }
                        }
                        return true;
                    }
                }
                // Check if it's a specifier-only export
                const specs_start = ctx.ast.extra_data.items[eidx + 1];
                const specs_end = ctx.ast.extra_data.items[eidx + 2];
                if (specs_start < specs_end) return true;
                // Empty export with no declaration — skip
                continue;
            },
            // Nested namespace — check if it has runtime
            .ts_module_declaration => {
                if (isDeclareNode(ctx, member)) continue;
                // Non-declare nested namespace — check recursively
                const ns_data = ctx.nodeData(member);
                const ns_extra = @intFromEnum(ns_data.extra);
                const ns_body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_extra + 1]);
                if (ns_body != .none and ctx.nodeTag(ns_body) == .ts_module_block) {
                    const nb_data = ctx.nodeData(ns_body);
                    const nb_extra = @intFromEnum(nb_data.extra);
                    const nb_start = ctx.ast.extra_data.items[nb_extra];
                    const nb_end = ctx.ast.extra_data.items[nb_extra + 1];
                    if (!nsHasRuntimeMembers(ctx, nb_start, nb_end)) continue;
                }
                return true;
            },
            .ts_enum_declaration => {
                if (isDeclareNode(ctx, member)) continue;
                return true;
            },
            .class_declaration => {
                if (isDeclareClass(ctx, member)) continue;
                return true;
            },
            // Everything else is runtime
            else => return true,
        }
    }
    return false;
}

/// Check if a namespace body contains any `declare` members
/// (export declare class, export declare function, etc.).
/// These are distinguished from pure type members (type, interface)
/// because they still warrant an empty IIFE stub.
/// Handle dotted namespace with ts_qualified_name: `namespace A.B.C { ... }` → nested IIFEs.
fn handleDottedNamespaceQualified(
    idx: NodeIndex,
    ctx: *TransformContext,
    qualified_name: NodeIndex,
    body_node: NodeIndex,
) void {
    // Collect all names from the qualified name chain
    var names: [16][]const u8 = undefined;
    var name_count: usize = 0;

    collectQualifiedNames(ctx, qualified_name, &names, &name_count);

    if (name_count == 0) return;
    if (body_node == .none) return;

    const body_tag = ctx.nodeTag(body_node);
    if (body_tag != .ts_module_block) return;

    const bd = ctx.nodeData(body_node);
    const be = @intFromEnum(bd.extra);
    const bs = ctx.ast.extra_data.items[be];
    const ben = ctx.ast.extra_data.items[be + 1];

    generateDottedNamespaceIife(ctx, idx, names[0..name_count], bs, ben);
}

/// Collect names from a ts_qualified_name chain (A.B.C → ["A", "B", "C"]).
fn collectQualifiedNames(
    ctx: *TransformContext,
    node: NodeIndex,
    names: *[16][]const u8,
    count: *usize,
) void {
    if (node == .none) return;
    const tag = ctx.nodeTag(node);
    if (tag == .ts_qualified_name) {
        const data = ctx.nodeData(node);
        collectQualifiedNames(ctx, data.binary.lhs, names, count);
        collectQualifiedNames(ctx, data.binary.rhs, names, count);
    } else if (tag == .identifier) {
        const tok = ctx.mainToken(node);
        if (count.* < 16) {
            names[count.*] = ctx.tokenSlice(tok);
            count.* += 1;
        }
    }
}

/// Handle dotted namespace: `namespace A.B.C { ... }` → nested IIFEs.
fn handleDottedNamespace(
    idx: NodeIndex,
    ctx: *TransformContext,
    outer_name: []const u8,
    inner_module: NodeIndex,
) void {
    // Collect all the namespace names in the dotted chain
    var names: [16][]const u8 = undefined;
    var name_count: usize = 0;
    names[0] = outer_name;
    name_count = 1;

    // Walk the chain of ts_module_declaration nodes
    var current = inner_module;
    while (true) {
        if (current == .none) break;
        if (ctx.nodeTag(current) != .ts_module_declaration) break;
        const cd = ctx.nodeData(current);
        const ce = @intFromEnum(cd.extra);
        const cn: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ce]);
        const cb: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ce + 1]);
        const ct = ctx.mainToken(cn);
        if (name_count < 16) {
            names[name_count] = ctx.tokenSlice(ct);
            name_count += 1;
        }
        if (cb == .none or ctx.nodeTag(cb) == .ts_module_block) {
            // Found the leaf — cb is the actual body
            if (cb != .none) {
                const bd = ctx.nodeData(cb);
                const be = @intFromEnum(bd.extra);
                const bs = ctx.ast.extra_data.items[be];
                const ben = ctx.ast.extra_data.items[be + 1];
                generateDottedNamespaceIife(ctx, idx, names[0..name_count], bs, ben);
            }
            return;
        }
        current = cb;
    }
}

/// Generate nested IIFEs for a dotted namespace chain.
fn generateDottedNamespaceIife(
    ctx: *TransformContext,
    idx: NodeIndex,
    names: []const []const u8,
    body_start: u32,
    body_end: u32,
) void {
    if (names.len == 0) return;

    const is_exported = ctx.exported_nodes.contains(@intFromEnum(idx));
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    // Build the nested IIFEs from outermost to innermost
    // Generate: let A;\n(function (_A) {\n  let B;\n  (function (_B) {\n    ...body...\n  })(B || (B = _A.B || (_A.B = {})));\n})(A || (A = {}));

    // Track param names
    var params: [16][]const u8 = undefined;
    const outer_is_first = !ctx.seen_enum_names.contains(names[0]);
    for (names, 0..) |name, i| {
        const min_suffix: u32 = if (i == 0 and is_exported and outer_is_first and names.len > 1) 2 else 1;
        const param = generateUniqueParamNameWithMinSuffix(ctx, name, min_suffix) orelse return;
        if (i < 16) params[i] = param;
    }

    // Generate opening for each level
    for (names, 0..) |name, i| {
        const is_first = !ctx.seen_enum_names.contains(name);
        ctx.seen_enum_names.put(ctx.allocator, name, {}) catch {};

        // Indent
        for (0..i) |_| {
            buf.appendSlice(ctx.allocator, "  ") catch return;
        }

        if (is_first and (i > 0 or !isClobberingExistingDecl(ctx, name))) {
            if (is_exported and i == 0) {
                buf.appendSlice(ctx.allocator, "let ") catch return;
            } else {
                buf.appendSlice(ctx.allocator, "let ") catch return;
            }
            buf.appendSlice(ctx.allocator, name) catch return;
            buf.appendSlice(ctx.allocator, ";\n") catch return;
        }

        // Indent
        for (0..i) |_| {
            buf.appendSlice(ctx.allocator, "  ") catch return;
        }

        buf.appendSlice(ctx.allocator, "(function (") catch return;
        buf.appendSlice(ctx.allocator, params[i]) catch return;
        buf.appendSlice(ctx.allocator, ") {\n") catch return;
    }

    // Generate body at innermost level
    // Body content inside the innermost IIFE (at nesting level names.len - 1)
    // gets indented by names.len * 2 spaces
    const inner_indent_count = names.len;
    const inner_indent = ctx.allocator.alloc(u8, inner_indent_count * 2) catch return;
    for (0..inner_indent_count) |ii| {
        inner_indent[ii * 2] = ' ';
        inner_indent[ii * 2 + 1] = ' ';
    }
    if (!nsHasRuntimeMembers(ctx, body_start, body_end)) {
        buf.appendSlice(ctx.allocator, inner_indent) catch return;
        buf.appendSlice(ctx.allocator, ";\n") catch return;
    } else {
        generateNamespaceBody(ctx, body_start, body_end, params[names.len - 1], &buf, inner_indent) catch return;
    }

    // Generate closing for each level (reverse order)
    var level: usize = names.len;
    while (level > 0) {
        level -= 1;
        const name = names[level];

        // Indent
        for (0..level) |_| {
            buf.appendSlice(ctx.allocator, "  ") catch return;
        }

        buf.appendSlice(ctx.allocator, "})(") catch return;
        buf.appendSlice(ctx.allocator, name) catch return;
        buf.appendSlice(ctx.allocator, " || (") catch return;
        buf.appendSlice(ctx.allocator, name) catch return;

        if (level > 0) {
            // Inner levels: `B || (B = _A.B || (_A.B = {}))`
            const parent_param = params[level - 1];
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, parent_param) catch return;
            buf.appendSlice(ctx.allocator, ".") catch return;
            buf.appendSlice(ctx.allocator, name) catch return;
            buf.appendSlice(ctx.allocator, " || (") catch return;
            buf.appendSlice(ctx.allocator, parent_param) catch return;
            buf.appendSlice(ctx.allocator, ".") catch return;
            buf.appendSlice(ctx.allocator, name) catch return;
            buf.appendSlice(ctx.allocator, " = {})));\n") catch return;
        } else {
            // Outermost level: `A || (A = {})`
            buf.appendSlice(ctx.allocator, " = {}));") catch return;
        }
    }

    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), buf.items) catch return;
}

/// Pre-allocate param names for all nested namespaces in a body (for counter consistency).
/// Called when a namespace body is being skipped but we still need to maintain the param counter.
fn preAllocateNestedParamNames(ctx: *TransformContext, body_start: u32, body_end: u32) void {
    for (ctx.ast.extra_data.items[body_start..body_end]) |member_raw| {
        const member: NodeIndex = @enumFromInt(member_raw);
        if (member == .none) continue;
        const mtag = ctx.nodeTag(member);
        switch (mtag) {
            .ts_module_declaration => {
                if (isDeclareNode(ctx, member)) continue;
                const nsd = ctx.nodeData(member);
                const nse = @intFromEnum(nsd.extra);
                const nsn: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[nse]);
                const nsb: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[nse + 1]);
                const ns_tok = ctx.mainToken(nsn);
                const ns_nm = ctx.tokenSlice(ns_tok);
                _ = generateUniqueParamName(ctx, ns_nm);
                // Recurse into nested body
                if (nsb != .none and ctx.nodeTag(nsb) == .ts_module_block) {
                    const nbd = ctx.nodeData(nsb);
                    const nbe = @intFromEnum(nbd.extra);
                    const nbs = ctx.ast.extra_data.items[nbe];
                    const nben = ctx.ast.extra_data.items[nbe + 1];
                    preAllocateNestedParamNames(ctx, nbs, nben);
                }
            },
            .export_named, .export_named_type => {
                const ed = ctx.nodeData(member);
                const eidx = @intFromEnum(ed.extra);
                if (eidx + 3 < ctx.ast.extra_data.items.len) {
                    const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                    if (decl_raw != @intFromEnum(NodeIndex.none)) {
                        const decl_node: NodeIndex = @enumFromInt(decl_raw);
                        if (ctx.nodeTag(decl_node) == .ts_module_declaration and !isDeclareNode(ctx, decl_node)) {
                            const nsd = ctx.nodeData(decl_node);
                            const nse = @intFromEnum(nsd.extra);
                            const nsn: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[nse]);
                            const nsb: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[nse + 1]);
                            const ns_tok = ctx.mainToken(nsn);
                            const ns_nm = ctx.tokenSlice(ns_tok);
                            _ = generateUniqueParamName(ctx, ns_nm);
                            if (nsb != .none and ctx.nodeTag(nsb) == .ts_module_block) {
                                const nbd = ctx.nodeData(nsb);
                                const nbe = @intFromEnum(nbd.extra);
                                const nbs = ctx.ast.extra_data.items[nbe];
                                const nben = ctx.ast.extra_data.items[nbe + 1];
                                preAllocateNestedParamNames(ctx, nbs, nben);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
}

/// Generate a unique parameter name for a namespace IIFE.
/// Uses `_name` for the first occurrence, `_name2`, `_name3`, etc. for subsequent ones.
fn generateUniqueParamName(ctx: *TransformContext, ns_name: []const u8) ?[]const u8 {
    return generateUniqueParamNameWithMinSuffix(ctx, ns_name, 1);
}

fn generateUniqueParamNameWithMinSuffix(ctx: *TransformContext, ns_name: []const u8, min_suffix: u32) ?[]const u8 {
    const base = namespaceParamBase(ctx, ns_name);
    var suffix: u32 = if (min_suffix == 0) 1 else min_suffix;
    while (suffix < 10_000) : (suffix += 1) {
        const candidate = if (suffix == 1)
            std.fmt.allocPrint(ctx.allocator, "_{s}", .{base}) catch return null
        else
            std.fmt.allocPrint(ctx.allocator, "_{s}{d}", .{ base, suffix }) catch return null;
        if (!namespaceParamConflict(ctx, candidate)) {
            ctx.ns_used_params.put(ctx.allocator, candidate, suffix) catch {};
            return candidate;
        }
    }
    return null;
}

fn namespaceParamBase(_: *TransformContext, ns_name: []const u8) []const u8 {
    var start: usize = 0;
    while (start < ns_name.len and (ns_name[start] == '_' or (ns_name[start] >= '0' and ns_name[start] <= '9'))) {
        start += 1;
    }

    var end: usize = ns_name.len;
    while (end > start and ns_name[end - 1] >= '0' and ns_name[end - 1] <= '9') {
        end -= 1;
    }

    if (start >= end) {
        const trimmed = std.mem.trim(u8, ns_name, "_0123456789");
        if (trimmed.len > 0) return trimmed;
        return "N";
    }

    const base = ns_name[start..end];
    return if (base.len > 0) base else "N";
}

fn namespaceParamConflict(ctx: *TransformContext, candidate: []const u8) bool {
    if (ctx.ns_used_params.contains(candidate)) return true;

    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    for (tags, 0..) |tag, ni| {
        switch (tag) {
            .identifier => {
                if (std.mem.eql(u8, ctx.tokenSlice(main_tokens[ni]), candidate)) return true;
            },
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .class_declaration,
            .class_expr,
            => {
                const extra_idx = @intFromEnum(datas[ni].extra);
                if (extra_idx >= ctx.ast.extra_data.items.len) continue;
                const name_tok_raw = ctx.ast.extra_data.items[extra_idx];
                if (name_tok_raw == 0 or name_tok_raw == @intFromEnum(NodeIndex.none) or name_tok_raw >= ctx.ast.tokens.len) continue;
                const tok: TokenIndex = @enumFromInt(name_tok_raw);
                if (std.mem.eql(u8, ctx.tokenSlice(tok), candidate)) return true;
            },
            else => {},
        }
    }

    return false;
}

/// Generate a nested namespace IIFE into a buffer with given indentation.
fn generateNestedNamespaceIife(
    ctx: *TransformContext,
    ns_name: []const u8,
    body_start: u32,
    body_end: u32,
    is_exported: bool,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
) error{OutOfMemory}!void {
    _ = is_exported;

    // Check if first occurrence or merge
    const is_first = !ctx.seen_enum_names.contains(ns_name);
    ctx.seen_enum_names.put(ctx.allocator, ns_name, {}) catch {};

    // Generate unique parameter name
    const ns_param = generateUniqueParamName(ctx, ns_name) orelse return;

    // Generate body into a temp buffer to detect empty
    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    {
        const nested_indent = try ctx.allocator.alloc(u8, indent.len + 2);
        @memcpy(nested_indent[0..indent.len], indent);
        nested_indent[indent.len] = ' ';
        nested_indent[indent.len + 1] = ' ';

        const saved_seen = ctx.seen_enum_names;
        ctx.seen_enum_names = .{};
        try generateNamespaceBody(ctx, body_start, body_end, ns_param, &body_buf, nested_indent);
        ctx.seen_enum_names = saved_seen;
    }

    if (body_buf.items.len == 0 and !nsNeedsEmptyStub(ctx, body_start, body_end)) {
        return;
    }

    // Emit `let N;\n` for first occurrence
    if (is_first) {
        try buf.appendSlice(ctx.allocator, indent);
        try buf.appendSlice(ctx.allocator, "let ");
        try buf.appendSlice(ctx.allocator, ns_name);
        try buf.appendSlice(ctx.allocator, ";\n");
    }

    // Generate IIFE
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "(function (");
    try buf.appendSlice(ctx.allocator, ns_param);
    if (body_buf.items.len == 0) {
        // Empty body — compact format
        try buf.appendSlice(ctx.allocator, ") {})(");
    } else {
        try buf.appendSlice(ctx.allocator, ") {\n");
        try buf.appendSlice(ctx.allocator, body_buf.items);
        try buf.appendSlice(ctx.allocator, indent);
        try buf.appendSlice(ctx.allocator, "})(");
    }
    try buf.appendSlice(ctx.allocator, ns_name);
    try buf.appendSlice(ctx.allocator, " || (");
    try buf.appendSlice(ctx.allocator, ns_name);
    try buf.appendSlice(ctx.allocator, " = {}));\n");
}

/// Generate a nested namespace IIFE for an exported namespace inside a parent.
/// Uses pattern: (N || (N = _Parent.N || (_Parent.N = {}))) for the IIFE call.
fn generateNestedNamespaceIifeExported(
    ctx: *TransformContext,
    ns_name: []const u8,
    body_start: u32,
    body_end: u32,
    parent_param: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
) error{OutOfMemory}!void {
    // Check if first occurrence or merge
    const is_first = !ctx.seen_enum_names.contains(ns_name);
    ctx.seen_enum_names.put(ctx.allocator, ns_name, {}) catch {};

    // Generate unique parameter name
    const ns_param = generateUniqueParamName(ctx, ns_name) orelse return;

    // Generate body into a temp buffer to detect empty
    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    {
        const nested_indent = try ctx.allocator.alloc(u8, indent.len + 2);
        @memcpy(nested_indent[0..indent.len], indent);
        nested_indent[indent.len] = ' ';
        nested_indent[indent.len + 1] = ' ';

        const saved_seen = ctx.seen_enum_names;
        ctx.seen_enum_names = .{};
        try generateNamespaceBody(ctx, body_start, body_end, ns_param, &body_buf, nested_indent);
        ctx.seen_enum_names = saved_seen;
    }

    if (body_buf.items.len == 0 and !nsNeedsEmptyStub(ctx, body_start, body_end)) {
        return;
    }

    // Emit `let N;\n` for first occurrence
    if (is_first) {
        try buf.appendSlice(ctx.allocator, indent);
        try buf.appendSlice(ctx.allocator, "let ");
        try buf.appendSlice(ctx.allocator, ns_name);
        try buf.appendSlice(ctx.allocator, ";\n");
    }

    // Generate IIFE
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "(function (");
    try buf.appendSlice(ctx.allocator, ns_param);
    if (body_buf.items.len == 0) {
        try buf.appendSlice(ctx.allocator, ") {})(");
    } else {
        try buf.appendSlice(ctx.allocator, ") {\n");
        try buf.appendSlice(ctx.allocator, body_buf.items);
        try buf.appendSlice(ctx.allocator, indent);
        try buf.appendSlice(ctx.allocator, "})(");
    }
    try buf.appendSlice(ctx.allocator, ns_name);
    try buf.appendSlice(ctx.allocator, " || (");
    try buf.appendSlice(ctx.allocator, ns_name);
    try buf.appendSlice(ctx.allocator, " = ");
    try buf.appendSlice(ctx.allocator, parent_param);
    try buf.appendSlice(ctx.allocator, ".");
    try buf.appendSlice(ctx.allocator, ns_name);
    try buf.appendSlice(ctx.allocator, " || (");
    try buf.appendSlice(ctx.allocator, parent_param);
    try buf.appendSlice(ctx.allocator, ".");
    try buf.appendSlice(ctx.allocator, ns_name);
    try buf.appendSlice(ctx.allocator, " = {})));\n");
}

/// Generate a nested enum IIFE into a buffer with given indentation.
fn generateNestedEnumIife(
    ctx: *TransformContext,
    enum_node: NodeIndex,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
) error{OutOfMemory}!void {
    const data = ctx.nodeData(enum_node);
    const extra_idx = @intFromEnum(data.extra);

    const name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const members_start = ctx.ast.extra_data.items[extra_idx + 1];
    const members_end = ctx.ast.extra_data.items[extra_idx + 2];

    const name_token = ctx.mainToken(name_node);
    const enum_name = ctx.tokenSlice(name_token);

    // Check if first occurrence or merge
    const is_first = !ctx.seen_enum_names.contains(enum_name);
    ctx.seen_enum_names.put(ctx.allocator, enum_name, {}) catch {};

    // Use 'let' for block-scoped enums
    if (is_first) {
        try buf.appendSlice(ctx.allocator, indent);
        try buf.appendSlice(ctx.allocator, "let ");
        try buf.appendSlice(ctx.allocator, enum_name);
        try buf.appendSlice(ctx.allocator, " = ");
    } else {
        try buf.appendSlice(ctx.allocator, indent);
        try buf.appendSlice(ctx.allocator, enum_name);
        try buf.appendSlice(ctx.allocator, " = ");
    }

    // Generate IIFE body (use {} for block-scoped first occurrence)
    const use_empty_arg = is_first;
    const nested_indent = std.fmt.allocPrint(ctx.allocator, "{s}  ", .{indent}) catch "  ";
    generateEnumIife(ctx, enum_name, members_start, members_end, buf, use_empty_arg, nested_indent, indent) catch return;

    try buf.appendSlice(ctx.allocator, ";\n");
}

fn generateNestedConstEnumObject(
    ctx: *TransformContext,
    enum_node: NodeIndex,
    namespace_param: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
) error{OutOfMemory}!void {
    const data = ctx.nodeData(enum_node);
    const extra_idx = @intFromEnum(data.extra);
    const name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const members_start = ctx.ast.extra_data.items[extra_idx + 1];
    const members_end = ctx.ast.extra_data.items[extra_idx + 2];
    const name_token = ctx.mainToken(name_node);
    const enum_name = ctx.tokenSlice(name_token);

    const member_infos = try collectEnumMemberInfos(ctx, members_start, members_end, enum_name);
    storeResolvedEnumMemberValues(ctx, enum_name, member_infos.items);
    ctx.runtime_const_enums.put(ctx.allocator, enum_name, {}) catch {};

    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "const ");
    try buf.appendSlice(ctx.allocator, enum_name);
    try buf.appendSlice(ctx.allocator, " = ");
    try generateConstEnumObjectLiteral(ctx, member_infos.items, buf, indent);
    try buf.appendSlice(ctx.allocator, ";\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, namespace_param);
    try buf.appendSlice(ctx.allocator, ".");
    try buf.appendSlice(ctx.allocator, enum_name);
    try buf.appendSlice(ctx.allocator, " = ");
    try buf.appendSlice(ctx.allocator, enum_name);
    try buf.appendSlice(ctx.allocator, ";\n");
}

fn nsHasDeclareMembers(ctx: *TransformContext, start: u32, end: u32) bool {
    for (ctx.ast.extra_data.items[start..end]) |member_raw| {
        const member: NodeIndex = @enumFromInt(member_raw);
        if (member == .none) continue;
        const tag = ctx.nodeTag(member);
        switch (tag) {
            .ts_declare_function, .ts_declare_variable, .ts_declare_method => return true,
            .class_declaration => {
                if (isDeclareClass(ctx, member)) return true;
            },
            .ts_enum_declaration => {
                if (isDeclareNode(ctx, member)) return true;
            },
            .ts_module_declaration => {
                // declare namespace is treated as type-only — don't count it
                if (isDeclareNode(ctx, member)) continue;
                // Recursively check nested namespace for declare members
                const ns_data_dm = ctx.nodeData(member);
                const ns_extra_dm = @intFromEnum(ns_data_dm.extra);
                const ns_body_dm: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_extra_dm + 1]);
                if (ns_body_dm != .none and ctx.nodeTag(ns_body_dm) == .ts_module_block) {
                    const nb_data_dm = ctx.nodeData(ns_body_dm);
                    const nb_extra_dm = @intFromEnum(nb_data_dm.extra);
                    const nb_start_dm = ctx.ast.extra_data.items[nb_extra_dm];
                    const nb_end_dm = ctx.ast.extra_data.items[nb_extra_dm + 1];
                    if (nsHasDeclareMembers(ctx, nb_start_dm, nb_end_dm)) return true;
                }
            },
            .export_named, .export_named_type => {
                const ed = ctx.nodeData(member);
                const eidx = @intFromEnum(ed.extra);
                if (eidx + 3 < ctx.ast.extra_data.items.len) {
                    const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                    if (decl_raw != @intFromEnum(NodeIndex.none)) {
                        const decl_node: NodeIndex = @enumFromInt(decl_raw);
                        const dtag = ctx.nodeTag(decl_node);
                        if (dtag == .ts_declare_function or dtag == .ts_declare_variable or dtag == .ts_declare_method) return true;
                        if (dtag == .ts_enum_declaration and isDeclareNode(ctx, decl_node)) return true;
                        if (dtag == .class_declaration and isDeclareClass(ctx, decl_node)) return true;
                        // declare namespace is type-only — don't count it
                        // Recursively check non-declared nested namespace for declare members
                        if (dtag == .ts_module_declaration and !isDeclareNode(ctx, decl_node)) {
                            const ns_data_dm2 = ctx.nodeData(decl_node);
                            const ns_extra_dm2 = @intFromEnum(ns_data_dm2.extra);
                            const ns_body_dm2: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_extra_dm2 + 1]);
                            if (ns_body_dm2 != .none and ctx.nodeTag(ns_body_dm2) == .ts_module_block) {
                                const nb_data_dm2 = ctx.nodeData(ns_body_dm2);
                                const nb_extra_dm2 = @intFromEnum(nb_data_dm2.extra);
                                const nb_start_dm2 = ctx.ast.extra_data.items[nb_extra_dm2];
                                const nb_end_dm2 = ctx.ast.extra_data.items[nb_extra_dm2 + 1];
                                if (nsHasDeclareMembers(ctx, nb_start_dm2, nb_end_dm2)) return true;
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn nsNeedsEmptyStub(ctx: *TransformContext, start: u32, end: u32) bool {
    for (ctx.ast.extra_data.items[start..end]) |member_raw| {
        const member: NodeIndex = @enumFromInt(member_raw);
        if (member == .none) continue;
        const tag = ctx.nodeTag(member);

        switch (tag) {
            .ts_module_declaration => {
                if (isDeclareNode(ctx, member)) continue;
                const data = ctx.nodeData(member);
                const extra_idx = @intFromEnum(data.extra);
                const body_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
                if (body_node != .none and ctx.nodeTag(body_node) == .ts_module_block) {
                    const body_data = ctx.nodeData(body_node);
                    const body_extra = @intFromEnum(body_data.extra);
                    const body_start = ctx.ast.extra_data.items[body_extra];
                    const body_end = ctx.ast.extra_data.items[body_extra + 1];
                    if (nsNeedsEmptyStub(ctx, body_start, body_end)) return true;
                }
                continue;
            },
            .export_named, .export_named_type => {
                const data = ctx.nodeData(member);
                const extra_idx = @intFromEnum(data.extra);
                if (extra_idx + 3 >= ctx.ast.extra_data.items.len) continue;
                const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
                if (decl_raw == @intFromEnum(NodeIndex.none)) continue;
                const decl_node: NodeIndex = @enumFromInt(decl_raw);
                if (ctx.nodeTag(decl_node) == .ts_module_declaration and !isDeclareNode(ctx, decl_node)) {
                    const ns_data = ctx.nodeData(decl_node);
                    const ns_extra = @intFromEnum(ns_data.extra);
                    const ns_body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_extra + 1]);
                    if (ns_body != .none and ctx.nodeTag(ns_body) == .ts_module_block) {
                        const body_data = ctx.nodeData(ns_body);
                        const body_extra = @intFromEnum(body_data.extra);
                        const body_start = ctx.ast.extra_data.items[body_extra];
                        const body_end = ctx.ast.extra_data.items[body_extra + 1];
                        if (nsNeedsEmptyStub(ctx, body_start, body_end)) return true;
                    }
                    continue;
                }
            },
            else => {},
        }

        const src = getNodeSourceText(ctx, member);
        if (std.mem.indexOf(u8, src, "declare class") != null) return true;
        if (std.mem.indexOf(u8, src, "declare abstract class") != null) return true;
        if (std.mem.indexOf(u8, src, "declare function") != null) return true;
        if (std.mem.indexOf(u8, src, "declare enum") != null) return true;
        if (std.mem.indexOf(u8, src, "declare var") != null) return true;
        if (std.mem.indexOf(u8, src, "declare let") != null) return true;
        if (std.mem.indexOf(u8, src, "declare const") != null) return true;
    }
    return false;
}

/// Check if a node appears directly in the program body (top level).
fn isInProgramBody(ctx: *TransformContext, node: NodeIndex) bool {
    const tags = ctx.ast.nodes.items(.tag);
    if (tags.len == 0 or tags[0] != .program) return false;

    const program_data = ctx.ast.nodes.items(.data)[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    const node_raw = @intFromEnum(node);
    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (stmt_raw == node_raw) return true;
        // Also check if it's inside an export_named at program level
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        const tag = tags[@intFromEnum(stmt)];
        if (tag == .export_named) {
            const ed = ctx.ast.nodes.items(.data)[@intFromEnum(stmt)];
            const eidx = @intFromEnum(ed.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                if (decl_raw == node_raw) return true;
            }
        }
    }
    return false;
}

fn programHasTopLevelValueTypeSyntax(ctx: *TransformContext) bool {
    const tags = ctx.ast.nodes.items(.tag);
    if (tags.len == 0 or tags[0] != .program) return false;

    const program_data = ctx.ast.nodes.items(.data)[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        const tag = ctx.nodeTag(stmt);
        switch (tag) {
            .var_declaration, .let_declaration, .const_declaration => {
                const src = getNodeSourceText(ctx, stmt);
                if (std.mem.indexOf(u8, src, ":") != null) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Check if a name already exists as a class/enum/function declaration at the same level.
/// Check if a name is declared by a function, class, or enum in a given body range.
/// Used to detect when a nested namespace name matches a sibling declaration.
/// Get the function/class name from a body member (for pre-scan clobbering detection).
fn getBodyMemberFuncName(ctx: *TransformContext, member: NodeIndex, tag: Node.Tag) ?[]const u8 {
    const datas = ctx.ast.nodes.items(.data);
    const tags = ctx.ast.nodes.items(.tag);
    switch (tag) {
        .function_declaration, .async_function_declaration => {
            const fd = datas[@intFromEnum(member)];
            const fextra = @intFromEnum(fd.extra);
            if (fextra < ctx.ast.extra_data.items.len) {
                const name_tok_raw = ctx.ast.extra_data.items[fextra];
                if (name_tok_raw != @intFromEnum(NodeIndex.none) and name_tok_raw > 0 and name_tok_raw < ctx.ast.tokens.len) {
                    const tok: TokenIndex = @enumFromInt(name_tok_raw);
                    return ctx.tokenSlice(tok);
                }
            }
        },
        .class_declaration => {
            if (isDeclareClass(ctx, member)) return null;
            const cd = datas[@intFromEnum(member)];
            const cextra = @intFromEnum(cd.extra);
            if (cextra < ctx.ast.extra_data.items.len) {
                const name_tok_raw = ctx.ast.extra_data.items[cextra];
                if (name_tok_raw != @intFromEnum(NodeIndex.none) and name_tok_raw > 0 and name_tok_raw < ctx.ast.tokens.len) {
                    const tok: TokenIndex = @enumFromInt(name_tok_raw);
                    return ctx.tokenSlice(tok);
                }
            }
        },
        .export_named => {
            // Check if the export wraps a function/class
            const ed = datas[@intFromEnum(member)];
            const eidx = @intFromEnum(ed.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                if (decl_raw != @intFromEnum(NodeIndex.none)) {
                    const decl_node: NodeIndex = @enumFromInt(decl_raw);
                    const dtag = tags[@intFromEnum(decl_node)];
                    return getBodyMemberFuncName(ctx, decl_node, dtag);
                }
            }
        },
        else => {},
    }
    return null;
}

fn isSiblingDeclaredInBody(ctx: *TransformContext, name: []const u8, body_start: u32, body_end: u32) bool {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    for (ctx.ast.extra_data.items[body_start..body_end]) |member_raw| {
        const member: NodeIndex = @enumFromInt(member_raw);
        if (member == .none) continue;
        const tag = tags[@intFromEnum(member)];
        switch (tag) {
            .function_declaration, .async_function_declaration => {
                const fd = datas[@intFromEnum(member)];
                const fextra = @intFromEnum(fd.extra);
                if (fextra < ctx.ast.extra_data.items.len) {
                    const name_tok_raw = ctx.ast.extra_data.items[fextra];
                    if (name_tok_raw != @intFromEnum(NodeIndex.none) and name_tok_raw > 0 and name_tok_raw < ctx.ast.tokens.len) {
                        const tok: TokenIndex = @enumFromInt(name_tok_raw);
                        if (std.mem.eql(u8, ctx.tokenSlice(tok), name)) return true;
                    }
                }
            },
            .class_declaration => {
                if (isDeclareClass(ctx, member)) continue;
                const cd = datas[@intFromEnum(member)];
                const cextra = @intFromEnum(cd.extra);
                if (cextra < ctx.ast.extra_data.items.len) {
                    const name_tok_raw = ctx.ast.extra_data.items[cextra];
                    if (name_tok_raw != @intFromEnum(NodeIndex.none) and name_tok_raw > 0 and name_tok_raw < ctx.ast.tokens.len) {
                        const tok: TokenIndex = @enumFromInt(name_tok_raw);
                        if (std.mem.eql(u8, ctx.tokenSlice(tok), name)) return true;
                    }
                }
            },
            .ts_enum_declaration => {
                if (isDeclareNode(ctx, member)) continue;
                const ed = datas[@intFromEnum(member)];
                const eextra = @intFromEnum(ed.extra);
                if (eextra < ctx.ast.extra_data.items.len) {
                    const name_n: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eextra]);
                    if (name_n != .none) {
                        const nt = ctx.mainToken(name_n);
                        if (std.mem.eql(u8, ctx.tokenSlice(nt), name)) return true;
                    }
                }
            },
            .export_named => {
                // Check if the export wraps a function/class/enum with this name
                const ed = datas[@intFromEnum(member)];
                const eidx = @intFromEnum(ed.extra);
                if (eidx + 3 < ctx.ast.extra_data.items.len) {
                    const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                    if (decl_raw != @intFromEnum(NodeIndex.none)) {
                        const decl_node: NodeIndex = @enumFromInt(decl_raw);
                        const dtag = tags[@intFromEnum(decl_node)];
                        switch (dtag) {
                            .function_declaration, .async_function_declaration => {
                                const fd = datas[@intFromEnum(decl_node)];
                                const fextra = @intFromEnum(fd.extra);
                                if (fextra < ctx.ast.extra_data.items.len) {
                                    const nt_raw = ctx.ast.extra_data.items[fextra];
                                    if (nt_raw != @intFromEnum(NodeIndex.none) and nt_raw > 0 and nt_raw < ctx.ast.tokens.len) {
                                        const tok: TokenIndex = @enumFromInt(nt_raw);
                                        if (std.mem.eql(u8, ctx.tokenSlice(tok), name)) return true;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn isClobberingExistingDecl(ctx: *TransformContext, name: []const u8) bool {
    // Check if there's a class, enum, or function with the same name
    // in the program body. This is a simplified check.
    const tags = ctx.ast.nodes.items(.tag);
    if (tags.len == 0) return false;
    if (tags[0] != .program) return false;

    const program_data = ctx.ast.nodes.items(.data)[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        const tag = tags[@intFromEnum(stmt)];
        switch (tag) {
            .class_declaration => {
                // extra[0] = name TOKEN (not node)
                const cd = ctx.ast.nodes.items(.data)[@intFromEnum(stmt)];
                const cextra = @intFromEnum(cd.extra);
                const name_tok_raw = ctx.ast.extra_data.items[cextra];
                if (name_tok_raw != @intFromEnum(NodeIndex.none) and name_tok_raw > 0) {
                    const tok: TokenIndex = @enumFromInt(name_tok_raw);
                    if (std.mem.eql(u8, ctx.tokenSlice(tok), name)) return true;
                }
            },
            .ts_enum_declaration => {
                // extra[0] = name NODE
                const ed = ctx.ast.nodes.items(.data)[@intFromEnum(stmt)];
                const eextra = @intFromEnum(ed.extra);
                const name_n: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eextra]);
                if (name_n != .none) {
                    const nt = ctx.mainToken(name_n);
                    if (std.mem.eql(u8, ctx.tokenSlice(nt), name)) return true;
                }
            },
            .function_declaration, .async_function_declaration => {
                // extra[0] = name NODE
                const fd = ctx.ast.nodes.items(.data)[@intFromEnum(stmt)];
                const fextra = @intFromEnum(fd.extra);
                const name_n: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[fextra]);
                if (name_n != .none) {
                    const nt = ctx.mainToken(name_n);
                    if (std.mem.eql(u8, ctx.tokenSlice(nt), name)) return true;
                }
            },
            .import_declaration => {
                // Check if any specifier has the same name
                const id = ctx.ast.nodes.items(.data)[@intFromEnum(stmt)];
                const iextra = @intFromEnum(id.extra);
                const ispecs_start = ctx.ast.extra_data.items[iextra + 1];
                const ispecs_end = ctx.ast.extra_data.items[iextra + 2];
                for (ctx.ast.extra_data.items[ispecs_start..ispecs_end]) |spec_raw| {
                    const spec: NodeIndex = @enumFromInt(spec_raw);
                    if (spec == .none) continue;
                    const spec_tag = tags[@intFromEnum(spec)];
                    if (spec_tag == .import_default or spec_tag == .import_namespace) {
                        const st = ctx.ast.nodes.items(.main_token)[@intFromEnum(spec)];
                        if (std.mem.eql(u8, ctx.tokenSlice(st), name)) return true;
                    }
                }
            },
            .export_named => {
                // Check if exported declaration has the same name
                const ed = ctx.ast.nodes.items(.data)[@intFromEnum(stmt)];
                const eextra = @intFromEnum(ed.extra);
                if (eextra + 3 < ctx.ast.extra_data.items.len) {
                    const decl_raw = ctx.ast.extra_data.items[eextra + 3];
                    if (decl_raw != @intFromEnum(NodeIndex.none)) {
                        const dn: NodeIndex = @enumFromInt(decl_raw);
                        const dtag = tags[@intFromEnum(dn)];
                        if (dtag == .class_declaration) {
                            // extra[0] = name TOKEN
                            const cd = ctx.ast.nodes.items(.data)[@intFromEnum(dn)];
                            const cextra2 = @intFromEnum(cd.extra);
                            const ntok_raw = ctx.ast.extra_data.items[cextra2];
                            if (ntok_raw != @intFromEnum(NodeIndex.none) and ntok_raw > 0) {
                                const tok: TokenIndex = @enumFromInt(ntok_raw);
                                if (std.mem.eql(u8, ctx.tokenSlice(tok), name)) return true;
                            }
                        } else if (dtag == .function_declaration or dtag == .async_function_declaration) {
                            const fd = ctx.ast.nodes.items(.data)[@intFromEnum(dn)];
                            const fextra2 = @intFromEnum(fd.extra);
                            const name_n: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[fextra2]);
                            if (name_n != .none) {
                                const nt = ctx.mainToken(name_n);
                                if (std.mem.eql(u8, ctx.tokenSlice(nt), name)) return true;
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

/// Generate the body of a namespace IIFE.
fn generateNamespaceBody(
    ctx: *TransformContext,
    body_start: u32,
    body_end: u32,
    param_name: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
) error{OutOfMemory}!void {
    // Pre-scan: mark function/class/enum names as "seen" so that a namespace
    // with the same name doesn't emit a redundant `let` declaration.
    for (ctx.ast.extra_data.items[body_start..body_end]) |pre_raw| {
        const pre_node: NodeIndex = @enumFromInt(pre_raw);
        if (pre_node == .none) continue;
        const pre_tag = ctx.nodeTag(pre_node);
        if (pre_tag == .removed) continue;
        const fname = getBodyMemberFuncName(ctx, pre_node, pre_tag);
        if (fname) |fn_name| {
            ctx.seen_enum_names.put(ctx.allocator, fn_name, {}) catch {};
        }
    }
    for (ctx.ast.extra_data.items[body_start..body_end]) |member_raw| {
        const member: NodeIndex = @enumFromInt(member_raw);
        if (member == .none) continue;
        const tag = ctx.nodeTag(member);
        if (tag == .removed) continue;

        switch (tag) {
            // Type-only declarations — skip
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_declare_function,
            .ts_declare_variable,
            .ts_declare_method,
            .import_declaration_type,
            .ts_index_signature,
            .ts_import_equals_declaration,
            .ts_namespace_export_declaration,
            => continue,
            .export_named, .export_named_type => {
                // Check if it has a declaration child
                _ = try generateExportedMember(ctx, member, param_name, buf, indent);
            },
            .var_declaration, .let_declaration, .const_declaration => {
                try buf.appendSlice(ctx.allocator, indent);
                try generateVarDeclStripped(ctx, member, tag, buf);
                try buf.appendSlice(ctx.allocator, "\n");
            },
            .expression_statement => {
                try buf.appendSlice(ctx.allocator, indent);
                const src = getNodeSourceText(ctx, member);
                try buf.appendSlice(ctx.allocator, src);
                // Add semicolon if not already present
                if (src.len == 0 or src[src.len - 1] != ';') {
                    try buf.appendSlice(ctx.allocator, ";");
                }
                try buf.appendSlice(ctx.allocator, "\n");
            },
            .function_declaration, .async_function_declaration => {
                const src = getNodeGeneratedSource(ctx, member);
                try appendIndentedMultiline(ctx.allocator, buf, indent, src);
            },
            .class_declaration => {
                if (isDeclareClass(ctx, member)) continue;
                const src = getNodeGeneratedSource(ctx, member);
                try appendIndentedMultiline(ctx.allocator, buf, indent, src);
            },
            .ts_module_declaration => {
                if (isDeclareNode(ctx, member)) continue;
                // Nested namespace — check if it has runtime members
                const ns_data2 = ctx.nodeData(member);
                const ns_extra2 = @intFromEnum(ns_data2.extra);
                const ns_name_node2: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_extra2]);
                const ns_body_node2: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_extra2 + 1]);
                if (ns_body_node2 != .none and ctx.nodeTag(ns_body_node2) == .ts_module_block) {
                    const nb_data2 = ctx.nodeData(ns_body_node2);
                    const nb_extra2 = @intFromEnum(nb_data2.extra);
                    const nb_start2 = ctx.ast.extra_data.items[nb_extra2];
                    const nb_end2 = ctx.ast.extra_data.items[nb_extra2 + 1];
                    const ns_name_tok2 = ctx.mainToken(ns_name_node2);
                    const inner_ns_name = ctx.tokenSlice(ns_name_tok2);
                    // Skip if all type-only and no declare members
                    if (!nsHasRuntimeMembers(ctx, nb_start2, nb_end2) and !nsNeedsEmptyStub(ctx, nb_start2, nb_end2)) {
                        // Allocate a param name for counter consistency even when skipping
                        _ = generateUniqueParamName(ctx, inner_ns_name);
                        // Also pre-allocate for nested namespaces inside the skipped body
                        preAllocateNestedParamNames(ctx, nb_start2, nb_end2);
                        continue;
                    }
                    // Check if a sibling function/class/enum already declares this name.
                    // If so, mark as "seen" to suppress the `let` declaration.
                    if (isSiblingDeclaredInBody(ctx, inner_ns_name, body_start, body_end)) {
                        ctx.seen_enum_names.put(ctx.allocator, inner_ns_name, {}) catch {};
                    }
                    try generateNestedNamespaceIife(ctx, inner_ns_name, nb_start2, nb_end2, false, buf, indent);
                } else {
                    try buf.appendSlice(ctx.allocator, indent);
                    const src = getNodeSourceText(ctx, member);
                    try buf.appendSlice(ctx.allocator, src);
                    try buf.appendSlice(ctx.allocator, "\n");
                }
            },
            .ts_enum_declaration => {
                if (isDeclareNode(ctx, member)) continue;
                const member_data = ctx.nodeData(member);
                const member_extra = @intFromEnum(member_data.extra);
                const is_const = member_extra + 3 < ctx.ast.extra_data.items.len and ctx.ast.extra_data.items[member_extra + 3] != 0;
                if (g_config.optimize_const_enums and is_const) {
                    try generateNestedConstEnumObject(ctx, member, param_name, buf, indent);
                } else {
                    try generateNestedEnumIife(ctx, member, buf, indent);
                }
            },
            else => {
                try buf.appendSlice(ctx.allocator, indent);
                const src = getNodeSourceText(ctx, member);
                try buf.appendSlice(ctx.allocator, src);
                try buf.appendSlice(ctx.allocator, "\n");
            },
        }
    }
}

/// Generate code for an exported member inside a namespace IIFE.
/// Returns true if runtime content was emitted, false if the member was type-only.
fn generateExportedMember(
    ctx: *TransformContext,
    export_node: NodeIndex,
    param_name: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
) error{OutOfMemory}!bool {
    const data = ctx.nodeData(export_node);
    const extra_idx = @intFromEnum(data.extra);

    // Check for declaration child
    if (extra_idx + 3 >= ctx.ast.extra_data.items.len) return false;
    const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
    if (decl_raw == @intFromEnum(NodeIndex.none)) return false;

    const decl_node: NodeIndex = @enumFromInt(decl_raw);
    const decl_tag = ctx.nodeTag(decl_node);

    // Check if the export wrapper is export_named_type — all such are type-only
    const export_tag = ctx.nodeTag(export_node);
    if (export_tag == .export_named_type) {
        return false;
    }

    switch (decl_tag) {
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        .ts_declare_function,
        .ts_declare_variable,
        .ts_declare_method,
        => {
            // Type-only export — skip (no runtime content)
            return false;
        },
        .class_declaration => {
            if (isDeclareClass(ctx, decl_node)) {
                return false;
            }
            // export class Name { } → class Name { } _N.Name = Name;
            // extra[0] = name TOKEN
            const cd = ctx.nodeData(decl_node);
            const cextra = @intFromEnum(cd.extra);
            const name_tok_raw = ctx.ast.extra_data.items[cextra];
            const src = getNodeGeneratedSource(ctx, decl_node);
            try appendIndentedMultiline(ctx.allocator, buf, indent, src);
            if (name_tok_raw != @intFromEnum(NodeIndex.none) and name_tok_raw > 0) {
                const tok: TokenIndex = @enumFromInt(name_tok_raw);
                const name_text = ctx.tokenSlice(tok);
                try buf.appendSlice(ctx.allocator, indent);
                try buf.appendSlice(ctx.allocator, param_name);
                try buf.appendSlice(ctx.allocator, ".");
                try buf.appendSlice(ctx.allocator, name_text);
                try buf.appendSlice(ctx.allocator, " = ");
                try buf.appendSlice(ctx.allocator, name_text);
                try buf.appendSlice(ctx.allocator, ";\n");
            }
            return true;
        },
        .ts_enum_declaration => {
            if (isDeclareNode(ctx, decl_node)) {
                return false;
            }
            const de = ctx.nodeData(decl_node);
            const de_extra = @intFromEnum(de.extra);
            const is_const = de_extra + 3 < ctx.ast.extra_data.items.len and ctx.ast.extra_data.items[de_extra + 3] != 0;
            if (g_config.optimize_const_enums and is_const) {
                try generateNestedConstEnumObject(ctx, decl_node, param_name, buf, indent);
                return true;
            }

            // Exported enum — generate IIFE inline with export assignment
            try generateNestedEnumIife(ctx, decl_node, buf, indent);
            // Add export assignment: _N.EnumName = EnumName;
            const en_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[de_extra]);
            const en_tok = ctx.mainToken(en_node);
            const en_name = ctx.tokenSlice(en_tok);
            try buf.appendSlice(ctx.allocator, indent);
            try buf.appendSlice(ctx.allocator, param_name);
            try buf.appendSlice(ctx.allocator, ".");
            try buf.appendSlice(ctx.allocator, en_name);
            try buf.appendSlice(ctx.allocator, " = ");
            try buf.appendSlice(ctx.allocator, en_name);
            try buf.appendSlice(ctx.allocator, ";\n");
            return true;
        },
        .ts_module_declaration => {
            if (isDeclareNode(ctx, decl_node)) {
                return false;
            }
            // Exported nested namespace — recursively transform
            const ns_d = ctx.nodeData(decl_node);
            const ns_e = @intFromEnum(ns_d.extra);
            const ns_nn: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_e]);
            const ns_bn: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[ns_e + 1]);
            if (ns_bn != .none and ctx.nodeTag(ns_bn) == .ts_module_block) {
                const nb_d = ctx.nodeData(ns_bn);
                const nb_e = @intFromEnum(nb_d.extra);
                const nb_s = ctx.ast.extra_data.items[nb_e];
                const nb_en = ctx.ast.extra_data.items[nb_e + 1];
                const ns_nt = ctx.mainToken(ns_nn);
                const inner_name = ctx.tokenSlice(ns_nt);
                // Check if nested namespace has runtime members — if not, skip entirely
                if (!nsHasRuntimeMembers(ctx, nb_s, nb_en) and !nsNeedsEmptyStub(ctx, nb_s, nb_en)) {
                    // Allocate param name for counter consistency
                    _ = generateUniqueParamName(ctx, inner_name);
                    preAllocateNestedParamNames(ctx, nb_s, nb_en);
                    return false;
                }
                try generateNestedNamespaceIifeExported(ctx, inner_name, nb_s, nb_en, param_name, buf, indent);
            } else {
                try buf.appendSlice(ctx.allocator, indent);
                const src = getNodeSourceText(ctx, decl_node);
                try buf.appendSlice(ctx.allocator, src);
                try buf.appendSlice(ctx.allocator, "\n");
            }
            return true;
        },
        .function_declaration, .async_function_declaration => {
            // export function f() {} → function f() {} _N.f = f;
            const fd = ctx.nodeData(decl_node);
            const fextra = @intFromEnum(fd.extra);
            // extra[0] is a TOKEN index (not node)
            const name_tok_raw = ctx.ast.extra_data.items[fextra];
            const src = getNodeGeneratedSource(ctx, decl_node);
            try appendIndentedMultiline(ctx.allocator, buf, indent, src);
            if (name_tok_raw != @intFromEnum(NodeIndex.none) and name_tok_raw > 0 and name_tok_raw < ctx.ast.tokens.len) {
                const tok: TokenIndex = @enumFromInt(name_tok_raw);
                const name_text = ctx.tokenSlice(tok);
                try buf.appendSlice(ctx.allocator, indent);
                try buf.appendSlice(ctx.allocator, param_name);
                try buf.appendSlice(ctx.allocator, ".");
                try buf.appendSlice(ctx.allocator, name_text);
                try buf.appendSlice(ctx.allocator, " = ");
                try buf.appendSlice(ctx.allocator, name_text);
                try buf.appendSlice(ctx.allocator, ";\n");
            }
            return true;
        },
        .var_declaration, .let_declaration, .const_declaration => {
            // export const x = 1; → const x = _N.x = 1;
            try generateExportedVarDecl(ctx, decl_node, decl_tag, param_name, buf, indent);
            return true;
        },
        else => {
            try buf.appendSlice(ctx.allocator, indent);
            const src = getNodeSourceText(ctx, decl_node);
            try buf.appendSlice(ctx.allocator, src);
            try buf.appendSlice(ctx.allocator, "\n");
            return true;
        },
    }
}

/// Generate code for `export const/let/var x = value` → `const x = _N.x = value`
/// Generate a var/let/const declaration with type annotations stripped.
fn generateVarDeclStripped(
    ctx: *TransformContext,
    decl_node: NodeIndex,
    decl_tag: Node.Tag,
    buf: *std.ArrayListUnmanaged(u8),
) error{OutOfMemory}!void {
    const dd = ctx.nodeData(decl_node);
    const dextra = @intFromEnum(dd.extra);
    const decls_start = ctx.ast.extra_data.items[dextra];
    const decls_end = ctx.ast.extra_data.items[dextra + 1];

    const keyword = switch (decl_tag) {
        .const_declaration => "const",
        .let_declaration => "let",
        else => "var",
    };

    try buf.appendSlice(ctx.allocator, keyword);
    try buf.appendSlice(ctx.allocator, " ");

    var first_decl = true;
    for (ctx.ast.extra_data.items[decls_start..decls_end]) |declarator_raw| {
        const declarator: NodeIndex = @enumFromInt(declarator_raw);
        if (declarator == .none) continue;
        if (ctx.nodeTag(declarator) != .declarator) continue;

        if (!first_decl) {
            try buf.appendSlice(ctx.allocator, ", ");
        }
        first_decl = false;

        const decl_data = ctx.nodeData(declarator);
        const binding = decl_data.binary.lhs;
        const init = decl_data.binary.rhs;

        if (binding != .none) {
            const btag = ctx.nodeTag(binding);
            if (btag == .identifier) {
                // Use token text directly to avoid including type annotations
                const tok = ctx.mainToken(binding);
                try buf.appendSlice(ctx.allocator, ctx.tokenSlice(tok));
            } else {
                // For destructuring patterns, use source text (may include annotations)
                const binding_src = getNodeSourceText(ctx, binding);
                try buf.appendSlice(ctx.allocator, binding_src);
            }
        }

        if (init != .none) {
            try buf.appendSlice(ctx.allocator, " = ");
            const init_src = getNodeSourceText(ctx, init);
            try buf.appendSlice(ctx.allocator, init_src);
        }
    }

    try buf.appendSlice(ctx.allocator, ";");
}

fn generateExportedVarDecl(
    ctx: *TransformContext,
    decl_node: NodeIndex,
    decl_tag: Node.Tag,
    param_name: []const u8,
    buf: *std.ArrayListUnmanaged(u8),
    indent: []const u8,
) error{OutOfMemory}!void {
    const dd = ctx.nodeData(decl_node);
    const dextra = @intFromEnum(dd.extra);
    const decls_start = ctx.ast.extra_data.items[dextra];
    const decls_end = ctx.ast.extra_data.items[dextra + 1];

    const keyword = switch (decl_tag) {
        .const_declaration => "const",
        .let_declaration => "let",
        else => "var",
    };

    // Check if any declarator has a destructuring pattern
    var has_destructuring = false;
    var all_simple_array_destructuring = true;
    for (ctx.ast.extra_data.items[decls_start..decls_end]) |declarator_raw| {
        const declarator: NodeIndex = @enumFromInt(declarator_raw);
        if (declarator == .none) continue;
        if (ctx.nodeTag(declarator) != .declarator) continue;
        const decl_data = ctx.nodeData(declarator);
        const binding = decl_data.binary.lhs;
        if (binding == .none) continue;
        const binding_tag = ctx.nodeTag(binding);
        if (binding_tag != .identifier) {
            has_destructuring = true;
            if (!isSimpleArrayBindingPattern(ctx, binding)) {
                all_simple_array_destructuring = false;
            }
        } else {
            all_simple_array_destructuring = false;
        }
    }

    if (has_destructuring) {
        if (all_simple_array_destructuring) return;
        // Destructuring declaration: emit the full declaration stripped of `export`,
        // then add _N.name = name for each bound name.
        const decl_src = getNodeGeneratedSource(ctx, decl_node);
        try appendIndentedMultiline(ctx.allocator, buf, indent, decl_src);

        // Collect bound names from destructuring patterns and emit export assignments
        var rest_bound_names: std.ArrayListUnmanaged([]const u8) = .empty;
        var bound_names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (ctx.ast.extra_data.items[decls_start..decls_end]) |declarator_raw| {
            const declarator: NodeIndex = @enumFromInt(declarator_raw);
            if (declarator == .none) continue;
            if (ctx.nodeTag(declarator) != .declarator) continue;
            const decl_data = ctx.nodeData(declarator);
            const binding = decl_data.binary.lhs;
            if (binding == .none) continue;
            if (isSimpleArrayBindingPattern(ctx, binding)) continue;
            collectExportedBoundNames(ctx, binding, &rest_bound_names, &bound_names, false);
        }
        if (rest_bound_names.items.len > 0 or bound_names.items.len > 0) {
            try buf.appendSlice(ctx.allocator, indent);
            var emitted_any = false;
            for (rest_bound_names.items) |name| {
                if (emitted_any) try buf.appendSlice(ctx.allocator, ", ");
                emitted_any = true;
                try buf.appendSlice(ctx.allocator, param_name);
                try buf.appendSlice(ctx.allocator, ".");
                try buf.appendSlice(ctx.allocator, name);
                try buf.appendSlice(ctx.allocator, " = ");
                try buf.appendSlice(ctx.allocator, name);
            }
            for (bound_names.items) |name| {
                if (emitted_any) try buf.appendSlice(ctx.allocator, ", ");
                emitted_any = true;
                try buf.appendSlice(ctx.allocator, param_name);
                try buf.appendSlice(ctx.allocator, ".");
                try buf.appendSlice(ctx.allocator, name);
                try buf.appendSlice(ctx.allocator, " = ");
                try buf.appendSlice(ctx.allocator, name);
            }
            try buf.appendSlice(ctx.allocator, ";\n");
        }
    } else {
        // Simple identifier bindings: use the inline _N.x = value pattern
        for (ctx.ast.extra_data.items[decls_start..decls_end]) |declarator_raw| {
            const declarator: NodeIndex = @enumFromInt(declarator_raw);
            if (declarator == .none) continue;
            const dtag = ctx.nodeTag(declarator);
            if (dtag != .declarator) continue;

            const decl_data = ctx.nodeData(declarator);
            const binding = decl_data.binary.lhs;
            const init = decl_data.binary.rhs;

            if (binding == .none) continue;
            const bt = ctx.mainToken(binding);
            const var_name = ctx.tokenSlice(bt);

            try buf.appendSlice(ctx.allocator, indent);
            try buf.appendSlice(ctx.allocator, keyword);
            try buf.appendSlice(ctx.allocator, " ");
            try buf.appendSlice(ctx.allocator, var_name);
            try buf.appendSlice(ctx.allocator, " = ");
            try buf.appendSlice(ctx.allocator, param_name);
            try buf.appendSlice(ctx.allocator, ".");
            try buf.appendSlice(ctx.allocator, var_name);
            try buf.appendSlice(ctx.allocator, " = ");

            if (init != .none) {
                const init_src = getNodeSourceText(ctx, init);
                try buf.appendSlice(ctx.allocator, init_src);
            } else {
                try buf.appendSlice(ctx.allocator, "undefined");
            }
            try buf.appendSlice(ctx.allocator, ";\n");
        }
    }
}

/// Collect all bound identifier names from a destructuring pattern.
/// For `{ a, b: c }` collects `a` and `c`.
/// For `[a, { b: [c] }]` collects `a` and `c`.
fn collectBoundNames(ctx: *TransformContext, pattern: NodeIndex, names: *std.ArrayListUnmanaged([]const u8)) void {
    if (pattern == .none) return;
    const tag = ctx.nodeTag(pattern);
    switch (tag) {
        .identifier => {
            const tok = ctx.mainToken(pattern);
            const name = ctx.tokenSlice(tok);
            names.append(ctx.allocator, name) catch {};
        },
        .object_pattern => {
            // extra[start..end] = properties
            const data = ctx.nodeData(pattern);
            const extra_idx = @intFromEnum(data.extra);
            const props_start = ctx.ast.extra_data.items[extra_idx];
            const props_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[props_start..props_end]) |prop_raw| {
                const prop: NodeIndex = @enumFromInt(prop_raw);
                if (prop == .none) continue;
                const ptag = ctx.nodeTag(prop);
                if (ptag == .rest_element) {
                    // ...rest
                    const pd = ctx.nodeData(prop);
                    collectBoundNames(ctx, pd.unary, names);
                } else if (ptag == .shorthand_property) {
                    // { a } — shorthand property, the name itself is the binding
                    const tok = ctx.mainToken(prop);
                    const name = ctx.tokenSlice(tok);
                    names.append(ctx.allocator, name) catch {};
                } else if (ptag == .property) {
                    // { key: value } — value is the binding
                    const pd = ctx.nodeData(prop);
                    collectBoundNames(ctx, pd.binary.rhs, names);
                } else if (ptag == .assignment_pattern) {
                    // { a = 1 } — lhs is identifier or nested pattern
                    const pd = ctx.nodeData(prop);
                    collectBoundNames(ctx, pd.binary.lhs, names);
                } else {
                    // Unknown property type — skip
                }
            }
        },
        .array_pattern => {
            // extra[start..end] = elements
            const data = ctx.nodeData(pattern);
            const extra_idx = @intFromEnum(data.extra);
            const elts_start = ctx.ast.extra_data.items[extra_idx];
            const elts_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[elts_start..elts_end]) |elt_raw| {
                const elt: NodeIndex = @enumFromInt(elt_raw);
                if (elt == .none) continue;
                collectBoundNames(ctx, elt, names);
            }
        },
        .rest_element => {
            const data = ctx.nodeData(pattern);
            collectBoundNames(ctx, data.unary, names);
        },
        .assignment_pattern => {
            // pattern = default
            const data = ctx.nodeData(pattern);
            collectBoundNames(ctx, data.binary.lhs, names);
        },
        else => {},
    }
}

fn appendUniqueBoundName(ctx: *TransformContext, names: *std.ArrayListUnmanaged([]const u8), name: []const u8) void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    names.append(ctx.allocator, name) catch {};
}

fn isSimpleArrayBindingPattern(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .array_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    const elts_start = ctx.ast.extra_data.items[extra_idx];
    const elts_end = ctx.ast.extra_data.items[extra_idx + 1];
    var saw_identifier = false;
    for (ctx.ast.extra_data.items[elts_start..elts_end]) |elt_raw| {
        const elt: NodeIndex = @enumFromInt(elt_raw);
        if (elt == .none) continue;
        if (ctx.nodeTag(elt) != .identifier) return false;
        saw_identifier = true;
    }
    return saw_identifier;
}

fn collectExportedBoundNames(
    ctx: *TransformContext,
    pattern: NodeIndex,
    rest_names: *std.ArrayListUnmanaged([]const u8),
    names: *std.ArrayListUnmanaged([]const u8),
    prefer_rest: bool,
) void {
    if (pattern == .none) return;
    const tag = ctx.nodeTag(pattern);
    switch (tag) {
        .identifier => {
            const name = ctx.tokenSlice(ctx.mainToken(pattern));
            if (prefer_rest) {
                appendUniqueBoundName(ctx, rest_names, name);
            } else {
                appendUniqueBoundName(ctx, names, name);
            }
        },
        .object_pattern => {
            const data = ctx.nodeData(pattern);
            const extra_idx = @intFromEnum(data.extra);
            const props_start = ctx.ast.extra_data.items[extra_idx];
            const props_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[props_start..props_end]) |prop_raw| {
                const prop: NodeIndex = @enumFromInt(prop_raw);
                if (prop == .none) continue;
                const ptag = ctx.nodeTag(prop);
                if (ptag == .rest_element) {
                    collectExportedBoundNames(ctx, ctx.nodeData(prop).unary, rest_names, names, true);
                } else if (ptag == .shorthand_property) {
                    const value = ctx.nodeData(prop).unary;
                    if (value != .none) {
                        collectExportedBoundNames(ctx, value, rest_names, names, prefer_rest);
                    } else {
                        const name = ctx.tokenSlice(ctx.mainToken(prop));
                        if (prefer_rest) {
                            appendUniqueBoundName(ctx, rest_names, name);
                        } else {
                            appendUniqueBoundName(ctx, names, name);
                        }
                    }
                } else if (ptag == .property) {
                    collectExportedBoundNames(ctx, ctx.nodeData(prop).binary.rhs, rest_names, names, prefer_rest);
                } else if (ptag == .assignment_pattern) {
                    collectExportedBoundNames(ctx, ctx.nodeData(prop).binary.lhs, rest_names, names, prefer_rest);
                }
            }
        },
        .array_pattern => {
            const data = ctx.nodeData(pattern);
            const extra_idx = @intFromEnum(data.extra);
            const elts_start = ctx.ast.extra_data.items[extra_idx];
            const elts_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[elts_start..elts_end]) |elt_raw| {
                const elt: NodeIndex = @enumFromInt(elt_raw);
                if (elt == .none) continue;
                collectExportedBoundNames(ctx, elt, rest_names, names, prefer_rest);
            }
        },
        .rest_element => collectExportedBoundNames(ctx, ctx.nodeData(pattern).unary, rest_names, names, true),
        .assignment_pattern => collectExportedBoundNames(ctx, ctx.nodeData(pattern).binary.lhs, rest_names, names, prefer_rest),
        else => {},
    }
}

// ────────────────────────────────────────────────────────────────────────
// End of namespace IIFE helpers
// ────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────
// Parameter Properties transform
// ────────────────────────────────────────────────────────────────────────

fn handleParameterProperties(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const tag = ctx.nodeTag(idx);
    const extra_idx = @intFromEnum(data.extra);

    // class_method: extra[0]=key, [1]=params_start, [2]=params_end, [3]=body
    // method_definition: same layout
    const key: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const params_start = ctx.ast.extra_data.items[extra_idx + 1];
    const params_end = ctx.ast.extra_data.items[extra_idx + 2];
    const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
    _ = tag;

    // Check if this is a constructor
    if (key == .none) return;
    const key_tag = ctx.nodeTag(key);
    if (key_tag != .identifier) return;
    const key_tok = ctx.mainToken(key);
    const key_text = ctx.tokenSlice(key_tok);
    if (!std.mem.eql(u8, key_text, "constructor")) return;

    // Collect parameter property names (in order)
    var prop_names: [32][]const u8 = undefined;
    var prop_tokens: [32]TokenIndex = undefined;
    var prop_count: usize = 0;

    for (ctx.ast.extra_data.items[params_start..params_end]) |param_raw| {
        const param: NodeIndex = @enumFromInt(param_raw);
        if (param == .none) continue;
        if (ctx.nodeTag(param) != .ts_parameter_property) continue;

        // Get the inner parameter
        const pp_data = ctx.nodeData(param);
        const pp_extra = @intFromEnum(pp_data.extra);
        const inner_param: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[pp_extra]);

        // Find the identifier name (handle assignment_pattern: x = default)
        const name_info = getParamPropertyName(ctx, inner_param);
        if (name_info.name) |pname| {
            if (prop_count < 32) {
                prop_names[prop_count] = pname;
                prop_tokens[prop_count] = name_info.token;
                prop_count += 1;
            }
        }
    }

    if (prop_count == 0) return;
    if (body == .none) return;

    // Get the body block_statement
    const body_tag = ctx.nodeTag(body);
    if (body_tag != .block_statement) return;

    const body_data = ctx.nodeData(body);
    const body_extra = @intFromEnum(body_data.extra);
    const stmts_start = ctx.ast.extra_data.items[body_extra];
    const stmts_end = ctx.ast.extra_data.items[body_extra + 1];

    // Babel lowers a lone parameter property with a default initializer into a
    // body-local `let` binding plus the `this` assignment, instead of keeping a
    // default parameter in the signature.
    if (prop_count == 1 and params_end == params_start + 1 and stmts_start == stmts_end) {
        const param: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[params_start]);
        if (ctx.nodeTag(param) == .ts_parameter_property) {
            const pp_data = ctx.nodeData(param);
            const pp_extra = @intFromEnum(pp_data.extra);
            const inner_param: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[pp_extra]);
            if (ctx.nodeTag(inner_param) == .assignment_pattern) {
                const ap_data = ctx.nodeData(inner_param);
                const name_info = getParamPropertyName(ctx, ap_data.binary.lhs);
                const default_src = getNodeGeneratedSource(ctx, ap_data.binary.rhs);
                if (name_info.name) |_| {
                    const pname_tok = name_info.token;

                    const lhs_arg1 = ctx.addNewNode(.{
                        .tag = .identifier,
                        .main_token = pname_tok,
                        .data = .{ .none = {} },
                    }) catch return;

                    const arguments_node = ctx.addNewNode(.{
                        .tag = .identifier,
                        .main_token = pname_tok,
                        .data = .{ .none = {} },
                    }) catch return;
                    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(arguments_node), "arguments") catch return;

                    const arguments_length = ctx.addNewNode(.{
                        .tag = .identifier,
                        .main_token = pname_tok,
                        .data = .{ .none = {} },
                    }) catch return;
                    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(arguments_length), "arguments.length") catch return;

                    const zero_lhs = ctx.addNewNode(.{
                        .tag = .numeric_literal,
                        .main_token = pname_tok,
                        .data = .{ .none = {} },
                    }) catch return;
                    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(zero_lhs), "0") catch return;

                    const gt_zero = ctx.addNewNode(.{
                        .tag = .binary_expr,
                        .main_token = pname_tok,
                        .data = .{ .binary = .{ .lhs = arguments_length, .rhs = zero_lhs } },
                    }) catch return;
                    ctx.ast.operator_overrides.put(ctx.allocator, @intFromEnum(gt_zero), ">") catch return;

                    const arguments_node_2 = ctx.addNewNode(.{
                        .tag = .identifier,
                        .main_token = pname_tok,
                        .data = .{ .none = {} },
                    }) catch return;
                    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(arguments_node_2), "arguments") catch return;

                    const zero_rhs = ctx.addNewNode(.{
                        .tag = .numeric_literal,
                        .main_token = pname_tok,
                        .data = .{ .none = {} },
                    }) catch return;
                    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(zero_rhs), "0") catch return;

                    const arguments_zero = ctx.addNewNode(.{
                        .tag = .computed_member_expr,
                        .main_token = pname_tok,
                        .data = .{ .binary = .{ .lhs = arguments_node_2, .rhs = zero_rhs } },
                    }) catch return;

                    const undefined_node = ctx.addNewNode(.{
                        .tag = .identifier,
                        .main_token = pname_tok,
                        .data = .{ .none = {} },
                    }) catch return;
                    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(undefined_node), "undefined") catch return;

                    const not_undefined = ctx.addNewNode(.{
                        .tag = .binary_expr,
                        .main_token = pname_tok,
                        .data = .{ .binary = .{ .lhs = arguments_zero, .rhs = undefined_node } },
                    }) catch return;
                    ctx.ast.operator_overrides.put(ctx.allocator, @intFromEnum(not_undefined), "!==") catch return;

                    const arguments_ok = ctx.addNewNode(.{
                        .tag = .logical_expr,
                        .main_token = pname_tok,
                        .data = .{ .binary = .{ .lhs = gt_zero, .rhs = not_undefined } },
                    }) catch return;
                    ctx.ast.operator_overrides.put(ctx.allocator, @intFromEnum(arguments_ok), "&&") catch return;

                    const default_node = ctx.addNewNode(.{
                        .tag = .identifier,
                        .main_token = pname_tok,
                        .data = .{ .none = {} },
                    }) catch return;
                    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(default_node), default_src) catch return;

                    const cond_extra_start = ctx.addExtra(@intFromEnum(arguments_zero)) catch return;
                    _ = ctx.addExtra(@intFromEnum(default_node)) catch return;
                    const default_value = ctx.addNewNode(.{
                        .tag = .conditional_expr,
                        .main_token = pname_tok,
                        .data = .{ .binary = .{ .lhs = arguments_ok, .rhs = @enumFromInt(cond_extra_start) } },
                    }) catch return;

                    const declarator = ctx.addNewNode(.{
                        .tag = .declarator,
                        .main_token = pname_tok,
                        .data = .{ .binary = .{ .lhs = lhs_arg1, .rhs = default_value } },
                    }) catch return;

                    const decl_range_start = ctx.addExtra(@intFromEnum(declarator)) catch return;
                    const decl_range_end: u32 = @intCast(ctx.ast.extra_data.items.len);
                    const let_extra = ctx.addExtra(decl_range_start) catch return;
                    _ = ctx.addExtra(decl_range_end) catch return;
                    const let_decl = ctx.addNewNode(.{
                        .tag = .let_declaration,
                        .main_token = pname_tok,
                        .data = .{ .extra = @enumFromInt(let_extra) },
                    }) catch return;

                    var assignment_nodes: [32]u32 = undefined;
                    var assignment_count: usize = 0;
                    appendParameterPropertyAssignments(ctx, prop_names[0..prop_count], prop_tokens[0..prop_count], &assignment_nodes, &assignment_count);
                    if (assignment_count == 0) return;

                    const body_range_start: u32 = @intCast(ctx.ast.extra_data.items.len);
                    _ = ctx.addExtra(@intFromEnum(let_decl)) catch return;
                    _ = ctx.addExtra(assignment_nodes[0]) catch return;
                    const body_range_end: u32 = @intCast(ctx.ast.extra_data.items.len);
                    ctx.ast.extra_data.items[body_extra] = body_range_start;
                    ctx.ast.extra_data.items[body_extra + 1] = body_range_end;
                    ctx.ast.extra_data.items[extra_idx + 1] = params_end;
                    return;
                }
            }
        }
    }

    // Build fallback assignment nodes: this.name = name;
    var new_stmts: [32]u32 = undefined;
    var new_count: usize = 0;

    appendParameterPropertyAssignments(ctx, prop_names[0..prop_count], prop_tokens[0..prop_count], &new_stmts, &new_count);

    if (new_count == 0) return;

    if (insertAssignmentsAfterSuperInStatement(ctx, body, prop_names[0..prop_count], prop_tokens[0..prop_count])) {
        return;
    }

    // Build new statement range: [existing before insert_after] + [new assignments] + [existing after insert_after]
    const old_count = stmts_end - stmts_start;
    const total = old_count + @as(u32, @intCast(new_count));

    // Ensure capacity first
    ctx.ast.extra_data.ensureUnusedCapacity(ctx.allocator, total) catch return;

    const new_range_start: u32 = @intCast(ctx.ast.extra_data.items.len);
    const insert_offset: u32 = 0;

    // Copy statements before insert point
    var i: u32 = 0;
    while (i < insert_offset) : (i += 1) {
        ctx.ast.extra_data.appendAssumeCapacity(ctx.ast.extra_data.items[stmts_start + i]);
    }

    // Insert new assignment statements
    for (0..new_count) |ni| {
        ctx.ast.extra_data.appendAssumeCapacity(new_stmts[ni]);
    }

    // Copy statements after insert point
    while (i < old_count) : (i += 1) {
        ctx.ast.extra_data.appendAssumeCapacity(ctx.ast.extra_data.items[stmts_start + i]);
    }

    const new_range_end: u32 = @intCast(ctx.ast.extra_data.items.len);

    // Update block_statement's range pointers
    ctx.ast.extra_data.items[body_extra] = new_range_start;
    ctx.ast.extra_data.items[body_extra + 1] = new_range_end;
}

fn appendParameterPropertyAssignments(
    ctx: *TransformContext,
    prop_names: []const []const u8,
    prop_tokens: []const TokenIndex,
    out_nodes: *[32]u32,
    out_count: *usize,
) void {
    for (prop_names, prop_tokens) |pname, ptok| {
        const this_node = ctx.addNewNode(.{
            .tag = .this_expr,
            .main_token = ptok,
            .data = .{ .none = {} },
        }) catch return;

        _ = pname;

        const member_node = ctx.addNewNode(.{
            .tag = .member_expr,
            .main_token = ptok,
            .data = .{ .binary = .{ .lhs = this_node, .rhs = @enumFromInt(@intFromEnum(ptok)) } },
        }) catch return;

        const rhs_ident = ctx.addNewNode(.{
            .tag = .identifier,
            .main_token = ptok,
            .data = .{ .none = {} },
        }) catch return;

        const assign_node = ctx.addNewNode(.{
            .tag = .assignment_expr,
            .main_token = ptok,
            .data = .{ .binary = .{ .lhs = member_node, .rhs = rhs_ident } },
        }) catch return;
        ctx.ast.operator_overrides.put(ctx.allocator, @intFromEnum(assign_node), "=") catch return;

        const expr_stmt = ctx.addNewNode(.{
            .tag = .expression_statement,
            .main_token = ptok,
            .data = .{ .unary = assign_node },
        }) catch return;

        if (out_count.* >= out_nodes.len) return;
        out_nodes[out_count.*] = @intFromEnum(expr_stmt);
        out_count.* += 1;
    }
}

fn insertAssignmentsAfterSuperInStatement(
    ctx: *TransformContext,
    stmt: NodeIndex,
    prop_names: []const []const u8,
    prop_tokens: []const TokenIndex,
) bool {
    if (stmt == .none) return false;
    switch (ctx.nodeTag(stmt)) {
        .block_statement => return insertAssignmentsAfterSuperInBlock(ctx, stmt, prop_names, prop_tokens),
        .if_statement => {
            const data = ctx.nodeData(stmt);
            const extra_idx = @intFromEnum(data.extra);
            const consequent: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            const alternate: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);
            const in_consequent = if (isSuperCall(ctx, consequent))
                wrapSuperStatementWithAssignments(ctx, consequent, prop_names, prop_tokens)
            else
                insertAssignmentsAfterSuperInStatement(ctx, consequent, prop_names, prop_tokens);
            const in_alternate = if (alternate != .none)
                (if (isSuperCall(ctx, alternate))
                    wrapSuperStatementWithAssignments(ctx, alternate, prop_names, prop_tokens)
                else
                    insertAssignmentsAfterSuperInStatement(ctx, alternate, prop_names, prop_tokens))
            else
                false;
            return in_consequent or in_alternate;
        },
        else => return false,
    }
}

fn insertAssignmentsAfterSuperInBlock(
    ctx: *TransformContext,
    block: NodeIndex,
    prop_names: []const []const u8,
    prop_tokens: []const TokenIndex,
) bool {
    if (block == .none or ctx.nodeTag(block) != .block_statement) return false;

    const data = ctx.nodeData(block);
    const extra_idx = @intFromEnum(data.extra);
    const stmts_start = ctx.ast.extra_data.items[extra_idx];
    const stmts_end = ctx.ast.extra_data.items[extra_idx + 1];
    const old_count = stmts_end - stmts_start;

    var appended_count: u32 = 0;
    var mutated = false;
    for (ctx.ast.extra_data.items[stmts_start..stmts_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        if (isSuperCall(ctx, stmt)) {
            appended_count += @intCast(prop_names.len);
            mutated = true;
            continue;
        }
        if (insertAssignmentsAfterSuperInStatement(ctx, stmt, prop_names, prop_tokens)) {
            mutated = true;
        }
    }

    if (!mutated) return false;
    if (appended_count == 0) return true;

    const total = old_count + appended_count;
    ctx.ast.extra_data.ensureUnusedCapacity(ctx.allocator, total) catch return false;

    const new_range_start: u32 = @intCast(ctx.ast.extra_data.items.len);
    for (ctx.ast.extra_data.items[stmts_start..stmts_end]) |stmt_raw| {
        ctx.ast.extra_data.appendAssumeCapacity(stmt_raw);
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none or !isSuperCall(ctx, stmt)) continue;

        var new_nodes: [32]u32 = undefined;
        var new_count: usize = 0;
        appendParameterPropertyAssignments(ctx, prop_names, prop_tokens, &new_nodes, &new_count);
        for (new_nodes[0..new_count]) |new_stmt| {
            ctx.ast.extra_data.appendAssumeCapacity(new_stmt);
        }
    }

    const new_range_end: u32 = @intCast(ctx.ast.extra_data.items.len);
    ctx.ast.extra_data.items[extra_idx] = new_range_start;
    ctx.ast.extra_data.items[extra_idx + 1] = new_range_end;
    return true;
}

fn wrapSuperStatementWithAssignments(
    ctx: *TransformContext,
    stmt: NodeIndex,
    prop_names: []const []const u8,
    prop_tokens: []const TokenIndex,
) bool {
    _ = prop_tokens;
    if (stmt == .none or !isSuperCall(ctx, stmt)) return false;

    const stmt_src = getNodeGeneratedSource(ctx, stmt);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "{\n  ") catch return false;
    buf.appendSlice(ctx.allocator, stmt_src) catch return false;
    if (!std.mem.endsWith(u8, stmt_src, ";")) {
        buf.appendSlice(ctx.allocator, ";") catch return false;
    }
    buf.appendSlice(ctx.allocator, "\n") catch return false;
    for (prop_names) |pname| {
        buf.appendSlice(ctx.allocator, "  this.") catch return false;
        buf.appendSlice(ctx.allocator, pname) catch return false;
        buf.appendSlice(ctx.allocator, " = ") catch return false;
        buf.appendSlice(ctx.allocator, pname) catch return false;
        buf.appendSlice(ctx.allocator, ";\n") catch return false;
    }
    buf.appendSlice(ctx.allocator, "}") catch return false;

    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(stmt), buf.items) catch return false;
    ctx.ast.replacement_needs_reindent.put(ctx.allocator, @intFromEnum(stmt), {}) catch return false;
    return true;
}

const ParamNameInfo = struct {
    name: ?[]const u8,
    token: TokenIndex,
};

fn getParamPropertyName(ctx: *TransformContext, param: NodeIndex) ParamNameInfo {
    if (param == .none) return .{ .name = null, .token = @enumFromInt(0) };
    const tag = ctx.nodeTag(param);
    switch (tag) {
        .identifier => {
            const tok = ctx.mainToken(param);
            return .{ .name = ctx.tokenSlice(tok), .token = tok };
        },
        .assignment_pattern => {
            // x = default
            const data = ctx.nodeData(param);
            return getParamPropertyName(ctx, data.binary.lhs);
        },
        else => return .{ .name = null, .token = @enumFromInt(0) },
    }
}

fn isSuperCall(ctx: *TransformContext, stmt: NodeIndex) bool {
    const tag = ctx.nodeTag(stmt);
    if (tag != .expression_statement) return false;
    const data = ctx.nodeData(stmt);
    const expr = data.unary;
    if (expr == .none) return false;
    const expr_tag = ctx.nodeTag(expr);
    if (expr_tag != .call_expr) return false;
    // Check if callee is super
    const call_data = ctx.nodeData(expr);
    const call_extra = @intFromEnum(call_data.extra);
    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[call_extra]);
    if (callee == .none) return false;
    return ctx.nodeTag(callee) == .super_expr;
}

// ────────────────────────────────────────────────────────────────────────
// End of parameter properties helpers
// ────────────────────────────────────────────────────────────────────────

/// Strip type-only specifiers from a range in extra_data.
/// `start_slot` and `end_slot` are indices into extra_data that hold
/// the start/end of the specifier range.
/// `is_export` determines whether type specifiers are export_specifier_type
/// or import_specifier_type/import_specifier_typeof.
fn stripTypeSpecifiers(ctx: *TransformContext, start_slot: u32, end_slot: u32, is_export: bool) void {
    const specs_start = ctx.ast.extra_data.items[start_slot];
    const specs_end = ctx.ast.extra_data.items[end_slot];
    if (specs_start >= specs_end) return;

    const tags = ctx.ast.nodes.items(.tag);

    // Build a compact list of non-type specifiers
    // We do this in-place by shifting kept specifiers to the front of the range
    var write_pos = specs_start;
    for (ctx.ast.extra_data.items[specs_start..specs_end]) |s| {
        const spec_tag = tags[s];
        const is_type_spec = if (is_export)
            spec_tag == .export_specifier_type
        else
            spec_tag == .import_specifier_type or spec_tag == .import_specifier_typeof;

        if (!is_type_spec) {
            ctx.ast.extra_data.items[write_pos] = s;
            write_pos += 1;
        }
    }

    // Update the end of the range
    ctx.ast.extra_data.items[end_slot] = write_pos;
}

/// Strip export specifiers that reference type-only names.
/// This handles `export { A, B, C }` where A/B are type-only imports or type declarations.
fn stripExportTypeOnlySpecifiers(ctx: *TransformContext, start_slot: u32, end_slot: u32) void {
    const specs_start = ctx.ast.extra_data.items[start_slot];
    const specs_end = ctx.ast.extra_data.items[end_slot];
    if (specs_start >= specs_end) return;

    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    var write_pos = specs_start;
    for (ctx.ast.extra_data.items[specs_start..specs_end]) |s| {
        const spec_tag = tags[s];

        // Always remove syntactically typed specifiers
        if (spec_tag == .export_specifier_type) continue;

        if (spec_tag == .export_specifier) {
            // extra[0]=local_token — check if local name is type-only
            const spec_data = datas[s];
            const spec_extra = @intFromEnum(spec_data.extra);
            const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra]);
            const name = ctx.tokenSlice(local_tok);

            if (isTypeOnlyName(ctx, name)) continue; // skip (remove)
        }

        ctx.ast.extra_data.items[write_pos] = s;
        write_pos += 1;
    }

    ctx.ast.extra_data.items[end_slot] = write_pos;
}

/// Check if a name refers to a type-only entity (type-only import,
/// type alias, interface, or declare-only declaration).
fn isTypeOnlyName(ctx: *TransformContext, name: []const u8) bool {
    // Check if it's a type-only import
    if (ctx.type_only_imports.contains(name)) return true;

    // Check if it's a locally declared type-only entity (pre-computed in scan phase)
    if (ctx.type_only_decls.contains(name)) return true;

    return false;
}

/// Check if a name is declared locally as a type-only entity
/// (interface, type alias, or declared-only entity with no runtime value).
fn isLocalTypeOnlyDecl(ctx: *TransformContext, name: []const u8) bool {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    if (tags.len == 0 or tags[0] != .program) return false;

    const program_data = datas[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    var has_type_decl = false;
    var has_value_decl = false;

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        const tag = tags[@intFromEnum(stmt)];

        // Unwrap export_named to check declaration inside
        var actual_tag = tag;
        var actual_node = stmt;
        if (tag == .export_named or tag == .export_named_type) {
            const ed = datas[@intFromEnum(stmt)];
            const eidx = @intFromEnum(ed.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                if (decl_raw != @intFromEnum(NodeIndex.none)) {
                    actual_node = @enumFromInt(decl_raw);
                    actual_tag = tags[@intFromEnum(actual_node)];
                } else continue; // specifier-only export, check separately below
            }
        }

        // Get the declared name (safely with bounds checking)
        const decl_name = getDeclaredName(ctx, actual_node, actual_tag);
        if (decl_name == null or !std.mem.eql(u8, decl_name.?, name)) continue;

        // Determine if this declaration is type-only or has a runtime value
        switch (actual_tag) {
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_declare_function,
            .ts_declare_variable,
            .ts_declare_method,
            => has_type_decl = true,

            .ts_enum_declaration => {
                if (isDeclareNode(ctx, actual_node))
                    has_type_decl = true
                else
                    has_value_decl = true;
            },
            .ts_module_declaration => {
                if (isDeclareNode(ctx, actual_node))
                    has_type_decl = true;
                // Non-declare namespace has a value but we don't track it here
            },
            .class_declaration => {
                if (isDeclareClass(ctx, actual_node))
                    has_type_decl = true
                else
                    has_value_decl = true;
            },
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .var_declaration,
            .let_declaration,
            .const_declaration,
            => has_value_decl = true,

            else => {},
        }
    }

    // If there's only a type declaration and no value declaration, it's type-only
    return has_type_decl and !has_value_decl;
}

/// Get the declared name for any declaration node (safely with bounds checking).
fn getDeclaredName(ctx: *TransformContext, node: NodeIndex, tag: Node.Tag) ?[]const u8 {
    if (node == .none) return null;
    const ni = @intFromEnum(node);
    const tags = ctx.ast.nodes.items(.tag);
    if (ni >= tags.len) return null;
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    switch (tag) {
        // Nodes where extra[0] is a name NODE
        .ts_enum_declaration,
        .ts_module_declaration,
        .ts_declare_function,
        => return getNodeDeclName(ctx, node),

        // Nodes where extra[0] is a name TOKEN
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .class_declaration,
        .class_expr,
        => {
            const data = datas[ni];
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return null;
            const name_tok_raw = ctx.ast.extra_data.items[extra_idx];
            if (name_tok_raw == @intFromEnum(NodeIndex.none) or name_tok_raw == 0) return null;
            if (name_tok_raw >= ctx.ast.tokens.len) return null;
            const tok: TokenIndex = @enumFromInt(name_tok_raw);
            return ctx.tokenSlice(tok);
        },

        // type alias: extra[0] = id node
        .ts_type_alias_declaration => {
            return getNodeDeclName(ctx, node);
        },

        // interface: extra[0] is name node
        .ts_interface_declaration => return getNodeDeclName(ctx, node),

        // declare variable, var/let/const: check first declarator
        .ts_declare_variable, .var_declaration, .let_declaration, .const_declaration => {
            const data = datas[ni];
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return null;
            const decls_start = ctx.ast.extra_data.items[extra_idx];
            const decls_end = ctx.ast.extra_data.items[extra_idx + 1];
            if (decls_start >= decls_end) return null;
            // Get first declarator name
            const first_d = ctx.ast.extra_data.items[decls_start];
            if (first_d >= tags.len) return null;
            if (tags[first_d] == .declarator) {
                const dd = datas[first_d];
                const id_node = dd.binary.lhs;
                if (id_node != .none and @intFromEnum(id_node) < tags.len and tags[@intFromEnum(id_node)] == .identifier) {
                    return ctx.tokenSlice(main_tokens[@intFromEnum(id_node)]);
                }
            }
            return null;
        },

        .ts_declare_method => {
            return ctx.tokenSlice(main_tokens[ni]);
        },

        else => return null,
    }
}

// ────────────────────────────────────────────────────────────────────────
// Import usage analysis — scan which imported names are used as values
// ────────────────────────────────────────────────────────────────────────

/// Perform a whole-program scan to determine which imported binding names
/// are used in value positions (and therefore must be kept).
/// After this scan, `ctx.type_only_imports` contains the names that are
/// ONLY used in type positions and can be elided.
fn scanImportUsage(ctx: *TransformContext) void {
    if (ctx.import_scan_done) return;
    ctx.import_scan_done = true;

    const tags = ctx.ast.nodes.items(.tag);
    if (tags.len == 0) return;
    if (tags[0] != .program) return;

    // Step 1: Collect all imported binding names.
    // Also track which imports are `import type` (always type-only).
    collectImportedNames(ctx);

    // Step 1b: Collect type-only local declarations (for export specifier stripping).
    // This must happen before transforms modify the AST, regardless of imports.
    collectTypeOnlyDecls(ctx);

    if (ctx.all_import_names.count() == 0) return;

    // Fast path: non-TS files cannot have type-position-only usages.
    // If no explicit `import type` was found, all imports are value imports
    // and the expensive value-usage scan can be skipped entirely.
    if (!ctx.ast.language.isTypeScript() and ctx.type_only_imports.count() == 0) return;

    // Step 2: Collect names that are defined locally (shadow imports).
    // These override the import binding, so uses of the name should NOT
    // count as import value-uses.
    var local_decls: std.StringHashMapUnmanaged(void) = .empty;
    collectLocalDeclarations(ctx, &local_decls);

    // Step 3: Find value-usages of imported names.
    // When a TransformSession is available, use its pre-built identifier
    // occurrence index instead of recursively walking the entire AST.
    var value_used: std.StringHashMapUnmanaged(void) = .empty;
    if (ctx.session) |session| {
        scanValueUsagesViaSession(ctx, session, &value_used, &local_decls);
    } else {
        scanValueUsages(ctx, @enumFromInt(0), false, &value_used, &local_decls);
    }

    // Step 3b: If JSX exists in the file, mark JSX pragma root identifiers as value-used.
    markJsxPragmaImports(ctx, &value_used);

    // Step 3c: Legacy decorators are not always attached as AST-side decorator
    // nodes on every class member shape, so also conservatively honor `@name`
    // occurrences in source.
    markDecoratorImportUsagesFromSource(ctx, &value_used);

    // Step 3d: Handle transitive type-only import-equals.
    // If `import b = babel` has bound name `b` that is NOT value-used,
    // then the module reference `babel` should also not be counted as value-used
    // (the import-equals itself will be removed).
    unmarkTransitiveImportEqualsRefs(ctx, &value_used);

    // Step 4: Any imported name NOT in value_used is type-only.
    var iter = ctx.all_import_names.keyIterator();
    while (iter.next()) |key| {
        if (!value_used.contains(key.*)) {
            ctx.type_only_imports.put(ctx.allocator, key.*, {}) catch {};
        }
    }

    // (Step 1b already collected type-only declarations)
}

/// Collect all imported binding names from import declarations.
/// Only scans program body statements since imports are top-level.
fn collectImportedNames(ctx: *TransformContext) void {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    if (tags.len == 0 or tags[0] != .program) return;
    const program_data = datas[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (stmt_raw >= tags.len) continue;
        const tag = tags[stmt_raw];
        const i = stmt_raw;

        switch (tag) {
            .import_declaration => {
                const data = datas[i];
                const extra_idx = @intFromEnum(data.extra);
                const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
                const specs_end = ctx.ast.extra_data.items[extra_idx + 2];

                for (ctx.ast.extra_data.items[specs_start..specs_end]) |s| {
                    const spec_tag = tags[s];
                    switch (spec_tag) {
                        .import_default, .import_namespace => {
                            const tok = main_tokens[s];
                            const name = ctx.tokenSlice(tok);
                            ctx.all_import_names.put(ctx.allocator, name, {}) catch {};
                        },
                        .import_specifier => {
                            const spec_data = datas[s];
                            const spec_extra = @intFromEnum(spec_data.extra);
                            const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra + 1]);
                            const name = ctx.tokenSlice(local_tok);
                            ctx.all_import_names.put(ctx.allocator, name, {}) catch {};
                        },
                        .import_specifier_type, .import_specifier_typeof => {
                            const spec_data = datas[s];
                            const spec_extra = @intFromEnum(spec_data.extra);
                            const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra + 1]);
                            const name = ctx.tokenSlice(local_tok);
                            ctx.all_import_names.put(ctx.allocator, name, {}) catch {};
                            ctx.type_only_imports.put(ctx.allocator, name, {}) catch {};
                        },
                        else => {},
                    }
                }
            },
            .import_declaration_type => {
                const data = datas[i];
                const extra_idx = @intFromEnum(data.extra);
                const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
                const specs_end = ctx.ast.extra_data.items[extra_idx + 2];

                for (ctx.ast.extra_data.items[specs_start..specs_end]) |s| {
                    const spec_tag = tags[s];
                    switch (spec_tag) {
                        .import_default, .import_namespace => {
                            const tok = main_tokens[s];
                            const name = ctx.tokenSlice(tok);
                            ctx.all_import_names.put(ctx.allocator, name, {}) catch {};
                            ctx.type_only_imports.put(ctx.allocator, name, {}) catch {};
                        },
                        .import_specifier, .import_specifier_type, .import_specifier_typeof => {
                            const spec_data = datas[s];
                            const spec_extra = @intFromEnum(spec_data.extra);
                            const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra + 1]);
                            const name = ctx.tokenSlice(local_tok);
                            ctx.all_import_names.put(ctx.allocator, name, {}) catch {};
                            ctx.type_only_imports.put(ctx.allocator, name, {}) catch {};
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
}

/// Collect local declarations that shadow imported names.
/// Only scans program body statements since top-level shadows are what matter.
fn collectLocalDeclarations(ctx: *TransformContext, local_decls: *std.StringHashMapUnmanaged(void)) void {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    if (tags.len == 0 or tags[0] != .program) return;
    const program_data = datas[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (stmt_raw >= tags.len) continue;
        var tag = tags[stmt_raw];
        var i = stmt_raw;

        // Unwrap export_named to reach the inner declaration
        if (tag == .export_named) {
            const ed = datas[i];
            const eidx = @intFromEnum(ed.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                if (decl_raw != @intFromEnum(NodeIndex.none) and decl_raw < tags.len) {
                    tag = tags[decl_raw];
                    i = decl_raw;
                } else continue;
            } else continue;
        } else if (tag == .export_default) {
            const ed = datas[i];
            if (ed.unary != .none and @intFromEnum(ed.unary) < tags.len) {
                tag = tags[@intFromEnum(ed.unary)];
                i = @intFromEnum(ed.unary);
            } else continue;
        }

        switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .class_declaration,
            => {
                const data = datas[i];
                const extra_idx = @intFromEnum(data.extra);
                if (extra_idx < ctx.ast.extra_data.items.len) {
                    const name_tok_raw = ctx.ast.extra_data.items[extra_idx];
                    if (name_tok_raw != @intFromEnum(NodeIndex.none) and name_tok_raw > 0 and name_tok_raw < ctx.ast.tokens.len) {
                        const tok: TokenIndex = @enumFromInt(name_tok_raw);
                        const name = ctx.tokenSlice(tok);
                        if (ctx.all_import_names.contains(name)) {
                            local_decls.put(ctx.allocator, name, {}) catch {};
                        }
                    }
                }
            },
            .ts_enum_declaration => {
                const name_str = getNodeDeclName(ctx, @enumFromInt(i));
                if (name_str) |name| {
                    if (ctx.all_import_names.contains(name)) {
                        local_decls.put(ctx.allocator, name, {}) catch {};
                    }
                }
            },
            .ts_type_alias_declaration => {
                const name_str = getNodeDeclName(ctx, @enumFromInt(i));
                if (name_str) |name| {
                    if (ctx.all_import_names.contains(name)) {
                        local_decls.put(ctx.allocator, name, {}) catch {};
                    }
                }
            },
            .ts_interface_declaration => {
                const data = datas[i];
                const extra_idx = @intFromEnum(data.extra);
                if (extra_idx < ctx.ast.extra_data.items.len) {
                    const name_raw = ctx.ast.extra_data.items[extra_idx];
                    const name_n: NodeIndex = @enumFromInt(name_raw);
                    if (name_n != .none and @intFromEnum(name_n) < tags.len) {
                        const nt = main_tokens[@intFromEnum(name_n)];
                        const name = ctx.tokenSlice(nt);
                        if (ctx.all_import_names.contains(name)) {
                            local_decls.put(ctx.allocator, name, {}) catch {};
                        }
                    }
                }
            },
            else => {},
        }
    }
}

/// Pre-compute which locally declared names are type-only (for export specifier stripping).
fn collectTypeOnlyDecls(ctx: *TransformContext) void {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    if (tags.len == 0 or tags[0] != .program) return;

    const program_data = datas[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    // First pass: collect all declarations, tracking type vs value
    var type_names: std.StringHashMapUnmanaged(void) = .empty;
    var value_names: std.StringHashMapUnmanaged(void) = .empty;

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        const tag = tags[@intFromEnum(stmt)];

        // Unwrap export_named / export_named_type
        var actual_tag = tag;
        var actual_node = stmt;
        if (tag == .export_named or tag == .export_named_type or tag == .export_default) {
            if (tag == .export_default) {
                const ed = datas[@intFromEnum(stmt)];
                if (ed.unary != .none) {
                    actual_node = ed.unary;
                    actual_tag = tags[@intFromEnum(actual_node)];
                } else continue;
            } else {
                const ed = datas[@intFromEnum(stmt)];
                const eidx = @intFromEnum(ed.extra);
                if (eidx + 3 < ctx.ast.extra_data.items.len) {
                    const decl_raw = ctx.ast.extra_data.items[eidx + 3];
                    if (decl_raw != @intFromEnum(NodeIndex.none)) {
                        actual_node = @enumFromInt(decl_raw);
                        actual_tag = tags[@intFromEnum(actual_node)];
                    } else continue;
                } else continue;
            }
        }

        const decl_name = getDeclaredName(ctx, actual_node, actual_tag) orelse continue;

        switch (actual_tag) {
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_declare_function,
            .ts_declare_variable,
            .ts_declare_method,
            => type_names.put(ctx.allocator, decl_name, {}) catch {},

            .ts_enum_declaration => {
                if (isDeclareNode(ctx, actual_node))
                    type_names.put(ctx.allocator, decl_name, {}) catch {}
                else
                    value_names.put(ctx.allocator, decl_name, {}) catch {};
            },
            .ts_module_declaration => {
                if (isDeclareNode(ctx, actual_node))
                    type_names.put(ctx.allocator, decl_name, {}) catch {};
            },
            .class_declaration => {
                if (isDeclareClass(ctx, actual_node))
                    type_names.put(ctx.allocator, decl_name, {}) catch {}
                else
                    value_names.put(ctx.allocator, decl_name, {}) catch {};
            },

            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .var_declaration,
            .let_declaration,
            .const_declaration,
            => value_names.put(ctx.allocator, decl_name, {}) catch {},

            else => {},
        }
    }

    // A name is type-only if it has a type declaration but no value declaration
    var type_iter = type_names.keyIterator();
    while (type_iter.next()) |key| {
        if (!value_names.contains(key.*)) {
            ctx.type_only_decls.put(ctx.allocator, key.*, {}) catch {};
        }
    }
}

/// Safely get the declaration name for a node that stores a name node at extra[0].
/// Works for function_declaration, ts_enum_declaration, ts_interface_declaration, etc.
fn getNodeDeclName(ctx: *TransformContext, idx: NodeIndex) ?[]const u8 {
    if (idx == .none) return null;
    const i = @intFromEnum(idx);
    const tags = ctx.ast.nodes.items(.tag);
    if (i >= tags.len) return null;

    const data = ctx.ast.nodes.items(.data)[i];
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx >= ctx.ast.extra_data.items.len) return null;

    const name_raw = ctx.ast.extra_data.items[extra_idx];
    const name_n: NodeIndex = @enumFromInt(name_raw);
    if (name_n == .none) return null;
    const ni = @intFromEnum(name_n);
    if (ni >= tags.len) return null;

    // The name node should be an identifier; get its main_token
    const nt = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.tokenSlice(nt);
}

fn inlineConstEnumMemberAccess(idx: NodeIndex, ctx: *TransformContext) void {
    if (!g_config.optimize_const_enums) return;
    const replacement = getConstEnumInlineReplacement(ctx, idx) orelse return;
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(idx), replacement) catch {};
}

fn getConstEnumInlineReplacement(ctx: *TransformContext, idx: NodeIndex) ?[]const u8 {
    const tag = ctx.nodeTag(idx);
    const data = ctx.nodeData(idx);

    var enum_name: []const u8 = undefined;
    var member_name: []const u8 = undefined;

    switch (tag) {
        .member_expr => {
            if (ctx.nodeTag(data.binary.lhs) != .identifier) return null;
            enum_name = ctx.tokenSlice(ctx.mainToken(data.binary.lhs));
            const prop_tok: TokenIndex = @enumFromInt(@intFromEnum(data.binary.rhs));
            member_name = ctx.tokenSlice(prop_tok);
        },
        .computed_member_expr => {
            if (ctx.nodeTag(data.binary.lhs) != .identifier) return null;
            enum_name = ctx.tokenSlice(ctx.mainToken(data.binary.lhs));
            const prop = data.binary.rhs;
            if (ctx.nodeTag(prop) != .string_literal) return null;
            const raw = ctx.tokenSlice(ctx.mainToken(prop));
            if (raw.len < 2) return null;
            member_name = raw[1 .. raw.len - 1];
        },
        else => return null,
    }

    if (ctx.scope) |scope_result| {
        const scope_idx = ctx.getScopeForNode(idx) orelse return null;
        if (findBindingInScopeChain(scope_result, scope_idx, enum_name) != null) return null;
    }

    if (ctx.runtime_const_enums.contains(enum_name)) return null;

    const key = std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ enum_name, member_name }) catch return null;
    const resolved = ctx.enum_member_values.get(key) orelse return null;
    return switch (resolved.kind) {
        .number => |n| std.fmt.allocPrint(ctx.allocator, "{d}", .{n}) catch null,
        .string => |s| s,
    };
}

fn findBindingInScopeChain(scope_result: *const scope_mod.ScopeResult, start_scope: scope_mod.ScopeIndex, name: []const u8) ?*const scope_mod.Binding {
    var current: ?scope_mod.ScopeIndex = start_scope;
    while (current) |scope_idx| {
        const scope = scope_result.scopes[@intFromEnum(scope_idx)];
        for (scope_result.bindings[scope.bindings_start..scope.bindings_end]) |*binding| {
            if (binding.scope != scope_idx) continue;
            if (std.mem.eql(u8, binding.name, name)) return binding;
        }
        current = scope.parent;
    }
    return null;
}

fn isConstEnumValueExported(ctx: *TransformContext, enum_name: []const u8) bool {
    const tags = ctx.ast.nodes.items(.tag);
    if (tags.len == 0 or tags[0] != .program) return false;

    const program_data = ctx.ast.nodes.items(.data)[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none or ctx.nodeTag(stmt) != .export_named) continue;

        const data = ctx.nodeData(stmt);
        const extra_idx = @intFromEnum(data.extra);
        const source_token_raw = ctx.ast.extra_data.items[extra_idx];
        if (source_token_raw != 0) continue;

        const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
        if (decl_raw != @intFromEnum(NodeIndex.none)) continue;

        const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
        const specs_end = ctx.ast.extra_data.items[extra_idx + 2];
        for (ctx.ast.extra_data.items[specs_start..specs_end]) |spec_raw| {
            const spec: NodeIndex = @enumFromInt(spec_raw);
            if (spec == .none) continue;
            const spec_tag = ctx.nodeTag(spec);
            if (spec_tag == .export_specifier_type) continue;
            if (spec_tag != .export_specifier) continue;
            const spec_data = ctx.nodeData(spec);
            const spec_extra = @intFromEnum(spec_data.extra);
            const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra]);
            if (std.mem.eql(u8, ctx.tokenSlice(local_tok), enum_name)) return true;
        }
    }
    return false;
}

fn isConstEnumTypeExported(ctx: *TransformContext, enum_name: []const u8) bool {
    const tags = ctx.ast.nodes.items(.tag);
    if (tags.len == 0 or tags[0] != .program) return false;

    const program_data = ctx.ast.nodes.items(.data)[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        const tag = ctx.nodeTag(stmt);

        switch (tag) {
            .export_named_type => {
                const data = ctx.nodeData(stmt);
                const extra_idx = @intFromEnum(data.extra);
                const source_token_raw = ctx.ast.extra_data.items[extra_idx];
                if (source_token_raw != 0) continue;

                if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
                    const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
                    if (decl_raw != @intFromEnum(NodeIndex.none)) {
                        const decl_node: NodeIndex = @enumFromInt(decl_raw);
                        if (decl_node != .none) {
                            const decl_tag = ctx.nodeTag(decl_node);
                            if (getDeclaredName(ctx, decl_node, decl_tag)) |decl_name| {
                                if (std.mem.eql(u8, decl_name, enum_name)) return true;
                            }
                        }
                    }
                }

                const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
                const specs_end = ctx.ast.extra_data.items[extra_idx + 2];
                for (ctx.ast.extra_data.items[specs_start..specs_end]) |spec_raw| {
                    const spec: NodeIndex = @enumFromInt(spec_raw);
                    if (spec == .none) continue;
                    if (ctx.nodeTag(spec) != .export_specifier and ctx.nodeTag(spec) != .export_specifier_type) continue;
                    const spec_data = ctx.nodeData(spec);
                    const spec_extra = @intFromEnum(spec_data.extra);
                    const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra]);
                    if (std.mem.eql(u8, ctx.tokenSlice(local_tok), enum_name)) return true;
                }
            },
            .export_named => {
                const data = ctx.nodeData(stmt);
                const extra_idx = @intFromEnum(data.extra);
                const source_token_raw = ctx.ast.extra_data.items[extra_idx];
                if (source_token_raw != 0) continue;
                const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
                const specs_end = ctx.ast.extra_data.items[extra_idx + 2];
                for (ctx.ast.extra_data.items[specs_start..specs_end]) |spec_raw| {
                    const spec: NodeIndex = @enumFromInt(spec_raw);
                    if (spec == .none or ctx.nodeTag(spec) != .export_specifier_type) continue;
                    const spec_data = ctx.nodeData(spec);
                    const spec_extra = @intFromEnum(spec_data.extra);
                    const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra]);
                    if (std.mem.eql(u8, ctx.tokenSlice(local_tok), enum_name)) return true;
                }
            },
            else => {},
        }
    }

    return false;
}

/// If the AST contains any JSX elements or fragments, find the JSX pragma
/// and fragment pragma root identifiers and mark them as value-used.
fn markJsxPragmaImports(ctx: *TransformContext, value_used: *std.StringHashMapUnmanaged(void)) void {
    const tags = ctx.ast.nodes.items(.tag);

    // Check if any JSX exists in the file
    var has_jsx_element = false;
    var has_jsx_fragment = false;
    for (tags) |tag| {
        switch (tag) {
            .jsx_element, .jsx_opening_element, .jsx_self_closing_element => has_jsx_element = true,
            .jsx_fragment, .jsx_opening_fragment => has_jsx_fragment = true,
            else => {},
        }
    }

    if (!has_jsx_element and !has_jsx_fragment) return;

    // Find pragma and pragmaFrag from:
    // 1. TransformContext options (set by the caller)
    // 2. Source code comments (@jsx, @jsxFrag)
    // 3. Defaults (React.createElement / React.Fragment)
    var pragma_root: ?[]const u8 = null;
    var pragma_frag_root: ?[]const u8 = null;

    // Priority 1: options from context
    if (ctx.jsx_pragma) |p| {
        pragma_root = extractRootIdent(p);
    }
    if (ctx.jsx_pragma_frag) |p| {
        pragma_frag_root = extractRootIdent(p);
    }

    // Priority 2: source code comments
    const source = ctx.ast.source;
    if (pragma_root == null) {
        if (findJsxPragma(source, "@jsx ")) |p| {
            pragma_root = extractRootIdent(p);
        }
    }
    if (pragma_frag_root == null) {
        if (findJsxPragma(source, "@jsxFrag ")) |p| {
            pragma_frag_root = extractRootIdent(p);
        }
    }

    // Priority 3: defaults
    const jsx_root = pragma_root orelse "React";
    const frag_root = pragma_frag_root orelse jsx_root;

    // Mark JSX pragma root as value-used
    if (has_jsx_element or has_jsx_fragment) {
        if (ctx.all_import_names.contains(jsx_root)) {
            value_used.put(ctx.allocator, jsx_root, {}) catch {};
        }
    }

    // Mark fragment pragma root as value-used
    if (has_jsx_fragment) {
        if (ctx.all_import_names.contains(frag_root)) {
            value_used.put(ctx.allocator, frag_root, {}) catch {};
        }
    }
}

/// Search source for a pragma pattern like "@jsx " or "@jsxFrag " in a comment.
fn findJsxPragma(source: []const u8, pattern: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < source.len) {
        if (std.mem.indexOfPos(u8, source, pos, pattern)) |idx| {
            // Verify it's inside a comment
            const value_start = idx + pattern.len;
            // Extract the value (until whitespace, newline, or end of comment)
            var end = value_start;
            while (end < source.len and source[end] != '\n' and source[end] != '\r' and source[end] != ' ' and source[end] != '*') {
                end += 1;
            }
            if (end > value_start) {
                return source[value_start..end];
            }
            pos = idx + 1;
        } else break;
    }
    return null;
}

/// Extract the root identifier from a pragma value like "React.createElement" → "React"
/// or "h" → "h"
fn extractRootIdent(pragma: []const u8) []const u8 {
    if (std.mem.indexOf(u8, pragma, ".")) |dot_pos| {
        return pragma[0..dot_pos];
    }
    return pragma;
}

fn markDecoratorImportUsagesFromSource(ctx: *TransformContext, value_used: *std.StringHashMapUnmanaged(void)) void {
    var iter = ctx.all_import_names.keyIterator();
    while (iter.next()) |name_ptr| {
        const name = name_ptr.*;
        if (sourceContainsDecoratorIdent(ctx.ast.source, name)) {
            value_used.put(ctx.allocator, name, {}) catch {};
        }
    }
}

fn sourceContainsDecoratorIdent(source: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, "@")) |at_pos| {
        const ident_start = at_pos + 1;
        if (ident_start + name.len > source.len) return false;
        if (!std.mem.eql(u8, source[ident_start .. ident_start + name.len], name)) {
            pos = ident_start;
            continue;
        }

        const ident_end = ident_start + name.len;
        if (ident_end < source.len) {
            const next = source[ident_end];
            if (std.ascii.isAlphanumeric(next) or next == '_' or next == '$') {
                pos = ident_end;
                continue;
            }
        }
        return true;
    }
    return false;
}

/// Session-backed value-usage scan: for each imported name, look up its
/// pre-indexed identifier occurrences and check whether any are outside
/// a type-only context by walking ancestors through the session's parent map.
/// Also checks export specifiers, which use tokens rather than child nodes
/// and therefore are not tracked in `identifierOccurrences`.
fn scanValueUsagesViaSession(
    ctx: *TransformContext,
    session: *const @import("session.zig").TransformSession,
    value_used: *std.StringHashMapUnmanaged(void),
    local_decls: *const std.StringHashMapUnmanaged(void),
) void {
    // Phase 1: check identifier occurrences via binding_occurrences.
    var name_iter = ctx.all_import_names.keyIterator();
    while (name_iter.next()) |key| {
        const name = key.*;
        if (local_decls.contains(name)) continue;
        if (value_used.contains(name)) continue;
        const binding_indices = session.bindingIndices(name) orelse continue;
        var found_value_use = false;
        for (binding_indices) |binding_idx| {
            const occurrences = session.bindingOccurrences(binding_idx);
            for (occurrences) |occ| {
                if (!isInTypeContext(ctx, session, occ.node)) {
                    found_value_use = true;
                    break;
                }
            }
            if (found_value_use) break;
        }
        if (found_value_use) {
            value_used.put(ctx.allocator, name, {}) catch {};
        }
    }

    // Phase 2: export specifiers use tokens (not child nodes), so they
    // are invisible to the identifier occurrence index. Scan program body
    // for specifier-only `export { ... }` statements.
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    if (tags.len == 0 or tags[0] != .program) return;
    const program_data = datas[0];
    const program_extra = @intFromEnum(program_data.extra);
    const range_start = ctx.ast.extra_data.items[program_extra];
    const range_end = ctx.ast.extra_data.items[program_extra + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (stmt_raw >= tags.len) continue;
        if (tags[stmt_raw] != .export_named) continue;
        const data = datas[stmt_raw];
        const extra_idx = @intFromEnum(data.extra);
        // Skip re-exports (have a `from` clause).
        if (ctx.ast.extra_data.items[extra_idx] != 0) continue;
        // Skip exports with a declaration.
        if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
            const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
            if (decl_raw != @intFromEnum(NodeIndex.none)) continue;
        }
        const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
        const specs_end = ctx.ast.extra_data.items[extra_idx + 2];
        for (ctx.ast.extra_data.items[specs_start..specs_end]) |s| {
            if (s >= tags.len) continue;
            if (tags[s] == .export_specifier_type) continue;
            if (tags[s] != .export_specifier) continue;
            const spec_data = datas[s];
            const spec_extra = @intFromEnum(spec_data.extra);
            const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra]);
            const name = ctx.tokenSlice(local_tok);
            if (ctx.all_import_names.contains(name) and !local_decls.contains(name)) {
                value_used.put(ctx.allocator, name, {}) catch {};
            }
        }
    }
}

/// Walk ancestors of `node` via the session parent map to determine whether
/// it sits inside a type-only subtree. Returns true when the identifier
/// should NOT count as a value-usage.
fn isInTypeContext(
    ctx: *const TransformContext,
    session: *const @import("session.zig").TransformSession,
    node: NodeIndex,
) bool {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    var current = node;
    // Walk up ancestors. Limit depth to avoid pathological cases.
    var depth: u32 = 0;
    while (depth < 1000) : (depth += 1) {
        const parent_opt = session.parentOf(current);
        if (parent_opt == null) break;
        const parent = parent_opt.?;
        const pi = @intFromEnum(parent);
        if (pi >= tags.len) break;
        const ptag = tags[pi];

        switch (ptag) {
            // Pure type nodes — anything inside is type-only.
            .ts_type_annotation,
            .ts_type_reference,
            .ts_keyword_type,
            .ts_array_type,
            .ts_tuple_type,
            .ts_union_type,
            .ts_intersection_type,
            .ts_function_type,
            .ts_constructor_type,
            .ts_parenthesized_type,
            .ts_optional_type,
            .ts_rest_type,
            .ts_literal_type,
            .ts_type_parameter,
            .ts_type_parameter_declaration,
            .ts_type_parameter_instantiation,
            .ts_conditional_type,
            .ts_infer_type,
            .ts_mapped_type,
            .ts_indexed_access_type,
            .ts_template_literal_type,
            .ts_typeof_type,
            .ts_type_operator,
            .ts_type_predicate,
            .ts_import_type,
            .ts_named_tuple_member,
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_interface_body,
            .ts_type_literal,
            .ts_property_signature,
            .ts_method_signature,
            .ts_index_signature,
            .ts_call_signature_declaration,
            .ts_construct_signature_declaration,
            .ts_declare_function,
            .ts_declare_variable,
            .ts_declare_method,
            .import_declaration_type,
            .import_specifier_type,
            .import_specifier_typeof,
            .export_named_type,
            .export_specifier_type,
            => return true,

            // ts_as_expression / ts_satisfies_expression: rhs is type.
            .ts_as_expression, .ts_satisfies_expression => {
                const d = datas[pi];
                if (current == d.binary.rhs) return true;
            },

            // ts_type_assertion: <Type>expr — lhs is type.
            .ts_type_assertion => {
                const d = datas[pi];
                if (current == d.binary.lhs) return true;
            },

            // ts_instantiation_expression: expr<Type> — rhs is type.
            .ts_instantiation_expression => {
                const d = datas[pi];
                if (current == d.binary.rhs) return true;
            },

            // Import binding sites — these are definitions, not usages.
            .import_declaration, .import_default, .import_namespace, .import_specifier => return true,

            // Property key position — not a value reference to import.
            .property => {
                const d = datas[pi];
                if (current == d.binary.lhs) return true;
            },

            else => {},
        }

        current = parent;
    }
    return false;
}

/// Recursively walk the AST and mark imported names used in value positions.
/// `in_type` indicates whether we're currently inside a type context.
fn scanValueUsages(
    ctx: *TransformContext,
    idx: NodeIndex,
    in_type: bool,
    value_used: *std.StringHashMapUnmanaged(void),
    local_decls: *const std.StringHashMapUnmanaged(void),
) void {
    if (idx == .none) return;
    const i = @intFromEnum(idx);
    const tags = ctx.ast.nodes.items(.tag);
    if (i >= tags.len) return;

    const tag = tags[i];

    // Skip removed/none nodes
    if (tag == .removed) return;

    // ── Type-context boundaries: entering a type context ──
    // These nodes and everything inside them are type-only.
    const is_type_node = switch (tag) {
        .ts_type_annotation,
        .ts_type_reference,
        .ts_keyword_type,
        .ts_array_type,
        .ts_tuple_type,
        .ts_union_type,
        .ts_intersection_type,
        .ts_function_type,
        .ts_constructor_type,
        .ts_parenthesized_type,
        .ts_optional_type,
        .ts_rest_type,
        .ts_literal_type,
        .ts_type_parameter,
        .ts_type_parameter_declaration,
        .ts_type_parameter_instantiation,
        .ts_conditional_type,
        .ts_infer_type,
        .ts_mapped_type,
        .ts_indexed_access_type,
        .ts_template_literal_type,
        .ts_typeof_type,
        .ts_type_operator,
        .ts_type_predicate,
        .ts_import_type,
        .ts_named_tuple_member,
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        .ts_interface_body,
        .ts_type_literal,
        .ts_property_signature,
        .ts_method_signature,
        .ts_index_signature,
        .ts_call_signature_declaration,
        .ts_construct_signature_declaration,
        .ts_declare_function,
        .ts_declare_variable,
        .ts_declare_method,
        .import_declaration_type,
        .import_specifier_type,
        .import_specifier_typeof,
        .export_named_type,
        .export_specifier_type,
        => true,
        else => false,
    };

    const current_in_type = in_type or is_type_node;

    // ── Identifier: check if it's an imported name in value position ──
    if (tag == .identifier and !current_in_type) {
        const tok = ctx.ast.nodes.items(.main_token)[i];
        const name = ctx.tokenSlice(tok);
        if (ctx.all_import_names.contains(name) and !local_decls.contains(name)) {
            value_used.put(ctx.allocator, name, {}) catch {};
        }
    }

    // ── Special handling for ts_as_expression, ts_satisfies_expression ──
    // lhs is value, rhs is type
    if (tag == .ts_as_expression or tag == .ts_satisfies_expression) {
        const data = ctx.ast.nodes.items(.data)[i];
        scanValueUsages(ctx, data.binary.lhs, in_type, value_used, local_decls);
        // rhs is always type — skip (or mark as type)
        return;
    }

    // ── Special handling for ts_type_assertion: <Type>expr ──
    // lhs is type, rhs is value
    if (tag == .ts_type_assertion) {
        const data = ctx.ast.nodes.items(.data)[i];
        scanValueUsages(ctx, data.binary.rhs, in_type, value_used, local_decls);
        // lhs is always type — skip
        return;
    }

    // ── Special handling for ts_non_null_expression ──
    // Inner is value
    if (tag == .ts_non_null_expression) {
        const data = ctx.ast.nodes.items(.data)[i];
        scanValueUsages(ctx, data.unary, in_type, value_used, local_decls);
        return;
    }

    // ── Special handling for ts_instantiation_expression: expr<Type> ──
    // lhs is value, rhs is type
    if (tag == .ts_instantiation_expression) {
        const data = ctx.ast.nodes.items(.data)[i];
        scanValueUsages(ctx, data.binary.lhs, in_type, value_used, local_decls);
        return;
    }

    // ── Special handling for ts_import_equals_declaration ──
    // The module reference is a VALUE usage (not type), even if it uses ts_qualified_name
    if (tag == .ts_import_equals_declaration) {
        const data = ctx.ast.nodes.items(.data)[i];
        const extra_idx = @intFromEnum(data.extra);
        if (extra_idx + 2 < ctx.ast.extra_data.items.len) {
            // Check if it's type-only
            const is_type = ctx.ast.extra_data.items[extra_idx + 2];
            if (is_type != 0) return; // type-only import equals — skip
        }
        // moduleReference is at extra[1]
        if (extra_idx + 1 < ctx.ast.extra_data.items.len) {
            const module_ref: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            // Force value context for the module reference
            scanValueUsages(ctx, module_ref, false, value_used, local_decls);
        }
        return;
    }

    // ── Special handling for property: key is NOT a value reference ──
    // In `{ A: 'foo' }`, A is just a property key, not referencing import A
    if (tag == .property) {
        const data = ctx.ast.nodes.items(.data)[i];
        // Only recurse into the value (rhs), skip the key (lhs)
        scanValueUsages(ctx, data.binary.rhs, in_type, value_used, local_decls);
        return;
    }

    // ── Special handling for method_definition, getter, setter ──
    // The key is not a value reference
    if (tag == .method_definition or tag == .getter or tag == .setter) {
        // Skip the key — only recurse into params and body
        const children = visitor.getChildren(ctx.ast, idx);
        // For methods, children include key (which we want to skip for name matching)
        // and body. Just recurse all children — method keys are rarely import names
        for (children.items[0..children.len]) |child| {
            scanValueUsages(ctx, child, current_in_type, value_used, local_decls);
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                scanValueUsages(ctx, @enumFromInt(raw), current_in_type, value_used, local_decls);
            }
        }
        return;
    }

    // ── Special handling for import/export declarations — don't count
    // the specifier identifiers themselves as value usages ──
    if (tag == .import_declaration or tag == .import_declaration_type) {
        // Don't recurse into import specifiers — those are binding sites
        return;
    }

    // ── Special handling for export type { ... } ──
    if (tag == .export_named_type) {
        // Everything in export type is type-only
        return;
    }

    // ── Special handling for export { type X } ──
    // For export_named, we need to check specifiers individually
    if (tag == .export_named) {
        const data = ctx.ast.nodes.items(.data)[i];
        const extra_idx = @intFromEnum(data.extra);
        const source_token_raw = ctx.ast.extra_data.items[extra_idx];

        // If this export has a `from` clause, it's a re-export — names don't reference local bindings
        if (source_token_raw != 0) return;

        // Check if there's a declaration
        if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
            const decl_raw = ctx.ast.extra_data.items[extra_idx + 3];
            if (decl_raw != @intFromEnum(NodeIndex.none)) {
                // Has a declaration — recurse into it
                const decl_node: NodeIndex = @enumFromInt(decl_raw);
                scanValueUsages(ctx, decl_node, in_type, value_used, local_decls);
                return;
            }
        }

        // Specifier-only export: `export { X, type Y }`
        // Non-type specifiers count as value usage of the local name
        const specs_start = ctx.ast.extra_data.items[extra_idx + 1];
        const specs_end = ctx.ast.extra_data.items[extra_idx + 2];
        for (ctx.ast.extra_data.items[specs_start..specs_end]) |s| {
            const spec_tag = tags[s];
            if (spec_tag == .export_specifier_type) continue; // type specifier
            if (spec_tag == .export_specifier) {
                // extra[0]=local_token — this references a local name as a value
                const spec_data = ctx.ast.nodes.items(.data)[s];
                const spec_extra = @intFromEnum(spec_data.extra);
                const local_tok: TokenIndex = @enumFromInt(ctx.ast.extra_data.items[spec_extra]);
                const name = ctx.tokenSlice(local_tok);
                if (ctx.all_import_names.contains(name) and !local_decls.contains(name)) {
                    value_used.put(ctx.allocator, name, {}) catch {};
                }
            }
        }
        return;
    }

    if (ctx.ast.decorators_map.get(@intCast(i))) |range| {
        const start: usize = @intCast(range.start);
        const end: usize = @intCast(range.end);
        if (start <= end and end <= ctx.ast.extra_data.items.len) {
            for (ctx.ast.extra_data.items[start..end]) |raw| {
                scanValueUsages(ctx, @enumFromInt(raw), false, value_used, local_decls);
            }
        }
    }

    // ── Recurse into children using the visitor ──
    const children = visitor.getChildren(ctx.ast, idx);

    for (children.items[0..children.len]) |child| {
        scanValueUsages(ctx, child, current_in_type, value_used, local_decls);
    }

    if (children.range_end > children.range_start) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            const child: NodeIndex = @enumFromInt(raw);
            scanValueUsages(ctx, child, current_in_type, value_used, local_decls);
        }
    }

    if (children.range2_end > children.range2_start) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            const child: NodeIndex = @enumFromInt(raw);
            scanValueUsages(ctx, child, current_in_type, value_used, local_decls);
        }
    }
}

/// Remove transitive value-used marks from import-equals module references
/// when the import-equals bound name is itself not value-used.
/// E.g., `import * as babel from 'x'; import b = babel;` — if `b` is
/// type-only, then the `babel` reference in `import b = babel` should
/// not keep `babel` marked as value-used.
fn unmarkTransitiveImportEqualsRefs(ctx: *TransformContext, value_used: *std.StringHashMapUnmanaged(void)) void {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const main_tokens = ctx.ast.nodes.items(.main_token);

    // Iterate until stable — handles chains like `import a = b; import b = c;`
    var changed = true;
    while (changed) {
        changed = false;
        for (tags, 0..) |tag, i| {
            if (tag != .ts_import_equals_declaration) continue;

            const data = datas[i];
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) continue;

            // Skip syntactically type-only import-equals
            const is_type = ctx.ast.extra_data.items[extra_idx + 2];
            if (is_type != 0) continue;

            // Get bound name
            const id_tok_raw = ctx.ast.extra_data.items[extra_idx];
            if (id_tok_raw == 0 or id_tok_raw >= ctx.ast.tokens.len) continue;
            const id_tok: TokenIndex = @enumFromInt(id_tok_raw);
            const bound_name = ctx.tokenSlice(id_tok);

            // If the bound name IS value-used, keep the module reference
            if (value_used.contains(bound_name)) continue;

            // Only un-mark the module reference when the bound name is used in
            // type positions (type-only alias). If the bound name is completely
            // unused (no type or value usage), the import-equals was dead code
            // but the module reference should still count as value-used.
            if (!hasTypeUsage(ctx, bound_name, @enumFromInt(i))) continue;

            // Bound name is type-only → remove module reference from value_used
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) continue;
            const module_ref: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]);
            if (module_ref == .none) continue;
            const mr_i = @intFromEnum(module_ref);
            if (mr_i >= tags.len) continue;

            // Get the root identifier of the module reference (handles qualified names)
            const ref_name = getModuleRefRootName(ctx, module_ref, tags, main_tokens);
            if (ref_name) |name| {
                if (value_used.contains(name)) {
                    // Only remove if the ONLY value usage of this name is from
                    // import-equals declarations that are themselves unused.
                    // Check if there are other value usages besides import-equals refs.
                    if (!hasNonImportEqualsValueUsage(ctx, name)) {
                        _ = value_used.remove(name);
                        changed = true;
                    }
                }
            }
        }
    }
}

/// Check if a name has any usage in type context (type annotations, type aliases, etc.),
/// excluding usages within import-equals declarations themselves.
fn hasTypeUsage(ctx: *TransformContext, name: []const u8, self_idx: NodeIndex) bool {
    const tags = ctx.ast.nodes.items(.tag);
    const main_tokens = ctx.ast.nodes.items(.main_token);
    const end_offsets = ctx.ast.nodes.items(.end_offset);
    const tok_starts = ctx.ast.tokens.items(.start);

    // Get the source range of our own import-equals to skip
    const self_i = @intFromEnum(self_idx);
    const self_start = tok_starts[@intFromEnum(main_tokens[self_i])];
    const self_end = end_offsets[self_i];

    for (tags, 0..) |tag, i| {
        if (tag != .identifier) continue;
        const tok = main_tokens[i];
        const tok_text = ctx.tokenSlice(tok);
        if (!std.mem.eql(u8, tok_text, name)) continue;

        const id_pos = tok_starts[@intFromEnum(tok)];

        // Skip synthetic nodes
        if (end_offsets[i] == 0) continue;

        // Skip identifiers inside our own import-equals
        if (id_pos >= self_start and id_pos < self_end) continue;

        // Check if this identifier is in a type context
        if (isPositionInTypeContext(ctx, id_pos)) return true;
    }
    return false;
}

/// Get the root identifier name from a module reference (handles ts_qualified_name chains).
fn getModuleRefRootName(
    ctx: *TransformContext,
    ref: NodeIndex,
    tags: []const Node.Tag,
    main_tokens: []const TokenIndex,
) ?[]const u8 {
    var current = ref;
    while (true) {
        const ci = @intFromEnum(current);
        if (ci >= tags.len) return null;
        const t = tags[ci];
        if (t == .identifier) {
            return ctx.tokenSlice(main_tokens[ci]);
        }
        if (t == .ts_qualified_name) {
            // left.right — follow left
            const data = ctx.ast.nodes.items(.data)[ci];
            current = data.binary.lhs;
            continue;
        }
        // member_expression: object.property — follow object
        if (t == .member_expr or t == .optional_chain_expr) {
            const data = ctx.ast.nodes.items(.data)[ci];
            current = data.binary.lhs;
            continue;
        }
        return null;
    }
}

/// Check if an imported name has value usages outside of import-equals module references.
fn hasNonImportEqualsValueUsage(ctx: *TransformContext, name: []const u8) bool {
    const tags = ctx.ast.nodes.items(.tag);
    const main_tokens = ctx.ast.nodes.items(.main_token);
    const end_offsets = ctx.ast.nodes.items(.end_offset);
    const tok_starts = ctx.ast.tokens.items(.start);

    // Collect source ranges of import-equals declarations to skip
    var import_eq_ranges: [64]struct { start: u32, end: u32 } = undefined;
    var eq_count: usize = 0;
    for (tags, 0..) |tag, i| {
        if (tag == .ts_import_equals_declaration and eq_count < import_eq_ranges.len) {
            const eo = end_offsets[i];
            if (eo == 0) continue;
            import_eq_ranges[eq_count] = .{
                .start = tok_starts[@intFromEnum(main_tokens[i])],
                .end = eo,
            };
            eq_count += 1;
        }
    }

    for (tags, 0..) |tag, i| {
        if (tag != .identifier) continue;
        const tok = main_tokens[i];
        const tok_text = ctx.tokenSlice(tok);
        if (!std.mem.eql(u8, tok_text, name)) continue;

        const id_pos = tok_starts[@intFromEnum(tok)];

        // Skip synthetic nodes
        if (end_offsets[i] == 0) continue;

        // Skip identifiers inside import-equals declarations
        var in_import_eq = false;
        for (import_eq_ranges[0..eq_count]) |r| {
            if (id_pos >= r.start and id_pos < r.end) {
                in_import_eq = true;
                break;
            }
        }
        if (in_import_eq) continue;

        // Skip identifiers inside import declarations
        var in_import = false;
        for (tags, 0..) |itag, ii| {
            if (itag == .import_declaration or itag == .import_declaration_type) {
                const ieo = end_offsets[ii];
                if (ieo == 0) continue;
                const ist = tok_starts[@intFromEnum(main_tokens[ii])];
                if (id_pos >= ist and id_pos < ieo) {
                    in_import = true;
                    break;
                }
            }
        }
        if (in_import) continue;

        // Skip identifiers in type context
        if (isPositionInTypeContext(ctx, id_pos)) continue;

        return true; // Found a non-import-equals, non-type value usage
    }
    return false;
}
