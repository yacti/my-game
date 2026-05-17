local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local FeedRewardService = require(Server:WaitForChild("FeedRewardService"))
local MarketOfferStore = require(Server:WaitForChild("MarketOfferStore"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local RebirthService = require(Server:WaitForChild("RebirthService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MarketCatalog = require(Shared:WaitForChild("MarketCatalog"))
local MarketProducts = require(Shared:WaitForChild("MarketProducts"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local MarketService = {}

local PURCHASE_RATE_SECONDS = 0.25
local STATE_RATE_SECONDS = 0.5
local RESTOCK_RATE_SECONDS = 1
local MARKET_DISTANCE = 20

local started = false
local purchaseLocks = {}
local purchaseLastFire = {}
local stateLastFire = {}
local restockLastFire = {}
local nextPurchaseId = 0

local MarketStateUpdated = Remotes.get(Remotes.Names.MarketStateUpdated)
local MarketPurchaseResult = Remotes.get(Remotes.Names.MarketPurchaseResult)
local MarketRestockResult = Remotes.get(Remotes.Names.MarketRestockResult)

local function consumeRateLimit(map, player, interval)
	local now = os.clock()
	local previous = map[player] or 0
	if now - previous < interval then
		return false
	end
	map[player] = now
	return true
end

local function primaryPartOf(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart
	end
	return nil
end

local function isPlayerNearMarket(player)
	local marketPart = Workspace:FindFirstChild("MarketPart")
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local primary = primaryPartOf(marketPart)
	return root ~= nil
		and root:IsA("BasePart")
		and primary ~= nil
		and (root.Position - primary.Position).Magnitude <= MARKET_DISTANCE
end

local function ensureMarketPurchases(profile, cycleId)
	local purchases = profile.Data.MarketPurchases
	if type(purchases) ~= "table" or purchases.cycleId ~= cycleId then
		purchases = {
			cycleId = cycleId,
			counts = {},
		}
		profile.Data.MarketPurchases = purchases
	elseif type(purchases.counts) ~= "table" then
		purchases.counts = {}
	end
	return purchases
end

local function getConsumedCount(player, profile, offer, offerScope, feedType)
	if offerScope == "server" then
		return MarketOfferStore.GetOverridePurchaseCount(player.UserId, offer.offerId, feedType)
	end
	local purchases = ensureMarketPurchases(profile, offer.cycleId)
	return purchases.counts[feedType] or 0
end

local function addConsumedCount(player, profile, offer, offerScope, feedType, amount)
	amount = amount or 1
	if offerScope == "server" then
		MarketOfferStore.AddOverridePurchase(player.UserId, offer.offerId, feedType, amount)
		return
	end
	local purchases = ensureMarketPurchases(profile, offer.cycleId)
	purchases.counts[feedType] = (purchases.counts[feedType] or 0) + amount
end

local function buildRemainingCounts(player, profile, offer, offerScope)
	local remaining = {}
	for feedType, allowance in pairs(offer.items or {}) do
		local consumed = profile and getConsumedCount(player, profile, offer, offerScope, feedType) or 0
		remaining[feedType] = math.max((tonumber(allowance) or 0) - consumed, 0)
	end
	return remaining
end

local function buildStatePayload(player)
	local profile = PlayerDataService.GetProfile(player)

	local offer, offerScope = MarketOfferStore.GetActiveOffer()
	if not offer then
		return nil
	end

	local catalog = MarketCatalog.GetCatalog()
	return {
		serverTime = os.time(),
		offerScope = offerScope,
		offerId = offer.offerId or tostring(offer.cycleId),
		cycleId = offer.cycleId,
		cycleStart = offer.cycleStart,
		cycleEnd = offer.cycleEnd,
		catalog = MarketCatalog.ToClientCatalog(catalog),
		remaining = buildRemainingCounts(player, profile, offer, offerScope),
		currency = profile and (profile.Data.Currency or 0) or 0,
		profileReady = profile ~= nil,
	}
end

local function sendState(player)
	local payload = buildStatePayload(player)
	if payload then
		MarketStateUpdated:FireClient(player, payload)
	end
end

function MarketService.SendState(player)
	sendState(player)
end

local function sendPurchaseResult(player, requestId, success, code, feedType, extra)
	local payload = extra or {}
	payload.requestId = requestId
	payload.success = success
	payload.code = code
	payload.feedType = feedType
	MarketPurchaseResult:FireClient(player, payload)
end

local function ensureMarketReceipts(profile)
	local receipts = profile.Data.MarketReceipts
	if type(receipts) ~= "table" then
		receipts = {}
		profile.Data.MarketReceipts = receipts
	end
	return receipts
end

local function receiptKey(purchaseId)
	if purchaseId == nil then
		return nil
	end
	return tostring(purchaseId)
end

local function hasProcessedReceipt(profile, purchaseId)
	purchaseId = receiptKey(purchaseId)
	if not purchaseId then
		return false
	end
	local receipts = ensureMarketReceipts(profile)
	return receipts[purchaseId] == true
end

local function markProcessedReceipt(profile, purchaseId)
	purchaseId = receiptKey(purchaseId)
	if not purchaseId then
		return
	end
	local receipts = ensureMarketReceipts(profile)
	receipts[purchaseId] = true
end

local function currentAllowance(offer, feedType)
	local allowance = offer.items and offer.items[feedType]
	if type(allowance) ~= "number" then
		return 0
	end
	return math.max(math.floor(allowance), 0)
end

local function purchase(player, requestId, feedType)
	if type(feedType) ~= "string" or feedType == "" then
		sendPurchaseResult(player, requestId, false, "invalid-item", feedType)
		return
	end
	if not consumeRateLimit(purchaseLastFire, player, PURCHASE_RATE_SECONDS) then
		sendPurchaseResult(player, requestId, false, "rate-limited", feedType)
		return
	end
	if purchaseLocks[player] then
		sendPurchaseResult(player, requestId, false, "busy", feedType)
		return
	end

	local catalogByFeedType = MarketCatalog.GetByFeedType()
	local item = catalogByFeedType[feedType]
	if not item then
		sendPurchaseResult(player, requestId, false, "invalid-item", feedType)
		return
	end

	purchaseLocks[player] = true
	nextPurchaseId += 1
	local purchaseId = nextPurchaseId

	local ok, err = pcall(function()
		local profile = PlayerDataService.GetProfile(player)
		if not profile then
			sendPurchaseResult(player, requestId, false, "no-profile", feedType)
			return
		end
		if not isPlayerNearMarket(player) then
			sendPurchaseResult(player, requestId, false, "too-far", feedType)
			return
		end

		local offer, offerScope = MarketOfferStore.GetActiveOffer()
		if not offer then
			sendPurchaseResult(player, requestId, false, "no-offer", feedType)
			return
		end

		local allowance = currentAllowance(offer, feedType)
		local consumed = getConsumedCount(player, profile, offer, offerScope, feedType)
		local remaining = math.max(allowance - consumed, 0)
		if remaining <= 0 then
			sendPurchaseResult(player, requestId, false, "sold-out-for-player", feedType, {
				remaining = 0,
			})
			return
		end

		local spent, spendCode, currency = CurrencyService.TrySpend(player, profile, item.price)
		if not spent then
			sendPurchaseResult(player, requestId, false, spendCode or "insufficient-currency", feedType, {
				remaining = remaining,
				currency = currency,
			})
			return
		end

		if not FeedRewardService.Grant(player, profile, feedType, 1) then
			CurrencyService.Add(player, profile, item.price)
			sendPurchaseResult(player, requestId, false, "grant-failed", feedType)
			return
		end

		addConsumedCount(player, profile, offer, offerScope, feedType, 1)

		local newRemaining = remaining - 1
		sendPurchaseResult(player, requestId, true, "ok", feedType, {
			purchaseId = purchaseId,
			remaining = newRemaining,
			currency = profile.Data.Currency,
		})
		NotificationService.Success(player, string.format("Purchased %s!", item.displayName))
		sendState(player)
	end)

	purchaseLocks[player] = nil
	if not ok then
		warn("[MarketService] Purchase failed: " .. tostring(err))
		sendPurchaseResult(player, requestId, false, "server-error", feedType, {
			purchaseId = purchaseId,
		})
	end
end

function MarketService.ApplyServerRestock(receiptId)
	local offer = MarketOfferStore.ApplyServerOverride(receiptId)
	for _, player in ipairs(Players:GetPlayers()) do
		sendState(player)
	end
	return offer
end

local function processFeedProduct(receiptInfo, player, feedType)
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local purchaseId = receiptKey(receiptInfo.PurchaseId)
	if not purchaseId then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if hasProcessedReceipt(profile, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if not MarketCatalog.GetByFeedType()[feedType] then
		warn(string.format("[MarketService] Product %s maps to unknown feedType %s", tostring(receiptInfo.ProductId), tostring(feedType)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local preparedGrant = nil
	preparedGrant = FeedRewardService.PrepareGrant(feedType, 1)
	if not preparedGrant then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local granted = FeedRewardService.ApplyPrepared(player, profile, preparedGrant)
	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	markProcessedReceipt(profile, purchaseId)
	profile:Save()
	NotificationService.Success(player, "Purchased " .. feedType .. "!")
	sendState(player)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processRestockProduct(receiptInfo, player)
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local purchaseId = receiptKey(receiptInfo.PurchaseId)
	if not purchaseId then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if hasProcessedReceipt(profile, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	MarketService.ApplyServerRestock(purchaseId)
	markProcessedReceipt(profile, purchaseId)
	profile:Save()
	NotificationService.Success(player, "Server shop restocked!")
	MarketRestockResult:FireClient(player, {
		success = true,
		code = "ok",
	})
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if receiptInfo.ProductId == MarketProducts.RestockProductId then
		return processRestockProduct(receiptInfo, player)
	end

	if MarketProducts.RebirthTierForProductId(receiptInfo.ProductId) then
		return RebirthService.ProcessSkipReceipt(receiptInfo, player)
	end

	local feedType = MarketProducts.FeedTypeForProductId(receiptInfo.ProductId)
	if feedType then
		return processFeedProduct(receiptInfo, player, feedType)
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function MarketService.Start()
	if started then
		return
	end
	started = true

	MarketOfferStore.Start()
	MarketplaceService.ProcessReceipt = processReceipt
	MarketOfferStore.OnUpdated(function()
		for _, player in ipairs(Players:GetPlayers()) do
			sendState(player)
		end
	end)

	Remotes.get(Remotes.Names.MarketStateRequest).OnServerEvent:Connect(function(player)
		if not consumeRateLimit(stateLastFire, player, STATE_RATE_SECONDS) then
			return
		end
		sendState(player)
	end)

	Remotes.get(Remotes.Names.MarketPurchaseRequest).OnServerEvent:Connect(function(player, requestId, feedType)
		if type(requestId) ~= "number" then
			return
		end
		purchase(player, requestId, feedType)
	end)

	Remotes.get(Remotes.Names.MarketRestockRequest).OnServerEvent:Connect(function(player, requestId)
		if not consumeRateLimit(restockLastFire, player, RESTOCK_RATE_SECONDS) then
			MarketRestockResult:FireClient(player, {
				requestId = requestId,
				success = false,
				code = "rate-limited",
			})
			return
		end
		MarketRestockResult:FireClient(player, {
			requestId = requestId,
			success = false,
			code = "product-unconfigured",
		})
	end)

	Players.PlayerRemoving:Connect(function(player)
		purchaseLocks[player] = nil
		purchaseLastFire[player] = nil
		stateLastFire[player] = nil
		restockLastFire[player] = nil
	end)
end

return MarketService
