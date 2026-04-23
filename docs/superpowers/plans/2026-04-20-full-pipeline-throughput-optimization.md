# Full-Pipeline Throughput Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real-project hotspot drilldown for the full pipeline, confirm the dominant cost on the `core` corpus, and land the first low-risk optimization by making transform run-stat retention opt-in instead of paying for it on every file.

**Architecture:** Keep `bash scripts/bench-real-projects.sh --tier core` as the KPI surface. Extend the benchmark tooling just enough to profile the slowest real-project files with machine-readable transform-shared and per-pass rows, then use that evidence to remove unconditional `PipelineRunStats` and retained `TransformSession` overhead from normal runs. Profile and test paths explicitly opt back in.

**Tech Stack:** Zig 0.16, existing `zig build` runners, Bash benchmark driver, Node.js script tests

---

## File Map

### Modified Files

- `src/bench/real_project_bench.zig`
  Add machine-readable row formatters for transform shared-cost and per-pass profile output.
- `tests/real_project_bench_test.zig`
  Cover the new transform profile row formatters.
- `scripts/transform_bench.zig`
  Add a machine-readable `profile-file` mode for one file, emit shared transform timings plus per-pass rows, and explicitly enable run-stat retention only for profiling.
- `scripts/bench-real-projects.sh`
  Add `--profile-top N`, pick the slowest Zig files from the batch run, rerun `profile-file` on only those paths, and print their drilldown rows after the aggregate comparison report.
- `scripts/prepare_real_bench_corpus_test.cjs`
  Add script-level coverage for the new `profile-file` and `--profile-top` benchmark reporting surface.
- `src/transform/pipeline.zig`
  Make run-stat collection and retained transform-session ownership opt-in so normal transform runs stop paying for profiling data they never read.
- `tests/transform_pipeline_stats_test.zig`
  Cover both the new default behavior (`lastRunStats()` / `lastTransformSession()` stay null) and the explicit opt-in profiling path.
- `progress.md`
  Refresh the current hotspot, verification state, and benchmark result after the optimization lands.

## Verification Ladder

Use this same order while executing the tasks:

1. `node --test scripts/prepare_real_bench_corpus_test.cjs`
2. `zig build test`
3. `zig build conformance-test`
4. `bash scripts/bench-real-projects.sh --tier core --profile-top 5`
5. `bash scripts/bench-real-projects.sh --tier full` when the `core` win is confirmed and the pipeline change touches shared infrastructure

## Task 1: Add Machine-Readable Transform Profile Rows

**Files:**
- Modify: `src/bench/real_project_bench.zig`
- Modify: `tests/real_project_bench_test.zig`

- [ ] **Step 1: Write the failing unit tests for transform profile row formatting**

```zig
test "formatTransformProfileSharedRow emits machine-readable shared timing rows" {
    const line = try zb.RealProjectBench.formatTransformProfileSharedRow(std.testing.allocator, .{
        .project = "antd",
        .path = "es/form/Form.js",
        .pipeline_ns = 100,
        .scope_analysis_ns = 20,
        .transform_session_ns = 10,
        .dispatch_table_build_ns = 5,
        .traversal_ns = 40,
    });
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "profile_shared\tantd\tes/form/Form.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "dispatch_table_build_ns\t5") != null);
}

test "formatTransformProfilePassRow emits machine-readable pass timing rows" {
    const line = try zb.RealProjectBench.formatTransformProfilePassRow(std.testing.allocator, .{
        .project = "antd",
        .path = "es/form/Form.js",
        .name = "parameters",
        .total_ns = 30,
        .enter_calls = 4,
        .exit_calls = 2,
    });
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "profile_pass\tantd\tes/form/Form.js\tparameters") != null);
}
```

- [ ] **Step 2: Run the unit suite to verify the tests fail for the missing helpers**

Run: `mise exec -- zig build test`

Expected: FAIL in `tests/real_project_bench_test.zig` because `RealProjectBench` has no `formatTransformProfileSharedRow` / `formatTransformProfilePassRow`.

- [ ] **Step 3: Add the row structs and formatters**

