# code-shape.nvim

> **Structure-aware navigation** for large repositories.
>
> - 🔎 **Defs**: fast symbol definition search from a local Rust index
> - 🕸️ **Calls**: follow call/reference edges from the selected symbol
> - 🔥 **Hotspots + Debt**: prioritize risky areas via git churn × complexity

`code-shape.nvim` keeps a fast incremental index in a small Rust core and gives
you one workflow for exploration and refactoring prioritization.

## 💡 Why code-shape.nvim?

Built for codebases where the key question is **"what should we touch first?"**

**Best fit:**
- Large monorepos where LSP symbol search gets slow or unstable
- Legacy refactoring where hotspot × complexity guides starting points
- Environments that need fast startup/search via persisted snapshots

**Not fit** — for small projects (≤10k LOC) or plain text search, `live_grep` / `lsp_workspace_symbols` are sufficient.

## ✨ Features

- ⚡ Millisecond-level symbol search from an incremental Rust index
- 🧭 Unified picker with three modes: **Defs**, **Calls**, **Hotspots**
- 🕸️ Call graph exploration from the selected symbol (`gc`, `l`, `h`, `r`)
- 🔥 Hotspots ranked by git history (with optional churn/time-decay weighting)
- 📊 Code metrics: cyclomatic complexity, LOC, nesting depth (via Tree-sitter)
- 🎯 Tech debt scoring: hotspot × complexity for targeted refactoring
- 🗂️ Automatic indexing of opened buffers + workspace symbol indexing
- 💾 Snapshot persistence on startup/exit (`snapshot.*`)
- 🌳 Multi-root support for monorepos and git worktrees (per-root stats/hotspots)
- 🧩 External picker integrations for Telescope / fzf-lua / snacks.nvim

## 🧭 Workflow: Defs → Calls → Hotspots

1. **Defs** — find the symbol (`gc` to explore callers/callees)
2. **Calls** — follow the call graph (`l` forward, `h` back)
3. **Hotspots** — prioritize by git churn × complexity

Details and example scenario: `:help code-shape-workflow`

## 📦 Requirements

- Neovim `>= 0.10`
- A working LSP setup (for best results)
- Optional: `git` (for Hotspots)

## 🚀 Installation

### lazy.nvim

```lua
{
  "mhiro2/code-shape.nvim",
  config = function()
    require("code-shape").setup({})
  end,
}
```

### packer.nvim

```lua
use({
  "mhiro2/code-shape.nvim",
  config = function()
    require("code-shape").setup({})
  end,
})
```

## Quickstart

1. Open your project in Neovim
2. Run:

```vim
:CodeShapeIndex
```

3. Open the picker:

```vim
:CodeShape
```

Type to search for symbol definitions.

## 💻 Commands

| Command              | Description                       |
| -------------------- | --------------------------------- |
| `:CodeShape`         | Open the picker UI                |
| `:CodeShapeIndex`    | Build/refresh index (incremental) |
| `:CodeShapeReindex`  | Full rebuild                      |
| `:CodeShapeIndexCancel` | Cancel running workspace index |
| `:CodeShapeStatus`   | Show index stats                  |
| `:CodeShapeClear`    | Clear indexed symbols, hotspot scores, and tracked roots |
| `:CodeShapeHotspots` | Open Hotspots view (drill into symbol metrics) |
| `:CodeShapeCallsFromCursor` | Open Calls mode for symbol under cursor |
| `:CodeShapeDiffImpact [--base=<ref>] [--head=<ref>] [--staged]` | Open AI-era diff impact view (risk order) |
| `:CodeShapeTelescope [mode]` | Open with Telescope (defs/hotspots/impact) |
| `:CodeShapeFzf [mode]`       | Open with fzf-lua (defs/hotspots/impact)   |
| `:CodeShapeSnacks [mode]`    | Open with snacks.nvim (defs/hotspots/impact) |

## ⌨️ Default Keymaps (in picker)

> [!IMPORTANT]
> `config.keymaps` in this section applies only to the built-in picker UI (`picker = "builtin"` or `nil`).
> If you use an external backend (`telescope` / `fzf_lua` / `snacks`), configure keymaps in that picker plugin or map `:CodeShape*` commands directly.

All bindings below can be customized via `config.keymaps`.

### Normal Mode

| Key      | Action                    |
| -------- | ------------------------- |
| `<CR>`   | Jump to symbol            |
| `<C-s>`  | Split jump                |
| `<C-v>`  | Vsplit jump               |
| `j` / `k`| Next / Previous item      |
| `q` / `<Esc>` | Close                |
| `<Tab>`  | Next mode (Defs→Calls→Hotspots) |
| `<S-Tab>`| Previous mode             |
| `t`      | Cycle kind filter (All/Func/Class/Var/Type) |
| `gd`     | Go to definition (LSP)    |
| `gr`     | Show references (LSP)     |
| `gc`     | Build/follow call graph   |
| `l`      | Follow selected graph node |
| `h`      | Back to previous graph node |
| `r`      | Refresh current graph node |

### Insert Mode (in input window)

| Key      | Action                    |
| -------- | ------------------------- |
| `<CR>`   | Jump to symbol            |
| `<C-n>` / `<C-p>` | Next / Previous item |
| `<Tab>`  | Next mode                 |
| `<S-Tab>`| Previous mode             |
| `<C-t>`  | Cycle kind filter         |
| `<C-g>`  | Build/follow call graph   |

### Hotspots Drill-down (`:CodeShapeHotspots`)

| Key      | Action                    |
| -------- | ------------------------- |
| `<CR>`   | Drill into file → show symbol metrics |
| `<BS>`   | Back to file list         |
| `h`      | Back to file list         |
| `q`      | Close                     |
| `<Esc>`  | Close                     |

