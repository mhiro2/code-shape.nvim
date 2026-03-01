---@class CodeShapeUiInstance
---@field open fun(config: CodeShapeConfig)
---@field open_hotspots fun(config: CodeShapeConfig)
---@field close fun()
---@field state CodeShapeUiState

---@class CodeShapeUi
---@field new fun(): CodeShapeUiInstance
---@field open fun(config: CodeShapeConfig)
---@field open_hotspots fun(config: CodeShapeConfig)
local M = {}

local util = require("code-shape.util")
local highlight = require("code-shape.highlight")
local ui_state = require("code-shape.ui.state")
local render = require("code-shape.ui.render")
local actions_factory = require("code-shape.ui.actions")
local input_module = require("code-shape.ui.input")

local HOTSPOT_SCORE_BAR_WIDTH = 10
local HOTSPOT_LINE_FIXED_WIDTH = 24
local HOTSPOT_WINDOW_MAX_WIDTH = 100
local SYMBOL_METRICS_FIXED_WIDTH = 42

---@param total_columns integer
---@param width number
---@return integer
local function resolve_window_width(total_columns, width)
  if width <= 1 then
    return math.max(1, math.floor(total_columns * width))
  end

  local max_width = math.max(1, total_columns - 2)
  return math.min(max_width, math.floor(width))
end

---@param total_columns integer
---@return integer
local function resolve_hotspots_window_width(total_columns)
  local max_width = math.max(1, total_columns - 4)
  return math.min(max_width, HOTSPOT_WINDOW_MAX_WIDTH)
end

---@param window_width integer
---@return integer
local function resolve_hotspots_path_width(window_width)
  return math.max(1, window_width - HOTSPOT_LINE_FIXED_WIDTH)
end

---@param text string
---@param max_width integer
---@return string
local function truncate_with_ellipsis(text, max_width)
  if #text <= max_width then
    return text
  end
  if max_width <= 3 then
    return text:sub(1, max_width)
  end
  return "..." .. text:sub(-(max_width - 3))
end

