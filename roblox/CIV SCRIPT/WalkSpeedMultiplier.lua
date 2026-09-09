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

local Enemies = {}          -- [Player] = { char, root, animator, shielding }
local trackCache = setmetatable({}, { __mode = "k" })  -- [AnimationTrack] = bool

local function isAttackTrack(track)
    local cached = trackCache[track]
    if cached ~= nil then return cached end
    local result = false
    pcall(function()
        local id = tonumber(track.Animation.AnimationId:match("(%d+)%s*$"))
        result = id ~= nil and ATTACK_ANIMS[id] == true
    end)
    trackCache[track] = result
    return result
end

local function bindEnemyChar(p, char)
    if not char then return end
    local entry = { char = char }
    Enemies[p] = entry

    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        if not hum or Enemies[p] ~= entry then return end
        entry.animator = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)
        entry.root     = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 5)
        local pvpFolder = char:WaitForChild("Pvp", 10)
        if pvpFolder and Enemies[p] == entry then
            entry.shielding = pvpFolder:FindFirstChild("Shielding")
        end
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
    local target = Me.baseSpeed * Config.speedMultiplier
    if Me.speedVal then
        if math.abs(Me.speedVal.Value - target) > 0.01 then
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

    for p, e in pairs(Enemies) do
        local root, animator = e.root, e.animator
        if root and animator and root.Parent then
            if (root.Position - myPos).Magnitude <= Config.blockRange then
                local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
                if ok then
                    for _, track in ipairs(tracks) do
                        if track.IsPlaying and isAttackTrack(track) then
                            threats += 1
                            break
                        end
                    end
                end
            end
        end
    end

    threatCount = threats
    Shield.set(threats > 0)
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

local PANEL_W, PANEL_H = 250, 342
local COL = {
    bg      = Color3.fromRGB(16, 16, 18),
    bar     = Color3.fromRGB(26, 26, 30),
    field   = Color3.fromRGB(38, 38, 44),
    on      = Color3.fromRGB(0, 178, 92),
    accent  = Color3.fromRGB(0, 132, 255),
    text    = Color3.fromRGB(238, 238, 240),
    dim     = Color3.fromRGB(126, 126, 134),
    line    = Color3.fromRGB(52, 52, 58),
    alert   = Color3.fromRGB(255, 96, 96),
}

local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = inst
    return c
end

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

local frame = Instance.new("Frame")
frame.Size             = UDim2.fromOffset(PANEL_W, PANEL_H)
frame.Position         = UDim2.new(0, 24, 0.5, -PANEL_H / 2)
frame.BackgroundColor3 = COL.bg
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Parent           = screen
corner(frame, 10)

local stroke = Instance.new("UIStroke")
stroke.Color       = COL.line
stroke.Thickness   = 1
stroke.Transparency = 0.4
stroke.Parent      = frame

-- Title bar ---------------------------------------------------------------
local titleBar = Instance.new("Frame")
titleBar.Size             = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = COL.bar
titleBar.BorderSizePixel  = 0
titleBar.Parent           = frame
corner(titleBar, 10)

local barFill = Instance.new("Frame")
barFill.Size             = UDim2.new(1, 0, 0, 12)
barFill.Position         = UDim2.new(0, 0, 1, -12)
barFill.BackgroundColor3 = COL.bar
barFill.BorderSizePixel  = 0
barFill.Parent           = titleBar

local title = Instance.new("TextLabel")
title.Size                   = UDim2.new(1, -70, 1, 0)
title.Position               = UDim2.fromOffset(12, 0)
title.BackgroundTransparency = 1
title.Text                   = "CIV CC PANEL"
title.TextColor3             = COL.text
title.Font                   = Enum.Font.GothamBold
title.TextSize               = 14
title.TextXAlignment         = Enum.TextXAlignment.Left
title.Parent                 = titleBar