In the symbol metrics view, `<CR>` jumps to the symbol location.

### Mode Tabs

The picker supports three modes:

- **Defs**: Search for symbol definitions (functions, classes, methods, etc.)
- **Calls**: Explore call/reference edges in a lightweight graph panel (`gc`/`l` follow, `h` back, `r` refresh)
- **Hotspots**: Browse files by change frequency

Use `<Tab>` / `<S-Tab>` to cycle between modes.

#### Calls Mode Features

**Navigation History**: The breadcrumb shows your path through the call graph:
```
Path (3/5): authenticate > check_token > validate_session
```
The `(3/5)` indicates you're at position 3 of 5 in the history.

**Section Summary**: A quick overview of graph edges:
```
Callers: 5 | Callees: 3 | Refs: 12
```

**Context Preservation**: When switching between modes, your query and selected symbol are preserved:
- Defs → Calls: Selected symbol becomes the call graph center
- Calls → Defs: Query is restored
- Defs ↔ Hotspots: Query and selection position are maintained

**External Picker Users**: Call graph navigation requires interactive `l`/`h`/`r` keys, which are not supported in external pickers. Use `:CodeShapeCallsFromCursor` to open the builtin UI directly in Calls mode for the symbol under cursor.

### Kind Filters

Press `t` (normal mode) or `<C-t>` (insert mode) to cycle through kind filters:

- **All**: Show all symbols
- **Func**: Methods, Constructors, Functions
- **Class**: Classes, Interfaces, Structs
- **Var**: Properties, Fields, Variables, Constants
- **Type**: Enums, EnumMembers, TypeParameters

## 🧺 Picker Integration (telescope / fzf-lua / snacks.nvim)

Set `picker` in your config to use an external backend:

```lua
require("code-shape").setup({
  picker = "telescope",  -- "builtin" | "telescope" | "fzf_lua" | "snacks"
})
```

Per-backend setup, keymaps, and Lua API: `:help code-shape-picker`

## ⚙️ Configuration

Configure via `require("code-shape").setup({ ... })`.

<details><summary>Default Settings</summary>

```lua
{
  -- UI preferences
  ui = {
    width = 0.8,        -- width ratio (0-1) or absolute columns (integer >= 1)
    height = 0.8,       -- height ratio (0-1)
    border = "rounded", -- border style: "none", "single", "double", "rounded", "solid", "shadow"
    preview = true,     -- show preview window
  },

  -- Search settings
  search = {
    limit = 50,         -- max results
    debounce_ms = 100,  -- debounce time for input
  },

  -- Hotspots (git churn)
  hotspots = {
    enabled = true,
    since = "3 months ago", -- time range for git log
    max_files = 1000,       -- max files to analyze
    -- Optional hotspot scoring options
    half_life_days = 30,    -- days for commit weight to decay to 0.5
    use_churn = true,       -- use numstat for line change analysis
  },

  -- Code metrics (Tree-sitter based)
  metrics = {
    enabled = true,         -- compute metrics during indexing
    complexity_cap = 50,    -- cap for tech debt normalization
  },

  -- Picker keymaps
  keymaps = {
    select = "<CR>",
    open_vsplit = "<C-v>",
    open_split = "<C-s>",
    prev = "k",
    prev_alt = "<Up>",
    next = "j",
    next_alt = "<Down>",
    prev_insert = "<C-p>",
    next_insert = "<C-n>",
    mode_next = "<Tab>",
    mode_prev = "<S-Tab>",
    cycle_kind_filter = "t",
    goto_definition = "gd",
    show_references = "gr",
    show_calls = "gc",
    graph_follow = "l",
    graph_back = "h",
    graph_refresh = "r",
    close = "q",
    close_alt = "<Esc>",
  },

  -- Snapshot persistence
  snapshot = {
    enabled = true,
    load_on_start = true,
    save_on_exit = true,
    remote_cache = {
      enabled = false,               -- optional (for shared/remote filesystem cache)
      dir = "/mnt/code-shape-cache", -- base directory for remote cache
      load_on_start = true,          -- pull remote snapshot before local load
      save_on_exit = true,           -- push local snapshot after save
    },
  },

  -- Picker backend: "builtin" (default), "telescope", "fzf_lua", "snacks"
  -- picker = nil,

  -- Debug mode (shows $/progress and $/log notifications)
  debug = false,
}
```

</details>

## 🏗️ How it works

**Lua** handles UI/LSP, **Rust core** serves fast search via stdio JSON-RPC.
Indexes LSP `documentSymbol` / `workspace/symbol` into an incremental n-gram inverted index.

| Repo scale | code-shape p50 (ms) | lsp_workspace_symbols p50 (ms) | live_grep p50 (ms) |
|------------|---------------------|--------------------------------|---------------------|
| 100k LOC   | 0.606               | 0.400                          | 5                   |
| 500k LOC   | 0.745               | 2.081                          | 5                   |
| 1M LOC     | 1.371               | 4.223                          | 4                   |

Benchmark details: [`benchmark/README.md`](./benchmark/README.md) | `:help code-shape-benchmark`
Advanced features (snapshots, multi-root, code metrics, AI-era diffs): `:help code-shape-advanced`

## 📄 License

MIT License. See [LICENSE](./LICENSE).

## 🔁 Alternatives

- [stevearc/aerial.nvim](https://github.com/stevearc/aerial.nvim)
- [simrat39/symbols-outline.nvim](https://github.com/simrat39/symbols-outline.nvim)
- [nvimdev/lspsaga.nvim](https://github.com/nvimdev/lspsaga.nvim)
- [folke/trouble.nvim](https://github.com/folke/trouble.nvim)
