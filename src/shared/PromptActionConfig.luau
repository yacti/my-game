local Interactions = require(script.Parent:WaitForChild("Interactions"))

local PromptActionConfig = {}

PromptActionConfig.ActionIntervalSeconds = 0.15
PromptActionConfig.RetryIntervalSeconds = PromptActionConfig.ActionIntervalSeconds

-- Held feed/collect actions accelerate: the repeat rate ramps from Start to
-- Max actions-per-second over RampSeconds of continuous holding, eased with
-- smoothstep so the acceleration builds and settles gently.
PromptActionConfig.HoldRampStartActionsPerSecond = 2
PromptActionConfig.HoldRampMaxActionsPerSecond = 10
PromptActionConfig.HoldRampSeconds = 3

-- Server-side family window for feed/collect actions. Derived from the ramp
-- peak with tolerance for network jitter compressing client-side gaps; the
-- curve itself is client UX, this cap is the anti-exploit ceiling.
PromptActionConfig.FamilyRateWindowSeconds = (1 / PromptActionConfig.HoldRampMaxActionsPerSecond) * 0.85

function PromptActionConfig.HoldIntervalSeconds(heldSeconds)
	local rampSeconds = math.max(PromptActionConfig.HoldRampSeconds, 0.001)
	local alpha = math.clamp((tonumber(heldSeconds) or 0) / rampSeconds, 0, 1)
	local eased = alpha * alpha * (3 - 2 * alpha)
	local actionsPerSecond = PromptActionConfig.HoldRampStartActionsPerSecond
		+ (PromptActionConfig.HoldRampMaxActionsPerSecond - PromptActionConfig.HoldRampStartActionsPerSecond) * eased
	return 1 / math.max(actionsPerSecond, 0.001)
end

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
