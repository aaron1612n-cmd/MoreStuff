# invis — runbook

Continuation state for the Delta invisibility work. Keep under ~1.5k tokens; trim oldest detail first.

## Where

- **Current: `roblox/invis_ghost.lua`** (inverted park). Old: `roblox/invis_delta.lua` (superseded, kept for comparison).
- Load: `loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/Claude-Codes/ClaudeMain/roblox/invis_ghost.lua"))()`
- Dev branch: `claude/friendly-hypatia-9zzuzn`. Merged: PRs #19–#28.
- **Working rule: always merge when ready, no confirmation needed.** draft → ready → merge, standing policy.

## Replication model (researched, not guessed)

A client pushes **root assembly CFrame** + Humanoid state + which animations play. Nothing else.

**Physics replicates at 20 Hz** while the client renders at 60. Unreliable, unordered, receiver interpolates at 60 Hz. Anchored parts don't replicate at all.

**Disproven by live testing, do not retry:** `Transparency`/`LocalTransparencyModifier` (server→client only); `Motor6D.Enabled=false` + limb CFrames; `Motor6D.Transform`; `SimulationRadius=0`.

Kill-you gotchas: `Humanoid.RequiresNeck` defaults true. Below `workspace.FallenPartsDestroyHeight` parts are deleted. A Heartbeat CFrame write is a real physical move — restores must carry `AssemblyLinearVelocity`/`AssemblyAngularVelocity`.

## Why v1 (`invis_delta.lua`) only half-worked

Held truth almost the whole frame, wrote the lie in the sliver between Heartbeat and next RenderStepped. That race is phase-locked: the 20 Hz sender samples every ~3rd frame at the same phase. Standing still replicated nothing. Moving jittered the phase, delivering the lie on a fraction of samples → partial delivery → gliding.

## v2 (`invis_ghost.lua`) — inverted park

The root **lives at the lie**; returns to truth only for the physics step.

```
PreSimulation (Stepped)   -> write TRUTH, physics steps from it
[physics]
PostSimulation (Heartbeat) -> capture truth, write LIE
[render + idle + frame boundary — all on the LIE]
```

Local compensation:
- **Camera**: `GhostEye` part pinned at truth, set as `CameraSubject`. Bound at `RenderPriority.First` (0).
- **Own body**: `LocalTransparencyModifier = 1`, bound at `Last` (2000).
- Humanoid Freefall problem gone for free.

Every write carries ±0.03st nudge — identical CFrame = no delta = no packet.

Resync (`R`): lie not written, root holds truth all frame.

## The trade that can't be engineered away

Server thinks you're elsewhere → server-validated hits resolve from elsewhere. Hold `R` is the escape hatch.
