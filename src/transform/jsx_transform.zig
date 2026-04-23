const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const pipeline = @import("pipeline.zig");
const Pass = pipeline.Pass;
const TransformContext = pipeline.TransformContext;
const visitor = @import("visitor.zig");
const Codegen = @import("../codegen.zig").Codegen;

const SourceType = @import("../ast.zig").SourceType;

const Buf = std.ArrayListUnmanaged(u8);

pub const JsxRuntime = enum { classic, automatic };
pub const PropsSpreadMode = enum { preserve, object_assign, babel_extends };

pub const JsxConfig = struct {
    runtime: JsxRuntime = .classic,
    pragma: []const u8 = "React.createElement",
    pragma_frag: []const u8 = "React.Fragment",
    import_source: []const u8 = "react",
    pure: ?bool = null, // null = auto (true for default pragma, false for custom)
    source_type: SourceType = .module,
    props_spread_mode: PropsSpreadMode = .preserve,
    inject_display_name: bool = false,
    es3_property_literals: bool = false,
    retain_lines: bool = false,
};

/// State tracked across the file for automatic mode imports.
const JsxState = struct {
    config: JsxConfig,
    needs_jsx: bool = false,
    needs_jsxs: bool = false,
    needs_fragment: bool = false,
    needs_create_element: bool = false,
    // Track registration order for import sorting
    order_counter: u8 = 0,
    jsx_order: u8 = 255,
    jsxs_order: u8 = 255,
    fragment_order: u8 = 255,
    create_element_order: u8 = 255,
    // Indent depth for nested JSX props (automatic mode)
    indent_depth: u8 = 0,
    // Estimated codegen indent level for the current top-level JSX element
    code_indent: u8 = 0,
    // Scope conflict suffix: e.g., if _jsx is taken, jsx_suffix = "2" → "_jsx2"
    jsx_suffix: []const u8 = "",
    jsxs_suffix: []const u8 = "",
    fragment_suffix: []const u8 = "",

    fn registerJsx(self: *JsxState) void {
        if (!self.needs_jsx) {
            self.needs_jsx = true;
            self.jsx_order = self.order_counter;
            self.order_counter += 1;
        }
    }

    fn registerJsxs(self: *JsxState) void {
        if (!self.needs_jsxs) {
            self.needs_jsxs = true;
            self.jsxs_order = self.order_counter;
            self.order_counter += 1;
        }
    }

    fn registerFragment(self: *JsxState) void {
        if (!self.needs_fragment) {
            self.needs_fragment = true;
            self.fragment_order = self.order_counter;
            self.order_counter += 1;
        }
    }

    fn registerCreateElement(self: *JsxState) void {
        if (!self.needs_create_element) {
            self.needs_create_element = true;
            self.create_element_order = self.order_counter;
            self.order_counter += 1;
        }
    }

    /// Return whether this is CJS script mode (require() instead of import)
    fn isScript(self: *const JsxState) bool {
        return self.config.source_type == .script;
    }

    /// Build the CJS require variable name from the import source.
    /// e.g. "react" → "_reactJsxRuntime", "preact" → "_preactJsxRuntime"
    fn cjsRuntimeVar(self: *const JsxState, alloc: std.mem.Allocator) ![]const u8 {
        return cjsCamelCase(alloc, self.config.import_source, "JsxRuntime");
    }

    /// Build the CJS require variable name for createElement.
    /// e.g. "react" → "_react", "preact" → "_preact"
    fn cjsSourceVar(self: *const JsxState, alloc: std.mem.Allocator) ![]const u8 {
        return cjsCamelCase(alloc, self.config.import_source, "");
    }
};

/// Build a CJS-style variable name: "_" + camelCase(source) + suffix
/// e.g. cjsCamelCase("react", "JsxRuntime") → "_reactJsxRuntime"
/// e.g. cjsCamelCase("react", "") → "_react"
/// e.g. cjsCamelCase("@emotion/react", "JsxRuntime") → "_emotionReactJsxRuntime"
fn cjsCamelCase(alloc: std.mem.Allocator, source: []const u8, suffix: []const u8) ![]const u8 {
    var buf: Buf = .empty;
    try buf.append(alloc, '_');

    var capitalize_next = false;
    for (source) |c| {
        if (c == '/' or c == '-' or c == '@' or c == '.') {
            capitalize_next = true;
            continue;
        }
        if (capitalize_next) {
            try buf.append(alloc, std.ascii.toUpper(c));
            capitalize_next = false;
        } else {
            try buf.append(alloc, c);
        }
    }

    try buf.appendSlice(alloc, suffix);
    return buf.items;
}

var g_state: JsxState = .{ .config = .{} };

pub fn resetState() void {
    g_state = .{ .config = .{} };
}

pub fn createPass(config: JsxConfig) Pass {
    g_state = JsxState{ .config = config };

    var filter = visitor.NodeTagBitSet.initEmpty();
    filter.set(@intFromEnum(Node.Tag.jsx_element));
    filter.set(@intFromEnum(Node.Tag.jsx_self_closing_element));
    filter.set(@intFromEnum(Node.Tag.jsx_fragment));
    // Handle program node for pragma detection + import injection
    filter.set(@intFromEnum(Node.Tag.program));
    filter.set(@intFromEnum(Node.Tag.declarator));

    return .{
        .name = "jsx_transform",
        .node_filter = filter,
        .enter = enterNode,
        .exit = exitNode,
        .priority = 15, // After ts_strip (10)
    };
}

/// Scan source comments for @jsx and @jsxFrag pragmas.
fn detectPragmaComments(ctx: *TransformContext) void {
    const source = ctx.ast.source;

    // Scan the source directly for pragma comment patterns.
    // Look for /* @jsx X */ and /* @jsxFrag X */ and /** @jsx X */ etc.
    var i: usize = 0;
    while (i + 5 < source.len) : (i += 1) {
        if (source[i] == '/' and source[i + 1] == '*') {
            // Find end of comment
            var end = i + 2;
            while (end + 1 < source.len) : (end += 1) {
                if (source[end] == '*' and source[end + 1] == '/') {
                    end += 2;
                    break;
                }
            }

            const comment = source[i..end];
            // Strip /* and */
            if (comment.len < 4) continue;
            var body = comment[2 .. comment.len - 2];
            // Strip leading whitespace and stars for JSDoc-style
            body = std.mem.trim(u8, body, " \t\r\n");
            // Strip leading stars and whitespace again (for JSDoc /** ... */ style)
            body = std.mem.trimStart(u8, body, " *");
            body = std.mem.trim(u8, body, " \t\r\n");
            // For multi-line JSDoc, look for @jsx on any line
            if (findPragmaInMultiline(body, "@jsx ")) |pragma| {
                g_state.config.pragma = pragma;
                i = end;
                if (i > 0) i -= 1;
                continue;
            }
            if (findPragmaInMultiline(body, "@jsxFrag ")) |frag| {
                g_state.config.pragma_frag = frag;
                i = end;
                if (i > 0) i -= 1;
                continue;
            }
            if (findPragmaInMultiline(body, "@jsxImportSource ")) |src| {
                g_state.config.import_source = src;
                // Custom import source via pragma disables pure unless explicitly set
                if (g_state.config.pure == null) {
                    g_state.config.pure = false;
                }
                i = end;
                if (i > 0) i -= 1;
                continue;
            }
            if (findPragmaInMultiline(body, "@jsxRuntime ")) |rt| {
                if (std.mem.eql(u8, rt, "classic")) {
                    g_state.config.runtime = .classic;
                } else if (std.mem.eql(u8, rt, "automatic")) {
                    g_state.config.runtime = .automatic;
                }
                i = end;
                if (i > 0) i -= 1;
                continue;
            }

            i = end;
            if (i > 0) i -= 1; // Will be incremented by loop
        }
    }
}

/// Scan source identifiers for conflicts with auto-import names (_jsx, _jsxs, _Fragment).
/// If a conflict is found, set the appropriate suffix on g_state.
fn detectScopeConflicts(ctx: *TransformContext) void {
    const source = ctx.ast.source;

    // Scan the source text for identifiers that conflict with our auto-import names.
    // We look for _jsx, _jsxs, _Fragment (with optional digit suffixes) as standalone identifiers.
    var max_jsx: u32 = 0; // Highest N seen in _jsx, _jsx2, _jsx3, ...
    var max_jsxs: u32 = 0;
    var max_fragment: u32 = 0;
    var has_jsx_conflict = false;
    var has_jsxs_conflict = false;
    var has_fragment_conflict = false;

    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        // Look for '_' that starts an identifier
        if (source[i] != '_') continue;
        // Check if this is at a word boundary (start of file or preceded by non-alnum)
        if (i > 0 and (std.ascii.isAlphanumeric(source[i - 1]) or source[i - 1] == '_')) continue;

        if (i + 4 <= source.len and std.mem.eql(u8, source[i .. i + 4], "_jsx")) {
            const rest_start = i + 4;
            if (rest_start < source.len and source[rest_start] == 's') {
                // _jsxs or _jsxsN
                const after = rest_start + 1;
                const suffix = extractDigitSuffix(source, after);
                if (isWordBoundary(source, after + suffix.len)) {
                    has_jsxs_conflict = true;
                    const n = if (suffix.len == 0) @as(u32, 1) else (std.fmt.parseInt(u32, suffix, 10) catch 1);
                    if (n > max_jsxs) max_jsxs = n;
                }
            } else {
                // _jsx or _jsxN
                const suffix = extractDigitSuffix(source, rest_start);
                if (isWordBoundary(source, rest_start + suffix.len)) {
                    has_jsx_conflict = true;
                    const n = if (suffix.len == 0) @as(u32, 1) else (std.fmt.parseInt(u32, suffix, 10) catch 1);
                    if (n > max_jsx) max_jsx = n;
                }
            }
        } else if (i + 9 <= source.len and std.mem.eql(u8, source[i .. i + 9], "_Fragment")) {
            const rest_start = i + 9;
            const suffix = extractDigitSuffix(source, rest_start);
            if (isWordBoundary(source, rest_start + suffix.len)) {
                has_fragment_conflict = true;
                const n = if (suffix.len == 0) @as(u32, 1) else (std.fmt.parseInt(u32, suffix, 10) catch 1);
                if (n > max_fragment) max_fragment = n;
            }
        }
    }

    // Also scan for identifiers named 'jsx', '_react' etc that need special handling
    // For the complicated-scope test: look for `jsx` and `_react` as variable names

    if (has_jsx_conflict) {
        g_state.jsx_suffix = std.fmt.allocPrint(ctx.allocator, "{}", .{max_jsx + 1}) catch "";
    }
    if (has_jsxs_conflict) {
        g_state.jsxs_suffix = std.fmt.allocPrint(ctx.allocator, "{}", .{max_jsxs + 1}) catch "";
    }
    if (has_fragment_conflict) {
        g_state.fragment_suffix = std.fmt.allocPrint(ctx.allocator, "{}", .{max_fragment + 1}) catch "";
    }
}

fn extractDigitSuffix(source: []const u8, pos: usize) []const u8 {
    var end = pos;
    while (end < source.len and std.ascii.isDigit(source[end])) end += 1;
    return source[pos..end];
}

fn isWordBoundary(source: []const u8, pos: usize) bool {
    if (pos >= source.len) return true;
    const c = source[pos];
    return !std.ascii.isAlphanumeric(c) and c != '_' and c != '$';
}

/// Get the jsx call name with scope conflict suffix (e.g., "_jsx" or "_jsx2")
fn jsxCallName(alloc: std.mem.Allocator) []const u8 {
    if (g_state.jsx_suffix.len == 0) return "_jsx(";
    return std.fmt.allocPrint(alloc, "_jsx{s}(", .{g_state.jsx_suffix}) catch "_jsx(";
}

/// Get the jsxs call name with scope conflict suffix
fn jsxsCallName(alloc: std.mem.Allocator) []const u8 {
    if (g_state.jsxs_suffix.len == 0) return "_jsxs(";
    return std.fmt.allocPrint(alloc, "_jsxs{s}(", .{g_state.jsxs_suffix}) catch "_jsxs(";
}

fn enterNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    const tag = ctx.nodeTag(idx);

    switch (tag) {
        .jsx_element => {
            if (g_state.indent_depth == 0) {
                g_state.code_indent = @intCast(estimateJsxBlockDepth(ctx, idx));
            }
            transformJsxElement(idx, ctx);
            return .skip_children;
        },
        .jsx_self_closing_element => {
            if (g_state.indent_depth == 0) {
                g_state.code_indent = @intCast(estimateJsxBlockDepth(ctx, idx));
            }
            transformJsxSelfClosing(idx, ctx);
            return .skip_children;
        },
        .jsx_fragment => {
            if (g_state.indent_depth == 0) {
                g_state.code_indent = @intCast(estimateJsxBlockDepth(ctx, idx));
            }
            transformJsxFragment(idx, ctx);
            return .skip_children;
        },
        .program => {
            // Scan source for @jsx/@jsxFrag pragma comments
            detectPragmaComments(ctx);
            // Detect scope conflicts for auto-import names (_jsx, _jsxs, _Fragment)
            if (g_state.config.runtime == .automatic) {
                detectScopeConflicts(ctx);
            }
            return .continue_traversal;
        },
        else => return .continue_traversal,
    }
}

fn exitNode(idx: NodeIndex, ctx: *TransformContext) visitor.VisitResult {
    if (g_state.config.inject_display_name and ctx.nodeTag(idx) == .declarator) {
        maybeInjectDisplayName(idx, ctx);
    }
    return .continue_traversal;
}

