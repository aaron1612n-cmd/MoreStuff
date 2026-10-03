--[[
  Chest test button (one shot):
    tp to the nearest world Chest / Infected Chest prompt, open it, then grab the box it drops.
  Only boxes owned by you are grabbed. Prompts are made instant (HoldDuration 0).
--]]

local Players = game:GetService("Players")
local lp      = Players.LocalPlayer

-- world chests are plain ProximityPrompts (e.g. Workspace.Resources.CrashedFreighter.Box) with ActionText "Chest"
local function isChestPrompt(d)
    local a = d.ActionText:lower()
    return d.Name ~= "Grab" and (a == "chest" or a == "infected chest")
end

for _, d in ipairs(workspace:GetDescendants()) do
    if d:IsA("ProximityPrompt") then d.HoldDuration = 0 end
end
workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then d.HoldDuration = 0 end
end)

local function root()
    return lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
end

local function partOf(prompt)
    local p = prompt.Parent
    if p:IsA("BasePart") then return p end
    return p:FindFirstChildWhichIsA("BasePart", true)
end

-- Info label text of a box: { "CHEST", "5 Kg", "OwnerName" }
local function infoTexts(box)
    local out = {}
    local info = box:FindFirstChild("Info")
    if info then
        for _, l in ipairs(info:GetDescendants()) do
            if l:IsA("TextLabel") then out[#out + 1] = l.Text end
        end
    end
    return out
end

-- nearest enabled prompt satisfying pred(prompt); returns prompt, part
local function nearest(pred)
    local hrp = root()
    local best, bestPart, bestDist = nil, nil, math.huge
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Enabled and pred(d) then
            local part = partOf(d)
            local dist = part and (part.Position - hrp.Position).Magnitude
            if dist and dist < bestDist then best, bestPart, bestDist = d, part, dist end
        end
    end
    return best, bestPart
end

local function fire(prompt, part)
    root().CFrame = part.CFrame * CFrame.new(0, 3, 0)
    task.wait(0.15)
    fireproximityprompt(prompt)
end

-- a Grab prompt on a chest box that belongs to me
local function myChestGrab(d)
    if d.Name ~= "Grab" then return false end
    local t = infoTexts(d.Parent)
    return (t[1] or ""):lower():find("chest", 1, true) ~= nil and t[3] == lp.Name
end

local function run()
    if not root() then return "no character" end

    local cp, cpart = nearest(isChestPrompt)
    if not cp then
        local seen = {}
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.ActionText:lower():find("chest", 1, true) then
                seen[#seen + 1] = d:GetFullName() .. " [" .. d.ActionText .. "] enabled=" .. tostring(d.Enabled)
            end
        end
        warn("[chest] chest prompts seen:", table.concat(seen, " ; "))
        return ("no chest prompt enabled (%d chest-ish prompts seen)"):format(#seen)
    end

    local at = cpart.Position
    local label = cp.ActionText
    fire(cp, cpart)

    -- opening drops a box; wait for its Grab prompt (owned by me, near the chest)
    local t0 = os.clock()
    while os.clock() - t0 < 4 do
        task.wait(0.2)
        local gp, gpart = nearest(myChestGrab)
        if gp and (gpart.Position - at).Magnitude < 60 then
            fire(gp, gpart)
            return "opened " .. label .. " + grabbed it"
        end
    end
    return "opened " .. label .. " but no Grab prompt of mine appeared"
end

-- ── GUI ───────────────────────────────────────────────────────────────────────
local screen = Instance.new("ScreenGui")
screen.Name, screen.ResetOnSpawn, screen.DisplayOrder = "_CoinTest", false, 9999
pcall(function() screen.Parent = game:GetService("CoreGui") end)
if not screen.Parent then screen.Parent = lp:WaitForChild("PlayerGui") end

local btn = Instance.new("TextButton")
btn.Size, btn.Position = UDim2.new(0, 300, 0, 36), UDim2.new(0, 12, 0, 60)
btn.BackgroundColor3, btn.BorderSizePixel = Color3.fromRGB(14, 14, 18), 0
btn.TextColor3, btn.TextSize, btn.Font = Color3.fromRGB(220, 220, 230), 11, Enum.Font.Code
btn.TextWrapped = true
btn.Parent = screen
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

local IDLE, busy = "CHEST: TP + OPEN + GRAB", false
btn.Text = IDLE
btn.MouseButton1Click:Connect(function()
    if busy then return end
    busy = true
    local ok, res = pcall(run)
    btn.Text = ok and res or ("error: " .. tostring(res))
    warn("[chest]", btn.Text)
    task.wait(3)
    btn.Text, busy = IDLE, false
end)
