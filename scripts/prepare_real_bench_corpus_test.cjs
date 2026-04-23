const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");
const assert = require("node:assert/strict");

const {
  loadCorpusLock,
  buildTierFileList,
  prepareCorpus,
} = require("./prepare_real_bench_corpus.cjs");

test("buildTierFileList keeps only checked-in files for the requested tier", () => {
  const lock = loadCorpusLock(path.join(__dirname, "../bench/corpus.lock.json"));
  const rows = buildTierFileList(lock, "core");

  assert.ok(rows.length > 0);
  assert.ok(rows.every(row => row.tiers.includes("core")));
  assert.ok(rows.some(row => row.project === "react-native"));
  assert.ok(rows.some(row => row.project === "antd"));
});

test("benchmark tiers expand cumulatively beyond smoke", () => {
  const lock = loadCorpusLock(path.join(__dirname, "../bench/corpus.lock.json"));
  const smokeRows = buildTierFileList(lock, "smoke");
  const coreRows = buildTierFileList(lock, "core");
  const fullRows = buildTierFileList(lock, "full");

  const keyOf = row => `${row.project}:${row.path}`;
  const smokeKeys = new Set(smokeRows.map(keyOf));
  const coreKeys = new Set(coreRows.map(keyOf));
  const fullKeys = new Set(fullRows.map(keyOf));

  assert.ok(smokeRows.length > 0);
  assert.ok(coreRows.length > smokeRows.length);
  assert.ok(fullRows.length > coreRows.length);
  assert.ok([...smokeKeys].every(key => coreKeys.has(key)));
  assert.ok([...coreKeys].every(key => fullKeys.has(key)));
  assert.ok(coreKeys.has("react-native:Libraries/Interaction/PanResponder.js"));
  assert.ok(coreKeys.has("antd:es/table/InternalTable.js"));
  assert.ok(fullKeys.has("react-native:Libraries/Components/TextInput/TextInput.flow.js"));
  assert.ok(fullKeys.has("antd:es/tabs/style/index.js"));
});

test("prepareCorpus writes tier file lists under .zig-cache/bench/corpus", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-corpus-"));
  await fs.promises.mkdir(path.join(tmp, "bench"), { recursive: true });
  await fs.promises.copyFile(
    path.join(__dirname, "../bench/corpus.lock.json"),
    path.join(tmp, "bench/corpus.lock.json"),
  );

  const result = await prepareCorpus({
    repoRoot: tmp,
    lockPath: path.join(tmp, "bench/corpus.lock.json"),
    tier: "smoke",
    offline: true,
  });

  assert.equal(result.tier, "smoke");
  assert.ok(fs.existsSync(path.join(tmp, ".zig-cache/bench/corpus/smoke.txt")));
});

test("prepareCorpus rejects missing resolved files when validation is enabled", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-corpus-validate-"));
  const lockPath = path.join(tmp, "bench/corpus.lock.json");

  await fs.promises.mkdir(path.join(tmp, "bench"), { recursive: true });
  await fs.promises.writeFile(
    lockPath,
    JSON.stringify(
      {
        packages: [
          {
            project: "sample",
            version: "1.0.0",
            tarball: "https://example.invalid/sample-1.0.0.tgz",
            root: "package",
            files: [
              {
                path: "src/missing.js",
                tiers: ["smoke"],
              },
            ],
          },
        ],
      },
      null,
      2,
    ),
  );

  await assert.rejects(
    prepareCorpus({
      repoRoot: tmp,
      lockPath,
      tier: "smoke",
      offline: true,
      validateResolvedFiles: true,
    }),
    /missing corpus file/i,
  );
});

test("babel batch mode prints one file row per input line", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-babel-files-"));
  const samplePath = path.join(tmp, "sample.ts");
  const listPath = path.join(tmp, "smoke.txt");

  await fs.promises.writeFile(samplePath, "const answer: number = 42;\n");
  await fs.promises.writeFile(listPath, `sample\t0.0.0\t${samplePath}\n`);

  const result = spawnSync(
    "node",
    ["scripts/babel_transform_bench.cjs", "files", "smoke", listPath, "1"],
    {
      cwd: path.join(__dirname, ".."),
      encoding: "utf8",
    },
  );

  assert.equal(result.status, 0);
  assert.match(result.stdout, /^file\tsample\t/m);
  assert.match(result.stdout, /^summary\tfiles\t/m);
});

test("babel batch mode falls back to flow parsing for flow modules", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-babel-flow-files-"));
  const samplePath = path.join(tmp, "sample.js");
  const listPath = path.join(tmp, "smoke.txt");

  await fs.promises.writeFile(
    samplePath,
    [
      "'use strict';",
      "import type {Foo} from './foo';",
      "export type Composite = {",
      "  start: () => void,",
      "  ...,",
      "};",
      "",
    ].join("\n"),
  );
  await fs.promises.writeFile(listPath, `sample\t0.0.0\t${samplePath}\n`);

  const result = spawnSync(
    "node",
    ["scripts/babel_transform_bench.cjs", "files", "smoke", listPath, "1"],
    {
      cwd: path.join(__dirname, ".."),
      encoding: "utf8",
    },
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^file\tsample\t/m);
  assert.match(result.stdout, /^summary\tfiles\t/m);
});

