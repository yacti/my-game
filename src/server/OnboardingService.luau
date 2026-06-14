local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local OnboardingAnalyticsService = require(Server:WaitForChild("OnboardingAnalyticsService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local OnboardingService = {}

local STARTER_AREA_EPSILON = 0.05
local FINAL_NOTE_TOTAL_SECONDS = Onboarding.FinalNoteDisplaySeconds + Onboarding.FinalNoteFadeSeconds
local finalNoteTokensByUserId = {}

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

local function resetStageProgressFor(state, nextStage)
	local progress = Onboarding.SanitizeProgress(state.Progress)
	if nextStage ~= Onboarding.Stages.GatherPumpkinXP then
		progress[Onboarding.ProgressKeys.PumpkinXPGained] = 0
	end
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
	if slotIndex < 1 then
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

local function activeDroppedSlotsFor(machine, expectedFoodId)
	local droppedSlots = {}
	if not machine then
		return droppedSlots
	end
	for _, descendant in ipairs(machine:GetDescendants()) do
		if (descendant:IsA("BasePart") or descendant:IsA("Model"))
			and descendant:GetAttribute(State.TreeClicker.GroundPile) == true
			and descendant:GetAttribute(State.Food.Id) == expectedFoodId then
			local slotIndex = normalizeTreeSlotIndex(descendant:GetAttribute(State.TreeClicker.SlotIndex))
			if slotIndex then
				droppedSlots[tostring(slotIndex)] = true
			end
		end
	end
	return droppedSlots
end

local setStage

local function userIdFor(player)
	return player and player.UserId or nil
end

local function cancelFinalNoteCompletion(player)
	local userId = userIdFor(player)
	if userId then
		finalNoteTokensByUserId[userId] = nil
	end
end

local function scheduleFinalNoteCompletion(player, profile)
	local userId = userIdFor(player)
	if not userId then
		return
	end

	local token = (finalNoteTokensByUserId[userId] or 0) + 1
	finalNoteTokensByUserId[userId] = token

	task.delay(FINAL_NOTE_TOTAL_SECONDS, function()
		if finalNoteTokensByUserId[userId] ~= token then
			return
		end
		if not (player and player.Parent and profile and profile.Data) then
			finalNoteTokensByUserId[userId] = nil
			return
		end
		if stageFor(profile) ~= Onboarding.Stages.FinalNote then
			finalNoteTokensByUserId[userId] = nil
			return
		end
		setStage(player, profile, Onboarding.Stages.Complete)
	end)
end

local function expandFarmCoordKey()
	return PlotGrid.CoordKey(Onboarding.ExpandFarmGrid.X, Onboarding.ExpandFarmGrid.Z)
end

local function hasExpandFarmGridUnlocked(profile)
	if not (profile and profile.Data) then
		return false
	end

	local targetKey = expandFarmCoordKey()
	for _, key in ipairs(PlotGrid.SanitizeUnlockedKeys(profile.Data.UnlockedGridKeys)) do
		if key == targetKey then
			return true
		end
	end
	for _, key in ipairs(PlotGrid.SanitizeUnlockedKeys(profile.Data.UnlockedGridIds)) do
		if key == targetKey then
			return true
		end
	end
	return false
end

local function maybeCompleteMakeCurrency(player, profile, currency)
	if stageFor(profile) ~= Onboarding.Stages.MakeCurrency then
		return false
	end
	if (tonumber(currency) or 0) < Onboarding.CurrencyRequired then
		return false
	end
	return setStage(player, profile, Onboarding.NextStage(Onboarding.Stages.MakeCurrency))
end

local function maybeCompleteExpandFarm(player, profile)
	if stageFor(profile) ~= Onboarding.Stages.ExpandFarm then
		return false
	end
	if not hasExpandFarmGridUnlocked(profile) then
		return false
	end
	return setStage(player, profile, Onboarding.NextStage(Onboarding.Stages.ExpandFarm))
end

setStage = function(player, profile, nextStage)
	if not (profile and profile.Data and Onboarding.IsStage(nextStage)) then
		return false
	end

	local state = profileState(profile)
	if state.Stage == nextStage then
		return false
	end

	state.Stage = nextStage
	resetStageProgressFor(state, nextStage)
	publishOnboarding(player, profile)
	OnboardingAnalyticsService.LogStage(player, nextStage)
	if nextStage == Onboarding.Stages.FinalNote then
		scheduleFinalNoteCompletion(player, profile)
	else
		cancelFinalNoteCompletion(player)
	end
	if nextStage == Onboarding.Stages.MakeCurrency then
		maybeCompleteMakeCurrency(player, profile, profile.Data.Currency)
	elseif nextStage == Onboarding.Stages.ExpandFarm then
		maybeCompleteExpandFarm(player, profile)
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

local function isExpandFarmGridPart(gridPart)
	if not (gridPart and gridPart:IsA("BasePart")) then
		return false
	end
	return Onboarding.IsExpandFarmGridCoordinate(
		PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.X)),
		PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.Z))
	)
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
	local currentStage = stageFor(profile)
	if Onboarding.IsActive(currentStage) then
		OnboardingAnalyticsService.LogStage(player, currentStage)
	end
	if currentStage == Onboarding.Stages.FinalNote then
		scheduleFinalNoteCompletion(player, profile)
		return false
	end
	return maybeCompleteExpandFarm(player, profile)
		or maybeCompleteMakeCurrency(player, profile, profile and profile.Data and profile.Data.Currency)
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

