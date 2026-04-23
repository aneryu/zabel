# Parameters Pass Throughput Optimization Design

Date: 2026-04-18

## Summary

Optimize the `parameters` transform pass with the explicit goal of producing a large, benchmark-visible reduction in overall transform-path runtime.

This work follows the completed transform profiling round, which identified `parameters` as the dominant pass-level hotspot by a wide margin in repeated benchmark runs. The optimization is allowed to restructure the internal processing model of `src/transform/parameters.zig`, but it must preserve the pass's external behavior and existing fixture expectations.

## Motivation

The current transform benchmark baseline clearly identifies `parameters` as the dominant cost center:

- first run: `parameters = 35327.641 ms/iter`
- repeat run: `parameters = 36040.789 ms/iter`
- `scope_analysis` remained far smaller in both runs

That removes ambiguity about where this optimization round should focus. The next question is not which pass to optimize, but how to change the `parameters` pass in a way that can materially reduce total benchmark time rather than only shaving off local overhead.

The strongest current bottleneck hypotheses are:

- repeated traversal or repeated per-function analysis
- excessive string construction and replacement-source generation work
- scope-related query cost paid multiple times across one function transform

Those hypotheses point away from isolated micro-tweaks and toward a deeper internal restructuring of how the pass processes one function at a time.

## Goals

- Achieve a large, benchmark-visible reduction in overall transform runtime by reducing the cost of the `parameters` pass.
- Restructure `parameters` processing so one function is analyzed once and generated once, instead of being repeatedly re-derived during transformation.
- Reduce repeated source extraction, repeated cache rebuilding, repeated scope queries, and repeated replacement-text assembly.
- Add a simple fast path for cheap parameter cases so common functions do not pay the full cost of the complex path.
- Preserve existing transform semantics, fixture behavior, and config-option meanings.

## Non-Goals

- No optimization work on `spread`, `for_of`, or `block_scoping` in this design.
- No parser, codegen, or fixture-runner optimization in this design.
- No changes to the ordering relationship between `parameters` and surrounding passes.
- No intentional changes to the semantics of:
  - `ignore_function_length`
  - `loose`
  - `emit_var_bindings`
  - `arrow_no_new_arrows`
  - `preserve_type_annotations`
- No broad transform-pipeline redesign.

## Scope Boundary

This design is intentionally narrow:

- primary target: `src/transform/parameters.zig`
- optional secondary support: minimal benchmark or support-code touches if needed to validate the optimization

The pass may be deeply reorganized internally, but the work must remain about making `parameters` cheaper. It must not expand into a cleanup campaign across unrelated passes or a general transform framework rewrite.

## Options Considered

### Option 1: Local micro-optimization only

Focus on obvious low-level costs such as individual allocations, append patterns, or helper call counts.

This is the smallest change, but it is unlikely to produce the scale of total benchmark improvement required here. The baseline suggests the pass is paying a structural cost, not only a handful of local inefficiencies.

### Option 2: Single-analysis plus single-generation architecture

Reorganize per-function processing into a small fixed set of stages:

1. cheap eligibility and path classification
2. one function-level analysis pass
3. generation-plan selection
4. one final replacement-generation pass

This is the recommended option. It directly targets repeated traversal, repeated source extraction, and repeated scope-query cost while still staying local to `parameters`.

### Option 3: Fast-path branching without deeper restructuring

Keep the existing structure but bolt on lightweight exits for simple parameter cases.

This can help, and it should be used where justified, but by itself it is unlikely to be enough. The pass appears heavy enough that the complex path itself must become cheaper.

## Recommended Design

Adopt Option 2, with targeted fast-pathing from Option 3.

The `parameters` pass should be restructured around a function-local processing pipeline. Instead of interleaving classification, source extraction, cache population, and replacement generation across many helpers, it should move through explicit internal stages and keep a function-local working set that generation can consume directly.

The core architectural idea is:

- analyze once
- decide once
- generate once

## External Behavior Constraints

The following external properties must remain unchanged:

- the `parameters` pass still handles the same function-like node kinds
- pass configuration semantics stay unchanged
- interactions with surrounding passes stay unchanged
- fixture output and conformance expectations stay unchanged

This design allows deep internal change, but not behavior drift.

## Internal Architecture

Per-function handling should be reorganized into four internal stages.

### Stage 1: Eligibility and path classification

This stage should answer the cheapest possible questions first:

- does this function require any `parameters` transform work at all
- is it a simple case or a complex case
- which high-level generation path will likely apply

This stage should avoid expensive source extraction, broad cache setup, or wide scope querying wherever possible. Its job is to reject or classify quickly.

### Stage 2: Function-level analysis

If the function needs transformation, build one function-local analysis result containing exactly the information generation will need, such as:

- parameter classification
- runtime argument index mapping
- whether default/rest/destructuring logic is present
- whether arrow-specific handling is required
- whether hoist-sensitive behavior is required
- whether expensive scope-derived decisions are needed

