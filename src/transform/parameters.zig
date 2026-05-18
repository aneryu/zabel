const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");
const rewrite_plan = @import("rewrite_plan.zig");
const session_mod = @import("session.zig");
const Codegen = @import("../codegen.zig").Codegen;
const scope_mod = @import("../scope.zig");

/// Configuration for the parameters transform.
pub const Config = struct {
    /// When true, use simplified default parameter handling
    /// (if (x === void 0) { x = default; }) instead of arguments-length checks.
    ignore_function_length: bool = false,
    /// Loose mode — same as ignoreFunctionLength.
    loose: bool = false,
    /// Emit `var` bindings when block-scoping is expected to run later.
    emit_var_bindings: bool = false,
    /// When false, preserve arrow spec mode with `.bind(this)` + `newArrowCheck`.
    arrow_no_new_arrows: bool = true,
    /// Preserve TS/Flow type annotations on params when no strip pass runs before us.
    preserve_type_annotations: bool = false,
};

var g_config: Config = .{};

/// Global counter for unique rest-loop variable suffixes (_len2, _key2, etc.)
var g_rest_loop_counter: u32 = 0;
var g_used_names: std.StringHashMapUnmanaged(void) = .empty;
var g_binding_list_started: bool = false;
var g_current_excluded_hoist_body: ?NodeIndex = null;
var g_replacement_cache_ast: ?*Ast = null;
var g_replacement_subtree_cache: []u8 = &[_]u8{};
var g_replacement_subtree_cache_epochs: []u32 = &[_]u32{};
var g_replacement_subtree_cache_epoch: u32 = 1;
var g_recursive_source_cache_ast: ?*Ast = null;
var g_recursive_source_cache: []?[]const u8 = &[_]?[]const u8{};
var g_recursive_source_cache_epochs: []u32 = &[_]u32{};
var g_recursive_source_cache_epoch: u32 = 1;
var g_reindent_subtree_cache_ast: ?*Ast = null;
var g_reindent_subtree_cache: []u8 = &[_]u8{};
var g_reindent_subtree_cache_epochs: []u32 = &[_]u32{};
var g_reindent_subtree_cache_epoch: u32 = 1;
var g_transparent_return_cache_ast: ?*Ast = null;
var g_transparent_return_cache: []u8 = &[_]u8{};
var g_class_field_value_ast: ?*Ast = null;
var g_class_field_values: []u8 = &[_]u8{};
var g_parenthesized_child_ast: ?*Ast = null;
var g_parenthesized_children: []u8 = &[_]u8{};
var g_node_parents: []u32 = &[_]u32{};
var g_node_parents_ready: bool = false;
var g_parent_session: ?*const session_mod.TransformSession = null;
const parent_none = std.math.maxInt(u32);
const resolved_binding_uncached = std.math.maxInt(u32);
const resolved_binding_none = std.math.maxInt(u32) - 1;
var g_resolved_binding_ast: ?*Ast = null;
var g_resolved_identifier_bindings: []u32 = &[_]u32{};
const ReplacementRange = struct {
    node_index: u32,
    start: u32,
    end: u32,
    text: []const u8,
    needs_reindent: bool,
};
const BlockRange = struct {
    start: u32,
    end: u32,
};
var g_replacement_ranges_ast: ?*Ast = null;
var g_replacement_ranges: std.ArrayListUnmanaged(ReplacementRange) = .empty;

pub fn createPass(config: Config) Pass {
    g_config = config;
    var exit_filter = visitor.NodeTagBitSet.initEmpty();
    exit_filter.set(@intFromEnum(Node.Tag.function_declaration));
    exit_filter.set(@intFromEnum(Node.Tag.function_expr));
    exit_filter.set(@intFromEnum(Node.Tag.async_function_declaration));
    exit_filter.set(@intFromEnum(Node.Tag.generator_declaration));
    exit_filter.set(@intFromEnum(Node.Tag.async_generator_declaration));
    exit_filter.set(@intFromEnum(Node.Tag.arrow_function_expr));
    exit_filter.set(@intFromEnum(Node.Tag.method_definition));
    exit_filter.set(@intFromEnum(Node.Tag.class_method));
    exit_filter.set(@intFromEnum(Node.Tag.class_private_method));
    exit_filter.set(@intFromEnum(Node.Tag.setter));
    return .{
        .name = "parameters",
        .node_filter = visitor.NodeTagBitSet.initEmpty(), // no enter work
        .exit_filter = exit_filter,
        .exit = enterNode, // Use exit so child transforms (spread) run first
        .priority = 35, // Run after arrow-functions (20) and block-scoping (30)
    };
}

pub fn resetState() void {
    g_rest_loop_counter = 0;
    g_ref_counter = 0;
    g_used_names = .{};
    g_binding_list_started = false;
    g_current_excluded_hoist_body = null;
    g_replacement_cache_ast = null;
    g_replacement_subtree_cache = &[_]u8{};
    g_replacement_subtree_cache_epochs = &[_]u32{};
    g_replacement_subtree_cache_epoch = 1;
    g_recursive_source_cache_ast = null;
    g_recursive_source_cache = &[_]?[]const u8{};
    g_recursive_source_cache_epochs = &[_]u32{};
    g_recursive_source_cache_epoch = 1;
    g_reindent_subtree_cache_ast = null;
    g_reindent_subtree_cache = &[_]u8{};
    g_reindent_subtree_cache_epochs = &[_]u32{};
    g_reindent_subtree_cache_epoch = 1;
    g_transparent_return_cache_ast = null;
    g_transparent_return_cache = &[_]u8{};
    g_class_field_value_ast = null;
    g_class_field_values = &[_]u8{};
    g_parenthesized_child_ast = null;
    g_parenthesized_children = &[_]u8{};
    g_node_parents = &[_]u32{};
    g_node_parents_ready = false;
    g_parent_session = null;
    g_resolved_binding_ast = null;
    g_resolved_identifier_bindings = &[_]u32{};
    g_replacement_ranges_ast = null;
    g_replacement_ranges = .empty;
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);
    var analysis = switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .method_definition,
        .class_method,
        .class_private_method,
        .setter,
        => analyzeFunctionNode(ctx, idx),
        .arrow_function_expr => analyzeArrowNode(ctx, idx),
        else => null,
    };
    if (analysis) |*resolved| {
        defer resolved.deinit(ctx.allocator);
        applyFunctionPlan(ctx, resolved);
    }
    return .continue_traversal;
}

// ── Parameter info ────────────────────────────────────────────────

const ParamKind = enum {
    normal, // simple identifier
    default_value, // identifier = expr
    rest, // ...identifier
    pattern, // destructuring pattern
    pattern_default, // destructuring = expr
};

const ParamInfo = struct {
    kind: ParamKind,
    node: NodeIndex,
    name: []const u8, // parameter name (for simple id/rest)
    index: u32, // argument index
    arg_index: u32, // runtime arguments[] index (excludes TS/Flow this param)
};

const GenerationMode = enum {
    arrow_arguments_length,
    ignore_function_length,
    arguments_length,
};

const FunctionPath = enum {
    none,
    simple_function,
    simple_arrow,
    complex_function,
    complex_arrow,
};

const FunctionAnalysis = struct {
    idx: NodeIndex,
    node_i: u32,
    tag: Node.Tag,
    body_node: NodeIndex = .none,
    params: std.ArrayListUnmanaged(ParamInfo) = .empty,
    rest_param: ?ParamInfo = null,
    has_defaults: bool = false,
    has_rest: bool = false,
    has_destructuring: bool = false,
    is_old_arrow_format: bool = false,

    fn deinit(self: *FunctionAnalysis, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
    }
};

const GenerationPlan = struct {
    path: FunctionPath,
    mode: GenerationMode,
    node_i: u32,
    first_special: u32,
};

const GenerationContext = struct {
    analysis: *const FunctionAnalysis,
    plan: GenerationPlan,

    fn resetCaches(self: *const GenerationContext, ctx: *TransformContext) void {
        _ = self;
        invalidateReplacementSubtreeCache(ctx);
        invalidateRecursiveSourceCache(ctx);
    }
};

fn analyzeFunctionParams(ctx: *TransformContext, analysis: *FunctionAnalysis) void {
    assignRuntimeArgumentIndices(ctx, analysis.params.items);
    for (analysis.params.items) |param| {
        switch (param.kind) {
            .default_value => analysis.has_defaults = true,
            .pattern_default => {
                analysis.has_defaults = true;
                analysis.has_destructuring = true;
            },
            .rest => {
                analysis.has_rest = true;
                analysis.rest_param = param;
                if (shadowBindingNode(ctx, param) != null) {
                    analysis.has_destructuring = true;
                }
            },
            .pattern => {
                analysis.has_defaults = true;
                analysis.has_destructuring = true;
            },
            else => {},
        }
    }
}

fn analyzeArrowNode(ctx: *TransformContext, idx: NodeIndex) ?FunctionAnalysis {
    const data = ctx.nodeData(idx);
    var analysis = FunctionAnalysis{
        .idx = idx,
        .node_i = @intFromEnum(idx),
        .tag = .arrow_function_expr,
    };

    // Parse the arrow's extra data to get params and body
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return null;

    const first = ctx.ast.extra_data.items[extra_idx];
    const second = ctx.ast.extra_data.items[extra_idx + 1];
    const third = ctx.ast.extra_data.items[extra_idx + 2];

    var params_start: u32 = 0;
    var params_end: u32 = 0;

    if (first == @intFromEnum(NodeIndex.none) or third == 1) {
        // Old format: param, body, count
        analysis.is_old_arrow_format = true;
        analysis.body_node = @enumFromInt(second);
        // Single param — check if it has a default
        const single_param: NodeIndex = @enumFromInt(first);
        if (single_param == .none) return null;
        analysis.params.append(ctx.allocator, classifyParam(ctx, single_param, 0)) catch return null;
        analyzeFunctionParams(ctx, &analysis);
        return analysis;
    }

    // New format: range_start, range_end, body
    params_start = first;
    params_end = second;
    analysis.body_node = @enumFromInt(third);

    if (params_start >= params_end) return null;
    if (analysis.body_node == .none) return null;

    // Parse all parameters
    for (ctx.ast.extra_data.items[params_start..params_end], 0..) |param_raw, pi| {
        const param: NodeIndex = @enumFromInt(param_raw);
        if (param == .none) continue;
        analysis.params.append(ctx.allocator, classifyParam(ctx, param, @intCast(pi))) catch continue;
    }
    analyzeFunctionParams(ctx, &analysis);
    return analysis;
}

fn analyzeFunctionNode(ctx: *TransformContext, idx: NodeIndex) ?FunctionAnalysis {
    const data = ctx.nodeData(idx);
    const tag = ctx.nodeTag(idx);
    var analysis = FunctionAnalysis{
        .idx = idx,
        .node_i = @intFromEnum(idx),
        .tag = tag,
    };

    // Get function structure:
    // functions: extra = [name_token, params_start, params_end, body]
    // setters:   extra = [params_start, params_end, body, flags, computed_key]
    const extra_idx = @intFromEnum(data.extra);
    const params_start, const params_end, const body_node = switch (tag) {
        .setter => blk: {
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return null;
            break :blk .{
                ctx.ast.extra_data.items[extra_idx],
                ctx.ast.extra_data.items[extra_idx + 1],
                @as(NodeIndex, @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2])),
            };
        },
        else => blk: {
            if (extra_idx + 3 >= ctx.ast.extra_data.items.len) return null;
            break :blk .{
                ctx.ast.extra_data.items[extra_idx + 1],
                ctx.ast.extra_data.items[extra_idx + 2],
                @as(NodeIndex, @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3])),
            };
        },
    };
    analysis.body_node = body_node;

    if (params_start >= params_end) return null;
    if (analysis.body_node == .none) return null;

    for (ctx.ast.extra_data.items[params_start..params_end], 0..) |param_raw, pi| {
        const param: NodeIndex = @enumFromInt(param_raw);
        if (param == .none) continue;
        analysis.params.append(ctx.allocator, classifyParam(ctx, param, @intCast(pi))) catch continue;
    }
    analyzeFunctionParams(ctx, &analysis);
    return analysis;
}

fn classifyGenerationMode(analysis: *const FunctionAnalysis) GenerationMode {
    if (analysis.tag == .arrow_function_expr) return .arrow_arguments_length;
    if (analysis.tag == .setter or g_config.ignore_function_length or g_config.loose) {
        return .ignore_function_length;
    }
    return .arguments_length;
}

fn findFirstSpecialParamIndex(params: []const ParamInfo) u32 {
    for (params, 0..) |p, pi| {
        if (p.kind == .default_value or p.kind == .pattern_default or p.kind == .rest) {
            return @intCast(pi);
        }
    }
    return @intCast(params.len);
}

fn canUseSimpleFunctionReplacement(ctx: *TransformContext, analysis: *const FunctionAnalysis) bool {
    if (analysis.has_destructuring) return false;
    if (getFunctionWrapInfo(ctx, analysis.idx, analysis.tag).is_generator) return false;
    if (findShadowedParams(ctx, analysis.params.items, analysis.body_node).len > 0) return false;
    if (needsParamOuterBindingIife(ctx, analysis.idx, analysis.params.items)) return false;
    return true;
}

fn canUseSimpleArrowReplacement(ctx: *TransformContext, analysis: *const FunctionAnalysis) bool {
    if (!canUseSimpleFunctionReplacement(ctx, analysis)) return false;
    if (isInClassField(ctx, analysis.idx)) return false;
    return true;
}

fn classifyFunctionPath(ctx: *TransformContext, analysis: *const FunctionAnalysis, mode: GenerationMode) FunctionPath {
    if (!analysis.has_defaults and !analysis.has_rest) return .none;
    const use_simple = switch (mode) {
        .arrow_arguments_length => canUseSimpleArrowReplacement(ctx, analysis),
        .ignore_function_length, .arguments_length => canUseSimpleFunctionReplacement(ctx, analysis),
    };
    return switch (mode) {
        .arrow_arguments_length => if (use_simple) .simple_arrow else .complex_arrow,
        .ignore_function_length, .arguments_length => if (use_simple) .simple_function else .complex_function,
    };
}

fn applyFunctionPlan(ctx: *TransformContext, analysis: *const FunctionAnalysis) void {
    const mode = classifyGenerationMode(analysis);
    const path = classifyFunctionPath(ctx, analysis, mode);
    if (path == .none) return;

    var generation = GenerationContext{
        .analysis = analysis,
        .plan = .{
            .path = path,
            .mode = mode,
            .node_i = analysis.node_i,
            .first_special = findFirstSpecialParamIndex(analysis.params.items),
        },
    };
    generation.resetCaches(ctx);

    switch (generation.plan.path) {
        .none => unreachable,
        .simple_function => buildSimpleFunctionReplacement(ctx, &generation),
        .simple_arrow => buildSimpleArrowReplacement(ctx, &generation),
        .complex_function, .complex_arrow => buildComplexFunctionReplacement(ctx, &generation),
    }
}

fn buildSimpleFunctionReplacement(
    ctx: *TransformContext,
    generation: *const GenerationContext,
) void {
    const analysis = generation.analysis;
    const plan = generation.plan;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    g_binding_list_started = false;
    const prev_hoist_body = g_current_excluded_hoist_body;
    g_current_excluded_hoist_body = findEnclosingHoistBody(ctx, analysis.idx);
    defer g_current_excluded_hoist_body = prev_hoist_body;

    emitFunctionHeader(&buf, ctx, analysis.idx, analysis.tag);
    buf.append(ctx.allocator, '(') catch return;

    switch (plan.mode) {
        .ignore_function_length => {
            var first = true;
            for (analysis.params.items) |p| {
                if (p.kind == .rest) continue;
                if (!first) buf.appendSlice(ctx.allocator, ", ") catch return;
                first = false;
                buf.appendSlice(ctx.allocator, getKeptParamSource(ctx, p)) catch return;
            }
        },
        .arguments_length => {
            for (analysis.params.items[0..plan.first_special], 0..) |p, pi| {
                if (pi > 0) buf.appendSlice(ctx.allocator, ", ") catch return;
                buf.appendSlice(ctx.allocator, getKeptParamSource(ctx, p)) catch return;
            }
        },
        .arrow_arguments_length => unreachable,
    }

    buf.appendSlice(ctx.allocator, ") {\n") catch return;

    switch (plan.mode) {
        .ignore_function_length => {
            for (analysis.params.items) |p| {
                if (p.kind != .default_value) continue;
                buf.appendSlice(ctx.allocator, "  if (") catch return;
                buf.appendSlice(ctx.allocator, p.name) catch return;
                buf.appendSlice(ctx.allocator, " === void 0) {\n    ") catch return;
                buf.appendSlice(ctx.allocator, p.name) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, getParamDefaultSource(ctx, p)) catch return;
                buf.appendSlice(ctx.allocator, ";\n  }\n") catch return;
            }
        },
        .arguments_length => {
            for (analysis.params.items, 0..) |p, pi| {
                switch (p.kind) {
                    .default_value => {
                        const use_name = if (std.mem.eql(u8, p.name, "arguments")) "_arguments" else p.name;
                        const binding_source = getParamBindingSource(ctx, p);
                        const binding_name = if (std.mem.eql(u8, use_name, p.name)) binding_source else use_name;
                        emitArgumentsDefaultBinding(&buf, ctx, binding_name, getParamIndexSource(ctx, p), getParamDefaultSource(ctx, p), "  ");
                        finishBindingList(&buf, ctx);
                    },
                    .normal => {
                        if (pi < plan.first_special) continue;
                        emitArgumentsValueBinding(&buf, ctx, getParamBindingSource(ctx, p), getParamIndexSource(ctx, p), "  ");
                        finishBindingList(&buf, ctx);
                    },
                    .rest => {},
                    .pattern, .pattern_default => unreachable,
                }
            }
        },
        .arrow_arguments_length => unreachable,
    }

    if (analysis.rest_param) |rp| {
        if (plan.mode == .arguments_length and analysis.params.items.len == 1 and plan.first_special == 0) {
            if (tryEmitCapturedLoopRestRewrite(&buf, ctx, analysis.body_node, rp)) {
                if (analysis.tag == .function_expr) {
                    buf.appendSlice(ctx.allocator, "  }") catch return;
                } else {
                    buf.appendSlice(ctx.allocator, "}") catch return;
                }
                putReplacement(ctx, generation.plan.node_i, buf.items);
                return;
            }
        }
    }

    if (analysis.rest_param) |rp| switch (tryApplyRestUsageOptimizations(ctx, analysis.body_node, rp, true)) {
        .failed => {
            emitBodyPrefixIntoBuffer(&buf, ctx, analysis.body_node, "  ");
            const rest_binding = emitRestLoop(&buf, ctx, rp, rp.arg_index);
            renameRestArgumentsBinding(ctx, rp, analysis.body_node);
            applyMaterializedRestSpreadLowering(ctx, analysis.body_node, rp, rest_binding);
        },
        .elided => restoreElidedRestShadowBinding(ctx, analysis.idx, analysis.body_node, rp),
        .materialized => {},
    };

    if (plan.mode == .arguments_length and g_config.emit_var_bindings and g_binding_list_started) {
        buf.appendSlice(ctx.allocator, ";\n") catch return;
    }

    emitTransformedBodyWithIndent(&buf, ctx, analysis.body_node, "  ");
    buf.appendSlice(ctx.allocator, "}") catch return;
    putReplacement(ctx, generation.plan.node_i, buf.items);
}

fn buildSimpleArrowReplacement(
    ctx: *TransformContext,
    generation: *const GenerationContext,
) void {
    const analysis = generation.analysis;
    const plan = generation.plan;
    if (plan.mode != .arrow_arguments_length) unreachable;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const binding_keyword = if (g_config.emit_var_bindings) "  var " else "  let ";
    g_binding_list_started = false;
    const prev_hoist_body = g_current_excluded_hoist_body;
    g_current_excluded_hoist_body = findEnclosingHoistBody(ctx, analysis.idx);
    defer g_current_excluded_hoist_body = prev_hoist_body;

    const mt = ctx.mainToken(analysis.idx);
    const mt_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(mt)];
    const is_async = (mt_tag == .kw_async) or ctx.ast.async_arrow_flags.contains(analysis.node_i);
    const body_tag = ctx.nodeTag(analysis.body_node);

    if (is_async) buf.appendSlice(ctx.allocator, "async ") catch return;
    buf.appendSlice(ctx.allocator, "function ") catch return;
    buf.append(ctx.allocator, '(') catch return;
    for (analysis.params.items[0..plan.first_special], 0..) |p, pi| {
        if (pi > 0) buf.appendSlice(ctx.allocator, ", ") catch return;
        buf.appendSlice(ctx.allocator, getKeptParamSource(ctx, p)) catch return;
    }
    buf.appendSlice(ctx.allocator, ") {\n") catch return;

    if (ctx.ast.block_prefix_source.get(analysis.node_i)) |arrow_prefix| {
        emitIndentedSnippet(&buf, ctx, arrow_prefix, "  ");
    }

    for (analysis.params.items, 0..) |p, pi| {
        switch (p.kind) {
            .default_value => {
                buf.appendSlice(ctx.allocator, binding_keyword) catch return;
                buf.appendSlice(ctx.allocator, getParamBindingSource(ctx, p)) catch return;
                buf.appendSlice(ctx.allocator, " = arguments.length > ") catch return;
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch return;
                buf.appendSlice(ctx.allocator, " && arguments[") catch return;
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch return;
                buf.appendSlice(ctx.allocator, "] !== undefined ? arguments[") catch return;
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch return;
                buf.appendSlice(ctx.allocator, "] : ") catch return;
                appendInlineMultilineSource(&buf, ctx, getParamDefaultSource(ctx, p));
                buf.appendSlice(ctx.allocator, ";\n") catch return;
            },
            .normal => {
                if (pi < plan.first_special) continue;
                buf.appendSlice(ctx.allocator, binding_keyword) catch return;
                buf.appendSlice(ctx.allocator, getParamBindingSource(ctx, p)) catch return;
                buf.appendSlice(ctx.allocator, " = arguments.length > ") catch return;
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch return;
                buf.appendSlice(ctx.allocator, " ? arguments[") catch return;
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch return;
                buf.appendSlice(ctx.allocator, "] : undefined;\n") catch return;
            },
            .rest => {},
            .pattern, .pattern_default => unreachable,
        }
    }

    if (analysis.rest_param) |rp| {
        if (analysis.params.items.len == 1 and plan.first_special == 0) {
            if (tryEmitCapturedLoopRestRewrite(&buf, ctx, analysis.body_node, rp)) {
                buf.appendSlice(ctx.allocator, "}") catch return;
                putReplacement(ctx, generation.plan.node_i, wrapArrowSpecReplacement(ctx, analysis.idx, buf.items));
                markReplacementNeedsReindent(ctx, generation.plan.node_i);
                return;
            }
        }
    }

    const skip_rest_optimization = ctx.ast.block_prefix_source.get(analysis.node_i) != null;
    if (analysis.rest_param) |rp| switch (if (skip_rest_optimization) RestOptimizationResult.failed else tryApplyRestUsageOptimizations(ctx, analysis.body_node, rp, body_tag == .block_statement)) {
        .failed => {
            emitBodyPrefixIntoBuffer(&buf, ctx, analysis.body_node, "  ");
            const rest_binding = emitRestLoop(&buf, ctx, rp, rp.arg_index);
            renameRestArgumentsBinding(ctx, rp, analysis.body_node);
            applyMaterializedRestSpreadLowering(ctx, analysis.body_node, rp, rest_binding);
        },
        .elided => restoreElidedRestShadowBinding(ctx, analysis.idx, analysis.body_node, rp),
        .materialized => {},
    };

    if (body_tag == .block_statement) {
        emitTransformedBodyWithIndent(&buf, ctx, analysis.body_node, "  ");
    } else {
        const body_src = getGeneratedSource(ctx, analysis.body_node);
        buf.appendSlice(ctx.allocator, "  return ") catch return;
        buf.appendSlice(ctx.allocator, body_src) catch return;
        buf.appendSlice(ctx.allocator, ";\n") catch return;
    }

    buf.appendSlice(ctx.allocator, "}") catch return;
    putReplacement(ctx, generation.plan.node_i, wrapArrowSpecReplacement(ctx, analysis.idx, buf.items));
    markReplacementNeedsReindent(ctx, generation.plan.node_i);
}

fn buildComplexFunctionReplacement(
    ctx: *TransformContext,
    generation: *const GenerationContext,
) void {
    const analysis = generation.analysis;
    const plan = generation.plan;
    switch (plan.mode) {
        .arrow_arguments_length => buildArrowArgumentsLength(
            ctx,
            plan.node_i,
            analysis.idx,
            analysis.params.items,
            analysis.rest_param,
            analysis.body_node,
            analysis.is_old_arrow_format,
            plan.first_special,
        ),
        .ignore_function_length => buildIgnoreFunctionLength(
            ctx,
            plan.node_i,
            analysis.idx,
            analysis.tag,
            analysis.params.items,
            analysis.rest_param,
            analysis.body_node,
        ),
        .arguments_length => buildArgumentsLength(
            ctx,
            plan.node_i,
            analysis.idx,
            analysis.tag,
            analysis.params.items,
            analysis.rest_param,
            analysis.body_node,
            plan.first_special,
        ),
    }
}

/// Build arguments.length replacement for arrow functions.
/// Converts: (a = 1) => { body } -> function() { var a = arguments[0] ... ; body }
fn buildArrowArgumentsLength(
    ctx: *TransformContext,
    node_i: u32,
    idx: NodeIndex,
    params: []const ParamInfo,
    rest_param: ?ParamInfo,
    body_node: NodeIndex,
    is_old_format: bool,
    first_special: u32,
) void {
    _ = is_old_format;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const binding_keyword = if (g_config.emit_var_bindings) "  var " else "  let ";
    g_binding_list_started = false;
    const prev_hoist_body = g_current_excluded_hoist_body;
    g_current_excluded_hoist_body = findEnclosingHoistBody(ctx, idx);
    defer g_current_excluded_hoist_body = prev_hoist_body;
    const pattern_temps = buildPatternTemps(ctx, params);
    defer ctx.allocator.free(pattern_temps);

    // Check if async
    const mt = ctx.mainToken(idx);
    const mt_tag = ctx.ast.tokens.items(.tag)[@intFromEnum(mt)];
    const is_async = (mt_tag == .kw_async) or ctx.ast.async_arrow_flags.contains(node_i);
    const in_class_field = isInClassField(ctx, idx);
    const shadowed_params = findShadowedParams(ctx, params, body_node);
    const needs_iife = shadowed_params.len > 0 or needsParamOuterBindingIife(ctx, idx, params);
    const body_tag = ctx.nodeTag(body_node);
    const needs_wrapper_iife = in_class_field or (body_tag != .block_statement and needs_iife);
    const wrapper_captures = if (needs_wrapper_iife)
        rewriteParamIifeLexicalCaptures(ctx, body_node)
    else
        ParamIifeCaptureInfo{};
    const wrapper_hoist_body = if (needs_wrapper_iife)
        findEnclosingArrowBlockBody(ctx, idx)
    else
        null;
    if (wrapper_hoist_body) |hoist_body| {
        var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;
        emitParamIifeCaptureBindings(&prefix_buf, ctx, wrapper_captures, "");
        if (prefix_buf.items.len != 0) {
            appendPrefixToBody(ctx, hoist_body, std.mem.trimEnd(u8, prefix_buf.items, "\n"));
        }
    }
    const should_wrap_iife = needs_wrapper_iife and wrapper_hoist_body == null;

    if (is_async) buf.appendSlice(ctx.allocator, "async ") catch return;
    buf.appendSlice(ctx.allocator, "function ") catch return;

    buf.append(ctx.allocator, '(') catch return;
    for (params[0..first_special], 0..) |p, pi| {
        if (pi > 0) buf.appendSlice(ctx.allocator, ", ") catch {};
        switch (p.kind) {
            .pattern => buf.appendSlice(ctx.allocator, getKeptPatternParamSource(ctx, p, pattern_temps[pi])) catch {},
            else => buf.appendSlice(ctx.allocator, getKeptParamSource(ctx, p)) catch {},
        }
    }
    buf.appendSlice(ctx.allocator, ") {\n") catch return;

    if (ctx.ast.block_prefix_source.get(node_i)) |arrow_prefix| {
        emitIndentedSnippet(&buf, ctx, arrow_prefix, "  ");
    }

    // Emit var statements for default params
    for (params, 0..) |p, pi| {
        switch (p.kind) {
            .default_value => {
                buf.appendSlice(ctx.allocator, binding_keyword) catch {};
                buf.appendSlice(ctx.allocator, getParamBindingSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, " = arguments.length > ") catch {};
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, " && arguments[") catch {};
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, "] !== undefined ? arguments[") catch {};
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, "] : ") catch {};
                appendInlineMultilineSource(&buf, ctx, getParamDefaultSource(ctx, p));
                buf.appendSlice(ctx.allocator, ";\n") catch {};
            },
            .normal => {
                if (pi < first_special) continue;
                buf.appendSlice(ctx.allocator, binding_keyword) catch {};
                buf.appendSlice(ctx.allocator, getParamBindingSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, " = arguments.length > ") catch {};
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, " ? arguments[") catch {};
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, "] : undefined;\n") catch {};
            },
            .rest => {},
            .pattern => {
                if (pi < first_special) {
                    emitPatternBindingStatements(&buf, ctx, patternNode(ctx, p), pattern_temps[pi], "  ");
                } else {
                    const temp = pattern_temps[pi];
                    buf.appendSlice(ctx.allocator, binding_keyword) catch {};
                    buf.appendSlice(ctx.allocator, temp) catch {};
                    buf.appendSlice(ctx.allocator, " = arguments.length > ") catch {};
                    buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                    buf.appendSlice(ctx.allocator, " ? arguments[") catch {};
                    buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                    buf.appendSlice(ctx.allocator, "] : undefined;\n") catch {};
                    emitPatternBindingStatements(&buf, ctx, patternNode(ctx, p), temp, "  ");
                }
            },
            .pattern_default => {
                const temp = pattern_temps[pi];
                buf.appendSlice(ctx.allocator, binding_keyword) catch {};
                buf.appendSlice(ctx.allocator, temp) catch {};
                buf.appendSlice(ctx.allocator, " = arguments.length > ") catch {};
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, " ? arguments[") catch {};
                buf.appendSlice(ctx.allocator, getParamIndexSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, "] : undefined;\n") catch {};
                const pattern_init = std.fmt.allocPrint(
                    ctx.allocator,
                    "{s} === void 0 ? {s} : {s}",
                    .{ temp, getParamDefaultSource(ctx, p), temp },
                ) catch temp;
                emitPatternBindingStatements(&buf, ctx, patternNode(ctx, p), pattern_init, "  ");
            },
        }
    }

    if (rest_param) |rp| {
        if (params.len == 1 and first_special == 0) {
            if (tryEmitCapturedLoopRestRewrite(&buf, ctx, body_node, rp)) {
                buf.appendSlice(ctx.allocator, "}") catch return;
                const wrapped = if (should_wrap_iife)
                    wrapArrowCaptureIife(ctx, buf.items, wrapper_captures)
                else
                    buf.items;
                putReplacement(ctx, node_i, wrapArrowSpecReplacement(ctx, idx, wrapped));
                markReplacementNeedsReindent(ctx, node_i);
                return;
            }
        }
    }

    // Emit rest parameter loop if present
    const skip_rest_optimization = ctx.ast.block_prefix_source.get(node_i) != null;
    if (rest_param) |rp| switch (if (skip_rest_optimization) RestOptimizationResult.failed else tryApplyRestUsageOptimizations(ctx, body_node, rp, body_tag == .block_statement)) {
        .failed => {
            emitBodyPrefixIntoBuffer(&buf, ctx, body_node, "  ");
            const rest_binding = emitRestLoop(&buf, ctx, rp, rp.arg_index);
            renameRestArgumentsBinding(ctx, rp, body_node);
            applyMaterializedRestSpreadLowering(ctx, body_node, rp, rest_binding);
        },
        .elided => restoreElidedRestShadowBinding(ctx, idx, body_node, rp),
        .materialized => {},
    };

    // Emit original body content
    if (body_tag == .block_statement) {
        if (needs_iife) {
            buf.appendSlice(ctx.allocator, "  return ") catch return;
            if (is_async) buf.appendSlice(ctx.allocator, "async ") catch return;
            buf.appendSlice(ctx.allocator, "function (") catch return;
            for (shadowed_params, 0..) |sp, si| {
                if (si > 0) buf.appendSlice(ctx.allocator, ", ") catch {};
                buf.appendSlice(ctx.allocator, sp) catch {};
            }
            buf.appendSlice(ctx.allocator, ") {\n") catch return;
            emitTransformedBodyWithIndent(&buf, ctx, body_node, "    ");
            buf.appendSlice(ctx.allocator, "  }(") catch return;
            for (shadowed_params, 0..) |sp, si| {
                if (si > 0) buf.appendSlice(ctx.allocator, ", ") catch {};
                buf.appendSlice(ctx.allocator, sp) catch {};
            }
            buf.appendSlice(ctx.allocator, ");\n") catch return;
        } else {
            emitTransformedBodyWithIndent(&buf, ctx, body_node, "  ");
        }
    } else {
        // Expression body: wrap in return statement
        const body_src = getGeneratedSource(ctx, body_node);
        buf.appendSlice(ctx.allocator, "  return ") catch {};
        buf.appendSlice(ctx.allocator, body_src) catch {};
        buf.appendSlice(ctx.allocator, ";\n") catch {};
    }

    buf.appendSlice(ctx.allocator, "}") catch return;

    const wrapped = if (should_wrap_iife)
        wrapArrowCaptureIife(ctx, buf.items, wrapper_captures)
    else
        buf.items;
    putReplacement(ctx, node_i, wrapArrowSpecReplacement(ctx, idx, wrapped));
    markReplacementNeedsReindent(ctx, node_i);
}

