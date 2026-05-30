local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local FeedRewardService = require(Server:WaitForChild("FeedRewardService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollChances = require(Shared:WaitForChild("RollChances"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))
local State = require(Shared:WaitForChild("State"))

local RollService = {}

local ROLL_DISTANCE = 14
local PURCHASE_DISTANCE = 18
local PURCHASE_REQUEST_RATE_SECONDS = 0.35
local OFFER_EXPIRES_SECONDS = 45
local PREVIEW_COUNT = 10

local locks = {}
local rollCooldownUntil = {}
local lastPurchaseRequest = {}
local pendingOffers = {}
local nextOfferId = 0
local nextTeaseRolls = {}
local boundRollButtons = setmetatable({}, { __mode = "k" })
local rng = Random.new()

local CrateRollEffect = Remotes.get(Remotes.Names.CrateRollEffect)
local CrateRollPurchaseRequest = Remotes.get(Remotes.Names.CrateRollPurchaseRequest)
local CrateRollPurchaseResult = Remotes.get(Remotes.Names.CrateRollPurchaseResult)

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

local function resolveRollArea(target)
	if not (target and target:IsA("BasePart") and target.Name == "Button") then
		return nil, nil, "invalid-target"
	end

	local buttonFolder = target.Parent
	if not (buttonFolder and buttonFolder:IsA("Folder") and buttonFolder.Name == "Button") then
		return nil, nil, "invalid-target"
	end

	local rollArea = buttonFolder.Parent
	if not (rollArea and rollArea:IsA("Folder") and rollArea.Name == "RollArea") then
		return nil, nil, "invalid-target"
	end

	local crateFloor = buttonFolder:FindFirstChild("CrateFloor")
	if not (crateFloor and crateFloor:IsA("BasePart")) then
		return nil, nil, "missing-crate-floor"
	end

	return target, crateFloor, nil
end

local function collectRollPool()
	local entries = {}

	for _, feedType in ipairs(FeedMachines.AllFeedTypes()) do
		local template = FeedMachines.GetTemplate(feedType)
		local chanceN = template and template:GetAttribute(State.Feed.RollChanceN)
		local price = template and template:GetAttribute(State.Feed.Price)
		local rarity = template and template:GetAttribute(State.Feed.Rarity)
		if RollChances.BaseWeightForChance(chanceN) and type(price) == "number" and price >= 0 then
			entries[#entries + 1] = {
				id = feedType,
				feedType = feedType,
				displayName = template.Name,
				rarity = type(rarity) == "string" and Rarities.IsValid(rarity) and rarity or nil,
				chanceN = chanceN,
				price = math.floor(price),
			}
		end
	end

	table.sort(entries, function(a, b)
		if a.chanceN ~= b.chanceN then
			return a.chanceN < b.chanceN
		end
		return a.feedType < b.feedType
	end)

	return entries
end

local function feedTypesFromEntries(entries)
	local feedTypes = {}
	for _, entry in ipairs(entries) do
		feedTypes[#feedTypes + 1] = entry.feedType
	end
	return feedTypes
end

local function rarestFeedType(entries, excludedFeedType)
	local rarest = nil
	for _, entry in ipairs(entries) do
		if entry.feedType ~= excludedFeedType and (not rarest or entry.chanceN > rarest.chanceN) then
			rarest = entry
		end
	end
	return rarest and rarest.feedType or nil
end

local function shouldTeaseRare(player)
	local remaining = nextTeaseRolls[player]
	if type(remaining) ~= "number" or remaining <= 0 then
		remaining = rng:NextInteger(1, 3)
	end
	remaining -= 1
	if remaining <= 0 then
		nextTeaseRolls[player] = rng:NextInteger(1, 3)
		return true
	end
	nextTeaseRolls[player] = remaining
	return false
end

local function shuffledPreviewFeedTypes(player, entries, rolledFeedType)
	local allFeedTypes = feedTypesFromEntries(entries)
	local pool = {}
	for _, feedType in ipairs(allFeedTypes) do
		if feedType ~= rolledFeedType then
			pool[#pool + 1] = feedType
		end
	end

	for index = #pool, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		pool[index], pool[swapIndex] = pool[swapIndex], pool[index]
	end

	local preview = {}
	local rareTease = shouldTeaseRare(player) and rarestFeedType(entries, rolledFeedType) or nil
	if rareTease then
		preview[#preview + 1] = rareTease
	end
	for index = 1, math.min(PREVIEW_COUNT - 1 - #preview, #pool) do
		if pool[index] ~= rareTease then
			preview[#preview + 1] = pool[index]
		end
	end
	while #preview < math.min(PREVIEW_COUNT - 1, #pool) do
		for _, feedType in ipairs(pool) do
			if feedType ~= rareTease then
				preview[#preview + 1] = feedType
				if #preview >= PREVIEW_COUNT - 1 then
					break
				end
			end
		end
		break
	end
	if #preview == 0 and #pool > 0 then
		preview[#preview + 1] = pool[1]
	end
	preview[#preview + 1] = rolledFeedType
	return preview
end

local function rollFeedForCrate(player, crateId)
	local entries = collectRollPool()
	if #entries == 0 then
		return nil, "empty-roll-pool"
	end

	local feedWeights, weightCode = RollChances.ComputeFeedWeights(crateId, entries)
	if not feedWeights then
		return nil, weightCode or "invalid-feed-weights"
	end

	local feedType = RollChances.WeightedChoice(feedWeights, rng)
	if not feedType then
		return nil, "empty-roll-pool"
	end

	local entry = nil
	for _, candidate in ipairs(entries) do
		if candidate.feedType == feedType then
			entry = candidate
			break
		end
	end
	if not entry then
		return nil, "missing-roll-entry"
	end

	entry.previewFeedTypes = shuffledPreviewFeedTypes(player, entries, entry.feedType)
	entry.feedOdds = RollChances.ToPercentages(feedWeights)
	return entry
end

local function sendRollEffect(player, buttonPart, crateFloor, crateId, rolled, offerId)
	local crate = RollChances.GetCrate(crateId)
	CrateRollEffect:FireClient(player, {
		offerId = offerId,
		crateId = crateId,
		crateTemplateName = crate and crate.TemplateName or crateId,
		button = buttonPart,
		crateFloor = crateFloor,
		feedType = rolled.feedType,
		displayName = rolled.displayName,
		rarity = rolled.rarity,
		price = rolled.price,
		chanceN = rolled.chanceN,
		rngChanceText = "1 in " .. tostring(rolled.chanceN),
		feedOdds = rolled.feedOdds,
		previewFeedTypes = rolled.previewFeedTypes,
		flickerCount = rolled.flickerCount,
		duration = 2.5,
	})
end

local function sendPurchaseResult(player, offerId, success, code, extra)
	local payload = extra or {}
	payload.offerId = offerId
	payload.success = success
	payload.code = code
	CrateRollPurchaseResult:FireClient(player, payload)
end

local function activeOffer(player, offerId)
	local offer = pendingOffers[player]
	if not offer or offer.offerId ~= offerId then
		return nil, "offer-expired"
	end
	if os.clock() > offer.expiresAt then
		pendingOffers[player] = nil
		return nil, "offer-expired"
	end
	return offer
end

local function consumePurchaseRate(player)
	local now = os.clock()
	local previous = lastPurchaseRequest[player] or 0
	if now - previous < PURCHASE_REQUEST_RATE_SECONDS then
		return false
	end
	lastPurchaseRequest[player] = now
	return true
end

function RollService.Roll(player, target, plot, profile)
	local buttonPart, crateFloor, targetCode = resolveRollArea(target)
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

	local now = os.clock()
	if now < (rollCooldownUntil[player] or 0) then
		return false, "cooldown"
	end
	if locks[player] then
		return false, "busy"
	end

	locks[player] = true
	local ok, success, codeOrCrate, rolledOrNil, offerIdOrNil = pcall(function()
		local crateId = RollChances.RollCrate(rng)
		if not crateId then
			return false, "crate-roll-failed", nil
		end

		local rolled, rollCode = rollFeedForCrate(player, crateId)
		if not rolled then
			return false, rollCode or "feed-roll-failed", nil
		end

		local flickerCount = RollConfig.Reveal.FlickerCount
		rolled.flickerCount = flickerCount
		rollCooldownUntil[player] = os.clock() + RollConfig.RollVisualDuration()
		nextOfferId += 1
		local offerId = nextOfferId
		pendingOffers[player] = {
			offerId = offerId,
			feedType = rolled.feedType,
			displayName = rolled.displayName,
			price = rolled.price,
			crateFloor = crateFloor,
			expiresAt = os.clock() + OFFER_EXPIRES_SECONDS,
		}
		return true, crateId, rolled, offerId
	end)
	locks[player] = nil

	if not ok then
		warn("[RollService] Roll failed: " .. tostring(success))
		TelemetryService.Warn("crate_roll_failed", TelemetryService.ForPlayer(player, {
			reason = "server-error",
		}))
		return false, "server-error"
	end
	if not success then
		TelemetryService.Warn("crate_roll_failed", TelemetryService.ForPlayer(player, {
			reason = codeOrCrate,
		}))
		return false, codeOrCrate
	end

	local crateId = codeOrCrate
	local rolled = rolledOrNil
	sendRollEffect(player, buttonPart, crateFloor, crateId, rolled, offerIdOrNil)
	TelemetryService.Record("crate_roll_created", TelemetryService.ForPlayer(player, {
		crateId = crateId,
		feedType = rolled.feedType,
		price = rolled.price,
		offerId = offerIdOrNil,
	}))
	return true, "ok"
end

function RollService.Purchase(player, offerId, profile)
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
	if locks[player] then
		sendPurchaseResult(player, offerId, false, "busy")
		return false, "busy"
	end

	local offer, offerCode = activeOffer(player, offerId)
	if not offer then
		NotificationService.Error(player, "This roll offer expired.")
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
			feedType = offer.feedType,
			price = offer.price,
		}))
		return false, "too-far"
	end

	locks[player] = true
	local ok, success, code, currencyOrNil = pcall(function()
		local spent, spendCode, currency = CurrencyService.TrySpend(player, profile, offer.price)
		if not spent then
			return false, spendCode or "insufficient-currency", currency
		end

		local granted, grantCode = FeedRewardService.Grant(player, profile, offer.feedType, 1)
		if not granted then
			CurrencyService.Add(player, profile, offer.price)
			return false, grantCode or "grant-failed"
		end

		pendingOffers[player] = nil
		return true, "ok", profile.Data.Currency
	end)
	locks[player] = nil

	if not ok then
		warn("[RollService] Purchase failed: " .. tostring(success))
		sendPurchaseResult(player, offerId, false, "server-error")
		TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
			reason = "server-error",
			offerId = offerId,
			feedType = offer.feedType,
			price = offer.price,
		}))
		return false, "server-error"
	end

	if success then
		NotificationService.Success(player, string.format("Purchased %s!", offer.displayName or offer.feedType))
		sendPurchaseResult(player, offerId, true, "ok", {
			feedType = offer.feedType,
			currency = currencyOrNil,
		})
		TelemetryService.Record("crate_roll_purchase_succeeded", TelemetryService.ForPlayer(player, {
			offerId = offerId,
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
	sendPurchaseResult(player, offerId, false, code)
	TelemetryService.Warn("crate_roll_purchase_failed", TelemetryService.ForPlayer(player, {
		reason = code,
		offerId = offerId,
		feedType = offer.feedType,
		price = offer.price,
		currency = currencyOrNil,
	}))
	return false, code
end

local function bindRollButton(buttonPart, PlotService, PlayerDataService)
	if boundRollButtons[buttonPart] then
		return
	end

	local resolvedButton = resolveRollArea(buttonPart)
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

	boundRollButtons[buttonPart] = clickDetector.MouseClick:Connect(function(player)
		local plot = PlotService.GetPlayerPlot(player)
		local profile = PlayerDataService.GetProfile(player)
		local ok, code = RollService.Roll(player, buttonPart, plot, profile)
		if not ok and code ~= "cooldown" and code ~= "busy" then
			NotificationService.Error(player, "Could not roll that crate.")
		end
	end)

	buttonPart.Destroying:Connect(function()
		local connection = boundRollButtons[buttonPart]
		if connection then
			connection:Disconnect()
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
	workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			bindRollButton(descendant, PlotService, PlayerDataService)
		end
	end)

	CrateRollPurchaseRequest.OnServerEvent:Connect(function(player, offerId)
		local profile = PlayerDataService.GetProfile(player)
		RollService.Purchase(player, offerId, profile)
	end)

	Players.PlayerRemoving:Connect(function(player)
		locks[player] = nil
		rollCooldownUntil[player] = nil
		lastPurchaseRequest[player] = nil
		pendingOffers[player] = nil
		nextTeaseRolls[player] = nil
	end)
end

return RollService
