local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileService = require(ReplicatedStorage.Shared:WaitForChild("ProfileService"))

local function defaultData()
	return {
		Pets = {
			{ type = "Pet1", xp = 0, money = 0 },
			{ type = "Pet1", xp = 0, money = 0 },
		},
		FeedPlacements = {},
		FeedInventory  = { Clicker1 = 1, Timed1 = 1, Processor1 = 1 },
		FoodInventory  = {},          -- { [FoodType] = count }
		Currency       = 0,
		LastSeen       = 0,
	}
end

local PROFILE_STORE = ProfileService.GetProfileStore("PlayerData_v7", defaultData())

local profiles = {}

local PlayerDataService = {}

function PlayerDataService.GetProfile(player)
	return profiles[player]
end

function PlayerDataService.LoadPlayerAsync(player)
	local key = "Player_" .. player.UserId
	local profile = PROFILE_STORE:LoadProfileAsync(key)
	if not profile then
		player:Kick("Could not load your save data. Please rejoin.")
		return nil
	end

	local defaults = defaultData()
	for k, default in pairs(defaults) do
		if profile.Data[k] == nil then
			profile.Data[k] = default
		end
	end

	-- Ensure at least one pet on a fresh/corrupt save
	if type(profile.Data.Pets) ~= "table" or #profile.Data.Pets == 0 then
		profile.Data.Pets = defaults.Pets
	end

	-- Seed FeedInventory if player has zero total feeds (placed + in inventory)
	local totalFeeds = #profile.Data.FeedPlacements
	for _, n in pairs(profile.Data.FeedInventory) do totalFeeds += n end
	if totalFeeds == 0 then
		profile.Data.FeedInventory = { Clicker1 = 1, Timed1 = 1, Processor1 = 1 }
	end

	profiles[player] = profile
	return profile
end

function PlayerDataService.UnloadPlayer(player)
	local profile = profiles[player]
	if not profile then return end
	-- Another coroutine (e.g., PlayerRemoving) is already in the middle of
	-- Release'ing this profile. Don't call Release again and don't clear the
	-- map — the original caller will finish the work and clear the map once
	-- SetAsync completes.
	if profile._released then return end
	profile:Release()
	profiles[player] = nil
end

function PlayerDataService.ActiveProfileCount()
	local n = 0
	for _ in pairs(profiles) do n += 1 end
	return n
end

return PlayerDataService