```zig
pub const TransformProfileSharedRow = struct {
    project: []const u8,
    path: []const u8,
    pipeline_ns: u64,
    scope_analysis_ns: u64,
    transform_session_ns: u64,
    dispatch_table_build_ns: u64,
    traversal_ns: u64,
};

pub const TransformProfilePassRow = struct {
    project: []const u8,
    path: []const u8,
    name: []const u8,
    total_ns: u64,
    enter_calls: u64,
    exit_calls: u64,
};

pub fn formatTransformProfileSharedRow(allocator: std.mem.Allocator, row: TransformProfileSharedRow) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "profile_shared\t{s}\t{s}\tpipeline_ns\t{d}\tscope_analysis_ns\t{d}\ttransform_session_ns\t{d}\tdispatch_table_build_ns\t{d}\ttraversal_ns\t{d}",
        .{
            row.project,
            row.path,
            row.pipeline_ns,
            row.scope_analysis_ns,
            row.transform_session_ns,
            row.dispatch_table_build_ns,
            row.traversal_ns,
        },
    );
}

pub fn formatTransformProfilePassRow(allocator: std.mem.Allocator, row: TransformProfilePassRow) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "profile_pass\t{s}\t{s}\t{s}\ttotal_ns\t{d}\tenter_calls\t{d}\texit_calls\t{d}",
        .{ row.project, row.path, row.name, row.total_ns, row.enter_calls, row.exit_calls },
    );
}
```

- [ ] **Step 4: Run the unit suite to verify the new rows are covered**

Run: `mise exec -- zig build test`

Expected: PASS for `tests/real_project_bench_test.zig` and no regressions in existing unit tests.

## Task 2: Add `transform_bench profile-file` For Slow-File Drilldown

**Files:**
- Modify: `scripts/transform_bench.zig`
- Modify: `scripts/prepare_real_bench_corpus_test.cjs`

- [ ] **Step 1: Write the failing script test for `profile-file`**

```js
test("transform bench profile-file emits shared and pass rows", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-profile-file-"));
  const samplePath = path.join(tmp, "sample.ts");
  const binPath = path.join(tmp, "transform_bench");

  await fs.promises.writeFile(samplePath, "const fn1 = (a = 1, ...rest) => [...rest, a];\n");

  assert.equal(
    spawnSync("mise", [
      "exec", "--", "zig", "build-exe",
      "--dep", "zig_babal",
      `-Mroot=${path.join(__dirname, "transform_bench.zig")}`,
      `-Mzig_babal=${path.join(__dirname, "../src/root.zig")}`,
      "-O", "Debug",
      `-femit-bin=${binPath}`,
    ], { cwd: path.join(__dirname, ".."), encoding: "utf8" }).status,
    0,
  );

  const result = spawnSync(binPath, ["profile-file", "sample", samplePath, "0", "1"], {
    cwd: path.join(__dirname, ".."),
    encoding: "utf8",
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^profile_shared\tsample\t/m);
  assert.match(result.stdout, /^profile_pass\tsample\t/m);
});
```

