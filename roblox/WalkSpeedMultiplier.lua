-- WalkSpeedMultiplier.lua
-- LocalScript — place in StarterPlayerScripts

local BASE_SPEED = 16
local multiplier = 2

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function getHumanoid()
    local char = player.Character
    return char and char:FindFirstChild("Humanoid")
end

local function applySpeed()
    local hum = getHumanoid()
    if hum then hum.WalkSpeed = BASE_SPEED * multiplier end
end

player.CharacterAdded:Connect(function(char)
    local hum = char:WaitForChild("Humanoid")
    hum.WalkSpeed = BASE_SPEED * multiplier
end)

-- GUI
local screen = Instance.new("ScreenGui")
screen.Name = "SpeedGui"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 220, 0, 110)
frame.Position = UDim2.new(0, 20, 0.5, -55)
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

local box = Instance.new("TextBox")
box.Size = UDim2.new(1, -20, 0, 32)
box.Position = UDim2.new(0, 10, 0, 38)
box.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
box.BorderSizePixel = 0
box.Text = tostring(multiplier)
box.PlaceholderText = "Enter multiplier"
box.TextColor3 = Color3.fromRGB(255, 255, 255)
box.Font = Enum.Font.Gotham
box.TextSize = 14
box.ClearTextOnFocus = false
box.Parent = frame
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(1, -20, 0, 28)
btn.Position = UDim2.new(0, 10, 0, 76)
btn.BackgroundColor3 = Color3.fromRGB(0, 150, 255)
btn.BorderSizePixel = 0
btn.Text = "Apply"
btn.TextColor3 = Color3.fromRGB(255, 255, 255)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 14
btn.Parent = frame
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

btn.MouseButton1Click:Connect(function()
    local val = tonumber(box.Text)
    if val and val > 0 then
        multiplier = val
        applySpeed()
        btn.Text = "Applied!"
        task.delay(1, function() btn.Text = "Apply" end)
    else
        btn.Text = "Invalid!"
        task.delay(1, function() btn.Text = "Apply" end)
    end
end)

applySpeed()
