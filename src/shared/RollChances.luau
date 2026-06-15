local RollChances = {}

local DEFAULT_LUCK_DONOR_COUNT = 2

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
	while remainingSurplus > 0 do
		local donorTotal = totalWeight(weights, donorIds)
		if donorTotal <= 0 then
			return remainingSurplus
		end

		local removedThisPass = 0
		for _, id in ipairs(donorIds) do
			local current = math.max(tonumber(weights[id]) or 0, 0)
			if current > 0 then
				local reduction = remainingSurplus * (current / donorTotal)
				reduction = math.min(reduction, current)
				weights[id] = current - reduction
				removedThisPass += reduction
			end
		end

		if removedThisPass <= 0 then
			return remainingSurplus
		end
		remainingSurplus -= removedThisPass
	end

	return 0
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
	if type(chanceN) ~= "number" or chanceN ~= chanceN or math.abs(chanceN) == math.huge or chanceN <= 0 then
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
	local serverLuckTerm = serverLuckMultiplier > 1 and serverLuckMultiplier or 0
	local playerLuckTerm = playerLuckPercent / 100

	-- Luck sources add together so crate, player, and server luck do not scale explosively.
	return math.max(crateLuckMultiplier + playerLuckTerm + serverLuckTerm, 1)
end

function RollChances.ComputeRewardWeights(crateId, entries, playerLuckPercent, serverLuckMultiplier)
	local crate = RollChances.GetCrate(crateId)
	if not crate then
		return nil, "unknown-crate"
	end
	if type(entries) ~= "table" or #entries == 0 then
		return nil, "empty-roll-pool"
	end

	local weights = {}
	local baseWeights = {}
	local sortedEntries = sortEntriesByChance(entries)
	for _, entry in ipairs(sortedEntries) do
		local id = entry.id
		local baseWeight = RollChances.BaseWeightForChance(entry.chanceN)
		if type(id) ~= "string" or id == "" or not baseWeight then
			return nil, "invalid-roll-entry"
		end
		weights[id] = baseWeight
		baseWeights[id] = baseWeight
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
	for index = 1, math.min(donorCount, #sortedEntries) do
		donorIds[#donorIds + 1] = sortedEntries[index].id
	end

	local desiredSurplus = 0
	for index, entry in ipairs(sortedEntries) do
		if index > donorCount then
			desiredSurplus += baseWeights[entry.id] * (multiplier - 1)
		end
	end

	local donorTotal = totalWeight(baseWeights, donorIds)
	local appliedSurplus = math.min(desiredSurplus, donorTotal)
	local boostScale = desiredSurplus > 0 and appliedSurplus / desiredSurplus or 0

	for index, entry in ipairs(sortedEntries) do
		if index > donorCount then
			local baseWeight = baseWeights[entry.id]
			weights[entry.id] = baseWeight + baseWeight * (multiplier - 1) * boostScale
		end
	end
	removeSurplusFromDonors(weights, donorIds, appliedSurplus)

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

	return #errors == 0
end

return RollChances
