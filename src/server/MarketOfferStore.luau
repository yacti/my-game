local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MarketCatalog = require(ReplicatedStorage.Shared:WaitForChild("MarketCatalog"))

local OFFER_INTERVAL_SECONDS = 15 * 60
local DATASTORE_NAME = "MarketOffers"
local GLOBAL_OFFER_KEY = "GlobalOffer"
local MESSAGE_TOPIC = "MarketOfferUpdated"
local CACHE_TTL_SECONDS = 20

local USE_MEMORY_STORE_IN_STUDIO = true

local MarketOfferStore = {}

local dataStore = nil
local memoryOffer = nil
local cachedOffer = nil
local cachedAt = 0
local overrideOffer = nil
local overridePurchases = {}
local overrideSerial = 0
local listeners = {}
local started = false

local function now()
	return os.time()
end

local function cycleFor(timestamp)
	timestamp = timestamp or now()
	local cycleId = math.floor(timestamp / OFFER_INTERVAL_SECONDS)
	local cycleStart = cycleId * OFFER_INTERVAL_SECONDS
	return cycleId, cycleStart, cycleStart + OFFER_INTERVAL_SECONDS
end

local function cloneMap(map)
	local out = {}
	for key, value in pairs(map or {}) do
		out[key] = value
	end
	return out
end

local function cloneOffer(offer)
	if type(offer) ~= "table" then
		return nil
	end
	local clone = {}
	for key, value in pairs(offer) do
		if key == "items" then
			clone.items = cloneMap(value)
		else
			clone[key] = value
		end
	end
	return clone
end

local function generateGlobalOffer(cycleId, cycleStart, cycleEnd)
	local catalog = MarketCatalog.GetCatalog()
	return MarketCatalog.GenerateOffer(catalog, cycleId, cycleStart, cycleEnd, "global")
end

local function ensureOfferShape(existing, currentCycleId)
	if type(existing) ~= "table" then
		return nil
	end
	if existing.cycleId ~= currentCycleId or type(existing.items) ~= "table" then
		return nil
	end
	return existing
end

local function publishUpdate(offer)
	local payload = {
		cycleId = offer and offer.cycleId,
		cycleEnd = offer and offer.cycleEnd,
	}
	pcall(function()
		MessagingService:PublishAsync(MESSAGE_TOPIC, payload)
	end)
end

local function notifyListeners()
	for _, callback in ipairs(listeners) do
		task.spawn(callback)
	end
end

local function refreshFromMemory(forceNewCycle)
	local cycleId = cycleFor(now())
	if forceNewCycle or not ensureOfferShape(memoryOffer, cycleId) then
		local currentCycleId, cycleStart, cycleEnd = cycleFor(now())
		memoryOffer = generateGlobalOffer(currentCycleId, cycleStart, cycleEnd)
	end
	cachedOffer = cloneOffer(memoryOffer)
	cachedAt = os.clock()
	return cloneOffer(cachedOffer)
end

local function refreshFromDataStore()
	local cycleId, cycleStart, cycleEnd = cycleFor(now())
	local generatedNewOffer = false

	local ok, result = pcall(function()
		return dataStore:UpdateAsync(GLOBAL_OFFER_KEY, function(existing)
			local current = ensureOfferShape(existing, cycleId)
			if current then
				return current
			end
			generatedNewOffer = true
			return generateGlobalOffer(cycleId, cycleStart, cycleEnd)
		end)
	end)

	if not ok then
		warn("[MarketOfferStore] Failed to refresh global offer: " .. tostring(result))
		return cachedOffer and cloneOffer(cachedOffer) or generateGlobalOffer(cycleId, cycleStart, cycleEnd)
	end

	cachedOffer = cloneOffer(result)
	cachedAt = os.clock()
	if generatedNewOffer then
		publishUpdate(cachedOffer)
	end
	return cloneOffer(cachedOffer)
end

