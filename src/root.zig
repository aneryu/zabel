//! zig-babal: A high-performance JavaScript parser.
//!
//! Usage:
//!   const babal = @import("zig_babal");
//!   var result = try babal.parse(allocator, source);
//!   defer result.deinit();

pub const Ast = @import("ast.zig").Ast;
pub const Node = @import("ast.zig").Node;
pub const NodeIndex = @import("ast.zig").NodeIndex;
pub const ExtraIndex = @import("ast.zig").ExtraIndex;
pub const Token = @import("token.zig").Token;
pub const TokenIndex = @import("token.zig").TokenIndex;
pub const Lexer = @import("lexer.zig").Lexer;
pub const Parser = @import("parser.zig").Parser;
pub const ParseResult = @import("parser.zig").ParseResult;
pub const ParseOptions = @import("parser.zig").ParseOptions;
pub const SourceType = @import("ast.zig").SourceType;
pub const Language = @import("ast.zig").Language;
pub const AstJson = @import("ast_json.zig");
pub const JsonCompare = @import("json_compare.zig");
pub const Diagnostic = @import("diagnostics.zig").Diagnostic;
pub const DiagnosticList = @import("diagnostics.zig").DiagnosticList;
pub const SourceMap = @import("source_map.zig");
pub const Codegen = @import("codegen.zig").Codegen;
pub const RealProjectBench = @import("bench/real_project_bench.zig");
pub const Telemetry = @import("telemetry.zig");
pub const TelemetryArgs = @import("telemetry_args.zig").TelemetryArgs;
pub const Visitor = @import("transform/visitor.zig");
pub const Pipeline = @import("transform/pipeline.zig").Pipeline;
pub const TransformContext = @import("transform/pipeline.zig").TransformContext;
pub const TransformSession = @import("transform/session.zig").TransformSession;
pub const RewritePlan = @import("transform/rewrite_plan.zig").RewritePlan;
pub const ReplacementIndex = @import("transform/replacement_index.zig").ReplacementIndex;
pub const TransformConfig = @import("transform/config.zig").TransformConfig;
pub const TransformKind = @import("transform/config.zig").TransformKind;
pub const Target = @import("transform/config.zig").Target;
pub const AstOps = @import("transform/ast_ops.zig");
pub const FlowStrip = @import("transform/flow_strip.zig");
pub const TsStrip = @import("transform/ts_strip.zig");
pub const ClassesTransform = @import("transform/classes_transform.zig");
pub const ClassPropertiesTransform = @import("transform/class_properties_transform.zig");
pub const PrivateMethodsTransform = @import("transform/private_methods_transform.zig");
pub const ModulesCommonJS = @import("transform/modules_commonjs.zig");
pub const ModulesAMD = @import("transform/modules_amd.zig");
pub const JsxTransform = @import("transform/jsx_transform.zig");
pub const ReactConstantElements = @import("transform/react_constant_elements.zig");
pub const ShorthandProperties = @import("transform/shorthand_properties.zig");
pub const TemplateLiterals = @import("transform/template_literals.zig");
pub const ComputedProperties = @import("transform/computed_properties.zig");
pub const ArrowFunctions = @import("transform/arrow_functions.zig");
pub const AsyncToGenerator = @import("transform/async_to_generator.zig");
pub const Regenerator = @import("transform/regenerator.zig");
pub const Spread = @import("transform/spread.zig");
pub const Parameters = @import("transform/parameters.zig");
pub const ForOf = @import("transform/for_of.zig");
pub const NullishCoalescing = @import("transform/nullish_coalescing.zig");
pub const LogicalAssignment = @import("transform/logical_assignment.zig");
pub const OptionalChaining = @import("transform/optional_chaining.zig");
pub const BlockScoping = @import("transform/block_scoping.zig");
pub const BlockScopedFunctions = @import("transform/block_scoped_functions.zig");
pub const Destructuring = @import("transform/destructuring.zig");
pub const Scope = @import("scope.zig");

/// Parse JavaScript source code and return the AST.
pub fn parse(allocator: @import("std").mem.Allocator, source: []const u8) !ParseResult {
    return Parser.parse(allocator, source);
}

/// Parse JavaScript source code with options and return the AST.
pub fn parseWithOptions(allocator: @import("std").mem.Allocator, source: []const u8, opts: ParseOptions) !ParseResult {
    return Parser.parseWithOptions(allocator, source, opts);
}
