const std = @import("std");
const zb = @import("zig_babal");

fn firstProgramChild(ast: *const zb.Ast) zb.NodeIndex {
    return nthProgramChild(ast, 0);
}

fn nthProgramChild(ast: *const zb.Ast, index: usize) zb.NodeIndex {
    const program_data = ast.nodes.items(.data)[0];
    const extra_idx = @intFromEnum(program_data.extra);
    const range_start = ast.extra_data.items[extra_idx];
    return @enumFromInt(ast.extra_data.items[range_start + index]);
}

fn functionParam(ast: *const zb.Ast, function_node: zb.NodeIndex) zb.NodeIndex {
    const data = ast.nodes.items(.data)[@intFromEnum(function_node)];
    const extra_idx = @intFromEnum(data.extra);
    const params_start = ast.extra_data.items[extra_idx + 1];
    return @enumFromInt(ast.extra_data.items[params_start]);
}

fn restElementArgument(ast: *const zb.Ast, rest_element: zb.NodeIndex) zb.NodeIndex {
    return ast.nodes.items(.data)[@intFromEnum(rest_element)].unary;
}

fn functionBody(ast: *const zb.Ast, function_node: zb.NodeIndex) zb.NodeIndex {
    const data = ast.nodes.items(.data)[@intFromEnum(function_node)];
    const extra_idx = @intFromEnum(data.extra);
    return @enumFromInt(ast.extra_data.items[extra_idx + 3]);
}

fn classBody(ast: *const zb.Ast, class_node: zb.NodeIndex) zb.NodeIndex {
    const data = ast.nodes.items(.data)[@intFromEnum(class_node)];
    const extra_idx = @intFromEnum(data.extra);
    return @enumFromInt(ast.extra_data.items[extra_idx + 2]);
}

fn firstClassBodyElement(ast: *const zb.Ast, body_node: zb.NodeIndex) zb.NodeIndex {
    const data = ast.nodes.items(.data)[@intFromEnum(body_node)];
    const extra_idx = @intFromEnum(data.extra);
    const range_start = ast.extra_data.items[extra_idx];
    return @enumFromInt(ast.extra_data.items[range_start]);
}

fn freeStructuralData(alloc: std.mem.Allocator, structural: anytype) void {
    if (structural.parent_map.len > 0) alloc.free(structural.parent_map);
    if (structural.function_boundary_for_node.len > 0) alloc.free(structural.function_boundary_for_node);
    if (structural.containing_function_node.len > 0) alloc.free(structural.containing_function_node);
    if (structural.identifier_occurrences.len > 0) alloc.free(structural.identifier_occurrences);
    if (structural.function_binding_name_nodes.len > 0) alloc.free(structural.function_binding_name_nodes);
    if (structural.preorder_start.len > 0) alloc.free(structural.preorder_start);
    if (structural.preorder_end.len > 0) alloc.free(structural.preorder_end);
    if (structural.this_occurrences.len > 0) alloc.free(structural.this_occurrences);
    if (structural.capture_boundary_for_node.len > 0) alloc.free(structural.capture_boundary_for_node);
}

fn firstBlockStatement(ast: *const zb.Ast, block_node: zb.NodeIndex) zb.NodeIndex {
    const data = ast.nodes.items(.data)[@intFromEnum(block_node)];
    const extra_idx = @intFromEnum(data.extra);
    const range_start = ast.extra_data.items[extra_idx];
    return @enumFromInt(ast.extra_data.items[range_start]);
}

fn returnExpression(ast: *const zb.Ast, return_node: zb.NodeIndex) zb.NodeIndex {
    return ast.nodes.items(.data)[@intFromEnum(return_node)].unary;
}

fn declaratorNodes(ast: *const zb.Ast, declaration_node: zb.NodeIndex) struct { lhs: zb.NodeIndex, rhs: zb.NodeIndex } {
    const data = ast.nodes.items(.data)[@intFromEnum(declaration_node)];
    const extra_idx = @intFromEnum(data.extra);
    const decl_start = ast.extra_data.items[extra_idx];
    const declarator = @as(zb.NodeIndex, @enumFromInt(ast.extra_data.items[decl_start]));
    const decl_data = ast.nodes.items(.data)[@intFromEnum(declarator)];
    return .{
        .lhs = decl_data.binary.lhs,
        .rhs = decl_data.binary.rhs,
    };
}