/// Check if a node is inside a class field (class property initializer).
fn isInClassField(ctx: *TransformContext, node_idx: NodeIndex) bool {
    const ni = @intFromEnum(node_idx);
    ensureClassFieldValueIndex(ctx);
    return ni < g_class_field_values.len and g_class_field_values[ni] != 0;
}

/// Get the name of an arrow function from its variable assignment.
fn getArrowName(ctx: *TransformContext, arrow_idx: NodeIndex) ?[]const u8 {
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        if (tag != .declarator) continue;
        const d = datas[ni];
        if (d.binary.rhs == arrow_idx) {
            const name_node = d.binary.lhs;
            if (name_node != .none and tags[@intFromEnum(name_node)] == .identifier) {
                return ctx.tokenSlice(ctx.ast.nodes.items(.main_token)[@intFromEnum(name_node)]);
            }
        }
    }
    return null;
}

// ── Classify parameter ────────────────────────────────────────────

fn classifyParam(ctx: *TransformContext, param: NodeIndex, index: u32) ParamInfo {
    const ptag = ctx.nodeTag(param);
    switch (ptag) {
        .identifier => {
            const name = ctx.tokenSlice(ctx.mainToken(param));
            return .{
                .kind = .normal,
                .node = param,
                .name = name,
                .index = index,
                .arg_index = index,
            };
        },
        .assignment_pattern => {
            // assignment_pattern: binary.lhs = pattern, binary.rhs = default
            const d = ctx.nodeData(param);
            const left = d.binary.lhs;
            const left_tag = ctx.nodeTag(left);

            if (left_tag == .identifier) {
                return .{
                    .kind = .default_value,
                    .node = param,
                    .name = ctx.tokenSlice(ctx.mainToken(left)),
                    .index = index,
                    .arg_index = index,
                };
            } else {
                // Destructuring with default
                return .{
                    .kind = .pattern_default,
                    .node = param,
                    .name = "",
                    .index = index,
                    .arg_index = index,
                };
            }
        },
        .rest_element => {
            const d = ctx.nodeData(param);
            const inner = d.unary;
            var name: []const u8 = "rest";
            if (inner != .none and ctx.nodeTag(inner) == .identifier) {
                name = ctx.tokenSlice(ctx.mainToken(inner));
            }
            return .{
                .kind = .rest,
                .node = param,
                .name = name,
                .index = index,
                .arg_index = index,
            };
        },
        .object_pattern, .array_pattern => {
            return .{
                .kind = .pattern,
                .node = param,
                .name = "",
                .index = index,
                .arg_index = index,
            };
        },
        else => {
            return .{
                .kind = .normal,
                .node = param,
                .name = "",
                .index = index,
                .arg_index = index,
            };
        },
    }
}

fn assignRuntimeArgumentIndices(ctx: *TransformContext, params: []ParamInfo) void {
    _ = ctx;
    if (params.len == 0) return;
    const has_this_param = params[0].kind == .normal and std.mem.eql(u8, params[0].name, "this");
    for (params) |*param| {
        param.arg_index = if (has_this_param and param.index > 0) param.index - 1 else param.index;
    }
}

// ── ignoreFunctionLength mode ─────────────────────────────────────
// function f(a, b = 1) {} ->
// function f(a, b) { if (b === void 0) { b = 1; } }

fn buildIgnoreFunctionLength(
    ctx: *TransformContext,
    node_i: u32,
    idx: NodeIndex,
    tag: Node.Tag,
    params: []const ParamInfo,
    rest_param: ?ParamInfo,
    body_node: NodeIndex,
) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    g_binding_list_started = false;
    const prev_hoist_body = g_current_excluded_hoist_body;
    g_current_excluded_hoist_body = findEnclosingHoistBody(ctx, idx);
    defer g_current_excluded_hoist_body = prev_hoist_body;
    const pattern_temps = buildPatternTemps(ctx, params);
    defer ctx.allocator.free(pattern_temps);
    const param_temps = buildIgnoreFunctionLengthParamTemps(ctx, params, pattern_temps);
    defer ctx.allocator.free(param_temps);

    // Build function header
    emitFunctionHeader(&buf, ctx, idx, tag);

    // Build param list: keep normal params, replace defaults with just name,
    // remove rest param, keep patterns as temp names
    buf.append(ctx.allocator, '(') catch return;
    var first = true;
    var last_normal_index: i32 = -1;
    for (params) |p| {
        if (p.kind == .rest) continue; // rest is removed from params

        if (!first) buf.appendSlice(ctx.allocator, ", ") catch {};
        first = false;

        switch (p.kind) {
            .normal => {
                buf.appendSlice(ctx.allocator, getKeptParamSource(ctx, p)) catch {};
                last_normal_index = @intCast(p.index);
            },
            .default_value => {
                buf.appendSlice(ctx.allocator, getKeptParamSource(ctx, p)) catch {};
                last_normal_index = @intCast(p.index);
            },
            .pattern => {
                const temp = getKeptPatternParamSource(ctx, p, param_temps[p.index]);
                buf.appendSlice(ctx.allocator, temp) catch {};
                last_normal_index = @intCast(p.index);
            },
            .pattern_default => {
                const temp = getKeptPatternParamSource(ctx, p, param_temps[p.index]);
                buf.appendSlice(ctx.allocator, temp) catch {};
                last_normal_index = @intCast(p.index);
            },
            .rest => {},
        }
    }
    buf.appendSlice(ctx.allocator, ") {\n") catch return;

    // Emit default checks: if (b === void 0) { b = default; }
    for (params) |p| {
        switch (p.kind) {
            .default_value => {
                buf.appendSlice(ctx.allocator, "  if (") catch {};
                buf.appendSlice(ctx.allocator, p.name) catch {};
                buf.appendSlice(ctx.allocator, " === void 0) {\n    ") catch {};
                buf.appendSlice(ctx.allocator, p.name) catch {};
                buf.appendSlice(ctx.allocator, " = ") catch {};
                buf.appendSlice(ctx.allocator, getParamDefaultSource(ctx, p)) catch {};
                buf.appendSlice(ctx.allocator, ";\n  }\n") catch {};
            },
            .pattern_default => {
                const temp = param_temps[p.index];
                const pattern_temp = pattern_temps[p.index];
                const pattern_init = std.fmt.allocPrint(
                    ctx.allocator,
                    "{s} === void 0 ? {s} : {s}",
                    .{ temp, getParamDefaultSource(ctx, p), temp },
                ) catch temp;
                emitVarBinding(&buf, ctx, pattern_temp, pattern_init, "  ");
                emitPatternBindingStatements(&buf, ctx, patternNode(ctx, p), pattern_temp, "  ");
                finishBindingList(&buf, ctx);
            },
            .pattern => {
                emitPatternBindingStatements(&buf, ctx, patternNode(ctx, p), pattern_temps[p.index], "  ");
                finishBindingList(&buf, ctx);
            },
            else => {},
        }
    }

    // Emit rest parameter loop if present
    if (rest_param) |rp| switch (tryApplyRestUsageOptimizations(ctx, body_node, rp, true)) {
        .failed => {
            emitBodyPrefixIntoBuffer(&buf, ctx, body_node, "  ");
            const rest_binding = emitRestLoop(&buf, ctx, rp, rp.arg_index);
            renameRestArgumentsBinding(ctx, rp, body_node);
            applyMaterializedRestSpreadLowering(ctx, body_node, rp, rest_binding);
        },
        .elided => restoreElidedRestShadowBinding(ctx, idx, body_node, rp),
        .materialized => {},
    };

    // Emit original body content
    emitTransformedBodyWithIndent(&buf, ctx, body_node, "  ");

    buf.appendSlice(ctx.allocator, "}") catch return;

    putReplacement(ctx, node_i, buf.items);
}

// ── arguments.length mode (default) ───────────────────────────────
// function f(a, b = 1) {} ->
// function f(a) { var b = arguments.length > 1 && arguments[1] !== undefined ? arguments[1] : 1; }

fn buildArgumentsLength(
    ctx: *TransformContext,
    node_i: u32,
    idx: NodeIndex,
    tag: Node.Tag,
    params: []const ParamInfo,
    rest_param: ?ParamInfo,
    body_node: NodeIndex,
    first_special: u32,
) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    g_binding_list_started = false;
    const prev_hoist_body = g_current_excluded_hoist_body;
    g_current_excluded_hoist_body = findEnclosingHoistBody(ctx, idx);
    defer g_current_excluded_hoist_body = prev_hoist_body;
    const pattern_temps = buildPatternTemps(ctx, params);
    defer ctx.allocator.free(pattern_temps);

    // Pre-check for shadowed params to determine if IIFE wrapping is needed
    const shadowed_params_early = findShadowedParams(ctx, params, body_node);
    const wrap_info = getFunctionWrapInfo(ctx, idx, tag);
    const needs_iife = wrap_info.is_generator or shadowed_params_early.len > 0 or needsParamOuterBindingIife(ctx, idx, params);
    const needs_async_reject_wrapper = needs_iife and wrap_info.is_async and !wrap_info.is_generator;

    // Build function header — strip generator/async if IIFE wrapping
    if (needs_iife) {
        emitFunctionHeaderPlain(&buf, ctx, idx, tag);
    } else {
        emitFunctionHeader(&buf, ctx, idx, tag);
    }
    const stmt_indent = if (needs_async_reject_wrapper) "    " else "  ";
    const iife_body_indent = if (needs_async_reject_wrapper) "      " else "    ";
    const iife_captures = if (needs_iife)
        rewriteParamIifeLexicalCaptures(ctx, body_node)
    else
        ParamIifeCaptureInfo{};

    buf.append(ctx.allocator, '(') catch return;
    for (params[0..first_special], 0..) |p, pi| {
        if (pi > 0) buf.appendSlice(ctx.allocator, ", ") catch {};
        switch (p.kind) {
            .pattern => buf.appendSlice(ctx.allocator, getKeptPatternParamSource(ctx, p, pattern_temps[pi])) catch {},
            else => buf.appendSlice(ctx.allocator, getKeptParamSource(ctx, p)) catch {},
        }
    }
    buf.appendSlice(ctx.allocator, ") {\n") catch return;
    if (needs_async_reject_wrapper) {
        buf.appendSlice(ctx.allocator, "  try {\n") catch return;
    }
    emitParamIifeCaptureBindings(&buf, ctx, iife_captures, stmt_indent);

    // Emit var statements for default params
    for (params, 0..) |p, pi| {
        switch (p.kind) {
            .default_value => {
                // Check if the rest param has the same name as "arguments"
                const use_name = if (std.mem.eql(u8, p.name, "arguments")) "_arguments" else p.name;
                const binding_source = getParamBindingSource(ctx, p);
                const binding_name = if (std.mem.eql(u8, use_name, p.name)) binding_source else use_name;
                emitArgumentsDefaultBinding(&buf, ctx, binding_name, getParamIndexSource(ctx, p), getParamDefaultSource(ctx, p), stmt_indent);
                finishBindingList(&buf, ctx);
            },
            .normal => {
                // Normal param after first default — still needs arguments[] access
                if (pi < first_special) continue;
                emitArgumentsValueBinding(&buf, ctx, getParamBindingSource(ctx, p), getParamIndexSource(ctx, p), stmt_indent);
                finishBindingList(&buf, ctx);
            },
            .rest => {
                // Rest params handled below
            },
            .pattern => {
                if (pi < first_special) {
                    emitPatternBindingStatements(&buf, ctx, patternNode(ctx, p), pattern_temps[pi], stmt_indent);
                } else {
                    const temp = pattern_temps[pi];
                    emitArgumentsValueBinding(&buf, ctx, temp, getParamIndexSource(ctx, p), stmt_indent);
                    emitPatternBindingStatements(&buf, ctx, patternNode(ctx, p), temp, stmt_indent);
                }
                finishBindingList(&buf, ctx);
            },
            .pattern_default => {
                const temp = pattern_temps[pi];
                emitArgumentsDefaultBinding(&buf, ctx, temp, getParamIndexSource(ctx, p), getParamDefaultSource(ctx, p), stmt_indent);
                emitPatternBindingStatements(&buf, ctx, patternNode(ctx, p), temp, stmt_indent);
                finishBindingList(&buf, ctx);
            },
        }
    }

    if (rest_param) |rp| {
        if (params.len == 1 and first_special == 0) {
            if (tryEmitCapturedLoopRestRewrite(&buf, ctx, body_node, rp)) {
                if (tag == .function_expr) {
                    buf.appendSlice(ctx.allocator, "  }") catch return;
                } else {
                    buf.appendSlice(ctx.allocator, "}") catch return;
                }
                putReplacement(ctx, node_i, buf.items);
                return;
            }
        }
    }

    // Emit rest parameter loop if present
    if (rest_param) |rp| switch (tryApplyRestUsageOptimizations(ctx, body_node, rp, true)) {
        .failed => {
            emitBodyPrefixIntoBuffer(&buf, ctx, body_node, stmt_indent);
            const rest_binding = emitRestLoop(&buf, ctx, rp, rp.arg_index);
            renameRestArgumentsBinding(ctx, rp, body_node);
            applyMaterializedRestSpreadLowering(ctx, body_node, rp, rest_binding);
        },
        .elided => restoreElidedRestShadowBinding(ctx, idx, body_node, rp),
        .materialized => {},
    };

    if (g_config.emit_var_bindings and g_binding_list_started) {
        buf.appendSlice(ctx.allocator, ";\n") catch return;
    }

    // Check if any parameter name is redeclared with `var` in the body.
    // If so, wrap the body in an IIFE to avoid conflicts.
    const shadowed_params = shadowed_params_early;
    pruneIifeShadowedVarDeclarations(ctx, body_node, params);

    if (needs_iife) {
        // IIFE wrapping: return [async] function[*](a) { body }(a);
        buf.appendSlice(ctx.allocator, stmt_indent) catch return;
        buf.appendSlice(ctx.allocator, "return ") catch return;
        if (wrap_info.is_async) buf.appendSlice(ctx.allocator, "async ") catch return;
        buf.appendSlice(ctx.allocator, "function") catch return;
        if (wrap_info.is_generator) buf.append(ctx.allocator, '*') catch {};
        buf.appendSlice(ctx.allocator, " (") catch return;
        for (shadowed_params, 0..) |sp, si| {
            if (si > 0) buf.appendSlice(ctx.allocator, ", ") catch {};
            buf.appendSlice(ctx.allocator, sp) catch {};
        }
        if (isEmptyBlockStatement(ctx, body_node)) {
            buf.appendSlice(ctx.allocator, ") {}(") catch return;
        } else {
            buf.appendSlice(ctx.allocator, ") {\n") catch return;
            emitTransformedBodyWithIndent(&buf, ctx, body_node, iife_body_indent);
            buf.appendSlice(ctx.allocator, stmt_indent) catch return;
            buf.appendSlice(ctx.allocator, "}(") catch return;
        }
        for (shadowed_params, 0..) |sp, si| {
            if (si > 0) buf.appendSlice(ctx.allocator, ", ") catch {};
            buf.appendSlice(ctx.allocator, sp) catch {};
        }
        buf.appendSlice(ctx.allocator, ");\n") catch return;
    } else {
        // Emit original body content
        emitTransformedBodyWithIndent(&buf, ctx, body_node, stmt_indent);
    }

    if (needs_async_reject_wrapper) {
        buf.appendSlice(ctx.allocator, "  } catch (e) {\n") catch return;
        buf.appendSlice(ctx.allocator, "    return Promise.reject(e);\n") catch return;
        buf.appendSlice(ctx.allocator, "  }\n") catch return;
    }

    buf.appendSlice(ctx.allocator, "}") catch return;

    putReplacement(ctx, node_i, buf.items);
}

fn pruneIifeShadowedVarDeclarations(ctx: *TransformContext, body_node: NodeIndex, params: []const ParamInfo) void {
    if (body_node == .none or ctx.nodeTag(body_node) != .block_statement) return;

    var param_names: std.StringHashMapUnmanaged(void) = .empty;
    defer param_names.deinit(ctx.allocator);

    for (params) |p| {
        if (shadowBindingNode(ctx, p)) |pattern| {
            collectBindingNames(ctx, pattern, &param_names);
            continue;
        }
        if (p.kind == .rest) continue;
        if (p.name.len > 0) {
            param_names.put(ctx.allocator, p.name, {}) catch {};
        }
    }
    if (param_names.count() == 0) return;

    const body_extra = @intFromEnum(ctx.nodeData(body_node).extra);
    if (body_extra + 1 >= ctx.ast.extra_data.items.len) return;
    const stmt_start = ctx.ast.extra_data.items[body_extra];
    const stmt_end = ctx.ast.extra_data.items[body_extra + 1];

    for (ctx.ast.extra_data.items[stmt_start..stmt_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none or ctx.nodeTag(stmt) != .var_declaration) continue;

        const stmt_extra = @intFromEnum(ctx.nodeData(stmt).extra);
        if (stmt_extra + 1 >= ctx.ast.extra_data.items.len) continue;
        const decl_start = ctx.ast.extra_data.items[stmt_extra];
        const decl_end = ctx.ast.extra_data.items[stmt_extra + 1];

        var kept_count: usize = 0;
        var total_count: usize = 0;
        var rewrote_stmt = false;
        var buf: std.ArrayListUnmanaged(u8) = .empty;

        for (ctx.ast.extra_data.items[decl_start..decl_end]) |decl_raw| {
            const decl: NodeIndex = @enumFromInt(decl_raw);
            if (decl == .none or ctx.nodeTag(decl) != .declarator) continue;
            total_count += 1;
            if (shouldPruneIifeVarDeclarator(ctx, decl, &param_names)) continue;

            const decl_src = if (buildIifeShadowedDeclaratorSource(ctx, decl, &param_names)) |rewritten| blk: {
                rewrote_stmt = true;
                break :blk rewritten;
            } else getNodeSourceRecursive(ctx, decl);
            if (decl_src.len == 0) continue;
            if (kept_count == 0) {
                buf.appendSlice(ctx.allocator, "var ") catch return;
            } else {
                buf.appendSlice(ctx.allocator, ", ") catch return;
            }
            buf.appendSlice(ctx.allocator, decl_src) catch return;
            kept_count += 1;
        }

        if (kept_count == total_count and !rewrote_stmt) continue;
        if (kept_count == 0) {
            putReplacement(ctx, @intFromEnum(stmt), "");
            continue;
        }

        buf.append(ctx.allocator, ';') catch return;
        putReplacement(ctx, @intFromEnum(stmt), buf.items);
    }
}

fn buildIifeShadowedDeclaratorSource(
    ctx: *TransformContext,
    decl: NodeIndex,
    param_names: *const std.StringHashMapUnmanaged(void),
) ?[]const u8 {
    if (decl == .none or ctx.nodeTag(decl) != .declarator) return null;

    const lhs = ctx.nodeData(decl).binary.lhs;
    const rhs = ctx.nodeData(decl).binary.rhs;
    if (lhs == .none or rhs == .none) return null;

    const lhs_tag = ctx.nodeTag(lhs);
    if (lhs_tag != .object_pattern and lhs_tag != .array_pattern) return null;
    if (!patternBindsParamName(ctx, lhs, param_names)) return null;

    const temp_base = firstPatternBindingName(ctx, lhs) orelse return null;
    const temp_name = allocNextRefName(
        ctx,
        std.fmt.allocPrint(ctx.allocator, "_{s}", .{temp_base}) catch return null,
    );
    const init_source = formatIifeShadowedInitSource(ctx, rhs);

    var fragment: std.ArrayListUnmanaged(u8) = .empty;
    const prev_binding_list_started = g_binding_list_started;
    g_binding_list_started = false;
    defer g_binding_list_started = prev_binding_list_started;

    emitVarBinding(&fragment, ctx, temp_name, init_source, "");
    emitPatternBindingStatements(&fragment, ctx, lhs, temp_name, "");
    finishBindingList(&fragment, ctx);

    var result: []const u8 = fragment.items;
    if (std.mem.startsWith(u8, result, "var ")) result = result["var ".len..];
    result = std.mem.trimEnd(u8, result, ";\n");
    return result;
}

fn formatIifeShadowedInitSource(ctx: *TransformContext, rhs: NodeIndex) []const u8 {
    const init_source = getNodeSourceRecursive(ctx, rhs);
    if (rhs == .none or ctx.nodeTag(rhs) != .object_expr) return init_source;
    if (std.mem.indexOfScalar(u8, init_source, '\n') != null) return init_source;

    const trimmed = std.mem.trim(u8, init_source, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return init_source;

    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    if (inner.len == 0) return init_source;

    return std.fmt.allocPrint(ctx.allocator, "{{\n    {s}\n  }}", .{inner}) catch init_source;
}

fn shouldPruneIifeVarDeclarator(
    ctx: *TransformContext,
    decl: NodeIndex,
    param_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (decl == .none or ctx.nodeTag(decl) != .declarator) return false;
    if (ctx.nodeData(decl).binary.rhs != .none) return false;
    if (isForInOfDeclarator(ctx, decl)) return false;

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(ctx.allocator);
    collectBindingNames(ctx, ctx.nodeData(decl).binary.lhs, &names);
    if (names.count() == 0) return false;

    var iter = names.keyIterator();
    while (iter.next()) |name| {
        if (!param_names.contains(name.*)) return false;
    }
    return true;
}

fn patternBindsParamName(
    ctx: *TransformContext,
    pattern: NodeIndex,
    param_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (pattern == .none) return false;

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(ctx.allocator);
    collectBindingNames(ctx, pattern, &names);
    if (names.count() == 0) return false;

    var iter = names.keyIterator();
    while (iter.next()) |name| {
        if (param_names.contains(name.*)) return true;
    }
    return false;
}

fn firstPatternBindingName(ctx: *TransformContext, node: NodeIndex) ?[]const u8 {
    if (node == .none) return null;

    switch (ctx.nodeTag(node)) {
        .identifier => return getNodeSource(ctx, node),
        .assignment_pattern => return firstPatternBindingName(ctx, ctx.nodeData(node).binary.lhs),
        .rest_element => return firstPatternBindingName(ctx, ctx.nodeData(node).unary),
        .object_pattern => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return null;
            const rs = ctx.ast.extra_data.items[extra_idx];
            const re = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[rs..re]) |item_raw| {
                const item: NodeIndex = @enumFromInt(item_raw);
                if (item == .none) continue;
                switch (ctx.nodeTag(item)) {
                    .shorthand_property => {
                        const value = ctx.nodeData(item).unary;
                        if (firstPatternBindingName(ctx, value)) |name| return name;
                    },
                    .property, .computed_property => {
                        const value = ctx.nodeData(item).binary.rhs;
                        if (firstPatternBindingName(ctx, value)) |name| return name;
                    },
                    .rest_element => {
                        if (firstPatternBindingName(ctx, ctx.nodeData(item).unary)) |name| return name;
                    },
                    else => {},
                }
            }
            return null;
        },
        .array_pattern => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return null;
            const rs = ctx.ast.extra_data.items[extra_idx];
            const re = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[rs..re]) |item_raw| {
                const item: NodeIndex = @enumFromInt(item_raw);
                if (item == .none) continue;
                const tag = ctx.nodeTag(item);
                if (tag == .removed or tag == .empty_statement) continue;
                if (firstPatternBindingName(ctx, item)) |name| return name;
            }
            return null;
        },
        else => return null,
    }
}

// ── Rest parameter loop ───────────────────────────────────────────

fn emitRestLoop(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, rp: ParamInfo, rest_index: u32) []const u8 {
    return emitRestLoopWithIndent(buf, ctx, rp, rest_index, "  ");
}

fn emitRestLoopWithIndent(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    rp: ParamInfo,
    rest_index: u32,
    indent: []const u8,
) []const u8 {
    // Check if the rest param name shadows `arguments`
    const binding_node = if (ctx.nodeTag(rp.node) == .rest_element) ctx.nodeData(rp.node).unary else rp.node;
    const use_pattern_temp = binding_node != .none and ctx.nodeTag(binding_node) != .identifier;
    const rest_name = if (use_pattern_temp)
        allocRef(ctx)
    else if (std.mem.eql(u8, rp.name, "arguments"))
        "_arguments"
    else
        rp.name;

    g_rest_loop_counter += 1;
    const rest_loop_suffix = if (g_rest_loop_counter == 1) "" else numSuffix(ctx, g_rest_loop_counter);
    const len_name = if (rest_loop_suffix.len == 0)
        "_len"
    else
        std.fmt.allocPrint(ctx.allocator, "_len{s}", .{rest_loop_suffix}) catch "_len";
    const key_name = if (rest_loop_suffix.len == 0)
        "_key"
    else
        std.fmt.allocPrint(ctx.allocator, "_key{s}", .{rest_loop_suffix}) catch "_key";

    if (rest_index == 0) {
        // No preceding params: for (var _len = arguments.length, rest = new Array(_len), _key = 0; ...)
        buf.appendSlice(ctx.allocator, indent) catch return rest_name;
        buf.appendSlice(ctx.allocator, "for (var ") catch return rest_name;
        buf.appendSlice(ctx.allocator, len_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " = arguments.length, ") catch return rest_name;
        buf.appendSlice(ctx.allocator, rest_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " = new Array(") catch return rest_name;
        buf.appendSlice(ctx.allocator, len_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "), ") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " = 0; ") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " < ") catch return rest_name;
        buf.appendSlice(ctx.allocator, len_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "; ") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "++) {\n") catch return rest_name;
        buf.appendSlice(ctx.allocator, indent) catch return rest_name;
        buf.appendSlice(ctx.allocator, "  ") catch return rest_name;
        buf.appendSlice(ctx.allocator, rest_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "[") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "] = arguments[") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "];\n") catch return rest_name;
        buf.appendSlice(ctx.allocator, indent) catch return rest_name;
        buf.appendSlice(ctx.allocator, "}\n") catch return rest_name;
    } else {
        // Has preceding params: offset calculation
        const idx_str = uintToStr(ctx, rest_index);
        buf.appendSlice(ctx.allocator, indent) catch return rest_name;
        buf.appendSlice(ctx.allocator, "for (var ") catch return rest_name;
        buf.appendSlice(ctx.allocator, len_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " = arguments.length, ") catch return rest_name;
        buf.appendSlice(ctx.allocator, rest_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " = new Array(") catch return rest_name;
        buf.appendSlice(ctx.allocator, len_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " > ") catch return rest_name;
        buf.appendSlice(ctx.allocator, idx_str) catch return rest_name;
        buf.appendSlice(ctx.allocator, " ? ") catch return rest_name;
        buf.appendSlice(ctx.allocator, len_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " - ") catch return rest_name;
        buf.appendSlice(ctx.allocator, idx_str) catch return rest_name;
        buf.appendSlice(ctx.allocator, " : 0), ") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " = ") catch return rest_name;
        buf.appendSlice(ctx.allocator, idx_str) catch return rest_name;
        buf.appendSlice(ctx.allocator, "; ") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " < ") catch return rest_name;
        buf.appendSlice(ctx.allocator, len_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "; ") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "++) {\n") catch return rest_name;
        buf.appendSlice(ctx.allocator, indent) catch return rest_name;
        buf.appendSlice(ctx.allocator, "  ") catch return rest_name;
        buf.appendSlice(ctx.allocator, rest_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "[") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, " - ") catch return rest_name;
        buf.appendSlice(ctx.allocator, idx_str) catch return rest_name;
        buf.appendSlice(ctx.allocator, "] = arguments[") catch return rest_name;
        buf.appendSlice(ctx.allocator, key_name) catch return rest_name;
        buf.appendSlice(ctx.allocator, "];\n") catch return rest_name;
        buf.appendSlice(ctx.allocator, indent) catch return rest_name;
        buf.appendSlice(ctx.allocator, "}\n") catch return rest_name;
    }

    if (use_pattern_temp and binding_node != .none) {
        emitPatternBindingStatementsWithoutArrayHelper(buf, ctx, binding_node, rest_name, indent);
        finishBindingList(buf, ctx);
    }

    return rest_name;
}

