-- infinitespeed.lua
-- Sets MaxSpeed = 1e9 on every VehicleSeat (A-Chassis + native seats)
-- and patches A-Chassis Tune modules so the chassis script doesn't re-clamp.
-- Includes draggable speedometer HUD.

local SPEED  = 1e9
local ws     = game:GetService("Workspace")
local lp     = game:GetService("Players").LocalPlayer
local UIS    = game:GetService("UserInputService")
local RS     = game:GetService("RunService")

-- ── MaxSpeed patching ─────────────────────────────────────────────────────────

local function patchTune(car)
    local tune = car:FindFirstChild("A-Chassis Tune", true)
               or car:FindFirstChild("Tune", true)
    if not tune then return end
    pcall(function()
        local tbl = require(tune)
        if type(tbl) ~= "table" then return end
        if tbl.MaxSpeed  ~= nil then tbl.MaxSpeed  = SPEED end
        -- zero all deceleration sources
        for _, k in ipairs({
            "AeroDrag","CorneringDrag","EngineBrake","RollResist",
            "BrakePower","ParkBrake","Drag","FrictionCoef",
        }) do
            if tbl[k] ~= nil then tbl[k] = 0 end
        end
    end)
end

-- override ACS speed cap and preserve speed
local _bv, _lv, _lastCar = nil, nil, nil

local function getCarRoot(car)
    return car.PrimaryPart
        or car:FindFirstChild("Chassis")
        or car:FindFirstChild("Body")
        or car:FindFirstChildWhichIsA("BasePart")
end

local ZERO3 = Vector3.zero

RS.Heartbeat:Connect(function()
    pcall(function()
        local char = lp.Character
        if not char then _bv=nil; _lv=nil; _lastCar=nil; return end
        local seat = char:FindFirstChildOfClass("VehicleSeat")
        if not seat then _bv=nil; _lv=nil; _lastCar=nil; return end
        local car  = seat.Parent
        local root = getCarRoot(car)
        if not root then return end

        -- every frame: neuter ALL ACS velocity constraints so they can't cap us
        for _, v in ipairs(car:GetDescendants()) do
            if v ~= _bv and v ~= _lv then
                if v:IsA("BodyVelocity") then
                    pcall(function() v.MaxForce = ZERO3 end)
                elseif v:IsA("LinearVelocity") then
                    pcall(function() v.MaxForce = 0 end)
                end
            end
        end

        -- inject our BodyVelocity once
        if not _bv or not _bv.Parent then
            _bv          = Instance.new("BodyVelocity")
            _bv.Name     = "_ISbv"
            _bv.MaxForce = Vector3.new(1e9, 0, 1e9)
            _bv.P        = 1e9
            _bv.Parent   = root
        end

        local vel = root.AssemblyLinearVelocity
        local spd = vel.Magnitude
        local wDown = UIS:IsKeyDown(Enum.KeyCode.W) or UIS:IsKeyDown(Enum.KeyCode.Up)

        if wDown then
            local look = ws.CurrentCamera.CFrame.LookVector
            local dir  = Vector3.new(look.X, 0, look.Z).Unit
            _bv.Velocity = dir * math.max(spd + 5, 50)
        elseif spd > 0.5 then
            _bv.Velocity = vel
        else
            _bv.Velocity = ZERO3
        end
    end)
end)

local function patchSeats(inst)
    for _, v in ipairs(inst:GetDescendants()) do
        if v:IsA("VehicleSeat") then
            pcall(function() v.MaxSpeed = SPEED end)
            patchTune(v.Parent or inst)
        end
    end
end

patchSeats(ws)

ws.DescendantAdded:Connect(function(d)
    if d:IsA("VehicleSeat") then
        task.defer(function()
            pcall(function() d.MaxSpeed = SPEED end)
            patchTune(d.Parent or ws)
        end)
    end
end)

-- ── Speedometer GUI ───────────────────────────────────────────────────────────

local screen = Instance.new("ScreenGui")
screen.Name         = "_SpeedoGui"
screen.ResetOnSpawn = false
screen.DisplayOrder = 9999
screen.Parent       = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size             = UDim2.new(0, 120, 0, 44)
frame.Position         = UDim2.new(0.5, -60, 1, -70)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Parent           = screen
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(45, 45, 55); stroke.Thickness = 1

local speedLbl = Instance.new("TextLabel", frame)
speedLbl.Size                 = UDim2.new(1, 0, 0.55, 0)
speedLbl.Position             = UDim2.new(0, 0, 0, 4)
speedLbl.BackgroundTransparency = 1
speedLbl.Text                 = "0"
speedLbl.TextColor3           = Color3.fromRGB(240, 240, 240)
speedLbl.TextSize             = 20
speedLbl.Font                 = Enum.Font.GothamBold
speedLbl.TextXAlignment       = Enum.TextXAlignment.Center

local unitLbl = Instance.new("TextLabel", frame)
unitLbl.Size                  = UDim2.new(1, 0, 0.35, 0)
unitLbl.Position              = UDim2.new(0, 0, 0.62, 0)
unitLbl.BackgroundTransparency = 1
unitLbl.Text                  = "SPS"
unitLbl.TextColor3            = Color3.fromRGB(80, 80, 95)
unitLbl.TextSize              = 11
unitLbl.Font                  = Enum.Font.Code
unitLbl.TextXAlignment        = Enum.TextXAlignment.Center

-- drag
local drag, ds, sp = false, nil, nil
frame.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        drag = true; ds = i.Position; sp = frame.Position
    end
end)
frame.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
end)
UIS.InputChanged:Connect(function(i)
    if drag and i.UserInputType == Enum.UserInputType.MouseMovement then
        local d = i.Position - ds
        frame.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
    end
end)

-- speed readout: use VehicleSeat velocity when seated, else HRP
RS.Heartbeat:Connect(function()
    local spd = 0
    pcall(function()
        local char = lp.Character
        if not char then return end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        -- prefer the seat's assembly velocity if in a vehicle
        local seat = char:FindFirstChildOfClass("Seat") or char:FindFirstChildOfClass("VehicleSeat")
        if seat then
            spd = math.floor(seat.AssemblyLinearVelocity.Magnitude)
        else
            spd = math.floor(hrp.AssemblyLinearVelocity.Magnitude)
        end
    end)
    speedLbl.Text = tostring(spd)
end)

print("[infinitespeed] done — MaxSpeed = " .. SPEED)
