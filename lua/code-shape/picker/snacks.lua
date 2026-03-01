---@class CodeShapePickerSnacks
local M = {}

local picker_utils = require("code-shape.picker.utils")
local util = require("code-shape.util")

---@alias CodeShapeSnacksPickerOpts table<string, any>

---@class CodeShapeSnacksItem
---@field idx integer
---@field score integer
---@field text string
---@field file string
---@field pos integer[]
---@field item? CodeShapeSearchResultItem

---@param opts? CodeShapeSnacksPickerOpts Snacks.picker options
function M.defs(opts)
  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks.picker then
    vim.notify("code-shape: snacks.nvim (with picker) is not installed", vim.log.levels.ERROR)
    return
  end

  local code_shape = require("code-shape")
  code_shape.ensure_setup()
  local config = code_shape.get_config()

  opts = opts or {}

  Snacks.picker({
    title = "CodeShape Defs",
    live = true,
    finder = function(_, ctx)
      -- Get the current search query from the picker context
      local query = ""
      if ctx.filter and type(ctx.filter.search) == "string" then
        query = ctx.filter.search
      end
      if query == "" and ctx.filter and type(ctx.filter.pattern) == "string" then
        query = ctx.filter.pattern
      end

      if query == "" then
        return {}
      end

      local rpc = require("code-shape.rpc")
      local params = picker_utils.search_params(query, config)
      ---@async
      ---@param cb async fun(item: CodeShapeSnacksItem)
      return function(cb)
        local done = false
        local canceled = false
        local async = ctx.async

        async:on("abort", function()
          canceled = true
          if not done then
            done = true
            async:resume()
          end
        end)

        rpc.request("search/query", params, function(err, result)
          if canceled or done then
            return
          end
          if err then
            vim.notify("code-shape: search error: " .. err, vim.log.levels.WARN)
            done = true
            async:resume()
            return
          end

          local symbols = type(result) == "table" and result.symbols or nil
          if vim.islist(symbols) then
            for idx, item in ipairs(symbols) do
              if canceled then
                break
              end
              local path, lnum = picker_utils.item_location(item)
              cb({
                idx = idx,
                score = idx,
                text = picker_utils.format_entry(item),
                file = path,
                pos = { lnum, item.range and item.range.start and item.range.start.character + 1 or 1 },
                item = item,
              })
            end
          end

          done = true
          async:resume()
        end)

        if not done then
          async:suspend()
        end
      end
    end,
    format = function(item, _)
      if item.item then
        return picker_utils.format_entry_highlight(item.item)
      end
      return { { item.text, "Normal" } }
    end,
    preview = "file",
    confirm = function(picker, item)
      picker:close()
      if item and item.file then
        vim.api.nvim_cmd({ cmd = "edit", args = { item.file } }, {})
        if item.pos then
          vim.api.nvim_win_set_cursor(0, { item.pos[1], item.pos[2] - 1 })
          vim.api.nvim_cmd({ cmd = "normal", args = { "zz" }, bang = true }, {})
        end
      end
    end,
  })
end

---@param opts? CodeShapeSnacksPickerOpts Snacks.picker options
function M.hotspots(opts)
  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks.picker then
    vim.notify("code-shape: snacks.nvim (with picker) is not installed", vim.log.levels.ERROR)
    return
  end

  local code_shape = require("code-shape")
  code_shape.ensure_setup()
  local config = code_shape.get_config()

  local hotspots = require("code-shape.hotspots")
  local top = hotspots.get_top(config and config.search.limit or 50)

  ---@type CodeShapeSnacksItem[]
  local items = {}
  for idx, item in ipairs(top) do
    local uri = type(item.path) == "string" and item.path or ""
    local path = util.file_uri_to_fname(uri) or uri
    table.insert(items, {
      idx = idx,
      score = idx,
      text = picker_utils.format_hotspot(item),
      file = path,
      pos = { 1, 1 },
      hotspot_uri = uri,
      hotspot_score = item.score or 0,
    })
  end

  opts = opts or {}

  Snacks.picker({
    title = "CodeShape Hotspots",
    items = items,
    format = function(item, _)
      return picker_utils.format_hotspot_highlight({ path = item.hotspot_uri, score = item.hotspot_score })
    end,
    preview = "file",
    confirm = function(picker, item)
      picker:close()
      if item and item.file then
        vim.api.nvim_cmd({ cmd = "edit", args = { item.file } }, {})
      end
    end,
  })
end

---@param opts? CodeShapeSnacksPickerOpts
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
  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks.picker then
    vim.notify("code-shape: snacks.nvim (with picker) is not installed", vim.log.levels.ERROR)
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
    ---@type CodeShapeSnacksItem[]
    local items = {}

    for idx, item in ipairs(impact_data) do
      local path = util.file_uri_to_fname(item.uri or "") or ""
      local lnum = (item.range and item.range.start and item.range.start.line or 0) + 1
      table.insert(items, {
        idx = idx,
        score = idx,
        text = picker_utils.format_impact(item),
        file = path,
        pos = { lnum, item.range and item.range.start and item.range.start.character + 1 or 1 },
        item = item,
      })
    end

    Snacks.picker({
      title = string.format("CodeShape Impact: %s -> %s", result.base, result.head),
      items = items,
      format = function(item, _)
        if item.item then
          return picker_utils.format_impact_highlight(item.item)
        end
        return { { item.text, "Normal" } }
      end,
      preview = "file",
      confirm = function(picker, item)
        picker:close()
        if item and item.file then
          vim.api.nvim_cmd({ cmd = "edit", args = { item.file } }, {})
          if item.pos then
            vim.api.nvim_win_set_cursor(0, { item.pos[1], item.pos[2] - 1 })
            vim.api.nvim_cmd({ cmd = "normal", args = { "zz" }, bang = true }, {})
          end
        end
      end,
    })
  end)
end

return M