- [ ] **Step 2: Run the script tests to verify the new mode is missing**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`

Expected: FAIL because `transform_bench` does not recognize `profile-file` and does not emit `profile_shared` / `profile_pass` rows.

- [ ] **Step 3: Add the new profile mode and emit the shared timings**

```zig
if (std.mem.eql(u8, mode, "profile-file")) {
    if (filtered.items.len != 5) {
        printUsage();
        return error.InvalidArgs;
    }

    const project = filtered.items[1];
    const file_path = filtered.items[2];
    const warmups = try std.fmt.parseInt(usize, filtered.items[3], 10);
    const iterations = try std.fmt.parseInt(usize, filtered.items[4], 10);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(source);
    try benchProfileFile(allocator, io, project, file_path, source, warmups, iterations, if (telemetry_session) |*session| session else null, spanPtr(&run_span));
    return;
}
```

```zig
fn benchProfileFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    project: []const u8,
    file_path: []const u8,
    source: []const u8,
    warmups: usize,
    iterations: usize,
    telemetry_session: ?*zb.Telemetry.TelemetrySession,
    parent_span: ?*const zb.Telemetry.SpanHandle,
) !void {
    var profile_span = if (telemetry_session) |session|
        session.startSpan(parent_span, .fixture, "phase", "bench_profile_file", &.{
            zb.Telemetry.Field.string("project", project),
            zb.Telemetry.Field.string("file", file_path),
            zb.Telemetry.Field.unsigned("warmups", warmups),
            zb.Telemetry.Field.unsigned("iterations", iterations),
        })
    else
        null;
    const total_iters = warmups + iterations;
    var pipeline_ns: u64 = 0;
    var scope_analysis_ns: u64 = 0;
    var transform_session_ns: u64 = 0;
    var dispatch_table_build_ns: u64 = 0;
    var traversal_ns: u64 = 0;
    var pass_totals: std.ArrayListUnmanaged(ProfilePassStat) = .empty;
    defer {
        for (pass_totals.items) |pass| allocator.free(pass.name);
        pass_totals.deinit(allocator);
    }

    for (0..total_iters) |iter| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var result = try parseTs(alloc, source);
        var pipeline = try buildFullPipeline(alloc, telemetry_session, spanPtr(&profile_span));
        defer pipeline.deinit();
        pipeline.collect_run_stats = true;
        pipeline.retain_transform_session = true;

        const timer = startTimer(io);
        try pipeline.run(&result.ast);
        const pipeline_elapsed = readTimerNs(io, timer);

        if (iter >= warmups) {
            pipeline_ns +%= pipeline_elapsed;
            if (pipeline.lastRunStats()) |stats| {
                scope_analysis_ns +%= stats.scope_analysis_ns orelse 0;
                transform_session_ns +%= stats.transform_session_ns orelse 0;
                dispatch_table_build_ns +%= stats.dispatch_table_build_ns orelse 0;
                traversal_ns +%= stats.traversal_ns orelse 0;
                if (pass_totals.items.len == 0) {
                    try pass_totals.ensureTotalCapacity(allocator, stats.passes.len);
                    for (stats.passes) |pass| {
                        try pass_totals.append(allocator, .{
                            .name = try allocator.dupe(u8, pass.name),
                            .total_ns = pass.total_ns,
                            .enter_calls = pass.enter_calls,
                            .exit_calls = pass.exit_calls,
                        });
                    }
                } else {
                    for (pass_totals.items, stats.passes) |*totals, pass| {
                        totals.total_ns +%= pass.total_ns;
                        totals.enter_calls +%= pass.enter_calls;
                        totals.exit_calls +%= pass.exit_calls;
                    }
                }
            }
        }
    }

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_writer.interface;
    const shared_line = try zb.RealProjectBench.formatTransformProfileSharedRow(allocator, .{
        .project = project,
        .path = file_path,
        .pipeline_ns = pipeline_ns,
        .scope_analysis_ns = scope_analysis_ns,
        .transform_session_ns = transform_session_ns,
        .dispatch_table_build_ns = dispatch_table_build_ns,
        .traversal_ns = traversal_ns,
    });
    try stdout.print("{s}\n", .{shared_line});
    for (pass_totals.items) |pass| {
        const pass_line = try zb.RealProjectBench.formatTransformProfilePassRow(allocator, .{
            .project = project,
            .path = file_path,
            .name = pass.name,
            .total_ns = pass.total_ns,
            .enter_calls = pass.enter_calls,
            .exit_calls = pass.exit_calls,
        });
        try stdout.print("{s}\n", .{pass_line});
    }
}
```

- [ ] **Step 4: Run the script tests to verify the profile mode works**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`

Expected: PASS for the new `profile-file` case plus the existing script tests.

## Task 3: Add `--profile-top` To The Real-Project Benchmark Driver

**Files:**
- Modify: `scripts/bench-real-projects.sh`
- Modify: `scripts/prepare_real_bench_corpus_test.cjs`

- [ ] **Step 1: Write the failing driver test for hotspot drilldown**

```js
test("bench-real-projects surfaces profile rows for the slowest Zig files", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-profile-report-"));
  const zigPath = path.join(tmp, "smoke-zig.tsv");
  const profilePath = path.join(tmp, "profile.tsv");

  await fs.promises.writeFile(
    zigPath,
    [
      "file\treact-native\tsrc/slow.js\t100\t10\t80\t10\t100",
      "file\tantd\tsrc/fast.js\t50\t10\t10\t5\t25",
      "summary\tfiles\t2\ttotal_ns\t125\tp95_total_ns\t100",
      "",
    ].join("\n"),
  );
  await fs.promises.writeFile(
    profilePath,
    [
      "profile_shared\treact-native\tsrc/slow.js\tpipeline_ns\t80\tscope_analysis_ns\t15\ttransform_session_ns\t8\tdispatch_table_build_ns\t3\ttraversal_ns\t40",
      "profile_pass\treact-native\tsrc/slow.js\tparameters\ttotal_ns\t20\tenter_calls\t4\texit_calls\t2",
      "",
    ].join("\n"),
  );

  const result = spawnSync(
    "bash",
    [
      "-lc",
      `source scripts/bench-real-projects.sh; print_profile_report "${zigPath}" "${profilePath}" 1`,
    ],
    { cwd: path.join(__dirname, ".."), encoding: "utf8" },
  );

  assert.equal(result.status, 0);
  assert.match(result.stdout, /^hotspot\treact-native\tsrc\/slow\.js\tzig_total_ns\t100$/m);
  assert.match(result.stdout, /^profile_shared\treact-native\tsrc\/slow\.js\tpipeline_ns\t80/m);
  assert.match(result.stdout, /^profile_pass\treact-native\tsrc\/slow\.js\tparameters\t/m);
});
```

