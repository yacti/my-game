# Asset Workflow

This project still uses Studio-authored assets for core gameplay templates.
MCP can inspect and edit those live instances, but it is not rollback or source
control. UI is intentionally Studio/MCP-owned in `ReplicatedStorage.UI`; do not
add game UI backups or Rojo mappings under `src/ui`.

## Current Runtime Asset Roots

These gameplay assets live under `ReplicatedStorage.Assets` and are required by server/client code:

- `ReplicatedStorage.Assets.PetModels`
- `ReplicatedStorage.Assets.FeedMachines`
- `ReplicatedStorage.Assets.Food`
- `ReplicatedStorage.Assets.Crates`
- `ReplicatedStorage.Assets.FeedMachineTool`
- `ReplicatedStorage.Assets.SeedTool`
- `ReplicatedStorage.Assets.Shovel`
- `ReplicatedStorage.Assets.Seeds`
- `ReplicatedStorage.Assets.Misc` (`PlotTemplate`, `Sapling`, `Clouds`, roll rewards such as `Brick`)
- `ReplicatedStorage.Assets.VFX` (`RarityParticle`)
- `ReplicatedStorage.UI`

`ReplicatedStorage.Remotes`, `ReplicatedStorage.Shared`, and `ReplicatedStorage.Satchel`
are already declared in `default.project.json`.

Studio also owns `Workspace.PlotTemplates`, the numbered loading pads used by
`src/server/PlotLoader.luau` to spawn runtime `Workspace.Plots` from
`ReplicatedStorage.Assets.Misc.PlotTemplate` on server startup.

## Backup Before Risky Edits

Before deleting, renaming, restructuring, or batch-editing important Studio assets,
export the affected folder/model as `.rbxm` or `.rbxmx` under `asset-backups/`.

Recommended layout:

```text
asset-backups/
  YYYY-MM-DD-before-description/
    PetModels.rbxm
    FeedMachines.rbxm
    Food.rbxm
    FeedMachineTool.rbxm
    SeedTool.rbxm
    Shovel.rbxm
    Seeds.rbxm
    Misc.rbxm
    Workspace-PlotTemplates.rbxm
    VFX.rbxm
```

Use `.rbxm` for compact rollback backups. Use `.rbxmx` when human-readable diffs
are more important than file size/noise.

These backups are temporary rollback checkpoints. They are not the final source
of truth.

## Gradual Source Ownership

Move non-UI assets into Rojo/source ownership in small, tested commits:

1. `ReplicatedStorage.Assets.FeedMachineTool`
2. `ReplicatedStorage.Assets.PetModels`
3. `ReplicatedStorage.Assets.FeedMachines`
4. `ReplicatedStorage.Assets.Food`

Avoid migrating everything at once. Complex models can break if pivots,
`PrimaryPart`s, welds, attributes, or tool handles are not preserved.

## Startup Validation

`src/server/AssetValidator.luau` checks required asset roots, templates,
attributes, remotes, crates, tools, UI templates, roll areas, the plot template,
numbered plot loading pads, and generated runtime plot structure at server startup.
Seed templates used by crate rolls must include valid `RollChanceN`, `Price`,
`GrowTime`, and `FeedType` attributes; `Rarity` is display-only when present.
Misc templates enter the roll pool only when they carry `MiscID`, and must then
also include valid `RollChanceN`, `Price`, and optional display `Rarity`.
Feed-machine templates should not duplicate seed-owned roll/economy/growth
attributes.
Critical gameplay assets still fail startup when they are missing or malformed.
Studio-owned UI assets warn clearly and the affected UI path skips itself; the
code should not generate fallback UI.
Roll reveal billboards are Studio-owned under `ReplicatedStorage.UI.RollBillboardGUI`
with `Seed` and `Misc` `BillboardGui` templates.
