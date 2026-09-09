--[[
    CIV CC PANEL
    Civilization Survival — speed control, auto block, auto kick.
    LocalScript / executor loadstring.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local SoundService      = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local pvpRemotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Pvp")
local shieldRem  = pvpRemotes:WaitForChild("Shield")
local kickRem    = pvpRemotes:WaitForChild("Kick")

-- ═══ Config ════════════════════════════════════════════════════════════════

local Config = {
    speedMultiplier = 2,
    autoBlock       = false,
    autoKick        = false,
    autoUnshield    = true,
    autoFace        = true,
    autoCap         = true,
    backpedal       = false,
    sounds          = true,
    blockRange      = 18,
    kickRange       = 14,
    kickCooldown    = 1.0,
    learnedAnims    = {},
    dismissedAnims  = {},
    keyPanel        = Enum.KeyCode.RightShift,
    keyBlock        = Enum.KeyCode.B,
    keyKick         = Enum.KeyCode.K,
    keyPanic        = Enum.KeyCode.RightControl,
}

local SETTINGS_PATH = "civccpanel_settings.json"

local function saveSettings()
    pcall(function()
        writefile(SETTINGS_PATH, game:GetService("HttpService"):JSONEncode({
            speedMultiplier = Config.speedMultiplier,
            blockRange      = Config.blockRange,
            kickRange       = Config.kickRange,
            autoUnshield    = Config.autoUnshield,
            autoFace        = Config.autoFace,
            autoCap         = Config.autoCap,
            backpedal       = Config.backpedal,
            sounds          = Config.sounds,
            learnedAnims    = Config.learnedAnims,
            dismissedAnims  = Config.dismissedAnims,
        }))
    end)
end

local function loadSettings()
    pcall(function()
        local raw = readfile(SETTINGS_PATH)
        local data = game:GetService("HttpService"):JSONDecode(raw)
        for k, v in pairs(data) do
            if Config[k] ~= nil and type(v) == type(Config[k]) then Config[k] = v end
        end
    end)
end

loadSettings()

-- ═══ Audio cues ════════════════════════════════════════════════════════════
-- Two engine-shipped sounds, pitch-shifted into three distinct tones. Parented
-- to SoundService so they play non-positionally and survive respawns.

local Sfx = {}
do
    local function mk(id, vol, speed)
        local s = Instance.new("Sound")
        s.SoundId       = id
        s.Volume        = vol
        s.PlaybackSpeed = speed
        s.Parent        = SoundService
        return s
    end

    local tones = {
        up   = mk("rbxasset://sounds/electronicpingshort.wav", 0.45, 1.0),  -- shield raised
        warn = mk("rbxasset://sounds/electronicpingshort.wav", 0.60, 1.7),  -- kick inbound
        fail = mk("rbxasset://sounds/switch.wav",              0.85, 0.65), -- fault / cap / panic
    }

    function Sfx.play(which)
        if not Config.sounds then return end
        local s = tones[which]
        if s then pcall(function() s:Play() end) end
    end
end

-- Attack animations (dumped from the place file). Kick is deliberately absent —
-- it shatters shields, so blocking into one is worse than eating it.
local ATTACK_ANIMS = {
    [97045948973922]  = true, -- SwordAttack1
    [100810292084443] = true, -- SwordAttack2
    [114143927519589] = true, -- SwordAttack3
    [129735633773191] = true, -- SpearAttack
    [94870385489834]  = true, -- SpearAttack2
    [129328921806355] = true, -- ClubAttack1
    [130993962519937] = true, -- ClubAttack2
    [71003966899873]  = true, -- SmallSwing
    [77833157080982]  = true, -- MediumSwing
    [111120820640543] = true, -- SickleSwing
}

-- Kick anim ID tracked separately — if enemy kicks while we're blocking, drop
-- the shield immediately so we don't eat the slow.
local KICK_ANIM_ID = 111619765264257

-- Anims he taught the panel in-game, and ones he waved off. Both persist, so a
-- rejoin doesn't re-ask about the same idle loop.
local DISMISSED = {}
for _, id in ipairs(Config.learnedAnims)   do ATTACK_ANIMS[id] = true end
for _, id in ipairs(Config.dismissedAnims) do DISMISSED[id]    = true end

local pendingAnims   = {}   -- unknown ids awaiting a verdict, newest first, max 3
local offeredAnims   = {}   -- [id] = true, already sitting in the queue
local refreshAnimRows       -- assigned once the GUI exists

-- ═══ Local character state ═════════════════════════════════════════════════

local Me = {
    char       = nil,
    humanoid   = nil,
    root       = nil,
    speedVal   = nil,
    combat     = nil,
    knocked    = nil,
    stationary = nil,
    baseSpeed  = nil,
}

local function inCombat()  return Me.combat  and Me.combat.Value  or false end
local function isKnocked() return Me.knocked and Me.knocked.Value or false end
local function alive()     return Me.humanoid and Me.humanoid.Health > 0 end

-- ═══ Facing ════════════════════════════════════════════════════════════════
-- The shield only absorbs from the front arc. A swing that connects with our
-- back or flank bypasses it entirely, which is why blocks "register" as damage.
-- Rotation-only: the position component is carried through untouched, so
-- nothing here produces displacement for the server to reject.
--
-- Turn rate is capped rather than snapped. Two reasons: an instant 180 is the
-- single most obvious tell to anyone watching, and a snap rewrites the CFrame
-- every frame even when we are already on target. Below the deadzone we write
-- nothing at all.

local TURN_RATE  = math.rad(900)   -- radians/sec ceiling
local FACE_DEAD  = 0.02            -- ~1.1 deg, close enough to skip the write
local rotationHeld = false

local function faceThreat(root, budget)
    if not (Me.root and Me.humanoid and root and root.Parent) then return end
    local myPos = Me.root.Position
    local tp    = root.Position
    local dx, dz = tp.X - myPos.X, tp.Z - myPos.Z
    if dx * dx + dz * dz < 0.01 then return end

    -- Roblox forward is -Z, so a pure yaw t has LookVector (-sin t, 0, -cos t)
    local want = math.atan2(-dx, -dz)
    local _, cur = Me.root.CFrame:ToEulerAnglesYXZ()
    local delta = (want - cur + math.pi) % (math.pi * 2) - math.pi
    if math.abs(delta) < FACE_DEAD then return end

    if not rotationHeld then
        Me.humanoid.AutoRotate = false
        rotationHeld = true
    end
    local cap  = TURN_RATE * budget
    local step = math.clamp(delta, -cap, cap)
    Me.root.CFrame = CFrame.new(myPos) * CFrame.fromEulerAnglesYXZ(0, cur + step, 0)
end

local function releaseRotation()
    if not rotationHeld then return end
    rotationHeld = false
    if Me.humanoid then Me.humanoid.AutoRotate = true end
end

-- ═══ Shield driver ═════════════════════════════════════════════════════════
-- Shield is a RemoteFunction: InvokeServer yields. Firing it from multiple
-- places lets calls overlap and land out of order, which is what made the
-- shield flicker. One worker owns the remote and converges actual -> desired.

-- `gen` retires workers across a respawn. An InvokeServer that never returns
-- would otherwise hold `busy` forever, and clearing `busy` on its own would let
-- a second worker start alongside the parked one — which is the overlap that
-- made the shield flicker in the first place.
local Shield = { desired = false, actual = false, busy = false, faulted = false, since = 0, gen = 0 }

function Shield.set(state)
    Shield.desired = state
    if Shield.busy or Shield.actual == Shield.desired then return end
    Shield.busy = true
    local myGen = Shield.gen
    task.spawn(function()
        local fails = 0
        while Shield.gen == myGen and Shield.actual ~= Shield.desired do
            local target = Shield.desired
            local sent   = tick()
            Shield.since = sent
            local ok = pcall(function() shieldRem:InvokeServer(target) end)
            if Shield.gen ~= myGen then return end
            if ok then
                Shield.actual  = target
                Shield.faulted = false
                fails = 0
                -- A raise that took longer than a swing windup is a miss, not a block
                if target and tick() - sent < 0.25 then Sfx.play("up") end
            else
                fails += 1
                if fails == 2 then Shield.faulted = true end
                task.wait(0.1)
            end
        end
        if Shield.gen == myGen then Shield.busy = false end
    end)
end

-- ═══ Enemy animator registry ═══════════════════════════════════════════════
-- Rebuilt on spawn rather than searched every frame.

local Enemies = {}          -- [Player] = { char, root, animator, shielding, humanoid, hpFill, attacks, kicks }
local trackCache = setmetatable({}, { __mode = "k" })  -- [AnimationTrack] = trackId

local function getTrackId(track)
    local cached = trackCache[track]
    if cached ~= nil then return cached end
    local id = 0
    pcall(function()
        id = tonumber(track.Animation.AnimationId:match("(%d+)%s*$")) or 0
    end)
    trackCache[track] = id
    return id
end

local function makeHPBar(char)
    local head = char:FindFirstChild("Head")
    if not head then return nil end
    local bb = Instance.new("BillboardGui")
    bb.Name              = "CivHPBar"
    bb.Size              = UDim2.fromOffset(90, 8)
    -- StudsOffset (0, 3.5, 0) relative to Head clears the default name display
    bb.StudsOffset       = Vector3.new(0, 3.5, 0)
    bb.MaxDistance       = 60
    bb.AlwaysOnTop       = false
    bb.ResetOnSpawn      = false
    bb.Adornee           = head
    bb.Parent            = char  -- parented to char so it cleans up with the character

    local bg = Instance.new("Frame")
    bg.Size              = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3  = Color3.fromRGB(16, 16, 20)
    bg.BorderSizePixel   = 1
    bg.BorderColor3      = Color3.fromRGB(36, 38, 50)
    bg.Parent            = bb

    local fill = Instance.new("Frame")
    fill.Size            = UDim2.new(1, 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(0, 210, 90)
    fill.BorderSizePixel = 0
    fill.Parent          = bg

    return fill
end

-- An anim worth asking about is short and one-shot. Idles, walks and runs are
-- looped, which is what kept the old console dump drowning in noise.
local function isCandidate(track, id)
    if id == 0 or ATTACK_ANIMS[id] or id == KICK_ANIM_ID then return false end
    if DISMISSED[id] or offeredAnims[id] then return false end
    local ok, looped = pcall(function() return track.Looped end)
    if not ok or looped then return false end
    local okLen, len = pcall(function() return track.Length end)
    return okLen and len < 2.5
end

local function offerAnim(id)
    offeredAnims[id] = true
    table.insert(pendingAnims, 1, id)
    pendingAnims[4] = nil
    if refreshAnimRows then refreshAnimRows() end
end

-- Attack tracks carry an expiry as a backstop: Stopped normally clears them,
-- but a character torn down mid-swing never fires it.
local TRACK_TTL = 3

local function bindEnemyChar(p, char)
    if not char then return end
    local entry = { char = char, attacks = {}, kicks = {} }
    Enemies[p] = entry

    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        if not hum or Enemies[p] ~= entry then return end
        entry.humanoid = hum
        entry.animator = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)
        entry.root     = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 5)
        local pvpFolder = char:WaitForChild("Pvp", 10)
        if pvpFolder and Enemies[p] == entry then
            entry.shielding = pvpFolder:FindFirstChild("Shielding")
        end
        entry.hpFill = makeHPBar(char)
        if not entry.animator then return end

        -- Anything already mid-swing when we bind never fires AnimationPlayed
        -- for us, so seed the set once here.
        local ok, tracks = pcall(entry.animator.GetPlayingAnimationTracks, entry.animator)
        if ok then
            for _, track in ipairs(tracks) do
                local id = getTrackId(track)
                if ATTACK_ANIMS[id] then entry.attacks[track] = tick() + TRACK_TTL end
            end
        end

        -- AnimationPlayed fires in the same frame the anim starts, and Stopped
        -- fires the frame it ends. Both edges are events, so the frame loop
        -- never has to ask the animator what is playing.
        entry.animConn = entry.animator.AnimationPlayed:Connect(function(track)
            local id = getTrackId(track)
            local isAttack = ATTACK_ANIMS[id] == true
            local isKick   = id == KICK_ANIM_ID

            if isAttack then
                entry.attacks[track] = tick() + TRACK_TTL
                track.Stopped:Once(function() entry.attacks[track] = nil end)
            elseif isKick then
                entry.kicks[track] = tick() + TRACK_TTL
                track.Stopped:Once(function() entry.kicks[track] = nil end)
            end

            if not (entry.root and Me.root) then return end
            local dist = (entry.root.Position - Me.root.Position).Magnitude

            if not (isAttack or isKick) then
                if dist <= Config.blockRange + 10 and isCandidate(track, id) then
                    offerAnim(id)
                end
                return
            end

            if not Config.autoBlock or not alive() or isKnocked() then return end
            if isAttack and dist <= Config.blockRange then
                if Config.autoFace then faceThreat(entry.root, 0.12) end
                Shield.set(true)
            elseif isKick and dist <= Config.kickRange + 4 then
                Sfx.play("warn")
                if Config.autoUnshield and Shield.actual then Shield.set(false) end
            end
        end)
    end)
