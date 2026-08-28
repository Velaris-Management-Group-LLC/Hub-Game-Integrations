using System;
using System.Collections.Generic;
using Newtonsoft.Json;
using Oxide.Core.Libraries;
using Oxide.Core.Libraries.Covalence;
using Oxide.Core.Plugins;

/*
 * XiveWhitelist — gate a Rust server on Xive hub membership, and report play time back.
 *
 * ── 🔴 WHY THIS HOLDS A ROSTER INSTEAD OF ASKING ABOUT EACH PLAYER ──────────────────────────
 *
 * CanUserLogin is SYNCHRONOUS and webrequest.Enqueue is NOT. There is no deferral phase in Rust —
 * nothing equivalent to FiveM's `deferrals.defer()`, which holds a connecting player on a card
 * while a resource makes an HTTP call. A plugin that tried to ask Xive at login would have to
 * return an answer before its own request came back, so it would either block the server thread or
 * answer with whatever it had, which is nothing.
 *
 * So the answer is already here before anybody knocks: a timer fetches the whole roster on an
 * interval and login is a HashSet lookup. That is exactly how uMod's own Whitelist plugin works —
 * it checks a local Oxide permission — and the only difference is where the local state comes from.
 *
 * ⚠️ THE OTHER HALF OF THE INTERVAL IS THE POINT OF THIS PLUGIN. The same call reports how long
 * each connected player has been on this server, which is what lets the hub grant roles for
 * playing. A Discord bot pushing `oxide.grant` over RCON can do the whitelisting; it cannot do
 * this, because RCON only travels one way.
 *
 * ── WHAT IS SENT ────────────────────────────────────────────────────────────────────────────
 *
 * Per connected player: their SteamID64, the whole minutes since the previous sync, and the Oxide
 * groups they hold here. Nothing else — not their name, not their IP, nothing about the server.
 *
 * ── WHAT HAPPENS WHEN XIVE IS UNREACHABLE ───────────────────────────────────────────────────
 *
 * The last good roster is kept and keeps working. Only once it is older than StaleRosterMinutes
 * does FailClosed decide: refuse everyone new, or admit everyone. A whitelist that switches itself
 * off when its checker is unavailable is not a whitelist, so the default is to refuse — but a brief
 * outage changes nothing at all, because the roster is already on the box.
 */

namespace Oxide.Plugins
{
    [Info("Xive Whitelist", "Xive", "1.0.0")]
    [Description("Whitelist this server against Xive hub membership, and grant hub roles for playing on it.")]
    public class XiveWhitelist : CovalencePlugin
    {
        // ── configuration ───────────────────────────────────────────────────────────────────
        private string _apiKey;
        private string _syncUrl;
        private string _verifyUrl;
        private bool _failClosed;
        private int _syncSeconds;
        private int _staleRosterMinutes;
        private bool _debug;
        private string _mirrorPermission;

        // ── state ───────────────────────────────────────────────────────────────────────────

        /// <summary>Every SteamID64 allowed on right now. Replaced wholesale on each good sync.</summary>
        private HashSet<string> _roster = new HashSet<string>();

        /// <summary>
        /// Set when the hub is larger than one roster page. While true, a player who is NOT on the
        /// roster is UNKNOWN rather than refused, and is asked about individually — otherwise a
        /// large hub would lock out every member past the cap.
        /// </summary>
        private bool _rosterTruncated;

        /// <summary>Null until the first successful sync — which is different from "empty".</summary>
        private DateTime? _rosterFetchedAt;

        /// <summary>steamId -> the moment their play time was last credited to Xive.</summary>
        private readonly Dictionary<string, DateTime> _creditedTo = new Dictionary<string, DateTime>();

        /// <summary>
        /// Answers for players resolved individually since the last sync, so a reconnect loop does
        /// not become a request loop. Cleared on every sync, because the roster supersedes it.
        /// </summary>
        private readonly Dictionary<string, bool> _individual = new Dictionary<string, bool>();

