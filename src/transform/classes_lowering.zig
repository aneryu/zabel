const std = @import("std");
const ast_mod = @import("../ast.zig");
const Codegen = @import("../codegen.zig").Codegen;
const pipeline = @import("pipeline.zig");
const visitor = @import("visitor.zig");

const ExtraRange = ast_mod.ExtraRange;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const TokenIndex = ast_mod.TokenIndex;
const TransformContext = pipeline.TransformContext;

pub const OutputMode = enum {
    runtime_lowered,
    preserve_class_surface,
};

pub const Capability = struct {
    mode: OutputMode = .preserve_class_surface,
    public_fields: bool = false,
    private_methods: bool = false,
    legacy_decorators: bool = false,
};

pub const FieldInfo = struct {
    node: NodeIndex,
    key: NodeIndex,
    value: NodeIndex,
    is_static: bool,
    is_private: bool,
    decorator_range: ?ExtraRange = null,
};

pub const MethodInfo = struct {
    node: NodeIndex,
    key: NodeIndex,
    body: NodeIndex,
    is_static: bool,
    is_private: bool,
    is_computed: bool = false,
    is_generator: bool = false,
    is_async: bool = false,
    is_getter: bool = false,
    is_setter: bool = false,
    decorator_range: ?ExtraRange = null,
};

pub const ClassInfo = struct {
    class_node: NodeIndex,
    name: ?TokenIndex = null,
    super_class: NodeIndex,
    body: NodeIndex,
    ctor: ?MethodInfo = null,
    instance_fields: std.ArrayListUnmanaged(FieldInfo) = .empty,
    static_fields: std.ArrayListUnmanaged(FieldInfo) = .empty,
    methods: std.ArrayListUnmanaged(MethodInfo) = .empty,
    private_methods: std.ArrayListUnmanaged(MethodInfo) = .empty,
    decorator_range: ?ExtraRange = null,
};

pub const LoweredClass = struct {
    prelude: []const u8 = "",
    replacement: []const u8,
};

pub fn findPreludeTarget(ctx: *TransformContext, node: NodeIndex) NodeIndex {
    var current = node;
    while (findParentOf(ctx, current)) |parent| {
        switch (ctx.nodeTag(parent)) {
            .program,
            .block_statement,
            .arrow_function_expr,
            => return parent,
            .function_declaration,
            .async_function_declaration,
            .generator_declaration,
            .async_generator_declaration,
            .function_expr,
            .method_definition,
            .class_method,
            .class_private_method,
            .getter,
            .setter,
            => return getFunctionBody(ctx, parent) orelse @enumFromInt(0),
            else => current = parent,
        }
    }
    return @enumFromInt(0);
}

pub fn lowerClass(ctx: *TransformContext, idx: NodeIndex, capability: Capability) ?LoweredClass {
    var info = collectClassInfo(ctx, idx) orelse return null;
    defer info.instance_fields.deinit(ctx.allocator);
    defer info.static_fields.deinit(ctx.allocator);
    defer info.methods.deinit(ctx.allocator);
    defer info.private_methods.deinit(ctx.allocator);

    return switch (capability.mode) {
        .runtime_lowered => renderRuntimeLoweredClass(ctx, &info, capability),
        .preserve_class_surface => renderSurfaceClass(ctx, &info, capability),
    };
}

pub fn collectClassInfo(ctx: *TransformContext, idx: NodeIndex) ?ClassInfo {
    const tag = ctx.nodeTag(idx);
    if (tag != .class_declaration and tag != .class_expr) return null;

    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return null;

    var info = ClassInfo{
        .class_node = idx,
        .name = if (ctx.ast.extra_data.items[extra_idx] == 0) null else @enumFromInt(ctx.ast.extra_data.items[extra_idx]),
        .super_class = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]),
        .body = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]),
        .decorator_range = ctx.ast.decorators_map.get(@intFromEnum(idx)),
    };
    collectClassMembers(ctx, &info);
    return info;
}

fn collectClassMembers(ctx: *TransformContext, info: *ClassInfo) void {
    if (info.body == .none or ctx.nodeTag(info.body) != .class_body) return;

    const body_data = ctx.nodeData(info.body);
    const body_extra = @intFromEnum(body_data.extra);
    if (body_extra + 1 >= ctx.ast.extra_data.items.len) return;

    const range_start: usize = @intCast(ctx.ast.extra_data.items[body_extra]);
    const range_end: usize = @intCast(ctx.ast.extra_data.items[body_extra + 1]);
    if (range_start > range_end or range_end > ctx.ast.extra_data.items.len) return;

    for (ctx.ast.extra_data.items[range_start..range_end]) |member_raw| {
        const member: NodeIndex = @enumFromInt(member_raw);
        switch (ctx.nodeTag(member)) {
            .class_method, .method_definition, .getter, .setter => collectMethod(ctx, info, member),
            .class_private_method => collectPrivateMethod(ctx, info, member),
            .class_field, .class_private_field => collectField(ctx, info, member),
            else => {},
        }
    }
}

fn collectMethod(ctx: *TransformContext, info: *ClassInfo, member: NodeIndex) void {
    const data = ctx.nodeData(member);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 4 >= ctx.ast.extra_data.items.len) return;

    const method = MethodInfo{
        .node = member,
        .key = @enumFromInt(ctx.ast.extra_data.items[extra_idx]),
        .body = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]),
        .is_static = (ctx.ast.extra_data.items[extra_idx + 4] & 1) != 0,
        .is_private = false,
        .is_computed = (ctx.ast.extra_data.items[extra_idx + 4] & 2) != 0,
        .is_generator = (ctx.ast.extra_data.items[extra_idx + 4] & 4) != 0,
        .is_async = (ctx.ast.extra_data.items[extra_idx + 4] & 8) != 0,
        .is_getter = ctx.nodeTag(member) == .getter,
        .is_setter = ctx.nodeTag(member) == .setter,
        .decorator_range = ctx.ast.decorators_map.get(@intFromEnum(member)),
    };

    if (!method.is_static and !method.is_getter and !method.is_setter and method.key != .none and ctx.nodeTag(method.key) == .identifier and std.mem.eql(u8, ctx.tokenSlice(ctx.mainToken(method.key)), "constructor")) {
        info.ctor = method;
        return;
    }

    info.methods.append(ctx.allocator, method) catch return;
}

fn collectPrivateMethod(ctx: *TransformContext, info: *ClassInfo, member: NodeIndex) void {
    const data = ctx.nodeData(member);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 4 >= ctx.ast.extra_data.items.len) return;

    info.private_methods.append(ctx.allocator, .{
        .node = member,
        .key = @enumFromInt(ctx.ast.extra_data.items[extra_idx]),
        .body = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]),
        .is_static = (ctx.ast.extra_data.items[extra_idx + 4] & 1) != 0,
        .is_private = true,
        .is_computed = (ctx.ast.extra_data.items[extra_idx + 4] & 2) != 0,
        .is_generator = (ctx.ast.extra_data.items[extra_idx + 4] & 4) != 0,
        .is_async = (ctx.ast.extra_data.items[extra_idx + 4] & 8) != 0,
        .decorator_range = ctx.ast.decorators_map.get(@intFromEnum(member)),
    }) catch return;
}

fn collectField(ctx: *TransformContext, info: *ClassInfo, member: NodeIndex) void {
    const data = ctx.nodeData(member);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;

    const field = FieldInfo{
        .node = member,
        .key = @enumFromInt(ctx.ast.extra_data.items[extra_idx]),
        .value = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]),
        .is_static = (ctx.ast.extra_data.items[extra_idx + 2] & 1) != 0,
        .is_private = ctx.nodeTag(member) == .class_private_field,
        .decorator_range = ctx.ast.decorators_map.get(@intFromEnum(member)),
    };

    if (field.is_static) {
        info.static_fields.append(ctx.allocator, field) catch return;
    } else {
        info.instance_fields.append(ctx.allocator, field) catch return;
    }
}