local minBtn = Instance.new("TextButton")
minBtn.Size              = UDim2.fromOffset(28, 22)
minBtn.Position          = UDim2.new(1, -36, 0, 7)
minBtn.BackgroundColor3  = COL.field
minBtn.BorderSizePixel   = 0
minBtn.Text              = "—"
minBtn.TextColor3        = COL.text
minBtn.Font              = Enum.Font.GothamBold
minBtn.TextSize          = 13
minBtn.AutoButtonColor   = false
minBtn.Parent            = titleBar
corner(minBtn, 5)

-- Body --------------------------------------------------------------------
local body = Instance.new("Frame")
body.Size                 = UDim2.new(1, 0, 1, -36)
body.Position             = UDim2.fromOffset(0, 36)
body.BackgroundTransparency = 1
body.Parent               = frame

local function sectionLabel(text, y)
    local l = Instance.new("TextLabel")
    l.Size                   = UDim2.new(1, -24, 0, 14)
    l.Position               = UDim2.fromOffset(12, y)
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
    d.Size             = UDim2.new(1, -24, 0, 1)
    d.Position         = UDim2.fromOffset(12, y)
    d.BackgroundColor3 = COL.line
    d.BorderSizePixel  = 0
    d.Parent           = body
    return d
end

-- Speed -------------------------------------------------------------------
sectionLabel("MOVEMENT", 10)

local speedRead = Instance.new("TextLabel")
speedRead.Size                   = UDim2.new(1, -24, 0, 14)
speedRead.Position               = UDim2.fromOffset(12, 26)
speedRead.BackgroundTransparency = 1
speedRead.Text                   = "detecting base speed..."
speedRead.TextColor3             = COL.dim
speedRead.Font                   = Enum.Font.Gotham
speedRead.TextSize               = 11
speedRead.TextXAlignment         = Enum.TextXAlignment.Left
speedRead.Parent                 = body

local speedBox = Instance.new("TextBox")
speedBox.Size              = UDim2.new(1, -84, 0, 28)
speedBox.Position          = UDim2.fromOffset(12, 46)
speedBox.BackgroundColor3  = COL.field
speedBox.BorderSizePixel   = 0
speedBox.Text              = tostring(Config.speedMultiplier)
speedBox.PlaceholderText   = "multiplier"
speedBox.TextColor3        = COL.text
speedBox.Font              = Enum.Font.Gotham
speedBox.TextSize          = 13
speedBox.ClearTextOnFocus  = false
speedBox.Parent            = body
corner(speedBox, 6)

