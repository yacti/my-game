# Publish Checklist

Run this checklist before publishing a live build.

## Source And Studio State

- Git working tree is clean.
- Rojo is connected and fully synced.
- `ReplicatedStorage.Remotes` exists exactly once and contains every remote
  declared in `default.project.json`.
- `ReplicatedStorage.Assets.PetModels` templates contain no baked `ProximityPrompt`s.
- Required Studio-owned assets exist until they are moved into source control:
  `Assets.PetModels`, `Assets.FeedMachines`, `Assets.Food`, `Assets.Crates`,
  `UI`, `Assets.Cosmetics`, `Assets.CosmeticTool`, `Assets.FeedMachineTool`, `Assets.SeedTool`, `Assets.Shovel`,
  `Assets.Seeds`, `Assets.Misc.Sapling`, `Assets.Misc.Brick`, and
  `Assets.VFX.RarityParticle`.
- Studio-owned `ReplicatedFirst.LoadingScreen` exists with `Root`,
  `Root.LoadingBar.Fill`, `Root.PercentLabel`, `Root.TapToPlayLabel`, and
  `Root.TapCaptureButton`; `ReplicatedFirst.LoadingScreenLoader` is present and
  there is no Rojo `ReplicatedFirst` mapping unless ownership intentionally
  changes.
- `Workspace.Map.LoadingScreenCamera` is an anchored, invisible,
  non-collidable, non-touchable, non-queryable camera marker.
- `ReplicatedStorage.UI.YesNoWarning` has `Description`, `Item`, `Yes`,
  `No`, and `CloseButton` descendants.
- Risky Studio/MCP asset edits have a matching `.rbxm` or `.rbxmx` checkpoint
  under `asset-backups/`.

## Data

- `src/server/PlayerDataService.luau` store policy is intentional:
  `STORE_NAME = "PlayerData"` and Studio uses ProfileStore mock mode by default.
- Dev and live are separate Roblox experiences. Dev data can be fresh or disposable,
  but publishing over live must preserve existing live `PlayerData` profiles.
- Any change that reads, migrates, sanitizes, snapshots, saves, or fulfills receipts
  against `PlayerData` has been reviewed against the current live profile shape, not
  only against fresh dev profiles.
- Fresh ProfileStore profile receives expected default pet, starter cosmetic tool, no persisted feed/seed/food inventory tools, utility shovel, and starting currency.
- Server output shows ProfileStore has DataStore access in production test
  environments.
- Leave/rejoin preserves pets, feed machines, growing seed placements, seed
  inventory, feed inventory, food inventory, cosmetic placements, cosmetic
  inventory, currency, and patch/processor/tree machine state.
- Tree ground piles restore as invisible authoritative marker state, not replicated
  visible fruit model geometry.
- Countable inventory tools cap at 250 (`Inventory.MAX_ITEMS`, Backpack + equipped).
  The utility shovel does not count. At the cap, pickups/harvests/processor/jam
  output, seed/feed/cosmetic grants, and shop grants are refused with a rate-limited
  "inventory full" notification; food-producing sources stay recoverable (ground
  pile, patch slot, or machine queue retained). A profile hoarding more than 250
  countable tools materializes at most 250 on join.

## Gameplay Security

- `PlaceFeedMachine` rejects malformed payloads and rate-limits placement.
- `PromptInteract` uses shared action constants, rate limits, and server-side
  ownership/distance/state validation.
- Food XP used by server actions is clamped through server-known food templates.
- Per-player locks, cooldowns, caches, and diagnostics use stable `UserId` keys
  where practical and are cleared on leave/session cleanup.
- Tool-consuming requests use `ToolIdentity` GUIDs to resolve and delete the exact
  equipped/backpack tool instance instead of matching by name.
- Roblox service calls, receipt paths, runtime callbacks, and long-running loops
  use validation plus `RuntimeGuard`/`pcall` style protection where an error would
  otherwise kill important gameplay behavior.
- Robux-backed Server Luck affects random crate odds; review current Roblox
  paid-random-item policy, restrictions, and odds disclosure before publishing.

## Client Runtime

- `RenderStepped`/`Heartbeat` connections disconnect when their owning GUI, model,
  plot, character, or controller is destroyed or no longer relevant.
- Collection renderers such as pets use one central render loop that iterates tracked
  instances and prunes invalid entries, not one render connection per object.

## Runtime Output

- Join a clean session and confirm no infinite-yield warnings.
- Confirm no missing template warnings for feed machines, food, crates, or roll-area assets.
- Confirm no duplicate feed type warnings.
- Confirm seed roll templates have valid `FeedType`, `GrowTime`, `RollChanceN`,
  `Price`, and display `Rarity` attributes.
- Confirm Misc roll templates with `MiscID` have valid `RollChanceN`, `Price`,
  and display `Rarity` attributes.
- Confirm feed-machine templates do not duplicate seed-owned `GrowTime`,
  `RollChanceN`, `Price`, or `Rarity` attributes.
- Confirm any missing `ReplicatedStorage.UI` warnings are intentional; missing UI
  should skip the affected UI path and should never create fallback UI.
- Confirm the custom loading screen appears from `ReplicatedFirst`, removes the
  default Roblox loader, uses `Lighting.UiBlur`, points the camera at
  `Workspace.Map.LoadingScreenCamera`, reaches tap-to-play after readiness or
  timeout, and restores camera/blur cleanly after dismissal.