fn renderRuntimeLoweredClass(ctx: *TransformContext, info: *ClassInfo, capability: Capability) ?LoweredClass {
    if (ctx.nodeTag(info.class_node) == .class_expr) {
        return renderRuntimeLoweredClassExpr(ctx, info, capability);
    }
    if (ctx.nodeTag(info.class_node) != .class_declaration) return null;

    const class_name = getClassNameSource(ctx, info);
    if (class_name.len == 0 or std.mem.eql(u8, class_name, "_Class")) return null;
    const base_field_init_block = if (capability.public_fields)
        (renderInstanceFieldInitializersForReceiver(ctx, info, "this") catch return null)
    else
        "";
    const derived_field_init_block = if (capability.public_fields and info.super_class != .none)
        (renderInstanceFieldInitializersForReceiver(ctx, info, "_this") catch return null)
    else
        "";

    if (info.super_class != .none) {
        const super_src = renderExpr(ctx, info.super_class) catch return null;
        const super_alias = renderSuperAlias(ctx, info.super_class) catch return null;
        const ctor_src = renderDerivedConstructor(ctx, info, class_name, derived_field_init_block) catch return null;
        const create_class_call = renderCreateClassCall(ctx, info, class_name) catch return null;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(ctx.allocator, "let ") catch return null;
        buf.appendSlice(ctx.allocator, class_name) catch return null;
        buf.appendSlice(ctx.allocator, " = /*#__PURE__*/function (") catch return null;
        buf.appendSlice(ctx.allocator, super_alias) catch return null;
        buf.appendSlice(ctx.allocator, ") {\n") catch return null;
        if (shouldEmitWrapperStrict(ctx)) {
            buf.appendSlice(ctx.allocator, "  \"use strict\";\n\n") catch return null;
        }
        buf.appendSlice(ctx.allocator, "  function ") catch return null;
        buf.appendSlice(ctx.allocator, class_name) catch return null;
        buf.appendSlice(ctx.allocator, ctor_src) catch return null;
        buf.appendSlice(ctx.allocator, "\n  babelHelpers.inherits(") catch return null;
        buf.appendSlice(ctx.allocator, class_name) catch return null;
        buf.appendSlice(ctx.allocator, ", ") catch return null;
        buf.appendSlice(ctx.allocator, super_alias) catch return null;
        buf.appendSlice(ctx.allocator, ");\n  return ") catch return null;
        buf.appendSlice(ctx.allocator, create_class_call) catch return null;
        buf.appendSlice(ctx.allocator, ";\n}(") catch return null;
        buf.appendSlice(ctx.allocator, super_src) catch return null;
        buf.appendSlice(ctx.allocator, ");") catch return null;
        return .{ .replacement = buf.items };
    }

    if (shouldUseBaseIife(ctx, info)) {
        const ctor_src = renderBaseConstructor(ctx, info, class_name, false, "    ", "  ", base_field_init_block) catch return null;
        const create_class_call = renderCreateClassCall(ctx, info, class_name) catch return null;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        buf.appendSlice(ctx.allocator, "var ") catch return null;
        buf.appendSlice(ctx.allocator, class_name) catch return null;
        buf.appendSlice(ctx.allocator, " = /*#__PURE__*/function () {\n") catch return null;
        if (shouldEmitWrapperStrict(ctx)) {
            buf.appendSlice(ctx.allocator, "  \"use strict\";\n\n") catch return null;
        }
        buf.appendSlice(ctx.allocator, "  function ") catch return null;
        buf.appendSlice(ctx.allocator, class_name) catch return null;
        buf.appendSlice(ctx.allocator, ctor_src) catch return null;
        buf.appendSlice(ctx.allocator, "\n  return ") catch return null;
        buf.appendSlice(ctx.allocator, create_class_call) catch return null;
        buf.appendSlice(ctx.allocator, ";\n}();") catch return null;
        return .{ .replacement = buf.items };
    }

    const ctor_src = renderBaseConstructor(ctx, info, class_name, shouldEmitWrapperStrict(ctx), "  ", "", base_field_init_block) catch return null;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "let ") catch return null;
    buf.appendSlice(ctx.allocator, class_name) catch return null;
    buf.appendSlice(ctx.allocator, " = /*#__PURE__*/babelHelpers.createClass(function ") catch return null;
    buf.appendSlice(ctx.allocator, class_name) catch return null;
    buf.appendSlice(ctx.allocator, ctor_src) catch return null;
    buf.appendSlice(ctx.allocator, ");") catch return null;
    return .{ .replacement = buf.items };
}

fn renderRuntimeLoweredClassExpr(ctx: *TransformContext, info: *ClassInfo, capability: Capability) ?LoweredClass {
    if (info.super_class != .none) return null;
    if (info.decorator_range != null) return null;
    if (info.private_methods.items.len != 0 and !capability.private_methods) return null;
    if (!capability.public_fields and (info.instance_fields.items.len != 0 or info.static_fields.items.len != 0)) return null;

    const class_name = getClassNameSource(ctx, info);
    if (!std.mem.eql(u8, class_name, "_Class")) return null;

    for (info.instance_fields.items) |field| {
        if (field.is_static or field.is_private or field.decorator_range != null) return null;
    }
    for (info.static_fields.items) |field| {
        if (!field.is_static or field.is_private or field.decorator_range != null) return null;
    }

    const field_init_block = if (capability.public_fields)
        (renderLooseInstanceFieldAssignmentsForReceiver(ctx, info, "this") catch return null)
    else
        "";
    const static_assignments = if (capability.public_fields)
        (renderStaticFieldAssignmentSequence(ctx, info, class_name) catch return null)
    else
        "";
    const ctor_src = renderBaseConstructor(ctx, info, class_name, shouldEmitWrapperStrict(ctx), "  ", "", field_init_block) catch return null;
    const create_class_call = std.fmt.allocPrint(
        ctx.allocator,
        "/*#__PURE__*/babelHelpers.createClass(function {s}{s})",
        .{ class_name, ctor_src },
    ) catch return null;

    const replacement = if (static_assignments.len != 0)
        wrapSequenceExprIfNeeded(
            ctx,
            info.class_node,
            std.fmt.allocPrint(
                ctx.allocator,
                "{s} = {s}, {s}, {s}",
                .{ class_name, create_class_call, static_assignments, class_name },
            ) catch return null,
        )
    else
        create_class_call;

    return .{
        .prelude = if (static_assignments.len != 0) "var _Class;" else "",
        .replacement = replacement,
    };
}

fn renderSurfaceClass(ctx: *TransformContext, info: *ClassInfo, capability: Capability) ?LoweredClass {
    if (capability.legacy_decorators) {
        if (renderDecoratedSurfaceClass(ctx, info, capability)) |decorated| return decorated;
    }

    const has_public_fields = capability.public_fields and info.instance_fields.items.len != 0;
    const has_private_methods = capability.private_methods and info.private_methods.items.len != 0;
    if (!has_public_fields and !has_private_methods) return null;
    if (info.super_class != .none) return null;

    const class_start = nodeStartOffset(ctx, info.class_node);
    const body_start = nodeStartOffset(ctx, info.body);
    if (class_start >= body_start) return null;

    const header = buildEffectiveSource(ctx, class_start, body_start);
    const init_block = renderSurfaceInitBlock(ctx, info, capability) catch return null;
    if (!has_private_methods and std.mem.trim(u8, init_block, " \t\r\n").len == 0) return null;

    const body_data = ctx.nodeData(info.body);
    const body_extra = @intFromEnum(body_data.extra);
    if (body_extra + 1 >= ctx.ast.extra_data.items.len) return null;
    const member_start: usize = @intCast(ctx.ast.extra_data.items[body_extra]);
    const member_end: usize = @intCast(ctx.ast.extra_data.items[body_extra + 1]);
    if (member_start > member_end or member_end > ctx.ast.extra_data.items.len) return null;

    var members: std.ArrayListUnmanaged([]const u8) = .empty;
    defer members.deinit(ctx.allocator);
    var ctor_emitted = false;

    for (ctx.ast.extra_data.items[member_start..member_end]) |member_raw| {
        const member: NodeIndex = @enumFromInt(member_raw);
        if (member == .none) continue;
        const tag = ctx.nodeTag(member);
        if (capability.private_methods and isPrivateTsSignatureSource(getNodeSource(ctx, member))) continue;

        switch (tag) {
            .class_field => {
                const field = collectFieldInfo(ctx, member) orelse return null;
                if (!field.is_static and !field.is_private and field.decorator_range == null) continue;
            },
            .class_private_field => return null,
            .class_private_method => {
                if (capability.private_methods) continue;
                return null;
            },
            .ts_declare_method, .ts_method_signature => {
                if (capability.private_methods) continue;
            },
            .class_method, .method_definition, .getter, .setter => {
                if (isConstructorMember(ctx, member)) {
                    const ctor_source = renderSurfaceConstructor(ctx, info, member, init_block) catch return null;
                    members.append(ctx.allocator, ctor_source) catch return null;
                    ctor_emitted = true;
                    continue;
                }
            },
            else => {},
        }

        members.append(ctx.allocator, getNodeSource(ctx, member)) catch return null;
    }

    if (!ctor_emitted and std.mem.trim(u8, init_block, " \t\r\n").len != 0) {
        const ctor_source = renderSyntheticSurfaceConstructor(ctx, init_block) catch return null;
        members.insert(ctx.allocator, 0, ctor_source) catch return null;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, header) catch return null;
    buf.appendSlice(ctx.allocator, "{\n") catch return null;
    for (members.items, 0..) |member_source, i| {
        if (i > 0) buf.append(ctx.allocator, '\n') catch return null;
        appendIndentedBody(ctx, &buf, member_source, "  ") catch return null;
    }
    buf.appendSlice(ctx.allocator, "\n}") catch return null;
    const private_functions = if (has_private_methods)
        (renderPrivateMethodFunctions(ctx, info) catch return null)
    else
        "";
    const replacement = if (std.mem.trim(u8, private_functions, " \t\r\n").len != 0)
        std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ buf.items, private_functions }) catch return null
    else
        buf.items;
    return .{
        .prelude = if (has_private_methods) (renderPrivateMethodPrelude(ctx, info) catch return null) else "",
        .replacement = replacement,
    };
}

fn renderDecoratedSurfaceClass(ctx: *TransformContext, info: *ClassInfo, capability: Capability) ?LoweredClass {
    if (capability.public_fields) {
        if (renderDecoratedPublicFieldSurfaceClass(ctx, info)) |decorated| return decorated;
    }
    return renderSimpleLegacyDecoratedSurfaceClass(ctx, info);
}