fn maybeInjectDisplayName(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const binding = data.binary.lhs;
    const init = data.binary.rhs;
    if (binding == .none or init == .none) return;
    if (ctx.nodeTag(binding) != .identifier or ctx.nodeTag(init) != .call_expr) return;

    const component_name = ctx.tokenSlice(ctx.mainToken(binding));
    if (component_name.len == 0) return;

    const init_data = ctx.nodeData(init);
    const extra_idx = @intFromEnum(init_data.extra);
    if (extra_idx + 2 >= ctx.ast.extra_data.items.len) return;
    const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const args_start = ctx.ast.extra_data.items[extra_idx + 1];
    const args_end = ctx.ast.extra_data.items[extra_idx + 2];
    if (!isReactCreateClassCallee(ctx, callee) or args_end <= args_start) return;

    const first_arg: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[args_start]);
    if (first_arg == .none or ctx.nodeTag(first_arg) != .object_expr) return;
    if (objectHasDisplayName(ctx, first_arg)) return;

    const object_src = getNodeGeneratedSource(ctx, first_arg);
    const injected = injectDisplayNameIntoObjectSource(ctx.allocator, object_src, component_name) catch return;
    ctx.ast.replacement_source.put(ctx.allocator, @intFromEnum(first_arg), injected) catch {};
}

fn isReactCreateClassCallee(ctx: *TransformContext, callee: NodeIndex) bool {
    if (callee == .none or ctx.nodeTag(callee) != .member_expr) return false;
    const data = ctx.nodeData(callee);
    if (ctx.nodeTag(data.binary.lhs) != .identifier) return false;

    const object_name = ctx.tokenSlice(ctx.mainToken(data.binary.lhs));
    const prop_tok: TokenIndex = @enumFromInt(@intFromEnum(data.binary.rhs));
    const prop_name = ctx.tokenSlice(prop_tok);
    return std.mem.eql(u8, object_name, "React") and std.mem.eql(u8, prop_name, "createClass");
}

fn objectHasDisplayName(ctx: *TransformContext, object_expr: NodeIndex) bool {
    const data = ctx.nodeData(object_expr);
    const extra_idx = @intFromEnum(data.extra);
    if (extra_idx + 1 >= ctx.ast.extra_data.items.len) return false;
    const props_start = ctx.ast.extra_data.items[extra_idx];
    const props_end = ctx.ast.extra_data.items[extra_idx + 1];
    for (ctx.ast.extra_data.items[props_start..props_end]) |prop_raw| {
        const prop: NodeIndex = @enumFromInt(prop_raw);
        if (prop == .none) continue;
        const prop_tag = ctx.nodeTag(prop);
        switch (prop_tag) {
            .property, .computed_property => {
                const key = ctx.nodeData(prop).binary.lhs;
                if (propertyKeyEquals(ctx, key, "displayName")) return true;
            },
            .shorthand_property => {
                if (propertyKeyEquals(ctx, ctx.nodeData(prop).unary, "displayName")) return true;
            },
            else => {},
        }
    }
    return false;
}

fn propertyKeyEquals(ctx: *TransformContext, key: NodeIndex, expected: []const u8) bool {
    if (key == .none) return false;
    const tag = ctx.nodeTag(key);
    if (tag == .identifier) {
        return std.mem.eql(u8, ctx.tokenSlice(ctx.mainToken(key)), expected);
    }
    if (tag == .string_literal) {
        const raw = ctx.tokenSlice(ctx.mainToken(key));
        if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'')) {
            return std.mem.eql(u8, raw[1 .. raw.len - 1], expected);
        }
        return std.mem.eql(u8, raw, expected);
    }
    return false;
}

fn injectDisplayNameIntoObjectSource(allocator: std.mem.Allocator, object_src: []const u8, component_name: []const u8) ![]const u8 {
    if (object_src.len < 2 or object_src[0] != '{' or object_src[object_src.len - 1] != '}') {
        return std.fmt.allocPrint(allocator, "{{\n  displayName: \"{s}\"\n}}", .{component_name});
    }

    const inner = object_src[1 .. object_src.len - 1];
    const trimmed_inner = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed_inner.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\n  displayName: \"{s}\"\n}}", .{component_name});
    }

    const inner_body = std.mem.trimStart(u8, inner, "\r\n");
    return std.fmt.allocPrint(allocator, "{{\n  displayName: \"{s}\",\n{s}}}", .{ component_name, inner_body });
}

// ── JSX Element Transform ───────────────────────────────────────────────

fn transformJsxElement(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const opening: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    // closing: extra_idx + 1 (not needed)
    const children_start = ctx.ast.extra_data.items[extra_idx + 2];
    const children_end = ctx.ast.extra_data.items[extra_idx + 3];

    // Get opening element info
    const opening_data = ctx.nodeData(opening);
    const opening_extra = @intFromEnum(opening_data.extra);
    const name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[opening_extra]);
    const attrs_start = ctx.ast.extra_data.items[opening_extra + 1];
    const attrs_end = ctx.ast.extra_data.items[opening_extra + 2];

    var buf: Buf = .empty;
    const alloc = ctx.allocator;

    switch (g_state.config.runtime) {
        .classic => {
            emitClassicElement(ctx, &buf, alloc, name_node, attrs_start, attrs_end, children_start, children_end) catch return;
        },
        .automatic => {
            emitAutomaticElement(ctx, &buf, alloc, name_node, attrs_start, attrs_end, children_start, children_end) catch return;
        },
    }

    ctx.ast.replacement_source.put(alloc, @intFromEnum(idx), buf.items) catch return;
}

fn transformJsxSelfClosing(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    const name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
    const attrs_start = ctx.ast.extra_data.items[extra_idx + 1];
    const attrs_end = ctx.ast.extra_data.items[extra_idx + 2];

    var buf: Buf = .empty;
    const alloc = ctx.allocator;

    switch (g_state.config.runtime) {
        .classic => {
            emitClassicElement(ctx, &buf, alloc, name_node, attrs_start, attrs_end, 0, 0) catch return;
        },
        .automatic => {
            emitAutomaticElement(ctx, &buf, alloc, name_node, attrs_start, attrs_end, 0, 0) catch return;
        },
    }

    ctx.ast.replacement_source.put(alloc, @intFromEnum(idx), buf.items) catch return;
}

fn transformJsxFragment(idx: NodeIndex, ctx: *TransformContext) void {
    const data = ctx.nodeData(idx);
    const extra_idx = @intFromEnum(data.extra);
    // opening: extra_idx + 0 (not needed)
    // closing: extra_idx + 1 (not needed)
    const children_start = ctx.ast.extra_data.items[extra_idx + 2];
    const children_end = ctx.ast.extra_data.items[extra_idx + 3];

    var buf: Buf = .empty;
    const alloc = ctx.allocator;

    switch (g_state.config.runtime) {
        .classic => {
            emitClassicFragment(ctx, &buf, alloc, children_start, children_end) catch return;
        },
        .automatic => {
            emitAutomaticFragment(ctx, &buf, alloc, children_start, children_end) catch return;
        },
    }

    ctx.ast.replacement_source.put(alloc, @intFromEnum(idx), buf.items) catch return;
}

// ── Classic Mode ─────────────────────────────────────────────────────���──

fn emitClassicElement(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    name_node: NodeIndex,
    attrs_start: u32,
    attrs_end: u32,
    children_start: u32,
    children_end: u32,
) error{OutOfMemory}!void {
    const pragma = g_state.config.pragma;

    // /*#__PURE__*/
    if (shouldEmitPure()) {
        try buf.appendSlice(alloc, "/*#__PURE__*/");
    }

    // React.createElement(
    try buf.appendSlice(alloc, pragma);
    try buf.appendSlice(alloc, "(");

    // Tag name
    try emitTagName(ctx, buf, alloc, name_node);
    if (firstAttrInlineCommentRange(ctx, attrs_start, attrs_end)) |range| {
        try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
    }

    // Props
    const has_attrs = attrs_end > attrs_start;
    if (has_attrs and leadingSpreadObjectCommentRange(ctx, attrs_start, attrs_end) != null) {
        try buf.appendSlice(alloc, ",");
    } else {
        try buf.appendSlice(alloc, ", ");
    }
    if (has_attrs) {
        if (g_state.config.props_spread_mode != .preserve and hasNonInlineJsxSpread(ctx, attrs_start, attrs_end)) {
            try emitMergedPropsCall(ctx, buf, alloc, attrs_start, attrs_end, &[_]JsxChild{}, false);
        } else {
            try emitPropsObject(ctx, buf, alloc, attrs_start, attrs_end, false, null);
        }
    } else {
        try buf.appendSlice(alloc, "null");
    }

    // Children (classic mode: each child is a separate argument)
    const children = collectJsxChildren(ctx, alloc, children_start, children_end) catch &[_]JsxChild{};
    for (children) |child| {
        try buf.appendSlice(alloc, ", ");
        try emitChildValue(ctx, buf, alloc, child);
    }

    try buf.appendSlice(alloc, ")");
}

fn emitClassicFragment(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    children_start: u32,
    children_end: u32,
) error{OutOfMemory}!void {
    const pragma = g_state.config.pragma;
    const pragma_frag = g_state.config.pragma_frag;

    if (shouldEmitPure()) {
        try buf.appendSlice(alloc, "/*#__PURE__*/");
    }

    try buf.appendSlice(alloc, pragma);
    try buf.appendSlice(alloc, "(");
    try buf.appendSlice(alloc, pragma_frag);
    try buf.appendSlice(alloc, ", null");

    const children = collectJsxChildren(ctx, alloc, children_start, children_end) catch &[_]JsxChild{};
    for (children) |child| {
        try buf.appendSlice(alloc, ", ");
        try emitChildValue(ctx, buf, alloc, child);
    }

    try buf.appendSlice(alloc, ")");
}

// ── Automatic Mode ──────────────────────────────────────────────────────

fn emitAutomaticElement(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    name_node: NodeIndex,
    attrs_start: u32,
    attrs_end: u32,
    children_start: u32,
    children_end: u32,
) error{OutOfMemory}!void {
    g_state.indent_depth += 1;
    defer g_state.indent_depth -= 1;

    const children = collectJsxChildren(ctx, alloc, children_start, children_end) catch &[_]JsxChild{};
    const has_attrs = attrs_end > attrs_start;

    // Check for key prop and spread-before-key pattern
    var key_value: ?JsxChild = null;
    var has_spread_before_key = false;
    if (has_attrs) {
        var seen_spread = false;
        for (ctx.ast.extra_data.items[attrs_start..attrs_end]) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);
            if (attr_tag == .jsx_spread_attribute) {
                seen_spread = true;
                continue;
            }
            if (attr_tag == .jsx_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                const attr_name = getJsxAttrName(ctx, attr_data.binary.lhs);
                if (std.mem.eql(u8, attr_name, "key")) {
                    if (seen_spread) {
                        has_spread_before_key = true;
                    }
                    // Get the key value
                    key_value = getAttrValueAsChild(ctx, attr_data.binary.rhs);
                }
            }
        }
    }

    // Determine if we need jsx vs jsxs
    const use_jsxs = children.len > 1;
    const use_create_element = has_spread_before_key;

    // Pre-scan children to register their imports first (Babel uses bottom-up ordering)
    for (children) |child| {
        if (child.kind == .jsx_node and child.node != .none) {
            preRegisterJsxImports(ctx, alloc, child.node);
        }
    }
    // Also pre-scan attribute values for nested JSX
    if (has_attrs) {
        for (ctx.ast.extra_data.items[attrs_start..attrs_end]) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);
            if (attr_tag == .jsx_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                const val_n = attr_data.binary.rhs;
                if (val_n != .none) {
                    const val_tag = ctx.nodeTag(val_n);
                    if (val_tag == .jsx_expression_container) {
                        const inner_data = ctx.nodeData(val_n);
                        if (inner_data.unary != .none and isJsxNode(ctx.nodeTag(inner_data.unary))) {
                            preRegisterJsxImports(ctx, alloc, inner_data.unary);
                        }
                    } else if (isJsxNode(val_tag)) {
                        preRegisterJsxImports(ctx, alloc, val_n);
                    }
                }
            }
        }
    }

    // Now register this element's own import
    if (use_create_element) {
        g_state.registerCreateElement();
    } else if (use_jsxs) {
        g_state.registerJsxs();
    } else {
        g_state.registerJsx();
    }

    if (shouldEmitPure()) {
        try buf.appendSlice(alloc, "/*#__PURE__*/");
    }

    if (g_state.isScript()) {
        // CJS mode: _reactJsxRuntime.jsx(, _react.createElement(
        if (use_create_element) {
            const src_var = try g_state.cjsSourceVar(alloc);
            try buf.appendSlice(alloc, src_var);
            try buf.appendSlice(alloc, ".createElement(");
        } else {
            const rt_var = try g_state.cjsRuntimeVar(alloc);
            try buf.appendSlice(alloc, rt_var);
            if (use_jsxs) {
                try buf.appendSlice(alloc, ".jsxs(");
            } else {
                try buf.appendSlice(alloc, ".jsx(");
            }
        }
    } else {
        if (use_create_element) {
            try buf.appendSlice(alloc, "_createElement(");
        } else if (use_jsxs) {
            try buf.appendSlice(alloc, jsxsCallName(alloc));
        } else {
            try buf.appendSlice(alloc, jsxCallName(alloc));
        }
    }

    // Tag name
    try emitTagName(ctx, buf, alloc, name_node);
    if (firstAttrInlineCommentRange(ctx, attrs_start, attrs_end)) |range| {
        try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
    }
    if (leadingSpreadObjectCommentRange(ctx, attrs_start, attrs_end) != null) {
        try buf.appendSlice(alloc, ",");
    } else {
        try buf.appendSlice(alloc, ", ");
    }

    // Props object (including children for automatic mode)
    if (use_create_element) {
        // createElement mode: key stays in props, spread is preserved
        try emitCreateElementProps(ctx, buf, alloc, attrs_start, attrs_end, children);
    } else {
        try emitAutomaticProps(ctx, buf, alloc, attrs_start, attrs_end, children, key_value != null);
    }

    // Key as 3rd argument (only for jsx/jsxs, not createElement)
    if (!use_create_element) {
        if (key_value) |kv| {
            try buf.appendSlice(alloc, ", ");
            try emitChildValue(ctx, buf, alloc, kv);
        }
    }

    try buf.appendSlice(alloc, ")");
}

