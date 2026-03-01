describe("ui.actions LSP requests", function()
  local ui_state = require("code-shape.ui.state")
  local original_get_clients
  local original_ui_select
  local original_setqflist
  local original_nvim_cmd
  local original_nvim_win_set_cursor
  local original_buf_request
  local original_notify
  local original_rpc

  local qflist_calls
  local cmd_calls
  local cursor_calls
  local notifications
  local rpc_calls
  local symbol_uri
  local symbol_bufnr

  local function new_actions(item)
    local actions_factory = require("code-shape.ui.actions")
    local state = {
      current_win = nil,
      current_buf = nil,
      preview_win = nil,
      preview_buf = nil,
      current_results = { item },
      selected_idx = 1,
      current_query = "",
      current_config = {
        search = { limit = 20, debounce_ms = 0 },
        metrics = { complexity_cap = 50 },
        keymaps = {},
      },
      is_internal_update = false,
      debounce_timer = nil,
      current_mode = 1,
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

    local actions = actions_factory.new({
      state = state,
      close = function() end,
      render_results = function() end,
      update_preview = function() end,
    })

    return actions, state
  end

  before_each(function()
    qflist_calls = {}
    cmd_calls = {}
    cursor_calls = {}
    notifications = {}
    rpc_calls = {}
    symbol_uri = vim.uri_from_fname(vim.fn.fnamemodify("lua/code-shape/ui/actions.lua", ":p"))
    symbol_bufnr = vim.uri_to_bufnr(symbol_uri)

    original_get_clients = vim.lsp.get_clients
    original_ui_select = vim.ui.select
    original_setqflist = vim.fn.setqflist
    original_nvim_cmd = vim.api.nvim_cmd
    original_nvim_win_set_cursor = vim.api.nvim_win_set_cursor
    original_buf_request = vim.lsp.buf_request
    original_notify = vim.notify
    original_rpc = package.loaded["code-shape.rpc"]

    package.loaded["code-shape.rpc"] = {
      request = function(method, params, cb)
        table.insert(rpc_calls, {
          method = method,
          params = vim.deepcopy(params),
        })
        if cb then
          cb(nil, { success = true })
        end
      end,
    }

    vim.fn.setqflist = function(items, action, opts)
      table.insert(qflist_calls, {
        items = items,
        action = action,
        opts = opts,
      })
    end

    vim.api.nvim_cmd = function(cmd, opts)
      table.insert(cmd_calls, {
        cmd = cmd,
        opts = opts,
      })
    end

    vim.api.nvim_win_set_cursor = function(winid, pos)
      table.insert(cursor_calls, { winid = winid, pos = vim.deepcopy(pos) })
    end

    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.lsp.get_clients = original_get_clients
    vim.ui.select = original_ui_select
    vim.fn.setqflist = original_setqflist
    vim.api.nvim_cmd = original_nvim_cmd
    vim.api.nvim_win_set_cursor = original_nvim_win_set_cursor
    vim.lsp.buf_request = original_buf_request
    vim.notify = original_notify
    package.loaded["code-shape.rpc"] = original_rpc
  end)

  it("show_references uses clients attached to symbol bufnr", function()
    local requested_bufnr = nil
    local get_clients_bufnr = nil

    vim.lsp.get_clients = function(opts)
      get_clients_bufnr = opts and opts.bufnr or nil
      return {
        {
          supports_method = function(method)
            return method == "textDocument/references"
          end,
          request = function(method, params, cb, bufnr)
            requested_bufnr = bufnr
            assert.are.equal("textDocument/references", method)
            assert.are.equal(symbol_uri, params.textDocument.uri)
            cb(nil, {
              {
                uri = symbol_uri,
                range = {
                  start = { line = 3, character = 2 },
                  ["end"] = { line = 3, character = 7 },
                },
              },
            })
          end,
        },
      }
    end

    local actions = new_actions({
      symbol_id = "sym-1",
      name = "target_symbol",
      kind = 12,
      uri = symbol_uri,
      range = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 5 },
      },
      score = 1.0,
    })

    actions.show_references()

    assert.are.equal(symbol_bufnr, get_clients_bufnr)
    assert.are.equal(symbol_bufnr, requested_bufnr)
    assert.are.equal(1, #qflist_calls)
    assert.are.equal("References: target_symbol", qflist_calls[1].opts.title)
    assert.are.equal(1, #qflist_calls[1].items)
    assert.are.equal("copen", cmd_calls[1].cmd.cmd)
  end)

  it("show_calls builds call/reference graph in Calls mode", function()
    local requests = {}

    vim.lsp.get_clients = function(opts)
      assert.are.equal(symbol_bufnr, opts and opts.bufnr)
      return {
        {
          supports_method = function(method)
            return method == "textDocument/prepareCallHierarchy"
              or method == "callHierarchy/incomingCalls"
              or method == "textDocument/references"
          end,
          request = function(method, params, cb, bufnr)
            table.insert(requests, {
              method = method,
              params = params,
              bufnr = bufnr,
            })
            if method == "textDocument/prepareCallHierarchy" then
              cb(nil, {
                uri = symbol_uri,
                name = "target_symbol",
                kind = 12,
                range = {
                  start = { line = 10, character = 0 },
                  ["end"] = { line = 10, character = 5 },
                },
                selectionRange = {
                  start = { line = 10, character = 0 },
                  ["end"] = { line = 10, character = 5 },
                },
              })
              return
            end

            if method == "callHierarchy/incomingCalls" then
              cb(nil, {
                {
                  from = {
                    uri = symbol_uri,
                    name = "caller_fn",
                    kind = 12,
                    range = {
                      start = { line = 20, character = 3 },
                      ["end"] = { line = 20, character = 9 },
                    },
                    selectionRange = {
                      start = { line = 20, character = 3 },
                      ["end"] = { line = 20, character = 9 },
                    },
                    detail = "CallerDetail",
                  },
                  fromRanges = {
                    {
                      start = { line = 20, character = 3 },
                      ["end"] = { line = 20, character = 9 },
                    },
                  },
                },
              })
              return
            end

            if method == "textDocument/references" then
              cb(nil, {
                {
                  uri = symbol_uri,
                  range = {
                    start = { line = 30, character = 1 },
                    ["end"] = { line = 30, character = 6 },
                  },
                },
              })
            end
          end,
        },
      }
    end

    local actions, state = new_actions({
      symbol_id = "sym-2",
      name = "target_symbol",
      kind = 12,
      uri = symbol_uri,
      range = {
        start = { line = 10, character = 0 },
        ["end"] = { line = 10, character = 5 },
      },
      score = 1.0,
    })

    actions.show_calls()

    assert.are.equal(ui_state.MODE_CALLS, state.current_mode)
    assert.is_not_nil(state.calls_graph)
    assert.are.equal("target_symbol", state.calls_graph.center.name)
    assert.are.equal(1, #state.calls_graph.incoming)
    assert.are.equal("caller_fn", state.calls_graph.incoming[1].name)
    assert.are.equal(1, #state.calls_graph.references)

    assert.are.equal("textDocument/prepareCallHierarchy", requests[1].method)
    assert.are.equal("callHierarchy/incomingCalls", requests[2].method)
    assert.are.equal("textDocument/references", requests[3].method)
    assert.are.equal(1, #rpc_calls)
    assert.are.equal("graph/upsertEdges", rpc_calls[1].method)
  end)

  it("goto_definition degrades safely when selected symbol URI is non-file", function()
    local buf_request_called = false
    vim.lsp.buf_request = function(_, _, _, _)
      buf_request_called = true
    end

    local actions = new_actions({
      symbol_id = "sym-non-file",
      name = "target_symbol",
      kind = 12,
      uri = "jdt://workspace/Foo",
      range = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 5 },
      },
      score = 1.0,
    })

    actions.goto_definition()

    assert.is_false(buf_request_called)
    assert.are.equal(0, #cmd_calls)
    assert.are.equal(0, #cursor_calls)
    assert.are.equal("code-shape: Cannot open non-file URI", notifications[1].msg)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
  end)

  it("goto_definition skips non-file definition target URI", function()
    vim.lsp.buf_request = function(_, _, _, cb)
      cb(nil, {
        uri = "jdt://workspace/Foo",
        range = {
          start = { line = 10, character = 2 },
          ["end"] = { line = 10, character = 7 },
        },
      })
    end

    local actions = new_actions({
      symbol_id = "sym-3",
      name = "target_symbol",
      kind = 12,
      uri = symbol_uri,
      range = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 5 },
      },
      score = 1.0,
    })

    actions.goto_definition()

    assert.are.equal(1, #cmd_calls)
    assert.are.equal("edit", cmd_calls[1].cmd.cmd)
    assert.are.equal(vim.uri_to_fname(symbol_uri), cmd_calls[1].cmd.args[1])
    assert.are.equal(1, #cursor_calls)
    assert.are.equal("code-shape: definition target is not a file URI", notifications[1].msg)
    assert.are.equal(vim.log.levels.INFO, notifications[1].level)
  end)

  it("show_references filters non-file URIs", function()
    vim.lsp.get_clients = function(opts)
      assert.are.equal(symbol_bufnr, opts and opts.bufnr)
      return {
        {
          supports_method = function(method)
            return method == "textDocument/references"
          end,
          request = function(_, _, cb, _)
            cb(nil, {
              {
                uri = "jdt://workspace/Foo",
                range = {
                  start = { line = 3, character = 2 },
                  ["end"] = { line = 3, character = 7 },
                },
              },
              {
                uri = symbol_uri,
                range = {
                  start = { line = 5, character = 1 },
                  ["end"] = { line = 5, character = 4 },
                },
              },
            })
          end,
        },
      }
    end

    local actions = new_actions({
      symbol_id = "sym-4",
      name = "target_symbol",
      kind = 12,
      uri = symbol_uri,
      range = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 5 },
      },
      score = 1.0,
    })

    actions.show_references()

    assert.are.equal(1, #qflist_calls)
    assert.are.equal(1, #qflist_calls[1].items)
    assert.are.equal(vim.uri_to_fname(symbol_uri), qflist_calls[1].items[1].filename)
    assert.are.equal("copen", cmd_calls[1].cmd.cmd)
  end)
end)
