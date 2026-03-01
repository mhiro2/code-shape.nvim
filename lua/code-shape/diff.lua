---@class CodeShapeDiff
local M = {}

local util = require("code-shape.util")
local uv = vim.uv

-- Alias for convenience
local close_pipe = util.close_pipe

---Parse git diff --name-status output
---@param line string
---@return CodeShapeChangedFile|nil
local function parse_name_status_line(line, git_root)
  -- Format: A/M/D\tfilename or R100\told\tnew
  if not line or line == "" then
    return nil
  end

  local status = line:sub(1, 1)
  local rest = line:sub(3)

  if status == "A" then
    local path = util.path_join(git_root, rest)
    return {
      uri = util.fname_to_file_uri(path),
      path = path,
      repo_path = rest,
      change_type = "added",
    }
  elseif status == "D" then
    local path = util.path_join(git_root, rest)
    return {
      uri = util.fname_to_file_uri(path),
      path = path,
      repo_path = rest,
      change_type = "deleted",
    }
  elseif status == "M" then
    local path = util.path_join(git_root, rest)
    return {
      uri = util.fname_to_file_uri(path),
      path = path,
      repo_path = rest,
      change_type = "modified",
    }
  elseif status == "R" then
    -- R100\told\tnew
    local old_path, new_path = rest:match("^[^\t]+\t([^\t]+)\t(.+)$")
    if old_path and new_path then
      local full_new_path = util.path_join(git_root, new_path)
      return {
        uri = util.fname_to_file_uri(full_new_path),
        path = full_new_path,
        repo_path = new_path,
        change_type = "renamed",
        old_path = util.path_join(git_root, old_path),
        old_repo_path = old_path,
      }
    end
  elseif status == "C" then
    -- Copy - treat as added
    local _, new_path = rest:match("^[^\t]+\t([^\t]+)\t(.+)$")
    if new_path then
      local path = util.path_join(git_root, new_path)
      return {
        uri = util.fname_to_file_uri(path),
        path = path,
        repo_path = new_path,
        change_type = "added",
      }
    end
  end

  return nil
end

---Parse git diff hunk header to extract line ranges
---Format: @@ -old_start,old_count +new_start,new_count @@
---@param header string
---@return { old_start: integer, old_count: integer, new_start: integer, new_count: integer }|nil
local function parse_hunk_header(header)
  -- Match: @@ -10,5 +10,7 @@ or @@ -10 +10,7 @@ or @@ -10,5 +10 @@
  local old_start, old_count, new_start, new_count = header:match("@@%s*%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s*@@")
  if not old_start then
    return nil
  end

  return {
    old_start = tonumber(old_start) or 1,
    old_count = tonumber(old_count) or 1,
    new_start = tonumber(new_start) or 1,
    new_count = tonumber(new_count) or 1,
  }
end

---Run git command and return output
---@param args string[]
---@param cwd string
---@param callback fun(code: integer, stdout: string, stderr: string)
local function run_git(args, cwd, callback)
  local stdout = {}
  local stderr = {}
  local stdout_pipe = uv.new_pipe(false)
  local stderr_pipe = uv.new_pipe(false)
  local handle
  local pid_or_err
  local exit_code = 1
  local exited = false
  local stdout_done = false
  local stderr_done = false
  local finished = false

  local function finish_if_ready()
    if finished or not exited or not stdout_done or not stderr_done then
      return
    end
    finished = true
    if handle then
      pcall(function()
        handle:close()
      end)
    end
    close_pipe(stdout_pipe)
    close_pipe(stderr_pipe)
    callback(exit_code, table.concat(stdout), table.concat(stderr))
  end

  stdout_pipe:read_start(function(err, data)
    if err then
      table.insert(stderr, tostring(err))
    end
    if data then
      table.insert(stdout, data)
      return
    end
    stdout_done = true
    finish_if_ready()
  end)

  stderr_pipe:read_start(function(err, data)
    if err then
      table.insert(stderr, tostring(err))
    end
    if data then
      table.insert(stderr, data)
      return
    end
    stderr_done = true
    finish_if_ready()
  end)

  handle, pid_or_err = uv.spawn("git", {
    args = args,
    cwd = cwd,
    stdio = { nil, stdout_pipe, stderr_pipe },
  }, function(code)
    exit_code = code or 1
    exited = true
    finish_if_ready()
  end)

  if not handle then
    close_pipe(stdout_pipe)
    close_pipe(stderr_pipe)
    callback(1, "", "failed to spawn git: " .. tostring(pid_or_err))
    return
  end

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