fn emitAutomaticFragment(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    children_start: u32,
    children_end: u32,
) error{OutOfMemory}!void {
    g_state.indent_depth += 1;
    defer g_state.indent_depth -= 1;

    const children = collectJsxChildren(ctx, alloc, children_start, children_end) catch &[_]JsxChild{};
    const use_jsxs = children.len > 1;

    // Pre-scan children for import ordering
    for (children) |child| {
        if (child.kind == .jsx_node and child.node != .none) {
            preRegisterJsxImports(ctx, alloc, child.node);
        }
    }

    g_state.registerFragment();
    if (use_jsxs) {
        g_state.registerJsxs();
    } else {
        g_state.registerJsx();
    }

    if (shouldEmitPure()) {
        try buf.appendSlice(alloc, "/*#__PURE__*/");
    }

    if (g_state.isScript()) {
        const rt_var = try g_state.cjsRuntimeVar(alloc);
        try buf.appendSlice(alloc, rt_var);
        if (use_jsxs) {
            try buf.appendSlice(alloc, ".jsxs(");
        } else {
            try buf.appendSlice(alloc, ".jsx(");
        }
        try buf.appendSlice(alloc, rt_var);
        try buf.appendSlice(alloc, ".Fragment, ");
    } else {
        if (use_jsxs) {
            try buf.appendSlice(alloc, jsxsCallName(alloc));
        } else {
            try buf.appendSlice(alloc, jsxCallName(alloc));
        }
        try buf.appendSlice(alloc, "_Fragment, ");
    }

    // Props with children
    try emitAutomaticProps(ctx, buf, alloc, 0, 0, children, false);

    try buf.appendSlice(alloc, ")");
}

// ── Props Emission ──────────────────────────────────────────────────────

fn emitPropsObject(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    attrs_start: u32,
    attrs_end: u32,
    is_automatic: bool,
    skip_key: ?bool,
) error{OutOfMemory}!void {
    const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
    if (attrs.len == 0 and !is_automatic) {
        try buf.appendSlice(alloc, "null");
        return;
    }

    // Check if we have only spread with no regular attrs
    var only_single_spread = false;
    var spread_count: u32 = 0;
    var regular_count: u32 = 0;
    for (attrs) |attr_raw| {
        const attr_idx: NodeIndex = @enumFromInt(attr_raw);
        if (attr_idx == .none) continue;
        const attr_tag = ctx.nodeTag(attr_idx);
        if (attr_tag == .jsx_spread_attribute) {
            spread_count += 1;
        } else {
            regular_count += 1;
        }
    }

    // Classic mode: single spread with no other attrs → just emit the spread expression
    // But only if the spread argument is NOT an object literal (those get inlined)
    if (!is_automatic and spread_count == 1 and regular_count == 0) {
        for (attrs) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);
            if (attr_tag == .jsx_spread_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                const arg_tag = ctx.nodeTag(attr_data.unary);
                if (arg_tag != .object_expr) {
                    only_single_spread = true;
                }
                break;
            }
        }
    }

    if (only_single_spread) {
        // Emit just the spread expression without object wrapper
        for (attrs) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);
            if (attr_tag == .jsx_spread_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                try emitExprSource(ctx, buf, alloc, attr_data.unary);
                return;
            }
        }
    }

    // Emit as object literal
    if (leadingSpreadObjectCommentRange(ctx, attrs_start, attrs_end)) |range| {
        try buf.appendSlice(alloc, "\n");
        try emitJsxGapCommentsClosingIndent(ctx, buf, alloc, range.from, range.to);
        try writeClosingIndent(buf, alloc);
    }
    try buf.appendSlice(alloc, "{\n");
    var first = true;
    var prev_attr_end: u32 = 0;
    var prev_was_spread = false;
    const first_attr_inline_comment = firstAttrInlineCommentRange(ctx, attrs_start, attrs_end);
    for (attrs) |attr_raw| {
        const attr_idx: NodeIndex = @enumFromInt(attr_raw);
        if (attr_idx == .none) continue;
        const attr_tag = ctx.nodeTag(attr_idx);

        // Get source position of current attribute for comment scanning
        const attr_start = getNodeStartPosition(ctx, attr_idx);

        if (attr_tag == .jsx_spread_attribute) {
            const attr_data = ctx.nodeData(attr_idx);
            // Emit spread: the argument is an expression
            // Check if the argument is an object_expr — if so, emit its properties inline
            // UNLESS the object has a __proto__ key (which must be kept as spread)
            const arg = attr_data.unary;
            const arg_tag = ctx.nodeTag(arg);
            if (arg_tag == .object_expr and !objectHasProtoKey(ctx, arg)) {
                // Inline the object properties
                try emitObjectExprInline(ctx, buf, alloc, arg, &first);
            } else {
                if (!first) try buf.appendSlice(alloc, ",\n");
                first = false;
                try writeIndent(buf, alloc);
                try buf.appendSlice(alloc, "...");
                // For object literals, format multiline
                if (arg_tag == .object_expr) {
                    try emitObjectExprMultiline(ctx, buf, alloc, arg);
                } else {
                    try emitExprSource(ctx, buf, alloc, arg);
                }
            }
            prev_attr_end = getNodeEndPosition(ctx, attr_idx);
            prev_was_spread = true;
        } else if (attr_tag == .jsx_attribute) {
            const attr_data = ctx.nodeData(attr_idx);
            const name_n = attr_data.binary.lhs;
            const val_n = attr_data.binary.rhs;
            const attr_name = getJsxAttrName(ctx, name_n);

            // Skip key in automatic mode (it becomes 3rd argument)
            if (skip_key orelse false) {
                if (std.mem.eql(u8, attr_name, "key")) continue;
            }

            const gap_start = if (prev_attr_end > 0) prev_attr_end else findTagNameEnd(ctx, attr_start);
            const inline_range = if (attr_start > gap_start) inlineCommentRange(ctx, gap_start, attr_start) else null;

            if (!first) {
                if (inline_range) |range| {
                    if (!prev_was_spread) {
                        try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
                    }
                }
                try buf.appendSlice(alloc, ",\n");
            }
            first = false;

            // Emit comments between previous attribute/element name and this one.
            // For the first attribute, scan from the element name end (estimated by
            // looking back from the attribute start for the end of the tag name).
            if (attr_start > 0) {
                if (attr_start > gap_start) {
                    const skip_first_attr_inline = prev_attr_end == 0 and first_attr_inline_comment != null;
                    if (!skip_first_attr_inline and inline_range == null) {
                        try emitJsxGapComments(ctx, buf, alloc, gap_start, attr_start);
                    }
                }
            }

            try writeIndent(buf, alloc);
            if (inline_range) |range| {
                if (prev_was_spread) {
                    try emitJsxRawComments(ctx, buf, alloc, range.from, range.to);
                }
            }
            try emitPropKey(buf, alloc, attr_name);

            if (val_n == .none) {
                // Boolean attribute: <Foo disabled /> → disabled: true
                try buf.appendSlice(alloc, ": true");
            } else {
                try buf.appendSlice(alloc, ": ");
                try emitAttrValue(ctx, buf, alloc, val_n);
            }
            prev_attr_end = getNodeEndPosition(ctx, attr_idx);
            prev_was_spread = false;
        }
    }

    if (!first) {
        if (trailingAttrInlineCommentRange(ctx, attrs_start, attrs_end)) |range| {
            try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
        }
        try buf.appendSlice(alloc, "\n");
        try writeClosingIndent(buf, alloc);
    }
    try buf.appendSlice(alloc, "}");
    if (trailingSpreadObjectCommentRange(ctx, attrs_start, attrs_end)) |range| {
        try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
    }
}

/// Emit props for automatic mode (includes children in the object).
fn emitAutomaticProps(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    attrs_start: u32,
    attrs_end: u32,
    children: []const JsxChild,
    skip_key: bool,
) error{OutOfMemory}!void {
    if (g_state.config.retain_lines) {
        try emitAutomaticPropsInline(ctx, buf, alloc, attrs_start, attrs_end, children, skip_key);
        return;
    }

    if (g_state.config.props_spread_mode != .preserve and hasNonInlineJsxSpread(ctx, attrs_start, attrs_end)) {
        try emitMergedPropsCall(ctx, buf, alloc, attrs_start, attrs_end, children, skip_key);
        return;
    }

    const has_attrs = attrs_end > attrs_start;
    const has_children = children.len > 0;

    // Count effective attrs (after filtering key)
    var effective_attrs: u32 = 0;
    if (has_attrs) {
        const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
        for (attrs) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);
            if (attr_tag == .jsx_attribute and skip_key) {
                const attr_data = ctx.nodeData(attr_idx);
                const attr_name = getJsxAttrName(ctx, attr_data.binary.lhs);
                if (std.mem.eql(u8, attr_name, "key")) continue;
            }
            effective_attrs += 1;
        }
    }

    if (effective_attrs == 0 and !has_children) {
        try buf.appendSlice(alloc, "{}");
        return;
    }

    if (leadingSpreadObjectCommentRange(ctx, attrs_start, attrs_end)) |range| {
        try buf.appendSlice(alloc, "\n");
        try emitJsxGapCommentsClosingIndent(ctx, buf, alloc, range.from, range.to);
        try writeClosingIndent(buf, alloc);
    }
    try buf.appendSlice(alloc, "{\n");
    var first = true;
    var prev_was_spread = false;
    const first_attr_inline_comment = firstAttrInlineCommentRange(ctx, attrs_start, attrs_end);

    // Emit attributes
    if (has_attrs) {
        const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
        var prev_attr_end_auto: u32 = 0;
        for (attrs) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);

            if (attr_tag == .jsx_spread_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                const arg = attr_data.unary;
                const arg_tag = ctx.nodeTag(arg);
                if (arg_tag == .object_expr and !objectHasProtoKey(ctx, arg)) {
                    try emitObjectExprInline(ctx, buf, alloc, arg, &first);
                } else {
                    if (!first) try buf.appendSlice(alloc, ",\n");
                    first = false;
                    try writeIndent(buf, alloc);
                    try buf.appendSlice(alloc, "...");
                    if (arg_tag == .object_expr) {
                        try emitObjectExprMultiline(ctx, buf, alloc, arg);
                    } else {
                        try emitExprSource(ctx, buf, alloc, arg);
                    }
                }
                prev_attr_end_auto = getNodeEndPosition(ctx, attr_idx);
                prev_was_spread = true;
            } else if (attr_tag == .jsx_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                const attr_name = getJsxAttrName(ctx, attr_data.binary.lhs);
                const a_start = getNodeStartPosition(ctx, attr_idx);

                // Skip key in automatic mode
                if (skip_key and std.mem.eql(u8, attr_name, "key")) continue;

                const gap_start = if (prev_attr_end_auto > 0) prev_attr_end_auto else findTagNameEnd(ctx, a_start);
                const inline_range = if (a_start > gap_start) inlineCommentRange(ctx, gap_start, a_start) else null;

                if (!first) {
                    if (inline_range) |range| {
                        if (!prev_was_spread) {
                            try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
                        }
                    }
                    try buf.appendSlice(alloc, ",\n");
                }
                first = false;

                // Emit comments between previous attribute and this one
                if (a_start > 0) {
                    if (a_start > gap_start) {
                        const skip_first_attr_inline = prev_attr_end_auto == 0 and first_attr_inline_comment != null;
                        if (!skip_first_attr_inline and inline_range == null) {
                            try emitJsxGapComments(ctx, buf, alloc, gap_start, a_start);
                        }
                    }
                }

                try writeIndent(buf, alloc);
                if (inline_range) |range| {
                    if (prev_was_spread) {
                        try emitJsxRawComments(ctx, buf, alloc, range.from, range.to);
                    }
                }
                try emitPropKey(buf, alloc, attr_name);

                const val_n = attr_data.binary.rhs;
                if (val_n == .none) {
                    try buf.appendSlice(alloc, ": true");
                } else {
                    try buf.appendSlice(alloc, ": ");
                    try emitAttrValue(ctx, buf, alloc, val_n);
                }
                prev_attr_end_auto = getNodeEndPosition(ctx, attr_idx);
                prev_was_spread = false;
            }
        }
    }

    // Emit children
    if (has_children) {
        if (!first) try buf.appendSlice(alloc, ",\n");
        first = false;
        try writeIndent(buf, alloc);
        try buf.appendSlice(alloc, "children: ");
        if (children.len == 1) {
            try emitChildValue(ctx, buf, alloc, children[0]);
        } else {
            try buf.appendSlice(alloc, "[");
            for (children, 0..) |child, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try emitChildValue(ctx, buf, alloc, child);
            }
            try buf.appendSlice(alloc, "]");
        }
    }

    if (!first) {
        if (trailingAttrInlineCommentRange(ctx, attrs_start, attrs_end)) |range| {
            try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
        }
    }
    try buf.appendSlice(alloc, "\n");
    try writeClosingIndent(buf, alloc);
    try buf.appendSlice(alloc, "}");
    if (trailingSpreadObjectCommentRange(ctx, attrs_start, attrs_end)) |range| {
        try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
    }
}

