---@class CodeShapeHealth
local M = {}

local util = require("code-shape.util")

---@param cmd string[]
---@return string|nil
local function get_command_first_line(cmd)
  if type(vim.system) ~= "function" then
    return nil
  end

  local ok_system, job = pcall(vim.system, cmd, { text = true })
  if not ok_system or type(job) ~= "table" or type(job.wait) ~= "function" then
    return nil
  end

  local ok_wait, result = pcall(job.wait, job)
  if not ok_wait or type(result) ~= "table" or result.code ~= 0 then
    return nil
  end

  local stdout = type(result.stdout) == "string" and result.stdout or ""
  if stdout == "" then
    return nil
  end

  local lines = vim.split(stdout, "\n", { trimempty = true })
  return lines[1]
end

---@return boolean
local function has_git()
  return vim.fn.executable("git") == 1
end

---@return boolean
local function has_lsp_attached()
  local clients = vim.lsp.get_clients()
  return #clients > 0
end

---@return string|nil
local function get_cargo_version()
  return get_command_first_line({ "cargo", "--version" })
end

---@param binary string
---@return string|nil
local function get_core_version(binary)
  return get_command_first_line({ binary, "--version" })
end

---@return string
local function snapshot_base_dir()
  return vim.fs.normalize(vim.fs.joinpath(vim.fn.stdpath("cache"), "code-shape"))
end

---@param dir string
---@return boolean
local function ensure_snapshot_dir(dir)
  local stat = vim.uv.fs_stat(dir)
  if stat then
    return stat.type == "directory"
  end

  local mkdir_ok = vim.fn.mkdir(dir, "p")
  if mkdir_ok == 1 then
    local created = vim.uv.fs_stat(dir)
    return created ~= nil and created.type == "directory"
  end

  local created = vim.uv.fs_stat(dir)
  return created ~= nil and created.type == "directory"
end

function M.check()
  vim.health.start("code-shape.nvim")

  -- Check binary
  local binary = util.find_core_binary()
  if binary then
    vim.health.ok("code-shape-core binary found: " .. binary)
    -- Check if binary is executable
    if vim.fn.executable(binary) == 1 then
      vim.health.ok("Binary is executable")

      local core_version = get_core_version(binary)
      if core_version then
        vim.health.ok("code-shape-core version: " .. core_version)
      else
        vim.health.warn("Failed to read code-shape-core version", { "Run '" .. binary .. " --version' manually" })
      end
    else
      vim.health.warn("Binary may not be executable. Run: chmod +x " .. binary)
    end
  else
    vim.health.error(
      "code-shape-core binary not found",
      { "Build with: cd rust && cargo build --release", "Or download from releases" }
    )
  end

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 1 and vim.system ~= nil then
    vim.health.ok("Neovim version: " .. vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch)
  else
    vim.health.error(
      "Neovim 0.10+ is required",
      { "Current version: " .. vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch }
    )
  end

  -- Check git (for hotspots)
  if has_git() then
    vim.health.ok("git is available (hotspots enabled)")
  else
    vim.health.warn("git not found", { "Hotspots feature will be disabled" })
  end

  -- Check LSP
  if has_lsp_attached() then
    vim.health.ok("LSP clients attached")
  else
    vim.health.info("No LSP clients attached", { "Open a file with LSP support for best results" })
  end

  -- Check local snapshot directory
  local snapshot_dir = snapshot_base_dir()
  if ensure_snapshot_dir(snapshot_dir) then
    vim.health.ok("Snapshot directory ready: " .. snapshot_dir)
  else
    vim.health.error(
      "Snapshot directory is not available: " .. snapshot_dir,
      { "Check permissions for " .. vim.fn.stdpath("cache") }
    )
  end

  -- Check RPC status
  local ok, rpc = pcall(require, "code-shape.rpc")
  if ok then
    if rpc.is_running() then
      vim.health.ok("RPC core is running")
    else
      vim.health.info("RPC core not started yet", { "Run :CodeShape to start" })
    end
  else
    vim.health.error("Failed to load RPC module")
  end

  -- Check tracked git roots
  local roots_ok, roots_mod = pcall(require, "code-shape.roots")
  if roots_ok then
    local roots = roots_mod.get_roots()
    if #roots > 0 then
      vim.health.ok("Tracked git roots: " .. #roots)
      for _, root in ipairs(roots) do
        vim.health.info("  " .. root)
      end
    else
      vim.health.info("No git roots tracked yet", { "Run :CodeShapeIndex to start indexing" })
    end
  end

  -- Check cargo (for development)
  local cargo_version = get_cargo_version()
  if cargo_version then
    vim.health.ok("cargo available: " .. cargo_version)
  else
    vim.health.info("cargo not found (only needed for building from source)")
  end
end

return M
