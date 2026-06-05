local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProfileStore = require(ReplicatedStorage.Shared:WaitForChild("ProfileStore"))
local PlotGrid = require(ReplicatedStorage.Shared:WaitForChild("PlotGrid"))
local RollDropAreaBalance = require(ReplicatedStorage.Shared:WaitForChild("RollDropAreaBalance"))
local RollLuckBalance = require(ReplicatedStorage.Shared:WaitForChild("RollLuckBalance"))
local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(ReplicatedStorage.Shared:WaitForChild("Seeds"))
local Cosmetics = require(ReplicatedStorage.Shared:WaitForChild("Cosmetics"))

local STORE_NAME = "PlayerData"
local USE_MOCK_STORE_IN_STUDIO = true
local CURRENT_DATA_VERSION = 5
local GROWING_SEED_PHASE = "GrowingSeed"
local STARTER_COSMETIC_INVENTORY = {
	Fountain = 1,
}

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
	FeedInventory = {},
	SeedInventory = {}, -- { [SeedID] = count }
	FoodInventory = {}, -- { [FoodId] = count }
	ProcessedReceipts = {},
	Currency = 0,
	RollLuckLevel = 0,
	RollDropAreaLevel = 0,
	Rebirths = 0,
	UnlockedGridKeys = {},
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
		end

		version = nextVersion
		data.DataVersion = version
	end
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

	local pets = {}
	if type(profile.Data.Pets) == "table" then
		for i, pet in ipairs(profile.Data.Pets) do
			if type(pet) == "table" then
				pets[i] = {
					petId = type(pet.petId) == "string" and pet.petId
						or type(pet.type) == "string" and pet.type
						or "Pet1",
					xp = math.max(tonumber(pet.xp) or 0, 0),
					money = math.max(tonumber(pet.money) or 0, 0),
					lx = tonumber(pet.lx),
					lz = tonumber(pet.lz),
					lry = tonumber(pet.lry) or 0,
				}
			end
		end
	end
	if #pets == 0 then
		pets = {
			{ petId = "Pet1", xp = 0, money = 0 },
		}
	end
	profile.Data.Pets = pets

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
						if type(item) == "table" and type(item.foodId or item.foodType) == "string" then
							clean.queue[#clean.queue + 1] = {
								foodId = item.foodId or item.foodType,
								depositedAt = tonumber(item.depositedAt) or os.time(),
							}
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

	local foodInventory = {}
	if type(profile.Data.FoodInventory) == "table" then
		for foodId, count in pairs(profile.Data.FoodInventory) do
			if type(foodId) == "string" and type(count) == "number" and count > 0 then
				foodInventory[foodId] = math.floor(count)
			end
		end
	end
	profile.Data.FoodInventory = foodInventory

	local processedReceipts = {}
	if type(profile.Data.ProcessedReceipts) == "table" then
		for purchaseId, processed in pairs(profile.Data.ProcessedReceipts) do
			if type(purchaseId) == "string" and processed == true then
				processedReceipts[purchaseId] = true
			end
		end
	end
	profile.Data.ProcessedReceipts = processedReceipts

	if type(profile.Data.Currency) ~= "number" then
		profile.Data.Currency = 0
	end
	profile.Data.RollLuckLevel = RollLuckBalance.LevelFor(profile.Data.RollLuckLevel)
	profile.Data.RollDropAreaLevel = RollDropAreaBalance.LevelFor(profile.Data.RollDropAreaLevel)
	profile.Data.Rebirths = math.max(math.floor(tonumber(profile.Data.Rebirths) or 0), 0)
	local unlockedGridKeys = PlotGrid.SanitizeUnlockedKeys(profile.Data.UnlockedGridKeys)
	if #unlockedGridKeys == 0 then
		unlockedGridKeys = PlotGrid.SanitizeUnlockedKeys(profile.Data.UnlockedGridIds)
	end
	profile.Data.UnlockedGridKeys = unlockedGridKeys
	profile.Data.UnlockedGridIds = nil

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
