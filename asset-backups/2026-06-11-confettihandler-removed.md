# ConfettiHandler Workspace Module Removed

`Workspace.ConfettiHandler` (a client-side confetti ModuleScript prototyped in
Studio) was removed from Workspace on 2026-06-11 after being ported into
source as `src/client/ui/ConfettiEffect.luau`.

The original Studio instance was not destroyed. It was moved to:

```text
ServerStorage.AssetBackups.ConfettiHandlerRemoved_2026_06_11.ConfettiHandler
```

Differences in the ported version (rulebook conformance; visuals preserved):

- One shared `RenderStepped` connection simulates all pieces instead of one
  connection per piece (the original spawned ~250 connections per burst).
- The `ConfettiGui` ScreenGui and the celebration sound are created lazily once
  and reused; the original looked up `ConfettiScreenGui` but created
  `ConfettiGui`, leaking a new ScreenGui per emit.
- No busy-wait on sound load; a 600-piece active cap bounds worst-case bursts.
- Module-level API (`ConfettiEffect.Emit(amount?, spawnPos?)`) instead of the
  unused OOP wrapper.

Consumer: `PetEvolutionEffects` emits a burst for the owner when the morph
reveal lands (as the evolution camera zoom restores).
