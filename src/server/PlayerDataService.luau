local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileService = require(ReplicatedStorage.Shared:WaitForChild("ProfileService"))

local function defaultFeedInventory()
	return {
		Clicker1   = 1,
		TimedNew   = 1,
		Processor1 = 1,
		AppleTree  = 1,
		CherryTree = 1,
	}
end

local function defaultData()
	return {
		Pets = {
			{ type = "Pet1", xp = 0, money = 0 },
			{ type = "Pet1", xp = 0, money = 0 },
		},
		FeedPlacements = {},
		FeedInventory  = defaultFeedInventory(),
		FoodInventory  = {},          -- { [FoodId] = count }
		Currency       = 0,
		LastSeen       = 0,
	}
end

-- One-shot migration: old saves stored placements with offX/offZ/rotY in
-- world space, which doesn't survive a Floor rotation / move. Records
-- without the floor-local fields (lx/lz) are wiped from FeedPlacements
-- and credited back to FeedInventory so players don't lose machines.
local function migrateFeedPlacementsAndCredit(profile)
	local placements = profile.Data.FeedPlacements
	if type(placements) ~= "table" then
		profile.Data.FeedPlacements = {}
		return
	end
	local hasOld = false
	for _, rec in ipairs(placements) do
		if type(rec) == "table" and rec.lx == nil
			and (rec.offX ~= nil or rec.offZ ~= nil or rec.rotY ~= nil) then
			hasOld = true
			break
		end
	end
	if not hasOld then return end

	for _, rec in ipairs(placements) do
		if type(rec) == "table" then
			local ft = rec.type or "Timed1"
			profile.Data.FeedInventory[ft] = (profile.Data.FeedInventory[ft] or 0) + 1
		end
	end
	profile.Data.FeedPlacements = {}
end

-- Sanity-clean FeedInventory. Earlier dev builds briefly used a
-- { levels = {…} } shape; collapse those back to a count, drop garbage.
local function migrateFeedInventory(inv)
	if type(inv) ~= "table" then return {} end
	local out = {}
	for ft, v in pairs(inv) do
		if type(v) == "number" and v > 0 then
			out[ft] = math.floor(v)
		elseif type(v) == "table" and type(v.levels) == "table" then
			local n = 0
			for _, lv in ipairs(v.levels) do
				if type(lv) == "number" and lv >= 1 then n = n + 1 end
			end
			if n > 0 then out[ft] = n end
		end
	end
	return out
end

local PROFILE_STORE = ProfileService.GetProfileStore("PlayerData_v13", defaultData())

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

	profile.Data.FeedInventory = migrateFeedInventory(profile.Data.FeedInventory)
	migrateFeedPlacementsAndCredit(profile)

	-- Seed FeedInventory if player has zero total feeds (placed + in inventory).
	local totalFeeds = #profile.Data.FeedPlacements
	for _, count in pairs(profile.Data.FeedInventory) do
		totalFeeds += count
	end
	if totalFeeds == 0 then
		profile.Data.FeedInventory = defaultFeedInventory()
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
