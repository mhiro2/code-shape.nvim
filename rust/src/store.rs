//! Index persistence using rkyv for fast zero-copy serialization
//!
//! Provides snapshot save/load functionality for the symbol index,
//! enabling fast startup after initial indexing.

use crate::index::{Edge, Symbol, SymbolIndex};
use anyhow::{Context, Result};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Version for snapshot format compatibility
const SNAPSHOT_VERSION: u32 = 1;

/// Snapshot data structure for serialization
#[derive(Debug, rkyv::Archive, rkyv::Serialize, rkyv::Deserialize)]
struct Snapshot {
    version: u32,
    symbols: Vec<Symbol>,
    by_uri: HashMap<String, Vec<String>>,
    hotspot_scores: HashMap<String, f64>,
    edges: Vec<Edge>,
}

fn build_temp_snapshot_path(path: &Path) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let tmp_name = format!(
        "{}.tmp.{}.{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("index.bin"),
        std::process::id(),
        nonce
    );
    path.with_file_name(tmp_name)
}

fn serialize_snapshot_atomically(snapshot: &Snapshot, path: &Path) -> Result<()> {
    let tmp_path = build_temp_snapshot_path(path);
    {
        let bytes = rkyv::to_bytes::<rkyv::rancor::Error>(snapshot)
            .map_err(|e| anyhow::anyhow!("{}", e))
            .with_context(|| "failed to serialize snapshot")?;
        let file = File::create(&tmp_path)
            .with_context(|| format!("failed to create temp snapshot file: {:?}", tmp_path))?;
        let mut writer = BufWriter::new(file);
        writer
            .write_all(&bytes)
            .with_context(|| "failed to write snapshot")?;
        writer
            .flush()
            .with_context(|| "failed to flush temp snapshot file")?;
        writer
            .get_ref()
            .sync_all()
            .with_context(|| "failed to fsync temp snapshot file")?;
    }

    if let Err(rename_err) = std::fs::rename(&tmp_path, path) {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(rename_err).with_context(|| {
            format!(
                "failed to atomically replace snapshot from {:?} to {:?}",
                tmp_path, path
            )
        });
    }

    Ok(())
}

/// Save index to a file
pub fn save_snapshot(index: &SymbolIndex, path: &Path) -> Result<()> {
    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create directory: {:?}", parent))?;
    }

    // Collect all symbols
    let symbols: Vec<Symbol> = index.all_symbols().into_iter().cloned().collect();

    // Create snapshot
    let snapshot = Snapshot {
        version: SNAPSHOT_VERSION,
        symbols,
        by_uri: index.get_by_uri().clone(),
        hotspot_scores: index.get_hotspot_scores().clone(),
        edges: index.all_edges().to_vec(),
    };

    serialize_snapshot_atomically(&snapshot, path)
}

fn deserialize_snapshot(path: &Path) -> Result<Snapshot> {
    let bytes =
        std::fs::read(path).with_context(|| format!("failed to read snapshot file: {:?}", path))?;
    rkyv::from_bytes::<Snapshot, rkyv::rancor::Error>(&bytes)
        .map_err(|e| anyhow::anyhow!("{}", e))
        .with_context(|| "failed to deserialize snapshot")
}

/// Load index from a file
pub fn load_snapshot(path: &Path) -> Result<SymbolIndex> {
    let snapshot = deserialize_snapshot(path)?;

    // Check version compatibility
    if snapshot.version != SNAPSHOT_VERSION {
        anyhow::bail!(
            "incompatible snapshot version: {} (expected {})",
            snapshot.version,
            SNAPSHOT_VERSION
        );
    }

    // Rebuild index
    let mut index = SymbolIndex::new();
    let symbols_by_id: HashMap<&str, &Symbol> = snapshot
        .symbols
        .iter()
        .map(|symbol| (symbol.symbol_id.as_str(), symbol))
        .collect();

    // Restore symbols grouped by URI
    for (uri, symbol_ids) in snapshot.by_uri {
        let mut seen: HashSet<String> = HashSet::new();
        let mut symbols_for_uri = Vec::with_capacity(symbol_ids.len());

        for symbol_id in symbol_ids {
            if !seen.insert(symbol_id.clone()) {
                continue;
            }
            if let Some(symbol) = symbols_by_id.get(symbol_id.as_str()) {
                symbols_for_uri.push((*symbol).clone());
            }
        }

        if !symbols_for_uri.is_empty() {
            index
                .upsert_symbols(&uri, symbols_for_uri)
                .with_context(|| format!("failed to restore symbols for uri: {}", uri))?;
        }
    }

    // Restore hotspot scores
    index.set_hotspot_scores(snapshot.hotspot_scores);

    // Restore edges
    if !snapshot.edges.is_empty() {
        index.upsert_edges(snapshot.edges);
    }

    Ok(index)
}

