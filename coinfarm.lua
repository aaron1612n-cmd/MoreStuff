--[[
  Chest + Puffball test buttons (one shot each):
    tp to the nearest world Chest / Infected Chest / Puffball prompt, open/harvest it, then grab the box it drops.
  Only boxes owned by you are grabbed. Prompts are made instant (HoldDuration 0).
--]]

local Players = game:GetService("Players")
local lp      = Players.LocalPlayer

-- world chests are plain ProximityPrompts (e.g. Workspace.Resources.CrashedFreighter.Box) with ActionText "Chest";
-- puffballs have no known text, so match the template signature (prompt on a part with a ParticleEmitter) or "puff"/"harvest" text
local KINDS = {
    chest = {
        word = "chest",
        isPrompt = function(d)
            local a = d.ActionText:lower()
            return d.Name ~= "Grab" and (a == "chest" or a == "infected chest")
        end,
    },
    puffball = {
        word = "puff",
        isPrompt = function(d)
            if d.Name == "Grab" then return false end
            local txt = (d.ActionText .. d.ObjectText):lower()
            return d.Parent:FindFirstChildOfClass("ParticleEmitter") ~= nil
                or txt:find("puff", 1, true) ~= nil or txt:find("harvest", 1, true) ~= nil
        end,
    },
}

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

-- a Grab prompt on a box of this kind that belongs to me
local function myBoxGrab(word)
    return function(d)
        if d.Name ~= "Grab" then return false end
        local t = infoTexts(d.Parent)
        return (t[1] or ""):lower():find(word, 1, true) ~= nil and t[3] == lp.Name
    end
end

local function run(kind)
    if not root() then return "no character" end

    local cp, cpart = nearest(kind.isPrompt)
    if not cp then
        local seen = {}
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Name ~= "Grab" and (kind.isPrompt(d) or d.ActionText:lower():find(kind.word, 1, true)) then
                seen[#seen + 1] = d:GetFullName() .. " [" .. d.ActionText .. "] enabled=" .. tostring(d.Enabled)
            end
        end
        warn("[coinfarm] prompts seen:", table.concat(seen, " ; "))
        return ("no %s prompt enabled (%d seen)"):format(kind.word, #seen)
    end

    local at = cpart.Position
    local label = cp.ActionText
    fire(cp, cpart)

    -- opening drops a box; wait for its Grab prompt (owned by me, near the spot)
    local t0 = os.clock()
    while os.clock() - t0 < 4 do
        task.wait(0.2)
        local gp, gpart = nearest(myBoxGrab(kind.word))
        if gp and (gpart.Position - at).Magnitude < 60 then
            fire(gp, gpart)
            return "opened " .. label .. " + grabbed it"
        end
    end
    -- box may not be labelled as expected: report what Grab prompts of mine exist
    local mine = {}
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "Grab" then
            local t = infoTexts(d.Parent)
            if t[3] == lp.Name then mine[#mine + 1] = table.concat(t, "/") end
        end
    end
    warn("[coinfarm] my boxes:", table.concat(mine, " ; "))
    return "opened " .. label .. " but no matching Grab appeared (my boxes: " .. #mine .. ", see output)"
end

-- ── GUI ───────────────────────────────────────────────────────────────────────
local screen = Instance.new("ScreenGui")
screen.Name, screen.ResetOnSpawn, screen.DisplayOrder = "_CoinTest", false, 9999
pcall(function() screen.Parent = game:GetService("CoreGui") end)
if not screen.Parent then screen.Parent = lp:WaitForChild("PlayerGui") end

local busy = false
local function makeButton(y, idle, kind)
    local btn = Instance.new("TextButton")
    btn.Size, btn.Position = UDim2.new(0, 300, 0, 36), UDim2.new(0, 12, 0, y)
    btn.BackgroundColor3, btn.BorderSizePixel = Color3.fromRGB(14, 14, 18), 0
    btn.TextColor3, btn.TextSize, btn.Font = Color3.fromRGB(220, 220, 230), 11, Enum.Font.Code
    btn.TextWrapped = true
    btn.Text = idle
    btn.Parent = screen
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
    btn.MouseButton1Click:Connect(function()
        if busy then return end
        busy = true
        local ok, res = pcall(run, kind)
        btn.Text = ok and res or ("error: " .. tostring(res))
        warn("[coinfarm]", btn.Text)
        task.wait(3)
        btn.Text, busy = idle, false
    end)
end

makeButton(60,  "CHEST: TP + OPEN + GRAB",    KINDS.chest)
makeButton(102, "PUFFBALL: TP + HARVEST + GRAB", KINDS.puffball)
