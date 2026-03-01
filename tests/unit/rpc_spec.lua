describe("rpc", function()
  local uv
  local original_new_pipe
  local original_spawn
  local original_new_timer
  local original_fs_stat
  local original_now
  local original_wait

  local spawned_exit_cb
  local kill_signals
  local timers
  local rpc
  local pipes
  local write_error
  local now_ms

  local function make_pipe()
    local closed = false
    local pipe = {
      on_read = nil,
      unref = function() end,
      read_start = function(self, cb)
        self.on_read = cb
      end,
      write = function(_, _, cb)
        if cb then
          cb(write_error)
        end
      end,
      close = function(_)
        closed = true
      end,
      is_closing = function(_)
        return closed
      end,
    }
    table.insert(pipes, pipe)
    return pipe
  end

  before_each(function()
    uv = vim.uv
    original_new_pipe = uv.new_pipe
    original_spawn = uv.spawn
    original_new_timer = uv.new_timer
    original_fs_stat = uv.fs_stat
    original_now = uv.now
    original_wait = vim.wait

    spawned_exit_cb = nil
    kill_signals = {}
    timers = {}
    pipes = {}
    write_error = nil
    now_ms = 0

    uv.new_pipe = function()
      return make_pipe()
    end
    uv.fs_stat = function()
      return { type = "file" }
    end
    uv.now = function()
      return now_ms
    end
    uv.new_timer = function()
      local timer = {
        closed = false,
        delay = nil,
        cb = nil,
      }
      function timer:unref() end
      function timer:start(delay, _repeat_ms, cb)
        self.delay = delay
        self.cb = cb
      end
      function timer:stop() end
      function timer:close()
        self.closed = true
      end
      function timer:is_closing()
        return self.closed
      end
      table.insert(timers, timer)
      return timer
    end
    uv.spawn = function(_binary, _opts, on_exit)
      spawned_exit_cb = on_exit
      local handle = {
        unref = function() end,
        kill = function(_, sig)
          table.insert(kill_signals, sig)
        end,
      }
      return handle, 12345
    end

    package.loaded["code-shape.rpc"] = nil
    rpc = require("code-shape.rpc")
  end)

  after_each(function()
    if spawned_exit_cb then
      spawned_exit_cb(0)
      vim.wait(10, function()
        return false
      end, 1)
    end

    uv.new_pipe = original_new_pipe
    uv.spawn = original_spawn
    uv.new_timer = original_new_timer
    uv.fs_stat = original_fs_stat
    uv.now = original_now
    vim.wait = original_wait

    package.loaded["code-shape.rpc"] = nil
  end)

  it("delays SIGKILL after SIGTERM in stop()", function()
    assert.is_true(rpc.start())

    rpc.stop()

    assert.are.same({ 15 }, kill_signals)

    local force_kill_timer = nil
    for _, timer in ipairs(timers) do
      if timer.delay == 3000 then
        force_kill_timer = timer
        break
      end
    end
    assert.is_not_nil(force_kill_timer)

    force_kill_timer.cb()
    assert.are.same({ 15, 9 }, kill_signals)
  end)

  it("cleans pending sync request when vim.wait times out first", function()
    assert.is_true(rpc.start())

    vim.wait = function()
      return false
    end

    local result, err = rpc.request_sync("search/query", { q = "test", limit = 10 }, 1234)
    assert.is_nil(result)
    assert.are.equal("sync request timeout", err)

    local request_timer = nil
    for _, timer in ipairs(timers) do
      if timer.delay == 1234 then
        request_timer = timer
        break
      end
    end
    assert.is_not_nil(request_timer)
    assert.is_true(request_timer.closed)
  end)

  it("stops process when stdin read error is emitted on stderr", function()
    assert.is_true(rpc.start())
    local stderr_pipe = pipes[3]
    assert.is_not_nil(stderr_pipe)
    assert.is_not_nil(stderr_pipe.on_read)

    stderr_pipe.on_read(nil, "code-shape-core: read error: failed to read from stdin\n")
    vim.wait(50, function()
      return #kill_signals >= 1
    end, 1)

    assert.are.same({ 15 }, kill_signals)
  end)

  it("does not stop process for non-fatal stderr lines containing error", function()
    assert.is_true(rpc.start())
    local stderr_pipe = pipes[3]
    assert.is_not_nil(stderr_pipe)
    assert.is_not_nil(stderr_pipe.on_read)

    stderr_pipe.on_read(nil, "code-shape-core: worker error budget reached\n")
    vim.wait(50, function()
      return false
    end, 1)

    assert.are.same({}, kill_signals)
  end)

  it("fails sync request immediately when stdin write fails", function()
    assert.is_true(rpc.start())
    write_error = "broken pipe"

    local result, err = rpc.request_sync("search/query", { q = "test" }, 1234)

    assert.is_nil(result)
    assert.is_not_nil(err)
    assert.is_true(err:find("write failed", 1, true) ~= nil)
    assert.are.same({ 15 }, kill_signals)
  end)

  it("guards request timer creation failure", function()
    assert.is_true(rpc.start())
    write_error = "broken pipe"
    uv.new_timer = function()
      return nil
    end

    local result, err = rpc.request_sync("search/query", { q = "test" }, 1234)

    assert.is_nil(result)
    assert.is_not_nil(err)
    assert.is_true(err:find("write failed", 1, true) ~= nil)
    assert.are.same({ 15 }, kill_signals)
  end)

  it("rate limits JSON decode failure notifications on stdout", function()
    local original_notify = vim.notify
    local notifications = {}
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    assert.is_true(rpc.start())
    local stdout_pipe = pipes[2]
    assert.is_not_nil(stdout_pipe)
    assert.is_not_nil(stdout_pipe.on_read)

    stdout_pipe.on_read(nil, "{invalid-json}\n")
    now_ms = 500
    stdout_pipe.on_read(nil, "{invalid-json}\n")

    local first_ok = vim.wait(100, function()
      return #notifications >= 1
    end, 1)
    assert.is_true(first_ok)
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.DEBUG, notifications[1].level)
    assert.is_true(notifications[1].msg:find("failed to decode rpc payload", 1, true) ~= nil)

    now_ms = 2500
    stdout_pipe.on_read(nil, "{invalid-json}\n")

    local second_ok = vim.wait(100, function()
      return #notifications >= 2
    end, 1)
    assert.is_true(second_ok)
    assert.are.equal(2, #notifications)
    assert.is_true(notifications[2].msg:find("suppressed", 1, true) ~= nil)

    vim.notify = original_notify
  end)

  it("handles fragmented stdout notification payloads", function()
    assert.is_true(rpc.start())
    local stdout_pipe = pipes[2]
    assert.is_not_nil(stdout_pipe)
    assert.is_not_nil(stdout_pipe.on_read)

    local received = nil
    rpc.on_notification("$/log", function(params)
      received = params
    end)

    stdout_pipe.on_read(nil, '{"jsonrpc":"2.0","method":"$/log","params":{"level":"info"')
    stdout_pipe.on_read(nil, ',"message":"ok"}}\n')

    local ok = vim.wait(100, function()
      return received ~= nil
    end, 1)
    assert.is_true(ok)
    assert.are.equal("info", received.level)
    assert.are.equal("ok", received.message)
  end)

  it("is_running returns false before start", function()
    assert.is_false(rpc.is_running())
  end)

  it("is_running returns true after start", function()
    assert.is_true(rpc.start())
    assert.is_true(rpc.is_running())
  end)
end)
