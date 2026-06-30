local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Replica = require(ServerScriptService:WaitForChild("ReplicaServer"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AutoRollConfig = require(Shared:WaitForChild("AutoRollConfig"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local PlayerBonuses = require(Shared:WaitForChild("PlayerBonuses"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local PlayerReplicaService = {}

local token = Replica.Token(PlayerState.Token)
local replicas = {}
local readyConnections = {}
local gamePassOwnership = {}
local hourlyPetIncome = {}
local friendBoostPercent = {}

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

local function nonnegativeNumber(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback or 0
	end
	return math.max(value, 0)
end

local function stringValue(value)
	return type(value) == "string" and value or ""
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

local function copyGamePassOwnership(map)
	local copy = {}
	for _, pass in ipairs(ShopBalance.AllGamePasses()) do
		copy[pass.Key] = type(map) == "table" and map[pass.Key] == true or false
	end
	return copy
end

local function copyStarterPackPurchases(map)
	local copy = {}
	for _, pack in ipairs(ShopBalance.AllStarterPacks()) do
		if type(pack.PackId) == "string" and pack.PackId ~= "" then
			copy[pack.PackId] = type(map) == "table" and map[pack.PackId] == true or false
		end
	end
	return copy
end

local function vipOwnedForKey(key)
	local vipKey = ShopBalance.GamePassKeys.VIP
	local map = key and gamePassOwnership[key] or nil
	return type(map) == "table" and map[vipKey] == true or false
end

local function hourlyIncomeForKey(key)
	return nonnegativeNumber(key and hourlyPetIncome[key] or nil, 0)
end

local function friendBoostPercentForKey(key)
	return math.clamp(
		integer(key and friendBoostPercent[key] or nil, 0),
		0,
		PlayerBonuses.FriendBoostPercent(PlayerBonuses.MaxFriendBoostFriends)
	)
end

local function copyOnboardingState(value)
	return Onboarding.SanitizeState(value, Onboarding.CompleteState())
end

local function stateFromProfile(player, profile)
	local data = profile and profile.Data or {}
	local key = userKey(player)
	return {
		[PlayerState.Fields.ProfileReady] = profile ~= nil,
		[PlayerState.Fields.Currency] = integer(data.Currency, 0),
		[PlayerState.Fields.Rebirths] = integer(data.Rebirths, 0),
		[PlayerState.Fields.RollLuckLevel] = integer(data.RollLuckLevel, 0),
		[PlayerState.Fields.RollDropAreaLevel] = integer(data.RollDropAreaLevel, 0),
		[PlayerState.Fields.AutoRollSettings] = AutoRollConfig.CopySettings(data.AutoRollSettings),
		[PlayerState.Fields.CosmeticInventory] = copyCountMap(data.CosmeticInventory),
		[PlayerState.Fields.FeedInventory] = copyCountMap(data.FeedInventory),
		[PlayerState.Fields.SeedInventory] = copyCountMap(data.SeedInventory),
		[PlayerState.Fields.FoodInventory] = copyCountMap(data.FoodInventory),
		[PlayerState.Fields.UnlockedGridKeys] = copyStringArray(data.UnlockedGridKeys),
		[PlayerState.Fields.Onboarding] = copyOnboardingState(data.Onboarding),
		[PlayerState.Fields.StarterPackPurchased] = data.StarterPackPurchased == true,
		[PlayerState.Fields.StarterPackPurchases] = copyStarterPackPurchases(data.StarterPackPurchases),
		[PlayerState.Fields.GamePassOwnership] = copyGamePassOwnership(key and gamePassOwnership[key] or nil),
		[PlayerState.Fields.VipOwned] = vipOwnedForKey(key),
		[PlayerState.Fields.FriendBoostPercent] = friendBoostPercentForKey(key),
		[PlayerState.Fields.HourlyPetIncome] = hourlyIncomeForKey(key),
		[PlayerState.Fields.JoinGroupRewardCollected] = data.JoinGroupRewardCollected == true,
		[PlayerState.Fields.LastSeenUpdateLogId] = stringValue(data.LastSeenUpdateLogId),
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
		Data = stateFromProfile(player, profile),
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
	for fieldName, value in pairs(stateFromProfile(player, profile)) do
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

function PlayerReplicaService.PublishAutoRollSettings(player, profile)
	local data = profile and profile.Data or {}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.AutoRollSettings, AutoRollConfig.CopySettings(data.AutoRollSettings))
end

function PlayerReplicaService.PublishInventories(player, profile)
	local data = profile and profile.Data or {}
	local success = true
	if not PlayerReplicaService.PublishField(player, PlayerState.Fields.CosmeticInventory, copyCountMap(data.CosmeticInventory)) then
		success = false
	end
	if not PlayerReplicaService.PublishField(player, PlayerState.Fields.FeedInventory, copyCountMap(data.FeedInventory)) then
		success = false
	end
	if not PlayerReplicaService.PublishField(player, PlayerState.Fields.SeedInventory, copyCountMap(data.SeedInventory)) then
		success = false
	end
	if not PlayerReplicaService.PublishField(player, PlayerState.Fields.FoodInventory, copyCountMap(data.FoodInventory)) then
		success = false
	end
	return success
end

function PlayerReplicaService.PublishFoodInventory(player, profile)
	local data = profile and profile.Data or {}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.FoodInventory, copyCountMap(data.FoodInventory))
end

function PlayerReplicaService.PublishUnlockedGridKeys(player, profile)
	local data = profile and profile.Data or {}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.UnlockedGridKeys, copyStringArray(data.UnlockedGridKeys))
end

function PlayerReplicaService.PublishOnboarding(player, profile)
	local data = profile and profile.Data or {}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.Onboarding, copyOnboardingState(data.Onboarding))
end

function PlayerReplicaService.PublishStarterPackPurchased(player, profile)
	local data = profile and profile.Data or {}
	local legacySuccess = PlayerReplicaService.PublishField(player, PlayerState.Fields.StarterPackPurchased, data.StarterPackPurchased == true)
	local purchasesSuccess = PlayerReplicaService.PublishField(
		player,
		PlayerState.Fields.StarterPackPurchases,
		copyStarterPackPurchases(data.StarterPackPurchases)
	)
	return legacySuccess and purchasesSuccess
end

function PlayerReplicaService.PublishGamePassOwnership(player, ownership)
	local key = userKey(player)
	if key then
		gamePassOwnership[key] = copyGamePassOwnership(ownership)
	end
	local safeOwnership = copyGamePassOwnership(ownership)
	local success = PlayerReplicaService.PublishField(player, PlayerState.Fields.GamePassOwnership, safeOwnership)
	local vipSuccess = PlayerReplicaService.PublishField(player, PlayerState.Fields.VipOwned, safeOwnership[ShopBalance.GamePassKeys.VIP] == true)
	return success and vipSuccess
end

function PlayerReplicaService.PublishVipOwned(player, owned)
	local key = userKey(player)
	local ownership = key and copyGamePassOwnership(gamePassOwnership[key]) or {}
	ownership[ShopBalance.GamePassKeys.VIP] = owned == true
	return PlayerReplicaService.PublishGamePassOwnership(player, ownership)
end

function PlayerReplicaService.PublishHourlyPetIncome(player, amount)
	local key = userKey(player)
	local safeAmount = nonnegativeNumber(amount, 0)
	if key then
		hourlyPetIncome[key] = safeAmount
	end
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.HourlyPetIncome, safeAmount)
end

function PlayerReplicaService.PublishFriendBoostPercent(player, amount)
	local key = userKey(player)
	local safeAmount = math.clamp(
		integer(amount, 0),
		0,
		PlayerBonuses.FriendBoostPercent(PlayerBonuses.MaxFriendBoostFriends)
	)
	if key then
		friendBoostPercent[key] = safeAmount
	end
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.FriendBoostPercent, safeAmount)
end

function PlayerReplicaService.PublishJoinBackShowcase(player, payload)
	if type(payload) ~= "table" then
		return PlayerReplicaService.PublishField(player, PlayerState.Fields.JoinBackShowcase, nil)
	end
	local safePayload = {
		seq = integer(payload.seq, 0),
		phase = type(payload.phase) == "string" and payload.phase or "pending",
	}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.JoinBackShowcase, safePayload)
end

function PlayerReplicaService.PublishJoinGroupRewardCollected(player, profile)
	local data = profile and profile.Data or {}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.JoinGroupRewardCollected, data.JoinGroupRewardCollected == true)
end

function PlayerReplicaService.PublishLastSeenUpdateLogId(player, profile)
	local data = profile and profile.Data or {}
	return PlayerReplicaService.PublishField(player, PlayerState.Fields.LastSeenUpdateLogId, stringValue(data.LastSeenUpdateLogId))
end

RuntimeGuard.Connect(Players.PlayerRemoving, "PlayerReplicaService.PlayerRemoving", function(player)
	local key = userKey(player)
	PlayerReplicaService.Destroy(player)
	if key then
		gamePassOwnership[key] = nil
		hourlyPetIncome[key] = nil
		friendBoostPercent[key] = nil
	end
end)

return PlayerReplicaService
