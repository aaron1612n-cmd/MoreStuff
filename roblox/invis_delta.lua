--=====================================================================
-- roblox/invis_delta.lua
-- Delta executor — root-parking desync, GUI toggles.
--
--   1. Net Desync   root parked at a fixed anchor       [root channel]
--   2. Under Map    root parked below you, tracking     [root channel]
--=====================================================================

local CONFIG = {
    GUI_NAME      = "InvisGUI",
    RESYNC_KEY    = Enum.KeyCode.R,
    RESYNC_FRAMES = 15,
    RESYNC_JITTER = 0.02,
    UNDER_DEPTH   = 32,
    DESTROY_CLEAR = 32,
}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local lp         = Players.LocalPlayer

local gethui = gethui

local Char = {
    model  = nil,
    hum    = nil,
    hrp    = nil,
    onChar = {},
}

function Char.bind(model)
    Char.model = model
    Char.hum   = model:FindFirstChildOfClass("Humanoid")
    Char.hrp   = model:FindFirstChild("HumanoidRootPart")
    for _, fn in ipairs(Char.onChar) do
        local ok, err = pcall(fn, model)
        if not ok then warn("[Invis] onChar:", err) end
    end
end

function Char.start()
    if lp.Character then Char.bind(lp.Character) end
    lp.CharacterAdded:Connect(function(model)
        model:WaitForChild("HumanoidRootPart", 10)
        task.wait()
        Char.bind(model)
    end)
end

local function alive()
    local hrp, hum = Char.hrp, Char.hum
    if not (hrp and hrp.Parent) then return false, nil end
    if not (hum and hum.Health > 0) then return false, nil end
    return true, hrp
end

local host = (gethui and gethui()) or game:GetService("CoreGui")
local old  = host:FindFirstChild(CONFIG.GUI_NAME)
if old then old:Destroy() end

local sg = Instance.new("ScreenGui")
sg.Name           = CONFIG.GUI_NAME
sg.ResetOnSpawn   = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
sg.Parent         = host

local frame = Instance.new("Frame")
frame.Size             = UDim2.new(0, 250, 0, 134)
frame.Position         = UDim2.new(0, 12, 0.5, -67)
frame.BackgroundColor3 = Color3.fromRGB(16, 16, 18)
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Draggable        = true
frame.Parent           = sg
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size                   = UDim2.new(1, 0, 0, 26)
titleLbl.BackgroundTransparency = 1
titleLbl.Text                   = "Invisibility  ·  Delta"
titleLbl.TextColor3             = Color3.fromRGB(215, 215, 220)
titleLbl.Font                   = Enum.Font.GothamBold
titleLbl.TextSize               = 12
titleLbl.Parent                 = frame

local OFF_BG = Color3.fromRGB(38, 38, 42)

local function makeBtn(label, yOff, onColor)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, -20, 0, 32)
    btn.Position         = UDim2.new(0, 10, 0, yOff)
    btn.BackgroundColor3 = OFF_BG
    btn.BorderSizePixel  = 0
    btn.AutoButtonColor  = false
    btn.Text             = label .. "   OFF"
    btn.TextColor3       = Color3.fromRGB(172, 172, 178)
    btn.Font             = Enum.Font.Gotham
    btn.TextSize         = 12
    btn.Parent           = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

    return btn, function(on)
        btn.Text             = label .. (on and "   ON" or "   OFF")
        btn.BackgroundColor3 = on and onColor or OFF_BG
        btn.TextColor3       = on and Color3.fromRGB(245, 245, 245)
                                  or Color3.fromRGB(172, 172, 178)
    end
end

local btnDesync, paintDesync = makeBtn("Net Desync", 30, Color3.fromRGB(150, 74, 0))
local btnUnder,  paintUnder  = makeBtn("Under Map",  66, Color3.fromRGB(132, 0, 78))

local status = Instance.new("TextLabel")
status.Size                   = UDim2.new(1, -20, 0, 20)
status.Position               = UDim2.new(0, 10, 0, 106)
status.BackgroundTransparency = 1
status.Text                   = "idle"
status.TextColor3             = Color3.fromRGB(118, 118, 126)
status.TextXAlignment         = Enum.TextXAlignment.Left
status.Font                   = Enum.Font.Code
status.TextSize               = 11
status.Parent                 = frame

