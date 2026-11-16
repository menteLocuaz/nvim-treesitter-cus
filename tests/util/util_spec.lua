-- ======================================================================
-- 1. SETUP Y MOCKS
-- ======================================================================
local M = require('nvim-treesitter.util') 

-- We are keeping the original to restore it later.
local original_io_open = io.open

-- Variables for spying on behavior (Spies)
local mock_state = {
  is_closed = false,
  read_result = nil,
  read_error = nil,
  write_success = true,
  write_error = nil,
  should_open = true,
  open_error = "File not found",
  written_content = ""
}

-- We create a mock of a Lua "file" object.
local file_mock = {
  read = function(self, mode)
    if mock_state.read_result then return mock_state.read_result end
    return nil, mock_state.read_error
  end,
  write = function(self, content)
    if mock_state.write_success then
      mock_state.written_content = content
      return true
    end
    return nil, mock_state.write_error
  end,
  close = function(self)
    mock_state.is_closed = true
  end
}

-- We replace the global I/O function.
local function setup_mock(state_overrides)
  -- Reset state
  mock_state.is_closed = false
  mock_state.read_result = "contenido de prueba"
  mock_state.read_error = nil
  mock_state.write_success = true
  mock_state.write_error = nil
  mock_state.should_open = true
  mock_state.open_error = "File not found"
  mock_state.written_content = ""

  -- Apply overrides
  if state_overrides then
    for k, v in pairs(state_overrides) do mock_state[k] = v end
  end

  io.open = function(path, mode)
    if mock_state.should_open then
      return file_mock
    end
    return nil, mock_state.open_error
  end
end

local function teardown_mock()
  io.open = original_io_open
end

--Utility function for error catching and testing pcalls
local function assert_throws(fn, expected_match, msg)
  local ok, err = pcall(fn)
  assert(not ok, msg .. " (It should have thrown an error)")
  assert(string.match(tostring(err), expected_match), msg .. " (The error message does not match)")
end

-- ======================================================================
-- 2. TEST SUITE
-- ======================================================================

local function test_read_file_camino_feliz()
  setup_mock({ read_result = "hello world" })
  
  local content = M.read_file("test.txt")
  
  assert(content == "hello world", "It must return the file content")
  assert(mock_state.is_closed == true, "The file MUST be closed after reading")
end

local function test_read_file_no_existe()
  setup_mock({ should_open = false, open_error = "No such file or directory" })
  
  assert_throws(
    function() M.read_file("fantasma.txt") end,
    "No such file",
    "Fallo: It should throw an error if the file does not exist."
  )
  assert(mock_state.is_closed == false, "No attempt was made to close a file that was not opened.")
end

local function test_write_file_camino_feliz()
  setup_mock()
  
  M.write_file("test.txt", "new text")
  
  assert(mock_state.written_content == "new text", "You must write the exact text.")
  assert(mock_state.is_closed == true, "The file MUST be closed after writing.")
end

local function test_write_file_falla_escritura()
  -- Simulamos un caso donde el disco está lleno
  setup_mock({ write_success = false, write_error = "No space left on device" })
  
  assert_throws(
    function() M.write_file("test.txt", "text") end,
    "No space left",
    "Failure: Must throw an error if the write operation fails."
  )
  assert(mock_state.is_closed == true, "PROPERTY: The file must be closed EVEN if the write operation fails, so as not to leave orphaned descriptors.")
end

-- ======================================================================
-- 3. EJECUCIÓN
-- ======================================================================
local function run_tests()
  print("Running I/O tests...")
  test_read_file_camino_feliz()
  test_read_file_no_existe()
  test_write_file_camino_feliz()
  test_write_file_falla_escritura()
  teardown_mock()
  print("✅ All tests have passed successfully..")
end

run_tests()