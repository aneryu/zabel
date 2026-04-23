const std = @import("std");
const Codegen = @import("codegen.zig").Codegen;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const ExtraIndex = @import("ast.zig").ExtraIndex;
const TokenIndex = @import("ast.zig").TokenIndex;
const Token = @import("token.zig").Token;
const Parser = @import("parser.zig").Parser;

const TS_MOD_PUBLIC: u32 = Parser.TS_MOD_PUBLIC;
const TS_MOD_PRIVATE: u32 = Parser.TS_MOD_PRIVATE;
const TS_MOD_PROTECTED: u32 = Parser.TS_MOD_PROTECTED;
const TS_MOD_READONLY: u32 = Parser.TS_MOD_READONLY;
const TS_MOD_ABSTRACT: u32 = Parser.TS_MOD_ABSTRACT;
const TS_MOD_DECLARE: u32 = Parser.TS_MOD_DECLARE;
const TS_MOD_OVERRIDE: u32 = Parser.TS_MOD_OVERRIDE;
const TS_MOD_STATIC: u32 = Parser.TS_MOD_STATIC;

pub fn emitTsNode(cg: *Codegen, tag: Node.Tag, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) !void {
    switch (tag) {
        // === TS Type Annotation ===
        .ts_type_annotation => {
            // `: type` — but when parent is TSFunctionType/TSConstructorType returnType, emit `=> type`
            const pt = cg.parent_tag;
            if (pt == .ts_function_type or pt == .ts_constructor_type) {
                try cg.writeStr("=> ");
            } else {
                try cg.writeStr(": ");
            }
            try cg.emitNode(data.unary);
        },

        // === TS Type Reference ===
        .ts_type_reference => {
            try cg.emitNode(data.binary.lhs);
            if (data.binary.rhs != .none) {
                try cg.emitNode(data.binary.rhs);
            }
        },

        // === TS Keyword Type ===
        .ts_keyword_type => {
            try cg.emitToken(main_token);
        },

        // === TS Array Type ===
        .ts_array_type => {
            cg.child_position = .argument;
            try cg.emitNode(data.unary);
            try cg.writeStr("[]");
        },

        // === TS Tuple Type ===
        .ts_tuple_type => {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = cg.ast.extra_data.items[extra_idx];
            const range_end = cg.ast.extra_data.items[extra_idx + 1];
            try cg.writeChar('[');
            if (range_start <= range_end and range_end <= cg.ast.extra_data.items.len) {
                try cg.emitCommaSeparated(range_start, range_end);
            }
            try cg.writeChar(']');
        },

        // === TS Union Type ===
        .ts_union_type => {
            try emitUnionOrIntersection(cg, data, " | ");
        },

        // === TS Intersection Type ===
        .ts_intersection_type => {
            try emitUnionOrIntersection(cg, data, " & ");
        },

        // === TS Function Type ===
        .ts_function_type => {
            try emitFunctionOrConstructorType(cg, idx, data, false);
        },

        // === TS Constructor Type ===
        .ts_constructor_type => {
            // Check for abstract
            const is_abstract = blk: {
                const mt = @intFromEnum(main_token);
                const mt_tag = cg.ast.tokens.items(.tag)[mt];
                if (mt_tag == .identifier) {
                    const mt_start = cg.ast.tokens.items(.start)[mt];
                    const mt_end = cg.ast.tokens.items(.end)[mt];
                    if (std.mem.eql(u8, cg.ast.source[mt_start..mt_end], "abstract")) {
                        break :blk true;
                    }
                }
                if (mt > 0) {
                    const prev_tag = cg.ast.tokens.items(.tag)[mt - 1];
                    if (prev_tag == .identifier) {
                        const prev_start = cg.ast.tokens.items(.start)[mt - 1];
                        const prev_end = cg.ast.tokens.items(.end)[mt - 1];
                        if (std.mem.eql(u8, cg.ast.source[prev_start..prev_end], "abstract")) break :blk true;
                    }
                }
                break :blk false;
            };
            if (is_abstract) {
                try cg.writeStr("abstract ");
            }
            try cg.writeStr("new ");
            try emitFunctionOrConstructorType(cg, idx, data, true);
        },

        // === TS Parenthesized Type ===
        .ts_parenthesized_type => {
            if (cg.ast.create_parenthesized_expressions) {
                try cg.writeChar('(');
                try cg.emitNode(data.unary);
                try cg.writeChar(')');
            } else {
                // Transparent: just emit the inner type
                try cg.emitNode(data.unary);
            }
        },

        // === TS Optional Type ===
        .ts_optional_type => {
            cg.child_position = .argument;
            try cg.emitNode(data.unary);
            try cg.writeChar('?');
        },

        // === TS Rest Type ===
        .ts_rest_type => {
            try cg.writeStr("...");
            cg.child_position = .argument;
            try cg.emitNode(data.unary);
        },

        // === TS Literal Type ===
        .ts_literal_type => {
            try cg.emitNode(data.unary);
        },

        // === TS Type Parameter ===
        .ts_type_parameter => {
            const extra_idx = @intFromEnum(data.extra);
            const constraint: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const default_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            const name_token_raw = cg.ast.extra_data.items[extra_idx + 2];
            const flags = cg.ast.extra_data.items[extra_idx + 3];
            const has_in = (flags & 1) != 0;
            const has_out = (flags & 2) != 0;
            const has_const = (flags & 4) != 0;

            const name_tok: TokenIndex = if (name_token_raw != @intFromEnum(NodeIndex.none))
                @enumFromInt(name_token_raw)
            else
                main_token;

            if (has_const) {
                try cg.writeStr("const ");
            }
            if (has_in) {
                try cg.writeStr("in ");
            }
            if (has_out) {
                try cg.writeStr("out ");
            }
            try cg.emitToken(name_tok);
            if (constraint != .none) {
                try cg.writeStr(" extends ");
                try cg.emitNode(constraint);
            }
            if (default_type != .none) {
                try cg.writeStr(" = ");
                try cg.emitNode(default_type);
            }
        },

        // === TS Type Parameter Declaration / Instantiation ===
        .ts_type_parameter_declaration, .ts_type_parameter_instantiation => {
            const extra_idx = @intFromEnum(data.extra);
            const range_start = cg.ast.extra_data.items[extra_idx];
            const range_end = cg.ast.extra_data.items[extra_idx + 1];
            try cg.writeChar('<');
            if (range_start <= range_end and range_end <= cg.ast.extra_data.items.len) {
                try cg.emitCommaSeparated(range_start, range_end);
                // Add trailing comma for arrow function type parameter declarations
                // with a single param, matching Babel's behavior to disambiguate from JSX.
                if (tag == .ts_type_parameter_declaration and cg.arrow_type_params and (range_end - range_start) == 1) {
                    try cg.writeChar(',');
                }
            }
            try cg.writeChar('>');
        },

        // === TS Qualified Name ===
        .ts_qualified_name => {
            try cg.emitNode(data.binary.lhs);
            try cg.writeChar('.');
            try cg.emitNode(data.binary.rhs);
        },

        // === TS Conditional Type ===
        .ts_conditional_type => {
            const extra_idx = @intFromEnum(data.extra);
            const check_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const extends_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            const true_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
            const false_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 3]);
            cg.child_position = .left;
            try cg.emitNode(check_type);
            try cg.writeStr(" extends ");
            cg.child_position = .right;
            try cg.emitNode(extends_type);
            try cg.writeStr(" ? ");
            cg.child_position = .consequent;
            try cg.emitNode(true_type);
            try cg.writeStr(" : ");
            cg.child_position = .alternate;
            try cg.emitNode(false_type);
        },

        // === TS Infer Type ===
        .ts_infer_type => {
            try cg.writeStr("infer ");
            // Emit the type parameter inline without variance modifiers (in/out)
            // since infer type params don't use variance annotations.
            try emitTsTypeParameterInline(cg, data.unary, false);
        },

        // === TS Mapped Type ===
        .ts_mapped_type => {
            try emitMappedType(cg, idx, data);
        },

        // === TS Indexed Access Type ===
        .ts_indexed_access_type => {
            cg.child_position = .left;
            try cg.emitNode(data.binary.lhs);
            try cg.writeChar('[');
            cg.child_position = .right;
            try cg.emitNode(data.binary.rhs);
            try cg.writeChar(']');
        },

        // === TS Template Literal Type ===
        .ts_template_literal_type => {
            try emitTemplateLiteralType(cg, main_token, data);
        },

        // === TS Typeof Type ===
        .ts_typeof_type => {
            try cg.writeStr("typeof ");
            try cg.emitNode(data.unary);
            // Type arguments from side table
            if (cg.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
                try cg.emitNode(tp);
            }
        },

        // === TS Type Operator ===
        .ts_type_operator => {
            try cg.emitToken(main_token);
            try cg.space();
            cg.child_position = .argument;
            try cg.emitNode(data.unary);
        },

        // === TS Type Predicate ===
        .ts_type_predicate => {
            const extra_idx = @intFromEnum(data.extra);
            const param_name: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const type_ann: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            const asserts_flag = cg.ast.extra_data.items[extra_idx + 2];
            if (asserts_flag != 0) {
                try cg.writeStr("asserts ");
            }
            try cg.emitNode(param_name);
            if (type_ann != .none) {
                try cg.writeStr(" is ");
                // The type_ann is a TSTypeAnnotation node — Babel prints typeAnnotation.typeAnnotation
                // So we need to unwrap the TSTypeAnnotation and emit the inner type.
                const ta_tag = cg.ast.nodes.items(.tag)[@intFromEnum(type_ann)];
                if (ta_tag == .ts_type_annotation) {
                    const ta_data = cg.ast.nodes.items(.data)[@intFromEnum(type_ann)];
                    try cg.emitNode(ta_data.unary);
                } else {
                    try cg.emitNode(type_ann);
                }
            }
        },

        // === TS Import Type ===
        .ts_import_type => {
            const extra_idx = @intFromEnum(data.extra);
            const argument: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const qualifier: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
            const options_node: NodeIndex = if (cg.ast.extra_data.items.len > extra_idx + 3)
                @enumFromInt(cg.ast.extra_data.items[extra_idx + 3])
            else
                .none;
            try cg.writeStr("import(");
            try cg.emitNode(argument);
            if (options_node != .none) {
                try cg.writeChar(',');
                try cg.emitNode(options_node);
            }
            try cg.writeChar(')');
            if (qualifier != .none) {
                try cg.writeChar('.');
                try cg.emitNode(qualifier);
            }
            if (type_params != .none) {
                try cg.emitNode(type_params);
            }
        },

        // === TS Named Tuple Member ===
        .ts_named_tuple_member => {
            const rhs = data.binary.rhs;
            const rhs_tag = cg.ast.nodes.items(.tag)[@intFromEnum(rhs)];
            const is_optional = rhs_tag == .ts_optional_type;
            try cg.emitNode(data.binary.lhs);
            if (is_optional) {
                try cg.writeChar('?');
            }
            try cg.writeStr(": ");
            if (is_optional) {
                // Unwrap the optional type to get the inner type
                const inner = cg.ast.nodes.items(.data)[@intFromEnum(rhs)].unary;
                try cg.emitNode(inner);
            } else {
                try cg.emitNode(rhs);
            }
        },

        // === TS As Expression ===
        .ts_as_expression => {
            cg.child_position = .left;
            try cg.emitNode(data.binary.lhs);
            try cg.writeStr(" as ");
            cg.child_position = .right;
            try cg.emitNode(data.binary.rhs);
        },

        // === TS Satisfies Expression ===
        .ts_satisfies_expression => {
            cg.child_position = .left;
            // Emit lhs, then check if it ended with a line comment.
            // If so, wrap in parens to prevent the comment from consuming
            // "satisfies ..." on the rest of the line.
            const buf_before = cg.buf.items.len;
            try cg.emitNode(data.binary.lhs);
            if (cg.endsWithLineComment()) {
                // Insert '(' before the lhs and add ')' after
                try cg.buf.insert(cg.allocator, buf_before, '(');
                try cg.newline();
                try cg.writeIndent();
                try cg.writeChar(')');
            }
            try cg.writeStr(" satisfies ");
            cg.child_position = .right;
            try cg.emitNode(data.binary.rhs);
        },

        // === TS Non-Null Expression ===
        .ts_non_null_expression => {
            cg.child_position = .object;
            try cg.emitNode(data.unary);
            try cg.writeChar('!');
        },

        // === TS Type Assertion ===
        .ts_type_assertion => {
            try cg.writeChar('<');
            try cg.emitNode(data.binary.lhs);
            try cg.writeStr("> ");
            cg.child_position = .argument;
            try cg.emitNode(data.binary.rhs);
        },

        // === TS Instantiation Expression ===
        .ts_instantiation_expression => {
            try cg.emitNode(data.binary.lhs);
            try cg.emitNode(data.binary.rhs);
        },

        // === TS Type Cast Expression ===
        .ts_type_cast_expression => {
            const extra_idx = @intFromEnum(data.extra);
            const expr: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const type_ann: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            try cg.emitNode(expr);
            try cg.emitNode(type_ann);
        },

        // === TS Type Alias Declaration ===
        .ts_type_alias_declaration => {
            try emitTypeAliasDeclaration(cg, idx, data);
        },

        // === TS Interface Declaration ===
        .ts_interface_declaration => {
            try emitInterfaceDeclaration(cg, idx, data);
        },

        // === TS Interface Body ===
        .ts_interface_body => {
            try emitBodyBraced(cg, data);
        },

        // === TS Type Literal ===
        .ts_type_literal => {
            try emitBodyBraced(cg, data);
        },

        // === TS Property Signature ===
        .ts_property_signature => {
            try emitPropertySignature(cg, idx, data);
        },

        // === TS Method Signature ===
        .ts_method_signature => {
            try emitMethodSignature(cg, idx, data);
        },

        // === TS Index Signature ===
        .ts_index_signature => {
            try emitIndexSignature(cg, idx, data);
        },

        // === TS Call Signature Declaration ===
        .ts_call_signature_declaration => {
            try emitSignatureDeclaration(cg, data, false);
        },

        // === TS Construct Signature Declaration ===
        .ts_construct_signature_declaration => {
            try cg.writeStr("new ");
            try emitSignatureDeclaration(cg, data, false);
        },

        // === TS Enum Declaration ===
        .ts_enum_declaration => {
            try emitEnumDeclaration(cg, idx, data);
        },

        // === TS Enum Member ===
        .ts_enum_member => {
            try cg.emitToken(main_token);
            if (data.unary != .none) {
                try cg.writeStr(" = ");
                try cg.emitNode(data.unary);
            }
        },

        // === TS Module Declaration ===
        .ts_module_declaration => {
            try emitModuleDeclaration(cg, idx, main_token, data);
        },

        // === TS Module Block ===
        .ts_module_block => {
            try emitModuleBlock(cg, data);
        },

        // === TS Declare Function ===
        .ts_declare_function => {
            try emitDeclareFunction(cg, idx, data);
        },

        // === TS Declare Variable ===
        .ts_declare_variable => {
            try emitDeclareVariable(cg, main_token, data);
        },

        // === TS Declare Method ===
        .ts_declare_method => {
            try emitDeclareMethod(cg, idx, data);
        },

        // === TS Parameter Property ===
        .ts_parameter_property => {
            try emitParameterProperty(cg, idx, data);
        },

        // === TS Import Equals Declaration ===
        .ts_import_equals_declaration => {
            try emitImportEqualsDeclaration(cg, data);
        },

        // === TS Export Assignment ===
        .ts_export_assignment => {
            try cg.writeStr("export = ");
            try cg.emitNode(data.unary);
            try cg.semicolon();
        },

        // === TS Namespace Export Declaration ===
        .ts_namespace_export_declaration => {
            try cg.writeStr("export as namespace ");
            const name_tok = data.token;
            try cg.emitToken(name_tok);
            try cg.semicolon();
        },

        // === TS External Module Reference ===
        .ts_external_module_reference => {
            try cg.writeStr("require(");
            try cg.emitNode(data.unary);
            try cg.writeChar(')');
        },

        // === import type { Foo } from "bar" ===
        .import_declaration_type => {
            try emitImportDeclarationType(cg, idx, data);
        },

        // === import { type Foo } ===
        .import_specifier_type => {
            try cg.writeStr("type ");
            try emitImportSpecifierInner(cg, data);
        },

        // === import { typeof Foo } ===
        .import_specifier_typeof => {
            try cg.writeStr("typeof ");
            try emitImportSpecifierInner(cg, data);
        },

        // === export type { Foo } ===
        .export_named_type => {
            try emitExportNamedType(cg, idx, data);
        },

        else => {
            try cg.writeStr("/* TODO: TS */");
        },
    }
}

