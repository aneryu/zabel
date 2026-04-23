# Full-Pipeline Throughput Optimization Design

Date: 2026-04-20

## Summary

Optimize end-to-end throughput across `parse`, `transform`, and `codegen`, using the pinned real-project corpus as the primary decision surface.

This round is explicitly measurement-first. The repository already has a strong transform benchmark surface, but full-pipeline optimization needs a tighter attribution path from aggregate runtime down to the dominant phase and then, when needed, down to transform-internal costs. The recommended approach is:

1. keep `bash scripts/bench-real-projects.sh --tier core` as the primary acceptance metric
2. improve hotspot attribution only where the existing output is too coarse
3. select one dominant, evidence-backed bottleneck
4. make the smallest structural change that reduces total runtime without weakening correctness checks

## Motivation

Recent throughput work has improved transform internals and established a reproducible real-project corpus based on `react-native` and `antd`. That benchmark already reports per-file and aggregate `parse`, `transform`, `codegen`, and `total` times, which is enough to rank slow files and broad phase costs.

What it does not yet provide in one continuous workflow is a clean path from:

- "which files dominate total runtime"
- to "which phase is responsible"
- to "if transform is responsible, is the time in scope analysis, shared session construction, dispatch setup, traversal, or a specific pass"

Without that attribution chain, full-pipeline work risks two common failures:

- continuing to optimize transform even when parse or codegen dominates total cost
- making broad speculative changes across subsystems instead of fixing the single bottleneck most likely to move end-to-end time

The next step is to make the benchmark output sufficient for hotspot selection, then land only the first high-confidence optimization.

## Goals

- Reduce end-to-end throughput time on the pinned real-project corpus.
- Use `bash scripts/bench-real-projects.sh --tier core` as the primary KPI surface.
- Keep `parse`, `transform`, `codegen`, and `total` attributable by file and project.
- Make it practical to drill from aggregate totals into the hottest files and then into transform-internal costs when transform is the dominant phase.
- Limit this round to one measured bottleneck and one focused optimization track.
- Preserve current parser, codegen, and transform correctness expectations.

## Non-Goals

- No correctness tradeoff for speed.
- No weakening of fixture runners, conformance expectations, or existing known-failure accounting.
- No attempt to optimize parse, transform, and codegen simultaneously in one round.
- No replacement of the current benchmark surface with a separate profiler-first workflow.
- No permanent debug-only binaries, fixture-specific hacks, or bespoke benchmark build paths.

## Current State

The repository already has the core pieces needed for full-pipeline work:

- `scripts/bench-real-projects.sh` prepares the pinned corpus and compares Zig against Babel on the same tier.
- `scripts/transform_bench.zig` can emit per-file `parse`, `transform`, `codegen`, and `total` rows for a file list.
- `src/bench/real_project_bench.zig` aggregates those rows into summary and per-project output.
- `src/transform/pipeline.zig` already records transform-internal timing for:
  - `scope_analysis_ns`
  - `transform_session_ns`
  - `dispatch_table_build_ns`
  - `traversal_ns`
  - per-pass totals and enter/exit call counts

The main gap is not the absence of measurements. The gap is that transform-internal timings are currently easiest to access through the single-file `profile` mode, while the real-project full-pipeline benchmark is optimized for aggregate file reporting. That makes hotspot ranking easy but keeps the second-stage diagnosis more manual than it should be.

## Assumptions

- The pinned `react-native` and `antd` corpora remain representative enough for this optimization round.
- The `core` tier is still the best day-to-day performance KPI because it balances signal and iteration time.
- The hottest total-runtime files in the corpus are more useful than synthetic inputs for choosing cross-phase work.
- If `transform` is not the dominant cost for the hottest files, optimization effort should move to `parse` or `codegen` rather than forcing another transform-first round.

## Options Considered

### Option 1: Keep optimizing transform with the current profiling tools

Use the existing transform profile output and continue targeting transform internals directly.

This is low friction because the transform instrumentation already exists, but it does not satisfy the full-pipeline objective. It assumes the answer is still in transform before verifying whether parse or codegen now dominates end-to-end runtime.

### Option 2: Add just enough attribution to the real-project benchmark, then optimize the top bottleneck

Keep the current benchmark scripts and corpus, strengthen the hotspot-diagnosis path where needed, rank the hottest files and phases, then optimize only the dominant measured bottleneck.

This is the recommended option. It preserves the current workflow, minimizes instrumentation churn, and keeps the optimization round honest about what actually dominates total runtime.

### Option 3: Launch parallel optimization tracks for parse, transform, and codegen

Profile all three phases deeply and try to land multiple wins in one round.

This could produce a larger total improvement, but it is the wrong risk profile for the current repository guidance. It expands scope too quickly, makes attribution muddier, and increases correctness risk across subsystems before the first bottleneck is even confirmed.

## Recommended Design

Adopt Option 2.

The work should proceed in four steps:

1. establish a current full-pipeline baseline on the real-project corpus
2. improve attribution only where current output is too coarse to choose a bottleneck
3. select the single strongest hotspot
4. implement one focused optimization and rerun correctness plus benchmark checks

