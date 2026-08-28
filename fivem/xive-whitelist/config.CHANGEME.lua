--[[
  Rename this file to `config.lua` and fill it in.

  Both values come from your hub: Settings -> Integrations -> FiveM.
]]

Config = {}

-- The API key issued by your hub. Shown ONCE when you create it; if you lose it, revoke it
-- and issue another. Treat it like a password: anyone holding it can ask Xive whether a given
-- player is on your whitelist.
--
-- 🔴 DO NOT COMMIT THIS FILE TO A PUBLIC REPOSITORY. This is the single most common way a
-- server's API key leaks. If it happens, revoke the key in Settings -> Integrations -> FiveM;
-- revocation takes effect immediately and no other key is affected.
Config.ApiKey = 'xive_fm_REPLACE_ME'

-- Xive's API. Change only if you were told to.
Config.Endpoint = 'https://api.thexive.com/api/hub/fivem/verify'

-- What a player sees when they are refused. `%s` is replaced with the reason.
Config.Messages = {
  checking      = 'Checking your Xive whitelist...',
  not_member    = 'You are not a member of this hub on Xive, or you have not linked the account you are connecting with. Join the hub and link your Steam account, then try again.',
  missing_role  = 'You are a member, but you do not have the role this server requires.',
  member_banned = 'You are banned from this hub on Xive.',
  member_muted  = 'Your membership of this hub is restricted.',
  member_left   = 'You are no longer a member of this hub on Xive.',
  member_pending = 'Your membership of this hub has not been approved yet.',
  no_supported_identifier = 'Xive could not read a Steam account from your connection. Make sure you are running Steam.',
  integration_disabled = 'This server is not accepting Xive whitelist checks right now.',
  unreachable   = 'Could not reach Xive to check the whitelist. Please try again in a moment.',
  bad_key       = 'This server is misconfigured (its Xive API key is not valid). Contact an admin.',
}

-- ── FAILURE POLICY ──────────────────────────────────────────────────────────────────────────
--
-- What happens when Xive cannot be reached at all.
--
--   true  (default) REFUSE the connection. A whitelist is a security control, and a control that
--                   switches itself off when its checker is unavailable is not one. The cost is
--                   that an outage at Xive means nobody new can join your server.
--
--   false           ALLOW the connection. Choose this only if you would rather run an open server
--                   for the duration of an outage than a closed one. Anyone can join while Xive
--                   is unreachable, including people you have banned.
--
-- Whichever you choose, players who connected recently are let through from the cache below, so a
-- brief blip does not lock out people who were just playing.
Config.FailClosed = true

-- How long an allow is remembered, in seconds. Only ALLOWS are cached, never refusals: a player
-- who was just granted a role should get in immediately, and one who was just banned must not be
-- let in from a stale entry.
Config.CacheSeconds = 300

-- Log every decision to the server console. Useful while setting up; noisy on a busy server.
Config.Debug = false
