---@class CodeShapeUiRender
local M = {}

local util = require("code-shape.util")
local ui_state = require("code-shape.ui.state")
local uv = vim.uv

---@class CodeShapePreviewFileCache
---@field path string
---@field size integer
---@field mtime_sec integer
---@field mtime_nsec integer
---@field lines string[]
---@field access_time integer

---@type CodeShapePreviewFileCache[]
local preview_cache_entries = {}
local PREVIEW_CACHE_MAX_SIZE = 5

---Evict oldest entries when cache is full
local function maybe_evict_cache()
  if #preview_cache_entries <= PREVIEW_CACHE_MAX_SIZE then
    return
  end

  -- Sort by access time (oldest first)
  table.sort(preview_cache_entries, function(a, b)
    return a.access_time < b.access_time
  end)

  -- Remove oldest entries
  while #preview_cache_entries > PREVIEW_CACHE_MAX_SIZE do
    table.remove(preview_cache_entries, 1)
  end
end

---Find cache entry by path
---@param path string
---@return integer|nil
local function find_cache_index(path)
  for i, entry in ipairs(preview_cache_entries) do
    if entry.path == path then
      return i
    end
  end
  return nil
end

---@param line string
---@return string
local function normalize_line_ending(line)
  if line:sub(-1) == "\r" then
    return line:sub(1, -2)
  end
  return line
end

---@param content string
---@return string[]
local function split_file_lines(content)
  if content == "" then
    return {}
  end

  local lines = {}
  local cursor = 1

  while true do
    local line_end = content:find("\n", cursor, true)
    if not line_end then
      break
    end
    table.insert(lines, normalize_line_ending(content:sub(cursor, line_end - 1)))
    cursor = line_end + 1
  end

  if cursor <= #content then
    table.insert(lines, normalize_line_ending(content:sub(cursor)))
  end

  return lines
end

---@param path string
---@return CodeShapePreviewFileCache|nil entry
---@return string|nil err
local function read_cached_file(path)
  local stat, stat_err = uv.fs_stat(path)
  if not stat then
    return nil, tostring(stat_err or "failed to stat file")
  end

  local mtime = stat.mtime or {}
  local mtime_sec = tonumber(mtime.sec) or 0
  local mtime_nsec = tonumber(mtime.nsec) or 0
  local size = tonumber(stat.size) or 0

  -- Check if file is in cache
  local cache_idx = find_cache_index(path)
  if cache_idx then
    local cached = preview_cache_entries[cache_idx]
    if cached.size == size and cached.mtime_sec == mtime_sec and cached.mtime_nsec == mtime_nsec then
      -- Cache hit - update access time and return
      cached.access_time = uv.now() or 0
      return cached, nil
    end
    -- File changed - remove stale entry
    table.remove(preview_cache_entries, cache_idx)
  end

  -- Read file
  local fd, open_err = uv.fs_open(path, "r", 420)
  if not fd then
    return nil, tostring(open_err or "failed to open file")
  end

  local chunks = {}
  local offset = 0
  while true do
    local chunk, read_err = uv.fs_read(fd, 65536, offset)
    if not chunk then
      uv.fs_close(fd)
      return nil, tostring(read_err or "failed to read file")
    end

    if chunk == "" then
      break
    end

    table.insert(chunks, chunk)
    offset = offset + #chunk
  end
  uv.fs_close(fd)

  local entry = {
    path = path,
    size = size,
    mtime_sec = mtime_sec,
    mtime_nsec = mtime_nsec,
    lines = split_file_lines(table.concat(chunks)),
    access_time = uv.now() or 0,
  }

  -- Add to cache and maybe evict old entries
  table.insert(preview_cache_entries, entry)
  maybe_evict_cache()

  return entry, nil
end

