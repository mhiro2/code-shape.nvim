use crate::index::{Symbol, SymbolIndex, SymbolMetrics, collect_ngrams, collect_unique_chars};
use anyhow::Result;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Deserialize)]
pub struct SearchParams {
    pub q: String,
    #[serde(default = "default_limit")]
    pub limit: usize,
    pub complexity_cap: u32,
    #[serde(default)]
    pub filters: SearchFilters,
}

fn default_limit() -> usize {
    50
}

#[derive(Debug, Default, Deserialize)]
pub struct SearchFilters {
    #[serde(default)]
    pub kinds: Option<Vec<u32>>,
}

#[derive(Debug, Serialize)]
pub struct SearchResult {
    pub symbols: Vec<SearchResultItem>,
}

#[derive(Debug, Serialize)]
pub struct SearchResultItem {
    pub symbol_id: String,
    pub name: String,
    pub kind: u32,
    pub container_name: Option<String>,
    pub uri: String,
    pub range: crate::index::Range,
    pub detail: Option<String>,
    pub score: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metrics: Option<SymbolMetrics>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tech_debt: Option<f64>,
}

const NAME_SCORE_EXACT: f64 = 100.0;
const NAME_SCORE_PREFIX: f64 = 80.0;
const NAME_SCORE_SUBSTRING: f64 = 60.0;
const NAME_SCORE_SUBSEQUENCE: f64 = 40.0;

const CONTAINER_SCORE_EXACT: f64 = 24.0;
const CONTAINER_SCORE_PREFIX: f64 = 16.0;
const CONTAINER_SCORE_SUBSTRING: f64 = 10.0;
const CONTAINER_SCORE_SUBSEQUENCE: f64 = 6.0;

const CONTAINER_BONUS_RATIO_CAP: f64 = 0.35;
const CONTAINER_ONLY_NAME_BASE: f64 = NAME_SCORE_SUBSEQUENCE;
const HOTSPOT_BOOST_FACTOR: f64 = 0.15;
const COMPLEXITY_BOOST_FACTOR: f64 = 0.10;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MatchGrade {
    None,
    Subsequence,
    Substring,
    Prefix,
    Exact,
}

type UnigramLookup = for<'a> fn(&'a SymbolIndex, char) -> Option<&'a [u32]>;
type NgramLookup = for<'a, 'b> fn(&'a SymbolIndex, &'b str) -> Option<&'a [u32]>;

/// Search symbols by query
pub fn search(index: &SymbolIndex, params: SearchParams) -> Result<SearchResult> {
    let query = params.q.to_lowercase();
    let query_tokens: Vec<&str> = query.split_whitespace().filter(|t| !t.is_empty()).collect();
    let complexity_cap = normalize_complexity_cap(params.complexity_cap);

    let candidate_symbols = if query_tokens.is_empty() {
        index.all_symbols()
    } else {
        resolve_candidates(index, &query_tokens)
    };

    let kind_filter_set = params
        .filters
        .kinds
        .as_ref()
        .map(|kinds| kinds.iter().copied().collect::<HashSet<u32>>());

    let mut results: Vec<SearchResultItem> = candidate_symbols
        .into_par_iter()
        .filter_map(|symbol| {
            if let Some(ref kinds) = kind_filter_set {
                if !kinds.contains(&symbol.kind) {
                    return None;
                }
            }

            let score = calculate_score(symbol, &query_tokens, index);
            if score > 0.0 {
                let hotspot = index.get_hotspot_score(&symbol.uri);
                let tech_debt =
                    calculate_tech_debt(hotspot, symbol.metrics.as_ref(), complexity_cap);
                Some(SearchResultItem {
                    symbol_id: symbol.symbol_id.clone(),
                    name: symbol.name.clone(),
                    kind: symbol.kind,
                    container_name: symbol.container_name.clone(),
                    uri: symbol.uri.clone(),
                    range: symbol.range.clone(),
                    detail: symbol.detail.clone(),
                    score,
                    metrics: symbol.metrics.clone(),
                    tech_debt,
                })
            } else {
                None
            }
        })
        .collect();

    // Sort by score descending. Tie-break fields are fixed so ordering does not
    // fluctuate across runs when scores are identical.
    results.par_sort_unstable_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.uri.cmp(&b.uri))
            .then_with(|| a.range.start.line.cmp(&b.range.start.line))
            .then_with(|| a.range.start.character.cmp(&b.range.start.character))
            .then_with(|| a.symbol_id.cmp(&b.symbol_id))
    });

    // Limit results
    results.truncate(params.limit);

    Ok(SearchResult { symbols: results })
}

