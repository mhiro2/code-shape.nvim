---@class CodeShapeMetrics
---@field cyclomatic_complexity integer
---@field lines_of_code integer
---@field nesting_depth integer

---@class CodeShapeSymbol
---@field symbol_id string
---@field name string
---@field kind integer LSP SymbolKind
---@field container_name string|nil
---@field uri string
---@field range CodeShapeRange
---@field detail string|nil
---@field metrics CodeShapeMetrics|nil

---@class CodeShapeRange
---@field start CodeShapePosition
---@field end CodeShapePosition

---@class CodeShapePosition
---@field line integer
---@field character integer

---@class CodeShapeSearchResultItem
---@field symbol_id string
---@field name string
---@field kind integer
---@field container_name string|nil
---@field uri string
---@field range CodeShapeRange
---@field detail string|nil
---@field score number
---@field metrics CodeShapeMetrics|nil
---@field tech_debt number|nil
---@field graph_section? "center"|"incoming"|"outgoing"|"reference"
---@field graph_edge_kind? "call"|"reference"|"import"
---@field graph_edge_count? integer
---@field graph_expandable? boolean

---@class CodeShapeCallsGraph
---@field center CodeShapeSearchResultItem
---@field incoming CodeShapeSearchResultItem[]
---@field outgoing CodeShapeSearchResultItem[]
---@field references CodeShapeSearchResultItem[]

---@class CodeShapeSearchResult
---@field symbols CodeShapeSearchResultItem[]

---@class CodeShapeIndexStats
---@field symbol_count integer
---@field uri_count integer
---@field hotspot_count integer

---@class CodeShapeUiConfig
---@field width number ratio (0 < width <= 1) or absolute columns (integer >= 1)
---@field height number
---@field border string
---@field preview boolean

---@class CodeShapeSearchConfig
---@field limit integer
---@field debounce_ms integer

---@class CodeShapeHotspotsConfig
---@field enabled boolean
---@field since string
---@field max_files integer
---@field half_life_days? integer
---@field use_churn? boolean

---@class CodeShapeKeymapsConfig
---@field select string
---@field open_vsplit string
---@field open_split string
---@field prev string
---@field prev_alt string
---@field next string
---@field next_alt string
---@field prev_insert string
---@field next_insert string
---@field mode_next string
---@field mode_prev string
---@field cycle_kind_filter string
---@field goto_definition string
---@field show_references string
---@field show_calls string
---@field graph_follow string
---@field graph_back string
---@field graph_refresh string
---@field close string
---@field close_alt string

---@class CodeShapeSnapshotConfig
---@field enabled boolean
---@field load_on_start boolean
---@field save_on_exit boolean
---@field remote_cache CodeShapeSnapshotRemoteCacheConfig

---@class CodeShapeSnapshotRemoteCacheConfig
---@field enabled boolean
---@field dir string|nil
---@field load_on_start boolean
---@field save_on_exit boolean

---@class CodeShapeMetricsConfig
---@field enabled boolean
---@field complexity_cap integer

---@class CodeShapeConfig
---@field ui CodeShapeUiConfig
---@field search CodeShapeSearchConfig
---@field hotspots CodeShapeHotspotsConfig
---@field metrics CodeShapeMetricsConfig
---@field keymaps CodeShapeKeymapsConfig
---@field snapshot CodeShapeSnapshotConfig
---@field picker? "builtin"|"telescope"|"fzf_lua"|"snacks"
---@field debug? boolean

-- AI-era Diffs types

---@alias CodeShapeChangeType
---| "added"
---| "modified"
---| "deleted"
---| "renamed"

---@class CodeShapeChangedSymbol
---@field symbol_id string
---@field name string
---@field kind integer LSP SymbolKind
---@field container_name string?
---@field uri string
---@field range CodeShapeRange
---@field change_type CodeShapeChangeType
---@field changed_lines integer[] 0-indexed
---@field detail string?

---@class CodeShapeChangedFile
---@field uri string
---@field path string
---@field repo_path string path relative to git root
---@field change_type CodeShapeChangeType
---@field old_path string? renamed only
---@field old_repo_path string? renamed only

---@class CodeShapeDiffStats
---@field files_added integer
---@field files_modified integer
---@field files_deleted integer
---@field files_renamed integer
---@field symbols_added integer
---@field symbols_modified integer
---@field symbols_deleted integer

---@class CodeShapeDiffAnalysis
---@field base string
---@field head string
---@field files CodeShapeChangedFile[]
---@field symbols CodeShapeChangedSymbol[]
---@field stats CodeShapeDiffStats

---@class CodeShapeDiffOptions
---@field base string?
---@field head string?
---@field staged boolean?
---@field git_root string?

-- Impact Analysis types

---@class CodeShapeImpactScore
---@field symbol_id string
---@field name string
---@field kind integer LSP SymbolKind
---@field uri string
---@field range CodeShapeRange
---@field change_type CodeShapeChangeType "changed" for directly modified, "affected" for call graph impact
---@field hotspot_score number 0-1 normalized hotspot score
---@field tech_debt number|nil technical debt score based on complexity
---@field caller_count integer number of symbols that call this symbol
---@field callee_count integer number of symbols this symbol calls
---@field impact_score number combined impact score for risk ranking

---@class CodeShapeImpactAnalysis
---@field base string
---@field head string
---@field changed_symbols CodeShapeImpactScore[] directly changed symbols
---@field affected_symbols CodeShapeImpactScore[] symbols affected via call graph
---@field risk_ranking CodeShapeImpactScore[] all symbols sorted by impact score
