local AnalyticsService = game:GetService("AnalyticsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Server = script.Parent
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local OnboardingAnalyticsService = {}

local STEP_NAMES = {
	[Onboarding.Stages.RollAppleTreeSeed] = "Roll Apple Tree Seed",
	[Onboarding.Stages.BuyAppleTreeSeed] = "Buy Apple Tree Seed",
	[Onboarding.Stages.PlantAppleTreeSeed] = "Plant Apple Tree Seed",
	[Onboarding.Stages.ShakeAppleTree] = "Shake Apple Tree",
	[Onboarding.Stages.CollectApple] = "Collect Apples",
	[Onboarding.Stages.FeedPetApple] = "Feed Pet Apple",
	[Onboarding.Stages.MakeCurrency] = "Earn " .. tostring(Onboarding.CurrencyRequired) .. " Cash",
	[Onboarding.Stages.RollPumpkinSeed] = "Roll Pumpkin Seed",
	[Onboarding.Stages.BuyPumpkinSeed] = "Buy Pumpkin Seed",
	[Onboarding.Stages.PlantPumpkinSeed] = "Plant Pumpkin Seed",
	[Onboarding.Stages.GatherPumpkinXP] = "Grow Pumpkin",
	[Onboarding.Stages.HarvestPumpkin] = "Harvest Pumpkin",
	[Onboarding.Stages.FeedPetPumpkin] = "Feed Pet Pumpkin",
	[Onboarding.Stages.ExpandFarm] = "Expand Farm",
	[Onboarding.Stages.FinalNote] = "See Final Tutorial Message",
	[Onboarding.Stages.Complete] = "Complete Tutorial",
}

local STEPS_BY_STAGE = {}
for step, stage in ipairs(Onboarding.OrderedStages()) do
	STEPS_BY_STAGE[stage] = step
end

local function warnFailure(player, stage, step, stepName, reason)
	TelemetryService.Warn("onboarding_funnel_log_failed", TelemetryService.ForPlayer(player, {
		reason = reason,
		stage = stage,
		step = step,
		stepName = stepName,
	}))
end

function OnboardingAnalyticsService.LogStage(player, stage)
	if RunService:IsStudio() then
		return false, "studio"
	end
	if not (player and player:IsA("Player")) then
		return false, "invalid-player"
	end
	if not Onboarding.IsStage(stage) then
		warnFailure(player, stage, nil, nil, "invalid-stage")
		return false, "invalid-stage"
	end

	local step = STEPS_BY_STAGE[stage]
	local stepName = STEP_NAMES[stage]
	if type(step) ~= "number" or type(stepName) ~= "string" or stepName == "" then
		warnFailure(player, stage, step, stepName, "missing-step")
		return false, "missing-step"
	end

	local ok, err = RuntimeGuard.Try("OnboardingAnalyticsService.LogStage", function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)
	if not ok then
		warnFailure(player, stage, step, stepName, tostring(err))
		return false, "analytics-error"
	end

	return true
end

return OnboardingAnalyticsService
