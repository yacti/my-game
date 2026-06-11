# Stress Test Optimization — Progress Tracker

Portable handoff document for the 8-client stress test optimization work. The original plan
lived in Cursor's local plans folder; this file is the repo-local source of truth so the work
can continue from any editor/agent.

Last updated: 2026-06-11 (end of Pass 4; all four passes complete — the 8-client manual
gate is what remains).

## Origin

An 8-client manual stress test (8 players, each plot populated with 10 pets, 300 patches,
30 trees) showed multi-second server heartbeat spikes during populate, sustained high p95
in steady state, a `pets = 73 / errors = 7` anomaly with no captured error text, and heavy
client-side work from globally-scoped UI watchers. The work is organized as four passes,
each followed by a measurement gate so regressions stay attributable.

## Status

| # | Item | Status |
|---|---|---|
| 1 | Fix `animate` nil-global bug in `AppleTreeSlotVisuals.luau` | DONE |
| 1 | Harness: capture first ~20 LogService warnings/errors per run | DONE |
| 1 | Harness: continue-not-break in `placePetBatch`, per-plot expected-vs-created telemetry | DONE |
| 1 | Harness: yield during populate; heartbeat sample resets post-populate/post-setup | DONE |
| 1 | Clamp `PetMotionService` heartbeat catch-up accumulator to one interval | DONE |
| 1 | Gate: passive baseline rerun with clean metrics | DONE |
| 2 | Patch growth redesign (derived XP, no 1Hz tick) | DONE |
| 2 | Per-plot pet nav grid cache with version-based invalidation | DONE |
| 2 | Gate: patches-only and pets-only validation runs | DONE |
| 3 | Shared plot-scope helper; bind SlotXPBillboard / PatchSlotVisuals / AppleTreeSlotVisuals / PetAnimations to assigned plot | DONE |
| 3 | SlotXPBillboard: lazy GUI creation, 0.2s tick, hoist RuntimeGuard out of hot loops | DONE |
| 3 | Gate: full passive run, client GUI/record counts + frame stats, Microprofiler check | DONE |
| 4 | Harness: randomized tree-click start offsets and interval jitter | DONE |
| 4 | Distance-gate PetAnimations renders; UiEffects billboard checks to 0.1–0.2s shared pass | DONE |
| 4 | Tree VFX caps/coalescing (only if active runs still spike after the above) | NOT NEEDED (verified: realistic active load is clean; only harness torture rates spike, and those saturate the server first) |
| 4 | Harness: live cap on stress-created tools; configurable tree-click interval | DONE |
| 5 | Remove legacy pet-segment replication (12 attrs + MotionSeq per publish) | DONE |
| 5 | Remove dead `PetMotionService.RefreshPet`; merge duplicate part-config helpers | DONE |
| 5 | Gate: full passive run; removed attrs absent on live pets; cornering intact | DONE |
| — | Final manual gate: 8-client Studio test matrix vs success criteria | **NEXT** |
| — | `docs/publish-checklist.md` pass after Pass 3, before any live publish (Pass 2 is on `main` but unpublished; the checklist exercises the same client visuals Pass 3 rewrites, so it runs once, after) | pending |

## Success criteria (final gate)

- No errors/warnings; populate counts exact on all plots.
- Server steady-state heartbeat p95 under 20–30ms; max under 250ms (no repeated 1s+ spikes).
- No repeated 80ms+ client frames while viewing 8 populated plots.
- The original `pets = 73 / errors = 7` anomaly explained or gone (it did not reproduce in
  single-owner MCP runs; the harness now captures error text, so the next multi-client
  session will identify it if it recurs).

## How runs are driven (works from any MCP-capable agent, or by hand in Studio)

The harness is `src/server/dev/PlotStressTest.luau`, wired into `init.server.luau`
(Studio-only). It is driven by attributes on `ServerScriptService.Server`:

