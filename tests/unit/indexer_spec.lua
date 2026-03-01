local indexer = require("code-shape.indexer")

describe("indexer", function()
  describe("should_index", function()
    it("returns false for invalid buffer", function()
      assert.is_false(indexer.should_index(-1))
    end)

    it("returns false for special filetypes", function()
      -- Create a scratch buffer
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "NvimTree", { buf = bufnr })

      assert.is_false(indexer.should_index(bufnr))

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("returns false for empty filetype", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "", { buf = bufnr })

      assert.is_false(indexer.should_index(bufnr))

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("returns false for non-empty buftype", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
      vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })

      assert.is_false(indexer.should_index(bufnr))

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("returns true for a real file buffer", function()
      local tmp = vim.fn.tempname() .. ".go"
      vim.fn.writefile({ "package main", "func main() {}" }, tmp)

      local bufnr = vim.fn.bufadd(tmp)
      vim.fn.bufload(bufnr)
      vim.api.nvim_set_option_value("filetype", "go", { buf = bufnr })

      assert.is_true(indexer.should_index(bufnr))

      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.fn.delete(tmp)
    end)
  end)

  describe("module structure", function()
    it("has index_buffer function", function()
      assert.is_function(indexer.index_buffer)
    end)

    it("has cleanup_buffer function", function()
      assert.is_function(indexer.cleanup_buffer)
    end)

    it("has reindex_all function", function()
      assert.is_function(indexer.reindex_all)
    end)

    it("has clear_all function", function()
      assert.is_function(indexer.clear_all)
    end)

    it("has index_workspace function", function()
      assert.is_function(indexer.index_workspace)
    end)

    it("has is_workspace_indexed function", function()
      assert.is_function(indexer.is_workspace_indexed)
    end)

    it("has reset_workspace_indexed function", function()
      assert.is_function(indexer.reset_workspace_indexed)
    end)

    it("has is_workspace_indexing function", function()
      assert.is_function(indexer.is_workspace_indexing)
    end)

    it("has cancel_workspace_index function", function()
      assert.is_function(indexer.cancel_workspace_index)
    end)

    it("has index_with_treesitter function", function()
      assert.is_function(indexer.index_with_treesitter)
    end)
  end)

  describe("batch removal", function()
    local rpc
    local original_request
    local original_list_bufs
    local indexed_uris
    local indexed_buffers
    local original_indexed_uris
    local original_indexed_buffers

    ---@param fn function
    ---@param name string
    ---@return integer|nil idx
    ---@return any value
    local function get_upvalue(fn, name)
      local idx = 1
      while true do
        local upvalue_name, value = debug.getupvalue(fn, idx)
        if not upvalue_name then
          return nil, nil
        end
        if upvalue_name == name then
          return idx, value
        end
        idx = idx + 1
      end
    end

    ---@param target table
    ---@param source table
    local function overwrite_table(target, source)
      for key in pairs(target) do
        target[key] = nil
      end
      for key, value in pairs(source) do
        target[key] = value
      end
    end

    before_each(function()
      rpc = require("code-shape.rpc")
      original_request = rpc.request
      original_list_bufs = vim.api.nvim_list_bufs
      _, indexed_uris = get_upvalue(indexer.reindex_all, "indexed_uris")
      _, indexed_buffers = get_upvalue(indexer.reindex_all, "indexed_buffers")
      original_indexed_uris = vim.deepcopy(indexed_uris or {})
      original_indexed_buffers = vim.deepcopy(indexed_buffers or {})
    end)

    after_each(function()
      rpc.request = original_request
      vim.api.nvim_list_bufs = original_list_bufs
      if indexed_uris then
        overwrite_table(indexed_uris, original_indexed_uris)
      end
      if indexed_buffers then
        overwrite_table(indexed_buffers, original_indexed_buffers)
      end
    end)

    it("reindex_all sends index/removeUris once for tracked URIs", function()
      local calls = {}
      rpc.request = function(method, params, cb)
        table.insert(calls, { method = method, params = params })
        if cb then
          cb(nil, { success = true })
        end
      end
      vim.api.nvim_list_bufs = function()
        return {}
      end

      assert.is_table(indexed_uris)
      assert.is_table(indexed_buffers)
      overwrite_table(indexed_uris, {
        ["file:///a.lua"] = true,
        ["file:///z.lua"] = true,
      })
      overwrite_table(indexed_buffers, {})

      indexer.reindex_all()

      assert.are.equal(1, #calls)
      assert.are.equal("index/removeUris", calls[1].method)
      table.sort(calls[1].params.uris)
      assert.are.same({ "file:///a.lua", "file:///z.lua" }, calls[1].params.uris)
    end)
  end)

  describe("workspace indexing", function()
    local rpc
    local original_get_clients
    local original_request
    local workspace_request_count
    local pending_workspace_request

    ---@param message string|nil
    ---@return boolean
    local function contains_cancel(message)
      return type(message) == "string" and message:find("cancel", 1, true) ~= nil
    end

    before_each(function()
      rpc = require("code-shape.rpc")
      original_get_clients = vim.lsp.get_clients
      original_request = rpc.request
      workspace_request_count = 0
      pending_workspace_request = nil

      indexer.cancel_workspace_index()
      indexer.reset_workspace_indexed()

      rpc.request = function(_method, _params, cb)
        if cb then
          cb(nil, { success = true })
        end
      end
    end)

    after_each(function()
      vim.lsp.get_clients = original_get_clients
      rpc.request = original_request
      indexer.cancel_workspace_index()
      indexer.reset_workspace_indexed()
    end)

    it("is_workspace_indexed returns false initially", function()
      assert.is_false(indexer.is_workspace_indexed())
    end)

    it("reset_workspace_indexed resets the workspace indexed flag", function()
      indexer.reset_workspace_indexed()
      assert.is_false(indexer.is_workspace_indexed())
    end)

    it("index_workspace returns error when no LSP clients", function()
      vim.lsp.get_clients = function()
        return {}
      end

      local err_msg
      indexer.index_workspace(function(err, _result)
        err_msg = err
      end)

      assert.are.equal("No LSP clients available", err_msg)
    end)

    it("coalesces reentry calls while indexing is in progress", function()
      vim.lsp.get_clients = function()
        return {
          {
            server_capabilities = { workspaceSymbolProvider = true },
            request = function(_self, method, _params, cb)
              assert.are.equal("workspace/symbol", method)
              workspace_request_count = workspace_request_count + 1
              pending_workspace_request = cb
            end,
          },
        }
      end

      local first_calls = 0
      local second_calls = 0
      local first_result
      local second_result

      indexer.index_workspace(function(err, result)
        assert.is_nil(err)
        first_calls = first_calls + 1
        first_result = result
      end)
      indexer.index_workspace(function(err, result)
        assert.is_nil(err)
        second_calls = second_calls + 1
        second_result = result
      end)

      assert.are.equal(1, workspace_request_count)
      assert.is_true(indexer.is_workspace_indexing())
      assert.is_function(pending_workspace_request)

      pending_workspace_request(nil, {
        {
          name = "func_a",
          kind = 12,
          location = {
            uri = "file:///tmp/a.lua",
            range = {
              start = { line = 0, character = 0 },
              ["end"] = { line = 0, character = 4 },
            },
          },
        },
      })

      assert.is_false(indexer.is_workspace_indexing())
      assert.are.equal(1, first_calls)
      assert.are.equal(1, second_calls)
      assert.are.equal(1, first_result.symbol_count)
      assert.are.equal(1, second_result.symbol_count)
    end)

    it("cancel_workspace_index stops active run and ignores stale callbacks", function()
      vim.lsp.get_clients = function()
        return {
          {
            server_capabilities = { workspaceSymbolProvider = true },
            request = function(_self, _method, _params, cb)
              pending_workspace_request = cb
            end,
          },
        }
      end

      local callback_count = 0
      local callback_err
      indexer.index_workspace(function(err, _result)
        callback_count = callback_count + 1
        callback_err = err
      end)

      assert.is_true(indexer.is_workspace_indexing())
      assert.is_true(indexer.cancel_workspace_index())
      assert.is_false(indexer.is_workspace_indexing())
      assert.are.equal(1, callback_count)
      assert.is_true(contains_cancel(callback_err))

      pending_workspace_request(nil, {})
      assert.are.equal(1, callback_count)
    end)

    it("restart option cancels current run and starts a new one", function()
      local pending_requests = {}

      vim.lsp.get_clients = function()
        return {
          {
            server_capabilities = { workspaceSymbolProvider = true },
            request = function(_self, _method, _params, cb)
              workspace_request_count = workspace_request_count + 1
              table.insert(pending_requests, cb)
            end,
          },
        }
      end

      local first_err
      local second_result

      indexer.index_workspace(function(err, _result)
        first_err = err
      end)
      indexer.index_workspace(function(err, result)
        assert.is_nil(err)
        second_result = result
      end, { restart = true })

      assert.are.equal(2, workspace_request_count)
      assert.is_true(contains_cancel(first_err))

      pending_requests[1](nil, {})
      assert.is_nil(second_result)

      pending_requests[2](nil, {
        {
          name = "func_b",
          kind = 12,
          location = {
            uri = "file:///tmp/b.lua",
            range = {
              start = { line = 1, character = 0 },
              ["end"] = { line = 1, character = 4 },
            },
          },
        },
      })

      assert.are.equal(1, second_result.symbol_count)
    end)

    it("retries fallback queries when empty query returns no symbols", function()
      local seen_queries = {}

      vim.lsp.get_clients = function()
        return {
          {
            server_capabilities = { workspaceSymbolProvider = true },
            request = function(_self, _method, params, cb)
              table.insert(seen_queries, params.query)
              if params.query == "a" then
                cb(nil, {
                  {
                    name = "alpha_func",
                    kind = 12,
                    location = {
                      uri = "file:///tmp/alpha.lua",
                      range = {
                        start = { line = 0, character = 0 },
                        ["end"] = { line = 0, character = 10 },
                      },
                    },
                  },
                })
              else
                cb(nil, {})
              end
            end,
          },
        }
      end

      local result
      indexer.index_workspace(function(err, workspace_result)
        assert.is_nil(err)
        result = workspace_result
      end)

      assert.are.equal("", seen_queries[1])
      assert.is_true(#seen_queries > 1)
      assert.is_table(result)
      assert.are.equal(1, result.symbol_count)
      assert.is_true(result.fallback_used)
      assert.is_true(result.query_count > 1)
    end)
  end)

  describe("buffer indexing callback", function()
    local rpc
    local original_request
    local original_get_clients

    before_each(function()
      rpc = require("code-shape.rpc")
      original_request = rpc.request
      original_get_clients = vim.lsp.get_clients
    end)

    after_each(function()
      rpc.request = original_request
      vim.lsp.get_clients = original_get_clients
    end)

    it("index_buffer immediate reports indexed result", function()
      local tmp = vim.fn.tempname() .. ".lua"
      vim.fn.writefile({ "local function f() return 1 end" }, tmp)

      local bufnr = vim.fn.bufadd(tmp)
      vim.fn.bufload(bufnr)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })

      vim.lsp.get_clients = function(_opts)
        return {
          {
            server_capabilities = { documentSymbolProvider = true },
            request = function(_self, _method, _params, cb)
              cb(nil, {
                {
                  name = "f",
                  kind = 12,
                  range = {
                    start = { line = 0, character = 0 },
                    ["end"] = { line = 0, character = 28 },
                  },
                  selectionRange = {
                    start = { line = 0, character = 15 },
                    ["end"] = { line = 0, character = 16 },
                  },
                },
              })
            end,
          },
        }
      end

      rpc.request = function(method, params, cb)
        if method == "index/upsertSymbols" then
          assert.are.equal(vim.uri_from_bufnr(bufnr), params.uri)
          assert.are.equal(1, #params.symbols)
        end
        if cb then
          cb(nil, { success = true })
        end
      end

      local status_result
      indexer.index_buffer(bufnr, function(status, result)
        status_result = { status = status, result = result }
      end, { immediate = true })

      assert.is_table(status_result)
      assert.are.equal("indexed", status_result.status)
      assert.are.equal(1, status_result.result.symbol_count)
      assert.are.equal("lsp", status_result.result.method)
      assert.is_nil(status_result.result.error)

      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.fn.delete(tmp)
    end)
  end)

  describe("metrics.enabled gating", function()
    local rpc
    local metrics_mod
    local original_request
    local original_get_clients
    local original_code_shape
    local original_compute_for_range
    local original_compute
    local original_get_parser
    local original_query_parse
    local original_get_node_text

    before_each(function()
      rpc = require("code-shape.rpc")
      metrics_mod = require("code-shape.metrics")
      original_request = rpc.request
      original_get_clients = vim.lsp.get_clients
      original_code_shape = package.loaded["code-shape"]
      original_compute_for_range = metrics_mod.compute_for_range
      original_compute = metrics_mod.compute
      original_get_parser = vim.treesitter.get_parser
      original_query_parse = vim.treesitter.query.parse
      original_get_node_text = vim.treesitter.get_node_text
    end)

    after_each(function()
      rpc.request = original_request
      vim.lsp.get_clients = original_get_clients
      package.loaded["code-shape"] = original_code_shape
      metrics_mod.compute_for_range = original_compute_for_range
      metrics_mod.compute = original_compute
      vim.treesitter.get_parser = original_get_parser
      vim.treesitter.query.parse = original_query_parse
      vim.treesitter.get_node_text = original_get_node_text
    end)

    it("skips LSP metrics attachment when metrics.enabled is false", function()
      local tmp = vim.fn.tempname() .. ".lua"
      vim.fn.writefile({ "local function no_metrics() return 1 end" }, tmp)
      local bufnr = vim.fn.bufadd(tmp)
      vim.fn.bufload(bufnr)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })

      package.loaded["code-shape"] = {
        get_config = function()
          return { metrics = { enabled = false } }
        end,
      }

      local compute_calls = 0
      metrics_mod.compute_for_range = function()
        compute_calls = compute_calls + 1
        return {
          cyclomatic_complexity = 3,
          lines_of_code = 10,
          nesting_depth = 1,
        }
      end

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

      local upsert_symbols = nil
      rpc.request = function(method, params, cb)
        if method == "index/upsertSymbols" then
          upsert_symbols = params.symbols
        end
        if cb then
          cb(nil, { success = true })
        end
      end

      local status_result
      indexer.index_buffer(bufnr, function(status, result)
        status_result = { status = status, result = result }
      end, { immediate = true })

      assert.is_table(status_result)
      assert.are.equal("indexed", status_result.status)
      assert.are.equal(0, compute_calls)
      assert.is_table(upsert_symbols)
      assert.are.equal(1, #upsert_symbols)
      assert.is_nil(upsert_symbols[1].metrics)

      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.fn.delete(tmp)
    end)

    it("skips tree-sitter metrics attachment when metrics.enabled is false", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local function no_metrics() return 1 end" })
      local uri = vim.uri_from_bufnr(bufnr)

      package.loaded["code-shape"] = {
        get_config = function()
          return { metrics = { enabled = false } }
        end,
      }

      local symbol_node = {
        type = function()
          return "function_declaration"
        end,
        range = function()
          return 0, 0, 0, 38
        end,
      }
      local name_node = {}

      local lang = "code_shape_metrics_gate_lang_" .. tostring(vim.uv.hrtime())
      vim.treesitter.get_parser = function()
        return {
          lang = function()
            return lang
          end,
          parse = function()
            return {
              {
                root = function()
                  return {
                    end_ = function()
                      return 0, 0
                    end,
                  }
                end,
              },
            }
          end,
        }
      end

      vim.treesitter.query.parse = function()
        return {
          iter_matches = function()
            local emitted = false
            return function()
              if emitted then
                return nil
              end
              emitted = true
              return 1, { symbol = { symbol_node }, name = { name_node } }, {}
            end
          end,
        }
      end

      vim.treesitter.get_node_text = function()
        return "no_metrics"
      end

      local compute_calls = 0
      metrics_mod.compute = function()
        compute_calls = compute_calls + 1
        return {
          cyclomatic_complexity = 2,
          lines_of_code = 8,
          nesting_depth = 1,
        }
      end

      local upsert_symbols = nil
      rpc.request = function(method, params, cb)
        if method == "index/upsertSymbols" then
          upsert_symbols = params.symbols
        end
        if cb then
          cb(nil, { success = true })
        end
      end

      local status_result
      indexer.index_with_treesitter(bufnr, uri, function(status, result)
        status_result = { status = status, result = result }
      end)

      assert.is_table(status_result)
      assert.are.equal("indexed", status_result.status)
      assert.are.equal(0, compute_calls)
      assert.is_table(upsert_symbols)
      assert.is_true(#upsert_symbols >= 1)
      for _, sym in ipairs(upsert_symbols) do
        assert.is_nil(sym.metrics)
      end

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("tree-sitter fallback", function()
    it("index_with_treesitter handles buffers without tree-sitter parser", function()
      -- Create a buffer with a language that might not have tree-sitter
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "text", { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "plain text content" })

      -- This should not crash even without a tree-sitter parser
      local uri = vim.uri_from_bufnr(bufnr)
      indexer.index_with_treesitter(bufnr, uri)

      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_true(true)
    end)

    it("index_with_treesitter handles empty buffer", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })

      local uri = vim.uri_from_bufnr(bufnr)
      indexer.index_with_treesitter(bufnr, uri)

      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_true(true)
    end)

    it("index_with_treesitter handles lua function", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "local function myTestFunc()",
        "  return 42",
        "end",
      })

      local uri = vim.uri_from_bufnr(bufnr)
      -- This should not crash and may extract the function
      indexer.index_with_treesitter(bufnr, uri)

      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_true(true)
    end)

    it("index_with_treesitter returns safely when parse result is empty", function()
      local original_get_parser = vim.treesitter.get_parser

      vim.treesitter.get_parser = function()
        return {
          parse = function()
            return {}
          end,
        }
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      indexer.index_with_treesitter(bufnr, "file:///tmp/parse-empty.lua")

      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.treesitter.get_parser = original_get_parser
      assert.is_true(true)
    end)

    it("index_with_treesitter returns safely when tree root node is nil", function()
      local original_get_parser = vim.treesitter.get_parser

      vim.treesitter.get_parser = function()
        return {
          parse = function()
            return {
              {
                root = function()
                  return nil
                end,
              },
            }
          end,
        }
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      indexer.index_with_treesitter(bufnr, "file:///tmp/root-nil.lua")

      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.treesitter.get_parser = original_get_parser
      assert.is_true(true)
    end)

    it("index_with_treesitter passes all=true to iter_matches", function()
      local original_get_parser = vim.treesitter.get_parser
      local original_parse = vim.treesitter.query.parse
      local iter_opts
      local iter_stop
      local lang = "code_shape_iter_opts_lang_" .. tostring(vim.uv.hrtime())

      vim.treesitter.get_parser = function()
        return {
          lang = function()
            return lang
          end,
          parse = function()
            return {
              {
                root = function()
                  return {
                    end_ = function()
                      return 42, 0
                    end,
                  }
                end,
              },
            }
          end,
        }
      end

      vim.treesitter.query.parse = function()
        return {
          captures = {},
          iter_matches = function(_self, _node, _bufnr, _start, _stop, opts)
            iter_stop = _stop
            iter_opts = opts
            return function()
              return nil
            end
          end,
        }
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      indexer.index_with_treesitter(bufnr, "file:///tmp/iter-match-opts.lua")

      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.treesitter.get_parser = original_get_parser
      vim.treesitter.query.parse = original_parse

      assert.are.same({ all = true }, iter_opts)
      assert.are.equal(42, iter_stop)
    end)

    it("caches parsed query objects per language", function()
      local original_get_parser = vim.treesitter.get_parser
      local original_parse = vim.treesitter.query.parse
      local parse_count = 0
      local lang = "code_shape_cache_lang_" .. tostring(vim.uv.hrtime())

      vim.treesitter.get_parser = function()
        return {
          lang = function()
            return lang
          end,
          parse = function()
            return {
              {
                root = function()
                  return {}
                end,
              },
            }
          end,
        }
      end

      vim.treesitter.query.parse = function()
        parse_count = parse_count + 1
        return {
          captures = {},
          iter_matches = function()
            return function()
              return nil
            end
          end,
        }
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      indexer.index_with_treesitter(bufnr, "file:///tmp/query-cache.lua")
      indexer.index_with_treesitter(bufnr, "file:///tmp/query-cache.lua")

      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.treesitter.get_parser = original_get_parser
      vim.treesitter.query.parse = original_parse

      -- query list has 3 static patterns; second run should reuse cache
      assert.are.equal(3, parse_count)
    end)

    it("caches failed query parse per language", function()
      local original_get_parser = vim.treesitter.get_parser
      local original_parse = vim.treesitter.query.parse
      local parse_count = 0
      local lang = "code_shape_cache_fail_lang_" .. tostring(vim.uv.hrtime())

      vim.treesitter.get_parser = function()
        return {
          lang = function()
            return lang
          end,
          parse = function()
            return {
              {
                root = function()
                  return {}
                end,
              },
            }
          end,
        }
      end

      vim.treesitter.query.parse = function()
        parse_count = parse_count + 1
        error("parse failure")
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      indexer.index_with_treesitter(bufnr, "file:///tmp/query-cache-fail.lua")
      indexer.index_with_treesitter(bufnr, "file:///tmp/query-cache-fail.lua")

      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.treesitter.get_parser = original_get_parser
      vim.treesitter.query.parse = original_parse

      assert.are.equal(3, parse_count)
    end)
  end)
end)