fn renameRestArgumentsBinding(ctx: *TransformContext, rp: ParamInfo, body_node: NodeIndex) void {
    if (!std.mem.eql(u8, rp.name, "arguments")) return;
    const scope_result = ctx.scope orelse return;
    const binding_node = if (ctx.nodeTag(rp.node) == .rest_element) ctx.nodeData(rp.node).unary else rp.node;
    if (binding_node == .none) return;
    const binding_idx = scope_mod.getBindingIndexForNode(scope_result, binding_node) orelse return;
    renameResolvedBindingInSubtree(ctx, body_node, binding_idx, "_arguments");
}

const RestUsageReplacement = struct {
    node: NodeIndex,
    replacement: []const u8,
};

const RestOptimizationResult = enum {
    failed,
    elided,
    materialized,
};

const DeferredRestPlan = struct {
    target_body: NodeIndex,
    target_stmt: ?NodeIndex,
};

const RestComputedReplacement = struct {
    replacement: []const u8,
    prefix: ?[]const u8 = null,
};

const SourceSubstitution = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

fn tryApplyRestUsageOptimizations(
    ctx: *TransformContext,
    body_node: NodeIndex,
    rp: ParamInfo,
    allow_deferred_materialization: bool,
) RestOptimizationResult {
    if (std.mem.eql(u8, rp.name, "arguments")) return .failed;
    const scope_result = ctx.scope orelse return .failed;
    const binding_node = if (ctx.nodeTag(rp.node) == .rest_element) ctx.nodeData(rp.node).unary else rp.node;
    if (binding_node == .none) return .failed;
    const binding_idx = scope_mod.getBindingIndexForNode(scope_result, binding_node) orelse return .failed;
    if (hasFunctionScopeRestRedeclaration(ctx, body_node, rp.name, binding_idx)) return .failed;

    var replacements: std.ArrayListUnmanaged(RestUsageReplacement) = .empty;
    defer replacements.deinit(ctx.allocator);
    var prefixes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer prefixes.deinit(ctx.allocator);
    var blockers: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer blockers.deinit(ctx.allocator);

    if (!collectRestUsageOptimizations(ctx, body_node, binding_idx, rp, &replacements, &prefixes, &blockers)) {
        return .failed;
    }

    if (blockers.items.len > 0) {
        if (!allow_deferred_materialization) return .failed;
        switch (ctx.nodeTag(body_node)) {
            .block_statement, .program => {},
            else => return .failed,
        }

        var candidates: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer candidates.deinit(ctx.allocator);
        for (blockers.items) |blocker| {
            candidates.append(ctx.allocator, blocker) catch return .failed;
        }
        for (replacements.items) |repl| {
            candidates.append(ctx.allocator, repl.node) catch return .failed;
        }

        const plan = planDeferredRestMaterialization(ctx, body_node, candidates.items) orelse return .failed;
        if (plan.target_body != body_node and !isDescendantOf(plan.target_body, body_node, ctx)) return .failed;

        const use_owner_stmt = plan.target_stmt != null and
            plan.target_body != body_node and
            isFirstLiveStatementInBody(ctx, plan.target_body, plan.target_stmt.?);

        var loop_buf: std.ArrayListUnmanaged(u8) = .empty;
        const rest_binding = emitRestLoopWithIndent(
            &loop_buf,
            ctx,
            rp,
            rp.arg_index,
            if (use_owner_stmt) "  " else "",
        );
        renameRestArgumentsBinding(ctx, rp, body_node);
        applyMaterializedRestSpreadLowering(ctx, body_node, rp, rest_binding);
        applyDeferredRestMaterialization(ctx, body_node, plan, loop_buf.items);
        return .materialized;
    }

    if (prefixes.items.len > 0) {
        if (mergeSimpleVarPrefixes(ctx, prefixes.items)) |merged_prefix| {
            appendPrefixToBody(ctx, body_node, merged_prefix);
        } else {
            for (prefixes.items) |prefix| {
                appendPrefixToBody(ctx, body_node, prefix);
            }
        }
    }
    for (replacements.items) |repl| {
        putReplacement(ctx, @intFromEnum(repl.node), repl.replacement);
    }
    return .elided;
}

fn hasFunctionScopeRestRedeclaration(
    ctx: *TransformContext,
    body_node: NodeIndex,
    rest_name: []const u8,
    rest_binding_idx: u32,
) bool {
    if (rest_name.len == 0) return false;
    const scope_result = ctx.scope orelse return false;
    const scope_idx = scope_mod.getScopeForNode(scope_result, body_node) orelse return false;
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];

    for (scope_result.bindings[scope.bindings_start..scope.bindings_end], scope.bindings_start..) |binding, binding_idx| {
        if (binding_idx == rest_binding_idx) continue;
        if (!std.mem.eql(u8, binding.name, rest_name)) continue;
        switch (binding.kind) {
            .var_decl, .function_decl => return true,
            else => {},
        }
    }

    return false;
}

fn collectRestUsageOptimizations(
    ctx: *TransformContext,
    root: NodeIndex,
    binding_idx: u32,
    rp: ParamInfo,
    replacements: *std.ArrayListUnmanaged(RestUsageReplacement),
    prefixes: *std.ArrayListUnmanaged([]const u8),
    blockers: *std.ArrayListUnmanaged(NodeIndex),
) bool {
    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, root) catch return false;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        const tag = ctx.nodeTag(node);
        if (node != root and isRestOptimizationBoundary(tag)) {
            if (subtreeReferencesBinding(ctx, node, binding_idx)) {
                blockers.append(ctx.allocator, node) catch return false;
            }
            continue;
        }

        switch (tag) {
            .assignment_expr => {
                if (subtreeContainsIdentifierName(ctx, ctx.nodeData(node).binary.lhs, rp.name)) {
                    blockers.append(ctx.allocator, node) catch return false;
                    continue;
                }
            },
            .call_expr, .optional_call_expr => {
                if (tryBuildRestSpreadCallReplacement(ctx, node, binding_idx, rp)) |replacement| {
                    replacements.append(ctx.allocator, .{ .node = node, .replacement = replacement }) catch return false;
                    continue;
                }
            },
            .member_expr, .optional_chain_expr => {
                const object = ctx.nodeData(node).binary.lhs;
                if (isResolvedBindingReference(ctx, object, binding_idx)) {
                    if (!isRestReadContext(ctx, node)) {
                        blockers.append(ctx.allocator, node) catch return false;
                        continue;
                    }
                    if (tryBuildRestMemberReplacement(ctx, node, rp)) |replacement| {
                        replacements.append(ctx.allocator, .{ .node = node, .replacement = replacement }) catch return false;
                        continue;
                    }
                }
            },
            .computed_member_expr, .optional_computed_member_expr => {
                const object = ctx.nodeData(node).binary.lhs;
                if (isResolvedBindingReference(ctx, object, binding_idx)) {
                    if (!isRestReadContext(ctx, node)) {
                        blockers.append(ctx.allocator, node) catch return false;
                        continue;
                    }
                    if (tryBuildRestComputedMemberReplacement(ctx, root, node, binding_idx, rp)) |replacement| {
                        if (replacement.prefix) |prefix| {
                            prefixes.append(ctx.allocator, prefix) catch return false;
                        }
                        replacements.append(ctx.allocator, .{ .node = node, .replacement = replacement.replacement }) catch return false;
                        continue;
                    }
                }
            },
            .identifier => {
                if (isUnboundArgumentsIdentifier(ctx, node)) return false;
                if (isResolvedBindingReference(ctx, node, binding_idx)) {
                    blockers.append(ctx.allocator, node) catch return false;
                    continue;
                }
            },
            else => {},
        }

        const children = visitor.getChildren(ctx.ast, node);
        var child_i: usize = children.len;
        while (child_i > 0) {
            child_i -= 1;
            stack.append(ctx.allocator, children.items[child_i]) catch return false;
        }
        if (children.range_end > children.range_start) {
            var range_i: usize = children.range_end;
            while (range_i > children.range_start) {
                range_i -= 1;
                const raw = ctx.ast.extra_data.items[range_i];
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
        if (children.range2_end > children.range2_start) {
            var range2_i: usize = children.range2_end;
            while (range2_i > children.range2_start) {
                range2_i -= 1;
                const raw = ctx.ast.extra_data.items[range2_i];
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
    }

    return true;
}

fn subtreeContainsIdentifierName(ctx: *TransformContext, root: NodeIndex, name: []const u8) bool {
    if (root == .none or name.len == 0) return false;

    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, root) catch return false;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        if (ctx.nodeTag(node) == .identifier and std.mem.eql(u8, ctx.tokenSlice(ctx.mainToken(node)), name)) {
            return true;
        }

        const children = visitor.getChildren(ctx.ast, node);
        for (children.items[0..children.len]) |child| {
            stack.append(ctx.allocator, child) catch return false;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
    }

    return false;
}

fn planDeferredRestMaterialization(
    ctx: *TransformContext,
    function_body: NodeIndex,
    candidates: []const NodeIndex,
) ?DeferredRestPlan {
    const target_body = findDeferredRestMaterializationBody(ctx, function_body, candidates) orelse return null;
    const target_stmt = findDeferredRestMaterializationStatement(ctx, target_body, candidates);
    return .{
        .target_body = target_body,
        .target_stmt = target_stmt,
    };
}

fn applyDeferredRestMaterialization(
    ctx: *TransformContext,
    function_body: NodeIndex,
    plan: DeferredRestPlan,
    prefix: []const u8,
) void {
    if (plan.target_stmt) |stmt| {
        if (plan.target_body != function_body and isFirstLiveStatementInBody(ctx, plan.target_body, stmt)) {
            insertPrefixIntoOwningStatement(ctx, plan.target_body, prefix);
            return;
        }
        if (plan.target_body == function_body and
            isFirstLiveStatementInBody(ctx, plan.target_body, stmt) and
            ctx.nodeTag(stmt) != .expression_statement)
        {
            appendPrefixToBody(ctx, plan.target_body, std.mem.trimEnd(u8, prefix, "\n"));
            return;
        }
        if (ctx.nodeTag(stmt) == .expression_statement) {
            if (findPreviousLiveStatementInBody(ctx, plan.target_body, stmt)) |prev_stmt| {
                appendSourceAfterStatement(ctx, prev_stmt, prefix);
            } else {
                prependSourceToStatement(ctx, stmt, prefix);
            }
        } else {
            prependSourceToStatement(ctx, stmt, prefix);
        }
    } else {
        appendPrefixToBody(ctx, plan.target_body, std.mem.trimEnd(u8, prefix, "\n"));
    }
}

fn insertPrefixIntoOwningStatement(ctx: *TransformContext, body: NodeIndex, prefix: []const u8) void {
    const owner = findParentOf(ctx, body) orelse return;
    const owner_tag = ctx.nodeTag(owner);
    var owner_src = if (needsStatementRelativeIndent(owner_tag) or shouldGenerateStatementSource(ctx, owner))
        getGeneratedSource(ctx, owner)
    else
        getNodeSourceRecursive(ctx, owner);
    if (owner_src.len == 0) return;

    const open_brace = std.mem.indexOfScalar(u8, owner_src, '{') orelse return;
    const insert_pos = if (open_brace + 1 < owner_src.len and owner_src[open_brace + 1] == '\n') open_brace + 2 else open_brace + 1;
    owner_src = std.fmt.allocPrint(
        ctx.allocator,
        "{s}{s}{s}",
        .{ owner_src[0..insert_pos], prefix, owner_src[insert_pos..] },
    ) catch return;
    putReplacement(ctx, @intFromEnum(owner), owner_src);
}

fn findDeferredRestMaterializationBody(
    ctx: *TransformContext,
    function_body: NodeIndex,
    blockers: []const NodeIndex,
) ?NodeIndex {
    if (blockers.len == 0) return function_body;

    var common = findDeferredRestAnchorBody(ctx, function_body, blockers[0]) orelse return function_body;
    for (blockers[1..]) |blocker| {
        const body = findDeferredRestAnchorBody(ctx, function_body, blocker) orelse continue;
        common = deepestCommonDeferredRestBody(ctx, function_body, common, body) orelse function_body;
    }
    return common;
}

fn findDeferredRestAnchorBody(ctx: *TransformContext, function_body: NodeIndex, blocker: NodeIndex) ?NodeIndex {
    var current = blocker;
    var outermost_loop: ?NodeIndex = null;
    while (current != function_body) {
        const parent = findParentOf(ctx, current) orelse break;
        if (isDeferredRestLoopBodyParent(ctx, parent, current)) {
            outermost_loop = parent;
        }
        current = parent;
    }

    if (outermost_loop) |loop_node| {
        return findEnclosingBodyAboveNode(ctx, loop_node, function_body);
    }
    return findNearestEnclosingBodyWithin(ctx, blocker, function_body);
}

fn deepestCommonDeferredRestBody(
    ctx: *TransformContext,
    function_body: NodeIndex,
    a: NodeIndex,
    b: NodeIndex,
) ?NodeIndex {
    var a_bodies: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer a_bodies.deinit(ctx.allocator);
    var b_bodies: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer b_bodies.deinit(ctx.allocator);

    collectEnclosingBodies(ctx, a, function_body, &a_bodies);
    collectEnclosingBodies(ctx, b, function_body, &b_bodies);
    if (a_bodies.items.len == 0 or b_bodies.items.len == 0) return null;

    var common: ?NodeIndex = null;
    var a_i = a_bodies.items.len;
    var b_i = b_bodies.items.len;
    while (a_i > 0 and b_i > 0) {
        a_i -= 1;
        b_i -= 1;
        if (a_bodies.items[a_i] != b_bodies.items[b_i]) break;
        common = a_bodies.items[a_i];
    }
    return common;
}

fn collectEnclosingBodies(
    ctx: *TransformContext,
    start: NodeIndex,
    function_body: NodeIndex,
    out: *std.ArrayListUnmanaged(NodeIndex),
) void {
    var current: ?NodeIndex = start;
    while (current) |node| {
        out.append(ctx.allocator, node) catch return;
        if (node == function_body) return;
        current = findEnclosingBodyAboveNode(ctx, node, function_body);
    }
}

fn findNearestEnclosingBodyWithin(ctx: *TransformContext, node: NodeIndex, function_body: NodeIndex) ?NodeIndex {
    var current = node;
    while (current != function_body) {
        const parent = findParentOf(ctx, current) orelse break;
        if (parent == function_body) return function_body;
        const tag = ctx.nodeTag(parent);
        if (tag == .block_statement or tag == .program) return parent;
        current = parent;
    }
    return if (function_body != .none) function_body else null;
}

fn findEnclosingBodyAboveNode(ctx: *TransformContext, node: NodeIndex, function_body: NodeIndex) ?NodeIndex {
    var current = node;
    while (current != function_body) {
        const parent = findParentOf(ctx, current) orelse return null;
        if (parent == function_body) return function_body;
        const tag = ctx.nodeTag(parent);
        if (tag == .block_statement or tag == .program) return parent;
        current = parent;
    }
    return null;
}

fn findDeferredRestMaterializationStatement(
    ctx: *TransformContext,
    body: NodeIndex,
    blockers: []const NodeIndex,
) ?NodeIndex {
    var best_stmt: ?NodeIndex = null;
    var best_start: ?u32 = null;
    for (blockers) |blocker| {
        const stmt = findChildWithinBody(ctx, body, blocker) orelse continue;
        const stmt_start = getNodeStart(ctx, stmt);
        if (best_start == null or stmt_start < best_start.?) {
            best_stmt = stmt;
            best_start = stmt_start;
        }
    }
    return best_stmt;
}

fn isFirstLiveStatementInBody(ctx: *TransformContext, body: NodeIndex, stmt: NodeIndex) bool {
    const range = getBlockRange(ctx, body) orelse return false;
    for (ctx.ast.extra_data.items[range.start..range.end]) |stmt_raw| {
        if (stmt_raw >= ctx.ast.nodes.items(.tag).len) continue;
        if (ctx.ast.nodes.items(.tag)[stmt_raw] == .removed) continue;
        return @as(NodeIndex, @enumFromInt(stmt_raw)) == stmt;
    }
    return false;
}

fn findPreviousLiveStatementInBody(ctx: *TransformContext, body: NodeIndex, stmt: NodeIndex) ?NodeIndex {
    const range = getBlockRange(ctx, body) orelse return null;
    var previous: ?NodeIndex = null;
    for (ctx.ast.extra_data.items[range.start..range.end]) |stmt_raw| {
        if (stmt_raw >= ctx.ast.nodes.items(.tag).len) continue;
        if (ctx.ast.nodes.items(.tag)[stmt_raw] == .removed) continue;
        const current: NodeIndex = @enumFromInt(stmt_raw);
        if (current == stmt) return previous;
        previous = current;
    }
    return null;
}

fn findChildWithinBody(ctx: *TransformContext, body: NodeIndex, node: NodeIndex) ?NodeIndex {
    var current = node;
    while (true) {
        const parent = findParentOf(ctx, current) orelse return null;
        if (parent == body) return current;
        current = parent;
    }
}

fn isDeferredRestLoopBodyParent(ctx: *TransformContext, parent: NodeIndex, child: NodeIndex) bool {
    return switch (ctx.nodeTag(parent)) {
        .for_statement => blk: {
            const extra_idx = @intFromEnum(ctx.nodeData(parent).extra);
            if (extra_idx + 3 >= ctx.ast.extra_data.items.len) break :blk false;
            break :blk @as(NodeIndex, @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3])) == child;
        },
        .for_in_statement, .for_of_statement, .for_of_await_statement => blk: {
            const extra_idx = @intFromEnum(ctx.nodeData(parent).extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) break :blk false;
            break :blk @as(NodeIndex, @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2])) == child;
        },
        .while_statement => ctx.nodeData(parent).binary.rhs == child,
        .do_while_statement => ctx.nodeData(parent).binary.lhs == child,
        else => false,
    };
}

fn prependSourceToStatement(ctx: *TransformContext, stmt: NodeIndex, prefix: []const u8) void {
    if (stmt == .none or prefix.len == 0) return;
    const stmt_src = getInjectedStatementSource(ctx, stmt);
    if (stmt_src.len == 0) return;
    const combined = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, stmt_src }) catch return;
    putReplacement(ctx, @intFromEnum(stmt), combined);
}

fn appendSourceAfterStatement(ctx: *TransformContext, stmt: NodeIndex, suffix: []const u8) void {
    if (stmt == .none or suffix.len == 0) return;
    const stmt_src = getInjectedStatementSource(ctx, stmt);
    if (stmt_src.len == 0) return;
    const combined = std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ stmt_src, suffix }) catch return;
    putReplacement(ctx, @intFromEnum(stmt), combined);
}

fn getInjectedStatementSource(ctx: *TransformContext, stmt: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(stmt);
    var stmt_src = if (needsStatementRelativeIndent(tag))
        normalizeMultilineSource(ctx, getGeneratedSource(ctx, stmt))
    else if (tag == .expression_statement)
        getNodeSourceRecursive(ctx, stmt)
    else if (shouldGenerateStatementSource(ctx, stmt))
        getGeneratedSource(ctx, stmt)
    else
        getNodeSourceRecursive(ctx, stmt);

    if (tag == .expression_statement and !std.mem.endsWith(u8, std.mem.trimEnd(u8, stmt_src, " \t\r\n"), ";")) {
        stmt_src = std.fmt.allocPrint(ctx.allocator, "{s};", .{stmt_src}) catch stmt_src;
    }
    return stmt_src;
}

fn restoreElidedRestShadowBinding(
    ctx: *TransformContext,
    func_node: NodeIndex,
    body_node: NodeIndex,
    rp: ParamInfo,
) void {
    if (rp.name.len == 0 or std.mem.eql(u8, rp.name, "arguments")) return;

    const scope_result = ctx.scope orelse return;
    const func_scope_idx = scope_mod.getScopeForNode(scope_result, func_node) orelse return;
    const binding_node = if (ctx.nodeTag(rp.node) == .rest_element) ctx.nodeData(rp.node).unary else rp.node;
    if (binding_node == .none) return;
    const rest_binding_idx = scope_mod.getBindingIndexForNode(scope_result, binding_node) orelse return;
    const same_name_bindings = scope_result.binding_name_indices.get(rp.name) orelse return;

    var shadow_binding_idx: ?u32 = null;
    var shadow_count: u32 = 0;
    for (same_name_bindings.items) |binding_idx| {
        if (binding_idx == rest_binding_idx) continue;
        const binding = scope_result.bindings[binding_idx];
        const owner_scope_idx = scope_result.containingFunctionScope(binding.scope);
        if (owner_scope_idx != func_scope_idx) continue;
        if (binding.scope == func_scope_idx) return;
        shadow_count += 1;
        shadow_binding_idx = binding_idx;
        if (shadow_count > 1) return;
    }

    if (shadow_binding_idx) |binding_idx| {
        const binding = scope_result.bindings[binding_idx];
        const current_name = ctx.ast.replacement_source.get(@intFromEnum(binding.node)) orelse rp.name;
        const fallback_name = if (std.mem.eql(u8, current_name, rp.name))
            std.fmt.allocPrint(ctx.allocator, "_{s}", .{rp.name}) catch current_name
        else
            current_name;
        renameResolvedBindingInSubtree(ctx, body_node, binding_idx, rp.name);
        restoreShadowBindingDeclChain(ctx, binding.node, body_node, fallback_name, rp.name);
    }
}

fn restoreShadowBindingDeclChain(
    ctx: *TransformContext,
    binding_node: NodeIndex,
    body_node: NodeIndex,
    current_name: []const u8,
    original_name: []const u8,
) void {
    if (binding_node == .none or current_name.len == 0 or std.mem.eql(u8, current_name, original_name)) return;

    var current = binding_node;
    while (current != body_node) {
        const parent = findParentOf(ctx, current) orelse return;
        const parent_i = @intFromEnum(parent);
        if (ctx.ast.replacement_source.get(parent_i)) |replacement| {
            const restored = replaceIdentifierText(ctx, replacement, current_name, original_name);
            if (!std.mem.eql(u8, restored, replacement)) {
                putReplacement(ctx, parent_i, restored);
            }
        }
        current = parent;
    }
}

fn replaceIdentifierText(
    ctx: *TransformContext,
    source: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) []const u8 {
    if (source.len == 0 or old_name.len == 0 or std.mem.eql(u8, old_name, new_name)) return source;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var pos: usize = 0;
    var changed = false;
    while (pos < source.len) {
        if (pos + old_name.len <= source.len and std.mem.eql(u8, source[pos .. pos + old_name.len], old_name) and
            (pos == 0 or !isIdentifierChar(source[pos - 1])) and
            (pos + old_name.len == source.len or !isIdentifierChar(source[pos + old_name.len])))
        {
            buf.appendSlice(ctx.allocator, new_name) catch return source;
            pos += old_name.len;
            changed = true;
        } else {
            buf.append(ctx.allocator, source[pos]) catch return source;
            pos += 1;
        }
    }
    return if (changed) buf.items else source;
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

fn isRestOptimizationBoundary(tag: Node.Tag) bool {
    return switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .arrow_function_expr,
        .class_declaration,
        .class_expr,
        .class_body,
        .class_field,
        .class_private_field,
        .class_static_block,
        .method_definition,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        => true,
        else => false,
    };
}

fn mergeSimpleVarPrefixes(ctx: *TransformContext, prefixes: []const []const u8) ?[]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(ctx.allocator);

    for (prefixes) |prefix| {
        const name = parseSimpleVarPrefix(prefix) orelse return null;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) break;
        } else {
            names.append(ctx.allocator, name) catch return null;
        }
    }

    if (names.items.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "var ") catch return null;
    for (names.items, 0..) |name, i| {
        if (i > 0) buf.appendSlice(ctx.allocator, ", ") catch return null;
        buf.appendSlice(ctx.allocator, name) catch return null;
    }
    buf.append(ctx.allocator, ';') catch return null;
    return buf.items;
}

fn parseSimpleVarPrefix(prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, prefix, "var ")) return null;
    if (prefix.len < 6 or prefix[prefix.len - 1] != ';') return null;
    const body = std.mem.trim(u8, prefix["var ".len .. prefix.len - 1], " \t\r\n");
    if (body.len == 0 or std.mem.indexOfScalar(u8, body, '=') != null or std.mem.indexOfScalar(u8, body, ',') != null) {
        return null;
    }
    return body;
}

fn subtreeReferencesBinding(ctx: *TransformContext, root: NodeIndex, binding_idx: u32) bool {
    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, root) catch return true;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        if (ctx.nodeTag(node) == .identifier and isResolvedBindingReference(ctx, node, binding_idx)) {
            return true;
        }

        const children = visitor.getChildren(ctx.ast, node);
        var child_i: u8 = 0;
        while (child_i < children.len) : (child_i += 1) {
            stack.append(ctx.allocator, children.items[child_i]) catch return true;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return true;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return true;
            }
        }
    }

    return false;
}

fn ensureResolvedBindingCache(ctx: *TransformContext) void {
    if (g_resolved_binding_ast == ctx.ast) return;
    g_resolved_binding_ast = ctx.ast;
    g_resolved_identifier_bindings = ctx.allocator.alloc(u32, ctx.ast.nodes.items(.tag).len) catch &[_]u32{};
    @memset(g_resolved_identifier_bindings, resolved_binding_uncached);
}

fn getResolvedIdentifierBindingIndex(ctx: *TransformContext, node: NodeIndex) ?u32 {
    if (node == .none or ctx.nodeTag(node) != .identifier) return null;
    if (ctx.session) |session| {
        return session.resolvedBindingIndexFor(node);
    }
    const scope_result = ctx.scope orelse return null;

    ensureResolvedBindingCache(ctx);
    const ni = @intFromEnum(node);
    if (ni < g_resolved_identifier_bindings.len) {
        const cached = g_resolved_identifier_bindings[ni];
        if (cached == resolved_binding_none) return null;
        if (cached != resolved_binding_uncached) return cached;
    }

    const name = ctx.tokenSlice(ctx.mainToken(node));
    const resolved = scope_mod.resolveBindingIndexForNode(scope_result, node, name);
    if (ni < g_resolved_identifier_bindings.len) {
        g_resolved_identifier_bindings[ni] = resolved orelse resolved_binding_none;
    }
    return resolved;
}

fn isResolvedBindingReference(ctx: *TransformContext, node: NodeIndex, binding_idx: u32) bool {
    if (node == .none or ctx.nodeTag(node) != .identifier) return false;
    return getResolvedIdentifierBindingIndex(ctx, node) == binding_idx;
}

fn isUnboundArgumentsIdentifier(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none or ctx.nodeTag(node) != .identifier) return false;
    const name = ctx.tokenSlice(ctx.mainToken(node));
    if (!std.mem.eql(u8, name, "arguments")) return false;
    return getResolvedIdentifierBindingIndex(ctx, node) == null;
}

fn applyMaterializedRestSpreadLowering(
    ctx: *TransformContext,
    body_node: NodeIndex,
    rp: ParamInfo,
    rest_binding: []const u8,
) void {
    const scope_result = ctx.scope orelse return;
    const binding_node = if (ctx.nodeTag(rp.node) == .rest_element) ctx.nodeData(rp.node).unary else rp.node;
    if (binding_node == .none) return;
    const binding_idx = scope_mod.getBindingIndexForNode(scope_result, binding_node) orelse return;

    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, body_node) catch return;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        switch (ctx.nodeTag(node)) {
            .call_expr, .optional_call_expr => {
                if (buildMaterializedRestCallReplacement(ctx, node, binding_idx, rest_binding)) |replacement| {
                    putReplacement(ctx, @intFromEnum(node), replacement);
                    continue;
                }
            },
            else => {},
        }

        const children = visitor.getChildren(ctx.ast, node);
        var child_i: u8 = 0;
        while (child_i < children.len) : (child_i += 1) {
            stack.append(ctx.allocator, children.items[child_i]) catch return;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return;
            }
        }
    }
}

