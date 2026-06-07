local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))

local OnboardingService = {}

local STARTER_AREA_EPSILON = 0.05

local function profileState(profile)
	if not (profile and profile.Data) then
		return Onboarding.CompleteState()
	end
	profile.Data.Onboarding = Onboarding.SanitizeState(profile.Data.Onboarding, Onboarding.CompleteState())
	return profile.Data.Onboarding
end

local function progressFor(profile)
	local state = profileState(profile)
	state.Progress = Onboarding.SanitizeProgress(state.Progress)
	return state.Progress
end

local function stageFor(profile)
	return profileState(profile).Stage
end

local function publishOnboarding(player, profile)
	PlayerReplicaService.PublishOnboarding(player, profile)
end

local function publishProfile(player, profile)
	PlayerReplicaService.PublishProfile(player, profile)
end

local function resetStageProgressFor(state, nextStage)
	local progress = Onboarding.SanitizeProgress(state.Progress)
	if nextStage ~= Onboarding.Stages.ShakeAppleTree and nextStage ~= Onboarding.Stages.CollectApple then
		progress[Onboarding.ProgressKeys.TreeClickCount] = 0
		progress[Onboarding.ProgressKeys.TreeDroppedSlots] = {}
		progress[Onboarding.ProgressKeys.TreeFruitTarget] = 0
		progress[Onboarding.ProgressKeys.TreeFruitCollected] = 0
	end
	state.Progress = progress
end

local function normalizeTreeSlotIndex(slotIndex)
	slotIndex = tonumber(slotIndex)
	if type(slotIndex) ~= "number" or slotIndex ~= slotIndex then
		return nil
	end
	slotIndex = math.floor(slotIndex)
	if slotIndex < 1 or slotIndex > Onboarding.TreeClicksRequired then
		return nil
	end
	return slotIndex
end

local function countDroppedSlots(droppedSlots)
	local count = 0
	if type(droppedSlots) ~= "table" then
		return count
	end
	for _, dropped in pairs(droppedSlots) do
		if dropped == true then
			count += 1
		end
	end
	return count
end

local function ensureAppleCash(player, profile)
	local progress = progressFor(profile)
	if progress[Onboarding.ProgressKeys.AppleCashGranted] == true then
		return false
	end

	progress[Onboarding.ProgressKeys.AppleCashGranted] = true
	local price = Seeds.PriceFor(Onboarding.Seeds.AppleTree) or 0
	local current = tonumber(profile.Data.Currency) or 0
	local grantAmount = math.max(math.floor(price - current), 0)
	if grantAmount > 0 then
		CurrencyService.Add(player, profile, grantAmount, true)
		return true
	end
	return false
end

local function applyStageEntryEffects(player, profile, stage)
	if stage == Onboarding.Stages.RollAppleTreeSeed then
		return ensureAppleCash(player, profile)
	end
	return false
end

local function setStage(player, profile, nextStage)
	if not (profile and profile.Data and Onboarding.IsStage(nextStage)) then
		return false
	end

	local state = profileState(profile)
	if state.Stage == nextStage then
		return false
	end

	state.Stage = nextStage
	resetStageProgressFor(state, nextStage)
	local profileChanged = applyStageEntryEffects(player, profile, nextStage)
	if profileChanged then
		publishProfile(player, profile)
	else
		publishOnboarding(player, profile)
	end
	return true
end

local function isPointInsidePart(part, worldPosition)
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	return math.abs(localPosition.X) <= part.Size.X / 2 + STARTER_AREA_EPSILON
		and math.abs(localPosition.Z) <= part.Size.Z / 2 + STARTER_AREA_EPSILON
end

local function isInsideStarterArea(plot, instance)
	if not (plot and instance) then
		return false
	end

	local position
	if instance:IsA("BasePart") then
		position = instance.Position
	elseif instance:IsA("Model") then
		position = instance:GetPivot().Position
	end
	if typeof(position) ~= "Vector3" then
		return false
	end

	local starterArea = plot:FindFirstChild("StarterArea")
	if not starterArea then
		return false
	end
	for _, child in ipairs(starterArea:GetChildren()) do
		if child:IsA("BasePart") and isPointInsidePart(child, position) then
			return true
		end
	end
	return false
