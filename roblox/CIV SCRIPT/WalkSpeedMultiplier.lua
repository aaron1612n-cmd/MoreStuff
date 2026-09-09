--[[
    CIV CC PANEL
    Civilization Survival — speed control, auto block, auto kick.
    LocalScript / executor loadstring.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
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
    blockRange      = 18,
    kickRange       = 14,
    kickCooldown    = 1.0,
    keyPanel        = Enum.KeyCode.RightShift,
    keyBlock        = Enum.KeyCode.B,
    keyKick         = Enum.KeyCode.K,
}

local SETTINGS_PATH = "civccpanel_settings.json"

local function saveSettings()
    pcall(function()
        writefile(SETTINGS_PATH, game:GetService("HttpService"):JSONEncode({
            speedMultiplier = Config.speedMultiplier,
            blockRange      = Config.blockRange,
            kickRange       = Config.kickRange,
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

-- ═══ Local character state ═════════════════════════════════════════════════

local Me = {
    char      = nil,
    humanoid  = nil,
    root      = nil,
    speedVal  = nil,
    combat    = nil,
    knocked   = nil,
    baseSpeed = nil,
}

local function inCombat()  return Me.combat  and Me.combat.Value  or false end
local function isKnocked() return Me.knocked and Me.knocked.Value or false end
local function alive()     return Me.humanoid and Me.humanoid.Health > 0 end

-- ═══ Shield driver ═════════════════════════════════════════════════════════
-- Shield is a RemoteFunction: InvokeServer yields. Firing it from multiple
-- places lets calls overlap and land out of order, which is what made the
-- shield flicker. One worker owns the remote and converges actual -> desired.

local Shield = { desired = false, actual = false, busy = false }

function Shield.set(state)
    Shield.desired = state
    if Shield.busy or Shield.actual == Shield.desired then return end
    Shield.busy = true
    task.spawn(function()
        while Shield.actual ~= Shield.desired do
            local target = Shield.desired
            local ok = pcall(function() shieldRem:InvokeServer(target) end)
            if ok then
                Shield.actual = target
            else
                task.wait(0.1)
            end
        end
        Shield.busy = false
    end)
end

-- ═══ Enemy animator registry ═══════════════════════════════════════════════
-- Rebuilt on spawn rather than searched every frame.

local Enemies = {}          -- [Player] = { char, root, animator, shielding, humanoid, hpFill }
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

local function isAttackTrack(track)
    local id = getTrackId(track)
    return id ~= 0 and ATTACK_ANIMS[id] == true
end

local function isKickTrack(track)
    return getTrackId(track) == KICK_ANIM_ID
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

local function bindEnemyChar(p, char)
    if not char then return end
    local entry = { char = char }
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
    end)
end

local function trackPlayer(p)
    if p == player then return end
    if p.Character then bindEnemyChar(p, p.Character) end
    p.CharacterAdded:Connect(function(char) bindEnemyChar(p, char) end)
    p.CharacterRemoving:Connect(function() Enemies[p] = nil end)
end

for _, p in ipairs(Players:GetPlayers()) do trackPlayer(p) end
Players.PlayerAdded:Connect(trackPlayer)
Players.PlayerRemoving:Connect(function(p) Enemies[p] = nil end)

-- ═══ Local character binding ═══════════════════════════════════════════════

local speedConn

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

local function bindCharacter(char)
    Me.char     = char
    Me.humanoid = nil
    Me.root     = nil
    Me.speedVal = nil
    Me.combat   = nil
    Me.knocked  = nil
    Me.baseSpeed = nil
    Me.lastWrite = nil
    Shield.actual  = false
    Shield.desired = false

    if speedConn then speedConn:Disconnect(); speedConn = nil end

    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        if Me.char ~= char then return end
        Me.humanoid = hum
        Me.root     = char:WaitForChild("HumanoidRootPart", 10)

        local pvpFolder = char:WaitForChild("Pvp", 10)
        if pvpFolder and Me.char == char then
            Me.combat  = pvpFolder:FindFirstChild("CombatMode")
            Me.knocked = pvpFolder:FindFirstChild("Knocked")
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

-- ═══ Auto block ════════════════════════════════════════════════════════════
-- Runs on RenderStepped. Every frame the desired shield state is derived from
-- scratch: is any enemy in range mid-attack-animation. Nothing accumulates, so
-- there is no counter to drift out of sync.

local threatCount = 0

RunService.RenderStepped:Connect(function()
    if not Config.autoBlock or not alive() or isKnocked() or not inCombat() or not Me.root then
        threatCount = 0
        Shield.set(false)
        return
    end

    local myPos = Me.root.Position
    local threats = 0
    local incomingKick = false

    for p, e in pairs(Enemies) do
        local root, animator = e.root, e.animator
        if root and animator and root.Parent then
            local dist = (root.Position - myPos).Magnitude
            if dist <= Config.blockRange then
                local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
                if ok then
                    for _, track in ipairs(tracks) do
                        if track.IsPlaying then
                            if isAttackTrack(track) then
                                threats += 1
                            elseif isKickTrack(track) and dist <= Config.kickRange + 4 then
                                incomingKick = true
                            end
                        end
                    end
                end
            end
        end
    end

    threatCount = threats
    -- Drop shield if a kick is incoming — blocking a kick gives the slow debuff
    if incomingKick and Shield.actual then
        Shield.set(false)
    else
        Shield.set(threats > 0)
    end
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

local PANEL_W, PANEL_H = 256, 350

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
verLabel.Text                   = "v3"
verLabel.TextColor3             = COL.dim
verLabel.Font                   = Enum.Font.GothamBold
verLabel.TextSize               = 10
verLabel.TextXAlignment         = Enum.TextXAlignment.Right
verLabel.Parent                 = titleBar

-- Body --------------------------------------------------------------------
-- Offset by 3px on left to clear the accent stripe
local body = Instance.new("Frame")
body.Size                 = UDim2.new(1, -3, 1, -38)
body.Position             = UDim2.fromOffset(3, 38)
body.BackgroundTransparency = 1
body.Parent               = frame

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
sectionLabel("MOVEMENT", 10)

local speedRead = Instance.new("TextLabel")
speedRead.Size                   = UDim2.new(1, -20, 0, 14)
speedRead.Position               = UDim2.fromOffset(9, 26)
speedRead.BackgroundTransparency = 1
speedRead.Text                   = "detecting base speed..."
speedRead.TextColor3             = COL.dim
speedRead.Font                   = Enum.Font.Gotham
speedRead.TextSize               = 11
speedRead.TextXAlignment         = Enum.TextXAlignment.Left
speedRead.Parent                 = body

local speedBox = Instance.new("TextBox")
speedBox.Size              = UDim2.new(1, -82, 0, 30)
speedBox.Position          = UDim2.fromOffset(9, 44)
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
applyBtn.Position         = UDim2.new(1, -73, 0, 44)
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

divider(86)

-- Combat ------------------------------------------------------------------
sectionLabel("COMBAT", 96)

local toggles = {}

local function makeToggle(name, key, y, get, set)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, -18, 0, 34)
    btn.Position         = UDim2.fromOffset(9, y)
    btn.BackgroundColor3 = COL.field
    btn.BorderSizePixel  = 1
    btn.BorderColor3     = COL.line
    btn.Text             = ""
    btn.AutoButtonColor  = false
    btn.Parent           = body

    -- Left status stripe that appears when ON
    local activeBar = Instance.new("Frame")
    activeBar.Size             = UDim2.fromOffset(3, 34)
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
    return btn
end

makeToggle("Auto Block", Config.keyBlock, 114,
    function() return Config.autoBlock end,
    function(v)
        Config.autoBlock = v
        if not v then Shield.set(false) end
    end)

makeToggle("Auto Kick", Config.keyKick, 154,
    function() return Config.autoKick end,
    function(v) Config.autoKick = v end)

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
    rail.Size             = UDim2.new(1, -18, 0, 8)
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

    local dragging = false
    local function apply(x)
        local a = math.clamp((x - rail.AbsolutePosition.X) / rail.AbsoluteSize.X, 0, 1)
        setV(math.floor(minV + a * (maxV - minV) + 0.5))
        render()
    end

    rail.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            apply(i.Position.X)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch) then
            apply(i.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            saveSettings()
        end
    end)

    render()
end

makeSlider("Block range", 200, 6, 40,
    function() return Config.blockRange end,
    function(v) Config.blockRange = v end)

makeSlider("Kick range", 238, 6, 30,
    function() return Config.kickRange end,
    function(v) Config.kickRange = v end)

divider(272)

-- Status strip ------------------------------------------------------------
local statusStrip = Instance.new("Frame")
statusStrip.Size             = UDim2.new(1, -18, 0, 30)
statusStrip.Position         = UDim2.fromOffset(9, 280)
statusStrip.BackgroundColor3 = COL.field
statusStrip.BorderSizePixel  = 1
statusStrip.BorderColor3     = COL.line
statusStrip.Parent           = body

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

-- Keybinds ----------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
    if processed or UserInputService:GetFocusedTextBox() then return end
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
    while task.wait(0.1) do
        if Me.baseSpeed then
            speedRead.Text = string.format("%.1f  →  %.1f studs/s",
                Me.baseSpeed, Me.baseSpeed * Config.speedMultiplier)
        end

        local text, colour
        if not alive() then
            text, colour = "DEAD", COL.dim
        elseif isKnocked() then
            text, colour = "KNOCKED", COL.alert
        elseif Shield.actual then
            text, colour = "BLOCKING  " .. threatCount .. " THREAT"
                        .. (threatCount == 1 and "" or "S"), COL.on
        elseif Config.autoBlock and inCombat() then
            text, colour = "ARMED  WATCHING", COL.accent
        elseif Config.autoBlock then
            text, colour = "ARMED  STANDBY", COL.dim
        else
            text, colour = "IDLE", COL.dim
        end
        status.Text                  = text
        status.TextColor3            = colour
        statusBar.BackgroundColor3   = colour
        statusStrip.BorderColor3     = colour ~= COL.dim and colour or COL.line
        chipStatus.Text              = Shield.actual and "BLK" or (Config.autoBlock and "ARM" or "OFF")
        chipStatus.TextColor3        = colour
    end
end)
