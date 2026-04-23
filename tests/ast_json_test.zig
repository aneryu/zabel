const std = @import("std");
const zig_babal = @import("zig_babal");

fn serializeAstJson(allocator: std.mem.Allocator, ast: *const zig_babal.Ast) ![]u8 {
    var json_output: std.ArrayList(u8) = .empty;
    errdefer json_output.deinit(allocator);

    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_output);
    try zig_babal.AstJson.serialize(ast, &writer.writer);
    json_output = writer.toArrayList();
    return try json_output.toOwnedSlice(allocator);
}

fn expectJson(source: []const u8, expected_fragment: []const u8) !void {
    return expectJsonWithOpts(source, .{}, expected_fragment);
}

fn expectJsonWithOpts(source: []const u8, opts: zig_babal.ParseOptions, expected_fragment: []const u8) !void {
    var result = try zig_babal.parseWithOptions(std.testing.allocator, source, opts);
    defer result.deinit();

    const output = try serializeAstJson(std.testing.allocator, &result.ast);
    defer std.testing.allocator.free(output);

    if (std.mem.indexOf(u8, output, expected_fragment) == null) {
        std.debug.print("Expected fragment: {s}\nActual output: {s}\n", .{ expected_fragment, output });
        return error.FragmentNotFound;
    }
}

test "program node" {
    try expectJson(";", "\"type\":\"File\"");
    try expectJson(";", "\"type\":\"Program\"");
}

test "numeric literal" {
    try expectJson("42;", "\"type\":\"NumericLiteral\"");
}

test "numeric literal has position" {
    try expectJson("42;", "\"start\":");
    try expectJson("42;", "\"loc\":");
}

test "string literal" {
    // A standalone string at program start becomes a directive
    try expectJson("\"hello\";", "\"type\":\"DirectiveLiteral\"");
    // A string after a non-string statement stays a StringLiteral
    try expectJson("0; \"hello\";", "\"type\":\"StringLiteral\"");
}

test "variable declaration" {
    try expectJson("const x = 1;", "\"type\":\"VariableDeclaration\"");
    try expectJson("const x = 1;", "\"kind\":\"const\"");
}

test "binary expression" {
    try expectJson("1 + 2;", "\"type\":\"BinaryExpression\"");
    try expectJson("1 + 2;", "\"operator\":\"+\"");
}

test "function declaration" {
    try expectJson("function foo() {}", "\"type\":\"FunctionDeclaration\"");
}

test "if statement" {
    try expectJson("if (true) {}", "\"type\":\"IfStatement\"");
}

test "identifier" {
    try expectJson("x;", "\"type\":\"Identifier\"");
}

test "call expression" {
    try expectJson("foo();", "\"type\":\"CallExpression\"");
}

test "typescript call/new expressions use typeArguments" {
    const opts = zig_babal.ParseOptions{
        .language = .typescript,
        .source_type = .module,
    };
    try expectJsonWithOpts("makeBox<number>(a);", opts, "\"type\":\"CallExpression\"");
    try expectJsonWithOpts("makeBox<number>(a);", opts, "\"typeArguments\":{\"type\":\"TSTypeParameterInstantiation\"");
    try expectJsonWithOpts("new Foo<Bar>();", opts, "\"type\":\"NewExpression\"");
    try expectJsonWithOpts("new Foo<Bar>();", opts, "\"typeArguments\":{\"type\":\"TSTypeParameterInstantiation\"");
}

test "deferred import expression keeps phase metadata" {
    const opts = zig_babal.ParseOptions{
        .source_type = .module,
        .enable_deferred_import = true,
    };
    try expectJsonWithOpts("import.defer(\"foo\");", opts, "\"type\":\"ImportExpression\"");
    try expectJsonWithOpts("import.defer(\"foo\");", opts, "\"phase\":\"defer\"");
}

