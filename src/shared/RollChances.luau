local RollChances = {}

local CATEGORY_SEED = "Seed"
local CATEGORY_MISC = "Misc"
local PROBABILITY_EPSILON = 1e-9
local FINAL_WEIGHT_TOLERANCE = 1e-6

RollChances.CategoryWeights = {
	[CATEGORY_SEED] = 100,
	[CATEGORY_MISC] = 0,
}

RollChances.SeedFallbackId = "__SeedCommonFallback"
RollChances.SeedFallback = {
	{ seedId = "AppleTreeSeed", weight = 50 },
	{ seedId = "PumpkinSeed", weight = 35 },
	{ seedId = "CabbageSeed", weight = 15 },
}
RollChances.SeedDonorRetentionPoints = {
	{ multiplier = 1, retention = 1 },
	{ multiplier = 2, retention = 0.5 },
	{ multiplier = 5, retention = 0.4 },
	{ multiplier = 25, retention = 0.2 },
	{ multiplier = 50, retention = 0 },
}
RollChances.SeedTransitionFullMultiplier = 11
RollChances.SeedCapFullMultiplier = 7
RollChances.SeedMaxFinalWeight = 0.25

-- DropWeights sum to 100, so each weight reads directly as a percentage.
RollChances.Crates = {
	Crate = {
		DisplayName = "Crate",
		DropWeight = 90,
		LuckMultiplier = 1,
		TemplateName = "CommonCrate",
	},
	YellowLuckyBlock = {
		DisplayName = "Yellow Lucky Block",
		DropWeight = 5,
		LuckMultiplier = 5,
		TemplateName = "YellowLuckyBlock",
		FallDurationMultiplier = 2,
	},
	BlueLuckyBlock = {
		DisplayName = "Blue Lucky Block",
		DropWeight = 3,
		LuckMultiplier = 10,
		TemplateName = "BlueLuckyBlock",
		FallDurationMultiplier = 2,
	},
	RedLuckyBlock = {
		DisplayName = "Red Lucky Block",
		DropWeight = 1,
		LuckMultiplier = 25,
		TemplateName = "RedLuckyBlock",
		FallDurationMultiplier = 2,
	},
	PurpleAngelLuckyBlock = {
		DisplayName = "Purple Angel Lucky Block",
		DropWeight = 0.75,
		LuckMultiplier = 50,
		TemplateName = "PurpleAngelLuckyBlock",
		FallDurationMultiplier = 3,
	},
	ChainedLuckyBlock = {
		DisplayName = "Chained Lucky Block",
		DropWeight = 0.25,
		LuckMultiplier = 100,
		TemplateName = "ChainedLuckyBlock",
		FallDurationMultiplier = 4,
	},
}

