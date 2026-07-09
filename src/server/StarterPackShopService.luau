local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local DiscoveryService = require(Server:WaitForChild("DiscoveryService"))
local FeedRewardService = require(Server:WaitForChild("FeedRewardService"))
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
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local StarterPackShopService = {}

local REQUEST_RATE_SECONDS = 0.5

local started = false
local locks = {}
local lastRequest = {}

local purchaseRequestRemote = Remotes.get(Remotes.Names.StarterPackPurchaseRequest)
local purchaseResultRemote = Remotes.get(Remotes.Names.StarterPackPurchaseResult)

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

local function copyBooleanMap(map)
	local copy = {}
	if type(map) ~= "table" then
		return copy
	end
	for key, value in pairs(map) do
		if type(key) == "string" and value == true then
			copy[key] = true
		end
	end
	return copy
end

local function starterPackPurchases(profile)
	local data = profile and profile.Data
	if not data then
		return {}
	end
	if type(data.StarterPackPurchases) ~= "table" then
		data.StarterPackPurchases = {}
	end
	if data.StarterPackPurchased == true then
		data.StarterPackPurchases.StarterPack = true
	end
	data.StarterPackPurchased = data.StarterPackPurchases.StarterPack == true
	return data.StarterPackPurchases
end

local function starterPackOwned(profile, packId)
	local purchases = starterPackPurchases(profile)
	return type(packId) == "string" and purchases[packId] == true
end

local function markStarterPackOwned(profile, packId)
	local purchases = starterPackPurchases(profile)
	if type(packId) == "string" and packId ~= "" then
		purchases[packId] = true
	end
	profile.Data.StarterPackPurchased = purchases.StarterPack == true
end

local function sendPurchaseResult(player, requestId, success, code, payload)
	local result = type(payload) == "table" and payload or {}
	result.requestId = requestId
	result.success = success == true
	result.code = code
	purchaseResultRemote:FireClient(player, result)
end

local function addSeedCount(counts, seedId, amount)
	if type(seedId) ~= "string" or seedId == "" then
		return
	end
	counts[seedId] = int(counts[seedId]) + int(amount)
end

local function addFeedCount(counts, feedType, amount)
	if type(feedType) ~= "string" or feedType == "" then
		return
	end
	counts[feedType] = int(counts[feedType]) + int(amount)
end

local function addCashAmount(prepared, amount)
	prepared.cashAmount = int(prepared.cashAmount) + int(amount)
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

local function rollbackPrepared(player, profile, prepared)
	if type(prepared) ~= "table" then
		return
	end

	local data = profile and profile.Data
	local seedInventory = data and data.SeedInventory
	if type(seedInventory) == "table" then
		for seedId, amount in pairs(prepared.seedCounts or {}) do
			seedInventory[seedId] = math.max(int(seedInventory[seedId]) - int(amount), 0)
			if seedInventory[seedId] <= 0 then
				seedInventory[seedId] = nil
			end
		end
	end

	local feedInventory = data and data.FeedInventory
	if type(feedInventory) == "table" then
		for feedType, amount in pairs(prepared.feedCounts or {}) do
			feedInventory[feedType] = math.max(int(feedInventory[feedType]) - int(amount), 0)
			if feedInventory[feedType] <= 0 then
				feedInventory[feedType] = nil
			end
		end
	end

	local cashAmount = int(prepared.cashAmount)
	if cashAmount > 0 then
		local currentCurrency = int(data and data.Currency)
		CurrencyService.SetBalanceForServer(player, profile, math.max(currentCurrency - cashAmount, 0), true)
	end
	destroyPrepared(prepared)
end