/// Save a subset of the index (symbols matching uri_prefix) to a file
pub fn save_snapshot_for_root(index: &SymbolIndex, path: &Path, uri_prefix: &str) -> Result<()> {
    // Ensure parent directory exists
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create directory: {:?}", parent))?;
    }

    // Filter by_uri to only include URIs starting with uri_prefix
    let filtered_by_uri: HashMap<String, Vec<String>> = index
        .get_by_uri()
        .iter()
        .filter(|(uri, _)| uri.starts_with(uri_prefix))
        .map(|(uri, symbol_ids)| (uri.clone(), symbol_ids.clone()))
        .collect();

    // Collect symbol IDs for filtered URIs
    let symbol_id_set: HashSet<&String> = filtered_by_uri.values().flatten().collect();

    // Collect symbols for filtered URIs
    let symbols: Vec<Symbol> = index
        .all_symbols()
        .into_iter()
        .filter(|s| symbol_id_set.contains(&s.symbol_id))
        .cloned()
        .collect();

    // Filter hotspot scores
    let filtered_hotspots: HashMap<String, f64> = index
        .get_hotspot_scores()
        .iter()
        .filter(|(uri, _)| uri.starts_with(uri_prefix))
        .map(|(k, v)| (k.clone(), *v))
        .collect();

    // Filter edges where caller or callee is in our symbol set
    let filtered_edges: Vec<Edge> = index
        .all_edges()
        .iter()
        .filter(|e| {
            symbol_id_set.contains(&e.caller_symbol_id)
                || symbol_id_set.contains(&e.callee_symbol_id)
        })
        .cloned()
        .collect();

    let snapshot = Snapshot {
        version: SNAPSHOT_VERSION,
        symbols,
        by_uri: filtered_by_uri,
        hotspot_scores: filtered_hotspots,
        edges: filtered_edges,
    };

    serialize_snapshot_atomically(&snapshot, path)
}

/// Load a snapshot and merge into an existing index (additive, does not replace)
pub fn load_snapshot_merge(index: &mut SymbolIndex, path: &Path) -> Result<(usize, usize)> {
    let snapshot = deserialize_snapshot(path)?;

    if snapshot.version != SNAPSHOT_VERSION {
        anyhow::bail!(
            "incompatible snapshot version: {} (expected {})",
            snapshot.version,
            SNAPSHOT_VERSION
        );
    }

    let symbol_count = snapshot.symbols.len();
    let uri_count = snapshot.by_uri.len();

    let symbols_by_id: HashMap<&str, &Symbol> = snapshot
        .symbols
        .iter()
        .map(|s| (s.symbol_id.as_str(), s))
        .collect();

    // Merge symbols grouped by URI
    for (uri, symbol_ids) in &snapshot.by_uri {
        let mut seen: HashSet<String> = HashSet::new();
        let mut symbols_for_uri = Vec::with_capacity(symbol_ids.len());

        for sid in symbol_ids {
            if !seen.insert(sid.clone()) {
                continue;
            }
            if let Some(symbol) = symbols_by_id.get(sid.as_str()) {
                symbols_for_uri.push((*symbol).clone());
            }
        }

        if !symbols_for_uri.is_empty() {
            index
                .upsert_symbols(uri, symbols_for_uri)
                .with_context(|| format!("failed to merge symbols for uri: {}", uri))?;
        }
    }

    // Merge hotspot scores
    let mut current_scores = index.get_hotspot_scores().clone();
    for (uri, score) in snapshot.hotspot_scores {
        current_scores.insert(uri, score);
    }
    index.set_hotspot_scores(current_scores);

    // Merge edges
    if !snapshot.edges.is_empty() {
        index.upsert_edges(snapshot.edges);
    }

    Ok((symbol_count, uri_count))
}

