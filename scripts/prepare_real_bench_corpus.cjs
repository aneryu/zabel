"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function loadCorpusLock(lockPath) {
  return JSON.parse(fs.readFileSync(lockPath, "utf8"));
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

function resolveRowPath(extractedDir, row) {
  return path.join(extractedDir, `${row.project}@${row.version}`, row.root, row.path);
}

async function validateResolvedRows(rows) {
  for (const row of rows) {
    try {
      await fs.promises.access(row.resolvedPath, fs.constants.R_OK);
    } catch (error) {
      if (error && error.code === "ENOENT") {
        throw new Error(
          `missing corpus file: ${row.project}@${row.version} ${row.path} -> ${row.resolvedPath}`,
        );
      }
      throw error;
    }
  }
}

async function prepareCorpus({
  repoRoot,
  lockPath,
  tier,
  offline = false,
  validateResolvedFiles = !offline,
}) {
  const lock = loadCorpusLock(lockPath);
  const rows = buildTierFileList(lock, tier);
  const baseDir = path.join(repoRoot, ".zig-cache/bench/corpus");
  const extractedDir = path.join(baseDir, "src");
  const tarballDir = path.join(baseDir, "tarballs");
  const listPath = path.join(baseDir, `${tier}.txt`);

  await fs.promises.mkdir(extractedDir, { recursive: true });
  await fs.promises.mkdir(tarballDir, { recursive: true });

  for (const pkg of lock.packages) {
    const projectDir = path.join(extractedDir, `${pkg.project}@${pkg.version}`);
    const packageDir = path.join(projectDir, pkg.root);
    if (!offline) {
      await ensurePackageExtracted(pkg, projectDir, tarballDir);
    } else {
      await fs.promises.mkdir(packageDir, { recursive: true });
    }
  }

  const resolvedRows = rows.map(row => ({
    ...row,
    resolvedPath: resolveRowPath(extractedDir, row),
  }));
  if (validateResolvedFiles) {
    await validateResolvedRows(resolvedRows);
  }

  const lines = resolvedRows.map(row => `${row.project}\t${row.version}\t${row.resolvedPath}`);
  await fs.promises.writeFile(listPath, `${lines.join("\n")}\n`);

  return {
    tier,
    listPath,
    files: rows.length,
  };
}

async function ensurePackageExtracted(pkg, projectDir, tarballDir) {
  const packageDir = path.join(projectDir, pkg.root);
  const tarballPath = path.join(tarballDir, `${pkg.project}@${pkg.version}.tgz`);

  if (await directoryHasEntries(packageDir)) {
    return;
  }

  await fs.promises.mkdir(projectDir, { recursive: true });
  await downloadTarball(pkg.tarball, tarballPath);

  const result = spawnSync("tar", ["-xzf", tarballPath, "-C", projectDir], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(result.stderr || "failed to extract corpus tarball");
  }
}

async function directoryHasEntries(dirPath) {
  try {
    const entries = await fs.promises.readdir(dirPath);
    return entries.length > 0;
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

async function downloadTarball(url, tarballPath) {
  if (fs.existsSync(tarballPath)) {
    return;
  }

  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`failed to download ${url}: ${response.status} ${response.statusText}`);
  }

  const bytes = Buffer.from(await response.arrayBuffer());
  await fs.promises.writeFile(tarballPath, bytes);
}

function printUsage() {
  process.stderr.write(
    [
      "Usage:",
      "  prepare_real_bench_corpus.cjs --tier <smoke|core|full> [--repo-root PATH] [--lock-path PATH] [--offline]",
      "",
    ].join("\n"),
  );
}

async function main() {
  const repoRoot = path.resolve(__dirname, "..");
  let tier = null;
  let rootDir = repoRoot;
  let lockPath = null;
  let offline = false;

  for (let i = 2; i < process.argv.length; i += 1) {
    const arg = process.argv[i];
    if (arg === "--tier") {
      tier = process.argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--repo-root") {
      rootDir = process.argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--lock-path") {
      lockPath = process.argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--offline") {
      offline = true;
      continue;
    }
    printUsage();
    throw new Error(`unknown argument: ${arg}`);
  }

  if (!tier) {
    printUsage();
    throw new Error("missing required --tier");
  }

  if (!lockPath) {
    lockPath = path.join(rootDir, "bench/corpus.lock.json");
  }

  const result = await prepareCorpus({
    repoRoot: rootDir,
    lockPath,
    tier,
    offline,
  });
  process.stdout.write(`prepared\t${result.tier}\t${result.files}\t${result.listPath}\n`);
}

module.exports = {
  loadCorpusLock,
  buildTierFileList,
  prepareCorpus,
};

if (require.main === module) {
  main().catch(error => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
