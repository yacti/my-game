local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(script.Parent:WaitForChild("Assets"))

local RollRewards = {}

RollRewards.Categories = {
	Seed = "Seed",
	Misc = "Misc",
}

RollRewards.Attributes = {
	MiscId = "MiscID",
	DisplayName = "DisplayName",
	RollChanceN = "RollChanceN",
	Price = "Price",
	Rarity = "Rarity",
}

local miscRoot
local miscIndex

local function getMiscRoot()
	miscRoot = miscRoot or Assets.WaitFor(Assets.Names.Misc)
	return miscRoot
end

function RollRewards.IsTemplate(instance)
	return instance ~= nil and (instance:IsA("BasePart") or instance:IsA("Model"))
end

function RollRewards.HasTemplateAncestor(root, instance)
	local parent = instance and instance.Parent
	while parent and parent ~= root do
		if RollRewards.IsTemplate(parent) then
			return true
		end
		parent = parent.Parent
	end
	return false
end

function RollRewards.RewardKey(category, rewardId)
	if type(category) ~= "string" or category == "" or type(rewardId) ~= "string" or rewardId == "" then
		return nil
	end
	return category .. ":" .. rewardId
end

local function miscIdOf(template)
	local miscId = template and template:GetAttribute(RollRewards.Attributes.MiscId)
	if type(miscId) == "string" and miscId ~= "" then
		return miscId
	end
	return nil
end

local function buildMiscIndex()
	local root = getMiscRoot()
	local result = {}
	for _, instance in ipairs(root:GetDescendants()) do
		if RollRewards.IsTemplate(instance) and not RollRewards.HasTemplateAncestor(root, instance) then
			local miscId = miscIdOf(instance)
			if miscId and not result[miscId] then
				result[miscId] = instance
			end
		end
	end
	return result
end

local function getMiscIndex()
	miscIndex = miscIndex or buildMiscIndex()
	return miscIndex
end

function RollRewards.GetMiscTemplate(miscId)
	if type(miscId) ~= "string" or miscId == "" then
		return nil
	end

	local direct = getMiscIndex()[miscId]
	if direct then
		return direct
	end

	local byName = getMiscRoot():FindFirstChild(miscId, true)
	if RollRewards.IsTemplate(byName) and miscIdOf(byName) == miscId then
		return byName
	end
	return nil
end

function RollRewards.AllMiscRewardIds()
	local ids = {}
	for miscId in pairs(getMiscIndex()) do
		ids[#ids + 1] = miscId
	end
	table.sort(ids)
	return ids
end

function RollRewards.MiscDisplayNameFor(miscId)
	local template = RollRewards.GetMiscTemplate(miscId)
	local displayName = template and template:GetAttribute(RollRewards.Attributes.DisplayName)
	if type(displayName) == "string" and displayName ~= "" then
		return displayName
	end
	return template and template.Name or miscId
end

function RollRewards.MiscPriceFor(miscId)
	local template = RollRewards.GetMiscTemplate(miscId)
	local price = template and template:GetAttribute(RollRewards.Attributes.Price)
	if type(price) == "number" and price >= 0 then
		return math.floor(price)
	end
	return nil
end

function RollRewards.MiscRollChanceNFor(miscId)
	local template = RollRewards.GetMiscTemplate(miscId)
	local chanceN = template and template:GetAttribute(RollRewards.Attributes.RollChanceN)
	if type(chanceN) == "number" and chanceN > 0 then
		return chanceN
	end
	return nil
end

function RollRewards.MiscRarityFor(miscId)
	local template = RollRewards.GetMiscTemplate(miscId)
	local rarity = template and template:GetAttribute(RollRewards.Attributes.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end
	return nil
end

function RollRewards.MiscEntryFor(miscId)
	local template = RollRewards.GetMiscTemplate(miscId)
	if not template then
		return nil
	end
	local displayName = template:GetAttribute(RollRewards.Attributes.DisplayName)
	if type(displayName) ~= "string" or displayName == "" then
		displayName = template.Name
	end
	local price = template:GetAttribute(RollRewards.Attributes.Price)
	if type(price) == "number" and price >= 0 then
		price = math.floor(price)
	else
		price = nil
	end
	local chanceN = template:GetAttribute(RollRewards.Attributes.RollChanceN)
	if type(chanceN) ~= "number" or chanceN <= 0 then
		chanceN = nil
	end
	local rarity = template:GetAttribute(RollRewards.Attributes.Rarity)
	if type(rarity) ~= "string" or rarity == "" then
		rarity = nil
	end

	return {
		category = RollRewards.Categories.Misc,
		id = RollRewards.RewardKey(RollRewards.Categories.Misc, miscId),
		rewardId = miscId,
		miscId = miscId,
		displayName = displayName,
		price = price,
		chanceN = chanceN,
		rarity = rarity,
	}
end

return RollRewards
