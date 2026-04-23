# Transform Pipeline Throughput Optimization Design

Date: 2026-04-18

## Summary

Optimize transform-path throughput with the explicit goal of reducing end-to-end benchmark runtime for the existing transform pipeline.

This work is scoped to the production transform path, not parser speed, codegen speed, or fixture-runner speed. The approach is profiling-first: establish a benchmark baseline, identify the dominant transform-stage costs, then apply structural optimizations to the highest-value hotspot or hotspots.

## Motivation

The repository already documents historical transform hotspots in `AGENTS.md`:

- `spread`
- `parameters`
- `for_of`
- `block_scoping`

That history is useful, but it is not enough to justify optimization work by itself. The current request is to improve overall transform performance, with success measured by end-to-end benchmark time rather than isolated microbench wins. That requires current evidence about where total pipeline time is actually going.

Without that measurement step, performance work is likely to overfit to familiar hotspots, produce local improvements that do not move total runtime, or introduce structural churn without enough throughput payoff.

## Goals

- Reduce total runtime for the transform benchmark, not just isolated pass timings.
- Establish enough stage-level measurement to identify the dominant transform costs in the current pipeline.
- Limit this round of optimization to the one or two hotspots most likely to move total throughput.
- Allow deep internal changes within the selected hotspot area when the measurement data justifies them.
- Preserve current transform correctness through the existing benchmark and conformance workflows.

## Non-Goals

- No parser-speed optimization in this project.
- No codegen-speed optimization in this project.
- No fixture-runner or test-harness optimization in this project.
- No broad rewrite of every transform pass.
- No permanent debug-only scripts, ad hoc build steps, or benchmark instrumentation that pollutes normal development workflows.
- No correctness tradeoffs such as weakening transforms, skipping fixtures, or relaxing test expectations to achieve better benchmark numbers.

## Scope Boundary

This design defines one focused performance sub-project:

- `transform pipeline throughput optimization`

Work is in scope if it directly helps answer one of these questions:

- where does total transform benchmark time go
- which transform stage or shared transform cost dominates total runtime
- what structural change would plausibly reduce total pipeline time

Work is out of scope if it expands the problem into unrelated subsystems or tries to optimize everything at once.

## Options Considered

### Option 1: Local hotspot micro-optimizations first

Start from historically hot passes and reduce obvious local costs such as allocations, copies, or repeated checks.

This is the fastest way to start changing code, but it is not the best fit for the stated success criterion. Local wins do not necessarily reduce total benchmark time enough to matter.

### Option 2: Broad transform-pipeline refactor first

Assume that total runtime problems come from larger structural issues and begin with a wide pipeline redesign.

This offers large theoretical upside, but it expands risk too quickly. Without current measurement, it is too easy to pay major correctness and maintenance cost for uncertain throughput gains.

### Option 3: Profiling-first, then targeted structural optimization

Measure total and stage-level costs first, identify the strongest hotspot candidates, then optimize the one or two targets most likely to reduce total runtime.

This is the recommended option. It matches the requested success metric, supports aggressive internal changes when warranted, and keeps the project bounded enough to validate.

## Recommended Design

Adopt Option 3.

The work should proceed in three phases:

1. measurement and attribution
2. hotspot selection
3. structural optimization plus verification

The key discipline is that optimization work must remain evidence-driven. Familiar hotspot names are useful starting hypotheses, not automatic implementation targets.

## Phase 1: Measurement And Attribution

The first phase is to establish a benchmark baseline and collect enough transform-stage data to identify where total runtime is currently concentrated.

The measurement layer should stay close to the existing performance workflow:

- `bash scripts/bench-transform.sh`
- `bash scripts/bench-compare.sh`

Do not introduce a separate heavyweight profiling framework unless the existing scripts prove insufficient. The preferred approach is to instrument the transform pipeline at stage boundaries so the benchmark output can answer:

- what the total transform runtime is
- which transform stages contribute the largest cumulative cost
- whether the dominant cost appears to be pass-local or shared infrastructure

If a total-time benchmark alone is too coarse, add a small amount of supporting instrumentation such as:

- stage cumulative time
- stage invocation count
- scope-construction count
- selected temporary-container or allocation counters

Instrumentation should be minimal, removable, and justified by a specific attribution need.

## Phase 2: Hotspot Selection

After measurement, select at most one or two optimization targets for this round.

Target selection should be based on all of the following:

