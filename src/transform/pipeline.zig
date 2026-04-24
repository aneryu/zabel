const std = @import("std");
const Ast = @import("../ast.zig").Ast;
const Node = @import("../ast.zig").Node;
const NodeIndex = @import("../ast.zig").NodeIndex;
const TokenIndex = @import("../ast.zig").TokenIndex;
const Allocator = std.mem.Allocator;
const visitor = @import("visitor.zig");
const ast_ops = @import("ast_ops.zig");
const scope_mod = @import("../scope.zig");
const replacement_index_mod = @import("replacement_index.zig");
const session_mod = @import("session.zig");
const telemetry_mod = @import("../telemetry.zig");

/// Resolved enum member value (for cross-enum reference tracking).
pub const ResolvedEnumValue = struct {
    kind: Kind,
    is_pure: bool = true,

    const Kind = union(enum) {
        number: f64,
        string: []const u8,
    };
};

// ── TransformContext ─────────────────────────────────────────────────

pub const TransformContext = struct {
    ast: *Ast,
    allocator: Allocator,

    /// Set by transforms to request an `export {};` module marker at end of program.
    needs_module_marker: bool = false,
    /// Force module marker emission even when regular imports remain.
    force_module_marker: bool = false,

    /// Set when the TS strip pass runs.
    had_ts_strip_pass: bool = false,

    /// Track seen enum/namespace names for merging detection.
    seen_enum_names: std.StringHashMapUnmanaged(void) = .empty,
    /// Track NodeIndex of enums that are inside export_named.
    exported_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Counter for generating unique namespace parameter names (_N, _N2, _N3, ...).
    ns_param_counter: u32 = 0,
    /// Track used namespace parameter names to avoid collisions.
    ns_used_params: std.StringHashMapUnmanaged(u32) = .empty,
    /// Resolved enum member values for cross-enum reference resolution.
    /// Keys are "EnumName.MemberName" strings, values store the resolved value.
    enum_member_values: std.StringHashMapUnmanaged(ResolvedEnumValue) = .empty,
    /// Outer constant values (simple const/var with literal initializers).
    /// Populated lazily for enum constant folding.
    outer_const_values: std.StringHashMapUnmanaged(ResolvedEnumValue) = .empty,
    /// Whether outer constants have been scanned.
    outer_const_scan_done: bool = false,

    /// Import usage analysis: names that are only used in type positions (should be elided).
    /// Populated lazily by the TS strip pass on first import_declaration encounter.
    type_only_imports: std.StringHashMapUnmanaged(void) = .empty,
    /// Set of all imported binding names (for tracking).
    all_import_names: std.StringHashMapUnmanaged(void) = .empty,
    /// Whether the import usage scan has been performed.
    import_scan_done: bool = false,
    /// Names that are declared as type-only in the program scope
    /// (interface, type alias, declare-only entities).
    type_only_decls: std.StringHashMapUnmanaged(void) = .empty,
    /// Const enums that remain as runtime objects after TS stripping.
    runtime_const_enums: std.StringHashMapUnmanaged(void) = .empty,

    /// JSX pragma for import elision (e.g., "React.createElement" or "h").
    jsx_pragma: ?[]const u8 = null,
    /// JSX fragment pragma for import elision (e.g., "React.Fragment" or "Fragment").
    jsx_pragma_frag: ?[]const u8 = null,

    /// Scope analysis result (populated when pipeline.needs_scope is true).
    scope: ?*scope_mod.ScopeResult = null,
    /// Shared structural indices computed once per pipeline run.
    session: ?*session_mod.TransformSession = null,
    /// Shared ordered replacement_source index built lazily during the run.
    replacement_index: replacement_index_mod.ReplacementIndex = .{},

    // ── Scope query helpers ──────────────────────────────────────────

    /// Get the scope containing a given AST node.
    pub fn getScopeForNode(self: *const TransformContext, node: NodeIndex) ?scope_mod.ScopeIndex {
        if (self.scope) |s| return scope_mod.getScopeForNode(s, node);
        return null;
    }

    /// Resolve the binding associated with an identifier/binding node.
    pub fn getBindingForNode(self: *const TransformContext, node: NodeIndex) ?*const scope_mod.Binding {
        if (self.scope) |s| return scope_mod.getBindingForNode(s, node);
        return null;
    }

    pub fn getBindingIndexForNode(self: *const TransformContext, node: NodeIndex) ?u32 {
        if (self.scope) |s| return scope_mod.getBindingIndexForNode(s, node);
        return null;
    }

    /// Generate a unique name not conflicting with any binding in the scope chain.
    pub fn generateUniqueName(self: *const TransformContext, node: NodeIndex, prefix: []const u8) !?[]const u8 {
        const s = self.scope orelse return null;
        const scope_idx = scope_mod.getScopeForNode(s, node) orelse return null;
        const name = try scope_mod.generateUniqueName(s, scope_idx, prefix, self.allocator);
        return name;
    }

    // ── Mutation delegates ────────────────────────────────────────────

    pub fn replaceNode(self: *TransformContext, target: NodeIndex, replacement: NodeIndex) void {
        ast_ops.replaceNode(self.ast, target, replacement);
    }

    pub fn removeNode(self: *TransformContext, target: NodeIndex) void {
        ast_ops.removeNode(self.ast, target);
    }

    pub fn addNewNode(self: *TransformContext, node: Node) !NodeIndex {
        return ast_ops.addNewNode(self.ast, self.allocator, node);
    }

    pub fn addExtra(self: *TransformContext, value: u32) !u32 {
        return ast_ops.addExtra(self.ast, self.allocator, value);
    }

    pub fn addExtraSlice(self: *TransformContext, values: []const u32) !u32 {
        return ast_ops.addExtraSlice(self.ast, self.allocator, values);
    }

    pub fn putReplacementSource(self: *TransformContext, target: NodeIndex, replacement: []const u8) !void {
        try self.ast.replacement_source.put(self.allocator, @intFromEnum(target), replacement);
        self.replacement_index.invalidate();
    }

    pub fn removeReplacementSource(self: *TransformContext, target: NodeIndex) bool {
        const removed = self.ast.replacement_source.remove(@intFromEnum(target));
        if (removed) self.replacement_index.invalidate();
        return removed;
    }

    pub fn markReplacementNeedsReindent(self: *TransformContext, target: NodeIndex) !void {
        try self.ast.replacement_needs_reindent.put(self.allocator, @intFromEnum(target), {});
        self.replacement_index.invalidate();
    }

    pub fn orderedReplacements(self: *TransformContext) ![]const replacement_index_mod.ReplacementIndex.Entry {
        return self.replacement_index.ordered(self.allocator, self.ast);
    }

    pub fn replacementLowerBound(self: *TransformContext, target_start: u32) !usize {
        return self.replacement_index.lowerBound(self.allocator, self.ast, target_start);
    }

    pub fn deinit(self: *TransformContext) void {
        self.replacement_index.deinit(self.allocator);
    }

    // ── Query helpers ────────────────────────────────────────────────

    pub fn nodeTag(self: *const TransformContext, idx: NodeIndex) Node.Tag {
        return self.ast.nodes.items(.tag)[@intFromEnum(idx)];
    }

    pub fn nodeData(self: *const TransformContext, idx: NodeIndex) Node.Data {
        return self.ast.nodes.items(.data)[@intFromEnum(idx)];
    }

    pub fn mainToken(self: *const TransformContext, idx: NodeIndex) TokenIndex {
        return self.ast.nodes.items(.main_token)[@intFromEnum(idx)];
    }

    pub fn tokenSlice(self: *const TransformContext, token_index: TokenIndex) []const u8 {
        return self.ast.tokenSlice(token_index);
    }

    pub fn extraData(self: *const TransformContext, idx: u32) u32 {
        return self.ast.extra_data.items[idx];
    }
};

