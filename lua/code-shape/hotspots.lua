---@class CodeShapeHotspots
local M = {}

local util = require("code-shape.util")
local uv = vim.uv

-- Alias for convenience
local close_pipe = util.close_pipe

---@type table<string, number>
local hotspot_scores = {}
local calculation_generation = 0

---@return integer
local function start_new_calculation()
  calculation_generation = calculation_generation + 1
  return calculation_generation
end

local function cancel_calculation()
  calculation_generation = calculation_generation + 1
end

---@param generation integer
---@return boolean
local function is_active_generation(generation)
  return generation == calculation_generation
end

---@param scores table<string, number>
local function set_scores_in_core(scores)
  local rpc = require("code-shape.rpc")
  rpc.request("hotspot/setScores", { scores = scores }, function(err)
    if err then
      vim.notify("code-shape: " .. err, vim.log.levels.WARN)
    end
  end)
end

---Time decay function: newer commits get higher weight
---@param commit_time number Unix timestamp of commit
---@param now number Current Unix timestamp
---@param half_life_days number Days for weight to decay to 0.5
---@return number weight
local function time_decay(commit_time, now, half_life_days)
  local days_ago = (now - commit_time) / 86400
  local decay_factor = math.log(2) / half_life_days
  return math.exp(-decay_factor * days_ago)
end

---Calculate churn score from git numstat
---@param additions number Lines added
---@param deletions number Lines deleted
---@return number churn_score
local function calculate_churn_score(additions, deletions)
  -- Churn formula: additions + deletions, with extra weight on deletions
  -- (deletions often indicate refactoring or bug fixes)
  return additions + (deletions * 1.5)
end

---@param args string[]
---@param cwd string
---@param on_line fun(line: string)
---@param on_done fun(code: integer, stderr: string)
local function run_git_stream(args, cwd, on_line, on_done)
  local stdout_pipe = uv.new_pipe(false)
  local stderr_pipe = uv.new_pipe(false)
  if not stdout_pipe or not stderr_pipe then
    close_pipe(stdout_pipe)
    close_pipe(stderr_pipe)
    on_done(1, "failed to create git stream pipes")
    return
  end

  local stdout_tail = ""
  local stderr_parts = {}
  local handle = nil
  local exited = false
  local stdout_done = false
  local stderr_done = false
  local exit_code = 1

  local function finish_if_ready()
    if not exited or not stdout_done or not stderr_done then
      return
    end
    close_pipe(stdout_pipe)
    close_pipe(stderr_pipe)
    if handle and handle.close then
      pcall(function()
        handle:close()
      end)
    end
    on_done(exit_code, table.concat(stderr_parts))
  end

  ---@param chunk string
  local function consume_stdout_chunk(chunk)
    local buffer = stdout_tail .. chunk
    local cursor = 1

    while true do
      local newline = buffer:find("\n", cursor, true)
      if not newline then
        stdout_tail = buffer:sub(cursor)
        return
      end

      local line = buffer:sub(cursor, newline - 1)
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      on_line(line)
      cursor = newline + 1
    end
  end

  stdout_pipe:read_start(function(err, data)
    if err then
      table.insert(stderr_parts, tostring(err))
    end

    if data then
      consume_stdout_chunk(data)
      return
    end

    if stdout_tail ~= "" then
      on_line(stdout_tail)
      stdout_tail = ""
    end
    stdout_done = true
    finish_if_ready()
  end)

  stderr_pipe:read_start(function(err, data)
    if err then
      table.insert(stderr_parts, tostring(err))
    end
    if data then
      table.insert(stderr_parts, data)
      return
    end
    stderr_done = true
    finish_if_ready()
  end)

  local spawned
  local spawn_err
  spawned, spawn_err = uv.spawn("git", {
    args = args,
    cwd = cwd,
    stdio = { nil, stdout_pipe, stderr_pipe },
  }, function(code)
    exit_code = code or 1
    exited = true
    finish_if_ready()
  end)

  if not spawned then
    close_pipe(stdout_pipe)
    close_pipe(stderr_pipe)
    on_done(1, "failed to spawn git: " .. tostring(spawn_err))
    return
  end

  handle = spawned
  pcall(function()
    handle:unref()
  end)
  pcall(function()
    stdout_pipe:unref()
  end)
  pcall(function()
    stderr_pipe:unref()
  end)
end

---@param raw_count string
---@return number
local function parse_numstat_count(raw_count)
  if raw_count == "-" then
    -- Binary diff entries in git numstat
    return 0
  end
  local count = tonumber(raw_count)
  if not count or count < 0 then
    return 0
  end
  return count
end

---@class CodeShapeHotspotsChurnState
---@field current_commit_time number|nil

---@param line string
---@param state CodeShapeHotspotsChurnState
---@param file_scores table<string, number>
---@param now number
---@param half_life_days number
local function parse_churn_line(line, state, file_scores, now, half_life_days)
  if line == "" then
    return
  end

  if line:match("^%d+$") then
    state.current_commit_time = tonumber(line)
    return
  end

  local additions, deletions, filename = line:match("^([%-%d]+)\t([%-%d]+)\t(.+)$")
  if not additions or not deletions or not filename or filename == "" then
    return
  end

  local commit_time = state.current_commit_time or now
  local adds = parse_numstat_count(additions)
  local dels = parse_numstat_count(deletions)
  local weight = time_decay(commit_time, now, half_life_days)
  local churn = calculate_churn_score(adds, dels)

  file_scores[filename] = (file_scores[filename] or 0) + (churn * weight)
end

