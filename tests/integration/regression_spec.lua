local config = require("code-shape.config")

describe("regression integration", function()
  local saved_modules
  local original_get_clients

  ---@param modules string[]
  local function save_modules(modules)
    saved_modules = {}
    for _, name in ipairs(modules) do
      saved_modules[name] = package.loaded[name]
    end
  end

  local function restore_modules()
    if not saved_modules then
      return
    end
    for name, value in pairs(saved_modules) do
      package.loaded[name] = value
    end
    saved_modules = nil
  end

  local function cleanup_ui_artifacts()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local bufnr = vim.api.nvim_win_get_buf(win)
      local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
      if ok and (filetype == "code-shape-impact" or filetype == "code-shape" or filetype == "code-shape-input") then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and (filetype == "code-shape-impact" or filetype == "code-shape" or filetype == "code-shape-input") then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end
  end

  ---@return integer|nil
  local function find_impact_buffer()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and filetype == "code-shape-impact" then
          return bufnr
        end
      end
    end
    return nil
  end

  before_each(function()
    original_get_clients = vim.lsp.get_clients
    cleanup_ui_artifacts()
  end)

  after_each(function()
    restore_modules()
    vim.lsp.get_clients = original_get_clients
    cleanup_ui_artifacts()
  end)

  it("indexer LSP path skips metrics attachment when metrics.enabled=false", function()
    save_modules({
      "code-shape",
      "code-shape.rpc",
      "code-shape.indexer",
    })

    package.loaded["code-shape"] = {
      get_config = function()
        return { metrics = { enabled = false } }
      end,
    }

    local upsert_symbols = nil
    package.loaded["code-shape.rpc"] = {
      request = function(method, params, cb)
        if method == "index/upsertSymbols" then
          upsert_symbols = params.symbols
        end
        if cb then
          cb(nil, { success = true })
        end
      end,
    }

    package.loaded["code-shape.indexer"] = nil
    local indexer = require("code-shape.indexer")

    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local function no_metrics() return 1 end" }, tmp)
    local bufnr = vim.fn.bufadd(tmp)
    vim.fn.bufload(bufnr)
    vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })

    vim.lsp.get_clients = function()
      return {
        {
          server_capabilities = { documentSymbolProvider = true },
          request = function(_self, _method, _params, cb)
            cb(nil, {
              {
                name = "no_metrics",
                kind = 12,
                range = {
                  start = { line = 0, character = 0 },
                  ["end"] = { line = 0, character = 38 },
                },
                selectionRange = {
                  start = { line = 0, character = 15 },
                  ["end"] = { line = 0, character = 25 },
                },
              },
            })
          end,
        },
      }
    end

    local result
    indexer.index_buffer(bufnr, function(status, item)
      result = { status = status, item = item }
    end, { immediate = true })

    assert.is_table(result)
    assert.are.equal("indexed", result.status)
    assert.is_table(upsert_symbols)
    assert.are.equal(1, #upsert_symbols)
    assert.is_nil(upsert_symbols[1].metrics)

    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(tmp)
  end)

  it("snacks hotspots passes URI/score fields to formatter", function()
    save_modules({
      "snacks",
      "code-shape",
      "code-shape.hotspots",
      "code-shape.picker.snacks",
    })

    local source_path = vim.fn.fnamemodify("lua/code-shape/ui.lua", ":p")
    local source_uri = vim.uri_from_fname(source_path)
    local picker_opts = nil

    package.loaded["snacks"] = {
      picker = function(opts)
        picker_opts = opts
      end,
    }

    package.loaded["code-shape"] = {
      ensure_setup = function() end,
      get_config = function()
        return {
          search = { limit = 20 },
          metrics = { complexity_cap = 50 },
        }
      end,
    }

    package.loaded["code-shape.hotspots"] = {
      get_top = function()
        return {
          { path = source_uri, score = 0.77 },
        }
      end,
    }

    package.loaded["code-shape.picker.snacks"] = nil
    local picker = require("code-shape.picker.snacks")
    picker.hotspots({})

    assert.is_table(picker_opts)
    assert.is_table(picker_opts.items)
    assert.are.equal(1, #picker_opts.items)
    assert.are.equal(source_uri, picker_opts.items[1].hotspot_uri)
    assert.are.equal(0.77, picker_opts.items[1].hotspot_score)

    local formatted = picker_opts.format(picker_opts.items[1], nil)
    local text = ""
    for _, seg in ipairs(formatted or {}) do
      text = text .. (seg[1] or "")
    end
    assert.is_true(text:find("(0.77)", 1, true) ~= nil)
  end)

  it("open_impact shows --head requires --base validation error", function()
    local ui = require("code-shape.ui")
    local cfg = config.setup({
      ui = { preview = false },
    })

    ui.open_impact(cfg, { head = "feature/foo" })

    local rendered = vim.wait(200, function()
      local bufnr = find_impact_buffer()
      if not bufnr then
        return false
      end
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 2, false)
      return lines[1] and lines[1]:find("--head requires --base", 1, true) ~= nil
    end, 10)

    assert.is_true(rendered)
  end)
end)
