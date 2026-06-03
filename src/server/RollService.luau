local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local InstanceVisibility = require(Server:WaitForChild("InstanceVisibility"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local SeedTools = require(Server:WaitForChild("SeedTools"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local RollChances = require(Shared:WaitForChild("RollChances"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))
local RollDropAreaBalance = require(Shared:WaitForChild("RollDropAreaBalance"))
local RollLuckBalance = require(Shared:WaitForChild("RollLuckBalance"))
local RollRewards = require(Shared:WaitForChild("RollRewards"))
local Seeds = require(Shared:WaitForChild("Seeds"))

local RollService = {}

local ROLL_DISTANCE = RollConfig.Button.InteractionDistance
local LUCK_UPGRADE_DISTANCE = RollConfig.Button.InteractionDistance
local DROP_AREA_UPGRADE_DISTANCE = RollConfig.Button.InteractionDistance
local PURCHASE_DISTANCE = 18
local PURCHASE_REQUEST_RATE_SECONDS = 0.35
local LUCK_REQUEST_RATE_SECONDS = 0.35
local DROP_AREA_REQUEST_RATE_SECONDS = 0.35
local ACTION_ROLL = "roll"
local ACTION_SHOW_OFFERS = "showOffers"
local ACTION_CLEAR_OFFER = "clearOffer"
local ACTION_CLEAR_OWNER_OFFERS = "clearOwnerOffers"

local DROP_AREA_VISIBILITY_OPTIONS = {
	RuntimeHiddenAsVisible = true,
	RuntimeHiddenVisualAsVisible = true,
}

local locks = {}
local rollCooldownUntil = {}
local lastPurchaseRequest = {}
local lastLuckRequest = {}
local lastDropAreaRequest = {}
local pendingOffers = {}
local nextOfferId = 0
local nextRollBatchId = 0
local boundRollButtons = setmetatable({}, { __mode = "k" })
local rng = Random.new()

local function userKey(player)
	return player and player.UserId or nil
end

local CrateRollEffect = Remotes.get(Remotes.Names.CrateRollEffect)
local CrateRollPurchaseRequest = Remotes.get(Remotes.Names.CrateRollPurchaseRequest)
local CrateRollPurchaseResult = Remotes.get(Remotes.Names.CrateRollPurchaseResult)
local RollLuckUpgradeRequest = Remotes.get(Remotes.Names.RollLuckUpgradeRequest)
local RollLuckUpgradeResult = Remotes.get(Remotes.Names.RollLuckUpgradeResult)
local RollDropAreaUpgradeRequest = Remotes.get(Remotes.Names.RollDropAreaUpgradeRequest)
local RollDropAreaUpgradeResult = Remotes.get(Remotes.Names.RollDropAreaUpgradeResult)

local function rootPart(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function isPlayerNearPart(player, part, maxDistance)
	local root = rootPart(player)
	return root ~= nil
		and part ~= nil
		and part:IsA("BasePart")
		and (root.Position - part.Position).Magnitude <= maxDistance
end

local function resolveRollButton(target)
	if not (target and target:IsA("BasePart") and target.Name == "Button") then
		return nil, "invalid-target"
	end

	local buttonFolder = target.Parent
	if not (buttonFolder and buttonFolder:IsA("Folder") and buttonFolder.Name == "Button") then
		return nil, "invalid-target"
	end

	local rollArea = buttonFolder.Parent
	if not (rollArea and rollArea:IsA("Folder") and rollArea.Name == "RollArea") then
		return nil, "invalid-target"
	end

	return target, nil
end

local function collectDropAreas(plot)
	local rollArea = plot and plot:FindFirstChild("RollArea")
	local buttonFolder = rollArea and rollArea:FindFirstChild("Button")
	if not (buttonFolder and buttonFolder:IsA("Folder")) then
		return nil, "missing-roll-button"
	end

	local dropAreas = {}
	for index = 1, RollDropAreaBalance.TotalPads do
		local area = buttonFolder:FindFirstChild("DropArea" .. tostring(index))
		local crateFloor = area and area:FindFirstChild("CrateFloor")
		if not (area and area:IsA("Model") and crateFloor and crateFloor:IsA("BasePart")) then
			return nil, "missing-drop-area"
		end
		dropAreas[#dropAreas + 1] = {
			index = index,
			area = area,
			crateFloor = crateFloor,
		}
	end

	return dropAreas, nil
end

local function unlockedDropAreas(profile, plot)
	local dropAreas, code = collectDropAreas(plot)
	if not dropAreas then
		return nil, code
	end

	local unlockedCount = RollDropAreaBalance.UnlockedCount(profile.Data.RollDropAreaLevel)
	local unlocked = {}
	for _, dropArea in ipairs(dropAreas) do
		if dropArea.index <= unlockedCount then
			unlocked[#unlocked + 1] = dropArea
		end
	end

	return unlocked, nil
end

local function rollButtonForPlot(plot)
	local rollArea = plot and plot:FindFirstChild("RollArea")
	local buttonFolder = rollArea and rollArea:FindFirstChild("Button")
	local buttonPart = buttonFolder and buttonFolder:FindFirstChild("Button")
	local resolvedButton, code = resolveRollButton(buttonPart)
	return resolvedButton, code
end

local function rollForButton(player, buttonPart, PlotService, PlayerDataService)
	local plot = PlotService.GetPlayerPlot(player)
	local profile = PlayerDataService.GetProfile(player)
	local ok, code = RollService.Roll(player, buttonPart, plot, profile)
	if not ok and code ~= "cooldown" and code ~= "busy" then
		NotificationService.Error(player, "Could not roll that crate.")
	end
end

local function collectRollPool()
	local entries = {}

	for _, seedId in ipairs(Seeds.AllSeedIds()) do
		local feedType = Seeds.FeedTypeFor(seedId)
		local feedClass = feedType and FeedMachines.GetClass(feedType)
		local chanceN = Seeds.RollChanceNFor(seedId)
		local price = Seeds.PriceFor(seedId)
		local rarity = Seeds.RarityFor(seedId)
		if RollChances.BaseWeightForChance(chanceN) and type(price) == "number" and price >= 0 then
			if feedClass == "Patch" or feedClass == "Tree" then
				entries[#entries + 1] = {
					id = RollRewards.RewardKey(RollRewards.Categories.Seed, seedId),
					category = RollRewards.Categories.Seed,
					rewardId = seedId,
					seedId = seedId,
					feedType = feedType,
					displayName = Seeds.DisplayNameFor(seedId),
					rarity = type(rarity) == "string" and Rarities.IsValid(rarity) and rarity or nil,
					chanceN = chanceN,
					price = math.floor(price),
				}
			end
		end
	end

	for _, miscId in ipairs(RollRewards.AllMiscRewardIds()) do
		local entry = RollRewards.MiscEntryFor(miscId)
		if entry then
			local chanceN = entry.chanceN
			local price = entry.price
			local rarity = entry.rarity
			if RollChances.BaseWeightForChance(chanceN) and type(price) == "number" and price >= 0 then
				entry.rarity = type(rarity) == "string" and Rarities.IsValid(rarity) and rarity or nil
				entry.price = math.floor(price)
				entries[#entries + 1] = entry
			end
		end
	end

	table.sort(entries, function(a, b)
		if a.chanceN ~= b.chanceN then
			return a.chanceN < b.chanceN
		end
		return tostring(a.id) < tostring(b.id)
	end)

	return entries
end

local function chanceTextForReward(weights, rewardKey)
	local selectedWeight = weights and weights[rewardKey]
	if type(selectedWeight) ~= "number" or selectedWeight <= 0 then
		return nil
	end

	local totalWeight = 0
	for _, weight in pairs(weights) do
		if type(weight) == "number" and weight > 0 then
			totalWeight += weight
		end
	end
	if totalWeight <= 0 then
		return nil
	end

	local oddsN = totalWeight / selectedWeight
	return "1 in " .. tostring(math.max(math.floor(oddsN + 0.5), 1))
end

local function rollRewardForCrate(crateId, profile)
	local entries = collectRollPool()
	if #entries == 0 then
		return nil, "empty-roll-pool"
	end

	local luckPercent = profile and RollLuckBalance.CurrentLuckPercent(profile.Data.RollLuckLevel) or 0
	local rewardWeights, weightCode = RollChances.ComputeRewardWeights(crateId, entries, luckPercent)
	if not rewardWeights then
		return nil, weightCode or "invalid-reward-weights"
	end

	local rewardKey = RollChances.WeightedChoice(rewardWeights, rng)
	if not rewardKey then
		return nil, "empty-roll-pool"
	end

	local entry = nil
	for _, candidate in ipairs(entries) do
		if candidate.id == rewardKey then
			entry = candidate
			break
		end
	end
	if not entry then
		return nil, "missing-roll-entry"
	end

	local rolled = table.clone(entry)
	rolled.rngChanceText = chanceTextForReward(rewardWeights, rewardKey) or ("1 in " .. tostring(entry.chanceN))
	return rolled
end

local function sendRollEffect(player, buttonPart, rollBatchId, offers)
	CrateRollEffect:FireClient(player, {
		action = ACTION_ROLL,
		rollBatchId = rollBatchId,
		ownerUserId = player.UserId,
		button = buttonPart,
		offers = offers,
	})
end

local function sendClearOwnerOffers(player)
	CrateRollEffect:FireAllClients({
		action = ACTION_CLEAR_OWNER_OFFERS,
		ownerUserId = player.UserId,
	})
end

local function sendPublicRollOffers(player, rollBatchId, offers)
	local key = userKey(player)
	local currentOffers = key and pendingOffers[key] or nil
	if not currentOffers then
		return
	end

	local activeOffers = {}
	for _, offer in ipairs(offers) do
		if currentOffers[offer.offerId] then
			activeOffers[#activeOffers + 1] = offer
		end
	end
	if #activeOffers == 0 then
		return
	end

	CrateRollEffect:FireAllClients({
		action = ACTION_SHOW_OFFERS,
		rollBatchId = rollBatchId,
		ownerUserId = player.UserId,
		offers = activeOffers,
	})
end

local function sendClearOffer(player, offerId)
	CrateRollEffect:FireAllClients({
		action = ACTION_CLEAR_OFFER,
		ownerUserId = player.UserId,
		offerId = offerId,
	})
end

local function sendPurchaseResult(player, offerId, success, code, extra)
	local payload = extra or {}
	payload.offerId = offerId
	payload.success = success
	payload.code = code
	CrateRollPurchaseResult:FireClient(player, payload)
end

local function sendLuckResult(player, requestId, success, code)
	RollLuckUpgradeResult:FireClient(player, {
		requestId = requestId,
		success = success,
		code = code,
	})
end

local function sendDropAreaResult(player, requestId, success, code)
	RollDropAreaUpgradeResult:FireClient(player, {
		requestId = requestId,
		success = success,
		code = code,
	})
end

local function clearPendingOffers(player)
	local key = userKey(player)
	if key ~= nil then
		pendingOffers[key] = nil
	end
end

local function removePendingOffer(player, offerId)
	local key = userKey(player)
	local offers = key and pendingOffers[key] or nil
	if not offers then
		return
	end
	offers[offerId] = nil
	if next(offers) == nil then
		pendingOffers[key] = nil
	end
end

local function activeOffer(player, offerId)
	local key = userKey(player)
	local offers = key and pendingOffers[key] or nil
	local offer = offers and offers[offerId]
	if not offer then
		return nil, "offer-unavailable"
	end
	return offer
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

local function consumePurchaseRate(player)
	return consumeRateLimit(lastPurchaseRequest, player, PURCHASE_REQUEST_RATE_SECONDS)
end

local function applySeedReward(player, profile, offer)
	local prepared, prepareCode = SeedTools.PrepareGrant(offer.seedId, 1)
	if not prepared then
		return false, prepareCode or "grant-failed"
	end

	local granted, grantCode = SeedTools.ApplyPrepared(player, profile, prepared)
	if not granted then
		SeedTools.DestroyPrepared(prepared)
		return false, grantCode or "grant-failed"
	end

	return true, "ok"
end

local function applyMiscReward(_player, _profile, _offer)
	-- Misc rewards are visual-only purchases until a concrete item behavior exists.
	return true, "ok"
end

local rewardPurchaseHandlers = {
	[RollRewards.Categories.Seed] = applySeedReward,
	[RollRewards.Categories.Misc] = applyMiscReward,
}

function RollService.ApplyDropAreaVisibility(plot, profileOrLevel)
	local level = profileOrLevel
	if type(profileOrLevel) == "table" and profileOrLevel.Data then
		level = profileOrLevel.Data.RollDropAreaLevel
	end
	local unlockedCount = RollDropAreaBalance.UnlockedCount(level)
	local dropAreas = collectDropAreas(plot)
	if not dropAreas then
		return false, "missing-drop-area"
	end

	for _, dropArea in ipairs(dropAreas) do
		InstanceVisibility.SetTreeActive(dropArea.area, dropArea.index <= unlockedCount, DROP_AREA_VISIBILITY_OPTIONS)
	end
	return true, "ok"
end

function RollService.Roll(player, target, plot, profile)
	local key = userKey(player)
	if key == nil then
		return false, "invalid-player"
	end

	local buttonPart, targetCode = resolveRollButton(target)
	if not buttonPart then
		return false, targetCode
	end
	if not (plot and target:IsDescendantOf(plot)) then
		return false, "wrong-plot"
	end
	if not profile then
		return false, "no-profile"
	end
	if not isPlayerNearPart(player, buttonPart, ROLL_DISTANCE) then
		return false, "too-far"
	end

	local dropAreas, dropAreaCode = unlockedDropAreas(profile, plot)
	if not dropAreas or #dropAreas == 0 then
		return false, dropAreaCode or "no-unlocked-drop-areas"
	end

	local now = os.clock()
	if now < (rollCooldownUntil[key] or 0) then
		return false, "cooldown"
	end
	if locks[key] then
		return false, "busy"
	end

	locks[key] = true
	local ok, success, codeOrOffers, batchIdOrNil, publicOffersOrNil = pcall(function()
		local offerMap = {}
		local effectOffers = {}
		local publicOffers = {}

		for _, dropArea in ipairs(dropAreas) do
			local crateId = RollChances.RollCrate(rng)
			if not crateId then
				return false, "crate-roll-failed"
			end

			local rolled, rollCode = rollRewardForCrate(crateId, profile)
			if not rolled then
				return false, rollCode or "reward-roll-failed"
			end

			nextOfferId += 1
			local offerId = nextOfferId
			local crate = RollChances.GetCrate(crateId)
			offerMap[offerId] = {
				offerId = offerId,
				category = rolled.category,
				rewardId = rolled.rewardId,
				seedId = rolled.seedId,
				feedType = rolled.feedType,
				miscId = rolled.miscId,
				displayName = rolled.displayName,
				price = rolled.price,
				crateFloor = dropArea.crateFloor,
				dropAreaIndex = dropArea.index,
			}
			effectOffers[#effectOffers + 1] = {
				offerId = offerId,
				rollBatchId = nil,
				ownerUserId = player.UserId,
				dropAreaIndex = dropArea.index,
				crateId = crateId,
				crateTemplateName = crate and crate.TemplateName or crateId,
				crateFloor = dropArea.crateFloor,
				category = rolled.category,
				rewardId = rolled.rewardId,
				seedId = rolled.seedId,
				feedType = rolled.feedType,
				miscId = rolled.miscId,
				displayName = rolled.displayName,
				rarity = rolled.rarity,
				price = rolled.price,
				chanceN = rolled.chanceN,
				rngChanceText = rolled.rngChanceText,
			}
			publicOffers[#publicOffers + 1] = {
				offerId = offerId,
				rollBatchId = nil,
				ownerUserId = player.UserId,
				dropAreaIndex = dropArea.index,
				crateFloor = dropArea.crateFloor,
				category = rolled.category,
				rewardId = rolled.rewardId,
				seedId = rolled.seedId,
				feedType = rolled.feedType,
				miscId = rolled.miscId,
				displayName = rolled.displayName,
				rarity = rolled.rarity,
				price = rolled.price,
				chanceN = rolled.chanceN,
				rngChanceText = rolled.rngChanceText,
			}
		end

		nextRollBatchId += 1
		local rollBatchId = nextRollBatchId
		for _, offer in ipairs(effectOffers) do
			offer.rollBatchId = rollBatchId
		end
		for _, offer in ipairs(publicOffers) do
			offer.rollBatchId = rollBatchId
		end

		clearPendingOffers(player)
		pendingOffers[key] = offerMap
		rollCooldownUntil[key] = os.clock() + RollConfig.RollVisualDuration()
		return true, effectOffers, rollBatchId, publicOffers
	end)
	locks[key] = nil

	if not ok then
		warn("[RollService] Roll failed: " .. tostring(success))
		TelemetryService.Warn("crate_roll_failed", TelemetryService.ForPlayer(player, {
			reason = "server-error",
		}))
		return false, "server-error"
	end
	if not success then
		TelemetryService.Warn("crate_roll_failed", TelemetryService.ForPlayer(player, {
			reason = codeOrOffers,
		}))
		return false, codeOrOffers
	end

	local effectOffers = codeOrOffers
	sendClearOwnerOffers(player)
	sendRollEffect(player, buttonPart, batchIdOrNil, effectOffers)
	task.delay(RollConfig.RollVisualDuration(), function()
		RuntimeGuard.Run("RollService.SendPublicRollOffersDelayed", sendPublicRollOffers, player, batchIdOrNil, publicOffersOrNil or {})
	end)
	TelemetryService.Record("crate_roll_created", TelemetryService.ForPlayer(player, {
		batchId = batchIdOrNil,
		offerCount = #effectOffers,
		unlockedPadCount = #dropAreas,
	}))
	return true, "ok"
end

function RollService.Purchase(player, offerId, profile)
	local key = userKey(player)
	if key == nil then
		return false, "invalid-player"
	end

	if not consumePurchaseRate(player) then
		sendPurchaseResult(player, type(offerId) == "number" and offerId or nil, false, "rate-limited")
		return false, "rate-limited"
	end
	if type(offerId) ~= "number" then
		sendPurchaseResult(player, offerId, false, "invalid-offer")
		TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
			reason = "invalid-offer",
			offerId = tostring(offerId),
		}))
		return false, "invalid-offer"
	end
	if locks[key] then
		sendPurchaseResult(player, offerId, false, "busy")
		return false, "busy"
	end

	local offer, offerCode = activeOffer(player, offerId)
	if not offer then
		NotificationService.Error(player, "This roll offer is no longer available.")
		sendPurchaseResult(player, offerId, false, offerCode)
		TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
			reason = offerCode,
			offerId = offerId,
		}))
		return false, offerCode
	end
	if not profile then
		NotificationService.Error(player, "Could not buy this roll yet.")
		sendPurchaseResult(player, offerId, false, "no-profile")
		TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
			reason = "no-profile",
			offerId = offerId,
			category = offer.category,
			rewardId = offer.rewardId,
			seedId = offer.seedId,
			feedType = offer.feedType,
			price = offer.price,
		}))
		return false, "no-profile"
	end
	if not isPlayerNearPart(player, offer.crateFloor, PURCHASE_DISTANCE) then
		NotificationService.Error(player, "Move closer to the rolled item to buy it.")
		sendPurchaseResult(player, offerId, false, "too-far")
		TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
			reason = "too-far",
			offerId = offerId,
			category = offer.category,
			rewardId = offer.rewardId,
			seedId = offer.seedId,
			feedType = offer.feedType,
			price = offer.price,
		}))
		return false, "too-far"
	end

	locks[key] = true
	local spentAmount = 0
	local ok, success, code, currencyOrNil = pcall(function()
		local spent, spendCode, currency = CurrencyService.TrySpend(player, profile, offer.price, true)
		if not spent then
			return false, spendCode or "insufficient-currency", currency
		end
		spentAmount = offer.price

		local handler = rewardPurchaseHandlers[offer.category]
		if not handler then
			CurrencyService.Add(player, profile, offer.price, true)
			spentAmount = 0
			return false, "unsupported-reward", currency
		end

		local granted, grantCode = handler(player, profile, offer)
		if not granted then
			CurrencyService.Add(player, profile, offer.price, true)
			spentAmount = 0
			return false, grantCode or "grant-failed"
		end

		removePendingOffer(player, offerId)
		spentAmount = 0
		return true, "ok", profile.Data.Currency
	end)
	locks[key] = nil

	if not ok then
		if spentAmount > 0 then
			CurrencyService.Add(player, profile, spentAmount, true)
		end
		PlayerReplicaService.PublishProfile(player, profile)
		warn("[RollService] Purchase failed: " .. tostring(success))
		sendPurchaseResult(player, offerId, false, "server-error")
		TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
			reason = "server-error",
			offerId = offerId,
			category = offer.category,
			rewardId = offer.rewardId,
			seedId = offer.seedId,
			feedType = offer.feedType,
			price = offer.price,
		}))
		return false, "server-error"
	end

	if success then
		NotificationService.Success(player, string.format("Purchased %s!", offer.displayName or offer.rewardId or offer.feedType))
		PlayerReplicaService.PublishProfile(player, profile)
		sendPurchaseResult(player, offerId, true, "ok", {
			category = offer.category,
			rewardId = offer.rewardId,
			seedId = offer.seedId,
			feedType = offer.feedType,
			miscId = offer.miscId,
			currency = currencyOrNil,
		})
		sendClearOffer(player, offerId)
		TelemetryService.Record("crate_roll_purchase_succeeded", TelemetryService.ForPlayer(player, {
			offerId = offerId,
			category = offer.category,
			rewardId = offer.rewardId,
			seedId = offer.seedId,
			feedType = offer.feedType,
			price = offer.price,
			currency = currencyOrNil,
		}))
		return true, "ok"
	end

	if code == "insufficient-currency" then
		NotificationService.Error(player, "Not enough currency for this roll.")
	elseif code == "too-far" then
		NotificationService.Error(player, "Move closer to the rolled item to buy it.")
	else
		NotificationService.Error(player, "Could not buy this roll.")
	end
	PlayerReplicaService.PublishProfile(player, profile)
	sendPurchaseResult(player, offerId, false, code)
	TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
		reason = code,
		offerId = offerId,
		category = offer.category,
		rewardId = offer.rewardId,
		seedId = offer.seedId,
		feedType = offer.feedType,
		price = offer.price,
		currency = currencyOrNil,
	}))
	return false, code
