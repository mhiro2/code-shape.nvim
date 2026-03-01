---@class CodeShapeUiLspContext
---@field state CodeShapeUiState
---@field close fun()
---@field jump_to_symbol fun(item: CodeShapeSearchResultItem)
local M = {}

local shared = require("code-shape.ui.actions.shared")
local is_list = shared.is_list

---@param ctx CodeShapeUiLspContext
---@return table
function M.new(ctx)
  local state = ctx.state

  local function goto_definition()
    local item = state.current_results[state.selected_idx]
    if not item then
      return
    end

    if item.kind == 1 then
      ctx.jump_to_symbol(item)
      return
    end

    local path = shared.file_uri_to_fname(item.uri)
    if not path then
      vim.notify("code-shape: Cannot open non-file URI", vim.log.levels.WARN)
      return
    end

    ctx.close()
    shared.open_symbol_with_cmd("edit", item, path)

    local params = {
      textDocument = { uri = item.uri },
      position = { line = item.range.start.line, character = item.range.start.character },
    }

    vim.lsp.buf_request(0, "textDocument/definition", params, function(err, result)
      if err or not result then
        return
      end

      local location = is_list(result) and result[1] or result
      if location then
        local uri = location.uri or location.targetUri
        local range = location.range or location.targetSelectionRange
        if uri and range then
          local def_path = shared.file_uri_to_fname(uri)
          if not def_path then
            vim.notify("code-shape: definition target is not a file URI", vim.log.levels.INFO)
            return
          end
          if def_path ~= vim.fn.expand("%:p") then
            vim.api.nvim_cmd({ cmd = "edit", args = { def_path } }, {})
          end
          vim.api.nvim_win_set_cursor(0, { range.start.line + 1, range.start.character })
          vim.api.nvim_cmd({ cmd = "normal", args = { "zz" }, bang = true }, {})
        end
      end
    end)
  end

  local function show_references()
    local item = state.current_results[state.selected_idx]
    if not item or item.kind == 1 then
      vim.notify("code-shape: No symbol selected", vim.log.levels.INFO)
      return
    end

    local bufnr = shared.target_bufnr(item)
    if not bufnr then
      vim.notify("code-shape: Invalid symbol URI", vim.log.levels.WARN)
      return
    end

    local params = {
      textDocument = { uri = item.uri },
      position = { line = item.range.start.line, character = item.range.start.character },
      context = { includeDeclaration = true },
    }

    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    local refs_client = shared.pick_client(clients, "textDocument/references")

    if not refs_client then
      vim.notify("code-shape: No LSP client supports references", vim.log.levels.WARN)
      return
    end

    refs_client.request("textDocument/references", params, function(err, result)
      if err then
        vim.notify("code-shape: Failed to get references: " .. shared.lsp_error_message(err), vim.log.levels.WARN)
        return
      end
      if not is_list(result) or #result == 0 then
        vim.notify("code-shape: No references found", vim.log.levels.INFO)
        return
      end

      local items = {}
      for _, loc in ipairs(result) do
        local loc_path = shared.file_uri_to_fname(loc.uri)
        if loc_path then
          table.insert(items, {
            filename = loc_path,
            lnum = loc.range.start.line + 1,
            col = loc.range.start.character + 1,
            text = item.name,
          })
        end
      end

      if #items == 0 then
        vim.notify("code-shape: No file references found", vim.log.levels.INFO)
        return
      end

      vim.fn.setqflist(items, "r", { title = "References: " .. item.name })
      vim.api.nvim_cmd({ cmd = "copen" }, {})
    end, bufnr)
  end

  return {
    goto_definition = goto_definition,
    show_references = show_references,
  }
end

return M
