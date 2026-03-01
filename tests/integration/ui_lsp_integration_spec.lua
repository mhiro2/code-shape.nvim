local config = require("code-shape.config")

describe("ui headless LSP integration", function()
  local original_rpc
  local original_hotspots
  local original_get_clients
  local original_ui_select
  local original_setqflist
  local original_nvim_cmd
  local original_keymap_set

  local qflist_calls
  local rpc_calls
  local keymaps
  local symbol_uri
  local symbol_bufnr

  local function reset_ui_modules()
    package.loaded["code-shape.ui"] = nil
    package.loaded["code-shape.ui.actions"] = nil
    package.loaded["code-shape.ui.actions.shared"] = nil
    package.loaded["code-shape.ui.actions.calls_graph"] = nil
    package.loaded["code-shape.ui.actions.lsp"] = nil
    package.loaded["code-shape.ui.actions.keymaps"] = nil
    package.loaded["code-shape.ui.render"] = nil
    package.loaded["code-shape.ui.state"] = nil
    package.loaded["code-shape.ui.input"] = nil
  end

  local function cleanup_ui_artifacts()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local bufnr = vim.api.nvim_win_get_buf(win)
      local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
      if ok and (filetype == "code-shape" or filetype == "code-shape-input" or filetype == "code-shape-preview") then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and (filetype == "code-shape" or filetype == "code-shape-input" or filetype == "code-shape-preview") then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end
  end

  ---@return integer|nil
  local function find_main_ui_buffer()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and filetype == "code-shape" then
          return bufnr
        end
      end
    end
    return nil
  end

  ---@return integer|nil
  local function find_input_buffer()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and filetype == "code-shape-input" then
          return bufnr
        end
      end
    end
    return nil
  end

  ---@param line_count integer
  ---@return string[]
  local function get_main_ui_lines(line_count)
    local bufnr = find_main_ui_buffer()
    assert.is_not_nil(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, line_count, false)
  end

  ---@param lines string[]
  ---@param pattern string
  ---@return boolean
  local function has_line_contains(lines, pattern)
    for _, line in ipairs(lines) do
      if line:find(pattern, 1, true) ~= nil then
        return true
      end
    end
    return false
  end

  ---@param query string
  local function open_ui_with_query(query)
    local ui = require("code-shape.ui")
    local cfg = config.setup({
      ui = { preview = false },
      search = { debounce_ms = 0, limit = 20 },
    })
    ui.open(cfg)

    -- Set query in the separate input buffer with prompt prefix
    local input_bufnr = find_input_buffer()
    assert.is_not_nil(input_bufnr)
    vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, { "> " .. query })

    -- Wait for results in the results buffer
    local results_bufnr = find_main_ui_buffer()
    assert.is_not_nil(results_bufnr)

    local ok = vim.wait(200, function()
      local lines = vim.api.nvim_buf_get_lines(results_bufnr, 0, 4, false)
      -- Results are now on line 2 (after header on line 1)
      return lines[2] and lines[2]:find("target_symbol", 1, true) ~= nil
    end, 10)
    assert.is_true(ok)
  end

  before_each(function()
    cleanup_ui_artifacts()
    reset_ui_modules()

    qflist_calls = {}
    rpc_calls = {}
    keymaps = {}
    symbol_uri = vim.uri_from_fname(vim.fn.fnamemodify("lua/code-shape/ui/actions.lua", ":p"))
    symbol_bufnr = vim.uri_to_bufnr(symbol_uri)

    original_rpc = package.loaded["code-shape.rpc"]
    original_hotspots = package.loaded["code-shape.hotspots"]
    original_get_clients = vim.lsp.get_clients
    original_ui_select = vim.ui.select
    original_setqflist = vim.fn.setqflist
    original_nvim_cmd = vim.api.nvim_cmd
    original_keymap_set = vim.keymap.set

    package.loaded["code-shape.rpc"] = {
      request = function(method, _params, cb)
        table.insert(rpc_calls, method)
        if method == "search/query" then
          cb(nil, {
            symbols = {
              {
                symbol_id = "sym-target",
                name = "target_symbol",
                kind = 12,
                container_name = "M",
                uri = symbol_uri,
                range = {
                  start = { line = 0, character = 0 },
                  ["end"] = { line = 0, character = 10 },
                },
                detail = nil,
                score = 1.0,
              },
            },
          })
          return
        end
        cb(nil, { success = true })
      end,
    }

    package.loaded["code-shape.hotspots"] = {
      get_top = function()
        return {}
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
      if cmd and cmd.cmd == "copen" then
        return
      end
      return original_nvim_cmd(cmd, opts)
    end

    vim.keymap.set = function(mode, lhs, rhs, _opts)
      keymaps[tostring(mode) .. ":" .. lhs] = rhs
    end
  end)

  after_each(function()
    cleanup_ui_artifacts()
    reset_ui_modules()

    package.loaded["code-shape.rpc"] = original_rpc
    package.loaded["code-shape.hotspots"] = original_hotspots
    vim.lsp.get_clients = original_get_clients
    vim.ui.select = original_ui_select
    vim.fn.setqflist = original_setqflist
    vim.api.nvim_cmd = original_nvim_cmd
    vim.keymap.set = original_keymap_set
  end)

  it("uses target symbol bufnr for gr references", function()
    local observed_client_bufnr = nil
    local observed_request_bufnr = nil

    vim.lsp.get_clients = function(opts)
      observed_client_bufnr = opts and opts.bufnr or nil
      return {
        {
          supports_method = function(method)
            return method == "textDocument/references"
          end,
          request = function(_, _, cb, bufnr)
            observed_request_bufnr = bufnr
            cb(nil, {
              {
                uri = symbol_uri,
                range = {
                  start = { line = 2, character = 1 },
                  ["end"] = { line = 2, character = 4 },
                },
              },
            })
          end,
        },
      }
    end

    open_ui_with_query("target_symbol")
    assert.is_function(keymaps["n:gr"])
    keymaps["n:gr"]()

    assert.are.equal(1, #qflist_calls)
    assert.are.equal(symbol_bufnr, observed_client_bufnr)
    assert.are.equal(symbol_bufnr, observed_request_bufnr)
    assert.are.equal("References: target_symbol", qflist_calls[1].opts.title)
  end)

  it("gc switches to Calls mode and renders graph sections", function()
    vim.lsp.get_clients = function(opts)
      assert.are.equal(symbol_bufnr, opts and opts.bufnr)
      return {
        {
          supports_method = function(method)
            return method == "textDocument/prepareCallHierarchy"
              or method == "callHierarchy/incomingCalls"
              or method == "textDocument/references"
          end,
          request = function(method, _params, cb)
            if method == "textDocument/prepareCallHierarchy" then
              cb(nil, {
                uri = symbol_uri,
                name = "target_symbol",
                kind = 12,
                range = {
                  start = { line = 0, character = 0 },
                  ["end"] = { line = 0, character = 10 },
                },
                selectionRange = {
                  start = { line = 0, character = 0 },
                  ["end"] = { line = 0, character = 10 },
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
                      start = { line = 7, character = 2 },
                      ["end"] = { line = 7, character = 6 },
                    },
                    selectionRange = {
                      start = { line = 7, character = 2 },
                      ["end"] = { line = 7, character = 6 },
                    },
                  },
                  fromRanges = {
                    {
                      start = { line = 7, character = 2 },
                      ["end"] = { line = 7, character = 6 },
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
                    start = { line = 11, character = 1 },
                    ["end"] = { line = 11, character = 5 },
                  },
                },
              })
            end
          end,
        },
      }
    end

    open_ui_with_query("target_symbol")
    assert.is_function(keymaps["n:gc"])
    keymaps["n:gc"]()

    local rendered = vim.wait(200, function()
      local lines = get_main_ui_lines(20)
      return lines[1]
        and lines[1]:find("%[Calls%]") ~= nil
        and has_line_contains(lines, "Callers (1)")
        and has_line_contains(lines, "caller_fn")
    end, 10)
    assert.is_true(rendered)
    assert.is_true(vim.tbl_contains(rpc_calls, "graph/upsertEdges"))
  end)

  it("supports l/h graph navigation in Calls mode", function()
    vim.lsp.get_clients = function(opts)
      assert.are.equal(symbol_bufnr, opts and opts.bufnr)
      return {
        {
          supports_method = function(method)
            return method == "textDocument/prepareCallHierarchy"
              or method == "callHierarchy/incomingCalls"
              or method == "textDocument/references"
          end,
          request = function(method, params, cb)
            if method == "textDocument/prepareCallHierarchy" then
              local line = params.position.line
              if line == 0 then
                cb(nil, {
                  uri = symbol_uri,
                  name = "target_symbol",
                  kind = 12,
                  range = {
                    start = { line = 0, character = 0 },
                    ["end"] = { line = 0, character = 10 },
                  },
                  selectionRange = {
                    start = { line = 0, character = 0 },
                    ["end"] = { line = 0, character = 10 },
                  },
                })
              else
                cb(nil, {
                  uri = symbol_uri,
                  name = "caller_fn",
                  kind = 12,
                  range = {
                    start = { line = 7, character = 2 },
                    ["end"] = { line = 7, character = 6 },
                  },
                  selectionRange = {
                    start = { line = 7, character = 2 },
                    ["end"] = { line = 7, character = 6 },
                  },
                })
              end
              return
            end

            if method == "callHierarchy/incomingCalls" then
              local center_line = params.item.selectionRange.start.line
              if center_line == 0 then
                cb(nil, {
                  {
                    from = {
                      uri = symbol_uri,
                      name = "caller_fn",
                      kind = 12,
                      range = {
                        start = { line = 7, character = 2 },
                        ["end"] = { line = 7, character = 6 },
                      },
                      selectionRange = {
                        start = { line = 7, character = 2 },
                        ["end"] = { line = 7, character = 6 },
                      },
                    },
                    fromRanges = {
                      {
                        start = { line = 7, character = 2 },
                        ["end"] = { line = 7, character = 6 },
                      },
                    },
                  },
                })
              else
                cb(nil, {
                  {
                    from = {
                      uri = symbol_uri,
                      name = "root_fn",
                      kind = 12,
                      range = {
                        start = { line = 2, character = 0 },
                        ["end"] = { line = 2, character = 5 },
                      },
                      selectionRange = {
                        start = { line = 2, character = 0 },
                        ["end"] = { line = 2, character = 5 },
                      },
                    },
                    fromRanges = {
                      {
                        start = { line = 2, character = 0 },
                        ["end"] = { line = 2, character = 5 },
                      },
                    },
                  },
                })
              end
              return
            end

            if method == "textDocument/references" then
              cb(nil, {})
            end
          end,
        },
      }
    end

    open_ui_with_query("target_symbol")
    keymaps["n:gc"]()

    local first_graph_ready = vim.wait(200, function()
      local lines = get_main_ui_lines(20)
      return has_line_contains(lines, "Callers (1)") and has_line_contains(lines, "caller_fn")
    end, 10)
    assert.is_true(first_graph_ready)

    keymaps["n:j"]()
    keymaps["n:l"]()

    local followed = vim.wait(200, function()
      local lines = get_main_ui_lines(20)
      return has_line_contains(lines, "target_symbol > caller_fn")
    end, 10)
    assert.is_true(followed)

    keymaps["n:h"]()

    local backed = vim.wait(200, function()
      local lines = get_main_ui_lines(20)
      return has_line_contains(lines, "Path") and has_line_contains(lines, "target_symbol")
    end, 10)
    assert.is_true(backed)
  end)
end)
