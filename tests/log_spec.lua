describe('log module', function()
  local log = require('nvim-treesitter.log')

  before_each(function()
    log._reset()
  end)

  it('creates loggers that record messages with context', function()
    local logger = log.new('test/ctx')
    logger:info('hello %s', 'world')
    logger:trace('trace message')
    assert.are.equal(2, #logger.messages)
    assert.are.equal('info', logger.messages[1][1])
    assert.are.equal('test/ctx', logger.messages[1][2])
    assert.are.equal('hello world', logger.messages[1][3])
  end)

  it('error returns the formatted message', function()
    local logger = log.new('test/ctx')
    local err = logger:error('failed: %s', 'reason')
    assert.are.equal('failed: reason', err)
  end)

  it('show works with and without a logger', function()
    local logger = log.new('test/ctx')
    logger:info('visible in global history')
    assert.has_no.errors(function()
      log.show()
    end)
    assert.has_no.errors(function()
      log.show(logger)
    end)
  end)

  it('global history includes per-context loggers', function()
    -- Regression: :TSLog used to show only the default logger, so install
    -- output (per-language loggers) was invisible.
    log._reset()
    log.new('install/lua'):info('Language installed')
    local echoed = {}
    local old_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks, _, _)
      echoed[#echoed + 1] = chunks[1][1]
    end
    local ok = pcall(log.show)
    vim.api.nvim_echo = old_echo
    assert.is_true(ok)
    local found = false
    for _, text in ipairs(echoed) do
      if text:find('Language installed', 1, true) then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)