This stage should gather facts, not build output text.

### Stage 3: Generation-plan selection

Convert the analysis result into one concrete generation plan, for example:

- simple fast path
- ordinary function path
- arrow-specific path
- complex destructuring and hoist-aware path

This plan should act as the contract between analysis and output generation. It prevents helpers from repeatedly rediscovering which path they are on while already assembling strings.

### Stage 4: Replacement generation

Generate the final replacement source and any required replacement ranges from the precomputed plan and analysis result.

This stage should do the unavoidable string work, but only after earlier stages have already fixed:

- which path is being used
- which nodes and sources are needed
- which scope-derived facts are required

## Fast Path Strategy

The fast path is important, but it should be explicit rather than accidental.

It should be reserved for cases that are cheap in both analysis and generation, such as:

- simple default parameters
- simple rest parameters
- parameter lists that do not require deep destructuring handling
- cases that do not need complex hoist exclusions or broad scope-dependent rewriting

The fast path should avoid pulling in the machinery needed only for complex cases.

## State And Cache Strategy

The current file already contains substantial global run-state and caches. That is a strong signal that some work may currently be happening too early, too often, or at too broad a lifetime.

The design direction should be:

- prefer function-local working state over pass-global state
- keep global state only when it genuinely spans multiple function transforms
- delay source extraction until generation or until a proven need exists during analysis
- avoid rebuilding large helper structures for functions that can cheaply exit

In particular, the following categories should be examined critically:

- recursive source caches
- replacement subtree caches
- replacement range tracking
- parenthesized-child tracking
- class-field value tracking
- helper state that survives longer than one function transform without clear reuse benefit

This does not mean every global cache must disappear. It means every cache should justify its lifetime and reuse.

## Scope Query Strategy

Scope queries should be concentrated rather than scattered.

If scope-derived decisions are needed, they should be gathered in the analysis stage and passed forward through the analysis result or generation plan. Generation should consume these facts rather than triggering more opportunistic scope queries from many helpers.

The desired outcome is that scope cost is paid only for functions and paths that actually require it, and paid once per decision category rather than repeatedly during output assembly.

## String And Replacement Strategy

String building is likely a major part of the current cost. The design should therefore prefer:

- deferred source extraction
- reuse of function-local source fragments
- one replacement-generation phase instead of many partial assembly steps
- minimizing intermediate strings that exist only to be immediately wrapped or re-sliced again

Replacement ranges and output fragments should be built from a plan, not discovered on the fly during string concatenation.

## Verification Strategy

This optimization is only worthwhile if it reduces total runtime, not only the isolated `parameters` pass number.

Required validation:

1. rerun the transform benchmark with pass-hotspot output
2. confirm `parameters` time drops materially
3. confirm total benchmark runtime also drops materially
4. rerun correctness checks

Required correctness checks:

- `zig build test`
- the relevant transform conformance runner for `parameters`

Additional checks are required if the restructuring changes adjacent syntax shape or replacement behavior that may surface outside `parameters` fixtures:

- `zig build codegen-test`
- broader `zig build conformance-test` when the scope of change makes it prudent

## Success Criteria

This project is only successful if all of the following are true:

- total transform benchmark runtime shows a large, obvious reduction
- `parameters` remains the same transform semantically
- correctness checks stay green
- the new internal structure can explain why the pass became cheaper, rather than only claiming a cluster of local tweaks

The following do not count as success:

- `parameters` pass time goes down but total benchmark time barely moves
- a speedup that depends on weakened behavior or narrower validation
- an optimization that only works for the benchmark by accidentally favoring one narrow code shape while destabilizing broader fixture behavior

## Risks And Controls

### Risk: Deep rewrite with weak payoff

Because this design allows core-flow restructuring, it could grow into expensive churn without enough speed gain.

Control:

Keep the change centered on the four-stage per-function model and measure against the same benchmark before and after.

### Risk: Fast path helps simple cases but leaves the complex path dominant

If the benchmark is dominated by complex parameter handling, a fast path alone will not move total runtime enough.

Control:

Treat fast paths as support for the redesign, not the redesign itself. The complex path must also become cheaper.

### Risk: Scope behavior regressions

Centralizing scope queries can subtly change when or how scope-derived facts are computed.

Control:

Preserve semantics and rerun the relevant conformance suite after the refactor.

### Risk: Cache-lifetime mistakes

Moving from pass-global to function-local state can introduce stale references, missing reuse, or ownership bugs.

Control:

Make ownership explicit and keep working data scoped to one function unless cross-function reuse is clearly intentional.

## Out Of Scope For This Design

This design does not yet define the exact helper names, exact data-structure names, or exact line-by-line edits. Those belong in the implementation plan.

This design also does not commit to deleting every existing cache or helper. It defines the direction of simplification and reuse boundaries rather than a forced mechanical rewrite of the entire file.
