---@class CodeShapePicker
local M = {}

---@type table<string, string>
local backend_modules = {
  telescope = "code-shape.picker.telescope",
  fzf_lua = "code-shape.picker.fzf_lua",
  snacks = "code-shape.picker.snacks",
}

---Open the picker with the configured backend
---@param mode? "defs"|"hotspots"|"impact" Default: "defs"
---@param opts? { picker?: string, base?: string, head?: string, staged?: boolean }
function M.open(mode, opts)
  mode = mode or "defs"
  opts = opts or {}

  local code_shape = require("code-shape")
  code_shape.ensure_setup()

  local config = code_shape.get_config()
  local backend = opts.picker or (config and config.picker) or "builtin"

  if backend == "builtin" then
    if mode == "hotspots" then
      return code_shape.show_hotspots()
    elseif mode == "impact" then
      return code_shape.show_impact(opts)
    end
    return code_shape.open()
  end

  local mod_name = backend_modules[backend]
  if not mod_name then
    vim.notify("code-shape: unknown picker backend '" .. backend .. "'", vim.log.levels.ERROR)
    return
  end

  local ok, picker_mod = pcall(require, mod_name)
  if not ok then
    vim.notify(
      "code-shape: failed to load picker backend '" .. backend .. "'. Is the plugin installed?",
      vim.log.levels.ERROR
    )
    return
  end

  local fn = picker_mod[mode]
  if not fn then
    vim.notify(
      "code-shape: picker backend '" .. backend .. "' does not support mode '" .. mode .. "'",
      vim.log.levels.ERROR
    )
    return
  end

  fn(opts)
end

return M
