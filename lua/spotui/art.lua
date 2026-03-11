-- Downloads album art and renders as unicode using chafa.
local M = {}
-- Caches rendered art lines, persists for whole session until M.clear_cache().
local cache = {}

-- Fetches and renders album art.
function M.get_lines(url, width)
  if not url then return {} end
  if cache[url] then return cache[url] end

  -- Fallback if chafa not installed.
  if vim.fn.executable('chafa') == 0 then
    return { '  [install chafa for album art]' }
  end

  -- Temporary file path for downloaded image.
  local tmp = (vim.fn.tempname() .. '.jpg'):gsub('\\', '/')
  -- Blocking download call as it only happens once per unique album.
  vim.fn.system(('curl -s -o "%s" "%s"'):format(tmp, url))

  local devnull = vim.fn.has('win32') == 1 and '2>nul' or '2>/dev/null'

  local lines = vim.fn.systemlist(
    ('chafa --size %dx12 --symbols braille --colors none --format symbols "%s" %s')
    :format(width - 4, tmp, devnull)
  )

  -- Strips returns from line endings.
  for i, line in ipairs(lines) do
    line = line:gsub('\r$', '')
    lines[i] = '  ' .. line
  end

  -- Cleans temp file after chafa reads.
  vim.fn.delete(tmp)
  -- Caches result
  cache[url] = #lines > 0 and lines or { '  [art unavailable]' }
  return cache[url]
end

-- Useful for resizing window.
function M.clear_cache()
  cache = {}
end

return M
