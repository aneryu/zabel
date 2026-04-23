#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const candidateRoots = [root, path.resolve(root, "..", "..")];

function resolveLocalPath(relPath) {
  for (const base of candidateRoots) {
    const candidate = path.join(base, relPath);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return path.join(root, relPath);
}

function localRequire(relPath) {
  return require(resolveLocalPath(relPath));
}

const babelCore = localRequire("vendor/babel/packages/babel-core/lib/index.js");
const babelParser = localRequire("vendor/babel/packages/babel-parser/lib/index.js");
const babelGeneratorMod = localRequire("vendor/babel/packages/babel-generator/lib/index.js");
const babelGenerator = babelGeneratorMod.default || babelGeneratorMod;

const stageDefs = [
  {
    stage: 1,
    name: "ts_strip",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-typescript/lib/index.js").default,
  },
  {
    stage: 2,
    name: "shorthand_properties",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-shorthand-properties/lib/index.js").default,
  },
  {
    stage: 3,
    name: "template_literals",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-template-literals/lib/index.js").default,
  },
  {
    stage: 4,
    name: "computed_properties",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-computed-properties/lib/index.js").default,
  },
  {
    stage: 5,
    name: "arrow_functions",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-arrow-functions/lib/index.js").default,
  },
  {
    stage: 6,
    name: "spread",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-spread/lib/index.js").default,
  },
  {
    stage: 7,
    name: "parameters",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-parameters/lib/index.js").default,
  },
  {
    stage: 8,
    name: "for_of",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-for-of/lib/index.js").default,
  },
  {
    stage: 9,
    name: "block_scoping",
    plugin: () =>
      localRequire("vendor/babel/packages/babel-plugin-transform-block-scoping/lib/index.js").default,
  },
];

function parseTs(source) {
  return babelParser.parse(source, {
    sourceType: "script",
    plugins: ["typescript"],
  });
}

function looksLikeFlowFile(source, filePath) {
  return filePath.endsWith(".js") && (source.includes("@flow") || source.includes("@noflow"));
}

function parseBatchSourceWithPlugin(source, pluginName) {
  return babelParser.parse(source, {
    sourceType: "unambiguous",
    plugins: [pluginName],
  });
}

function parseBatchSource(source, filePath) {
  const primaryPlugin = looksLikeFlowFile(source, filePath) ? "flow" : "typescript";

  try {
    return parseBatchSourceWithPlugin(source, primaryPlugin);
  } catch (primaryError) {
    if (!filePath.endsWith(".js")) {
      throw primaryError;
    }

    const fallbackPlugin = primaryPlugin === "flow" ? "typescript" : "flow";
    try {
      return parseBatchSourceWithPlugin(source, fallbackPlugin);
    } catch {
      throw primaryError;
    }
  }
}

function pluginListForStage(stage) {
  return stageDefs
    .filter(def => def.stage <= stage)
    .map(def => def.plugin());
}

function transformAst(ast, source, stage) {
  return babelCore.transformFromAstSync(ast, source, {
    ast: true,
    code: false,
    babelrc: false,
    configFile: false,
    comments: false,
    cloneInputAst: false,
    plugins: pluginListForStage(stage),
  });
}

function transformFull(ast, source) {
  return transformAst(ast, source, stageDefs.length);
}

function elapsedNs(start) {
  return Number(process.hrtime.bigint() - start);
}

function benchStage(source, stage, warmups, iterations) {
  let elapsed = 0;
  let sink = 0;
  const total = warmups + iterations;

  for (let iter = 0; iter < total; iter += 1) {
    const ast = parseTs(source);

    const start = process.hrtime.bigint();
    const result = transformAst(ast, source, stage);
    const ns = elapsedNs(start);

    sink += (result.ast?.program?.body?.length ?? 0);
    if (iter >= warmups) elapsed += ns;
  }

  process.stdout.write(`stage\t${stage}\t${iterations}\t${elapsed}\t${sink}\n`);
}

function benchPhase(source, warmups, iterations) {
  const total = warmups + iterations;
  let parseNs = 0;
  let pipelineNs = 0;
  let codegenNs = 0;
  let sink = 0;

  for (let iter = 0; iter < total; iter += 1) {
    let start = process.hrtime.bigint();
    const ast = parseTs(source);
    const parseElapsed = elapsedNs(start);

    start = process.hrtime.bigint();
    const transformed = transformFull(ast, source);
    const pipelineElapsed = elapsedNs(start);

    start = process.hrtime.bigint();
    const generated = babelGenerator(transformed.ast, { comments: false }, source);
    const codegenElapsed = elapsedNs(start);

    sink += (generated.code?.length ?? 0) + (transformed.ast?.program?.body?.length ?? 0);

    if (iter >= warmups) {
      parseNs += parseElapsed;
      pipelineNs += pipelineElapsed;
      codegenNs += codegenElapsed;
    }
  }

  process.stdout.write(`phase\t${iterations}\t${parseNs}\t${pipelineNs}\t${codegenNs}\t${sink}\n`);
}

function benchTotal(source, warmups, iterations) {
  let elapsed = 0;
  let sink = 0;
  const total = warmups + iterations;

  for (let iter = 0; iter < total; iter += 1) {
    const start = process.hrtime.bigint();
    const ast = parseTs(source);
    const transformed = transformFull(ast, source);
    const generated = babelGenerator(transformed.ast, { comments: false }, source);
    const ns = elapsedNs(start);

    sink += (generated.code?.length ?? 0) + (transformed.ast?.program?.body?.length ?? 0);
    if (iter >= warmups) elapsed += ns;
  }

  process.stdout.write(`total\t${iterations}\t${elapsed}\t${sink}\n`);
}

function benchOneFile(project, filePath, source, iterations) {
  let parseNs = 0;
  let transformNs = 0;
  let codegenNs = 0;

  for (let iter = 0; iter < iterations; iter += 1) {
    let start = process.hrtime.bigint();
    const ast = parseBatchSource(source, filePath);
    parseNs += elapsedNs(start);

    start = process.hrtime.bigint();
    const transformed = transformFull(ast, source);
    transformNs += elapsedNs(start);

    start = process.hrtime.bigint();
    babelGenerator(transformed.ast, { comments: false }, source);
    codegenNs += elapsedNs(start);
  }

  return {
    project,
    path: filePath,
    bytes: Buffer.byteLength(source),
    parseNs,
    transformNs,
    codegenNs,
    totalNs: parseNs + transformNs + codegenNs,
  };
}

function parseFileList(listSource) {
  return listSource
    .split(/\r?\n/)
    .filter(Boolean)
    .map(line => {
      const [project, version, absolutePath, extra] = line.split("\t");
      if (!project || !version || !absolutePath || extra !== undefined) {
        throw new Error(`invalid file list row: ${line}`);
      }
      return { project, version, absolutePath };
    });
}

function benchFiles(tier, listSource, iterations) {
  const rows = parseFileList(listSource);
  let totalBytes = 0;
  let totalNs = 0;
  const totalRows = [];
  const projectTotals = new Map();

  for (const row of rows) {
    const source = fs.readFileSync(row.absolutePath, "utf8");
    const result = benchOneFile(row.project, row.absolutePath, source, iterations);
    totalBytes += result.bytes;
    totalNs += result.totalNs;
    totalRows.push(result);
    projectTotals.set(row.project, (projectTotals.get(row.project) ?? 0) + result.totalNs);
    process.stdout.write(
      `file\t${result.project}\t${result.path}\t${result.bytes}\t${result.parseNs}\t${result.transformNs}\t${result.codegenNs}\t${result.totalNs}\n`,
    );
  }

  totalRows.sort((a, b) => a.totalNs - b.totalNs);
  const p95Index = Math.max(0, Math.ceil(totalRows.length * 0.95) - 1);
  const p95TotalNs = totalRows.length === 0 ? 0 : totalRows[p95Index].totalNs;
  process.stdout.write(`summary\tfiles\t${rows.length}\ttotal_ns\t${totalNs}\tp95_total_ns\t${p95TotalNs}\n`);
  for (const project of [...projectTotals.keys()].sort()) {
    const fileCount = rows.filter(row => row.project === project).length;
    process.stdout.write(`project\t${project}\tfiles\t${fileCount}\ttotal_ns\t${projectTotals.get(project)}\n`);
  }
}

function usage() {
  process.stderr.write(
    [
      "Usage:",
      "  babel_transform_bench.cjs stage <input.ts> <stage> <warmups> <iterations>",
      "  babel_transform_bench.cjs phase <input.ts> <warmups> <iterations>",
      "  babel_transform_bench.cjs total <input.ts> <warmups> <iterations>",
      "  babel_transform_bench.cjs files <tier> <list.txt> <iterations>",
      "",
    ].join("\n"),
  );
}

function main() {
  const [, , mode, inputPath, ...rest] = process.argv;

  if (!mode) {
    usage();
    process.exitCode = 1;
    return;
  }

  if (mode === "stage") {
    if (rest.length !== 3) {
      usage();
      process.exitCode = 1;
      return;
    }

    const source = fs.readFileSync(inputPath, "utf8");
    const [stageRaw, warmupsRaw, iterationsRaw] = rest;
    benchStage(source, Number(stageRaw), Number(warmupsRaw), Number(iterationsRaw));
    return;
  }

  if (mode === "phase") {
    if (rest.length !== 2) {
      usage();
      process.exitCode = 1;
      return;
    }

    const source = fs.readFileSync(inputPath, "utf8");
    const [warmupsRaw, iterationsRaw] = rest;
    benchPhase(source, Number(warmupsRaw), Number(iterationsRaw));
    return;
  }

  if (mode === "total") {
    if (rest.length !== 2) {
      usage();
      process.exitCode = 1;
      return;
    }

    const source = fs.readFileSync(inputPath, "utf8");
    const [warmupsRaw, iterationsRaw] = rest;
    benchTotal(source, Number(warmupsRaw), Number(iterationsRaw));
    return;
  }

  if (mode === "files") {
    if (rest.length !== 2) {
      usage();
      process.exitCode = 1;
      return;
    }

    const tier = inputPath;
    const [listPath, iterationsRaw] = rest;
    benchFiles(tier, fs.readFileSync(listPath, "utf8"), Number(iterationsRaw));
    return;
  }

  usage();
  process.exitCode = 1;
}

main();
