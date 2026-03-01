---@class CodeShapeModeState
---@field query string
---@field selected_idx integer
---@field kind_filter integer|nil

---@class CodeShapeUiState
---@field current_win integer|nil -- results window
---@field current_buf integer|nil -- results buffer
---@field input_win integer|nil -- input window
---@field input_buf integer|nil -- input buffer
---@field preview_win integer|nil
---@field preview_buf integer|nil
---@field current_results CodeShapeSearchResultItem[]
---@field selected_idx integer
---@field current_query string
---@field current_config CodeShapeConfig|nil
---@field is_internal_update boolean
---@field debounce_timer uv_timer_t|nil
---@field current_mode integer
---@field current_kind_filter integer
---@field calls_graph CodeShapeCallsGraph|nil
---@field calls_history CodeShapeSearchResultItem[]
---@field calls_history_idx integer
---@field calls_loading boolean
---@field calls_status string|nil
---@field calls_request_seq integer
---@field calls_graph_updated_at integer|nil -- timestamp of last graph build
---@field defs_state CodeShapeModeState -- per-mode state for Defs
---@field calls_state CodeShapeModeState -- per-mode state for Calls
---@field hotspots_state CodeShapeModeState -- per-mode state for Hotspots
---@field focused_symbol CodeShapeSearchResultItem|nil -- symbol selected for cross-mode context
local M = {}

M.MODE_DEFS = 1
M.MODE_CALLS = 2
M.MODE_HOTSPOTS = 3
M.MODE_NAMES = { "Defs", "Calls", "Hotspots" }

M.PREVIEW_CONTEXT_LINES = 5
M.HEADER_LINE_INDEX = 0 -- 0-indexed: mode tabs + filter indicator
M.INPUT_LINE_INDEX = 1 -- 0-indexed: the input/prompt line
M.RESULTS_START_LINE_INDEX = 2 -- 0-indexed: first line of results
M.RESULTS_HEADER_LINE_COUNT = 2 -- number of header lines before results (for compatibility)

M.KIND_FILTERS = {
  { name = "All", kinds = nil },
  { name = "Func", kinds = { 6, 9, 12 } }, -- Method, Constructor, Function
  { name = "Class", kinds = { 5, 11, 23 } }, -- Class, Interface, Struct
  { name = "Var", kinds = { 7, 8, 13, 14 } }, -- Property, Field, Variable, Constant
  { name = "Type", kinds = { 10, 22, 26 } }, -- Enum, EnumMember, TypeParameter
}

---@return CodeShapeUiState
function M.new()
  return {
    current_win = nil,
    current_buf = nil,
    input_win = nil,
    input_buf = nil,
    preview_win = nil,
    preview_buf = nil,
    current_results = {},
    selected_idx = 1,
    current_query = "",
    current_config = nil,
    is_internal_update = false,
    debounce_timer = nil,
    current_mode = M.MODE_DEFS,
    current_kind_filter = 1,
    calls_graph = nil,
    calls_history = {},
    calls_history_idx = 0,
    calls_loading = false,
    calls_status = nil,
    calls_request_seq = 0,
    calls_graph_updated_at = nil,
    -- per-mode state preservation
    defs_state = { query = "", selected_idx = 1, kind_filter = 1 },
    calls_state = { query = "", selected_idx = 1 },
    hotspots_state = { query = "", selected_idx = 1 },
    focused_symbol = nil,
  }
end

---@param state CodeShapeUiState
---@return boolean
function M.is_open(state)
  return state.current_win ~= nil
    and vim.api.nvim_win_is_valid(state.current_win)
    and state.input_win ~= nil
    and vim.api.nvim_win_is_valid(state.input_win)
end

---@param state CodeShapeUiState
function M.cleanup_timer(state)
  if not state.debounce_timer then
    return
  end

  if not state.debounce_timer:is_closing() then
    state.debounce_timer:stop()
    state.debounce_timer:close()
  end
  state.debounce_timer = nil
end

---@param state CodeShapeUiState
function M.reset(state)
  M.cleanup_timer(state)
  state.current_win = nil
  state.current_buf = nil
  state.input_win = nil
  state.input_buf = nil
  state.preview_win = nil
  state.preview_buf = nil
  state.current_results = {}
  state.selected_idx = 1
  state.is_internal_update = false
  state.current_mode = M.MODE_DEFS
  state.current_kind_filter = 1
  state.calls_graph = nil
  state.calls_history = {}
  state.calls_history_idx = 0
  state.calls_loading = false
  state.calls_status = nil
  state.calls_request_seq = 0
  state.calls_graph_updated_at = nil
  -- reset per-mode state
  state.defs_state = { query = "", selected_idx = 1, kind_filter = 1 }
  state.calls_state = { query = "", selected_idx = 1 }
  state.hotspots_state = { query = "", selected_idx = 1 }
  state.focused_symbol = nil
end

return M