fn normalize_complexity_cap(complexity_cap: u32) -> f64 {
    f64::from(complexity_cap.max(1))
}

fn calculate_tech_debt(
    hotspot_score: f64,
    metrics: Option<&SymbolMetrics>,
    complexity_cap: f64,
) -> Option<f64> {
    metrics.map(|m| {
        let cc = (m.cyclomatic_complexity as f64).min(complexity_cap);
        hotspot_score * (cc / complexity_cap)
    })
}

fn resolve_candidates<'a>(index: &'a SymbolIndex, query_tokens: &[&str]) -> Vec<&'a Symbol> {
    let mut union_ids: HashSet<u32> = HashSet::new();
    for token in query_tokens {
        union_ids.extend(token_candidates(index, token));
    }

    union_ids
        .into_iter()
        .filter_map(|numeric_id| index.get_symbol_by_numeric_id(numeric_id))
        .collect()
}

fn token_candidates(index: &SymbolIndex, token: &str) -> HashSet<u32> {
    let mut name_candidates = token_candidates_for_domain(
        index,
        token,
        SymbolIndex::get_unigram_posting,
        SymbolIndex::get_bigram_posting,
        SymbolIndex::get_trigram_posting,
    );
    let container_candidates = token_candidates_for_domain(
        index,
        token,
        SymbolIndex::get_container_unigram_posting,
        SymbolIndex::get_container_bigram_posting,
        SymbolIndex::get_container_trigram_posting,
    );
    name_candidates.extend(container_candidates);
    name_candidates
}

fn token_candidates_for_domain(
    index: &SymbolIndex,
    token: &str,
    unigram_lookup: UnigramLookup,
    bigram_lookup: NgramLookup,
    trigram_lookup: NgramLookup,
) -> HashSet<u32> {
    let char_count = token.chars().count();
    if char_count == 0 {
        return HashSet::new();
    }

    if char_count == 1 {
        let Some(ch) = token.chars().next() else {
            return HashSet::new();
        };
        return unigram_lookup(index, ch)
            .map(|ids| ids.iter().copied().collect())
            .unwrap_or_default();
    }

    let candidates = if char_count == 2 {
        substring_candidates(index, token, 2, bigram_lookup)
    } else {
        substring_candidates(index, token, 3, trigram_lookup)
    };

    if candidates.is_empty() {
        return fuzzy_candidates(index, token, unigram_lookup);
    }

    candidates
}

fn substring_candidates(
    index: &SymbolIndex,
    token: &str,
    n: usize,
    posting_lookup: NgramLookup,
) -> HashSet<u32> {
    let ngrams = collect_ngrams(token, n);
    if ngrams.is_empty() {
        return HashSet::new();
    }

    let mut postings = Vec::with_capacity(ngrams.len());
    for ngram in ngrams {
        let posting = posting_lookup(index, &ngram);
        let Some(posting) = posting else {
            return HashSet::new();
        };
        postings.push(posting);
    }
    intersect_postings(postings)
}

fn fuzzy_candidates(
    index: &SymbolIndex,
    token: &str,
    unigram_lookup: UnigramLookup,
) -> HashSet<u32> {
    let unique_chars = collect_unique_chars(token);
    if unique_chars.is_empty() {
        return HashSet::new();
    }

    let mut postings = Vec::with_capacity(unique_chars.len());
    for ch in unique_chars {
        let Some(posting) = unigram_lookup(index, ch) else {
            return HashSet::new();
        };
        postings.push(posting);
    }
    intersect_postings(postings)
}

fn intersect_postings(postings: Vec<&[u32]>) -> HashSet<u32> {
    if postings.is_empty() {
        return HashSet::new();
    }

    let mut sorted_postings = postings;
    sorted_postings.sort_by_key(|posting| posting.len());

    let mut intersection_counts: HashMap<u32, usize> =
        HashMap::with_capacity(sorted_postings[0].len());
    for id in sorted_postings[0].iter().copied() {
        intersection_counts.entry(id).or_insert(1);
    }

    for (posting_idx, posting) in sorted_postings.into_iter().enumerate().skip(1) {
        if intersection_counts.is_empty() {
            break;
        }

        let expected_count = posting_idx;
        for id in posting {
            if let Some(count) = intersection_counts.get_mut(id) {
                if *count == expected_count {
                    *count += 1;
                }
            }
        }

        let next_expected = expected_count + 1;
        intersection_counts.retain(|_, count| *count == next_expected);
    }

    intersection_counts.into_keys().collect()
}

