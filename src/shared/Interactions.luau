local Interactions = {}

Interactions.Actions = {
	PetFeed = "PetFeed",
	FeedMachine = "FeedMachine",
	PatchHarvest = "PatchHarvest",
	TreeGroundPickup = "TreeGroundPickup",
	GridPartUnlock = "GridPartUnlock",
	CrateRoll = "CrateRoll",
}

local validActions = {}
for _, action in pairs(Interactions.Actions) do
	validActions[action] = true
end

function Interactions.IsAction(action)
	return validActions[action] == true
end

return Interactions