test "deferred import declaration keeps phase metadata" {
    const opts = zig_babal.ParseOptions{
        .source_type = .module,
        .enable_deferred_import = true,
    };
    try expectJsonWithOpts("import defer * as ns from \"x\";", opts, "\"type\":\"ImportDeclaration\"");
    try expectJsonWithOpts("import defer * as ns from \"x\";", opts, "\"phase\":\"defer\"");
}

test "typescript class heritage serializes babel-compatible fields" {
    const opts = zig_babal.ParseOptions{
        .language = .typescript,
        .source_type = .module,
    };
    const source = "abstract class C<T> extends Base<U> implements X.Y<Z> {}";
    try expectJsonWithOpts(source, opts, "\"type\":\"ClassDeclaration\"");
    try expectJsonWithOpts(source, opts, "\"abstract\":true");
    try expectJsonWithOpts(source, opts, "\"typeParameters\":{\"type\":\"TSTypeParameterDeclaration\"");
    try expectJsonWithOpts(source, opts, "\"superTypeArguments\":{\"type\":\"TSTypeParameterInstantiation\"");
    try expectJsonWithOpts(source, opts, "\"type\":\"TSClassImplements\"");
    try expectJsonWithOpts(source, opts, "\"typeArguments\":{\"type\":\"TSTypeParameterInstantiation\"");
}

test "typescript abstract and declare class start at modifier token" {
    const opts = zig_babal.ParseOptions{
        .language = .typescript,
        .source_type = .module,
    };
    try expectJsonWithOpts("abstract class C {}", opts, "\"body\":[{\"type\":\"ClassDeclaration\",\"start\":0");
    try expectJsonWithOpts("declare abstract class C {}", opts, "\"body\":[{\"type\":\"ClassDeclaration\",\"start\":0");
    try expectJsonWithOpts("declare abstract class C {}", opts, "\"declare\":true");
    try expectJsonWithOpts("declare abstract class C {}", opts, "\"abstract\":true");
}

test "deferred comment attachment materializes during serialization" {
    var result = try zig_babal.parseWithOptions(std.testing.allocator, "/*a*/ foo();", .{
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.ast.leading_comments.count());

    const output = try serializeAstJson(std.testing.allocator, &result.ast);
    defer std.testing.allocator.free(output);

    try std.testing.expect(result.ast.comments_attached);
    try std.testing.expect(result.ast.leading_comments.count() > 0);
}

test "typescript class signatures serialize as TSDeclareMethod" {
    const opts = zig_babal.ParseOptions{
        .language = .typescript,
        .source_type = .module,
    };
    const source = "class C { constructor(x: number); }";
    try expectJsonWithOpts(source, opts, "\"type\":\"TSDeclareMethod\"");
    try expectJsonWithOpts(source, opts, "\"kind\":\"constructor\"");
    try expectJsonWithOpts(source, opts, "\"computed\":false");
    try expectJsonWithOpts(source, opts, "\"params\":[{\"type\":\"Identifier\"");
}

test "flow call and class heritage use typeArguments" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    // @flow pragma is required for type arguments in call expressions
    try expectJsonWithOpts("// @flow\nf<T>(a);", opts, "\"typeArguments\":{\"type\":\"TypeParameterInstantiation\"");
    try expectJsonWithOpts("// @flow\nclass Foo<T> extends Bar<T> {}", opts, "\"superTypeArguments\":{\"type\":\"TypeParameterInstantiation\"");
}

test "flow typeof reserved escaped member serializes valid json" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    const source = "// @flow\nconst x: typeof d.i\\u{6e}terface = \"hi\";";

    var result = try zig_babal.parseWithOptions(std.testing.allocator, source, opts);
    defer result.deinit();
    try std.testing.expect(result.errors.hasErrors());

    const output = try serializeAstJson(std.testing.allocator, &result.ast);
    defer std.testing.allocator.free(output);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), output, .{});

    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"TypeofTypeAnnotation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"GenericTypeAnnotation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"QualifiedTypeIdentifier\"") != null);
}

