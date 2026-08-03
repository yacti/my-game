local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PetSkinTools = require(Server:WaitForChild("PetSkinTools"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Inventory = require(Shared:WaitForChild("Inventory"))
local PetSkinCatalog = require(Shared:WaitForChild("PetSkinCatalog"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local PetSkinPackShopService = {}

local started = false
local locks = {}
local rng = Random.new()
local resultRemote = Remotes.get(Remotes.Names.SeedPackPurchaseResult)

local function integer(value)
	value = tonumber(value) or 0
	if value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function destroyPrepared(prepared)
	for _, tool in ipairs(type(prepared) == "table" and prepared.tools or {}) do
		if tool then
			tool:Destroy()
		end
	end
end

local function rollRewards(quantity)
	local rewards = {}
	for _ = 1, quantity do
		local reward = PetSkinCatalog.Roll(rng)
		if not reward or not PetSkinCatalog.TemplateFor(reward.Id) then
			return nil, "roll-failed"
		end
		rewards[#rewards + 1] = reward
	end
	return rewards, "ok"
end

local function prepareRewards(rewards)
	local prepared = { tools = {}, counts = {} }
	for _, reward in ipairs(rewards) do
		local grant, code = PetSkinTools.PrepareGrant(reward.Id, 1)
		if not grant then
			destroyPrepared(prepared)
			return nil, code
		end
		for _, tool in ipairs(grant.tools or {}) do
			prepared.tools[#prepared.tools + 1] = tool
		end
		prepared.counts[reward.Id] = (prepared.counts[reward.Id] or 0) + 1
	end
	return prepared, "ok"
end

local function grantPrepared(player, profile, prepared)
	local granted, code = ToolGrantService.GrantTools(player, prepared.tools, {
		autoEquip = false,
		maxItems = Inventory.HARD_MAX_ITEMS,
	})
	if not granted then
		destroyPrepared(prepared)
		return false, code
	end
	profile.Data.PetSkinInventory = profile.Data.PetSkinInventory or {}
	for petSkinId, amount in pairs(prepared.counts) do
		profile.Data.PetSkinInventory[petSkinId] = integer(profile.Data.PetSkinInventory[petSkinId]) + amount
	end
	return true, "ok"
end

local function rollback(profile, prepared)
	local inventory = profile and profile.Data and profile.Data.PetSkinInventory
	if type(inventory) == "table" then
		for petSkinId, amount in pairs(prepared.counts or {}) do
			inventory[petSkinId] = math.max(integer(inventory[petSkinId]) - integer(amount), 0)
			if inventory[petSkinId] == 0 then
				inventory[petSkinId] = nil
			end
		end
	end
	destroyPrepared(prepared)
end

local function saveProfile(profile)
	return pcall(function()
		profile:Save()
	end)
end

local function revealPayload(pack, rewards)
	local results = {}
	for _, reward in ipairs(rewards) do
		results[#results + 1] = {
			kind = "PetSkin",
			petSkinId = reward.Id,
			displayName = PetSkinCatalog.NameFor(reward.Id),
			rarity = reward.Rarity,
			chanceText = PetSkinCatalog.ChanceText(reward.Id),
		}
	end
	return {
		action = "reveal",
		packId = pack.PackId,
		sourceSection = "Featured",
		results = results,
	}
end

function PetSkinPackShopService.HandlesProductId(productId)
	return ShopBalance.PetSkinPackForProductId(productId) ~= nil
end

function PetSkinPackShopService.Start()
	if started then
		return
	end
	started = true
	RuntimeGuard.Connect(Players.PlayerRemoving, "PetSkinPackShopService.PlayerRemoving", function(player)
		locks[player.UserId] = nil
	end)
end

function PetSkinPackShopService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local pack, quantity = ShopBalance.PetSkinPackForProductId(receiptInfo.ProductId)
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
	local key = player.UserId
	if locks[key] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	locks[key] = true
	local granted = false
	local rewards = nil
	local prepared = nil
	local resultCode = "server-error"
	local ok, err = pcall(function()
		quantity = integer(quantity)
		if quantity ~= 1 and quantity ~= 12 then
			resultCode = "invalid-quantity"
			return
		end
		rewards, resultCode = rollRewards(quantity)
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
			rollback(profile, prepared)
			granted = false
			resultCode = "save-failed"
		end
	end)
	locks[key] = nil

	if not ok then
		warn("[PetSkinPackShopService] Receipt grant failed: " .. tostring(err))
		if granted and prepared then
			ReceiptService.ClearProcessed(profile, purchaseId)
			rollback(profile, prepared)
			granted = false
		elseif prepared then
			destroyPrepared(prepared)
		end
		resultCode = "server-error"
	end

	PlayerReplicaService.PublishInventories(player, profile)
	if granted then
		NotificationService.Success(player, string.format("Purchased %d %s%s!", quantity, pack.DisplayName, quantity == 1 and "" or "s"))
		resultRemote:FireClient(player, revealPayload(pack, rewards))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if resultCode ~= "inventory-full" then
		NotificationService.Error(player, "Could not grant your Pet Skin Pack yet")
	end
	warn("[PetSkinPackShopService] Receipt grant failed: " .. tostring(resultCode))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

return PetSkinPackShopService