// ---------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------

fn emitUnionOrIntersection(cg: *Codegen, data: Node.Data, sep: []const u8) !void {
    const extra_idx = @intFromEnum(data.extra);
    const range_start = cg.ast.extra_data.items[extra_idx];
    const range_end = cg.ast.extra_data.items[extra_idx + 1];
    if (range_start <= range_end and range_end <= cg.ast.extra_data.items.len) {
        const items = cg.ast.extra_data.items[range_start..range_end];
        for (items, 0..) |item, i| {
            if (i > 0) {
                try cg.writeStr(sep);
            }
            try cg.emitNode(@enumFromInt(item));
        }
    }
}

fn emitFunctionOrConstructorType(cg: *Codegen, idx: NodeIndex, data: Node.Data, is_constructor: bool) !void {
    _ = is_constructor;
    const extra_idx = @intFromEnum(data.extra);
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const params_start = cg.ast.extra_data.items[extra_idx + 1];
    const params_end = cg.ast.extra_data.items[extra_idx + 2];
    const return_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 3]);

    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    try cg.writeChar('(');
    if (params_start <= params_end and params_end <= cg.ast.extra_data.items.len) {
        try emitParamList(cg, params_start, params_end);
    }
    try cg.writeChar(')');
    if (return_type != .none) {
        try cg.writeStr(" => ");
        try cg.emitNode(return_type);
    }
    _ = idx;
}

