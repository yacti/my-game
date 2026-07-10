local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local DiscoveryService = require(Server:WaitForChild("DiscoveryService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))
local SeedTools = require(Server:WaitForChild("SeedTools"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local SeedPackShopService = {}

local started = false
local locks = {}
local rng = Random.new()

local resultRemote = Remotes.get(Remotes.Names.SeedPackPurchaseResult)

local function userKey(player)
	return player and player.UserId or nil
end

local function updateSeedPacksAllowed(player)
	if not (player and player:IsDescendantOf(Players)) then
		return
	end

	player:SetAttribute(State.Player.SeedPacksAllowed, false)
	local ok, policyInfo = pcall(PolicyService.GetPolicyInfoForPlayerAsync, PolicyService, player)
	if not (ok and type(policyInfo) == "table") then
		warn("[SeedPackShopService] Could not load paid random item policy for user " .. tostring(userKey(player)))
		return
	end
	if player:IsDescendantOf(Players) then
		player:SetAttribute(State.Player.SeedPacksAllowed, policyInfo.ArePaidRandomItemsRestricted ~= true)
	end
end

local function int(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function addSeedCount(counts, seedId, amount)
	if type(seedId) ~= "string" or seedId == "" then
		return
	end
	counts[seedId] = (counts[seedId] or 0) + int(amount)
end

local function destroyPrepared(prepared)
	if type(prepared) ~= "table" then
		return
	end
	for _, tool in ipairs(prepared.tools or {}) do
		if tool then
			tool:Destroy()
		end
	end
end

local function rollbackPrepared(profile, prepared)
	if type(prepared) ~= "table" then
		return
	end
	local inventory = profile and profile.Data and profile.Data.SeedInventory
	if type(inventory) == "table" then
		for seedId, amount in pairs(prepared.counts or {}) do
			inventory[seedId] = math.max(int(inventory[seedId]) - int(amount), 0)
			if inventory[seedId] <= 0 then
				inventory[seedId] = nil
			end
		end
	end
	destroyPrepared(prepared)
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

local function resultPayload(pack, rewards)
	local results = {}
	for _, reward in ipairs(rewards) do
		results[#results + 1] = {
			seedId = reward.SeedId,
			displayName = Seeds.DisplayNameFor(reward.SeedId),
			rarity = Seeds.RarityFor(reward.SeedId),
			chanceText = reward.ChanceText,
		}
	end
	return {
		action = "reveal",
		packId = pack.PackId,
		sourceSection = "SeedPacks",
		results = results,
	}
end

local function rollRewards(pack, quantity)
	local rewards = {}
	for _ = 1, quantity do
		local reward = ShopBalance.RollSeedPackReward(pack, rng)
		if not reward then
			return nil, "roll-failed"
		end
		if not Seeds.GetTemplate(reward.SeedId) then
			return nil, "no-template"
		end
		rewards[#rewards + 1] = reward
	end
	return rewards, "ok"
end

local function prepareRewards(rewards)
	local prepared = {
		tools = {},
		counts = {},
	}
	for _, reward in ipairs(rewards) do
		local seedId = reward.SeedId
		local seedGrant, code = SeedTools.PrepareGrant(seedId, 1)
		if not seedGrant then
			destroyPrepared(prepared)
			return nil, code or "grant-failed"
		end
		for _, tool in ipairs(seedGrant.tools or {}) do
			prepared.tools[#prepared.tools + 1] = tool
		end
		addSeedCount(prepared.counts, seedId, 1)
	end
	return prepared, "ok"
end

local function grantPrepared(player, profile, prepared)
	if not (player and profile and type(prepared) == "table") then
		destroyPrepared(prepared)
		return false, "invalid-grant"
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		destroyPrepared(prepared)
		return false, "no-backpack"
	end

	local granted, code = ToolGrantService.GrantTools(player, prepared.tools, {
		autoEquip = false,
		ignoreInventoryCap = true,
	})
	if not granted then
		destroyPrepared(prepared)
		return false, code or "grant-failed"
	end

	profile.Data.SeedInventory = profile.Data.SeedInventory or {}
	for seedId, amount in pairs(prepared.counts or {}) do
		profile.Data.SeedInventory[seedId] = int(profile.Data.SeedInventory[seedId]) + int(amount)
		DiscoveryService.MarkSeed(player, profile, seedId)
	end
	return true, "ok"
end

function SeedPackShopService.HandlesProductId(productId)
	return ShopBalance.SeedPackForProductId(productId) ~= nil
end

function SeedPackShopService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local pack, quantity = ShopBalance.SeedPackForProductId(receiptInfo.ProductId)
	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not (player and profile and pack and purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if ReceiptService.HasProcessed(profile, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if OfflineProgressService.IsPending(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local key = userKey(player)
	if not key or locks[key] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	locks[key] = true
	local granted = false
	local resultCode = "server-error"
	local rewards = nil
	local prepared = nil

	local ok, err = pcall(function()
		quantity = math.max(int(quantity), 1)
		rewards, resultCode = rollRewards(pack, quantity)
		if not rewards then
			return
		end

		prepared, resultCode = prepareRewards(rewards)
		if not prepared then
			return
		end

		granted, resultCode = grantPrepared(player, profile, prepared)
		if not granted then
			prepared = nil
			return
		end

		ReceiptService.MarkProcessed(profile, purchaseId)
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			rollbackPrepared(profile, prepared)
			granted = false
			resultCode = "save-failed"
			return
		end
	end)
	locks[key] = nil

	if not ok then
		warn("[SeedPackShopService] Receipt grant failed: " .. tostring(err))
		if granted and prepared then
			ReceiptService.ClearProcessed(profile, purchaseId)
			rollbackPrepared(profile, prepared)
			granted = false
		elseif prepared then
			destroyPrepared(prepared)
		end
		resultCode = "server-error"
	end

	PlayerReplicaService.PublishInventories(player, profile)
	if granted then
		NotificationService.Success(player, string.format("Purchased %s!", pack.DisplayName or "Seed Pack"))
		resultRemote:FireClient(player, resultPayload(pack, rewards))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if resultCode == "inventory-full" then
		-- ToolGrantService emits the rate-limited inventory full notification.
	elseif resultCode == "no-backpack" then
		NotificationService.Error(player, "Could not grant your seed pack yet. Please rejoin and try again")
	else
		NotificationService.Error(player, "Could not grant your seed pack yet")
	end
	warn("[SeedPackShopService] Receipt grant failed: " .. tostring(resultCode))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function SeedPackShopService.Start()
	if started then
		return
	end
	started = true

	for _, player in ipairs(Players:GetPlayers()) do
		RuntimeGuard.Spawn("SeedPackShopService.Policy." .. tostring(userKey(player)), updateSeedPacksAllowed, player)
	end

	RuntimeGuard.Connect(Players.PlayerAdded, "SeedPackShopService.PlayerAdded", function(player)
		RuntimeGuard.Spawn("SeedPackShopService.Policy." .. tostring(userKey(player)), updateSeedPacksAllowed, player)
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "SeedPackShopService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
		end
	end)
end

return SeedPackShopService
