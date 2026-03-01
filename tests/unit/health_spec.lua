describe("health", function()
  local original_health
  local original_has
  local original_executable
  local original_get_clients
  local original_system
  local original_stdpath
  local original_mkdir
  local original_uv_fs_stat
  local original_util
  local original_rpc

  local health_logs
  local has_nvim_010
  local system_outputs
  local cache_dir
  local snapshot_dir
  local snapshot_stat
  local snapshot_mkdir_success

  ---@param cmd string[]
  ---@return string
  local function command_key(cmd)
    return table.concat(cmd, " ")
  end

  ---@param logs table
  ---@param pattern string
  ---@return boolean
  local function has_message(logs, pattern)
    for _, entry in ipairs(logs) do
      local msg = type(entry) == "table" and entry.msg or entry
      if type(msg) == "string" and msg:find(pattern, 1, true) ~= nil then
        return true
      end
    end
    return false
  end

  local function load_health_module()
    package.loaded["code-shape.health"] = nil
    return require("code-shape.health")
  end

  before_each(function()
    health_logs = {
      ok = {},
      error = {},
      warn = {},
      info = {},
    }
    has_nvim_010 = 1

    original_health = vim.health
    original_has = vim.fn.has
    original_executable = vim.fn.executable
    original_get_clients = vim.lsp.get_clients
    original_system = vim.system
    original_stdpath = vim.fn.stdpath
    original_mkdir = vim.fn.mkdir
    original_uv_fs_stat = vim.uv.fs_stat
    original_util = package.loaded["code-shape.util"]
    original_rpc = package.loaded["code-shape.rpc"]
    cache_dir = "/tmp/code-shape-health-cache"
    snapshot_dir = cache_dir .. "/code-shape"
    snapshot_mkdir_success = true
    snapshot_stat = {
      [snapshot_dir] = { type = "directory" },
    }
    system_outputs = {
      [command_key({ "cargo", "--version" })] = { code = 0, stdout = "cargo 1.75.0\n" },
      [command_key({ "/tmp/code-shape-core", "--version" })] = { code = 0, stdout = "code-shape-core 0.1.0\n" },
    }

    vim.health = {
      start = function() end,
      ok = function(msg)
        table.insert(health_logs.ok, msg)
      end,
      error = function(msg, advice)
        table.insert(health_logs.error, { msg = msg, advice = advice })
      end,
      warn = function(msg, advice)
        table.insert(health_logs.warn, { msg = msg, advice = advice })
      end,
      info = function(msg, advice)
        table.insert(health_logs.info, { msg = msg, advice = advice })
      end,
    }

    vim.fn.has = function(key)
      if key == "nvim-0.10" then
        return has_nvim_010
      end
      return 1
    end

    vim.fn.executable = function(_)
      return 1
    end

    vim.lsp.get_clients = function()
      return {}
    end

    vim.system = function(cmd)
      local key = command_key(cmd)
      local result = system_outputs[key] or { code = 127, stdout = "" }
      return {
        wait = function()
          return vim.deepcopy(result)
        end,
      }
    end

    vim.fn.stdpath = function(kind)
      if kind == "cache" then
        return cache_dir
      end
      if kind == "data" then
        return "/tmp/code-shape-health-data"
      end
      return original_stdpath(kind)
    end

    vim.fn.mkdir = function(path, _)
      if path == snapshot_dir then
        if snapshot_mkdir_success then
          snapshot_stat[path] = { type = "directory" }
          return 1
        end
        return 0
      end
      return original_mkdir(path, "p")
    end

    vim.uv.fs_stat = function(path)
      if snapshot_stat[path] ~= nil then
        return snapshot_stat[path] or nil
      end
      return original_uv_fs_stat(path)
    end

    package.loaded["code-shape.util"] = {
      find_core_binary = function()
        return "/tmp/code-shape-core"
      end,
    }
    package.loaded["code-shape.rpc"] = {
      is_running = function()
        return false
      end,
    }
  end)

  after_each(function()
    vim.health = original_health
    vim.fn.has = original_has
    vim.fn.executable = original_executable
    vim.lsp.get_clients = original_get_clients
    vim.system = original_system
    vim.fn.stdpath = original_stdpath
    vim.fn.mkdir = original_mkdir
    vim.uv.fs_stat = original_uv_fs_stat

    package.loaded["code-shape.util"] = original_util
    package.loaded["code-shape.rpc"] = original_rpc
    package.loaded["code-shape.health"] = nil
  end)

  it("reports Neovim 0.10+ requirement when unavailable", function()
    has_nvim_010 = 0
    local health = load_health_module()
    health.check()

    assert.is_true(#health_logs.error > 0)
    assert.are.equal("Neovim 0.10+ is required", health_logs.error[1].msg)
  end)

  it("accepts Neovim 0.10+ and vim.system availability", function()
    local health = load_health_module()
    health.check()

    assert.is_true(has_message(health_logs.ok, "Neovim version:"))
  end)

  it("reports core binary version", function()
    local health = load_health_module()
    health.check()

    assert.is_true(has_message(health_logs.ok, "code-shape-core version: code-shape-core 0.1.0"))
  end)

  it("warns when core binary version command fails", function()
    system_outputs[command_key({ "/tmp/code-shape-core", "--version" })] = { code = 1, stdout = "" }

    local health = load_health_module()
    health.check()

    assert.is_true(has_message(health_logs.warn, "Failed to read code-shape-core version"))
  end)

  it("checks snapshot directory readiness", function()
    local health = load_health_module()
    health.check()

    assert.is_true(has_message(health_logs.ok, "Snapshot directory ready: " .. snapshot_dir))
  end)

  it("reports snapshot directory errors when creation fails", function()
    snapshot_stat[snapshot_dir] = false
    snapshot_mkdir_success = false

    local health = load_health_module()
    health.check()

    assert.is_true(has_message(health_logs.error, "Snapshot directory is not available: " .. snapshot_dir))
  end)

  it("reports cargo version via vim.system", function()
    local health = load_health_module()
    health.check()

    assert.is_true(has_message(health_logs.ok, "cargo available: cargo 1.75.0"))
  end)

  it("reports cargo missing when command fails", function()
    system_outputs[command_key({ "cargo", "--version" })] = { code = 127, stdout = "" }
    local health = load_health_module()
    health.check()

    assert.is_true(has_message(health_logs.info, "cargo not found"))
  end)
end)
