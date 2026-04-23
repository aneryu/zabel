const std = @import("std");
const Codegen = @import("codegen.zig").Codegen;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const ExtraIndex = @import("ast.zig").ExtraIndex;
const TokenIndex = @import("ast.zig").TokenIndex;

pub fn emitFlowNode(cg: *Codegen, tag: Node.Tag, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) !void {
    switch (tag) {
        // === Flow Type Annotation ===
        // data.unary = typeAnnotation
        .flow_type_annotation => {
            try cg.writeStr(": ");
            try cg.emitNode(data.unary);
        },

        // === Flow Generic Type ===
        // extra: [id_node, type_params]
        .flow_generic_type => {
            const extra_idx = @intFromEnum(data.extra);
            const id_node: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            try cg.emitNode(id_node);
            if (type_params != .none) {
                try cg.emitNode(type_params);
            }
        },

        // === Flow Qualified Type Identifier ===
        // extra: [qualification, member_token]
        .flow_qualified_type_identifier => {
            const extra_idx = @intFromEnum(data.extra);
            const qualification: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            // member_token at extra_idx + 1 (unused for codegen, we use main_token)
            try cg.emitNode(qualification);
            try cg.writeChar('.');
            try cg.emitToken(main_token);
        },

        // === Flow Nullable Type ===
        // data.unary = typeAnnotation
        .flow_nullable_type => {
            try cg.writeChar('?');
            try cg.emitNode(data.unary);
        },

        // === Flow Union Type ===
        // extra: [range_start, range_end]
        .flow_union_type => {
            try emitSeparatedTypes(cg, data, " | ");
        },

        // === Flow Intersection Type ===
        // extra: [range_start, range_end]
        .flow_intersection_type => {
            try emitSeparatedTypes(cg, data, " & ");
        },

        // === Flow Typeof Type ===
        // data.unary = argument
        .flow_typeof_type => {
            try cg.writeStr("typeof ");
            try cg.emitNode(data.unary);
        },

        // === Flow Array Type ===
        // data.unary = elementType
        .flow_array_type => {
            try cg.emitNode(data.unary);
            try cg.writeStr("[]");
        },

        // === Flow Tuple Type ===
        // extra: [range_start, range_end]
        .flow_tuple_type => {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = cg.ast.extra_data.items[extra_idx];
            const range_end = cg.ast.extra_data.items[extra_idx + 1];
            try cg.writeChar('[');
            try cg.emitCommaSeparated(range_start, range_end);
            try cg.writeChar(']');
        },

        // === Flow Keyword Types ===
        .flow_number_type => try cg.writeStr("number"),
        .flow_string_type => try cg.writeStr("string"),
        .flow_boolean_type => try cg.writeStr("boolean"),
        .flow_void_type => try cg.writeStr("void"),
        .flow_mixed_type => try cg.writeStr("mixed"),
        .flow_empty_type => try cg.writeStr("empty"),
        .flow_any_type => try cg.writeStr("any"),
        .flow_symbol_type => try cg.writeStr("symbol"),
        .flow_bigint_type => try cg.writeStr("bigint"),
        .flow_null_literal_type => try cg.writeStr("null"),
        .flow_this_type_annotation => try cg.writeStr("this"),
        .flow_exists_type => try cg.writeChar('*'),

        // === Flow Literal Types ===
        // main_token has the literal value
        .flow_number_literal_type => try cg.emitToken(main_token),
        .flow_string_literal_type => try cg.emitToken(main_token),
        .flow_boolean_literal_type => try cg.emitToken(main_token),
        .flow_bigint_literal_type => try cg.emitToken(main_token),

        // === Flow Object Type / Exact Object Type ===
        // extra: [range_start, range_end, inexact_flag]
        .flow_object_type, .flow_exact_object_type => {
            try emitFlowObjectType(cg, tag, data);
        },

        // === Flow Object Type Property ===
        // extra: [value_or_func, key_token, variance_token, flags]
        // flags: bit 0 = optional, bit 1 = static, bit 2 = proto, bit 3 = getter, bit 4 = setter,
        //        bit 5 = plus variance, bit 6 = minus variance, bit 7 = method
        .flow_object_type_property => {
            try emitFlowObjectTypeProperty(cg, idx, data);
        },

        // === Flow Object Type Spread Property ===
        // data.unary = argument
        .flow_object_type_spread_property => {
            try cg.writeStr("...");
            try cg.emitNode(data.unary);
        },

        // === Flow Object Type Indexer ===
        // extra: [name_token, key_type, value_type, flags]
        .flow_object_type_indexer => {
            try emitFlowObjectTypeIndexer(cg, idx, data);
        },

        // === Flow Object Type Call Property ===
        // extra: [func_type, flags]
        .flow_object_type_call_property => {
            const extra_idx = @intFromEnum(data.extra);
            const func_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const flags = cg.ast.extra_data.items[extra_idx + 1];
            const is_static = (flags & 1) != 0;
            if (is_static) {
                try cg.writeStr("static ");
            }
            // Call properties use ":" for return type, not "=>"
            try emitFlowFunctionTypeAnnotation(cg, func_type, true);
        },

        // === Flow Object Type Internal Slot ===
        // extra: [name_token, value_type, flags]
        .flow_object_type_internal_slot => {
            try emitFlowObjectTypeInternalSlot(cg, data);
        },

        // === Flow Type Alias ===
        // extra: [name_token, type_params, right]
        .flow_type_alias => {
            try emitFlowTypeAlias(cg, data, false);
        },

        // === Flow Declare Type Alias ===
        .flow_declare_type_alias => {
            try cg.writeStr("declare ");
            try emitFlowTypeAlias(cg, data, false);
        },

        // === Flow Opaque Type ===
        // extra: [name_token, type_params, supertype, impl_type]
        .flow_opaque_type => {
            try emitFlowOpaqueType(cg, data);
        },

        // === Flow Interface Declaration ===
        // extra: [name_token, type_params, extends_start, extends_end, body]
        .flow_interface_declaration => {
            try cg.writeStr("interface ");
            try emitInterfaceish(cg, data);
        },

        // === Flow Interface Body ===
        // Same data layout as flow_object_type: [range_start, range_end, ...]
        .flow_interface_body => {
            // Interface body in Flow is an ObjectTypeAnnotation — emit as object type
            try emitFlowObjectType(cg, .flow_object_type, data);
        },

        // === Flow Interface Extends ===
        // extra: [id, type_params]
        .flow_interface_extends => {
            const extra_idx = @intFromEnum(data.extra);
            const id: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            try cg.emitNode(id);
            if (type_params != .none) {
                try cg.emitNode(type_params);
            }
        },

        // === Flow Declare Class ===
        // extra: [name_token, type_params, extends_start, extends_end, impl_start, impl_end, body, mixins_start, mixins_end]
        .flow_declare_class => {
            try emitFlowDeclareClass(cg, idx, data);
        },

        // === Flow Declare Function ===
        // extra: [name_token, type_params_node, func_type, predicate]
        .flow_declare_function => {
            try emitFlowDeclareFunction(cg, idx, data);
        },

        // === Flow Declare Variable ===
        // extra: [kind_token, name_token, type_annotation]
        .flow_declare_variable => {
            try emitFlowDeclareVariable(cg, data);
        },

        // === Flow Declare Module ===
        // extra: [name_token, lbrace_token, range_start, range_end]
        .flow_declare_module => {
            try emitFlowDeclareModule(cg, data);
        },

        // === Flow Declare Module Exports ===
        // extra: [colon_token, type_node]
        .flow_declare_module_exports => {
            const extra_idx = @intFromEnum(data.extra);
            // colon_token at extra_idx (unused for codegen)
            const type_node: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            try cg.writeStr("declare module.exports: ");
            try cg.emitNode(type_node);
        },

        // === Flow Declare Export Declaration ===
        // extra: [declaration, flags, source_token, specs_start, specs_end]
        .flow_declare_export_declaration => {
            try emitFlowDeclareExportDeclaration(cg, data);
        },

        // === Flow Declare Export All Declaration ===
        // extra: [source_token, export_kind_flag]
        .flow_declare_export_all_declaration => {
            const extra_idx = @intFromEnum(data.extra);
            const source_token_raw = cg.ast.extra_data.items[extra_idx];
            const export_kind_flag = cg.ast.extra_data.items[extra_idx + 1];
            const source_tok: TokenIndex = @enumFromInt(source_token_raw);
            if (export_kind_flag != 0) {
                try cg.writeStr("declare export type * from ");
            } else {
                try cg.writeStr("declare export * from ");
            }
            try cg.emitToken(source_tok);
            try cg.semicolon();
        },

        // === Flow Declare Interface ===
        // extra: [name_token, type_params, extends_start, extends_end, body]
        .flow_declare_interface => {
            try cg.writeStr("declare ");
            try cg.writeStr("interface ");
            try emitInterfaceish(cg, data);
        },

        // === Flow Declare Opaque Type ===
        // extra: [name_token, type_params, supertype, impl_type]
        .flow_declare_opaque_type => {
            try emitFlowDeclareOpaqueType(cg, idx, data);
        },

        // === Flow Type Parameter ===
        // extra: [bound, default_type, variance_flag, variance_token]
        .flow_type_parameter => {
            try emitFlowTypeParameter(cg, main_token, data);
        },

        // === Flow Type Parameter Declaration / Instantiation ===
        // extra: [range_start, range_end]
        .flow_type_parameter_declaration, .flow_type_parameter_instantiation => {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = cg.ast.extra_data.items[extra_idx];
            const range_end = cg.ast.extra_data.items[extra_idx + 1];
            try cg.writeChar('<');
            try cg.emitCommaSeparated(range_start, range_end);
            try cg.writeChar('>');
        },

        // === Flow Type Cast Expression ===
        // extra: [expr, type]
        .flow_type_cast_expression => {
            const extra_idx = @intFromEnum(data.extra);
            const expr: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const ty: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            try cg.writeChar('(');
            // Clear expression_statement/arrow_body context since we're inside parens
            cg.token_context.expression_statement = false;
            cg.token_context.arrow_body = false;
            try cg.emitNode(expr);
            try cg.writeStr(": ");
            try cg.emitNode(ty);
            try cg.writeChar(')');
        },

        // === Flow Function Type Annotation ===
        // extra: [params_start, params_end, return_type, rest_param, type_params, this_param]
        .flow_function_type_annotation => {
            try emitFlowFunctionTypeAnnotation(cg, idx, false);
        },

        // === Flow Function Type Param ===
        // extra: [type, flags]  flags: bit 0 = optional, bit 1 = unnamed
        .flow_function_type_param => {
            try emitFlowFunctionTypeParam(cg, main_token, data);
        },

        // === Flow Indexed Access Type ===
        // extra: [object_type, index_type]
        .flow_indexed_access_type => {
            const extra_idx = @intFromEnum(data.extra);
            const object_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const index_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            try cg.emitNode(object_type);
            try cg.writeChar('[');
            try cg.emitNode(index_type);
            try cg.writeChar(']');
        },

        // === Flow Optional Indexed Access Type ===
        // extra: [object_type, index_type]; main_token tag == optional_chain means optional
        .flow_optional_indexed_access_type => {
            const extra_idx = @intFromEnum(data.extra);
            const object_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const index_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            try cg.emitNode(object_type);
            const mt_tag = cg.ast.tokens.items(.tag)[@intFromEnum(main_token)];
            if (mt_tag == .optional_chain) {
                try cg.writeStr("?.");
            }
            try cg.writeChar('[');
            try cg.emitNode(index_type);
            try cg.writeChar(']');
        },

        // === Flow Inferred Predicate ===
        .flow_inferred_predicate => {
            try cg.writeStr("%checks");
        },

        // === Flow Declared Predicate ===
        // data.unary = value
        .flow_declared_predicate => {
            try cg.writeStr("%checks(");
            try cg.emitNode(data.unary);
            try cg.writeChar(')');
        },

        // === Flow Interface Type Annotation ===
        // extra: [extends_start, extends_end, body]
        .flow_interface_type_annotation => {
            const extra_idx = @intFromEnum(data.extra);
            const extends_start = cg.ast.extra_data.items[extra_idx];
            const extends_end = cg.ast.extra_data.items[extra_idx + 1];
            const body: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);

            try cg.writeStr("interface");
            if (extends_start < extends_end) {
                try cg.writeStr(" extends ");
                const ext_items = cg.ast.extra_data.items[extends_start..extends_end];
                for (ext_items, 0..) |item, i| {
                    if (i > 0) try cg.writeStr(", ");
                    try cg.emitNode(@enumFromInt(item));
                }
            }
            try cg.space();
            try cg.emitNode(body);
        },

        // === Flow Variance ===
        // main_token = + or -
        .flow_variance => {
            try cg.emitToken(main_token);
        },

        // === Flow Parenthesized Type ===
        // data.unary = inner type
        .flow_parenthesized_type => {
            if (cg.ast.create_parenthesized_expressions) {
                try cg.writeChar('(');
                try cg.emitNode(data.unary);
                try cg.writeChar(')');
            } else {
                // Transparent: emit the inner type, but restore parent context
                // so that needsParens on the inner type sees the correct ancestor
                try cg.emitNode(data.unary);
            }
        },

        // === Flow Enum Declaration ===
        // extra: [name_token, body]
        .flow_enum_declaration => {
            const extra_idx = @intFromEnum(data.extra);
            const name_token_raw = cg.ast.extra_data.items[extra_idx];
            const body: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            try cg.writeStr("enum ");
            try cg.emitToken(@enumFromInt(name_token_raw));
            try cg.emitNode(body);
        },

        // === Flow Enum Bodies ===
        // extra: [range_start, range_end, has_unknown, explicit_type]
        .flow_enum_boolean_body => try emitFlowEnumBody(cg, data, "boolean"),
        .flow_enum_number_body => try emitFlowEnumBody(cg, data, "number"),
        .flow_enum_string_body => try emitFlowEnumBody(cg, data, "string"),
        .flow_enum_symbol_body => try emitFlowEnumBody(cg, data, "symbol"),

        // === Flow Enum Members ===
        // main_token = name; data.token = value token
        .flow_enum_boolean_member,
        .flow_enum_number_member,
        .flow_enum_string_member,
        => {
            try cg.emitToken(main_token);
            try cg.writeStr(" = ");
            try cg.emitToken(data.token);
            try cg.writeChar(',');
        },

        // === Flow Enum Default Member ===
        // main_token = name, no initializer
        .flow_enum_default_member => {
            try cg.emitToken(main_token);
            try cg.writeChar(',');
        },

        else => {},
    }
}

