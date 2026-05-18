# Asset Workflow

This project still uses Studio-authored assets for core gameplay templates.
MCP can inspect and edit those live instances, but it is not rollback or source
control. UI is intentionally Studio/MCP-owned in `ReplicatedStorage.UI`; do not
add game UI backups or Rojo mappings under `src/ui`.

## Current Runtime Asset Roots

These live under `ReplicatedStorage` and are required by server/client code:

- `PetModels`
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
    PetModels.rbxm
    FeedMachines.rbxm
    Food.rbxm
    FeedMachineTool.rbxm
    EditTool.rbxm
```

Use `.rbxm` for compact rollback backups. Use `.rbxmx` when human-readable diffs
are more important than file size/noise.

These backups are temporary rollback checkpoints. They are not the final source
of truth.

## Gradual Source Ownership

Move non-UI assets into Rojo/source ownership in small, tested commits:

1. `ReplicatedStorage.FeedMachineTool`
2. `ReplicatedStorage.EditTool`
3. `ReplicatedStorage.PetModels`
4. `ReplicatedStorage.FeedMachines`
5. `ReplicatedStorage.Food`

Avoid migrating everything at once. Complex models can break if pivots,
`PrimaryPart`s, welds, attributes, or tool handles are not preserved.

## Startup Validation

`src/server/AssetValidator.luau` checks required asset roots, templates,
attributes, remotes, tools, UI templates, and plot structure at server startup.
Critical gameplay assets still fail startup when they are missing or malformed.
Studio-owned UI assets warn clearly and the affected UI path skips itself; the
code should not generate fallback UI.