        private Timer _syncTimer;

        /// <summary>Set while a request is in flight, so a slow API cannot stack up syncs.</summary>
        private bool _syncing;

        // ── lifecycle ───────────────────────────────────────────────────────────────────────

        private void Init()
        {
            permission.RegisterPermission("xivewhitelist.bypass", this);
            LoadConfigValues();
        }

        private void OnServerInitialized()
        {
            if (!KeyLooksSet())
            {
                PrintError("ApiKey is not set in oxide/config/XiveWhitelist.json. "
                         + "Issue one in your hub: Settings -> Integrations -> Rust. "
                         + (_failClosed ? "Every player will be refused until you do."
                                        : "Nobody will be checked until you do."));
                return;
            }

            // Everyone already on the server when the plugin loads starts accruing from now, not
            // from whenever they connected — the plugin cannot credit time it did not observe.
            foreach (var player in players.Connected)
                _creditedTo[player.Id] = DateTime.UtcNow;

            Sync();
            _syncTimer = timer.Every(_syncSeconds, Sync);
            Log($"started. Sync every {_syncSeconds}s. Fail policy: "
              + (_failClosed ? "closed (refuse when the roster is stale)"
                             : "OPEN (admit unchecked when the roster is stale)"));
        }

        private void Unload()
        {
            _syncTimer?.Destroy();
        }

        // ── the gate ────────────────────────────────────────────────────────────────────────

        /// <summary>
        /// Returning a string REFUSES the connection and shows it to the player; null admits.
        ///
        /// 🔴 EVERYTHING THIS TOUCHES IS LOCAL. No request is made here and none can be — see the
        /// header. Adding an HTTP call to this method is the one change that would break the plugin
        /// in a way that looks like it works, because the callback would fire long after the return.
        /// </summary>
        private object CanUserLogin(string name, string id, string ip)
        {
            if (!KeyLooksSet())
                return _failClosed ? Lang("BadKey", id) : null;

            // Server operators and admins must never be locked out by their own whitelist —
            // most importantly when it is misconfigured.
            if (permission.UserHasPermission(id, "xivewhitelist.bypass"))
                return null;

            if (_roster.Contains(id))
            {
                Debug($"allow {id} (roster)");
                return null;
            }

            bool individual;
            if (_individual.TryGetValue(id, out individual))
            {
                Debug($"{(individual ? "allow" : "deny")} {id} (individual)");
                return individual ? null : Lang("NotMember", id);
            }

            /*
             * Not on the roster. What that MEANS depends on whether the roster is complete and
             * fresh, and conflating the three cases is how a player gets told they are not a member
             * when in fact the server could not reach Xive.
             */
            if (_rosterTruncated)
            {
                // The roster never claimed to be complete, so absence proves nothing. Ask, and let
                // them back in on the reconnect once the answer has landed.
                AskAbout(id);
                return Lang("Checking", id);
            }

            if (RosterIsStale())
            {
                if (_failClosed)
                {
                    PrintWarning($"roster is stale and {id} is not on it; refusing (FailClosed).");
                    return Lang("Unreachable", id);
                }
                PrintWarning($"roster is stale; admitting {id} UNCHECKED (FailClosed = false).");
                return null;
            }

            /*
             * A complete, fresh roster that does not contain them. This is the ONLY case that is a
             * real refusal — but they may also have joined the hub thirty seconds ago, so ask in the
             * background: their next attempt will succeed without waiting for the sync interval.
             */
            AskAbout(id);
            return Lang("NotMember", id);
        }

        private void OnUserConnected(IPlayer player)
        {
            // Their time starts now. A player whose whole session falls between two syncs is still
            // credited, because the sync reads this dictionary rather than a connect event.
            _creditedTo[player.Id] = DateTime.UtcNow;
        }

