local config = require("code-shape.config")

describe("ui", function()
  local original_keymap_set
  local original_rpc
  local original_hotspots
  local original_diff

  local keymaps
  local keymap_opts
  local rpc_requests
  local rpc_symbols
  local hotspot_items
  local source_uri

  local function reset_ui_modules()
    package.loaded["code-shape.ui"] = nil
    package.loaded["code-shape.ui.actions"] = nil
    package.loaded["code-shape.ui.actions.shared"] = nil
    package.loaded["code-shape.ui.actions.calls_graph"] = nil
    package.loaded["code-shape.ui.actions.lsp"] = nil
    package.loaded["code-shape.ui.actions.keymaps"] = nil
    package.loaded["code-shape.ui.render"] = nil
    package.loaded["code-shape.ui.state"] = nil
    package.loaded["code-shape.ui.input"] = nil
  end

  ---@param filetype string
  ---@return boolean
  local function is_code_shape_filetype(filetype)
    return filetype == "code-shape"
      or filetype == "code-shape-input"
      or filetype == "code-shape-preview"
      or filetype == "code-shape-hotspots"
      or filetype == "code-shape-impact"
  end

  local function cleanup_ui_artifacts()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local bufnr = vim.api.nvim_win_get_buf(win)
      local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
      if ok and is_code_shape_filetype(filetype) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and is_code_shape_filetype(filetype) then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end
  end

  ---@return integer|nil
  local function find_main_ui_buffer()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and filetype == "code-shape" then
          return bufnr
        end
      end
    end
    return nil
  end

  ---@return integer|nil
  local function find_input_buffer()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and filetype == "code-shape-input" then
          return bufnr
        end
      end
    end
    return nil
  end

  ---@return integer|nil
  local function find_hotspots_buffer()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and filetype == "code-shape-hotspots" then
          return bufnr
        end
      end
    end
    return nil
  end

  ---@return integer|nil
  local function find_main_ui_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local bufnr = vim.api.nvim_win_get_buf(win)
      local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
      if ok and filetype == "code-shape" then
        return win
      end
    end
    return nil
  end

  ---@param line_count integer
  ---@return string[]
  local function get_main_ui_lines(line_count)
    local bufnr = find_main_ui_buffer()
    assert.is_not_nil(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, line_count, false)
  end

  ---@param query string
  local function set_query_and_wait(query)
    local input_bufnr = find_input_buffer()
    assert.is_not_nil(input_bufnr)
    -- Set the query in the input buffer with prompt prefix
    vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, { "> " .. query })

    local results_bufnr = find_main_ui_buffer()
    assert.is_not_nil(results_bufnr)

    local completed = vim.wait(200, function()
      local lines = vim.api.nvim_buf_get_lines(results_bufnr, 0, 4, false)
      return #rpc_requests >= 1 and lines[2] and lines[2]:find(query, 1, true) ~= nil
    end, 10)
    assert.is_true(completed)
  end

  ---@param ui CodeShapeUi
  local function open_ui(ui)
    local cfg = config.setup({
      ui = {
        preview = false,
      },
      search = {
        debounce_ms = 0,
        limit = 20,
      },
    })
    ui.open(cfg)
  end

  before_each(function()
    cleanup_ui_artifacts()
    reset_ui_modules()

    keymaps = {}
    keymap_opts = {}
    rpc_requests = {}
    rpc_symbols = {}
    hotspot_items = {}

    source_uri = vim.uri_from_fname(vim.fn.fnamemodify("lua/code-shape/ui.lua", ":p"))

    original_keymap_set = vim.keymap.set
    original_rpc = package.loaded["code-shape.rpc"]
    original_hotspots = package.loaded["code-shape.hotspots"]
    original_diff = package.loaded["code-shape.diff"]

    vim.keymap.set = function(mode, lhs, rhs, opts)
      local key = tostring(mode) .. ":" .. lhs
      keymaps[key] = rhs
      keymap_opts[key] = vim.deepcopy(opts)
    end

    package.loaded["code-shape.rpc"] = {
      request = function(method, params, cb)
        table.insert(rpc_requests, {
          method = method,
          params = vim.deepcopy(params),
        })
        if cb then
          cb(nil, { symbols = vim.deepcopy(rpc_symbols) })
        end
      end,
    }

    package.loaded["code-shape.hotspots"] = {
      get_top = function(_limit)
        return vim.deepcopy(hotspot_items)
      end,
    }
  end)

  after_each(function()
    cleanup_ui_artifacts()
    reset_ui_modules()

    vim.keymap.set = original_keymap_set
    package.loaded["code-shape.rpc"] = original_rpc
    package.loaded["code-shape.hotspots"] = original_hotspots
    package.loaded["code-shape.diff"] = original_diff
  end)

  it("renders initial defs view", function()
    local ui = require("code-shape.ui")
    open_ui(ui)

    local lines = get_main_ui_lines(4)
    assert.is_true(lines[1]:find("%[Defs%]") ~= nil)
    -- Line 2 is empty, Line 3 has "Type to search..."
    assert.is_true(lines[3]:find("Type to search") ~= nil)
  end)

  it("creates independent UI instances via factory", function()
    local ui = require("code-shape.ui")
    local instance_a = ui.new()
    local instance_b = ui.new()

    assert.is_table(instance_a)
    assert.is_table(instance_b)
    assert.is_true(instance_a ~= instance_b)
    assert.is_true(instance_a.state ~= instance_b.state)
  end)

  it("supports absolute ui.width in columns", function()
    local ui = require("code-shape.ui")
    local cfg = config.setup({
      ui = {
        width = 40,
        preview = false,
      },
      search = {
        debounce_ms = 0,
      },
    })

    ui.open(cfg)

    local win = find_main_ui_window()
    assert.is_not_nil(win)
    assert.are.equal(40, vim.api.nvim_win_get_width(win))
  end)

  it("opens with very small ui.height without window creation error", function()
    local ui = require("code-shape.ui")
    local cfg = config.setup({
      ui = {
        height = 0.05,
        preview = false,
      },
      search = {
        debounce_ms = 0,
      },
    })

    local ok, err = pcall(function()
      ui.open(cfg)
    end)
    assert.is_true(ok, err)

    local win = find_main_ui_window()
    assert.is_not_nil(win)
    assert.is_true(vim.api.nvim_win_get_height(win) >= 1)
  end)

  it("applies nowait only to immediate action keys in picker UI", function()
    local ui = require("code-shape.ui")
    open_ui(ui)

    assert.is_true(keymap_opts["n:<CR>"].nowait)
    assert.is_true(keymap_opts["n:q"].nowait)
    assert.is_true(keymap_opts["n:<Esc>"].nowait)
    assert.is_nil(keymap_opts["n:j"].nowait)
    assert.is_nil(keymap_opts["n:gd"].nowait)
    assert.is_nil(keymap_opts["n:l"].nowait)
    assert.is_nil(keymap_opts["n:h"].nowait)
    assert.is_nil(keymap_opts["n:r"].nowait)
  end)

  it("switches to calls mode and shows guidance", function()
    local ui = require("code-shape.ui")
    open_ui(ui)

    -- Use Tab to cycle to Calls mode (Defs -> Calls)
    assert.is_function(keymaps["n:<Tab>"])
    keymaps["n:<Tab>"]()

    local rendered = vim.wait(200, function()
      local lines = get_main_ui_lines(8)
      local has_guidance = false
      for _, line in ipairs(lines) do
        if line:find("Select a symbol in Defs and press gc to build call graph", 1, true) then
          has_guidance = true
          break
        end
      end
      return lines[1] and lines[1]:find("%[Calls%]") ~= nil and has_guidance
    end, 10)
    assert.is_true(rendered)
  end)

  it("runs search from query line updates and renders results", function()
    rpc_symbols = {
      {
        symbol_id = "sym-1",
        name = "my_fn",
        kind = 12,
        container_name = "M",
        uri = source_uri,
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 5 },
        },
        detail = nil,
        score = 1,
      },
    }

    local ui = require("code-shape.ui")
    open_ui(ui)
    set_query_and_wait("my_fn")

    -- Results are now on line 2 (after header on line 1)
    local rendered = vim.wait(200, function()
      local lines = get_main_ui_lines(3)
      return lines[2] and lines[2]:find("my_fn", 1, true) ~= nil
    end, 10)
    assert.is_true(rendered)
    assert.are.equal("search/query", rpc_requests[1].method)
    assert.are.equal("my_fn", rpc_requests[1].params.q)
    assert.are.equal(50, rpc_requests[1].params.complexity_cap)
    assert.is_nil(rpc_requests[1].params.filters)
  end)

  it("cycles kind filter and applies kinds to search params", function()
    rpc_symbols = {
      {
        symbol_id = "sym-1",
        name = "my_fn",
        kind = 12,
        container_name = "M",
        uri = source_uri,
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 5 },
        },
        detail = nil,
        score = 1,
      },
    }

    local ui = require("code-shape.ui")
    open_ui(ui)
    set_query_and_wait("my_fn")

    assert.is_function(keymaps["n:t"])
    keymaps["n:t"]()

    local cycled = vim.wait(200, function()
      return #rpc_requests >= 2
    end, 10)
    assert.is_true(cycled)

    local params = rpc_requests[2].params
    assert.are.equal("my_fn", params.q)
    assert.are.equal(50, params.complexity_cap)
    assert.are.same({ kinds = { 6, 9, 12 } }, params.filters)

    -- Kind filter indicator is now on line 1 (header line)
    local rendered = vim.wait(200, function()
      local lines = get_main_ui_lines(2)
      return lines[1] and lines[1]:find("%[t%] Func") ~= nil
    end, 10)
    assert.is_true(rendered)
  end)

  it("opens selected symbol on <CR> and closes picker window", function()
    rpc_symbols = {
      {
        symbol_id = "sym-1",
        name = "jump_target",
        kind = 12,
        container_name = "M",
        uri = source_uri,
        range = {
          start = { line = 4, character = 1 },
          ["end"] = { line = 4, character = 8 },
        },
        detail = nil,
        score = 1,
      },
    }

    local ui = require("code-shape.ui")
    open_ui(ui)
    set_query_and_wait("jump_target")

    assert.is_function(keymaps["n:<CR>"])
    keymaps["n:<CR>"]()

    local closed = vim.wait(200, function()
      return find_main_ui_buffer() == nil
    end, 10)
    assert.is_true(closed)

    assert.are.equal(vim.uri_to_fname(source_uri), vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.are.equal(5, cursor[1])
  end)

  it("opens selected symbol in vsplit on <C-v>", function()
    rpc_symbols = {
      {
        symbol_id = "sym-1",
        name = "split_target",
        kind = 12,
        container_name = "M",
        uri = source_uri,
        range = {
          start = { line = 1, character = 0 },
          ["end"] = { line = 1, character = 3 },
        },
        detail = nil,
        score = 1,
      },
    }

    local ui = require("code-shape.ui")
    open_ui(ui)
    set_query_and_wait("split_target")

    assert.is_function(keymaps["n:<C-v>"])
    keymaps["n:<C-v>"]()

    local closed = vim.wait(200, function()
      return find_main_ui_buffer() == nil
    end, 10)
    assert.is_true(closed)
    assert.are.equal(vim.uri_to_fname(source_uri), vim.api.nvim_buf_get_name(0))
    assert.is_true(#vim.api.nvim_list_wins() >= 2)
  end)

  it("switches to hotspots mode and renders hotspot items", function()
    hotspot_items = {
      {
        path = source_uri,
        score = 1.5,
      },
    }

    local ui = require("code-shape.ui")
    open_ui(ui)

    -- Use Tab twice to cycle from Defs -> Calls -> Hotspots
    assert.is_function(keymaps["n:<Tab>"])
    keymaps["n:<Tab>"]() -- Defs -> Calls
    keymaps["n:<Tab>"]() -- Calls -> Hotspots

    -- Wait for mode switch to complete
    vim.wait(100)

    local lines = get_main_ui_lines(3)
    assert.is_true(lines[1]:find("%[Hotspots%]") ~= nil)
    -- With separate input window, results start at line 2
    assert.is_true(lines[2]:find("File:", 1, true) ~= nil or (lines[2] and lines[2]:find("ui.lua", 1, true) ~= nil))
  end)

  it("sets nowait for hotspots window control keys", function()
    hotspot_items = {
      {
        path = source_uri,
        score = 1.5,
      },
    }

    local ui = require("code-shape.ui")
    local cfg = config.setup({})
    ui.open_hotspots(cfg)

    assert.is_true(keymap_opts["n:<CR>"].nowait)
    assert.is_true(keymap_opts["n:q"].nowait)
    assert.is_true(keymap_opts["n:<Esc>"].nowait)
  end)

  it("scales hotspots path width with current window width", function()
    local previous_columns = vim.o.columns
    vim.o.columns = 70

    local ok, err = pcall(function()
      hotspot_items = {
        {
          path = vim.uri_from_fname("/tmp/" .. string.rep("very_long_dir_name/", 8) .. "entry.lua"),
          score = 0.87,
        },
      }

      local ui = require("code-shape.ui")
      local cfg = config.setup({})
      ui.open_hotspots(cfg)

      local bufnr = find_hotspots_buffer()
      assert.is_not_nil(bufnr)

      local line = vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1]
      assert.is_not_nil(line)
      assert.is_true(vim.fn.strdisplaywidth(line) <= vim.o.columns)
      assert.is_true(line:find("...", 1, true) ~= nil)
    end)

    vim.o.columns = previous_columns
    if not ok then
      error(err)
    end
  end)

  it("passes diff options to impact analysis", function()
    local captured_opts = nil
    package.loaded["code-shape.diff"] = {
      calculate_impact = function(opts, cb)
        captured_opts = vim.deepcopy(opts)
        cb(nil, {
          base = opts.base or "HEAD",
          head = opts.head or "working",
          risk_ranking = {},
        })
      end,
    }

    local ui = require("code-shape.ui")
    local cfg = config.setup({
      ui = {
        border = "single",
      },
    })

    ui.open_impact(cfg, {
      base = "main",
      head = "feature/refactor",
      staged = true,
    })

    local completed = vim.wait(200, function()
      return captured_opts ~= nil
    end, 10)
    assert.is_true(completed)
    assert.are.same({
      base = "main",
      head = "feature/refactor",
      staged = true,
    }, captured_opts)
  end)
end)
