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
- Confirm cosmetic templates under `ReplicatedStorage.Assets.Cosmetics` have
  unique `CosmeticID` attributes and model `PrimaryPart`s.
- Confirm `ReplicatedStorage.UI.RollBillboardGUI` has `Seed` and `Misc`
  billboard templates with the expected text labels.
- Confirm local prompts show correct per-player context.
- Equip the shovel, click a placed plant, confirm through `YesNoWarning`, and
  verify the plant deletes, saves, and does not delete processors or other plots.
