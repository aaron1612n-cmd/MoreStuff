-- Dumps everything under Workspace.Huffencrag and Workspace.Peltsden to the bridge (read it with get_remotes filter "TOWN").
local HS = game:GetService("HttpService")
local req = (syn and syn.request) or (http and http.request) or request or http_request

local function post(name, lines)
    pcall(function()
        req({ Url = "http://127.0.0.1:7821", Method = "POST", Headers = { ["Content-Type"] = "application/json" },
              Body = HS:JSONEncode({ kind = "remote", name = name, path = "recon", remote_type = "town", args = lines }) })
    end)
end

for _, town in ipairs({ "Huffencrag", "Peltsden" }) do
    local root = workspace:FindFirstChild(town)
    local lines = {}
    if not root then
        lines[1] = "not loaded: Workspace." .. town
    else
        for _, d in ipairs(root:GetDescendants()) do
            local extra = ""
            if d:IsA("ProximityPrompt") then extra = (" [prompt %q/%q]"):format(d.ActionText, d.ObjectText) end
            if d:IsA("ClickDetector") then extra = " [click]" end
            if d:IsA("BasePart") then extra = (" pos=%d,%d,%d"):format(d.Position.X, d.Position.Y, d.Position.Z) end
            if d:IsA("ValueBase") then extra = " = " .. tostring(d.Value) end
            if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") or d:IsA("RemoteEvent") or d:IsA("RemoteFunction")
                or extra ~= "" then
                lines[#lines + 1] = d.ClassName .. " " .. d:GetFullName() .. extra
            end
        end
    end
    post("TOWN_" .. town, lines)
end
warn("[townrecon] sent")
