# Real-Project Transform Throughput Architecture Design

Date: 2026-04-19

## Summary

Define a real-project performance program for the transform pipeline with end-to-end single-file throughput as the primary success metric.

The work has two coordinated tracks:

1. build a reproducible benchmark and comparison system based on pinned public `react-native` and `antd` source corpora
2. evolve the transform engine from repeated pass-local analysis plus ad hoc text rewriting toward a shared-analysis, plan-driven lowering architecture

The benchmark system becomes the decision surface for future performance work. The engine work remains gated by the existing conformance expectations: no intentional relaxation of Babel-aligned behavior is allowed.

## Motivation

Recent synthetic-benchmark work has produced large wins, but it does not fully answer the next question: where does throughput go on real project sources, and what architectural work is justified by that data.

Continuing to optimize around a single synthetic input risks three failures:

- overfitting to one generated file shape
- spending time on local hotspots that do not dominate real-project throughput
- accumulating pass-local caches and special cases instead of removing the structural causes of repeated work

The next step is to replace ad hoc performance judgment with a reproducible real-project benchmark and to use that benchmark to drive architectural optimization of the transform pipeline.

## Goals

- Optimize end-to-end single-file throughput as the primary performance metric.
- Use real project source files as the primary benchmark corpus.
- Keep `react-native` and `antd` as the initial benchmark projects.
- Preserve current transform correctness and Babel-aligned conformance expectations.
- Make benchmark results attributable by project, file, phase, and logical transform stage.
- Reduce repeated transform work by introducing shared analysis and plan-driven lowering.
- Keep stage-level attribution visible even when implementation details are internally shared.

## Non-Goals

- No intentional correctness tradeoff to gain speed.
- No weakening of fixture runners, skip policy, or conformance expectations.
- No attempt to optimize every subsystem at once.
- No permanent dependence on local user checkouts as the primary corpus source.
- No replacement of the current transform pipeline in one step.

## Assumptions

- Public package releases are sufficient to construct an initial real-project benchmark corpus.
- Benchmark reproducibility matters more than sampling the newest unpublished source state.
- The repository can tolerate temporary dual-path maintenance while a new transform architecture is validated.
- The current benchmark scripts are a reasonable starting point, but the reporting surface will need to expand.

## Scope Boundary

This design covers both the measurement layer and the transform-engine architecture needed to improve real-project throughput:

- benchmark corpus acquisition and pinning
- benchmark-tier definition and result reporting
- Babel comparison workflow
- transform shared-analysis infrastructure
- plan-driven rewrite architecture
- staged migration and correctness gating
- regression monitoring for performance

This design does not define every individual code change inside each transform pass. Those details belong in follow-on implementation plans once the benchmark system is in place.

## Options Considered

### Option 1: Measurement platform first, then local hotspot optimization

Start by building a stronger benchmark surface and continue optimizing the hottest existing pass or helper as data arrives.

This is low-risk and easy to validate, but it tends to preserve current architectural boundaries. It improves prioritization but not necessarily the long-term throughput ceiling.

### Option 2: Dual-track benchmark plus architecture upgrade

Build the real-project benchmark system and, in parallel, reshape the transform engine around shared analysis and plan-driven rewriting. Keep the current path as the reference implementation while the new architecture proves itself.

This is the recommended option. It creates a reliable decision surface while also targeting the structural causes of repeated work.

### Option 3: Full transform-core rewrite

Replace the current transform internals with a new architecture in one major step and rebuild all affected passes around it.

This offers the highest theoretical upside, but it is too risky for the current repository constraints. It would make correctness drift and migration debugging much harder than necessary.

## Recommended Design

Adopt Option 2.

The work should proceed on two tracks that inform each other:

- a benchmark track that establishes a stable, real-project measurement surface
- an engine track that incrementally replaces repeated pass-local work with shared analysis and plan-driven lowering

Neither track should advance in isolation. Benchmark results determine optimization priority, and engine changes are only accepted when the real-project benchmark and correctness gates support them.

## Benchmark And Measurement System

### Corpus Source And Pinning

Use pinned public releases of `react-native` and `antd` as the initial benchmark source.

Maintain a checked-in corpus manifest, for example `bench/corpus.lock`, that records:

- package name
- package version
- fetch source or package URL
- integrity or checksum information
- extraction rules, if needed

The default benchmark flow should operate on these pinned releases so results remain reproducible across machines and over time.

Support for local checkout overrides may be added later, but local checkouts are not the benchmark of record.

### Corpus Inclusion Rules

Only include real source files that exercise the parser and transform pipeline in representative ways.