-- Admin-only crates dropped through the live-events control plane
-- (LiveEvents.DropAdminCrate). They have no DropWeight on purpose: they must
-- never enter the normal RollCrate pool. Templates live under the
-- Assets.Crates.AdminParty subfolder.
RollChances.AdminCrates = {
	InfernoCrate = {
		DisplayName = "Inferno Crate",
		LuckMultiplier = 75,
		TemplateName = "InfernoCrate",
		FallDurationMultiplier = 3,
	},
	SaturnCrate = {
		DisplayName = "Saturn Crate",
		LuckMultiplier = 250,
		TemplateName = "SaturnCrate",
		FallDurationMultiplier = 3,
	},
	UFOCrate = {
		DisplayName = "UFO Crate",
		LuckMultiplier = 1000,
		TemplateName = "UFOCrate",
		FallDurationMultiplier = 4,
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

local function clamp01(value)
	value = tonumber(value) or 0
	if not isFiniteNumber(value) then
		return 0
	end
	if value <= 0 then
		return 0
	end
	if value >= 1 then
		return 1
	end
	return value
end

local function lerp(a, b, t)
	return a + (b - a) * clamp01(t)
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

local function suffixMass(baseWeights, sortedEntries, startIndex, multiplier)
	local total = 0
	for index = startIndex, #sortedEntries do
		total += baseWeights[sortedEntries[index].id] * multiplier
	end
	return total
end

local function earliestTrueStart(baseWeights, sortedEntries, multiplier)
	for index = 1, #sortedEntries do
		if suffixMass(baseWeights, sortedEntries, index, multiplier) <= 1 + PROBABILITY_EPSILON then
			return index
		end
	end
	return #sortedEntries + 1
end

local function clampTinyWeight(weight)
	if math.abs(weight) <= PROBABILITY_EPSILON then
		return 0
	end
	return weight
end

local function normalizeFinalWeights(weights)
	local total = 0
	for id, weight in pairs(weights) do
		if not isFiniteNumber(weight) then
			return nil, "invalid-roll-weight"
		end
		weight = clampTinyWeight(weight)
		if weight < 0 then
			return nil, "negative-roll-weight"
		end
		weights[id] = weight
		total += weight
	end

	if total <= PROBABILITY_EPSILON then
		return nil, "empty-roll-pool"
	end
	if math.abs(total - 1) > FINAL_WEIGHT_TOLERANCE then
		return nil, "roll-weight-total-mismatch"
	end
	for id, weight in pairs(weights) do
		weights[id] = weight / total
	end
	return weights
end

local function normalizeWeights(weights)
	local total = 0
	local normalized = {}
	for id, weight in pairs(weights) do
		if not isFiniteNumber(weight) then
			return nil, "invalid-roll-weight"
		end
		weight = clampTinyWeight(weight)
		if weight < 0 then
			return nil, "negative-roll-weight"
		end
		if weight > 0 then
			normalized[id] = weight
			total += weight
		end
	end

	if total <= PROBABILITY_EPSILON then
		return nil, "empty-roll-pool"
	end
	for id, weight in pairs(normalized) do
		normalized[id] = weight / total
	end
	return normalized
end

local function piecewiseDonorRetention(multiplier)
	multiplier = math.max(tonumber(multiplier) or 1, 1)
	local points = RollChances.SeedDonorRetentionPoints
	if type(points) ~= "table" or #points == 0 then
		return 1
	end

	local previous = points[1]
	local previousMultiplier = tonumber(previous and previous.multiplier) or 1
	local previousRetention = clamp01(previous and previous.retention)
	if multiplier <= previousMultiplier then
		return previousRetention
	end

	for index = 2, #points do
		local current = points[index]
		local currentMultiplier = tonumber(current and current.multiplier)
		local currentRetention = clamp01(current and current.retention)
		if isFiniteNumber(currentMultiplier) and currentMultiplier > previousMultiplier then
			if multiplier <= currentMultiplier then
				return lerp(previousRetention, currentRetention, (multiplier - previousMultiplier) / (currentMultiplier - previousMultiplier))
			end
			previousMultiplier = currentMultiplier
			previousRetention = currentRetention
		end
	end

	return previousRetention
end

local function transitionMultiplierForLuck(multiplier)
	multiplier = math.max(tonumber(multiplier) or 1, 1)
	local fullMultiplier = tonumber(RollChances.SeedTransitionFullMultiplier) or 1
	if not isFiniteNumber(fullMultiplier) or fullMultiplier <= 1 then
		return multiplier
	end

	local transitionFraction = clamp01((multiplier - 1) / (fullMultiplier - 1))
	return 1 + ((multiplier - 1) * transitionFraction)
end

local function maxSeedWeightForLuck(multiplier)
	multiplier = math.max(tonumber(multiplier) or 1, 1)
	local fullMultiplier = tonumber(RollChances.SeedCapFullMultiplier) or 1
	local maxFinalWeight = tonumber(RollChances.SeedMaxFinalWeight) or 1
	if not isFiniteNumber(maxFinalWeight) then
		maxFinalWeight = 1
	end
	maxFinalWeight = math.min(math.max(maxFinalWeight, PROBABILITY_EPSILON), 1)
	if not isFiniteNumber(fullMultiplier) or fullMultiplier <= 1 then
		return maxFinalWeight
	end

	return lerp(1, maxFinalWeight, (multiplier - 1) / (fullMultiplier - 1))
end

local function buildVisibleSeedBaseWeights(sortedEntries, baseWeights, fallbackWeight)
	local weights = {}
	local seedIdToEntryId = {}
	local baseTotal = 0
	for _, entry in ipairs(sortedEntries) do
		local baseWeight = baseWeights[entry.id] or 0
		weights[entry.id] = baseWeight
		baseTotal += baseWeight
		if type(entry.seedId) == "string" and entry.seedId ~= "" then
			seedIdToEntryId[entry.seedId] = entry.id
		end
	end

	if fallbackWeight <= PROBABILITY_EPSILON then
		return weights
	end

	local fallbackTotal = 0
	local fallbackEntries = {}
	for _, fallback in ipairs(RollChances.SeedFallback) do
		local entryId = seedIdToEntryId[fallback.seedId]
		local weight = tonumber(fallback.weight) or 0
		if entryId and weight > 0 then
			fallbackEntries[#fallbackEntries + 1] = {
				id = entryId,
				weight = weight,
			}
			fallbackTotal += weight
		end
	end

	if fallbackTotal > 0 then
		for _, fallbackEntry in ipairs(fallbackEntries) do
			weights[fallbackEntry.id] = (weights[fallbackEntry.id] or 0) + fallbackWeight * (fallbackEntry.weight / fallbackTotal)
		end
	elseif baseTotal > PROBABILITY_EPSILON then
		for _, entry in ipairs(sortedEntries) do
			weights[entry.id] = (weights[entry.id] or 0) + fallbackWeight * ((baseWeights[entry.id] or 0) / baseTotal)
		end
	end

	return weights
end

local function applyMaxWeightCap(weights, maxWeight)
	local normalized, code = normalizeWeights(weights)
	if not normalized then
		return nil, code
	end

	maxWeight = tonumber(maxWeight) or 1
	if not isFiniteNumber(maxWeight) or maxWeight >= 1 then
		return normalized
	end
	maxWeight = math.max(maxWeight, PROBABILITY_EPSILON)

	local activeIds = {}
	for id, weight in pairs(normalized) do
		if weight > PROBABILITY_EPSILON then
			activeIds[#activeIds + 1] = id
		end
	end
	table.sort(activeIds)

	local cappedWeights = {}
	local remainingMass = 1
	while #activeIds > 0 do
		local activeTotal = totalWeight(normalized, activeIds)
		if activeTotal <= PROBABILITY_EPSILON then
			break
		end

		local effectiveCap = math.max(maxWeight, remainingMass / #activeIds)
		local nextActiveIds = {}
		local cappedAny = false
		for _, id in ipairs(activeIds) do
			local weight = remainingMass * normalized[id] / activeTotal
			if weight > effectiveCap + PROBABILITY_EPSILON then
				cappedWeights[id] = effectiveCap
				remainingMass -= effectiveCap
				cappedAny = true
			else
				nextActiveIds[#nextActiveIds + 1] = id
			end
		end

		if not cappedAny then
			for _, id in ipairs(activeIds) do
				cappedWeights[id] = remainingMass * normalized[id] / activeTotal
			end
			return normalizeFinalWeights(cappedWeights)
		end

		activeIds = nextActiveIds
	end

	return normalizeFinalWeights(cappedWeights)
end

local function buildFinalSeedWeights(sortedEntries, baseWeights, visibleBaseWeights, multiplier, cutoffIndex)
	if #sortedEntries == 0 then
		return nil, "empty-roll-pool"
	end

	if multiplier <= 1 then
		return applyMaxWeightCap(visibleBaseWeights, maxSeedWeightForLuck(multiplier))
	end

	cutoffIndex = math.min(math.max(math.floor(tonumber(cutoffIndex) or #sortedEntries), 1), #sortedEntries)
	local donorRetention = piecewiseDonorRetention(multiplier)
	local transitionMultiplier = transitionMultiplierForLuck(multiplier)
	local weights = {}

	for index, entry in ipairs(sortedEntries) do
		if index < cutoffIndex then
			weights[entry.id] = (visibleBaseWeights[entry.id] or baseWeights[entry.id] or 0) * donorRetention
		elseif index == cutoffIndex then
			weights[entry.id] = (baseWeights[entry.id] or 0) * transitionMultiplier
		else
			weights[entry.id] = (baseWeights[entry.id] or 0) * multiplier
		end
	end

	return applyMaxWeightCap(weights, maxSeedWeightForLuck(multiplier))
end

function RollChances.GetCrate(crateId)
	-- Admin crates resolve here too so reward-weight math works for them, but
	-- RollCrate only ever draws from RollChances.Crates.
	return RollChances.Crates[crateId] or RollChances.AdminCrates[crateId]
end

function RollChances.GetAdminCrate(crateId)
	if type(crateId) ~= "string" then
		return nil
	end
	return RollChances.AdminCrates[crateId]
end

function RollChances.AdminCrateIds()
	local ids = {}
	for crateId in pairs(RollChances.AdminCrates) do
		ids[#ids + 1] = crateId
	end
	table.sort(ids)
	return ids
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

function RollChances.EffectiveLuckMultiplier(crateLuckMultiplier, playerLuckPercent, serverLuckMultiplier, adminLuckMultiplier)
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
	adminLuckMultiplier = tonumber(adminLuckMultiplier) or 1
	if type(adminLuckMultiplier) ~= "number" or adminLuckMultiplier ~= adminLuckMultiplier or math.abs(adminLuckMultiplier) == math.huge then
		adminLuckMultiplier = 1
	end
	local serverLuckTerm = serverLuckMultiplier > 1 and (serverLuckMultiplier - 1) or 0
	local adminLuckTerm = adminLuckMultiplier > 1 and (adminLuckMultiplier - 1) or 0
	local playerLuckTerm = playerLuckPercent / 100

	-- Luck sources add together so crate, player, server, and admin luck do not scale explosively.
	return math.max(crateLuckMultiplier + playerLuckTerm + serverLuckTerm + adminLuckTerm, 1)
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
	end

	if category ~= CATEGORY_SEED then
		return weights
	end

	local crateMultiplier = math.max(tonumber(crate.LuckMultiplier) or 1, 1)
	local adminLuckMultiplier = type(options) == "table" and options.adminLuckMultiplier or nil
	local multiplier = RollChances.EffectiveLuckMultiplier(crateMultiplier, playerLuckPercent, serverLuckMultiplier, adminLuckMultiplier)
	local visibleBaseWeights = buildVisibleSeedBaseWeights(sortedEntries, baseWeights, fallbackWeight)
	local cutoffIndex = earliestTrueStart(baseWeights, sortedEntries, multiplier)
	return buildFinalSeedWeights(sortedEntries, baseWeights, visibleBaseWeights, multiplier, cutoffIndex)
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
		if crate.LuckMultiplier ~= nil and (type(crate.LuckMultiplier) ~= "number" or crate.LuckMultiplier < 1) then
			errors[#errors + 1] = string.format("RollChances crate %s has invalid LuckMultiplier", tostring(crateId))
		end
		if crate.FallDurationMultiplier ~= nil and (type(crate.FallDurationMultiplier) ~= "number" or crate.FallDurationMultiplier <= 0) then
			errors[#errors + 1] = string.format("RollChances crate %s has invalid FallDurationMultiplier", tostring(crateId))
		end
	end

	for crateId, crate in pairs(RollChances.AdminCrates) do
		if RollChances.Crates[crateId] ~= nil then
			errors[#errors + 1] = string.format("RollChances admin crate %s collides with a pool crate id", tostring(crateId))
		end
		if type(crate.TemplateName) ~= "string" or crate.TemplateName == "" then
			errors[#errors + 1] = string.format("RollChances admin crate %s missing TemplateName", tostring(crateId))
		end
		if crate.DropWeight ~= nil then
			errors[#errors + 1] = string.format("RollChances admin crate %s must not define DropWeight", tostring(crateId))
		end
		if type(crate.LuckMultiplier) ~= "number" or crate.LuckMultiplier < 1 then
			errors[#errors + 1] = string.format("RollChances admin crate %s has invalid LuckMultiplier", tostring(crateId))
		end
		if crate.FallDurationMultiplier ~= nil and (type(crate.FallDurationMultiplier) ~= "number" or crate.FallDurationMultiplier <= 0) then
			errors[#errors + 1] = string.format("RollChances admin crate %s has invalid FallDurationMultiplier", tostring(crateId))
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
	if type(RollChances.SeedDonorRetentionPoints) ~= "table" or #RollChances.SeedDonorRetentionPoints == 0 then
		errors[#errors + 1] = "RollChances SeedDonorRetentionPoints must be a non-empty table"
	else
		local previousMultiplier = nil
		for index, point in ipairs(RollChances.SeedDonorRetentionPoints) do
			local multiplier = type(point) == "table" and point.multiplier or nil
			local retention = type(point) == "table" and point.retention or nil
			if not isFiniteNumber(multiplier) or multiplier < 1 then
				errors[#errors + 1] = string.format("RollChances SeedDonorRetentionPoints[%d] has invalid multiplier", index)
			elseif previousMultiplier and multiplier <= previousMultiplier then
				errors[#errors + 1] = "RollChances SeedDonorRetentionPoints multipliers must be strictly increasing"
			else
				previousMultiplier = multiplier
			end
			if not isFiniteNumber(retention) or retention < 0 or retention > 1 then
				errors[#errors + 1] = string.format("RollChances SeedDonorRetentionPoints[%d] has invalid retention", index)
			end
		end
	end
	if not isFiniteNumber(RollChances.SeedTransitionFullMultiplier) or RollChances.SeedTransitionFullMultiplier <= 1 then
		errors[#errors + 1] = "RollChances SeedTransitionFullMultiplier must be greater than 1"
	end
	if not isFiniteNumber(RollChances.SeedCapFullMultiplier) or RollChances.SeedCapFullMultiplier <= 1 then
		errors[#errors + 1] = "RollChances SeedCapFullMultiplier must be greater than 1"
	end
	if not isFiniteNumber(RollChances.SeedMaxFinalWeight)
		or RollChances.SeedMaxFinalWeight <= 0
		or RollChances.SeedMaxFinalWeight > 1 then
		errors[#errors + 1] = "RollChances SeedMaxFinalWeight must be between 0 and 1"
	end
	return #errors == 0
end

return RollChances
