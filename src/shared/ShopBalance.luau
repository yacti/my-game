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

ShopBalance.CashPacks = {
	{
		PackId = "CashPack1",
		DisplayName = "Cash Pack 1",
		DevProductId = 3604620536,
		HoursOfIncome = 0.25,
		BaseReward = 1000,
		Order = 1,
	},
	{
		PackId = "CashPack2",
		DisplayName = "Cash Pack 2",
		DevProductId = 3604620549,
		HoursOfIncome = 1,
		BaseReward = 5000,
		Order = 2,
	},
	{
		PackId = "CashPack3",
		DisplayName = "Cash Pack 3",
		DevProductId = 3604620570,
		HoursOfIncome = 2,
		BaseReward = 10000,
		Order = 3,
	},
	{
		PackId = "CashPack4",
		DisplayName = "Cash Pack 4",
		DevProductId = 3604620596,
		HoursOfIncome = 5,
		BaseReward = 25000,
		Order = 4,
	},
}

ShopBalance.ServerLuck = {
	DurationSeconds = 15 * 60,
	BaseMultiplier = 1,
	MaxMultiplier = 20,
	Steps = {
		{ FromMultiplier = 1, ToMultiplier = 2, DevProductId = 3604579183 },
		{ FromMultiplier = 2, ToMultiplier = 4, DevProductId = 3604579204 },
		{ FromMultiplier = 4, ToMultiplier = 8, DevProductId = 3604579231 },
		{ FromMultiplier = 8, ToMultiplier = 12, DevProductId = 3604579237 },
		{ FromMultiplier = 12, ToMultiplier = 16, DevProductId = 3604579251 },
		{ FromMultiplier = 16, ToMultiplier = 20, DevProductId = 3604579272 },
	},
}

ShopBalance.StarterPackRewardKinds = {
	Seed = "Seed",
}

ShopBalance.StarterPack = {
	PackId = "StarterPack",
	DisplayName = "Starter Pack",
	DevProductId = 3604596908,
	Rewards = {
		{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "AppleTreeSeed", Amount = 1 },
		{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "AppleTreeSeed", Amount = 1 },
		{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "AppleTreeSeed", Amount = 1 },
		{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "AppleTreeSeed", Amount = 3 },
	},
}

ShopBalance.GamePassKeys = {
	VIP = "VIP",
	Luck2x = "Luck2x",
	Cash2x = "Cash2x",
	FoodXP2x = "FoodXP2x",
}

