# Asset Backups

Store temporary `.rbxm` / `.rbxmx` rollback checkpoints here before risky Studio
or MCP edits.

Backups should be grouped by date and purpose, for example:

```text
asset-backups/2026-05-07-before-pet-template-cleanup/Pets.rbxm
```

These files are safety snapshots, not the active asset source of truth. Prefer
moving critical assets into Rojo/source-owned paths over time.
