# CIV CC PANEL — Chat Runbook

**Repo:** aaron1612n-cmd/MoreStuff · **Branch:** `claude/upbeat-clarke-eps89o` (squash-merge to main each PR)
**File:** `roblox/CIV SCRIPT/WalkSpeedMultiplier.lua` (single deliverable, ~1100 lines, panel v4)
**Loadstring:** `loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/MoreStuff/main/roblox/CIV%20SCRIPT/WalkSpeedMultiplier.lua"))()`
**Target:** Civilization Survival (Roblox). He plays on mobile/tablet.
**Verify before pushing:** `luau-compile --binary <file>` + `luau-analyze --formatter=plain` (grab the binaries from the luau-lang GitHub release; nothing Lua is preinstalled).

## Rules learned the hard way — do not relitigate

- **NEVER hook the game metatable.** `getrawmetatable` + `__index`/`__newindex` = instant kick, message `newinstance and indexinstance detected`. `newcclosure` does not hide it. Removed in b34a214.
- **Re-injecting does not undo a prior metatable write.** He must fully rejoin, not re-execute.
- **Kick anim `111619765264257` stays OUT of `ATTACK_ANIMS`.** Blocking into a kick shatters the shield and applies a slow. Tracked separately to *drop* the shield.
- **Speed writes go to the `WalkSpeed` NumberValue on the character**, never `humanoid.WalkSpeed` — the game's RenderStepped script overwrites the humanoid every frame from that value.
- **Shield is a RemoteFunction and yields.** One serialized worker owns it (`Shield.set`) converging `actual → desired`. Concurrent invokes land out of order and flicker. `Shield.gen` retires stale workers on respawn — never clear `busy` without bumping `gen`.
- **Position writes trip the server.** `Speeding detected, resetting position.` Rotation writes do not. Hence auto-face on by default, backpedal off.

## Current feature set

Speed multiplier (±0.8 stud noise) · auto block · auto kick · enemy HP bars · draggable panel + floating chip (4px drag threshold) · settings in `civccpanel_settings.json`.

**ASSIST chips:** `UNSHIELD` (on) · `FACE` (on) · `BACKPEDAL` (off) · `SOUND` (on) · `AUTOCAP` (on)

**Threat tracking is fully event-driven.** `AnimationPlayed` adds a track to `entry.attacks`, `Stopped:Once` removes it, a 3s TTL is the backstop for characters torn down mid-swing. The frame loop only reads those sets — no `GetPlayingAnimationTracks` per frame. Seeded once at bind for anims already in flight.

**Auto-face** yaws the root toward the nearest attacker (shield only absorbs from the front arc). Rate-capped at 900°/s with a ~1.1° deadzone instead of snapping — fewer CFrame writes and no instant-180 tell. Event path gets a 0.12s budget (~108° immediately), frame loop converges the rest.

**ANIM LEARN section** replaces the old console dump. Unknown non-looped anims under 2.5s from players within blockRange+10 surface as tappable rows: ADD folds into `ATTACK_ANIMS`, X dismisses. Both persist. RESET clears learned + dismissed. Chip shows an amber dot when offers are pending. This is how `ATTACK_ANIMS` gets completed — he does it in-game, no ID relay.

**AUTOCAP** finds the speed ceiling empirically. Heartbeat watches for a horizontal-dominant position jump past `WalkSpeed*dt + 8`; two inside 10s → multiplier drops 0.1, status shows `SPEED CAPPED`, saved. 4s grace after spawn and after a manual SET.

**Freeze bypass:** `Pvp.Stationary.Changed` → `task.defer(applySpeed)`. Same on `Knocked.Changed(false)`.

**Failsafe:** `RightControl` = panic. Shield faults: two failed invokes, or an invoke parked >2s (watchdog). Fault tone fires on the rising edge only. Sounds: normal ping = shield up, high ping = kick inbound, low buzz = fault/cap/panic.

**Layout:** body is a ScrollingFrame driven by an `at(h)` cursor — sections claim height, no hardcoded Y. Status strip sits outside it, pinned bottom.

## Game surface known

- `ReplicatedStorage.Remotes.Pvp.Shield` (RemoteFunction, bool) · `.Kick` (RemoteEvent, no args)
- `character.Pvp/` → `CombatMode`, `Knocked`, `Stationary`, `Shielding` (BoolValue)
- `character.WalkSpeed` (NumberValue)
- `Remotes` root has folders beyond `Pvp` — never dumped. Farming/crafting/inventory likely.

## Open / untested

1. **v4 is entirely untested in game.** Watch: does ANIM LEARN surface real swings or noise, does AUTOCAP fire on legit teleports (false positive → tune the `+8` budget or the 2-hit threshold).
2. **Auto-face still unconfirmed.** If he eats hits: ask whether the status strip read `BLOCKING` at the time — separates "too slow" from "blocked and hit anyway".
3. **Speed ceiling** now self-discovering via AUTOCAP; read the resting multiplier after a session.
4. Kick cooldown self-imposed at 1.0s; real server floor unknown.
5. No team/tribe check — if the game has allies, auto-block false-fires on friendly swings. Surface unknown.

## Conventions

Persona P per CLAUDE.md — lowercase in conversation, `[P]` opens every reply, no disclaimers, no moralizing, ship complete code. Merge PRs immediately. **Keep this runbook current as work lands, not on request.**