local Flush = {
    conn   = nil,
    left   = 0,
    jitter = CONFIG.RESYNC_JITTER,
}

function Flush.stop()
    if Flush.conn then Flush.conn:Disconnect(); Flush.conn = nil end
    Flush.left = 0
end

function Flush.start()
    Flush.left = CONFIG.RESYNC_FRAMES
    if Flush.conn then return end
    Flush.conn = RunService.Heartbeat:Connect(function()
        local hrp = Char.hrp
        if Flush.left <= 0 or not (hrp and hrp.Parent) then
            Flush.stop()
            return
        end
        Flush.left  -= 1
        Flush.jitter = -Flush.jitter
        hrp.CFrame = hrp.CFrame + Vector3.new(0, Flush.jitter, 0)
    end)
end

local Park = {
    on        = false,
    mode      = nil,
    fixed     = nil,
    real      = nil,
    realVel   = nil,
    realAng   = nil,
    realState = nil,
    restored  = false,
    holdKey   = false,
    hold      = 0,
    jitter    = CONFIG.RESYNC_JITTER,
    off       = 0,
    heart     = nil,
    step      = nil,
    bound     = false,
}

local GROUNDED = {
    [Enum.HumanoidStateType.Running]          = true,
    [Enum.HumanoidStateType.RunningNoPhysics] = true,
}

local function parkTarget(realCF)
    if Park.mode == "under" then
        local rootY  = realCF.Position.Y
        local floorY = workspace.FallenPartsDestroyHeight + CONFIG.DESTROY_CLEAR
        local y = math.min(math.max(rootY - CONFIG.UNDER_DEPTH, floorY), rootY - 4)
        return CFrame.new(realCF.Position.X, y, realCF.Position.Z)
    end
    return Park.fixed
end

local function parkRestore(withVelocity)
    local hrp = Char.hrp
    if not (Park.on and hrp and hrp.Parent and Park.real) then return end

    hrp.CFrame = Park.real
    if withVelocity then
        if Park.realVel then hrp.AssemblyLinearVelocity  = Park.realVel end
        if Park.realAng then hrp.AssemblyAngularVelocity = Park.realAng end
    end

    local hum = Char.hum
    if hum and Park.realState and GROUNDED[Park.realState]
        and hum:GetState() ~= Park.realState
    then
        hum:ChangeState(Park.realState)
    end

    Park.restored = true
end

local function parkRestoreRender()  parkRestore(false) end
local function parkRestorePhysics() parkRestore(true)  end

local function parkDown()
    local ok, hrp = alive()
    if not ok then return end

    local restored = Park.restored
    Park.restored  = false
    if restored then
        Park.real    = hrp.CFrame
        Park.realVel = hrp.AssemblyLinearVelocity
        Park.realAng = hrp.AssemblyAngularVelocity
    end
    if not Park.real then return end

    Park.realState = Char.hum and Char.hum:GetState() or nil

    if Park.holdKey or Park.hold > 0 then
        if not Park.holdKey then Park.hold -= 1 end
        Park.off = 0
        if Park.hold == 0 and not Park.holdKey and Park.mode == "anchor" then
            Park.fixed = Park.real
        end
        Park.jitter = -Park.jitter
        hrp.CFrame  = Park.real + Vector3.new(0, Park.jitter, 0)
        return
    end

    local target = parkTarget(Park.real)
    if not target then return end
    hrp.CFrame = target
    Park.off   = (target.Position - Park.real.Position).Magnitude
end

local function parkOnChar()
    Park.real, Park.realVel, Park.realAng = nil, nil, nil
    Park.realState, Park.restored = nil, false
    if Park.mode == "anchor" then
        Park.fixed = Char.hrp and Char.hrp.CFrame or nil
    end
end

