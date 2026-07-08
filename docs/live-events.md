# Live Events Operator Runbook

Global live events (currently the Alien invasion) are controlled by `src/server/LiveEventCommandService.luau` from the **server command bar**, plus the owner-only **Admin Panel** UI (see below), which is a thin client over the same control plane. The live Developer Console server command bar is restricted by Roblox to users with edit permission on the place.

## Admin Panel

`ReplicatedStorage.UI.Menu.AdminPanel` is wired by `src/client/ui/AdminPanelController.luau` to `src/server/AdminPanelService.luau`. It stays invisible and inert until armed from the server command bar:

```lua
require(game.ServerScriptService.Server.AdminPanelService).Toggle()          -- every allowlisted admin in this server
require(game.ServerScriptService.Server.AdminPanelService).Toggle(17722150)  -- one player
```

Security: every remote command is validated server-side against the hardcoded allowlist in `AdminPanelService` (`ADMIN_USER_IDS`, currently only 17722150) **and** requires the panel to be armed via the command above — so even a compromised owner account cannot fire panel commands unless someone with edit permission armed the panel on that server. Closing the panel (X or switching menus) disarms it. Unauthorized requests are dropped silently and logged. In Studio only, local test clients are also eligible (`AdminPanelCommand`/`AdminPanelResult` attributes on `ServerScriptService.Server` drive the toggle from separate-VM command bars, same pattern as `GameEventDev`).

Panel sections → control plane: OwnerMessage/AlienMessage GO buttons → `SendGlobalMessage` (Owner/Alien preset; the GO button is the **only** submit path), LuckAmount CONFIRM → `SetAdminLuck` (preview in `LuckPreview`; the REMOVE button switches the row to removal mode — preview reads `LUCK REMOVED` and CONFIRM pushes `StopAdminLuck` instead), AdminEvents → `StartGlobalEvent("Alien")` / `StopGlobalEventsByEventId("Alien")`, PadToggle → `SetAdminPartyPad`, CrateDrops → `DropAdminCrate` (InfernoCrate x75 / SaturnCrate x250 / UFOCrate x1000; mythic/secret unwired for now). All panel commands land in the audit list with `operatorNote = "AdminPanel <name>"`.

## Architecture (summary)

- **DataStore `LiveEvents_v1` / key `GlobalState`** is the durable source of truth. All writes go through `UpdateAsync` with pure, non-yielding transforms. Command writes **fail closed**: if the write fails, nothing starts and nothing is published.
- **MessagingService topic `LiveEvents_v1`** is the best-effort fast path (compact revision-gated deltas; `commandId` is carried for idempotent writes and audit). Typical propagation is sub-second.
- Every server **subscribes first, then reconciles** from the DataStore at startup, and re-polls every 20–30s (jittered). A server that misses a message or restarts mid-event self-heals within one poll.
- `GameEventService.SetExternalManualRecords("LiveEvents", records)` merges global records with scheduled weather and local command-bar records; `LayerConfigs` caps still apply.

## Running commands

