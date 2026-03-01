use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

/// Metrics for a symbol (cyclomatic complexity, LOC, nesting depth)
#[derive(
    Debug, Clone, Serialize, Deserialize, rkyv::Archive, rkyv::Serialize, rkyv::Deserialize,
)]
pub struct SymbolMetrics {
    pub cyclomatic_complexity: u32,
    pub lines_of_code: u32,
    pub nesting_depth: u32,
}

/// Symbol record as defined in DESIGN.md
#[derive(
    Debug, Clone, Serialize, Deserialize, rkyv::Archive, rkyv::Serialize, rkyv::Deserialize,
)]
pub struct Symbol {
    pub symbol_id: String,
    pub name: String,
    pub kind: u32, // LSP SymbolKind
    #[serde(default)]
    pub container_name: Option<String>,
    pub uri: String,
    pub range: Range,
    #[serde(default)]
    pub detail: Option<String>,
    #[serde(default)]
    pub metrics: Option<SymbolMetrics>,
}

/// Edge kind for call graph edges (DESIGN.md 4.2)
#[derive(
    Debug,
    Clone,
    Copy,
    PartialEq,
    Eq,
    Hash,
    Default,
    Serialize,
    Deserialize,
    rkyv::Archive,
    rkyv::Serialize,
    rkyv::Deserialize,
)]
#[serde(rename_all = "lowercase")]
pub enum EdgeKind {
    #[default]
    Call,
    Reference,
    Import,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct EdgeKey {
    caller_symbol_id: String,
    callee_symbol_id: String,
    edge_kind: EdgeKind,
}

impl From<&Edge> for EdgeKey {
    fn from(edge: &Edge) -> Self {
        Self {
            caller_symbol_id: edge.caller_symbol_id.clone(),
            callee_symbol_id: edge.callee_symbol_id.clone(),
            edge_kind: edge.edge_kind,
        }
    }
}

/// Graph edge for call graph (DESIGN.md 4.2)
#[derive(
    Debug, Clone, Serialize, Deserialize, rkyv::Archive, rkyv::Serialize, rkyv::Deserialize,
)]
pub struct Edge {
    pub caller_symbol_id: String,
    pub callee_symbol_id: String,
    pub edge_kind: EdgeKind,
    /// Evidence location where the call/reference occurs
    pub evidence: Evidence,
}

/// Evidence location for an edge
#[derive(
    Debug, Clone, Serialize, Deserialize, rkyv::Archive, rkyv::Serialize, rkyv::Deserialize,
)]
pub struct Evidence {
    pub uri: String,
    pub range: Range,
}

#[derive(
    Debug, Clone, Serialize, Deserialize, rkyv::Archive, rkyv::Serialize, rkyv::Deserialize,
)]
pub struct Range {
    pub start: Position,
    pub end: Position,
}

#[derive(
    Debug, Clone, Serialize, Deserialize, rkyv::Archive, rkyv::Serialize, rkyv::Deserialize,
)]
pub struct Position {
    pub line: u32,
    pub character: u32,
}

/// Generate stable symbol_id from symbol fields.
/// Format is intentionally aligned with previous Lua implementation.
pub fn generate_symbol_id(uri: &str, name: &str, kind: u32, range: &Range) -> String {
    let data = format!(
        "{}:{}:{}:{}:{}:{}:{}",
        uri,
        name,
        kind,
        range.start.line,
        range.start.character,
        range.end.line,
        range.end.character
    );
    let digest = Sha256::digest(data.as_bytes());
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        let _ = write!(&mut out, "{:02x}", b);
    }
    out
}

pub fn collect_unique_chars(text: &str) -> Vec<char> {
    if text.is_empty() {
        return Vec::new();
    }

    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for ch in text.chars() {
        if seen.insert(ch) {
            out.push(ch);
        }
    }
    out
}

pub fn collect_ngrams(text: &str, n: usize) -> Vec<String> {
    if text.is_empty() || n == 0 {
        return Vec::new();
    }

    let mut seen = HashSet::new();
    let chars: Vec<char> = text.chars().collect();
    if chars.len() < n {
        return Vec::new();
    }

    let mut ngrams = Vec::new();
    for i in 0..=(chars.len() - n) {
        let ngram: String = chars[i..(i + n)].iter().collect();
        if seen.insert(ngram.clone()) {
            ngrams.push(ngram);
        }
    }
    ngrams
}

