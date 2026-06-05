local Assets = require(script.Parent:WaitForChild("Assets"))
local State = require(script.Parent:WaitForChild("State"))

local Cosmetics = {}

Cosmetics.Attributes = {
	Id = State.Cosmetic.Id,
	Rarity = State.Cosmetic.Rarity,
	Description = "Description",
}

local root
local index

local function getRoot()
	root = root or Assets.WaitFor(Assets.Names.Cosmetics)
	return root
end

local function isCosmeticTemplate(instance)
	return instance ~= nil and (instance:IsA("BasePart") or instance:IsA("Model"))
end

local function hasCosmeticTemplateAncestor(instance)
	local parent = instance.Parent
	local cosmeticRoot = getRoot()
	while parent and parent ~= cosmeticRoot do
		if isCosmeticTemplate(parent) then
			return true
		end
		parent = parent.Parent
	end
	return false
end

local function buildIndex()
	local result = {}
	for _, instance in ipairs(getRoot():GetDescendants()) do
		if isCosmeticTemplate(instance) and not hasCosmeticTemplateAncestor(instance) then
			local cosmeticId = instance:GetAttribute(Cosmetics.Attributes.Id)
			if type(cosmeticId) == "string" and cosmeticId ~= "" and not result[cosmeticId] then
				result[cosmeticId] = instance
			end
		end
	end
	return result
end

local function getIndex()
	index = index or buildIndex()
	return index
end

function Cosmetics.Refresh()
	index = nil
	root = nil
end

function Cosmetics.GetTemplate(cosmeticId)
	if type(cosmeticId) ~= "string" or cosmeticId == "" then
		return nil
	end

	local direct = getIndex()[cosmeticId]
	if direct then
		return direct
	end

	local byName = getRoot():FindFirstChild(cosmeticId, true)
	if isCosmeticTemplate(byName) then
		return byName
	end
	return nil
end

function Cosmetics.AllCosmeticIds()
	local ids = {}
	for cosmeticId in pairs(getIndex()) do
		ids[#ids + 1] = cosmeticId
	end
	table.sort(ids)
	return ids
end

function Cosmetics.IdOf(cosmetic)
	if not cosmetic then
		return nil
	end
	local cosmeticId = cosmetic:GetAttribute(Cosmetics.Attributes.Id)
	if type(cosmeticId) == "string" and cosmeticId ~= "" then
		return cosmeticId
	end
	return nil
end

function Cosmetics.RarityFor(cosmeticId)
	local template = Cosmetics.GetTemplate(cosmeticId)
	local rarity = template and template:GetAttribute(Cosmetics.Attributes.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end
	return nil
end

function Cosmetics.DisplayNameFor(cosmeticId)
	local template = Cosmetics.GetTemplate(cosmeticId)
	return template and template.Name or cosmeticId
end

function Cosmetics.DescriptionFor(cosmeticId)
	local template = Cosmetics.GetTemplate(cosmeticId)
	local description = template and template:GetAttribute(Cosmetics.Attributes.Description)
	if type(description) == "string" then
		return description
	end
	return ""
end

return Cosmetics
