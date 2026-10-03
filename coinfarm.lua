--[[
  Box grabber: Chest, InfectedChest, Puffball
  [ : toggle farm
  Teleports to each matching box in Workspace and fires its Grab prompt.
  Delivery step is not automated yet (waiting on recon of the paying remote).
--]]

local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local lp      = Players.LocalPlayer

local WANT = { chest = true, infectedchest = true, puffball = true }
local on = true

-- a box matches if it or any ancestor below Workspace is named for a wanted type
local function boxType(prompt)
    local inst = prompt.Parent
    while inst and inst ~= workspace do
        local n = inst.Name:lower()
        if WANT[n] then return n end
        inst = inst.Parent
    end
end

local function grab(prompt)
    local part = prompt.Parent
    if not part:IsA("BasePart") then part = part:FindFirstChildWhichIsA("BasePart", true) end
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (part and hrp) then return end
    hrp.CFrame = part.CFrame * CFrame.new(0, 3, 0)
    task.wait(0.15)
    fireproximityprompt(prompt)
end

UIS.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == Enum.KeyCode.LeftBracket then
        on = not on
        warn("[coinfarm]", on and "ON" or "OFF")
    end
end)

task.spawn(function()
    while task.wait(0.5) do
        if not on then continue end
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Name == "Grab" and d.Enabled and boxType(d) then
                pcall(grab, d)
                task.wait(0.4)
                if not on then break end
            end
        end
    end
end)
