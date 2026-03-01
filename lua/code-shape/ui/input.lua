---@class CodeShapeUiInputCallbacks
---@field close fun()
---@field do_search fun(query: string)
---@field select_next fun()
---@field select_prev fun()
---@field switch_mode_next fun()
---@field switch_mode_prev fun()
---@field cycle_kind_filter fun()
---@field jump_to_symbol fun(item: CodeShapeSearchResultItem)
---@field show_calls fun()

---@class CodeShapeUiInput
local M = {}

---@param state CodeShapeUiState
---@param config CodeShapeConfig
---@param callbacks CodeShapeUiInputCallbacks
function M.setup(state, config, callbacks)
  local PROMPT_LEN = 2 -- "> " is 2 characters
  local keymaps = config.keymaps or {}

  -- Set up buffer attachment for input buffer
  vim.api.nvim_buf_attach(state.input_buf, false, {
    on_lines = function(_, _, _, firstline, lastline, new_lastline)
      if state.is_internal_update then
        return
      end

      -- Handle nil parameters (for tests)
      firstline = firstline or 0
      lastline = lastline or 0
      new_lastline = new_lastline or 0

      if state.debounce_timer and not state.debounce_timer:is_closing() then
        state.debounce_timer:stop()
        state.debounce_timer:close()
      end
      state.debounce_timer = vim.uv.new_timer()
      state.debounce_timer:start(config.search.debounce_ms, 0, function()
        if state.debounce_timer and not state.debounce_timer:is_closing() then
          state.debounce_timer:close()
        end
        state.debounce_timer = nil
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(state.input_buf) then
            return
          end
          -- Read the query from the input buffer, stripping the prompt prefix
          local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
          local full_line = lines[1] or ""
          local query = full_line:sub(PROMPT_LEN + 1) -- Strip "> " prefix
          -- Update state and call do search
          state.current_query = query
          callbacks.do_search(query)
        end)
      end)
    end,
  })

  -- Set up keymaps for input window
  local opts = { buffer = state.input_buf, noremap = true, silent = true }
  local nowait_opts = vim.tbl_extend("force", opts, { nowait = true })

  ---@param lhs string|nil
  ---@return string|nil
  local function insert_ctrl_lhs(lhs)
    if type(lhs) ~= "string" or lhs == "" then
      return nil
    end
    if lhs:match("^<C%-.+>$") then
      return lhs
    end
    if #lhs == 1 and lhs:match("^%a$") then
      return "<C-" .. lhs:lower() .. ">"
    end
    return nil
  end

  ---@param mode string
  ---@param lhs string|nil
  ---@param rhs function
  ---@param map_opts? vim.keymap.set.Opts
  local function map(mode, lhs, rhs, map_opts)
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set(mode, lhs, rhs, map_opts or opts)
    end
  end

  local function jump_to_selected()
    local selected = state.current_results[state.selected_idx]
    if selected then
      callbacks.jump_to_symbol(selected)
    end
  end

  map("n", keymaps.close, callbacks.close, nowait_opts)
  map("n", keymaps.close_alt, callbacks.close, nowait_opts)

  map("n", keymaps.next, callbacks.select_next)
  map("n", keymaps.next_alt, callbacks.select_next)
  map("n", keymaps.prev, callbacks.select_prev)
  map("n", keymaps.prev_alt, callbacks.select_prev)

  map("n", keymaps.mode_next, callbacks.switch_mode_next)
  map("n", keymaps.mode_prev, callbacks.switch_mode_prev)

  map("n", keymaps.cycle_kind_filter, callbacks.cycle_kind_filter)
  map("n", keymaps.select, jump_to_selected, nowait_opts)

  map("i", keymaps.select, jump_to_selected, nowait_opts)
  map("i", keymaps.next_insert, callbacks.select_next)
  map("i", keymaps.prev_insert, callbacks.select_prev)
  map("i", keymaps.mode_next, callbacks.switch_mode_next)
  map("i", keymaps.mode_prev, callbacks.switch_mode_prev)
  map("i", insert_ctrl_lhs(keymaps.cycle_kind_filter), callbacks.cycle_kind_filter)
  map("i", insert_ctrl_lhs(keymaps.show_calls), callbacks.show_calls)
end

return M