This keeps measurement work proportional to the question being asked and avoids overbuilding infrastructure before it is justified.

## Measurement Strategy

### Primary Benchmark Surface

Keep `bash scripts/bench-real-projects.sh --tier core` as the primary optimization loop.

That run already answers the first-level questions:

- total Zig time vs Babel time
- per-project totals
- slowest files
- broad phase totals across `parse`, `transform`, and `codegen`

This is the acceptance surface for deciding whether an optimization round moved real end-to-end time.

### Secondary Hotspot Attribution

Add a second-level diagnosis path for the hottest files rather than trying to fully profile every file in every run.

The intended flow is:

1. run the real-project benchmark and identify the slowest files by total runtime
2. inspect which broad phase dominates those files
3. if `transform` dominates, expose or reuse transform-internal stats for those files:
   - `scope_analysis_ns`
   - `transform_session_ns`
   - `dispatch_table_build_ns`
   - `traversal_ns`
   - per-pass totals
4. if `parse` or `codegen` dominates, move the optimization focus to that subsystem instead of forcing transform-specific work

The benchmark surface should make this drilldown easy enough that hotspot selection does not depend on ad hoc manual inspection.

### Reporting Requirements

The reporting surface for this project must answer all of the following without ambiguity:

- Which files dominate total runtime in the `core` tier?
- For those files, which of `parse`, `transform`, or `codegen` dominates?
- If `transform` dominates, how much of that time is shared infrastructure versus pass-local work?
- Are the hottest costs concentrated in one project, one file family, or one pass family?

The benchmark does not need a heavyweight profiler UI. Tabular output remains sufficient if it exposes these questions clearly.

## Optimization Selection Rule

Only one hotspot track should be active in this round.

The selected target must satisfy all of the following:

- it contributes meaningfully to total runtime on the `core` tier
- the measured data identifies a plausible structural cause
- the change can be validated with the repository's existing correctness commands
- the likely win is large enough to justify touching production code

Examples of valid hotspot classes:

- parser work repeated across high-volume syntax patterns
- codegen formatting or replacement emission overhead on large files
- transform shared infrastructure such as scope analysis or traversal overhead
- one transform pass whose cumulative time clearly dominates the rest

Examples of invalid target selection:

- choosing a historically hot pass without current benchmark evidence
- selecting two or three unrelated hotspots in one round
- mixing benchmark refactors and production optimizations without proving which one matters

## Implementation Boundaries

The code change should be the smallest structural change that addresses the confirmed bottleneck.

This means:

- no speculative cross-phase cleanup
- no unrelated refactors while touching the hotspot
- no broad abstraction work unless the benchmark data shows that shared structure is the cost center
- no leaving temporary counters or debug paths in normal production flow unless they are part of the intentional benchmark surface

If the first optimization reveals that the chosen hotspot was not actually dominant enough, the correct next move is to return to measurement, not to chain more speculative fixes onto the same patch.

## Verification Strategy

Performance validation must prove a real end-to-end improvement, not just a prettier internal profile.

Required validation sequence:

1. capture the pre-change benchmark on `bash scripts/bench-real-projects.sh --tier core`
2. run the smallest targeted check for the touched subsystem
3. implement the change
4. rerun the targeted check
5. run `zig build test`
6. run the relevant conformance runner for the touched subsystem
7. run `zig build conformance-test` if shared infrastructure or cross-phase behavior changed
8. rerun `bash scripts/bench-real-projects.sh --tier core`
9. rerun `bash scripts/bench-real-projects.sh --tier full` if the `core` win is material and the change touches shared infrastructure

Subsystem-specific expectations:

- parser work starts with the smallest relevant `parse-test -- <fixture> --diff`
- codegen work starts with the smallest relevant `codegen-test -- --diff <fixture>`
- transform work starts with the smallest relevant `transform-test` fixture and expands to `codegen-test` when syntax shape or comments can drift

Any Zig source edits must still be formatted with `zig fmt`.

## Success Criteria

This round is successful only if all of the following are true:

- the benchmark identifies a dominant full-pipeline bottleneck before production code changes begin
- the implemented change targets that measured bottleneck directly
- `bash scripts/bench-real-projects.sh --tier core` shows a reproducible end-to-end improvement
- correctness checks remain green at the required scope

The following do not count as success on their own:

- a transform pass getting faster while total runtime is flat
- a microbenchmark win without a real-project benchmark improvement
- a one-off run that cannot be reproduced
- a benchmark improvement that comes with correctness regression or weakened validation

## Risks And Controls

### Risk: The benchmark surface is still too coarse

Control:

Add only the missing attribution needed for hotspot selection, and keep it aligned with the existing real-project workflow rather than inventing a separate profiling path.

### Risk: Optimizing the wrong subsystem

Control:

Require hotspot selection from measured `parse`, `transform`, and `codegen` totals before editing production code.

### Risk: Turning one performance task into a repo-wide refactor

Control:

Limit the first optimization round to one bottleneck and one focused production change.

### Risk: Regressing correctness while chasing throughput

Control:

Use the existing targeted runners, `zig build test`, and wider conformance checks when shared infrastructure changes.