/// Index store for symbols and edges
#[derive(Default)]
struct SearchIndexStore {
    symbols: HashMap<String, Symbol>,            // symbol_id -> Symbol
    by_uri: HashMap<String, Vec<String>>,        // uri -> [symbol_id]
    symbol_numeric_ids: HashMap<String, u32>,    // symbol_id -> numeric_id
    numeric_to_symbol_ids: Vec<Option<String>>,  // numeric_id -> symbol_id (None = vacant)
    free_numeric_ids: Vec<u32>,                  // reusable numeric IDs
    trigram_postings: HashMap<String, Vec<u32>>, // trigram -> [numeric_id]
    bigram_postings: HashMap<String, Vec<u32>>,  // bigram -> [numeric_id]
    unigram_postings: HashMap<char, Vec<u32>>,   // character -> [numeric_id]
    container_trigram_postings: HashMap<String, Vec<u32>>, // trigram -> [numeric_id]
    container_bigram_postings: HashMap<String, Vec<u32>>, // bigram -> [numeric_id]
    container_unigram_postings: HashMap<char, Vec<u32>>, // character -> [numeric_id]
}

#[derive(Default)]
struct HotspotStore {
    scores: HashMap<String, f64>, // uri -> score
}

#[derive(Default)]
struct GraphStore {
    edges: Vec<Edge>,                             // all edges
    edge_lookup: HashMap<EdgeKey, usize>,         // edge key -> edge index
    edges_by_caller: HashMap<String, Vec<usize>>, // caller_symbol_id -> [edge indices]
    edges_by_callee: HashMap<String, Vec<usize>>, // callee_symbol_id -> [edge indices]
}

pub struct SymbolIndex {
    search: SearchIndexStore,
    hotspots: HotspotStore,
    graph: GraphStore,
}

impl SymbolIndex {
    pub fn new() -> Self {
        Self {
            search: SearchIndexStore::default(),
            hotspots: HotspotStore::default(),
            graph: GraphStore::default(),
        }
    }

    /// Upsert symbols for a URI
    pub fn upsert_symbols(&mut self, uri: &str, symbols: Vec<Symbol>) -> Result<()> {
        // Remove old symbols for this URI
        if let Some(old_ids) = self.search.by_uri.remove(uri) {
            for id in old_ids {
                if let Some(old_symbol) = self.search.symbols.remove(&id) {
                    self.remove_symbol_from_search_postings(&old_symbol);
                }
            }
        }

        // Insert new symbols
        let mut new_ids = Vec::new();
        let mut seen_ids = HashSet::new();
        for mut symbol in symbols {
            symbol.symbol_id =
                generate_symbol_id(&symbol.uri, &symbol.name, symbol.kind, &symbol.range);
            let symbol_id = symbol.symbol_id.clone();
            if !seen_ids.insert(symbol_id.clone()) {
                continue;
            }

            if let Some(existing) = self.search.symbols.remove(&symbol_id) {
                self.remove_symbol_from_search_postings(&existing);
            }

            self.add_symbol_to_search_postings(&symbol)?;
            new_ids.push(symbol_id.clone());
            self.search.symbols.insert(symbol_id, symbol);
        }
        self.search.by_uri.insert(uri.to_string(), new_ids);
        Ok(())
    }

    /// Remove all symbols for a URI
    pub fn remove_uri(&mut self, uri: &str) {
        if let Some(ids) = self.search.by_uri.remove(uri) {
            for id in ids {
                if let Some(symbol) = self.search.symbols.remove(&id) {
                    self.remove_symbol_from_search_postings(&symbol);
                }
            }
        }
    }

    /// Remove all symbols for multiple URIs
    pub fn remove_uris(&mut self, uris: Vec<String>) {
        for uri in uris {
            self.remove_uri(&uri);
        }
    }

    /// Get all symbols
    pub fn all_symbols(&self) -> Vec<&Symbol> {
        self.search.symbols.values().collect()
    }

    /// Get symbol by numeric id
    pub fn get_symbol_by_numeric_id(&self, numeric_id: u32) -> Option<&Symbol> {
        let symbol_id = self.search.numeric_to_symbol_ids.get(numeric_id as usize)?;
        self.search.symbols.get(symbol_id.as_deref()?)
    }

    /// Get symbol by symbol id
    pub fn get_symbol(&self, symbol_id: &str) -> Option<&Symbol> {
        self.search.symbols.get(symbol_id)
    }

    /// Get posting list for trigram
    pub fn get_trigram_posting(&self, trigram: &str) -> Option<&[u32]> {
        self.search
            .trigram_postings
            .get(trigram)
            .map(|ids| ids.as_slice())
    }

    /// Get posting list for bigram
    pub fn get_bigram_posting(&self, bigram: &str) -> Option<&[u32]> {
        self.search
            .bigram_postings
            .get(bigram)
            .map(|ids| ids.as_slice())
    }

    /// Get posting list for unigram
    pub fn get_unigram_posting(&self, ch: char) -> Option<&[u32]> {
        self.search
            .unigram_postings
            .get(&ch)
            .map(|ids| ids.as_slice())
    }

    /// Get posting list for container trigram
    pub fn get_container_trigram_posting(&self, trigram: &str) -> Option<&[u32]> {
        self.search
            .container_trigram_postings
            .get(trigram)
            .map(|ids| ids.as_slice())
    }