Exclude:

- `dist` outputs
- minified files
- generated snapshots
- vendored third-party bundles
- obviously machine-generated artifacts that do not represent authored source

Prefer files that stress transform-relevant syntax such as:

- default parameters
- rest parameters
- arrow functions
- spread
- `for...of`
- block scoping
- template literals
- TypeScript stripping

The goal is not to run every file in each project. The goal is to maintain a stable benchmark set that is representative, attributable, and practical to rerun often.

### Benchmark Tiers

Define three benchmark tiers:

#### `smoke`

A small set of representative files for fast local iteration and regression checks during development.

#### `core`

The main benchmark set and the primary KPI surface. This is the default decision metric for optimization work.

#### `full`

A larger-coverage set used manually or before major milestones. This adds breadth, but it must not become the default loop if it slows iteration too much.

The repository should treat `core` as the authoritative performance baseline for day-to-day optimization decisions.

### Result Reporting

Each benchmark run should report at least:

- `parse`
- `transform`
- `codegen`
- `total`

Results should be available at both aggregate and file level.

Required aggregate views:

- `ms/file`
- `MB/s`
- `p50`
- `p95`
- Zig/Babel ratio

Required attribution views:

- per-project totals for `react-native` and `antd`
- slowest files
- slowest phases
- logical stage contribution inside `transform`

This keeps benchmark output useful for both executive questions and hotspot diagnosis.

### Babel Comparison

The real-project benchmark must preserve a direct Babel comparison path.

For each tier, the reporting surface should answer:

- how Zig compares to Babel on parse, transform, codegen, and total time
- where Zig is slower or faster by project
- which files are responsible for the largest remaining gap

The Babel comparison is a diagnostic reference, not a justification for relaxing correctness boundaries.

## Transform Engine Direction

The engine goal is to remove repeated structural work, not just layer more local caches onto the current pass boundaries.

The recommended direction has three parts:

1. a shared `TransformSession`
2. plan-driven rewriting
3. bounded pass clustering for function- and scope-related lowering

### Shared TransformSession

Each file should build one session-level analysis surface that can be reused by multiple transform stages.

The session should own high-frequency structural indices such as:

- parent map
- preorder or subtree range data
- `node -> scope`
- `node -> binding`
- identifier occurrence lists
- function boundaries
- capture boundaries
- source span metadata

The rule is simple: expensive structural questions should be answered once per file, then served from shared data rather than rediscovered independently by each pass.

### Plan-Driven Rewriting

Current transform costs are amplified when analysis and text reconstruction are interleaved.

The new direction is to separate them:

- analysis determines which lowering is needed and why
- a rewrite plan records the minimum required replacement intent
- a later application step materializes source replacements

The rewrite plan should describe:

- target node or range
- lowering kind or template
- prerequisites already proven by analysis
- replacement ordering constraints
- any indentation or formatting-sensitive metadata needed during application

This keeps most expensive reasoning in the structural domain and reduces repeated subtree reconstruction during analysis.

### Bounded Pass Clustering

Do not collapse the entire transform pipeline into one opaque mega-pass.

Instead, treat `parameters`, `arrow_functions`, and `block_scoping` as a function-and-scope lowering cluster with shared analysis inputs. These stages repeatedly depend on nearly the same facts:

- function boundaries
- `this` and `arguments` capture
- default and rest parameter behavior
- spread-related lowering context
- loop closure and capture behavior
- rename and reference-escape information

The design should allow those stages to share the expensive analysis while preserving logical stage attribution in benchmark output and diagnostics.

## Migration And Safety Strategy

The new architecture must land incrementally.

### Guardrail 1: Shadow Mode

New paths should begin in shadow mode where practical:

- run the current path as the behavioral reference
- run the new path on the same inputs
- compare outputs, and compare normalized structural results when textual comparison alone is not sufficient

If the outputs differ, treat the result as a regression unless the repository explicitly documents the difference as acceptable and stable.

### Guardrail 2: Existing Conformance Is The Authority

Keep the existing validation surface intact:

- `zig build parse-test`
- `zig build codegen-test`
- `zig build transform-test`
- `zig build conformance-test`

Do not create broader skips or weaker expectations to make a new performance path easier to land.

### Guardrail 3: Dual Acceptance Criteria

No new path becomes the default implementation unless both are true:

- correctness checks stay green
- the `core` real-project benchmark shows stable aggregate benefit

Synthetic-only wins do not justify default enablement.

### Staged Rollout

The migration should proceed in this order:

