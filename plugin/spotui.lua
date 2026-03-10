local M = {}

M.options = {
  poll_interval = 2000,   -- check Spotify every 2 seconds (ms)
  window = {
    width = 42,
    expanded_height = 14, -- tall: album art + track info
    compact_height = 3,   -- slim: just name, artist, time
    expand_duration = 5000, -- ms before shrinking down
  }
}

function M.apply(opts)
  M.options = vim.tbl_deep_extend('force', M.options, opts or {})
end

return M
