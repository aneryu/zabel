const std = @import("std");
const zig_babal = @import("zig_babal");
const Parser = zig_babal.Parser;
const Node = zig_babal.Node;

fn expectParseSuccess(source: []const u8) !void {
    return expectParseSuccessWithOpts(source, .{});
}

fn expectParseSuccessWithOpts(source: []const u8, opts: zig_babal.ParseOptions) !void {
    var result = try Parser.parseWithOptions(std.testing.allocator, source, opts);
    defer result.deinit();
    if (result.errors.hasErrors()) {
        return error.ParseFailed;
    }
}

fn expectParseSuccessWithOptsVerbose(source: []const u8, opts: zig_babal.ParseOptions) !void {
    var result = try Parser.parseWithOptions(std.testing.allocator, source, opts);
    defer result.deinit();
    if (result.errors.hasErrors()) {
        var stderr_buf: [8192]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(std.testing.io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        try result.errors.format(&result.ast, stderr);
        try stderr.flush();
        return error.ParseFailed;
    }
}

fn expectFirstNodeTag(source: []const u8, expected: Node.Tag) !void {
    var result = try Parser.parse(std.testing.allocator, source);
    defer result.deinit();
    if (result.errors.hasErrors()) return error.ParseFailed;
    const tags = result.ast.nodes.items(.tag);
    var found = false;
    for (tags) |tag| {
        if (tag == expected) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// === Expression tests ===

test "numeric literal" {
    try expectParseSuccess("42;");
    try expectFirstNodeTag("42;", .numeric_literal);
}

test "string literal" {
    try expectParseSuccess("\"hello\";");
    try expectFirstNodeTag("\"hello\";", .string_literal);
}

test "binary expression" {
    try expectParseSuccess("1 + 2;");
    try expectFirstNodeTag("1 + 2;", .binary_expr);
}

test "nested binary expression" {
    try expectParseSuccess("1 + 2 * 3;");
}

test "unary expression" {
    try expectParseSuccess("!true;");
    try expectParseSuccess("-42;");
    try expectParseSuccess("typeof x;");
}

test "assignment expression" {
    try expectParseSuccess("x = 42;");
    try expectFirstNodeTag("x = 42;", .assignment_expr);
}

test "call expression" {
    try expectParseSuccess("foo();");
    try expectParseSuccess("foo(1, 2, 3);");
    try expectFirstNodeTag("foo();", .call_expr);
}

test "member expression" {
    try expectParseSuccess("a.b;");
    try expectParseSuccess("a.b.c;");
    try expectFirstNodeTag("a.b;", .member_expr);
}

test "computed member" {
    try expectParseSuccess("a[0];");
    try expectFirstNodeTag("a[0];", .computed_member_expr);
}

test "conditional expression" {
    try expectParseSuccess("a ? b : c;");
    try expectFirstNodeTag("a ? b : c;", .conditional_expr);
}

test "arrow function" {
    try expectParseSuccess("() => 42;");
    try expectParseSuccess("(a, b) => a + b;");
    try expectParseSuccess("x => x;");
}

test "parenthesized expression" {
    try expectParseSuccess("(1 + 2);");
}

test "array literal" {
    try expectParseSuccess("[1, 2, 3];");
}

test "object literal" {
    try expectParseSuccess("({a: 1, b: 2});");
}

test "new expression" {
    try expectParseSuccess("new Foo();");
    try expectParseSuccess("new Foo(1, 2);");
}

test "template literal" {
    try expectParseSuccess("`hello`;");
}

test "sequence expression" {
    try expectParseSuccess("(1, 2, 3);");
}

test "update expression" {
    try expectParseSuccess("i++;");
    try expectParseSuccess("++i;");
}

test "logical expressions" {
    try expectParseSuccess("a && b;");
    try expectParseSuccess("a || b;");
    try expectParseSuccess("a ?? b;");
}

test "spread element" {
    try expectParseSuccess("[...a];");
    try expectParseSuccess("foo(...args);");
}

// === Statement tests ===

test "variable declarations" {
    try expectParseSuccess("var x = 1;");
    try expectParseSuccess("let x = 1, y = 2;");
    try expectParseSuccess("const { a, b } = obj;");
    try expectParseSuccess("const [a, b] = arr;");
}

test "if statement" {
    try expectParseSuccess("if (true) {}");
    try expectParseSuccess("if (x) { y; } else { z; }");
    try expectParseSuccess("if (a) {} else if (b) {} else {}");
}

test "for statement" {
    try expectParseSuccess("for (var i = 0; i < 10; i++) {}");
    try expectParseSuccess("for (;;) {}");
}

test "for-in statement" {
    try expectParseSuccess("for (var k in obj) {}");
}

test "for-of statement" {
    try expectParseSuccess("for (const x of arr) {}");
}

test "while statement" {
    try expectParseSuccess("while (true) {}");
}

test "do-while statement" {
    try expectParseSuccess("do { x; } while (y);");
}

test "switch statement" {
    try expectParseSuccess("switch (x) { case 1: break; default: break; }");
}

test "try-catch-finally" {
    try expectParseSuccess("try { x; } catch (e) { y; }");
    try expectParseSuccess("try { x; } finally { y; }");
    try expectParseSuccess("try { x; } catch (e) { y; } finally { z; }");
}

test "return statement" {
    try expectParseSuccess("function f() { return; }");
    try expectParseSuccess("function f() { return 42; }");
}

test "throw statement" {
    try expectParseSuccess("throw new Error();");
}

test "break and continue" {
    try expectParseSuccess("while (true) { break; }");
    try expectParseSuccess("while (true) { continue; }");
    try expectParseSuccess("outer: while (true) { break outer; }");
}

test "labeled statement" {
    try expectParseSuccess("label: for (;;) {}");
}

test "block statement" {
    try expectParseSuccess("{ var x = 1; }");
}

test "empty statement" {
    try expectParseSuccess(";");
}

test "debugger statement" {
    try expectParseSuccess("debugger;");
}

test "with statement" {
    try expectParseSuccess("with (obj) { x; }");
}

test "escaped contextual keywords stay identifiers" {
    try expectParseSuccessWithOpts("int\\u0065rface = 1;", .{ .language = .typescript });
    try expectParseSuccessWithOpts("opa\\u0071ue = 1;", .{ .language = .flow });
}

test "newline after using avoids using declaration parsing" {
    try expectParseSuccess("using\nfoo = 1;");
}

// === Function/Class/Module tests ===

test "function declaration" {
    try expectParseSuccess("function foo(a, b) { return a + b; }");
}

test "async function" {
    try expectParseSuccess("async function foo() { await bar(); }");
}

test "generator function" {
    try expectParseSuccess("function* gen() { yield 1; yield 2; }");
}

test "function expression" {
    try expectParseSuccess("const f = function(x) { return x; };");
}

test "class declaration" {
    try expectParseSuccess("class Foo { constructor() {} method() {} }");
}

test "class with extends" {
    try expectParseSuccess("class Bar extends Foo { constructor() { super(); } }");
}

test "class fields and static" {
    try expectParseSuccess("class Foo { x = 1; static y = 2; #priv = 3; }");
}

test "class static block" {
    try expectParseSuccess("class Foo { static { console.log('init'); } }");
}

test "import declaration" {
    try expectParseSuccess("import foo from 'bar';");
    try expectParseSuccess("import { a, b as c } from 'bar';");
    try expectParseSuccess("import * as ns from 'bar';");
    try expectParseSuccess("import 'side-effect';");
}

test "export declaration" {
    const module_opts = zig_babal.ParseOptions{ .source_type = .module };
    try expectParseSuccessWithOpts("export const x = 1;", module_opts);
    try expectParseSuccessWithOpts("export function foo() {}", module_opts);
    try expectParseSuccessWithOpts("export { a, b as c };", module_opts);
    try expectParseSuccessWithOpts("export default 42;", module_opts);
    try expectParseSuccessWithOpts("export default function() {}", module_opts);
    try expectParseSuccessWithOpts("export * from 'bar';", module_opts);
}

test "dynamic import" {
    try expectParseSuccess("import('module');");
}

test "destructuring params" {
    try expectParseSuccess("function f({ a, b }, [c, d]) {}");
}

test "default params" {
    try expectParseSuccess("function f(a = 1, b = 2) {}");
}

test "rest params" {
    try expectParseSuccess("function f(a, ...rest) {}");
}

test "getter and setter" {
    try expectParseSuccess("const obj = { get x() { return 1; }, set x(v) {} };");
}

test "computed property" {
    try expectParseSuccess("const obj = { [key]: value };");
}

test "method shorthand" {
    try expectParseSuccess("const obj = { foo() {} };");
}

// === Edge case tests ===

test "ASI - return without semicolon" {
    try expectParseSuccess("function f() { return\n42 }");
}

test "ASI - after closing brace" {
    try expectParseSuccess("if (true) {}\nvar x = 1");
}

test "ASI - postfix update before arrow statement" {
    try expectParseSuccessWithOptsVerbose(
        "var i;\nfor (let i = 0; i < 1; ) {\n  i++\n  () => i;\n}\n",
        .{ .source_type = .module },
    );
}

test "flow default params do not leak type-only bindings" {
    try expectParseSuccessWithOptsVerbose(
        "function a(b: (c) => void = {}) {\n  let c;\n}\n\nfunction d(e = <T>() => {}) {\n  let T;\n}\n",
        .{ .language = .flow, .source_type = .module },
    );
}

test "labeled statement identifier" {
    try expectParseSuccess("foo: while (true) { break foo; }");
}

test "error recovery - unexpected token" {
    var result = try Parser.parse(std.testing.allocator, "var x = ;");
    defer result.deinit();
    try std.testing.expect(result.errors.hasErrors());
}

test "error recovery makes progress on invalid statement starter" {
    var result = try Parser.parse(std.testing.allocator, "if (");
    defer result.deinit();
    try std.testing.expect(result.errors.hasErrors());
}

test "truncated object getter does not panic" {
    var result = try Parser.parse(std.testing.allocator, "({ get })");
    defer result.deinit();
    try std.testing.expect(result.ast.nodes.len > 0);
}

test "new without parens" {
    try expectParseSuccess("new Foo;");
}

test "optional chaining" {
    try expectParseSuccess("a?.b;");
    try expectParseSuccess("a?.[b];");
    try expectParseSuccess("a?.();");
}

test "nullish coalescing" {
    try expectParseSuccess("a ?? b;");
}

test "import.meta" {
    try expectParseSuccess("import.meta.url;");
}

test "empty program" {
    try expectParseSuccess("");
}
