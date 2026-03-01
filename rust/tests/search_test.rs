use code_shape_core::index::{Position, Range, Symbol, SymbolIndex};
use code_shape_core::search::{SearchFilters, SearchParams, search};
use std::collections::HashMap;

fn make_symbol(id: &str, name: &str, uri: &str, kind: u32, container: Option<&str>) -> Symbol {
    Symbol {
        symbol_id: id.to_string(),
        name: name.to_string(),
        kind,
        container_name: container.map(|s| s.to_string()),
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

fn setup_index() -> SymbolIndex {
    let mut index = SymbolIndex::new();

    index
        .upsert_symbols(
            "file:///src/utils.ts",
            vec![
                make_symbol(
                    "id1",
                    "formatDate",
                    "file:///src/utils.ts",
                    12,
                    Some("Utils"),
                ),
                make_symbol(
                    "id2",
                    "parseDate",
                    "file:///src/utils.ts",
                    12,
                    Some("Utils"),
                ),
                make_symbol("id3", "DateHelper", "file:///src/utils.ts", 5, None),
            ],
        )
        .expect("upsert symbols should succeed");

    index
        .upsert_symbols(
            "file:///src/api.ts",
            vec![
                make_symbol("id4", "fetchUser", "file:///src/api.ts", 12, Some("Api")),
                make_symbol("id5", "UserClient", "file:///src/api.ts", 5, None),
            ],
        )
        .expect("upsert symbols should succeed");

    index
}

#[test]
fn search_empty_query_returns_all() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert_eq!(result.symbols.len(), 5);
}

#[test]
fn search_exact_match() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "formatDate".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert_eq!(result.symbols.len(), 1);
    assert_eq!(result.symbols[0].name, "formatDate");
}

#[test]
fn search_prefix_match() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "format".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert_eq!(result.symbols.len(), 1);
    assert_eq!(result.symbols[0].name, "formatDate");
}

#[test]
fn search_substring_match() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "Date".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    // formatDate, parseDate, DateHelper
    assert!(result.symbols.len() >= 3);
}

#[test]
fn search_fuzzy_match() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "fd".to_string(), // matches formatDate (f...d...)
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert!(!result.symbols.is_empty());
    let names: Vec<&str> = result.symbols.iter().map(|s| s.name.as_str()).collect();
    assert!(names.contains(&"formatDate"));
}

#[test]
fn search_container_only_query_returns_symbols() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "utils".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    let names: Vec<&str> = result.symbols.iter().map(|s| s.name.as_str()).collect();
    assert!(names.contains(&"formatDate"));
    assert!(names.contains(&"parseDate"));
}

#[test]
fn search_container_match_boosts_ranking() {
    let mut index = SymbolIndex::new();
    index
        .upsert_symbols(
            "file:///src/a.ts",
            vec![make_symbol(
                "id1",
                "fetchItem",
                "file:///src/a.ts",
                12,
                Some("Api"),
            )],
        )
        .expect("upsert symbols should succeed");
    index
        .upsert_symbols(
            "file:///src/b.ts",
            vec![make_symbol(
                "id2",
                "fetchItem",
                "file:///src/b.ts",
                12,
                Some("Utils"),
            )],
        )
        .expect("upsert symbols should succeed");

    let result = search(
        &index,
        SearchParams {
            q: "fetch api".to_string(),
            limit: 10,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert_eq!(result.symbols[0].uri, "file:///src/a.ts");
}

#[test]
fn search_respects_limit() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "".to_string(),
            limit: 2,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert_eq!(result.symbols.len(), 2);
}

#[test]
fn search_filter_by_kind() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters {
                kinds: Some(vec![12]),
            }, // Function only
        },
    )
    .expect("search should succeed");

    assert_eq!(result.symbols.len(), 3); // formatDate, parseDate, fetchUser
    for symbol in &result.symbols {
        assert_eq!(symbol.kind, 12);
    }
}

#[test]
fn search_kind_boost_prioritizes_function_when_name_score_is_equal() {
    let mut index = SymbolIndex::new();
    index
        .upsert_symbols(
            "file:///src/function.ts",
            vec![make_symbol(
                "id1",
                "target",
                "file:///src/function.ts",
                12,
                None,
            )],
        )
        .expect("upsert symbols should succeed");
    index
        .upsert_symbols(
            "file:///src/class.ts",
            vec![make_symbol(
                "id2",
                "target",
                "file:///src/class.ts",
                5,
                None,
            )],
        )
        .expect("upsert symbols should succeed");

    let result = search(
        &index,
        SearchParams {
            q: "target".to_string(),
            limit: 10,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert_eq!(result.symbols.len(), 2);
    assert_eq!(result.symbols[0].kind, 12);
    assert_eq!(result.symbols[1].kind, 5);
}

#[test]
fn search_no_match() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "nonexistent".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert_eq!(result.symbols.len(), 0);
}

#[test]
fn search_hotspot_boost() {
    let mut index = setup_index();

    // Set hotspot scores
    let mut scores = HashMap::new();
    scores.insert("file:///src/api.ts".to_string(), 10.0); // High score
    scores.insert("file:///src/utils.ts".to_string(), 0.1); // Low score
    index.set_hotspot_scores(scores);

    // Search for common substring
    let result = search(
        &index,
        SearchParams {
            q: "".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    // api.ts symbols should be ranked higher
    assert!(!result.symbols.is_empty());
    let first_uri = &result.symbols[0].uri;
    assert!(first_uri.contains("api.ts"));
}

#[test]
fn search_hotspot_boost_is_clamped() {
    let mut index = SymbolIndex::new();
    index
        .upsert_symbols(
            "file:///src/api.ts",
            vec![make_symbol(
                "id1",
                "fetchUser",
                "file:///src/api.ts",
                12,
                Some("Api"),
            )],
        )
        .expect("upsert symbols should succeed");

    let mut baseline_scores = HashMap::new();
    baseline_scores.insert("file:///src/api.ts".to_string(), 1.0);
    index.set_hotspot_scores(baseline_scores);

    let baseline = search(
        &index,
        SearchParams {
            q: "fetch".to_string(),
            limit: 10,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");
    let baseline_score = baseline.symbols[0].score;

    let mut clamped_scores = HashMap::new();
    clamped_scores.insert("file:///src/api.ts".to_string(), 10.0);
    index.set_hotspot_scores(clamped_scores);

    let clamped = search(
        &index,
        SearchParams {
            q: "fetch".to_string(),
            limit: 10,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");
    let clamped_score = clamped.symbols[0].score;

    assert_eq!(baseline_score, clamped_score);
}

#[test]
fn search_result_has_score() {
    let index = setup_index();

    let result = search(
        &index,
        SearchParams {
            q: "format".to_string(),
            limit: 100,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        },
    )
    .expect("search should succeed");

    assert!(!result.symbols.is_empty());
    assert!(result.symbols[0].score > 0.0);
}