end

local function feedTypeOf(machine)
	local feedType = machine and machine:GetAttribute(State.Feed.Type)
	return type(feedType) == "string" and feedType or nil
end

local function foodIdOf(instance)
	local foodId = instance and instance:GetAttribute(State.Food.Id)
	return type(foodId) == "string" and foodId or nil
end

function OnboardingService.GetState(profile)
	return profileState(profile)
end

function OnboardingService.GetStage(profile)
	return stageFor(profile)
end

function OnboardingService.IsComplete(profile)
	return Onboarding.IsComplete(stageFor(profile))
end

function OnboardingService.SetStage(player, profile, nextStage)
	return setStage(player, profile, nextStage)
end

function OnboardingService.ApplyCurrentStageEntry(player, profile)
	local changed = applyStageEntryEffects(player, profile, stageFor(profile))
	if changed then
		publishProfile(player, profile)
	end
	return changed
end

function OnboardingService.Advance(player, profile, expectedStage)
	if stageFor(profile) ~= expectedStage then
		return false
	end

	local nextStage = Onboarding.NextStage(expectedStage)
	if not nextStage then
		return false
	end
	return setStage(player, profile, nextStage)
end

function OnboardingService.GuaranteedRollSeed(profile)
	local stage = stageFor(profile)
	if stage == Onboarding.Stages.RollPumpkinSeed then
		return Onboarding.Seeds.Pumpkin
	end
	if stage == Onboarding.Stages.RollAppleTreeSeed then
		return Onboarding.Seeds.AppleTree
	end
	return nil
end

function OnboardingService.RequiredBuySeed(profile)
	local stage = stageFor(profile)
	if stage == Onboarding.Stages.BuyPumpkinSeed then
		return Onboarding.Seeds.Pumpkin
	end
	if stage == Onboarding.Stages.BuyAppleTreeSeed then
		return Onboarding.Seeds.AppleTree
	end
	return nil
end

function OnboardingService.ResolveRollAttempt(player, profile, hasRequiredOffer)
	local stage = stageFor(profile)
	if stage == Onboarding.Stages.BuyPumpkinSeed then
		if hasRequiredOffer then
			return false, "tutorial-buy-pending"
		end
		setStage(player, profile, Onboarding.Stages.RollPumpkinSeed)
		return true
	end
	if stage == Onboarding.Stages.BuyAppleTreeSeed then
		if hasRequiredOffer then
			return false, "tutorial-buy-pending"
		end
		setStage(player, profile, Onboarding.Stages.RollAppleTreeSeed)
		return true
	end
	return true
end

function OnboardingService.OnRollCreated(player, profile, seedId)
	if seedId == Onboarding.Seeds.Pumpkin then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.RollPumpkinSeed)
	end
	if seedId == Onboarding.Seeds.AppleTree then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.RollAppleTreeSeed)
	end
	return false
end

function OnboardingService.OnSeedPurchased(player, profile, seedId)
	if seedId == Onboarding.Seeds.Pumpkin then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.BuyPumpkinSeed)
	end
	if seedId == Onboarding.Seeds.AppleTree then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.BuyAppleTreeSeed)
	end
	return false
end

function OnboardingService.OnSeedPlaced(player, profile, plot, placedFeed, seedId, feedType)
	if seedId == Onboarding.Seeds.Pumpkin
		and feedType == Onboarding.FeedTypes.Pumpkin
		and isInsideStarterArea(plot, placedFeed) then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.PlantPumpkinSeed)
	end
	if seedId == Onboarding.Seeds.AppleTree
		and feedType == Onboarding.FeedTypes.AppleTree
		and isInsideStarterArea(plot, placedFeed) then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.PlantAppleTreeSeed)
	end
	return false
end

