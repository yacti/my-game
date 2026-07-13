local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local FeedGrowthService = require(Server:WaitForChild("FeedGrowthService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MailboxConfig = require(Shared:WaitForChild("MailboxConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local GrowSkipService = {}

local APPLE_TREE_SEED_ID = "AppleTreeSeed"
local SAPLING_RESERVATION_KIND = "SaplingMature"
local PLOT_TIME_RESERVATION_KIND = "PlotTime"
local TARGETED_SAPLING_SKIP_ID = "TargetedSapling"
local REQUEST_RATE_SECONDS = 0.5
local RESERVATION_SECONDS = 5 * 60
-- Client shows the sapling prompt at 10 studs (GrowSkipController.PROMPT_DISTANCE);
-- validate with slack for movement/latency, like the other 10-stud prompts.
local SAPLING_SKIP_DISTANCE = 14
local MAILBOX_SKIP_DISTANCE = MailboxConfig.InteractionDistance
local SKIP_SIGN_DISTANCE = MailboxConfig.SkipTimeSignInteractionDistance
local EDIT_MODE_ATTR = "EditMode"
local SIGNS_FOLDER_NAME = MailboxConfig.SignsFolderName
local MAILBOX_NAME = MailboxConfig.MailboxName
local SKIP_SIGN_NAME = MailboxConfig.SkipTimeSignName

local started = false
local snapshotProfileState = nil
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

local function saplingProductId()
	local config = ShopBalance.GetGrowSkip()
	return int(config and config.DevProductId, 0)
end

local function productConfig(productIdValue)
	return ShopBalance.GrowSkipForProductId(productIdValue)
end

local function skipConfig(skipId)
	return ShopBalance.GrowSkipForSkipId(skipId)
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

local function pendingReservation(profile, expectedProductId)
	local reservation = profile and profile.Data and profile.Data.PendingGrowSkipReservation
	if type(reservation) ~= "table" then
		return nil
	end
	local reservationProductId = int(reservation.productId, 0)
	if expectedProductId ~= nil and reservationProductId ~= int(expectedProductId, 0) then
		return nil
	end
	if not productConfig(reservationProductId) then
		return nil
	end
	return reservation
end

local function reservationExpired(reservation)
	return int(reservation and reservation.expiresAt, 0) < now()
end

local function clearExpiredReservation(profile)
	local reservation = pendingReservation(profile)
	if not reservation then
		return true
	end
	if not reservationExpired(reservation) then
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

local function isPlayerNearInstance(player, target, maxDistance)
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = root and root:IsA("BasePart") and instancePosition(target) or nil
	return position ~= nil and (root.Position - position).Magnitude <= maxDistance
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

-- The plot-time skip can be bought from either station: the Mailbox (HUD
-- buttons) or the SkipTimeSign (SurfaceGui hitboxes). Returns the matched
-- station plus its interaction distance.
local function skipStationForTarget(plot, target)
	if not (plot and target and target:IsDescendantOf(plot)) then
		return nil, nil
	end
	local signs = plot:FindFirstChild(SIGNS_FOLDER_NAME)
	local mailbox = signs and signs:FindFirstChild(MAILBOX_NAME)
	if mailbox and (target == mailbox or target:IsDescendantOf(mailbox)) then
		return mailbox, MAILBOX_SKIP_DISTANCE
	end
	local skipSign = signs and signs:FindFirstChild(SKIP_SIGN_NAME)
	if skipSign and (target == skipSign or target:IsDescendantOf(skipSign)) then
		return skipSign, SKIP_SIGN_DISTANCE
	end
	return nil, nil
end

local function isMaturePatch(feed)
	return feed ~= nil
		and feed:GetAttribute(State.Feed.Class) == "Patch"
		and FeedGrowthService.IsGrowing(feed) ~= true
end

local function hasMaturePatchGrowth(plot)
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		if isMaturePatch(feed) and FeedMachines.HasGrowthCreditTarget(feed) then
			return true
		end
	end
	return false
end

local function hasEligiblePlotGrowth(player, plot)
	return FeedGrowthService.HasOwnedGrowth(player, plot) or hasMaturePatchGrowth(plot)
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

local function normalizeSaplingReservation(feedIndex, seedId)
	local createdAt = now()
	return {
		kind = SAPLING_RESERVATION_KIND,
		reservationId = HttpService:GenerateGUID(false),
		productId = saplingProductId(),
		feedIndex = feedIndex,
		seedId = seedId,
		createdAt = createdAt,
		expiresAt = createdAt + RESERVATION_SECONDS,
	}
end

local function normalizePlotTimeReservation(config)
	local createdAt = now()
	return {
		kind = PLOT_TIME_RESERVATION_KIND,
		reservationId = HttpService:GenerateGUID(false),
		productId = int(config and config.DevProductId, 0),
		skipId = config and config.SkipId or nil,
		durationSeconds = int(config and config.DurationSeconds, 0),
		createdAt = createdAt,
		expiresAt = createdAt + RESERVATION_SECONDS,
	}
end

local function reserveSaplingSkip(player, plot, profile, target)
	local _, info, feedIndex, resolveCode = resolveSkippableSapling(player, plot, target)
	if resolveCode ~= "ok" then
		return nil, false, resolveCode
	end
	local reservation = normalizeSaplingReservation(feedIndex, info.seedId)
	profile.Data.PendingGrowSkipReservation = reservation
	if not saveProfile(profile) then
		clearReservation(profile)
		return nil, false, "save-failed"
	end
	return reservation, true, "ok"
end

local function reservePlotTimeSkip(player, plot, profile, target, skipId)
	local config = skipConfig(skipId)
	if not config or int(config.DevProductId, 0) <= 0 or int(config.DurationSeconds, 0) <= 0 then
		return nil, false, "invalid-product"
	end
	local station, stationDistance = skipStationForTarget(plot, target)
	if not station then
		return nil, false, "invalid-target"
	end
	if not isPlayerNearInstance(player, station, stationDistance) then
		return nil, false, "too-far"
	end
	if player:GetAttribute(EDIT_MODE_ATTR) == true then
		return nil, false, "edit-mode"
	end
	if not hasEligiblePlotGrowth(player, plot) then
		return nil, false, "no-growth"
	end

	local reservation = normalizePlotTimeReservation(config)
	profile.Data.PendingGrowSkipReservation = reservation
	if not saveProfile(profile) then
		clearReservation(profile)
		return nil, false, "save-failed"
	end
	return reservation, true, "ok"
end

local function onSkipRequest(player, requestId, target, skipId)
	if type(requestId) ~= "number" then
		return
	end
	if typeof(target) ~= "Instance" then
		sendResult(player, requestId, false, "invalid-target")
		return
	end
	local isPlotTimeRequest = type(skipId) == "string" and skipId ~= ""
	local requestedConfig = isPlotTimeRequest and skipConfig(skipId) or ShopBalance.GrowSkipForProductId(saplingProductId())
	local configProductId = int(requestedConfig and requestedConfig.DevProductId, 0)
	local profile = PlayerDataService.GetProfile(player)
	local plot = PlotService.GetPlayerPlot(player)
	if configProductId <= 0 then
		sendResult(player, requestId, false, "invalid-product")
		return
	end
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
	if not isPlotTimeRequest and not isPlayerNearInstance(player, target, SAPLING_SKIP_DISTANCE) then
		sendResult(player, requestId, false, "too-far")
		return
	end
	if pendingReservation(profile) and not clearExpiredReservation(profile) then
		sendResult(player, requestId, false, "pending-purchase")
		return
	end

	locks[key] = true
	local reservation = nil
	local resultCode = "server-error"
	local ok, err = pcall(function()
		local saved = false
		if isPlotTimeRequest then
			reservation, saved, resultCode = reservePlotTimeSkip(player, plot, profile, target, skipId)
		else
			reservation, saved, resultCode = reserveSaplingSkip(player, plot, profile, target)
		end
		if not saved then
			reservation = nil
		end
	end)
	locks[key] = nil

	if not ok then
		clearReservation(profile)
		warn("[GrowSkipService] Reservation failed: " .. tostring(err))
		sendResult(player, requestId, false, "server-error")
		return
	end
	if not reservation then
		sendResult(player, requestId, false, resultCode)
		return
	end

	sendResult(player, requestId, true, "ok", {
		productId = configProductId,
		reservationId = reservation.reservationId,
		expiresAt = reservation.expiresAt,
		skipId = isPlotTimeRequest and skipId or nil,
	})
end

local function snapshotIfPossible(player, plot, profile)
	if type(snapshotProfileState) ~= "function" then
		return true
	end
	return snapshotProfileState(player, plot, profile) == true
end

local function finishNoOp(profile, purchaseId, player, plot)
	clearReservation(profile)
	ReceiptService.MarkProcessed(profile, purchaseId)
	if player and plot and not snapshotIfPossible(player, plot, profile) then
		ReceiptService.ClearProcessed(profile, purchaseId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if saveProfile(profile) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	ReceiptService.ClearProcessed(profile, purchaseId)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function cancelReservation(player, productIdValue)
	local profile = PlayerDataService.GetProfile(player)
	if not pendingReservation(profile, productIdValue) then
		return
	end
	clearReservation(profile)
	saveProfile(profile)
end

local function creditMaturePatches(plot, seconds)
	local creditedSlots = 0
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		if isMaturePatch(feed) and FeedMachines.HasGrowthCreditTarget(feed) then
			local ok, result = FeedMachines.CreditGrowthSeconds(feed, seconds)
			if ok and type(result) == "table" then
				creditedSlots += int(result.changedSlots, 0)
			end
		end
	end
	return creditedSlots
end

local function applyPlotTimeSkip(player, plot, seconds)
	seconds = int(seconds, 0)
	if seconds <= 0 then
		return nil, "invalid-duration"
	end
	if player:GetAttribute(EDIT_MODE_ATTR) == true then
		return nil, "edit-mode"
	end
	if not hasEligiblePlotGrowth(player, plot) then
		return nil, "no-growth"
	end

	local creditedSlots = creditMaturePatches(plot, seconds)
	local seedResult = FeedGrowthService.AdvanceOwnedGrowth(player, plot, seconds)
	local advanced = int(seedResult and seedResult.advanced, 0)
	local matured = int(seedResult and seedResult.matured, 0)
	local leftoverPatchCreditSlots = int(seedResult and seedResult.patchCreditSlots, 0)
	if creditedSlots + advanced + matured + leftoverPatchCreditSlots <= 0 then
		return nil, "no-growth"
	end

	return {
		creditedSlots = creditedSlots + leftoverPatchCreditSlots,
		advanced = advanced,
		matured = matured,
	}, "ok"
end

local function commitPlotTimeReservation(player, plot, profile, reservation, purchaseId)
	if type(reservation) ~= "table" then
		return false, "missing-reservation"
	end
	if reservation.sourceCommitted == true then
		local appliedPurchaseId = reservation.appliedPurchaseId
		if type(appliedPurchaseId) == "string" and appliedPurchaseId ~= "" and appliedPurchaseId ~= purchaseId then
			return false, "receipt-mismatch"
		end
		if type(appliedPurchaseId) ~= "string" or appliedPurchaseId == "" then
			reservation.appliedPurchaseId = purchaseId
			profile.Data.PendingGrowSkipReservation = reservation
			if not saveProfile(profile) then
				return false, "source-commit-save-failed"
			end
		end
		return true, "ok"
	end

	local _, applyCode = applyPlotTimeSkip(player, plot, int(reservation.durationSeconds, 0))
	if applyCode ~= "ok" then
		return false, applyCode
	end

	reservation.sourceCommitted = true
	reservation.appliedPurchaseId = purchaseId
	profile.Data.PendingGrowSkipReservation = reservation
	if not snapshotIfPossible(player, plot, profile) then
		return false, "source-commit-snapshot-failed"
	end
	if not saveProfile(profile) then
		return false, "source-commit-save-failed"
	end
	return true, "ok"
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
	local plot = nil
	local reservation = pendingReservation(profile, receiptInfo.ProductId)
	local ok, err = pcall(function()
		plot = PlotService.GetPlayerPlot(player)
		if not plot then
			resultCode = "missing-plot"
			return
		end
		if not reservation then
			noOp = true
			resultCode = "missing-reservation"
			return
		end
		if reservationExpired(reservation) then
			noOp = true
			resultCode = "reservation-expired"
			return
		end

		local reservationKind = reservation.kind
		if reservationKind == nil then
			reservationKind = SAPLING_RESERVATION_KIND
		end
		if reservationKind == PLOT_TIME_RESERVATION_KIND then
			if config.SkipId ~= reservation.skipId or int(config.DurationSeconds, 0) ~= int(reservation.durationSeconds, 0) then
				noOp = true
				resultCode = "target-changed"
				return
			end
			local committed, commitCode = commitPlotTimeReservation(player, plot, profile, reservation, purchaseId)
			if not committed then
				if commitCode == "no-growth" then
					noOp = true
				end
				resultCode = commitCode
				return
			end
		else
			if config.SkipId ~= TARGETED_SAPLING_SKIP_ID then
				noOp = true
				resultCode = "target-changed"
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
		end
		clearReservation(profile)
		ReceiptService.MarkProcessed(profile, purchaseId)
		resultCode = "snapshot-failed"
		if not snapshotIfPossible(player, plot, profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			return
		end
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
		if reservation and reservation.kind == PLOT_TIME_RESERVATION_KIND then
			NotificationService.Success(player, string.format("%s applied to your plot!", config.DisplayName or "Growth skip"))
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if noOp then
		if resultCode == "reservation-expired" then
			NotificationService.Error(player, "That skip purchase expired before it could be applied")
		elseif (reservation and reservation.kind == PLOT_TIME_RESERVATION_KIND) or (config and config.SkipId ~= TARGETED_SAPLING_SKIP_ID) then
			warn("[GrowSkipService] Plot time skip no-op: " .. tostring(resultCode))
		else
			NotificationService.Error(player, "Could not find that growing tree to skip")
		end
		return finishNoOp(profile, purchaseId, player, plot)
	end

	warn("[GrowSkipService] Receipt grant failed: " .. tostring(resultCode))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function GrowSkipService.Start(config)
	if started then
		return
	end
	started = true
	config = type(config) == "table" and config or nil
	snapshotProfileState = config and config.snapshotProfileState or nil

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
		if player and productConfig(finishedProductId) and wasPurchased ~= true then
			cancelReservation(player, finishedProductId)
		end
	end)
end

return GrowSkipService
