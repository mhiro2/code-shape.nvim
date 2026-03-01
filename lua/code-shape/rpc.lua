---@class CodeShapeRpc
local M = {}

local uv = vim.uv
local util

---@return CodeShapeUtil
local function get_util()
  util = util or require("code-shape.util")
  return util
end

-- Alias for convenience after util is loaded
local function safe_stop_timer(timer)
  return get_util().safe_stop_timer(timer)
end

---@type uv_process_t|nil
local process = nil
---@type uv_pipe_t|nil
local stdin_pipe = nil
---@type uv_pipe_t|nil
local stdout_pipe = nil
---@type uv_pipe_t|nil
local stderr_pipe = nil

local next_id = 1
---@type table<integer, { cb: fun(err: string|nil, result: any), timer: uv_timer_t|nil }>
local pending = {}

---@type table<string, fun(params: any)[]>
local notification_handlers = {}

local DEFAULT_TIMEOUT_MS = 30000
local FORCE_KILL_DELAY_MS = 3000

---@type string[]
local read_buffer_parts = {}
---@type uv_timer_t|nil
local stop_kill_timer = nil

-- Error tracking for recovery decisions
---@type integer
local consecutive_errors = 0
---@type integer
local last_error_time = 0
local ERROR_THRESHOLD = 5
local ERROR_WINDOW_MS = 5000
local DECODE_NOTIFY_WINDOW_MS = 2000
local MAX_DECODE_SNIPPET = 120

---@type integer
local last_decode_notify_time = -DECODE_NOTIFY_WINDOW_MS
---@type integer
local suppressed_decode_errors = 0

---@param timer uv_timer_t|nil
local function stop_and_close_timer(timer)
  safe_stop_timer(timer)
end

---@param id integer
---@return { cb: fun(err: string|nil, result: any), timer: uv_timer_t|nil }|nil
local function take_pending(id)
  local entry = pending[id]
  if not entry then
    return nil
  end
  pending[id] = nil
  stop_and_close_timer(entry.timer)
  return entry
end

local function clear_stop_kill_timer()
  if stop_kill_timer then
    pcall(function()
      if not stop_kill_timer:is_closing() then
        stop_kill_timer:stop()
        stop_kill_timer:close()
      end
    end)
    stop_kill_timer = nil
  end
end

---@param line string
---@return string
local function prefixed_core_line(line)
  if line:find("^code%-shape%-core:") then
    return line
  end
  return "code-shape-core: " .. line
end

---@param line string
---@return string
local function strip_core_prefix(line)
  return line:gsub("^code%-shape%-core:%s*", "")
end

---@param line string
---@param err any
local function notify_decode_failure(line, err)
  local now = uv.now() or 0
  if now - last_decode_notify_time < DECODE_NOTIFY_WINDOW_MS then
    suppressed_decode_errors = suppressed_decode_errors + 1
    return
  end

  local suffix = ""
  if suppressed_decode_errors > 0 then
    suffix = string.format(" (+%d suppressed)", suppressed_decode_errors)
    suppressed_decode_errors = 0
  end
  last_decode_notify_time = now

  local snippet = line
  if #snippet > MAX_DECODE_SNIPPET then
    snippet = snippet:sub(1, MAX_DECODE_SNIPPET) .. "..."
  end

  vim.schedule(function()
    vim.notify(
      string.format("code-shape: failed to decode rpc payload: %s [%s]%s", tostring(err), snippet, suffix),
      vim.log.levels.DEBUG
    )
  end)
end

local function reset_read_buffer_parts()
  read_buffer_parts = {}
end

---@param segment string
---@return string
local function take_buffered_line(segment)
  if segment ~= "" then
    table.insert(read_buffer_parts, segment)
  end
  local line = table.concat(read_buffer_parts)
  read_buffer_parts = {}
  return line
end

