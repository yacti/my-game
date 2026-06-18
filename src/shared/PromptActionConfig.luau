local Interactions = require(script.Parent:WaitForChild("Interactions"))

local PromptActionConfig = {}

PromptActionConfig.ActionIntervalSeconds = 0.15
PromptActionConfig.RetryIntervalSeconds = PromptActionConfig.ActionIntervalSeconds

PromptActionConfig.FeedCollectActions = {
	Interactions.Actions.PetFeed,
	Interactions.Actions.PatchHarvest,
	Interactions.Actions.TreeGroundPickup,
}

local feedCollectActionSet = {}
for _, action in ipairs(PromptActionConfig.FeedCollectActions) do
	feedCollectActionSet[action] = true
end

function PromptActionConfig.IsFeedCollectAction(action)
	return feedCollectActionSet[action] == true
end

return PromptActionConfig
