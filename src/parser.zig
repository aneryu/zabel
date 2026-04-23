const std = @import("std");
const Token = @import("token.zig").Token;
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const ExtraIndex = ast_mod.ExtraIndex;
const TokenIndex = ast_mod.TokenIndex;
const SourceType = ast_mod.SourceType;
const Language = ast_mod.Language;
const DenseNodeIndexSideTable = ast_mod.DenseNodeIndexSideTable;
const DenseFlagSideTable = ast_mod.DenseFlagSideTable;
const DeferredNodeIndexSideTableRecord = ast_mod.DeferredNodeIndexSideTableRecord;
const DiagnosticList = @import("diagnostics.zig").DiagnosticList;

pub const ParseOptions = struct {
    strict_mode: bool = false,
    source_type: SourceType = .script,
    language: Language = .javascript,
    enable_throw_expressions: bool = false,
    enable_v8_intrinsic: bool = false,
    flow_all: bool = false, // When true, parse Flow types everywhere (like @flow pragma in all files)
    enable_pipeline_operator: bool = false,
    pipeline_proposal: PipelineProposal = .hack,
    pipeline_topic_token: PipelineTopicToken = .percent,
    enable_decorators: bool = false,
    decorators_legacy: bool = false,
    decorators_before_export: bool = false,
    enable_placeholders: bool = false,
    enable_do_expressions: bool = false,
    enable_throw_expression: bool = false,
    enable_module_blocks: bool = false,
    enable_partial_application: bool = false,
    enable_function_sent: bool = false,
    enable_export_default_from: bool = false,
    enable_bind_operator: bool = false,
    enable_destructuring_private: bool = false,
    enable_record_and_tuple: bool = false,
    enable_discard_binding: bool = false,
    enable_import_source_phase: bool = false,
    enable_deferred_import: bool = false,
    enable_decorator_auto_accessors: bool = false,
    enable_optional_chaining_assign: bool = false,
    enable_flow_comments: bool = false,
    defer_comment_attachment: bool = false,
    create_parenthesized_expressions: bool = false,
    create_import_expressions: bool = true,
    emit_ranges: bool = false,
    allow_new_target_outside_function: bool = true,
    allow_await_outside_function: bool = false,
    annex_b: bool = true,
    start_index: u32 = 0,
    start_line: u32 = 1,
    start_column: u32 = 0,
    source_filename: ?[]const u8 = null,

    pub const PipelineProposal = enum { hack, fsharp, minimal };
    pub const PipelineTopicToken = enum { percent, hash, caret, double_caret, double_at };
};

/// Check if source contains `@flow` pragma in a leading comment (before any code).
/// In Babel, the `@flow` pragma must appear in a comment at the top of the file.
fn sourceHasFlowPragma(source: []const u8) bool {
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        // Skip whitespace and newlines
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0xC) {
            i += 1;
            continue;
        }
        // Check for comment
        if (c == '/' and i + 1 < source.len) {
            if (source[i + 1] == '/') {
                // Line comment: scan to end of line
                const start = i;
                i += 2;
                while (i < source.len and source[i] != '\n' and source[i] != '\r') : (i += 1) {}
                if (std.mem.indexOf(u8, source[start..i], "@flow") != null) return true;
                continue;
            }
            if (source[i + 1] == '*') {
                // Block comment: scan to */
                const start = i;
                i += 2;
                while (i + 1 < source.len) : (i += 1) {
                    if (source[i] == '*' and source[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                }
                if (std.mem.indexOf(u8, source[start..i], "@flow") != null) return true;
                continue;
            }
        }
        // Hashbang line
        if (c == '#' and i + 1 < source.len and source[i + 1] == '!') {
            i += 2;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        // String literal directive (e.g. 'use strict'; or "use strict";)
        // Skip it so we can find @flow comments after directives
        if (c == '\'' or c == '"') {
            const quote = c;
            i += 1;
            while (i < source.len and source[i] != quote) {
                if (source[i] == '\\') i += 1; // skip escape
                i += 1;
            }
            if (i < source.len) i += 1; // skip closing quote
            // Skip optional semicolon after directive
            while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
            if (i < source.len and source[i] == ';') i += 1;
            continue;
        }
        // Any other character means we've reached code — stop looking
        break;
    }
    return false;
}

pub const SoftKeyword = enum(u8) {
    none,
    abstract_,
    accessor,
    any,
    assert,
    asserts,
    bigint_,
    bool_,
    boolean,
    checks,
    declare,
    defer_,
    empty,
    enum_,
    exports,
    global,
    implements,
    infer,
    interface,
    intrinsic,
    is,
    keyof,
    mixins,
    mixed,
    module,
    namespace,
    number,
    opaque_,
    out,
    override,
    private_,
    protected_,
    proto,
    public_,
    readonly,
    require,
    satisfies,
    source,
    string,
    symbol,
    type_,
    unique,
    using_,
    with_,
};

fn classifySoftKeyword(bytes: []const u8) SoftKeyword {
    return switch (bytes.len) {
        2 => if (std.mem.eql(u8, bytes, "is")) .is else .none,
        3 => if (std.mem.eql(u8, bytes, "any")) .any else if (std.mem.eql(u8, bytes, "out")) .out else .none,
        4 => if (std.mem.eql(u8, bytes, "bool")) .bool_ else if (std.mem.eql(u8, bytes, "enum")) .enum_ else if (std.mem.eql(u8, bytes, "type")) .type_ else if (std.mem.eql(u8, bytes, "with")) .with_ else .none,
        5 => if (std.mem.eql(u8, bytes, "defer")) .defer_ else if (std.mem.eql(u8, bytes, "empty")) .empty else if (std.mem.eql(u8, bytes, "infer")) .infer else if (std.mem.eql(u8, bytes, "keyof")) .keyof else if (std.mem.eql(u8, bytes, "mixed")) .mixed else if (std.mem.eql(u8, bytes, "proto")) .proto else if (std.mem.eql(u8, bytes, "using")) .using_ else .none,
        6 => if (std.mem.eql(u8, bytes, "assert")) .assert else if (std.mem.eql(u8, bytes, "bigint")) .bigint_ else if (std.mem.eql(u8, bytes, "checks")) .checks else if (std.mem.eql(u8, bytes, "global")) .global else if (std.mem.eql(u8, bytes, "mixins")) .mixins else if (std.mem.eql(u8, bytes, "module")) .module else if (std.mem.eql(u8, bytes, "opaque")) .opaque_ else if (std.mem.eql(u8, bytes, "public")) .public_ else if (std.mem.eql(u8, bytes, "source")) .source else if (std.mem.eql(u8, bytes, "string")) .string else if (std.mem.eql(u8, bytes, "symbol")) .symbol else if (std.mem.eql(u8, bytes, "unique")) .unique else .none,
        7 => if (std.mem.eql(u8, bytes, "asserts")) .asserts else if (std.mem.eql(u8, bytes, "boolean")) .boolean else if (std.mem.eql(u8, bytes, "declare")) .declare else if (std.mem.eql(u8, bytes, "exports")) .exports else if (std.mem.eql(u8, bytes, "private")) .private_ else if (std.mem.eql(u8, bytes, "require")) .require else .none,
        8 => if (std.mem.eql(u8, bytes, "abstract")) .abstract_ else if (std.mem.eql(u8, bytes, "accessor")) .accessor else if (std.mem.eql(u8, bytes, "override")) .override else if (std.mem.eql(u8, bytes, "readonly")) .readonly else .none,
        9 => if (std.mem.eql(u8, bytes, "interface")) .interface else if (std.mem.eql(u8, bytes, "intrinsic")) .intrinsic else if (std.mem.eql(u8, bytes, "namespace")) .namespace else if (std.mem.eql(u8, bytes, "protected")) .protected_ else if (std.mem.eql(u8, bytes, "satisfies")) .satisfies else .none,
        10 => if (std.mem.eql(u8, bytes, "implements")) .implements else .none,
        else => .none,
    };
}

fn buildSoftKeywordTable(
    allocator: std.mem.Allocator,
    source: []const u8,
    token_tags: []const Token.Tag,
    token_starts: []const u32,
    token_ends: []const u32,
) ![]SoftKeyword {
    const table = try allocator.alloc(SoftKeyword, token_tags.len);
    for (token_tags, 0..) |tag, idx| {
        table[idx] = .none;
        if (tag != .identifier) continue;
        const text = source[token_starts[idx]..token_ends[idx]];
        if (text.len < 2 or text.len > 10) continue;
        switch (text[0]) {
            'a', 'b', 'c', 'd', 'e', 'g', 'i', 'k', 'm', 'n', 'o', 'p', 'r', 's', 't', 'u', 'w' => {
                table[idx] = classifySoftKeyword(text);
            },
            else => {},
        }
    }
    return table;
}

fn buildNewlineBeforeTable(
    allocator: std.mem.Allocator,
    token_starts: []const u32,
    token_ends: []const u32,
    line_offsets: []const u32,
) ![]u8 {
    const table = try allocator.alloc(u8, token_starts.len);
    if (table.len != 0) table[0] = 0;
    var line_idx: usize = 1;
    var idx: usize = 1;
    while (idx < token_starts.len) : (idx += 1) {
        const prev_end = token_ends[idx - 1];
        const curr_start = token_starts[idx];
        while (line_idx < line_offsets.len and line_offsets[line_idx] <= prev_end) : (line_idx += 1) {}
        table[idx] = if (line_idx < line_offsets.len and line_offsets[line_idx] <= curr_start) 1 else 0;
    }
    return table;
}

pub const Parser = struct {
    source: []const u8,
    token_tags: []const Token.Tag,
    token_starts: []const u32,
    token_ends: []const u32,
    newline_before: []const u8,
    soft_keywords: []const SoftKeyword,
    token_index: u32,
    nodes: std.MultiArrayList(Node),
    extra_data: std.ArrayList(u32),
    scratch: std.ArrayList(NodeIndex),
    errors: DiagnosticList,
    allocator: std.mem.Allocator,
    line_offsets: std.ArrayList(u32),

    // Context flags
    no_in: bool = false,
    in_function: bool = false,
    in_async: bool = false,
    in_generator: bool = false,
    in_loop: bool = false,
    in_switch: bool = false,
    strict_mode: bool = false,
    for_await: bool = false,
    in_single_statement: bool = false,
    no_arrow: bool = false, // Suppresses arrow function parsing (set in binary RHS, unary operands)
    in_class_field_init: bool = false, // Inside class field initializer (yield/await are identifiers)
    class_member_is_accessor: bool = false, // Set when parsing `accessor` keyword in class body
    class_member_is_declare: bool = false, // Flow: current class member has `declare` modifier
    flow_in_declare_class: bool = false,
    flow_in_declare_module: bool = false, // Flow: inside declare module { ... } body
    flow_no_anon_function_type: bool = false, // Suppress no-parens `T => U` in return type annotations
    in_constructor_params: bool = false, // TypeScript: parsing constructor parameters (for TSParameterProperty)
    source_type: SourceType = .script,
    language: Language = .javascript,
    enable_throw_expressions: bool = false,
    enable_v8_intrinsic: bool = false,
    pending_async_arrow: bool = false, // Set when parsing potential async arrow params; in_async deferred to body
    ts_in_ambient: bool = false,
    ts_in_type_alias: bool = false, // TypeScript: parsing the RHS of a type alias (for `intrinsic` keyword)
    pending_greater_than: u32 = 0, // For splitting >> and >>> tokens in nested generics
    pending_equal: bool = false, // For splitting >= into > + = in type parameter lists
    split_greater_end: u32 = 0, // End position of the `>` part when splitting >=, >>=, >>>=
    pending_less_than: bool = false, // For splitting << into < + < in type argument contexts
    in_array_destructuring: bool = false, // Disallow type annotations in array destructuring elements
    flow_pragma: bool = false, // Flow: true if source has @flow pragma or flow_all option is set
    ts_in_type_params: bool = false, // TypeScript: inside TS function type parameters — template expr literals get TSLiteralType wrapper
    in_conditional_consequent: bool = false, // TypeScript: inside ternary consequent — `:` is ternary separator, not return type
    ts_in_conditional_extends: bool = false, // TypeScript: inside extends clause of conditional type — infer constraint keeps `?`
    in_possible_pattern: bool = false, // Inside parens/arrays/objects that may become patterns (for discard binding `void =`)
    in_fsharp_pipeline_body: bool = false, // fsharp pipeline: arrow bodies should not consume |>
    flow_no_arrow_at: [8]u32 = .{0} ** 8, // Flow: source positions where arrows should NOT be parsed (for ternary disambiguation)
    flow_no_arrow_at_len: u8 = 0,

    // Flow side tables
    flow_type_annotations: DenseNodeIndexSideTable = .{},
    flow_return_types: DenseNodeIndexSideTable = .{},
    flow_type_parameters: DenseNodeIndexSideTable = .{},
    type_annotation_records: std.ArrayListUnmanaged(DeferredNodeIndexSideTableRecord) = .empty,
    return_type_records: std.ArrayListUnmanaged(DeferredNodeIndexSideTableRecord) = .empty,
    type_parameter_records: std.ArrayListUnmanaged(DeferredNodeIndexSideTableRecord) = .empty,
    flow_super_type_params: DenseNodeIndexSideTable = .{},
    flow_implements: std.AutoHashMapUnmanaged(u32, @import("ast.zig").ExtraRange) = .empty,
    flow_predicates: DenseNodeIndexSideTable = .{},
    flow_variance_map: DenseNodeIndexSideTable = .{},

    // Async arrow flag side table (for arrows where main_token is not kw_async)
    async_arrow_flags: DenseFlagSideTable = .{},

    // TypeScript class modifier side table (keyed by node index, bitmask value)
    ts_class_modifiers: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    // TypeScript optional parameter side table (keyed by node index)
    ts_optional_params: DenseFlagSideTable = .{},
    // Node start position overrides (keyed by node index, value is start offset)
    node_start_overrides: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    deferred_param_type_annotations: std.ArrayListUnmanaged(DeferredTypeAnnotation) = .empty,
    deferred_param_optional_params: std.ArrayListUnmanaged(DeferredOptionalParam) = .empty,
    defer_param_metadata_depth: u32 = 0,

    // Operator string overrides (keyed by node index) for split token operators
    operator_overrides: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    // Decorator side table (keyed by node index, value is extra range of decorator nodes)
    decorators_map: std.AutoHashMapUnmanaged(u32, @import("ast.zig").ExtraRange) = .empty,

    // Parse options for proposals
    opts: ParseOptions = .{},

    // Side table for placeholder expected node strings
    placeholder_contexts: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    // Side table for JSX token type flags (token_index → 0=jsxTagStart, 1=jsxTagEnd, 2=jsxName)
    jsx_token_flags: std.AutoHashMapUnmanaged(u32, u8) = .empty,

    // Side table for placeholder name/body nodes on functions/classes
    // Key: parent (function/class) node index, Value: placeholder NodeIndex for name
    placeholder_name_nodes: DenseNodeIndexSideTable = .{},

    // TypeScript class modifier bitmask constants
    pub const TS_MOD_PUBLIC: u32 = 1;
    pub const TS_MOD_PRIVATE: u32 = 2;
    pub const TS_MOD_PROTECTED: u32 = 4;
    pub const TS_MOD_READONLY: u32 = 8;
    pub const TS_MOD_ABSTRACT: u32 = 16;
    pub const TS_MOD_DECLARE: u32 = 32;
    pub const TS_MOD_OVERRIDE: u32 = 64;
    pub const TS_MOD_STATIC: u32 = 128;
    pub const TS_MOD_IN: u32 = 256;
    pub const TS_MOD_OUT: u32 = 512;

    const DeferredTypeAnnotation = struct {
        node: NodeIndex,
        type_ann: NodeIndex,
    };

    const DeferredOptionalParam = struct {
        node: NodeIndex,
        end_offset: u32,
    };

    pub const DeferredParamMetadataState = struct {
        type_annotations_len: usize,
        optional_params_len: usize,
    };

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
        return parseWithOptions(allocator, source, .{});
    }

    pub fn parseWithOptions(allocator: std.mem.Allocator, source: []const u8, opts: ParseOptions) !ParseResult {
        const Lexer = @import("lexer.zig").Lexer;
        const lex_result = try Lexer.tokenizeWithOptions(allocator, source, .{
            .is_module = opts.source_type == .module,
            .annex_b = opts.annex_b,
            .enable_flow_comments = opts.enable_flow_comments,
        });
        const newline_before = try buildNewlineBeforeTable(
            allocator,
            lex_result.tokens.items(.start),
            lex_result.tokens.items(.end),
            lex_result.line_offsets.items,
        );
        defer allocator.free(newline_before);
        const soft_keywords = try buildSoftKeywordTable(
            allocator,
            source,
            lex_result.tokens.items(.tag),
            lex_result.tokens.items(.start),
            lex_result.tokens.items(.end),
        );
        defer allocator.free(soft_keywords);

        var parser = Parser{
            .source = source,
            .token_tags = lex_result.tokens.items(.tag),
            .token_starts = lex_result.tokens.items(.start),
            .token_ends = lex_result.tokens.items(.end),
            .newline_before = newline_before,
            .soft_keywords = soft_keywords,
            .token_index = 0,
            .nodes = .{},
            .extra_data = .empty,
            .scratch = .empty,
            .errors = DiagnosticList.init(allocator),
            .allocator = allocator,
            .line_offsets = lex_result.line_offsets,
            .strict_mode = opts.strict_mode,
            .in_async = opts.source_type == .module or opts.allow_await_outside_function,
            .source_type = opts.source_type,
            .language = opts.language,
            .enable_throw_expressions = opts.enable_throw_expressions,
            .enable_v8_intrinsic = opts.enable_v8_intrinsic,
            .opts = opts,
        };
        const token_count = parser.token_tags.len;
        try parser.nodes.ensureTotalCapacity(allocator, @max(token_count + 1, 32));
        try parser.extra_data.ensureTotalCapacity(allocator, @max(token_count * 2, 64));
        try parser.scratch.ensureTotalCapacity(allocator, @max(token_count / 2, 32));

        // Flow pragma detection: check for @flow in source comments
        if (opts.language == .flow) {
            parser.flow_pragma = opts.flow_all or sourceHasFlowPragma(source);
        }

        // Report lexer-level errors
        if (lex_result.has_unterminated_comment) {
            parser.errors.addError("unterminated comment", lex_result.unterminated_comment_offset);
        }
        if (lex_result.has_invalid_unicode) {
            parser.errors.addError("invalid unicode code point", lex_result.invalid_unicode_offset);
        }
        if (lex_result.has_html_comment and opts.source_type == .module) {
            parser.errors.addError("HTML comments are not allowed in modules", lex_result.html_comment_offset);
        }
        if (lex_result.has_unterminated_string and !opts.language.isJSX()) {
            parser.errors.addError("Unterminated string constant.", lex_result.unterminated_string_offset);
        }

        // Reserve index 0 for a sentinel/root
        try parser.nodes.append(allocator, .{
            .tag = .program,
            .main_token = @enumFromInt(0),
            .data = .{ .none = {} },
        });

        const root = parser.parseProgram() catch {
            parser.scratch.deinit(allocator);
            parser.deferred_param_type_annotations.deinit(allocator);
            parser.deferred_param_optional_params.deinit(allocator);
            parser.flow_type_annotations.deinit(allocator);
            parser.flow_return_types.deinit(allocator);
            parser.flow_type_parameters.deinit(allocator);
            var ast = Ast{
                .source = source,
                .tokens = lex_result.tokens,
                .nodes = parser.nodes,
                .extra_data = parser.extra_data,
                .line_offsets = parser.line_offsets,
                .comments = lex_result.comments,
                .allocator = allocator,
                .source_type = opts.source_type,
                .hashbang_end = lex_result.hashbang_end,
                .language = opts.language,
                .deferred_type_side_tables_materialized = false,
                .type_annotation_records = parser.type_annotation_records,
                .return_type_records = parser.return_type_records,
                .type_parameter_records = parser.type_parameter_records,
                .super_type_parameters = parser.flow_super_type_params,
                .implements_list = parser.flow_implements,
                .predicate_map = parser.flow_predicates,
                .variance_map = parser.flow_variance_map,
                .ts_class_modifiers = parser.ts_class_modifiers,
                .ts_optional_params = parser.ts_optional_params,
                .async_arrow_flags = parser.async_arrow_flags,
                .node_start_overrides = parser.node_start_overrides,
                .operator_overrides = parser.operator_overrides,
                .decorators_map = parser.decorators_map,
                .jsx_token_flags = parser.jsx_token_flags,
                .create_parenthesized_expressions = opts.create_parenthesized_expressions,
            };
            if (!opts.defer_comment_attachment) ast.ensureCommentsAttached();
            return ParseResult{
                .ast = ast,
                .errors = parser.errors,
            };
        };
        _ = root;

        parser.scratch.deinit(allocator);
        parser.deferred_param_type_annotations.deinit(allocator);
        parser.deferred_param_optional_params.deinit(allocator);
        parser.flow_type_annotations.deinit(allocator);
        parser.flow_return_types.deinit(allocator);
        parser.flow_type_parameters.deinit(allocator);

        var ast = Ast{
            .source = source,
            .tokens = lex_result.tokens,
            .nodes = parser.nodes,
            .extra_data = parser.extra_data,
            .line_offsets = parser.line_offsets,
            .comments = lex_result.comments,
            .allocator = allocator,
            .source_type = opts.source_type,
            .hashbang_end = lex_result.hashbang_end,
            .language = opts.language,
            .deferred_type_side_tables_materialized = false,
            .type_annotation_records = parser.type_annotation_records,
            .return_type_records = parser.return_type_records,
            .type_parameter_records = parser.type_parameter_records,
            .super_type_parameters = parser.flow_super_type_params,
            .implements_list = parser.flow_implements,
            .predicate_map = parser.flow_predicates,
            .variance_map = parser.flow_variance_map,
            .ts_class_modifiers = parser.ts_class_modifiers,
            .ts_optional_params = parser.ts_optional_params,
            .async_arrow_flags = parser.async_arrow_flags,
            .node_start_overrides = parser.node_start_overrides,
            .operator_overrides = parser.operator_overrides,
            .decorators_map = parser.decorators_map,
            .placeholder_contexts = parser.placeholder_contexts,
            .placeholder_name_nodes = parser.placeholder_name_nodes,
            .jsx_token_flags = parser.jsx_token_flags,
            .create_parenthesized_expressions = opts.create_parenthesized_expressions,
        };
        if (!opts.defer_comment_attachment) ast.ensureCommentsAttached();
        return ParseResult{
            .ast = ast,
            .errors = parser.errors,
        };
    }

    // === Token navigation ===

    pub fn currentTag(self: *const Parser) Token.Tag {
        if (self.token_index >= self.token_tags.len) return .eof;
        return self.token_tags[self.token_index];
    }

    pub fn currentStart(self: *const Parser) u32 {
        if (self.token_index >= self.token_starts.len) return @intCast(self.source.len);
        return self.token_starts[self.token_index];
    }

    pub fn advance(self: *Parser) TokenIndex {
        const idx = if (self.token_index < self.token_tags.len)
            self.token_index
        else
            @as(u32, @intCast(self.token_tags.len - 1));
        if (self.token_index < self.token_tags.len) {
            self.token_index += 1;
        }
        return @enumFromInt(idx);
    }

    pub fn expect(self: *Parser, tag: Token.Tag) !TokenIndex {
        if (self.currentTag() == tag) {
            return self.advance();
        }
        self.errors.addError("unexpected token", self.currentStart());
        return error.ParseError;
    }

    pub fn eat(self: *Parser, tag: Token.Tag) ?TokenIndex {
        if (self.currentTag() == tag) {
            return self.advance();
        }
        return null;
    }

    pub fn lookAhead(self: *const Parser, offset: u32) Token.Tag {
        const idx = self.token_index + offset;
        if (idx >= self.token_tags.len) return .eof;
        return self.token_tags[idx];
    }

    fn newlineBeforeToken(self: *const Parser, idx: u32) bool {
        return idx < self.newline_before.len and self.newline_before[idx] != 0;
    }

    pub fn softKeywordAt(self: *const Parser, idx: u32) SoftKeyword {
        if (idx >= self.soft_keywords.len) return .none;
        return self.soft_keywords[idx];
    }

    pub fn currentSoftKeyword(self: *const Parser) SoftKeyword {
        return self.softKeywordAt(self.token_index);
    }

    pub fn identifierEquals(self: *const Parser, idx: u32, name: []const u8) bool {
        if (idx >= self.token_tags.len or self.token_tags[idx] != .identifier) return false;
        const expected = classifySoftKeyword(name);
        if (expected != .none) {
            const cached = self.softKeywordAt(idx);
            if (cached != .none) return cached == expected;
        }
        return std.mem.eql(u8, self.tokenText(idx), name);
    }

    /// Check if there's a newline between the token at `token_index + offset`
    /// and the following token.
    pub fn hasNewlineAfterOffset(self: *const Parser, offset: u32) bool {
        const idx = self.token_index + offset;
        return self.newlineBeforeToken(idx + 1);
    }

    /// Check if there's a newline between the current token and the next token.
    pub fn hasNewlineAfterCurrent(self: *const Parser) bool {
        return self.hasNewlineAfterOffset(0);
    }

    /// Get the source text of a token at the given index.
    pub fn tokenText(self: *const Parser, idx: u32) []const u8 {
        if (idx >= self.token_starts.len) return "";
        return self.source[self.token_starts[idx]..self.token_ends[idx]];
    }

    /// Check if the current identifier token is an escaped keyword.
    fn resolvedEscapedKeyword(self: *Parser) ?Token.Tag {
        if (self.token_index >= self.token_tags.len) return null;
        if (self.token_tags[self.token_index] != .identifier) return null;
        const text = self.tokenText(self.token_index);
        if (std.mem.indexOf(u8, text, "\\u") == null) return null;
        var buf: [32]u8 = undefined;
        const Lex = @import("lexer.zig").Lexer;
        const resolved = Lex.resolveEscapes(text, &buf);
        if (resolved.len == 0) return null;
        return Lex.identifyKeyword(resolved);
    }

    fn escapedKeywordUsesIdentifierSemantics(tag: Token.Tag) bool {
        return switch (tag) {
            .kw_let,
            .kw_async,
            .kw_await,
            .kw_yield,
            .kw_of,
            .kw_static,
            .kw_get,
            .kw_set,
            .kw_from,
            .kw_as,
            => true,
            else => false,
        };
    }

    /// Check if the current position starts a `using` declaration.
    /// `using` is a contextual keyword: `using <identifier> =`
    /// Requires: current token is identifier "using", no newline before next,
    /// next token is identifier (but not "of").
    fn isUsingDeclaration(self: *const Parser) bool {
        return self.isUsingDeclarationImpl(false);
    }

    /// Like isUsingDeclaration but also accepts `{` after `using` for destructuring
    /// (error recovery). Only used in statement context, NOT in for-loop init.
    fn isUsingDeclarationWithDestructuring(self: *const Parser) bool {
        return self.isUsingDeclarationImpl(true);
    }

    fn isUsingDeclarationImpl(self: *const Parser, accept_brace: bool) bool {
        if (self.currentTag() != .identifier) return false;
        if (self.currentSoftKeyword() != .using_) return false;
        if (self.hasNewlineAfterCurrent()) return false;
        const next = self.lookAhead(1);
        // Binding name can be an identifier or a contextual keyword like `of`, `get`, `set`, etc.
        if (next == .identifier or next == .kw_of or next == .kw_get or next == .kw_set or
            next == .kw_let or next == .kw_async or next == .kw_await) return true;
        // Discard binding: `using void = ...`
        if (self.opts.enable_discard_binding and next == .kw_void) return true;
        // Accept `{` for destructuring only in statement context (not for-loop).
        if (accept_brace and next == .l_brace) return true;
        // Placeholder: `using %%X%% = ...`
        if (self.opts.enable_placeholders and next == .percent and self.lookAhead(2) == .percent) return true;
        return false;
    }

    /// In for-loop context, `using of <expr>` means `for (using of <expr>)` — a for-of
    /// with `using` as the iteration variable. Returns true when we should NOT parse as using declaration.
    fn isForUsingOfPattern(self: *const Parser) bool {
        if (self.lookAhead(1) != .kw_of) return false;
        // `using of = ...` is a using declaration even in for context
        if (self.lookAhead(2) == .equal) return false;
        // `using of;` is a using declaration (no initializer) in traditional for context
        if (self.lookAhead(2) == .semicolon) return false;
        // `using of: Type = ...` is a using declaration with type annotation (TS)
        if (self.lookAhead(2) == .colon) return false;
        return true;
    }

    /// Check if current position starts an `await using` declaration.
    /// Requires: current is `await`, next is identifier "using" (no newline),
    /// and the token after that is an identifier.
    fn isAwaitUsingDeclaration(self: *const Parser) bool {
        if (self.currentTag() != .kw_await) return false;
        if (self.hasNewlineAfterCurrent()) return false;
        if (self.lookAhead(1) != .identifier) return false;
        if (self.softKeywordAt(self.token_index + 1) != .using_) return false;
        if (self.newlineBeforeToken(self.token_index + 2)) return false;
        const after_using = self.lookAhead(2);
        if (after_using != .identifier and after_using != .kw_of and after_using != .kw_get and
            after_using != .kw_set and after_using != .kw_let and after_using != .kw_async and
            after_using != .kw_await and !(self.opts.enable_discard_binding and after_using == .kw_void)) return false;
        return true;
    }

    fn shouldParseForLetDeclaration(self: *const Parser) bool {
        if (self.currentTag() != .kw_let) return false;
        const next = self.lookAhead(1);
        switch (next) {
            .dot, .l_paren, .template_no_sub, .template_head, .semicolon, .kw_in => return false,
            .kw_of => {
                const after_of = self.lookAhead(2);
                return after_of == .equal or
                    after_of == .colon or
                    after_of == .comma or
                    after_of == .semicolon or
                    after_of == .kw_in or
                    after_of == .kw_of;
            },
            else => return true,
        }
    }

    /// Parse Flow type parameters, super type params, and implements on a class.
    fn parseFlowClassExtras(self: *Parser) Error!void {
        if (!self.isFlow() or self.currentTag() != .less_than) return;
        const flow_mod = @import("parser_flow.zig");
        const type_params = try flow_mod.parseFlowTypeParameterDeclaration(self);
        try self.putTypeParameters(@enumFromInt(self.nodes.len), type_params);
    }

    fn parseFlowSuperTypeParams(self: *Parser) Error!void {
        if (!self.isFlow() or self.currentTag() != .less_than) return;
        const flow_mod = @import("parser_flow.zig");
        const super_tp = try flow_mod.parseFlowTypeParameterInstantiation(self);
        try self.flow_super_type_params.put(self.allocator, @intCast(self.nodes.len), super_tp);
    }

    fn parseFlowImplementsClause(self: *Parser) Error!void {
        if (!self.isFlow() or self.currentTag() != .identifier or
            self.currentSoftKeyword() != .implements) return;
        const flow_mod = @import("parser_flow.zig");
        _ = self.advance(); // implements
        const scratch_start2 = self.scratch.items.len;
        while (true) {
            const impl = try flow_mod.parseFlowInterfaceExtends(self);
            try self.scratch.append(self.allocator, impl);
            if (self.currentTag() != .comma) break;
            _ = self.advance();
        }
        const impl_items = self.scratch.items[scratch_start2..];
        const impl_range = try self.addExtraRange(impl_items);
        self.scratch.shrinkRetainingCapacity(scratch_start2);
        try self.flow_implements.put(self.allocator, @intCast(self.nodes.len), .{ .start = impl_range.start, .end = impl_range.end });
    }

    fn rollbackSpeculativeState(
        self: *Parser,
        saved_token_index: u32,
        saved_nodes_len: usize,
        saved_extra_len: usize,
        saved_scratch_len: usize,
        saved_errors_len: usize,
    ) void {
        self.token_index = saved_token_index;
        self.nodes.shrinkRetainingCapacity(saved_nodes_len);
        self.extra_data.shrinkRetainingCapacity(saved_extra_len);
        self.scratch.shrinkRetainingCapacity(saved_scratch_len);
        self.errors.items.shrinkRetainingCapacity(saved_errors_len);
    }

    fn tryParseTypeArgumentsForCallOrInstantiation(self: *Parser, allow_instantiation: bool) Error!?NodeIndex {
        if ((self.currentTag() != .less_than and self.currentTag() != .less_less) or self.hasNewlineBefore()) return null;

        const saved_token_index = self.token_index;
        const saved_nodes_len = self.nodes.len;
        const saved_extra_len = self.extra_data.items.len;
        const saved_scratch_len = self.scratch.items.len;
        const saved_errors_len = self.errors.items.items.len;
        const saved_pending_less_than = self.pending_less_than;

        if (self.isTypeScript()) {
            const parser_ts = @import("parser_ts.zig");
            const type_args = parser_ts.parseTsTypeParameterInstantiation(self) catch |err| switch (err) {
                error.ParseError => {
                    self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
                    self.pending_less_than = saved_pending_less_than;
                    return null;
                },
                else => return err,
            };
            // Accept: call `(`, tagged template, or (if allowed) instantiation expression follow tokens
            if (self.currentTag() == .l_paren or
                self.currentTag() == .template_no_sub or
                self.currentTag() == .template_head or
                (allow_instantiation and self.isInstantiationExpressionFollowToken()))
            {
                return type_args;
            }
            self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
            self.pending_less_than = saved_pending_less_than;
            return null;
        }

        if (self.isFlow() and self.flow_pragma) {
            const flow_mod = @import("parser_flow.zig");
            const type_args = flow_mod.parseFlowTypeParameterInstantiation(self) catch |err| switch (err) {
                error.ParseError => {
                    self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
                    self.pending_less_than = saved_pending_less_than;
                    return null;
                },
                else => return err,
            };
            if (self.currentTag() != .l_paren) {
                self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
                self.pending_less_than = saved_pending_less_than;
                return null;
            }
            return type_args;
        }

        return null;
    }

    /// Check if the current token is a valid follow token for a TSInstantiationExpression.
    /// Check if the given source position is in the flow_no_arrow_at list.
    fn isFlowNoArrowAt(self: *const Parser, pos: u32) bool {
        for (self.flow_no_arrow_at[0..self.flow_no_arrow_at_len]) |p| {
            if (p == pos) return true;
        }
        return false;
    }

    /// This determines whether `f<T>` should be parsed as an instantiation expression
    /// (not a comparison) based on what comes after the closing `>`.
    fn isInstantiationExpressionFollowToken(self: *Parser) bool {
        const tag = self.currentTag();
        return switch (tag) {
            // Punctuation that can't start an expression
            .semicolon, .comma, .r_paren, .r_bracket, .r_brace, .colon, .question => true,
            // End of file
            .eof => true,
            // Equality/comparison operators
            .equal_equal, .equal_equal_equal, .bang_equal, .bang_equal_equal => true,
            // Logical operators
            .ampersand_ampersand, .pipe_pipe, .question_question => true,
            // Assignment operators
            .equal,
            .plus_equal,
            .minus_equal,
            .asterisk_equal,
            .slash_equal,
            .percent_equal,
            .less_less_equal,
            .greater_greater_equal,
            .greater_greater_greater_equal,
            .ampersand_equal,
            .pipe_equal,
            .caret_equal,
            .power_equal,
            .ampersand_ampersand_equal,
            .pipe_pipe_equal,
            .question_question_equal,
            => true,
            // Dot for property access: `a<b>.c`
            .dot => true,
            // Optional chain: `a<b>?.c`
            .optional_chain => true,
            // `as` keyword (TypeScript): `a<b> as c`
            .kw_as => true,
            else => blk: {
                // `satisfies` identifier (TypeScript): `a<b> satisfies c`
                if (tag == .identifier and self.isTypeScript() and self.currentSoftKeyword() == .satisfies) break :blk true;
                break :blk self.hasNewlineBefore(); // newline = ASI
            },
        };
    }

    fn tryParseTypeArgumentsForNew(self: *Parser) Error!?NodeIndex {
        if ((self.currentTag() != .less_than and self.currentTag() != .less_less) or self.hasNewlineBefore()) return null;
        // In Flow mode, don't speculatively parse `<<` as type args on `new` —
        // `new f<<T>...>()` should be parsed as `(new f)<<T>...>()` (call with type args).
        if (self.isFlow() and self.currentTag() == .less_less) return null;

        const saved_token_index = self.token_index;
        const saved_nodes_len = self.nodes.len;
        const saved_extra_len = self.extra_data.items.len;
        const saved_scratch_len = self.scratch.items.len;
        const saved_errors_len = self.errors.items.items.len;
        const saved_pending_less_than = self.pending_less_than;

        const type_args = if (self.isTypeScript()) blk: {
            const parser_ts = @import("parser_ts.zig");
            break :blk parser_ts.parseTsTypeParameterInstantiation(self) catch |err| switch (err) {
                error.ParseError => {
                    self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
                    self.pending_less_than = saved_pending_less_than;
                    return null;
                },
                else => return err,
            };
        } else if (self.isFlow() and self.flow_pragma) blk: {
            const flow_mod = @import("parser_flow.zig");
            break :blk flow_mod.parseFlowTypeParameterInstantiation(self) catch |err| switch (err) {
                error.ParseError => {
                    self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
                    self.pending_less_than = saved_pending_less_than;
                    return null;
                },
                else => return err,
            };
        } else return null;

        // For `new`, accept type args before: call parens, templates, statement boundaries,
        // ASI, and reserved keywords that start new statements (`if`, `class`, etc.).
        if (self.currentTag() == .l_paren or self.hasNewlineBefore() or
            self.isInstantiationExpressionFollowToken() or
            self.currentTag() == .template_no_sub or self.currentTag() == .template_head or
            self.currentTag().isReservedKeyword())
        {
            return type_args;
        }

        self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
        self.pending_less_than = saved_pending_less_than;
        return null;
    }

    /// Check if the current token's source text contains a unicode escape sequence.
    /// Used to detect e.g. `\u0061sync` which resolves to `async` but should not
    /// be treated as the `async` keyword.
    fn currentTokenHasEscape(self: *const Parser) bool {
        if (self.token_index >= self.token_starts.len) return false;
        const start = self.token_starts[self.token_index];
        const end = self.token_ends[self.token_index];
        var i = start;
        while (i < end) : (i += 1) {
            if (self.source[i] == '\\') return true;
        }
        return false;
    }

    pub fn hasNewlineBefore(self: *const Parser) bool {
        return self.newlineBeforeToken(self.token_index);
    }

    /// Check whether there's a newline between two token indices.
    fn hasNewlineBetween(self: *const Parser, tok_a: usize, tok_b: usize) bool {
        if (tok_a >= self.token_starts.len or tok_b >= self.token_starts.len or tok_a >= tok_b) return false;
        var idx = tok_a + 1;
        while (idx <= tok_b) : (idx += 1) {
            if (self.newlineBeforeToken(@intCast(idx))) return true;
        }
        return false;
    }

    /// Check whether `await` (current token) is followed by a token that suggests
    /// it is being used as an AwaitExpression rather than an identifier.  Babel
    /// always parses `await <expr>` as AwaitExpression (adding an error when not
    /// in async context), so we replicate that for error-recovery compatibility.
    /// A newline after `await` means it's an identifier (ASI applies).
    /// Only checks tokens that UNAMBIGUOUSLY start an argument expression.
    /// Excludes ( [ / because in non-async context those make await look like
    /// an identifier being called/subscripted/divided.
    fn looksLikeAwaitExpr(self: *const Parser) bool {
        if (self.hasNewlineAfterCurrent()) return false;
        const next = self.lookAhead(1);
        return switch (next) {
            // Expression-start tokens that unambiguously indicate `await <expr>`
            .identifier,
            .numeric,
            .string,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_this,
            .kw_new,
            .kw_typeof,
            .kw_void,
            .kw_delete,
            .kw_function,
            .kw_class,
            .kw_import,
            .kw_super,
            .kw_yield,
            .kw_await,
            .kw_async,
            .kw_throw,
            .l_brace,
            .template_no_sub,
            .template_head,
            .bang,
            .tilde,
            => true,
            else => false,
        };
    }

    // === Language helpers ===

    pub fn isTypeScript(self: *const Parser) bool {
        return self.language.isTypeScript();
    }

    pub fn isJSX(self: *const Parser) bool {
        return self.language.isJSX();
    }

    pub fn isFlow(self: *const Parser) bool {
        return self.language.isFlow();
    }

    /// Check if current token is `const` followed by `enum` in TypeScript mode.
    pub fn isTsConstEnum(self: *const Parser) bool {
        return self.isTypeScript() and self.currentTag() == .kw_const and
            self.lookAhead(1) == .identifier and
            self.softKeywordAt(self.token_index + 1) == .enum_;
    }

    fn recordTypeAnnotation(self: *Parser, node: NodeIndex, value: NodeIndex) !void {
        try self.type_annotation_records.append(self.allocator, .{
            .node = @intFromEnum(node),
            .value = value,
        });
    }

    fn recordReturnType(self: *Parser, node: NodeIndex, value: NodeIndex) !void {
        try self.return_type_records.append(self.allocator, .{
            .node = @intFromEnum(node),
            .value = value,
        });
    }

    fn recordTypeParameters(self: *Parser, node: NodeIndex, value: NodeIndex) !void {
        try self.type_parameter_records.append(self.allocator, .{
            .node = @intFromEnum(node),
            .value = value,
        });
    }

    fn hasRecordedNodeIndexValue(records: []const DeferredNodeIndexSideTableRecord, node: NodeIndex) bool {
        var i = records.len;
        while (i > 0) {
            i -= 1;
            const record = records[i];
            if (record.node == @intFromEnum(node)) return record.value != .none;
        }
        return false;
    }

    pub fn putTypeAnnotation(self: *Parser, node: NodeIndex, type_ann: NodeIndex) !void {
        try self.flow_type_annotations.put(self.allocator, @intFromEnum(node), type_ann);
        try self.recordTypeAnnotation(node, type_ann);
    }

    pub fn removeTypeAnnotation(self: *Parser, node: NodeIndex) !bool {
        const removed = self.flow_type_annotations.remove(@intFromEnum(node));
        if (removed) try self.recordTypeAnnotation(node, .none);
        return removed;
    }

    pub fn putReturnType(self: *Parser, node: NodeIndex, type_ann: NodeIndex) !void {
        try self.recordReturnType(node, type_ann);
    }

    pub fn removeReturnType(self: *Parser, node: NodeIndex) !bool {
        const removed = hasRecordedNodeIndexValue(self.return_type_records.items, node);
        if (removed) try self.recordReturnType(node, .none);
        return removed;
    }

    pub fn putTypeParameters(self: *Parser, node: NodeIndex, type_params: NodeIndex) !void {
        try self.recordTypeParameters(node, type_params);
    }

    pub fn removeTypeParameters(self: *Parser, node: NodeIndex) !bool {
        const removed = hasRecordedNodeIndexValue(self.type_parameter_records.items, node);
        if (removed) try self.recordTypeParameters(node, .none);
        return removed;
    }

    /// Store a type annotation for a node and extend the node's end position.
    pub fn storeTypeAnnotation(self: *Parser, node: NodeIndex, type_ann: NodeIndex) !void {
        try self.putTypeAnnotation(node, type_ann);
        const ann_end = self.nodes.items(.end_offset)[@intFromEnum(type_ann)];
        self.nodes.items(.end_offset)[@intFromEnum(node)] = ann_end;
    }

    pub fn storeParamTypeAnnotation(self: *Parser, node: NodeIndex, type_ann: NodeIndex) !void {
        if (self.defer_param_metadata_depth != 0) {
            try self.deferred_param_type_annotations.append(self.allocator, .{
                .node = node,
                .type_ann = type_ann,
            });
            return;
        }
        try self.storeTypeAnnotation(node, type_ann);
    }

    fn markOptionalParam(self: *Parser, node: NodeIndex, q_tok: TokenIndex) !void {
        const q_end = self.token_ends[@intFromEnum(q_tok)];
        if (self.defer_param_metadata_depth != 0) {
            try self.deferred_param_optional_params.append(self.allocator, .{
                .node = node,
                .end_offset = q_end,
            });
            return;
        }
        try self.ts_optional_params.put(self.allocator, @intFromEnum(node), {});
        if (self.nodes.items(.end_offset)[@intFromEnum(node)] < q_end) {
            self.nodes.items(.end_offset)[@intFromEnum(node)] = q_end;
        }
    }

    pub fn beginDeferredParamMetadata(self: *Parser) DeferredParamMetadataState {
        self.defer_param_metadata_depth += 1;
        return .{
            .type_annotations_len = self.deferred_param_type_annotations.items.len,
            .optional_params_len = self.deferred_param_optional_params.items.len,
        };
    }

    pub fn discardDeferredParamMetadata(self: *Parser, state: DeferredParamMetadataState) void {
        std.debug.assert(self.defer_param_metadata_depth > 0);
        self.deferred_param_type_annotations.shrinkRetainingCapacity(state.type_annotations_len);
        self.deferred_param_optional_params.shrinkRetainingCapacity(state.optional_params_len);
        self.defer_param_metadata_depth -= 1;
    }

    pub fn commitDeferredParamMetadata(self: *Parser, state: DeferredParamMetadataState) !void {
        std.debug.assert(self.defer_param_metadata_depth > 0);

        if (self.defer_param_metadata_depth == 1) {
            for (self.deferred_param_optional_params.items[state.optional_params_len..]) |entry| {
                try self.ts_optional_params.put(self.allocator, @intFromEnum(entry.node), {});
                if (self.nodes.items(.end_offset)[@intFromEnum(entry.node)] < entry.end_offset) {
                    self.nodes.items(.end_offset)[@intFromEnum(entry.node)] = entry.end_offset;
                }
            }

            for (self.deferred_param_type_annotations.items[state.type_annotations_len..]) |entry| {
                try self.storeTypeAnnotation(entry.node, entry.type_ann);
            }
        }

        self.discardDeferredParamMetadata(state);
    }

    fn moveDeferredParamTypeAnnotation(self: *Parser, from: NodeIndex, to: NodeIndex) void {
        var i = self.deferred_param_type_annotations.items.len;
        while (i > 0) {
            i -= 1;
            if (self.deferred_param_type_annotations.items[i].node == from) {
                self.deferred_param_type_annotations.items[i].node = to;
                return;
            }
        }
    }

    fn moveDeferredOptionalParam(self: *Parser, from: NodeIndex, to: NodeIndex) void {
        var i = self.deferred_param_optional_params.items.len;
        while (i > 0) {
            i -= 1;
            if (self.deferred_param_optional_params.items[i].node == from) {
                self.deferred_param_optional_params.items[i].node = to;
                return;
            }
        }
    }

    pub fn moveParamTypeAnnotationToRest(self: *Parser, elem: NodeIndex, rest_node: NodeIndex) !void {
        if (self.defer_param_metadata_depth != 0) {
            self.moveDeferredParamTypeAnnotation(elem, rest_node);
            return;
        }
        if (self.flow_type_annotations.get(@intFromEnum(elem))) |ann| {
            const elem_main = self.nodes.items(.main_token)[@intFromEnum(elem)];
            self.nodes.items(.end_offset)[@intFromEnum(elem)] = self.token_ends[@intFromEnum(elem_main)];
            _ = try self.removeTypeAnnotation(elem);
            try self.putTypeAnnotation(rest_node, ann);
        }
    }

    pub fn moveOptionalParamToRest(self: *Parser, elem: NodeIndex, rest_node: NodeIndex) !void {
        if (self.defer_param_metadata_depth != 0) {
            self.moveDeferredOptionalParam(elem, rest_node);
            return;
        }
        if (self.ts_optional_params.get(@intFromEnum(elem))) |_| {
            _ = self.ts_optional_params.remove(@intFromEnum(elem));
            try self.ts_optional_params.put(self.allocator, @intFromEnum(rest_node), {});
            const elem_main = self.nodes.items(.main_token)[@intFromEnum(elem)];
            self.nodes.items(.end_offset)[@intFromEnum(elem)] = self.token_ends[@intFromEnum(elem_main)];
        }
    }

    const ThisParamInfo = struct {
        index: usize,
        param: NodeIndex,
        binding: NodeIndex,
        token: TokenIndex,
        has_default: bool,
    };

    fn tokenRepresentsThis(self: *const Parser, tok: TokenIndex) bool {
        return std.mem.eql(u8, self.tokenText(@intFromEnum(tok)), "this");
    }

    fn tokenRepresentsConstructor(self: *const Parser, tok: TokenIndex) bool {
        const text = self.tokenText(@intFromEnum(tok));
        return switch (self.token_tags[@intFromEnum(tok)]) {
            .identifier => std.mem.eql(u8, text, "constructor"),
            .string => text.len >= 2 and std.mem.eql(u8, text[1 .. text.len - 1], "constructor"),
            else => false,
        };
    }

    fn getThisParamInfo(self: *const Parser, param: NodeIndex, index: usize) ?ThisParamInfo {
        switch (self.nodes.items(.tag)[@intFromEnum(param)]) {
            .identifier => {
                const tok = self.nodes.items(.main_token)[@intFromEnum(param)];
                if (!self.tokenRepresentsThis(tok)) return null;
                return .{
                    .index = index,
                    .param = param,
                    .binding = param,
                    .token = tok,
                    .has_default = false,
                };
            },
            .assignment_pattern => {
                const lhs = self.nodes.items(.data)[@intFromEnum(param)].binary.lhs;
                if (self.nodes.items(.tag)[@intFromEnum(lhs)] != .identifier) return null;
                const tok = self.nodes.items(.main_token)[@intFromEnum(lhs)];
                if (!self.tokenRepresentsThis(tok)) return null;
                return .{
                    .index = index,
                    .param = param,
                    .binding = lhs,
                    .token = tok,
                    .has_default = true,
                };
            },
            else => return null,
        }
    }

    fn findThisParam(self: *const Parser, params: []const NodeIndex) ?ThisParamInfo {
        for (params, 0..) |param, i| {
            if (self.getThisParamInfo(param, i)) |info| return info;
        }
        return null;
    }

    fn parseThisParameter(self: *Parser, scratch_start: usize) Error!NodeIndex {
        const flow_mod = @import("parser_flow.zig");
        const this_tok = self.advance();
        const this_start = self.token_starts[@intFromEnum(this_tok)];
        const this_param = try self.addNode(.{ .tag = .identifier, .main_token = this_tok, .data = .{ .none = {} } });

        var is_optional = false;
        if (self.currentTag() == .question) {
            const q_tok = self.advance();
            is_optional = true;
            try self.markOptionalParam(this_param, q_tok);
        }

        var has_type_annotation = false;
        if (self.currentTag() == .colon) {
            has_type_annotation = true;
            if (self.isFlow()) {
                const type_ann = try flow_mod.parseFlowTypeAnnotation(self);
                try self.storeParamTypeAnnotation(this_param, type_ann);
            } else if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                const type_ann = try parser_ts.parseTsTypeAnnotation(self);
                try self.storeParamTypeAnnotation(this_param, type_ann);
            }
        }

        var param = this_param;
        var has_default = false;
        if (self.currentTag() == .equal) {
            has_default = true;
            const eq_token = self.advance();
            const def = try self.parseAssignmentExpression();
            param = try self.addNode(.{
                .tag = .assignment_pattern,
                .main_token = eq_token,
                .data = .{ .binary = .{ .lhs = this_param, .rhs = def } },
            });
        }

        if (!has_type_annotation) {
            self.errors.addError("A type annotation is required for the `this` parameter.", this_start);
        }
        if (self.scratch.items.len != scratch_start) {
            self.errors.addError("The `this` parameter must be the first function parameter.", this_start);
        }
        if (is_optional) {
            self.errors.addError("The `this` parameter cannot be optional.", this_start);
        }
        if (has_default) {
            self.errors.addError("The `this` parameter may not have a default value.", this_start);
        }

        return param;
    }

    // === Parser state checkpoint for backtracking ===

    pub const ParserState = struct {
        token_index: u32,
        nodes_len: u32,
        extra_len: u32,
        scratch_len: u32,
        errors_len: u32,
        type_annotation_records_len: u32,
        return_type_records_len: u32,
        type_parameter_records_len: u32,
        deferred_param_type_annotations_len: u32,
        deferred_param_optional_params_len: u32,
        defer_param_metadata_depth: u32,
        pending_greater_than: u32,
        pending_equal: bool,
        split_greater_end: u32,
    };

    pub fn saveState(self: *Parser) ParserState {
        return .{
            .token_index = self.token_index,
            .nodes_len = @intCast(self.nodes.len),
            .extra_len = @intCast(self.extra_data.items.len),
            .scratch_len = @intCast(self.scratch.items.len),
            .errors_len = @intCast(self.errors.items.items.len),
            .type_annotation_records_len = @intCast(self.type_annotation_records.items.len),
            .return_type_records_len = @intCast(self.return_type_records.items.len),
            .type_parameter_records_len = @intCast(self.type_parameter_records.items.len),
            .deferred_param_type_annotations_len = @intCast(self.deferred_param_type_annotations.items.len),
            .deferred_param_optional_params_len = @intCast(self.deferred_param_optional_params.items.len),
            .defer_param_metadata_depth = self.defer_param_metadata_depth,
            .pending_greater_than = self.pending_greater_than,
            .pending_equal = self.pending_equal,
            .split_greater_end = self.split_greater_end,
        };
    }

    pub fn restoreState(self: *Parser, state: ParserState) void {
        self.token_index = state.token_index;
        const old_len = state.nodes_len;
        const cur_len = self.nodes.len;
        if (cur_len > old_len) {
            self.flow_type_annotations.clearRange(old_len, @intCast(cur_len));
            self.flow_return_types.clearRange(old_len, @intCast(cur_len));
            self.flow_type_parameters.clearRange(old_len, @intCast(cur_len));
            self.flow_predicates.clearRange(old_len, @intCast(cur_len));
            self.ts_optional_params.clearRange(old_len, @intCast(cur_len));
            self.async_arrow_flags.clearRange(old_len, @intCast(cur_len));

            var i: u32 = old_len;
            while (i < cur_len) : (i += 1) {
                _ = self.flow_implements.remove(i);
            }
        }
        self.nodes.shrinkRetainingCapacity(state.nodes_len);
        self.extra_data.shrinkRetainingCapacity(state.extra_len);
        self.scratch.shrinkRetainingCapacity(state.scratch_len);
        self.errors.items.shrinkRetainingCapacity(state.errors_len);
        self.type_annotation_records.shrinkRetainingCapacity(state.type_annotation_records_len);
        self.return_type_records.shrinkRetainingCapacity(state.return_type_records_len);
        self.type_parameter_records.shrinkRetainingCapacity(state.type_parameter_records_len);
        self.deferred_param_type_annotations.shrinkRetainingCapacity(state.deferred_param_type_annotations_len);
        self.deferred_param_optional_params.shrinkRetainingCapacity(state.deferred_param_optional_params_len);
        self.defer_param_metadata_depth = state.defer_param_metadata_depth;
        self.pending_greater_than = state.pending_greater_than;
        self.pending_equal = state.pending_equal;
        self.split_greater_end = state.split_greater_end;
    }

    /// Get the start position of a node (checking overrides first).
    pub fn nodeStartPos(self: *const Parser, idx: NodeIndex) u32 {
        const i = @intFromEnum(idx);
        if (self.node_start_overrides.get(i)) |override| return override;
        return self.token_starts[@intFromEnum(self.nodes.items(.main_token)[i])];
    }

    // === Node creation ===

    pub fn addNode(self: *Parser, node: Node) Error!NodeIndex {
        const idx: u32 = @intCast(self.nodes.len);
        var n = node;
        // Auto-set end_offset to end of last consumed token
        if (self.token_index > 0) {
            n.end_offset = self.token_ends[self.token_index - 1];
        }
        try self.nodes.append(self.allocator, n);
        return @enumFromInt(idx);
    }

    /// Map a token tag to the appropriate AST node tag for property/method keys.
    fn keyNodeTag(tok_tag: @import("token.zig").Token.Tag) Node.Tag {
        return if (tok_tag == .string) .string_literal else if (tok_tag == .numeric) .numeric_literal else if (tok_tag == .bigint) .bigint_literal else .identifier;
    }

    pub fn addExtra(self: *Parser, value: u32) !u32 {
        const idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(self.allocator, value);
        return idx;
    }

    pub const Range = struct { start: u32, end: u32 };

    pub fn addExtraRange(self: *Parser, items: []const NodeIndex) !Range {
        const start: u32 = @intCast(self.extra_data.items.len);
        for (items) |item| {
            try self.extra_data.append(self.allocator, @intFromEnum(item));
        }
        const end_val: u32 = @intCast(self.extra_data.items.len);
        return .{ .start = start, .end = end_val };
    }

    // === Error recovery ===

    fn synchronize(self: *Parser) void {
        while (self.currentTag() != .eof) {
            if (self.currentTag() == .semicolon) {
                _ = self.advance();
                return;
            }
            switch (self.currentTag()) {
                .kw_function,
                .kw_class,
                .kw_var,
                .kw_let,
                .kw_const,
                .kw_if,
                .kw_for,
                .kw_while,
                .kw_return,
                .kw_try,
                .kw_import,
                .kw_export,
                => return,
                else => _ = self.advance(),
            }
        }
    }

    pub fn recoverAfterError(self: *Parser, failed_token_index: u32) void {
        self.synchronize();
        // If synchronization stopped at the same token, consume one token so recovery makes progress.
        if (self.token_index == failed_token_index and self.currentTag() != .eof) {
            _ = self.advance();
        }
    }

    /// Skip tokens until we find a position that could start a new class member.
    fn skipToClassMemberBoundary(self: *Parser, failed_token_index: u32) void {
        // Ensure progress: if we're still at the failed token, consume one.
        if (self.token_index == failed_token_index and self.currentTag() != .eof) {
            _ = self.advance();
        }
        while (self.currentTag() != .eof) {
            switch (self.currentTag()) {
                // These could start a new class member
                .r_brace => return,
                .semicolon => {
                    _ = self.advance();
                    return;
                },
                .identifier,
                .hash,
                .l_bracket,
                .asterisk,
                .kw_static,
                .kw_get,
                .kw_set,
                .kw_async,
                .string,
                .numeric,
                => return,
                else => _ = self.advance(),
            }
        }
    }

    /// Skip tokens until we reach r_paren (stop) or the given delimiter (consume and stop).
    fn skipToDelimiter(self: *Parser, comptime consume_tag: Token.Tag) void {
        while (self.currentTag() != .eof) {
            if (self.currentTag() == .r_paren) return;
            if (self.currentTag() == consume_tag) {
                _ = self.advance();
                return;
            }
            _ = self.advance();
        }
    }

    /// Consume a semicolon, handling ASI (Automatic Semicolon Insertion).
    pub fn expectSemicolon(self: *Parser) !void {
        if (self.currentTag() == .semicolon) {
            _ = self.advance();
            return;
        }
        // ASI: insert semicolon if newline before current token, or at }, or at EOF
        if (self.hasNewlineBefore() or self.currentTag() == .r_brace or self.currentTag() == .eof) {
            return;
        }
        self.errors.addError("expected semicolon", self.currentStart());
        return error.ParseError;
    }

    // === Grammar rules ===

    fn parseProgram(self: *Parser) Error!NodeIndex {
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        // Parse directive prologue: consecutive expression statements whose
        // expression is a string literal are treated as directives.
        var in_directive_prologue = true;
        while (self.currentTag() != .eof) {
            const failed_token_index = self.token_index;
            const stmt = self.parseStatementOrDeclaration() catch {
                self.recoverAfterError(failed_token_index);
                in_directive_prologue = false;
                continue;
            };

            // Check if this is a directive (string literal expression statement)
            if (in_directive_prologue) {
                const tags = self.nodes.items(.tag);
                const datas = self.nodes.items(.data);
                if (tags[@intFromEnum(stmt)] == .expression_statement) {
                    const expr_idx = datas[@intFromEnum(stmt)].unary;
                    if (tags[@intFromEnum(expr_idx)] == .string_literal) {
                        // Convert to directive node
                        const dir_literal = try self.addNode(.{
                            .tag = .directive_literal,
                            .main_token = self.nodes.items(.main_token)[@intFromEnum(expr_idx)],
                            .data = .{ .none = {} },
                        });
                        // Copy end_offset from the string literal for the directive literal
                        self.nodes.items(.end_offset)[@intFromEnum(dir_literal)] =
                            self.nodes.items(.end_offset)[@intFromEnum(expr_idx)];
                        const dir_node = try self.addNode(.{
                            .tag = .directive,
                            .main_token = self.nodes.items(.main_token)[@intFromEnum(stmt)],
                            .data = .{ .unary = dir_literal },
                        });
                        // Copy end_offset from the expression statement
                        self.nodes.items(.end_offset)[@intFromEnum(dir_node)] =
                            self.nodes.items(.end_offset)[@intFromEnum(stmt)];
                        try self.scratch.append(self.allocator, dir_node);
                        continue;
                    }
                }
                in_directive_prologue = false;
            }

            try self.scratch.append(self.allocator, stmt);
        }

        const stmts = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(stmts);

        // Update the root node (index 0) with the program data
        // Store start and end of the range in extra_data
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        self.nodes.items(.data)[0] = .{ .extra = @enumFromInt(extra_start) };
        // Set end_offset to the end of the last consumed token (not source.len),
        // so that trailing whitespace/newlines are excluded — matching Babel behavior.
        // When no tokens were consumed (empty/whitespace-only source), use 0.
        self.nodes.items(.end_offset)[0] = if (self.token_index > 0)
            self.token_ends[self.token_index - 1]
        else
            0;

        return @enumFromInt(0);
    }

    fn parseSingleStatement(self: *Parser) Error!NodeIndex {
        const saved = self.in_single_statement;
        self.in_single_statement = true;
        defer self.in_single_statement = saved;
        return self.parseStatementOrDeclaration();
    }

    pub fn parseStatementOrDeclaration(self: *Parser) Error!NodeIndex {
        // Placeholders as statements: only if followed by `;`, `}`, EOF, or newline (ASI)
        // Otherwise, fall through to expression parsing so `%%FOO%% + bar` works.
        if (self.isPlaceholder()) {
            const after_ph = self.lookAhead(5); // tokens: % % IDENT % % <next>
            // Check for ASI: newline between the closing %% and the next token
            const has_asi = blk: {
                const ph_end_idx = self.token_index + 4; // index of last %
                const next_idx = self.token_index + 5;
                if (next_idx < self.token_starts.len) {
                    const ph_end_pos = self.token_ends[ph_end_idx];
                    const next_pos = self.token_starts[next_idx];
                    var si: u32 = ph_end_pos;
                    while (si < next_pos and si < self.source.len) : (si += 1) {
                        if (self.source[si] == '\n' or self.source[si] == '\r') break :blk true;
                    }
                }
                break :blk false;
            };
            if (after_ph == .semicolon or after_ph == .r_brace or after_ph == .eof or has_asi) {
                const ph = try self.parsePlaceholder("Statement");
                // Update end position to include the semicolon
                if (self.eat(.semicolon)) |semi_tok| {
                    self.nodes.items(.end_offset)[@intFromEnum(ph)] = self.token_ends[@intFromEnum(semi_tok)];
                }
                return ph;
            }
            // Otherwise fall through — will be parsed as expression via parsePrefixExpression
        }

        // Decorators: @expr before class/export
        // Skip if this is @@ topic reference in pipeline context
        if (self.opts.enable_decorators and self.isAtDecorator() and !self.isDoubleAtTopicReference()) {
            return self.parseDecoratedStatement();
        }

        // Check for identifiers that are escaped keywords (e.g., co\u{6e}st → "const")
        if (self.currentTag() == .identifier) {
            if (self.resolvedEscapedKeyword()) |esc_kw| {
                if (!escapedKeywordUsesIdentifierSemantics(esc_kw)) {
                    self.errors.addError("escape sequence in keyword", self.currentStart());
                    switch (esc_kw) {
                        .kw_const => return self.parseVariableDeclaration(.const_declaration),
                        .kw_if => return self.parseIfStatement(),
                        .kw_export => return self.parseExportDeclaration(),
                        .kw_import => return self.parseImportOrImportExpr(),
                        else => {},
                    }
                }
            }
        }
        return switch (self.currentTag()) {
            .kw_var => self.parseVariableDeclaration(.var_declaration),
            .kw_let => self.parseLetDeclaration(),
            .kw_const => {
                if (self.isTsConstEnum()) {
                    return @import("parser_ts.zig").parseTsEnumDeclaration(self);
                }
                return self.parseVariableDeclaration(.const_declaration);
            },
            .kw_function => blk_func: {
                // function.sent MetaProperty at statement level
                if (self.opts.enable_function_sent and self.lookAhead(1) == .dot) {
                    break :blk_func self.parseExpressionStatement();
                }
                break :blk_func self.parseFunctionDeclaration();
            },
            .kw_if => self.parseIfStatement(),
            .kw_return => self.parseReturnStatement(),
            .kw_throw => self.parseThrowStatement(),
            .l_brace => self.parseBlockStatement(),
            .semicolon => self.parseEmptyStatement(),
            .kw_while => self.parseWhileStatement(),
            .kw_do => self.parseDoWhileStatement(),
            .kw_for => self.parseForStatement(),
            .kw_break => self.parseBreakContinue(.break_statement),
            .kw_continue => self.parseBreakContinue(.continue_statement),
            .kw_switch => self.parseSwitchStatement(),
            .kw_try => self.parseTryStatement(),
            .kw_class => {
                if (self.in_single_statement) {
                    self.errors.addError("Unexpected token", self.currentStart());
                }
                return self.parseClassDeclaration();
            },
            .kw_import => self.parseImportOrImportExpr(),
            .kw_export => self.parseExportDeclaration(),
            .kw_with => self.parseWithStatement(),
            .kw_debugger => self.parseDebuggerStatement(),
            .kw_async => self.parseAsyncPrefix(),
            .kw_await => {
                if (self.isAwaitUsingDeclaration()) return self.parseAwaitUsingDeclaration();
                return self.parseExpressionOrLabeledStatement();
            },
            else => {
                if (self.isUsingDeclarationWithDestructuring()) return self.parseUsingDeclaration();
                // Flow-specific statement parsing
                if (self.isFlow() and self.currentTag() == .identifier) {
                    const flow_mod = @import("parser_flow.zig");
                    switch (self.currentSoftKeyword()) {
                        .type_ => return flow_mod.parseFlowTypeAlias(self),
                        .opaque_ => return flow_mod.parseFlowOpaqueType(self),
                        .interface => return flow_mod.parseFlowInterfaceDeclaration(self),
                        .declare => return flow_mod.parseFlowDeclareStatement(self),
                        .enum_ => return flow_mod.parseFlowEnumDeclaration(self),
                        else => {
                            if (flow_mod.decodedIdentifierEquals(self.tokenText(self.token_index), "interface")) {
                                return flow_mod.parseFlowInterfaceDeclaration(self);
                            }
                        },
                    }
                }
                // TypeScript declaration keywords (contextual identifiers)
                if (self.isTypeScript() and self.currentTag() == .identifier) {
                    const parser_ts = @import("parser_ts.zig");
                    const soft = self.currentSoftKeyword();
                    if (soft == .type_ and !self.hasNewlineAfterCurrent()) return parser_ts.parseTsTypeAliasDeclaration(self);
                    if (soft == .interface and !self.hasNewlineAfterCurrent()) return parser_ts.parseTsInterfaceDeclaration(self);
                    if (soft == .enum_) return parser_ts.parseTsEnumDeclaration(self);
                    if ((soft == .namespace or soft == .module) and !self.hasNewlineAfterCurrent()) return parser_ts.parseTsModuleDeclaration(self);
                    if (soft == .global and self.lookAhead(1) == .l_brace) return parser_ts.parseTsModuleDeclaration(self);
                    if (soft == .declare and !self.hasNewlineAfterCurrent()) {
                        const next_tag = self.lookAhead(1);
                        const next_soft = self.softKeywordAt(self.token_index + 1);
                        // Check if next token is a valid declaration keyword for `declare`
                        const next_is_decl_valid = next_tag == .kw_function or
                            next_tag == .kw_var or next_tag == .kw_let or next_tag == .kw_const or
                            next_tag == .kw_class or next_tag == .kw_async or next_tag == .kw_await or
                            (next_tag == .identifier and (next_soft == .enum_ or
                                next_soft == .namespace or
                                next_soft == .module or
                                next_soft == .interface or
                                next_soft == .type_ or
                                next_soft == .global or
                                next_soft == .abstract_ or
                                next_soft == .using_));
                        // Skip if a contextual keyword is followed by newline
                        const next_has_nl = self.hasNewlineAfterOffset(1);
                        const next_is_soft_kw = next_soft == .interface or
                            next_soft == .type_ or
                            next_soft == .namespace or
                            next_soft == .module or
                            (next_soft == .abstract_ and self.lookAhead(2) == .kw_class);
                        if (next_is_decl_valid and !(next_is_soft_kw and next_has_nl)) {
                            return parser_ts.parseTsDeclareStatement(self);
                        }
                    }
                    if (soft == .abstract_ and self.lookAhead(1) == .kw_class and !self.hasNewlineAfterCurrent()) {
                        const abstract_tok = self.advance();
                        const cls = try self.parseClassDeclaration();
                        self.nodes.items(.main_token)[@intFromEnum(cls)] = abstract_tok;
                        try self.storeTsModifiers(cls, TS_MOD_ABSTRACT);
                        return cls;
                    }
                    if (soft == .abstract_ and self.lookAhead(1) == .identifier and
                        self.softKeywordAt(self.token_index + 1) == .interface and
                        !self.hasNewlineAfterCurrent() and !self.hasNewlineAfterOffset(1))
                    {
                        const abstract_tok = self.advance();
                        self.errors.addError("'abstract' modifier can only appear on a class, method, or property declaration.", self.token_starts[@intFromEnum(abstract_tok)]);
                        const iface = try parser_ts.parseTsInterfaceDeclaration(self);
                        self.nodes.items(.main_token)[@intFromEnum(iface)] = abstract_tok;
                        try self.storeTsModifiers(iface, TS_MOD_ABSTRACT);
                        return iface;
                    }
                }

                // `enum` is a reserved word — emit error but continue parsing
                if (self.currentTag() == .identifier and self.currentSoftKeyword() == .enum_) {
                    self.errors.addError("Unexpected reserved word 'enum'", self.currentStart());
                }
                return self.parseExpressionOrLabeledStatement();
            },
        };
    }

    // === Expression Parser (Pratt) ===

    pub const Precedence = enum(u8) {
        none,
        comma, // ,
        assignment, // = += -= etc
        pipeline, // |>
        conditional, // ?:
        nullish_coalescing, // ??
        logical_or, // ||
        logical_and, // &&
        bitwise_or, // |
        bitwise_xor, // ^
        bitwise_and, // &
        equality, // == != === !==
        relational, // < > <= >= instanceof in
        shift, // << >> >>>
        additive, // + -
        multiplicative, // * / %
        exponentiation, // **
        unary, // ! ~ typeof void delete + - ++ --
        postfix, // ++ --
        call, // () [] .
        member, // new

        fn forToken(tag: Token.Tag) Precedence {
            return switch (tag) {
                .comma => .comma,
                .equal,
                .plus_equal,
                .minus_equal,
                .asterisk_equal,
                .slash_equal,
                .percent_equal,
                .power_equal,
                .ampersand_equal,
                .pipe_equal,
                .caret_equal,
                .less_less_equal,
                .greater_greater_equal,
                .greater_greater_greater_equal,
                .ampersand_ampersand_equal,
                .pipe_pipe_equal,
                .question_question_equal,
                => .assignment,
                .question => .conditional,
                .question_question => .nullish_coalescing,
                .pipe_pipe => .logical_or,
                .ampersand_ampersand => .logical_and,
                .pipe => .bitwise_or,
                .caret => .bitwise_xor,
                .ampersand => .bitwise_and,
                .equal_equal, .bang_equal, .equal_equal_equal, .bang_equal_equal => .equality,
                .less_than,
                .greater_than,
                .less_equal,
                .greater_equal,
                .kw_instanceof,
                .kw_in,
                => .relational,
                .less_less, .greater_greater, .greater_greater_greater => .shift,
                .plus, .minus => .additive,
                .asterisk, .slash, .percent => .multiplicative,
                .power => .exponentiation,
                else => .none,
            };
        }
    };

    pub const Error = error{ParseError} || std.mem.Allocator.Error;

    pub fn parseExpression(self: *Parser) Error!NodeIndex {
        const start_token: TokenIndex = @enumFromInt(self.token_index);
        var expr = try self.parseAssignmentExpression();

        // Handle comma expressions (SequenceExpression)
        if (self.currentTag() == .comma) {
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);
            try self.scratch.append(self.allocator, expr);
            while (self.eat(.comma) != null) {
                const next = try self.parseAssignmentExpression();
                try self.scratch.append(self.allocator, next);
            }
            const items = self.scratch.items[scratch_start..];
            const range = try self.addExtraRange(items);
            const extra_start = try self.addExtra(range.start);
            _ = try self.addExtra(range.end);
            expr = try self.addNode(.{
                .tag = .sequence_expr,
                .main_token = start_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
        }
        return expr;
    }

    /// Parse expression without allowing 'in' as a binary operator (for for-in detection)
    fn parseExpressionNoIn(self: *Parser) Error!NodeIndex {
        const saved = self.no_in;
        self.no_in = true;
        defer self.no_in = saved;
        return self.parseAssignmentExpression();
    }

    pub fn parseAssignmentExpression(self: *Parser) Error!NodeIndex {
        // yield and await have very low precedence (below all binary operators),
        // so they must be handled here, not inside parsePrefixExpression where
        // the result would be fed into the precedence climbing loop.
        if (self.currentTag() == .kw_yield and self.in_generator) {
            return self.parseYieldExpression();
        }
        if (self.currentTag() == .kw_yield and !self.in_generator and !self.in_class_field_init) {
            // In non-generator context, yield followed by expression-like tokens
            // should be parsed as YieldExpression with an error (Babel error recovery).
            // But yield => ... is an arrow function, not a yield expression.
            // Skip this in class field initializers where yield is always an identifier.
            // yield * x should be treated as identifier * x (multiplication), not yield delegate.
            const la = self.lookAhead(1);
            if (la != .arrow and la != .semicolon and la != .eof and la != .r_paren and
                la != .r_bracket and la != .r_brace and la != .colon and la != .comma and
                la != .asterisk and
                self.looksLikeYieldExpr())
            {
                self.errors.addError("'yield' is only allowed within generator functions", self.currentStart());
                return self.parseYieldExpression();
            }
        }
        if (self.currentTag() == .kw_await and self.in_async) {
            // Parse await expression, then continue with binary operators at assignment precedence.
            // This allows `await x in y` to be parsed as `(await x) in y`.
            const await_node = try self.parseAwaitExpression();
            return self.parseBinaryLoop(await_node, .assignment);
        }
        return self.parseExpressionPrec(.assignment);
    }

    /// Parse the RHS of a fsharp/minimal pipeline operator.
    /// Arrow functions on the RHS have their body limited so it does NOT consume `|>`.
    /// Non-arrow expressions parse left-to-right (don't consume `|>`).
    fn parseFsharpPipelineRHS(self: *Parser) Error!NodeIndex {
        // Set flag so arrow function bodies parse at conditional precedence
        // (i.e., they don't consume `|>` in their body).
        const saved = self.in_fsharp_pipeline_body;
        self.in_fsharp_pipeline_body = true;
        defer self.in_fsharp_pipeline_body = saved;
        // Detect arrow function patterns that should be parsed as assignment
        if (self.looksLikeArrowStart()) {
            return self.parseAssignmentExpression();
        }
        // In fsharp pipeline, `await` is always a bare pipeline step (no argument).
        // e.g., `x |> await |> f` means `f(await x)`.
        // `x |> await f` means `(x |> await); f;` (two statements).
        if (self.currentTag() == .kw_await and self.in_async) {
            const await_token = self.advance();
            return self.addNode(.{ .tag = .await_expr, .main_token = await_token, .data = .{ .unary = .none } });
        }
        // Parse at conditional precedence (above pipeline), so `|>` is NOT consumed
        return self.parseExpressionPrec(.conditional);
    }

    /// Parse arrow function body, respecting fsharp pipeline body context.
    /// In fsharp pipeline body mode, arrows don't consume `|>` in their body.
    fn parseArrowBody(self: *Parser) Error!NodeIndex {
        if (self.currentTag() == .l_brace) {
            return self.parseBlockStatement();
        }
        if (self.in_fsharp_pipeline_body) {
            return self.parseExpressionPrec(.conditional);
        }
        return self.parseAssignmentExpression();
    }

    fn parseArrowBodyWithNoIn(self: *Parser, no_in: bool) Error!NodeIndex {
        const saved_no_in = self.no_in;
        self.no_in = no_in;
        defer self.no_in = saved_no_in;
        return self.parseArrowBody();
    }

    /// Heuristic: does the current position look like the start of an arrow function?
    fn looksLikeArrowStart(self: *Parser) bool {
        // x => ...
        if (self.currentTag() == .identifier and self.lookAhead(1) == .arrow) return true;
        // async x => ... or async (x) => ...
        if (self.currentTag() == .kw_async and !self.hasNewlineAfterCurrent()) {
            if (self.lookAhead(1) == .identifier and self.lookAhead(2) == .arrow) return true;
            if (self.lookAhead(1) == .l_paren) return true;
        }
        // (x) => ... or (x, y) => ...
        if (self.currentTag() == .l_paren) {
            // Walk forward to find matching ) and check for =>
            var depth: u32 = 0;
            var i: u32 = 0;
            while (true) {
                const t = self.lookAhead(i);
                if (t == .eof) break;
                if (t == .l_paren) depth += 1;
                if (t == .r_paren) {
                    depth -= 1;
                    if (depth == 0) {
                        // Check if followed by => (possibly with TypeScript return type annotation)
                        const after = self.lookAhead(i + 1);
                        if (after == .arrow) return true;
                        if (after == .colon) return true; // (x): T => ...
                        break;
                    }
                }
                i += 1;
                if (i > 100) break; // Safety limit
            }
        }
        return false;
    }

    /// Emit an error if `node` is an arrow function expression.
    /// Used to reject arrows in positions where they are syntactically invalid
    /// (e.g. class heritage, unary operands).
    fn rejectArrowNode(self: *Parser, node: NodeIndex) void {
        if (node != .none and self.nodes.items(.tag)[@intFromEnum(node)] == .arrow_function_expr) {
            self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(self.nodes.items(.main_token)[@intFromEnum(node)])]);
        }
    }

    /// Check if yield looks like it's used as a yield expression (followed by an expression-start token)
    fn looksLikeYieldExpr(self: *Parser) bool {
        const la = self.lookAhead(1);
        return switch (la) {
            .identifier,
            .numeric,
            .string,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_this,
            .kw_function,
            .kw_class,
            .kw_new,
            .kw_typeof,
            .kw_void,
            .kw_delete,
            .kw_yield,
            .kw_await,
            .kw_async,
            .l_paren,
            .l_bracket,
            .l_brace,
            .template_head,
            .template_no_sub,
            .bang,
            .tilde,
            => true,
            else => false,
        };
    }

    pub fn parseExpressionPrec(self: *Parser, min_prec: Precedence) Error!NodeIndex {
        // Prevent arrow function parsing in higher-precedence contexts
        const saved_no_arrow = self.no_arrow;
        if (@intFromEnum(min_prec) > @intFromEnum(Precedence.assignment)) {
            self.no_arrow = true;
        } else {
            self.no_arrow = false;
        }
        const left = try self.parsePrefixExpression();
        self.no_arrow = saved_no_arrow;

        // Arrow functions cannot be operands of binary, call, ternary, etc.
        {
            const left_tag = self.nodes.items(.tag)[@intFromEnum(left)];
            if (left_tag == .arrow_function_expr) {
                const cur = self.currentTag();
                // Case 1: Arrow as RHS of a higher-precedence operator
                // (e.g. `true || () => {}` — arrow in logical_or context)
                if (@intFromEnum(min_prec) > @intFromEnum(Precedence.assignment)) {
                    self.errors.addError("Unexpected token", self.currentStart());
                }
                // Case 2: Arrow followed by `(` or other operators — treat as ASI
                // (arrow function results are not valid call targets)
                else if (cur == .l_paren or cur == .question or cur == .dot or
                    cur == .l_bracket or cur == .kw_in or cur == .kw_instanceof or
                    Precedence.forToken(cur) != .none)
                {
                    // Don't error for comma/assignment/semicolons — those are valid.
                    if (cur != .comma and !cur.isAssignment() and cur != .semicolon and
                        cur != .r_paren and cur != .r_bracket and cur != .r_brace and
                        cur != .colon and cur != .eof)
                    {
                        // Return early to avoid consuming the token as a continuation
                        return left;
                    }
                }
            }
        }

        return self.parseBinaryLoop(left, min_prec);
    }

    /// Continue parsing binary/postfix/call/member operators given an already-parsed
    /// left-hand side. Used by parseExpressionPrec and also directly when await/yield
    /// need to participate in binary operators after being parsed at unary precedence.
    fn parseBinaryLoop(self: *Parser, initial_left: NodeIndex, min_prec: Precedence) Error!NodeIndex {
        var left = initial_left;

        while (true) {
            // Handle postfix ++ and --
            // Only apply to LeftHandSideExpressions (not unary/await expressions)
            if ((self.currentTag() == .plus_plus or self.currentTag() == .minus_minus) and !self.hasNewlineBefore()) {
                const left_tag = self.nodes.items(.tag)[@intFromEnum(left)];
                if (left_tag != .unary_expr and left_tag != .await_expr) {
                    const op_token = self.advance();
                    left = try self.addNode(.{
                        .tag = .update_expr,
                        .main_token = op_token,
                        .data = .{ .unary = left },
                    });
                    continue;
                }
            }

            // Handle call, member access, optional chaining
            // Check if left is part of an optional chain — if so, propagate optional types
            const left_in_opt_chain = self.isOptionalChainNode(left);
            if (@intFromEnum(min_prec) <= @intFromEnum(Precedence.call)) {
                const allow_instantiation = @intFromEnum(min_prec) < @intFromEnum(Precedence.call);
                if (try self.tryParseTypeArgumentsForCallOrInstantiation(allow_instantiation)) |type_args| {
                    if (self.currentTag() == .l_paren) {
                        // Call expression with type arguments: f<T>(args)
                        left = if (left_in_opt_chain)
                            try self.parseOptionalCallInChain(left)
                        else
                            try self.parseCallExpression(left);
                        try self.putTypeParameters(left, type_args);
                    } else if (self.currentTag() == .template_no_sub or self.currentTag() == .template_head) {
                        // Tagged template with type arguments: f<T>`...`
                        left = try self.parseTaggedTemplate(left);
                        try self.putTypeParameters(left, type_args);
                    } else {
                        // Instantiation expression: f<T>
                        left = try self.addNode(.{
                            .tag = .ts_instantiation_expression,
                            .main_token = self.nodes.items(.main_token)[@intFromEnum(left)],
                            .data = .{ .binary = .{ .lhs = left, .rhs = type_args } },
                        });
                    }
                    continue;
                }
            }
            switch (self.currentTag()) {
                .l_paren => {
                    if (@intFromEnum(min_prec) > @intFromEnum(Precedence.call)) break;
                    if (self.hasNewlineBefore() and self.nodes.items(.tag)[@intFromEnum(left)] == .update_expr) {
                        break;
                    }
                    if (left_in_opt_chain) {
                        left = try self.parseOptionalCallInChain(left);
                    } else {
                        left = try self.parseCallExpression(left);
                    }
                    continue;
                },
                .dot => {
                    if (@intFromEnum(min_prec) > @intFromEnum(Precedence.call)) break;
                    if (left_in_opt_chain) {
                        left = try self.parseOptionalMemberInChain(left);
                    } else {
                        left = try self.parseMemberExpression(left);
                    }
                    continue;
                },
                .l_bracket => {
                    if (@intFromEnum(min_prec) > @intFromEnum(Precedence.call)) break;
                    if (left_in_opt_chain) {
                        left = try self.parseOptionalComputedInChain(left);
                    } else {
                        left = try self.parseComputedMemberExpression(left);
                    }
                    continue;
                },
                .optional_chain => {
                    if (@intFromEnum(min_prec) > @intFromEnum(Precedence.call)) break;
                    left = try self.parseOptionalChainExpression(left);
                    continue;
                },
                .template_no_sub, .template_head => {
                    if (@intFromEnum(min_prec) > @intFromEnum(Precedence.call)) break;
                    left = try self.parseTaggedTemplate(left);
                    continue;
                },
                .colon => {
                    // Bind operator: a :: b  (two colons)
                    if (self.opts.enable_bind_operator and self.lookAhead(1) == .colon) {
                        if (@intFromEnum(min_prec) > @intFromEnum(Precedence.call)) break;
                        _ = self.advance(); // first :
                        _ = self.advance(); // second :
                        // Check for invalid RHS: super and import
                        if (self.currentTag() == .kw_super or self.currentTag() == .kw_import) {
                            self.errors.addError("The right-hand side of binding can not be super or import.", self.currentStart());
                            return error.ParseError;
                        }
                        // RHS should be parsed as a primary expression (not including calls)
                        const right = try self.parsePrefixExpression();
                        // Use left's main_token so BindExpression start comes from the object
                        left = try self.addNode(.{
                            .tag = .bind_expression,
                            .main_token = self.nodes.items(.main_token)[@intFromEnum(left)],
                            .data = .{ .binary = .{ .lhs = left, .rhs = right } },
                        });
                        continue;
                    }
                },
                else => {},
            }

            // TypeScript postfix operators: `as`, `satisfies`, `!`
            // `as` and `satisfies` have the same precedence as relational operators
            if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                if (@intFromEnum(min_prec) <= @intFromEnum(Precedence.relational)) {
                    if ((self.currentTag() == .kw_as or
                        self.identifierEquals(self.token_index, "as")) and
                        !self.hasNewlineBefore())
                    {
                        left = try parser_ts.parseTsAsExpression(self, left);
                        continue;
                    }
                    if (self.currentTag() == .identifier and !self.hasNewlineBefore() and self.currentSoftKeyword() == .satisfies) {
                        left = try parser_ts.parseTsSatisfiesExpression(self, left);
                        continue;
                    }
                }
                if (self.currentTag() == .bang and !self.hasNewlineBefore()) {
                    const next = self.lookAhead(1);
                    if (next != .equal and next != .equal_equal) {
                        left = try parser_ts.parseTsNonNullExpression(self, left);
                        continue;
                    }
                }
            }

            // Skip 'in' operator when in no_in mode (for-in detection)
            if (self.no_in and self.currentTag() == .kw_in) break;
            // A placeholder starting on a new line should terminate the previous
            // expression so ASI can kick in.
            if (self.opts.enable_placeholders and self.hasNewlineBefore() and self.currentTag() == .percent and self.lookAhead(1) == .percent) break;

            // Pipeline operator: `|` followed by `>` forms `|>` — must check before
            // general precedence lookup, otherwise `|` is misinterpreted as bitwise OR.
            if (self.opts.enable_pipeline_operator and self.currentTag() == .pipe) {
                const next_idx = self.token_index + 1;
                if (next_idx < self.token_tags.len and self.token_tags[next_idx] == .greater_than) {
                    if (@intFromEnum(Precedence.pipeline) >= @intFromEnum(min_prec)) {
                        const op_token = self.advance(); // consume |
                        _ = self.advance(); // consume >
                        const right = if (self.opts.pipeline_proposal == .hack)
                            try self.parseAssignmentExpression()
                        else
                            try self.parseFsharpPipelineRHS();
                        left = try self.addNode(.{
                            .tag = .binary_expr,
                            .main_token = op_token,
                            .data = .{ .binary = .{ .lhs = left, .rhs = right } },
                        });
                        continue;
                    } else {
                        break; // pipeline prec too low for current context
                    }
                }
            }

            // Handle pending_equal from topic token splitting (%=, ^=, etc.).
            // pending_equal means a `=` was split off from a compound token.
            // Combine it with the current token to form the real operator.
            if (self.pending_equal) {
                const cur = self.currentTag();
                if (cur == .equal_equal) {
                    // pending `=` + `==` → `===`
                    self.pending_equal = false;
                    const op_token = self.advance();
                    const right = try self.parseExpressionPrec(.equality);
                    left = try self.addNode(.{
                        .tag = .binary_expr,
                        .main_token = op_token,
                        .data = .{ .binary = .{ .lhs = left, .rhs = right } },
                    });
                    // Override to === in serialization via operator_overrides
                    try self.operator_overrides.put(self.allocator, @intFromEnum(left), "===");
                    continue;
                } else if (cur == .equal) {
                    // pending `=` + `=` → `==`
                    self.pending_equal = false;
                    const op_token = self.advance();
                    const right = try self.parseExpressionPrec(.equality);
                    left = try self.addNode(.{
                        .tag = .binary_expr,
                        .main_token = op_token,
                        .data = .{ .binary = .{ .lhs = left, .rhs = right } },
                    });
                    // Override to == in serialization via operator_overrides
                    try self.operator_overrides.put(self.allocator, @intFromEnum(left), "==");
                    continue;
                } else {
                    // Just a bare `=` — treat as assignment
                    self.pending_equal = false;
                }
            }

            const prec = Precedence.forToken(self.currentTag());
            if (prec == .none or @intFromEnum(prec) < @intFromEnum(min_prec)) break;

            // Handle assignment (right-associative)
            if (self.currentTag().isAssignment()) {
                // Optional chain expressions cannot be assigned to
                if (self.isOptionalChainNode(left)) {
                    self.errors.addError("Invalid left-hand side in assignment expression", self.currentStart());
                }
                const op_token = self.advance();
                // Convert LHS expression to pattern for destructuring assignments
                if (self.token_tags[@intFromEnum(op_token)] == .equal) {
                    self.convertToPattern(left);
                }
                const right = try self.parseAssignmentExpression();
                left = try self.addNode(.{
                    .tag = .assignment_expr,
                    .main_token = op_token,
                    .data = .{ .binary = .{ .lhs = left, .rhs = right } },
                });
                continue;
            }

            // Handle conditional (ternary)
            if (self.currentTag() == .question) {
                if (self.isFlow()) {
                    left = try self.parseFlowConditional(left);
                    continue;
                }
                const q_token = self.advance();
                // In TypeScript, set a flag so that `:` after async(b) in
                // `a ? async(b) : c => d` is treated as ternary separator,
                // not as a return type annotation.
                const saved_in_cond = self.in_conditional_consequent;
                if (self.isTypeScript()) self.in_conditional_consequent = true;
                const consequent = try self.parseAssignmentExpression();
                self.in_conditional_consequent = saved_in_cond;
                _ = try self.expect(.colon);
                const alternate = try self.parseAssignmentExpression();
                // Store consequent and alternate in extra_data
                const extra_start = try self.addExtra(@intFromEnum(consequent));
                _ = try self.addExtra(@intFromEnum(alternate));
                left = try self.addNode(.{
                    .tag = .conditional_expr,
                    .main_token = q_token,
                    .data = .{ .binary = .{ .lhs = left, .rhs = @enumFromInt(extra_start) } },
                });
                continue;
            }

            // Binary/logical operators
            const op_token = self.advance();

            // Check for mixing ?? with || or && without parentheses
            if (prec == .nullish_coalescing or prec == .logical_or or prec == .logical_and) {
                self.checkNullishMixing(left, prec, op_token);
            }

            // Determine next precedence (right-associative for **)
            const next_prec: Precedence = if (prec == .exponentiation) prec else @enumFromInt(@intFromEnum(prec) + 1);
            const right = try self.parseExpressionPrec(next_prec);

            if (prec == .nullish_coalescing or prec == .logical_or or prec == .logical_and) {
                self.checkNullishMixing(right, prec, op_token);
            }

            const tag: Node.Tag = switch (prec) {
                .logical_or, .logical_and, .nullish_coalescing => .logical_expr,
                else => .binary_expr,
            };

            left = try self.addNode(.{
                .tag = tag,
                .main_token = op_token,
                .data = .{ .binary = .{ .lhs = left, .rhs = right } },
            });
        }

        return left;
    }

    /// Flow: parse conditional expression with arrow function disambiguation.
    /// Implements the Babel Flow plugin's parseConditional logic with backtracking.
    fn parseFlowConditional(self: *Parser, test_expr: NodeIndex) Error!NodeIndex {
        const q_token = self.advance(); // consume ?

        // Save original state for potential retries
        const original_no_arrow_at = self.flow_no_arrow_at;
        const original_no_arrow_at_len = self.flow_no_arrow_at_len;
        const saved_pending_async = self.pending_async_arrow;

        // Helper: restore parser to post-? state with given no_arrow_at
        const state1 = self.saveState();

        // First attempt: try to parse the consequent
        const consequent1 = try self.parseAssignmentExpression();
        const failed1 = self.currentTag() != .colon;

        // Collect arrow-like expressions from the consequent
        var arrow_starts: [8]u32 = .{0} ** 8;
        var arrow_count: u8 = 0;
        var arrow_nodes_arr: [8]NodeIndex = .{.none} ** 8;
        self.collectArrowNodes(consequent1, &arrow_nodes_arr, &arrow_starts, &arrow_count);

        if (failed1 or arrow_count > 0) {
            // Classify arrows as valid (params are assignable) or invalid (params not assignable)
            var invalid_starts: [8]u32 = .{0} ** 8;
            var invalid_count: u8 = 0;
            var valid_starts: [8]u32 = .{0} ** 8;
            var valid_count: u8 = 0;

            for (0..arrow_count) |ai| {
                const anode = arrow_nodes_arr[ai];
                if (anode != .none and self.isArrowAllParamsValid(anode)) {
                    if (valid_count < valid_starts.len) {
                        valid_starts[valid_count] = arrow_starts[ai];
                        valid_count += 1;
                    }
                } else {
                    if (invalid_count < invalid_starts.len) {
                        invalid_starts[invalid_count] = arrow_starts[ai];
                        invalid_count += 1;
                    }
                }
            }

            if (invalid_count > 0) {
                // Retry with invalid arrow positions suppressed
                self.restoreState(state1);
                self.pending_async_arrow = saved_pending_async;
                self.flow_no_arrow_at = original_no_arrow_at;
                self.flow_no_arrow_at_len = original_no_arrow_at_len;

                for (invalid_starts[0..invalid_count]) |pos| {
                    if (self.flow_no_arrow_at_len < self.flow_no_arrow_at.len) {
                        self.flow_no_arrow_at[self.flow_no_arrow_at_len] = pos;
                        self.flow_no_arrow_at_len += 1;
                    }
                }

                const consequent2 = try self.parseAssignmentExpression();
                const failed2 = self.currentTag() != .colon;

                if (failed2) {
                    // Re-collect valid arrows from retry
                    var valid_starts2: [8]u32 = .{0} ** 8;
                    var valid_count2: u8 = 0;
                    var arrow_starts2: [8]u32 = .{0} ** 8;
                    var arrow_count2: u8 = 0;
                    var arrow_nodes2: [8]NodeIndex = .{.none} ** 8;
                    self.collectArrowNodes(consequent2, &arrow_nodes2, &arrow_starts2, &arrow_count2);
                    for (0..arrow_count2) |ai| {
                        const anode = arrow_nodes2[ai];
                        if (anode != .none and self.isArrowAllParamsValid(anode)) {
                            if (valid_count2 < valid_starts2.len) {
                                valid_starts2[valid_count2] = arrow_starts2[ai];
                                valid_count2 += 1;
                            }
                        }
                    }

                    if (valid_count2 == 1) {
                        // One valid arrow remaining — retry with it suppressed too
                        self.restoreState(state1);
                        self.pending_async_arrow = saved_pending_async;
                        self.flow_no_arrow_at = original_no_arrow_at;
                        self.flow_no_arrow_at_len = original_no_arrow_at_len;

                        for (invalid_starts[0..invalid_count]) |pos| {
                            if (self.flow_no_arrow_at_len < self.flow_no_arrow_at.len) {
                                self.flow_no_arrow_at[self.flow_no_arrow_at_len] = pos;
                                self.flow_no_arrow_at_len += 1;
                            }
                        }
                        if (self.flow_no_arrow_at_len < self.flow_no_arrow_at.len) {
                            self.flow_no_arrow_at[self.flow_no_arrow_at_len] = valid_starts2[0];
                            self.flow_no_arrow_at_len += 1;
                        }

                        const consequent3 = try self.parseAssignmentExpression();
                        _ = try self.expect(.colon);

                        self.flow_no_arrow_at = original_no_arrow_at;
                        self.flow_no_arrow_at_len = original_no_arrow_at_len;

                        const alternate = try self.parseAssignmentExpression();
                        const extra_start = try self.addExtra(@intFromEnum(consequent3));
                        _ = try self.addExtra(@intFromEnum(alternate));
                        return self.addNode(.{
                            .tag = .conditional_expr,
                            .main_token = q_token,
                            .data = .{ .binary = .{ .lhs = test_expr, .rhs = @enumFromInt(extra_start) } },
                        });
                    } else if (valid_count2 > 1) {
                        self.errors.addError("Ambiguous expression: wrap the arrow functions in parentheses to disambiguate.", self.currentStart());
                    }
                }

                // Use consequent2
                _ = try self.expect(.colon);

                self.flow_no_arrow_at = original_no_arrow_at;
                self.flow_no_arrow_at_len = original_no_arrow_at_len;

                const alternate = try self.parseAssignmentExpression();
                const extra_start = try self.addExtra(@intFromEnum(consequent2));
                _ = try self.addExtra(@intFromEnum(alternate));
                return self.addNode(.{
                    .tag = .conditional_expr,
                    .main_token = q_token,
                    .data = .{ .binary = .{ .lhs = test_expr, .rhs = @enumFromInt(extra_start) } },
                });
            }

            // No invalid arrows — only valid arrows
            if (failed1 and valid_count == 1) {
                // Single valid arrow — retry with it suppressed
                self.restoreState(state1);
                self.pending_async_arrow = saved_pending_async;
                self.flow_no_arrow_at = original_no_arrow_at;
                self.flow_no_arrow_at_len = original_no_arrow_at_len;

                if (self.flow_no_arrow_at_len < self.flow_no_arrow_at.len) {
                    self.flow_no_arrow_at[self.flow_no_arrow_at_len] = valid_starts[0];
                    self.flow_no_arrow_at_len += 1;
                }

                const consequent_retry = try self.parseAssignmentExpression();
                _ = try self.expect(.colon);

                self.flow_no_arrow_at = original_no_arrow_at;
                self.flow_no_arrow_at_len = original_no_arrow_at_len;

                const alternate = try self.parseAssignmentExpression();
                const extra_start = try self.addExtra(@intFromEnum(consequent_retry));
                _ = try self.addExtra(@intFromEnum(alternate));
                return self.addNode(.{
                    .tag = .conditional_expr,
                    .main_token = q_token,
                    .data = .{ .binary = .{ .lhs = test_expr, .rhs = @enumFromInt(extra_start) } },
                });
            } else if (failed1 and valid_count > 1) {
                // Multiple valid arrows — ambiguous, report error
                self.errors.addError("Ambiguous expression: wrap the arrow functions in parentheses to disambiguate.", self.currentStart());
            }
            // Fall through to use consequent1 (either succeeded or reported error)
        }

        // Parse succeeded (reached `:`) — use consequent1
        _ = try self.expect(.colon);

        self.flow_no_arrow_at = original_no_arrow_at;
        self.flow_no_arrow_at_len = original_no_arrow_at_len;

        const alternate = try self.parseAssignmentExpression();
        const extra_start = try self.addExtra(@intFromEnum(consequent1));
        _ = try self.addExtra(@intFromEnum(alternate));
        return self.addNode(.{
            .tag = .conditional_expr,
            .main_token = q_token,
            .data = .{ .binary = .{ .lhs = test_expr, .rhs = @enumFromInt(extra_start) } },
        });
    }

    /// Collect source positions and node indices of arrow function expressions that have
    /// return types but no type parameters (and whose body is not a block statement).
    /// These are the "ambiguous" arrows that could be either arrow functions or
    /// parenthesized expressions with type annotations.
    fn collectArrowNodes(self: *const Parser, node: NodeIndex, nodes: *[8]NodeIndex, starts: *[8]u32, count: *u8) void {
        if (node == .none) return;
        const idx = @intFromEnum(node);
        const tag = self.nodes.items(.tag)[idx];
        if (tag == .arrow_function_expr) {
            const body_idx = self.getArrowBody(node);
            const body_is_block = body_idx != .none and self.nodes.items(.tag)[@intFromEnum(body_idx)] == .block_statement;
            if (!body_is_block) {
                // Check if it has return type but no type parameters
                const has_return_type = hasRecordedNodeIndexValue(self.return_type_records.items, node);
                const has_type_params = hasRecordedNodeIndexValue(self.type_parameter_records.items, node);
                if (has_return_type and !has_type_params) {
                    if (count.* < starts.len) {
                        nodes[count.*] = node;
                        starts[count.*] = self.nodeStartPos(node);
                        count.* += 1;
                    }
                }
                // Recurse into body
                self.collectArrowNodes(body_idx, nodes, starts, count);
            }
        } else if (tag == .conditional_expr) {
            // Recurse into consequent and alternate
            const data = self.nodes.items(.data)[idx];
            const extra_idx = @intFromEnum(data.binary.rhs);
            const consequent: NodeIndex = @enumFromInt(self.extra_data.items[extra_idx]);
            const alternate: NodeIndex = @enumFromInt(self.extra_data.items[extra_idx + 1]);
            self.collectArrowNodes(consequent, nodes, starts, count);
            self.collectArrowNodes(alternate, nodes, starts, count);
        }
    }

    /// Check if a node is a valid binding pattern (can be converted to a pattern).
    /// Used for Flow ternary arrow disambiguation.
    fn isAssignableNode(self: *const Parser, node: NodeIndex) bool {
        if (node == .none) return true;
        const tag = self.nodes.items(.tag)[@intFromEnum(node)];
        return switch (tag) {
            .identifier => true,
            .array_pattern, .object_pattern => true,
            .assignment_pattern => blk: {
                // Only simple assignment (=) is a valid pattern; compound (+=) has been
                // converted with an error and should be treated as invalid for Flow
                // ternary arrow disambiguation.
                const mt = self.nodes.items(.main_token)[@intFromEnum(node)];
                break :blk self.token_tags[@intFromEnum(mt)] == .equal;
            },
            .rest_element, .spread_element => true,
            .parenthesized_expr => blk: {
                // Parenthesized identifier is assignable
                const inner = self.nodes.items(.data)[@intFromEnum(node)].unary;
                break :blk self.isAssignableNode(inner);
            },
            .flow_type_cast_expression => blk: {
                // TypeCastExpression with an assignable expression
                const expr = self.nodes.items(.data)[@intFromEnum(node)].binary.lhs;
                break :blk self.isAssignableNode(expr);
            },
            // Only simple assignment (b = c) is assignable as a default parameter
            .assignment_expr => blk: {
                const mt = self.nodes.items(.main_token)[@intFromEnum(node)];
                if (self.token_tags[@intFromEnum(mt)] != .equal) break :blk false;
                const data = self.nodes.items(.data)[@intFromEnum(node)];
                break :blk self.isAssignableNode(data.binary.lhs);
            },
            else => false,
        };
    }

    /// Check if an arrow function's parameters are all valid (assignable).
    fn isArrowAllParamsValid(self: *const Parser, arrow: NodeIndex) bool {
        const data = self.nodes.items(.data)[@intFromEnum(arrow)];
        const extra_start = @intFromEnum(data.extra);
        const third_val = self.extra_data.items[extra_start + 2];
        if (third_val <= 1) {
            // Simple arrow: [param, body, param_count]
            const param: NodeIndex = @enumFromInt(self.extra_data.items[extra_start]);
            return self.isAssignableNode(param);
        }
        // Typed arrow: [range_start, range_end, body]
        const range_start = self.extra_data.items[extra_start];
        const range_end = self.extra_data.items[extra_start + 1];
        var i = range_start;
        while (i < range_end) : (i += 1) {
            const param: NodeIndex = @enumFromInt(self.extra_data.items[i]);
            if (!self.isAssignableNode(param)) return false;
        }
        return true;
    }

    /// Get the body of an arrow function from its extra data.
    fn getArrowBody(self: *const Parser, node: NodeIndex) NodeIndex {
        const data = self.nodes.items(.data)[@intFromEnum(node)];
        const extra_start = @intFromEnum(data.extra);
        // Arrow function extra data layout:
        // For typed arrows: [param_range_start, param_range_end, body]
        // For simple (single-param) arrows: [param, body, param_count]
        // Distinguish by checking the third value (param_count for simple, body node for typed)
        const third_val = self.extra_data.items[extra_start + 2];
        if (third_val <= 1) {
            // Simple arrow: [param, body, param_count]
            return @enumFromInt(self.extra_data.items[extra_start + 1]);
        }
        // Typed arrow: [range_start, range_end, body]
        return @enumFromInt(third_val);
    }

    /// Report an error if a logical expression operand mixes ?? with ||/&&.
    fn checkNullishMixing(self: *Parser, operand: NodeIndex, current_prec: Precedence, op_token: TokenIndex) void {
        if (self.nodes.items(.tag)[@intFromEnum(operand)] != .logical_expr) return;
        const operand_main = self.nodes.items(.main_token)[@intFromEnum(operand)];
        const operand_op = self.token_tags[@intFromEnum(operand_main)];
        const is_operand_nullish = (operand_op == .question_question);
        const is_current_nullish = (current_prec == .nullish_coalescing);
        if (is_operand_nullish != is_current_nullish) {
            self.errors.addError("nullish coalescing operator requires parens when mixing with logical operators", self.token_starts[@intFromEnum(op_token)]);
        }
    }

    fn parsePrefixExpression(self: *Parser) Error!NodeIndex {
        switch (self.currentTag()) {
            .percent => {
                // Placeholder: %%name%%
                if (self.opts.enable_placeholders and self.lookAhead(1) == .percent) {
                    return self.parsePlaceholder("Expression");
                }
                // Pipeline topic reference: %
                if (self.opts.enable_pipeline_operator and
                    self.opts.pipeline_proposal == .hack and
                    self.opts.pipeline_topic_token == .percent)
                {
                    const tok = self.advance();
                    return self.addNode(.{ .tag = .topic_reference, .main_token = tok, .data = .{ .none = {} } });
                }
                if (!self.enable_v8_intrinsic) {
                    self.errors.addError("Unexpected token", self.currentStart());
                    return error.ParseError;
                }
                return self.parseV8IntrinsicIdentifier();
            },
            .percent_equal => {
                // Pipeline topic reference split: `%==` or `%===` was lexed as `%=` + `=` or `%=` + `==`.
                // Split `%=` into `%` (topic) + `=` (pending for the next operator).
                if (self.opts.enable_pipeline_operator and
                    self.opts.pipeline_proposal == .hack and
                    self.opts.pipeline_topic_token == .percent)
                {
                    const tok = self.advance();
                    self.pending_equal = true;
                    // Override end position to cover only `%`, not `%=`
                    const topic_start = self.token_starts[@intFromEnum(tok)];
                    const node = try self.addNode(.{ .tag = .topic_reference, .main_token = tok, .data = .{ .none = {} } });
                    self.nodes.items(.end_offset)[@intFromEnum(node)] = topic_start + 1;
                    return node;
                }
                self.errors.addError("Unexpected token", self.currentStart());
                return error.ParseError;
            },
            .colon => {
                if (self.opts.enable_bind_operator and self.lookAhead(1) == .colon) {
                    const first_colon = self.advance();
                    _ = self.advance(); // second :
                    if (self.currentTag() == .kw_super or self.currentTag() == .kw_import) {
                        self.errors.addError("The right-hand side of binding can not be super or import.", self.currentStart());
                        return error.ParseError;
                    }
                    const right = try self.parsePrefixExpression();
                    if (self.currentTag() == .optional_chain) {
                        self.errors.addError("Binding should be performed on object property.", self.currentStart());
                        return error.ParseError;
                    }
                    return self.addNode(.{
                        .tag = .bind_expression,
                        .main_token = first_colon,
                        .data = .{ .binary = .{ .lhs = .none, .rhs = right } },
                    });
                }
                self.errors.addError("unexpected token", self.currentStart());
                return error.ParseError;
            },
            // Unary operators
            .bang, .tilde, .kw_typeof, .kw_void, .kw_delete => {
                // Discard binding: `void` as standalone expression in pattern context
                // (e.g., [void] = [], for ([void] of []), etc.)
                if (self.opts.enable_discard_binding and self.currentTag() == .kw_void) {
                    const next = self.lookAhead(1);
                    if (next == .r_bracket or next == .comma or next == .r_paren or
                        next == .r_brace or (next == .equal and self.in_possible_pattern))
                    {
                        const tok = self.advance();
                        const node = try self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
                        try self.async_arrow_flags.put(self.allocator, @intFromEnum(node), {});
                        return node;
                    }
                }
                const op_token = self.advance();
                const saved_no_arrow = self.no_arrow;
                self.no_arrow = true;
                // Unary operand at .unary prec so member access/calls bind tighter
                const operand = try self.parseExpressionPrec(.unary);
                self.no_arrow = saved_no_arrow;
                self.rejectArrowNode(operand);
                return self.addNode(.{
                    .tag = .unary_expr,
                    .main_token = op_token,
                    .data = .{ .unary = operand },
                });
            },
            // Unary +/-
            .plus, .minus => {
                const op_token = self.advance();
                const operand = try self.parseExpressionPrec(.unary);
                return self.addNode(.{
                    .tag = .unary_expr,
                    .main_token = op_token,
                    .data = .{ .unary = operand },
                });
            },
            // Prefix ++ and --
            .plus_plus, .minus_minus => {
                const op_token = self.advance();
                const operand = try self.parseExpressionPrec(.unary);
                return self.addNode(.{
                    .tag = .update_expr,
                    .main_token = op_token,
                    .data = .{ .unary = operand },
                });
            },
            // Literals
            .numeric => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .numeric_literal, .main_token = tok, .data = .{ .none = {} } });
            },
            .bigint => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .bigint_literal, .main_token = tok, .data = .{ .none = {} } });
            },
            .string => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .string_literal, .main_token = tok, .data = .{ .none = {} } });
            },
            .kw_true, .kw_false => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .boolean_literal, .main_token = tok, .data = .{ .none = {} } });
            },
            .kw_null => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .null_literal, .main_token = tok, .data = .{ .none = {} } });
            },
            .kw_this => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .this_expr, .main_token = tok, .data = .{ .none = {} } });
            },
            .kw_super => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .super_expr, .main_token = tok, .data = .{ .none = {} } });
            },
            .template_no_sub => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .template_literal, .main_token = tok, .data = .{ .none = {} } });
            },
            .template_head => {
                return self.parseTemplateLiteral();
            },
            .identifier => {
                // Check for escaped keywords in expression position
                if (self.resolvedEscapedKeyword()) |esc_kw| {
                    if (!escapedKeywordUsesIdentifierSemantics(esc_kw)) {
                        self.errors.addError("escape sequence in keyword", self.currentStart());
                        switch (esc_kw) {
                            .kw_null => {
                                const tok = self.advance();
                                return self.addNode(.{ .tag = .null_literal, .main_token = tok, .data = .{ .none = {} } });
                            },
                            .kw_true, .kw_false => {
                                const tok = self.advance();
                                return self.addNode(.{ .tag = .boolean_literal, .main_token = tok, .data = .{ .none = {} } });
                            },
                            .kw_new => return self.parseNewExpression(),
                            else => {},
                        }
                    }
                }
                // module { ... } — ModuleExpression (no newline between module and {)
                if (self.opts.enable_module_blocks and self.lookAhead(1) == .l_brace) {
                    const ident_text = self.tokenText(self.token_index);
                    if (std.mem.eql(u8, ident_text, "module") and !self.hasNewlineBetween(self.token_index, self.token_index + 1)) {
                        return self.parseModuleExpression();
                    }
                }
                // Check for arrow function: ident => ...
                if (!self.no_arrow and self.lookAhead(1) == .arrow) {
                    return self.parseArrowFunction();
                }
                const tok = self.advance();
                return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
            },
            .l_paren => {
                return self.parseParenOrArrow();
            },
            .l_bracket => {
                return self.parseArrayLiteral();
            },
            .l_brace => {
                return self.parseObjectLiteral();
            },
            .kw_function => {
                // function.sent MetaProperty — only valid in generator functions
                if (self.opts.enable_function_sent and self.lookAhead(1) == .dot) {
                    const next_tok_idx = self.token_index + 2;
                    if (next_tok_idx < self.token_tags.len) {
                        const next_tag = self.token_tags[next_tok_idx];
                        if (next_tag == .identifier and std.mem.eql(u8, self.tokenText(next_tok_idx), "sent")) {
                            if (!self.in_generator) {
                                // function.sent is only valid inside generator functions
                                self.errors.addError("Unexpected token, expected \"(\"", self.token_starts[self.token_index + 1]);
                                return error.ParseError;
                            }
                            const func_tok = self.advance(); // function
                            _ = self.advance(); // .
                            const prop_tok = self.advance(); // sent
                            const prop = try self.addNode(.{ .tag = .identifier, .main_token = prop_tok, .data = .{ .none = {} } });
                            return self.addNode(.{ .tag = .meta_property, .main_token = func_tok, .data = .{ .unary = prop } });
                        }
                    }
                }
                return self.parseFunctionExpression();
            },
            .kw_class => {
                return self.parseClassExpression();
            },
            .kw_new => {
                return self.parseNewExpression();
            },
            .kw_async => {
                return self.parseAsyncExprPrefix();
            },
            .kw_yield => {
                // In generator context, yield is handled by parseAssignmentExpression
                // (before entering the precedence climbing loop). If we reach here,
                // yield is an identifier (non-generator context or sub-expression).
                // Check for arrow function: yield => ...
                if (!self.in_generator and self.lookAhead(1) == .arrow) {
                    return self.parseArrowFunction();
                }
                const tok = self.advance();
                return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
            },
            .kw_await => {
                // In async context, parse as AwaitExpression
                if (self.in_async) {
                    return self.parseAwaitExpression();
                }
                // Outside async context, Babel still parses `await expr` as
                // AwaitExpression with an error diagnostic.
                if (self.looksLikeAwaitExpr()) {
                    return self.parseAwaitExpression();
                }
                const tok = self.advance();
                return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
            },
            .kw_throw => {
                if (!self.opts.enable_throw_expression and !self.enable_throw_expressions) {
                    self.errors.addError("This experimental syntax requires enabling the parser plugin: \"throwExpressions\".", self.currentStart());
                    return error.ParseError;
                }
                return self.parseThrowExpression();
            },
            .kw_do => {
                // do-expression: do { ... }
                if (self.opts.enable_do_expressions) {
                    const do_tok = self.advance();
                    const body = try self.parseBlockStatement();
                    return self.addNode(.{ .tag = .do_expression, .main_token = do_tok, .data = .{ .unary = body } });
                }
                self.errors.addError("Unexpected token", self.currentStart());
                return error.ParseError;
            },
            .caret => {
                // Pipeline topic reference: ^ or ^^
                if (self.opts.enable_pipeline_operator and
                    self.opts.pipeline_proposal == .hack)
                {
                    if (self.opts.pipeline_topic_token == .caret) {
                        const tok = self.advance();
                        return self.addNode(.{ .tag = .topic_reference, .main_token = tok, .data = .{ .none = {} } });
                    }
                    if (self.opts.pipeline_topic_token == .double_caret and self.lookAhead(1) == .caret) {
                        // Check for ambiguous ^^^ — a third ^ immediately before or after ^^
                        // Before: previous token was ^ (XOR) adjacent to this ^^
                        if (self.token_index > 0) {
                            const prev_idx = self.token_index - 1;
                            if (self.token_tags[prev_idx] == .caret and
                                self.token_ends[prev_idx] == self.token_starts[self.token_index])
                            {
                                self.errors.addError("Unexpected token", self.currentStart());
                            }
                        }
                        // After: next ^ after ^^ is adjacent
                        if (self.lookAhead(2) == .caret) {
                            const second_caret_idx = self.token_index + 1;
                            const third_caret_idx = self.token_index + 2;
                            if (second_caret_idx < self.token_tags.len and third_caret_idx < self.token_tags.len and
                                self.token_ends[second_caret_idx] == self.token_starts[third_caret_idx])
                            {
                                self.errors.addError("Unexpected token", self.currentStart());
                            }
                        }
                        const tok = self.advance();
                        _ = self.advance(); // consume second ^
                        return self.addNode(.{ .tag = .topic_reference, .main_token = tok, .data = .{ .none = {} } });
                    }
                    // Handle split: ^^= was lexed as ^ + ^= (caret + caret_equal)
                    // Split the ^= into ^ (second caret of topic) + = (pending)
                    if (self.opts.pipeline_topic_token == .double_caret and self.lookAhead(1) == .caret_equal) {
                        const tok = self.advance();
                        const second_caret = self.advance(); // consume ^= (split)
                        self.pending_equal = true;
                        // Override end position of topic to cover ^^ (start of first ^ to start of second ^ + 1)
                        const topic_end = self.token_starts[@intFromEnum(second_caret)] + 1;
                        const node = try self.addNode(.{ .tag = .topic_reference, .main_token = tok, .data = .{ .none = {} } });
                        self.nodes.items(.end_offset)[@intFromEnum(node)] = topic_end;
                        return node;
                    }
                }
                self.errors.addError("Unexpected token", self.currentStart());
                return error.ParseError;
            },
            .caret_equal => {
                // Pipeline topic reference split: `^==` or `^===` was lexed as `^=` + ...
                // Split `^=` into `^` (topic) + `=` (pending for the next operator).
                if (self.opts.enable_pipeline_operator and
                    self.opts.pipeline_proposal == .hack and
                    self.opts.pipeline_topic_token == .caret)
                {
                    const tok = self.advance();
                    self.pending_equal = true;
                    const topic_start = self.token_starts[@intFromEnum(tok)];
                    const node = try self.addNode(.{ .tag = .topic_reference, .main_token = tok, .data = .{ .none = {} } });
                    self.nodes.items(.end_offset)[@intFromEnum(node)] = topic_start + 1;
                    return node;
                }
                self.errors.addError("Unexpected token", self.currentStart());
                return error.ParseError;
            },
            // (@@  topic reference handled in the .invalid case below)
            .kw_import => {
                // import.meta or import()
                return self.parseImportExpression();
            },
            .ellipsis => {
                const tok = self.advance();
                const arg = try self.parseAssignmentExpression();
                return self.addNode(.{ .tag = .spread_element, .main_token = tok, .data = .{ .unary = arg } });
            },
            .hash => {
                // Pipeline topic reference: #
                if (self.opts.enable_pipeline_operator and
                    self.opts.pipeline_proposal == .hack and
                    self.opts.pipeline_topic_token == .hash)
                {
                    // Only if not followed by identifier (which would be private name)
                    const next = self.lookAhead(1);
                    if (next != .identifier and !next.isKeyword()) {
                        const tok = self.advance();
                        return self.addNode(.{ .tag = .topic_reference, .main_token = tok, .data = .{ .none = {} } });
                    }
                }
                // Private name: #identifier — used in `#x in obj` (private-in)
                const hash_tok = self.advance();
                const ident_tok = self.advance();
                const ident_node = try self.addNode(.{ .tag = .identifier, .main_token = ident_tok, .data = .{ .none = {} } });
                return self.addNode(.{ .tag = .private_name, .main_token = hash_tok, .data = .{ .unary = ident_node } });
            },
            .slash, .slash_equal => {
                // Regex literal - rescan from current position
                return self.parseRegexLiteral();
            },
            // Keywords that can be used as identifiers in expression context
            .kw_let, .kw_static, .kw_as, .kw_get, .kw_set, .kw_of, .kw_from => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
            },
            .less_than => {
                // JSX/TSX/TypeScript: `<` in prefix position
                if (self.language == .tsx) {
                    return self.parseTsxPrefixLessThan();
                } else if (self.language == .flow) {
                    return self.parseFlowPrefixLessThan();
                } else if (self.language == .jsx) {
                    const parser_jsx = @import("parser_jsx.zig");
                    return parser_jsx.parseJsxElement(self);
                } else if (self.language == .typescript) {
                    const parser_ts = @import("parser_ts.zig");
                    // Try generic arrow function first for patterns like `<const T>() => {}`
                    // or `<T extends U>() => {}` or `<T,>() => {}`
                    const next = self.lookAhead(1);
                    const try_generic = blk: {
                        if (next == .identifier or next == .kw_const or next == .kw_in) {
                            const after = self.lookAhead(2);
                            if (after == .comma or after == .kw_extends or after == .greater_than or after == .equal) break :blk true;
                            if (next == .kw_const or next == .kw_in) {
                                if (after == .identifier) break :blk true;
                            }
                            if (next == .identifier) {
                                const text = self.tokenText(self.token_index + 1);
                                if (std.mem.eql(u8, text, "out") or std.mem.eql(u8, text, "in")) {
                                    if (after == .identifier or after == .kw_const or after == .kw_in) break :blk true;
                                }
                            }
                        }
                        break :blk false;
                    };
                    if (try_generic) {
                        const state = self.saveState();
                        if (parser_ts.tryParseGenericArrowFunction(self)) |node| {
                            return node;
                        } else |_| {
                            self.restoreState(state);
                        }
                    }
                    return parser_ts.parseTsTypeAssertion(self);
                } else {
                    self.errors.addError("unexpected token", self.currentStart());
                    const tok = self.advance();
                    return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
                }
            },
            .invalid => {
                // Pipeline topic reference: @@ (two @ tokens)
                if (self.opts.enable_pipeline_operator and
                    self.opts.pipeline_proposal == .hack and
                    self.opts.pipeline_topic_token == .double_at)
                {
                    const start = self.currentStart();
                    if (start < self.source.len and self.source[start] == '@') {
                        // Only match @@ if the next token is also @ adjacent to this one
                        const next_idx = self.token_index + 1;
                        if (next_idx < self.token_tags.len and
                            self.token_tags[next_idx] == .invalid and
                            self.token_starts[next_idx] < self.source.len and
                            self.source[self.token_starts[next_idx]] == '@' and
                            self.token_ends[self.token_index] == self.token_starts[next_idx])
                        {
                            const tok = self.advance();
                            _ = self.advance(); // consume second @
                            return self.addNode(.{ .tag = .topic_reference, .main_token = tok, .data = .{ .none = {} } });
                        }
                        // Single @ — fall through to decorator handling
                    }
                }
                // Decorators before class expression: @dec class Foo { }
                if (self.opts.enable_decorators and self.isAtDecorator()) {
                    const dec_range = try self.parseDecorators();
                    if (self.currentTag() == .kw_class) {
                        const cls = try self.parseClassExpression();
                        if (dec_range) |dr| {
                            try self.decorators_map.put(self.allocator, @intFromEnum(cls), dr);
                            // Adjust start position to include decorators
                            const first_dec_idx2: NodeIndex = @enumFromInt(self.extra_data.items[dr.start]);
                            const first_dec_mt = self.nodes.items(.main_token)[@intFromEnum(first_dec_idx2)];
                            const first_dec_start = self.token_starts[@intFromEnum(first_dec_mt)];
                            try self.node_start_overrides.put(self.allocator, @intFromEnum(cls), first_dec_start);
                        }
                        return cls;
                    }
                    // Decorators without class — error recovery
                    self.errors.addError("Leading decorators must be attached to a class declaration.", self.currentStart());
                    return self.addNode(.{ .tag = .identifier, .main_token = @enumFromInt(self.token_index), .data = .{ .none = {} } });
                }
                self.errors.addError("invalid token", self.currentStart());
                const tok = self.advance();
                return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
            },
            .eof => {
                self.errors.addError("unexpected end of input", self.currentStart());
                return error.ParseError;
            },
            else => {
                if (self.currentTag().isKeyword()) {
                    const tok = self.advance();
                    return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
                }
                self.errors.addError("unexpected token", self.currentStart());
                const tok = self.advance();
                return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
            },
        }
    }

    // === Regex literal (rescan from slash) ===

    fn parseRegexLiteral(self: *Parser) Error!NodeIndex {
        // Rescan the source from the current slash token as a regex
        const start = self.currentStart();
        var pos = start + 1; // skip /
        // For /= at start, include the =
        if (self.currentTag() == .slash_equal) {
            // The token is /= but we want it as regex starting with /=
            // We need to parse as /=.../flags
        }

        // Scan regex body
        var in_class = false;
        var found_closing = false;
        while (pos < self.source.len) {
            const c = self.source[pos];
            if (c == '\\') {
                pos += 1; // skip backslash
                if (pos < self.source.len and self.source[pos] == '\n') break; // unterminated: /a\<newline>
                if (pos < self.source.len) pos += 1; // skip escaped char
                continue;
            }
            if (c == '[') {
                in_class = true;
                pos += 1;
                continue;
            }
            if (c == ']') {
                in_class = false;
                pos += 1;
                continue;
            }
            if (c == '/' and !in_class) {
                pos += 1; // skip closing /
                found_closing = true;
                break;
            }
            if (c == '\n') break; // unterminated
            pos += 1;
        }
        if (!found_closing) {
            self.errors.addError("unterminated regular expression", start);
        }
        // Scan flags (including \uXXXX unicode escapes in flags for error recovery)
        while (pos < self.source.len) {
            const fc = self.source[pos];
            if ((fc >= 'a' and fc <= 'z') or (fc >= 'A' and fc <= 'Z') or (fc >= '0' and fc <= '9') or fc == '_' or fc == '$') {
                pos += 1;
            } else if (fc == '\\') {
                // \uXXXX or \\ in flags — consume the escape
                if (pos + 1 < self.source.len) {
                    pos += 1; // skip backslash
                    if (self.source[pos] == 'u') {
                        pos += 1;
                        var j: u32 = 0;
                        while (j < 4 and pos < self.source.len and std.ascii.isHex(self.source[pos])) : (j += 1) {
                            pos += 1;
                        }
                    } else {
                        pos += 1;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        // Create a synthetic token for the regex
        // We'll modify the current token's end and tag
        const tok_idx = self.token_index;
        // Advance past any tokens the regex spans
        while (self.token_index < self.token_tags.len and self.token_starts[self.token_index] < pos) {
            self.token_index += 1;
        }
        // Use the original slash token index as main_token
        const main_tok: TokenIndex = @enumFromInt(tok_idx);
        const node = try self.addNode(.{
            .tag = .regex_literal,
            .main_token = main_tok,
            .data = .{ .none = {} },
        });
        // Override end_offset to the actual regex end
        self.nodes.items(.end_offset)[@intFromEnum(node)] = pos;
        return node;
    }

    fn parseV8IntrinsicIdentifier(self: *Parser) Error!NodeIndex {
        const percent_start = self.currentStart();
        const percent_token = self.advance();
        const ident_token = if (self.currentTag() == .identifier or self.currentTag().isKeyword())
            self.advance()
        else {
            self.errors.addError("Unexpected token", percent_start);
            return error.ParseError;
        };

        // V8 intrinsic syntax is only valid as callee in direct call/new forms,
        // so `%Ident` must be followed immediately by `(`.
        if (self.currentTag() != .l_paren) {
            self.errors.addError("Unexpected token", percent_start);
            return error.ParseError;
        }

        const node = try self.addNode(.{
            .tag = .v8_intrinsic_identifier,
            .main_token = ident_token,
            .data = .{ .none = {} },
        });
        // Include leading '%' in node range.
        self.nodes.items(.main_token)[@intFromEnum(node)] = percent_token;
        self.nodes.items(.end_offset)[@intFromEnum(node)] = self.token_ends[@intFromEnum(ident_token)];
        return node;
    }

    // === Call / Member / Optional Chain ===

    fn parseCallExpression(self: *Parser, callee: NodeIndex) Error!NodeIndex {
        return self.parseCallArgs(callee, .call_expr);
    }

    /// Shared logic for parsing call arguments `(args...)`.
    fn parseCallArgs(self: *Parser, callee: NodeIndex, tag: Node.Tag) Error!NodeIndex {
        const paren_token = self.advance(); // consume (
        // Allow `in` inside parentheses: `for (a(b in c) in d)` needs `in` inside (...)
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        if (self.currentTag() != .r_paren) {
            // Handle leading elision: (,...)
            if (self.currentTag() == .comma) {
                try self.scratch.append(self.allocator, .none);
            } else if (self.opts.enable_partial_application and self.currentTag() == .question and self.lookAhead(1) != .dot) {
                // Partial application: ? as ArgumentPlaceholder
                const q_tok = self.advance();
                const placeholder = try self.addNode(.{ .tag = .topic_reference, .main_token = q_tok, .data = .{ .none = {} } });
                try self.scratch.append(self.allocator, placeholder);
            } else {
                var first = try self.parseAssignmentOrSpread();
                // Flow typecast in call args (with error)
                if (self.isFlow() and self.currentTag() == .colon) {
                    self.errors.addError("The type cast expression is expected to be wrapped with parenthesis.", self.currentStart());
                    const flow_mc = @import("parser_flow.zig");
                    first = try flow_mc.parseFlowTypeCastExpression(self, first);
                }
                // TS typecast in call args (with error)
                if (self.isTypeScript() and self.currentTag() == .colon) {
                    self.errors.addError("Did not expect a type annotation here.", self.currentStart());
                    const ts_mc = @import("parser_ts.zig");
                    first = try ts_mc.parseTsTypeCastExpression(self, first);
                }
                try self.scratch.append(self.allocator, first);
            }
            while (self.eat(.comma) != null) {
                if (self.currentTag() == .r_paren) break;
                if (self.currentTag() == .comma) {
                    // Elision in arguments
                    try self.scratch.append(self.allocator, .none);
                    continue;
                }
                if (self.opts.enable_partial_application and self.currentTag() == .question and self.lookAhead(1) != .dot) {
                    const q_tok2 = self.advance();
                    const ph2 = try self.addNode(.{ .tag = .topic_reference, .main_token = q_tok2, .data = .{ .none = {} } });
                    try self.scratch.append(self.allocator, ph2);
                    continue;
                }
                var arg = try self.parseAssignmentOrSpread();
                // Flow typecast in call args (with error)
                if (self.isFlow() and self.currentTag() == .colon) {
                    self.errors.addError("The type cast expression is expected to be wrapped with parenthesis.", self.currentStart());
                    const flow_mc2 = @import("parser_flow.zig");
                    arg = try flow_mc2.parseFlowTypeCastExpression(self, arg);
                }
                // TS typecast in call args (with error)
                if (self.isTypeScript() and self.currentTag() == .colon) {
                    self.errors.addError("Did not expect a type annotation here.", self.currentStart());
                    const ts_mc2 = @import("parser_ts.zig");
                    arg = try ts_mc2.parseTsTypeCastExpression(self, arg);
                }
                try self.scratch.append(self.allocator, arg);
            }
        }
        _ = try self.expect(.r_paren);

        const args = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(args);
        const extra_start = try self.addExtra(@intFromEnum(callee));
        _ = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);

        return self.addNode(.{
            .tag = tag,
            .main_token = paren_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    pub fn parseAssignmentOrSpread(self: *Parser) Error!NodeIndex {
        if (self.currentTag() == .ellipsis) {
            const tok = self.advance();
            if (self.currentTag() == .ellipsis) {
                self.errors.addError("Unexpected token", self.currentStart());
            }
            const arg = try self.parseAssignmentExpression();
            return self.addNode(.{ .tag = .spread_element, .main_token = tok, .data = .{ .unary = arg } });
        }
        return self.parseAssignmentExpression();
    }

    fn parseMemberExpression(self: *Parser, object: NodeIndex) Error!NodeIndex {
        return self.parseDotMember(object, .member_expr);
    }

    /// Shared logic for `.property` / `.#private` member access.
    /// `tag` is `.member_expr` normally, or `.optional_chain_expr` inside an optional chain.
    fn parseDotMember(self: *Parser, object: NodeIndex, tag: Node.Tag) Error!NodeIndex {
        const dot_token = self.advance(); // consume .
        if (self.currentTag() == .hash) {
            _ = self.advance(); // consume #
            const name_token = if (self.currentTag() == .identifier or self.currentTag().isKeyword())
                self.advance()
            else
                try self.expect(.identifier);
            return self.addNode(.{
                .tag = tag,
                .main_token = dot_token,
                .data = .{ .binary = .{ .lhs = object, .rhs = @enumFromInt(@intFromEnum(name_token)) } },
            });
        }
        const prop_token = if (self.currentTag() == .identifier or self.currentTag().isKeyword())
            self.advance()
        else
            try self.expect(.identifier);
        return self.addNode(.{
            .tag = tag,
            .main_token = dot_token,
            .data = .{ .binary = .{ .lhs = object, .rhs = @enumFromInt(@intFromEnum(prop_token)) } },
        });
    }

    fn parseComputedMemberExpression(self: *Parser, object: NodeIndex) Error!NodeIndex {
        return self.parseBracketMember(object, .computed_member_expr);
    }

    /// Shared logic for `[expr]` computed member access.
    fn parseBracketMember(self: *Parser, object: NodeIndex, tag: Node.Tag) Error!NodeIndex {
        const bracket_token = self.advance(); // consume [
        // Allow `in` inside brackets: `for (a[b in c] in d)` needs `in` inside [...]
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        const prop = try self.parseExpression();
        _ = try self.expect(.r_bracket);
        return self.addNode(.{
            .tag = tag,
            .main_token = bracket_token,
            .data = .{ .binary = .{ .lhs = object, .rhs = prop } },
        });
    }

    fn parseOptionalChainExpression(self: *Parser, object: NodeIndex) Error!NodeIndex {
        const chain_token = self.advance(); // consume ?.
        // ?. can be followed by <TypeArgs>(args), identifier, [, or (
        // Handle optional call with type arguments: f?.<T>(args)
        if ((self.isTypeScript() or (self.isFlow() and self.flow_pragma)) and self.currentTag() == .less_than) {
            const saved_token_index = self.token_index;
            const saved_nodes_len = self.nodes.len;
            const saved_extra_len = self.extra_data.items.len;
            const saved_scratch_len = self.scratch.items.len;
            const saved_errors_len = self.errors.items.items.len;
            const saved_pending_less_than = self.pending_less_than;
            const type_args = if (self.isTypeScript()) blk_ts: {
                const parser_ts = @import("parser_ts.zig");
                break :blk_ts parser_ts.parseTsTypeParameterInstantiation(self) catch |err| switch (err) {
                    error.ParseError => blk: {
                        self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
                        self.pending_less_than = saved_pending_less_than;
                        break :blk NodeIndex.none;
                    },
                    else => return err,
                };
            } else blk_flow: {
                const flow_mod = @import("parser_flow.zig");
                break :blk_flow flow_mod.parseFlowTypeParameterInstantiation(self) catch |err| switch (err) {
                    error.ParseError => blk: {
                        self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
                        self.pending_less_than = saved_pending_less_than;
                        break :blk NodeIndex.none;
                    },
                    else => return err,
                };
            };
            if (type_args != .none) {
                if (self.currentTag() == .l_paren) {
                    // optional call with type args: a?.<T>(args)
                    const call_node = try self.parseCallArgs(object, .optional_call_expr);
                    // Override main_token to `?.` so isDirectOptional detects it correctly
                    self.nodes.items(.main_token)[@intFromEnum(call_node)] = chain_token;
                    try self.putTypeParameters(call_node, type_args);
                    return call_node;
                }
                // Rollback if not followed by (
                self.rollbackSpeculativeState(saved_token_index, saved_nodes_len, saved_extra_len, saved_scratch_len, saved_errors_len);
                self.pending_less_than = saved_pending_less_than;
            }
        }
        if (self.currentTag() == .l_paren) {
            // optional call: a?.() — reuse parseCallArgs for consistent typecast handling
            const call_node = try self.parseCallArgs(object, .optional_call_expr);
            // Override main_token to `?.` so isDirectOptional detects it correctly
            self.nodes.items(.main_token)[@intFromEnum(call_node)] = chain_token;
            return call_node;
        }
        if (self.currentTag() == .l_bracket) {
            // optional computed member: a?.[b]
            _ = self.advance(); // [
            const prop = try self.parseExpression();
            _ = try self.expect(.r_bracket);
            return self.addNode(.{
                .tag = .optional_computed_member_expr,
                .main_token = chain_token,
                .data = .{ .binary = .{ .lhs = object, .rhs = prop } },
            });
        }
        // optional private member: a?.#x
        if (self.currentTag() == .hash) {
            _ = self.advance(); // skip #
            const name_token = if (self.currentTag() == .identifier or self.currentTag().isKeyword())
                self.advance()
            else
                try self.expect(.identifier);
            // Store the identifier token; the serializer detects private via preceding # token
            return self.addNode(.{
                .tag = .optional_chain_expr,
                .main_token = chain_token,
                .data = .{ .binary = .{ .lhs = object, .rhs = @enumFromInt(@intFromEnum(name_token)) } },
            });
        }
        // optional member: a?.b — property can be identifier or keyword
        const prop_token = if (self.currentTag() == .identifier or self.currentTag().isKeyword())
            self.advance()
        else
            try self.expect(.identifier);
        return self.addNode(.{
            .tag = .optional_chain_expr,
            .main_token = chain_token,
            .data = .{ .binary = .{ .lhs = object, .rhs = @enumFromInt(@intFromEnum(prop_token)) } },
        });
    }

    /// Check if a node is part of an optional chain (for propagation).
    fn isOptionalChainNode(self: *Parser, node: NodeIndex) bool {
        if (node == .none) return false;
        const tag = self.nodes.items(.tag)[@intFromEnum(node)];
        if (tag == .optional_chain_expr or tag == .optional_computed_member_expr or tag == .optional_call_expr)
            return true;
        // TSInstantiationExpression propagates optional chain from its inner expression
        if (tag == .ts_instantiation_expression) {
            const inner = self.nodes.items(.data)[@intFromEnum(node)].binary.lhs;
            return self.isOptionalChainNode(inner);
        }
        return false;
    }

    /// Chain-propagated `.property` — reuses parseDotMember with optional_chain_expr tag.
    fn parseOptionalMemberInChain(self: *Parser, object: NodeIndex) Error!NodeIndex {
        return self.parseDotMember(object, .optional_chain_expr);
    }

    /// Chain-propagated `[expr]` — reuses parseBracketMember with optional tag.
    fn parseOptionalComputedInChain(self: *Parser, object: NodeIndex) Error!NodeIndex {
        return self.parseBracketMember(object, .optional_computed_member_expr);
    }

    /// Chain-propagated `(args)` — reuses parseCallArgs with optional tag.
    fn parseOptionalCallInChain(self: *Parser, callee: NodeIndex) Error!NodeIndex {
        return self.parseCallArgs(callee, .optional_call_expr);
    }

    fn parseTaggedTemplate(self: *Parser, tag_expr: NodeIndex) Error!NodeIndex {
        const template = if (self.currentTag() == .template_no_sub) blk: {
            // Simple template with no substitutions
            const tok = self.advance();
            break :blk try self.addNode(.{ .tag = .template_literal, .main_token = tok, .data = .{ .none = {} } });
        } else try self.parseTemplateLiteral();
        const extra_idx = try self.addExtra(@intFromEnum(tag_expr));
        _ = try self.addExtra(@intFromEnum(template));
        return self.addNode(.{
            .tag = .tagged_template_expr,
            .main_token = self.nodes.items(.main_token)[@intFromEnum(tag_expr)],
            .data = .{ .extra = @enumFromInt(extra_idx) },
        });
    }

    fn parseTemplateLiteral(self: *Parser) Error!NodeIndex {
        const head_token = self.advance(); // template_head
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        // We collect expressions and template tokens interleaved in scratch.
        // We'll use a second scratch region for template tokens.
        // First collect expressions, then we'll store template tokens after.

        // Track template part tokens (head, middle..., tail)
        var template_tokens: std.ArrayList(u32) = .empty;
        defer template_tokens.deinit(self.allocator);
        try template_tokens.append(self.allocator, @intFromEnum(head_token)); // head

        // Parse expressions between template parts
        while (true) {
            var expr = try self.parseExpression();
            // TypeScript: when inside a TS function type parameter binding's default value,
            // template expressions that are literals should be wrapped in TSLiteralType.
            // This matches Babel's behavior where `type F = ({ x = `${0}` }) => {}`
            // wraps the `0` as TSLiteralType { literal: NumericLiteral }.
            if (self.ts_in_type_params and self.isTypeScript()) {
                const expr_tag = self.nodes.items(.tag)[@intFromEnum(expr)];
                if (expr_tag == .numeric_literal or expr_tag == .string_literal or expr_tag == .boolean_literal) {
                    expr = try self.addNode(.{
                        .tag = .ts_literal_type,
                        .main_token = self.nodes.items(.main_token)[@intFromEnum(expr)],
                        .data = .{ .unary = expr },
                    });
                }
            }
            try self.scratch.append(self.allocator, expr);
            // The lexer replaces '}' with template_middle/template_tail in template context
            if (self.currentTag() == .template_tail) {
                const tail_tok = self.advance();
                try template_tokens.append(self.allocator, @intFromEnum(tail_tok));
                break;
            }
            if (self.currentTag() == .template_middle) {
                const mid_tok = self.advance();
                try template_tokens.append(self.allocator, @intFromEnum(mid_tok));
                continue;
            }
            // If we get something unexpected (e.g. unclosed template expression), report error
            self.errors.addError("Unexpected token, expected \"}\"", self.currentStart());
            break;
        }

        const exprs = self.scratch.items[scratch_start..];
        const num_expressions: u32 = @intCast(exprs.len);

        // Extra data layout: [num_expressions, expr1, expr2, ..., head_tok, mid_tok1, ..., tail_tok]
        const extra_start = try self.addExtra(num_expressions);
        for (exprs) |expr| {
            _ = try self.addExtra(@intFromEnum(expr));
        }
        for (template_tokens.items) |tok| {
            _ = try self.addExtra(tok);
        }

        return self.addNode(.{
            .tag = .template_literal,
            .main_token = head_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    // === Arrow functions ===

    fn parseArrowFunction(self: *Parser) Error!NodeIndex {
        // Single param: x => body
        const param_token = self.advance(); // identifier
        // Create the identifier node now so its end_offset captures just the identifier,
        // not the '=>' token that follows.
        const param = try self.addNode(.{ .tag = .identifier, .main_token = param_token, .data = .{ .none = {} } });
        _ = try self.expect(.arrow);

        // Arrow functions are never generators; reset in_generator for the body.
        const saved_gen = self.in_generator;
        self.in_generator = false;
        defer self.in_generator = saved_gen;

        const body = try self.parseArrowBody();

        const extra_start = try self.addExtra(@intFromEnum(param));
        _ = try self.addExtra(@intFromEnum(body));
        _ = try self.addExtra(1); // param count

        return self.addNode(.{
            .tag = .arrow_function_expr,
            .main_token = param_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    /// Speculatively try parsing typed arrow function: (x: T, y: U): R => body
    /// Returns the arrow function node if successful, null otherwise.
    /// Caller must have already consumed '(' and self.token_index is at first param.
    /// `outer_in_cond` is the caller's `in_conditional_consequent` flag value
    /// (from before entering parens); used for the return type annotation check after `)`.
    fn tryParseTypedArrowFunction(self: *Parser, paren_token: TokenIndex, outer_no_in: bool) ?NodeIndex {
        const save = self.saveState();
        const deferred = self.beginDeferredParamMetadata();

        // Try to parse parameters with type annotations, return type, and =>
        const result = self.parseTypedArrowInner(paren_token, outer_no_in) catch {
            self.restoreState(save);
            return null;
        };

        self.commitDeferredParamMetadata(deferred) catch {
            self.restoreState(save);
            return null;
        };
        return result;
    }

    fn parseTypedArrowInner(self: *Parser, paren_token: TokenIndex, outer_no_in: bool) Error!NodeIndex {
        const flow_mod = @import("parser_flow.zig");
        const scratch_start = self.scratch.items.len;

        // Parse parameter list with type annotations
        while (self.currentTag() != .r_paren and self.currentTag() != .eof) {
            // Rest parameter
            if (self.currentTag() == .ellipsis) {
                const rest_token = self.advance();
                const elem = try self.parseBindingElement();
                const rest_node = try self.addNode(.{ .tag = .rest_element, .main_token = rest_token, .data = .{ .unary = elem } });
                try self.moveParamTypeAnnotationToRest(elem, rest_node);
                try self.moveOptionalParamToRest(elem, rest_node);
                try self.scratch.append(self.allocator, rest_node);
                break;
            }
            // Parse binding element (identifier, pattern, etc.)
            const param = try self.parseBindingElement();
            try self.scratch.append(self.allocator, param);

            if (self.currentTag() == .comma) {
                _ = self.advance();
            } else if (self.currentTag() != .r_paren) {
                // Not a comma or closing paren — this isn't a valid arrow param list
                return error.ParseError;
            }
        }
        _ = try self.expect(.r_paren);

        // Optional return type annotation and/or Flow predicate
        var ret_type: NodeIndex = .none;
        var flow_predicate: NodeIndex = .none;
        if (self.currentTag() == .colon) {
            if (self.isFlow()) {
                // Check if the return "type" is actually a predicate: `: %checks`
                if (self.lookAhead(1) == .percent) {
                    _ = self.advance(); // consume ':'
                    flow_predicate = try flow_mod.parseFlowPredicate(self);
                } else {
                    ret_type = try flow_mod.parseFlowArrowReturnTypeAnnotation(self);
                    // Check for predicate after return type
                    if (self.currentTag() == .percent) {
                        flow_predicate = try flow_mod.parseFlowPredicate(self);
                    }
                }
            } else if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                ret_type = try parser_ts.parseTsReturnTypeAnnotation(self);
            }
        }

        // Must see => (possibly with newline check relaxed since return type bridges the gap)
        // Handle split `*=` + `>` → virtual `=>`
        if (self.currentTag() != .arrow) {
            if (self.pending_equal and self.currentTag() == .greater_than) {
                self.pending_equal = false;
                _ = self.advance(); // >
            } else {
                return error.ParseError;
            }
        } else {
            _ = self.advance(); // =>
        }

        // Arrow functions are never generators
        const saved_gen = self.in_generator;
        self.in_generator = false;
        defer self.in_generator = saved_gen;

        const saved_async = self.in_async;
        if (self.pending_async_arrow) {
            self.in_async = true;
            self.pending_async_arrow = false;
        }

        const body = try self.parseArrowBodyWithNoIn(outer_no_in);
        self.in_async = saved_async;

        const params = self.scratch.items[scratch_start..];

        // Flow: convert `this` identifier params to ThisExpression in arrow functions
        if (self.isFlow()) {
            for (params) |param_idx| {
                const pi = @intFromEnum(param_idx);
                if (self.nodes.items(.tag)[pi] == .identifier) {
                    const mt = self.nodes.items(.main_token)[pi];
                    if (self.token_tags[@intFromEnum(mt)] == .kw_this) {
                        self.nodes.items(.tag)[pi] = .this_expr;
                    }
                }
            }
        }

        const param_range = try self.addExtraRange(params);
        self.scratch.shrinkRetainingCapacity(scratch_start);
        const extra_start = try self.addExtra(param_range.start);
        _ = try self.addExtra(param_range.end);
        _ = try self.addExtra(@intFromEnum(body));

        const arrow_node = try self.addNode(.{
            .tag = .arrow_function_expr,
            .main_token = paren_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        if (ret_type != .none) {
            try self.putReturnType(arrow_node, ret_type);
        }
        if (flow_predicate != .none) {
            try self.flow_predicates.put(self.allocator, @intFromEnum(arrow_node), flow_predicate);
        }
        return arrow_node;
    }

    pub fn parseParenOrArrow(self: *Parser) Error!NodeIndex {
        // Could be: (expr), (a, b) => ..., or ()=>...
        // Look ahead to determine
        const paren_start_pos = self.currentStart();
        const paren_token = self.advance(); // consume (
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;

        // Flow: if this paren position is in flow_no_arrow_at, suppress all arrow
        // function parsing (treat as parenthesized expression only)
        const flow_suppress_arrow = self.isFlow() and self.isFlowNoArrowAt(paren_start_pos);

        // Save and reset in_conditional_consequent inside parens.
        // Inside parens, `:` can be a type annotation, not a ternary separator.
        // The saved value is passed to tryParseTypedArrowFunction for the
        // return type check AFTER `)`.
        const saved_in_cond_conseq = self.in_conditional_consequent;
        self.in_conditional_consequent = false;
        defer self.in_conditional_consequent = saved_in_cond_conseq;

        // Empty parens: must be arrow
        if (self.currentTag() == .r_paren) {
            _ = self.advance(); // )

            // Flow/TS: return type annotation before =>
            var empty_ret_type: NodeIndex = .none;
            if ((self.isFlow() or self.isTypeScript()) and self.currentTag() == .colon) {
                if (self.isFlow()) {
                    const flow_mod2 = @import("parser_flow.zig");
                    empty_ret_type = try flow_mod2.parseFlowArrowReturnTypeAnnotation(self);
                } else {
                    const parser_ts2 = @import("parser_ts.zig");
                    empty_ret_type = try parser_ts2.parseTsReturnTypeAnnotation(self);
                }
            }

            // No LineTerminator allowed before =>
            if (self.currentTag() == .arrow and self.hasNewlineBefore()) {
                self.errors.addError("Unexpected token", self.currentStart());
                return error.ParseError;
            }
            // Handle split `*=` + `>` → virtual `=>`
            if (self.pending_equal and self.currentTag() == .greater_than) {
                self.pending_equal = false;
                _ = self.advance(); // >
            } else {
                _ = try self.expect(.arrow);
            }

            // Arrow functions are never generators.
            const saved_gen = self.in_generator;
            self.in_generator = false;
            defer self.in_generator = saved_gen;

            // For async arrows, enable in_async for the body only
            const saved_async = self.in_async;
            if (self.pending_async_arrow) {
                self.in_async = true;
                self.pending_async_arrow = false;
            }

            const body = try self.parseArrowBodyWithNoIn(saved_no_in);
            self.in_async = saved_async;
            const extra_start = try self.addExtra(@intFromEnum(@as(NodeIndex, .none)));
            _ = try self.addExtra(@intFromEnum(body));
            _ = try self.addExtra(0); // param count
            const empty_arrow = try self.addNode(.{
                .tag = .arrow_function_expr,
                .main_token = paren_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
            if (empty_ret_type != .none) {
                try self.putReturnType(empty_arrow, empty_ret_type);
            }
            return empty_arrow;
        }

        // Flow/TS: speculatively try parsing as typed arrow function parameters
        // (x: T, y: U): R => body
        if ((self.isFlow() or self.isTypeScript()) and !self.no_arrow and !flow_suppress_arrow) {
            const arrow_result = self.tryParseTypedArrowFunction(paren_token, saved_no_in);
            if (arrow_result) |result| return result;
        }

        // Parse first expression
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        // Reset fsharp pipeline body context inside parentheses —
        // |> inside (...) belongs to the inner expressions.
        // Restored before arrow body parsing if this turns out to be arrow params.
        const saved_fsharp_paren = self.in_fsharp_pipeline_body;
        self.in_fsharp_pipeline_body = false;

        // Discard binding: inside parens, `void = expr` may be arrow param with default
        const saved_pattern = self.in_possible_pattern;
        if (self.opts.enable_discard_binding) self.in_possible_pattern = true;
        defer self.in_possible_pattern = saved_pattern;

        var first = try self.parseAssignmentOrSpread();
        // Flow typecast: (expr: Type)
        if (self.isFlow() and self.currentTag() == .colon) {
            // Remove stale type annotation left by speculative arrow parsing
            _ = try self.removeTypeAnnotation(first);
            const flow_mod3 = @import("parser_flow.zig");
            first = try flow_mod3.parseFlowTypeCastExpression(self, first);
        }
        // TS typecast: (expr: Type) — produces TSTypeCastExpression with error
        if (self.isTypeScript() and self.currentTag() == .colon) {
            // Remove stale type annotation left by speculative arrow parsing
            _ = try self.removeTypeAnnotation(first);
            self.errors.addError("Did not expect a type annotation here.", self.currentStart());
            const ts_mod_cast = @import("parser_ts.zig");
            first = try ts_mod_cast.parseTsTypeCastExpression(self, first);
        }
        try self.scratch.append(self.allocator, first);

        // If comma follows, could be sequence or arrow params
        var had_trailing_comma = false;
        while (self.eat(.comma) != null) {
            if (self.currentTag() == .r_paren) {
                had_trailing_comma = true;
                break;
            }
            var next = try self.parseAssignmentOrSpread();
            // Flow typecast for subsequent items
            if (self.isFlow() and self.currentTag() == .colon) {
                _ = try self.removeTypeAnnotation(next);
                const flow_mod4 = @import("parser_flow.zig");
                next = try flow_mod4.parseFlowTypeCastExpression(self, next);
            }
            // TS typecast for subsequent items
            if (self.isTypeScript() and self.currentTag() == .colon) {
                self.errors.addError("Did not expect a type annotation here.", self.currentStart());
                const ts_mod_cast2 = @import("parser_ts.zig");
                next = try ts_mod_cast2.parseTsTypeCastExpression(self, next);
            }
            try self.scratch.append(self.allocator, next);
        }

        // Restore fsharp pipeline body context before closing paren and arrow detection.
        self.in_fsharp_pipeline_body = saved_fsharp_paren;

        _ = try self.expect(.r_paren);

        // Flow: after `)`, if `:` is next, speculatively try to parse return type + `=>`
        // This handles cases like `((foo)): string => {}` where `tryParseTypedArrowFunction`
        // couldn't handle the inner parenthesized parameter.
        if (self.isFlow() and self.currentTag() == .colon and !self.no_arrow and !flow_suppress_arrow) {
            const flow_arrow_state = self.saveState();
            const flow_mod_arrow = @import("parser_flow.zig");
            const saved_no_anon = self.flow_no_anon_function_type;
            self.flow_no_anon_function_type = true;
            const flow_ret_type = flow_mod_arrow.parseFlowTypeAnnotation(self) catch blk: {
                self.flow_no_anon_function_type = saved_no_anon;
                self.restoreState(flow_arrow_state);
                break :blk @as(NodeIndex, .none);
            };
            self.flow_no_anon_function_type = saved_no_anon;
            if (flow_ret_type != .none and self.currentTag() == .arrow and !self.hasNewlineBefore()) {
                _ = self.advance(); // consume =>

                const saved_gen_flow = self.in_generator;
                self.in_generator = false;

                const saved_async_flow = self.in_async;
                if (self.pending_async_arrow) {
                    self.in_async = true;
                    self.pending_async_arrow = false;
                }

                const flow_body = try self.parseArrowBodyWithNoIn(saved_no_in);
                self.in_async = saved_async_flow;
                self.in_generator = saved_gen_flow;

                // Convert expressions to patterns for arrow function parameters
                const flow_params = self.scratch.items[scratch_start..];
                for (flow_params) |param_idx| {
                    self.convertToPattern(param_idx);
                    self.validatePattern(param_idx);
                }
                const flow_param_range = try self.addExtraRange(flow_params);
                const flow_extra_start = try self.addExtra(flow_param_range.start);
                _ = try self.addExtra(flow_param_range.end);
                _ = try self.addExtra(@intFromEnum(flow_body));

                const flow_arrow_node = try self.addNode(.{
                    .tag = .arrow_function_expr,
                    .main_token = paren_token,
                    .data = .{ .extra = @enumFromInt(flow_extra_start) },
                });
                try self.putReturnType(flow_arrow_node, flow_ret_type);
                return flow_arrow_node;
            }
            // Not an arrow — rollback the type annotation parsing
            if (flow_ret_type != .none) {
                self.restoreState(flow_arrow_state);
            }
        }

        // Check for arrow — no LineTerminator allowed before =>
        if (self.currentTag() == .arrow and !self.hasNewlineBefore() and !flow_suppress_arrow) {
            _ = self.advance(); // consume =>

            // Arrow functions are never generators.
            const saved_gen = self.in_generator;
            self.in_generator = false;
            defer self.in_generator = saved_gen;

            // For async arrows, enable in_async for the body only
            const saved_async2 = self.in_async;
            if (self.pending_async_arrow) {
                self.in_async = true;
                self.pending_async_arrow = false;
            }

            const body = try self.parseArrowBodyWithNoIn(saved_no_in);
            self.in_async = saved_async2;

            // Convert expressions to patterns for arrow function parameters
            const params = self.scratch.items[scratch_start..];
            for (params) |param_idx| {
                self.convertToPattern(param_idx);
                self.validatePattern(param_idx);
            }
            const param_range = try self.addExtraRange(params);
            const extra_start = try self.addExtra(param_range.start);
            _ = try self.addExtra(param_range.end);
            _ = try self.addExtra(@intFromEnum(body));

            return self.addNode(.{
                .tag = .arrow_function_expr,
                .main_token = paren_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
        }

        // Not an arrow — parenthesized expression or sequence
        self.pending_async_arrow = false;
        const items = self.scratch.items[scratch_start..];

        // Trailing comma in parenthesized expression is only valid for arrow params
        if (had_trailing_comma) {
            self.errors.addError("Unexpected token", self.currentStart());
        }

        // Check for rest/spread elements — these are only valid in arrow params
        for (items) |item| {
            if (item != .none and self.nodes.items(.tag)[@intFromEnum(item)] == .spread_element) {
                self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(self.nodes.items(.main_token)[@intFromEnum(item)])]);
            }
        }

        if (items.len == 1) {
            // Parenthesized expression
            return self.addNode(.{
                .tag = .parenthesized_expr,
                .main_token = paren_token,
                .data = .{ .unary = items[0] },
            });
        }

        // Sequence expression — end at the last element, not the closing paren
        const range = try self.addExtraRange(items);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        // Record end_offset of last element (before `)`) for proper Babel-compatible positions
        const last_elem_end = self.nodes.items(.end_offset)[@intFromEnum(items[items.len - 1])];
        const seq_node = try self.addNode(.{
            .tag = .sequence_expr,
            .main_token = paren_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        // Fix: Babel's SequenceExpression inside parens ends before the `)`, not after.
        self.nodes.items(.end_offset)[@intFromEnum(seq_node)] = last_elem_end;
        // Wrap in parenthesized_expr so extra.parenthesized is emitted
        return self.addNode(.{
            .tag = .parenthesized_expr,
            .main_token = paren_token,
            .data = .{ .unary = seq_node },
        });
    }

    // === Array/Object Literals ===

    fn parseArrayLiteral(self: *Parser) Error!NodeIndex {
        const bracket_token = self.advance(); // [
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        // Reset fsharp pipeline body context inside array literals —
        // |> inside [...] belongs to the inner expressions.
        const saved_fsharp = self.in_fsharp_pipeline_body;
        self.in_fsharp_pipeline_body = false;
        defer self.in_fsharp_pipeline_body = saved_fsharp;
        // Discard binding: inside arrays, `void = expr` may be destructuring with default
        const saved_pattern_arr = self.in_possible_pattern;
        if (self.opts.enable_discard_binding) self.in_possible_pattern = true;
        defer self.in_possible_pattern = saved_pattern_arr;
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        while (self.currentTag() != .r_bracket and self.currentTag() != .eof) {
            if (self.currentTag() == .comma) {
                // Elision - add null placeholder
                try self.scratch.append(self.allocator, .none);
                _ = self.advance();
                continue;
            }
            var elem = try self.parseAssignmentOrSpread();
            // Flow typecast in array (with error)
            if (self.isFlow() and self.currentTag() == .colon) {
                self.errors.addError("The type cast expression is expected to be wrapped with parenthesis.", self.currentStart());
                const flow_ma = @import("parser_flow.zig");
                elem = try flow_ma.parseFlowTypeCastExpression(self, elem);
            }
            // TS typecast in array (with error)
            if (self.isTypeScript() and self.currentTag() == .colon) {
                self.errors.addError("Did not expect a type annotation here.", self.currentStart());
                const ts_ma = @import("parser_ts.zig");
                elem = try ts_ma.parseTsTypeCastExpression(self, elem);
            }
            try self.scratch.append(self.allocator, elem);
            if (self.currentTag() != .r_bracket) {
                _ = try self.expect(.comma);
            }
        }
        _ = try self.expect(.r_bracket);

        const elems = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(elems);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        return self.addNode(.{
            .tag = .array_expr,
            .main_token = bracket_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseObjectLiteral(self: *Parser) Error!NodeIndex {
        const brace_token = self.advance(); // {
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        // Reset fsharp pipeline body context inside object literals —
        // |> inside {...} belongs to the inner expressions.
        const saved_fsharp = self.in_fsharp_pipeline_body;
        self.in_fsharp_pipeline_body = false;
        defer self.in_fsharp_pipeline_body = saved_fsharp;
        // Discard binding: inside objects, `void = expr` may be destructuring with default
        const saved_pattern_obj = self.in_possible_pattern;
        if (self.opts.enable_discard_binding) self.in_possible_pattern = true;
        defer self.in_possible_pattern = saved_pattern_obj;
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
            // Parse decorators on object properties/methods
            var obj_prop_dec_range: ?@import("ast.zig").ExtraRange = null;
            if ((self.opts.enable_decorators or self.opts.decorators_legacy) and self.isAtDecorator()) {
                obj_prop_dec_range = try self.parseDecorators();
                // Decorators before spread elements are invalid
                if (self.currentTag() == .ellipsis) {
                    self.errors.addError("Unexpected token", self.currentStart());
                }
            }
            const prop = try self.parseObjectProperty();
            if (obj_prop_dec_range) |dr| {
                try self.decorators_map.put(self.allocator, @intFromEnum(prop), dr);
            }
            try self.scratch.append(self.allocator, prop);
            if (self.currentTag() != .r_brace) {
                _ = try self.expect(.comma);
            }
        }
        _ = try self.expect(.r_brace);

        const props = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(props);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        return self.addNode(.{
            .tag = .object_expr,
            .main_token = brace_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseObjectProperty(self: *Parser) Error!NodeIndex {
        const parser_ts = @import("parser_ts.zig");

        // Handle spread
        if (self.currentTag() == .ellipsis) {
            const tok = self.advance();
            const arg = try self.parseAssignmentExpression();
            return self.addNode(.{ .tag = .spread_element, .main_token = tok, .data = .{ .unary = arg } });
        }

        // Private names (#x) are not allowed in object literals
        if (self.currentTag() == .hash) {
            self.errors.addError("Unexpected private name.", self.currentStart());
            // Parse as private name for error recovery, producing correct AST
            const hash_tok = self.advance();
            const ident_tok = self.advance();
            const ident_node = try self.addNode(.{ .tag = .identifier, .main_token = ident_tok, .data = .{ .none = {} } });
            const priv_key = try self.addNode(.{ .tag = .private_name, .main_token = hash_tok, .data = .{ .unary = ident_node } });

            // Method shorthand: #x() { ... }
            if (self.currentTag() == .l_paren) {
                const params = try self.parseParameterList();
                const saved_func = self.in_function;
                self.in_function = true;
                defer self.in_function = saved_func;
                const body = try self.parseBlockStatement();
                var mflags: u32 = 0;
                if (self.in_generator) mflags |= 1;
                if (self.in_async) mflags |= 2;
                const mextra_start = try self.addExtra(@intFromEnum(priv_key));
                _ = try self.addExtra(params.start);
                _ = try self.addExtra(params.end);
                _ = try self.addExtra(@intFromEnum(body));
                _ = try self.addExtra(mflags);
                return self.addNode(.{
                    .tag = .method_definition,
                    .main_token = hash_tok,
                    .data = .{ .extra = @enumFromInt(mextra_start) },
                });
            }

            // key: value
            if (self.eat(.colon) != null) {
                var value = try self.parseAssignmentExpression();
                if (self.isTypeScript() and
                    (self.currentTag() == .kw_as or
                        self.identifierEquals(self.token_index, "as")))
                {
                    value = try parser_ts.parseTsAsExpression(self, value);
                }
                return self.addNode(.{
                    .tag = .property,
                    .main_token = hash_tok,
                    .data = .{ .binary = .{ .lhs = priv_key, .rhs = value } },
                });
            }

            // Shorthand (just #x)
            return self.addNode(.{
                .tag = .shorthand_property,
                .main_token = hash_tok,
                .data = .{ .unary = priv_key },
            });
        }

        // Handle get/set
        if ((self.currentTag() == .kw_get or self.currentTag() == .kw_set) and
            self.lookAhead(1) != .colon and self.lookAhead(1) != .l_paren and self.lookAhead(1) != .comma and self.lookAhead(1) != .r_brace and self.lookAhead(1) != .equal)
        {
            return self.parseGetterSetterProperty(0);
        }

        // Handle async methods — but not when async is a method/shorthand name
        if (self.currentTag() == .kw_async and self.lookAhead(1) != .l_paren and self.lookAhead(1) != .colon and self.lookAhead(1) != .comma and self.lookAhead(1) != .r_brace and self.lookAhead(1) != .equal and !self.hasNewlineAfterCurrent()) {
            return self.parseAsyncMethod();
        }

        // Handle generator methods
        if (self.currentTag() == .asterisk) {
            return self.parseGeneratorMethod();
        }

        // Handle computed property
        if (self.currentTag() == .l_bracket) {
            return self.parseComputedPropertyDef();
        }

        // Placeholder as property key: `%%key%%: value`
        if (self.isPlaceholder()) {
            const ph_start_token: TokenIndex = @enumFromInt(self.token_index);
            const ph_key = try self.parsePlaceholder("Identifier");
            if (self.eat(.colon) != null) {
                var value = try self.parseAssignmentExpression();
                if (self.isTypeScript() and
                    (self.currentTag() == .kw_as or
                        self.identifierEquals(self.token_index, "as")))
                {
                    value = try parser_ts.parseTsAsExpression(self, value);
                }
                return self.addNode(.{
                    .tag = .property,
                    .main_token = ph_start_token,
                    .data = .{ .binary = .{ .lhs = ph_key, .rhs = value } },
                });
            }
            return self.addNode(.{
                .tag = .shorthand_property,
                .main_token = ph_start_token,
                .data = .{ .unary = ph_key },
            });
        }

        // Regular property or shorthand
        const key_token = self.advance();
        const key = try self.addNode(.{
            .tag = keyNodeTag(self.token_tags[@intFromEnum(key_token)]),
            .main_token = key_token,
            .data = .{ .none = {} },
        });

        // Method shorthand: key() { ... } or key<T>() { ... }
        if (self.currentTag() == .l_paren or ((self.isFlow() or self.isTypeScript()) and self.currentTag() == .less_than)) {
            // Save and reset async/generator — regular methods are not async/generator
            const saved_async = self.in_async;
            const saved_gen = self.in_generator;
            self.in_async = false;
            self.in_generator = false;
            defer {
                self.in_async = saved_async;
                self.in_generator = saved_gen;
            }
            return self.parseMethodProperty(key_token, key);
        }

        // key: value
        if (self.eat(.colon) != null) {
            var value = try self.parseAssignmentExpression();
            if (self.isTypeScript() and
                (self.currentTag() == .kw_as or
                    self.identifierEquals(self.token_index, "as")))
            {
                value = try parser_ts.parseTsAsExpression(self, value);
            }
            return self.addNode(.{
                .tag = .property,
                .main_token = key_token,
                .data = .{ .binary = .{ .lhs = key, .rhs = value } },
            });
        }

        // Shorthand with default value for destructuring: { x = expr }
        // Babel represents this as ObjectProperty(shorthand=true, value=AssignmentPattern)
        if (self.eat(.equal) != null) {
            const def = try self.parseAssignmentExpression();
            const assign_pat = try self.addNode(.{
                .tag = .assignment_pattern,
                .main_token = key_token,
                .data = .{ .binary = .{ .lhs = key, .rhs = def } },
            });
            return self.addNode(.{
                .tag = .shorthand_property,
                .main_token = key_token,
                .data = .{ .unary = assign_pat },
            });
        }

        // Shorthand property: { x } is same as { x: x }
        // String and number literals cannot be shorthand properties
        const key_tag = self.token_tags[@intFromEnum(key_token)];
        if (key_tag == .string or key_tag == .numeric) {
            self.errors.addError("Unexpected token", self.currentStart());
        }
        return self.addNode(.{
            .tag = .shorthand_property,
            .main_token = key_token,
            .data = .{ .unary = key },
        });
    }

    fn parseGetterSetterProperty(self: *Parser, in_flags: u32) Error!NodeIndex {
        var flags = in_flags;
        const gs_token = self.advance(); // get or set
        const gs_start = self.token_starts[@intFromEnum(gs_token)];
        const tag: Node.Tag = if (self.token_tags[@intFromEnum(gs_token)] == .kw_get) .getter else .setter;

        // Check for generator after get/set — `get *name()` / `set *name()`
        if (self.currentTag() == .asterisk) {
            if (tag == .getter) {
                self.errors.addError("A getter cannot be a generator.", gs_start);
            } else {
                self.errors.addError("A setter cannot be a generator.", gs_start);
            }
            _ = self.advance(); // skip *
            flags |= 16; // bit 4 = generator
        }

        // Key can be identifier, string, number, computed, or private
        var key_token: TokenIndex = undefined;
        var computed_key: NodeIndex = .none;
        const is_private = self.currentTag() == .hash;
        if (is_private) {
            _ = self.advance(); // skip #
            key_token = self.advance();
            flags |= 4; // bit 2 = private
        } else if (self.currentTag() == .l_bracket) {
            key_token = self.advance(); // [
            computed_key = try self.parseAssignmentExpression();
            _ = try self.expect(.r_bracket);
            flags |= 8; // bit 3 = computed
        } else {
            key_token = self.advance();
        }

        // Parse params — accept any number for error tolerance
        _ = try self.expect(.l_paren);
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);
        while (self.currentTag() != .r_paren and self.currentTag() != .eof) {
            if ((self.isFlow() or self.isTypeScript()) and self.currentTag() == .kw_this) {
                const param = try self.parseThisParameter(scratch_start);
                try self.scratch.append(self.allocator, param);
                if (self.currentTag() == .comma) _ = self.advance();
                continue;
            }
            if (self.currentTag() == .ellipsis) {
                const rest_token = self.advance();
                const elem = try self.parseBindingElement();
                const flow_mod = @import("parser_flow.zig");
                flow_mod.tryParseFlowParamTypeAnnotation(self, elem) catch {};
                const rest_node = try self.addNode(.{ .tag = .rest_element, .main_token = rest_token, .data = .{ .unary = elem } });
                try self.scratch.append(self.allocator, rest_node);
                if (self.eat(.comma) != null) continue;
                break;
            }
            const p = try self.parseBindingElement();
            const flow_mod = @import("parser_flow.zig");
            flow_mod.tryParseFlowParamTypeAnnotation(self, p) catch {};
            try self.scratch.append(self.allocator, p);
            if (self.currentTag() != .r_paren) {
                _ = try self.expect(.comma);
            }
        }

        const param_count = self.scratch.items.len - scratch_start;
        const params = self.scratch.items[scratch_start..];
        const has_this_param = self.findThisParam(params) != null;
        const effective_param_count = param_count - (if (has_this_param) @as(usize, 1) else 0);
        var setter_value_is_rest = false;
        if (tag == .setter and effective_param_count == 1) {
            for (params) |param| {
                if (self.getThisParamInfo(param, 0) != null) continue;
                setter_value_is_rest = self.nodes.items(.tag)[@intFromEnum(param)] == .rest_element;
                break;
            }
        }

        // Validate accessor parameter count and kind
        if (tag == .getter and effective_param_count != 0) {
            self.errors.addError("A 'get' accessor must not have any formal parameters.", gs_start);
        }
        if (tag == .setter) {
            if (effective_param_count != 1) {
                self.errors.addError("A 'set' accessor must have exactly one formal parameter.", gs_start);
            } else if (setter_value_is_rest) {
                self.errors.addError("A 'set' accessor function argument must not be a rest parameter.", gs_start);
            }
        }

        const param_range = try self.addExtraRange(params);

        _ = try self.expect(.r_paren);

        // Return type annotation on getter/setter
        var gs_ret_type: NodeIndex = .none;
        if (self.currentTag() == .colon) {
            if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                gs_ret_type = try parser_ts.parseTsReturnTypeAnnotation(self);
            } else if (self.isFlow()) {
                const flow_mod = @import("parser_flow.zig");
                gs_ret_type = try flow_mod.parseFlowTypeAnnotation(self);
            }
        }

        // TypeScript: getter/setter without body (in declare class or overload)
        if (self.isTypeScript() and self.currentTag() != .l_brace) {
            if (self.currentTag() == .semicolon) _ = self.advance();
            const extra_start = try self.addExtra(param_range.start);
            _ = try self.addExtra(param_range.end);
            _ = try self.addExtra(@intFromEnum(NodeIndex.none)); // no body
            _ = try self.addExtra(flags);
            _ = try self.addExtra(@intFromEnum(computed_key));
            const gs_node = try self.addNode(.{
                .tag = tag,
                .main_token = key_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
            if (gs_ret_type != .none) {
                try self.putReturnType(gs_node, gs_ret_type);
            }
            return gs_node;
        }

        const body = try self.parseBlockStatement();

        const extra_start = try self.addExtra(param_range.start);
        _ = try self.addExtra(param_range.end);
        _ = try self.addExtra(@intFromEnum(body));
        _ = try self.addExtra(flags);
        _ = try self.addExtra(@intFromEnum(computed_key));

        const gs_node = try self.addNode(.{
            .tag = tag,
            .main_token = key_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        if (gs_ret_type != .none) {
            try self.putReturnType(gs_node, gs_ret_type);
        }
        return gs_node;
    }

    fn parseAsyncMethod(self: *Parser) Error!NodeIndex {
        const async_token = self.advance(); // async
        const is_generator = self.eat(.asterisk) != null;
        const key_token = self.advance(); // method name
        const key = try self.addNode(.{ .tag = keyNodeTag(self.token_tags[@intFromEnum(key_token)]), .main_token = key_token, .data = .{ .none = {} } });

        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        const saved_func = self.in_function;
        self.in_async = true;
        self.in_generator = is_generator;
        self.in_function = true;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
            self.in_function = saved_func;
        }

        // Use async_token so nodeStart includes 'async' keyword
        const result = try self.parseMethodProperty(key_token, key);
        self.nodes.items(.main_token)[@intFromEnum(result)] = async_token;
        return result;
    }

    fn parseGeneratorMethod(self: *Parser) Error!NodeIndex {
        const star_token = self.advance(); // *

        const saved_gen = self.in_generator;
        const saved_async = self.in_async;
        const saved_func = self.in_function;
        self.in_generator = true;
        self.in_async = false;
        self.in_function = true;
        defer {
            self.in_generator = saved_gen;
            self.in_async = saved_async;
            self.in_function = saved_func;
        }

        // Handle computed key: *[expr]() {}
        if (self.currentTag() == .l_bracket) {
            _ = self.advance(); // [
            const key = try self.parseAssignmentExpression();
            _ = try self.expect(.r_bracket);
            // Parse params and body
            const params = try self.parseParameterList();
            const body = try self.parseBlockStatement();
            const extra_start = try self.addExtra(@intFromEnum(key));
            _ = try self.addExtra(params.start);
            _ = try self.addExtra(params.end);
            _ = try self.addExtra(@intFromEnum(body));
            _ = try self.addExtra(1); // flags: bit 0 = generator
            return self.addNode(.{
                .tag = .computed_method,
                .main_token = star_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
        }

        const key_token = self.advance();
        const key = try self.addNode(.{ .tag = keyNodeTag(self.token_tags[@intFromEnum(key_token)]), .main_token = key_token, .data = .{ .none = {} } });

        // Use star_token as main_token so nodeStart includes '*'
        const result = try self.parseMethodProperty(key_token, key);
        self.nodes.items(.main_token)[@intFromEnum(result)] = star_token;
        return result;
    }

    fn parseComputedPropertyDef(self: *Parser) Error!NodeIndex {
        const bracket_token = self.advance(); // [
        const key = try self.parseAssignmentExpression();
        _ = try self.expect(.r_bracket);

        if (self.currentTag() == .l_paren) {
            // Computed method
            const params = try self.parseParameterList();
            const body = try self.parseBlockStatement();
            const extra_start = try self.addExtra(@intFromEnum(key));
            _ = try self.addExtra(params.start);
            _ = try self.addExtra(params.end);
            _ = try self.addExtra(@intFromEnum(body));
            // flags: bit 0 = generator, bit 1 = async
            _ = try self.addExtra(0);
            return self.addNode(.{
                .tag = .computed_method,
                .main_token = bracket_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
        }

        _ = try self.expect(.colon);
        const value = try self.parseAssignmentExpression();
        return self.addNode(.{
            .tag = .computed_property,
            .main_token = bracket_token,
            .data = .{ .binary = .{ .lhs = key, .rhs = value } },
        });
    }

    fn parseMethodProperty(self: *Parser, key_token: TokenIndex, key: NodeIndex) Error!NodeIndex {
        // Type parameters: <T, S> before parameter list
        var method_type_params: NodeIndex = .none;
        if (self.currentTag() == .less_than) {
            if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                method_type_params = try parser_ts.parseTsTypeParameterDeclaration(self);
            } else if (self.isFlow()) {
                const flow_mod = @import("parser_flow.zig");
                method_type_params = try flow_mod.parseFlowTypeParameterDeclaration(self);
            }
        }

        const params = try self.parseParameterList();

        const saved_func = self.in_function;
        self.in_function = true;
        defer self.in_function = saved_func;

        // Flow/TS: return type annotation
        var ret_type: NodeIndex = .none;
        if (self.isFlow() and self.currentTag() == .colon) {
            const flow_mod = @import("parser_flow.zig");
            ret_type = try flow_mod.parseFlowTypeAnnotation(self);
        } else if (self.isTypeScript() and self.currentTag() == .colon) {
            const parser_ts = @import("parser_ts.zig");
            ret_type = try parser_ts.parseTsReturnTypeAnnotation(self);
        }

        const body = try self.parseBlockStatement();

        // flags: bit 0 = generator, bit 1 = async
        var flags: u32 = 0;
        if (self.in_generator) flags |= 1;
        if (self.in_async) flags |= 2;

        const extra_start = try self.addExtra(@intFromEnum(key));
        _ = try self.addExtra(params.start);
        _ = try self.addExtra(params.end);
        _ = try self.addExtra(@intFromEnum(body));
        _ = try self.addExtra(flags);

        const method_node = try self.addNode(.{
            .tag = .method_definition,
            .main_token = key_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        if (method_type_params != .none) {
            try self.putTypeParameters(method_node, method_type_params);
        }
        if (ret_type != .none) {
            try self.putReturnType(method_node, ret_type);
        }
        return method_node;
    }

    // === New Expression ===

    fn parseNewExpression(self: *Parser) Error!NodeIndex {
        const new_token = self.advance(); // new

        // new.target / new.<property>
        if (self.currentTag() == .dot) {
            const next = self.lookAhead(1);
            if (next == .identifier or next.isKeyword()) {
                _ = self.advance(); // .
                const prop_token = self.advance();
                // Check if new.target is used outside function when not allowed
                if (!self.opts.allow_new_target_outside_function and !self.in_function) {
                    const prop_text = self.tokenText(@intFromEnum(prop_token));
                    if (std.mem.eql(u8, prop_text, "target")) {
                        self.errors.addError("`new.target` can only be used in functions or class properties.", self.token_starts[@intFromEnum(new_token)]);
                        return error.ParseError;
                    }
                }
                const prop_node = try self.addNode(.{
                    .tag = .identifier,
                    .main_token = prop_token,
                    .data = .{ .none = {} },
                });
                return self.addNode(.{
                    .tag = .meta_property,
                    .main_token = new_token,
                    .data = .{ .unary = prop_node },
                });
            }
        }

        // Parse the callee — but don't allow call expressions at the same level.
        // Handles member access, computed member, optional chaining and tagged templates.
        //
        // Special case: `new import("foo")` with createImportExpressions=false
        // produces NewExpression { callee: Import, arguments: ["foo"] } — the import
        // keyword becomes the callee and the (...) are new's arguments, not import()'s.
        var callee: NodeIndex = undefined;
        if (self.currentTag() == .kw_import and !self.opts.create_import_expressions) {
            const import_tok = self.advance();
            callee = try self.addNode(.{
                .tag = .import_expr,
                .main_token = import_tok,
                .data = .{ .binary = .{ .lhs = .none, .rhs = .none } },
            });
            // Mark as lone import (no parentheses)
            try self.async_arrow_flags.put(self.allocator, @intFromEnum(callee), {});
        } else {
            callee = try self.parsePrefixExpression();
        }
        var in_opt_chain = false;

        while (true) {
            switch (self.currentTag()) {
                .dot => {
                    if (in_opt_chain) {
                        callee = try self.parseOptionalMemberInChain(callee);
                    } else {
                        callee = try self.parseMemberExpression(callee);
                    }
                },
                .l_bracket => {
                    if (in_opt_chain) {
                        callee = try self.parseOptionalComputedInChain(callee);
                    } else {
                        callee = try self.parseComputedMemberExpression(callee);
                    }
                },
                .optional_chain => {
                    if (self.lookAhead(1) == .l_paren) break;
                    callee = try self.parseOptionalChainExpression(callee);
                    in_opt_chain = true;
                },
                .bang => {
                    // TypeScript postfix non-null assertion in callee position,
                    // e.g. `new foo?.bar!()` / `new foo!.bar()`.
                    if (!self.isTypeScript() or self.hasNewlineBefore()) break;
                    const next = self.lookAhead(1);
                    if (next == .equal or next == .equal_equal) break;
                    const parser_ts = @import("parser_ts.zig");
                    callee = try parser_ts.parseTsNonNullExpression(self, callee);
                },
                .template_no_sub, .template_head => {
                    callee = try self.parseTaggedTemplate(callee);
                },
                .less_than, .less_less => {
                    // TypeScript type arguments before tagged template: new C<T>`...`
                    if (self.isTypeScript()) {
                        const saved_ti = self.token_index;
                        const saved_nl = self.nodes.len;
                        const saved_el = self.extra_data.items.len;
                        const saved_sl = self.scratch.items.len;
                        const saved_erl = self.errors.items.items.len;
                        const saved_plt = self.pending_less_than;
                        const parser_ts = @import("parser_ts.zig");
                        const ta = parser_ts.parseTsTypeParameterInstantiation(self) catch |err| switch (err) {
                            error.ParseError => blk: {
                                self.rollbackSpeculativeState(saved_ti, saved_nl, saved_el, saved_sl, saved_erl);
                                self.pending_less_than = saved_plt;
                                break :blk NodeIndex.none;
                            },
                            else => return err,
                        };
                        if (ta != .none and (self.currentTag() == .template_no_sub or self.currentTag() == .template_head)) {
                            callee = try self.parseTaggedTemplate(callee);
                            try self.putTypeParameters(callee, ta);
                            continue;
                        }
                        // Not a tagged template — rollback and fall through to tryParseTypeArgumentsForNew
                        if (ta != .none) {
                            self.rollbackSpeculativeState(saved_ti, saved_nl, saved_el, saved_sl, saved_erl);
                            self.pending_less_than = saved_plt;
                        }
                    }
                    break;
                },
                else => break,
            }
        }

        const type_args = (try self.tryParseTypeArgumentsForNew()) orelse .none;

        // Parse arguments if present
        if (self.currentTag() == .l_paren) {
            _ = self.advance(); // (
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);

            if (self.currentTag() != .r_paren) {
                if (self.opts.enable_partial_application and self.currentTag() == .question and self.lookAhead(1) != .dot) {
                    const q_tok = self.advance();
                    const ph_node = try self.addNode(.{ .tag = .topic_reference, .main_token = q_tok, .data = .{ .none = {} } });
                    try self.scratch.append(self.allocator, ph_node);
                } else {
                    const first = try self.parseAssignmentOrSpread();
                    try self.scratch.append(self.allocator, first);
                }
                while (self.eat(.comma) != null) {
                    if (self.currentTag() == .r_paren) break;
                    if (self.opts.enable_partial_application and self.currentTag() == .question and self.lookAhead(1) != .dot) {
                        const q_tok2 = self.advance();
                        const ph_node2 = try self.addNode(.{ .tag = .topic_reference, .main_token = q_tok2, .data = .{ .none = {} } });
                        try self.scratch.append(self.allocator, ph_node2);
                    } else {
                        const arg = try self.parseAssignmentOrSpread();
                        try self.scratch.append(self.allocator, arg);
                    }
                }
            }
            _ = try self.expect(.r_paren);

            const args = self.scratch.items[scratch_start..];
            const range = try self.addExtraRange(args);
            const extra_start = try self.addExtra(@intFromEnum(callee));
            _ = try self.addExtra(range.start);
            _ = try self.addExtra(range.end);
            const node = try self.addNode(.{
                .tag = .new_expr,
                .main_token = new_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
            if (type_args != .none) {
                try self.putTypeParameters(node, type_args);
            }
            return node;
        }

        // new Foo without parens — use same extra format as with-parens
        const no_args_extra = try self.addExtra(@intFromEnum(callee));
        const empty_range_start: u32 = @intCast(self.extra_data.items.len);
        _ = try self.addExtra(empty_range_start);
        _ = try self.addExtra(empty_range_start);
        const node = try self.addNode(.{
            .tag = .new_expr,
            .main_token = new_token,
            .data = .{ .extra = @enumFromInt(no_args_extra) },
        });
        if (type_args != .none) {
            try self.putTypeParameters(node, type_args);
        }
        return node;
    }

    // === Yield / Await ===

    fn parseThrowExpression(self: *Parser) Error!NodeIndex {
        const throw_token = self.advance(); // throw
        if (self.hasNewlineBefore()) {
            self.errors.addError("Illegal newline after throw", self.currentStart());
        }
        const arg = try self.parseAssignmentExpression();
        return self.addNode(.{ .tag = .unary_expr, .main_token = throw_token, .data = .{ .unary = arg } });
    }

    /// Parse `module { ... }` — ModuleExpression
    fn parseModuleExpression(self: *Parser) Error!NodeIndex {
        const module_token = self.advance(); // module
        _ = try self.expect(.l_brace); // {

        // Parse body statements (module-level: imports, exports, declarations)
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        // Save and set module-level context
        const saved_source_type = self.source_type;
        self.source_type = .module;
        defer self.source_type = saved_source_type;

        var in_directive_prologue = true;
        while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
            const failed_token_index = self.token_index;
            const stmt = self.parseStatementOrDeclaration() catch {
                self.recoverAfterError(failed_token_index);
                in_directive_prologue = false;
                continue;
            };

            // Check if this is a directive (string literal expression statement)
            if (in_directive_prologue) {
                const tags = self.nodes.items(.tag);
                const datas = self.nodes.items(.data);
                if (tags[@intFromEnum(stmt)] == .expression_statement) {
                    const expr_idx = datas[@intFromEnum(stmt)].unary;
                    if (tags[@intFromEnum(expr_idx)] == .string_literal) {
                        // Convert to directive node
                        const dir_literal = try self.addNode(.{
                            .tag = .directive_literal,
                            .main_token = self.nodes.items(.main_token)[@intFromEnum(expr_idx)],
                            .data = .{ .none = {} },
                        });
                        self.nodes.items(.end_offset)[@intFromEnum(dir_literal)] =
                            self.nodes.items(.end_offset)[@intFromEnum(expr_idx)];
                        const dir_node = try self.addNode(.{
                            .tag = .directive,
                            .main_token = self.nodes.items(.main_token)[@intFromEnum(stmt)],
                            .data = .{ .unary = dir_literal },
                        });
                        self.nodes.items(.end_offset)[@intFromEnum(dir_node)] =
                            self.nodes.items(.end_offset)[@intFromEnum(stmt)];
                        try self.scratch.append(self.allocator, dir_node);
                        continue;
                    }
                }
                in_directive_prologue = false;
            }

            try self.scratch.append(self.allocator, stmt);
        }

        _ = try self.expect(.r_brace); // }

        const stmts = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(stmts);

        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);

        return self.addNode(.{
            .tag = .module_expression,
            .main_token = module_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseYieldExpression(self: *Parser) Error!NodeIndex {
        const yield_token = self.advance();
        if (self.hasNewlineBefore() or self.currentTag() == .semicolon or self.currentTag() == .r_paren or self.currentTag() == .r_bracket or self.currentTag() == .r_brace or self.currentTag() == .colon or self.currentTag() == .comma) {
            return self.addNode(.{ .tag = .yield_expr, .main_token = yield_token, .data = .{ .unary = .none } });
        }
        // yield* for delegation
        if (self.eat(.asterisk) != null) {
            const arg = try self.parseAssignmentExpression();
            return self.addNode(.{ .tag = .yield_delegate_expr, .main_token = yield_token, .data = .{ .unary = arg } });
        }
        const arg = try self.parseAssignmentExpression();
        return self.addNode(.{ .tag = .yield_expr, .main_token = yield_token, .data = .{ .unary = arg } });
    }

    fn parseAwaitExpression(self: *Parser) Error!NodeIndex {
        const await_token = self.advance();
        // Check for `await*` which was removed from the async functions proposal
        if (self.currentTag() == .asterisk) {
            self.errors.addError("'await*' has been removed from the async functions proposal. Use Promise.all() instead.", self.currentStart());
            _ = self.advance(); // consume the *
        }
        // await's argument is a UnaryExpression, which includes call/member expressions
        // but not binary operators. Parse at unary precedence so the loop handles
        // call/member/postfix but stops at binary operators like +, *, etc.
        const arg = try self.parseExpressionPrec(.unary);
        return self.addNode(.{ .tag = .await_expr, .main_token = await_token, .data = .{ .unary = arg } });
    }

    // === Import expression / import.meta ===

    fn parseImportExpression(self: *Parser) Error!NodeIndex {
        const import_token = self.advance(); // import

        // import.meta or import.source("foo")
        if (self.currentTag() == .dot) {
            // import.source("foo") — dynamic import with source phase
            if (self.opts.enable_import_source_phase and self.lookAhead(1) == .identifier and
                self.softKeywordAt(self.token_index + 1) == .source and
                self.lookAhead(2) == .l_paren)
            {
                _ = self.advance(); // .
                _ = self.advance(); // source
                return self.parseImportExpressionWithPhase(import_token, "source");
            }
            // import.defer("foo") — dynamic import with defer phase
            if (self.opts.enable_deferred_import and self.lookAhead(1) == .identifier and
                self.softKeywordAt(self.token_index + 1) == .defer_ and
                self.lookAhead(2) == .l_paren)
            {
                _ = self.advance(); // .
                _ = self.advance(); // defer
                return self.parseImportExpressionWithPhase(import_token, "defer");
            }
            _ = self.advance(); // .
            const prop_token = self.advance(); // meta (identifier) or other
            const prop_node = try self.addNode(.{
                .tag = .identifier,
                .main_token = prop_token,
                .data = .{ .none = {} },
            });
            return self.addNode(.{ .tag = .meta_property, .main_token = import_token, .data = .{ .unary = prop_node } });
        }

        // import() — if not ( or ., it's a lone import (error recovery)
        if (self.currentTag() != .l_paren) {
            self.errors.addError("`import` can only be used in `import()` or `import.meta`.", self.token_starts[@intFromEnum(import_token)]);
            const lone_node = try self.addNode(.{ .tag = .import_expr, .main_token = import_token, .data = .{ .binary = .{ .lhs = .none, .rhs = .none } } });
            // Mark as lone import (no parentheses)
            try self.async_arrow_flags.put(self.allocator, @intFromEnum(lone_node), {});
            return lone_node;
        }
        _ = try self.expect(.l_paren);
        if (self.currentTag() == .r_paren) {
            // import() — no arguments, error
            self.errors.addError("import() requires at least one argument.", self.currentStart());
            _ = self.advance(); // skip )
            return self.addNode(.{ .tag = .import_expr, .main_token = import_token, .data = .{ .binary = .{ .lhs = .none, .rhs = .none } } });
        }
        if (self.currentTag() == .ellipsis) {
            self.errors.addError("... is not allowed in import()", self.currentStart());
        }
        const arg = try self.parseAssignmentExpression();
        // Optional second argument: import("foo", { with: ... })
        var options_node: NodeIndex = .none;
        if (self.eat(.comma) != null) {
            // Allow trailing comma: import("foo",)
            if (self.currentTag() != .r_paren) {
                if (self.currentTag() == .ellipsis) {
                    self.errors.addError("... is not allowed in import()", self.currentStart());
                }
                options_node = try self.parseAssignmentExpression();
                // Allow trailing comma after second arg
                if (self.eat(.comma) != null) {
                    // 3+ arguments: consume and store for serialization
                    var extra_args: std.ArrayList(NodeIndex) = .empty;
                    defer extra_args.deinit(self.allocator);
                    while (self.currentTag() != .r_paren and self.currentTag() != .eof) {
                        self.errors.addError("import() only accepts 1 or 2 arguments.", self.currentStart());
                        const extra_arg = try self.parseAssignmentExpression();
                        try extra_args.append(self.allocator, extra_arg);
                        if (self.eat(.comma) == null) break;
                    }
                    if (extra_args.items.len > 0) {
                        _ = try self.expect(.r_paren);
                        const node = try self.addNode(.{ .tag = .import_expr, .main_token = import_token, .data = .{ .binary = .{ .lhs = arg, .rhs = options_node } } });
                        // Store extra args in implements_list side table for serialization
                        const range = try self.addExtraRange(extra_args.items);
                        try self.flow_implements.put(self.allocator, @intFromEnum(node), .{ .start = range.start, .end = range.end });
                        return node;
                    }
                }
            }
        }
        _ = try self.expect(.r_paren);
        return self.addNode(.{ .tag = .import_expr, .main_token = import_token, .data = .{ .binary = .{ .lhs = arg, .rhs = options_node } } });
    }

    fn parseImportExpressionWithPhase(self: *Parser, import_token: TokenIndex, phase: []const u8) Error!NodeIndex {
        _ = try self.expect(.l_paren);
        const arg = try self.parseAssignmentExpression();
        var options_node: NodeIndex = .none;
        if (self.eat(.comma) != null) {
            if (self.currentTag() != .r_paren) {
                options_node = try self.parseAssignmentExpression();
                _ = self.eat(.comma); // trailing comma
            }
        }
        _ = try self.expect(.r_paren);
        const node = try self.addNode(.{ .tag = .import_expr, .main_token = import_token, .data = .{ .binary = .{ .lhs = arg, .rhs = options_node } } });
        const phase_val: u32 = if (std.mem.eql(u8, phase, "source")) IMPORT_PHASE_SOURCE else IMPORT_PHASE_DEFER;
        try self.ts_class_modifiers.put(self.allocator, @intFromEnum(node), phase_val);
        return node;
    }

    // === Async prefix in expression context ===

    fn parseAsyncExprPrefix(self: *Parser) Error!NodeIndex {
        // async do { } expression
        if (self.opts.enable_do_expressions and self.lookAhead(1) == .kw_do and !self.hasNewlineAfterCurrent()) {
            const async_tok = self.advance(); // consume 'async'
            _ = self.advance(); // consume 'do'
            const body = try self.parseBlockStatement();
            const do_node = try self.addNode(.{ .tag = .do_expression, .main_token = async_tok, .data = .{ .unary = body } });
            try self.async_arrow_flags.put(self.allocator, @intFromEnum(do_node), {});
            return do_node;
        }

        // async function, async () =>, async x =>
        if (self.lookAhead(1) == .kw_function and !self.hasNewlineAfterCurrent()) {
            return self.parseAsyncFunctionExpression();
        }

        // Flow: if `async` position is in flow_no_arrow_at, parse as identifier + call
        if (self.isFlow() and self.isFlowNoArrowAt(self.currentStart()) and self.lookAhead(1) == .l_paren) {
            const async_ident_tok = self.advance();
            const async_ident = try self.addNode(.{ .tag = .identifier, .main_token = async_ident_tok, .data = .{ .none = {} } });
            return self.parseCallExpression(async_ident);
        }

        if (self.lookAhead(1) == .l_paren and !self.hasNewlineAfterCurrent() and !self.no_arrow and
            !(self.isTypeScript() and self.in_conditional_consequent))
        {
            // Could be async arrow: async (params) => body
            // Save full state for backtracking if not an arrow
            const saved_idx = self.token_index;
            const saved_nodes_len = self.nodes.len;
            const saved_extra_len = self.extra_data.items.len;
            const saved_errors_len = self.errors.items.items.len;
            const saved_async = self.in_async;
            // Don't set in_async yet — params are parsed as expressions where
            // `await` should remain an identifier (error is added later).
            // in_async is set inside parseParenOrArrow for the arrow body.
            const async_token = self.advance(); // async
            self.pending_async_arrow = true;
            const result = self.parseParenOrArrow() catch {
                self.pending_async_arrow = false;
                // Parse failed — backtrack fully and treat async as identifier
                self.token_index = saved_idx;
                self.nodes.len = saved_nodes_len;
                self.extra_data.items.len = saved_extra_len;
                self.errors.items.items.len = saved_errors_len;
                self.in_async = saved_async;
                const tok = self.advance();
                return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
            };
            // Check if it produced an arrow function
            const result_tag = self.nodes.items(.tag)[@intFromEnum(result)];
            if (result_tag == .arrow_function_expr) {
                // Fix start to be at 'async' keyword
                self.nodes.items(.main_token)[@intFromEnum(result)] = async_token;
                self.in_async = saved_async;
                return result;
            }
            // Not an arrow — backtrack fully and treat async as identifier
            self.pending_async_arrow = false;
            self.token_index = saved_idx;
            self.nodes.len = saved_nodes_len;
            self.extra_data.items.len = saved_extra_len;
            self.errors.items.items.len = saved_errors_len;
            self.in_async = saved_async;
            const tok = self.advance();
            return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
        }
        // async <T>() => ... — generic async arrow (TypeScript or Flow)
        if ((self.isTypeScript() or self.isFlow()) and self.lookAhead(1) == .less_than and !self.hasNewlineAfterCurrent() and !self.no_arrow) {
            if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                const state = self.saveState();
                const async_token = self.advance(); // async
                self.pending_async_arrow = true;
                if (parser_ts.tryParseGenericArrowFunction(self)) |node| {
                    self.nodes.items(.main_token)[@intFromEnum(node)] = async_token;
                    return node;
                } else |_| {
                    self.pending_async_arrow = false;
                    self.restoreState(state);
                }
            } else {
                const parser_flow = @import("parser_flow.zig");
                const state = self.saveState();
                const async_token = self.advance(); // async
                self.pending_async_arrow = true;
                if (parser_flow.tryParseFlowGenericArrowFunction(self)) |node| {
                    self.nodes.items(.main_token)[@intFromEnum(node)] = async_token;
                    return node;
                } else |_| {
                    self.pending_async_arrow = false;
                    self.restoreState(state);
                }
            }
        }
        if (!self.hasNewlineAfterCurrent() and !self.no_arrow) {
            const la = self.lookAhead(1);
            // async x =>, async await =>, async yield => ...
            // Keywords that can be used as parameter names in sloppy mode
            if (la == .identifier or la == .kw_await or la == .kw_yield or la == .kw_let or
                la == .kw_of or la == .kw_static or la == .kw_as or la == .kw_get or la == .kw_set or la == .kw_from)
            {
                // Only treat as arrow if followed by =>
                if (self.lookAhead(2) == .arrow) {
                    const saved_async = self.in_async;
                    self.in_async = true;
                    defer self.in_async = saved_async;
                    const async_token = self.advance(); // async
                    const result = try self.parseArrowFunction();
                    // Fix start to be at 'async' keyword
                    self.nodes.items(.main_token)[@intFromEnum(result)] = async_token;
                    return result;
                }
            }
        }
        // Just an identifier named "async"
        const tok = self.advance();
        return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
    }

    fn parseAsyncFunctionExpression(self: *Parser) Error!NodeIndex {
        const async_token = self.advance(); // async
        const result = try self.parseFunctionExpressionInner(true);
        // Fix start to include 'async' keyword
        self.nodes.items(.main_token)[@intFromEnum(result)] = async_token;
        return result;
    }

    // === Statements ===

    pub fn parseExpressionOrLabeledStatement(self: *Parser) Error!NodeIndex {
        // Placeholder as label: `%%FOO%%: stmt`
        if (self.isPlaceholder() and self.lookAhead(5) == .colon) {
            const ph_label_start = self.currentStart();
            const ph = try self.parsePlaceholder("Identifier");
            _ = self.advance(); // :
            const body = try self.parseSingleStatement();
            const label_node = try self.addNode(.{
                .tag = .labeled_statement,
                .main_token = self.nodes.items(.main_token)[@intFromEnum(ph)],
                .data = .{ .unary = body },
            });
            // Store the placeholder as the label using placeholder_name_nodes
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(label_node), ph);
            // Fix start position to include the leading %%
            try self.node_start_overrides.put(self.allocator, @intFromEnum(label_node), ph_label_start);
            return label_node;
        }
        // Check for labeled statement: identifier ':' (also handles yield/await as labels)
        // Exclude `a::` when bind operator is enabled (:: is the bind operator, not a label)
        const cur = self.currentTag();
        if ((cur == .identifier or cur == .kw_yield or (cur == .kw_await and !self.in_async and self.source_type != .module)) and
            self.lookAhead(1) == .colon and
            !(self.opts.enable_bind_operator and self.lookAhead(2) == .colon))
        {
            const label_token = self.advance();
            _ = self.advance(); // :
            const body = try self.parseSingleStatement();
            return self.addNode(.{
                .tag = .labeled_statement,
                .main_token = label_token,
                .data = .{ .unary = body },
            });
        }
        return self.parseExpressionStatement();
    }

    fn parseExpressionStatement(self: *Parser) Error!NodeIndex {
        const start_token: TokenIndex = @enumFromInt(self.token_index);
        const expr = try self.parseExpression();

        self.expectSemicolon() catch {};
        return self.addNode(.{
            .tag = .expression_statement,
            .main_token = start_token,
            .data = .{ .unary = expr },
        });
    }

    fn parseVariableDeclaration(self: *Parser, tag: Node.Tag) Error!NodeIndex {
        const kw_token = self.advance(); // var/let/const
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        const first = try self.parseDeclarator();
        try self.scratch.append(self.allocator, first);
        while (self.eat(.comma) != null) {
            const decl = try self.parseDeclarator();
            try self.scratch.append(self.allocator, decl);
        }

        self.expectSemicolon() catch {};

        const decls = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(decls);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);

        return self.addNode(.{
            .tag = tag,
            .main_token = kw_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseLetDeclaration(self: *Parser) Error!NodeIndex {
        // `let` can be an identifier in non-strict mode.
        const next = self.lookAhead(1);
        // Placeholder after let: `let %%X%% = ...`
        if (self.opts.enable_placeholders and next == .percent and self.lookAhead(2) == .percent) {
            if (self.in_single_statement and self.hasNewlineAfterCurrent()) {
                // `if (cond) let\n%%X%%` — `let` is identifier expression, not declaration
                const let_tok = self.advance();
                const let_id = try self.addNode(.{ .tag = .identifier, .main_token = let_tok, .data = .{ .none = {} } });
                return self.addNode(.{
                    .tag = .expression_statement,
                    .main_token = let_tok,
                    .data = .{ .unary = let_id },
                });
            }
            if (self.in_single_statement) {
                self.errors.addError("lexical declaration in single-statement context", self.currentStart());
            }
            return self.parseVariableDeclaration(.let_declaration);
        }
        if (next == .identifier or next == .kw_yield or next == .kw_await or next == .kw_let or
            next == .kw_static or next == .kw_get or next == .kw_set or next == .kw_of or next == .kw_from)
        {
            if (self.in_single_statement and self.hasNewlineAfterCurrent()) {
                return self.parseExpressionStatement();
            }
            if (self.in_single_statement) {
                self.errors.addError("lexical declaration in single-statement context", self.currentStart());
            }
            return self.parseVariableDeclaration(.let_declaration);
        }
        // For `{` with newline in single-statement context: treat `let` as an identifier
        // (expression statement) — the `{` on the next line starts a new block statement.
        // For `[`, even with a newline, still parse as a let declaration (with error).
        if (next == .l_brace) {
            if (self.in_single_statement and self.hasNewlineAfterCurrent()) {
                return self.parseExpressionStatement();
            }
            if (self.in_single_statement) {
                self.errors.addError("lexical declaration in single-statement context", self.currentStart());
            }
            return self.parseVariableDeclaration(.let_declaration);
        }
        if (next == .l_bracket) {
            if (self.in_single_statement) {
                self.errors.addError("lexical declaration in single-statement context", self.currentStart());
            }
            return self.parseVariableDeclaration(.let_declaration);
        }
        // Reserved keywords after `let` that cannot be binary operators (e.g., `let default`)
        // — parse as variable declaration with error recovery (parseBindingPattern will emit
        // the error). Keywords like `instanceof` and `in` are excluded because they are valid
        // binary operators following `let` as an identifier expression.
        if (next.isReservedKeyword() and next != .kw_instanceof and next != .kw_in) {
            return self.parseVariableDeclaration(.let_declaration);
        }
        // Otherwise treat as expression statement
        return self.parseExpressionStatement();
    }

    pub fn parseUsingDeclaration(self: *Parser) Error!NodeIndex {
        const using_token = self.advance(); // consume 'using' identifier
        return self.parseUsingDeclarators(using_token, .using_declaration);
    }

    pub fn parseAwaitUsingDeclaration(self: *Parser) Error!NodeIndex {
        const await_token = self.advance(); // consume 'await'
        _ = self.advance(); // consume 'using'
        return self.parseUsingDeclarators(await_token, .await_using_declaration);
    }

    fn parseUsingDeclarators(self: *Parser, main_token: TokenIndex, tag: Node.Tag) Error!NodeIndex {
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        const first = try self.parseDeclarator();
        self.checkUsingDestructuring(first);
        try self.scratch.append(self.allocator, first);
        while (self.eat(.comma) != null) {
            const decl = try self.parseDeclarator();
            self.checkUsingDestructuring(decl);
            try self.scratch.append(self.allocator, decl);
        }

        self.expectSemicolon() catch {};

        const decls = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(decls);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);

        return self.addNode(.{
            .tag = tag,
            .main_token = main_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    /// Emit an error if a `using`/`await using` declarator has a destructuring pattern binding.
    fn checkUsingDestructuring(self: *Parser, decl_node: NodeIndex) void {
        if (decl_node == .none) return;
        const data = self.nodes.items(.data)[@intFromEnum(decl_node)];
        const binding = data.binary.lhs;
        if (binding == .none) return;
        const binding_tag = self.nodes.items(.tag)[@intFromEnum(binding)];
        if (binding_tag == .array_pattern or binding_tag == .object_pattern) {
            const binding_start = self.token_starts[@intFromEnum(self.nodes.items(.main_token)[@intFromEnum(binding)])];
            self.errors.addError("Using declaration cannot have destructuring patterns.", binding_start);
        }
    }

    fn parseDeclarator(self: *Parser) Error!NodeIndex {
        const start_token: TokenIndex = @enumFromInt(self.token_index);
        // Parse binding pattern WITHOUT default value handling — the `=` in
        // `var x = expr` is the initializer, not a default value pattern.
        const binding = try self.parseBindingPattern();

        // TypeScript: definite assignment assertion `x!: Type`
        var is_definite = false;
        if (self.isTypeScript() and self.currentTag() == .bang and !self.hasNewlineBefore()) {
            // Check if this is `x!:` (definite assignment) vs `x!;` (non-null expression)
            const la = self.lookAhead(1);
            if (la == .colon) {
                _ = self.advance(); // consume !
                is_definite = true;
            }
        }

        // Flow: type annotation on variable
        if (self.isFlow() and self.currentTag() == .colon) {
            const flow_mod = @import("parser_flow.zig");
            const type_ann = try flow_mod.parseFlowTypeAnnotation(self);
            try self.putTypeAnnotation(binding, type_ann);
            // Update end position
            const ann_end = self.nodes.items(.end_offset)[@intFromEnum(type_ann)];
            self.nodes.items(.end_offset)[@intFromEnum(binding)] = ann_end;
        }

        // TypeScript: type annotation on variable: `let x: string = ...`
        if (self.isTypeScript() and self.currentTag() == .colon) {
            const parser_ts = @import("parser_ts.zig");
            const type_ann = try parser_ts.parseTsTypeAnnotation(self);
            try self.storeTypeAnnotation(binding, type_ann);
        }

        const init_val = if (self.eat(.equal) != null)
            try self.parseAssignmentExpression()
        else
            @as(NodeIndex, .none);

        const decl = try self.addNode(.{
            .tag = .declarator,
            .main_token = start_token,
            .data = .{ .binary = .{ .lhs = binding, .rhs = init_val } },
        });

        // Store definite assignment flag
        if (is_definite) {
            try self.ts_class_modifiers.put(self.allocator, @intFromEnum(decl), 1); // flag for definite
        }

        return decl;
    }

    /// Parse a binding pattern (identifier, array pattern, or object pattern)
    /// WITHOUT default value (`= expr`) handling. Used by variable declarators
    /// where `=` means initializer, not a default value.
    pub fn parseBindingPattern(self: *Parser) Error!NodeIndex {
        // Placeholder in binding position: `var %%X%% = ...`
        if (self.isPlaceholder()) {
            return self.parsePlaceholder("Pattern");
        }
        switch (self.currentTag()) {
            .identifier => {
                const tok = self.advance();
                return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
            },
            .l_bracket => return self.parseArrayPattern(),
            .l_brace => return self.parseObjectPattern(),
            else => {
                if (self.currentTag().isKeyword()) {
                    // Discard binding: `void` as a pattern → VoidPattern
                    if (self.opts.enable_discard_binding and self.currentTag() == .kw_void) {
                        const tok = self.advance();
                        const node = try self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
                        // Mark as VoidPattern
                        try self.async_arrow_flags.put(self.allocator, @intFromEnum(node), {});
                        return node;
                    }
                    // Reserved words like void, typeof, delete in binding position:
                    // add a non-fatal error but still parse (error recovery like Babel).
                    if (self.currentTag().isReservedKeyword()) {
                        self.errors.addError("Unexpected keyword", self.currentStart());
                    }
                    const tok = self.advance();
                    return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
                }
                self.errors.addError("expected binding pattern", self.currentStart());
                return error.ParseError;
            },
        }
    }

    pub fn parseBindingElement(self: *Parser) Error!NodeIndex {
        var binding = try self.parseBindingPattern();

        // TypeScript/Flow: optional parameter marker `x?`
        if ((self.isTypeScript() or self.isFlow()) and self.currentTag() == .question) {
            const q_tok = self.advance();
            try self.markOptionalParam(binding, q_tok);
        }

        // TypeScript: non-null assertion in parameter position `x!`
        if (self.isTypeScript() and self.currentTag() == .bang and !self.hasNewlineBefore()) {
            const binding_start = self.token_starts[@intFromEnum(self.nodes.items(.main_token)[@intFromEnum(binding)])];
            self.errors.addError("Unexpected type cast in parameter position.", binding_start);
            const parser_ts = @import("parser_ts.zig");
            binding = try parser_ts.parseTsNonNullExpression(self, binding);
        }

        // Type annotation on parameter
        // Not allowed inside array destructuring patterns
        if (self.currentTag() == .colon and !self.in_array_destructuring) {
            if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                const type_ann = try parser_ts.parseTsTypeAnnotation(self);
                try self.storeParamTypeAnnotation(binding, type_ann);
            } else if (self.isFlow()) {
                const flow_mod = @import("parser_flow.zig");
                try flow_mod.tryParseFlowParamTypeAnnotation(self, binding);
            }
        }

        // Check for default value (assignment pattern)
        if (self.currentTag() == .equal) {
            const eq_token = self.advance();
            const def = try self.parseAssignmentExpression();
            return self.addNode(.{ .tag = .assignment_pattern, .main_token = eq_token, .data = .{ .binary = .{ .lhs = binding, .rhs = def } } });
        }
        return binding;
    }

    fn parseArrayPattern(self: *Parser) Error!NodeIndex {
        const bracket_token = self.advance(); // [
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        const saved_in_array_destr = self.in_array_destructuring;
        self.in_array_destructuring = true;
        defer self.in_array_destructuring = saved_in_array_destr;

        while (self.currentTag() != .r_bracket and self.currentTag() != .eof) {
            if (self.currentTag() == .comma) {
                // Elision — emit null hole
                try self.scratch.append(self.allocator, .none);
                _ = self.advance(); // consume comma
                continue;
            }
            if (self.currentTag() == .ellipsis) {
                const rest_token = self.advance();
                const elem = try self.parseBindingElement();
                const rest_node = try self.addNode(.{ .tag = .rest_element, .main_token = rest_token, .data = .{ .unary = elem } });
                // Check: void (discard binding) is not valid as rest target
                if (self.opts.enable_discard_binding and elem != .none and self.async_arrow_flags.contains(@intFromEnum(elem))) {
                    self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(rest_token)]);
                }
                try self.scratch.append(self.allocator, rest_node);
                break;
            }
            const elem = try self.parseBindingElement();
            try self.scratch.append(self.allocator, elem);
            if (self.currentTag() != .r_bracket) {
                _ = try self.expect(.comma);
            }
        }
        _ = try self.expect(.r_bracket);

        const elems = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(elems);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        return self.addNode(.{
            .tag = .array_pattern,
            .main_token = bracket_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseObjectPattern(self: *Parser) Error!NodeIndex {
        const brace_token = self.advance(); // {
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
            if (self.currentTag() == .ellipsis) {
                const rest_token = self.advance();
                const rest_start = self.token_starts[self.token_index];
                const elem = try self.parseBindingElement();
                // Rest argument in object patterns must be a plain identifier
                const elem_tag = self.nodes.items(.tag)[@intFromEnum(elem)];
                if (elem_tag == .object_pattern or elem_tag == .array_pattern or elem_tag == .assignment_pattern) {
                    self.errors.addError("unexpected token", rest_start);
                }
                const rest_node = try self.addNode(.{ .tag = .rest_element, .main_token = rest_token, .data = .{ .unary = elem } });
                // Check: void (discard binding) is not valid as rest target
                if (self.opts.enable_discard_binding and elem != .none and self.async_arrow_flags.contains(@intFromEnum(elem))) {
                    self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(rest_token)]);
                }
                try self.scratch.append(self.allocator, rest_node);
                // Error recovery: if rest is followed by comma, emit error
                if (self.currentTag() == .comma) {
                    self.errors.addError("rest element must be last", self.currentStart());
                    _ = self.advance(); // skip comma
                    // If there are more properties, continue parsing
                    if (self.currentTag() != .r_brace) continue;
                }
                break;
            }
            const prop = try self.parseBindingProperty();
            try self.scratch.append(self.allocator, prop);
            if (self.currentTag() != .r_brace) {
                _ = try self.expect(.comma);
            }
        }
        _ = try self.expect(.r_brace);

        const props = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(props);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        return self.addNode(.{
            .tag = .object_pattern,
            .main_token = brace_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseBindingProperty(self: *Parser) Error!NodeIndex {
        // Handle computed property key: {[expr]: binding}
        if (self.currentTag() == .l_bracket) {
            const bracket_token = self.advance(); // [
            const computed_key = try self.parseAssignmentExpression();
            _ = try self.expect(.r_bracket);
            _ = try self.expect(.colon);
            const value = try self.parseBindingElement();
            return self.addNode(.{ .tag = .computed_property, .main_token = bracket_token, .data = .{ .binary = .{ .lhs = computed_key, .rhs = value } } });
        }

        // Handle private name key: {#x: binding} (destructuring-private)
        if (self.currentTag() == .hash) {
            const hash_tok = self.advance(); // #
            const ident_tok = try self.expect(.identifier);
            const ident_node = try self.addNode(.{ .tag = .identifier, .main_token = ident_tok, .data = .{ .none = {} } });
            const key = try self.addNode(.{ .tag = .private_name, .main_token = hash_tok, .data = .{ .unary = ident_node } });
            _ = try self.expect(.colon);
            const value = try self.parseBindingElement();
            return self.addNode(.{ .tag = .property, .main_token = hash_tok, .data = .{ .binary = .{ .lhs = key, .rhs = value } } });
        }

        // Handle string/number key: {"key": binding, 42: binding}
        if (self.currentTag() == .string or self.currentTag() == .numeric) {
            const key_token = self.advance();
            const key = try self.addNode(.{ .tag = if (self.token_tags[@intFromEnum(key_token)] == .string) .string_literal else .numeric_literal, .main_token = key_token, .data = .{ .none = {} } });
            if (self.eat(.colon) != null) {
                const value = try self.parseBindingElement();
                return self.addNode(.{ .tag = .property, .main_token = key_token, .data = .{ .binary = .{ .lhs = key, .rhs = value } } });
            }
            return self.addNode(.{ .tag = .shorthand_property, .main_token = key_token, .data = .{ .unary = key } });
        }

        const key_token = self.advance(); // identifier or keyword
        const key = try self.addNode(.{ .tag = .identifier, .main_token = key_token, .data = .{ .none = {} } });
        // key: binding or shorthand
        if (self.eat(.colon) != null) {
            const value = try self.parseBindingElement();
            return self.addNode(.{ .tag = .property, .main_token = key_token, .data = .{ .binary = .{ .lhs = key, .rhs = value } } });
        }
        // Shorthand with optional default: { x = expr } becomes
        // ObjectProperty(shorthand=true, key=x, value=AssignmentPattern(left=x, right=expr))
        const ident = key;
        if (self.eat(.equal) != null) {
            const def = try self.parseAssignmentExpression();
            const assign_pat = try self.addNode(.{ .tag = .assignment_pattern, .main_token = key_token, .data = .{ .binary = .{ .lhs = ident, .rhs = def } } });
            return self.addNode(.{ .tag = .shorthand_property, .main_token = key_token, .data = .{ .unary = assign_pat } });
        }
        return self.addNode(.{ .tag = .shorthand_property, .main_token = key_token, .data = .{ .unary = ident } });
    }

    // === Control flow statements ===

    pub fn parseBlockStatement(self: *Parser) Error!NodeIndex {
        const brace_token = try self.expect(.l_brace);
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);
        const saved_single = self.in_single_statement;
        self.in_single_statement = false;
        defer self.in_single_statement = saved_single;

        while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
            const failed_token_index = self.token_index;
            const stmt = self.parseStatementOrDeclaration() catch {
                self.recoverAfterError(failed_token_index);
                continue;
            };
            try self.scratch.append(self.allocator, stmt);
        }
        _ = try self.expect(.r_brace);

        const stmts = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(stmts);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        return self.addNode(.{
            .tag = .block_statement,
            .main_token = brace_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseEmptyStatement(self: *Parser) Error!NodeIndex {
        const tok = self.advance(); // ;
        return self.addNode(.{ .tag = .empty_statement, .main_token = tok, .data = .{ .none = {} } });
    }

    fn parseIfStatement(self: *Parser) Error!NodeIndex {
        const if_token = self.advance(); // if
        _ = try self.expect(.l_paren);
        const condition = try self.parseExpression();
        _ = try self.expect(.r_paren);
        const consequent = try self.parseSingleStatement();

        const alternate = if (self.eat(.kw_else) != null)
            try self.parseSingleStatement()
        else
            @as(NodeIndex, .none);

        const extra_start = try self.addExtra(@intFromEnum(condition));
        _ = try self.addExtra(@intFromEnum(consequent));
        _ = try self.addExtra(@intFromEnum(alternate));

        return self.addNode(.{
            .tag = .if_statement,
            .main_token = if_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseWhileStatement(self: *Parser) Error!NodeIndex {
        const while_token = self.advance(); // while
        _ = try self.expect(.l_paren);
        const condition = try self.parseExpression();
        _ = try self.expect(.r_paren);

        const saved_loop = self.in_loop;
        self.in_loop = true;
        defer self.in_loop = saved_loop;

        const body = try self.parseSingleStatement();
        return self.addNode(.{
            .tag = .while_statement,
            .main_token = while_token,
            .data = .{ .binary = .{ .lhs = condition, .rhs = body } },
        });
    }

    fn parseDoWhileStatement(self: *Parser) Error!NodeIndex {
        const do_token = self.advance(); // do

        const saved_loop = self.in_loop;
        self.in_loop = true;
        defer self.in_loop = saved_loop;

        const body = try self.parseSingleStatement();
        _ = try self.expect(.kw_while);
        _ = try self.expect(.l_paren);
        const condition = try self.parseExpression();
        _ = try self.expect(.r_paren);
        // do-while has a special ASI rule: the semicolon after `do { } while (expr)`
        // is always optional, even without a preceding newline (ECMAScript 13.7.2).
        _ = self.eat(.semicolon);

        return self.addNode(.{
            .tag = .do_while_statement,
            .main_token = do_token,
            .data = .{ .binary = .{ .lhs = body, .rhs = condition } },
        });
    }

    fn parseForStatement(self: *Parser) Error!NodeIndex {
        const for_token = self.advance(); // for

        // Handle `for await (...)`
        const saved_for_await = self.for_await;
        if (self.currentTag() == .kw_await) {
            if (!self.in_async) {
                self.errors.addError("Unexpected token", self.currentStart());
            }
            _ = self.advance(); // consume 'await'
            self.for_await = true;
        }
        defer self.for_await = saved_for_await;

        _ = try self.expect(.l_paren);

        const saved_loop = self.in_loop;
        self.in_loop = true;
        defer self.in_loop = saved_loop;

        // Determine for/for-in/for-of
        // `let` followed by `.`, `(`, or backtick is an identifier expression,
        // not a declaration: `for (let.foo of [])`, `for (let().bar of [])`, etc.
        if (self.currentTag() == .kw_var or self.currentTag() == .kw_const) {
            return self.parseForWithDeclaration(for_token);
        }
        if (self.shouldParseForLetDeclaration()) return self.parseForWithDeclaration(for_token);
        // for (await using x of ...)
        if (self.isAwaitUsingDeclaration()) {
            return self.parseForWithUsingDeclaration(for_token, true);
        }
        // for (using x of/in ...) — but NOT `for (using of <expr>)` which is for-of
        if (self.isUsingDeclaration() and !self.isForUsingOfPattern()) {
            return self.parseForWithUsingDeclaration(for_token, false);
        }
        if (self.currentTag() == .semicolon) {
            // for (;;)
            return self.parseForTraditional(for_token, .none);
        }
        // for (expr; ...) or for (lhs in/of ...)
        // Parse LHS first without allowing 'in' operator (to detect for-in)
        const init_expr = try self.parseExpressionNoIn();
        if (self.currentTag() == .kw_in) {
            self.convertToPattern(init_expr);
            return self.parseForIn(for_token, init_expr);
        }
        if (self.currentTag() == .kw_of) {
            self.convertToPattern(init_expr);
            return self.parseForOf(for_token, init_expr);
        }
        // Traditional for - may need to continue parsing comma expressions
        var full_init = init_expr;
        if (self.currentTag() == .comma) {
            // Parse rest as sequence expression
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);
            try self.scratch.append(self.allocator, init_expr);
            while (self.eat(.comma) != null) {
                const next = try self.parseAssignmentExpression();
                try self.scratch.append(self.allocator, next);
            }
            if (self.scratch.items.len > scratch_start + 1) {
                const items = self.scratch.items[scratch_start..];
                const range = try self.addExtraRange(items);
                const extra_start = try self.addExtra(range.start);
                _ = try self.addExtra(range.end);
                full_init = try self.addNode(.{
                    .tag = .sequence_expr,
                    .main_token = @enumFromInt(self.token_index),
                    .data = .{ .extra = @enumFromInt(extra_start) },
                });
            }
        }
        return self.parseForTraditional(for_token, full_init);
    }

    fn parseForWithDeclaration(self: *Parser, for_token: TokenIndex) Error!NodeIndex {
        const decl_tag: Node.Tag = switch (self.currentTag()) {
            .kw_var => .var_declaration,
            .kw_let => .let_declaration,
            .kw_const => .const_declaration,
            else => unreachable,
        };
        const kw_token = self.advance();

        // Parse first declarator with no_in to allow for-in detection
        const saved_no_in = self.no_in;
        self.no_in = true;
        const first_decl = try self.parseDeclarator();
        self.no_in = saved_no_in;

        // Check for in/of
        if (self.currentTag() == .kw_in) {
            // Wrap single declarator in extra range format (same as normal var decl)
            const scratch_forin = self.scratch.items.len;
            try self.scratch.append(self.allocator, first_decl);
            const forin_decls = self.scratch.items[scratch_forin..];
            const forin_range = try self.addExtraRange(forin_decls);
            const forin_extra = try self.addExtra(forin_range.start);
            _ = try self.addExtra(forin_range.end);
            self.scratch.shrinkRetainingCapacity(scratch_forin);
            const decl_node = try self.addNode(.{
                .tag = decl_tag,
                .main_token = kw_token,
                .data = .{ .extra = @enumFromInt(forin_extra) },
            });
            return self.parseForIn(for_token, decl_node);
        }
        if (self.currentTag() == .kw_of) {
            const scratch_forof = self.scratch.items.len;
            try self.scratch.append(self.allocator, first_decl);
            const forof_decls = self.scratch.items[scratch_forof..];
            const forof_range = try self.addExtraRange(forof_decls);
            const forof_extra = try self.addExtra(forof_range.start);
            _ = try self.addExtra(forof_range.end);
            self.scratch.shrinkRetainingCapacity(scratch_forof);
            const decl_node = try self.addNode(.{
                .tag = decl_tag,
                .main_token = kw_token,
                .data = .{ .extra = @enumFromInt(forof_extra) },
            });
            return self.parseForOf(for_token, decl_node);
        }

        // Traditional for with declaration
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);
        try self.scratch.append(self.allocator, first_decl);
        while (self.eat(.comma) != null) {
            const decl = try self.parseDeclarator();
            try self.scratch.append(self.allocator, decl);
        }

        const decls = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(decls);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        const decl_node = try self.addNode(.{
            .tag = decl_tag,
            .main_token = kw_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });

        return self.parseForTraditional(for_token, decl_node);
    }

    fn parseForWithUsingDeclaration(self: *Parser, for_token: TokenIndex, is_await: bool) Error!NodeIndex {
        const main_token: TokenIndex = @enumFromInt(self.token_index);
        const tag: Node.Tag = if (is_await) .await_using_declaration else .using_declaration;
        if (is_await) {
            _ = self.advance(); // consume 'await'
        }
        _ = self.advance(); // consume 'using'

        // Parse single declarator with no_in to detect for-in/for-of
        const saved_no_in = self.no_in;
        self.no_in = true;
        const first_decl = try self.parseDeclarator();
        self.no_in = saved_no_in;

        // Wrap in using declaration node
        const scratch_start = self.scratch.items.len;
        try self.scratch.append(self.allocator, first_decl);

        if (self.currentTag() == .kw_of) {
            const decls = self.scratch.items[scratch_start..];
            const range = try self.addExtraRange(decls);
            const extra_start = try self.addExtra(range.start);
            _ = try self.addExtra(range.end);
            self.scratch.shrinkRetainingCapacity(scratch_start);
            const decl_node = try self.addNode(.{
                .tag = tag,
                .main_token = main_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
            return self.parseForOf(for_token, decl_node);
        }

        if (self.currentTag() == .kw_in) {
            const decls = self.scratch.items[scratch_start..];
            const range = try self.addExtraRange(decls);
            const extra_start = try self.addExtra(range.start);
            _ = try self.addExtra(range.end);
            self.scratch.shrinkRetainingCapacity(scratch_start);
            const decl_node = try self.addNode(.{
                .tag = tag,
                .main_token = main_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
            return self.parseForIn(for_token, decl_node);
        }

        // Traditional for with using - parse remaining declarators
        while (self.eat(.comma) != null) {
            const decl = try self.parseDeclarator();
            try self.scratch.append(self.allocator, decl);
        }
        const decls = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(decls);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        self.scratch.shrinkRetainingCapacity(scratch_start);
        const decl_node = try self.addNode(.{
            .tag = tag,
            .main_token = main_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        return self.parseForTraditional(for_token, decl_node);
    }

    fn parseForTraditional(self: *Parser, for_token: TokenIndex, init: NodeIndex) Error!NodeIndex {
        // for await (;;) is invalid — await only works with for-of
        if (self.for_await) {
            self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(for_token)]);
        }
        // Use lenient semicolon handling: emit error but don't skip tokens,
        // so that subsequent parts (test, update) can still be parsed.
        // This matches Babel's error recovery for e.g. `for (const of 42)`.
        self.expectSemicolon() catch {};
        const condition = if (self.currentTag() != .semicolon and self.currentTag() != .r_paren)
            self.parseExpression() catch blk: {
                self.skipToDelimiter(.semicolon);
                break :blk @as(NodeIndex, .none);
            }
        else
            @as(NodeIndex, .none);
        if (self.currentTag() != .r_paren) {
            self.expectSemicolon() catch {};
        }
        const update = if (self.currentTag() != .r_paren)
            self.parseExpression() catch blk: {
                self.skipToDelimiter(.semicolon);
                break :blk @as(NodeIndex, .none);
            }
        else
            @as(NodeIndex, .none);
        _ = try self.expect(.r_paren);
        const body = try self.parseSingleStatement();

        const extra_start = try self.addExtra(@intFromEnum(init));
        _ = try self.addExtra(@intFromEnum(condition));
        _ = try self.addExtra(@intFromEnum(update));
        _ = try self.addExtra(@intFromEnum(body));

        return self.addNode(.{
            .tag = .for_statement,
            .main_token = for_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseForIn(self: *Parser, for_token: TokenIndex, left: NodeIndex) Error!NodeIndex {
        // for await (... in ...) is invalid — await only works with for-of
        if (self.for_await) {
            self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(for_token)]);
        }
        _ = self.advance(); // in
        const right = try self.parseExpression();
        _ = try self.expect(.r_paren);
        const body = try self.parseSingleStatement();

        const extra_start = try self.addExtra(@intFromEnum(left));
        _ = try self.addExtra(@intFromEnum(right));
        _ = try self.addExtra(@intFromEnum(body));

        return self.addNode(.{
            .tag = .for_in_statement,
            .main_token = for_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseForOf(self: *Parser, for_token: TokenIndex, left: NodeIndex) Error!NodeIndex {
        _ = self.advance(); // of
        const right = try self.parseAssignmentExpression();
        _ = try self.expect(.r_paren);
        const body = try self.parseSingleStatement();

        const extra_start = try self.addExtra(@intFromEnum(left));
        _ = try self.addExtra(@intFromEnum(right));
        _ = try self.addExtra(@intFromEnum(body));

        const tag: Node.Tag = if (self.for_await) .for_of_await_statement else .for_of_statement;
        return self.addNode(.{
            .tag = tag,
            .main_token = for_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseSwitchStatement(self: *Parser) Error!NodeIndex {
        const switch_token = self.advance(); // switch
        _ = try self.expect(.l_paren);
        const discriminant = try self.parseExpression();
        _ = try self.expect(.r_paren);
        _ = try self.expect(.l_brace);

        const saved_switch = self.in_switch;
        self.in_switch = true;
        defer self.in_switch = saved_switch;

        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
            const case_node = try self.parseSwitchCase();
            try self.scratch.append(self.allocator, case_node);
        }
        _ = try self.expect(.r_brace);

        const cases = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(cases);
        const extra_start = try self.addExtra(@intFromEnum(discriminant));
        _ = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);

        return self.addNode(.{
            .tag = .switch_statement,
            .main_token = switch_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseSwitchCase(self: *Parser) Error!NodeIndex {
        const case_token = self.advance(); // case or default
        const is_default = self.token_tags[@intFromEnum(case_token)] == .kw_default;

        const test_expr = if (!is_default) blk: {
            const expr = try self.parseExpression();
            break :blk expr;
        } else @as(NodeIndex, .none);

        _ = try self.expect(.colon);

        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        while (self.currentTag() != .kw_case and self.currentTag() != .kw_default and self.currentTag() != .r_brace and self.currentTag() != .eof) {
            const failed_token_index = self.token_index;
            const stmt = self.parseStatementOrDeclaration() catch {
                self.recoverAfterError(failed_token_index);
                continue;
            };
            try self.scratch.append(self.allocator, stmt);
        }

        const stmts = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(stmts);
        const extra_start = try self.addExtra(@intFromEnum(test_expr));
        _ = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);

        return self.addNode(.{
            .tag = if (is_default) .switch_default else .switch_case,
            .main_token = case_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseTryStatement(self: *Parser) Error!NodeIndex {
        const try_token = self.advance(); // try
        // Placeholder as try block: `try %%BLOCK%%`
        const block = if (self.isPlaceholder())
            try self.parsePlaceholder("BlockStatement")
        else
            try self.parseBlockStatement();

        var handler: NodeIndex = .none;
        var finalizer: NodeIndex = .none;

        if (self.eat(.kw_catch) != null) {
            handler = try self.parseCatchClause();
        }
        if (self.eat(.kw_finally) != null) {
            // Placeholder as finally block
            finalizer = if (self.isPlaceholder())
                try self.parsePlaceholder("BlockStatement")
            else
                try self.parseBlockStatement();
        }

        const extra_start = try self.addExtra(@intFromEnum(block));
        _ = try self.addExtra(@intFromEnum(handler));
        _ = try self.addExtra(@intFromEnum(finalizer));

        return self.addNode(.{
            .tag = .try_statement,
            .main_token = try_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    fn parseCatchClause(self: *Parser) Error!NodeIndex {
        const catch_token = @as(TokenIndex, @enumFromInt(self.token_index - 1));
        var param: NodeIndex = .none;
        if (self.eat(.l_paren) != null) {
            // Parse binding pattern only (no default allowed in catch)
            param = try self.parseBindingPattern();
            // TypeScript/Flow: type annotation on catch parameter
            if (self.currentTag() == .colon and (self.isTypeScript() or self.isFlow())) {
                const parser_ts = @import("parser_ts.zig");
                const type_ann = try parser_ts.parseTsTypeAnnotation(self);
                try self.storeTypeAnnotation(param, type_ann);
            }
            if (self.currentTag() == .equal) {
                self.errors.addError("Unexpected token", self.currentStart());
                _ = self.advance(); // skip =
                _ = try self.parseAssignmentExpression(); // consume the default expr
            }
            _ = try self.expect(.r_paren);
        }
        // Placeholder as catch body: `catch %%BLOCK%%`
        const body = if (self.isPlaceholder())
            try self.parsePlaceholder("BlockStatement")
        else
            try self.parseBlockStatement();
        return self.addNode(.{
            .tag = .catch_clause,
            .main_token = catch_token,
            .data = .{ .binary = .{ .lhs = param, .rhs = body } },
        });
    }

    fn parseReturnStatement(self: *Parser) Error!NodeIndex {
        const return_token = self.advance(); // return
        // ASI: if newline after return, argument is undefined
        if (self.hasNewlineBefore() or self.currentTag() == .semicolon or self.currentTag() == .r_brace or self.currentTag() == .eof) {
            if (self.currentTag() == .semicolon) _ = self.advance();
            return self.addNode(.{ .tag = .return_statement, .main_token = return_token, .data = .{ .unary = .none } });
        }
        const expr = try self.parseExpression();
        self.expectSemicolon() catch {};
        return self.addNode(.{ .tag = .return_statement, .main_token = return_token, .data = .{ .unary = expr } });
    }

    fn parseThrowStatement(self: *Parser) Error!NodeIndex {
        const throw_token = self.advance(); // throw
        if (self.hasNewlineBefore()) {
            // Emit error but continue parsing the argument for error recovery
            // (Babel parses throw\n10 as ThrowStatement with argument 10 plus an error)
            self.errors.addError("Illegal newline after throw", self.currentStart());
        }
        const expr = try self.parseExpression();
        self.expectSemicolon() catch {};
        return self.addNode(.{ .tag = .throw_statement, .main_token = throw_token, .data = .{ .unary = expr } });
    }

    fn parseBreakContinue(self: *Parser, tag: Node.Tag) Error!NodeIndex {
        const kw_token = self.advance();
        // Optional label (no newline before)
        var label: NodeIndex = .none;
        if (!self.hasNewlineBefore() and self.isPlaceholder()) {
            // Placeholder as label: `break %%LABEL%%`
            label = try self.parsePlaceholder("Identifier");
        } else if (!self.hasNewlineBefore() and self.currentTag() == .identifier) {
            const label_token = self.advance();
            label = try self.addNode(.{ .tag = .identifier, .main_token = label_token, .data = .{ .none = {} } });
        }
        self.expectSemicolon() catch {};
        return self.addNode(.{ .tag = tag, .main_token = kw_token, .data = .{ .unary = label } });
    }

    fn parseWithStatement(self: *Parser) Error!NodeIndex {
        const with_token = self.advance(); // with
        _ = try self.expect(.l_paren);
        const object = try self.parseExpression();
        _ = try self.expect(.r_paren);
        const body = try self.parseSingleStatement();
        return self.addNode(.{
            .tag = .with_statement,
            .main_token = with_token,
            .data = .{ .binary = .{ .lhs = object, .rhs = body } },
        });
    }

    fn parseDebuggerStatement(self: *Parser) Error!NodeIndex {
        const tok = self.advance(); // debugger
        self.expectSemicolon() catch {};
        return self.addNode(.{ .tag = .debugger_statement, .main_token = tok, .data = .{ .none = {} } });
    }

    // === Function Declarations ===

    fn parseFunctionDeclaration(self: *Parser) Error!NodeIndex {
        return self.parseFunctionDeclInner(false, false);
    }

    fn parseFunctionDeclInner(self: *Parser, is_async: bool, is_export: bool) Error!NodeIndex {
        const func_token = self.advance(); // function
        const is_generator = self.eat(.asterisk) != null;

        // Placeholder as function name: `function %%ID%%()`
        var ph_name_node: NodeIndex = .none;
        var name_token: ?TokenIndex = null;
        if (self.isPlaceholder()) {
            ph_name_node = try self.parsePlaceholder("Identifier");
        } else if (self.currentTag() == .identifier or self.currentTag().isKeyword()) {
            // Optional name — can be identifier or keyword (error recovery allows keyword names)
            name_token = self.advance();
        }

        // Non-default-export function declarations require a name
        if (name_token == null and ph_name_node == .none and !is_export) {
            self.errors.addError("Unexpected token", self.currentStart());
        }

        // Type parameters: <T, S> before parameter list
        var type_params: NodeIndex = .none;
        if (self.currentTag() == .less_than) {
            if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                type_params = try parser_ts.parseTsTypeParameterDeclaration(self);
            } else if (self.isFlow()) {
                const flow_mod2 = @import("parser_flow.zig");
                type_params = try flow_mod2.parseFlowTypeParameterDeclaration(self);
            }
        }

        // Set generator/async scope BEFORE parsing parameters, because
        // parameter defaults can contain yield/await expressions.
        const saved_func = self.in_function;
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        self.in_function = true;
        self.in_async = is_async;
        self.in_generator = is_generator;
        defer {
            self.in_function = saved_func;
            self.in_async = saved_async;
            self.in_generator = saved_gen;
        }

        const params = try self.parseParameterList();

        // Flow/TS: return type annotation and/or Flow predicate
        var ret_type: NodeIndex = .none;
        var flow_func_predicate: NodeIndex = .none;
        if (self.isFlow() and self.currentTag() == .colon) {
            const flow_mod2 = @import("parser_flow.zig");
            // Check if the return "type" is actually a predicate: `: %checks`
            if (self.lookAhead(1) == .percent) {
                _ = self.advance(); // consume ':'
                flow_func_predicate = try flow_mod2.parseFlowPredicate(self);
            } else {
                ret_type = try flow_mod2.parseFlowTypeAnnotation(self);
                // Check for predicate after return type
                if (self.currentTag() == .percent) {
                    flow_func_predicate = try flow_mod2.parseFlowPredicate(self);
                }
            }
        } else if (self.isTypeScript() and self.currentTag() == .colon) {
            const parser_ts = @import("parser_ts.zig");
            ret_type = try parser_ts.parseTsReturnTypeAnnotation(self);
        }

        // TypeScript: function declaration without body = TSDeclareFunction (overload)
        if (self.isTypeScript() and self.currentTag() != .l_brace) {
            self.expectSemicolon() catch {};

            // Build as ts_declare_function
            const id_node: NodeIndex = if (name_token) |nt| blk: {
                const id = try self.addNode(.{ .tag = .identifier, .main_token = nt, .data = .{ .none = {} } });
                // Fix end_offset since we create this node after parsing params/return type
                self.nodes.items(.end_offset)[@intFromEnum(id)] = self.token_ends[@intFromEnum(nt)];
                break :blk id;
            } else .none;

            const ts_extra_start = try self.addExtra(@intFromEnum(id_node));
            _ = try self.addExtra(@intFromEnum(type_params));
            _ = try self.addExtra(params.start);
            _ = try self.addExtra(params.end);
            _ = try self.addExtra(@intFromEnum(ret_type));
            _ = try self.addExtra(@intFromEnum(@as(NodeIndex, .none))); // no body

            return self.addNode(.{
                .tag = .ts_declare_function,
                .main_token = func_token,
                .data = .{ .extra = @enumFromInt(ts_extra_start) },
            });
        }

        // Placeholder as function body: `function f() %%BODY%%`
        const body = if (self.isPlaceholder())
            try self.parsePlaceholder("BlockStatement")
        else
            try self.parseBlockStatement();

        const tag: Node.Tag = if (is_async and is_generator)
            .async_generator_declaration
        else if (is_async)
            .async_function_declaration
        else if (is_generator)
            .generator_declaration
        else
            .function_declaration;

        const extra_start = try self.addExtra(@intFromEnum(name_token orelse @as(TokenIndex, @enumFromInt(0))));
        _ = try self.addExtra(params.start);
        _ = try self.addExtra(params.end);
        _ = try self.addExtra(@intFromEnum(body));

        const node = try self.addNode(.{
            .tag = tag,
            .main_token = func_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        // Store placeholder name node
        if (ph_name_node != .none) {
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(node), ph_name_node);
        }
        if (type_params != .none) {
            try self.putTypeParameters(node, type_params);
        }
        if (ret_type != .none) {
            try self.putReturnType(node, ret_type);
        }
        if (flow_func_predicate != .none) {
            try self.flow_predicates.put(self.allocator, @intFromEnum(node), flow_func_predicate);
        }
        return node;
    }

    fn parseFunctionExpression(self: *Parser) Error!NodeIndex {
        return self.parseFunctionExpressionInner(false);
    }

    fn parseFunctionExpressionInner(self: *Parser, is_async: bool) Error!NodeIndex {
        const func_token = self.advance(); // function
        const is_generator = self.eat(.asterisk) != null;
        // Placeholder as function name
        var ph_name_node_expr: NodeIndex = .none;
        var name_token: ?TokenIndex = null;
        if (self.isPlaceholder()) {
            ph_name_node_expr = try self.parsePlaceholder("Identifier");
        } else if (self.currentTag() == .identifier or self.currentTag().isKeyword()) {
            // Accept keyword as function name (error recovery)
            name_token = self.advance();
        }

        // Type parameters: <T, S> before parameter list
        var type_params: NodeIndex = .none;
        if (self.currentTag() == .less_than) {
            if (self.isTypeScript()) {
                const parser_ts = @import("parser_ts.zig");
                type_params = try parser_ts.parseTsTypeParameterDeclaration(self);
            } else if (self.isFlow()) {
                const flow_mod2 = @import("parser_flow.zig");
                type_params = try flow_mod2.parseFlowTypeParameterDeclaration(self);
            }
        }

        // Set generator/async scope BEFORE parsing parameters, because
        // parameter defaults can contain yield/await expressions.
        const saved_func = self.in_function;
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        self.in_function = true;
        self.in_async = is_async;
        self.in_generator = is_generator;
        defer {
            self.in_function = saved_func;
            self.in_async = saved_async;
            self.in_generator = saved_gen;
        }

        const params = try self.parseParameterList();

        // Flow/TS: return type annotation
        var ret_type: NodeIndex = .none;
        if (self.isFlow() and self.currentTag() == .colon) {
            const flow_mod2 = @import("parser_flow.zig");
            ret_type = try flow_mod2.parseFlowTypeAnnotation(self);
        } else if (self.isTypeScript() and self.currentTag() == .colon) {
            const parser_ts = @import("parser_ts.zig");
            ret_type = try parser_ts.parseTsReturnTypeAnnotation(self);
        }

        // Placeholder as function body
        const body = if (self.isPlaceholder())
            try self.parsePlaceholder("BlockStatement")
        else
            try self.parseBlockStatement();

        var flags: u32 = 0;
        if (is_generator) flags |= 1;
        if (is_async) flags |= 2;

        const extra_start = try self.addExtra(@intFromEnum(name_token orelse @as(TokenIndex, @enumFromInt(0))));
        _ = try self.addExtra(params.start);
        _ = try self.addExtra(params.end);
        _ = try self.addExtra(@intFromEnum(body));
        _ = try self.addExtra(flags);

        const node = try self.addNode(.{
            .tag = .function_expr,
            .main_token = func_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        if (ph_name_node_expr != .none) {
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(node), ph_name_node_expr);
        }
        if (type_params != .none) {
            try self.putTypeParameters(node, type_params);
        }
        if (ret_type != .none) {
            try self.putReturnType(node, ret_type);
        }
        return node;
    }

    fn parseParameterList(self: *Parser) Error!Range {
        const flow_mod = @import("parser_flow.zig");
        _ = try self.expect(.l_paren);
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        while (self.currentTag() != .r_paren and self.currentTag() != .eof) {
            if ((self.isFlow() or self.isTypeScript()) and self.currentTag() == .kw_this) {
                const this_param = try self.parseThisParameter(scratch_start);
                try self.scratch.append(self.allocator, this_param);
                if (self.currentTag() == .comma) _ = self.advance();
                continue;
            }

            if (self.currentTag() == .ellipsis) {
                const rest_token = self.advance();
                const rest_start = self.token_starts[@intFromEnum(rest_token)];
                const elem = self.parseBindingElement() catch {
                    self.skipToDelimiter(.comma);
                    continue;
                };
                // Flow: type annotation on rest element
                flow_mod.tryParseFlowParamTypeAnnotation(self, elem) catch {};
                // Rest element cannot have a default value
                if (self.nodes.items(.tag)[@intFromEnum(elem)] == .assignment_pattern) {
                    self.errors.addError("rest element cannot have a default value", rest_start);
                }
                const rest_node = try self.addNode(.{ .tag = .rest_element, .main_token = rest_token, .data = .{ .unary = elem } });
                // Flow: type annotation on rest node
                flow_mod.tryParseFlowParamTypeAnnotation(self, rest_node) catch {};
                // Flow/TypeScript: move type annotation from inner binding to rest node
                if (self.flow_type_annotations.get(@intFromEnum(elem))) |type_ann| {
                    try self.storeTypeAnnotation(rest_node, type_ann);
                    _ = try self.removeTypeAnnotation(elem);
                    // Reset inner element end to its main_token end (before type annotation)
                    const elem_main = self.nodes.items(.main_token)[@intFromEnum(elem)];
                    self.nodes.items(.end_offset)[@intFromEnum(elem)] = self.token_ends[@intFromEnum(elem_main)];
                }
                try self.scratch.append(self.allocator, rest_node);
                // Tolerate trailing comma and extra params after rest (error recovery)
                if (self.eat(.comma) != null) continue;
                break;
            }
            // Parse parameter decorators: @decorator before parameter
            var param_dec_range: ?@import("ast.zig").ExtraRange = null;
            var param_dec_start: u32 = 0;
            if ((self.opts.enable_decorators or self.opts.decorators_legacy) and self.isAtDecorator()) {
                param_dec_start = self.currentStart();
                param_dec_range = try self.parseDecorators();
                if (!(self.isTypeScript() and self.opts.decorators_legacy)) {
                    self.errors.addError("Decorators cannot be used to decorate parameters.", param_dec_start);
                }
            }

            // TypeScript: TSParameterProperty (public x, readonly y, override z, etc.)
            // Allowed in constructors, but parsed (with error) in other methods too.
            if (self.isTypeScript() and self.currentTag() == .identifier) {
                const ts_pp = self.tryParseTsParameterProperty();
                if (ts_pp) |pp| {
                    if (!self.in_constructor_params) {
                        self.errors.addError("A parameter property is only allowed in a constructor implementation.", self.token_starts[@intFromEnum(self.nodes.items(.main_token)[@intFromEnum(pp)])]);
                    }
                    if (param_dec_range) |dr| {
                        try self.decorators_map.put(self.allocator, @intFromEnum(pp), dr);
                        try self.node_start_overrides.put(self.allocator, @intFromEnum(pp), param_dec_start);
                    }
                    try self.scratch.append(self.allocator, pp);
                    if (self.currentTag() != .r_paren) {
                        _ = try self.expect(.comma);
                    }
                    continue;
                }
            }
            const param = self.parseBindingElement() catch {
                self.skipToDelimiter(.comma);
                continue;
            };
            // Attach parameter decorators
            if (param_dec_range) |dr| {
                try self.decorators_map.put(self.allocator, @intFromEnum(param), dr);
                try self.node_start_overrides.put(self.allocator, @intFromEnum(param), param_dec_start);
            }
            // Flow: type annotation on parameter
            flow_mod.tryParseFlowParamTypeAnnotation(self, param) catch {};
            try self.scratch.append(self.allocator, param);
            if (self.currentTag() != .r_paren) {
                _ = try self.expect(.comma);
            }
        }
        _ = try self.expect(.r_paren);

        const params = self.scratch.items[scratch_start..];
        return self.addExtraRange(params);
    }

    // === Placeholders ===

    pub fn isPlaceholder(self: *Parser) bool {
        return self.opts.enable_placeholders and
            self.currentTag() == .percent and
            self.lookAhead(1) == .percent;
    }

    pub fn parsePlaceholder(self: *Parser, expected_node: []const u8) Error!NodeIndex {
        const start_tok = self.advance(); // first %
        _ = self.advance(); // second %
        const name_tok = self.advance(); // identifier
        // Expect closing %%
        _ = try self.expect(.percent);
        const last_pct = try self.expect(.percent);
        const end_pos = self.token_ends[@intFromEnum(last_pct)];
        const node = try self.addNode(.{
            .tag = .placeholder,
            .main_token = name_tok,
            .data = .{ .token = start_tok },
            .end_offset = end_pos,
        });
        // Store expected node context
        try self.placeholder_contexts.put(self.allocator, @intFromEnum(node), expected_node);
        return node;
    }

    // === Decorators ===

    /// Check if the current position is @@ (double-at topic reference in pipeline context).
    fn isDoubleAtTopicReference(self: *const Parser) bool {
        if (!self.opts.enable_pipeline_operator or
            self.opts.pipeline_proposal != .hack or
            self.opts.pipeline_topic_token != .double_at) return false;
        if (self.currentTag() != .invalid) return false;
        const start = self.currentStart();
        if (start >= self.source.len or self.source[start] != '@') return false;
        const next_idx = self.token_index + 1;
        if (next_idx >= self.token_tags.len) return false;
        return self.token_tags[next_idx] == .invalid and
            self.token_starts[next_idx] < self.source.len and
            self.source[self.token_starts[next_idx]] == '@' and
            self.token_ends[self.token_index] == self.token_starts[next_idx];
    }

    fn isAtDecorator(self: *Parser) bool {
        if (self.currentTag() != .invalid) return false;
        const start = self.currentStart();
        return start < self.source.len and self.source[start] == '@';
    }

    fn parseDecorator(self: *Parser) Error!NodeIndex {
        const at_token = self.advance(); // consume @
        // Parse decorator expression (member expressions and calls)
        var expr = try self.parsePrimaryDecorator();
        // Allow member access: @foo.bar.baz or @foo.#bar (private name)
        // Uses the token-index convention for rhs (same as parseDotMember)
        while (self.currentTag() == .dot) {
            const dot_tok = self.advance(); // consume .
            if (self.currentTag() == .hash) {
                // Private name member: @C.#dec
                _ = self.advance(); // consume #
                const name_tok = self.advance(); // property name after #
                expr = try self.addNode(.{ .tag = .member_expr, .main_token = dot_tok, .data = .{ .binary = .{ .lhs = expr, .rhs = @enumFromInt(@intFromEnum(name_tok)) } } });
            } else {
                const prop_tok = self.advance(); // property name
                expr = try self.addNode(.{ .tag = .member_expr, .main_token = dot_tok, .data = .{ .binary = .{ .lhs = expr, .rhs = @enumFromInt(@intFromEnum(prop_tok)) } } });
            }
        }
        // Allow type arguments + call: @foo<T>(args) or @foo<<T>(v: T) => void>(args) (TypeScript)
        if (self.isTypeScript() and (self.currentTag() == .less_than or self.currentTag() == .less_less)) {
            if (try self.tryParseTypeArgumentsForCallOrInstantiation(false)) |type_args| {
                if (self.currentTag() == .l_paren) {
                    expr = try self.parseCallExpression(expr);
                    try self.putTypeParameters(expr, type_args);
                }
            }
        } else if (self.currentTag() == .l_paren) {
            // Allow call: @foo(args)
            expr = try self.parseCallExpression(expr);
        }
        // Legacy decorators: allow member access, computed member, and further calls after initial call
        if (self.opts.decorators_legacy) {
            while (true) {
                if (self.currentTag() == .dot) {
                    const legacy_dot_tok = self.advance();
                    const prop_tok = self.advance();
                    expr = try self.addNode(.{ .tag = .member_expr, .main_token = legacy_dot_tok, .data = .{ .binary = .{ .lhs = expr, .rhs = @enumFromInt(@intFromEnum(prop_tok)) } } });
                } else if (self.isTypeScript() and (self.currentTag() == .less_than or self.currentTag() == .less_less)) {
                    // TypeScript: type arguments on legacy decorator calls
                    if (try self.tryParseTypeArgumentsForCallOrInstantiation(false)) |type_args| {
                        if (self.currentTag() == .l_paren) {
                            expr = try self.parseCallExpression(expr);
                            try self.putTypeParameters(expr, type_args);
                        }
                    }
                } else if (self.currentTag() == .l_paren) {
                    expr = try self.parseCallExpression(expr);
                } else if (self.currentTag() == .l_bracket) {
                    // Legacy decorators allow computed member: @foo[expr]
                    _ = self.advance();
                    const index_expr = try self.parseAssignmentExpression();
                    _ = try self.expect(.r_bracket);
                    expr = try self.addNode(.{ .tag = .computed_member_expr, .main_token = @enumFromInt(@intFromEnum(at_token)), .data = .{ .binary = .{ .lhs = expr, .rhs = index_expr } } });
                } else break;
            }
        }
        return self.addNode(.{ .tag = .decorator, .main_token = at_token, .data = .{ .unary = expr } });
    }

    fn parsePrimaryDecorator(self: *Parser) Error!NodeIndex {
        if (self.currentTag() == .l_paren) {
            const open_paren_tok = self.advance(); // (
            const expr = try self.parseAssignmentExpression();
            _ = try self.expect(.r_paren);
            return self.addNode(.{ .tag = .parenthesized_expr, .main_token = open_paren_tok, .data = .{ .unary = expr } });
        }
        const tok = self.advance();
        return self.addNode(.{ .tag = .identifier, .main_token = tok, .data = .{ .none = {} } });
    }

    fn parseDecorators(self: *Parser) Error!?@import("ast.zig").ExtraRange {
        if (!(self.opts.enable_decorators or self.opts.decorators_legacy) or !self.isAtDecorator()) return null;
        const scratch_top = self.scratch.items.len;
        while (self.isAtDecorator()) {
            const dec = try self.parseDecorator();
            try self.scratch.append(self.allocator, dec);
        }
        const dec_count = self.scratch.items.len - scratch_top;
        if (dec_count == 0) return null;
        const range_start: u32 = @intCast(self.extra_data.items.len);
        for (self.scratch.items[scratch_top..]) |dec_idx| {
            try self.extra_data.append(self.allocator, @intFromEnum(dec_idx));
        }
        self.scratch.shrinkRetainingCapacity(scratch_top);
        return .{ .start = range_start, .end = @intCast(self.extra_data.items.len) };
    }

    fn parseDecoratedStatement(self: *Parser) Error!NodeIndex {
        const dec_range = try self.parseDecorators() orelse return error.ParseError;
        // Compute first decorator start for position adjustment
        const first_dec_idx: NodeIndex = @enumFromInt(self.extra_data.items[dec_range.start]);
        const first_dec_main_token = self.nodes.items(.main_token)[@intFromEnum(first_dec_idx)];
        const first_dec_start = self.token_starts[@intFromEnum(first_dec_main_token)];

        // After decorators, expect class, export, or abstract class
        if (self.currentTag() == .kw_class) {
            const cls = try self.parseClassDeclaration();
            try self.decorators_map.put(self.allocator, @intFromEnum(cls), dec_range);
            try self.node_start_overrides.put(self.allocator, @intFromEnum(cls), first_dec_start);
            return cls;
        } else if (self.currentTag() == .kw_export) {
            // Decorators before export: attach decorators to the inner class declaration
            const export_node = try self.parseExportDeclaration();
            const export_tag = self.nodes.items(.tag)[@intFromEnum(export_node)];
            // For `export default class` or `export class`, find the inner declaration
            if (export_tag == .export_default) {
                const inner = self.nodes.items(.data)[@intFromEnum(export_node)].unary;
                const inner_tag = self.nodes.items(.tag)[@intFromEnum(inner)];
                if (inner_tag == .class_declaration or inner_tag == .class_expr) {
                    // Merge with any existing decorators (from @dec after export keyword)
                    if (self.decorators_map.get(@intFromEnum(inner))) |existing| {
                        // Prepend outer decorators before inner ones
                        const merged_start: u32 = @intCast(self.extra_data.items.len);
                        for (self.extra_data.items[dec_range.start..dec_range.end]) |d| {
                            try self.extra_data.append(self.allocator, d);
                        }
                        for (self.extra_data.items[existing.start..existing.end]) |d| {
                            try self.extra_data.append(self.allocator, d);
                        }
                        try self.decorators_map.put(self.allocator, @intFromEnum(inner), .{ .start = merged_start, .end = @intCast(self.extra_data.items.len) });
                    } else {
                        try self.decorators_map.put(self.allocator, @intFromEnum(inner), dec_range);
                    }
                    try self.node_start_overrides.put(self.allocator, @intFromEnum(inner), first_dec_start);
                    try self.node_start_overrides.put(self.allocator, @intFromEnum(export_node), first_dec_start);
                    return export_node;
                }
            } else if (export_tag == .export_named or export_tag == .export_named_type) {
                // export class Foo {} — the declaration is in extra_data
                const extra_idx = @intFromEnum(self.nodes.items(.data)[@intFromEnum(export_node)].extra);
                if (extra_idx + 3 < self.extra_data.items.len) {
                    const decl_raw = self.extra_data.items[extra_idx + 3];
                    if (decl_raw != @intFromEnum(NodeIndex.none)) {
                        const decl: NodeIndex = @enumFromInt(decl_raw);
                        const decl_tag = self.nodes.items(.tag)[@intFromEnum(decl)];
                        if (decl_tag == .class_declaration or decl_tag == .class_expr) {
                            // Merge with any existing decorators (from @dec after export keyword)
                            if (self.decorators_map.get(@intFromEnum(decl))) |existing| {
                                const merged_start2: u32 = @intCast(self.extra_data.items.len);
                                for (self.extra_data.items[dec_range.start..dec_range.end]) |d| {
                                    try self.extra_data.append(self.allocator, d);
                                }
                                for (self.extra_data.items[existing.start..existing.end]) |d| {
                                    try self.extra_data.append(self.allocator, d);
                                }
                                try self.decorators_map.put(self.allocator, @intFromEnum(decl), .{ .start = merged_start2, .end = @intCast(self.extra_data.items.len) });
                            } else {
                                try self.decorators_map.put(self.allocator, @intFromEnum(decl), dec_range);
                            }
                            try self.node_start_overrides.put(self.allocator, @intFromEnum(decl), first_dec_start);
                            try self.node_start_overrides.put(self.allocator, @intFromEnum(export_node), first_dec_start);
                            return export_node;
                        }
                    }
                }
            }
            // Non-class export with decorator — error in legacy mode
            if (self.opts.decorators_legacy) {
                self.errors.addError("A decorated export must export a class declaration.", self.currentStart());
                return error.ParseError;
            }
            // Fallback: attach to the export node itself
            try self.decorators_map.put(self.allocator, @intFromEnum(export_node), dec_range);
            try self.node_start_overrides.put(self.allocator, @intFromEnum(export_node), first_dec_start);
            return export_node;
        } else if (self.isTypeScript() and self.currentTag() == .identifier and
            self.currentSoftKeyword() == .abstract_ and
            self.lookAhead(1) == .kw_class)
        {
            const abstract_tok = self.advance();
            const cls = try self.parseClassDeclaration();
            self.nodes.items(.main_token)[@intFromEnum(cls)] = abstract_tok;
            try self.storeTsModifiers(cls, TS_MOD_ABSTRACT);
            try self.decorators_map.put(self.allocator, @intFromEnum(cls), dec_range);
            try self.node_start_overrides.put(self.allocator, @intFromEnum(cls), first_dec_start);
            return cls;
        } else {
            self.errors.addError("Leading decorators must be attached to a class declaration", self.currentStart());
            return error.ParseError;
        }
    }

    // === Class Declarations ===

    pub fn parseClassDeclaration(self: *Parser) Error!NodeIndex {
        return self.parseClassDeclInner(false);
    }

    fn parseClassDeclInner(self: *Parser, is_export: bool) Error!NodeIndex {
        const flow_mod = @import("parser_flow.zig");
        const parser_ts = @import("parser_ts.zig");
        const class_token = self.advance(); // class

        // Placeholder as class name: `class %%ID%% {}`
        var ph_class_name: NodeIndex = .none;
        var name_token: ?TokenIndex = null;
        if (self.isPlaceholder()) {
            ph_class_name = try self.parsePlaceholder("Identifier");
        } else {
            // Accept keyword as class name (error recovery), but in Flow/TS mode
            // `implements` before an identifier is a keyword, not the class name
            name_token = blk_name: {
                if (self.currentTag() == .identifier or
                    (self.currentTag().isKeyword() and self.currentTag() != .kw_extends))
                {
                    if ((self.isFlow() or self.isTypeScript()) and
                        self.currentSoftKeyword() == .implements)
                    {
                        const la = self.lookAhead(1);
                        if (la == .identifier or la.isKeyword()) {
                            break :blk_name null;
                        }
                    }
                    // For export default class, name is optional
                    if (is_export and self.currentTag() == .l_brace) break :blk_name null;
                    break :blk_name self.advance();
                }
                break :blk_name null;
            };
        }

        var type_params: NodeIndex = .none;
        if (self.isFlow() and self.currentTag() == .less_than) {
            type_params = try flow_mod.parseFlowTypeParameterDeclaration(self);
        } else if (self.isTypeScript() and self.currentTag() == .less_than) {
            type_params = try parser_ts.parseTsTypeParameterDeclaration(self);
        }

        var super_class: NodeIndex = .none;
        var super_type_args: NodeIndex = .none;
        if (self.eat(.kw_extends) != null) {
            super_class = try self.parseExpressionPrec(.call);
            self.rejectArrowNode(super_class);
            if (self.isFlow() and (self.currentTag() == .less_than or self.currentTag() == .less_less)) {
                super_type_args = try flow_mod.parseFlowTypeParameterInstantiation(self);
            } else if (self.isTypeScript() and (self.currentTag() == .less_than or self.currentTag() == .less_less)) {
                super_type_args = try parser_ts.parseTsTypeParameterInstantiation(self);
            }
        }

        var implements_range: ?@import("ast.zig").ExtraRange = null;
        if (self.currentTag() == .identifier and self.currentSoftKeyword() == .implements) {
            _ = self.advance(); // implements
            const scratch_start = self.scratch.items.len;
            // Handle empty implements (e.g., `class Foo implements {}`)
            if (self.currentTag() != .l_brace) {
                while (true) {
                    const impl = if (self.isFlow())
                        try flow_mod.parseFlowInterfaceExtends(self)
                    else if (self.isTypeScript())
                        try parser_ts.parseTsTypeReference(self)
                    else
                        break;
                    try self.scratch.append(self.allocator, impl);
                    if (self.currentTag() != .comma) break;
                    _ = self.advance();
                }
            }
            const impl_items = self.scratch.items[scratch_start..];
            const impl_range = try self.addExtraRange(impl_items);
            self.scratch.shrinkRetainingCapacity(scratch_start);
            implements_range = .{ .start = impl_range.start, .end = impl_range.end };
        }

        // Placeholder as class body: `class Cl %%BODY%%`
        const body = if (self.isPlaceholder())
            try self.parsePlaceholder("ClassBody")
        else
            try self.parseClassBody();

        const extra_start = try self.addExtra(@intFromEnum(name_token orelse @as(TokenIndex, @enumFromInt(0))));
        _ = try self.addExtra(@intFromEnum(super_class));
        _ = try self.addExtra(@intFromEnum(body));

        const node = try self.addNode(.{
            .tag = .class_declaration,
            .main_token = class_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        // Store placeholder name node
        if (ph_class_name != .none) {
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(node), ph_class_name);
        }
        if (type_params != .none) {
            try self.putTypeParameters(node, type_params);
        }
        if (super_type_args != .none) {
            try self.flow_super_type_params.put(self.allocator, @intFromEnum(node), super_type_args);
        }
        if (implements_range) |impl_range| {
            try self.flow_implements.put(self.allocator, @intFromEnum(node), impl_range);
        }
        return node;
    }

    fn parseClassExpression(self: *Parser) Error!NodeIndex {
        const flow_mod = @import("parser_flow.zig");
        const parser_ts = @import("parser_ts.zig");
        const class_token = self.advance(); // class
        // Placeholder as class name (but NOT class body — check what follows the placeholder)
        var ph_class_name_expr: NodeIndex = .none;
        var name_token: ?TokenIndex = null;
        if (self.isPlaceholder()) {
            // Look past the %% IDENT %% (5 tokens) to see what follows
            const after_ph = self.lookAhead(5);
            if (after_ph == .l_brace or after_ph == .kw_extends or
                (after_ph == .identifier and self.softKeywordAt(self.token_index + 5) == .implements) or
                after_ph == .less_than or
                (after_ph == .percent and self.lookAhead(6) == .percent))
            {
                ph_class_name_expr = try self.parsePlaceholder("Identifier");
            }
            // Otherwise: placeholder is the class body, handled below
        } else {
            // Accept keyword as class name (except extends, {)
            // In TypeScript: `class implements X {}` — `implements` is the keyword, not the name
            name_token = blk_name: {
                if (self.currentTag() == .identifier or
                    (self.currentTag().isKeyword() and self.currentTag() != .kw_extends))
                {
                    // If the token is `implements` in TypeScript context, check if it's
                    // actually the implements keyword (followed by a type reference)
                    if (self.isTypeScript() and self.currentSoftKeyword() == .implements) {
                        const la = self.lookAhead(1);
                        // If followed by an identifier or keyword that could start a type, it's the keyword
                        if (la == .identifier or la.isKeyword()) {
                            break :blk_name null;
                        }
                    }
                    break :blk_name self.advance();
                }
                break :blk_name null;
            };
        }

        var type_params: NodeIndex = .none;
        if (self.isFlow() and self.currentTag() == .less_than) {
            type_params = try flow_mod.parseFlowTypeParameterDeclaration(self);
        } else if (self.isTypeScript() and self.currentTag() == .less_than) {
            type_params = try parser_ts.parseTsTypeParameterDeclaration(self);
        }

        var super_class: NodeIndex = .none;
        var super_type_args: NodeIndex = .none;
        if (self.eat(.kw_extends) != null) {
            super_class = try self.parseExpressionPrec(.call);
            self.rejectArrowNode(super_class);
            if (self.isFlow() and (self.currentTag() == .less_than or self.currentTag() == .less_less)) {
                super_type_args = try flow_mod.parseFlowTypeParameterInstantiation(self);
            } else if (self.isTypeScript() and (self.currentTag() == .less_than or self.currentTag() == .less_less)) {
                super_type_args = try parser_ts.parseTsTypeParameterInstantiation(self);
            }
        }

        var implements_range: ?@import("ast.zig").ExtraRange = null;
        if (self.currentTag() == .identifier and self.currentSoftKeyword() == .implements) {
            _ = self.advance(); // implements
            const scratch_start = self.scratch.items.len;
            // Handle empty implements (e.g., `class Foo implements {}`)
            if (self.currentTag() != .l_brace) {
                while (true) {
                    const impl = if (self.isFlow())
                        try flow_mod.parseFlowInterfaceExtends(self)
                    else if (self.isTypeScript())
                        try parser_ts.parseTsTypeReference(self)
                    else
                        break;
                    try self.scratch.append(self.allocator, impl);
                    if (self.currentTag() != .comma) break;
                    _ = self.advance();
                }
            }
            const impl_items = self.scratch.items[scratch_start..];
            const impl_range = try self.addExtraRange(impl_items);
            self.scratch.shrinkRetainingCapacity(scratch_start);
            implements_range = .{ .start = impl_range.start, .end = impl_range.end };
        }

        // Placeholder as class body
        const body = if (self.isPlaceholder())
            try self.parsePlaceholder("ClassBody")
        else
            try self.parseClassBody();

        const extra_start = try self.addExtra(@intFromEnum(name_token orelse @as(TokenIndex, @enumFromInt(0))));
        _ = try self.addExtra(@intFromEnum(super_class));
        _ = try self.addExtra(@intFromEnum(body));

        const node = try self.addNode(.{
            .tag = .class_expr,
            .main_token = class_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        if (ph_class_name_expr != .none) {
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(node), ph_class_name_expr);
        }
        if (type_params != .none) {
            try self.putTypeParameters(node, type_params);
        }
        if (super_type_args != .none) {
            try self.flow_super_type_params.put(self.allocator, @intFromEnum(node), super_type_args);
        }
        if (implements_range) |impl_range| {
            try self.flow_implements.put(self.allocator, @intFromEnum(node), impl_range);
        }
        return node;
    }

    fn parseClassBody(self: *Parser) Error!NodeIndex {
        const brace_token = try self.expect(.l_brace);
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
            // Skip semicolons in class body
            if (self.currentTag() == .semicolon) {
                _ = self.advance();
                continue;
            }
            // Parse decorators before class member
            const member_dec_range = self.parseDecorators() catch null;
            // Error: decorator followed by semicolon
            if (member_dec_range != null and self.currentTag() == .semicolon) {
                self.errors.addError("Decorators must not be followed by a semicolon.", self.currentStart());
                _ = self.advance();
                continue;
            }
            const failed_token_index = self.token_index;
            const member = self.parseClassMember() catch {
                // Error recovery: skip to next class member boundary
                self.skipToClassMemberBoundary(failed_token_index);
                continue;
            };
            // Attach decorators to member
            if (member_dec_range) |dr| {
                try self.decorators_map.put(self.allocator, @intFromEnum(member), dr);
                // Adjust start position
                const first_dec_idx: NodeIndex = @enumFromInt(self.extra_data.items[dr.start]);
                const first_dec_main_token = self.nodes.items(.main_token)[@intFromEnum(first_dec_idx)];
                const first_dec_start = self.token_starts[@intFromEnum(first_dec_main_token)];
                try self.node_start_overrides.put(self.allocator, @intFromEnum(member), first_dec_start);
            }
            try self.scratch.append(self.allocator, member);
        }
        _ = try self.expect(.r_brace);

        const members = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(members);
        const extra_start = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        return self.addNode(.{
            .tag = .class_body,
            .main_token = brace_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    /// Check if an identifier token text is a TypeScript class member modifier keyword.
    /// Returns the modifier bit or 0 if not a modifier.
    pub fn tsModifierBit(text: []const u8) u32 {
        if (std.mem.eql(u8, text, "public")) return TS_MOD_PUBLIC;
        if (std.mem.eql(u8, text, "private")) return TS_MOD_PRIVATE;
        if (std.mem.eql(u8, text, "protected")) return TS_MOD_PROTECTED;
        if (std.mem.eql(u8, text, "readonly")) return TS_MOD_READONLY;
        if (std.mem.eql(u8, text, "abstract")) return TS_MOD_ABSTRACT;
        if (std.mem.eql(u8, text, "declare")) return TS_MOD_DECLARE;
        if (std.mem.eql(u8, text, "override")) return TS_MOD_OVERRIDE;
        if (std.mem.eql(u8, text, "in")) return TS_MOD_IN;
        if (std.mem.eql(u8, text, "out")) return TS_MOD_OUT;
        return 0;
    }

    /// Check if a contextual identifier token is a TypeScript class member modifier keyword.
    /// Returns the modifier bit or 0 if not a modifier.
    pub fn tsModifierBitFromToken(tag: Token.Tag, soft: SoftKeyword) u32 {
        if (tag == .kw_in) return TS_MOD_IN;
        return switch (soft) {
            .public_ => TS_MOD_PUBLIC,
            .private_ => TS_MOD_PRIVATE,
            .protected_ => TS_MOD_PROTECTED,
            .readonly => TS_MOD_READONLY,
            .abstract_ => TS_MOD_ABSTRACT,
            .declare => TS_MOD_DECLARE,
            .override => TS_MOD_OVERRIDE,
            .out => TS_MOD_OUT,
            else => 0,
        };
    }

    /// Parse TypeScript class member modifier keywords (public, private, protected,
    /// readonly, abstract, declare, override). Only consumes tokens that are truly
    /// modifiers (followed by another modifier, property name, or keyword -- not by
    /// ( ; = } which would mean the identifier is a property name itself).
    fn parseTsClassModifiers(self: *Parser) u32 {
        var mods: u32 = 0;
        if (!self.isTypeScript()) return mods;
        while (self.currentTag() == .identifier or self.currentTag() == .kw_in) {
            const bit = tsModifierBitFromToken(self.currentTag(), self.currentSoftKeyword());
            if (bit == 0) break;
            // Look ahead: if next token is ( ; = } then this identifier is a property name, not a modifier
            const la = self.lookAhead(1);
            if (la == .l_paren or la == .semicolon or la == .equal or la == .r_brace) break;
            // Also not a modifier if next is < (type parameters — method named with modifier keyword)
            if (la == .less_than) break;
            // Also not a modifier if followed by newline (ASI — modifier is actually a field name)
            if (self.hasNewlineAfterCurrent()) break;
            // Also not a modifier if next is ? followed by : ; = } (optional property name)
            if (la == .question) {
                const la2 = self.lookAhead(2);
                if (la2 == .colon or la2 == .semicolon or la2 == .equal or la2 == .r_brace) break;
            }
            // Also not a modifier if next is : (type annotation on field named with modifier keyword)
            if (la == .colon) break;
            // Also not a modifier if next is ! followed by : (definite assignment)
            if (la == .bang) {
                const la2 = self.lookAhead(2);
                if (la2 == .colon) break;
            }
            // For accessibility (public/private/protected), keep only the first one.
            const accessibility_mask = TS_MOD_PUBLIC | TS_MOD_PRIVATE | TS_MOD_PROTECTED;
            const is_duplicate_accessibility = (bit & accessibility_mask != 0) and (mods & accessibility_mask != 0);
            if (!is_duplicate_accessibility) {
                mods |= bit;
            }
            _ = self.advance();
        }
        return mods;
    }

    /// Store TypeScript class modifiers on a node if any were parsed.
    pub fn storeTsModifiers(self: *Parser, node: NodeIndex, ts_mods: u32) Error!void {
        if (ts_mods != 0) {
            try self.ts_class_modifiers.put(self.allocator, @intFromEnum(node), ts_mods);
        }
    }

    fn parseClassMember(self: *Parser) Error!NodeIndex {
        var is_static = false;
        var is_declare = false;
        const member_start_token: TokenIndex = @enumFromInt(self.token_index);
        const saved_declare = self.class_member_is_declare;
        self.class_member_is_declare = false;
        defer self.class_member_is_declare = saved_declare;
        const saved_accessor = self.class_member_is_accessor;
        self.class_member_is_accessor = false;
        defer self.class_member_is_accessor = saved_accessor;

        var ts_mods = self.parseTsClassModifiers();

        // Flow: `declare` modifier on class members
        if (self.isFlow() and self.currentTag() == .identifier and
            self.currentSoftKeyword() == .declare)
        {
            const la = self.lookAhead(1);
            // declare( or declare; or declare= or declare: or declare} means 'declare' is a field/method name
            if (la != .l_paren and la != .semicolon and la != .equal and la != .r_brace and la != .colon) {
                is_declare = true;
                self.class_member_is_declare = true;
                _ = self.advance();
            }
        }

        // static keyword — but only if NOT followed by ( ; = (which means 'static' is a method/field name)
        if (self.currentTag() == .kw_static) {
            const la = self.lookAhead(1);
            // static { ... } is a static block
            if (la == .l_brace and !is_declare) {
                _ = self.advance(); // consume 'static'
                return self.parseStaticBlockBody(member_start_token, ts_mods);
            }
            // static( or static; or static= or static} or static< means 'static' is a method/field name
            if (la != .l_paren and la != .semicolon and la != .equal and la != .r_brace and
                !(self.isTypeScript() and la == .less_than))
            {
                is_static = true;
                _ = self.advance();
            }
        }

        // After consuming first static, check for `static static {}` pattern
        if (is_static and self.currentTag() == .kw_static and self.lookAhead(1) == .l_brace) {
            _ = self.advance(); // consume second 'static'
            return self.parseStaticBlockBody(member_start_token, ts_mods | TS_MOD_STATIC);
        }

        ts_mods |= self.parseTsClassModifiers();

        // `accessor` keyword for auto-accessors (decoratorAutoAccessors plugin)
        if (self.opts.enable_decorator_auto_accessors and self.currentTag() == .identifier and
            self.currentSoftKeyword() == .accessor)
        {
            const la = self.lookAhead(1);
            // accessor( or accessor; or accessor= or accessor} or accessor: means 'accessor' is a field/method name
            // Also, a newline after `accessor` means it's a field name (ASI)
            if (la != .l_paren and la != .semicolon and la != .equal and la != .r_brace and la != .colon and
                !self.hasNewlineAfterCurrent())
            {
                self.class_member_is_accessor = true;
                _ = self.advance();
            }
        }

        // TypeScript: detect index signature [key: Type]: Type in class body
        if (self.isTypeScript() and self.currentTag() == .l_bracket and
            self.lookAhead(1) == .identifier and self.lookAhead(2) == .colon)
        {
            const parser_ts = @import("parser_ts.zig");
            const idx_sig = try parser_ts.parseTsClassIndexSignature(self, member_start_token);
            var idx_mods = ts_mods;
            if (is_static) idx_mods |= TS_MOD_STATIC;
            try self.storeTsModifiers(idx_sig, idx_mods);
            return idx_sig;
        }

        // Handle get/set — when followed by a property name (not ( ; = } * < : ? !)
        // Getters/setters can't be generators, so `*` means `get`/`set` is a field name.
        // `<` means type parameters — `get<T>()` is a method named `get`, not a getter.
        // `:` means type annotation — `get: string` is a field named `get`.
        // `?` means optional — `get?: string` is a field named `get`.
        // `!` means definite assignment — `get!: string` is a field named `get`.
        if ((self.currentTag() == .kw_get or self.currentTag() == .kw_set) and
            self.lookAhead(1) != .l_paren and self.lookAhead(1) != .semicolon and
            self.lookAhead(1) != .equal and self.lookAhead(1) != .r_brace and
            self.lookAhead(1) != .asterisk and self.lookAhead(1) != .less_than and
            self.lookAhead(1) != .colon and self.lookAhead(1) != .question and
            self.lookAhead(1) != .bang)
        {
            const node = try self.parseGetterSetterProperty(if (is_static) @as(u32, 3) else 2);
            try self.storeTsModifiers(node, ts_mods);
            return node;
        }

        // async method — but not if followed by ( ; = } ? : ! < (which means 'async' is a field/method name)
        if (self.currentTag() == .kw_async and self.lookAhead(1) != .l_paren and
            self.lookAhead(1) != .semicolon and self.lookAhead(1) != .equal and
            self.lookAhead(1) != .r_brace and self.lookAhead(1) != .question and
            self.lookAhead(1) != .colon and self.lookAhead(1) != .bang and
            !(self.isTypeScript() and self.lookAhead(1) == .less_than) and
            !self.hasNewlineAfterCurrent())
        {
            _ = self.advance(); // async
            const is_generator = self.eat(.asterisk) != null;

            if (self.currentTag() == .identifier) {
                const next_text = self.tokenText(self.token_index);
                if (std.mem.eql(u8, next_text, "constructor")) {
                    self.errors.addError("Constructor can't be an async function.", self.currentStart());
                }
            }

            const saved_async = self.in_async;
            const saved_gen = self.in_generator;
            self.in_async = true;
            self.in_generator = is_generator;
            defer {
                self.in_async = saved_async;
                self.in_generator = saved_gen;
            }

            const node = try self.parseClassMethodOrField(is_static, member_start_token, true, is_generator);
            try self.storeTsModifiers(node, ts_mods);
            return node;
        }

        // Flow: variance annotation (+/- before property name, only at start of member)
        if (self.isFlow() and !is_static and (self.currentTag() == .plus or self.currentTag() == .minus)) {
            const la = self.lookAhead(1);
            if (la == .identifier or la == .string or la.isKeyword() or la == .hash) {
                const variance_token = self.advance();
                const flow_mod = @import("parser_flow.zig");
                const variance_node = try flow_mod.createFlowVarianceNode(self, variance_token);
                const node = try self.parseClassMethodOrField(is_static, member_start_token, false, false);
                try self.flow_variance_map.put(self.allocator, @intFromEnum(node), variance_node);
                try self.storeTsModifiers(node, ts_mods);
                return node;
            }
        }

        // Generator
        if (self.currentTag() == .asterisk) {
            _ = self.advance();
            const saved_gen = self.in_generator;
            self.in_generator = true;
            defer self.in_generator = saved_gen;
            const node = try self.parseClassMethodOrField(is_static, member_start_token, false, true);
            try self.storeTsModifiers(node, ts_mods);
            return node;
        }

        const node = try self.parseClassMethodOrField(is_static, member_start_token, false, false);
        try self.storeTsModifiers(node, ts_mods);
        return node;
    }

    /// Parse a static block body `{ ... }` after `static` has been consumed.
    /// Handles scope isolation and stores TS modifiers on the resulting node.
    fn parseStaticBlockBody(self: *Parser, start_token: TokenIndex, mods: u32) Error!NodeIndex {
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        const saved_func = self.in_function;
        self.in_async = false;
        self.in_generator = false;
        self.in_function = true;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
            self.in_function = saved_func;
        }
        const body = try self.parseBlockStatement();
        const sb_node = try self.addNode(.{
            .tag = .class_static_block,
            .main_token = start_token,
            .data = .{ .unary = body },
        });
        try self.storeTsModifiers(sb_node, mods);
        return sb_node;
    }

    fn parseClassMethodOrField(self: *Parser, is_static: bool, member_start_token: TokenIndex, member_is_async: bool, member_is_generator: bool) Error!NodeIndex {
        // Build flags bitmask: bit 0 = static, bit 1 = computed, bit 2 = generator, bit 3 = async
        // Use the member-level flags (not self.in_async/in_generator which may
        // reflect the enclosing function scope, not the class member itself).
        var flags: u32 = 0;
        if (is_static) flags |= 1;
        if (member_is_generator) flags |= 4;
        if (member_is_async) flags |= 8;
        if (self.class_member_is_accessor) flags |= 64; // accessor property

        // Private field/method
        const is_private = self.currentTag() == .hash;
        if (is_private) {
            const hash_token = self.advance();
            const hash_end = self.token_ends[@intFromEnum(hash_token)];
            const next_tag = self.currentTag();
            const next_start = self.currentStart();

            // Validate: # must be immediately followed by an identifier (no spaces)
            if (next_tag == .identifier or next_tag.isKeyword()) {
                if (next_start != hash_end) {
                    // Space between # and identifier: `# x` — report error
                    self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(hash_token)]);
                }
            } else if (next_tag == .numeric) {
                // `#0`, `#2` — digit after hash
                self.errors.addError("Unexpected digit after hash token.", self.token_starts[@intFromEnum(hash_token)]);
            } else if (next_tag == .l_bracket) {
                // `#[m]` — computed private not allowed
                self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(hash_token)]);
            } else if (next_tag == .string) {
                // `#"x"` — string after hash
                self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(hash_token)]);
            } else if (next_tag == .invalid) {
                // e.g. `#2x` — invalid token after hash (digit followed by identifier chars)
                self.errors.addError("Unexpected digit after hash token.", next_start);
            }
        }

        // Computed key
        if (self.currentTag() == .l_bracket) {
            flags |= 2; // computed
            _ = self.advance(); // [
            const key = try self.parseAssignmentExpression();
            _ = try self.expect(.r_bracket);

            if (self.isTypeScript() and self.currentTag() == .question) {
                _ = self.advance();
                flags |= 16; // optional
            }

            // TypeScript: type parameters on computed method
            var comp_type_params: NodeIndex = .none;
            if (self.isTypeScript() and self.currentTag() == .less_than) {
                const parser_ts = @import("parser_ts.zig");
                comp_type_params = try parser_ts.parseTsTypeParameterDeclaration(self);
            }

            if (self.currentTag() == .l_paren) {
                // Computed method
                const params = try self.parseParameterList();
                // TypeScript: return type annotation
                var comp_ret_type: NodeIndex = .none;
                if (self.isTypeScript() and self.currentTag() == .colon) {
                    const parser_ts = @import("parser_ts.zig");
                    comp_ret_type = try parser_ts.parseTsReturnTypeAnnotation(self);
                }
                // TypeScript: method without body
                if (self.isTypeScript() and self.currentTag() != .l_brace) {
                    if (self.currentTag() == .semicolon) _ = self.advance();
                    const extra_start = try self.addExtra(@intFromEnum(key));
                    _ = try self.addExtra(params.start);
                    _ = try self.addExtra(params.end);
                    _ = try self.addExtra(@intFromEnum(NodeIndex.none));
                    _ = try self.addExtra(self.applyDeclareFlag(flags));
                    const comp_method = try self.addNode(.{
                        .tag = .ts_declare_method,
                        .main_token = member_start_token,
                        .data = .{ .extra = @enumFromInt(extra_start) },
                    });
                    if (comp_ret_type != .none) {
                        try self.putReturnType(comp_method, comp_ret_type);
                    }
                    if (comp_type_params != .none) {
                        try self.putTypeParameters(comp_method, comp_type_params);
                    }
                    return comp_method;
                }
                const body = try self.parseBlockStatement();
                const extra_start = try self.addExtra(@intFromEnum(key));
                _ = try self.addExtra(params.start);
                _ = try self.addExtra(params.end);
                _ = try self.addExtra(@intFromEnum(body));
                _ = try self.addExtra(self.applyDeclareFlag(flags));
                const comp_method = try self.addNode(.{
                    .tag = .class_method,
                    .main_token = member_start_token,
                    .data = .{ .extra = @enumFromInt(extra_start) },
                });
                if (comp_ret_type != .none) {
                    try self.putReturnType(comp_method, comp_ret_type);
                }
                if (comp_type_params != .none) {
                    try self.putTypeParameters(comp_method, comp_type_params);
                }
                return comp_method;
            }

            // TypeScript: type annotation on computed field
            if (self.isTypeScript() and self.currentTag() == .colon) {
                const parser_ts = @import("parser_ts.zig");
                const type_ann = try parser_ts.parseTsTypeAnnotation(self);
                try self.putTypeAnnotation(key, type_ann);
            }

            // Computed field
            const value = try self.parseFieldInitializer();
            try self.expectSemicolon();
            const cf_extra = try self.addExtra(@intFromEnum(key));
            _ = try self.addExtra(@intFromEnum(value));
            _ = try self.addExtra(self.applyDeclareFlag(flags));
            const cf_node = try self.addNode(.{
                .tag = .class_field,
                .main_token = member_start_token,
                .data = .{ .extra = @enumFromInt(cf_extra) },
            });
            // TypeScript: copy type annotation from key node to field node
            if (self.isTypeScript()) {
                if (self.flow_type_annotations.get(@intFromEnum(key))) |type_ann| {
                    try self.putTypeAnnotation(cf_node, type_ann);
                }
            }
            return cf_node;
        }

        // Named key — create the Identifier node immediately so its end_offset
        // is set correctly (before parsing params/body which advance token_index).
        const key_token = self.advance();
        const key = try self.addNode(.{ .tag = keyNodeTag(self.token_tags[@intFromEnum(key_token)]), .main_token = key_token, .data = .{ .none = {} } });

        // Flow: type parameters on method
        var method_type_params: NodeIndex = .none;
        if (self.isFlow() and self.currentTag() == .less_than) {
            const flow_m = @import("parser_flow.zig");
            method_type_params = try flow_m.parseFlowTypeParameterDeclaration(self);
        }

        // TypeScript: optional (?) marker on member name
        if (self.isTypeScript() and self.currentTag() == .question) {
            _ = self.advance();
            flags |= 16; // bit 4 = optional
        }

        // TypeScript: definite assignment (!) on field name
        if (self.isTypeScript() and self.currentTag() == .bang) {
            if ((flags & 16) != 0) {
                self.errors.addError("Unexpected token", self.currentStart());
            }
            _ = self.advance();
            flags |= 32; // bit 5 = definite
        }

        // TypeScript: handle type parameters on methods
        if (self.isTypeScript() and self.currentTag() == .less_than) {
            const parser_ts = @import("parser_ts.zig");
            method_type_params = try parser_ts.parseTsTypeParameterDeclaration(self);
        }

        // Method
        if (self.currentTag() == .l_paren) {
            // accessor keyword is not allowed on methods
            if ((flags & 64) != 0) {
                self.errors.addError("Unexpected token", self.currentStart());
                return error.ParseError;
            }
            const saved_func = self.in_function;
            self.in_function = true;
            defer self.in_function = saved_func;

            // Set constructor param state for TSParameterProperty
            const key_name = self.tokenText(@intFromEnum(key_token));
            const is_ctor = !is_private and std.mem.eql(u8, key_name, "constructor");
            const saved_ctor = self.in_constructor_params;
            if (is_ctor and self.isTypeScript()) self.in_constructor_params = true;
            defer self.in_constructor_params = saved_ctor;

            const params = try self.parseParameterList();

            // Flow: return type on method
            var method_ret_type: NodeIndex = .none;
            if (self.isFlow() and self.currentTag() == .colon) {
                const flow_m2 = @import("parser_flow.zig");
                method_ret_type = try flow_m2.parseFlowTypeAnnotation(self);
            }

            // TypeScript: return type annotation on method
            if (self.isTypeScript() and self.currentTag() == .colon) {
                const parser_ts = @import("parser_ts.zig");
                method_ret_type = try parser_ts.parseTsReturnTypeAnnotation(self);
            }

            if (!is_static and !is_private and self.tokenRepresentsConstructor(key_token)) {
                var i: usize = params.start;
                while (i < params.end) : (i += 1) {
                    if (self.getThisParamInfo(@enumFromInt(self.extra_data.items[i]), i - params.start)) |_| {
                        self.errors.addError(
                            "Constructors cannot have a `this` parameter; constructors don't bind `this` like other functions.",
                            self.token_starts[@intFromEnum(member_start_token)],
                        );
                        break;
                    }
                }
            }

            // TypeScript: method without body (overload signature, abstract method, declare class method)
            if (self.isTypeScript() and self.currentTag() != .l_brace) {
                if (self.currentTag() == .semicolon) _ = self.advance();

                const extra_start = try self.addExtra(@intFromEnum(key));
                _ = try self.addExtra(params.start);
                _ = try self.addExtra(params.end);
                _ = try self.addExtra(@intFromEnum(NodeIndex.none)); // no body
                _ = try self.addExtra(self.applyDeclareFlag(flags));

                const method_node = try self.addNode(.{
                    .tag = .ts_declare_method,
                    .main_token = member_start_token,
                    .data = .{ .extra = @enumFromInt(extra_start) },
                });
                if (method_ret_type != .none) {
                    try self.putReturnType(method_node, method_ret_type);
                }
                if (method_type_params != .none) {
                    try self.putTypeParameters(method_node, method_type_params);
                }
                return method_node;
            }

            const body = try self.parseBlockStatement();

            const extra_start = try self.addExtra(@intFromEnum(key));
            _ = try self.addExtra(params.start);
            _ = try self.addExtra(params.end);
            _ = try self.addExtra(@intFromEnum(body));
            _ = try self.addExtra(self.applyDeclareFlag(flags));

            const method_node = try self.addNode(.{
                .tag = if (is_private) .class_private_method else .class_method,
                .main_token = member_start_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
            if (method_ret_type != .none) {
                try self.putReturnType(method_node, method_ret_type);
            }
            if (method_type_params != .none) {
                try self.putTypeParameters(method_node, method_type_params);
            }
            return method_node;
        }

        // Flow: type annotation on field
        var flow_type_ann: NodeIndex = .none;
        if (self.isFlow() and self.currentTag() == .colon) {
            const flow_m3 = @import("parser_flow.zig");
            flow_type_ann = try flow_m3.parseFlowTypeAnnotation(self);
        }

        // TypeScript: type annotation on class field
        if (self.isTypeScript() and self.currentTag() == .colon) {
            const parser_ts = @import("parser_ts.zig");
            const type_ann = try parser_ts.parseTsTypeAnnotation(self);
            try self.putTypeAnnotation(key, type_ann);
        }

        // Field — reuse the key Identifier node created above.
        const value = try self.parseFieldInitializer();
        self.expectSemicolon() catch {};

        const field_extra = try self.addExtra(@intFromEnum(key));
        _ = try self.addExtra(@intFromEnum(value));
        _ = try self.addExtra(self.applyDeclareFlag(flags));

        const field_node = try self.addNode(.{
            .tag = if (is_private) .class_private_field else .class_field,
            .main_token = member_start_token,
            .data = .{ .extra = @enumFromInt(field_extra) },
        });

        // Store Flow type annotation against the field node
        if (flow_type_ann != .none) {
            try self.putTypeAnnotation(field_node, flow_type_ann);
        }

        // TypeScript: copy type annotation from key node to field node for serializer
        if (self.isTypeScript()) {
            if (self.flow_type_annotations.get(@intFromEnum(key))) |type_ann| {
                try self.putTypeAnnotation(field_node, type_ann);
            }
        }

        return field_node;
    }

    /// Apply the Flow `declare` modifier flag (bit 4) to class member flags.
    fn applyDeclareFlag(self: *Parser, flags: u32) u32 {
        if (self.class_member_is_declare) {
            self.class_member_is_declare = false;
            return flags | 16;
        }
        return flags;
    }

    /// Try to parse a TypeScript parameter property (e.g., `public x: number`).
    /// Returns the TSParameterProperty node if successful, or null if not a parameter property.
    fn tryParseTsParameterProperty(self: *Parser) ?NodeIndex {
        // Consume consecutive access/readonly modifiers, each validated by look-ahead
        // to distinguish `public x: T` (parameter property) from `public` (param name).
        var pp_flags: u32 = 0;
        const pp_start_token: TokenIndex = @enumFromInt(self.token_index);
        while (self.currentTag() == .identifier) {
            const mod_bit = tsModifierBitFromToken(self.currentTag(), self.currentSoftKeyword());
            if (mod_bit == 0) break;
            if (mod_bit != TS_MOD_PUBLIC and mod_bit != TS_MOD_PRIVATE and
                mod_bit != TS_MOD_PROTECTED and mod_bit != TS_MOD_READONLY and
                mod_bit != TS_MOD_OVERRIDE) break;
            // Next is ) , : = means this identifier is the param name, not a modifier
            const next_la = self.lookAhead(1);
            if (next_la == .r_paren or next_la == .comma or next_la == .colon or next_la == .equal) break;
            if (next_la == .question) {
                const next_la2 = self.lookAhead(2);
                if (next_la2 == .colon or next_la2 == .comma or next_la2 == .r_paren) break;
            }
            if (mod_bit == TS_MOD_PUBLIC) pp_flags |= (1 << 4);
            if (mod_bit == TS_MOD_PRIVATE) pp_flags |= (1 << 5);
            if (mod_bit == TS_MOD_PROTECTED) pp_flags |= (1 << 6);
            if (mod_bit == TS_MOD_READONLY) pp_flags |= (1 << 7);
            if (mod_bit == TS_MOD_OVERRIDE) pp_flags |= (1 << 8);
            _ = self.advance();
        }

        if (pp_flags == 0) return null;

        const param = self.parseBindingElement() catch return null;

        // Optional marker before type annotation
        if (self.currentTag() == .question) {
            _ = self.advance();
            self.ts_optional_params.put(self.allocator, @intFromEnum(param), {}) catch return null;
        }

        if (self.currentTag() == .colon) {
            const parser_ts = @import("parser_ts.zig");
            const type_ann = parser_ts.parseTsTypeAnnotation(self) catch return null;
            self.putTypeAnnotation(param, type_ann) catch return null;
        }

        // Default value wraps param in AssignmentPattern
        var final_param = param;
        if (self.currentTag() == .equal) {
            _ = self.advance();
            const default_val = self.parseAssignmentExpression() catch return null;
            final_param = self.addNode(.{
                .tag = .assignment_pattern,
                .main_token = @enumFromInt(self.token_index),
                .data = .{ .binary = .{ .lhs = param, .rhs = default_val } },
            }) catch return null;
        }

        const extra_start = self.addExtra(@intFromEnum(final_param)) catch return null;
        _ = self.addExtra(pp_flags) catch return null;

        return self.addNode(.{
            .tag = .ts_parameter_property,
            .main_token = pp_start_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        }) catch null;
    }

    /// Parse the optional `= <value>` initializer of a class field.
    /// Class field initializers run in their own scope where await/yield
    /// are identifiers, not operators.
    fn parseFieldInitializer(self: *Parser) Error!NodeIndex {
        if (self.pending_equal) {
            // The `=` was split from a compound token (e.g. `*=` in Flow type context)
            self.pending_equal = false;
        } else if (self.eat(.equal) == null) {
            return .none;
        }
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        const saved_field_init = self.in_class_field_init;
        self.in_async = false;
        self.in_generator = false;
        self.in_class_field_init = true;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
            self.in_class_field_init = saved_field_init;
        }
        return self.parseAssignmentExpression();
    }

    // === Import/Export ===

    fn parseImportOrImportExpr(self: *Parser) Error!NodeIndex {
        // import() or import.meta are expressions
        if (self.lookAhead(1) == .l_paren or self.lookAhead(1) == .dot) {
            return self.parseExpressionStatement();
        }
        return self.parseImportDeclaration();
    }

    const FlowImportKind = enum(u2) {
        value,
        type,
        typeof,
    };

    fn isFlowReservedTypeName(self: *const Parser, tok: TokenIndex) bool {
        const idx = @intFromEnum(tok);
        return switch (self.softKeywordAt(idx)) {
            .any, .bool_, .boolean, .empty, .mixed, .number, .string => true,
            else => switch (self.token_tags[idx]) {
                .kw_null, .kw_true, .kw_false, .kw_void => true,
                else => false,
            },
        };
    }

    fn validateFlowImportTypeName(self: *Parser, tok: TokenIndex, kind: FlowImportKind) void {
        if (!self.isFlow() or kind == .value) return;
        if (self.isFlowReservedTypeName(tok)) {
            var msg_buf: [96]u8 = undefined;
            const text = self.tokenText(@intFromEnum(tok));
            const msg = std.fmt.bufPrint(&msg_buf, "Cannot overwrite reserved type {s}.", .{text}) catch "Cannot overwrite reserved type.";
            self.errors.addError(msg, self.token_starts[@intFromEnum(tok)]);
        }
    }

    fn parseImportLocalToken(self: *Parser) Error!TokenIndex {
        if (self.currentTag().isReservedKeyword()) {
            var msg_buf: [96]u8 = undefined;
            const text = self.tokenText(self.token_index);
            const msg = std.fmt.bufPrint(&msg_buf, "Unexpected keyword '{s}'.", .{text}) catch "Unexpected keyword.";
            self.errors.addError(msg, self.currentStart());
            return self.advance();
        }
        if (self.currentTag() == .identifier or self.currentTag().isKeyword()) {
            return self.advance();
        }
        return self.expect(.identifier);
    }

    pub fn parseImportDeclaration(self: *Parser) Error!NodeIndex {
        const import_token = self.advance(); // import
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        // Source-phase imports: `import source x from "mod"`
        var import_phase: ?[]const u8 = null;
        if (self.opts.enable_import_source_phase and self.currentTag() == .identifier and
            self.currentSoftKeyword() == .source)
        {
            // `import source x from "mod"` — source is followed by an identifier
            const la1_sp = self.lookAhead(1);
            if (la1_sp == .identifier or la1_sp == .asterisk or la1_sp == .kw_from) {
                // Check for `import source from from "x"` — binding name is "from"
                if (la1_sp == .kw_from) {
                    // Check if the token after "from" is also "from" — then source is phase
                    const la2_sp = self.lookAhead(2);
                    if (la2_sp == .kw_from) {
                        import_phase = "source";
                        _ = self.advance(); // skip 'source'
                    }
                    // else: `import source from "x"` — source is the default binding name
                } else if (la1_sp == .identifier and std.mem.eql(u8, self.tokenText(self.token_index + 1), "from")) {
                    // `import source from "x"` — source is default binding, from is keyword
                    // Don't set import_phase
                } else {
                    import_phase = "source";
                    _ = self.advance(); // skip 'source'
                }
            } else if (la1_sp == .l_brace) {
                // `import source { x } from "x"` — parse but emit error
                const source_start = self.currentStart();
                import_phase = "source";
                _ = self.advance(); // skip 'source'
                self.errors.addError("Only `import source x from \"./module\"` is valid.", source_start);
            }
        }
        // Deferred import: `import defer * as ns from "mod"`
        if (self.opts.enable_deferred_import and import_phase == null and self.currentTag() == .identifier and
            self.currentSoftKeyword() == .defer_)
        {
            const la1_di = self.lookAhead(1);
            if (la1_di == .asterisk) {
                import_phase = "defer";
                _ = self.advance(); // skip 'defer'
            } else if (la1_di == .identifier or la1_di == .l_brace or la1_di.isKeyword()) {
                // `import defer x` or `import defer { x }` — parse but emit error
                const defer_start = self.currentStart();
                import_phase = "defer";
                _ = self.advance(); // skip 'defer'
                self.errors.addError("Only `import defer * as x from \"./module\"` is valid.", defer_start);
            }
        }

        var flow_import_kind: FlowImportKind = .value;
        // Flow/TS: skip 'type' keyword in `import type ...`
        var is_type_import = false;
        if ((self.isFlow() or self.isTypeScript()) and self.currentTag() == .identifier and
            self.currentSoftKeyword() == .type_)
        {
            const la1 = self.lookAhead(1);
            // TS: `import type X = ...` → TSImportEqualsDeclaration with importKind=type
            if (self.isTypeScript() and la1 == .identifier and self.lookAhead(2) == .equal) {
                _ = self.advance(); // skip 'type'
                return self.parseTsImportEqualsDeclaration(import_token, true);
            }
            // Check that it's not `import type from '...'` (where 'type' is the default import)
            if (la1 != .identifier and la1 != .l_brace and la1 != .asterisk and
                !(self.isFlow() and la1.isReservedKeyword()))
            {
                // TS: `import type = require(...)` → TSImportEqualsDeclaration where "type" is the id
                if (self.isTypeScript() and la1 == .equal) {
                    return self.parseTsImportEqualsDeclaration(import_token, false);
                }
                // 'type' is the default import name, not a type keyword
            } else {
                _ = self.advance(); // skip 'type'
                is_type_import = true;
                if (self.isFlow()) flow_import_kind = .type;
            }
        } else if (self.isFlow()) {
            if (self.currentTag() == .kw_typeof and
                (self.lookAhead(1) == .identifier or self.lookAhead(1) == .l_brace or self.lookAhead(1) == .asterisk))
            {
                _ = self.advance();
                flow_import_kind = .typeof;
            }
        }

        // TS: `import X = ...` → TSImportEqualsDeclaration (non-type)
        if (self.isTypeScript() and !is_type_import and self.currentTag() == .identifier and self.lookAhead(1) == .equal) {
            return self.parseTsImportEqualsDeclaration(import_token, false);
        }

        // Placeholder as source: `import %%FILE%%;` (side-effect with placeholder source)
        if (self.isPlaceholder() and self.lookAhead(5) == .semicolon) {
            const ph_source = try self.parsePlaceholder("StringLiteral");
            try self.expectSemicolon();
            // Store placeholder source in side table — use @intFromEnum as source_token slot
            const side_extra = try self.addExtra(0); // dummy source_token
            const empty_start2: u32 = @intCast(self.extra_data.items.len + 2);
            _ = try self.addExtra(empty_start2);
            _ = try self.addExtra(empty_start2);
            const pos2: u32 = @intCast(self.extra_data.items.len);
            _ = try self.addExtra(pos2);
            _ = try self.addExtra(pos2);
            const import_node = try self.addNode(.{
                .tag = .import_declaration,
                .main_token = import_token,
                .data = .{ .extra = @enumFromInt(side_extra) },
            });
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(import_node), ph_source);
            return import_node;
        }

        // import 'source' (side-effect import)
        if (self.currentTag() == .string) {
            const source_token = self.advance();
            // Parse import attributes: `with { ... }` or `assert { ... }`
            const attrs_range = try self.parseImportAttributes();
            try self.expectSemicolon();
            // Use same extra format as other imports: source_token, specs_start, specs_end, attrs_start, attrs_end
            const side_extra = try self.addExtra(@intFromEnum(source_token));
            const empty_start: u32 = @intCast(self.extra_data.items.len + 2);
            _ = try self.addExtra(empty_start);
            _ = try self.addExtra(empty_start);
            _ = try self.addExtra(attrs_range.start);
            _ = try self.addExtra(attrs_range.end);
            return self.addNode(.{
                .tag = .import_declaration,
                .main_token = import_token,
                .data = .{ .extra = @enumFromInt(side_extra) },
            });
        }

        // import * as ns from 'source'
        if (self.currentTag() == .asterisk) {
            if (flow_import_kind == .type) {
                self.errors.addError("Unexpected token", self.currentStart());
            }
            const star_tok_pos = self.currentStart();
            _ = self.advance(); // *
            _ = try self.expect(.kw_as);
            // Placeholder as namespace import: `import * as %%NS%%`
            if (self.isPlaceholder()) {
                const ph_ns = try self.parsePlaceholder("Identifier");
                const ns_node = try self.addNode(.{
                    .tag = .import_namespace,
                    .main_token = self.nodes.items(.main_token)[@intFromEnum(ph_ns)],
                    .data = .{ .none = {} },
                });
                try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(ns_node), ph_ns);
                try self.node_start_overrides.put(self.allocator, @intFromEnum(ns_node), star_tok_pos);
                try self.scratch.append(self.allocator, ns_node);
            } else {
                const ns_token = try self.expect(.identifier);
                self.validateFlowImportTypeName(ns_token, flow_import_kind);
                const ns_node = try self.addNode(.{
                    .tag = .import_namespace,
                    .main_token = ns_token,
                    .data = .{ .none = {} },
                });
                try self.scratch.append(self.allocator, ns_node);
            }
        } else if (self.currentTag() == .l_brace) {
            // import { a, b as c } from 'source'
            _ = self.advance(); // {
            while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
                const spec = try self.parseImportSpecifier(flow_import_kind);
                try self.scratch.append(self.allocator, spec);
                if (self.currentTag() != .r_brace) {
                    _ = try self.expect(.comma);
                }
            }
            _ = try self.expect(.r_brace);
        } else {
            // import default from 'source'
            // import default, { named } from 'source'
            // import default, * as ns from 'source'
            // Placeholder as default import name: wraps in ImportDefaultSpecifier
            if (self.isPlaceholder()) {
                const ph = try self.parsePlaceholder("Identifier");
                const default_node = try self.addNode(.{
                    .tag = .import_default,
                    .main_token = self.nodes.items(.main_token)[@intFromEnum(ph)],
                    .data = .{ .none = {} },
                });
                try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(default_node), ph);
                try self.scratch.append(self.allocator, default_node);
                // Check for comma after placeholder to allow: import %%X%%, { y } from "mod"
                if (self.eat(.comma) != null) {
                    if (self.currentTag() == .asterisk) {
                        const star_tok2 = self.advance(); // *
                        const star_tok_pos2 = self.token_starts[@intFromEnum(star_tok2)];
                        _ = try self.expect(.kw_as);
                        if (self.isPlaceholder()) {
                            const ph_ns2 = try self.parsePlaceholder("Identifier");
                            const ns_n2 = try self.addNode(.{
                                .tag = .import_namespace,
                                .main_token = self.nodes.items(.main_token)[@intFromEnum(ph_ns2)],
                                .data = .{ .none = {} },
                            });
                            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(ns_n2), ph_ns2);
                            try self.node_start_overrides.put(self.allocator, @intFromEnum(ns_n2), star_tok_pos2);
                            try self.scratch.append(self.allocator, ns_n2);
                        } else {
                            const ns_token2 = try self.expect(.identifier);
                            const ns_n2 = try self.addNode(.{
                                .tag = .import_namespace,
                                .main_token = ns_token2,
                                .data = .{ .none = {} },
                            });
                            try self.scratch.append(self.allocator, ns_n2);
                        }
                    } else if (self.currentTag() == .l_brace) {
                        _ = self.advance();
                        while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
                            const spec2 = try self.parseImportSpecifier(flow_import_kind);
                            try self.scratch.append(self.allocator, spec2);
                            if (self.currentTag() != .r_brace) _ = try self.expect(.comma);
                        }
                        _ = try self.expect(.r_brace);
                    }
                }
            } else {
                // If the token is a reserved keyword (e.g., `default`), emit an error
                // but still parse it as an identifier (error recovery like Babel).
                // In Flow, `import type <keyword>` allows keywords without error.
                const default_token = if (self.currentTag().isReservedKeyword()) blk: {
                    if (!is_type_import or !self.isFlow()) {
                        self.errors.addError("Unexpected keyword", self.currentStart());
                    }
                    break :blk self.advance();
                } else if (self.currentTag().isKeyword() and !self.currentTag().isReservedKeyword()) blk: {
                    // Contextual keywords (from, as, get, set, etc.) can be used as binding names
                    break :blk self.advance();
                } else try self.expect(.identifier);
                self.validateFlowImportTypeName(default_token, flow_import_kind);
                const default_node = try self.addNode(.{
                    .tag = .import_default,
                    .main_token = default_token,
                    .data = .{ .none = {} },
                });
                try self.scratch.append(self.allocator, default_node);

                if (self.eat(.comma) != null) {
                    if (self.currentTag() == .asterisk) {
                        if (flow_import_kind == .type) {
                            self.errors.addError("Unexpected token", self.currentStart());
                        }
                        const star_pos2 = self.currentStart();
                        _ = self.advance(); // *
                        _ = try self.expect(.kw_as);
                        // Placeholder as namespace after comma
                        if (self.isPlaceholder()) {
                            const ph_ns3 = try self.parsePlaceholder("Identifier");
                            const ns_node = try self.addNode(.{
                                .tag = .import_namespace,
                                .main_token = self.nodes.items(.main_token)[@intFromEnum(ph_ns3)],
                                .data = .{ .none = {} },
                            });
                            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(ns_node), ph_ns3);
                            try self.node_start_overrides.put(self.allocator, @intFromEnum(ns_node), star_pos2);
                            try self.scratch.append(self.allocator, ns_node);
                        } else {
                            const ns_token = try self.expect(.identifier);
                            self.validateFlowImportTypeName(ns_token, flow_import_kind);
                            const ns_node = try self.addNode(.{
                                .tag = .import_namespace,
                                .main_token = ns_token,
                                .data = .{ .none = {} },
                            });
                            try self.scratch.append(self.allocator, ns_node);
                        }
                    } else if (self.currentTag() == .l_brace) {
                        _ = self.advance(); // {
                        while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
                            const spec = try self.parseImportSpecifier(flow_import_kind);
                            try self.scratch.append(self.allocator, spec);
                            if (self.currentTag() != .r_brace) {
                                _ = try self.expect(.comma);
                            }
                        }
                        _ = try self.expect(.r_brace);
                    } else {
                        // After `import foo,` we expect `{` or `*`
                        self.errors.addError("Unexpected token, expected \"{\"", self.currentStart());
                        return error.ParseError;
                    }
                }
            } // close else for placeholder check
        }

        _ = try self.expect(.kw_from);
        // Placeholder as source: `from %%FILE%%`
        var ph_source_node: NodeIndex = .none;
        var source_token: TokenIndex = undefined;
        if (self.isPlaceholder()) {
            ph_source_node = try self.parsePlaceholder("StringLiteral");
            source_token = @enumFromInt(0); // dummy
        } else {
            source_token = try self.expect(.string);
        }
        // Parse import attributes: `with { ... }` or `assert { ... }`
        const attrs_range = try self.parseImportAttributes();
        try self.expectSemicolon();

        const specifiers = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(specifiers);
        const extra_start = try self.addExtra(@intFromEnum(source_token));
        _ = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        _ = try self.addExtra(attrs_range.start);
        _ = try self.addExtra(attrs_range.end);

        const import_node = try self.addNode(.{
            .tag = if (is_type_import and !self.isFlow())
                .import_declaration_type
            else switch (flow_import_kind) {
                .value => .import_declaration,
                .type => .import_declaration_type,
                .typeof => .import_declaration_typeof,
            },
            .main_token = import_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
        if (ph_source_node != .none) {
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(import_node), ph_source_node);
        }
        // Store import phase (source/defer)
        if (import_phase) |phase| {
            const phase_val: u32 = if (std.mem.eql(u8, phase, "source")) IMPORT_PHASE_SOURCE else IMPORT_PHASE_DEFER;
            try self.ts_class_modifiers.put(self.allocator, @intFromEnum(import_node), phase_val);
        }
        return import_node;
    }

    const IMPORT_PHASE_SOURCE: u32 = 0x100;
    const IMPORT_PHASE_DEFER: u32 = 0x200;

    /// Parse import attributes: `with { key: "value", ... }` or `assert { ... }`.
    /// Returns a range of import_attribute node indices.
    fn parseImportAttributes(self: *Parser) Error!Range {
        // Check for `with` or `assert` keyword (both are identifiers in our lexer)
        // Must be followed by `{` (not `(` which would be a `with` statement)
        if (((self.currentTag() == .identifier and
            (self.currentSoftKeyword() == .with_ or self.currentSoftKeyword() == .assert)) or
            self.currentTag() == .kw_with) and
            self.lookAhead(1) == .l_brace)
        {
            _ = self.advance(); // skip 'with' or 'assert'
            _ = try self.expect(.l_brace);

            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);

            while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
                // key: either identifier or string
                const key = if (self.currentTag() == .string)
                    try self.addNode(.{ .tag = .string_literal, .main_token = self.advance(), .data = .{ .none = {} } })
                else
                    try self.addNode(.{ .tag = .identifier, .main_token = self.advance(), .data = .{ .none = {} } });
                _ = try self.expect(.colon);
                const value = try self.addNode(.{ .tag = .string_literal, .main_token = try self.expect(.string), .data = .{ .none = {} } });
                const attr = try self.addNode(.{
                    .tag = .import_attribute,
                    .main_token = self.nodes.items(.main_token)[@intFromEnum(key)],
                    .data = .{ .binary = .{ .lhs = key, .rhs = value } },
                });
                try self.scratch.append(self.allocator, attr);
                if (self.currentTag() != .r_brace) {
                    _ = try self.expect(.comma);
                }
            }
            _ = try self.expect(.r_brace);

            const attrs = self.scratch.items[scratch_start..];
            return self.addExtraRange(attrs);
        }
        // No attributes
        const pos: u32 = @intCast(self.extra_data.items.len);
        return .{ .start = pos, .end = pos };
    }

    /// Check if current token is `type` used as an inline type modifier in `{ type Foo }`.
    /// If so, consume it and return the token. Handles disambiguation for edge cases like
    /// `{ type }`, `{ type as }`, `{ type as X }`, and `{ type as as X }`.
    fn tryConsumeInlineTypeModifier(self: *Parser) struct { is_type: bool, token: TokenIndex } {
        const none: TokenIndex = @enumFromInt(0);
        if (!self.isTypeScript() or self.currentTag() != .identifier or
            self.currentSoftKeyword() != .type_)
            return .{ .is_type = false, .token = none };

        const la1 = self.lookAhead(1);
        if (la1 == .comma or la1 == .r_brace) {
            // `{ type }` or `{ type, ... }` — "type" is a binding name, not a modifier
            return .{ .is_type = false, .token = none };
        }
        if (la1 == .kw_as) {
            const la2 = self.lookAhead(2);
            if (la2 == .comma or la2 == .r_brace) {
                // `{ type as }` — type modifier for "as"
                return .{ .is_type = true, .token = self.advance() };
            }
            if (self.lookAhead(3) == .comma or self.lookAhead(3) == .r_brace) {
                // `{ type as X }` — rename "type" to X, not a modifier
                return .{ .is_type = false, .token = none };
            }
        }
        // `{ type Foo }`, `{ type Foo as Bar }`, `{ type as as X }`, etc.
        return .{ .is_type = true, .token = self.advance() };
    }

    // Side table for import/export specifier local placeholders
    // Key: specifier node index, Value: placeholder NodeIndex for the "local" field
    // (separate from placeholder_name_nodes which stores the "imported"/"exported" placeholder)
    fn getSpecLocalPlaceholder(self: *const Parser, node_idx: u32) ?NodeIndex {
        // We repurpose flow_variance_map for storing specifier local placeholders
        // This is safe because flow_variance_map is only used for Flow type variance
        // which never overlaps with import/export specifier nodes.
        return self.flow_variance_map.get(node_idx);
    }

    fn parseImportSpecifier(self: *Parser, decl_kind: FlowImportKind) Error!NodeIndex {
        // Placeholder in import specifier: `{ %%NAMED%% }` or `{ %%NAMED%% as alias }` or `{ name as %%ALIAS%% }`
        if (self.isPlaceholder()) {
            const ph_start_tok: TokenIndex = @enumFromInt(self.token_index);
            const ph_imported = try self.parsePlaceholder("Identifier");
            // Check for `as` alias after placeholder
            if (self.eat(.kw_as) != null) {
                // `{ %%NAMED%% as alias }` or `{ %%NAMED%% as %%ALIAS%% }`
                var local_ph: ?NodeIndex = null;
                if (self.isPlaceholder()) {
                    local_ph = try self.parsePlaceholder("Identifier");
                }
                var local_tok_val: u32 = 0;
                if (local_ph == null) {
                    const lt = try self.parseImportLocalToken();
                    local_tok_val = @intFromEnum(lt);
                }
                const i_extra_start = try self.addExtra(0);
                _ = try self.addExtra(local_tok_val);
                const spec_node = try self.addNode(.{
                    .tag = .import_specifier,
                    .main_token = ph_start_tok,
                    .data = .{ .extra = @enumFromInt(i_extra_start) },
                });
                try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(spec_node), ph_imported);
                if (local_ph) |lp| {
                    try self.flow_variance_map.put(self.allocator, @intFromEnum(spec_node), lp);
                }
                return spec_node;
            }
            // No alias — placeholder is both imported and local
            const i_extra_start = try self.addExtra(0);
            _ = try self.addExtra(0);
            const spec_node = try self.addNode(.{
                .tag = .import_specifier,
                .main_token = ph_start_tok,
                .data = .{ .extra = @enumFromInt(i_extra_start) },
            });
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(spec_node), ph_imported);
            return spec_node;
        }

        var spec_kind: FlowImportKind = .value;
        var start_token: TokenIndex = @enumFromInt(self.token_index);
        var imported_token: TokenIndex = undefined;

        if (self.isFlow()) {
            const is_type_kw = self.currentTag() == .identifier and self.currentSoftKeyword() == .type_;
            const is_typeof_kw = self.currentTag() == .kw_typeof;
            if (is_type_kw or is_typeof_kw) {
                const kw_kind: FlowImportKind = if (is_type_kw) .type else .typeof;
                const la1 = self.lookAhead(1);
                const la2 = self.lookAhead(2);
                const use_shorthand = if (la1 == .kw_as)
                    la2 == .kw_as or la2 == .comma or la2 == .r_brace
                else
                    la1 != .comma and la1 != .r_brace;
                if (use_shorthand) {
                    start_token = self.advance();
                    spec_kind = kw_kind;
                    if (decl_kind != .value) {
                        self.errors.addError(
                            "The `type` and `typeof` keywords on named imports can only be used on regular `import` statements. It cannot be used with `import type` or `import typeof` statements.",
                            self.token_starts[@intFromEnum(start_token)],
                        );
                    }
                    imported_token = self.advance();
                    self.validateFlowImportTypeName(imported_token, spec_kind);
                } else {
                    imported_token = self.advance();
                }
            } else {
                imported_token = self.advance();
            }
        } else {
            // TypeScript: handle inline `type` modifier in `{ type Foo }` or `{ type Foo as Bar }`
            const ts_type_info = self.tryConsumeInlineTypeModifier();
            if (ts_type_info.is_type) {
                start_token = ts_type_info.token;
                spec_kind = .type;
            }
            imported_token = self.advance();
        }

        const is_string_import = self.token_tags[@intFromEnum(imported_token)] == .string;
        if (self.eat(.kw_as) != null) {
            // Placeholder as local: `{ name as %%ALIAS%% }`
            if (self.isPlaceholder()) {
                const local_ph = try self.parsePlaceholder("Identifier");
                const i_extra2 = try self.addExtra(@intFromEnum(imported_token));
                _ = try self.addExtra(0);
                const spec_n2 = try self.addNode(.{
                    .tag = switch (spec_kind) {
                        .value => .import_specifier,
                        .type => .import_specifier_type,
                        .typeof => .import_specifier_typeof,
                    },
                    .main_token = start_token,
                    .data = .{ .extra = @enumFromInt(i_extra2) },
                });
                try self.flow_variance_map.put(self.allocator, @intFromEnum(spec_n2), local_ph);
                return spec_n2;
            }
            const local_token = try self.parseImportLocalToken();
            self.validateFlowImportTypeName(local_token, spec_kind);
            const extra_start = try self.addExtra(@intFromEnum(imported_token));
            _ = try self.addExtra(@intFromEnum(local_token));
            return self.addNode(.{
                .tag = switch (spec_kind) {
                    .value => .import_specifier,
                    .type => .import_specifier_type,
                    .typeof => .import_specifier_typeof,
                },
                .main_token = start_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
        }
        // No alias — string literals cannot be used as local bindings
        if (is_string_import) {
            self.errors.addError("A string literal cannot be used as an imported binding.", self.token_starts[@intFromEnum(imported_token)]);
        }
        self.validateFlowImportTypeName(imported_token, spec_kind);
        // Store same token for both imported and local
        const extra_start = try self.addExtra(@intFromEnum(imported_token));
        _ = try self.addExtra(@intFromEnum(imported_token));
        return self.addNode(.{
            .tag = switch (spec_kind) {
                .value => .import_specifier,
                .type => .import_specifier_type,
                .typeof => .import_specifier_typeof,
            },
            .main_token = start_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    /// Parse TSImportEqualsDeclaration: `import X = require("foo")` or `import X = A.B`
    /// Called after `import` has been consumed. The current token should be the identifier.
    fn parseTsImportEqualsDeclaration(self: *Parser, import_token: TokenIndex, is_type: bool) Error!NodeIndex {
        const id_token = self.advance(); // identifier name
        _ = try self.expect(.equal); // =

        // Parse the module reference: either require("...") or A.B.C
        const module_ref = if (self.currentTag() == .identifier and
            self.currentSoftKeyword() == .require and
            self.lookAhead(1) == .l_paren)
            try self.parseTsExternalModuleReference()
        else
            try self.parseTsQualifiedNameOrIdent();

        try self.expectSemicolon();

        // Extra format: id_token, module_reference, is_type_flag
        const extra_start = try self.addExtra(@intFromEnum(id_token));
        _ = try self.addExtra(@intFromEnum(module_ref));
        _ = try self.addExtra(@as(u32, if (is_type) 1 else 0));

        return self.addNode(.{
            .tag = .ts_import_equals_declaration,
            .main_token = import_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    /// Parse `require("...")` as TSExternalModuleReference
    fn parseTsExternalModuleReference(self: *Parser) Error!NodeIndex {
        const require_token = self.advance(); // require
        _ = try self.expect(.l_paren);
        const string_token = try self.expect(.string);
        const str_node = try self.addNode(.{
            .tag = .string_literal,
            .main_token = string_token,
            .data = .{ .none = {} },
        });
        _ = try self.expect(.r_paren);
        return self.addNode(.{
            .tag = .ts_external_module_reference,
            .main_token = require_token,
            .data = .{ .unary = str_node },
        });
    }

    /// Parse a qualified name: `A` or `A.B` or `A.B.C`
    /// Accepts keywords with error recovery (e.g. `Y.if`, `this.A`).
    fn parseTsQualifiedNameOrIdent(self: *Parser) Error!NodeIndex {
        const left_token = if (self.currentTag() == .identifier)
            self.advance()
        else if (self.currentTag().isKeyword()) blk: {
            const kw_text = self.tokenText(self.token_index);
            const msg = std.fmt.allocPrint(self.allocator, "Unexpected keyword '{s}'.", .{kw_text}) catch "Unexpected keyword.";
            self.errors.addError(msg, self.currentStart());
            break :blk self.advance();
        } else try self.expect(.identifier);
        var left = try self.addNode(.{
            .tag = .identifier,
            .main_token = left_token,
            .data = .{ .none = {} },
        });
        while (self.eat(.dot) != null) {
            // Accept keywords after dot with error recovery
            const right_token = if (self.currentTag() == .identifier)
                self.advance()
            else if (self.currentTag().isKeyword()) blk: {
                const kw_text = self.tokenText(self.token_index);
                const msg = std.fmt.allocPrint(self.allocator, "Unexpected keyword '{s}'.", .{kw_text}) catch "Unexpected keyword.";
                self.errors.addError(msg, self.currentStart());
                break :blk self.advance();
            } else try self.expect(.identifier);
            const right = try self.addNode(.{
                .tag = .identifier,
                .main_token = right_token,
                .data = .{ .none = {} },
            });
            left = try self.addNode(.{
                .tag = .ts_qualified_name,
                .main_token = left_token,
                .data = .{ .binary = .{ .lhs = left, .rhs = right } },
            });
        }
        return left;
    }

    pub fn parseExportDeclaration(self: *Parser) Error!NodeIndex {
        if (self.source_type == .script) {
            self.errors.addError("'import' and 'export' may appear only with 'sourceType: \"module\"'", self.currentStart());
        }
        const export_token = self.advance(); // export

        // exportDefaultFrom plugin: `export <identifier> from 'source'` or `export default from 'source'`
        if (self.opts.enable_export_default_from) {
            // Check for `export default from 'source'` (default is keyword, from is keyword, then string)
            const is_default_from = self.currentTag() == .kw_default and
                ((self.lookAhead(1) == .kw_from and self.lookAhead(2) == .string) or
                    self.lookAhead(1) == .comma);
            // Check for `export <identifier> from 'source'` or `export <identifier>,`
            // Exclude `type` when Flow or TypeScript is enabled (it's a keyword there)
            const is_type_keyword = self.currentTag() == .identifier and
                self.currentSoftKeyword() == .type_ and
                (self.isFlow() or self.isTypeScript());
            const is_ident_from = self.currentTag() == .identifier and !is_type_keyword and
                ((self.lookAhead(1) == .kw_from and self.lookAhead(2) == .string) or
                    self.lookAhead(1) == .comma);
            if (is_default_from or is_ident_from) {
                return self.parseExportDefaultFrom(export_token);
            }
        }

        // Decorators after export: `export @dec class Foo {}`
        var export_dec_range: ?@import("ast.zig").ExtraRange = null;
        if (self.opts.enable_decorators and self.isAtDecorator()) {
            export_dec_range = try self.parseDecorators();
        }

        // export default ...
        if (self.eat(.kw_default) != null) {
            // Decorators after export default: `export default @dec class Foo {}`
            if (self.opts.enable_decorators and self.isAtDecorator() and export_dec_range == null) {
                export_dec_range = try self.parseDecorators();
            }
            const value = if (self.currentTag() == .kw_function)
                try self.parseFunctionDeclInner(false, true)
            else if (self.currentTag() == .kw_class)
                try self.parseClassDeclInner(true)
            else if (self.isFlow() and self.currentTag() == .identifier and self.currentSoftKeyword() == .enum_)
                try @import("parser_flow.zig").parseFlowEnumDeclaration(self)
            else if (self.isTypeScript() and self.currentTag() == .identifier and
                self.currentSoftKeyword() == .abstract_ and
                self.lookAhead(1) == .kw_class)
            blk_abs: {
                const abs_tok = self.advance();
                const cls = try self.parseClassDeclInner(true);
                try self.storeTsModifiers(cls, TS_MOD_ABSTRACT);
                self.nodes.items(.main_token)[@intFromEnum(cls)] = abs_tok;
                break :blk_abs cls;
            } else if (self.currentTag() == .kw_async and self.lookAhead(1) == .kw_function and
                !self.hasNewlineAfterCurrent() and !self.currentTokenHasEscape())
            blk2: {
                const async_tok2 = self.advance(); // async
                const async_res2 = try self.parseFunctionDeclInner(true, true);
                self.nodes.items(.main_token)[@intFromEnum(async_res2)] = async_tok2;
                break :blk2 async_res2;
            } else if (self.isTypeScript() and self.currentTag() == .identifier and
                self.currentSoftKeyword() == .interface and
                !self.hasNewlineAfterCurrent())
            blk_iface: {
                break :blk_iface try @import("parser_ts.zig").parseTsInterfaceDeclaration(self);
            } else blk: {
                const expr = try self.parseAssignmentExpression();
                self.expectSemicolon() catch {};
                break :blk expr;
            };
            // Attach decorators to the class inside the export
            if (export_dec_range) |dr| {
                const val_tag = self.nodes.items(.tag)[@intFromEnum(value)];
                if (val_tag == .class_declaration or val_tag == .class_expr) {
                    try self.decorators_map.put(self.allocator, @intFromEnum(value), dr);
                    const first_dec_idx3: NodeIndex = @enumFromInt(self.extra_data.items[dr.start]);
                    const first_dec_mt3 = self.nodes.items(.main_token)[@intFromEnum(first_dec_idx3)];
                    const first_dec_start3 = self.token_starts[@intFromEnum(first_dec_mt3)];
                    try self.node_start_overrides.put(self.allocator, @intFromEnum(value), first_dec_start3);
                }
                export_dec_range = null;
            }
            return self.addNode(.{
                .tag = .export_default,
                .main_token = export_token,
                .data = .{ .unary = value },
            });
        }

        // TypeScript: export = expr;
        if (self.isTypeScript() and self.currentTag() == .equal) {
            _ = self.advance(); // =
            const expr = try self.parseAssignmentExpression();
            self.expectSemicolon() catch {};
            return self.addNode(.{
                .tag = .ts_export_assignment,
                .main_token = export_token,
                .data = .{ .unary = expr },
            });
        }

        // TypeScript: export as namespace X;
        if (self.isTypeScript() and self.currentTag() == .kw_as and
            self.lookAhead(1) == .identifier and
            self.softKeywordAt(self.token_index + 1) == .namespace)
        {
            _ = self.advance(); // as
            _ = self.advance(); // namespace
            const ns_id = self.advance(); // identifier
            self.expectSemicolon() catch {};
            return self.addNode(.{
                .tag = .ts_namespace_export_declaration,
                .main_token = export_token,
                .data = .{ .token = ns_id },
            });
        }

        // export * from 'source' OR export * as ns from 'source'
        if (self.currentTag() == .asterisk) {
            const star_token = self.advance(); // *
            if (self.eat(.kw_as) != null) {
                // export * as ns from 'source' — ExportNamedDeclaration with ExportNamespaceSpecifier
                // Placeholder as namespace name
                var ens_ph: NodeIndex = .none;
                var ns_name_token: TokenIndex = undefined;
                if (self.isPlaceholder()) {
                    ens_ph = try self.parsePlaceholder("Identifier");
                    ns_name_token = self.nodes.items(.main_token)[@intFromEnum(ens_ph)];
                } else {
                    // The name can be an identifier, keyword, or string literal
                    ns_name_token = if (self.currentTag() == .identifier or self.currentTag() == .string or self.currentTag() == .kw_default or self.currentTag().isKeyword())
                        self.advance()
                    else
                        try self.expect(.identifier);
                }
                const ns_spec = try self.addNode(.{
                    .tag = .export_namespace_specifier,
                    .main_token = star_token,
                    .data = .{ .unary = @enumFromInt(@intFromEnum(ns_name_token)) },
                });
                if (ens_ph != .none) {
                    try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(ns_spec), ens_ph);
                }
                _ = try self.expect(.kw_from);
                // Placeholder as source
                var ens_ph_source: NodeIndex = .none;
                var source_token: TokenIndex = undefined;
                if (self.isPlaceholder()) {
                    ens_ph_source = try self.parsePlaceholder("StringLiteral");
                    source_token = @enumFromInt(0);
                } else {
                    source_token = try self.expect(.string);
                }
                const ns_attrs_range = try self.parseImportAttributes();
                try self.expectSemicolon();
                const scratch_start = self.scratch.items.len;
                try self.scratch.append(self.allocator, ns_spec);
                const specs = self.scratch.items[scratch_start..];
                const range = try self.addExtraRange(specs);
                self.scratch.shrinkRetainingCapacity(scratch_start);
                const extra_start = try self.addExtra(@intFromEnum(source_token));
                _ = try self.addExtra(range.start);
                _ = try self.addExtra(range.end);
                _ = try self.addExtra(@intFromEnum(@as(NodeIndex, .none))); // no declaration
                _ = try self.addExtra(ns_attrs_range.start);
                _ = try self.addExtra(ns_attrs_range.end);
                const ens_node = try self.addNode(.{
                    .tag = .export_named,
                    .main_token = export_token,
                    .data = .{ .extra = @enumFromInt(extra_start) },
                });
                if (ens_ph_source != .none) {
                    try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(ens_node), ens_ph_source);
                }
                return ens_node;
            }
            // export * from 'source' → ExportAllDeclaration
            _ = try self.expect(.kw_from);
            // Placeholder as source: `export * from %%FILE%%`
            var ea_ph_source: NodeIndex = .none;
            var ea_source_token: TokenIndex = undefined;
            if (self.isPlaceholder()) {
                ea_ph_source = try self.parsePlaceholder("StringLiteral");
                ea_source_token = @enumFromInt(0);
            } else {
                ea_source_token = try self.expect(.string);
            }
            const star_attrs_range = try self.parseImportAttributes();
            try self.expectSemicolon();
            const star_extra_start = try self.addExtra(@intFromEnum(ea_source_token));
            _ = try self.addExtra(star_attrs_range.start);
            _ = try self.addExtra(star_attrs_range.end);
            _ = try self.addExtra(0); // is_type_export flag
            const ea_node = try self.addNode(.{
                .tag = .export_all,
                .main_token = export_token,
                .data = .{ .extra = @enumFromInt(star_extra_start) },
            });
            if (ea_ph_source != .none) {
                try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(ea_node), ea_ph_source);
            }
            return ea_node;
        }

        // export { a, b as c }
        if (self.currentTag() == .l_brace) {
            _ = self.advance(); // {
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);

            while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
                const spec = try self.parseExportSpecifier();
                try self.scratch.append(self.allocator, spec);
                if (self.currentTag() != .r_brace) {
                    _ = try self.expect(.comma);
                }
            }
            _ = try self.expect(.r_brace);

            // Optional: from 'source' or from %%FILE%%
            var source_token: TokenIndex = @enumFromInt(0);
            var en_ph_source: NodeIndex = .none;
            var brace_attrs_range: Range = blk_ar: {
                const pos: u32 = @intCast(self.extra_data.items.len);
                break :blk_ar .{ .start = pos, .end = pos };
            };
            if (self.eat(.kw_from) != null) {
                if (self.isPlaceholder()) {
                    en_ph_source = try self.parsePlaceholder("StringLiteral");
                } else {
                    source_token = try self.expect(.string);
                }
                brace_attrs_range = try self.parseImportAttributes();
            }
            try self.expectSemicolon();

            const specs = self.scratch.items[scratch_start..];
            const range = try self.addExtraRange(specs);
            const extra_start = try self.addExtra(@intFromEnum(source_token));
            _ = try self.addExtra(range.start);
            _ = try self.addExtra(range.end);
            _ = try self.addExtra(@intFromEnum(@as(NodeIndex, .none))); // no declaration
            _ = try self.addExtra(brace_attrs_range.start);
            _ = try self.addExtra(brace_attrs_range.end);

            const en_node = try self.addNode(.{
                .tag = .export_named,
                .main_token = export_token,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
            if (en_ph_source != .none) {
                try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(en_node), en_ph_source);
            }
            return en_node;
        }

        // export var/let/const/function/class/async/using/await using
        // Flow: export type/interface/opaque/enum/declare
        const decl = switch (self.currentTag()) {
            .kw_var => try self.parseVariableDeclaration(.var_declaration),
            .kw_let => try self.parseVariableDeclaration(.let_declaration),
            .kw_const => blk_const: {
                if (self.isTsConstEnum()) {
                    break :blk_const try @import("parser_ts.zig").parseTsEnumDeclaration(self);
                }
                break :blk_const try self.parseVariableDeclaration(.const_declaration);
            },
            .kw_function => try self.parseFunctionDeclaration(),
            .kw_class => try self.parseClassDeclaration(),
            .kw_async => blk: {
                const async_tok = self.advance(); // async
                const async_result = try self.parseFunctionDeclInner(true, true);
                self.nodes.items(.main_token)[@intFromEnum(async_result)] = async_tok;
                break :blk async_result;
            },
            .kw_await => blk: {
                if (self.isAwaitUsingDeclaration()) {
                    self.errors.addError("Using declaration cannot be exported.", self.currentStart());
                    break :blk try self.parseAwaitUsingDeclaration();
                }
                self.errors.addError("expected export declaration", self.currentStart());
                return error.ParseError;
            },
            else => blk: {
                if (self.isFlow() and self.currentTag() == .identifier) {
                    const flow_mod = @import("parser_flow.zig");
                    switch (self.currentSoftKeyword()) {
                        .type_ => {
                            // export type { ... } from '...' => re-export (treat as export named)
                            // export type Foo = ... => type alias
                            if (self.lookAhead(1) == .l_brace or self.lookAhead(1) == .asterisk) {
                                // export type { ... } or export type * — Flow type export
                                // Skip 'type' and parse as normal export specifiers
                                _ = self.advance(); // skip 'type'
                                // Re-parse the brace/star part
                                // This is a type-only re-export, for now treat as regular export
                                if (self.currentTag() == .asterisk) {
                                    // export type * from 'source'
                                    _ = self.advance(); // *
                                    _ = try self.expect(.kw_from);
                                    const src_tok = try self.expect(.string);
                                    const flow_star_attrs = try self.parseImportAttributes();
                                    try self.expectSemicolon();
                                    const flow_star_extra = try self.addExtra(@intFromEnum(src_tok));
                                    _ = try self.addExtra(flow_star_attrs.start);
                                    _ = try self.addExtra(flow_star_attrs.end);
                                    _ = try self.addExtra(1); // is_type_export flag
                                    return self.addNode(.{
                                        .tag = .export_all,
                                        .main_token = export_token,
                                        .data = .{ .extra = @enumFromInt(flow_star_extra) },
                                    });
                                }
                                // export type { ... }
                                _ = self.advance(); // {
                                const sstart = self.scratch.items.len;
                                defer self.scratch.shrinkRetainingCapacity(sstart);
                                while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
                                    const spec = try self.parseExportSpecifier();
                                    try self.scratch.append(self.allocator, spec);
                                    if (self.currentTag() != .r_brace) {
                                        _ = try self.expect(.comma);
                                    }
                                }
                                _ = try self.expect(.r_brace);
                                var src_token: TokenIndex = @enumFromInt(0);
                                var flow_brace_attrs: Range = blk_fa: {
                                    const p: u32 = @intCast(self.extra_data.items.len);
                                    break :blk_fa .{ .start = p, .end = p };
                                };
                                if (self.eat(.kw_from) != null) {
                                    src_token = try self.expect(.string);
                                    flow_brace_attrs = try self.parseImportAttributes();
                                }
                                try self.expectSemicolon();
                                const specs2 = self.scratch.items[sstart..];
                                const range2 = try self.addExtraRange(specs2);
                                const extra_start2 = try self.addExtra(@intFromEnum(src_token));
                                _ = try self.addExtra(range2.start);
                                _ = try self.addExtra(range2.end);
                                _ = try self.addExtra(@intFromEnum(@as(NodeIndex, .none)));
                                _ = try self.addExtra(flow_brace_attrs.start);
                                _ = try self.addExtra(flow_brace_attrs.end);
                                return self.addNode(.{
                                    .tag = .export_named_type,
                                    .main_token = export_token,
                                    .data = .{ .extra = @enumFromInt(extra_start2) },
                                });
                            }
                            break :blk try flow_mod.parseFlowTypeAlias(self);
                        },
                        .opaque_ => break :blk try flow_mod.parseFlowOpaqueType(self),
                        .interface => break :blk try flow_mod.parseFlowInterfaceDeclaration(self),
                        .enum_ => break :blk try flow_mod.parseFlowEnumDeclaration(self),
                        .declare => break :blk try flow_mod.parseFlowDeclareStatement(self),
                        else => {},
                    }
                }
                // TypeScript: export abstract class / type / interface / enum / namespace / module / declare
                if (self.isTypeScript() and self.currentTag() == .identifier) {
                    const parser_ts = @import("parser_ts.zig");
                    const ts_soft = self.currentSoftKeyword();
                    if (ts_soft == .abstract_ and self.lookAhead(1) == .kw_class) {
                        const abstract_tok = self.advance();
                        const cls = try self.parseClassDeclaration();
                        self.nodes.items(.main_token)[@intFromEnum(cls)] = abstract_tok;
                        try self.storeTsModifiers(cls, TS_MOD_ABSTRACT);
                        break :blk cls;
                    }
                    if (ts_soft == .abstract_ and self.lookAhead(1) == .identifier and
                        self.softKeywordAt(self.token_index + 1) == .interface and
                        !self.hasNewlineAfterCurrent() and !self.hasNewlineAfterOffset(1))
                    {
                        const abstract_tok = self.advance();
                        self.errors.addError("'abstract' modifier can only appear on a class, method, or property declaration.", self.token_starts[@intFromEnum(abstract_tok)]);
                        const iface = try parser_ts.parseTsInterfaceDeclaration(self);
                        self.nodes.items(.main_token)[@intFromEnum(iface)] = abstract_tok;
                        try self.storeTsModifiers(iface, TS_MOD_ABSTRACT);
                        break :blk iface;
                    }
                    if (ts_soft == .type_) {
                        // export type { ... } or export type * — TS type export
                        if (self.lookAhead(1) == .l_brace or self.lookAhead(1) == .asterisk) {
                            _ = self.advance(); // skip 'type'
                            if (self.currentTag() == .asterisk) {
                                // export type * from 'source' or export type * as ns from 'source'
                                const star_token2 = self.advance(); // *
                                if (self.eat(.kw_as) != null) {
                                    // export type * as ns from 'source'
                                    const ns_name_token2 = if (self.currentTag() == .identifier or self.currentTag() == .string or self.currentTag() == .kw_default or self.currentTag().isKeyword())
                                        self.advance()
                                    else
                                        try self.expect(.identifier);
                                    const ns_spec2 = try self.addNode(.{
                                        .tag = .export_namespace_specifier,
                                        .main_token = star_token2,
                                        .data = .{ .unary = @enumFromInt(@intFromEnum(ns_name_token2)) },
                                    });
                                    _ = try self.expect(.kw_from);
                                    const src_tok3 = try self.expect(.string);
                                    const ts_ns_attrs = try self.parseImportAttributes();
                                    try self.expectSemicolon();
                                    const sstart3 = self.scratch.items.len;
                                    try self.scratch.append(self.allocator, ns_spec2);
                                    const specs3 = self.scratch.items[sstart3..];
                                    const range3 = try self.addExtraRange(specs3);
                                    self.scratch.shrinkRetainingCapacity(sstart3);
                                    const extra3 = try self.addExtra(@intFromEnum(src_tok3));
                                    _ = try self.addExtra(range3.start);
                                    _ = try self.addExtra(range3.end);
                                    _ = try self.addExtra(@intFromEnum(@as(NodeIndex, .none)));
                                    _ = try self.addExtra(ts_ns_attrs.start);
                                    _ = try self.addExtra(ts_ns_attrs.end);
                                    return self.addNode(.{
                                        .tag = .export_named_type,
                                        .main_token = export_token,
                                        .data = .{ .extra = @enumFromInt(extra3) },
                                    });
                                }
                                _ = try self.expect(.kw_from);
                                const src_tok2 = try self.expect(.string);
                                const ts_star_attrs = try self.parseImportAttributes();
                                try self.expectSemicolon();
                                const ts_star_extra = try self.addExtra(@intFromEnum(src_tok2));
                                _ = try self.addExtra(ts_star_attrs.start);
                                _ = try self.addExtra(ts_star_attrs.end);
                                _ = try self.addExtra(1); // is_type_export flag
                                return self.addNode(.{
                                    .tag = .export_all,
                                    .main_token = export_token,
                                    .data = .{ .extra = @enumFromInt(ts_star_extra) },
                                });
                            }
                            // export type { ... }
                            _ = self.advance(); // {
                            const sstart2 = self.scratch.items.len;
                            defer self.scratch.shrinkRetainingCapacity(sstart2);
                            while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
                                const spec2 = try self.parseExportSpecifier();
                                try self.scratch.append(self.allocator, spec2);
                                if (self.currentTag() != .r_brace) {
                                    _ = try self.expect(.comma);
                                }
                            }
                            _ = try self.expect(.r_brace);
                            var src_token2: TokenIndex = @enumFromInt(0);
                            var ts_brace_attrs: Range = blk_tba: {
                                const p: u32 = @intCast(self.extra_data.items.len);
                                break :blk_tba .{ .start = p, .end = p };
                            };
                            if (self.eat(.kw_from) != null) {
                                src_token2 = try self.expect(.string);
                                ts_brace_attrs = try self.parseImportAttributes();
                            }
                            try self.expectSemicolon();
                            const specs_ts = self.scratch.items[sstart2..];
                            const range_ts = try self.addExtraRange(specs_ts);
                            const extra_ts = try self.addExtra(@intFromEnum(src_token2));
                            _ = try self.addExtra(range_ts.start);
                            _ = try self.addExtra(range_ts.end);
                            _ = try self.addExtra(@intFromEnum(@as(NodeIndex, .none)));
                            _ = try self.addExtra(ts_brace_attrs.start);
                            _ = try self.addExtra(ts_brace_attrs.end);
                            return self.addNode(.{
                                .tag = .export_named_type,
                                .main_token = export_token,
                                .data = .{ .extra = @enumFromInt(extra_ts) },
                            });
                        }
                        break :blk try parser_ts.parseTsTypeAliasDeclaration(self);
                    }
                    if (ts_soft == .interface and !self.hasNewlineAfterCurrent()) break :blk try parser_ts.parseTsInterfaceDeclaration(self);
                    if (ts_soft == .enum_) break :blk try parser_ts.parseTsEnumDeclaration(self);
                    if (ts_soft == .namespace) break :blk try parser_ts.parseTsModuleDeclaration(self);
                    if (ts_soft == .module) break :blk try parser_ts.parseTsModuleDeclaration(self);
                    if (ts_soft == .declare and !self.hasNewlineAfterCurrent()) {
                        if (self.softKeywordAt(self.token_index + 1) != .interface or !self.hasNewlineAfterOffset(1)) {
                            break :blk try parser_ts.parseTsDeclareStatement(self);
                        }
                    }
                }
                // TypeScript: export import X = ... → TSImportEqualsDeclaration wrapped in ExportNamed
                if (self.isTypeScript() and self.currentTag() == .kw_import) {
                    break :blk try self.parseImportDeclaration();
                }
                if (self.isUsingDeclaration()) {
                    self.errors.addError("Using declaration cannot be exported.", self.currentStart());
                    break :blk try self.parseUsingDeclaration();
                }
                // Placeholder as exported declaration: `export %%DECL%%`
                if (self.isPlaceholder()) {
                    const ph_decl = try self.parsePlaceholder("Declaration");
                    break :blk ph_decl;
                }
                self.errors.addError("expected export declaration", self.currentStart());
                return error.ParseError;
            },
        };

        // Attach decorators from `export @dec class` to the class declaration
        if (export_dec_range) |dr| {
            const dt = self.nodes.items(.tag)[@intFromEnum(decl)];
            if (dt == .class_declaration or dt == .class_expr) {
                try self.decorators_map.put(self.allocator, @intFromEnum(decl), dr);
                const fdi: NodeIndex = @enumFromInt(self.extra_data.items[dr.start]);
                const fdmt = self.nodes.items(.main_token)[@intFromEnum(fdi)];
                const fds = self.token_starts[@intFromEnum(fdmt)];
                try self.node_start_overrides.put(self.allocator, @intFromEnum(decl), fds);
            }
        }

        // Use extra format: store 0 (no source), then empty specifiers range, then declaration, then empty attrs range
        const decl_extra_start = try self.addExtra(0); // no source token
        const empty_specs_start: u32 = @intCast(self.extra_data.items.len);
        _ = try self.addExtra(empty_specs_start); // range start = range end = empty
        _ = try self.addExtra(empty_specs_start);
        _ = try self.addExtra(@intFromEnum(decl)); // declaration
        const empty_attrs_start: u32 = @intCast(self.extra_data.items.len);
        _ = try self.addExtra(empty_attrs_start);
        _ = try self.addExtra(empty_attrs_start);

        // Determine if this is a type-kind export (Flow type/opaque/interface/enum/declare, TS type/interface/enum)
        const decl_tag = self.nodes.items(.tag)[@intFromEnum(decl)];
        const is_type_export = switch (decl_tag) {
            .flow_type_alias, .flow_opaque_type, .flow_interface_declaration, .flow_declare_class, .flow_declare_function, .flow_declare_variable, .flow_declare_module, .flow_declare_module_exports, .flow_declare_export_declaration, .flow_declare_interface, .flow_declare_opaque_type => true,
            .ts_type_alias_declaration, .ts_interface_declaration, .ts_declare_variable => true,
            // TSDeclareFunction: type export only when actually declared with `declare`
            .ts_declare_function => blk: {
                const mt = self.nodes.items(.main_token)[@intFromEnum(decl)];
                if (self.token_tags[@intFromEnum(mt)] == .identifier) {
                    const mt_text = self.tokenText(@intFromEnum(mt));
                    break :blk std.mem.eql(u8, mt_text, "declare");
                }
                break :blk false;
            },
            // declare enum/namespace/module/class: exportKind "type" only when declared
            .ts_enum_declaration, .ts_module_declaration => blk: {
                // When parsed via parseTsDeclareStatement, main_token is set to the "declare" identifier
                const mt = self.nodes.items(.main_token)[@intFromEnum(decl)];
                if (self.token_tags[@intFromEnum(mt)] == .identifier) {
                    const mt_text = self.tokenText(@intFromEnum(mt));
                    break :blk std.mem.eql(u8, mt_text, "declare");
                }
                break :blk false;
            },
            .class_declaration => blk: {
                const key = @intFromEnum(decl);
                const mods = self.ts_class_modifiers.get(key) orelse 0;
                break :blk (mods & TS_MOD_DECLARE) != 0;
            },
            else => false,
        };

        return self.addNode(.{
            .tag = if (is_type_export) .export_named_type else .export_named,
            .main_token = export_token,
            .data = .{ .extra = @enumFromInt(decl_extra_start) },
        });
    }

    /// Parse `export <identifier> from 'source'` (exportDefaultFrom plugin)
    fn parseExportDefaultFrom(self: *Parser, export_token: TokenIndex) Error!NodeIndex {
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        // First specifier: the default specifier
        const default_spec_token = self.advance(); // the identifier or 'default' keyword
        const default_spec = try self.addNode(.{
            .tag = .export_default_specifier,
            .main_token = default_spec_token,
            .data = .{ .none = {} },
        });
        try self.scratch.append(self.allocator, default_spec);

        // Optional: , { ... } or , * as ns
        if (self.eat(.comma) != null) {
            if (self.currentTag() == .asterisk) {
                // export foo, * as ns from 'source'
                const star_tok = self.advance(); // *
                _ = try self.expect(.kw_as);
                const ns_name_tok = if (self.currentTag() == .identifier or self.currentTag() == .string or self.currentTag() == .kw_default or self.currentTag().isKeyword())
                    self.advance()
                else
                    try self.expect(.identifier);
                const ns_spec = try self.addNode(.{
                    .tag = .export_namespace_specifier,
                    .main_token = star_tok,
                    .data = .{ .unary = @enumFromInt(@intFromEnum(ns_name_tok)) },
                });
                try self.scratch.append(self.allocator, ns_spec);
            } else if (self.currentTag() == .l_brace) {
                // export foo, { bar } from 'source'
                _ = self.advance(); // {
                while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
                    const spec = try self.parseExportSpecifier();
                    try self.scratch.append(self.allocator, spec);
                    if (self.currentTag() != .r_brace) {
                        _ = try self.expect(.comma);
                    }
                }
                _ = try self.expect(.r_brace);
            }
        }

        _ = try self.expect(.kw_from);
        const source_token = try self.expect(.string);
        const edf_attrs_range = try self.parseImportAttributes();
        try self.expectSemicolon();

        const specs = self.scratch.items[scratch_start..];
        const range = try self.addExtraRange(specs);
        const extra_start = try self.addExtra(@intFromEnum(source_token));
        _ = try self.addExtra(range.start);
        _ = try self.addExtra(range.end);
        _ = try self.addExtra(@intFromEnum(@as(NodeIndex, .none))); // no declaration
        _ = try self.addExtra(edf_attrs_range.start);
        _ = try self.addExtra(edf_attrs_range.end);

        return self.addNode(.{
            .tag = .export_named,
            .main_token = export_token,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    pub fn parseExportSpecifier(self: *Parser) Error!NodeIndex {
        // Placeholder in export specifier: `{ %%NAME%% }`, `{ %%NAME%% as alias }`, etc.
        if (self.isPlaceholder()) {
            const ph_start: TokenIndex = @enumFromInt(self.token_index);
            const ph = try self.parsePlaceholder("Identifier");
            if (self.eat(.kw_as) != null) {
                // `{ %%NAME%% as alias }` or `{ %%NAME%% as %%ALIAS%% }`
                var exported_ph: ?NodeIndex = null;
                var exported_tok: TokenIndex = @enumFromInt(0);
                if (self.isPlaceholder()) {
                    exported_ph = try self.parsePlaceholder("Identifier");
                } else {
                    exported_tok = self.advance(); // exported token
                }
                const e_extra_start = try self.addExtra(0);
                _ = try self.addExtra(@intFromEnum(exported_tok));
                const spec_node = try self.addNode(.{
                    .tag = .export_specifier,
                    .main_token = ph_start,
                    .data = .{ .extra = @enumFromInt(e_extra_start) },
                });
                try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(spec_node), ph);
                if (exported_ph) |ep| {
                    try self.flow_variance_map.put(self.allocator, @intFromEnum(spec_node), ep);
                }
                return spec_node;
            }
            // No alias — placeholder is both local and exported
            const e_extra_start = try self.addExtra(0);
            _ = try self.addExtra(0);
            const spec_node = try self.addNode(.{
                .tag = .export_specifier,
                .main_token = ph_start,
                .data = .{ .extra = @enumFromInt(e_extra_start) },
            });
            try self.placeholder_name_nodes.put(self.allocator, @intFromEnum(spec_node), ph);
            return spec_node;
        }

        const type_info = self.tryConsumeInlineTypeModifier();
        const is_type_specifier = type_info.is_type;
        const type_keyword_token = type_info.token;

        const spec_tag: Node.Tag = if (is_type_specifier) .export_specifier_type else .export_specifier;
        const local_token = self.advance();
        const main_tok = if (is_type_specifier) type_keyword_token else local_token;
        if (self.eat(.kw_as) != null) {
            // Placeholder as exported: `{ name as %%ALIAS%% }`
            if (self.isPlaceholder()) {
                const exp_ph = try self.parsePlaceholder("Identifier");
                const ex_extra_start = try self.addExtra(@intFromEnum(local_token));
                _ = try self.addExtra(0);
                const ex_spec_node = try self.addNode(.{
                    .tag = spec_tag,
                    .main_token = main_tok,
                    .data = .{ .extra = @enumFromInt(ex_extra_start) },
                });
                try self.flow_variance_map.put(self.allocator, @intFromEnum(ex_spec_node), exp_ph);
                return ex_spec_node;
            }
            const exported_token = self.advance(); // could be identifier or keyword
            self.checkExportStringLoneSurrogate(exported_token);
            const extra_start = try self.addExtra(@intFromEnum(local_token));
            _ = try self.addExtra(@intFromEnum(exported_token));
            return self.addNode(.{
                .tag = spec_tag,
                .main_token = main_tok,
                .data = .{ .extra = @enumFromInt(extra_start) },
            });
        }
        // No alias — store same token for both local and exported
        self.checkExportStringLoneSurrogate(local_token);
        const extra_start = try self.addExtra(@intFromEnum(local_token));
        _ = try self.addExtra(@intFromEnum(local_token));
        return self.addNode(.{
            .tag = spec_tag,
            .main_token = main_tok,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    /// Validate that a string literal used as an export name does not contain lone surrogates.
    fn checkExportStringLoneSurrogate(self: *Parser, token: TokenIndex) void {
        const idx = @intFromEnum(token);
        if (idx >= self.token_tags.len) return;
        if (self.token_tags[idx] != .string) return;
        const start = self.token_starts[idx];
        const end = self.token_ends[idx];
        const raw = self.source[start..end];
        // Scan for \uXXXX escapes that are surrogates
        var i: usize = 0;
        while (i + 5 < raw.len) : (i += 1) {
            if (raw[i] != '\\' or raw[i + 1] != 'u') continue;
            // Parse the 4 hex digits
            const hex = raw[i + 2 .. i + 6];
            const val = std.fmt.parseInt(u16, hex, 16) catch continue;
            if (val >= 0xD800 and val <= 0xDBFF) {
                // High surrogate — check for valid pair
                if (i + 11 < raw.len and raw[i + 6] == '\\' and raw[i + 7] == 'u') {
                    const hex2 = raw[i + 8 .. i + 12];
                    const val2 = std.fmt.parseInt(u16, hex2, 16) catch 0;
                    if (val2 >= 0xDC00 and val2 <= 0xDFFF) {
                        i += 11; // skip the pair
                        continue;
                    }
                }
                // Lone high surrogate
                self.errors.addError("An export name cannot include a lone surrogate", start);
                return;
            }
            if (val >= 0xDC00 and val <= 0xDFFF) {
                // Lone low surrogate
                self.errors.addError("An export name cannot include a lone surrogate", start);
                return;
            }
        }
    }

    // === Async prefix in statement context ===

    fn parseAsyncPrefix(self: *Parser) Error!NodeIndex {
        if (self.lookAhead(1) == .kw_function and !self.hasNewlineAfterCurrent()) {
            const async_token = self.advance(); // async
            const result = try self.parseFunctionDeclInner(true, false);
            // Fix start to include 'async' keyword
            self.nodes.items(.main_token)[@intFromEnum(result)] = async_token;
            return result;
        }
        return self.parseExpressionOrLabeledStatement();
    }

    // === Expression to Pattern conversion ===
    // When parsing `[a, b] = x` or `{a, b} = x`, the LHS is initially parsed
    // as an expression (array_expr/object_expr). After seeing `=`, we convert
    // it to the corresponding pattern (array_pattern/object_pattern).

    fn convertToPattern(self: *Parser, idx: NodeIndex) void {
        if (idx == .none) return;
        const i = @intFromEnum(idx);
        const tags = self.nodes.items(.tag);
        const tag = tags[i];
        switch (tag) {
            .array_expr => {
                tags[i] = .array_pattern;
                // Recursively convert elements
                const data = self.nodes.items(.data)[i];
                const extra_idx = @intFromEnum(data.extra);
                if (extra_idx < self.extra_data.items.len) {
                    const range_start = self.extra_data.items[extra_idx];
                    const range_end = self.extra_data.items[extra_idx + 1];
                    if (range_start <= range_end and range_end <= self.extra_data.items.len) {
                        for (self.extra_data.items[range_start..range_end]) |elem| {
                            self.convertToPattern(@enumFromInt(elem));
                        }
                    }
                }
            },
            .object_expr => {
                tags[i] = .object_pattern;
                // Recursively convert property values
                const data = self.nodes.items(.data)[i];
                const extra_idx = @intFromEnum(data.extra);
                if (extra_idx < self.extra_data.items.len) {
                    const range_start = self.extra_data.items[extra_idx];
                    const range_end = self.extra_data.items[extra_idx + 1];
                    if (range_start <= range_end and range_end <= self.extra_data.items.len) {
                        for (self.extra_data.items[range_start..range_end]) |elem| {
                            self.convertPropertyToPattern(@enumFromInt(elem));
                        }
                    }
                }
            },
            .assignment_expr => {
                // a = b inside a pattern becomes AssignmentPattern
                // For compound operators (+=, -=, etc.), still convert but add error
                const mt = self.nodes.items(.main_token)[i];
                if (self.token_tags[@intFromEnum(mt)] != .equal) {
                    self.errors.addError("Only '=' operator can be used for specifying default value.", self.token_starts[@intFromEnum(mt)]);
                }
                tags[i] = .assignment_pattern;
                const data = self.nodes.items(.data)[i];
                self.convertToPattern(data.binary.lhs);
            },
            .parenthesized_expr => {
                // Convert inner expression
                const data = self.nodes.items(.data)[i];
                self.convertToPattern(data.unary);
            },
            .spread_element => {
                // In pattern context, spread becomes rest
                tags[i] = .rest_element;
                const data = self.nodes.items(.data)[i];
                self.convertToPattern(data.unary);
                // Check: void (discard binding) is not valid as rest target
                if (data.unary != .none) {
                    if (self.opts.enable_discard_binding and self.async_arrow_flags.contains(@intFromEnum(data.unary))) {
                        const rest_start = self.token_starts[@intFromEnum(self.nodes.items(.main_token)[i])];
                        self.errors.addError("Unexpected token", rest_start);
                    } else {
                        // Validate rest target is a valid pattern
                        const rest_tag = tags[@intFromEnum(data.unary)];
                        switch (rest_tag) {
                            .identifier, .array_pattern, .object_pattern, .assignment_pattern, .placeholder => {},
                            else => {
                                const rest_start = self.token_starts[@intFromEnum(self.nodes.items(.main_token)[@intFromEnum(data.unary)])];
                                self.errors.addError("Invalid rest target", rest_start);
                            },
                        }
                    }
                }
            },
            .placeholder => {
                // Change expectedNode from "Expression" to "Pattern" for arrow params
                self.placeholder_contexts.put(self.allocator, i, "Pattern") catch {};
            },
            .ts_as_expression, .ts_satisfies_expression => {
                // Convert the expression part of `expr as Type` to pattern
                const data = self.nodes.items(.data)[i];
                self.convertToPattern(data.binary.lhs);
            },
            .ts_non_null_expression => {
                // Convert the expression part of `expr!` to pattern
                const data = self.nodes.items(.data)[i];
                self.convertToPattern(data.unary);
            },
            .flow_type_cast_expression => {
                // In pattern context, (a: Type) becomes a typed identifier.
                // Extract the expression and attach the type as annotation.
                const data = self.nodes.items(.data)[i];
                const extra_idx = @intFromEnum(data.extra);
                const expr_idx: NodeIndex = @enumFromInt(self.extra_data.items[extra_idx]);
                const type_idx: NodeIndex = @enumFromInt(self.extra_data.items[extra_idx + 1]);
                // Find the colon token between expr and type
                const type_main = self.nodes.items(.main_token)[@intFromEnum(type_idx)];
                var colon_tok: TokenIndex = type_main;
                if (@intFromEnum(type_main) > 0) {
                    var search: u32 = @intFromEnum(type_main);
                    while (search > 0) {
                        search -= 1;
                        if (self.token_tags[search] == .colon) {
                            colon_tok = @enumFromInt(search);
                            break;
                        }
                    }
                }
                // Create a flow_type_annotation wrapper
                const ann_end = self.nodes.items(.end_offset)[@intFromEnum(type_idx)];
                const ann_node = self.addNode(.{
                    .tag = .flow_type_annotation,
                    .main_token = colon_tok,
                    .data = .{ .unary = type_idx },
                }) catch return;
                if (ann_end > 0) {
                    self.nodes.items(.end_offset)[@intFromEnum(ann_node)] = ann_end;
                }
                // Overwrite this node with the expression's data (effectively unwrap)
                const expr_i = @intFromEnum(expr_idx);
                tags[i] = self.nodes.items(.tag)[expr_i];
                self.nodes.items(.main_token)[i] = self.nodes.items(.main_token)[expr_i];
                self.nodes.items(.data)[i] = self.nodes.items(.data)[expr_i];
                // Set end to include the type annotation (not just the identifier)
                const final_ann_end = self.nodes.items(.end_offset)[@intFromEnum(ann_node)];
                if (final_ann_end > 0) {
                    self.nodes.items(.end_offset)[i] = final_ann_end;
                } else {
                    self.nodes.items(.end_offset)[i] = self.token_ends[@intFromEnum(self.nodes.items(.main_token)[expr_i])];
                }
                // Attach type annotation
                self.putTypeAnnotation(@enumFromInt(i), ann_node) catch {};
                self.convertToPattern(idx);
            },
            else => {},
        }
    }

    fn convertPropertyToPattern(self: *Parser, idx: NodeIndex) void {
        if (idx == .none) return;
        const i = @intFromEnum(idx);
        const tags = self.nodes.items(.tag);
        const tag = tags[i];
        switch (tag) {
            .property, .computed_property => {
                // Property uses data.binary: lhs=key, rhs=value
                const data = self.nodes.items(.data)[i];
                self.convertToPattern(data.binary.rhs);
            },
            .shorthand_property => {
                // Shorthand {a} = ... — the value is already an identifier, no conversion needed
                // But if it has a default: {a = 1} is a shorthand_property with an assignment_pattern
                const data = self.nodes.items(.data)[i];
                if (data.unary != .none) {
                    self.convertToPattern(data.unary);
                }
            },
            .spread_element, .rest_element => {
                // In object pattern context, spread becomes rest
                if (tag == .spread_element) tags[i] = .rest_element;
                const data = self.nodes.items(.data)[i];
                self.convertToPattern(data.unary);
                // Check: void (discard binding) is not valid as rest target
                if (tag == .spread_element and data.unary != .none) {
                    if (self.opts.enable_discard_binding and self.async_arrow_flags.contains(@intFromEnum(data.unary))) {
                        const rest_start = self.token_starts[@intFromEnum(self.nodes.items(.main_token)[i])];
                        self.errors.addError("Unexpected token", rest_start);
                    }
                }
            },
            else => {
                self.convertToPattern(idx);
            },
        }
    }

    /// Validate that a node is a valid binding pattern (used for arrow function params).
    /// Reports errors for invalid nodes like numeric/string literals in pattern positions.
    fn validatePattern(self: *Parser, idx: NodeIndex) void {
        if (idx == .none) return;
        const i = @intFromEnum(idx);
        const tags = self.nodes.items(.tag);
        const tag = tags[i];
        switch (tag) {
            .identifier, .assignment_pattern => {},
            .rest_element => {
                const data = self.nodes.items(.data)[i];
                self.validatePattern(data.unary);
            },
            .array_pattern => {
                const data = self.nodes.items(.data)[i];
                const extra_idx = @intFromEnum(data.extra);
                if (extra_idx < self.extra_data.items.len) {
                    const range_start = self.extra_data.items[extra_idx];
                    const range_end = self.extra_data.items[extra_idx + 1];
                    if (range_start <= range_end and range_end <= self.extra_data.items.len) {
                        for (self.extra_data.items[range_start..range_end]) |elem| {
                            self.validatePattern(@enumFromInt(elem));
                        }
                    }
                }
            },
            .object_pattern => {
                const data = self.nodes.items(.data)[i];
                const extra_idx = @intFromEnum(data.extra);
                if (extra_idx < self.extra_data.items.len) {
                    const range_start = self.extra_data.items[extra_idx];
                    const range_end = self.extra_data.items[extra_idx + 1];
                    if (range_start <= range_end and range_end <= self.extra_data.items.len) {
                        for (self.extra_data.items[range_start..range_end]) |elem| {
                            const node_idx: NodeIndex = @enumFromInt(elem);
                            const ptag = tags[@intFromEnum(node_idx)];
                            switch (ptag) {
                                .shorthand_property, .property, .computed_property => {},
                                .rest_element => self.validatePattern(node_idx),
                                else => self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(self.nodes.items(.main_token)[@intFromEnum(node_idx)])]),
                            }
                        }
                    }
                }
            },
            .numeric_literal,
            .string_literal,
            .boolean_literal,
            .null_literal,
            .binary_expr,
            .unary_expr,
            .call_expr,
            .member_expr,
            .template_literal,
            => {
                self.errors.addError("Unexpected token", self.token_starts[@intFromEnum(self.nodes.items(.main_token)[i])]);
            },
            else => {},
        }
    }

    /// Flow disambiguation: `<` in prefix position can be JSX or generic arrow function.
    /// In Flow mode, `<T>(params): RetType => body` is a generic arrow function.
    fn parseFlowPrefixLessThan(self: *Parser) Error!NodeIndex {
        const parser_jsx = @import("parser_jsx.zig");
        const parser_flow = @import("parser_flow.zig");

        // `<>` is always a JSX fragment
        if (self.lookAhead(1) == .greater_than) {
            return parser_jsx.parseJsxElement(self);
        }

        // `</` is a closing tag (error in expression position, but let JSX handle it)
        if (self.lookAhead(1) == .slash) {
            return parser_jsx.parseJsxElement(self);
        }

        // Check what follows `<identifier`:
        // If the next token after identifier is `,`, `:`, `>`, or `+`/`-` (variance),
        // it could be a generic arrow function `<T>(...) => ...` or `<T, U>(...) => ...`
        if (self.lookAhead(1) == .identifier or self.lookAhead(1).isKeyword()) {
            const after_ident = self.lookAhead(2);
            // Flow type parameters use `:` for bounds (not `extends`), `=` for defaults,
            // and `,` or `>` for separation
            if (after_ident == .comma or after_ident == .colon or after_ident == .greater_than or after_ident == .equal) {
                // Likely a generic arrow function — try with backtracking
                const state = self.saveState();
                if (parser_flow.tryParseFlowGenericArrowFunction(self)) |node| {
                    return node;
                } else |_| {
                    // Failed — check for `<T> async () => {}` error recovery
                    // The type parameters were parsed but what follows is `async` instead of `(`
                    // Don't restore yet — check if we can do error recovery
                    if (self.currentTag() == .kw_async and self.lookAhead(1) == .l_paren) {
                        // Error recovery: `<T> async () => {}` — parse as async arrow with type params
                        // but report error about type params needing to come after async
                        self.restoreState(state);
                        return self.parseFlowMisplacedTypeParamsArrow();
                    }
                    self.restoreState(state);
                }
            }
            // Otherwise parse as JSX
            return parser_jsx.parseJsxElement(self);
        }

        // `<+T>` or `<-T>` — variance annotations in Flow type parameters
        if (self.lookAhead(1) == .plus or self.lookAhead(1) == .minus) {
            const state = self.saveState();
            if (parser_flow.tryParseFlowGenericArrowFunction(self)) |node| {
                return node;
            } else |_| {
                self.restoreState(state);
            }
        }

        // Default: parse as JSX
        return parser_jsx.parseJsxElement(self);
    }

    /// Error recovery for `<T> async () => {}` in Flow mode.
    /// Parses the type parameters, reports the error, then parses the async arrow.
    fn parseFlowMisplacedTypeParamsArrow(self: *Parser) Error!NodeIndex {
        const parser_flow = @import("parser_flow.zig");
        const start_tok: TokenIndex = @enumFromInt(self.token_index);

        // Report error at the start of `<`
        self.errors.addError("Type parameters must come after the async keyword, e.g. instead of `<T> async () => {}`, use `async <T>() => {}`.", self.currentStart());

        // Parse type parameters
        const type_params = try parser_flow.parseFlowTypeParameterDeclaration(self);

        // Parse `async () => body`
        _ = self.advance(); // consume "async"

        _ = try self.expect(.l_paren);
        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);

        while (self.currentTag() != .r_paren and self.currentTag() != .eof) {
            if (self.currentTag() == .ellipsis) {
                const rest_tok = self.advance();
                const elem = try self.parseBindingElement();
                const rest_node = try self.addNode(.{ .tag = .rest_element, .main_token = rest_tok, .data = .{ .unary = elem } });
                if (self.flow_type_annotations.get(@intFromEnum(elem))) |type_ann| {
                    try self.storeTypeAnnotation(rest_node, type_ann);
                    _ = try self.removeTypeAnnotation(elem);
                }
                self.scratch.append(self.allocator, rest_node) catch return error.ParseError;
            } else {
                const param = try self.parseBindingElement();
                self.scratch.append(self.allocator, param) catch return error.ParseError;
            }
            if (self.eat(.comma) == null) break;
        }
        _ = try self.expect(.r_paren);

        // Optional return type
        var return_type: NodeIndex = .none;
        if (self.currentTag() == .colon) {
            return_type = try parser_flow.parseFlowArrowReturnTypeAnnotation(self);
        }

        // Expect =>
        _ = try self.expect(.arrow);

        // Parse body
        const saved_async = self.in_async;
        self.in_async = true;
        const saved_gen = self.in_generator;
        self.in_generator = false;
        const body = if (self.currentTag() == .l_brace)
            try self.parseBlockStatement()
        else
            try self.parseAssignmentExpression();
        self.in_async = saved_async;
        self.in_generator = saved_gen;

        const params = self.scratch.items[scratch_start..];
        const param_range = try self.addExtraRange(params);
        const extra_start = try self.addExtra(param_range.start);
        _ = try self.addExtra(param_range.end);
        _ = try self.addExtra(@intFromEnum(body));

        if (type_params != .none) {
            try self.putTypeParameters(@enumFromInt(self.nodes.len), type_params);
        }
        if (return_type != .none) {
            try self.putReturnType(@enumFromInt(self.nodes.len), return_type);
        }
        // Mark as async arrow (main_token is <, not async keyword)
        try self.async_arrow_flags.put(self.allocator, @intCast(self.nodes.len), {});

        return self.addNode(.{
            .tag = .arrow_function_expr,
            .main_token = start_tok,
            .data = .{ .extra = @enumFromInt(extra_start) },
        });
    }

    /// TSX disambiguation: `<` in prefix position can be JSX or generic arrow function.
    /// Type assertions (`<Type>expr`) are forbidden in TSX.
    fn parseTsxPrefixLessThan(self: *Parser) Error!NodeIndex {
        const parser_jsx = @import("parser_jsx.zig");
        const parser_ts = @import("parser_ts.zig");

        // `<>` is always a JSX fragment
        if (self.lookAhead(1) == .greater_than) {
            return parser_jsx.parseJsxElement(self);
        }

        // `</` is a closing tag (error in expression position, but let JSX handle it)
        if (self.lookAhead(1) == .slash) {
            return parser_jsx.parseJsxElement(self);
        }

        // Check what follows `<identifier`:
        // If the next token after identifier is `,`, `extends`, or `>`, try generic arrow function
        if (self.lookAhead(1) == .identifier or self.lookAhead(1).isKeyword()) {
            // Could be JSX `<Component ...>` or generic `<T extends U>() => ...` or `<T,>() => ...`
            const after_ident = self.lookAhead(2);
            if (after_ident == .comma or after_ident == .kw_extends or after_ident == .greater_than) {
                // TSX: Try JSX first, fall back to generic arrow if JSX fails.
                // This matches Babel's behavior where `<T>` prefers JSX interpretation.
                const jsx_state = self.saveState();
                if (parser_jsx.parseJsxElement(self)) |jsx_node| {
                    // JSX succeeded — use it
                    return jsx_node;
                } else |_| {
                    // JSX failed — try generic arrow function
                    self.restoreState(jsx_state);
                    const arrow_state = self.saveState();
                    if (parser_ts.tryParseGenericArrowFunction(self)) |node| {
                        // In TSX mode, single type param `<T>` without trailing comma gets an error
                        if (after_ident == .greater_than) {
                            self.errors.addError("Single type parameter should have a trailing comma.", self.token_starts[@intFromEnum(self.nodes.items(.main_token)[@intFromEnum(node)])]);
                        }
                        return node;
                    } else |_| {
                        self.restoreState(arrow_state);
                    }
                }
            }
            // Otherwise parse as JSX
            return parser_jsx.parseJsxElement(self);
        }

        // Default: parse as JSX
        return parser_jsx.parseJsxElement(self);
    }

    pub const ParseError = error{ParseError} || std.mem.Allocator.Error;
};

pub const ParseResult = struct {
    ast: Ast,
    errors: DiagnosticList,

    pub fn deinit(self: *ParseResult) void {
        self.ast.deinit();
        self.errors.deinit();
    }
};

// === Post-parse comment attachment ===

const CommentRange = @import("ast.zig").CommentRange;
const Comment = @import("lexer.zig").Comment;
