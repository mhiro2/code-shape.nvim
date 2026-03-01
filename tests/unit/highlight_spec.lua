describe("highlight", function()
  local highlight
  local original_set_hl
  local calls

  before_each(function()
    package.loaded["code-shape.highlight"] = nil
    highlight = require("code-shape.highlight")
    original_set_hl = vim.api.nvim_set_hl
    calls = {}

    vim.api.nvim_set_hl = function(_ns_id, group, opts)
      calls[group] = vim.deepcopy(opts)
    end
  end)

  after_each(function()
    vim.api.nvim_set_hl = original_set_hl
    package.loaded["code-shape.highlight"] = nil
  end)

  it("defines default highlight links", function()
    highlight.setup()

    assert.are.same({ default = true, link = "Visual" }, calls.CodeShapeSelected)
    assert.are.same({ default = true, link = "PmenuSel" }, calls.CodeShapeMode)
    assert.are.same({ default = true, link = "Title" }, calls.CodeShapeTitle)
    assert.are.same({ default = true, link = "Search" }, calls.CodeShapePreviewLine)
    assert.are.same({ default = true, link = "Comment" }, calls.CodeShapeHint)
  end)
end)
