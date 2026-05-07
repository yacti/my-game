local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileStore = require(ReplicatedStorage.Shared:WaitForChild("ProfileStore"))

local DATA_TEMPLATE = {
	Pets = {
		{ type = "Pet1", xp = 0, money = 0 },
		{ type = "Pet1", xp = 0, money = 0 },
	},
	FeedPlacements = {},
	FeedInventory = {
		Clicker1 = 1,
		Processor1 = 1,
		AppleTree = 1,
		CherryTree = 1,
		PumpkinPatch = 1,
	},
	FoodInventory = {}, -- { [FoodId] = count }
	Currency = 0,
	LastSeen = 0,
}

local PLAYER_STORE = ProfileStore.New("PlayerData", DATA_TEMPLATE)
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

	if type(profile.Data.Pets) ~= "table" or #profile.Data.Pets == 0 then
		profile.Data.Pets = {
			{ type = "Pet1", xp = 0, money = 0 },
			{ type = "Pet1", xp = 0, money = 0 },
		}
	end

	if type(profile.Data.FeedPlacements) ~= "table" then
		profile.Data.FeedPlacements = {}
	end

	if type(profile.Data.FeedInventory) ~= "table" then
		profile.Data.FeedInventory = {}
	end

	if type(profile.Data.FoodInventory) ~= "table" then
		profile.Data.FoodInventory = {}
	end

	if type(profile.Data.Currency) ~= "number" then
		profile.Data.Currency = 0
	end

	if type(profile.Data.LastSeen) ~= "number" then
		profile.Data.LastSeen = 0
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
