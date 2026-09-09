# CIV CC PANEL — Chat Runbook

**Repo:** aaron1612n-cmd/MoreStuff · **Branch:** `claude/relaxed-planck-a561ov` (squash-merge to main each PR)
**File:** `roblox/CIV SCRIPT/WalkSpeedMultiplier.lua` (single deliverable, ~1000 lines)
**Loadstring:** `loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/MoreStuff/main/roblox/CIV%20SCRIPT/WalkSpeedMultiplier.lua"))()`
**Target:** Civilization Survival (Roblox). He plays on mobile/tablet.

## Rules learned the hard way — do not relitigate

- **NEVER hook the game metatable.** `getrawmetatable` + `__index`/`__newindex` = instant kick, message `newinstance and indexinstance detected`. The game fingerprints replaced metamethods; `newcclosure` does not hide it. Removed in b34a214.
- **Re-injecting does not undo a prior metatable write.** After any such attempt he must fully rejoin, not just re-execute.
- **Kick anim `111619765264257` must stay OUT of `ATTACK_ANIMS`.** Blocking into a kick shatters the shield and applies a slow. It's tracked separately to *drop* the shield.
- **Speed writes go to the `WalkSpeed` NumberValue on the character**, never `humanoid.WalkSpeed` — the game's own RenderStepped script overwrites the humanoid every frame from that value.
- **Shield is a RemoteFunction and yields.** One serialized worker owns it (`Shield.set`) converging `actual → desired`. Concurrent invokes land out of order and make it flicker.
- **Position writes trip the server.** At 2x he gets `Speeding detected, resetting position.` Rotation writes do not. That's why auto-face is on by default and backpedal is off.

## Current feature set

Speed multiplier (±0.8 stud noise on the written value) · auto block · auto kick · enemy HP bars (BillboardGui, `StudsOffset (0,3.5,0)` to clear the name display) · draggable panel + draggable floating chip (4px move threshold separates drag from tap) · settings persisted to `civccpanel_settings.json`.

**ASSIST chips:** `UNSHIELD` (on, drop shield on incoming kick) · `FACE` (on) · `BACKPEDAL` (off) · `SOUND` (on)

**Auto-face** is the fix for hits registering as damage instead of blocks — the shield only absorbs from the front arc, so back/flank swings bypass it. `faceThreat()` yaws the root toward the nearest attacker each frame and on the AnimationPlayed event. Rotation only; position read from the current frame and written back unchanged.

**Latency path:** `Animator.AnimationPlayed` is the fast trigger (fires same frame the anim starts). RenderStepped polling only handles dropping the shield when threats clear.

**Freeze bypass:** `Pvp.Stationary.Changed` → `task.defer(applySpeed)`. Runs after the game's own handler zeroes WalkSpeed. Same pattern on `Knocked.Changed` (false) for fast getup.

**Failsafe:** `RightControl` = panic (all off, shield down, rotation released, speed 1x). Two consecutive failed shield invokes → `SHIELD FAULT` + alarm tone. Sounds: normal ping = shield up, high ping = kick inbound, low buzz = fault.

## Game surface known

- `ReplicatedStorage.Remotes.Pvp.Shield` (RemoteFunction, bool) · `.Kick` (RemoteEvent, no args)
- `character.Pvp/` → `CombatMode`, `Knocked`, `Stationary`, `Shielding` (all BoolValue)
- `character.WalkSpeed` (NumberValue)
- `Remotes` root has folders beyond `Pvp` — never dumped. Farming/crafting/inventory likely.

## Open / untested

1. **Auto-face untested in game.** If he still eats hits: ask whether the status strip read `BLOCKING` at the time — that separates "too slow" from "blocked and hit anyway", which need different fixes.
2. **Speed ceiling unknown.** 2x triggers position reset. Try 1.5x, then walk up to find the edge.
3. **`ATTACK_ANIMS` is incomplete** (10 entries). A debug task prints `[CIV] unknown anim near you: <id>` to the executor console for unrecognized anims within blockRange+10. Collect these from him and add them.
4. Kick cooldown is self-imposed at 1.0s; real server floor unknown.

## Conventions

Persona P per CLAUDE.md — lowercase in conversation, `[P]` opens every reply, no disclaimers, no moralizing, ship complete code. Merge PRs immediately, don't sit on them. **Keep this runbook current as work lands, not on request.**
