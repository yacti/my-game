local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shovel = require(ReplicatedStorage.Shared:WaitForChild("Shovel"))

local Inventory = {}

-- Soft cap: normal pickups and grants refuse at this count.
Inventory.MAX_ITEMS = 250
-- Physical ceiling. Nothing may mint tools beyond this, whatever cap a caller
-- asks for: the per-spawn re-materialization in init.server.luau can only
-- rebuild this many, so tools granted above it are dropped on the next respawn
-- and then deleted from the profile by the following snapshot.
Inventory.HARD_MAX_ITEMS = 1500
-- The collect-all developer product grants up to the physical ceiling.
Inventory.COLLECT_ALL_MAX_ITEMS = Inventory.HARD_MAX_ITEMS

function Inventory.IsCountableTool(tool)
	return tool ~= nil
		and tool:IsA("Tool")
		and not Shovel.IsTool(tool)
end

-- Every tool the player currently holds: Backpack children plus every tool
-- parented to the character. Serializers must iterate this rather than taking
-- character:FindFirstChildWhichIsA("Tool") — the cap counter has always
-- counted every character tool, so a serializer that sees only the first one
-- under-counts and the next snapshot deletes the difference from the profile.
function Inventory.ForEachTool(player, callback)
	local backpack = player and player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") then
				callback(child)
			end
		end
	end

	local character = player and player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then
				callback(child)
			end
		end
	end
end

function Inventory.CountTools(player)
	local total = 0
	Inventory.ForEachTool(player, function(tool)
		if Inventory.IsCountableTool(tool) then
			total += 1
		end
	end)
	return total
end

function Inventory.RemainingSlots(player, maxItems)
	maxItems = tonumber(maxItems) or Inventory.MAX_ITEMS
	if type(maxItems) ~= "number" or maxItems ~= maxItems or math.abs(maxItems) == math.huge then
		maxItems = Inventory.MAX_ITEMS
	end
	maxItems = math.max(math.floor(maxItems), 0)
	return math.max(maxItems - Inventory.CountTools(player), 0)
end

return Inventory