fn renderDecoratedPublicFieldSurfaceClass(ctx: *TransformContext, info: *ClassInfo) ?LoweredClass {
    if (info.super_class != .none) return null;
    if (ctx.nodeTag(info.class_node) != .class_declaration) return null;
    if (info.instance_fields.items.len != 1) return null;
    if (info.static_fields.items.len != 0) return null;
    if (info.private_methods.items.len != 0) return null;
    if (info.methods.items.len != 0) return null;

    const field = info.instance_fields.items[0];
    const decorators = field.decorator_range orelse return null;
    if (field.is_static or field.is_private or field.value != .none) return null;

    const class_name = getClassNameSource(ctx, info);
    if (class_name.len == 0 or std.mem.eql(u8, class_name, "_Class")) return null;

    const key_src = renderFieldKey(ctx, field.key) catch return null;
    const decorator_list = renderDecoratorExprList(ctx, decorators) catch return null;

    const replacement = std.fmt.allocPrint(
        ctx.allocator,
        "let {s} = (_class = class {s} {{\n  constructor() {{\n    babelHelpers.initializerDefineProperty(this, {s}, _descriptor, this);\n  }}\n}}, _descriptor = babelHelpers.applyDecoratedDescriptor(_class.prototype, {s}, [{s}], {{\n  configurable: true,\n  enumerable: true,\n  writable: true,\n  initializer: null\n}}), _class);",
        .{ class_name, class_name, key_src, key_src, decorator_list },
    ) catch return null;

    return .{
        .prelude = "var _class, _descriptor;",
        .replacement = replacement,
    };
}

fn renderSimpleLegacyDecoratedSurfaceClass(ctx: *TransformContext, info: *ClassInfo) ?LoweredClass {
    if (info.super_class != .none) return null;
    if (ctx.nodeTag(info.class_node) != .class_declaration) return null;
    if (info.private_methods.items.len != 0) return null;
    if (info.static_fields.items.len != 0) return null;

    const class_name = getClassNameSource(ctx, info);
    if (class_name.len == 0 or std.mem.eql(u8, class_name, "_Class")) return null;

    if (info.decorator_range) |decorators| {
        if (info.instance_fields.items.len != 0 or info.methods.items.len != 0) return null;
        const decorator_expr = renderSingleDecoratorExpr(ctx, decorators) catch return null;
        if (info.ctor == null) {
            const replacement = std.fmt.allocPrint(
                ctx.allocator,
                "let {s} = {s}(_class = class {s} {{}}) || _class;",
                .{ class_name, decorator_expr, class_name },
            ) catch return null;
            return .{
                .prelude = "var _class;",
                .replacement = replacement,
            };
        }
        // Decorated class with constructor body — use _dec pattern
        const body_src = getNodeSource(ctx, info.body);
        if (body_src.len == 0) return null;
        const replacement = std.fmt.allocPrint(
            ctx.allocator,
            "let {s} = (_dec = {s}, _dec(_class = class {s} {s}) || _class);",
            .{ class_name, decorator_expr, class_name, body_src },
        ) catch return null;
        return .{
            .prelude = "var _dec, _class;",
            .replacement = replacement,
        };
    }

    if (info.ctor == null and info.instance_fields.items.len == 0 and info.methods.items.len == 1) {
        const method = info.methods.items[0];
        const method_source = getNodeSource(ctx, method.node);
        const method_src = renderSurfaceMethodWithoutDecorators(ctx, method) catch return null;
        const key_src = renderQuotedMemberKeyFromSurfaceSource(ctx, method_src) catch return null;
        const decorator_list = if (method.decorator_range) |decorators|
            (renderDecoratorExprList(ctx, decorators) catch return null)
        else
            (extractDecoratorExprListFromSource(ctx, method_source) catch return null);
        const replacement = std.fmt.allocPrint(
            ctx.allocator,
            "let {s} = (_class = class {s} {{\n  {s}\n}}, babelHelpers.applyDecoratedDescriptor(_class.prototype, {s}, [{s}], Object.getOwnPropertyDescriptor(_class.prototype, {s}), _class.prototype), _class);",
            .{ class_name, class_name, method_src, key_src, decorator_list, key_src },
        ) catch return null;
        return .{
            .prelude = "var _class;",
            .replacement = replacement,
        };
    }

    if (info.ctor == null and info.instance_fields.items.len == 1 and info.methods.items.len == 0) {
        const field = info.instance_fields.items[0];
        const decorators = field.decorator_range orelse return null;
        if (field.is_static or field.is_private or field.value == .none) return null;

        const field_src = renderDecoratedFieldWarningSurface(ctx, field, "_descriptor") catch return null;
        const descriptor_initializer = renderDecoratedFieldInitializer(ctx, field.value) catch return null;
        const key_src = renderFieldKey(ctx, field.key) catch return null;
        const decorator_list = renderDecoratorExprList(ctx, decorators) catch return null;
        const replacement = std.fmt.allocPrint(
            ctx.allocator,
            "let {s} = (_class = class {s} {{\n  {s}\n}}, _descriptor = babelHelpers.applyDecoratedDescriptor(_class.prototype, {s}, [{s}], {{\n  configurable: true,\n  enumerable: true,\n  writable: true,\n  initializer: function () {{\n    return {s};\n  }}\n}}), _class);",
            .{ class_name, class_name, field_src, key_src, decorator_list, descriptor_initializer },
        ) catch return null;
        return .{
            .prelude = "var _class, _descriptor;",
            .replacement = replacement,
        };
    }

    return null;
}

fn isPrivateTsSignatureSource(source: []const u8) bool {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "#") and
        std.mem.indexOfScalar(u8, trimmed, '(') != null and
        std.mem.endsWith(u8, trimmed, ";");
}

fn getFunctionBody(ctx: *TransformContext, func_node: NodeIndex) ?NodeIndex {
    const ni = @intFromEnum(func_node);
    const tag = ctx.ast.nodes.items(.tag)[ni];
    const data = ctx.ast.nodes.items(.data)[ni];
    switch (tag) {
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        .function_expr,
        .method_definition,
        .class_method,
        .class_private_method,
        .getter,
        .setter,
        => {
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 3 < ctx.ast.extra_data.items.len) {
                return @enumFromInt(ctx.ast.extra_data.items[extra_idx + 3]);
            }
        },
        else => {},
    }
    return null;
}

fn findParentOf(ctx: *TransformContext, target: NodeIndex) ?NodeIndex {
    if (target == .none) return null;
    const target_i = @intFromEnum(target);
    for (0..ctx.ast.nodes.items(.tag).len) |ni| {
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

fn collectFieldInfo(ctx: *TransformContext, member: NodeIndex) ?FieldInfo {
    const data = ctx.nodeData(member);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return null;
    return .{
        .node = member,
        .key = @enumFromInt(ctx.ast.extra_data.items[extra_idx]),
        .value = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 1]),
        .is_static = (ctx.ast.extra_data.items[extra_idx + 2] & 1) != 0,
        .is_private = ctx.nodeTag(member) == .class_private_field,
        .decorator_range = ctx.ast.decorators_map.get(@intFromEnum(member)),
    };
}

fn isConstructorMember(ctx: *TransformContext, member: NodeIndex) bool {
    if (member == .none) return false;
    const tag = ctx.nodeTag(member);
    if (tag != .class_method and tag != .method_definition) return false;

    const data = ctx.nodeData(member);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx >= ctx.ast.extra_data.items.len) return false;
    const key: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    return key != .none and ctx.nodeTag(key) == .identifier and std.mem.eql(u8, ctx.tokenSlice(ctx.mainToken(key)), "constructor");
}

fn renderInstanceFieldInitializers(ctx: *TransformContext, info: *const ClassInfo) ![]const u8 {
    return renderInstanceFieldInitializersForReceiver(ctx, info, "this");
}

fn renderInstanceFieldInitializersForReceiver(ctx: *TransformContext, info: *const ClassInfo, receiver: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    for (info.instance_fields.items) |field| {
        if (field.is_static or field.is_private or field.decorator_range != null) return ctx.allocator.dupe(u8, "");
        if (field.value == .none) continue;
        const key_src = try renderFieldKey(ctx, field.key);
        const value_src = try renderExpr(ctx, field.value);
        if (!first) try buf.append(ctx.allocator, '\n');
        first = false;
        try buf.appendSlice(ctx.allocator, "babelHelpers.defineProperty(");
        try buf.appendSlice(ctx.allocator, receiver);
        try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, key_src);
        try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, value_src);
        try buf.appendSlice(ctx.allocator, ");");
    }
    return buf.items;
}

fn renderStaticFieldAssignmentSequence(ctx: *TransformContext, info: *const ClassInfo, receiver: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    for (info.static_fields.items) |field| {
        if (!field.is_static or field.is_private or field.decorator_range != null) return ctx.allocator.dupe(u8, "");

        const value_src = if (field.value != .none)
            try renderExpr(ctx, field.value)
        else
            "void 0";

        const assignment = if (field.key != .none and ctx.nodeTag(field.key) == .identifier)
            std.fmt.allocPrint(
                ctx.allocator,
                "{s}.{s} = {s}",
                .{ receiver, ctx.tokenSlice(ctx.mainToken(field.key)), value_src },
            ) catch return ctx.allocator.dupe(u8, "")
        else
            std.fmt.allocPrint(
                ctx.allocator,
                "babelHelpers.defineProperty({s}, {s}, {s})",
                .{ receiver, try renderFieldKey(ctx, field.key), value_src },
            ) catch return ctx.allocator.dupe(u8, "");

        if (!first) try buf.appendSlice(ctx.allocator, ", ");
        first = false;
        try buf.appendSlice(ctx.allocator, assignment);
    }
    return buf.items;
}

