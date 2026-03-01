//! Benchmarks for search operations.
//!
//! Measures performance of:
//! - Exact match queries
//! - Prefix match queries
//! - Fuzzy/subsequence match queries
//! - Empty queries (all symbols)
//! - Queries with hotspot boost
//! - Queries with kind filters

use code_shape_core::index::SymbolIndex;
use code_shape_core::search::{SearchFilters, SearchParams, search};
use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use std::collections::HashMap;
use std::hint::black_box;

mod common;
use common::generate_workspace;

fn setup_large_index() -> SymbolIndex {
    let mut index = SymbolIndex::new();
    // Realistic workspace: 500 files, 100 symbols each = ~50,000 symbols
    let workspace = generate_workspace(500, 100);
    for (uri, symbols) in workspace {
        index
            .upsert_symbols(&uri, symbols)
            .expect("upsert symbols should succeed");
    }
    index
}

fn setup_xlarge_index() -> SymbolIndex {
    let mut index = SymbolIndex::new();
    // Extra large workspace: 1000 files, 100 symbols each = ~100,000 symbols
    let workspace = generate_workspace(1000, 100);
    for (uri, symbols) in workspace {
        index
            .upsert_symbols(&uri, symbols)
            .expect("upsert symbols should succeed");
    }
    index
}

fn setup_repo_scale_index(file_count: usize, symbols_per_file: usize) -> SymbolIndex {
    let mut index = SymbolIndex::new();
    let workspace = generate_workspace(file_count, symbols_per_file);
    for (uri, symbols) in workspace {
        index
            .upsert_symbols(&uri, symbols)
            .expect("upsert symbols should succeed");
    }
    index
}

fn setup_medium_index() -> SymbolIndex {
    let mut index = SymbolIndex::new();
    // Medium workspace: 100 files, 50 symbols each = ~5,000 symbols
    let workspace = generate_workspace(100, 50);
    for (uri, symbols) in workspace {
        index
            .upsert_symbols(&uri, symbols)
            .expect("upsert symbols should succeed");
    }
    index
}

fn bench_search_exact_match(c: &mut Criterion) {
    let index = setup_large_index();
    let mut group = c.benchmark_group("search_exact");

    // Exact match queries - these should be fast
    let queries = ["fetchData", "parseResponse", "handleError", "validateInput"];

    for query in queries {
        group.bench_function(format!("query_{}", query), |b| {
            b.iter(|| {
                let result = search(
                    &index,
                    SearchParams {
                        q: query.to_string(),
                        limit: 50,
                        complexity_cap: 50,
                        filters: SearchFilters::default(),
                    },
                );
                black_box(result)
            })
        });
    }
    group.finish();
}

fn bench_search_prefix(c: &mut Criterion) {
    let index = setup_large_index();
    let mut group = c.benchmark_group("search_prefix");

    // Prefix queries - match multiple symbols
    let queries = ["fetch", "parse", "handle", "validate", "process"];

    for query in queries {
        group.bench_function(format!("query_{}", query), |b| {
            b.iter(|| {
                let result = search(
                    &index,
                    SearchParams {
                        q: query.to_string(),
                        limit: 50,
                        complexity_cap: 50,
                        filters: SearchFilters::default(),
                    },
                );
                black_box(result)
            })
        });
    }
    group.finish();
}

fn bench_search_fuzzy(c: &mut Criterion) {
    let index = setup_large_index();
    let mut group = c.benchmark_group("search_fuzzy");

    // Fuzzy queries (subsequence matching) - most expensive
    let queries = ["fd", "pr", "hv", "vd", "pc"];

    for query in queries {
        group.bench_function(format!("query_{}", query), |b| {
            b.iter(|| {
                let result = search(
                    &index,
                    SearchParams {
                        q: query.to_string(),
                        limit: 50,
                        complexity_cap: 50,
                        filters: SearchFilters::default(),
                    },
                );
                black_box(result)
            })
        });
    }
    group.finish();
}

