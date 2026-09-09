--[[
    Desync.lua — Universal Roblox Desync

    You walk around normally. The humanoid is never modified, so movement,
    animations, collision and the camera stay entirely native. Only what the
    server receives is changed.

    The core invariant
    ------------------
    The position the server sees (`serverCF`) NEVER jumps. It is a simulated
    point that chases a target at a capped speed, always. Every teleport
    detector works the same way — magnitude(lastPos, newPos) / dt compared
    against a plausible maximum — so a position that only ever moves at a
    legitimate speed has nothing to flag, no matter how far it currently is
    from where you actually are.

    That single rule is what makes this usable in games that detect teleports.
    It is also why switching it off no longer snaps: instead of handing the
    server your real position in one frame, the script walks `serverCF` back
    to you at running speed and only then stops.

    Modes
    -----
    SHADOW  A rigid offset from where you actually are. The gap is constant,
            so serverCF moves at exactly your speed and no catch-up burst
            exists to be detected. Small enough to stay inside a game's
            interaction range, so your own attacks and interactions still
            land. Default.
    TRAIL   serverCF follows the path you actually walked, TrailLag seconds
            behind. Every position the server sees is one you genuinely
            occupied, in the order you occupied it — there is no artificial
            movement to detect at all.
    ANCHOR  serverCF is pinned where you switched on. Biggest gap, loudest:
            its leash has to accelerate from a standstill to reel you back in,
            and that acceleration is a speed signature the others lack.

    The server has one position for you, and range checks measure from it, so
    any gap large enough to stop incoming damage breaks your own outgoing
    reach by the same distance. SHADOW exists to keep the gap under that line.

    MaxGap is the leash. Games that snap you back are measuring the distance
    between where they think you are and where you claim to be; keeping the
    gap under that threshold is what stops the snap. Default 60 studs.

    Transports
    ----------
    native  Uses the executor's RakNet layer: physics packets are suppressed
            and the spoofed position is pushed directly. No local CFrame
            writes at all, so nothing client-side can observe the desync.
            Requires both a packet-drop function and rnet.sendphysics.
    swap    The portable fallback. Frame order on the client is

                RenderStepped -> render -> Stepped -> physics -> Heartbeat -> flush

            Heartbeat is the last thing before the engine transmits, so the
            real CFrame is saved and the spoofed one written there. It is then
            restored TWICE: at Stepped, which fires immediately before the
            physics step, and at RenderStepped, before the frame draws.

            Both restores are load-bearing. Physics is not locked to the
            render frame, and at 30fps the gap between the Heartbeat write and
            the next RenderStepped is a full 33ms of simulation — long enough
            for the engine to solve the character out of whatever the spoofed
            position is intersecting, which shows up as shaking. Restoring at
            Stepped is what guarantees physics only ever integrates from the
            real state.

    Toggle with the GUI button or [F]. Everything works from the GUI alone —
    no keyboard required.
--]]

local CONFIG = {
    ToggleKey = Enum.KeyCode.F,

    Mode = "SHADOW",    -- "SHADOW", "TRAIL" or "ANCHOR"

    ShadowOffset = Vector3.new(4, 0, 0),

    MaxGap = 60,        -- studs

    SpeedFloorFactor = 1.0,

    MinSpeedFloor = 1,   -- studs/s

    MaxTrackSpeed = 250, -- studs/s

    TrailLag = 1.5,     -- seconds

    ResyncTolerance = 2, -- studs
}

-- ── Services ──────────────────────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local StarterGui       = game:GetService("StarterGui")

local lp = Players.LocalPlayer

-- ── State ─────────────────────────────────────────────────────────────────────
local PHASE_OFF, PHASE_ON, PHASE_RESYNC = "off", "on", "resync"
local phase = PHASE_OFF

local anchorCF = CFrame.new()   -- ANCHOR mode target
local serverCF = CFrame.new()   -- what the server sees; never jumps
local lastStep = os.clock()

local observedSpeed = 0
local lastRealPos   = nil

local instantSpeed = 0

local realCF, realVel, realAngVel

