# 2026-07-31 — yactiNPC / MagicWand set CanCollide = false

Property-only edit to two Studio-owned templates, applied through MCP in the
Edit datamodel (recorded via `ChangeHistoryService`, so it is undoable in
Studio). No structure, names or hierarchy changed, so no `.rbxm` export.

## Before

`ReplicatedStorage.Assets.Misc.yactiNPC` (20 BaseParts) — `CanCollide = true` on:

- `HumanoidRootPart`
- `UpperTorso`
- `LowerTorso`

`ReplicatedStorage.Assets.Misc.MagicWand` (3 BaseParts) — `CanCollide = true` on:

- `Union`
- `Meshes/stars_Circle`

## After

Every BasePart in both models is `CanCollide = false`.

## Why

Fairy yacti is pure decoration: he tours a player's own farm during the Sprinkle
chaos event and should never block or shove them. The templates are only half
the fix — see the `holdCollisionCleared` comment in
`src/client/ui/SprinkleEventController.luau` for the Humanoid re-enabling limb
collision after the rig is parented, which is what actually made him solid in
game regardless of what the template said.

## To revert

Set `CanCollide = true` on the five parts listed above.