end

local function trackPlayer(p)
    if p == player then return end
    if p.Character then bindEnemyChar(p, p.Character) end
    p.CharacterAdded:Connect(function(char) bindEnemyChar(p, char) end)
    p.CharacterRemoving:Connect(function()
        local e = Enemies[p]
        if e and e.animConn then e.animConn:Disconnect() end
        Enemies[p] = nil
    end)
end

for _, p in ipairs(Players:GetPlayers()) do trackPlayer(p) end
Players.PlayerAdded:Connect(trackPlayer)
Players.PlayerRemoving:Connect(function(p)
    local e = Enemies[p]
    if e and e.animConn then e.animConn:Disconnect() end
    Enemies[p] = nil
end)

-- ═══ Local character binding ═══════════════════════════════════════════════

local speedConn

-- Position-yank guard. The server answers an over-speed with
-- `Speeding detected, resetting position.` — a hard horizontal snap we did not
-- ask for. Two of those inside ten seconds and the multiplier walks itself
-- down, which is how the real ceiling gets found without guessing at it.
local Guard = { last = nil, hits = {}, cappedAt = 0, graceUntil = 0 }

local function applySpeed()
    if not Me.baseSpeed then return end
    -- ±0.8 stud noise so the value is never a clean round number on the wire
    local noise = (math.random() - 0.5) * 1.6
    local target = Me.baseSpeed * Config.speedMultiplier + noise
    if Me.speedVal then
        if math.abs(Me.speedVal.Value - target) > 0.8 then
            Me.lastWrite = target
            Me.speedVal.Value = target
        end
    elseif Me.humanoid then
        Me.humanoid.WalkSpeed = target
    end
