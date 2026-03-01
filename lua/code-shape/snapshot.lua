---@class CodeShapeSnapshot
local M = {}

local util = require("code-shape.util")
local uv = vim.uv

local LOAD_TIMEOUT_MS = 5000
local SAVE_TIMEOUT_MS = 10000
local DIRECTORY_MODE = 493 -- 0755

---@param cb? fun(success: boolean, err: string|nil)
---@param success boolean
---@param err string|nil
local function finish(cb, success, err)
  if cb then
    cb(success, err)
  end
end

---@param config CodeShapeConfig
---@return CodeShapeSnapshotRemoteCacheConfig|nil
local function remote_cache_config(config)
  local snapshot_cfg = config and config.snapshot
  if type(snapshot_cfg) ~= "table" then
    return nil
  end

  local remote_cfg = snapshot_cfg.remote_cache
  if type(remote_cfg) ~= "table" or not remote_cfg.enabled then
    return nil
  end

  if type(remote_cfg.dir) ~= "string" or remote_cfg.dir == "" then
    return nil
  end

  return remote_cfg
end

---@param dst_path string
---@return string
local function build_temp_path(dst_path)
  local nonce = tostring(uv.hrtime())
  local pid = tostring(vim.fn.getpid())
  return string.format("%s.tmp.%s.%s", dst_path, pid, nonce)
end

---@param path string
---@return boolean, string|nil
local function ensure_parent_dir(path)
  local parent = util.dirname(path)
  if parent == "." or parent == "" then
    return true, nil
  end

  if util.is_dir(parent) then
    return true, nil
  end

  local missing_dirs = {}
  local current = parent
  while current ~= "." and current ~= "" and not util.is_dir(current) do
    table.insert(missing_dirs, current)
    local next_parent = util.dirname(current)
    if next_parent == current then
      break
    end
    current = next_parent
  end

  for idx = #missing_dirs, 1, -1 do
    local dir = missing_dirs[idx]
    local ok, mkdir_err, mkdir_name = uv.fs_mkdir(dir, DIRECTORY_MODE)
    if not ok and not util.is_dir(dir) then
      local err_msg = tostring(mkdir_err or mkdir_name or "unknown")
      return false, string.format("failed to create directory %s: %s", dir, err_msg)
    end
  end

  if not util.is_dir(parent) then
    return false, "failed to create directory: " .. parent
  end

  return true, nil
end

---@param src_path string
---@param dst_path string
---@return boolean, string|nil
local function copy_file_atomic(src_path, dst_path)
  if vim.fs.normalize(src_path) == vim.fs.normalize(dst_path) then
    return true, nil
  end

  if not util.file_exists(src_path) then
    return false, "source file not found: " .. src_path
  end

  local ok_dir, dir_err = ensure_parent_dir(dst_path)
  if not ok_dir then
    return false, dir_err
  end

  local tmp_path = build_temp_path(dst_path)
  local copied, copy_err, copy_name = uv.fs_copyfile(src_path, tmp_path)
  if not copied then
    return false, tostring(copy_err or copy_name or "failed to copy snapshot")
  end

  local renamed, rename_err, rename_name = uv.fs_rename(tmp_path, dst_path)
  if not renamed then
    uv.fs_unlink(tmp_path)
    return false, tostring(rename_err or rename_name or "failed to rename snapshot")
  end

  return true, nil
end

---@param git_root string
---@param base_dir string
---@return string
local function build_snapshot_path(git_root, base_dir)
  local scope = util.get_snapshot_scope(git_root)
  return util.path_join(base_dir, scope.relative_dir, "index.bin")
end

---@return string
local function local_base_dir()
  return util.path_join(vim.fn.stdpath("cache"), "code-shape")
end

---Get snapshot path for a specific git root
---@param git_root string
---@return string
function M.get_path_for_root(git_root)
  return build_snapshot_path(git_root, local_base_dir())
end

---Get remote snapshot path for a specific git root
---@param config CodeShapeConfig
---@param git_root string
---@return string|nil
function M.get_remote_path_for_root(config, git_root)
  local remote_cfg = remote_cache_config(config)
  if not remote_cfg then
    return nil
  end

  return build_snapshot_path(git_root, vim.fs.normalize(remote_cfg.dir))
end

---@param config CodeShapeConfig
---@param root string
---@param local_path string
---@return boolean, string|nil
local function pull_remote_snapshot(config, root, local_path)
  local remote_cfg = remote_cache_config(config)
  if not remote_cfg or not remote_cfg.load_on_start then
    return true, nil
  end

  local remote_path = M.get_remote_path_for_root(config, root)
  if not remote_path or not util.file_exists(remote_path) then
    return true, nil
  end

  local copied, copy_err = copy_file_atomic(remote_path, local_path)
  if not copied then
    return false, "failed to pull remote snapshot for " .. root .. ": " .. copy_err
  end

  if config.debug then
    vim.notify("code-shape: pulled remote snapshot for " .. root, vim.log.levels.DEBUG)
  end

  return true, nil