        private void OnUserDisconnected(IPlayer player)
        {
            /*
             * ⚠️ THEIR REMAINING TIME IS CREDITED HERE, NOT DISCARDED. Otherwise a player who plays
             * for four minutes and leaves between two five-minute syncs is credited nothing, every
             * time — and on a busy server with short sessions that is most of the play time.
             */
            DateTime since;
            if (!_creditedTo.TryGetValue(player.Id, out since))
                return;

            int minutes = WholeMinutesSince(since);
            if (minutes > 0)
                _pending[player.Id] = PendingFor(player.Id) + minutes;

            _creditedTo.Remove(player.Id);
        }

        /// <summary>Minutes owed for players who left before a sync could report them.</summary>
        private readonly Dictionary<string, int> _pending = new Dictionary<string, int>();

        private int PendingFor(string id)
        {
            int n;
            return _pending.TryGetValue(id, out n) ? n : 0;
        }

        // ── talking to Xive ─────────────────────────────────────────────────────────────────

        private void Sync()
        {
            if (!KeyLooksSet() || _syncing)
                return;

            var now = DateTime.UtcNow;
            var payload = new List<Dictionary<string, object>>();

            // Players who left since the last sync, with the time they were owed.
            foreach (var entry in _pending)
            {
                payload.Add(new Dictionary<string, object>
                {
                    ["steam_id"] = entry.Key,
                    ["minutes"] = entry.Value,
                    ["groups"] = GroupsOf(entry.Key),
                });
            }
            _pending.Clear();

            // …and everybody still here.
            foreach (var player in players.Connected)
            {
                DateTime since;
                if (!_creditedTo.TryGetValue(player.Id, out since))
                {
                    _creditedTo[player.Id] = now;
                    continue;
                }

                int minutes = WholeMinutesSince(since);
                // ⚠️ ADVANCED BY WHAT WAS CREDITED, NOT TO `now`. Rounding down to whole minutes and
                // then resetting the clock would discard the remainder every single sync, so a
                // player on a 90-second cadence would accrue nothing forever.
                if (minutes > 0)
                    _creditedTo[player.Id] = since.AddMinutes(minutes);

                payload.Add(new Dictionary<string, object>
                {
                    ["steam_id"] = player.Id,
                    ["minutes"] = minutes,
                    ["groups"] = GroupsOf(player.Id),
                });
            }

            var body = JsonConvert.SerializeObject(new Dictionary<string, object> { ["players"] = payload });

            _syncing = true;
            webrequest.Enqueue(_syncUrl, body, (code, response) =>
            {
                _syncing = false;
                HandleSyncResponse(code, response);
            }, this, RequestMethod.POST, Headers(), 20f);
        }

        private void HandleSyncResponse(int code, string response)
        {
            if (code == 401 || code == 403)
            {
                // 🔴 A CONFIGURATION PROBLEM, NOT A PLAYER PROBLEM. Saying "you are not whitelisted"
                // here sends every player to an admin who then finds them present in the member list.
                PrintError("Xive rejected this server's API key. Issue a new one in your hub: "
                         + "Settings -> Integrations -> Rust, then update oxide/config/XiveWhitelist.json.");
                return;
            }
            if (code != 200 || string.IsNullOrEmpty(response))
            {
                PrintWarning($"sync failed (HTTP {code}). Keeping the roster we have"
                           + (RosterIsStale() ? ", which is now STALE." : "."));
                return;
            }

            SyncResponse parsed;
            try
            {
                parsed = JsonConvert.DeserializeObject<SyncResponse>(response);
            }
            catch (Exception e)
            {
                PrintWarning("sync response could not be read: " + e.Message);
                return;
            }

            if (parsed == null || !parsed.Success)
            {
                PrintWarning("sync response was not a success.");
                return;
            }

            if (!parsed.Enabled)
            {
                /*
                 * ⚠️ THE HUB TURNED THE INTEGRATION OFF. The roster is EMPTIED rather than kept:
                 * "stop checking against my hub" must not leave the last roster gating the server
                 * forever. FailClosed then decides what an empty-and-disabled state means, exactly
                 * as it decides what an unreachable one does.
                 */
                _roster.Clear();
                _rosterTruncated = false;
                _rosterFetchedAt = null;
                PrintWarning("this hub has turned Xive whitelist checks off.");
                return;
            }

            _roster = new HashSet<string>(parsed.Roster ?? new List<string>());
            _rosterTruncated = parsed.RosterTruncated;
            _rosterFetchedAt = DateTime.UtcNow;
            _individual.Clear();

            if (parsed.SyncSeconds > 0 && parsed.SyncSeconds != _syncSeconds)
            {
                // The API is the authority on its own cadence, so a change there does not need every
                // operator to edit a config file.
                _syncSeconds = parsed.SyncSeconds;
                _syncTimer?.Destroy();
                _syncTimer = timer.Every(_syncSeconds, Sync);
                Log($"sync interval changed to {_syncSeconds}s by the API.");
            }

            Debug($"roster {_roster.Count}{(_rosterTruncated ? " (TRUNCATED)" : "")}, "
                + $"reported {parsed.Recorded}, roles +{parsed.RolesGranted} -{parsed.RolesRemoved}");

            if (!string.IsNullOrEmpty(_mirrorPermission))
                MirrorToOxide();
        }