| Attribute | Meaning | Typical |
|---|---|---|
| `PlotStressTestEnabled` | true starts a run, false stops/cleans up | — |
| `PlotStressTestPlotCount` | plots to populate (owner plot first) | 8 |
| `PlotStressTestPetsPerPlot` / `PatchesPerPlot` / `TreesPerPlot` | per-plot counts | 10 / 300 / 30 |
| `PlotStressTestDurationSeconds` / `MetricsSeconds` | run length / metrics interval | 75–120 / 15 |
| `PlotStressTestActiveCollection` | server-driven tree-click loops | false |
| `PlotStressTestTreeClickIntervalSeconds` | per-tree click interval for active runs (jittered ±30%) | 3 (realistic) / 0.22 (torture default) |
| `PlotStressTestDisableTutorial` | skip onboarding for the owner | true |

Sequence: start play mode with one client, wait for the player + plot assignment, set the
config attributes, flip `Enabled` to true. Telemetry (`plot_stress_plot_populated`,
`plot_stress_metrics`, `plot_stress_stopped`, captured error text) prints to the Studio
output console. A run auto-stops at duration and resets the plots. There are also client
chat-style remote commands (`populate`, `clicktrees`, `stopclicktrees`, `resetheartbeat`,
`clear`) via the `PlotStressTestCommand` RemoteEvent for realistic multi-client sessions.

Note for MCP `execute_luau`: it runs in a separate Luau VM, so requiring server modules
returns fresh module state — drive the real server through attributes/remotes (as above)
and validate through instance attributes, which are shared across VMs.

## Pass 1 — Bug fixes + harness hygiene (COMPLETED 2026-06-11)

Implemented:

- `src/client/ui/AppleTreeSlotVisuals.luau`: `animate` forward-declared; the initial tree
  scan no longer hits a nil global (production bug for clients joining with existing trees).
- `src/server/PetMotionService.luau`: heartbeat accumulator clamped to one `UPDATE_INTERVAL`
  — at most one `tickAll` per frame, no catch-up replay after a spike.
- `src/server/dev/PlotStressTest.luau`:
  - Captures the first 20 non-harness warning/error messages per run with timestamps; dumps
    them on both stop paths.
  - `placePetBatch` counts per-pet misses and continues; only plot-wide permanent failures
    (no unlocked point, missing template) break.
  - Yields every 25 feed placements / 5 pets during populate; per-user populate lock added
    since `preparePlot` now yields.
  - Per-plot expected-vs-created always printed + emitted as telemetry.
  - Heartbeat samples auto-reset post-populate and post-setup; manual `resetheartbeat`
    command and `PlotStressTest.ResetHeartbeatSamples()`.

Gate result (MCP, single owner, 8 plots x 300 patches / 30 trees / 10 pets, 120s):
counts exact (80/2400/240), zero errors/warnings, setup 15.6s with worst frame 1.6s
(previously one ~10s stall). Steady state: p50 ~6.4ms, p95 oscillating 15–107ms, recurring
1.2–2.1s max spikes — the pre-Pass-2 baseline.

## Pass 2 — Server steady-state (COMPLETED 2026-06-11)

### Patch growth redesign (derived, not ticked)

Gameplay unchanged (one XP interval per `GrowRate` seconds, identical harvest earnings),
but XP is now derived from time instead of replicated every second:

- New shared `src/shared/PatchGrowth.luau`:
  `xp(now) = baseXP + floor((now - growthStart) / growRate) * patchXP`, timestamps via
  `Workspace:GetServerTimeNow()` (shared server clock). New `State.Food.GrowthStart`
  attribute key in `src/shared/State.luau`.
- `src/server/feedMachines/Patches.luau` rewritten:
  - 1Hz growth loop removed (was ~2400 replicated attribute writes + 2400 profile/onboarding
    calls per second at stress scale). Slots store `baseXP` + `growthStart`; attributes are
    published only on spawn, harvest, respawn, restore, and offline credit. Harvest and
    serialize compute XP on demand from server state — economy-neutral by construction.
  - Respawn is `task.delay`-scheduled per harvest with a token guard; the callback re-arms
    itself if `respawnAt` was shifted by offline progress. Edit mode still defers slot
    materialization (`pendingMaterialize` + edit-mode-exit connection).
  - **Saved profile shape unchanged** (`slots = { xp, growthElapsed, respawnAt }`,
    `lastTick`): `Serialize` reconstructs it from the anchor; `Apply` converts it back.
    Backward and forward compatible. Deferred offline progress freezes slots (no
    `growthStart`) at saved XP until `ApplyOfflineProgress` credits
    `growthElapsed + offlineSeconds * OFFLINE_GROW_FRACTION` and re-anchors — same interval
    math as the old `applyGrowth`.
  - Onboarding pumpkin-XP progress keeps its per-second feel via a 1Hz loop that early-outs
    per player unless `OnboardingService.NeedsPatchXPReports(profile)` (new helper, true
    only in the `GatherPumpkinXP` stage); harvest also reports the final delta. Offline
    credit still counts toward progress, matching old behavior.
  - `Patches.HarvestAnchor` uses an `anchorIndex` map instead of scanning all machines.
