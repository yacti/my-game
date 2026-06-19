local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(script.Parent:WaitForChild("Assets"))

local Seeds = {}

Seeds.Attributes = {
	Id = "SeedID",
	FeedType = "FeedType",
	GrowTime = "GrowTime",
	RollChanceN = "RollChanceN",
	Price = "Price",
	Rarity = "Rarity",
}

local root
local index

local function getRoot()
	root = root or Assets.WaitFor(Assets.Names.Seeds)
	return root
end

local function isSeedTemplate(instance)
	return instance ~= nil and (instance:IsA("BasePart") or instance:IsA("Model"))
end

local function hasSeedTemplateAncestor(instance)
	local parent = instance.Parent
	local seedRoot = getRoot()
	while parent and parent ~= seedRoot do
		if isSeedTemplate(parent) then
			return true
		end
		parent = parent.Parent
	end
	return false
end

local function buildIndex()
	local result = {}
	for _, instance in ipairs(getRoot():GetDescendants()) do
		if isSeedTemplate(instance) and not hasSeedTemplateAncestor(instance) then
			local seedId = instance:GetAttribute(Seeds.Attributes.Id)
			if type(seedId) == "string" and seedId ~= "" and not result[seedId] then
				result[seedId] = instance
			end
		end
	end
	return result
end

local function getIndex()
	index = index or buildIndex()
	return index
end

function Seeds.Refresh()
	index = nil
	root = nil
end

function Seeds.GetTemplate(seedId)
	if type(seedId) ~= "string" or seedId == "" then
		return nil
	end

	local direct = getIndex()[seedId]
	if direct then
		return direct
	end

	local byName = getRoot():FindFirstChild(seedId, true)
	if isSeedTemplate(byName) then
		return byName
	end
	return nil
end

function Seeds.TemplateForFeedType(feedType)
	if type(feedType) ~= "string" or feedType == "" then
		return nil
	end
	for _, template in pairs(getIndex()) do
		if template:GetAttribute(Seeds.Attributes.FeedType) == feedType then
			return template
		end
	end
	return nil
end

function Seeds.AllSeedIds()
	local ids = {}
	for seedId in pairs(getIndex()) do
		ids[#ids + 1] = seedId
	end
	table.sort(ids)
	return ids
end

function Seeds.IdOf(seed)
	if not seed then
		return nil
	end
	local seedId = seed:GetAttribute(Seeds.Attributes.Id)
	if type(seedId) == "string" and seedId ~= "" then
		return seedId
	end
	return nil
end

function Seeds.FeedTypeFor(seedId)
	local template = Seeds.GetTemplate(seedId)
	local feedType = template and template:GetAttribute(Seeds.Attributes.FeedType)
	if type(feedType) == "string" and feedType ~= "" then
		return feedType
	end
	return nil
end

function Seeds.GrowTimeFor(seedId)
	local template = Seeds.GetTemplate(seedId)
	local growTime = template and template:GetAttribute(Seeds.Attributes.GrowTime)
	if type(growTime) == "number" and growTime > 0 then
		return growTime
	end
	return nil
end

function Seeds.PriceFor(seedId)
	local template = Seeds.GetTemplate(seedId)
	local price = template and template:GetAttribute(Seeds.Attributes.Price)
	if type(price) == "number" and price >= 0 then
		return math.floor(price)
	end
	return nil
end

function Seeds.RollChanceNFor(seedId)
	local template = Seeds.GetTemplate(seedId)
	local chanceN = template and template:GetAttribute(Seeds.Attributes.RollChanceN)
	if type(chanceN) == "number" and chanceN > 0 then
		return chanceN
	end
	return nil
end

function Seeds.RarityFor(seedId)
	local template = Seeds.GetTemplate(seedId)
	local rarity = template and template:GetAttribute(Seeds.Attributes.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end
	return nil
end

function Seeds.RarityForFeedType(feedType)
	local template = Seeds.TemplateForFeedType(feedType)
	local rarity = template and template:GetAttribute(Seeds.Attributes.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end
	return nil
end

function Seeds.DisplayNameFor(seedId)
	local template = Seeds.GetTemplate(seedId)
	return template and template.Name or seedId
end

return Seeds
