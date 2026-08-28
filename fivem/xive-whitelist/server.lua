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

--[[
  ── 🔴 HOW LONG WE WILL WAIT FOR XIVE BEFORE DECIDING WITHOUT IT ───────────────────────────

  PerformHttpRequest has NO TIMEOUT. If the request is black-holed — a firewall that drops rather
  than refuses, a DNS stall, an outbound rule that only blocks POST — the callback is never
  invoked, `deferrals.done()` is never called, and the player sits on "Deferring connection"
  forever with nothing in the console.

  That was the failure this file shipped with, and it is the worst shape a whitelist can fail in:
  it does not admit and it does not refuse, so an operator sees "it's broken" and a player sees a
  frozen screen. A whitelist may say no. It may not say nothing.

  After this many seconds the fail policy is applied exactly as it would be for a 500.
]]
local REQUEST_TIMEOUT_SECONDS = 10

local function log(fmt, ...)
  if Config and Config.Debug then
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

--[[
  ── 🔴 EVERY CONNECTION GETS EXACTLY ONE ANSWER ───────────────────────────────────────────

  `deferrals.done()` may be called once. Call it twice and FiveM errors; never call it and the
  player hangs. With a watchdog racing an HTTP callback, both are now genuinely possible — so
  every path goes through this closure, which enforces once-only and nothing else may call
  `deferrals.done` directly.
]]
local function answerer(deferrals)
  local answered = false
  return function(message)
    if answered then return end
    answered = true
    if message then
      deferrals.done(message)
    else
      deferrals.done()
    end
  end
end

--- The message for a refusal reason, falling back to something a player can report.
local function reasonText(reason)
  local messages = (Config and Config.Messages) or {}
  return messages[reason] or ('Refused by the Xive whitelist (%s).'):format(reason or 'unknown')
end

--[[
  ── CONFIGURATION, CHECKED ONCE AT START RATHER THAN ONCE PER PLAYER ───────────────────────

  🔴 `config.lua` NOT EXISTING IS THE MOST COMMON SETUP MISTAKE, and it used to present as every
  player hanging on the deferral screen with nothing in the console — because `Config` was nil, the
  handler errored on its first `Config.` access after `defer()`, and an error inside an event
  handler is silent unless you are looking for it.

  It is a startup problem, so it is reported at startup, in words that name the file.

  @return string|nil the reason this server cannot check anybody, or nil if it can.
]]
local function configProblem()
  if Config == nil then
    return 'config.lua was not loaded. Copy config.CHANGEME.lua to config.lua and fill it in.'
  end
  if type(Config.ApiKey) ~= 'string' or Config.ApiKey == '' or Config.ApiKey == 'xive_fm_REPLACE_ME' then
    return 'Config.ApiKey is not set. Issue a key in your hub: Settings -> Integrations -> FiveM.'
  end
  if type(Config.Endpoint) ~= 'string' or Config.Endpoint == '' then
    return 'Config.Endpoint is not set.'
  end
  return nil
end

AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
  local source = source
  deferrals.defer()

  local answer = answerer(deferrals)

  -- One frame before touching deferrals again, or the update is dropped. This is a FiveM
  -- requirement, not a stylistic pause.
  Wait(0)

  --[[
    ── 🔴 ANY ERROR BELOW MUST BECOME A REFUSAL, NOT A HANG ────────────────────────────────

    `deferrals.defer()` has already been called, so from here until an answer the player is on the
    deferral screen. An uncaught error in an event handler is SILENT — no console output, no
    kick — and leaves them there permanently.

    So the whole pre-request path runs inside a pcall and any failure is answered. Which answer is
    the fail policy's decision, not this file's: an operator who chose FailClosed = false said they
    would rather run open than closed when the check cannot happen, and a bug here is exactly that
    case.
  ]]
  local ok, err = pcall(function()
    local problem = configProblem()
    if problem then
      print('[xive-whitelist] ' .. problem)
      answer(reasonText('bad_key'))
      return
    end

    deferrals.update(Config.Messages.checking)

    local identifiers = GetPlayerIdentifiers(source)
    if #identifiers == 0 then
      -- No identifiers at all is not a whitelist decision, it is a broken connection.
      answer(reasonText('no_supported_identifier'))
      return
    end

    local key = cacheKeyFor(identifiers)

    --[[
      ── THE WATCHDOG ────────────────────────────────────────────────────────────────────

      Started BEFORE the request so it covers the request never being sent as well as its
      callback never arriving. `answer` is once-only, so whichever of the two gets there first
      decides and the other is a no-op.
    ]]
    SetTimeout(REQUEST_TIMEOUT_SECONDS * 1000, function()
      print(('[xive-whitelist] Xive did not answer within %ds.'):format(REQUEST_TIMEOUT_SECONDS))
      if cachedAllow(key) then
        print('[xive-whitelist] admitting a recently-verified player from cache.')
        answer(nil)
      elseif Config.FailClosed then
        answer(reasonText('unreachable'))
      else
        print('[xive-whitelist] admitting UNCHECKED (Config.FailClosed = false).')
        answer(nil)
      end
    end)

    PerformHttpRequest(Config.Endpoint, function(status, body, _)
      -- ── The API answered ────────────────────────────────────────────────────────────────
      if status == 200 and body then
        local okDecode, payload = pcall(json.decode, body)
        if okDecode and payload and payload.allowed ~= nil then
          if payload.allowed then
            rememberAllow(key)
            log('allow %s (%s)', tostring(payload.display_name), key or 'no-key')
            answer(nil)
          else
            log('deny %s: %s', key or 'no-key', tostring(payload.reason))
            answer(reasonText(payload.reason))
          end
          return
        end
        print('[xive-whitelist] Xive returned 200 with a body this resource could not read.')
      end

      -- ── 401 is a CONFIGURATION problem, not a player problem ────────────────────────────
      --
      -- The key is wrong, revoked, or belongs to an archived hub. Saying "you are not
      -- whitelisted" here would send every player to an admin who would then look for them in
      -- the member list and find them present. Say what is actually wrong, in the console too.
      if status == 401 or status == 403 then
        print('[xive-whitelist] Xive rejected this server API key. Issue a new one in ' ..
              'Settings -> Integrations -> FiveM.')
        answer(reasonText('bad_key'))
        return
      end

      -- ── Anything else is an outage ──────────────────────────────────────────────────────
      --
      -- ⚠️ PRINTED UNCONDITIONALLY, not behind Config.Debug. A failing whitelist with a silent
      -- console is the state this resource was in when it hung, and Debug defaults to false —
      -- so the one message an operator needs was the one they could not see.
      print(('[xive-whitelist] request failed with status %s.'):format(tostring(status)))

      if cachedAllow(key) then
        -- They were allowed within the cache window. A blip must not eject somebody who was
        -- playing a minute ago.
        print('[xive-whitelist] admitting a recently-verified player from cache.')
        answer(nil)
        return
      end

      if Config.FailClosed then
        print('[xive-whitelist] no cached allow; refusing (Config.FailClosed).')
        answer(reasonText('unreachable'))
      else
        print('[xive-whitelist] admitting UNCHECKED (Config.FailClosed = false).')
        answer(nil)
      end
    end, 'POST', json.encode({ identifiers = identifiers }), {
      ['Content-Type']  = 'application/json',
      -- The key travels as a header, not in the body, so it stays out of request logs and error
      -- reports that record payloads.
      ['Authorization'] = 'Bearer ' .. Config.ApiKey,
    })
  end)

  if not ok then
    -- Reached only if something above threw. The player must still get an answer.
    print('[xive-whitelist] internal error while checking a player: ' .. tostring(err))
    if Config and Config.FailClosed == false then
      answer(nil)
    else
      answer(reasonText('unreachable'))
    end
  end
end)

AddEventHandler('onResourceStart', function(resource)
  if resource ~= GetCurrentResourceName() then return end

  -- 🔴 SAID AT START, LOUDLY, because the alternative is discovering it one hanging player at a
  -- time. See configProblem().
  local problem = configProblem()
  if problem then
    print('[xive-whitelist] NOT CONFIGURED: ' .. problem)
    print('[xive-whitelist] Every player will be refused until this is fixed.')
    return
  end

  print('[xive-whitelist] started. Fail policy: ' ..
        (Config.FailClosed and 'closed (refuse when Xive is unreachable)'
                           or 'OPEN (admit unchecked when Xive is unreachable)'))
  print(('[xive-whitelist] endpoint: %s  key: %s...'):format(Config.Endpoint, Config.ApiKey:sub(1, 12)))
end)