fn emitAutomaticPropsInline(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    attrs_start: u32,
    attrs_end: u32,
    children: []const JsxChild,
    skip_key: bool,
) error{OutOfMemory}!void {
    var inner: Buf = .empty;
    defer inner.deinit(alloc);

    if (attrs_end > attrs_start) {
        const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
        var first = true;
        for (attrs) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);

            if (attr_tag == .jsx_spread_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                if (!first) try inner.appendSlice(alloc, ", ");
                first = false;
                try inner.appendSlice(alloc, "...");
                try emitExprSource(ctx, &inner, alloc, attr_data.unary);
            } else if (attr_tag == .jsx_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                const attr_name = getJsxAttrName(ctx, attr_data.binary.lhs);
                if (skip_key and std.mem.eql(u8, attr_name, "key")) continue;
                if (!first) try inner.appendSlice(alloc, ", ");
                first = false;
                try emitPropKey(&inner, alloc, attr_name);
                if (attr_data.binary.rhs == .none) {
                    try inner.appendSlice(alloc, ": true");
                } else {
                    try inner.appendSlice(alloc, ": ");
                    try emitAttrValue(ctx, &inner, alloc, attr_data.binary.rhs);
                }
            }
        }
    }

    if (children.len > 0) {
        if (inner.items.len > 0) try inner.appendSlice(alloc, ", ");
        try inner.appendSlice(alloc, "children: ");
        if (children.len == 1) {
            try emitChildValue(ctx, &inner, alloc, children[0]);
        } else {
            try inner.appendSlice(alloc, "[");
            for (children, 0..) |child, i| {
                if (i > 0) try inner.appendSlice(alloc, ", ");
                try emitChildValue(ctx, &inner, alloc, child);
            }
            try inner.appendSlice(alloc, "]");
        }
    }

    if (inner.items.len == 0) {
        try buf.appendSlice(alloc, "{}");
    } else {
        try buf.appendSlice(alloc, "{ ");
        try buf.appendSlice(alloc, inner.items);
        try buf.appendSlice(alloc, " }");
    }
}

/// Emit props for createElement mode (key stays in props, spread preserved).
fn emitCreateElementProps(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    attrs_start: u32,
    attrs_end: u32,
    children: []const JsxChild,
) error{OutOfMemory}!void {
    if (g_state.config.props_spread_mode != .preserve and hasNonInlineJsxSpread(ctx, attrs_start, attrs_end)) {
        try emitMergedPropsCall(ctx, buf, alloc, attrs_start, attrs_end, children, false);
        return;
    }

    const has_attrs = attrs_end > attrs_start;

    if (!has_attrs and children.len == 0) {
        try buf.appendSlice(alloc, "{}");
        return;
    }

    if (leadingSpreadObjectCommentRange(ctx, attrs_start, attrs_end)) |range| {
        try buf.appendSlice(alloc, "\n");
        try emitJsxGapCommentsClosingIndent(ctx, buf, alloc, range.from, range.to);
        try writeClosingIndent(buf, alloc);
    }
    try buf.appendSlice(alloc, "{\n");
    var first = true;
    var prev_was_spread = false;
    const first_attr_inline_comment = firstAttrInlineCommentRange(ctx, attrs_start, attrs_end);

    if (has_attrs) {
        const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
        var prev_attr_end_ce: u32 = 0;
        for (attrs) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);

            if (attr_tag == .jsx_spread_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                const arg = attr_data.unary;
                const arg_tag = ctx.nodeTag(arg);
                if (arg_tag == .object_expr and !objectHasProtoKey(ctx, arg)) {
                    try emitObjectExprInline(ctx, buf, alloc, arg, &first);
                } else {
                    if (!first) try buf.appendSlice(alloc, ",\n");
                    first = false;
                    try writeIndent(buf, alloc);
                    try buf.appendSlice(alloc, "...");
                    if (arg_tag == .object_expr) {
                        try emitObjectExprMultiline(ctx, buf, alloc, arg);
                    } else {
                        try emitExprSource(ctx, buf, alloc, arg);
                    }
                }
                prev_attr_end_ce = getNodeEndPosition(ctx, attr_idx);
                prev_was_spread = true;
            } else if (attr_tag == .jsx_attribute) {
                const attr_data = ctx.nodeData(attr_idx);
                const attr_name = getJsxAttrName(ctx, attr_data.binary.lhs);
                const ce_start = getNodeStartPosition(ctx, attr_idx);

                const gap_start = if (prev_attr_end_ce > 0) prev_attr_end_ce else findTagNameEnd(ctx, ce_start);
                const inline_range = if (ce_start > gap_start) inlineCommentRange(ctx, gap_start, ce_start) else null;

                if (!first) {
                    if (inline_range) |range| {
                        if (!prev_was_spread) {
                            try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
                        }
                    }
                    try buf.appendSlice(alloc, ",\n");
                }
                first = false;

                // Emit comments between previous attribute and this one
                if (ce_start > 0) {
                    if (ce_start > gap_start) {
                        const skip_first_attr_inline = prev_attr_end_ce == 0 and first_attr_inline_comment != null;
                        if (!skip_first_attr_inline and inline_range == null) {
                            try emitJsxGapComments(ctx, buf, alloc, gap_start, ce_start);
                        }
                    }
                }

                try writeIndent(buf, alloc);
                if (inline_range) |range| {
                    if (prev_was_spread) {
                        try emitJsxRawComments(ctx, buf, alloc, range.from, range.to);
                    }
                }
                try emitPropKey(buf, alloc, attr_name);

                const val_n = attr_data.binary.rhs;
                if (val_n == .none) {
                    try buf.appendSlice(alloc, ": true");
                } else {
                    try buf.appendSlice(alloc, ": ");
                    try emitAttrValue(ctx, buf, alloc, val_n);
                }
                prev_attr_end_ce = getNodeEndPosition(ctx, attr_idx);
                prev_was_spread = false;
            }
        }
    }

    // Children for createElement
    if (children.len > 0) {
        if (!first) try buf.appendSlice(alloc, ",\n");
        try writeIndent(buf, alloc);
        try buf.appendSlice(alloc, "children: ");
        if (children.len == 1) {
            try emitChildValue(ctx, buf, alloc, children[0]);
        } else {
            try buf.appendSlice(alloc, "[");
            for (children, 0..) |child, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try emitChildValue(ctx, buf, alloc, child);
            }
            try buf.appendSlice(alloc, "]");
        }
    }

    if (!first) {
        if (trailingAttrInlineCommentRange(ctx, attrs_start, attrs_end)) |range| {
            try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
        }
    }
    try buf.appendSlice(alloc, "\n");
    try writeClosingIndent(buf, alloc);
    try buf.appendSlice(alloc, "}");
    if (trailingSpreadObjectCommentRange(ctx, attrs_start, attrs_end)) |range| {
        try emitJsxInlineComments(ctx, buf, alloc, range.from, range.to);
    }
}

fn hasNonInlineJsxSpread(ctx: *TransformContext, attrs_start: u32, attrs_end: u32) bool {
    if (attrs_end <= attrs_start) return false;
    const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
    for (attrs) |attr_raw| {
        const attr_idx: NodeIndex = @enumFromInt(attr_raw);
        if (attr_idx == .none or ctx.nodeTag(attr_idx) != .jsx_spread_attribute) continue;
        const arg = ctx.nodeData(attr_idx).unary;
        if (ctx.nodeTag(arg) == .object_expr and !objectHasProtoKey(ctx, arg)) continue;
        return true;
    }
    return false;
}

fn emitMergedPropsCall(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    attrs_start: u32,
    attrs_end: u32,
    children: []const JsxChild,
    skip_key: bool,
) error{OutOfMemory}!void {
    const callee = switch (g_state.config.props_spread_mode) {
        .object_assign => "Object.assign(",
        .babel_extends => "babelHelpers.extends(",
        .preserve => unreachable,
    };
    try buf.appendSlice(alloc, callee);
    try buf.appendSlice(alloc, "{}");

    var chunk: Buf = .empty;
    var chunk_first = true;
    var has_arg = false;

    if (attrs_end > attrs_start) {
        const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
        for (attrs) |attr_raw| {
            const attr_idx: NodeIndex = @enumFromInt(attr_raw);
            if (attr_idx == .none) continue;
            const attr_tag = ctx.nodeTag(attr_idx);

            if (attr_tag == .jsx_spread_attribute) {
                const arg = ctx.nodeData(attr_idx).unary;
                if (ctx.nodeTag(arg) == .object_expr and !objectHasProtoKey(ctx, arg)) {
                    try emitObjectExprInline(ctx, &chunk, alloc, arg, &chunk_first);
                    continue;
                }

                if (!chunk_first) {
                    try appendMergedPropsChunk(buf, alloc, &chunk, &chunk_first, &has_arg);
                }
                try buf.appendSlice(alloc, ", ");
                try emitExprSource(ctx, buf, alloc, arg);
                has_arg = true;
                continue;
            }

            if (attr_tag != .jsx_attribute) continue;
            const attr_data = ctx.nodeData(attr_idx);
            const attr_name = getJsxAttrName(ctx, attr_data.binary.lhs);
            if (skip_key and std.mem.eql(u8, attr_name, "key")) continue;

            if (!chunk_first) try chunk.appendSlice(alloc, ",\n");
            chunk_first = false;
            try writeIndent(&chunk, alloc);
            try emitPropKey(&chunk, alloc, attr_name);
            if (attr_data.binary.rhs == .none) {
                try chunk.appendSlice(alloc, ": true");
            } else {
                try chunk.appendSlice(alloc, ": ");
                try emitAttrValue(ctx, &chunk, alloc, attr_data.binary.rhs);
            }
        }
    }

    if (children.len > 0) {
        if (!chunk_first) try chunk.appendSlice(alloc, ",\n");
        chunk_first = false;
        try writeIndent(&chunk, alloc);
        try chunk.appendSlice(alloc, "children: ");
        if (children.len == 1) {
            try emitChildValue(ctx, &chunk, alloc, children[0]);
        } else {
            try chunk.appendSlice(alloc, "[");
            for (children, 0..) |child, i| {
                if (i > 0) try chunk.appendSlice(alloc, ", ");
                try emitChildValue(ctx, &chunk, alloc, child);
            }
            try chunk.appendSlice(alloc, "]");
        }
    }

    if (!chunk_first) {
        try appendMergedPropsChunk(buf, alloc, &chunk, &chunk_first, &has_arg);
    }

    try buf.appendSlice(alloc, ")");
}

fn appendMergedPropsChunk(
    buf: *Buf,
    alloc: std.mem.Allocator,
    chunk: *Buf,
    chunk_first: *bool,
    has_arg: *bool,
) error{OutOfMemory}!void {
    if (chunk_first.*) return;
    try buf.appendSlice(alloc, ", {\n");
    try buf.appendSlice(alloc, chunk.items);
    try buf.appendSlice(alloc, "\n");
    try writeClosingIndent(buf, alloc);
    try buf.appendSlice(alloc, "}");
    chunk.clearRetainingCapacity();
    chunk_first.* = true;
    has_arg.* = true;
}

// ── Tag Name Emission ───────────────────────────────────────────────────

fn emitTagName(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, name_node: NodeIndex) error{OutOfMemory}!void {
    const tag = ctx.nodeTag(name_node);
    switch (tag) {
        .jsx_identifier => {
            const name = getJsxIdentifierName(ctx, name_node);
            if (std.mem.eql(u8, name, "this")) {
                try buf.appendSlice(alloc, "this");
            } else if (name.len > 0 and isLowercase(name[0])) {
                // Lowercase: string literal
                try buf.append(alloc, '"');
                try buf.appendSlice(alloc, name);
                try buf.append(alloc, '"');
            } else {
                // Uppercase: identifier reference
                try buf.appendSlice(alloc, name);
            }
        },
        .jsx_member_expression => {
            try emitJsxMemberExpr(ctx, buf, alloc, name_node);
        },
        .jsx_namespaced_name => {
            const data = ctx.nodeData(name_node);
            const ns_name = getJsxIdentifierName(ctx, data.binary.lhs);
            const local_name = getJsxIdentifierName(ctx, data.binary.rhs);
            try buf.append(alloc, '"');
            try buf.appendSlice(alloc, ns_name);
            try buf.append(alloc, ':');
            try buf.appendSlice(alloc, local_name);
            try buf.append(alloc, '"');
        },
        else => {
            // Fallback: use source text
            try emitExprSource(ctx, buf, alloc, name_node);
        },
    }
}

fn emitJsxMemberExpr(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, node: NodeIndex) error{OutOfMemory}!void {
    const data = ctx.nodeData(node);
    const obj = data.binary.lhs;
    const prop = data.binary.rhs;

    const obj_tag = ctx.nodeTag(obj);
    if (obj_tag == .jsx_member_expression) {
        try emitJsxMemberExpr(ctx, buf, alloc, obj);
    } else {
        try buf.appendSlice(alloc, getJsxIdentifierName(ctx, obj));
    }
    try buf.append(alloc, '.');
    try buf.appendSlice(alloc, getJsxIdentifierName(ctx, prop));
}

// ── Attribute Helpers ───────────────────────────────────────────────────