ShopBalance.GamePasses = {
	VIP = {
		Key = "VIP",
		DisplayName = "VIP",
		GamePassId = 1875159706,
		ShopCardName = "VIP",
		FeaturedCardName = "VIP",
		PetCashMultiplier = 1.25,
		LuckBonusPercent = 25,
		Order = 1,
	},
	Luck2x = {
		Key = "Luck2x",
		DisplayName = "x2 Luck",
		GamePassId = 1874769695,
		ShopCardName = "x2Luck",
		LuckBonusPercent = 100,
		Order = 2,
	},
	Cash2x = {
		Key = "Cash2x",
		DisplayName = "x2 Cash",
		GamePassId = 1874365753,
		ShopCardName = "x2Cash",
		PetCashMultiplier = 2,
		Order = 3,
	},
	FoodXP2x = {
		Key = "FoodXP2x",
		DisplayName = "x2 Food XP",
		GamePassId = 1876239739,
		ShopCardName = "x2XP",
		FoodXPMultiplier = 2,
		Order = 4,
	},
}

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function finiteNumber(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback or 0
	end
	return value
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

local function copyStarterPackReward(reward)
	return {
		Kind = reward and reward.Kind or nil,
		SeedId = reward and reward.SeedId or nil,
		Amount = int(reward and reward.Amount, 0),
	}
end

local function copyStarterPack(pack)
	if type(pack) ~= "table" then
		return nil
	end
	local rewards = {}
	for _, reward in ipairs(pack.Rewards or {}) do
		rewards[#rewards + 1] = copyStarterPackReward(reward)
	end
	return {
		PackId = pack.PackId,
		DisplayName = pack.DisplayName,
		DevProductId = pack.DevProductId,
		Rewards = rewards,
	}
end

local function copyCashPack(pack)
	if type(pack) ~= "table" then
		return nil
	end
	return {
		PackId = pack.PackId,
		DisplayName = pack.DisplayName,
		DevProductId = pack.DevProductId,
		HoursOfIncome = finiteNumber(pack.HoursOfIncome, 0),
		BaseReward = int(pack.BaseReward, 0),
		Order = int(pack.Order, 0),
	}
end

local function copyGamePass(config)
	if type(config) ~= "table" then
		return nil
	end
	local petCashMultiplier = finiteNumber(config.PetCashMultiplier or config.PetCashEarnRate, 1)
	return {
		Key = config.Key,
		DisplayName = config.DisplayName,
		GamePassId = int(config.GamePassId, 0),
		ShopCardName = config.ShopCardName,
		FeaturedCardName = config.FeaturedCardName,
		PetCashMultiplier = petCashMultiplier,
		PetCashEarnRate = petCashMultiplier,
		LuckBonusPercent = finiteNumber(config.LuckBonusPercent, 0),
		FoodXPMultiplier = finiteNumber(config.FoodXPMultiplier, 1),
		Order = int(config.Order, 0),
	}
end

local function productId(value)
	return int(value, 0)
end

local function copyServerLuckStep(step)
	if type(step) ~= "table" then
		return nil
	end
	return {
		FromMultiplier = step.FromMultiplier,
		ToMultiplier = step.ToMultiplier,
		DevProductId = step.DevProductId,
	}
end

local function serverLuckSteps()
	local config = ShopBalance.ServerLuck
	return type(config) == "table" and config.Steps or {}
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

function ShopBalance.AllCashPacks()
	local packs = {}
	for _, pack in ipairs(ShopBalance.CashPacks or {}) do
		local copy = copyCashPack(pack)
		if copy then
			packs[#packs + 1] = copy
		end
	end
	table.sort(packs, function(a, b)
		local orderA = tonumber(a.Order) or 0
		local orderB = tonumber(b.Order) or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return tostring(a.PackId) < tostring(b.PackId)
	end)
	return packs
end

function ShopBalance.CashPackForProductId(productIdValue)
	local target = productId(productIdValue)
	if target <= 0 then
		return nil
	end
	for _, pack in ipairs(ShopBalance.CashPacks or {}) do
		if productId(pack.DevProductId) == target then
			return copyCashPack(pack)
		end
	end
	return nil
end

function ShopBalance.GetStarterPack()
	return copyStarterPack(ShopBalance.StarterPack)
end

function ShopBalance.GetVIP()
	return ShopBalance.GamePassForKey(ShopBalance.GamePassKeys.VIP)
end

function ShopBalance.VIPGamePassId()
	local config = ShopBalance.GamePasses[ShopBalance.GamePassKeys.VIP]
	return productId(config and config.GamePassId)
end

function ShopBalance.GamePassForKey(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end
	local config = ShopBalance.GamePasses[key]
	return copyGamePass(config)
end

function ShopBalance.GamePassForId(gamePassId)
	local target = productId(gamePassId)
	if target <= 0 then
		return nil
	end
	for _, pass in pairs(ShopBalance.GamePasses) do
		if productId(pass.GamePassId) == target then
			return copyGamePass(pass)
		end
	end
	return nil
end

function ShopBalance.GamePassIdForKey(key)
	local config = type(key) == "string" and ShopBalance.GamePasses[key] or nil
	return productId(config and config.GamePassId)
end

function ShopBalance.AllGamePasses()
	local passes = {}
	for key, config in pairs(ShopBalance.GamePasses) do
		local pass = copyGamePass(config)
		if pass then
			pass.Key = type(pass.Key) == "string" and pass.Key ~= "" and pass.Key or key
			passes[#passes + 1] = pass
		end
	end
	table.sort(passes, function(a, b)
		local orderA = tonumber(a.Order) or 0
		local orderB = tonumber(b.Order) or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return tostring(a.Key) < tostring(b.Key)
	end)
	return passes
end

function ShopBalance.StarterPackForProductId(productIdValue)
	local target = productId(productIdValue)
	local pack = ShopBalance.StarterPack
	if target <= 0 or type(pack) ~= "table" or productId(pack.DevProductId) ~= target then
		return nil
	end
	return copyStarterPack(pack)
end

function ShopBalance.StarterPackTotalAmount(pack)
	local total = 0
	for _, reward in ipairs(pack and pack.Rewards or {}) do
		total += int(reward and reward.Amount, 0)
	end
	return total
end

function ShopBalance.AllServerLuckSteps()
	local steps = {}
	for _, step in ipairs(serverLuckSteps()) do
		steps[#steps + 1] = copyServerLuckStep(step)
	end
	return steps
end

function ShopBalance.ServerLuckStepForProductId(productIdValue)
	local target = productId(productIdValue)
	if target <= 0 then
		return nil
	end
	for _, step in ipairs(serverLuckSteps()) do
		if productId(step.DevProductId) == target then
			return copyServerLuckStep(step)
		end
	end
	return nil
end

function ShopBalance.ServerLuckStepForCurrentMultiplier(multiplier)
	local config = ShopBalance.ServerLuck
	local maxMultiplier = int(config and config.MaxMultiplier, 1)
	local current = int(multiplier, 1)
	local fallback = nil
	for _, step in ipairs(serverLuckSteps()) do
		fallback = step
		if current < int(step.ToMultiplier, 1) then
			return copyServerLuckStep(step)
		end
	end
	if current >= maxMultiplier and fallback then
		return copyServerLuckStep(fallback)
	end
	return nil
end

function ShopBalance.ServerLuckNextMultiplier(multiplier)
	local config = ShopBalance.ServerLuck
	local baseMultiplier = int(config and config.BaseMultiplier, 1)
	local step = ShopBalance.ServerLuckStepForCurrentMultiplier(multiplier)
	if not step then
		return baseMultiplier
	end
	return int(step.ToMultiplier, baseMultiplier)
end

function ShopBalance.ServerLuckProductForCurrentMultiplier(multiplier)
	local step = ShopBalance.ServerLuckStepForCurrentMultiplier(multiplier)
	return step and productId(step.DevProductId) or 0
end

function ShopBalance.RoundCashPackAmount(amount)
	amount = finiteNumber(amount, 0)
	if amount <= 0 then
		return 0
	end
	local step = 1
	while amount / step >= 100 do
		step *= 10
	end
	if amount >= 1000 then
		local displayUnit = 1000
		while amount / displayUnit >= 1000 do
			displayUnit *= 1000
		end
		if amount / displayUnit >= 5 and step < displayUnit then
			step = displayUnit
		end
	end
	return math.max(math.floor((amount / step) + 0.5) * step, 1)
end

function ShopBalance.CashPackPayout(pack, hourlyIncome)
	if type(pack) ~= "table" then
		return 0
	end
	local hours = finiteNumber(pack.HoursOfIncome, 0)
	if hours <= 0 then
		return 0
	end
	local baseReward = int(pack.BaseReward, 0)
	local incomeReward = ShopBalance.RoundCashPackAmount(finiteNumber(hourlyIncome, 0) * hours)
	return math.max(baseReward, incomeReward)
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
	local seenGamePasses = {}

	local function add(message)
		errors[#errors + 1] = message
	end

	local function validateProduct(id, source)
		if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 then
			add(source .. " has invalid developer product id")
			return
		end
		if seenProducts[id] then
			add(string.format("Duplicate ShopBalance developer product id %d on %s and %s", id, seenProducts[id], source))
			return
		end
		seenProducts[id] = source
	end

	local function validateGamePass(id, source)
		if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 then
			add(source .. " has invalid gamepass id")
			return
		end
		if seenGamePasses[id] then
			add(string.format("Duplicate ShopBalance gamepass id %d on %s and %s", id, seenGamePasses[id], source))
			return
		end
		seenGamePasses[id] = source
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

	local cashPacks = ShopBalance.CashPacks
	if type(cashPacks) ~= "table" or #cashPacks ~= 4 then
		add("ShopBalance.CashPacks must define exactly four packs")
	else
		local seenCashPackIds = {}
		for index, pack in ipairs(cashPacks) do
			local source = "ShopBalance.CashPacks[" .. tostring(index) .. "]"
			if type(pack) ~= "table" then
				add(source .. " must be a table")
				continue
			end
			if type(pack.PackId) ~= "string" or pack.PackId == "" then
				add(source .. " has invalid PackId")
			elseif seenPacks[pack.PackId] or seenCashPackIds[pack.PackId] then
				add("Duplicate shop PackId " .. tostring(pack.PackId))
			else
				seenCashPackIds[pack.PackId] = true
				seenPacks[pack.PackId] = true
			end
			if type(pack.DisplayName) ~= "string" or pack.DisplayName == "" then
				add(source .. " has invalid DisplayName")
			end
			validateProduct(pack.DevProductId, source .. ".DevProductId")
			if type(pack.HoursOfIncome) ~= "number"
				or pack.HoursOfIncome <= 0
				or pack.HoursOfIncome ~= pack.HoursOfIncome
				or math.abs(pack.HoursOfIncome) == math.huge then
				add(source .. " has invalid HoursOfIncome")
			end
			if type(pack.BaseReward) ~= "number"
				or pack.BaseReward <= 0
				or pack.BaseReward ~= pack.BaseReward
				or math.abs(pack.BaseReward) == math.huge
				or pack.BaseReward % 1 ~= 0 then
				add(source .. " has invalid BaseReward")
			end
			if type(pack.Order) ~= "number" or pack.Order <= 0 or pack.Order % 1 ~= 0 then
				add(source .. " has invalid Order")
			end
		end
	end

	local starterPack = ShopBalance.StarterPack
	if type(starterPack) ~= "table" then
		add("ShopBalance.StarterPack must be a table")
	else
		local source = "ShopBalance.StarterPack"
		if type(starterPack.PackId) ~= "string" or starterPack.PackId == "" then
			add(source .. " has invalid PackId")
		elseif seenPacks[starterPack.PackId] then
			add("Duplicate shop PackId " .. tostring(starterPack.PackId))
		else
			seenPacks[starterPack.PackId] = true
		end
		if type(starterPack.DisplayName) ~= "string" or starterPack.DisplayName == "" then
			add(source .. " has invalid DisplayName")
		end
		validateProduct(starterPack.DevProductId, source .. ".DevProductId")

		if type(starterPack.Rewards) ~= "table" or #starterPack.Rewards ~= 4 then
			add(source .. " must define exactly four Rewards")
		else
			for rewardIndex, reward in ipairs(starterPack.Rewards) do
				local rewardSource = source .. ".Rewards[" .. tostring(rewardIndex) .. "]"
				if type(reward) ~= "table" then
					add(rewardSource .. " must be a table")
					continue
				end
				if reward.Kind ~= ShopBalance.StarterPackRewardKinds.Seed then
					add(rewardSource .. " has invalid Kind")
				end
				if type(reward.SeedId) ~= "string" or reward.SeedId == "" then
					add(rewardSource .. " has invalid SeedId")
				end
				if type(reward.Amount) ~= "number"
					or reward.Amount <= 0
					or reward.Amount ~= reward.Amount
					or math.abs(reward.Amount) == math.huge
					or reward.Amount % 1 ~= 0 then
					add(rewardSource .. " has invalid Amount")
				end
			end
		end
	end

	local serverLuck = ShopBalance.ServerLuck
	if type(serverLuck) ~= "table" then
		add("ShopBalance.ServerLuck must be a table")
	else
		if type(serverLuck.DurationSeconds) ~= "number" or serverLuck.DurationSeconds <= 0 or serverLuck.DurationSeconds % 1 ~= 0 then
			add("ShopBalance.ServerLuck has invalid DurationSeconds")
		end
		if type(serverLuck.BaseMultiplier) ~= "number" or serverLuck.BaseMultiplier < 1 or serverLuck.BaseMultiplier % 1 ~= 0 then
			add("ShopBalance.ServerLuck has invalid BaseMultiplier")
		end
		if type(serverLuck.MaxMultiplier) ~= "number" or serverLuck.MaxMultiplier < 1 or serverLuck.MaxMultiplier % 1 ~= 0 then
			add("ShopBalance.ServerLuck has invalid MaxMultiplier")
		end
		if type(serverLuck.Steps) ~= "table" or #serverLuck.Steps == 0 then
			add("ShopBalance.ServerLuck must define Steps")
		else
			local expectedFrom = int(serverLuck.BaseMultiplier, 1)
			for index, step in ipairs(serverLuck.Steps) do
				local source = "ShopBalance.ServerLuck.Steps[" .. tostring(index) .. "]"
				if type(step) ~= "table" then
					add(source .. " must be a table")
					continue
				end
				if type(step.FromMultiplier) ~= "number" or step.FromMultiplier ~= expectedFrom or step.FromMultiplier % 1 ~= 0 then
					add(source .. " has invalid FromMultiplier")
				end
				if type(step.ToMultiplier) ~= "number"
					or step.ToMultiplier <= expectedFrom
					or step.ToMultiplier % 1 ~= 0
					or step.ToMultiplier > int(serverLuck.MaxMultiplier, 1) then
					add(source .. " has invalid ToMultiplier")
				end
				validateProduct(step.DevProductId, source .. ".DevProductId")
				expectedFrom = int(step.ToMultiplier, expectedFrom)
			end
			if expectedFrom ~= int(serverLuck.MaxMultiplier, 1) then
				add("ShopBalance.ServerLuck.Steps must end at MaxMultiplier")
			end
		end
	end

	local gamePasses = ShopBalance.GamePasses
	if type(gamePasses) ~= "table" then
		add("ShopBalance.GamePasses must be a table")
	else
		for key, pass in pairs(gamePasses) do
			local source = "ShopBalance.GamePasses." .. tostring(key)
			if type(pass) ~= "table" then
				add(source .. " must be a table")
				continue
			end
			if type(key) ~= "string" or key == "" then
				add(source .. " has invalid key")
			end
			if type(pass.Key) ~= "string" or pass.Key == "" then
				add(source .. " has invalid Key")
			elseif pass.Key ~= key then
				add(source .. ".Key must match its GamePasses key")
			end
			if type(pass.DisplayName) ~= "string" or pass.DisplayName == "" then
				add(source .. " has invalid DisplayName")
			end
			if type(pass.ShopCardName) ~= "string" or pass.ShopCardName == "" then
				add(source .. " has invalid ShopCardName")
			end
			validateGamePass(pass.GamePassId, source .. ".GamePassId")

			local petCashMultiplier = pass.PetCashMultiplier
			if petCashMultiplier ~= nil and (type(petCashMultiplier) ~= "number"
				or petCashMultiplier <= 0
				or petCashMultiplier ~= petCashMultiplier
				or math.abs(petCashMultiplier) == math.huge) then
				add(source .. " has invalid PetCashMultiplier")
			end
			local foodXPMultiplier = pass.FoodXPMultiplier
			if foodXPMultiplier ~= nil and (type(foodXPMultiplier) ~= "number"
				or foodXPMultiplier <= 0
				or foodXPMultiplier ~= foodXPMultiplier
				or math.abs(foodXPMultiplier) == math.huge) then
				add(source .. " has invalid FoodXPMultiplier")
			end
			local luckBonusPercent = pass.LuckBonusPercent
			if luckBonusPercent ~= nil and (type(luckBonusPercent) ~= "number"
				or luckBonusPercent < 0
				or luckBonusPercent ~= luckBonusPercent
				or math.abs(luckBonusPercent) == math.huge) then
				add(source .. " has invalid LuckBonusPercent")
			end
		end
	end

	return #errors == 0
end

return ShopBalance
