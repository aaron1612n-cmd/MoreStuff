-- CIV CC PANEL
-- LocalScript — place in StarterPlayerScripts
-- Civilization Survival: speed hack + auto block + auto kick

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local player     = Players.LocalPlayer
local playerGui  = player:WaitForChild("PlayerGui")

-- ─── Remotes ───────────────────────────────────────────────────────────────
local pvp      = game.ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Pvp")
local shieldRem = pvp:WaitForChild("Shield")   -- InvokeServer(bool)
local kickRem   = pvp:WaitForChild("Kick")     -- FireServer()

-- ─── State ─────────────────────────────────────────────────────────────────
local speedMultiplier = 2
local baseSpeed       = nil
local autoBlockOn     = false
local autoKickOn      = false
local blocking        = false
local blockCooldown   = false
local KICK_RANGE      = 14

-- ─── Character helpers ─────────────────────────────────────────────────────
local function getChar()    return player.Character end
local function getHum()     local c = getChar(); return c and c:FindFirstChild("Humanoid") end
local function getSpeedVal() local c = getChar(); return c and c:FindFirstChild("WalkSpeed") end
local function getRoot()    local c = getChar(); return c and c:FindFirstChild("HumanoidRootPart") end

local function isInCombat()
    local c = getChar()
    if not c then return false end
    local pvpFolder = c:FindFirstChild("Pvp")
    return pvpFolder and pvpFolder:FindFirstChild("CombatMode") and pvpFolder.CombatMode.Value
end

-- ─── Speed ─────────────────────────────────────────────────────────────────
local function snapshotBase()
    local wsVal = getSpeedVal()
    if wsVal and wsVal.Value > 0 then baseSpeed = wsVal.Value; return end
    local hum = getHum()
    if hum then baseSpeed = hum.WalkSpeed > 0 and hum.WalkSpeed or 8 end
end

local function applySpeed()
    if not baseSpeed then return end
    local wsVal = getSpeedVal()
    if wsVal then
        wsVal.Value = baseSpeed * speedMultiplier
    else
        local hum = getHum()
        if hum then hum.WalkSpeed = baseSpeed * speedMultiplier end
    end
end

local function onCharAdded()
    baseSpeed = nil
    blocking = false
    blockCooldown = false
    task.delay(1, function() snapshotBase(); applySpeed() end)
end

player.CharacterAdded:Connect(onCharAdded)
task.delay(1, function() snapshotBase(); applySpeed() end)

task.spawn(function()
    while task.wait(0.1) do applySpeed() end
end)

-- ─── Auto Block ─────────────────────────────────────────────────────────────
-- Strategy: watch humanoid.HealthChanged — the moment HP drops, invoke shield.
-- Unblock after 0.6s with no further hits (or immediately if already blocking).

local lastHit = 0

local function doBlock(state)
    if blocking == state then return end
    blocking = state
    pcall(function() shieldRem:InvokeServer(state) end)
end

local function onHealthChanged()
    if not autoBlockOn then return end
    if not isInCombat() then return end
    lastHit = tick()
    if not blockCooldown then
        doBlock(true)
    end
end

local function autoBlockLoop()
    while task.wait(0.05) do
        if autoBlockOn and blocking then
            if tick() - lastHit > 0.6 then
                doBlock(false)
            end
        end
    end
end

-- ─── Auto Kick ─────────────────────────────────────────────────────────────
-- Fire Kick when an enemy within KICK_RANGE has their shield up (Shielding.Value=true)

local function autoKickLoop()
    while task.wait(0.15) do
        if not autoKickOn then continue end
        if not isInCombat() then continue end
        local root = getRoot()
        if not root then continue end
        for _, p in ipairs(Players:GetPlayers()) do
            if p == player then continue end
            local c = p.Character
            if not c then continue end
            local theirRoot = c:FindFirstChild("HumanoidRootPart")
            if not theirRoot then continue end
            if (theirRoot.Position - root.Position).Magnitude > KICK_RANGE then continue end
            local pvpF = c:FindFirstChild("Pvp")
            local shielding = pvpF and pvpF:FindFirstChild("Shielding")
            if shielding and shielding.Value then
                pcall(function() kickRem:FireServer() end)
                break
            end
        end
    end
end

task.spawn(autoBlockLoop)
task.spawn(autoKickLoop)

-- Hook health changes on current and future characters
local healthConn
local function hookHealth(char)
    if healthConn then healthConn:Disconnect() end
    local hum = char:WaitForChild("Humanoid")
    healthConn = hum.HealthChanged:Connect(onHealthChanged)
end

player.CharacterAdded:Connect(hookHealth)
if player.Character then
    task.spawn(function() hookHealth(player.Character) end)
end

-- ─── GUI ───────────────────────────────────────────────────────────────────
local screen = Instance.new("ScreenGui")
screen.Name        = "CivCCPanel"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 999
screen.Parent      = playerGui

