local RollChances = {}

local DEFAULT_LUCK_DONOR_COUNT = 2
local CATEGORY_SEED = "Seed"
local CATEGORY_MISC = "Misc"
local PROBABILITY_EPSILON = 1e-9

RollChances.CategoryWeights = {
	[CATEGORY_SEED] = 100,
	[CATEGORY_MISC] = 0,
}

RollChances.SeedFallbackId = "__SeedCommonFallback"
RollChances.MaxBoostedOutcomeProbability = 0.25
RollChances.SeedFallback = {
	{ seedId = "AppleTreeSeed", weight = 50 },
	{ seedId = "PumpkinSeed", weight = 35 },
	{ seedId = "CabbageSeed", weight = 15 },
}

-- DropWeights sum to 100, so each weight reads directly as a percentage.
RollChances.Crates = {
	Crate = {
		DisplayName = "Crate",
		DropWeight = 50,
		LuckMultiplier = 1,
		TemplateName = "CommonCrate",
	},
	YellowLuckyBlock = {
		DisplayName = "Yellow Lucky Block",
		DropWeight = 5,
		LuckMultiplier = 5,
		TemplateName = "YellowLuckyBlock",
		FallDurationMultiplier = 2,
		DonorCount = 2,
	},
	BlueLuckyBlock = {
		DisplayName = "Blue Lucky Block",
		DropWeight = 3,
		LuckMultiplier = 10,
		TemplateName = "BlueLuckyBlock",
		FallDurationMultiplier = 2,
		DonorCount = 2,
	},
	RedLuckyBlock = {
		DisplayName = "Red Lucky Block",
		DropWeight = 1,
		LuckMultiplier = 25,
		TemplateName = "RedLuckyBlock",
		FallDurationMultiplier = 2,
		DonorCount = 2,
	},
	PurpleAngelLuckyBlock = {
		DisplayName = "Purple Angel Lucky Block",
		DropWeight = 0.75,
		LuckMultiplier = 50,
		TemplateName = "PurpleAngelLuckyBlock",
		FallDurationMultiplier = 3,
		DonorCount = 2,
	},
	ChainedLuckyBlock = {
		DisplayName = "Chained Lucky Block",
		DropWeight = 0.25,
		LuckMultiplier = 100,
		TemplateName = "ChainedLuckyBlock",
		FallDurationMultiplier = 4,
		DonorCount = 2,
	},
}

local function totalWeight(weights, keys)
	local total = 0
	if keys then
		for _, key in ipairs(keys) do
			total += math.max(tonumber(weights[key]) or 0, 0)
		end
	else
		for _, weight in pairs(weights or {}) do
			total += math.max(tonumber(weight) or 0, 0)
		end
	end
	return total
end

local function sortedKeys(weights)
	local keys = {}
	for key in pairs(weights or {}) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

local function removeSurplusFromDonors(weights, donorIds, surplus)
	if surplus <= 0 then
		return 0
	end

	local remainingSurplus = surplus
	for _, id in ipairs(donorIds or {}) do
		if remainingSurplus <= PROBABILITY_EPSILON then
			return 0
		end
		local current = math.max(tonumber(weights[id]) or 0, 0)
		if current > 0 then
			local reduction = math.min(remainingSurplus, current)
			weights[id] = current - reduction
			remainingSurplus -= reduction
		end
	end

	return math.max(remainingSurplus, 0)
end

local function sortEntriesByChance(entries)
	local sorted = table.clone(entries or {})
	table.sort(sorted, function(a, b)
		if a.chanceN ~= b.chanceN then
			return a.chanceN < b.chanceN
		end
		return tostring(a.id) < tostring(b.id)
	end)
	return sorted
end

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function categoryOf(entry)
	return type(entry) == "table" and entry.category or nil
end

local function categoryHasEntries(entries, category)
	for _, entry in ipairs(entries or {}) do
		if categoryOf(entry) == category then
			return true
		end
	end
	return false
end