fn emitMappedType(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    _ = idx;
    const extra_idx = @intFromEnum(data.extra);
    const type_param: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const type_ann: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const name_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
    const optional_mod = cg.ast.extra_data.items[extra_idx + 3];
    const readonly_mod = cg.ast.extra_data.items[extra_idx + 4];

    // Extract key name and constraint from the TSTypeParameter
    const tp_extra_idx = @intFromEnum(cg.ast.nodes.items(.data)[@intFromEnum(type_param)].extra);
    const constraint: NodeIndex = @enumFromInt(cg.ast.extra_data.items[tp_extra_idx]);
    const name_token_raw = cg.ast.extra_data.items[tp_extra_idx + 2];
    const tp_main_token = cg.ast.nodes.items(.main_token)[@intFromEnum(type_param)];
    const name_tok: TokenIndex = if (name_token_raw != @intFromEnum(NodeIndex.none))
        @enumFromInt(name_token_raw)
    else
        tp_main_token;

    try cg.writeStr("{ ");
    if (readonly_mod != 0) {
        try emitPlusMinus(cg, readonly_mod);
        try cg.writeStr("readonly ");
    }
    try cg.writeChar('[');
    try cg.emitToken(name_tok);
    try cg.writeStr(" in ");
    if (constraint != .none) {
        try cg.emitNode(constraint);
    }
    if (name_type != .none) {
        try cg.writeStr(" as ");
        try cg.emitNode(name_type);
    }
    try cg.writeChar(']');
    if (optional_mod != 0) {
        try emitPlusMinus(cg, optional_mod);
        try cg.writeChar('?');
    }
    if (type_ann != .none) {
        try cg.writeStr(": ");
        try cg.emitNode(type_ann);
    }
    try cg.writeStr(" }");
}

