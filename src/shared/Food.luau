-- Food registry. Templates live at ReplicatedStorage.Assets.Food (recursively;
-- per-machine subfolders are supported, e.g. Food/Patch/Pumpkin1). A
-- template may be either a BasePart (legacy) or a Model (preferred —
-- supports multi-part visuals and Model:ScaleTo). Templates may carry a base
-- XP attribute, but producers such as patches can override tool XP.
-- Food tools carry both FoodId (exact template key, e.g. Pumpkin1) and
-- FoodType (broad group/category, e.g. Fruit). Every system that consumes
-- food identifies food by attributes, never by name.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))
local ToolIdentity = require(ReplicatedStorage.Shared:WaitForChild("ToolIdentity"))
local Assets = require(script.Parent:WaitForChild("Assets"))
local Rarities = require(script.Parent:WaitForChild("Rarities"))

local Food = {}

local JAM_FOOD_TYPE = "Jam"
local JAM_ID_PREFIX = "Jam:"
local JAM_JAR_TEMPLATE_NAME = "JamJar"
local JAM_FILL_NAME = "Fill"
local FOOD_RARITY_ATTRIBUTE = "Rarity"

local folder
local function getFolder()
	folder = folder or Assets.WaitFor(Assets.Names.Food)
	return folder
end

local function isFoodTemplate(obj)
	return obj and (obj:IsA("BasePart") or obj:IsA("Model"))
end

local function sourceDisplayName(sourceFoodId)
	local template = Food.GetTemplate(sourceFoodId)
	return template and template.Name or tostring(sourceFoodId)
end

function Food.MakeJamFoodId(producerFeedType, sourceFoodId)
	if type(producerFeedType) ~= "string" or producerFeedType == "" then return nil end
	if type(sourceFoodId) ~= "string" or sourceFoodId == "" then return nil end
	return JAM_ID_PREFIX .. producerFeedType .. ":" .. sourceFoodId
end

function Food.ParseJamFoodId(foodId)
	if type(foodId) ~= "string" then return nil, nil end
	local producerFeedType, sourceFoodId = string.match(foodId, "^" .. JAM_ID_PREFIX .. "([^:]+):(.+)$")
	if type(producerFeedType) ~= "string" or producerFeedType == "" then return nil, nil end
	if type(sourceFoodId) ~= "string" or sourceFoodId == "" then return nil, nil end
	return producerFeedType, sourceFoodId
end

function Food.IsJamFoodId(foodId)
	local producerFeedType, sourceFoodId = Food.ParseJamFoodId(foodId)
	return producerFeedType ~= nil and sourceFoodId ~= nil
end

local function findFeedTemplate(feedType)
	if type(feedType) ~= "string" or feedType == "" then return nil end
	local feedRoot = Assets.WaitFor(Assets.Names.FeedMachines)
	if not feedRoot then return nil end
	for _, obj in ipairs(feedRoot:GetDescendants()) do
		if isFoodTemplate(obj) and obj:GetAttribute(State.Feed.Type) == feedType then
			return obj
		end
	end
	return nil
end

local function jamJarTemplate()
	local misc = Assets.WaitFor(Assets.Names.Misc)
	local template = misc and misc:FindFirstChild(JAM_JAR_TEMPLATE_NAME)
	if template and template:IsA("Model") then
		return template
	end
	return nil
end

local function firstDescendantBasePartNamed(instance, name)
	if not instance then return nil end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant.Name == name and descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

local function primaryColorOfFoodTemplate(foodId)
	local template = Food.GetTemplate(foodId)
	if not template then return nil end
	if template:IsA("BasePart") then
		return template.Color
	end
	if template:IsA("Model") and template.PrimaryPart then
		return template.PrimaryPart.Color
	end
	return nil
end

local function applyToolRarity(tool, rarity)
	if type(rarity) == "string" and Rarities.IsValid(rarity) then
		tool:SetAttribute(State.Tool.Rarity, rarity)
	end
end

local function defaultJamXP(producerFeedType, sourceFoodId)
	local baseXP = Food.BaseXP(sourceFoodId)
	local producerTemplate = findFeedTemplate(producerFeedType)
	local multiplier = producerTemplate and producerTemplate:GetAttribute(State.Feed.XPMultiplier) or nil
	if type(multiplier) ~= "number" or multiplier <= 0 then
		multiplier = producerTemplate and producerTemplate:GetAttribute(State.Feed.XP) or 1
	end
	if type(multiplier) ~= "number" or multiplier <= 0 then
		multiplier = 1
	end
	return baseXP * multiplier
end

-- Foods may be organized into visual/category subfolders (Food/Fruit,
-- Food/Patch, Food/Processor, etc.) so the lookup recurses. FoodId is the stable key;
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
	local producerFeedType, sourceFoodId = Food.ParseJamFoodId(foodId)
	if producerFeedType and sourceFoodId then
		return defaultJamXP(producerFeedType, sourceFoodId)
	end
	local t = Food.GetTemplate(foodId)
	return t and (t:GetAttribute(State.Food.XP) or 1) or 1
end

function Food.TypeFor(foodId)
	if Food.IsJamFoodId(foodId) then
		return JAM_FOOD_TYPE
	end
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