end

local speedBox   -- forward declared: the guard rewrites the field on a throttle

local function throttleSpeed()
    local next = math.max(1, math.floor((Config.speedMultiplier - 0.1) * 10 + 0.5) / 10)
    if next == Config.speedMultiplier then return end
    Config.speedMultiplier = next
    if speedBox then speedBox.Text = tostring(next) end
    Guard.cappedAt = tick()
    Guard.graceUntil = tick() + 3
    table.clear(Guard.hits)
    applySpeed()
    saveSettings()
    Sfx.play("fail")
end

local function bindCharacter(char)
    Me.char       = char
    Me.humanoid   = nil
    Me.root       = nil
    Me.speedVal   = nil
    Me.combat     = nil
    Me.knocked    = nil
    Me.stationary = nil
    Me.baseSpeed  = nil
    Me.lastWrite  = nil
    Shield.actual  = false
    Shield.desired = false
    Shield.faulted = false
    Shield.gen    += 1       -- retires any worker still parked on the old character
    Shield.busy    = false
    rotationHeld   = false   -- new humanoid, old AutoRotate lock is meaningless

    Guard.last       = nil
    Guard.graceUntil = tick() + 4   -- spawn drop and load-in teleports are not yanks
    table.clear(Guard.hits)

    if speedConn then speedConn:Disconnect(); speedConn = nil end

    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        if Me.char ~= char then return end
        Me.humanoid = hum
        Me.root     = char:WaitForChild("HumanoidRootPart", 10)

        local pvpFolder = char:WaitForChild("Pvp", 10)
        if pvpFolder and Me.char == char then
            Me.combat     = pvpFolder:FindFirstChild("CombatMode")
            Me.knocked    = pvpFolder:FindFirstChild("Knocked")
            Me.stationary = pvpFolder:FindFirstChild("Stationary")
            if Me.stationary then
                Me.stationary.Changed:Connect(function(v)
                    if v and Me.char == char then task.defer(applySpeed) end
                end)
            end
            if Me.knocked then
                Me.knocked.Changed:Connect(function(v)
                    if not v and Me.char == char then task.defer(applySpeed) end
                end)
            end
        end

        -- The game writes character.WalkSpeed (NumberValue) and a RenderStepped
        -- script pushes it into humanoid.WalkSpeed. Tracking the game's writes
        -- keeps the multiplier correct as gear and terrain change the base,
        -- instead of freezing whatever it happened to be at spawn.
        local wsVal = char:WaitForChild("WalkSpeed", 10)
        if wsVal and Me.char == char then
            Me.speedVal  = wsVal
            Me.baseSpeed = wsVal.Value > 0 and wsVal.Value or 16
            speedConn = wsVal.Changed:Connect(function(v)
                if Me.lastWrite and math.abs(v - Me.lastWrite) < 0.01 then return end
                if v > 0 then Me.baseSpeed = v end
                applySpeed()
            end)
        elseif Me.char == char then
            Me.baseSpeed = (hum and hum.WalkSpeed > 0) and hum.WalkSpeed or 16
        end

        applySpeed()
    end)
end

if player.Character then bindCharacter(player.Character) end
player.CharacterAdded:Connect(bindCharacter)

task.spawn(function()
    while task.wait(0.25) do applySpeed() end
end)

RunService.Heartbeat:Connect(function(dt)
    local root = Me.root
    if not (root and root.Parent and alive()) or isKnocked() then
        Guard.last = nil
        return
    end
    local pos  = root.Position
    local prev = Guard.last
    Guard.last = pos
    if not prev or tick() < Guard.graceUntil then return end
    if not Config.autoCap or Config.speedMultiplier <= 1 then return end

    local d     = pos - prev
    local horiz = Vector3.new(d.X, 0, d.Z).Magnitude
    -- A correction is horizontal and far past anything our speed could cover.
    -- Falls and jumps are vertical-dominant, so they never qualify.
    local budget = (Me.speedVal and Me.speedVal.Value or 16) * dt + 8
    if horiz <= budget or horiz <= math.abs(d.Y) * 1.5 then return end

    local now = tick()
    local kept = {}
    for _, t in ipairs(Guard.hits) do
        if now - t < 10 then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = now
    Guard.hits = kept
    if #kept >= 2 then throttleSpeed() end
end)

-- ═══ Auto block ════════════════════════════════════════════════════════════
-- Runs on RenderStepped over the live attack sets maintained by the animator
-- events. Desired shield state is derived from scratch every frame, so nothing
-- accumulates and there is no counter to drift out of sync.

local threatCount = 0
local threatRoot  = nil   -- root of the closest enemy currently mid-attack

