Updated: 2026-09-12 CST

Context: Roblox executor script + local MCP bridge so Claude can see the game's object tree and remote events in real time. SimpleSpy hooks remotes; a tree walker serializes the DataModel and POSTs it to the bridge every 30s.

Done:
- ec76879–1b67db0: Full pipeline — bridge.py (zero-dep JSON-RPC stdio MCP), script.lua (SimpleSpy hook + tree walker), claude_desktop_config.json wired, MCP verified live
- Removed DarkDex, replaced with built-in tree walker (depth 4, 80-child cap, 12 services)
- Removed hookmetamethod entirely (was breaking movement/camera via C-level re-entrancy)
- Fixed GUI: CoreGui parent with PlayerGui fallback; no IgnoreGuiInset

- script.lua pushed to aaron1612n-cmd/MoreStuff/main/script.lua
- Loadstring: loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/MoreStuff/main/script.lua"))()

In progress: Nothing mid-flight. Bridge active, tree data flowing.

Next:
- Get remotes flowing (SimpleSpy hook table key may not match — check _G.SimpleSpy after injection and verify which key exists)
- If remote_count stays 0 after firing actions in-game, add a fallback raw __namecall hook scoped only to non-render methods

Key facts/decisions:
- MCP config lives in `C:\Users\ongo9\AppData\Roaming\Claude\claude_desktop_config.json` (desktop app), NOT ~/.claude/settings.json (CLI only)
- bridge.py copy at `C:\Users\ongo9\.claude\roblox_bridge.py` — clean path, no apostrophe. Source of truth is repo bridge.py; keep in sync manually
- Installed `mcp` 2.2.0 is NOT Anthropic's SDK. bridge.py uses zero-dep JSON-RPC 2.0 over stdio — no imports from mcp package
- hookmetamethod on __namecall kills movement on most executors. Never use it here. SimpleSpy's own hook table is the only safe intercept point
- Tree walker skips nodes with >80 children (marks `children_truncated: true`). T key forces immediate resend
- Game observed: flat baseplate map, `rare10` loot folder in Workspace, `01_server` RemoteEvent + `02_client`/`03_client` RemoteFunctions, TopbarPlus UI framework in ReplicatedStorage

Files:
- script.lua — executor script (SimpleSpy + tree walker + status GUI)
- bridge.py — MCP bridge server (HTTP :7821 ingest + stdio MCP)
- bridge.bat — wrapper for clean-path spawn (legacy, claude_desktop_config.json now points to roblox_bridge.py directly)
- C:\Users\ongo9\.claude\roblox_bridge.py — copy of bridge.py at apostrophe-free path

Session name rule: this session's title ends in a version pattern (N.0 / vN) -> bump N by 1; otherwise -> append " 2.0"
