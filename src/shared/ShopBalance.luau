local Rarities = require(script.Parent:WaitForChild("Rarities"))

local ShopBalance = {}

ShopBalance.SeedPacks = {
	{
		PackId = "SeedPack",
		DisplayName = "Seed Pack",
		Rarity = Rarities.Rare,
		DevProductId = 3593513166,
		BuyThreeDevProductId = 3593513259,
		Products = {
			{ Quantity = 1, DevProductId = 3593513166 },
			{ Quantity = 3, DevProductId = 3593513259 },
		},
		Rewards = {
			{ SeedId = "OrangeTreeSeed", Weight = 60 },
			{ SeedId = "WatermelonSeed", Weight = 35 },
			{ SeedId = "CherryTreeSeed", Weight = 5 },
		},
	},
	{
		PackId = "EpicSeedPack",
		DisplayName = "Epic Seed Pack",
		Rarity = Rarities.Epic,
		DevProductId = 3593513368,
		BuyThreeDevProductId = 3604441419,
		Products = {
			{ Quantity = 1, DevProductId = 3593513368 },
			{ Quantity = 3, DevProductId = 3604441419 },
		},
		Rewards = {
			{ SeedId = "CornSeed", Weight = 50 },
			{ SeedId = "MushroomSeed", Weight = 45 },
			{ SeedId = "PineappleSeed", Weight = 5 },
		},
	},
	{
		PackId = "SecretSeedPack",
		DisplayName = "Secret Seed Pack",
		Rarity = Rarities.Secret,
		DevProductId = 3604441448,
		BuyThreeDevProductId = 3604441467,
		Products = {
			{ Quantity = 1, DevProductId = 3604441448 },
			{ Quantity = 3, DevProductId = 3604441467 },
		},
		Rewards = {
			{ SeedId = "FigTreeSeed", Weight = 66 },
			{ SeedId = "GlowshroomSeed", Weight = 33 },
			{ SeedId = "DurianTreeSeed", Weight = 1 },
		},
	},
}

ShopBalance.PetSkinPack = {
	PackId = "PetSkinPack",
	DisplayName = "Pet Skin Pack",
	Products = {
		{ Quantity = 1, DevProductId = 3613041963 },
		{ Quantity = 12, DevProductId = 3613041996 },
	},
}

-- Standalone Durian Pack feature (HUD entry -> Menu.DurianPackHolder), no
-- longer sold from the RobuxShop seed pack sections. Players buy tickets with
-- Robux; one ticket funds one roll from Rewards. Every PityRollCount-th roll
-- is a guaranteed PitySeedId; naturally rolled durians do not reset the pity
-- counter. CycleSeconds only drives the visual countdown label.
ShopBalance.DurianPack = {
	PackId = "DurianPack",
	DisplayName = "Durian Pack",
	CycleSeconds = 14 * 24 * 60 * 60,
	PityRollCount = 90,
	PitySeedId = "DurianTreeSeed",
	RollCounts = { 1, 3, 10 },
	TicketProducts = {
		{ Tickets = 1, ExtraTickets = 0, DevProductId = 3608999791 },
		{ Tickets = 3, ExtraTickets = 0, DevProductId = 3608999818 },
		{ Tickets = 10, ExtraTickets = 2, DevProductId = 3608999847 },
		{ Tickets = 25, ExtraTickets = 5, DevProductId = 3608999879 },
		{ Tickets = 50, ExtraTickets = 10, DevProductId = 3608999957 },
	},
	-- Retired shop-era DurianPack roll products. Not shown in any UI; pending
	-- receipts convert one purchased roll into one ticket so live players are
	-- never left with an unprocessable purchase. The other three shop-era ids
	-- (3607448072/3607448274/3607448383) were recycled into
	-- ShopBalance.EndlessPack.Products and now route there.
	LegacyTicketProducts = {
		{ Tickets = 1, ExtraTickets = 0, DevProductId = 3607448000 },
	},
	Rewards = {
		{ SeedId = "CherryTreeSeed", Weight = 55 },
		{ SeedId = "PurpleShroomSeed", Weight = 39 },
		{ SeedId = "GlowshroomSeed", Weight = 5 },
		{ SeedId = "DurianTreeSeed", Weight = 1 },
	},
}

ShopBalance.EndlessPackKinds = {
	Money1 = "Money1", -- cash worth MoneyPacks.Money1.MinutesOfIncome of pet income
	Money2 = "Money2",
	SeedPack = "SeedPack", -- one free roll of the matching ShopBalance.SeedPacks entry
	EpicSeedPack = "EpicSeedPack",
	SeedGrant = "SeedGrant", -- deterministic seed tool chosen by global SeedGrant ordinal
	GrowSkip = "GrowSkip", -- free plot-time grow skip, best-effort (claims even with no growth)
}

-- Endless Pack: an infinite, strictly sequential claim track in the RobuxShop.
-- The 27-entry Cycle repeats forever; every 3rd entry (Paid = true) is a Robux
-- gate that blocks progress until purchased, everything else is a free claim.
-- Money packs at non-paid positions grant their cash payout for free. Paid
-- purchases map to Products by global paid ordinal, capped at the last product
-- (the 9th product is prompted forever after the first cycle). SeedGrant
-- entries walk SeedSchedule once by global ordinal, then loop SeedRotation.
-- CycleSeconds only drives the visual countdown label; progress never resets.
ShopBalance.EndlessPack = {
	PackId = "EndlessPack",
	DisplayName = "Endless Pack",
	CycleSeconds = 14 * 60 * 60,
	GrowSkipSeconds = 5 * 60,
	Icons = {
		Money1 = "rbxassetid://83341129100923",
		Money2 = "rbxassetid://125623245592194",
		GrowSkip = "rbxassetid://128769188913261",
	},
	MoneyPacks = {
		Money1 = { MinutesOfIncome = 2.5, BaseReward = 250 },
		Money2 = { MinutesOfIncome = 5, BaseReward = 500 },
	},
	Products = {
		3607448072,
		3607448274,
		3607448383,
		3609660089,
		3609660117,
		3609660137,
		3609660179,
		3609660205,
		3609660281,
	},
	Cycle = {
		{ Kind = "Money1", Paid = true },
		{ Kind = "SeedPack" },
		{ Kind = "SeedGrant" },
		{ Kind = "Money1", Paid = true },
		{ Kind = "GrowSkip" },
		{ Kind = "Money1" },
		{ Kind = "Money2", Paid = true },
		{ Kind = "SeedGrant" },
		{ Kind = "SeedPack" },
		{ Kind = "Money1", Paid = true },
		{ Kind = "SeedPack" },
		{ Kind = "GrowSkip" },
		{ Kind = "Money2", Paid = true },
		{ Kind = "EpicSeedPack" },
		{ Kind = "Money1" },
		{ Kind = "Money1", Paid = true },
		{ Kind = "SeedPack" },
		{ Kind = "GrowSkip" },
		{ Kind = "Money1", Paid = true },
		{ Kind = "SeedGrant" },
		{ Kind = "SeedPack" },
		{ Kind = "Money1", Paid = true },
		{ Kind = "GrowSkip" },
		{ Kind = "Money2" },
		{ Kind = "Money2", Paid = true },
		{ Kind = "GrowSkip" },
		{ Kind = "EpicSeedPack" },
	},
	SeedSchedule = {
		"OrangeTreeSeed",
		"WatermelonSeed",
		"PlumTreeSeed",
		"CornSeed",
		"CherryTreeSeed",
		"MushroomSeed",
	},
	SeedRotation = {
		"CherryTreeSeed",
		"CornSeed",
		"MushroomSeed",
	},
}

