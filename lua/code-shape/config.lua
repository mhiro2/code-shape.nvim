require("code-shape.types")

local M = {}

local util

---@return CodeShapeUtil
local function get_util()
  util = util or require("code-shape.util")
  return util
end

---@type CodeShapeConfig
local defaults = {
  ui = {
    width = 0.8,
    height = 0.8,
    border = "rounded",
    preview = true,
  },
  search = {
    limit = 50,
    debounce_ms = 100,
  },
  hotspots = {
    enabled = true,
    since = "3 months ago",
    max_files = 1000,
  },
  metrics = {
    enabled = true,
    complexity_cap = 50,
  },
  keymaps = {
    select = "<CR>",
    open_vsplit = "<C-v>",
    open_split = "<C-s>",
    prev = "k",
    prev_alt = "<Up>",
    next = "j",
    next_alt = "<Down>",
    prev_insert = "<C-p>",
    next_insert = "<C-n>",
    mode_next = "<Tab>",
    mode_prev = "<S-Tab>",
    cycle_kind_filter = "t",
    goto_definition = "gd",
    show_references = "gr",
    show_calls = "gc",
    graph_follow = "l",
    graph_back = "h",
    graph_refresh = "r",
    close = "q",
    close_alt = "<Esc>",
  },
  snapshot = {
    enabled = true,
    load_on_start = true,
    save_on_exit = true,
    remote_cache = {
      enabled = false,
      dir = nil,
      load_on_start = true,
      save_on_exit = true,
    },
  },
  picker = nil,
  debug = false,
}

---@type table<string, table|boolean>
local known_keys = {
  ui = {
    width = true,
    height = true,
    border = true,
    preview = true,
  },
  search = {
    limit = true,
    debounce_ms = true,
  },
  hotspots = {
    enabled = true,
    since = true,
    max_files = true,
    half_life_days = true,
    use_churn = true,
  },
  metrics = {
    enabled = true,
    complexity_cap = true,
  },
  keymaps = {
    select = true,
    open_vsplit = true,
    open_split = true,
    prev = true,
    prev_alt = true,
    next = true,
    next_alt = true,
    prev_insert = true,
    next_insert = true,
    mode_next = true,
    mode_prev = true,
    cycle_kind_filter = true,
    goto_definition = true,
    show_references = true,
    show_calls = true,
    graph_follow = true,
    graph_back = true,
    graph_refresh = true,
    close = true,
    close_alt = true,
  },
  snapshot = {
    enabled = true,
    load_on_start = true,
    save_on_exit = true,
    remote_cache = {
      enabled = true,
      dir = true,
      load_on_start = true,
      save_on_exit = true,
    },
  },
  picker = true,
  debug = true,
}

---@param opts table
---@param schema table<string, table|boolean>
---@param path_prefix string
---@param warnings string[]
local function collect_unknown_keys(opts, schema, path_prefix, warnings)
  for key, value in pairs(opts) do
    local expected = schema[key]
    local full_key = path_prefix ~= "" and (path_prefix .. "." .. key) or key
    if expected == nil then
      table.insert(warnings, "unknown config key: " .. full_key)
    elseif type(expected) == "table" and type(value) == "table" then
      collect_unknown_keys(value, expected, full_key, warnings)
    end
  end
end

---@param value any
---@return boolean
local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

---@param value any
---@return boolean
local function is_positive_integer(value)
  return is_integer(value) and value >= 1
end

---@param value any
---@return boolean
local function is_non_negative_integer(value)
  return is_integer(value) and value >= 0
end

---@param value any
---@return boolean
local function is_valid_ui_width(value)
  if type(value) ~= "number" or value <= 0 then
    return false
  end
  if value <= 1 then
    return true
  end
  return is_integer(value)
end

---@param opts CodeShapeConfig|nil
---@return CodeShapeConfig
function M.setup(opts)
  local warnings = {}

  if opts ~= nil and type(opts) ~= "table" then
    table.insert(warnings, "setup options must be a table, got " .. type(opts))
    opts = {}
  end

  if opts then
    collect_unknown_keys(opts, known_keys, "", warnings)
  end

  local merged = get_util().tbl_deep_merge(defaults, opts or {})
  M._validate(merged, warnings)
  return merged
