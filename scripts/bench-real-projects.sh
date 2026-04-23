#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$ROOT/.zig-cache/bench"
TIER="core"
OFFLINE=0
PROFILE_TOP=0

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

usage() {
  cat <<'EOF'
Usage: bash scripts/bench-real-projects.sh [--tier smoke|core|full] [--offline] [--profile-top N]
EOF
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

numeric_ratio() {
  awk -v lhs="$1" -v rhs="$2" 'BEGIN {
    if (rhs == 0) {
      printf "1e18";
    } else {
      printf "%.12f", lhs / rhs;
    }
  }'
}

summary_value() {
  local tsv_path="$1"
  local key="$2"

  awk -F'\t' -v key="$key" '
    $1 == "summary" {
      for (i = 2; i < NF; i += 1) {
        if ($i == key) {
          print $(i + 1)
          exit
        }
      }
    }
  ' "$tsv_path"
}

project_names() {
  local tsv_path="$1"
  awk -F'\t' '$1 == "project" { print $2 }' "$tsv_path"
}

project_total_ns() {
  local tsv_path="$1"
  local project_name="$2"

  awk -F'\t' -v project_name="$project_name" '
    $1 == "project" && $2 == project_name {
      for (i = 3; i < NF; i += 1) {
        if ($i == "total_ns") {
          print $(i + 1)
          exit
        }
      }
    }
  ' "$tsv_path"
}

file_total_ns() {
  local tsv_path="$1"
  local project_name="$2"
  local file_path="$3"

  awk -F'\t' -v project_name="$project_name" -v file_path="$file_path" '
    $1 == "file" && $2 == project_name && $3 == file_path {
      print $8
      exit
    }
  ' "$tsv_path"
}

phase_total_ns() {
  local tsv_path="$1"
  local phase_name="$2"
  local field_index=""

  case "$phase_name" in
    parse) field_index=5 ;;
    transform) field_index=6 ;;
    codegen) field_index=7 ;;
    *)
      echo "error: unknown phase '$phase_name'" >&2
      exit 1
      ;;
  esac

  awk -F'\t' -v field_index="$field_index" '
    $1 == "file" {
      total += $field_index
    }
    END {
      print total + 0
    }
  ' "$tsv_path"
}

print_phase_report() {
  local zig_tsv="$1"
  local babel_tsv="$2"
  local phase_name

  for phase_name in parse transform codegen; do
    local zig_phase_total
    local babel_phase_total
    zig_phase_total="$(phase_total_ns "$zig_tsv" "$phase_name")"
    babel_phase_total="$(phase_total_ns "$babel_tsv" "$phase_name")"
    printf 'phase\t%s\tzig_total_ns\t%s\tbabel_total_ns\t%s\tratio\t%s\n' \
      "$phase_name" \
      "$zig_phase_total" \
      "$babel_phase_total" \
      "$(format_ratio "$babel_phase_total" "$zig_phase_total")"
  done
}

print_slowest_files_report() {
  local zig_tsv="$1"
  local babel_tsv="$2"
  local limit="${3:-5}"

  awk -F'\t' '$1 == "file" { print $2 "\t" $3 "\t" $8 }' "$zig_tsv" \
    | sort -t$'\t' -k3,3nr \
    | head -n "$limit" \
    | while IFS=$'\t' read -r project_name file_path zig_total; do
        [[ -n "$project_name" ]] || continue
        local babel_total
        babel_total="$(file_total_ns "$babel_tsv" "$project_name" "$file_path")"
        printf 'file\t%s\t%s\tzig_total_ns\t%s\tbabel_total_ns\t%s\tratio\t%s\n' \
          "$project_name" \
          "$file_path" \
          "$zig_total" \
          "$babel_total" \
          "$(format_ratio "$babel_total" "$zig_total")"
      done
}

print_highest_ratio_files_report() {
  local zig_tsv="$1"
  local babel_tsv="$2"
  local limit="${3:-5}"

  awk -F'\t' '$1 == "file" { print $2 "\t" $3 "\t" $8 }' "$zig_tsv" \
    | while IFS=$'\t' read -r project_name file_path zig_total; do
        [[ -n "$project_name" ]] || continue
        local babel_total
        local raw_ratio
        babel_total="$(file_total_ns "$babel_tsv" "$project_name" "$file_path")"
        raw_ratio="$(numeric_ratio "$babel_total" "$zig_total")"
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$raw_ratio" \
          "$project_name" \
          "$file_path" \
          "$zig_total" \
          "$babel_total"
      done \
    | sort -t$'\t' -k1,1nr -k2,2 -k3,3 \
    | head -n "$limit" \
    | while IFS=$'\t' read -r raw_ratio project_name file_path zig_total babel_total; do
        printf 'ratio_file\t%s\t%s\tzig_total_ns\t%s\tbabel_total_ns\t%s\tratio\t%s\n' \
          "$project_name" \
          "$file_path" \
          "$zig_total" \
          "$babel_total" \
          "$(format_ratio "$babel_total" "$zig_total")"
      done
}

