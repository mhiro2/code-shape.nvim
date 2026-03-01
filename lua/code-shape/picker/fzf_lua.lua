---@class CodeShapePickerFzfLua
local M = {}

local picker_utils = require("code-shape.picker.utils")
local util = require("code-shape.util")

---@alias CodeShapeFzfLuaOpts table<string, any>
---@alias CodeShapeFzfSelection string[]

---@param entry string
---@return string|nil path
---@return integer|nil lnum
local function parse_selected_entry(entry)
  if type(entry) ~= "string" or entry == "" then
    return nil, nil
  end
  local path, raw_lnum = entry:match("\t(.+):(%d+)$")
  local lnum = tonumber(raw_lnum)
  if not path or not lnum then
    return nil, nil
  end
  return path, lnum
end

---@param opts? CodeShapeFzfLuaOpts fzf-lua options
function M.defs(opts)
  local ok, fzf_lua = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("code-shape: fzf-lua is not installed", vim.log.levels.ERROR)
    return
  end

  local code_shape = require("code-shape")
  code_shape.ensure_setup()
  local config = code_shape.get_config()

  opts = vim.tbl_deep_extend("force", {
    prompt = "CodeShape Defs> ",
    fzf_opts = {
      ["--no-sort"] = "",
      ["--ansi"] = "",
    },
    previewer = "builtin",
    actions = {
      ---@param selected CodeShapeFzfSelection|nil
      ["default"] = function(selected)
        if not selected or #selected == 0 then
          return
        end
        local entry = selected[1]
        local path, lnum = parse_selected_entry(entry)
        if path and lnum then
          vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {})
          vim.api.nvim_win_set_cursor(0, { lnum, 0 })
          vim.api.nvim_cmd({ cmd = "normal", args = { "zz" }, bang = true }, {})
        end
      end,
      ---@param selected CodeShapeFzfSelection|nil
      ["ctrl-s"] = function(selected)
        if not selected or #selected == 0 then
          return
        end
        local entry = selected[1]
        local path, lnum = parse_selected_entry(entry)
        if path and lnum then
          vim.api.nvim_cmd({ cmd = "split", args = { path } }, {})
          vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        end
      end,
      ---@param selected CodeShapeFzfSelection|nil
      ["ctrl-v"] = function(selected)
        if not selected or #selected == 0 then
          return
        end
        local entry = selected[1]
        local path, lnum = parse_selected_entry(entry)
        if path and lnum then
          vim.api.nvim_cmd({ cmd = "vsplit", args = { path } }, {})
          vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        end
      end,
    },
  }, opts or {})

  -- Use fzf_live for live query → code-shape search
  fzf_lua.fzf_live(function(query)
    if not query or query == "" then
      return {}
    end

    local results = {}
    local symbols = picker_utils.search_symbols(query, config)
    for _, item in ipairs(symbols) do
      local path, lnum = picker_utils.item_location(item)
      local display = picker_utils.format_entry_fzf(item)
      -- fzf-lua uses the last `:path:lnum` for preview/actions
      table.insert(results, display .. "\t" .. path .. ":" .. lnum)
    end

    return results
  end, opts)
end

---@param opts? CodeShapeFzfLuaOpts fzf-lua options
function M.hotspots(opts)
  local ok, fzf_lua = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("code-shape: fzf-lua is not installed", vim.log.levels.ERROR)
    return
  end

  local code_shape = require("code-shape")
  code_shape.ensure_setup()
  local config = code_shape.get_config()

  local hotspots = require("code-shape.hotspots")
  local top = hotspots.get_top(config and config.search.limit or 50)

  local entries = {}
  for _, item in ipairs(top) do
    local uri = type(item.path) == "string" and item.path or ""
    local path = util.file_uri_to_fname(uri) or uri
    local display = picker_utils.format_hotspot_fzf(item)
    table.insert(entries, display .. "\t" .. path .. ":1")
  end

  opts = vim.tbl_deep_extend("force", {
    prompt = "CodeShape Hotspots> ",
    fzf_opts = {
      ["--ansi"] = "",
    },
    previewer = "builtin",
    actions = {
      ---@param selected CodeShapeFzfSelection|nil
      ["default"] = function(selected)
        if not selected or #selected == 0 then
          return
        end
        local entry = selected[1]
        local path = select(1, parse_selected_entry(entry))
        if path then
          vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {})
        end
      end,
    },
  }, opts or {})

  fzf_lua.fzf_exec(entries, opts)
end

---@param opts? CodeShapeFzfLuaOpts
function M.calls(_)
  -- Calls mode requires interactive call graph navigation which is not supported in external pickers
  vim.notify(
    "code-shape: Calls mode requires interactive navigation (l/h/r keys).\n"
      .. "  Alternative: Use builtin UI with :CodeShapeCallsFromCursor\n"
      .. "  Or: Open CodeShape UI with :CodeShape, select symbol, press gc",
    vim.log.levels.INFO
  )
end

---@param opts? { base?: string, head?: string, staged?: boolean }
function M.impact(opts)
  local ok, fzf_lua = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("code-shape: fzf-lua is not installed", vim.log.levels.ERROR)
    return
  end

  local code_shape = require("code-shape")
  code_shape.ensure_setup()
  local config = code_shape.get_config()

  opts = opts or {}
  local diff = require("code-shape.diff")

  -- Show loading state
  local loading_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(loading_buf, 0, -1, false, { "Analyzing diff...", "This may take a moment..." })
  local loading_win = vim.api.nvim_open_win(loading_buf, true, {
    relative = "editor",
    width = 40,
    height = 2,
    row = math.floor(vim.o.lines / 2),
    col = math.floor((vim.o.columns - 40) / 2),
    border = config.ui.border,
    title = " CodeShape Impact ",
    title_pos = "center",
  })

  local diff_opts = {
    base = opts.base,
    head = opts.head,
    staged = opts.staged,
  }

  diff.calculate_impact(diff_opts, function(err, result)
    pcall(vim.api.nvim_win_close, loading_win, true)
    pcall(vim.api.nvim_buf_delete, loading_buf, { force = true })

    if err then
      vim.notify("code-shape: " .. err, vim.log.levels.ERROR)
      return
    end

    if not result or #result.risk_ranking == 0 then
      vim.notify("code-shape: No changes detected", vim.log.levels.INFO)
      return
    end

    local impact_data = result.risk_ranking
    local entries = {}

    for _, item in ipairs(impact_data) do
      local path = util.file_uri_to_fname(item.uri or "") or ""
      local lnum = (item.range and item.range.start and item.range.start.line or 0) + 1
      local display = picker_utils.format_impact_fzf(item)
      table.insert(entries, display .. "\t" .. path .. ":" .. lnum)
    end

    local fzf_opts = vim.tbl_deep_extend("force", {
      prompt = "CodeShape Impact> ",
      fzf_opts = {
        ["--ansi"] = "",
      },
      previewer = "builtin",
      actions = {
        ---@param selected CodeShapeFzfSelection|nil
        ["default"] = function(selected)
          if not selected or #selected == 0 then
            return
          end
          local entry = selected[1]
          local path, lnum = parse_selected_entry(entry)
          if path and lnum then
            vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {})
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            vim.api.nvim_cmd({ cmd = "normal", args = { "zz" }, bang = true }, {})
          end
        end,
      },
    }, opts)

    fzf_lua.fzf_exec(entries, fzf_opts)
  end)
end

return M