fn expressionStatementExpression(ast: *const zb.Ast, statement_node: zb.NodeIndex) zb.NodeIndex {
    return ast.nodes.items(.data)[@intFromEnum(statement_node)].unary;
}

test "transform session computes parent and subtree ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\function outer(a = 1) {
        \\  const inner = () => a + 1;
        \\  return inner();
        \\}
    ,
        .{
            .source_type = .script,
            .language = .typescript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    var session = try zb.TransformSession.init(alloc, &parsed.ast, null);
    defer session.deinit(alloc);

    const program = @as(zb.NodeIndex, @enumFromInt(0));
    const outer_fn = firstProgramChild(&parsed.ast);
    const param = functionParam(&parsed.ast, outer_fn);
    const body = functionBody(&parsed.ast, outer_fn);

    try std.testing.expectEqual(zb.Node.Tag.program, parsed.ast.nodes.items(.tag)[@intFromEnum(program)]);
    try std.testing.expectEqual(zb.Node.Tag.function_declaration, parsed.ast.nodes.items(.tag)[@intFromEnum(outer_fn)]);
    try std.testing.expectEqual(outer_fn, session.parentOf(param).?);
    try std.testing.expectEqual(outer_fn, session.parentOf(body).?);
    try std.testing.expectEqual(program, session.parentOf(outer_fn).?);

    const program_range = session.subtreeRange(program);
    const outer_range = session.subtreeRange(outer_fn);
    const param_range = session.subtreeRange(param);
    const body_range = session.subtreeRange(body);

    try std.testing.expect(program_range.start < program_range.end);
    try std.testing.expect(outer_range.start < outer_range.end);
    try std.testing.expect(program_range.start <= outer_range.start);
    try std.testing.expect(outer_range.end <= program_range.end);
    try std.testing.expect(outer_range.start <= param_range.start);
    try std.testing.expect(param_range.end <= outer_range.end);
    try std.testing.expect(outer_range.start <= body_range.start);
    try std.testing.expect(body_range.end <= outer_range.end);
}

test "transform session indexes identifier occurrences by spelling and function boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\function outer(value) {
        \\  return () => value + value;
        \\}
    ,
        .{
            .source_type = .script,
            .language = .typescript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    var session = try zb.TransformSession.init(alloc, &parsed.ast, null);
    defer session.deinit(alloc);

    const outer_fn = firstProgramChild(&parsed.ast);
    const outer_body = functionBody(&parsed.ast, outer_fn);
    const return_stmt = firstBlockStatement(&parsed.ast, outer_body);
    const arrow_fn = returnExpression(&parsed.ast, return_stmt);

    const occurrences = session.identifierOccurrences("value") orelse return error.ExpectedOccurrences;
    try std.testing.expectEqual(@as(usize, 3), occurrences.len);
    try std.testing.expect(occurrences[0].start < occurrences[1].start);
    try std.testing.expect(occurrences[1].start < occurrences[2].start);

    var outer_count: usize = 0;
    var arrow_count: usize = 0;
    for (occurrences) |occurrence| {
        if (occurrence.function_boundary == null) continue;
        if (occurrence.function_boundary.? == outer_fn) outer_count += 1;
        if (occurrence.function_boundary.? == arrow_fn) arrow_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 1), outer_count);
    try std.testing.expectEqual(@as(usize, 2), arrow_count);
    try std.testing.expectEqual(outer_fn, session.functionBoundaryOf(outer_body).?);
}

test "transform session consumes structural identifier occurrences without scope analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\function outer(value) {
        \\  return () => value;
        \\}
    ,
        .{
            .source_type = .script,
            .language = .javascript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    const structural = try zb.TransformSession.buildStructuralData(std.testing.allocator, &parsed.ast);
    var session = try zb.TransformSession.initWithStructuralData(std.testing.allocator, &parsed.ast, null, structural);
    defer session.deinit(std.testing.allocator);

    const occurrences = session.identifierOccurrences("value") orelse return error.ExpectedOccurrences;
    try std.testing.expectEqual(@as(usize, 2), occurrences.len);
}

