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
4. Add `ensure xive-whitelist` to your `server.cfg`.
5. Restart the server. The console prints the fail policy on start.

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

The connecting player's FiveM identifier list, as-is. Xive reads `steam:` and `discord:` and
ignores the rest. It never receives their name, their IP, or anything about your server.

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
| `no_supported_identifier` | no Steam identifier on the connection |
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
