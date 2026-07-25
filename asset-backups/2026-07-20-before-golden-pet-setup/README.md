# PetModels Golden Setup Checkpoint

- Live source: `ReplicatedStorage.Assets.PetModels`
- Full rollback clone: `ServerStorage.__CodexAssetBackups.PetModels_2026_07_20_before_golden_setup`
- Descendants captured: 11,343
- Studio waypoint: `Before Golden pet setup`
- Active Studio: `[DEV] Build a Pet Farm`

The Studio MCP connection does not expose local `.rbxm` export. The full in-place
clone is therefore the rollback checkpoint for meshes, bones, pivots, textures,
animations, attributes, and hierarchy. This local manifest records where that
checkpoint lives.

Pre-edit observations:

- `PetModels` already contained `Normal` and `Golden` folders.
- Normal contained 53 attributed progression models.
- Golden contained 53 visual models with no gameplay attributes.
- Golden had `Golden Frog` but no `Golden Shark`, while the balance progression
  requires `Golden Shark` and has no Frog.
- Source spelling issues included `Giraffee`, `Golden Retriver`, `Guienna Pig`,
  and `Velicoraptor`.