---Get changed files list
---@param opts CodeShapeDiffOptions
---@param git_root string
---@param callback fun(err: string|nil, files: CodeShapeChangedFile[])
local function get_changed_files(opts, git_root, callback)
  local args = { "diff", "--name-status" }

  if opts.staged then
    table.insert(args, "--cached")
  else
    local base = opts.base or "HEAD"
    if base ~= "HEAD" then
      table.insert(args, base .. "..." .. (opts.head or "HEAD"))
    else
      -- Default: compare working tree to HEAD
      table.insert(args, "HEAD")
    end
  end

  run_git(args, git_root, function(code, stdout, stderr)
    if code ~= 0 then
      callback(stderr or "git diff failed", {})
      return
    end

    local files = {}
    for line in stdout:gmatch("[^\r\n]+") do
      local file = parse_name_status_line(line, git_root)
      if file then
        table.insert(files, file)
      end
    end

    callback(nil, files)
  end)
end

---Get changed line ranges for a file
---@param opts CodeShapeDiffOptions
---@param git_root string
---@param file_path string
---@param callback fun(err: string|nil, ranges: { start_line: integer, end_line: integer }[])
local function get_changed_lines(opts, git_root, file_path, callback)
  local args = { "diff", "--unified=0", "--diff-filter=M" }

  if opts.staged then
    table.insert(args, "--cached")
  else
    local base = opts.base or "HEAD"
    if base ~= "HEAD" then
      table.insert(args, base .. "..." .. (opts.head or "HEAD"))
    else
      table.insert(args, "HEAD")
    end
  end

  table.insert(args, "--")
  table.insert(args, file_path)

  run_git(args, git_root, function(code, stdout, stderr)
    if code ~= 0 then
      callback(stderr or "git diff failed", {})
      return
    end

    local ranges = {}
    for line in stdout:gmatch("[^\r\n]+") do
      if line:sub(1, 2) == "@@" then
        local hunk = parse_hunk_header(line)
        if hunk then
          -- new_start is 1-indexed, convert to 0-indexed
          local start_line = hunk.new_start - 1
          local end_line = start_line + hunk.new_count - 1
          if hunk.new_count > 0 then
            table.insert(ranges, { start_line = start_line, end_line = end_line })
          end
        end
      end
    end

    callback(nil, ranges)
  end)
end

---Check if a line range overlaps with any changed ranges
---@param symbol_start integer 0-indexed
---@param symbol_end integer 0-indexed
---@param changed_ranges { start_line: integer, end_line: integer }[]
---@return boolean
---@return integer[]
local function symbol_overlaps_changes(symbol_start, symbol_end, changed_ranges)
  local changed_lines = {}
  local overlaps = false

  for _, range in ipairs(changed_ranges) do
    -- Check for overlap
    if range.start_line <= symbol_end and range.end_line >= symbol_start then
      overlaps = true
      -- Collect changed lines within symbol
      for line = math.max(symbol_start, range.start_line), math.min(symbol_end, range.end_line) do
        table.insert(changed_lines, line)
      end
    end
  end

  return overlaps, changed_lines
end

---Get symbols using tree-sitter (fallback)
---@param bufnr integer
---@param uri string
---@param callback fun(err: string|nil, symbols: table[])
local function get_file_symbols_from_treesitter(bufnr, uri, callback)
  local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not has_parser or not parser then
    callback("no tree-sitter parser", {})
    return
  end

  local symbols = {}
  local trees = parser:parse()
  if not trees or not trees[1] then
    callback(nil, {})
    return
  end

  local root = trees[1]:root()
  local lang = parser:lang()

  -- Basic queries for common symbol types
  local queries = {
    [[
      (function_declaration name: (identifier) @name) @symbol
      (function_definition name: (identifier) @name) @symbol
      (method_declaration name: (field_identifier) @name) @symbol
      (method_definition name: (property_identifier) @name) @symbol
      (class_declaration name: (type_identifier) @name) @symbol
      (class_definition name: (type_identifier) @name) @symbol
    ]],
  }

  for _, query_str in ipairs(queries) do
    local ok, query = pcall(vim.treesitter.query.parse, lang, query_str)
    if ok and query then
      for _, match, _ in query:iter_matches(root, bufnr, 0, -1, { all = true }) do
        local name_node = match[1] or match["name"]
        local symbol_node = match[2] or match["symbol"]

        if name_node and symbol_node then
          if type(name_node) == "table" then
            name_node = name_node[1]
          end
          if type(symbol_node) == "table" then
            symbol_node = symbol_node[1]
          end

          if name_node and symbol_node then
            local name = vim.treesitter.get_node_text(name_node, bufnr)
            local start_line, _, end_line, end_col = symbol_node:range()
            local node_type = symbol_node:type()

            local kind = 13 -- Variable
            if node_type:find("function") or node_type:find("method") then
              kind = 12 -- Function
            elseif node_type:find("class") then
              kind = 5 -- Class
            end

            table.insert(symbols, {
              name = name,
              kind = kind,
              uri = uri,
              range = {
                start = { line = start_line, character = 0 },
                ["end"] = { line = end_line or start_line, character = end_col or 0 },
              },
            })
          end
        end
      end
    end
  end

  callback(nil, symbols)
