local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProfileStore = require(ReplicatedStorage.Shared:WaitForChild("ProfileStore"))
local PlotGrid = require(ReplicatedStorage.Shared:WaitForChild("PlotGrid"))
local RebirthBalance = require(ReplicatedStorage.Shared:WaitForChild("RebirthBalance"))
local RollDropAreaBalance = require(ReplicatedStorage.Shared:WaitForChild("RollDropAreaBalance"))
local RollLuckBalance = require(ReplicatedStorage.Shared:WaitForChild("RollLuckBalance"))
local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(ReplicatedStorage.Shared:WaitForChild("Seeds"))
local Cosmetics = require(ReplicatedStorage.Shared:WaitForChild("Cosmetics"))
local Onboarding = require(ReplicatedStorage.Shared:WaitForChild("Onboarding"))
local FoodInventoryService = require(script.Parent:WaitForChild("FoodInventoryService"))

local STORE_NAME = "PlayerData"
local USE_MOCK_STORE_IN_STUDIO = true
local CURRENT_DATA_VERSION = 7
local GROWING_SEED_PHASE = "GrowingSeed"
local STARTING_CURRENCY = 100
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
	FoodInventoryItems = {}, -- { { foodId = string, xp = number, guid = string?, scale = number? } }
	ProcessedReceipts = {},
	PendingFoodStealReservation = nil,
	PendingGrowSkipReservation = nil,
	StarterPackPurchased = false,
	Currency = STARTING_CURRENCY,
	RollLuckLevel = 0,
	RollDropAreaLevel = 0,
	Rebirths = 0,
	UnlockedGridKeys = {},
	Onboarding = Onboarding.DefaultState(),
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
	local feedIndex = math.max(math.floor(tonumber(value.feedIndex) or 0), 0)
	local seedId = value.seedId
	local createdAt = math.floor(tonumber(value.createdAt) or os.time())
	local expiresAt = math.floor(tonumber(value.expiresAt) or 0)
	if productId <= 0 or feedIndex <= 0 or type(seedId) ~= "string" or seedId == "" or expiresAt <= 0 then
		return nil
	end
	return {
		reservationId = reservationId,
		productId = productId,
		feedIndex = feedIndex,
		seedId = seedId,
		createdAt = createdAt,
		expiresAt = expiresAt,
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
							clean.slots[#clean.slots + 1] = {
								xp = math.max(tonumber(slot.xp) or 0, 0),
								growthElapsed = math.max(tonumber(slot.growthElapsed) or 0, 0),
								respawnAt = tonumber(slot.respawnAt),
							}
						end
					end
					clean.lastTick = tonumber(placement.lastTick) or os.time()
				end
				if type(placement.piles) == "table" then
					clean.piles = {}
					for slotKey, pile in pairs(placement.piles) do
						if type(slotKey) == "string" and type(pile) == "table" and type(pile.foodId or pile.foodType) == "string" then
							clean.piles[slotKey] = {
								foodId = pile.foodId or pile.foodType,
								xp = math.max(tonumber(pile.xp) or 0, 0),
							}
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

	profile.Data.StarterPackPurchased = profile.Data.StarterPackPurchased == true

	if type(profile.Data.Currency) ~= "number" then
		profile.Data.Currency = STARTING_CURRENCY
	end
	profile.Data.RollLuckLevel = RollLuckBalance.LevelFor(profile.Data.RollLuckLevel)
	profile.Data.RollDropAreaLevel = RollDropAreaBalance.LevelFor(profile.Data.RollDropAreaLevel)
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
