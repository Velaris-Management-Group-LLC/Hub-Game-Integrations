# xive-whitelist

Whitelist your FiveM server against your Xive hub. A connecting player is allowed on if they are
an active member of your hub and have linked the Steam account they are connecting with.

## Install

1. In your hub: **Settings → Integrations → FiveM**.
   - Turn on *Answer whitelist checks from your FiveM server*.
   - Choose who may join: any member, or only members with a particular role.
   - **Issue key**, and copy it. It is shown once and is not recoverable — only a hash is stored,
     so nobody, including support, can read it back. Lose it and you revoke it and issue another.
2. Copy this `xive-whitelist` folder into your server's `resources` directory.
3. Rename `config.CHANGEME.lua` to `config.lua` and paste your key into `Config.ApiKey`.
   The resource does **not** read `config.CHANGEME.lua` — that name is deliberate, so an upgrade
   never overwrites your key.
4. Add `ensure xive-whitelist` to your `server.cfg`.
5. Restart the server and **read the console**. One of two lines tells you where you stand:

   ```
   [xive-whitelist] started. Fail policy: closed (refuse when Xive is unreachable)
   [xive-whitelist] endpoint: https://api.thexive.com/...  key: xive_fm_2498...
   ```

   ```
   [xive-whitelist] NOT CONFIGURED: config.lua was not loaded. Copy config.CHANGEME.lua to config.lua and fill it in.
   [xive-whitelist] Every player will be refused until this is fixed.
   ```

6. Connect a player, then check the key in **Settings → Integrations → FiveM**. Once a check has
   actually reached Xive, the key shows a **last used** time. If it still says *never used*, no
   request is leaving your server — see Troubleshooting.

## Troubleshooting

**Players stuck on "Deferring connection", and the key shows *never used*.**
The request is not leaving your server — Xive has never seen it. The console now says which of the
two causes it is:

| Console line | Cause | Fix |
|---|---|---|
| `NOT CONFIGURED: config.lua was not loaded` | `config.CHANGEME.lua` was never renamed | Do step 3, restart the resource |
| `Xive did not answer within 10s` | outbound HTTPS from the game server is being dropped | Allow outbound 443 to `api.thexive.com` |
| `request failed with status 0` | DNS or TLS failure on the game server | Check the box can resolve and reach `api.thexive.com` |
| `Xive rejected this server API key` | the key is wrong, revoked, or from another hub | Issue a new key and paste it into `config.lua` |

Nothing hangs any more: after 10 seconds the resource applies `Config.FailClosed` and the player
gets an answer either way. A whitelist may say no — it may not say nothing.

**Players refused with "you are not a member".**
They are either not in the hub, or the account they are connecting with is not linked. See below.

## What your players need to do

**If they play with Steam running** — link Steam on Xive: **User Settings → Connections → Steam**.
That is all. The first time they join your server, Xive quietly records the FiveM license it sees
on that same connection, so from then on they can join with Steam closed. Nobody types anything.

**If they never use Steam** — they have no identifier Xive can prove, so they can type their FiveM
license into **User Settings → Connections → FiveM**. This is off for your server by default. To
accept it, turn on *Accept licenses members typed in themselves* in the hub's FiveM settings, and
understand what it allows:

- **Ban evasion.** A banned player can ask a friend to claim the banned player's license. The
  friend is a member in good standing, so the license resolves to an active membership.
- **Squatting.** One license belongs to one Xive account, so claiming someone else's locks the
  real owner out of ever claiming it.

Neither applies to licenses confirmed automatically, which is why that path is the default and this
one is opt-in.

## What gets sent

Two identifiers and no others: `steam:` and `license:`. The resource filters the rest out before
the request is built — Discord id, IP address, Xbox and Rockstar handles never leave your machine.
Xive never receives the player's name or anything about your server.

Xive answers with whether they are allowed, a reason if not, and — if allowed — their Xive display
name and role names. Nothing about non-members is returned.

## When Xive is unreachable

`Config.FailClosed = true` (the default) refuses new connections. A whitelist is a security
control, and one that switches itself off when its checker is unavailable is not a control. Set it
to `false` only if you would rather run an open server during an outage than a closed one.

Either way, players allowed within the last `Config.CacheSeconds` are let through from cache, so a
brief blip does not eject people who were just playing. **Only allows are cached** — a ban takes
effect on the next connection attempt, never served from a stale entry.

## Refusal reasons

| reason | means |
|---|---|
| `not_member` | not in the hub, or hasn't linked the account they're connecting with |
| `missing_role` | a member, but without the role this server requires |
| `member_banned` | banned from the hub |
| `member_muted` / `member_pending` / `member_left` | membership isn't active |
| `no_supported_identifier` | neither a Steam account nor a license on the connection |
| `integration_disabled` | the hub turned whitelist checks off |
| `bad_key` | **your** key is wrong or revoked — a config problem, not the player's |

`bad_key` is deliberately distinct: telling a player "you are not whitelisted" when the server's
key is broken sends them to an admin who then finds them present in the member list.

## Security

- The key travels as an `Authorization: Bearer` header, not in the body, so it stays out of request
  logs and error reports that record payloads.
- **Do not commit `config.lua` to a public repository.** That is the most common way a server key
  leaks. If it happens, revoke it in the hub — revocation is immediate and affects no other key.
- A key identifies a *hub*, not a person. It can only ask whether a given identifier belongs to an
  active member; it cannot read your member list, and it returns nothing about non-members.