end

---@param config CodeShapeConfig
---@param warnings string[]|nil
function M._validate(config, warnings)
  warnings = warnings or {}

  -- Validate ui
  if type(config.ui) ~= "table" then
    table.insert(warnings, "ui must be a table")
    config.ui = vim.deepcopy(defaults.ui)
  else
    if not is_valid_ui_width(config.ui.width) then
      table.insert(
        warnings,
        "ui.width must be a ratio (0 < width <= 1) or integer columns (width >= 1), got " .. tostring(config.ui.width)
      )
      config.ui.width = defaults.ui.width
    end

    if type(config.ui.height) ~= "number" or config.ui.height <= 0 or config.ui.height > 1 then
      table.insert(warnings, "ui.height must be a number between 0 and 1, got " .. tostring(config.ui.height))
      config.ui.height = defaults.ui.height
    end

    local valid_borders = { "none", "single", "double", "rounded", "solid", "shadow" }
    if type(config.ui.border) ~= "string" or not vim.tbl_contains(valid_borders, config.ui.border) then
      table.insert(warnings, "ui.border must be one of: " .. table.concat(valid_borders, ", "))
      config.ui.border = defaults.ui.border
    end

    if type(config.ui.preview) ~= "boolean" then
      table.insert(warnings, "ui.preview must be a boolean, got " .. tostring(config.ui.preview))
      config.ui.preview = defaults.ui.preview
    end
  end

  -- Validate search
  if type(config.search) ~= "table" then
    table.insert(warnings, "search must be a table")
    config.search = vim.deepcopy(defaults.search)
  else
    if not is_positive_integer(config.search.limit) then
      table.insert(warnings, "search.limit must be a positive integer, got " .. tostring(config.search.limit))
      config.search.limit = defaults.search.limit
    end

    if not is_non_negative_integer(config.search.debounce_ms) then
      table.insert(
        warnings,
        "search.debounce_ms must be a non-negative integer, got " .. tostring(config.search.debounce_ms)
      )
      config.search.debounce_ms = defaults.search.debounce_ms
    end
  end

  -- Validate hotspots
  if type(config.hotspots) ~= "table" then
    table.insert(warnings, "hotspots must be a table")
    config.hotspots = vim.deepcopy(defaults.hotspots)
  else
    if type(config.hotspots.enabled) ~= "boolean" then
      table.insert(warnings, "hotspots.enabled must be a boolean, got " .. type(config.hotspots.enabled))
      config.hotspots.enabled = defaults.hotspots.enabled
    end

    if type(config.hotspots.since) ~= "string" or config.hotspots.since == "" then
      table.insert(warnings, "hotspots.since must be a non-empty string, got " .. tostring(config.hotspots.since))
      config.hotspots.since = defaults.hotspots.since
    end

    if not is_positive_integer(config.hotspots.max_files) then
      table.insert(
        warnings,
        "hotspots.max_files must be a positive integer, got " .. tostring(config.hotspots.max_files)
      )
      config.hotspots.max_files = defaults.hotspots.max_files
    end

    if config.hotspots.half_life_days ~= nil and not is_positive_integer(config.hotspots.half_life_days) then
      table.insert(
        warnings,
        "hotspots.half_life_days must be a positive integer, got " .. tostring(config.hotspots.half_life_days)
      )
      config.hotspots.half_life_days = nil
    end

    if config.hotspots.use_churn ~= nil and type(config.hotspots.use_churn) ~= "boolean" then
      table.insert(warnings, "hotspots.use_churn must be a boolean, got " .. tostring(config.hotspots.use_churn))
      config.hotspots.use_churn = nil
    end
  end

  -- Validate metrics
  if type(config.metrics) ~= "table" then
    table.insert(warnings, "metrics must be a table")
    config.metrics = vim.deepcopy(defaults.metrics)
  else
    if type(config.metrics.enabled) ~= "boolean" then
      table.insert(warnings, "metrics.enabled must be a boolean, got " .. type(config.metrics.enabled))
      config.metrics.enabled = defaults.metrics.enabled
    end

    if not is_positive_integer(config.metrics.complexity_cap) then
      table.insert(
        warnings,
        "metrics.complexity_cap must be a positive integer, got " .. tostring(config.metrics.complexity_cap)
      )
      config.metrics.complexity_cap = defaults.metrics.complexity_cap
    end
  end

  -- Validate keymaps
  if type(config.keymaps) ~= "table" then
    table.insert(warnings, "keymaps must be a table")
    config.keymaps = vim.deepcopy(defaults.keymaps)
  else
    for key, default_value in pairs(defaults.keymaps) do
      local value = config.keymaps[key]
      if type(value) ~= "string" or value == "" then
        table.insert(warnings, "keymaps." .. key .. " must be a non-empty string")
        config.keymaps[key] = default_value
      end
    end
  end

  -- Validate snapshot settings
  if type(config.snapshot) ~= "table" then
    table.insert(warnings, "snapshot must be a table")
    config.snapshot = vim.deepcopy(defaults.snapshot)
  else
    if type(config.snapshot.enabled) ~= "boolean" then
      table.insert(warnings, "snapshot.enabled must be a boolean")
      config.snapshot.enabled = defaults.snapshot.enabled
    end
    if type(config.snapshot.load_on_start) ~= "boolean" then
      table.insert(warnings, "snapshot.load_on_start must be a boolean")
      config.snapshot.load_on_start = defaults.snapshot.load_on_start
    end
    if type(config.snapshot.save_on_exit) ~= "boolean" then
      table.insert(warnings, "snapshot.save_on_exit must be a boolean")
      config.snapshot.save_on_exit = defaults.snapshot.save_on_exit
    end

    if type(config.snapshot.remote_cache) ~= "table" then
      table.insert(warnings, "snapshot.remote_cache must be a table")
      config.snapshot.remote_cache = vim.deepcopy(defaults.snapshot.remote_cache)
    else
      if type(config.snapshot.remote_cache.enabled) ~= "boolean" then
        table.insert(warnings, "snapshot.remote_cache.enabled must be a boolean")
        config.snapshot.remote_cache.enabled = defaults.snapshot.remote_cache.enabled
      end

      if config.snapshot.remote_cache.dir ~= nil then
        if type(config.snapshot.remote_cache.dir) ~= "string" or config.snapshot.remote_cache.dir == "" then
          table.insert(warnings, "snapshot.remote_cache.dir must be a non-empty string or nil")
          config.snapshot.remote_cache.dir = defaults.snapshot.remote_cache.dir
        else
          config.snapshot.remote_cache.dir = vim.fs.normalize(config.snapshot.remote_cache.dir)
        end
      end

      if type(config.snapshot.remote_cache.load_on_start) ~= "boolean" then
        table.insert(warnings, "snapshot.remote_cache.load_on_start must be a boolean")
        config.snapshot.remote_cache.load_on_start = defaults.snapshot.remote_cache.load_on_start
      end

      if type(config.snapshot.remote_cache.save_on_exit) ~= "boolean" then
        table.insert(warnings, "snapshot.remote_cache.save_on_exit must be a boolean")
        config.snapshot.remote_cache.save_on_exit = defaults.snapshot.remote_cache.save_on_exit
      end
    end
  end

  -- Validate picker
  if config.picker ~= nil then
    local valid_pickers = { "builtin", "telescope", "fzf_lua", "snacks" }
    if type(config.picker) ~= "string" or not vim.tbl_contains(valid_pickers, config.picker) then
      table.insert(warnings, "picker must be one of: " .. table.concat(valid_pickers, ", "))
      config.picker = nil
    end
  end

  -- Validate debug
  if type(config.debug) ~= "boolean" then
    table.insert(warnings, "debug must be a boolean")
    config.debug = defaults.debug
  end

  -- Report warnings
  if #warnings > 0 then
    vim.notify("code-shape: invalid configuration:\n" .. table.concat(warnings, "\n"), vim.log.levels.WARN)
  end
end

return M
