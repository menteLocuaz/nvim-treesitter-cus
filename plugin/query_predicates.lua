local query = vim.treesitter.query

local predicates = {
  --- @param match table<integer, TSNode[]>
  --- @param pred any[]
  --- @param any boolean
  --- @return boolean
  ['kind-eq'] = function(match, pred, any)
    local nodes = match[pred[2]]
    if not nodes or #nodes == 0 then
      -- Preserve the original behavior:
      -- Empty captures (e.g. optional nodes) do not cause the predicate to fail.
      return true
    end

    for _, node in ipairs(nodes) do
      local node_type = node:type()
      local is_match = false

      -- OPTIMIZATION: Search directly in the 'pred' array without creating new tables.
      for i = 3, #pred do
        if pred[i] == node_type then
          is_match = true
          break
        end
      end

      if any and is_match then
        return true
      elseif not any and not is_match then
        return false
      end
    end

    return not any
  end,
}

-- Register predicates (The function signature
-- function(match, pattern, bufnr, pred) is correct in Neovim 0.10+).

--- @param match table<integer, TSNode[]>
--- @param pred any[]
--- @return boolean
query.add_predicate('kind-eq?', function(match, _, _, pred)
  return predicates['kind-eq'](match, pred, false)
end, { force = true })

--- @param match table<integer, TSNode[]>
--- @param pred any[]
--- @return boolean
query.add_predicate('any-kind-eq?', function(match, _, _, pred)
  return predicates['kind-eq'](match, pred, true)
end, { force = true })
