# SeedPacks model rework backup (2026-07-10)

State of `ReplicatedStorage.Assets.Misc.SeedPacks` before agent cleanup for the
new pack model hierarchy (Stroke/Main/Highlight/Highlight2 + contents).

Children at time of edit (in order):

1. `SecretSeedPack` — new style: Stroke 0,0,0 Neon; Main 163,162,165 SmoothPlastic
   (mesh 130233329332089); Highlight 163,162,165 (mesh 95324442690205);
   Highlight2 255,255,255 (mesh 131072210854008); Seeds unions 103,73,65.
2. `EpicSeedPack` — new style, identical geometry/colors to SecretSeedPack.
3. `EpicSeedPack` (DUPLICATE, old authored-static style) — same meshes but
   Main 165,136,62; Highlight 168,123,78; Highlight2 185,152,70. Positioned at
   x=25.58 (others 14.23/19.97/31.05). REMOVED by this edit.
4. `DurianPack` — new style grays/white; contents two `Durian` models
   (Part 116,88,46 + Union 135,135,68).

`SeedPack` (base pack) model was missing entirely — RECREATED by this edit as a
clone of the new-style EpicSeedPack renamed `SeedPack`.

Color change applied to every pack model after this backup:
Main 163,162,165 -> 240,240,240 and Highlight2 -> 255,255,255 (already white on
new-style models). Full JSON property dump captured via MCP is described above;
geometry survives in the remaining models (shared MeshIds listed).