1. introduce shared analysis infrastructure while existing passes keep their current behavior
2. convert `parameters` to plan-driven rewriting
3. convert `block_scoping` to shared-analysis plus plan-driven rewriting
4. decide whether `arrow_functions` should fully join the shared lowering cluster or stay partially separate
5. default-enable the new path only after shadow validation and real-project benchmark gains are stable

This preserves a rollback path and keeps debugging localized.

## Verification Strategy

Every milestone must satisfy both correctness and performance gates.

### Correctness Gates

Required broad checks:

- `zig build conformance-test`

Required targeted checks:

- focused transform fixtures for default parameters
- focused transform fixtures for rest and spread interactions
- focused transform fixtures for arrow capture and self-reference
- focused transform fixtures for loop closure and block scoping rename behavior

The exact targeted fixture set should be made explicit in the implementation plan for each milestone.

### Performance Gates

Performance acceptance should be judged on the real-project `core` tier, not only on synthetic benchmark input.

Each milestone should report:

- before vs. after aggregate throughput
- before vs. after project-level totals
- top remaining slow files
- phase attribution for the changed area

### Regression Monitoring

The benchmark framework should retain enough history or machine-readable output to detect:

- total throughput regressions
- project-specific regressions
- single-file outliers
- phase-shift regressions where one optimization silently pushes cost into another phase

## Milestones

### Milestone 0: Benchmark Surface

Deliver:

- pinned `react-native` and `antd` corpus definition
- `smoke`, `core`, and `full` tiers
- unified result format
- Babel comparison path

Exit criteria:

- repeated runs on the same machine are stable enough to support decisions
- the benchmark can attribute cost by project, file, phase, and logical stage

### Milestone 1: Shared Analysis Foundation

Deliver:

- `TransformSession`
- shared structural indices consumed by existing passes without changing their behavior

Exit criteria:

- no conformance regressions
- no meaningful real-project throughput regression
- follow-on pass work can consume shared indices instead of rebuilding equivalent structures

### Milestone 2: Parameters Plan-Driven Rewrite

Deliver:

- `parameters` migrated away from mixed analysis and text reconstruction

Exit criteria:

- targeted `parameters` fixtures remain green
- real-project `parameters` cost falls measurably on the `core` corpus

### Milestone 3: Block-Scoping Migration

Deliver:

- `block_scoping` consuming shared analysis and using plan-driven application

Exit criteria:

- loop capture and rename fixtures remain green
- real-project `block_scoping` cost falls measurably on the `core` corpus

### Milestone 4: Function/Scope Lowering Cluster

Deliver:

- shared analysis across `parameters`, `arrow_functions`, and `block_scoping`
- preserved stage attribution despite shared internals

Exit criteria:

- transform total continues to improve on the `core` corpus
- diagnostics remain understandable at the logical-stage level

### Milestone 5: Default Enablement And Monitoring

Deliver:

- new architecture enabled by default
- old path retained temporarily for fallback and comparison
- regression monitoring embedded in the benchmark workflow

Exit criteria:

- stable correctness
- stable real-project throughput benefit
- a clear path to removing the fallback when confidence is high enough

## Risks And Controls

### Risk: Benchmark set overfits to the selected project versions

Control:

Use two unrelated projects with different source characteristics, keep tier membership explicit, and preserve the ability to refresh the corpus in a later controlled update.

### Risk: Shared analysis becomes a new monolith

Control:

Keep `TransformSession` focused on reusable structural facts, not pass-specific policy or mutable ad hoc state.

### Risk: Plan-driven rewriting introduces ordering bugs

Control:

Make ordering constraints explicit in the rewrite plan and validate with shadow-mode comparisons before default enablement.

### Risk: Stage attribution becomes unreadable after pass sharing

Control:

Preserve logical-stage accounting even when the underlying analysis is shared.

### Risk: Dual-path maintenance drags on too long

Control:

Tie each migration phase to explicit exit criteria and only keep the fallback while it materially reduces rollout risk.

## Success Criteria

This design is successful only if all of the following become true:

- real-project benchmarking replaces the synthetic benchmark as the primary decision surface for transform performance
- future optimization work can name the slow projects, files, phases, and logical stages precisely
- transform passes stop paying repeated structural-analysis cost independently
- correctness remains governed by the existing conformance surface
- the repository gains a credible path to sustained throughput improvements beyond one-off hotspot fixes

## Out Of Scope For This Design

This design does not specify:

- the exact package versions to pin first
- the exact file selection algorithm for each benchmark tier
- the exact internal representation of the rewrite plan
- the exact code changes to any transform pass

Those are implementation-planning details to be resolved next, within the constraints defined here.
