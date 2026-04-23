const std = @import("std");
const Token = @import("token.zig").Token;
const Comment = @import("lexer.zig").Comment;

pub const TokenIndex = @import("token.zig").TokenIndex;
pub const NodeIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ExtraIndex = enum(u32) { _ };

pub const SourceType = enum { script, module };
pub const Language = enum {
    javascript,
    typescript,
    jsx,
    tsx,
    flow,

    pub fn isTypeScript(self: Language) bool {
        return self == .typescript or self == .tsx;
    }

    pub fn isJSX(self: Language) bool {
        return self == .jsx or self == .tsx or self == .flow;
    }

    pub fn isFlow(self: Language) bool {
        return self == .flow;
    }
};

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,
    end_offset: u32 = 0,

    pub const Tag = enum(u16) {
        // === Literals ===
        numeric_literal,
        string_literal,
        boolean_literal,
        null_literal,
        regex_literal,
        bigint_literal,
        template_literal,

        // === Expressions ===
        identifier,
        v8_intrinsic_identifier,
        this_expr,
        super_expr,
        binary_expr,
        unary_expr,
        update_expr,
        logical_expr,
        conditional_expr,
        assignment_expr,
        sequence_expr,
        call_expr,
        new_expr,
        member_expr,
        computed_member_expr,
        optional_chain_expr,
        optional_computed_member_expr,
        optional_call_expr,
        arrow_function_expr,
        function_expr,
        class_expr,
        yield_expr,
        yield_delegate_expr,
        await_expr,
        spread_element,
        tagged_template_expr,
        meta_property,
        import_expr,
        private_name,
        parenthesized_expr,
        object_expr,
        array_expr,

        // === Object/Array internals ===
        property,
        shorthand_property,
        computed_property,
        computed_method,
        method_definition,
        getter,
        setter,

        // === Patterns ===
        array_pattern,
        object_pattern,
        assignment_pattern,
        rest_element,

        // === Declarations ===
        var_declaration,
        let_declaration,
        const_declaration,
        using_declaration,
        await_using_declaration,
        declarator,
        function_declaration,
        async_function_declaration,
        generator_declaration,
        async_generator_declaration,
        class_declaration,

        // === Class internals ===
        class_body,
        class_field,
        class_static_block,
        class_method,
        class_private_field,
        class_private_method,

        // === Transform-only ===
        removed, // Node removed by a transform pass — codegen emits nothing

        // === Statements ===
        block_statement,
        expression_statement,
        empty_statement,
        if_statement,
        for_statement,
        for_in_statement,
        for_of_statement,
        for_of_await_statement,
        while_statement,
        do_while_statement,
        switch_statement,
        switch_case,
        switch_default,
        return_statement,
        throw_statement,
        try_statement,
        catch_clause,
        break_statement,
        continue_statement,
        labeled_statement,
        with_statement,
        debugger_statement,

        // === Module ===
        import_declaration,
        import_declaration_typeof,
        import_specifier,
        import_default,
        import_namespace,
        import_attribute, // ImportAttribute — binary: { lhs = key, rhs = value }
        export_named,
        export_default,
        export_all,
        module_expression, // module { ... }
        export_specifier,
        export_specifier_type, // { type Foo } in export
        export_namespace_specifier,

        // === Directives ===
        directive, // data: binary { lhs = directive_literal, rhs = unused }
        directive_literal, // main_token = string token

        // === JSX ===
        jsx_element,
        jsx_opening_element,
        jsx_closing_element,
        jsx_self_closing_element,
        jsx_fragment,
        jsx_opening_fragment,
        jsx_closing_fragment,
        jsx_attribute,
        jsx_spread_attribute,
        jsx_spread_child,
        jsx_expression_container,
        jsx_string_literal,
        jsx_empty_expression,
        jsx_text,
        jsx_identifier,
        jsx_member_expression,
        jsx_namespaced_name,

        // === TypeScript Basic Types ===
        ts_type_annotation, // : Type
        ts_type_reference, // Foo<T> — binary: { lhs = typeName, rhs = typeParameters or .none }
        ts_keyword_type, // string, number, boolean, etc. — main_token = keyword token
        ts_array_type, // T[] — unary: elementType
        ts_tuple_type, // [T, U] — extra: [start, end]
        ts_union_type, // T | U — extra: [start, end]
        ts_intersection_type, // T & U — extra: [start, end]
        ts_function_type, // (params) => RetType — extra: [typeParameters, params_start, params_end, returnType]
        ts_constructor_type, // new (params) => RetType — extra: [typeParameters, params_start, params_end, returnType]
        ts_parenthesized_type, // (Type) — unary: type
        ts_optional_type, // T? — unary: type
        ts_rest_type, // ...T — unary: type
        ts_literal_type, // literal value as type — unary: literal node
        ts_type_parameter, // T extends U = D — extra: [name/constraint, constraint/default, default]
        ts_type_parameter_declaration, // <T, U> — extra: [start, end]
        ts_type_parameter_instantiation, // <T, U> — extra: [start, end]
        ts_qualified_name, // A.B — binary: { lhs = left, rhs = right }

        // === TypeScript Advanced Types ===
        ts_conditional_type, // T extends U ? X : Y — extra: [checkType, extendsType, trueType, falseType]
        ts_infer_type, // infer T — unary: type_parameter
        ts_mapped_type, // { [K in T]: V } — extra: [typeParameter, typeAnnotation, nameType, optional_modifier, readonly_modifier]
        ts_indexed_access_type, // T[K] — binary: { lhs = objectType, rhs = indexType }
        ts_template_literal_type, // `hello ${T}` — extra: [types_start, types_end]
        ts_typeof_type, // typeof x — unary: expression
        ts_type_operator, // keyof T, unique symbol, readonly T[] — unary: type; main_token = operator
        ts_type_predicate, // x is Type — extra: [parameterName, typeAnnotation, asserts_flag]
        ts_import_type, // import("mod").Type — extra: [argument, qualifier, typeParameters]
        ts_named_tuple_member, // label: Type — binary: { lhs = label, rhs = elementType }

        // === TypeScript Expressions ===
        ts_as_expression, // expr as Type — binary: { lhs = expression, rhs = typeAnnotation }
        ts_satisfies_expression, // expr satisfies Type — binary: { lhs = expression, rhs = typeAnnotation }
        ts_non_null_expression, // expr! — unary: expression
        ts_type_assertion, // <Type>expr — binary: { lhs = typeAnnotation, rhs = expression }
        ts_instantiation_expression, // expr<Type> — binary: { lhs = expression, rhs = typeArguments }
        ts_type_cast_expression, // (x: Type) — extra: [expression, typeAnnotation]

        // === TypeScript Declarations ===
        ts_type_alias_declaration, // type Foo = Type
        ts_interface_declaration, // interface Foo { ... }
        ts_interface_body, // { ... }
        ts_type_literal, // { ... } (type literal, not interface body)
        ts_property_signature, // key: Type
        ts_method_signature, // method(params): Type
        ts_index_signature, // [key: string]: Type
        ts_call_signature_declaration, // (params): Type
        ts_construct_signature_declaration, // new (params): Type
        ts_enum_declaration, // enum Foo { ... }
        ts_enum_member, // A = 1
        ts_module_declaration, // namespace/module Foo { ... }
        ts_module_block, // { ... } (module body)
        ts_declare_function, // declare function foo(): void
        ts_declare_variable, // declare var/let/const x: Type
        ts_declare_method, // class/constructor signature without body in TS

        // === TypeScript Class Extensions ===
        ts_parameter_property, // constructor(public x: T)

        // === TypeScript Import/Export ===
        ts_import_equals_declaration, // import x = require("...")
        ts_export_assignment, // export = expr
        ts_namespace_export_declaration, // export as namespace X
        ts_external_module_reference, // require("...") in import =
        import_declaration_type, // import type { Foo } from "bar"
        import_specifier_type, // { type Foo } in import
        import_specifier_typeof, // { typeof Foo } in import
        export_named_type, // export type { Foo }

        // === Program ===
        program,

        // === Flow Core Types ===
        flow_type_annotation, // : Type (TypeAnnotation wrapper)
        flow_generic_type, // Foo<T>
        flow_qualified_type_identifier, // A.B.C
        flow_nullable_type, // ?Type
        flow_union_type, // A | B
        flow_intersection_type, // A & B
        flow_typeof_type, // typeof X
        flow_array_type, // Type[]
        flow_tuple_type, // [A, B]
        flow_number_type, // number
        flow_string_type, // string
        flow_boolean_type, // boolean
        flow_void_type, // void
        flow_mixed_type, // mixed
        flow_empty_type, // empty
        flow_any_type, // any
        flow_symbol_type, // symbol
        flow_bigint_type, // bigint
        flow_null_literal_type, // null
        flow_number_literal_type, // 42
        flow_string_literal_type, // "foo"
        flow_boolean_literal_type, // true/false
        flow_bigint_literal_type, // 42n
        flow_exists_type, // *
        flow_object_type, // { ... }
        flow_object_type_property, // key: Type
        flow_object_type_spread_property, // ...Type
        flow_object_type_indexer, // [key: Type]: Type
        flow_object_type_call_property, // (params): ReturnType
        flow_object_type_internal_slot, // [[Slot]]: Type
        flow_exact_object_type, // {| ... |}
        flow_type_alias, // type Foo = Type
        flow_declare_type_alias, // declare type Foo = Type
        flow_opaque_type, // opaque type Foo = Type
        flow_interface_declaration, // interface Foo { ... }
        flow_interface_body, // { ... } (of interface)
        flow_interface_extends, // extends Foo
        flow_declare_class, // declare class Foo { ... }
        flow_declare_function, // declare function foo(): void
        flow_declare_variable, // declare var/let/const x: Type
        flow_declare_module, // declare module "foo" { ... }
        flow_declare_module_exports, // declare module.exports: Type
        flow_declare_export_declaration, // declare export ...
        flow_declare_export_all_declaration, // declare export * from "..."
        flow_declare_interface, // declare interface Foo { ... }
        flow_declare_opaque_type, // declare opaque type Foo
        flow_type_parameter, // T
        flow_type_parameter_declaration, // <T, U>
        flow_type_parameter_instantiation, // <T, U>
        flow_type_cast_expression, // (x: Type)

        // === Flow Advanced ===
        flow_function_type_annotation, // (a: T, b: U) => V
        flow_function_type_param, // a: T (parameter in function type)
        flow_indexed_access_type, // T[K]
        flow_optional_indexed_access_type, // T?.[K]
        flow_inferred_predicate, // %checks
        flow_declared_predicate, // %checks(expr)
        flow_this_type_annotation, // this (as type)
        flow_interface_type_annotation, // interface { ... } or interface extends X { ... }
        flow_variance, // +/- variance annotation
        flow_parenthesized_type, // (Type) — unary: type

        // Flow enum
        flow_enum_declaration,
        flow_enum_boolean_body,
        flow_enum_number_body,
        flow_enum_string_body,
        flow_enum_symbol_body,
        flow_enum_boolean_member,
        flow_enum_number_member,
        flow_enum_string_member,
        flow_enum_default_member,

        // === Proposal: Pipeline Operator ===
        topic_reference, // %, #, ^, ^^, @@ in pipeline — main_token = topic token

        // === Proposal: Decorators ===
        decorator, // @expr — unary: expression

        // === Proposal: Placeholders ===
        placeholder, // %%Name%% — main_token = identifier inside %%, data.token = expectedNode context

        // === Proposal: do-expressions ===
        do_expression, // do { ... } or async do { ... } — unary: block body; async flag in async_arrow_flags

        // === Proposal: throw expressions ===
        throw_expression, // throw expr (as expression) — unary: argument

        // === Proposal: export default from ===
        export_default_specifier, // export v from "mod" — main_token = exported identifier

        // === Proposal: bind operator ===
        bind_expression, // ::obj.method — binary: { lhs = object (or none), rhs = callee }
    };

    pub const Data = union {
        binary: struct { lhs: NodeIndex, rhs: NodeIndex },
        unary: NodeIndex,
        extra: ExtraIndex,
        token: TokenIndex,
        none: void,
    };
};