function Food.XPOf(food)
	local foodId = Food.IdOf(food)
	if Food.IsJamFoodId(foodId) then
		local xp = tonumber(food:GetAttribute(State.Food.XP))
		if xp == nil then
			xp = Food.BaseXP(foodId)
		end
		return math.max(xp, 0)
	end
	local template = foodId and Food.GetTemplate(foodId)
	if not template then return nil end

	local baseXP = tonumber(template:GetAttribute(State.Food.XP)) or 1
	local xp = tonumber(food:GetAttribute(State.Food.XP)) or baseXP
	return math.max(xp, 0)
end

local function configureBodyPart(part, isHandle)
	part.Anchored   = false
	part.CanCollide = isHandle  -- only the handle collides; sub-parts shouldn't push the player around
	part.CanQuery   = false     -- so the held food doesn't block ClickDetector raycasts
	part.Massless   = true
end

local function buildToolFromTemplate(template, toolName)
	local tool          = Instance.new("Tool")
	tool.Name           = toolName
	tool.RequiresHandle = true

	if template:IsA("BasePart") then
		local handle = template:Clone()
		handle.Name = "Handle"
		configureBodyPart(handle, true)
		handle.Parent = tool
	elseif template:IsA("Model") then
		if not template.PrimaryPart then
			warn(string.format("[Food] Model template %q has no PrimaryPart", toolName))
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
		warn(string.format("[Food] Unsupported template class %q for %s", template.ClassName, tostring(toolName)))
		return nil
	end

	return tool
end

local function configureFoodTool(tool, foodId, foodType, xp, rarity)
	tool:SetAttribute(State.Food.Id, foodId)
	tool:SetAttribute(State.Food.Type, foodType)
	tool:SetAttribute(State.Food.XP, xp)
	applyToolRarity(tool, rarity)
	ToolIdentity.AssignGuid(tool)
	return tool
end

function Food.MakeJamTool(producerFeedType, sourceFoodId, xpOverride)
	local foodId = Food.MakeJamFoodId(producerFeedType, sourceFoodId)
	if not foodId then return nil end

	local template = jamJarTemplate()
	if not template then
		warn("[Food] Missing Assets.Misc.JamJar model")
		return nil
	end
	if Food.IsJamFoodId(sourceFoodId) then
		warn(string.format("[Food] Cannot make jam from jam source %q", tostring(sourceFoodId)))
		return nil
	end
	local sourceTemplate = Food.GetTemplate(sourceFoodId)
	if not sourceTemplate then
		warn(string.format("[Food] No source food template for jam: %q", tostring(sourceFoodId)))
		return nil
	end

	local fillColor = primaryColorOfFoodTemplate(sourceFoodId)
	local tool = buildToolFromTemplate(template, sourceDisplayName(sourceFoodId) .. " Jam")
	if not tool then return nil end

	local fill = firstDescendantBasePartNamed(tool, JAM_FILL_NAME)
	if fill and fillColor then
		fill.Color = fillColor
	end

	local xp = tonumber(xpOverride) or defaultJamXP(producerFeedType, sourceFoodId)
	configureFoodTool(tool, foodId, JAM_FOOD_TYPE, math.max(xp, 0), sourceTemplate:GetAttribute(FOOD_RARITY_ATTRIBUTE))
	tool:SetAttribute(State.Food.JamProducerFeedType, producerFeedType)
	tool:SetAttribute(State.Food.JamSourceFoodId, sourceFoodId)
	return tool
end

-- xpOverride lets processors dispense food with a multiplier baked in.
-- Templates can be BaseParts or Models. Model templates use their
-- PrimaryPart as the Tool's Handle; sibling parts get welded to it so the
-- Tool keeps RequiresHandle semantics while still showing the full visual.
function Food.MakeTool(foodId, xpOverride)
	local producerFeedType, sourceFoodId = Food.ParseJamFoodId(foodId)
	if producerFeedType and sourceFoodId then
		return Food.MakeJamTool(producerFeedType, sourceFoodId, xpOverride)
	end

	local template = Food.GetTemplate(foodId)
	if not template then
		warn(string.format("[Food] No template for %q", tostring(foodId)))
		return nil
	end

	local tool = buildToolFromTemplate(template, template.Name)
	if not tool then return nil end

	local xp = xpOverride or (template:GetAttribute(State.Food.XP) or 1)
	return configureFoodTool(tool, foodId, Food.TypeFor(foodId), xp, template:GetAttribute(FOOD_RARITY_ATTRIBUTE))
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

local function feedCandidateXP(item)
	if not Food.IsFood(item) then return nil end
	return Food.XPOf(item)
end

local function isBetterFeedCandidate(candidate, candidateXP, current, currentXP)
	if current == nil then return true end
	if candidateXP ~= currentXP then return candidateXP > currentXP end

	local candidateId = Food.IdOf(candidate) or ""
	local currentId = Food.IdOf(current) or ""
	if candidateId ~= currentId then return candidateId < currentId end

	local candidateGuid = ToolIdentity.GuidOf(candidate) or candidate.Name
	local currentGuid = ToolIdentity.GuidOf(current) or current.Name
	return candidateGuid < currentGuid
end

-- Pet feeding always spends the held food first. If no feedable food is held,
-- choose the highest-XP food from the backpack so bulk feeding is predictable.
function Food.FindForPetFeed(player)
	local eq = equippedTool(player)
	if feedCandidateXP(eq) ~= nil then
		return eq
	end

	local best = nil
	local bestXP = nil
	for _, item in ipairs(player.Backpack:GetChildren()) do
		local xp = feedCandidateXP(item)
		if xp ~= nil and isBetterFeedCandidate(item, xp, best, bestXP) then
			best = item
			bestXP = xp
		end
	end

	return best
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
