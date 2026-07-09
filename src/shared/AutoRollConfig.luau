local Rarities = require(script.Parent:WaitForChild("Rarities"))

local AutoRollConfig = {}

AutoRollConfig.UnlockRebirths = 1
AutoRollConfig.RequestRateSeconds = 0.25
AutoRollConfig.RetrySeconds = 0.25
AutoRollConfig.NextRollDelaySeconds = 1.5

AutoRollConfig.Actions = {
	Start = "start",
	Stop = "stop",
	Settings = "settings",
}

AutoRollConfig.ToggleColors = {
	Off = Color3.new(1, 1, 1),
	On = Color3.fromRGB(70, 235, 95),
}

-- Exclusive seeds are EventOnly (never in the roll pool), so they get no
-- auto-roll filter row.
AutoRollConfig.Rarities = {}
for _, rarity in ipairs(Rarities.Order) do
	if rarity ~= Rarities.Exclusive then
		table.insert(AutoRollConfig.Rarities, rarity)
	end
end
AutoRollConfig.PurchasePriority = {
	Rarities.Secret,
	Rarities.Mythical,
	Rarities.Legendary,
	Rarities.Epic,
	Rarities.Rare,
	Rarities.Common,
}
AutoRollConfig.MaxSelectedRarities = #AutoRollConfig.Rarities

function AutoRollConfig.SanitizeSelectedRarities(value)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		return nil, "invalid-rarities"
	end

	local rawCount = 0
	local set = {}
	for key, item in pairs(value) do
		rawCount += 1
		if rawCount > AutoRollConfig.MaxSelectedRarities then
			return nil, "too-many-rarities"
		end

		local rarity = nil
		if type(item) == "string" then
			rarity = item
		elseif item == true and type(key) == "string" then
			rarity = key
		elseif item == false then
			rarity = nil
		else
			return nil, "invalid-rarities"
		end

		if rarity and Rarities.IsValid(rarity) then
			set[rarity] = true
		end
	end

	local selected = {}
	for _, rarity in ipairs(AutoRollConfig.Rarities) do
		if set[rarity] == true then
			selected[#selected + 1] = rarity
		end
	end
	return selected
end

function AutoRollConfig.SanitizeSettings(value)
	if value == nil then
		return {
			autoPurchase = false,
			selectedRarities = {},
		}
	end
	if type(value) ~= "table" then
		return nil, "invalid-settings"
	end

	local selected, code = AutoRollConfig.SanitizeSelectedRarities(value.selectedRarities)
	if not selected then
		return nil, code
	end

	return {
		autoPurchase = value.autoPurchase == true,
		selectedRarities = selected,
	}
end

function AutoRollConfig.CopySettings(value)
	local settings = AutoRollConfig.SanitizeSettings(value)
	if settings then
		return settings
	end
	return {
		autoPurchase = false,
		selectedRarities = {},
	}
end

local priorityByRarity = {}
for index, rarity in ipairs(AutoRollConfig.PurchasePriority) do
	priorityByRarity[rarity] = index
end

function AutoRollConfig.PriorityForRarity(rarity)
	return priorityByRarity[rarity] or math.huge
end

return AutoRollConfig