/// Check if a snapshot file exists
pub fn snapshot_exists(path: &Path) -> bool {
    path.exists()
}

/// Get default snapshot path for a project
#[allow(dead_code)]
pub fn get_default_snapshot_path(project_root: &Path) -> std::path::PathBuf {
    // Use .cache/code-shape/ directory in the project root
    project_root
        .join(".cache")
        .join("code-shape")
        .join("index.bin")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::{EdgeKind, Evidence, Position, Range};
    use tempfile::tempdir;

    fn create_test_symbol(name: &str, uri: &str) -> Symbol {
        Symbol {
            symbol_id: format!("{}_{}", name, uri),
            name: name.to_string(),
            kind: 12, // Function
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

    fn create_test_edge(caller: &str, callee: &str, uri: &str) -> Edge {
        Edge {
            caller_symbol_id: caller.to_string(),
            callee_symbol_id: callee.to_string(),
            edge_kind: EdgeKind::Call,
            evidence: Evidence {
                uri: uri.to_string(),
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
    fn test_save_and_load_snapshot() {
        let dir = tempdir().unwrap();
        let snapshot_path = dir.path().join("test.bin");

        // Create and populate index
        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file:///test.lua",
                vec![create_test_symbol("myFunc", "file:///test.lua")],
            )
            .expect("upsert symbols should succeed");
        index.upsert_edges(vec![create_test_edge(
            "caller_id",
            "myFunc_file:///test.lua",
            "file:///test.lua",
        )]);
        let mut scores = HashMap::new();
        scores.insert("file:///test.lua".to_string(), 0.8);
        index.set_hotspot_scores(scores);

        // Save snapshot
        save_snapshot(&index, &snapshot_path).unwrap();
        assert!(snapshot_path.exists());

        // Load snapshot
        let loaded = load_snapshot(&snapshot_path).unwrap();

        assert_eq!(loaded.symbol_count(), 1);
        assert_eq!(loaded.uri_count(), 1);
        assert_eq!(loaded.edge_count(), 1);
        assert_eq!(loaded.get_hotspot_score("file:///test.lua"), 0.8);
    }

    #[test]
    fn test_snapshot_exists() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.bin");
        assert!(!snapshot_exists(&path));

        std::fs::write(&path, b"test").unwrap();
        assert!(snapshot_exists(&path));
    }

    #[test]
    fn test_get_default_snapshot_path() {
        let root = Path::new("/project");
        let path = get_default_snapshot_path(root);
        assert_eq!(path, Path::new("/project/.cache/code-shape/index.bin"));
    }

    #[test]
    fn test_load_nonexistent_file() {
        let result = load_snapshot(Path::new("/nonexistent/path.bin"));
        assert!(result.is_err());
    }

    #[test]
    fn test_save_creates_parent_directory() {
        let dir = tempdir().unwrap();
        let snapshot_path = dir.path().join("nested").join("dir").join("test.bin");

        let index = SymbolIndex::new();
        save_snapshot(&index, &snapshot_path).unwrap();

        assert!(snapshot_path.exists());
    }

    #[test]
    fn test_save_snapshot_for_root_filters_by_prefix() {
        let dir = tempdir().unwrap();
        let snapshot_path = dir.path().join("root_a.bin");

        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file:///repo_a/src/main.lua",
                vec![create_test_symbol("funcA", "file:///repo_a/src/main.lua")],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file:///repo_b/src/main.lua",
                vec![create_test_symbol("funcB", "file:///repo_b/src/main.lua")],
            )
            .expect("upsert symbols should succeed");

        let mut scores = HashMap::new();
        scores.insert("file:///repo_a/src/main.lua".to_string(), 0.9);
        scores.insert("file:///repo_b/src/main.lua".to_string(), 0.5);
        index.set_hotspot_scores(scores);

        // Save only repo_a
        save_snapshot_for_root(&index, &snapshot_path, "file:///repo_a/").unwrap();

        // Load into a fresh index
        let loaded = load_snapshot(&snapshot_path).unwrap();
        assert_eq!(loaded.symbol_count(), 1);
        assert_eq!(loaded.uri_count(), 1);
        assert_eq!(loaded.get_hotspot_score("file:///repo_a/src/main.lua"), 0.9);
        assert_eq!(loaded.get_hotspot_score("file:///repo_b/src/main.lua"), 0.0);
    }

    #[test]
    fn test_save_snapshot_for_root_uses_temp_and_replaces_existing_file() {
        let dir = tempdir().unwrap();
        let snapshot_path = dir.path().join("root_a.bin");
        std::fs::write(&snapshot_path, b"stale").unwrap();

        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file:///repo_a/src/main.lua",
                vec![create_test_symbol("funcA", "file:///repo_a/src/main.lua")],
            )
            .expect("upsert symbols should succeed");
        index
            .upsert_symbols(
                "file:///repo_b/src/main.lua",
                vec![create_test_symbol("funcB", "file:///repo_b/src/main.lua")],
            )
            .expect("upsert symbols should succeed");

        save_snapshot_for_root(&index, &snapshot_path, "file:///repo_a/").unwrap();

        let loaded = load_snapshot(&snapshot_path).unwrap();
        assert_eq!(loaded.symbol_count(), 1);
        assert_eq!(loaded.uri_count(), 1);
        assert_eq!(loaded.get_hotspot_score("file:///repo_b/src/main.lua"), 0.0);

        let leftovers: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with("root_a.bin.tmp."))
            .collect();
        assert!(leftovers.is_empty());
    }

    #[test]
    fn test_load_snapshot_merge() {
        let dir = tempdir().unwrap();

        // Create first snapshot (repo_a)
        let mut index_a = SymbolIndex::new();
        index_a
            .upsert_symbols(
                "file:///repo_a/main.lua",
                vec![create_test_symbol("funcA", "file:///repo_a/main.lua")],
            )
            .expect("upsert symbols should succeed");
        let path_a = dir.path().join("a.bin");
        save_snapshot(&index_a, &path_a).unwrap();

        // Create second snapshot (repo_b)
        let mut index_b = SymbolIndex::new();
        index_b
            .upsert_symbols(
                "file:///repo_b/main.lua",
                vec![create_test_symbol("funcB", "file:///repo_b/main.lua")],
            )
            .expect("upsert symbols should succeed");
        let path_b = dir.path().join("b.bin");
        save_snapshot(&index_b, &path_b).unwrap();

        // Merge both into a fresh index
        let mut merged = SymbolIndex::new();
        let (sc_a, uc_a) = load_snapshot_merge(&mut merged, &path_a).unwrap();
        assert_eq!(sc_a, 1);
        assert_eq!(uc_a, 1);

        let (sc_b, uc_b) = load_snapshot_merge(&mut merged, &path_b).unwrap();
        assert_eq!(sc_b, 1);
        assert_eq!(uc_b, 1);

        // Merged index should have both
        assert_eq!(merged.symbol_count(), 2);
        assert_eq!(merged.uri_count(), 2);
    }

    #[test]
    fn test_save_snapshot_uses_temp_and_replaces_existing_file() {
        let dir = tempdir().unwrap();
        let snapshot_path = dir.path().join("test.bin");
        std::fs::write(&snapshot_path, b"stale").unwrap();

        let mut index = SymbolIndex::new();
        index
            .upsert_symbols(
                "file:///test.lua",
                vec![create_test_symbol("myFunc", "file:///test.lua")],
            )
            .expect("upsert symbols should succeed");
        save_snapshot(&index, &snapshot_path).unwrap();

        let loaded = load_snapshot(&snapshot_path).unwrap();
        assert_eq!(loaded.symbol_count(), 1);

        let leftovers: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with("test.bin.tmp."))
            .collect();
        assert!(leftovers.is_empty());
    }
}