fn renderLooseInstanceFieldAssignmentsForReceiver(ctx: *TransformContext, info: *const ClassInfo, receiver: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    for (info.instance_fields.items) |field| {
        if (field.is_static or field.is_private or field.decorator_range != null) return ctx.allocator.dupe(u8, "");
        if (field.value == .none) continue;

        const value_src = try renderExpr(ctx, field.value);
        const assignment = if (field.key != .none and ctx.nodeTag(field.key) == .identifier)
            std.fmt.allocPrint(
                ctx.allocator,
                "{s}.{s} = {s};",
                .{ receiver, ctx.tokenSlice(ctx.mainToken(field.key)), value_src },
            ) catch return ctx.allocator.dupe(u8, "")
        else
            std.fmt.allocPrint(
                ctx.allocator,
                "babelHelpers.defineProperty({s}, {s}, {s});",
                .{ receiver, try renderFieldKey(ctx, field.key), value_src },
            ) catch return ctx.allocator.dupe(u8, "");

        if (!first) try buf.append(ctx.allocator, '\n');
        first = false;
        try buf.appendSlice(ctx.allocator, assignment);
    }
    return buf.items;
}

fn wrapSequenceExprIfNeeded(ctx: *TransformContext, node: NodeIndex, expr: []const u8) []const u8 {
    const parent = findParentOf(ctx, node) orelse return expr;
    return switch (ctx.nodeTag(parent)) {
        .parenthesized_expr => blk: {
            const grandparent = findParentOf(ctx, parent) orelse break :blk expr;
            break :blk switch (ctx.nodeTag(grandparent)) {
                .expression_statement, .return_statement, .throw_statement => expr,
                else => std.fmt.allocPrint(ctx.allocator, "({s})", .{expr}) catch expr,
            };
        },
        .expression_statement, .return_statement, .throw_statement => expr,
        else => std.fmt.allocPrint(ctx.allocator, "({s})", .{expr}) catch expr,
    };
}

fn renderFieldKey(ctx: *TransformContext, key: NodeIndex) ![]const u8 {
    if (key != .none and ctx.nodeTag(key) == .identifier) {
        return std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{ctx.tokenSlice(ctx.mainToken(key))});
    }
    return ctx.allocator.dupe(u8, getNodeSource(ctx, key));
}

fn renderSurfaceConstructor(
    ctx: *TransformContext,
    info: *const ClassInfo,
    member: NodeIndex,
    init_block: []const u8,
) ![]const u8 {
    _ = info;
    const method = MethodInfo{
        .node = member,
        .key = .none,
        .body = .none,
        .is_static = false,
        .is_private = false,
    };
    const parts = try resolveMethodParts(ctx, method);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "constructor");
    try buf.appendSlice(ctx.allocator, parts.params);
    try buf.appendSlice(ctx.allocator, " {\n");
    try appendIndentedBody(ctx, &buf, init_block, "  ");
    if (std.mem.trim(u8, parts.body, " \t\r\n").len != 0) {
        try buf.append(ctx.allocator, '\n');
        try appendIndentedBody(ctx, &buf, parts.body, "  ");
    }
    try buf.appendSlice(ctx.allocator, "\n}");
    return buf.items;
}

fn renderSyntheticSurfaceConstructor(ctx: *TransformContext, init_block: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "constructor() {\n");
    try appendIndentedBody(ctx, &buf, init_block, "  ");
    try buf.appendSlice(ctx.allocator, "\n}");
    return buf.items;
}

fn renderSurfaceInitBlock(ctx: *TransformContext, info: *const ClassInfo, capability: Capability) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;

    if (capability.private_methods) {
        for (info.private_methods.items) |method| {
            const temp_name = try renderPrivateMethodTempName(ctx, method);
            if (!first) try buf.append(ctx.allocator, '\n');
            first = false;
            try buf.appendSlice(ctx.allocator, "babelHelpers.classPrivateMethodInitSpec(this, ");
            try buf.appendSlice(ctx.allocator, temp_name);
            try buf.appendSlice(ctx.allocator, ");");
        }
    }

    if (capability.public_fields) {
        const fields = try renderInstanceFieldInitializers(ctx, info);
        const trimmed = std.mem.trim(u8, fields, " \t\r\n");
        if (trimmed.len != 0) {
            if (!first) try buf.append(ctx.allocator, '\n');
            try buf.appendSlice(ctx.allocator, fields);
        }
    }

    return buf.items;
}

fn renderPrivateMethodPrelude(ctx: *TransformContext, info: *const ClassInfo) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (info.private_methods.items, 0..) |method, i| {
        if (i > 0) try buf.append(ctx.allocator, '\n');
        const temp_name = try renderPrivateMethodTempName(ctx, method);
        try buf.appendSlice(ctx.allocator, "var ");
        try buf.appendSlice(ctx.allocator, temp_name);
        try buf.appendSlice(ctx.allocator, " = /*#__PURE__*/new WeakSet();");
    }
    return buf.items;
}

fn renderPrivateMethodFunctions(ctx: *TransformContext, info: *const ClassInfo) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (info.private_methods.items, 0..) |method, i| {
        if (i > 0) try buf.append(ctx.allocator, '\n');
        const temp_name = try renderPrivateMethodFunctionName(ctx, method);
        const parts = MethodParts{
            .params = try renderParamListForMethod(ctx, method),
            .body = try renderGeneratedMethodBody(ctx, method.body),
        };
        try buf.appendSlice(ctx.allocator, "function ");
        try buf.appendSlice(ctx.allocator, temp_name);
        try buf.appendSlice(ctx.allocator, parts.params);
        try buf.appendSlice(ctx.allocator, " {");
        if (std.mem.trim(u8, parts.body, " \t\r\n").len != 0) {
            try buf.append(ctx.allocator, '\n');
            try appendIndentedBody(ctx, &buf, parts.body, "  ");
            try buf.appendSlice(ctx.allocator, "\n}");
        } else {
            try buf.appendSlice(ctx.allocator, "\n}");
        }
    }
    return buf.items;
}

fn renderPrivateMethodTempName(ctx: *TransformContext, method: MethodInfo) ![]const u8 {
    const class_name = if (findEnclosingClassInfoName(ctx, method.node)) |name| name else "_Class";
    const method_name = try renderPrivateMethodFunctionName(ctx, method);
    return std.fmt.allocPrint(ctx.allocator, "_{s}_brand", .{class_name}) catch method_name;
}

fn renderPrivateMethodFunctionName(ctx: *TransformContext, method: MethodInfo) ![]const u8 {
    const key = method.key;
    if (key != .none and ctx.nodeTag(key) == .private_name) {
        const inner = ctx.nodeData(key).unary;
        if (inner != .none and ctx.nodeTag(inner) == .identifier) {
            return std.fmt.allocPrint(ctx.allocator, "_{s}", .{ctx.tokenSlice(ctx.mainToken(inner))});
        }
    }
    if (key != .none and ctx.nodeTag(key) == .identifier) {
        return std.fmt.allocPrint(ctx.allocator, "_{s}", .{ctx.tokenSlice(ctx.mainToken(key))});
    }
    return ctx.allocator.dupe(u8, "_privateMethod");
}

fn renderGeneratedMethodBody(ctx: *TransformContext, body: NodeIndex) ![]const u8 {
    if (body == .none or ctx.nodeTag(body) != .block_statement) return ctx.allocator.dupe(u8, "");
    const generated = getGeneratedSource(ctx, body);
    const trimmed = std.mem.trim(u8, generated, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return ctx.allocator.dupe(u8, trimmed);
    }
    return normalizeBlockBodyIndent(ctx, std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n"));
}

fn findEnclosingClassInfoName(ctx: *TransformContext, node: NodeIndex) ?[]const u8 {
    const tags = ctx.ast.nodes.items(.tag);
    const data = ctx.ast.nodes.items(.data);
    const target = @intFromEnum(node);

    for (tags, 0..) |tag, ni| {
        if (tag != .class_declaration and tag != .class_expr) continue;
        const extra_idx = @intFromEnum(data[ni].extra);
        if (extra_idx + 2 >= ctx.ast.extra_data.items.len) continue;
        const body: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx + 2]);
        if (body == .none or ctx.nodeTag(body) != .class_body) continue;

        const body_data = ctx.nodeData(body);
        const body_extra = @intFromEnum(body_data.extra);
        if (body_extra + 1 >= ctx.ast.extra_data.items.len) continue;
        const range_start: usize = @intCast(ctx.ast.extra_data.items[body_extra]);
        const range_end: usize = @intCast(ctx.ast.extra_data.items[body_extra + 1]);
        if (range_start > range_end or range_end > ctx.ast.extra_data.items.len) continue;

        for (ctx.ast.extra_data.items[range_start..range_end]) |member_raw| {
            if (member_raw != target) continue;
            const name_tok = ctx.ast.extra_data.items[extra_idx];
            if (name_tok == 0) return null;
            return ctx.tokenSlice(@enumFromInt(name_tok));
        }
    }
    return null;
}

fn shouldEmitWrapperStrict(ctx: *TransformContext) bool {
    return ctx.ast.source_type == .script;
}

fn shouldUseBaseIife(ctx: *TransformContext, info: *const ClassInfo) bool {
    if (info.methods.items.len != 0) return true;
    if (info.instance_fields.items.len != 0 or info.static_fields.items.len != 0) return true;
    if (info.private_methods.items.len != 0) return true;
    if (info.decorator_range != null) return true;
    if (info.ctor) |ctor| {
        return !methodParamsAreSimple(ctx, ctor);
    }
    return false;
}

fn methodParamsAreSimple(ctx: *TransformContext, method: MethodInfo) bool {
    const data = ctx.nodeData(method.node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return false;

    const params_start: usize = @intCast(ctx.ast.extra_data.items[extra_idx + 1]);
    const params_end: usize = @intCast(ctx.ast.extra_data.items[extra_idx + 2]);
    if (params_start > params_end or params_end > ctx.ast.extra_data.items.len) return false;

    for (ctx.ast.extra_data.items[params_start..params_end]) |param_raw| {
        if (!paramNodeIsSimple(ctx, @enumFromInt(param_raw))) return false;
    }
    return true;
}

fn paramNodeIsSimple(ctx: *TransformContext, param: NodeIndex) bool {
    if (param == .none) return false;

    return switch (ctx.nodeTag(param)) {
        .identifier => true,
        .ts_parameter_property => blk: {
            const data = ctx.nodeData(param);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx >= ctx.ast.extra_data.items.len) break :blk false;
            break :blk paramNodeIsSimple(ctx, @enumFromInt(ctx.ast.extra_data.items[extra_idx]));
        },
        else => false,
    };
}