test "flow typeof named identifiers use babel argument shape" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    try expectJsonWithOpts("var x: typeof Y = Y;", opts, "\"argument\":{\"type\":\"GenericTypeAnnotation\"");
    try expectJsonWithOpts("const x: typeof default = \"hi\";", opts, "\"argument\":{\"type\":\"Identifier\"");
}

test "flow literal and keyword types serialize babel-compatible fields" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    try expectJsonWithOpts("type T = -1;", opts, "\"type\":\"NumberLiteralTypeAnnotation\"");
    try expectJsonWithOpts("type T = -1;", opts, "\"extra\":{\"rawValue\":-1,\"raw\":\"-1\"}");
    try expectJsonWithOpts("type T = \"div\";", opts, "\"type\":\"StringLiteralTypeAnnotation\"");
    try expectJsonWithOpts("type T = \"div\";", opts, "\"extra\":{\"rawValue\":\"div\",\"raw\":\"\\\"div\\\"\"}");
    try expectJsonWithOpts("function foo(a:function) {}", opts, "\"typeAnnotation\":{\"type\":\"Identifier\"");
}

test "flow function types serialize this parameter separately" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    const source = "type T = (this : number, a : string) => void";
    try expectJsonWithOpts(source, opts, "\"this\":{\"type\":\"FunctionTypeParam\"");
    try expectJsonWithOpts(source, opts, "\"name\":null");
    try expectJsonWithOpts(source, opts, "\"params\":[{\"type\":\"FunctionTypeParam\"");
}

test "flow function type errors when this is not first" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    var result = try zig_babal.parseWithOptions(std.testing.allocator, "type T = (a : string, this : number) => void", opts);
    defer result.deinit();
    try std.testing.expect(result.errors.hasErrors());
}

test "flow runtime this parameter default preserves assignment pattern" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    var result = try zig_babal.parseWithOptions(std.testing.allocator, "function foo (this : number = 2) {}", opts);
    defer result.deinit();
    try std.testing.expect(result.errors.hasErrors());

    const output = try serializeAstJson(std.testing.allocator, &result.ast);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"type\":\"AssignmentPattern\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\":\"this\"") != null);
}

test "flow object accessor methods serialize accessor kind" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    const source =
        \\type T = {
        \\  get foo(this : string) : void,
        \\  set bar(this : string) : void,
        \\}
    ;
    var result = try zig_babal.parseWithOptions(std.testing.allocator, source, opts);
    defer result.deinit();
    try std.testing.expect(result.errors.hasErrors());

    const output = try serializeAstJson(std.testing.allocator, &result.ast);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"kind\":\"get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"kind\":\"set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"this\":{\"type\":\"FunctionTypeParam\"") != null);
}

test "flow class constructor this parameter reports error" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    var result = try zig_babal.parseWithOptions(std.testing.allocator, "class A { constructor(this: string) {} }", opts);
    defer result.deinit();
    try std.testing.expect(result.errors.hasErrors());

    const output = try serializeAstJson(std.testing.allocator, &result.ast);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"kind\":\"constructor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\":\"this\"") != null);
}

test "flow declare class serializes mixins and implements" {
    const opts = zig_babal.ParseOptions{
        .language = .flow,
        .source_type = .module,
    };
    const source = "declare class A mixins B implements C {}";
    try expectJsonWithOpts(source, opts, "\"implements\":[{\"type\":\"ClassImplements\"");
    try expectJsonWithOpts(source, opts, "\"mixins\":[{\"type\":\"InterfaceExtends\"");
}