/// Range of comment indices into comments array.
pub const CommentRange = struct { start: u32, end: u32 };

/// Range of extra_data indices.
pub const ExtraRange = struct { start: u32, end: u32 };

pub const DeferredNodeIndexSideTableRecord = struct {
    node: u32,
    value: NodeIndex,
};

fn growDenseSideTableLen(current: usize, minimum: usize) usize {
    var new_len = current;
    while (new_len < minimum) {
        const bump = new_len / 2 + 32;
        const grown = new_len +| bump;
        if (grown <= new_len) return minimum;
        new_len = grown;
    }
    return new_len;
}

pub fn DenseValueSideTable(comptime T: type, comptime empty: T) type {
    return struct {
        values: std.ArrayListUnmanaged(T) = .empty,

        const Self = @This();

        fn ensureSlot(self: *Self, allocator: std.mem.Allocator, key: u32) !void {
            const target_len: usize = @as(usize, key) + 1;
            const old_len = self.values.items.len;
            if (target_len <= old_len) return;
            try self.values.resize(allocator, growDenseSideTableLen(old_len, target_len));
            for (self.values.items[old_len..]) |*slot| slot.* = empty;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, key: u32, value: T) !void {
            try self.ensureSlot(allocator, key);
            self.values.items[key] = value;
        }

        pub fn get(self: *const Self, key: u32) ?T {
            if (key >= self.values.items.len) return null;
            const value = self.values.items[key];
            if (value == empty) return null;
            return value;
        }

        pub fn contains(self: *const Self, key: u32) bool {
            return self.get(key) != null;
        }

        pub fn remove(self: *Self, key: u32) bool {
            if (key >= self.values.items.len) return false;
            if (self.values.items[key] == empty) return false;
            self.values.items[key] = empty;
            return true;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.values.items.len = 0;
        }

        pub fn clearRange(self: *Self, start: u32, end: u32) void {
            if (start >= end) return;
            if (start >= self.values.items.len) return;
            const slice_end = @min(@as(usize, end), self.values.items.len);
            for (self.values.items[@as(usize, start)..slice_end]) |*slot| slot.* = empty;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.values.deinit(allocator);
        }
    };
}