fn buildMaterializedRestCallReplacement(
    ctx: *TransformContext,
    node: NodeIndex,
    binding_idx: u32,
    rest_binding: []const u8,
) ?[]const u8 {
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return null;
    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const args_start = ctx.ast.extra_data.items[extra_idx + 1];
    const args_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (args_start >= args_end) return null;

    const args = ctx.ast.extra_data.items[args_start..args_end];
    if (!argsContainBindingSpread(ctx, args, binding_idx)) return null;

    const callee_tag = ctx.nodeTag(callee);
    if (callee_tag == .member_expr or callee_tag == .computed_member_expr or callee_tag == .optional_chain_expr or callee_tag == .optional_computed_member_expr) {
        return null;
    }

    var args_buf: std.ArrayListUnmanaged(u8) = .empty;
    buildMaterializedRestArgsArray(&args_buf, ctx, args, binding_idx, rest_binding);
    if (args_buf.items.len == 0) return null;

    const callee_src = getNodeSourceRecursive(ctx, callee);
    return std.fmt.allocPrint(ctx.allocator, "{s}.apply(void 0, {s})", .{ callee_src, args_buf.items }) catch null;
}

fn argsContainBindingSpread(ctx: *TransformContext, args: []const u32, binding_idx: u32) bool {
    for (args) |arg_raw| {
        const arg: NodeIndex = @enumFromInt(arg_raw);
        if (arg == .none or ctx.nodeTag(arg) != .spread_element) continue;
        if (isResolvedBindingReference(ctx, ctx.nodeData(arg).unary, binding_idx)) return true;
    }
    return false;
}

fn buildMaterializedRestArgsArray(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    args: []const u32,
    binding_idx: u32,
    rest_binding: []const u8,
) void {
    if (args.len == 1) {
        const only_arg: NodeIndex = @enumFromInt(args[0]);
        if (only_arg != .none and ctx.nodeTag(only_arg) == .spread_element) {
            const inner = ctx.nodeData(only_arg).unary;
            if (isResolvedBindingReference(ctx, inner, binding_idx)) {
                buf.appendSlice(ctx.allocator, rest_binding) catch {};
                return;
            }
        }
    }

    var first_segment = true;
    var index: usize = 0;
    while (index < args.len) {
        const arg: NodeIndex = @enumFromInt(args[index]);
        const is_rest_spread = arg != .none and
            ctx.nodeTag(arg) == .spread_element and
            isResolvedBindingReference(ctx, ctx.nodeData(arg).unary, binding_idx);

        if (is_rest_spread) {
            if (first_segment) {
                buf.appendSlice(ctx.allocator, rest_binding) catch return;
            } else {
                buf.appendSlice(ctx.allocator, ".concat(") catch return;
                buf.appendSlice(ctx.allocator, rest_binding) catch return;
                buf.append(ctx.allocator, ')') catch return;
            }
            first_segment = false;
            index += 1;
            continue;
        }

        const segment_start = index;
        while (index < args.len) : (index += 1) {
            const seg_arg: NodeIndex = @enumFromInt(args[index]);
            if (seg_arg != .none and
                ctx.nodeTag(seg_arg) == .spread_element and
                isResolvedBindingReference(ctx, ctx.nodeData(seg_arg).unary, binding_idx))
            {
                break;
            }
        }

        if (!first_segment) {
            buf.appendSlice(ctx.allocator, ".concat(") catch return;
        }
        emitMaterializedRestArrayLiteral(buf, ctx, args[segment_start..index]);
        if (!first_segment) {
            buf.append(ctx.allocator, ')') catch return;
        }
        first_segment = false;
    }
}

fn emitMaterializedRestArrayLiteral(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    args: []const u32,
) void {
    buf.append(ctx.allocator, '[') catch return;
    for (args, 0..) |arg_raw, arg_i| {
        const arg: NodeIndex = @enumFromInt(arg_raw);
        if (arg_i > 0) buf.appendSlice(ctx.allocator, ", ") catch return;
        if (arg == .none) continue;
        if (ctx.nodeTag(arg) == .spread_element) {
            buf.appendSlice(ctx.allocator, getNodeSourceRecursive(ctx, ctx.nodeData(arg).unary)) catch return;
        } else {
            buf.appendSlice(ctx.allocator, getNodeSourceRecursive(ctx, arg)) catch return;
        }
    }
    buf.append(ctx.allocator, ']') catch return;
}

fn tryBuildRestSpreadCallReplacement(
    ctx: *TransformContext,
    node: NodeIndex,
    binding_idx: u32,
    rp: ParamInfo,
) ?[]const u8 {
    if (rp.arg_index != 0) return null;
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return null;

    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const args_start = ctx.ast.extra_data.items[extra_idx + 1];
    const args_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (args_end - args_start != 1) return null;

    const only_arg: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[args_start]);
    if (only_arg == .none or ctx.nodeTag(only_arg) != .spread_element) return null;

    const inner = ctx.nodeData(only_arg).unary;
    if (!isResolvedBindingReference(ctx, inner, binding_idx)) return null;

    const callee_tag = ctx.nodeTag(callee);
    if (callee_tag == .member_expr or callee_tag == .computed_member_expr or callee_tag == .optional_chain_expr or callee_tag == .optional_computed_member_expr) {
        return null;
    }

    const callee_src = getNodeSourceRecursive(ctx, callee);
    return std.fmt.allocPrint(ctx.allocator, "{s}.apply(void 0, arguments)", .{callee_src}) catch null;
}

fn tryBuildRestMemberReplacement(ctx: *TransformContext, node: NodeIndex, rp: ParamInfo) ?[]const u8 {
    if (!isRestReadContext(ctx, node)) return null;
    const prop_tok: TokenIndex = @enumFromInt(@intFromEnum(ctx.nodeData(node).binary.rhs));
    if (!std.mem.eql(u8, ctx.tokenSlice(prop_tok), "length")) return null;
    return wrapConditionalExpressionIfNeeded(ctx, node, buildRestLengthExpr(ctx, rp.arg_index));
}

fn tryBuildRestComputedMemberReplacement(
    ctx: *TransformContext,
    root: NodeIndex,
    node: NodeIndex,
    binding_idx: u32,
    rp: ParamInfo,
) ?RestComputedReplacement {
    if (!isRestReadContext(ctx, node)) return null;
    const index_node = ctx.nodeData(node).binary.rhs;
    if (index_node == .none) return null;
    if (isStringLikeRestComputedIndex(ctx, index_node)) return null;
    const index_src = getRestIndexExprSource(ctx, index_node, binding_idx, rp) orelse return null;

    if (parseIntegerLiteralValue(ctx, index_node)) |literal_value| {
        if (literal_value < 0) {
            return .{ .replacement = "void 0" };
        }

        const literal_src = std.fmt.allocPrint(ctx.allocator, "{d}", .{literal_value}) catch return null;
        if (rp.arg_index == 0) {
            const expr = std.fmt.allocPrint(
                ctx.allocator,
                "arguments.length <= {s} ? undefined : arguments[{s}]",
                .{ literal_src, literal_src },
            ) catch return null;
            return .{ .replacement = wrapConditionalExpressionIfNeeded(ctx, node, expr) };
        }
        const absolute_literal = std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{rp.arg_index + @as(u32, @intCast(literal_value))},
        ) catch return null;
        const expr = std.fmt.allocPrint(
            ctx.allocator,
            "arguments.length <= {s} ? undefined : arguments[{s}]",
            .{ absolute_literal, absolute_literal },
        ) catch return null;
        return .{ .replacement = wrapConditionalExpressionIfNeeded(ctx, node, expr) };
    }

    if (rp.arg_index == 0) {
        if (restComputedIndexNeedsMemoization(ctx, index_node)) {
            if (ctx.nodeTag(root) != .block_statement) return null;

            const temp = allocRestComputedIndexTemp(ctx, index_node);
            const prefix = std.fmt.allocPrint(ctx.allocator, "var {s};", .{temp}) catch return null;
            const expr = std.fmt.allocPrint(
                ctx.allocator,
                "{s} = {s}, {s} < 0 || arguments.length <= {s} ? undefined : arguments[{s}]",
                .{ temp, index_src, temp, temp, temp },
            ) catch return null;
            return .{
                .replacement = wrapSequenceExpressionIfNeeded(ctx, node, expr),
                .prefix = prefix,
            };
        }

        const expr = std.fmt.allocPrint(
            ctx.allocator,
            "{s} < 0 || arguments.length <= {s} ? undefined : arguments[{s}]",
            .{ index_src, index_src, index_src },
        ) catch return null;
        return .{ .replacement = wrapConditionalExpressionIfNeeded(ctx, node, expr) };
    }

    if (ctx.nodeTag(root) != .block_statement) return null;

    const temp = allocRef(ctx);
    const prefix = std.fmt.allocPrint(ctx.allocator, "var {s};", .{temp}) catch return null;
    const expr = std.fmt.allocPrint(
        ctx.allocator,
        "{s} = {s} + {d}, {s} < {d} || arguments.length <= {s} ? undefined : arguments[{s}]",
        .{ temp, index_src, rp.arg_index, temp, rp.arg_index, temp, temp },
    ) catch return null;
    return .{
        .replacement = wrapSequenceExpressionIfNeeded(ctx, node, expr),
        .prefix = prefix,
    };
}

fn isStringLikeRestComputedIndex(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    return switch (ctx.nodeTag(node)) {
        .string_literal, .template_literal => true,
        .identifier => blk: {
            const binding = ctx.getBindingForNode(node) orelse break :blk false;
            const init_node = binding.init_node;
            if (init_node == .none) break :blk false;
            break :blk switch (ctx.nodeTag(init_node)) {
                .string_literal, .template_literal => true,
                else => false,
            };
        },
        .parenthesized_expr,
        .ts_non_null_expression,
        => isStringLikeRestComputedIndex(ctx, ctx.nodeData(node).unary),
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_type_assertion,
        => isStringLikeRestComputedIndex(ctx, ctx.nodeData(node).binary.lhs),
        else => false,
    };
}

fn isRestReadContext(ctx: *TransformContext, node: NodeIndex) bool {
    var child = node;
    while (true) {
        const parent = findParentOf(ctx, child) orelse return true;
        switch (ctx.nodeTag(parent)) {
            .parenthesized_expr,
            .ts_non_null_expression,
            .ts_as_expression,
            .ts_satisfies_expression,
            .ts_type_assertion,
            .ts_instantiation_expression,
            .array_expr,
            .object_expr,
            .property,
            .computed_property,
            .shorthand_property,
            => {
                child = parent;
                continue;
            },
            .assignment_expr => {
                return ctx.nodeData(parent).binary.lhs != child;
            },
            .update_expr => return false,
            .unary_expr => {
                const mt = ctx.mainToken(parent);
                const tok = ctx.ast.tokens.items(.tag)[@intFromEnum(mt)];
                return tok != .kw_delete;
            },
            .call_expr, .optional_call_expr, .new_expr => {
                const extra_idx = @intFromEnum(ctx.nodeData(parent).extra);
                if (extra_idx >= ctx.ast.extra_data.items.len) return true;
                const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
                return callee != child;
            },
            .member_expr, .optional_chain_expr, .computed_member_expr, .optional_computed_member_expr => {
                return ctx.nodeData(parent).binary.lhs != child;
            },
            .for_in_statement, .for_of_statement, .for_of_await_statement => {
                const extra_idx = @intFromEnum(ctx.nodeData(parent).extra);
                if (extra_idx >= ctx.ast.extra_data.items.len) return true;
                const left: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
                return left != child;
            },
            else => return true,
        }
    }
}

fn buildRestLengthExpr(ctx: *TransformContext, rest_index: u32) []const u8 {
    if (rest_index == 0) return "arguments.length";
    return std.fmt.allocPrint(
        ctx.allocator,
        "arguments.length <= {d} ? 0 : arguments.length - {d}",
        .{ rest_index, rest_index },
    ) catch "arguments.length";
}

fn wrapConditionalExpressionIfNeeded(ctx: *TransformContext, node: NodeIndex, expr: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, expr, '?') == null) return expr;
    const parent = findParentOf(ctx, node) orelse return expr;
    return switch (ctx.nodeTag(parent)) {
        .binary_expr,
        .logical_expr,
        .member_expr,
        .optional_chain_expr,
        .computed_member_expr,
        .optional_computed_member_expr,
        .unary_expr,
        .update_expr,
        => std.fmt.allocPrint(ctx.allocator, "({s})", .{expr}) catch expr,
        else => expr,
    };
}

fn wrapSequenceExpressionIfNeeded(ctx: *TransformContext, node: NodeIndex, expr: []const u8) []const u8 {
    const parent = findParentOf(ctx, node) orelse return expr;
    return switch (ctx.nodeTag(parent)) {
        .expression_statement, .return_statement, .throw_statement => expr,
        else => std.fmt.allocPrint(ctx.allocator, "({s})", .{expr}) catch expr,
    };
}

fn parseNonNegativeIntegerLiteral(ctx: *TransformContext, node: NodeIndex) ?[]const u8 {
    if (ctx.nodeTag(node) != .numeric_literal) return null;
    const src = getNodeSource(ctx, node);
    if (src.len == 0) return null;
    for (src) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return src;
}

fn parseIntegerLiteralValue(ctx: *TransformContext, node: NodeIndex) ?i64 {
    const src = getGeneratedSource(ctx, node);
    if (src.len == 0) return null;

    var digit_start: usize = 0;
    if (src[0] == '+' or src[0] == '-') {
        digit_start = 1;
    }
    if (digit_start >= src.len) return null;
    for (src[digit_start..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(i64, src, 10) catch null;
}

fn unwrapTransparentReturnExpr(ctx: *TransformContext, node: NodeIndex) NodeIndex {
    var current = node;
    while (current != .none) {
        switch (ctx.nodeTag(current)) {
            .flow_type_cast_expression => {
                const extra_idx = @intFromEnum(ctx.nodeData(current).extra);
                if (extra_idx >= ctx.ast.extra_data.items.len) return current;
                current = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            },
            .ts_type_cast_expression => {
                const extra_idx = @intFromEnum(ctx.nodeData(current).extra);
                if (extra_idx >= ctx.ast.extra_data.items.len) return current;
                current = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            },
            .ts_as_expression, .ts_satisfies_expression => {
                current = ctx.nodeData(current).binary.lhs;
            },
            .ts_type_assertion => {
                current = ctx.nodeData(current).binary.rhs;
            },
            .ts_non_null_expression => {
                current = ctx.nodeData(current).unary;
            },
            .parenthesized_expr => {
                const child = ctx.nodeData(current).unary;
                switch (ctx.nodeTag(child)) {
                    .flow_type_cast_expression,
                    .ts_type_cast_expression,
                    .ts_as_expression,
                    .ts_satisfies_expression,
                    .ts_type_assertion,
                    .ts_non_null_expression,
                    .parenthesized_expr,
                    => current = child,
                    else => return current,
                }
            },
            else => return current,
        }
    }
    return node;
}

fn restComputedIndexNeedsMemoization(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    return switch (ctx.nodeTag(node)) {
        .call_expr,
        .optional_call_expr,
        .new_expr,
        .assignment_expr,
        .update_expr,
        .await_expr,
        .yield_expr,
        .sequence_expr,
        => true,
        .parenthesized_expr,
        .ts_non_null_expression,
        => restComputedIndexNeedsMemoization(ctx, ctx.nodeData(node).unary),
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_type_assertion,
        => restComputedIndexNeedsMemoization(ctx, ctx.nodeData(node).binary.lhs),
        else => false,
    };
}

fn allocRestComputedIndexTemp(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return allocRef(ctx);
    return switch (ctx.nodeTag(node)) {
        .identifier => blk: {
            const name = getNodeSource(ctx, node);
            const base = std.fmt.allocPrint(ctx.allocator, "_{s}", .{name}) catch return allocRef(ctx);
            break :blk allocNextRefName(ctx, base);
        },
        .update_expr,
        .parenthesized_expr,
        .ts_non_null_expression,
        => allocRestComputedIndexTemp(ctx, ctx.nodeData(node).unary),
        .assignment_expr,
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_type_assertion,
        => allocRestComputedIndexTemp(ctx, ctx.nodeData(node).binary.lhs),
        else => allocRef(ctx),
    };
}

fn getRestIndexExprSource(
    ctx: *TransformContext,
    expr: NodeIndex,
    binding_idx: u32,
    rp: ParamInfo,
) ?[]const u8 {
    var substitutions: std.ArrayListUnmanaged(SourceSubstitution) = .empty;
    defer substitutions.deinit(ctx.allocator);

    if (!collectRestLengthSubstitutions(ctx, expr, binding_idx, rp, &substitutions)) return null;
    if (substitutions.items.len == 0) return getGeneratedSource(ctx, expr);

    std.mem.sort(SourceSubstitution, substitutions.items, {}, struct {
        fn lessThan(_: void, a: SourceSubstitution, b: SourceSubstitution) bool {
            return a.start < b.start;
        }
    }.lessThan);

    return buildSourceWithSubstitutions(ctx, expr, substitutions.items);
}

fn collectRestLengthSubstitutions(
    ctx: *TransformContext,
    root: NodeIndex,
    binding_idx: u32,
    rp: ParamInfo,
    substitutions: *std.ArrayListUnmanaged(SourceSubstitution),
) bool {
    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, root) catch return false;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        switch (ctx.nodeTag(node)) {
            .member_expr, .optional_chain_expr => {
                const lhs = ctx.nodeData(node).binary.lhs;
                if (isResolvedBindingReference(ctx, lhs, binding_idx)) {
                    const prop_tok: TokenIndex = @enumFromInt(@intFromEnum(ctx.nodeData(node).binary.rhs));
                    if (!std.mem.eql(u8, ctx.tokenSlice(prop_tok), "length")) return false;
                    const text = if (node != root and rp.arg_index > 0)
                        std.fmt.allocPrint(ctx.allocator, "({s})", .{buildRestLengthExpr(ctx, rp.arg_index)}) catch return false
                    else
                        buildRestLengthExpr(ctx, rp.arg_index);
                    substitutions.append(ctx.allocator, .{
                        .start = getNodeStart(ctx, node),
                        .end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(node)],
                        .text = text,
                    }) catch return false;
                    continue;
                }
            },
            .computed_member_expr, .optional_computed_member_expr => {
                const lhs = ctx.nodeData(node).binary.lhs;
                if (isResolvedBindingReference(ctx, lhs, binding_idx)) return false;
            },
            .identifier => {
                if (isResolvedBindingReference(ctx, node, binding_idx)) return false;
            },
            else => {},
        }

        const children = visitor.getChildren(ctx.ast, node);
        var child_i: usize = children.len;
        while (child_i > 0) {
            child_i -= 1;
            stack.append(ctx.allocator, children.items[child_i]) catch return false;
        }
        if (children.range_end > children.range_start) {
            var range_i: usize = children.range_end;
            while (range_i > children.range_start) {
                range_i -= 1;
                const raw = ctx.ast.extra_data.items[range_i];
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
        if (children.range2_end > children.range2_start) {
            var range2_i: usize = children.range2_end;
            while (range2_i > children.range2_start) {
                range2_i -= 1;
                const raw = ctx.ast.extra_data.items[range2_i];
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
    }

    return true;
}

fn buildSourceWithSubstitutions(
    ctx: *TransformContext,
    root: NodeIndex,
    substitutions: []const SourceSubstitution,
) ?[]const u8 {
    const start = getNodeStart(ctx, root);
    const end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(root)];
    if (start >= end or end > ctx.ast.source.len) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var cursor = start;
    for (substitutions) |subst| {
        if (subst.start < cursor or subst.end > end) return null;
        buf.appendSlice(ctx.allocator, ctx.ast.source[cursor..subst.start]) catch return null;
        buf.appendSlice(ctx.allocator, subst.text) catch return null;
        cursor = subst.end;
    }
    buf.appendSlice(ctx.allocator, ctx.ast.source[cursor..end]) catch return null;
    return buf.items;
}

fn buildPatternTemps(ctx: *TransformContext, params: []const ParamInfo) [][]const u8 {
    const temps = ctx.allocator.alloc([]const u8, params.len) catch @panic("oom");
    for (params, 0..) |p, pi| {
        temps[pi] = switch (p.kind) {
            .pattern, .pattern_default => allocRef(ctx),
            else => "",
        };
    }
    return temps;
}

fn buildIgnoreFunctionLengthParamTemps(
    ctx: *TransformContext,
    params: []const ParamInfo,
    pattern_temps: [][]const u8,
) [][]const u8 {
    const temps = ctx.allocator.alloc([]const u8, params.len) catch @panic("oom");
    for (params, 0..) |p, pi| {
        temps[pi] = switch (p.kind) {
            .pattern => pattern_temps[pi],
            .pattern_default => allocNextRefName(ctx, "_temp"),
            else => "",
        };
    }
    return temps;
}

fn patternNode(ctx: *TransformContext, param: ParamInfo) NodeIndex {
    return switch (param.kind) {
        .pattern => param.node,
        .pattern_default => ctx.nodeData(param.node).binary.lhs,
        else => .none,
    };
}

fn shadowBindingNode(ctx: *TransformContext, param: ParamInfo) ?NodeIndex {
    return switch (param.kind) {
        .pattern => param.node,
        .pattern_default => ctx.nodeData(param.node).binary.lhs,
        .rest => blk: {
            if (ctx.nodeTag(param.node) != .rest_element) break :blk null;
            const inner = ctx.nodeData(param.node).unary;
            if (inner == .none or ctx.nodeTag(inner) == .identifier) break :blk null;
            break :blk inner;
        },
        else => null,
    };
}

fn bindingNode(ctx: *TransformContext, param: ParamInfo) NodeIndex {
    return switch (param.kind) {
        .normal => param.node,
        .default_value => ctx.nodeData(param.node).binary.lhs,
        .rest => if (ctx.nodeTag(param.node) == .rest_element) ctx.nodeData(param.node).unary else .none,
        .pattern, .pattern_default => .none,
    };
}

fn defaultValueNode(ctx: *TransformContext, param: ParamInfo) NodeIndex {
    return switch (param.kind) {
        .default_value, .pattern_default => ctx.nodeData(param.node).binary.rhs,
        else => .none,
    };
}

fn getParamBindingSource(ctx: *TransformContext, param: ParamInfo) []const u8 {
    const node = bindingNode(ctx, param);
    if (node == .none) return "";
    return getBindingSource(ctx, node);
}

fn getParamDefaultSource(ctx: *TransformContext, param: ParamInfo) []const u8 {
    const node = defaultValueNode(ctx, param);
    if (node == .none) return "";
    return getDefaultValueSource(ctx, node);
}

fn getParamIndexSource(ctx: *TransformContext, param: ParamInfo) []const u8 {
    return uintToStr(ctx, param.arg_index);
}

fn emitPatternBindingStatements(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    indent: []const u8,
) void {
    if (pattern == .none) return;
    if (!patternHasBindingNames(ctx, pattern)) {
        buf.appendSlice(ctx.allocator, indent) catch return;
        buf.appendSlice(ctx.allocator, "let") catch return;
        buf.appendSlice(ctx.allocator, " ") catch return;
        buf.appendSlice(ctx.allocator, getNodeSource(ctx, pattern)) catch return;
        buf.appendSlice(ctx.allocator, " = ") catch return;
        buf.appendSlice(ctx.allocator, init_source) catch return;
        buf.appendSlice(ctx.allocator, ";\n") catch return;
        return;
    }
    switch (ctx.nodeTag(pattern)) {
        .object_pattern => emitObjectPatternBindings(buf, ctx, pattern, init_source, indent),
        .array_pattern => emitArrayPatternBindings(buf, ctx, pattern, init_source, indent),
        else => {
            buf.appendSlice(ctx.allocator, indent) catch return;
            buf.appendSlice(ctx.allocator, "var ") catch return;
            buf.appendSlice(ctx.allocator, getNodeSource(ctx, pattern)) catch return;
            buf.appendSlice(ctx.allocator, " = ") catch return;
            buf.appendSlice(ctx.allocator, init_source) catch return;
            buf.appendSlice(ctx.allocator, ";\n") catch return;
        },
    }
}

fn emitPatternBindingStatementsWithoutArrayHelper(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    indent: []const u8,
) void {
    if (pattern == .none) return;
    switch (ctx.nodeTag(pattern)) {
        .object_pattern => emitObjectPatternBindings(buf, ctx, pattern, init_source, indent),
        .array_pattern => emitArrayPatternBindingsImpl(buf, ctx, pattern, init_source, indent, false),
        else => emitPatternBindingStatements(buf, ctx, pattern, init_source, indent),
    }
}

fn emitObjectPatternBindings(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    indent: []const u8,
) void {
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    var rest_target: ?NodeIndex = null;

    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop_node: NodeIndex = @enumFromInt(prop_idx);
        switch (ctx.nodeTag(prop_node)) {
            .shorthand_property => {
                const value_node = ctx.nodeData(prop_node).unary;
                if (value_node == .none) continue;
                const value_tag = ctx.nodeTag(value_node);
                if (value_tag == .assignment_pattern) {
                    emitObjectPropertyDefault(buf, ctx, value_node, init_source, null, indent);
                } else {
                    const name = getNodeSource(ctx, value_node);
                    emitVarBinding(buf, ctx, name, tryPropAccess(ctx, init_source, name, false), indent);
                }
            },
            .property => {
                const prop_data = ctx.nodeData(prop_node);
                const key_node = prop_data.binary.lhs;
                const value_node = prop_data.binary.rhs;
                if (key_node == .none or value_node == .none) continue;

                const key_tag = ctx.nodeTag(key_node);
                const key_source = getNodeSource(ctx, key_node);
                const access = tryPropAccess(
                    ctx,
                    init_source,
                    key_source,
                    key_tag == .numeric_literal or key_tag == .string_literal,
                );
                switch (ctx.nodeTag(value_node)) {
                    .assignment_pattern => emitObjectPropertyDefault(buf, ctx, value_node, init_source, key_node, indent),
                    .object_pattern, .array_pattern => {
                        const temp = allocRefName(ctx, init_source, key_source);
                        emitVarBinding(buf, ctx, temp, access, indent);
                        emitPatternBindingStatements(buf, ctx, value_node, temp, indent);
                    },
                    else => emitVarBinding(buf, ctx, getNodeSource(ctx, value_node), access, indent),
                }
            },
            .computed_property => {
                const prop_data = ctx.nodeData(prop_node);
                const key_node = prop_data.binary.lhs;
                const value_node = prop_data.binary.rhs;
                if (key_node == .none or value_node == .none) continue;

                const key_source = getNodeSource(ctx, key_node);
                const access = tryPropAccess(ctx, init_source, key_source, true);
                switch (ctx.nodeTag(value_node)) {
                    .assignment_pattern => emitObjectPropertyDefault(buf, ctx, value_node, init_source, key_node, indent),
                    .object_pattern, .array_pattern => {
                        const temp = allocRefName(ctx, init_source, "ref");
                        emitVarBinding(buf, ctx, temp, access, indent);
                        emitPatternBindingStatements(buf, ctx, value_node, temp, indent);
                    },
                    else => emitVarBinding(buf, ctx, getNodeSource(ctx, value_node), access, indent),
                }
            },
            .rest_element => {
                rest_target = ctx.nodeData(prop_node).unary;
            },
            else => {
                buf.appendSlice(ctx.allocator, indent) catch return;
                buf.appendSlice(ctx.allocator, "var ") catch return;
                buf.appendSlice(ctx.allocator, getNodeSource(ctx, pattern)) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, init_source) catch return;
                buf.appendSlice(ctx.allocator, ";\n") catch return;
                return;
            },
        }
    }

    if (rest_target) |target| {
        const excluded = buildParamObjectRestExcludedKeysSource(ctx, rs, re);
        const excluded_ref = hoistParamExcludedKeys(ctx, excluded);
        const helper_name = if (g_config.loose) "babelHelpers.objectWithoutPropertiesLoose" else "babelHelpers.objectWithoutProperties";
        const expr = std.fmt.allocPrint(
            ctx.allocator,
            "{s}({s}, {s})",
            .{ helper_name, init_source, excluded_ref },
        ) catch excluded_ref;
        emitVarBinding(buf, ctx, getNodeSource(ctx, target), expr, indent);
    }
}

fn buildParamObjectRestExcludedKeysSource(
    ctx: *TransformContext,
    rs: u32,
    re: u32,
) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return "[]";
    var first = true;
    for (ctx.ast.extra_data.items[rs..re]) |prop_idx| {
        if (prop_idx >= ctx.ast.nodes.len) continue;
        const prop_node: NodeIndex = @enumFromInt(prop_idx);
        const key_source = switch (ctx.nodeTag(prop_node)) {
            .shorthand_property => blk: {
                const value = ctx.nodeData(prop_node).unary;
                if (value == .none) continue;
                break :blk std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{getNodeSource(ctx, value)}) catch continue;
            },
            .property => blk: {
                const key = ctx.nodeData(prop_node).binary.lhs;
                if (key == .none) continue;
                switch (ctx.nodeTag(key)) {
                    .identifier => break :blk std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{getNodeSource(ctx, key)}) catch continue,
                    else => break :blk getNodeSource(ctx, key),
                }
            },
            .computed_property => blk: {
                const key = ctx.nodeData(prop_node).binary.lhs;
                if (key == .none) continue;
                break :blk getNodeSource(ctx, key);
            },
            .rest_element => continue,
            else => continue,
        };
        if (!first) buf.appendSlice(ctx.allocator, ", ") catch return "[]";
        first = false;
        buf.appendSlice(ctx.allocator, key_source) catch return "[]";
    }
    buf.append(ctx.allocator, ']') catch return "[]";
    return buf.items;
}

