# Agent Collaboration Docs Design

Date: 2026-04-18

## Summary

Add three long-lived agent-facing collaboration documents at the repository root:

- `context.md`
- `progress.md`
- `bugs.md`

Update `AGENTS.md` so it becomes the entry point for agent collaboration around those files.

The design is intentionally lightweight. It adds a stable document system for handoff and ongoing execution without turning the repository into a process-heavy workflow.

## Motivation

The repository already has strong task execution guidance in `AGENTS.md`, plus design and implementation documents under `docs/`. What it does not yet have is a small, explicit set of working documents that help an incoming agent answer four operational questions quickly:

- what this repository is and what constraints matter right now
- what the current work focus is
- which known defects are worth investigating
- what documents must be updated before handing work off

Without these boundaries, useful context tends to end up scattered across ad hoc task threads, stale notes, and commit history. That increases handoff cost and makes it easier for agents to duplicate investigation or miss important constraints.

## Goals

- Create a small set of agent-first collaboration documents with clear, non-overlapping responsibilities.
- Make `AGENTS.md` the single entry point that tells agents what to read and when to update it.
- Keep the document system cheap to maintain and fast to scan in a terminal.
- Improve handoff quality without changing the repository's existing engineering style.

## Non-Goals

- No attempt to replace design docs in `docs/specs/` or implementation plans in `docs/plans/`.
- No project-management layer such as milestones, owners, estimates, or status dashboards.
- No requirement to preserve a full historical log of all work.
- No frontmatter-heavy or template-heavy documentation system.

## Options Considered

### Option 1: Minimal attachment to existing `AGENTS.md`

Add the three files and only mention them briefly in `AGENTS.md`.

This is the lowest-churn option, but it leaves too much interpretation to each agent. Read order, update triggers, and file boundaries would remain implicit.

### Option 2: Central index model

Make `AGENTS.md` the collaboration entry point and define:

- read order
- document boundaries
- update triggers
- handoff expectations

Then keep the three new files narrowly scoped:

- `context.md` for stable background
- `progress.md` for the active work surface
- `bugs.md` for actionable known defects

This is the recommended option because it gives enough structure to be reliable without making the workflow heavy.

### Option 3: Full runbook model

Rewrite `AGENTS.md` into a larger process manual with strict templates and more elaborate ceremony around documentation updates.

This would maximize consistency, but it is heavier than the repository needs and does not match the current preference for concise, surgical guidance.

## Recommended Design

Adopt Option 2.

The document system should have one control document and three working documents:

- `AGENTS.md`: collaboration rules and read order
- `context.md`: stable project context
- `progress.md`: current execution state
- `bugs.md`: actionable defect backlog

This keeps facts, status, defects, and workflow rules separate. An agent can scan the right file for the right question instead of reconstructing context from mixed notes.

## File Responsibilities

### `AGENTS.md`

`AGENTS.md` becomes the collaboration entry point. It should answer:

- how to work in this repository
- which documents to read first
- when each document must be updated
- what a handoff must include

It should not become the storage place for fast-changing project facts or issue lists.

### `context.md`

`context.md` stores long-lived background that should remain useful across multiple tasks and handoffs. It should answer:

- what the repository does
- what major constraints shape the work
- which commands and subsystems matter
- which architectural boundaries are already accepted

It should not contain daily progress notes or bug triage.

### `progress.md`

`progress.md` stores the active work surface. It should answer:

- what is being worked on now
- what was completed recently
- what is most likely to happen next
- what the latest important verification result was

It is expected to change frequently and should be overwritten as reality changes instead of accumulating a long journal.

### `bugs.md`

`bugs.md` stores known defects that are concrete enough to support future reproduction, investigation, or validation. It should answer:

- what is broken
- how it manifests
- what area is likely involved
- how someone can verify a fix

It should not be used for vague worries, general technical debt, or unformed ideas.

## Read Order

The default read order for an incoming agent should be:

1. `AGENTS.md`
2. `context.md`
3. `progress.md`
4. `bugs.md` only if the task is bug-related or current progress points there

