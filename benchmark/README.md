# code-shape.nvim Benchmarks

This directory contains the benchmark scripts and canonical benchmark outputs.

## Single Source of Truth

- `benchmark/results/latest-e2e.json`
- `benchmark/results/latest-comparison.json`

All README/vimdoc benchmark numbers should be synchronized from `latest-comparison.json`.

## Profiles

Benchmark profiles are fixed to repository-scale conditions:

| Profile | Approx LOC | Files | Symbols/File | Approx Symbols |
|---------|------------|-------|--------------|----------------|
| `100k_loc` | 100k | 200 | 50 | 10k |
| `500k_loc` | 500k | 500 | 100 | 50k |
| `1m_loc` | 1M | 1000 | 100 | 100k |

## Scripts

### `run-e2e.sh`

Measures code-shape latency from real Criterion samples (`search_by_repo_scale`) and derives `p50/p95`.

```bash
./benchmark/run-e2e.sh -n 100 -q fetchData
```

Output:

- timestamped JSON: `benchmark/results/e2e_<timestamp>.json`
- latest JSON: `benchmark/results/latest-e2e.json`

### `run-comparison.sh`

Runs all tools under the same profile/query conditions:

1. `code-shape` (`search_by_repo_scale`, Criterion)
2. `lsp_workspace_symbols` baseline (`workspace_symbol_linear_by_repo_scale`, Criterion linear scan)
3. `live_grep` (`rg` over generated corpus in `benchmark/results/datasets/<profile>`)

```bash
./benchmark/run-comparison.sh -n 100 -i 100 -w 5 -q fetchData
```

Output:

- timestamped JSON: `benchmark/results/comparison_<timestamp>.json`
- latest JSON: `benchmark/results/latest-comparison.json`

## Latest Results

Source: `benchmark/results/latest-comparison.json`

| Profile | code-shape p50/p95 (ms) | lsp_workspace_symbols p50/p95 (ms) | live_grep p50/p95 (ms) |
|---------|-------------------------|------------------------------------|-------------------------|
| `100k_loc` | 0.606 / 0.881 | 0.400 / 0.538 | 5 / 6 |
| `500k_loc` | 0.745 / 1.198 | 2.081 / 2.366 | 5 / 7 |
| `1m_loc` | 1.371 / 2.416 | 4.223 / 5.659 | 4 / 7 |

## Environment (Latest Run)

| Parameter | Value |
|-----------|-------|
| OS | Darwin 25.2.0 |
| Architecture | arm64 |
| Neovim | v0.11.6 |
| Rust | 1.93.0 |
| Criterion sample size | 100 |
| live_grep warmup / iterations | 5 / 100 |
| Query | `fetchData` |

## Notes

- `lsp_workspace_symbols` is measured as an automated linear-scan baseline for workspace symbol lookup under the same dataset/query constraints.
- `live_grep` uses generated corpora to keep profile conditions reproducible and fully automated.
