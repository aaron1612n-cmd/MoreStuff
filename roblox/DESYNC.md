# Desync

Client and server disagree about where you are. You walk around normally; the
server is told something else.

## What RakNet is

RakNet is the UDP networking library Roblox's transport layer is built on. Every
multiplayer message — physics updates, remote events, instance replication —
is a RakNet packet with a leading message ID byte.

The IDs that matter here:

| ID | Name | Carries |
| --- | --- | --- |
| `0x83` | `ID_DATA` | general replication (remotes, properties, instances) |
| `0x85` | `ID_PHYSICS` | physics replication — your character's position |
| `0x81` | `ID_SET_GLOBALS` | session globals |

Normally a script sits on top of the engine: you set `HumanoidRootPart.CFrame`
and the engine decides what to transmit. "RakNet access" means the executor has
hooked the transport underneath the engine and exposes it to Lua, so a script
can read, rewrite, drop or forge the packets themselves.

Two API shapes exist in the wild, and they are not compatible:

```lua
-- Velocity-style
raknet.desync(true)                  -- suppress physics replication outright
raknet.block(0x85, true)             -- block a packet ID
raknet.add_send_hook(function(pkt)   -- inspect / rewrite / drop
    if pkt.PacketId == 0x85 then pkt:Block() end
end)

-- Celery-style
rnet.setfilter({ 0x85 })             -- drop packets by leading byte
rnet.sendphysics(cframe)             -- push a position straight to the server
rnet.Capture:Connect(function(p) print(p.id, p.data) end)
```

`rnet.sendphysics` is the interesting one: it hands the server a position
directly, without the engine and without touching your character at all.

### What RakNet does not fix

Dropping physics packets is a cleaner desync than swapping CFrames — nothing
client-side can observe it, and there is no per-frame fight with the engine.
But **it does not solve teleport detection**, which is the thing that actually
gets you caught.

While packets are dropped, the server holds your last known position. The
moment you stop dropping, the next packet carries your real position. The
server's position history reads:

```
anchor, anchor, anchor, ..., anchor, [200 studs away]
```

One frame, enormous delta. Every teleport check is some form of
`magnitude(last, new) / dt > plausible_max`, and that trips it just as hard as
the CFrame method does. RakNet changes *how* the lie is delivered, not the fact
that the lie ends abruptly.

Worth knowing: Roblox shipped improved physics replication in June 2026 with
["eventual consistency to ensure updates aren't lost due to packet drops"](https://devforum.roblox.com/t/upcoming-improvements-to-physics-replication/4675512).
Drop-based desync is being actively hardened against; a method that only works
by discarding packets has a shelf life.

## The rule this implementation is built on

> The position the server sees never jumps, and never moves faster than a
> speed you actually achieved.

`serverCF` is a simulated point that chases a target at a capped speed. It is
written in exactly one place — `chase()` — which is what makes the guarantee
structural rather than incidental. There is no code path that can teleport it,
including switching the script off.

That single rule is what makes this usable where the naive version is not:

- **Teleport detection** has nothing to read. The server only ever sees
  continuous motion at legitimate speeds.
- **Switching off no longer snaps.** Instead of handing the server your real
  position in one frame, `serverCF` walks back to you at running speed and the
  script stops only once it arrives.

### The cap and the leash conflict

An early version used a fixed speed cap plus a maximum gap. Those two rules
contradict each other, and the test suite caught it: if you move faster than
the cap, `serverCF` cannot keep up and the gap grows without bound — 8409 studs
in a 30-second run at 200 studs/s. Which is exactly the distance a snap-back
check measures.

The resolution is that a fixed cap is the wrong invariant. A speed *you
genuinely moved at* is legitimate by construction — the server watching you
travel at it has nothing to flag, because you really did travel that fast. So
the budget is:

```lua
math.clamp(math.max(MaxServerSpeed, observedSpeed * headroom),
           MaxServerSpeed, MaxTrackSpeed)
```

`observedSpeed` is your own low-passed speed. The sample is clamped *before* it
enters the filter, not just after — a game-scripted teleport is one frame of
effectively infinite speed, and without that clamp a single frame drags the
budget to the ceiling on its own (measured: 250 studs/s before the fix, 35
after).

Above `MaxTrackSpeed` the gap is allowed to grow. That is a deliberate trade:
matching an absurd speed to hold the leash would itself be the detectable
event.

## The gap cuts both ways

The server has exactly one position for you. Reach and range checks measure
from *that* position to whatever you are interacting with. So:

> Any gap large enough to protect you from incoming damage breaks your own
> outgoing reach by exactly the same distance.

There is no configuration that avoids this — it is what a single replicated
position means. A game that rejects your attacks with "too far from target" is
measuring from `serverCF`, and the fix is a smaller gap, not a different mode.

`SHADOW` exists for exactly this: a gap small enough to stay inside the game's
interaction range while still being a gap.

## Modes

| Mode | `serverCF` target | Gap | Your reach | Speed signature |
| --- | --- | --- | --- | --- |
| `SHADOW` | rigid offset from your real position | constant, small | intact | none — speed is identically yours |
| `TRAIL` | your own path, `TrailLag` seconds behind | `TrailLag × your speed` | broken past interaction range | none in steady state |
| `ANCHOR` | fixed point where you switched on | grows to `MaxGap` | broken | a catch-up burst when the leash engages |

`SHADOW` is the default.

`TRAIL` replays real history, just late.

`ANCHOR` gives the biggest gap and is the loudest.

## Speed detection

The floor on `serverCF`'s speed is derived from your own `WalkSpeed`, not a
fixed number.

## Transports

Selected automatically at load.

| Transport | Requires | How |
| --- | --- | --- |
| `native` | a packet-drop function **and** `rnet.sendphysics` | suppress `0x85`, push `serverCF` directly. No local CFrame writes at all. |
| `swap` | nothing | the portable fallback |

## Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `Mode` | `SHADOW` | `SHADOW`, `TRAIL` or `ANCHOR` |
| `ShadowOffset` | `(4, 0, 0)` | the rigid offset in `SHADOW` mode |
| `MaxGap` | 60 | the leash, in studs |
| `SpeedFloorFactor` | 1.0 | speed floor as a multiple of your `WalkSpeed` |
| `MinSpeedFloor` | 1 | absolute floor |
| `MaxTrackSpeed` | 250 | hard ceiling |
| `TrailLag` | 1.5 | seconds `TRAIL` runs behind you |
| `ResyncTolerance` | 2 | studs; resync is finished under this |

## Tests

```sh
luau roblox/tests/desync_math.lua
```