RunService.RenderStepped:Connect(function(dt)
    if not Config.autoBlock or not alive() or isKnocked() or not Me.root then
        threatCount = 0
        threatRoot  = nil
        releaseRotation()
        Shield.set(false)
        return
    end

    local myPos = Me.root.Position
    local now   = tick()
    local threats = 0
    local nearest, nearestDist = nil, math.huge
    local incomingKick, kickRoot = false, nil

    for _, e in pairs(Enemies) do
        local root = e.root
        if root and root.Parent then
            local dist = (root.Position - myPos).Magnitude

            if dist <= Config.blockRange then
                local hot = false
                for track, expiry in pairs(e.attacks) do
                    if now > expiry or not track.IsPlaying then
                        e.attacks[track] = nil
                    else
                        hot = true
                    end
                end
                if hot then
                    threats += 1
                    if dist < nearestDist then nearest, nearestDist = root, dist end
                end
            end

            if dist <= Config.kickRange + 4 then
                for track, expiry in pairs(e.kicks) do
                    if now > expiry or not track.IsPlaying then
                        e.kicks[track] = nil
                    else
                        incomingKick, kickRoot = true, root
                    end
                end
            end
        end
    end

    threatCount = threats
    threatRoot  = nearest or kickRoot

    -- Turn into whatever is threatening us, kick included — facing a kicker is
    -- still better than eating it sideways.
    if Config.autoFace and threatRoot then
        faceThreat(threatRoot, dt)
    else
        releaseRotation()
    end

    if incomingKick and Config.autoUnshield and Shield.actual then
        Shield.set(false)
    else
        Shield.set(threats > 0)
    end
end)

-- Backpedal runs on Heartbeat so it lands after the control scripts have set
-- their move vector for the frame. Off by default: this writes displacement.
RunService.Heartbeat:Connect(function()
    if not Config.backpedal or not Config.autoBlock then return end
    if not threatRoot or not threatRoot.Parent then return end
    if not alive() or isKnocked() or not (Me.root and Me.humanoid) then return end
    local away = Me.root.Position - threatRoot.Position
    away = Vector3.new(away.X, 0, away.Z)
    if away.Magnitude < 0.1 then return end
    Me.humanoid:Move(away.Unit, false)
end)

-- ═══ Auto kick ═════════════════════════════════════════════════════════════

local lastKick = 0

task.spawn(function()
    while task.wait(0.1) do
        if not Config.autoKick then continue end
        if not alive() or isKnocked() or not inCombat() or not Me.root then continue end
        if tick() - lastKick < Config.kickCooldown then continue end

        local myPos = Me.root.Position
        for _, e in pairs(Enemies) do
            local root, shielding = e.root, e.shielding
            if root and root.Parent and shielding and shielding.Value then
                if (root.Position - myPos).Magnitude <= Config.kickRange then
                    lastKick = tick()
                    pcall(function() kickRem:FireServer() end)
                    break
                end
            end
        end
    end
end)

-- ═══ GUI ═══════════════════════════════════════════════════════════════════

local PANEL_W, PANEL_H = 256, 480

local COL = {
    bg      = Color3.fromRGB(8, 9, 12),
    bar     = Color3.fromRGB(14, 15, 20),
    field   = Color3.fromRGB(24, 25, 33),
    on      = Color3.fromRGB(0, 210, 90),
    accent  = Color3.fromRGB(255, 138, 0),
    text    = Color3.fromRGB(245, 245, 248),
    dim     = Color3.fromRGB(108, 110, 122),
    line    = Color3.fromRGB(36, 38, 50),
    alert   = Color3.fromRGB(255, 50, 50),
}

local screen = Instance.new("ScreenGui")
screen.Name           = "CivCCPanel"
screen.ResetOnSpawn   = false
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder   = 2147483647

local function parentGui()
    local target = playerGui
    pcall(function()
        local hidden = (typeof(gethui) == "function") and gethui() or CoreGui
        if hidden then target = hidden end
    end)
    local ok = pcall(function() screen.Parent = target end)
    if not ok then pcall(function() screen.Parent = playerGui end) end
end
parentGui()

-- 1px border wrapper gives sharp square outline without UIStroke quirks
local border = Instance.new("Frame")
border.Size             = UDim2.fromOffset(PANEL_W + 2, PANEL_H + 2)
border.Position         = UDim2.new(0, 23, 0.5, -(PANEL_H / 2) - 1)
border.BackgroundColor3 = COL.line
border.BorderSizePixel  = 0
border.Active           = true
border.Parent           = screen

local frame = Instance.new("Frame")
frame.Size             = UDim2.new(1, -2, 1, -2)
frame.Position         = UDim2.fromOffset(1, 1)
frame.BackgroundColor3 = COL.bg
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Parent           = border

-- Left accent stripe (3px, tracks frame height via Scale)
local stripe = Instance.new("Frame")
stripe.Size             = UDim2.new(0, 3, 1, 0)
stripe.BackgroundColor3 = COL.accent
stripe.BorderSizePixel  = 0
stripe.Parent           = frame

-- Title bar ---------------------------------------------------------------
local titleBar = Instance.new("Frame")
titleBar.Size             = UDim2.new(1, 0, 0, 38)
titleBar.BackgroundColor3 = COL.bar
titleBar.BorderSizePixel  = 0
titleBar.Parent           = frame

-- 1px amber bottom separator on the title bar
local titleSep = Instance.new("Frame")
titleSep.Size             = UDim2.new(1, 0, 0, 1)
titleSep.Position         = UDim2.new(0, 0, 1, -1)
titleSep.BackgroundColor3 = COL.accent
titleSep.BorderSizePixel  = 0
titleSep.Parent           = titleBar

local title = Instance.new("TextLabel")
title.Size                   = UDim2.new(1, -88, 1, 0)
title.Position               = UDim2.fromOffset(14, 0)
title.BackgroundTransparency = 1
title.Text                   = "CIV CC PANEL"
title.TextColor3             = COL.accent
title.Font                   = Enum.Font.GothamBold
title.TextSize               = 13
title.TextXAlignment         = Enum.TextXAlignment.Left
title.Parent                 = titleBar

local verLabel = Instance.new("TextLabel")
verLabel.Size                   = UDim2.fromOffset(28, 14)
verLabel.Position               = UDim2.new(1, -36, 0.5, -7)
verLabel.BackgroundTransparency = 1
verLabel.Text                   = "v4"
verLabel.TextColor3             = COL.dim
verLabel.Font                   = Enum.Font.GothamBold
verLabel.TextSize               = 10
verLabel.TextXAlignment         = Enum.TextXAlignment.Right
verLabel.Parent                 = titleBar

