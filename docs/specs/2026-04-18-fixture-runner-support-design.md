# Fixture Runner Support Design

Date: 2026-04-18

## Summary

Introduce a single shared test-side support module for the three fixture runners:

- `tests/babel_fixture_runner.zig`
- `tests/codegen_fixture_runner.zig`
- `tests/transform_fixture_runner.zig`

The refactor is strictly internal. It removes duplicated runner infrastructure without changing parser, codegen, or transform behavior.

## Motivation

The three fixture runners currently duplicate the same categories of logic:

- `std.process.Init` bootstrapping
- `std.Io` runtime access plumbing
- argument slicing
- candidate input-file probing
- fixture directory traversal
- base directory open/fail handling
- per-thread arena reuse patterns
- telemetry shell logic around run setup and progress reporting

This duplication already caused maintenance friction during the Zig `0.16.0` migration, where equivalent compatibility changes had to be applied and validated in three places. The cost will repeat for future runtime, filesystem, and telemetry-related changes unless the shared infrastructure is centralized.

## Goals

- Reduce duplicated fixture-runner infrastructure across the three test runners.
- Keep each runner focused on its own testing semantics.
- Preserve current CLI behavior, skip/pass/fail semantics, telemetry field names, and output shape.
- Make future maintenance tasks such as Zig stdlib migrations and test harness cleanup touch fewer files.

## Non-Goals

- No parser, codegen, transform, or AST behavior changes.
- No unification of runner-specific `evaluateOptions` or option-merging semantics.
- No telemetry schema changes.
- No CLI flag changes.
- No restructuring of `src/transform/pipeline.zig` or large transform source files.
- No conversion of the three runners into a generic framework.

## Current Problems

### Repeated bootstrap code

All three runners perform near-identical startup work:

- extract `alloc`, `io`, `arena`, and `environ` from `std.process.Init`
- convert `std.process.Args` into `[]const []const u8`
- initialize telemetry arguments
- keep a process-wide `std.Io` handle reachable by helper functions

### Repeated filesystem helpers

All three runners implement their own versions of:

- input file probing from ordered candidate filename lists
- recursive fixture discovery
- base directory open error handling

The transform runner also extends the same pattern rather than using a fundamentally different traversal model.

### Repeated runner shell structure

All three runners share the same outer execution pattern:

- discover fixtures
- spawn worker threads
- reuse per-thread arenas with `retain_with_limit`
- aggregate stats
- emit progress telemetry
- print a final summary

The differences are real, but they live above the shell layer, not inside it.

## Options Considered

### Option 1: Keep the runners separate and only document the duplication

This is the lowest-effort path, but it does not solve the maintenance problem. Every future stdlib or harness change would still require three edits and three reviews.

### Option 2: Extract only pure helper functions

This reduces some duplication, but leaves repeated bootstrap and shell scaffolding in place. It helps, but not enough to justify the churn.

### Option 3: Extract a narrow shared support module

This is the recommended option.

Create one shared support module for runner infrastructure only. Move obvious bootstrap, I/O, discovery, and worker-shell helpers into it while keeping all runner-specific semantics local. This provides meaningful payoff without introducing a new abstraction layer over the actual test logic.

## Proposed Design

Add one new module:

- `tests/fixture_runner_support.zig`

This module will expose small, explicit helpers rather than a generic “runner framework”.

### Shared responsibilities moved into the support module

#### 1. Runtime bootstrap helpers

- `argsToSlice`
- a small runtime context type carrying `allocator`, `io`, `arena`, and `environ`
- shared initialization for telemetry argument handling
- `std.Io` access helpers used by test-side filesystem code

This removes the current repeated `g_io` plus local wrapper pattern from each runner.

#### 2. Filesystem and fixture discovery helpers

- probe an ordered list of candidate input filenames and return the first readable file
- open a base fixture directory and print the standard “git submodule update --init” hint on failure
- recursively walk directories using `std.Io.Dir`
- simple file-presence helpers such as “has any of these filenames”

These helpers will stay generic and declarative. They should not contain parser/codegen/transform-specific rules.

