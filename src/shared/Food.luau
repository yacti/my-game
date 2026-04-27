-- Food registry. Templates live at ReplicatedStorage.Food (recursively;
-- per-machine subfolders are supported, e.g. Food/Timed/Food3_Timed) and
-- must carry an XP attribute. A template may be either a BasePart (legacy)
-- or a Model (preferred — supports multi-part visuals and Model:ScaleTo).
-- Food tools always carry a FoodType attribute and use the food type as
-- Tool.Name. Every system that consumes food (pet feeding, processor
-- input, inventory save) identifies food by attribute, never by name.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Food = {}

local folder
local function getFolder()
	folder = folder or ReplicatedStorage:WaitForChild("Food")
	return folder
end

-- Foods are organized into per-machine subfolders (Food/Clicker, Food/Timed,
-- Food/Processor, etc.) so the lookup recurses.
function Food.GetTemplate(foodType)
	return getFolder():FindFirstChild(foodType, true)
end

function Food.BaseXP(foodType)
	local t = Food.GetTemplate(foodType)
	return t and (t:GetAttribute("XP") or 1) or 1
end

local function configureBodyPart(part, isHandle)
	part.Anchored   = false
	part.CanCollide = isHandle  -- only the handle collides; sub-parts shouldn't push the player around
	part.CanQuery   = false     -- so the held food doesn't block ClickDetector raycasts
	part.Massless   = true
end

-- xpOverride lets Processor dispense food with a multiplier baked in.
-- Templates can be BaseParts or Models. Model templates use their
-- PrimaryPart as the Tool's Handle; sibling parts get welded to it so the
-- Tool keeps RequiresHandle semantics while still showing the full visual.
function Food.MakeTool(foodType, xpOverride)
	local template = Food.GetTemplate(foodType)
	if not template then
		warn(string.format("[Food] No template for %q", tostring(foodType)))
		return nil
	end

	local tool          = Instance.new("Tool")
	tool.Name           = foodType
	tool.RequiresHandle = true

	if template:IsA("BasePart") then
		local handle = template:Clone()
		handle.Name = "Handle"
		configureBodyPart(handle, true)
		handle.Parent = tool
	elseif template:IsA("Model") then
		if not template.PrimaryPart then
			warn(string.format("[Food] Model template %q has no PrimaryPart", foodType))
			return nil
		end
		local clone  = template:Clone()
		local handle = clone.PrimaryPart
		handle.Name  = "Handle"
		configureBodyPart(handle, true)

		-- Reparent the Handle to the Tool, then weld every sibling part to
		-- it so the visual moves as one rigid body when held.
		handle.Parent = tool
		for _, p in ipairs(clone:GetDescendants()) do
			if p:IsA("BasePart") then
				configureBodyPart(p, false)
				p.Parent = tool
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = handle
				weld.Part1 = p
				weld.Parent = p
			end
		end
		clone:Destroy()
	else
		warn(string.format("[Food] Unsupported template class %q for %s", template.ClassName, foodType))
		return nil
	end

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