local function clearExpiredOverride(globalOffer)
	if overrideOffer and globalOffer and globalOffer.cycleId ~= overrideOffer.cycleId then
		overrideOffer = nil
		overridePurchases = {}
		notifyListeners()
	end
end

function MarketOfferStore.CycleFor(timestamp)
	return cycleFor(timestamp)
end

function MarketOfferStore.GetGlobalOffer(forceRefresh)
	local useMemory = USE_MEMORY_STORE_IN_STUDIO and RunService:IsStudio()
	if not forceRefresh and cachedOffer and os.clock() - cachedAt < CACHE_TTL_SECONDS then
		clearExpiredOverride(cachedOffer)
		return cloneOffer(cachedOffer)
	end

	local offer
	if useMemory then
		offer = refreshFromMemory(forceRefresh)
	else
		dataStore = dataStore or DataStoreService:GetDataStore(DATASTORE_NAME)
		offer = refreshFromDataStore()
	end
	clearExpiredOverride(offer)
	return offer
end

function MarketOfferStore.GetActiveOffer()
	local globalOffer = MarketOfferStore.GetGlobalOffer()
	if overrideOffer and globalOffer and overrideOffer.cycleId == globalOffer.cycleId then
		return cloneOffer(overrideOffer), "server"
	end
	return globalOffer, "global"
end

function MarketOfferStore.ApplyServerOverride(receiptId)
	local globalOffer = MarketOfferStore.GetGlobalOffer(true)
	local receiptKey = receiptId and tostring(receiptId) or nil
	if receiptKey and overrideOffer and overrideOffer.receiptId == receiptKey then
		return cloneOffer(overrideOffer)
	end

	overrideSerial += 1

	local catalog = MarketCatalog.GetCatalog()
	local salt = receiptKey
		and string.format("server:%s:%s", game.JobId, receiptKey)
		or string.format("server:%s:%s:%d", game.JobId, HttpService:GenerateGUID(false), overrideSerial)
	local offer = MarketCatalog.GenerateOffer(catalog, globalOffer.cycleId, globalOffer.cycleStart, globalOffer.cycleEnd, salt)
	offer.offerId = receiptKey
		and string.format("server-%s-%s", game.JobId ~= "" and game.JobId or "studio", receiptKey)
		or string.format("server-%s-%d", game.JobId ~= "" and game.JobId or "studio", overrideSerial)
	offer.receiptId = receiptKey
	overrideOffer = offer
	overridePurchases = {}
	notifyListeners()
	return cloneOffer(overrideOffer)
end

function MarketOfferStore.GetOverridePurchaseCount(userId, offerId, feedType)
	local userPurchases = overridePurchases[userId]
	local offerPurchases = userPurchases and userPurchases[offerId]
	return offerPurchases and offerPurchases[feedType] or 0
end

function MarketOfferStore.AddOverridePurchase(userId, offerId, feedType, amount)
	amount = amount or 1
	overridePurchases[userId] = overridePurchases[userId] or {}
	overridePurchases[userId][offerId] = overridePurchases[userId][offerId] or {}
	local counts = overridePurchases[userId][offerId]
	counts[feedType] = (counts[feedType] or 0) + amount
end

function MarketOfferStore.OnUpdated(callback)
	listeners[#listeners + 1] = callback
end

function MarketOfferStore.Start()
	if started then
		return
	end
	started = true

	task.spawn(function()
		MarketOfferStore.GetGlobalOffer(true)
		notifyListeners()
	end)

	task.spawn(function()
		pcall(function()
			MessagingService:SubscribeAsync(MESSAGE_TOPIC, function()
				MarketOfferStore.GetGlobalOffer(true)
				notifyListeners()
			end)
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(5)
			local offer = MarketOfferStore.GetGlobalOffer()
			local secondsUntilNextCycle = offer and (offer.cycleEnd - now()) or CACHE_TTL_SECONDS
			if secondsUntilNextCycle <= 2 then
				MarketOfferStore.GetGlobalOffer(true)
				notifyListeners()
				task.wait(2)
			end
		end
	end)
end

return MarketOfferStore