const MethodParts = struct {
    params: []const u8,
    body: []const u8,
};

fn resolveMethodParts(ctx: *TransformContext, method: MethodInfo) !MethodParts {
    if (ctx.ast.replacement_source.contains(@intFromEnum(method.node))) {
        if (extractMethodPartsFromSource(ctx, getNodeSource(ctx, method.node))) |parts| return parts;
    }
    return .{
        .params = try renderParamListForMethod(ctx, method),
        .body = try renderStatementList(ctx, method.body),
    };
}

fn extractMethodPartsFromSource(ctx: *TransformContext, method_source: []const u8) ?MethodParts {
    const trimmed = std.mem.trim(u8, method_source, " \t\r\n");
    if (trimmed.len == 0) return null;

    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return null;
    const close_paren = findMatchingDelimiter(trimmed, open_paren, '(', ')') orelse return null;

    var body_start = close_paren + 1;
    while (body_start < trimmed.len and trimmed[body_start] != '{') : (body_start += 1) {}
    if (body_start >= trimmed.len) return null;

    const body_end = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return null;
    if (body_end <= body_start) return null;

    const normalized_body = normalizeBlockBodyIndent(ctx, std.mem.trimEnd(u8, trimmed[body_start + 1 .. body_end], " \t\r\n")) catch return null;
    return .{
        .params = trimmed[open_paren .. close_paren + 1],
        .body = normalized_body,
    };
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
                continue;
            }
            if (source[i + 1] == '*') {
                i = skipBlockComment(source, i + 2) orelse return null;
                continue;
            }
        }
    }
    return null;
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

fn normalizeBlockBodyIndent(ctx: *TransformContext, body: []const u8) ![]const u8 {
    if (body.len == 0) return ctx.allocator.dupe(u8, "");

    var lines = std.mem.splitScalar(u8, body, '\n');
    var min_indent: ?usize = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
        min_indent = if (min_indent) |current| @min(current, indent) else indent;
    }

    const strip = min_indent orelse 0;
    if (strip == 0) return ctx.allocator.dupe(u8, body);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var out_lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (out_lines.next()) |line| {
        if (!first) try buf.append(ctx.allocator, '\n');
        first = false;

        var start: usize = 0;
        var remaining = strip;
        while (start < line.len and remaining > 0 and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {
            remaining -= 1;
        }
        try buf.appendSlice(ctx.allocator, line[start..]);
    }
    return buf.items;
}

fn nodeStartOffset(ctx: *TransformContext, node: NodeIndex) u32 {
    const ni = @intFromEnum(node);
    return ctx.ast.node_start_overrides.get(ni) orelse ctx.ast.tokens.items(.start)[@intFromEnum(ctx.mainToken(node))];
}

fn getNodeSource(ctx: *TransformContext, idx: NodeIndex) []const u8 {
    if (idx == .none) return "";
    const ni = @intFromEnum(idx);
    if (ctx.ast.replacement_source.get(ni)) |replacement| return replacement;

    const start = nodeStartOffset(ctx, idx);
    const end = ctx.ast.nodes.items(.end_offset)[ni];
    if (start >= end or end > ctx.ast.source.len) return "";
    return buildEffectiveSource(ctx, start, end);
}

fn getClassNameSource(ctx: *TransformContext, info: *const ClassInfo) []const u8 {
    if (info.name) |name_tok| return ctx.tokenSlice(name_tok);
    if (ctx.nodeTag(info.class_node) == .class_declaration) {
        if (extractClassNameFromSource(getNodeSource(ctx, info.class_node))) |name| return name;
    }
    return "_Class";
}

fn extractClassNameFromSource(source: []const u8) ?[]const u8 {
    const class_pos = std.mem.indexOf(u8, source, "class") orelse return null;
    var pos = class_pos + "class".len;
    while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or source[pos] == '\r' or source[pos] == '\n')) : (pos += 1) {}
    const start = pos;
    while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_' or source[pos] == '$')) : (pos += 1) {}
    if (pos == start) return null;
    return source[start..pos];
}

fn renderDecoratorExprList(ctx: *TransformContext, range: ExtraRange) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const start: usize = @intCast(range.start);
    const end: usize = @intCast(range.end);
    if (start > end or end > ctx.ast.extra_data.items.len) return buf.items;

    for (ctx.ast.extra_data.items[start..end], 0..) |decorator_raw, i| {
        if (i > 0) try buf.appendSlice(ctx.allocator, ", ");
        const decorator: NodeIndex = @enumFromInt(decorator_raw);
        if (ctx.nodeTag(decorator) == .decorator) {
            try buf.appendSlice(ctx.allocator, getNodeSource(ctx, ctx.nodeData(decorator).unary));
        } else {
            try buf.appendSlice(ctx.allocator, getNodeSource(ctx, decorator));
        }
    }
    return buf.items;
}

fn renderSingleDecoratorExpr(ctx: *TransformContext, range: ExtraRange) ![]const u8 {
    const start: usize = @intCast(range.start);
    const end: usize = @intCast(range.end);
    if (start + 1 != end or end > ctx.ast.extra_data.items.len) return error.UnsupportedDecoratorList;

    const decorator: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[start]);
    if (ctx.nodeTag(decorator) == .decorator) {
        // Use decorator node source minus @ prefix to handle call expressions
        // (call_expr main token is '(' so getNodeSource on the unary misses the callee)
        const full_src = getNodeSource(ctx, decorator);
        if (full_src.len > 0 and full_src[0] == '@') {
            return ctx.allocator.dupe(u8, std.mem.trimStart(u8, full_src[1..], &[_]u8{ ' ', '\t' }));
        }
        return ctx.allocator.dupe(u8, full_src);
    }
    return ctx.allocator.dupe(u8, getNodeSource(ctx, decorator));
}

fn ensureConstructorSource(ctx: *TransformContext, info: *ClassInfo) ![]const u8 {
    if (info.ctor) |ctor| return ctx.allocator.dupe(u8, getNodeSource(ctx, ctor.node));
    const class_name = getClassNameSource(ctx, info);
    return std.fmt.allocPrint(
        ctx.allocator,
        "() {{\n  \"use strict\";\n\n  babelHelpers.classCallCheck(this, {s});\n}}",
        .{class_name},
    );
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

fn nodeStartOffsetRaw(ctx: *TransformContext, ni: usize) u32 {
    return ctx.ast.node_start_overrides.get(@intCast(ni)) orelse ctx.ast.tokens.items(.start)[@intFromEnum(ctx.ast.nodes.items(.main_token)[ni])];
}

fn renderSuperAlias(ctx: *TransformContext, super_class: NodeIndex) ![]const u8 {
    const super_src = std.mem.trim(u8, try renderExpr(ctx, super_class), " \t\r\n");
    if (super_src.len == 0) return ctx.allocator.dupe(u8, "_Super");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(ctx.allocator, '_');
    for (super_src) |ch| {
        if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '$') {
            try buf.append(ctx.allocator, ch);
            continue;
        }
        if (ch == '.') {
            try buf.append(ctx.allocator, '$');
            continue;
        }
        return ctx.allocator.dupe(u8, "_Super");
    }
    return buf.items;
}

fn renderBaseConstructor(
    ctx: *TransformContext,
    info: *ClassInfo,
    class_name: []const u8,
    include_use_strict: bool,
    body_indent: []const u8,
    closing_indent: []const u8,
    field_init_block: []const u8,
) ![]const u8 {
    const parts = if (info.ctor) |ctor|
        try resolveMethodParts(ctx, ctor)
    else
        MethodParts{ .params = "()", .body = "" };
    const prelude = splitBaseConstructorPrelude(parts.body);
    const body_tail = std.mem.trimStart(u8, parts.body[prelude.len..], " \t\r\n");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(ctx.allocator, parts.params);
    try buf.appendSlice(ctx.allocator, " {\n");
    if (include_use_strict) {
        try buf.appendSlice(ctx.allocator, body_indent);
        try buf.appendSlice(ctx.allocator, "\"use strict\";\n\n");
    }
    if (std.mem.trim(u8, prelude, " \t\r\n").len != 0) {
        try appendIndentedBody(ctx, &buf, prelude, body_indent);
        try buf.append(ctx.allocator, '\n');
    }
    try buf.appendSlice(ctx.allocator, body_indent);
    try buf.appendSlice(ctx.allocator, "babelHelpers.classCallCheck(this, ");
    try buf.appendSlice(ctx.allocator, class_name);
    try buf.appendSlice(ctx.allocator, ");");
    if (std.mem.trim(u8, field_init_block, " \t\r\n").len != 0) {
        try buf.append(ctx.allocator, '\n');
        try appendIndentedBody(ctx, &buf, field_init_block, body_indent);
    }
    if (std.mem.trim(u8, body_tail, " \t\r\n").len != 0) {
        try buf.append(ctx.allocator, '\n');
        try appendIndentedBody(ctx, &buf, body_tail, body_indent);
    }
    try buf.append(ctx.allocator, '\n');
    try buf.appendSlice(ctx.allocator, closing_indent);
    try buf.append(ctx.allocator, '}');
    return buf.items;
}