end

function RollService.PurchaseLuckUpgrade(player, profile, plot, requestId)
	local key = userKey(player)
	if key == nil then
		return false, "invalid-player"
	end

	if type(requestId) ~= "number" then
		requestId = nil
	end
	if not consumeRateLimit(lastLuckRequest, player, LUCK_REQUEST_RATE_SECONDS) then
		sendLuckResult(player, requestId, false, "rate-limited")
		return false, "rate-limited"
	end
	if locks[key] then
		sendLuckResult(player, requestId, false, "busy")
		return false, "busy"
	end
	if not profile then
		NotificationService.Error(player, "Could not upgrade luck yet.")
		sendLuckResult(player, requestId, false, "no-profile")
		TelemetryService.Warn("roll_luck_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "no-profile",
		}))
		return false, "no-profile"
	end
	if not plot then
		NotificationService.Error(player, "Could not find your plot.")
		sendLuckResult(player, requestId, false, "no-plot")
		TelemetryService.Warn("roll_luck_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "no-plot",
		}))
		return false, "no-plot"
	end

	local buttonPart, buttonCode = rollButtonForPlot(plot)
	if not buttonPart then
		sendLuckResult(player, requestId, false, buttonCode or "missing-roll-button")
		TelemetryService.Warn("roll_luck_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = buttonCode or "missing-roll-button",
		}))
		return false, buttonCode or "missing-roll-button"
	end
	if not isPlayerNearPart(player, buttonPart, LUCK_UPGRADE_DISTANCE) then
		NotificationService.Error(player, "Move closer to the roll button to upgrade luck.")
		sendLuckResult(player, requestId, false, "too-far")
		TelemetryService.Warn("roll_luck_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "too-far",
		}))
		return false, "too-far"
	end

	local currentLevel = RollLuckBalance.LevelFor(profile.Data.RollLuckLevel)
	local nextUpgrade, nextLevel = RollLuckBalance.NextUpgrade(currentLevel)
	if not nextUpgrade then
		NotificationService.Error(player, "Luck is already maxed.")
		sendLuckResult(player, requestId, false, "max-level")
		return false, "max-level"
	end

	local price = math.max(math.floor(tonumber(nextUpgrade.price) or 0), 0)
	locks[key] = true
	local spentAmount = 0
	local ok, success, code, currencyOrNil = pcall(function()
		local freshLevel = RollLuckBalance.LevelFor(profile.Data.RollLuckLevel)
		local freshUpgrade, freshNextLevel = RollLuckBalance.NextUpgrade(freshLevel)
		if not freshUpgrade then
			return false, "max-level", profile.Data.Currency
		end

		local freshPrice = math.max(math.floor(tonumber(freshUpgrade.price) or 0), 0)
		local spent, spendCode, currency = CurrencyService.TrySpend(player, profile, freshPrice, true)
		if not spent then
			return false, spendCode or "insufficient-currency", currency
		end
		spentAmount = freshPrice

		profile.Data.RollLuckLevel = freshNextLevel
		spentAmount = 0
		return true, "ok", profile.Data.Currency
	end)
	locks[key] = nil

	if not ok then
		profile.Data.RollLuckLevel = currentLevel
		if spentAmount > 0 then
			CurrencyService.Add(player, profile, spentAmount, true)
		end
		PlayerReplicaService.PublishProfile(player, profile)
		warn("[RollService] Luck upgrade failed: " .. tostring(success))
		sendLuckResult(player, requestId, false, "server-error")
		TelemetryService.Warn("roll_luck_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "server-error",
			level = currentLevel,
			price = price,
		}))
		return false, "server-error"
	end

	if success then
		local updatedLuck = RollLuckBalance.CurrentLuckPercent(profile.Data.RollLuckLevel)
		NotificationService.Success(player, string.format("Luck upgraded to +%d%%!", updatedLuck))
		PlayerReplicaService.PublishProfile(player, profile)
		sendLuckResult(player, requestId, true, "ok")
		TelemetryService.Record("roll_luck_upgrade_succeeded", TelemetryService.ForPlayer(player, {
			level = profile.Data.RollLuckLevel,
			luckPercent = updatedLuck,
			price = price,
			currency = currencyOrNil,
		}))
		return true, "ok"
	end

	if code == "insufficient-currency" then
		NotificationService.Error(player, "Not enough currency for this luck upgrade.")
	elseif code == "max-level" then
		NotificationService.Error(player, "Luck is already maxed.")
	else
		NotificationService.Error(player, "Could not upgrade luck.")
	end
	PlayerReplicaService.PublishProfile(player, profile)
	sendLuckResult(player, requestId, false, code)
	TelemetryService.Warn("roll_luck_upgrade_failed", TelemetryService.ForPlayer(player, {
		reason = code,
		level = currentLevel,
		price = price,
		currency = currencyOrNil,
	}))
	return false, code