-- Body --------------------------------------------------------------------
-- Scrolls, so sections can grow without the panel outgrowing a tablet screen.
-- Offset by 3px on the left to clear the accent stripe; the status strip lives
-- outside it, pinned to the bottom, so it never scrolls out of view.
local body = Instance.new("ScrollingFrame")
body.Size                   = UDim2.new(1, -3, 1, -84)
body.Position               = UDim2.fromOffset(3, 38)
body.BackgroundTransparency = 1
body.BorderSizePixel        = 0
body.ScrollBarThickness     = 3
body.ScrollBarImageColor3   = COL.line
body.ScrollingDirection     = Enum.ScrollingDirection.Y
body.CanvasSize             = UDim2.fromOffset(0, 0)
body.Parent                 = frame

-- Vertical layout cursor. Sections claim their height as they are built, so
-- inserting one does not mean renumbering everything below it.
local Y = 10
local function at(advance)
    local y = Y
    Y = Y + advance
    return y
end

local function sectionLabel(text, y)
    local bar = Instance.new("Frame")
    bar.Size             = UDim2.fromOffset(2, 12)
    bar.Position         = UDim2.fromOffset(9, y + 1)
    bar.BackgroundColor3 = COL.accent
    bar.BorderSizePixel  = 0
    bar.Parent           = body

    local l = Instance.new("TextLabel")
    l.Size                   = UDim2.new(1, -26, 0, 14)
    l.Position               = UDim2.fromOffset(16, y)
    l.BackgroundTransparency = 1
    l.Text                   = text
    l.TextColor3             = COL.dim
    l.Font                   = Enum.Font.GothamBold
    l.TextSize               = 10
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.Parent                 = body
    return l
end

local function divider(y)
    local d = Instance.new("Frame")
    d.Size             = UDim2.new(1, -18, 0, 1)
    d.Position         = UDim2.fromOffset(9, y)
    d.BackgroundColor3 = COL.line
    d.BorderSizePixel  = 0
    d.Parent           = body
    return d
end

-- Speed -------------------------------------------------------------------
sectionLabel("MOVEMENT", at(16))

local speedRead = Instance.new("TextLabel")
speedRead.Size                   = UDim2.new(1, -20, 0, 14)
speedRead.Position               = UDim2.fromOffset(9, at(18))
speedRead.BackgroundTransparency = 1
speedRead.Text                   = "detecting base speed..."
speedRead.TextColor3             = COL.dim
speedRead.Font                   = Enum.Font.Gotham
speedRead.TextSize               = 11
speedRead.TextXAlignment         = Enum.TextXAlignment.Left
speedRead.Parent                 = body

local speedRowY = at(42)

speedBox = Instance.new("TextBox")
speedBox.Size              = UDim2.new(1, -82, 0, 30)
speedBox.Position          = UDim2.fromOffset(9, speedRowY)
speedBox.BackgroundColor3  = COL.field
speedBox.BorderSizePixel   = 1
speedBox.BorderColor3      = COL.line
speedBox.Text              = tostring(Config.speedMultiplier)
speedBox.PlaceholderText   = "multiplier"
speedBox.TextColor3        = COL.text
speedBox.Font              = Enum.Font.Gotham
speedBox.TextSize          = 13
speedBox.ClearTextOnFocus  = false
speedBox.Parent            = body

local applyBtn = Instance.new("TextButton")
applyBtn.Size             = UDim2.fromOffset(64, 30)
applyBtn.Position         = UDim2.new(1, -73, 0, speedRowY)
applyBtn.BackgroundColor3 = COL.accent
applyBtn.BorderSizePixel  = 0
applyBtn.Text             = "SET"
applyBtn.TextColor3       = COL.bg
applyBtn.Font             = Enum.Font.GothamBold
applyBtn.TextSize         = 12
applyBtn.AutoButtonColor  = false
applyBtn.Parent           = body

local function commitSpeed()
    local v = tonumber(speedBox.Text)
    if v and v > 0 and v <= 20 then
        Config.speedMultiplier = v
        -- A deliberate change resets the guard: this is the value under test now
        table.clear(Guard.hits)
        Guard.graceUntil = tick() + 2
        applySpeed()
        saveSettings()
        applyBtn.Text = "OK"
    else
        speedBox.Text = tostring(Config.speedMultiplier)
        applyBtn.Text = "BAD"
    end
    task.delay(0.8, function() applyBtn.Text = "SET" end)
end

applyBtn.MouseButton1Click:Connect(commitSpeed)
speedBox.FocusLost:Connect(function(enter) if enter then commitSpeed() end end)

divider(at(10))

-- Combat ------------------------------------------------------------------
sectionLabel("COMBAT", at(18))

local toggles  = {}   -- [KeyCode] = flip fn
local renderers = {}  -- every toggle's render fn, replayed after a panic

