local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local VipService = {}

local RETRY_DELAY_SECONDS = 1

local started = false
local ownershipByUserId = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function vipConfig()
	return ShopBalance.GetVIP() or {}
end

local function gamePassId()
	return ShopBalance.VIPGamePassId()
end

local function finiteNumber(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	return value
end

local function publishOwnership(player, owned)
	local key = userKey(player)
	if not key then
		return false
	end
	ownershipByUserId[key] = owned == true
	PlayerReplicaService.PublishVipOwned(player, ownershipByUserId[key])
	return true
end

local function queryOwnership(player)
	local key = userKey(player)
	local passId = gamePassId()
	if not key or passId <= 0 or not player:IsDescendantOf(Players) then
		return false, false, "invalid-player"
	end

	local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, key, passId)
	if not ok then
		return false, false, "lookup-failed"
	end
	return true, owns == true, "ok"
end

function VipService.RefreshOwnership(player)
	local key = userKey(player)
	if not key then
		return false, "invalid-player"
	end

	local lastCode = "lookup-failed"
	for attempt = 1, 2 do
		local ok, owns, code = queryOwnership(player)
		lastCode = code or lastCode
		if ok then
			publishOwnership(player, owns)
			return owns, "ok"
		end
		if attempt == 1 then
			task.wait(RETRY_DELAY_SECONDS)
		end
	end

	publishOwnership(player, false)
	warn(string.format("[VipService] Failed to verify VIP ownership for user %s: %s", tostring(key), tostring(lastCode)))
	return false, lastCode
end

function VipService.OwnsVip(player)
	local key = userKey(player)
	return key ~= nil and ownershipByUserId[key] == true
end

function VipService.PetCashEarnRate(player)
	if not VipService.OwnsVip(player) then
		return 1
	end
	local rate = finiteNumber(vipConfig().PetCashEarnRate, 1)
	return rate > 0 and rate or 1
end

function VipService.LuckBonusPercent(player)
	if not VipService.OwnsVip(player) then
		return 0
	end
	return math.max(finiteNumber(vipConfig().LuckBonusPercent, 0), 0)
end

function VipService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Players.PlayerRemoving, "VipService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			ownershipByUserId[key] = nil
		end
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptGamePassPurchaseFinished, "VipService.PromptGamePassPurchaseFinished", function(player, purchasedGamePassId)
		if tonumber(purchasedGamePassId) ~= gamePassId() then
			return
		end
		RuntimeGuard.Spawn("VipService.RefreshPurchaseOwnership", VipService.RefreshOwnership, player)
	end)
end

return VipService
