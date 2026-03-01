describe("ui.actions.keymaps", function()
  local original_keymap_set

  ---@param state table
  ---@return CodeShapeUiKeymapContext
  local function build_ctx(state)
    local noop = function() end
    return {
      state = state,
      close = noop,
      do_search = noop,
      jump_to_symbol = noop,
      select_prev = noop,
      select_next = noop,
      switch_mode_next = noop,
      switch_mode_prev = noop,
      switch_mode = noop,
      cycle_kind_filter = noop,
      goto_definition = noop,
      show_references = noop,
      show_calls = noop,
      follow_graph_node = noop,
      calls_back = noop,
      refresh_calls_graph = noop,
    }
  end

  ---@return table
  local function build_config()
    return {
      search = {
        debounce_ms = 10,
      },
      keymaps = {},
    }
  end

  before_each(function()
    package.loaded["code-shape.ui.actions.keymaps"] = nil

    original_keymap_set = vim.keymap.set
    vim.keymap.set = function() end
  end)

  after_each(function()
    vim.keymap.set = original_keymap_set
    package.loaded["code-shape.ui.actions.keymaps"] = nil
  end)

  it("sets up keymaps without error", function()
    local keymaps = require("code-shape.ui.actions.keymaps")
    local state = {
      is_internal_update = false,
      current_mode = 1,
      current_results = {},
      selected_idx = 1,
    }
    -- Should not throw error
    keymaps.setup(build_ctx(state), 1, build_config())
    assert.is_true(true)
  end)
end)
