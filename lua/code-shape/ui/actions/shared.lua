---@class CodeShapeUiActionsShared
local M = {}

local util = require("code-shape.util")

M.is_list = vim.islist

---@param err any
---@return string
function M.lsp_error_message(err)
  if type(err) == "table" and type(err.message) == "string" then
    return err.message
  end
  return tostring(err)
end

---@param range any
---@return CodeShapeRange
function M.normalize_range(range)
  local safe_range = type(range) == "table" and range or {}
  local start_pos = type(safe_range.start) == "table" and safe_range.start or {}
  local end_pos = type(safe_range["end"]) == "table" and safe_range["end"] or {}
  return {
    start = {
      line = type(start_pos.line) == "number" and start_pos.line or 0,
      character = type(start_pos.character) == "number" and start_pos.character or 0,
    },
    ["end"] = {
      line = type(end_pos.line) == "number" and end_pos.line or 0,
      character = type(end_pos.character) == "number" and end_pos.character or 0,
    },
  }
end

---@param item CodeShapeSearchResultItem
---@return integer|nil
function M.target_bufnr(item)
  if type(item.uri) ~= "string" or item.uri == "" then
    return nil
  end

  local ok, bufnr = pcall(vim.uri_to_bufnr, item.uri)
  if not ok or type(bufnr) ~= "number" or bufnr < 1 then
    return nil
  end
  return bufnr
end

---@param item CodeShapeSearchResultItem
---@return CodeShapeSearchResultItem
function M.clone_symbol_item(item)
  return {
    symbol_id = item.symbol_id or "",
    name = item.name or "",
    kind = item.kind or 0,
    container_name = item.container_name,
    uri = item.uri or "",
    range = M.normalize_range(item.range),
    detail = item.detail,
    score = item.score or 0,
    graph_section = item.graph_section,
    graph_edge_kind = item.graph_edge_kind,
    graph_edge_count = item.graph_edge_count,
    graph_expandable = item.graph_expandable,
  }
end

---@param item CodeShapeSearchResultItem
---@return string
function M.ensure_symbol_id(item)
  if type(item.symbol_id) == "string" and item.symbol_id ~= "" then
    return item.symbol_id
  end
  item.symbol_id =
    util.generate_symbol_id(item.uri or "", item.name or "", item.kind or 0, M.normalize_range(item.range))
  return item.symbol_id
end

---@param uri string
---@return string|nil path
function M.file_uri_to_fname(uri)
  return util.file_uri_to_fname(uri)
end

---@param uri string
---@return string
function M.uri_display_path(uri)
  return util.uri_display_path(uri)
end

---@param cmd "edit"|"split"|"vsplit"
---@param item CodeShapeSearchResultItem
---@param path string
function M.open_symbol_with_cmd(cmd, item, path)
  vim.api.nvim_cmd({ cmd = cmd, args = { path } }, {})
  local line = item.range.start.line + 1
  local col = item.range.start.character
  vim.api.nvim_win_set_cursor(0, { line, col })
end

---@param clients vim.lsp.Client[]
---@param method string
---@return vim.lsp.Client|nil
function M.pick_client(clients, method)
  for _, client in ipairs(clients) do
    if client.supports_method(method) then
      return client
    end
  end
  return nil
end

---@param uri string
---@return string
function M.render_path(uri)
  local path = util.uri_display_path(uri)
  return util.shorten_path(path) or path
end

---@param items CodeShapeSearchResultItem[]
function M.sort_graph_items(items)
  table.sort(items, function(a, b)
    local a_count = a.graph_edge_count or 0
    local b_count = b.graph_edge_count or 0
    if a_count ~= b_count then
      return a_count > b_count
    end

    if a.name ~= b.name then
      return a.name < b.name
    end

    if a.uri ~= b.uri then
      return a.uri < b.uri
    end

    local a_line = a.range and a.range.start and a.range.start.line or 0
    local b_line = b.range and b.range.start and b.range.start.line or 0
    if a_line ~= b_line then
      return a_line < b_line
    end

    local a_col = a.range and a.range.start and a.range.start.character or 0
    local b_col = b.range and b.range.start and b.range.start.character or 0
    return a_col < b_col
  end)
end

return M
