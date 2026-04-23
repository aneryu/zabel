#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/scripts"
CACHE_DIR="$ROOT/.zig-cache/bench"
ZIG_BENCH_SRC="$SCRIPT_DIR/transform_bench.zig"
ZIG_BENCH_BIN="$CACHE_DIR/transform_bench"
BABEL_BENCH_SRC="$SCRIPT_DIR/babel_transform_bench.cjs"
INPUT_PATH="$CACHE_DIR/transform-bench-input.ts"
DEFAULT_STAGE_LIST="1,2,3,4,5,6,7,8,9"

WARMUPS=1
STAGE_ITERATIONS=1
ITERATIONS=4
BLOCKS=800
GENERATE_INPUT=1
STAGE_LIST="$DEFAULT_STAGE_LIST"
declare -a TELEMETRY_ARGS=()

usage() {
  cat <<'EOF'
Usage: bash scripts/bench-compare.sh [options]

Options:
  --input PATH             Use an existing TypeScript input file.
  --warmups N              Warmup iterations for each benchmark. Default: 1
  --stage-iterations N     Iterations for cumulative stage benchmarks. Default: 1
  --iterations N           Iterations for phase/total benchmarks. Default: 4
  --blocks N               Number of generated TS blocks. Default: 800
  --stages LIST            Comma-separated cumulative stages to run. Default: 1,2,3,4,5,6,7,8,9
  --no-generate            Do not generate a synthetic input file.
  --log-level LEVEL        Forward telemetry log level to the zig benchmark runner.
  --log-format FORMAT      Forward telemetry log format to the zig benchmark runner.
  --log-path PATH          Forward telemetry log path to the zig benchmark runner.
  --trace-level LEVEL      Forward telemetry trace level to the zig benchmark runner.
  --trace-format FORMAT    Forward telemetry trace format to the zig benchmark runner.
  --trace-events-path PATH Forward telemetry events path to the zig benchmark runner.
  --trace-summary-path PATH Forward telemetry summary path to the zig benchmark runner.
  -h, --help               Show this help.

Output:
  Compares zig-babal and local vendor/babel on the same input and prints:
  - stage cumulative timings
  - stage delta timings
  - parse/pipeline/codegen timings
  - end-to-end total timings
EOF
}

log() {
  printf '[compare] %s\n' "$*" >&2
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

  echo "error: neither 'zig' nor 'mise' is available for zig" >&2
  exit 1
}

run_node() {
  if command -v node >/dev/null 2>&1; then
    node "$@"
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
    "$mise_bin" exec -- node "$@"
    return
  fi

  echo "error: neither 'node' nor 'mise' is available for node" >&2
  exit 1
}

format_ms_per_iter() {
  awk -v ns="$1" -v iters="$2" 'BEGIN { printf "%.3f", ns / 1000000 / iters }'
}

format_ratio() {
  awk -v lhs="$1" -v rhs="$2" 'BEGIN {
    if (rhs == 0) {
      printf "inf";
    } else {
      printf "%.3fx", lhs / rhs;
    }
  }'
}

stage_name() {
  case "$1" in
    1) printf 'ts_strip' ;;
    2) printf 'shorthand_properties' ;;
    3) printf 'template_literals' ;;
    4) printf 'computed_properties' ;;
    5) printf 'arrow_functions' ;;
    6) printf 'spread' ;;
    7) printf 'parameters' ;;
    8) printf 'for_of' ;;
    9) printf 'block_scoping' ;;
    *) printf 'unknown' ;;
  esac
}

parse_stage_list() {
  local raw="$1"
  local part
  local -a parsed=()

  IFS=',' read -r -a parsed <<<"$raw"
  if [[ "${#parsed[@]}" -eq 0 ]]; then
    echo "error: empty --stages list" >&2
    exit 1
  fi

  STAGES=()
  for part in "${parsed[@]}"; do
    part="${part//[[:space:]]/}"
    if [[ -z "$part" ]]; then
      echo "error: invalid empty stage in --stages list" >&2
      exit 1
    fi
    if [[ ! "$part" =~ ^[1-9]$ ]]; then
      echo "error: stage must be an integer from 1 to 9, got '$part'" >&2
      exit 1
    fi
    STAGES+=("$part")
  done
}

