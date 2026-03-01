#!/usr/bin/env bash
# Comparison benchmark:
#   - code-shape index search (Criterion)
#   - lsp_workspace_symbols baseline (linear symbol scan, Criterion)
#   - live_grep (ripgrep over generated corpus)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="${PROJECT_ROOT}/rust"
RESULTS_DIR="${SCRIPT_DIR}/results"
DATASET_ROOT="${RESULTS_DIR}/datasets"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

SAMPLE_SIZE=100
ITERATIONS=100
WARMUP=5
QUERY="fetchData"
OUTPUT_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
  cat <<'EOF'
Usage: run-comparison.sh [OPTIONS]

Options:
  -n, --sample-size N    Criterion sample size for code-shape/LSP baseline (default: 100)
  -i, --iterations N     Iterations for live_grep timing (default: 100)
  -w, --warmup N         Warmup iterations for live_grep (default: 5)
  -q, --query QUERY      Query used across all tools (default: fetchData)
  -o, --output FILE      Output JSON path (default: benchmark/results/comparison_<timestamp>.json)
  -h, --help             Show this help

Profiles (fixed):
  - 100k LOC  (200 files, 50 symbols/file)
  - 500k LOC  (500 files, 100 symbols/file)
  - 1M LOC    (1000 files, 100 symbols/file)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--sample-size)
        SAMPLE_SIZE="$2"
        shift 2
        ;;
      -i|--iterations)
        ITERATIONS="$2"
        shift 2
        ;;
      -w|--warmup)
        WARMUP="$2"
        shift 2
        ;;
      -q|--query)
        QUERY="$2"
        shift 2
        ;;
      -o|--output)
        OUTPUT_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

profile_to_loc() {
  case "$1" in
    100k_loc) echo "100k" ;;
    500k_loc) echo "500k" ;;
    1m_loc) echo "1M" ;;
    *) return 1 ;;
  esac
}

profile_to_files() {
  case "$1" in
    100k_loc) echo 200 ;;
    500k_loc) echo 500 ;;
    1m_loc) echo 1000 ;;
    *) return 1 ;;
  esac
}

profile_to_symbols_per_file() {
  case "$1" in
    100k_loc) echo 50 ;;
    500k_loc) echo 100 ;;
    1m_loc) echo 100 ;;
    *) return 1 ;;
  esac
}

profile_to_lines_per_file() {
  case "$1" in
    100k_loc) echo 500 ;;
    500k_loc) echo 1000 ;;
    1m_loc) echo 1000 ;;
    *) return 1 ;;
  esac
}

profile_to_symbols() {
  case "$1" in
    100k_loc) echo 10000 ;;
    500k_loc) echo 50000 ;;
    1m_loc) echo 100000 ;;
    *) return 1 ;;
  esac
}

check_prerequisites() {
  log_info "Checking prerequisites..."
  local required=(cargo jq rg nvim rustc)
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "$cmd not found in PATH"
      exit 1
    fi
  done
  mkdir -p "$RESULTS_DIR" "$DATASET_ROOT"
}

extract_stats_from_sample() {
  local sample_path="$1"
  jq -c '
    [range(0; (.iters | length)) as $i | (.times[$i] / .iters[$i])] as $per_iter_ns
    | ($per_iter_ns | sort) as $sorted
    | ($sorted | length) as $n
    | if $n == 0 then
        error("sample.json has no measurements")
      else
        {
          sample_count: $n,
          p50_ms: ($sorted[((($n - 1) * 0.50) | floor)] / 1000000),
          p95_ms: ($sorted[((($n - 1) * 0.95) | floor)] / 1000000),
          avg_ms: (($sorted | add) / $n / 1000000),
          max_ms: ($sorted[-1] / 1000000),
          min_ms: ($sorted[0] / 1000000)
        }
      end
  ' "$sample_path"
}

run_code_shape_e2e() {
  local e2e_file="${RESULTS_DIR}/e2e_${TIMESTAMP}.json"
  log_info "Running code-shape E2E benchmark..." >&2
  "${SCRIPT_DIR}/run-e2e.sh" -n "$SAMPLE_SIZE" -q "$QUERY" -o "$e2e_file" >&2
  printf '%s\n' "$e2e_file"
}

run_lsp_baseline_bench() {
  log_info "Running lsp_workspace_symbols baseline benchmark..."
  (
    cd "$RUST_DIR"
    cargo bench --bench search_bench -- workspace_symbol_linear_by_repo_scale --noplot --sample-size "$SAMPLE_SIZE"
  )
}