fn hoistParamExcludedKeys(ctx: *TransformContext, excluded: []const u8) []const u8 {
    if (excluded.len == 0 or std.mem.eql(u8, excluded, "[]")) return excluded;
    if (std.mem.indexOfScalar(u8, excluded, '`') != null or std.mem.indexOfScalar(u8, excluded, '[') != 0) return excluded;
    if (std.mem.indexOf(u8, excluded, ".map(") != null) return excluded;

    const body = g_current_excluded_hoist_body orelse return excluded;
    const name = allocNextRefName(ctx, "_excluded");
    const keyword = if (g_config.emit_var_bindings) "var" else "const";
    const prefix = std.fmt.allocPrint(ctx.allocator, "{s} {s} = {s};", .{ keyword, name, excluded }) catch return excluded;
    appendPrefixToBody(ctx, body, prefix);
    return name;
}

fn emitArrayPatternBindings(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    indent: []const u8,
) void {
    emitArrayPatternBindingsImpl(buf, ctx, pattern, init_source, indent, true);
}

fn emitArrayPatternBindingsImpl(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    pattern: NodeIndex,
    init_source: []const u8,
    indent: []const u8,
    allow_array_helper: bool,
) void {
    var source = init_source;
    const use_to_array_helper = allow_array_helper and arrayPatternHasRest(ctx, pattern);
    if (allow_array_helper and g_config.emit_var_bindings) {
        const helper_temp = allocRef(ctx);
        const helper_expr = if (use_to_array_helper)
            std.fmt.allocPrint(ctx.allocator, "babelHelpers.toArray({s})", .{init_source}) catch init_source
        else blk: {
            const count = countArrayPatternElements(ctx, pattern);
            break :blk std.fmt.allocPrint(
                ctx.allocator,
                "babelHelpers.slicedToArray({s}, {d})",
                .{ init_source, count },
            ) catch init_source;
        };
        emitVarBinding(buf, ctx, helper_temp, helper_expr, indent);
        source = helper_temp;
    }

    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[rs..re], 0..) |elem_idx, index| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem_node: NodeIndex = @enumFromInt(elem_idx);
        const elem_tag = ctx.nodeTag(elem_node);
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;

        const access = std.fmt.allocPrint(ctx.allocator, "{s}[{d}]", .{ source, index }) catch source;
        switch (elem_tag) {
            .identifier => emitVarBinding(buf, ctx, getNodeSource(ctx, elem_node), access, indent),
            .assignment_pattern => {
                const target = ctx.nodeData(elem_node).binary.lhs;
                const default_val = ctx.nodeData(elem_node).binary.rhs;
                if (target == .none or default_val == .none) continue;
                const target_src = getNodeSource(ctx, target);
                const default_src = getNodeSource(ctx, default_val);
                const temp = allocRefName(ctx, source, "");
                emitVarBinding(buf, ctx, temp, access, indent);
                const expr = std.fmt.allocPrint(
                    ctx.allocator,
                    "{s} === void 0 ? {s} : {s}",
                    .{ temp, default_src, temp },
                ) catch temp;
                emitVarBinding(buf, ctx, target_src, expr, indent);
            },
            .rest_element => {
                const target = ctx.nodeData(elem_node).unary;
                if (target == .none) continue;
                const expr = if (use_to_array_helper)
                    std.fmt.allocPrint(ctx.allocator, "babelHelpers.arrayLikeToArray({s}).slice({d})", .{ source, index }) catch source
                else
                    std.fmt.allocPrint(ctx.allocator, "{s}.slice({d})", .{ source, index }) catch source;
                emitVarBinding(buf, ctx, getNodeSource(ctx, target), expr, indent);
            },
            .object_pattern, .array_pattern => {
                const temp = allocRefName(ctx, source, std.fmt.allocPrint(ctx.allocator, "{d}", .{index}) catch "");
                emitVarBinding(buf, ctx, temp, access, indent);
                emitPatternBindingStatements(buf, ctx, elem_node, temp, indent);
            },
            else => {
                buf.appendSlice(ctx.allocator, indent) catch return;
                buf.appendSlice(ctx.allocator, "var ") catch return;
                buf.appendSlice(ctx.allocator, getNodeSource(ctx, pattern)) catch return;
                buf.appendSlice(ctx.allocator, " = ") catch return;
                buf.appendSlice(ctx.allocator, source) catch return;
                buf.appendSlice(ctx.allocator, ";\n") catch return;
                return;
            },
        }
    }
}

fn countArrayPatternElements(ctx: *TransformContext, pattern: NodeIndex) u32 {
    if (pattern == .none) return 0;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return 0;

    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    var count: u32 = 0;
    for (ctx.ast.extra_data.items[rs..re], 0..) |elem_idx, index| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        const elem_tag = ctx.ast.nodes.items(.tag)[elem_idx];
        if (elem_tag == .removed or elem_tag == .empty_statement) continue;
        count = @intCast(index + 1);
    }
    return count;
}

fn arrayPatternHasRest(ctx: *TransformContext, pattern: NodeIndex) bool {
    if (pattern == .none or ctx.nodeTag(pattern) != .array_pattern) return false;
    const data = ctx.nodeData(pattern);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const rs = ctx.ast.extra_data.items[extra_idx];
    const re = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[rs..re]) |elem_idx| {
        if (elem_idx >= ctx.ast.nodes.len) continue;
        if (ctx.ast.nodes.items(.tag)[elem_idx] == .rest_element) return true;
    }
    return false;
}

fn emitObjectPropertyDefault(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    assignment_pattern: NodeIndex,
    init_source: []const u8,
    key_node: ?NodeIndex,
    indent: []const u8,
) void {
    const data = ctx.nodeData(assignment_pattern);
    const target = data.binary.lhs;
    const default_val = data.binary.rhs;
    if (target == .none or default_val == .none) return;

    const target_src = getNodeSource(ctx, target);
    const key_src = if (key_node) |kn| getNodeSource(ctx, kn) else target_src;
    const use_bracket = if (key_node) |kn|
        switch (ctx.nodeTag(kn)) {
            .numeric_literal, .string_literal => true,
            else => false,
        }
    else
        false;
    const access = tryPropAccess(ctx, init_source, key_src, use_bracket);
    switch (ctx.nodeTag(target)) {
        .object_pattern, .array_pattern => {
            const temp = allocRefName(ctx, init_source, key_src);
            emitVarBinding(buf, ctx, temp, access, indent);
            emitPatternWithDefaultBinding(buf, ctx, target, temp, getNodeSource(ctx, default_val), indent);
        },
        else => {
            const temp_name = allocRefName(ctx, init_source, key_src);
            emitVarBinding(buf, ctx, temp_name, access, indent);
            const guarded_expr = std.fmt.allocPrint(
                ctx.allocator,
                "{s} === void 0 ? {s} : {s}",
                .{ temp_name, getNodeSource(ctx, default_val), temp_name },
            ) catch temp_name;
            emitVarBinding(buf, ctx, target_src, guarded_expr, indent);
        },
    }
}

fn emitVarBinding(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    name: []const u8,
    expr: []const u8,
    indent: []const u8,
) void {
    emitVarBindingPrefix(buf, ctx, indent);
    if (!g_binding_list_started) return;
    buf.appendSlice(ctx.allocator, name) catch return;
    buf.appendSlice(ctx.allocator, " = ") catch return;
    appendInlineMultilineSource(buf, ctx, expr);
}

fn emitVarBindingPrefix(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, indent: []const u8) void {
    const keyword = if (g_config.emit_var_bindings) "var" else "let";
    if (!g_binding_list_started) {
        buf.appendSlice(ctx.allocator, indent) catch return;
        buf.appendSlice(ctx.allocator, keyword) catch return;
        buf.appendSlice(ctx.allocator, " ") catch return;
        g_binding_list_started = true;
    } else {
        buf.appendSlice(ctx.allocator, ",\n") catch return;
        buf.appendSlice(ctx.allocator, indent) catch return;
        buf.appendSlice(ctx.allocator, "  ") catch return;
    }
}

fn emitArgumentsValueBinding(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    name: []const u8,
    index_src: []const u8,
    indent: []const u8,
) void {
    emitVarBindingPrefix(buf, ctx, indent);
    if (!g_binding_list_started) return;
    buf.appendSlice(ctx.allocator, name) catch return;
    buf.appendSlice(ctx.allocator, " = arguments.length > ") catch return;
    buf.appendSlice(ctx.allocator, index_src) catch return;
    buf.appendSlice(ctx.allocator, " ? arguments[") catch return;
    buf.appendSlice(ctx.allocator, index_src) catch return;
    buf.appendSlice(ctx.allocator, "] : undefined") catch return;
}

fn emitArgumentsDefaultBinding(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    name: []const u8,
    index_src: []const u8,
    default_src: []const u8,
    indent: []const u8,
) void {
    emitVarBindingPrefix(buf, ctx, indent);
    if (!g_binding_list_started) return;
    buf.appendSlice(ctx.allocator, name) catch return;
    buf.appendSlice(ctx.allocator, " = arguments.length > ") catch return;
    buf.appendSlice(ctx.allocator, index_src) catch return;
    buf.appendSlice(ctx.allocator, " && arguments[") catch return;
    buf.appendSlice(ctx.allocator, index_src) catch return;
    buf.appendSlice(ctx.allocator, "] !== undefined ? arguments[") catch return;
    buf.appendSlice(ctx.allocator, index_src) catch return;
    buf.appendSlice(ctx.allocator, "] : ") catch return;
    appendInlineMultilineSource(buf, ctx, default_src);
}

fn finishBindingList(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext) void {
    if (!g_binding_list_started) return;
    buf.appendSlice(ctx.allocator, ";\n") catch return;
    g_binding_list_started = false;
}

fn appendInlineMultilineSource(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    src: []const u8,
) void {
    if (std.mem.indexOfScalar(u8, src, '\n') == null) {
        buf.appendSlice(ctx.allocator, src) catch return;
        return;
    }
    appendReplacementWithCurrentLineIndent(buf, ctx, src);
}

fn emitPatternWithDefaultBinding(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    pattern: NodeIndex,
    temp: []const u8,
    default_source: []const u8,
    indent: []const u8,
) void {
    const default_ref = allocNextRefName(ctx, temp);
    const expr = std.fmt.allocPrint(
        ctx.allocator,
        "{s} === void 0 ? {s} : {s}",
        .{ temp, default_source, temp },
    ) catch temp;
    emitVarBinding(buf, ctx, default_ref, expr, indent);
    emitPatternBindingStatements(buf, ctx, pattern, default_ref, indent);
}

fn tryPropAccess(
    ctx: *TransformContext,
    init_source: []const u8,
    key_source: []const u8,
    use_bracket: bool,
) []const u8 {
    if (use_bracket) {
        return std.fmt.allocPrint(ctx.allocator, "{s}[{s}]", .{ init_source, key_source }) catch init_source;
    }
    return std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ init_source, key_source }) catch init_source;
}

fn tryEmitCapturedLoopRestRewrite(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    body_node: NodeIndex,
    rp: ParamInfo,
) bool {
    if (rp.kind != .rest or rp.arg_index != 0 or getParamBindingSource(ctx, rp).len == 0) return false;
    if (ctx.nodeTag(body_node) != .block_statement) return false;

    const body_data = ctx.nodeData(body_node);
    const body_extra = @intFromEnum(body_data.extra);
    if (body_extra + 1 >= ctx.ast.extra_data.items.len) return false;

    const body_range_start = ctx.ast.extra_data.items[body_extra];
    const body_range_end = ctx.ast.extra_data.items[body_extra + 1];
    const loop_stmt = firstLiveStatementInRange(ctx, body_range_start, body_range_end) orelse return false;
    if (liveStatementCount(ctx, body_range_start, body_range_end) != 1) return false;
    if (ctx.nodeTag(loop_stmt) != .while_statement) return false;

    const loop_data = ctx.nodeData(loop_stmt);
    const cond_node = loop_data.binary.lhs;
    const loop_body = loop_data.binary.rhs;
    if (ctx.nodeTag(loop_body) != .block_statement) return false;

    const loop_body_data = ctx.nodeData(loop_body);
    const loop_body_extra = @intFromEnum(loop_body_data.extra);
    if (loop_body_extra + 1 >= ctx.ast.extra_data.items.len) return false;

    const loop_range_start = ctx.ast.extra_data.items[loop_body_extra];
    const loop_range_end = ctx.ast.extra_data.items[loop_body_extra + 1];
    if (liveStatementCount(ctx, loop_range_start, loop_range_end) != 2) return false;

    const decl_stmt = firstLiveStatementInRange(ctx, loop_range_start, loop_range_end) orelse return false;
    const return_stmt = secondLiveStatementInRange(ctx, loop_range_start, loop_range_end) orelse return false;
    const decl_tag = ctx.nodeTag(decl_stmt);
    if (decl_tag != .const_declaration and decl_tag != .let_declaration and decl_tag != .var_declaration) return false;
    if (ctx.nodeTag(return_stmt) != .return_statement) return false;

    const decl_data = ctx.nodeData(decl_stmt);
    const decl_extra = @intFromEnum(decl_data.extra);
    if (decl_extra + 1 >= ctx.ast.extra_data.items.len) return false;

    const decls_start = ctx.ast.extra_data.items[decl_extra];
    const decls_end = ctx.ast.extra_data.items[decl_extra + 1];
    if (decls_end - decls_start != 1) return false;

    const declarator: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[decls_start]);
    if (ctx.nodeTag(declarator) != .declarator) return false;
    const declarator_data = ctx.nodeData(declarator);
    const binding_node = declarator_data.binary.lhs;
    const init_node = declarator_data.binary.rhs;
    if (binding_node == .none or init_node == .none) return false;
    if (ctx.nodeTag(binding_node) != .identifier) return false;

    const binding_name = ctx.tokenSlice(ctx.mainToken(binding_node));
    const return_expr = ctx.nodeData(return_stmt).unary;
    if (return_expr == .none) return false;
    const raw_return_src = getNodeSourceRecursive(ctx, return_expr);
    if (!isCapturedBinding(ctx, binding_node, binding_name) and
        !looksLikeCapturedLoopReturn(raw_return_src, binding_name))
    {
        return false;
    }

    const init_src = replaceIdentifierName(
        ctx,
        getNodeSourceRecursive(ctx, init_node),
        rp.name,
        "_arguments",
    );
    const return_src = replaceIdentifierName(
        ctx,
        raw_return_src,
        rp.name,
        "_arguments",
    );
    const normalized_return_src = normalizeLoopReturnSource(ctx, return_src, binding_name);
    const cond_src = getNodeSourceRecursive(ctx, cond_node);

    buf.appendSlice(ctx.allocator, "    var _arguments = arguments;\n") catch return false;
    buf.appendSlice(ctx.allocator, "    var _loop = function () {\n") catch return false;
    buf.appendSlice(ctx.allocator, "        var ") catch return false;
    buf.appendSlice(ctx.allocator, binding_name) catch return false;
    buf.appendSlice(ctx.allocator, " = ") catch return false;
    buf.appendSlice(ctx.allocator, init_src) catch return false;
    buf.appendSlice(ctx.allocator, ";\n") catch return false;
    appendReturnValueObject(buf, ctx, normalized_return_src);
    buf.appendSlice(ctx.allocator, "      },\n") catch return false;
    buf.appendSlice(ctx.allocator, "      _ret;\n") catch return false;
    buf.appendSlice(ctx.allocator, "    while (") catch return false;
    buf.appendSlice(ctx.allocator, cond_src) catch return false;
    buf.appendSlice(ctx.allocator, ") {\n") catch return false;
    buf.appendSlice(ctx.allocator, "      _ret = _loop();\n") catch return false;
    buf.appendSlice(ctx.allocator, "      if (_ret) return _ret.v;\n") catch return false;
    buf.appendSlice(ctx.allocator, "    }\n") catch return false;
    return true;
}

fn appendReturnValueObject(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    expr_src: []const u8,
) void {
    const normalized = normalizeMultilineSource(ctx, expr_src);
    var lines = std.mem.splitScalar(u8, normalized, '\n');
    const first_line = lines.next() orelse "";

    buf.appendSlice(ctx.allocator, "        return {\n") catch return;
    buf.appendSlice(ctx.allocator, "          v: ") catch return;
    buf.appendSlice(ctx.allocator, first_line) catch return;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        buf.append(ctx.allocator, '\n') catch return;
        buf.appendSlice(ctx.allocator, "          ") catch return;
        buf.appendSlice(ctx.allocator, line) catch return;
    }
    buf.appendSlice(ctx.allocator, "\n        };\n") catch return;
}

fn normalizeMultilineSource(ctx: *TransformContext, src: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src, '\n') == null) return std.mem.trim(u8, src, " \t\r\n");

    var min_indent: usize = std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_index: usize = 0;
    while (lines.next()) |line| {
        const trimmed_right = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed_right.len == 0) continue;
        if (line_index == 0) {
            line_index += 1;
            continue;
        }
        const trimmed_left = std.mem.trimStart(u8, trimmed_right, " \t");
        const leading = trimmed_right.len - trimmed_left.len;
        if (leading < min_indent) min_indent = leading;
        line_index += 1;
    }
    if (min_indent == std.math.maxInt(usize)) return "";

    var normalized_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer normalized_lines.deinit(ctx.allocator);
    var lines2 = std.mem.splitScalar(u8, src, '\n');
    while (lines2.next()) |line| {
        const trimmed_right = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed_right.len == 0) {
            normalized_lines.append(ctx.allocator, "") catch return src;
            continue;
        }
        const trimmed_left = std.mem.trimStart(u8, trimmed_right, " \t");
        const leading = trimmed_right.len - trimmed_left.len;
        const dedented = if (leading >= min_indent) trimmed_right[min_indent..] else trimmed_left;
        normalized_lines.append(ctx.allocator, dedented) catch return src;
    }

    var first_non_empty: usize = 0;
    while (first_non_empty < normalized_lines.items.len and normalized_lines.items[first_non_empty].len == 0) : (first_non_empty += 1) {}
    if (first_non_empty == normalized_lines.items.len) return "";

    var last_non_empty = normalized_lines.items.len;
    while (last_non_empty > first_non_empty and normalized_lines.items[last_non_empty - 1].len == 0) : (last_non_empty -= 1) {}

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var i = first_non_empty;
    while (i < last_non_empty) : (i += 1) {
        if (i != first_non_empty) result.append(ctx.allocator, '\n') catch return src;
        result.appendSlice(ctx.allocator, normalized_lines.items[i]) catch return src;
    }
    return result.items;
}

fn replaceIdentifierName(
    ctx: *TransformContext,
    src: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) []const u8 {
    if (old_name.len == 0 or std.mem.eql(u8, old_name, new_name)) return src;
    if (std.mem.indexOf(u8, src, old_name) == null) return src;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var pos: usize = 0;
    while (pos < src.len) {
        if (pos + old_name.len <= src.len and
            std.mem.eql(u8, src[pos .. pos + old_name.len], old_name) and
            (pos == 0 or !isIdentCont(src[pos - 1])) and
            (pos + old_name.len == src.len or !isIdentCont(src[pos + old_name.len])))
        {
            result.appendSlice(ctx.allocator, new_name) catch return src;
            pos += old_name.len;
            continue;
        }
        result.append(ctx.allocator, src[pos]) catch return src;
        pos += 1;
    }
    return result.items;
}

fn isCapturedBinding(ctx: *TransformContext, binding_node: NodeIndex, binding_name: []const u8) bool {
    const scope_result = ctx.scope orelse return false;
    for (scope_result.bindings) |binding| {
        if (binding.node == binding_node and
            std.mem.eql(u8, binding.name, binding_name))
        {
            return binding.is_captured;
        }
    }
    return false;
}

fn looksLikeCapturedLoopReturn(return_src: []const u8, binding_name: []const u8) bool {
    if (binding_name.len == 0) return false;
    if (std.mem.indexOf(u8, return_src, binding_name) == null) return false;
    return std.mem.indexOf(u8, return_src, "function") != null or std.mem.indexOf(u8, return_src, "=>") != null;
}

fn normalizeLoopReturnSource(
    ctx: *TransformContext,
    src: []const u8,
    binding_name: []const u8,
) []const u8 {
    var result = src;
    if (binding_name.len > 0) {
        const renamed = std.fmt.allocPrint(ctx.allocator, "_{s}", .{binding_name}) catch "";
        if (renamed.len > 0 and std.mem.indexOf(u8, result, renamed) != null) {
            result = replaceIdentifierName(ctx, result, renamed, binding_name);
        }
    }
    if (std.mem.indexOf(u8, result, "() =>") != null) {
        result = replaceExactText(ctx, result, "() =>", "function ()");
    }
    return result;
}

fn replaceExactText(
    ctx: *TransformContext,
    src: []const u8,
    needle: []const u8,
    replacement: []const u8,
) []const u8 {
    if (needle.len == 0 or std.mem.indexOf(u8, src, needle) == null) return src;
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, src, cursor, needle)) |pos| {
        result.appendSlice(ctx.allocator, src[cursor..pos]) catch return src;
        result.appendSlice(ctx.allocator, replacement) catch return src;
        cursor = pos + needle.len;
    }
    result.appendSlice(ctx.allocator, src[cursor..]) catch return src;
    return result.items;
}

fn firstLiveStatementInRange(ctx: *TransformContext, range_start: u32, range_end: u32) ?NodeIndex {
    if (range_end <= range_start or range_end > ctx.ast.extra_data.items.len) return null;
    for (ctx.ast.extra_data.items[range_start..range_end]) |raw| {
        if (raw >= ctx.ast.nodes.items(.tag).len) continue;
        if (ctx.ast.nodes.items(.tag)[raw] == .removed) continue;
        return @enumFromInt(raw);
    }
    return null;
}

fn secondLiveStatementInRange(ctx: *TransformContext, range_start: u32, range_end: u32) ?NodeIndex {
    if (range_end <= range_start or range_end > ctx.ast.extra_data.items.len) return null;
    var seen_first = false;
    for (ctx.ast.extra_data.items[range_start..range_end]) |raw| {
        if (raw >= ctx.ast.nodes.items(.tag).len) continue;
        if (ctx.ast.nodes.items(.tag)[raw] == .removed) continue;
        if (!seen_first) {
            seen_first = true;
            continue;
        }
        return @enumFromInt(raw);
    }
    return null;
}

fn liveStatementCount(ctx: *TransformContext, range_start: u32, range_end: u32) u32 {
    if (range_end <= range_start or range_end > ctx.ast.extra_data.items.len) return 0;
    var count: u32 = 0;
    for (ctx.ast.extra_data.items[range_start..range_end]) |raw| {
        if (raw >= ctx.ast.nodes.items(.tag).len) continue;
        if (ctx.ast.nodes.items(.tag)[raw] == .removed) continue;
        count += 1;
    }
    return count;
}

fn isIdentCont(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_' or ch == '$';
}

// ── Function header ───────────────────────────────────────────────

/// Emit function header without generator/async markers (for IIFE-wrapped functions).
fn emitFunctionHeaderPlain(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, idx: NodeIndex, tag: Node.Tag) void {
    if (tag == .setter) {
        emitAccessorHeader(buf, ctx, idx, "set");
        return;
    }
    if (tag == .method_definition or tag == .class_method or tag == .class_private_method) {
        emitMethodHeader(buf, ctx, idx, tag, false);
        return;
    }

    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = ctx.ast.extra_data.items[extra_idx];
    var emitted_name = false;

    // Determine if originally a generator (needed to skip '*' in name lookup)
    var is_generator: bool = false;
    switch (tag) {
        .generator_declaration, .async_generator_declaration => is_generator = true,
        .function_expr => {
            if (extra_idx + 4 < ctx.ast.extra_data.items.len) {
                const flags = ctx.ast.extra_data.items[extra_idx + 4];
                is_generator = (flags & 1) != 0;
            }
        },
        else => {},
    }

    buf.appendSlice(ctx.allocator, "function") catch {};

    // Get function name
    if (name_token_raw != 0) {
        const name_tok: TokenIndex = @enumFromInt(name_token_raw);
        const name = ctx.tokenSlice(name_tok);
        if (name.len > 0) {
            buf.append(ctx.allocator, ' ') catch {};
            buf.appendSlice(ctx.allocator, name) catch {};
            emitted_name = true;
        }
    } else {
        switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            => {
                const mt = ctx.mainToken(idx);
                var mt_idx = @intFromEnum(mt);
                if (mt_idx + 1 < ctx.ast.tokens.items(.tag).len) {
                    mt_idx += 1;
                    if (is_generator and ctx.ast.tokens.items(.tag)[mt_idx] == .asterisk) {
                        mt_idx += 1;
                    }
                    // Skip 'async' token if present
                    if (ctx.ast.tokens.items(.tag)[mt_idx] == .kw_function) {
                        mt_idx += 1;
                        if (is_generator and mt_idx < ctx.ast.tokens.items(.tag).len and
                            ctx.ast.tokens.items(.tag)[mt_idx] == .asterisk)
                        {
                            mt_idx += 1;
                        }
                    }
                    if (mt_idx < ctx.ast.tokens.items(.tag).len and
                        ctx.ast.tokens.items(.tag)[mt_idx] == .identifier)
                    {
                        buf.append(ctx.allocator, ' ') catch {};
                        buf.appendSlice(ctx.allocator, ctx.tokenSlice(@enumFromInt(mt_idx))) catch {};
                        emitted_name = true;
                    }
                }
            },
            else => {},
        }
    }
    if (!emitted_name) buf.append(ctx.allocator, ' ') catch {};
}

fn emitFunctionHeader(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, idx: NodeIndex, tag: Node.Tag) void {
    if (tag == .setter) {
        emitAccessorHeader(buf, ctx, idx, "set");
        return;
    }
    if (tag == .method_definition or tag == .class_method or tag == .class_private_method) {
        emitMethodHeader(buf, ctx, idx, tag, true);
        return;
    }

    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = ctx.ast.extra_data.items[extra_idx];
    var emitted_name = false;

    // Determine async/generator from tag (declarations) or flags (expressions)
    var is_async: bool = false;
    var is_generator: bool = false;

    switch (tag) {
        .async_function_declaration, .async_generator_declaration => {
            is_async = true;
            if (tag == .async_generator_declaration) is_generator = true;
        },
        .generator_declaration => is_generator = true,
        .function_expr => {
            // function_expr has flags at extra_idx + 4
            if (extra_idx + 4 < ctx.ast.extra_data.items.len) {
                const flags = ctx.ast.extra_data.items[extra_idx + 4];
                is_generator = (flags & 1) != 0;
                is_async = (flags & 2) != 0;
            }
        },
        else => {},
    }

    if (is_async) buf.appendSlice(ctx.allocator, "async ") catch {};
    buf.appendSlice(ctx.allocator, "function") catch {};
    if (is_generator) buf.append(ctx.allocator, '*') catch {};

    // Get function name
    if (name_token_raw != 0) {
        const name_tok: TokenIndex = @enumFromInt(name_token_raw);
        const name = ctx.tokenSlice(name_tok);
        if (name.len > 0) {
            buf.append(ctx.allocator, ' ') catch {};
            buf.appendSlice(ctx.allocator, name) catch {};
            emitted_name = true;
        }
    } else {
        // Function declarations — get name from tokens following 'function' keyword
        switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            => {
                const mt = ctx.mainToken(idx);
                var mt_idx = @intFromEnum(mt);
                // Skip past 'function' and optionally '*'
                if (mt_idx + 1 < ctx.ast.tokens.items(.tag).len) {
                    mt_idx += 1;
                    // Skip '*' for generators
                    if (is_generator and ctx.ast.tokens.items(.tag)[mt_idx] == .asterisk) {
                        mt_idx += 1;
                    }
                    if (mt_idx < ctx.ast.tokens.items(.tag).len and
                        ctx.ast.tokens.items(.tag)[mt_idx] == .identifier)
                    {
                        buf.append(ctx.allocator, ' ') catch {};
                        buf.appendSlice(ctx.allocator, ctx.tokenSlice(@enumFromInt(mt_idx))) catch {};
                        emitted_name = true;
                    }
                }
            },
            else => {},
        }
    }
    if (!emitted_name) buf.append(ctx.allocator, ' ') catch {};
}

fn emitMethodHeader(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    idx: NodeIndex,
    tag: Node.Tag,
    include_async_generator: bool,
) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx >= ctx.ast.extra_data.items.len) return;

    const key: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const flags = if (extra_idx + 4 < ctx.ast.extra_data.items.len)
        ctx.ast.extra_data.items[extra_idx + 4]
    else
        0;
    const is_static = tag != .method_definition and (flags & 1) != 0;
    const is_computed = (flags & 2) != 0;
    const is_generator = include_async_generator and (flags & 4) != 0;
    const is_async = include_async_generator and (flags & 8) != 0;

    if (is_static) buf.appendSlice(ctx.allocator, "static ") catch {};
    if (is_async) buf.appendSlice(ctx.allocator, "async ") catch {};
    if (is_generator) buf.append(ctx.allocator, '*') catch {};

    if (tag == .class_private_method) {
        buf.append(ctx.allocator, '#') catch {};
        if (key != .none) {
            buf.appendSlice(ctx.allocator, getNodeSourceRecursive(ctx, key)) catch {};
        }
    } else if (is_computed) {
        buf.append(ctx.allocator, '[') catch {};
        if (key != .none) {
            buf.appendSlice(ctx.allocator, getNodeSourceRecursive(ctx, key)) catch {};
        }
        buf.append(ctx.allocator, ']') catch {};
    } else if (key != .none) {
        buf.appendSlice(ctx.allocator, getNodeSourceRecursive(ctx, key)) catch {};
    }

    buf.append(ctx.allocator, ' ') catch {};
}