pub const DenseNodeIndexSideTable = DenseValueSideTable(NodeIndex, .none);

pub const DenseFlagSideTable = struct {
    values: std.ArrayListUnmanaged(bool) = .empty,

    const Self = @This();

    fn ensureSlot(self: *Self, allocator: std.mem.Allocator, key: u32) !void {
        const target_len: usize = @as(usize, key) + 1;
        const old_len = self.values.items.len;
        if (target_len <= old_len) return;
        try self.values.resize(allocator, growDenseSideTableLen(old_len, target_len));
        @memset(self.values.items[old_len..], false);
    }

    pub fn put(self: *Self, allocator: std.mem.Allocator, key: u32, _: void) !void {
        try self.ensureSlot(allocator, key);
        self.values.items[key] = true;
    }

    pub fn get(self: *const Self, key: u32) ?void {
        if (!self.contains(key)) return null;
        return {};
    }

    pub fn contains(self: *const Self, key: u32) bool {
        return key < self.values.items.len and self.values.items[key];
    }

    pub fn remove(self: *Self, key: u32) bool {
        if (!self.contains(key)) return false;
        self.values.items[key] = false;
        return true;
    }

    pub fn clearRetainingCapacity(self: *Self) void {
        self.values.items.len = 0;
    }

    pub fn clearRange(self: *Self, start: u32, end: u32) void {
        if (start >= end) return;
        if (start >= self.values.items.len) return;
        const slice_end = @min(@as(usize, end), self.values.items.len);
        @memset(self.values.items[@as(usize, start)..slice_end], false);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }
};

