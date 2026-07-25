local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AutoRollConfig = require(ReplicatedStorage.Shared:WaitForChild("AutoRollConfig"))
local ProfileStore = require(ReplicatedStorage.Shared:WaitForChild("ProfileStore"))
local PlotGrid = require(ReplicatedStorage.Shared:WaitForChild("PlotGrid"))
local RebirthBalance = require(ReplicatedStorage.Shared:WaitForChild("RebirthBalance"))
local RollDropAreaBalance = require(ReplicatedStorage.Shared:WaitForChild("RollDropAreaBalance"))
local RollLuckBalance = require(ReplicatedStorage.Shared:WaitForChild("RollLuckBalance"))
local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(ReplicatedStorage.Shared:WaitForChild("ShopBalance"))
local Seeds = require(ReplicatedStorage.Shared:WaitForChild("Seeds"))
local Cosmetics = require(ReplicatedStorage.Shared:WaitForChild("Cosmetics"))
local Mutations = require(ReplicatedStorage.Shared:WaitForChild("Mutations"))
local Onboarding = require(ReplicatedStorage.Shared:WaitForChild("Onboarding"))
local PlayerSettings = require(ReplicatedStorage.Shared:WaitForChild("PlayerSettings"))
local StormChaser = require(ReplicatedStorage.Shared:WaitForChild("StormChaser"))
local BeeEvent = require(ReplicatedStorage.Shared:WaitForChild("BeeEvent"))
local FoodInventoryService = require(script.Parent:WaitForChild("FoodInventoryService"))
local RollOfferPersistence = require(script.Parent:WaitForChild("RollOfferPersistence"))

local STORE_NAME = "PlayerData"
local USE_MOCK_STORE_IN_STUDIO = true
local CURRENT_DATA_VERSION = 13
local GROWING_SEED_PHASE = "GrowingSeed"
local STARTING_CURRENCY = 50
local STARTER_PET_ID = "Pet1"
local STARTER_FEED_INVENTORY = {}
local STARTER_SEED_INVENTORY = {}
local STARTER_COSMETIC_INVENTORY = {}

local DEPRECATED_FEED_TYPES = {
	Clicker1 = true,
	StarfruitTree = true,
}

-- Fresh ProfileStore-backed schema for the active PlayerData store.
local DATA_TEMPLATE = {
	DataVersion = CURRENT_DATA_VERSION,
	Pets = {
		{ petId = "Pet1", xp = 0, money = 0 },
	},
	FeedPlacements = {},
	CosmeticPlacements = {},
	CosmeticInventory = STARTER_COSMETIC_INVENTORY, -- { [CosmeticID] = count }
	FeedInventory = STARTER_FEED_INVENTORY, -- { [FeedType] = count }
	SeedInventory = STARTER_SEED_INVENTORY, -- { [SeedID] = count }
	FoodInventory = {}, -- { [FoodId] = count }
	-- Individual records preserve food XP, mutations, scale, GUID, and favourite state.
	FoodInventoryItems = {},
	-- Count-backed tools are otherwise identical, so favourite counts preserve their state.
	FavouriteInventory = {
		Feed = {},
		Seed = {},
		Cosmetic = {},
	},
	ProcessedReceipts = {},
	PendingFoodStealReservation = nil,
	PendingGrowSkipReservation = nil,
	PendingCollectAllReservation = nil,
	PendingRollOffers = {},
	StarterPackPurchased = false,
	StarterPackPurchases = {},
	-- Durian Pack tickets bought with Robux; one ticket funds one durian roll.
	DurianTickets = 0,
	-- Rolls since the last pity-guaranteed durian. Every PityRollCount-th roll
	-- (see ShopBalance.DurianPack) is forced to the durian reward and resets
	-- this; natural durian rolls do not.
	DurianPackPity = 0,
	-- Total Endless Pack track items claimed/bought (see ShopBalance.EndlessPack).
	-- Monotonic; the next claimable position is always this + 1.
	EndlessPackProgress = 0,
	Currency = STARTING_CURRENCY,
	RollLuckLevel = 0,
	RollDropAreaLevel = 0,
	AutoRollSettings = {
		autoPurchase = false,
		selectedRarities = {},
	},
	PlayerSettings = {
		musicEnabled = true,
		treeAutoCollect = true,
		acceptGifts = true,
		motionSickness = false,
		hidePetsInEditMode = false,
	},
	Rebirths = 0,
	UnlockedGridKeys = {},
	-- Lifetime count of crates spawned by this player's rolls (one per drop
	-- pad per roll). Admin party drops do not count.
	LifetimeCrateRolls = 0,
	-- New-player hook: the Nth lifetime crate is a guaranteed
	-- PurpleAngelLuckyBlock. 0 = no guarantee (consumed, or an existing
	-- profile migrated in). Never set nil: Reconcile would refill it from
	-- this template and re-arm the guarantee.
	PurpleAngelCrateGuaranteeAt = 12,
	-- StormChaser event: current reward tier and per-mutation crate deposits,
	-- e.g. { Tier = 1, Deposits = { Twisted = 3 } }. Tiers loop 1 -> 2 -> 1.
	StormChaser = { Tier = 1, Deposits = {} },
	-- Bee event: current reward tier and the single Jar deposit counter,
	-- e.g. { Tier = 2, Deposits = 17 }. Tiers loop 1 -> 2 -> 3 -> 1.
	BeeEvent = { Tier = 1, Deposits = 0 },
	Onboarding = Onboarding.DefaultState(),
	-- Index/codex discovery sets: { Pets = { [PetID] = true }, Feed = { [FeedType] = true } }.
	Discovered = { Pets = {}, Feed = {} },
	JoinGroupRewardCollected = false,
	MediaRewardCollected = false,
	LastSeenUpdateLogId = "",
	LastSeen = 0,
}

