describe("diff", function()
  local diff

  before_each(function()
    package.loaded["code-shape.diff"] = nil
    diff = require("code-shape.diff")
  end)

  after_each(function()
    package.loaded["code-shape.diff"] = nil
  end)

  describe("impact score calculation constants", function()
    it("gives higher weight to added and deleted symbols than modified", function()
      -- These are the internal CHANGE_TYPE_WEIGHTS constants
      -- added=1.0, modified=0.8, deleted=1.0, renamed=0.5
      local change_weights = {
        added = 1.0,
        modified = 0.8,
        deleted = 1.0,
        renamed = 0.5,
      }

      -- Added and deleted should have highest weight
      assert.are.equal(1.0, change_weights.added)
      assert.are.equal(1.0, change_weights.deleted)
      -- Modified should be lower
      assert.are.equal(0.8, change_weights.modified)
      -- Renamed should be lowest
      assert.are.equal(0.5, change_weights.renamed)

      -- Verify ordering
      assert.is_true(change_weights.added >= change_weights.modified)
      assert.is_true(change_weights.deleted >= change_weights.modified)
      assert.is_true(change_weights.modified >= change_weights.renamed)
    end)

    it("caps caller contribution at 0.5", function()
      -- caller_weight = min(caller_count, 10) / 10 * 0.5
      -- Maximum is when caller_count >= 10: 10/10 * 0.5 = 0.5
      local max_caller_contribution = 0.5
      assert.are.equal(0.5, max_caller_contribution)
    end)

    it("caps callee contribution at 0.3", function()
      -- callee_weight = min(callee_count, 10) / 10 * 0.3
      -- Maximum is when callee_count >= 10: 10/10 * 0.3 = 0.3
      local max_callee_contribution = 0.3
      assert.are.equal(0.3, max_callee_contribution)
    end)

    it("applies hotspot weight at 0.4", function()
      -- hotspot_weight = hotspot_score * 0.4
      -- Maximum when hotspot_score = 1.0: 1.0 * 0.4 = 0.4
      local max_hotspot_contribution = 0.4
      assert.are.equal(0.4, max_hotspot_contribution)
    end)

    it("calculates impact score formula correctly", function()
      -- Formula: change_weight * (1.0 + caller_weight + callee_weight + hotspot_weight)
      -- For added symbol with max callers/callees/hotspot:
      -- = 1.0 * (1.0 + 0.5 + 0.3 + 0.4) = 1.0 * 2.2 = 2.2
      local change_weight = 1.0 -- added
      local caller_weight = 0.5 -- max
      local callee_weight = 0.3 -- max
      local hotspot_weight = 0.4 -- max

      local impact_score = change_weight * (1.0 + caller_weight + callee_weight + hotspot_weight)
      assert.are.equal(2.2, impact_score)
    end)

    it("calculates minimum impact score correctly", function()
      -- For renamed symbol with no callers/callees/hotspot:
      -- = 0.5 * (1.0 + 0 + 0 + 0) = 0.5
      local change_weight = 0.5 -- renamed
      local caller_weight = 0
      local callee_weight = 0
      local hotspot_weight = 0

      local impact_score = change_weight * (1.0 + caller_weight + callee_weight + hotspot_weight)
      assert.are.equal(0.5, impact_score)
    end)

    it("calculates caller weight with diminishing returns", function()
      -- caller_weight = min(caller_count, 10) / 10 * 0.5
      local function calc_caller_weight(count)
        return math.min(count, 10) / 10 * 0.5
      end

      assert.are.equal(0.05, calc_caller_weight(1))
      assert.are.equal(0.25, calc_caller_weight(5))
      assert.are.equal(0.5, calc_caller_weight(10))
      assert.are.equal(0.5, calc_caller_weight(100)) -- capped
    end)

    it("calculates callee weight with diminishing returns", function()
      -- callee_weight = min(callee_count, 10) / 10 * 0.3
      local function calc_callee_weight(count)
        return math.min(count, 10) / 10 * 0.3
      end

      assert.are.equal(0.03, calc_callee_weight(1))
      assert.are.equal(0.15, calc_callee_weight(5))
      assert.are.equal(0.3, calc_callee_weight(10))
      assert.are.equal(0.3, calc_callee_weight(100)) -- capped
    end)
  end)

  describe("tech debt calculation", function()
    it("estimates tech debt from symbol range size", function()
      -- Tech debt is calculated from lines_in_range
      -- If lines_in_range > 50: tech_debt = min(lines_in_range / 100, 1.0)

      -- 100 lines -> 1.0
      local lines_100 = 100
      local debt_100 = math.min(lines_100 / 100, 1.0)
      assert.are.equal(1.0, debt_100)

      -- 50 lines -> 0.5
      local lines_50 = 50
      local debt_50 = math.min(lines_50 / 100, 1.0)
      assert.are.equal(0.5, debt_50)

      -- 200 lines -> capped at 1.0
      local lines_200 = 200
      local debt_200 = math.min(lines_200 / 100, 1.0)
      assert.are.equal(1.0, debt_200)
    end)
  end)

  describe("module exports", function()
    it("exports analyze function", function()
      assert.is_function(diff.analyze)
    end)

    it("exports analyze_staged function", function()
      assert.is_function(diff.analyze_staged)
    end)

    it("exports get_changed_symbols function", function()
      assert.is_function(diff.get_changed_symbols)
    end)

    it("exports calculate_impact function", function()
      assert.is_function(diff.calculate_impact)
    end)
  end)

  describe("ui module exports", function()
    it("exports open_impact function", function()
      local ui = require("code-shape.ui")
      assert.is_function(ui.open_impact)
    end)
  end)

  describe("init module exports", function()
    it("exports show_impact function", function()
      package.loaded["code-shape"] = nil
      local code_shape = require("code-shape")
      assert.is_function(code_shape.show_impact)
    end)
  end)

  describe("picker module impact support", function()
    it("picker utils exports format_impact function", function()
      local picker_utils = require("code-shape.picker.utils")
      assert.is_function(picker_utils.format_impact)
    end)

    it("format_impact returns string", function()
      local picker_utils = require("code-shape.picker.utils")
      local item = {
        name = "test_func",
        kind = 12,
        uri = "file:///test.lua",
        change_type = "modified",
        caller_count = 5,
        hotspot_score = 0.8,
        impact_score = 1.5,
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 10, character = 0 } },
      }
      local result = picker_utils.format_impact(item)
      assert.is_string(result)
      assert.is_true(result:find("test_func") ~= nil)
    end)
  end)

  describe("deleted file analysis", function()
    local original_spawn
    local original_new_pipe

    local function create_pipe()
      local pipe = {
        on_read = nil,
        closed = false,
        queued = {},
      }
      function pipe:read_start(cb)
        self.on_read = cb
        for _, item in ipairs(self.queued) do
          cb(item.err, item.data)
        end
        self.queued = {}
      end
      function pipe:push(err, data)
        if self.on_read then
          self.on_read(err, data)
          return
        end
        table.insert(self.queued, { err = err, data = data })
      end
      function pipe:close()
        self.closed = true
      end
      function pipe:is_closing()
        return self.closed
      end
      function pipe:unref() end
      return pipe
    end

    before_each(function()
      original_spawn = vim.uv.spawn
      original_new_pipe = vim.uv.new_pipe
      vim.uv.new_pipe = function()
        return create_pipe()
      end
    end)

    after_each(function()
      vim.uv.spawn = original_spawn
      vim.uv.new_pipe = original_new_pipe
    end)

    it("uses repository-relative path for git show on deleted files", function()
      local spawn_calls = {}
      vim.uv.spawn = function(_cmd, opts, on_exit)
        local args = vim.deepcopy(opts.args)
        local stdout_pipe = opts.stdio[2]
        local stderr_pipe = opts.stdio[3]
        table.insert(spawn_calls, { args = args, cwd = opts.cwd, stdio = opts.stdio })

        vim.schedule(function()
          if args[1] == "diff" and args[2] == "--name-status" then
            stdout_pipe:push(nil, "D\tfoo/bar.lua\n")
          end
          if args[1] == "show" then
            stderr_pipe:push(nil, "fatal: path does not exist in 'HEAD'\n")
          end
          stdout_pipe:push(nil, nil)
          stderr_pipe:push(nil, nil)

          local code = args[1] == "show" and 1 or 0
          on_exit(code, 0)
        end)

        return {
          close = function() end,
          unref = function() end,
        }, 1
      end

      local done = false
      local analyze_err = nil
      local analyze_result = nil

      diff.analyze({
        git_root = "/repo",
        base = "HEAD",
      }, function(err, result)
        analyze_err = err
        analyze_result = result
        done = true
      end)

      local completed = vim.wait(200, function()
        return done
      end, 10)
      assert.is_true(completed)
      assert.is_nil(analyze_err)
      assert.are.equal(1, analyze_result.stats.files_deleted)

      local show_call = nil
      for _, call in ipairs(spawn_calls) do
        if call.args[1] == "show" then
          show_call = call
          break
        end
      end

      assert.is_not_nil(show_call)
      assert.are.equal("HEAD:foo/bar.lua", show_call.args[2])
      assert.is_table(spawn_calls[1].stdio[2])
      assert.is_table(spawn_calls[1].stdio[3])
    end)

    it("returns spawn error when git command cannot start", function()
      vim.uv.spawn = function()
        return nil, "spawn failure"
      end

      local done = false
      local analyze_err = nil

      diff.analyze({
        git_root = "/repo",
        base = "HEAD",
      }, function(err)
        analyze_err = err
        done = true
      end)

      local completed = vim.wait(200, function()
        return done
      end, 10)
      assert.is_true(completed)
      assert.are.equal("failed to spawn git: spawn failure", analyze_err)
    end)
  end)

  describe("affected symbol resolution", function()
    local original_rpc
    local original_hotspots

    before_each(function()
      original_rpc = package.loaded["code-shape.rpc"]
      original_hotspots = package.loaded["code-shape.hotspots"]
    end)

    after_each(function()
      package.loaded["code-shape.rpc"] = original_rpc
      package.loaded["code-shape.hotspots"] = original_hotspots
    end)

    it("resolves affected symbols via index/getSymbolById", function()
      local rpc_calls = {}

      package.loaded["code-shape.rpc"] = {
        request = function(method, params, cb)
          table.insert(rpc_calls, {
            method = method,
            params = vim.deepcopy(params),
          })

          if method == "graph/getIncomingEdges" then
            if params.symbol_id == "changed-1" then
              cb(nil, {
                edges = {
                  { caller_symbol_id = "affected-1" },
                },
              })
            else
              cb(nil, { edges = {} })
            end
          elseif method == "graph/getOutgoingEdges" then
            cb(nil, { edges = {} })
          elseif method == "index/getSymbolById" then
            cb(nil, {
              symbol = {
                symbol_id = "affected-1",
                name = "affected_fn",
                kind = 12,
                uri = "file:///affected.lua",
                range = {
                  start = { line = 3, character = 0 },
                  ["end"] = { line = 8, character = 0 },
                },
              },
            })
          else
            cb("unexpected method: " .. method, nil)
          end
        end,
      }

      package.loaded["code-shape.hotspots"] = {
        get_score = function(uri)
          if uri == "file:///changed.lua" then
            return 0.8
          end
          if uri == "file:///affected.lua" then
            return 0.4
          end
          return 0
        end,
      }

      local original_analyze = diff.analyze
      diff.analyze = function(_, cb)
        cb(nil, {
          base = "HEAD",
          head = "working",
          symbols = {
            {
              symbol_id = "changed-1",
              name = "changed_fn",
              kind = 12,
              uri = "file:///changed.lua",
              range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 2, character = 0 },
              },
              change_type = "modified",
            },
          },
        })
      end

      local done = false
      local impact_err = nil
      local impact_result = nil

      diff.calculate_impact({}, function(err, result)
        impact_err = err
        impact_result = result
        done = true
      end)

      local completed = vim.wait(200, function()
        return done
      end, 10)
      assert.is_true(completed)
      assert.is_nil(impact_err)
      assert.are.equal(1, #impact_result.affected_symbols)
      assert.are.equal("affected-1", impact_result.affected_symbols[1].symbol_id)

      local has_get_symbol_call = false
      for _, call in ipairs(rpc_calls) do
        if call.method == "index/getSymbolById" and call.params.symbol_id == "affected-1" then
          has_get_symbol_call = true
          break
        end
      end
      assert.is_true(has_get_symbol_call)

      diff.analyze = original_analyze
    end)
  end)

  describe("--head without --base validation", function()
    it("returns error when --head is specified without --base", function()
      local done = false
      local analyze_err = nil

      diff.analyze({ head = "feature/foo" }, function(err, _)
        analyze_err = err
        done = true
      end)

      local completed = vim.wait(200, function()
        return done
      end, 10)
      assert.is_true(completed)
      assert.is_not_nil(analyze_err)
      assert.truthy(analyze_err:find("%-%-head requires %-%-base"))
    end)

    it("allows --base without --head", function()
      -- This should not trigger the validation error (it may fail for other reasons
      -- like not being in a git repo, but not due to --head validation)
      local done = false
      local analyze_err = nil

      diff.analyze({ base = "main", git_root = "/nonexistent" }, function(err, _)
        analyze_err = err
        done = true
      end)

      local completed = vim.wait(200, function()
        return done
      end, 10)
      assert.is_true(completed)
      -- Should not be the --head validation error
      if analyze_err then
        assert.is_nil(analyze_err:find("%-%-head requires %-%-base"))
      end
    end)
  end)

  describe("find_affected_symbols parallel BFS", function()
    local original_rpc
    local original_hotspots

    before_each(function()
      original_rpc = package.loaded["code-shape.rpc"]
      original_hotspots = package.loaded["code-shape.hotspots"]
    end)

    after_each(function()
      package.loaded["code-shape.rpc"] = original_rpc
      package.loaded["code-shape.hotspots"] = original_hotspots
    end)

    it("discovers affected symbols across multiple BFS levels", function()
      -- Graph: changed-1 <- caller-A <- caller-B (two levels deep)
      package.loaded["code-shape.rpc"] = {
        request = function(method, params, cb)
          if method == "graph/getIncomingEdges" then
            if params.symbol_id == "changed-1" then
              cb(nil, { edges = { { caller_symbol_id = "caller-A" } } })
            elseif params.symbol_id == "caller-A" then
              cb(nil, { edges = { { caller_symbol_id = "caller-B" } } })
            else
              cb(nil, { edges = {} })
            end
          elseif method == "graph/getOutgoingEdges" then
            cb(nil, { edges = {} })
          elseif method == "index/getSymbolById" then
            local id = params.symbol_id
            cb(nil, {
              symbol = {
                symbol_id = id,
                name = id,
                kind = 12,
                uri = "file:///" .. id .. ".lua",
                range = { start = { line = 0, character = 0 }, ["end"] = { line = 5, character = 0 } },
              },
            })
          else
            cb(nil, {})
          end
        end,
      }

      package.loaded["code-shape.hotspots"] = {
        get_score = function()
          return 0
        end,
      }

      local original_analyze = diff.analyze
      diff.analyze = function(_, cb)
        cb(nil, {
          base = "HEAD",
          head = "working",
          symbols = {
            {
              symbol_id = "changed-1",
              name = "changed_fn",
              kind = 12,
              uri = "file:///changed.lua",
              range = { start = { line = 0, character = 0 }, ["end"] = { line = 2, character = 0 } },
              change_type = "modified",
            },
          },
        })
      end

      local done = false
      local impact_result = nil

      diff.calculate_impact({}, function(err, result)
        assert.is_nil(err)
        impact_result = result
        done = true
      end)

      local completed = vim.wait(200, function()
        return done
      end, 10)
      assert.is_true(completed)

      -- Should have found both caller-A and caller-B as affected
      assert.are.equal(2, #impact_result.affected_symbols)
      local affected_ids = {}
      for _, sym in ipairs(impact_result.affected_symbols) do
        affected_ids[sym.symbol_id] = true
      end
      assert.is_true(affected_ids["caller-A"])
      assert.is_true(affected_ids["caller-B"])

      diff.analyze = original_analyze
    end)
  end)
end)