fn emitAccessorHeader(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, idx: NodeIndex, kind: []const u8) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const flags = if (extra_idx + 3 < ctx.ast.extra_data.items.len)
        ctx.ast.extra_data.items[extra_idx + 3]
    else
        0;
    const is_computed = (flags & 8) != 0;
    const is_private = (flags & 4) != 0;

    buf.appendSlice(ctx.allocator, kind) catch {};
    buf.append(ctx.allocator, ' ') catch {};

    if (is_computed and extra_idx + 4 < ctx.ast.extra_data.items.len) {
        const key_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 4]);
        buf.append(ctx.allocator, '[') catch {};
        if (key_node != .none) {
            buf.appendSlice(ctx.allocator, getNodeSourceRecursive(ctx, key_node)) catch {};
        }
        buf.append(ctx.allocator, ']') catch {};
        return;
    }

    if (is_private) buf.append(ctx.allocator, '#') catch {};
    buf.appendSlice(ctx.allocator, ctx.tokenSlice(ctx.mainToken(idx))) catch {};
}

// ── IIFE shadow detection ────────────────────────────────────────

/// Find parameter names that are redeclared with `var` in the function body.
/// These need IIFE wrapping to avoid TDZ conflicts.
fn findShadowedParams(ctx: *TransformContext, params: []const ParamInfo, body_node: NodeIndex) []const []const u8 {
    if (body_node == .none) return &[_][]const u8{};
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen_params: std.StringHashMapUnmanaged(void) = .empty;
    var emitted_names: std.StringHashMapUnmanaged(void) = .empty;

    for (params) |p| {
        if (shadowBindingNode(ctx, p)) |pattern| {
            collectBindingNames(ctx, pattern, &seen_params);
            continue;
        }
        if (p.kind == .rest) continue;
        if (p.name.len > 0) {
            seen_params.put(ctx.allocator, p.name, {}) catch {};
        }
    }

    if (seen_params.count() == 0) return result.items;

    if (ctx.scope) |scope_result| {
        const scope_idx = scope_mod.getScopeForNode(scope_result, body_node) orelse return result.items;
        const scope = scope_result.scopes[@intFromEnum(scope_idx)];
        for (scope_result.bindings[scope.bindings_start..scope.bindings_end]) |binding| {
            if (!bindingNeedsShadowIife(ctx, binding)) continue;
            if (!seen_params.contains(binding.name)) continue;
            appendShadowedParam(ctx, &result, &emitted_names, binding.name);
        }
    }

    scanShadowedBindingsInBody(ctx, body_node, &seen_params, &emitted_names, &result);
    if (ctx.scope != null) return result.items;

    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);
    const body_tag = tags[@intFromEnum(body_node)];
    if (body_tag != .block_statement) return result.items;

    const body_data = datas[@intFromEnum(body_node)];
    const extra_idx = @intFromEnum(body_data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return result.items;
    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (stmt_raw >= tags.len) continue;
        const stmt_tag = tags[stmt_raw];
        if (stmt_tag == .var_declaration) {
            const stmt_data = datas[stmt_raw];
            const decl_extra = @intFromEnum(stmt_data.extra);
            if (decl_extra + 1 >= ctx.ast.extra_data.items.len) continue;
            const decl_start = ctx.ast.extra_data.items[decl_extra];
            const decl_end = ctx.ast.extra_data.items[decl_extra + 1];

            for (ctx.ast.extra_data.items[decl_start..decl_end]) |decl_raw| {
                if (decl_raw >= tags.len) continue;
                if (tags[decl_raw] != .declarator) continue;
                const decl_d = datas[decl_raw];
                const name_node = decl_d.binary.lhs;
                if (name_node == .none) continue;
                if (tags[@intFromEnum(name_node)] != .identifier) continue;
                const var_name = ctx.tokenSlice(ctx.ast.nodes.items(.main_token)[@intFromEnum(name_node)]);
                if (seen_params.contains(var_name)) appendShadowedParam(ctx, &result, &emitted_names, var_name);
            }
            continue;
        }

        switch (stmt_tag) {
            .function_declaration, .async_function_declaration, .generator_declaration, .async_generator_declaration => {
                const stmt_name = getFunctionName(ctx, @enumFromInt(stmt_raw)) orelse continue;
                if (seen_params.contains(stmt_name)) appendShadowedParam(ctx, &result, &emitted_names, stmt_name);
            },
            else => {},
        }
    }

    return result.items;
}

fn appendShadowedParam(
    ctx: *TransformContext,
    result: *std.ArrayListUnmanaged([]const u8),
    emitted_names: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) void {
    if (emitted_names.contains(name)) return;
    emitted_names.put(ctx.allocator, name, {}) catch return;
    result.append(ctx.allocator, name) catch {};
}

fn bindingNeedsShadowIife(ctx: *TransformContext, binding: scope_mod.Binding) bool {
    return switch (binding.kind) {
        .function_decl => true,
        .var_decl => binding.init_node != .none or isForInOfDeclarator(ctx, binding.decl_node),
        else => false,
    };
}

fn isForInOfDeclarator(ctx: *TransformContext, declarator: NodeIndex) bool {
    if (declarator == .none) return false;
    const decl_parent = findParentOf(ctx, declarator) orelse return false;
    switch (ctx.nodeTag(decl_parent)) {
        .var_declaration, .let_declaration, .const_declaration => {},
        else => return false,
    }
    const loop_parent = findParentOf(ctx, decl_parent) orelse return false;
    return switch (ctx.nodeTag(loop_parent)) {
        .for_in_statement, .for_of_statement, .for_of_await_statement => true,
        else => false,
    };
}

fn scanShadowedBindingsInBody(
    ctx: *TransformContext,
    node: NodeIndex,
    seen_params: *std.StringHashMapUnmanaged(void),
    emitted_names: *std.StringHashMapUnmanaged(void),
    result: *std.ArrayListUnmanaged([]const u8),
) void {
    if (node == .none) return;
    switch (ctx.nodeTag(node)) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        => {
            const name = getFunctionName(ctx, node) orelse return;
            if (seen_params.contains(name)) appendShadowedParam(ctx, result, emitted_names, name);
            return;
        },
        .function_expr,
        .arrow_function_expr,
        .class_declaration,
        .class_expr,
        .class_body,
        .method_definition,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        => return,
        .var_declaration => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
            const decl_start = ctx.ast.extra_data.items[extra_idx];
            const decl_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[decl_start..decl_end]) |decl_raw| {
                const decl: NodeIndex = @enumFromInt(decl_raw);
                if (decl == .none or ctx.nodeTag(decl) != .declarator) continue;
                const decl_data = ctx.nodeData(decl);
                if (decl_data.binary.rhs == .none and !isForInOfDeclarator(ctx, decl)) continue;
                appendShadowedBindingsFromPattern(ctx, decl_data.binary.lhs, seen_params, emitted_names, result);
            }
            return;
        },
        else => {},
    }

    const children = visitor.getChildren(ctx.ast, node);
    for (children.items[0..children.len]) |child| {
        scanShadowedBindingsInBody(ctx, child, seen_params, emitted_names, result);
    }
    if (children.range_end > children.range_start) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            scanShadowedBindingsInBody(ctx, @enumFromInt(raw), seen_params, emitted_names, result);
        }
    }
    if (children.range2_end > children.range2_start) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            scanShadowedBindingsInBody(ctx, @enumFromInt(raw), seen_params, emitted_names, result);
        }
    }
}

fn appendShadowedBindingsFromPattern(
    ctx: *TransformContext,
    node: NodeIndex,
    seen_params: *std.StringHashMapUnmanaged(void),
    emitted_names: *std.StringHashMapUnmanaged(void),
    result: *std.ArrayListUnmanaged([]const u8),
) void {
    if (node == .none) return;
    switch (ctx.nodeTag(node)) {
        .identifier => {
            const name = ctx.tokenSlice(ctx.mainToken(node));
            if (seen_params.contains(name)) appendShadowedParam(ctx, result, emitted_names, name);
        },
        .assignment_pattern => appendShadowedBindingsFromPattern(ctx, ctx.nodeData(node).binary.lhs, seen_params, emitted_names, result),
        .rest_element => appendShadowedBindingsFromPattern(ctx, ctx.nodeData(node).unary, seen_params, emitted_names, result),
        .ts_parameter_property => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return;
            appendShadowedBindingsFromPattern(ctx, @enumFromInt(ctx.ast.extra_data.items[extra_idx]), seen_params, emitted_names, result);
        },
        .array_pattern => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
            const range_start = ctx.ast.extra_data.items[extra_idx];
            const range_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[range_start..range_end]) |raw| {
                appendShadowedBindingsFromPattern(ctx, @enumFromInt(raw), seen_params, emitted_names, result);
            }
        },
        .object_pattern => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
            const range_start = ctx.ast.extra_data.items[extra_idx];
            const range_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[range_start..range_end]) |raw| {
                const prop: NodeIndex = @enumFromInt(raw);
                if (prop == .none) continue;
                switch (ctx.nodeTag(prop)) {
                    .property, .computed_property => appendShadowedBindingsFromPattern(ctx, ctx.nodeData(prop).binary.rhs, seen_params, emitted_names, result),
                    .shorthand_property, .rest_element => appendShadowedBindingsFromPattern(ctx, ctx.nodeData(prop).unary, seen_params, emitted_names, result),
                    else => appendShadowedBindingsFromPattern(ctx, prop, seen_params, emitted_names, result),
                }
            }
        },
        else => {},
    }
}

fn collectBindingNames(
    ctx: *TransformContext,
    node: NodeIndex,
    names: *std.StringHashMapUnmanaged(void),
) void {
    if (node == .none) return;
    switch (ctx.nodeTag(node)) {
        .identifier => {
            names.put(ctx.allocator, ctx.tokenSlice(ctx.mainToken(node)), {}) catch {};
        },
        .assignment_pattern => collectBindingNames(ctx, ctx.nodeData(node).binary.lhs, names),
        .rest_element => collectBindingNames(ctx, ctx.nodeData(node).unary, names),
        .ts_parameter_property => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return;
            collectBindingNames(ctx, @enumFromInt(ctx.ast.extra_data.items[extra_idx]), names);
        },
        .array_pattern => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
            const range_start = ctx.ast.extra_data.items[extra_idx];
            const range_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[range_start..range_end]) |raw| {
                collectBindingNames(ctx, @enumFromInt(raw), names);
            }
        },
        .object_pattern => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return;
            const range_start = ctx.ast.extra_data.items[extra_idx];
            const range_end = ctx.ast.extra_data.items[extra_idx + 1];
            for (ctx.ast.extra_data.items[range_start..range_end]) |raw| {
                const prop: NodeIndex = @enumFromInt(raw);
                if (prop == .none) continue;
                switch (ctx.nodeTag(prop)) {
                    .property, .computed_property => collectBindingNames(ctx, ctx.nodeData(prop).binary.rhs, names),
                    .shorthand_property, .rest_element => collectBindingNames(ctx, ctx.nodeData(prop).unary, names),
                    else => collectBindingNames(ctx, prop, names),
                }
            }
        },
        else => {},
    }
}

fn patternHasBindingNames(ctx: *TransformContext, pattern: NodeIndex) bool {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(ctx.allocator);
    collectBindingNames(ctx, pattern, &names);
    return names.count() > 0;
}

const FunctionWrapInfo = struct {
    is_generator: bool = false,
    is_async: bool = false,
};

fn getFunctionWrapInfo(ctx: *TransformContext, idx: NodeIndex, tag: Node.Tag) FunctionWrapInfo {
    var info: FunctionWrapInfo = .{};
    switch (tag) {
        .async_function_declaration => info.is_async = true,
        .generator_declaration => info.is_generator = true,
        .async_generator_declaration => {
            info.is_async = true;
            info.is_generator = true;
        },
        .function_expr => {
            const eidx = @intFromEnum(ctx.nodeData(idx).extra);
            if (eidx + 4 < ctx.ast.extra_data.items.len) {
                const flags = ctx.ast.extra_data.items[eidx + 4];
                info.is_generator = (flags & 1) != 0;
                info.is_async = (flags & 2) != 0;
            }
        },
        .method_definition, .class_method, .class_private_method => {
            const eidx = @intFromEnum(ctx.nodeData(idx).extra);
            if (eidx + 4 < ctx.ast.extra_data.items.len) {
                const flags = ctx.ast.extra_data.items[eidx + 4];
                info.is_generator = (flags & 4) != 0;
                info.is_async = (flags & 8) != 0;
            }
        },
        else => {},
    }
    return info;
}

const ParamIifeCaptureInfo = struct {
    has_this: bool = false,
    has_arguments: bool = false,
    has_new_target: bool = false,
    has_super_prop: bool = false,
    this_name: ?[]const u8 = null,
    arguments_name: ?[]const u8 = null,
    new_target_name: ?[]const u8 = null,
    super_prop_name: ?[]const u8 = null,
    super_prop_source: ?[]const u8 = null,
};

fn rewriteParamIifeLexicalCaptures(ctx: *TransformContext, body_node: NodeIndex) ParamIifeCaptureInfo {
    var info: ParamIifeCaptureInfo = .{};
    collectParamIifeLexicalCaptures(ctx, body_node, &info);
    if (info.has_new_target) {
        const new_target_name = allocNextRefName(ctx, "_newtarget");
        info.new_target_name = new_target_name;
        rewriteParamIifeNewTargetCapture(ctx, body_node, new_target_name);
    }
    if (info.has_super_prop) {
        const base = buildParamIifeSuperPropBaseName(ctx, info.super_prop_source orelse "super");
        const super_prop_name = allocNextRefName(ctx, base);
        info.super_prop_name = super_prop_name;
        rewriteParamIifeSuperPropCapture(ctx, body_node, super_prop_name);
    }
    if (info.has_this) {
        const this_name = allocNextRefName(ctx, "_this");
        info.this_name = this_name;
        rewriteParamIifeThisCapture(ctx, body_node, this_name);
    }
    if (info.has_arguments) {
        const arguments_name = allocNextRefName(ctx, "_arguments");
        info.arguments_name = arguments_name;
        rewriteParamIifeArgumentsCapture(ctx, body_node, arguments_name);
    }
    return info;
}

fn collectParamIifeLexicalCaptures(ctx: *TransformContext, root: NodeIndex, info: *ParamIifeCaptureInfo) void {
    const WorkItem = struct {
        node: NodeIndex,
    };

    var work_stack: std.ArrayListUnmanaged(WorkItem) = .empty;
    defer work_stack.deinit(ctx.allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(ctx.allocator);

    work_stack.append(ctx.allocator, .{ .node = root }) catch return;

    while (work_stack.items.len > 0) {
        const item = work_stack.items[work_stack.items.len - 1];
        work_stack.items.len -= 1;
        if (item.node == .none) continue;

        const ni = @intFromEnum(item.node);
        if (ni >= ctx.ast.nodes.items(.tag).len) continue;
        if (visited.contains(@intCast(ni))) continue;
        visited.put(ctx.allocator, @intCast(ni), {}) catch return;

        const tag = ctx.nodeTag(item.node);
        if (item.node != root and isParamIifeBoundaryTag(tag)) continue;

        if (tag == .this_expr) {
            info.has_this = true;
            continue;
        }

        if (tag == .meta_property) {
            info.has_new_target = true;
            continue;
        }

        if (tag == .identifier) {
            const name = ctx.tokenSlice(ctx.mainToken(item.node));
            if (std.mem.eql(u8, name, "arguments") and isParamIifeArgumentsReference(ctx, item.node)) {
                info.has_arguments = true;
                continue;
            }
        }

        if (tag == .member_expr or tag == .optional_chain_expr) {
            const lhs = ctx.nodeData(item.node).binary.lhs;
            if (lhs != .none and ctx.nodeTag(lhs) == .super_expr) {
                info.has_super_prop = true;
                if (info.super_prop_source == null) info.super_prop_source = getNodeSource(ctx, item.node);
                continue;
            }
            work_stack.append(ctx.allocator, .{ .node = ctx.nodeData(item.node).binary.lhs }) catch return;
            continue;
        }

        const children = visitor.getChildren(ctx.ast, item.node);
        var child_i: u8 = 0;
        while (child_i < children.len) : (child_i += 1) {
            work_stack.append(ctx.allocator, .{ .node = children.items[child_i] }) catch return;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch return;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch return;
            }
        }
    }
}

fn rewriteParamIifeNewTargetCapture(ctx: *TransformContext, root: NodeIndex, new_target_name: []const u8) void {
    if (root == .none) return;
    const tag = ctx.nodeTag(root);
    if (tag == .meta_property) {
        putReplacement(ctx, @intFromEnum(root), new_target_name);
        return;
    }
    if (isParamIifeBoundaryTag(tag)) return;

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        rewriteParamIifeNewTargetCapture(ctx, child, new_target_name);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            rewriteParamIifeNewTargetCapture(ctx, @enumFromInt(raw), new_target_name);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            rewriteParamIifeNewTargetCapture(ctx, @enumFromInt(raw), new_target_name);
        }
    }
}

fn rewriteParamIifeSuperPropCapture(ctx: *TransformContext, root: NodeIndex, super_prop_name: []const u8) void {
    if (root == .none) return;
    const tag = ctx.nodeTag(root);
    if (tag == .member_expr or tag == .optional_chain_expr) {
        const lhs = ctx.nodeData(root).binary.lhs;
        if (lhs != .none and ctx.nodeTag(lhs) == .super_expr) {
            const replacement = std.fmt.allocPrint(ctx.allocator, "{s}()", .{super_prop_name}) catch return;
            putReplacement(ctx, @intFromEnum(root), replacement);
            return;
        }
        rewriteParamIifeSuperPropCapture(ctx, lhs, super_prop_name);
        return;
    }
    if (isParamIifeBoundaryTag(tag)) return;

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        rewriteParamIifeSuperPropCapture(ctx, child, super_prop_name);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            rewriteParamIifeSuperPropCapture(ctx, @enumFromInt(raw), super_prop_name);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            rewriteParamIifeSuperPropCapture(ctx, @enumFromInt(raw), super_prop_name);
        }
    }
}

fn buildParamIifeSuperPropBaseName(ctx: *TransformContext, source: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "super.")) return "_superprop_get";
    const prop = trimmed["super.".len..];
    if (prop.len == 0) return "_superprop_get";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "_superprop_get") catch return "_superprop_get";
    buf.append(ctx.allocator, std.ascii.toUpper(prop[0])) catch return "_superprop_get";
    if (prop.len > 1) buf.appendSlice(ctx.allocator, prop[1..]) catch return "_superprop_get";
    return buf.items;
}

fn rewriteParamIifeThisCapture(ctx: *TransformContext, root: NodeIndex, this_name: []const u8) void {
    if (root == .none) return;
    if (ctx.nodeTag(root) == .this_expr) {
        putReplacement(ctx, @intFromEnum(root), this_name);
        return;
    }
    if (isParamIifeBoundaryTag(ctx.nodeTag(root))) return;

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        rewriteParamIifeThisCapture(ctx, child, this_name);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            rewriteParamIifeThisCapture(ctx, @enumFromInt(raw), this_name);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            rewriteParamIifeThisCapture(ctx, @enumFromInt(raw), this_name);
        }
    }
}

fn rewriteParamIifeArgumentsCapture(ctx: *TransformContext, root: NodeIndex, arguments_name: []const u8) void {
    if (root == .none) return;
    const tag = ctx.nodeTag(root);
    if (tag == .identifier) {
        const name = ctx.tokenSlice(ctx.mainToken(root));
        if (std.mem.eql(u8, name, "arguments") and isParamIifeArgumentsReference(ctx, root)) {
            putReplacement(ctx, @intFromEnum(root), arguments_name);
            return;
        }
    }
    if (isParamIifeBoundaryTag(tag)) return;
    if (tag == .member_expr or tag == .optional_chain_expr) {
        rewriteParamIifeArgumentsCapture(ctx, ctx.nodeData(root).binary.lhs, arguments_name);
        return;
    }

    const children = visitor.getChildren(ctx.ast, root);
    for (children.items[0..children.len]) |child| {
        rewriteParamIifeArgumentsCapture(ctx, child, arguments_name);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            rewriteParamIifeArgumentsCapture(ctx, @enumFromInt(raw), arguments_name);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            rewriteParamIifeArgumentsCapture(ctx, @enumFromInt(raw), arguments_name);
        }
    }
}

fn emitParamIifeCaptureBindings(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    info: ParamIifeCaptureInfo,
    indent: []const u8,
) void {
    var entries: [4][]const u8 = undefined;
    var count: usize = 0;

    if (info.has_new_target and info.new_target_name != null) {
        entries[count] = std.fmt.allocPrint(ctx.allocator, "{s} = new.target", .{info.new_target_name.?}) catch return;
        count += 1;
    }
    if (info.has_super_prop and info.super_prop_name != null and info.super_prop_source != null) {
        entries[count] = std.fmt.allocPrint(ctx.allocator, "{s} = () => {s}", .{ info.super_prop_name.?, info.super_prop_source.? }) catch return;
        count += 1;
    }
    if (info.has_arguments and info.arguments_name != null) {
        entries[count] = std.fmt.allocPrint(ctx.allocator, "{s} = arguments", .{info.arguments_name.?}) catch return;
        count += 1;
    }
    if (info.has_this and info.this_name != null) {
        entries[count] = std.fmt.allocPrint(ctx.allocator, "{s} = this", .{info.this_name.?}) catch return;
        count += 1;
    }
    if (count == 0) return;

    buf.appendSlice(ctx.allocator, indent) catch return;
    buf.appendSlice(ctx.allocator, "var ") catch return;
    buf.appendSlice(ctx.allocator, entries[0]) catch return;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        buf.appendSlice(ctx.allocator, ",\n") catch return;
        buf.appendSlice(ctx.allocator, indent) catch return;
        buf.appendSlice(ctx.allocator, "  ") catch return;
        buf.appendSlice(ctx.allocator, entries[i]) catch return;
    }
    buf.appendSlice(ctx.allocator, ";\n") catch return;
}

fn wrapArrowCaptureIife(
    ctx: *TransformContext,
    function_source: []const u8,
    captures: ParamIifeCaptureInfo,
) []const u8 {
    if (!captures.has_this and !captures.has_arguments and !captures.has_new_target and !captures.has_super_prop) {
        return std.fmt.allocPrint(ctx.allocator, "(() => {s})()", .{function_source}) catch function_source;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "(() => {\n") catch return function_source;
    emitParamIifeCaptureBindings(&buf, ctx, captures, "  ");
    buf.appendSlice(ctx.allocator, "  return ") catch return function_source;
    appendWrappedFunctionSource(&buf, ctx, function_source, "  ");
    buf.appendSlice(ctx.allocator, ";\n})()") catch return function_source;
    return buf.items;
}

fn appendWrappedFunctionSource(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    source: []const u8,
    continuation_indent: []const u8,
) void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            buf.append(ctx.allocator, '\n') catch return;
            buf.appendSlice(ctx.allocator, continuation_indent) catch return;
        }
        first = false;
        buf.appendSlice(ctx.allocator, line) catch return;
    }
}

fn isParamIifeBoundaryTag(tag: Node.Tag) bool {
    return switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .arrow_function_expr,
        .method_definition,
        .computed_method,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        .class_declaration,
        .class_expr,
        .class_body,
        => true,
        else => false,
    };
}

fn isParamIifeArgumentsReference(ctx: *TransformContext, node: NodeIndex) bool {
    const parent = findParentOf(ctx, node) orelse return true;
    return switch (ctx.nodeTag(parent)) {
        .property => ctx.nodeData(parent).binary.lhs != node,
        .declarator => ctx.nodeData(parent).binary.rhs == node,
        .assignment_pattern => ctx.nodeData(parent).binary.rhs == node,
        .rest_element => false,
        else => true,
    };
}

fn isEmptyBlockStatement(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none or ctx.nodeTag(node) != .block_statement) return false;
    const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    return ctx.ast.extra_data.items[extra_idx] == ctx.ast.extra_data.items[extra_idx + 1];
}

fn getFunctionName(ctx: *TransformContext, node: NodeIndex) ?[]const u8 {
    if (node == .none) return null;
    switch (ctx.nodeTag(node)) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        => {
            const extra_idx = @intFromEnum(ctx.nodeData(node).extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) return null;
            const name_raw = ctx.ast.extra_data.items[extra_idx];
            if (name_raw >= ctx.ast.nodes.items(.tag).len) return null;
            const name_node: NodeIndex = @enumFromInt(name_raw);
            if (name_node == .none or ctx.nodeTag(name_node) != .identifier) return null;
            return ctx.tokenSlice(ctx.mainToken(name_node));
        },
        else => return null,
    }
}

fn getKeptParamSource(ctx: *TransformContext, param: ParamInfo) []const u8 {
    return switch (param.kind) {
        .normal => getNodeSourceWithTypeAnnotation(ctx, param.node),
        .default_value => getNodeSourceWithTypeAnnotation(ctx, ctx.nodeData(param.node).binary.lhs),
        .pattern, .pattern_default => getKeptPatternParamSource(ctx, param, getNodeSource(ctx, patternNode(ctx, param))),
        .rest => getParamBindingSource(ctx, param),
    };
}

fn needsParamOuterBindingIife(ctx: *TransformContext, func_node: NodeIndex, params: []const ParamInfo) bool {
    const scope_result = ctx.scope orelse return false;
    const func_scope_idx = scope_mod.getScopeForNode(scope_result, func_node) orelse return false;
    const func_scope = scope_result.scopes[@intFromEnum(func_scope_idx)];
    const parent_scope_idx = func_scope.parent orelse return false;

    for (params) |param| {
        if (param.kind == .normal or param.kind == .rest) continue;
        if (paramSubtreeNeedsOuterBindingIife(ctx, scope_result, func_scope_idx, parent_scope_idx, param.node)) {
            return true;
        }
    }

    return false;
}

fn paramSubtreeNeedsOuterBindingIife(
    ctx: *TransformContext,
    scope_result: *const scope_mod.ScopeResult,
    func_scope_idx: scope_mod.ScopeIndex,
    parent_scope_idx: scope_mod.ScopeIndex,
    root: NodeIndex,
) bool {
    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, root) catch return false;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        switch (ctx.nodeTag(node)) {
            .ts_type_annotation,
            .flow_type_annotation,
            .ts_type_parameter_declaration,
            .flow_type_parameter_declaration,
            => continue,
            .identifier => {
                if (!shouldCheckOuterBindingIdentifier(ctx, node)) continue;
                const name = ctx.tokenSlice(ctx.mainToken(node));
                if (std.mem.eql(u8, name, "eval")) return true;
                if (!scopeHasNonParamOwnBinding(scope_result, func_scope_idx, name)) continue;

                const outer_binding = scope_mod.getBindingIndex(scope_result, parent_scope_idx, name) orelse continue;
                const current_binding = getResolvedIdentifierBindingIndex(ctx, node) orelse return true;
                if (scope_result.bindings[current_binding].kind == .param) continue;
                const current_scope = scope_result.bindings[current_binding].scope;
                if (current_binding == outer_binding or current_scope == func_scope_idx) return true;
            },
            else => {},
        }

        const children = visitor.getChildren(ctx.ast, node);
        var child_i: u8 = 0;
        while (child_i < children.len) : (child_i += 1) {
            stack.append(ctx.allocator, children.items[child_i]) catch return false;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return false;
            }
        }
    }

    return false;
}

fn shouldCheckOuterBindingIdentifier(ctx: *TransformContext, node: NodeIndex) bool {
    const parent = findParentOf(ctx, node) orelse return true;
    return switch (ctx.nodeTag(parent)) {
        .property => ctx.nodeData(parent).binary.lhs != node,
        else => true,
    };
}

fn scopeHasOwnBinding(
    scope_result: *const scope_mod.ScopeResult,
    scope_idx: scope_mod.ScopeIndex,
    name: []const u8,
) bool {
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];
    for (scope_result.bindings[scope.bindings_start..scope.bindings_end]) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

fn scopeHasNonParamOwnBinding(
    scope_result: *const scope_mod.ScopeResult,
    scope_idx: scope_mod.ScopeIndex,
    name: []const u8,
) bool {
    const scope = scope_result.scopes[@intFromEnum(scope_idx)];
    for (scope_result.bindings[scope.bindings_start..scope.bindings_end]) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        if (binding.kind != .param) return true;
    }
    return false;
}

fn getKeptPatternParamSource(ctx: *TransformContext, param: ParamInfo, temp_name: []const u8) []const u8 {
    const pattern = patternNode(ctx, param);
    if (pattern == .none) return temp_name;
    if (!g_config.preserve_type_annotations) return temp_name;
    if (ctx.ast.type_annotations.get(@intFromEnum(pattern))) |type_ann| {
        return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ temp_name, getGeneratedSource(ctx, type_ann) }) catch temp_name;
    }
    return temp_name;
}

fn getBindingSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (g_config.preserve_type_annotations) return getNodeSourceWithTypeAnnotation(ctx, node);
    return getGeneratedSource(ctx, node);
}

fn getNodeSourceWithTypeAnnotation(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const base = getGeneratedSource(ctx, node);
    if (!g_config.preserve_type_annotations) return base;
    if (ctx.ast.type_annotations.get(@intFromEnum(node))) |type_ann| {
        return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ base, getGeneratedSource(ctx, type_ann) }) catch base;
    }
    return base;
}

fn wrapArrowSpecReplacement(ctx: *TransformContext, arrow_idx: NodeIndex, replacement: []const u8) []const u8 {
    if (g_config.arrow_no_new_arrows) return replacement;
    if (std.mem.indexOf(u8, replacement, ".bind(this)") != null) return replacement;

    const body = findEnclosingHoistBody(ctx, arrow_idx);
    if (body == .none) return replacement;
    const this_name = allocNextRefName(ctx, "_this");
    const prefix = std.fmt.allocPrint(ctx.allocator, "var {s} = this;", .{this_name}) catch return replacement;
    appendPrefixToBody(ctx, body, prefix);
    var result = replacement;

    if (getArrowName(ctx, arrow_idx)) |name| {
        if (std.mem.startsWith(u8, result, "async function (")) {
            result = std.fmt.allocPrint(ctx.allocator, "async function {s}{s}", .{ name, result["async function (".len - 1 ..] }) catch result;
        } else if (std.mem.startsWith(u8, result, "function (")) {
            result = std.fmt.allocPrint(ctx.allocator, "function {s}{s}", .{ name, result["function (".len - 1 ..] }) catch result;
        }
    }

    const return_pos = std.mem.lastIndexOf(u8, result, "  return ") orelse std.mem.lastIndexOf(u8, result, "}") orelse return result;
    const check_stmt = std.fmt.allocPrint(ctx.allocator, "  babelHelpers.newArrowCheck(this, {s});\n", .{this_name}) catch return result;
    result = std.fmt.allocPrint(ctx.allocator, "{s}{s}{s}.bind(this)", .{ result[0..return_pos], check_stmt, result[return_pos..] }) catch result;
    return result;
}