fn renderDerivedConstructor(ctx: *TransformContext, info: *ClassInfo, class_name: []const u8, field_init_block: []const u8) ![]const u8 {
    if (info.ctor == null and std.mem.trim(u8, field_init_block, " \t\r\n").len != 0) {
        return renderSyntheticDerivedFieldConstructor(ctx, class_name, field_init_block);
    }

    const parts = if (info.ctor) |ctor|
        try resolveMethodParts(ctx, ctor)
    else
        MethodParts{ .params = "()", .body = "super(...arguments);" };
    const body = parts.body;
    const super_stmt = extractLeadingSuperStatement(body) orelse return ctx.allocator.dupe(u8, "() {\n    babelHelpers.classCallCheck(this, _Class);\n    return babelHelpers.callSuper(this, _Class, arguments);\n}");
    const rest = std.mem.trim(u8, body[super_stmt.end..], " \t\r\n");
    const super_call = renderCallSuperExpr(ctx, class_name, super_stmt.text) catch return ctx.allocator.dupe(u8, "babelHelpers.callSuper(this, _Class)");
    const needs_alias = rest.len != 0 or std.mem.trim(u8, field_init_block, " \t\r\n").len != 0;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(ctx.allocator, parts.params);
    try buf.appendSlice(ctx.allocator, " {\n");
    if (needs_alias) {
        try buf.appendSlice(ctx.allocator, "    var _this;\n");
    }
    try buf.appendSlice(ctx.allocator, "    babelHelpers.classCallCheck(this, ");
    try buf.appendSlice(ctx.allocator, class_name);
    try buf.appendSlice(ctx.allocator, ");\n");
    if (needs_alias) {
        try buf.appendSlice(ctx.allocator, "    _this = ");
        try buf.appendSlice(ctx.allocator, super_call);
        try buf.appendSlice(ctx.allocator, ";\n");
        if (std.mem.trim(u8, field_init_block, " \t\r\n").len != 0) {
            try appendIndentedBody(ctx, &buf, field_init_block, "    ");
            if (rest.len != 0) try buf.append(ctx.allocator, '\n');
        }
        const rewritten_rest = replaceAllIdentifierAware(ctx.allocator, rest, "this", "_this") catch rest;
        try appendIndentedBody(ctx, &buf, rewritten_rest, "    ");
        try buf.appendSlice(ctx.allocator, "\n    return _this;\n  }");
    } else {
        try buf.appendSlice(ctx.allocator, "    return ");
        try buf.appendSlice(ctx.allocator, super_call);
        try buf.appendSlice(ctx.allocator, ";\n  }");
    }
    return buf.items;
}

fn renderSyntheticDerivedFieldConstructor(ctx: *TransformContext, class_name: []const u8, field_init_block: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "() {\n");
    try buf.appendSlice(ctx.allocator, "    var _this;\n");
    try buf.appendSlice(ctx.allocator, "    babelHelpers.classCallCheck(this, ");
    try buf.appendSlice(ctx.allocator, class_name);
    try buf.appendSlice(ctx.allocator, ");\n");
    try buf.appendSlice(ctx.allocator, "    for (var _len = arguments.length, args = new Array(_len), _key = 0; _key < _len; _key++) {\n");
    try buf.appendSlice(ctx.allocator, "      args[_key] = arguments[_key];\n");
    try buf.appendSlice(ctx.allocator, "    }\n");
    try buf.appendSlice(ctx.allocator, "    _this = babelHelpers.callSuper(this, ");
    try buf.appendSlice(ctx.allocator, class_name);
    try buf.appendSlice(ctx.allocator, ", [].concat(args));\n");
    try appendIndentedBody(ctx, &buf, field_init_block, "    ");
    try buf.appendSlice(ctx.allocator, "\n    return _this;\n  }");
    return buf.items;
}

fn renderCreateClassCall(ctx: *TransformContext, info: *const ClassInfo, class_name: []const u8) ![]const u8 {
    const proto_methods = try renderMethodDescriptorArray(ctx, info.methods.items, false);
    const static_methods = try renderMethodDescriptorArray(ctx, info.methods.items, true);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "babelHelpers.createClass(");
    try buf.appendSlice(ctx.allocator, class_name);
    if (proto_methods.len != 0 or static_methods.len != 0) {
        try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, if (proto_methods.len != 0) proto_methods else "[]");
        if (static_methods.len != 0) {
            try buf.appendSlice(ctx.allocator, ", ");
            try buf.appendSlice(ctx.allocator, static_methods);
        }
    }
    try buf.append(ctx.allocator, ')');
    return buf.items;
}

fn renderMethodDescriptorArray(ctx: *TransformContext, methods: []const MethodInfo, want_static: bool) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;

    for (methods) |method| {
        if (method.is_static != want_static or method.is_private) continue;
        const descriptor = try renderMethodDescriptor(ctx, method);
        if (first) {
            try buf.append(ctx.allocator, '[');
        } else {
            try buf.appendSlice(ctx.allocator, ", ");
        }
        first = false;
        try buf.appendSlice(ctx.allocator, descriptor);
    }

    if (first) return ctx.allocator.dupe(u8, "");
    try buf.append(ctx.allocator, ']');
    return buf.items;
}

fn renderMethodDescriptor(ctx: *TransformContext, method: MethodInfo) ![]const u8 {
    const key_src = try renderMethodKey(ctx, method);
    const parts = try resolveMethodParts(ctx, method);
    const prop_name = if (method.is_getter)
        "get"
    else if (method.is_setter)
        "set"
    else
        "value";
    const func_name = if (!method.is_computed and method.key != .none and ctx.nodeTag(method.key) == .identifier)
        ctx.tokenSlice(ctx.mainToken(method.key))
    else
        "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "{\n    key: ");
    try buf.appendSlice(ctx.allocator, key_src);
    try buf.appendSlice(ctx.allocator, ",\n    ");
    try buf.appendSlice(ctx.allocator, prop_name);
    try buf.appendSlice(ctx.allocator, ": ");
    if (method.is_async) try buf.appendSlice(ctx.allocator, "async ");
    try buf.appendSlice(ctx.allocator, "function");
    if (method.is_generator) try buf.append(ctx.allocator, '*');
    if (func_name.len != 0) {
        try buf.append(ctx.allocator, ' ');
        try buf.appendSlice(ctx.allocator, func_name);
    }
    try buf.appendSlice(ctx.allocator, parts.params);
    try buf.appendSlice(ctx.allocator, " {");
    if (std.mem.trim(u8, parts.body, " \t\r\n").len != 0) {
        try buf.append(ctx.allocator, '\n');
        try appendIndentedBody(ctx, &buf, parts.body, "      ");
        try buf.appendSlice(ctx.allocator, "\n    }");
    } else {
        try buf.appendSlice(ctx.allocator, "\n    }");
    }
    try buf.appendSlice(ctx.allocator, "\n  }");
    return buf.items;
}

fn renderMethodKey(ctx: *TransformContext, method: MethodInfo) ![]const u8 {
    if (method.is_computed) return renderExpr(ctx, method.key);
    if (method.key != .none and ctx.nodeTag(method.key) == .identifier) {
        return std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{ctx.tokenSlice(ctx.mainToken(method.key))});
    }
    return ctx.allocator.dupe(u8, getNodeSource(ctx, method.key));
}

fn renderMethodSurfaceKey(ctx: *TransformContext, method: MethodInfo) ![]const u8 {
    if (method.is_computed) {
        const expr = try renderExpr(ctx, method.key);
        return std.fmt.allocPrint(ctx.allocator, "[{s}]", .{expr});
    }
    return ctx.allocator.dupe(u8, getNodeSource(ctx, method.key));
}

fn renderSurfaceMethodWithoutDecorators(ctx: *TransformContext, method: MethodInfo) ![]const u8 {
    const source = getNodeSource(ctx, method.node);
    return ctx.allocator.dupe(u8, stripLeadingDecorators(source));
}

fn renderDecoratedFieldWarningSurface(ctx: *TransformContext, field: FieldInfo, descriptor_name: []const u8) ![]const u8 {
    const key = if (field.key != .none and ctx.nodeTag(field.key) == .identifier)
        ctx.tokenSlice(ctx.mainToken(field.key))
    else
        return error.UnsupportedDecoratedField;
    return std.fmt.allocPrint(
        ctx.allocator,
        "{s} = babelHelpers.initializerWarningHelper({s}, this);",
        .{ key, descriptor_name },
    );
}

fn renderDecoratedFieldInitializer(ctx: *TransformContext, value: NodeIndex) ![]const u8 {
    return renderExpr(ctx, value);
}

fn stripLeadingDecorators(source: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    var pos: usize = 0;
    while (pos < trimmed.len and trimmed[pos] == '@') {
        pos += 1;
        var depth_paren: usize = 0;
        var depth_bracket: usize = 0;
        var depth_brace: usize = 0;
        while (pos < trimmed.len) : (pos += 1) {
            const ch = trimmed[pos];
            switch (ch) {
                '(' => depth_paren += 1,
                ')' => {
                    if (depth_paren > 0) depth_paren -= 1;
                },
                '[' => depth_bracket += 1,
                ']' => {
                    if (depth_bracket > 0) depth_bracket -= 1;
                },
                '{' => depth_brace += 1,
                '}' => {
                    if (depth_brace > 0) depth_brace -= 1;
                },
                else => {},
            }
            if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 and std.ascii.isWhitespace(ch)) break;
        }
        while (pos < trimmed.len and std.ascii.isWhitespace(trimmed[pos])) : (pos += 1) {}
    }
    return std.mem.trim(u8, trimmed[pos..], " \t\r\n");
}

