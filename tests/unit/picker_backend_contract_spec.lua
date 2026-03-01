---@class PickerBackendContractState
---@field cmd_calls table[]
---@field cursor_calls table[]
---@field notifications table[]
---@field wait_called boolean
---@field source_uri string
---@field source_path string
---@field fzf_live_fn? fun(query: string): string[]
---@field fzf_live_opts? table
---@field fzf_exec_entries? string[]
---@field fzf_exec_opts? table
---@field snacks_picker_calls? table[]
---@field telescope_picker_specs? table[]
---@field telescope_actions? table<string, fun()>
---@field telescope_selected_entry? table

---@class PickerBackendContractAction
---@field assert_result fun()
---@field select_default fun()

---@class PickerBackendContractAdapter
---@field backend string
---@field module_name string
---@field stub_module_keys string[]
---@field install_stubs fun(state: PickerBackendContractState)
---@field prepare_defs fun(state: PickerBackendContractState, picker: table): PickerBackendContractAction
---@field prepare_hotspots fun(state: PickerBackendContractState, picker: table): PickerBackendContractAction

local shared_module_keys = {
  "code-shape",
  "code-shape.rpc",
  "code-shape.hotspots",
}

local function reset_picker_modules()
  package.loaded["code-shape.picker.utils"] = nil
  package.loaded["code-shape.picker.fzf_lua"] = nil
  package.loaded["code-shape.picker.snacks"] = nil
  package.loaded["code-shape.picker.telescope"] = nil
end

---@param modules string[]
---@return table<string, any>
local function save_loaded_modules(modules)
  local saved = {}
  for _, name in ipairs(modules) do
    saved[name] = package.loaded[name]
  end
  return saved
end

---@param modules string[]
---@param saved table<string, any>
local function restore_loaded_modules(modules, saved)
  for _, name in ipairs(modules) do
    package.loaded[name] = saved[name]
  end
end

---@param state PickerBackendContractState
local function install_common_stubs(state)
  package.loaded["code-shape"] = {
    ensure_setup = function() end,
    get_config = function()
      return { search = { limit = 20 }, metrics = { complexity_cap = 50 } }
    end,
  }

  package.loaded["code-shape.rpc"] = {
    request = function(_, _, cb)
      cb(nil, {
        symbols = {
          {
            symbol_id = "sym-1",
            name = "my_fn",
            kind = 12,
            container_name = "M",
            uri = state.source_uri,
            range = {
              start = { line = 0, character = 0 },
              ["end"] = { line = 0, character = 4 },
            },
            detail = nil,
            score = 1.0,
          },
        },
      })
    end,
    request_sync = function()
      return {
        symbols = {
          {
            symbol_id = "sym-1",
            name = "my_fn",
            kind = 12,
            container_name = "M",
            uri = state.source_uri,
            range = {
              start = { line = 0, character = 0 },
              ["end"] = { line = 0, character = 4 },
            },
            detail = nil,
            score = 1.0,
          },
        },
      },
        nil
    end,
  }

  package.loaded["code-shape.hotspots"] = {
    get_top = function()
      return {
        {
          path = state.source_uri,
          score = 0.9,
        },
      }
    end,
  }
end

---@param cmd_calls table[]
---@return boolean
local function has_centering_cmd(cmd_calls)
  for _, call in ipairs(cmd_calls) do
    if call.cmd and call.cmd.cmd == "normal" and call.cmd.args and call.cmd.args[1] == "zz" then
      return true
    end
  end
  return false
end

---@param adapter PickerBackendContractAdapter
---@return string[]
local function module_keys(adapter)
  local keys = {}
  for _, key in ipairs(shared_module_keys) do
    table.insert(keys, key)
  end
  for _, key in ipairs(adapter.stub_module_keys) do
    table.insert(keys, key)
  end
  return keys
end