// ---------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------

/// Emit a declaration node from within declare export, without the leading "declare " keyword
fn emitFlowDeclareChild(cg: *Codegen, decl_idx: NodeIndex, decl_tag: Node.Tag) !void {
    const decl_data = cg.ast.nodes.items(.data)[@intFromEnum(decl_idx)];
    switch (decl_tag) {
        .flow_declare_class => try emitFlowDeclareClassInner(cg, decl_idx, decl_data, false),
        .flow_declare_function => try emitFlowDeclareFunctionInner(cg, decl_idx, decl_data, false),
        .flow_declare_variable => try emitFlowDeclareVariableInner(cg, decl_data, false),
        .flow_declare_opaque_type => try emitFlowDeclareOpaqueTypeInner(cg, decl_idx, decl_data, false),
        else => try cg.emitNode(decl_idx),
    }
}

/// Emit types separated by a given separator (e.g., " | " or " & ")
fn emitSeparatedTypes(cg: *Codegen, data: Node.Data, separator: []const u8) !void {
    const extra_idx = @intFromEnum(data.extra);
    const range_start = cg.ast.extra_data.items[extra_idx];
    const range_end = cg.ast.extra_data.items[extra_idx + 1];
    const items = cg.ast.extra_data.items[range_start..range_end];
    for (items, 0..) |item, i| {
        if (i > 0) try cg.writeStr(separator);
        try cg.emitNode(@enumFromInt(item));
    }
}

