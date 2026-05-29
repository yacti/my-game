local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProfileStore = require(ReplicatedStorage.Shared:WaitForChild("ProfileStore"))
local PlotGrid = require(ReplicatedStorage.Shared:WaitForChild("PlotGrid"))

local STORE_NAME = "PlayerData"
local USE_MOCK_STORE_IN_STUDIO = true

-- Fresh ProfileStore-backed schema for the active PlayerData store.
local DATA_TEMPLATE = {
	Pets = {
		{ petId = "Pet1", xp = 0, money = 0 },
	},
	FeedPlacements = {},
	FeedInventory = {
		Processor1 = 1,
		AppleTree = 1,
		BananaTree = 1,
		CherryTree = 1,
		FigTree = 1,
		OrangeTree = 1,
		PumpkinPatch = 1,
		StarfruitTree = 1,
	},
	FoodInventory = {}, -- { [FoodId] = count }
	ProcessedReceipts = {},
	Currency = 0,
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

ProfileStore.OnError:Connect(function(message, storeName, profileKey)
	warn(string.format("[ProfileStore] Store=%s Key=%s Error=%s", tostring(storeName), tostring(profileKey), tostring(message)))
end)

ProfileStore.OnCriticalToggle:Connect(function(isCritical)
	if isCritical then
		warn("[ProfileStore] DataStore access is in a critical state")
	end
end)

local function ensureValidData(profile)
	profile:Reconcile()

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
			if type(placement) == "table" and type(placement.type) == "string" then
				local clean = {
					type = placement.type,
					lx = tonumber(placement.lx) or 0,
					lz = tonumber(placement.lz) or 0,
					lry = tonumber(placement.lry) or 0,
				}
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
								stage = math.max(math.floor(tonumber(slot.stage) or 1), 1),
								xp = math.max(tonumber(slot.xp) or 0, 0),
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

	local feedInventory = {}
	if type(profile.Data.FeedInventory) == "table" then
		for feedType, count in pairs(profile.Data.FeedInventory) do
			if type(feedType) == "string" and type(count) == "number" and count > 0 then
				feedInventory[feedType] = math.floor(count)
			end
		end
	end
	profile.Data.FeedInventory = feedInventory

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

	local totalFeeds = #profile.Data.FeedPlacements
	for _, count in pairs(profile.Data.FeedInventory) do
		totalFeeds += count
	end
	if totalFeeds == 0 then
		profile.Data.FeedInventory = table.clone(DATA_TEMPLATE.FeedInventory)
	end
end

function PlayerDataService.GetProfile(player)
	return profiles[player]
end

function PlayerDataService.LoadPlayerAsync(player)
	local profile = PLAYER_STORE:StartSessionAsync(tostring(player.UserId), {
		Cancel = function()
			return player:IsDescendantOf(Players) == false
		end,
	})

	if not profile and IS_STUDIO and PLAYER_STORE ~= MOCK_PLAYER_STORE then
		warn("[PlayerDataService] Live profile load failed in Studio; retrying with mock store")
		profile = MOCK_PLAYER_STORE:StartSessionAsync(tostring(player.UserId), {
			Cancel = function()
				return player:IsDescendantOf(Players) == false
			end,
		})
	end

	if not profile then
		player:Kick("Could not load your save data. Please rejoin.")
		return nil
	end

	profile:AddUserId(player.UserId)
	ensureValidData(profile)

	profile.OnSessionEnd:Connect(function()
		if profiles[player] == profile then
			profiles[player] = nil
		end
		if player:IsDescendantOf(Players) then
			player:Kick("Your save data session ended. Please rejoin.")
		end
	end)

	if player:IsDescendantOf(Players) == false then
		profile:EndSession()
		return nil
	end

	profiles[player] = profile
	return profile
end

function PlayerDataService.UnloadPlayer(player)
	local profile = profiles[player]
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