---@param file_scores table<string, number>
---@param max_files integer
---@param git_root string
---@return table<string, number>
local function build_normalized_scores(file_scores, max_files, git_root)
  local max_score = 1
  local sorted = {}

  for file, score in pairs(file_scores) do
    if score > max_score then
      max_score = score
    end
    table.insert(sorted, { file = file, score = score })
  end

  table.sort(sorted, function(a, b)
    return a.score > b.score
  end)

  local scores = {}
  for i, item in ipairs(sorted) do
    if i > max_files then
      break
    end
    local full_path = util.path_join(git_root, item.file)
    local uri = util.fname_to_file_uri(full_path)
    if uri then
      scores[uri] = item.score / max_score
    end
  end

  return scores
end

---Calculate hotspot scores for a single git root
---@param config CodeShapeHotspotsConfig
---@param git_root string
---@param cb fun(scores: table<string, number>)
local function calculate_for_root(config, git_root, cb)
  local since = config.since or "3 months ago"
  local max_files = config.max_files or 1000
  local half_life_days = config.half_life_days or 30
  local use_churn = config.use_churn ~= false

  local callback_called = false
  local function safe_callback(scores)
    if not callback_called then
      callback_called = true
      cb(scores)
    end
  end

  if use_churn then
    local now = os.time()
    local churn_state = { current_commit_time = nil }
    local file_scores = {}

    -- Stream git output line-by-line to avoid keeping huge logs in memory.
    run_git_stream(
      {
        "log",
        "--numstat",
        "--format=%ct",
        "--since=" .. since,
      },
      git_root,
      function(line)
        parse_churn_line(line, churn_state, file_scores, now, half_life_days)
      end,
      function(code)
        if code ~= 0 then
          safe_callback({})
          return
        end
        safe_callback(build_normalized_scores(file_scores, max_files, git_root))
      end
    )
    return
  end

  local counts = {}
  run_git_stream(
    {
      "log",
      "--name-only",
      "--since=" .. since,
      "--pretty=format:",
    },
    git_root,
    function(line)
      if line ~= "" then
        counts[line] = (counts[line] or 0) + 1
      end
    end,
    function(code)
      if code ~= 0 then
        safe_callback({})
        return
      end
      safe_callback(build_normalized_scores(counts, max_files, git_root))
    end
  )
end

---Calculate hotspot scores using git log with churn analysis
---Supports multiple git roots (monorepo / git-worktree)
---@param config CodeShapeHotspotsConfig
---@param cb fun(scores: table<string, number>)
function M.calculate(config, cb)
  config = config or {}
  local generation = start_new_calculation()

  -- Collect git roots from tracked URIs
  local roots_mod = require("code-shape.roots")
  local roots = roots_mod.get_roots()

  -- Fallback: if no roots discovered yet, try cwd
  if #roots == 0 then
    local cwd = vim.fn.getcwd()
    local git_root = util.find_git_root(cwd)
    if git_root then
      roots = { git_root }
    end
  end

  if #roots == 0 then
    if is_active_generation(generation) then
      cb({})
    end
    return
  end

  local all_scores = {}
  local pending_count = #roots
  local callback_called = false

  local function on_all_done()
    if callback_called or not is_active_generation(generation) then
      return
    end
    callback_called = true

    hotspot_scores = all_scores

    -- Send merged scores to Rust core
    vim.schedule(function()
      set_scores_in_core(all_scores)
    end)

    cb(all_scores)
  end

  for _, git_root in ipairs(roots) do
    calculate_for_root(config, git_root, function(root_scores)
      if not is_active_generation(generation) then
        return
      end

      -- Merge root scores into combined table
      -- URIs from different roots are distinct, so no conflict
      for uri, score in pairs(root_scores) do
        all_scores[uri] = score
      end

      pending_count = pending_count - 1
      if pending_count == 0 then
        on_all_done()
      end
    end)
  end
end

---Clear hotspot scores in Lua and Rust core
function M.reset()
  cancel_calculation()
  hotspot_scores = {}
  set_scores_in_core({})
end

---Get hotspot score for a file (accepts URI)
---@param uri_or_path string
---@return number
function M.get_score(uri_or_path)
  -- Convert path to URI if needed
  local uri = uri_or_path
  if type(uri) ~= "string" or uri == "" then
    return 0
  end
  if not util.is_file_uri(uri) then
    uri = util.fname_to_file_uri(uri_or_path)
    if not uri then
      return 0
    end
  end
  return hotspot_scores[uri] or 0
end

---Get all hotspot scores
---@return table<string, number>
function M.get_all_scores()
  return hotspot_scores
end

---Get top hotspots
---@param limit integer|nil
---@return { path: string, score: number }[]
function M.get_top(limit)
  limit = limit or 20
  local sorted = {}

  for path, score in pairs(hotspot_scores) do
    table.insert(sorted, { path = path, score = score })
  end

  table.sort(sorted, function(a, b)
    return a.score > b.score
  end)

  local result = {}
  for i, item in ipairs(sorted) do
    if i > limit then
      break
    end
    table.insert(result, item)
  end

  return result
end

---Get top symbols for a URI
---@param uri string File URI
---@param limit integer|nil Maximum number of symbols to return
---@param cb fun(symbols: table|nil, err: string|nil)
function M.get_top_symbols(uri, limit, cb)
  if type(limit) == "function" then
    cb = limit
    limit = 10
  end
  limit = limit or 10

  local code_shape = require("code-shape")
  local config = code_shape.get_config()
  if not config then
    cb(nil, "code-shape: setup is not completed")
    return
  end

  local rpc = require("code-shape.rpc")
  rpc.request(
    "hotspot/getTopSymbols",
    { uri = uri, limit = limit, complexity_cap = config.metrics.complexity_cap },
    function(err, result)
      if err then
        cb(nil, err)
        return
      end
      cb(result and result.symbols or {}, nil)
    end
  )
end

return M
