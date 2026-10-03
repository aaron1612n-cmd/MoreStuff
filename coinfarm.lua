--[[
  Trio test button (one shot):
    Chest / InfectedChest  -> tp to nearest, grab
    Puffball               -> tp to nearest puffball, harvest, then grab the box it drops
  All ProximityPrompts are made instant (HoldDuration 0). Button text shows what happened.
--]]

local Players = game:GetService("Players")
local lp      = Players.LocalPlayer

local WANT = { chest = true, infectedchest = true, puffball = true }

-- ── instant prompts ───────────────────────────────────────────────────────────
for _, d in ipairs(workspace:GetDescendants()) do
    if d:IsA("ProximityPrompt") then d.HoldDuration = 0 end
end
workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then d.HoldDuration = 0 end
end)

-- ── helpers ───────────────────────────────────────────────────────────────────
-- wanted type of the nearest ancestor below Workspace named for the trio
local function trioType(inst)
    inst = inst.Parent
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

local function root()
    return lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
end

-- nearest enabled prompt of a wanted type; want = "grab" (Grab prompts) or "harvest" (any other prompt)
local function nearest(want)
    local hrp = root()
    if not hrp then return end
    local best, bestPart, bestDist, kind = nil, nil, math.huge, nil
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Enabled then
            local t = trioType(d)
            local isGrab = d.Name == "Grab"
            if t and ((want == "grab") == isGrab) then
                local part = partOf(d)
                local dist = part and (part.Position - hrp.Position).Magnitude
                if dist and dist < bestDist then best, bestPart, bestDist, kind = d, part, dist, t end
            end
        end
    end
    return best, bestPart, kind
end

local function fire(prompt, part)
    root().CFrame = part.CFrame * CFrame.new(0, 3, 0)
    task.wait(0.15)
    fireproximityprompt(prompt)
end

-- ── test run ──────────────────────────────────────────────────────────────────
local function run()
    local hrp = root()
    if not hrp then return "no character" end

    -- closest of: a ready box (Grab) or an unharvested puffball (other prompt)
    local gp, gpart, gkind = nearest("grab")
    local hp, hpart        = nearest("harvest")
    local gd = gpart and (gpart.Position - hrp.Position).Magnitude or math.huge
    local hd = hpart and (hpart.Position - hrp.Position).Magnitude or math.huge

    if gp and gd <= hd then
        fire(gp, gpart)
        return "grabbed " .. gkind .. ": " .. gp.Parent:GetFullName()
    end

    if hp then
        local at = hpart.Position
        local name = hp.Name
        fire(hp, hpart)
        -- harvest drops a box nearby; wait for its Grab prompt
        local t0 = os.clock()
        while os.clock() - t0 < 4 do
            task.wait(0.2)
            local p, part = nearest("grab")
            if p and (part.Position - at).Magnitude < 40 then
                fire(p, part)
                return "harvested (" .. name .. ") + grabbed " .. p.Parent:GetFullName()
            end
        end
        return "harvested (" .. name .. ") but no Grab prompt appeared"
    end

    -- nothing matched: report what prompts exist so the matcher can be fixed
    local names, n = {}, 0
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            n += 1
            names[d.Name .. "@" .. d.Parent.Name] = true
        end
    end
    local list = {}
    for k in pairs(names) do list[#list + 1] = k end
    table.sort(list)
    warn("[trio] prompts seen:", table.concat(list, ", "))
    return ("no trio found (%d prompts, see output)"):format(n)
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

local IDLE, busy = "TRIO: TP + GRAB NEAREST", false
btn.Text = IDLE
btn.MouseButton1Click:Connect(function()
    if busy then return end
    busy = true
    local ok, res = pcall(run)
    btn.Text = ok and res or ("error: " .. tostring(res))
    warn("[trio]", btn.Text)
    task.wait(3)
    btn.Text, busy = IDLE, false
end)
