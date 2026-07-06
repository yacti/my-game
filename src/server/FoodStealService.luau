local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local FoodInventoryService = require(Server:WaitForChild("FoodInventoryService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PetIncomeService = require(Server:WaitForChild("PetIncomeService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local FoodStealService = {}

local REQUEST_RATE_SECONDS = 0.5
local RESERVATION_SECONDS = 5 * 60
local STEAL_DISTANCE = 10
local SOURCE_UNAVAILABLE_COMPENSATION_SECONDS = 15 * 60

local started = false
local locks = {}
local lastRequest = {}
local activeReservations = {}
local sourceReservations = {}
local snapshotProfileState = nil

local requestRemote = Remotes.get(Remotes.Names.FoodStealRequest)
local resultRemote = Remotes.get(Remotes.Names.FoodStealResult)
local cancelRemote = Remotes.get(Remotes.Names.FoodStealCancel)

local function userKey(player)
	return player and player.UserId or nil
end

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function productId()
	local config = ShopBalance.GetFoodSteal()
	return int(config and config.DevProductId, 0)
end

local function now()
	return os.time()
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
	if not instance then return nil end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local cf = instance:GetBoundingBox()
		return cf.Position
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

local function clearReservation(profile)
	if profile and profile.Data then
		profile.Data.PendingFoodStealReservation = nil
	end
end

local function untrackSourceReservation(key, reservation)
	local sourceUserId = int(reservation and reservation.sourceOwnerUserId, 0)
	if not (key and sourceUserId > 0) then
		return
	end
	local bucket = sourceReservations[sourceUserId]
	if not bucket then
		return
	end
	bucket[key] = nil
	if next(bucket) == nil then
		sourceReservations[sourceUserId] = nil
	end
end

local function trackActiveReservation(key, machine, reservation)
	if not key then
		return
	end
	activeReservations[key] = {
		machine = machine,
		reservation = reservation,
	}
	local sourceUserId = int(reservation and reservation.sourceOwnerUserId, 0)
	if sourceUserId > 0 then
		local bucket = sourceReservations[sourceUserId]
		if not bucket then
			bucket = {}
			sourceReservations[sourceUserId] = bucket
		end
		bucket[key] = true
	end
end

local function clearActiveReservation(key)
	local active = key and activeReservations[key] or nil
	if active then
		untrackSourceReservation(key, active.reservation)
	end
	activeReservations[key] = nil
	return active
end

local function releaseActiveReservation(key)
	local active = clearActiveReservation(key)
	if not active then
		return false
	end
	return FeedMachines.ReleaseSteal(active.machine, active.reservation, active.reservation.reservationId)
end

local function pendingReservation(profile)
	local reservation = profile and profile.Data and profile.Data.PendingFoodStealReservation
	if type(reservation) ~= "table" then
		return nil
	end
	if int(reservation.productId, 0) ~= productId() then
		return nil
	end
	return reservation
end

local function clearExpiredReservation(player, profile)
	local reservation = pendingReservation(profile)
	if not reservation then
		return true
	end
	if int(reservation.expiresAt, 0) >= now() then
		return false
	end
	releaseActiveReservation(userKey(player))
	clearReservation(profile)
	return saveProfile(profile)
end

local function normalizeReservation(snapshot, reservationId)
	local createdAt = now()
	local configProductId = productId()
	return {
		reservationId = reservationId,
		productId = configProductId,
		foodId = snapshot.foodId,
		xp = math.max(tonumber(snapshot.xp) or 0, 0),
			scale = tonumber(snapshot.scale),
			mutationIds = snapshot.mutationIds,
			primaryMutationId = snapshot.primaryMutationId,
			sourceKind = snapshot.sourceKind,
		sourceOwnerUserId = int(snapshot.sourceOwnerUserId, 0),
		sourceFeedIndex = int(snapshot.sourceFeedIndex, 0),
		sourceSlotIndex = int(snapshot.sourceSlotIndex, 0),
		sourceCommitted = snapshot.sourceCommitted == true,
		sourceUnavailable = snapshot.sourceUnavailable == true,
		createdAt = createdAt,
		expiresAt = createdAt + RESERVATION_SECONDS,
	}
end

local function reservationExpiresAt()
	return now() + RESERVATION_SECONDS
end

local function foodDisplayName(foodId)
	local template = type(foodId) == "string" and Food.GetTemplate(foodId) or nil
	if template then
		return template.Name
	end
	return type(foodId) == "string" and foodId or "food"
end

local function compensationAmount(player)
	local perSecond = PetIncomeService.Compute(player)
	perSecond = tonumber(perSecond) or 0
	if perSecond ~= perSecond or math.abs(perSecond) == math.huge then
		perSecond = 0
	end
	return math.max(math.floor(perSecond * SOURCE_UNAVAILABLE_COMPENSATION_SECONDS), 1)
end

local function reservationCompensationAmount(player, reservation)
	local amount = tonumber(reservation and reservation.compensationCash)
	if type(amount) == "number" and amount == amount and math.abs(amount) < math.huge and amount > 0 then
		return math.floor(amount)
	end
	return compensationAmount(player)
end

local function sourceContext(reservation)
	local sourcePlayer = Players:GetPlayerByUserId(int(reservation and reservation.sourceOwnerUserId, 0))
	local sourceProfile = sourcePlayer and PlayerDataService.GetProfile(sourcePlayer)
	local sourcePlot = sourcePlayer and PlotService.GetPlayerPlot(sourcePlayer)
	if not (sourcePlayer and sourceProfile and sourcePlot) then
		return nil, nil, nil, nil
	end
	local sourceFeedIndex = int(reservation.sourceFeedIndex, 0)
	for _, feed in ipairs(PlotService.GetSortedFeeds(sourcePlot)) do
		if feed:GetAttribute(State.Feed.Index) == sourceFeedIndex then
			return sourcePlayer, sourceProfile, sourcePlot, feed
		end
	end

	return sourcePlayer, sourceProfile, sourcePlot, nil
end

local function isSourceUnavailable(reservation)
	local sourcePlayer = Players:GetPlayerByUserId(int(reservation and reservation.sourceOwnerUserId, 0))
	if not sourcePlayer then
		return true
	end
	if not PlayerDataService.GetProfile(sourcePlayer) then
		return true
	end
	if not PlotService.GetPlayerPlot(sourcePlayer) then
		return true
	end
	return false
end

local function snapshotSourceOwner(reservation)
	local sourcePlayer, sourceProfile, sourcePlot, feed = sourceContext(reservation)
	if type(snapshotProfileState) == "function" and sourcePlayer and sourceProfile and sourcePlot then
		local snapshotOk = snapshotProfileState(sourcePlayer, sourcePlot, sourceProfile)
		if not snapshotOk then
			warn("[FoodStealService] Source snapshot failed after steal for user " .. tostring(reservation.sourceOwnerUserId))
		end
	end
	return sourcePlayer, feed
end

local function commitSourceRemoval(thief, reservation, active)
	if reservation and reservation.sourceCommitted == true then
		return true
	end
	local committed = false
	if active and active.machine then
		committed = FeedMachines.CommitSteal(active.machine, reservation, reservation.reservationId) == true
	end
	if not committed then
		local _, _, _, feed = sourceContext(reservation)
		if feed then
			committed = FeedMachines.CommitSteal(feed, reservation, reservation.reservationId) == true
		end
	end
	local sourcePlayer = snapshotSourceOwner(reservation)
	local foodName = foodDisplayName(reservation and reservation.foodId)
	if committed and sourcePlayer then
		local thiefName = thief and thief.DisplayName or thief and thief.Name or "Someone"
		NotificationService.Info(sourcePlayer, string.format("%s has stolen your %s!", thiefName, foodName))
	elseif not committed then
		warn(string.format(
			"[FoodStealService] Could not clear stolen source kind=%s owner=%s feed=%s slot=%s reservation=%s",
			tostring(reservation.sourceKind),
			tostring(reservation.sourceOwnerUserId),
			tostring(reservation.sourceFeedIndex),
			tostring(reservation.sourceSlotIndex),
			tostring(reservation.reservationId)
		))
	end
	return committed == true
end

local function onStealRequest(player, requestId, target)
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
	if not profile then
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
	if Inventory.RemainingSlots(player) <= 0 then
		NotificationService.Error(player, string.format("Inventory full (%d max). Delete or use some items first", Inventory.MAX_ITEMS))
		sendResult(player, requestId, false, "inventory-full")
		return
	end
	if not isPlayerNearInstance(player, target, STEAL_DISTANCE) then
		sendResult(player, requestId, false, "too-far")
		return
	end
	if pendingReservation(profile) and not clearExpiredReservation(player, profile) then
		sendResult(player, requestId, false, "pending-purchase")
		return
	end

	locks[key] = true
	local saved = false
	local reservation = nil
	local machine = nil
	local resultCode = "server-error"
	local ok, err = pcall(function()
		local reservationId = HttpService:GenerateGUID(false)
		local expiresAt = reservationExpiresAt()
		local reserved, snapshotOrCode, reservedMachine = FeedMachines.ReserveStealTarget(target, player, reservationId, expiresAt)
		if not reserved then
			resultCode = snapshotOrCode or "invalid-target"
			return
		end
		reservation = normalizeReservation(snapshotOrCode, reservationId)
		reservation.expiresAt = expiresAt
		machine = reservedMachine
		local sourcePlayer = Players:GetPlayerByUserId(reservation.sourceOwnerUserId)
		if sourcePlayer and OfflineProgressService.IsPending(sourcePlayer) then
			resultCode = "source-busy"
			FeedMachines.ReleaseSteal(machine, reservation, reservationId)
			return
		end
		profile.Data.PendingFoodStealReservation = reservation
		saved = saveProfile(profile)
		if not saved then
			clearReservation(profile)
			FeedMachines.ReleaseSteal(machine, reservation, reservationId)
			resultCode = "save-failed"
			return
		end
		trackActiveReservation(key, machine, reservation)
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		if reservation and machine then
			FeedMachines.ReleaseSteal(machine, reservation, reservation.reservationId)
		end
		clearReservation(profile)
		warn("[FoodStealService] Reservation failed: " .. tostring(err))
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

local function cancelReservation(player, reservationId)
	local profile = PlayerDataService.GetProfile(player)
	local reservation = pendingReservation(profile)
	if not reservation then
		return
	end
	if type(reservationId) == "string" and reservationId ~= "" and reservation.reservationId ~= reservationId then
		return
	end
	releaseActiveReservation(userKey(player))
	clearReservation(profile)
	saveProfile(profile)
end

local function onClientCancel(_player, _reservationId)
	-- The client can fire this remote from sandboxed prompt UI, so it must not
	-- be allowed to clear paid-purchase context. Server-side
	-- PromptProductPurchaseFinished is the trusted decline signal.
end

local function releaseReservationsForSource(sourceUserId)
	local bucket = sourceReservations[sourceUserId]
	if not bucket then
		return
	end
	local buyerKeys = {}
	for buyerKey in pairs(bucket) do
		buyerKeys[#buyerKeys + 1] = buyerKey
	end
	for _, buyerKey in ipairs(buyerKeys) do
		local active = clearActiveReservation(buyerKey)
		if active then
			FeedMachines.ReleaseSteal(active.machine, active.reservation, active.reservation.reservationId)
		end
		local buyer = Players:GetPlayerByUserId(buyerKey)
		local profile = buyer and PlayerDataService.GetProfile(buyer)
		local reservation = pendingReservation(profile)
		if reservation and reservation.sourceCommitted ~= true and int(reservation.sourceOwnerUserId, 0) == sourceUserId then
			reservation.sourceUnavailable = true
			reservation.compensationCash = compensationAmount(buyer)
			profile.Data.PendingFoodStealReservation = reservation
			saveProfile(profile)
			NotificationService.Info(buyer, "Food steal target left. If you complete the purchase, you will receive cash compensation")
		end
	end
	sourceReservations[sourceUserId] = nil
end

function FoodStealService.HandlesProductId(productIdValue)
	return ShopBalance.FoodStealForProductId(productIdValue) ~= nil
end

function FoodStealService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local config = ShopBalance.FoodStealForProductId(receiptInfo.ProductId)
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
	local grantedTool = nil
	local granted = false
	local compensated = false
	local compensationCash = 0
	local resultCode = "server-error"
	local oldReservation = profile.Data.PendingFoodStealReservation
	local oldItems = profile.Data.FoodInventoryItems
	local oldCounts = profile.Data.FoodInventory
	local oldCurrency = profile.Data.Currency
	local reservation = pendingReservation(profile)
	local function compensateReservation()
		resultCode = "compensation-add-failed"
		compensationCash = reservationCompensationAmount(player, reservation)
		local _, addCode = CurrencyService.Add(player, profile, compensationCash, true)
		if addCode ~= nil then
			return false
		end
		clearActiveReservation(key)
		clearReservation(profile)
		ReceiptService.MarkProcessed(profile, purchaseId)
		resultCode = "compensation-save-failed"
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			profile.Data.PendingFoodStealReservation = reservation
			profile.Data.Currency = oldCurrency
			return false
		end
		compensated = true
		resultCode = "ok"
		return true
	end
	local ok, err = pcall(function()
		if not reservation then
			resultCode = "missing-reservation"
			return
		end

		if reservation.sourceUnavailable == true and reservation.sourceCommitted ~= true then
			compensateReservation()
			return
		end

		if reservation.sourceCommitted ~= true then
			resultCode = "source-remove-failed"
			local active = activeReservations[key]
			if commitSourceRemoval(player, reservation, active) ~= true then
				if isSourceUnavailable(reservation) then
					reservation.sourceUnavailable = true
					profile.Data.PendingFoodStealReservation = reservation
					compensateReservation()
				end
				return
			end
			clearActiveReservation(key)
			reservation.sourceCommitted = true
			profile.Data.PendingFoodStealReservation = reservation
			resultCode = "source-commit-save-failed"
			if not saveProfile(profile) then
				return
			end
		else
			clearActiveReservation(key)
		end

		resultCode = "inventory-full"
		if Inventory.RemainingSlots(player) <= 0 then
			return
		end

		resultCode = "grant-failed"
		grantedTool = FoodInventoryService.MakeTool(reservation)
		if not grantedTool then
			return
		end
		if not ToolGrantService.GrantTool(player, grantedTool, {
			deferAutoEquip = true,
			autoEquipPolicy = "firstInBurst",
			autoEquipBurstGap = 3,
		}) then
			grantedTool:Destroy()
			grantedTool = nil
			return
		end

		resultCode = "save-failed"
		profile.Data.FoodInventoryItems = FoodInventoryService.SerializeTools(player)
		profile.Data.FoodInventory = FoodInventoryService.CountRecords(profile.Data.FoodInventoryItems)
		clearReservation(profile)
		ReceiptService.MarkProcessed(profile, purchaseId)
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			profile.Data.PendingFoodStealReservation = reservation
			profile.Data.FoodInventoryItems = oldItems
			profile.Data.FoodInventory = oldCounts
			if grantedTool and grantedTool.Parent then
				grantedTool:Destroy()
			end
			grantedTool = nil
			return
		end
		granted = true
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		ReceiptService.ClearProcessed(profile, purchaseId)
		profile.Data.PendingFoodStealReservation = reservation and reservation.sourceCommitted == true and reservation or oldReservation
		profile.Data.FoodInventoryItems = oldItems
		profile.Data.FoodInventory = oldCounts
		profile.Data.Currency = oldCurrency
		if grantedTool and grantedTool.Parent then
			grantedTool:Destroy()
		end
		warn("[FoodStealService] Receipt failed: " .. tostring(err))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if granted then
		clearActiveReservation(key)
		PlayerReplicaService.PublishFoodInventory(player, profile)
		if reservation then
			local sourcePlayer = Players:GetPlayerByUserId(int(reservation.sourceOwnerUserId, 0))
			local sourceName = sourcePlayer and sourcePlayer.DisplayName or sourcePlayer and sourcePlayer.Name or "Player"
			NotificationService.Notify(player, {
				kind = NotificationConfig.Kinds.Success,
				text = string.format(
					"You have stolen %s's %s!",
					sourceName,
					foodDisplayName(reservation.foodId)
				),
				sound = "FoodStolen",
			})
		else
			NotificationService.Error(player, "Could not find the food steal reservation")
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if compensated then
		PlayerReplicaService.PublishFoodInventory(player, profile)
		CurrencyService.Publish(player, profile)
		NotificationService.Success(player, string.format(
			"Steal failed! Victim left, $%d rewarded instead!",
			compensationCash
		))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if resultCode == "inventory-full" then
		NotificationService.Error(player, string.format("Inventory full (%d max). Delete or use some items first", Inventory.MAX_ITEMS))
	else
		NotificationService.Error(player, "Could not complete food steal yet")
		warn("[FoodStealService] Receipt grant failed: " .. tostring(resultCode))
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function FoodStealService.Start(config)
	if started then
		return
	end
	started = true
	config = type(config) == "table" and config or {}
	snapshotProfileState = config.snapshotProfileState

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "FoodStealService.Request", onStealRequest)
	RuntimeGuard.Connect(cancelRemote.OnServerEvent, "FoodStealService.ClientCancel", onClientCancel)
	RuntimeGuard.Connect(Players.PlayerRemoving, "FoodStealService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			releaseReservationsForSource(key)
			releaseActiveReservation(key)
			locks[key] = nil
			lastRequest[key] = nil
		end
	end)
	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "FoodStealService.PromptFinished", function(playerOrUserId, finishedProductId, wasPurchased)
		local userId = typeof(playerOrUserId) == "Instance" and playerOrUserId.UserId or playerOrUserId
		local player = Players:GetPlayerByUserId(userId)
		if player and int(finishedProductId, 0) == productId() and wasPurchased ~= true then
			cancelReservation(player)
		end
	end)
end

return FoodStealService