end

---@param config CodeShapeConfig
---@param root string
---@param local_path string
---@return boolean, string|nil
local function push_remote_snapshot(config, root, local_path)
  local remote_cfg = remote_cache_config(config)
  if not remote_cfg or not remote_cfg.save_on_exit then
    return true, nil
  end

  local remote_path = M.get_remote_path_for_root(config, root)
  if not remote_path then
    return true, nil
  end

  local copied, copy_err = copy_file_atomic(local_path, remote_path)
  if not copied then
    return false, "failed to push remote snapshot for " .. root .. ": " .. copy_err
  end

  if config.debug then
    vim.notify("code-shape: pushed remote snapshot for " .. root, vim.log.levels.DEBUG)
  end

  return true, nil
end

---Load per-root snapshots
---@param rpc table
---@param config CodeShapeConfig
---@param cb? fun(success: boolean, err: string|nil)
function M.load(rpc, config, cb)
  if not config.snapshot.enabled or not config.snapshot.load_on_start then
    finish(cb, false, nil)
    return
  end

  local roots_mod = require("code-shape.roots")
  local roots = roots_mod.get_roots()

  -- On initial startup, roots may be empty. Try cwd as fallback.
  if #roots == 0 then
    local cwd = vim.fn.getcwd()
    local git_root = util.find_git_root(cwd)
    if git_root then
      roots = { git_root }
    end
  end

  if #roots == 0 then
    finish(cb, false, nil)
    return
  end

  local pending_count = #roots
  local loaded_any = false
  local first_error = nil

  for _, root in ipairs(roots) do
    local path = M.get_path_for_root(root)
    local pulled, pull_err = pull_remote_snapshot(config, root, path)
    if not pulled then
      first_error = first_error or pull_err
      vim.notify("code-shape: " .. pull_err, vim.log.levels.WARN)
    end

    rpc.request("index/snapshotExists", { path = path }, function(exists_err, exists_result)
      if exists_err or type(exists_result) ~= "table" or exists_result.exists ~= true then
        pending_count = pending_count - 1
        if pending_count == 0 then
          finish(cb, loaded_any, first_error)
        end
        return
      end

      rpc.request("index/loadSnapshotForRoot", { path = path }, function(load_err, load_result)
        if load_err then
          first_error = first_error or load_err
        elseif type(load_result) == "table" and load_result.success then
          loaded_any = true
          if config.debug then
            local symbols = tonumber(load_result.symbol_count) or 0
            local uris = tonumber(load_result.uri_count) or 0
            vim.notify(
              string.format("code-shape: loaded snapshot for %s (%d symbols / %d files)", root, symbols, uris),
              vim.log.levels.DEBUG
            )
          end
        end

        pending_count = pending_count - 1
        if pending_count == 0 then
          finish(cb, loaded_any, first_error)
        end
      end, { timeout_ms = LOAD_TIMEOUT_MS })
    end, { timeout_ms = 2000 })
  end
end

---Save per-root snapshots
---@param rpc table
---@param config CodeShapeConfig
---@param cb? fun(success: boolean, err: string|nil)
function M.save(rpc, config, cb)
  if not config.snapshot.enabled or not config.snapshot.save_on_exit then
    finish(cb, false, nil)
    return
  end

  local roots_mod = require("code-shape.roots")
  local roots = roots_mod.get_roots()

  if #roots == 0 then
    finish(cb, false, nil)
    return
  end

  local pending_count = #roots
  local saved_any = false
  local first_error = nil

  for _, root in ipairs(roots) do
    local path = M.get_path_for_root(root)
    local uri_prefix = util.fname_to_file_uri(root)
    if uri_prefix then
      -- Ensure trailing slash for prefix matching
      if not uri_prefix:match("/$") then
        uri_prefix = uri_prefix .. "/"
      end

      rpc.request("index/saveSnapshotForRoot", {
        path = path,
        uri_prefix = uri_prefix,
      }, function(save_err, save_result)
        if save_err then
          first_error = first_error or save_err
          vim.notify("code-shape: failed to save snapshot for " .. root .. ": " .. save_err, vim.log.levels.WARN)
        elseif type(save_result) == "table" and save_result.success then
          saved_any = true
          local pushed, push_err = push_remote_snapshot(config, root, path)
          if not pushed then
            first_error = first_error or push_err
            vim.notify("code-shape: " .. push_err, vim.log.levels.WARN)
          end
        end

        pending_count = pending_count - 1
        if pending_count == 0 then
          finish(cb, saved_any, first_error)
        end
      end, { timeout_ms = SAVE_TIMEOUT_MS })
    else
      pending_count = pending_count - 1
      if pending_count == 0 then
        finish(cb, saved_any, first_error)
      end
    end
  end
end

return M