local function makeToggle(name, key, y, get, set)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, -18, 0, 32)
    btn.Position         = UDim2.fromOffset(9, y)
    btn.BackgroundColor3 = COL.field
    btn.BorderSizePixel  = 1
    btn.BorderColor3     = COL.line
    btn.Text             = ""
    btn.AutoButtonColor  = false
    btn.Parent           = body

    -- Left status stripe that appears when ON
    local activeBar = Instance.new("Frame")
    activeBar.Size             = UDim2.fromOffset(3, 32)
    activeBar.BackgroundColor3 = COL.on
    activeBar.BorderSizePixel  = 0
    activeBar.Visible          = false
    activeBar.Parent           = btn

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -96, 1, 0)
    lbl.Position               = UDim2.fromOffset(12, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = name
    lbl.TextColor3             = COL.text
    lbl.Font                   = Enum.Font.GothamMedium
    lbl.TextSize               = 12
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = btn

    local stateLbl = Instance.new("TextLabel")
    stateLbl.Size                   = UDim2.fromOffset(28, 14)
    stateLbl.Position               = UDim2.new(1, -86, 0.5, -7)
    stateLbl.BackgroundTransparency = 1
    stateLbl.Text                   = "OFF"
    stateLbl.TextColor3             = COL.dim
    stateLbl.Font                   = Enum.Font.GothamBold
    stateLbl.TextSize               = 10
    stateLbl.Parent                 = btn

    -- Square keybind chip, no UICorner
    local hint = Instance.new("TextLabel")
    hint.Size                   = UDim2.fromOffset(48, 20)
    hint.Position               = UDim2.new(1, -52, 0.5, -10)
    hint.BackgroundColor3       = COL.bg
    hint.BorderSizePixel        = 1
    hint.BorderColor3           = COL.line
    hint.Text                   = "[" .. key.Name .. "]"
    hint.TextColor3             = COL.dim
    hint.Font                   = Enum.Font.Gotham
    hint.TextSize               = 10
    hint.Parent                 = btn

    local function render()
        local on = get()
        btn.BorderColor3    = on and COL.on or COL.line
        activeBar.Visible   = on
        stateLbl.Text       = on and "ON" or "OFF"
        stateLbl.TextColor3 = on and COL.on or COL.dim
    end

    local function flip()
        set(not get())
        render()
    end

    btn.MouseButton1Click:Connect(flip)
    render()
    toggles[key] = flip
    renderers[#renderers + 1] = render
    return btn
end

-- Half-width chip for the secondary options. Same visual language, no keybind.
local function makeChip(name, x, y, w, get, set)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.fromOffset(w, 32)
    btn.Position         = UDim2.fromOffset(x, y)
    btn.BackgroundColor3 = COL.field
    btn.BorderSizePixel  = 1
    btn.BorderColor3     = COL.line
    btn.Text             = ""
    btn.AutoButtonColor  = false
    btn.Parent           = body

    local activeBar = Instance.new("Frame")
    activeBar.Size             = UDim2.fromOffset(3, 32)
    activeBar.BackgroundColor3 = COL.on
    activeBar.BorderSizePixel  = 0
    activeBar.Visible          = false
    activeBar.Parent           = btn

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -14, 1, 0)
    lbl.Position               = UDim2.fromOffset(10, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = name
    lbl.TextColor3             = COL.dim
    lbl.Font                   = Enum.Font.GothamBold
    lbl.TextSize               = 10
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = btn

    local function render()
        local on = get()
        btn.BorderColor3  = on and COL.on or COL.line
        activeBar.Visible = on
        lbl.TextColor3    = on and COL.text or COL.dim
    end

    btn.MouseButton1Click:Connect(function()
        set(not get())
        render()
        saveSettings()
    end)
    render()
    renderers[#renderers + 1] = render
    return btn
end

makeToggle("Auto Block", Config.keyBlock, at(36),
    function() return Config.autoBlock end,
    function(v)
        Config.autoBlock = v
        if not v then
            Shield.set(false)
            releaseRotation()
            Shield.faulted = false
        end
    end)

makeToggle("Auto Kick", Config.keyKick, at(44),
    function() return Config.autoKick end,
    function(v) Config.autoKick = v end)

divider(at(10))

-- Assist ------------------------------------------------------------------
sectionLabel("ASSIST", at(18))

local CHIP_W, CHIP_X2 = 114, 129

local assistRow1 = at(36)
makeChip("UNSHIELD", 9, assistRow1, CHIP_W,
    function() return Config.autoUnshield end,
    function(v) Config.autoUnshield = v end)

makeChip("FACE", CHIP_X2, assistRow1, CHIP_W,
    function() return Config.autoFace end,
    function(v)
        Config.autoFace = v
        if not v then releaseRotation() end
    end)

local assistRow2 = at(36)
makeChip("BACKPEDAL", 9, assistRow2, CHIP_W,
    function() return Config.backpedal end,
    function(v) Config.backpedal = v end)

makeChip("SOUND", CHIP_X2, assistRow2, CHIP_W,
    function() return Config.sounds end,
    function(v) Config.sounds = v end)

local assistRow3 = at(44)
makeChip("AUTOCAP", 9, assistRow3, CHIP_W,
    function() return Config.autoCap end,
    function(v)
        Config.autoCap = v
        table.clear(Guard.hits)
    end)

divider(at(10))

-- Anim learning -----------------------------------------------------------
-- The attack table shipped incomplete and every missing ID is a swing that
-- does not raise the shield. Unrecognised one-shot anims from nearby players
-- surface here instead of the executor console, which is unreadable on a
-- tablet mid-fight. ADD folds the ID into the attack set and persists it.

local animHeaderY = at(18)
sectionLabel("ANIM LEARN", animHeaderY)

local animReset = Instance.new("TextButton")
animReset.Size             = UDim2.new(0, 44, 0, 14)
animReset.Position         = UDim2.new(1, -53, 0, animHeaderY)
animReset.BackgroundColor3 = COL.bg
animReset.BorderSizePixel  = 1
animReset.BorderColor3     = COL.line
animReset.Text             = "RESET"
animReset.TextColor3       = COL.dim
animReset.Font             = Enum.Font.GothamBold
animReset.TextSize         = 9
animReset.AutoButtonColor  = false
animReset.Parent           = body

local animEmpty = Instance.new("TextLabel")
animEmpty.Size                   = UDim2.new(1, -22, 0, 24)
animEmpty.Position               = UDim2.fromOffset(9, Y)
animEmpty.BackgroundTransparency = 1
animEmpty.Text                   = "watching for unknown swings..."
animEmpty.TextColor3             = COL.dim
animEmpty.Font                   = Enum.Font.Gotham
animEmpty.TextSize               = 11
animEmpty.TextXAlignment         = Enum.TextXAlignment.Left
animEmpty.Parent                 = body

local function learnAnim(id)
    ATTACK_ANIMS[id] = true
    Config.learnedAnims[#Config.learnedAnims + 1] = id
    saveSettings()
end

local function dismissAnim(id)
    DISMISSED[id] = true
    Config.dismissedAnims[#Config.dismissedAnims + 1] = id
    saveSettings()
end

local function dropPending(id)
    for i, v in ipairs(pendingAnims) do
        if v == id then
            table.remove(pendingAnims, i)
            break
        end
    end
    refreshAnimRows()
end

local animRows = {}
for i = 1, 3 do
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1, -22, 0, 24)
    row.Position         = UDim2.fromOffset(9, at(27))
    row.BackgroundColor3 = COL.field
    row.BorderSizePixel  = 1
    row.BorderColor3     = COL.line
    row.Visible          = false
    row.Parent           = body

    local idLbl = Instance.new("TextLabel")
    idLbl.Size                   = UDim2.new(1, -92, 1, 0)
    idLbl.Position               = UDim2.fromOffset(8, 0)
    idLbl.BackgroundTransparency = 1
    idLbl.TextColor3             = COL.text
    idLbl.Font                   = Enum.Font.Gotham
    idLbl.TextSize               = 10
    idLbl.TextXAlignment         = Enum.TextXAlignment.Left
    idLbl.Parent                 = row

    local add = Instance.new("TextButton")
    add.Size             = UDim2.new(0, 42, 0, 18)
    add.Position         = UDim2.new(1, -70, 0.5, -9)
    add.BackgroundColor3 = COL.accent
    add.BorderSizePixel  = 0
    add.Text             = "ADD"
    add.TextColor3       = COL.bg
    add.Font             = Enum.Font.GothamBold
    add.TextSize         = 9
    add.AutoButtonColor  = false
    add.Parent           = row

    local skip = Instance.new("TextButton")
    skip.Size             = UDim2.new(0, 20, 0, 18)
    skip.Position         = UDim2.new(1, -24, 0.5, -9)
    skip.BackgroundColor3 = COL.bg
    skip.BorderSizePixel  = 1
    skip.BorderColor3     = COL.line
    skip.Text             = "X"
    skip.TextColor3       = COL.dim
    skip.Font             = Enum.Font.GothamBold
    skip.TextSize         = 9
    skip.AutoButtonColor  = false
    skip.Parent           = row

    local slot = { row = row, idLbl = idLbl, id = nil }
    add.MouseButton1Click:Connect(function()
        if not slot.id then return end
        learnAnim(slot.id)
        Sfx.play("up")
        dropPending(slot.id)
    end)
    skip.MouseButton1Click:Connect(function()
        if not slot.id then return end
        dismissAnim(slot.id)
        dropPending(slot.id)
    end)
    animRows[i] = slot
end

function refreshAnimRows()
    for i, slot in ipairs(animRows) do
        local id = pendingAnims[i]
        slot.id = id
        slot.row.Visible = id ~= nil
        if id then slot.idLbl.Text = tostring(id) end
    end
    animEmpty.Visible = #pendingAnims == 0
end

animReset.MouseButton1Click:Connect(function()
    for _, id in ipairs(Config.learnedAnims) do ATTACK_ANIMS[id] = nil end
    table.clear(Config.learnedAnims)
    table.clear(Config.dismissedAnims)
    table.clear(DISMISSED)
    table.clear(offeredAnims)
    table.clear(pendingAnims)
    refreshAnimRows()
    saveSettings()
    animReset.Text = "CLEAR"
    task.delay(0.8, function() animReset.Text = "RESET" end)
end)

refreshAnimRows()

divider(at(10))

-- Tuning ------------------------------------------------------------------
sectionLabel("TUNING", at(18))

-- Sliders -----------------------------------------------------------------
local function makeSlider(name, y, minV, maxV, getV, setV)
    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -18, 0, 14)
    lbl.Position               = UDim2.fromOffset(9, y)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = name .. ": " .. getV()
    lbl.TextColor3             = COL.dim
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextSize               = 11
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = body

    local rail = Instance.new("Frame")
    rail.Size             = UDim2.new(1, -22, 0, 8)
    rail.Position         = UDim2.fromOffset(9, y + 18)
    rail.BackgroundColor3 = COL.field
    rail.BorderSizePixel  = 1
    rail.BorderColor3     = COL.line
    rail.Active           = true
    rail.Parent           = body

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = COL.accent
    fill.BorderSizePixel  = 0
    fill.Parent           = rail

    local function render()
        local a = (getV() - minV) / (maxV - minV)
        fill.Size = UDim2.new(math.clamp(a, 0, 1), 0, 1, 0)
        lbl.Text  = name .. ": " .. getV()
    end

    local function apply(x)
        local a = math.clamp((x - rail.AbsolutePosition.X) / rail.AbsoluteSize.X, 0, 1)
        setV(math.floor(minV + a * (maxV - minV) + 0.5))
        render()
    end

    -- Drag is scoped to the input that started it rather than a global
    -- InputChanged listener per slider, so nothing keeps firing once the panel
    -- is idle and a second slider can never steal an in-flight drag.
    rail.InputBegan:Connect(function(i)
        if i.UserInputType ~= Enum.UserInputType.MouseButton1
        and i.UserInputType ~= Enum.UserInputType.Touch then return end
        apply(i.Position.X)
        local moveConn
        moveConn = UserInputService.InputChanged:Connect(function(m)
            if m.UserInputType == Enum.UserInputType.MouseMovement
            or m == i then
                apply(m.Position.X)
            end
        end)
        local endConn
        endConn = UserInputService.InputEnded:Connect(function(e)
            if e.UserInputType ~= Enum.UserInputType.MouseButton1 and e ~= i then return end
            moveConn:Disconnect()
            endConn:Disconnect()
            saveSettings()
        end)
    end)

    render()
end

makeSlider("Block range", at(34), 6, 40,
    function() return Config.blockRange end,
    function(v) Config.blockRange = v end)

makeSlider("Kick range", at(34), 6, 30,
    function() return Config.kickRange end,
    function(v) Config.kickRange = v end)

body.CanvasSize = UDim2.fromOffset(0, Y + 8)

-- Status strip ------------------------------------------------------------
-- Outside the scroll body: pinned to the bottom of the panel so combat state
-- is readable no matter where the body is scrolled.
local statusStrip = Instance.new("Frame")
statusStrip.Size             = UDim2.new(1, -21, 0, 30)
statusStrip.Position         = UDim2.new(0, 12, 1, -38)
statusStrip.BackgroundColor3 = COL.field
statusStrip.BorderSizePixel  = 1
statusStrip.BorderColor3     = COL.line
statusStrip.Parent           = frame

local statusBar = Instance.new("Frame")
statusBar.Size             = UDim2.fromOffset(3, 30)
statusBar.BackgroundColor3 = COL.dim
statusBar.BorderSizePixel  = 0
statusBar.Parent           = statusStrip

local status = Instance.new("TextLabel")
status.Size                   = UDim2.new(1, -14, 1, 0)
status.Position               = UDim2.fromOffset(11, 0)
status.BackgroundTransparency = 1
status.Text                   = "IDLE"
status.TextColor3             = COL.dim
status.Font                   = Enum.Font.GothamBold
status.TextSize               = 11
status.TextXAlignment         = Enum.TextXAlignment.Left
status.Parent                 = statusStrip

-- Drag --------------------------------------------------------------------
-- Frame.Draggable is deprecated and unreliable once the GUI lives outside
-- PlayerGui, so the drag is driven directly off input events.
do
    local dragging, startPos, startInput
    titleBar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging   = true
            startPos   = border.Position
            startInput = i.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType ~= Enum.UserInputType.MouseMovement
        and i.UserInputType ~= Enum.UserInputType.Touch then return end
        local d = i.Position - startInput
        border.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y
        )
    end)
end

-- Floating toggle button -------------------------------------------------
-- Independent draggable chip that shows/hides the panel.
-- Stays visible even when the panel is hidden.
local chip = Instance.new("Frame")
chip.Size             = UDim2.fromOffset(48, 48)
chip.Position         = UDim2.new(0, 289, 0.5, -24)
chip.BackgroundColor3 = COL.bar
chip.BorderSizePixel  = 1
chip.BorderColor3     = COL.accent
chip.Active           = true
chip.Parent           = screen

local chipAccent = Instance.new("Frame")
chipAccent.Size             = UDim2.fromOffset(48, 3)
chipAccent.BackgroundColor3 = COL.accent
chipAccent.BorderSizePixel  = 0
chipAccent.Parent           = chip

local chipBtn = Instance.new("TextButton")
chipBtn.Size              = UDim2.new(1, 0, 1, 0)
chipBtn.BackgroundTransparency = 1
chipBtn.Text              = "CC"
chipBtn.TextColor3        = COL.accent
chipBtn.Font              = Enum.Font.GothamBold
chipBtn.TextSize          = 14
chipBtn.AutoButtonColor   = false
chipBtn.Parent            = chip

local chipStatus = Instance.new("TextLabel")
chipStatus.Size                   = UDim2.new(1, 0, 0, 14)
chipStatus.Position               = UDim2.new(0, 0, 1, -16)
chipStatus.BackgroundTransparency = 1
chipStatus.Text                   = "OFF"
chipStatus.TextColor3             = COL.dim
chipStatus.Font                   = Enum.Font.GothamBold
chipStatus.TextSize               = 8
chipStatus.Parent                 = chip

-- Unanswered anim offers get a dot on the chip, so a find during a fight is
-- still there to action once the fight is over.
local chipDot = Instance.new("Frame")
chipDot.Size             = UDim2.fromOffset(6, 6)
chipDot.Position         = UDim2.new(1, -9, 0, 6)
chipDot.BackgroundColor3 = COL.accent
chipDot.BorderSizePixel  = 0
chipDot.Visible          = false
chipDot.Parent           = chip

local function togglePanel()
    border.Visible = not border.Visible
    chip.BorderColor3 = border.Visible and COL.accent or COL.dim
    chipBtn.TextColor3 = border.Visible and COL.accent or COL.dim
end

do
    local dragging, moved, startPos, startInput
    -- chipBtn covers the whole frame so drag and click both wire here.
    -- A move > 4px counts as a drag; anything smaller is a tap/click → togglePanel.
    chipBtn.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging   = true
            moved      = false
            startPos   = chip.Position
            startInput = i.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    if not moved then togglePanel() end
                    dragging = false
                    moved    = false
                end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType ~= Enum.UserInputType.MouseMovement
        and i.UserInputType ~= Enum.UserInputType.Touch then return end
        local d = i.Position - startInput
        if d.Magnitude > 4 then moved = true end
        if moved then
            chip.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)
