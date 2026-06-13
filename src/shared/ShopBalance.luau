local ShopBalance = {}

ShopBalance.SeedPacks = {
	{
		PackId = "SeedPack",
		DisplayName = "Seed Pack",
		DevProductId = 3593513166,
		BuyThreeDevProductId = 3593513259,
		Rewards = {
			{ SeedId = "AppleTreeSeed", Weight = 1 },
			{ SeedId = "AppleTreeSeed", Weight = 1 },
			{ SeedId = "AppleTreeSeed", Weight = 1 },
		},
	},
	{
		PackId = "EpicSeedPack",
		DisplayName = "Epic Seed Pack",
		DevProductId = 3593513368,
		BuyThreeDevProductId = 3604441419,
		Rewards = {
			{ SeedId = "AppleTreeSeed", Weight = 1 },
			{ SeedId = "AppleTreeSeed", Weight = 1 },
			{ SeedId = "AppleTreeSeed", Weight = 1 },
		},
	},
	{
		PackId = "SecretSeedPack",
		DisplayName = "Secret Seed Pack",
		DevProductId = 3604441448,
		BuyThreeDevProductId = 3604441467,
		Rewards = {
			{ SeedId = "AppleTreeSeed", Weight = 1 },
			{ SeedId = "AppleTreeSeed", Weight = 1 },
			{ SeedId = "AppleTreeSeed", Weight = 1 },
		},
	},
}

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function copyReward(reward)
	return {
		SeedId = reward and reward.SeedId or nil,
		Weight = reward and reward.Weight or nil,
	}
end

local function copyPack(pack)
	if type(pack) ~= "table" then
		return nil
	end
	local rewards = {}
	for _, reward in ipairs(pack.Rewards or {}) do
		rewards[#rewards + 1] = copyReward(reward)
	end
	return {
		PackId = pack.PackId,
		DisplayName = pack.DisplayName,
		DevProductId = pack.DevProductId,
		BuyThreeDevProductId = pack.BuyThreeDevProductId,
		Rewards = rewards,
	}
end

local function productId(value)
	return int(value, 0)
end

function ShopBalance.AllSeedPacks()
	local packs = {}
	for _, pack in ipairs(ShopBalance.SeedPacks) do
		packs[#packs + 1] = copyPack(pack)
	end
	return packs
end

function ShopBalance.SeedPackForProductId(productIdValue)
	local target = productId(productIdValue)
	if target <= 0 then
		return nil
	end
	for _, pack in ipairs(ShopBalance.SeedPacks) do
		if productId(pack.DevProductId) == target then
			return copyPack(pack), 1
		end
		if productId(pack.BuyThreeDevProductId) == target then
			return copyPack(pack), 3
		end
	end
	return nil
end

function ShopBalance.TotalWeight(pack)
	local total = 0
	for _, reward in ipairs(pack and pack.Rewards or {}) do
		local weight = tonumber(reward.Weight)
		if type(weight) == "number" and weight > 0 and weight == weight and math.abs(weight) < math.huge then
			total += weight
		end
	end
	return total
end

function ShopBalance.ChanceText(pack, reward)
	local total = ShopBalance.TotalWeight(pack)
	local weight = tonumber(reward and reward.Weight)
	if total <= 0 or type(weight) ~= "number" or weight <= 0 then
		return "0%"
	end
	local percent = (weight / total) * 100
	if math.abs(percent - math.floor(percent + 0.5)) < 0.01 then
		return string.format("%d%%", math.floor(percent + 0.5))
	end
	return string.format("%.1f%%", percent)
end

function ShopBalance.RollSeedPackReward(pack, random)
	local rewards = pack and pack.Rewards
	if type(rewards) ~= "table" then
		return nil
	end
	local total = ShopBalance.TotalWeight(pack)
	if total <= 0 then
		return nil
	end

	local roll = (random or Random.new()):NextNumber(0, total)
	local cumulative = 0
	for index, reward in ipairs(rewards) do
		local weight = tonumber(reward.Weight)
		if type(weight) == "number" and weight > 0 then
			cumulative += weight
			if roll <= cumulative then
				local copy = copyReward(reward)
				copy.ChanceText = ShopBalance.ChanceText(pack, reward)
				return copy
			end
		end
	end

	local fallback = rewards[#rewards]
	if fallback then
		local copy = copyReward(fallback)
		copy.ChanceText = ShopBalance.ChanceText(pack, fallback)
		return copy
	end
	return nil
end

function ShopBalance.Validate(errors)
	errors = errors or {}
	local seenPacks = {}
	local seenProducts = {}

	local function add(message)
		errors[#errors + 1] = message
	end

	local function validateProduct(id, source)
		if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 then
			add(source .. " has invalid developer product id")
			return
		end
		if seenProducts[id] then
			add(string.format("Duplicate seed pack developer product id %d on %s and %s", id, seenProducts[id], source))
			return
		end
		seenProducts[id] = source
	end

	for index, pack in ipairs(ShopBalance.SeedPacks) do
		local source = "ShopBalance.SeedPacks[" .. tostring(index) .. "]"
		if type(pack) ~= "table" then
			add(source .. " must be a table")
			continue
		end
		if type(pack.PackId) ~= "string" or pack.PackId == "" then
			add(source .. " has invalid PackId")
		elseif seenPacks[pack.PackId] then
			add("Duplicate seed pack PackId " .. tostring(pack.PackId))
		else
			seenPacks[pack.PackId] = true
		end
		if type(pack.DisplayName) ~= "string" or pack.DisplayName == "" then
			add(source .. " has invalid DisplayName")
		end

		validateProduct(pack.DevProductId, source .. ".DevProductId")
		validateProduct(pack.BuyThreeDevProductId, source .. ".BuyThreeDevProductId")

		if type(pack.Rewards) ~= "table" or #pack.Rewards ~= 3 then
			add(source .. " must define exactly three Rewards")
		else
			for rewardIndex, reward in ipairs(pack.Rewards) do
				local rewardSource = source .. ".Rewards[" .. tostring(rewardIndex) .. "]"
				if type(reward) ~= "table" then
					add(rewardSource .. " must be a table")
					continue
				end
				if type(reward.SeedId) ~= "string" or reward.SeedId == "" then
					add(rewardSource .. " has invalid SeedId")
				end
				if type(reward.Weight) ~= "number" or reward.Weight <= 0 or reward.Weight ~= reward.Weight or math.abs(reward.Weight) == math.huge then
					add(rewardSource .. " has invalid Weight")
				end
			end
		end
	end

	return #errors == 0
end

return ShopBalance
