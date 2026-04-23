# Real-Project Transform Throughput Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible real-project benchmark surface for `react-native` and `antd`, then use it to land the first shared-analysis and plan-driven transform architecture steps without relaxing conformance.

**Architecture:** Keep the existing synthetic benchmark flow intact, add a separate real-project corpus and batch benchmark path, and only then thread a shared `TransformSession` plus rewrite-plan primitives into the transform pipeline. Land the engine work incrementally: shared analysis first, then `parameters`, then `block_scoping`, while preserving logical stage attribution and existing conformance runners.

**Tech Stack:** Zig 0.16, existing `zig build` test runners, Bash benchmark wrappers, Node.js scripts for Babel comparison and package-corpus preparation

---

## File Map

### New Files

- `bench/corpus.lock.json`
  Records pinned package metadata, extraction roots, tier membership, and the exact benchmark file list for `react-native` and `antd`.
- `scripts/prepare_real_bench_corpus.cjs`
  Downloads or reuses pinned package tarballs, extracts them into `.zig-cache/bench/corpus`, validates the checked-in file list, and writes tier-specific file lists for the runners.
- `scripts/prepare_real_bench_corpus_test.cjs`
  Node tests for lock parsing, file filtering, and tier file-list emission without requiring network access.
- `scripts/bench-real-projects.sh`
  End-to-end entry point for preparing the corpus, compiling the Zig runner, invoking Zig and Babel batch modes, and printing aggregate plus top-file summaries.
- `src/bench/real_project_bench.zig`
  Shared Zig helpers for batch file loading, per-file result rows, aggregation, percentile calculation, and machine-readable output formatting.
- `tests/real_project_bench_test.zig`
  Unit tests for row aggregation, percentile math, size accounting, and stage-summary ordering.
- `src/transform/session.zig`
  Shared per-file structural analysis surface for parent lookup, subtree ranges, function boundaries, capture boundaries, and identifier occurrences.
- `tests/transform_session_test.zig`
  Unit tests for `TransformSession` indexing invariants on parser output.
- `src/transform/rewrite_plan.zig`
  Shared rewrite-plan representation and ordered replacement application helpers.
- `tests/rewrite_plan_test.zig`
  Unit tests for replacement ordering, overlap rejection, and indentation metadata propagation.

### Modified Files

- `build.zig`
  Registers new Zig test files and keeps existing top-level steps stable.
- `src/root.zig`
  Re-exports new benchmark and transform helper modules needed by scripts or tests.
- `scripts/transform_bench.zig`
  Adds batch benchmark modes for file lists and emits per-file plus aggregate rows using `src/bench/real_project_bench.zig`.
- `scripts/babel_transform_bench.cjs`
  Adds matching batch modes so Zig and Babel report the same file-level and aggregate fields.
- `scripts/bench-compare.sh`
  Stays synthetic-focused but should share formatting helpers with the new real-project benchmark script where practical.
- `src/transform/pipeline.zig`
  Threads `TransformSession` and `RewritePlan` support through pipeline execution while preserving existing stage stats.
- `src/transform/parameters.zig`
  Migrates body-rewrite planning to the shared rewrite-plan path and consumes shared session analysis.
- `src/transform/block_scoping.zig`
  Reuses shared session indices and shared rewrite-plan application for rename and loop-lowering edits.
- `src/transform/arrow_functions.zig`
  Consumes shared session analysis where it overlaps with function-boundary and capture queries.
- `tests/transform_pipeline_stats_test.zig`
  Extends stage-stat assertions to cover the new batch and shared-analysis plumbing.
- `tests/parameters_transform_test.zig`
  Adds regression coverage for rewrite-plan-based `parameters` lowering.
- `tests/block_scoping_transform_test.zig`
  Adds regression coverage for rewrite-plan-based `block_scoping` edits.
- `tests/arrow_functions_transform_test.zig`
  Adds coverage that proves shared session data does not change arrow lowering behavior.
- `progress.md`
  Refreshes handoff state after each implemented milestone.
- `context.md`
  Updates long-lived repository facts once the real-project benchmark workflow is part of normal repo usage.

## Verification Ladder

Use this same ladder throughout implementation:

1. Focused unit or fixture test for the task being changed
2. `zig build test`
3. `zig build transform-test -- --diff <fixture>` for the touched transform pass
4. `zig build conformance-test` when shared transform infrastructure changes
5. `bash scripts/bench-real-projects.sh --tier core`

Keep the existing synthetic benchmark commands available for sanity checks, but the real-project `core` tier is the acceptance metric.

### Task 1: Lock The Real-Project Corpus

**Files:**
- Create: `bench/corpus.lock.json`
- Create: `scripts/prepare_real_bench_corpus.cjs`
- Test: `scripts/prepare_real_bench_corpus_test.cjs`

- [ ] **Step 1: Write the failing corpus-lock test**

```js
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");
const { loadCorpusLock, buildTierFileList } = require("./prepare_real_bench_corpus.cjs");

test("buildTierFileList keeps only checked-in files for the requested tier", async () => {
  const lock = await loadCorpusLock(path.join(__dirname, "../bench/corpus.lock.json"));
  const rows = buildTierFileList(lock, "core");

  assert.ok(rows.length > 0);
  assert.ok(rows.every(row => row.tiers.includes("core")));
  assert.ok(rows.some(row => row.project === "react-native"));
  assert.ok(rows.some(row => row.project === "antd"));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`
Expected: FAIL with `Cannot find module './prepare_real_bench_corpus.cjs'` or missing `bench/corpus.lock.json`

- [ ] **Step 3: Write the lock file and minimal loader**

```json
{
  "packages": [
    {
      "project": "react-native",
      "version": "0.76.1",
      "tarball": "https://registry.npmjs.org/react-native/-/react-native-0.76.1.tgz",
      "root": "package",
      "files": [
        { "path": "Libraries/Animated/src/AnimatedImplementation.js", "tiers": ["smoke", "core", "full"] },
        { "path": "Libraries/Renderer/implementations/ReactFabric-dev.js", "tiers": ["full"] }
      ]
    },
    {
      "project": "antd",
      "version": "5.21.6",
      "tarball": "https://registry.npmjs.org/antd/-/antd-5.21.6.tgz",
      "root": "package",
      "files": [
        { "path": "es/form/Form.js", "tiers": ["smoke", "core", "full"] },
        { "path": "es/table/InternalTable.js", "tiers": ["core", "full"] }
      ]
    }
  ]
}
```

```js
function loadCorpusLock(lockPath) {
  const raw = fs.readFileSync(lockPath, "utf8");
  return JSON.parse(raw);
}

function buildTierFileList(lock, tier) {
  return lock.packages.flatMap(pkg =>
    pkg.files
      .filter(file => file.tiers.includes(tier))
      .map(file => ({
        project: pkg.project,
        version: pkg.version,
        root: pkg.root,
        path: file.path,
        tiers: file.tiers,
      })),
  );
}

module.exports = { loadCorpusLock, buildTierFileList };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`
Expected: PASS with one passing test for tier selection and no network access

- [ ] **Step 5: Commit**

```bash
git add bench/corpus.lock.json scripts/prepare_real_bench_corpus.cjs scripts/prepare_real_bench_corpus_test.cjs
git commit -m "bench: add pinned real-project corpus lock"
```

### Task 2: Prepare The Corpus Into A Stable Cache Layout

**Files:**
- Modify: `scripts/prepare_real_bench_corpus.cjs`
- Test: `scripts/prepare_real_bench_corpus_test.cjs`

- [ ] **Step 1: Write the failing preparation test**

```js
test("prepareCorpus writes tier file lists under .zig-cache/bench/corpus", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-corpus-"));
  const result = await prepareCorpus({
    repoRoot: tmp,
    lockPath: path.join(tmp, "bench/corpus.lock.json"),
    tier: "smoke",
    offline: true,
  });

  assert.equal(result.tier, "smoke");
  assert.ok(fs.existsSync(path.join(tmp, ".zig-cache/bench/corpus/smoke.txt")));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`
Expected: FAIL with `prepareCorpus is not a function`

- [ ] **Step 3: Implement cache preparation and file-list emission**