// ── Pass ─────────────────────────────────────────────────────────────

pub const Pass = struct {
    name: []const u8,
    node_filter: visitor.NodeTagBitSet,
    enter: ?*const fn (NodeIndex, *TransformContext) visitor.VisitResult = null,
    exit: ?*const fn (NodeIndex, *TransformContext) visitor.VisitResult = null,
    priority: u8 = 128,
};

pub const PassRunStat = struct {
    name: []const u8,
    total_ns: u64,
    enter_calls: u64,
    exit_calls: u64,
};

pub const PipelineRunStats = struct {
    scope_analysis_ns: ?u64 = null,
    transform_session_ns: ?u64 = null,
    dispatch_table_build_ns: ?u64 = null,
    traversal_ns: ?u64 = null,
    nodes_visited: u64 = 0,
    passes: []PassRunStat = &.{},

    pub fn deinit(self: *PipelineRunStats, allocator: Allocator) void {
        for (self.passes) |pass| allocator.free(pass.name);
        allocator.free(self.passes);
        self.* = .{};
    }
};

// ── Pipeline ─────────────────────────────────────────────────────────

pub const Pipeline = struct {
    passes: std.ArrayListUnmanaged(Pass),
    allocator: Allocator,

    /// JSX pragma for import elision (set by the test runner / CLI).
    jsx_pragma: ?[]const u8 = null,
    /// JSX fragment pragma for import elision.
    jsx_pragma_frag: ?[]const u8 = null,
    /// When true, run scope analysis before transform passes.
    needs_scope: bool = false,
    /// When true, build a shared TransformSession even if scope analysis is disabled.
    requires_transform_session: bool = false,
    /// Additional globals declared by fixture-local helper plugins.
    scope_extra_globals: []const []const u8 = &.{},
    telemetry_session: ?*telemetry_mod.TelemetrySession = null,
    telemetry_parent_span: ?telemetry_mod.SpanHandle = null,
    collect_run_stats: bool = false,
    retain_transform_session: bool = false,
    last_run_stats: ?PipelineRunStats = null,
    last_transform_session: ?session_mod.TransformSession = null,

    const PassStats = struct {
        total_ns: u64 = 0,
        enter_calls: u64 = 0,
        exit_calls: u64 = 0,
    };

    const dispatch_tag_count = std.meta.fields(Node.Tag).len;

    const DispatchRange = struct {
        start: usize = 0,
        len: usize = 0,
    };

    const DispatchTable = struct {
        enter_ranges: [dispatch_tag_count]DispatchRange = [_]DispatchRange{.{}} ** dispatch_tag_count,
        exit_ranges: [dispatch_tag_count]DispatchRange = [_]DispatchRange{.{}} ** dispatch_tag_count,
        enter_indices: []usize = &.{},
        exit_indices: []usize = &.{},

        fn deinit(self: *DispatchTable, allocator: Allocator) void {
            if (self.enter_indices.len > 0) allocator.free(self.enter_indices);
            if (self.exit_indices.len > 0) allocator.free(self.exit_indices);
            self.* = .{};
        }

        fn enterForTag(self: *const DispatchTable, tag: Node.Tag) []const usize {
            const range = self.enter_ranges[@intFromEnum(tag)];
            return self.enter_indices[range.start .. range.start + range.len];
        }

        fn exitForTag(self: *const DispatchTable, tag: Node.Tag) []const usize {
            const range = self.exit_ranges[@intFromEnum(tag)];
            return self.exit_indices[range.start .. range.start + range.len];
        }
    };

    pub fn init(allocator: Allocator) Pipeline {
        return .{
            .passes = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.clearLastRunStats();
        self.clearLastTransformSession();
        self.passes.deinit(self.allocator);
    }

    pub fn clearLastRunStats(self: *Pipeline) void {
        if (self.last_run_stats) |*stats| stats.deinit(self.allocator);
        self.last_run_stats = null;
    }

    pub fn lastRunStats(self: *const Pipeline) ?*const PipelineRunStats {
        if (self.last_run_stats) |*stats| return stats;
        return null;
    }

    pub fn clearLastTransformSession(self: *Pipeline) void {
        if (self.last_transform_session) |*session| session.deinit(self.allocator);
        self.last_transform_session = null;
    }

    pub fn lastTransformSession(self: *const Pipeline) ?*const session_mod.TransformSession {
        if (self.last_transform_session) |*session| return session;
        return null;
    }

    pub fn addPass(self: *Pipeline, pass: Pass) !void {
        try self.passes.append(self.allocator, pass);
    }

    pub fn run(self: *Pipeline, ast: *Ast) !void {
        self.clearLastRunStats();
        self.clearLastTransformSession();
        if (self.passes.items.len == 0) return;
        const ast_nodes_before: u64 = @intCast(ast.nodes.len);

        const pipeline_fields = [_]telemetry_mod.Field{
            telemetry_mod.Field.unsigned("pass_count", self.passes.items.len),
            telemetry_mod.Field.unsigned("ast_nodes_before", ast_nodes_before),
            telemetry_mod.Field.boolean("needs_scope", self.needs_scope),
        };
        var pipeline_span = if (self.telemetry_session) |session|
            session.startSpan(self.pipelineParentSpan(), .fixture, "phase", "pipeline", &pipeline_fields)
        else
            null;

        try ast.ensureTypeSideTablesMaterialized();
        ast.ensureCommentsAttached();

        // Sort passes by priority (lower = earlier).
        std.mem.sort(Pass, self.passes.items, {}, struct {
            fn lessThan(_: void, a: Pass, b: Pass) bool {
                return a.priority < b.priority;
            }
        }.lessThan);

        const record_run_stats = self.collect_run_stats;
        const record_timings = record_run_stats or self.telemetry_session != null;
        const retain_transform_session = self.retain_transform_session;

        const pass_stats = if (record_timings)
            self.allocator.alloc(PassStats, self.passes.items.len) catch null
        else
            null;
        defer if (pass_stats) |stats| self.allocator.free(stats);
        if (pass_stats) |stats| @memset(stats, .{});

        // Run scope analysis if any pass needs it.
        var scope_result: ?scope_mod.ScopeResult = null;
        var scope_analysis_ns: ?u64 = null;
        if (self.needs_scope) {
            var scope_span = if (self.telemetry_session) |session|
                session.startSpan(spanPtr(&pipeline_span), .pass, "phase", "scope_analysis", &.{})
            else
                null;
            var scope_error = false;
            const scope_started_ns = if (record_timings) monotonicNowNs() else 0;
            scope_result = scope_mod.analyzeWithOptions(ast, self.allocator, .{
                .extra_globals = self.scope_extra_globals,
            }) catch blk: {
                scope_error = true;
                break :blk null;
            };
            if (self.telemetry_session) |session| {
                session.finishSpan(spanPtr(&scope_span), if (scope_error) .err else .ok, &.{});
            }
            if (record_timings) {
                scope_analysis_ns = monotonicNsDelta(scope_started_ns, monotonicNowNs());
            }
        }
        defer if (scope_result) |*sr| sr.deinit();

        var transform_session_ns: ?u64 = null;
        var transient_transform_session: ?session_mod.TransformSession = null;
        defer if (transient_transform_session) |*session| session.deinit(self.allocator);
        var ctx_session: ?*session_mod.TransformSession = null;
        if (self.needs_scope or self.requires_transform_session) {
            const session_started_ns = if (record_timings) monotonicNowNs() else 0;
            transient_transform_session = try session_mod.TransformSession.init(
                self.allocator,
                ast,
                if (scope_result) |*sr| sr else null,
            );
            if (record_timings) {
                transform_session_ns = monotonicNsDelta(session_started_ns, monotonicNowNs());
            }

            if (retain_transform_session) {
                self.last_transform_session = transient_transform_session;
                transient_transform_session = null;
                if (self.last_transform_session) |*session| {
                    ctx_session = session;
                }
            } else if (transient_transform_session) |*session| {
                ctx_session = session;
            }
        }

        const dispatch_table_started_ns = if (record_timings) monotonicNowNs() else 0;
        var dispatch_table = try self.buildDispatchTable();
        defer dispatch_table.deinit(self.allocator);
        const dispatch_table_build_ns = if (record_timings)
            monotonicNsDelta(dispatch_table_started_ns, monotonicNowNs())
        else
            null;

        var ctx = TransformContext{
            .ast = ast,
            .allocator = self.allocator,
            .jsx_pragma = self.jsx_pragma,
            .jsx_pragma_frag = self.jsx_pragma_frag,
            .scope = if (scope_result) |*sr| sr else null,
            .session = ctx_session,
        };
        defer ctx.deinit();

        // Start traversal from the root node (index 0).
        var nodes_visited: u64 = 0;
        const traversal_started_ns = if (record_timings) monotonicNowNs() else 0;
        self.visitNode(&ctx, &dispatch_table, @enumFromInt(0), pass_stats, &nodes_visited);
        const traversal_ns = if (record_timings)
            monotonicNsDelta(traversal_started_ns, monotonicNowNs())
        else
            null;

        // After all passes, compact statement ranges by removing .removed entries.
        compactStatementRanges(ast);

        // Add `export {};` module marker if needed.
        if (ctx.needs_module_marker) {
            addModuleMarker(ast, self.allocator, ctx.force_module_marker) catch {};
        }

        if (pass_stats) |stats| {
            for (self.passes.items, stats) |pass, stat| {
                const fields = [_]telemetry_mod.Field{
                    telemetry_mod.Field.unsigned("priority", pass.priority),
                    telemetry_mod.Field.unsigned("enter_calls", stat.enter_calls),
                    telemetry_mod.Field.unsigned("exit_calls", stat.exit_calls),
                };
                if (self.telemetry_session) |session| {
                    session.emitCompletedSpan(
                        spanPtr(&pipeline_span),
                        .pass,
                        "pass",
                        pass.name,
                        .ok,
                        stat.total_ns,
                        &fields,
                    );
                }
            }
        }

        if (self.telemetry_session) |session| {
            const final_fields = [_]telemetry_mod.Field{
                telemetry_mod.Field.unsigned("ast_nodes_after", @intCast(ast.nodes.len)),
                telemetry_mod.Field.boolean("needs_module_marker", ctx.needs_module_marker),
                telemetry_mod.Field.unsigned("nodes_visited", nodes_visited),
                telemetry_mod.Field.unsigned("transform_session_ns", transform_session_ns orelse 0),
                telemetry_mod.Field.unsigned("dispatch_table_build_ns", dispatch_table_build_ns orelse 0),
                telemetry_mod.Field.unsigned("traversal_ns", traversal_ns orelse 0),
            };
            session.finishSpan(spanPtr(&pipeline_span), .ok, &final_fields);
        }

        if (record_run_stats) {
            var owned_pass_stats: []PassRunStat = &.{};
            if (pass_stats) |stats| {
                owned_pass_stats = try self.allocator.alloc(PassRunStat, self.passes.items.len);
                errdefer self.allocator.free(owned_pass_stats);
                for (self.passes.items, stats, 0..) |pass, stat, i| {
                    owned_pass_stats[i] = .{
                        .name = try self.allocator.dupe(u8, pass.name),
                        .total_ns = stat.total_ns,
                        .enter_calls = stat.enter_calls,
                        .exit_calls = stat.exit_calls,
                    };
                }
            }
            self.last_run_stats = .{
                .scope_analysis_ns = scope_analysis_ns,
                .transform_session_ns = transform_session_ns,
                .dispatch_table_build_ns = dispatch_table_build_ns,
                .traversal_ns = traversal_ns,
                .nodes_visited = nodes_visited,
                .passes = owned_pass_stats,
            };
        }
    }

    /// Add an `export {};` node at the end of the program body as a module marker.
    fn addModuleMarker(ast: *Ast, allocator: Allocator, force: bool) !void {
        const tags = ast.nodes.items(.tag);
        if (tags.len == 0) return;
        if (tags[0] != .program) return;

        const program_data = ast.nodes.items(.data)[0];
        const program_extra = @intFromEnum(program_data.extra);
        const range_start = ast.extra_data.items[program_extra];
        const range_end = ast.extra_data.items[program_extra + 1];

        // Check if any remaining export exists in the program body.
        // Existing exports already preserve module status.
        for (ast.extra_data.items[range_start..range_end]) |entry| {
            if (entry >= tags.len) continue;
            const entry_tag = tags[entry];
            switch (entry_tag) {
                .export_named, .export_default, .export_all => return,
                else => {},
            }
        }

        // Regular imports preserve module status unless a transform explicitly
        // requested a forced marker after removing all exports.
        if (!force) {
            for (ast.extra_data.items[range_start..range_end]) |entry| {
                if (entry >= tags.len) continue;
                if (tags[entry] == .import_declaration) return;
            }
        }

        // Step 1: Create export_named extra data
        // Layout: [source=0, specs_start, specs_end, decl=none, attrs_start, attrs_end]
        const export_extra_start = try ast_ops.addExtra(ast, allocator, 0); // source_token_raw = 0
        _ = try ast_ops.addExtra(ast, allocator, 0); // specs_start = 0
        _ = try ast_ops.addExtra(ast, allocator, 0); // specs_end = 0 (empty)
        _ = try ast_ops.addExtra(ast, allocator, @intFromEnum(NodeIndex.none)); // no declaration
        _ = try ast_ops.addExtra(ast, allocator, 0); // attrs_start = 0
        _ = try ast_ops.addExtra(ast, allocator, 0); // attrs_end = 0 (empty)

        // Step 2: Create the export_named node
        const export_node = try ast_ops.addNewNode(ast, allocator, .{
            .tag = .export_named,
            .main_token = @enumFromInt(0),
            .data = .{ .extra = @enumFromInt(export_extra_start) },
        });

        // Step 3: Create a new program body range that includes the export node at the end
        // We copy the existing range entries and add the new one.
        // NOTE: We must read the range BEFORE ensuring capacity, since reallocation
        // would invalidate the slice.
        const old_start = ast.extra_data.items[program_extra];
        const old_end = ast.extra_data.items[program_extra + 1];
        const old_len = old_end - old_start;

        // Ensure capacity FIRST so no reallocation during append
        try ast.extra_data.ensureUnusedCapacity(allocator, old_len + 1);

        // NOW read the items (safe since no reallocation will occur)
        const new_start: u32 = @intCast(ast.extra_data.items.len);
        const cur_old_start = ast.extra_data.items[program_extra];
        var i: u32 = 0;
        while (i < old_len) : (i += 1) {
            ast.extra_data.appendAssumeCapacity(ast.extra_data.items[cur_old_start + i]);
        }
        ast.extra_data.appendAssumeCapacity(@intFromEnum(export_node));
        const new_end: u32 = @intCast(ast.extra_data.items.len);

        // Step 4: Update program's range pointers
        ast.extra_data.items[program_extra] = new_start;
        ast.extra_data.items[program_extra + 1] = new_end;
    }

    /// Compact statement ranges by removing entries for .removed nodes.
    fn compactStatementRanges(ast: *Ast) void {
        const tags = ast.nodes.items(.tag);

        // Compact all statement container ranges except program.
        // Program body keeps .removed entries so the codegen can emit
        // preserved comments (JSDoc, inline annotations) from removed
        // type-only statements.
        for (tags, 0..) |tag, i| {
            const is_statement_container = switch (tag) {
                .block_statement, .class_body, .ts_module_block, .ts_interface_body => true,
                else => false,
            };
            if (!is_statement_container) continue;

            const data = ast.nodes.items(.data)[i];
            const extra_idx = @intFromEnum(data.extra);
            const range_start_slot = extra_idx;
            const range_end_slot = extra_idx + 1;
            const range_start = ast.extra_data.items[range_start_slot];
            const range_end = ast.extra_data.items[range_end_slot];
            if (range_start >= range_end) continue;

            // Compact in-place: shift non-removed entries to the front
            var write_pos = range_start;
            for (ast.extra_data.items[range_start..range_end]) |entry| {
                if (entry >= tags.len) continue;
                if (tags[entry] == .removed) continue;
                ast.extra_data.items[write_pos] = entry;
                write_pos += 1;
            }

            // Update the range end
            ast.extra_data.items[range_end_slot] = write_pos;
        }
    }

    fn visitNode(
        self: *const Pipeline,
        ctx: *TransformContext,
        dispatch_table: *const DispatchTable,
        idx: NodeIndex,
        pass_stats: ?[]PassStats,
        nodes_visited: *u64,
    ) void {
        // Skip sentinel and removed nodes.
        if (idx == .none) return;
        const i = @intFromEnum(idx);
        const tags = ctx.ast.nodes.items(.tag);
        if (i >= tags.len) return;
        if (tags[i] == .removed) return;
        nodes_visited.* += 1;

        const tag = tags[i];

        // ── Enter passes ─────────────────────────────────────────────
        for (dispatch_table.enterForTag(tag)) |pass_index| {
            const pass = self.passes.items[pass_index];
            const enter_fn = pass.enter orelse continue;
            const result = if (pass_stats) |stats| blk: {
                const started_ns = monotonicNowNs();
                const visit_result = enter_fn(idx, ctx);
                stats[pass_index].total_ns += monotonicNsDelta(started_ns, monotonicNowNs()) orelse 0;
                stats[pass_index].enter_calls += 1;
                break :blk visit_result;
            } else enter_fn(idx, ctx);
            switch (result) {
                .skip_children => return,
                .remove_node => {
                    ast_ops.removeNode(ctx.ast, idx);
                    return;
                },
                .continue_traversal => {},
            }
        }

        // ── Recurse into children ────────────────────────────────────
        if (!visitor.isLeafTag(tag)) {
            const children = visitor.getChildren(ctx.ast, idx);

            // Direct children.
            for (children.items[0..children.len]) |child| {
                self.visitNode(ctx, dispatch_table, child, pass_stats, nodes_visited);
            }

            // First range.
            if (children.range_end > children.range_start) {
                for (ctx.ast.extra_data.items[children.range_start..children.range_end]) |raw| {
                    const child: NodeIndex = @enumFromInt(raw);
                    self.visitNode(ctx, dispatch_table, child, pass_stats, nodes_visited);
                }
            }

            // Second range.
            if (children.range2_end > children.range2_start) {
                for (ctx.ast.extra_data.items[children.range2_start..children.range2_end]) |raw| {
                    const child: NodeIndex = @enumFromInt(raw);
                    self.visitNode(ctx, dispatch_table, child, pass_stats, nodes_visited);
                }
            }
        }

        // ── Exit passes ──────────────────────────────────────────────
        // Re-read tag in case enter passes modified it.
        const exit_tag = ctx.ast.nodes.items(.tag)[@intFromEnum(idx)];

        for (dispatch_table.exitForTag(exit_tag)) |pass_index| {
            const pass = self.passes.items[pass_index];
            const exit_fn = pass.exit orelse continue;
            const result = if (pass_stats) |stats| blk: {
                const started_ns = monotonicNowNs();
                const visit_result = exit_fn(idx, ctx);
                stats[pass_index].total_ns += monotonicNsDelta(started_ns, monotonicNowNs()) orelse 0;
                stats[pass_index].exit_calls += 1;
                break :blk visit_result;
            } else exit_fn(idx, ctx);
            switch (result) {
                .remove_node => {
                    ast_ops.removeNode(ctx.ast, idx);
                    return;
                },
                .skip_children, .continue_traversal => {},
            }
        }
    }

    fn buildDispatchTable(self: *const Pipeline) !DispatchTable {
        var table = DispatchTable{};
        errdefer table.deinit(self.allocator);

        var enter_counts = [_]usize{0} ** dispatch_tag_count;
        var exit_counts = [_]usize{0} ** dispatch_tag_count;

        for (self.passes.items) |pass| {
            for (0..dispatch_tag_count) |tag_index| {
                if (!pass.node_filter.isSet(tag_index)) continue;
                if (pass.enter != null) enter_counts[tag_index] += 1;
                if (pass.exit != null) exit_counts[tag_index] += 1;
            }
        }

        var total_enter: usize = 0;
        var total_exit: usize = 0;
        for (0..dispatch_tag_count) |tag_index| {
            table.enter_ranges[tag_index] = .{ .start = total_enter, .len = enter_counts[tag_index] };
            table.exit_ranges[tag_index] = .{ .start = total_exit, .len = exit_counts[tag_index] };
            total_enter += enter_counts[tag_index];
            total_exit += exit_counts[tag_index];
        }

        if (total_enter > 0) {
            table.enter_indices = try self.allocator.alloc(usize, total_enter);
        }
        if (total_exit > 0) {
            table.exit_indices = try self.allocator.alloc(usize, total_exit);
        }

        var enter_cursor = table.enter_ranges;
        var exit_cursor = table.exit_ranges;
        for (self.passes.items, 0..) |pass, pass_index| {
            for (0..dispatch_tag_count) |tag_index| {
                if (!pass.node_filter.isSet(tag_index)) continue;
                if (pass.enter != null) {
                    const cursor = &enter_cursor[tag_index];
                    table.enter_indices[cursor.start] = pass_index;
                    cursor.start += 1;
                }
                if (pass.exit != null) {
                    const cursor = &exit_cursor[tag_index];
                    table.exit_indices[cursor.start] = pass_index;
                    cursor.start += 1;
                }
            }
        }

        return table;
    }

    fn pipelineParentSpan(self: *const Pipeline) ?*const telemetry_mod.SpanHandle {
        if (self.telemetry_parent_span) |*span| return span;
        return null;
    }
};

fn monotonicNowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    if (rc != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn monotonicNsDelta(start_ns: u64, end_ns: u64) ?u64 {
    if (end_ns < start_ns) return null;
    return end_ns - start_ns;
}

fn spanPtr(span: *?telemetry_mod.SpanHandle) ?*const telemetry_mod.SpanHandle {
    if (span.*) |*value| return value;
    return null;
}
