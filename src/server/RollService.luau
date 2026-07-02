local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local GamePassService = require(Server:WaitForChild("GamePassService"))
local InstanceVisibility = require(Server:WaitForChild("InstanceVisibility"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local RollOfferPersistence = require(Server:WaitForChild("RollOfferPersistence"))
local SeedTools = require(Server:WaitForChild("SeedTools"))
local ServerLuckService = require(Server:WaitForChild("ServerLuckService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AutoRollConfig = require(Shared:WaitForChild("AutoRollConfig"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
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
local ROLL_CLICK_DISTANCE = RollConfig.Button.ClickDistance or RollConfig.Button.InteractionDistance
local LUCK_UPGRADE_DISTANCE = RollConfig.Button.InteractionDistance
local DROP_AREA_UPGRADE_DISTANCE = RollConfig.Button.InteractionDistance
local PURCHASE_DISTANCE = 18
local PURCHASE_REQUEST_RATE_SECONDS = 0.35
local AUTO_ROLL_REQUEST_RATE_SECONDS = AutoRollConfig.RequestRateSeconds
local AUTO_ROLL_RETRY_SECONDS = AutoRollConfig.RetrySeconds
local LUCK_REQUEST_RATE_SECONDS = 0.35
local DROP_AREA_REQUEST_RATE_SECONDS = 0.35
local ACTION_ROLL = "roll"
local ACTION_SHOW_OFFERS = "showOffers"
local ACTION_RESTORE_OFFERS = "restoreOffers"
local ACTION_CLEAR_OFFER = "clearOffer"
local ACTION_CLEAR_OWNER_OFFERS = "clearOwnerOffers"

-- Admin party drops are a separate offer track: they never displace normal
-- offers (or vice versa), and clients scope roll tokens and owner-wide visual
-- wipes per track. A nil track on clearOwnerOffers means "both".
local TRACK_NORMAL = "normal"
local TRACK_ADMIN = "admin"
local RARE_TEASE_RARITIES = {
	Rarities.Legendary,
	Rarities.Mythical,
	Rarities.Secret,
}

local DROP_AREA_VISIBILITY_OPTIONS = {
	RuntimeHiddenAsVisible = true,
	RuntimeHiddenVisualAsVisible = true,
}

-- Admin party: control-plane-toggled bonus pad plus admin-only crate drops.
local ADMIN_PARTY_FOLDER_NAME = "AdminParty"
local ADMIN_PARTY_DROP_AREA_NAME = "AdminPartyDropArea"
-- Pads only show on occupied plots (PlotService's OwnerUserId attribute).
-- Emitters stay replicated-off; AdminPartyPadController enables them locally
-- for the plot owner and plays the entrance drop when the counter bumps.
local ADMIN_PAD_VISIBILITY_OPTIONS = {
	RuntimeHiddenAsVisible = true,
	RuntimeHiddenVisualAsVisible = true,
	ParticleEmittersAlwaysOff = true,
}
local ADMIN_PAD_ACTIVE_ATTRIBUTE = "AdminPartyActive"
local ADMIN_PAD_ENTRANCE_ATTRIBUTE = "AdminPartyEntrance"
local PLOT_OWNER_ATTRIBUTE = "OwnerUserId"
local ADMIN_DROP_AREA_INDEX = 0
local ADMIN_DROP_NOTICE = "yacti has dropped a crate on your farm!"

-- New-player hook: profile.Data.PurpleAngelCrateGuaranteeAt marks which
-- lifetime crate is a guaranteed PurpleAngelLuckyBlock (0 = none/consumed).
local GUARANTEED_NEW_PLAYER_CRATE_ID = "PurpleAngelLuckyBlock"

local locks = {}
local rollCooldownUntil = {}
local lastPurchaseRequest = {}
local lastAutoRollRequest = {}
local lastLuckRequest = {}
local lastDropAreaRequest = {}
local pendingOffers = {}
local adminPendingOffers = {}
local autoRollSessions = {}
local nextOfferId = 0
local nextRollBatchId = 0
local nextAutoRollToken = 0
local boundRollButtons = setmetatable({}, { __mode = "k" })
local rng = Random.new()
local PlayerDataServiceRef = nil
local PlotServiceRef = nil
local EventEligibilityRef = nil
local adminPadActive = false

local function userKey(player)
	return player and player.UserId or nil
end

local function finiteNumber(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	return value
end

local function rollLuckBreakdown(player, profile)
	local baseLuckPercent = profile and RollLuckBalance.CurrentLuckPercent(profile.Data.RollLuckLevel) or 0
	local gamePassLuckPercent = GamePassService.LuckBonusPercent(player)
	return baseLuckPercent, gamePassLuckPercent, baseLuckPercent + gamePassLuckPercent
end

local CrateRollEffect = Remotes.get(Remotes.Names.CrateRollEffect)
local CrateRollPurchaseRequest = Remotes.get(Remotes.Names.CrateRollPurchaseRequest)
local CrateRollPurchaseResult = Remotes.get(Remotes.Names.CrateRollPurchaseResult)
local AutoRollRequest = Remotes.get(Remotes.Names.AutoRollRequest)
local AutoRollState = Remotes.get(Remotes.Names.AutoRollState)
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

local function adminPartyPadFor(plot)
	local folder = plot and plot:FindFirstChild(ADMIN_PARTY_FOLDER_NAME)
	local area = folder and folder:FindFirstChild(ADMIN_PARTY_DROP_AREA_NAME)
	local crateFloor = area and area:FindFirstChild("CrateFloor")
	if area and crateFloor and crateFloor:IsA("BasePart") then
		return area, crateFloor
	end
	return nil, nil
end

local function allPlots()
	local plotsFolder = workspace:FindFirstChild("Plots")
	return plotsFolder and plotsFolder:GetChildren() or {}
end

-- The pad hides from players still in onboarding (drops already exclude them
-- via EventEligibility). Fail-closed: an occupied plot whose profile isn't
-- readable yet counts as onboarding. Reveal paths after that: the post-load
-- ApplyDropAreaVisibility call in the join flow, and the OnCompleted callback
-- when the tutorial finishes mid-party (reconcile is revision-gated and does
-- NOT reapply unchanged state).
local function plotOwnerReadyForAdminPad(plot)
	local userId = plot:GetAttribute(PLOT_OWNER_ATTRIBUTE)
	if userId == nil then
		return false
	end
	local player = Players:GetPlayerByUserId(userId)
	local profile = player and PlayerDataServiceRef and PlayerDataServiceRef.GetProfile(player) or nil
	return profile ~= nil and not OnboardingService.IsActive(profile)
end

local function applyAdminPadVisibility(plot)
	local area = adminPartyPadFor(plot)
	if area then
		local shouldShow = adminPadActive and plotOwnerReadyForAdminPad(plot)
		InstanceVisibility.SetTreeActive(area, shouldShow, ADMIN_PAD_VISIBILITY_OPTIONS)
		area:SetAttribute(ADMIN_PAD_ACTIVE_ATTRIBUTE, shouldShow)
	end
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
	local ok, code = RollService.Roll(player, buttonPart, plot, profile, ROLL_CLICK_DISTANCE)
	if not ok and code ~= "cooldown" and code ~= "busy" and code ~= "tutorial-buy-pending" then
		NotificationService.Error(player, "Could not roll that crate")
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

local function seedPreviewPayload(entry)
	return {
		category = RollRewards.Categories.Seed,
		rewardId = entry.rewardId,
		seedId = entry.seedId,
		feedType = entry.feedType,
		displayName = entry.displayName,
		rarity = entry.rarity,
		price = entry.price,
		chanceN = entry.chanceN,
		rngChanceText = NumberFormatter.ChanceN(entry.chanceN),
	}
end

local function collectSeedEntries(entries)
	local seedEntries = {}
	for _, entry in ipairs(entries) do
		if entry.category == RollRewards.Categories.Seed then
			seedEntries[#seedEntries + 1] = entry
		end
	end
	return seedEntries
end

local function collectCategoryEntries(entries, category)
	local categoryEntries = {}
	for _, entry in ipairs(entries or {}) do
		if entry.category == category then
			categoryEntries[#categoryEntries + 1] = entry
		end
	end
	return categoryEntries
end

local function randomSeedEntry(seedEntries, usedSeedIds, rarity, allowUsed)
	local candidates = {}
	for _, entry in ipairs(seedEntries) do
		local matchesRarity = rarity == nil or entry.rarity == rarity
		local isUsed = usedSeedIds and usedSeedIds[entry.seedId] == true
		if matchesRarity and (allowUsed or not isUsed) then
			candidates[#candidates + 1] = entry
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

local function weightedSeedEntry(crateId, player, profile, seedEntries, usedSeedIds, allowUsed)
	local candidates = {}
	for _, entry in ipairs(seedEntries) do
		local isUsed = usedSeedIds and usedSeedIds[entry.seedId] == true
		if allowUsed or not isUsed then
			candidates[#candidates + 1] = entry
		end
	end
	if #candidates == 0 then
		return nil
	end

	local _, _, luckPercent = rollLuckBreakdown(player, profile)
	local serverLuckMultiplier = ServerLuckService.CurrentMultiplier()
	local rewardWeights = RollChances.ComputeRewardWeights(crateId, candidates, luckPercent, serverLuckMultiplier, {
		includeFallback = false,
	})
	if not rewardWeights then
		return nil
	end

	local rewardKey = RollChances.WeightedChoice(rewardWeights, rng)
	if not rewardKey then
		return nil
	end
	for _, entry in ipairs(candidates) do
		if entry.id == rewardKey then
			return entry
		end
	end
	return nil
end

local function weightedRareTeaseRarity(availableRarities)
	local weights = RollConfig.Reveal.SeedRareTeaseWeights
	local totalWeight = 0
	for _, rarity in ipairs(RARE_TEASE_RARITIES) do
		if not availableRarities or availableRarities[rarity] == true then
			totalWeight += tonumber(weights[rarity]) or 0
		end
	end
	if totalWeight <= 0 then
		return nil
	end

	local pick = rng:NextNumber(0, totalWeight)
	local cumulative = 0
	for _, rarity in ipairs(RARE_TEASE_RARITIES) do
		if not availableRarities or availableRarities[rarity] == true then
			cumulative += tonumber(weights[rarity]) or 0
			if pick <= cumulative then
				return rarity
			end
		end
	end
	return RARE_TEASE_RARITIES[#RARE_TEASE_RARITIES]
end

local function availableRareTeaseRarities(seedEntries, usedSeedIds, allowUsed)
	local available = {}
	for _, rarity in ipairs(RARE_TEASE_RARITIES) do
		if randomSeedEntry(seedEntries, usedSeedIds, rarity, allowUsed) then
			available[rarity] = true
		end
	end
	return next(available) ~= nil and available or nil
end

local function rareTeaseSeedEntry(seedEntries, usedSeedIds)
	local rarity = weightedRareTeaseRarity()
	local entry = rarity and randomSeedEntry(seedEntries, usedSeedIds, rarity, false) or nil
	if entry then
		return entry
	end

	local fallbackRarities = availableRareTeaseRarities(seedEntries, usedSeedIds, false)
	local fallbackRarity = fallbackRarities and weightedRareTeaseRarity(fallbackRarities) or nil
	entry = fallbackRarity and randomSeedEntry(seedEntries, usedSeedIds, fallbackRarity, false) or nil
	if entry then
		return entry
	end

	fallbackRarities = availableRareTeaseRarities(seedEntries, usedSeedIds, true)
	fallbackRarity = fallbackRarities and weightedRareTeaseRarity(fallbackRarities) or nil
	return fallbackRarity and randomSeedEntry(seedEntries, usedSeedIds, fallbackRarity, true) or nil
end

local function rollSeedPreviewCount()
	local options = RollConfig.Reveal.SeedPreviewCountOptions
	local candidates = {}
	if type(options) == "table" then
		for _, count in ipairs(options) do
			count = tonumber(count)
			if type(count) == "number" and count == count and math.abs(count) < math.huge and count > 0 then
				candidates[#candidates + 1] = math.floor(count)
			end
		end
	end
	if #candidates == 0 then
		local fallback = RollConfig.MaxSeedPreviewCount()
		return fallback > 0 and fallback or 0
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

local function buildSeedPreviewSeeds(rolled, entries, crateId, player, profile)
	if rolled.category ~= RollRewards.Categories.Seed then
		return nil
	end

	local count = rollSeedPreviewCount()
	if count <= 0 then
		return nil
	end

	local seedEntries = collectSeedEntries(entries)
	if #seedEntries == 0 then
		return nil
	end

	local previews = table.create(count)
	local usedSeedIds = {}
	if type(rolled.seedId) == "string" then
		usedSeedIds[rolled.seedId] = true
	end

	for index = 1, count do
		local entry = nil
		if rng:NextNumber(0, 1) < RollConfig.Reveal.SeedRareTeaseChance then
			entry = rareTeaseSeedEntry(seedEntries, usedSeedIds)
		end
		entry = entry
			or weightedSeedEntry(crateId, player, profile, seedEntries, usedSeedIds, false)
			or weightedSeedEntry(crateId, player, profile, seedEntries, usedSeedIds, true)
		if entry then
			previews[index] = entry
			usedSeedIds[entry.seedId] = true
		end
	end

	local payloads = table.create(count)
	for index = 1, count do
		local entry = previews[index]
		if entry then
			payloads[#payloads + 1] = seedPreviewPayload(entry)
		end
	end
	return #payloads > 0 and payloads or nil
end

local function rollEntryForSeed(seedId, entries)
	if type(seedId) ~= "string" or seedId == "" then
		return nil, "invalid-seed"
	end
	local rewardKey = RollRewards.RewardKey(RollRewards.Categories.Seed, seedId)
	for _, entry in ipairs(entries or collectRollPool()) do
		if entry.id == rewardKey then
			local rolled = table.clone(entry)
			rolled.rngChanceText = "Tutorial reward"
			rolled.tutorialGuaranteed = true
			return rolled
		end
	end
	return nil, "missing-tutorial-seed"
end

local function rollRewardForCrate(crateId, player, profile, entries)
	entries = entries or collectRollPool()
	if #entries == 0 then
		return nil, "empty-roll-pool"
	end

	local _, _, luckPercent = rollLuckBreakdown(player, profile)
	local serverLuckMultiplier = ServerLuckService.CurrentMultiplier()

	local categoryWeights, categoryCode = RollChances.ComputeCategoryWeights(entries)
	if not categoryWeights then
		return nil, categoryCode or "empty-category-pool"
	end
	local category = RollChances.WeightedChoice(categoryWeights, rng)
	if not category then
		return nil, "category-roll-failed"
	end

	local categoryEntries = collectCategoryEntries(entries, category)
	if #categoryEntries == 0 then
		return nil, "empty-category-pool"
	end

	local rewardWeights, weightCode = RollChances.ComputeRewardWeights(crateId, categoryEntries, luckPercent, serverLuckMultiplier)
	if not rewardWeights then
		return nil, weightCode or "invalid-reward-weights"
	end

	local rewardKey = RollChances.WeightedChoice(rewardWeights, rng)
	if not rewardKey then
		return nil, "empty-roll-pool"
	end

	local entry = nil
	for _, candidate in ipairs(categoryEntries) do
		if candidate.id == rewardKey then
			entry = candidate
			break
		end
	end
	if not entry then
		return nil, "missing-roll-entry"
	end

	local rolled = table.clone(entry)
	local rewardPercentages = RollChances.ToPercentages(rewardWeights)
	local finalProbability = (rewardPercentages[rewardKey] or 0) / 100
	if finalProbability > 0 then
		rolled.rngChanceText = NumberFormatter.ChanceFromProbability(finalProbability)
	else
		rolled.rngChanceText = NumberFormatter.ChanceN(rolled.chanceN)
	end
	return rolled
end

local function sendRollEffect(player, buttonPart, rollBatchId, offers, track)
	CrateRollEffect:FireClient(player, {
		action = ACTION_ROLL,
		rollBatchId = rollBatchId,
		ownerUserId = player.UserId,
		button = buttonPart,
		offers = offers,
		track = track or TRACK_NORMAL,
	})
end

local function sendClearOwnerOffers(player, track)
	CrateRollEffect:FireAllClients({
		action = ACTION_CLEAR_OWNER_OFFERS,
		ownerUserId = player.UserId,
		track = track,
	})
end

local function sendPublicRollOffers(player, rollBatchId, offers, track)
	local key = userKey(player)
	local map = track == TRACK_ADMIN and adminPendingOffers or pendingOffers
	local currentOffers = key and map[key] or nil
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
		track = track or TRACK_NORMAL,
	})
end

local function sendRestoreRollOffers(player, rollBatchId, offers)
	CrateRollEffect:FireAllClients({
		action = ACTION_RESTORE_OFFERS,
		rollBatchId = rollBatchId,
		ownerUserId = player.UserId,
		offers = offers,
		track = TRACK_NORMAL,
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
	if key == nil then
		return
	end
	for _, map in ipairs({ pendingOffers, adminPendingOffers }) do
		local offers = map[key]
		if offers and offers[offerId] then
			offers[offerId] = nil
			if next(offers) == nil then
				map[key] = nil
			end
			return
		end
	end
end

-- offerIds are globally unique across both tracks (shared nextOfferId), so
-- the offerId-only purchase remote can resolve either map unambiguously.
local function activeOffer(player, offerId)
	local key = userKey(player)
	if key == nil then
		return nil, "offer-unavailable"
	end
	local offers = pendingOffers[key]
	local offer = offers and offers[offerId]
	if not offer then
		local adminOffers = adminPendingOffers[key]
		offer = adminOffers and adminOffers[offerId]
	end
	if not offer then
		return nil, "offer-unavailable"
	end
	return offer
end

local function savePendingOfferRecords(profile, offers)
	if not (profile and profile.Data) then
		return
	end

	profile.Data.PendingRollOffers = RollOfferPersistence.SanitizeRecords(offers)
end

local function removePersistedOffer(profile, offer)
	if not (profile and profile.Data) then
		return
	end

	RollOfferPersistence.RemoveRecord(profile.Data.PendingRollOffers, offer)
end

local function hasRequiredTutorialOffer(player, profile)
	local requiredSeedId = OnboardingService.RequiredBuySeed(profile)
	if not requiredSeedId then
		return false
	end
	local key = userKey(player)
	local offers = key and pendingOffers[key] or nil
	if not offers then
		return false
	end
	for _, offer in pairs(offers) do
		if offer.category == RollRewards.Categories.Seed and offer.seedId == requiredSeedId then
			return true
		end
	end
	return false
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

local function applySeedReward(player, profile, offer, options)
	local prepared, prepareCode = SeedTools.PrepareGrant(offer.seedId, 1)
	if not prepared then
		return false, prepareCode or "grant-failed"
	end

	-- Auto-roll purchases pass autoEquip = false so a background roll never yanks
	-- the tool out of the player's hands; manual buys still auto-equip as before.
	local grantOptions = nil
	if type(options) == "table" and options.autoEquip == false then
		grantOptions = { autoEquip = false }
	end

	local granted, grantCode = SeedTools.ApplyPrepared(player, profile, prepared, grantOptions)
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
	-- Reapply the admin pad on the same lifecycle: the occupancy listener
	-- fires before the profile loads (fail-closed hidden), so the post-load
	-- call here is what reveals the pad for returning players mid-party.
	RuntimeGuard.Run("RollService.ApplyAdminPadVisibility", applyAdminPadVisibility, plot)
	return true, "ok"
end

function RollService.Roll(player, target, plot, profile, maxDistance, options)
	options = type(options) == "table" and options or {}
	local key = userKey(player)
	if key == nil then
		return false, "invalid-player"
	end
	if OfflineProgressService.IsPending(player) then
		return false, "busy"
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
	if options.skipDistance ~= true and not isPlayerNearPart(player, buttonPart, maxDistance or ROLL_DISTANCE) then
		return false, "too-far"
	end

	local canRoll, rollGateCode = OnboardingService.ResolveRollAttempt(player, profile, hasRequiredTutorialOffer(player, profile))
	if not canRoll then
		NotificationService.Info(player, "Buy the tutorial seed before rolling again")
		return false, rollGateCode or "tutorial-buy-pending"
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
	local ok, success, codeOrOffers, batchIdOrNil, publicOffersOrNil, tutorialSeedIdOrNil, visualDurationOrNil = pcall(function()
		local offerMap = {}
		local effectOffers = {}
		local publicOffers = {}
		local guaranteedSeedId = OnboardingService.GuaranteedRollSeed(profile)
		local usedGuaranteedSeedId = nil
		local rollPool = collectRollPool()

		for _, dropArea in ipairs(dropAreas) do
			-- Count every crate this player's rolls spawn (one per pad).
			-- Admin party drops intentionally do not pass through here.
			local crateCount = math.max(math.floor(tonumber(profile.Data.LifetimeCrateRolls) or 0), 0) + 1
			profile.Data.LifetimeCrateRolls = crateCount

			local crateId
			local guaranteeAt = math.floor(tonumber(profile.Data.PurpleAngelCrateGuaranteeAt) or 0)
			if guaranteeAt > 0 and crateCount >= guaranteeAt then
				-- One-shot: consume by setting 0, never nil (Reconcile would
				-- re-arm nil from the profile template).
				profile.Data.PurpleAngelCrateGuaranteeAt = 0
				crateId = GUARANTEED_NEW_PLAYER_CRATE_ID
			else
				crateId = RollChances.RollCrate(rng)
			end
			if not crateId then
				return false, "crate-roll-failed"
			end

			local rolled, rollCode
			if guaranteedSeedId and not usedGuaranteedSeedId then
				rolled, rollCode = rollEntryForSeed(guaranteedSeedId, rollPool)
				if rolled then
					usedGuaranteedSeedId = guaranteedSeedId
				end
			else
				rolled, rollCode = rollRewardForCrate(crateId, player, profile, rollPool)
			end
			if not rolled then
				return false, rollCode or "reward-roll-failed"
			end

			nextOfferId += 1
			local offerId = nextOfferId
			local crate = RollChances.GetCrate(crateId)
			local previewSeeds = buildSeedPreviewSeeds(rolled, rollPool, crateId, player, profile)
			offerMap[offerId] = {
				offerId = offerId,
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
				crateFloor = dropArea.crateFloor,
				dropAreaIndex = dropArea.index,
				tutorialGuaranteed = rolled.tutorialGuaranteed == true,
			}
			effectOffers[#effectOffers + 1] = {
				offerId = offerId,
				rollBatchId = nil,
				ownerUserId = player.UserId,
				dropAreaIndex = dropArea.index,
				crateId = crateId,
				crateTemplateName = crate and crate.TemplateName or crateId,
				fallDurationMultiplier = crate and crate.FallDurationMultiplier or 1,
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
				previewSeeds = previewSeeds,
				tutorialGuaranteed = rolled.tutorialGuaranteed == true,
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
				tutorialGuaranteed = rolled.tutorialGuaranteed == true,
			}
		end

		nextRollBatchId += 1
		local rollBatchId = nextRollBatchId
		for _, offer in pairs(offerMap) do
			offer.rollBatchId = rollBatchId
		end
		for _, offer in ipairs(effectOffers) do
			offer.rollBatchId = rollBatchId
		end
		for _, offer in ipairs(publicOffers) do
			offer.rollBatchId = rollBatchId
		end

		clearPendingOffers(player)
		pendingOffers[key] = offerMap
		local visualDuration = RollConfig.RollVisualDurationForOffers(effectOffers)
		rollCooldownUntil[key] = os.clock() + visualDuration
		return true, effectOffers, rollBatchId, publicOffers, usedGuaranteedSeedId, visualDuration
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
	local visualDuration = visualDurationOrNil or RollConfig.RollVisualDurationForOffers(effectOffers)
	savePendingOfferRecords(profile, publicOffersOrNil or effectOffers)
	if tutorialSeedIdOrNil then
		OnboardingService.OnRollCreated(player, profile, tutorialSeedIdOrNil)
	end
	sendClearOwnerOffers(player, TRACK_NORMAL)
	sendRollEffect(player, buttonPart, batchIdOrNil, effectOffers, TRACK_NORMAL)
	task.delay(visualDuration, function()
		RuntimeGuard.Run("RollService.SendPublicRollOffersDelayed", sendPublicRollOffers, player, batchIdOrNil, publicOffersOrNil or {}, TRACK_NORMAL)
	end)
	TelemetryService.Record("crate_roll_created", TelemetryService.ForPlayer(player, {
		batchId = batchIdOrNil,
		offerCount = #effectOffers,
		unlockedPadCount = #dropAreas,
	}))
	return true, "ok", {
		offers = effectOffers,
		rollBatchId = batchIdOrNil,
		publicOffers = publicOffersOrNil,
		visualDuration = visualDuration,
		button = buttonPart,
	}
end

function RollService.RestorePendingOffers(player, plot, profile, options)
	options = type(options) == "table" and options or {}
	local key = userKey(player)
	if key == nil then
		return false, "invalid-player"
	end
	if pendingOffers[key] ~= nil then
		return true, "already-active"
	end
	if not (profile and profile.Data) then
		return false, "no-profile"
	end

	local records = type(profile.Data.PendingRollOffers) == "table" and profile.Data.PendingRollOffers or {}
	if #records == 0 then
		clearPendingOffers(player)
		profile.Data.PendingRollOffers = {}
		return true, "empty"
	end

	local dropAreas, dropAreaCode = unlockedDropAreas(profile, plot)
	if not dropAreas then
		return false, dropAreaCode or "missing-drop-area"
	end

	local dropAreasByIndex = {}
	for _, dropArea in ipairs(dropAreas) do
		dropAreasByIndex[dropArea.index] = dropArea
	end

	nextRollBatchId += 1
	local rollBatchId = nextRollBatchId
	local offerMap = {}
	local payloads = {}
	local savedRecords = {}
	for _, record in ipairs(records) do
		local dropAreaIndex = finiteNumber(record.dropAreaIndex)
		dropAreaIndex = dropAreaIndex and math.floor(dropAreaIndex) or nil
		local dropArea = dropAreaIndex and dropAreasByIndex[dropAreaIndex] or nil
		if dropArea then
			nextOfferId += 1
			local offerId = nextOfferId
			local active, payload, clean = RollOfferPersistence.RestoreRecord(record, dropArea, offerId, rollBatchId, player.UserId)
			if active then
				offerMap[offerId] = active
				payloads[#payloads + 1] = payload
				savedRecords[#savedRecords + 1] = clean
			end
		end
	end

	clearPendingOffers(player)
	if #payloads == 0 then
		profile.Data.PendingRollOffers = {}
		return false, "no-valid-offers"
	end

	pendingOffers[key] = offerMap
	profile.Data.PendingRollOffers = savedRecords

	local function sendActiveRestoredOffers()
		if not player:IsDescendantOf(Players) then
			return
		end
		local currentOffers = pendingOffers[key]
		if currentOffers ~= offerMap then
			return
		end

		local activePayloads = {}
		for _, payload in ipairs(payloads) do
			if currentOffers[payload.offerId] then
				activePayloads[#activePayloads + 1] = payload
			end
		end
		if #activePayloads > 0 then
			sendRestoreRollOffers(player, rollBatchId, activePayloads)
		end
	end

	local visualDelaySeconds = finiteNumber(options.visualDelaySeconds) or 0
	if visualDelaySeconds > 0 then
		task.delay(visualDelaySeconds, function()
			RuntimeGuard.Run("RollService.SendRestoredOffersDelayed", sendActiveRestoredOffers)
		end)
	else
		sendActiveRestoredOffers()
	end

	TelemetryService.Record("crate_roll_offers_restored", TelemetryService.ForPlayer(player, {
		batchId = rollBatchId,
		offerCount = #payloads,
	}))
	return true, "ok"
end

local function purchaseOffer(player, offerId, profile, options)
	options = type(options) == "table" and options or {}
	local key = userKey(player)
	if key == nil then
		return false, "invalid-player"
	end
	if OfflineProgressService.IsPending(player) then
		sendPurchaseResult(player, type(offerId) == "number" and offerId or nil, false, "busy")
		return false, "busy"
	end

	if options.consumeRate ~= false and not consumePurchaseRate(player) then
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
		NotificationService.Error(player, "This roll offer is no longer available")
		sendPurchaseResult(player, offerId, false, offerCode)
		TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
			reason = offerCode,
			offerId = offerId,
		}))
		return false, offerCode
	end
	if options.requiredRollBatchId ~= nil and offer.rollBatchId ~= options.requiredRollBatchId then
		sendPurchaseResult(player, offerId, false, "offer-batch-mismatch")
		TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
			reason = "offer-batch-mismatch",
			offerId = offerId,
			category = offer.category,
			rewardId = offer.rewardId,
			seedId = offer.seedId,
			feedType = offer.feedType,
			price = offer.price,
		}))
		return false, "offer-batch-mismatch"
	end
	if not profile then
		NotificationService.Error(player, "Could not buy this roll yet")
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
	if options.skipDistance ~= true and not isPlayerNearPart(player, offer.crateFloor, PURCHASE_DISTANCE) then
		NotificationService.Error(player, "Move closer to the rolled item to buy it")
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

		local granted, grantCode = handler(player, profile, offer, options)
		if not granted then
			CurrencyService.Add(player, profile, offer.price, true)
			spentAmount = 0
			return false, grantCode or "grant-failed"
		end

		removePendingOffer(player, offerId)
		-- Admin offers never persist (and dropAreaIndex 0 never serializes);
		-- skip explicitly rather than rely on the serializer detail.
		if offer.adminParty ~= true then
			removePersistedOffer(profile, offer)
		end
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
		if offer.category == RollRewards.Categories.Seed then
			OnboardingService.OnSeedPurchased(player, profile, offer.seedId)
		end
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
		NotificationService.Error(player, "Not enough currency for this roll")
	elseif code == "too-far" then
		NotificationService.Error(player, "Move closer to the rolled item to buy it")
	else
		NotificationService.Error(player, "Could not buy this roll")
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

local function autoPurchaseOffer(player, offerId, profile, rollBatchId)
	return purchaseOffer(player, offerId, profile, {
		consumeRate = false,
		skipDistance = true,
		requiredRollBatchId = rollBatchId,
		-- Background auto-purchases go straight to inventory; don't force-equip.
		autoEquip = false,
	})
end

function RollService.Purchase(player, offerId, profile)
	return purchaseOffer(player, offerId, profile, {
		consumeRate = true,
		skipDistance = false,
	})
end

local function cloneArray(array)
	local copy = {}
	for index, value in ipairs(array or {}) do
		copy[index] = value
	end
	return copy
end

local function selectedRaritySet(list)
	local set = {}
	for _, rarity in ipairs(list or {}) do
		set[rarity] = true
	end
	return set
end

local function sanitizeAutoRollPayload(payload)
	if type(payload) ~= "table" then
		return nil, "invalid-payload"
	end

	local action = payload.action
	if action ~= AutoRollConfig.Actions.Start
		and action ~= AutoRollConfig.Actions.Stop
		and action ~= AutoRollConfig.Actions.Settings then
		return nil, "invalid-action"
	end

	local settings, settingsCode = AutoRollConfig.SanitizeSettings(payload)
	if not settings then
		return nil, settingsCode
	end

	settings.action = action
	return settings, nil
end

local function sendAutoRollState(player, enabled, code, sessionOrSettings)
	local source = type(sessionOrSettings) == "table" and sessionOrSettings or {}
	local selectedRarities = nil
	if type(source.selectedRarities) == "table" then
		selectedRarities = cloneArray(source.selectedRarities)
	end
	AutoRollState:FireClient(player, {
		enabled = enabled == true,
		code = code,
		autoPurchase = source.autoPurchase == true,
		selectedRarities = selectedRarities,
	})
end

local function isProfileActive(profile)
	if not profile then
		return false
	end
	if type(profile.IsActive) == "function" then
		return profile:IsActive()
	end
	return true
end

local function saveAutoRollSettings(player, profile, settings)
	if not isProfileActive(profile) then
		return false
	end
	profile.Data.AutoRollSettings = AutoRollConfig.CopySettings(settings)
	PlayerReplicaService.PublishAutoRollSettings(player, profile)
	return true
end

local function autoRollSession(player, token)
	local key = userKey(player)
	local session = key and autoRollSessions[key] or nil
	if not session or session.enabled ~= true then
		return nil
	end
	if token ~= nil and session.token ~= token then
		return nil
	end
	if not player:IsDescendantOf(Players) then
		return nil
	end
	return session
end

function RollService.IsAutoRollEnabled(player)
	return autoRollSession(player) ~= nil
end

local function stopAutoRoll(player, code)
	local key = userKey(player)
	local session = key and autoRollSessions[key] or nil
	local stopped = session ~= nil
	if session then
		session.enabled = false
		session.token += 1
		autoRollSessions[key] = nil
	end
	sendAutoRollState(player, false, code, session)
	return stopped
end

local function waitForAutoRollSession(player, token, seconds)
	local deadline = os.clock() + math.max(tonumber(seconds) or 0, 0)
	while os.clock() < deadline do
		if not autoRollSession(player, token) then
			return false
		end
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			break
		end
		task.wait(math.min(0.2, remaining))
	end
	return autoRollSession(player, token) ~= nil
end

local function autoRollSettingsSnapshot(session)
	return {
		autoPurchase = session.autoPurchase == true,
		selectedRarities = cloneArray(session.selectedRarities),
		selectedSet = selectedRaritySet(session.selectedRarities),
	}
end

local function validateAutoRollState(player, session, profile, requireNearButton)
	if not player:IsDescendantOf(Players) then
		return false, "invalid-player"
	end
	if not session then
		return false, "stopped"
	end
	if not isProfileActive(profile) then
		return false, "no-profile"
	end
	if OfflineProgressService.IsPending(player) then
		return false, "busy"
	end
	if math.max(math.floor(tonumber(profile.Data.Rebirths) or 0), 0) < AutoRollConfig.UnlockRebirths then
		return false, "locked"
	end
	if not (session.plot and session.plot:IsDescendantOf(workspace)) then
		return false, "no-plot"
	end
	if not (session.buttonPart and session.buttonPart:IsDescendantOf(session.plot)) then
		return false, "missing-roll-button"
	end
	if requireNearButton and not isPlayerNearPart(player, session.buttonPart, ROLL_DISTANCE) then
		return false, "too-far"
	end
	return true, "ok"
end

local function selectedRollOffers(offers, settings)
	if next(settings.selectedSet) == nil then
		return {}
	end

	local matches = {}
	for _, offer in ipairs(offers or {}) do
		if type(offer) == "table" and settings.selectedSet[offer.rarity] == true then
			matches[#matches + 1] = offer
		end
	end
	table.sort(matches, function(a, b)
		local aPriority = AutoRollConfig.PriorityForRarity(a.rarity)
		local bPriority = AutoRollConfig.PriorityForRarity(b.rarity)
		if aPriority ~= bPriority then
			return aPriority < bPriority
		end
		local aDropArea = tonumber(a.dropAreaIndex) or math.huge
		local bDropArea = tonumber(b.dropAreaIndex) or math.huge
		if aDropArea ~= bDropArea then
			return aDropArea < bDropArea
		end
		return (tonumber(a.offerId) or math.huge) < (tonumber(b.offerId) or math.huge)
	end)
	return matches
end

local function runAutoRollLoop(player, token)
	while autoRollSession(player, token) do
		local session = autoRollSession(player, token)
		local profile = PlayerDataServiceRef and PlayerDataServiceRef.GetProfile(player) or nil
		local valid, validCode = validateAutoRollState(player, session, profile, false)
		if not valid then
			stopAutoRoll(player, validCode)
			return
		end

		local settings = autoRollSettingsSnapshot(session)
		local rolled, rollCode, rollResult = RollService.Roll(player, session.buttonPart, session.plot, profile, nil, {
			skipDistance = true,
		})
		if not rolled then
			if rollCode == "cooldown" or rollCode == "busy" then
				if not waitForAutoRollSession(player, token, AUTO_ROLL_RETRY_SECONDS) then
					return
				end
				continue
			end
			stopAutoRoll(player, rollCode)
			return
		end

		local visualDuration = type(rollResult) == "table" and rollResult.visualDuration or RollConfig.RollVisualDuration()
		if not waitForAutoRollSession(player, token, visualDuration) then
			return
		end

		session = autoRollSession(player, token)
		profile = PlayerDataServiceRef and PlayerDataServiceRef.GetProfile(player) or nil
		valid, validCode = validateAutoRollState(player, session, profile, false)
		if not valid then
			stopAutoRoll(player, validCode)
			return
		end

		local matches = selectedRollOffers(type(rollResult) == "table" and rollResult.offers or nil, settings)
		if #matches > 0 then
			if settings.autoPurchase ~= true then
				stopAutoRoll(player, "selected-rarity")
				return
			end

			for _, offer in ipairs(matches) do
				if not autoRollSession(player, token) then
					return
				end
				profile = PlayerDataServiceRef and PlayerDataServiceRef.GetProfile(player) or nil
				valid, validCode = validateAutoRollState(player, session, profile, false)
				if not valid then
					stopAutoRoll(player, validCode)
					return
				end

				local purchased, purchaseCode = autoPurchaseOffer(player, offer.offerId, profile, rollResult.rollBatchId)
				if not purchased then
					stopAutoRoll(player, purchaseCode)
					return
				end
			end
		end

		if not waitForAutoRollSession(player, token, AutoRollConfig.NextRollDelaySeconds) then
			return
		end
	end
end

local function applyAutoRollSettings(player, payload, profile)
	local key = userKey(player)
	local session = key and autoRollSessions[key] or nil
	if not saveAutoRollSettings(player, profile, payload) then
		sendAutoRollState(player, session ~= nil, "no-profile", session or payload)
		return
	end
	local settings = profile.Data.AutoRollSettings
	if not session then
		sendAutoRollState(player, false, "ok", settings)
		return
	end

	session.autoPurchase = settings.autoPurchase == true
	session.selectedRarities = cloneArray(settings.selectedRarities)
	sendAutoRollState(player, true, "ok", session)
end

local function startAutoRoll(player, payload)
	local key = userKey(player)
	if key == nil or not PlayerDataServiceRef or not PlotServiceRef then
		sendAutoRollState(player, false, "server-not-ready", payload)
		return
	end

	local profile = PlayerDataServiceRef.GetProfile(player)
	if not saveAutoRollSettings(player, profile, payload) then
		sendAutoRollState(player, false, "no-profile", payload)
		return
	end
	local plot = PlotServiceRef.GetPlayerPlot(player)
	local buttonPart, buttonCode = rollButtonForPlot(plot)
	if not buttonPart then
		sendAutoRollState(player, false, buttonCode or "missing-roll-button", profile.Data.AutoRollSettings)
		return
	end

	local session = {
		enabled = true,
		token = 0,
		playerUserId = key,
		plot = plot,
		buttonPart = buttonPart,
		autoPurchase = profile.Data.AutoRollSettings.autoPurchase == true,
		selectedRarities = cloneArray(profile.Data.AutoRollSettings.selectedRarities),
	}
	local valid, validCode = validateAutoRollState(player, session, profile, true)
	if not valid then
		sendAutoRollState(player, false, validCode, profile.Data.AutoRollSettings)
		return
	end

	stopAutoRoll(player, nil)
	nextAutoRollToken += 1
	session.token = nextAutoRollToken
	autoRollSessions[key] = session
	sendAutoRollState(player, true, "ok", session)
	NotificationService.Success(player, "Auto Roll enabled")
	RuntimeGuard.Spawn("RollService.AutoRollLoop", runAutoRollLoop, player, session.token)
end

function RollService.ResumeAutoRoll(player, profile, options)
	options = type(options) == "table" and options or {}
	local key = userKey(player)
	if key == nil or not PlayerDataServiceRef or not PlotServiceRef then
		sendAutoRollState(player, false, "server-not-ready")
		return false, "server-not-ready"
	end

	profile = profile or PlayerDataServiceRef.GetProfile(player)
	if not isProfileActive(profile) then
		sendAutoRollState(player, false, "no-profile")
		return false, "no-profile"
	end

	local plot = PlotServiceRef.GetPlayerPlot(player)
	local buttonPart, buttonCode = rollButtonForPlot(plot)
	if not buttonPart then
		sendAutoRollState(player, false, buttonCode or "missing-roll-button", profile.Data.AutoRollSettings)
		return false, buttonCode or "missing-roll-button"
	end

	local settings = AutoRollConfig.CopySettings(profile.Data.AutoRollSettings)
	local session = {
		enabled = true,
		token = 0,
		playerUserId = key,
		plot = plot,
		buttonPart = buttonPart,
		autoPurchase = settings.autoPurchase == true,
		selectedRarities = cloneArray(settings.selectedRarities),
	}
	local valid, validCode = validateAutoRollState(player, session, profile, options.requireNearButton == true)
	if not valid then
		sendAutoRollState(player, false, validCode, settings)
		return false, validCode
	end

	local existing = autoRollSessions[key]
	if existing then
		existing.enabled = false
		existing.token += 1
	end

	nextAutoRollToken += 1
	session.token = nextAutoRollToken
	autoRollSessions[key] = session
	sendAutoRollState(player, true, "ok", session)
	if options.notify == true then
		NotificationService.Success(player, "Auto Roll enabled")
	end
	RuntimeGuard.Spawn("RollService.AutoRollLoop", runAutoRollLoop, player, session.token)
	return true, "ok"
end

local function handleAutoRollRequest(player, payload)
	if not consumeRateLimit(lastAutoRollRequest, player, AUTO_ROLL_REQUEST_RATE_SECONDS) then
		return
	end

	local sanitized, sanitizeCode = sanitizeAutoRollPayload(payload)
	if not sanitized then
		sendAutoRollState(player, false, sanitizeCode)
		return
	end

	if sanitized.action == AutoRollConfig.Actions.Stop then
		local profile = PlayerDataServiceRef and PlayerDataServiceRef.GetProfile(player) or nil
		if saveAutoRollSettings(player, profile, sanitized) then
			local key = userKey(player)
			local session = key and autoRollSessions[key] or nil
			if session then
				session.autoPurchase = profile.Data.AutoRollSettings.autoPurchase == true
				session.selectedRarities = cloneArray(profile.Data.AutoRollSettings.selectedRarities)
			end
		end
		if stopAutoRoll(player, "stopped") then
			NotificationService.Info(player, "Auto Roll disabled")
		end
	elseif sanitized.action == AutoRollConfig.Actions.Settings then
		local profile = PlayerDataServiceRef and PlayerDataServiceRef.GetProfile(player) or nil
		applyAutoRollSettings(player, sanitized, profile)
	elseif sanitized.action == AutoRollConfig.Actions.Start then
		startAutoRoll(player, sanitized)
	end
end

function RollService.PurchaseLuckUpgrade(player, profile, plot, requestId)
	local key = userKey(player)
	if key == nil then
		return false, "invalid-player"
	end
	if OfflineProgressService.IsPending(player) then
		sendLuckResult(player, type(requestId) == "number" and requestId or nil, false, "busy")
		return false, "busy"
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
		NotificationService.Error(player, "Could not upgrade luck yet")
		sendLuckResult(player, requestId, false, "no-profile")
		TelemetryService.Warn("roll_luck_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "no-profile",
		}))
		return false, "no-profile"
	end
	if not plot then
		NotificationService.Error(player, "Could not find your plot")
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
		NotificationService.Error(player, "Move closer to the roll button to upgrade luck")
		sendLuckResult(player, requestId, false, "too-far")
		TelemetryService.Warn("roll_luck_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "too-far",
		}))
		return false, "too-far"
	end

	local currentLevel = RollLuckBalance.LevelFor(profile.Data.RollLuckLevel)
	local nextUpgrade, nextLevel = RollLuckBalance.NextUpgrade(currentLevel)
	if not nextUpgrade then
		NotificationService.Error(player, "Luck is already maxed")
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
		NotificationService.Success(player, "Luck upgraded to +" .. NumberFormatter.Percent(updatedLuck) .. "!")
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
		NotificationService.Error(player, "Not enough currency for this luck upgrade")
	elseif code == "max-level" then
		NotificationService.Error(player, "Luck is already maxed")
	else
		NotificationService.Error(player, "Could not upgrade luck")
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
	if OfflineProgressService.IsPending(player) then
		sendDropAreaResult(player, type(requestId) == "number" and requestId or nil, false, "busy")
		return false, "busy"
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
		NotificationService.Error(player, "Could not upgrade drop areas yet")
		sendDropAreaResult(player, requestId, false, "no-profile")
		TelemetryService.Warn("roll_drop_area_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "no-profile",
		}))
		return false, "no-profile"
	end
	if not plot then
		NotificationService.Error(player, "Could not find your plot")
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
		NotificationService.Error(player, "Move closer to the roll button to upgrade drop areas")
		sendDropAreaResult(player, requestId, false, "too-far")
		TelemetryService.Warn("roll_drop_area_upgrade_failed", TelemetryService.ForPlayer(player, {
			reason = "too-far",
		}))
		return false, "too-far"
	end

	local currentLevel = RollDropAreaBalance.LevelFor(profile.Data.RollDropAreaLevel)
	local nextUpgrade = RollDropAreaBalance.NextUpgrade(currentLevel)
	if not nextUpgrade then
		NotificationService.Error(player, "Drop areas are already maxed")
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
		NotificationService.Success(player, "Unlocked drop area " .. NumberFormatter.Integer(unlockedCount) .. "/" .. NumberFormatter.Integer(RollDropAreaBalance.TotalPads) .. "!")
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
		NotificationService.Error(player, "Not enough currency for this drop area upgrade")
	elseif code == "max-level" then
		NotificationService.Error(player, "Drop areas are already maxed")
	else
		NotificationService.Error(player, "Could not upgrade drop areas")
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
	clickDetector.MaxActivationDistance = ROLL_CLICK_DISTANCE

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
	local root = workspace:FindFirstChild("Plots") or workspace
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			bindRollButton(descendant, PlotService, PlayerDataService)
		end
	end
end

-- ── Admin party (control-plane driven) ────────────────────────────────────────

local function clearAdminPendingOffers()
	local clearedCount = 0
	for key, offerMap in pairs(adminPendingOffers) do
		for offerId in pairs(offerMap) do
			clearedCount += 1
			CrateRollEffect:FireAllClients({
				action = ACTION_CLEAR_OFFER,
				ownerUserId = key,
				offerId = offerId,
			})
		end
		adminPendingOffers[key] = nil
	end
	return clearedCount
end

function RollService.IsAdminPartyPadActive()
	return adminPadActive
end

-- Idempotent: safe to reapply on every control-plane reconcile. Turning the
-- pad off also clears any unresolved admin offers everywhere on this server.
function RollService.SetAdminPartyPadActive(active)
	active = active == true
	local changed = active ~= adminPadActive
	adminPadActive = active
	for _, plot in ipairs(allPlots()) do
		if changed and active then
			-- Bump the entrance counter before unhiding so clients start the
			-- drop-in the moment the pad appears. Only on the off->on
			-- transition: reconcile reapplies, mid-party plot claims, and
			-- onboarding completions show the pad in place with no entrance.
			local area = adminPartyPadFor(plot)
			if area and plotOwnerReadyForAdminPad(plot) then
				area:SetAttribute(
					ADMIN_PAD_ENTRANCE_ATTRIBUTE,
					(tonumber(area:GetAttribute(ADMIN_PAD_ENTRANCE_ATTRIBUTE)) or 0) + 1
				)
			end
		end
		RuntimeGuard.Run("RollService.ApplyAdminPadVisibility", applyAdminPadVisibility, plot)
	end
	if changed and not active then
		clearAdminPendingOffers()
	end
	return changed
end

local function dropAdminCrateForPlayer(player, crateId, crate)
	local key = userKey(player)
	if key == nil then
		return false
	end
	local eligible, _, context = EventEligibilityRef.IsEligible(player)
	if not (eligible and context) then
		return false
	end
	local _, crateFloor = adminPartyPadFor(context.plot)
	if not crateFloor then
		return false
	end
	if locks[key] then
		return false
	end
	local profile = context.profile

	locks[key] = true
	local ok, success, codeOrEffect, publicOfferOrNil, visualDurationOrNil = pcall(function()
		local rollPool = collectRollPool()
		local rolled, rollCode = rollRewardForCrate(crateId, player, profile, rollPool)
		if not rolled then
			return false, rollCode or "reward-roll-failed"
		end
		-- Display the seed's original rarity odds, matching regular seed roll
		-- reveals; the boosted luck only decides WHAT drops, not the shown text.
		if rolled.chanceN then
			rolled.rngChanceText = NumberFormatter.ChanceN(rolled.chanceN)
		end

		nextOfferId += 1
		local offerId = nextOfferId
		nextRollBatchId += 1
		local rollBatchId = nextRollBatchId
		local previewSeeds = buildSeedPreviewSeeds(rolled, rollPool, crateId, player, profile)

		-- Separate track: normal offers are untouched. Whole-map replace is
		-- the "refresh" — a newer admin drop displaces the previous one, and
		-- only purchase, party-off, or leave clears it otherwise.
		adminPendingOffers[key] = {
			[offerId] = {
				offerId = offerId,
				rollBatchId = rollBatchId,
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
				crateFloor = crateFloor,
				dropAreaIndex = ADMIN_DROP_AREA_INDEX,
				adminParty = true,
			},
		}

		local effectOffer = {
			offerId = offerId,
			rollBatchId = rollBatchId,
			ownerUserId = player.UserId,
			dropAreaIndex = ADMIN_DROP_AREA_INDEX,
			crateId = crateId,
			crateTemplateName = crate.TemplateName or crateId,
			fallDurationMultiplier = crate.FallDurationMultiplier or 1,
			crateFloor = crateFloor,
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
			previewSeeds = previewSeeds,
			tutorialGuaranteed = false,
		}
		local publicOffer = {
			offerId = offerId,
			rollBatchId = rollBatchId,
			ownerUserId = player.UserId,
			dropAreaIndex = ADMIN_DROP_AREA_INDEX,
			crateFloor = crateFloor,
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
			tutorialGuaranteed = false,
		}

		-- No rollCooldownUntil write: the admin fall must not block normal
		-- rolling; the duration only paces the delayed public send.
		local visualDuration = RollConfig.RollVisualDurationForOffers({ effectOffer })
		return true, effectOffer, publicOffer, visualDuration
	end)
	locks[key] = nil

	if not ok then
		warn("[RollService] Admin crate drop failed for user " .. tostring(key) .. ": " .. tostring(success))
		return false
	end
	if not success then
		return false
	end

	local effectOffer = codeOrEffect
	local visualDuration = visualDurationOrNil or RollConfig.RollVisualDurationForOffers({ effectOffer })
	-- Intentionally NOT persisted: admin drops are one-shot for present
	-- players and do not survive rejoin (profile keeps its pre-drop offers).
	sendClearOwnerOffers(player, TRACK_ADMIN)
	sendRollEffect(player, nil, effectOffer.rollBatchId, { effectOffer }, TRACK_ADMIN)
	task.delay(visualDuration, function()
		RuntimeGuard.Run("RollService.SendPublicAdminOffer", sendPublicRollOffers, player, effectOffer.rollBatchId, { publicOfferOrNil }, TRACK_ADMIN)
	end)
	RuntimeGuard.Run("RollService.NotifyAdminDrop", function()
		NotificationService.Notify(player, {
			kind = NotificationConfig.Kinds.Mythical,
			text = ADMIN_DROP_NOTICE,
			lifetime = 5,
		})
	end)
	TelemetryService.Record("admin_crate_dropped", TelemetryService.ForPlayer(player, {
		crateId = crateId,
		rewardId = effectOffer.rewardId,
		rarity = effectOffer.rarity,
	}))
	return true
end

-- Drops one admin crate on every eligible present player's admin pad.
-- Present players only: joiners after the command do not receive it.
function RollService.DropAdminCrate(crateId)
	local crate = RollChances.GetAdminCrate(crateId)
	if not crate then
		return false, "unknown-admin-crate"
	end
	if not adminPadActive then
		return false, "pad-inactive"
	end
	if not EventEligibilityRef then
		return false, "not-started"
	end

	local droppedCount, skippedCount = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		local dropOk, dropped = RuntimeGuard.Run("RollService.DropAdminCrateFor." .. tostring(player.UserId), dropAdminCrateForPlayer, player, crateId, crate)
		if dropOk and dropped == true then
			droppedCount += 1
		else
			skippedCount += 1
		end
	end
	print(string.format(
		"[RollService] Admin crate %s dropped for %d player(s), skipped %d",
		tostring(crateId),
		droppedCount,
		skippedCount
	))
	return true, droppedCount, skippedCount
end

function RollService.Start()
	local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
	local PlotService = require(Server:WaitForChild("PlotService"))
	PlayerDataServiceRef = PlayerDataService
	PlotServiceRef = PlotService
	EventEligibilityRef = require(Server:WaitForChild("EventEligibility"))

	-- Admin party pads default hidden; the control plane re-enables them from
	-- durable state (its reconcile runs after RollService.Start in init).
	-- Occupancy changes mid-party (claim/vacate) reapply that plot's pad.
	for _, plot in ipairs(allPlots()) do
		RuntimeGuard.Run("RollService.HideAdminPadAtBoot", applyAdminPadVisibility, plot)
		RuntimeGuard.Connect(
			plot:GetAttributeChangedSignal(PLOT_OWNER_ATTRIBUTE),
			"RollService.AdminPadOccupancy." .. plot.Name,
			function()
				applyAdminPadVisibility(plot)
			end
		)
	end

	-- Finishing the tutorial mid-party reveals the pad immediately (in place,
	-- no entrance) instead of waiting for the next reconcile reapply.
	OnboardingService.OnCompleted(function(player)
		local plot = PlotService.GetPlayerPlot(player)
		if plot then
			applyAdminPadVisibility(plot)
		end
	end)

	scanRollButtons(PlotService, PlayerDataService)
	local rollButtonRoot = workspace:FindFirstChild("Plots") or workspace
	RuntimeGuard.Connect(rollButtonRoot.DescendantAdded, "RollService.DescendantAdded", function(descendant)
		if descendant:IsA("BasePart") then
			bindRollButton(descendant, PlotService, PlayerDataService)
		end
	end)

	RuntimeGuard.Connect(CrateRollPurchaseRequest.OnServerEvent, "RollService.CrateRollPurchaseRequest", function(player, offerId)
		local profile = PlayerDataService.GetProfile(player)
		RollService.Purchase(player, offerId, profile)
	end)

	RuntimeGuard.Connect(AutoRollRequest.OnServerEvent, "RollService.AutoRollRequest", function(player, payload)
		handleAutoRollRequest(player, payload)
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
		lastAutoRollRequest[key] = nil
		lastLuckRequest[key] = nil
		lastDropAreaRequest[key] = nil
		pendingOffers[key] = nil
		adminPendingOffers[key] = nil
		if autoRollSessions[key] then
			autoRollSessions[key].enabled = false
			autoRollSessions[key] = nil
		end
	end)
end

return RollService
