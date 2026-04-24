const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const ExtraIndex = @import("../ast.zig").ExtraIndex;

// ── Types ────────────────────────────────────────────────────────────

pub const NodeTagBitSet = std.StaticBitSet(512);

pub const VisitResult = enum {
    continue_traversal,
    skip_children,
    remove_node,
};

pub const ChildList = struct {
    /// Fixed direct children (up to MAX_CHILDREN).
    items: [MAX_CHILDREN]NodeIndex = .{.none} ** MAX_CHILDREN,
    len: u8 = 0,
    /// First range of children stored in extra_data[range_start..range_end].
    range_start: u32 = 0,
    range_end: u32 = 0,
    /// Second range for nodes with two child ranges (e.g., switch_statement: discriminant + cases range).
    range2_start: u32 = 0,
    range2_end: u32 = 0,

    pub const MAX_CHILDREN = 8;

    /// Append a direct child. Silently ignores .none indices.
    pub fn add(self: *ChildList, idx: NodeIndex) void {
        if (idx == .none) return;
        if (self.len < MAX_CHILDREN) {
            self.items[self.len] = idx;
            self.len += 1;
        }
    }
};

// ── Leaf-tag predicate ──────────────────────────────────────────

/// Tags that have zero structural children.  Used by callers to skip
/// `getChildren()` entirely, avoiding the switch-dispatch overhead.
pub fn isLeafTag(tag: Node.Tag) bool {
    return switch (tag) {
        .removed,
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .regex_literal,
        .bigint_literal,
        .identifier,
        .v8_intrinsic_identifier,
        .this_expr,
        .super_expr,
        .empty_statement,
        .debugger_statement,
        .directive_literal,
        .jsx_empty_expression,
        .jsx_text,
        .jsx_string_literal,
        .jsx_identifier,
        .ts_keyword_type,
        .topic_reference,
        .placeholder,
        .export_default_specifier,
        .import_default,
        .import_namespace,
        .ts_namespace_export_declaration,
        .flow_number_type,
        .flow_string_type,
        .flow_boolean_type,
        .flow_void_type,
        .flow_mixed_type,
        .flow_empty_type,
        .flow_any_type,
        .flow_symbol_type,
        .flow_bigint_type,
        .flow_null_literal_type,
        .flow_number_literal_type,
        .flow_string_literal_type,
        .flow_boolean_literal_type,
        .flow_bigint_literal_type,
        .flow_exists_type,
        .flow_inferred_predicate,
        .flow_this_type_annotation,
        .flow_variance,
        .flow_enum_default_member,
        => true,
        else => false,
    };
}

// ── getChildren ─────────────────────────────���────────────────────────

