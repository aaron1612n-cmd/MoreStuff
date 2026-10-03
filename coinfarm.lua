--[[
  Chest test button (one shot): tp to the nearest Chest / InfectedChest and grab it.
  Prompts are made instant (HoldDuration 0). Button text shows what happened.
--]]

local Players = game:GetService("Players")
local lp      = Players.LocalPlayer

local WANT = { chest = true, infectedchest = true }

for _, d in ipairs(workspace:GetDescendants()) do
    if d:IsA("ProximityPrompt") then d.HoldDuration = 0 end
end
workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then d.HoldDuration = 0 end
end)

-- chest type of a box: its Info label text, else any ancestor below Workspace named for it
local function chestType(prompt)
    local box = prompt.Parent
    local info = box and box:FindFirstChild("Info")
    if info then
        for _, l in ipairs(info:GetDescendants()) do
            if l:IsA("TextLabel") then
                local txt = l.Text:lower():gsub("%s", "")
                for k in pairs(WANT) do if txt:find(k, 1, true) then return k end end
            end
        end
    end
    while box and box ~= workspace do
        if WANT[box.Name:lower()] then return box.Name:lower() end
        box = box.Parent
    end
end

local function partOf(prompt)
    local p = prompt.Parent
    if p:IsA("BasePart") then return p end
    return p:FindFirstChildWhichIsA("BasePart", true)
end

local function run()
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return "no character" end

    local best, bestPart, bestDist, kind = nil, nil, math.huge, nil
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "Grab" and d.Enabled then
            local t = chestType(d)
            local part = t and partOf(d)
            if part then
                local dist = (part.Position - hrp.Position).Magnitude
                if dist < bestDist then best, bestPart, bestDist, kind = d, part, dist, t end
            end
        end
    end

    if best then
        hrp.CFrame = bestPart.CFrame * CFrame.new(0, 3, 0)
        task.wait(0.15)
        fireproximityprompt(best)
        return "grabbed " .. kind .. ": " .. best.Parent:GetFullName()
    end

    -- nothing matched: send every Grab prompt (and its Info text) to the bridge so the matcher can be fixed
    local list = {}
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Name == "Grab" then
            local texts = {}
            local info = d.Parent:FindFirstChild("Info")
            if info then
                for _, l in ipairs(info:GetDescendants()) do
                    if l:IsA("TextLabel") then texts[#texts + 1] = l.Text end
                end
            end
            list[#list + 1] = d:GetFullName() .. " | info: " .. table.concat(texts, " / ")
        end
    end
    pcall(function()
        local req = (syn and syn.request) or (http and http.request) or request or http_request
        req({ Url = "http://127.0.0.1:7821", Method = "POST", Headers = { ["Content-Type"] = "application/json" },
              Body = game:GetService("HttpService"):JSONEncode({ kind = "remote", name = "PROMPTS", path = "chest", remote_type = "dump", args = list }) })
    end)
    return ("no chest found (%d Grab prompts, sent to bridge)"):format(#list)
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

local IDLE, busy = "CHEST: TP + GRAB NEAREST", false
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