/// Emit a Flow object type: { ... } or {| ... |}
fn emitFlowObjectType(cg: *Codegen, tag: Node.Tag, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const range_start = cg.ast.extra_data.items[extra_idx];
    const range_end = cg.ast.extra_data.items[extra_idx + 1];
    const inexact_flag = cg.ast.extra_data.items[extra_idx + 2];
    const is_exact = tag == .flow_exact_object_type;

    const items = cg.ast.extra_data.items[range_start..range_end];
    const has_props = items.len > 0;
    const is_inexact = inexact_flag != 0;
    const needs_separator = items.len != 1 or is_inexact;

    if (is_exact) {
        try cg.writeStr("{|");
    } else {
        try cg.writeChar('{');
    }

    if (has_props) {
        // Babel reorders: properties + spreads first, then call properties,
        // then indexers, then internal slots
        // Build ordered list
        var ordered: [256]u32 = undefined;
        var ordered_len: usize = 0;

        // 1. Properties and spread properties
        for (items) |item| {
            const item_tag = cg.ast.nodes.items(.tag)[@intFromEnum(@as(NodeIndex, @enumFromInt(item)))];
            if (item_tag == .flow_object_type_property or item_tag == .flow_object_type_spread_property) {
                if (ordered_len < ordered.len) {
                    ordered[ordered_len] = item;
                    ordered_len += 1;
                }
            }
        }
        // 2. Call properties
        for (items) |item| {
            const item_tag = cg.ast.nodes.items(.tag)[@intFromEnum(@as(NodeIndex, @enumFromInt(item)))];
            if (item_tag == .flow_object_type_call_property) {
                if (ordered_len < ordered.len) {
                    ordered[ordered_len] = item;
                    ordered_len += 1;
                }
            }
        }
        // 3. Indexers
        for (items) |item| {
            const item_tag = cg.ast.nodes.items(.tag)[@intFromEnum(@as(NodeIndex, @enumFromInt(item)))];
            if (item_tag == .flow_object_type_indexer) {
                if (ordered_len < ordered.len) {
                    ordered[ordered_len] = item;
                    ordered_len += 1;
                }
            }
        }
        // 4. Internal slots
        for (items) |item| {
            const item_tag = cg.ast.nodes.items(.tag)[@intFromEnum(@as(NodeIndex, @enumFromInt(item)))];
            if (item_tag == .flow_object_type_internal_slot) {
                if (ordered_len < ordered.len) {
                    ordered[ordered_len] = item;
                    ordered_len += 1;
                }
            }
        }

        const emit_items = ordered[0..ordered_len];

        try cg.newline();
        cg.indent();
        for (emit_items, 0..) |item, i| {
            if (i > 0 and needs_separator) {
                try cg.writeChar(',');
            }
            if (i > 0) {
                try cg.newline();
            }
            try cg.writeIndent();
            try cg.emitNode(@enumFromInt(item));
        }
        // Trailing comma for multi-member or inexact objects
        if (needs_separator) {
            try cg.writeChar(',');
        }
        try cg.newline();
        cg.dedent();
    }

    if (is_inexact) {
        if (has_props) {
            // After props with trailing comma, add ... on its own line
            cg.indent();
            try cg.writeIndent();
            try cg.writeStr("...");
            try cg.newline();
            cg.dedent();
        } else {
            // No props — inline: {...}
            try cg.writeStr("...");
        }
    }

    if (is_exact) {
        if (has_props or (is_inexact and has_props)) try cg.writeIndent();
        try cg.writeStr("|}");
    } else {
        if (has_props) try cg.writeIndent();
        try cg.writeChar('}');
    }
}