---@param path string
---@param start_line integer 1-based
---@param end_line integer 1-based
---@return string[]|nil lines
---@return string|nil err
local function read_file_lines_in_range(path, start_line, end_line)
  if start_line < 1 then
    start_line = 1
  end
  if end_line < start_line then
    return {}, nil
  end

  local entry, read_err = read_cached_file(path)
  if not entry then
    return nil, read_err
  end

  local file_lines = entry.lines
  if #file_lines == 0 then
    return {}, nil
  end

  local last_line = math.min(end_line, #file_lines)
  if start_line > last_line then
    return {}, nil
  end

  local lines = {}
  for line_nr = start_line, last_line do
    table.insert(lines, file_lines[line_nr])
  end
  return lines, nil
end

---@param bufnr integer
---@param filetype string
local function start_preview_treesitter(bufnr, filetype)
  if filetype == "" then
    return
  end
  if type(vim.treesitter) ~= "table" or type(vim.treesitter.start) ~= "function" then
    return
  end
  pcall(vim.treesitter.start, bufnr, filetype)
end

---@param state CodeShapeUiState
---@return string
local function render_mode_tabs(state)
  local tabs = {}
  for i, name in ipairs(ui_state.MODE_NAMES) do
    if i == state.current_mode then
      table.insert(tabs, string.format("[%s]", name))
    else
      table.insert(tabs, string.format(" %s ", name))
    end
  end

  -- Add kind filter indicator on the same line for Defs mode
  if state.current_mode == ui_state.MODE_DEFS then
    local filter = ui_state.KIND_FILTERS[state.current_kind_filter]
    return " " .. table.concat(tabs, " ") .. string.format("  │ [t] %s", filter.name)
  end

  return " " .. table.concat(tabs, " ")
end

---@param uri string
---@return string
local function render_file_path(uri)
  if type(uri) ~= "string" or uri == "" then
    return ""
  end

  local path = util.uri_display_path(uri)

  return util.shorten_path(path) or path
end

---@param item CodeShapeSearchResultItem
---@return string
local function render_graph_entry(item)
  local section = item.graph_section or "incoming"
  local icon = section == "center" and "●"
    or section == "incoming" and "←"
    or section == "outgoing" and "→"
    or "↳"
  local file_path = render_file_path(item.uri)
  local count_suffix = item.graph_edge_count and item.graph_edge_count > 1 and (" x" .. item.graph_edge_count) or ""

  if section == "reference" then
    local line_no = (item.range and item.range.start and item.range.start.line or 0) + 1
    local col_no = (item.range and item.range.start and item.range.start.character or 0) + 1
    return string.format("%s Ref: %s:%d:%d%s", icon, file_path, line_no, col_no, count_suffix)
  end

  local kind = util.symbol_kind_name(item.kind)
  local container = type(item.container_name) == "string" and (" [" .. item.container_name .. "]") or ""
  if type(item.container_name) == "string" and item.container_name == file_path then
    container = ""
  end
  local path_suffix = file_path ~= "" and (" - " .. file_path) or ""
  return string.format("%s %s: %s%s%s%s", icon, kind, item.name, container, path_suffix, count_suffix)
end

---@param state CodeShapeUiState
---@param lines string[]
---@return integer[] result_line_map
local function render_calls_results(state, lines)
  local result_line_map = {}

  -- Build breadcrumb with position indicator
  local breadcrumbs = {}
  for i = 1, state.calls_history_idx do
    local history_item = state.calls_history[i]
    if history_item and type(history_item.name) == "string" and history_item.name ~= "" then
      table.insert(breadcrumbs, history_item.name)
    end
  end

  -- Show path with position (e.g., "Path (2/5): func1 > func2 > func3")
  if #breadcrumbs > 0 then
    local position_suffix = #state.calls_history > 1
        and string.format(" (%d/%d)", state.calls_history_idx, #state.calls_history)
      or ""
    table.insert(lines, " Path" .. position_suffix .. ": " .. table.concat(breadcrumbs, " > "))
  else
    table.insert(lines, " Call Graph")
  end

  -- Show section summary and key hints
  if state.calls_status and state.calls_status ~= "" then
    table.insert(lines, " " .. state.calls_status)
  elseif state.calls_graph then
    local counts = {
      state.calls_graph.incoming and #state.calls_graph.incoming or 0,
      state.calls_graph.outgoing and #state.calls_graph.outgoing or 0,
      state.calls_graph.references and #state.calls_graph.references or 0,
    }
    local summary = string.format("Callers: %d | Callees: %d | Refs: %d", counts[1], counts[2], counts[3])
    table.insert(lines, " " .. summary .. "  │ [gc/l] follow  [h] back  [r] refresh")
  else
    table.insert(lines, " [gc/l] follow  [h] back  [r] refresh  (line2: filter)")
  end

  if state.calls_loading then
    table.insert(lines, "")
    table.insert(lines, "  Loading call/reference edges...")
    return result_line_map
  end

  if not state.calls_graph then
    table.insert(lines, "")
    table.insert(lines, "  Select a symbol in Defs and press gc to build call graph")
    return result_line_map
  end

  if #state.current_results == 0 then
    table.insert(lines, "")
    table.insert(lines, "  No nodes matched current filter")
    return result_line_map
  end

  local section_counts = {
    center = state.calls_graph.center and 1 or 0,
    incoming = #state.calls_graph.incoming,
    outgoing = #state.calls_graph.outgoing,
    reference = #state.calls_graph.references,
  }
  local section_labels = {
    center = "Center",
    incoming = "Callers",
    outgoing = "Callees",
    reference = "References",
  }

  local last_section = ""
  for i, item in ipairs(state.current_results) do
    local section = item.graph_section or "incoming"
    if section ~= last_section then
      if i > 1 then
        table.insert(lines, "")
      end
      table.insert(lines, string.format(" %s (%d)", section_labels[section] or section, section_counts[section] or 0))
      last_section = section
    end

    local prefix = i == state.selected_idx and "> " or "  "
    table.insert(lines, prefix .. render_graph_entry(item))
    table.insert(result_line_map, #lines)
  end

  return result_line_map
end

---@param state CodeShapeUiState
function M.render_results(state)
  if not state.current_buf or not vim.api.nvim_buf_is_valid(state.current_buf) then
    return
  end

  -- Get current cursor position to restore later
  local cursor_col = 0
  if state.current_win and vim.api.nvim_win_is_valid(state.current_win) then
    local cursor = vim.api.nvim_win_get_cursor(state.current_win)
    cursor_col = cursor[2]
  end

  -- Line 1: Mode tabs + kind filter (for Defs mode)
  -- Input is now in a separate window, so we only render header + results
  local header_line = render_mode_tabs(state)
  local lines = { header_line }
  local result_line_map = {}

  if state.current_mode == ui_state.MODE_CALLS then
    result_line_map = render_calls_results(state, lines)
  else
    for i, item in ipairs(state.current_results) do
      local prefix = i == state.selected_idx and "> " or "  "
      local kind = util.symbol_kind_name(item.kind)
      local file_path = render_file_path(item.uri)
      local container = type(item.container_name) == "string" and (" [" .. item.container_name .. "]") or ""
      if type(item.container_name) == "string" and item.container_name == file_path then
        container = ""
      end
      local path_suffix = file_path ~= "" and (" - " .. file_path) or ""
      local line = string.format("%s%s: %s%s%s", prefix, kind, item.name, container, path_suffix)
      table.insert(lines, line)
      table.insert(result_line_map, #lines)
    end

    if #state.current_results == 0 then
      if state.current_mode == ui_state.MODE_DEFS then
        table.insert(lines, "")
        if state.current_query == "" then
          table.insert(lines, "  Type to search...")
          table.insert(lines, "")
          table.insert(lines, "  No results? Run :CodeShapeIndex or open a buffer with LSP attached.")
        else
          table.insert(lines, "  No results found.")
        end
      elseif state.current_mode == ui_state.MODE_HOTSPOTS then
        table.insert(lines, "")
        table.insert(lines, "  No hotspots found. Edit files to generate hotspots.")
      end
    end
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.current_buf })
  state.is_internal_update = true
  vim.api.nvim_buf_set_lines(state.current_buf, 0, -1, false, lines)
  state.is_internal_update = false

  -- Highlight line 1: header (tabs + filter)
  vim.api.nvim_buf_add_highlight(state.current_buf, -1, "CodeShapeTitle", 0, 0, -1)

  local tab_start = 1
  for i, name in ipairs(ui_state.MODE_NAMES) do
    local tab_text = i == state.current_mode and string.format("[%s]", name) or string.format(" %s ", name)
    if i == state.current_mode then
      vim.api.nvim_buf_add_highlight(state.current_buf, -1, "CodeShapeMode", 0, tab_start, tab_start + #tab_text)
    end
    tab_start = tab_start + #tab_text + 1
  end

  -- Highlight calls mode extra header lines
  if state.current_mode == ui_state.MODE_CALLS then
    vim.api.nvim_buf_add_highlight(state.current_buf, -1, "CodeShapeHint", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(state.current_buf, -1, "CodeShapeHint", 2, 0, -1)
  end

  for result_idx, line_nr in ipairs(result_line_map) do
    local hl = result_idx == state.selected_idx and "CodeShapeSelected" or "Normal"
    vim.api.nvim_buf_add_highlight(state.current_buf, -1, hl, line_nr - 1, 0, 2)
  end

  -- Keep cursor on the selected result line in results window
  if state.current_win and vim.api.nvim_win_is_valid(state.current_win) then
    if #result_line_map > 0 then
      local target_line = math.min(state.selected_idx, #result_line_map)
      vim.api.nvim_win_set_cursor(state.current_win, { result_line_map[target_line], cursor_col })
    end
  end
end

---@param state CodeShapeUiState
function M.update_preview(state)
  if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then
    return
  end

  local item = state.current_results[state.selected_idx]
  if not item then
    vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, { "No preview available" })
    return
  end

  local path = util.file_uri_to_fname(item.uri)
  if not path then
    vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, { "No preview available" })
    return
  end

  local filetype = vim.filetype.match({ filename = path }) or ""
  if filetype ~= "" then
    vim.api.nvim_set_option_value("filetype", filetype, { buf = state.preview_buf })
  end

  local symbol_line = (item.range and item.range.start and item.range.start.line or 0) + 1
  local symbol_end_line = (item.range and item.range["end"] and item.range["end"].line or (symbol_line - 1)) + 1
  local start_line = math.max(1, symbol_line - ui_state.PREVIEW_CONTEXT_LINES)
  local end_line = math.max(symbol_end_line, symbol_line) + ui_state.PREVIEW_CONTEXT_LINES

  local lines, read_err = read_file_lines_in_range(path, start_line, end_line)
  if not lines then
    vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, { "Unable to read file" })
    if read_err and state.current_config and state.current_config.debug then
      vim.notify("code-shape: preview read failed: " .. read_err, vim.log.levels.DEBUG)
    end
    return
  end

  if #lines == 0 then
    vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, { "No preview available" })
    return
  end

  vim.api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, lines)
  start_preview_treesitter(state.preview_buf, filetype)

  local symbol_line_idx = symbol_line - start_line
  if symbol_line_idx >= 0 and symbol_line_idx < #lines then
    vim.api.nvim_buf_add_highlight(state.preview_buf, -1, "CodeShapePreviewLine", symbol_line_idx, 0, -1)
  end
end

return M