run_case() {
  local label="$1"
  shift

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/bench-compare.XXXXXX")"

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

run_zig_bench_case() {
  local label="$1"
  shift

  local -a cmd=("$ZIG_BENCH_BIN")
  if [[ ${#TELEMETRY_ARGS[@]} -gt 0 ]]; then
    cmd+=("${TELEMETRY_ARGS[@]}")
  fi
  cmd+=("$@")
  run_case "$label" "${cmd[@]}"
}

generate_input() {
  mkdir -p "$(dirname "$INPUT_PATH")"

  : >"$INPUT_PATH"
  for ((i = 0; i < BLOCKS; i++)); do
    printf '{
  type Item%d = { value: number; label?: string };
  const base%d: number[] = [1, 2, 3, 4, 5];
  const seed%d: number = %d;
  const mapper%d = (n: number, extra = seed%d, ...rest: number[]): string => {
    const arr = [n, ...base%d, extra];
    let total = 0;
    for (const value of arr) {
      let local = value + extra;
      total += local;
    }
    const obj = { n, extra, total, [`k${n}`]: `%d-${total}`, text: `%d-${n + extra}` };
    return `%d-${obj.text}-${rest.length}`;
  };
  const out%d: Item%d = { value: seed%d, label: mapper%d(...base%d) };
}

' \
      "$i" "$i" "$i" "$i" "$i" "$i" "$i" "$i" "$i" "$i" "$i" "$i" "$i" >>"$INPUT_PATH"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_PATH="$2"
      shift 2
      ;;
    --warmups)
      WARMUPS="$2"
      shift 2
      ;;
    --stage-iterations)
      STAGE_ITERATIONS="$2"
      shift 2
      ;;
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    --blocks)
      BLOCKS="$2"
      shift 2
      ;;
    --stages)
      STAGE_LIST="$2"
      shift 2
      ;;
    --no-generate)
      GENERATE_INPUT=0
      shift
      ;;
    --log-level|--log-format|--log-path|--trace-level|--trace-format|--trace-events-path|--trace-summary-path)
      TELEMETRY_ARGS+=("$1" "$2")
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

if [[ "$GENERATE_INPUT" -eq 1 ]]; then
  generate_input
elif [[ ! -f "$INPUT_PATH" ]]; then
  echo "error: input file not found: $INPUT_PATH" >&2
  exit 1
fi

declare -a STAGES=()
parse_stage_list "$STAGE_LIST"

mkdir -p "$CACHE_DIR"
log "compiling zig benchmark runner"
run_zig build-exe \
  --dep zig_babal \
  -Mroot="$ZIG_BENCH_SRC" \
  -Mzig_babal="$ROOT/src/root.zig" \
  -O ReleaseFast \
  -femit-bin="$ZIG_BENCH_BIN"
log "compiled zig benchmark runner"

INPUT_BYTES="$(wc -c < "$INPUT_PATH" | tr -d '[:space:]')"
log "input: $INPUT_PATH (${INPUT_BYTES} bytes)"
log "warmups=$WARMUPS stage_iterations=$STAGE_ITERATIONS iterations=$ITERATIONS stages=$STAGE_LIST"

declare -a stage_rows=()
declare -a zig_stage_raw_rows=()
declare -a babel_stage_raw_rows=()
prev_zig_ns=0
prev_babel_ns=0

for stage in "${STAGES[@]}"; do
  name="$(stage_name "$stage")"
  zig_raw="$(run_zig_bench_case "zig stage ${stage} cumulative (${name})" stage "$INPUT_PATH" "$stage" "$WARMUPS" "$STAGE_ITERATIONS")"
  babel_raw="$(run_case "babel stage ${stage} cumulative (${name})" run_node "$BABEL_BENCH_SRC" stage "$INPUT_PATH" "$stage" "$WARMUPS" "$STAGE_ITERATIONS")"

  IFS=$'\t' read -r _ zig_stage_num zig_stage_iters zig_stage_ns _ <<<"$zig_raw"
  IFS=$'\t' read -r _ babel_stage_num babel_stage_iters babel_stage_ns _ <<<"$babel_raw"

  zig_delta_ns=$((zig_stage_ns - prev_zig_ns))
  babel_delta_ns=$((babel_stage_ns - prev_babel_ns))

  stage_rows+=("$(printf '  %s %-22s zig_cumulative=%9s ms/iter  babel_cumulative=%9s ms/iter  zig_delta=%9s ms/iter  babel_delta=%9s ms/iter  zig_div_babel=%7s' \
    "$stage" \
    "$name" \
    "$(format_ms_per_iter "$zig_stage_ns" "$zig_stage_iters")" \
    "$(format_ms_per_iter "$babel_stage_ns" "$babel_stage_iters")" \
    "$(format_ms_per_iter "$zig_delta_ns" "$zig_stage_iters")" \
    "$(format_ms_per_iter "$babel_delta_ns" "$babel_stage_iters")" \
    "$(format_ratio "$zig_stage_ns" "$babel_stage_ns")")")

  zig_stage_raw_rows+=("  $zig_raw")
  babel_stage_raw_rows+=("  $babel_raw")
  prev_zig_ns="$zig_stage_ns"
  prev_babel_ns="$babel_stage_ns"
