# Stress Test Optimization — Progress Tracker

Portable handoff document for the 8-client stress test optimization work. The original plan
lived in Cursor's local plans folder; this file is the repo-local source of truth so the work
can continue from any editor/agent.

Last updated: 2026-06-11 (end of Pass 2).

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
| 3 | Shared plot-scope helper; bind SlotXPBillboard / PatchSlotVisuals / AppleTreeSlotVisuals / PetAnimations to assigned plot | **NEXT** |
| 3 | SlotXPBillboard: lazy GUI creation, 0.2s tick, hoist RuntimeGuard out of hot loops | pending |
| 3 | Gate: full passive run, client GUI/record counts + frame stats, Microprofiler check | pending |
| 4 | Harness: randomized tree-click start offsets and interval jitter | pending |
| 4 | Distance-gate PetAnimations renders; UiEffects billboard checks to 0.1–0.2s shared pass | pending |
| 4 | Tree VFX caps/coalescing (only if active runs still spike after the above) | pending |
| — | Final manual gate: 8-client Studio test matrix vs success criteria | pending |
| — | `docs/publish-checklist.md` pass before the Pass 2 patch redesign ships | pending |

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

## Pass 3 — Client plot scoping (NEXT)

- Build one shared plot-scope helper (assigned plot + optional nearby plots, rebinds on
  reassignment) and use it in `SlotXPBillboard.luau`, `PatchSlotVisuals.luau`,
  `AppleTreeSlotVisuals.luau`, and `PetAnimations.luau` instead of binding all of
  `Workspace.Plots` (today every client tracks every plot's slots/pets).
- `SlotXPBillboard`: lazy-create `BillboardGui`s only when in range (today 2400 GUIs are
  cloned into `PlayerGui` up front), tick at 0.2s instead of every Heartbeat, hoist
  `RuntimeGuard.Run` out of per-item hot loops (same pattern applies to `PatchSlotVisuals`
  and `AppleTreeSlotVisuals`).

Gate (MCP): full passive run; client-side tracked-record/GUI counts and frame stats;
Microprofiler check for repeated 80ms+ frames.

## Pass 4 — Active tree clicking polish

- Harness: randomized per-tree start offset and click interval jitter so active runs stop
  synchronizing all 240 trees onto the same frames.
- Distance-gate `renderPet` work in `PetAnimations.luau`; move `UiEffects` billboard
  distance checks off `RenderStepped` into a 0.1–0.2s shared pass.
- Tree VFX caps/coalescing only if the post-jitter active run still shows client spikes —
  the 75-stud server gate in `feedMachines/Trees.luau` plus Pass 3 plot scoping may already
  be enough.

Final gate (manual): multi-client Studio session running the full 8-client test matrix
against the success criteria above.

## Working-tree state at handoff

All Pass 1 + Pass 2 changes are uncommitted on top of `bb0a15d` ("Docs: update plot-scoped
architecture guidance"):

- Modified: `src/client/ui/AppleTreeSlotVisuals.luau`, `src/client/ui/PatchSlotVisuals.luau`,
  `src/client/ui/SlotXPBillboard.luau`, `src/server/OnboardingService.luau`,
  `src/server/PetMotionService.luau`, `src/server/PetNavigation.luau`,
  `src/server/PlotGridService.luau`, `src/server/PlotService.luau`,
  `src/server/feedMachines/Patches.luau`, `src/server/feedMachines/Trees.luau`,
  `src/server/feedMachines/init.luau`, `src/server/init.server.luau`, `src/shared/State.luau`
- New: `src/shared/PatchGrowth.luau`, `src/server/dev/PlotStressTest.luau`
  (`Trees.luau`/`feedMachines/init.luau`/`init.server.luau` changes are the harness hooks:
  `StressClick` path and Studio-only `PlotStressTest` wiring.)

No automated Luau lint/format toolchain exists in this repo; validation is Studio
playtests + the harness gates described above. `rojo serve` must be running for Studio to
pick up source changes.
