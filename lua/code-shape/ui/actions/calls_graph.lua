---@class CodeShapeUiCallsGraphContext
---@field state CodeShapeUiState
---@field render_results fun()
---@field update_preview fun()
local M = {}

local util = require("code-shape.util")
local ui_state = require("code-shape.ui.state")
local shared = require("code-shape.ui.actions.shared")
local is_list = shared.is_list

---@param ctx CodeShapeUiCallsGraphContext
---@return table
function M.new(ctx)
  local state = ctx.state

  local function clamp_selection()
    if #state.current_results == 0 then
      state.selected_idx = 1
      return
    end

    if state.selected_idx < 1 then
      state.selected_idx = 1
      return
    end

    if state.selected_idx > #state.current_results then
      state.selected_idx = #state.current_results
    end
  end

  ---@param query string
  ---@param case_sensitive_source string|nil
  ---@return boolean
  local function query_matches(query, case_sensitive_source)
    if query == "" then
      return true
    end
    if type(case_sensitive_source) ~= "string" then
      return false
    end
    return case_sensitive_source:lower():find(query, 1, true) ~= nil
  end

  ---@param item CodeShapeSearchResultItem
  ---@param normalized_query string
  ---@return boolean
  local function graph_item_matches(item, normalized_query)
    if normalized_query == "" then
      return true
    end

    if item.graph_section == "center" then
      return true
    end

    if query_matches(normalized_query, item.name) then
      return true
    end
    if query_matches(normalized_query, item.container_name) then
      return true
    end
    if query_matches(normalized_query, item.detail) then
      return true
    end
    return query_matches(normalized_query, shared.render_path(item.uri))
  end

  local function rebuild_calls_results()
    local graph = state.calls_graph
    if not graph then
      state.current_results = {}
      state.selected_idx = 1
      return
    end

    local normalized_query = state.current_query:lower()
    local results = {}

    local center = shared.clone_symbol_item(graph.center)
    center.graph_section = "center"
    center.graph_expandable = true
    center.graph_edge_kind = "call"
    center.graph_edge_count = 0
    table.insert(results, center)

    local function append_section(items, section)
      for _, raw in ipairs(items) do
        local item = shared.clone_symbol_item(raw)
        item.graph_section = section
        if graph_item_matches(item, normalized_query) then
          table.insert(results, item)
        end
      end
    end

    append_section(graph.incoming, "incoming")
    append_section(graph.outgoing, "outgoing")
    append_section(graph.references, "reference")

    state.current_results = results
    clamp_selection()
  end

  ---@param item CodeShapeSearchResultItem
  ---@param reset_history boolean
  local function push_calls_history(item, reset_history)
    if reset_history then
      state.calls_history = {}
      state.calls_history_idx = 0
    end

    if state.calls_history_idx < #state.calls_history then
      for i = #state.calls_history, state.calls_history_idx + 1, -1 do
        table.remove(state.calls_history, i)
      end
    end

    local top = state.calls_history[#state.calls_history]
    if top and top.symbol_id == item.symbol_id then
      state.calls_history_idx = #state.calls_history
      return
    end

    table.insert(state.calls_history, shared.clone_symbol_item(item))
    state.calls_history_idx = #state.calls_history
  end

  ---@param raw_item table
  ---@param section "incoming"|"outgoing"
  ---@param edge_count integer
  ---@return CodeShapeSearchResultItem|nil
  local function call_hierarchy_to_graph_item(raw_item, section, edge_count)
    if type(raw_item) ~= "table" or type(raw_item.uri) ~= "string" or raw_item.uri == "" then
      return nil
    end

    local range = shared.normalize_range(raw_item.selectionRange or raw_item.range)
    local item = {
      symbol_id = "",
      name = type(raw_item.name) == "string" and raw_item.name or "<anonymous>",
      kind = util.to_symbol_kind(raw_item.kind),
      container_name = type(raw_item.detail) == "string" and raw_item.detail or nil,
      uri = raw_item.uri,
      range = range,
      detail = type(raw_item.detail) == "string" and raw_item.detail or nil,
      score = 1,
      graph_section = section,
      graph_edge_kind = "call",
      graph_edge_count = edge_count,
      graph_expandable = true,
    }

    shared.ensure_symbol_id(item)
    return item
  end

  ---@param location table
  ---@return CodeShapeSearchResultItem|nil
  local function reference_to_graph_item(location)
    local uri = location.uri or location.targetUri
    local raw_range = location.range or location.targetSelectionRange
    if type(uri) ~= "string" or uri == "" or type(raw_range) ~= "table" then
      return nil
    end

    local range = shared.normalize_range(raw_range)
    local path = shared.file_uri_to_fname(uri) or uri
    local short_path = util.shorten_path(path) or path
    local line_no = range.start.line + 1
    local col_no = range.start.character + 1

    local item = {
      symbol_id = "",
      name = string.format("%s:%d:%d", vim.fn.fnamemodify(path, ":t"), line_no, col_no),
      kind = 13,
      container_name = short_path,
      uri = uri,
      range = range,
      detail = "reference",
      score = 1,
      graph_section = "reference",
      graph_edge_kind = "reference",
      graph_edge_count = 1,
      graph_expandable = false,
    }

    shared.ensure_symbol_id(item)
    return item
  end

  ---@param item CodeShapeSearchResultItem
  ---@param opts? { push_history?: boolean, reset_history?: boolean }
  local function build_calls_graph(item, opts)
    opts = opts or {}

    if not item or item.kind == 1 then
      vim.notify("code-shape: No symbol selected", vim.log.levels.INFO)
      return
    end

    local bufnr = shared.target_bufnr(item)
    if not bufnr then
      vim.notify("code-shape: Invalid symbol URI", vim.log.levels.WARN)
      return
    end

    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    if not clients or #clients == 0 then
      vim.notify("code-shape: No LSP clients attached to symbol", vim.log.levels.WARN)
      return
    end

    local refs_client = shared.pick_client(clients, "textDocument/references")

    local call_client = nil
    local has_incoming = false
    local has_outgoing = false
    for _, client in ipairs(clients) do
      local supports_prepare = client.supports_method("textDocument/prepareCallHierarchy")
      local supports_incoming = client.supports_method("callHierarchy/incomingCalls")
      local supports_outgoing = client.supports_method("callHierarchy/outgoingCalls")
      if supports_prepare and (supports_incoming or supports_outgoing) then
        call_client = client
        has_incoming = supports_incoming
        has_outgoing = supports_outgoing
        break
      end
    end

    if not call_client and not refs_client then
      vim.notify("code-shape: Call graph is not supported by attached LSP", vim.log.levels.INFO)
      return
    end

    local center = shared.clone_symbol_item(item)
    center.graph_section = "center"
    center.graph_edge_kind = "call"
    center.graph_edge_count = 0
    center.graph_expandable = true
    shared.ensure_symbol_id(center)

    state.calls_request_seq = state.calls_request_seq + 1
    local request_seq = state.calls_request_seq
    state.calls_loading = true
    state.calls_status = "Loading call/reference edges..."
    state.current_results = {}
    state.selected_idx = 1
    ctx.render_results()
    ctx.update_preview()

    local incoming_map = {}
    local outgoing_map = {}
    local reference_map = {}
    local edges = {}

    local pending = (call_client and 1 or 0) + (refs_client and 1 or 0)

    local function still_active()
      return state.calls_request_seq == request_seq
    end

    local function map_values(map)
      local values = {}
      for _, value in pairs(map) do
        table.insert(values, value)
      end
      return values
    end

    local function add_edge(caller_id, callee_id, edge_kind, uri, range)
      table.insert(edges, {
        caller_symbol_id = caller_id,
        callee_symbol_id = callee_id,
        edge_kind = edge_kind,
        evidence = {
          uri = uri,
          range = shared.normalize_range(range),
        },
      })
    end

    ---@param target_map table<string, CodeShapeSearchResultItem>
    ---@param graph_item CodeShapeSearchResultItem
    ---@param edge_count integer
    local function upsert_graph_item(target_map, graph_item, edge_count)
      local key = shared.ensure_symbol_id(graph_item)
      local existing = target_map[key]
      if existing then
        existing.graph_edge_count = (existing.graph_edge_count or 0) + edge_count
        return existing
      end

      graph_item.graph_edge_count = edge_count
      target_map[key] = graph_item
      return graph_item
    end

    local function finish_one()
      pending = pending - 1
      if pending > 0 then
        return
      end

      if not still_active() then
        return
      end

      local incoming = map_values(incoming_map)
      local outgoing = map_values(outgoing_map)
      local references = map_values(reference_map)
      shared.sort_graph_items(incoming)
      shared.sort_graph_items(outgoing)
      shared.sort_graph_items(references)

      state.calls_graph = {
        center = center,
        incoming = incoming,
        outgoing = outgoing,
        references = references,
      }
      state.calls_loading = false
      state.calls_status = nil
      state.calls_graph_updated_at = os.time()

      if opts.push_history then
        push_calls_history(center, opts.reset_history == true)
      end

      if #incoming == 0 and #outgoing == 0 and #references == 0 then
        state.calls_status = "No edges found around selected symbol"
      end

      rebuild_calls_results()
      state.selected_idx = 1
      clamp_selection()
      ctx.render_results()
      ctx.update_preview()

      if #edges > 0 then
        local rpc = require("code-shape.rpc")
        rpc.request("graph/upsertEdges", { edges = edges }, function(err)
          if err and state.current_config and state.current_config.debug then
            vim.notify("code-shape: graph/upsertEdges failed: " .. err, vim.log.levels.DEBUG)
          end
        end)
      end
    end

    if call_client then
      local prepare_params = {
        textDocument = { uri = center.uri },
        position = { line = center.range.start.line, character = center.range.start.character },
      }

      call_client.request("textDocument/prepareCallHierarchy", prepare_params, function(err, result)
        if not still_active() then
          return
        end

        if err then
          if not refs_client then
            state.calls_status = "Failed to prepare call hierarchy: " .. shared.lsp_error_message(err)
          end
          finish_one()
          return
        end

        local prepared_item = is_list(result) and result[1] or result
        if type(prepared_item) ~= "table" then
          if not refs_client then
            state.calls_status = "Call hierarchy is unavailable for selected symbol"
          end
          finish_one()
          return
        end

        local directions = {}
        if has_incoming then
          table.insert(directions, { method = "callHierarchy/incomingCalls", section = "incoming", incoming = true })
        end
        if has_outgoing then
          table.insert(directions, { method = "callHierarchy/outgoingCalls", section = "outgoing", incoming = false })
        end

        if #directions == 0 then
          finish_one()
          return
        end

        local pending_directions = #directions
        local function finish_direction()
          pending_directions = pending_directions - 1
          if pending_directions == 0 then
            finish_one()
          end
        end

        local function request_direction(method, section, incoming)
          call_client.request(method, { item = prepared_item }, function(call_err, call_result)
            if not still_active() then
              return
            end

            if call_err then
              finish_direction()
              return
            end

            local call_items = {}
            if is_list(call_result) then
              call_items = call_result
            elseif type(call_result) == "table" then
              call_items = { call_result }
            end

            for _, call_item in ipairs(call_items) do
              local raw_node = incoming and call_item.from or call_item.to
              if raw_node then
                local from_ranges = is_list(call_item.fromRanges) and call_item.fromRanges or {}
                local edge_count = #from_ranges > 0 and #from_ranges or 1
                local graph_item = call_hierarchy_to_graph_item(raw_node, section, edge_count)
                if graph_item then
                  local target_map = incoming and incoming_map or outgoing_map
                  local merged = upsert_graph_item(target_map, graph_item, edge_count)
                  if #from_ranges == 0 then
                    local fallback_range = raw_node.selectionRange or raw_node.range or merged.range
                    local evidence_uri = incoming and merged.uri or center.uri
                    add_edge(
                      incoming and merged.symbol_id or center.symbol_id,
                      incoming and center.symbol_id or merged.symbol_id,
                      "call",
                      evidence_uri,
                      fallback_range
                    )
                  else
                    local evidence_uri = incoming and merged.uri or center.uri
                    for _, raw_range in ipairs(from_ranges) do
                      add_edge(
                        incoming and merged.symbol_id or center.symbol_id,
                        incoming and center.symbol_id or merged.symbol_id,
                        "call",
                        evidence_uri,
                        raw_range
                      )
                    end
                  end
                end
              end
            end

            finish_direction()
          end, bufnr)
        end

        for _, direction in ipairs(directions) do
          request_direction(direction.method, direction.section, direction.incoming)
        end
      end, bufnr)
    end

    if refs_client then
      local refs_params = {
        textDocument = { uri = center.uri },
        position = { line = center.range.start.line, character = center.range.start.character },
        context = { includeDeclaration = false },
      }

      refs_client.request("textDocument/references", refs_params, function(err, result)
        if not still_active() then
          return
        end

        if err then
          finish_one()
          return
        end

        local refs = {}
        if is_list(result) then
          refs = result
        elseif type(result) == "table" then
          refs = { result }
        end

        for _, loc in ipairs(refs) do
          local ref_item = reference_to_graph_item(loc)
          if ref_item then
            local merged = upsert_graph_item(reference_map, ref_item, 1)
            add_edge(merged.symbol_id, center.symbol_id, "reference", merged.uri, merged.range)
          end
        end

        finish_one()
      end, bufnr)
    end

    if pending == 0 then
      state.calls_loading = false
      state.calls_status = "No call/reference providers available"
      rebuild_calls_results()
      ctx.render_results()
      ctx.update_preview()
    end
  end

  local function follow_graph_node()
    if state.current_mode ~= ui_state.MODE_CALLS then
      return
    end

    local item = state.current_results[state.selected_idx]
    if not item then
      vim.notify("code-shape: No symbol selected", vim.log.levels.INFO)
      return
    end

    if not item.graph_expandable then
      vim.notify("code-shape: This node cannot be expanded", vim.log.levels.INFO)
      return
    end

    local current_center = state.calls_graph and state.calls_graph.center or nil
    if current_center and current_center.symbol_id == item.symbol_id then
      build_calls_graph(current_center, { push_history = false })
      return
    end

    build_calls_graph(item, { push_history = true })
  end

  local function calls_back()
    if state.current_mode ~= ui_state.MODE_CALLS then
      return
    end

    if state.calls_history_idx <= 1 then
      vim.notify("code-shape: No previous call-graph node", vim.log.levels.INFO)
      return
    end

    state.calls_history_idx = state.calls_history_idx - 1
    local target = state.calls_history[state.calls_history_idx]
    if not target then
      vim.notify("code-shape: No previous call-graph node", vim.log.levels.INFO)
      return
    end

    build_calls_graph(target, { push_history = false })
  end

  local function refresh_calls_graph()
    if state.current_mode ~= ui_state.MODE_CALLS then
      return
    end

    local center = state.calls_graph and state.calls_graph.center or nil
    if not center then
      local item = state.current_results[state.selected_idx]
      if item and item.kind ~= 1 then
        build_calls_graph(item, { push_history = true, reset_history = true })
        return
      end
      vim.notify("code-shape: No call-graph node to refresh", vim.log.levels.INFO)
      return
    end

    build_calls_graph(center, { push_history = false })
  end

  return {
    rebuild_calls_results = rebuild_calls_results,
    build_calls_graph = build_calls_graph,
    follow_graph_node = follow_graph_node,
    calls_back = calls_back,
    refresh_calls_graph = refresh_calls_graph,
  }
end

return M
