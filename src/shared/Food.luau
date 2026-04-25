-- Food registry. Templates live at ReplicatedStorage.Food.<FoodType> and must
-- carry an XP attribute. Food tools always carry a FoodType attribute and use
-- the food type as Tool.Name. Every system that consumes food (pet feeding,
-- processor input, inventory save) identifies food by attribute, never by
-- hardcoded name.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Food = {}

local folder
local function getFolder()
	folder = folder or ReplicatedStorage:WaitForChild("Food")
	return folder
end

function Food.GetTemplate(foodType)
	return getFolder():FindFirstChild(foodType)
end

function Food.BaseXP(foodType)
	local t = Food.GetTemplate(foodType)
	return t and (t:GetAttribute("XP") or 1) or 1
end

-- xpOverride lets Processor dispense food with a multiplier baked in.
function Food.MakeTool(foodType, xpOverride)
	local template = Food.GetTemplate(foodType)
	if not template then
		warn(string.format("[Food] No template for %q", tostring(foodType)))
		return nil
	end

	local tool          = Instance.new("Tool")
	tool.Name           = foodType
	tool.RequiresHandle = true

	local handle      = template:Clone()
	handle.Name       = "Handle"
	handle.Anchored   = false
	handle.CanCollide = true
	handle.CanQuery   = false  -- so the held food doesn't block ClickDetector raycasts
	handle.Massless   = true
	handle.Parent     = tool

	tool:SetAttribute("FoodType", foodType)
	tool:SetAttribute("XP", xpOverride or (template:GetAttribute("XP") or 1))
	return tool
end

function Food.IsFood(tool)
	return tool ~= nil
		and tool:IsA("Tool")
		and tool:GetAttribute("FoodType") ~= nil
end

local function equippedTool(player)
	local char = player.Character
	return char and char:FindFirstChildWhichIsA("Tool") or nil
end

function Food.FindFirstInBackpack(player, foodType)
	for _, item in pairs(player.Backpack:GetChildren()) do
		if Food.IsFood(item) and (foodType == nil or item:GetAttribute("FoodType") == foodType) then
			return item
		end
	end
	local eq = equippedTool(player)
	if eq and Food.IsFood(eq) and (foodType == nil or eq:GetAttribute("FoodType") == foodType) then
		return eq
	end
	return nil
end

-- Equipped-only variant: returns the player's currently held food Tool
-- (optionally filtered by FoodType) or nil. Used by Processor deposit, which
-- requires the player to be holding the food.
function Food.GetEquipped(player, foodType)
	local eq = equippedTool(player)
	if Food.IsFood(eq) and (foodType == nil or eq:GetAttribute("FoodType") == foodType) then
		return eq
	end
	return nil
end

function Food.CountByType(player)
	local counts = {}
	local function add(item)
		if Food.IsFood(item) then
			local t = item:GetAttribute("FoodType")
			counts[t] = (counts[t] or 0) + 1
		end
	end
	for _, item in pairs(player.Backpack:GetChildren()) do add(item) end
	add(equippedTool(player))
	return counts
end

return Food