```js
async function prepareCorpus({ repoRoot, lockPath, tier, offline = false }) {
  const lock = loadCorpusLock(lockPath);
  const rows = buildTierFileList(lock, tier);
  const baseDir = path.join(repoRoot, ".zig-cache/bench/corpus");
  const extractedDir = path.join(baseDir, "src");
  const listPath = path.join(baseDir, `${tier}.txt`);

  await fs.promises.mkdir(extractedDir, { recursive: true });
  for (const pkg of lock.packages) {
    const packageDir = path.join(extractedDir, `${pkg.project}@${pkg.version}`);
    await fs.promises.mkdir(packageDir, { recursive: true });
    if (!offline) {
      await ensurePackageExtracted(pkg, packageDir);
    }
  }

  const lines = rows.map(row =>
    `${row.project}\t${row.version}\t${path.join(extractedDir, `${row.project}@${row.version}`, row.root, row.path)}`
  );
  await fs.promises.writeFile(listPath, `${lines.join("\n")}\n`);
  return { tier, listPath, files: rows.length };
}

module.exports = { loadCorpusLock, buildTierFileList, prepareCorpus };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`
Expected: PASS with the new cache-layout assertion and existing tier-selection test

- [ ] **Step 5: Commit**

```bash
git add scripts/prepare_real_bench_corpus.cjs scripts/prepare_real_bench_corpus_test.cjs
git commit -m "bench: add corpus preparation cache layout"
```

### Task 3: Add Zig Batch Benchmark Primitives

**Files:**
- Create: `src/bench/real_project_bench.zig`
- Create: `tests/real_project_bench_test.zig`
- Modify: `build.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing Zig aggregation test**

```zig
const std = @import("std");
const zb = @import("zig_babal");

test "aggregateRows computes totals and p95 from file rows" {
    const rows = [_]zb.RealProjectBench.FileRow{
        .{ .project = "react-native", .path = "a.js", .bytes = 100, .parse_ns = 10, .transform_ns = 20, .codegen_ns = 5, .total_ns = 35 },
        .{ .project = "antd", .path = "b.js", .bytes = 300, .parse_ns = 30, .transform_ns = 40, .codegen_ns = 10, .total_ns = 80 },
    };

    const summary = try zb.RealProjectBench.aggregateRows(std.testing.allocator, &rows);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 115), summary.total_ns);
    try std.testing.expectEqual(@as(u64, 400), summary.total_bytes);
    try std.testing.expect(summary.p95_total_ns >= 80);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `zb.RealProjectBench` is not exported and `tests/real_project_bench_test.zig` is not registered

- [ ] **Step 3: Implement batch-row types and aggregation**

```zig
pub const FileRow = struct {
    project: []const u8,
    path: []const u8,
    bytes: u64,
    parse_ns: u64,
    transform_ns: u64,
    codegen_ns: u64,
    total_ns: u64,
};

pub const Summary = struct {
    total_ns: u64,
    total_bytes: u64,
    p50_total_ns: u64,
    p95_total_ns: u64,
    rows: []FileRow,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        self.* = undefined;
    }
};

pub fn aggregateRows(allocator: std.mem.Allocator, input: []const FileRow) !Summary {
    var rows = try allocator.dupe(FileRow, input);
    var total_ns: u64 = 0;
    var total_bytes: u64 = 0;
    std.mem.sort(FileRow, rows, {}, struct {
        fn lessThan(_: void, a: FileRow, b: FileRow) bool {
            return a.total_ns < b.total_ns;
        }
    }.lessThan);
    for (rows) |row| {
        total_ns += row.total_ns;
        total_bytes += row.bytes;
    }
    return .{
        .total_ns = total_ns,
        .total_bytes = total_bytes,
        .p50_total_ns = rows[(rows.len - 1) / 2].total_ns,
        .p95_total_ns = rows[(rows.len * 95 + 99) / 100 - 1].total_ns,
        .rows = rows,
    };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS with `tests/real_project_bench_test.zig` included in the build and the new aggregation test green

- [ ] **Step 5: Commit**

```bash
git add src/bench/real_project_bench.zig tests/real_project_bench_test.zig build.zig src/root.zig
git commit -m "bench: add real-project row aggregation"
```

### Task 4: Teach The Zig Runner To Process File Lists

**Files:**
- Modify: `scripts/transform_bench.zig`
- Modify: `src/bench/real_project_bench.zig`
- Test: `tests/real_project_bench_test.zig`

- [ ] **Step 1: Write the failing batch-output test**

```zig
test "formatBatchRow emits machine-readable file rows" {
    const row = zb.RealProjectBench.FileRow{
        .project = "antd",
        .path = "es/form/Form.js",
        .bytes = 1234,
        .parse_ns = 10,
        .transform_ns = 20,
        .codegen_ns = 5,
        .total_ns = 35,
    };

    const line = try zb.RealProjectBench.formatBatchRow(std.testing.allocator, row);
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "file\tantd\tes/form/Form.js") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `formatBatchRow` and batch list processing do not exist