done

zig_phase_raw="$(run_zig_bench_case "zig phase breakdown" phase "$INPUT_PATH" "$WARMUPS" "$ITERATIONS")"
babel_phase_raw="$(run_case "babel phase breakdown" run_node "$BABEL_BENCH_SRC" phase "$INPUT_PATH" "$WARMUPS" "$ITERATIONS")"
zig_total_raw="$(run_zig_bench_case "zig total transform" total "$INPUT_PATH" "$WARMUPS" "$ITERATIONS")"
babel_total_raw="$(run_case "babel total transform" run_node "$BABEL_BENCH_SRC" total "$INPUT_PATH" "$WARMUPS" "$ITERATIONS")"

IFS=$'\t' read -r _ zig_phase_iters zig_parse_ns zig_pipeline_ns zig_codegen_ns _ <<<"$zig_phase_raw"
IFS=$'\t' read -r _ babel_phase_iters babel_parse_ns babel_pipeline_ns babel_codegen_ns _ <<<"$babel_phase_raw"
IFS=$'\t' read -r _ zig_total_iters zig_total_ns _ <<<"$zig_total_raw"
IFS=$'\t' read -r _ babel_total_iters babel_total_ns _ <<<"$babel_total_raw"

phase_rows="$(cat <<EOF
  parse_only                     zig=$(format_ms_per_iter "$zig_parse_ns" "$zig_phase_iters") ms/iter  babel=$(format_ms_per_iter "$babel_parse_ns" "$babel_phase_iters") ms/iter  zig_div_babel=$(format_ratio "$zig_parse_ns" "$babel_parse_ns")
  pipeline_run_full              zig=$(format_ms_per_iter "$zig_pipeline_ns" "$zig_phase_iters") ms/iter  babel=$(format_ms_per_iter "$babel_pipeline_ns" "$babel_phase_iters") ms/iter  zig_div_babel=$(format_ratio "$zig_pipeline_ns" "$babel_pipeline_ns")
  codegen_only                   zig=$(format_ms_per_iter "$zig_codegen_ns" "$zig_phase_iters") ms/iter  babel=$(format_ms_per_iter "$babel_codegen_ns" "$babel_phase_iters") ms/iter  zig_div_babel=$(format_ratio "$zig_codegen_ns" "$babel_codegen_ns")
EOF
)"

total_row="$(printf '  parse_plus_pipeline_plus_codegen zig=%9s ms/iter  babel=%9s ms/iter  zig_div_babel=%7s' \
  "$(format_ms_per_iter "$zig_total_ns" "$zig_total_iters")" \
  "$(format_ms_per_iter "$babel_total_ns" "$babel_total_iters")" \
  "$(format_ratio "$zig_total_ns" "$babel_total_ns")")"

cat <<EOF
Input: $INPUT_PATH
Size: ${INPUT_BYTES} bytes
Stage iterations: $STAGE_ITERATIONS
Phase/total iterations: $ITERATIONS
Warmups: $WARMUPS

Stage comparison:
$(printf '%s\n' "${stage_rows[@]}")

Phase comparison:
${phase_rows}

Total comparison:
${total_row}

Raw zig:
$(printf '%s\n' "${zig_stage_raw_rows[@]}")
  $zig_phase_raw
  $zig_total_raw

Raw babel:
$(printf '%s\n' "${babel_stage_raw_rows[@]}")
  $babel_phase_raw
  $babel_total_raw
EOF
