local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")

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

local AdminLuckService = require(Server:WaitForChild("AdminLuckService"))
local AdminPanelService = require(Server:WaitForChild("AdminPanelService"))
local CashPackShopService = require(Server:WaitForChild("CashPackShopService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService       = require(Server:WaitForChild("PlotService"))
local PlotWindService   = require(Server:WaitForChild("PlotWindService"))
local PlotEarthquakeService = require(Server:WaitForChild("PlotEarthquakeService"))
local GameEventService  = require(Server:WaitForChild("GameEventService"))
local LiveEventCommandService = require(Server:WaitForChild("LiveEventCommandService"))
local PlotGridService   = require(Server:WaitForChild("PlotGridService"))
local PetMotionService  = require(Server:WaitForChild("PetMotionService"))
local PetIncomeService  = require(Server:WaitForChild("PetIncomeService"))
local CurrencyService   = require(Server:WaitForChild("CurrencyService"))
local CosmeticTools     = require(Server:WaitForChild("CosmeticTools"))
local CosmeticPlacementService = require(Server:WaitForChild("CosmeticPlacementService"))
local CosmeticShopService = require(Server:WaitForChild("CosmeticShopService"))
local CollectAllService = require(Server:WaitForChild("CollectAllService"))
local DiscoveryService  = require(Server:WaitForChild("DiscoveryService"))
local DurianPackShopService = require(Server:WaitForChild("DurianPackShopService"))
local EndlessPackShopService = require(Server:WaitForChild("EndlessPackShopService"))
local FeedMachines      = require(Server:WaitForChild("feedMachines"))
local FeedMachineTools  = require(Server:WaitForChild("FeedMachineTools"))
local FeedEditService   = require(Server:WaitForChild("FeedEditService"))
local FeedGrowthService = require(Server:WaitForChild("FeedGrowthService"))
local FeedPlacementService = require(Server:WaitForChild("FeedPlacementService"))
local FoodInventoryService = require(Server:WaitForChild("FoodInventoryService"))
local FoodStealService = require(Server:WaitForChild("FoodStealService"))
local FriendBoostService = require(Server:WaitForChild("FriendBoostService"))
local GamePassService = require(Server:WaitForChild("GamePassService"))
local GearShopService = require(Server:WaitForChild("GearShopService"))
local GiftService = require(Server:WaitForChild("GiftService"))
local GrowSkipService = require(Server:WaitForChild("GrowSkipService"))
local AFKRejoinService = require(Server:WaitForChild("AFKRejoinService"))
local HomeTeleportService = require(Server:WaitForChild("HomeTeleportService"))
local InventoryDeleteService = require(Server:WaitForChild("InventoryDeleteService"))
local JoinGroupRewardService = require(Server:WaitForChild("JoinGroupRewardService"))
local MediaRewardService = require(Server:WaitForChild("MediaRewardService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PromptInteractionService = require(Server:WaitForChild("PromptInteractionService"))
local RebirthService    = require(Server:WaitForChild("RebirthService"))
local ReceiptService    = require(Server:WaitForChild("ReceiptService"))
local RollBroadcastService = require(Server:WaitForChild("RollBroadcastService"))
local RollService       = require(Server:WaitForChild("RollService"))
local SeedPackShopService = require(Server:WaitForChild("SeedPackShopService"))
local ServerLuckService = require(Server:WaitForChild("ServerLuckService"))
local SeedTools         = require(Server:WaitForChild("SeedTools"))
local ShovelService     = require(Server:WaitForChild("ShovelService"))
local ShovelTools       = require(Server:WaitForChild("ShovelTools"))
local SkipTimeStationService = require(Server:WaitForChild("SkipTimeStationService"))
local StarterPackShopService = require(Server:WaitForChild("StarterPackShopService"))
local StormChaserService = require(Server:WaitForChild("StormChaserService"))
local TelemetryService  = require(Server:WaitForChild("TelemetryService"))
local UpdateEventConfigService = require(Server:WaitForChild("UpdateEventConfigService"))
local UpdateLogService = require(Server:WaitForChild("UpdateLogService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlayerSettingsService = require(Server:WaitForChild("PlayerSettingsService"))

local Interactions = require(Shared:WaitForChild("Interactions"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local PlayerBonuses = require(Shared:WaitForChild("PlayerBonuses"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local PromptActionConfig = require(Shared:WaitForChild("PromptActionConfig"))
local RebirthBalance = require(Shared:WaitForChild("RebirthBalance"))
local State    = require(Shared:WaitForChild("State"))
local Food     = require(Shared:WaitForChild("Food"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local GridUnlockEffect = Remotes.get(Remotes.Names.GridUnlockEffect)
local PetBillboardFeedEffect = Remotes.get(Remotes.Names.PetBillboardFeedEffect)
local PromptInteractEffect = Remotes.get(Remotes.Names.PromptInteractEffect)
local PlotStressTest = nil
local GameEventDev = nil
local AnimalAmbientSoundService = require(Server:WaitForChild("AnimalAmbientSoundService"))

if RunService:IsStudio() then
	local devFolder = Server:FindFirstChild("dev")
	local stressModule = devFolder and devFolder:FindFirstChild("PlotStressTest")
	if stressModule and stressModule:IsA("ModuleScript") then
		PlotStressTest = require(stressModule)
	end
	local gameEventDevModule = devFolder and devFolder:FindFirstChild("GameEventDev")
	if gameEventDevModule and gameEventDevModule:IsA("ModuleScript") then
		GameEventDev = require(gameEventDevModule)
	end
end

-- Both windows must admit the hold ramp's peak rate (with jitter tolerance),
-- or held feeding gets randomly rejected at full speed.
local PROMPT_RATE_SECONDS = PromptActionConfig.FamilyRateWindowSeconds
local PROMPT_ACTION_RATE_SECONDS = PromptActionConfig.FamilyRateWindowSeconds
local PLACE_RATE_SECONDS = 0.25
local PET_COLLECTION_DISTANCE = 5
local PET_COLLECTION_INTERVAL = 0.25
local PET_FEED_REACTION_SECONDS = 2
local PET_EVOLUTION_IDLE_HOLD_SECONDS = 4
local OFFLINE_PET_EARN_FRACTION = 0.01
local FOOD_PICKUP_PROMPT_DISTANCE = 8
local EDIT_MODE_ATTR = "EditMode"
local FOOD_COLLECTION_SNAPSHOT = "FoodCollection"
local PET_FEED_SNAPSHOT = "PetFeed"
local PET_FEED_SNAPSHOT_DEBOUNCE_SECONDS = 1

local minimumPetSnapshotCounts = {}
local pendingPetFeedSnapshotTokens = {}

local function userLabel(player)
	return tostring(player and player.UserId or "unknown")
end

local function userKey(player)
	return player and player.UserId or nil
end

-- Player attribute (State.Player.InventoryRestorePending): true while the
-- profile's inventory fields are authoritative and the live backpack is not
-- (session start / death, until re-materialization completes). Kept as an
-- attribute so services outside this file (receipts, deletes, prompt
-- dispatch) can consult it before serializing or mutating the backpack.
local function isInventoryRestorePending(player)
	return player ~= nil and player:GetAttribute(State.Player.InventoryRestorePending) == true
end

local function setInventoryRestorePending(player, pending)
	if player and player:IsDescendantOf(Players) then
		player:SetAttribute(State.Player.InventoryRestorePending, pending == true or nil)
	end
end

local function isInventoryGameplayBlocked(player)
	return OfflineProgressService.IsPending(player) or isInventoryRestorePending(player)
end

local function minimumPetCountForRebirths(rebirths)
	local count = 1
	rebirths = math.max(math.floor(tonumber(rebirths) or 0), 0)
	for tierNumber = 1, rebirths do
		local tier = RebirthBalance.GetTier(tierNumber)
		if not tier then
			break
		end
		for _, reward in ipairs(tier.PetRewards or {}) do
			count += math.max(math.floor(tonumber(reward.amount) or 0), 0)
		end
	end
	return count
end

local function copyPetRecord(pet)
	if type(pet) ~= "table" then
		return nil
	end
	return {
		petId = type(pet.petId) == "string" and pet.petId or "Pet1",
		xp = math.max(tonumber(pet.xp) or 0, 0),
		money = math.max(tonumber(pet.money) or 0, 0),
		lx = tonumber(pet.lx),
		lz = tonumber(pet.lz),
		lry = tonumber(pet.lry) or 0,
	}
end

local function defaultRebirthPetId(slotIndex, rebirths)
	if slotIndex <= 1 then
		return "Pet1"
	end

	local currentSlot = 1
	rebirths = math.max(math.floor(tonumber(rebirths) or 0), 0)
	for tierNumber = 1, rebirths do
		local tier = RebirthBalance.GetTier(tierNumber)
		if not tier then
			break
		end
		for _, reward in ipairs(tier.PetRewards or {}) do
			local amount = math.max(math.floor(tonumber(reward.amount) or 0), 0)
			for _ = 1, amount do
				currentSlot += 1
				if currentSlot == slotIndex then
					return type(reward.petId) == "string" and reward.petId or "Pet1"
				end
			end
		end
	end

	return "Pet1"
end

RuntimeGuard.Run("PlotGridService.ResetVacantPlotsToPreviewRows", PlotGridService.ResetVacantPlotsToPreviewRows)
RuntimeGuard.Run("PlotService.SyncVacantPlotVisibility", PlotService.SyncVacantPlotVisibility)
RuntimeGuard.Run("AnimalAmbientSoundService.Start", AnimalAmbientSoundService.Start)

RuntimeGuard.Run("RebirthService.Start", RebirthService.Start)
RuntimeGuard.Run("GearShopService.Start", GearShopService.Start)
RuntimeGuard.Run("CosmeticShopService.Start", CosmeticShopService.Start)
RuntimeGuard.Run("SeedPackShopService.Start", SeedPackShopService.Start)
RuntimeGuard.Run("DurianPackShopService.Start", DurianPackShopService.Start)
RuntimeGuard.Run("CashPackShopService.Start", CashPackShopService.Start)
RuntimeGuard.Run("StarterPackShopService.Start", StarterPackShopService.Start)
RuntimeGuard.Run("ServerLuckService.Start", ServerLuckService.Start)
RuntimeGuard.Run("AdminLuckService.Start", AdminLuckService.Start)
-- GameEventService.Start runs later, once snapshotProfileState is defined, so
-- no event handler can start with a nil snapshot callback.
RuntimeGuard.Run("UpdateEventConfigService.Start", UpdateEventConfigService.Start)
RuntimeGuard.Run("SkipTimeStationService.Start", SkipTimeStationService.Start)
RuntimeGuard.Run("UpdateLogService.Start", UpdateLogService.Start)
RuntimeGuard.Run("HomeTeleportService.Start", HomeTeleportService.Start)
RuntimeGuard.Run("JoinGroupRewardService.Start", JoinGroupRewardService.Start)
RuntimeGuard.Run("MediaRewardService.Start", MediaRewardService.Start)
RuntimeGuard.Run("FriendBoostService.Start", FriendBoostService.Start)
RuntimeGuard.Run("PetIncomeService.Start", function()
	PetIncomeService.Start({
		PetCashMultiplier = GamePassService.PetCashMultiplier,
	})
end)
RuntimeGuard.Run("GamePassService.RegisterOwnershipChangedCallback", function()
	GamePassService.RegisterOwnershipChangedCallback(function(player)
		PetIncomeService.Refresh(player)
	end)
end)
RuntimeGuard.Run("GamePassService.Start", GamePassService.Start)
RuntimeGuard.Run("ReceiptService.Start", function()
	ReceiptService.Start({
		rebirthService = RebirthService,
		gearShopService = GearShopService,
		cosmeticShopService = CosmeticShopService,
		seedPackShopService = SeedPackShopService,
		durianPackShopService = DurianPackShopService,
		endlessPackShopService = EndlessPackShopService,
		cashPackShopService = CashPackShopService,
		starterPackShopService = StarterPackShopService,
		serverLuckService = ServerLuckService,
		foodStealService = FoodStealService,
		growSkipService = GrowSkipService,
		collectAllService = CollectAllService,
	})
end)
RuntimeGuard.Run("RollBroadcastService.Start", RollBroadcastService.Start)
RuntimeGuard.Run("RollService.Start", RollService.Start)
RuntimeGuard.Run("AFKRejoinService.Start", AFKRejoinService.Start)
RuntimeGuard.Run("OfflineProgressService.Start", OfflineProgressService.Start)

-- ── Pet state save ────────────────────────────────────────────────────────────

-- Rebuild profile.Data.Pets from the current plot state (source of truth is the
-- spawned Models and their attributes). Preserves xp/money from the existing
-- profile entry when possible; falls back to 0. Missing existing profile pets
-- are retained so a partial live spawn cannot erase rebirth pet slots.
local function collectPetsFromPlot(player, plot, profile)
	local floor = PlotService.GetFloor(plot)
	local saved = {}
	local represented = {}
	local existingPets = type(profile.Data.Pets) == "table" and profile.Data.Pets or {}
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local idx = pet:GetAttribute(State.Pet.Index)
		if type(idx) == "number" then
			local existing = existingPets[idx]
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
			saved[#saved + 1] = entry
			represented[idx] = true
			if idx ~= #saved then
				pet:SetAttribute(State.Pet.Index, #saved)
			end
		end
	end

	local minimumCount = math.max(#existingPets, minimumPetCountForRebirths(profile.Data.Rebirths))
	local key = userKey(player)
	if key and minimumPetSnapshotCounts[key] then
		minimumCount = math.max(minimumCount, minimumPetSnapshotCounts[key])
	end
	for oldIndex, existing in ipairs(existingPets) do
		if #saved >= minimumCount then
			break
		end
		if not represented[oldIndex] then
			local copy = copyPetRecord(existing)
			if copy then
				saved[#saved + 1] = copy
			end
		end
	end
	for index = #saved + 1, minimumCount do
		saved[index] = {
			petId = defaultRebirthPetId(index, profile.Data.Rebirths),
			xp = 0,
			money = 0,
			lry = 0,
		}
	end

	return saved
end

local function savePetsFromPlot(plot, profile)
	profile.Data.Pets = collectPetsFromPlot(nil, plot, profile)
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

	local foodInventoryItems = FoodInventoryService.SerializeTools(player)
	return {
		FeedPlacements = placements,
		FeedInventory = feedInventory,
		SeedInventory = SeedTools.CountBySeed(player),
		FoodInventoryItems = foodInventoryItems,
		FoodInventory = FoodInventoryService.CountRecords(foodInventoryItems),
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
	if isInventoryRestorePending(player) then
		return false
	end
	if OfflineProgressService.IsPending(player) then
		local applied = OfflineProgressService.ApplyPendingBeforeSnapshot(player)
		if applied ~= true then
			return false
		end
	end
	local petsOk, pets = RuntimeGuard.Run("snapshotProfileState.collectPets", collectPetsFromPlot, player, plot, profile)
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
	profile.Data.FoodInventoryItems = feedState.FoodInventoryItems
	profile.Data.FoodInventory = feedState.FoodInventory
	profile.Data.LastSeen = os.time()
	-- Catch-all discovery sweep: covers gifting and any grant path without a
	-- point hook (publish rides the PublishProfile below).
	RuntimeGuard.Run("snapshotProfileState.discoverySync", DiscoveryService.Sync, player, profile)
	local publishRunOk, published = RuntimeGuard.Run("snapshotProfileState.publishProfile", PlayerReplicaService.PublishProfile, player, profile)
	if publishRunOk and published ~= true then
		warn("[init] Snapshot saved but PlayerState replica was not updated for user " .. userLabel(player))
	end
	return true
end

local function snapshotFoodCollection(player, plot, profile, feed)
	if not plot or not profile then return false end
	if isInventoryRestorePending(player) then
		return false
	end
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
	profile.Data.FoodInventoryItems = FoodInventoryService.SerializeTools(player)
	profile.Data.FoodInventory = FoodInventoryService.CountRecords(profile.Data.FoodInventoryItems)
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

local function snapshotFoodInventory(player, profile, context)
	if not profile then return false end
	if isInventoryRestorePending(player) then
		return false
	end
	profile.Data.FoodInventoryItems = FoodInventoryService.SerializeTools(player)
	profile.Data.FoodInventory = FoodInventoryService.CountRecords(profile.Data.FoodInventoryItems)
	profile.Data.LastSeen = os.time()
	local label = type(context) == "string" and context or "snapshotFoodInventory"
	local publishRunOk, published = RuntimeGuard.Run(
		label .. ".publishFoodInventory",
		PlayerReplicaService.PublishFoodInventory,
		player,
		profile
	)
	if publishRunOk and published ~= true then
		warn("[init] Food inventory snapshot saved but food inventory replica was not updated for user " .. userLabel(player))
	end
	return true
end

RuntimeGuard.Run("GameEventService.Start", function()
	GameEventService.Start({
		snapshotProfileState = snapshotProfileState,
	})
end)
RuntimeGuard.Run("LiveEventCommandService.Start", LiveEventCommandService.Start)
RuntimeGuard.Run("AdminPanelService.Start", AdminPanelService.Start)

local function clearPendingPetFeedSnapshot(player)
	local key = userKey(player)
	if key then
		pendingPetFeedSnapshotTokens[key] = nil
	end
end

local function schedulePetFeedSnapshot(player)
	local key = userKey(player)
	if not key then return end
	if pendingPetFeedSnapshotTokens[key] ~= nil then
		return
	end

	local token = os.clock()
	pendingPetFeedSnapshotTokens[key] = token
	task.delay(PET_FEED_SNAPSHOT_DEBOUNCE_SECONDS, function()
		RuntimeGuard.Run("PetFeedSnapshotDebounce." .. userLabel(player), function()
			if pendingPetFeedSnapshotTokens[key] ~= token then
				return
			end
			pendingPetFeedSnapshotTokens[key] = nil
			if not player:IsDescendantOf(Players) then
				return
			end
			local plot = PlotService.GetPlayerPlot(player)
			local profile = PlayerDataService.GetProfile(player)
			if plot and profile then
				snapshotProfileState(player, plot, profile)
			end
		end)
	end)
end

local function notifyGrown(player, feed)
	if not (player and feed) then return end
	NotificationService.Notify(player, {
		kind = NotificationConfig.Kinds.Success,
		text = string.format("%s has grown!", feed.Name),
		sound = "FruitPop",
	})
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

local function encodePetEvolutionPath(pathPetIds)
	if type(pathPetIds) ~= "table" or #pathPetIds == 0 then
		return nil
	end

	local sanitized = {}
	for _, petId in ipairs(pathPetIds) do
		if type(petId) == "string" and petId ~= "" then
			sanitized[#sanitized + 1] = petId
		end
	end
	if #sanitized == 0 then
		return nil
	end

	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(sanitized)
	end)
	if ok and type(encoded) == "string" then
		return encoded
	end

	warn("[init] Failed to encode pet evolution path")
	return nil
end

local function publishPetEvolutionCue(pet, oldPetId, oldScale, pivot, seq, pathPetIds)
	pet:SetAttribute(State.Pet.EvolutionOldPetId, oldPetId)
	pet:SetAttribute(State.Pet.EvolutionOldScale, oldScale)
	pet:SetAttribute(State.Pet.EvolutionPivot, pivot)
	pet:SetAttribute(State.Pet.EvolutionPathPetIds, encodePetEvolutionPath(pathPetIds))
	pet:SetAttribute(State.Pet.EvolutionSeq, seq)

	task.delay(8, function()
		RuntimeGuard.Run("PetEvolutionCue.ClearDelayed", function()
			if pet.Parent and pet:GetAttribute(State.Pet.EvolutionSeq) == seq then
				-- Keep the sequence monotonic, but remove stale payload so late
				-- clients do not replay an already-finished evolution.
				pet:SetAttribute(State.Pet.EvolutionOldPetId, nil)
				pet:SetAttribute(State.Pet.EvolutionOldScale, nil)
				pet:SetAttribute(State.Pet.EvolutionPivot, nil)
				pet:SetAttribute(State.Pet.EvolutionPathPetIds, nil)
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
	local evolutionPath = nil

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
			evolutionPath = { petId }
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
		if evolutionPath and evolutionPath[#evolutionPath] ~= nextPetId then
			evolutionPath[#evolutionPath + 1] = nextPetId
		end
		evolved = true
	end

	if not activePet or not activePet.Parent then return nil, evolved end

	local logicalPivot = PetMotionService.GetLogicalPivot(activePet)
	PlotService.RescalePet(activePet, petData.xp, logicalPivot)
	publishPetState(activePet, petData.money, petData.xp)

	if evolved then
		publishPetEvolutionCue(activePet, firstPetId, firstScale, firstPivot, evolutionSeq, evolutionPath)
		AnimalAmbientSoundService.PlayEvolutionBurst(activePet, evolutionPath)
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

local function withinHorizontalDistance(rootPosition, targetX, targetZ, maxDistance)
	local distance = tonumber(maxDistance)
	if type(targetX) ~= "number" or type(targetZ) ~= "number" or not distance then
		return false
	end

	local dx = rootPosition.X - targetX
	local dz = rootPosition.Z - targetZ
	return dx * dx + dz * dz <= distance * distance
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

	local foodXPMultiplier = GamePassService.FoodXPMultiplier(player)
	foodXP *= foodXPMultiplier
	petData.xp = (petData.xp or 0) + foodXP
	local activePet = pet
	local evolved = false
	if petData.xp >= maxXP then
		activePet, evolved = tryEvolvePet(plot, pet, profile)
		if not activePet or not activePet.Parent then return false end
		if evolved then
			DiscoveryService.MarkPet(player, profile, activePet:GetAttribute(State.Pet.Id))
		end
	else
		local logicalPivot = PetMotionService.GetLogicalPivot(pet)
		PlotService.RescalePet(pet, petData.xp, logicalPivot)
		pet:SetAttribute(State.Pet.XP, petData.xp)
	end
	local faceLX, faceLZ = playerFloorLocal(plot, player)
	PetMotionService.HoldAfterFeed(activePet, faceLX, faceLZ, evolved and PET_EVOLUTION_IDLE_HOLD_SECONDS or nil)
	triggerPetFeedReaction(activePet, faceLX, faceLZ)
	return true, activePet, foodXP
end

-- ── Currency / offline helpers ────────────────────────────────────────────────

local function applyOfflineEarnings(player, plot, profile, lastSeen, joinTime)
	lastSeen = tonumber(lastSeen) or profile.Data.LastSeen or 0
	if lastSeen == 0 then return true end
	local elapsed = (tonumber(joinTime) or os.time()) - lastSeen
	if elapsed <= 0 then return true end

	local earnRate = GamePassService.PetCashMultiplier(player)
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
				local earnRate = PlayerBonuses.EffectiveMultiplier(
					GamePassService.PetCashMultiplier(player),
					FriendBoostService.Multiplier(player)
				)
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

					local petX, petZ = PetMotionService.GetLogicalPlanarPosition(pet)
					if withinHorizontalDistance(root.Position, petX, petZ, PET_COLLECTION_DISTANCE) then
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
			NotificationService.Info(player, "That plot area is already unlocked")
		elseif code == "insufficient-currency" then
			NotificationService.Error(player, "Not enough currency for this plot area")
		elseif code ~= "busy" then
			NotificationService.Error(player, "Could not unlock that plot area")
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
	clearPendingPetFeedSnapshot(player)
	RuntimeGuard.Run("PlayerTeardown.StopPlotWind." .. label, PlotWindService.StopForPlayer, player)
	RuntimeGuard.Run("PlayerTeardown.StopPlotEarthquake." .. label, PlotEarthquakeService.StopForPlayer, player)
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
	local key = userKey(player)
	if key then
		minimumPetSnapshotCounts[key] = nil
	end
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
	-- Backfill Index discoveries from everything the profile already owns
	-- (runs before the replica is created, so the initial replica state
	-- carries the result).
	RuntimeGuard.Run("PlayerAdded.DiscoverySync." .. userLabel(player), DiscoveryService.Sync, player, profile)
	if PlotStressTest and PlotStressTest.ShouldDisableTutorial() then
		RuntimeGuard.Run("PlotStressTest.PreparePlayerProfile." .. userLabel(player), PlotStressTest.PreparePlayerProfile, player, profile)
	end
	local afkRejoinData = AFKRejoinService.GetJoinData(player)
	AFKRejoinService.MarkPending(player, afkRejoinData)

	local label = userLabel(player)
	local setupOk = RuntimeGuard.Run("PlayerAdded.Setup." .. label, function()
		-- The profile's inventory is authoritative until the first character
		-- restore materializes it; keep snapshots from clobbering it with an
		-- empty backpack in the meantime.
		setInventoryRestorePending(player, true)

		local offlineSession = nil
		if afkRejoinData then
			RuntimeGuard.Run("PlayerAdded.ClearOfflineForAFKRejoin." .. label, OfflineProgressService.Clear, player)
		else
			offlineSession = OfflineProgressService.Begin(player, plot, profile)
		end
		local deferOfflineProgress = offlineSession ~= nil
		local applied, applyReason = PlotGridService.ApplyProfileState(plot, profile)
		if not applied then
			warn(string.format("[init] Failed to apply user %s plot grid state: %s", userLabel(player), tostring(applyReason)))
			PlotGridService.ResetPlotState(plot)
		end
		RollService.ApplyDropAreaVisibility(plot, profile)
		RuntimeGuard.Run("RollService.RestorePendingOffers." .. label, RollService.RestorePendingOffers, player, plot, profile, {
			visualDelaySeconds = 1,
		})

		local spawnedPets, expectedPets = PlotService.SpawnPetsForPlot(plot, profile.Data.Pets)
		if type(spawnedPets) == "number" and type(expectedPets) == "number" and spawnedPets < expectedPets then
			local key = userKey(player)
			if key then
				minimumPetSnapshotCounts[key] = math.max(minimumPetSnapshotCounts[key] or 0, expectedPets)
			end
			warn(string.format(
				"[init] Spawned %d/%d profile pets for user %s; snapshots will preserve the profile pet count",
				spawnedPets,
				expectedPets,
				userLabel(player)
			))
		end
		RuntimeGuard.Run("PetIncomeService.TrackPlayerPlot." .. label, PetIncomeService.TrackPlayerPlot, player, plot)
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

		GamePassService.RefreshOwnership(player)
		if not deferOfflineProgress then
			applyOfflineEarnings(player, plot, profile)
		end

		PlayerReplicaService.Create(player, profile)
		PlayerSettingsService.ApplyToPlayer(player, profile)
		FriendBoostService.Publish(player)
		FriendBoostService.ScheduleRefresh()
		CurrencyService.Publish(player, profile)
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
		RuntimeGuard.Run("PlotWindService.StartForPlayer." .. label, PlotWindService.StartForPlayer, player, plot)
		RuntimeGuard.Run("PlotEarthquakeService.StartForPlayer." .. label, PlotEarthquakeService.StartForPlayer, player, plot)

		local afkRejoinRestored = false

		local function restoreBackpackTools(character)
			task.wait(0.5)
			-- The character may have died/respawned or the session ended during
			-- the wait; leave the pending flag set so the next spawn restores.
			-- The alive check matters: restoring against a corpse would clear
			-- the flag while the respawn backpack wipe is still ahead.
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if player.Character ~= character
				or not player:IsDescendantOf(Players)
				or PlayerDataService.GetProfile(player) ~= profile
				or not humanoid
				or humanoid.Health <= 0 then
				return
			end
			local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
			if not backpack or player.Character ~= character then
				return
			end
			-- Deficit-based restore: a grant can land between respawn and this
			-- run (profile count bumped + tool already in the fresh backpack),
			-- so materialize only what the profile holds beyond the live tools;
			-- a full rebuild would duplicate that grant.
			local liveFoodGuids = {}
			local liveFeedCounts = {}
			local function captureLiveTool(item)
				if not (item and item:IsA("Tool")) then
					return
				end
				local foodRecord = FoodInventoryService.SerializeTool(item)
				if foodRecord and foodRecord.guid then
					liveFoodGuids[foodRecord.guid] = true
				end
				if FeedMachineTools.IsFeedTool(item) then
					local feedType = item:GetAttribute(State.Feed.Type)
					liveFeedCounts[feedType] = (liveFeedCounts[feedType] or 0) + 1
				end
			end
			for _, item in ipairs(backpack:GetChildren()) do
				captureLiveTool(item)
			end
			captureLiveTool(character:FindFirstChildWhichIsA("Tool"))
			local liveSeedCounts = SeedTools.CountBySeed(player)
			local liveCosmeticCounts = CosmeticTools.CountByCosmetic(player)
			-- Materialize at most the hard cap; collect-all purchases can
			-- intentionally leave a profile above the normal 250 item cap.
			local remainingSlots = Inventory.RemainingSlots(player, Inventory.COLLECT_ALL_MAX_ITEMS)
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
				-- Parent into this spawn's backpack specifically: if a respawn
				-- interleaves mid-loop, these tools die with the old backpack
				-- instead of duplicating into the new one.
				tool.Parent = backpack
				return remainingSlots > 0
			end
			local function restoreMap(map, makeTool, liveCounts)
				for _, itemId in ipairs(sortedKeys(map)) do
					local count = math.max(math.floor(tonumber(map[itemId]) or 0), 0)
						- math.max(math.floor(tonumber(liveCounts[itemId]) or 0), 0)
					for _ = 1, count do
						if not restoreCountedTool(function()
							return makeTool(itemId)
						end) then
							return
						end
					end
				end
			end
			for _, record in ipairs(FoodInventoryService.SanitizeRecords(profile.Data.FoodInventoryItems)) do
				if not (record.guid and liveFoodGuids[record.guid]) then
					if not restoreCountedTool(function()
						return FoodInventoryService.MakeTool(record)
					end) then
						break
					end
				end
			end
			restoreMap(profile.Data.FeedInventory, FeedMachineTools.MakeFeedTool, liveFeedCounts)
			restoreMap(profile.Data.SeedInventory, SeedTools.MakeSeedTool, liveSeedCounts)
			restoreMap(profile.Data.CosmeticInventory, CosmeticTools.MakeCosmeticTool, liveCosmeticCounts)
			if player.Character == character then
				setInventoryRestorePending(player, false)
			end
		end

		local function onCharacterAdded(character)
			if afkRejoinData and not afkRejoinRestored then
				local restoreOk, restored = RuntimeGuard.Run(
					"AFKRejoinService.RestoreCharacter." .. label,
					AFKRejoinService.RestoreCharacter,
					player,
					plot,
					afkRejoinData
				)
				if restoreOk == true and restored == true then
					afkRejoinRestored = true
					RuntimeGuard.Run(
						"AFKRejoinService.FireCameraRestore." .. label,
						AFKRejoinService.FireCameraRestore,
						player,
						afkRejoinData
					)
					if afkRejoinData.autoRollEnabled == true then
						RuntimeGuard.Run(
							"AFKRejoinService.ResumeAutoRoll." .. label,
							RollService.ResumeAutoRoll,
							player,
							profile,
							{
								reason = "afk-rejoin",
							}
						)
					end
				end
			end

			ShovelTools.EnsureUtilityTool(player)

			-- Spawned so onCharacterAdded returns immediately: the initial
			-- character's run must not delay connecting CharacterAdded /
			-- CharacterRemoving below, or a death inside the restore's 0.5s
			-- wait would go unobserved.
			RuntimeGuard.Spawn("CharacterSpawnRestore." .. label, function()
				local humanoid = character:FindFirstChildOfClass("Humanoid")
					or character:WaitForChild("Humanoid", 5)
				if humanoid then
					RuntimeGuard.Connect(humanoid.Died, "HumanoidDied." .. label, function()
						-- Roblox wipes the backpack on respawn; from death until
						-- the next restore completes, the profile is the only truth.
						setInventoryRestorePending(player, true)
					end)
				end
				restoreBackpackTools(character)
			end)
		end

		if player.Character then
			RuntimeGuard.Run("CharacterAdded.Initial." .. label, onCharacterAdded, player.Character)
		end
		RuntimeGuard.Connect(player.CharacterAdded, "CharacterAdded." .. label, onCharacterAdded)
		RuntimeGuard.Connect(player.CharacterRemoving, "CharacterRemoving." .. label, function(removingCharacter)
			-- Backstop for deaths where Died may not fire (e.g. void falls
			-- destroying the humanoid). A live character is deliberately left
			-- alone so a healthy leaver's final teardown snapshot still runs.
			-- Any future server-side LoadCharacter caller must call
			-- setInventoryRestorePending(player, true) first.
			local humanoid = removingCharacter:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				setInventoryRestorePending(player, true)
			end
		end)
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
		familyActionRateSeconds = PROMPT_ACTION_RATE_SECONDS,
		familyActions = PromptActionConfig.FeedCollectActions,
		getContext = function(player)
			if OfflineProgressService.IsPending(player) then
				return nil, nil
			end
			-- Blocks all prompt handlers while dead/mid-restore: a handler that
			-- consumes a tool then couldn't persist the consumption, so the
			-- respawn restore would re-mint the consumed item.
			if isInventoryRestorePending(player) then
				return nil, nil
			end
			return PlotService.GetPlayerPlot(player), PlayerDataService.GetProfile(player)
		end,
		handlers = {
			[Interactions.Actions.PetFeed] = function(player, target, plot, profile)
				local fed, activePet, xpGained = feedPet(plot, player, profile, target)
				if fed then
					PetBillboardFeedEffect:FireClient(player, {
						pet = activePet,
						xp = xpGained,
					})
					OnboardingService.OnPetFed(player, profile)
					return PET_FEED_SNAPSHOT
				end
				return false
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
					NotificationService.Error(player, "Could not roll that crate")
				end
			end,
		},
		afterInteraction = function(player, plot, profile, action, _target, handlerResult)
			if OfflineProgressService.IsPending(player) then
				return
			end
			if action == Interactions.Actions.PetFeed then
				if handlerResult == PET_FEED_SNAPSHOT then
					PromptInteractEffect:FireClient(player, {
						action = action,
						effect = "feed",
						sound = "PetFed",
					})
					snapshotFoodInventory(player, profile, "snapshotPetFeedFoodInventory")
					schedulePetFeedSnapshot(player)
				end
				return
			end
			if action == Interactions.Actions.PatchHarvest or action == Interactions.Actions.TreeGroundPickup then
				if type(handlerResult) ~= "table" or handlerResult.snapshot ~= FOOD_COLLECTION_SNAPSHOT then
					return
				end
				PromptInteractEffect:FireClient(player, {
					action = action,
					effect = "collect",
					sound = "FruitPop",
				})
				if snapshotFoodCollection(player, plot, profile, handlerResult.feed) then
					return
				end
				warn("[init] Falling back to full snapshot after food collection for user " .. userLabel(player))
			end
			clearPendingPetFeedSnapshot(player)
			snapshotProfileState(player, plot, profile)
		end,
	})
end)

RuntimeGuard.Run("FeedEditService.Start", function()
	FeedEditService.Start({
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = isInventoryGameplayBlocked,
	})
end)

RuntimeGuard.Run("ShovelService.Start", function()
	ShovelService.Start({
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = isInventoryGameplayBlocked,
	})
end)

RuntimeGuard.Run("InventoryDeleteService.Start", function()
	InventoryDeleteService.Start({
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = isInventoryGameplayBlocked,
	})
end)

RuntimeGuard.Run("FoodStealService.Start", function()
	FoodStealService.Start({
		snapshotProfileState = snapshotProfileState,
	})
end)

RuntimeGuard.Run("GiftService.Start", function()
	GiftService.Start({
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = isInventoryGameplayBlocked,
	})
end)

RuntimeGuard.Run("PlayerSettingsService.Start", function()
	PlayerSettingsService.Start()
end)

RuntimeGuard.Run("StormChaserService.Start", function()
	StormChaserService.Start({
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = isInventoryGameplayBlocked,
	})
end)

RuntimeGuard.Run("GrowSkipService.Start", function()
	GrowSkipService.Start({
		snapshotProfileState = snapshotProfileState,
	})
end)

RuntimeGuard.Run("EndlessPackShopService.Start", function()
	EndlessPackShopService.Start({
		snapshotProfileState = snapshotProfileState,
	})
end)

RuntimeGuard.Run("CollectAllService.Start", function()
	CollectAllService.Start({
		snapshotProfileState = snapshotProfileState,
	})
end)

RuntimeGuard.Run("FeedPlacementService.Start", function()
	FeedPlacementService.Start({
		rateSeconds = PLACE_RATE_SECONDS,
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = isInventoryGameplayBlocked,
	})
end)

RuntimeGuard.Run("CosmeticPlacementService.Start", function()
	CosmeticPlacementService.Start({
		rateSeconds = PLACE_RATE_SECONDS,
		snapshotProfileState = snapshotProfileState,
		isGameplayBlocked = isInventoryGameplayBlocked,
	})
end)

if PlotStressTest then
	RuntimeGuard.Run("PlotStressTest.Watch", PlotStressTest.Watch)
end

if GameEventDev then
	RuntimeGuard.Run("GameEventDev.Watch", GameEventDev.Watch)
end
