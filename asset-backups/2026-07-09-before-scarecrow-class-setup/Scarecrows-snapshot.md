# Snapshot: ReplicatedStorage.Assets.FeedMachines.Scarecrows

Taken 2026-07-09 via MCP execute_luau before: renaming folder `Scarecrows` → `Scarecrow`
and setting FeedType/FeedClass/JumpSeconds/JumpRadius/Price/ItemRarity attributes on the
three models (which previously had NO attributes). Text snapshot (MCP cannot export
.rbxm); geometry itself was not modified by this change.

```text
Scarecrows [Folder]
  GoldenScarecrow [Model] primary=PrimaryPart pivot=95.6499939, 5.39999676, -148.344894, 1, 0, 0, 0, 1, 0, 0, 0, 1
    PumpkinHead [Model] primary=nil pivot=96.0608826, 8.80367947, -148.282364, 0, 0.25881806, -0.965921879, 0, 0.965921879, 0.25881806, 1, 0, 0
      Body [UnionOperation] size=2.25, 2, 2.25 anchored=true color=0.901961, 0.470588, 0.0941176 material=Plastic
      Part [Part] size=1.6, 1.2, 0.1 anchored=true color=0,0,0 material=Neon
      Union [UnionOperation] size=0.2, 0.733, 0.423 anchored=true color=0.419608, 0.372549, 0.243137 material=SmoothPlastic
    Union [UnionOperation] size=1.5, 3.0, 5.5 anchored=true color=1, 0.6, 0 material=Plastic
    Part [Part] size=0.5, 8.5, 0.5 anchored=true color=0.231373 material=Plastic
    Part [Part] size=0.5, 3.5, 0.5 anchored=true color=0.231373 material=Plastic
    Union [UnionOperation] size=1.5, 3.0, 5.44 anchored=true color=1, 0.768627, 0 material=Plastic
    Part [Part] size=0.5, 0.5, 2 anchored=true color=0.231373 material=Plastic
    PrimaryPart [Part] size=3, 8.8, 8 anchored=true transparency=1
  UpgradedScarecrow [Model] primary=PrimaryPart pivot=95.6499939, 5.39999676, -138.84491 (same 9-part structure; blue/grey palette)
  BasicScarecrow [Model] primary=PrimaryPart pivot=95.9999924, 5.39999676, -128.444916 (same 9-part structure; straw/brown palette)
```

No attributes existed on the folder or any descendant at snapshot time.
Full per-part CFrames are recoverable from Studio history if needed; this change
touched only the folder Name and model attributes.
