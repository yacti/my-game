local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerBonuses = require(Shared:WaitForChild("PlayerBonuses"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local GamePassService = {}

local LOOKUP_RETRIES = 2
local RETRY_DELAY_SECONDS = 1
local DEFAULT_REFRESH_TIMEOUT_SECONDS = 5
local LOG_PREFIX = "[GamePassService]"

local started = false
local ownershipByUserId = {}
local ownershipChangedCallbacks = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function emptyOwnership()
	local map = {}
	for _, pass in ipairs(ShopBalance.AllGamePasses()) do
		map[pass.Key] = false
	end
	return map
end

local function copyOwnership(map)
	local copy = emptyOwnership()
	if type(map) ~= "table" then
		return copy
	end
	for key in pairs(copy) do
		copy[key] = map[key] == true
	end
	return copy
end

local function ownershipForUserId(key)
	if not key then
		return emptyOwnership()
	end
	local map = ownershipByUserId[key]
	if type(map) ~= "table" then
		map = emptyOwnership()
		ownershipByUserId[key] = map
	end
	return map
end

local function publishOwnership(player)
	local key = userKey(player)
	if not key then
		return false
	end
	return PlayerReplicaService.PublishGamePassOwnership(player, ownershipForUserId(key))
end

local function notifyOwnershipChanged(player)
	for _, callback in ipairs(ownershipChangedCallbacks) do
		RuntimeGuard.Run("GamePassService.OwnershipChangedCallback", callback, player)
	end
end

local function configuredPasses()
	return ShopBalance.AllGamePasses()
end

local function passForKey(passKey)
	return ShopBalance.GamePassForKey(passKey)
end

local function passForGamePassId(gamePassId)
	return ShopBalance.GamePassForId(gamePassId)
end

local function queryOwnership(player, pass)
	local key = userKey(player)
	local passId = tonumber(pass and pass.GamePassId) or 0
	if not key or passId <= 0 or not player:IsDescendantOf(Players) then
		return false, false, "invalid-player"
	end

	local lastCode = "lookup-failed"
	for attempt = 1, LOOKUP_RETRIES do
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, key, passId)
		if ok then
			return true, owns == true, "ok"
		end
		if attempt < LOOKUP_RETRIES then
			task.wait(RETRY_DELAY_SECONDS)
		end
	end
	return false, false, lastCode
end

local function applyLookupResult(player, pass, ok, owns, code)
	local key = userKey(player)
	if not key or not pass then
		return false
	end
	local ownership = ownershipForUserId(key)
	local previous = ownership[pass.Key] == true
	if ok then
		ownership[pass.Key] = owns == true
	elseif ownership[pass.Key] ~= true then
		ownership[pass.Key] = false
	end
	if not ok then
		warn(string.format(
			"%s Failed to verify %s ownership for user %s: %s",
			LOG_PREFIX,
			tostring(pass.Key),
			tostring(key),
			tostring(code or "lookup-failed")
		))
	end
	return previous ~= (ownership[pass.Key] == true)
end

function GamePassService.RefreshOwnership(player, options)
	options = type(options) == "table" and options or {}
	local key = userKey(player)
	if not key then
		return nil, "invalid-player"
	end

	local passes = {}
	if type(options.PassKey) == "string" then
		local pass = passForKey(options.PassKey)
		if pass then
			passes[#passes + 1] = pass
		end
	else
		passes = configuredPasses()
	end
	if #passes == 0 then
		publishOwnership(player)
		return copyOwnership(ownershipForUserId(key)), "ok"
	end

	local pending = #passes
	local deadline = os.clock() + (tonumber(options.TimeoutSeconds) or DEFAULT_REFRESH_TIMEOUT_SECONDS)
	for _, pass in ipairs(passes) do
		task.spawn(function()
			local ok, owns, code = queryOwnership(player, pass)
			local changed = applyLookupResult(player, pass, ok, owns, code)
			pending -= 1
			publishOwnership(player)
			if changed then
				notifyOwnershipChanged(player)
			end
		end)
	end

	while pending > 0 and os.clock() < deadline and player:IsDescendantOf(Players) do
		task.wait()
	end

	if pending > 0 then
		warn(string.format("%s Ownership refresh timed out for user %s with %d pending lookups", LOG_PREFIX, tostring(key), pending))
		publishOwnership(player)
		return copyOwnership(ownershipForUserId(key)), "timeout"
	end

	publishOwnership(player)
	return copyOwnership(ownershipForUserId(key)), "ok"
end

function GamePassService.RefreshGamePassId(player, gamePassId)
	local pass = passForGamePassId(gamePassId)
	if not pass then
		return nil, "unknown-gamepass"
	end
	return GamePassService.RefreshOwnership(player, {
		PassKey = pass.Key,
		TimeoutSeconds = DEFAULT_REFRESH_TIMEOUT_SECONDS,
	})
end

function GamePassService.OwnershipMap(player)
	return copyOwnership(ownershipByUserId[userKey(player)])
end

function GamePassService.Owns(player, passKey)
	local ownership = ownershipByUserId[userKey(player)]
	return type(ownership) == "table" and ownership[passKey] == true or false
end

function GamePassService.PetCashMultiplier(player)
	return PlayerBonuses.PetCashMultiplier(GamePassService.OwnershipMap(player))
end

function GamePassService.LuckBonusPercent(player)
	return PlayerBonuses.LuckBonusPercent(GamePassService.OwnershipMap(player))
end

function GamePassService.FoodXPMultiplier(player)
	return PlayerBonuses.FoodXPMultiplier(GamePassService.OwnershipMap(player))
end

function GamePassService.RegisterOwnershipChangedCallback(callback)
	if type(callback) ~= "function" then
		return nil
	end
	table.insert(ownershipChangedCallbacks, callback)
	local index = #ownershipChangedCallbacks
	return function()
		if ownershipChangedCallbacks[index] == callback then
			table.remove(ownershipChangedCallbacks, index)
		end
	end
end

function GamePassService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Players.PlayerRemoving, "GamePassService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			ownershipByUserId[key] = nil
		end
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptGamePassPurchaseFinished, "GamePassService.PromptGamePassPurchaseFinished", function(player, purchasedGamePassId)
		if not passForGamePassId(purchasedGamePassId) then
			return
		end
		RuntimeGuard.Spawn("GamePassService.RefreshPurchaseOwnership", GamePassService.RefreshGamePassId, player, purchasedGamePassId)
	end)
end

return GamePassService