local heartbeatConn = nil
local steppedConn   = nil
local root, humanoid

local RESTORE_BIND = "DesyncRestore"

-- ── RakNet backend detection ──────────────────────────────────────────────────
local ID_PHYSICS = 0x85

local function globalTable(name)
    local ok, v = pcall(function()
        if getgenv then
            local g = getgenv()[name]
            if g ~= nil then return g end
        end
        return getfenv(0)[name]
    end)
    if ok and (type(v) == "table" or type(v) == "userdata") then return v end
    return nil
end

local function hasFn(t, name)
    if not t then return false end
    local ok, v = pcall(function() return t[name] end)
    return ok and type(v) == "function"
end

local Net = { drop = nil, sendPhysics = nil, label = "swap" }

local function detectBackend()
    local rk = globalTable("raknet")
    local rn = globalTable("rnet")

    if hasFn(rk, "desync") then
        Net.drop = function(on) pcall(function() rk.desync(on) end) end
    elseif hasFn(rk, "block") then
        Net.drop = function(on)
            pcall(function()
                if on then rk.block(ID_PHYSICS, true)
                elseif hasFn(rk, "unblock") then rk.unblock(ID_PHYSICS)
                else rk.block(ID_PHYSICS, false) end
            end)
        end
    elseif hasFn(rn, "setfilter") then
        Net.drop = function(on)
            pcall(function() rn.setfilter(on and { ID_PHYSICS } or {}) end)
        end
    end

    if hasFn(rn, "sendphysics") then
        Net.sendPhysics = function(cf) pcall(function() rn.sendphysics(cf) end) end
    end

    Net.label = (Net.drop and Net.sendPhysics) and "native" or "swap"
end

detectBackend()

-- ── Path history ──────────────────────────────────────────────────────────────
local trail = {}