local applyBtn = Instance.new("TextButton")
applyBtn.Size             = UDim2.fromOffset(60, 28)
applyBtn.Position         = UDim2.new(1, -72, 0, 46)
applyBtn.BackgroundColor3 = COL.accent
applyBtn.BorderSizePixel  = 0
applyBtn.Text             = "SET"
applyBtn.TextColor3       = COL.text
applyBtn.Font             = Enum.Font.GothamBold
applyBtn.TextSize         = 12
applyBtn.AutoButtonColor  = false
applyBtn.Parent           = body
corner(applyBtn, 6)

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
    btn.Size             = UDim2.new(1, -24, 0, 32)
    btn.Position         = UDim2.fromOffset(12, y)
    btn.BackgroundColor3 = COL.field
    btn.BorderSizePixel  = 0
    btn.Text             = ""
    btn.AutoButtonColor  = false
    btn.Parent           = body
    corner(btn, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -60, 1, 0)
    lbl.Position               = UDim2.fromOffset(10, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = name
    lbl.TextColor3             = COL.text
    lbl.Font                   = Enum.Font.GothamMedium
    lbl.TextSize               = 12
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = btn

    local hint = Instance.new("TextLabel")
    hint.Size                   = UDim2.fromOffset(46, 16)
    hint.Position               = UDim2.new(1, -54, 0.5, -8)
    hint.BackgroundColor3       = COL.bg
    hint.BorderSizePixel        = 0
    hint.Text                   = "[" .. key.Name .. "]"
    hint.TextColor3             = COL.dim
    hint.Font                   = Enum.Font.Gotham
    hint.TextSize               = 10
    hint.Parent                 = btn
    corner(hint, 4)

    local function render()
        local on = get()
        btn.BackgroundColor3 = on and COL.on or COL.field
        hint.BackgroundTransparency = on and 0.75 or 0
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

makeToggle("Auto Kick", Config.keyKick, 152,
    function() return Config.autoKick end,
    function(v) Config.autoKick = v end)

-- Sliders -----------------------------------------------------------------
local function makeSlider(name, y, minV, maxV, getV, setV)
    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -24, 0, 14)
    lbl.Position               = UDim2.fromOffset(12, y)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = name .. ": " .. getV()
    lbl.TextColor3             = COL.dim
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextSize               = 11
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = body

    local rail = Instance.new("Frame")
    rail.Size             = UDim2.new(1, -24, 0, 6)
    rail.Position         = UDim2.fromOffset(12, y + 18)
    rail.BackgroundColor3 = COL.field
    rail.BorderSizePixel  = 0
    rail.Active           = true
    rail.Parent           = body
    corner(rail, 3)

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = COL.accent
    fill.BorderSizePixel  = 0
    fill.Parent           = rail
    corner(fill, 3)

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

makeSlider("Block range", 194, 6, 40,
    function() return Config.blockRange end,
    function(v) Config.blockRange = v end)

makeSlider("Kick range", 232, 6, 30,
    function() return Config.kickRange end,
    function(v) Config.kickRange = v end)

divider(268)

-- Status ------------------------------------------------------------------
local status = Instance.new("TextLabel")
status.Size                   = UDim2.new(1, -24, 0, 16)
status.Position               = UDim2.fromOffset(12, 276)
status.BackgroundTransparency = 1
status.Text                   = "idle"
status.TextColor3             = COL.dim
status.Font                   = Enum.Font.GothamMedium
status.TextSize               = 11
status.TextXAlignment         = Enum.TextXAlignment.Left
status.Parent                 = body

-- Drag --------------------------------------------------------------------
-- Frame.Draggable is deprecated and unreliable once the GUI lives outside
-- PlayerGui, so the drag is driven directly off input events.
do
    local dragging, startPos, startInput
    titleBar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging   = true
            startPos   = frame.Position
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
        frame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y
        )
    end)
end

-- Minimize ----------------------------------------------------------------
local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    frame.Size   = minimized and UDim2.fromOffset(PANEL_W, 36)
                             or UDim2.fromOffset(PANEL_W, PANEL_H)
    minBtn.Text  = minimized and "+" or "—"
end)

-- Keybinds ----------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
    if processed or UserInputService:GetFocusedTextBox() then return end
    if input.KeyCode == Config.keyPanel then
        screen.Enabled = not screen.Enabled
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

-- Status feed -------------------------------------------------------------
task.spawn(function()
    while task.wait(0.1) do
        if Me.baseSpeed then
            speedRead.Text = string.format("%.1f  →  %.1f studs/s",
                Me.baseSpeed, Me.baseSpeed * Config.speedMultiplier)
        end

        local text, colour
        if not alive() then
            text, colour = "dead", COL.dim
        elseif isKnocked() then
            text, colour = "knocked", COL.alert
        elseif Shield.actual then
            text, colour = "BLOCKING · " .. threatCount .. " threat"
                        .. (threatCount == 1 and "" or "s"), COL.on
        elseif Config.autoBlock and inCombat() then
            text, colour = "armed · watching", COL.accent
        elseif Config.autoBlock then
            text, colour = "armed · out of combat", COL.dim
        else
            text, colour = "idle", COL.dim
        end
        status.Text      = text
        status.TextColor3 = colour
    end
end)
