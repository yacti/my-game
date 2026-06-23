local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerBonuses = require(Shared:WaitForChild("PlayerBonuses"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local FriendBoostService = {}

local REFRESH_DEBOUNCE_SECONDS = 0.25
local LOG_PREFIX = "[FriendBoostService]"

local started = false
local refreshScheduled = false
local refreshGeneration = 0
local recordsByUserId = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function validPlayer(player)
	return player and player:IsA("Player") and player:IsDescendantOf(Players)
end

local function safeRecord(friendCount)
	friendCount = PlayerBonuses.FriendBoostFriendCount(friendCount)
	return {
		friendCount = friendCount,
		percent = PlayerBonuses.FriendBoostPercent(friendCount),
		multiplier = PlayerBonuses.FriendBoostMultiplier(friendCount),
	}
end

local function recordFor(player)
	local key = userKey(player)
	if not key then
		return safeRecord(0)
	end
	return recordsByUserId[key] or safeRecord(0)
end

local function publish(player)
	local record = recordFor(player)
	return PlayerReplicaService.PublishFriendBoostPercent(player, record.percent)
end

local function applyRecord(player, friendCount)
	local key = userKey(player)
	if not key or not validPlayer(player) then
		return
	end

	recordsByUserId[key] = safeRecord(friendCount)
	publish(player)
end

local function isFriend(player, otherPlayer)
	if not (validPlayer(player) and validPlayer(otherPlayer)) then
		return false
	end

	local ok, result = pcall(function()
		return player:IsFriendsWithAsync(otherPlayer.UserId)
	end)
	if not ok then
		warn(string.format(
			"%s Failed friendship lookup for users %s and %s: %s",
			LOG_PREFIX,
			tostring(player.UserId),
			tostring(otherPlayer.UserId),
			tostring(result)
		))
		return false
	end
	return result == true
end

local function countServerFriends(player, players)
	local count = 0
	for _, otherPlayer in ipairs(players) do
		if otherPlayer ~= player and isFriend(player, otherPlayer) then
			count += 1
			if count >= PlayerBonuses.MaxFriendBoostFriends then
				return count
			end
		end
	end
	return count
end

function FriendBoostService.RefreshAll()
	refreshGeneration += 1
	local generation = refreshGeneration
	local players = Players:GetPlayers()

	RuntimeGuard.Spawn("FriendBoostService.RefreshAll", function()
		for _, player in ipairs(players) do
			if generation ~= refreshGeneration then
				return
			end
			if validPlayer(player) then
				applyRecord(player, countServerFriends(player, players))
			end
		end
	end)
end

function FriendBoostService.ScheduleRefresh()
	if refreshScheduled then
		return
	end
	refreshScheduled = true
	task.delay(REFRESH_DEBOUNCE_SECONDS, function()
		refreshScheduled = false
		FriendBoostService.RefreshAll()
	end)
end

function FriendBoostService.Publish(player)
	return publish(player)
end

function FriendBoostService.FriendCount(player)
	return recordFor(player).friendCount
end

function FriendBoostService.BoostPercent(player)
	return recordFor(player).percent
end

function FriendBoostService.Multiplier(player)
	return recordFor(player).multiplier
end

function FriendBoostService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Players.PlayerAdded, "FriendBoostService.PlayerAdded", function()
		FriendBoostService.ScheduleRefresh()
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "FriendBoostService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			recordsByUserId[key] = nil
		end
		FriendBoostService.ScheduleRefresh()
	end)

	FriendBoostService.ScheduleRefresh()
end

return FriendBoostService