end

function RollService.PurchaseDropAreaUpgrade(player, profile, plot, requestId)
	local key = userKey(player)
	if key == nil then
		return false, "invalid-player"
	end

	if type(requestId) ~= "number" then
		requestId = nil
	end
	if not consumeRateLimit(lastDropAreaRequest, player, DROP_AREA_REQUEST_RATE_SECONDS) then
		sendDropAreaResult(player, requestId, false, "rate-limited")
		return false, "rate-limited"
	end
	if locks[key] then
		sendDropAreaResult(player, requestId, false, "busy")
		return false, "busy"
	end
	if not profile then
		NotificationService.Error(player, "Could not upgrade drop areas yet.")
		sendDropAreaResult(player, requestId, false, "no-profile")
		TelemetryService.Warn("roll_drop_area_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "no-profile",
		}))
		return false, "no-profile"
	end
	if not plot then
		NotificationService.Error(player, "Could not find your plot.")
		sendDropAreaResult(player, requestId, false, "no-plot")
		TelemetryService.Warn("roll_drop_area_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "no-plot",
		}))
		return false, "no-plot"
	end

	local buttonPart, buttonCode = rollButtonForPlot(plot)
	if not buttonPart then
		sendDropAreaResult(player, requestId, false, buttonCode or "missing-roll-button")
		TelemetryService.Warn("roll_drop_area_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = buttonCode or "missing-roll-button",
		}))
		return false, buttonCode or "missing-roll-button"
	end
	if not isPlayerNearPart(player, buttonPart, DROP_AREA_UPGRADE_DISTANCE) then
		NotificationService.Error(player, "Move closer to the roll button to upgrade drop areas.")
		sendDropAreaResult(player, requestId, false, "too-far")
		TelemetryService.Warn("roll_drop_area_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "too-far",
		}))
		return false, "too-far"
	end

	local currentLevel = RollDropAreaBalance.LevelFor(profile.Data.RollDropAreaLevel)
	local nextUpgrade = RollDropAreaBalance.NextUpgrade(currentLevel)
	if not nextUpgrade then
		NotificationService.Error(player, "Drop areas are already maxed.")
		sendDropAreaResult(player, requestId, false, "max-level")
		return false, "max-level"
	end

	local price = math.max(math.floor(tonumber(nextUpgrade.price) or 0), 0)
	locks[key] = true
	local spentAmount = 0
	local ok, success, code, currencyOrNil, levelOrNil = pcall(function()
		local freshLevel = RollDropAreaBalance.LevelFor(profile.Data.RollDropAreaLevel)
		local freshUpgrade, freshNextLevel = RollDropAreaBalance.NextUpgrade(freshLevel)
		if not freshUpgrade then
			return false, "max-level", profile.Data.Currency, freshLevel
		end

		local freshPrice = math.max(math.floor(tonumber(freshUpgrade.price) or 0), 0)
		local spent, spendCode, currency = CurrencyService.TrySpend(player, profile, freshPrice, true)
		if not spent then
			return false, spendCode or "insufficient-currency", currency, freshLevel
		end
		spentAmount = freshPrice

		profile.Data.RollDropAreaLevel = freshNextLevel
		local applied, applyCode = RollService.ApplyDropAreaVisibility(plot, profile)
		if not applied then
			profile.Data.RollDropAreaLevel = freshLevel
			CurrencyService.Add(player, profile, freshPrice, true)
			spentAmount = 0
			return false, applyCode or "visibility-failed", profile.Data.Currency, freshLevel
		end

		spentAmount = 0
		return true, "ok", profile.Data.Currency, freshNextLevel
	end)
	locks[key] = nil

	if not ok then
		profile.Data.RollDropAreaLevel = currentLevel
		RuntimeGuard.Run("RollService.RestoreDropAreaVisibility", RollService.ApplyDropAreaVisibility, plot, profile)
		if spentAmount > 0 then
			CurrencyService.Add(player, profile, spentAmount, true)
		end
		PlayerReplicaService.PublishProfile(player, profile)
		warn("[RollService] Drop area upgrade failed: " .. tostring(success))
		sendDropAreaResult(player, requestId, false, "server-error")
		TelemetryService.Warn("roll_drop_area_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "server-error",
			level = currentLevel,
			price = price,
		}))
		return false, "server-error"
	end

	if success then
		local unlockedCount = RollDropAreaBalance.UnlockedCount(profile.Data.RollDropAreaLevel)
		NotificationService.Success(player, string.format("Unlocked drop area %d/%d!", unlockedCount, RollDropAreaBalance.TotalPads))
		PlayerReplicaService.PublishProfile(player, profile)
		sendDropAreaResult(player, requestId, true, "ok")
		TelemetryService.Record("roll_drop_area_upgrade_succeeded", TelemetryService.ForPlayer(player, {
			level = levelOrNil,
			unlockedPadCount = unlockedCount,
			price = price,
			currency = currencyOrNil,
		}))
		return true, "ok"
	end

	if code == "insufficient-currency" then
		NotificationService.Error(player, "Not enough currency for this drop area upgrade.")
	elseif code == "max-level" then
		NotificationService.Error(player, "Drop areas are already maxed.")
	else
		NotificationService.Error(player, "Could not upgrade drop areas.")
	end
	PlayerReplicaService.PublishProfile(player, profile)
	sendDropAreaResult(player, requestId, false, code)
	TelemetryService.Warn("roll_drop_area_upgrade_failed", TelemetryService.ForPlayer(player, {
		reason = code,
		level = currentLevel,
		price = price,
		currency = currencyOrNil,
	}))
	return false, code
