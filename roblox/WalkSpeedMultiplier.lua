-- WalkSpeedMultiplier.lua
-- LocalScript — place in StarterPlayerScripts
-- Set MULTIPLIER to any number to scale your walk speed

local MULTIPLIER = 2  -- change this value

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")

local BASE_SPEED = 16  -- Roblox default walk speed

humanoid.WalkSpeed = BASE_SPEED * MULTIPLIER

-- Re-apply on respawn
player.CharacterAdded:Connect(function(newChar)
    local newHumanoid = newChar:WaitForChild("Humanoid")
    newHumanoid.WalkSpeed = BASE_SPEED * MULTIPLIER
end)
