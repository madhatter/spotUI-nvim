-- Handles communication with Spotify Web API
local M = {}
local _tokens = nil

-- Safe JSON decode helper — wraps pcall so unexpected curl output
-- (empty string, partial data, network errors) never crashes the plugin
local function safe_decode(raw)
  if not raw or vim.trim(raw) == '' then return nil end
  local ok, result = pcall(vim.fn.json_decode, raw)
  if not ok then return nil end
  return result
end

-- Reads tokens from JSON file saved via scripts/get_token.py
-- Uses cached tokens in _tokens if already loaded.
local function load_tokens()
  if _tokens then return _tokens end

  local path = vim.fn.expand('~/.spotify_nvim_tokens.json')
  local f = io.open(path, 'r')
  if not f then -- Notifies user if tokens file doesn't exist.
    vim.notify('SpotUI: run scripts/get_token.py first!', vim.log.levels.ERROR)
    return nil
  end
  _tokens = safe_decode(f:read('*all'))
  f:close()
  return _tokens
end

-- Clears cache after 401 error.
function M.invalidate_cache()
  _tokens = nil
end

-- Writes tokens to disk and updates cache.
local function save_tokens(tokens)
  _tokens = tokens
  local path = vim.fn.expand('~/.spotify_nvim_tokens.json')
  local f = io.open(path, 'w')
  -- Converts Lua table back to JSON string.
  if f then f:write(vim.fn.json_encode(tokens)); f:close() end
end

-- Sends a control command to Spotify (no response body expected)
-- Async HTTP helper for control commands
local function async_curl_action(method, endpoint, cb)
  local tokens = load_tokens()
  if not tokens then
    vim.notify('SpotUI: no tokens', vim.log.levels.ERROR)
    return
  end

  local chunks = {}
  local stdout = vim.loop.new_pipe(false)
  local handle

  handle = vim.loop.spawn('curl', {
    args = {
      '-s', -- silent mode
      '-X', method, -- HTTP method
      'https://api.spotify.com/v1/me/player/' .. endpoint,
      '-H', 'Authorization: Bearer ' .. tokens.access_token,
      '-H', 'Content-Length: 0',
    },
    stdio = { nil, stdout, nil },
  }, function()
    handle:close()
    stdout:close()

    -- Defers execution to nvim's main thread
    vim.schedule(function()
      local response = table.concat(chunks)
      -- Only show error if Spotify returned an actual error object
      if response and response:find('"error"') then
        vim.notify('SpotUI control error: ' .. response, vim.log.levels.WARN)
      end
      if cb then cb() end
    end)
  end)

  stdout:read_start(function(_, data)
    if data then table.insert(chunks, data) end
  end)
end

function M.play()
  async_curl_action('PUT', 'play', nil)
end

function M.pause()
  async_curl_action('PUT', 'pause', nil)
end

function M.next_track()
  async_curl_action('POST', 'next', nil)
end

function M.prev_track()
  async_curl_action('POST', 'previous', nil)
end

function M.toggle_play(cb)
  -- We need to know current state to decide play vs pause
  M.get_now_playing(function(track)
    if track and track.is_playing then
      async_curl_action('PUT', 'pause', cb)
    else
      async_curl_action('PUT', 'play', cb)
    end
  end)
end

-- Runs curl asynchronously, calls cb(string) with full output when done.
-- For HTTP requests where we read response body.
local function async_curl(args, cb)
  local chunks = {} -- Collects response body that arrives in pieces
  local stdout = vim.loop.new_pipe(false)

  local handle
  handle = vim.loop.spawn('curl', {
    args = args,
    stdio = { nil, stdout, nil },
  }, function()
    -- Called when the process exits
    handle:close()
    stdout:close()
    vim.schedule(function()
      -- Joins chunks into complete response string.
      cb(table.concat(chunks))
    end)
  end)

  stdout:read_start(function(_, data)
    if data then
      table.insert(chunks, data)
    end
  end)
end

-- Spotify access tokens last 1 hour, silently refreshes using refresh token.
local function do_refresh(tokens, cb)
  async_curl({
    '-s', '-X', 'POST',
    'https://accounts.spotify.com/api/token',
    '--user', tokens.client_id .. ':' .. tokens.client_secret,
    '-d', 'grant_type=refresh_token&refresh_token=' .. tokens.refresh_token,
  }, function(raw)
    local new = safe_decode(raw)
    if new and new.access_token then
      tokens.access_token = new.access_token
      _tokens = tokens -- directly updates the module-level cache
      save_tokens(tokens)
      cb(tokens)
    else
      cb(nil)
    end
  end)
end

-- Public: get now playing, result delivered via callback
-- cb receives a track table or nil
function M.get_now_playing(cb)
  local tokens = load_tokens()
  if not tokens then cb(nil); return end

  async_curl({
    '-s',
    'https://api.spotify.com/v1/me/player/currently-playing',
    '-H', 'Authorization: Bearer ' .. tokens.access_token,
  }, function(raw)
    local data = safe_decode(raw)
    if not data then cb(nil); return end

    -- Token expired — refresh and retry once
    if data.error and data.error.status == 401 then
      M.invalidate_cache()
      do_refresh(tokens, function(new_tokens)
        if not new_tokens then cb(nil); return end
        async_curl({
          '-s',
          'https://api.spotify.com/v1/me/player/currently-playing',
          '-H', 'Authorization: Bearer ' .. new_tokens.access_token,
        }, function(raw2)
          local data2 = safe_decode(raw2)
          if not data2 or not data2.item then cb(nil); return end
          cb(M._parse(data2))
        end)
      end)
      return
    end

    if not data.item then cb(nil); return end
    cb(M._parse(data))
  end)
end

-- Parses raw Spotify response into a clean track table
function M._parse(data)
  local artists = {}
  for _, a in ipairs(data.item.artists) do
    table.insert(artists, a.name)
  end
  return {
    name = data.item.name,
    artist = table.concat(artists, ', '),
    album = data.item.album.name,
    art_url = data.item.album.images[1] and data.item.album.images[1].url,
    progress_ms = data.progress_ms or 0,
    duration_ms = data.item.duration_ms or 0,
    is_playing = data.is_playing,
  }
end

return M