- Clients derive XP locally:
  - `src/client/ui/SlotXPBillboard.luau` recomputes visible labels per heartbeat via
    `PatchGrowth.ComputeXPForFood`, re-rendering only when the value changes.
  - `src/client/ui/PatchSlotVisuals.luau` derives fruit scale in its existing 0.2s pass;
    dirty-flag attribute connections removed; the 80-per-step budget now counts only actual
    `ScaleTo` calls.

### Per-plot pet nav grid cache

- `src/server/PetNavigation.luau`: grids cached per plot, keyed by pet padding quantized UP
  to 0.25 (conservative — larger padding only blocks more, never less), shared across pets
  and by both `PlanWander` and `LegIsClear`; failed builds cached as `false`.
- Invalidation is lazy via two new monotonic version counters:
  - `PlotGridService.GetUnlockVersion(plot)` — bumped in `ApplyProfileState`,
    `ResetPlotState`, `ResetVacantPlotState`, `TryPurchaseCell`.
  - `PlotService.GetNavigationObstacleVersion(plot)` — bumped in `markPlacementBoundsDirty`
    and `clearPlacementRecord`; stored outside the placement record so it survives clears.
- `IsWalkableFootprint` spatial index deliberately deferred — unnecessary at current numbers.

### Gate result (MCP, single client, 75s runs, metrics every 15s)

| Run | Setup | Steady p50 | Steady p95 | Max | Errors |
|---|---|---|---|---|---|
| Patches-only, 8 x 300 (2400/2400) | 1.33s | 4.5–7ms | 6–9.5ms | 12.6–31.7ms | 0 |
| Pets-only, 8 x 10 (80/80) | 0.75s | ~4.2ms | ~4.6ms | 13–16ms | 0 |

(Pass 1 full baseline for comparison: p95 15–107ms with recurring 1.2–2.1s spikes.)

Functional checks, all via real paths:

- Server- and client-derived XP agree exactly (Pumpkin Patch, `GrowRate 1` / `XP 2`:
  110 @ 55s, 138 @ 69s elapsed).
- Harvest through the real client `PromptInteract -> PatchHarvest` remote granted a tool
  with XP 50, exactly the client's predicted value; slot emptied and respawned ~3s later
  with `baseXP 0` and a fresh `GrowthStart`.
- `SlotXPBillboard` labels tick live; the harvested slot correctly trails its neighbors.

Outstanding from the Pass 2 acceptance criteria:

- A `docs/publish-checklist.md` pass before the patch redesign ships.
- Offline-progress/rejoin persistence exercised live in the final manual gate (code path
  reviewed; saved shape unchanged, so old profiles restore losslessly).

## Pass 3 — Client plot scoping (COMPLETED 2026-06-11)

Implemented:

- New `src/client/ui/PlotScope.luau`: shared plot-scope registry. Scope = the assigned plot
  (always, via `PlotResolver`) plus plots whose `Floor` bounds are within `nearbyRange`
  studs of the character. Refreshes every 0.5s and on `AssignedPlotName` changes; exit uses
  a +20 stud hysteresis margin. Distance is measured to the closest point on the Floor
  part's bounds, not the plot center — floors are 81×187 studs, far larger than the
  per-item visual ranges. `onPlotAdded(plot)` may return a cleanup function invoked when
  the plot leaves scope (reassignment, distance, or removal).