local frame = Instance.new("Frame")
frame.Size            = UDim2.new(0, 240, 0, 240)
frame.Position        = UDim2.new(0, 20, 0.5, -120)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
frame.BorderSizePixel = 0
frame.Active   = true
frame.Draggable = true
frame.Parent   = screen
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

local function makeLabel(text, y, size, color)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, size or 30)
    l.Position = UDim2.new(0, 0, 0, y)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = color or Color3.fromRGB(220, 220, 220)
    l.Font = Enum.Font.GothamBold
    l.TextSize = size or 14
    l.Parent = frame
    return l
end

local function makeToggle(label, y, onToggle)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -20, 0, 32)
    btn.Position = UDim2.new(0, 10, 0, y)
    btn.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    btn.BorderSizePixel = 0
    btn.Text = label .. ": OFF"
    btn.TextColor3 = Color3.fromRGB(200, 200, 200)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.Parent = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    local state = false
    btn.MouseButton1Click:Connect(function()
        state = not state
        btn.Text = label .. (state and ": ON" or ": OFF")
        btn.BackgroundColor3 = state and Color3.fromRGB(0, 180, 80) or Color3.fromRGB(50, 50, 50)
        onToggle(state)
    end)
    return btn
end

-- Title
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 34)
titleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
titleBar.BorderSizePixel = 0
titleBar.Parent = frame
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)
local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, 0, 1, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "CIV CC PANEL"
titleLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 15
titleLbl.Parent = titleBar

-- Speed section
local speedInfo = Instance.new("TextLabel")
speedInfo.Size = UDim2.new(1, -10, 0, 16)
speedInfo.Position = UDim2.new(0, 5, 0, 38)
speedInfo.BackgroundTransparency = 1
speedInfo.Text = "base: detecting..."
speedInfo.TextColor3 = Color3.fromRGB(130, 130, 130)
speedInfo.Font = Enum.Font.Gotham
speedInfo.TextSize = 11
speedInfo.TextXAlignment = Enum.TextXAlignment.Left
speedInfo.Parent = frame

local speedBox = Instance.new("TextBox")
speedBox.Size = UDim2.new(1, -20, 0, 28)
speedBox.Position = UDim2.new(0, 10, 0, 58)
speedBox.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
speedBox.BorderSizePixel = 0
speedBox.Text = tostring(speedMultiplier)
speedBox.PlaceholderText = "Speed multiplier"
speedBox.TextColor3 = Color3.fromRGB(255, 255, 255)
speedBox.Font = Enum.Font.Gotham
speedBox.TextSize = 13
speedBox.ClearTextOnFocus = false
speedBox.Parent = frame
Instance.new("UICorner", speedBox).CornerRadius = UDim.new(0, 6)

local speedBtn = Instance.new("TextButton")
speedBtn.Size = UDim2.new(1, -20, 0, 26)
speedBtn.Position = UDim2.new(0, 10, 0, 92)
speedBtn.BackgroundColor3 = Color3.fromRGB(0, 140, 255)
speedBtn.BorderSizePixel = 0
speedBtn.Text = "Apply Speed"
speedBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
speedBtn.Font = Enum.Font.GothamBold
speedBtn.TextSize = 13
speedBtn.Parent = frame
Instance.new("UICorner", speedBtn).CornerRadius = UDim.new(0, 6)

speedBtn.MouseButton1Click:Connect(function()
    local val = tonumber(speedBox.Text)
    if val and val > 0 then
        speedMultiplier = val
        speedBtn.Text = "Applied!"
        task.delay(1, function() speedBtn.Text = "Apply Speed" end)
    else
        speedBtn.Text = "Invalid!"
        task.delay(1, function() speedBtn.Text = "Apply Speed" end)
    end
end)

-- Divider
local div = Instance.new("Frame")
div.Size = UDim2.new(1, -20, 0, 1)
div.Position = UDim2.new(0, 10, 0, 128)
div.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
div.BorderSizePixel = 0
div.Parent = frame

-- Toggles
makeToggle("Auto Block", 136, function(s)
    autoBlockOn = s
    if not s then doBlock(false) end
end)

makeToggle("Auto Kick", 176, function(s)
    autoKickOn = s
end)

-- Status label
local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1, -10, 0, 14)
statusLbl.Position = UDim2.new(0, 5, 0, 218)
statusLbl.BackgroundTransparency = 1
statusLbl.Text = ""
statusLbl.TextColor3 = Color3.fromRGB(100, 200, 100)
statusLbl.Font = Enum.Font.Gotham
statusLbl.TextSize = 11
statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.Parent = frame

task.spawn(function()
    while task.wait(0.25) do
        if baseSpeed then
            speedInfo.Text = string.format("base: %.1f  →  %.1f", baseSpeed, baseSpeed * speedMultiplier)
        end
        local parts = {}
        if blocking then parts[#parts+1] = "BLOCKING" end
        if autoKickOn then parts[#parts+1] = "KICK ON" end
        statusLbl.Text = table.concat(parts, "  |  ")
    end
end)