fn emitPlusMinus(cg: *Codegen, mod: u32) !void {
    switch (mod) {
        2 => try cg.writeChar('+'), // "+"
        3 => try cg.writeChar('-'), // "-"
        else => {}, // true (1) — no prefix
    }
}

fn emitTemplateLiteralType(cg: *Codegen, main_token: TokenIndex, data: Node.Data) !void {
    const mt_tag = cg.ast.tokens.items(.tag)[@intFromEnum(main_token)];
    if (mt_tag == .template_no_sub) {
        // Simple template - no substitutions
        try cg.emitToken(main_token);
    } else {
        const extra_idx = @intFromEnum(data.extra);
        const types_start = cg.ast.extra_data.items[extra_idx];
        const types_end = cg.ast.extra_data.items[extra_idx + 1];
        const tpl_toks_start = cg.ast.extra_data.items[extra_idx + 2];
        const tpl_toks_end = cg.ast.extra_data.items[extra_idx + 3];
        const num_types = types_end - types_start;

        // Emit head token
        try cg.emitToken(main_token);

        // Interleave types and middle/tail tokens
        for (0..num_types) |j| {
            const type_node: NodeIndex = @enumFromInt(cg.ast.extra_data.items[types_start + j]);
            try cg.emitNode(type_node);
            if (tpl_toks_start + j < tpl_toks_end) {
                const next_tok: TokenIndex = @enumFromInt(cg.ast.extra_data.items[tpl_toks_start + j]);
                try cg.emitToken(next_tok);
            }
        }
    }
}

fn emitTypeAliasDeclaration(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const id: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const type_ann: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);

    if (isDeclareNode(cg, idx)) {
        try cg.writeStr("declare ");
    }
    try cg.writeStr("type ");
    try cg.emitNode(id);
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    try cg.writeStr(" = ");
    try cg.emitNode(type_ann);
    try cg.semicolon();
}

fn emitInterfaceDeclaration(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const id: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const body: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);
    const extends_start = cg.ast.extra_data.items[extra_idx + 3];
    const extends_end = cg.ast.extra_data.items[extra_idx + 4];

    if (isDeclareNode(cg, idx)) {
        try cg.writeStr("declare ");
    }
    try cg.writeStr("interface ");
    try cg.emitNode(id);
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    if (extends_start < extends_end) {
        try cg.writeStr(" extends ");
        const items = cg.ast.extra_data.items[extends_start..extends_end];
        for (items, 0..) |item, i| {
            if (i > 0) {
                try cg.writeStr(", ");
            }
            // Each extends item is a type reference — emit as expression (TSInterfaceHeritage)
            const ref_idx: NodeIndex = @enumFromInt(item);
            try emitInterfaceHeritage(cg, ref_idx);
        }
    }
    try cg.space();
    try cg.emitNode(body);
}

fn emitInterfaceHeritage(cg: *Codegen, ref_idx: NodeIndex) !void {
    const ref_tag = cg.ast.nodes.items(.tag)[@intFromEnum(ref_idx)];
    if (ref_tag == .ts_type_reference) {
        const ref_data = cg.ast.nodes.items(.data)[@intFromEnum(ref_idx)];
        // Emit expression (typeName for type reference, converting qualified names to member exprs)
        try emitEntityNameAsExpr(cg, ref_data.binary.lhs);
        if (ref_data.binary.rhs != .none) {
            try cg.emitNode(ref_data.binary.rhs);
        }
    } else {
        try cg.emitNode(ref_idx);
    }
}

fn emitEntityNameAsExpr(cg: *Codegen, name_idx: NodeIndex) !void {
    const name_tag = cg.ast.nodes.items(.tag)[@intFromEnum(name_idx)];
    if (name_tag == .ts_qualified_name) {
        const name_data = cg.ast.nodes.items(.data)[@intFromEnum(name_idx)];
        try emitEntityNameAsExpr(cg, name_data.binary.lhs);
        try cg.writeChar('.');
        try cg.emitNode(name_data.binary.rhs);
    } else {
        try cg.emitNode(name_idx);
    }
}

