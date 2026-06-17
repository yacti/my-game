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

AutoRollConfig.Rarities = table.clone(Rarities.Order)
AutoRollConfig.PurchasePriority = {
	Rarities.Secret,
	Rarities.Mythical,
	Rarities.Legendary,
	Rarities.Epic,
	Rarities.Rare,
	Rarities.Common,
}
AutoRollConfig.MaxSelectedRarities = #AutoRollConfig.Rarities

local priorityByRarity = {}
for index, rarity in ipairs(AutoRollConfig.PurchasePriority) do
	priorityByRarity[rarity] = index
end

function AutoRollConfig.PriorityForRarity(rarity)
	return priorityByRarity[rarity] or math.huge
end

return AutoRollConfig
