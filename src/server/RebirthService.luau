local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local FeedRewardService = require(Server:WaitForChild("FeedRewardService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))
local SeedTools = require(Server:WaitForChild("SeedTools"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AutoRollConfig = require(Shared:WaitForChild("AutoRollConfig"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
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

local function appendPetRewards(targetPets, tier)
	for _, reward in ipairs(tier.PetRewards or {}) do
		local petId = reward.petId
		local amount = integer(reward.amount, 0)
		if type(petId) ~= "string" or not PetCatalog.GetDefinition(petId) or amount <= 0 then
			return false, "invalid-pet-reward"
		end
		for _ = 1, amount do
			targetPets[#targetPets + 1] = {
				petId = petId,
				xp = 0,
				money = 0,
			}
		end
	end
	return true
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

	local rewardsOk, rewardCode = appendPetRewards(targetPets, tier)
	if not rewardsOk then
		return nil, rewardCode
	end

	normalizePetRotations(targetPets)
	return targetPets
end

local function buildSkipPetRewards(tier)
	local rewardPets = {}
	local rewardsOk, rewardCode = appendPetRewards(rewardPets, tier)
	if not rewardsOk then
		return nil, rewardCode
	end
	normalizePetRotations(rewardPets)
	return rewardPets
end

local function destroyPreparedPets(preparedPets)
	for _, pet in ipairs(preparedPets or {}) do
		if pet then
			pet:Destroy()
		end
	end
end

local function preparePetModels(plot, pets, startIndex)
	local floor = PlotService.GetFloor(plot)
	if not floor then
		return nil, "no-floor"
	end

	startIndex = integer(startIndex, 1)
	if startIndex < 1 then
		startIndex = 1
	end

	local prepared = {}
	for offset, petData in ipairs(pets or {}) do
		local petIndex = startIndex + offset - 1
		local clone = PlotService.CreatePet(petData.petId, petIndex, petData.xp or 0, floor, petData.lx or 0, petData.lz or 0, petData.lry or 0)
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

local function destroyPreparedReward(prepared)
	if type(prepared) ~= "table" then
		return
	end
	if prepared.kind == "FeedMachine" then
		FeedRewardService.DestroyPrepared(prepared.grant)
	elseif prepared.kind == "Seed" then
		SeedTools.DestroyPrepared(prepared.grant)
	end
end

local function prepareRewards(tier)
	local prepared = {}
	for _, reward in ipairs(tier.Rewards or {}) do
		local amount = integer(reward.amount, 0)
		local grant, code
		if reward.kind == "FeedMachine" then
			grant, code = FeedRewardService.PrepareGrant(reward.feedType, amount)
		elseif reward.kind == "Seed" then
			grant, code = SeedTools.PrepareGrant(reward.seedId, amount)
		else
			for _, existing in ipairs(prepared) do
				destroyPreparedReward(existing)
			end
			return nil, "invalid-reward-kind"
		end

		if not grant then
			for _, existing in ipairs(prepared) do
				destroyPreparedReward(existing)
			end
			return nil, code or "invalid-reward"
		end
		prepared[#prepared + 1] = {
			kind = reward.kind,
			grant = grant,
		}
	end
	return prepared
end

local function destroyPreparedRewards(preparedRewards)
	for _, prepared in ipairs(preparedRewards or {}) do
		destroyPreparedReward(prepared)
	end
end

local function applyPreparedRewards(player, profile, preparedRewards)
	for _, prepared in ipairs(preparedRewards or {}) do
		local ok, code
		if prepared.kind == "FeedMachine" then
			ok, code = FeedRewardService.ApplyPrepared(player, profile, prepared.grant)
		elseif prepared.kind == "Seed" then
			ok, code = SeedTools.ApplyPrepared(player, profile, prepared.grant)
		else
			ok, code = false, "invalid-reward-kind"
		end
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

local function restoreProfile(player, profile, snapshot, restoreCurrency)
	if restoreCurrency ~= false then
		CurrencyService.SetBalanceForServer(player, profile, snapshot.Currency or 0, true)
	end
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

local function appendPreparedPets(plot, profilePets, preparedPets, firstIndex)
	firstIndex = integer(firstIndex, 1)
	if firstIndex < 1 then
		return false, "invalid-pet-index"
	end

	for _, pet in ipairs(preparedPets or {}) do
		if not (pet and pet:IsA("Model")) then
			return false, "pet-build-failed"
		end
	end

	for offset, pet in ipairs(preparedPets or {}) do
		local index = firstIndex + offset - 1
		local petData = profilePets[index] or {}
		pet.Parent = plot
		publishPetState(pet, petData.money or 0, petData.xp or 0)
		PetMotionService.Register(plot, pet)
	end
	return true
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

local function getTransactionContext(player, options)
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

	return true, nil, profile, plot, tierNumber, tier
end

local function finishTransaction(player, profile, tierNumber, options)
	PlayerReplicaService.PublishProfile(player, profile)
	CurrencyService.Publish(player, profile)
	NotificationService.Success(player, "Rebirth " .. NumberFormatter.Integer(tierNumber) .. " complete!")
	if tierNumber == AutoRollConfig.UnlockRebirths then
		NotificationService.Success(player, "You can now auto-roll!")
	end
	TelemetryService.Record("rebirth_succeeded", TelemetryService.ForPlayer(player, {
		tier = tierNumber,
		skip = options.skip == true,
		purchaseId = options.purchaseId,
	}))
	return true, "ok"
end

local function runResetTransaction(player, options)
	local contextOk, contextCode, profile, plot, tierNumber, tier = getTransactionContext(player, options)
	if not contextOk then
		return false, contextCode
	end

	local targetPets, petCode = buildTargetPets(plot, profile, tier)
	if not targetPets then
		return false, petCode
	end
	local preparedPets, preparePetCode = preparePetModels(plot, targetPets)
	if not preparedPets then
		return false, preparePetCode
	end
	local preparedRewards, prepareRewardCode = prepareRewards(tier)
	if not preparedRewards then
		destroyPreparedPets(preparedPets)
		return false, prepareRewardCode
	end

	local snapshot = snapshotProfile(profile)
	local resetOk, resetCode = CurrencyService.ResetToZeroForRebirth(player, profile, integer(tier.Price, 0), true)
	if not resetOk then
		destroyPreparedPets(preparedPets)
		destroyPreparedRewards(preparedRewards)
		return false, resetCode
	end

	profile.Data.Rebirths = tierNumber
	profile.Data.Pets = targetPets

	local rewardsOk, rewardsCode = applyPreparedRewards(player, profile, preparedRewards)
	if not rewardsOk then
		restoreProfile(player, profile, snapshot)
		destroyPreparedPets(preparedPets)
		destroyPreparedRewards(preparedRewards)
		restoreLivePets(plot, snapshot.Pets)
		return false, rewardsCode or "grant-failed"
	end

	if not swapPreparedPets(plot, profile.Data.Pets, preparedPets) then
		restoreProfile(player, profile, snapshot)
		destroyPreparedRewards(preparedRewards)
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
		destroyPreparedRewards(preparedRewards)
		local restored = restoreLivePets(plot, snapshot.Pets)
		if not restored then
			warn("[RebirthService] Failed to restore live pet state after profile save failure")
		end
		PlayerReplicaService.PublishProfile(player, profile)
		CurrencyService.Publish(player, profile)
		return false, "save-failed"
	end

	return finishTransaction(player, profile, tierNumber, options)
end

local function runSkipTransaction(player, options)
	if OfflineProgressService.IsPending(player) then
		return false, "busy"
	end

	local contextOk, contextCode, profile, plot, tierNumber, tier = getTransactionContext(player, options)
	if not contextOk then
		return false, contextCode
	end

	local profilePets = type(profile.Data.Pets) == "table" and profile.Data.Pets or {}
	local existingPetCount = #profilePets
	local rewardPets, petCode = buildSkipPetRewards(tier)
	if not rewardPets then
		return false, petCode
	end

	local preparedPets, preparePetCode = preparePetModels(plot, rewardPets, existingPetCount + 1)
	if not preparedPets then
		return false, preparePetCode
	end
	local preparedRewards, prepareRewardCode = prepareRewards(tier)
	if not preparedRewards then
		destroyPreparedPets(preparedPets)
		return false, prepareRewardCode
	end

	local snapshot = snapshotProfile(profile)
	profile.Data.Rebirths = tierNumber
	profile.Data.Pets = profilePets
	for _, petData in ipairs(rewardPets) do
		profile.Data.Pets[#profile.Data.Pets + 1] = petData
	end

	local rewardsOk, rewardsCode = applyPreparedRewards(player, profile, preparedRewards)
	if not rewardsOk then
		restoreProfile(player, profile, snapshot, false)
		destroyPreparedPets(preparedPets)
		destroyPreparedRewards(preparedRewards)
		return false, rewardsCode or "grant-failed"
	end

	local appendOk, appendCode = appendPreparedPets(plot, profile.Data.Pets, preparedPets, existingPetCount + 1)
	if not appendOk then
		restoreProfile(player, profile, snapshot, false)
		destroyPreparedPets(preparedPets)
		destroyPreparedRewards(preparedRewards)
		return false, appendCode or "pet-append-failed"
	end

	if options.purchaseId then
		ReceiptService.MarkProcessed(profile, options.purchaseId)
	end

	if not saveProfile(profile) then
		restoreProfile(player, profile, snapshot, false)
		destroyPreparedPets(preparedPets)
		destroyPreparedRewards(preparedRewards)
		PlayerReplicaService.PublishProfile(player, profile)
		CurrencyService.Publish(player, profile)
		return false, "save-failed"
	end

	return finishTransaction(player, profile, tierNumber, options)
end

local function runTransaction(player, options)
	if options.skip == true then
		return runSkipTransaction(player, options)
	end
	return runResetTransaction(player, options)
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
		if OfflineProgressService.IsPending(player) then
			sendResult(player, requestId, false, "busy")
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
