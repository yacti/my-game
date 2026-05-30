local RollDropAreaBalance = {}

RollDropAreaBalance.TotalPads = 5

RollDropAreaBalance.Upgrades = {
	[1] = { price = 1 },
	[2] = { price = 1 },
	[3] = { price = 1 },
	[4] = { price = 1 },
}

local function isFiniteNumber(value)
	value = tonumber(value)
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function nonNegativeInteger(value)
	if not isFiniteNumber(value) then
		return 0
	end
	return math.max(math.floor(tonumber(value)), 0)
end

function RollDropAreaBalance.MaxLevel()
	local maxLevel = 0
	for level in pairs(RollDropAreaBalance.Upgrades) do
		if type(level) == "number" and level > maxLevel then
			maxLevel = level
		end
	end
	return maxLevel
end

function RollDropAreaBalance.LevelFor(value)
	if not isFiniteNumber(value) then
		return 0
	end
	return math.clamp(math.floor(tonumber(value)), 0, RollDropAreaBalance.MaxLevel())
end

function RollDropAreaBalance.UnlockedCount(level)
	return math.clamp(RollDropAreaBalance.LevelFor(level) + 1, 1, RollDropAreaBalance.TotalPads)
end

function RollDropAreaBalance.NextUpgrade(level)
	local nextLevel = RollDropAreaBalance.LevelFor(level) + 1
	return RollDropAreaBalance.Upgrades[nextLevel], nextLevel
end

function RollDropAreaBalance.ToState(level, currency)
	level = RollDropAreaBalance.LevelFor(level)
	local nextUpgrade, nextLevel = RollDropAreaBalance.NextUpgrade(level)
	local unlockedCount = RollDropAreaBalance.UnlockedCount(level)

	return {
		level = level,
		maxLevel = RollDropAreaBalance.MaxLevel(),
		totalPads = RollDropAreaBalance.TotalPads,
		unlockedPadCount = unlockedCount,
		nextLevel = nextUpgrade and nextLevel or nil,
		nextPadCount = nextUpgrade and RollDropAreaBalance.UnlockedCount(nextLevel) or unlockedCount,
		price = nextUpgrade and math.max(math.floor(tonumber(nextUpgrade.price) or 0), 0) or nil,
		currency = nonNegativeInteger(currency),
		isMaxLevel = nextUpgrade == nil,
	}
end

function RollDropAreaBalance.Validate(errors)
	errors = errors or {}
	local maxLevel = RollDropAreaBalance.MaxLevel()
	if RollDropAreaBalance.TotalPads ~= 5 then
		errors[#errors + 1] = "RollDropAreaBalance.TotalPads must be 5"
	end
	if maxLevel ~= RollDropAreaBalance.TotalPads - 1 then
		errors[#errors + 1] = "RollDropAreaBalance must define one fewer upgrade than total pads"
	end
	for level = 1, maxLevel do
		local upgrade = RollDropAreaBalance.Upgrades[level]
		if type(upgrade) ~= "table" then
			errors[#errors + 1] = string.format("RollDropAreaBalance.Upgrades[%d] must be a table", level)
		elseif type(upgrade.price) ~= "number" or upgrade.price < 0 or upgrade.price % 1 ~= 0 then
			errors[#errors + 1] = string.format("RollDropAreaBalance.Upgrades[%d] has invalid price", level)
		end
	end
	return #errors == 0
end

return RollDropAreaBalance
