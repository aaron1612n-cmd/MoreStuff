--[[
  Chest + Puffball test buttons (one shot each):
    tp to the nearest world Chest / Infected Chest / Puffball prompt, open/harvest it, then grab the box it drops.
  Only boxes owned by you are grabbed. Prompts are made instant (HoldDuration 0).
--]]

local VERSION = 14 -- bump on every update
local STEP, MAX_CELLS = 300, 80 -- stream-sweep grid spacing (studs) and max cells per click

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
            local anc = d.Parent
            while anc and anc ~= workspace do
                if anc.Name:lower():find("puff", 1, true) then return true end
                anc = anc.Parent
            end
            return d.Parent:FindFirstChildOfClass("ParticleEmitter") ~= nil
                or txt:find("puff", 1, true) ~= nil or txt:find("harvest", 1, true) ~= nil
        end,
    },
}

-- every live ProximityPrompt, kept current by events so clicks never rescan the whole Workspace
local prompts = {}
local function track(d)
    if d:IsA("ProximityPrompt") then
        prompts[d] = true
        d.HoldDuration, d.MaxActivationDistance, d.RequiresLineOfSight = 0, 1e9, false
    end
end
task.spawn(function()
    for i, d in ipairs(workspace:GetDescendants()) do
        track(d)
        if i % 3000 == 0 then task.wait() end -- yield so the initial scan doesn't hitch
    end
end)
-- "Gameplay Paused": stop it at the source (StreamingPauseMode), and also hide the overlay if it still shows
pcall(function() workspace.StreamingPauseMode = Enum.StreamingPauseMode.Disabled end)
pcall(function() sethiddenproperty(workspace, "StreamingPauseMode", Enum.StreamingPauseMode.Disabled) end)

local function matchPause(d)
    return (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text:lower():find("paused", 1, true) ~= nil
end
local function hidePause(d)
    if not matchPause(d) then return end
    local g = d
    while g.Parent and not g.Parent:IsA("ScreenGui") do g = g.Parent end
    if g:IsA("GuiObject") then
        g.Visible = false
        g:GetPropertyChangedSignal("Visible"):Connect(function() -- Roblox flips it back on: keep it off
            if g.Visible then g.Visible = false end
        end)
    end
end
for _, d in ipairs(game:GetService("CoreGui"):GetDescendants()) do pcall(hidePause, d) end

-- re-running replaces the previous copy: drop its prompt hook and buttons
local genv = getgenv()
if genv._coinTestConn then genv._coinTestConn:Disconnect() end
genv._coinTestConn = workspace.DescendantAdded:Connect(track)
if genv._coinTestRemConn then genv._coinTestRemConn:Disconnect() end
genv._coinTestRemConn = workspace.DescendantRemoving:Connect(function(d) prompts[d] = nil end)
if genv._coinTestPauseConn then genv._coinTestPauseConn:Disconnect() end
genv._coinTestPauseConn = game:GetService("CoreGui").DescendantAdded:Connect(function(d)
    task.defer(pcall, hidePause, d) -- text is set after the label is parented
    if d:IsA("TextLabel") then d:GetPropertyChangedSignal("Text"):Connect(function() pcall(hidePause, d) end) end
end)
for _, parent in ipairs({ game:GetService("CoreGui"), lp:FindFirstChildOfClass("PlayerGui") }) do
    local old = parent and parent:FindFirstChild("_CoinTest")
    if old then old:Destroy() end
end

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
    for d in pairs(prompts) do
        if d.Enabled and pred(d) then
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
    local diag = ""

    local cp, cpart = nearest(kind.isPrompt)

    -- nothing loaded: with StreamingEnabled far parts don't exist on this client. Sweep a grid over the
    -- map (extents taken from the top-level models), streaming each cell in and looking again, nearest cell first.
    if not cp and workspace.StreamingEnabled then
        local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
        for _, c in ipairs(workspace:GetChildren()) do
            local ok, pos = pcall(function()
                return c:IsA("PVInstance") and c:GetPivot().Position or nil
            end)
            if ok and pos and not c:IsA("Terrain") and not Players:GetPlayerFromCharacter(c) then
                minX, maxX = math.min(minX, pos.X), math.max(maxX, pos.X)
                minZ, maxZ = math.min(minZ, pos.Z), math.max(maxZ, pos.Z)
            end
        end
        local here, cells = root().Position, {}
        for x = minX, maxX, STEP do
            for z = minZ, maxZ, STEP do cells[#cells + 1] = Vector3.new(x, here.Y, z) end
        end
        table.sort(cells, function(p, q) return (p - here).Magnitude < (q - here).Magnitude end)
        for i, pos in ipairs(cells) do
            if i > MAX_CELLS then break end
            pcall(function() lp:RequestStreamAroundAsync(pos, 1.5) end)
            cp, cpart = nearest(kind.isPrompt)
            if cp then break end
        end
        if not cp then
            diag = ("swept %d/%d cells, nothing"):format(math.min(#cells, MAX_CELLS), #cells)
        end
    end

    if not cp then
        local seen = {}
        for d in pairs(prompts) do
            if d.Name ~= "Grab" and (kind.isPrompt(d) or d.ActionText:lower():find(kind.word, 1, true)) then
                seen[#seen + 1] = d:GetFullName() .. " [" .. d.ActionText .. "] enabled=" .. tostring(d.Enabled)
            end
        end
        warn("[coinfarm] prompts seen:", table.concat(seen, " ; "))
        return ("no %s prompt enabled (%d seen) %s"):format(kind.word, #seen, diag)
    end

    local at = cpart.Position
    local label = cp.ActionText

    -- snapshot existing Grab prompts so the box this opens is the one that is new
    local before = {}
    for d in pairs(prompts) do
        if d.Name == "Grab" then before[d] = true end
    end
    fire(cp, cpart)

    local t0 = os.clock()
    while os.clock() - t0 < 6 do
        task.wait(0.2)
        local gp, gpart = nearest(function(d)
            local part = d.Name == "Grab" and not before[d] and partOf(d)
            return part and (part.Position - at).Magnitude < 80
        end)
        if gp then
            fire(gp, gpart)
            return "opened " .. label .. " + grabbed it"
        end
    end
    -- box may not be labelled as expected: report what Grab prompts of mine exist
    local mine = {}
    for d in pairs(prompts) do
        if d.Name == "Grab" then
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

makeButton(60,  "v" .. VERSION .. "  CHEST: TP + OPEN + GRAB",    KINDS.chest)
makeButton(102, "v" .. VERSION .. "  PUFFBALL: TP + HARVEST + GRAB", KINDS.puffball)
