local RollLuckBalance = {}

RollLuckBalance.Upgrades = {
	[1] = { price = 1, luckPercent = 5 },
	[2] = { price = 1, luckPercent = 10 },
	[3] = { price = 1, luckPercent = 15 },
	[4] = { price = 1, luckPercent = 20 },
	[5] = { price = 1, luckPercent = 25 },
	[6] = { price = 1, luckPercent = 30 },
	[7] = { price = 1, luckPercent = 35 },
	[8] = { price = 1, luckPercent = 40 },
	[9] = { price = 1, luckPercent = 45 },
	[10] = { price = 1, luckPercent = 50 },
	[11] = { price = 1, luckPercent = 55 },
	[12] = { price = 1, luckPercent = 60 },
	[13] = { price = 1, luckPercent = 65 },
	[14] = { price = 1, luckPercent = 70 },
	[15] = { price = 1, luckPercent = 75 },
	[16] = { price = 1, luckPercent = 80 },
	[17] = { price = 1, luckPercent = 85 },
	[18] = { price = 1, luckPercent = 90 },
	[19] = { price = 1, luckPercent = 95 },
	[20] = { price = 1, luckPercent = 100 },
	[21] = { price = 1, luckPercent = 105 },
	[22] = { price = 1, luckPercent = 110 },
	[23] = { price = 1, luckPercent = 115 },
	[24] = { price = 1, luckPercent = 120 },
	[25] = { price = 1, luckPercent = 125 },
	[26] = { price = 1, luckPercent = 130 },
	[27] = { price = 1, luckPercent = 135 },
	[28] = { price = 1, luckPercent = 140 },
	[29] = { price = 1, luckPercent = 145 },
	[30] = { price = 1, luckPercent = 150 },
	[31] = { price = 1, luckPercent = 155 },
	[32] = { price = 1, luckPercent = 160 },
	[33] = { price = 1, luckPercent = 165 },
	[34] = { price = 1, luckPercent = 170 },
	[35] = { price = 1, luckPercent = 175 },
	[36] = { price = 1, luckPercent = 180 },
	[37] = { price = 1, luckPercent = 185 },
	[38] = { price = 1, luckPercent = 190 },
	[39] = { price = 1, luckPercent = 195 },
	[40] = { price = 1, luckPercent = 200 },
	[41] = { price = 1, luckPercent = 205 },
	[42] = { price = 1, luckPercent = 210 },
	[43] = { price = 1, luckPercent = 215 },
	[44] = { price = 1, luckPercent = 220 },
	[45] = { price = 1, luckPercent = 225 },
	[46] = { price = 1, luckPercent = 230 },
	[47] = { price = 1, luckPercent = 235 },
	[48] = { price = 1, luckPercent = 240 },
	[49] = { price = 1, luckPercent = 245 },
	[50] = { price = 1, luckPercent = 250 },
	[51] = { price = 1, luckPercent = 255 },
	[52] = { price = 1, luckPercent = 260 },
	[53] = { price = 1, luckPercent = 265 },
	[54] = { price = 1, luckPercent = 270 },
	[55] = { price = 1, luckPercent = 275 },
	[56] = { price = 1, luckPercent = 280 },
	[57] = { price = 1, luckPercent = 285 },
	[58] = { price = 1, luckPercent = 290 },
	[59] = { price = 1, luckPercent = 295 },
	[60] = { price = 1, luckPercent = 300 },
	[61] = { price = 1, luckPercent = 305 },
	[62] = { price = 1, luckPercent = 310 },
	[63] = { price = 1, luckPercent = 315 },
	[64] = { price = 1, luckPercent = 320 },
	[65] = { price = 1, luckPercent = 325 },
	[66] = { price = 1, luckPercent = 330 },
	[67] = { price = 1, luckPercent = 335 },
	[68] = { price = 1, luckPercent = 340 },
	[69] = { price = 1, luckPercent = 345 },
	[70] = { price = 1, luckPercent = 350 },
	[71] = { price = 1, luckPercent = 355 },
	[72] = { price = 1, luckPercent = 360 },
	[73] = { price = 1, luckPercent = 365 },
	[74] = { price = 1, luckPercent = 370 },
	[75] = { price = 1, luckPercent = 375 },
	[76] = { price = 1, luckPercent = 380 },
	[77] = { price = 1, luckPercent = 385 },
	[78] = { price = 1, luckPercent = 390 },
	[79] = { price = 1, luckPercent = 395 },
	[80] = { price = 1, luckPercent = 400 },
	[81] = { price = 1, luckPercent = 405 },
	[82] = { price = 1, luckPercent = 410 },
	[83] = { price = 1, luckPercent = 415 },
	[84] = { price = 1, luckPercent = 420 },
	[85] = { price = 1, luckPercent = 425 },
	[86] = { price = 1, luckPercent = 430 },
	[87] = { price = 1, luckPercent = 435 },
	[88] = { price = 1, luckPercent = 440 },
	[89] = { price = 1, luckPercent = 445 },
	[90] = { price = 1, luckPercent = 450 },
	[91] = { price = 1, luckPercent = 455 },
	[92] = { price = 1, luckPercent = 460 },
	[93] = { price = 1, luckPercent = 465 },
	[94] = { price = 1, luckPercent = 470 },
	[95] = { price = 1, luckPercent = 475 },
	[96] = { price = 1, luckPercent = 480 },
	[97] = { price = 1, luckPercent = 485 },
	[98] = { price = 1, luckPercent = 490 },
	[99] = { price = 1, luckPercent = 495 },
	[100] = { price = 1, luckPercent = 500 },
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

function RollLuckBalance.MaxLevel()
	local maxLevel = 0
	for level in pairs(RollLuckBalance.Upgrades) do
		if type(level) == "number" and level > maxLevel then
			maxLevel = level
		end
	end
	return maxLevel
end

function RollLuckBalance.LevelFor(value)
	if not isFiniteNumber(value) then
		return 0
	end
	return math.clamp(math.floor(tonumber(value)), 0, RollLuckBalance.MaxLevel())
end

function RollLuckBalance.CurrentLuckPercent(level)
	level = RollLuckBalance.LevelFor(level)
	if level <= 0 then
		return 0
	end
	local upgrade = RollLuckBalance.Upgrades[level]
	return upgrade and math.max(tonumber(upgrade.luckPercent) or 0, 0) or 0
end

function RollLuckBalance.NextUpgrade(level)
	local nextLevel = RollLuckBalance.LevelFor(level) + 1
	return RollLuckBalance.Upgrades[nextLevel], nextLevel
end

function RollLuckBalance.ToState(level, currency)
	level = RollLuckBalance.LevelFor(level)
	local nextUpgrade, nextLevel = RollLuckBalance.NextUpgrade(level)
	local currentLuck = RollLuckBalance.CurrentLuckPercent(level)

	return {
		level = level,
		maxLevel = RollLuckBalance.MaxLevel(),
		currentLuckPercent = currentLuck,
		nextLevel = nextUpgrade and nextLevel or nil,
		nextLuckPercent = nextUpgrade and (tonumber(nextUpgrade.luckPercent) or currentLuck) or currentLuck,
		price = nextUpgrade and math.max(math.floor(tonumber(nextUpgrade.price) or 0), 0) or nil,
		currency = nonNegativeInteger(currency),
		isMaxLevel = nextUpgrade == nil,
	}
end

function RollLuckBalance.Validate(errors)
	errors = errors or {}
	local maxLevel = RollLuckBalance.MaxLevel()
	if maxLevel ~= 100 then
		errors[#errors + 1] = "RollLuckBalance must define levels 1 through 100"
	end
	for level = 1, maxLevel do
		local upgrade = RollLuckBalance.Upgrades[level]
		if type(upgrade) ~= "table" then
			errors[#errors + 1] = string.format("RollLuckBalance.Upgrades[%d] must be a table", level)
		else
			if type(upgrade.price) ~= "number" or upgrade.price < 0 or upgrade.price % 1 ~= 0 then
				errors[#errors + 1] = string.format("RollLuckBalance.Upgrades[%d] has invalid price", level)
			end
			if type(upgrade.luckPercent) ~= "number" or upgrade.luckPercent < 0 then
				errors[#errors + 1] = string.format("RollLuckBalance.Upgrades[%d] has invalid luckPercent", level)
			end
		end
	end
	return #errors == 0
end

return RollLuckBalance
