if vim.g.loaded_code_shape then
  return
end
vim.g.loaded_code_shape = true

local MINIMUM_NVIM_VERSION = "0.10.0"
local unsupported_notified = false

---@return boolean
local function ensure_minimum_neovim()
  local supported = vim.fn.has("nvim-0.10") == 1 and type(vim.system) == "function" and type(vim.islist) == "function"
  if supported then
    return true
  end

  if not unsupported_notified then
    unsupported_notified = true
    vim.notify("code-shape.nvim requires Neovim >= " .. MINIMUM_NVIM_VERSION, vim.log.levels.ERROR)
  end

  return false
end

local function with_module(fn)
  if not ensure_minimum_neovim() then
    return nil
  end
  local mod = require("code-shape")
  mod.ensure_setup()
  return fn(mod)
end

-- Main command: Open search UI
vim.api.nvim_create_user_command("CodeShape", function()
  with_module(function(mod)
    mod.open()
  end)
end, {})

-- Index commands
vim.api.nvim_create_user_command("CodeShapeIndex", function()
  with_module(function(mod)
    mod.index_open_buffers()
  end)
end, {})

vim.api.nvim_create_user_command("CodeShapeReindex", function()
  with_module(function(mod)
    mod.reindex()
  end)
end, {})

vim.api.nvim_create_user_command("CodeShapeIndexCancel", function()
  with_module(function(mod)
    mod.cancel_workspace_index()
  end)
end, {})

vim.api.nvim_create_user_command("CodeShapeClear", function()
  with_module(function(mod)
    mod.clear()
  end)
end, {})

vim.api.nvim_create_user_command("CodeShapeStatus", function()
  with_module(function(mod)
    mod.status()
  end)
end, {})

vim.api.nvim_create_user_command("CodeShapeHotspots", function()
  with_module(function(mod)
    mod.show_hotspots()
  end)
end, {})

-- Picker-specific commands
vim.api.nvim_create_user_command("CodeShapeTelescope", function(args)
  with_module(function(_)
    local picker = require("code-shape.picker")
    local mode = args.args ~= "" and args.args or "defs"
    picker.open(mode, { picker = "telescope" })
  end)
end, {
  nargs = "?",
  complete = function()
    return { "defs", "hotspots", "impact" }
  end,
})

vim.api.nvim_create_user_command("CodeShapeFzf", function(args)
  with_module(function(_)
    local picker = require("code-shape.picker")
    local mode = args.args ~= "" and args.args or "defs"
    picker.open(mode, { picker = "fzf_lua" })
  end)
end, {
  nargs = "?",
  complete = function()
    return { "defs", "hotspots", "impact" }
  end,
})

vim.api.nvim_create_user_command("CodeShapeSnacks", function(args)
  with_module(function(_)
    local picker = require("code-shape.picker")
    local mode = args.args ~= "" and args.args or "defs"
    picker.open(mode, { picker = "snacks" })
  end)
end, {
  nargs = "?",
  complete = function()
    return { "defs", "hotspots", "impact" }
  end,
})

-- Open Calls mode for symbol under cursor (useful for external picker users)
vim.api.nvim_create_user_command("CodeShapeCallsFromCursor", function()
  with_module(function(mod)
    mod.open_calls_from_cursor()
  end)
end, {})

-- Impact analysis commands
vim.api.nvim_create_user_command("CodeShapeDiffImpact", function(args)
  with_module(function(mod)
    local opts = {}
    for _, arg in ipairs(args.fargs) do
      if arg:match("^%-%-base=") then
        opts.base = arg:sub(8)
      elseif arg:match("^%-%-head=") then
        opts.head = arg:sub(8)
      elseif arg == "--staged" then
        opts.staged = true
      elseif not arg:match("^%-%-") then
        -- First non-flag argument is base
        if not opts.base then
          opts.base = arg
        end
      end
    end
    mod.show_impact(opts)
  end)
end, {
  desc = "Show impact analysis for diff (risk-ordered review recommendation)",
  nargs = "*",
  complete = function(_, cmdline, _)
    local completions = {}
    if not cmdline:match("%-%-base=") then
      table.insert(completions, "--base=")
    end
    if not cmdline:match("%-%-head=") then
      table.insert(completions, "--head=")
    end
    if not cmdline:match("%-%-staged") then
      table.insert(completions, "--staged")
    end
    return completions
  end,
})
