-- nvim-treesitter.predicates
-- Registers custom Treesitter query predicates used in .scm query files.
--
-- Predicates extend the Treesitter query language with custom match conditions.
-- They are referenced in .scm files with the #predicate? syntax, e.g.:
--   ((identifier) @name (#kind-eq? @name "function_definition"))
--
-- Registered predicates:
--   #kind-eq?      – ALL nodes bound to a capture must match one of the given types.
--   #any-kind-eq?  – AT LEAST ONE node bound to a capture must match one of the given types.
--
-- Both predicates are registered with { force = true } so they overwrite any
-- previously registered version of the same name. This is required for CI
-- environments where the module may be reloaded between test runs.

local query = vim.treesitter.query

-- Table of predicate implementation functions, exported so they can be tested
-- independently of the query engine (i.e., called directly in unit tests
-- without needing a live Treesitter match).
local predicates = {}

--- Core implementation shared by both #kind-eq? and #any-kind-eq?.
---
--- Checks whether the nodes bound to a capture in a query match satisfy a
--- node-type (kind) condition. The `any` flag controls the quantifier:
---   any = false  →  ALL nodes must match one of the allowed types (universal).
---   any = true   →  AT LEAST ONE node must match one of the allowed types (existential).
---
--- @param match table<integer, TSNode[]>
---   The match table from the Treesitter query engine, mapping capture IDs
---   to the list of nodes bound to that capture in this match.
--- @param pred any[]
---   The predicate argument list as parsed from the .scm file:
---     pred[1]  – predicate name string (e.g. 'kind-eq?'), unused here.
---     pred[2]  – capture ID (integer) identifying which capture to inspect.
---     pred[3+] – one or more node type strings to match against (e.g. 'identifier').
--- @param any boolean
---   true  → existential quantifier (#any-kind-eq? semantics).
---   false → universal quantifier  (#kind-eq? semantics).
--- @return boolean
---   true if the condition is satisfied, false otherwise.
---
--- Boundary cases:
---   - If the capture is absent from the match (nodes is nil or empty), returns
---     true unconditionally. This matches Treesitter's convention that predicates
---     on absent captures are vacuously satisfied (do not reject the match).
---   - For any = false with zero nodes: the universal condition is vacuously true.
---   - For any = true  with zero nodes: the existential condition is vacuously
---     false, but the early-return on empty nodes means true is returned instead
---     (same "absent capture" convention as above).
function predicates.kind_eq(match, pred, any)
  local nodes = match[pred[2]]

  -- Absent or empty capture: vacuously satisfied — do not reject the match.
  if not nodes or #nodes == 0 then
    return true
  end

  -- Build a set of allowed node types from pred[3] onward for O(1) lookup.
  local allowed = {}
  for i = 3, #pred do
    allowed[pred[i]] = true
  end

  for _, node in ipairs(nodes) do
    local node_type = node:type()
    local matched = allowed[node_type] ~= nil

    if any then
      -- Existential: return true as soon as one node matches.
      if matched then
        return true
      end
    elseif not matched then
      -- Universal: return false as soon as one node does NOT match.
      return false
    end
  end

  -- Universal (any=false): all nodes matched → true.
  -- Existential (any=true): no node matched → false.
  return not any
end

-- ── Predicate registration ────────────────────────────────────────────────────

--- #kind-eq? @capture type1 [type2 ...]
--- Universal predicate: the match is accepted only if ALL nodes bound to
--- @capture have a node type that appears in the allowed type list.
---
--- Example (.scm):
---   ((node) @n (#kind-eq? @n "identifier" "property_identifier"))
---   -- Accepts only if every node bound to @n is an identifier or property_identifier.
---
--- @param match table<integer, TSNode[]>
--- @param pred  any[]
--- @return boolean
query.add_predicate('kind-eq?', function(match, _, _, pred)
  return predicates.kind_eq(match, pred, false)
end, { force = true })

--- #any-kind-eq? @capture type1 [type2 ...]
--- Existential predicate: the match is accepted if AT LEAST ONE node bound
--- to @capture has a node type that appears in the allowed type list.
---
--- Example (.scm):
---   ((node) @n (#any-kind-eq? @n "string" "template_string"))
---   -- Accepts if any node bound to @n is a string or template_string.
---
--- @param match table<integer, TSNode[]>
--- @param pred  any[]
--- @return boolean
query.add_predicate('any-kind-eq?', function(match, _, _, pred)
  return predicates.kind_eq(match, pred, true)
end, { force = true })

-- Export the predicate implementations for unit testing.
-- Callers can invoke predicates.kind_eq() directly without going through
-- the query engine, making it easy to test edge cases in isolation.
return predicates