pub const Ast = struct {
    const Self = @This();

    source: []const u8,
    tokens: std.MultiArrayList(Token),
    nodes: std.MultiArrayList(Node),
    extra_data: std.ArrayList(u32),
    line_offsets: std.ArrayList(u32),
    comments: std.ArrayList(Comment),
    allocator: std.mem.Allocator,
    source_type: SourceType = .script,
    hashbang_end: ?u32 = null,

    // Comment attachment side tables (keyed by @intFromEnum(NodeIndex))
    leading_comments: std.AutoHashMapUnmanaged(u32, CommentRange) = .empty,
    trailing_comments: std.AutoHashMapUnmanaged(u32, CommentRange) = .empty,
    inner_comments: std.AutoHashMapUnmanaged(u32, CommentRange) = .empty,
    comments_attached: bool = false,
    deferred_type_side_tables_materialized: bool = true,

    // Flow type annotation side tables (keyed by @intFromEnum(NodeIndex))
    type_annotations: DenseNodeIndexSideTable = .{},
    return_types: DenseNodeIndexSideTable = .{},
    type_parameters: DenseNodeIndexSideTable = .{},
    type_annotation_records: std.ArrayListUnmanaged(DeferredNodeIndexSideTableRecord) = .empty,
    return_type_records: std.ArrayListUnmanaged(DeferredNodeIndexSideTableRecord) = .empty,
    type_parameter_records: std.ArrayListUnmanaged(DeferredNodeIndexSideTableRecord) = .empty,
    super_type_parameters: DenseNodeIndexSideTable = .{},
    implements_list: std.AutoHashMapUnmanaged(u32, ExtraRange) = .empty,
    predicate_map: DenseNodeIndexSideTable = .{},
    variance_map: DenseNodeIndexSideTable = .{},
    ts_class_modifiers: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    ts_optional_params: DenseFlagSideTable = .{},
    async_arrow_flags: DenseFlagSideTable = .{},
    node_start_overrides: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    operator_overrides: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    decorators_map: std.AutoHashMapUnmanaged(u32, ExtraRange) = .empty,
    placeholder_contexts: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    placeholder_name_nodes: DenseNodeIndexSideTable = .{},
    jsx_token_flags: std.AutoHashMapUnmanaged(u32, u8) = .empty, // Token index → JSX token type (0=jsxTagStart, 1=jsxTagEnd, =jsxName)
    replacement_source: std.AutoHashMapUnmanaged(u32, []const u8) = .empty, // NodeIndex → replacement source text (set by transform passes)
    replacement_needs_reindent: std.AutoHashMapUnmanaged(u32, void) = .empty, // NodeIndex → flag: replacement_source should be re-indented by codegen
    block_prefix_source: std.AutoHashMapUnmanaged(u32, []const u8) = .empty, // BlockStatement NodeIndex → text to insert at start of body (set by arrow-functions transform)
    consumed_comments: std.AutoHashMapUnmanaged(u32, void) = .empty, // Source positions of comments already handled by transform passes
    language: Language = .javascript,
    create_import_expressions: bool = true, // when false, serialize import() as CallExpression
    create_parenthesized_expressions: bool = false, // when true, emit ParenthesizedExpression nodes
    has_import_phase: bool = false, // when true, emit "phase" field on imports
    emit_ranges: bool = false, // when true, emit "range":[start,end] on each node
    start_index: u32 = 0, // offset added to all position indices
    start_line: u32 = 1, // starting line number (default 1)
    start_column: u32 = 0, // offset added to first line's column
    source_filename: ?[]const u8 = null, // when set, emit "filename" in loc objects
    emit_tokens: bool = false, // when true, emit "tokens" array on File node

    pub fn deinit(self: *Ast) void {
        self.tokens.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.extra_data.deinit(self.allocator);
        self.line_offsets.deinit(self.allocator);
        self.comments.deinit(self.allocator);
        self.leading_comments.deinit(self.allocator);
        self.trailing_comments.deinit(self.allocator);
        self.inner_comments.deinit(self.allocator);
        self.type_annotations.deinit(self.allocator);
        self.return_types.deinit(self.allocator);
        self.type_parameters.deinit(self.allocator);
        self.type_annotation_records.deinit(self.allocator);
        self.return_type_records.deinit(self.allocator);
        self.type_parameter_records.deinit(self.allocator);
        self.super_type_parameters.deinit(self.allocator);
        self.implements_list.deinit(self.allocator);
        self.predicate_map.deinit(self.allocator);
        self.ts_class_modifiers.deinit(self.allocator);
        self.ts_optional_params.deinit(self.allocator);
        self.async_arrow_flags.deinit(self.allocator);
        self.node_start_overrides.deinit(self.allocator);
        self.replacement_source.deinit(self.allocator);
        self.block_prefix_source.deinit(self.allocator);
        self.consumed_comments.deinit(self.allocator);
    }

    pub fn ensureTypeSideTablesMaterialized(self: *Self) !void {
        if (self.deferred_type_side_tables_materialized) return;

        for (self.type_annotation_records.items) |record| {
            try self.type_annotations.put(self.allocator, record.node, record.value);
        }
        for (self.return_type_records.items) |record| {
            try self.return_types.put(self.allocator, record.node, record.value);
        }
        for (self.type_parameter_records.items) |record| {
            try self.type_parameters.put(self.allocator, record.node, record.value);
        }

        self.type_annotation_records.deinit(self.allocator);
        self.type_annotation_records = .empty;
        self.return_type_records.deinit(self.allocator);
        self.return_type_records = .empty;
        self.type_parameter_records.deinit(self.allocator);
        self.type_parameter_records = .empty;
        self.deferred_type_side_tables_materialized = true;
    }

    pub fn ensureCommentsAttached(self: *Self) void {
        if (self.comments_attached) return;
        self.comments_attached = true;

        const comments = self.comments.items;
        if (comments.len == 0) return;

        const node_count = self.nodes.len;
        if (node_count == 0) return;

        const starts = self.nodes.items(.main_token);
        const end_offsets = self.nodes.items(.end_offset);
        const tags = self.nodes.items(.tag);

        var sorted = self.allocator.alloc(NodePos, node_count) catch return;
        defer self.allocator.free(sorted);

        var count: usize = 0;
        for (0..node_count) |i| {
            const tag = tags[i];
            if (tag == .declarator or tag == .directive_literal or tag == .export_specifier or tag == .export_specifier_type or
                tag == .import_specifier or tag == .import_specifier_type or tag == .import_default or tag == .import_namespace) continue;
            const main_tok = @intFromEnum(starts[i]);
            if (main_tok >= self.tokens.len) continue;
            const start = self.tokens.items(.start)[main_tok];
            const end = end_offsets[i];
            if (end == 0 and i > 0) continue;
            sorted[count] = .{ .start = start, .end = end, .idx = @intCast(i) };
            count += 1;
        }
        const nodes = sorted[0..count];

        std.mem.sort(NodePos, nodes, {}, struct {
            fn lessThan(_: void, a: NodePos, b: NodePos) bool {
                if (a.start != b.start) return a.start < b.start;
                return a.end > b.end;
            }
        }.lessThan);

        for (comments, 0..) |comment, ci| {
            const c_start = comment.start;
            const c_end = comment.end;

            var next_node_idx: ?usize = null;
            var prev_node_idx: ?usize = null;

            var lo: usize = 0;
            var hi: usize = nodes.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (nodes[mid].start < c_end) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo < nodes.len) next_node_idx = lo;

            if (lo > 0) {
                var best_end: u32 = 0;
                var j: usize = lo;
                while (j > 0) {
                    j -= 1;
                    if (nodes[j].end <= c_start and nodes[j].end > best_end) {
                        best_end = nodes[j].end;
                        prev_node_idx = j;
                    }
                }
            }

            var enclosing_idx: ?usize = null;
            var enclosing_span: u64 = std.math.maxInt(u64);
            if (lo > 0) {
                var j: usize = lo;
                while (j > 0) {
                    j -= 1;
                    if (nodes[j].start <= c_start and nodes[j].end >= c_end) {
                        const span = @as(u64, nodes[j].end) - @as(u64, nodes[j].start);
                        if (span < enclosing_span) {
                            enclosing_span = span;
                            enclosing_idx = j;
                        } else if (span == enclosing_span and enclosing_idx != null) {
                            const cur_tag = tags[nodes[enclosing_idx.?].idx];
                            const new_tag = tags[nodes[j].idx];
                            const cur_is_wrapper = cur_tag == .program or cur_tag == .expression_statement;
                            const new_is_wrapper = new_tag == .program or new_tag == .expression_statement;
                            if (cur_is_wrapper and !new_is_wrapper) enclosing_idx = j;
                        }
                    }
                }
            }

            if (prev_node_idx) |pi| {
                const prev_end = nodes[pi].end;
                if (prev_end > 0 and prev_end <= c_start) {
                    const same_line = blk: {
                        var k: u32 = prev_end;
                        while (k < c_start and k < self.source.len) : (k += 1) {
                            if (self.source[k] == '\n' or self.source[k] == '\r') break :blk false;
                        }
                        break :blk true;
                    };
                    if (same_line) {
                        const has_separator = blk2: {
                            var k: u32 = prev_end;
                            while (k < c_start and k < self.source.len) : (k += 1) {
                                if (self.source[k] == ',' or self.source[k] == ';' or self.source[k] == '=') break :blk2 true;
                                if (k + 2 <= self.source.len and
                                    self.source[k] == 'o' and self.source[k + 1] == 'f' and
                                    (k + 2 >= self.source.len or !std.ascii.isAlphanumeric(self.source[k + 2])) and
                                    (k == 0 or !std.ascii.isAlphanumeric(self.source[k - 1])))
                                    break :blk2 true;
                                if (k + 2 <= self.source.len and
                                    self.source[k] == 'i' and self.source[k + 1] == 'n' and
                                    (k + 2 >= self.source.len or !std.ascii.isAlphanumeric(self.source[k + 2])) and
                                    (k == 0 or !std.ascii.isAlphanumeric(self.source[k - 1])))
                                    break :blk2 true;
                            }
                            break :blk2 false;
                        };
                        if (has_separator) {
                            if (next_node_idx) |ni| {
                                const next_same_line = blk3: {
                                    var k: u32 = c_end;
                                    while (k < nodes[ni].start and k < self.source.len) : (k += 1) {
                                        if (self.source[k] == '\n' or self.source[k] == '\r') break :blk3 false;
                                    }
                                    break :blk3 true;
                                };
                                if (next_same_line) {
                                    if (enclosing_idx) |ei| {
                                        if (nodes[ni].start >= nodes[ei].end) {
                                            addCommentToMap(&self.inner_comments, self.allocator, nodes[ei].idx, @intCast(ci));
                                            continue;
                                        }
                                    }
                                    addCommentToMap(&self.leading_comments, self.allocator, nodes[ni].idx, @intCast(ci));
                                    continue;
                                }
                            }
                        }
                        if (enclosing_idx) |ei| {
                            if (nodes[pi].end <= nodes[ei].start or nodes[pi].start >= nodes[ei].end) {
                                addCommentToMap(&self.inner_comments, self.allocator, nodes[ei].idx, @intCast(ci));
                                continue;
                            }
                        }
                        addCommentToMap(&self.trailing_comments, self.allocator, nodes[pi].idx, @intCast(ci));
                        continue;
                    }
                }
            }

            if (next_node_idx) |ni| {
                if (enclosing_idx) |ei| {
                    if (nodes[ni].start >= nodes[ei].end) {
                        addCommentToMap(&self.inner_comments, self.allocator, nodes[ei].idx, @intCast(ci));
                        continue;
                    }
                }
                addCommentToMap(&self.leading_comments, self.allocator, nodes[ni].idx, @intCast(ci));
                continue;
            }

            if (enclosing_idx) |ei| {
                addCommentToMap(&self.inner_comments, self.allocator, nodes[ei].idx, @intCast(ci));
                continue;
            }

            if (prev_node_idx) |pi| {
                addCommentToMap(&self.trailing_comments, self.allocator, nodes[pi].idx, @intCast(ci));
            }
        }
    }

    const NodePos = struct {
        start: u32,
        end: u32,
        idx: u32,
    };

    fn addCommentToMap(
        map: *std.AutoHashMapUnmanaged(u32, CommentRange),
        allocator: std.mem.Allocator,
        node_idx: u32,
        comment_idx: u32,
    ) void {
        if (map.getPtr(node_idx)) |existing| {
            if (comment_idx < existing.start) existing.start = comment_idx;
            if (comment_idx + 1 > existing.end) existing.end = comment_idx + 1;
        } else {
            map.put(allocator, node_idx, .{ .start = comment_idx, .end = comment_idx + 1 }) catch {};
        }
    }

    /// Get the slice of source text for a given token index.
    pub fn tokenSlice(self: *const Ast, token_index: TokenIndex) []const u8 {
        const starts = self.tokens.items(.start);
        const ends = self.tokens.items(.end);
        const idx = @intFromEnum(token_index);
        return self.source[starts[idx]..ends[idx]];
    }

    /// Resolve a byte offset to line and column numbers (0-indexed).
    pub fn resolvePosition(self: *const Ast, byte_offset: u32) struct { line: u32, col: u32 } {
        const offsets = self.line_offsets.items;
        // Binary search for the line containing this offset
        var lo: u32 = 0;
        var hi: u32 = @intCast(offsets.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (offsets[mid] <= byte_offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line = if (lo > 0) lo - 1 else 0;
        const col = byte_offset - offsets[line];
        return .{ .line = line, .col = col };
    }

    /// Append an extra data entry and return its index.
    pub fn addExtra(self: *Ast, value: u32) !ExtraIndex {
        const idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(self.allocator, value);
        return @enumFromInt(idx);
    }

    /// Append a range of NodeIndex values to extra_data. Returns the ExtraIndex of the start.
    pub fn addExtraRange(self: *Ast, items: []const NodeIndex) !struct { start: u32, end: u32 } {
        const start: u32 = @intCast(self.extra_data.items.len);
        for (items) |item| {
            try self.extra_data.append(self.allocator, @intFromEnum(item));
        }
        const end_val: u32 = @intCast(self.extra_data.items.len);
        return .{ .start = start, .end = end_val };
    }

    /// Get a slice of extra_data as NodeIndex values.
    pub fn extraRange(self: *const Ast, start: u32, end_val: u32) []const u32 {
        return self.extra_data.items[start..end_val];
    }
};