top_zig_files() {
  local tsv_path="$1"
  local limit="$2"

  awk -F'\t' '$1 == "file" { print $8 "\t" $2 "\t" $3 }' "$tsv_path" \
    | sort -t$'\t' -k1,1nr -k2,2 -k3,3 \
    | head -n "$limit"
}

print_profile_report() {
  local zig_tsv="$1"
  local profile_tsv="$2"
  local limit="$3"

  top_zig_files "$zig_tsv" "$limit" \
    | while IFS=$'\t' read -r zig_total project_name file_path; do
        [[ -n "$project_name" ]] || continue
        printf 'hotspot\t%s\t%s\tzig_total_ns\t%s\n' "$project_name" "$file_path" "$zig_total"
        awk -F'\t' -v project_name="$project_name" -v file_path="$file_path" '
          $2 == project_name && $3 == file_path { print }
        ' "$profile_tsv"
      done
}

print_live_profile_report() {
  local zig_tsv="$1"
  local limit="$2"

  top_zig_files "$zig_tsv" "$limit" \
    | while IFS=$'\t' read -r zig_total project_name file_path; do
        [[ -n "$project_name" ]] || continue
        printf 'hotspot\t%s\t%s\tzig_total_ns\t%s\n' "$project_name" "$file_path" "$zig_total"
        "$CACHE_DIR/transform_bench" profile-file "$project_name" "$file_path" 0 1 </dev/null
      done
}

print_comparison_report() {
  local tier="$1"
  local zig_tsv="$2"
  local babel_tsv="$3"

  local zig_files
  local zig_total
  local babel_total
  zig_files="$(summary_value "$zig_tsv" "files")"
  zig_total="$(summary_value "$zig_tsv" "total_ns")"
  babel_total="$(summary_value "$babel_tsv" "total_ns")"

  printf 'summary\t%s\tfiles\t%s\tzig_total_ns\t%s\tbabel_total_ns\t%s\tratio\t%s\n' \
    "$tier" \
    "$zig_files" \
    "$zig_total" \
    "$babel_total" \
    "$(format_ratio "$babel_total" "$zig_total")"

  while IFS= read -r project_name; do
    [[ -n "$project_name" ]] || continue
    local zig_project_total
    local babel_project_total
    zig_project_total="$(project_total_ns "$zig_tsv" "$project_name")"
    babel_project_total="$(project_total_ns "$babel_tsv" "$project_name")"
    printf 'project\t%s\tzig_total_ns\t%s\tbabel_total_ns\t%s\tratio\t%s\n' \
      "$project_name" \
      "$zig_project_total" \
      "$babel_project_total" \
      "$(format_ratio "$babel_project_total" "$zig_project_total")"
  done < <({ project_names "$zig_tsv"; project_names "$babel_tsv"; } | sort -u)

  print_phase_report "$zig_tsv" "$babel_tsv"
  print_slowest_files_report "$zig_tsv" "$babel_tsv" 5
  print_highest_ratio_files_report "$zig_tsv" "$babel_tsv" 5
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tier)
        TIER="$2"
        shift 2
        ;;
      --offline)
        OFFLINE=1
        shift
        ;;
      --profile-top)
        PROFILE_TOP="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        echo "error: unknown argument '$1'" >&2
        exit 1
        ;;
    esac
  done

  mkdir -p "$CACHE_DIR"

  prepare_args=("$ROOT/scripts/prepare_real_bench_corpus.cjs" "--tier" "$TIER")
  if (( OFFLINE )); then
    prepare_args+=("--offline")
  fi
  run_node "${prepare_args[@]}"

  run_zig build-exe --dep zig_babal -Mroot="$ROOT/scripts/transform_bench.zig" -Mzig_babal="$ROOT/src/root.zig" -O ReleaseFast -femit-bin="$CACHE_DIR/transform_bench"

  "$CACHE_DIR/transform_bench" files "$TIER" "$ROOT/.zig-cache/bench/corpus/${TIER}.txt" 1 > "$CACHE_DIR/${TIER}-zig.tsv"
  run_node "$ROOT/scripts/babel_transform_bench.cjs" files "$TIER" "$ROOT/.zig-cache/bench/corpus/${TIER}.txt" 1 > "$CACHE_DIR/${TIER}-babel.tsv"

  print_comparison_report "$TIER" "$CACHE_DIR/${TIER}-zig.tsv" "$CACHE_DIR/${TIER}-babel.tsv"
  if (( PROFILE_TOP > 0 )); then
    print_live_profile_report "$CACHE_DIR/${TIER}-zig.tsv" "$PROFILE_TOP"
  fi
  printf 'zig\t%s\n' "$CACHE_DIR/${TIER}-zig.tsv"
  printf 'babel\t%s\n' "$CACHE_DIR/${TIER}-babel.tsv"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
