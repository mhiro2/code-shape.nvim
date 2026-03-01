local metrics = require("code-shape.metrics")

describe("metrics", function()
  describe("module structure", function()
    it("has compute function", function()
      assert.is_function(metrics.compute)
    end)

    it("has compute_for_range function", function()
      assert.is_function(metrics.compute_for_range)
    end)

    it("has is_computable_kind function", function()
      assert.is_function(metrics.is_computable_kind)
    end)
  end)

  describe("is_computable_kind", function()
    it("returns true for Function (12)", function()
      assert.is_true(metrics.is_computable_kind(12))
    end)

    it("returns true for Method (6)", function()
      assert.is_true(metrics.is_computable_kind(6))
    end)

    it("returns true for Constructor (9)", function()
      assert.is_true(metrics.is_computable_kind(9))
    end)

    it("returns false for Class (5)", function()
      assert.is_false(metrics.is_computable_kind(5))
    end)

    it("returns false for Variable (13)", function()
      assert.is_false(metrics.is_computable_kind(13))
    end)

    it("returns false for Interface (23)", function()
      assert.is_false(metrics.is_computable_kind(23))
    end)
  end)

  describe("compute", function()
    it("returns nil for nil node", function()
      assert.is_nil(metrics.compute(0, "lua", nil))
    end)

    it("computes metrics for a simple lua function", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "local function simple()",
        "  return 1",
        "end",
      })

      local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "lua")
      if not has_parser or not parser then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        pending("lua tree-sitter parser not available")
        return
      end

      local trees = parser:parse()
      local root = trees[1]:root()

      -- Find the function_declaration node
      local func_node = nil
      for child in root:iter_children() do
        if child:type() == "function_declaration" then
          func_node = child
          break
        end
      end

      if not func_node then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        pending("could not find function_declaration node")
        return
      end

      local result = metrics.compute(bufnr, "lua", func_node)
      assert.is_not_nil(result)
      assert.are.equal(1, result.cyclomatic_complexity) -- base complexity
      assert.are.equal(3, result.lines_of_code)
      assert.are.equal(0, result.nesting_depth)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("counts if_statement as decision node for lua", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "local function with_if(x)",
        "  if x > 0 then",
        "    return x",
        "  end",
        "  return 0",
        "end",
      })

      local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "lua")
      if not has_parser or not parser then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        pending("lua tree-sitter parser not available")
        return
      end

      local trees = parser:parse()
      local root = trees[1]:root()

      local func_node = nil
      for child in root:iter_children() do
        if child:type() == "function_declaration" then
          func_node = child
          break
        end
      end

      if not func_node then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        pending("could not find function_declaration node")
        return
      end

      local result = metrics.compute(bufnr, "lua", func_node)
      assert.is_not_nil(result)
      assert.are.equal(2, result.cyclomatic_complexity) -- 1 base + 1 if
      assert.are.equal(6, result.lines_of_code)
      assert.are.equal(1, result.nesting_depth)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("counts nested control flow for nesting depth", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "local function nested(x, y)",
        "  if x > 0 then",
        "    for i = 1, y do",
        "      if i > x then",
        "        return i",
        "      end",
        "    end",
        "  end",
        "  return 0",
        "end",
      })

      local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "lua")
      if not has_parser or not parser then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        pending("lua tree-sitter parser not available")
        return
      end

      local trees = parser:parse()
      local root = trees[1]:root()

      local func_node = nil
      for child in root:iter_children() do
        if child:type() == "function_declaration" then
          func_node = child
          break
        end
      end

      if not func_node then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        pending("could not find function_declaration node")
        return
      end

      local result = metrics.compute(bufnr, "lua", func_node)
      assert.is_not_nil(result)
      assert.are.equal(4, result.cyclomatic_complexity) -- 1 base + 1 if + 1 for + 1 if
      assert.are.equal(10, result.lines_of_code)
      assert.are.equal(3, result.nesting_depth) -- if > for > if

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("compute_for_range", function()
    it("returns nil when tree-sitter is not available", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("filetype", "text", { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "plain text" })

      local result = metrics.compute_for_range(bufnr, "text", {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 10 },
      })
      assert.is_nil(result)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