ensure_live_grep_dataset() {
  local profile="$1"
  local dataset_dir="${DATASET_ROOT}/${profile}"
  local marker="${dataset_dir}/.meta"

  local files symbols_per_file lines_per_file
  files="$(profile_to_files "$profile")"
  symbols_per_file="$(profile_to_symbols_per_file "$profile")"
  lines_per_file="$(profile_to_lines_per_file "$profile")"

  local expected_meta
  expected_meta="$(printf 'files=%s\nsymbols_per_file=%s\nlines_per_file=%s\n' "$files" "$symbols_per_file" "$lines_per_file")"
  if [[ -f "$marker" ]] && diff -q <(printf '%s' "$expected_meta") "$marker" >/dev/null 2>&1; then
    log_info "Reusing dataset: ${profile}"
    echo "$dataset_dir"
    return
  fi

  log_info "Generating live_grep dataset: ${profile} (${files} files, ${lines_per_file} LOC/file)"
  rm -rf "$dataset_dir"
  mkdir -p "$dataset_dir"

  for ((file_idx = 1; file_idx <= files; file_idx++)); do
    awk \
      -v file_idx="$file_idx" \
      -v symbols="$symbols_per_file" \
      -v lines="$lines_per_file" \
      'BEGIN {
        prefixes[1] = "fetchData"
        prefixes[2] = "parseResponse"
        prefixes[3] = "handleError"
        prefixes[4] = "validateInput"
        prefixes[5] = "UserService"

        for (i = 1; i <= symbols; i++) {
          p = prefixes[((i - 1) % 5) + 1]
          printf("export function %s_%d_%d() { return %d; }\n", p, file_idx, i, i)
        }

        for (line = symbols + 1; line <= lines; line++) {
          printf("// filler line %d in file %d\n", line, file_idx)
        }
      }' > "${dataset_dir}/file_${file_idx}.ts"
  done

  printf '%s' "$expected_meta" > "$marker"
  echo "$dataset_dir"
}

calc_stats_from_seconds_file() {
  local input_file="$1"
  local sorted_file
  sorted_file="$(mktemp)"
  sort -n "$input_file" > "$sorted_file"

  local count
  count="$(wc -l < "$sorted_file" | tr -d ' ')"
  if [[ "$count" -eq 0 ]]; then
    rm -f "$sorted_file"
    jq -n '{ sample_count: 0, p50_ms: 0, p95_ms: 0, avg_ms: 0, max_ms: 0, min_ms: 0 }'
    return
  fi

  local p50_line p95_line
  p50_line=$(( ((count - 1) * 50 / 100) + 1 ))
  p95_line=$(( ((count - 1) * 95 / 100) + 1 ))

  local p50_s p95_s min_s max_s avg_s
  p50_s="$(sed -n "${p50_line}p" "$sorted_file")"
  p95_s="$(sed -n "${p95_line}p" "$sorted_file")"
  min_s="$(sed -n '1p' "$sorted_file")"
  max_s="$(sed -n '$p' "$sorted_file")"
  avg_s="$(awk '{sum += $1} END {if (NR > 0) printf "%.9f", sum / NR; else print "0"}' "$sorted_file")"

  rm -f "$sorted_file"

  jq -n \
    --argjson sample_count "$count" \
    --arg p50_s "$p50_s" \
    --arg p95_s "$p95_s" \
    --arg avg_s "$avg_s" \
    --arg max_s "$max_s" \
    --arg min_s "$min_s" \
    '{
      sample_count: $sample_count,
      p50_ms: (($p50_s | tonumber) * 1000),
      p95_ms: (($p95_s | tonumber) * 1000),
      avg_ms: (($avg_s | tonumber) * 1000),
      max_ms: (($max_s | tonumber) * 1000),
      min_ms: (($min_s | tonumber) * 1000)
    }'
}

measure_live_grep_profile() {
  local dataset_dir="$1"
  local samples_file
  samples_file="$(mktemp)"

  TIMEFORMAT='%R'

  for ((i = 1; i <= WARMUP; i++)); do
    { time rg --line-number --no-heading --color=never --max-count 50 "$QUERY" "$dataset_dir" >/dev/null 2>&1 || true; } 2>/dev/null
  done

  for ((i = 1; i <= ITERATIONS; i++)); do
    local elapsed
    elapsed="$({ time rg --line-number --no-heading --color=never --max-count 50 "$QUERY" "$dataset_dir" >/dev/null 2>&1 || true; } 2>&1)"
    printf '%s\n' "$elapsed" >> "$samples_file"
  done

  calc_stats_from_seconds_file "$samples_file"
  rm -f "$samples_file"
}