end

-- Failsafe ----------------------------------------------------------------
-- Kills every active behaviour and returns the character to stock state in one
-- keypress: features off, shield down, rotation released, speed back to base.

local function panic()
    Config.autoBlock       = false
    Config.autoKick        = false
    Config.backpedal       = false
    Config.speedMultiplier = 1
    speedBox.Text          = "1"
    Shield.set(false)
    Shield.faulted         = false
    releaseRotation()
    applySpeed()
    Sfx.play("fail")
    for _, render in ipairs(renderers) do render() end
    saveSettings()
end

-- Keybinds ----------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
    if processed or UserInputService:GetFocusedTextBox() then return end
    if input.KeyCode == Config.keyPanic then
        panic()
        return
    end
    if input.KeyCode == Config.keyPanel then
        togglePanel()
        return
    end
    local flip = toggles[input.KeyCode]
    if flip then flip() end
end)

-- Watchdog: the game clears PlayerGui when it opens its own menus, and an
-- executor may reject the protected parent. Re-parent instead of vanishing.
task.spawn(function()
    while task.wait(1) do
        if not screen.Parent then parentGui() end
    end
end)

-- HP bar update loop -------------------------------------------------------
task.spawn(function()
    while task.wait(0.1) do
        for _, e in pairs(Enemies) do
            local fill, hum = e.hpFill, e.humanoid
            if fill and fill.Parent and hum and hum.Parent then
                local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                fill.Size = UDim2.new(pct, 0, 1, 0)
                fill.BackgroundColor3 = pct > 0.4
                    and Color3.fromRGB(0, 210, 90)
                    or  Color3.fromRGB(255, 50, 50)
            end
        end
    end
end)