/// Calculate search score for a symbol
fn calculate_score(symbol: &Symbol, query_tokens: &[&str], index: &SymbolIndex) -> f64 {
    let kind_multiplier = calculate_kind_multiplier(symbol.kind);
    let hotspot_multiplier = calculate_hotspot_multiplier(index.get_hotspot_score(&symbol.uri));
    let complexity_multiplier = calculate_complexity_multiplier(&symbol.metrics);

    if query_tokens.is_empty() {
        return 1.0 * kind_multiplier * hotspot_multiplier * complexity_multiplier;
    }

    let name_lower = symbol.name.to_lowercase();
    let container_lower = symbol.container_name.as_ref().map(|c| c.to_lowercase());
    let mut name_score_total = 0.0;
    let mut container_bonus_total = 0.0;

    for token in query_tokens {
        name_score_total += calculate_name_score(match_grade(&name_lower, token));
        if let Some(container) = container_lower.as_deref() {
            container_bonus_total += calculate_container_bonus(match_grade(container, token));
        }
    }

    let container_cap_base = name_score_total.max(CONTAINER_ONLY_NAME_BASE);
    let clamped_container_bonus =
        container_bonus_total.min(container_cap_base * CONTAINER_BONUS_RATIO_CAP);
    let raw_score = name_score_total + clamped_container_bonus;
    if raw_score <= 0.0 {
        return 0.0;
    }

    raw_score * kind_multiplier * hotspot_multiplier * complexity_multiplier
}

fn match_grade(text: &str, token: &str) -> MatchGrade {
    if text.is_empty() || token.is_empty() {
        return MatchGrade::None;
    }
    if text == token {
        MatchGrade::Exact
    } else if text.starts_with(token) {
        MatchGrade::Prefix
    } else if text.contains(token) {
        MatchGrade::Substring
    } else if is_subsequence(text, token) {
        MatchGrade::Subsequence
    } else {
        MatchGrade::None
    }
}

fn calculate_name_score(grade: MatchGrade) -> f64 {
    match grade {
        MatchGrade::Exact => NAME_SCORE_EXACT,
        MatchGrade::Prefix => NAME_SCORE_PREFIX,
        MatchGrade::Substring => NAME_SCORE_SUBSTRING,
        MatchGrade::Subsequence => NAME_SCORE_SUBSEQUENCE,
        MatchGrade::None => 0.0,
    }
}

fn calculate_container_bonus(grade: MatchGrade) -> f64 {
    match grade {
        MatchGrade::Exact => CONTAINER_SCORE_EXACT,
        MatchGrade::Prefix => CONTAINER_SCORE_PREFIX,
        MatchGrade::Substring => CONTAINER_SCORE_SUBSTRING,
        MatchGrade::Subsequence => CONTAINER_SCORE_SUBSEQUENCE,
        MatchGrade::None => 0.0,
    }
}

fn calculate_kind_multiplier(kind: u32) -> f64 {
    match kind {
        12 | 6 | 9 => 1.15,      // Function, Method, Constructor
        5 | 11 | 23 => 1.08,     // Class, Interface, Struct
        7 | 8 | 13 | 14 => 1.03, // Property, Field, Variable, Constant
        _ => 1.0,
    }
}

fn calculate_hotspot_multiplier(raw_hotspot: f64) -> f64 {
    let hotspot = if raw_hotspot.is_finite() {
        raw_hotspot.clamp(0.0, 1.0)
    } else {
        0.0
    };
    1.0 + hotspot * HOTSPOT_BOOST_FACTOR
}

fn calculate_complexity_multiplier(metrics: &Option<SymbolMetrics>) -> f64 {
    match metrics {
        Some(m) => {
            let cc = (m.cyclomatic_complexity as f64).max(1.0);
            1.0 + cc.ln() * COMPLEXITY_BOOST_FACTOR
        }
        None => 1.0,
    }
}