function OnboardingService.OnCurrencyChanged(player, profile, currency)
	return maybeCompleteMakeCurrency(player, profile, currency)
end

function OnboardingService.CanUnlockGridPart(profile, gridPart)
	if stageFor(profile) ~= Onboarding.Stages.ExpandFarm then
		return true
	end
	return isExpandFarmGridPart(gridPart)
end

function OnboardingService.GuaranteedRollSeed(profile)
	local stage = stageFor(profile)
	if stage == Onboarding.Stages.RollAppleTreeSeed then
		return Onboarding.Seeds.AppleTree
	end
	if stage == Onboarding.Stages.RollPumpkinSeed then
		return Onboarding.Seeds.Pumpkin
	end
	return nil
end

function OnboardingService.RequiredBuySeed(profile)
	local stage = stageFor(profile)
	if stage == Onboarding.Stages.BuyAppleTreeSeed then
		return Onboarding.Seeds.AppleTree
	end
	if stage == Onboarding.Stages.BuyPumpkinSeed then
		return Onboarding.Seeds.Pumpkin
	end
	return nil
end

function OnboardingService.ResolveRollAttempt(player, profile, hasRequiredOffer)
	local stage = stageFor(profile)
	if stage == Onboarding.Stages.BuyAppleTreeSeed then
		if hasRequiredOffer then
			return false, "tutorial-buy-pending"
		end
		setStage(player, profile, Onboarding.Stages.RollAppleTreeSeed)
		return true
	end
	if stage == Onboarding.Stages.BuyPumpkinSeed then
		if hasRequiredOffer then
			return false, "tutorial-buy-pending"
		end
		setStage(player, profile, Onboarding.Stages.RollPumpkinSeed)
		return true
	end
	return true
end

function OnboardingService.OnRollCreated(player, profile, seedId)
	if seedId == Onboarding.Seeds.AppleTree then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.RollAppleTreeSeed)
	end
	if seedId == Onboarding.Seeds.Pumpkin then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.RollPumpkinSeed)
	end
	return false
end

function OnboardingService.OnSeedPurchased(player, profile, seedId)
	if seedId == Onboarding.Seeds.AppleTree then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.BuyAppleTreeSeed)
	end
	if seedId == Onboarding.Seeds.Pumpkin then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.BuyPumpkinSeed)
	end
	return false
end