fn renameResolvedBindingInSubtree(ctx: *TransformContext, root: NodeIndex, binding_idx: u32, new_name: []const u8) void {
    if (ctx.session) |session| {
        const root_range = session.subtreeRange(root);
        const occurrences = session.bindingOccurrences(binding_idx);
        for (occurrences) |occurrence| {
            const occurrence_range = session.subtreeRange(occurrence.node);
            if (occurrence_range.start < root_range.start or occurrence_range.end > root_range.end) continue;
            putReplacement(ctx, @intFromEnum(occurrence.node), new_name);
        }
        return;
    }

    const WorkItem = struct {
        node: NodeIndex,
    };

    var work_stack: std.ArrayListUnmanaged(WorkItem) = .empty;
    defer work_stack.deinit(ctx.allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(ctx.allocator);

    work_stack.append(ctx.allocator, .{ .node = root }) catch return;

    while (work_stack.items.len > 0) {
        const item = work_stack.items[work_stack.items.len - 1];
        work_stack.items.len -= 1;
        if (item.node == .none) continue;
        const ni = @intFromEnum(item.node);
        if (ni >= ctx.ast.nodes.items(.tag).len) continue;
        if (visited.contains(@intCast(ni))) continue;
        visited.put(ctx.allocator, @intCast(ni), {}) catch return;

        const tag = ctx.nodeTag(item.node);
        if (tag == .identifier) {
            if (isResolvedBindingReference(ctx, item.node, binding_idx)) {
                putReplacement(ctx, @intCast(ni), new_name);
            }
        }

        if (tag == .member_expr or tag == .optional_chain_expr) {
            const d = ctx.nodeData(item.node);
            work_stack.append(ctx.allocator, .{ .node = d.binary.lhs }) catch return;
            continue;
        }

        const children = visitor.getChildren(ctx.ast, item.node);
        var ci: u8 = 0;
        while (ci < children.len) : (ci += 1) {
            work_stack.append(ctx.allocator, .{ .node = children.items[ci] }) catch return;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch return;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                work_stack.append(ctx.allocator, .{ .node = @enumFromInt(raw) }) catch return;
            }
        }
    }
}

// ── Body helpers ──────────────────────────────────────────────────

/// Get body source text, reconstructing from children if any have replacement_source.
fn getBodySourceWithReplacements(ctx: *TransformContext, body_node: NodeIndex) []const u8 {
    if (body_node == .none) return "{}";
    const tag = ctx.nodeTag(body_node);
    if (tag != .block_statement) return getNodeSource(ctx, body_node);

    const data = ctx.nodeData(body_node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return "{}";

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];

    // Check if any child or descendant has a replacement_source
    var has_replacements = false;
    for (ctx.ast.extra_data.items[range_start..range_end]) |stmt_raw| {
        if (hasReplacementInSubtree(ctx, @enumFromInt(stmt_raw))) {
            has_replacements = true;
            break;
        }
    }

    if (!has_replacements and !g_config.emit_var_bindings) {
        const raw = getNodeSource(ctx, body_node);
        if (looksLikeBlockSource(raw)) return raw;
    }

    // Reconstruct body with replacements
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "{\n") catch return "{}";
    emitTransformedBodyWithIndent(&buf, ctx, body_node, "  ");
    buf.appendSlice(ctx.allocator, "}") catch {};
    return buf.items;
}

fn getBlockRange(ctx: *TransformContext, body_node: NodeIndex) ?BlockRange {
    if (body_node == .none or ctx.nodeTag(body_node) != .block_statement) return null;
    const data = ctx.nodeData(body_node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return null;
    return .{
        .start = ctx.ast.extra_data.items[extra_idx],
        .end = ctx.ast.extra_data.items[extra_idx + 1],
    };
}

fn blockNeedsReconstruction(ctx: *TransformContext, range: BlockRange) bool {
    for (ctx.ast.extra_data.items[range.start..range.end]) |stmt_raw| {
        if (hasReplacementInSubtree(ctx, @enumFromInt(stmt_raw))) return true;
    }
    return false;
}

fn hasTransparentReturnWrapperInSubtree(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    ensureTransparentReturnCache(ctx);
    const ni = @intFromEnum(node);
    if (ni < g_transparent_return_cache.len) {
        switch (g_transparent_return_cache[ni]) {
            1 => return false,
            2 => return true,
            else => {},
        }
    }

    const result = switch (ctx.nodeTag(node)) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .arrow_function_expr,
        .class_declaration,
        .class_expr,
        .class_body,
        .method_definition,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        => false,
        .return_statement => blk: {
            const expr = ctx.nodeData(node).unary;
            break :blk expr != .none and unwrapTransparentReturnExpr(ctx, expr) != expr;
        },
        else => blk: {
            const children = visitor.getChildren(ctx.ast, node);
            var i: u8 = 0;
            while (i < children.len) : (i += 1) {
                if (hasTransparentReturnWrapperInSubtree(ctx, children.items[i])) break :blk true;
            }
            if (children.range_end > children.range_start) {
                for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                    if (hasTransparentReturnWrapperInSubtree(ctx, @enumFromInt(raw))) break :blk true;
                }
            }
            if (children.range2_end > children.range2_start) {
                for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                    if (hasTransparentReturnWrapperInSubtree(ctx, @enumFromInt(raw))) break :blk true;
                }
            }
            break :blk false;
        },
    };

    if (ni < g_transparent_return_cache.len) {
        g_transparent_return_cache[ni] = if (result) 2 else 1;
    }
    return result;
}

fn emitTransformedBodyWithIndent(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    body_node: NodeIndex,
    indent: []const u8,
) void {
    if (body_node == .none) return;
    if (ctx.nodeTag(body_node) != .block_statement) {
        const body_src = getGeneratedSource(ctx, body_node);
        buf.appendSlice(ctx.allocator, indent) catch return;
        buf.appendSlice(ctx.allocator, "return ") catch return;
        buf.appendSlice(ctx.allocator, body_src) catch return;
        buf.appendSlice(ctx.allocator, ";\n") catch return;
        return;
    }

    const range = getBlockRange(ctx, body_node) orelse return;
    const prefix = ctx.ast.block_prefix_source.get(@intFromEnum(body_node));
    const needs_reconstruction = g_config.emit_var_bindings or
        prefix != null or
        blockNeedsReconstruction(ctx, range) or
        hasTransparentReturnWrapperInSubtree(ctx, body_node);

    if (!needs_reconstruction) {
        const raw = getNodeSource(ctx, body_node);
        if (looksLikeBlockSource(raw)) {
            emitBodyWithIndent(buf, ctx, raw, indent);
            return;
        }
    }

    if (prefix) |body_prefix| {
        emitIndentedSnippet(buf, ctx, body_prefix, indent);
    }

    var live_stmt_i: usize = 0;
    for (ctx.ast.extra_data.items[range.start..range.end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt == .none) continue;
        if (stmt_raw < ctx.ast.nodes.items(.tag).len and ctx.ast.nodes.items(.tag)[stmt_raw] == .removed) continue;

        const stmt_tag = ctx.nodeTag(stmt);
        const needs_reindent = hasReplacementNeedingReindentInSubtree(ctx, stmt);
        const has_direct_replacement = ctx.ast.replacement_source.get(@intFromEnum(stmt)) != null;
        var stmt_src = if (needs_reindent and needsPreservedDeclarationIndent(stmt_tag))
            getGeneratedSource(ctx, stmt)
        else if (needs_reindent)
            getNodeSourceRecursive(ctx, stmt)
        else if (shouldGenerateStatementSource(ctx, stmt))
            getGeneratedSource(ctx, stmt)
        else
            getNodeSourceRecursive(ctx, stmt);
        if (stmt_src.len == 0) continue;
        stmt_src = appendTrailingInlineComment(ctx, body_node, range, live_stmt_i, stmt, stmt_src);
        if (needsPreservedDeclarationIndent(stmt_tag) and std.mem.indexOfScalar(u8, stmt_src, '\n') != null) {
            if (has_direct_replacement) {
                emitIndentedSnippet(buf, ctx, stmt_src, indent);
            } else {
                emitIndentedStatementSnippet(buf, ctx, stmt_src, indent);
            }
        } else if (stmt_tag == .return_statement and std.mem.indexOfScalar(u8, stmt_src, '\n') != null) {
            emitIndentedSnippetPreserveBlankLines(buf, ctx, stmt_src, indent);
        } else if (has_direct_replacement and preservesBlankLines(stmt_tag)) {
            emitIndentedSnippetPreserveBlankLines(buf, ctx, stmt_src, indent);
        } else if (needsPreservedDeclarationIndent(stmt_tag)) {
            emitPreservedStatementSnippet(buf, ctx, stmt_src, indent);
        } else if (needsStatementRelativeIndent(stmt_tag) and !has_direct_replacement) {
            emitIndentedStatementSnippet(buf, ctx, stmt_src, indent);
        } else {
            emitIndentedSnippet(buf, ctx, stmt_src, indent);
        }
        live_stmt_i += 1;
    }
}

fn emitBodyPrefixIntoBuffer(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    body_node: NodeIndex,
    indent: []const u8,
) void {
    if (body_node == .none) return;
    const tag = ctx.nodeTag(body_node);
    if (tag != .block_statement and tag != .program) return;

    const body_i = @intFromEnum(body_node);
    const prefix = ctx.ast.block_prefix_source.get(body_i) orelse return;
    emitIndentedSnippet(buf, ctx, prefix, indent);
    _ = ctx.ast.block_prefix_source.remove(body_i);
}

fn isFunctionDeclarationTag(tag: Node.Tag) bool {
    return switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        => true,
        else => false,
    };
}

fn shouldGenerateStatementSource(ctx: *TransformContext, stmt: NodeIndex) bool {
    const tag = ctx.nodeTag(stmt);
    if (!hasReplacementInSubtree(ctx, stmt) and isFunctionDeclarationTag(tag)) return true;
    if (tag == .expression_statement or tag == .var_declaration or tag == .let_declaration or tag == .const_declaration) {
        const raw = std.mem.trimEnd(u8, getNodeSource(ctx, stmt), " \t\r\n");
        if (!std.mem.endsWith(u8, raw, ";")) return true;
    }
    return false;
}

fn bumpCacheEpoch(generations: []u32, epoch: *u32) void {
    if (epoch.* == std.math.maxInt(u32)) {
        @memset(generations, 0);
        epoch.* = 1;
        return;
    }
    epoch.* += 1;
}

fn readBoolEpochCache(cache: []u8, generations: []u32, epoch: u32, node_i: usize) ?bool {
    if (node_i >= cache.len or node_i >= generations.len) return null;
    if (generations[node_i] != epoch) return null;
    return switch (cache[node_i]) {
        1 => false,
        2 => true,
        else => null,
    };
}

fn writeBoolEpochCache(cache: []u8, generations: []u32, epoch: u32, node_i: usize, value: bool) void {
    if (node_i >= cache.len or node_i >= generations.len) return;
    cache[node_i] = if (value) 2 else 1;
    generations[node_i] = epoch;
}

fn invalidateReplacementSubtreeCache(ctx: *TransformContext) void {
    if (g_replacement_cache_ast != ctx.ast) return;
    bumpCacheEpoch(g_replacement_subtree_cache_epochs, &g_replacement_subtree_cache_epoch);
}

fn invalidateRecursiveSourceCache(ctx: *TransformContext) void {
    if (g_recursive_source_cache_ast != ctx.ast) return;
    bumpCacheEpoch(g_recursive_source_cache_epochs, &g_recursive_source_cache_epoch);
}

fn invalidateReindentSubtreeCache(ctx: *TransformContext) void {
    if (g_reindent_subtree_cache_ast != ctx.ast) return;
    bumpCacheEpoch(g_reindent_subtree_cache_epochs, &g_reindent_subtree_cache_epoch);
}

/// Check if a node or any descendant has a replacement_source.
fn hasReplacementInSubtree(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    ensureReplacementSubtreeCache(ctx);
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return false;
    if (readBoolEpochCache(g_replacement_subtree_cache, g_replacement_subtree_cache_epochs, g_replacement_subtree_cache_epoch, ni)) |cached| return cached;
    const result = ctx.ast.replacement_source.get(ni) != null or hasReplacementInSubtreeSlow(ctx, node);
    writeBoolEpochCache(g_replacement_subtree_cache, g_replacement_subtree_cache_epochs, g_replacement_subtree_cache_epoch, ni, result);
    return result;
}

fn hasReplacementNeedingReindentInSubtree(ctx: *TransformContext, node: NodeIndex) bool {
    if (node == .none) return false;
    ensureReindentSubtreeCache(ctx);
    const ni = @intFromEnum(node);
    if (ni < g_reindent_subtree_cache.len and g_reindent_subtree_cache_ast == ctx.ast) {
        return g_reindent_subtree_cache[ni] != 0;
    }
    return ctx.ast.replacement_needs_reindent.contains(ni) or
        subtreeHasReplacementRange(ctx, node, true) or
        hasReplacementNeedingReindentInSubtreeSlow(ctx, node);
}

fn subtreeHasReplacementRange(ctx: *TransformContext, node: NodeIndex, only_reindented: bool) bool {
    if (node == .none or ctx.ast.replacement_source.count() == 0) return false;
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return false;
    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return false;

    ensureReplacementRanges(ctx);
    var range_i = lowerBoundReplacementRange(start);
    while (range_i < g_replacement_ranges.items.len) : (range_i += 1) {
        const entry = g_replacement_ranges.items[range_i];
        if (entry.start >= end) break;
        if (entry.node_index == ni or entry.end > end) continue;
        if (only_reindented and !entry.needs_reindent) continue;
        return true;
    }
    return false;
}

fn hasReplacementInSubtreeSlow(ctx: *TransformContext, node: NodeIndex) bool {
    const children = visitor.getChildren(ctx.ast, node);
    var ci: u8 = 0;
    while (ci < children.len) : (ci += 1) {
        if (hasReplacementInSubtree(ctx, children.items[ci])) return true;
    }
    if (children.range_end > children.range_start) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (hasReplacementInSubtree(ctx, @enumFromInt(raw))) return true;
        }
    }
    return false;
}

fn hasReplacementNeedingReindentInSubtreeSlow(ctx: *TransformContext, node: NodeIndex) bool {
    const children = visitor.getChildren(ctx.ast, node);
    for (children.items[0..children.len]) |child| {
        if (hasReplacementNeedingReindentInSubtree(ctx, child)) return true;
    }
    if (children.range_end > children.range_start) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            if (hasReplacementNeedingReindentInSubtree(ctx, @enumFromInt(raw))) return true;
        }
    }
    if (children.range2_end > children.range2_start) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            if (hasReplacementNeedingReindentInSubtree(ctx, @enumFromInt(raw))) return true;
        }
    }
    return false;
}

fn ensureReplacementSubtreeCache(ctx: *TransformContext) void {
    const node_count = ctx.ast.nodes.items(.tag).len;
    if (g_replacement_cache_ast == ctx.ast and g_replacement_subtree_cache.len == node_count and g_replacement_subtree_cache_epochs.len == node_count) return;
    g_replacement_cache_ast = ctx.ast;
    g_replacement_subtree_cache = ctx.allocator.alloc(u8, node_count) catch &[_]u8{};
    g_replacement_subtree_cache_epochs = ctx.allocator.alloc(u32, node_count) catch &[_]u32{};
    @memset(g_replacement_subtree_cache, 0);
    @memset(g_replacement_subtree_cache_epochs, 0);
    g_replacement_subtree_cache_epoch = 1;
}

fn ensureReindentSubtreeCache(ctx: *TransformContext) void {
    const node_count = ctx.ast.nodes.items(.tag).len;
    if (g_reindent_subtree_cache_ast == ctx.ast and g_reindent_subtree_cache.len == node_count) return;
    g_reindent_subtree_cache_ast = ctx.ast;
    g_reindent_subtree_cache = ctx.allocator.alloc(u8, node_count) catch &[_]u8{};
    if (g_reindent_subtree_cache.len != node_count) {
        g_reindent_subtree_cache_ast = null;
        g_reindent_subtree_cache = &[_]u8{};
        return;
    }
    @memset(g_reindent_subtree_cache, 0);
    ensureParentMap(ctx);

    var iter = ctx.ast.replacement_needs_reindent.iterator();
    while (iter.next()) |entry| {
        markReindentSubtreeAncestors(ctx, entry.key_ptr.*);
    }
}

fn markReindentSubtreeAncestors(ctx: *TransformContext, start_node_i: u32) void {
    if (g_reindent_subtree_cache_ast != ctx.ast) return;
    if (start_node_i >= g_reindent_subtree_cache.len) return;
    ensureParentMap(ctx);

    var current_i = start_node_i;
    while (current_i < g_reindent_subtree_cache.len) {
        if (g_reindent_subtree_cache[current_i] != 0) break;
        g_reindent_subtree_cache[current_i] = 1;
        if (g_parent_session) |session| {
            const parent = session.parentOf(@enumFromInt(current_i)) orelse break;
            current_i = @intFromEnum(parent);
            continue;
        }
        if (!g_node_parents_ready) break;
        if (current_i >= g_node_parents.len) break;
        const parent_i = g_node_parents[current_i];
        if (parent_i == parent_none) break;
        current_i = parent_i;
    }
}

fn ensureTransparentReturnCache(ctx: *TransformContext) void {
    if (g_transparent_return_cache_ast == ctx.ast) return;
    g_transparent_return_cache_ast = ctx.ast;
    g_transparent_return_cache = ctx.allocator.alloc(u8, ctx.ast.nodes.items(.tag).len) catch &[_]u8{};
    @memset(g_transparent_return_cache, 0);
}

fn readRecursiveSourceCache(node_i: usize) ?[]const u8 {
    if (node_i >= g_recursive_source_cache.len or node_i >= g_recursive_source_cache_epochs.len) return null;
    if (g_recursive_source_cache_epochs[node_i] != g_recursive_source_cache_epoch) return null;
    return g_recursive_source_cache[node_i];
}

fn writeRecursiveSourceCache(node_i: usize, source: []const u8) void {
    if (node_i >= g_recursive_source_cache.len or node_i >= g_recursive_source_cache_epochs.len) return;
    g_recursive_source_cache[node_i] = source;
    g_recursive_source_cache_epochs[node_i] = g_recursive_source_cache_epoch;
}

/// Get node source text, recursively applying replacements on children.
fn getNodeSourceRecursive(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    ensureRecursiveSourceCache(ctx);
    const ni = @intFromEnum(node);
    if (ni >= ctx.ast.nodes.items(.tag).len) return "";
    if (readRecursiveSourceCache(ni)) |cached| return cached;

    const tag = ctx.nodeTag(node);

    // If this node has a replacement, use it directly
    if (ctx.ast.replacement_source.get(ni)) |replacement| {
        writeRecursiveSourceCache(ni, replacement);
        return replacement;
    }

    switch (tag) {
        .block_statement => {
            const src = getBodySourceWithReplacements(ctx, node);
            writeRecursiveSourceCache(ni, src);
            return src;
        },
        .expression_statement => {
            const raw = getNodeSource(ctx, node);
            const has_descendant_replacements = hasReplacementInSubtree(ctx, node);
            if (!has_descendant_replacements) {
                writeRecursiveSourceCache(ni, raw);
                return raw;
            }

            const expr = ctx.nodeData(node).unary;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            if (expr != .none) {
                const expr_src = getNodeSourceRecursive(ctx, expr);
                buf.appendSlice(ctx.allocator, expr_src) catch {
                    writeRecursiveSourceCache(ni, raw);
                    return raw;
                };
            }
            buf.append(ctx.allocator, ';') catch {
                writeRecursiveSourceCache(ni, raw);
                return raw;
            };
            writeRecursiveSourceCache(ni, buf.items);
            return buf.items;
        },
        .return_statement => {
            const raw = getNodeSource(ctx, node);
            const has_descendant_replacements = hasReplacementInSubtree(ctx, node);
            const raw_trimmed = std.mem.trimStart(u8, raw, " \t\r\n");
            const has_return_keyword = std.mem.startsWith(u8, raw_trimmed, "return");
            const expr = ctx.nodeData(node).unary;
            const has_transparent_return_wrapper = expr != .none and unwrapTransparentReturnExpr(ctx, expr) != expr;
            if (!has_descendant_replacements and !g_config.emit_var_bindings and has_return_keyword and !has_transparent_return_wrapper) {
                writeRecursiveSourceCache(ni, raw);
                return raw;
            }

            var buf: std.ArrayListUnmanaged(u8) = .empty;
            buf.appendSlice(ctx.allocator, "return") catch {
                writeRecursiveSourceCache(ni, raw);
                return raw;
            };
            if (expr != .none) {
                buf.appendSlice(ctx.allocator, " ") catch {
                    writeRecursiveSourceCache(ni, raw);
                    return raw;
                };
                const expr_has_direct_replacement = ctx.ast.replacement_source.get(@intFromEnum(expr)) != null;
                var expr_src = blk: {
                    const source_expr = if (ctx.nodeTag(expr) == .parenthesized_expr and expr_has_direct_replacement)
                        expr
                    else if (ctx.nodeTag(expr) == .parenthesized_expr and hasReplacementInSubtree(ctx, expr))
                        ctx.nodeData(expr).unary
                    else
                        unwrapTransparentReturnExpr(ctx, expr);
                    break :blk if (expr_has_direct_replacement or has_descendant_replacements)
                        getNodeSourceRecursive(ctx, source_expr)
                    else
                        getGeneratedSource(ctx, source_expr);
                };
                if (ctx.nodeTag(expr) == .parenthesized_expr and hasReplacementInSubtree(ctx, expr)) {
                    const trimmed_expr = std.mem.trim(u8, expr_src, " \t\r\n");
                    if (trimmed_expr.len >= 2 and trimmed_expr[0] == '(' and trimmed_expr[trimmed_expr.len - 1] == ')') {
                        expr_src = trimmed_expr[1 .. trimmed_expr.len - 1];
                    }
                }
                buf.appendSlice(ctx.allocator, expr_src) catch {
                    writeRecursiveSourceCache(ni, raw);
                    return raw;
                };
            }
            buf.append(ctx.allocator, ';') catch {
                writeRecursiveSourceCache(ni, raw);
                return raw;
            };
            writeRecursiveSourceCache(ni, buf.items);
            return buf.items;
        },
        else => {},
    }

    // Check if any descendant has a replacement
    if (!hasReplacementInSubtree(ctx, node)) {
        if (g_config.emit_var_bindings and tag == .if_statement) {
            const src = getGeneratedSource(ctx, node);
            writeRecursiveSourceCache(ni, src);
            return src;
        }
        const src = getNodeSource(ctx, node);
        writeRecursiveSourceCache(ni, src);
        return src;
    }

    if (needsStatementRelativeIndent(tag)) {
        const src = getGeneratedSource(ctx, node);
        writeRecursiveSourceCache(ni, src);
        return src;
    }

    // Reconstruct by substituting descendant replacements into source
    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";

    const raw = ctx.ast.source[start..end];

    ensureReplacementRanges(ctx);
    const range_start = lowerBoundReplacementRange(start);
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var cursor: u32 = start;
    var found_any = false;
    for (g_replacement_ranges.items[range_start..]) |entry| {
        if (entry.start >= end) break;
        if (entry.start < start or entry.end > end or entry.node_index == ni) continue;
        if (entry.start < cursor) continue;
        if (entry.start > cursor) {
            result.appendSlice(ctx.allocator, ctx.ast.source[cursor..entry.start]) catch {};
        }
        const entry_text = entry.text;
        if (entry.needs_reindent) {
            appendReplacementWithCurrentLineIndent(&result, ctx, entry_text);
        } else {
            result.appendSlice(ctx.allocator, entry_text) catch {};
        }
        cursor = entry.end;
        found_any = true;
    }
    if (!found_any) {
        writeRecursiveSourceCache(ni, raw);
        return raw;
    }
    if (cursor < end) {
        result.appendSlice(ctx.allocator, ctx.ast.source[cursor..end]) catch {};
    }
    writeRecursiveSourceCache(ni, result.items);
    return result.items;
}

fn ensureRecursiveSourceCache(ctx: *TransformContext) void {
    const node_count = ctx.ast.nodes.items(.tag).len;
    if (g_recursive_source_cache_ast == ctx.ast and g_recursive_source_cache.len == node_count and g_recursive_source_cache_epochs.len == node_count) return;
    g_recursive_source_cache_ast = ctx.ast;
    g_recursive_source_cache = ctx.allocator.alloc(?[]const u8, node_count) catch &[_]?[]const u8{};
    g_recursive_source_cache_epochs = ctx.allocator.alloc(u32, node_count) catch &[_]u32{};
    @memset(g_recursive_source_cache, null);
    @memset(g_recursive_source_cache_epochs, 0);
    g_recursive_source_cache_epoch = 1;
}

fn ensureReplacementRanges(ctx: *TransformContext) void {
    if (g_replacement_ranges_ast == ctx.ast) return;
    g_replacement_ranges_ast = ctx.ast;
    g_replacement_ranges = .empty;

    const replacement_count = ctx.ast.replacement_source.count();
    if (replacement_count == 0) {
        return;
    }

    g_replacement_ranges.ensureTotalCapacityPrecise(ctx.allocator, replacement_count) catch {
        g_replacement_ranges = .empty;
        return;
    };
    var iter = ctx.ast.replacement_source.iterator();
    while (iter.next()) |entry| {
        const node_index = entry.key_ptr.*;
        if (node_index >= ctx.ast.nodes.items(.tag).len) continue;
        g_replacement_ranges.appendAssumeCapacity(.{
            .node_index = node_index,
            .start = getNodeStart(ctx, @enumFromInt(node_index)),
            .end = ctx.ast.nodes.items(.end_offset)[node_index],
            .text = entry.value_ptr.*,
            .needs_reindent = ctx.ast.replacement_needs_reindent.contains(node_index),
        });
    }
    std.mem.sort(ReplacementRange, g_replacement_ranges.items, {}, struct {
        fn lt(_: void, a: ReplacementRange, b: ReplacementRange) bool {
            return a.start < b.start;
        }
    }.lt);
}

fn lowerBoundReplacementRange(target_start: u32) usize {
    var lo: usize = 0;
    var hi: usize = g_replacement_ranges.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (g_replacement_ranges.items[mid].start < target_start) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn appendReplacementWithCurrentLineIndent(
    buf: *std.ArrayListUnmanaged(u8),
    ctx: *TransformContext,
    replacement: []const u8,
) void {
    const indent = cloneCurrentLineIndent(ctx, buf.items);
    defer if (indent.len > 0) ctx.allocator.free(indent);

    var i: usize = 0;
    while (i < replacement.len) {
        const nl_pos = std.mem.indexOfScalar(u8, replacement[i..], '\n');
        if (nl_pos) |pos| {
            buf.appendSlice(ctx.allocator, replacement[i .. i + pos + 1]) catch return;
            i += pos + 1;
            if (i < replacement.len and indent.len > 0) {
                buf.appendSlice(ctx.allocator, indent) catch return;
            }
        } else {
            buf.appendSlice(ctx.allocator, replacement[i..]) catch return;
            break;
        }
    }
}

fn cloneCurrentLineIndent(ctx: *TransformContext, current: []const u8) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, current, '\n')) |idx| idx + 1 else 0;
    var indent_end = line_start;
    while (indent_end < current.len and (current[indent_end] == ' ' or current[indent_end] == '\t')) : (indent_end += 1) {}
    if (indent_end == line_start) return "";
    return ctx.allocator.dupe(u8, current[line_start..indent_end]) catch "";
}

fn updateReplacementRangeCache(ctx: *TransformContext, node_i: u32, replacement: []const u8) void {
    if (g_replacement_ranges_ast != ctx.ast) return;

    const node: NodeIndex = @enumFromInt(node_i);
    const start = getNodeStart(ctx, node);
    const insert_at = lowerBoundReplacementRange(start);
    var same_start = insert_at;
    while (same_start < g_replacement_ranges.items.len and g_replacement_ranges.items[same_start].start == start) : (same_start += 1) {
        if (g_replacement_ranges.items[same_start].node_index != node_i) continue;
        g_replacement_ranges.items[same_start].text = replacement;
        g_replacement_ranges.items[same_start].needs_reindent = ctx.ast.replacement_needs_reindent.contains(node_i);
        return;
    }

    const end = ctx.ast.nodes.items(.end_offset)[node_i];
    g_replacement_ranges.insert(ctx.allocator, insert_at, .{
        .node_index = node_i,
        .start = start,
        .end = end,
        .text = replacement,
        .needs_reindent = ctx.ast.replacement_needs_reindent.contains(node_i),
    }) catch {
        g_replacement_ranges_ast = null;
        g_replacement_ranges = .empty;
        return;
    };
}

fn markReplacementNeedsReindent(ctx: *TransformContext, node_i: u32) void {
    ctx.ast.replacement_needs_reindent.put(ctx.allocator, node_i, {}) catch return;
    invalidateRecursiveSourceCache(ctx);
    if (g_replacement_ranges_ast == ctx.ast) {
        const node: NodeIndex = @enumFromInt(node_i);
        const start = getNodeStart(ctx, node);
        var range_i = lowerBoundReplacementRange(start);
        while (range_i < g_replacement_ranges.items.len and g_replacement_ranges.items[range_i].start == start) : (range_i += 1) {
            if (g_replacement_ranges.items[range_i].node_index != node_i) continue;
            g_replacement_ranges.items[range_i].needs_reindent = true;
            break;
        }
    }
    markReindentSubtreeAncestors(ctx, node_i);
}