fn emitBodyBraced(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const range_start = cg.ast.extra_data.items[extra_idx];
    const range_end = cg.ast.extra_data.items[extra_idx + 1];
    if (range_start >= range_end) {
        try cg.writeStr("{}");
        return;
    }
    try cg.writeStr("{\n");
    cg.indent();
    const items = cg.ast.extra_data.items[range_start..range_end];
    for (items) |item| {
        try cg.writeIndent();
        try cg.emitNode(@enumFromInt(item));
        try cg.newline();
    }
    cg.dedent();
    try cg.writeIndent();
    try cg.writeChar('}');
}

fn emitPropertySignature(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    _ = idx;
    const extra_idx = @intFromEnum(data.extra);
    const key: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const type_ann: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const flags = cg.ast.extra_data.items[extra_idx + 2];
    const is_optional = (flags & 1) != 0;
    const is_readonly = (flags & 2) != 0;
    const is_computed = (flags & 4) != 0;

    if (is_readonly) {
        try cg.writeStr("readonly ");
    }
    if (is_computed) {
        try cg.writeChar('[');
    }
    try cg.emitNode(key);
    if (is_computed) {
        try cg.writeChar(']');
    }
    if (is_optional) {
        try cg.writeChar('?');
    }
    if (type_ann != .none) {
        try cg.emitNode(type_ann);
    }
    try cg.semicolon();
}

fn emitMethodSignature(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    _ = idx;
    const extra_idx = @intFromEnum(data.extra);
    const key: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const params_start = cg.ast.extra_data.items[extra_idx + 2];
    const params_end = cg.ast.extra_data.items[extra_idx + 3];
    const return_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 4]);
    const flags = cg.ast.extra_data.items[extra_idx + 5];
    const kind_code = cg.ast.extra_data.items[extra_idx + 6];
    const is_optional = (flags & 1) != 0;
    const is_computed = (flags & 4) != 0;

    // Kind: get/set prefix
    if (kind_code == 1) {
        try cg.writeStr("get ");
    } else if (kind_code == 2) {
        try cg.writeStr("set ");
    }

    if (is_computed) {
        try cg.writeChar('[');
    }
    try cg.emitNode(key);
    if (is_computed) {
        try cg.writeChar(']');
    }
    if (is_optional) {
        try cg.writeChar('?');
    }

    // Signature
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    try cg.writeChar('(');
    if (params_start <= params_end and params_end <= cg.ast.extra_data.items.len) {
        try emitParamList(cg, params_start, params_end);
    }
    try cg.writeChar(')');
    if (return_type != .none) {
        try cg.emitNode(return_type);
    }
    try cg.semicolon();
}

fn emitIndexSignature(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const param: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const type_ann: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 2]);

    // Check modifiers
    const mods = cg.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;
    if (mods & TS_MOD_STATIC != 0) {
        try cg.writeStr("static ");
    }
    if (mods & TS_MOD_READONLY != 0) {
        try cg.writeStr("readonly ");
    }

    try cg.writeChar('[');
    try emitParamWithAnnotation(cg, param);
    try cg.writeChar(']');
    if (type_ann != .none) {
        try cg.emitNode(type_ann);
    }
    try cg.semicolon();
}

fn emitSignatureDeclaration(cg: *Codegen, data: Node.Data, _: bool) !void {
    const extra_idx = @intFromEnum(data.extra);
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const params_start = cg.ast.extra_data.items[extra_idx + 1];
    const params_end = cg.ast.extra_data.items[extra_idx + 2];
    const return_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 3]);

    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    try cg.writeChar('(');
    if (params_start <= params_end and params_end <= cg.ast.extra_data.items.len) {
        try emitParamList(cg, params_start, params_end);
    }
    try cg.writeChar(')');
    if (return_type != .none) {
        try cg.emitNode(return_type);
    }
    try cg.semicolon();
}

fn emitEnumDeclaration(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const id: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const members_start = cg.ast.extra_data.items[extra_idx + 1];
    const members_end = cg.ast.extra_data.items[extra_idx + 2];
    const is_const = cg.ast.extra_data.items[extra_idx + 3] != 0;

    if (isDeclareNode(cg, idx)) {
        try cg.writeStr("declare ");
    }
    if (is_const) {
        try cg.writeStr("const ");
    }
    try cg.writeStr("enum ");
    try cg.emitNode(id);
    try cg.writeStr(" ");

    // Enum body: { members }
    if (members_start >= members_end) {
        try cg.writeStr("{}");
        return;
    }
    try cg.writeStr("{\n");
    cg.indent();
    const items = cg.ast.extra_data.items[members_start..members_end];
    for (items, 0..) |item, i| {
        try cg.writeIndent();
        try cg.emitNode(@enumFromInt(item));
        if (i < items.len - 1) {
            try cg.writeChar(',');
        }
        try cg.newline();
    }
    cg.dedent();
    try cg.writeIndent();
    try cg.writeChar('}');
}

fn emitModuleDeclaration(cg: *Codegen, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) !void {
    _ = main_token;
    const extra_idx = @intFromEnum(data.extra);
    const id: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const body: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const kind_code = if (extra_idx + 2 < cg.ast.extra_data.items.len) cg.ast.extra_data.items[extra_idx + 2] else 0;

    if (isDeclareNode(cg, idx)) {
        try cg.writeStr("declare ");
    }
    // Kind: 0=module, 1=namespace, 2=global
    if (kind_code != 2) {
        const kind_str: []const u8 = switch (kind_code) {
            1 => "namespace",
            else => "module",
        };
        try cg.writeStr(kind_str);
        try cg.space();
    }
    try cg.emitNode(id);
    if (body == .none) {
        try cg.semicolon();
        return;
    }
    try cg.space();
    try cg.emitNode(body);
}