/// Find the end of the JSX tag name by scanning backward from an attribute position.
/// This is used to determine the gap start for comment scanning before the first attribute.
fn findTagNameEnd(ctx: *TransformContext, attr_start: u32) u32 {
    if (attr_start == 0) return 0;
    const source = ctx.ast.source;
    var pos = attr_start;
    while (pos > 0) {
        pos -= 1;
        const c = source[pos];
        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        // If we hit a block comment end (`*/`), scan back to find comment start
        if (c == '/' and pos > 0 and source[pos - 1] == '*') {
            pos -= 1;
            while (pos > 1) {
                pos -= 1;
                if (source[pos] == '/' and source[pos + 1] == '*') {
                    break;
                }
            }
            continue;
        }
        // For any non-whitespace character, check if it's inside a line comment.
        // Find the start of the current line and look for `//`.
        {
            var line_start = pos;
            while (line_start > 0 and source[line_start - 1] != '\n') {
                line_start -= 1;
            }
            // Scan forward from line start looking for `//` before or at pos
            var lp = line_start;
            var found_line_comment = false;
            while (lp + 1 <= pos) {
                if (source[lp] == '/' and source[lp + 1] == '/') {
                    // Everything from `//` to end of line is a comment
                    // Skip backward past the entire line comment
                    pos = lp;
                    found_line_comment = true;
                    break;
                }
                lp += 1;
            }
            if (found_line_comment) continue;
        }
        // Hit the tag name or some JSX syntax
        return pos + 1;
    }
    return 0;
}

/// Get the start source position of a node.
fn getNodeStartPosition(ctx: *TransformContext, node: NodeIndex) u32 {
    const i = @intFromEnum(node);
    const main_tok = ctx.ast.nodes.items(.main_token)[i];
    return ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
}

/// Get the end source position of a node.
fn getNodeEndPosition(ctx: *TransformContext, node: NodeIndex) u32 {
    const i = @intFromEnum(node);
    return ctx.ast.nodes.items(.end_offset)[i];
}