test("transform bench profile-file emits shared and pass rows", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-profile-file-"));
  const samplePath = path.join(tmp, "sample.ts");
  const binPath = path.join(tmp, "transform_bench");
  const miseBin = ["/usr/local/bin/mise", "/opt/homebrew/bin/mise", `${process.env.HOME}/.local/bin/mise`]
    .find(candidate => fs.existsSync(candidate));

  assert.ok(miseBin, "expected a local mise binary");
  await fs.promises.writeFile(samplePath, "const fn1 = (a = 1, ...rest) => [...rest, a];\n");

  const buildResult = spawnSync(
    miseBin,
    [
      "exec",
      "--",
      "zig",
      "build-exe",
      "--dep",
      "zig_babal",
      `-Mroot=${path.join(__dirname, "transform_bench.zig")}`,
      `-Mzig_babal=${path.join(__dirname, "../src/root.zig")}`,
      "-O",
      "Debug",
      `-femit-bin=${binPath}`,
    ],
    {
      cwd: path.join(__dirname, ".."),
      encoding: "utf8",
    },
  );

  assert.equal(buildResult.status, 0, buildResult.stderr);

  const result = spawnSync(binPath, ["profile-file", "sample", samplePath, "0", "1"], {
    cwd: path.join(__dirname, ".."),
    encoding: "utf8",
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^profile_shared\tsample\t/m);
  assert.match(result.stdout, /^profile_pass\tsample\t/m);
});

test("bench-real-projects prints aggregate comparison output from summary rows", async () => {
  const tmp = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zb-driver-report-"));
  const zigPath = path.join(tmp, "smoke-zig.tsv");
  const babelPath = path.join(tmp, "smoke-babel.tsv");

  await fs.promises.writeFile(
    zigPath,
    [
      "file\treact-native\tsrc/slow.js\t100\t10\t20\t10\t40",
      "file\tantd\tsrc/fast.js\t50\t5\t10\t5\t20",
      "summary\tfiles\t2\ttotal_ns\t60\tp95_total_ns\t40",
      "project\tantd\tfiles\t1\ttotal_ns\t20",
      "project\treact-native\tfiles\t1\ttotal_ns\t40",
      "",
    ].join("\n"),
  );
  await fs.promises.writeFile(
    babelPath,
    [
      "file\treact-native\tsrc/slow.js\t100\t20\t40\t20\t80",
      "file\tantd\tsrc/fast.js\t50\t8\t15\t7\t30",
      "summary\tfiles\t2\ttotal_ns\t110\tp95_total_ns\t80",
      "project\tantd\tfiles\t1\ttotal_ns\t30",
      "project\treact-native\tfiles\t1\ttotal_ns\t80",
      "",
    ].join("\n"),
  );

  const result = spawnSync(
    "bash",
    [
      "-lc",
      `source scripts/bench-real-projects.sh; print_comparison_report smoke "${zigPath}" "${babelPath}"`,
    ],
    {
      cwd: path.join(__dirname, ".."),
      encoding: "utf8",
    },
  );

  assert.equal(result.status, 0);
  assert.match(result.stdout, /^summary\tsmoke\tfiles\t2\tzig_total_ns\t60\tbabel_total_ns\t110\tratio\t1\.833x$/m);
  assert.match(result.stdout, /^project\treact-native\tzig_total_ns\t40\tbabel_total_ns\t80\tratio\t2\.000x$/m);
  assert.match(result.stdout, /^file\treact-native\tsrc\/slow\.js\tzig_total_ns\t40\tbabel_total_ns\t80\tratio\t2\.000x$/m);
  assert.match(result.stdout, /^ratio_file\treact-native\tsrc\/slow\.js\tzig_total_ns\t40\tbabel_total_ns\t80\tratio\t2\.000x$/m);
  assert.match(result.stdout, /^phase\tparse\tzig_total_ns\t15\tbabel_total_ns\t28\tratio\t1\.867x$/m);
  assert.match(result.stdout, /^phase\ttransform\tzig_total_ns\t30\tbabel_total_ns\t55\tratio\t1\.833x$/m);
  assert.match(result.stdout, /^phase\tcodegen\tzig_total_ns\t15\tbabel_total_ns\t27\tratio\t1\.800x$/m);
});

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
    {
      cwd: path.join(__dirname, ".."),
      encoding: "utf8",
    },
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^hotspot\treact-native\tsrc\/slow\.js\tzig_total_ns\t100$/m);
  assert.match(result.stdout, /^profile_shared\treact-native\tsrc\/slow\.js\tpipeline_ns\t80/m);
  assert.match(result.stdout, /^profile_pass\treact-native\tsrc\/slow\.js\tparameters\t/m);
});
