# Phase 3: StructuralData + TransformSession Migration — Plan & Progress

**Goal**: Significantly improve real-project transform throughput by eliminating redundant AST traversals.

**Core Idea (Option A)**: Perform one lightweight structural DFS (`buildStructuralData`) that produces parent maps, function/capture boundaries, preorder ranges, identifier occurrences, this expressions, and function binding names. Then let both Scope analysis and hot transform passes (`TransformSession` + individual passes) reuse this data instead of walking the AST multiple times.

---

## High-Level Plan

1. **StructuralData Production**
   - Single DFS in `TransformSession.buildStructuralData` collects:
     - `parent_map`
     - `function_boundary_for_node`
     - `containing_function_node`
     - `capture_boundary_for_node` (function + class)
     - `preorder_start` / `preorder_end`
     - `identifier_occurrences`
     - `function_binding_name_nodes`
     - `this_occurrences`

2. **TransformSession Consumption**
   - `initWithStructuralData` can take the pre-built data.
   - When `preorder` is provided, skip the expensive second `buildParentAndRanges` DFS entirely.
   - Expose fast O(1) helpers: `parentOf`, `contains`, `captureBoundaryOf`, `subtreeRange`, etc.

3. **Pass Migration**
   - Migrate hot passes (`block_scoping`, `parameters`, ...) to query the shared `TransformSession` instead of maintaining their own parent maps or repeatedly calling `getParentNode`.

4. **Verification**
   - `zig build test` + `conformance-test` (834/834) must stay green.
   - Measure with `scripts/bench-real-projects.sh --tier core --profile-top 5`.

---

## Completed Milestones

| Milestone | Status | Notes |
|-----------|--------|-------|
| `StructuralData` includes `capture_boundary_for_node` | ✅ Done | Function + class boundaries produced in one DFS |
| `TransformSession` skips second DFS when preorder provided | ✅ Done | Major win on `transform_session_ns` |
| `session.contains(ancestor, descendant)` (O(1)) | ✅ Done | Uses preorder ranges |
| `session.captureBoundaryOf()` | ✅ Done | Exposed on TransformSession |
| `block_scoping.isDescendantOf` migrated | ✅ Done | Uses `session.contains()` |
| `block_scoping.isDeclarationInLoopBody` walk bounded by capture boundary | ✅ Done | Search now stops at enclosing function/class |
| Centralized `g_parent_session` in `block_scoping.exitNode` | ✅ Done | Removed redundant `ensureParentMap` calls & the function itself |
| Added `hasCaptureBoundary` helper (block_scoping + parameters) | ✅ Done | Symmetry + cleaner future migration code |
| `parameters` started migration | ✅ Done | `ensureParentMap` prefers session, `hasCaptureBoundary` added, redundant `ensureParentMap` call inside `findParentOf` removed |

**Current Performance (latest core-tier run, useSelection.js)**:
- `transform_session_ns`: **363K**
- `scope_analysis_ns`: **1.34M** (still the #1 bottleneck)
- `traversal_ns`: **766K**
- `block_scoping`: **177K**

---

## In Progress / Partially Done

- **block_scoping migration** — ~50% complete
  - Done: `isDescendantOf`, `isDeclarationInLoopBody` (bounded), cleanup.
  - Deferred: `hasFunctionBoundaryBetween` (two conformance regressions; needs more careful design).

- **parameters migration** — ~15–20% complete
  - Infrastructure + helpers in place.
  - Still has legacy `g_node_parents` + `findParentOfSlow` fallback.

---

## Deferred / Blocked

- `block_scoping.hasFunctionBoundaryBetween`
  - Problem: The original function treats `.class_declaration` / `.class_expr` as boundaries, while `functionBoundaryOf` does not.
  - `captureBoundaryOf` was introduced to solve this, but two direct attempts to use it caused 11–41 conformance failures.
  - Current status: **Deferred** until a proven-correct fast-path implementation is designed.

---

## Next Recommended Steps (in rough priority)

1. **Continue safe `block_scoping` migration**
   - Find other pure “ancestor walking / is-descendant” patterns and replace with `session.contains` / `session.parentOf` / `session.captureBoundaryOf`.
   - Avoid `hasFunctionBoundaryBetween` until we have a rock-solid plan.

2. **Deepen `parameters` migration**
   - Replace more `findParentOf` call sites with direct session usage.
   - Eventually remove or deprecate the custom `g_node_parents` maintenance.

3. **Evaluate whether a richer “nearest loop ancestor” helper** (or similar) would give further wins in block_scoping without touching the risky boundary function.

4. **(Later) Re-attack `hasFunctionBoundaryBetween`** once we have:
   - A small test that compares fast vs. slow versions on the fixture corpus, or
   - A refined helper that safely combines function and class boundaries.

5. **Longer term**: Look at `scope_analysis_ns` and `traversal_ns` once the pass-migration thread has more data points.

---

## Verification Discipline (always followed)

- Every non-trivial change must pass:
  - `zig build test`
  - `zig build conformance-test` (834/834)
  - `bash scripts/bench-real-projects.sh --tier core --profile-top 5` (or at least `--profile-top 3`)
- No change is merged if it regresses conformance, even if it looks like a big perf win.

---

**Summary**: The architectural foundation is complete and delivering real, sustained wins on `transform_session_ns`. The pass-migration phase is underway (block_scoping partially done, parameters just started). The hardest remaining piece inside block_scoping (`hasFunctionBoundaryBetween`) is deliberately deferred until we have a safer implementation path.

We are making steady, correct, data-driven progress toward "until fully complete".
