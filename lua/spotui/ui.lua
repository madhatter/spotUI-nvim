local M = {}
local config = require('spotui.config')

local state = {
  buf = nil,
  win = nil,
  poll_timer = nil,
  shrink_timer = nil,
  current_track = nil,
  expanded = false,
}

-- Format milliseconds as M:SS
local function fmt_time(ms)
  local s = math.floor(ms / 1000)
  return ('%d:%02d'):format(math.floor(s / 60), s % 60)
end

local function win_valid()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function get_win_cfg(height)
  local w = config.options.window.width
  local pos = config.options.position
  local row, col

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
    focusable = false,
    zindex = 50,
  }
end

local function set_lines(lines)
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

local function clean_name(name)
  -- Remove (feat. ...) and (with ...) and [feat. ...] variants
  name = name:gsub('%s*%(feat%.?[^%)]*%)', '')
  name = name:gsub('%s*%[feat%.?[^%]]*%]', '')
  name = name:gsub('%s*%(with[^%)]*%)', '')
  return name:match('^%s*(.-)%s*$')  -- trim whitespace
end

local function trim_artist(artist, max_len)
  if #artist <= max_len then return artist end
  -- Cut at the last comma before max_len and add ...
  local trimmed = artist:sub(1, max_len)
  local last_comma = trimmed:match('.*(),')
  if last_comma then
    return artist:sub(1, last_comma - 1) .. ', ...'
  end
  return trimmed .. '...'
end

local function compact_lines(track)
  if not track then
    return { '  ♪  Nothing playing' }
  end
  local icon = track.is_playing and '▶' or '⏸'
  local name = clean_name(track.name)
  local artist = trim_artist(track.artist, 28)
  return {
    ('  %s  %s'):format(icon, name),
    ('     %s'):format(artist),
    ('     %s / %s'):format(fmt_time(track.progress_ms), fmt_time(track.duration_ms)),
  }
end
local function shrink()
  if not win_valid() then return end
  state.expanded = false
  local lines = compact_lines(state.current_track)
  set_lines(lines)
  vim.api.nvim_win_set_config(state.win, get_win_cfg(#lines))
end

local function expand(track)
  state.expanded = true
  local opts = config.options.window
  local art = require('spotui.art').get_lines(track and track.art_url, opts.width)

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

  if win_valid() then
    vim.api.nvim_win_set_config(state.win, get_win_cfg(opts.expanded_height))
  else
    state.win = vim.api.nvim_open_win(state.buf, false, get_win_cfg(opts.expanded_height))
    vim.wo[state.win].winhl = 'Normal:NormalFloat,FloatBorder:FloatBorder'
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
    -- Same song — just update timestamp
    if state.current_track and track
      and state.current_track.name == track.name then
      local old_secs = math.floor(state.current_track.progress_ms / 1000)
      local new_secs = math.floor(track.progress_ms / 1000)
      state.current_track.progress_ms = track.progress_ms
      state.current_track.is_playing  = track.is_playing
      if not state.expanded and win_valid() and old_secs ~= new_secs then
        set_lines(compact_lines(state.current_track))
      end
      return
    end
    -- New song or first load
    state.current_track = track
    if win_valid() then expand(track) end
  end)
end

function M.init()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype    = 'nofile'
  vim.bo[state.buf].modifiable = false
end

function M.toggle()
  if win_valid() then
    vim.api.nvim_win_close(state.win, true)
    state.win = nil
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
    vim.wo[state.win].winhl = 'Normal:NormalFloat,FloatBorder:FloatBorder'
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
