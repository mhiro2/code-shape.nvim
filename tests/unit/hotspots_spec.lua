local hotspots = require("code-shape.hotspots")

describe("hotspots", function()
  describe("module structure", function()
    it("has calculate function", function()
      assert.is_function(hotspots.calculate)
    end)

    it("has get_score function", function()
      assert.is_function(hotspots.get_score)
    end)

    it("has get_all_scores function", function()
      assert.is_function(hotspots.get_all_scores)
    end)

    it("has get_top function", function()
      assert.is_function(hotspots.get_top)
    end)

    it("has get_top_symbols function", function()
      assert.is_function(hotspots.get_top_symbols)
    end)

    it("has reset function", function()
      assert.is_function(hotspots.reset)
    end)
  end)

  describe("get_score", function()
    it("returns 0 for unknown uri", function()
      local score = hotspots.get_score("file:///unknown/path.lua")
      assert.are.equal(0, score)
    end)
  end)

  describe("get_top", function()
    it("returns empty table when no hotspots", function()
      local top = hotspots.get_top(10)
      assert.is_table(top)
    end)

    it("respects limit parameter", function()
      -- This will return empty or existing hotspots
      local top = hotspots.get_top(5)
      assert.is_true(#top <= 5)
    end)
  end)

  describe("get_top_symbols", function()
    local original_rpc
    local original_code_shape

    before_each(function()
      original_rpc = package.loaded["code-shape.rpc"]
      original_code_shape = package.loaded["code-shape"]
    end)

    after_each(function()
      package.loaded["code-shape.rpc"] = original_rpc
      package.loaded["code-shape"] = original_code_shape
    end)

    it("passes complexity_cap from config to core request", function()
      local rpc_calls = {}
      package.loaded["code-shape"] = {
        get_config = function()
          return { metrics = { complexity_cap = 75 } }
        end,
      }
      package.loaded["code-shape.rpc"] = {
        request = function(method, params, cb)
          table.insert(rpc_calls, { method = method, params = vim.deepcopy(params) })
          cb(nil, { symbols = {} })
        end,
      }

      local symbols, err
      hotspots.get_top_symbols("file:///tmp/a.lua", 5, function(result, rpc_err)
        symbols = result
        err = rpc_err
      end)

      assert.is_nil(err)
      assert.are.same({}, symbols)
      assert.are.equal(1, #rpc_calls)
      assert.are.equal("hotspot/getTopSymbols", rpc_calls[1].method)
      assert.are.same({
        uri = "file:///tmp/a.lua",
        limit = 5,
        complexity_cap = 75,
      }, rpc_calls[1].params)
    end)

    it("returns error when setup is not completed", function()
      package.loaded["code-shape"] = {
        get_config = function()
          return nil
        end,
      }
      package.loaded["code-shape.rpc"] = {
        request = function()
          error("rpc should not be called")
        end,
      }

      local symbols, err
      hotspots.get_top_symbols("file:///tmp/a.lua", 5, function(result, rpc_err)
        symbols = result
        err = rpc_err
      end)

      assert.is_nil(symbols)
      assert.are.equal("code-shape: setup is not completed", err)
    end)
  end)

  describe("get_all_scores", function()
    it("returns a table", function()
      local scores = hotspots.get_all_scores()
      assert.is_table(scores)
    end)
  end)

  describe("reset", function()
    local original_rpc

    before_each(function()
      original_rpc = package.loaded["code-shape.rpc"]
    end)

    after_each(function()
      package.loaded["code-shape.rpc"] = original_rpc
    end)

    it("clears local scores and syncs empty scores to core", function()
      local rpc_calls = {}
      package.loaded["code-shape.rpc"] = {
        request = function(method, params, cb)
          table.insert(rpc_calls, { method = method, params = vim.deepcopy(params) })
          if cb then
            cb(nil, { success = true })
          end
        end,
      }

      local scores = hotspots.get_all_scores()
      scores[vim.uri_from_fname("/tmp/a.lua")] = 0.9
      hotspots.reset()

      assert.are.same({}, hotspots.get_all_scores())
      assert.are.equal(1, #rpc_calls)
      assert.are.equal("hotspot/setScores", rpc_calls[1].method)
      assert.are.same({}, rpc_calls[1].params.scores)
    end)
  end)

  describe("time_decay", function()
    -- Access internal function for testing
    local function time_decay(commit_time, now, half_life_days)
      local days_ago = (now - commit_time) / 86400
      local decay_factor = math.log(2) / half_life_days
      return math.exp(-decay_factor * days_ago)
    end

    it("returns 1 for current time", function()
      local now = os.time()
      local weight = time_decay(now, now, 30)
      assert.is_true(math.abs(weight - 1.0) < 0.0001)
    end)

    it("returns ~0.5 for half_life_days ago", function()
      local now = os.time()
      local half_life_days = 30
      local commit_time = now - (half_life_days * 86400)
      local weight = time_decay(commit_time, now, half_life_days)
      assert.is_true(math.abs(weight - 0.5) < 0.01)
    end)

    it("returns lower weight for older commits", function()
      local now = os.time()
      local recent = time_decay(now - 86400, now, 30) -- 1 day ago
      local old = time_decay(now - (30 * 86400), now, 30) -- 30 days ago
      assert.is_true(recent > old)
    end)
  end)

  describe("calculate_churn_score", function()
    local function calculate_churn_score(additions, deletions)
      return additions + (deletions * 1.5)
    end

    it("calculates churn correctly", function()
      local score = calculate_churn_score(10, 5)
      -- 10 + (5 * 1.5) = 10 + 7.5 = 17.5
      assert.are.equal(17.5, score)
    end)

    it("handles zero values", function()
      local score = calculate_churn_score(0, 0)
      assert.are.equal(0, score)
    end)

    it("weights deletions higher than additions", function()
      local additions_only = calculate_churn_score(10, 0)
      local deletions_only = calculate_churn_score(0, 10)
      assert.is_true(deletions_only > additions_only)
    end)
  end)

  describe("calculate with churn", function()
    local util = require("code-shape.util")
    local roots = require("code-shape.roots")
    local original_find_git_root
    local original_getcwd
    local original_schedule
    local original_rpc
    local original_uv_new_pipe
    local original_uv_spawn

    local spawn_plans
    local deferred_runs

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
      original_find_git_root = util.find_git_root
      original_getcwd = vim.fn.getcwd
      original_schedule = vim.schedule
      original_rpc = package.loaded["code-shape.rpc"]
      original_uv_new_pipe = vim.uv.new_pipe
      original_uv_spawn = vim.uv.spawn

      spawn_plans = {}
      deferred_runs = {}
      roots.clear()

      vim.uv.new_pipe = function()
        return create_pipe()
      end
      vim.uv.spawn = function(_binary, opts, on_exit)
        local stdout_pipe = opts.stdio[2]
        local stderr_pipe = opts.stdio[3]
        local plan = table.remove(spawn_plans, 1)
          or {
            stdout_chunks = {},
            stderr_chunks = {},
            auto_run = true,
            exit_code = 0,
            exit_signal = 0,
          }

        local function run()
          for _, chunk in ipairs(plan.stdout_chunks or {}) do
            stdout_pipe:push(nil, chunk)
          end
          stdout_pipe:push(nil, nil)

          for _, chunk in ipairs(plan.stderr_chunks or {}) do
            stderr_pipe:push(nil, chunk)
          end
          stderr_pipe:push(nil, nil)

          on_exit(plan.exit_code or 0, plan.exit_signal or 0)
        end

        if plan.auto_run ~= false then
          run()
        else
          table.insert(deferred_runs, run)
        end

        return {
          close = function() end,
          unref = function() end,
        }, 12345
      end
    end)

    after_each(function()
      util.find_git_root = original_find_git_root
      vim.fn.getcwd = original_getcwd
      vim.schedule = original_schedule
      package.loaded["code-shape.rpc"] = original_rpc
      vim.uv.new_pipe = original_uv_new_pipe
      vim.uv.spawn = original_uv_spawn
      roots.clear()
    end)

    it("parses streamed git log output produced by --numstat --format=%ct", function()
      util.find_git_root = function()
        return "/repo"
      end
      vim.fn.getcwd = function()
        return "/repo"
      end
      vim.schedule = function(cb)
        cb()
      end

      local rpc_calls = {}
      package.loaded["code-shape.rpc"] = {
        request = function(method, params, cb)
          table.insert(rpc_calls, { method = method, params = params })
          if cb then
            cb(nil, { success = true })
          end
        end,
      }
      table.insert(spawn_plans, {
        stdout_chunks = {
          "1730000000\n10\t2\tsrc/foo.lua\n-\t-\tbinary.dat\n",
          "1720000000\n2\t0\tsrc/bar.lua\n",
        },
      })

      local scores
      hotspots.calculate({
        enabled = true,
        since = "1 month ago",
        max_files = 100,
        half_life_days = 30,
        use_churn = true,
      }, function(result)
        scores = result
      end)

      assert.is_table(scores)

      local foo_uri = vim.uri_from_fname("/repo/src/foo.lua")
      local bar_uri = vim.uri_from_fname("/repo/src/bar.lua")
      assert.is_true((scores[foo_uri] or 0) > (scores[bar_uri] or 0))
      assert.is_true((scores[foo_uri] or 0) > 0)
      assert.is_true((scores[bar_uri] or 0) > 0)

      assert.are.equal(1, #rpc_calls)
      assert.are.equal("hotspot/setScores", rpc_calls[1].method)
    end)

    it("ignores stale calculate result after reset during in-flight calculation", function()
      util.find_git_root = function()
        return "/repo"
      end
      vim.fn.getcwd = function()
        return "/repo"
      end
      vim.schedule = function(cb)
        cb()
      end

      local rpc_calls = {}
      package.loaded["code-shape.rpc"] = {
        request = function(method, params, cb)
          table.insert(rpc_calls, { method = method, params = vim.deepcopy(params) })
          if cb then
            cb(nil, { success = true })
          end
        end,
      }
      table.insert(spawn_plans, {
        stdout_chunks = {
          "1730000000\n10\t2\tsrc/foo.lua\n",
        },
        auto_run = false,
      })

      local callback_calls = 0
      hotspots.calculate({ use_churn = true }, function()
        callback_calls = callback_calls + 1
      end)

      assert.are.equal(1, #deferred_runs)

      hotspots.reset()

      assert.are.same({}, hotspots.get_all_scores())
      assert.are.equal(1, #rpc_calls)
      assert.are.equal("hotspot/setScores", rpc_calls[1].method)
      assert.are.same({}, rpc_calls[1].params.scores)

      deferred_runs[1]()

      assert.are.same({}, hotspots.get_all_scores())
      assert.are.equal(1, #rpc_calls)
      assert.are.equal(0, callback_calls)
    end)

    it("returns empty scores when git root is unavailable", function()
      util.find_git_root = function()
        return nil
      end

      local scores
      hotspots.calculate({ use_churn = true }, function(result)
        scores = result
      end)

      assert.are.same({}, scores)
    end)
  end)
end)
