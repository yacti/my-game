local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local FeedRewardService = require(Server:WaitForChild("FeedRewardService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local RebirthBalance = require(Shared:WaitForChild("RebirthBalance"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local RebirthService = {}

local REQUEST_RATE_SECONDS = 0.75

local started = false
local transactionLocks = {}
local requestLastFire = {}

local RebirthResult = Remotes.get(Remotes.Names.RebirthResult)

local function userKey(player)
	return player and player.UserId or nil
end

local function consumeRateLimit(map, player, interval)
	local key = userKey(player)
	if key == nil then
		return false
	end

	local now = os.clock()
	local previous = map[key] or 0
	if now - previous < interval then
		return false
	end
	map[key] = now
	return true
end

local function integer(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	return math.floor(value)
end

local function deepCopyArray(array)
	local copy = {}
	for i, value in ipairs(array or {}) do
		if type(value) == "table" then
			local entry = {}
			for k, v in pairs(value) do
				entry[k] = v
			end
			copy[i] = entry
		end
	end
	return copy
end

local function copyMap(map)
	local copy = {}
	for k, v in pairs(map or {}) do
		copy[k] = v
	end
	return copy
end

local function saveProfile(profile)
	local ok, err = pcall(function()
		profile:Save()
	end)
	if not ok then
		warn("[RebirthService] Profile save failed: " .. tostring(err))
	end
	return ok
end

local function orderOnePetId()
	local found
	local count = 0
	for _, petId in ipairs(PetCatalog.AllPetIds()) do
		local definition = PetCatalog.GetDefinition(petId)
		if definition and definition.Order == 1 then
			found = petId
			count += 1
		end
	end
	if count ~= 1 then
		return nil, "invalid-order-one-pet"
	end
	return found
end

local function publishPetState(pet, money, xp)
	pet:SetAttribute(State.Pet.Money, money or 0)
	pet:SetAttribute(State.Pet.XP, xp or 0)
end

local function currentPetPositions(plot)
	local floor = PlotService.GetFloor(plot)
	local positions = {}
	if not floor then
		return positions
	end
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		local index = pet:GetAttribute(State.Pet.Index)
		if type(index) == "number" then
			local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, PetMotionService.GetLogicalPivot(pet))
			positions[index] = { lx = lx, lz = lz, lry = lry }
		end
	end
	return positions
end

local function normalizePetRotations(pets)
	for _, pet in ipairs(pets) do
		if pet.lry == nil then
			pet.lry = 0
		end
		pet.lry = tonumber(pet.lry) or 0
	end
end

local function buildTargetPets(plot, profile, tier)
	local floor = PlotService.GetFloor(plot)
	if not floor then
		return nil, "no-floor"
	end

	local basePetId, baseCode = orderOnePetId()
	if not basePetId then
		return nil, baseCode
	end

	local positions = currentPetPositions(plot)
	local targetPets = {}
	for index, existing in ipairs(profile.Data.Pets or {}) do
		local position = positions[index] or existing
		targetPets[#targetPets + 1] = {
			petId = basePetId,
			xp = 0,
			money = 0,
			lx = tonumber(position and position.lx),
			lz = tonumber(position and position.lz),
			lry = tonumber(position and position.lry) or 0,
		}
	end

	for _, reward in ipairs(tier.PetRewards or {}) do
		local petId = reward.petId
		local amount = integer(reward.amount, 0)
		if type(petId) ~= "string" or not PetCatalog.GetDefinition(petId) or amount <= 0 then
			return nil, "invalid-pet-reward"
		end
		for _ = 1, amount do
			targetPets[#targetPets + 1] = {
				petId = petId,
				xp = 0,
				money = 0,
			}
		end
	end

	normalizePetRotations(targetPets)
	return targetPets
end

local function destroyPreparedPets(preparedPets)
	for _, pet in ipairs(preparedPets or {}) do
		if pet then
			pet:Destroy()
		end
	end
end

local function preparePetModels(plot, pets)
	local floor = PlotService.GetFloor(plot)
	if not floor then
		return nil, "no-floor"
	end

	local prepared = {}
	for index, petData in ipairs(pets or {}) do
		local clone = PlotService.CreatePet(petData.petId, index, petData.xp or 0, floor, petData.lx or 0, petData.lz or 0, petData.lry or 0)
		if not clone then
			destroyPreparedPets(prepared)
			return nil, "pet-build-failed"
		end
		local fitted, fitLX, fitLZ = PlotService.FitPetOnUnlockedGrid(
			plot,
			clone,
			petData.lx or 0,
			petData.lz or 0,
			petData.lry or 0,
			petData.lx == nil or petData.lz == nil
		)
		if not fitted then
			clone:Destroy()
			destroyPreparedPets(prepared)
			return nil, "pet-grid-fit-failed"
		end
		petData.lx = fitLX
		petData.lz = fitLZ
		petData.lry = tonumber(petData.lry) or 0
		prepared[#prepared + 1] = clone
	end
	return prepared
end

local function prepareFeedRewards(tier)
	local prepared = {}
	for _, reward in ipairs(tier.Rewards or {}) do
		if reward.kind ~= "FeedMachine" then
			for _, grant in ipairs(prepared) do
				FeedRewardService.DestroyPrepared(grant)
			end
			return nil, "invalid-reward-kind"
		end

		local amount = integer(reward.amount, 0)
		local grant, code = FeedRewardService.PrepareGrant(reward.feedType, amount)
		if not grant then
			for _, existing in ipairs(prepared) do
				FeedRewardService.DestroyPrepared(existing)
			end
			return nil, code or "invalid-feed-reward"
		end
		prepared[#prepared + 1] = grant
	end
	return prepared
end

local function destroyPreparedFeedRewards(preparedRewards)
	for _, grant in ipairs(preparedRewards or {}) do
		FeedRewardService.DestroyPrepared(grant)
	end
end

local function applyPreparedFeedRewards(player, profile, preparedRewards)
	for _, grant in ipairs(preparedRewards or {}) do
		local ok, code = FeedRewardService.ApplyPrepared(player, profile, grant)
		if not ok then
			return false, code
		end
	end
	return true
end

local function snapshotProfile(profile)
	return {
		Currency = integer(profile.Data.Currency, 0),
		Rebirths = integer(profile.Data.Rebirths, 0),
		Pets = deepCopyArray(profile.Data.Pets),
		FeedInventory = copyMap(profile.Data.FeedInventory),
		SeedInventory = copyMap(profile.Data.SeedInventory),
		ProcessedReceipts = copyMap(profile.Data.ProcessedReceipts),
	}
end

local function restoreProfile(player, profile, snapshot)
	CurrencyService.SetBalanceForServer(player, profile, snapshot.Currency or 0, true)
	profile.Data.Rebirths = snapshot.Rebirths or 0
	profile.Data.Pets = deepCopyArray(snapshot.Pets)
	profile.Data.FeedInventory = copyMap(snapshot.FeedInventory)
	profile.Data.SeedInventory = copyMap(snapshot.SeedInventory)
	profile.Data.ProcessedReceipts = copyMap(snapshot.ProcessedReceipts)
end

local function swapPreparedPets(plot, profilePets, preparedPets)
	PetMotionService.UnregisterPlot(plot)
	PlotService.DestroyPets(plot)

	for _, pet in ipairs(preparedPets) do
		pet.Parent = plot
	end
	for index, pet in ipairs(preparedPets) do
		local petData = profilePets[index] or {}
		publishPetState(pet, petData.money or 0, petData.xp or 0)
		PetMotionService.Register(plot, pet)
	end

	local spawned = #PlotService.GetSortedPets(plot)
	return spawned == #profilePets
end

local function restoreLivePets(plot, pets)
	local prepared, code = preparePetModels(plot, pets)
	if not prepared then
		return false, code
	end
	local ok = swapPreparedPets(plot, pets, prepared)
	if not ok then
		destroyPreparedPets(prepared)
		return false, "restore-failed"
	end
	return true
end

local function sendResult(player, requestId, success, code)
	local payload = {
		requestId = requestId,
		success = success,
		code = code,
	}
	RebirthResult:FireClient(player, payload)
end

local function runTransaction(player, options)
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return false, "no-profile"
	end

	local plot = PlotService.GetPlayerPlot(player)
	if not plot then
		return false, "no-plot"
	end

	local currentRebirths = integer(profile.Data.Rebirths, 0)
	local tierNumber, tier = RebirthBalance.GetNextTier(currentRebirths)
	if not tier then
		return false, "max-tier"
	end
	if options.expectedTier and tierNumber ~= options.expectedTier then
		return false, "tier-mismatch"
	end

	local targetPets, petCode = buildTargetPets(plot, profile, tier)
	if not targetPets then
		return false, petCode
	end
	local preparedPets, preparePetCode = preparePetModels(plot, targetPets)
	if not preparedPets then
		return false, preparePetCode
	end
	local preparedFeeds, prepareFeedCode = prepareFeedRewards(tier)
	if not preparedFeeds then
		destroyPreparedPets(preparedPets)
		return false, prepareFeedCode
	end

	local snapshot = snapshotProfile(profile)
	local minimumCash = options.skip == true and 0 or integer(tier.Price, 0)
	local resetOk, resetCode = CurrencyService.ResetToZeroForRebirth(player, profile, minimumCash, true)
	if not resetOk then
		destroyPreparedPets(preparedPets)
		destroyPreparedFeedRewards(preparedFeeds)
		return false, resetCode
	end

	profile.Data.Rebirths = tierNumber
	profile.Data.Pets = targetPets

	local feedsOk, feedsCode = applyPreparedFeedRewards(player, profile, preparedFeeds)
	if not feedsOk then
		restoreProfile(player, profile, snapshot)
		destroyPreparedPets(preparedPets)
		destroyPreparedFeedRewards(preparedFeeds)
		restoreLivePets(plot, snapshot.Pets)
		return false, feedsCode or "grant-failed"
	end

	if not swapPreparedPets(plot, profile.Data.Pets, preparedPets) then
		restoreProfile(player, profile, snapshot)
		destroyPreparedFeedRewards(preparedFeeds)
		local restored = restoreLivePets(plot, snapshot.Pets)
		if not restored then
			warn("[RebirthService] Failed to restore live pet state after rebirth swap failure")
		end
		return false, "pet-swap-failed"
	end

	if options.purchaseId then
		ReceiptService.MarkProcessed(profile, options.purchaseId)
	end

	if not saveProfile(profile) then
		restoreProfile(player, profile, snapshot)
		destroyPreparedFeedRewards(preparedFeeds)
		local restored = restoreLivePets(plot, snapshot.Pets)
		if not restored then
			warn("[RebirthService] Failed to restore live pet state after profile save failure")
		end
		PlayerReplicaService.PublishProfile(player, profile)
		CurrencyService.Publish(player, profile)
		return false, "save-failed"
	end

	PlayerReplicaService.PublishProfile(player, profile)
	CurrencyService.Publish(player, profile)
	NotificationService.Success(player, string.format("Rebirth %d complete!", tierNumber))
	TelemetryService.Record("rebirth_succeeded", TelemetryService.ForPlayer(player, {
		tier = tierNumber,
		skip = options.skip == true,
		purchaseId = options.purchaseId,
	}))
	return true, "ok"
end

local function performRebirth(player, options)
	local key = userKey(player)
	if key == nil or transactionLocks[key] then
		return false, "busy"
	end

	transactionLocks[key] = true
	local ok, success, code = pcall(runTransaction, player, options or {})
	transactionLocks[key] = nil

	if not ok then
		warn("[RebirthService] Transaction failed: " .. tostring(success))
		TelemetryService.Warn("rebirth_failed", TelemetryService.ForPlayer(player, {
			reason = "server-error",
			skip = options and options.skip == true,
			purchaseId = options and options.purchaseId,
		}))
		return false, "server-error"
	end
	if not success then
		TelemetryService.Warn("rebirth_failed", TelemetryService.ForPlayer(player, {
			reason = code,
			skip = options and options.skip == true,
			purchaseId = options and options.purchaseId,
		}))
	end
	return success, code
end

local function markReceiptNoOp(profile, purchaseId, reason)
	ReceiptService.MarkProcessed(profile, purchaseId)
	local saved = saveProfile(profile)
	if not saved then
		ReceiptService.ClearProcessed(profile, purchaseId)
	end
	warn("[RebirthService] Rebirth skip receipt no-op: " .. tostring(reason))
	TelemetryService.Warn("rebirth_receipt_noop", {
		purchaseId = purchaseId,
		reason = reason,
		saved = saved,
	})
	return saved
end

function RebirthService.ProcessSkipReceipt(receiptInfo, player)
	player = player or Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not purchaseId then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if ReceiptService.HasProcessed(profile, purchaseId) then
		TelemetryService.Record("rebirth_receipt_duplicate", TelemetryService.ForPlayer(player, {
			purchaseId = purchaseId,
			productId = receiptInfo.ProductId,
		}))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local productTier = RebirthBalance.TierForSkipProductId(receiptInfo.ProductId)
	if not productTier then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local nextTierNumber, nextTier = RebirthBalance.GetNextTier(profile.Data.Rebirths)
	if not nextTier then
		return markReceiptNoOp(profile, purchaseId, "max-tier")
			and Enum.ProductPurchaseDecision.PurchaseGranted
			or Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if productTier ~= nextTierNumber then
		return markReceiptNoOp(profile, purchaseId, productTier < nextTierNumber and "stale-tier" or "future-tier")
			and Enum.ProductPurchaseDecision.PurchaseGranted
			or Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local success, code = performRebirth(player, {
		skip = true,
		expectedTier = productTier,
		purchaseId = purchaseId,
	})
	if success then
		TelemetryService.Record("rebirth_receipt_granted", TelemetryService.ForPlayer(player, {
			purchaseId = purchaseId,
			productId = receiptInfo.ProductId,
			tier = productTier,
		}))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	warn(string.format("[RebirthService] Skip receipt could not be granted: %s", tostring(code)))
	TelemetryService.Warn("rebirth_receipt_failed", TelemetryService.ForPlayer(player, {
		purchaseId = purchaseId,
		productId = receiptInfo.ProductId,
		tier = productTier,
		reason = code,
	}))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function RebirthService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.RebirthRequest).OnServerEvent, "RebirthService.RebirthRequest", function(player, requestId)
		if type(requestId) ~= "number" then
			requestId = nil
		end
		if not consumeRateLimit(requestLastFire, player, REQUEST_RATE_SECONDS) then
			sendResult(player, requestId, false, "rate-limited")
			return
		end

		local success, code = performRebirth(player, {
			skip = false,
		})
		sendResult(player, requestId, success, code)
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "RebirthService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key == nil then return end
		transactionLocks[key] = nil
		requestLastFire[key] = nil
	end)
end

return RebirthService
