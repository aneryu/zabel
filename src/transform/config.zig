const std = @import("std");

pub const TransformKind = enum {
    arrow_functions,
    block_scoping,
    classes,
    optional_chaining,
    nullish_coalescing,
    class_fields,
    class_static_block,
    async_await,
    generators,
    shorthand_properties,
    template_literals,
    computed_properties,
    spread,
    parameters,
    for_of,
    logical_assignment,
    block_scoped_functions,
    destructuring,
};

pub const Target = enum {
    es2015,
    es2016,
    es2017,
    es2018,
    es2019,
    es2020,
    es2021,
    es2022,
    es2023,
    es2024,
    es2025,
    esnext,

    pub fn order(self: Target) u8 {
        return switch (self) {
            .es2015 => 0,
            .es2016 => 1,
            .es2017 => 2,
            .es2018 => 3,
            .es2019 => 4,
            .es2020 => 5,
            .es2021 => 6,
            .es2022 => 7,
            .es2023 => 8,
            .es2024 => 9,
            .es2025 => 10,
            .esnext => 11,
        };
    }

    pub fn parse(text: []const u8) ?Target {
        inline for (std.meta.fields(Target)) |field| {
            if (std.mem.eql(u8, text, field.name)) {
                return @field(Target, field.name);
            }
        }
        return null;
    }
};

pub const JsxRuntime = enum {
    classic,
    automatic,
};

pub const JsxConfig = struct {
    runtime: JsxRuntime = .automatic,
    pragma: []const u8 = "React.createElement",
    import_source: []const u8 = "react",
};

pub const TransformConfig = struct {
    target: Target = .esnext,
    ts_strip: bool = true,
    jsx: JsxConfig = .{},

    pub fn needsTransform(self: TransformConfig, transform: TransformKind) bool {
        return switch (transform) {
            .arrow_functions,
            .block_scoping,
            .classes,
            .shorthand_properties,
            .template_literals,
            .computed_properties,
            .spread,
            .parameters,
            .for_of,
            .block_scoped_functions,
            .destructuring,
            => self.target.order() <= Target.es2015.order(),

            .async_await => self.target.order() <= Target.es2016.order(),
            .generators => self.target.order() <= Target.es2015.order(),
            .optional_chaining,
            .nullish_coalescing,
            => self.target.order() <= Target.es2019.order(),
            .logical_assignment => self.target.order() <= Target.es2020.order(),
            .class_fields => self.target.order() <= Target.es2021.order(),
            .class_static_block => self.target.order() <= Target.es2022.order(),
        };
    }
};