test "typescript interface signatures use babel-compatible fields" {
    const opts = zig_babal.ParseOptions{
        .language = .typescript,
        .source_type = .module,
    };
    const source = "interface I { readonly x?: number; foo?(a: number): void; (x: number): void; }";
    try expectJsonWithOpts(source, opts, "\"type\":\"TSPropertySignature\"");
    try expectJsonWithOpts(source, opts, "\"readonly\":true");
    try expectJsonWithOpts(source, opts, "\"optional\":true");
    try expectJsonWithOpts(source, opts, "\"type\":\"TSMethodSignature\"");
    try expectJsonWithOpts(source, opts, "\"params\":[{\"type\":\"Identifier\"");
    try expectJsonWithOpts(source, opts, "\"kind\":\"method\"");
    try expectJsonWithOpts(source, opts, "\"type\":\"TSCallSignatureDeclaration\"");
    try expectJsonWithOpts(source, opts, "\"returnType\":{\"type\":\"TSTypeAnnotation\"");
}

test "typescript interface computed accessor serializes computed key" {
    const opts = zig_babal.ParseOptions{
        .language = .typescript,
        .source_type = .module,
    };
    const source = "interface I { get [Symbol.iterator](): void; }";
    try expectJsonWithOpts(source, opts, "\"computed\":true");
    try expectJsonWithOpts(source, opts, "\"kind\":\"get\"");
    try expectJsonWithOpts(source, opts, "\"type\":\"MemberExpression\"");
}

test "assignment expression" {
    try expectJson("x = 1;", "\"type\":\"AssignmentExpression\"");
    try expectJson("x = 1;", "\"operator\":\"=\"");
}

test "template literal no substitution" {
    try expectJson("`hello`;", "\"type\":\"TemplateLiteral\"");
    try expectJson("`hello`;", "\"quasis\":[{\"type\":\"TemplateElement\"");
    try expectJson("`hello`;", "\"tail\":true");
}

test "template literal with expressions" {
    try expectJson("`a${x}b`;", "\"type\":\"TemplateLiteral\"");
    try expectJson("`a${x}b`;", "\"expressions\":[{\"type\":\"Identifier\"");
    try expectJson("`a${x}b`;", "\"quasis\":[{\"type\":\"TemplateElement\"");
    try expectJson("`a${x}b`;", "\"tail\":false}");
    try expectJson("`a${x}b`;", "\"tail\":true}]");
}

test "template literal with multiple expressions" {
    try expectJson("`a${x}b${y}c`;", "\"type\":\"TemplateLiteral\"");
    // Two expressions
    try expectJson("`a${x}b${y}c`;", "\"expressions\":[{\"type\":\"Identifier\"");
    // Three quasis
    try expectJson("`a${x}b${y}c`;", "\"quasis\":[{\"type\":\"TemplateElement\"");
}

fn expectFlowJson(source: []const u8, expected_fragment: []const u8) !void {
    var result = try zig_babal.parseWithOptions(std.testing.allocator, source, .{ .language = .flow });
    defer result.deinit();

    const output = try serializeAstJson(std.testing.allocator, &result.ast);
    defer std.testing.allocator.free(output);
    if (std.mem.indexOf(u8, output, expected_fragment) == null) {
        std.debug.print("\nExpected fragment: {s}\nActual output: {s}\n", .{ expected_fragment, output });
        return error.FragmentNotFound;
    }
}

test "flow type annotation on function params" {
    try expectFlowJson("function foo(numVal: any){}", "\"typeAnnotation\":{\"type\":\"TypeAnnotation\"");
}

test "flow function return type" {
    try expectFlowJson("function foo():number{}", "\"returnType\":{\"type\":\"TypeAnnotation\"");
}

test "flow arrow with return type" {
    try expectFlowJson("var foo = (bar): number => bar;", "\"returnType\":{\"type\":\"TypeAnnotation\"");
    try expectFlowJson("var foo = (bar): number => bar;", "\"predicate\":null");
}

test "flow enum declaration" {
    try expectFlowJson(
        "enum E of boolean {\n  A = true,\n  B = false,\n}",
        "\"type\":\"EnumDeclaration\"",
    );
    try expectFlowJson(
        "enum E of boolean {\n  A = true,\n  B = false,\n}",
        "\"type\":\"EnumBooleanBody\"",
    );
}