/// Emit a Flow object type property
fn emitFlowObjectTypeProperty(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const value_or_func: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const key_token_raw = cg.ast.extra_data.items[extra_idx + 1];
    // variance_token at extra_idx + 2
    const flags = cg.ast.extra_data.items[extra_idx + 3];
    const is_optional = (flags & 1) != 0;
    const is_static = (flags & 2) != 0;
    const is_proto = (flags & 4) != 0;
    const is_getter = (flags & 8) != 0;
    const is_setter = (flags & 16) != 0;
    const is_plus_variance = (flags & 32) != 0;
    const is_minus_variance = (flags & 64) != 0;
    const is_method = (flags & 128) != 0;

    if (is_proto) {
        try cg.writeStr("proto ");
    }
    if (is_static) {
        try cg.writeStr("static ");
    }
    if (is_getter) {
        try cg.writeStr("get ");
    } else if (is_setter) {
        try cg.writeStr("set ");
    }

    // Variance
    if (!is_method) {
        if (is_plus_variance) {
            try cg.writeChar('+');
        } else if (is_minus_variance) {
            try cg.writeChar('-');
        }
    }

    // Key
    const key_token: TokenIndex = @enumFromInt(key_token_raw);
    try cg.emitToken(key_token);

    // Optional
    if (is_optional) {
        try cg.writeChar('?');
    }

    // Colon and value (or method value directly)
    if (is_method) {
        // For methods, emit function type annotation with colon separator
        try emitFlowFunctionTypeAnnotation(cg, value_or_func, true);
    } else {
        try cg.writeStr(": ");
        try cg.emitNode(value_or_func);
    }
    _ = idx;
}

