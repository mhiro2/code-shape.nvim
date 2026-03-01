---@class CodeShape
local M = {}

local types_loaded = false
local config_mod
local rpc
local util
local indexer
local ui
local hotspots
local snapshot
local roots
local highlight

local config = nil
local setup_done = false
local group = nil
local hotspots_idle_scheduled = false

local HOTSPOTS_IDLE_DELAY_MS = 300
local INDEX_PROGRESS_DELAY_MS = 5000
local INDEX_PROGRESS_INTERVAL_MS = 3000
local INDEX_PROGRESS_HEARTBEAT_MS = 10000

---@class CodeShapeManualIndexProgress
---@field id integer
---@field command_label string
---@field baseline_symbol_count integer
---@field progress_notified boolean
---@field last_progress_symbol_count integer|nil
---@field last_progress_notify_ms integer
local manual_index_progress = nil
local next_manual_index_progress_id = 0

---@param run_id integer|nil
local function stop_manual_index_progress(run_id)
  if not manual_index_progress then
    return
  end
  if run_id ~= nil and manual_index_progress.id ~= run_id then
    return
  end
  manual_index_progress = nil
end

---@param callback fun(symbol_count: integer|nil)
local function fetch_index_symbol_count(callback)
  rpc.request("index/stats", {}, function(err, result)
    if err or type(result) ~= "table" or type(result.symbol_count) ~= "number" then
      callback(nil)
      return
    end
    callback(result.symbol_count)
  end)
end

---@param run_id integer
---@param delay_ms integer
local function schedule_manual_index_progress(run_id, delay_ms)
  vim.defer_fn(function()
    local active = manual_index_progress
    if not active or active.id ~= run_id then
      return
    end

    fetch_index_symbol_count(function(symbol_count)
      local current = manual_index_progress
      if not current or current.id ~= run_id then
        return
      end

      local now = vim.uv.now() or 0
      local should_notify = false
      local message = nil

      if type(symbol_count) == "number" then
        local delta = symbol_count - current.baseline_symbol_count
        if delta < 0 then
          delta = 0
        end
        local changed = current.last_progress_symbol_count == nil or current.last_progress_symbol_count ~= symbol_count
        local heartbeat_due = current.progress_notified
          and now - current.last_progress_notify_ms >= INDEX_PROGRESS_HEARTBEAT_MS

        if not current.progress_notified or changed then
          should_notify = true
          message = string.format("code-shape: indexing in progress... %d symbols (+%d)", symbol_count, delta)
        elseif heartbeat_due then
          should_notify = true
          message = string.format("code-shape: indexing still running... %d symbols (+%d)", symbol_count, delta)
        end

        current.last_progress_symbol_count = symbol_count
      else
        local heartbeat_due = current.progress_notified
          and now - current.last_progress_notify_ms >= INDEX_PROGRESS_HEARTBEAT_MS
        if not current.progress_notified then
          should_notify = true
          message = "code-shape: indexing in progress..."
        elseif heartbeat_due then
          should_notify = true
          message = "code-shape: indexing still running..."
        end
      end

      if should_notify and message then
        vim.notify(message, vim.log.levels.INFO)
        current.progress_notified = true
        current.last_progress_notify_ms = now
      end

      schedule_manual_index_progress(run_id, INDEX_PROGRESS_INTERVAL_MS)
    end)
  end, delay_ms)
end

---@param command_label string
---@return integer run_id
local function start_manual_index_progress(command_label)
  stop_manual_index_progress(nil)

  next_manual_index_progress_id = next_manual_index_progress_id + 1
  local run_id = next_manual_index_progress_id

  manual_index_progress = {
    id = run_id,
    command_label = command_label,
    baseline_symbol_count = 0,
    progress_notified = false,
    last_progress_symbol_count = nil,
    last_progress_notify_ms = 0,
  }

  vim.notify(string.format("code-shape: indexing started (%s)", command_label), vim.log.levels.INFO)

  fetch_index_symbol_count(function(symbol_count)
    local active = manual_index_progress
    if not active or active.id ~= run_id then
      return
    end
    if type(symbol_count) == "number" and symbol_count >= 0 then
      active.baseline_symbol_count = symbol_count
    end
  end)

  schedule_manual_index_progress(run_id, INDEX_PROGRESS_DELAY_MS)
  return run_id
