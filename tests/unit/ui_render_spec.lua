describe("ui.render", function()
  local render
  local preview_buf
  local original_fs_open
  local original_now
  local original_treesitter_start

  before_each(function()
    original_fs_open = vim.uv.fs_open
    original_now = vim.uv.now
    original_treesitter_start = vim.treesitter and vim.treesitter.start or nil
    package.loaded["code-shape.ui.render"] = nil
    render = require("code-shape.ui.render")
    preview_buf = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    vim.uv.fs_open = original_fs_open
    vim.uv.now = original_now
    if vim.treesitter then
      vim.treesitter.start = original_treesitter_start
    end
    if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
      vim.api.nvim_buf_delete(preview_buf, { force = true })
    end
  end)

  it("update_preview degrades safely for non-file URI", function()
    local state = {
      preview_buf = preview_buf,
      current_results = {
        {
          uri = "jdt://workspace/Foo",
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 1 },
          },
        },
      },
      selected_idx = 1,
      current_config = { debug = false },
    }

    render.update_preview(state)

    local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
    assert.are.same({ "No preview available" }, lines)
  end)

  it("uses cached file lines for consecutive preview updates on same file", function()
    local tmp_path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line1", "line2", "line3", "line4" }, tmp_path)

    local open_calls = 0
    vim.uv.fs_open = function(...)
      open_calls = open_calls + 1
      return original_fs_open(...)
    end

    local uri = vim.uri_from_fname(tmp_path)
    local state = {
      preview_buf = preview_buf,
      current_results = {
        {
          uri = uri,
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 4 },
          },
        },
        {
          uri = uri,
          range = {
            start = { line = 2, character = 0 },
            ["end"] = { line = 2, character = 4 },
          },
        },
      },
      selected_idx = 1,
      current_config = { debug = false },
    }

    render.update_preview(state)
    state.selected_idx = 2
    render.update_preview(state)

    assert.are.equal(1, open_calls)
    os.remove(tmp_path)
  end)

  it("invalidates preview cache when file content changes", function()
    local tmp_path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line1", "line2" }, tmp_path)

    local open_calls = 0
    vim.uv.fs_open = function(...)
      open_calls = open_calls + 1
      return original_fs_open(...)
    end

    local state = {
      preview_buf = preview_buf,
      current_results = {
        {
          uri = vim.uri_from_fname(tmp_path),
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 4 },
          },
        },
      },
      selected_idx = 1,
      current_config = { debug = false },
    }

    render.update_preview(state)
    vim.fn.writefile({ "line1-updated", "line2" }, tmp_path)
    render.update_preview(state)

    assert.are.equal(2, open_calls)
    local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
    local preview = table.concat(lines, "\n")
    assert.is_true(preview:find("line1%-updated") ~= nil)
    os.remove(tmp_path)
  end)

  it("evicts least-recently-used preview cache entry when capacity is exceeded", function()
    local paths = {}
    for i = 1, 6 do
      local path = string.format("%s-%d.lua", vim.fn.tempname(), i)
      vim.fn.writefile({ string.format("line%d", i) }, path)
      table.insert(paths, path)
    end

    local open_calls = 0
    vim.uv.fs_open = function(...)
      open_calls = open_calls + 1
      return original_fs_open(...)
    end

    local now_tick = 0
    vim.uv.now = function()
      now_tick = now_tick + 1
      return now_tick
    end

    local current_results = {}
    for _, path in ipairs(paths) do
      table.insert(current_results, {
        uri = vim.uri_from_fname(path),
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 5 },
        },
      })
    end
    local state = {
      preview_buf = preview_buf,
      current_results = current_results,
      selected_idx = 1,
      current_config = { debug = false },
    }

    for idx = 1, #paths do
      state.selected_idx = idx
      render.update_preview(state)
    end

    state.selected_idx = 1
    render.update_preview(state)

    assert.are.equal(7, open_calls)
    for _, path in ipairs(paths) do
      os.remove(path)
    end
  end)

  it("starts treesitter for preview buffer when filetype is detected", function()
    local tmp_path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local x = 1" }, tmp_path)

    local ts_calls = {}
    if vim.treesitter then
      vim.treesitter.start = function(bufnr, lang)
        table.insert(ts_calls, { bufnr = bufnr, lang = lang })
      end
    end

    local state = {
      preview_buf = preview_buf,
      current_results = {
        {
          uri = vim.uri_from_fname(tmp_path),
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 4 },
          },
        },
      },
      selected_idx = 1,
      current_config = { debug = false },
    }

    render.update_preview(state)

    assert.is_true(#ts_calls >= 1)
    local found = false
    for _, call in ipairs(ts_calls) do
      if call.bufnr == preview_buf and call.lang == "lua" then
        found = true
        break
      end
    end
    assert.is_true(found)
    os.remove(tmp_path)
  end)
end)