local function prepareRewards(pack)
	local prepared = {
		tools = {},
		seedCounts = {},
		feedCounts = {},
		cashAmount = 0,
	}
	for _, reward in ipairs(pack and pack.Rewards or {}) do
		local amount = int(reward.Amount)
		if reward.Kind == ShopBalance.StarterPackRewardKinds.Cash then
			addCashAmount(prepared, amount)
		elseif reward.Kind == ShopBalance.StarterPackRewardKinds.Seed then
			local seedGrant, code = SeedTools.PrepareGrant(reward.SeedId, amount)
			if not seedGrant then
				destroyPrepared(prepared)
				return nil, code or "grant-failed"
			end
			for _, tool in ipairs(seedGrant.tools or {}) do
				prepared.tools[#prepared.tools + 1] = tool
			end
			addSeedCount(prepared.seedCounts, reward.SeedId, amount)
		elseif reward.Kind == ShopBalance.StarterPackRewardKinds.FeedMachine then
			local feedGrant, code = FeedRewardService.PrepareGrant(reward.FeedType, amount)
			if not feedGrant then
				destroyPrepared(prepared)
				return nil, code or "grant-failed"
			end
			for _, tool in ipairs(feedGrant.tools or {}) do
				prepared.tools[#prepared.tools + 1] = tool
			end
			addFeedCount(prepared.feedCounts, reward.FeedType, amount)
		else
			destroyPrepared(prepared)
			return nil, "invalid-reward"
		end
	end
	return prepared, "ok"
end

local function grantPrepared(player, profile, prepared)
	if not (player and profile and type(prepared) == "table") then
		destroyPrepared(prepared)
		return false, "invalid-grant"
	end
	local tools = prepared.tools or {}
	if #tools > 0 and not player:FindFirstChildOfClass("Backpack") then
		destroyPrepared(prepared)
		return false, "no-backpack"
	end

	local cashAmount = int(prepared.cashAmount)
	if cashAmount > 0 then
		local _, cashCode = CurrencyService.Add(player, profile, cashAmount, true)
		if cashCode then
			destroyPrepared(prepared)
			return false, cashCode
		end
	end

	if #tools > 0 then
		local granted, code = ToolGrantService.GrantTools(player, tools, {
			autoEquip = false,
		})
		if not granted then
			if cashAmount > 0 then
				local currentCurrency = int(profile.Data.Currency)
				CurrencyService.SetBalanceForServer(player, profile, math.max(currentCurrency - cashAmount, 0), true)
			end
			destroyPrepared(prepared)
			return false, code or "grant-failed"
		end
	end

	profile.Data.SeedInventory = profile.Data.SeedInventory or {}
	for seedId, amount in pairs(prepared.seedCounts or {}) do
		profile.Data.SeedInventory[seedId] = int(profile.Data.SeedInventory[seedId]) + int(amount)
		DiscoveryService.MarkSeed(player, profile, seedId)
	end
	profile.Data.FeedInventory = profile.Data.FeedInventory or {}
	for feedType, amount in pairs(prepared.feedCounts or {}) do
		profile.Data.FeedInventory[feedType] = int(profile.Data.FeedInventory[feedType]) + int(amount)
		DiscoveryService.MarkFeedType(player, profile, feedType)
	end
	return true, "ok"
end

local function requiredSlots(pack)
	return ShopBalance.StarterPackTotalAmount(pack)
end

function StarterPackShopService.HandlesProductId(productId)
	return ShopBalance.StarterPackForProductId(productId) ~= nil
end

local function onPurchaseRequest(player, requestId, packId)
	if type(requestId) ~= "number" then
		return
	end
	if packId == nil then
		packId = "StarterPack"
	end

	local pack = ShopBalance.StarterPackForPackId(packId)
	local profile = PlayerDataService.GetProfile(player)
	if not (pack and profile) then
		sendPurchaseResult(player, requestId, false, "profile-not-ready")
		return
	end
	if OfflineProgressService.IsPending(player) then
		sendPurchaseResult(player, requestId, false, "offline-progress")
		return
	end
	local activePack = ShopBalance.StarterPackForRebirths(profile.Data.Rebirths)
	if not (activePack and activePack.PackId == pack.PackId) then
		sendPurchaseResult(player, requestId, false, "inactive-pack")
		return
	end
	if starterPackOwned(profile, pack.PackId) then
		sendPurchaseResult(player, requestId, false, "already-owned")
		return
	end

	local key = userKey(player)
	if not key then
		sendPurchaseResult(player, requestId, false, "invalid-player")
		return
	end
	local now = os.clock()
	if lastRequest[key] and now - lastRequest[key] < REQUEST_RATE_SECONDS then
		sendPurchaseResult(player, requestId, false, "rate-limited")
		return
	end
	lastRequest[key] = now
	if locks[key] then
		sendPurchaseResult(player, requestId, false, "busy")
		return
	end

	local slots = requiredSlots(pack)
	if Inventory.RemainingSlots(player) < slots then
		NotificationService.Error(player, string.format("Inventory full (%d max). Delete or use some items first", Inventory.MAX_ITEMS))
		sendPurchaseResult(player, requestId, false, "inventory-full", {
			requiredSlots = slots,
		})
		return
	end

	sendPurchaseResult(player, requestId, true, "ok", {
		productId = int(pack.DevProductId),
		packId = pack.PackId,
		requiredSlots = slots,
	})
end

function StarterPackShopService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local pack = ShopBalance.StarterPackForProductId(receiptInfo.ProductId)
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
	local prepared = nil
	local wasPurchases = copyBooleanMap(profile.Data.StarterPackPurchases)
	local wasLegacyPurchased = profile.Data.StarterPackPurchased == true
	local wasPurchased = starterPackOwned(profile, pack.PackId)

	local ok, err = pcall(function()
		if wasPurchased then
			resultCode = "save-failed"
			ReceiptService.MarkProcessed(profile, purchaseId)
			if saveProfile(profile) then
				resultCode = "already-owned"
			else
				ReceiptService.ClearProcessed(profile, purchaseId)
			end
			return
		end

		resultCode = "inventory-full"
		if Inventory.RemainingSlots(player) < requiredSlots(pack) then
			return
		end

		prepared, resultCode = prepareRewards(pack)
		if not prepared then
			return
		end

		granted, resultCode = grantPrepared(player, profile, prepared)
		if not granted then
			prepared = nil
			return
		end

		resultCode = "save-failed"
		markStarterPackOwned(profile, pack.PackId)
		ReceiptService.MarkProcessed(profile, purchaseId)
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			profile.Data.StarterPackPurchases = copyBooleanMap(wasPurchases)
			profile.Data.StarterPackPurchased = wasLegacyPurchased
			rollbackPrepared(player, profile, prepared)
			granted = false
			return
		end
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		warn("[StarterPackShopService] Receipt grant failed: " .. tostring(err))
		ReceiptService.ClearProcessed(profile, purchaseId)
		profile.Data.StarterPackPurchases = copyBooleanMap(wasPurchases)
		profile.Data.StarterPackPurchased = wasLegacyPurchased
		if granted and prepared then
			rollbackPrepared(player, profile, prepared)
			granted = false
		elseif prepared then
			destroyPrepared(prepared)
		end
		resultCode = "server-error"
	end

	PlayerReplicaService.PublishInventories(player, profile)
	CurrencyService.Publish(player, profile)
	PlayerReplicaService.PublishStarterPackPurchased(player, profile)

	if granted then
		NotificationService.Success(player, string.format("Purchased %s!", pack.DisplayName or "Starter Pack"))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if resultCode == "already-owned" then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if resultCode == "inventory-full" then
		-- ToolGrantService emits a rate-limited notification if the cap is hit
		-- during grant; preflight also notifies before opening the purchase UI.
	elseif resultCode == "no-backpack" then
		NotificationService.Error(player, "Could not grant your starter pack yet. Please rejoin and try again")
	else
		NotificationService.Error(player, "Could not grant your starter pack yet")
	end
	warn("[StarterPackShopService] Receipt grant failed: " .. tostring(resultCode))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function StarterPackShopService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Players.PlayerRemoving, "StarterPackShopService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequest[key] = nil
		end
	end)
	RuntimeGuard.Connect(purchaseRequestRemote.OnServerEvent, "StarterPackShopService.PurchaseRequest", onPurchaseRequest)
end

return StarterPackShopService