build_comparison_report() {
  local e2e_file="$1"
  local profiles=("100k_loc" "500k_loc" "1m_loc")
  local rows=()

  for profile in "${profiles[@]}"; do
    local loc files approx_symbols
    loc="$(profile_to_loc "$profile")"
    files="$(profile_to_files "$profile")"
    approx_symbols="$(profile_to_symbols "$profile")"

    local code_shape_stats
    code_shape_stats="$(jq -c --arg profile "$profile" '.profiles[] | select(.profile == $profile) | .latency' "$e2e_file")"
    if [[ -z "$code_shape_stats" ]]; then
      log_error "Missing code-shape stats for profile: ${profile}"
      exit 1
    fi

    local lsp_sample_path="${RUST_DIR}/target/criterion/workspace_symbol_linear_by_repo_scale/search_${profile}/new/sample.json"
    if [[ ! -f "$lsp_sample_path" ]]; then
      log_error "Missing LSP baseline sample: ${lsp_sample_path}"
      exit 1
    fi
    local lsp_stats
    lsp_stats="$(extract_stats_from_sample "$lsp_sample_path")"

    local dataset_dir
    dataset_dir="$(ensure_live_grep_dataset "$profile")"
    local live_grep_stats
    live_grep_stats="$(measure_live_grep_profile "$dataset_dir")"

    local row
    row="$(jq -cn \
      --arg profile "$profile" \
      --arg loc "$loc" \
      --argjson files "$files" \
      --argjson approx_symbols "$approx_symbols" \
      --argjson code_shape "$code_shape_stats" \
      --argjson lsp "$lsp_stats" \
      --argjson live_grep "$live_grep_stats" \
      '{
        profile: $profile,
        loc: $loc,
        files: $files,
        approx_symbols: $approx_symbols,
        code_shape: $code_shape,
        lsp_workspace_symbols: $lsp,
        live_grep: $live_grep
      }')"
    rows+=("$row")
  done

  local result_rows
  result_rows="$(printf '%s\n' "${rows[@]}" | jq -s '.')"

  local output_file="$OUTPUT_FILE"
  if [[ -z "$output_file" ]]; then
    output_file="${RESULTS_DIR}/comparison_${TIMESTAMP}.json"
  fi

  jq -n \
    --arg generated_at "$(date -Iseconds)" \
    --arg query "$QUERY" \
    --argjson sample_size "$SAMPLE_SIZE" \
    --argjson iterations "$ITERATIONS" \
    --argjson warmup "$WARMUP" \
    --arg e2e_source "$e2e_file" \
    --arg system_os "$(uname -s)" \
    --arg system_release "$(uname -r)" \
    --arg system_arch "$(uname -m)" \
    --arg nvim_version "$(nvim --version | head -1)" \
    --arg rustc_version "$(rustc --version)" \
    --argjson profiles "$result_rows" \
    '{
      generated_at: $generated_at,
      benchmark: "search-comparison",
      query: $query,
      sample_size: $sample_size,
      live_grep_iterations: $iterations,
      live_grep_warmup: $warmup,
      sources: {
        code_shape_e2e: $e2e_source,
        lsp_workspace_symbols: "criterion workspace_symbol_linear_by_repo_scale",
        live_grep_dataset: "benchmark/results/datasets/<profile>"
      },
      environment: {
        os: $system_os,
        release: $system_release,
        arch: $system_arch,
        nvim: $nvim_version,
        rustc: $rustc_version
      },
      profiles: $profiles
    }' > "$output_file"

  cp "$output_file" "${RESULTS_DIR}/latest-comparison.json"
  log_info "Saved comparison report: $output_file"
  log_info "Updated latest report: ${RESULTS_DIR}/latest-comparison.json"

  log_info "Summary (p50/p95 ms):"
  jq -r '
    .profiles[]
    | "  \(.loc): code-shape p50=\(.code_shape.p50_ms|tostring), p95=\(.code_shape.p95_ms|tostring) | "
      + "lsp p50=\(.lsp_workspace_symbols.p50_ms|tostring), p95=\(.lsp_workspace_symbols.p95_ms|tostring) | "
      + "live_grep p50=\(.live_grep.p50_ms|tostring), p95=\(.live_grep.p95_ms|tostring)"
  ' "$output_file"
}

main() {
  parse_args "$@"
  check_prerequisites

  local e2e_file
  e2e_file="$(run_code_shape_e2e)"

  run_lsp_baseline_bench
  build_comparison_report "$e2e_file"
}

main "$@"
