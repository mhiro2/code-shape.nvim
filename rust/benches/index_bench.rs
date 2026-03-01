//! Benchmarks for SymbolIndex operations.
//!
//! Measures performance of:
//! - upsert_symbols: Inserting/replacing symbols for a URI
//! - remove_uri: Removing all symbols for a URI
//! - Multiple URI operations: Realistic workspace indexing

use code_shape_core::index::SymbolIndex;
use criterion::{
    BatchSize, BenchmarkId, Criterion, Throughput, black_box, criterion_group, criterion_main,
};

mod common;
use common::{generate_workspace, typescript_symbols};

fn bench_upsert_symbols(c: &mut Criterion) {
    let mut group = c.benchmark_group("upsert_symbols");

    // Test different scales: 100, 1000, 10000 symbols per file
    for size in [100, 1_000, 10_000] {
        group.throughput(Throughput::Elements(size as u64));

        let symbols = typescript_symbols("file:///test.ts", size);

        group.bench_with_input(BenchmarkId::new("ts_symbols", size), &size, |b, _| {
            b.iter_batched(
                SymbolIndex::new,
                |mut index| {
                    index
                        .upsert_symbols("file:///test.ts", symbols.clone())
                        .expect("upsert symbols should succeed");
                    index
                },
                BatchSize::SmallInput,
            )
        });
    }
    group.finish();
}

fn bench_upsert_multiple_uris(c: &mut Criterion) {
    let mut group = c.benchmark_group("upsert_multiple_uris");

    // Realistic workspace: 100 files with 50 symbols each
    let workspace = generate_workspace(100, 50);

    group.bench_function("workspace_100_files", |b| {
        b.iter_batched(
            SymbolIndex::new,
            |mut index| {
                for (uri, symbols) in &workspace {
                    index
                        .upsert_symbols(uri, symbols.clone())
                        .expect("upsert symbols should succeed");
                }
                index
            },
            BatchSize::SmallInput,
        )
    });
    group.finish();
}

fn bench_upsert_large_workspace(c: &mut Criterion) {
    let mut group = c.benchmark_group("upsert_large_workspace");

    // Large workspace: 500 files with 100 symbols each = 50,000 symbols
    let workspace = generate_workspace(500, 100);

    group.bench_function("workspace_500_files", |b| {
        b.iter_batched(
            SymbolIndex::new,
            |mut index| {
                for (uri, symbols) in &workspace {
                    index
                        .upsert_symbols(uri, symbols.clone())
                        .expect("upsert symbols should succeed");
                }
                index
            },
            BatchSize::SmallInput,
        )
    });
    group.finish();
}

fn bench_remove_uri(c: &mut Criterion) {
    let mut group = c.benchmark_group("remove_uri");

    // Setup index with 10000 symbols across 100 files
    let workspace = generate_workspace(100, 100);

    group.bench_function("remove_from_large_index", |b| {
        b.iter_batched(
            || {
                let mut index = SymbolIndex::new();
                for (uri, symbols) in &workspace {
                    index
                        .upsert_symbols(uri, symbols.clone())
                        .expect("upsert symbols should succeed");
                }
                index
            },
            |mut index| {
                index.remove_uri("file:///src/file_50.ts");
                index
            },
            BatchSize::SmallInput,
        )
    });
    group.finish();
}

fn bench_upsert_replace(c: &mut Criterion) {
    let mut group = c.benchmark_group("upsert_replace");

    let old_symbols = typescript_symbols("file:///test.ts", 1000);
    let new_symbols = typescript_symbols("file:///test.ts", 500);

    group.bench_function("replace_1000_with_500", |b| {
        b.iter_batched(
            || {
                let mut index = SymbolIndex::new();
                index
                    .upsert_symbols("file:///test.ts", old_symbols.clone())
                    .expect("upsert symbols should succeed");
                index
            },
            |mut index| {
                index
                    .upsert_symbols("file:///test.ts", new_symbols.clone())
                    .expect("upsert symbols should succeed");
                index
            },
            BatchSize::SmallInput,
        )
    });
    group.finish();
}

fn bench_upsert_same_uri_repeated(c: &mut Criterion) {
    let mut group = c.benchmark_group("upsert_same_uri_repeated");

    let symbols = typescript_symbols("file:///test.ts", 100);

    group.bench_function("repeated_updates", |b| {
        b.iter_batched(
            SymbolIndex::new,
            |mut index| {
                for _ in 0..10 {
                    index
                        .upsert_symbols("file:///test.ts", symbols.clone())
                        .expect("upsert symbols should succeed");
                }
                index
            },
            BatchSize::SmallInput,
        )
    });
    group.finish();
}

fn bench_all_symbols(c: &mut Criterion) {
    let mut group = c.benchmark_group("all_symbols");

    let workspace = generate_workspace(100, 100);

    let mut index = SymbolIndex::new();
    for (uri, symbols) in &workspace {
        index
            .upsert_symbols(uri, symbols.clone())
            .expect("upsert symbols should succeed");
    }

    group.bench_function("iterate_10000_symbols", |b| {
        b.iter(|| {
            let symbols = index.all_symbols();
            black_box(symbols)
        })
    });
    group.finish();
}

fn bench_symbol_count(c: &mut Criterion) {
    let mut group = c.benchmark_group("symbol_count");

    let workspace = generate_workspace(100, 100);

    let mut index = SymbolIndex::new();
    for (uri, symbols) in &workspace {
        index
            .upsert_symbols(uri, symbols.clone())
            .expect("upsert symbols should succeed");
    }

    group.bench_function("count_10000_symbols", |b| {
        b.iter(|| {
            let count = index.symbol_count();
            black_box(count)
        })
    });
    group.finish();
}

criterion_group!(
    index_benches,
    bench_upsert_symbols,
    bench_upsert_multiple_uris,
    bench_upsert_large_workspace,
    bench_remove_uri,
    bench_upsert_replace,
    bench_upsert_same_uri_repeated,
    bench_all_symbols,
    bench_symbol_count,
);
criterion_main!(index_benches);
