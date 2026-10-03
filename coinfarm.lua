--[[
  Test button: finds the nearest Chest / InfectedChest / Puffball box in Workspace and grabs it once.
  Label shows what it found, or why not.
--]]

local Players = game:GetService("Players")
local lp      = Players.LocalPlayer

local WANT = { chest = true, infectedchest = true, puffball = true }

-- a box matches if it or any ancestor below Workspace is named for a wanted type
local function boxType(prompt)
    local inst = prompt.Parent
    while inst and inst ~= workspace do
        local n = inst.Name:lower()
        if WANT[n] then return n end
        inst = inst.Parent
    end
end

local function partOf(prompt)
    local p = prompt.Parent
    if p:IsA("BasePart") then return p end
    return p:FindFirstChildWhichIsA("BasePart", true)
end

local function grabNearest()
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return "no character" end

    local best, bestPart, bestDist, seen = nil, nil, math.huge, 0
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "Grab" then
            seen += 1
            local part = d.Enabled and boxType(d) and partOf(d)
            if part then
                local dist = (part.Position - hrp.Position).Magnitude
                if dist < bestDist then best, bestPart, bestDist = d, part, dist end
            end
        end
    end
    if not best then return ("no match (%d Grab prompts seen)"):format(seen) end

    hrp.CFrame = bestPart.CFrame * CFrame.new(0, 3, 0)
    task.wait(0.15)
    fireproximityprompt(best)
    return "grabbed " .. best.Parent:GetFullName()
end

-- ── GUI ───────────────────────────────────────────────────────────────────────
local screen = Instance.new("ScreenGui")
screen.Name, screen.ResetOnSpawn, screen.DisplayOrder = "_CoinTest", false, 9999
pcall(function() screen.Parent = game:GetService("CoreGui") end)
if not screen.Parent then screen.Parent = lp:WaitForChild("PlayerGui") end

local btn = Instance.new("TextButton")
btn.Size, btn.Position = UDim2.new(0, 260, 0, 36), UDim2.new(0, 12, 0, 60)
btn.BackgroundColor3, btn.BorderSizePixel = Color3.fromRGB(14, 14, 18), 0
btn.TextColor3, btn.TextSize, btn.Font = Color3.fromRGB(220, 220, 230), 12, Enum.Font.Code
btn.Text = "GRAB NEAREST BOX"
btn.Parent = screen
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

local busy = false
btn.MouseButton1Click:Connect(function()
    if busy then return end
    busy = true
    local ok, res = pcall(grabNearest)
    btn.Text = ok and res or ("error: " .. tostring(res))
    warn("[coinfarm]", btn.Text)
    task.wait(2)
    btn.Text, busy = "GRAB NEAREST BOX", false
end)