end

local function ensure_modules()
  if not types_loaded then
    require("code-shape.types")
    types_loaded = true
  end
  config_mod = config_mod or require("code-shape.config")
  rpc = rpc or require("code-shape.rpc")
  util = util or require("code-shape.util")
  indexer = indexer or require("code-shape.indexer")
  ui = ui or require("code-shape.ui")
  hotspots = hotspots or require("code-shape.hotspots")
  snapshot = snapshot or require("code-shape.snapshot")
  roots = roots or require("code-shape.roots")
  highlight = highlight or require("code-shape.highlight")
end

local function schedule_hotspots_after_idle()
  if not config or not config.hotspots.enabled or hotspots_idle_scheduled then
    return
  end

  hotspots_idle_scheduled = true
  vim.defer_fn(function()
    hotspots_idle_scheduled = false
    if not config or not config.hotspots.enabled then
      return
    end
    hotspots.calculate(config.hotspots, function() end)
  end, HOTSPOTS_IDLE_DELAY_MS)
end

---@param opts CodeShapeConfig|nil
function M.setup(opts)
  ensure_modules()
  highlight.setup()

  if not config then
    config = config_mod.setup(opts)
    rpc.start()
    snapshot.load(rpc, config)
  elseif opts ~= nil then
    config = config_mod.setup(util.tbl_deep_merge(config, opts))
  end

  if not setup_done then
    -- Register notification handlers
    rpc.on_notification("$/progress", function(params)
      if config and config.debug then
        local message = params.value and params.value.message or "indexing..."
        vim.notify("code-shape progress: " .. message, vim.log.levels.DEBUG)
      end
    end)

    rpc.on_notification("$/log", function(params)
      if config and config.debug then
        local level = params.level or "info"
        local message = params.message or ""
        local log_level = level == "error" and vim.log.levels.ERROR
          or level == "warn" and vim.log.levels.WARN
          or vim.log.levels.DEBUG
        vim.notify("code-shape: " .. message, log_level)
      end
    end)

    group = vim.api.nvim_create_augroup("code-shape", { clear = true })

    -- Index opened buffers on BufEnter
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(args)
        if not indexer.should_index(args.buf) then
          return
        end
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(args.buf) then
            return
          end
          indexer.index_buffer(args.buf)
        end)
      end,
    })

    -- Re-index on save
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      callback = function(args)
        if not indexer.should_index(args.buf) then
          return
        end
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(args.buf) then
            return
          end
          indexer.index_buffer(args.buf)
        end)
      end,
    })

    -- Cleanup on buffer wipeout
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      callback = function(args)
        indexer.cleanup_buffer(args.buf)
      end,
    })

    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      callback = function()
        highlight.setup()
      end,
    })

    -- Stop RPC on exit
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        snapshot.save(rpc, config, function()
          rpc.stop()
        end)
      end,
    })

    setup_done = true
  end

  -- Index current buffer
  local current_buf = vim.api.nvim_get_current_buf()
  if indexer.should_index(current_buf) then
    indexer.index_buffer(current_buf)
  end

  -- Calculate hotspots
  schedule_hotspots_after_idle()
end

function M.ensure_setup()
  ensure_modules()
  if not setup_done then
    M.setup({})
  end
end

---@return CodeShapeConfig|nil
function M.get_config()
  return config
end

---Open search UI (uses configured picker backend)
---@param opts? { picker?: string }
function M.open(opts)
  M.ensure_setup()
  if config.picker and config.picker ~= "builtin" then
    local picker = require("code-shape.picker")
    return picker.open("defs", vim.tbl_extend("force", { picker = config.picker }, opts or {}))
  end
  ui.open(config)
end

---Search symbols
---@param query string
---@param cb fun(err: string|nil, result: CodeShapeSearchResult|nil)
function M.search(query, cb)
  M.ensure_setup()
  rpc.request("search/query", {
    q = query,
    limit = config.search.limit,
    complexity_cap = config.metrics.complexity_cap,
  }, cb)
end