function OnboardingService.OnPatchXPChanged(player, profile, machine, xp)
	if stageFor(profile) ~= Onboarding.Stages.GatherPumpkinXP then
		return false
	end
	if feedTypeOf(machine) ~= Onboarding.FeedTypes.Pumpkin then
		return false
	end
	if (tonumber(xp) or 0) < Onboarding.PumpkinXPRequired then
		return false
	end
	return OnboardingService.Advance(player, profile, Onboarding.Stages.GatherPumpkinXP)
end

function OnboardingService.OnPatchHarvested(player, profile, machine, foodId)
	if stageFor(profile) ~= Onboarding.Stages.HarvestPumpkin then
		return false
	end
	if feedTypeOf(machine) ~= Onboarding.FeedTypes.Pumpkin then
		return false
	end
	if foodId ~= Onboarding.FoodIds.Pumpkin then
		return false
	end
	return OnboardingService.Advance(player, profile, Onboarding.Stages.HarvestPumpkin)
end

function OnboardingService.OnPetFed(player, profile)
	local stage = stageFor(profile)
	if stage == Onboarding.Stages.FeedPetPumpkin then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.FeedPetPumpkin)
	end
	if stage == Onboarding.Stages.FeedPetApple then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.FeedPetApple)
	end
	return false
end

function OnboardingService.OnTreeClicked(player, profile, machine, foodId, slotIndex)
	if stageFor(profile) ~= Onboarding.Stages.ShakeAppleTree then
		return false
	end
	if feedTypeOf(machine) ~= Onboarding.FeedTypes.AppleTree then
		return false
	end
	if foodId ~= Onboarding.FoodIds.Apple then
		return false
	end
	slotIndex = normalizeTreeSlotIndex(slotIndex)
	if not slotIndex then
		return false
	end

	local progress = progressFor(profile)
	local droppedSlots = progress[Onboarding.ProgressKeys.TreeDroppedSlots]
	if type(droppedSlots) ~= "table" then
		droppedSlots = {}
		progress[Onboarding.ProgressKeys.TreeDroppedSlots] = droppedSlots
	end

	local slotKey = tostring(slotIndex)
	if droppedSlots[slotKey] == true then
		return false
	end

	droppedSlots[slotKey] = true
	local droppedCount = math.min(countDroppedSlots(droppedSlots), Onboarding.TreeClicksRequired)
	progress[Onboarding.ProgressKeys.TreeClickCount] = droppedCount
	progress[Onboarding.ProgressKeys.TreeFruitTarget] = math.max(
		progress[Onboarding.ProgressKeys.TreeFruitTarget] or 0,
		droppedCount
	)
	progress[Onboarding.ProgressKeys.TreeFruitCollected] = progress[Onboarding.ProgressKeys.TreeFruitCollected] or 0

	if droppedCount >= Onboarding.TreeClicksRequired then
		return setStage(player, profile, Onboarding.Stages.CollectApple)
	end
	publishOnboarding(player, profile)
	return true
end

function OnboardingService.OnTreeFruitPicked(player, profile, machine, ground)
	if stageFor(profile) ~= Onboarding.Stages.CollectApple then
		return false
	end
	if feedTypeOf(machine) ~= Onboarding.FeedTypes.AppleTree then
		return false
	end
	if foodIdOf(ground) ~= Onboarding.FoodIds.Apple then
		return false
	end

	local progress = progressFor(profile)
	local target = math.max(progress[Onboarding.ProgressKeys.TreeFruitTarget] or 0, Onboarding.TreeClicksRequired)
	local collected = math.min((progress[Onboarding.ProgressKeys.TreeFruitCollected] or 0) + 1, target)
	progress[Onboarding.ProgressKeys.TreeFruitTarget] = target
	progress[Onboarding.ProgressKeys.TreeFruitCollected] = collected

	if collected >= target then
		return setStage(player, profile, Onboarding.Stages.FeedPetApple)
	end
	publishOnboarding(player, profile)
	return true
end

return OnboardingService