fn getGeneratedSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const comment_count = ctx.ast.comments.items.len;
    var emitted = std.DynamicBitSetUnmanaged.initEmpty(ctx.allocator, comment_count) catch {
        return getNodeSource(ctx, node);
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
    cg.emitNode(node) catch return getNodeSource(ctx, node);
    return cg.buf.toOwnedSlice(ctx.allocator) catch getNodeSource(ctx, node);
}

fn emitBodyWithIndent(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, body_src: []const u8, indent: []const u8) void {
    const open = std.mem.indexOf(u8, body_src, "{") orelse return;
    const close = std.mem.lastIndexOf(u8, body_src, "}") orelse return;
    if (close <= open + 1) return;
    const inner = body_src[open + 1 .. close];

    emitIndentedSnippet(buf, ctx, inner, indent);
}

fn emitIndentedSnippet(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, snippet: []const u8, indent: []const u8) void {
    if (snippet.len == 0) return;

    // Find minimum indentation
    var min_indent: usize = std.math.maxInt(usize);
    var line_iter = std.mem.splitScalar(u8, snippet, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const leading = line.len - trimmed.len;
        if (leading < min_indent) min_indent = leading;
    }
    if (min_indent == std.math.maxInt(usize)) return;

    var line_iter2 = std.mem.splitScalar(u8, snippet, '\n');
    while (line_iter2.next()) |line| {
        const trimmed_right = std.mem.trimEnd(u8, line, " \t\r");
        const trimmed_left = std.mem.trimStart(u8, trimmed_right, " \t");
        if (trimmed_left.len == 0) continue;
        const orig_indent = trimmed_right.len - trimmed_left.len;
        const extra = if (orig_indent >= min_indent) orig_indent - min_indent else 0;
        buf.appendSlice(ctx.allocator, indent) catch {};
        var ei: usize = 0;
        while (ei < extra) : (ei += 1) buf.append(ctx.allocator, ' ') catch {};
        const rewritten_left = rewriteFrozenBlockScopedLine(ctx, trimmed_left);
        buf.appendSlice(ctx.allocator, rewritten_left) catch {};
        buf.append(ctx.allocator, '\n') catch {};
    }
}

fn emitIndentedStatementSnippet(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, snippet: []const u8, indent: []const u8) void {
    if (snippet.len == 0) return;

    var min_indent: usize = std.math.maxInt(usize);
    var seen_first = false;
    var line_iter = std.mem.splitScalar(u8, snippet, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (!seen_first) {
            seen_first = true;
            continue;
        }
        const leading = line.len - trimmed.len;
        if (leading < min_indent) min_indent = leading;
    }
    if (min_indent == std.math.maxInt(usize)) {
        emitIndentedSnippet(buf, ctx, snippet, indent);
        return;
    }

    var line_iter2 = std.mem.splitScalar(u8, snippet, '\n');
    var is_first_line = true;
    while (line_iter2.next()) |line| {
        const trimmed_right = std.mem.trimEnd(u8, line, " \t\r");
        const trimmed_left = std.mem.trimStart(u8, trimmed_right, " \t");
        if (trimmed_left.len == 0) {
            buf.append(ctx.allocator, '\n') catch {};
            continue;
        }
        const orig_indent = trimmed_right.len - trimmed_left.len;
        const base_indent = if (is_first_line) 0 else min_indent;
        const extra = if (orig_indent >= base_indent) orig_indent - base_indent else 0;
        is_first_line = false;
        buf.appendSlice(ctx.allocator, indent) catch {};
        var ei: usize = 0;
        while (ei < extra) : (ei += 1) buf.append(ctx.allocator, ' ') catch {};
        const rewritten_left = rewriteFrozenBlockScopedLine(ctx, trimmed_left);
        buf.appendSlice(ctx.allocator, rewritten_left) catch {};
        buf.append(ctx.allocator, '\n') catch {};
    }
}

fn emitIndentedSnippetPreserveBlankLines(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, snippet: []const u8, indent: []const u8) void {
    if (snippet.len == 0) return;

    var line_iter = std.mem.splitScalar(u8, snippet, '\n');
    while (line_iter.next()) |line| {
        const trimmed_right = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed_right.len == 0) {
            buf.append(ctx.allocator, '\n') catch {};
            continue;
        }
        buf.appendSlice(ctx.allocator, indent) catch {};
        const rewritten_left = rewriteFrozenBlockScopedLine(ctx, trimmed_right);
        buf.appendSlice(ctx.allocator, rewritten_left) catch {};
        buf.append(ctx.allocator, '\n') catch {};
    }
}

fn emitPreservedStatementSnippet(buf: *std.ArrayListUnmanaged(u8), ctx: *TransformContext, snippet: []const u8, indent: []const u8) void {
    if (snippet.len == 0) return;

    var line_iter = std.mem.splitScalar(u8, snippet, '\n');
    while (line_iter.next()) |line| {
        const trimmed_right = std.mem.trimEnd(u8, line, " \t\r");
        const trimmed_left = std.mem.trimStart(u8, trimmed_right, " \t");
        if (trimmed_left.len == 0) continue;
        const orig_indent = trimmed_right.len - trimmed_left.len;
        buf.appendSlice(ctx.allocator, indent) catch {};
        var ei: usize = 0;
        while (ei < orig_indent) : (ei += 1) buf.append(ctx.allocator, ' ') catch {};
        const rewritten_left = rewriteFrozenBlockScopedLine(ctx, trimmed_left);
        buf.appendSlice(ctx.allocator, rewritten_left) catch {};
        buf.append(ctx.allocator, '\n') catch {};
    }
}

fn preservesBlankLines(tag: Node.Tag) bool {
    return switch (tag) {
        .class_declaration => true,
        else => false,
    };
}

fn rewriteFrozenBlockScopedLine(ctx: *TransformContext, line: []const u8) []const u8 {
    if (!g_config.emit_var_bindings) return line;
    if (std.mem.startsWith(u8, line, "let ")) return std.fmt.allocPrint(ctx.allocator, "var{s}", .{line["let".len..]}) catch line;
    if (std.mem.startsWith(u8, line, "const ")) return std.fmt.allocPrint(ctx.allocator, "var{s}", .{line["const".len..]}) catch line;
    if (std.mem.startsWith(u8, line, "for (let ")) return std.fmt.allocPrint(ctx.allocator, "for (var{s}", .{line["for (let".len..]}) catch line;
    if (std.mem.startsWith(u8, line, "for (const ")) return std.fmt.allocPrint(ctx.allocator, "for (var{s}", .{line["for (const".len..]}) catch line;
    if (std.mem.startsWith(u8, line, "for await (let ")) return std.fmt.allocPrint(ctx.allocator, "for await (var{s}", .{line["for await (let".len..]}) catch line;
    if (std.mem.startsWith(u8, line, "for await (const ")) return std.fmt.allocPrint(ctx.allocator, "for await (var{s}", .{line["for await (const".len..]}) catch line;
    return line;
}

fn appendTrailingInlineComment(
    ctx: *TransformContext,
    body_node: NodeIndex,
    range: BlockRange,
    stmt_i: usize,
    stmt: NodeIndex,
    stmt_src: []const u8,
) []const u8 {
    const stmt_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(stmt)];
    const next_boundary = nextBlockContentBoundary(ctx, body_node, range, stmt_i) orelse return stmt_src;
    if (stmt_end >= next_boundary or next_boundary > ctx.ast.source.len) return stmt_src;

    const gap = ctx.ast.source[stmt_end..next_boundary];
    const newline_idx = std.mem.indexOfScalar(u8, gap, '\n') orelse gap.len;
    const maybe_comment = gap[0..newline_idx];
    const trimmed = std.mem.trimStart(u8, maybe_comment, " \t");
    if (trimmed.len == 0) return stmt_src;
    if (!std.mem.startsWith(u8, trimmed, "//") and !std.mem.startsWith(u8, trimmed, "/*")) return stmt_src;
    markConsumedCommentsInRange(ctx, stmt_end, stmt_end + @as(u32, @intCast(maybe_comment.len)));

    return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ stmt_src, maybe_comment }) catch stmt_src;
}

fn markConsumedCommentsInRange(ctx: *TransformContext, start: u32, end: u32) void {
    for (ctx.ast.comments.items) |comment| {
        if (comment.start < start or comment.start >= end) continue;
        ctx.ast.consumed_comments.put(ctx.allocator, comment.start, {}) catch {};
    }
}

fn nextBlockContentBoundary(
    ctx: *TransformContext,
    body_node: NodeIndex,
    range: BlockRange,
    stmt_i: usize,
) ?u32 {
    var live_index: usize = 0;
    for (ctx.ast.extra_data.items[range.start..range.end]) |raw| {
        if (raw >= ctx.ast.nodes.items(.tag).len) continue;
        if (ctx.ast.nodes.items(.tag)[raw] == .removed) continue;
        if (live_index == stmt_i + 1) {
            return getNodeStart(ctx, @enumFromInt(raw));
        }
        live_index += 1;
    }

    const body_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(body_node)];
    return if (body_end > 0) body_end - 1 else null;
}

fn needsStatementRelativeIndent(tag: Node.Tag) bool {
    return switch (tag) {
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        .if_statement,
        .switch_statement,
        .try_statement,
        => true,
        else => false,
    };
}

fn needsPreservedDeclarationIndent(tag: Node.Tag) bool {
    return switch (tag) {
        .var_declaration,
        .let_declaration,
        .const_declaration,
        => true,
        else => false,
    };
}

fn looksLikeBlockSource(src: []const u8) bool {
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    return trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}';
}

fn putReplacement(ctx: *TransformContext, node_i: u32, replacement: []const u8) void {
    const node: NodeIndex = @enumFromInt(node_i);
    const tag = ctx.nodeTag(node);
    const final_replacement = if ((tag == .function_expr or tag == .arrow_function_expr) and startsLikeFunctionExpression(replacement) and needsFunctionExpressionParens(ctx, node))
        std.fmt.allocPrint(ctx.allocator, "({s})", .{replacement}) catch replacement
    else
        replacement;
    const needs_reindent = tag == .setter or shouldAutoReindentReplacement(tag, final_replacement) or
        ((tag == .function_expr or tag == .arrow_function_expr) and std.mem.indexOfScalar(u8, final_replacement, '\n') != null);
    var plan = rewrite_plan.RewritePlan.init(ctx.allocator);
    defer plan.deinit();
    const end = ctx.ast.nodes.items(.end_offset)[node_i];
    plan.add(.{
        .node_index = node_i,
        .start = getNodeStart(ctx, node),
        .end = end,
        .text = final_replacement,
        .needs_reindent = needs_reindent,
    }) catch return;
    plan.applyToAst(ctx.ast, ctx.allocator) catch return;
    invalidateReplacementSubtreeCache(ctx);
    invalidateRecursiveSourceCache(ctx);
    if (g_replacement_ranges_ast == ctx.ast) {
        updateReplacementRangeCache(ctx, node_i, final_replacement);
    } else {
        g_replacement_ranges_ast = null;
        g_replacement_ranges = .empty;
    }
    if (needs_reindent) {
        markReplacementNeedsReindent(ctx, node_i);
    }
}

fn shouldAutoReindentReplacement(tag: Node.Tag, replacement: []const u8) bool {
    if (std.mem.indexOfScalar(u8, replacement, '\n') == null) return false;
    return switch (tag) {
        .expression_statement,
        .return_statement,
        .throw_statement,
        .if_statement,
        .for_statement,
        .for_in_statement,
        .for_of_statement,
        .for_of_await_statement,
        .while_statement,
        .do_while_statement,
        .switch_statement,
        .try_statement,
        .var_declaration,
        .let_declaration,
        .const_declaration,
        .class_declaration,
        => true,
        else => false,
    };
}

fn startsLikeFunctionExpression(src: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, src, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "function") or std.mem.startsWith(u8, trimmed, "async function");
}

fn needsFunctionExpressionParens(ctx: *TransformContext, node: NodeIndex) bool {
    if (isDirectChildOfParenthesizedExpr(ctx, node)) return true;
    const parent = findParentOf(ctx, node) orelse return false;
    return ctx.nodeTag(parent) == .expression_statement;
}

fn isDirectChildOfParenthesizedExpr(ctx: *TransformContext, node: NodeIndex) bool {
    ensureParenthesizedChildren(ctx);
    const ni = @intFromEnum(node);
    return ni < g_parenthesized_children.len and g_parenthesized_children[ni] != 0;
}

fn findParentOf(ctx: *TransformContext, target: NodeIndex) ?NodeIndex {
    // ensureParentMap is expected to have been called by the caller (or earlier in the pass).
    // We still check g_parent_session for robustness.
    if (g_parent_session) |session| {
        if (session.parentOf(target)) |parent| return parent;
    }
    if (g_node_parents_ready) {
        const target_i = @intFromEnum(target);
        if (target_i >= g_node_parents.len) return null;
        const parent_raw = g_node_parents[target_i];
        if (parent_raw == parent_none) return null;
        return @enumFromInt(parent_raw);
    }

    return findParentOfSlow(ctx, target);
}

/// Returns true if the given node is inside a function or class (i.e., has a capture boundary).
/// This is a small helper to make future migration of parent-walking logic cleaner (symmetric with block_scoping).
fn hasCaptureBoundary(node: NodeIndex) bool {
    if (g_parent_session) |session| {
        return session.captureBoundaryOf(node) != null;
    }
    return false;
}

fn ensureParentMap(ctx: *TransformContext) void {
    if (ctx.session) |session| {
        g_parent_session = session;
        return;
    }
    // Legacy fallback: build our own parent map only if no TransformSession is provided.
    // In normal pipeline runs (needs_scope = true), the shared session is always available.
    const node_count = ctx.ast.nodes.items(.tag).len;
    if (g_node_parents_ready and g_node_parents.len == node_count) return;

    g_node_parents = ctx.allocator.alloc(u32, node_count) catch {
        g_node_parents_ready = false;
        return;
    };
    @memset(g_node_parents, parent_none);

    buildParentMap(ctx, @enumFromInt(0), .none);
    g_node_parents_ready = true;
}

fn buildParentMap(ctx: *TransformContext, node: NodeIndex, parent: ?NodeIndex) void {
    if (node == .none) return;
    const ni = @intFromEnum(node);
    if (ni >= g_node_parents.len) return;
    g_node_parents[ni] = if (parent) |p| @intFromEnum(p) else parent_none;

    const children = visitor.getChildren(ctx.ast, node);
    for (children.items[0..children.len]) |child| {
        buildParentMap(ctx, child, node);
    }
    if (children.range_start < children.range_end) {
        for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
            buildParentMap(ctx, @enumFromInt(raw), node);
        }
    }
    if (children.range2_start < children.range2_end) {
        for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
            buildParentMap(ctx, @enumFromInt(raw), node);
        }
    }
}

fn findParentOfSlow(ctx: *TransformContext, target: NodeIndex) ?NodeIndex {
    const target_i = @intFromEnum(target);
    const tags = ctx.ast.nodes.items(.tag);
    const datas = ctx.ast.nodes.items(.data);

    for (tags, 0..) |tag, ni| {
        const data = datas[ni];
        switch (tag) {
            .member_expr, .optional_chain_expr => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
            },
            .computed_member_expr,
            .optional_computed_member_expr,
            .binary_expr,
            .logical_expr,
            .assignment_expr,
            .conditional_expr,
            .ts_as_expression,
            .ts_satisfies_expression,
            .assignment_pattern,
            => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
                if (@intFromEnum(data.binary.rhs) == target_i) return @enumFromInt(ni);
            },
            .unary_expr,
            .update_expr,
            .parenthesized_expr,
            .ts_non_null_expression,
            .expression_statement,
            .return_statement,
            .throw_statement,
            .spread_element,
            .yield_expr,
            .await_expr,
            => {
                if (@intFromEnum(data.unary) == target_i) return @enumFromInt(ni);
            },
            .declarator => {
                if (@intFromEnum(data.binary.lhs) == target_i) return @enumFromInt(ni);
                if (@intFromEnum(data.binary.rhs) == target_i) return @enumFromInt(ni);
            },
            .call_expr, .optional_call_expr, .new_expr => {
                const eidx = @intFromEnum(data.extra);
                if (eidx < ctx.ast.extra_data.items.len and ctx.ast.extra_data.items[eidx] == target_i) {
                    return @enumFromInt(ni);
                }
                if (eidx + 2 < ctx.ast.extra_data.items.len) {
                    const args_start = ctx.ast.extra_data.items[eidx + 1];
                    const args_end = ctx.ast.extra_data.items[eidx + 2];
                    if (args_end > args_start and args_end <= ctx.ast.extra_data.items.len) {
                        for (ctx.ast.extra_data.items[args_start..args_end]) |arg_raw| {
                            if (arg_raw == target_i) return @enumFromInt(ni);
                        }
                    }
                }
            },
            .if_statement => {
                const eidx = @intFromEnum(data.extra);
                if (eidx + 2 < ctx.ast.extra_data.items.len) {
                    for (0..3) |offset| {
                        if (ctx.ast.extra_data.items[eidx + offset] == target_i) return @enumFromInt(ni);
                    }
                }
            },
            else => {},
        }

        const children = visitor.getChildren(ctx.ast, @enumFromInt(ni));
        for (children.items[0..children.len]) |child| {
            if (child == target) return @enumFromInt(ni);
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                if (raw == target_i) return @enumFromInt(ni);
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                if (raw == target_i) return @enumFromInt(ni);
            }
        }
    }
    return null;
}

fn findEnclosingHoistBody(ctx: *TransformContext, func_node: NodeIndex) NodeIndex {
    if (ctx.scope) |scope_result| {
        var scope_idx = scope_mod.getScopeForNode(scope_result, func_node);
        if (scope_idx) |current_scope_idx| {
            const current_scope = scope_result.scopes[@intFromEnum(current_scope_idx)];
            if ((current_scope.kind == .function or current_scope.kind == .arrow) and current_scope.node == func_node) {
                scope_idx = current_scope.parent;
            }
        }
        while (scope_idx) |current_scope_idx| {
            const scope = scope_result.scopes[@intFromEnum(current_scope_idx)];
            switch (scope.kind) {
                .function, .arrow => {
                    if (getFunctionBody(ctx, scope.node)) |body| return body;
                },
                .global, .module => break,
                else => {},
            }
            scope_idx = scope.parent;
        }
        return @enumFromInt(0);
    }

    const target_start = getNodeStart(ctx, func_node);
    const target_end = ctx.ast.nodes.items(.end_offset)[@intFromEnum(func_node)];
    const tags = ctx.ast.nodes.items(.tag);

    var best_body: NodeIndex = .none;
    var best_range: u64 = std.math.maxInt(u64);

    for (tags, 0..) |tag, ni| {
        const is_func = switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .method_definition,
            .class_method,
            .class_private_method,
            => true,
            else => false,
        };
        if (!is_func or ni == @intFromEnum(func_node)) continue;

        const func_start = getNodeStart(ctx, @enumFromInt(ni));
        const func_end = ctx.ast.nodes.items(.end_offset)[ni];
        if (func_start > target_start or func_end < target_end) continue;

        const range: u64 = @as(u64, func_end) - @as(u64, func_start);
        if (range < best_range) {
            if (getFunctionBody(ctx, @enumFromInt(ni))) |body| {
                best_range = range;
                best_body = body;
            }
        }
    }

    return if (best_body != .none) best_body else @enumFromInt(0);
}

fn ensureParenthesizedChildren(ctx: *TransformContext) void {
    if (g_parenthesized_child_ast == ctx.ast) return;
    g_parenthesized_child_ast = ctx.ast;
    g_parenthesized_children = ctx.allocator.alloc(u8, ctx.ast.nodes.items(.tag).len) catch &[_]u8{};
    @memset(g_parenthesized_children, 0);

    const tags = ctx.ast.nodes.items(.tag);
    const data = ctx.ast.nodes.items(.data);
    for (tags, 0..) |tag, ni| {
        if (tag != .parenthesized_expr) continue;
        const child = data[ni].unary;
        const child_i = @intFromEnum(child);
        if (child_i < g_parenthesized_children.len) g_parenthesized_children[child_i] = 1;
    }
}

fn ensureClassFieldValueIndex(ctx: *TransformContext) void {
    if (g_class_field_value_ast == ctx.ast) return;
    g_class_field_value_ast = ctx.ast;
    g_class_field_values = ctx.allocator.alloc(u8, ctx.ast.nodes.items(.tag).len) catch &[_]u8{};
    @memset(g_class_field_values, 0);

    const tags = ctx.ast.nodes.items(.tag);
    const data = ctx.ast.nodes.items(.data);
    for (tags, 0..) |tag, ni| {
        switch (tag) {
            .class_field, .class_private_field => {
                const eidx = @intFromEnum(data[ni].extra);
                if (eidx + 1 >= ctx.ast.extra_data.items.len) continue;
                markClassFieldSubtree(ctx, @enumFromInt(ctx.ast.extra_data.items[eidx + 1]));
            },
            else => {},
        }
    }
}

fn markClassFieldSubtree(ctx: *TransformContext, root: NodeIndex) void {
    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(ctx.allocator);
    stack.append(ctx.allocator, root) catch return;

    while (stack.items.len > 0) {
        const node = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (node == .none) continue;

        const ni = @intFromEnum(node);
        if (ni >= g_class_field_values.len) continue;
        if (g_class_field_values[ni] != 0) continue;
        g_class_field_values[ni] = 1;

        const tag = ctx.nodeTag(node);
        switch (tag) {
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .method_definition,
            .computed_method,
            .class_method,
            .class_private_method,
            .getter,
            .setter,
            .class_declaration,
            .class_expr,
            .class_body,
            => continue,
            else => {},
        }

        const children = visitor.getChildren(ctx.ast, node);
        var child_i: u8 = 0;
        while (child_i < children.len) : (child_i += 1) {
            stack.append(ctx.allocator, children.items[child_i]) catch return;
        }
        if (children.range_end > children.range_start) {
            for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return;
            }
        }
        if (children.range2_end > children.range2_start) {
            for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                stack.append(ctx.allocator, @enumFromInt(raw)) catch return;
            }
        }
    }
}

fn getFunctionBody(ctx: *TransformContext, func_node: NodeIndex) ?NodeIndex {
    const ni = @intFromEnum(func_node);
    const tag = ctx.ast.nodes.items(.tag)[ni];
    const d = ctx.ast.nodes.items(.data)[ni];
    switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        => {
            const eidx = @intFromEnum(d.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
            }
        },
        .method_definition, .class_method, .class_private_method => {
            const eidx = @intFromEnum(d.extra);
            if (eidx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[eidx + 3]);
            }
        },
        else => {},
    }
    return null;
}

fn findEnclosingArrowBlockBody(ctx: *TransformContext, node: NodeIndex) ?NodeIndex {
    var current = findParentOf(ctx, node) orelse return null;
    while (true) {
        if (ctx.nodeTag(current) == .arrow_function_expr) {
            const data = ctx.nodeData(current);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 < ctx.ast.extra_data.items.len) {
                const first = ctx.ast.extra_data.items[extra_idx];
                const second = ctx.ast.extra_data.items[extra_idx + 1];
                const third = ctx.ast.extra_data.items[extra_idx + 2];
                const body_node: NodeIndex = if (first == @intFromEnum(NodeIndex.none) or third == 1)
                    @enumFromInt(second)
                else
                    @enumFromInt(third);
                if (body_node != .none and ctx.nodeTag(body_node) == .block_statement) return body_node;
            }
        }
        current = findParentOf(ctx, current) orelse return null;
    }
}

fn isDescendantOf(node: NodeIndex, ancestor: NodeIndex, ctx: *TransformContext) bool {
    if (node == .none or ancestor == .none) return false;
    if (node == ancestor) return true;

    var current = findParentOf(ctx, node) orelse return false;
    while (true) {
        if (current == ancestor) return true;
        current = findParentOf(ctx, current) orelse return false;
    }
}

fn appendPrefixToBody(ctx: *TransformContext, body: NodeIndex, prefix: []const u8) void {
    if (prefix.len == 0 or body == .none) return;
    const body_i = @intFromEnum(body);
    const tag = ctx.nodeTag(body);
    if (tag != .block_statement and tag != .program) return;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (ctx.ast.block_prefix_source.get(body_i)) |existing| {
        if (std.mem.indexOf(u8, existing, prefix) != null) return;
        buf.appendSlice(ctx.allocator, existing) catch return;
        if (existing.len > 0 and existing[existing.len - 1] != '\n') {
            buf.append(ctx.allocator, '\n') catch return;
        }
    }
    buf.appendSlice(ctx.allocator, prefix) catch return;
    ctx.ast.block_prefix_source.put(ctx.allocator, body_i, buf.items) catch return;
}

// ── Utility helpers ───────────────────────────────────────────────

var g_ref_counter: u32 = 0;

fn allocRef(ctx: *TransformContext) []const u8 {
    g_ref_counter += 1;
    if (g_ref_counter == 1) return "_ref";
    return std.fmt.allocPrint(ctx.allocator, "_ref{d}", .{g_ref_counter}) catch "_ref";
}

fn allocRefName(ctx: *TransformContext, base: []const u8, prop: []const u8) []const u8 {
    const prop_part = if (prop.len > 2 and std.mem.endsWith(u8, prop, "es")) prop[0 .. prop.len - 2] else prop;
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    if (base.len == 0 or base[0] != '_') {
        name_buf.append(ctx.allocator, '_') catch return allocRef(ctx);
    }
    for (base) |c| {
        if (c == '.' or c == '[' or c == ']') {
            name_buf.append(ctx.allocator, '$') catch return allocRef(ctx);
        } else if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or (c >= '0' and c <= '9')) {
            name_buf.append(ctx.allocator, c) catch return allocRef(ctx);
        }
    }
    name_buf.append(ctx.allocator, '$') catch return allocRef(ctx);
    name_buf.appendSlice(ctx.allocator, prop_part) catch return allocRef(ctx);
    if (!g_used_names.contains(name_buf.items)) {
        g_used_names.put(ctx.allocator, name_buf.items, {}) catch return name_buf.items;
        return name_buf.items;
    }
    var counter: u32 = 2;
    while (counter < 100) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ name_buf.items, counter }) catch return allocRef(ctx);
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch return candidate;
            return candidate;
        }
    }
    return name_buf.items;
}

fn allocNextRefName(ctx: *TransformContext, base: []const u8) []const u8 {
    if (!g_used_names.contains(base)) {
        g_used_names.put(ctx.allocator, base, {}) catch {};
        return base;
    }
    var counter: u32 = 2;
    while (counter < 100) : (counter += 1) {
        const candidate = std.fmt.allocPrint(ctx.allocator, "{s}{d}", .{ base, counter }) catch return allocRef(ctx);
        if (!g_used_names.contains(candidate)) {
            g_used_names.put(ctx.allocator, candidate, {}) catch {};
            return candidate;
        }
    }
    return allocRef(ctx);
}

fn uintToStr(ctx: *TransformContext, n: u32) []const u8 {
    return std.fmt.allocPrint(ctx.allocator, "{d}", .{n}) catch "0";
}

fn numSuffix(ctx: *TransformContext, n: u32) []const u8 {
    const suffix_n = if (n >= 12)
        n - 2
    else if (n >= 10)
        n - 10
    else if (n >= 2)
        n
    else
        0;
    return std.fmt.allocPrint(ctx.allocator, "{d}", .{suffix_n}) catch "";
}

// ── Source text helpers ──────────────────────────────────────────────

fn getNodeSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (node == .none) return "";
    const ni = @intFromEnum(node);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;
    const start = getNodeStart(ctx, node);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return ctx.ast.source[start..end];
}

fn getDefaultValueSource(ctx: *TransformContext, node: NodeIndex) []const u8 {
    if (ctx.nodeTag(node) != .arrow_function_expr) {
        return getGeneratedSource(ctx, node);
    }

    const src = getNodeSource(ctx, node);

    const type_params = ctx.ast.type_parameters.get(@intFromEnum(node)) orelse return src;
    if (ctx.nodeTag(type_params) != .ts_type_parameter_declaration) return src;

    const data = ctx.nodeData(type_params);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return src;

    const range_start = ctx.ast.extra_data.items[extra_idx];
    const range_end = ctx.ast.extra_data.items[extra_idx + 1];
    if (range_end - range_start != 1) return src;

    const gt_idx = std.mem.indexOfScalar(u8, src, '>') orelse return src;
    if (gt_idx > 0 and src[gt_idx - 1] == ',') return src;

    return std.fmt.allocPrint(ctx.allocator, "{s},{s}", .{ src[0..gt_idx], src[gt_idx..] }) catch src;
}

fn getNodeStart(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    if (ctx.ast.node_start_overrides.get(ni)) |override| return override;

    const tag = ctx.ast.nodes.items(.tag)[ni];
    const d = ctx.ast.nodes.items(.data)[ni];

    switch (tag) {
        .call_expr, .optional_call_expr => {
            const eidx = @intFromEnum(d.extra);
            if (eidx < ctx.ast.extra_data.items.len) {
                const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[eidx]);
                return getNodeStart(ctx, callee);
            }
        },
        .member_expr,
        .computed_member_expr,
        .optional_chain_expr,
        .optional_computed_member_expr,
        => return getNodeStart(ctx, d.binary.lhs),
        .binary_expr, .logical_expr, .assignment_expr => return getNodeStart(ctx, d.binary.lhs),
        .conditional_expr => return getNodeStart(ctx, d.binary.lhs),
        .ts_as_expression, .ts_satisfies_expression => return getNodeStart(ctx, d.binary.lhs),
        .ts_non_null_expression => return getNodeStart(ctx, d.unary),
        else => {},
    }

    const mt_idx = ctx.ast.nodes.items(.main_token)[ni];
    return ctx.ast.tokens.items(.start)[@intFromEnum(mt_idx)];
}
