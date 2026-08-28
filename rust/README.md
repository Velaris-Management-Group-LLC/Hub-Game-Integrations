# XiveWhitelist

Gate your Rust server on Xive hub membership, and grant hub roles for playing on it.

A connecting player is allowed on if they are an active member of your hub and have linked the
Steam account they are connecting with. While they play, the plugin reports their time to Xive,
which can grant them a hub role for it.

## Install

1. Install **Oxide/uMod** (or Carbon, which runs the same plugins) on your Rust server.
2. In your hub: **Settings → Integrations → Rust**.
   - Turn on *Answer whitelist checks from your Rust server*.
   - Choose who may join: any member, or only members with a particular role.
   - Optionally set up the role grants — see [Roles for playing](#roles-for-playing).
   - **Issue key**, and copy it. It is shown once and is not recoverable — only a hash is stored,
     so nobody, including support, can read it back. Lose it and you revoke it and issue another.
3. Copy `XiveWhitelist.cs` into your server's `oxide/plugins/` directory.
4. The plugin writes `oxide/config/XiveWhitelist.json` on first load. Paste your key into
   `ApiKey` there, then reload: `oxide.reload XiveWhitelist`.

The console prints the sync interval and the fail policy on start.

## What your players need to do

Link Steam on Xive: **User Settings → Connections → Steam**. That is all — Rust *is* Steam, so
there is nothing else to prove and nothing to type.

## 🔴 Why the first connection can ask for a reconnect

**Rust has no deferral phase.** FiveM can hold a connecting player on a card while it asks a
question over HTTP; Rust cannot — `CanUserLogin` is synchronous, and there is no way to suspend a
connection while an answer comes back.

So this plugin keeps the whole roster locally and refreshes it every `SyncSeconds`. Logins are a
local lookup, exactly like uMod's own `Whitelist` plugin checking an Oxide permission. **For anyone
already on the roster — everybody, ordinarily — nothing is ever slow and nothing asks them to
reconnect.**

The one case that does is somebody who joined your hub in the last few minutes, or a hub so large
its roster is paged. They are asked about individually in the background and get in on their next
attempt.

## Roles for playing

Configured in the hub, not here. Three rules, and they behave differently on purpose:

| rule | grants | withdrawn? |
|---|---|---|
| **Has played here** | any verified session on your server | never |
| **Playtime** | crossing *N* hours on your server | never |
| **Oxide group** | holding an Oxide group here, mapped to a hub role | **yes** |

The first two are historical records — an hour served is not lost by not playing tomorrow. The
third is a *mirror*: "sync my `vip` group to the VIP role" means the role tracks the group in both
directions, so removing somebody from `vip` here removes the role there.

> ⚠️ **The hub will not let you map a role more privileged than `@everyone`.** A grant with no
> reviewer may not carry a permission your default role lacks, so a "Rust Moderator" role holding
> `mod_ban` is refused — at configuration time, and again every time a grant is attempted. This is
> deliberate: your server key lives in a config file on a machine Xive does not control, and this is
> what bounds what a leaked one can do.

## What gets sent

Per connected player: their **SteamID64**, the **whole minutes** since the previous sync, and the
**Oxide groups** they hold on this server. Nothing else — not their name, not their IP, nothing
about your server.

Xive answers with the roster of SteamID64s allowed on, and counts of what it recorded. Nothing is
returned about people who are not members.

## When Xive is unreachable

**Nothing happens, for a while.** The roster is already on the box, so a failed sync just keeps the
last one and logs a warning. Only once it is older than `StaleRosterMinutes` (default 30) does
`FailClosed` decide:

- `true` (default) — refuse players who are not on the last known roster. A whitelist that switches
  itself off when its checker is unavailable is not a whitelist.
- `false` — admit everyone, including people you have banned, until Xive is reachable again.

Either way, players who **are** on the last roster keep getting in throughout.

If the hub turns the integration off, the roster is **emptied** rather than kept — "stop checking
against my hub" must not leave a stale roster gating your server forever.

## Interoperating with other whitelist plugins

Set `MirrorToOxidePermission` to a permission name (for example `whitelist.allow`) and the plugin
will grant it to everyone on the roster and revoke it from everyone else, on every sync. Anything
that already gates on that permission — uMod's `Whitelist` among them — then sees the same answer
without knowing anything about Xive.

⚠️ It **revokes** as well as grants, which is what makes it a mirror rather than a leak. If you
grant that permission by hand to anybody, this will take it back. Leave it empty (the default) if
you do not want that.

## Bypass

`xivewhitelist.bypass` admits a player regardless — including when the key is wrong or missing.
Grant it to yourself before you do anything else:

```
oxide.grant user <your SteamID64> xivewhitelist.bypass
```

## Security

- The key travels as an `Authorization: Bearer` header, not in the body, so it stays out of request
  logs and error reports that record payloads.
- **Do not commit `oxide/config/XiveWhitelist.json` to a public repository.** If it leaks, revoke it
  in the hub — revocation is immediate and affects no other key.
- A key identifies a *hub*, not a person. It can ask whether a Steam account belongs to an active
  member and report play time for your own server; it cannot read your member list, and it returns
  nothing about non-members.
- **Xive never asks for your RCON password.** The usual Discord-to-Rust integrations hold RCON and
  push `oxide.grant` — which means handing a third party the full server console, reversibly stored.
  This works the other way round: your server calls Xive, with a key you can revoke.
