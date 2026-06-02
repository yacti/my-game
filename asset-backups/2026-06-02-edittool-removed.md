# EditTool Runtime Asset Removed

`ReplicatedStorage.EditTool` was removed from the active runtime asset roots on
2026-06-02 after edit mode moved to the Studio-owned HUD button and
`FeedEditService` server state.

The original Studio instance was not destroyed. It was moved to:

```text
ServerStorage.AssetBackups.EditToolRemoved_2026_06_02.EditTool
```

Verification:

- `AssetValidator` no longer requires `ReplicatedStorage.EditTool`.
- No code grants or watches `EditTool` to enter edit mode.
- Edit mode now uses `ReplicatedStorage.UI.HUD.EditModeButton`.