- Confirm cosmetic templates under `ReplicatedStorage.Assets.Cosmetics` have
  unique `CosmeticID` attributes and model `PrimaryPart`s.
- Confirm `ReplicatedStorage.UI.BillboardGUIs` has `SeedRoll` and `MiscRoll`
  billboard templates with the expected text labels.
- Confirm local prompts show correct per-player context.
- Confirm local prompt discovery only targets authoritative plot instances and never
  client-local tree fruit visuals.
- Buy Server Luck from the Robux shop, verify all players receive the notification
  and local confetti, and verify `HUD.Buffs.ServerLuck` hides at `1x` and shows
  the active multiplier/timer while boosted.
- Buy VIP gamepass id `1875159706` from both Robux shop locations, verify both VIP
  cards show `Sold`, `HUD.Buffs.VIP` shows only for VIP owners, Sold state
  persists after rejoin through Marketplace ownership verification, pet cash-rate
  billboards show the 1.25x VIP rate, online/offline pet cash generation use
  `PetCashEarnRate = 1.25`, and roll luck includes VIP as an additive `+25%`
  source. Because VIP affects random crate odds, review paid-random-item policy
  and odds disclosure together with Server Luck before publishing.
- Buy x2 Cash gamepass id `1874365753`, verify the `x2Cash` Robux shop card
  shows `Sold`, ownership persists after rejoin, pet cash-rate billboards use the
  additive effective rate, and online/offline pet cash generation stacks with VIP
  as `2.25x` instead of multiplying to `2.5x`.
- Join a server with 1-4 Roblox friends, verify `HUD.Currency.FriendBoost` shows
  `+10%` per same-server friend up to `+40%`, live pet money generation stacks
  additively with VIP/x2 Cash, offline earnings and cash-pack hourly income stay
  unchanged by friend boost, and `HUD.Currency.InviteFriends` opens Roblox's
  native invite prompt when available on the player's platform.
- Buy x2 Food XP gamepass id `1876239739`, verify the `x2XP` Robux shop card
  shows `Sold`, feeding a pet grants double the equipped food tool's stored XP,
  food tool XP labels remain unchanged, and patch/tree/processor/jam outputs are
  not changed by the pass.
- Buy x2 Luck gamepass id `1874769695`, verify the `x2Luck` Robux shop card
  shows `Sold`, roll luck includes the pass as additive `+100%` player luck,
  revealed roll chance text reflects effective server-side odds, and player-facing
  copy does not imply every final rare reward chance is exactly doubled. Because
  x2 Luck affects random crate odds, review paid-random-item policy and odds
  disclosure together with Server Luck and VIP before publishing.
- Buy Starter Pack from the Robux shop, verify it grants six `AppleTreeSeed`
  tools across four displayed reward slots, shows `Sold` after purchase, stays
  sold after rejoin, blocks a second in-game purchase attempt, does not double-grant
  on receipt retry, and refuses purchase preflight when fewer than six inventory
  slots are open.
- Buy each Robux cash pack (`3604620536`, `3604620549`, `3604620570`,
  `3604620596`) from `RobuxShop.SFHolder.CashPacks`, verify each purchase can
  be repeated, grants the rounded displayed cash amount once per receipt, and
  does not double-grant on receipt retry.
- Evolve a pet, rebirth, and buy VIP/x2 Cash, then verify Robux cash pack amounts
  update from the live hourly pet income cache and use online pet income rather
  than the offline earning fraction.
- Equip the shovel, click a placed plant, confirm through `YesNoWarning`, and
  verify the plant deletes, saves, and does not delete processors or other plots.
- Click tree fruit on multiple `FeedClass = "Tree"` templates, verify nearby
  clients see drop/shake effects, visible ground fruit appears only when close,
  pickup targets the invisible marker, and far clients do not keep unnecessary
  ground fruit visuals.
- During active onboarding, verify `HUD.TopBar` is hidden and plot wind does not play.
  After onboarding is complete, verify `Weather.Windy` starts on synchronized 10-minute
  wall-clock marks (`HH:00`, `HH:10`, etc.), lasts 60 seconds, and shows through
  `HUD.TopBar.CurrentEvent.Windy` with `EventTimer.Timer = "NOW"` and
  `CurrentEventTimer` showing `Events end in ...`. Verify `Sunny` shows while no event is active,
  the next weather countdown points at the next 10-minute mark, the white
  `It's getting windy...` notification appears 3 seconds before wind starts,
  wave processing is capped at 50 events per heartbeat, and client wind lines
  move from positive X toward negative X while wind audio, 15x cloud speed, and
  60 Hz cloud updates ramp up for 4 seconds. Verify every mature tree sways and
  runs 32-52 independent shake/drop waves during the 52-second active window,
  each wave drops 2-4 ready fruit when available, wind-triggered tree shake sounds
  play once per wave with spatial rolloff, drop effects are only received within
  35 studs even for the plot owner, wind lines/audio/cloud speed/cloud update rate
  ramp down for 4 seconds, and local wind trail attachments do not affect collision,
  placement, edit, or tree click raycasts.
- Click `HUD.TopBar.Home` from away from the plot spawn and verify the player is
  server-teleported to their assigned plot `SpawnLocation`.
- With dense feeds/cosmetics, verify pet navigation still routes around placements
  after place, move, delete, seed maturity, restore, and teardown.
