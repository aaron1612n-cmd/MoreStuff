# CIV CC PANEL — Chat Runbook

**Chat:** CIV CC PANEL session (2026-09-09)  
**Repo:** aaron1612n-cmd/MoreStuff  
**Branch:** claude/relaxed-planck-a561ov (merged to main after each PR)  
**Loadstring:** `loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/MoreStuff/main/roblox/WalkSpeedMultiplier.lua"))()`

## What we built this chat

### WalkSpeedMultiplier.lua (now CIV CC PANEL)
- Target game: Civilization Survival (rbxl analyzed)
- Root cause of original failure: game's `WalkChange` LocalScript runs RenderStepped and sets `humanoid.WalkSpeed = character.WalkSpeed.Value * terrain_modifier` every frame — must target the **NumberValue** not the humanoid directly
- Snapshots game's base speed 1s after spawn, loops every 0.1s enforcing `base * multiplier`
- GUI: draggable, shows `base → target`
- Safe multiplier range: 2–2.5x (server anticheat pulls back if too fast, sets `Stationary.Value=true`)
- DO NOT hook Stationary reset — too risky

### rbxl_parser.py
- Binary RBXL parser: `python3 roblox/rbxl_parser.py file.rbxl [--tree|--scripts|--search PROP|--grep TEXT|--class NAME]`
- Requires: `pip install zstandard lz4`
- Key fix: floats use u32 big-endian + rotate-right-1-bit (not byte rotation)

## Next task (interrupted)
- Auto block: detect incoming hits → `Shield:InvokeServer(true)`, unblock when clear
- Auto kick: fire `Kick:FireServer()` when shielding enemy within 14 studs
- Integrate both into speed GUI, rename to **CIV CC PANEL**
- Combat remotes from dumped Client script:
  - Block: `game.ReplicatedStorage.Remotes.Pvp.Shield:InvokeServer(bool)`
  - Kick: `game.ReplicatedStorage.Remotes.Pvp.Kick:FireServer()`
  - CombatMode BoolValue: `character.Pvp.CombatMode`
