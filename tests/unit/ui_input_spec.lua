describe("ui.input", function()
  local original_keymap_set

  local mapped_keymaps
  local input_buf

  before_each(function()
    package.loaded["code-shape.ui.input"] = nil
    mapped_keymaps = {}
    input_buf = nil

    original_keymap_set = vim.keymap.set
    vim.keymap.set = function(mode, lhs, _rhs, opts)
      mapped_keymaps[tostring(mode) .. ":" .. tostring(lhs)] = opts and vim.deepcopy(opts) or {}
    end
  end)

  after_each(function()
    vim.keymap.set = original_keymap_set
    if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
      vim.api.nvim_buf_delete(input_buf, { force = true })
    end
    package.loaded["code-shape.ui.input"] = nil
  end)

  it("uses configurable keymaps for input window", function()
    local input = require("code-shape.ui.input")
    input_buf = vim.api.nvim_create_buf(false, true)

    local state = {
      input_buf = input_buf,
      current_results = {},
      selected_idx = 1,
      is_internal_update = false,
    }
    local cfg = {
      search = {
        debounce_ms = 0,
      },
      keymaps = {
        select = "<C-j>",
        open_vsplit = "<C-v>",
        open_split = "<C-s>",
        prev = "p",
        prev_alt = "<Up>",
        next = "n",
        next_alt = "<Down>",
        prev_insert = "<A-k>",
        next_insert = "<A-j>",
        mode_next = "<C-l>",
        mode_prev = "<C-h>",
        cycle_kind_filter = "f",
        goto_definition = "gd",
        show_references = "gr",
        show_calls = "gc",
        graph_follow = "l",
        graph_back = "h",
        graph_refresh = "r",
        close = "x",
        close_alt = "<C-c>",
      },
    }
    local callbacks = {
      close = function() end,
      do_search = function() end,
      select_next = function() end,
      select_prev = function() end,
      switch_mode_next = function() end,
      switch_mode_prev = function() end,
      cycle_kind_filter = function() end,
      jump_to_symbol = function() end,
    }

    input.setup(state, cfg, callbacks)

    assert.is_not_nil(mapped_keymaps["n:x"])
    assert.is_not_nil(mapped_keymaps["n:<C-c>"])
    assert.is_not_nil(mapped_keymaps["n:n"])
    assert.is_not_nil(mapped_keymaps["n:p"])
    assert.is_not_nil(mapped_keymaps["n:<C-l>"])
    assert.is_not_nil(mapped_keymaps["n:<C-h>"])
    assert.is_not_nil(mapped_keymaps["n:f"])
    assert.is_not_nil(mapped_keymaps["n:<C-j>"])

    assert.is_not_nil(mapped_keymaps["i:<C-j>"])
    assert.is_not_nil(mapped_keymaps["i:<A-j>"])
    assert.is_not_nil(mapped_keymaps["i:<A-k>"])
    assert.is_not_nil(mapped_keymaps["i:<C-l>"])
    assert.is_not_nil(mapped_keymaps["i:<C-h>"])
    assert.is_not_nil(mapped_keymaps["i:<C-f>"])

    assert.is_nil(mapped_keymaps["n:j"])
    assert.is_nil(mapped_keymaps["n:q"])
    assert.is_nil(mapped_keymaps["i:<C-n>"])
  end)
end)