fn extractDecoratorExprListFromSource(ctx: *TransformContext, source: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    var pos: usize = 0;
    var first = true;
    while (pos < trimmed.len and trimmed[pos] == '@') {
        pos += 1;
        const expr_start = pos;
        var depth_paren: usize = 0;
        var depth_bracket: usize = 0;
        var depth_brace: usize = 0;
        while (pos < trimmed.len) : (pos += 1) {
            const ch = trimmed[pos];
            switch (ch) {
                '(' => depth_paren += 1,
                ')' => {
                    if (depth_paren > 0) depth_paren -= 1;
                },
                '[' => depth_bracket += 1,
                ']' => {
                    if (depth_bracket > 0) depth_bracket -= 1;
                },
                '{' => depth_brace += 1,
                '}' => {
                    if (depth_brace > 0) depth_brace -= 1;
                },
                else => {},
            }
            if (depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 and std.ascii.isWhitespace(ch)) break;
        }
        const expr = std.mem.trim(u8, trimmed[expr_start..pos], " \t\r\n");
        if (expr.len == 0) return error.UnsupportedDecoratorList;
        if (!first) try buf.appendSlice(ctx.allocator, ", ");
        first = false;
        try buf.appendSlice(ctx.allocator, expr);
        while (pos < trimmed.len and std.ascii.isWhitespace(trimmed[pos])) : (pos += 1) {}
    }
    if (first) return error.UnsupportedDecoratorList;
    return buf.items;
}

fn renderQuotedMemberKeyFromSurfaceSource(ctx: *TransformContext, source: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return error.UnsupportedDecoratedMethod;

    var start: usize = 0;
    if (std.mem.startsWith(u8, trimmed, "static ")) start += "static ".len;
    if (std.mem.startsWith(u8, trimmed[start..], "async ")) start += "async ".len;
    if (std.mem.startsWith(u8, trimmed[start..], "get ")) {
        start += "get ".len;
    } else if (std.mem.startsWith(u8, trimmed[start..], "set ")) {
        start += "set ".len;
    } else if (start < trimmed.len and trimmed[start] == '*') {
        start += 1;
    }

    const rest = std.mem.trimStart(u8, trimmed[start..], " \t");
    if (rest.len == 0 or rest[0] == '[') return error.UnsupportedDecoratedMethod;

    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_' or rest[end] == '$')) : (end += 1) {}
    if (end == 0) return error.UnsupportedDecoratedMethod;

    return std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{rest[0..end]});
}

fn splitBaseConstructorPrelude(body: []const u8) []const u8 {
    var pos: usize = 0;
    var last_match_end: usize = 0;
    while (pos < body.len) {
        while (pos < body.len and std.ascii.isWhitespace(body[pos])) : (pos += 1) {}
        if (pos >= body.len) break;

        const stmt_end = findTopLevelStatementEnd(body, pos) orelse break;
        const stmt = std.mem.trim(u8, body[pos..stmt_end], " \t\r\n");
        if (!looksLikeBaseConstructorPrelude(stmt)) break;
        last_match_end = stmt_end;
        pos = stmt_end;
    }
    return std.mem.trimEnd(u8, body[0..last_match_end], " \t\r\n");
}

fn findTopLevelStatementEnd(body: []const u8, start: usize) ?usize {
    var depth_paren: usize = 0;
    var depth_brace: usize = 0;
    var depth_bracket: usize = 0;
    var i = start;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        switch (ch) {
            '(' => depth_paren += 1,
            ')' => {
                if (depth_paren > 0) depth_paren -= 1;
            },
            '[' => depth_bracket += 1,
            ']' => {
                if (depth_bracket > 0) depth_bracket -= 1;
            },
            '{' => depth_brace += 1,
            '}' => {
                if (depth_brace > 0) {
                    depth_brace -= 1;
                    if (depth_brace == 0 and depth_paren == 0 and depth_bracket == 0) {
                        var end = i + 1;
                        while (end < body.len and (body[end] == ';' or std.ascii.isWhitespace(body[end]))) : (end += 1) {}
                        return end;
                    }
                }
            },
            ';' => if (depth_paren == 0 and depth_brace == 0 and depth_bracket == 0) return i + 1,
            '"', '\'', '`' => i = skipQuotedLiteral(body, i) orelse return null,
            '/' => if (i + 1 < body.len) {
                if (body[i + 1] == '/') {
                    i = skipLineComment(body, i + 2);
                } else if (body[i + 1] == '*') {
                    i = skipBlockComment(body, i + 2) orelse return null;
                }
            },
            else => {},
        }
    }
    return if (start < body.len) body.len else null;
}

fn looksLikeBaseConstructorPrelude(stmt: []const u8) bool {
    if (stmt.len == 0) return false;
    if (std.mem.indexOf(u8, stmt, "arguments")) |_| return true;
    if (std.mem.indexOf(u8, stmt, "=== void 0")) |_| return true;
    if (std.mem.startsWith(u8, stmt, "for (var _len")) return true;
    return false;
}

fn appendIndentedBody(ctx: *TransformContext, buf: *std.ArrayListUnmanaged(u8), source: []const u8, prefix: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    var preserve_continuation_indent = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!first) try buf.append(ctx.allocator, '\n');
        if (first or !preserve_continuation_indent) {
            try buf.appendSlice(ctx.allocator, prefix);
        }
        first = false;
        try buf.appendSlice(ctx.allocator, trimmed);
        if (!preserve_continuation_indent and
            (std.mem.indexOf(u8, trimmed, "= <") != null or
                std.mem.indexOf(u8, trimmed, "=<") != null or
                std.mem.indexOf(u8, trimmed, "return <") != null))
        {
            preserve_continuation_indent = true;
        }
        if (preserve_continuation_indent and std.mem.endsWith(u8, std.mem.trimEnd(u8, trimmed, " \t"), ";")) {
            preserve_continuation_indent = false;
        }
    }
}

fn renderParamListForMethod(ctx: *TransformContext, method: MethodInfo) ![]const u8 {
    const data = ctx.nodeData(method.node);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return ctx.allocator.dupe(u8, "()");

    const params_start: usize = @intCast(ctx.ast.extra_data.items[extra_idx + 1]);
    const params_end: usize = @intCast(ctx.ast.extra_data.items[extra_idx + 2]);
    if (params_start > params_end or params_end > ctx.ast.extra_data.items.len) return ctx.allocator.dupe(u8, "()");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(ctx.allocator, '(');
    for (ctx.ast.extra_data.items[params_start..params_end], 0..) |param_raw, i| {
        if (i > 0) try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, try renderExpr(ctx, @enumFromInt(param_raw)));
    }
    try buf.append(ctx.allocator, ')');
    return buf.items;
}