end

---Get symbols for a file using LSP or tree-sitter
---@param uri string
---@param callback fun(err: string|nil, symbols: table[])
local function get_file_symbols(uri, callback)
  local path = util.file_uri_to_fname(uri)
  if not path then
    callback("invalid uri", {})
    return
  end

  -- Check if buffer is already loaded
  local bufnr = vim.uri_to_bufnr(uri)
  local is_loaded = vim.api.nvim_buf_is_loaded(bufnr)

  if not is_loaded then
    -- Load buffer temporarily
    vim.fn.bufload(bufnr)
  end

  -- Try LSP first
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local has_symbol_provider = false

  for _, client in ipairs(clients) do
    if client.server_capabilities.documentSymbolProvider then
      has_symbol_provider = true
      local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
      client:request("textDocument/documentSymbol", params, function(err, result)
        if err or not result then
          -- Fallback to tree-sitter
          get_file_symbols_from_treesitter(bufnr, uri, callback)
          return
        end

        local symbols = {}
        local function process_symbols(symbols_list)
          for _, sym in ipairs(symbols_list) do
            local range = sym.range or sym.selectionRange
            if range then
              table.insert(symbols, {
                name = sym.name,
                kind = util.to_symbol_kind(sym.kind),
                container_name = sym.containerName,
                uri = uri,
                range = {
                  start = { line = range.start.line, character = range.start.character },
                  ["end"] = { line = range["end"].line, character = range["end"].character },
                },
                detail = sym.detail,
              })
            end
            if sym.children and #sym.children > 0 then
              process_symbols(sym.children)
            end
          end
        end
        process_symbols(result)
        callback(nil, symbols)
      end, bufnr)
      break
    end
  end

  if not has_symbol_provider then
    -- Fallback to tree-sitter
    get_file_symbols_from_treesitter(bufnr, uri, callback)
  end
end

---Get symbols from a deleted file using git show
---@param base string
---@param git_root string
---@param repo_path string
---@param callback fun(err: string|nil, symbols: table[])
local function get_deleted_file_symbols(base, git_root, repo_path, callback)
  -- Get file content from base commit
  local args = { "show", base .. ":" .. repo_path }
  run_git(args, git_root, function(code, stdout, stderr)
    if code ~= 0 then
      callback(stderr or "git show failed", {})
      return
    end

    -- Create temporary buffer to parse symbols
    local temp_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, vim.split(stdout, "\n"))

    local abs_path = util.path_join(git_root, repo_path)
    local uri = util.fname_to_file_uri(abs_path)
    get_file_symbols_from_treesitter(temp_buf, uri, function(err, symbols)
      vim.api.nvim_buf_delete(temp_buf, { force = true })
      callback(err, symbols)
    end)
  end)
end

