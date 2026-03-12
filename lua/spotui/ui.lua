-- Controls floating window, timer, and display logic.
local M = {}
local config = require('spotui.config')

-- All runtime states
local state = {
  buf = nil, -- Buffer holding content
  win = nil, -- Floating window handle
  poll_timer = nil, -- Fires every polling interval to check Spotify
  shrink_timer = nil, -- Fires after expansion to minimize window
  current_track = nil, -- Last track received
  expanded = false,
}

-- Format milliseconds as M:SS
local function fmt_time(ms)
  local s = math.floor(ms / 1000)
  return ('%d:%02d'):format(math.floor(s / 60), s % 60)
  -- Adds leading 0 for single digit timer eg. 1:03
end

-- Checks if floating window exists, countering potential user close.
local function win_valid()
  if state.win ~= nil and not vim.api.nvim_win_is_valid(state.win) then
    state.win = nil  -- clean up stale handle so we don't keep checking it
  end
  return state.win ~= nil
end

-- Builds window
local function get_win_cfg(height)
  local w = config.options.window.width
  local pos = config.options.position
  local row, col

  -- Calculates row / col based on user corner choice.
  if pos == 'top-right' then
    row = 1
    col = vim.o.columns - w - 3
  elseif pos == 'top-left' then
    row = 1
    col = 1
  elseif pos == 'bottom-left' then
    row = vim.o.lines - height - 4  -- -4 accounts for statusline + cmdline
    col = 1
  elseif pos == 'bottom-right' then
    row = vim.o.lines - height - 4
    col = vim.o.columns - w - 3
  else
    -- fallback to top-right
    row = 1
    col = vim.o.columns - w - 3
  end

  return {
    relative = 'editor',
    row = row,
    col = col,
    width = w,
    height = height,
    style = 'minimal',
    border = 'rounded',
    focusable = false, -- To prevent cursor jumping to window
    zindex = 50, -- To render on top of other elements
  }
end

-- Writes to buffer, keeping it unmodifiable until we have to change it.
local function set_lines(lines)
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

-- Strips '(feat.)' to to save space.
local function clean_name(name)
  -- Remove (feat. ...) and (with ...) and [feat. ...] variants
  name = name:gsub('%s*%(feat%.?[^%)]*%)', '')
  name = name:gsub('%s*%[feat%.?[^%]]*%]', '')
  name = name:gsub('%s*%(with[^%)]*%)', '')
  return name:match('^%s*(.-)%s*$')  -- trim whitespace
end

-- Truncates artist names to fit
local function trim_artist(artist, max_len)
  if #artist <= max_len then return artist end
  return artist:sub(1, max_len - 3) .. '...'
end

-- Builds the 3 line view after minimizing
local function compact_lines(track)
  if not track then
    return { '  ♪  Nothing playing' }
  end
  local icon = track.is_playing and '▶' or '||'
  local name = clean_name(track.name)
  local max = config.options.window.width - 9
  local artist = trim_artist(track.artist, max)
  return {
    ('  %s  %s'):format(icon, name),
    ('     %s'):format(artist),
    ('     %s / %s'):format(fmt_time(track.progress_ms), fmt_time(track.duration_ms)),
  }
end

-- Collapses window to 3 line format.
local function shrink()
  if not win_valid() then return end
  state.expanded = false
  local lines = compact_lines(state.current_track)
  set_lines(lines)
  vim.api.nvim_win_set_config(state.win, get_win_cfg(#lines))
end

-- Expands window to show album art + full info.
local function expand(track)
  state.expanded = true
  local opts = config.options.window

  -- Fetches album art from art.lua
  local art = require('spotui.art').get_lines(track and track.art_url, opts.width)

  -- Builds content
  local lines = {}
  for _, l in ipairs(art) do
    table.insert(lines, l)
  end
  table.insert(lines, '  ' .. ('─'):rep(opts.width - 4))
  if track then
    table.insert(lines, ('  ♪  %s'):format(track.name))
    table.insert(lines, ('     %s'):format(track.artist))
    table.insert(lines, ('     %s · %s'):format(track.album, fmt_time(track.duration_ms)))
  else
    table.insert(lines, '  Nothing playing right now.')
  end

  -- Resizes window if already exists.
  if win_valid() then
    vim.api.nvim_win_set_config(state.win, get_win_cfg(opts.expanded_height))
  else
    state.win = vim.api.nvim_open_win(state.buf, false, get_win_cfg(opts.expanded_height))
    local hl = config.options.highlights
    vim.wo[state.win].winhl = ('Normal:%s,FloatBorder:%s,NormalFloat:%s'):format(hl.background, hl.border, hl.text)
  end
  set_lines(lines)

  -- Reset the shrink countdown
  if state.shrink_timer then
    state.shrink_timer:stop()
    state.shrink_timer:close()
  end
  state.shrink_timer = vim.loop.new_timer()
  state.shrink_timer:start(opts.expand_duration, 0, vim.schedule_wrap(shrink))
end

local function on_tick()
  if not win_valid() then return end

  require('spotui.api').get_now_playing(function(track)

    -- Nothing playing — always update to compact nil view
    if not track then
      state.current_track = nil
      if state.shrink_timer then
        state.shrink_timer:stop()
        state.shrink_timer:close()
        state.shrink_timer = nil
      end
      state.expanded = false
      set_lines(compact_lines(nil))
      vim.api.nvim_win_set_config(state.win, get_win_cfg(1))
      return
    end

    -- Same song — just update timestamp
    if state.current_track and state.current_track.name == track.name then
      local old_secs = math.floor(state.current_track.progress_ms / 1000)
      local new_secs = math.floor(track.progress_ms / 1000)
      state.current_track.progress_ms = track.progress_ms
      state.current_track.is_playing  = track.is_playing
      if not state.expanded and win_valid() and old_secs ~= new_secs then
        set_lines(compact_lines(state.current_track))
      end
      return
    end

    -- New song
    state.current_track = track
    if win_valid() then expand(track) end
  end)
end
-- Creates buffer once when plugin started.
function M.init()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype    = 'nofile'
  vim.bo[state.buf].modifiable = false
end

function M.toggle()
  if win_valid() then
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
    state.current_track = nil
    state.expanded = false
    if state.poll_timer then
      state.poll_timer:stop()
      state.poll_timer:close()
      state.poll_timer = nil
    end
    if state.shrink_timer then
      state.shrink_timer:stop()
      state.shrink_timer:close()
      state.shrink_timer = nil
    end
  else
    state.win = vim.api.nvim_open_win(
      state.buf, false,
      get_win_cfg(config.options.window.compact_height)
    )
    local hl = config.options.highlights
    vim.wo[state.win].winhl = ('Normal:%s,FloatBorder:%s,NormalFloat:%s'):format(hl.background, hl.border, hl.text)
    set_lines({ '  ♪  Loading...' })

    state.poll_timer = vim.loop.new_timer()
    state.poll_timer:start(
      0,
      config.options.poll_interval,
      vim.schedule_wrap(on_tick)
    )
  end
end

return M
