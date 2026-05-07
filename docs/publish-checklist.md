# Publish Checklist

Run this checklist before publishing a live build.

## Source And Studio State

- Git working tree is clean.
- Rojo is connected and fully synced.
- `ReplicatedStorage.Remotes` exists exactly once and contains every remote
  declared in `default.project.json`.
- `ReplicatedStorage.Pets` templates contain no baked `ProximityPrompt`s.
- Required Studio-owned assets exist until they are moved into source control:
  `Pets`, `FeedMachines`, `Food`, `UI`, `FeedMachineTool`, and `EditTool`.
- Risky Studio/MCP asset edits have a matching `.rbxm` or `.rbxmx` checkpoint
  under `asset-backups/`.

## Data

- `src/server/PlayerDataService.luau` store policy is intentional:
  `STORE_NAME = "PlayerData"` and Studio uses ProfileStore mock mode by default.
- Fresh ProfileStore profile receives expected default pets/feed tools/currency.
- Server output shows ProfileStore has DataStore access in production test
  environments.
- Leave/rejoin preserves pets, feed machines, feed inventory, food inventory,
  currency, and patch/processor/tree machine state.

## Gameplay Security

- `PlaceFeedMachine` rejects malformed payloads and rate-limits placement.
- `PromptInteract` uses shared action constants, rate limits, and server-side
  ownership/distance/state validation.
- Food XP used by server actions is clamped through server-known food templates.

## Runtime Output

- Join a clean session and confirm no infinite-yield warnings.
- Confirm no missing template warnings for feed machines or food.
- Confirm no duplicate feed type warnings.
- Confirm local prompts show correct per-player context.
