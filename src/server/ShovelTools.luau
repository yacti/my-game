local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shovel = require(ReplicatedStorage.Shared:WaitForChild("Shovel"))
local ToolIdentity = require(ReplicatedStorage.Shared:WaitForChild("ToolIdentity"))

local ShovelTools = {}

local function findShovel(container)
	if not container then
		return nil
	end
	for _, child in ipairs(container:GetChildren()) do
		if Shovel.IsTool(child) then
			return child
		end
	end
	return nil
end

function ShovelTools.MakeTool()
	local template = ReplicatedStorage:WaitForChild(Shovel.ToolName)
	if not template:IsA("Tool") then
		warn("[ShovelTools] ReplicatedStorage.Shovel must be a Tool")
		return nil
	end

	local tool = template:Clone()
	tool.Name = Shovel.ToolName
	tool:SetAttribute(Shovel.ToolKindAttribute, Shovel.ToolKind)
	ToolIdentity.AssignGuid(tool)
	return tool
end

function ShovelTools.HasShovel(player)
	if not player then
		return false
	end
	return findShovel(player.Backpack) ~= nil or findShovel(player.Character) ~= nil
end

function ShovelTools.EnsureUtilityTool(player)
	if ShovelTools.HasShovel(player) then
		return true
	end

	local tool = ShovelTools.MakeTool()
	if not tool then
		return false
	end
	tool.Parent = player:WaitForChild("Backpack")
	return true
end

return ShovelTools