fn bench_search_empty_query(c: &mut Criterion) {
    let index = setup_large_index();

    c.bench_function("search_empty_all_symbols", |b| {
        b.iter(|| {
            let result = search(
                &index,
                SearchParams {
                    q: "".to_string(),
                    limit: 50,
                    complexity_cap: 50,
                    filters: SearchFilters::default(),
                },
            );
            black_box(result)
        })
    });
}

fn bench_search_with_hotspot(c: &mut Criterion) {
    let mut index = setup_large_index();

    // Set hotspot scores for 20% of files
    let mut scores = HashMap::new();
    for i in 0..100 {
        let uri = format!("file:///src/file_{}.ts", i);
        scores.insert(uri, (i as f64) / 100.0);
    }
    index.set_hotspot_scores(scores);

    c.bench_function("search_with_hotspot_boost", |b| {
        b.iter(|| {
            let result = search(
                &index,
                SearchParams {
                    q: "data".to_string(),
                    limit: 50,
                    complexity_cap: 50,
                    filters: SearchFilters::default(),
                },
            );
            black_box(result)
        })
    });
}

fn bench_search_with_kind_filter(c: &mut Criterion) {
    let index = setup_large_index();

    c.bench_function("search_filter_functions_only", |b| {
        b.iter(|| {
            let result = search(
                &index,
                SearchParams {
                    q: "".to_string(),
                    limit: 50,
                    complexity_cap: 50,
                    filters: SearchFilters {
                        kinds: Some(vec![12]), // Function only
                    },
                },
            );
            black_box(result)
        })
    });
}

fn bench_search_varying_result_sizes(c: &mut Criterion) {
    let index = setup_large_index();
    let mut group = c.benchmark_group("search_limits");

    for limit in [10, 50, 100, 500] {
        group.throughput(Throughput::Elements(limit as u64));

        group.bench_with_input(BenchmarkId::new("limit", limit), &limit, |b, limit| {
            b.iter(|| {
                let result = search(
                    &index,
                    SearchParams {
                        q: "".to_string(),
                        limit: *limit,
                        complexity_cap: 50,
                        filters: SearchFilters::default(),
                    },
                );
                black_box(result)
            })
        });
    }
    group.finish();
}

fn bench_search_index_sizes(c: &mut Criterion) {
    let mut group = c.benchmark_group("search_by_index_size");

    // Small index: 1000 symbols
    let small_workspace = generate_workspace(20, 50);
    let mut small_index = SymbolIndex::new();
    for (uri, symbols) in small_workspace {
        small_index
            .upsert_symbols(&uri, symbols)
            .expect("upsert symbols should succeed");
    }

    // Medium index: 5000 symbols
    let medium_index = setup_medium_index();

    // Large index: 50000 symbols
    let large_index = setup_large_index();
    // Extra large index: 100000 symbols
    let xlarge_index = setup_xlarge_index();

    for (name, index) in [
        ("1k_symbols", &small_index),
        ("5k_symbols", &medium_index),
        ("50k_symbols", &large_index),
        ("100k_symbols", &xlarge_index),
    ] {
        group.bench_function(format!("search_{}", name), |b| {
            b.iter(|| {
                let result = search(
                    index,
                    SearchParams {
                        q: "fetch".to_string(),
                        limit: 50,
                        complexity_cap: 50,
                        filters: SearchFilters::default(),
                    },
                );
                black_box(result)
            })
        });
    }
    group.finish();
}