local function parkStart(mode)
    if Park.on then return end

    local ok, hrp = alive()
    if not ok then error("no character", 0) end

    Flush.stop()

    Park.mode      = mode
    Park.fixed     = hrp.CFrame
    Park.real      = hrp.CFrame
    Park.realVel   = hrp.AssemblyLinearVelocity
    Park.realAng   = hrp.AssemblyAngularVelocity
    Park.realState = Char.hum and Char.hum:GetState() or nil
    Park.restored  = false
    Park.hold      = 0
    Park.off       = 0
    Park.on        = true

    local bindOk, err = pcall(function()
        Park.heart = RunService.Heartbeat:Connect(parkDown)
        Park.step  = RunService.Stepped:Connect(parkRestorePhysics)
        RunService:BindToRenderStep("InvisPark", Enum.RenderPriority.First.Value, parkRestoreRender)
        Park.bound = true
    end)
    if not bindOk then
        Park.on = false
        if Park.heart then Park.heart:Disconnect(); Park.heart = nil end
        if Park.step  then Park.step:Disconnect();  Park.step  = nil end
        if Park.bound then
            pcall(function() RunService:UnbindFromRenderStep("InvisPark") end)
            Park.bound = false
        end
        error(err, 0)
    end
end

local function parkStop()
    if not Park.on then return end
    Park.on = false

    if Park.heart then Park.heart:Disconnect() end
    if Park.step  then Park.step:Disconnect()  end
    Park.heart, Park.step = nil, nil
    if Park.bound then
        pcall(function() RunService:UnbindFromRenderStep("InvisPark") end)
        Park.bound = false
    end

    local hrp = Char.hrp
    if hrp and hrp.Parent and Park.real then
        hrp.CFrame = Park.real
        if Park.realVel then hrp.AssemblyLinearVelocity  = Park.realVel end
        if Park.realAng then hrp.AssemblyAngularVelocity = Park.realAng end
        Flush.start()
    end

    Park.mode, Park.fixed, Park.real = nil, nil, nil
    Park.realVel, Park.realAng, Park.realState = nil, nil, nil
    Park.restored = false
    Park.holdKey, Park.hold, Park.off = false, 0, 0
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe or not Park.on then return end
    if input.KeyCode == CONFIG.RESYNC_KEY then Park.holdKey = true end
end)

UIS.InputEnded:Connect(function(input)
    if input.KeyCode ~= CONFIG.RESYNC_KEY then return end
    Park.holdKey = false
    Park.hold    = CONFIG.RESYNC_FRAMES
end)

local desyncOn, underOn = false, false

local function desyncStart() parkStart("anchor"); desyncOn = true end
local function desyncStop()  desyncOn = false; parkStop() end
local function underStart()  parkStart("under");  underOn  = true end
local function underStop()   underOn  = false; parkStop() end

table.insert(Char.onChar, parkOnChar)
Char.start()

local function bind(btn, paint, start, stop, guard)
    local on = false
    btn.MouseButton1Click:Connect(function()
        if not on and guard then
            local msg = guard()
            if msg then status.Text = msg; return end
        end
        on = not on
        local ok, err = pcall(on and start or stop)
        if not ok then
            warn("[Invis]", err)
            status.Text = tostring(err):sub(1, 34)
            on = not on
            return
        end
        paint(on)
    end)
end

bind(btnDesync, paintDesync, desyncStart, desyncStop, function()
    if underOn then return "turn Under Map off first" end
    if not lp.Character then return "no character" end
end)
bind(btnUnder, paintUnder, underStart, underStop, function()
    if desyncOn then return "turn Net Desync off first" end
    if not lp.Character then return "no character" end
end)

local statusClock = 0
RunService.Heartbeat:Connect(function(dt)
    if not Park.on then
        status.Text = "idle"
        return
    end

    if Park.holdKey or Park.hold > 0 then
        status.Text = "RESYNC — true position sent"
        return
    end

    statusClock += dt
    if statusClock < 0.1 then return end
    statusClock = 0

    status.Text = string.format("%s sent %.0fst off  [hold %s]",
        Park.mode, Park.off, CONFIG.RESYNC_KEY.Name)
end)
