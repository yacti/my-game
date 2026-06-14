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
- Buy Starter Pack from the Robux shop, verify it grants six `AppleTreeSeed`
  tools across four displayed reward slots, shows `Sold` after purchase, stays
  sold after rejoin, blocks a second in-game purchase attempt, does not double-grant
  on receipt retry, and refuses purchase preflight when fewer than six inventory
  slots are open.
- Equip the shovel, click a placed plant, confirm through `YesNoWarning`, and
  verify the plant deletes, saves, and does not delete processors or other plots.
- Click tree fruit on multiple `FeedClass = "Tree"` templates, verify nearby
  clients see drop/shake effects, visible ground fruit appears only when close,
  pickup targets the invisible marker, and far clients do not keep unnecessary
  ground fruit visuals.
- With dense feeds/cosmetics, verify pet navigation still routes around placements
  after place, move, delete, seed maturity, restore, and teardown.