function OnboardingService.OnSeedPlaced(player, profile, plot, placedFeed, seedId, feedType)
	if seedId == Onboarding.Seeds.AppleTree
		and feedType == Onboarding.FeedTypes.AppleTree
		and isInsideStarterArea(plot, placedFeed) then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.PlantAppleTreeSeed)
	end
	if seedId == Onboarding.Seeds.Pumpkin
		and feedType == Onboarding.FeedTypes.Pumpkin
		and isInsideStarterArea(plot, placedFeed) then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.PlantPumpkinSeed)
	end
	return false
end

-- Patch growth is derived (no per-second server tick), so Patches only runs
-- its periodic onboarding reporting for players currently in this stage.
function OnboardingService.NeedsPatchXPReports(profile)
	return stageFor(profile) == Onboarding.Stages.GatherPumpkinXP
end

function OnboardingService.OnPatchXPGained(player, profile, machine, xpGained)
	if stageFor(profile) ~= Onboarding.Stages.GatherPumpkinXP then
		return false
	end
	if feedTypeOf(machine) ~= Onboarding.FeedTypes.Pumpkin then
		return false
	end
	xpGained = tonumber(xpGained) or 0
	if xpGained <= 0 then
		return false
	end

	local progress = progressFor(profile)
	local total = math.min(
		(progress[Onboarding.ProgressKeys.PumpkinXPGained] or 0) + xpGained,
		Onboarding.PumpkinXPRequired
	)
	progress[Onboarding.ProgressKeys.PumpkinXPGained] = total
	if total >= Onboarding.PumpkinXPRequired then
		return OnboardingService.Advance(player, profile, Onboarding.Stages.GatherPumpkinXP)
	end
	publishOnboarding(player, profile)
	return true
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

function OnboardingService.OnGridPartUnlocked(player, profile, gridPart)
	if stageFor(profile) ~= Onboarding.Stages.ExpandFarm then
		return false
	end
	if not isExpandFarmGridPart(gridPart) then
		return false
	end
	return OnboardingService.Advance(player, profile, Onboarding.Stages.ExpandFarm)
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
	local slotKey = tostring(slotIndex)
	local droppedSlots = activeDroppedSlotsFor(machine, Onboarding.FoodIds.Apple)
	droppedSlots[slotKey] = true
	progress[Onboarding.ProgressKeys.TreeDroppedSlots] = droppedSlots
	local visibleFruitCount = countDroppedSlots(droppedSlots)
	local clickCount = math.min(
		(progress[Onboarding.ProgressKeys.TreeClickCount] or 0) + 1,
		Onboarding.TreeClicksRequired
	)
	progress[Onboarding.ProgressKeys.TreeClickCount] = clickCount
	progress[Onboarding.ProgressKeys.TreeFruitTarget] = visibleFruitCount
	progress[Onboarding.ProgressKeys.TreeFruitCollected] = progress[Onboarding.ProgressKeys.TreeFruitCollected] or 0

	if clickCount >= Onboarding.TreeClicksRequired then
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
	local collectedSoFar = progress[Onboarding.ProgressKeys.TreeFruitCollected] or 0
	local target = progress[Onboarding.ProgressKeys.TreeFruitTarget] or 0
	local visibleFruitCount = countDroppedSlots(activeDroppedSlotsFor(machine, Onboarding.FoodIds.Apple))
	local collectibleTotal = collectedSoFar + visibleFruitCount
	if collectibleTotal > 0 then
		target = math.min(math.max(target, 1), collectibleTotal)
	else
		target = math.max(target, 1)
	end
	local collected = math.min(collectedSoFar + 1, target)
	progress[Onboarding.ProgressKeys.TreeFruitTarget] = target
	progress[Onboarding.ProgressKeys.TreeFruitCollected] = collected

	if collected >= target then
		return setStage(player, profile, Onboarding.Stages.FeedPetApple)
	end
	publishOnboarding(player, profile)
	return true
end

RuntimeGuard.Connect(Players.PlayerRemoving, "OnboardingService.PlayerRemoving", function(player)
	cancelFinalNoteCompletion(player)
end)

return OnboardingService