/// Emit comments found in the source gap between two positions.
/// Used to preserve comments between JSX attributes in the generated props object.
fn emitJsxGapComments(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, from: u32, to: u32) error{OutOfMemory}!void {
    if (from >= to or to > ctx.ast.source.len) return;
    const gap = ctx.ast.source[from..to];
    var i: usize = 0;
    while (i < gap.len) {
        if (gap[i] == '/' and i + 1 < gap.len) {
            if (gap[i + 1] == '/') {
                // Line comment
                const start = i;
                const abs_pos = from + @as(u32, @intCast(start));
                while (i < gap.len and gap[i] != '\n') i += 1;
                try writeIndent(buf, alloc);
                try buf.appendSlice(alloc, gap[start..i]);
                try buf.appendSlice(alloc, "\n");
                if (i < gap.len) i += 1;
                // Mark as consumed so codegen doesn't duplicate it
                ctx.ast.consumed_comments.put(ctx.allocator, abs_pos, {}) catch {};
                continue;
            } else if (gap[i + 1] == '*') {
                // Block comment
                const start = i;
                const abs_pos = from + @as(u32, @intCast(start));
                i += 2;
                while (i + 1 < gap.len) {
                    if (gap[i] == '*' and gap[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                // For multi-line block comments, re-indent continuation lines
                const comment_text = gap[start..i];
                try writeIndent(buf, alloc);
                try emitReindentedBlockComment(buf, alloc, comment_text, abs_pos, ctx);
                try buf.appendSlice(alloc, "\n");
                // Mark as consumed so codegen doesn't duplicate it
                ctx.ast.consumed_comments.put(ctx.allocator, abs_pos, {}) catch {};
                continue;
            }
        }
        i += 1;
    }
}

fn emitJsxGapCommentsClosingIndent(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, from: u32, to: u32) error{OutOfMemory}!void {
    if (from >= to or to > ctx.ast.source.len) return;
    const gap = ctx.ast.source[from..to];
    var i: usize = 0;
    while (i < gap.len) {
        if (gap[i] == '/' and i + 1 < gap.len) {
            if (gap[i + 1] == '/') {
                const start = i;
                const abs_pos = from + @as(u32, @intCast(start));
                while (i < gap.len and gap[i] != '\n') i += 1;
                try writeClosingIndent(buf, alloc);
                try buf.appendSlice(alloc, gap[start..i]);
                try buf.appendSlice(alloc, "\n");
                if (i < gap.len) i += 1;
                ctx.ast.consumed_comments.put(ctx.allocator, abs_pos, {}) catch {};
                continue;
            } else if (gap[i + 1] == '*') {
                const start = i;
                const abs_pos = from + @as(u32, @intCast(start));
                i += 2;
                while (i + 1 < gap.len) {
                    if (gap[i] == '*' and gap[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                const comment_text = gap[start..i];
                try writeClosingIndent(buf, alloc);
                try emitReindentedBlockComment(buf, alloc, comment_text, abs_pos, ctx);
                try buf.appendSlice(alloc, "\n");
                ctx.ast.consumed_comments.put(ctx.allocator, abs_pos, {}) catch {};
                continue;
            }
        }
        i += 1;
    }
}

fn emitJsxInlineComments(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, from: u32, to: u32) error{OutOfMemory}!void {
    if (from >= to or to > ctx.ast.source.len) return;
    const gap = ctx.ast.source[from..to];
    var i: usize = 0;
    var first = true;
    while (i < gap.len) {
        if (gap[i] == '/' and i + 1 < gap.len) {
            if (gap[i + 1] == '/') {
                const start = i;
                const abs_pos = from + @as(u32, @intCast(start));
                while (i < gap.len and gap[i] != '\n') i += 1;
                if (first) {
                    try buf.appendSlice(alloc, " ");
                    first = false;
                } else {
                    try buf.appendSlice(alloc, " ");
                }
                try buf.appendSlice(alloc, gap[start..i]);
                ctx.ast.consumed_comments.put(ctx.allocator, abs_pos, {}) catch {};
                continue;
            } else if (gap[i + 1] == '*') {
                const start = i;
                const abs_pos = from + @as(u32, @intCast(start));
                i += 2;
                while (i + 1 < gap.len) {
                    if (gap[i] == '*' and gap[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                if (first) {
                    try buf.appendSlice(alloc, " ");
                    first = false;
                } else {
                    try buf.appendSlice(alloc, " ");
                }
                try buf.appendSlice(alloc, gap[start..i]);
                ctx.ast.consumed_comments.put(ctx.allocator, abs_pos, {}) catch {};
                continue;
            }
        }
        i += 1;
    }
}

fn emitJsxRawComments(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, from: u32, to: u32) error{OutOfMemory}!void {
    if (from >= to or to > ctx.ast.source.len) return;
    const gap = ctx.ast.source[from..to];
    var i: usize = 0;
    while (i < gap.len) {
        if (gap[i] == '/' and i + 1 < gap.len) {
            if (gap[i + 1] == '/') {
                const start = i;
                const abs_pos = from + @as(u32, @intCast(start));
                while (i < gap.len and gap[i] != '\n') i += 1;
                try buf.appendSlice(alloc, gap[start..i]);
                ctx.ast.consumed_comments.put(ctx.allocator, abs_pos, {}) catch {};
                continue;
            } else if (gap[i + 1] == '*') {
                const start = i;
                const abs_pos = from + @as(u32, @intCast(start));
                i += 2;
                while (i + 1 < gap.len) {
                    if (gap[i] == '*' and gap[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                try buf.appendSlice(alloc, gap[start..i]);
                ctx.ast.consumed_comments.put(ctx.allocator, abs_pos, {}) catch {};
                continue;
            }
        }
        i += 1;
    }
}

const CommentRange = struct {
    from: u32,
    to: u32,
};

fn leadingSpreadObjectCommentRange(ctx: *TransformContext, attrs_start: u32, attrs_end: u32) ?CommentRange {
    if (attrs_end <= attrs_start) return null;
    const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
    for (attrs) |attr_raw| {
        const attr_idx: NodeIndex = @enumFromInt(attr_raw);
        if (attr_idx == .none) continue;
        if (ctx.nodeTag(attr_idx) != .jsx_spread_attribute) return null;

        const arg = ctx.nodeData(attr_idx).unary;
        if (arg == .none or ctx.nodeTag(arg) != .object_expr or objectHasProtoKey(ctx, arg)) return null;

        const from = getNodeStartPosition(ctx, attr_idx);
        const to = getNodeStartPosition(ctx, arg);
        if (from >= to or !hasCommentInSourceRange(ctx.ast.source, from, to)) return null;
        return .{ .from = from, .to = to };
    }
    return null;
}

fn firstAttrInlineCommentRange(ctx: *TransformContext, attrs_start: u32, attrs_end: u32) ?CommentRange {
    if (attrs_end <= attrs_start) return null;
    const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
    for (attrs) |attr_raw| {
        const attr_idx: NodeIndex = @enumFromInt(attr_raw);
        if (attr_idx == .none) continue;
        if (ctx.nodeTag(attr_idx) != .jsx_attribute) return null;

        const attr_start = getNodeStartPosition(ctx, attr_idx);
        const from = findTagNameEnd(ctx, attr_start);
        const to = attr_start;
        return inlineCommentRange(ctx, from, to);
    }
    return null;
}

fn trailingSpreadObjectCommentRange(ctx: *TransformContext, attrs_start: u32, attrs_end: u32) ?CommentRange {
    if (attrs_end <= attrs_start) return null;
    const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
    if (attrs.len != 1) return null;

    const attr_idx: NodeIndex = @enumFromInt(attrs[0]);
    if (attr_idx == .none or ctx.nodeTag(attr_idx) != .jsx_spread_attribute) return null;

    const arg = ctx.nodeData(attr_idx).unary;
    if (arg == .none or ctx.nodeTag(arg) != .object_expr or objectHasProtoKey(ctx, arg)) return null;

    const from = getNodeEndPosition(ctx, arg);
    const to = getNodeEndPosition(ctx, attr_idx);
    if (from >= to or !hasCommentInSourceRange(ctx.ast.source, from, to)) return null;
    return .{ .from = from, .to = to };
}

fn trailingAttrInlineCommentRange(ctx: *TransformContext, attrs_start: u32, attrs_end: u32) ?CommentRange {
    if (attrs_end <= attrs_start) return null;
    const attrs = ctx.ast.extra_data.items[attrs_start..attrs_end];
    var last_attr: ?NodeIndex = null;
    for (attrs) |attr_raw| {
        const attr_idx: NodeIndex = @enumFromInt(attr_raw);
        if (attr_idx != .none) last_attr = attr_idx;
    }
    const attr_idx = last_attr orelse return null;
    if (ctx.nodeTag(attr_idx) != .jsx_attribute) return null;

    const from = getNodeEndPosition(ctx, attr_idx);
    const to = findJsxTagCloseStart(ctx, from);
    return inlineCommentRange(ctx, from, to);
}

fn hasCommentInSourceRange(source: []const u8, from: u32, to: u32) bool {
    if (from >= to or to > source.len) return false;
    const gap = source[from..to];
    var i: usize = 0;
    while (i + 1 < gap.len) : (i += 1) {
        if (gap[i] == '/' and (gap[i + 1] == '/' or gap[i + 1] == '*')) return true;
    }
    return false;
}

fn hasNewlineInSourceRange(source: []const u8, from: u32, to: u32) bool {
    if (from >= to or to > source.len) return false;
    return std.mem.indexOfScalar(u8, source[from..to], '\n') != null;
}

fn inlineCommentRange(ctx: *TransformContext, from: u32, to: u32) ?CommentRange {
    if (from >= to or hasNewlineInSourceRange(ctx.ast.source, from, to)) return null;
    if (!hasCommentInSourceRange(ctx.ast.source, from, to)) return null;
    return .{ .from = from, .to = to };
}

fn findJsxTagCloseStart(ctx: *TransformContext, from: u32) u32 {
    const source = ctx.ast.source;
    var pos: u32 = from;
    while (pos < source.len and source[pos] != '>') : (pos += 1) {}
    var end = pos;
    while (end > from and std.ascii.isWhitespace(source[end - 1])) {
        end -= 1;
    }
    if (end > from and source[end - 1] == '/' and (end < 2 or source[end - 2] != '*')) {
        end -= 1;
        while (end > from and std.ascii.isWhitespace(source[end - 1])) {
            end -= 1;
        }
    }
    return end;
}

/// Emit a block comment with re-indented continuation lines.
/// The base indent of the comment in source is determined by the column of `/*`,
/// and continuation lines are adjusted to match the current output indent.
fn emitReindentedBlockComment(buf: *Buf, alloc: std.mem.Allocator, comment: []const u8, source_pos: u32, ctx: *TransformContext) error{OutOfMemory}!void {
    // Find the source column of the `/*` start
    const source = ctx.ast.source;
    var source_col: u32 = 0;
    if (source_pos > 0) {
        var p = source_pos;
        while (p > 0) {
            p -= 1;
            if (source[p] == '\n') break;
            source_col += 1;
        }
    }

    // Check if this is a single-line comment
    if (std.mem.indexOfScalar(u8, comment, '\n') == null) {
        try buf.appendSlice(alloc, comment);
        return;
    }

    // Multi-line: emit first line as-is, then re-indent continuation lines
    // Target indent: writeIndent level (which is 2 spaces per INDENT_SPACES)
    var line_start: usize = 0;
    var first_line = true;
    for (comment, 0..) |c, ci| {
        if (c == '\n' or ci == comment.len - 1) {
            const line_end = if (c == '\n') ci else ci + 1;
            if (first_line) {
                try buf.appendSlice(alloc, comment[line_start..line_end]);
                try buf.appendSlice(alloc, "\n");
                first_line = false;
            } else {
                // Strip the original indentation and apply new indent
                var stripped_start = line_start;
                while (stripped_start < line_end and (comment[stripped_start] == ' ' or comment[stripped_start] == '\t')) {
                    stripped_start += 1;
                }
                // Apply new indent: same as writeIndent + extra spaces to align with `/*` content
                try writeIndent(buf, alloc);
                // Add spaces to align continuation (e.g., `   ` in `/* ...\n   ... */`)
                const original_content_col = stripped_start - line_start;
                const comment_start_col = source_col; // column where `/*` was
                if (original_content_col > comment_start_col) {
                    const extra = original_content_col - comment_start_col;
                    var s: u32 = 0;
                    while (s < extra) : (s += 1) {
                        try buf.append(alloc, ' ');
                    }
                }
                try buf.appendSlice(alloc, comment[stripped_start..line_end]);
                if (c == '\n') try buf.appendSlice(alloc, "\n");
            }
            line_start = ci + 1;
        }
    }
}

fn getJsxAttrName(ctx: *TransformContext, name_node: NodeIndex) []const u8 {
    const tag = ctx.nodeTag(name_node);
    if (tag == .jsx_identifier) {
        return getJsxIdentifierName(ctx, name_node);
    }
    if (tag == .jsx_namespaced_name) {
        // For namespaced attributes, we need the full "ns:name" form
        return getNodeSourceText(ctx, name_node);
    }
    return getNodeSourceText(ctx, name_node);
}

fn getJsxIdentifierName(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const i = @intFromEnum(node);
    const main_tok = ctx.ast.nodes.items(.main_token)[i];
    const start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
    const end_off = ctx.ast.nodes.items(.end_offset)[i];
    if (end_off > start and end_off <= ctx.ast.source.len) {
        return ctx.ast.source[start..end_off];
    }
    return ctx.tokenSlice(main_tok);
}

fn emitAttrValue(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, val_node: NodeIndex) error{OutOfMemory}!void {
    const tag = ctx.nodeTag(val_node);
    switch (tag) {
        .jsx_string_literal => {
            // JSX string literal: emit as JS string with proper quoting
            const main_tok = ctx.mainToken(val_node);
            const start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
            const end = ctx.ast.tokens.items(.end)[@intFromEnum(main_tok)];
            const raw = ctx.ast.source[start..end];
            // Strip outer quotes and re-emit with double quotes
            if (raw.len >= 2) {
                const content = raw[1 .. raw.len - 1];
                try buf.append(alloc, '"');
                try emitJsxStringContent(buf, alloc, content);
                try buf.append(alloc, '"');
            } else {
                try buf.appendSlice(alloc, raw);
            }
        },
        .jsx_expression_container => {
            // {expr} → emit the inner expression
            const data = ctx.nodeData(val_node);
            const inner = data.unary;
            if (inner != .none) {
                const inner_tag = ctx.nodeTag(inner);
                // Check if inner is itself a JSX element
                if (isJsxNode(inner_tag)) {
                    try emitJsxNodeRecursive(ctx, buf, alloc, inner);
                } else {
                    // Collapse multi-line expressions to single line
                    try emitExprSourceCollapsed(ctx, buf, alloc, inner);
                }
            }
        },
        // JSX element as attribute value (no expression container)
        .jsx_element, .jsx_self_closing_element, .jsx_fragment => {
            try emitJsxNodeRecursive(ctx, buf, alloc, val_node);
        },
        else => {
            try emitExprSource(ctx, buf, alloc, val_node);
        },
    }
}

fn getAttrValueAsChild(ctx: *TransformContext, val_node: NodeIndex) JsxChild {
    if (val_node == .none) return .{ .kind = .literal, .text = "true" };
    const tag = ctx.nodeTag(val_node);
    switch (tag) {
        .jsx_string_literal => {
            const main_tok = ctx.mainToken(val_node);
            const start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];
            const end = ctx.ast.tokens.items(.end)[@intFromEnum(main_tok)];
            const raw = ctx.ast.source[start..end];
            return .{ .kind = .literal, .text = raw };
        },
        .jsx_expression_container => {
            const data = ctx.nodeData(val_node);
            return .{ .kind = .expression, .node = data.unary };
        },
        else => return .{ .kind = .expression, .node = val_node },
    }
}

// ── Children Handling ───────────────────────────────────────────────────

const JsxChild = struct {
    kind: enum { text, expression, jsx_node, literal },
    text: []const u8 = "",
    node: NodeIndex = .none,
};

fn collectJsxChildren(
    ctx: *TransformContext,
    alloc: std.mem.Allocator,
    children_start: u32,
    children_end: u32,
) ![]const JsxChild {
    if (children_end <= children_start) return &[_]JsxChild{};

    var result: std.ArrayListUnmanaged(JsxChild) = .empty;

    const raw_children = ctx.ast.extra_data.items[children_start..children_end];
    for (raw_children) |child_raw| {
        const child_idx: NodeIndex = @enumFromInt(child_raw);
        if (child_idx == .none) continue;
        const child_tag = ctx.nodeTag(child_idx);

        switch (child_tag) {
            .jsx_text => {
                // Get the text and trim per JSX whitespace rules
                const data = ctx.nodeData(child_idx);
                const extra_idx = @intFromEnum(data.extra);
                const text_start = ctx.ast.extra_data.items[extra_idx];
                const text_end = ctx.ast.extra_data.items[extra_idx + 1];
                const raw = ctx.ast.source[text_start..text_end];
                const trimmed = trimJsxText(alloc, raw) catch continue;
                if (trimmed.len > 0) {
                    try result.append(alloc, .{ .kind = .text, .text = trimmed });
                }
            },
            .jsx_expression_container => {
                const data = ctx.nodeData(child_idx);
                const inner = data.unary;
                if (inner != .none) {
                    const inner_tag = ctx.nodeTag(inner);
                    if (inner_tag == .jsx_empty_expression) continue;
                    if (isJsxNode(inner_tag)) {
                        try result.append(alloc, .{ .kind = .jsx_node, .node = inner });
                    } else {
                        try result.append(alloc, .{ .kind = .expression, .node = inner });
                    }
                }
            },
            .jsx_spread_child => {
                const data = ctx.nodeData(child_idx);
                try result.append(alloc, .{ .kind = .expression, .node = data.unary });
            },
            .jsx_element, .jsx_self_closing_element, .jsx_fragment => {
                try result.append(alloc, .{ .kind = .jsx_node, .node = child_idx });
            },
            .removed => continue,
            else => {
                try result.append(alloc, .{ .kind = .expression, .node = child_idx });
            },
        }
    }

    return result.items;
}

fn emitChildValue(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, child: JsxChild) error{OutOfMemory}!void {
    switch (child.kind) {
        .text => {
            try buf.append(alloc, '"');
            try emitJsxDecodedText(buf, alloc, child.text);
            try buf.append(alloc, '"');
        },
        .literal => {
            try buf.appendSlice(alloc, child.text);
        },
        .expression => {
            if (child.node != .none) {
                const tag = ctx.nodeTag(child.node);
                if (tag == .array_expr) {
                    // Array expression may contain JSX nodes — transform them
                    try emitArrayWithJsx(ctx, buf, alloc, child.node);
                } else {
                    try emitExprSource(ctx, buf, alloc, child.node);
                }
            }
        },
        .jsx_node => {
            if (child.node != .none) {
                try emitJsxNodeRecursive(ctx, buf, alloc, child.node);
            }
        },
    }
}

/// Emit an array expression, transforming any JSX nodes inside it.
fn emitArrayWithJsx(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, node: NodeIndex) error{OutOfMemory}!void {
    const data = ctx.nodeData(node);
    const extra_idx = @intFromEnum(data.extra);
    const elems_start = ctx.ast.extra_data.items[extra_idx];
    const elems_end = ctx.ast.extra_data.items[extra_idx + 1];

    try buf.append(alloc, '[');
    var first = true;
    for (ctx.ast.extra_data.items[elems_start..elems_end]) |elem_raw| {
        const elem_idx: NodeIndex = @enumFromInt(elem_raw);
        if (elem_idx == .none) continue;

        if (!first) try buf.appendSlice(alloc, ", ");
        first = false;

        const elem_tag = ctx.nodeTag(elem_idx);
        if (isJsxNode(elem_tag)) {
            try emitJsxNodeRecursive(ctx, buf, alloc, elem_idx);
        } else {
            try emitExprSource(ctx, buf, alloc, elem_idx);
        }
    }
    try buf.append(alloc, ']');
}

// ── JSX Text Whitespace Trimming ──────────────────────────────���─────────

/// Trim JSX text per Babel's whitespace rules:
/// 1. If no newlines, return as-is (no trimming for single-line text)
/// 2. Split by newlines
/// 3. Trim trailing whitespace from all lines
/// 4. Trim leading whitespace from lines after the first
/// 5. Remove leading/trailing empty lines
/// 6. Join non-empty lines with " "
/// 7. Return empty string if all whitespace
fn trimJsxText(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return "";

    // Check if there are any newlines
    var has_newline = false;
    for (raw) |c| {
        if (c == '\n') {
            has_newline = true;
            break;
        }
    }

    if (!has_newline) {
        // Single line: no trimming at all
        // But escape backslashes and quotes for JS string
        return raw;
    }

    // Split into lines
    var lines_buf: std.ArrayListUnmanaged([]const u8) = .empty;

    var start: usize = 0;
    for (raw, 0..) |c, i| {
        if (c == '\n') {
            // Also strip \r before \n
            const end = if (i > start and raw[i - 1] == '\r') i - 1 else i;
            try lines_buf.append(alloc, raw[start..end]);
            start = i + 1;
        }
    }
    try lines_buf.append(alloc, raw[start..]);

    const lines = lines_buf.items;
    if (lines.len == 0) return "";

    // Process lines:
    // - First line: trim right only
    // - Middle/last lines: trim both sides
    var processed: std.ArrayListUnmanaged([]const u8) = .empty;
    for (lines, 0..) |line, i| {
        var trimmed: []const u8 = undefined;
        if (i == 0) {
            // First line: only trim right
            trimmed = std.mem.trimEnd(u8, line, " \t");
        } else {
            // Other lines: trim both sides
            trimmed = std.mem.trim(u8, line, " \t");
        }
        try processed.append(alloc, trimmed);
    }

    // Remove leading empty lines
    var proc_start: usize = 0;
    while (proc_start < processed.items.len and processed.items[proc_start].len == 0) {
        proc_start += 1;
    }

    // Remove trailing empty lines
    var proc_end: usize = processed.items.len;
    while (proc_end > proc_start and processed.items[proc_end - 1].len == 0) {
        proc_end -= 1;
    }

    if (proc_start >= proc_end) return "";

    // Join remaining lines with space
    var result: Buf = .empty;
    var first = true;
    for (processed.items[proc_start..proc_end]) |line| {
        if (line.len == 0) continue; // Skip inner empty lines too
        if (!first) {
            try result.append(alloc, ' ');
        }
        first = false;
        try result.appendSlice(alloc, line);
    }

    return result.items;
}

// ── Object Expression Inline ─────────────────────────────���──────────────

/// Check if an object expression has a __proto__ key in a non-shorthand property.
/// Objects with non-shorthand `__proto__` properties should not be inlined
/// (the spread wrapper must be preserved to avoid prototype pollution).
/// Shorthand `__proto__` (without `:`) is OK to inline.
fn objectHasProtoKey(ctx: *TransformContext, obj_node: NodeIndex) bool {
    const data = ctx.nodeData(obj_node);
    const extra_idx = @intFromEnum(data.extra);
    const props_start = ctx.ast.extra_data.items[extra_idx];
    const props_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[props_start..props_end]) |prop_raw| {
        const prop_idx: NodeIndex = @enumFromInt(prop_raw);
        if (prop_idx == .none) continue;
        const prop_tag = ctx.nodeTag(prop_idx);
        // Only check non-shorthand properties
        if (prop_tag == .property) {
            // Regular property: key is in binary.lhs
            const prop_data = ctx.nodeData(prop_idx);
            const key_node = prop_data.binary.lhs;
            if (key_node != .none) {
                const key_text = getNodeSourceText(ctx, key_node);
                if (std.mem.eql(u8, key_text, "__proto__") or
                    std.mem.eql(u8, key_text, "\"__proto__\"") or
                    std.mem.eql(u8, key_text, "'__proto__'"))
                {
                    return true;
                }
            }
        }
        // computed_property: [expr]: value — these are OK to inline even with __proto__
        // shorthand_property (__proto__ without `:`) is OK to inline
    }
    return false;
}

/// Emit the properties of an object expression inline (for spread attribute flattening).
fn emitObjectExprInline(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    obj_node: NodeIndex,
    first: *bool,
) error{OutOfMemory}!void {
    const data = ctx.nodeData(obj_node);
    const extra_idx = @intFromEnum(data.extra);
    const props_start = ctx.ast.extra_data.items[extra_idx];
    const props_end = ctx.ast.extra_data.items[extra_idx + 1];

    for (ctx.ast.extra_data.items[props_start..props_end]) |prop_raw| {
        const prop_idx: NodeIndex = @enumFromInt(prop_raw);
        if (prop_idx == .none) continue;

        if (!first.*) try buf.appendSlice(alloc, ",\n");
        first.* = false;

        try writeIndent(buf, alloc);
        // Emit the property source text
        try emitExprSource(ctx, buf, alloc, prop_idx);
    }
}

/// Emit an object expression in multiline format: `{\n    key: value\n  }`
/// Properties are indented one level deeper than the current indent.
fn emitObjectExprMultiline(
    ctx: *TransformContext,
    buf: *Buf,
    alloc: std.mem.Allocator,
    obj_node: NodeIndex,
) error{OutOfMemory}!void {
    const data = ctx.nodeData(obj_node);
    const extra_idx = @intFromEnum(data.extra);
    const props_start = ctx.ast.extra_data.items[extra_idx];
    const props_end = ctx.ast.extra_data.items[extra_idx + 1];

    try buf.appendSlice(alloc, "{\n");

    // Temporarily increase indent for the object's content
    g_state.indent_depth += 1;
    defer g_state.indent_depth -= 1;

    var first = true;
    for (ctx.ast.extra_data.items[props_start..props_end]) |prop_raw| {
        const prop_idx: NodeIndex = @enumFromInt(prop_raw);
        if (prop_idx == .none) continue;

        if (!first) try buf.appendSlice(alloc, ",\n");
        first = false;

        try writeIndent(buf, alloc);
        try emitExprSource(ctx, buf, alloc, prop_idx);
    }
    if (!first) {
        try buf.appendSlice(alloc, "\n");
        // Closing brace at the level BEFORE the increase
        try writeClosingIndent(buf, alloc);
    }
    try buf.appendSlice(alloc, "}");
}

// ── Recursive JSX Node Emission ─────────────────────────────────────────

/// Recursively transform a JSX node and emit it as its replacement form.
fn emitJsxNodeRecursive(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, node: NodeIndex) error{OutOfMemory}!void {
    const tag = ctx.nodeTag(node);
    switch (tag) {
        .jsx_element => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            const opening: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const children_start = ctx.ast.extra_data.items[extra_idx + 2];
            const children_end = ctx.ast.extra_data.items[extra_idx + 3];

            const opening_data = ctx.nodeData(opening);
            const opening_extra = @intFromEnum(opening_data.extra);
            const name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[opening_extra]);
            const attrs_start = ctx.ast.extra_data.items[opening_extra + 1];
            const attrs_end = ctx.ast.extra_data.items[opening_extra + 2];

            switch (g_state.config.runtime) {
                .classic => try emitClassicElement(ctx, buf, alloc, name_node, attrs_start, attrs_end, children_start, children_end),
                .automatic => try emitAutomaticElement(ctx, buf, alloc, name_node, attrs_start, attrs_end, children_start, children_end),
            }
        },
        .jsx_self_closing_element => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            const name_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const attrs_start = ctx.ast.extra_data.items[extra_idx + 1];
            const attrs_end = ctx.ast.extra_data.items[extra_idx + 2];

            switch (g_state.config.runtime) {
                .classic => try emitClassicElement(ctx, buf, alloc, name_node, attrs_start, attrs_end, 0, 0),
                .automatic => try emitAutomaticElement(ctx, buf, alloc, name_node, attrs_start, attrs_end, 0, 0),
            }
        },
        .jsx_fragment => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            const children_start = ctx.ast.extra_data.items[extra_idx + 2];
            const children_end = ctx.ast.extra_data.items[extra_idx + 3];

            switch (g_state.config.runtime) {
                .classic => try emitClassicFragment(ctx, buf, alloc, children_start, children_end),
                .automatic => try emitAutomaticFragment(ctx, buf, alloc, children_start, children_end),
            }
        },
        else => {
            // Not a JSX node, emit source text
            try emitExprSource(ctx, buf, alloc, node);
        },
    }
}

// ── Source Text Helpers ──────────────────────────��───────────────────────

fn emitExprSource(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, node: NodeIndex) error{OutOfMemory}!void {
    if (node == .none) return;
    const text = getNodeSourceText(ctx, node);
    try buf.appendSlice(alloc, text);
}

/// Emit expression source text with whitespace collapsed to single spaces.
/// This handles multi-line JSX attribute expressions like `"foo" + "bar" +\n  "baz"`.
fn emitExprSourceCollapsed(ctx: *TransformContext, buf: *Buf, alloc: std.mem.Allocator, node: NodeIndex) error{OutOfMemory}!void {
    if (node == .none) return;
    const text = getNodeSourceText(ctx, node);

    // Check if the text contains newlines — if not, emit as-is (fast path)
    if (std.mem.indexOf(u8, text, "\n") == null) {
        try buf.appendSlice(alloc, text);
        return;
    }

    // Collapse runs of whitespace (including newlines) to single spaces
    // Be careful not to collapse whitespace inside string literals
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'' or c == '`') {
            // Copy string literal verbatim
            try buf.append(alloc, c);
            i += 1;
            while (i < text.len and text[i] != c) {
                if (text[i] == '\\' and i + 1 < text.len) {
                    try buf.append(alloc, text[i]);
                    i += 1;
                }
                try buf.append(alloc, text[i]);
                i += 1;
            }
            if (i < text.len) {
                try buf.append(alloc, text[i]);
                i += 1;
            }
        } else if (c == '\n' or c == '\r') {
            // Collapse whitespace sequence to single space
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) {
                i += 1;
            }
            // Only add space if there's content before and after
            if (buf.items.len > 0 and i < text.len) {
                // Check if previous char already is a space
                if (buf.items[buf.items.len - 1] != ' ') {
                    try buf.append(alloc, ' ');
                }
            }
        } else {
            try buf.append(alloc, c);
            i += 1;
        }
    }
}

fn getNodeSourceText(ctx: *TransformContext, node: NodeIndex) []const u8 {
    const i = @intFromEnum(node);
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

fn getNodeStartPos(ctx: *TransformContext, node: NodeIndex) u32 {
    const i = @intFromEnum(node);
    const tag = ctx.ast.nodes.items(.tag)[i];
    const data = ctx.ast.nodes.items(.data)[i];
    const main_tok = ctx.ast.nodes.items(.main_token)[i];
    const mt_start = ctx.ast.tokens.items(.start)[@intFromEnum(main_tok)];

    switch (tag) {
        .call_expr, .optional_call_expr, .new_expr => {
            const extra_idx = @intFromEnum(data.extra);
            const callee: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            if (callee != .none) {
                const callee_start = getNodeStartPos(ctx, callee);
                if (tag == .new_expr) return @min(mt_start, callee_start);
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
        .unary_expr, .update_expr => return mt_start,
        .ts_as_expression, .ts_satisfies_expression => {
            const lhs_start = getNodeStartPos(ctx, data.binary.lhs);
            return @min(lhs_start, mt_start);
        },
        .ts_non_null_expression => {
            const inner_start = getNodeStartPos(ctx, data.unary);
            return @min(inner_start, mt_start);
        },
        .parenthesized_expr => return mt_start,
        .conditional_expr => {
            const lhs_start = getNodeStartPos(ctx, data.binary.lhs);
            return @min(lhs_start, mt_start);
        },
        .assignment_expr => {
            const lhs_start = getNodeStartPos(ctx, data.binary.lhs);
            return @min(lhs_start, mt_start);
        },
        .sequence_expr => {
            // Get the first element of the range
            const extra_idx = @intFromEnum(data.extra);
            const range_start = ctx.ast.extra_data.items[extra_idx];
            const range_end = ctx.ast.extra_data.items[extra_idx + 1];
            if (range_end > range_start) {
                const first_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[range_start]);
                if (first_node != .none) {
                    return @min(getNodeStartPos(ctx, first_node), mt_start);
                }
            }
        },
        .array_expr => return mt_start,
        .object_expr => return mt_start,
        .spread_element => return mt_start,
        .template_literal => return mt_start,
        .tagged_template_expr => {
            const extra_idx = @intFromEnum(data.extra);
            const tag_node: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            if (tag_node != .none) {
                return @min(getNodeStartPos(ctx, tag_node), mt_start);
            }
        },
        else => return mt_start,
    }
    return mt_start;
}

// ── JSX String Content ──────────────────────────────────────────────────

/// Emit JSX text content with HTML entity decoding and JS string escaping.
fn emitJsxDecodedText(buf: *Buf, alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            // Try to decode HTML entity
            if (decodeHtmlEntity(text[i..])) |decoded| {
                // Emit the decoded character(s)
                try emitJsEscapedChar(buf, alloc, decoded.codepoint);
                i += decoded.len;
                continue;
            }
        }
        // Regular character: apply JS string escaping
        const c = text[i];
        if (c >= 0x80) {
            // Non-ASCII: decode UTF-8 and decide whether to escape
            const utf8_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            if (i + utf8_len <= text.len) {
                const cp = std.unicode.utf8Decode(text[i..][0..utf8_len]) catch {
                    // Invalid UTF-8: just copy the byte
                    try buf.append(alloc, c);
                    i += 1;
                    continue;
                };
                // Babel keeps most non-ASCII chars as-is but we need to match its behavior:
                // Non-breaking space (U+00A0) and other control-like chars get \xNN or \uNNNN
                // Regular characters (like accented letters) are kept as UTF-8
                if (cp == 0xA0 or (cp >= 0x80 and cp < 0xA0)) {
                    // Escape as \xNN
                    try emitJsEscapedChar(buf, alloc, cp);
                } else {
                    // Keep as UTF-8
                    try buf.appendSlice(alloc, text[i..][0..utf8_len]);
                }
                i += utf8_len;
            } else {
                try buf.append(alloc, c);
                i += 1;
            }
            continue;
        }
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
        i += 1;
    }
}

const HtmlEntityResult = struct {
    codepoint: u21,
    len: usize, // bytes consumed
};

fn decodeHtmlEntity(text: []const u8) ?HtmlEntityResult {
    if (text.len < 2 or text[0] != '&') return null;

    // Find semicolon
    var end: usize = 1;
    while (end < text.len and end < 12) : (end += 1) {
        if (text[end] == ';') break;
    }
    if (end >= text.len or text[end] != ';') return null;

    const entity = text[1..end];
    const total_len = end + 1;

    // Numeric entity
    if (entity.len > 1 and entity[0] == '#') {
        if (entity[1] == 'x' or entity[1] == 'X') {
            // Hex: &#xNNN;
            const hex = entity[2..];
            const val = std.fmt.parseInt(u21, hex, 16) catch return null;
            return .{ .codepoint = val, .len = total_len };
        } else {
            // Decimal: &#NNN;
            const dec = entity[1..];
            const val = std.fmt.parseInt(u21, dec, 10) catch return null;
            return .{ .codepoint = val, .len = total_len };
        }
    }

    // Named entities
    if (std.mem.eql(u8, entity, "nbsp")) return .{ .codepoint = 0xA0, .len = total_len };
    if (std.mem.eql(u8, entity, "amp")) return .{ .codepoint = '&', .len = total_len };
    if (std.mem.eql(u8, entity, "lt")) return .{ .codepoint = '<', .len = total_len };
    if (std.mem.eql(u8, entity, "gt")) return .{ .codepoint = '>', .len = total_len };
    if (std.mem.eql(u8, entity, "quot")) return .{ .codepoint = '"', .len = total_len };
    if (std.mem.eql(u8, entity, "apos")) return .{ .codepoint = '\'', .len = total_len };
    if (std.mem.eql(u8, entity, "mdash")) return .{ .codepoint = 0x2014, .len = total_len };
    if (std.mem.eql(u8, entity, "ndash")) return .{ .codepoint = 0x2013, .len = total_len };
    if (std.mem.eql(u8, entity, "hellip")) return .{ .codepoint = 0x2026, .len = total_len };
    if (std.mem.eql(u8, entity, "laquo")) return .{ .codepoint = 0xAB, .len = total_len };
    if (std.mem.eql(u8, entity, "raquo")) return .{ .codepoint = 0xBB, .len = total_len };
    if (std.mem.eql(u8, entity, "copy")) return .{ .codepoint = 0xA9, .len = total_len };
    if (std.mem.eql(u8, entity, "reg")) return .{ .codepoint = 0xAE, .len = total_len };
    if (std.mem.eql(u8, entity, "trade")) return .{ .codepoint = 0x2122, .len = total_len };

    return null;
}

fn emitJsEscapedChar(buf: *Buf, alloc: std.mem.Allocator, codepoint: u21) error{OutOfMemory}!void {
    if (codepoint < 0x80) {
        // ASCII: regular char, but escape special ones
        const c: u8 = @intCast(codepoint);
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    } else if (codepoint <= 0xFF) {
        // Latin1: use \xNN
        var tmp: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "\\x{X:0>2}", .{codepoint}) catch return;
        try buf.appendSlice(alloc, s);
    } else if (codepoint <= 0xFFFF) {
        // BMP: use \uNNNN
        var tmp: [6]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "\\u{X:0>4}", .{codepoint}) catch return;
        try buf.appendSlice(alloc, s);
    } else {
        // Supplementary: use \u{NNNNNN} or surrogate pair
        var tmp: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "\\u{{{X}}}", .{codepoint}) catch return;
        try buf.appendSlice(alloc, s);
    }
}

