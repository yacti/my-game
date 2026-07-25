local RebirthBalance = {}

RebirthBalance.Tiers = {
	[1] = {
		Price = 25000,
		PetRewards = {
			{ petId = "Pet1", amount = 1 },
		},
		Rewards = {
			{ kind = "Seed", seedId = "MushroomSeed", amount = 1 },
		},
		SkipProductId = 3604678866,
	},
	[2] = {
		Price = 250000,
		PetRewards = {
			{ petId = "Pet1", amount = 1 },
		},
		Rewards = {
			{ kind = "FeedMachine", feedType = "JamBarrel", amount = 1 },
		},
		SkipProductId = 3604678885,
	},
	[3] = {
		Price = 3500000,
		PetRewards = {
			{ petId = "Pet1", amount = 1 },
		},
		Rewards = {
			{ kind = "Seed", seedId = "PineappleSeed", amount = 1 },
		},
		SkipProductId = 3604678897,
	},
	[4] = {
		Price = 20000000,
		PetRewards = {
			{ petId = "Pet1", amount = 1 },
		},
		Rewards = {
			{ kind = "FeedMachine", feedType = "UpgradedJamBarrel", amount = 1 },
		},
		SkipProductId = 3604678913,
	},
	[5] = {
		Price = 50000000,
		PetRewards = {
			{ petId = "Pet1", amount = 1 },
		},
		Rewards = {
			{ kind = "Seed", seedId = "BloodOrangeTreeSeed", amount = 1 },
		},
		SkipProductId = 3604678927,
	},
	[6] = {
		Price = 200000000,
		PetRewards = {
			{ petId = "Pet1", amount = 1 },
		},
		SkipProductId = 0,
	},
	[7] = {
		Price = 1000000000,
		PetRewards = {
			{ petId = "Pet1", amount = 1 },
		},
		SkipProductId = 0,
	},
	[8] = {
		Price = 4500000000,
		PetRewards = {
			{ petId = "Pet1", amount = 1 },
		},
		SkipProductId = 0,
	},
}

local function integer(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	return math.floor(value)
end

function RebirthBalance.GetTier(tier)
	return RebirthBalance.Tiers[integer(tier, -1)]
end

function RebirthBalance.NextTierNumber(rebirths)
	return integer(rebirths, 0) + 1
end

function RebirthBalance.GetNextTier(rebirths)
	local tierNumber = RebirthBalance.NextTierNumber(rebirths)
	return tierNumber, RebirthBalance.GetTier(tierNumber)
end

function RebirthBalance.TierForSkipProductId(productId)
	productId = integer(productId, 0)
	if productId <= 0 then
		return nil
	end
	for tierNumber, tier in pairs(RebirthBalance.Tiers) do
		if integer(tier.SkipProductId, 0) == productId then
			return tierNumber
		end
	end
	return nil
end

function RebirthBalance.ToClientRewards(tier)
	local rewards = {}
	if type(tier) ~= "table" then
		return rewards
	end

	for _, reward in ipairs(tier.PetRewards or {}) do
		rewards[#rewards + 1] = {
			kind = "Pet",
			petId = reward.petId,
			amount = integer(reward.amount, 0),
			displayName = tostring(reward.petId or "Pet"),
		}
	end
	for _, reward in ipairs(tier.Rewards or {}) do
		if reward.kind == "FeedMachine" then
			rewards[#rewards + 1] = {
				kind = "FeedMachine",
				feedType = reward.feedType,
				amount = integer(reward.amount, 0),
			}
		elseif reward.kind == "Seed" then
			rewards[#rewards + 1] = {
				kind = "Seed",
				seedId = reward.seedId,
				amount = integer(reward.amount, 0),
				displayName = tostring(reward.seedId or "Seed"),
			}
		end
	end
	return rewards
end

return RebirthBalance
