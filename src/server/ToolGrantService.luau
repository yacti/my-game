local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))

local ToolGrantService = {}

local function shouldAutoEquip(options)
	return type(options) ~= "table" or options.autoEquip ~= false
end

local function equippedHumanoid(player)
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid
end

function ToolGrantService.EquipLatest(player, tool)
	if not (tool and tool:IsA("Tool")) then
		return false
	end
	local humanoid = equippedHumanoid(player)
	if not humanoid then
		return false
	end

	local ok = RuntimeGuard.Run("ToolGrantService.EquipLatest", function()
		humanoid:EquipTool(tool)
	end)
	return ok == true
end

function ToolGrantService.GrantTool(player, tool, options)
	if not (tool and tool:IsA("Tool")) then
		return false, "invalid-tool"
	end
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "no-backpack"
	end

	tool.Parent = backpack
	if shouldAutoEquip(options) then
		ToolGrantService.EquipLatest(player, tool)
	end
	return true
end

function ToolGrantService.GrantTools(player, tools, options)
	if type(tools) ~= "table" then
		return false, "invalid-tools"
	end
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return false, "no-backpack"
	end

	local latest = nil
	for _, tool in ipairs(tools) do
		if tool and tool:IsA("Tool") then
			tool.Parent = backpack
			latest = tool
		end
	end

	if latest and shouldAutoEquip(options) then
		ToolGrantService.EquipLatest(player, latest)
	end
	return true
end

return ToolGrantService