end

local function bindRollButton(buttonPart, PlotService, PlayerDataService)
	if boundRollButtons[buttonPart] then
		return
	end

	local resolvedButton = resolveRollButton(buttonPart)
	if not resolvedButton then
		return
	end

	local clickDetector = buttonPart:FindFirstChild("RollClickDetector")
	if not clickDetector then
		clickDetector = Instance.new("ClickDetector")
		clickDetector.Name = "RollClickDetector"
		clickDetector.Parent = buttonPart
	elseif not clickDetector:IsA("ClickDetector") then
		return
	end
	clickDetector.MaxActivationDistance = ROLL_DISTANCE

	local connections = {}
	connections[#connections + 1] = RuntimeGuard.Connect(clickDetector.MouseClick, "RollService.RollButtonClick", function(player)
		rollForButton(player, buttonPart, PlotService, PlayerDataService)
	end)
	boundRollButtons[buttonPart] = connections

	connections[#connections + 1] = RuntimeGuard.Connect(buttonPart.Destroying, "RollService.RollButtonDestroying", function()
		local activeConnections = boundRollButtons[buttonPart]
		if activeConnections then
			for _, connection in ipairs(activeConnections) do
				connection:Disconnect()
			end
			boundRollButtons[buttonPart] = nil
		end
	end)
