---@class CodeShapeUtil
local M = {}

local uv = vim.uv

---Safely close a pipe, checking if it exists and isn't already closing
---@param pipe uv_pipe_t|nil
function M.close_pipe(pipe)
  if not pipe then
    return
  end
  if pipe.is_closing and not pipe:is_closing() then
    pipe:close()
  end
end

---Safely stop and close a timer
---@param timer uv_timer_t|nil
function M.safe_stop_timer(timer)
  if not timer then
    return
  end
  pcall(function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end)
end
---@type table<string, string|false>
local git_root_cache = {}

---@param path string
---@return string
local function normalize_path(path)
  local realpath = uv.fs_realpath(path)
  return vim.fs.normalize(realpath or path)
end

---@param path string
---@return boolean
local function is_absolute_path(path)
  if path:sub(1, 1) == "/" then
    return true
  end
  return path:match("^%a:[/\\]") ~= nil
end

---@param base string
---@param target string
---@return string
local function resolve_path(base, target)
  if is_absolute_path(target) then
    return normalize_path(target)
  end
  return normalize_path(vim.fs.joinpath(base, target))
end

---@param path string
---@return string|nil
local function read_first_line(path)
  local fd = uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end

  local stat = uv.fs_fstat(fd)
  if not stat or not stat.size or stat.size <= 0 then
    uv.fs_close(fd)
    return nil
  end

  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if type(content) ~= "string" or content == "" then
    return nil
  end

  local first_line = content:match("([^\r\n]+)")
  return first_line
end

---@param segment string|nil
---@param fallback string
---@return string
local function sanitize_segment(segment, fallback)
  local source = type(segment) == "string" and segment or fallback
  local sanitized = source:gsub("[^%w%._-]", "_")
  if sanitized == "" then
    return fallback
  end
  return sanitized
end

---@param git_root string
---@return string|nil git_dir
---@return string|nil common_dir
local function resolve_git_dirs(git_root)
  local git_entry = M.path_join(git_root, ".git")
  local git_stat = uv.fs_stat(git_entry)
  if not git_stat then
    return nil, nil
  end

  if git_stat.type == "directory" then
    local normalized = normalize_path(git_entry)
    return normalized, normalized
  end

  if git_stat.type ~= "file" then
    return nil, nil
  end

  local gitdir_line = read_first_line(git_entry)
  local gitdir_path = gitdir_line and gitdir_line:match("^gitdir:%s*(.+)%s*$")
  if not gitdir_path then
    return nil, nil
  end

  local git_dir = resolve_path(git_root, gitdir_path)
  local common_dir = git_dir

  local commondir_path = M.path_join(git_dir, "commondir")
  if M.file_exists(commondir_path) then
    local commondir_line = read_first_line(commondir_path)
    if commondir_line and commondir_line ~= "" then
      common_dir = resolve_path(git_dir, commondir_line)
    end
  end

  return git_dir, common_dir
end

---@param base table
---@param extra table
---@return table
function M.tbl_deep_merge(base, extra)
  return vim.tbl_deep_extend("force", {}, base, extra or {})
end

---@param ... string
---@return string
function M.path_join(...)
  return vim.fs.joinpath(...)
end

---@param path string
---@return string
function M.dirname(path)
  if type(path) ~= "string" or path == "" then
    return "."
  end
  return vim.fs.dirname(path) or "."
end