/// Emit a Flow object type indexer
fn emitFlowObjectTypeIndexer(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    const key_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const value_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
    const flags = if (extra_idx + 3 < cg.ast.extra_data.items.len)
        cg.ast.extra_data.items[extra_idx + 3]
    else
        @as(u32, 0);
    const is_static = (flags & 1) != 0;

    if (is_static) {
        try cg.writeStr("static ");
    }

    // Variance from side table
    if (cg.ast.variance_map.get(@intFromEnum(idx))) |var_node| {
        try cg.emitNode(var_node);
    }

    try cg.writeChar('[');
    if (name_token_raw != 0) {
        const name_tok: TokenIndex = @enumFromInt(name_token_raw);
        try cg.emitToken(name_tok);
        try cg.writeStr(": ");
    }
    try cg.emitNode(key_type);
    try cg.writeChar(']');
    try cg.writeStr(": ");
    try cg.emitNode(value_type);
}

/// Emit a Flow object type internal slot
fn emitFlowObjectTypeInternalSlot(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    const value_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const flags = cg.ast.extra_data.items[extra_idx + 2];
    const is_optional = (flags & 1) != 0;
    const is_static = (flags & 2) != 0;
    const is_method = cg.ast.nodes.items(.tag)[@intFromEnum(value_type)] == .flow_function_type_annotation;

    if (is_static) {
        try cg.writeStr("static ");
    }

    const name_tok: TokenIndex = @enumFromInt(name_token_raw);
    try cg.writeStr("[[");
    try cg.emitToken(name_tok);
    try cg.writeStr("]]");

    if (is_optional) {
        try cg.writeChar('?');
    }

    if (is_method) {
        // Method internal slots use ":" for return type
        try emitFlowFunctionTypeAnnotation(cg, value_type, true);
    } else {
        try cg.writeStr(": ");
        try cg.emitNode(value_type);
    }
}

/// Emit a Flow type alias: type Name<Params> = Right;
fn emitFlowTypeAlias(cg: *Codegen, data: Node.Data, _: bool) !void {
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const right: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);

    try cg.writeStr("type ");
    try cg.emitToken(@enumFromInt(name_token_raw));
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    try cg.writeStr(" = ");
    try cg.emitNode(right);
    try cg.semicolon();
}

