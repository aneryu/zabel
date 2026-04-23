# AGENTS.md

## Default Stance

- Bias toward correctness, small diffs, and verifiable outcomes over speed.
- State assumptions explicitly when they affect correctness.
- Prefer the simplest change that solves the stated problem.
- Touch only code directly related to the request.
- Use repository commands and fixtures to prove behavior instead of subjective checks.

For bug work, reproduce first when practical, then make the failing check pass.

## Workflow

For non-trivial work:

1. Read `AGENTS.md`.
2. Read `context.md` for durable repo facts, environment, and command surfaces.
3. Read `progress.md` for the current handoff state.
4. Read `bugs.md` only for bug work or when `progress.md` points to a known defect.
5. Define concrete verification targets before editing.
6. Write a short check-driven plan.
7. Make the smallest change that satisfies the verification targets.
8. Refresh the collaboration docs before handoff if the task changed durable state.

Example plan:

```text
1. Update parser branch -> verify: targeted parse-test fixture
2. Adjust codegen formatting -> verify: targeted codegen-test fixture
3. Re-run cross-cutting checks -> verify: conformance-test or relevant full runners
```

For trivial tasks, use judgment but keep the same bias toward minimal, verifiable changes.

## Verification Discipline

- Define the check surface before editing so scope stays honest.
- Start with the smallest relevant targeted command, then widen only as needed.
- Prefer repository runners and fixtures over ad hoc inspection.
- Run `zig fmt` on any Zig files you touch.

## Validation By Change Type

### Parser

- Start with the smallest relevant `parse-test -- <fixture> --diff`.
- Rerun full `parse-test`.
- Also run `codegen-test` and `transform-test` if parse shape affects emission or transforms.
- Common parser-sensitive areas: `no_in`, contextual keywords, plugin-gated syntax, comment attachment.

### Codegen

- Start with a targeted `codegen-test -- --diff <fixture>`.
- Rerun `transform-test` after comment, whitespace, or parenthesization changes.
- Common codegen-sensitive areas: loop-head parenthesization, comment/blank-line preservation, escaped keywords, TS/Flow emission.

### Transform

- Start with the targeted `transform-test` fixture.
- Rerun `codegen-test` if syntax shape or comments change.
- Review `src/scope.zig` and `pipeline.needs_scope` when the pass depends on binding or scope semantics.

### Performance

- Benchmark with `scripts/bench-transform.sh`, `scripts/bench-compare.sh`, or `scripts/bench-real-projects.sh` as appropriate.
- Compare cumulative stage deltas, not only full-pipeline totals.
- Re-run `zig build test` and the relevant conformance runners.
- Do not leave benchmark-only debug helpers or temporary build steps in the tree.

## Collaboration Docs

Boundaries:

- `AGENTS.md`: workflow rules, verification expectations, and doc-maintenance requirements.
- `context.md`: long-lived repository facts, environment, important paths, and stable infrastructure notes.
- `progress.md`: current focus, recently completed work, likely next steps, and recent verification state.
- `bugs.md`: concrete, reproducible defects with enough detail to re-check them later.

Rules:

- Update `context.md` only when long-lived facts change.
- Update `progress.md` after non-trivial work, priority changes, or meaningful verification worth handing off.
- Update `bugs.md` when a reproducible defect is found or materially changes.
- Update `AGENTS.md` only when the collaboration workflow or document boundaries change.
- Prefer replacing stale state over appending session logs.

Before handoff on non-trivial work:

1. Refresh `progress.md`.
2. Update `bugs.md` for newly confirmed or materially changed defects.
3. Update `context.md` only if the task changed a long-lived fact.

## Never

- Do not edit `vendor/babel` fixtures unless the task is explicitly about vendored updates.
- Do not weaken conformance runners to hide regressions unless the behavior is intentionally out of scope and documented.
- Do not leave temporary debug executables, bespoke build steps, or fixture-specific hacks in the repo.
- Do not claim transform performance wins without correctness and benchmark validation.