local function pushTrail(pos, now)
    trail[#trail + 1] = { t = now, p = pos }
    local cutoff = now - (CONFIG.TrailLag + 2)
    local drop = 0
    while trail[drop + 1] and trail[drop + 1].t < cutoff do
        drop += 1
    end
    if drop > 0 then
        table.move(trail, drop + 1, #trail, 1)
        for i = #trail, #trail - drop + 1, -1 do trail[i] = nil end
    end
end

local function trailPointAt(age, now)
    if #trail == 0 then return nil end
    local want = now - age
    for i = #trail, 1, -1 do
        if trail[i].t <= want then
            local a, b = trail[i], trail[i + 1]
            if not b then return a.p end
            local span = b.t - a.t
            if span <= 1e-6 then return a.p end
            return a.p:Lerp(b.p, math.clamp((want - a.t) / span, 0, 1))
        end
    end
    return trail[1].p
end

-- ── GUI ───────────────────────────────────────────────────────────────────────
local sg = Instance.new("ScreenGui")
sg.Name           = "DesyncGUI"
sg.ResetOnSpawn   = false
sg.IgnoreGuiInset = true
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

if not pcall(function() sg.Parent = game:GetService("CoreGui") end) then
    sg.Parent = lp:WaitForChild("PlayerGui")
end

local frame = Instance.new("Frame")
frame.Size             = UDim2.fromOffset(248, 196)
frame.Position         = UDim2.fromOffset(20, 20)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
frame.BorderSizePixel  = 0
frame.Parent           = sg
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke", frame)
stroke.Color, stroke.Thickness = Color3.fromRGB(60, 60, 75), 1

local titleBar = Instance.new("Frame")
titleBar.Size             = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
titleBar.BorderSizePixel  = 0
titleBar.Parent           = frame
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleSquare = Instance.new("Frame")
titleSquare.Size             = UDim2.new(1, 0, 0.5, 0)
titleSquare.Position         = UDim2.fromScale(0, 0.5)
titleSquare.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
titleSquare.BorderSizePixel  = 0
titleSquare.Parent           = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size                   = UDim2.new(1, -10, 1, 0)
titleLabel.Position               = UDim2.fromOffset(10, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Font                   = Enum.Font.GothamBold
titleLabel.TextSize               = 13
titleLabel.TextColor3             = Color3.fromRGB(180, 180, 200)
titleLabel.TextXAlignment         = Enum.TextXAlignment.Left
titleLabel.Text                   = "DESYNC"
titleLabel.Parent                 = titleBar

local function mkLabel(y, size, colour)
    local l = Instance.new("TextLabel")
    l.Size                   = UDim2.new(1, -20, 0, 16)
    l.Position               = UDim2.fromOffset(10, y)
    l.BackgroundTransparency = 1
    l.Font                   = Enum.Font.Gotham
    l.TextSize               = size
    l.TextColor3             = colour
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.Parent                 = frame
    return l
end

local statusLabel = mkLabel(36, 12, Color3.fromRGB(120, 120, 140))
statusLabel.Text = "Status: Inactive"

local infoLabel = mkLabel(54, 11, Color3.fromRGB(95, 95, 115))
infoLabel.Text = "gap 0 · " .. Net.label

local function mkButton(y, h, text, size)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(1, -20, 0, h)
    b.Position         = UDim2.fromOffset(10, y)
    b.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    b.BorderSizePixel  = 0
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = size
    b.TextColor3       = Color3.fromRGB(200, 200, 220)
    b.Text             = text
    b.AutoButtonColor  = false
    b.Parent           = frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    local s = Instance.new("UIStroke", b)
    s.Color, s.Thickness = Color3.fromRGB(60, 60, 75), 1
    return b, s
end

local btn, btnStroke = mkButton(78, 44, "ENABLE", 14)
local modeBtn, modeStroke = mkButton(130, 34, "Mode: TRAIL", 12)
local gapBtn, gapStroke   = mkButton(170, 0, "", 12)
gapBtn.Visible = false
gapStroke.Thickness = 0

local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad)

btn.MouseEnter:Connect(function()
    if phase ~= PHASE_OFF then return end
    TweenService:Create(btn, tweenInfo, { BackgroundColor3 = Color3.fromRGB(50, 50, 65) }):Play()
end)
btn.MouseLeave:Connect(function()
    if phase ~= PHASE_OFF then return end
    TweenService:Create(btn, tweenInfo, { BackgroundColor3 = Color3.fromRGB(35, 35, 45) }):Play()
end)

local dragging, dragStart, startPos = false, nil, nil

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging, dragStart, startPos = true, input.Position, frame.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - dragStart
        frame.Position = UDim2.fromOffset(
            startPos.X.Offset + delta.X,
            startPos.Y.Offset + delta.Y
        )
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

local function updateUI()
    if phase == PHASE_ON then
        statusLabel.Text, statusLabel.TextColor3 = "Status: ACTIVE", Color3.fromRGB(80, 220, 100)
        btn.Text, btn.TextColor3 = "DISABLE", Color3.fromRGB(80, 220, 100)
        TweenService:Create(btn,       tweenInfo, { BackgroundColor3 = Color3.fromRGB(30, 90, 50) }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color = Color3.fromRGB(50, 160, 80) }):Play()
    elseif phase == PHASE_RESYNC then
        statusLabel.Text, statusLabel.TextColor3 = "Status: RESYNCING", Color3.fromRGB(230, 180, 90)
        btn.Text, btn.TextColor3 = "CANCEL", Color3.fromRGB(230, 180, 90)
        TweenService:Create(btn,       tweenInfo, { BackgroundColor3 = Color3.fromRGB(80, 60, 25) }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color = Color3.fromRGB(160, 120, 60) }):Play()
    else
        statusLabel.Text, statusLabel.TextColor3 = "Status: Inactive", Color3.fromRGB(120, 120, 140)
        btn.Text, btn.TextColor3 = "ENABLE", Color3.fromRGB(200, 200, 220)
        TweenService:Create(btn,       tweenInfo, { BackgroundColor3 = Color3.fromRGB(35, 35, 45) }):Play()
        TweenService:Create(btnStroke, tweenInfo, { Color = Color3.fromRGB(60, 60, 75) }):Play()
    end
