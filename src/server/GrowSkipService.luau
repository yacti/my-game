local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedGrowthService = require(Server:WaitForChild("FeedGrowthService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local GrowSkipService = {}

local APPLE_TREE_SEED_ID = "AppleTreeSeed"
local REQUEST_RATE_SECONDS = 0.5
local RESERVATION_SECONDS = 5 * 60
local SKIP_DISTANCE = 10

local started = false
local locks = {}
local lastRequest = {}

local requestRemote = Remotes.get(Remotes.Names.GrowSkipRequest)
local resultRemote = Remotes.get(Remotes.Names.GrowSkipResult)

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function userKey(player)
	return player and player.UserId or nil
end

local function now()
	return os.time()
end

local function productId()
	local config = ShopBalance.GetGrowSkip()
	return int(config and config.DevProductId, 0)
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

local function sendResult(player, requestId, success, code, payload)
	local result = type(payload) == "table" and payload or {}
	result.requestId = requestId
	result.success = success == true
	result.code = code
	resultRemote:FireClient(player, result)
end

local function clearReservation(profile)
	if profile and profile.Data then
		profile.Data.PendingGrowSkipReservation = nil
	end
end

local function pendingReservation(profile)
	local reservation = profile and profile.Data and profile.Data.PendingGrowSkipReservation
	if type(reservation) ~= "table" then
		return nil
	end
	if int(reservation.productId, 0) ~= productId() then
		return nil
	end
	return reservation
end

local function clearExpiredReservation(profile)
	local reservation = pendingReservation(profile)
	if not reservation then
		return true
	end
	if int(reservation.expiresAt, 0) >= now() then
		return false
	end
	clearReservation(profile)
	return saveProfile(profile)
end

local function instancePosition(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local cframe = instance:GetBoundingBox()
		return cframe.Position
	end
	local part = instance:FindFirstChildWhichIsA("BasePart", true)
	return part and part.Position or nil
end

local function isPlayerNearInstance(player, target)
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = root and root:IsA("BasePart") and instancePosition(target) or nil
	return position ~= nil and (root.Position - position).Magnitude <= SKIP_DISTANCE
end

local function feedRootForTarget(plot, target)
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		if feed == target or target:IsDescendantOf(feed) then
			return feed
		end
	end
	return nil
end

local function feedByIndex(plot, feedIndex)
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		if int(feed:GetAttribute(State.Feed.Index), 0) == feedIndex then
			return feed
		end
	end
	return nil
end

local function resolveSkippableSapling(player, plot, target)
	if not (plot and target and target:IsDescendantOf(plot)) then
		return nil, nil, nil, "invalid-target"
	end
	local feed = feedRootForTarget(plot, target)
	if not feed then
		return nil, nil, nil, "invalid-target"
	end
	local info = FeedGrowthService.GetGrowingInfo(feed)
	if not info then
		return nil, nil, nil, "not-growing"
	end
	if info.offlineProgressPending == true then
		return nil, nil, nil, "offline-progress"
	end
	if info.owner ~= nil and info.owner ~= player then
		return nil, nil, nil, "not-owner"
	end
	if info.feedClass ~= "Tree" then
		return nil, nil, nil, "not-tree"
	end
	if info.seedId == APPLE_TREE_SEED_ID then
		return nil, nil, nil, "apple-disabled"
	end
	local feedIndex = int(feed:GetAttribute(State.Feed.Index), 0)
	if feedIndex <= 0 then
		return nil, nil, nil, "invalid-index"
	end
	return feed, info, feedIndex, "ok"
end

local function normalizeReservation(feedIndex, seedId)
	local createdAt = now()
	return {
		reservationId = HttpService:GenerateGUID(false),
		productId = productId(),
		feedIndex = feedIndex,
		seedId = seedId,
		createdAt = createdAt,
		expiresAt = createdAt + RESERVATION_SECONDS,
	}
end

local function onSkipRequest(player, requestId, target)
	if type(requestId) ~= "number" then
		return
	end
	if typeof(target) ~= "Instance" then
		sendResult(player, requestId, false, "invalid-target")
		return
	end
	local configProductId = productId()
	if configProductId <= 0 then
		sendResult(player, requestId, false, "invalid-product")
		return
	end
	local profile = PlayerDataService.GetProfile(player)
	local plot = PlotService.GetPlayerPlot(player)
	if not (profile and plot) then
		sendResult(player, requestId, false, "profile-not-ready")
		return
	end
	if OfflineProgressService.IsPending(player) then
		sendResult(player, requestId, false, "offline-progress")
		return
	end
	local key = userKey(player)
	if not key then
		sendResult(player, requestId, false, "invalid-player")
		return
	end
	local clock = os.clock()
	if lastRequest[key] and clock - lastRequest[key] < REQUEST_RATE_SECONDS then
		sendResult(player, requestId, false, "rate-limited")
		return
	end
	lastRequest[key] = clock
	if locks[key] then
		sendResult(player, requestId, false, "busy")
		return
	end
	if not isPlayerNearInstance(player, target) then
		sendResult(player, requestId, false, "too-far")
		return
	end
	if pendingReservation(profile) and not clearExpiredReservation(profile) then
		sendResult(player, requestId, false, "pending-purchase")
		return
	end

	locks[key] = true
	local saved = false
	local reservation = nil
	local resultCode = "server-error"
	local ok, err = pcall(function()
		local _, info, feedIndex, resolveCode = resolveSkippableSapling(player, plot, target)
		if resolveCode ~= "ok" then
			resultCode = resolveCode
			return
		end
		reservation = normalizeReservation(feedIndex, info.seedId)
		profile.Data.PendingGrowSkipReservation = reservation
		saved = saveProfile(profile)
		if not saved then
			clearReservation(profile)
			resultCode = "save-failed"
			return
		end
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		clearReservation(profile)
		warn("[GrowSkipService] Reservation failed: " .. tostring(err))
		sendResult(player, requestId, false, "server-error")
		return
	end
	if not (saved and reservation) then
		sendResult(player, requestId, false, resultCode)
		return
	end

	sendResult(player, requestId, true, "ok", {
		productId = configProductId,
		reservationId = reservation.reservationId,
		expiresAt = reservation.expiresAt,
	})
end

local function finishNoOp(profile, purchaseId)
	clearReservation(profile)
	ReceiptService.MarkProcessed(profile, purchaseId)
	if saveProfile(profile) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	ReceiptService.ClearProcessed(profile, purchaseId)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function cancelReservation(player)
	local profile = PlayerDataService.GetProfile(player)
	if not pendingReservation(profile) then
		return
	end
	clearReservation(profile)
	saveProfile(profile)
end

function GrowSkipService.HandlesProductId(productIdValue)
	return ShopBalance.GrowSkipForProductId(productIdValue) ~= nil
end

function GrowSkipService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local config = ShopBalance.GrowSkipForProductId(receiptInfo.ProductId)
	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not (player and profile and config and purchaseId) then
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
	local noOp = false
	local resultCode = "server-error"
	local reservation = pendingReservation(profile)
	local ok, err = pcall(function()
		if not reservation then
			noOp = true
			resultCode = "missing-reservation"
			return
		end
		local plot = PlotService.GetPlayerPlot(player)
		if not plot then
			resultCode = "missing-plot"
			return
		end
		local feed = feedByIndex(plot, int(reservation.feedIndex, 0))
		if not feed then
			noOp = true
			resultCode = "missing-feed"
			return
		end
		local info = FeedGrowthService.GetGrowingInfo(feed)
		if not info then
			noOp = true
			resultCode = "not-growing"
			return
		end
		if info.offlineProgressPending == true then
			resultCode = "offline-progress"
			return
		end
		if info.seedId ~= reservation.seedId or info.feedClass ~= "Tree" or info.seedId == APPLE_TREE_SEED_ID then
			noOp = true
			resultCode = "target-changed"
			return
		end
		if info.owner ~= nil and info.owner ~= player then
			noOp = true
			resultCode = "not-owner"
			return
		end

		resultCode = "mature-failed"
		local mature = FeedGrowthService.ForceMature(feed)
		if not mature then
			return
		end
		clearReservation(profile)
		ReceiptService.MarkProcessed(profile, purchaseId)
		resultCode = "save-failed"
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			return
		end
		granted = true
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		ReceiptService.ClearProcessed(profile, purchaseId)
		warn("[GrowSkipService] Receipt failed: " .. tostring(err))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if granted then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if noOp then
		NotificationService.Error(player, "Could not find that growing tree to skip.")
		return finishNoOp(profile, purchaseId)
	end

	warn("[GrowSkipService] Receipt grant failed: " .. tostring(resultCode))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function GrowSkipService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "GrowSkipService.Request", onSkipRequest)
	RuntimeGuard.Connect(Players.PlayerRemoving, "GrowSkipService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequest[key] = nil
		end
	end)
	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "GrowSkipService.PromptFinished", function(playerOrUserId, finishedProductId, wasPurchased)
		local userId = typeof(playerOrUserId) == "Instance" and playerOrUserId.UserId or playerOrUserId
		local player = Players:GetPlayerByUserId(userId)
		if player and int(finishedProductId, 0) == productId() and wasPurchased ~= true then
			cancelReservation(player)
		end
	end)
end

return GrowSkipService
