local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local RollDropAreaBalance = require(Shared:WaitForChild("RollDropAreaBalance"))
local RollRewards = require(Shared:WaitForChild("RollRewards"))
local Seeds = require(Shared:WaitForChild("Seeds"))

local RollOfferPersistence = {}

local function finiteNumber(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	return value
end

local function nonemptyString(value)
	return type(value) == "string" and value ~= "" and value or nil
end

local function price(value, fallback)
	local number = finiteNumber(value)
	if number and number >= 0 then
		return math.floor(number)
	end
	number = finiteNumber(fallback)
	if number and number >= 0 then
		return math.floor(number)
	end
	return nil
end

local function chance(value, fallback)
	local number = finiteNumber(value)
	if number and number > 0 then
		return number
	end
	number = finiteNumber(fallback)
	if number and number > 0 then
		return number
	end
	return nil
end

local function rarity(value, fallback)
	if type(value) == "string" and Rarities.IsValid(value) then
		return value
	end
	if type(fallback) == "string" and Rarities.IsValid(fallback) then
		return fallback
	end
	return nil
end

function RollOfferPersistence.SerializeOffer(offer)
	if type(offer) ~= "table" then
		return nil
	end

	local dropAreaIndex = finiteNumber(offer.dropAreaIndex)
	if not dropAreaIndex then
		return nil
	end
	dropAreaIndex = math.floor(dropAreaIndex)
	if dropAreaIndex < 1 or dropAreaIndex > RollDropAreaBalance.TotalPads then
		return nil
	end

	local category = nonemptyString(offer.category)
	local clean = nil
	if category == RollRewards.Categories.Seed then
		local seedId = nonemptyString(offer.seedId) or nonemptyString(offer.rewardId)
		local feedType = seedId and Seeds.FeedTypeFor(seedId) or nil
		local offerPrice = seedId and price(offer.price, Seeds.PriceFor(seedId)) or nil
		if not (seedId and feedType and offerPrice) then
			return nil
		end

		clean = {
			category = RollRewards.Categories.Seed,
			rewardId = seedId,
			seedId = seedId,
			feedType = feedType,
			displayName = nonemptyString(offer.displayName) or Seeds.DisplayNameFor(seedId),
			price = offerPrice,
			dropAreaIndex = dropAreaIndex,
		}
		clean.rarity = rarity(offer.rarity, Seeds.RarityFor(seedId))
		clean.chanceN = chance(offer.chanceN, Seeds.RollChanceNFor(seedId))
	elseif category == RollRewards.Categories.Misc then
		local miscId = nonemptyString(offer.miscId) or nonemptyString(offer.rewardId)
		local entry = miscId and RollRewards.MiscEntryFor(miscId) or nil
		local offerPrice = entry and price(offer.price, entry.price) or nil
		if not (entry and offerPrice) then
			return nil
		end

		clean = {
			category = RollRewards.Categories.Misc,
			rewardId = miscId,
			miscId = miscId,
			displayName = nonemptyString(offer.displayName) or entry.displayName,
			price = offerPrice,
			dropAreaIndex = dropAreaIndex,
		}
		clean.rarity = rarity(offer.rarity, entry.rarity)
		clean.chanceN = chance(offer.chanceN, entry.chanceN)
	else
		return nil
	end

	clean.rngChanceText = nonemptyString(offer.rngChanceText)
	clean.tutorialGuaranteed = offer.tutorialGuaranteed == true
	return clean
end

function RollOfferPersistence.SanitizeRecords(records)
	if type(records) ~= "table" then
		return {}
	end

	local cleanRecords = {}
	local seenDropAreas = {}
	for _, offer in ipairs(records) do
		local clean = RollOfferPersistence.SerializeOffer(offer)
		if clean and not seenDropAreas[clean.dropAreaIndex] then
			seenDropAreas[clean.dropAreaIndex] = true
			cleanRecords[#cleanRecords + 1] = clean
		end
	end
	table.sort(cleanRecords, function(left, right)
		return left.dropAreaIndex < right.dropAreaIndex
	end)
	return cleanRecords
end

function RollOfferPersistence.RemoveRecord(records, offer)
	if type(records) ~= "table" or type(offer) ~= "table" then
		return false
	end

	local dropAreaIndex = finiteNumber(offer.dropAreaIndex)
	dropAreaIndex = dropAreaIndex and math.floor(dropAreaIndex) or nil
	for index = #records, 1, -1 do
		local record = records[index]
		if type(record) == "table"
			and record.category == offer.category
			and record.rewardId == offer.rewardId
			and finiteNumber(record.dropAreaIndex)
			and math.floor(finiteNumber(record.dropAreaIndex)) == dropAreaIndex then
			table.remove(records, index)
			return true
		end
	end
	return false
end

function RollOfferPersistence.RestoreRecord(record, dropArea, offerId, rollBatchId, ownerUserId)
	if not (dropArea and dropArea.crateFloor) then
		return nil, nil, nil
	end

	local clean = RollOfferPersistence.SerializeOffer(record)
	if not clean then
		return nil, nil, nil
	end

	local active = table.clone(clean)
	active.offerId = offerId
	active.rollBatchId = rollBatchId
	active.ownerUserId = ownerUserId
	active.crateFloor = dropArea.crateFloor

	local payload = table.clone(active)
	return active, payload, clean
end

return RollOfferPersistence
