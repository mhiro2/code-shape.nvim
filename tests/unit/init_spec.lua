describe("code-shape", function()
  local original_notify
  local original_nvim_get_current_buf
  local original_nvim_create_augroup
  local original_nvim_create_autocmd
  local original_nvim_list_bufs
  local original_nvim_buf_is_loaded
  local original_defer_fn
  local original_uv_now

  local notifications
  local state
  local saved_modules

  local stubbed_module_names = {
    "code-shape",
    "code-shape.config",
    "code-shape.rpc",
    "code-shape.util",
    "code-shape.indexer",
    "code-shape.ui",
    "code-shape.hotspots",
    "code-shape.snapshot",
    "code-shape.roots",
    "code-shape.highlight",
    "code-shape.picker",
  }

  ---@return table
  local function make_base_config()
    return {
      search = { limit = 50 },
      metrics = { complexity_cap = 50 },
      hotspots = { enabled = false },
      picker = nil,
      debug = false,
    }
  end

  local function install_module_stubs()
    saved_modules = {}
    for _, name in ipairs(stubbed_module_names) do
      saved_modules[name] = package.loaded[name]
    end

    package.loaded["code-shape.config"] = {
      setup = function(opts)
        table.insert(state.config_setup_calls, vim.deepcopy(opts))
        return vim.tbl_deep_extend("force", make_base_config(), vim.deepcopy(opts or {}))
      end,
    }

    package.loaded["code-shape.rpc"] = {
      start = function()
        state.rpc_start_calls = state.rpc_start_calls + 1
      end,
      stop = function()
        state.rpc_stop_calls = state.rpc_stop_calls + 1
      end,
      on_notification = function(method, cb)
        state.rpc_notification_handlers[method] = cb
      end,
      request = function(method, params, cb, opts)
        table.insert(state.rpc_requests, {
          method = method,
          params = vim.deepcopy(params),
          opts = vim.deepcopy(opts),
        })
        local handler = state.rpc_handlers[method]
        if handler then
          handler(params, cb, opts)
          return
        end
        if cb then
          cb(nil, {})
        end
      end,
    }

    package.loaded["code-shape.util"] = {
      tbl_deep_merge = function(base, opts)
        return vim.tbl_deep_extend("force", vim.deepcopy(base), vim.deepcopy(opts))
      end,
      fname_to_file_uri = function(path)
        return vim.uri_from_fname(path)
      end,
    }

    package.loaded["code-shape.indexer"] = {
      should_index = function(bufnr)
        if state.should_index_fn then
          return state.should_index_fn(bufnr)
        end
        return false
      end,
      index_buffer = function(bufnr, cb, opts)
        table.insert(state.indexed_buffers, bufnr)
        table.insert(state.index_buffer_calls, { bufnr = bufnr, opts = vim.deepcopy(opts) })
        if state.index_buffer_handler then
          state.index_buffer_handler(bufnr, cb, opts)
          return
        end
        if cb then
          cb("indexed", {
            status = "indexed",
            symbol_count = 1,
            method = "lsp",
            error = nil,
            bufnr = bufnr,
            uri = string.format("file:///tmp/%d.lua", bufnr),
          })
        end
      end,
      cleanup_buffer = function(bufnr)
        table.insert(state.cleaned_buffers, bufnr)
      end,
      index_workspace = function(cb, opts)
        table.insert(state.index_workspace_calls, { opts = vim.deepcopy(opts) })
        if state.index_workspace_handler then
          state.index_workspace_handler(cb, opts)
          return
        end
        if cb then
          cb(nil, nil)
        end
      end,
      reindex_all = function(cb, opts)
        state.reindex_calls = state.reindex_calls + 1
        table.insert(state.reindex_all_calls, { opts = vim.deepcopy(opts) })
        if state.reindex_all_handler then
          state.reindex_all_handler(cb, opts)
          return
        end
        if cb then
          cb({
            target_count = 0,
            indexed_count = 0,
            empty_count = 0,
            failed_count = 0,
            skipped_count = 0,
          })
        end
      end,
      reset_workspace_indexed = function()
        state.reset_workspace_calls = state.reset_workspace_calls + 1
      end,
      clear_all = function()
        state.clear_calls = state.clear_calls + 1
      end,
      cancel_workspace_index = function()
        return state.cancel_workspace_result
      end,
    }

    package.loaded["code-shape.ui"] = {
      open = function(cfg)
        table.insert(state.ui_open_configs, vim.deepcopy(cfg))
      end,
      open_hotspots = function(cfg)
        table.insert(state.ui_open_hotspots_configs, vim.deepcopy(cfg))
      end,
    }

    package.loaded["code-shape.hotspots"] = {
      calculate = function(opts, cb)
        table.insert(state.hotspot_calculate_calls, vim.deepcopy(opts))
        if cb then
          cb()
        end
      end,
      reset = function()
        state.hotspot_reset_calls = state.hotspot_reset_calls + 1
      end,
    }

    package.loaded["code-shape.snapshot"] = {
      load = function(_rpc, cfg)
        table.insert(state.snapshot_load_configs, vim.deepcopy(cfg))
      end,
      save = function(_rpc, cfg, cb)
        table.insert(state.snapshot_save_configs, vim.deepcopy(cfg))
        if cb then
          cb()
        end
      end,
    }

    package.loaded["code-shape.roots"] = {
      get_roots = function()
        return vim.deepcopy(state.active_roots)
      end,
      clear = function()
        state.roots_clear_calls = state.roots_clear_calls + 1
      end,
    }

    package.loaded["code-shape.picker"] = {
      open = function(mode, opts)
        table.insert(state.picker_open_calls, { mode = mode, opts = vim.deepcopy(opts) })
        return state.picker_open_result
      end,
    }

    package.loaded["code-shape.highlight"] = {
      setup = function()
        state.highlight_setup_calls = state.highlight_setup_calls + 1
      end,
    }
  end

  local function restore_module_stubs()
    for _, name in ipairs(stubbed_module_names) do
      package.loaded[name] = saved_modules[name]
    end
  end

  local function load_code_shape()
    package.loaded["code-shape"] = nil
    return require("code-shape")
  end

  before_each(function()
    state = {
      current_buf = 1,
      list_bufs = {},
      loaded_bufs = {},
      active_roots = {},
      config_setup_calls = {},
      rpc_start_calls = 0,
      rpc_stop_calls = 0,
      rpc_requests = {},
      rpc_handlers = {},
      rpc_notification_handlers = {},
      indexed_buffers = {},
      index_buffer_calls = {},
      cleaned_buffers = {},
      index_workspace_calls = {},
      reindex_calls = 0,
      reindex_all_calls = {},
      reset_workspace_calls = 0,
      clear_calls = 0,
      cancel_workspace_result = false,
      should_index_fn = nil,
      index_buffer_handler = nil,
      index_workspace_handler = nil,
      reindex_all_handler = nil,
      ui_open_configs = {},
      ui_open_hotspots_configs = {},
      hotspot_calculate_calls = {},
      hotspot_reset_calls = 0,
      snapshot_load_configs = {},
      snapshot_save_configs = {},
      roots_clear_calls = 0,
      picker_open_calls = {},
      picker_open_result = nil,
      autocmd_defs = {},
      defer_calls = {},
      highlight_setup_calls = 0,
      now_ms = 0,
    }
    notifications = {}

    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    original_nvim_get_current_buf = vim.api.nvim_get_current_buf
    original_nvim_create_augroup = vim.api.nvim_create_augroup
    original_nvim_create_autocmd = vim.api.nvim_create_autocmd
    original_nvim_list_bufs = vim.api.nvim_list_bufs
    original_nvim_buf_is_loaded = vim.api.nvim_buf_is_loaded
    original_defer_fn = vim.defer_fn
    original_uv_now = vim.uv.now

    vim.api.nvim_get_current_buf = function()
      return state.current_buf
    end
    vim.api.nvim_create_augroup = function(_name, _opts)
      return 100
    end
    vim.api.nvim_create_autocmd = function(event, opts)
      table.insert(state.autocmd_defs, { event = event, opts = opts })
      return #state.autocmd_defs
    end
    vim.api.nvim_list_bufs = function()
      return vim.deepcopy(state.list_bufs)
    end
    vim.api.nvim_buf_is_loaded = function(bufnr)
      return state.loaded_bufs[bufnr] == true
    end
    vim.defer_fn = function(fn, ms)
      table.insert(state.defer_calls, { fn = fn, ms = ms })
    end
    vim.uv.now = function()
      return state.now_ms
    end

    install_module_stubs()
  end)

  after_each(function()
    restore_module_stubs()

    vim.notify = original_notify
    vim.api.nvim_get_current_buf = original_nvim_get_current_buf
    vim.api.nvim_create_augroup = original_nvim_create_augroup
    vim.api.nvim_create_autocmd = original_nvim_create_autocmd
    vim.api.nvim_list_bufs = original_nvim_list_bufs
    vim.api.nvim_buf_is_loaded = original_nvim_buf_is_loaded
    vim.defer_fn = original_defer_fn
    vim.uv.now = original_uv_now
  end)

  describe("module structure", function()
    it("exports expected public functions", function()
      local code_shape = load_code_shape()
      local expected = {
        "setup",
        "open",
        "search",
        "stats",
        "index_open_buffers",
        "reindex",
        "clear",
        "cancel_workspace_index",
        "status",
        "show_hotspots",
        "ensure_setup",
        "get_config",
      }

      for _, key in ipairs(expected) do
        assert.is_function(code_shape[key])
      end
    end)
  end)

  describe("setup", function()
    it("defers initial hotspot calculation until idle", function()
      local code_shape = load_code_shape()
      code_shape.setup({ hotspots = { enabled = true } })

      assert.are.equal(1, state.highlight_setup_calls)
      assert.are.equal("ColorScheme", state.autocmd_defs[4].event)
      assert.are.equal(1, #state.defer_calls)
      assert.are.equal(300, state.defer_calls[1].ms)
      assert.are.equal(0, #state.hotspot_calculate_calls)

      state.defer_calls[1].fn()

      assert.are.equal(1, #state.hotspot_calculate_calls)
      assert.is_true(state.hotspot_calculate_calls[1].enabled)
    end)
  end)

  describe("error handling", function()
    it("clear resets hotspot caches in Lua and Rust core", function()
      local code_shape = load_code_shape()
      code_shape.clear()

      assert.are.equal(1, state.clear_calls)
      assert.are.equal(1, state.hotspot_reset_calls)
      assert.are.equal(1, state.roots_clear_calls)
      assert.are.equal("code-shape: index cleared", notifications[1].msg)
      assert.are.equal(vim.log.levels.INFO, notifications[1].level)
    end)

    it("notifies error when status request fails", function()
      state.rpc_handlers["index/stats"] = function(_, cb)
        cb("core unreachable", nil)
      end

      local code_shape = load_code_shape()
      code_shape.status()

      assert.are.equal("index/stats", state.rpc_requests[1].method)
      assert.are.equal("code-shape: core unreachable", notifications[1].msg)
      assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    end)

    it("notifies error when single-root status response is invalid", function()
      state.rpc_handlers["index/stats"] = function(_, cb)
        cb(nil, "invalid-response")
      end

      local code_shape = load_code_shape()
      code_shape.status()

      assert.are.equal("index/stats", state.rpc_requests[1].method)
      assert.are.equal("code-shape: invalid response from core", notifications[1].msg)
      assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    end)

    it("notifies error when multi-root status response is invalid", function()
      state.active_roots = { "/tmp/work-a", "/tmp/work-b" }
      state.rpc_handlers["index/statsByRoot"] = function(_, cb)
        cb(nil, "invalid-response")
      end

      local code_shape = load_code_shape()
      code_shape.status()

      assert.are.equal("index/statsByRoot", state.rpc_requests[1].method)
      assert.are.equal(2, #state.rpc_requests[1].params.roots)
      assert.are.equal("code-shape: invalid response from core", notifications[1].msg)
      assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    end)

    it("notifies debug message when no workspace indexing is running", function()
      state.cancel_workspace_result = false

      local code_shape = load_code_shape()
      code_shape.cancel_workspace_index()

      assert.are.equal("code-shape: no workspace indexing in progress", notifications[1].msg)
      assert.are.equal(vim.log.levels.DEBUG, notifications[1].level)
    end)

    it("notifies debug message when workspace indexing fails", function()
      state.current_buf = 99
      state.list_bufs = { 10, 11 }
      state.loaded_bufs[10] = true
      state.loaded_bufs[11] = false
      state.should_index_fn = function(bufnr)
        return bufnr ~= state.current_buf
      end
      state.index_workspace_handler = function(cb)
        cb("timeout", nil)
      end

      local code_shape = load_code_shape()
      code_shape.index_open_buffers()

      assert.are.same({ 10 }, state.indexed_buffers)
      assert.are.equal(1, #state.index_buffer_calls)
      assert.is_true(state.index_buffer_calls[1].opts.immediate)
      assert.are.equal(1, #state.index_workspace_calls)
      assert.are.equal("code-shape: indexing started (CodeShapeIndex)", notifications[1].msg)
      assert.are.equal(vim.log.levels.INFO, notifications[1].level)
      assert.are.equal("code-shape: indexed 1/1 buffers (empty: 0, failed: 0)", notifications[2].msg)
      assert.are.equal(vim.log.levels.INFO, notifications[2].level)
      assert.are.equal("code-shape: workspace index: timeout", notifications[3].msg)
      assert.are.equal(vim.log.levels.DEBUG, notifications[3].level)

      assert.are.equal(5000, state.defer_calls[1].ms)
      state.defer_calls[1].fn()
      assert.are.equal(3, #notifications)
    end)

    it("shows delayed progress updates for long-running manual indexing", function()
      local pending_workspace_callback
      local stats_calls = 0

      state.current_buf = 99
      state.list_bufs = { 10 }
      state.loaded_bufs[10] = true
      state.should_index_fn = function(bufnr)
        return bufnr == 10
      end
      state.index_workspace_handler = function(cb)
        pending_workspace_callback = cb
      end
      state.rpc_handlers["index/stats"] = function(_, cb)
        stats_calls = stats_calls + 1
        if stats_calls == 1 then
          cb(nil, { symbol_count = 100 })
        else
          cb(nil, { symbol_count = 125 })
        end
      end

      local code_shape = load_code_shape()
      code_shape.index_open_buffers()

      assert.are.equal("code-shape: indexing started (CodeShapeIndex)", notifications[1].msg)
      assert.are.equal(5000, state.defer_calls[1].ms)

      state.defer_calls[1].fn()

      assert.are.equal("code-shape: indexing in progress... 125 symbols (+25)", notifications[2].msg)
      assert.are.equal(vim.log.levels.INFO, notifications[2].level)
      assert.are.equal(3000, state.defer_calls[2].ms)

      pending_workspace_callback(nil, { symbol_count = 30 })
      assert.are.equal(
        "code-shape: indexed 1/1 buffers (empty: 0, failed: 0), 30 workspace symbols",
        notifications[3].msg
      )

      state.defer_calls[2].fn()
      assert.are.equal(3, #notifications)
    end)

    it("throttles unchanged progress updates and emits heartbeat", function()
      local pending_workspace_callback
      local stats_calls = 0

      state.current_buf = 99
      state.list_bufs = { 10 }
      state.loaded_bufs[10] = true
      state.should_index_fn = function(bufnr)
        return bufnr == 10
      end
      state.index_workspace_handler = function(cb)
        pending_workspace_callback = cb
      end
      state.rpc_handlers["index/stats"] = function(_, cb)
        stats_calls = stats_calls + 1
        if stats_calls == 1 then
          cb(nil, { symbol_count = 100 })
          return
        end
        cb(nil, { symbol_count = 130 })
      end

      local code_shape = load_code_shape()
      code_shape.index_open_buffers()

      assert.are.equal("code-shape: indexing started (CodeShapeIndex)", notifications[1].msg)
      assert.are.equal(5000, state.defer_calls[1].ms)

      state.now_ms = 6000
      state.defer_calls[1].fn()
      assert.are.equal("code-shape: indexing in progress... 130 symbols (+30)", notifications[2].msg)
      assert.are.equal(3000, state.defer_calls[2].ms)

      state.now_ms = 9000
      state.defer_calls[2].fn()
      assert.are.equal(2, #notifications)
      assert.are.equal(3000, state.defer_calls[3].ms)

      state.now_ms = 12000
      state.defer_calls[3].fn()
      assert.are.equal(2, #notifications)
      assert.are.equal(3000, state.defer_calls[4].ms)

      state.now_ms = 15000
      state.defer_calls[4].fn()
      assert.are.equal(2, #notifications)
      assert.are.equal(3000, state.defer_calls[5].ms)

      state.now_ms = 18000
      state.defer_calls[5].fn()
      assert.are.equal("code-shape: indexing still running... 130 symbols (+30)", notifications[3].msg)
      assert.are.equal(vim.log.levels.INFO, notifications[3].level)

      pending_workspace_callback(nil, { symbol_count = 33 })
      assert.are.equal(
        "code-shape: indexed 1/1 buffers (empty: 0, failed: 0), 33 workspace symbols",
        notifications[4].msg
      )
    end)

    it("stops progress notifications when workspace indexing is cancelled", function()
      state.current_buf = 99
      state.list_bufs = { 10 }
      state.loaded_bufs[10] = true
      state.should_index_fn = function(bufnr)
        return bufnr == 10
      end
      state.index_workspace_handler = function(_cb)
        -- Keep indexing pending until cancellation.
      end
      state.cancel_workspace_result = true
      state.rpc_handlers["index/stats"] = function(_, cb)
        cb(nil, { symbol_count = 5 })
      end

      local code_shape = load_code_shape()
      code_shape.index_open_buffers()
      code_shape.cancel_workspace_index()

      assert.are.equal("code-shape: indexing started (CodeShapeIndex)", notifications[1].msg)
      assert.are.equal("code-shape: workspace indexing cancelled", notifications[2].msg)

      state.defer_calls[1].fn()
      assert.are.equal(2, #notifications)
    end)

    it("notifies start and completion for manual reindex", function()
      state.current_buf = 99
      state.should_index_fn = function(_)
        return false
      end
      state.index_workspace_handler = function(cb, opts)
        assert.is_true(opts.restart)
        cb(nil, { symbol_count = 7 })
      end
      state.reindex_all_handler = function(cb, opts)
        assert.is_true(opts.immediate)
        cb({
          target_count = 2,
          indexed_count = 1,
          empty_count = 1,
          failed_count = 0,
          skipped_count = 0,
        })
      end
      state.rpc_handlers["index/stats"] = function(_, cb)
        cb(nil, { symbol_count = 2 })
      end

      local code_shape = load_code_shape()
      code_shape.reindex()

      assert.are.equal(1, state.reindex_calls)
      assert.are.equal(1, #state.reindex_all_calls)
      assert.is_true(state.reindex_all_calls[1].opts.immediate)
      assert.are.equal(1, state.reset_workspace_calls)
      assert.are.equal(1, #state.index_workspace_calls)
      assert.is_true(state.index_workspace_calls[1].opts.restart)
      assert.are.equal("code-shape: indexing started (CodeShapeReindex)", notifications[1].msg)
      assert.are.equal(
        "code-shape: reindexed 1/2 buffers (empty: 1, failed: 0), 7 workspace symbols",
        notifications[2].msg
      )
    end)
  end)

  describe("open_calls_from_cursor SymbolInformation support", function()
    it("exports open_calls_from_cursor function", function()
      local code_shape = load_code_shape()
      assert.is_function(code_shape.open_calls_from_cursor)
    end)
  end)
end)