fn emitModuleBlock(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const range_start = cg.ast.extra_data.items[extra_idx];
    const range_end = cg.ast.extra_data.items[extra_idx + 1];
    if (range_start >= range_end) {
        try cg.writeStr("{}");
        return;
    }
    try cg.writeStr("{\n");
    cg.indent();
    const items = cg.ast.extra_data.items[range_start..range_end];
    for (items) |item| {
        try cg.writeIndent();
        try cg.emitNode(@enumFromInt(item));
        try cg.newline();
    }
    cg.dedent();
    try cg.writeIndent();
    try cg.writeChar('}');
}

fn emitDeclareFunction(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const id: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const type_params: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const params_start = cg.ast.extra_data.items[extra_idx + 2];
    const params_end = cg.ast.extra_data.items[extra_idx + 3];
    const return_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 4]);
    const body: NodeIndex = if (extra_idx + 5 < cg.ast.extra_data.items.len) @enumFromInt(cg.ast.extra_data.items[extra_idx + 5]) else .none;

    // Check if declare keyword present
    const main_token = cg.ast.nodes.items(.main_token)[@intFromEnum(idx)];
    const mt_tag = cg.ast.tokens.items(.tag)[@intFromEnum(main_token)];
    const is_declare = mt_tag == .identifier and std.mem.eql(u8, cg.ast.tokenSlice(main_token), "declare");

    if (is_declare) {
        try cg.writeStr("declare ");
    }

    try cg.writeStr("function ");
    if (id != .none) {
        try cg.emitNode(id);
    }
    if (type_params != .none) {
        try cg.emitNode(type_params);
    }
    try cg.writeChar('(');
    if (params_start <= params_end and params_end <= cg.ast.extra_data.items.len) {
        try emitParamList(cg, params_start, params_end);
    }
    try cg.writeChar(')');
    if (return_type != .none) {
        try cg.emitNode(return_type);
    }
    if (body != .none) {
        try cg.space();
        try cg.emitNode(body);
    } else {
        try cg.semicolon();
    }
}

fn emitDeclareVariable(cg: *Codegen, main_token: TokenIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const tok_tag = cg.ast.tokens.items(.tag)[@intFromEnum(main_token)];
    // main_token may be 'declare' identifier, so check the next token for the actual keyword
    const kind_tag = if (tok_tag == .identifier)
        cg.ast.tokens.items(.tag)[@intFromEnum(main_token) + 1]
    else
        tok_tag;
    const kind_str: []const u8 = switch (kind_tag) {
        .kw_var => "var",
        .kw_let => "let",
        .kw_const => "const",
        else => "var",
    };
    try cg.writeStr("declare ");
    try cg.writeStr(kind_str);
    try cg.space();
    const range_start = cg.ast.extra_data.items[extra_idx];
    const range_end = cg.ast.extra_data.items[extra_idx + 1];
    if (range_start <= range_end and range_end <= cg.ast.extra_data.items.len) {
        try cg.emitCommaSeparated(range_start, range_end);
    }
    try cg.semicolon();
}

fn emitDeclareMethod(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const key: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const params_start = cg.ast.extra_data.items[extra_idx + 1];
    const params_end = cg.ast.extra_data.items[extra_idx + 2];
    const flags = if (extra_idx + 4 < cg.ast.extra_data.items.len)
        cg.ast.extra_data.items[extra_idx + 4]
    else
        0;
    const is_static = (flags & 1) != 0;
    const is_computed = (flags & 2) != 0;
    const is_generator = (flags & 4) != 0;
    const is_async = (flags & 8) != 0;
    const is_optional = (flags & 16) != 0;

    // Modifiers from side table
    const mods = cg.ast.ts_class_modifiers.get(@intFromEnum(idx)) orelse 0;

    // Emit modifiers in Babel order: declare, accessibility, static, abstract, override, readonly
    if (mods & TS_MOD_DECLARE != 0) {
        try cg.writeStr("declare ");
    }
    if (mods & TS_MOD_PUBLIC != 0) {
        try cg.writeStr("public ");
    } else if (mods & TS_MOD_PRIVATE != 0) {
        try cg.writeStr("private ");
    } else if (mods & TS_MOD_PROTECTED != 0) {
        try cg.writeStr("protected ");
    }
    if (is_static) {
        try cg.writeStr("static ");
    }
    if (mods & TS_MOD_ABSTRACT != 0) {
        try cg.writeStr("abstract ");
    }
    if (mods & TS_MOD_OVERRIDE != 0) {
        try cg.writeStr("override ");
    }

    if (is_async) {
        try cg.writeStr("async ");
    }
    if (is_generator) {
        try cg.writeChar('*');
    }
    if (is_computed) {
        try cg.writeChar('[');
    }

    // Check private name
    const key_main = cg.ast.nodes.items(.main_token)[@intFromEnum(key)];
    const key_idx_val = @intFromEnum(key_main);
    const is_private_key = key_idx_val > 0 and cg.ast.tokens.items(.tag)[key_idx_val - 1] == .hash;
    if (is_private_key) {
        try cg.writeChar('#');
    }

    try cg.emitNode(key);
    if (is_computed) {
        try cg.writeChar(']');
    }
    if (is_optional) {
        try cg.writeChar('?');
    }

    // Type params and return type from side table
    if (cg.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
        try cg.emitNode(tp);
    }
    try cg.writeChar('(');
    if (params_start <= params_end and params_end <= cg.ast.extra_data.items.len) {
        try emitParamList(cg, params_start, params_end);
    }
    try cg.writeChar(')');
    if (cg.ast.return_types.get(@intFromEnum(idx))) |rt| {
        try cg.emitNode(rt);
    }
    try cg.semicolon();
}

fn emitParameterProperty(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const param: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const param_flags = if (extra_idx + 1 < cg.ast.extra_data.items.len) cg.ast.extra_data.items[extra_idx + 1] else 0;

    try cg.emitDecorators(idx);

    // Accessibility
    if ((param_flags & (1 << 4)) != 0) {
        try cg.writeStr("public ");
    } else if ((param_flags & (1 << 5)) != 0) {
        try cg.writeStr("private ");
    } else if ((param_flags & (1 << 6)) != 0) {
        try cg.writeStr("protected ");
    }
    // Override
    if ((param_flags & (1 << 8)) != 0) {
        try cg.writeStr("override ");
    }
    // Readonly
    if ((param_flags & (1 << 7)) != 0) {
        try cg.writeStr("readonly ");
    }
    // Emit the parameter (which might be an Identifier, AssignmentPattern, etc.)
    try emitParamWithAnnotation(cg, param);
}