/// Emit a Flow opaque type: opaque type Name<Params>: Super = Impl;
fn emitFlowOpaqueType(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const supertype: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
    const impl_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 3]);

    try cg.writeStr("opaque type ");
    try cg.emitToken(@enumFromInt(name_token_raw));
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    if (supertype != .none) {
        try cg.writeStr(": ");
        try cg.emitNode(supertype);
    }
    if (impl_type != .none) {
        try cg.writeStr(" = ");
        try cg.emitNode(impl_type);
    }
    try cg.semicolon();
}

/// Emit interfaceish: name + type params + extends + body
fn emitInterfaceish(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const extends_start = cg.ast.extra_data.items[extra_idx + 2];
    const extends_end = cg.ast.extra_data.items[extra_idx + 3];
    const body: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 4]);

    try cg.emitToken(@enumFromInt(name_token_raw));
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    if (extends_start < extends_end) {
        try cg.writeStr(" extends ");
        const ext_items = cg.ast.extra_data.items[extends_start..extends_end];
        for (ext_items, 0..) |item, i| {
            if (i > 0) try cg.writeStr(", ");
            try cg.emitNode(@enumFromInt(item));
        }
    }
    try cg.space();
    try cg.emitNode(body);
}

/// Emit a Flow declare class
fn emitFlowDeclareClass(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    return emitFlowDeclareClassInner(cg, idx, data, true);
}

fn emitFlowDeclareClassInner(cg: *Codegen, idx: NodeIndex, data: Node.Data, emit_declare: bool) !void {
    _ = idx;
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const extends_start = cg.ast.extra_data.items[extra_idx + 2];
    const extends_end = cg.ast.extra_data.items[extra_idx + 3];
    const impl_start = cg.ast.extra_data.items[extra_idx + 4];
    const impl_end = cg.ast.extra_data.items[extra_idx + 5];
    const body: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 6]);
    const mixins_start = cg.ast.extra_data.items[extra_idx + 7];
    const mixins_end = cg.ast.extra_data.items[extra_idx + 8];

    if (emit_declare) {
        try cg.writeStr("declare ");
    }
    try cg.writeStr("class ");
    try cg.emitToken(@enumFromInt(name_token_raw));
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    if (extends_start < extends_end) {
        try cg.writeStr(" extends ");
        const ext_items = cg.ast.extra_data.items[extends_start..extends_end];
        for (ext_items, 0..) |item, i| {
            if (i > 0) try cg.writeStr(", ");
            try cg.emitNode(@enumFromInt(item));
        }
    }
    if (mixins_start < mixins_end) {
        try cg.writeStr(" mixins ");
        const mixin_items = cg.ast.extra_data.items[mixins_start..mixins_end];
        for (mixin_items, 0..) |item, i| {
            if (i > 0) try cg.writeStr(", ");
            try cg.emitNode(@enumFromInt(item));
        }
    }
    if (impl_start < impl_end) {
        try cg.writeStr(" implements ");
        const impl_items = cg.ast.extra_data.items[impl_start..impl_end];
        for (impl_items, 0..) |item, i| {
            if (i > 0) try cg.writeStr(", ");
            try cg.emitNode(@enumFromInt(item));
        }
    }
    try cg.space();
    try cg.emitNode(body);
}

/// Emit a Flow declare function
fn emitFlowDeclareFunction(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    return emitFlowDeclareFunctionInner(cg, idx, data, true);
}

fn emitFlowDeclareFunctionInner(cg: *Codegen, idx: NodeIndex, data: Node.Data, emit_declare: bool) !void {
    _ = idx;
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    // type_params_node at extra_idx + 1 (unused in codegen — type params are part of func_type)
    const func_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
    const predicate: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 3]);

    if (emit_declare) {
        try cg.writeStr("declare ");
    }
    try cg.writeStr("function ");
    try cg.emitToken(@enumFromInt(name_token_raw));

    // Emit the function type annotation directly (without wrapping ": ...")
    // The FunctionTypeAnnotation in DeclareFunction uses ":" not "=>" for return
    if (func_type != .none) {
        try emitFlowFunctionTypeAnnotation(cg, func_type, true);
    }

    if (predicate != .none) {
        try cg.space();
        try cg.emitNode(predicate);
    }

    try cg.semicolon();
}

/// Emit a Flow declare variable
fn emitFlowDeclareVariable(cg: *Codegen, data: Node.Data) !void {
    return emitFlowDeclareVariableInner(cg, data, true);
}

fn emitFlowDeclareVariableInner(cg: *Codegen, data: Node.Data, emit_declare: bool) !void {
    const extra_idx = @intFromEnum(data.extra);
    // kind_token at extra_idx (unused — always "var" in codegen)
    const name_token_raw = cg.ast.extra_data.items[extra_idx + 1];
    const type_annotation: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);

    if (emit_declare) {
        try cg.writeStr("declare ");
    }
    try cg.writeStr("var ");
    try cg.emitToken(@enumFromInt(name_token_raw));
    if (type_annotation != .none) {
        try cg.emitNode(type_annotation);
    }
    try cg.semicolon();
}

