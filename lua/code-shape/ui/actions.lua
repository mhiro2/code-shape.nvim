---@class CodeShapeUiActionsContext
---@field state CodeShapeUiState
---@field close fun()
---@field render_results fun()
---@field update_preview fun()

---@class CodeShapeUiActions
---@field do_search fun(query: string)
---@field select_prev fun()
---@field select_next fun()
---@field switch_mode_next fun()
---@field switch_mode_prev fun()
---@field switch_mode fun(mode_idx: integer)
---@field cycle_kind_filter fun()
---@field goto_definition fun()
---@field show_references fun()
---@field show_calls fun()
---@field follow_graph_node fun()
---@field calls_back fun()
---@field refresh_calls_graph fun()
---@field setup_keymaps fun(bufnr: integer, config: CodeShapeConfig)
local M = {}

local util = require("code-shape.util")
local ui_state = require("code-shape.ui.state")
local shared = require("code-shape.ui.actions.shared")
local calls_graph_factory = require("code-shape.ui.actions.calls_graph")
local lsp_factory = require("code-shape.ui.actions.lsp")
local keymaps = require("code-shape.ui.actions.keymaps")

---@param ctx CodeShapeUiActionsContext
---@return CodeShapeUiActions
function M.new(ctx)
  local state = ctx.state
  local calls_graph = calls_graph_factory.new({
    state = state,
    render_results = ctx.render_results,
    update_preview = ctx.update_preview,
  })

  ---@param item CodeShapeSearchResultItem
  local function jump_to_symbol(item)
    local path = shared.file_uri_to_fname(item.uri)
    if not path then
      vim.notify("code-shape: Cannot open non-file URI", vim.log.levels.WARN)
      return
    end
    ctx.close()
    shared.open_symbol_with_cmd("edit", item, path)
    vim.api.nvim_cmd({ cmd = "normal", args = { "zz" }, bang = true }, {})
  end

  local lsp_actions = lsp_factory.new({
    state = state,
    close = ctx.close,
    jump_to_symbol = jump_to_symbol,
  })

  ---@param query string
  local function do_search(query)
    state.current_query = query
    local rpc = require("code-shape.rpc")

    if state.current_mode == ui_state.MODE_HOTSPOTS then
      local hotspots = require("code-shape.hotspots")
      local top_hotspots = hotspots.get_top(state.current_config and state.current_config.search.limit or 50)

      state.current_results = {}
      for _, item in ipairs(top_hotspots) do
        local file_path = shared.file_uri_to_fname(item.path)
        local display_path = shared.uri_display_path(item.path)
        table.insert(state.current_results, {
          symbol_id = "",
          name = file_path and vim.fn.fnamemodify(file_path, ":t") or display_path,
          kind = 1,
          container_name = util.shorten_path(display_path),
          uri = item.path,
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
          detail = string.format("score: %.2f", item.score),
          score = item.score,
        })
      end
      state.selected_idx = 1
      ctx.render_results()
      ctx.update_preview()
      return
    end

    if state.current_mode == ui_state.MODE_CALLS then
      calls_graph.rebuild_calls_results()
      ctx.render_results()
      ctx.update_preview()
      return
    end

    if query == "" then
      state.current_results = {}
      state.selected_idx = 1
      ctx.render_results()
      ctx.update_preview()
      return
    end

    local search_params = {
      q = query,
      limit = state.current_config.search.limit,
      complexity_cap = state.current_config.metrics.complexity_cap,
    }

    local filter = ui_state.KIND_FILTERS[state.current_kind_filter]
    if filter.kinds then
      search_params.filters = { kinds = filter.kinds }
    end

    rpc.request("search/query", search_params, function(err, result)
      if err then
        vim.notify("code-shape: " .. err, vim.log.levels.WARN)
        return
      end
      state.current_results = result and result.symbols or {}
      state.selected_idx = 1
      vim.schedule(function()
        ctx.render_results()
        ctx.update_preview()
      end)
    end)
  end

  local function select_prev()
    if state.selected_idx > 1 then
      state.selected_idx = state.selected_idx - 1
      ctx.render_results()
      ctx.update_preview()
    end
  end

  local function select_next()
    if state.selected_idx < #state.current_results then
      state.selected_idx = state.selected_idx + 1
      ctx.render_results()
      ctx.update_preview()
    end
  end

  ---@type fun(mode_idx: integer)
  local switch_mode

  local function switch_mode_next()
    local next_mode = state.current_mode % 3 + 1
    switch_mode(next_mode)
  end

  local function switch_mode_prev()
    local prev_mode = ((state.current_mode - 2) % 3) + 1
    switch_mode(prev_mode)
  end

  ---@param mode_idx integer
  switch_mode = function(mode_idx)
    if mode_idx < 1 or mode_idx > 3 then
      return
    end

    local previous_mode = state.current_mode
    local previous_item = state.current_results[state.selected_idx]

    -- Save current mode state before switching
    local function save_mode_state(mode)
      if mode == ui_state.MODE_DEFS then
        state.defs_state.query = state.current_query
        state.defs_state.selected_idx = state.selected_idx
        state.defs_state.kind_filter = state.current_kind_filter
      elseif mode == ui_state.MODE_CALLS then
        state.calls_state.query = state.current_query
        state.calls_state.selected_idx = state.selected_idx
      elseif mode == ui_state.MODE_HOTSPOTS then
        state.hotspots_state.query = state.current_query
        state.hotspots_state.selected_idx = state.selected_idx
      end
    end

    -- Restore target mode state
    local function restore_mode_state(mode)
      if mode == ui_state.MODE_DEFS then
        state.current_query = state.defs_state.query
        state.selected_idx = state.defs_state.selected_idx
        state.current_kind_filter = state.defs_state.kind_filter or 1
      elseif mode == ui_state.MODE_CALLS then
        state.current_query = state.calls_state.query
        state.selected_idx = state.calls_state.selected_idx
      elseif mode == ui_state.MODE_HOTSPOTS then
        state.current_query = state.hotspots_state.query
        state.selected_idx = state.hotspots_state.selected_idx
      end
    end

    -- Save previous mode state
    save_mode_state(previous_mode)

    -- Update focused_symbol when selecting a symbol in Defs mode
    if previous_mode == ui_state.MODE_DEFS and previous_item and previous_item.kind ~= 1 then
      state.focused_symbol = previous_item
    end

    state.current_mode = mode_idx
    state.current_results = {}

    if mode_idx == ui_state.MODE_CALLS then
      -- Calls mode has special handling
      state.current_query = ""

      if previous_mode ~= ui_state.MODE_CALLS and previous_item and previous_item.kind ~= 1 then
        calls_graph.build_calls_graph(previous_item, { push_history = true, reset_history = true })
        return
      end

      calls_graph.rebuild_calls_results()
      ctx.render_results()
      ctx.update_preview()
      return
    end

    -- Restore state for Defs/Hotspots modes
    restore_mode_state(mode_idx)
    do_search(state.current_query)
  end

  local function cycle_kind_filter()
    if state.current_mode ~= ui_state.MODE_DEFS then
      return
    end
    state.current_kind_filter = (state.current_kind_filter % #ui_state.KIND_FILTERS) + 1
    do_search(state.current_query)
  end

  local function show_calls()
    if state.current_mode ~= ui_state.MODE_CALLS then
      switch_mode(ui_state.MODE_CALLS)
      return
    end

    local item = state.current_results[state.selected_idx]
    if item and item.graph_expandable then
      local center = state.calls_graph and state.calls_graph.center or nil
      if center and center.symbol_id == item.symbol_id then
        calls_graph.build_calls_graph(center, { push_history = false })
      else
        calls_graph.build_calls_graph(item, { push_history = true })
      end
      return
    end

    calls_graph.refresh_calls_graph()
  end

  ---@param bufnr integer
  ---@param config CodeShapeConfig
  local function setup_keymaps(bufnr, config)
    keymaps.setup({
      state = state,
      close = ctx.close,
      do_search = do_search,
      jump_to_symbol = jump_to_symbol,
      select_prev = select_prev,
      select_next = select_next,
      switch_mode_next = switch_mode_next,
      switch_mode_prev = switch_mode_prev,
      switch_mode = switch_mode,
      cycle_kind_filter = cycle_kind_filter,
      goto_definition = lsp_actions.goto_definition,
      show_references = lsp_actions.show_references,
      show_calls = show_calls,
      follow_graph_node = calls_graph.follow_graph_node,
      calls_back = calls_graph.calls_back,
      refresh_calls_graph = calls_graph.refresh_calls_graph,
    }, bufnr, config)
  end

  return {
    do_search = do_search,
    select_prev = select_prev,
    select_next = select_next,
    switch_mode_next = switch_mode_next,
    switch_mode_prev = switch_mode_prev,
    switch_mode = switch_mode,
    cycle_kind_filter = cycle_kind_filter,
    jump_to_symbol = jump_to_symbol,
    goto_definition = lsp_actions.goto_definition,
    show_references = lsp_actions.show_references,
    show_calls = show_calls,
    follow_graph_node = calls_graph.follow_graph_node,
    calls_back = calls_graph.calls_back,
    refresh_calls_graph = calls_graph.refresh_calls_graph,
    setup_keymaps = setup_keymaps,
  }
end

return M