---@param path string
---@return boolean
function M.file_exists(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil
end

---@param path string
---@return boolean
function M.is_dir(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---@param start_dir string
---@return string|nil
function M.find_git_root(start_dir)
  if type(start_dir) ~= "string" or start_dir == "" then
    return nil
  end

  local cached = git_root_cache[start_dir]
  if cached ~= nil then
    return cached or nil
  end

  local dir = start_dir
  local visited = {}
  while dir and dir ~= "/" do
    table.insert(visited, dir)
    local cached_dir = git_root_cache[dir]
    if cached_dir ~= nil then
      local resolved = cached_dir or nil
      for _, path in ipairs(visited) do
        git_root_cache[path] = cached_dir
      end
      return resolved
    end

    local git_dir = M.path_join(dir, ".git")
    if M.is_dir(git_dir) or M.file_exists(git_dir) then
      for _, path in ipairs(visited) do
        git_root_cache[path] = dir
      end
      return dir
    end
    local parent = M.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  for _, path in ipairs(visited) do
    git_root_cache[path] = false
  end
  git_root_cache[start_dir] = false
  return nil
end

---@class CodeShapeSnapshotScope
---@field project_name string
---@field project_hash string
---@field workspace_name string
---@field workspace_hash string
---@field relative_dir string

---Build snapshot scope key for a git root (project + workspace/worktree)
---@param git_root string
---@return CodeShapeSnapshotScope
function M.get_snapshot_scope(git_root)
  local normalized_root = normalize_path(git_root)
  local _, common_dir = resolve_git_dirs(normalized_root)

  local project_identity = common_dir or normalized_root
  local project_base = project_identity
  if vim.fs.basename(project_base) == ".git" then
    project_base = M.dirname(project_base)
  end

  local project_name = sanitize_segment(vim.fs.basename(project_base), "project")
  local workspace_name = sanitize_segment(vim.fs.basename(normalized_root), "workspace")
  local project_hash = vim.fn.sha256(project_identity):sub(1, 16)
  local workspace_hash = vim.fn.sha256(normalized_root):sub(1, 16)
  local relative_dir = string.format("%s-%s/%s-%s", project_name, project_hash, workspace_name, workspace_hash)

  return {
    project_name = project_name,
    project_hash = project_hash,
    workspace_name = workspace_name,
    workspace_hash = workspace_hash,
    relative_dir = relative_dir,
  }
end

---@param path string|nil
---@return string|nil
function M.shorten_path(path)
  if path == nil or path == vim.NIL then
    return nil
  end
  if type(path) ~= "string" then
    return nil
  end
  if path == "" then
    return path
  end

  local file_dir = M.dirname(path)
  local git_root = M.find_git_root(file_dir)

  if git_root then
    local normalized_root = git_root
    if normalized_root:sub(-1) ~= "/" then
      normalized_root = normalized_root .. "/"
    end
    local relative = path:sub(#normalized_root + 1)
    return relative
  end

  return path
end

---@param uri any
---@return boolean
function M.is_file_uri(uri)
  return type(uri) == "string" and uri:match("^file://") ~= nil
end

---@param uri any
---@return string|nil path
function M.file_uri_to_fname(uri)
  if not M.is_file_uri(uri) then
    return nil
  end

  local ok, path = pcall(vim.uri_to_fname, uri)
  if not ok or type(path) ~= "string" or path == "" then
    return nil
  end
  return path
end

---@param path any
---@return string|nil uri
function M.fname_to_file_uri(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local ok, uri = pcall(vim.uri_from_fname, path)
  if not ok or type(uri) ~= "string" or uri == "" then
    return nil
  end
  return uri
end

---@param uri any
---@return string
function M.uri_display_path(uri)
  if type(uri) ~= "string" or uri == "" then
    return ""
  end
  return M.file_uri_to_fname(uri) or uri
end

-- Single source of truth for SymbolKind mappings
-- LSP SymbolKind: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind
local SYMBOL_KINDS = {
  { name = "File", id = 1 },
  { name = "Module", id = 2 },
  { name = "Namespace", id = 3 },
  { name = "Package", id = 4 },
  { name = "Class", id = 5 },
  { name = "Method", id = 6 },
  { name = "Property", id = 7 },
  { name = "Field", id = 8 },
  { name = "Constructor", id = 9 },
  { name = "Enum", id = 10 },
  { name = "Interface", id = 11 },
  { name = "Function", id = 12 },
  { name = "Variable", id = 13 },
  { name = "Constant", id = 14 },
  { name = "String", id = 15 },
  { name = "Number", id = 16 },
  { name = "Boolean", id = 17 },
  { name = "Array", id = 18 },
  { name = "Object", id = 19 },
  { name = "Key", id = 20 },
  { name = "Null", id = 21 },
  { name = "EnumMember", id = 22 },
  { name = "Struct", id = 23 },
  { name = "Event", id = 24 },
  { name = "Operator", id = 25 },
  { name = "TypeParameter", id = 26 },
}

-- Build lookup tables from the single source
local KIND_NAME_TO_ID = {}
local KIND_ID_TO_NAME = {}
for _, entry in ipairs(SYMBOL_KINDS) do
  KIND_NAME_TO_ID[entry.name] = entry.id
  KIND_ID_TO_NAME[entry.id] = entry.name
end

---Convert LSP SymbolKind to number
---@param kind string|integer
---@return integer
function M.to_symbol_kind(kind)
  if type(kind) == "number" then
    return kind
  end
  return KIND_NAME_TO_ID[kind] or 0
end

---Get display name for SymbolKind
---@param kind integer
---@return string
function M.symbol_kind_name(kind)
  return KIND_ID_TO_NAME[kind] or "Unknown"
end

---Generate stable symbol_id compatible with Rust core (`generate_symbol_id`).
---@param uri string
---@param name string
---@param kind integer
---@param range CodeShapeRange
---@return string
function M.generate_symbol_id(uri, name, kind, range)
  local safe_uri = type(uri) == "string" and uri or ""
  local safe_name = type(name) == "string" and name or ""
  local safe_kind = type(kind) == "number" and kind or 0
  local safe_range = type(range) == "table" and range or {}
  local start_pos = type(safe_range.start) == "table" and safe_range.start or {}
  local end_pos = type(safe_range["end"]) == "table" and safe_range["end"] or {}
  local start_line = type(start_pos.line) == "number" and start_pos.line or 0
  local start_col = type(start_pos.character) == "number" and start_pos.character or 0
  local end_line = type(end_pos.line) == "number" and end_pos.line or 0
  local end_col = type(end_pos.character) == "number" and end_pos.character or 0
  local serialized =
    string.format("%s:%s:%d:%d:%d:%d:%d", safe_uri, safe_name, safe_kind, start_line, start_col, end_line, end_col)
  return vim.fn.sha256(serialized)
end

---Find the code-shape-core binary
---@param plugin_root string|nil Optional plugin root path
---@return string|nil
function M.find_core_binary(plugin_root)
  local candidates = {}

  if plugin_root then
    candidates = {
      M.path_join(plugin_root, "rust", "target", "release", "code-shape-core"),
      M.path_join(plugin_root, "rust", "target", "debug", "code-shape-core"),
      M.path_join(plugin_root, "bin", "code-shape-core"),
    }
  else
    -- Auto-detect plugin root
    local source = debug.getinfo(1, "S").source:sub(2)
    local root = M.dirname(M.dirname(M.dirname(source)))
    if root then
      candidates = {
        M.path_join(root, "rust", "target", "release", "code-shape-core"),
        M.path_join(root, "rust", "target", "debug", "code-shape-core"),
        M.path_join(root, "bin", "code-shape-core"),
      }
    end
  end

  -- Check standard data directory
  local data_dir = vim.fn.stdpath("data")
  if data_dir then
    table.insert(candidates, M.path_join(data_dir, "code-shape", "bin", "code-shape-core"))
  end

  for _, path in ipairs(candidates) do
    if uv.fs_stat(path) then
      return path
    end
  end

  -- Check PATH
  local found = vim.fn.exepath("code-shape-core")
  if found and found ~= "" then
    return found
  end

  return nil
end

return M