fn emitImportEqualsDeclaration(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const id_token_raw = cg.ast.extra_data.items[extra_idx];
    const module_ref: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const is_type = cg.ast.extra_data.items[extra_idx + 2] != 0;

    try cg.writeStr("import ");
    if (is_type) {
        try cg.writeStr("type ");
    }
    const id_tok: TokenIndex = @enumFromInt(id_token_raw);
    try cg.emitToken(id_tok);
    try cg.writeStr(" = ");
    try cg.emitNode(module_ref);
    try cg.semicolon();
}

fn emitImportDeclarationType(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const source_token_raw = cg.ast.extra_data.items[extra_idx];
    const specs_start = cg.ast.extra_data.items[extra_idx + 1];
    const specs_end = cg.ast.extra_data.items[extra_idx + 2];

    try cg.writeStr("import type ");

    // Check for import phase
    const phase_val = cg.ast.ts_class_modifiers.get(@intFromEnum(idx));
    if (phase_val) |pv| {
        if (pv == 0x100) {
            try cg.writeStr("source ");
        } else if (pv == 0x200) {
            try cg.writeStr("defer ");
        }
    }

    if (specs_start < specs_end and specs_end <= cg.ast.extra_data.items.len) {
        const specs = cg.ast.extra_data.items[specs_start..specs_end];
        const tags = cg.ast.nodes.items(.tag);

        var has_default = false;
        var has_namespace = false;
        var named_start: ?usize = null;
        var named_end: usize = 0;

        for (specs, 0..) |s, j| {
            const spec_tag = tags[s];
            if (spec_tag == .import_default) {
                has_default = true;
                try cg.emitNode(@enumFromInt(s));
                const has_more = j + 1 < specs.len;
                if (has_more) {
                    try cg.writeStr(", ");
                }
            } else if (spec_tag == .import_namespace) {
                has_namespace = true;
                try cg.emitNode(@enumFromInt(s));
            } else {
                if (named_start == null) named_start = j;
                named_end = j + 1;
            }
        }

        if (named_start) |ns| {
            try cg.writeStr("{ ");
            var first = true;
            for (specs[ns..named_end]) |s| {
                if (!first) try cg.writeStr(", ");
                first = false;
                try cg.emitNode(@enumFromInt(s));
            }
            try cg.writeStr(" }");
        }

        if (has_default or has_namespace or named_start != null) {
            try cg.writeStr(" from ");
        }
    } else {
        // Empty specifiers: import type {} from "..."
        try cg.writeStr("{} from ");
    }

    // Source
    const source_tok: TokenIndex = @enumFromInt(source_token_raw);
    try cg.emitToken(source_tok);

    // Attributes
    const has_attrs = extra_idx + 4 < cg.ast.extra_data.items.len;
    if (has_attrs) {
        const attrs_start = cg.ast.extra_data.items[extra_idx + 3];
        const attrs_end = cg.ast.extra_data.items[extra_idx + 4];
        if (attrs_start < attrs_end and attrs_end <= cg.ast.extra_data.items.len) {
            try cg.writeStr(" with { ");
            try cg.emitCommaSeparated(attrs_start, attrs_end);
            try cg.writeStr(" }");
        }
    }

    try cg.semicolon();
}

fn emitImportSpecifierInner(cg: *Codegen, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const imported_token_raw = cg.ast.extra_data.items[extra_idx];
    const local_token_raw = cg.ast.extra_data.items[extra_idx + 1];

    const imported_tok: TokenIndex = @enumFromInt(imported_token_raw);
    const local_tok: TokenIndex = @enumFromInt(local_token_raw);

    try cg.emitToken(imported_tok);
    const imported_text = cg.ast.tokenSlice(imported_tok);
    const local_text = cg.ast.tokenSlice(local_tok);
    if (!std.mem.eql(u8, imported_text, local_text)) {
        try cg.writeStr(" as ");
        try cg.emitToken(local_tok);
    }
}

fn emitExportNamedType(cg: *Codegen, idx: NodeIndex, data: Node.Data) !void {
    const extra_idx = @intFromEnum(data.extra);
    const source_token_raw = cg.ast.extra_data.items[extra_idx];
    const specs_start = cg.ast.extra_data.items[extra_idx + 1];
    const specs_end = cg.ast.extra_data.items[extra_idx + 2];

    // Check if there's a declaration
    const has_decl = extra_idx + 3 < cg.ast.extra_data.items.len and
        cg.ast.extra_data.items[extra_idx + 3] != @intFromEnum(NodeIndex.none);
    const decl_raw = if (extra_idx + 3 < cg.ast.extra_data.items.len)
        cg.ast.extra_data.items[extra_idx + 3]
    else
        @intFromEnum(NodeIndex.none);

    if (has_decl and decl_raw != @intFromEnum(NodeIndex.none)) {
        try cg.writeStr("export ");
        try cg.emitNode(@enumFromInt(decl_raw));
    } else {
        try cg.writeStr("export type ");

        if (specs_start < specs_end and specs_end <= cg.ast.extra_data.items.len) {
            const specs = cg.ast.extra_data.items[specs_start..specs_end];
            // Check for export_namespace_specifier (export type * as ns from)
            if (specs.len == 1) {
                const spec_node: NodeIndex = @enumFromInt(specs[0]);
                const spec_tag = cg.ast.nodes.items(.tag)[@intFromEnum(spec_node)];
                if (spec_tag == .export_namespace_specifier) {
                    try cg.emitNode(spec_node);
                    if (source_token_raw != 0) {
                        try cg.writeStr(" from ");
                        const source_tok: TokenIndex = @enumFromInt(source_token_raw);
                        try cg.emitToken(source_tok);
                    }
                    try cg.semicolon();
                    return;
                }
            }
            try cg.writeStr("{ ");
            var first = true;
            for (specs) |s| {
                if (!first) try cg.writeStr(", ");
                first = false;
                try cg.emitNode(@enumFromInt(s));
            }
            try cg.writeStr(" }");
        } else {
            try cg.writeStr("{}");
        }

        if (source_token_raw != 0) {
            try cg.writeStr(" from ");
            const source_tok: TokenIndex = @enumFromInt(source_token_raw);
            try cg.emitToken(source_tok);
        }

        // Attributes
        const has_attrs = extra_idx + 5 < cg.ast.extra_data.items.len;
        if (has_attrs) {
            const attrs_start = cg.ast.extra_data.items[extra_idx + 4];
            const attrs_end = cg.ast.extra_data.items[extra_idx + 5];
            if (attrs_start < attrs_end and attrs_end <= cg.ast.extra_data.items.len) {
                try cg.writeStr(" with { ");
                try cg.emitCommaSeparated(attrs_start, attrs_end);
                try cg.writeStr(" }");
            }
        }

        try cg.semicolon();
    }
    _ = idx;
}

