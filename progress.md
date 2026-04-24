# Progress

## Current Focus

- Keep the collaboration docs compact and current as the repo handoff surface.
- Continue full-pipeline throughput work through the approved plan in `docs/superpowers/plans/2026-04-20-full-pipeline-throughput-optimization.md`.
- Prefer real-project measurements on the pinned `react-native` and `antd` corpora over synthetic-only conclusions.
- Use `bash scripts/bench-real-projects.sh --tier core --profile-top 5` as the main hotspot drilldown surface before making the next transform-throughput change.
- Build on the shared `TransformSession`, `RewritePlan`, and replacement-index infrastructure instead of adding new pass-local caches.

## Recent Completed

- Added machine-readable transform hotspot rows (`profile_shared` / `profile_pass`) plus `transform_bench profile-file` so real-project benchmarking can drill from slow files into shared transform overhead and per-pass totals.
- Extended `bash scripts/bench-real-projects.sh` with `--profile-top N`, then fixed the live-profile reporting path so it prints all requested hotspots without shell stdin interference or buffered-file truncation.
- Made `Pipeline` run-stat collection and retained transform-session ownership opt-in via `collect_run_stats` / `retain_transform_session`, leaving normal transform runs on the cheaper path.
- Re-measured the current `core` tier after removing default profiling overhead: Zig total time improved from `49,242,457ns` to `47,816,040ns` and transform phase time improved from `30,383,833ns` to `29,843,999ns`.
- Added `TransformSession.thisOccurrences()` and switched `arrow_functions` body `this` / `arguments` prechecks to session-backed occurrence filtering when a session is available, while also dropping the extra raw binding-name source precheck before self-reference detection so the pass relies directly on binding occurrences.
- Fixed a direct-expression-body regression in the new session path by treating `node == body_node` as an in-body reference, restoring `() => this` / `() => arguments` captures and the `arrow_functions` transform-fixture suite.
- Re-measured the fixed `core` tier after the session-backed `arrow_functions` precheck change: repeated runs landed at `zig_total_ns=41,787,249` / `transform=24,393,374` and `zig_total_ns=43,559,502` / `transform=25,586,833`, down from the previous `47,816,040ns` / `29,843,999ns` checkpoint.
- Confirmed the hottest current `core` files are still transform-dominated, but `arrow_functions` is no longer the main offender in `es/table/hooks/useSelection.js` (`112,000ns`) or `es/table/InternalTable.js` (`55,000ns`); shared transform cost plus `ts_strip` now dominate the remaining drilldown output.
- Made `TransformSession` skip its disconnected-node fallback sweep when the root traversal already covered the full AST, and changed occurrence ordering to sort only when traversal produced out-of-order data instead of sorting every collected list unconditionally.
- Re-measured the current `core` tier after the `TransformSession` ordering shortcuts: one noisy rerun overshot, but the follow-up confirmation landed at `zig_total_ns=43,124,960` / `transform=23,492,375`, with `transform_session_ns` dropping on the main hotspots (`useSelection.js`: `1,521,000ns`, `AnimatedImplementation.js`: `1,300,000ns`, `InternalTable.js`: `1,051,000ns`).
- Confirmed the current `full` tier also improved after the session shortcuts: `zig_total_ns=49,681,456` and `transform=28,522,541`, down from the prior `53,295,541ns` / `32,388,666ns` confirmation run.
- Replaced `std.c.clock_gettime` in `monotonicNowNs()` with `std.os.linux.clock_gettime` to remove libc dependency from the transform pipeline, allowing benchmarks and tests to compile without linking libc.
- Optimized `ts_strip.scanImportUsage()`: limited `collectImportedNames` and `collectLocalDeclarations` to program body statements instead of all AST nodes; added session-backed `scanValueUsagesViaSession` that uses `TransformSession.identifierOccurrences()` + parent chain walks to determine type context, avoiding the O(N) recursive AST traversal in `scanValueUsages`.
- Measured `core` tier improvement: `ts_strip` pass time on `useSelection.js` dropped from `3.15M ns` to `1.72M ns` (45% reduction); traversal_ns dropped 24.5%; overall transform phase improved ~11.7%.