/// Emit a Flow declare module
fn emitFlowDeclareModule(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    // lbrace_token at extra_idx + 1 (unused)
    const range_start = cg.ast.extra_data.items[extra_idx + 2];
    const range_end = cg.ast.extra_data.items[extra_idx + 3];

    try cg.writeStr("declare module ");
    try cg.emitToken(@enumFromInt(name_token_raw));
    try cg.space();

    // Emit body as block
    const body_items = cg.ast.extra_data.items[range_start..range_end];
    if (body_items.len == 0) {
        try cg.writeStr("{}");
    } else {
        try cg.writeStr("{\n");
        cg.indent();
        for (body_items) |item| {
            try cg.writeIndent();
            try cg.emitNode(@enumFromInt(item));
            try cg.newline();
        }
        cg.dedent();
        try cg.writeIndent();
        try cg.writeChar('}');
    }
}

/// Emit a Flow declare export declaration
fn emitFlowDeclareExportDeclaration(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const declaration: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const flags = cg.ast.extra_data.items[extra_idx + 1];
    const source_token_raw = cg.ast.extra_data.items[extra_idx + 2];
    const specs_start = cg.ast.extra_data.items[extra_idx + 3];
    const specs_end = cg.ast.extra_data.items[extra_idx + 4];
    const is_default = (flags & 1) != 0;

    try cg.writeStr("declare export ");
    if (is_default) {
        try cg.writeStr("default ");
    }

    const has_specifiers = specs_start < specs_end;

    if (has_specifiers) {
        // Named exports: export { x, y } from 'source'
        try cg.writeChar('{');
        const specs = cg.ast.extra_data.items[specs_start..specs_end];
        if (specs.len > 0) {
            try cg.space();
            for (specs, 0..) |s, j| {
                if (j > 0) try cg.writeStr(", ");
                try cg.emitNode(@enumFromInt(s));
            }
            try cg.space();
        }
        try cg.writeChar('}');

        if (source_token_raw != 0) {
            try cg.writeStr(" from ");
            try cg.emitToken(@enumFromInt(source_token_raw));
        }
        try cg.semicolon();
    } else if (declaration != .none) {
        // Has a declaration
        const decl_tag = cg.ast.nodes.items(.tag)[@intFromEnum(declaration)];
        // For declarations that start with "declare", emit without that prefix
        // by calling their specific handlers which check parent context.
        // We use emitFlowDeclareChild which skips the "declare " keyword.
        switch (decl_tag) {
            .flow_declare_class,
            .flow_declare_function,
            .flow_declare_variable,
            .flow_declare_opaque_type,
            => try emitFlowDeclareChild(cg, declaration, decl_tag),
            else => {
                try cg.emitNode(declaration);
                // Check if the declaration is NOT a statement (needs semicolon)
                const is_stmt = switch (decl_tag) {
                    .flow_type_alias,
                    .flow_opaque_type,
                    .flow_interface_declaration,
                    .flow_declare_interface,
                    => true,
                    else => false,
                };
                if (!is_stmt) {
                    try cg.semicolon();
                }
            },
        }
    } else {
        // Empty export
        try cg.writeStr("{}");
        try cg.semicolon();
    }
}

/// Emit a Flow declare opaque type
fn emitFlowDeclareOpaqueType(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    return emitFlowDeclareOpaqueTypeInner(cg, idx, data, true);
}

fn emitFlowDeclareOpaqueTypeInner(cg: *Codegen, idx: NodeIndex, data: Node.Data, emit_declare: bool) !void {
    _ = idx;
    const extra_idx = @intFromEnum(data.extra);
    const name_token_raw = cg.ast.extra_data.items[extra_idx];
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const supertype: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
    const impl_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 3]);

    if (emit_declare) {
        try cg.writeStr("declare ");
    }
    try cg.writeStr("opaque type ");
    try cg.emitToken(@enumFromInt(name_token_raw));
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    if (supertype != .none) {
        try cg.writeStr(": ");
        try cg.emitNode(supertype);
    }
    if (impl_type != .none) {
        try cg.writeStr(" = ");
        try cg.emitNode(impl_type);
    }
    try cg.semicolon();
}

