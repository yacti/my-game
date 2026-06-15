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
RollChances.MaxBoundaryJumpRatio = 3
RollChances.TransitionBandSize = 2
RollChances.TransitionMultiplierFractions = { 2 / 7, 9 / 14 }
RollChances.LowLuckDelayedTrueStartMultiplier = 3

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

local function transitionFractionsForBand(bandSize)
	local fractions = RollChances.TransitionMultiplierFractions
	local offset = #fractions - bandSize
	local selected = table.create(bandSize)
	for index = 1, bandSize do
		selected[index] = fractions[offset + index]
	end
	return selected
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

local function buildSeedWeightsCandidate(sortedEntries, baseWeights, fallbackWeight, multiplier, trueStart, transitionStart, transitionFractions)
	transitionStart = transitionStart or trueStart
	transitionFractions = transitionFractions or {}

	local trueMass = 0
	for index = trueStart, #sortedEntries do
		trueMass += baseWeights[sortedEntries[index].id] * multiplier
	end

	local transitionMass = 0
	for index = transitionStart, trueStart - 1 do
		local fraction = transitionFractions[index - transitionStart + 1]
		if not isFiniteNumber(fraction) then
			return nil, "invalid-transition-fraction"
		end
		transitionMass += baseWeights[sortedEntries[index].id] * multiplier * fraction
	end

	if trueMass + transitionMass > 1 + PROBABILITY_EPSILON then
		return nil, "transition-overflow"
	end

	local donorMass = 1 - trueMass - transitionMass
	if donorMass < 0 and math.abs(donorMass) <= PROBABILITY_EPSILON then
		donorMass = 0
	end
	if donorMass < 0 then
		return nil, "negative-donor-mass"
	end

	local donorBase = fallbackWeight
	for index = 1, transitionStart - 1 do
		donorBase += baseWeights[sortedEntries[index].id]
	end
	if donorMass > PROBABILITY_EPSILON and donorBase <= PROBABILITY_EPSILON then
		return nil, "missing-donor-weight"
	end

	local donorScale = donorBase > PROBABILITY_EPSILON and donorMass / donorBase or 0
	local weights = {}

	for index = 1, transitionStart - 1 do
		local entry = sortedEntries[index]
		weights[entry.id] = baseWeights[entry.id] * donorScale
	end

	local fallbackMass = fallbackWeight * donorScale
	if fallbackMass > PROBABILITY_EPSILON then
		local fallbackEntries = {}
		local fallbackTotal = 0
		for _, fallback in ipairs(RollChances.SeedFallback) do
			for index = 1, transitionStart - 1 do
				local entry = sortedEntries[index]
				if entry.seedId == fallback.seedId then
					fallbackEntries[#fallbackEntries + 1] = {
						id = entry.id,
						weight = fallback.weight,
					}
					fallbackTotal += fallback.weight
					break
				end
			end
		end

		if fallbackTotal > 0 then
			for _, fallbackEntry in ipairs(fallbackEntries) do
				weights[fallbackEntry.id] = (weights[fallbackEntry.id] or 0) + fallbackMass * (fallbackEntry.weight / fallbackTotal)
			end
		else
			local donorVisibleTotal = 0
			for index = 1, transitionStart - 1 do
				donorVisibleTotal += baseWeights[sortedEntries[index].id]
			end
			if donorVisibleTotal <= PROBABILITY_EPSILON then
				return nil, "missing-fallback-target"
			end
			for index = 1, transitionStart - 1 do
				local entry = sortedEntries[index]
				weights[entry.id] = (weights[entry.id] or 0) + fallbackMass * (baseWeights[entry.id] / donorVisibleTotal)
			end
		end
	end

	for index = transitionStart, trueStart - 1 do
		local entry = sortedEntries[index]
		local fraction = transitionFractions[index - transitionStart + 1]
		weights[entry.id] = baseWeights[entry.id] * multiplier * fraction
	end

	for index = trueStart, #sortedEntries do
		local entry = sortedEntries[index]
		weights[entry.id] = baseWeights[entry.id] * multiplier
	end

	local boundaryRatio = 0
	if transitionStart > 1 and transitionStart <= #sortedEntries then
		local previousEntry = sortedEntries[transitionStart - 1]
		local firstBoostedEntry = sortedEntries[transitionStart]
		local previousWeight = weights[previousEntry.id] or 0
		local firstBoostedWeight = weights[firstBoostedEntry.id] or 0
		if firstBoostedWeight > PROBABILITY_EPSILON then
			boundaryRatio = previousWeight > PROBABILITY_EPSILON and firstBoostedWeight / previousWeight or math.huge
		end
	elseif transitionStart == 1 and #sortedEntries > 0 then
		boundaryRatio = math.huge
	end

	local normalized, code = normalizeFinalWeights(weights)
	if not normalized then
		return nil, code
	end

	return {
		weights = normalized,
		boundaryRatio = boundaryRatio,
		trueStart = trueStart,
		transitionStart = transitionStart,
	}
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
	end

	if category ~= CATEGORY_SEED then
		return weights
	end

	local crateMultiplier = math.max(tonumber(crate.LuckMultiplier) or 1, 1)
	local multiplier = RollChances.EffectiveLuckMultiplier(crateMultiplier, playerLuckPercent, serverLuckMultiplier)

	if multiplier <= 1 then
		local candidate, candidateCode = buildSeedWeightsCandidate(
			sortedEntries,
			baseWeights,
			fallbackWeight,
			1,
			#sortedEntries + 1,
			#sortedEntries + 1,
			{}
		)
		return candidate and candidate.weights or nil, candidateCode
	end

	local trueStart = earliestTrueStart(baseWeights, sortedEntries, multiplier)
	local candidate = nil
	local candidateCode = nil
	if trueStart <= #sortedEntries then
		candidate, candidateCode = buildSeedWeightsCandidate(sortedEntries, baseWeights, fallbackWeight, multiplier, trueStart, trueStart, {})
	else
		candidate, candidateCode = buildSeedWeightsCandidate(
			sortedEntries,
			baseWeights,
			fallbackWeight,
			multiplier,
			#sortedEntries + 1,
			#sortedEntries + 1,
			{}
		)
	end

	local maxBoundaryJumpRatio = RollChances.MaxBoundaryJumpRatio
	if not isFiniteNumber(maxBoundaryJumpRatio) or maxBoundaryJumpRatio <= 1 then
		return nil, "invalid-boundary-jump-ratio"
	end

	if candidate and candidate.boundaryRatio <= maxBoundaryJumpRatio then
		return candidate.weights
	end

	local lowLuckThreshold = RollChances.LowLuckDelayedTrueStartMultiplier

	if trueStart <= #sortedEntries then
		local maxBandSize = math.min(
			math.floor(tonumber(RollChances.TransitionBandSize) or 0),
			#RollChances.TransitionMultiplierFractions,
			trueStart - 1
		)
		for bandSize = maxBandSize, 1, -1 do
			local transitionStart = trueStart - bandSize
			local transitionCandidate = buildSeedWeightsCandidate(
				sortedEntries,
				baseWeights,
				fallbackWeight,
				multiplier,
				trueStart,
				transitionStart,
				transitionFractionsForBand(bandSize)
			)
			if transitionCandidate and transitionCandidate.boundaryRatio <= maxBoundaryJumpRatio then
				return transitionCandidate.weights
			end
		end
	end

	if isFiniteNumber(lowLuckThreshold) and multiplier > lowLuckThreshold and trueStart < #sortedEntries then
		local delayedTrueStart = trueStart + 1
		local maxBandSize = math.min(
			math.floor(tonumber(RollChances.TransitionBandSize) or 0),
			#RollChances.TransitionMultiplierFractions,
			delayedTrueStart - 1
		)
		for bandSize = maxBandSize, 1, -1 do
			local transitionStart = delayedTrueStart - bandSize
			local transitionCandidate = buildSeedWeightsCandidate(
				sortedEntries,
				baseWeights,
				fallbackWeight,
				multiplier,
				delayedTrueStart,
				transitionStart,
				transitionFractionsForBand(bandSize)
			)
			if transitionCandidate and transitionCandidate.boundaryRatio <= maxBoundaryJumpRatio then
				return transitionCandidate.weights
			end
		end
	end

	if isFiniteNumber(lowLuckThreshold) and multiplier <= lowLuckThreshold and trueStart < #sortedEntries then
		local delayedCandidate = nil
		local delayedCode = nil
		for delayedTrueStart = trueStart + 1, #sortedEntries do
			delayedCandidate, delayedCode = buildSeedWeightsCandidate(
				sortedEntries,
				baseWeights,
				fallbackWeight,
				multiplier,
				delayedTrueStart,
				delayedTrueStart,
				{}
			)
			if delayedCandidate and delayedCandidate.boundaryRatio <= maxBoundaryJumpRatio then
				return delayedCandidate.weights
			end
		end
		if delayedCandidate then
			return delayedCandidate.weights
		end
		candidateCode = candidateCode or delayedCode
	end

	if candidate then
		return candidate.weights
	end
	return nil, candidateCode or "invalid-reward-weights"
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
	if not isFiniteNumber(RollChances.MaxBoundaryJumpRatio) or RollChances.MaxBoundaryJumpRatio <= 1 then
		errors[#errors + 1] = "RollChances MaxBoundaryJumpRatio must be greater than 1"
	end
	if not isFiniteNumber(RollChances.TransitionBandSize)
		or RollChances.TransitionBandSize < 0
		or RollChances.TransitionBandSize % 1 ~= 0 then
		errors[#errors + 1] = "RollChances TransitionBandSize must be a nonnegative integer"
	end
	if type(RollChances.TransitionMultiplierFractions) ~= "table" then
		errors[#errors + 1] = "RollChances TransitionMultiplierFractions must be a table"
	else
		if #RollChances.TransitionMultiplierFractions ~= RollChances.TransitionBandSize then
			errors[#errors + 1] = "RollChances TransitionMultiplierFractions must match TransitionBandSize"
		end
		local previousFraction = 0
		for index, fraction in ipairs(RollChances.TransitionMultiplierFractions) do
			if not isFiniteNumber(fraction) or fraction <= 0 or fraction >= 1 then
				errors[#errors + 1] = string.format("RollChances TransitionMultiplierFractions[%d] must be between 0 and 1", index)
			elseif fraction <= previousFraction then
				errors[#errors + 1] = "RollChances TransitionMultiplierFractions must be strictly increasing"
			end
			previousFraction = fraction
		end
	end
	if not isFiniteNumber(RollChances.LowLuckDelayedTrueStartMultiplier)
		or RollChances.LowLuckDelayedTrueStartMultiplier < 1 then
		errors[#errors + 1] = "RollChances LowLuckDelayedTrueStartMultiplier must be at least 1"
	end

	return #errors == 0
end

return RollChances
