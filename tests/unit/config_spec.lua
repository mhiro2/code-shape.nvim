local config = require("code-shape.config")

describe("config validation", function()
  it("accepts valid configuration", function()
    local cfg = config.setup({
      ui = {
        width = 0.9,
        height = 0.9,
        border = "double",
        preview = false,
      },
      search = {
        limit = 100,
        debounce_ms = 200,
      },
      hotspots = {
        enabled = false,
        since = "1 month ago",
        max_files = 500,
      },
      keymaps = {
        select = "<Space>",
      },
      snapshot = {
        enabled = true,
        load_on_start = true,
        save_on_exit = false,
        remote_cache = {
          enabled = true,
          dir = "/tmp/code-shape-remote",
          load_on_start = true,
          save_on_exit = false,
        },
      },
      debug = true,
    })

    assert.are.equal(0.9, cfg.ui.width)
    assert.are.equal(0.9, cfg.ui.height)
    assert.are.equal("double", cfg.ui.border)
    assert.is_false(cfg.ui.preview)
    assert.are.equal(100, cfg.search.limit)
    assert.are.equal(200, cfg.search.debounce_ms)
    assert.is_false(cfg.hotspots.enabled)
    assert.are.equal("1 month ago", cfg.hotspots.since)
    assert.are.equal(500, cfg.hotspots.max_files)
    assert.are.equal("<Space>", cfg.keymaps.select)
    assert.is_true(cfg.snapshot.load_on_start)
    assert.is_false(cfg.snapshot.save_on_exit)
    assert.is_true(cfg.snapshot.remote_cache.enabled)
    assert.are.equal("/tmp/code-shape-remote", cfg.snapshot.remote_cache.dir)
    assert.is_false(cfg.snapshot.remote_cache.save_on_exit)
    assert.is_true(cfg.debug)
  end)

  it("validates ui.width", function()
    local _notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(_notify_calls, { msg = msg, level = level })
    end

    -- Invalid: absolute width must be integer
    local cfg1 = config.setup({ ui = { width = 1.5 } })
    assert.are.equal(0.8, cfg1.ui.width)

    -- Invalid: negative
    local cfg2 = config.setup({ ui = { width = -0.5 } })
    assert.are.equal(0.8, cfg2.ui.width)

    -- Invalid: not a number
    local cfg3 = config.setup({ ui = { width = "large" } })
    assert.are.equal(0.8, cfg3.ui.width)

    -- Valid: absolute columns
    local cfg4 = config.setup({ ui = { width = 120 } })
    assert.are.equal(120, cfg4.ui.width)

    vim.notify = original_notify
  end)

  it("validates ui.height", function()
    local _notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(_notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({ ui = { height = 2.0 } })
    assert.are.equal(0.8, cfg.ui.height)

    vim.notify = original_notify
  end)

  it("validates ui.border", function()
    local _notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(_notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({ ui = { border = "fancy" } })
    assert.are.equal("rounded", cfg.ui.border)

    vim.notify = original_notify
  end)

  it("validates search.limit", function()
    local _notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(_notify_calls, { msg = msg, level = level })
    end

    -- Invalid: negative
    local cfg1 = config.setup({ search = { limit = -10 } })
    assert.are.equal(50, cfg1.search.limit)

    -- Invalid: zero
    local cfg2 = config.setup({ search = { limit = 0 } })
    assert.are.equal(50, cfg2.search.limit)

    vim.notify = original_notify
  end)

  it("handles nil opts", function()
    local cfg = config.setup(nil)
    assert.are.equal(0.8, cfg.ui.width)
    assert.are.equal("rounded", cfg.ui.border)
    assert.are.equal(50, cfg.search.limit)
  end)

  it("handles empty opts", function()
    local cfg = config.setup({})
    assert.are.equal(0.8, cfg.ui.width)
    assert.is_true(cfg.ui.preview)
    assert.is_true(cfg.hotspots.enabled)
    assert.is_true(cfg.metrics.enabled)
    assert.are.equal(50, cfg.metrics.complexity_cap)
    assert.are.equal("<CR>", cfg.keymaps.select)
    assert.is_true(cfg.snapshot.enabled)
  end)

  it("merges partial config with defaults", function()
    local cfg = config.setup({
      search = { limit = 100 },
    })

    assert.are.equal(0.8, cfg.ui.width) -- default
    assert.are.equal(100, cfg.search.limit) -- overridden
    assert.is_true(cfg.hotspots.enabled) -- default
  end)

  it("keeps debug option when provided", function()
    local cfg = config.setup({ debug = true })
    assert.is_true(cfg.debug)
  end)

  it("warns unknown keys", function()
    local notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_calls, { msg = msg, level = level })
    end

    local cfg = config.setup({
      ui = { invalid_key = 0.9 },
      unknown = true,
    })

    assert.are.equal(0.8, cfg.ui.width)
    assert.is_true(#notify_calls > 0)
    assert.is_true(notify_calls[1].msg:find("unknown config key: ui.invalid_key", 1, true) ~= nil)
    assert.is_true(notify_calls[1].msg:find("unknown config key: unknown", 1, true) ~= nil)

    vim.notify = original_notify
  end)

  it("validates keymaps values", function()
    local cfg = config.setup({
      keymaps = {
        select = 123,
        graph_follow = 123,
      },
    })

    assert.are.equal("<CR>", cfg.keymaps.select)
    assert.are.equal("l", cfg.keymaps.graph_follow)
  end)

  it("validates snapshot values", function()
    local cfg = config.setup({
      snapshot = {
        enabled = "yes",
        load_on_start = 1,
        save_on_exit = 1,
        remote_cache = {
          enabled = "yes",
          dir = "",
          load_on_start = 1,
          save_on_exit = 1,
        },
      },
    })

    assert.is_true(cfg.snapshot.enabled)
    assert.is_true(cfg.snapshot.load_on_start)
    assert.is_true(cfg.snapshot.save_on_exit)
    assert.is_false(cfg.snapshot.remote_cache.enabled)
    assert.is_nil(cfg.snapshot.remote_cache.dir)
    assert.is_true(cfg.snapshot.remote_cache.load_on_start)
    assert.is_true(cfg.snapshot.remote_cache.save_on_exit)
  end)

  it("validates ui.preview type", function()
    local cfg = config.setup({
      ui = {
        preview = "enabled",
      },
    })

    assert.is_true(cfg.ui.preview)
  end)

  it("validates table sections and falls back to defaults", function()
    local cfg = config.setup({
      ui = "invalid",
      search = "invalid",
      hotspots = "invalid",
    })

    assert.are.equal(0.8, cfg.ui.width)
    assert.are.equal(50, cfg.search.limit)
    assert.is_true(cfg.hotspots.enabled)
  end)

  it("requires integer search values", function()
    local cfg = config.setup({
      search = {
        limit = 10.5,
        debounce_ms = 12.1,
      },
    })

    assert.are.equal(50, cfg.search.limit)
    assert.are.equal(100, cfg.search.debounce_ms)
  end)

  it("validates metrics config", function()
    local _notify_calls = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(_notify_calls, { msg = msg, level = level })
    end

    -- Valid config
    local cfg = config.setup({
      metrics = {
        enabled = false,
        complexity_cap = 100,
      },
    })
    assert.is_false(cfg.metrics.enabled)
    assert.are.equal(100, cfg.metrics.complexity_cap)

    -- Invalid enabled type
    local cfg2 = config.setup({ metrics = { enabled = "yes" } })
    assert.is_true(cfg2.metrics.enabled)

    -- Invalid complexity_cap
    local cfg3 = config.setup({ metrics = { complexity_cap = -10 } })
    assert.are.equal(50, cfg3.metrics.complexity_cap)

    -- Non-integer complexity_cap
    local cfg4 = config.setup({ metrics = { complexity_cap = 25.5 } })
    assert.are.equal(50, cfg4.metrics.complexity_cap)

    -- Non-table metrics
    local cfg5 = config.setup({ metrics = "invalid" })
    assert.is_true(cfg5.metrics.enabled)
    assert.are.equal(50, cfg5.metrics.complexity_cap)

    vim.notify = original_notify
  end)

  it("validates optional hotspots fields", function()
    local cfg = config.setup({
      hotspots = {
        enabled = true,
        since = "2 weeks ago",
        max_files = 200,
        half_life_days = 0,
        use_churn = "yes",
      },
    })

    assert.are.equal(200, cfg.hotspots.max_files)
    assert.is_nil(cfg.hotspots.half_life_days)
    assert.is_nil(cfg.hotspots.use_churn)
  end)
end)