local IS_STUDIO = RunService:IsStudio()

local BASE_PLAYER_STORE = ProfileStore.New(STORE_NAME, DATA_TEMPLATE)
local MOCK_PLAYER_STORE = BASE_PLAYER_STORE.Mock
local PLAYER_STORE = BASE_PLAYER_STORE
if USE_MOCK_STORE_IN_STUDIO and IS_STUDIO then
	PLAYER_STORE = MOCK_PLAYER_STORE
end
local profiles = {}

local PlayerDataService = {}

local function userKey(player)
	return player and player.UserId or nil
end

RuntimeGuard.Connect(ProfileStore.OnError, "PlayerDataService.ProfileStoreError", function(message, storeName, profileKey)
	warn(string.format("[ProfileStore] Store=%s Key=%s Error=%s", tostring(storeName), tostring(profileKey), tostring(message)))
end)

RuntimeGuard.Connect(ProfileStore.OnCriticalToggle, "PlayerDataService.ProfileStoreCriticalToggle", function(isCritical)
	if isCritical then
		warn("[ProfileStore] DataStore access is in a critical state")
	end
end)

local function normalizeDataVersion(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function removeDeprecatedFeedTypesFromMap(map)
	if type(map) ~= "table" then
		return
	end
	for feedType in pairs(DEPRECATED_FEED_TYPES) do
		map[feedType] = nil
	end
end

local function removeDeprecatedFeedPlacements(data)
	if type(data.FeedPlacements) ~= "table" then
		return
	end

	local placements = {}
	for _, placement in ipairs(data.FeedPlacements) do
		local feedType = type(placement) == "table" and placement.type or nil
		if type(feedType) == "string" and not DEPRECATED_FEED_TYPES[feedType] then
			placements[#placements + 1] = placement
		end
	end
	data.FeedPlacements = placements
end

local function finiteNumber(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	return value
end

local function nonnegativeNumber(value)
	value = finiteNumber(value)
	if value == nil then
		return nil
	end
	return math.max(value, 0)
end

local function nonemptyString(value)
	return type(value) == "string" and value ~= "" and value or nil
end

local function sanitizeFavouriteCountMap(value, inventory)
	local clean = {}
	if type(value) ~= "table" or type(inventory) ~= "table" then
		return clean
	end
	for itemId, count in pairs(value) do
		local inventoryCount = math.max(math.floor(finiteNumber(inventory[itemId]) or 0), 0)
		local favouriteCount = math.max(math.floor(finiteNumber(count) or 0), 0)
		if type(itemId) == "string" and itemId ~= "" and inventoryCount > 0 and favouriteCount > 0 then
			clean[itemId] = math.min(favouriteCount, inventoryCount)
		end
	end
	return clean
end

local function sanitizeStarterPackPurchases(value, legacyPurchased)
	local clean = {}
	local source = type(value) == "table" and value or {}
	for _, pack in ipairs(ShopBalance.AllStarterPacks()) do
		local packId = type(pack.PackId) == "string" and pack.PackId or nil
		if packId and (source[packId] == true or (packId == "StarterPack" and legacyPurchased == true)) then
			clean[packId] = true
		end
	end
	return clean
end

local function firstMutationIds(...)
	for index = 1, select("#", ...) do
		local mutationIds = Mutations.SanitizeList(select(index, ...))
		if #mutationIds > 0 then
			return mutationIds
		end
	end
	return {}
end

local function copyMutationPayload(clean, mutationIdsValue, primaryMutationIdValue, mutationKey, primaryKey)
	local mutationIds = Mutations.SanitizeList(mutationIdsValue)
	if #mutationIds == 0 then
		return
	end

	clean[mutationKey or "mutationIds"] = mutationIds
	local primaryMutationId = Mutations.Primary(mutationIds, primaryMutationIdValue)
	if primaryMutationId then
		clean[primaryKey or "primaryMutationId"] = primaryMutationId
	end
end

local function copyFoodReservationPayload(clean, source)
	if type(clean) ~= "table" or type(source) ~= "table" then
		return
	end
	local reservationId = nonemptyString(source.stealReservationId)
	local expiresAt = math.floor(tonumber(source.stealReservationExpiresAt) or 0)
	if not reservationId or expiresAt <= 0 then
		return
	end
	clean.stealReservationId = reservationId
	clean.stealReservationExpiresAt = expiresAt
end

local function sanitizeFeedQueueItem(item)
	if type(item) ~= "table" then
		return nil
	end

	local legacyFoodId = nonemptyString(item.foodId) or nonemptyString(item.foodType)
	local sourceFoodId = nonemptyString(item.sourceFoodId)
	local readyAt = finiteNumber(item.readyAt)
	local depositedAt = finiteNumber(item.depositedAt)

	if sourceFoodId or readyAt then
		local clean = {
			sourceFoodId = sourceFoodId or legacyFoodId,
		}
		if not clean.sourceFoodId then
			return nil
		end

		local sourceXP = nonnegativeNumber(item.sourceXP)
		if sourceXP == nil then
			sourceXP = nonnegativeNumber(item.xp)
		end
		if sourceXP ~= nil then
			clean.sourceXP = sourceXP
		end

		if readyAt ~= nil then
			clean.readyAt = readyAt
		elseif depositedAt ~= nil then
			-- JamBarrel.Apply can reconstruct readyAt from legacy depositedAt.
			clean.depositedAt = depositedAt
		else
			return nil
		end

		copyMutationPayload(
			clean,
			firstMutationIds(item.sourceMutationIds, item.mutationIds, item.mutations),
			item.sourcePrimaryMutationId or item.primaryMutationId or item.primaryMutation,
			"sourceMutationIds",
			"sourcePrimaryMutationId"
		)
		return clean
	end

	if not (legacyFoodId and depositedAt) then
		return nil
	end

	local clean = {
		foodId = legacyFoodId,
		depositedAt = depositedAt,
	}
	local xp = nonnegativeNumber(item.xp)
	if xp ~= nil then
		clean.xp = xp
	end
	copyMutationPayload(
		clean,
		firstMutationIds(item.mutationIds, item.mutations, item.sourceMutationIds),
		item.primaryMutationId or item.primaryMutation or item.sourcePrimaryMutationId
	)
	return clean
end

local function migrateData(data)
	if type(data) ~= "table" then
		return
	end

	local version = normalizeDataVersion(data.DataVersion)
	if version > CURRENT_DATA_VERSION then
		warn(string.format(
			"[PlayerDataService] Profile data version %d is newer than server version %d",
			version,
			CURRENT_DATA_VERSION
		))
		return
	end

	while version < CURRENT_DATA_VERSION do
		local nextVersion = version + 1
		if nextVersion == 1 then
			-- Baseline version marker for profiles created before explicit
			-- migrations existed.
		elseif nextVersion == 2 then
			removeDeprecatedFeedTypesFromMap(data.FeedInventory)
			removeDeprecatedFeedPlacements(data)
		elseif nextVersion == 3 then
			if type(data.SeedInventory) ~= "table" then
				data.SeedInventory = {}
			end
		elseif nextVersion == 4 then
			if type(data.CosmeticPlacements) ~= "table" then
				data.CosmeticPlacements = {}
			end
			if type(data.CosmeticInventory) ~= "table" then
				data.CosmeticInventory = {}
			end
		elseif nextVersion == 5 then
			if type(data.CosmeticInventory) ~= "table" then
				data.CosmeticInventory = {}
			end
			for cosmeticId, count in pairs(STARTER_COSMETIC_INVENTORY) do
				if data.CosmeticInventory[cosmeticId] == nil then
					data.CosmeticInventory[cosmeticId] = count
				end
			end
		elseif nextVersion == 6 then
			-- Existing profiles skip onboarding; fresh v6 profiles receive the
			-- default onboarding state from DATA_TEMPLATE.
			if data.Onboarding == nil then
				data.Onboarding = Onboarding.CompleteState()
			end
		elseif nextVersion == 7 then
			if type(data.FoodInventoryItems) ~= "table" then
				data.FoodInventoryItems = FoodInventoryService.RecordsFromCountMap(data.FoodInventory)
			end
		elseif nextVersion == 8 then
			if type(data.PendingRollOffers) ~= "table" then
				data.PendingRollOffers = {}
			end
		elseif nextVersion == 9 then
			if type(data.StarterPackPurchases) ~= "table" then
				data.StarterPackPurchases = {}
			end
			if data.StarterPackPurchased == true then
				data.StarterPackPurchases.StarterPack = true
			end
		elseif nextVersion == 10 then
			-- Existing profiles never receive the new-player guaranteed crate;
			-- fresh v10 profiles get PurpleAngelCrateGuaranteeAt = 12 from
			-- DATA_TEMPLATE. Explicit 0 (not nil) so Reconcile cannot re-arm it.
			data.PurpleAngelCrateGuaranteeAt = 0
			if type(data.LifetimeCrateRolls) ~= "number" then
				data.LifetimeCrateRolls = 0
			end
		elseif nextVersion == 11 then
			if type(data.StormChaser) ~= "table" then
				data.StormChaser = { Tier = 1, Deposits = {} }
			end
		elseif nextVersion == 12 then
			if type(data.FavouriteInventory) ~= "table" then
				data.FavouriteInventory = {
					Feed = {},
					Seed = {},
					Cosmetic = {},
				}
			end
		elseif nextVersion == 13 then
			if type(data.BeeEvent) ~= "table" then
				data.BeeEvent = { Tier = 1, Deposits = 0 }
			end
		end

		version = nextVersion
		data.DataVersion = version
	end
end

local function sanitizePendingFoodStealReservation(value)
	if type(value) ~= "table" then
		return nil
	end
	local item = FoodInventoryService.SanitizeRecord({
		foodId = value.foodId,
			xp = value.xp,
			scale = value.scale,
			mutationIds = value.mutationIds or value.mutations,
			primaryMutationId = value.primaryMutationId or value.primaryMutation,
		})
	if not item then
		return nil
	end
	local reservationId = value.reservationId
	if type(reservationId) ~= "string" or reservationId == "" then
		return nil
	end
	local sourceKind = value.sourceKind
	if sourceKind ~= "Patch" and sourceKind ~= "Tree" then
		return nil
	end
	local productId = math.max(math.floor(tonumber(value.productId) or 0), 0)
	if productId <= 0 then
		return nil
	end
	local clean = {
		reservationId = reservationId,
		productId = productId,
		foodId = item.foodId,
		xp = item.xp,
			scale = item.scale,
			mutationIds = item.mutationIds,
			primaryMutationId = item.primaryMutationId,
			sourceKind = sourceKind,
		sourceOwnerUserId = math.floor(tonumber(value.sourceOwnerUserId) or 0),
		sourceFeedIndex = math.floor(tonumber(value.sourceFeedIndex) or 0),
		sourceSlotIndex = math.floor(tonumber(value.sourceSlotIndex) or 0),
		sourceCommitted = value.sourceCommitted == true,
		sourceUnavailable = value.sourceUnavailable == true,
		compensationCash = math.max(math.floor(tonumber(value.compensationCash) or 0), 0),
		createdAt = math.floor(tonumber(value.createdAt) or os.time()),
		expiresAt = math.floor(tonumber(value.expiresAt) or 0),
	}
	if clean.sourceOwnerUserId <= 0 or clean.sourceFeedIndex <= 0 or clean.sourceSlotIndex <= 0 or clean.expiresAt <= 0 then
		return nil
	end
	return clean
end

local function sanitizePendingGrowSkipReservation(value)
	if type(value) ~= "table" then
		return nil
	end
	local reservationId = value.reservationId
	if type(reservationId) ~= "string" or reservationId == "" then
		return nil
	end
	local productId = math.max(math.floor(tonumber(value.productId) or 0), 0)
	local createdAt = math.floor(tonumber(value.createdAt) or os.time())
	local expiresAt = math.floor(tonumber(value.expiresAt) or 0)
	if productId <= 0 or expiresAt <= 0 then
		return nil
	end
	local kind = value.kind
	if kind ~= "PlotTime" then
		kind = "SaplingMature"
	end
	local clean = {
		kind = kind,
		reservationId = reservationId,
		productId = productId,
		createdAt = createdAt,
		expiresAt = expiresAt,
	}
	if kind == "PlotTime" then
		local skipId = value.skipId
		local durationSeconds = math.max(math.floor(tonumber(value.durationSeconds) or 0), 0)
		if type(skipId) ~= "string" or skipId == "" or durationSeconds <= 0 then
			return nil
		end
		clean.skipId = skipId
		clean.durationSeconds = durationSeconds
		clean.sourceCommitted = value.sourceCommitted == true
		local appliedPurchaseId = nonemptyString(value.appliedPurchaseId)
		if appliedPurchaseId then
			clean.appliedPurchaseId = appliedPurchaseId
		end
		return clean
	end

	local feedIndex = math.max(math.floor(tonumber(value.feedIndex) or 0), 0)
	local seedId = value.seedId
	if feedIndex <= 0 or type(seedId) ~= "string" or seedId == "" then
		return nil
	end
	clean.feedIndex = feedIndex
	clean.seedId = seedId
	return clean
end

local function sanitizePendingCollectAllReservation(value)
	if type(value) ~= "table" then
		return nil
	end
	local reservationId = value.reservationId
	if type(reservationId) ~= "string" or reservationId == "" then
		return nil
	end
	local productId = math.max(math.floor(tonumber(value.productId) or 0), 0)
	local createdAt = math.floor(tonumber(value.createdAt) or os.time())
	local expiresAt = math.floor(tonumber(value.expiresAt) or 0)
	if productId <= 0 or expiresAt <= 0 then
		return nil
	end
	local items = {}
	if type(value.items) == "table" then
		for _, item in ipairs(value.items) do
			local cleanItem = FoodInventoryService.SanitizeRecord(item)
			if cleanItem then
				local sourceKind = item.sourceKind
				local sourceFeedIndex = math.max(math.floor(tonumber(item.sourceFeedIndex) or 0), 0)
				local sourceSlotIndex = math.max(math.floor(tonumber(item.sourceSlotIndex) or 0), 0)
				if (sourceKind == "Patch" or sourceKind == "Tree") and sourceFeedIndex > 0 and sourceSlotIndex > 0 then
					cleanItem.sourceKind = sourceKind
					cleanItem.sourceFeedIndex = sourceFeedIndex
					cleanItem.sourceSlotIndex = sourceSlotIndex
					cleanItem.sourceCommitted = item.sourceCommitted == true
					cleanItem.sourceUnavailable = item.sourceUnavailable == true
					items[#items + 1] = cleanItem
				end
			end
		end
	end
	if #items == 0 then
		return nil
	end
	return {
		reservationId = reservationId,
		productId = productId,
		createdAt = createdAt,
		expiresAt = expiresAt,
		items = items,
		appliedPurchaseId = nonemptyString(value.appliedPurchaseId),
	}
end

local function petSlotFromKey(key)
	if type(key) == "number" then
		if key > 0 and key == math.floor(key) then
			return key
		end
		return nil
	end
	if type(key) == "string" then
		local slot = tonumber(key)
		if type(slot) == "number" and slot > 0 and slot == math.floor(slot) then
			return slot
		end
	end
	return nil
end

local function sanitizePetRecord(pet)
	if type(pet) ~= "table" then
		return nil
	end
	return {
		petId = type(pet.petId) == "string" and pet.petId
			or type(pet.type) == "string" and pet.type
			or STARTER_PET_ID,
		xp = math.max(tonumber(pet.xp) or 0, 0),
		money = math.max(tonumber(pet.money) or 0, 0),
		lx = tonumber(pet.lx),
		lz = tonumber(pet.lz),
		lry = tonumber(pet.lry) or 0,
	}
end

local function minimumPetIdsForRebirths(rebirths)
	local petIds = { STARTER_PET_ID }
	for tierNumber = 1, rebirths do
		local tier = RebirthBalance.GetTier(tierNumber)
		if not tier then
			break
		end
		for _, reward in ipairs(tier.PetRewards or {}) do
			local amount = math.max(math.floor(tonumber(reward.amount) or 0), 0)
			local petId = type(reward.petId) == "string" and reward.petId or STARTER_PET_ID
			for _ = 1, amount do
				petIds[#petIds + 1] = petId
			end
		end
	end
	return petIds
end

local function sanitizePets(petsValue, rebirths)
	local recordsBySlot = {}
	local slots = {}
	if type(petsValue) == "table" then
		for key, pet in pairs(petsValue) do
			local slot = petSlotFromKey(key)
			if slot and not recordsBySlot[slot] then
				local clean = sanitizePetRecord(pet)
				if clean then
					recordsBySlot[slot] = clean
					slots[#slots + 1] = slot
				end
			end
		end
	end

	table.sort(slots)
	local pets = {}
	for _, slot in ipairs(slots) do
		pets[#pets + 1] = recordsBySlot[slot]
	end

	local minimumPetIds = minimumPetIdsForRebirths(rebirths)
	if #pets == 0 then
		pets[#pets + 1] = { petId = STARTER_PET_ID, xp = 0, money = 0, lry = 0 }
	end
	for index = #pets + 1, #minimumPetIds do
		pets[index] = {
			petId = minimumPetIds[index],
			xp = 0,
			money = 0,
			lry = 0,
		}
	end

	return pets
end

local function sanitizeStormChaser(value)
	local clean = { Tier = 1, Deposits = {} }
	if type(value) ~= "table" then
		return clean
	end
	clean.Tier = StormChaser.NormalizeTier(value.Tier)
	if type(value.Deposits) == "table" then
		for _, mutationId in ipairs(StormChaser.CrateMutationIds) do
			local required = StormChaser.RequiredFor(clean.Tier, mutationId) or 0
			local count = math.floor(tonumber(value.Deposits[mutationId]) or 0)
			count = math.clamp(count, 0, required)
			if count > 0 then
				clean.Deposits[mutationId] = count
			end
		end
	end
	return clean
end

local function sanitizeBeeEvent(value)
	local clean = { Tier = 1, Deposits = 0 }
	if type(value) ~= "table" then
		return clean
	end
	clean.Tier = BeeEvent.NormalizeTier(value.Tier)
	local required = BeeEvent.RequiredFor(clean.Tier) or 0
	local count = math.floor(tonumber(value.Deposits) or 0)
	clean.Deposits = math.clamp(count, 0, required)
	return clean
end

local function sanitizeDiscoveredSet(value)
	local clean = {}
	if type(value) == "table" then
		for id, flag in pairs(value) do
			if type(id) == "string" and flag == true then
				clean[id] = true
			end
		end
	end
	return clean
end

local function sanitizeDiscovered(value)
	if type(value) ~= "table" then
		value = {}
	end
	return {
		Pets = sanitizeDiscoveredSet(value.Pets),
		Feed = sanitizeDiscoveredSet(value.Feed),
	}
end

local function ensureValidData(profile)
	migrateData(profile.Data)
	profile:Reconcile()

	local dataVersion = normalizeDataVersion(profile.Data.DataVersion)
	if dataVersion < CURRENT_DATA_VERSION then
		profile.Data.DataVersion = CURRENT_DATA_VERSION
	else
		profile.Data.DataVersion = dataVersion
	end

	profile.Data.Rebirths = math.max(math.floor(tonumber(profile.Data.Rebirths) or 0), 0)
	profile.Data.LifetimeCrateRolls = math.max(math.floor(tonumber(profile.Data.LifetimeCrateRolls) or 0), 0)
	profile.Data.PurpleAngelCrateGuaranteeAt = math.max(math.floor(tonumber(profile.Data.PurpleAngelCrateGuaranteeAt) or 0), 0)
	profile.Data.DurianTickets = math.max(math.floor(tonumber(profile.Data.DurianTickets) or 0), 0)
	profile.Data.DurianPackPity = math.max(math.floor(tonumber(profile.Data.DurianPackPity) or 0), 0)
	profile.Data.EndlessPackProgress = math.max(math.floor(tonumber(profile.Data.EndlessPackProgress) or 0), 0)
	profile.Data.Pets = sanitizePets(profile.Data.Pets, profile.Data.Rebirths)

	local placements = {}
	if type(profile.Data.FeedPlacements) == "table" then
		for _, placement in ipairs(profile.Data.FeedPlacements) do
			if type(placement) == "table"
				and type(placement.type) == "string"
				and not DEPRECATED_FEED_TYPES[placement.type] then
				local clean = {
					type = placement.type,
					lx = tonumber(placement.lx) or 0,
					lz = tonumber(placement.lz) or 0,
					lry = tonumber(placement.lry) or 0,
				}
				if placement.phase == GROWING_SEED_PHASE then
					local seedId = type(placement.seedId) == "string" and placement.seedId or nil
					local seedFeedType = seedId and Seeds.FeedTypeFor(seedId) or nil
					local growTime = math.max(tonumber(placement.growTime) or Seeds.GrowTimeFor(seedId) or 0, 0)
					if not (seedId and seedFeedType and growTime > 0) then
						continue
					end
					clean.type = seedFeedType
					clean.phase = GROWING_SEED_PHASE
					clean.seedId = seedId
					clean.plantedAt = tonumber(placement.plantedAt) or os.time()
					clean.growTime = growTime
				end
				if type(placement.queue) == "table" then
					clean.queue = {}
					for _, item in ipairs(placement.queue) do
						local queueItem = sanitizeFeedQueueItem(item)
						if queueItem then
							clean.queue[#clean.queue + 1] = queueItem
						end
					end
				end
				if type(placement.slots) == "table" then
					clean.slots = {}
					for _, slot in ipairs(placement.slots) do
						if type(slot) == "table" then
							local cleanSlot = {
								xp = math.max(tonumber(slot.xp) or 0, 0),
								growthElapsed = math.max(tonumber(slot.growthElapsed) or 0, 0),
								respawnAt = tonumber(slot.respawnAt),
							}
							copyMutationPayload(
								cleanSlot,
								firstMutationIds(slot.mutationIds, slot.mutations),
								slot.primaryMutationId or slot.primaryMutation
							)
							copyFoodReservationPayload(cleanSlot, slot)
							clean.slots[#clean.slots + 1] = cleanSlot
						end
					end
					clean.lastTick = tonumber(placement.lastTick) or os.time()
				end
				if type(placement.piles) == "table" then
					clean.piles = {}
					for slotKey, pile in pairs(placement.piles) do
						if type(slotKey) == "string" and type(pile) == "table" and type(pile.foodId or pile.foodType) == "string" then
							local cleanPile = {
								foodId = pile.foodId or pile.foodType,
								xp = math.max(tonumber(pile.xp) or 0, 0),
							}
							copyMutationPayload(
								cleanPile,
								firstMutationIds(pile.mutationIds, pile.mutations),
								pile.primaryMutationId or pile.primaryMutation
							)
							copyFoodReservationPayload(cleanPile, pile)
							clean.piles[slotKey] = cleanPile
						end
					end
				end
				placements[#placements + 1] = clean
			end
		end
	end
	profile.Data.FeedPlacements = placements

	local cosmeticPlacements = {}
	if type(profile.Data.CosmeticPlacements) == "table" then
		for _, placement in ipairs(profile.Data.CosmeticPlacements) do
			if type(placement) == "table"
				and type(placement.id) == "string"
				and Cosmetics.GetTemplate(placement.id) then
				cosmeticPlacements[#cosmeticPlacements + 1] = {
					id = placement.id,
					lx = tonumber(placement.lx) or 0,
					lz = tonumber(placement.lz) or 0,
					lry = tonumber(placement.lry) or 0,
				}
			end
		end
	end
	profile.Data.CosmeticPlacements = cosmeticPlacements

	local cosmeticInventory = {}
	if type(profile.Data.CosmeticInventory) == "table" then
		for cosmeticId, count in pairs(profile.Data.CosmeticInventory) do
			if type(cosmeticId) == "string"
				and type(count) == "number"
				and count > 0
				and Cosmetics.GetTemplate(cosmeticId) then
				cosmeticInventory[cosmeticId] = math.floor(count)
			end
		end
	end
	profile.Data.CosmeticInventory = cosmeticInventory

	local feedInventory = {}
	if type(profile.Data.FeedInventory) == "table" then
		for feedType, count in pairs(profile.Data.FeedInventory) do
			if type(feedType) == "string"
				and type(count) == "number"
				and count > 0
				and not DEPRECATED_FEED_TYPES[feedType] then
				feedInventory[feedType] = math.floor(count)
			end
		end
	end
	profile.Data.FeedInventory = feedInventory

	local seedInventory = {}
	if type(profile.Data.SeedInventory) == "table" then
		for seedId, count in pairs(profile.Data.SeedInventory) do
			if type(seedId) == "string"
				and type(count) == "number"
				and count > 0
				and Seeds.GetTemplate(seedId) then
				seedInventory[seedId] = math.floor(count)
			end
		end
	end
	profile.Data.SeedInventory = seedInventory

	local favouriteInventory = type(profile.Data.FavouriteInventory) == "table"
		and profile.Data.FavouriteInventory
		or {}
	profile.Data.FavouriteInventory = {
		Feed = sanitizeFavouriteCountMap(favouriteInventory.Feed, feedInventory),
		Seed = sanitizeFavouriteCountMap(favouriteInventory.Seed, seedInventory),
		Cosmetic = sanitizeFavouriteCountMap(favouriteInventory.Cosmetic, cosmeticInventory),
	}

	local foodInventoryItems = FoodInventoryService.SanitizeRecords(profile.Data.FoodInventoryItems)
	if #foodInventoryItems == 0 and type(profile.Data.FoodInventory) == "table" then
		foodInventoryItems = FoodInventoryService.RecordsFromCountMap(profile.Data.FoodInventory)
	end
	profile.Data.FoodInventoryItems = foodInventoryItems
	profile.Data.FoodInventory = FoodInventoryService.CountRecords(foodInventoryItems)

	local processedReceipts = {}
	if type(profile.Data.ProcessedReceipts) == "table" then
		for purchaseId, processed in pairs(profile.Data.ProcessedReceipts) do
			if type(purchaseId) == "string" and processed == true then
				processedReceipts[purchaseId] = true
			end
		end
	end
	profile.Data.ProcessedReceipts = processedReceipts
	profile.Data.PendingFoodStealReservation = sanitizePendingFoodStealReservation(profile.Data.PendingFoodStealReservation)
	profile.Data.PendingGrowSkipReservation = sanitizePendingGrowSkipReservation(profile.Data.PendingGrowSkipReservation)
	profile.Data.PendingCollectAllReservation = sanitizePendingCollectAllReservation(profile.Data.PendingCollectAllReservation)
	profile.Data.PendingRollOffers = RollOfferPersistence.SanitizeRecords(profile.Data.PendingRollOffers)

	profile.Data.StarterPackPurchases = sanitizeStarterPackPurchases(
		profile.Data.StarterPackPurchases,
		profile.Data.StarterPackPurchased == true
	)
	profile.Data.StarterPackPurchased = profile.Data.StarterPackPurchases.StarterPack == true

	if type(profile.Data.Currency) ~= "number" then
		profile.Data.Currency = STARTING_CURRENCY
	end
	profile.Data.RollLuckLevel = RollLuckBalance.LevelFor(profile.Data.RollLuckLevel)
	profile.Data.RollDropAreaLevel = RollDropAreaBalance.LevelFor(profile.Data.RollDropAreaLevel)
	profile.Data.AutoRollSettings = AutoRollConfig.CopySettings(profile.Data.AutoRollSettings)
	profile.Data.PlayerSettings = PlayerSettings.CopySettings(profile.Data.PlayerSettings)
	local unlockedGridKeys = PlotGrid.SanitizeUnlockedKeys(profile.Data.UnlockedGridKeys)
	if #unlockedGridKeys == 0 then
		unlockedGridKeys = PlotGrid.SanitizeUnlockedKeys(profile.Data.UnlockedGridIds)
	end
	profile.Data.UnlockedGridKeys = unlockedGridKeys
	profile.Data.UnlockedGridIds = nil
	profile.Data.Onboarding = Onboarding.SanitizeState(profile.Data.Onboarding, Onboarding.CompleteState())
	if not Onboarding.IsEnabled() then
		profile.Data.Onboarding = Onboarding.CompleteState()
	end
	profile.Data.StormChaser = sanitizeStormChaser(profile.Data.StormChaser)
	profile.Data.BeeEvent = sanitizeBeeEvent(profile.Data.BeeEvent)
	profile.Data.Discovered = sanitizeDiscovered(profile.Data.Discovered)
	profile.Data.JoinGroupRewardCollected = profile.Data.JoinGroupRewardCollected == true
	profile.Data.MediaRewardCollected = profile.Data.MediaRewardCollected == true
	if type(profile.Data.LastSeenUpdateLogId) ~= "string" then
		profile.Data.LastSeenUpdateLogId = ""
	end

	if type(profile.Data.LastSeen) ~= "number" then
		profile.Data.LastSeen = 0
	end

end

function PlayerDataService.GetProfile(player)
	local key = userKey(player)
	return key and profiles[key] or nil
end

local function startSession(store, key, player, label)
	local ok, profileOrError = pcall(function()
		return store:StartSessionAsync(tostring(key), {
			Cancel = function()
				return player:IsDescendantOf(Players) == false
			end,
		})
	end)
	if not ok then
		warn(string.format("[PlayerDataService] Failed to start %s profile session for %s: %s", label, tostring(key), tostring(profileOrError)))
		return nil
	end
	return profileOrError
end

function PlayerDataService.LoadPlayerAsync(player)
	local key = userKey(player)
	if key == nil then
		return nil
	end

	local profile = startSession(PLAYER_STORE, key, player, "primary")

	if not profile and IS_STUDIO and PLAYER_STORE ~= MOCK_PLAYER_STORE then
		warn("[PlayerDataService] Live profile load failed in Studio; retrying with mock store")
		profile = startSession(MOCK_PLAYER_STORE, key, player, "mock")
	end

	if not profile then
		player:Kick("Could not load your save data. Please rejoin.")
		return nil
	end

	profile:AddUserId(key)
	ensureValidData(profile)

	RuntimeGuard.Connect(profile.OnSessionEnd, "PlayerDataService.SessionEnd", function()
		if profiles[key] == profile then
			profiles[key] = nil
		end
		if player:IsDescendantOf(Players) then
			player:Kick("Your save data session ended. Please rejoin.")
		end
	end)

	if player:IsDescendantOf(Players) == false then
		profile:EndSession()
		return nil
	end

	profiles[key] = profile
	return profile
end

function PlayerDataService.UnloadPlayer(player)
	local key = userKey(player)
	local profile = key and profiles[key] or nil
	if profile and profile:IsActive() then
		profile:EndSession()
	end
end

function PlayerDataService.ActiveProfileCount()
	local n = 0
	for _, profile in pairs(profiles) do
		if profile:IsActive() then
			n += 1
		end
	end
	return n
end

return PlayerDataService