-- Prefix counts over the Endless Pack cycle so item resolution is O(1):
-- endlessPaidOrdinalAt[i] / endlessSeedOrdinalAt[i] = how many Paid / SeedGrant
-- entries exist in Cycle[1..i].
local endlessPaidOrdinalAt = {}
local endlessSeedOrdinalAt = {}
do
	local paidCount = 0
	local seedCount = 0
	for index, entry in ipairs(ShopBalance.EndlessPack.Cycle) do
		if type(entry) == "table" and entry.Paid == true then
			paidCount += 1
		end
		if type(entry) == "table" and entry.Kind == ShopBalance.EndlessPackKinds.SeedGrant then
			seedCount += 1
		end
		endlessPaidOrdinalAt[index] = paidCount
		endlessSeedOrdinalAt[index] = seedCount
	end
end

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
	Cash = "Cash",
	FeedMachine = "FeedMachine",
	Seed = "Seed",
	-- PackId names a ShopBalance.SeedPacks entry; Amount = rolls granted on
	-- purchase. Randomized, so policy-restricted players (paid random items)
	-- get CashFallbackAmount cash instead — see StarterPackRewardsForPolicy.
	SeedPack = "SeedPack",
}

ShopBalance.CashRewardIcon = "rbxassetid://83341129100923"
ShopBalance.CashRewardTextColor = Color3.fromRGB(76, 217, 100)
ShopBalance.StarterPackCycleSeconds = 14 * 60 * 60

ShopBalance.StarterPacks = {
	{
		PackId = "StarterPack",
		DisplayName = "Starter Pack",
		DevProductId = 3604596908,
		MinRebirths = 0,
		MaxRebirths = 0,
		PromptDelaySeconds = 60, -- plot prompt shows this long after tutorial completion
		Rewards = {
			{ Kind = ShopBalance.StarterPackRewardKinds.SeedPack, PackId = "SeedPack", Amount = 1, CashFallbackAmount = 10000 },
			{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "WatermelonSeed", Amount = 1 },
			{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "PlumTreeSeed", Amount = 1 },
		},
	},
	{
		PackId = "FarmerPack",
		DisplayName = "Farmer Pack",
		DevProductId = 3607447742,
		MinRebirths = 1,
		MaxRebirths = 2,
		PromptDelaySeconds = 30, -- plot prompt shows this long after rebirth eligibility
		Rewards = {
			{ Kind = ShopBalance.StarterPackRewardKinds.SeedPack, PackId = "EpicSeedPack", Amount = 1, CashFallbackAmount = 100000 },
			{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "MushroomSeed", Amount = 1 },
			{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "CactusSeed", Amount = 1 },
		},
	},
	{
		PackId = "LegendaryFarmerPack",
		DisplayName = "Legendary Farmer Pack",
		DevProductId = 3607447786,
		MinRebirths = 3,
		MaxRebirths = nil,
		PromptDelaySeconds = 30, -- plot prompt shows this long after rebirth eligibility
		Rewards = {
			{ Kind = ShopBalance.StarterPackRewardKinds.SeedPack, PackId = "EpicSeedPack", Amount = 1, CashFallbackAmount = 2500000 },
			{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "FigTreeSeed", Amount = 1 },
			{ Kind = ShopBalance.StarterPackRewardKinds.Seed, SeedId = "PurpleShroomSeed", Amount = 1 },
		},
	},
}
ShopBalance.StarterPack = ShopBalance.StarterPacks[1]

-- StealSetting A/B test. The "normal" control charges DevProductId for every
-- steal; the "tiered" treatment charges the product matching the stolen food's
-- rarity. Foods whose rarity cannot be resolved fall back to FallbackTierRarity.
ShopBalance.FoodSteal = {
	DevProductId = 3604630642,
	TierDevProductIds = {
		[Rarities.Common] = 3612202316,
		[Rarities.Rare] = 3612202346,
		[Rarities.Epic] = 3612202363,
		[Rarities.Legendary] = 3612202372,
		[Rarities.Mythical] = 3612202401,
		[Rarities.Secret] = 3612202439,
		[Rarities.Exclusive] = 3612203098,
	},
	FallbackTierRarity = Rarities.Common,
}

ShopBalance.GrowSkip = {
	DevProductId = 3604690049, -- Targeted growing tree skip prompt.
	Skips = {
		{
			SkipId = "Skip5m",
			DisplayName = "Skip 5m",
			DevProductId = 3607255791,
			DurationSeconds = 5 * 60,
			Order = 1,
		},
		{
			SkipId = "Skip30m",
			DisplayName = "Skip 30m",
			DevProductId = 3607255816,
			DurationSeconds = 30 * 60,
			Order = 2,
		},
	},
}