    /// Get posting list for container bigram
    pub fn get_container_bigram_posting(&self, bigram: &str) -> Option<&[u32]> {
        self.search
            .container_bigram_postings
            .get(bigram)
            .map(|ids| ids.as_slice())
    }

    /// Get posting list for container unigram
    pub fn get_container_unigram_posting(&self, ch: char) -> Option<&[u32]> {
        self.search
            .container_unigram_postings
            .get(&ch)
            .map(|ids| ids.as_slice())
    }

    /// Set hotspot scores
    pub fn set_hotspot_scores(&mut self, scores: HashMap<String, f64>) {
        self.hotspots.scores = scores;
    }

    /// Get hotspot score for a URI
    pub fn get_hotspot_score(&self, uri: &str) -> f64 {
        self.hotspots.scores.get(uri).copied().unwrap_or(0.0)
    }

    /// Get symbol count
    pub fn symbol_count(&self) -> usize {
        self.search.symbols.len()
    }

    /// Get URI count
    pub fn uri_count(&self) -> usize {
        self.search.by_uri.len()
    }

    /// Get all hotspot scores
    pub fn get_hotspot_scores(&self) -> &HashMap<String, f64> {
        &self.hotspots.scores
    }

    // --- Graph edge methods ---

    /// Upsert edges for call graph
    pub fn upsert_edges(&mut self, edges: Vec<Edge>) {
        for edge in edges {
            let key = EdgeKey::from(&edge);
            if let Some(existing_idx) = self.graph.edge_lookup.get(&key).copied() {
                if let Some(existing) = self.graph.edges.get_mut(existing_idx) {
                    existing.evidence = edge.evidence;
                }
                continue;
            }

            let edge_idx = self.graph.edges.len();
            let caller_symbol_id = edge.caller_symbol_id.clone();
            let callee_symbol_id = edge.callee_symbol_id.clone();
            self.graph.edges.push(edge);
            self.graph.edge_lookup.insert(key, edge_idx);

            // Index by caller
            self.graph
                .edges_by_caller
                .entry(caller_symbol_id)
                .or_default()
                .push(edge_idx);

            // Index by callee
            self.graph
                .edges_by_callee
                .entry(callee_symbol_id)
                .or_default()
                .push(edge_idx);
        }
    }