- meaningful contribution to total benchmark runtime
- a clear hypothesis about why the target is expensive
- a realistic path to structural improvement
- a correctness boundary that can be validated with the repo's existing test and conformance workflow

A stage is not a good target just because it is historically hot. It becomes a good target when the current benchmark shows that optimizing it is likely to reduce total pipeline time.

If the dominant cost is shared infrastructure rather than a single pass, it is valid to target a shared cause such as:

- repeated scope work
- repeated traversal over the same node population
- repeated allocation and discard of temporary structures
- duplicated precondition checks across passes

## Phase 3: Structural Optimization

The selected hotspot work may be aggressive internally, but it should still be narrowly justified by measured cost.

The following optimization categories are in scope:

### Repeated traversal reduction

If a hotspot pass scans the same region or node class multiple times, consolidate the work where possible. Reduce repeated lookup, repeated classification, and repeated preparatory walks when the same information can be carried forward through one traversal.

### Scope and binding cost reduction

If measured cost points to repeated scope construction or over-broad scope dependency, tighten the boundary between passes that truly need scope and passes that can make cheaper local decisions. Review whether current `pipeline.needs_scope` behavior or related scope access patterns are creating avoidable total cost.

### Allocation and temporary-structure reduction

If the bottleneck is driven by short-lived builders, arrays, string buffers, or node-copy churn, shorten object lifetimes, increase reuse where appropriate, and remove intermediate representations that exist only to be immediately transformed again.

### Shared-work elimination across passes

If two or more transform stages are paying the same setup or classification cost, consider extracting or deferring the shared work instead of recomputing it in each stage. This is the highest-risk category and should be used only when the benchmark data clearly points there.

## Design Constraints

- Prefer one well-justified deep optimization over many speculative tweaks.
- Do not optimize multiple unrelated transform passes in the same round without evidence that each contributes meaningfully to total runtime.
- Keep benchmark instrumentation proportional to the question it answers.
- Remove temporary measurement helpers once they are no longer needed, unless they become part of an intentional long-term benchmarking workflow.
- Do not hide correctness regressions behind fixture skips or relaxed expectations.

## Verification Strategy

Performance validation must prove end-to-end improvement, not just local speed changes.

Required validation order:

1. establish the pre-change benchmark baseline
2. collect stage-level measurement for attribution
3. implement the selected optimization
4. rerun the benchmark and compare total runtime before vs. after
5. rerun the relevant correctness checks

Required correctness checks after optimization:

- `zig build test`
- the relevant transform conformance runner

Additional checks are required when the optimization changes adjacent behavior:

- rerun `zig build codegen-test` if formatting, parenthesization, comments, or emitted syntax shape may drift
- rerun broader conformance if the optimization touches shared transform infrastructure or scope-dependent behavior

When scope or pass scheduling semantics are touched, review whether full `zig build conformance-test` is warranted rather than only a narrower runner.

## Success Criteria

This project is only successful if all of the following are true:

- the transform benchmark shows a measurable end-to-end runtime reduction
- the optimization target was chosen based on current benchmark evidence, not only historical expectation
- the optimization can be explained in structural terms, not only as a pile of micro-tweaks
- correctness checks remain green

The following do not count as success on their own:

- a hotspot stage getting faster while total runtime stays flat
- a one-off benchmark number without reproducible before/after comparison
- a benchmark improvement purchased by weakening transform behavior or test coverage

## Risks And Controls

### Risk: Optimizing the wrong hotspot

Historical expectations can be wrong for the current benchmark input.

Control:

Require a benchmark baseline and stage-level attribution before selecting optimization targets.

### Risk: Large structural churn without enough payoff

Aggressive internal refactors can expand quickly once performance work begins.

Control:

Limit the round to one or two measured hotspots and require an explicit path from the chosen change to end-to-end runtime reduction.

### Risk: Hidden correctness regressions

Transform performance work can accidentally change traversal order, scope behavior, or emitted syntax.

Control:

Use the repository's existing correctness workflow after optimization, and expand validation when scope or codegen-sensitive behavior is touched.

### Risk: Benchmark pollution

Temporary counters, debug output, or special-case build steps can linger after the measurement phase.

Control:

Keep measurement support minimal and remove ad hoc tooling that is only useful during the investigation phase.

## Out Of Scope For This Design

This design does not yet choose the exact hotspot pass or the exact code changes. Those decisions depend on the measurement phase.

This design also does not define a new permanent profiling subsystem. It only requires enough measurement to support target selection and validation for this optimization round.