/// Return a ChildList enumerating all direct structural children of the
/// given AST node.  Side-table children (type_annotations, return_types,
/// type_parameters, implements_list, decorators_map, …) are NOT included;
/// transforms should access those tables directly when needed.
pub fn getChildren(ast: *const Ast, idx: NodeIndex) ChildList {
    if (idx == .none) return .{};

    const i = @intFromEnum(idx);
    const tag = ast.nodes.items(.tag)[i];
    const data = ast.nodes.items(.data)[i];

    return switch (tag) {
        // ════════════════════════════════════════════════════════════
        // 0 children — leaf / token-only nodes
        // ════════════════════════════════════════════════════════════
        .removed,
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .regex_literal,
        .bigint_literal,
        .identifier,
        .v8_intrinsic_identifier,
        .this_expr,
        .super_expr,
        .empty_statement,
        .debugger_statement,
        .directive_literal,
        .jsx_empty_expression,
        .jsx_text,
        .jsx_string_literal,
        .jsx_identifier,
        .ts_keyword_type,
        .topic_reference,
        .placeholder,
        .export_default_specifier,
        .import_default,
        .import_namespace,
        .ts_namespace_export_declaration,
        .flow_number_type,
        .flow_string_type,
        .flow_boolean_type,
        .flow_void_type,
        .flow_mixed_type,
        .flow_empty_type,
        .flow_any_type,
        .flow_symbol_type,
        .flow_bigint_type,
        .flow_null_literal_type,
        .flow_number_literal_type,
        .flow_string_literal_type,
        .flow_boolean_literal_type,
        .flow_bigint_literal_type,
        .flow_exists_type,
        .flow_inferred_predicate,
        .flow_this_type_annotation,
        .flow_variance,
        .flow_enum_default_member,
        => .{},

        // ════════════════════════════════════════════════════════════
        // 1 child — data.unary
        // ════════════════════════════════════════════════════════════
        .unary_expr,
        .update_expr,
        .await_expr,
        .yield_expr,
        .yield_delegate_expr,
        .spread_element,
        .rest_element,
        .parenthesized_expr,
        .expression_statement,
        .return_statement,
        .throw_statement,
        .ts_type_annotation,
        .ts_array_type,
        .ts_parenthesized_type,
        .ts_optional_type,
        .ts_rest_type,
        .ts_literal_type,
        .ts_infer_type,
        .ts_typeof_type,
        .ts_type_operator,
        .ts_non_null_expression,
        .ts_export_assignment,
        .ts_external_module_reference,
        .decorator,
        .do_expression,
        .throw_expression,
        .export_default,
        .class_static_block,
        .private_name,
        .jsx_closing_element,
        .jsx_spread_attribute,
        .jsx_spread_child,
        .jsx_expression_container,
        .flow_type_annotation,
        .flow_nullable_type,
        .flow_typeof_type,
        .flow_array_type,
        .flow_object_type_spread_property,
        .flow_declared_predicate,
        .flow_parenthesized_type,
        => blk: {
            var cl = ChildList{};
            cl.add(data.unary);
            break :blk cl;
        },

        // directive: data.unary = directive_literal child
        .directive => blk: {
            var cl = ChildList{};
            cl.add(data.unary);
            break :blk cl;
        },

        // labeled_statement: data.unary = body (label is a token, not a node)
        .labeled_statement => blk: {
            var cl = ChildList{};
            cl.add(data.unary);
            break :blk cl;
        },

        // break/continue: data.unary = label node (may be .none)
        .break_statement,
        .continue_statement,
        => blk: {
            var cl = ChildList{};
            cl.add(data.unary);
            break :blk cl;
        },

        // ts_enum_member: data.unary = initializer (id is a token)
        .ts_enum_member => blk: {
            var cl = ChildList{};
            cl.add(data.unary);
            break :blk cl;
        },

        // meta_property: data.unary = property node (meta is synthesized from token)
        .meta_property => blk: {
            var cl = ChildList{};
            cl.add(data.unary);
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // 2 children — data.binary { lhs, rhs }
        // ════════════════════════════════════════════════════════════
        .binary_expr,
        .logical_expr,
        .assignment_expr,
        .computed_member_expr,
        .optional_computed_member_expr,
        .assignment_pattern,
        .declarator,
        .while_statement,
        .do_while_statement,
        .catch_clause,
        .with_statement,
        .import_attribute,
        .ts_type_reference,
        .ts_qualified_name,
        .ts_indexed_access_type,
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_type_assertion,
        .ts_instantiation_expression,
        .ts_named_tuple_member,
        .jsx_attribute,
        .jsx_member_expression,
        .jsx_namespaced_name,
        .bind_expression,
        => blk: {
            var cl = ChildList{};
            cl.add(data.binary.lhs);
            cl.add(data.binary.rhs);
            break :blk cl;
        },

        // member_expr: lhs = object, rhs is a TOKEN (not a node)
        .member_expr,
        .optional_chain_expr,
        => blk: {
            var cl = ChildList{};
            cl.add(data.binary.lhs);
            // rhs is a token index cast as NodeIndex — do NOT include
            break :blk cl;
        },

        // import_expr: binary lhs=source, rhs=options (both may be .none)
        .import_expr => blk: {
            var cl = ChildList{};
            cl.add(data.binary.lhs);
            cl.add(data.binary.rhs);
            break :blk cl;
        },

        // property / computed_property: key=lhs, value=rhs
        .property,
        .computed_property,
        => blk: {
            var cl = ChildList{};
            cl.add(data.binary.lhs);
            cl.add(data.binary.rhs);
            break :blk cl;
        },

        // shorthand_property: data.unary = value (key is derived from value)
        .shorthand_property => blk: {
            var cl = ChildList{};
            cl.add(data.unary);
            break :blk cl;
        },

        // ════════════════════════════════════════════���═══════════════
        // conditional_expr: data.binary.lhs = test,
        //   data.binary.rhs (as ExtraIndex) → extra[0]=consequent, extra[1]=alternate
        // ════════════════════════════════════════════════════════════
        .conditional_expr => blk: {
            var cl = ChildList{};
            cl.add(data.binary.lhs);
            const extra_start = @intFromEnum(data.binary.rhs);
            const consequent: NodeIndex = @enumFromInt(ast.extra_data.items[extra_start]);
            const alternate: NodeIndex = @enumFromInt(ast.extra_data.items[extra_start + 1]);
            cl.add(consequent);
            cl.add(alternate);
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // data.extra → range only (extra[0]=start, extra[1]=end)
        // ════════════════════════════════════════════════════════════
        .sequence_expr,
        .object_expr,
        .array_expr,
        .array_pattern,
        .object_pattern,
        .class_body,
        .ts_tuple_type,
        .ts_union_type,
        .ts_intersection_type,
        .ts_type_parameter_declaration,
        .ts_type_parameter_instantiation,
        .ts_interface_body,
        .ts_type_literal,
        .ts_module_block,
        .flow_union_type,
        .flow_intersection_type,
        .flow_tuple_type,
        .flow_type_parameter_declaration,
        .flow_type_parameter_instantiation,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // var/let/const/using/await_using declaration: extra range of declarators
        .var_declaration,
        .let_declaration,
        .const_declaration,
        .using_declaration,
        .await_using_declaration,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // ts_declare_variable: extra[0]=range_start, extra[1]=range_end (of declarators)
        .ts_declare_variable => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // ═════════════════════════════════════���══════════════════════
        // program: extra[0]=stmts_start, extra[1]=stmts_end
        // ════════════════════════════════════════════════════════════
        .program => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            const range_start = ast.extra_data.items[extra_idx];
            const range_end = ast.extra_data.items[extra_idx + 1];
            cl.range_start = range_start;
            cl.range_end = range_end;
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // block_statement: extra[0]=range_start, extra[1]=range_end
        // ════════════════════════════════════════════════════════════
        .block_statement => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // call_expr / optional_call_expr / new_expr:
        //   extra[0]=callee, extra[1]=args_start, extra[2]=args_end
        // ════════════════════════════════════════════════════════════
        .call_expr,
        .optional_call_expr,
        .new_expr,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            const callee: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx]);
            const args_start = ast.extra_data.items[extra_idx + 1];
            const args_end = ast.extra_data.items[extra_idx + 2];
            cl.add(callee);
            cl.range_start = args_start;
            cl.range_end = args_end;
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // if_statement: extra[0]=test, extra[1]=consequent, extra[2]=alternate
        // ════════════════════════════════════════════════════════════
        .if_statement => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // for_statement: extra[0]=init, [1]=test, [2]=update, [3]=body
        // ════════════════════════════════════════════════════════════
        .for_statement => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3]));
            break :blk cl;
        },

        // for_in_statement: extra[0]=left, [1]=right, [2]=body
        .for_in_statement => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            break :blk cl;
        },

        // for_of_statement / for_of_await_statement: extra[0]=left, [1]=right, [2]=body
        .for_of_statement,
        .for_of_await_statement,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            break :blk cl;
        },

        // try_statement: extra[0]=block, [1]=handler, [2]=finalizer
        .try_statement => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            break :blk cl;
        },

        // switch_statement: extra[0]=discriminant, [1]=cases_start, [2]=cases_end
        .switch_statement => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.range_start = ast.extra_data.items[extra_idx + 1];
            cl.range_end = ast.extra_data.items[extra_idx + 2];
            break :blk cl;
        },

        // switch_case / switch_default: extra[0]=test, [1]=stmts_start, [2]=stmts_end
        .switch_case,
        .switch_default,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // test (or none for default)
            cl.range_start = ast.extra_data.items[extra_idx + 1];
            cl.range_end = ast.extra_data.items[extra_idx + 2];
            break :blk cl;
        },

        // ════════════════════════════���═══════════════════════════════
        // function_declaration/async_function_declaration/generator_declaration/async_generator_declaration:
        //   extra[0]=name_token(NOT node), [1]=params_start, [2]=params_end, [3]=body
        // ════════════════════════════════════════════════════════════
        .function_declaration,
        .async_function_declaration,
        .generator_declaration,
        .async_generator_declaration,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] is name_token — skip (not a node)
            const params_start = ast.extra_data.items[extra_idx + 1];
            const params_end = ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 3]);
            cl.add(body);
            cl.range_start = params_start;
            cl.range_end = params_end;
            break :blk cl;
        },

        // function_expr: extra[0]=name_token, [1]=params_start, [2]=params_end, [3]=body
        .function_expr => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] is name_token — skip
            const params_start = ast.extra_data.items[extra_idx + 1];
            const params_end = ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 3]);
            cl.add(body);
            cl.range_start = params_start;
            cl.range_end = params_end;
            break :blk cl;
        },

        // arrow_function_expr: extra layout varies:
        //   Old format (single param): extra[0]=param, [1]=body, [2]=count (0 or 1)
        //   New format (multi params):  extra[0]=range_start, [1]=range_end, [2]=body
        // We need to detect which format based on the same heuristic as ast_json.
        .arrow_function_expr => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 < ast.extra_data.items.len) {
                const first = ast.extra_data.items[extra_idx];
                const second = ast.extra_data.items[extra_idx + 1];
                const third = ast.extra_data.items[extra_idx + 2];
                if (first == @intFromEnum(NodeIndex.none) or third == 1) {
                    // Old format: param, body, count
                    const param: NodeIndex = @enumFromInt(first);
                    const body: NodeIndex = @enumFromInt(second);
                    cl.add(param);
                    cl.add(body);
                } else {
                    // New format: range_start, range_end, body
                    const body: NodeIndex = @enumFromInt(third);
                    cl.add(body);
                    cl.range_start = first;
                    cl.range_end = second;
                }
            }
            break :blk cl;
        },

        // class_declaration: extra[0]=name_token, [1]=super_class, [2]=body
        .class_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] = name_token (not a node)
            const super_class: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 1]);
            const body: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 2]);
            cl.add(super_class);
            cl.add(body);
            break :blk cl;
        },

        // class_expr: extra[0]=name_token, [1]=super_class, [2]=body
        .class_expr => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] = name_token (not a node)
            const super_class: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 1]);
            const body: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 2]);
            cl.add(super_class);
            cl.add(body);
            break :blk cl;
        },

        // class_field / class_private_field: extra[0]=key, [1]=value, [2]=flags
        .class_field,
        .class_private_field,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // key
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // value
            break :blk cl;
        },

        // class_method / class_private_method: extra[0]=key, [1]=params_start, [2]=params_end, [3]=body
        .class_method,
        .class_private_method,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx]);
            const params_start = ast.extra_data.items[extra_idx + 1];
            const params_end = ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 3]);
            cl.add(key);
            cl.add(body);
            cl.range_start = params_start;
            cl.range_end = params_end;
            break :blk cl;
        },

        // method_definition (ObjectMethod kind="method"):
        //   extra[0]=key, [1]=params_start, [2]=params_end, [3]=body
        .method_definition => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx]);
            const params_start = ast.extra_data.items[extra_idx + 1];
            const params_end = ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 3]);
            cl.add(key);
            cl.add(body);
            cl.range_start = params_start;
            cl.range_end = params_end;
            break :blk cl;
        },

        // getter / setter:
        //   extra[0]=params_start, [1]=params_end, [2]=body, [3]=flags, [4]=computed_key
        .getter,
        .setter,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            const params_start = ast.extra_data.items[extra_idx];
            const params_end = ast.extra_data.items[extra_idx + 1];
            const body: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 2]);
            const flags = if (extra_idx + 3 < ast.extra_data.items.len)
                ast.extra_data.items[extra_idx + 3]
            else
                0;
            const is_computed = (flags & 8) != 0;
            if (is_computed and extra_idx + 4 < ast.extra_data.items.len) {
                cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 4])); // computed key node
            }
            cl.add(body);
            cl.range_start = params_start;
            cl.range_end = params_end;
            break :blk cl;
        },

        // computed_method: extra[0]=key, [1]=params_start, [2]=params_end, [3]=body
        .computed_method => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            const key: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx]);
            const params_start = ast.extra_data.items[extra_idx + 1];
            const params_end = ast.extra_data.items[extra_idx + 2];
            const body: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 3]);
            cl.add(key);
            cl.add(body);
            cl.range_start = params_start;
            cl.range_end = params_end;
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // Module declarations
        // ════════════════════════════════════════════════════════════

        // import_declaration / import_declaration_type / import_declaration_typeof:
        //   extra[0]=source_token(NOT node), [1]=specs_start, [2]=specs_end,
        //   optional [3]=attrs_start, [4]=attrs_end
        .import_declaration,
        .import_declaration_type,
        .import_declaration_typeof,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] = source_token — not a node
            cl.range_start = ast.extra_data.items[extra_idx + 1];
            cl.range_end = ast.extra_data.items[extra_idx + 2];
            // Optional attributes range
            if (extra_idx + 4 < ast.extra_data.items.len) {
                cl.range2_start = ast.extra_data.items[extra_idx + 3];
                cl.range2_end = ast.extra_data.items[extra_idx + 4];
            }
            break :blk cl;
        },

        // import_specifier / import_specifier_type / import_specifier_typeof:
        //   extra[0]=imported_token, [1]=local_token — all tokens, 0 children
        .import_specifier,
        .import_specifier_type,
        .import_specifier_typeof,
        => .{},

        // export_specifier / export_specifier_type:
        //   extra[0]=local_token, [1]=exported_token — all tokens, 0 children
        .export_specifier,
        .export_specifier_type,
        => .{},

        // export_namespace_specifier: data.unary = exported name token (not a node)
        .export_namespace_specifier => .{},

        // export_named / export_named_type:
        //   extra[0]=source_token, [1]=specs_start, [2]=specs_end, [3]=declaration, ...
        .export_named,
        .export_named_type,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] = source_token — not a node
            const specs_start = ast.extra_data.items[extra_idx + 1];
            const specs_end = ast.extra_data.items[extra_idx + 2];
            // Declaration (may be none)
            if (extra_idx + 3 < ast.extra_data.items.len) {
                const decl: NodeIndex = @enumFromInt(ast.extra_data.items[extra_idx + 3]);
                cl.add(decl);
            }
            cl.range_start = specs_start;
            cl.range_end = specs_end;
            // Attributes range (indices 4 and 5)
            if (extra_idx + 5 < ast.extra_data.items.len) {
                cl.range2_start = ast.extra_data.items[extra_idx + 4];
                cl.range2_end = ast.extra_data.items[extra_idx + 5];
            }
            break :blk cl;
        },

        // export_all: extra[0]=source_token, [1]=attrs_start, [2]=attrs_end
        // source_token is a token, not a node
        .export_all => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            if (extra_idx + 2 < ast.extra_data.items.len) {
                cl.range_start = ast.extra_data.items[extra_idx + 1];
                cl.range_end = ast.extra_data.items[extra_idx + 2];
            }
            break :blk cl;
        },

        // module_expression: extra[0]=body_start, [1]=body_end (range of statements)
        .module_expression => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // template_literal: complex layout with num_expressions, etc.
        // We extract expression children only (quasis are tokens).
        // ════════════════════════════════════════════════════════════
        .template_literal => blk: {
            var cl = ChildList{};
            // Check if it's a no-sub template (main_token is template_no_sub)
            const mt = ast.nodes.items(.main_token)[i];
            const mt_tag = ast.tokens.items(.tag)[@intFromEnum(mt)];
            if (mt_tag != .template_no_sub) {
                const extra_idx = @intFromEnum(data.extra);
                const num_expressions = ast.extra_data.items[extra_idx];
                const exprs_start = extra_idx + 1;
                // expressions are stored as node indices starting at extra[1]
                cl.range_start = @intCast(exprs_start);
                cl.range_end = @intCast(exprs_start + num_expressions);
            }
            break :blk cl;
        },

        // tagged_template_expr: extra[0]=tag, [1]=quasi
        .tagged_template_expr => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // tag
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // quasi
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // JSX
        // ════════════════════════════════════════════════════════════

        // jsx_element: extra[0]=opening, [1]=closing, [2]=children_start, [3]=children_end
        .jsx_element => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // opening
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // closing
            cl.range_start = ast.extra_data.items[extra_idx + 2];
            cl.range_end = ast.extra_data.items[extra_idx + 3];
            break :blk cl;
        },

        // jsx_opening_element / jsx_self_closing_element:
        //   extra[0]=name, [1]=attrs_start, [2]=attrs_end
        .jsx_opening_element,
        .jsx_self_closing_element,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // name
            cl.range_start = ast.extra_data.items[extra_idx + 1];
            cl.range_end = ast.extra_data.items[extra_idx + 2];
            break :blk cl;
        },

        // jsx_fragment: extra[0]=opening, [1]=closing, [2]=children_start, [3]=children_end
        .jsx_fragment => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.range_start = ast.extra_data.items[extra_idx + 2];
            cl.range_end = ast.extra_data.items[extra_idx + 3];
            break :blk cl;
        },

        // jsx_opening_fragment / jsx_closing_fragment: 0 children
        .jsx_opening_fragment,
        .jsx_closing_fragment,
        => .{},

        // ════════════════════════════════════════════════════════════
        // TypeScript
        // ════════════════════════════════════════════════════════════

        // ts_conditional_type: extra[0]=check, [1]=extends, [2]=true, [3]=false
        .ts_conditional_type => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3]));
            break :blk cl;
        },

        // ts_mapped_type: extra[0]=typeParam, [1]=typeAnnotation, [2]=nameType
        .ts_mapped_type => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // typeParameter
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // typeAnnotation
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2])); // nameType
            break :blk cl;
        },

        // ts_type_parameter: extra[0]=constraint, [1]=default, [2]=name_token, [3]=flags
        // name_token and flags are not nodes
        .ts_type_parameter => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // constraint
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // default
            break :blk cl;
        },

        // ts_function_type / ts_constructor_type:
        //   extra[0]=typeParameters, [1]=params_start, [2]=params_end, [3]=returnType
        .ts_function_type,
        .ts_constructor_type,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // typeParameters
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3])); // returnType
            cl.range_start = ast.extra_data.items[extra_idx + 1];
            cl.range_end = ast.extra_data.items[extra_idx + 2];
            break :blk cl;
        },

        // ts_type_predicate: extra[0]=parameterName, [1]=typeAnnotation, [2]=asserts_flag
        .ts_type_predicate => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // ts_import_type: extra[0]=argument, [1]=qualifier, [2]=typeParameters, [3]=options
        .ts_import_type => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            if (ast.extra_data.items.len > extra_idx + 3) {
                cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3]));
            }
            break :blk cl;
        },

        // ts_template_literal_type: extra[0]=types_start, [1]=types_end, [2]=toks_start, [3]=toks_end
        // Only types are child nodes (quasis are token indices).
        .ts_template_literal_type => blk: {
            var cl = ChildList{};
            const mt = ast.nodes.items(.main_token)[i];
            const mt_tag = ast.tokens.items(.tag)[@intFromEnum(mt)];
            if (mt_tag != .template_no_sub) {
                const extra_idx = @intFromEnum(data.extra);
                cl.range_start = ast.extra_data.items[extra_idx];
                cl.range_end = ast.extra_data.items[extra_idx + 1];
            }
            break :blk cl;
        },

        // ts_type_cast_expression: extra[0]=expression, [1]=typeAnnotation
        .ts_type_cast_expression => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // ts_type_alias_declaration: extra[0]=id, [1]=typeAnnotation, [2]=typeParameters
        .ts_type_alias_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            break :blk cl;
        },

        // ts_interface_declaration: extra[0]=id, [1]=typeParams, [2]=body, [3]=extends_start, [4]=extends_end
        .ts_interface_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // id
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // typeParams
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2])); // body
            cl.range_start = ast.extra_data.items[extra_idx + 3];
            cl.range_end = ast.extra_data.items[extra_idx + 4];
            break :blk cl;
        },

        // ts_property_signature: extra[0]=key, [1]=type_ann, [2]=flags
        .ts_property_signature => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // ts_method_signature: extra[0]=key, [1]=type_params, [2..3]=params range, [4]=return_type
        .ts_method_signature => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // key
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // type_params
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 4])); // return_type
            cl.range_start = ast.extra_data.items[extra_idx + 2];
            cl.range_end = ast.extra_data.items[extra_idx + 3];
            break :blk cl;
        },

        // ts_index_signature: extra[0]=param(node), [1]=unused?, [2]=typeAnnotation
        .ts_index_signature => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            break :blk cl;
        },

        // ts_call_signature_declaration / ts_construct_signature_declaration:
        //   extra[0]=typeParams, [1..2]=params range, [3]=returnType
        .ts_call_signature_declaration,
        .ts_construct_signature_declaration,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // typeParams
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3])); // returnType
            cl.range_start = ast.extra_data.items[extra_idx + 1];
            cl.range_end = ast.extra_data.items[extra_idx + 2];
            break :blk cl;
        },

        // ts_enum_declaration: extra[0]=id, [1..2]=members range, [3]=const_flag, [4..5]=body tokens
        .ts_enum_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // id
            cl.range_start = ast.extra_data.items[extra_idx + 1];
            cl.range_end = ast.extra_data.items[extra_idx + 2];
            break :blk cl;
        },

        // ts_module_declaration: extra[0]=id, [1]=body
        .ts_module_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // ts_declare_function: extra[0]=id, [1]=typeParams, [2..3]=params range, [4]=returnType, [5]=body
        .ts_declare_function => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // id
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // typeParams
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 4])); // returnType
            if (extra_idx + 5 < ast.extra_data.items.len) {
                cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 5])); // body
            }
            cl.range_start = ast.extra_data.items[extra_idx + 2];
            cl.range_end = ast.extra_data.items[extra_idx + 3];
            break :blk cl;
        },

        // ts_declare_method: extra[0]=key, [1..2]=params range, [3]=unused?, [4]=flags
        .ts_declare_method => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // key
            cl.range_start = ast.extra_data.items[extra_idx + 1];
            cl.range_end = ast.extra_data.items[extra_idx + 2];
            break :blk cl;
        },

        // ts_parameter_property: extra[0]=parameter(node), [1]=flags
        .ts_parameter_property => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            break :blk cl;
        },

        // ts_import_equals_declaration: extra[0]=id_token, [1]=moduleReference(node), [2]=is_type
        .ts_import_equals_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] is id_token — not a node
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // moduleReference
            break :blk cl;
        },

        // ════════════════════════════════════════════════════════════
        // Flow types
        // ════════════════════════════════════════════════════════════

        // flow_generic_type: extra[0]=id, [1]=typeParameters
        .flow_generic_type => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // flow_qualified_type_identifier: extra[0]=qualification(node), [1]=member_token
        .flow_qualified_type_identifier => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // qualification
            // extra[1] is a token, not a node
            break :blk cl;
        },

        // flow_object_type / flow_exact_object_type: extra[0]=range_start, [1]=range_end, [2]=inexact_flag
        .flow_object_type,
        .flow_exact_object_type,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // flow_object_type_property: extra[0]=value(node), [1]=key_token, [2]=variance_token, [3]=flags
        .flow_object_type_property => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // value/func type
            // key_token and variance_token are tokens, not nodes
            break :blk cl;
        },

        // flow_object_type_indexer: extra[0]=name_token, [1]=key_type, [2]=value_type
        .flow_object_type_indexer => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] is name_token — not a node
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // key_type
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2])); // value_type
            break :blk cl;
        },

        // flow_object_type_call_property: extra[0]=func_type(node), [1]=flags
        .flow_object_type_call_property => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            break :blk cl;
        },

        // flow_object_type_internal_slot: extra[0]=name_token, [1]=value_type(node), [2]=flags
        .flow_object_type_internal_slot => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] is name_token — not a node
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // flow_type_alias / flow_declare_type_alias: extra[0]=name_token, [1]=typeParams, [2]=right
        .flow_type_alias,
        .flow_declare_type_alias,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] is name_token — not a node
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // typeParams
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2])); // right
            break :blk cl;
        },

        // flow_opaque_type: extra[0]=name_token, [1]=typeParams, [2]=supertype, [3]=impltype
        .flow_opaque_type => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3]));
            break :blk cl;
        },

        // flow_interface_declaration: extra[0]=name_token, [1]=typeParams, [2..3]=extends range, [4]=body
        .flow_interface_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // typeParams
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 4])); // body
            cl.range_start = ast.extra_data.items[extra_idx + 2];
            cl.range_end = ast.extra_data.items[extra_idx + 3];
            break :blk cl;
        },

        // flow_interface_body: 0 children in the structural sense
        // (ast_json just emits "InterfaceBody" with a position — the body members
        //  are in the parent's range, not in the body node itself)
        .flow_interface_body => .{},

        // flow_interface_extends: extra[0]=id(node), [1]=typeParameters(node)
        .flow_interface_extends => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // flow_declare_class: extra[0]=name_token, [1]=typeParams, [2..3]=extends, [4..5]=implements, [6]=body, [7..8]=mixins
        .flow_declare_class => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // typeParams
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 6])); // body
            cl.range_start = ast.extra_data.items[extra_idx + 2]; // extends range
            cl.range_end = ast.extra_data.items[extra_idx + 3];
            cl.range2_start = ast.extra_data.items[extra_idx + 4]; // implements range
            cl.range2_end = ast.extra_data.items[extra_idx + 5];
            break :blk cl;
        },

        // flow_declare_function: extra[0]=name_token, [1]=typeParams, [2]=funcType, [3]=predicate
        .flow_declare_function => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            // extra[0] is name_token — not a node
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // typeParams
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2])); // funcType
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3])); // predicate
            break :blk cl;
        },

        // flow_declare_variable: extra[0]=kind_token, [1]=name_token, [2]=typeAnnotation(node)
        .flow_declare_variable => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            break :blk cl;
        },

        // flow_declare_module: extra[0]=name_token, [1]=lbrace_token, [2..3]=body range
        .flow_declare_module => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.range_start = ast.extra_data.items[extra_idx + 2];
            cl.range_end = ast.extra_data.items[extra_idx + 3];
            break :blk cl;
        },

        // flow_declare_module_exports: extra[0]=colon_token, [1]=type(node)
        .flow_declare_module_exports => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // flow_declare_export_declaration: extra[0]=declaration, [1]=flags, [2]=source_token, [3..4]=specs range
        .flow_declare_export_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // declaration
            cl.range_start = ast.extra_data.items[extra_idx + 3];
            cl.range_end = ast.extra_data.items[extra_idx + 4];
            break :blk cl;
        },

        // flow_declare_export_all_declaration: extra[0]=source_token, [1]=exportKind_flag
        // No child nodes (source is a token).
        .flow_declare_export_all_declaration => .{},

        // flow_declare_interface: extra[0]=name_token, [1]=typeParams, [2..3]=extends range, [4]=body
        .flow_declare_interface => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 4]));
            cl.range_start = ast.extra_data.items[extra_idx + 2];
            cl.range_end = ast.extra_data.items[extra_idx + 3];
            break :blk cl;
        },

        // flow_declare_opaque_type: extra[0]=name_token, [1]=typeParams, [2]=supertype, [3]=impltype
        .flow_declare_opaque_type => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3]));
            break :blk cl;
        },

        // flow_type_parameter: extra[0]=bound, [1]=default, [2]=variance_flag, [3]=variance_token
        .flow_type_parameter => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx])); // bound
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1])); // default
            break :blk cl;
        },

        // flow_type_cast_expression: extra[0]=expression, [1]=type
        .flow_type_cast_expression => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // flow_function_type_annotation:
        //   extra[0..1]=params range, [2]=return_type, [3]=rest_param, [4]=typeParams, [5]=this_param
        .flow_function_type_annotation => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2])); // return_type
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 3])); // rest_param
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 4])); // typeParams
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 5])); // this_param
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // flow_function_type_param: extra[0]=type(node), [1]=flags
        .flow_function_type_param => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            break :blk cl;
        },

        // flow_indexed_access_type / flow_optional_indexed_access_type:
        //   extra[0]=objectType, [1]=indexType
        .flow_indexed_access_type,
        .flow_optional_indexed_access_type,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx]));
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // flow_interface_type_annotation: extra[0..1]=extends range, [2]=body
        .flow_interface_type_annotation => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 2])); // body
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // flow_enum_declaration: extra[0]=name_token, [1]=body(node)
        .flow_enum_declaration => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.add(@enumFromInt(ast.extra_data.items[extra_idx + 1]));
            break :blk cl;
        },

        // flow_enum_boolean_body / number / string / symbol:
        //   extra[0..1]=members range, [2]=has_unknown
        .flow_enum_boolean_body,
        .flow_enum_number_body,
        .flow_enum_string_body,
        .flow_enum_symbol_body,
        => blk: {
            var cl = ChildList{};
            const extra_idx = @intFromEnum(data.extra);
            cl.range_start = ast.extra_data.items[extra_idx];
            cl.range_end = ast.extra_data.items[extra_idx + 1];
            break :blk cl;
        },

        // flow_enum_boolean_member / number / string: data.unary = init value (node)
        .flow_enum_boolean_member,
        .flow_enum_number_member,
        .flow_enum_string_member,
        => blk: {
            var cl = ChildList{};
            cl.add(data.unary);
            break :blk cl;
        },
    };
}