- All four watchers now scan + bind `DescendantAdded`/`ChildAdded` per scoped plot and tear
  records down on scope exit, instead of binding all of `Workspace.Plots`:
  - `SlotXPBillboard` (scope 20): `BillboardGui`s are lazily created on 10-stud range entry
    and destroyed on exit — previously 2400 were cloned into `PlayerGui` up front. Tick is
    0.2s instead of every Heartbeat; per-item `RuntimeGuard.Run` hoisted (the connection
    wrapper still guards the pass). Also fixes a latent bug: a tick with no
    HumanoidRootPart (death) or a `PlayerGui` reset used to destroy all records
    permanently — records now survive and GUIs rebuild on the next in-range tick.
  - `PatchSlotVisuals` (scope 80 vs 70-stud item range): per-item guard hoisted.
  - `AppleTreeSlotVisuals` (scope 100, ≥ the server's 75-stud effect remote gate):
    per-marker guard hoisted; the `animated` map is intentionally kept across scope cycles
    so fruit grow-in tweens don't replay every time a plot re-enters scope.
  - `PetAnimations` (scope 150): pets on out-of-scope plots carry no records/tracks and
    freeze at their last pose; on scope entry they rebind and snap to the current
    server-replicated segment.

### Gate result (MCP, single client, full 8 x 300 patches / 30 trees / 10 pets, passive, 120s)

Server (steady state after populate): setup 2.56s; p50 4.17ms, p95 4.63–4.80ms,
max 12.7–58.3ms; zero warnings/errors; counts exact on all plots. (Pass 1 full-run
baseline: p95 15–107ms with recurring 1.2–2.1s max spikes.)

Client, viewing from the assigned plot:

- `XPBillboard` GUIs at rest: 0 (previously 2400 cloned up front). Standing beside a patch:
  10 (only the slots actually within the 10-stud range).
- Pets bound by proximity: 50/81 animating (assigned + 4 nearby plots); plots 6–8 dormant.
- 20s frame sample: p50 4.2ms, p95 4.7ms, p99 5.2ms, max 18.5ms — zero frames over 80ms
  (stands in for the Microprofiler check; a visual pass can ride along with the final
  manual gate).

Functional checks, all via real paths:

- Walk up to a patch: billboards appear within one tick, label ticks 66 → 72 xp over 3s and
  matches `PatchGrowth.ComputeXPForFood` exactly; fruit `GetScale()` 0.472 equals
  `PatchScale.ComputeScale` for the derived XP. Walk away: GUI count back to 0.
- Teleport to dormant Plot8: its pets animate and billboards appear within ~2s (scope
  refresh + rebind); Plot2/Plot3 evict; assigned Plot1 stays bound regardless of distance.
- Two full populate/teardown cycles with zero captured client or server errors.

## Pass 4 — Active tree clicking polish (COMPLETED 2026-06-11)

Implemented:

- Harness: per-tree random start offset plus ±30% interval jitter in both server-driven
  (`treeActivityLoop`) and client-command (`treeClickOnlyLoop`) click loops, so active runs
  no longer synchronize all 240 trees onto the same frames.
- Harness: `PlotStressTestTreeClickIntervalSeconds` attribute (default 0.22s remains the
  torture knob; 3s models 8 players auto-clicking ~10/s each) and a live FIFO cap of 200 on
  stress-created pickup tools. Without the cap, server-driven pickup rates granted the
  owner ~140 tools/s — 14.5k backpack tools in 90s, O(n²) backpack rescans, a replication
  flood that froze the client below 1 fps, and a teardown long enough to disconnect the MCP
  plugin. That accumulation was a harness artifact, not a game behavior.
- `PetAnimations.luau`: per-frame `renderPet` pivot math now runs only for pets within 120
  studs of the camera (renderable flag refreshed on a 0.25s cadence); gated pets freeze and
  snap to the current replicated segment on re-entry.
- `UiEffects.luau`: billboard distance checks moved off `RenderStepped` onto a 0.15s
  Heartbeat pass; Enabled-change reactions stay immediate via their property signal.

Findings from the gate runs:

- Tree VFX caps/coalescing (the conditional third item) are NOT needed. Under a realistic
  active load the client is clean (numbers below). Only the harness torture rate (0.22s
  interval = ~565–900 server-driven clicks+pickups/s) produces spikes, and at that rate the
  SERVER saturates first (p50 ~110ms) — a load real players cannot generate, since the
  production click path goes through rate-limited `PromptInteract`, not the harness's
  direct `StressClickTree`.

### Gate result (MCP, single client, full 8 x 300 / 30 / 10, ACTIVE at 3s/tree, 120s)

- Sustained ~80 clicks+pickups/s (9587 clicks, 9347 pickups over 122s), ~200 ground piles
  live, tool cap holding at 200.
- Server steady state: p50 4.2–4.5ms, p95 8.5–14ms, max 15–62ms; zero warnings/errors;
  counts exact. (Success criterion: p95 under 20–30ms, max under 250ms.)
- Client during active clicking: p50 4.5ms, p95 13.9ms, p99 17.1ms, max 24ms — zero frames
  over 33ms, with ground-fruit visuals (40 local) and drop/shake effects active.

Final gate (manual): multi-client Studio session running the full 8-client test matrix
against the success criteria above.

## Pass 5 — Dead/redundant code cleanup (COMPLETED 2026-06-11)

Swept for unused/redundant code across client ui, server, and shared (legacy replication
paths, uncalled public/local functions, orphan modules, unused requires/constants/State
keys). Executed before Pass 4 deliberately: the main finding reduces replication churn, so
Pass 4 measures against a cleaner baseline.

Removed:

- **Legacy pet-segment replication path.** `PetMotionService.publishSegment` wrote 12
  individual segment attributes plus `MotionSeq` alongside the packed `PetSegmentData`
  string on every publish (every few seconds per pet; 80 pets at stress scale). The legacy
  client reader was unreachable: segment attributes are ephemeral (never serialized to
  ProfileStore), the packed format has been stable at 12 values since `9b6246d`
  (2026-05-19), and a Roblox server instance and its clients always run the same place
  version, so cross-version replication compat does not apply. Now only `SegmentWalkSpeed`,
  `MotionState`, and `SegmentData` are written. Client `readLegacySegment`, the
  `packed == nil` fallback branch, and the values[10–12] attribute fallbacks are gone;
  `readSegmentData` requires exactly 12 values. The 12 orphaned `State.Pet` keys were
  removed from `State.luau`.
- `PetMotionService.RefreshPet` — public function with zero call sites (superseded by
  `RefreshPlotRoutes`).
- `AppleTreeSlotVisuals.configureLocalGroundPart` — identical to `configureEffectPart`;
  merged.

Checked and deliberately kept: `lastTick`/`growthElapsed` in `Patches.luau`
Serialize/Apply (saved-profile shape compatibility), the Studio-only
`dev/PlotStressTest.luau` harness and its hooks, the `animated` map persistence in
`AppleTreeSlotVisuals` (prevents tween replay on scope re-entry, Pass 3). Everything else
surveyed came back clean: no orphan client-ui modules, no unused requires, all other
public server functions in use.

### Gate result (MCP, single client, full 8 x 300 / 30 / 10 passive, 120s)

- Server: setup 2.51s; steady p50 4.16–4.19ms, p95 4.62–4.77ms, max 9.8–15.9ms after the
  first interval; zero warnings/errors; counts exact — in line with (maxes slightly better
  than) the Pass 3 gate.
- 81/81 live pets carried only the packed `SegmentData` (12 values, all parsed) and none
  of the removed attributes; 16 were mid-corner (`cornerRadius > 0`), exercising the
  values[10–12] path without attribute fallbacks.
- Client: 11/11 Plot1 pets animating, Plot8 dormant (plot scope intact), and a walking pet
  moved 3.05 studs/s — renderer healthy under the strict 12-value parser.

## Working-tree state

Pass 1 + Pass 2 are committed as `1e6103b`, Pass 3 + Pass 5 as `30b21aa`, both on `main`
and pushed. Pass 4 (harness jitter + tool cap, pet render distance gating, UiEffects
shared pass, this doc update) is the working tree on top of `30b21aa`.

No automated Luau lint/format toolchain exists in this repo; validation is Studio
playtests + the harness gates described above. `rojo serve` must be running for Studio to
pick up source changes.