/// Check if pattern is a subsequence of text
/// Optimized to avoid Vec<char> allocation by iterating directly
fn is_subsequence(text: &str, pattern: &str) -> bool {
    let mut text_iter = text.chars();
    for pattern_char in pattern.chars() {
        loop {
            match text_iter.next() {
                Some(text_char) if text_char == pattern_char => break,
                Some(_) => continue,
                None => return false,
            }
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::SymbolIndex;

    fn create_test_symbol(name: &str, kind: u32, uri: &str) -> Symbol {
        Symbol {
            symbol_id: String::new(),
            name: name.to_string(),
            kind,
            container_name: None,
            uri: uri.to_string(),
            range: crate::index::Range {
                start: crate::index::Position {
                    line: 0,
                    character: 0,
                },
                end: crate::index::Position {
                    line: 0,
                    character: 10,
                },
            },
            detail: None,
            metrics: None,
        }
    }

    fn create_test_symbol_with_container(
        name: &str,
        kind: u32,
        uri: &str,
        container: &str,
    ) -> Symbol {
        let mut symbol = create_test_symbol(name, kind, uri);
        symbol.container_name = Some(container.to_string());
        symbol
    }

    #[test]
    fn test_search_with_kind_filter() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![create_test_symbol("myFunc", 12, "file1.lua")],
            )
            .expect("upsert symbols should succeed"); // Function
        index
            .upsert_symbols(
                "file2.lua",
                vec![create_test_symbol("MyClass", 5, "file2.lua")],
            )
            .expect("upsert symbols should succeed"); // Class
        index
            .upsert_symbols(
                "file3.lua",
                vec![create_test_symbol("myVar", 13, "file3.lua")],
            )
            .expect("upsert symbols should succeed"); // Variable

        // Search without filter
        let params = SearchParams {
            q: "my".to_string(),
            limit: 50,
            complexity_cap: 50,
            filters: SearchFilters { kinds: None },
        };
        let result = search(&index, params).unwrap();
        assert_eq!(result.symbols.len(), 3);

        // Search with Function filter (kind 12)
        let params = SearchParams {
            q: "my".to_string(),
            limit: 50,
            complexity_cap: 50,
            filters: SearchFilters {
                kinds: Some(vec![12]),
            },
        };
        let result = search(&index, params).unwrap();
        assert_eq!(result.symbols.len(), 1);
        assert_eq!(result.symbols[0].name, "myFunc");

        // Search with Class filter (kind 5)
        let params = SearchParams {
            q: "my".to_string(),
            limit: 50,
            complexity_cap: 50,
            filters: SearchFilters {
                kinds: Some(vec![5]),
            },
        };
        let result = search(&index, params).unwrap();
        assert_eq!(result.symbols.len(), 1);
        assert_eq!(result.symbols[0].name, "MyClass");
    }

    #[test]
    fn test_search_with_multiple_kind_filter() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![create_test_symbol("myFunc", 12, "file1.lua")],
            )
            .expect("upsert symbols should succeed"); // Function
        index
            .upsert_symbols(
                "file2.lua",
                vec![create_test_symbol("myMethod", 6, "file2.lua")],
            )
            .expect("upsert symbols should succeed"); // Method
        index
            .upsert_symbols(
                "file3.lua",
                vec![create_test_symbol("MyClass", 5, "file3.lua")],
            )
            .expect("upsert symbols should succeed"); // Class

        // Search with Func filter (Method=6, Constructor=9, Function=12)
        let params = SearchParams {
            q: "my".to_string(),
            limit: 50,
            complexity_cap: 50,
            filters: SearchFilters {
                kinds: Some(vec![6, 9, 12]),
            },
        };
        let result = search(&index, params).unwrap();
        assert_eq!(result.symbols.len(), 2);

        let names: Vec<&str> = result.symbols.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"myFunc"));
        assert!(names.contains(&"myMethod"));
        assert!(!names.contains(&"MyClass"));
    }

    #[test]
    fn test_search_empty_query_with_filter() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![create_test_symbol("testFunc", 12, "file1.lua")],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file2.lua",
                vec![create_test_symbol("TestClass", 5, "file2.lua")],
            )
            .expect("upsert symbols should succeed");

        // Empty query with filter should return filtered results
        let params = SearchParams {
            q: "".to_string(),
            limit: 50,
            complexity_cap: 50,
            filters: SearchFilters {
                kinds: Some(vec![12]),
            },
        };
        let result = search(&index, params).unwrap();
        assert_eq!(result.symbols.len(), 1);
        assert_eq!(result.symbols[0].name, "testFunc");
    }

    #[test]
    fn test_search_no_match_with_filter() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![create_test_symbol("testFunc", 12, "file1.lua")],
            )
            .expect("upsert symbols should succeed");

        // Search with Class filter when only Function exists
        let params = SearchParams {
            q: "test".to_string(),
            limit: 50,
            complexity_cap: 50,
            filters: SearchFilters {
                kinds: Some(vec![5]),
            },
        };
        let result = search(&index, params).unwrap();
        assert_eq!(result.symbols.len(), 0);
    }

    #[test]
    fn test_search_uses_trigram_candidates() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![
                    create_test_symbol("formatDate", 12, "file1.lua"),
                    create_test_symbol("parseDate", 12, "file1.lua"),
                    create_test_symbol("unrelated", 12, "file1.lua"),
                ],
            )
            .expect("upsert symbols should succeed");

        let params = SearchParams {
            q: "format".to_string(),
            limit: 50,
            complexity_cap: 50,
            filters: SearchFilters::default(),
        };
        let result = search(&index, params).unwrap();

        assert!(!result.symbols.is_empty());
        let names: Vec<&str> = result.symbols.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"formatDate"));
    }

    #[test]
    fn test_token_candidates_uses_unigram_for_single_char() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![
                    create_test_symbol("formatDate", 12, "file1.lua"),
                    create_test_symbol("parseDate", 12, "file1.lua"),
                ],
            )
            .expect("upsert symbols should succeed");

        let candidate_ids = token_candidates(&index, "f");
        let names: HashSet<String> = candidate_ids
            .into_iter()
            .filter_map(|id| index.get_symbol_by_numeric_id(id))
            .map(|symbol| symbol.name.clone())
            .collect();

        assert_eq!(names.len(), 1);
        assert!(names.contains("formatDate"));
    }

    #[test]
    fn test_token_candidates_short_query_keeps_fuzzy_matches() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![
                    create_test_symbol("formatDate", 12, "file1.lua"),
                    create_test_symbol("parseDate", 12, "file1.lua"),
                    create_test_symbol("unrelated", 12, "file1.lua"),
                ],
            )
            .expect("upsert symbols should succeed");

        let candidate_ids = token_candidates(&index, "fd");
        let names: HashSet<String> = candidate_ids
            .into_iter()
            .filter_map(|id| index.get_symbol_by_numeric_id(id))
            .map(|symbol| symbol.name.clone())
            .collect();

        assert!(names.contains("formatDate"));
    }

    #[test]
    fn test_token_candidates_include_container_postings() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![create_test_symbol_with_container(
                    "alpha",
                    12,
                    "file1.lua",
                    "Utils",
                )],
            )
            .expect("upsert symbols should succeed");

        let candidate_ids = token_candidates(&index, "utils");
        let names: HashSet<String> = candidate_ids
            .into_iter()
            .filter_map(|id| index.get_symbol_by_numeric_id(id))
            .map(|symbol| symbol.name.clone())
            .collect();

        assert!(names.contains("alpha"));
    }

    #[test]
    fn test_calculate_score_container_only_query_is_positive() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![create_test_symbol_with_container(
                    "alpha",
                    12,
                    "file1.lua",
                    "Utils",
                )],
            )
            .expect("upsert symbols should succeed");
        let symbol = index.all_symbols().pop().expect("symbol should exist");

        let score = calculate_score(symbol, &["utils"], &index);
        assert!(score > 0.0);
    }

    #[test]
    fn test_complexity_multiplier_with_no_metrics() {
        assert_eq!(calculate_complexity_multiplier(&None), 1.0);
    }

    #[test]
    fn test_complexity_multiplier_increases_with_cc() {
        let low = calculate_complexity_multiplier(&Some(SymbolMetrics {
            cyclomatic_complexity: 1,
            lines_of_code: 5,
            nesting_depth: 0,
        }));
        let high = calculate_complexity_multiplier(&Some(SymbolMetrics {
            cyclomatic_complexity: 20,
            lines_of_code: 100,
            nesting_depth: 5,
        }));
        assert!(high > low, "higher CC should produce higher multiplier");
        assert!(low >= 1.0, "multiplier should be >= 1.0");
    }

    #[test]
    fn test_search_result_includes_tech_debt() {
        let mut index = SymbolIndex::new();
        let mut sym = create_test_symbol("complex_func", 12, "file:///hot.lua");
        sym.metrics = Some(SymbolMetrics {
            cyclomatic_complexity: 25,
            lines_of_code: 80,
            nesting_depth: 4,
        });
        index
            .upsert_symbols("file:///hot.lua", vec![sym])
            .expect("upsert should succeed");

        let mut scores = std::collections::HashMap::new();
        scores.insert("file:///hot.lua".to_string(), 0.9);
        index.set_hotspot_scores(scores);

        let result = search(
            &index,
            SearchParams {
                q: "complex_func".to_string(),
                limit: 10,
                complexity_cap: 50,
                filters: SearchFilters::default(),
            },
        )
        .expect("search should succeed");

        assert_eq!(result.symbols.len(), 1);
        let item = &result.symbols[0];
        assert!(item.metrics.is_some());
        assert!(item.tech_debt.is_some());
        let td = item.tech_debt.unwrap();
        assert!(
            td > 0.0,
            "tech_debt should be positive for hotspot file with CC"
        );
        assert!(td <= 1.0, "tech_debt should be <= 1.0");
    }

    #[test]
    fn test_search_result_uses_complexity_cap_param() {
        let mut index = SymbolIndex::new();
        let mut sym = create_test_symbol("complex_func", 12, "file:///hot.lua");
        sym.metrics = Some(SymbolMetrics {
            cyclomatic_complexity: 25,
            lines_of_code: 80,
            nesting_depth: 4,
        });
        index
            .upsert_symbols("file:///hot.lua", vec![sym])
            .expect("upsert should succeed");

        let mut scores = std::collections::HashMap::new();
        scores.insert("file:///hot.lua".to_string(), 0.9);
        index.set_hotspot_scores(scores);

        let high_cap_result = search(
            &index,
            SearchParams {
                q: "complex_func".to_string(),
                limit: 10,
                complexity_cap: 100,
                filters: SearchFilters::default(),
            },
        )
        .expect("search should succeed");

        let low_cap_result = search(
            &index,
            SearchParams {
                q: "complex_func".to_string(),
                limit: 10,
                complexity_cap: 20,
                filters: SearchFilters::default(),
            },
        )
        .expect("search should succeed");

        let high_cap = high_cap_result.symbols[0]
            .tech_debt
            .expect("tech_debt should exist");
        let low_cap = low_cap_result.symbols[0]
            .tech_debt
            .expect("tech_debt should exist");

        assert!(
            low_cap > high_cap,
            "smaller complexity_cap should increase tech_debt"
        );
    }

    #[test]
    fn test_search_result_no_tech_debt_without_metrics() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file:///plain.lua",
                vec![create_test_symbol("plain_func", 12, "file:///plain.lua")],
            )
            .expect("upsert should succeed");

        let result = search(
            &index,
            SearchParams {
                q: "plain_func".to_string(),
                limit: 10,
                complexity_cap: 50,
                filters: SearchFilters::default(),
            },
        )
        .expect("search should succeed");

        assert_eq!(result.symbols.len(), 1);
        assert!(result.symbols[0].metrics.is_none());
        assert!(result.symbols[0].tech_debt.is_none());
    }

    #[test]
    fn test_hotspot_multiplier_is_clamped() {
        assert_eq!(
            calculate_hotspot_multiplier(1.0),
            calculate_hotspot_multiplier(10.0)
        );
        assert_eq!(
            calculate_hotspot_multiplier(0.0),
            calculate_hotspot_multiplier(-1.0)
        );
    }

    #[test]
    fn test_resolve_candidates_returns_empty_when_no_index_hit() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file1.lua",
                vec![create_test_symbol("formatDate", 12, "file1.lua")],
            )
            .expect("upsert symbols should succeed");

        let candidates = resolve_candidates(&index, &["zzzunknown"]);
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_intersect_postings_handles_duplicate_ids_without_extra_sets() {
        let postings = vec![&[1, 1, 2, 3][..], &[2, 2, 1][..], &[4, 1, 2][..]];
        let result = intersect_postings(postings);

        assert_eq!(result.len(), 2);
        assert!(result.contains(&1));
        assert!(result.contains(&2));
    }

    #[test]
    fn test_search_tie_breaker_is_stable_for_same_score() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file:///b.lua",
                vec![create_test_symbol("target", 12, "file:///b.lua")],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file:///a.lua",
                vec![create_test_symbol("target", 12, "file:///a.lua")],
            )
            .expect("upsert symbols should succeed");

        let result = search(
            &index,
            SearchParams {
                q: "target".to_string(),
                limit: 10,
                complexity_cap: 50,
                filters: SearchFilters::default(),
            },
        )
        .expect("search should succeed");

        assert_eq!(result.symbols.len(), 2);
        assert_eq!(result.symbols[0].uri, "file:///a.lua");
        assert_eq!(result.symbols[1].uri, "file:///b.lua");
    }
}
