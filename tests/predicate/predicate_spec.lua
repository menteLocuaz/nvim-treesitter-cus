
-- ======================================================================
-- 1. SETUP AND MOCKS
-- ======================================================================

-- Mock the vim.treesitter.query API to prevent errors outside Neovim.
_G.vim = { treesitter = { query = {} } }

local registered_predicates = {}

vim.treesitter.query.add_predicate = function(name, handler, opts)
  registered_predicates[name] = handler
end

-- LOAD THE CODE (Copy and paste the refactored code here in a real environment.
-- For this test, we assume the code above has already been executed and
-- populated `registered_predicates`.)

-- Mock a TSNode.
local function make_node(type_name)
  return {
    type = function()
      return type_name
    end
  }
end

-- ======================================================================
-- 2. TESTS
-- ======================================================================

local function test_kind_eq_all_nodes_match()
  local handler = registered_predicates['kind-eq?']

  -- Capture 1 contains two nodes, both of which are "string" or "identifier".
  local match = {
    [1] = { make_node("string"), make_node("identifier") }
  }

  -- (#kind-eq? @1 "string" "identifier")
  local pred = { "kind-eq?", 1, "string", "identifier" }

  local result = handler(match, nil, nil, pred)
  assert(result == true, "Failure: ALL nodes match the allowed list.")
end

local function test_kind_eq_one_node_does_not_match()
  local handler = registered_predicates['kind-eq?']

  local match = {
    [1] = { make_node("string"), make_node("number") }
  }
  local pred = { "kind-eq?", 1, "string", "identifier" }

  local result = handler(match, nil, nil, pred)
  assert(result == false, "Failure: One node is 'number'. It should return false because not all nodes match.")
end

local function test_any_kind_eq_at_least_one_matches()
  local handler = registered_predicates['any-kind-eq?']

  -- Only one of the nodes matches ("string").
  local match = {
    [1] = { make_node("number"), make_node("string") }
  }
  local pred = { "any-kind-eq?", 1, "string", "identifier" }

  local result = handler(match, nil, nil, pred)
  assert(result == true, "Failure: At least ONE node matches ('string'). It should return true.")
end

local function test_any_kind_eq_no_nodes_match()
  local handler = registered_predicates['any-kind-eq?']

  local match = {
    [1] = { make_node("number"), make_node("boolean") }
  }
  local pred = { "any-kind-eq?", 1, "string", "identifier" }

  local result = handler(match, nil, nil, pred)
  assert(result == false, "Failure: NONE of the nodes match. It should return false.")
end

local function test_empty_capture()
  local handler_all = registered_predicates['kind-eq?']
  local handler_any = registered_predicates['any-kind-eq?']

  -- Capture 1 did not capture any nodes (optional node is absent).
  local match = { [1] = {} }
  local pred = { "kind-eq?", 1, "string" }

  assert(handler_all(match, nil, nil, pred) == true, "Edge case: Empty capture (all) should return true.")
  assert(handler_any(match, nil, nil, pred) == true, "Edge case: Empty capture (any) should return true.")
end

-- ======================================================================
-- 3. TEST EXECUTION
-- ======================================================================
local function run_tests()
  -- Simulate loading the module (make sure registered_predicates is populated).
  -- require('your_predicate_file')

  test_kind_eq_all_nodes_match()
  test_kind_eq_one_node_does_not_match()
  test_any_kind_eq_at_least_one_matches()
  test_any_kind_eq_no_nodes_match()
  test_empty_capture()

  print("✅ All Tree-sitter predicate tests passed successfully.")
end

run_tests()