---Extract changed symbols from a modified file
---@param file CodeShapeChangedFile
---@param opts CodeShapeDiffOptions
---@param git_root string
---@param callback fun(err: string|nil, symbols: CodeShapeChangedSymbol[])
local function extract_changed_symbols(file, opts, git_root, callback)
  if file.change_type == "deleted" then
    -- For deleted files, get symbols from base
    local base = opts.base or "HEAD"
    local repo_path = file.repo_path
    if not repo_path or repo_path == "" then
      local root_prefix = git_root .. "/"
      if type(file.path) == "string" and file.path:sub(1, #root_prefix) == root_prefix then
        repo_path = file.path:sub(#root_prefix + 1)
      else
        repo_path = file.path
      end
    end

    get_deleted_file_symbols(base, git_root, repo_path, function(err, symbols)
      if err then
        callback(err, {})
        return
      end

      local changed_symbols = {}
      for _, sym in ipairs(symbols) do
        table.insert(
          changed_symbols,
          vim.tbl_extend("force", sym, {
            symbol_id = util.generate_symbol_id(sym.uri, sym.name, sym.kind, sym.range),
            change_type = "deleted",
            changed_lines = {},
          })
        )
      end
      callback(nil, changed_symbols)
    end)
    return
  end

  if file.change_type == "added" or file.change_type == "renamed" then
    -- For new files, all symbols are "added"
    get_file_symbols(file.uri, function(err, symbols)
      if err then
        callback(err, {})
        return
      end

      local changed_symbols = {}
      for _, sym in ipairs(symbols) do
        table.insert(
          changed_symbols,
          vim.tbl_extend("force", sym, {
            symbol_id = util.generate_symbol_id(sym.uri, sym.name, sym.kind, sym.range),
            change_type = "added",
            changed_lines = {},
          })
        )
      end
      callback(nil, changed_symbols)
    end)
    return
  end

  -- For modified files, match symbols to changed lines
  get_changed_lines(opts, git_root, file.path, function(err, ranges)
    if err then
      callback(err, {})
      return
    end

    if #ranges == 0 then
      callback(nil, {})
      return
    end

    get_file_symbols(file.uri, function(symbols_err, symbols)
      if symbols_err then
        callback(symbols_err, {})
        return
      end

      local changed_symbols = {}
      for _, sym in ipairs(symbols) do
        local start_line = sym.range.start.line
        local end_line = sym.range["end"].line
        local overlaps, changed_lines = symbol_overlaps_changes(start_line, end_line, ranges)

        if overlaps then
          table.insert(
            changed_symbols,
            vim.tbl_extend("force", sym, {
              symbol_id = util.generate_symbol_id(sym.uri, sym.name, sym.kind, sym.range),
              change_type = "modified",
              changed_lines = changed_lines,
            })
          )
        end
      end
      callback(nil, changed_symbols)
    end)
  end)
end

---Analyze diff and extract changed symbols
---@param opts CodeShapeDiffOptions
---@param callback fun(err: string|nil, result: CodeShapeDiffAnalysis|nil)
function M.analyze(opts, callback)
  opts = opts or {}

  -- Validate: --head without --base is ambiguous
  if opts.head and not opts.base then
    callback("code-shape: --head requires --base (e.g. --base=main --head=" .. opts.head .. ")", nil)
    return
  end

  local git_root = opts.git_root or util.find_git_root(vim.fn.getcwd())

  if not git_root then
    callback("not a git repository", nil)
    return
  end

  get_changed_files(opts, git_root, function(err, files)
    if err then
      callback(err, nil)
      return
    end

    if #files == 0 then
      callback(nil, {
        base = opts.base or "HEAD",
        head = opts.head or "working",
        files = {},
        symbols = {},
        stats = {
          files_added = 0,
          files_modified = 0,
          files_deleted = 0,
          files_renamed = 0,
          symbols_added = 0,
          symbols_modified = 0,
          symbols_deleted = 0,
        },
      })
      return
    end

    local all_symbols = {}
    local pending = #files
    local stats = {
      files_added = 0,
      files_modified = 0,
      files_deleted = 0,
      files_renamed = 0,
      symbols_added = 0,
      symbols_modified = 0,
      symbols_deleted = 0,
    }

    for _, file in ipairs(files) do
      -- Update file stats
      if file.change_type == "added" then
        stats.files_added = stats.files_added + 1
      elseif file.change_type == "modified" then
        stats.files_modified = stats.files_modified + 1
      elseif file.change_type == "deleted" then
        stats.files_deleted = stats.files_deleted + 1
      elseif file.change_type == "renamed" then
        stats.files_renamed = stats.files_renamed + 1
      end

      extract_changed_symbols(file, opts, git_root, function(sym_err, symbols)
        if not sym_err and symbols then
          for _, sym in ipairs(symbols) do
            table.insert(all_symbols, sym)
            if sym.change_type == "added" then
              stats.symbols_added = stats.symbols_added + 1
            elseif sym.change_type == "modified" then
              stats.symbols_modified = stats.symbols_modified + 1
            elseif sym.change_type == "deleted" then
              stats.symbols_deleted = stats.symbols_deleted + 1
            end
          end
        end

        pending = pending - 1
        if pending == 0 then
          callback(nil, {
            base = opts.base or "HEAD",
            head = opts.head or (opts.staged and "staged" or "working"),
            files = files,
            symbols = all_symbols,
            stats = stats,
          })
        end
      end)
    end
  end)
end

---Analyze staged changes
---@param callback fun(err: string|nil, result: CodeShapeDiffAnalysis|nil)
function M.analyze_staged(callback)
  M.analyze({ staged = true }, callback)
end

---Get changed symbols only
---@param opts CodeShapeDiffOptions
---@param callback fun(err: string|nil, symbols: CodeShapeChangedSymbol[]|nil)
function M.get_changed_symbols(opts, callback)
  M.analyze(opts, function(err, result)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, result.symbols)
  end)
end

-- Change type weights for impact calculation
local CHANGE_TYPE_WEIGHTS = {
  added = 1.0,
  modified = 0.8,
  deleted = 1.0,
  renamed = 0.5,
}

---Calculate impact score for a symbol
---@param symbol CodeShapeChangedSymbol
---@param hotspot_score number
---@param caller_count integer
---@param callee_count integer
---@return number
local function calculate_impact_score(symbol, hotspot_score, caller_count, callee_count)
  local change_weight = CHANGE_TYPE_WEIGHTS[symbol.change_type] or 0.5
  local caller_weight = math.min(caller_count, 10) / 10 * 0.5
  local callee_weight = math.min(callee_count, 10) / 10 * 0.3
  local hotspot_weight = hotspot_score * 0.4

  return change_weight * (1.0 + caller_weight + callee_weight + hotspot_weight)
end

---Build impact score from changed symbol
---@param symbol CodeShapeChangedSymbol
---@param rpc CodeShapeRpc
---@param hotspots CodeShapeHotspots
---@param callback fun(err: string|nil, score: CodeShapeImpactScore|nil)
local function build_impact_score(symbol, rpc, hotspots, callback)
  -- Get hotspot score for the file
  local hotspot_score = hotspots.get_score(symbol.uri) or 0

  -- Get caller/callee counts from graph
  local pending = 2
  local caller_count = 0
  local callee_count = 0
  local has_error = false

  local function on_done()
    if has_error then
      return
    end
    pending = pending - 1
    if pending == 0 then
      local impact_score = calculate_impact_score(symbol, hotspot_score, caller_count, callee_count)

      -- Calculate tech debt from symbol metrics if available
      local tech_debt = nil
      -- Note: metrics would need to be fetched from index, for now we estimate from range
      local lines_in_range = symbol.range["end"].line - symbol.range.start.line + 1
      if lines_in_range > 50 then
        tech_debt = math.min(lines_in_range / 100, 1.0)
      end

      callback(nil, {
        symbol_id = symbol.symbol_id,
        name = symbol.name,
        kind = symbol.kind,
        uri = symbol.uri,
        range = symbol.range,
        change_type = symbol.change_type,
        hotspot_score = hotspot_score,
        tech_debt = tech_debt,
        caller_count = caller_count,
        callee_count = callee_count,
        impact_score = impact_score,
      })
    end
  end

  -- Get incoming edges (callers)
  rpc.request("graph/getIncomingEdges", { symbol_id = symbol.symbol_id }, function(err, result)
    if err then
      has_error = true
      callback(err, nil)
      return
    end
    caller_count = result and result.edges and #result.edges or 0
    on_done()
  end)

  -- Get outgoing edges (callees)
  rpc.request("graph/getOutgoingEdges", { symbol_id = symbol.symbol_id }, function(err, result)
    if err then
      has_error = true
      callback(err, nil)
      return
    end
    callee_count = result and result.edges and #result.edges or 0
    on_done()
  end)
end

local MAX_BFS_DEPTH = 3

---Find affected symbols via call graph traversal (parallel BFS by depth level)
---@param changed_symbol_ids string[]
---@param rpc CodeShapeRpc
---@param callback fun(err: string|nil, affected: table<string, boolean>|nil)
local function find_affected_symbols(changed_symbol_ids, rpc, callback)
  local visited = {}
  local affected = {}

  -- Initialize with changed symbols
  ---@type { id: string, depth: integer }[]
  local current_level = {}
  for _, id in ipairs(changed_symbol_ids) do
    table.insert(current_level, { id = id, depth = 0 })
    visited[id] = true
  end

  ---Process one BFS level: fire all RPC requests in parallel, collect next level
  local function process_level()
    if #current_level == 0 then
      callback(nil, affected)
      return
    end

    local pending = #current_level
    local next_level = {}

    for _, item in ipairs(current_level) do
      rpc.request("graph/getIncomingEdges", { symbol_id = item.id }, function(err, result)
        if not err and result and result.edges then
          for _, edge in ipairs(result.edges) do
            local caller_id = edge.caller_symbol_id
            if not visited[caller_id] then
              visited[caller_id] = true
              affected[caller_id] = true
              if item.depth + 1 < MAX_BFS_DEPTH then
                table.insert(next_level, { id = caller_id, depth = item.depth + 1 })
              end
            end
          end
        end

        pending = pending - 1
        if pending == 0 then
          current_level = next_level
          process_level()
        end
      end)
    end
  end

  process_level()
end

---Get symbol details from index
---@param symbol_id string
---@param rpc CodeShapeRpc
---@param callback fun(err: string|nil, symbol: table|nil)
local function get_symbol_from_index(symbol_id, rpc, callback)
  rpc.request("index/getSymbolById", { symbol_id = symbol_id }, function(err, result)
    if err then
      callback(err, nil)
      return
    end

    local symbol = nil
    if type(result) == "table" then
      symbol = result.symbol or result
    end

    if type(symbol) == "table" and symbol.symbol_id then
      callback(nil, symbol)
    else
      callback("symbol not found", nil)
    end
  end)
end

---Calculate impact analysis for changed symbols
---Combines diff analysis with call graph and hotspot scores
---@param opts CodeShapeDiffOptions
---@param callback fun(err: string|nil, result: CodeShapeImpactAnalysis|nil)
function M.calculate_impact(opts, callback)
  opts = opts or {}

  local rpc = require("code-shape.rpc")
  local hotspots = require("code-shape.hotspots")

  -- First, run diff analysis
  M.analyze(opts, function(err, diff_result)
    if err then
      callback(err, nil)
      return
    end

    if #diff_result.symbols == 0 then
      callback(nil, {
        base = diff_result.base,
        head = diff_result.head,
        changed_symbols = {},
        affected_symbols = {},
        risk_ranking = {},
      })
      return
    end

    -- Build impact scores for changed symbols
    local changed_impact_scores = {}
    local pending = #diff_result.symbols

    local done = false

    local function finish(finish_err, result)
      if done then
        return
      end
      done = true
      callback(finish_err, result)
    end

    local function build_result(changed, affected)
      local all_scores = vim.list_extend({}, changed)
      all_scores = vim.list_extend(all_scores, affected)
      table.sort(all_scores, function(a, b)
        return a.impact_score > b.impact_score
      end)
      return {
        base = diff_result.base,
        head = diff_result.head,
        changed_symbols = changed,
        affected_symbols = affected,
        risk_ranking = all_scores,
      }
    end

    for _, symbol in ipairs(diff_result.symbols) do
      build_impact_score(symbol, rpc, hotspots, function(build_err, score)
        if done then
          return
        end

        if build_err then
          finish(build_err, nil)
          return
        end

        if score then
          table.insert(changed_impact_scores, score)
        end

        pending = pending - 1
        if pending == 0 then
          -- Find affected symbols via call graph
          local changed_ids = {}
          for _, s in ipairs(diff_result.symbols) do
            table.insert(changed_ids, s.symbol_id)
          end

          find_affected_symbols(changed_ids, rpc, function(find_err, affected_ids)
            if done then
              return
            end

            if find_err then
              finish(find_err, nil)
              return
            end

            -- Build impact scores for affected symbols
            local affected_impact_scores = {}
            local affected_pending = vim.tbl_count(affected_ids)

            if affected_pending == 0 then
              finish(nil, build_result(changed_impact_scores, {}))
              return
            end

            for affected_id, _ in pairs(affected_ids) do
              get_symbol_from_index(affected_id, rpc, function(get_err, sym)
                if done then
                  return
                end

                if not get_err and sym then
                  local affected_hotspot = hotspots.get_score(sym.uri) or 0
                  local affected_score = {
                    symbol_id = sym.symbol_id,
                    name = sym.name,
                    kind = sym.kind,
                    uri = sym.uri,
                    range = sym.range,
                    change_type = "affected",
                    hotspot_score = affected_hotspot,
                    tech_debt = sym.tech_debt,
                    caller_count = 0, -- Would need separate call
                    callee_count = 0,
                    impact_score = affected_hotspot * 0.5, -- Lower score for affected
                  }
                  table.insert(affected_impact_scores, affected_score)
                end

                affected_pending = affected_pending - 1
                if affected_pending == 0 then
                  finish(nil, build_result(changed_impact_scores, affected_impact_scores))
                end
              end)
            end
          end)
        end
      end)
    end
  end)
end

return M
