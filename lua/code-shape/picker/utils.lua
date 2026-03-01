---@class CodeShapePickerUtils
local M = {}

local util
local is_list = vim.islist

-- Highlight groups for picker display
local HIGHLIGHT_GROUPS = {
  kind = "CodeShapeKind",
  name = "CodeShapeSymbolName",
  container = "CodeShapeContainer",
  path = "CodeShapePath",
  lnum = "CodeShapeLineNr",
  score = "CodeShapeScore",
  bar = "CodeShapeScoreBar",
  change_type = "CodeShapeChangeType",
}

-- Set up default highlight groups
local function setup_highlights()
  vim.api.nvim_set_hl(0, HIGHLIGHT_GROUPS.kind, { default = true, link = "Type" })
  vim.api.nvim_set_hl(0, HIGHLIGHT_GROUPS.name, { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, HIGHLIGHT_GROUPS.container, { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, HIGHLIGHT_GROUPS.path, { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, HIGHLIGHT_GROUPS.lnum, { default = true, link = "LineNr" })
  vim.api.nvim_set_hl(0, HIGHLIGHT_GROUPS.score, { default = true, link = "Number" })
  vim.api.nvim_set_hl(0, HIGHLIGHT_GROUPS.bar, { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, HIGHLIGHT_GROUPS.change_type, { default = true, link = "Label" })
end

-- ANSI color codes for fzf-lua
local ANSI_CODES = {
  reset = "\27[0m",
  bold = "\27[1m",
  dim = "\27[2m",
  -- Foreground colors (256-color)
  blue = "\27[38;5;75m",
  green = "\27[38;5;114m",
  yellow = "\27[38;5;180m",
  cyan = "\27[38;5;80m",
  magenta = "\27[38;5;176m",
  white = "\27[38;5;252m",
  gray = "\27[38;5;246m",
  red = "\27[38;5;167m",
}

-- Initialize highlights on module load
setup_highlights()

---@return CodeShapeUtil
local function get_util()
  util = util or require("code-shape.util")
  return util
end

---Extract filepath and 1-based line number from a search result item
---@param item CodeShapeSearchResultItem
---@return string filepath, integer lnum
function M.item_location(item)
  local u = get_util()
  local uri = type(item.uri) == "string" and item.uri or ""
  local path = u.file_uri_to_fname(uri) or uri
  local lnum = (item.range and item.range.start and item.range.start.line or 0) + 1
  return path, lnum
end

---Format a search result item for display in a picker
---@param item CodeShapeSearchResultItem
---@return string display
function M.format_entry(item)
  local u = get_util()
  local kind = u.symbol_kind_name(item.kind)
  local path, lnum = M.item_location(item)
  local short_path = u.shorten_path(path) or path

  local container = ""
  if type(item.container_name) == "string" and item.container_name ~= "" and item.container_name ~= short_path then
    container = " [" .. item.container_name .. "]"
  end

  return string.format("%s: %s%s - %s:%d", kind, item.name, container, short_path, lnum)
end

---Format a search result item with highlights for snacks.nvim
---Returns array of { text, highlight_group } pairs
---@param item CodeShapeSearchResultItem
---@return { [1]: string, [2]: string }[] display
function M.format_entry_highlight(item)
  local u = get_util()
  local kind = u.symbol_kind_name(item.kind)
  local path, lnum = M.item_location(item)
  local short_path = u.shorten_path(path) or path

  ---@type { [1]: string, [2]: string }[]
  local ret = {}

  -- Kind with highlight
  table.insert(ret, { kind .. ":", HIGHLIGHT_GROUPS.kind })
  table.insert(ret, { " ", "Normal" })

  -- Symbol name with highlight
  table.insert(ret, { item.name or "", HIGHLIGHT_GROUPS.name })

  -- Container name if present
  if type(item.container_name) == "string" and item.container_name ~= "" and item.container_name ~= short_path then
    table.insert(ret, { " [" .. item.container_name .. "]", HIGHLIGHT_GROUPS.container })
  end

  table.insert(ret, { " - ", "Normal" })

  -- Path with highlight
  table.insert(ret, { short_path, HIGHLIGHT_GROUPS.path })
  table.insert(ret, { ":", HIGHLIGHT_GROUPS.path })

  -- Line number with highlight
  table.insert(ret, { tostring(lnum), HIGHLIGHT_GROUPS.lnum })

  return ret
end

---Format entry for telescope with highlights
---Returns display string and highlight array for telescope entry_maker
---Highlight format: { { start_col, end_col }, hl_group }[]
---@param item CodeShapeSearchResultItem
---@return string display_string, { [1]: integer[], [2]: string }[] highlights
function M.format_entry_telescope(item)
  local u = get_util()
  local kind = u.symbol_kind_name(item.kind)
  local path, lnum = M.item_location(item)
  local short_path = u.shorten_path(path) or path

  local parts = {}
  ---@type { [1]: integer[], [2]: string }[] -- { { start_col, end_col }, hl_group }
  local highlights = {}
  local col = 0

  -- Kind
  local kind_text = kind .. ": "
  table.insert(parts, kind_text)
  table.insert(highlights, { { col, col + #kind_text }, HIGHLIGHT_GROUPS.kind })
  col = col + #kind_text

  -- Symbol name
  local name_text = item.name or ""
  table.insert(parts, name_text)
  table.insert(highlights, { { col, col + #name_text }, HIGHLIGHT_GROUPS.name })
  col = col + #name_text

  -- Container
  if type(item.container_name) == "string" and item.container_name ~= "" and item.container_name ~= short_path then
    local container_text = " [" .. item.container_name .. "]"
    table.insert(parts, container_text)
    table.insert(highlights, { { col, col + #container_text }, HIGHLIGHT_GROUPS.container })
    col = col + #container_text
  end

  -- Separator
  local sep_text = " - "
  table.insert(parts, sep_text)
  col = col + #sep_text

  -- Path
  table.insert(parts, short_path)
  table.insert(highlights, { { col, col + #short_path }, HIGHLIGHT_GROUPS.path })
  col = col + #short_path

  -- Colon and line number
  local lnum_text = ":" .. lnum
  table.insert(parts, lnum_text)
  table.insert(highlights, { { col, col + #lnum_text }, HIGHLIGHT_GROUPS.lnum })

  return table.concat(parts), highlights
end

---Format entry for fzf-lua with ANSI colors
---@param item CodeShapeSearchResultItem
---@return string display_string
function M.format_entry_fzf(item)
  local u = get_util()
  local kind = u.symbol_kind_name(item.kind)
  local path, lnum = M.item_location(item)
  local short_path = u.shorten_path(path) or path

  local parts = {}

  -- Kind with color
  local kind_text = kind .. ": "
  table.insert(parts, ANSI_CODES.cyan .. kind_text .. ANSI_CODES.reset)

  -- Symbol name with color
  local name_text = item.name or ""
  table.insert(parts, ANSI_CODES.green .. name_text .. ANSI_CODES.reset)

  -- Container with color
  if type(item.container_name) == "string" and item.container_name ~= "" and item.container_name ~= short_path then
    local container_text = " [" .. item.container_name .. "]"
    table.insert(parts, ANSI_CODES.yellow .. container_text .. ANSI_CODES.reset)
  end

  -- Separator (no color)
  table.insert(parts, " - ")

  -- Path with color
  table.insert(parts, ANSI_CODES.gray .. short_path .. ANSI_CODES.reset)

  -- Line number with color
  table.insert(parts, ANSI_CODES.white .. ":" .. lnum .. ANSI_CODES.reset)

  return table.concat(parts)
end

---Format a hotspot item for display in a picker
---@param item { path: string, score: number }
---@return string display
function M.format_hotspot(item)
  local u = get_util()
  local uri = type(item.path) == "string" and item.path or ""
  local path = u.file_uri_to_fname(uri) or uri
  local short_path = u.shorten_path(path) or path
  local score_bar = string.rep("█", math.floor(item.score * 10))
  return string.format("%-60s %s (%.2f)", short_path, score_bar, item.score)
end

---Format a hotspot item for fzf-lua with ANSI colors
---@param item { path: string, score: number }
---@return string display
function M.format_hotspot_fzf(item)
  local u = get_util()
  local uri = type(item.path) == "string" and item.path or ""
  local path = u.file_uri_to_fname(uri) or uri
  local short_path = u.shorten_path(path) or path
  local score_bar = string.rep("█", math.floor(item.score * 10))

  return string.format(
    ANSI_CODES.gray
      .. "%-60s "
      .. ANSI_CODES.reset
      .. ANSI_CODES.red
      .. "%s"
      .. ANSI_CODES.reset
      .. " "
      .. ANSI_CODES.magenta
      .. "(%.2f)"
      .. ANSI_CODES.reset,
    short_path,
    score_bar,
    item.score
  )
end

---Format a hotspot item with highlights for snacks.nvim
---@param item { path: string, score: number }
---@return { [1]: string, [2]: string }[] display
function M.format_hotspot_highlight(item)
  local u = get_util()
  local uri = type(item.path) == "string" and item.path or ""
  local path = u.file_uri_to_fname(uri) or uri
  local short_path = u.shorten_path(path) or path
  local score_bar = string.rep("█", math.floor(item.score * 10))
  local score_text = string.format("(%.2f)", item.score)

  ---@type { [1]: string, [2]: string }[]
  local ret = {}

  -- Path with padding
  table.insert(ret, { string.format("%-60s ", short_path), HIGHLIGHT_GROUPS.path })

  -- Score bar
  table.insert(ret, { score_bar, HIGHLIGHT_GROUPS.bar })

  table.insert(ret, { " ", "Normal" })

  -- Score number
  table.insert(ret, { score_text, HIGHLIGHT_GROUPS.score })

  return ret
end

---Format an impact analysis item for display in a picker
---@param item CodeShapeImpactScore
---@return string display
function M.format_impact(item)
  local u = get_util()
  local path = u.file_uri_to_fname(item.uri or "") or ""
  local short_path = u.shorten_path(path) or path
  local change_type = item.change_type == "affected" and "affect" or (item.change_type or "mod"):sub(1, 5)
  local score_bar = string.rep("█", math.floor((item.impact_score or 0) * 5))
  return string.format(
    "%-30s %-8s callers:%-3d hotspot:%.2f score:%.2f %s %s",
    item.name,
    change_type,
    item.caller_count or 0,
    item.hotspot_score or 0,
    item.impact_score or 0,
    score_bar,
    short_path
  )
end

---Format an impact analysis item for fzf-lua with ANSI colors
---@param item CodeShapeImpactScore
---@return string display
function M.format_impact_fzf(item)
  local u = get_util()
  local path = u.file_uri_to_fname(item.uri or "") or ""
  local short_path = u.shorten_path(path) or path
  local change_type = item.change_type == "affected" and "affect" or (item.change_type or "mod"):sub(1, 5)
  local score_bar = string.rep("█", math.floor((item.impact_score or 0) * 5))

  return string.format(
    ANSI_CODES.green
      .. "%-30s "
      .. ANSI_CODES.reset
      .. ANSI_CODES.blue
      .. "%-8s "
      .. ANSI_CODES.reset
      .. "callers:%-3d hotspot:%.2f score:%.2f "
      .. ANSI_CODES.red
      .. "%s"
      .. ANSI_CODES.reset
      .. " "
      .. ANSI_CODES.gray
      .. "%s"
      .. ANSI_CODES.reset,
    item.name or "",
    change_type,
    item.caller_count or 0,
    item.hotspot_score or 0,
    item.impact_score or 0,
    score_bar,
    short_path
  )
end

---Format an impact analysis item with highlights for snacks.nvim
---@param item CodeShapeImpactScore
---@return { [1]: string, [2]: string }[] display
function M.format_impact_highlight(item)
  local u = get_util()
  local path = u.file_uri_to_fname(item.uri or "") or ""
  local short_path = u.shorten_path(path) or path
  local change_type = item.change_type == "affected" and "affect" or (item.change_type or "mod"):sub(1, 5)
  local score_bar = string.rep("█", math.floor((item.impact_score or 0) * 5))

  ---@type { [1]: string, [2]: string }[]
  local ret = {}

  -- Symbol name
  table.insert(ret, { string.format("%-30s ", item.name or ""), HIGHLIGHT_GROUPS.name })

  -- Change type
  table.insert(ret, { string.format("%-8s ", change_type), HIGHLIGHT_GROUPS.change_type })

  -- Caller count
  table.insert(ret, { "callers:", "Normal" })
  table.insert(ret, { string.format("%-3d ", item.caller_count or 0), HIGHLIGHT_GROUPS.score })

  -- Hotspot score
  table.insert(ret, { "hotspot:", "Normal" })
  table.insert(ret, { string.format("%.2f ", item.hotspot_score or 0), HIGHLIGHT_GROUPS.score })

  -- Impact score
  table.insert(ret, { "score:", "Normal" })
  table.insert(ret, { string.format("%.2f ", item.impact_score or 0), HIGHLIGHT_GROUPS.score })

  -- Score bar
  table.insert(ret, { score_bar, HIGHLIGHT_GROUPS.bar })

  table.insert(ret, { " ", "Normal" })

  -- Path
  table.insert(ret, { short_path, HIGHLIGHT_GROUPS.path })

  return ret
end

---Build search params from config
---@param query string
---@param config CodeShapeConfig
---@param kind_filter? integer[] LSP SymbolKind values to filter by
---@return table params
function M.search_params(query, config, kind_filter)
  local params = {
    q = query,
    limit = config.search.limit,
    complexity_cap = config.metrics.complexity_cap,
  }
  if kind_filter then
    params.filters = { kinds = kind_filter }
  end
  return params
end

---Run search/query and return symbols asynchronously via coroutine yield.
---Must be called from a coroutine context (telescope, fzf-lua, snacks all provide this).
---@param query string
---@param config CodeShapeConfig
---@return CodeShapeSearchResultItem[]
function M.search_symbols(query, config)
  if type(query) ~= "string" or query == "" then
    return {}
  end

  local rpc = require("code-shape.rpc")
  local params = M.search_params(query, config)
  local co = coroutine.running()

  if not co then
    vim.notify("code-shape: search_symbols must be called from a coroutine context", vim.log.levels.WARN)
    return {}
  end

  local symbols = {}
  local done = false
  local yielded = false

  rpc.request("search/query", params, function(err, result)
    if not err and type(result) == "table" and is_list(result.symbols) then
      symbols = result.symbols
    end
    done = true
    if yielded then
      vim.schedule(function()
        if coroutine.status(co) == "suspended" then
          pcall(coroutine.resume, co)
        end
      end)
    end
  end)

  if not done then
    yielded = true
    coroutine.yield()
  end
  return symbols
end

return M
