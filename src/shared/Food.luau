-- Food registry. Templates live at ReplicatedStorage.Food (recursively;
-- per-machine subfolders are supported, e.g. Food/Timed/Food3_Timed) and
-- must carry an XP attribute. A template may be either a BasePart (legacy)
-- or a Model (preferred — supports multi-part visuals and Model:ScaleTo).
-- Food tools carry both FoodId (exact template key, e.g. Food1_Clicker) and
-- FoodType (broad group/category, e.g. Fruit). Every system that consumes
-- food identifies food by attributes, never by name.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local Food = {}

local folder
local function getFolder()
	folder = folder or ReplicatedStorage:WaitForChild("Food")
	return folder
end

local function isFoodTemplate(obj)
	return obj and (obj:IsA("BasePart") or obj:IsA("Model"))
end

-- Foods are organized into per-machine subfolders (Food/Clicker, Food/Timed,
-- Food/Processor, etc.) so the lookup recurses. FoodId is the stable key;
-- template.Name is allowed to be a player-facing alias.
function Food.GetTemplate(foodId)
	local direct = getFolder():FindFirstChild(foodId, true)
	if isFoodTemplate(direct) then return direct end

	for _, obj in ipairs(getFolder():GetDescendants()) do
		if isFoodTemplate(obj) and obj:GetAttribute(State.Food.Id) == foodId then
			return obj
		end
	end
	return nil
end

function Food.BaseXP(foodId)
	local t = Food.GetTemplate(foodId)
	return t and (t:GetAttribute("XP") or 1) or 1
end

function Food.TypeFor(foodId)
	local t = Food.GetTemplate(foodId)
	local foodType = t and t:GetAttribute(State.Food.Type)
	return type(foodType) == "string" and foodType ~= "" and foodType or "Fruit"
end

function Food.IdOf(food)
	if not food then return nil end
	local foodId = food:GetAttribute(State.Food.Id)
	if type(foodId) == "string" and foodId ~= "" then return foodId end

	-- Backward compatibility for tools created before FoodId existed.
	local oldFoodType = food:GetAttribute(State.Food.Type)
	if type(oldFoodType) == "string" and Food.GetTemplate(oldFoodType) then
		return oldFoodType
	end
	return nil
end

function Food.TypeOf(food)
	if not food then return nil end
	local foodId = Food.IdOf(food)
	local foodType = food:GetAttribute(State.Food.Type)

	if foodId and foodType == foodId then
		-- Backward compatibility for old tools where FoodType stored the
		-- exact template key instead of the broad category.
		return Food.TypeFor(foodId)
	end

	if type(foodType) == "string" and foodType ~= "" then return foodType end
	return foodId and Food.TypeFor(foodId) or nil
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
function Food.MakeTool(foodId, xpOverride)
	local template = Food.GetTemplate(foodId)
	if not template then
		warn(string.format("[Food] No template for %q", tostring(foodId)))
		return nil
	end

	local tool          = Instance.new("Tool")
	tool.Name           = template.Name
	tool.RequiresHandle = true

	if template:IsA("BasePart") then
		local handle = template:Clone()
		handle.Name = "Handle"
		configureBodyPart(handle, true)
		handle.Parent = tool
	elseif template:IsA("Model") then
		if not template.PrimaryPart then
			warn(string.format("[Food] Model template %q has no PrimaryPart", foodId))
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
		warn(string.format("[Food] Unsupported template class %q for %s", template.ClassName, foodId))
		return nil
	end

	tool:SetAttribute(State.Food.Id, foodId)
	tool:SetAttribute(State.Food.Type, Food.TypeFor(foodId))
	tool:SetAttribute("XP", xpOverride or (template:GetAttribute("XP") or 1))
	return tool
end

function Food.IsFood(tool)
	return tool ~= nil
		and tool:IsA("Tool")
		and Food.IdOf(tool) ~= nil
end

local function equippedTool(player)
	local char = player.Character
	return char and char:FindFirstChildWhichIsA("Tool") or nil
end

function Food.FindFirstInBackpack(player, foodType)
	for _, item in pairs(player.Backpack:GetChildren()) do
		if Food.IsFood(item) and (foodType == nil or Food.IdOf(item) == foodType) then
			return item
		end
	end
	local eq = equippedTool(player)
	if eq and Food.IsFood(eq) and (foodType == nil or Food.IdOf(eq) == foodType) then
		return eq
	end
	return nil
end

-- Equipped-only variant: returns the player's currently held food Tool
-- (optionally filtered by FoodType) or nil. Used by Processor deposit, which
-- requires the player to be holding the food.
function Food.GetEquipped(player, foodType)
	local eq = equippedTool(player)
	if Food.IsFood(eq) and (foodType == nil or Food.TypeOf(eq) == foodType) then
		return eq
	end
	return nil
end

function Food.CountByType(player)
	local counts = {}
	local function add(item)
		if Food.IsFood(item) then
			local t = Food.IdOf(item)
			counts[t] = (counts[t] or 0) + 1
		end
	end
	for _, item in pairs(player.Backpack:GetChildren()) do add(item) end
	add(equippedTool(player))
	return counts
end

return Food