fn emitJsxStringContent(buf: *Buf, alloc: std.mem.Allocator, content: []const u8) error{OutOfMemory}!void {
    // Convert JSX string content to JS string with HTML entity decoding.
    try emitJsxDecodedText(buf, alloc, content);
}

// ── Utility ───────────────────────────────────────────────────────────��─

/// Search multi-line comment body for a pragma like "@jsx funcName".
/// Returns the value (e.g., "funcName") if found, null otherwise.
fn findPragmaInMultiline(body: []const u8, pragma_prefix: []const u8) ?[]const u8 {
    // Search each line for the pragma
    var line_start: usize = 0;
    while (line_start < body.len) {
        // Find end of line
        var line_end = line_start;
        while (line_end < body.len and body[line_end] != '\n') : (line_end += 1) {}

        const line = body[line_start..line_end];
        // Trim line: strip leading whitespace and * characters
        const trimmed = std.mem.trimStart(u8, std.mem.trim(u8, line, " \t\r"), " *");

        if (std.mem.startsWith(u8, trimmed, pragma_prefix)) {
            const val = std.mem.trim(u8, trimmed[pragma_prefix.len..], " \t\r\n");
            if (val.len > 0) return val;
        }

        line_start = line_end + 1;
    }

    // Also try the whole body as a single line (after trimming)
    const trimmed = std.mem.trimStart(u8, body, " *\t\r\n");
    if (std.mem.startsWith(u8, trimmed, pragma_prefix)) {
        const val = std.mem.trim(u8, trimmed[pragma_prefix.len..], " \t\r\n");
        if (val.len > 0) return val;
    }

    return null;
}

