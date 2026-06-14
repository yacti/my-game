local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")

local Server            = ServerScriptService:WaitForChild("Server")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Remotes           = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard      = require(Shared:WaitForChild("RuntimeGuard"))
Remotes.validateAll()

local function requireReplicaServer()
	local moduleScript = ServerScriptService:FindFirstChild("ReplicaServer")
	assert(moduleScript and moduleScript:IsA("ModuleScript"), "Missing ServerScriptService.ReplicaServer ModuleScript")
	return require(moduleScript)
end

require(Server:WaitForChild("PlotLoader")).Load()
require(Server:WaitForChild("AssetValidator")).validate()
requireReplicaServer()

local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService       = require(Server:WaitForChild("PlotService"))
local PlotGridService   = require(Server:WaitForChild("PlotGridService"))
local PetMotionService  = require(Server:WaitForChild("PetMotionService"))
local CurrencyService   = require(Server:WaitForChild("CurrencyService"))
local CosmeticTools     = require(Server:WaitForChild("CosmeticTools"))
local CosmeticPlacementService = require(Server:WaitForChild("CosmeticPlacementService"))
local CosmeticShopService = require(Server:WaitForChild("CosmeticShopService"))
local FeedMachines      = require(Server:WaitForChild("feedMachines"))
local FeedMachineTools  = require(Server:WaitForChild("FeedMachineTools"))
local FeedEditService   = require(Server:WaitForChild("FeedEditService"))
local FeedGrowthService = require(Server:WaitForChild("FeedGrowthService"))
local FeedPlacementService = require(Server:WaitForChild("FeedPlacementService"))
local GearShopService = require(Server:WaitForChild("GearShopService"))
local InventoryDeleteService = require(Server:WaitForChild("InventoryDeleteService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PromptInteractionService = require(Server:WaitForChild("PromptInteractionService"))
local RebirthService    = require(Server:WaitForChild("RebirthService"))
local ReceiptService    = require(Server:WaitForChild("ReceiptService"))
local RollService       = require(Server:WaitForChild("RollService"))
local SeedPackShopService = require(Server:WaitForChild("SeedPackShopService"))
local ServerLuckService = require(Server:WaitForChild("ServerLuckService"))
local SeedTools         = require(Server:WaitForChild("SeedTools"))
local ShovelService     = require(Server:WaitForChild("ShovelService"))
local ShovelTools       = require(Server:WaitForChild("ShovelTools"))
local StarterPackShopService = require(Server:WaitForChild("StarterPackShopService"))
local TelemetryService  = require(Server:WaitForChild("TelemetryService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local VipService = require(Server:WaitForChild("VipService"))

local Interactions = require(Shared:WaitForChild("Interactions"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local State    = require(Shared:WaitForChild("State"))
local Food     = require(Shared:WaitForChild("Food"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local GridUnlockEffect = Remotes.get(Remotes.Names.GridUnlockEffect)
local PlotStressTest = nil

if RunService:IsStudio() then
	local devFolder = Server:FindFirstChild("dev")
	local stressModule = devFolder and devFolder:FindFirstChild("PlotStressTest")
	if stressModule and stressModule:IsA("ModuleScript") then
		PlotStressTest = require(stressModule)
	end
end

CurrencyService.RegisterChangedCallback(function(player, profile, amount)
	OnboardingService.OnCurrencyChanged(player, profile, amount)
end)

local PROMPT_RATE_SECONDS = 0.12
local PLACE_RATE_SECONDS = 0.25
local PET_COLLECTION_DISTANCE = 5
local PET_COLLECTION_INTERVAL = 0.25
local PET_FEED_REACTION_SECONDS = 2
local PET_FEED_PROMPT_DISTANCE = 8
local PET_EVOLUTION_IDLE_HOLD_SECONDS = 4
local OFFLINE_PET_EARN_FRACTION = 0.01
local FOOD_PICKUP_PROMPT_DISTANCE = 8
local EDIT_MODE_ATTR = "EditMode"
local FOOD_COLLECTION_SNAPSHOT = "FoodCollection"

local function userLabel(player)
	return tostring(player and player.UserId or "unknown")
end

RuntimeGuard.Run("PlotGridService.ResetVacantPlotsToPreviewRows", PlotGridService.ResetVacantPlotsToPreviewRows)
RuntimeGuard.Run("PlotService.SyncVacantPlotVisibility", PlotService.SyncVacantPlotVisibility)

RuntimeGuard.Run("RebirthService.Start", RebirthService.Start)
RuntimeGuard.Run("GearShopService.Start", GearShopService.Start)
RuntimeGuard.Run("CosmeticShopService.Start", CosmeticShopService.Start)
RuntimeGuard.Run("SeedPackShopService.Start", SeedPackShopService.Start)
RuntimeGuard.Run("StarterPackShopService.Start", StarterPackShopService.Start)
RuntimeGuard.Run("ServerLuckService.Start", ServerLuckService.Start)
RuntimeGuard.Run("VipService.Start", VipService.Start)
RuntimeGuard.Run("ReceiptService.Start", function()
	ReceiptService.Start({
		rebirthService = RebirthService,
		gearShopService = GearShopService,
		cosmeticShopService = CosmeticShopService,
		seedPackShopService = SeedPackShopService,
		starterPackShopService = StarterPackShopService,
		serverLuckService = ServerLuckService,
	})
end)
RuntimeGuard.Run("RollService.Start", RollService.Start)
RuntimeGuard.Run("OfflineProgressService.Start", OfflineProgressService.Start)

-- ── Pet state save ────────────────────────────────────────────────────────────

-- Rebuild profile.Data.Pets from the current plot state (source of truth is the
-- spawned Models and their attributes). Preserves xp/money from the existing
-- profile entry when possible; falls back to 0.
local function collectPetsFromPlot(plot, profile)
	local floor = PlotService.GetFloor(plot)
	local saved = {}
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		if idx then
			local existing = profile.Data.Pets and profile.Data.Pets[idx] or nil
			local entry = {
				petId = pet:GetAttribute(State.Pet.Id) or (existing and existing.petId) or "Pet1",
				xp    = existing and existing.xp or 0,
				money = existing and existing.money or 0,
			}
			-- Position + rotation are stored in floor-local space so they
			-- survive Floor rotations / translations between sessions.
			if floor then
				local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, PetMotionService.GetLogicalPivot(pet))
				entry.lx, entry.lz, entry.lry = lx, lz, lry
			end
			saved[idx] = entry
		end
	end
	return saved
end

local function savePetsFromPlot(plot, profile)
	profile.Data.Pets = collectPetsFromPlot(plot, profile)
end

-- ── Feed state save ───────────────────────────────────────────────────────────

local function collectFeedState(plot, player)
	local floor = PlotService.GetFloor(plot)
	local placements = {}
	if floor then
		for _, f in ipairs(PlotService.GetSortedFeeds(plot)) do
			-- GetPivot works uniformly for BasePart and Model. We store the
			-- pivot in the floor's local frame (lx/lz/lry) so placements
			-- survive Floor rotations / translations.
			local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, f:GetPivot())
			local feedType = f:GetAttribute(State.Feed.Type)
			if type(feedType) ~= "string" or feedType == "" then
				continue
			end
			local rec = {
				type = feedType,
				lx   = lx,
				lz   = lz,
				lry  = lry,
			}
			-- Per-class extras (or growing-seed state). Merged shallow.
			local extras = FeedGrowthService.IsGrowing(f)
				and FeedGrowthService.Serialize(f)
				or FeedMachines.Serialize(f)
			if type(extras) == "table" then
				for k, v in pairs(extras) do rec[k] = v end
			end
			table.insert(placements, rec)
		end
	end

	local feedInventory = {}
	local function captureTool(item)
		if not FeedMachineTools.IsFeedTool(item) then return end
		local ft = item:GetAttribute(State.Feed.Type)
		feedInventory[ft] = (feedInventory[ft] or 0) + 1
	end
	for _, item in pairs(player.Backpack:GetChildren()) do captureTool(item) end
	if player.Character then
		captureTool(player.Character:FindFirstChildWhichIsA("Tool"))
	end

	return {
		FeedPlacements = placements,
		FeedInventory = feedInventory,
		SeedInventory = SeedTools.CountBySeed(player),
		FoodInventory = Food.CountByType(player),
	}
end

local function collectFeedPlacementRecord(plot, feed)
	local floor = PlotService.GetFloor(plot)
	if not (floor and feed and feed:IsDescendantOf(plot)) then
		return nil
	end
	local feedType = feed:GetAttribute(State.Feed.Type)
	if type(feedType) ~= "string" or feedType == "" then
		return nil
	end

	local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, feed:GetPivot())
	local rec = {
		type = feedType,
		lx = lx,
		lz = lz,
		lry = lry,
	}
	local extras = FeedGrowthService.IsGrowing(feed)
		and FeedGrowthService.Serialize(feed)
		or FeedMachines.Serialize(feed)
	if type(extras) == "table" then
		for k, v in pairs(extras) do rec[k] = v end
	end
	return rec
end

local function collectCosmeticState(plot, player)
	local floor = PlotService.GetFloor(plot)
	local placements = {}
	if floor then
		for _, cosmetic in ipairs(PlotService.GetSortedCosmetics(plot)) do
			local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, cosmetic:GetPivot())
			local cosmeticId = cosmetic:GetAttribute(State.Cosmetic.Id)
			if type(cosmeticId) ~= "string" or cosmeticId == "" then
				continue
			end
			table.insert(placements, {
				id = cosmeticId,
				lx = lx,
				lz = lz,
				lry = lry,
			})
		end
	end

	return {
		CosmeticPlacements = placements,
		CosmeticInventory = CosmeticTools.CountByCosmetic(player),
	}
end

local function snapshotProfileState(player, plot, profile)
	if not plot or not profile then return false end
	if OfflineProgressService.IsPending(player) then
		local applied = OfflineProgressService.ApplyPendingBeforeSnapshot(player)
		if applied ~= true then
			return false
		end
	end
	local petsOk, pets = RuntimeGuard.Run("snapshotProfileState.collectPets", collectPetsFromPlot, plot, profile)
	local feedOk, feedState = RuntimeGuard.Run("snapshotProfileState.collectFeed", collectFeedState, plot, player)
	local cosmeticOk, cosmeticState = RuntimeGuard.Run("snapshotProfileState.collectCosmetics", collectCosmeticState, plot, player)
	if not (petsOk and feedOk and cosmeticOk) then
		return false
	end
	profile.Data.Pets = pets
	profile.Data.FeedPlacements = feedState.FeedPlacements
	profile.Data.CosmeticPlacements = cosmeticState.CosmeticPlacements
	profile.Data.CosmeticInventory = cosmeticState.CosmeticInventory
	profile.Data.FeedInventory = feedState.FeedInventory
	profile.Data.SeedInventory = feedState.SeedInventory
	profile.Data.FoodInventory = feedState.FoodInventory
	profile.Data.LastSeen = os.time()
	local publishRunOk, published = RuntimeGuard.Run("snapshotProfileState.publishProfile", PlayerReplicaService.PublishProfile, player, profile)
	if publishRunOk and published ~= true then
		warn("[init] Snapshot saved but PlayerState replica was not updated for user " .. userLabel(player))
	end
	return true
end

local function snapshotFoodCollection(player, plot, profile, feed)
	if not plot or not profile then return false end
	if OfflineProgressService.IsPending(player) then
		return false
	end
	if not feed then return false end
	local feedIndex = feed:GetAttribute(State.Feed.Index)
	local placement = collectFeedPlacementRecord(plot, feed)
	if type(feedIndex) ~= "number" or feedIndex < 1 or not placement then
		return false
	end
	profile.Data.FeedPlacements = profile.Data.FeedPlacements or {}
	profile.Data.FeedPlacements[feedIndex] = placement
	profile.Data.FoodInventory = Food.CountByType(player)
	profile.Data.LastSeen = os.time()
	local publishRunOk, published = RuntimeGuard.Run(
		"snapshotFoodCollection.publishFoodInventory",
		PlayerReplicaService.PublishFoodInventory,
		player,
		profile
	)
	if publishRunOk and published ~= true then
		warn("[init] Food collection snapshot saved but food inventory replica was not updated for user " .. userLabel(player))
	end
	return true
end

local function notifyGrown(player, feed)
	if not (player and feed) then return end
	NotificationService.Success(player, string.format("%s has grown!", feed.Name))
end

RuntimeGuard.Run("FeedGrowthService.Start", function()
	FeedGrowthService.Start({
		onMature = function(player, plot, matureFeed)
			notifyGrown(player, matureFeed)
			PetMotionService.RefreshPlotRoutes(plot)
			local profile = PlayerDataService.GetProfile(player)
			if profile then
				snapshotProfileState(player, plot, profile)
			end
		end,
	})
end)

-- ── Pet state replication ────────────────────────────────────────────────────
-- Per-pet state is published as attributes on the pet Model. Clients subscribe
-- via GetAttributeChangedSignal and render billboards locally (see
-- src/client/ui/PetBillboards.luau). No UI is created server-side.

local function publishPetState(pet, money, xp)
	pet:SetAttribute(State.Pet.Money, money or 0)
	pet:SetAttribute(State.Pet.XP,    xp or 0)
end

local function publishPetEvolutionCue(pet, oldPetId, oldScale, pivot, seq)
	pet:SetAttribute(State.Pet.EvolutionOldPetId, oldPetId)
	pet:SetAttribute(State.Pet.EvolutionOldScale, oldScale)
	pet:SetAttribute(State.Pet.EvolutionPivot, pivot)
	pet:SetAttribute(State.Pet.EvolutionSeq, seq)

	task.delay(8, function()
		RuntimeGuard.Run("PetEvolutionCue.ClearDelayed", function()
			if pet.Parent and pet:GetAttribute(State.Pet.EvolutionSeq) == seq then
				-- Keep the sequence monotonic, but remove stale payload so late
				-- clients do not replay an already-finished evolution.
				pet:SetAttribute(State.Pet.EvolutionOldPetId, nil)
				pet:SetAttribute(State.Pet.EvolutionOldScale, nil)
				pet:SetAttribute(State.Pet.EvolutionPivot, nil)
			end
		end)
	end)
end

-- ── Pet feeding + evolution ──────────────────────────────────────────────────

local function tryEvolvePet(plot, pet, profile)
	local idx = pet:GetAttribute(State.Pet.Index)
	local petData = profile.Data.Pets[idx]
	if not petData then return end

	local activePet = pet
	local evolved = false
	local firstPetId = nil
	local firstScale = nil
	local firstPivot = nil
	local evolutionSeq = nil

	while activePet and activePet.Parent do
		local petId = activePet:GetAttribute(State.Pet.Id)
		local maxXP = activePet:GetAttribute(State.Pet.MaxXP)
		local currentXP = petData.xp or 0
		if type(maxXP) ~= "number" or maxXP <= 0 then
			petData.xp = 0
			break
		end

		if currentXP < maxXP then
			break
		end

		local nextPetId = PetCatalog.NextPetId(petId)
		if not nextPetId then
			petData.xp = math.min(currentXP, maxXP)
			break
		end

		if not firstPetId then
			firstPetId = petId
			firstScale = activePet:GetScale()
			firstPivot = PetMotionService.GetLogicalPivot(activePet)
			evolutionSeq = (activePet:GetAttribute(State.Pet.EvolutionSeq) or 0) + 1
		end

		local evolutionPivot = PetMotionService.GetLogicalPivot(activePet)
		local currentVisual = PetCatalog.VisualForPetId(petId)
		local nextVisual = PetCatalog.VisualForPetId(nextPetId)
		local nextXP = math.max(currentXP - maxXP, 0)

		if currentVisual and nextVisual and currentVisual.ModelName == nextVisual.ModelName then
			if not PlotService.ApplyPetIdAttributes(activePet, nextPetId) then
				break
			end
		else
			local newPet = PlotService.ReplacePetAt(plot, activePet, nextPetId, idx, nextXP, evolutionPivot)
			if not newPet then
				return nil, evolved
			end
			activePet = newPet
			PetMotionService.Register(plot, activePet)
		end

		petData.petId = nextPetId
		petData.xp = nextXP
		evolved = true
	end

	if not activePet or not activePet.Parent then return nil, evolved end

	local logicalPivot = PetMotionService.GetLogicalPivot(activePet)
	PlotService.RescalePet(activePet, petData.xp, logicalPivot)
	publishPetState(activePet, petData.money, petData.xp)

	if evolved then
		publishPetEvolutionCue(activePet, firstPetId, firstScale, firstPivot, evolutionSeq)
	end

	return activePet, evolved
end

local function primaryPartOf(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then return instance end
	if instance:IsA("Model") then return instance.PrimaryPart end
	return nil
end

local function positionOfInstance(instance)
	if instance and instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil then
		return PetMotionService.GetLogicalPosition(instance)
	end

	local primary = primaryPartOf(instance)
	return primary and primary.Position or nil
end

local function isPlayerNearInstance(player, instance, maxDistance)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = positionOfInstance(instance)
	return root ~= nil
		and root:IsA("BasePart")
		and position ~= nil
		and (root.Position - position).Magnitude <= maxDistance
end

local function playerFloorLocal(plot, player)
	local floor = PlotService.GetFloor(plot)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (floor and root and root:IsA("BasePart")) then return nil, nil end

	local faceLX, faceLZ = PlotService.WorldPivotToFloorLocal(floor, root.CFrame)
	return faceLX, faceLZ
end

local function triggerPetFeedReaction(pet, faceLX, faceLZ)
	if type(faceLX) ~= "number" or type(faceLZ) ~= "number" then return end

	local seq = (pet:GetAttribute(State.Pet.FeedReactionSeq) or 0) + 1
	local direction = seq % 2 == 0 and 1 or -1

	pet:SetAttribute(State.Pet.FeedReactionSeq, seq)
	pet:SetAttribute(State.Pet.FeedReactionStartTime, workspace:GetServerTimeNow())
	pet:SetAttribute(State.Pet.FeedReactionDuration, PET_FEED_REACTION_SECONDS)
	pet:SetAttribute(State.Pet.FeedReactionDirection, direction)
	pet:SetAttribute(State.Pet.FeedReactionFaceLX, faceLX)
	pet:SetAttribute(State.Pet.FeedReactionFaceLZ, faceLZ)
end

local function feedPet(plot, player, profile, pet)
	if not pet or not pet:IsA("Model") or not pet:IsDescendantOf(plot) then return false end
	local primary = pet.PrimaryPart
	if not primary then return false end
	if player:GetAttribute("EditMode") == true then return false end
	if not isPlayerNearInstance(player, pet, PET_FEED_PROMPT_DISTANCE) then return false end

	local idx = pet:GetAttribute(State.Pet.Index)
	local petData = profile.Data.Pets[idx]
	if not petData then return false end

	local maxXP = pet:GetAttribute(State.Pet.MaxXP)
	if type(maxXP) ~= "number" or maxXP <= 0 then return false end
	if (petData.xp or 0) >= maxXP and PetCatalog.NextPetId(pet:GetAttribute(State.Pet.Id)) == nil then return false end

	local food = Food.FindForPetFeed(player)
	if not food then return false end

	local foodXP = Food.XPOf(food)
	if not foodXP then return false end
	local foodGuid = ToolIdentity.EnsureGuid(food)
	if not ToolIdentity.DestroyIfGuidMatches(food, foodGuid) then return false end

	petData.xp = (petData.xp or 0) + foodXP
	local activePet = pet
	local evolved = false
	if petData.xp >= maxXP then
		activePet, evolved = tryEvolvePet(plot, pet, profile)
		if not activePet or not activePet.Parent then return false end
	else
		local logicalPivot = PetMotionService.GetLogicalPivot(pet)
		PlotService.RescalePet(pet, petData.xp, logicalPivot)
		pet:SetAttribute(State.Pet.XP, petData.xp)
	end
	local faceLX, faceLZ = playerFloorLocal(plot, player)
	PetMotionService.HoldAfterFeed(activePet, faceLX, faceLZ, evolved and PET_EVOLUTION_IDLE_HOLD_SECONDS or nil)
	triggerPetFeedReaction(activePet, faceLX, faceLZ)
	return true
end

-- ── Currency / offline helpers ────────────────────────────────────────────────

local function applyOfflineEarnings(player, plot, profile, lastSeen, joinTime)
	lastSeen = tonumber(lastSeen) or profile.Data.LastSeen or 0
	if lastSeen == 0 then return true end
	local elapsed = (tonumber(joinTime) or os.time()) - lastSeen
	if elapsed <= 0 then return true end

	local earnRate = VipService.PetCashEarnRate(player)
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		local petData = profile.Data.Pets[idx]
		if petData then
			local rate = pet:GetAttribute(State.Pet.MoneyRate) or 1
			petData.money = (petData.money or 0) + rate * elapsed * OFFLINE_PET_EARN_FRACTION * earnRate
			pet:SetAttribute(State.Pet.Money, petData.money)
		end
	end
	return true
end

OfflineProgressService.RegisterSystem("PetMoney", function(context)
	return applyOfflineEarnings(context.player, context.plot, context.profile, context.lastSeen, context.joinTime)
end)

OfflineProgressService.RegisterSystem("FeedMachines", function(context)
	for _, feed in ipairs(PlotService.GetSortedFeeds(context.plot)) do
		if not FeedGrowthService.IsGrowing(feed) then
			if not FeedMachines.ApplyOfflineProgress(feed, context) then
				return false, "feed-machine-failed"
			end
		end
	end
	return true
end)

OfflineProgressService.RegisterSystem("GrowingSeeds", function(context)
	local ok = FeedGrowthService.ApplyOfflineProgress(context)
	if ok then
		PetMotionService.RefreshPlotRoutes(context.plot)
	end
	return ok
end)

local function startPetMoneyLoop(player, plot, profile)
	local label = userLabel(player)
	RuntimeGuard.Spawn("PetMoneyLoop." .. label, function()
		while PlotService.GetPlayerPlot(player) == plot do
			task.wait(1)
			RuntimeGuard.Run("PetMoneyTick." .. label, function()
				if OfflineProgressService.IsPending(player) then
					return
				end
				local earnRate = VipService.PetCashEarnRate(player)
				for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
					local idx = pet:GetAttribute(State.Pet.Index)
					local petData = profile.Data.Pets[idx]
					if petData then
						local rate = pet:GetAttribute(State.Pet.MoneyRate) or 1
						petData.money = (petData.money or 0) + rate * earnRate
						pet:SetAttribute(State.Pet.Money, petData.money)
					end
				end
			end)
		end
	end)
end

local function startPetCollectionLoop(player, plot, profile)
	local label = userLabel(player)
	RuntimeGuard.Spawn("PetCollectionLoop." .. label, function()
		while PlotService.GetPlayerPlot(player) == plot do
			task.wait(PET_COLLECTION_INTERVAL)
			RuntimeGuard.Run("PetCollectionTick." .. label, function()
				if OfflineProgressService.IsPending(player) then
					return
				end
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if not (root and root:IsA("BasePart")) then
					return
				end

				for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
					local idx = pet:GetAttribute(State.Pet.Index)
					local petData = profile.Data.Pets[idx]
					if not petData then
						continue
					end

					local money = petData.money or 0
					if money < 1 then
						continue
					end

					local petPosition = PetMotionService.GetLogicalPosition(pet)
					if (root.Position - petPosition).Magnitude <= PET_COLLECTION_DISTANCE then
						CurrencyService.Add(player, profile, money)
						petData.money = 0
						pet:SetAttribute(State.Pet.Money, 0)
					end
				end
			end)
		end
	end)
end

local function startProfileSnapshotLoop(player, plot, profile)
	local label = userLabel(player)
	RuntimeGuard.Spawn("ProfileSnapshotLoop." .. label, function()
		while PlotService.GetPlayerPlot(player) == plot and PlayerDataService.GetProfile(player) == profile do
			task.wait(60)
			if PlotService.GetPlayerPlot(player) == plot and PlayerDataService.GetProfile(player) == profile then
				RuntimeGuard.Run("ProfileSnapshotTick." .. label, snapshotProfileState, player, plot, profile)
			end
		end
	end)
end

local function unlockGridPart(target, plot, player, profile)
	local gridPart = PlotGridService.ResolveGridPart(target)
	if not OnboardingService.CanUnlockGridPart(profile, gridPart) then
		TelemetryService.Warn("grid_unlock_failed", TelemetryService.ForPlayer(player, {
			reason = "tutorial-target-mismatch",
			target = target,
			plot = plot,
		}))
		return
	end

	local ok, code, _, price = PlotGridService.TryPurchaseCell(player, plot, profile, target)
	if not ok then
		if code ~= "already-unlocked" and code ~= "busy" then
			TelemetryService.Warn("grid_unlock_failed", TelemetryService.ForPlayer(player, {
				reason = code,
				target = target,
				plot = plot,
			}))
		end
		if code == "already-unlocked" then
			NotificationService.Info(player, "That plot area is already unlocked.")
		elseif code == "insufficient-currency" then
			NotificationService.Error(player, "Not enough currency for this plot area.")
		elseif code ~= "busy" then
			NotificationService.Error(player, "Could not unlock that plot area.")
		end
		return
	end

	PetMotionService.RefreshPlotRoutes(plot)
	PlayerReplicaService.PublishUnlockedGridKeys(player, profile)
	OnboardingService.OnGridPartUnlocked(player, profile, gridPart)
	if gridPart then
		RuntimeGuard.Run("GridUnlockEffect.FireAllClients", function()
			GridUnlockEffect:FireAllClients(gridPart)
		end)
	end
	TelemetryService.Record("grid_unlock_succeeded", TelemetryService.ForPlayer(player, {
		price = price,
		gridPart = gridPart,
		plot = plot,
		currency = profile.Data.Currency,
	}))
	NotificationService.Success(player, "Plot area unlocked for " .. NumberFormatter.Currency(price) .. "!")
end

-- ── Player lifecycle ──────────────────────────────────────────────────────────

local function teardownPlayerState(player, plot, profile, options)
	options = options or {}
	local label = userLabel(player)
	if options.snapshot == true and plot and profile then
		RuntimeGuard.Run("PlayerTeardown.ApplyPendingOffline." .. label, OfflineProgressService.ApplyPendingBeforeSnapshot, player)
		RuntimeGuard.Run("PlayerTeardown.Snapshot." .. label, snapshotProfileState, player, plot, profile)
	end
	RuntimeGuard.Run("PlayerTeardown.ClearOfflineProgress." .. label, OfflineProgressService.Clear, player)
	if plot then
		RuntimeGuard.Run("PlayerTeardown.UnregisterPets." .. label, PetMotionService.UnregisterPlot, plot)
		RuntimeGuard.Run("PlayerTeardown.DestroyPets." .. label, PlotService.DestroyPets, plot)
		RuntimeGuard.Run("PlayerTeardown.DestroyFeeds." .. label, PlotService.DestroyFeeds, plot)
		RuntimeGuard.Run("PlayerTeardown.DestroyCosmetics." .. label, PlotService.DestroyCosmetics, plot)
		RuntimeGuard.Run("PlayerTeardown.ResetGrid." .. label, PlotGridService.ResetVacantPlotState, plot)
		RuntimeGuard.Run("PlayerTeardown.FreePlot." .. label, PlotService.FreePlot, player)
	end
	RuntimeGuard.Run("PlayerTeardown.ClearAttributes." .. label, function()
		player:SetAttribute(State.Player.AssignedPlotName, nil)
		player:SetAttribute(EDIT_MODE_ATTR, false)
		player.RespawnLocation = nil
	end)
	RuntimeGuard.Run("PlayerTeardown.DestroyReplica." .. label, PlayerReplicaService.Destroy, player)
	RuntimeGuard.Run("PlayerTeardown.UnloadProfile." .. label, PlayerDataService.UnloadPlayer, player)
end

local function handlePlayerAdded(player)
	player:SetAttribute(EDIT_MODE_ATTR, false)

	local plot, _ = PlotService.AssignPlot(player)
	if not plot then
		player:Kick("The server is full (all plots are taken).")
		return
	end
	player:SetAttribute(State.Player.AssignedPlotName, plot.Name)
	PlotGridService.ResetPlotState(plot)
	RollService.ApplyDropAreaVisibility(plot, 0)

	local spawnLocation = plot:FindFirstChild("SpawnLocation")
	if spawnLocation then player.RespawnLocation = spawnLocation end

	local profile = PlayerDataService.LoadPlayerAsync(player)
	if not profile then
		teardownPlayerState(player, plot, nil, { snapshot = false })
		return
	end
	if PlotStressTest and PlotStressTest.ShouldDisableTutorial() then
		RuntimeGuard.Run("PlotStressTest.PreparePlayerProfile." .. userLabel(player), PlotStressTest.PreparePlayerProfile, player, profile)
	end

	local label = userLabel(player)
	local setupOk = RuntimeGuard.Run("PlayerAdded.Setup." .. label, function()
		local offlineSession = OfflineProgressService.Begin(player, plot, profile)
		local deferOfflineProgress = offlineSession ~= nil
		local applied, applyReason = PlotGridService.ApplyProfileState(plot, profile)
		if not applied then
			warn(string.format("[init] Failed to apply user %s plot grid state: %s", userLabel(player), tostring(applyReason)))
			PlotGridService.ResetPlotState(plot)
		end
		RollService.ApplyDropAreaVisibility(plot, profile)

		PlotService.SpawnPetsForPlot(plot, profile.Data.Pets)
		local maturedOnLoad = {}
		for index, placement in ipairs(profile.Data.FeedPlacements or {}) do
			if type(placement) == "table" and placement.phase == FeedGrowthService.Phase then
				local restored, status = FeedGrowthService.RestorePlacement(plot, player, placement, index, {
					deferOfflineProgress = deferOfflineProgress,
				})
				if restored and status == "mature" then
					maturedOnLoad[#maturedOnLoad + 1] = restored
				end
			else
				PlotService.PlaceFeedWithIndex(plot, placement.type, index, placement.lx or 0, placement.lz or 0, placement.lry or 0)
			end
		end

		for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
			if FeedGrowthService.IsGrowing(feed) then
				continue
			end
			local setupSucceeded, setupCode = FeedMachines.Setup(feed, plot, player)
			if not setupSucceeded then
				error("failed to setup feed machine: " .. tostring(setupCode))
			end
			local idx   = feed:GetAttribute(State.Feed.Index)
			local saved = idx and profile.Data.FeedPlacements[idx] or nil
			if saved and saved.phase ~= FeedGrowthService.Phase then
				FeedMachines.Apply(feed, saved, {
					deferOfflineProgress = deferOfflineProgress,
					freezeAt = offlineSession and offlineSession.lastSeen or nil,
				})
			end
		end
		for _, feed in ipairs(maturedOnLoad) do
			task.defer(function()
				RuntimeGuard.Run("PlayerAdded.NotifyGrownDeferred." .. label, notifyGrown, player, feed)
			end)
		end

		for index, placement in ipairs(profile.Data.CosmeticPlacements or {}) do
			if type(placement) ~= "table" or type(placement.id) ~= "string" then
				continue
			end
			PlotService.PlaceCosmeticWithIndex(plot, placement.id, index, placement.lx or 0, placement.lz or 0, placement.lry or 0)
		end

		VipService.RefreshOwnership(player)
		if not deferOfflineProgress then
			applyOfflineEarnings(player, plot, profile)
		end

		PlayerReplicaService.Create(player, profile)
		OfflineProgressService.Publish(player)
		OnboardingService.ApplyCurrentStageEntry(player, profile)

		for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
			local idx = pet:GetAttribute(State.Pet.Index)
			local petData = profile.Data.Pets[idx]
			local money = petData and petData.money or 0
			local xp = petData and petData.xp or 0
			publishPetState(pet, money, xp)
			PetMotionService.Register(plot, pet)
		end

		startPetMoneyLoop(player, plot, profile)
		startPetCollectionLoop(player, plot, profile)
		startProfileSnapshotLoop(player, plot, profile)

		local toolsRestored = false
		local function onCharacterAdded(character)
			ShovelTools.EnsureUtilityTool(player)
			if not toolsRestored then
				toolsRestored = true
				task.wait(0.5)
				-- Materialize at most the global cap; hoarded profiles beyond it
				-- would otherwise burst thousands of replicated instances on join.
				local remainingSlots = Inventory.RemainingSlots(player)
				local function sortedKeys(map)
					local keys = {}
					if type(map) == "table" then
						for key in pairs(map) do
							keys[#keys + 1] = key
						end
					end
					table.sort(keys, function(left, right)
						return tostring(left) < tostring(right)
					end)
					return keys
				end
				local function restoreCountedTool(makeTool)
					if remainingSlots <= 0 then
						return false
					end
					local tool = makeTool()
					if not tool then
						return remainingSlots > 0
					end
					if Inventory.IsCountableTool(tool) then
						remainingSlots -= 1
					end
					tool.Parent = player.Backpack
					return remainingSlots > 0
				end
				local function restoreMap(map, makeTool)
					for _, itemId in ipairs(sortedKeys(map)) do
						local count = math.max(math.floor(tonumber(map[itemId]) or 0), 0)
						for _ = 1, count do
							if not restoreCountedTool(function()
								return makeTool(itemId)
							end) then
								return
							end
						end
					end
				end
				restoreMap(profile.Data.FoodInventory, Food.MakeTool)
				restoreMap(profile.Data.FeedInventory, FeedMachineTools.MakeFeedTool)
				restoreMap(profile.Data.SeedInventory, SeedTools.MakeSeedTool)
				restoreMap(profile.Data.CosmeticInventory, CosmeticTools.MakeCosmeticTool)
			end
		end

		if player.Character then
			RuntimeGuard.Run("CharacterAdded.Initial." .. label, onCharacterAdded, player.Character)
		end
		RuntimeGuard.Connect(player.CharacterAdded, "CharacterAdded." .. label, onCharacterAdded)
	end)

	if not setupOk then
		teardownPlayerState(player, plot, profile, { snapshot = false })
		RuntimeGuard.Run("PlayerAdded.KickFailedSetup." .. label, function()
			if player:IsDescendantOf(Players) then
				player:Kick("Could not initialize your session. Please rejoin.")
			end
		end)
	end
end

RuntimeGuard.Connect(Players.PlayerAdded, "Players.PlayerAdded", handlePlayerAdded)

local function handlePlayerRemoving(player)
	local plot = PlotService.GetPlayerPlot(player)
	local profile = PlayerDataService.GetProfile(player)
	teardownPlayerState(player, plot, profile, { snapshot = true })
end

RuntimeGuard.Connect(Players.PlayerRemoving, "Players.PlayerRemoving", handlePlayerRemoving)

game:BindToClose(function()
	for _, player in pairs(Players:GetPlayers()) do
		RuntimeGuard.Run("BindToClose.Player." .. userLabel(player), function()
			local plot    = PlotService.GetPlayerPlot(player)
			local profile = PlayerDataService.GetProfile(player)
			teardownPlayerState(player, plot, profile, { snapshot = true })
		end)
	end

	-- Wait for ProfileStore sessions to finish their final save.
	local deadline = os.clock() + 25
	while PlayerDataService.ActiveProfileCount() > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

RuntimeGuard.Run("PromptInteractionService.Start", function()
	PromptInteractionService.Start({
		rateSeconds = PROMPT_RATE_SECONDS,
		getContext = function(player)
			if OfflineProgressService.IsPending(player) then
				return nil, nil
			end
			return PlotService.GetPlayerPlot(player), PlayerDataService.GetProfile(player)
		end,
		handlers = {
			[Interactions.Actions.PetFeed] = function(player, target, plot, profile)
				if feedPet(plot, player, profile, target) then
					OnboardingService.OnPetFed(player, profile)
				end
			end,
			[Interactions.Actions.FeedMachine] = function(player, target, plot)
				if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, 14) then
					FeedMachines.Interact(target, player)
				end
			end,
			[Interactions.Actions.PatchHarvest] = function(player, target, plot)
				if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, 14) then
					local ok, feed = FeedMachines.HarvestPatchAnchor(target, player)
					if ok then
						return {
							snapshot = FOOD_COLLECTION_SNAPSHOT,
							feed = feed,
						}
					end
				end
				return false
			end,
			[Interactions.Actions.TreeGroundPickup] = function(player, target, plot)
				if target:IsDescendantOf(plot) and isPlayerNearInstance(player, target, FOOD_PICKUP_PROMPT_DISTANCE) then
					local ok, feed = FeedMachines.PickupTreeGround(target, player)
					if ok then
						return {
							snapshot = FOOD_COLLECTION_SNAPSHOT,
							feed = feed,
						}
					end
				end
				return false
			end,
			[Interactions.Actions.GridPartUnlock] = function(player, target, plot, profile)
				unlockGridPart(target, plot, player, profile)
			end,
			[Interactions.Actions.CrateRoll] = function(player, target, plot, profile)
				local ok, code = RollService.Roll(player, target, plot, profile)
				if not ok and code ~= "cooldown" and code ~= "busy" and code ~= "tutorial-buy-pending" then
					NotificationService.Error(player, "Could not roll that crate.")
				end
			end,
		},
		afterInteraction = function(player, plot, profile, action, _target, handlerResult)
			if OfflineProgressService.IsPending(player) then
				return
			end
			if action == Interactions.Actions.PatchHarvest or action == Interactions.Actions.TreeGroundPickup then
				if type(handlerResult) ~= "table" or handlerResult.snapshot ~= FOOD_COLLECTION_SNAPSHOT then
					return
				end
				if snapshotFoodCollection(player, plot, profile, handlerResult.feed) then
					return
				end
				warn("[init] Falling back to full snapshot after food collection for user " .. userLabel(player))
			end
			snapshotProfileState(player, plot, profile)
		end,
	})
end)

RuntimeGuard.Run("FeedEditService.Start", function()
	FeedEditService.Start({
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = OfflineProgressService.IsPending,
	})
end)

RuntimeGuard.Run("ShovelService.Start", function()
	ShovelService.Start({
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = OfflineProgressService.IsPending,
	})
end)

RuntimeGuard.Run("InventoryDeleteService.Start", function()
	InventoryDeleteService.Start({
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = OfflineProgressService.IsPending,
	})
end)

RuntimeGuard.Run("FeedPlacementService.Start", function()
	FeedPlacementService.Start({
		rateSeconds = PLACE_RATE_SECONDS,
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = OfflineProgressService.IsPending,
	})
end)

RuntimeGuard.Run("CosmeticPlacementService.Start", function()
	CosmeticPlacementService.Start({
		rateSeconds = PLACE_RATE_SECONDS,
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = OfflineProgressService.IsPending,
	})
end)

if PlotStressTest then
	RuntimeGuard.Run("PlotStressTest.Watch", PlotStressTest.Watch)
end