---@type PickerBackendContractAdapter[]
local adapters = {
  {
    backend = "fzf_lua",
    module_name = "code-shape.picker.fzf_lua",
    stub_module_keys = {
      "fzf-lua",
    },
    install_stubs = function(state)
      package.loaded["fzf-lua"] = {
        fzf_live = function(fn, opts)
          state.fzf_live_fn = fn
          state.fzf_live_opts = opts
        end,
        fzf_exec = function(entries, opts)
          state.fzf_exec_entries = entries
          state.fzf_exec_opts = opts
        end,
      }
    end,
    prepare_defs = function(state, picker)
      picker.defs({})
      assert.is_function(state.fzf_live_fn)
      assert.is_table(state.fzf_live_opts)

      local results = state.fzf_live_fn("my_fn")
      assert.are.equal(1, #results)

      return {
        assert_result = function()
          assert.is_true(results[1]:find("my_fn", 1, true) ~= nil)
        end,
        select_default = function()
          state.fzf_live_opts.actions["default"]({ results[1] })
        end,
      }
    end,
    prepare_hotspots = function(state, picker)
      picker.hotspots({})
      assert.is_table(state.fzf_exec_entries)
      assert.are.equal(1, #state.fzf_exec_entries)
      assert.is_table(state.fzf_exec_opts)

      return {
        assert_result = function()
          assert.is_true(state.fzf_exec_entries[1]:find(state.source_path, 1, true) ~= nil)
        end,
        select_default = function()
          state.fzf_exec_opts.actions["default"]({ state.fzf_exec_entries[1] })
        end,
      }
    end,
  },
  {
    backend = "snacks",
    module_name = "code-shape.picker.snacks",
    stub_module_keys = {
      "snacks",
    },
    install_stubs = function(state)
      state.snacks_picker_calls = {}
      package.loaded["snacks"] = {
        picker = function(opts)
          table.insert(state.snacks_picker_calls, opts)
        end,
      }
    end,
    prepare_defs = function(state, picker)
      picker.defs({})
      local opts = state.snacks_picker_calls[1]
      assert.is_table(opts)
      assert.is_true(opts.live)

      local finder_result = opts.finder(nil, {
        filter = { search = "", pattern = "my_fn" },
        async = {
          on = function() end,
          resume = function() end,
          suspend = function() end,
        },
      })
      assert.is_function(finder_result)
      local items = {}
      finder_result(function(item)
        table.insert(items, item)
      end)
      assert.are.equal(1, #items)

      return {
        assert_result = function()
          assert.are.equal("my_fn", items[1].item.name)
        end,
        select_default = function()
          local closed = false
          opts.confirm({
            close = function()
              closed = true
            end,
          }, items[1])
          assert.is_true(closed)
        end,
      }
    end,
    prepare_hotspots = function(state, picker)
      picker.hotspots({})
      local opts = state.snacks_picker_calls[1]
      assert.is_table(opts)
      assert.is_table(opts.items)
      assert.are.equal(1, #opts.items)

      return {
        assert_result = function()
          assert.are.equal(state.source_path, opts.items[1].file)
          assert.are.equal(state.source_uri, opts.items[1].hotspot_uri)
          assert.are.equal(0.9, opts.items[1].hotspot_score)

          local formatted = opts.format(opts.items[1], nil)
          local text = ""
          for _, seg in ipairs(formatted or {}) do
            text = text .. (seg[1] or "")
          end
          assert.is_true(text:find("(0.90)", 1, true) ~= nil)
        end,
        select_default = function()
          local closed = false
          opts.confirm({
            close = function()
              closed = true
            end,
          }, opts.items[1])
          assert.is_true(closed)
        end,
      }
    end,
  },
  {
    backend = "telescope",
    module_name = "code-shape.picker.telescope",
    stub_module_keys = {
      "telescope",
      "telescope.pickers",
      "telescope.finders",
      "telescope.config",
      "telescope.actions",
      "telescope.actions.state",
    },
    install_stubs = function(state)
      state.telescope_picker_specs = {}
      state.telescope_actions = {}

      package.loaded["telescope"] = {}
      package.loaded["telescope.pickers"] = {
        new = function(_, spec)
          table.insert(state.telescope_picker_specs, spec)
          return {
            find = function() end,
          }
        end,
      }
      package.loaded["telescope.finders"] = {
        new_dynamic = function(spec)
          return spec
        end,
        new_table = function(spec)
          return spec
        end,
      }
      package.loaded["telescope.config"] = {
        values = {
          generic_sorter = function()
            return function() end
          end,
          file_previewer = function()
            return {}
          end,
        },
      }
      package.loaded["telescope.actions"] = {
        close = function() end,
        select_default = {
          replace = function(_, fn)
            state.telescope_actions.default = fn
          end,
        },
        select_horizontal = {
          replace = function(_, fn)
            state.telescope_actions.horizontal = fn
          end,
        },
        select_vertical = {
          replace = function(_, fn)
            state.telescope_actions.vertical = fn
          end,
        },
      }
      package.loaded["telescope.actions.state"] = {
        get_selected_entry = function()
          return state.telescope_selected_entry
        end,
      }
    end,
    prepare_defs = function(state, picker)
      picker.defs({})
      local spec = state.telescope_picker_specs[1]
      assert.is_table(spec)
      assert.is_table(spec.finder)

      local results = spec.finder.fn("my_fn")
      assert.are.equal(1, #results)
      local selected = spec.finder.entry_maker(results[1])
      spec.attach_mappings(0, nil)

      return {
        assert_result = function()
          assert.are.equal("my_fn", results[1].name)
        end,
        select_default = function()
          state.telescope_selected_entry = selected
          state.telescope_actions.default()
        end,
      }
    end,
    prepare_hotspots = function(state, picker)
      picker.hotspots({})
      local spec = state.telescope_picker_specs[1]
      assert.is_table(spec)
      assert.is_table(spec.finder)
      assert.is_table(spec.finder.results)
      assert.are.equal(1, #spec.finder.results)

      local selected = spec.finder.entry_maker(spec.finder.results[1])
      spec.attach_mappings(0, nil)

      return {
        assert_result = function()
          assert.are.equal(state.source_path, selected.path)
        end,
        select_default = function()
          state.telescope_selected_entry = selected
          state.telescope_actions.default()
        end,
      }
    end,
  },
}

for _, adapter in ipairs(adapters) do
  describe("picker backend contract: " .. adapter.backend, function()
    ---@type PickerBackendContractState
    local state
    local original_notify
    local original_wait
    local original_nvim_cmd
    local original_nvim_win_set_cursor
    local saved_modules
    local keys

    before_each(function()
      state = {
        cmd_calls = {},
        cursor_calls = {},
        notifications = {},
        wait_called = false,
        source_uri = vim.uri_from_fname(vim.fn.fnamemodify("lua/code-shape/picker/utils.lua", ":p")),
        source_path = "",
      }
      state.source_path = vim.uri_to_fname(state.source_uri)

      reset_picker_modules()

      keys = module_keys(adapter)
      saved_modules = save_loaded_modules(keys)

      install_common_stubs(state)
      adapter.install_stubs(state)

      original_notify = vim.notify
      original_wait = vim.wait
      original_nvim_cmd = vim.api.nvim_cmd
      original_nvim_win_set_cursor = vim.api.nvim_win_set_cursor

      vim.notify = function(msg, level)
        table.insert(state.notifications, { msg = msg, level = level })
      end

      vim.wait = function()
        state.wait_called = true
        error("vim.wait should not be called from picker backends")
      end

      vim.api.nvim_cmd = function(cmd, opts)
        table.insert(state.cmd_calls, {
          cmd = vim.deepcopy(cmd),
          opts = vim.deepcopy(opts),
        })
      end

      vim.api.nvim_win_set_cursor = function(win, pos)
        table.insert(state.cursor_calls, {
          win = win,
          pos = vim.deepcopy(pos),
        })
      end
    end)

    after_each(function()
      vim.notify = original_notify
      vim.wait = original_wait
      vim.api.nvim_cmd = original_nvim_cmd
      vim.api.nvim_win_set_cursor = original_nvim_win_set_cursor

      restore_loaded_modules(keys, saved_modules)
      reset_picker_modules()
    end)

    it("opens defs selection without vim.wait", function()
      local picker = require(adapter.module_name)
      local action = adapter.prepare_defs(state, picker)

      action.assert_result()
      action.select_default()

      assert.is_false(state.wait_called)
      assert.are.equal(2, #state.cmd_calls)
      assert.are.equal("edit", state.cmd_calls[1].cmd.cmd)
      assert.are.equal(state.source_path, state.cmd_calls[1].cmd.args[1])
      assert.are.same({ 1, 0 }, state.cursor_calls[1].pos)
      assert.is_true(has_centering_cmd(state.cmd_calls))
    end)

    it("opens hotspot selection", function()
      local picker = require(adapter.module_name)
      local action = adapter.prepare_hotspots(state, picker)

      action.assert_result()
      action.select_default()

      assert.are.equal(1, #state.cmd_calls)
      assert.are.equal("edit", state.cmd_calls[1].cmd.cmd)
      assert.are.equal(state.source_path, state.cmd_calls[1].cmd.args[1])
    end)

    it("provides calls guidance notification", function()
      local picker = require(adapter.module_name)

      picker.calls({})

      assert.are.equal(1, #state.notifications)
      assert.are.equal(vim.log.levels.INFO, state.notifications[1].level)
      assert.is_true(state.notifications[1].msg:find("Calls mode", 1, true) ~= nil)
    end)
  end)
end