In a **live server**: press F9 → Developer Console → switch to the **Server** tab → use the command bar at the bottom. In **Studio**: use the command bar during a Play Solo session (this hits the *dev experience's* real DataStore/MessagingService — a separate namespace from live).

**Important:** every console command runs in a fresh environment — `local` variables do not carry over between commands. Stash the module in `_G` first (persists for the console session):

```lua
_G.LE = require(game.ServerScriptService.Server.LiveEventCommandService)
```

Then each of these works as a single console command:

```lua
-- Start a global Alien for 120 seconds. commandId is optional (auto-GUID);
-- provide one when you may retry the same command so retries are idempotent.
local ok, r = _G.LE.StartGlobalEvent("Alien", { durationSeconds = 120, commandId = "alien-2026-07-02-a" }) print(ok, typeof(r) == "table" and r.instanceId or r)

-- See what's active (local cached view).
for _, r in ipairs(_G.LE.ListGlobalEvents()) do print(r.eventId, r.instanceId, math.floor(r.endsAt - workspace:GetServerTimeNow()) .. "s left") end

-- Stop things.
print(_G.LE.StopGlobalEvent("Global_Chaos_Alien_<guid>"))
print(_G.LE.StopGlobalEventsByEventId("Alien"))
print(_G.LE.StopGlobalEventsByLayer("Chaos"))
print(_G.LE.StopAllGlobalEvents())   -- the "abort everything" button

-- Global admin messages (HUD AdminText banner, all servers).
local ok, m = _G.LE.SendGlobalMessage("We are coming for your crops...", { preset = "Alien" }) print(ok, typeof(m) == "table" and m.messageId or m)
local ok, m = _G.LE.SendGlobalMessage("Everyone to your plots!", { preset = "Owner" }) print(ok, typeof(m) == "table" and m.messageId or m)
for _, m in ipairs(_G.LE.ListGlobalMessages()) do print(m.presetId, m.messageId, m.text) end
print(_G.LE.ClearGlobalMessages())   -- wipe the banner everywhere

-- Admin party: bonus roll pad + admin-only high-luck crate drops.
print(_G.LE.SetAdminPartyPad(true))    -- pad appears on every plot, every server (durable)
print(_G.LE.DropAdminCrate("UFOCrate"))     -- x1000 luck; also "SaturnCrate" (x250), "InfernoCrate" (x75)
print(_G.LE.SetAdminPartyPad(false))   -- pad hidden everywhere; unresolved admin offers cleared

-- Global admin luck (additive on top of crate/player/server luck; durable,
-- replace semantics, multipliers whitelisted to 2/5/10/25, ceiling 72h).
print(_G.LE.SetAdminLuck(5, 1800))     -- x5 admin luck for 30 min on every server
print(_G.LE.StopAdminLuck())           -- clear the boost everywhere
local r = _G.LE.GetAdminLuck() print(r and ("x" .. r.multiplier .. ", " .. math.floor(r.endsAt - workspace:GetServerTimeNow()) .. "s left") or "inactive")

-- Force an immediate DataStore reconcile on this server.
print(_G.LE.ReconcileNow())
```

No-setup alternative — fully self-contained one-liner (works even after a console reset):

```lua
local ok, r = require(game.ServerScriptService.Server.LiveEventCommandService).StartGlobalEvent("Alien", { durationSeconds = 120 }) print(ok, typeof(r) == "table" and r.instanceId or r)
```

`StartGlobalEvent` returns `true, record` (the record includes the `instanceId` you need for `StopGlobalEvent`) or `false, code`. Stop commands return `true, count` (`0` when nothing matched).

## Semantics and guardrails

- **Chaos layer only.** Weather (Windy/Stormy) stays schedule-driven; `layer-not-allowed` otherwise.
- **Single instance per event ID globally.** Starting `Alien` atomically replaces any existing global Alien.
- **Duration caps.** Per-event `maxGlobalDurationSeconds` in `GameEvents.EventConfigs` (Alien: 600s). Absolute ceiling 72h. Omitting `durationSeconds` uses the event's natural duration (Alien ≈ 352s).
- **One shot per server.** Once a server's Alien cycle completes (with or without zaps), that instance is suppressed on that server until `endsAt + 60s`. It does not return for newly-matured food, and a zero-zap server does not retry.
- **Layer caps.** `Chaos.maxActive = 3` is enforced inside the DataStore transform — lower-priority records are displaced by priority, or the new record is rejected (`layer-full`).
- **Idempotency.** A `commandId` identifies **one occurrence** of an event. The ledger survives stops and server restarts (this is what makes retries safe) and holds the newest 64 commands — an old id is only forgotten after 64 newer commands evict it; never plan around reuse. Same `commandId` + same parameters → idempotent success: returns the running record, or `true, "already-processed-not-active"` if that run has since stopped/expired (nothing starts). Same `commandId` + different parameters → `command-conflict`. **Liveops rule: new run = new commandId** (e.g. bump `alien-2026-07-02-1` → `-2`); only reuse an id to retry a command that failed.
- **Same-key write cooldown.** DataStore throttles same-key writes to one per 6s **experience-wide**; commands are serialized and spaced automatically — rapid-fire commands queue for a few seconds each. Event times are stamped at commit, so queue wait never eats into a queued event's duration.
- **Mixing local + global.** A local `GameEventService.StartManualEvent("Alien")` record and a global Alien can coexist under Chaos (max 3), but only one drives the handler on a given server — earliest `startsAt` wins; the other takes over when it completes. Avoid local Alien tests during a live global run.
- **Admin party.** `SetAdminPartyPad(true/false)` is durable — servers booting mid-party reconcile the pad on. `DropAdminCrate(crateId)` is **one-shot for players present at that moment** (tutorial/offline-pending players excluded); drop again to cover late joiners; a server that misses the broadcast skips that drop (rare — repeat the command). The dropped crate reveals a normal **purchasable** offer rolled with the crate's luck (Inferno x75 / Saturn x250 / UFO x1000, sharing the usual crate+player+server+admin luck formula), plus the toast "yacti has dropped a crate on your farm!". The reveal card always shows the seed's **original** rarity odds (e.g. Cactus "1 in 1,200") — the boosted luck decides what drops, not the displayed chance. Latest-batch-wins like all rolls: the drop replaces the player's pending offers, and a later normal roll replaces the admin crate. Admin offers do not survive rejoin. Toggling the pad off clears unresolved admin offers everywhere.
- **Admin luck.** `SetAdminLuck(multiplier, durationSeconds, { commandId, operatorNote })` applies a global luck boost, additive on top of crate, player, and server luck (`RollChances.EffectiveLuckMultiplier` gains `(admin − 1)`). Durable — servers booting mid-boost reconcile it. **Replace semantics**: a new boost overwrites the running one from commit time (the panel preview always matches the result). Multipliers are whitelisted in `src/shared/AdminPanelConfig.luau` (2/5/10/25); duration must be positive, ceiling 72h. `StopAdminLuck()` clears it everywhere; `GetAdminLuck()` returns the active record or `nil`. Clients see it as the `HUD.Buffs.AdminLuck` badge via `AdminLuckMultiplier`/`AdminLuckEndsAt` attributes on ReplicatedStorage.
- **Admin messages.** `SendGlobalMessage(text, { preset, durationSeconds, commandId, operatorNote })` — presets live in `src/shared/AdminMessagePresets.luau` (`Owner`, `Alien`; each sets template frame, display name, photo, colours). Text max 180 bytes. `durationSeconds` (default 30, max 300) is the **receivable window**: players/servers arriving within it still get the message; on-screen time is fixed at 11s per client (queue of max 3, newest at bottom, oldest forced out, typewriter reveal). Hidden during the tutorial, shown after if the window is still open. Each client shows a message once. `ClearGlobalMessages()` also hides messages currently on screen everywhere.

## Error codes

Failure codes (`false, code`): `invalid-event`, `unknown-event`, `invalid-layer`, `layer-not-allowed`, `invalid-options`, `invalid-duration`, `duration-too-long` (3rd return is the cap), `invalid-command-id` (max 64 chars, valid UTF-8), `invalid-instance`, `invalid-multiplier` (`SetAdminLuck` accepts only whitelisted multipliers), `command-conflict`, `layer-full`, `state-version-newer` (durable state written by a newer code version — do not fight it), `datastore-unavailable`, `datastore-budget-exhausted`, `datastore-write-failed` (fail-closed — safe to retry with the same `commandId`).

Success markers (`true, ...`): a record table (started / still running), `"already-processed-not-active"` (commandId already used; that run has ended — nothing started), `0` from stop commands when nothing matched.

## Audit

Every command appends `{commandId, action, createdAt, sourceJobId, placeId, note}` to a capped audit list inside `GlobalState`. Pass `operatorNote = "reason"` to `StartGlobalEvent` to tag why. Inspect via:

```lua
print(game:GetService("HttpService"):JSONEncode(
	game:GetService("DataStoreService"):GetDataStore("LiveEvents_v1"):GetAsync("GlobalState").audit
))
```

## Testing notes

- MessagingService does **not** deliver between Studio and live servers, and Studio sessions are single-server — cross-server behavior can only be validated in a **published place** (use the dev experience; set max players to 1–2 to force multiple servers).
- Studio Play Solo still exercises the full single-server path: DataStore write → local apply → event runs → suppression → stop → reconcile.
- Dev and live are separate experiences, so Studio/dev testing never touches the live `LiveEvents_v1` store.
- If a stray record is ever stuck (e.g. after a bad deploy), `StopAllGlobalEvents()` removes everything durably; individual servers converge within one reconcile poll.