test "transform session indexes arrow binding name nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\const fnRef = value => value + fnRef(value);
        \\fact = n => n > 1 ? n * fact(n - 1) : 1;
    ,
        .{
            .source_type = .script,
            .language = .javascript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    var session = try zb.TransformSession.init(alloc, &parsed.ast, null);
    defer session.deinit(alloc);

    const declarator_stmt = firstProgramChild(&parsed.ast);
    const declarator = declaratorNodes(&parsed.ast, declarator_stmt);
    try std.testing.expectEqual(declarator.lhs, session.functionBindingNode(declarator.rhs).?);

    const assignment_stmt = nthProgramChild(&parsed.ast, 1);
    const assignment_expr = expressionStatementExpression(&parsed.ast, assignment_stmt);
    const assignment_data = parsed.ast.nodes.items(.data)[@intFromEnum(assignment_expr)];
    try std.testing.expectEqual(assignment_data.binary.lhs, session.functionBindingNode(assignment_data.binary.rhs).?);
}

test "transform session indexes bindings by name and owning function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\const value = 1;
        \\function outer(value) {
        \\  function inner() {
        \\    let value = 2;
        \\    return value;
        \\  }
        \\  return value;
        \\}
    ,
        .{
            .source_type = .script,
            .language = .javascript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    var scope_result = try zb.Scope.analyze(&parsed.ast, alloc);
    defer scope_result.deinit();

    var session = try zb.TransformSession.init(alloc, &parsed.ast, &scope_result);
    defer session.deinit(alloc);

    const outer_fn = nthProgramChild(&parsed.ast, 1);
    const outer_body = functionBody(&parsed.ast, outer_fn);
    const inner_fn = firstBlockStatement(&parsed.ast, outer_body);
    const program = @as(zb.NodeIndex, @enumFromInt(0));

    const all_bindings = session.bindingIndices("value") orelse return error.ExpectedBindings;
    try std.testing.expectEqual(@as(usize, 3), all_bindings.len);

    const global_scope = zb.Scope.getScopeForNode(&scope_result, program) orelse return error.ExpectedGlobalScope;
    const outer_scope = zb.Scope.getScopeForNode(&scope_result, outer_fn) orelse return error.ExpectedOuterScope;
    const inner_scope = zb.Scope.getScopeForNode(&scope_result, inner_fn) orelse return error.ExpectedInnerScope;

    try std.testing.expectEqual(@as(usize, 1), session.functionBindingIndices(global_scope, "value").?.len);
    try std.testing.expectEqual(@as(usize, 1), session.functionBindingIndices(outer_scope, "value").?.len);
    try std.testing.expectEqual(@as(usize, 1), session.functionBindingIndices(inner_scope, "value").?.len);
}

test "transform session indexes binding occurrences with function boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\function outer(...rest) {
        \\  rest;
        \\  return () => rest;
        \\}
    ,
        .{
            .source_type = .script,
            .language = .javascript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    var scope_result = try zb.Scope.analyze(&parsed.ast, alloc);
    defer scope_result.deinit();

    var session = try zb.TransformSession.init(alloc, &parsed.ast, &scope_result);
    defer session.deinit(alloc);

    const outer_fn = firstProgramChild(&parsed.ast);
    const rest_param = functionParam(&parsed.ast, outer_fn);
    const rest_ident = restElementArgument(&parsed.ast, rest_param);
    const outer_body = functionBody(&parsed.ast, outer_fn);
    const expr_stmt = firstBlockStatement(&parsed.ast, outer_body);
    const direct_ref = expressionStatementExpression(&parsed.ast, expr_stmt);

    const rest_binding_idx = zb.Scope.getBindingIndexForNode(&scope_result, rest_ident) orelse return error.ExpectedRestBinding;
    const occurrences = session.bindingOccurrences(rest_binding_idx);
    try std.testing.expectEqual(@as(usize, 3), occurrences.len);
    try std.testing.expectEqual(rest_ident, occurrences[0].node);
    try std.testing.expectEqual(direct_ref, occurrences[1].node);
    try std.testing.expectEqual(outer_fn, occurrences[1].function_boundary.?);
    try std.testing.expectEqual(zb.Node.Tag.arrow_function_expr, parsed.ast.nodes.items(.tag)[@intFromEnum(occurrences[2].function_boundary.?)]);
}

