local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shovel = require(ReplicatedStorage.Shared:WaitForChild("Shovel"))

local Inventory = {}

Inventory.MAX_ITEMS = 250

function Inventory.IsCountableTool(tool)
	return tool ~= nil
		and tool:IsA("Tool")
		and not Shovel.IsTool(tool)
end

function Inventory.CountTools(player)
	local total = 0
	local function add(tool)
		if Inventory.IsCountableTool(tool) then
			total += 1
		end
	end

	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			add(child)
		end
	end

	local character = player and player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			add(child)
		end
	end

	return total
end

function Inventory.RemainingSlots(player)
	return math.max(Inventory.MAX_ITEMS - Inventory.CountTools(player), 0)
end

return Inventory