---@param line string
local function handle_stdout_line(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    notify_decode_failure(line, ok and "not an object" or msg)
  elseif msg.id ~= nil then
    -- Response
    local id = msg.id
    if type(id) == "number" then
      local entry = take_pending(id)
      if entry then
        vim.schedule(function()
          if msg.error then
            entry.cb(msg.error.message or "rpc error", nil)
          else
            entry.cb(nil, msg.result)
          end
        end)
      end
    end
  elseif msg.method then
    -- Notification
    local handlers = notification_handlers[msg.method]
    if handlers then
      for _, handler in ipairs(handlers) do
        local handler_fn = handler
        local params = msg.params
        vim.schedule(function()
          handler_fn(params)
        end)
      end
    end
  end
end

---@param data string
local function on_stdout(data)
  local cursor = 1
  while true do
    local newline = data:find("\n", cursor, true)
    if not newline then
      local tail = data:sub(cursor)
      if tail ~= "" then
        table.insert(read_buffer_parts, tail)
      end
      break
    end

    local segment = data:sub(cursor, newline - 1)
    local line = take_buffered_line(segment)
    if line ~= "" then
      handle_stdout_line(line)
    end
    cursor = newline + 1
  end
end

---Check if error is fatal and requires process restart
---@param line string
---@return boolean
local function is_fatal_error(line)
  local normalized = strip_core_prefix(line:lower())
  if normalized:match("^fatal error:") or normalized:match("^panic:") then
    return true
  end
  if normalized:match("^thread '.-' panicked at") then
    return true
  end
  if normalized:match("^read error:%s*failed to read from stdin") then
    return true
  end

  local fatal_keywords = {
    "assertion failed",
    "out of memory",
    "stack overflow",
    "segmentation fault",
    "access violation",
  }
  for _, keyword in ipairs(fatal_keywords) do
    if normalized:find(keyword, 1, true) then
      return true
    end
  end
  return false
end

---Check if error is ignorable (debug/info output)
---@param line string
---@return boolean
local function is_ignorable_error(line)
  local normalized = strip_core_prefix(line:lower())
  local ignorable_patterns = {
    "^debug:",
    "^info:",
    "^trace:",
    "^warn:",
    "^warning:",
    "^note:",
  }
  for _, pattern in ipairs(ignorable_patterns) do
    if normalized:find(pattern) then
      return true
    end
  end
  return false
end

---@param line string
---@return boolean
local function is_error_line(line)
  return line:lower():find("%f[%a]error%f[%A]") ~= nil
end

---@param data string
local function on_stderr(data)
  local now = vim.uv.now() or 0

  for line in data:gmatch("[^\n]+") do
    -- Skip empty lines and ignorable output
    if line ~= "" and not is_ignorable_error(line) then
      -- Check for fatal errors
      if is_fatal_error(line) then
        vim.schedule(function()
          vim.notify(
            prefixed_core_line(line) .. "\nProcess will be stopped. Restart with :CodeShape",
            vim.log.levels.ERROR
          )
        end)
        -- Stop the process on fatal error
        vim.schedule(function()
          M.stop()
        end)
        return
      end

      -- Track consecutive errors for recovery
      if is_error_line(line) then
        -- Reset counter if outside error window
        if now - last_error_time > ERROR_WINDOW_MS then
          consecutive_errors = 0
        end

        consecutive_errors = consecutive_errors + 1
        last_error_time = now

        -- Notify user with context
        vim.schedule(function()
          vim.notify(prefixed_core_line(line), vim.log.levels.ERROR)
        end)

        -- If too many consecutive errors, stop the process
        if consecutive_errors >= ERROR_THRESHOLD then
          vim.schedule(function()
            vim.notify(
              "code-shape-core: Too many consecutive errors. Stopping process.\n"
                .. "Check :checkhealth code-shape for diagnostics.",
              vim.log.levels.ERROR
            )
            M.stop()
          end)
          return
        end
      else
        -- Reset counter on non-error output
        consecutive_errors = 0
      end
    end
  end
end

function M.is_running()
  return process ~= nil
end

function M.start()
  if process then
    return true
  end

  consecutive_errors = 0
  last_error_time = 0
  reset_read_buffer_parts()
  last_decode_notify_time = -DECODE_NOTIFY_WINDOW_MS
  suppressed_decode_errors = 0

  local binary = get_util().find_core_binary()
  if not binary then
    vim.notify(
      "code-shape: binary not found. Run :checkhealth code-shape or build with 'cd rust && cargo build --release'",
      vim.log.levels.ERROR
    )
    return false
  end

  stdin_pipe = uv.new_pipe(false)
  stdout_pipe = uv.new_pipe(false)
  stderr_pipe = uv.new_pipe(false)

  local handle, pid
  handle, pid = uv.spawn(binary, {
    stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    detached = false,
  }, function(code)
    vim.schedule(function()
      clear_stop_kill_timer()
      process = nil
      for id, entry in pairs(pending) do
        pending[id] = nil
        stop_and_close_timer(entry.timer)
        entry.cb("process exited (code=" .. tostring(code) .. ")", nil)
      end
      reset_read_buffer_parts()
      if stdin_pipe and not stdin_pipe:is_closing() then
        stdin_pipe:close()
      end
      if stdout_pipe and not stdout_pipe:is_closing() then
        stdout_pipe:close()
      end
      if stderr_pipe and not stderr_pipe:is_closing() then
        stderr_pipe:close()
      end
      stdin_pipe = nil
      stdout_pipe = nil
      stderr_pipe = nil
    end)
  end)

  if not handle then
    vim.notify("code-shape: failed to start binary: " .. tostring(pid), vim.log.levels.ERROR)
    if stdin_pipe then
      stdin_pipe:close()
    end
    if stdout_pipe then
      stdout_pipe:close()
    end
    if stderr_pipe then
      stderr_pipe:close()
    end
    stdin_pipe = nil
    stdout_pipe = nil
    stderr_pipe = nil
    return false
  end

  process = handle
  pcall(function()
    process:unref()
  end)
  pcall(function()
    stdin_pipe:unref()
  end)
  pcall(function()
    stdout_pipe:unref()
  end)
  pcall(function()
    stderr_pipe:unref()
  end)

  stdout_pipe:read_start(function(err, data)
    if err then
      return
    end
    if data then
      on_stdout(data)
    end
  end)

  stderr_pipe:read_start(function(err, data)
    if err then
      return
    end
    if data then
      on_stderr(data)
    end
  end)

  -- Send initialize
  M.request("initialize", {}, function() end)

  return true
end

function M.stop()
  if not process then
    return
  end

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = next_id,
    method = "shutdown",
    params = vim.empty_dict(),
  }) .. "\n"
  next_id = next_id + 1

  if stdin_pipe then
    pcall(function()
      stdin_pipe:write(msg)
    end)
  end

  local target = process
  pcall(function()
    target:kill(15)
  end) -- SIGTERM

  clear_stop_kill_timer()
  stop_kill_timer = uv.new_timer()
  if stop_kill_timer then
    pcall(function()
      stop_kill_timer:unref()
    end)
    stop_kill_timer:start(FORCE_KILL_DELAY_MS, 0, function()
      if process ~= target then
        clear_stop_kill_timer()
        return
      end
      pcall(function()
        target:kill(9)
      end) -- SIGKILL
      clear_stop_kill_timer()
    end)
  end