- [ ] **Step 2: Run the script tests to verify the helper is missing**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`

Expected: FAIL because `bench-real-projects.sh` does not accept `--profile-top` and has no `print_profile_report` helper.

- [ ] **Step 3: Implement the top-file selection and profile report**

```bash
PROFILE_TOP=0

top_zig_files() {
  local tsv_path="$1"
  local limit="$2"
  awk -F'\t' '$1 == "file" { print $8 "\t" $2 "\t" $3 }' "$tsv_path" \
    | sort -t$'\t' -k1,1nr \
    | head -n "$limit"
}

print_profile_report() {
  local zig_tsv="$1"
  local profile_tsv="$2"
  local limit="$3"

  top_zig_files "$zig_tsv" "$limit" | while IFS=$'\t' read -r zig_total project_name file_path; do
    [[ -n "$project_name" ]] || continue
    printf 'hotspot\t%s\t%s\tzig_total_ns\t%s\n' "$project_name" "$file_path" "$zig_total"
    awk -F'\t' -v project_name="$project_name" -v file_path="$file_path" '
      $2 == project_name && $3 == file_path { print }
    ' "$profile_tsv"
  done
}
```

```bash
if (( PROFILE_TOP > 0 )); then
  profile_tsv="$CACHE_DIR/${TIER}-zig-profile.tsv"
  : > "$profile_tsv"
  while IFS=$'\t' read -r _ project_name file_path; do
    [[ -n "$project_name" ]] || continue
    "$CACHE_DIR/transform_bench" profile-file "$project_name" "$file_path" 0 1 >> "$profile_tsv"
  done < <(top_zig_files "$CACHE_DIR/${TIER}-zig.tsv" "$PROFILE_TOP")
  print_profile_report "$CACHE_DIR/${TIER}-zig.tsv" "$profile_tsv" "$PROFILE_TOP"
fi
```

- [ ] **Step 4: Run the script tests to verify hotspot drilldown output**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`

Expected: PASS for the new `print_profile_report` coverage plus the earlier benchmark-script tests.

## Task 4: Capture The Baseline And Confirm The Bottleneck

**Files:**
- Modify: none

- [ ] **Step 1: Run the unit and script checks before benchmarking**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`
Expected: PASS

Run: `mise exec -- zig build test`
Expected: PASS

- [ ] **Step 2: Run the core-tier benchmark with hotspot drilldown**

Run: `bash scripts/bench-real-projects.sh --tier core --profile-top 5`

Expected: output contains:

```text
summary	core
phase	parse
phase	transform
phase	codegen
hotspot
profile_shared
profile_pass
```

- [ ] **Step 3: Confirm the optimization target**

Interpret the output with one rule:

```text
If the slowest files are still transform-dominated and the non-pass/shared rows
show meaningful fixed overhead, proceed to Task 5.
If parse or codegen dominates instead, stop and write a narrower follow-up plan
for that subsystem before editing production code.
```

Expected: current repo state should still point to transform shared overhead as the first optimization target.

## Task 5: Make Pipeline Run Stats And Session Retention Opt-In

**Files:**
- Modify: `src/transform/pipeline.zig`
- Modify: `tests/transform_pipeline_stats_test.zig`
- Modify: `scripts/transform_bench.zig`

- [ ] **Step 1: Write the failing pipeline tests for the new default behavior**

```zig
test "pipeline does not retain run stats unless requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var result = try zb.parseWithOptions(alloc,
        \\const fn1 = (a = 1, ...rest) => [...rest, a];
    , .{
        .source_type = .script,
        .language = .typescript,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();
    pipeline.needs_scope = true;
    try pipeline.addPass(zb.ArrowFunctions.createPass(.{}));

    try pipeline.run(&result.ast);

    try std.testing.expect(pipeline.lastRunStats() == null);
    try std.testing.expect(pipeline.lastTransformSession() == null);
}
```

```zig
test "pipeline retains run stats and transform session when profiling is enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var result = try zb.parseWithOptions(alloc,
        \\const fn1 = (a = 1, ...rest) => [...rest, a];
    , .{
        .source_type = .script,
        .language = .typescript,
        .defer_comment_attachment = true,
    });
    defer result.deinit();

    var pipeline = zb.Pipeline.init(alloc);
    defer pipeline.deinit();
    pipeline.needs_scope = true;
    pipeline.collect_run_stats = true;
    pipeline.retain_transform_session = true;
    zb.Parameters.resetState();
    try pipeline.addPass(zb.Parameters.createPass(.{}));
    try pipeline.run(&result.ast);

    const stats = pipeline.lastRunStats() orelse return error.ExpectedPipelineStats;
    try std.testing.expect(stats.transform_session_ns != null);
    try std.testing.expect(stats.dispatch_table_build_ns != null);
    try std.testing.expect(stats.traversal_ns != null);
    try std.testing.expect(pipeline.lastTransformSession() != null);
}
```

- [ ] **Step 2: Run the unit suite to verify the tests fail under the current always-on behavior**

Run: `mise exec -- zig build test`

Expected: FAIL because `lastRunStats()` and `lastTransformSession()` are currently populated even when the caller never asked for them.

- [ ] **Step 3: Implement opt-in stats retention and update profiling callers**

```zig
pub const Pipeline = struct {
    passes: std.ArrayListUnmanaged(Pass),
    allocator: Allocator,
    jsx_pragma: ?[]const u8 = null,
    jsx_pragma_frag: ?[]const u8 = null,
    needs_scope: bool = false,
    requires_transform_session: bool = false,
    scope_extra_globals: []const []const u8 = &.{},
    telemetry_session: ?*telemetry_mod.TelemetrySession = null,
    telemetry_parent_span: ?telemetry_mod.SpanHandle = null,
    collect_run_stats: bool = false,
    retain_transform_session: bool = false,
    last_run_stats: ?PipelineRunStats = null,
    last_transform_session: ?session_mod.TransformSession = null,
};
```

```zig
const wants_run_stats = self.collect_run_stats or self.telemetry_session != null;
const wants_retained_session = self.retain_transform_session or self.collect_run_stats;
```

```zig
const pass_stats = if (wants_run_stats)
    self.allocator.alloc(PassStats, self.passes.items.len) catch null