fn bench_search_repo_scales(c: &mut Criterion) {
    let mut group = c.benchmark_group("search_by_repo_scale");
    let profiles = [
        ("100k_loc", 200, 50),  // ~100k LOC, ~10k symbols
        ("500k_loc", 500, 100), // ~500k LOC, ~50k symbols
        ("1m_loc", 1000, 100),  // ~1M LOC, ~100k symbols
    ];

    for (name, file_count, symbols_per_file) in profiles {
        let index = setup_repo_scale_index(file_count, symbols_per_file);
        group.bench_function(format!("search_{}", name), |b| {
            b.iter(|| {
                let result = search(
                    &index,
                    SearchParams {
                        q: "fetchData".to_string(),
                        limit: 50,
                        complexity_cap: 50,
                        filters: SearchFilters::default(),
                    },
                );
                black_box(result)
            })
        });
    }
    group.finish();
}

fn linear_workspace_symbol_search(symbol_names: &[String], query: &str, limit: usize) -> usize {
    if query.is_empty() {
        return symbol_names.len().min(limit);
    }

    let query_lower = query.to_ascii_lowercase();
    let mut matched = Vec::new();

    for (idx, name) in symbol_names.iter().enumerate() {
        let score = if name == &query_lower {
            3
        } else if name.starts_with(&query_lower) {
            2
        } else if name.contains(&query_lower) {
            1
        } else {
            0
        };

        if score > 0 {
            matched.push((score, idx));
        }
    }

    // Simulate baseline ranking work done by generic workspace/symbol flows.
    matched.sort_unstable_by(|a, b| b.cmp(a));
    matched.len().min(limit)
}

fn bench_workspace_symbol_linear_repo_scales(c: &mut Criterion) {
    let mut group = c.benchmark_group("workspace_symbol_linear_by_repo_scale");
    let profiles = [
        ("100k_loc", 200, 50),  // ~100k LOC, ~10k symbols
        ("500k_loc", 500, 100), // ~500k LOC, ~50k symbols
        ("1m_loc", 1000, 100),  // ~1M LOC, ~100k symbols
    ];

    for (name, file_count, symbols_per_file) in profiles {
        let index = setup_repo_scale_index(file_count, symbols_per_file);
        let symbol_names: Vec<String> = index
            .all_symbols()
            .iter()
            .map(|symbol| symbol.name.to_ascii_lowercase())
            .collect();

        group.bench_function(format!("search_{}", name), |b| {
            b.iter(|| {
                let result = linear_workspace_symbol_search(
                    black_box(&symbol_names),
                    black_box("fetchData"),
                    black_box(50),
                );
                black_box(result)
            })
        });
    }
    group.finish();
}

fn bench_search_multi_token(c: &mut Criterion) {
    let index = setup_large_index();
    let mut group = c.benchmark_group("search_multi_token");

    // Multi-token queries
    let queries = [
        "fetch data",
        "parse response",
        "handle error",
        "user service",
    ];

    for query in queries {
        group.bench_function(format!("query_{}", query.replace(' ', "_")), |b| {
            b.iter(|| {
                let result = search(
                    &index,
                    SearchParams {
                        q: query.to_string(),
                        limit: 50,
                        complexity_cap: 50,
                        filters: SearchFilters::default(),
                    },
                );
                black_box(result)
            })
        });
    }
    group.finish();
}

fn bench_search_no_results(c: &mut Criterion) {
    let index = setup_large_index();

    c.bench_function("search_no_match", |b| {
        b.iter(|| {
            let result = search(
                &index,
                SearchParams {
                    q: "xyznonexistent123".to_string(),
                    limit: 50,
                    complexity_cap: 50,
                    filters: SearchFilters::default(),
                },
            );
            black_box(result)
        })
    });
}

criterion_group!(
    search_benches,
    bench_search_exact_match,
    bench_search_prefix,
    bench_search_fuzzy,
    bench_search_empty_query,
    bench_search_with_hotspot,
    bench_search_with_kind_filter,
    bench_search_varying_result_sizes,
    bench_search_index_sizes,
    bench_search_repo_scales,
    bench_workspace_symbol_linear_repo_scales,
    bench_search_multi_token,
    bench_search_no_results,
);
criterion_main!(search_benches);