ShopBalance.CollectAll = {
	DevProductId = 3607271856,
	DisplayName = "Collect All",
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

local function seedPackProducts(pack)
	local products = {}
	if type(pack) == "table" and type(pack.Products) == "table" then
		for _, product in ipairs(pack.Products) do
			if type(product) == "table" then
				products[#products + 1] = {
					Quantity = int(product.Quantity, 0),
					DevProductId = int(product.DevProductId, 0),
				}
			end
		end
	end
	if #products == 0 and type(pack) == "table" then
		local oneProductId = int(pack.DevProductId, 0)
		if oneProductId > 0 then
			products[#products + 1] = {
				Quantity = 1,
				DevProductId = oneProductId,
			}
		end
		local threeProductId = int(pack.BuyThreeDevProductId, 0)
		if threeProductId > 0 then
			products[#products + 1] = {
				Quantity = 3,
				DevProductId = threeProductId,
			}
		end
	end
	table.sort(products, function(a, b)
		if a.Quantity ~= b.Quantity then
			return a.Quantity < b.Quantity
		end
		return a.DevProductId < b.DevProductId
	end)
	return products
end

local function copyPack(pack)
	if type(pack) ~= "table" then
		return nil
	end
	local rewards = {}
	for _, reward in ipairs(pack.Rewards or {}) do
		rewards[#rewards + 1] = copyReward(reward)
	end
	local products = seedPackProducts(pack)
	local oneProduct = products[1]
	local threeProduct = nil
	for _, product in ipairs(products) do
		if product.Quantity == 1 then
			oneProduct = product
		elseif product.Quantity == 3 then
			threeProduct = product
		end
	end
	return {
		PackId = pack.PackId,
		DisplayName = pack.DisplayName,
		DevProductId = int(pack.DevProductId or (oneProduct and oneProduct.DevProductId), 0),
		BuyThreeDevProductId = int(pack.BuyThreeDevProductId or (threeProduct and threeProduct.DevProductId), 0),
		Products = products,
		Rewards = rewards,
	}
end

local function copyPetSkinPack(config)
	if type(config) ~= "table" then
		return nil
	end
	return {
		PackId = config.PackId,
		DisplayName = config.DisplayName,
		Products = seedPackProducts(config),
	}
end

local function copyDurianTicketProduct(product, legacy)
	if type(product) ~= "table" then
		return nil
	end
	return {
		Tickets = int(product.Tickets, 0),
		ExtraTickets = int(product.ExtraTickets, 0),
		DevProductId = int(product.DevProductId, 0),
		Legacy = legacy == true,
	}
end

local function copyDurianPack(config)
	if type(config) ~= "table" then
		return nil
	end
	local rewards = {}
	for _, reward in ipairs(config.Rewards or {}) do
		rewards[#rewards + 1] = copyReward(reward)
	end
	local ticketProducts = {}
	for _, product in ipairs(config.TicketProducts or {}) do
		local copy = copyDurianTicketProduct(product, false)
		if copy then
			ticketProducts[#ticketProducts + 1] = copy
		end
	end
	table.sort(ticketProducts, function(a, b)
		if a.Tickets ~= b.Tickets then
			return a.Tickets < b.Tickets
		end
		return a.DevProductId < b.DevProductId
	end)
	local rollCounts = {}
	for _, count in ipairs(config.RollCounts or {}) do
		rollCounts[#rollCounts + 1] = int(count, 0)
	end
	return {
		PackId = config.PackId,
		DisplayName = config.DisplayName,
		CycleSeconds = int(config.CycleSeconds, 0),
		PityRollCount = int(config.PityRollCount, 0),
		PitySeedId = config.PitySeedId,
		RollCounts = rollCounts,
		TicketProducts = ticketProducts,
		Rewards = rewards,
	}
end

local function copyStarterPackReward(reward)
	return {
		Kind = reward and reward.Kind or nil,
		FeedType = reward and reward.FeedType or nil,
		SeedId = reward and reward.SeedId or nil,
		PackId = reward and reward.PackId or nil,
		Amount = int(reward and reward.Amount, 0),
		CashFallbackAmount = reward and reward.CashFallbackAmount ~= nil and int(reward.CashFallbackAmount, 0) or nil,
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
		MinRebirths = int(pack.MinRebirths, 0),
		MaxRebirths = pack.MaxRebirths ~= nil and int(pack.MaxRebirths, 0) or nil,
		PromptDelaySeconds = int(pack.PromptDelaySeconds, 0),
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

local function copyFoodSteal(config)
	if type(config) ~= "table" then
		return nil
	end
	local tiers = {}
	for rarity, tierProductId in pairs(config.TierDevProductIds or {}) do
		tiers[rarity] = int(tierProductId, 0)
	end
	return {
		DevProductId = int(config.DevProductId, 0),
		TierDevProductIds = tiers,
		FallbackTierRarity = config.FallbackTierRarity,
	}
end

local function copyGrowSkip(config)
	if type(config) ~= "table" then
		return nil
	end
	local skips = {}
	for _, skip in ipairs(config.Skips or {}) do
		if type(skip) == "table" then
			skips[#skips + 1] = {
				SkipId = skip.SkipId,
				DisplayName = skip.DisplayName,
				DevProductId = int(skip.DevProductId, 0),
				DurationSeconds = int(skip.DurationSeconds, 0),
				Order = int(skip.Order, 0),
			}
		end
	end
	table.sort(skips, function(a, b)
		local orderA = tonumber(a.Order) or 0
		local orderB = tonumber(b.Order) or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return tostring(a.SkipId) < tostring(b.SkipId)
	end)
	return {
		DevProductId = int(config.DevProductId, 0),
		Skips = skips,
	}
end

local function copyGrowSkipProduct(skip)
	if type(skip) ~= "table" then
		return nil
	end
	return {
		SkipId = skip.SkipId,
		DisplayName = skip.DisplayName,
		DevProductId = int(skip.DevProductId, 0),
		DurationSeconds = int(skip.DurationSeconds, 0),
		Order = int(skip.Order, 0),
	}
end

local function copyCollectAll(config)
	if type(config) ~= "table" then
		return nil
	end
	return {
		DevProductId = int(config.DevProductId, 0),
		DisplayName = config.DisplayName,
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

function ShopBalance.SeedPackForPackId(packId)
	if type(packId) ~= "string" or packId == "" then
		return nil
	end
	for _, pack in ipairs(ShopBalance.SeedPacks) do
		if pack.PackId == packId then
			return copyPack(pack)
		end
	end
	return nil
end

function ShopBalance.StarterPackHasSeedPackReward(pack)
	for _, reward in ipairs(pack and pack.Rewards or {}) do
		if reward.Kind == ShopBalance.StarterPackRewardKinds.SeedPack then
			return true
		end
	end
	return false
end

-- Effective reward list for a player's paid-random-items policy: SeedPack
-- rewards swap to their CashFallbackAmount as a plain Cash reward when
-- seedPacksAllowed is not true, so restricted players buy a fully
-- deterministic pack.
function ShopBalance.StarterPackRewardsForPolicy(pack, seedPacksAllowed)
	local rewards = {}
	for _, reward in ipairs(pack and pack.Rewards or {}) do
		local copy = copyStarterPackReward(reward)
		if copy.Kind == ShopBalance.StarterPackRewardKinds.SeedPack and seedPacksAllowed ~= true then
			copy = {
				Kind = ShopBalance.StarterPackRewardKinds.Cash,
				Amount = int(reward.CashFallbackAmount, 0),
			}
		end
		rewards[#rewards + 1] = copy
	end
	return rewards
end

function ShopBalance.SeedPackProductForQuantity(pack, quantity)
	local targetQuantity = int(quantity, 0)
	if targetQuantity <= 0 then
		return nil
	end
	for _, product in ipairs(seedPackProducts(pack)) do
		if product.Quantity == targetQuantity and product.DevProductId > 0 then
			return {
				Quantity = product.Quantity,
				DevProductId = product.DevProductId,
			}
		end
	end
	return nil
end

function ShopBalance.AllSeedPackProducts(pack)
	return seedPackProducts(pack)
end

function ShopBalance.SeedPackForProductId(productIdValue)
	local target = productId(productIdValue)
	if target <= 0 then
		return nil
	end
	for _, pack in ipairs(ShopBalance.SeedPacks) do
		for _, product in ipairs(seedPackProducts(pack)) do
			if product.DevProductId == target then
				return copyPack(pack), product.Quantity
			end
		end
	end
	return nil
end

function ShopBalance.GetPetSkinPack()
	return copyPetSkinPack(ShopBalance.PetSkinPack)
end

function ShopBalance.PetSkinPackProductForQuantity(quantity)
	return ShopBalance.SeedPackProductForQuantity(ShopBalance.PetSkinPack, quantity)
end

function ShopBalance.AllPetSkinPackProducts()
	return seedPackProducts(ShopBalance.PetSkinPack)
end

function ShopBalance.PetSkinPackForProductId(productIdValue)
	local target = productId(productIdValue)
	if target <= 0 then
		return nil
	end
	for _, product in ipairs(seedPackProducts(ShopBalance.PetSkinPack)) do
		if product.DevProductId == target then
			return copyPetSkinPack(ShopBalance.PetSkinPack), product.Quantity
		end
	end
	return nil
end

function ShopBalance.GetDurianPack()
	return copyDurianPack(ShopBalance.DurianPack)
end

function ShopBalance.DurianTicketProductForProductId(productIdValue)
	local target = productId(productIdValue)
	local config = ShopBalance.DurianPack
	if target <= 0 or type(config) ~= "table" then
		return nil
	end
	for _, product in ipairs(config.TicketProducts or {}) do
		if productId(product.DevProductId) == target then
			return copyDurianTicketProduct(product, false)
		end
	end
	for _, product in ipairs(config.LegacyTicketProducts or {}) do
		if productId(product.DevProductId) == target then
			return copyDurianTicketProduct(product, true)
		end
	end
	return nil
end

function ShopBalance.DurianRollCountAllowed(rollCount)
	local target = int(rollCount, 0)
	if target <= 0 then
		return false
	end
	local config = ShopBalance.DurianPack
	for _, count in ipairs(type(config) == "table" and config.RollCounts or {}) do
		if int(count, 0) == target then
			return true
		end
	end
	return false
end

function ShopBalance.GetEndlessPack()
	local config = ShopBalance.EndlessPack
	if type(config) ~= "table" then
		return nil
	end
	local icons = {}
	for kind, icon in pairs(config.Icons or {}) do
		icons[kind] = tostring(icon)
	end
	local moneyPacks = {}
	for kind, pack in pairs(config.MoneyPacks or {}) do
		moneyPacks[kind] = {
			MinutesOfIncome = finiteNumber(pack.MinutesOfIncome, 0),
			BaseReward = int(pack.BaseReward, 0),
		}
	end
	local products = {}
	for index, id in ipairs(config.Products or {}) do
		products[index] = int(id, 0)
	end
	local cycle = {}
	for index, entry in ipairs(config.Cycle or {}) do
		cycle[index] = {
			Kind = entry.Kind,
			Paid = entry.Paid == true,
		}
	end
	return {
		PackId = config.PackId,
		DisplayName = config.DisplayName,
		CycleSeconds = int(config.CycleSeconds, 0),
		GrowSkipSeconds = int(config.GrowSkipSeconds, 0),
		Icons = icons,
		MoneyPacks = moneyPacks,
		Products = products,
		Cycle = cycle,
		SeedSchedule = table.clone(config.SeedSchedule or {}),
		SeedRotation = table.clone(config.SeedRotation or {}),
	}
end

function ShopBalance.EndlessPackSeedIdForOrdinal(ordinal)
	ordinal = int(ordinal, 0)
	if ordinal <= 0 then
		return nil
	end
	local schedule = ShopBalance.EndlessPack.SeedSchedule or {}
	if ordinal <= #schedule then
		return schedule[ordinal]
	end
	local rotation = ShopBalance.EndlessPack.SeedRotation or {}
	if #rotation == 0 then
		return nil
	end
	return rotation[((ordinal - #schedule - 1) % #rotation) + 1]
end

-- Resolves a 1-based global track position into the concrete item at that
-- position: kind, whether it is a Robux gate (and which product prompts it),
-- and the deterministic seed for SeedGrant entries.
function ShopBalance.EndlessPackItemForPosition(position)
	position = int(position, 0)
	local config = ShopBalance.EndlessPack
	local cycleLength = #config.Cycle
	if position <= 0 or cycleLength == 0 then
		return nil
	end
	local cycleIndex = ((position - 1) % cycleLength) + 1
	local cycleNumber = math.floor((position - 1) / cycleLength)
	local entry = config.Cycle[cycleIndex]
	local kinds = ShopBalance.EndlessPackKinds
	local paid = entry.Paid == true

	local item = {
		Position = position,
		Kind = entry.Kind,
		Paid = paid,
		Icon = config.Icons[entry.Kind],
	}
	if paid then
		local paidOrdinal = cycleNumber * endlessPaidOrdinalAt[cycleLength] + endlessPaidOrdinalAt[cycleIndex]
		item.ProductId = int(config.Products[math.min(paidOrdinal, #config.Products)], 0)
	end
	if entry.Kind == kinds.SeedGrant then
		local seedOrdinal = cycleNumber * endlessSeedOrdinalAt[cycleLength] + endlessSeedOrdinalAt[cycleIndex]
		item.SeedId = ShopBalance.EndlessPackSeedIdForOrdinal(seedOrdinal)
	end
	if entry.Kind == kinds.SeedPack or entry.Kind == kinds.EpicSeedPack then
		item.PackId = entry.Kind
	end
	if entry.Kind == kinds.GrowSkip then
		item.SkipSeconds = int(config.GrowSkipSeconds, 0)
	end
	return item
end

-- Receipt-routing predicate/fallback: maps a developer product id to the paid
-- cycle slot that first prompts it. The last product covers every paid ordinal
-- past the first cycle, so its Kind is the kind of the last paid cycle slot.
function ShopBalance.EndlessPackPaidItemForProductId(productIdValue)
	local target = productId(productIdValue)
	if target <= 0 then
		return nil
	end
	local config = ShopBalance.EndlessPack
	local productIndex = nil
	for index, id in ipairs(config.Products or {}) do
		if productId(id) == target then
			productIndex = index
			break
		end
	end
	if not productIndex then
		return nil
	end
	local paidSeen = 0
	for cycleIndex, entry in ipairs(config.Cycle or {}) do
		if entry.Paid == true then
			paidSeen += 1
			if paidSeen == productIndex then
				return {
					Kind = entry.Kind,
					ProductId = target,
					PaidOrdinal = productIndex,
					CycleIndex = cycleIndex,
				}
			end
		end
	end
	return nil
end

function ShopBalance.EndlessPackMoneyPayout(kind, hourlyIncome)
	local moneyPack = (ShopBalance.EndlessPack.MoneyPacks or {})[kind]
	if type(moneyPack) ~= "table" then
		return 0
	end
	return ShopBalance.CashPackPayout({
		HoursOfIncome = finiteNumber(moneyPack.MinutesOfIncome, 0) / 60,
		BaseReward = int(moneyPack.BaseReward, 0),
	}, hourlyIncome)
end

-- Cash dropped by admin-spawned pinatas, scaled to the collecting player's own
-- pet income at the moment the pinata broke. BaseReward floors follow the same
-- 100/minute curve as the Endless Pack money packs (2.5min -> 250, 5min -> 500)
-- so a brand-new player with almost no income still gets something meaningful.
ShopBalance.Pinata = {
	CashPacks = {
		Small = { MinutesOfIncome = 10, BaseReward = 1000 },
		Medium = { MinutesOfIncome = 25, BaseReward = 2500 },
	},
}

function ShopBalance.PinataCashPayout(cashId, hourlyIncome)
	local pack = (ShopBalance.Pinata.CashPacks or {})[cashId]
	if type(pack) ~= "table" then
		return 0
	end
	return ShopBalance.CashPackPayout({
		HoursOfIncome = finiteNumber(pack.MinutesOfIncome, 0) / 60,
		BaseReward = int(pack.BaseReward, 0),
	}, hourlyIncome)
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

function ShopBalance.AllStarterPacks()
	local packs = {}
	for _, pack in ipairs(ShopBalance.StarterPacks or {}) do
		local copy = copyStarterPack(pack)
		if copy then
			packs[#packs + 1] = copy
		end
	end
	table.sort(packs, function(a, b)
		local minA = tonumber(a.MinRebirths) or 0
		local minB = tonumber(b.MinRebirths) or 0
		if minA ~= minB then
			return minA < minB
		end
		return tostring(a.PackId) < tostring(b.PackId)
	end)
	return packs
end

function ShopBalance.StarterPackForPackId(packId)
	if type(packId) ~= "string" or packId == "" then
		return nil
	end
	for _, pack in ipairs(ShopBalance.StarterPacks or {}) do
		if pack.PackId == packId then
			return copyStarterPack(pack)
		end
	end
	return nil
end

function ShopBalance.GetFoodSteal()
	return copyFoodSteal(ShopBalance.FoodSteal)
end

-- Tiered-variant steal product for a food rarity. Unknown or unconfigured
-- rarities fall back to the configured fallback tier; returns 0 when neither
-- resolves so callers can drop back to the single control product.
function ShopBalance.FoodStealProductIdForRarity(rarity)
	local config = ShopBalance.FoodSteal
	local tiers = type(config) == "table" and config.TierDevProductIds or nil
	if type(tiers) ~= "table" then
		return 0
	end
	local tierProductId = int(tiers[rarity], 0)
	if tierProductId > 0 then
		return tierProductId
	end
	return int(tiers[config.FallbackTierRarity], 0)
end

function ShopBalance.GetGrowSkip()
	return copyGrowSkip(ShopBalance.GrowSkip)
end

function ShopBalance.GetCollectAll()
	return copyCollectAll(ShopBalance.CollectAll)
end

function ShopBalance.GrowSkipForSkipId(skipId)
	if type(skipId) ~= "string" or skipId == "" then
		return nil
	end
	local config = ShopBalance.GrowSkip
	for _, skip in ipairs(type(config) == "table" and config.Skips or {}) do
		if skip.SkipId == skipId then
			return copyGrowSkipProduct(skip)
		end
	end
	return nil
end

function ShopBalance.AllGrowSkipProducts()
	local products = {}
	local config = ShopBalance.GrowSkip
	if type(config) ~= "table" then
		return products
	end
	local targetedProductId = productId(config.DevProductId)
	if targetedProductId > 0 then
		products[#products + 1] = {
			SkipId = "TargetedSapling",
			DisplayName = "Targeted Sapling Skip",
			DevProductId = targetedProductId,
			DurationSeconds = 0,
			Order = 0,
		}
	end
	for _, skip in ipairs(config.Skips or {}) do
		local copy = copyGrowSkipProduct(skip)
		if copy then
			products[#products + 1] = copy
		end
	end
	table.sort(products, function(a, b)
		local orderA = tonumber(a.Order) or 0
		local orderB = tonumber(b.Order) or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return tostring(a.SkipId) < tostring(b.SkipId)
	end)
	return products
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
	if target <= 0 then
		return nil
	end
	for _, pack in ipairs(ShopBalance.StarterPacks or {}) do
		if productId(pack.DevProductId) == target then
			return copyStarterPack(pack)
		end
	end
	return nil
end

function ShopBalance.StarterPackForRebirths(rebirths)
	local value = int(rebirths, 0)
	local fallback = nil
	for _, pack in ipairs(ShopBalance.AllStarterPacks()) do
		local minRebirths = int(pack.MinRebirths, 0)
		local maxRebirths = pack.MaxRebirths ~= nil and int(pack.MaxRebirths, 0) or nil
		if value >= minRebirths and (maxRebirths == nil or value <= maxRebirths) then
			return pack
		end
		if value >= minRebirths then
			fallback = pack
		end
	end
	return fallback
end

function ShopBalance.FoodStealForProductId(productIdValue)
	local target = productId(productIdValue)
	local config = ShopBalance.FoodSteal
	if target <= 0 or type(config) ~= "table" then
		return nil
	end
	if productId(config.DevProductId) == target then
		return copyFoodSteal(config)
	end
	for _, tierProductId in pairs(config.TierDevProductIds or {}) do
		if productId(tierProductId) == target then
			return copyFoodSteal(config)
		end
	end
	return nil
end

function ShopBalance.CollectAllForProductId(productIdValue)
	local target = productId(productIdValue)
	local config = ShopBalance.CollectAll
	if target <= 0 or type(config) ~= "table" or productId(config.DevProductId) ~= target then
		return nil
	end
	return copyCollectAll(config)
end

function ShopBalance.GrowSkipForProductId(productIdValue)
	local target = productId(productIdValue)
	local config = ShopBalance.GrowSkip
	if target <= 0 or type(config) ~= "table" then
		return nil
	end
	if productId(config.DevProductId) == target then
		return {
			SkipId = "TargetedSapling",
			DisplayName = "Targeted Sapling Skip",
			DevProductId = productId(config.DevProductId),
			DurationSeconds = 0,
			Order = 0,
		}
	end
	for _, skip in ipairs(config.Skips or {}) do
		if productId(skip.DevProductId) == target then
			return copyGrowSkipProduct(skip)
		end
	end
	return nil
end

-- Inventory slots the pack's tools occupy. seedPacksAllowed=false swaps
-- SeedPack rewards to their cash fallback (no slot); nil/true counts them.
function ShopBalance.StarterPackTotalAmount(pack, seedPacksAllowed)
	local rewards = ShopBalance.StarterPackRewardsForPolicy(pack, seedPacksAllowed ~= false)
	local total = 0
	for _, reward in ipairs(rewards) do
		if reward and reward.Kind ~= ShopBalance.StarterPackRewardKinds.Cash then
			total += int(reward.Amount, 0)
		end
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
		if not Rarities.IsValid(pack.Rarity) then
			add(source .. " has invalid Rarity")
		end

		local products = seedPackProducts(pack)
		local seenQuantities = {}
		if #products == 0 then
			add(source .. " must define seed pack Products")
		end
		for productIndex, product in ipairs(products) do
			local productSource = source .. ".Products[" .. tostring(productIndex) .. "]"
			if type(product.Quantity) ~= "number" or product.Quantity <= 0 or product.Quantity % 1 ~= 0 then
				add(productSource .. " has invalid Quantity")
			elseif seenQuantities[product.Quantity] then
				add(source .. " has duplicate product Quantity " .. tostring(product.Quantity))
			else
				seenQuantities[product.Quantity] = true
			end
			validateProduct(product.DevProductId, productSource .. ".DevProductId")
		end

		if type(pack.Rewards) ~= "table" or #pack.Rewards == 0 then
			add(source .. " must define Rewards")
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

	local petSkinPack = ShopBalance.PetSkinPack
	if type(petSkinPack) ~= "table" then
		add("ShopBalance.PetSkinPack must be a table")
	else
		if type(petSkinPack.PackId) ~= "string" or petSkinPack.PackId == "" then
			add("ShopBalance.PetSkinPack has invalid PackId")
		elseif seenPacks[petSkinPack.PackId] then
			add("Duplicate shop PackId " .. tostring(petSkinPack.PackId))
		else
			seenPacks[petSkinPack.PackId] = true
		end
		if type(petSkinPack.DisplayName) ~= "string" or petSkinPack.DisplayName == "" then
			add("ShopBalance.PetSkinPack has invalid DisplayName")
		end
		local seenQuantities = {}
		for index, product in ipairs(seedPackProducts(petSkinPack)) do
			local source = "ShopBalance.PetSkinPack.Products[" .. tostring(index) .. "]"
			if product.Quantity ~= 1 and product.Quantity ~= 12 then
				add(source .. " must grant exactly 1 or 12 packs")
			elseif seenQuantities[product.Quantity] then
				add("ShopBalance.PetSkinPack has duplicate product Quantity " .. tostring(product.Quantity))
			else
				seenQuantities[product.Quantity] = true
			end
			validateProduct(product.DevProductId, source .. ".DevProductId")
		end
		if not (seenQuantities[1] and seenQuantities[12]) then
			add("ShopBalance.PetSkinPack must define quantities 1 and 12")
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

	local starterPacks = ShopBalance.StarterPacks
	if type(starterPacks) ~= "table" or #starterPacks == 0 then
		add("ShopBalance.StarterPacks must define starter packs")
	else
		for index, starterPack in ipairs(starterPacks) do
			local source = "ShopBalance.StarterPacks[" .. tostring(index) .. "]"
			if type(starterPack) ~= "table" then
				add(source .. " must be a table")
				continue
			end
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
			local minRebirths = starterPack.MinRebirths
			if type(minRebirths) ~= "number" or minRebirths < 0 or minRebirths % 1 ~= 0 then
				add(source .. " has invalid MinRebirths")
			end
			local safeMinRebirths = type(minRebirths) == "number" and minRebirths or 0
			if starterPack.MaxRebirths ~= nil
				and (type(starterPack.MaxRebirths) ~= "number"
					or starterPack.MaxRebirths < safeMinRebirths
					or starterPack.MaxRebirths % 1 ~= 0) then
				add(source .. " has invalid MaxRebirths")
			end
			if type(starterPack.PromptDelaySeconds) ~= "number"
				or starterPack.PromptDelaySeconds <= 0
				or starterPack.PromptDelaySeconds % 1 ~= 0 then
				add(source .. " has invalid PromptDelaySeconds")
			end

			if type(starterPack.Rewards) ~= "table" or #starterPack.Rewards == 0 then
				add(source .. " must define Rewards")
			else
				for rewardIndex, reward in ipairs(starterPack.Rewards) do
					local rewardSource = source .. ".Rewards[" .. tostring(rewardIndex) .. "]"
					if type(reward) ~= "table" then
						add(rewardSource .. " must be a table")
						continue
					end
					if reward.Kind ~= ShopBalance.StarterPackRewardKinds.Seed
						and reward.Kind ~= ShopBalance.StarterPackRewardKinds.FeedMachine
						and reward.Kind ~= ShopBalance.StarterPackRewardKinds.Cash
						and reward.Kind ~= ShopBalance.StarterPackRewardKinds.SeedPack then
						add(rewardSource .. " has invalid Kind")
					end
					if reward.Kind == ShopBalance.StarterPackRewardKinds.Seed
						and (type(reward.SeedId) ~= "string" or reward.SeedId == "") then
						add(rewardSource .. " has invalid SeedId")
					end
					if reward.Kind == ShopBalance.StarterPackRewardKinds.SeedPack
						and ShopBalance.SeedPackForPackId(reward.PackId) == nil then
						add(rewardSource .. " has invalid seed pack PackId")
					end
					if reward.Kind == ShopBalance.StarterPackRewardKinds.SeedPack
						and (type(reward.CashFallbackAmount) ~= "number"
							or reward.CashFallbackAmount <= 0
							or reward.CashFallbackAmount % 1 ~= 0) then
						add(rewardSource .. " has invalid CashFallbackAmount")
					end
					if reward.Kind == ShopBalance.StarterPackRewardKinds.FeedMachine
						and (type(reward.FeedType) ~= "string" or reward.FeedType == "") then
						add(rewardSource .. " has invalid FeedType")
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
	end

	local durianPack = ShopBalance.DurianPack
	if type(durianPack) ~= "table" then
		add("ShopBalance.DurianPack must be a table")
	else
		if type(durianPack.PackId) ~= "string" or durianPack.PackId == "" then
			add("ShopBalance.DurianPack has invalid PackId")
		elseif seenPacks[durianPack.PackId] then
			add("Duplicate shop PackId " .. tostring(durianPack.PackId))
		else
			seenPacks[durianPack.PackId] = true
		end
		if type(durianPack.DisplayName) ~= "string" or durianPack.DisplayName == "" then
			add("ShopBalance.DurianPack has invalid DisplayName")
		end
		if type(durianPack.CycleSeconds) ~= "number" or durianPack.CycleSeconds <= 0 or durianPack.CycleSeconds % 1 ~= 0 then
			add("ShopBalance.DurianPack has invalid CycleSeconds")
		end
		if type(durianPack.PityRollCount) ~= "number" or durianPack.PityRollCount <= 0 or durianPack.PityRollCount % 1 ~= 0 then
			add("ShopBalance.DurianPack has invalid PityRollCount")
		end
		if type(durianPack.PitySeedId) ~= "string" or durianPack.PitySeedId == "" then
			add("ShopBalance.DurianPack has invalid PitySeedId")
		end
		if type(durianPack.RollCounts) ~= "table" or #durianPack.RollCounts == 0 then
			add("ShopBalance.DurianPack must define RollCounts")
		else
			local seenRollCounts = {}
			for index, count in ipairs(durianPack.RollCounts) do
				local source = "ShopBalance.DurianPack.RollCounts[" .. tostring(index) .. "]"
				if type(count) ~= "number" or count <= 0 or count % 1 ~= 0 then
					add(source .. " has invalid roll count")
				elseif seenRollCounts[count] then
					add("Duplicate ShopBalance.DurianPack roll count " .. tostring(count))
				else
					seenRollCounts[count] = true
				end
			end
		end
		local function validateTicketProducts(products, sourceName)
			if type(products) ~= "table" or #products == 0 then
				add("ShopBalance.DurianPack." .. sourceName .. " must define ticket products")
				return
			end
			for index, product in ipairs(products) do
				local source = "ShopBalance.DurianPack." .. sourceName .. "[" .. tostring(index) .. "]"
				if type(product) ~= "table" then
					add(source .. " must be a table")
					continue
				end
				if type(product.Tickets) ~= "number" or product.Tickets <= 0 or product.Tickets % 1 ~= 0 then
					add(source .. " has invalid Tickets")
				end
				if type(product.ExtraTickets) ~= "number" or product.ExtraTickets < 0 or product.ExtraTickets % 1 ~= 0 then
					add(source .. " has invalid ExtraTickets")
				end
				validateProduct(product.DevProductId, source .. ".DevProductId")
			end
		end
		validateTicketProducts(durianPack.TicketProducts, "TicketProducts")
		validateTicketProducts(durianPack.LegacyTicketProducts, "LegacyTicketProducts")
		if type(durianPack.Rewards) ~= "table" or #durianPack.Rewards == 0 then
			add("ShopBalance.DurianPack must define Rewards")
		else
			local pityRewardFound = false
			for rewardIndex, reward in ipairs(durianPack.Rewards) do
				local rewardSource = "ShopBalance.DurianPack.Rewards[" .. tostring(rewardIndex) .. "]"
				if type(reward) ~= "table" then
					add(rewardSource .. " must be a table")
					continue
				end
				if type(reward.SeedId) ~= "string" or reward.SeedId == "" then
					add(rewardSource .. " has invalid SeedId")
				elseif reward.SeedId == durianPack.PitySeedId then
					pityRewardFound = true
				end
				if type(reward.Weight) ~= "number" or reward.Weight <= 0 or reward.Weight ~= reward.Weight or math.abs(reward.Weight) == math.huge then
					add(rewardSource .. " has invalid Weight")
				end
			end
			if not pityRewardFound then
				add("ShopBalance.DurianPack.PitySeedId must also be a configured reward")
			end
		end
	end

	local endlessPack = ShopBalance.EndlessPack
	if type(endlessPack) ~= "table" then
		add("ShopBalance.EndlessPack must be a table")
	else
		local kinds = ShopBalance.EndlessPackKinds
		if type(endlessPack.PackId) ~= "string" or endlessPack.PackId == "" then
			add("ShopBalance.EndlessPack has invalid PackId")
		elseif seenPacks[endlessPack.PackId] then
			add("Duplicate shop PackId " .. tostring(endlessPack.PackId))
		else
			seenPacks[endlessPack.PackId] = true
		end
		if type(endlessPack.DisplayName) ~= "string" or endlessPack.DisplayName == "" then
			add("ShopBalance.EndlessPack has invalid DisplayName")
		end
		if type(endlessPack.CycleSeconds) ~= "number" or endlessPack.CycleSeconds <= 0 or endlessPack.CycleSeconds % 1 ~= 0 then
			add("ShopBalance.EndlessPack has invalid CycleSeconds")
		end
		if type(endlessPack.GrowSkipSeconds) ~= "number" or endlessPack.GrowSkipSeconds <= 0 or endlessPack.GrowSkipSeconds % 1 ~= 0 then
			add("ShopBalance.EndlessPack has invalid GrowSkipSeconds")
		end

		local seedPackIds = {}
		for _, pack in ipairs(ShopBalance.SeedPacks or {}) do
			if type(pack) == "table" and type(pack.PackId) == "string" then
				seedPackIds[pack.PackId] = true
			end
		end

		local paidPerCycle = 0
		local cycle = endlessPack.Cycle
		if type(cycle) ~= "table" or #cycle ~= 27 then
			add("ShopBalance.EndlessPack.Cycle must define exactly 27 entries")
		else
			for index, entry in ipairs(cycle) do
				local source = "ShopBalance.EndlessPack.Cycle[" .. tostring(index) .. "]"
				if type(entry) ~= "table" then
					add(source .. " must be a table")
					continue
				end
				if type(entry.Kind) ~= "string" or kinds[entry.Kind] ~= entry.Kind then
					add(source .. " has invalid Kind")
					continue
				end
				local paid = entry.Paid == true
				if paid ~= (index % 3 == 1) then
					add(source .. " Paid flag must be set exactly on every 3rd entry (1, 4, 7, ...)")
				end
				if paid then
					paidPerCycle += 1
					if entry.Kind ~= kinds.Money1 and entry.Kind ~= kinds.Money2 then
						add(source .. " paid entries must be money packs")
					end
				end
				if (entry.Kind == kinds.SeedPack or entry.Kind == kinds.EpicSeedPack) and not seedPackIds[entry.Kind] then
					add(source .. " Kind has no matching ShopBalance.SeedPacks PackId")
				end
			end
		end

		local products = endlessPack.Products
		if type(products) ~= "table" or #products == 0 then
			add("ShopBalance.EndlessPack.Products must define developer products")
		else
			if paidPerCycle > 0 and #products ~= paidPerCycle then
				add("ShopBalance.EndlessPack.Products count must match paid entries per cycle")
			end
			for index, id in ipairs(products) do
				validateProduct(id, "ShopBalance.EndlessPack.Products[" .. tostring(index) .. "]")
			end
		end

		for kind, moneyPack in pairs(endlessPack.MoneyPacks or {}) do
			local source = "ShopBalance.EndlessPack.MoneyPacks." .. tostring(kind)
			if kind ~= kinds.Money1 and kind ~= kinds.Money2 then
				add(source .. " has invalid money kind")
			end
			if type(moneyPack) ~= "table"
				or type(moneyPack.MinutesOfIncome) ~= "number"
				or moneyPack.MinutesOfIncome <= 0
				or moneyPack.MinutesOfIncome ~= moneyPack.MinutesOfIncome
				or math.abs(moneyPack.MinutesOfIncome) == math.huge then
				add(source .. " has invalid MinutesOfIncome")
			end
			if type(moneyPack) ~= "table"
				or type(moneyPack.BaseReward) ~= "number"
				or moneyPack.BaseReward <= 0
				or moneyPack.BaseReward % 1 ~= 0 then
				add(source .. " has invalid BaseReward")
			end
		end
		if type(endlessPack.MoneyPacks) ~= "table"
			or type(endlessPack.MoneyPacks.Money1) ~= "table"
			or type(endlessPack.MoneyPacks.Money2) ~= "table" then
			add("ShopBalance.EndlessPack.MoneyPacks must define Money1 and Money2")
		end

		local function validateSeedList(list, sourceName)
			if type(list) ~= "table" or #list == 0 then
				add("ShopBalance.EndlessPack." .. sourceName .. " must define seed ids")
				return
			end
			for index, seedId in ipairs(list) do
				if type(seedId) ~= "string" or seedId == "" then
					add("ShopBalance.EndlessPack." .. sourceName .. "[" .. tostring(index) .. "] has invalid seed id")
				end
			end
		end
		validateSeedList(endlessPack.SeedSchedule, "SeedSchedule")
		validateSeedList(endlessPack.SeedRotation, "SeedRotation")
	end

	local foodSteal = ShopBalance.FoodSteal
	if type(foodSteal) ~= "table" then
		add("ShopBalance.FoodSteal must be a table")
	else
		validateProduct(foodSteal.DevProductId, "ShopBalance.FoodSteal.DevProductId")
		local tiers = foodSteal.TierDevProductIds
		if type(tiers) ~= "table" then
			add("ShopBalance.FoodSteal.TierDevProductIds must be a table")
		else
			for rarity in pairs(tiers) do
				if not Rarities.IsValid(rarity) then
					add("ShopBalance.FoodSteal.TierDevProductIds has invalid rarity " .. tostring(rarity))
				end
			end
			-- Every rarity needs its own tier product; a missing one would
			-- silently charge stolen food at the fallback tier's price.
			for _, rarity in ipairs(Rarities.Order) do
				if tiers[rarity] == nil then
					add("ShopBalance.FoodSteal.TierDevProductIds is missing " .. rarity)
				else
					validateProduct(tiers[rarity], "ShopBalance.FoodSteal.TierDevProductIds." .. rarity)
				end
			end
		end
		if not Rarities.IsValid(foodSteal.FallbackTierRarity) then
			add("ShopBalance.FoodSteal has invalid FallbackTierRarity")
		end
	end

	local collectAll = ShopBalance.CollectAll
	if type(collectAll) ~= "table" then
		add("ShopBalance.CollectAll must be a table")
	else
		if type(collectAll.DisplayName) ~= "string" or collectAll.DisplayName == "" then
			add("ShopBalance.CollectAll has invalid DisplayName")
		end
		validateProduct(collectAll.DevProductId, "ShopBalance.CollectAll.DevProductId")
	end

	local growSkip = ShopBalance.GrowSkip
	if type(growSkip) ~= "table" then
		add("ShopBalance.GrowSkip must be a table")
	else
		validateProduct(growSkip.DevProductId, "ShopBalance.GrowSkip.DevProductId")
		local skips = growSkip.Skips
		if type(skips) ~= "table" or #skips == 0 then
			add("ShopBalance.GrowSkip.Skips must define plot time skip products")
		else
			local seenSkipIds = {}
			for index, skip in ipairs(skips) do
				local source = "ShopBalance.GrowSkip.Skips[" .. tostring(index) .. "]"
				if type(skip) ~= "table" then
					add(source .. " must be a table")
					continue
				end
				if type(skip.SkipId) ~= "string" or skip.SkipId == "" then
					add(source .. " has invalid SkipId")
				elseif seenSkipIds[skip.SkipId] then
					add("Duplicate grow skip SkipId " .. tostring(skip.SkipId))
				else
					seenSkipIds[skip.SkipId] = true
				end
				if type(skip.DisplayName) ~= "string" or skip.DisplayName == "" then
					add(source .. " has invalid DisplayName")
				end
				validateProduct(skip.DevProductId, source .. ".DevProductId")
				if type(skip.DurationSeconds) ~= "number"
					or skip.DurationSeconds <= 0
					or skip.DurationSeconds ~= skip.DurationSeconds
					or math.abs(skip.DurationSeconds) == math.huge
					or skip.DurationSeconds % 1 ~= 0 then
					add(source .. " has invalid DurationSeconds")
				end
				if type(skip.Order) ~= "number" or skip.Order <= 0 or skip.Order % 1 ~= 0 then
					add(source .. " has invalid Order")
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