-- Status feed -------------------------------------------------------------
task.spawn(function()
    local wasFaulted = false
    while task.wait(0.1) do
        if Me.baseSpeed then
            speedRead.Text = string.format("%.1f  →  %.1f studs/s",
                Me.baseSpeed, Me.baseSpeed * Config.speedMultiplier)
        end

        -- A RemoteFunction that never returns leaves the worker parked and the
        -- shield stuck wherever it was. Surface it instead of going quiet.
        if Shield.busy and tick() - Shield.since > 2 then Shield.faulted = true end
        if Shield.faulted and not wasFaulted then Sfx.play("fail") end
        wasFaulted = Shield.faulted

        local text, colour
        if not alive() then
            text, colour = "DEAD", COL.dim
        elseif Shield.faulted then
            text, colour = "SHIELD FAULT", COL.alert
        elseif tick() - Guard.cappedAt < 4 then
            text, colour = string.format("SPEED CAPPED  %.1fx", Config.speedMultiplier), COL.alert
        elseif isKnocked() then
            text, colour = "KNOCKED", COL.alert
        elseif Shield.actual then
            text, colour = "BLOCKING  " .. threatCount .. " THREAT"
                        .. (threatCount == 1 and "" or "S"), COL.on
        elseif Config.autoBlock and inCombat() then
            text, colour = "ARMED  WATCHING", COL.accent
        elseif Config.autoBlock then
            text, colour = "ARMED  STANDBY", COL.dim
        elseif #pendingAnims > 0 then
            text, colour = #pendingAnims .. " UNKNOWN ANIM"
                        .. (#pendingAnims == 1 and "" or "S"), COL.accent
        else
            text, colour = "IDLE", COL.dim
        end
        status.Text                  = text
        status.TextColor3            = colour
        statusBar.BackgroundColor3   = colour
        statusStrip.BorderColor3     = colour ~= COL.dim and colour or COL.line
        chipStatus.Text              = Shield.actual and "BLK" or (Config.autoBlock and "ARM" or "OFF")
        chipStatus.TextColor3        = colour
        chipDot.Visible              = #pendingAnims > 0
    end
end)