---Get index stats
---@param cb fun(err: string|nil, result: CodeShapeIndexStats|nil)
function M.stats(cb)
  M.ensure_setup()
  rpc.request("index/stats", {}, cb)
end

---@class CodeShapeBufferIndexSummary
---@field target_count integer
---@field indexed_count integer
---@field empty_count integer
---@field failed_count integer
---@field skipped_count integer

---@return CodeShapeBufferIndexSummary
local function new_buffer_index_summary()
  return {
    target_count = 0,
    indexed_count = 0,
    empty_count = 0,
    failed_count = 0,
    skipped_count = 0,
  }
end

---@param summary CodeShapeBufferIndexSummary
---@param status CodeShapeBufferIndexStatus
local function record_buffer_index_result(summary, status)
  if status == "indexed" then
    summary.indexed_count = summary.indexed_count + 1
  elseif status == "empty" then
    summary.empty_count = summary.empty_count + 1
  elseif status == "error" then
    summary.failed_count = summary.failed_count + 1
  else
    summary.skipped_count = summary.skipped_count + 1
  end
end

---@param summary CodeShapeBufferIndexSummary
---@return string
local function format_buffer_index_summary(summary)
  return string.format(
    "%d/%d buffers (empty: %d, failed: %d)",
    summary.indexed_count,
    summary.target_count,
    summary.empty_count,
    summary.failed_count
  )
end