end

---@param method string
---@param params table
---@param cb fun(err: string|nil, result: any)
---@param opts? { timeout_ms?: integer }
---@return integer|nil request_id
function M.request(method, params, cb, opts)
  if not process then
    if not M.start() then
      cb("process not running", nil)
      return nil
    end
  end

  local id = next_id
  next_id = next_id + 1

  local timeout_ms = (opts and opts.timeout_ms) or DEFAULT_TIMEOUT_MS

  local timer = uv.new_timer()
  if timer then
    pcall(function()
      timer:unref()
    end)
    timer:start(timeout_ms, 0, function()
      local entry = take_pending(id)
      if entry then
        vim.schedule(function()
          entry.cb("timeout after " .. timeout_ms .. "ms", nil)
        end)
      end
    end)
  end

  pending[id] = { cb = cb, timer = timer }

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  }) .. "\n"

  if stdin_pipe then
    local write_ok, write_err = pcall(function()
      stdin_pipe:write(msg, function(err)
        if not err then
          return
        end
        local entry = take_pending(id)
        if entry then
          vim.schedule(function()
            entry.cb("write failed: " .. tostring(err), nil)
          end)
        end
        vim.schedule(function()
          if process then
            M.stop()
          end
        end)
      end)
    end)
    if not write_ok then
      take_pending(id)
      cb("write failed: " .. tostring(write_err), nil)
      if process then
        M.stop()
      end
      return nil
    end
  else
    take_pending(id)
    cb("stdin not available", nil)
    return nil
  end
  return id
end

---@param method string
---@param params table
---@param timeout_ms? integer
---@return any|nil result
---@return string|nil error
function M.request_sync(method, params, timeout_ms)
  timeout_ms = timeout_ms or DEFAULT_TIMEOUT_MS
  local result, err
  local done = false
  local request_id = M.request(method, params, function(e, r)
    err = e
    result = r
    done = true
  end, { timeout_ms = timeout_ms })

  local ok = vim.wait(timeout_ms, function()
    return done
  end, 10)
  if not ok then
    if request_id then
      take_pending(request_id)
    end
    return nil, "sync request timeout"
  end
  return result, err
end

---@param method string
---@param params table
function M.notify(method, params)
  if not process or not stdin_pipe then
    return
  end

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }) .. "\n"

  pcall(function()
    stdin_pipe:write(msg)
  end)
end

---@param method string
---@param cb fun(params: any)
function M.on_notification(method, cb)
  if not notification_handlers[method] then
    notification_handlers[method] = {}
  end
  table.insert(notification_handlers[method], cb)
end

---@param method string
---@param cb fun(params: any)
function M.off_notification(method, cb)
  local handlers = notification_handlers[method]
  if not handlers then
    return
  end
  for i = #handlers, 1, -1 do
    if handlers[i] == cb then
      table.remove(handlers, i)
    end
  end
end

return M