        /// <summary>
        /// Ask about one player the roster did not cover.
        ///
        /// The answer lands after they have already been refused, and is used on their NEXT attempt.
        /// That is the reconnect the message asks for, and it is the cost of a game with no deferral
        /// phase; for anyone on the roster — everybody, ordinarily — it never happens at all.
        /// </summary>
        private void AskAbout(string steamId)
        {
            if (_individual.ContainsKey(steamId))
                return;

            var body = JsonConvert.SerializeObject(new Dictionary<string, object> { ["steam_id"] = steamId });

            webrequest.Enqueue(_verifyUrl, body, (code, response) =>
            {
                if (code != 200 || string.IsNullOrEmpty(response))
                    return;
                try
                {
                    var parsed = JsonConvert.DeserializeObject<VerifyResponse>(response);
                    if (parsed == null)
                        return;
                    _individual[steamId] = parsed.Allowed;
                    Debug($"individual answer for {steamId}: {(parsed.Allowed ? "allow" : parsed.Reason)}");
                }
                catch (Exception e)
                {
                    PrintWarning("verify response could not be read: " + e.Message);
                }
            }, this, RequestMethod.POST, Headers(), 20f);
        }

        /// <summary>
        /// Grant the roster an Oxide permission, so plugins that already gate on one — uMod's own
        /// Whitelist among them — see the same answer without knowing anything about Xive.
        ///
        /// ⚠️ THIS REVOKES AS WELL AS GRANTS, which is what makes it a mirror rather than a leak.
        /// Only ever touching the permission it was told to means a player granted it by hand is
        /// still taken back if they leave the hub, so this is off unless an operator asks for it.
        /// </summary>
        private void MirrorToOxide()
        {
            foreach (var steamId in _roster)
            {
                if (!permission.UserHasPermission(steamId, _mirrorPermission))
                    permission.GrantUserPermission(steamId, _mirrorPermission, this);
            }

            foreach (var userId in permission.GetPermissionUsers(_mirrorPermission))
            {
                // GetPermissionUsers returns "id (name)"; the id is everything before the space.
                var id = userId.Split(' ')[0];
                if (!_roster.Contains(id))
                    permission.RevokeUserPermission(id, _mirrorPermission);
            }
        }

        // ── helpers ─────────────────────────────────────────────────────────────────────────

        private Dictionary<string, string> Headers()
        {
            return new Dictionary<string, string>
            {
                ["Content-Type"] = "application/json",
                // A header, not the body, so the key stays out of request logs and error reports
                // that record payloads.
                ["Authorization"] = "Bearer " + _apiKey,
            };
        }

        private string[] GroupsOf(string steamId)
        {
            return permission.GetUserGroups(steamId) ?? new string[0];
        }