local function categoryWeight(category)
	local weight = tonumber(RollChances.CategoryWeights[category]) or 0
	if not isFiniteNumber(weight) then
		return 0
	end
	return math.max(weight, 0)
end

local function sortedCategoryIds()
	local ids = {}
	for category in pairs(RollChances.CategoryWeights) do
		ids[#ids + 1] = category
	end
	table.sort(ids)
	return ids
end

local function validateSingleCategory(entries)
	local category
	for _, entry in ipairs(entries or {}) do
		local entryCategory = categoryOf(entry)
		if type(entryCategory) ~= "string" or entryCategory == "" then
			return nil, "invalid-roll-entry-category"
		end
		category = category or entryCategory
		if entryCategory ~= category then
			return nil, "mixed-roll-entry-categories"
		end
	end
	return category, nil
end

local function seedFallbackProbability(totalBaseProbability)
	local remaining = 1 - totalBaseProbability
	if remaining <= PROBABILITY_EPSILON then
		return 0
	end
	return remaining
end

local function addDonorIds(donorIds, sortedEntries, donorCount)
	for index = 1, math.min(donorCount, #sortedEntries) do
		donorIds[#donorIds + 1] = sortedEntries[index].id
	end
end

local function boostedTotal(baseWeights, sortedEntries, donorCount)
	local total = 0
	for index = donorCount + 1, #sortedEntries do
		total += baseWeights[sortedEntries[index].id]
	end
	return total
end

function RollChances.GetCrate(crateId)
	return RollChances.Crates[crateId]
end

function RollChances.CrateIds()
	local ids = {}
	for crateId in pairs(RollChances.Crates) do
		ids[#ids + 1] = crateId
	end
	table.sort(ids)
	return ids
end

function RollChances.BaseWeightForChance(chanceN)
	chanceN = tonumber(chanceN)
	if not isFiniteNumber(chanceN) or chanceN <= 0 then
		return nil
	end
	return 1 / chanceN
end

function RollChances.EffectiveLuckMultiplier(crateLuckMultiplier, playerLuckPercent, serverLuckMultiplier)
	crateLuckMultiplier = tonumber(crateLuckMultiplier) or 1
	if type(crateLuckMultiplier) ~= "number" or crateLuckMultiplier ~= crateLuckMultiplier or math.abs(crateLuckMultiplier) == math.huge then
		crateLuckMultiplier = 1
	end
	crateLuckMultiplier = math.max(crateLuckMultiplier, 1)

	playerLuckPercent = tonumber(playerLuckPercent) or 0
	if type(playerLuckPercent) ~= "number" or playerLuckPercent ~= playerLuckPercent or math.abs(playerLuckPercent) == math.huge then
		playerLuckPercent = 0
	end
	playerLuckPercent = math.max(playerLuckPercent, 0)

	serverLuckMultiplier = tonumber(serverLuckMultiplier) or 1
	if type(serverLuckMultiplier) ~= "number" or serverLuckMultiplier ~= serverLuckMultiplier or math.abs(serverLuckMultiplier) == math.huge then
		serverLuckMultiplier = 1
	end
	local serverLuckTerm = serverLuckMultiplier > 1 and (serverLuckMultiplier - 1) or 0
	local playerLuckTerm = playerLuckPercent / 100

	-- Luck sources add together so crate, player, and server luck do not scale explosively.
	return math.max(crateLuckMultiplier + playerLuckTerm + serverLuckTerm, 1)
end

function RollChances.ComputeCategoryWeights(entries)
	if type(entries) ~= "table" or #entries == 0 then
		return nil, "empty-roll-pool"
	end

	local weights = {}
	for _, category in ipairs(sortedCategoryIds()) do
		local weight = categoryWeight(category)
		if weight > 0 and categoryHasEntries(entries, category) then
			weights[category] = weight
		end
	end
	if totalWeight(weights) <= 0 then
		return nil, "empty-category-pool"
	end
	return weights
end

function RollChances.ComputeRewardWeights(crateId, entries, playerLuckPercent, serverLuckMultiplier, options)
	local crate = RollChances.GetCrate(crateId)
	if not crate then
		return nil, "unknown-crate"
	end
	if type(entries) ~= "table" or #entries == 0 then
		return nil, "empty-roll-pool"
	end
	local category, categoryCode = validateSingleCategory(entries)
	if not category then
		return nil, categoryCode
	end

	local weights = {}
	local baseWeights = {}
	local sortedEntries = sortEntriesByChance(entries)
	local totalBaseProbability = 0
	for _, entry in ipairs(sortedEntries) do
		local id = entry.id
		local baseWeight = RollChances.BaseWeightForChance(entry.chanceN)
		if type(id) ~= "string" or id == "" or not baseWeight then
			return nil, "invalid-roll-entry"
		end
		if weights[id] ~= nil then
			return nil, "duplicate-roll-entry"
		end
		weights[id] = baseWeight
		baseWeights[id] = baseWeight
		totalBaseProbability += baseWeight
	end

	if totalBaseProbability > 1 + PROBABILITY_EPSILON then
		return nil, "roll-probability-overflow"
	end

	local includeFallback = not (type(options) == "table" and options.includeFallback == false)
	local fallbackWeight = 0
	if category == CATEGORY_SEED and includeFallback then
		fallbackWeight = seedFallbackProbability(totalBaseProbability)
		if fallbackWeight > 0 then
			weights[RollChances.SeedFallbackId] = fallbackWeight
			baseWeights[RollChances.SeedFallbackId] = fallbackWeight
		end
	end

	if category ~= CATEGORY_SEED then
		return weights
	end

	local crateMultiplier = math.max(tonumber(crate.LuckMultiplier) or 1, 1)
	local multiplier = RollChances.EffectiveLuckMultiplier(crateMultiplier, playerLuckPercent, serverLuckMultiplier)
	if multiplier <= 1 then
		return weights
	end

	local donorIds = {}
	local donorCount = tonumber(crate.DonorCount)
	if type(donorCount) ~= "number" or donorCount ~= donorCount or math.abs(donorCount) == math.huge then
		donorCount = DEFAULT_LUCK_DONOR_COUNT
	end
	donorCount = math.max(math.floor(donorCount), 0)

	while donorCount < #sortedEntries do
		local firstBoosted = sortedEntries[donorCount + 1]
		if baseWeights[firstBoosted.id] * multiplier <= RollChances.MaxBoostedOutcomeProbability + PROBABILITY_EPSILON then
			break
		end
		donorCount += 1
	end

	while donorCount < #sortedEntries do
		table.clear(donorIds)
		if fallbackWeight > 0 then
			donorIds[#donorIds + 1] = RollChances.SeedFallbackId
		end
		addDonorIds(donorIds, sortedEntries, donorCount)
		local desiredSurplus = boostedTotal(baseWeights, sortedEntries, donorCount) * (multiplier - 1)
		if totalWeight(baseWeights, donorIds) + PROBABILITY_EPSILON >= desiredSurplus then
			break
		end
		donorCount += 1
	end

	table.clear(donorIds)
	if fallbackWeight > 0 then
		donorIds[#donorIds + 1] = RollChances.SeedFallbackId
	end
	addDonorIds(donorIds, sortedEntries, donorCount)

	local desiredSurplus = boostedTotal(baseWeights, sortedEntries, donorCount) * (multiplier - 1)
	for index, entry in ipairs(sortedEntries) do
		if index > donorCount then
			local baseWeight = baseWeights[entry.id]
			weights[entry.id] = baseWeight * multiplier
		end
	end
	local remainingSurplus = removeSurplusFromDonors(weights, donorIds, desiredSurplus)
	if remainingSurplus > PROBABILITY_EPSILON then
		return nil, "insufficient-donor-weight"
	end

	return weights
end

function RollChances.ToPercentages(weights)
	local total = totalWeight(weights)
	local percentages = {}
	if total <= 0 then
		return percentages
	end

	for id, weight in pairs(weights or {}) do
		percentages[id] = math.max(weight, 0) / total * 100
	end
	return percentages
end

function RollChances.WeightedChoice(weights, rng)
	rng = rng or Random.new()
	local total = totalWeight(weights)
	if total <= 0 then
		return nil
	end

	local roll = rng:NextNumber(0, total)
	local running = 0
	for _, id in ipairs(sortedKeys(weights)) do
		local weight = math.max(tonumber(weights[id]) or 0, 0)
		if weight > 0 then
			running += weight
			if roll <= running then
				return id
			end
		end
	end

	return nil
end

function RollChances.RollCrate(rng)
	local weights = {}
	for crateId, crate in pairs(RollChances.Crates) do
		weights[crateId] = crate.DropWeight
	end
	return RollChances.WeightedChoice(weights, rng)
end

function RollChances.Validate(errors)
	errors = errors or {}

	for crateId, crate in pairs(RollChances.Crates) do
		if type(crate.TemplateName) ~= "string" or crate.TemplateName == "" then
			errors[#errors + 1] = string.format("RollChances crate %s missing TemplateName", tostring(crateId))
		end
		if type(crate.DropWeight) ~= "number" or crate.DropWeight <= 0 then
			errors[#errors + 1] = string.format("RollChances crate %s has invalid DropWeight", tostring(crateId))
		end
		if crate.DonorCount ~= nil and (type(crate.DonorCount) ~= "number" or crate.DonorCount < 0 or crate.DonorCount % 1 ~= 0) then
			errors[#errors + 1] = string.format("RollChances crate %s has invalid DonorCount", tostring(crateId))
		end
		if crate.LuckMultiplier ~= nil and (type(crate.LuckMultiplier) ~= "number" or crate.LuckMultiplier < 1) then
			errors[#errors + 1] = string.format("RollChances crate %s has invalid LuckMultiplier", tostring(crateId))
		end
		if crate.FallDurationMultiplier ~= nil and (type(crate.FallDurationMultiplier) ~= "number" or crate.FallDurationMultiplier <= 0) then
			errors[#errors + 1] = string.format("RollChances crate %s has invalid FallDurationMultiplier", tostring(crateId))
		end
	end

	local positiveCategoryWeight = false
	for category, weight in pairs(RollChances.CategoryWeights) do
		if type(category) ~= "string" or category == "" then
			errors[#errors + 1] = "RollChances has invalid reward category key"
		end
		if not isFiniteNumber(weight) or weight < 0 then
			errors[#errors + 1] = string.format("RollChances category %s has invalid weight %q", tostring(category), tostring(weight))
		elseif weight > 0 then
			positiveCategoryWeight = true
		end
	end
	if not positiveCategoryWeight then
		errors[#errors + 1] = "RollChances must have at least one positive category weight"
	end
	if not isFiniteNumber(RollChances.MaxBoostedOutcomeProbability)
		or RollChances.MaxBoostedOutcomeProbability <= 0
		or RollChances.MaxBoostedOutcomeProbability > 1 then
		errors[#errors + 1] = "RollChances MaxBoostedOutcomeProbability must be between 0 and 1"
	end
	if type(RollChances.SeedFallbackId) ~= "string" or RollChances.SeedFallbackId == "" then
		errors[#errors + 1] = "RollChances missing SeedFallbackId"
	end
	local fallbackTotal = 0
	for _, fallback in ipairs(RollChances.SeedFallback) do
		if type(fallback.seedId) ~= "string" or fallback.seedId == "" then
			errors[#errors + 1] = "RollChances SeedFallback entry missing seedId"
		end
		if not isFiniteNumber(fallback.weight) or fallback.weight <= 0 then
			errors[#errors + 1] = string.format("RollChances SeedFallback %s has invalid weight %q", tostring(fallback.seedId), tostring(fallback.weight))
		else
			fallbackTotal += fallback.weight
		end
	end
	if fallbackTotal <= 0 then
		errors[#errors + 1] = "RollChances SeedFallback must have positive total weight"
	end

	return #errors == 0
end

return RollChances
