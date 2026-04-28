local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileService = require(ReplicatedStorage.Shared:WaitForChild("ProfileService"))

-- FeedInventory shape: per-FeedType list of *individual tools*, each with
-- a Level. We can't collapse to a count anymore because some FeedMachines
-- (AppleTree) carry persistent state — picking up a Lv5 tree must yield a
-- Lv5 tool. Old saves stored counts; they migrate to all-Lv1 tools.
local function defaultFeedInventory()
	return {
		Clicker1   = { levels = { 1 } },
		TimedNew   = { levels = { 1 } },
		Processor1 = { levels = { 1 } },
		AppleTree  = { levels = { 1 } },
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
		FoodInventory  = {},          -- { [FoodType] = count }
		Currency       = 0,
		LastSeen       = 0,
	}
end

-- One-shot migration: old saves stored placements with offX/offZ/rotY in
-- world space, which doesn't survive a Floor rotation / move. Records that
-- lack the new floor-local fields (lx/lz) are wiped from FeedPlacements
-- and credited back to FeedInventory at their stored level so players
-- keep their machines.
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
			local ft  = rec.type or "Timed1"
			local lvl = tonumber(rec.level) or 1
			profile.Data.FeedInventory[ft] = profile.Data.FeedInventory[ft] or { levels = {} }
			table.insert(profile.Data.FeedInventory[ft].levels, lvl)
		end
	end
	profile.Data.FeedPlacements = {}
end

-- Old saves stored FeedInventory[feedType] as a number; new shape is
-- { levels = {…} } so each tool's Level persists. Idempotent — already-
-- migrated entries pass through unchanged. Garbage entries are dropped.
local function migrateFeedInventory(inv)
	if type(inv) ~= "table" then return {} end
	local out = {}
	for ft, v in pairs(inv) do
		if type(v) == "number" and v > 0 then
			out[ft] = { levels = table.create(v, 1) }
		elseif type(v) == "table" and type(v.levels) == "table" then
			-- Sanity-clean: drop non-numeric/non-positive level entries.
			local clean = {}
			for _, lv in ipairs(v.levels) do
				if type(lv) == "number" and lv >= 1 then
					table.insert(clean, math.floor(lv))
				end
			end
			if #clean > 0 then out[ft] = { levels = clean } end
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
	for _, entry in pairs(profile.Data.FeedInventory) do
		totalFeeds += #entry.levels
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
