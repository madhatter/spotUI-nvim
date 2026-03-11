local M = {}
local _tokens = nil

local function load_tokens()
  if _tokens then return _tokens end
  local path = vim.fn.expand('~/.spotify_nvim_tokens.json')
  local f = io.open(path, 'r')
  if not f then
    vim.notify('SpotUI: run scripts/get_token.py first!', vim.log.levels.ERROR)
    return nil
  end
  _tokens = vim.fn.json_decode(f:read('*all'))
  f:close()
  return _tokens
end

local function save_tokens(tokens)
  _tokens = tokens
  local path = vim.fn.expand('~/.spotify_nvim_tokens.json')
  local f = io.open(path, 'w')
  if f then f:write(vim.fn.json_encode(tokens)); f:close() end
end

-- Runs curl asynchronously, calls cb(string) with full output when done
local function async_curl(args, cb)
  local chunks = {}
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
      cb(table.concat(chunks))
    end)
  end)

  stdout:read_start(function(err, data)
    if data then
      table.insert(chunks, data)
    end
  end)
end

local function do_refresh(tokens, cb)
  async_curl({
    '-s', '-X', 'POST',
    'https://accounts.spotify.com/api/token',
    '--user', tokens.client_id .. ':' .. tokens.client_secret,
    '-d', 'grant_type=refresh_token&refresh_token=' .. tokens.refresh_token,
  }, function(raw)
    local new = vim.fn.json_decode(raw)
    if new and new.access_token then
      tokens.access_token = new.access_token
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
    if not raw or raw == '' then cb(nil); return end

    local data = vim.fn.json_decode(raw)
    if not data then cb(nil); return end

    -- Token expired — refresh and retry once
    if data.error and data.error.status == 401 then
      do_refresh(tokens, function(new_tokens)
        if not new_tokens then cb(nil); return end
        async_curl({
          '-s',
          'https://api.spotify.com/v1/me/player/currently-playing',
          '-H', 'Authorization: Bearer ' .. new_tokens.access_token,
        }, function(raw2)
          local data2 = vim.fn.json_decode(raw2)
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
    name        = data.item.name,
    artist      = table.concat(artists, ', '),
    album       = data.item.album.name,
    art_url     = data.item.album.images[1] and data.item.album.images[1].url,
    progress_ms = data.progress_ms or 0,
    duration_ms = data.item.duration_ms or 0,
    is_playing  = data.is_playing,
  }
end

return M