fn renderStatementList(ctx: *TransformContext, body: NodeIndex) ![]const u8 {
    if (body == .none or ctx.nodeTag(body) != .block_statement) return ctx.allocator.dupe(u8, "");

    const data = ctx.nodeData(body);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return ctx.allocator.dupe(u8, "");

    const stmts_start: usize = @intCast(ctx.ast.extra_data.items[extra_idx]);
    const stmts_end: usize = @intCast(ctx.ast.extra_data.items[extra_idx + 1]);
    if (stmts_start > stmts_end or stmts_end > ctx.ast.extra_data.items.len) return ctx.allocator.dupe(u8, "");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    for (ctx.ast.extra_data.items[stmts_start..stmts_end]) |stmt_raw| {
        const stmt: NodeIndex = @enumFromInt(stmt_raw);
        const rendered = try renderStatement(ctx, stmt);
        const trimmed = std.mem.trim(u8, rendered, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (!first) try buf.append(ctx.allocator, '\n');
        first = false;
        try buf.appendSlice(ctx.allocator, trimmed);
    }
    return buf.items;
}

fn renderStatement(ctx: *TransformContext, stmt: NodeIndex) ![]const u8 {
    if (stmt == .none) return ctx.allocator.dupe(u8, "");
    if (ctx.nodeTag(stmt) == .block_statement) {
        return ctx.allocator.dupe(u8, getGeneratedSource(ctx, stmt));
    }
    if (ctx.ast.replacement_source.get(@intFromEnum(stmt))) |replacement| {
        if (ctx.ast.replacement_needs_reindent.contains(@intFromEnum(stmt))) {
            return ctx.allocator.dupe(u8, getGeneratedSource(ctx, stmt));
        }
        return ctx.allocator.dupe(u8, replacement);
    }

    switch (ctx.nodeTag(stmt)) {
        .expression_statement => {
            const expr = ctx.nodeData(stmt).unary;
            return std.fmt.allocPrint(ctx.allocator, "{s};", .{try renderExpr(ctx, expr)});
        },
        .var_declaration, .let_declaration, .const_declaration => {
            return ctx.allocator.dupe(u8, getGeneratedSource(ctx, stmt));
        },
        else => {
            const ni = @intFromEnum(stmt);
            if (ni < ctx.ast.nodes.items(.end_offset).len) {
                const start = nodeStartOffset(ctx, stmt);
                const end = ctx.ast.nodes.items(.end_offset)[ni];
                if (start < end and end <= ctx.ast.source.len) {
                    return ctx.allocator.dupe(u8, getNodeSource(ctx, stmt));
                }
            }
            return ctx.allocator.dupe(u8, getNodeSource(ctx, stmt));
        },
    }
}

fn renderExpr(ctx: *TransformContext, expr: NodeIndex) anyerror![]const u8 {
    if (expr == .none) return ctx.allocator.dupe(u8, "");

    switch (ctx.nodeTag(expr)) {
        .identifier => return ctx.allocator.dupe(u8, ctx.tokenSlice(ctx.mainToken(expr))),
        .arrow_function_expr => {
            if (ctx.ast.replacement_source.get(@intFromEnum(expr))) |replacement| {
                return ctx.allocator.dupe(u8, replacement);
            }

            const data = ctx.nodeData(expr);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) {
                return ctx.allocator.dupe(u8, getNodeSource(ctx, expr));
            }

            const first = ctx.ast.extra_data.items[extra_idx];
            const second = ctx.ast.extra_data.items[extra_idx + 1];
            const third = ctx.ast.extra_data.items[extra_idx + 2];

            var body_node: NodeIndex = .none;
            var params_start: usize = 0;
            var params_end: usize = 0;
            var single_param: ?NodeIndex = null;

            if (first == @intFromEnum(NodeIndex.none) or third == 1) {
                single_param = @enumFromInt(first);
                body_node = @enumFromInt(second);
            } else {
                params_start = @intCast(first);
                params_end = @intCast(second);
                body_node = @enumFromInt(third);
            }

            const params_src = if (single_param) |param|
                try renderArrowParamList(ctx, &.{param})
            else if (params_end <= ctx.ast.extra_data.items.len and params_start <= params_end)
                try renderArrowParamRange(ctx, ctx.ast.extra_data.items[params_start..params_end])
            else
                "()";

            if (body_node != .none and ctx.nodeTag(body_node) == .block_statement) {
                const body_src = try renderStatementList(ctx, body_node);
                if (std.mem.trim(u8, body_src, " \t\r\n").len == 0) {
                    return std.fmt.allocPrint(ctx.allocator, "{s} => {{}}", .{params_src});
                }

                var buf: std.ArrayListUnmanaged(u8) = .empty;
                try buf.appendSlice(ctx.allocator, params_src);
                try buf.appendSlice(ctx.allocator, " => {\n");
                try appendIndentedBody(ctx, &buf, body_src, "  ");
                try buf.appendSlice(ctx.allocator, "\n}");
                return buf.items;
            }

            return std.fmt.allocPrint(ctx.allocator, "{s} => {s}", .{ params_src, try renderExpr(ctx, body_node) });
        },
        .ts_parameter_property => {
            const data = ctx.nodeData(expr);
            const extra_idx = @intFromEnum(data.extra);
            return renderExpr(ctx, @enumFromInt(ctx.ast.extra_data.items[extra_idx]));
        },
        .assignment_pattern => {
            const data = ctx.nodeData(expr);
            const lhs = try renderExpr(ctx, data.binary.lhs);
            const rhs = try renderExpr(ctx, data.binary.rhs);
            return std.fmt.allocPrint(ctx.allocator, "{s} = {s}", .{ lhs, rhs });
        },
        .rest_element => {
            const arg = ctx.nodeData(expr).unary;
            return std.fmt.allocPrint(ctx.allocator, "...{s}", .{try renderExpr(ctx, arg)});
        },
        .this_expr => return ctx.allocator.dupe(u8, "this"),
        .member_expr => {
            const data = ctx.nodeData(expr);
            const lhs = try renderExpr(ctx, data.binary.lhs);
            const prop_tok: TokenIndex = @enumFromInt(@intFromEnum(data.binary.rhs));
            return std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ lhs, ctx.tokenSlice(prop_tok) });
        },
        .computed_member_expr => {
            const data = ctx.nodeData(expr);
            const lhs = try renderExpr(ctx, data.binary.lhs);
            const rhs = try renderExpr(ctx, data.binary.rhs);
            return std.fmt.allocPrint(ctx.allocator, "{s}[{s}]", .{ lhs, rhs });
        },
        .assignment_expr => {
            const data = ctx.nodeData(expr);
            const lhs = try renderExpr(ctx, data.binary.lhs);
            const rhs = try renderExpr(ctx, data.binary.rhs);
            const op = ctx.ast.operator_overrides.get(@intFromEnum(expr)) orelse "=";
            return std.fmt.allocPrint(ctx.allocator, "{s} {s} {s}", .{ lhs, op, rhs });
        },
        .call_expr => {
            if (ctx.ast.replacement_source.get(@intFromEnum(expr))) |replacement| {
                return ctx.allocator.dupe(u8, replacement);
            }
            const data = ctx.nodeData(expr);
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 >= ctx.ast.extra_data.items.len) {
                return ctx.allocator.dupe(u8, getNodeSource(ctx, expr));
            }
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const args_start: usize = @intCast(ctx.ast.extra_data.items[extra_idx + 1]);
            const args_end: usize = @intCast(ctx.ast.extra_data.items[extra_idx + 2]);
            const callee_src = if (callee != .none and ctx.nodeTag(callee) == .super_expr)
                "super"
            else
                try renderExpr(ctx, callee);
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(ctx.allocator, callee_src);
            try buf.append(ctx.allocator, '(');
            if (args_start <= args_end and args_end <= ctx.ast.extra_data.items.len) {
                for (ctx.ast.extra_data.items[args_start..args_end], 0..) |arg_raw, i| {
                    if (i > 0) try buf.appendSlice(ctx.allocator, ", ");
                    try buf.appendSlice(ctx.allocator, try renderExpr(ctx, @enumFromInt(arg_raw)));
                }
            }
            try buf.append(ctx.allocator, ')');
            return buf.items;
        },
        else => {
            const ni = @intFromEnum(expr);
            if (ni < ctx.ast.nodes.items(.end_offset).len) {
                const start = nodeStartOffset(ctx, expr);
                const end = ctx.ast.nodes.items(.end_offset)[ni];
                if (start < end and end <= ctx.ast.source.len) {
                    return ctx.allocator.dupe(u8, getNodeSource(ctx, expr));
                }
            }
            return ctx.allocator.dupe(u8, getNodeSource(ctx, expr));
        },
    }
}

fn renderArrowParamRange(ctx: *TransformContext, params: []const u32) anyerror![]const u8 {
    if (params.len == 1) {
        return renderArrowParamList(ctx, &.{@enumFromInt(params[0])});
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(ctx.allocator, '(');
    for (params, 0..) |param_raw, i| {
        if (i > 0) try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, try renderExpr(ctx, @enumFromInt(param_raw)));
    }
    try buf.append(ctx.allocator, ')');
    return buf.items;
}

fn renderArrowParamList(ctx: *TransformContext, params: []const NodeIndex) anyerror![]const u8 {
    if (params.len == 1 and arrowParamCanOmitParens(ctx, params[0])) {
        return renderExpr(ctx, params[0]);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(ctx.allocator, '(');
    for (params, 0..) |param, i| {
        if (i > 0) try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, try renderExpr(ctx, param));
    }
    try buf.append(ctx.allocator, ')');
    return buf.items;
}

fn arrowParamCanOmitParens(ctx: *TransformContext, param: NodeIndex) bool {
    if (param == .none) return false;
    return switch (ctx.nodeTag(param)) {
        .identifier => true,
        else => false,
    };
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

const SuperStatement = struct {
    text: []const u8,
    end: usize,
};

fn extractLeadingSuperStatement(body: []const u8) ?SuperStatement {
    const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
    const offset = body.len - trimmed.len;
    if (!std.mem.startsWith(u8, trimmed, "super")) return null;
    const end = std.mem.indexOfScalar(u8, trimmed, ';') orelse return null;
    return .{
        .text = trimmed[0 .. end + 1],
        .end = offset + end + 1,
    };
}

fn renderCallSuperExpr(ctx: *TransformContext, class_name: []const u8, super_stmt: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, super_stmt, " \t\r\n");

    if (std.mem.eql(u8, trimmed, "super();")) {
        return std.fmt.allocPrint(ctx.allocator, "babelHelpers.callSuper(this, {s})", .{class_name});
    }

    if (std.mem.startsWith(u8, trimmed, "super.apply(void 0, ") and std.mem.endsWith(u8, trimmed, ");")) {
        const args = trimmed["super.apply(void 0, ".len .. trimmed.len - 2];
        return std.fmt.allocPrint(ctx.allocator, "babelHelpers.callSuper(this, {s}, {s})", .{ class_name, args });
    }

    if (std.mem.startsWith(u8, trimmed, "super(") and std.mem.endsWith(u8, trimmed, ");")) {
        const args = std.mem.trim(u8, trimmed["super(".len .. trimmed.len - 2], " \t\r\n");
        if (args.len == 0) {
            return std.fmt.allocPrint(ctx.allocator, "babelHelpers.callSuper(this, {s})", .{class_name});
        }
        if (std.mem.eql(u8, args, "...arguments")) {
            return std.fmt.allocPrint(ctx.allocator, "babelHelpers.callSuper(this, {s}, arguments)", .{class_name});
        }
        if (std.mem.startsWith(u8, args, "...")) {
            const spread_arg = std.mem.trim(u8, args[3..], " \t\r\n");
            return std.fmt.allocPrint(
                ctx.allocator,
                "babelHelpers.callSuper(this, {s}, babelHelpers.toConsumableArray({s}))",
                .{ class_name, spread_arg },
            );
        }
        return std.fmt.allocPrint(ctx.allocator, "babelHelpers.callSuper(this, {s}, [{s}])", .{ class_name, args });
    }

    return std.fmt.allocPrint(ctx.allocator, "babelHelpers.callSuper(this, {s}, arguments)", .{class_name});
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
            try buf.appendSlice(allocator, replacement);
            i += needle.len;
            changed = true;
            continue;
        }

        try buf.append(allocator, source[i]);
        i += 1;
    }

    if (!changed) return source;
    return buf.items;
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
