mod index;
mod rpc;
mod search;
mod store;

use anyhow::Result;
use index::{SymbolIndex, SymbolMetrics};
use rpc::{
    INTERNAL_ERROR, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND, Notification, Response,
    Transport,
};
use serde_json::{Value, json};
use std::{env, process};

const MAX_UPSERT_SYMBOLS_PARAMS_BYTES: usize = 8 * 1024 * 1024;

fn default_top_limit() -> usize {
    10
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

#[derive(serde::Deserialize)]
struct HotspotTopSymbolsParams {
    uri: String,
    #[serde(default = "default_top_limit")]
    limit: usize,
    complexity_cap: u32,
}

#[derive(serde::Deserialize)]
struct SymbolIdParams {
    symbol_id: String,
}

#[derive(serde::Deserialize)]
struct PathParams {
    path: String,
}

#[derive(serde::Deserialize)]
struct SaveSnapshotForRootParams {
    path: String,
    uri_prefix: String,
}

#[derive(serde::Deserialize)]
struct RootInfoParams {
    name: String,
    uri_prefix: String,
}

#[derive(serde::Deserialize)]
struct StatsByRootParams {
    roots: Vec<RootInfoParams>,
}

fn init_search_pool() {
    let _ = rayon::ThreadPoolBuilder::new()
        .thread_name(|idx| format!("code-shape-search-{}", idx))
        .build_global();
}

fn response_if_params_too_large(
    id: Option<Value>,
    method: &str,
    params_size: usize,
    max_bytes: usize,
) -> Option<Response> {
    if params_size <= max_bytes {
        return None;
    }

    Some(Response::error(
        id,
        INVALID_PARAMS,
        format!(
            "params too large for {}: {} bytes (max: {} bytes)",
            method, params_size, max_bytes
        ),
    ))
}

struct Server {
    transport: Transport,
    index: SymbolIndex,
    initialized: bool,
    shutdown_requested: bool,
}

impl Server {
    fn new() -> Self {
        Self {
            transport: Transport::new(),
            index: SymbolIndex::new(),
            initialized: false,
            shutdown_requested: false,
        }
    }

    /// Send a notification to the client
    fn send_notification(&self, method: &str, params: Value) {
        let notification = Notification::new(method, params);
        if let Err(e) = self.transport.send_notification(&notification) {
            eprintln!("code-shape-core: failed to send notification: {}", e);
        }
    }

    /// Send a progress notification (DESIGN.md 8)
    fn send_progress(&self, token: &str, value: Value) {
        self.send_notification(
            "$/progress",
            json!({
                "token": token,
                "value": value
            }),
        );
    }

    /// Send a log notification (DESIGN.md 8)
    fn send_log(&self, level: &str, message: &str) {
        self.send_notification(
            "$/log",
            json!({
                "level": level,
                "message": message
            }),
        );
    }

    fn run(&mut self) -> Result<()> {
        eprintln!("code-shape-core: server starting");

        loop {
            let request = match self.transport.read_message() {
                Ok(Some(req)) => req,
                Ok(None) => {
                    eprintln!("code-shape-core: EOF, shutting down");
                    break;
                }
                Err(e) => {
                    if e.to_string().contains("failed to read from stdin") {
                        break;
                    }
                    eprintln!("code-shape-core: read error: {}", e);
                    continue;
                }
            };

            if request.jsonrpc != "2.0" {
                if request.id.is_some() {
                    let response = Response::error(
                        request.id.clone(),
                        INVALID_REQUEST,
                        "invalid jsonrpc version".to_string(),
                    );
                    let _ = self.transport.send_response(&response);
                }
                continue;
            }

            // Notifications have no id
            if request.id.is_none() {
                continue;
            }

            let id = request.id.clone();
            let response = self.dispatch(
                &request.method,
                request.params,
                request.params_bytes,
                id.clone(),
            );
            if let Err(e) = self.transport.send_response(&response) {
                eprintln!("code-shape-core: send error: {}", e);
            }
            if self.shutdown_requested {
                eprintln!("code-shape-core: graceful shutdown complete");
                break;
            }
        }

        Ok(())
    }

    fn handle_initialize(&mut self, id: Option<Value>) -> Response {
        self.initialized = true;
        Response::success(
            id,
            json!({
                "name": "code-shape-core",
                "version": env!("CARGO_PKG_VERSION")
            }),
        )
    }

    fn handle_shutdown(&mut self, id: Option<Value>) -> Response {
        eprintln!("code-shape-core: shutdown requested");
        self.shutdown_requested = true;
        Response::success(id, json!(null))
    }

    fn handle_index_upsert_symbols(
        &mut self,
        params: Value,
        params_bytes: usize,
        id: Option<Value>,
    ) -> Response {
        if let Some(resp) = response_if_params_too_large(
            id.clone(),
            "index/upsertSymbols",
            params_bytes,
            MAX_UPSERT_SYMBOLS_PARAMS_BYTES,
        ) {
            return resp;
        }

        match serde_json::from_value::<index::UpsertSymbolsParams>(params) {
            Ok(p) => {
                let symbol_count = p.symbols.len();
                match self.index.upsert_symbols(&p.uri, p.symbols) {
                    Ok(()) => {
                        self.send_progress(
                            "indexing",
                            json!({
                                "kind": "report",
                                "message": format!("Indexed {} symbols in {}", symbol_count, p.uri),
                                "uri": p.uri
                            }),
                        );
                        Response::success(id, json!({ "success": true }))
                    }
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                }
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_index_remove_uri(&mut self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<index::RemoveUriParams>(params) {
            Ok(p) => {
                self.index.remove_uri(&p.uri);
                Response::success(id, json!({ "success": true }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_index_remove_uris(&mut self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<index::RemoveUrisParams>(params) {
            Ok(p) => {
                self.index.remove_uris(p.uris);
                Response::success(id, json!({ "success": true }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_index_stats(&self, id: Option<Value>) -> Response {
        let stats = index::IndexStats {
            symbol_count: self.index.symbol_count(),
            uri_count: self.index.uri_count(),
            hotspot_count: self.index.get_hotspot_scores().len(),
            edge_count: self.index.edge_count(),
        };
        Response::success(id, json!(stats))
    }

    fn handle_index_get_symbol_by_id(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<SymbolIdParams>(params) {
            Ok(p) => {
                let symbol = self.index.get_symbol(&p.symbol_id);
                Response::success(id, json!({ "symbol": symbol }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_search_query(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<search::SearchParams>(params) {
            Ok(p) => match search::search(&self.index, p) {
                Ok(result) => Response::success(id, json!(result)),
                Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
            },
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_hotspot_set_scores(&mut self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<index::SetHotspotScoresParams>(params) {
            Ok(p) => {
                self.index.set_hotspot_scores(p.scores);
                Response::success(id, json!({ "success": true }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_hotspot_get_top_symbols(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<HotspotTopSymbolsParams>(params) {
            Ok(p) => {
                let hotspot_score = self.index.get_hotspot_score(&p.uri);
                let complexity_cap = normalize_complexity_cap(p.complexity_cap);
                let symbols = self.index.get_top_symbols(&p.uri, p.limit);
                let symbols_with_debt: Vec<Value> = symbols
                    .iter()
                    .map(|s| {
                        let tech_debt =
                            calculate_tech_debt(hotspot_score, s.metrics.as_ref(), complexity_cap);
                        let mut val = serde_json::to_value(s).unwrap_or(json!(null));
                        if let Some(td) = tech_debt {
                            val["tech_debt"] = json!(td);
                        }
                        val
                    })
                    .collect();
                Response::success(id, json!({ "symbols": symbols_with_debt }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_graph_upsert_edges(&mut self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<index::UpsertEdgesParams>(params) {
            Ok(p) => {
                self.index.upsert_edges(p.edges);
                Response::success(id, json!({ "success": true }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_graph_get_outgoing_edges(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<SymbolIdParams>(params) {
            Ok(p) => {
                let edges = self.index.get_outgoing_edges(&p.symbol_id);
                Response::success(id, json!({ "edges": edges }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_graph_get_incoming_edges(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<SymbolIdParams>(params) {
            Ok(p) => {
                let edges = self.index.get_incoming_edges(&p.symbol_id);
                Response::success(id, json!({ "edges": edges }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_graph_clear_edges(&mut self, id: Option<Value>) -> Response {
        self.index.clear_edges();
        Response::success(id, json!({ "success": true }))
    }

    fn handle_index_save_snapshot(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<PathParams>(params) {
            Ok(p) => match store::save_snapshot(&self.index, std::path::Path::new(&p.path)) {
                Ok(()) => Response::success(id, json!({ "success": true })),
                Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
            },
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_index_load_snapshot(&mut self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<PathParams>(params) {
            Ok(p) => {
                self.send_progress(
                    "loading",
                    json!({
                        "kind": "begin",
                        "title": "Loading index snapshot"
                    }),
                );

                match store::load_snapshot(std::path::Path::new(&p.path)) {
                    Ok(loaded_index) => {
                        let symbol_count = loaded_index.symbol_count();
                        let uri_count = loaded_index.uri_count();
                        let edge_count = loaded_index.edge_count();
                        self.index = loaded_index;

                        self.send_progress(
                            "loading",
                            json!({
                                "kind": "end",
                                "message": format!("Loaded {} symbols from {} files", symbol_count, uri_count)
                            }),
                        );
                        self.send_log(
                            "info",
                            &format!(
                                "Snapshot loaded: {} symbols, {} URIs, {} edges",
                                symbol_count, uri_count, edge_count
                            ),
                        );

                        Response::success(
                            id,
                            json!({
                                "success": true,
                                "symbol_count": symbol_count,
                                "uri_count": uri_count,
                                "edge_count": edge_count
                            }),
                        )
                    }
                    Err(e) => {
                        self.send_log("error", &format!("Failed to load snapshot: {}", e));
                        Response::error(id, INTERNAL_ERROR, e.to_string())
                    }
                }
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_index_snapshot_exists(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<PathParams>(params) {
            Ok(p) => {
                let exists = store::snapshot_exists(std::path::Path::new(&p.path));
                Response::success(id, json!({ "exists": exists }))
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_index_save_snapshot_for_root(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<SaveSnapshotForRootParams>(params) {
            Ok(p) => match store::save_snapshot_for_root(
                &self.index,
                std::path::Path::new(&p.path),
                &p.uri_prefix,
            ) {
                Ok(()) => Response::success(id, json!({ "success": true })),
                Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
            },
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_index_load_snapshot_for_root(
        &mut self,
        params: Value,
        id: Option<Value>,
    ) -> Response {
        match serde_json::from_value::<PathParams>(params) {
            Ok(p) => {
                match store::load_snapshot_merge(&mut self.index, std::path::Path::new(&p.path)) {
                    Ok((symbol_count, uri_count)) => Response::success(
                        id,
                        json!({
                            "success": true,
                            "symbol_count": symbol_count,
                            "uri_count": uri_count,
                        }),
                    ),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                }
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn handle_index_stats_by_root(&self, params: Value, id: Option<Value>) -> Response {
        match serde_json::from_value::<StatsByRootParams>(params) {
            Ok(p) => {
                let mut root_stats = Vec::new();
                for root in &p.roots {
                    let (sym_count, uri_count, hotspot_count) =
                        self.index.stats_for_prefix(&root.uri_prefix);
                    root_stats.push(json!({
                        "name": root.name,
                        "symbol_count": sym_count,
                        "uri_count": uri_count,
                        "hotspot_count": hotspot_count,
                    }));
                }
                Response::success(
                    id,
                    json!({
                        "total": {
                            "symbol_count": self.index.symbol_count(),
                            "uri_count": self.index.uri_count(),
                            "hotspot_count": self.index.get_hotspot_scores().len(),
                            "edge_count": self.index.edge_count(),
                        },
                        "roots": root_stats,
                    }),
                )
            }
            Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
        }
    }

    fn dispatch(
        &mut self,
        method: &str,
        params: Value,
        params_bytes: usize,
        id: Option<Value>,
    ) -> Response {
        match method {
            "initialize" => self.handle_initialize(id),
            "shutdown" => self.handle_shutdown(id),
            "index/upsertSymbols" => self.handle_index_upsert_symbols(params, params_bytes, id),
            "index/removeUri" => self.handle_index_remove_uri(params, id),
            "index/removeUris" => self.handle_index_remove_uris(params, id),
            "index/stats" => self.handle_index_stats(id),
            "index/getSymbolById" => self.handle_index_get_symbol_by_id(params, id),
            "search/query" => self.handle_search_query(params, id),
            "hotspot/setScores" => self.handle_hotspot_set_scores(params, id),
            "hotspot/getTopSymbols" => self.handle_hotspot_get_top_symbols(params, id),
            "graph/upsertEdges" => self.handle_graph_upsert_edges(params, id),
            "graph/getOutgoingEdges" => self.handle_graph_get_outgoing_edges(params, id),
            "graph/getIncomingEdges" => self.handle_graph_get_incoming_edges(params, id),
            "graph/clearEdges" => self.handle_graph_clear_edges(id),
            "index/saveSnapshot" => self.handle_index_save_snapshot(params, id),
            "index/loadSnapshot" => self.handle_index_load_snapshot(params, id),
            "index/snapshotExists" => self.handle_index_snapshot_exists(params, id),
            "index/saveSnapshotForRoot" => self.handle_index_save_snapshot_for_root(params, id),
            "index/loadSnapshotForRoot" => self.handle_index_load_snapshot_for_root(params, id),
            "index/statsByRoot" => self.handle_index_stats_by_root(params, id),
            _ => Response::error(
                id,
                METHOD_NOT_FOUND,
                format!("method not found: {}", method),
            ),
        }
    }
}

fn main() {
    let mut args = env::args().skip(1);
    if let Some(arg) = args.next() {
        if arg == "--version" || arg == "-V" {
            println!("code-shape-core {}", env!("CARGO_PKG_VERSION"));
            return;
        }
    }

    init_search_pool();
    let mut server = Server::new();
    if let Err(e) = server.run() {
        eprintln!("code-shape-core: fatal error: {}", e);
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn test_symbol(name: String) -> Value {
        json!({
            "symbol_id": "",
            "name": name,
            "kind": 12,
            "uri": "file:///test.lua",
            "range": {
                "start": { "line": 0, "character": 0 },
                "end": { "line": 0, "character": 10 }
            }
        })
    }

    #[test]
    fn upsert_symbols_accepts_payload_within_limit() {
        let mut server = Server::new();
        let params = json!({
            "uri": "file:///test.lua",
            "symbols": [test_symbol("func_a".to_string())]
        });

        let params_bytes = serde_json::to_vec(&params)
            .expect("params should serialize")
            .len();
        let response = server.dispatch("index/upsertSymbols", params, params_bytes, Some(json!(1)));

        assert!(response.error.is_none());
        assert_eq!(server.index.symbol_count(), 1);
    }

    #[test]
    fn upsert_symbols_rejects_oversized_payload() {
        let mut server = Server::new();
        let oversized_name = "a".repeat(MAX_UPSERT_SYMBOLS_PARAMS_BYTES + 1024);
        let params = json!({
            "uri": "file:///test.lua",
            "symbols": [test_symbol(oversized_name)]
        });

        let params_bytes = serde_json::to_vec(&params)
            .expect("params should serialize")
            .len();
        let response = server.dispatch("index/upsertSymbols", params, params_bytes, Some(json!(1)));

        assert!(response.result.is_none());
        assert!(response.error.is_some());
        let error = response.error.expect("error must exist");
        assert_eq!(error.code, INVALID_PARAMS);
        assert!(
            error
                .message
                .contains("params too large for index/upsertSymbols")
        );
        assert_eq!(server.index.symbol_count(), 0);
    }

    #[test]
    fn index_get_symbol_by_id_returns_symbol() {
        let mut server = Server::new();
        let upsert_params = json!({
            "uri": "file:///test.lua",
            "symbols": [test_symbol("func_a".to_string())]
        });

        let upsert_bytes = serde_json::to_vec(&upsert_params)
            .expect("params should serialize")
            .len();
        let upsert_response = server.dispatch(
            "index/upsertSymbols",
            upsert_params,
            upsert_bytes,
            Some(json!(1)),
        );
        assert!(upsert_response.error.is_none());

        let symbol_id = server
            .index
            .all_symbols()
            .first()
            .expect("symbol should exist after upsert")
            .symbol_id
            .clone();

        let response = server.dispatch(
            "index/getSymbolById",
            json!({ "symbol_id": symbol_id }),
            0,
            Some(json!(2)),
        );
        assert!(response.error.is_none());

        let result = response.result.expect("result should exist");
        assert_eq!(result["symbol"]["name"], json!("func_a"));
        assert_ne!(result["symbol"]["symbol_id"], json!(""));
    }

    #[test]
    fn index_get_symbol_by_id_returns_null_when_missing() {
        let mut server = Server::new();

        let response = server.dispatch(
            "index/getSymbolById",
            json!({ "symbol_id": "missing-id" }),
            0,
            Some(json!(1)),
        );
        assert!(response.error.is_none());
        let result = response.result.expect("result should exist");
        assert_eq!(result["symbol"], Value::Null);
    }
}
