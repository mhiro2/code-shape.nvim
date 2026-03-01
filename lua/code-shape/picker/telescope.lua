---@class CodeShapePickerTelescope
local M = {}

local picker_utils = require("code-shape.picker.utils")
local util = require("code-shape.util")

---@alias CodeShapeTelescopeOpts table<string, any>

---@class CodeShapeTelescopeEntry
---@field value CodeShapeSearchResultItem|{ path: string, score: number }
---@field display string
---@field ordinal string
---@field path string
---@field lnum integer

---@param opts? CodeShapeTelescopeOpts Telescope picker opts
function M.defs(opts)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("code-shape: telescope.nvim is not installed", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local code_shape = require("code-shape")
  code_shape.ensure_setup()
  local config = code_shape.get_config()

  opts = opts or {}

  pickers
    .new(opts, {
      prompt_title = "CodeShape Defs",
      finder = finders.new_dynamic({
        fn = function(query)
          if not query or query == "" then
            return {}
          end
          return picker_utils.search_symbols(query, config)
        end,
        ---@param item CodeShapeSearchResultItem
        ---@return CodeShapeTelescopeEntry
        entry_maker = function(item)
          local path, lnum = picker_utils.item_location(item)
          local display_str, highlights = picker_utils.format_entry_telescope(item)
          return {
            value = item,
            display = function(_)
              return display_str, highlights
            end,
            ordinal = item.name .. " " .. (item.container_name or ""),
            path = path,
            lnum = lnum,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = conf.file_previewer(opts),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          ---@type CodeShapeTelescopeEntry|nil
          local selection = action_state.get_selected_entry()
          if selection then
            local item = selection.value
            local path, lnum = picker_utils.item_location(item)
            local char = item.range and item.range.start and item.range.start.character or 0
            vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {})
            vim.api.nvim_win_set_cursor(0, { lnum, char })
            vim.api.nvim_cmd({ cmd = "normal", args = { "zz" }, bang = true }, {})
          end
        end)

        actions.select_horizontal:replace(function()
          actions.close(prompt_bufnr)
          ---@type CodeShapeTelescopeEntry|nil
          local selection = action_state.get_selected_entry()
          if selection then
            local item = selection.value
            local path, lnum = picker_utils.item_location(item)
            local char = item.range and item.range.start and item.range.start.character or 0
            vim.api.nvim_cmd({ cmd = "split", args = { path } }, {})
            vim.api.nvim_win_set_cursor(0, { lnum, char })
          end
        end)

        actions.select_vertical:replace(function()
          actions.close(prompt_bufnr)
          ---@type CodeShapeTelescopeEntry|nil
          local selection = action_state.get_selected_entry()
          if selection then
            local item = selection.value
            local path, lnum = picker_utils.item_location(item)
            local char = item.range and item.range.start and item.range.start.character or 0
            vim.api.nvim_cmd({ cmd = "vsplit", args = { path } }, {})
            vim.api.nvim_win_set_cursor(0, { lnum, char })
          end
        end)

        return true
      end,
    })
    :find()
end

---@param opts? CodeShapeTelescopeOpts Telescope picker opts
function M.hotspots(opts)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("code-shape: telescope.nvim is not installed", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local code_shape = require("code-shape")
  code_shape.ensure_setup()
  local config = code_shape.get_config()

  local hotspots = require("code-shape.hotspots")
  local top = hotspots.get_top(config and config.search.limit or 50)

  opts = opts or {}

  pickers
    .new(opts, {
      prompt_title = "CodeShape Hotspots",
      finder = finders.new_table({
        results = top,
        ---@param item { path: string, score: number }
        ---@return CodeShapeTelescopeEntry
        entry_maker = function(item)
          local uri = type(item.path) == "string" and item.path or ""
          local path = util.file_uri_to_fname(uri) or uri
          return {
            value = item,
            display = picker_utils.format_hotspot(item),
            ordinal = path,
            path = path,
            lnum = 1,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = conf.file_previewer(opts),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          ---@type CodeShapeTelescopeEntry|nil
          local selection = action_state.get_selected_entry()
          if selection then
            local uri = type(selection.value.path) == "string" and selection.value.path or ""
            local path = util.file_uri_to_fname(uri) or uri
            vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {})
          end
        end)
        return true
      end,
    })
    :find()
end

---@param opts? CodeShapeTelescopeOpts Telescope picker opts
function M.calls(_)
  -- Calls mode requires interactive call graph navigation which is not supported in external pickers
  -- Provide guidance for alternative workflow
  vim.notify(
    "code-shape: Calls mode requires interactive navigation (l/h/r keys).\n"
      .. "  Alternative: Use builtin UI with :CodeShapeCallsFromCursor\n"
      .. "  Or: Open CodeShape UI with :CodeShape, select symbol, press gc",
    vim.log.levels.INFO
  )
end

---@param opts? { base?: string, head?: string, staged?: boolean }
function M.impact(opts)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("code-shape: telescope.nvim is not installed", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

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

    pickers
      .new(opts, {
        prompt_title = string.format("CodeShape Impact: %s -> %s", result.base, result.head),
        finder = finders.new_table({
          results = impact_data,
          ---@param item CodeShapeImpactScore
          ---@return CodeShapeTelescopeEntry
          entry_maker = function(item)
            local path = util.file_uri_to_fname(item.uri or "") or ""
            local lnum = (item.range and item.range.start and item.range.start.line or 0) + 1
            return {
              value = item,
              display = picker_utils.format_impact(item),
              ordinal = item.name .. " " .. path,
              path = path,
              lnum = lnum,
            }
          end,
        }),
        sorter = conf.generic_sorter(opts),
        previewer = conf.file_previewer(opts),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            ---@type CodeShapeTelescopeEntry|nil
            local selection = action_state.get_selected_entry()
            if selection then
              local item = selection.value
              local path = util.file_uri_to_fname(item.uri or "") or ""
              local lnum = (item.range and item.range.start and item.range.start.line or 0) + 1
              local char = item.range and item.range.start and item.range.start.character or 0
              if path ~= "" then
                vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {})
                vim.api.nvim_win_set_cursor(0, { lnum, char })
                vim.api.nvim_cmd({ cmd = "normal", args = { "zz" }, bang = true }, {})
              end
            end
          end)
          return true
        end,
      })
      :find()
  end)
end

return M