#### 3. Shared runner shell helpers

- per-thread arena lifecycle helper
- common work-loop shell for fixture iteration where the runner supplies the fixture execution callback
- shared base stats fields for `pass`, `fail`, `skip`, and `err`
- progress logging helper that takes caller-provided cadence and log label

Runner-specific summary formatting stays in the runners.

## Responsibilities that remain inside each runner

The following logic stays local and is not abstracted:

- parser, codegen, and transform fixture semantics
- `OptionsResult` and `TransformOptions` types
- `checkOptions` and `evaluateOptions`
- AST comparison and diff printing
- transform-kind classification and per-kind counters
- skip policies, force-mode behavior, and plugin-specific fixture logic

This keeps the shared module mechanical and bounded.

## Module Shape

The support module should prefer small helpers over deep type hierarchies. A suitable shape is:

- `RuntimeContext`
- `argsToSlice(...)`
- `readFirstExistingFileAlloc(...)`
- `dirHasAnyFile(...)`
- `openFixtureBaseDirOrExit(...)`
- `walkFixtureDirs(...)`
- `runWorkerLoop(...)`
- `logProgress(...)`

The API should not attempt to model every runner difference. If a helper needs too many callbacks or mode switches to fit all three runners cleanly, it should remain runner-local.

## Migration Plan

### Phase 1: Create the support module with the lowest-risk helpers

Move only the most obviously duplicated pieces first:

- argument slicing
- runtime `io` access shell
- candidate input-file probing
- base-directory open helper
- recursive directory walk helpers

No result semantics change in this phase.

### Phase 2: Migrate the parser fixture runner

Update `tests/babel_fixture_runner.zig` to use the shared helpers while keeping parser option merging and AST comparison local.

Verification target:

- `zig build parse-test`

### Phase 3: Migrate the codegen fixture runner

Update `tests/codegen_fixture_runner.zig` to use the same helper layer while keeping generator-specific option evaluation and diff logic local.

Verification target:

- `zig build codegen-test`

### Phase 4: Migrate the transform fixture runner

Update `tests/transform_fixture_runner.zig` last, because it has the richest local semantics. Only the infrastructure layer moves.

Verification target:

- `zig build transform-test`

### Phase 5: Cross-check the full harness

After all three migrations:

- `zig build test`
- `zig build conformance-test`

## Verification Requirements

The refactor is only complete if all of the following remain true:

- existing runner CLI flags still behave the same
- existing skip counts do not change
- telemetry field names and summary formatting remain stable
- no new fixture categories are discovered or skipped
- parse/codegen/transform pass-fail behavior is unchanged

Required commands:

```bash
zig build parse-test
zig build codegen-test
zig build transform-test
zig build test
zig build conformance-test
```

## Risks and Controls

### Risk: Over-abstraction

If the support module tries to capture every runner difference, it will become another large, unclear layer.

Control:

Keep only mechanical shell logic shared. Leave semantic logic in the runners.

### Risk: Hidden behavior change during traversal refactor

Directory discovery and candidate file probing are easy to accidentally alter.

Control:

Migrate one runner at a time and verify with the runner’s full conformance command before proceeding.

### Risk: Transform runner pulls the shared module in the wrong direction

The transform runner is more complex than the others and could force awkward abstractions.

Control:

Treat transform as the final adopter. If a helper becomes transform-specific, stop abstracting and keep it local.

## Success Criteria

- `tests/babel_fixture_runner.zig`, `tests/codegen_fixture_runner.zig`, and `tests/transform_fixture_runner.zig` lose duplicated infrastructure code.
- A new shared support module exists under `tests/`.
- The three runners remain individually understandable and keep their current semantics.
- All required verification commands pass without changing skip/pass/fail totals.

## Deferred Work

This design deliberately does not tackle:

- refactoring `src/transform/pipeline.zig`
- splitting very large transform files such as `parameters.zig` or `ts_strip.zig`
- consolidating runner option-evaluation semantics

Those can be considered later once the runner infrastructure duplication is removed.
