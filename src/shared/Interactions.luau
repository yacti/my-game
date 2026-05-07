local Interactions = {}

Interactions.Actions = {
	PetFeed = "PetFeed",
	FeedPickup = "FeedPickup",
	FeedMachine = "FeedMachine",
	PatchHarvest = "PatchHarvest",
	TreeGroundPickup = "TreeGroundPickup",
}

local validActions = {}
for _, action in pairs(Interactions.Actions) do
	validActions[action] = true
end

function Interactions.IsAction(action)
	return validActions[action] == true
end

return Interactions
