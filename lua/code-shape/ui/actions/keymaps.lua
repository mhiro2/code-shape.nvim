---@class CodeShapeUiKeymapContext
---@field state CodeShapeUiState
---@field close fun()
---@field do_search fun(query: string)
---@field jump_to_symbol fun(item: CodeShapeSearchResultItem)
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
local M = {}

local shared = require("code-shape.ui.actions.shared")

---@param ctx CodeShapeUiKeymapContext
---@param bufnr integer
---@param config CodeShapeConfig
function M.setup(ctx, bufnr, config)
  local state = ctx.state

  -- Results buffer is read-only, so we don't need on_lines handling
  -- Input handling is done by the separate input window module

  local opts = { buffer = bufnr, noremap = true, silent = true }
  local nowait_opts = vim.tbl_extend("force", opts, { nowait = true })
  local keymaps = config.keymaps

  ---@param mode string
  ---@param lhs string|nil
  ---@param rhs function
  ---@param map_opts? vim.keymap.set.Opts
  local function map(mode, lhs, rhs, map_opts)
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set(mode, lhs, rhs, map_opts or opts)
    end
  end

  map("n", keymaps.select, function()
    if state.current_results[state.selected_idx] then
      ctx.jump_to_symbol(state.current_results[state.selected_idx])
    end
  end, nowait_opts)

  map("n", keymaps.open_vsplit, function()
    local item = state.current_results[state.selected_idx]
    if item then
      local path = shared.file_uri_to_fname(item.uri)
      if not path then
        vim.notify("code-shape: Cannot open non-file URI", vim.log.levels.WARN)
        return
      end
      ctx.close()
      shared.open_symbol_with_cmd("vsplit", item, path)
    end
  end)

  map("n", keymaps.open_split, function()
    local item = state.current_results[state.selected_idx]
    if item then
      local path = shared.file_uri_to_fname(item.uri)
      if not path then
        vim.notify("code-shape: Cannot open non-file URI", vim.log.levels.WARN)
        return
      end
      ctx.close()
      shared.open_symbol_with_cmd("split", item, path)
    end
  end)

  map("n", keymaps.prev, ctx.select_prev)
  map("n", keymaps.prev_alt, ctx.select_prev)
  map("n", keymaps.next, ctx.select_next)
  map("n", keymaps.next_alt, ctx.select_next)

  map("n", keymaps.mode_next, ctx.switch_mode_next)
  map("n", keymaps.mode_prev, ctx.switch_mode_prev)

  map("n", keymaps.cycle_kind_filter, ctx.cycle_kind_filter)

  map("n", keymaps.goto_definition, ctx.goto_definition)
  map("n", keymaps.show_references, ctx.show_references)
  map("n", keymaps.show_calls, ctx.show_calls)
  map("n", keymaps.graph_follow, ctx.follow_graph_node)
  map("n", keymaps.graph_back, ctx.calls_back)
  map("n", keymaps.graph_refresh, ctx.refresh_calls_graph)

  map("n", keymaps.close, ctx.close, nowait_opts)
  map("n", keymaps.close_alt, ctx.close, nowait_opts)
end

return M