end

local function updateModeUI()
    local tint = {
        SHADOW = { Color3.fromRGB(140, 220, 160), Color3.fromRGB(60, 130, 80)  },
        TRAIL  = { Color3.fromRGB(140, 190, 230), Color3.fromRGB(70, 110, 150) },
        ANCHOR = { Color3.fromRGB(230, 140, 140), Color3.fromRGB(140, 70, 70)  },
    }
    local t = tint[CONFIG.Mode] or tint.SHADOW
    modeBtn.Text       = "Mode: " .. CONFIG.Mode
    modeBtn.TextColor3 = t[1]
    TweenService:Create(modeStroke, tweenInfo, { Color = t[2] }):Play()
end

-- ── Core ──────────────────────────────────────────────────────────────────────

local function alive()
    return root ~= nil and root.Parent ~= nil
end

local function rotationOf(cf)
    return cf - cf.Position
end

local function modeTarget(realPos, now)
    if CONFIG.Mode == "ANCHOR" then
        return anchorCF.Position
    end
    if CONFIG.Mode == "SHADOW" then
        return realPos + CONFIG.ShadowOffset
    end
    return trailPointAt(CONFIG.TrailLag, now) or realPos
end

local function speedFloor()
    local ws = 16
    if humanoid then
        local ok, v = pcall(function() return humanoid.WalkSpeed end)
        if ok and type(v) == "number" and v > 0 then ws = v end
    end
    return math.max(ws * CONFIG.SpeedFloorFactor, CONFIG.MinSpeedFloor)
end

local function trackSpeed(headroom)
    local floor = speedFloor()
    return math.clamp(
        math.max(floor, observedSpeed * headroom),
        floor,
        CONFIG.MaxTrackSpeed
    )
end

local function chase(targetPos, maxSpeed, dt, rot)
    local delta = targetPos - serverCF.Position
    local dist  = delta.Magnitude
    local step  = math.min(dist, maxSpeed * dt)
    local pos   = dist > 1e-4 and (serverCF.Position + delta.Unit * step) or targetPos
    serverCF = CFrame.new(pos) * rot
    return dist - step
end

local function transmit()
    if Net.label == "native" then
        Net.sendPhysics(serverCF)
        return
    end
    realCF     = root.CFrame
    realVel    = root.AssemblyLinearVelocity
    realAngVel = root.AssemblyAngularVelocity

    root.CFrame                  = serverCF
    root.AssemblyLinearVelocity  = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function restoreReal()
    if Net.label == "native" then return end
    if not alive() or not realCF then return end
    root.CFrame                  = realCF
    root.AssemblyLinearVelocity  = realVel or Vector3.zero
    root.AssemblyAngularVelocity = realAngVel or Vector3.zero
end

local uiClock = 0

local function onHeartbeat()
    if phase == PHASE_OFF or not alive() then return end

    local now = os.clock()
    local dt  = math.min(now - lastStep, 0.25)
    lastStep  = now

    local realPos = root.CFrame.Position
    local rot     = rotationOf(root.CFrame)
    pushTrail(realPos, now)

    if lastRealPos then
        local instant = math.min(
            (realPos - lastRealPos).Magnitude / dt,
            CONFIG.MaxTrackSpeed
        )
        instantSpeed  = instant
        observedSpeed += (instant - observedSpeed) * math.min(1, dt * 8)
    end
    lastRealPos = realPos

    local targetPos, speed

    if phase == PHASE_RESYNC then
        targetPos = realPos
        speed     = trackSpeed(1.15)
    else
        targetPos = modeTarget(realPos, now)
        if CONFIG.Mode == "SHADOW" then
            local floor = speedFloor()
            speed = math.clamp(
                math.max(floor, instantSpeed * 1.05), floor, CONFIG.MaxTrackSpeed
            )
        else
            speed = trackSpeed(1.05)
        end

        local off = realPos - targetPos
        if off.Magnitude > CONFIG.MaxGap then
            targetPos = realPos - off.Unit * CONFIG.MaxGap
        end
    end

    local remaining = chase(targetPos, speed, dt, rot)

    if phase == PHASE_RESYNC and remaining <= CONFIG.ResyncTolerance then
        phase = PHASE_OFF
        restoreReal()
        realCF, realVel, realAngVel = nil, nil, nil
        if Net.drop then Net.drop(false) end
        pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
        if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
        if steppedConn then steppedConn:Disconnect(); steppedConn = nil end
        updateUI()
        infoLabel.Text = "gap 0 · " .. Net.label
        return
    end

    transmit()

    uiClock += dt
    if uiClock >= 0.1 then
        uiClock = 0
        infoLabel.Text = string.format(
            "gap %d · %s", (realPos - serverCF.Position).Magnitude, Net.label
        )
    end
