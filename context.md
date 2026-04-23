# Context

## Purpose

- `zig-babal` is a Zig implementation of a JavaScript/TypeScript parser, code generator, scope analyzer, and ES2015-era transform pipeline.
- Behavior is validated against vendored Babel fixtures under `vendor/babel`.
- This file holds long-lived repository facts that should remain useful across sessions.

## Repo Map

- `src/parser.zig`, `src/parser_ts.zig`, `src/parser_flow.zig`: parser front-end
- `src/codegen.zig`, `src/codegen_ts.zig`, `src/codegen_flow.zig`, `src/codegen_jsx.zig`: code generation
- `src/scope.zig`: scope and binding analysis
- `src/transform/`: transform passes and shared transform infrastructure
- `tests/*fixture_runner.zig`: parser, codegen, and transform conformance runners
- `scripts/`: benchmark drivers, Babel comparison helpers, and corpus-preparation tooling
- `docs/specs/`: design notes
- `docs/superpowers/plans/`: executable implementation plans

## Environment

- The repo pins Zig via `mise.toml` with `zig = "0.16.0"`.
- Initialize a shell with `eval "$(mise activate zsh)"`, then use direct `zig ...` commands.
- Core checks are `zig build test`, `zig build parse-test`, `zig build codegen-test`, `zig build transform-test`, and `zig build conformance-test`.

## Stable Transform Infrastructure

- `TransformSession` is the shared source of parent, binding, identifier, and `this_expr` occurrence metadata for transform passes; occurrence slices are kept in source order, with sorting only used as a fallback when traversal order is insufficient.
- `RewritePlan` and `replacement_index.zig` are the shared rewrite/replacement plumbing for ordered transform output.
- Real-project throughput work uses pinned corpora defined in `bench/corpus.lock.json`, prepared by `scripts/prepare_real_bench_corpus.cjs`, and benchmarked by `scripts/bench-real-projects.sh`.
- `scripts/bench-real-projects.sh --profile-top N` drills from the slowest real-project files into `profile_shared` and `profile_pass` transform rows emitted by `scripts/transform_bench.zig profile-file`.
- `arrow_functions` uses session-backed `this` / `arguments` occurrence checks before falling back to raw-source scans, so real-project throughput work should prefer keeping `TransformSession` metadata reusable instead of adding new pass-local scans.
- `Pipeline.lastRunStats()` and `Pipeline.lastTransformSession()` are opt-in surfaces; callers that need them must set `collect_run_stats` and `retain_transform_session` explicitly before `run()`.
- Synthetic Zig-vs-Babel comparison still lives in `scripts/bench-compare.sh`.

## Operational Constraints

- Treat `vendor/babel` as fixture/reference data, not project source, unless the task explicitly targets vendored updates.
- Conformance fixtures are the behavioral reference for parser, codegen, and transform output.
- Benchmark scripts validate throughput, not correctness.
- Keep top-level build step names stable when extending `build.zig`.

## Collaboration Docs

- `AGENTS.md` defines workflow and verification rules.
- `progress.md` is the current handoff summary and should stay compact.
- `bugs.md` records concrete defects rather than general uncertainty.
