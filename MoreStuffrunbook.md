# MoreStuff Runbook

**Repo:** aaron1612n-cmd/MoreStuff  
**Branch:** claude/relaxed-planck-a561ov  
**Session:** 2026-09-09

## Structure
- `roblox/` — Lua scripts for Roblox exploits/utilities
  - `Desync.lua` — desync script
  - `invis_delta.lua`, `invis_ghost.lua` — invisibility variants
  - `WalkSpeedMultiplier.lua` — multiplies walk speed by configurable value

## WalkSpeedMultiplier.lua
- LocalScript in StarterPlayerScripts
- Set `MULTIPLIER` at top (default 2)
- `BASE_SPEED = 16` (Roblox default)
- Auto-reapplies on respawn

## Notes
- Scripts are client-side LocalScripts unless noted otherwise
- Tests in `roblox/tests/`