end

local function startLoops()
    if heartbeatConn then return end
    lastStep = os.clock()
    heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
    steppedConn = RunService.Stepped:Connect(restoreReal)
    RunService:BindToRenderStep(RESTORE_BIND, Enum.RenderPriority.First.Value, restoreReal)
end

local function enable()
    if phase == PHASE_ON then return end

    if not alive() or not humanoid then
        statusLabel.Text       = "Status: no character"
        statusLabel.TextColor3 = Color3.fromRGB(220, 160, 60)
        return
    end

    if phase == PHASE_OFF then
        serverCF = root.CFrame
        table.clear(trail)
        observedSpeed, lastRealPos = 0, nil
    end

    anchorCF = root.CFrame
    phase    = PHASE_ON

    if Net.drop then Net.drop(true) end
    startLoops()
    updateUI()

    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Desync", Text = CONFIG.Mode .. " · " .. Net.label, Duration = 2,
        })
    end)
end

local function disable()
    if phase ~= PHASE_ON then return end
    phase = PHASE_RESYNC

    if Net.drop and Net.label ~= "native" then Net.drop(false) end

    updateUI()
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Desync", Text = "Resyncing — walking the gap back", Duration = 2,
        })
    end)
end

local function teardown()
    phase = PHASE_OFF
    pcall(function() RunService:UnbindFromRenderStep(RESTORE_BIND) end)
    if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
    if steppedConn then steppedConn:Disconnect(); steppedConn = nil end
    if Net.drop then Net.drop(false) end
end

local function toggle()
    if phase == PHASE_ON then
        disable()
    elseif phase == PHASE_RESYNC then
        phase = PHASE_ON
        if Net.drop then Net.drop(true) end
        updateUI()
    else
        enable()
    end
end

-- ── Character binding ─────────────────────────────────────────────────────────
local function bindCharacter(c)
    root     = c:WaitForChild("HumanoidRootPart")
    humanoid = c:WaitForChild("Humanoid")
    serverCF = root.CFrame
end

task.spawn(function()
    bindCharacter(lp.Character or lp.CharacterAdded:Wait())
end)

lp.CharacterAdded:Connect(function(newChar)
    teardown()
    realCF, realVel, realAngVel = nil, nil, nil
    root, humanoid = nil, nil
    table.clear(trail)
    updateUI()
    bindCharacter(newChar)
end)

-- ── Input ─────────────────────────────────────────────────────────────────────
btn.Activated:Connect(toggle)

modeBtn.Activated:Connect(function()
    local order = { SHADOW = "TRAIL", TRAIL = "ANCHOR", ANCHOR = "SHADOW" }
    CONFIG.Mode = order[CONFIG.Mode] or "SHADOW"
    if phase == PHASE_ON then anchorCF = alive() and root.CFrame or anchorCF end
    updateModeUI()
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == CONFIG.ToggleKey then toggle() end
end)

updateModeUI()
updateUI()

-- ── Public API ────────────────────────────────────────────────────────────────
return {
    enable   = enable,
    disable  = disable,
    toggle   = toggle,
    phase    = function() return phase end,
    gap      = function()
        if not alive() then return 0 end
        return (root.CFrame.Position - serverCF.Position).Magnitude
    end,
    backend  = function() return Net.label end,
    config   = CONFIG,
}