/// Recursively pre-scan a JSX node to register its imports in bottom-up order.
fn preRegisterJsxImports(ctx: *TransformContext, alloc: std.mem.Allocator, node: NodeIndex) void {
    if (node == .none) return;
    const tag = ctx.nodeTag(node);

    switch (tag) {
        .jsx_element => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            const opening: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[extra_idx]);
            const children_start = ctx.ast.extra_data.items[extra_idx + 2];
            const children_end = ctx.ast.extra_data.items[extra_idx + 3];

            // Pre-register children first
            const children = collectJsxChildren(ctx, alloc, children_start, children_end) catch &[_]JsxChild{};
            for (children) |child| {
                if (child.kind == .jsx_node and child.node != .none) {
                    preRegisterJsxImports(ctx, alloc, child.node);
                }
            }

            // Pre-register attribute value JSX
            const opening_data = ctx.nodeData(opening);
            const opening_extra = @intFromEnum(opening_data.extra);
            const attrs_start = ctx.ast.extra_data.items[opening_extra + 1];
            const attrs_end = ctx.ast.extra_data.items[opening_extra + 2];
            preRegisterAttrJsx(ctx, alloc, attrs_start, attrs_end);

            // Register this node
            if (children.len > 1) {
                g_state.registerJsxs();
            } else {
                g_state.registerJsx();
            }
        },
        .jsx_self_closing_element => {
            // Pre-register attribute value JSX
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            const attrs_start = ctx.ast.extra_data.items[extra_idx + 1];
            const attrs_end = ctx.ast.extra_data.items[extra_idx + 2];
            preRegisterAttrJsx(ctx, alloc, attrs_start, attrs_end);

            g_state.registerJsx();
        },
        .jsx_fragment => {
            const data = ctx.nodeData(node);
            const extra_idx = @intFromEnum(data.extra);
            const children_start = ctx.ast.extra_data.items[extra_idx + 2];
            const children_end = ctx.ast.extra_data.items[extra_idx + 3];

            const children = collectJsxChildren(ctx, alloc, children_start, children_end) catch &[_]JsxChild{};
            for (children) |child| {
                if (child.kind == .jsx_node and child.node != .none) {
                    preRegisterJsxImports(ctx, alloc, child.node);
                }
            }

            g_state.registerFragment();
            if (children.len > 1) {
                g_state.registerJsxs();
            } else {
                g_state.registerJsx();
            }
        },
        else => {},
    }
}

fn preRegisterAttrJsx(ctx: *TransformContext, alloc: std.mem.Allocator, attrs_start: u32, attrs_end: u32) void {
    if (attrs_end <= attrs_start) return;
    for (ctx.ast.extra_data.items[attrs_start..attrs_end]) |attr_raw| {
        const attr_idx: NodeIndex = @enumFromInt(attr_raw);
        if (attr_idx == .none) continue;
        const attr_tag = ctx.nodeTag(attr_idx);
        if (attr_tag == .jsx_attribute) {
            const attr_data = ctx.nodeData(attr_idx);
            const val_n = attr_data.binary.rhs;
            if (val_n != .none) {
                const val_tag = ctx.nodeTag(val_n);
                if (val_tag == .jsx_expression_container) {
                    const inner_data = ctx.nodeData(val_n);
                    if (inner_data.unary != .none and isJsxNode(ctx.nodeTag(inner_data.unary))) {
                        preRegisterJsxImports(ctx, alloc, inner_data.unary);
                    }
                } else if (isJsxNode(val_tag)) {
                    preRegisterJsxImports(ctx, alloc, val_n);
                }
            }
        }
    }
}

/// Write indent spaces based on current depth.
/// Always writes at least 2 spaces (base indent for properties),
/// plus 2 more for each additional nesting level.
fn writeIndent(buf: *Buf, alloc: std.mem.Allocator) error{OutOfMemory}!void {
    const code_depth = g_state.code_indent;
    const jsx_depth = g_state.indent_depth;
    // In automatic mode, indent_depth starts at 1 for each JSX element.
    // In classic mode, indent_depth is always 0 at the base props level.
    // The +1 ensures at least one level for the props object.
    const is_classic = (g_state.config.runtime == .classic);
    const total = code_depth + jsx_depth + @as(u8, if (is_classic) 1 else 0);
    var i: u8 = 0;
    while (i < total) : (i += 1) {
        try buf.appendSlice(alloc, "  ");
    }
}

/// Write the closing brace indentation (one level less than writeIndent).
fn writeClosingIndent(buf: *Buf, alloc: std.mem.Allocator) error{OutOfMemory}!void {
    const code_depth = g_state.code_indent;
    const jsx_depth = g_state.indent_depth;
    const is_classic = (g_state.config.runtime == .classic);
    const content_level = code_depth + jsx_depth + @as(u8, if (is_classic) 1 else 0);
    const total: u8 = if (content_level > 0) content_level - 1 else 0;
    var i: u8 = 0;
    while (i < total) : (i += 1) {
        try buf.appendSlice(alloc, "  ");
    }
}

/// Estimate the block nesting depth of a JSX node by counting { and } before it in the source.
fn estimateJsxBlockDepth(ctx: *TransformContext, idx: NodeIndex) usize {
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
            const quote = source[i];
            i += 1;
            while (i < tok_start and source[i] != quote) {
                if (source[i] == '\\' and i + 1 < tok_start) i += 1;
                i += 1;
            }
        } else if (source[i] == '/' and i + 1 < tok_start) {
            if (source[i + 1] == '/') {
                while (i < tok_start and source[i] != '\n') i += 1;
            } else if (source[i + 1] == '*') {
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

fn isLowercase(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

/// Emit a property key, quoting it if it contains non-identifier characters (like hyphens).
fn emitPropKey(buf: *Buf, alloc: std.mem.Allocator, name: []const u8) error{OutOfMemory}!void {
    if (needsQuoting(name) or (g_state.config.es3_property_literals and isEs3ReservedWord(name))) {
        try buf.append(alloc, '"');
        try buf.appendSlice(alloc, name);
        try buf.append(alloc, '"');
    } else {
        try buf.appendSlice(alloc, name);
    }
}

/// Check if an attribute name needs quoting as a JS property key.
/// Names with hyphens, dots, or other non-identifier chars need quoting.
fn needsQuoting(name: []const u8) bool {
    if (name.len == 0) return true;
    // First char must be letter, underscore, or dollar
    const first = name[0];
    if (!isIdentStart(first)) return true;
    for (name[1..]) |c| {
        if (!isIdentPart(c)) return true;
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isEs3ReservedWord(name: []const u8) bool {
    return std.mem.eql(u8, name, "abstract") or
        std.mem.eql(u8, name, "boolean") or
        std.mem.eql(u8, name, "break") or
        std.mem.eql(u8, name, "byte") or
        std.mem.eql(u8, name, "case") or
        std.mem.eql(u8, name, "catch") or
        std.mem.eql(u8, name, "char") or
        std.mem.eql(u8, name, "class") or
        std.mem.eql(u8, name, "const") or
        std.mem.eql(u8, name, "continue") or
        std.mem.eql(u8, name, "debugger") or
        std.mem.eql(u8, name, "default") or
        std.mem.eql(u8, name, "delete") or
        std.mem.eql(u8, name, "do") or
        std.mem.eql(u8, name, "double") or
        std.mem.eql(u8, name, "else") or
        std.mem.eql(u8, name, "enum") or
        std.mem.eql(u8, name, "export") or
        std.mem.eql(u8, name, "extends") or
        std.mem.eql(u8, name, "final") or
        std.mem.eql(u8, name, "finally") or
        std.mem.eql(u8, name, "float") or
        std.mem.eql(u8, name, "for") or
        std.mem.eql(u8, name, "function") or
        std.mem.eql(u8, name, "goto") or
        std.mem.eql(u8, name, "if") or
        std.mem.eql(u8, name, "implements") or
        std.mem.eql(u8, name, "import") or
        std.mem.eql(u8, name, "in") or
        std.mem.eql(u8, name, "instanceof") or
        std.mem.eql(u8, name, "int") or
        std.mem.eql(u8, name, "interface") or
        std.mem.eql(u8, name, "long") or
        std.mem.eql(u8, name, "native") or
        std.mem.eql(u8, name, "new") or
        std.mem.eql(u8, name, "package") or
        std.mem.eql(u8, name, "private") or
        std.mem.eql(u8, name, "protected") or
        std.mem.eql(u8, name, "public") or
        std.mem.eql(u8, name, "return") or
        std.mem.eql(u8, name, "short") or
        std.mem.eql(u8, name, "static") or
        std.mem.eql(u8, name, "super") or
        std.mem.eql(u8, name, "switch") or
        std.mem.eql(u8, name, "synchronized") or
        std.mem.eql(u8, name, "this") or
        std.mem.eql(u8, name, "throw") or
        std.mem.eql(u8, name, "throws") or
        std.mem.eql(u8, name, "transient") or
        std.mem.eql(u8, name, "try") or
        std.mem.eql(u8, name, "typeof") or
        std.mem.eql(u8, name, "var") or
        std.mem.eql(u8, name, "void") or
        std.mem.eql(u8, name, "volatile") or
        std.mem.eql(u8, name, "while") or
        std.mem.eql(u8, name, "with");
}

fn isJsxNode(tag: Node.Tag) bool {
    return tag == .jsx_element or
        tag == .jsx_self_closing_element or
        tag == .jsx_fragment;
}

fn shouldEmitPure() bool {
    const config = g_state.config;
    // Explicit pure setting overrides everything
    if (config.pure) |p| return p;
    // Default: pure for default pragma/source, not pure for custom
    if (config.runtime == .classic) {
        return std.mem.eql(u8, config.pragma, "React.createElement");
    }
    // Automatic mode: pure only with default import source
    return std.mem.eql(u8, config.import_source, "react");
}

// ── Import Injection (Automatic Mode) ─────────────────────────────���─────

/// Generate the import statement(s) for automatic mode.
/// Called after the full transform to prepend imports.
pub fn getAutomaticImports(alloc: std.mem.Allocator) !?[]const u8 {
    if (g_state.config.runtime != .automatic) return null;

    const needs_any = g_state.needs_jsx or g_state.needs_jsxs or g_state.needs_fragment;
    const needs_ce = g_state.needs_create_element;

    if (!needs_any and !needs_ce) return null;

    var buf: Buf = .empty;
    const line_end = if (g_state.config.retain_lines) "" else "\n";

    if (g_state.isScript()) {
        // CJS mode: var _react = require("react"); var _reactJsxRuntime = require("react/jsx-runtime");
        // Babel puts the base source require first, then the jsx-runtime require.
        if (needs_ce) {
            const src_var = try g_state.cjsSourceVar(alloc);
            try buf.appendSlice(alloc, "var ");
            try buf.appendSlice(alloc, src_var);
            try buf.appendSlice(alloc, " = require(\"");
            try buf.appendSlice(alloc, g_state.config.import_source);
            try buf.appendSlice(alloc, "\");");
            try buf.appendSlice(alloc, line_end);
        }
        if (needs_any) {
            const rt_var = try g_state.cjsRuntimeVar(alloc);
            try buf.appendSlice(alloc, "var ");
            try buf.appendSlice(alloc, rt_var);
            try buf.appendSlice(alloc, " = require(\"");
            try buf.appendSlice(alloc, g_state.config.import_source);
            try buf.appendSlice(alloc, "/jsx-runtime\");");
            try buf.appendSlice(alloc, line_end);
        }
    } else {
        // ESM mode: import { jsx as _jsx, ... } from "react/jsx-runtime";
        if (needs_any) {
            try buf.appendSlice(alloc, "import { ");

            // Emit in first-use order (with scope conflict suffix)
            const ImportSpec = struct { name: []const u8, order: u8, needed: bool };
            const jsx_spec = std.fmt.allocPrint(alloc, "jsx as _jsx{s}", .{g_state.jsx_suffix}) catch "jsx as _jsx";
            const jsxs_spec = std.fmt.allocPrint(alloc, "jsxs as _jsxs{s}", .{g_state.jsxs_suffix}) catch "jsxs as _jsxs";
            const frag_spec = std.fmt.allocPrint(alloc, "Fragment as _Fragment{s}", .{g_state.fragment_suffix}) catch "Fragment as _Fragment";
            var specs = [_]ImportSpec{
                .{ .name = jsx_spec, .order = g_state.jsx_order, .needed = g_state.needs_jsx },
                .{ .name = jsxs_spec, .order = g_state.jsxs_order, .needed = g_state.needs_jsxs },
                .{ .name = frag_spec, .order = g_state.fragment_order, .needed = g_state.needs_fragment },
            };

            // Sort by registration order
            std.mem.sort(ImportSpec, &specs, {}, struct {
                fn lessThan(_: void, a: ImportSpec, b: ImportSpec) bool {
                    return a.order < b.order;
                }
            }.lessThan);

            var first = true;
            for (specs) |spec| {
                if (!spec.needed) continue;
                if (!first) try buf.appendSlice(alloc, ", ");
                first = false;
                try buf.appendSlice(alloc, spec.name);
            }

            try buf.appendSlice(alloc, " } from \"");
            try buf.appendSlice(alloc, g_state.config.import_source);
            try buf.appendSlice(alloc, "/jsx-runtime\";");
            try buf.appendSlice(alloc, line_end);
        }

        // import { createElement as _createElement } from "react";
        if (needs_ce) {
            try buf.appendSlice(alloc, "import { createElement as _createElement } from \"");
            try buf.appendSlice(alloc, g_state.config.import_source);
            try buf.appendSlice(alloc, "\";");
            try buf.appendSlice(alloc, line_end);
        }
    }

    return buf.items;
}
