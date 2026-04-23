const std = @import("std");
const Codegen = @import("codegen.zig").Codegen;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const TokenIndex = @import("ast.zig").TokenIndex;

pub fn emitJsxNode(cg: *Codegen, tag: Node.Tag, idx: NodeIndex, main_token: TokenIndex, data: Node.Data) !void {
    switch (tag) {
        // === JSX Element ===
        // extra: [opening, closing, children_start, children_end]
        .jsx_element => {
            const extra_idx = @intFromEnum(data.extra);
            const opening: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const closing: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            const children_start = cg.ast.extra_data.items[extra_idx + 2];
            const children_end = cg.ast.extra_data.items[extra_idx + 3];

            try cg.emitNode(opening);
            cg.indent();
            const children = cg.ast.extra_data.items[children_start..children_end];
            for (children) |child| {
                try cg.emitNode(@enumFromInt(child));
            }
            cg.dedent();
            try cg.emitNode(closing);
        },

        // === JSX Opening Element ===
        // extra: [name, attr_start, attr_end]
        .jsx_opening_element => {
            try cg.writeChar('<');
            try emitJsxOpeningInternals(cg, idx, data, false);
            try cg.writeChar('>');
        },

        // === JSX Closing Element ===
        // data.unary = name
        .jsx_closing_element => {
            try cg.writeStr("</");
            try cg.emitNode(data.unary);
            try cg.writeChar('>');
        },

        // === JSX Self-Closing Element ===
        // In the AST, this is stored like an opening element but with selfClosing=true
        // extra: [name, attr_start, attr_end]
        .jsx_self_closing_element => {
            try cg.writeChar('<');
            try emitJsxOpeningInternals(cg, idx, data, true);
            try cg.writeStr(" />");
        },

        // === JSX Fragment ===
        // extra: [opening, closing, children_start, children_end]
        .jsx_fragment => {
            const extra_idx = @intFromEnum(data.extra);
            const opening: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
            const closing: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx + 1]);
            const children_start = cg.ast.extra_data.items[extra_idx + 2];
            const children_end = cg.ast.extra_data.items[extra_idx + 3];

            try cg.emitNode(opening);
            cg.indent();
            const children = cg.ast.extra_data.items[children_start..children_end];
            for (children) |child| {
                try cg.emitNode(@enumFromInt(child));
            }
            cg.dedent();
            try cg.emitNode(closing);
        },

        // === JSX Opening Fragment ===
        .jsx_opening_fragment => {
            try cg.writeStr("<>");
        },

        // === JSX Closing Fragment ===
        .jsx_closing_fragment => {
            try cg.writeStr("</>");
        },

        // === JSX Attribute ===
        // data.binary: lhs = name, rhs = value (or .none if boolean)
        .jsx_attribute => {
            try cg.emitNode(data.binary.lhs);
            if (data.binary.rhs != .none) {
                try cg.writeChar('=');
                try cg.emitNode(data.binary.rhs);
            }
        },

        // === JSX Spread Attribute ===
        // data.unary = argument
        .jsx_spread_attribute => {
            try cg.writeStr("{...");
            try cg.emitNode(data.unary);
            try cg.writeChar('}');
        },

        // === JSX Spread Child ===
        // data.unary = expression
        .jsx_spread_child => {
            try cg.writeStr("{...");
            try cg.emitNode(data.unary);
            try cg.writeChar('}');
        },

        // === JSX Expression Container ===
        // data.unary = expression
        .jsx_expression_container => {
            try cg.writeChar('{');
            // For empty expressions with trailing comments (e.g., {/*comment*/}),
            // suppress the default space before the trailing comment
            if (data.unary != .none) {
                const inner_tag = cg.ast.nodes.items(.tag)[@intFromEnum(data.unary)];
                if (inner_tag == .jsx_empty_expression) {
                    // Emit the empty expression (no output), then emit trailing
                    // comments directly without space
                    cg.emitExprLeadingComments(data.unary) catch {};
                    const key = @intFromEnum(data.unary);
                    if (cg.ast.trailing_comments.get(key)) |range| {
                        const comments = cg.ast.comments.items;
                        var ci = range.start;
                        while (ci < range.end and ci < comments.len) : (ci += 1) {
                            if (cg.emitted_comments.isSet(ci)) continue;
                            cg.emitted_comments.set(ci);
                            cg.emitCommentText(comments[ci]) catch {};
                        }
                    }
                } else {
                    try cg.emitNode(data.unary);
                }
            }
            try cg.writeChar('}');
        },

        // === JSX String Literal ===
        // main_token has the string with quotes
        .jsx_string_literal => {
            try cg.emitToken(main_token);
        },

        // === JSX Empty Expression ===
        .jsx_empty_expression => {
            // Empty — nothing to emit (comments handled by expression container)
        },

        // === JSX Text ===
        // extra: [text_start, text_end] — raw source text
        .jsx_text => {
            const i = @intFromEnum(idx);
            const node_data = cg.ast.nodes.items(.data)[i];
            const extra_idx = @intFromEnum(node_data.extra);
            const text_start = cg.ast.extra_data.items[extra_idx];
            const text_end = cg.ast.extra_data.items[extra_idx + 1];
            const raw = cg.ast.source[text_start..text_end];
            try cg.writeStr(raw);
        },

        // === JSX Identifier ===
        // main_token has the identifier (may be hyphenated, spans to node end)
        .jsx_identifier => {
            const start = cg.ast.tokens.items(.start)[@intFromEnum(main_token)];
            const end_off = cg.ast.nodes.items(.end_offset)[@intFromEnum(idx)];
            // Use end_offset if available; otherwise fall back to token end
            const end = if (end_off > 0)
                end_off
            else
                cg.ast.tokens.items(.end)[@intFromEnum(main_token)];
            const name = cg.ast.source[start..end];
            try cg.writeStr(name);
        },

        // === JSX Member Expression ===
        // data.binary: lhs = object, rhs = property
        .jsx_member_expression => {
            try cg.emitNode(data.binary.lhs);
            try cg.writeChar('.');
            try cg.emitNode(data.binary.rhs);
        },

        // === JSX Namespaced Name ===
        // data.binary: lhs = namespace, rhs = name
        .jsx_namespaced_name => {
            try cg.emitNode(data.binary.lhs);
            try cg.writeChar(':');
            try cg.emitNode(data.binary.rhs);
        },

        else => {},
    }
}

/// Emit the internals of a JSX opening element (name, type arguments, attributes)
fn emitJsxOpeningInternals(cg: *Codegen, idx: NodeIndex, data: Node.Data, self_closing: bool) !void {
    _ = self_closing;
    const extra_idx = @intFromEnum(data.extra);
    const name: NodeIndex = @enumFromInt(cg.ast.extra_data.items[extra_idx]);
    const attr_start = cg.ast.extra_data.items[extra_idx + 1];
    const attr_end = cg.ast.extra_data.items[extra_idx + 2];

    try cg.emitNode(name);

    // Emit typeArguments if present (for TSX: <Component<T> ...>)
    if (cg.ast.type_parameters.get(@intFromEnum(idx))) |tp| {
        try cg.emitNode(tp);
    }

    // Emit attributes with space separators
    const attrs = cg.ast.extra_data.items[attr_start..attr_end];
    for (attrs) |attr| {
        try cg.space();
        try cg.emitNode(@enumFromInt(attr));
    }
}