    /// Get edges where the given symbol is the caller
    pub fn get_outgoing_edges(&self, symbol_id: &str) -> Vec<&Edge> {
        self.graph
            .edges_by_caller
            .get(symbol_id)
            .map(|indices| {
                indices
                    .iter()
                    .filter_map(|&i| self.graph.edges.get(i))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Get edges where the given symbol is the callee
    pub fn get_incoming_edges(&self, symbol_id: &str) -> Vec<&Edge> {
        self.graph
            .edges_by_callee
            .get(symbol_id)
            .map(|indices| {
                indices
                    .iter()
                    .filter_map(|&i| self.graph.edges.get(i))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Get edge count
    pub fn edge_count(&self) -> usize {
        self.graph.edges.len()
    }

    /// Clear all edges
    pub fn clear_edges(&mut self) {
        self.graph.edges.clear();
        self.graph.edge_lookup.clear();
        self.graph.edges_by_caller.clear();
        self.graph.edges_by_callee.clear();
    }

    /// Get all edges
    pub fn all_edges(&self) -> &[Edge] {
        &self.graph.edges
    }

    /// Get symbols grouped by URI
    pub fn get_by_uri(&self) -> &HashMap<String, Vec<String>> {
        &self.search.by_uri
    }

    /// Get stats for symbols whose URI starts with the given prefix
    pub fn stats_for_prefix(&self, uri_prefix: &str) -> (usize, usize, usize) {
        let mut symbol_count = 0;
        let mut uri_count = 0;
        let mut hotspot_count = 0;

        for (uri, ids) in &self.search.by_uri {
            if uri.starts_with(uri_prefix) {
                uri_count += 1;
                symbol_count += ids.len();
            }
        }
        for uri in self.hotspots.scores.keys() {
            if uri.starts_with(uri_prefix) {
                hotspot_count += 1;
            }
        }

        (symbol_count, uri_count, hotspot_count)
    }

    fn add_symbol_to_search_postings(&mut self, symbol: &Symbol) -> Result<()> {
        let numeric_id = self.resolve_numeric_id(&symbol.symbol_id)?;

        let lowered_name = symbol.name.to_lowercase();
        Self::add_text_to_postings(
            &lowered_name,
            numeric_id,
            &mut self.search.unigram_postings,
            &mut self.search.bigram_postings,
            &mut self.search.trigram_postings,
        );

        if let Some(ref container) = symbol.container_name {
            let lowered_container = container.to_lowercase();
            Self::add_text_to_postings(
                &lowered_container,
                numeric_id,
                &mut self.search.container_unigram_postings,
                &mut self.search.container_bigram_postings,
                &mut self.search.container_trigram_postings,
            );
        }
        Ok(())
    }

    fn remove_symbol_from_search_postings(&mut self, symbol: &Symbol) {
        let Some(numeric_id) = self
            .search
            .symbol_numeric_ids
            .get(&symbol.symbol_id)
            .copied()
        else {
            return;
        };

        let lowered_name = symbol.name.to_lowercase();
        Self::remove_text_from_postings(
            &lowered_name,
            numeric_id,
            &mut self.search.unigram_postings,
            &mut self.search.bigram_postings,
            &mut self.search.trigram_postings,
        );

        if let Some(ref container) = symbol.container_name {
            let lowered_container = container.to_lowercase();
            Self::remove_text_from_postings(
                &lowered_container,
                numeric_id,
                &mut self.search.container_unigram_postings,
                &mut self.search.container_bigram_postings,
                &mut self.search.container_trigram_postings,
            );
        }

        self.release_numeric_id(&symbol.symbol_id, numeric_id);
    }

    fn add_text_to_postings(
        text: &str,
        numeric_id: u32,
        unigram_postings: &mut HashMap<char, Vec<u32>>,
        bigram_postings: &mut HashMap<String, Vec<u32>>,
        trigram_postings: &mut HashMap<String, Vec<u32>>,
    ) {
        for ch in collect_unique_chars(text) {
            unigram_postings.entry(ch).or_default().push(numeric_id);
        }
        for bigram in collect_ngrams(text, 2) {
            bigram_postings.entry(bigram).or_default().push(numeric_id);
        }
        for trigram in collect_ngrams(text, 3) {
            trigram_postings
                .entry(trigram)
                .or_default()
                .push(numeric_id);
        }
    }

    fn remove_text_from_postings(
        text: &str,
        numeric_id: u32,
        unigram_postings: &mut HashMap<char, Vec<u32>>,
        bigram_postings: &mut HashMap<String, Vec<u32>>,
        trigram_postings: &mut HashMap<String, Vec<u32>>,
    ) {
        let mut empty_unigrams = Vec::new();
        for ch in collect_unique_chars(text) {
            if let Some(ids) = unigram_postings.get_mut(&ch) {
                ids.retain(|id| *id != numeric_id);
                if ids.is_empty() {
                    empty_unigrams.push(ch);
                }
            }
        }
        for ch in empty_unigrams {
            unigram_postings.remove(&ch);
        }

        let mut empty_bigrams = Vec::new();
        for bigram in collect_ngrams(text, 2) {
            if let Some(ids) = bigram_postings.get_mut(&bigram) {
                ids.retain(|id| *id != numeric_id);
                if ids.is_empty() {
                    empty_bigrams.push(bigram);
                }
            }
        }
        for bigram in empty_bigrams {
            bigram_postings.remove(&bigram);
        }

        let mut empty_trigrams = Vec::new();
        for trigram in collect_ngrams(text, 3) {
            if let Some(ids) = trigram_postings.get_mut(&trigram) {
                ids.retain(|id| *id != numeric_id);
                if ids.is_empty() {
                    empty_trigrams.push(trigram);
                }
            }
        }
        for trigram in empty_trigrams {
            trigram_postings.remove(&trigram);
        }
    }

    fn resolve_numeric_id(&mut self, symbol_id: &str) -> Result<u32> {
        if let Some(id) = self.search.symbol_numeric_ids.get(symbol_id).copied() {
            return Ok(id);
        }

        while let Some(free_id) = self.search.free_numeric_ids.pop() {
            if let Some(slot) = self.search.numeric_to_symbol_ids.get_mut(free_id as usize) {
                if slot.is_none() {
                    let owned_symbol_id = symbol_id.to_string();
                    *slot = Some(owned_symbol_id.clone());
                    self.search
                        .symbol_numeric_ids
                        .insert(owned_symbol_id, free_id);
                    return Ok(free_id);
                }
            }
        }

        let numeric_id = u32::try_from(self.search.numeric_to_symbol_ids.len())
            .map_err(|_| anyhow!("symbol index exceeded u32"))?;
        self.search
            .symbol_numeric_ids
            .insert(symbol_id.to_string(), numeric_id);
        self.search
            .numeric_to_symbol_ids
            .push(Some(symbol_id.to_string()));
        Ok(numeric_id)
    }

    fn release_numeric_id(&mut self, symbol_id: &str, numeric_id: u32) {
        self.search.symbol_numeric_ids.remove(symbol_id);

        let Some(slot) = self
            .search
            .numeric_to_symbol_ids
            .get_mut(numeric_id as usize)
        else {
            return;
        };

        if slot.take().is_some() {
            self.search.free_numeric_ids.push(numeric_id);
        }

        if (numeric_id as usize) + 1 == self.search.numeric_to_symbol_ids.len() {
            self.compact_numeric_id_tail();
        }
    }

    fn compact_numeric_id_tail(&mut self) {
        while self
            .search
            .numeric_to_symbol_ids
            .last()
            .is_some_and(|entry| entry.is_none())
        {
            self.search.numeric_to_symbol_ids.pop();
        }

        let max_slots = self.search.numeric_to_symbol_ids.len();
        self.search
            .free_numeric_ids
            .retain(|id| (*id as usize) < max_slots);
    }

    /// Get top symbols for a specific URI (DESIGN.md 4.3)
    /// Returns symbols sorted by relevance (hotspot score + kind priority)
    pub fn get_top_symbols(&self, uri: &str, limit: usize) -> Vec<&Symbol> {
        let symbol_ids = match self.search.by_uri.get(uri) {
            Some(ids) => ids,
            None => return Vec::new(),
        };

        let hotspot_score = self.get_hotspot_score(uri);

        // Collect symbols with scores
        let mut scored_symbols: Vec<(&Symbol, f64)> = symbol_ids
            .iter()
            .filter_map(|id| {
                let symbol = self.search.symbols.get(id)?;
                // Score based on kind priority and other factors
                let kind_score = match symbol.kind {
                    12 | 6 => 3.0,  // Function, Method - highest
                    5 | 23 => 2.5,  // Class, Interface
                    9 => 2.0,       // Constructor
                    14 | 15 => 1.5, // Constant, Property
                    13 => 1.0,      // Variable
                    _ => 0.5,       // Other
                };
                let complexity_boost = symbol.metrics.as_ref().map_or(1.0, |m| {
                    1.0 + (m.cyclomatic_complexity as f64).max(1.0).ln() * 0.10
                });
                let score = kind_score * (1.0 + hotspot_score * 0.5) * complexity_boost;
                Some((symbol, score))
            })
            .collect();

        // Sort by score descending
        scored_symbols.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        // Return top N
        scored_symbols
            .into_iter()
            .take(limit)
            .map(|(s, _)| s)
            .collect()
    }
}

impl Default for SymbolIndex {
    fn default() -> Self {
        Self::new()
    }
}

// --- RPC parameter types ---

#[derive(Debug, Deserialize)]
pub struct UpsertSymbolsParams {
    pub uri: String,
    pub symbols: Vec<Symbol>,
}

#[derive(Debug, Deserialize)]
pub struct RemoveUriParams {
    pub uri: String,
}

#[derive(Debug, Deserialize)]
pub struct RemoveUrisParams {
    pub uris: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct SetHotspotScoresParams {
    pub scores: HashMap<String, f64>,
}

#[derive(Debug, Deserialize)]
pub struct UpsertEdgesParams {
    pub edges: Vec<Edge>,
}

#[derive(Debug, Serialize)]
pub struct IndexStats {
    pub symbol_count: usize,
    pub uri_count: usize,
    pub hotspot_count: usize,
    pub edge_count: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_symbol(name: &str, kind: u32, uri: &str) -> Symbol {
        Symbol {
            symbol_id: String::new(),
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

    fn create_test_edge(caller: &str, callee: &str, kind: EdgeKind) -> Edge {
        Edge {
            caller_symbol_id: caller.to_string(),
            callee_symbol_id: callee.to_string(),
            edge_kind: kind,
            evidence: Evidence {
                uri: "file:///test.lua".to_string(),
                range: Range {
                    start: Position {
                        line: 1,
                        character: 0,
                    },
                    end: Position {
                        line: 1,
                        character: 20,
                    },
                },
            },
        }
    }

    #[test]
    fn test_upsert_edges() {
        let mut index = SymbolIndex::new();

        let edges = vec![
            create_test_edge("func_a", "func_b", EdgeKind::Call),
            create_test_edge("func_a", "func_c", EdgeKind::Call),
            create_test_edge("func_b", "func_d", EdgeKind::Reference),
        ];

        index.upsert_edges(edges);

        assert_eq!(index.edge_count(), 3);
    }

    #[test]
    fn test_upsert_edges_merges_duplicates() {
        let mut index = SymbolIndex::new();

        let mut first = create_test_edge("func_a", "func_b", EdgeKind::Call);
        first.evidence.range.start.line = 10;
        let mut second = create_test_edge("func_a", "func_b", EdgeKind::Call);
        second.evidence.range.start.line = 42;

        index.upsert_edges(vec![first]);
        index.upsert_edges(vec![second]);

        assert_eq!(index.edge_count(), 1);

        let outgoing = index.get_outgoing_edges("func_a");
        assert_eq!(outgoing.len(), 1);
        assert_eq!(outgoing[0].evidence.range.start.line, 42);
    }

    #[test]
    fn test_get_outgoing_edges() {
        let mut index = SymbolIndex::new();

        index.upsert_edges(vec![
            create_test_edge("func_a", "func_b", EdgeKind::Call),
            create_test_edge("func_a", "func_c", EdgeKind::Call),
            create_test_edge("func_b", "func_d", EdgeKind::Reference),
        ]);

        let outgoing = index.get_outgoing_edges("func_a");
        assert_eq!(outgoing.len(), 2);

        let outgoing_b = index.get_outgoing_edges("func_b");
        assert_eq!(outgoing_b.len(), 1);
        assert_eq!(outgoing_b[0].edge_kind, EdgeKind::Reference);

        let outgoing_d = index.get_outgoing_edges("func_d");
        assert_eq!(outgoing_d.len(), 0);
    }

    #[test]
    fn test_get_incoming_edges() {
        let mut index = SymbolIndex::new();

        index.upsert_edges(vec![
            create_test_edge("func_a", "func_b", EdgeKind::Call),
            create_test_edge("func_c", "func_b", EdgeKind::Call),
            create_test_edge("func_d", "func_b", EdgeKind::Reference),
        ]);

        let incoming = index.get_incoming_edges("func_b");
        assert_eq!(incoming.len(), 3);

        let incoming_a = index.get_incoming_edges("func_a");
        assert_eq!(incoming_a.len(), 0);
    }

    #[test]
    fn test_clear_edges() {
        let mut index = SymbolIndex::new();

        index.upsert_edges(vec![create_test_edge("func_a", "func_b", EdgeKind::Call)]);

        assert_eq!(index.edge_count(), 1);

        index.clear_edges();

        assert_eq!(index.edge_count(), 0);
        assert_eq!(index.get_outgoing_edges("func_a").len(), 0);
        assert_eq!(index.get_incoming_edges("func_b").len(), 0);
    }

    #[test]
    fn test_get_top_symbols() {
        let mut index = SymbolIndex::new();

        index
            .upsert_symbols(
                "file:///test.lua",
                vec![
                    create_test_symbol("myFunc", 12, "file:///test.lua"), // Function
                    create_test_symbol("MyClass", 5, "file:///test.lua"), // Class
                    create_test_symbol("myVar", 13, "file:///test.lua"),  // Variable
                ],
            )
            .expect("upsert symbols should succeed");

        // Set hotspot score
        let mut scores = HashMap::new();
        scores.insert("file:///test.lua".to_string(), 0.8);
        index.set_hotspot_scores(scores);

        let top = index.get_top_symbols("file:///test.lua", 10);
        assert_eq!(top.len(), 3);

        // Function should be first (highest priority)
        assert_eq!(top[0].name, "myFunc");
        // Class should be second
        assert_eq!(top[1].name, "MyClass");
        // Variable should be last
        assert_eq!(top[2].name, "myVar");
    }

    #[test]
    fn test_get_top_symbols_limit() {
        let mut index = SymbolIndex::new();

        index
            .upsert_symbols(
                "file:///test.lua",
                vec![
                    create_test_symbol("func1", 12, "file:///test.lua"),
                    create_test_symbol("func2", 12, "file:///test.lua"),
                    create_test_symbol("func3", 12, "file:///test.lua"),
                ],
            )
            .expect("upsert symbols should succeed");

        let top = index.get_top_symbols("file:///test.lua", 2);
        assert_eq!(top.len(), 2);
    }

    #[test]
    fn test_get_top_symbols_empty_uri() {
        let index = SymbolIndex::new();

        let top = index.get_top_symbols("file:///nonexistent.lua", 10);
        assert_eq!(top.len(), 0);
    }

    #[test]
    fn test_remove_uris_batch() {
        let mut index = SymbolIndex::new();

        index
            .upsert_symbols(
                "file:///a.lua",
                vec![create_test_symbol("func_a", 12, "file:///a.lua")],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file:///b.lua",
                vec![create_test_symbol("func_b", 12, "file:///b.lua")],
            )
            .expect("upsert symbols should succeed");

        assert_eq!(index.uri_count(), 2);
        assert_eq!(index.symbol_count(), 2);

        index.remove_uris(vec![
            "file:///a.lua".to_string(),
            "file:///b.lua".to_string(),
        ]);

        assert_eq!(index.uri_count(), 0);
        assert_eq!(index.symbol_count(), 0);
    }

    #[test]
    fn test_edge_kind_serialization() {
        let edge = create_test_edge("a", "b", EdgeKind::Call);
        let json = serde_json::to_string(&edge).unwrap();
        assert!(json.contains("\"call\""));

        let edge = create_test_edge("a", "b", EdgeKind::Reference);
        let json = serde_json::to_string(&edge).unwrap();
        assert!(json.contains("\"reference\""));

        let edge = create_test_edge("a", "b", EdgeKind::Import);
        let json = serde_json::to_string(&edge).unwrap();
        assert!(json.contains("\"import\""));
    }

    #[test]
    fn test_index_stats() {
        let mut index = SymbolIndex::new();

        index
            .upsert_symbols(
                "file:///test.lua",
                vec![create_test_symbol("func", 12, "file:///test.lua")],
            )
            .expect("upsert symbols should succeed");

        let mut scores = HashMap::new();
        scores.insert("file:///test.lua".to_string(), 0.5);
        index.set_hotspot_scores(scores);

        index.upsert_edges(vec![create_test_edge("a", "b", EdgeKind::Call)]);

        let stats = IndexStats {
            symbol_count: index.symbol_count(),
            uri_count: index.uri_count(),
            hotspot_count: index.get_hotspot_scores().len(),
            edge_count: index.edge_count(),
        };

        assert_eq!(stats.symbol_count, 1);
        assert_eq!(stats.uri_count, 1);
        assert_eq!(stats.hotspot_count, 1);
        assert_eq!(stats.edge_count, 1);
    }

    #[test]
    fn test_generate_symbol_id_is_stable() {
        let range = Range {
            start: Position {
                line: 1,
                character: 2,
            },
            end: Position {
                line: 3,
                character: 4,
            },
        };

        let id1 = generate_symbol_id("file:///a.lua", "myFunc", 12, &range);
        let id2 = generate_symbol_id("file:///a.lua", "myFunc", 12, &range);
        let id3 = generate_symbol_id("file:///a.lua", "otherFunc", 12, &range);

        assert_eq!(id1, id2);
        assert_ne!(id1, id3);
    }

    #[test]
    fn test_search_posting_cleanup_on_replace() {
        let mut index = SymbolIndex::new();

        index
            .upsert_symbols(
                "file:///test.lua",
                vec![create_test_symbol("formatDate", 12, "file:///test.lua")],
            )
            .expect("upsert symbols should succeed");
        assert!(index.get_trigram_posting("for").is_some());
        assert!(index.get_bigram_posting("or").is_some());
        assert!(index.get_unigram_posting('f').is_some());

        index
            .upsert_symbols(
                "file:///test.lua",
                vec![create_test_symbol("parseUser", 12, "file:///test.lua")],
            )
            .expect("upsert symbols should succeed");

        assert!(index.get_trigram_posting("for").is_none());
        assert!(index.get_bigram_posting("or").is_none());
        assert!(index.get_unigram_posting('f').is_none());
        assert!(index.get_trigram_posting("par").is_some());
        assert!(index.get_bigram_posting("pa").is_some());
        assert!(index.get_unigram_posting('p').is_some());
    }

    #[test]
    fn test_container_search_posting_cleanup_on_replace() {
        let mut index = SymbolIndex::new();

        index
            .upsert_symbols(
                "file:///test.lua",
                vec![create_test_symbol_with_container(
                    "alpha",
                    12,
                    "file:///test.lua",
                    "Utils",
                )],
            )
            .expect("upsert symbols should succeed");
        assert!(index.get_container_trigram_posting("uti").is_some());
        assert!(index.get_container_bigram_posting("ut").is_some());
        assert!(index.get_container_unigram_posting('u').is_some());

        index
            .upsert_symbols(
                "file:///test.lua",
                vec![create_test_symbol_with_container(
                    "beta",
                    12,
                    "file:///test.lua",
                    "Api",
                )],
            )
            .expect("upsert symbols should succeed");

        assert!(index.get_container_trigram_posting("uti").is_none());
        assert!(index.get_container_bigram_posting("ut").is_none());
        assert!(index.get_container_unigram_posting('u').is_none());
        assert!(index.get_container_trigram_posting("api").is_some());
        assert!(index.get_container_bigram_posting("ap").is_some());
        assert!(index.get_container_unigram_posting('a').is_some());
    }

    #[test]
    fn test_numeric_id_reuse_after_symbol_removal() {
        let mut index = SymbolIndex::new();

        index
            .upsert_symbols(
                "file:///a.lua",
                vec![create_test_symbol("alpha", 12, "file:///a.lua")],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file:///b.lua",
                vec![create_test_symbol("beta", 12, "file:///b.lua")],
            )
            .expect("upsert symbols should succeed");

        let reusable_id = *index
            .get_unigram_posting('l')
            .expect("alpha posting should exist")
            .first()
            .expect("alpha posting should have numeric id");

        index.remove_uri("file:///a.lua");
        index
            .upsert_symbols(
                "file:///c.lua",
                vec![create_test_symbol("gamma", 12, "file:///c.lua")],
            )
            .expect("upsert symbols should succeed");

        let gamma_ids = index
            .get_unigram_posting('g')
            .expect("gamma posting should exist");
        assert!(gamma_ids.contains(&reusable_id));
    }

    #[test]
    fn test_numeric_id_tail_compaction_trims_stale_slots() {
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file:///a.lua",
                vec![create_test_symbol("alpha", 12, "file:///a.lua")],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file:///b.lua",
                vec![create_test_symbol("beta", 12, "file:///b.lua")],
            )
            .expect("upsert symbols should succeed");

        assert_eq!(index.search.numeric_to_symbol_ids.len(), 2);
        index.remove_uri("file:///b.lua");

        assert_eq!(index.search.numeric_to_symbol_ids.len(), 1);
        assert!(index.search.free_numeric_ids.is_empty());
    }

    #[test]
    fn test_symbol_metrics_serialization() {
        let metrics = SymbolMetrics {
            cyclomatic_complexity: 5,
            lines_of_code: 30,
            nesting_depth: 3,
        };
        let json = serde_json::to_string(&metrics).unwrap();
        assert!(json.contains("\"cyclomatic_complexity\":5"));
        assert!(json.contains("\"lines_of_code\":30"));
        assert!(json.contains("\"nesting_depth\":3"));

        let parsed: SymbolMetrics = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.cyclomatic_complexity, 5);
        assert_eq!(parsed.lines_of_code, 30);
        assert_eq!(parsed.nesting_depth, 3);
    }

    #[test]
    fn test_symbol_with_metrics() {
        let mut symbol = create_test_symbol("myFunc", 12, "file:///test.lua");
        symbol.metrics = Some(SymbolMetrics {
            cyclomatic_complexity: 10,
            lines_of_code: 45,
            nesting_depth: 4,
        });

        let json = serde_json::to_string(&symbol).unwrap();
        assert!(json.contains("\"metrics\""));
        assert!(json.contains("\"cyclomatic_complexity\":10"));

        let parsed: Symbol = serde_json::from_str(&json).unwrap();
        assert!(parsed.metrics.is_some());
        let m = parsed.metrics.unwrap();
        assert_eq!(m.cyclomatic_complexity, 10);
        assert_eq!(m.lines_of_code, 45);
        assert_eq!(m.nesting_depth, 4);
    }

    #[test]
    fn test_symbol_without_metrics_defaults_to_none() {
        let json = r#"{
            "symbol_id": "",
            "name": "func",
            "kind": 12,
            "uri": "file:///test.lua",
            "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 10}}
        }"#;
        let parsed: Symbol = serde_json::from_str(json).unwrap();
        assert!(parsed.metrics.is_none());
    }

    #[test]
    fn test_get_top_symbols_with_metrics_boost() {
        let mut index = SymbolIndex::new();

        let mut sym_high_cc = create_test_symbol("highCC", 12, "file:///test.lua");
        sym_high_cc.metrics = Some(SymbolMetrics {
            cyclomatic_complexity: 20,
            lines_of_code: 100,
            nesting_depth: 5,
        });
        sym_high_cc.range.start.line = 0;
        sym_high_cc.range.end.line = 99;

        let mut sym_low_cc = create_test_symbol("lowCC", 12, "file:///test.lua");
        sym_low_cc.metrics = Some(SymbolMetrics {
            cyclomatic_complexity: 1,
            lines_of_code: 5,
            nesting_depth: 0,
        });
        sym_low_cc.range.start.line = 100;
        sym_low_cc.range.end.line = 104;

        index
            .upsert_symbols("file:///test.lua", vec![sym_high_cc, sym_low_cc])
            .expect("upsert symbols should succeed");

        let top = index.get_top_symbols("file:///test.lua", 10);
        assert_eq!(top.len(), 2);
        // Higher complexity should score higher
        assert_eq!(top[0].name, "highCC");
        assert_eq!(top[1].name, "lowCC");
    }

    #[test]
    fn test_stats_for_prefix() {
        let mut index = SymbolIndex::new();

        index
            .upsert_symbols(
                "file:///repo_a/src/main.lua",
                vec![
                    create_test_symbol("funcA1", 12, "file:///repo_a/src/main.lua"),
                    create_test_symbol("funcA2", 12, "file:///repo_a/src/main.lua"),
                ],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file:///repo_a/src/util.lua",
                vec![create_test_symbol(
                    "utilA",
                    12,
                    "file:///repo_a/src/util.lua",
                )],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file:///repo_b/src/main.lua",
                vec![create_test_symbol(
                    "funcB",
                    12,
                    "file:///repo_b/src/main.lua",
                )],
            )
            .expect("upsert symbols should succeed");

        let mut scores = HashMap::new();
        scores.insert("file:///repo_a/src/main.lua".to_string(), 0.8);
        scores.insert("file:///repo_b/src/main.lua".to_string(), 0.5);
        index.set_hotspot_scores(scores);

        let (sym_a, uri_a, hot_a) = index.stats_for_prefix("file:///repo_a/");
        assert_eq!(sym_a, 3); // funcA1, funcA2, utilA
        assert_eq!(uri_a, 2); // main.lua, util.lua
        assert_eq!(hot_a, 1); // main.lua

        let (sym_b, uri_b, hot_b) = index.stats_for_prefix("file:///repo_b/");
        assert_eq!(sym_b, 1);
        assert_eq!(uri_b, 1);
        assert_eq!(hot_b, 1);

        let (sym_c, uri_c, hot_c) = index.stats_for_prefix("file:///repo_c/");
        assert_eq!(sym_c, 0);
        assert_eq!(uri_c, 0);
        assert_eq!(hot_c, 0);
    }
}
