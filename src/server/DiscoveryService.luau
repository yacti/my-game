-- Index/codex discovery tracking. Marks pets (by PetID) and feed machines
-- (by FeedType) as discovered on the profile and republishes the Discovered
-- replica field on change. Seeds discover the machine their FeedType grows
-- into. Sync is the catch-all used for load-time backfill and the periodic
-- profile snapshot (covers gifting and any grant path without a point hook).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local PlayerReplicaService = require(script.Parent:WaitForChild("PlayerReplicaService"))

local DiscoveryService = {}

local function ensure(profile)
	local data = profile and profile.Data
	if type(data) ~= "table" then
		return nil
	end
	if type(data.Discovered) ~= "table" then
		data.Discovered = {}
	end
	if type(data.Discovered.Pets) ~= "table" then
		data.Discovered.Pets = {}
	end
	if type(data.Discovered.Feed) ~= "table" then
		data.Discovered.Feed = {}
	end
	return data.Discovered
end

local function copySet(set)
	local copy = {}
	for id, flag in pairs(set) do
		if type(id) == "string" and flag == true then
			copy[id] = true
		end
	end
	return copy
end

local function publish(player, discovered)
	PlayerReplicaService.PublishField(player, PlayerState.Fields.Discovered, {
		Pets = copySet(discovered.Pets),
		Feed = copySet(discovered.Feed),
	})
end

local function mark(set, id)
	if type(id) ~= "string" or id == "" or set[id] == true then
		return false
	end
	set[id] = true
	return true
end

function DiscoveryService.MarkPet(player, profile, petId)
	local discovered = ensure(profile)
	if not discovered then
		return false
	end
	local changed = mark(discovered.Pets, petId)
	if changed then
		publish(player, discovered)
	end
	return changed
end

function DiscoveryService.MarkFeedType(player, profile, feedType)
	local discovered = ensure(profile)
	if not discovered then
		return false
	end
	local changed = mark(discovered.Feed, feedType)
	if changed then
		publish(player, discovered)
	end
	return changed
end

function DiscoveryService.MarkSeed(player, profile, seedId)
	return DiscoveryService.MarkFeedType(player, profile, Seeds.FeedTypeFor(seedId))
end

-- Scan-and-mark everything the profile currently owns: pets, feed inventory,
-- seed inventory (mapped to the machine they grow into), and placed machines
-- (FeedPlacements[*].type is already the machine FeedType, even while the
-- placement is still a growing seed).
function DiscoveryService.Sync(player, profile)
	local discovered = ensure(profile)
	if not discovered then
		return false
	end
	local data = profile.Data
	local changed = false

	if type(data.Pets) == "table" then
		for _, petData in pairs(data.Pets) do
			if type(petData) == "table" then
				changed = mark(discovered.Pets, petData.petId) or changed
			end
		end
	end

	if type(data.FeedInventory) == "table" then
		for feedType in pairs(data.FeedInventory) do
			changed = mark(discovered.Feed, feedType) or changed
		end
	end

	if type(data.SeedInventory) == "table" then
		for seedId in pairs(data.SeedInventory) do
			changed = mark(discovered.Feed, Seeds.FeedTypeFor(seedId)) or changed
		end
	end

	if type(data.FeedPlacements) == "table" then
		for _, placement in ipairs(data.FeedPlacements) do
			if type(placement) == "table" then
				changed = mark(discovered.Feed, placement.type) or changed
			end
		end
	end

	if changed then
		publish(player, discovered)
	end
	return changed
end

return DiscoveryService