---@return CodeShapeUiInstance
function M.new()
  ---@type CodeShapeUiState
  local state = ui_state.new()

  local function render_results()
    render.render_results(state)
  end

  local function update_preview()
    render.update_preview(state)
  end

  local function close()
    ui_state.cleanup_timer(state)

    if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
      vim.api.nvim_win_close(state.input_win, true)
    end
    if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
      vim.api.nvim_buf_delete(state.input_buf, { force = true })
    end
    if state.current_win and vim.api.nvim_win_is_valid(state.current_win) then
      vim.api.nvim_win_close(state.current_win, true)
    end
    if state.current_buf and vim.api.nvim_buf_is_valid(state.current_buf) then
      vim.api.nvim_buf_delete(state.current_buf, { force = true })
    end
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
      vim.api.nvim_win_close(state.preview_win, true)
    end
    if state.preview_buf and vim.api.nvim_buf_is_valid(state.preview_buf) then
      vim.api.nvim_buf_delete(state.preview_buf, { force = true })
    end

    ui_state.reset(state)
  end

  local actions = actions_factory.new({
    state = state,
    close = close,
    render_results = render_results,
    update_preview = update_preview,
  })

  ---@param config CodeShapeConfig
  local function open(config)
    highlight.setup()
    state.current_config = config

    if ui_state.is_open(state) then
      vim.api.nvim_set_current_win(state.input_win)
      return
    end

    local width = resolve_window_width(vim.o.columns, config.ui.width)
    local col = math.floor((vim.o.columns - width) / 2)

    local input_height = 1
    local min_results_height = 1
    local stacked_border_rows = 4 -- two stacked windows, each with top/bottom border
    local min_total_height = input_height + min_results_height + stacked_border_rows
    local desired_total_height = math.floor(vim.o.lines * config.ui.height)
    local total_height = math.max(min_total_height, desired_total_height)
    local results_height = math.max(min_results_height, total_height - input_height - stacked_border_rows)
    local stacked_total_height = input_height + results_height + stacked_border_rows
    local row = math.max(0, math.floor((vim.o.lines - stacked_total_height) / 2))

    -- Create input buffer and window
    state.input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "prompt", { buf = state.input_buf })
    vim.api.nvim_set_option_value("filetype", "code-shape-input", { buf = state.input_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.input_buf })
    -- Set the prompt to "> " instead of default "%"
    vim.fn.prompt_setprompt(state.input_buf, "> ")

    state.input_win = vim.api.nvim_open_win(state.input_buf, true, {
      relative = "editor",
      width = width,
      height = input_height,
      row = row,
      col = col,
      border = config.ui.border,
      title = " CodeShape ",
      title_pos = "center",
    })

    -- Create results buffer and window
    state.current_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.current_buf })
    vim.api.nvim_set_option_value("filetype", "code-shape", { buf = state.current_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.current_buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = state.current_buf })

    local main_width = config.ui.preview and math.floor(width * 0.5) or width
    state.current_win = vim.api.nvim_open_win(state.current_buf, false, {
      relative = "editor",
      width = main_width,
      height = results_height,
      row = row + input_height + 2, -- below input window + border rows
      col = col,
      border = config.ui.border,
      title = " Results ",
      title_pos = "center",
    })

    if config.ui.preview then
      state.preview_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.preview_buf })
      vim.api.nvim_set_option_value("filetype", "code-shape-preview", { buf = state.preview_buf })
      vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.preview_buf })

      state.preview_win = vim.api.nvim_open_win(state.preview_buf, false, {
        relative = "editor",
        width = main_width,
        height = results_height,
        row = row + input_height + 2,
        col = col + main_width + 2,
        border = config.ui.border,
        title = " Preview ",
        title_pos = "center",
      })
    end

    -- Set up input handling
    local input_callbacks = {
      close = close,
      do_search = function(query)
        actions.do_search(query)
      end,
      select_next = function()
        actions.select_next()
      end,
      select_prev = function()
        actions.select_prev()
      end,
      switch_mode_next = function()
        actions.switch_mode_next()
      end,
      switch_mode_prev = function()
        actions.switch_mode_prev()
      end,
      cycle_kind_filter = function()
        actions.cycle_kind_filter()
      end,
      jump_to_symbol = function(item)
        actions.jump_to_symbol(item)
      end,
      show_calls = function()
        actions.show_calls()
      end,
    }
    input_module.setup(state, config, input_callbacks)

    -- Set up keymaps for results window (navigation, etc.)
    actions.setup_keymaps(state.current_buf, config)

    -- Window options for input window
    vim.api.nvim_set_option_value("number", false, { win = state.input_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.input_win })
    vim.api.nvim_set_option_value("cursorline", false, { win = state.input_win })

    -- Window options for results window
    vim.api.nvim_set_option_value("cursorline", true, { win = state.current_win })
    vim.api.nvim_set_option_value("number", false, { win = state.current_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.current_win })

    if state.preview_win then
      vim.api.nvim_set_option_value("cursorline", false, { win = state.preview_win })
      vim.api.nvim_set_option_value("number", false, { win = state.preview_win })
      vim.api.nvim_set_option_value("relativenumber", false, { win = state.preview_win })
    end

    -- Initial render
    render_results()

    -- Start in insert mode in the input window
    vim.api.nvim_cmd({ cmd = "startinsert", bang = true }, {})
  end

  ---Render the symbol metrics drill-down view inside the hotspots window
  ---@param bufnr integer
  ---@param win integer
  ---@param uri string
  ---@param hotspot_score number
  ---@param render_file_list fun() function to re-render file list view
  local function render_symbol_metrics(bufnr, win, uri, hotspot_score, render_file_list)
    local hotspots = require("code-shape.hotspots")
    hotspots.get_top_symbols(uri, 20, function(symbols, err)
      if err or not symbols or #symbols == 0 then
        vim.notify("code-shape: No symbols found for this file.", vim.log.levels.INFO)
        return
      end

      local path = util.file_uri_to_fname(uri) or uri
      local short_path = util.shorten_path(path) or path
      local width = vim.api.nvim_win_get_width(win)
      local name_width = math.max(10, width - SYMBOL_METRICS_FIXED_WIDTH)

      local lines = {
        string.format("Symbols in %s (hotspot: %.2f)", short_path, hotspot_score),
        "",
        string.format("  #  %-" .. name_width .. "s  CC  LOC  Depth  Tech Debt", "Name"),
      }
      local symbol_data = {}

      for i, sym in ipairs(symbols) do
        local name = truncate_with_ellipsis(sym.name or "", name_width)
        local cc = sym.metrics and sym.metrics.cyclomatic_complexity or 0
        local loc = sym.metrics and sym.metrics.lines_of_code or 0
        local depth = sym.metrics and sym.metrics.nesting_depth or 0
        local tech_debt = sym.tech_debt or 0

        local debt_bar_len =
          math.max(0, math.min(HOTSPOT_SCORE_BAR_WIDTH, math.floor(tech_debt * HOTSPOT_SCORE_BAR_WIDTH)))
        local debt_bar = string.rep("█", debt_bar_len)

        local line = string.format(
          "%3d. %-" .. name_width .. "s %3d  %3d    %3d   %s %.2f",
          i,
          name,
          cc,
          loc,
          depth,
          debt_bar,
          tech_debt
        )
        table.insert(lines, line)
        table.insert(symbol_data, sym)
      end

      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

      vim.api.nvim_buf_add_highlight(bufnr, -1, "CodeShapeTitle", 0, 0, -1)
      vim.api.nvim_buf_add_highlight(bufnr, -1, "CodeShapeComment", 2, 0, -1)

      -- Update window title
      pcall(vim.api.nvim_win_set_config, win, {
        title = " CodeShape Symbols ",
        title_pos = "center",
      })

      -- Clear existing keymaps and set new ones
      local opts = { buffer = bufnr, noremap = true, silent = true }
      local nowait_opts = vim.tbl_extend("force", opts, { nowait = true })

      -- Jump to symbol location
      vim.keymap.set("n", "<CR>", function()
        local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
        local idx = cursor_line - 3 -- header lines offset
        if idx >= 1 and symbol_data[idx] then
          local sym = symbol_data[idx]
          vim.api.nvim_win_close(win, true)
          local fpath = util.file_uri_to_fname(sym.uri or uri)
          if fpath then
            vim.api.nvim_cmd({ cmd = "edit", args = { fpath } }, {})
            local line = (sym.range and sym.range.start and sym.range.start.line or 0) + 1
            pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
          end
        end
      end, nowait_opts)

      -- Back to file list
      vim.keymap.set("n", "<BS>", render_file_list, nowait_opts)
      vim.keymap.set("n", "h", render_file_list, nowait_opts)

      vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
      end, nowait_opts)

      vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
      end, nowait_opts)
    end)
  end

  ---@param config CodeShapeConfig
  local function open_hotspots(config)
    highlight.setup()
    local hotspots = require("code-shape.hotspots")
    local top_hotspots = hotspots.get_top(50)

    if #top_hotspots == 0 then
      vim.notify("code-shape: No hotspots found. Try editing some files first.", vim.log.levels.INFO)
      return
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
    vim.api.nvim_set_option_value("filetype", "code-shape-hotspots", { buf = bufnr })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })

    local width = resolve_hotspots_window_width(vim.o.columns)
    local height

    local win

    local function build_hotspot_lines()
      local path_width = resolve_hotspots_path_width(width)
      local lines = { "Hotspot Files (sorted by change frequency):", "" }
      local paths = {}
      local uris = {}
      local scores = {}

      for i, item in ipairs(top_hotspots) do
        local uri = type(item.path) == "string" and item.path or ""
        local path = util.file_uri_to_fname(uri) or uri
        local short_path = util.shorten_path(path) or path
        local score = type(item.score) == "number" and item.score or 0
        local score_bar_length =
          math.max(0, math.min(HOTSPOT_SCORE_BAR_WIDTH, math.floor(score * HOTSPOT_SCORE_BAR_WIDTH)))
        local score_bar = string.rep("█", score_bar_length)
        local clipped_path = truncate_with_ellipsis(short_path, path_width)
        local line = string.format("%3d. %-" .. path_width .. "s %s (%.2f)", i, clipped_path, score_bar, score)
        table.insert(lines, line)
        table.insert(paths, path)
        table.insert(uris, uri)
        table.insert(scores, score)
      end

      return lines, paths, uris, scores
    end

    local function render_file_list()
      local lines, paths, uris, scores = build_hotspot_lines()

      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

      -- Update window title
      pcall(vim.api.nvim_win_set_config, win, {
        title = " CodeShape Hotspots ",
        title_pos = "center",
      })

      vim.api.nvim_buf_add_highlight(bufnr, -1, "CodeShapeTitle", 0, 0, -1)

      local opts = { buffer = bufnr, noremap = true, silent = true }
      local nowait_opts = vim.tbl_extend("force", opts, { nowait = true })

      vim.keymap.set("n", "<CR>", function()
        local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
        local idx = cursor_line - 2
        if idx >= 1 and paths[idx] then
          render_symbol_metrics(bufnr, win, uris[idx], scores[idx], render_file_list)
        end
      end, nowait_opts)

      vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
      end, nowait_opts)

      vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
      end, nowait_opts)
    end

    -- Use shared function for initial height calculation
    local initial_lines = build_hotspot_lines()
    height = math.min(vim.o.lines - 4, #initial_lines + 2)

    win = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      border = config.ui.border,
      title = " CodeShape Hotspots ",
      title_pos = "center",
    })

    vim.api.nvim_set_option_value("cursorline", true, { win = win })
    vim.api.nvim_set_option_value("number", false, { win = win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win })

    render_file_list()
  end

  ---@param config CodeShapeConfig
  ---@param opts? { base?: string, head?: string, staged?: boolean }
  local function open_impact(config, opts)
    opts = opts or {}
    highlight.setup()
    local diff = require("code-shape.diff")

    local width = resolve_hotspots_window_width(vim.o.columns)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
    vim.api.nvim_set_option_value("filetype", "code-shape-impact", { buf = bufnr })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

    local win
    local impact_data = {}

    local function render_loading()
      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Analyzing diff...", "", "This may take a moment..." })
      vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
    end

    local function render_impact_list()
      if #impact_data == 0 then
        vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
        vim.api.nvim_buf_set_lines(
          bufnr,
          0,
          -1,
          false,
          { "No changes detected.", "", "Try specifying a different base branch." }
        )
        vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
        return
      end

      local name_width = 28
      local path_width = 32
      local lines = {
        string.format("Impact Analysis: %s -> %s", opts.base or "HEAD", opts.head or "working"),
        string.format(
          "  #  %-" .. name_width .. "s  %-8s  Callers  Hotspot   Score   %-" .. path_width .. "s",
          "Symbol",
          "Type"
        ),
      }

      for i, item in ipairs(impact_data) do
        local name = truncate_with_ellipsis(item.name or "", name_width)
        local change_type = item.change_type == "affected" and "affect" or (item.change_type or "mod"):sub(1, 5)
        local caller_count = item.caller_count or 0
        local hotspot_score = item.hotspot_score or 0
        local impact_score = item.impact_score or 0
        local path = util.file_uri_to_fname(item.uri or "") or ""
        local short_path = util.shorten_path(path) or path
        short_path = truncate_with_ellipsis(short_path, path_width)

        local score_bar_len =
          math.max(0, math.min(HOTSPOT_SCORE_BAR_WIDTH, math.floor(impact_score * HOTSPOT_SCORE_BAR_WIDTH / 2)))
        local score_bar = string.rep("█", score_bar_len)

        local line = string.format(
          "%3d. %-" .. name_width .. "s  %-8s    %3d      %.2f    %.2f   %-" .. path_width .. "s",
          i,
          name,
          change_type,
          caller_count,
          hotspot_score,
          impact_score,
          short_path
        )
        if #score_bar > 0 then
          line = line .. " " .. score_bar
        end
        table.insert(lines, line)
      end

      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

      vim.api.nvim_buf_add_highlight(bufnr, -1, "CodeShapeTitle", 0, 0, -1)
      vim.api.nvim_buf_add_highlight(bufnr, -1, "CodeShapeComment", 1, 0, -1)

      pcall(vim.api.nvim_win_set_config, win, {
        title = " CodeShape Impact Analysis ",
        title_pos = "center",
      })
    end

    local height = math.min(vim.o.lines - 4, 10)
    win = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      border = config.ui.border,
      title = " CodeShape Impact Analysis ",
      title_pos = "center",
    })

    vim.api.nvim_set_option_value("cursorline", true, { win = win })
    vim.api.nvim_set_option_value("number", false, { win = win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win })

    local opts_keymap = { buffer = bufnr, noremap = true, silent = true }
    local nowait_opts = vim.tbl_extend("force", opts_keymap, { nowait = true })

    vim.keymap.set("n", "<CR>", function()
      local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
      local idx = cursor_line - 2
      if idx >= 1 and impact_data[idx] then
        local item = impact_data[idx]
        vim.api.nvim_win_close(win, true)
        local fpath = util.file_uri_to_fname(item.uri or "")
        if fpath and fpath ~= "" then
          vim.api.nvim_cmd({ cmd = "edit", args = { fpath } }, {})
          local line = (item.range and item.range.start and item.range.start.line or 0) + 1
          pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
        end
      end
    end, nowait_opts)

    vim.keymap.set("n", "q", function()
      vim.api.nvim_win_close(win, true)
    end, nowait_opts)

    vim.keymap.set("n", "<Esc>", function()
      vim.api.nvim_win_close(win, true)
    end, nowait_opts)

    render_loading()

    local diff_opts = {
      base = opts.base,
      head = opts.head,
      staged = opts.staged,
    }

    diff.calculate_impact(diff_opts, function(err, result)
      if err then
        vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Error: " .. err })
        vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
        return
      end

      if result then
        impact_data = result.risk_ranking or {}
        render_impact_list()
        if #impact_data > 0 then
          local new_height = math.min(vim.o.lines - 4, #impact_data + 3)
          pcall(vim.api.nvim_win_set_height, win, new_height)
        end
      end
    end)
  end

  return {
    open = open,
    open_hotspots = open_hotspots,
    open_impact = open_impact,
    close = close,
    state = state,
  }
end

---@type CodeShapeUiInstance|nil
local default_instance = nil

---@return CodeShapeUiInstance
local function get_default_instance()
  if not default_instance then
    default_instance = M.new()
  end
  return default_instance
end

---@param config CodeShapeConfig
function M.open(config)
  get_default_instance().open(config)
end

---@param config CodeShapeConfig
function M.open_hotspots(config)
  get_default_instance().open_hotspots(config)
end

---@param config CodeShapeConfig
---@param opts? { base?: string, head?: string, staged?: boolean }
function M.open_impact(config, opts)
  get_default_instance().open_impact(config, opts)
end

return M
