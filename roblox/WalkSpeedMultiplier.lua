-- WalkSpeedMultiplier.lua
-- LocalScript — place in StarterPlayerScripts
-- For games that use a WalkSpeed NumberValue in the character (e.g. Civilization Survival)
-- Falls back to humanoid.WalkSpeed for standard games

local multiplier = 2

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local baseSpeed = nil  -- snapshotted from game's own value on load

local function getChar()
    return player.Character
end

local function getSpeedValue()
    local char = getChar()
    return char and char:FindFirstChild("WalkSpeed")  -- NumberValue the game uses
end

local function getHumanoid()
    local char = getChar()
    return char and char:FindFirstChild("Humanoid")
end

local function snapshotBase()
    local wsVal = getSpeedValue()
    if wsVal and wsVal.Value > 0 then
        baseSpeed = wsVal.Value
        return
    end
    local hum = getHumanoid()
    if hum then
        baseSpeed = hum.WalkSpeed > 0 and hum.WalkSpeed or 8
    end
end

local function applySpeed()
    if not baseSpeed then return end
    local wsVal = getSpeedValue()
    if wsVal then
        wsVal.Value = baseSpeed * multiplier
    else
        local hum = getHumanoid()
        if hum then hum.WalkSpeed = baseSpeed * multiplier end
    end
end

-- On respawn: wait for server to set initial values, then snapshot and apply
local function onCharAdded(char)
    baseSpeed = nil
    task.delay(1, function()  -- give server time to assign WalkSpeed.Value
        snapshotBase()
        applySpeed()
    end)
end

player.CharacterAdded:Connect(onCharAdded)

-- Initial setup
task.delay(1, function()
    snapshotBase()
    applySpeed()
end)

-- Loop: re-enforce every 0.1s (game tries to reduce speed in combat, crouching, etc.)
task.spawn(function()
    while task.wait(0.1) do
        applySpeed()
    end
end)

-- GUI
local screen = Instance.new("ScreenGui")
screen.Name = "SpeedGui"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 230, 0, 130)
frame.Position = UDim2.new(0, 20, 0.5, -65)
frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = screen
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
title.BorderSizePixel = 0
title.Text = "Speed Multiplier"
title.TextColor3 = Color3.fromRGB(220, 220, 220)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = frame
Instance.new("UICorner", title).CornerRadius = UDim.new(0, 8)

local infoLabel = Instance.new("TextLabel")
infoLabel.Size = UDim2.new(1, -10, 0, 18)
infoLabel.Position = UDim2.new(0, 5, 0, 32)
infoLabel.BackgroundTransparency = 1
infoLabel.Text = "base: detecting..."
infoLabel.TextColor3 = Color3.fromRGB(160, 160, 160)
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 11
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.Parent = frame

local box = Instance.new("TextBox")
box.Size = UDim2.new(1, -20, 0, 30)
box.Position = UDim2.new(0, 10, 0, 54)
box.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
box.BorderSizePixel = 0
box.Text = tostring(multiplier)
box.PlaceholderText = "Multiplier"
box.TextColor3 = Color3.fromRGB(255, 255, 255)
box.Font = Enum.Font.Gotham
box.TextSize = 14
box.ClearTextOnFocus = false
box.Parent = frame
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(1, -20, 0, 28)
btn.Position = UDim2.new(0, 10, 0, 92)
btn.BackgroundColor3 = Color3.fromRGB(0, 150, 255)
btn.BorderSizePixel = 0
btn.Text = "Apply"
btn.TextColor3 = Color3.fromRGB(255, 255, 255)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 14
btn.Parent = frame
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

-- Update info label periodically
task.spawn(function()
    while task.wait(0.5) do
        if baseSpeed then
            infoLabel.Text = string.format("base: %.1f  →  target: %.1f", baseSpeed, baseSpeed * multiplier)
        else
            infoLabel.Text = "base: detecting..."
        end
    end
end)

btn.MouseButton1Click:Connect(function()
    local val = tonumber(box.Text)
    if val and val > 0 then
        multiplier = val
        btn.Text = "Applied!"
        task.delay(1, function() btn.Text = "Apply" end)
    else
        btn.Text = "Invalid!"
        task.delay(1, function() btn.Text = "Apply" end)
    end
end)
