#!/usr/bin/env bash
# E2E latency benchmark for code-shape core search.
# Runs real Criterion measurements and derives p50/p95 from raw sample data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="${PROJECT_ROOT}/rust"
RESULTS_DIR="${SCRIPT_DIR}/results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

SAMPLE_SIZE=100
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
Usage: run-e2e.sh [OPTIONS]

Options:
  -n, --sample-size N    Criterion sample size (default: 100)
  -q, --query QUERY      Search query label for report metadata (default: fetchData)
  -o, --output FILE      Output JSON file path (default: benchmark/results/e2e_<timestamp>.json)
  -h, --help             Show this help

Profiles (fixed):
  - 100k LOC  -> search_by_repo_scale/search_100k_loc
  - 500k LOC  -> search_by_repo_scale/search_500k_loc
  - 1M LOC    -> search_by_repo_scale/search_1m_loc
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--sample-size)
        SAMPLE_SIZE="$2"
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
  if ! command -v cargo >/dev/null 2>&1; then
    log_error "cargo not found in PATH"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq not found in PATH"
    exit 1
  fi
  mkdir -p "$RESULTS_DIR"
}

run_benchmarks() {
  log_info "Running Criterion benchmarks for repo scale profiles..."
  (
    cd "$RUST_DIR"
    cargo bench --bench search_bench -- search_by_repo_scale --noplot --sample-size "$SAMPLE_SIZE"
  )
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
          p50_ns: $sorted[((($n - 1) * 0.50) | floor)],
          p95_ns: $sorted[((($n - 1) * 0.95) | floor)],
          max_ns: $sorted[-1],
          min_ns: $sorted[0],
          avg_ns: (($sorted | add) / $n)
        }
      end
  ' "$sample_path"
}

build_report() {
  local profiles=("100k_loc" "500k_loc" "1m_loc")
  local rows=()

  for profile in "${profiles[@]}"; do
    local sample_path="${RUST_DIR}/target/criterion/search_by_repo_scale/search_${profile}/new/sample.json"
    if [[ ! -f "$sample_path" ]]; then
      log_error "Missing Criterion sample: ${sample_path}"
      exit 1
    fi

    local stats
    stats="$(extract_stats_from_sample "$sample_path")"

    local loc files approx_symbols
    loc="$(profile_to_loc "$profile")"
    files="$(profile_to_files "$profile")"
    approx_symbols="$(profile_to_symbols "$profile")"

    local row
    row="$(jq -cn \
      --arg profile "$profile" \
      --arg loc "$loc" \
      --arg query "$QUERY" \
      --argjson files "$files" \
      --argjson approx_symbols "$approx_symbols" \
      --argjson stats "$stats" \
      '{
        profile: $profile,
        loc: $loc,
        files: $files,
        approx_symbols: $approx_symbols,
        query: $query,
        latency: {
          p50_ms: ($stats.p50_ns / 1000000),
          p95_ms: ($stats.p95_ns / 1000000),
          avg_ms: ($stats.avg_ns / 1000000),
          max_ms: ($stats.max_ns / 1000000),
          min_ms: ($stats.min_ns / 1000000)
        },
        raw: $stats
      }')"
    rows+=("$row")
  done

  local results_json
  results_json="$(printf '%s\n' "${rows[@]}" | jq -s '.')"

  local output_file="$OUTPUT_FILE"
  if [[ -z "$output_file" ]]; then
    output_file="${RESULTS_DIR}/e2e_${TIMESTAMP}.json"
  fi

  jq -n \
    --arg generated_at "$(date -Iseconds)" \
    --arg query "$QUERY" \
    --arg sample_size "$SAMPLE_SIZE" \
    --arg system_os "$(uname -s)" \
    --arg system_release "$(uname -r)" \
    --arg system_arch "$(uname -m)" \
    --arg nvim_version "$(nvim --version 2>/dev/null | head -1 || echo "unknown")" \
    --arg rustc_version "$(rustc --version 2>/dev/null || echo "unknown")" \
    --arg bench_command "cargo bench --bench search_bench -- search_by_repo_scale --noplot --sample-size ${SAMPLE_SIZE}" \
    --argjson results "$results_json" \
    '{
      generated_at: $generated_at,
      benchmark: "code-shape-e2e",
      query: $query,
      sample_size: ($sample_size | tonumber),
      command: $bench_command,
      environment: {
        os: $system_os,
        release: $system_release,
        arch: $system_arch,
        nvim: $nvim_version,
        rustc: $rustc_version
      },
      profiles: $results
    }' > "$output_file"

  cp "$output_file" "${RESULTS_DIR}/latest-e2e.json"
  log_info "Saved E2E report: $output_file"
  log_info "Updated latest report: ${RESULTS_DIR}/latest-e2e.json"

  log_info "Summary (p50/p95 ms):"
  jq -r '.profiles[] | "  \(.loc): p50=\(.latency.p50_ms|tostring) ms, p95=\(.latency.p95_ms|tostring) ms"' "$output_file"
}

main() {
  parse_args "$@"
  check_prerequisites
  run_benchmarks
  build_report
}

main "$@"