---@param callback fun(summary: CodeShapeBufferIndexSummary)
local function index_loaded_buffers_immediate(callback)
  local summary = new_buffer_index_summary()
  local pending = 0
  local finished = false

  local function finish()
    if finished then
      return
    end
    finished = true
    callback(summary)
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if indexer.should_index(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      summary.target_count = summary.target_count + 1
      pending = pending + 1
      indexer.index_buffer(bufnr, function(status, _result)
        record_buffer_index_result(summary, status)
        pending = pending - 1
        if pending == 0 then
          finish()
        end
      end, { immediate = true })
    end
  end

  if pending == 0 then
    finish()
  end
end

---@param verb "indexed"|"reindexed"
---@param summary CodeShapeBufferIndexSummary
---@param workspace_result table|nil
local function notify_manual_index_summary(verb, summary, workspace_result)
  local workspace_symbol_count = workspace_result and workspace_result.symbol_count or 0
  local workspace_suffix = string.format("%d workspace symbols", workspace_symbol_count)
  if workspace_result and type(workspace_result.query_count) == "number" then
    local fallback_label = workspace_result.fallback_used and ", fallback used" or ""
    workspace_suffix =
      string.format("%s (queries: %d%s)", workspace_suffix, workspace_result.query_count, fallback_label)
  end

  local level = (summary.failed_count > 0 or workspace_symbol_count == 0) and vim.log.levels.WARN or vim.log.levels.INFO
  vim.notify(
    string.format("code-shape: %s %s, %s", verb, format_buffer_index_summary(summary), workspace_suffix),
    level
  )
end

---Index currently opened buffers
function M.index_open_buffers()
  M.ensure_setup()
  local progress_run_id = start_manual_index_progress("CodeShapeIndex")
  index_loaded_buffers_immediate(function(summary)
    -- Also index workspace symbols if LSP supports it
    indexer.index_workspace(function(err, result)
      stop_manual_index_progress(progress_run_id)
      if err then
        vim.notify("code-shape: indexed " .. format_buffer_index_summary(summary), vim.log.levels.INFO)
        vim.notify("code-shape: workspace index: " .. err, vim.log.levels.DEBUG)
        return
      end
      notify_manual_index_summary("indexed", summary, result)
    end)
  end)

  if config.hotspots.enabled then
    hotspots.calculate(config.hotspots, function() end)
  end
end

---Reindex all opened buffers
function M.reindex()
  M.ensure_setup()
  local progress_run_id = start_manual_index_progress("CodeShapeReindex")
  indexer.reindex_all(function(summary)
    indexer.reset_workspace_indexed()

    -- Reindex workspace symbols
    indexer.index_workspace(function(err, result)
      stop_manual_index_progress(progress_run_id)
      if err then
        vim.notify("code-shape: reindexed " .. format_buffer_index_summary(summary), vim.log.levels.INFO)
        vim.notify("code-shape: workspace reindex: " .. err, vim.log.levels.DEBUG)
        return
      end
      notify_manual_index_summary("reindexed", summary, result)
    end, { restart = true })
  end, { immediate = true })

  if config.hotspots.enabled then
    hotspots.calculate(config.hotspots, function() end)
  end
end

---Clear index
function M.clear()
  M.ensure_setup()
  indexer.clear_all()
  hotspots.reset()
  roots.clear()
  vim.notify("code-shape: index cleared", vim.log.levels.INFO)
end

---Cancel workspace indexing if running
function M.cancel_workspace_index()
  M.ensure_setup()
  local cancelled = indexer.cancel_workspace_index()
  if cancelled then
    stop_manual_index_progress(nil)
    vim.notify("code-shape: workspace indexing cancelled", vim.log.levels.INFO)
  else
    vim.notify("code-shape: no workspace indexing in progress", vim.log.levels.DEBUG)
  end
end

---Show status
function M.status()
  M.ensure_setup()

  local active_roots = roots.get_roots()

  -- Multi-root: show per-root breakdown
  if #active_roots > 1 then
    local root_infos = {}
    for _, root in ipairs(active_roots) do
      local uri_prefix = util.fname_to_file_uri(root)
      if uri_prefix then
        if not uri_prefix:match("/$") then
          uri_prefix = uri_prefix .. "/"
        end
        table.insert(root_infos, {
          name = vim.fn.fnamemodify(root, ":t"),
          uri_prefix = uri_prefix,
        })
      end
    end

    if #root_infos == 0 then
      vim.notify("code-shape: no valid roots available", vim.log.levels.WARN)
      return
    end

    rpc.request("index/statsByRoot", { roots = root_infos }, function(err, result)
      if err then
        vim.notify("code-shape: " .. err, vim.log.levels.ERROR)
        return
      end

      if type(result) ~= "table" then
        vim.notify("code-shape: invalid response from core", vim.log.levels.ERROR)
        return
      end

      local total = result.total or {}
      local lines = {
        "CodeShape Status:",
        string.format(
          "  Total: %d symbols, %d files, %d hotspots",
          total.symbol_count or 0,
          total.uri_count or 0,
          total.hotspot_count or 0
        ),
      }

      for _, rs in ipairs(result.roots or {}) do
        table.insert(
          lines,
          string.format(
            "  [%s] %d symbols, %d files, %d hotspots",
            rs.name or "?",
            rs.symbol_count or 0,
            rs.uri_count or 0,
            rs.hotspot_count or 0
          )
        )
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end)
    return
  end

  -- Single root or no roots: existing behavior
  rpc.request("index/stats", {}, function(err, result)
    if err then
      vim.notify("code-shape: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Defensive check for result shape
    if type(result) ~= "table" then
      vim.notify("code-shape: invalid response from core", vim.log.levels.ERROR)
      return
    end

    local symbol_count = type(result.symbol_count) == "number" and result.symbol_count or 0
    local uri_count = type(result.uri_count) == "number" and result.uri_count or 0
    local hotspot_count = type(result.hotspot_count) == "number" and result.hotspot_count or 0

    local lines = {
      "CodeShape Status:",
      "  Symbols: " .. symbol_count,
      "  Files: " .. uri_count,
      "  Hotspots: " .. hotspot_count,
    }
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end)
end

---Show hotspots UI (uses configured picker backend)
---@param opts? { picker?: string }
function M.show_hotspots(opts)
  M.ensure_setup()
  if config.picker and config.picker ~= "builtin" then
    local picker = require("code-shape.picker")
    return picker.open("hotspots", vim.tbl_extend("force", { picker = config.picker }, opts or {}))
  end
  ui.open_hotspots(config)
end

---Show impact analysis UI (files/symbols in risk order)
---@param opts? { picker?: string, base?: string, head?: string, staged?: boolean }
function M.show_impact(opts)
  M.ensure_setup()
  opts = opts or {}
  if config.picker and config.picker ~= "builtin" then
    local picker = require("code-shape.picker")
    return picker.open("impact", vim.tbl_extend("force", { picker = config.picker }, opts))
  end
  ui.open_impact(config, opts)
end

---Open Calls mode for symbol under cursor using builtin UI
---This is useful for external picker users who want to access call graph functionality
function M.open_calls_from_cursor()
  M.ensure_setup()

  -- Get symbol under cursor using LSP
  local params = vim.lsp.util.make_position_params(0, "utf-16")
  local bufnr = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr })

  local symbol_client = nil
  for _, client in ipairs(clients) do
    if client.supports_method("textDocument/documentSymbol") or client.supports_method("textDocument/definition") then
      symbol_client = client
      break
    end
  end

  if not symbol_client then
    vim.notify("code-shape: No LSP client available for symbol resolution", vim.log.levels.WARN)
    return
  end

  -- Try to get symbol at cursor position
  symbol_client.request("textDocument/documentSymbol", { textDocument = params.textDocument }, function(err, result)
    if err or not result or #result == 0 then
      vim.notify("code-shape: Could not resolve symbol at cursor", vim.log.levels.INFO)
      return
    end

    -- Find symbol containing cursor position
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
    local cursor_col = vim.api.nvim_win_get_cursor(0)[2]

    ---Get the range from a symbol, supporting both DocumentSymbol and SymbolInformation formats
    ---@param sym table
    ---@return table|nil range
    local function get_symbol_range(sym)
      return sym.range or sym.selectionRange or (sym.location and sym.location.range) or nil
    end

    ---Check if result is DocumentSymbol[] (has range field) vs SymbolInformation[] (has location field)
    local is_document_symbol = result[1] and result[1].range ~= nil

    local function find_symbol_at_cursor(symbols, depth)
      depth = depth or 0
      if depth > 10 then
        return nil
      end

      for _, sym in ipairs(symbols) do
        local range = get_symbol_range(sym)
        if range then
          local start_line, start_char = range.start.line, range.start.character
          local end_line, end_char = range["end"].line, range["end"].character

          if
            cursor_line >= start_line
            and cursor_line <= end_line
            and (cursor_line > start_line or cursor_col >= start_char)
            and (cursor_line < end_line or cursor_col <= end_char)
          then
            -- Check children first (more specific match) - only DocumentSymbol has children
            if is_document_symbol and sym.children and #sym.children > 0 then
              local child_match = find_symbol_at_cursor(sym.children, depth + 1)
              if child_match then
                return child_match
              end
            end
            return sym
          end
        end
      end
      return nil
    end

    local symbol = find_symbol_at_cursor(result)
    if not symbol then
      vim.notify("code-shape: No symbol found at cursor position", vim.log.levels.INFO)
      return
    end

    -- Convert to CodeShapeSearchResultItem format
    -- Support both DocumentSymbol (range) and SymbolInformation (location.range)
    local uri = vim.uri_from_bufnr(bufnr)
    local sym_range = get_symbol_range(symbol)
    local item = {
      symbol_id = "",
      name = symbol.name,
      kind = util.to_symbol_kind(symbol.kind),
      container_name = symbol.containerName or nil,
      uri = uri,
      range = {
        start = { line = sym_range.start.line, character = sym_range.start.character },
        ["end"] = { line = sym_range["end"].line, character = sym_range["end"].character },
      },
      detail = symbol.detail or nil,
      score = 1,
    }

    -- Open builtin UI in Calls mode
    local ui_instance = ui.new()
    ui_instance.open(config)

    -- Build call graph for the symbol
    vim.schedule(function()
      local actions = require("code-shape.ui.actions")
      -- The UI actions will be available after opening
      -- We need to trigger the call graph build
      local state = ui_instance.state
      if state then
        state.focused_symbol = item
        state.current_mode = require("code-shape.ui.state").MODE_CALLS
        -- Trigger call graph build through the actions module
        local actions_ctx = {
          state = state,
          close = function()
            ui_instance.close()
          end,
          render_results = function()
            require("code-shape.ui.render").render_results(state)
          end,
          update_preview = function()
            require("code-shape.ui.render").update_preview(state)
          end,
        }
        local ui_actions = actions.new(actions_ctx)
        ui_actions.show_calls()
      end
    end)
  end, bufnr)
end

return M