/// Emit a Flow type parameter
fn emitFlowTypeParameter(cg: *Codegen, main_token: TokenIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const bound: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const default_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const variance_flag = cg.ast.extra_data.items[extra_idx + 2];
    // variance_token at extra_idx + 3

    // Variance
    if (variance_flag == 1) {
        try cg.writeChar('+');
    } else if (variance_flag == 2) {
        try cg.writeChar('-');
    }

    // Name: if variance is present, main_token is variance token, name is next
    const name_token = if (variance_flag != 0)
        @as(TokenIndex, @enumFromInt(@intFromEnum(main_token) + 1))
    else
        main_token;
    try cg.emitToken(name_token);

    // Bound (type annotation like ": Type")
    if (bound != .none) {
        try cg.emitNode(bound);
    }

    // Default
    if (default_type != .none) {
        try cg.writeStr(" = ");
        try cg.emitNode(default_type);
    }
}

/// Emit a Flow function type annotation
/// When `is_method_context` is true, emit `:` instead of `=>` for return type
fn emitFlowFunctionTypeAnnotation(cg: *Codegen, idx: NodeIndex, is_method_context: bool) !void {
    const func_data = cg.ast.nodes.items(.data)[@intFromEnum(idx)];
    const extra_idx = @intFromEnum(func_data.extra);
    const params_start = cg.ast.extra_data.items[extra_idx];
    const params_end = cg.ast.extra_data.items[extra_idx + 1];
    const return_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
    const rest_param: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 3]);
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 4]);
    const this_param: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 5]);

    // Type parameters
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }

    // Parameters
    try cg.writeChar('(');

    var has_params = false;

    // 'this' parameter
    if (this_param != .none) {
        try cg.writeStr("this: ");
        // this_param is a FunctionTypeParam — emit its typeAnnotation
        const this_data = cg.ast.nodes.items(.data)[@intFromEnum(this_param)];
        const this_extra = @intFromEnum(this_data.extra);
        const this_ty: NodeIndex = @enumFromInt(cg.ast.extra_data.items[this_extra]);
        try cg.emitNode(this_ty);
        has_params = true;
    }

    // Regular parameters
    const param_items = cg.ast.extra_data.items[params_start..params_end];
    for (param_items, 0..) |item, i| {
        if (i > 0 or has_params) try cg.writeStr(", ");
        try cg.emitNode(@enumFromInt(item));
    }
    if (param_items.len > 0) has_params = true;

    // Rest parameter
    if (rest_param != .none) {
        if (has_params) try cg.writeStr(", ");
        try cg.writeStr("...");
        try cg.emitNode(rest_param);
    }

    try cg.writeChar(')');

    // Return type separator
    // In method context (DeclareFunction, ObjectTypeCallProperty, ObjectTypeInternalSlot,
    // ObjectTypeProperty with method), use ":"
    // Otherwise use "=>"
    if (is_method_context) {
        try cg.writeStr(": ");
    } else {
        try cg.writeStr(" => ");
    }

    // Return type
    try cg.emitNode(return_type);
}

/// Emit a Flow function type parameter
fn emitFlowFunctionTypeParam(cg: *Codegen, main_token: TokenIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const ty: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const flags = cg.ast.extra_data.items[extra_idx + 1];
    const is_optional = (flags & 1) != 0;
    const is_unnamed = (flags & 2) != 0;

    const has_name = if (is_unnamed)
        false
    else blk: {
        const tok_tag = cg.ast.tokens.items(.tag)[@intFromEnum(main_token)];
        break :blk tok_tag == .identifier or tok_tag.isKeyword();
    };

    if (has_name) {
        try cg.emitToken(main_token);
        if (is_optional) try cg.writeChar('?');
        try cg.writeStr(": ");
    }
    try cg.emitNode(ty);
}

/// Emit a Flow enum body
fn emitFlowEnumBody(cg: *Codegen, data: Node.Data, type_name: []const u8) !void {
    const extra_idx = @intFromEnum(data.extra);
    const range_start = cg.ast.extra_data.items[extra_idx];
    const range_end = cg.ast.extra_data.items[extra_idx + 1];
    const has_unknown = cg.ast.extra_data.items[extra_idx + 2];
    const explicit_type = if (extra_idx + 3 < cg.ast.extra_data.items.len)
        cg.ast.extra_data.items[extra_idx + 3]
    else
        0;

    // "of <type>" if explicit, or for symbol bodies always explicit
    if (explicit_type != 0 or std.mem.eql(u8, type_name, "symbol")) {
        try cg.writeStr(" of ");
        try cg.writeStr(type_name);
    }
    try cg.space();

    // Body
    try cg.writeStr("{\n");
    cg.indent();

    const items = cg.ast.extra_data.items[range_start..range_end];
    for (items) |item| {
        try cg.writeIndent();
        try cg.emitNode(@enumFromInt(item));
        try cg.newline();
    }

    if (has_unknown != 0) {
        try cg.writeIndent();
        try cg.writeStr("...\n");
    }

    cg.dedent();
    try cg.writeIndent();
    try cg.writeChar('}');
}
