-- Standalone Durian Pack feature: Robux ticket purchases arrive through
-- MarketplaceService receipts (routed by ReceiptService), and ticket-funded
-- rolls arrive through DurianPackRollRequest. One ticket funds one roll from
-- ShopBalance.DurianPack.Rewards; every PityRollCount-th roll is a guaranteed
-- PitySeedId and resets the pity counter, while naturally rolled durians do
-- not. Legacy shop-era DurianPack products convert one purchased roll into
-- one ticket so pending receipts stay processable.

local Players = game:GetService("Players")
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
local Inventory = require(Shared:WaitForChild("Inventory"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local DurianPackShopService = {}

local started = false
local locks = {}
local rng = Random.new()

local rollRequestRemote = Remotes.get(Remotes.Names.DurianPackRollRequest)
local rollResultRemote = Remotes.get(Remotes.Names.DurianPackRollResult)

local function userKey(player)
	return player and player.UserId or nil
end

local function int(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

local function isGameplayBlocked(player)
	return OfflineProgressService.IsPending(player)
		or (player and player:GetAttribute(State.Player.InventoryRestorePending) == true)
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

local function pityReward(pack)
	for _, reward in ipairs(pack.Rewards or {}) do
		if reward.SeedId == pack.PitySeedId then
			return {
				SeedId = reward.SeedId,
				Weight = reward.Weight,
				ChanceText = ShopBalance.ChanceText(pack, reward),
			}
		end
	end
	return nil
end

-- Rolls rollCount rewards and returns them with the resulting pity counter.
-- The pity counter is only committed to the profile after a successful grant.
local function rollRewards(pack, rollCount, pity)
	local rewards = {}
	for _ = 1, rollCount do
		pity += 1
		local reward
		if pity >= pack.PityRollCount then
			reward = pityReward(pack)
			pity = 0
		else
			reward = ShopBalance.RollSeedPackReward(pack, rng)
		end
		if not reward then
			return nil, pity, "roll-failed"
		end
		if not Seeds.GetTemplate(reward.SeedId) then
			return nil, pity, "no-template"
		end
		rewards[#rewards + 1] = reward
	end
	return rewards, pity, "ok"
end

local function prepareRewards(rewards)
	local prepared = {
		tools = {},
		counts = {},
	}
	for _, reward in ipairs(rewards) do
		local seedGrant, code = SeedTools.PrepareGrant(reward.SeedId, 1)
		if not seedGrant then
			destroyPrepared(prepared)
			return nil, code or "grant-failed"
		end
		for _, tool in ipairs(seedGrant.tools or {}) do
			prepared.tools[#prepared.tools + 1] = tool
		end
		prepared.counts[reward.SeedId] = (prepared.counts[reward.SeedId] or 0) + 1
	end
	return prepared, "ok"
end

local function grantPrepared(player, profile, prepared)
	if not player:FindFirstChildOfClass("Backpack") then
		destroyPrepared(prepared)
		return false, "no-backpack"
	end

	-- Ticket rolls grant above the normal 250 soft cap, but never above the
	-- physical ceiling the per-spawn restore can rebuild. A blocked grant
	-- leaves the ticket unspent, so the roll can be retried.
	local granted, code = ToolGrantService.GrantTools(player, prepared.tools, {
		autoEquip = false,
		maxItems = Inventory.HARD_MAX_ITEMS,
	})
	if not granted then
		destroyPrepared(prepared)
		return false, code or "grant-failed"
	end

	profile.Data.SeedInventory = profile.Data.SeedInventory or {}
	for seedId, amount in pairs(prepared.counts) do
		profile.Data.SeedInventory[seedId] = int(profile.Data.SeedInventory[seedId]) + int(amount)
		DiscoveryService.MarkSeed(player, profile, seedId)
	end
	return true, "ok"
end

local function revealPayload(pack, rewards)
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
		sourceSection = "DurianPack",
		results = results,
	}
end

local function fireRollResult(player, requestId, success, code, reveal)
	rollResultRemote:FireClient(player, {
		requestId = requestId,
		success = success == true,
		code = code,
		reveal = reveal,
	})
end

local function handleRollRequest(player, requestId, rollCount)
	requestId = tonumber(requestId)
	if type(requestId) ~= "number" or requestId ~= requestId or math.abs(requestId) == math.huge then
		return
	end
	rollCount = int(rollCount)
	if not ShopBalance.DurianRollCountAllowed(rollCount) then
		fireRollResult(player, requestId, false, "invalid-roll-count")
		return
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		fireRollResult(player, requestId, false, "no-profile")
		return
	end
	if isGameplayBlocked(player) then
		fireRollResult(player, requestId, false, "busy")
		return
	end

	local key = userKey(player)
	if not key or locks[key] then
		fireRollResult(player, requestId, false, "busy")
		return
	end

	local pack = ShopBalance.GetDurianPack()
	if int(profile.Data.DurianTickets) < rollCount then
		fireRollResult(player, requestId, false, "not-enough-tickets")
		NotificationService.Error(player, "No durian tickets!")
		return
	end

	locks[key] = true
	local granted = false
	local resultCode = "server-error"
	local rewards = nil
	local prepared = nil

	local ok, err = pcall(function()
		local nextPity
		rewards, nextPity, resultCode = rollRewards(pack, rollCount, int(profile.Data.DurianPackPity))
		if not rewards then
			return
		end

		prepared, resultCode = prepareRewards(rewards)
		if not prepared then
			return
		end

		granted, resultCode = grantPrepared(player, profile, prepared)
		if not granted then
			return
		end

		profile.Data.DurianTickets = int(profile.Data.DurianTickets) - rollCount
		profile.Data.DurianPackPity = nextPity
	end)
	locks[key] = nil

	if not ok then
		warn("[DurianPackShopService] Roll grant failed: " .. tostring(err))
		if granted then
			rollbackPrepared(profile, prepared)
		else
			destroyPrepared(prepared)
		end
		PlayerReplicaService.PublishInventories(player, profile)
		fireRollResult(player, requestId, false, "server-error")
		return
	end

	PlayerReplicaService.PublishInventories(player, profile)
	PlayerReplicaService.PublishDurianPack(player, profile)
	if granted then
		fireRollResult(player, requestId, true, "ok", revealPayload(pack, rewards))
		return
	end

	if resultCode == "no-backpack" then
		NotificationService.Error(player, "Could not roll the Durian Pack yet. Please rejoin and try again")
	elseif resultCode ~= "inventory-full" then
		-- ToolGrantService emits the rate-limited inventory full notification.
		NotificationService.Error(player, "Could not roll the Durian Pack yet")
	end
	fireRollResult(player, requestId, false, resultCode)
	warn("[DurianPackShopService] Roll grant failed: " .. tostring(resultCode))
end

function DurianPackShopService.HandlesProductId(productId)
	return ShopBalance.DurianTicketProductForProductId(productId) ~= nil
end

function DurianPackShopService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local product = ShopBalance.DurianTicketProductForProductId(receiptInfo.ProductId)
	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not (player and profile and product and purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if ReceiptService.HasProcessed(profile, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local key = userKey(player)
	if not key or locks[key] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	locks[key] = true
	local previousTickets = int(profile.Data.DurianTickets)
	local grantedTickets = int(product.Tickets) + int(product.ExtraTickets)
	local granted = false

	local ok, err = pcall(function()
		profile.Data.DurianTickets = previousTickets + grantedTickets
		ReceiptService.MarkProcessed(profile, purchaseId)
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			profile.Data.DurianTickets = previousTickets
			return
		end
		granted = true
	end)
	locks[key] = nil

	if not ok then
		warn("[DurianPackShopService] Receipt grant failed: " .. tostring(err))
		ReceiptService.ClearProcessed(profile, purchaseId)
		profile.Data.DurianTickets = previousTickets
		granted = false
	end

	PlayerReplicaService.PublishDurianPack(player, profile)
	if granted then
		NotificationService.Success(player, string.format(
			"Purchased %d Durian Ticket%s!",
			grantedTickets,
			grantedTickets == 1 and "" or "s"
		))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	NotificationService.Error(player, "Could not grant your Durian Tickets yet")
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function DurianPackShopService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(rollRequestRemote.OnServerEvent, "DurianPackShopService.RollRequest", handleRollRequest)
	RuntimeGuard.Connect(Players.PlayerRemoving, "DurianPackShopService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
		end
	end)
end

return DurianPackShopService
