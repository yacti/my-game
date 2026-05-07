# Asset Workflow

This project still uses Studio-authored assets for core gameplay templates.
MCP can inspect and edit those live instances, but it is not rollback or source
control. Before risky Studio or MCP edits, export the affected assets into this
repo so git has a recovery point.

## Current Runtime Asset Roots

These live under `ReplicatedStorage` and are required by server/client code:

- `Pets`
- `FeedMachines`
- `Food`
- `UI`
- `FeedMachineTool`
- `EditTool`

`ReplicatedStorage.Remotes`, `ReplicatedStorage.Shared`, and `ReplicatedStorage.Satchel`
are already declared in `default.project.json`.

## Backup Before Risky Edits

Before deleting, renaming, restructuring, or batch-editing important Studio assets,
export the affected folder/model as `.rbxm` or `.rbxmx` under `asset-backups/`.

Recommended layout:

```text
asset-backups/
  YYYY-MM-DD-before-description/
    Pets.rbxm
    FeedMachines.rbxm
    Food.rbxm
    UI.rbxm
    FeedMachineTool.rbxm
    EditTool.rbxm
```

Use `.rbxm` for compact rollback backups. Use `.rbxmx` when human-readable diffs
are more important than file size/noise.

These backups are temporary rollback checkpoints. They are not the final source
of truth.

## Gradual Source Ownership

Move assets into Rojo/source ownership in small, tested commits:

1. `ReplicatedStorage.UI`
2. `ReplicatedStorage.FeedMachineTool`
3. `ReplicatedStorage.EditTool`
4. `ReplicatedStorage.Pets`
5. `ReplicatedStorage.FeedMachines`
6. `ReplicatedStorage.Food`

Avoid migrating everything at once. Complex models can break if pivots,
`PrimaryPart`s, welds, attributes, or tool handles are not preserved.

## Startup Validation

`src/server/AssetValidator.luau` checks required asset roots, templates,
attributes, remotes, tools, UI templates, and plot structure at server startup.
If Studio state drifts from what the code expects, the game should fail loudly
instead of partially booting.
