local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(script.Parent:WaitForChild("Assets"))
local State = require(script.Parent:WaitForChild("State"))

local Mutations = {}

Mutations.Ids = {
	Lightning = "Lightning",
	Alien = "Alien",
}

Mutations.DisplayColors = {
	[Mutations.Ids.Lightning] = Color3.fromRGB(107, 206, 255),
	[Mutations.Ids.Alien] = Color3.fromRGB(107, 255, 137),
}

Mutations.XPMultipliers = {
	[Mutations.Ids.Lightning] = 5,
	[Mutations.Ids.Alien] = 6,
}

local function mutationRoot()
	local assets = Assets.FindRoot() or Assets.WaitForRoot(5)
	local mutations = assets and assets:FindFirstChild("Mutations")
	if mutations and mutations:IsA("Folder") then
		return mutations
	end
	return nil
end

local function cleanId(value)
	if type(value) ~= "string" then
		return nil
	end
	value = string.gsub(value, "^%s+", "")
	value = string.gsub(value, "%s+$", "")
	if value == "" then
		return nil
	end
	return value
end

local function addUnique(out, seen, mutationId)
	mutationId = cleanId(mutationId)
	if mutationId and not seen[mutationId] then
		seen[mutationId] = true
		out[#out + 1] = mutationId
	end
end

function Mutations.Template(mutationId)
	mutationId = cleanId(mutationId)
	local root = mutationRoot()
	local template = root and mutationId and root:FindFirstChild(mutationId)
	if template and (template:IsA("BasePart") or template:IsA("Model") or template:IsA("Folder")) then
		return template
	end
	return nil
end

function Mutations.IsValid(mutationId)
	return Mutations.Template(mutationId) ~= nil
end

function Mutations.Decode(encoded)
	local out = {}
	local seen = {}
	if type(encoded) == "string" then
		for token in string.gmatch(encoded, "[^,]+") do
			addUnique(out, seen, token)
		end
	end
	table.sort(out)
	return out
end

function Mutations.SanitizeList(value)
	local out = {}
	local seen = {}
	if type(value) == "table" then
		for _, mutationId in ipairs(value) do
			addUnique(out, seen, mutationId)
		end
	elseif type(value) == "string" then
		for _, mutationId in ipairs(Mutations.Decode(value)) do
			addUnique(out, seen, mutationId)
		end
	end
	table.sort(out)
	return out
end

function Mutations.Encode(mutationIds)
	local clean = Mutations.SanitizeList(mutationIds)
	if #clean == 0 then
		return nil
	end
	return table.concat(clean, ",")
end

function Mutations.Copy(mutationIds)
	local clean = Mutations.SanitizeList(mutationIds)
	local copy = table.create(#clean)
	for index, mutationId in ipairs(clean) do
		copy[index] = mutationId
	end
	return copy
end

function Mutations.Contains(mutationIds, mutationId)
	mutationId = cleanId(mutationId)
	if not mutationId then
		return false
	end
	for _, current in ipairs(Mutations.SanitizeList(mutationIds)) do
		if current == mutationId then
			return true
		end
	end
	return false
end

function Mutations.Primary(mutationIds, preferredMutationId)
	local clean = Mutations.SanitizeList(mutationIds)
	if #clean == 0 then
		return nil
	end
	preferredMutationId = cleanId(preferredMutationId)
	if preferredMutationId and Mutations.Contains(clean, preferredMutationId) then
		return preferredMutationId
	end
	return clean[#clean]
end

function Mutations.Add(mutationIds, mutationId)
	local out = Mutations.SanitizeList(mutationIds)
	mutationId = cleanId(mutationId)
	if not mutationId or not Mutations.IsValid(mutationId) or Mutations.Contains(out, mutationId) then
		return out, false
	end
	out[#out + 1] = mutationId
	table.sort(out)
	return out, true
end

function Mutations.FromInstance(instance)
	if not instance then
		return {}
	end
	return Mutations.Decode(instance:GetAttribute(State.Food.MutationIds))
end

function Mutations.PrimaryFromInstance(instance)
	if not instance then
		return nil
	end
	return Mutations.Primary(Mutations.FromInstance(instance), instance:GetAttribute(State.Food.PrimaryMutationId))
end

function Mutations.DisplayColor(mutationId)
	mutationId = cleanId(mutationId)
	if not mutationId then
		return nil
	end
	local template = Mutations.Template(mutationId)
	local templateColor = template and template:GetAttribute("InventoryColor")
	if typeof(templateColor) == "Color3" then
		return templateColor
	end
	templateColor = template and template:GetAttribute("Color")
	if typeof(templateColor) == "Color3" then
		return templateColor
	end
	return Mutations.DisplayColors[mutationId]
end

function Mutations.ApplyAttribute(instance, mutationIds, primaryMutationId)
	if not instance then
		return
	end
	local primary = Mutations.Primary(mutationIds, primaryMutationId)
	instance:SetAttribute(State.Food.MutationIds, Mutations.Encode(mutationIds))
	instance:SetAttribute(State.Food.PrimaryMutationId, primary)
end

function Mutations.XPMultiplier(mutationId)
	mutationId = cleanId(mutationId)
	local configuredMultiplier = mutationId and Mutations.XPMultipliers[mutationId]
	if type(configuredMultiplier) == "number"
		and configuredMultiplier > 0
		and configuredMultiplier == configuredMultiplier
		and math.abs(configuredMultiplier) ~= math.huge then
		return configuredMultiplier
	end
	local template = Mutations.Template(mutationId)
	local multiplier = template and template:GetAttribute(State.Feed.XPMultiplier)
	if type(multiplier) ~= "number" or multiplier <= 0 or multiplier ~= multiplier or math.abs(multiplier) == math.huge then
		return nil
	end
	return multiplier
end

return Mutations