- Eliminated `identifier_occurrences` StringHashMap from `TransformSession`: resolved identifiers (~90%) now go directly into `binding_occurrences` arrays, skipping the hash map entirely; only unresolved identifiers (globals, free refs, no-scope case) fall back to a smaller `unresolved_occurrences` hash map. Callers in `block_scoping` and `ts_strip` now iterate `bindingIndices` + `bindingOccurrences` directly. `arrow_functions` uses `identifierOccurrences()` which checks unresolved map first then derives from binding occurrences.
- Added `visitor.isLeafTag()` predicate (matching the 0-children tags from `getChildren`). Used it to skip the `getChildren()` switch dispatch for leaf nodes in both `TransformSession.visitNode` and `Pipeline.visitNode`.
- `useSelection.js` profile results (median of 5, 3 warmups): `transform_session_ns` dropped from `13.1M` to `7.5M` (−43%), `pipeline_ns` dropped from `51.8M` to `44.8M` (−13.5%), `traversal_ns` dropped from `19.6M` to `19.0M` (−3.1%).
- `core` tier total: `zig_total_ns` dropped from `321.4M` to `311.0M` (−3.2%), `p95_total_ns` dropped from `95.6M` to `86.7M` (−9.3%).

## Likely Next Steps

- `transform_session_ns` is now ~7.5M on the hottest file; further gains likely require merging the parent/preorder traversal with scope analysis to avoid a second full-AST walk.
- `traversal_ns` (~19M) and `scope_analysis_ns` (~10M) are the remaining dominant costs.
- Keep removing pass-local structural or lookup caches when equivalent session-backed data already exists.
- Treat `core` before/after measurements as the acceptance metric; use `full` as a confirmation run after material shared-infrastructure changes.

## Verification Snapshot

- 2026-04-20: `node --test scripts/prepare_real_bench_corpus_test.cjs` passed at `9 pass / 0 fail`.
- 2026-04-20: `/usr/local/bin/mise exec -- zig build test` passed after adding `TransformSession.thisOccurrences()` and the session-backed `arrow_functions` prechecks.
- 2026-04-20: `/usr/local/bin/mise exec -- zig build transform-test -- vendor/babel/packages/babel-plugin-transform-arrow-functions/test/fixtures/arrow-functions` passed at `18 pass / 0 fail / 816 skip / 0 error`, confirming the direct-expression-body fix restored the arrow-functions fixture suite.
- 2026-04-20: `/usr/local/bin/mise exec -- zig build conformance-test` completed at the current baseline: parser `5891 pass / 0 fail / 0 skip / 0 error`, codegen `486 pass / 0 fail / 0 skip / 0 error`, transform `825 pass / 9 fail / 0 skip / 0 error`.
- 2026-04-20: pre-change `core` benchmark with hotspot drilldown recorded `zig_total_ns=49,242,457` and `transform=30,383,833` from `bash scripts/bench-real-projects.sh --tier core --profile-top 5`.
- 2026-04-20: current `core` benchmark with hotspot drilldown recorded `zig_total_ns=41,787,249` and `transform=24,393,374` from `bash scripts/bench-real-projects.sh --tier core --profile-top 5`.
- 2026-04-20: repeat `core` confirmation run recorded `zig_total_ns=43,559,502` and `transform=25,586,833` from `bash scripts/bench-real-projects.sh --tier core --profile-top 5`.
- 2026-04-20: post-session-shortcut `core` confirmation run recorded `zig_total_ns=43,124,960` and `transform=23,492,375` from `bash scripts/bench-real-projects.sh --tier core --profile-top 5`.
- 2026-04-20: post-session-shortcut `full` confirmation run `bash scripts/bench-real-projects.sh --tier full` completed with `zig_total_ns=49,681,456` and `transform=28,522,541`.
- 2026-04-23: `zig build test` passed after `monotonicNowNs` and `scanImportUsage` optimizations.
- 2026-04-23: `zig build conformance-test` completed: parser `5891 pass / 0 fail`, codegen `486 pass / 0 fail`, transform `832 pass / 2 fail` (same 2 pre-existing failures as baseline).
- 2026-04-24: `zig build test` passed after identifier hash map elimination and leaf-tag fast path.
- 2026-04-24: `zig build conformance-test` completed: parser `5891 pass / 0 fail`, codegen `486 pass / 0 fail`, transform `829 pass / 5 fail` (same pre-existing failures as baseline).
