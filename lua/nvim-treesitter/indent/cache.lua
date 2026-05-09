local LineCache = {}

function LineCache.new(bufnr)
  local self = setmetatable({}, { __index = LineCache })
  self.bufnr = bufnr
  self.cache = {}
  return self
end

function LineCache:get(lnum)
  if not self.cache[lnum] then
    self.cache[lnum] = vim.api.nvim_buf_get_lines(self.bufnr, lnum - 1, lnum, false)[1] or ''
  end
  return self.cache[lnum]
end

function LineCache:getline(lnum)
  return self:get(lnum)
end

function LineCache:get_indent(lnum)
  local _, indentcols = self:get(lnum):find('^%s*')
  return indentcols or 0
end

local function memoize(fn)
  local cache = {}

  return function(...)
    local key = string.format('%s:%s:%s', ...)
    if cache[key] == nil then
      local v = fn(...)
      cache[key] = v ~= nil and v or vim.NIL
    end

    local v = cache[key]
    return v ~= vim.NIL and v or nil
  end
end

return {
  LineCache = LineCache,
  memoize = memoize,
}