This order ensures that an agent first learns the workflow, then the stable repository frame, then the current execution state, and only then the defect inventory when relevant.

## Boundary Rules

The boundary rules should be explicit and strict:

- workflow rules belong in `AGENTS.md`
- stable facts belong in `context.md`
- short-horizon execution state belongs in `progress.md`
- concrete defects belong in `bugs.md`

Examples:

- a toolchain version change belongs in `context.md`
- a new current priority belongs in `progress.md`
- a reproducible parser mismatch belongs in `bugs.md`
- a rule about when to update docs belongs in `AGENTS.md`

These boundaries are necessary to prevent the documents from collapsing into one another.

## Recommended File Structure

### `context.md`

Recommended sections:

- `Purpose`
- `Current Reality`
- `Key Areas`
- `Operational Constraints`
- `Open Context Gaps`

This file should stay concise and relatively stable.

### `progress.md`

Recommended sections:

- `Current Focus`
- `Recent Completed`
- `Next Likely Steps`
- `Verification Snapshot`

This file should optimize for fast takeover, not historical completeness.

### `bugs.md`

Each bug entry should use a compact, repeated structure:

- `Title`
- `Status`
- `Impact`
- `Reproduction`
- `Expected`
- `Actual`
- `Scope / Suspected Area`
- `Verification`

This keeps the file actionable in a terminal and makes it easier to sort bugs by readiness.

## Maintenance Rules

### When to update `context.md`

Update only when long-lived facts change, for example:

- toolchain or environment expectations
- core commands
- important directory responsibilities
- accepted architecture boundaries
- lasting repository constraints

Do not update this file just because a task was completed.

### When to update `progress.md`

Update when:

- a non-trivial task is completed
- the active priority changes
- the likely next step changes
- a meaningful verification result should be handed to the next agent

This file should prefer replacement over accumulation.

### When to update `bugs.md`

Update when:

- a new reproducible defect is found
- reproduction details or suspected scope materially improve
- status changes from `open` to `investigating`, `blocked`, or `fixed`

Do not add entries that cannot yet be described as a concrete behavioral problem.

### When to update `AGENTS.md`

Update when:

- collaboration workflow changes
- document read order changes
- document boundaries change
- handoff requirements change

Do not add unstable project facts here.

## Handoff Rules

`AGENTS.md` should instruct agents to leave the repository in a state that the next agent can pick up quickly.

A non-trivial handoff should usually include:

- refreshed `progress.md`
- any new reproducible issue added to or updated in `bugs.md`
- `context.md` updates only when long-lived facts changed

This is intentionally lighter than a full session log. The standard is not completeness; it is decision-useful continuity.

## Style Rules

The new documents should follow these style rules:

- plain Markdown
- short headings
- short bullet lists
- terminal-friendly formatting
- agent-first wording
- overwrite stale state instead of stacking long logs

Do not require frontmatter, tables, or process-specific metadata unless future experience proves they are necessary.

## Risks and Controls

### Risk: Document drift

The files may become stale if updates are treated as optional.

Control:

Put update triggers and handoff expectations in `AGENTS.md`, not in informal convention.

### Risk: Overlap between files

Agents may put the same information in multiple places.

Control:

Define the file boundaries explicitly and keep each file focused on one type of information.

### Risk: Process bloat

The documentation system could grow into ceremony that slows normal engineering work.

Control:

Keep the structure small, avoid historical logging, and write only information that changes the next agent's decisions.

## Verification

This design is successful if, after implementation:

- an incoming agent can determine what to read first without guessing
- stable context no longer competes with daily progress updates
- known defects can be scanned without reading unrelated status notes
- a completed non-trivial task leaves a clearer handoff trail than before

## Out of Scope for This Design

This design does not specify:

- the exact initial contents of `context.md`, `progress.md`, or `bugs.md`
- any automation that keeps the files synchronized
- any implementation details beyond the document structure and maintenance rules

Those belong in the implementation planning and execution phases.
