---@class CodeShapeHighlight
local M = {}

---@param group string
---@param fallback string
local function set_default_link(group, fallback)
  vim.api.nvim_set_hl(0, group, { default = true, link = fallback })
end

function M.setup()
  set_default_link("CodeShapeSelected", "Visual")
  set_default_link("CodeShapeMode", "PmenuSel")
  set_default_link("CodeShapeTitle", "Title")
  set_default_link("CodeShapePreviewLine", "Search")
  set_default_link("CodeShapeHint", "Comment")
end

return M
