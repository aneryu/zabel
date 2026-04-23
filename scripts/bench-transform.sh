#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/scripts"
CACHE_DIR="$ROOT/.zig-cache/bench"
BENCH_SRC="$SCRIPT_DIR/transform_bench.zig"
BENCH_BIN="$CACHE_DIR/transform_bench"
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
Usage: bash scripts/bench-transform.sh [options]

Options:
  --input PATH             Use an existing TypeScript input file.
  --warmups N              Warmup iterations for each benchmark. Default: 1
  --stage-iterations N     Iterations for cumulative stage benchmarks. Default: 1
  --iterations N           Iterations for phase/total benchmarks. Default: 4
  --blocks N               Number of generated TS blocks. Default: 800
  --stages LIST            Comma-separated cumulative stages to run. Default: 1,2,3,4,5,6,7,8,9
  --no-generate            Do not generate a synthetic input file.
  --log-level LEVEL        Forward telemetry log level to the benchmark runner.
  --log-format FORMAT      Forward telemetry log format to the benchmark runner.
  --log-path PATH          Forward telemetry log path to the benchmark runner.
  --trace-level LEVEL      Forward telemetry trace level to the benchmark runner.
  --trace-format FORMAT    Forward telemetry trace format to the benchmark runner.
  --trace-events-path PATH Forward telemetry events path to the benchmark runner.
  --trace-summary-path PATH Forward telemetry summary path to the benchmark runner.
  -h, --help               Show this help.

Environment:
  Uses `zig` from PATH when available.
  Falls back to `mise exec -- zig ...` when `zig` is not directly available.
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

format_ms() {
  awk -v ns="$1" 'BEGIN { printf "%.3f", ns / 1000000 }'
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
  tmp="$(mktemp "${TMPDIR:-/tmp}/transform-bench.XXXXXX")"

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

run_bench_case() {
  local label="$1"
  shift

  local -a cmd=("$BENCH_BIN")
  if (( ${#TELEMETRY_ARGS[@]} )); then
    cmd+=("${TELEMETRY_ARGS[@]}")
  fi
  cmd+=("$@")

  run_case "$label" "${cmd[@]}"
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
log "compiling benchmark runner"
run_zig build-exe \
  --dep zig_babal \
  -Mroot="$BENCH_SRC" \
  -Mzig_babal="$ROOT/src/root.zig" \
  -O ReleaseFast \
  -femit-bin="$BENCH_BIN"
log "compiled benchmark runner"

INPUT_BYTES="$(wc -c < "$INPUT_PATH" | tr -d '[:space:]')"
log "input: $INPUT_PATH (${INPUT_BYTES} bytes)"
log "warmups=$WARMUPS stage_iterations=$STAGE_ITERATIONS iterations=$ITERATIONS stages=$STAGE_LIST"

declare -a stage_rows=()
declare -a stage_raw_rows=()
prev_stage_ns=0

for stage in "${STAGES[@]}"; do
  name="$(stage_name "$stage")"
  raw="$(run_bench_case "stage ${stage} cumulative (${name})" stage "$INPUT_PATH" "$stage" "$WARMUPS" "$STAGE_ITERATIONS")"
  IFS=$'\t' read -r _ stage_num stage_iters stage_ns _ <<<"$raw"

  delta_ns=$((stage_ns - prev_stage_ns))
  stage_rows+=("$(printf '  %s %-22s cumulative=%9s ms/iter  delta=%9s ms/iter  iterations=%s' \
    "$stage_num" \
    "$name" \
    "$(format_ms_per_iter "$stage_ns" "$stage_iters")" \
    "$(format_ms_per_iter "$delta_ns" "$stage_iters")" \
    "$stage_iters")")
  stage_raw_rows+=("  $raw")
  prev_stage_ns="$stage_ns"
done

phase_raw="$(run_bench_case "phase breakdown" phase "$INPUT_PATH" "$WARMUPS" "$ITERATIONS")"
total_raw="$(run_bench_case "total transform" total "$INPUT_PATH" "$WARMUPS" "$ITERATIONS")"
profile_raw="$(run_bench_case "pass profile" profile "$INPUT_PATH" "$WARMUPS" "$ITERATIONS")"

IFS=$'\t' read -r _ phase_iters parse_ns pipeline_ns codegen_ns _ <<<"$phase_raw"
IFS=$'\t' read -r _ total_iters total_ns _ <<<"$total_raw"

profile_header=""
declare -a profile_rows=()
while IFS=$'\t' read -r kind a b c d; do
  if [[ "$kind" == "profile" ]]; then
    profile_header="$(printf '  pipeline_full=%9s ms/iter  scope_analysis=%9s ms/iter  iterations=%s' \
      "$(format_ms_per_iter "$b" "$a")" \
      "$(format_ms_per_iter "$c" "$a")" \
      "$a")"
  elif [[ "$kind" == "pass" ]]; then
    profile_rows+=("$(printf '  %-22s total=%9s ms/iter  enter=%s  exit=%s' \
      "$a" \
      "$(format_ms_per_iter "$b" "$ITERATIONS")" \
      "$c" \
      "$d")")
  fi
done <<<"$profile_raw"

cat <<EOF
Input: $INPUT_PATH
Size: ${INPUT_BYTES} bytes
Stage iterations: $STAGE_ITERATIONS
Phase/total iterations: $ITERATIONS
Warmups: $WARMUPS

Stage breakdown:
$(printf '%s\n' "${stage_rows[@]}")

Phase breakdown:
  parse_only: $(format_ms_per_iter "$parse_ns" "$phase_iters") ms/iter
  pipeline_run_full: $(format_ms_per_iter "$pipeline_ns" "$phase_iters") ms/iter
  codegen_only: $(format_ms_per_iter "$codegen_ns" "$phase_iters") ms/iter

Total:
  parse_plus_pipeline_plus_codegen: $(format_ms_per_iter "$total_ns" "$total_iters") ms/iter

Pass hotspots:
$profile_header
$(printf '%s\n' "${profile_rows[@]}")

Raw:
$(printf '%s\n' "${stage_raw_rows[@]}")
  $phase_raw
  $total_raw
  $profile_raw
EOF