test "transform session exposes resolved binding indices for identifier nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\const value = 1;
        \\function outer(value) {
        \\  return () => value + (() => {
        \\    const value = 2;
        \\    return value;
        \\  })();
        \\}
    ,
        .{
            .source_type = .script,
            .language = .javascript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    var scope_result = try zb.Scope.analyze(&parsed.ast, alloc);
    defer scope_result.deinit();

    var session = try zb.TransformSession.init(alloc, &parsed.ast, &scope_result);
    defer session.deinit(alloc);

    const all_bindings = session.bindingIndices("value") orelse return error.ExpectedBindings;
    try std.testing.expectEqual(@as(usize, 3), all_bindings.len);

    const global_binding = all_bindings[0];
    const outer_binding = all_bindings[1];
    const inner_binding = all_bindings[2];

    // Verify per-binding occurrence counts: global=1, outer=2, inner=2 (total 5).
    const global_occs = session.bindingOccurrences(global_binding);
    const outer_occs = session.bindingOccurrences(outer_binding);
    const inner_occs = session.bindingOccurrences(inner_binding);
    try std.testing.expectEqual(@as(usize, 1), global_occs.len);
    try std.testing.expectEqual(@as(usize, 2), outer_occs.len);
    try std.testing.expectEqual(@as(usize, 2), inner_occs.len);

    // Verify resolved binding indices via each occurrence's node.
    try std.testing.expectEqual(global_binding, session.resolvedBindingIndexFor(global_occs[0].node).?);
    try std.testing.expectEqual(outer_binding, session.resolvedBindingIndexFor(outer_occs[0].node).?);
    try std.testing.expectEqual(outer_binding, session.resolvedBindingIndexFor(outer_occs[1].node).?);
    try std.testing.expectEqual(inner_binding, session.resolvedBindingIndexFor(inner_occs[0].node).?);
    try std.testing.expectEqual(inner_binding, session.resolvedBindingIndexFor(inner_occs[1].node).?);
}

test "transform session indexes this expressions in source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\function outer() {
        \\  return () => this.value + (() => this.other)();
        \\}
    ,
        .{
            .source_type = .script,
            .language = .javascript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    var session = try zb.TransformSession.init(alloc, &parsed.ast, null);
    defer session.deinit(alloc);

    const this_nodes = session.thisOccurrences();
    try std.testing.expectEqual(@as(usize, 2), this_nodes.len);
    try std.testing.expect(parsed.ast.nodes.items(.tag)[@intFromEnum(this_nodes[0])] == .this_expr);
    try std.testing.expect(parsed.ast.nodes.items(.tag)[@intFromEnum(this_nodes[1])] == .this_expr);

    const first_range = session.subtreeRange(this_nodes[0]);
    const second_range = session.subtreeRange(this_nodes[1]);
    try std.testing.expect(first_range.start < second_range.start);
}

test "structural data keeps class capture boundaries separate from function boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = try zb.parseWithOptions(
        alloc,
        \\class Box {
        \\  method() {
        \\    return this.value;
        \\  }
        \\}
    ,
        .{
            .source_type = .script,
            .language = .javascript,
            .defer_comment_attachment = true,
        },
    );
    defer parsed.deinit();

    const structural = try zb.TransformSession.buildStructuralData(std.testing.allocator, &parsed.ast);
    defer freeStructuralData(std.testing.allocator, structural);

    const class_decl = firstProgramChild(&parsed.ast);
    const class_body = classBody(&parsed.ast, class_decl);
    const method_node = firstClassBodyElement(&parsed.ast, class_body);
    const method_body = functionBody(&parsed.ast, method_node);

    try std.testing.expectEqual(zb.Node.Tag.class_declaration, parsed.ast.nodes.items(.tag)[@intFromEnum(class_decl)]);
    try std.testing.expectEqual(zb.Node.Tag.class_body, parsed.ast.nodes.items(.tag)[@intFromEnum(class_body)]);
    try std.testing.expectEqual(class_decl, structural.capture_boundary_for_node[@intFromEnum(class_body)]);
    try std.testing.expectEqual(zb.NodeIndex.none, structural.function_boundary_for_node[@intFromEnum(class_body)]);
    try std.testing.expectEqual(method_node, structural.capture_boundary_for_node[@intFromEnum(method_body)]);
    try std.testing.expectEqual(method_node, structural.function_boundary_for_node[@intFromEnum(method_body)]);
}