- [ ] **Step 3: Add a `files` mode to the Zig benchmark runner**

```zig
if (std.mem.eql(u8, mode, "files")) {
    if (filtered.items.len != 4) return error.InvalidArgs;
    const tier = filtered.items[1];
    const list_path = filtered.items[2];
    const iterations = try std.fmt.parseInt(usize, filtered.items[3], 10);
    try benchFiles(allocator, io, tier, list_path, iterations, if (telemetry_session) |*session| session else null, spanPtr(&run_span));
    return;
}
```

```zig
pub fn formatBatchRow(allocator: std.mem.Allocator, row: FileRow) ![]u8 {
    return std.fmt.allocPrint(allocator, "file\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}", .{
        row.project,
        row.path,
        row.bytes,
        row.parse_ns,
        row.transform_ns,
        row.codegen_ns,
        row.total_ns,
    });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS with the new batch-row formatter test and no regressions in `tests/transform_pipeline_stats_test.zig`

- [ ] **Step 5: Commit**

```bash
git add scripts/transform_bench.zig src/bench/real_project_bench.zig tests/real_project_bench_test.zig
git commit -m "bench: add zig batch file-list mode"
```

### Task 5: Add Matching Babel Batch Mode And Real-Project Driver

**Files:**
- Modify: `scripts/babel_transform_bench.cjs`
- Create: `scripts/bench-real-projects.sh`
- Test: `scripts/prepare_real_bench_corpus_test.cjs`

- [ ] **Step 1: Write the failing Babel batch smoke test**

```js
test("babel batch mode prints one file row per input line", async () => {
  const inputList = path.join(fixturesDir, "smoke.txt");
  const { stdout, status } = spawnSync("node", ["scripts/babel_transform_bench.cjs", "files", "smoke", inputList, "1"], {
    cwd: repoRoot,
    encoding: "utf8",
  });

  assert.equal(status, 0);
  assert.match(stdout, /^file\t/sm);
  assert.match(stdout, /^summary\t/sm);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`
Expected: FAIL because `babel_transform_bench.cjs` does not support `files`

- [ ] **Step 3: Implement Babel batch mode and the shell entry point**

```js
if (mode === "files") {
  const [tier, listPath, iterationsRaw] = rest;
  benchFiles(tier, fs.readFileSync(listPath, "utf8"), Number(iterationsRaw));
  return;
}

function benchFiles(tier, listSource, iterations) {
  const rows = parseFileList(listSource);
  for (const row of rows) {
    const source = fs.readFileSync(row.absolutePath, "utf8");
    const result = benchOneFile(row.project, row.relativePath, source, iterations);
    process.stdout.write(`file\t${result.project}\t${result.path}\t${result.bytes}\t${result.parseNs}\t${result.transformNs}\t${result.codegenNs}\t${result.totalNs}\n`);
  }
}
```

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIER="${1:-core}"
node "$ROOT/scripts/prepare_real_bench_corpus.cjs" --tier "$TIER"
zig build-exe --dep zig_babal -Mroot="$ROOT/scripts/transform_bench.zig" -Mzig_babal="$ROOT/src/root.zig" -O ReleaseFast -femit-bin="$ROOT/.zig-cache/bench/transform_bench"
"$ROOT/.zig-cache/bench/transform_bench" files "$TIER" "$ROOT/.zig-cache/bench/corpus/${TIER}.txt" 1 > "$ROOT/.zig-cache/bench/${TIER}-zig.tsv"
node "$ROOT/scripts/babel_transform_bench.cjs" files "$TIER" "$ROOT/.zig-cache/bench/corpus/${TIER}.txt" 1 > "$ROOT/.zig-cache/bench/${TIER}-babel.tsv"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`
Expected: PASS with the new Babel batch smoke test and the existing corpus-preparation tests

- [ ] **Step 5: Commit**

```bash
git add scripts/babel_transform_bench.cjs scripts/bench-real-projects.sh scripts/prepare_real_bench_corpus_test.cjs
git commit -m "bench: add real-project zig and babel driver"
```

### Task 6: Add Aggregate Reporting For Project, File, And Phase Views

**Files:**
- Modify: `src/bench/real_project_bench.zig`
- Modify: `scripts/bench-real-projects.sh`
- Test: `tests/real_project_bench_test.zig`

- [ ] **Step 1: Write the failing summary test**

```zig
test "renderSummary includes per-project totals and p95" {
    const rows = [_]zb.RealProjectBench.FileRow{
        .{ .project = "react-native", .path = "a.js", .bytes = 100, .parse_ns = 10, .transform_ns = 20, .codegen_ns = 5, .total_ns = 35 },
        .{ .project = "antd", .path = "b.js", .bytes = 200, .parse_ns = 15, .transform_ns = 25, .codegen_ns = 5, .total_ns = 45 },
    };

    const output = try zb.RealProjectBench.renderSummary(std.testing.allocator, &rows);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "project\treact-native") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "p95_total_ns") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `renderSummary` does not exist

- [ ] **Step 3: Implement aggregate and top-file rendering**

```zig
pub fn renderSummary(allocator: std.mem.Allocator, rows: []const FileRow) ![]u8 {
    var out = std.ArrayList(u8).empty;
    const summary = try aggregateRows(allocator, rows);
    defer summary.deinit(allocator);
    try out.writer(allocator).print("summary\tfiles\t{d}\ttotal_ns\t{d}\tp95_total_ns\t{d}\n", .{
        rows.len,
        summary.total_ns,
        summary.p95_total_ns,
    });
    for (projectSummaries(rows)) |project| {
        try out.writer(allocator).print("project\t{s}\tfiles\t{d}\ttotal_ns\t{d}\n", .{
            project.name,
            project.file_count,
            project.total_ns,
        });
    }
    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS with the new summary-rendering test and stable existing benchmark helper tests

- [ ] **Step 5: Commit**

```bash
git add src/bench/real_project_bench.zig tests/real_project_bench_test.zig scripts/bench-real-projects.sh
git commit -m "bench: add aggregate real-project reporting"
```

### Task 7: Introduce TransformSession Parent And Range Indices

**Files:**
- Create: `src/transform/session.zig`
- Create: `tests/transform_session_test.zig`
- Modify: `build.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing session-index test**

```zig
const std = @import("std");
const zb = @import("zig_babal");

test "transform session computes parent and subtree ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var parsed = try zb.parseWithOptions(alloc,
        \\function outer(a = 1) {
        \\  const inner = () => a + 1;
        \\  return inner();
        \\}
    , .{ .source_type = .script, .language = .typescript, .defer_comment_attachment = true });

    var session = try zb.TransformSession.init(alloc, &parsed.ast, null);
    defer session.deinit(alloc);

    const outer_fn = parsed.ast.rootDecls()[0];
    try std.testing.expect(session.parentOf(outer_fn) != null);
    try std.testing.expect(session.subtreeRange(outer_fn).start <= session.subtreeRange(outer_fn).end);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `TransformSession` does not exist

- [ ] **Step 3: Implement the shared session skeleton**

```zig
pub const TransformSession = struct {
    ast: *Ast,
    parent_map: []NodeIndex,
    preorder_start: []u32,
    preorder_end: []u32,

    pub fn init(allocator: Allocator, ast: *Ast, scope: ?*scope_mod.ScopeResult) !TransformSession {
        _ = scope;
        var session = TransformSession{
            .ast = ast,
            .parent_map = try allocator.alloc(NodeIndex, ast.nodes.len),
            .preorder_start = try allocator.alloc(u32, ast.nodes.len),
            .preorder_end = try allocator.alloc(u32, ast.nodes.len),
        };
        try session.buildParentAndRanges(allocator);
        return session;
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS with `tests/transform_session_test.zig` added and the new parent/range assertions green

- [ ] **Step 5: Commit**

```bash
git add src/transform/session.zig tests/transform_session_test.zig build.zig src/root.zig
git commit -m "transform: add shared session parent and range indices"
```

### Task 8: Add Function-Boundary And Identifier-Occurrence Session Data

**Files:**
- Modify: `src/transform/session.zig`
- Test: `tests/transform_session_test.zig`
- Modify: `src/transform/pipeline.zig`

- [ ] **Step 1: Write the failing occurrence test**

```zig
test "transform session indexes identifier occurrences by spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var parsed = try zb.parseWithOptions(alloc,
        \\function outer(value) {
        \\  return () => value + value;
        \\}
    , .{ .source_type = .script, .language = .typescript, .defer_comment_attachment = true });

    var session = try zb.TransformSession.init(alloc, &parsed.ast, null);
    defer session.deinit(alloc);

    const occurrences = session.identifierOccurrences("value") orelse return error.ExpectedOccurrences;
    try std.testing.expect(occurrences.len >= 3);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because occurrence indexing and function-boundary metadata are missing

- [ ] **Step 3: Implement shared occurrence and boundary indexing**

```zig
pub const IdentifierOccurrence = struct {
    node: NodeIndex,
    function_boundary: ?NodeIndex,
};

identifier_occurrences: std.StringHashMapUnmanaged([]IdentifierOccurrence) = .empty,
function_boundary_for_node: []NodeIndex,

pub fn identifierOccurrences(self: *const TransformSession, name: []const u8) ?[]const IdentifierOccurrence {
    return self.identifier_occurrences.get(name);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS with the new occurrence test and no regression in `tests/transform_pipeline_stats_test.zig`

- [ ] **Step 5: Commit**

```bash
git add src/transform/session.zig tests/transform_session_test.zig src/transform/pipeline.zig
git commit -m "transform: index shared function boundaries and occurrences"
```

### Task 9: Thread TransformSession Through The Pipeline Without Changing Behavior

**Files:**
- Modify: `src/transform/pipeline.zig`
- Modify: `tests/transform_pipeline_stats_test.zig`
- Test: `tests/arrow_functions_transform_test.zig`

- [ ] **Step 1: Write the failing pipeline-session test**

```zig
test "pipeline exposes a shared transform session during pass execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var parsed = try zb.parseWithOptions(alloc, "const fn1 = (a = 1) => a;", .{
        .source_type = .script,
        .language = .typescript,
        .defer_comment_attachment = true,
    });
    defer parsed.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();
    pipeline.needs_scope = true;
    try pipeline.addPass(zb.ArrowFunctions.createPass(.{}));
    try pipeline.run(&parsed.ast);

    const stats = pipeline.lastRunStats() orelse return error.ExpectedStats;
    try std.testing.expect(stats.scope_analysis_ns != null);
    try std.testing.expect(pipeline.lastTransformSession() != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because the pipeline does not retain or expose a session

- [ ] **Step 3: Create and thread the session in `Pipeline.run`**

```zig
var transform_session: ?session_mod.TransformSession = null;
defer if (transform_session) |*value| value.deinit(self.allocator);

if (self.needs_scope or self.requires_transform_session) {
    transform_session = try session_mod.TransformSession.init(self.allocator, ast, if (scope_result) |*s| s else null);
}

var ctx = TransformContext{
    .ast = ast,
    .allocator = self.allocator,
    .scope = if (scope_result) |*s| s else null,
    .session = if (transform_session) |*s| s else null,
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS with the new pipeline-session assertion and unchanged transform fixture output

- [ ] **Step 5: Commit**

```bash
git add src/transform/pipeline.zig tests/transform_pipeline_stats_test.zig tests/arrow_functions_transform_test.zig
git commit -m "transform: thread shared session through pipeline"
```

### Task 10: Add RewritePlan Ordering And Overlap Tests

**Files:**
- Create: `src/transform/rewrite_plan.zig`
- Create: `tests/rewrite_plan_test.zig`
- Modify: `build.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Write the failing rewrite-plan test**

```zig
const std = @import("std");
const zb = @import("zig_babal");

test "rewrite plan sorts replacements by source order and rejects overlap" {
    var plan = zb.RewritePlan.init(std.testing.allocator);
    defer plan.deinit();

    try plan.add(.{ .start = 20, .end = 25, .text = "second", .needs_reindent = false });
    try plan.add(.{ .start = 10, .end = 15, .text = "first", .needs_reindent = true });
    try std.testing.expectError(error.OverlappingReplacement, plan.add(.{ .start = 12, .end = 14, .text = "bad", .needs_reindent = false }));

    const ordered = try plan.ordered(std.testing.allocator);
    defer std.testing.allocator.free(ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expectEqual(@as(u32, 10), ordered[0].start);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL because `RewritePlan` does not exist

- [ ] **Step 3: Implement the shared rewrite-plan container**

```zig
pub const Replacement = struct {
    start: u32,
    end: u32,
    text: []const u8,
    needs_reindent: bool,
};

pub const RewritePlan = struct {
    allocator: std.mem.Allocator,
    replacements: std.ArrayListUnmanaged(Replacement) = .empty,

    pub fn add(self: *RewritePlan, replacement: Replacement) !void {
        for (self.replacements.items) |existing| {
            if (!(replacement.end <= existing.start or replacement.start >= existing.end)) {
                return error.OverlappingReplacement;
            }
        }
        try self.replacements.append(self.allocator, replacement);
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS with `tests/rewrite_plan_test.zig` registered and the overlap-ordering assertions green

- [ ] **Step 5: Commit**

```bash
git add src/transform/rewrite_plan.zig tests/rewrite_plan_test.zig build.zig src/root.zig
git commit -m "transform: add shared rewrite plan"
```

### Task 11: Migrate Parameters To RewritePlan

**Files:**
- Modify: `src/transform/parameters.zig`
- Modify: `src/transform/pipeline.zig`
- Test: `tests/parameters_transform_test.zig`

- [ ] **Step 1: Write the failing `parameters` regression**

```zig
test "parameters uses rewrite plan for default and rest lowering" {
    try expectTransform(
        \\function demo(a = seed(), ...rest) {
        \\  return (() => rest.length + a)();
        \\}
    ,
        \\function demo() {
        \\  var a = arguments.length > 0 && arguments[0] !== undefined ? arguments[0] : seed();
        \\  for (var _len = arguments.length, rest = Array(_len > 1 ? _len - 1 : 0), _key = 1; _key < _len; _key++) {
        \\    rest[_key - 1] = arguments[_key];
        \\  }
        \\  return function () {
        \\    return rest.length + a;
        \\  }();
        \\}
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build transform-test -- --diff parameters`
Expected: FAIL once the test is added because `parameters` still writes directly through its legacy replacement path

- [ ] **Step 3: Replace direct replacement emission with shared plan construction**

```zig
var plan = rewrite_plan.RewritePlan.init(gpa);
defer plan.deinit();

try plan.add(.{
    .start = function_start,
    .end = function_end,
    .text = try self.renderLoweredFunction(ctx, fn_node, analysis),
    .needs_reindent = true,
});

try rewrite_plan.applyPlan(ctx.ast, &plan, .{ .allocator = gpa });
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build transform-test -- --diff parameters`
Expected: PASS for the new regression and existing `parameters` fixtures

- [ ] **Step 5: Commit**

```bash
git add src/transform/parameters.zig src/transform/pipeline.zig tests/parameters_transform_test.zig
git commit -m "transform: migrate parameters to rewrite plan"
```

### Task 12: Reuse TransformSession In Arrow Functions

**Files:**
- Modify: `src/transform/arrow_functions.zig`
- Test: `tests/arrow_functions_transform_test.zig`

- [ ] **Step 1: Write the failing arrow-session regression**

```zig
test "arrow functions resolve self references through transform session" {
    try expectTransform(
        \\const fnRef = (value) => value + fnRef(value);
    ,
        \\var fnRef = function fnRef(value) {
        \\  return value + fnRef(value);
        \\};
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build transform-test -- --diff arrow-functions/self-referential`
Expected: FAIL after the new assertion if arrow self-reference discovery is still independent of the shared session

- [ ] **Step 3: Switch arrow queries to shared session lookups**

```zig
fn getArrowBindingNameNode(self: *State, ctx: *TransformContext, arrow: NodeIndex) ?NodeIndex {
    if (ctx.session) |session| {
        return session.functionBindingNode(arrow);
    }
    return self.getArrowBindingNameNodeSlow(ctx, arrow);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build transform-test -- --diff arrow-functions/self-referential`
Expected: PASS with unchanged output and no new arrow fixture regressions

- [ ] **Step 5: Commit**

```bash
git add src/transform/arrow_functions.zig tests/arrow_functions_transform_test.zig
git commit -m "transform: reuse session data in arrow functions"
```

### Task 13: Migrate Block Scoping To Shared Rewrite And Session Data

**Files:**
- Modify: `src/transform/block_scoping.zig`
- Test: `tests/block_scoping_transform_test.zig`
- Test: `tests/transform_pipeline_stats_test.zig`

- [ ] **Step 1: Write the failing block-scoping regression**

```zig
test "block scoping rewrite plan preserves loop closure renames" {
    try expectTransform(
        \\for (const value of list) {
        \\  callbacks.push(function () {
        \\    return value;
        \\  });
        \\}
    ,
        \\var _loop = function (value) {
        \\  callbacks.push(function () {
        \\    return value;
        \\  });
        \\};
        \\for (var _iterator = list[Symbol.iterator](), _step; !(_step = _iterator.next()).done;) {
        \\  var value = _step.value;
        \\  _loop(value);
        \\}
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build transform-test -- --diff for-const-closure`
Expected: FAIL once the new regression is added because `block_scoping` still applies direct source edits without the shared rewrite-plan path

- [ ] **Step 3: Migrate rename and loop edits to session-backed rewrite planning**

```zig
var plan = rewrite_plan.RewritePlan.init(gpa);
defer plan.deinit();

for (rename_edits.items) |edit| {
    try plan.add(.{
        .start = edit.start,
        .end = edit.end,
        .text = edit.replacement,
        .needs_reindent = false,
    });
}

try rewrite_plan.applyPlan(ctx.ast, &plan, .{ .allocator = gpa });
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build transform-test -- --diff for-const-closure`
Expected: PASS for the new loop-closure regression and existing block-scoping fixtures

- [ ] **Step 5: Commit**

```bash
git add src/transform/block_scoping.zig tests/block_scoping_transform_test.zig tests/transform_pipeline_stats_test.zig
git commit -m "transform: migrate block scoping to shared rewrite path"
```

### Task 14: Run Cross-Cutting Validation And Promote The New Benchmark Flow

**Files:**
- Modify: `progress.md`
- Modify: `context.md`
- Modify: `scripts/bench-real-projects.sh`

- [ ] **Step 1: Write the failing documentation assertion**

```text
Expected `progress.md` to mention the real-project benchmark path and `context.md` to describe the new benchmark workflow once the implementation is complete.
```

- [ ] **Step 2: Run validation to establish the pre-promotion baseline**

Run: `zig build conformance-test`
Expected: PASS before touching the handoff docs

Run: `bash scripts/bench-real-projects.sh core`
Expected: PASS with both Zig and Babel summaries emitted, plus top-file and per-project totals

- [ ] **Step 3: Update the durable docs and shell help text**

```md
## Current Reality

- Real-project transform benchmarking lives in `bench/corpus.lock.json`, `scripts/prepare_real_bench_corpus.cjs`, and `scripts/bench-real-projects.sh`
- `bash scripts/bench-real-projects.sh core` is the primary throughput benchmark entry point
```

```md
## Current Focus

- Use the real-project benchmark `core` tier as the default throughput decision surface.
- Keep shared `TransformSession` and `RewritePlan` changes aligned with conformance-first validation.
```

- [ ] **Step 4: Run final verification**

Run: `zig build test`
Expected: PASS

Run: `zig build conformance-test`
Expected: PASS

Run: `bash scripts/bench-real-projects.sh core`
Expected: PASS with stable `react-native` and `antd` project summaries and Zig/Babel ratios

- [ ] **Step 5: Commit**

```bash
git add context.md progress.md scripts/bench-real-projects.sh
git commit -m "docs: promote real-project transform benchmark workflow"
```

## Self-Review Notes

- Spec coverage: benchmark pinning, tiering, reporting, Babel comparison, shared session, rewrite plan, `parameters`, `block_scoping`, `arrow_functions`, staged rollout, and doc promotion each map to at least one task.
- Placeholder scan: no `TODO`, `TBD`, or “similar to Task N” shortcuts remain; each task has concrete files, commands, and core code snippets.
- Type consistency: the plan consistently uses `TransformSession`, `RewritePlan`, `FileRow`, and `Summary`; later tasks reuse those names instead of inventing alternatives.