else
    null;
```

```zig
var transient_transform_session: ?session_mod.TransformSession = null;
var ctx_session: ?*session_mod.TransformSession = null;
if (self.needs_scope or self.requires_transform_session) {
    transient_transform_session = try session_mod.TransformSession.init(
        self.allocator,
        ast,
        if (scope_result) |*sr| sr else null,
    );
    if (wants_retained_session) {
        self.last_transform_session = transient_transform_session.?;
        ctx_session = self.lastTransformSession();
    } else {
        ctx_session = &transient_transform_session.?;
    }
}
defer if (!wants_retained_session) {
    if (transient_transform_session) |*session| session.deinit(self.allocator);
}
```

```zig
var pipeline = try buildFullPipeline(alloc, telemetry_session, spanPtr(&profile_span));
pipeline.collect_run_stats = true;
pipeline.retain_transform_session = true;
```

Also run `mise exec -- zig fmt src/transform/pipeline.zig scripts/transform_bench.zig tests/transform_pipeline_stats_test.zig`.

- [ ] **Step 4: Run the validation ladder and confirm the throughput win**

Run: `node --test scripts/prepare_real_bench_corpus_test.cjs`
Expected: PASS

Run: `mise exec -- zig build test`
Expected: PASS

Run: `mise exec -- zig build conformance-test`
Expected: PASS at the repo baseline for known transform failures

Run: `bash scripts/bench-real-projects.sh --tier core --profile-top 5`
Expected: total `transform` time and total end-to-end `summary` improve versus the pre-change baseline

Run: `bash scripts/bench-real-projects.sh --tier full`
Expected: the same direction of improvement holds on the larger corpus

## Task 6: Refresh Handoff Docs

**Files:**
- Modify: `progress.md`

- [ ] **Step 1: Update the progress summary with the new benchmark surface and optimization result**

```md
## Recent Completed

- Added `--profile-top` real-project hotspot drilldown with `profile_shared` and `profile_pass` rows for the slowest Zig files.
- Made pipeline run-stat collection and retained transform-session ownership opt-in, leaving normal transform runs on the cheaper path.
- Re-measured full-pipeline core/full benchmarks after removing unconditional profiling overhead.
```

- [ ] **Step 2: Record the latest verification snapshot**

```md
## Verification Snapshot

- 2026-04-20: `node --test scripts/prepare_real_bench_corpus_test.cjs` passed.
- 2026-04-20: `mise exec -- zig build test` passed.
- 2026-04-20: `mise exec -- zig build conformance-test` completed at the current baseline.
- 2026-04-20: `bash scripts/bench-real-projects.sh --tier core --profile-top 5` showed the post-change full-pipeline result.
- 2026-04-20: `bash scripts/bench-real-projects.sh --tier full` confirmed the larger-corpus direction.
```

- [ ] **Step 3: Verify the repo is ready for handoff**

Run: `git diff --stat`

Expected: only the benchmark, pipeline, tests, and progress files from this plan are changed.
