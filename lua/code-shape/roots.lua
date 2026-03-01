---@class CodeShapeRoots
local M = {}

local util = require("code-shape.util")

---@type table<string, boolean>
local active_roots = {}

---Register a URI and track its git root
---@param uri string file:// URI
---@return string|nil git_root path or nil
function M.register_uri(uri)
  local path = util.file_uri_to_fname(uri)
  if not path then
    return nil
  end
  local dir = util.dirname(path)
  local root = util.find_git_root(dir)
  if root then
    active_roots[root] = true
  end
  return root
end

---Get all active git roots (sorted)
---@return string[]
function M.get_roots()
  local result = {}
  for root in pairs(active_roots) do
    table.insert(result, root)
  end
  table.sort(result)
  return result
end

---Get git root for a given URI
---@param uri string
---@return string|nil
function M.root_for_uri(uri)
  local path = util.file_uri_to_fname(uri)
  if not path then
    return nil
  end
  local dir = util.dirname(path)
  return util.find_git_root(dir)
end

---Clear all tracked roots
function M.clear()
  active_roots = {}
end

return M