end

local function scanRollButtons(PlotService, PlayerDataService)
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("BasePart") then
			bindRollButton(descendant, PlotService, PlayerDataService)
		end
	end
end

function RollService.Start()
	local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
	local PlotService = require(Server:WaitForChild("PlotService"))

	scanRollButtons(PlotService, PlayerDataService)
	RuntimeGuard.Connect(workspace.DescendantAdded, "RollService.DescendantAdded", function(descendant)
		if descendant:IsA("BasePart") then
			bindRollButton(descendant, PlotService, PlayerDataService)
		end
	end)

	RuntimeGuard.Connect(CrateRollPurchaseRequest.OnServerEvent, "RollService.CrateRollPurchaseRequest", function(player, offerId)
		local profile = PlayerDataService.GetProfile(player)
		RollService.Purchase(player, offerId, profile)
	end)

	RuntimeGuard.Connect(RollLuckUpgradeRequest.OnServerEvent, "RollService.RollLuckUpgradeRequest", function(player, requestId)
		local profile = PlayerDataService.GetProfile(player)
		local plot = PlotService.GetPlayerPlot(player)
		RollService.PurchaseLuckUpgrade(player, profile, plot, requestId)
	end)

	RuntimeGuard.Connect(RollDropAreaUpgradeRequest.OnServerEvent, "RollService.RollDropAreaUpgradeRequest", function(player, requestId)
		local profile = PlayerDataService.GetProfile(player)
		local plot = PlotService.GetPlayerPlot(player)
		RollService.PurchaseDropAreaUpgrade(player, profile, plot, requestId)
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "RollService.PlayerRemoving", function(player)
		sendClearOwnerOffers(player)
		local key = userKey(player)
		if key == nil then return end
		locks[key] = nil
		rollCooldownUntil[key] = nil
		lastPurchaseRequest[key] = nil
		lastLuckRequest[key] = nil
		lastDropAreaRequest[key] = nil
		pendingOffers[key] = nil
	end)
end

return RollService
