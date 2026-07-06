local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local FoodInventoryService = require(Server:WaitForChild("FoodInventoryService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Inventory = require(Shared:WaitForChild("Inventory"))
local MailboxConfig = require(Shared:WaitForChild("MailboxConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local CollectAllService = {}

local REQUEST_RATE_SECONDS = 0.5
local RESERVATION_SECONDS = 5 * 60
local COLLECT_DISTANCE = MailboxConfig.InteractionDistance
local SIGNS_FOLDER_NAME = MailboxConfig.SignsFolderName
local MAILBOX_NAME = MailboxConfig.MailboxName
local EDIT_MODE_ATTR = "EditMode"

local started = false
local snapshotProfileState = nil
local locks = {}
local lastRequest = {}

local requestRemote = Remotes.get(Remotes.Names.CollectAllRequest)
local resultRemote = Remotes.get(Remotes.Names.CollectAllResult)

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

local function productConfig(productIdValue)
	return ShopBalance.CollectAllForProductId(productIdValue)
end

local function collectAllProductId()
	local config = ShopBalance.GetCollectAll()
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
	return position ~= nil and (root.Position - position).Magnitude <= COLLECT_DISTANCE
end

local function mailboxForTarget(plot, target)
	if not (plot and target and target:IsDescendantOf(plot)) then
		return nil
	end
	local signs = plot:FindFirstChild(SIGNS_FOLDER_NAME)
	local mailbox = signs and signs:FindFirstChild(MAILBOX_NAME)
	if mailbox and (target == mailbox or target:IsDescendantOf(mailbox)) then
		return mailbox
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

local function pendingReservation(profile, expectedProductId)
	local reservation = profile and profile.Data and profile.Data.PendingCollectAllReservation
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
	if type(reservation.items) ~= "table" then
		return nil
	end
	return reservation
end

local function reservationExpired(reservation)
	return int(reservation and reservation.expiresAt, 0) < now()
end

local function reservationPurchaseId(reservation)
	local purchaseId = reservation and reservation.appliedPurchaseId
	return type(purchaseId) == "string" and purchaseId ~= "" and purchaseId or nil
end

local function releaseReservationSources(plot, reservation, onlyUncommitted)
	if not (plot and type(reservation) == "table" and type(reservation.items) == "table") then
		return
	end
	local reservationId = reservation.reservationId
	if type(reservationId) ~= "string" or reservationId == "" then
		return
	end
	for _, item in ipairs(reservation.items) do
		if onlyUncommitted and (item.sourceCommitted == true or item.sourceUnavailable == true) then
			continue
		end
		local feed = feedByIndex(plot, int(item.sourceFeedIndex, 0))
		if feed then
			FeedMachines.ReleaseCollectAll(feed, item, reservationId)
		end
	end
end

local function clearReservation(profile, plot, options)
	options = type(options) == "table" and options or {}
	local reservation = pendingReservation(profile)
	if reservation and options.release ~= false then
		releaseReservationSources(plot, reservation, options.onlyUncommitted == true)
	end
	if profile and profile.Data then
		profile.Data.PendingCollectAllReservation = nil
	end
end

local function snapshotIfPossible(player, plot, profile)
	if type(snapshotProfileState) == "function" then
		return snapshotProfileState(player, plot, profile) == true
	end
	profile.Data.FoodInventoryItems = FoodInventoryService.SerializeTools(player)
	profile.Data.FoodInventory = FoodInventoryService.CountRecords(profile.Data.FoodInventoryItems)
	PlayerReplicaService.PublishFoodInventory(player, profile)
	return true
end

local function clearExpiredReservation(player, profile, plot)
	local reservation = pendingReservation(profile)
	if not reservation then
		return true
	end
	if not reservationExpired(reservation) then
		return false
	end
	clearReservation(profile, plot)
	if not snapshotIfPossible(player, plot, profile) then
		return false
	end
	return saveProfile(profile)
end

local function collectReservedItems(player, plot, reservation, limit)
	local selected = {}
	local changed = false
	local reservationId = reservation.reservationId
	for _, item in ipairs(reservation.items) do
		if #selected >= limit then
			break
		end
		if item.sourceUnavailable == true then
			continue
		end
		if item.sourceCommitted == true then
			selected[#selected + 1] = item
			continue
		end
		local feed = feedByIndex(plot, int(item.sourceFeedIndex, 0))
		local committed = feed and FeedMachines.CommitCollectAll(feed, item, reservationId)
		if committed then
			item.sourceCommitted = true
			changed = true
			selected[#selected + 1] = item
		else
			item.sourceUnavailable = true
			changed = true
		end
	end
	return selected, changed
end

local function grantItems(player, items)
	local grantedTools = {}
	for _, item in ipairs(items) do
		local tool = FoodInventoryService.MakeTool(item)
		if not tool then
			for _, granted in ipairs(grantedTools) do
				if granted.Parent then
					granted:Destroy()
				end
			end
			return nil, "tool-failed"
		end
		local granted, code = ToolGrantService.GrantTool(player, tool, {
			maxItems = Inventory.COLLECT_ALL_MAX_ITEMS,
			deferAutoEquip = true,
			autoEquipPolicy = "firstInBurst",
			autoEquipBurstGap = 3,
		})
		if not granted then
			tool:Destroy()
			for _, grantedTool in ipairs(grantedTools) do
				if grantedTool.Parent then
					grantedTool:Destroy()
				end
			end
			return nil, code or "grant-failed"
		end
		grantedTools[#grantedTools + 1] = tool
	end
	return grantedTools, "ok"
end

local function destroyTools(tools)
	for _, tool in ipairs(tools or {}) do
		if tool and tool.Parent then
			tool:Destroy()
		end
	end
end

local function reserveCollectAll(player, plot, profile, target)
	local config = ShopBalance.GetCollectAll()
	local productId = int(config and config.DevProductId, 0)
	if productId <= 0 then
		return nil, false, "invalid-product"
	end
	local mailbox = mailboxForTarget(plot, target)
	if not mailbox then
		return nil, false, "invalid-target"
	end
	if not isPlayerNearInstance(player, mailbox) then
		return nil, false, "too-far"
	end
	if player:GetAttribute(EDIT_MODE_ATTR) == true then
		return nil, false, "edit-mode"
	end

	local remainingSlots = Inventory.RemainingSlots(player, Inventory.COLLECT_ALL_MAX_ITEMS)
	if remainingSlots <= 0 then
		return nil, false, "inventory-full"
	end

	local createdAt = now()
	local reservation = {
		reservationId = HttpService:GenerateGUID(false),
		productId = productId,
		createdAt = createdAt,
		expiresAt = createdAt + RESERVATION_SECONDS,
		items = {},
	}

	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		local remaining = remainingSlots - #reservation.items
		if remaining <= 0 then
			break
		end
		local ok, result = FeedMachines.ReserveCollectAll(feed, player, reservation.reservationId, reservation.expiresAt, remaining)
		if ok and type(result) == "table" and type(result.items) == "table" then
			for _, item in ipairs(result.items) do
				reservation.items[#reservation.items + 1] = item
				if #reservation.items >= remainingSlots then
					break
				end
			end
		end
	end

	if #reservation.items == 0 then
		return nil, false, "no-food"
	end

	profile.Data.PendingCollectAllReservation = reservation
	if not snapshotIfPossible(player, plot, profile) then
		releaseReservationSources(plot, reservation)
		clearReservation(profile, plot, { release = false })
		snapshotIfPossible(player, plot, profile)
		return nil, false, "snapshot-failed"
	end
	if not saveProfile(profile) then
		releaseReservationSources(plot, reservation)
		clearReservation(profile, plot, { release = false })
		snapshotIfPossible(player, plot, profile)
		return nil, false, "save-failed"
	end
	return reservation, true, "ok"
end

local function onCollectAllRequest(player, requestId, target)
	if type(requestId) ~= "number" then
		return
	end
	if typeof(target) ~= "Instance" then
		sendResult(player, requestId, false, "invalid-target")
		return
	end

	local productId = collectAllProductId()
	local profile = PlayerDataService.GetProfile(player)
	local plot = PlotService.GetPlayerPlot(player)
	if productId <= 0 then
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
	if pendingReservation(profile) and not clearExpiredReservation(player, profile, plot) then
		sendResult(player, requestId, false, "pending-purchase")
		return
	end

	locks[key] = true
	local reservation = nil
	local resultCode = "server-error"
	local ok, err = pcall(function()
		local saved = false
		reservation, saved, resultCode = reserveCollectAll(player, plot, profile, target)
		if not saved then
			reservation = nil
		end
	end)
	locks[key] = nil

	if not ok then
		clearReservation(profile, plot)
		warn("[CollectAllService] Reservation failed: " .. tostring(err))
		sendResult(player, requestId, false, "server-error")
		return
	end
	if not reservation then
		sendResult(player, requestId, false, resultCode)
		return
	end

	sendResult(player, requestId, true, "ok", {
		productId = productId,
		reservationId = reservation.reservationId,
		expiresAt = reservation.expiresAt,
		availableCount = #reservation.items,
	})
end

local function finishNoOp(profile, purchaseId, player, plot, message)
	clearReservation(profile, plot)
	ReceiptService.MarkProcessed(profile, purchaseId)
	if not snapshotIfPossible(player, plot, profile) then
		ReceiptService.ClearProcessed(profile, purchaseId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if saveProfile(profile) then
		if message then
			NotificationService.Error(player, message)
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	ReceiptService.ClearProcessed(profile, purchaseId)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function cancelReservation(player)
	local profile = PlayerDataService.GetProfile(player)
	local plot = PlotService.GetPlayerPlot(player)
	if not pendingReservation(profile) then
		return
	end
	clearReservation(profile, plot)
	if snapshotIfPossible(player, plot, profile) then
		saveProfile(profile)
	end
end

function CollectAllService.HandlesProductId(productIdValue)
	return ShopBalance.CollectAllForProductId(productIdValue) ~= nil
end

function CollectAllService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local config = ShopBalance.CollectAllForProductId(receiptInfo.ProductId)
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
	-- Serializing the backpack while dead/mid-restore would persist the wiped
	-- backpack over the profile's inventory; retry once the restore completes.
	if player:GetAttribute(State.Player.InventoryRestorePending) == true then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local key = userKey(player)
	if not key or locks[key] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	locks[key] = true
	local grantedTools = nil
	local grantedCount = 0
	local totalReserved = 0
	local resultCode = "server-error"
	local plot = nil
	local reservation = pendingReservation(profile, receiptInfo.ProductId)
	local noOp = false
	local oldReservation = profile.Data.PendingCollectAllReservation
	local oldItems = profile.Data.FoodInventoryItems
	local oldCounts = profile.Data.FoodInventory

	local ok, err = pcall(function()
		plot = PlotService.GetPlayerPlot(player)
		if not plot then
			resultCode = "missing-plot"
			return
		end
		if not reservation then
			resultCode = "missing-reservation"
			return
		end
		if reservationExpired(reservation) then
			noOp = true
			resultCode = "reservation-expired"
			return
		end
		totalReserved = #(reservation.items or {})
		local remainingSlots = Inventory.RemainingSlots(player, Inventory.COLLECT_ALL_MAX_ITEMS)
			if remainingSlots <= 0 then
				resultCode = "inventory-full"
				return
			end

			local purchaseClaimed = false
			local appliedPurchaseId = reservationPurchaseId(reservation)
			if appliedPurchaseId and appliedPurchaseId ~= purchaseId then
				resultCode = "receipt-mismatch"
				return
			end
			if not appliedPurchaseId then
				reservation.appliedPurchaseId = purchaseId
				purchaseClaimed = true
				profile.Data.PendingCollectAllReservation = reservation
			end

			local selected, reservationChanged = collectReservedItems(player, plot, reservation, remainingSlots)
			if reservationChanged or purchaseClaimed then
				profile.Data.PendingCollectAllReservation = reservation
				resultCode = "source-commit-snapshot-failed"
				if not snapshotIfPossible(player, plot, profile) then
					return
			end
			resultCode = "source-commit-save-failed"
			if not saveProfile(profile) then
				return
			end
		end
		if #selected == 0 then
			resultCode = "no-food"
			return
		end

		resultCode = "grant-failed"
		grantedTools, resultCode = grantItems(player, selected)
		if not grantedTools then
			return
		end
		grantedCount = #grantedTools

		local selectedSet = {}
		for _, item in ipairs(selected) do
			selectedSet[item] = true
		end
		for _, item in ipairs(reservation.items or {}) do
			if not selectedSet[item] and item.sourceCommitted ~= true and item.sourceUnavailable ~= true then
				local feed = feedByIndex(plot, int(item.sourceFeedIndex, 0))
				if feed then
					FeedMachines.ReleaseCollectAll(feed, item, reservation.reservationId)
				end
			end
		end

		profile.Data.PendingCollectAllReservation = nil
		ReceiptService.MarkProcessed(profile, purchaseId)
		resultCode = "snapshot-failed"
		if not snapshotIfPossible(player, plot, profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			profile.Data.PendingCollectAllReservation = reservation
			profile.Data.FoodInventoryItems = oldItems
			profile.Data.FoodInventory = oldCounts
			destroyTools(grantedTools)
			grantedTools = nil
			return
		end
		resultCode = "save-failed"
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			profile.Data.PendingCollectAllReservation = reservation
			profile.Data.FoodInventoryItems = oldItems
			profile.Data.FoodInventory = oldCounts
			destroyTools(grantedTools)
			grantedTools = nil
			return
		end
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		ReceiptService.ClearProcessed(profile, purchaseId)
		profile.Data.PendingCollectAllReservation = oldReservation
		profile.Data.FoodInventoryItems = oldItems
		profile.Data.FoodInventory = oldCounts
		destroyTools(grantedTools)
		warn("[CollectAllService] Receipt failed: " .. tostring(err))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if grantedTools then
		PlayerReplicaService.PublishFoodInventory(player, profile)
		if grantedCount < totalReserved then
			NotificationService.Success(player, string.format(
				"Collected %d food. Inventory capped at %d.",
				grantedCount,
				Inventory.COLLECT_ALL_MAX_ITEMS
			))
		else
			NotificationService.Success(player, string.format("Collected %d food!", grantedCount))
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if noOp then
		return finishNoOp(profile, purchaseId, player, plot, "Collect all reservation expired")
	end

	if resultCode == "no-food" or resultCode == "missing-reservation" then
		return finishNoOp(profile, purchaseId, player, plot, "No reserved food was available to collect")
	end

	if resultCode == "inventory-full" then
		NotificationService.Error(player, string.format("Inventory full (%d max). Delete items first", Inventory.COLLECT_ALL_MAX_ITEMS))
	else
		NotificationService.Error(player, "Could not complete collect all yet")
		warn("[CollectAllService] Receipt grant failed: " .. tostring(resultCode))
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function CollectAllService.Start(config)
	if started then
		return
	end
	started = true
	config = type(config) == "table" and config or {}
	snapshotProfileState = config.snapshotProfileState

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "CollectAllService.Request", onCollectAllRequest)
	RuntimeGuard.Connect(Players.PlayerRemoving, "CollectAllService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequest[key] = nil
		end
	end)
	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "CollectAllService.PromptFinished", function(playerOrUserId, finishedProductId, wasPurchased)
		local userId = typeof(playerOrUserId) == "Instance" and playerOrUserId.UserId or playerOrUserId
		local player = Players:GetPlayerByUserId(userId)
		if player and int(finishedProductId, 0) == collectAllProductId() and wasPurchased ~= true then
			cancelReservation(player)
		end
	end)
end

return CollectAllService