        private static int WholeMinutesSince(DateTime since)
        {
            var elapsed = DateTime.UtcNow - since;
            return elapsed.TotalMinutes < 1 ? 0 : (int)Math.Floor(elapsed.TotalMinutes);
        }

        private bool RosterIsStale()
        {
            return !_rosterFetchedAt.HasValue
                || (DateTime.UtcNow - _rosterFetchedAt.Value).TotalMinutes > _staleRosterMinutes;
        }

        private bool KeyLooksSet()
        {
            return !string.IsNullOrEmpty(_apiKey) && _apiKey != "xive_rs_REPLACE_ME";
        }

        private void Debug(string message)
        {
            if (_debug)
                Log(message);
        }

        private string Lang(string key, string userId)
        {
            return lang.GetMessage(key, this, userId);
        }

        // ── config ──────────────────────────────────────────────────────────────────────────

        protected override void LoadDefaultConfig()
        {
            Config["ApiKey"] = "xive_rs_REPLACE_ME";
            Config["SyncUrl"] = "https://api.thexive.com/api/hub/rust/sync";
            Config["VerifyUrl"] = "https://api.thexive.com/api/hub/rust/verify";
            Config["FailClosed"] = true;
            Config["SyncSeconds"] = 300;
            Config["StaleRosterMinutes"] = 30;
            Config["MirrorToOxidePermission"] = "";
            Config["Debug"] = false;
        }

        private void LoadConfigValues()
        {
            _apiKey = Convert.ToString(Config["ApiKey"] ?? "");
            _syncUrl = Convert.ToString(Config["SyncUrl"] ?? "");
            _verifyUrl = Convert.ToString(Config["VerifyUrl"] ?? "");
            _failClosed = Convert.ToBoolean(Config["FailClosed"] ?? true);
            _syncSeconds = Convert.ToInt32(Config["SyncSeconds"] ?? 300);
            _staleRosterMinutes = Convert.ToInt32(Config["StaleRosterMinutes"] ?? 30);
            _mirrorPermission = Convert.ToString(Config["MirrorToOxidePermission"] ?? "");
            _debug = Convert.ToBoolean(Config["Debug"] ?? false);

            // A sync faster than this is a request storm against a shared API for no benefit; the
            // roster does not change often enough to reward it.
            if (_syncSeconds < 60)
                _syncSeconds = 60;
        }

        protected override void LoadDefaultMessages()
        {
            lang.RegisterMessages(new Dictionary<string, string>
            {
                ["Checking"] = "Checking your Xive membership — please reconnect in a moment.",
                ["NotMember"] = "You are not a member of this server's Xive hub, or you have not linked "
                              + "your Steam account. Join the hub, link Steam in User Settings -> "
                              + "Connections, then reconnect.",
                ["Unreachable"] = "Could not reach Xive to check the whitelist. Please try again shortly.",
                ["BadKey"] = "This server's Xive whitelist is misconfigured. Please contact an admin.",
            }, this);
        }

        // ── wire shapes ─────────────────────────────────────────────────────────────────────

        private class SyncResponse
        {
            [JsonProperty("success")] public bool Success { get; set; }
            [JsonProperty("enabled")] public bool Enabled { get; set; }
            [JsonProperty("roster")] public List<string> Roster { get; set; }
            [JsonProperty("roster_truncated")] public bool RosterTruncated { get; set; }
            [JsonProperty("sync_seconds")] public int SyncSeconds { get; set; }
            [JsonProperty("recorded")] public int Recorded { get; set; }
            [JsonProperty("roles_granted")] public int RolesGranted { get; set; }
            [JsonProperty("roles_removed")] public int RolesRemoved { get; set; }
        }

        private class VerifyResponse
        {
            [JsonProperty("success")] public bool Success { get; set; }
            [JsonProperty("allowed")] public bool Allowed { get; set; }
            [JsonProperty("reason")] public string Reason { get; set; }
        }
    }
}
