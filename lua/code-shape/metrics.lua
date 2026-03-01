---@class CodeShapeMetricsModule
local M = {}

-- LSP SymbolKind values that represent computable (function-like) symbols
local COMPUTABLE_KINDS = {
  [6] = true, -- Method
  [9] = true, -- Constructor
  [12] = true, -- Function
}

-- Language-specific decision node types for cyclomatic complexity
---@type table<string, table<string, boolean>>
local DECISION_NODES = {
  lua = {
    if_statement = true,
    elseif_clause = true,
    for_statement = true,
    for_in_statement = true,
    while_statement = true,
    repeat_statement = true,
  },
  javascript = {
    if_statement = true,
    for_statement = true,
    for_in_statement = true,
    while_statement = true,
    do_statement = true,
    switch_case = true,
    catch_clause = true,
    ternary_expression = true,
  },
  typescript = {
    if_statement = true,
    for_statement = true,
    for_in_statement = true,
    while_statement = true,
    do_statement = true,
    switch_case = true,
    catch_clause = true,
    ternary_expression = true,
  },
  tsx = {
    if_statement = true,
    for_statement = true,
    for_in_statement = true,
    while_statement = true,
    do_statement = true,
    switch_case = true,
    catch_clause = true,
    ternary_expression = true,
  },
  python = {
    if_statement = true,
    elif_clause = true,
    for_statement = true,
    while_statement = true,
    except_clause = true,
    conditional_expression = true,
  },
  go = {
    if_statement = true,
    for_statement = true,
    expression_case = true,
    type_case = true,
  },
  rust = {
    if_expression = true,
    for_expression = true,
    while_expression = true,
    loop_expression = true,
    match_arm = true,
  },
}

-- Logical operator node types that add to cyclomatic complexity
---@type table<string, table<string, string[]>>
local LOGICAL_OPS = {
  lua = { binary_expression = { "and", "or" } },
  javascript = { binary_expression = { "&&", "||" } },
  typescript = { binary_expression = { "&&", "||" } },
  tsx = { binary_expression = { "&&", "||" } },
  python = { boolean_operator = { "and", "or" } },
  rust = { binary_expression = { "&&", "||" } },
}

-- Node types that represent nesting control flow structures
---@type table<string, boolean>
local NESTING_NODES = {
  if_statement = true,
  if_expression = true,
  elseif_clause = true,
  elif_clause = true,
  for_statement = true,
  for_in_statement = true,
  for_expression = true,
  while_statement = true,
  while_expression = true,
  repeat_statement = true,
  do_statement = true,
  loop_expression = true,
  switch_statement = true,
  match_expression = true,
  try_statement = true,
  catch_clause = true,
  except_clause = true,
}

-- Generic fallback decision nodes for unlisted languages
---@type table<string, boolean>
local GENERIC_DECISION_NODES = {
  if_statement = true,
  if_expression = true,
  elseif_clause = true,
  elif_clause = true,
  for_statement = true,
  for_in_statement = true,
  for_expression = true,
  while_statement = true,
  while_expression = true,
  repeat_statement = true,
  do_statement = true,
  loop_expression = true,
  switch_case = true,
  expression_case = true,
  match_arm = true,
  catch_clause = true,
  except_clause = true,
  ternary_expression = true,
  conditional_expression = true,
}

---@param lang string
---@return table<string, boolean>
local function get_decision_nodes(lang)
  return DECISION_NODES[lang] or GENERIC_DECISION_NODES
end

---Check if a logical operator node adds to complexity
---@param lang string
---@param node TSNode
---@param bufnr integer
---@return boolean
local function is_logical_op(lang, node, bufnr)
  local ops = LOGICAL_OPS[lang]
  if not ops then
    return false
  end

  local node_type = node:type()
  local allowed_ops = ops[node_type]
  if not allowed_ops then
    return false
  end

  -- Check the operator child node text
  local child_count = node:child_count()
  for i = 0, child_count - 1 do
    local child = node:child(i)
    if child and child:named() == false then
      local text = vim.treesitter.get_node_text(child, bufnr)
      for _, op in ipairs(allowed_ops) do
        if text == op then
          return true
        end
      end
    end
  end

  return false
end

---Walk tree-sitter node descendants and compute metrics
---@param node TSNode
---@param bufnr integer
---@param lang string
---@param decision_nodes table<string, boolean>
---@param depth integer current nesting depth
---@return integer complexity_additions
---@return integer max_depth
local function walk_node(node, bufnr, lang, decision_nodes, depth)
  local complexity = 0
  local max_depth = depth

  local child_count = node:child_count()
  for i = 0, child_count - 1 do
    local child = node:child(i)
    if child then
      local child_type = child:type()
      local child_depth = depth

      if decision_nodes[child_type] then
        complexity = complexity + 1
      end

      if is_logical_op(lang, child, bufnr) then
        complexity = complexity + 1
      end

      if NESTING_NODES[child_type] then
        child_depth = depth + 1
        if child_depth > max_depth then
          max_depth = child_depth
        end
      end

      local sub_complexity, sub_depth = walk_node(child, bufnr, lang, decision_nodes, child_depth)
      complexity = complexity + sub_complexity
      if sub_depth > max_depth then
        max_depth = sub_depth
      end
    end
  end

  return complexity, max_depth
end

---Compute metrics for a tree-sitter node representing a function/method
---@param bufnr integer
---@param lang string
---@param symbol_node TSNode
---@return CodeShapeMetrics|nil
function M.compute(bufnr, lang, symbol_node)
  if not symbol_node then
    return nil
  end

  local start_line = symbol_node:start()
  local end_line = symbol_node:end_()
  local lines_of_code = end_line - start_line + 1

  local decision_nodes = get_decision_nodes(lang)
  local complexity_additions, max_depth = walk_node(symbol_node, bufnr, lang, decision_nodes, 0)
  local cyclomatic_complexity = 1 + complexity_additions

  return {
    cyclomatic_complexity = cyclomatic_complexity,
    lines_of_code = lines_of_code,
    nesting_depth = max_depth,
  }
end

---Compute metrics for a range (used in LSP path)
---Finds the enclosing function node from the range start position
---@param bufnr integer
---@param lang string
---@param range CodeShapeRange
---@return CodeShapeMetrics|nil
function M.compute_for_range(bufnr, lang, range)
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = bufnr,
    pos = { range.start.line, range.start.character },
  })
  if not ok or not node then
    return nil
  end

  -- Walk up to find a function-like node
  local current = node
  while current do
    local node_type = current:type()
    if
      node_type:find("function")
      or node_type:find("method")
      or node_type == "function_definition"
      or node_type == "function_declaration"
      or node_type == "method_declaration"
      or node_type == "method_definition"
      or node_type == "function_item"
      or node_type == "arrow_function"
      or node_type == "lambda"
    then
      return M.compute(bufnr, lang, current)
    end
    current = current:parent()
  end

  return nil
end

---Check if a symbol kind is computable (function-like)
---@param kind integer LSP SymbolKind
---@return boolean
function M.is_computable_kind(kind)
  return COMPUTABLE_KINDS[kind] == true
end

return M
