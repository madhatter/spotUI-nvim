local M = {}

local function load_tokens()
  local path = vim.fn.expand('~/.spotify_nvim_tokens.json')
  local f = io.open(path, 'r')
  if not f then
    vim.notify('SpotUI: token file not found. Run scripts/get_token.py first!', vim.log.levels.ERROR)
    return nil
  end
  local data = vim.fn.json_decode(f:read('*all'))
  f:close()
  return data
end

local function save_tokens(tokens)
  local path = vim.fn.expand('~/.spotify_nvim_tokens.json')
  local f = io.open(path, 'w')
  if f then
    f:write(vim.fn.json_encode(tokens))
    f:close()
  end
end

local function refresh(tokens)
  local result = vim.fn.system(
    ('curl -s -X POST https://accounts.spotify.com/api/token ' ..
     '--user "%s:%s" ' ..
     '-d "grant_type=refresh_token&refresh_token=%s"')
    :format(tokens.client_id, tokens.client_secret, tokens.refresh_token)
  )
  local new = vim.fn.json_decode(result)
  if new and new.access_token then
    tokens.access_token = new.access_token
    save_tokens(tokens)
    return tokens
  end
  return nil
end

local function fetch(tokens)
  return vim.fn.system(
    ('curl -s https://api.spotify.com/v1/me/player/currently-playing ' ..
     '-H "Authorization: Bearer %s"')
    :format(tokens.access_token)
  )
end

function M.get_now_playing()
  local tokens = load_tokens()
  if not tokens then return nil end

  local raw = fetch(tokens)
  if not raw or raw == '' then return nil end

  local data = vim.fn.json_decode(raw)
  if not data then return nil end

  -- Token expired, refresh and retry once
  if data.error and data.error.status == 401 then
    tokens = refresh(tokens)
    if not tokens then return nil end
    raw = fetch(tokens)
    data = vim.fn.json_decode(raw)
    if not data then return nil end
  end

  if not data.item then return nil end

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
