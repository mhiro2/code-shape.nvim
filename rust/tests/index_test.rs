use code_shape_core::index::{Position, Range, Symbol, SymbolIndex};
use std::collections::HashMap;

fn make_symbol(id: &str, name: &str, uri: &str, kind: u32) -> Symbol {
    Symbol {
        symbol_id: id.to_string(),
        name: name.to_string(),
        kind,
        container_name: None,
        uri: uri.to_string(),
        range: Range {
            start: Position {
                line: 0,
                character: 0,
            },
            end: Position {
                line: 0,
                character: 10,
            },
        },
        detail: None,
        metrics: None,
    }
}

#[test]
fn new_index_is_empty() {
    let index = SymbolIndex::new();
    assert_eq!(index.symbol_count(), 0);
    assert_eq!(index.uri_count(), 0);
}

#[test]
fn upsert_symbols_adds_new_symbols() {
    let mut index = SymbolIndex::new();

    let symbols = vec![
        make_symbol("id1", "foo", "file:///a.ts", 12), // Function
        make_symbol("id2", "bar", "file:///a.ts", 5),  // Class
    ];

    index
        .upsert_symbols("file:///a.ts", symbols)
        .expect("upsert symbols should succeed");

    assert_eq!(index.symbol_count(), 2);
    assert_eq!(index.uri_count(), 1);
}

#[test]
fn upsert_symbols_replaces_existing() {
    let mut index = SymbolIndex::new();

    let symbols1 = vec![
        make_symbol("id1", "foo", "file:///a.ts", 12),
        make_symbol("id2", "bar", "file:///a.ts", 5),
    ];
    index
        .upsert_symbols("file:///a.ts", symbols1)
        .expect("upsert symbols should succeed");
    assert_eq!(index.symbol_count(), 2);

    let symbols2 = vec![
        make_symbol("id3", "baz", "file:///a.ts", 13), // Variable
    ];
    index
        .upsert_symbols("file:///a.ts", symbols2)
        .expect("upsert symbols should succeed");
    assert_eq!(index.symbol_count(), 1);
    assert_eq!(index.uri_count(), 1);
}

#[test]
fn upsert_symbols_handles_multiple_uris() {
    let mut index = SymbolIndex::new();

    index
        .upsert_symbols(
            "file:///a.ts",
            vec![make_symbol("id1", "foo", "file:///a.ts", 12)],
        )
        .expect("upsert symbols should succeed");
    index
        .upsert_symbols(
            "file:///b.ts",
            vec![make_symbol("id2", "bar", "file:///b.ts", 12)],
        )
        .expect("upsert symbols should succeed");

    assert_eq!(index.symbol_count(), 2);
    assert_eq!(index.uri_count(), 2);
}

#[test]
fn remove_uri_deletes_symbols() {
    let mut index = SymbolIndex::new();

    index
        .upsert_symbols(
            "file:///a.ts",
            vec![
                make_symbol("id1", "foo", "file:///a.ts", 12),
                make_symbol("id2", "bar", "file:///a.ts", 5),
            ],
        )
        .expect("upsert symbols should succeed");
    assert_eq!(index.symbol_count(), 2);

    index.remove_uri("file:///a.ts");
    assert_eq!(index.symbol_count(), 0);
    assert_eq!(index.uri_count(), 0);
}

#[test]
fn remove_uri_nonexistent_is_noop() {
    let mut index = SymbolIndex::new();
    index
        .upsert_symbols(
            "file:///a.ts",
            vec![make_symbol("id1", "foo", "file:///a.ts", 12)],
        )
        .expect("upsert symbols should succeed");

    index.remove_uri("file:///nonexistent.ts");
    assert_eq!(index.symbol_count(), 1);
}

#[test]
fn all_symbols_returns_all() {
    let mut index = SymbolIndex::new();

    index
        .upsert_symbols(
            "file:///a.ts",
            vec![make_symbol("id1", "foo", "file:///a.ts", 12)],
        )
        .expect("upsert symbols should succeed");
    index
        .upsert_symbols(
            "file:///b.ts",
            vec![make_symbol("id2", "bar", "file:///b.ts", 5)],
        )
        .expect("upsert symbols should succeed");

    let all = index.all_symbols();
    assert_eq!(all.len(), 2);
}

#[test]
fn hotspot_scores() {
    let mut index = SymbolIndex::new();

    let mut scores = HashMap::new();
    scores.insert("file:///a.ts".to_string(), 0.8);
    scores.insert("file:///b.ts".to_string(), 0.3);

    index.set_hotspot_scores(scores);

    assert!((index.get_hotspot_score("file:///a.ts") - 0.8).abs() < f64::EPSILON);
    assert!((index.get_hotspot_score("file:///b.ts") - 0.3).abs() < f64::EPSILON);
    assert!((index.get_hotspot_score("file:///c.ts")).abs() < f64::EPSILON); // missing = 0
}

#[test]
fn get_hotspot_scores_returns_reference() {
    let mut index = SymbolIndex::new();

    let mut scores = HashMap::new();
    scores.insert("file:///a.ts".to_string(), 0.5);

    index.set_hotspot_scores(scores);

    let all_scores = index.get_hotspot_scores();
    assert_eq!(all_scores.len(), 1);
}
