local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Replica = require(ServerScriptService:WaitForChild("ReplicaServer"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerReplicaService = {}

local token = Replica.Token(PlayerState.Token)
local replicas = {}
local readyConnections = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function integer(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback or 0
	end
	return math.max(math.floor(value), 0)
end

local function copyCountMap(map)
	local copy = {}
	if type(map) ~= "table" then
		return copy
	end
	for key, count in pairs(map) do
		if type(key) == "string" then
			local safeCount = integer(count, 0)
			if safeCount > 0 then
				copy[key] = safeCount
			end
		end
	end
	return copy
end

local function copyStringArray(array)
	local copy = {}
	if type(array) ~= "table" then
		return copy
	end
	local seen = {}
	for _, key in ipairs(array) do
		if type(key) == "string" and not seen[key] then
			seen[key] = true
			copy[#copy + 1] = key
		end
	end
	return copy
end

local function copyOnboardingState(value)
	return Onboarding.SanitizeState(value, Onboarding.CompleteState())
end

local function stateFromProfile(profile)
	local data = profile and profile.Data or {}
	return {
		[PlayerState.Fields.ProfileReady] = profile ~= nil,
		[PlayerState.Fields.Currency] = integer(data.Currency, 0),
		[PlayerState.Fields.Rebirths] = integer(data.Rebirths, 0),
		[PlayerState.Fields.RollLuckLevel] = integer(data.RollLuckLevel, 0),
		[PlayerState.Fields.RollDropAreaLevel] = integer(data.RollDropAreaLevel, 0),
		[PlayerState.Fields.CosmeticInventory] = copyCountMap(data.CosmeticInventory),
		[PlayerState.Fields.FeedInventory] = copyCountMap(data.FeedInventory),
		[PlayerState.Fields.SeedInventory] = copyCountMap(data.SeedInventory),
		[PlayerState.Fields.FoodInventory] = copyCountMap(data.FoodInventory),
		[PlayerState.Fields.UnlockedGridKeys] = copyStringArray(data.UnlockedGridKeys),
		[PlayerState.Fields.Onboarding] = copyOnboardingState(data.Onboarding),
	}
end

local function replicaFor(player)
	local key = userKey(player)
	return key and replicas[key] or nil
end

local function clearReadyConnection(key)
	local connection = readyConnections[key]
	if connection then
		connection:Disconnect()
		readyConnections[key] = nil
	end
end

local function subscribeWhenReady(player, replica)
	local key = userKey(player)
	if not key then
		return
	end

	clearReadyConnection(key)

	local function subscribe()
		if replicaFor(player) ~= replica or not replica:IsActive() then
			return false
		end
		if player:IsDescendantOf(Players) then
			local ok = RuntimeGuard.Run("PlayerReplicaService.Subscribe", function()
				replica:Subscribe(player)
			end)
			return ok == true
		end
		return false
	end

	local function retrySubscribe()
		task.delay(1, function()
			RuntimeGuard.Run("PlayerReplicaService.SubscribeRetry", function()
				if subscribe() then
					clearReadyConnection(key)
				end
			end)
		end)
	end

	if Replica.ReadyPlayers[player] == true then
		if not subscribe() then
			retrySubscribe()
		end
		return
	end

	readyConnections[key] = RuntimeGuard.Connect(Replica.NewReadyPlayer, "PlayerReplicaService.NewReadyPlayer", function(readyPlayer)
		if readyPlayer ~= player then
			return
		end
		if subscribe() then
			clearReadyConnection(key)
		else
			retrySubscribe()
		end
	end)
end

function PlayerReplicaService.Create(player, profile)
	local key = userKey(player)
	if not key then
		return nil
	end

	PlayerReplicaService.Destroy(player)

	local replica = Replica.New({
		Token = token,
		Tags = {
			UserId = key,
		},
		Data = stateFromProfile(profile),
	})
	replicas[key] = replica
	subscribeWhenReady(player, replica)
	return replica
end

function PlayerReplicaService.Destroy(player)
	local key = userKey(player)
	if not key then
		return
	end

	clearReadyConnection(key)

	local replica = replicas[key]
	replicas[key] = nil
	if replica and replica:IsActive() then
		replica:Destroy()
	end
end

function PlayerReplicaService.PublishField(player, fieldName, value)
	local replica = replicaFor(player)
	if not (replica and replica:IsActive()) then
		return false
	end
	local ok = RuntimeGuard.Run("PlayerReplicaService.PublishField." .. tostring(fieldName), function()
		replica:Set({ fieldName }, value)
	end)
	return ok == true
end

function PlayerReplicaService.PublishProfile(player, profile)
	local replica = replicaFor(player)
	if not (replica and replica:IsActive()) then
		return false
	end
	for fieldName, value in pairs(stateFromProfile(profile)) do
		local ok = RuntimeGuard.Run("PlayerReplicaService.PublishProfile." .. tostring(fieldName), function()
			replica:Set({ fieldName }, value)
		end)
		if not ok then
			return false
		end
	end
	return true
end

function PlayerReplicaService.PublishCurrency(player, amount)
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.Currency, integer(amount, 0))
end

function PlayerReplicaService.PublishRebirths(player, rebirths)
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.Rebirths, integer(rebirths, 0))
end

function PlayerReplicaService.PublishRollLuckLevel(player, level)
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.RollLuckLevel, integer(level, 0))
end

function PlayerReplicaService.PublishRollDropAreaLevel(player, level)
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.RollDropAreaLevel, integer(level, 0))
end

function PlayerReplicaService.PublishInventories(player, profile)
	local data = profile and profile.Data or {}
	PlayerReplicaService.PublishField(player, PlayerState.Fields.CosmeticInventory, copyCountMap(data.CosmeticInventory))
	PlayerReplicaService.PublishField(player, PlayerState.Fields.FeedInventory, copyCountMap(data.FeedInventory))
	PlayerReplicaService.PublishField(player, PlayerState.Fields.SeedInventory, copyCountMap(data.SeedInventory))
	PlayerReplicaService.PublishField(player, PlayerState.Fields.FoodInventory, copyCountMap(data.FoodInventory))
end

function PlayerReplicaService.PublishUnlockedGridKeys(player, profile)
	local data = profile and profile.Data or {}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.UnlockedGridKeys, copyStringArray(data.UnlockedGridKeys))
end

function PlayerReplicaService.PublishOnboarding(player, profile)
	local data = profile and profile.Data or {}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.Onboarding, copyOnboardingState(data.Onboarding))
end

RuntimeGuard.Connect(Players.PlayerRemoving, "PlayerReplicaService.PlayerRemoving", function(player)
	PlayerReplicaService.Destroy(player)
end)

return PlayerReplicaService
