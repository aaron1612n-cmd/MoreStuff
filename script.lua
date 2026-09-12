--[[
  SimpleSpy + Explorer  →  MCP Bridge
  ] : toggle GUI
  T : send explorer tree to bridge now
  Bridge: http://127.0.0.1:7821
--]]

local BRIDGE = "http://127.0.0.1:7821"
local HS     = game:GetService("HttpService")
local UIS    = game:GetService("UserInputService")
local lp     = game:GetService("Players").LocalPlayer

local bridgeActive = false

-- ── HTTP POST ─────────────────────────────────────────────────────────────────
local function post(payload)
    local ok = pcall(function()
        local body = HS:JSONEncode(payload)
        local req = (syn and syn.request) or (http and http.request) or request or http_request
        req({ Url=BRIDGE, Method="POST", Body=body,
              Headers={["Content-Type"]="application/json"} })
    end)
    if ok then bridgeActive = true end
    return ok
end

-- ── Suppress foreign GUIs ─────────────────────────────────────────────────────
local cg = game:GetService("CoreGui")
cg.DescendantAdded:Connect(function(d)
    if not d:IsA("ScreenGui") or d.Name == "_MCP_GUI" then return end
    local n = d.Name:lower()
    if n:find("spy") or n:find("remote") then d.Enabled = false end
end)

-- ── Explorer tree walker ───────────────────────────────────────────────────────
-- Walks the relevant services to a fixed depth, sends to bridge.
-- Skips CoreGui and anything with 100+ children to keep size sane.
local SERVICES = {
    "Workspace", "Players", "Lighting", "ReplicatedStorage",
    "ReplicatedFirst", "StarterGui", "StarterPack", "StarterPlayer",
    "Teams", "SoundService", "TextChatService", "RunService",
}
local MAX_DEPTH = 4
local MAX_CHILDREN = 80

local function walkNode(inst, depth)
    local node = { name=inst.Name, class=inst.ClassName }
    if depth < MAX_DEPTH then
        local children = inst:GetChildren()
        if #children > 0 and #children <= MAX_CHILDREN then
            node.children = {}
            for _, child in ipairs(children) do
                local ok, child_node = pcall(walkNode, child, depth + 1)
                if ok then
                    table.insert(node.children, child_node)
                end
            end
        elseif #children > MAX_CHILDREN then
            node.children_count = #children
            node.children_truncated = true
        end
    end
    return node
end

local function sendTree()
    local tree = {}
    for _, svcName in ipairs(SERVICES) do
        local ok, svc = pcall(function() return game:GetService(svcName) end)
        if ok and svc then
            local ok2, node = pcall(walkNode, svc, 0)
            if ok2 then tree[svcName] = node end
        end
    end
    post({ kind="tree", tree=tree })
end

-- Send tree on load, then every 30s
task.spawn(function()
    task.wait(3) -- let game load
    sendTree()
    while true do
        task.wait(30)
        sendTree()
    end
end)

-- ── Load SimpleSpy, tap its hook ──────────────────────────────────────────────
task.spawn(function()
    local src = game:HttpGet("https://github.com/exxtremestuffs/SimpleSpySource/raw/master/SimpleSpy.lua")
    local fn, err = loadstring(src)
    if not fn then warn("[MCP] SimpleSpy:", err); return end
    pcall(fn)

    for _ = 1, 20 do
        task.wait(0.5)
        if type(_G.SimpleSpy) == "table" then break end
    end
    if type(_G.SimpleSpy) ~= "table" then
        warn("[MCP] SimpleSpy hook table not found"); return
    end

    for _, k in ipairs({ "Hook", "OnRemote", "Callback", "Fire" }) do
        if type(_G.SimpleSpy[k]) == "function" then
            local orig = _G.SimpleSpy[k]
            _G.SimpleSpy[k] = function(remote, method, args, ...)
                task.spawn(function()
                    local name, path = "?", "?"
                    pcall(function() name = tostring(remote.Name) end)
                    pcall(function() path = remote:GetFullName() end)
                    post({ kind="remote", name=name, path=path, remote_type=tostring(method) })
                end)
                return orig(remote, method, args, ...)
            end
            break
        end
    end
end)

-- ── Probe loop ────────────────────────────────────────────────────────────────
task.spawn(function()
    while true do
        if not post({ kind="ping" }) then bridgeActive = false end
        task.wait(4)
    end
end)

-- ── GUI ───────────────────────────────────────────────────────────────────────
local screen = Instance.new("ScreenGui")
screen.Name         = "_MCP_GUI"
screen.ResetOnSpawn = false
screen.DisplayOrder = 9999
pcall(function() screen.Parent = cg end)
if screen.Parent ~= cg then screen.Parent = lp:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size             = UDim2.new(0, 152, 0, 36)
frame.Position         = UDim2.new(0, 12, 0, 12)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Parent           = screen
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 5)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(45, 45, 55); stroke.Thickness = 1

local dot = Instance.new("Frame", frame)
dot.Size             = UDim2.new(0, 7, 0, 7)
dot.Position         = UDim2.new(0, 10, 0.5, -3.5)
dot.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
dot.BorderSizePixel  = 0
Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

local lbl = Instance.new("TextLabel", frame)
lbl.Size                 = UDim2.new(1, -26, 1, 0)
lbl.Position             = UDim2.new(0, 24, 0, 0)
lbl.BackgroundTransparency = 1
lbl.Text                 = "MCP  OFFLINE"
lbl.TextColor3           = Color3.fromRGB(90, 90, 100)
lbl.TextSize             = 11
lbl.Font                 = Enum.Font.Code
lbl.TextXAlignment       = Enum.TextXAlignment.Left

task.spawn(function()
    while task.wait(1) do
        if bridgeActive then
            dot.BackgroundColor3 = Color3.fromRGB(40, 210, 110)
            lbl.Text             = "MCP  ACTIVE"
            lbl.TextColor3       = Color3.fromRGB(40, 210, 110)
        else
            dot.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
            lbl.Text             = "MCP  OFFLINE"
            lbl.TextColor3       = Color3.fromRGB(90, 90, 100)
        end
    end
end)

-- Drag
local drag, ds, sp = false, nil, nil
frame.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        drag=true; ds=i.Position; sp=frame.Position
    end
end)
frame.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then drag=false end
end)
UIS.InputChanged:Connect(function(i)
    if drag and i.UserInputType == Enum.UserInputType.MouseMovement then
        local d = i.Position - ds
        frame.Position = UDim2.new(sp.X.Scale, sp.X.Offset+d.X, sp.Y.Scale, sp.Y.Offset+d.Y)
    end
end)

-- Keybinds
UIS.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == Enum.KeyCode.RightBracket then
        screen.Enabled = not screen.Enabled
    elseif i.KeyCode == Enum.KeyCode.T then
        task.spawn(sendTree)
    end
end)
