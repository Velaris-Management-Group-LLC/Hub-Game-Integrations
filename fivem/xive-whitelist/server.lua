--[[
  xive-whitelist — check connecting players against Xive hub membership.

  ── HOW IT WORKS ────────────────────────────────────────────────────────────────────────────

  On `playerConnecting`, before any resource loads, this asks Xive one question: is the person
  behind these identifiers a member of the hub this key belongs to? Xive answers allow or deny
  with a reason, and the player either joins or sees that reason on the deferral card.

  The check happens during the deferral phase deliberately — a refused player never loads the
  server's resources, which is both faster for them and cheaper for you than kicking afterwards.

  ── WHAT IT SENDS ───────────────────────────────────────────────────────────────────────────

  The connecting player's identifier list, verbatim. Xive reads `steam:`, `license:` and
  `discord:` and ignores the rest; it never receives their name, IP, or anything about your server.
  It answers with a display name and role names — the same things any member list on Xive already
  shows, and nothing at all about people who are not members.

  ── 🔴 SEND EVERY IDENTIFIER, EXACTLY AS FIVEM GIVES THEM ───────────────────────────────────

  Two of them matter, and both are handled on Xive's side:

    steam:    HEXADECIMAL here, decimal in Xive (`steam:110000112345678` is a SteamID64 in hex).
              Do not "helpfully" convert it — that breaks the match silently, for every player.

    license:  The Rockstar identifier. On a connection Steam has already authorised, Xive RECORDS
              this license as belonging to that player, so their next join works with Steam closed.
              Nothing is typed and nothing is trusted: the binding is made during a session Steam
              vouched for.

  Sending fewer identifiers than FiveM offers is what breaks the second one. Send the list whole.

  ── FAILURE POLICY ──────────────────────────────────────────────────────────────────────────

  See Config.FailClosed. Recently-allowed players are served from a short cache so a brief outage
  does not lock out people who were just playing. Only allows are cached — a ban must take effect
  immediately, so refusals are always asked afresh.
]]

local cache = {}   -- identifier -> { expires = os.time() + n }

local function log(fmt, ...)
  if Config.Debug then
    print(('[xive-whitelist] ' .. fmt):format(...))
  end
end

--- The first identifier we would recognise, used as the cache key.
--- Steam first because it is the one Xive can actually match today.
local function cacheKeyFor(identifiers)
  for _, id in ipairs(identifiers) do
    if id:sub(1, 6) == 'steam:' then return id end
  end
  for _, id in ipairs(identifiers) do
    if id:sub(1, 8) == 'discord:' then return id end
  end
  return nil
end

local function cachedAllow(key)
  if not key then return false end
  local hit = cache[key]
  if hit and hit.expires > os.time() then return true end
  cache[key] = nil
  return false
end

local function rememberAllow(key)
  if key and Config.CacheSeconds > 0 then
    cache[key] = { expires = os.time() + Config.CacheSeconds }
  end
end

--- Refuse, with the clearest sentence we have for this reason.
local function refuse(deferrals, reason)
  deferrals.done(Config.Messages[reason] or ('Refused by the Xive whitelist (%s).'):format(reason or 'unknown'))
end

AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
  local source = source
  deferrals.defer()

  -- One frame before touching deferrals again, or the update is dropped. This is a FiveM
  -- requirement, not a stylistic pause.
  Wait(0)
  deferrals.update(Config.Messages.checking)

  local identifiers = GetPlayerIdentifiers(source)
  if #identifiers == 0 then
    -- No identifiers at all is not a whitelist decision, it is a broken connection.
    refuse(deferrals, 'no_supported_identifier')
    return
  end

  local key = cacheKeyFor(identifiers)

  if Config.ApiKey == nil or Config.ApiKey == '' or Config.ApiKey == 'xive_fm_REPLACE_ME' then
    print('[xive-whitelist] Config.ApiKey is not set. Every player will be refused.')
    refuse(deferrals, 'bad_key')
    return
  end

  PerformHttpRequest(Config.Endpoint, function(status, body, _)
    -- ── The API answered ──────────────────────────────────────────────────────────────────
    if status == 200 and body then
      local okDecode, payload = pcall(json.decode, body)
      if okDecode and payload and payload.allowed ~= nil then
        if payload.allowed then
          rememberAllow(key)
          log('allow %s (%s)', tostring(payload.display_name), key or 'no-key')
          deferrals.done()
        else
          log('deny %s: %s', key or 'no-key', tostring(payload.reason))
          refuse(deferrals, payload.reason)
        end
        return
      end
      log('unreadable response body')
    end

    -- ── 401 is a CONFIGURATION problem, not a player problem ──────────────────────────────
    --
    -- The key is wrong, revoked, or belongs to an archived hub. Saying "you are not whitelisted"
    -- here would send every player to an admin who would then look for them in the member list
    -- and find them present. Say what is actually wrong, and say it in the console too.
    if status == 401 or status == 403 then
      print('[xive-whitelist] Xive rejected this server API key. Issue a new one in ' ..
            'Settings -> Integrations -> FiveM.')
      refuse(deferrals, 'bad_key')
      return
    end

    -- ── Anything else is an outage ────────────────────────────────────────────────────────
    log('request failed with status %s', tostring(status))

    if cachedAllow(key) then
      -- They were allowed within the cache window. A blip must not eject somebody who was
      -- playing a minute ago.
      print('[xive-whitelist] Xive unreachable; admitting a recently-verified player from cache.')
      deferrals.done()
      return
    end

    if Config.FailClosed then
      print('[xive-whitelist] Xive unreachable and no cached allow; refusing (Config.FailClosed).')
      refuse(deferrals, 'unreachable')
    else
      print('[xive-whitelist] Xive unreachable; admitting UNCHECKED (Config.FailClosed = false).')
      deferrals.done()
    end
  end, 'POST', json.encode({ identifiers = identifiers }), {
    ['Content-Type']  = 'application/json',
    -- The key travels as a header, not in the body, so it stays out of request logs and error
    -- reports that record payloads.
    ['Authorization'] = 'Bearer ' .. Config.ApiKey,
  })
end)

AddEventHandler('onResourceStart', function(resource)
  if resource ~= GetCurrentResourceName() then return end
  print('[xive-whitelist] started. Fail policy: ' ..
        (Config.FailClosed and 'closed (refuse when Xive is unreachable)'
                           or 'OPEN (admit unchecked when Xive is unreachable)'))
end)