// ---------------------------------------------------------------
// Helper: emit parameter with type annotation and optional
// ---------------------------------------------------------------

fn emitParamWithAnnotation(cg: *Codegen, param: NodeIndex) !void {
    if (param == .none) return;
    const param_i = @intFromEnum(param);
    const param_tag = cg.ast.nodes.items(.tag)[param_i];

    switch (param_tag) {
        .identifier => {
            try cg.emitNode(param);
            // Optional marker
            if (cg.ast.ts_optional_params.contains(param_i)) {
                try cg.writeChar('?');
            }
            // Type annotation
            if (cg.ast.type_annotations.get(param_i)) |ta| {
                try cg.emitNode(ta);
            }
        },
        .assignment_pattern => {
            // left = right, with possible type annotation on left
            const ap_data = cg.ast.nodes.items(.data)[param_i];
            try emitParamWithAnnotation(cg, ap_data.binary.lhs);
            try cg.writeStr(" = ");
            try cg.emitNode(ap_data.binary.rhs);
        },
        .rest_element => {
            try cg.writeStr("...");
            const re_data = cg.ast.nodes.items(.data)[param_i];
            try emitParamWithAnnotation(cg, re_data.unary);
            // Type annotation on the rest element itself
            if (cg.ast.type_annotations.get(param_i)) |ta| {
                try cg.emitNode(ta);
            }
        },
        .object_pattern, .array_pattern => {
            try cg.emitNode(param);
            if (cg.ast.ts_optional_params.contains(param_i)) {
                try cg.writeChar('?');
            }
            // Type annotation
            if (cg.ast.type_annotations.get(param_i)) |ta| {
                try cg.emitNode(ta);
            }
        },
        .ts_parameter_property => {
            try cg.emitNode(param);
        },
        else => {
            try cg.emitNode(param);
        },
    }
}

fn emitParamList(cg: *Codegen, start: u32, end: u32) !void {
    const items = cg.ast.extra_data.items[start..end];
    for (items, 0..) |item, i| {
        if (i > 0) {
            try cg.writeStr(", ");
        }
        try emitParamWithAnnotation(cg, @enumFromInt(item));
    }
}

fn isDeclareNode(cg: *Codegen, idx: NodeIndex) bool {
    const main_tok = cg.ast.nodes.items(.main_token)[@intFromEnum(idx)];
    return std.mem.eql(u8, cg.ast.tokenSlice(main_tok), "declare");
}

/// Emit a TSTypeParameter inline (for use in infer context where variance is suppressed).
fn emitTsTypeParameterInline(cg: *Codegen, idx: NodeIndex, emit_variance: bool) !void {
    if (idx == .none) return;
    const data = cg.ast.nodes.items(.data)[@intFromEnum(idx)];
    const main_token = cg.ast.nodes.items(.main_token)[@intFromEnum(idx)];
    const extra_idx = @intFromEnum(data.extra);
    const constraint: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const default_type: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
    const name_token_raw = cg.ast.extra_data.items[extra_idx + 2];
    const flags = cg.ast.extra_data.items[extra_idx + 3];

    const name_tok: TokenIndex = if (name_token_raw != @intFromEnum(NodeIndex.none))
        @enumFromInt(name_token_raw)
    else
        main_token;

    if (emit_variance) {
        const has_in = (flags & 1) != 0;
        const has_out = (flags & 2) != 0;
        const has_const = (flags & 4) != 0;
        if (has_const) try cg.writeStr("const ");
        if (has_in) try cg.writeStr("in ");
        if (has_out) try cg.writeStr("out ");
    }

    try cg.emitToken(name_tok);
    if (constraint != .none) {
        try cg.writeStr(" extends ");
        const saved_parent_tag = cg.parent_tag;
        const saved_parent_data = cg.parent_data;
        const saved_parent_main_token = cg.parent_main_token;
        const saved_child_pos = cg.child_position;
        defer {
            cg.parent_tag = saved_parent_tag;
            cg.parent_data = saved_parent_data;
            cg.parent_main_token = saved_parent_main_token;
            cg.child_position = saved_child_pos;
        }
        cg.parent_tag = .ts_type_parameter;
        cg.parent_data = data;
        cg.parent_main_token = main_token;
        cg.child_position = .left;
        try cg.emitNode(constraint);
    }
    if (default_type != .none) {
        try cg.writeStr(" = ");
        const saved_parent_tag = cg.parent_tag;
        const saved_parent_data = cg.parent_data;
        const saved_parent_main_token = cg.parent_main_token;
        const saved_child_pos = cg.child_position;
        defer {
            cg.parent_tag = saved_parent_tag;
            cg.parent_data = saved_parent_data;
            cg.parent_main_token = saved_parent_main_token;
            cg.child_position = saved_child_pos;
        }
        cg.parent_tag = .ts_type_parameter;
        cg.parent_data = data;
        cg.parent_main_token = main_token;
        cg.child_position = .right;
        try cg.emitNode(default_type);
    }
}
