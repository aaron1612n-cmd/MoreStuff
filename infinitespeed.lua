-- infinitespeed.lua
-- Sets MaxSpeed = 1e9 on every VehicleSeat (A-Chassis + native seats)
-- and patches A-Chassis Tune modules so the chassis script doesn't re-clamp.

local SPEED = 1e9
local ws    = game:GetService("Workspace")

-- patch A-Chassis Tune table in the required module cache
local function patchTune(car)
    -- ACS tune is usually named "A-Chassis Tune" or "Tune" directly in the car
    local tune = car:FindFirstChild("A-Chassis Tune", true)
               or car:FindFirstChild("Tune", true)
    if not tune then return end
    -- executor getcustomasset / getreg trick to get required module table
    pcall(function()
        local tbl = require(tune)
        if type(tbl) == "table" and tbl.MaxSpeed ~= nil then
            tbl.MaxSpeed = SPEED
        end
    end)
end

-- patch every VehicleSeat on a given instance + its Tune module if it's a car
local function patchSeats(inst)
    for _, v in ipairs(inst:GetDescendants()) do
        if v:IsA("VehicleSeat") then
            pcall(function() v.MaxSpeed = SPEED end)
            patchTune(v.Parent or inst)
        end
    end
end

-- initial pass
patchSeats(ws)

-- catch newly added cars / seats
ws.DescendantAdded:Connect(function(d)
    if d:IsA("VehicleSeat") then
        task.defer(function()  -- defer so parent is set
            pcall(function() d.MaxSpeed = SPEED end)
            patchTune(d.Parent or ws)
        end)
    end
end)

print("[infinitespeed] done — MaxSpeed = " .. SPEED)
