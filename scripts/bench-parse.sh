#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/scripts"
CACHE_DIR="$ROOT/.zig-cache/bench"
BENCH_SRC="$SCRIPT_DIR/parse_bench.zig"
BENCH_BIN="$CACHE_DIR/parse_bench"

WARMUPS=1
ITERATIONS=5
COMMENTS_MODE="deferred"
CASE_NAME="all"
CUSTOM_INPUT=""
CUSTOM_LANGUAGE=""
CUSTOM_SOURCE_TYPE=""

usage() {
  cat <<'EOF'
Usage: bash scripts/bench-parse.sh [options]

Options:
  --case NAME              Run one default case: js | jsx | ts | tsx | flow | all
  --input PATH             Run a custom input instead of default cases.
  --language LANG          Required with --input. One of: javascript | jsx | typescript | tsx | flow
  --module                 Use module source type for --input.
  --script                 Use script source type for --input.
  --comments MODE          Comment mode: deferred | default. Default: deferred
  --warmups N              Warmup iterations. Default: 1
  --iterations N           Timed iterations. Default: 5
  -h, --help               Show this help.

Default cases:
  js   -> regenerator-tests input.js (script)
  jsx  -> jsx/comments input.js (script)
  ts   -> real-world-babel-file2 input.ts (module)
  tsx  -> variance-annotations-with-jsx input.tsx (module)
  flow -> flow/type-annotations input.js (module)
EOF
}

run_zig() {
  if command -v zig >/dev/null 2>&1; then
    zig "$@"
    return
  fi

  local mise_bin=""

  if command -v mise >/dev/null 2>&1; then
    mise_bin="$(command -v mise)"
  elif [[ -x "$HOME/.local/bin/mise" ]]; then
    mise_bin="$HOME/.local/bin/mise"
  elif [[ -x /opt/homebrew/bin/mise ]]; then
    mise_bin=/opt/homebrew/bin/mise
  elif [[ -x /usr/local/bin/mise ]]; then
    mise_bin=/usr/local/bin/mise
  fi

  if [[ -n "$mise_bin" ]]; then
    "$mise_bin" exec -- zig "$@"
    return
  fi

  echo "error: neither 'zig' nor 'mise' is available in PATH" >&2
  exit 1
}

format_ms_per_iter() {
  awk -v ns="$1" -v iters="$2" 'BEGIN { printf "%.3f", ns / 1000000 / iters }'
}

log() {
  printf '[bench] %s\n' "$*" >&2
}

run_case() {
  local label="$1"
  shift

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/parse-bench.XXXXXX")"

  log "running ${label}"
  if "$@" >"$tmp"; then
    log "finished ${label}"
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi

  local status=$?
  rm -f "$tmp"
  return "$status"
}

default_case_spec() {
  case "$1" in
    js)
      printf '%s\t%s\t%s\t%s\n' \
        "js" \
        "$ROOT/vendor/babel/packages/babel-plugin-transform-regenerator/test/fixtures/misc/regenerator-tests/input.js" \
        "javascript" \
        "script"
      ;;
    jsx)
      printf '%s\t%s\t%s\t%s\n' \
        "jsx" \
        "$ROOT/vendor/babel/packages/babel-generator/test/fixtures/jsx/comments/input.js" \
        "jsx" \
        "script"
      ;;
    ts)
      printf '%s\t%s\t%s\t%s\n' \
        "ts" \
        "$ROOT/vendor/babel/packages/babel-generator/test/fixtures/sourcemaps/real-world-babel-file2/input.ts" \
        "typescript" \
        "module"
      ;;
    tsx)
      printf '%s\t%s\t%s\t%s\n' \
        "tsx" \
        "$ROOT/vendor/babel/packages/babel-parser/test/fixtures/typescript/types/variance-annotations-with-jsx/input.tsx" \
        "tsx" \
        "module"
      ;;
    flow)
      printf '%s\t%s\t%s\t%s\n' \
        "flow" \
        "$ROOT/vendor/babel/packages/babel-generator/test/fixtures/flow/type-annotations/input.js" \
        "flow" \
        "module"
      ;;
    *)
      echo "error: unknown case '$1'" >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --case)
      CASE_NAME="$2"
      shift 2
      ;;
    --input)
      CUSTOM_INPUT="$2"
      shift 2
      ;;
    --language)
      CUSTOM_LANGUAGE="$2"
      shift 2
      ;;
    --module)
      CUSTOM_SOURCE_TYPE="module"
      shift
      ;;
    --script)
      CUSTOM_SOURCE_TYPE="script"
      shift
      ;;
    --comments)
      COMMENTS_MODE="$2"
      shift 2
      ;;
    --warmups)
      WARMUPS="$2"
      shift 2
      ;;
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$COMMENTS_MODE" != "deferred" && "$COMMENTS_MODE" != "default" ]]; then
  echo "error: --comments must be 'deferred' or 'default'" >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"
log "compiling parse benchmark runner"
run_zig build-exe \
  --dep zig_babal \
  -Mroot="$BENCH_SRC" \
  -Mzig_babal="$ROOT/src/root.zig" \
  -O ReleaseFast \
  -femit-bin="$BENCH_BIN"
log "compiled parse benchmark runner"

declare -a labels=()
declare -a inputs=()
declare -a languages=()
declare -a source_types=()

if [[ -n "$CUSTOM_INPUT" ]]; then
  if [[ -z "$CUSTOM_LANGUAGE" ]]; then
    echo "error: --language is required with --input" >&2
    exit 1
  fi
  if [[ -z "$CUSTOM_SOURCE_TYPE" ]]; then
    CUSTOM_SOURCE_TYPE="module"
  fi
  labels+=("custom")
  inputs+=("$CUSTOM_INPUT")
  languages+=("$CUSTOM_LANGUAGE")
  source_types+=("$CUSTOM_SOURCE_TYPE")
else
  declare -a case_names=()
  if [[ "$CASE_NAME" == "all" ]]; then
    case_names=(js jsx ts tsx flow)
  else
    case_names=("$CASE_NAME")
  fi

  for case_name in "${case_names[@]}"; do
    IFS=$'\t' read -r label input_path language source_type < <(default_case_spec "$case_name")
    labels+=("$label")
    inputs+=("$input_path")
    languages+=("$language")
    source_types+=("$source_type")
  done
fi

declare -a rows=()
declare -a raw_rows=()

for i in "${!labels[@]}"; do
  label="${labels[$i]}"
  input_path="${inputs[$i]}"
  language="${languages[$i]}"
  source_type="${source_types[$i]}"

  if [[ ! -f "$input_path" ]]; then
    echo "error: input file not found: $input_path" >&2
    exit 1
  fi

  input_bytes="$(wc -c < "$input_path" | tr -d '[:space:]')"
  raw="$(run_case "parse ${label}" "$BENCH_BIN" "$input_path" "$language" "$source_type" "$COMMENTS_MODE" "$WARMUPS" "$ITERATIONS")"
  IFS=$'\t' read -r _ iters elapsed_ns sink <<<"$raw"

  rows+=("  ${label} language=${language} source_type=${source_type} comments=${COMMENTS_MODE} size=${input_bytes}B parse_only=$(format_ms_per_iter "$elapsed_ns" "$iters") ms/iter")
  raw_rows+=("  ${label}\t${raw}")
done

cat <<EOF
Iterations: $ITERATIONS
Warmups: $WARMUPS
Comments mode: $COMMENTS_MODE

Case breakdown:
$(printf '%s\n' "${rows[@]}")

Raw:
$(printf '%s\n' "${raw_rows[@]}")
EOF
