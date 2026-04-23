# zig-babal

Zig implementation of a JavaScript/TypeScript parser, code generator, scope analyzer, and ES2015-era transform pipeline.

## Current Status

Source of truth for the current toolchain and workflow:

- Zig toolchain: `0.16.0` via [mise.toml](mise.toml)
- Primary local guidance: [AGENTS.md](AGENTS.md)

Initialize `mise` in the shell first, then use direct `zig ...` commands:

```bash
eval "$(mise activate zsh)"
```

Verified on `2026-04-18`:

- `zig build test` passes
- `zig build conformance-test` passes
- Parser conformance: `5891 pass / 0 fail / 0 skip / 0 error`
- Codegen conformance: `486 pass / 0 fail / 0 skip / 0 error`
- Transform conformance: `720 pass / 0 fail / 114 skip / 0 error`

## Common Commands

```bash
zig build test
zig build parse-test
zig build codegen-test
zig build transform-test
zig build conformance-test
```

## Notes

- The repository is already migrated to Zig `0.16.0`.
- Vendored Babel content under `vendor/babel` is fixture/reference data, not project source.
