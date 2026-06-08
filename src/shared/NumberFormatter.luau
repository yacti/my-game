local NumberFormatter = {}

local SUFFIXES = {
	{ threshold = 1e63, suffix = "Vg" },
	{ threshold = 1e60, suffix = "NoDc" },
	{ threshold = 1e57, suffix = "OcDc" },
	{ threshold = 1e54, suffix = "SpDc" },
	{ threshold = 1e51, suffix = "SxDc" },
	{ threshold = 1e48, suffix = "QiDc" },
	{ threshold = 1e45, suffix = "QaDc" },
	{ threshold = 1e42, suffix = "TDc" },
	{ threshold = 1e39, suffix = "DDc" },
	{ threshold = 1e36, suffix = "UDc" },
	{ threshold = 1e33, suffix = "Dc" },
	{ threshold = 1e30, suffix = "No" },
	{ threshold = 1e27, suffix = "Oc" },
	{ threshold = 1e24, suffix = "Sp" },
	{ threshold = 1e21, suffix = "Sx" },
	{ threshold = 1e18, suffix = "Qi" },
	{ threshold = 1e15, suffix = "Qa" },
	{ threshold = 1e12, suffix = "T" },
	{ threshold = 1e9, suffix = "B" },
	{ threshold = 1e6, suffix = "M" },
	{ threshold = 1e3, suffix = "K" },
}

local function finiteNumber(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return value
end

local function roundTo(value, decimals)
	local factor = 10 ^ math.max(math.floor(decimals or 0), 0)
	return math.floor(value * factor + 0.5) / factor
end

local function trimTrailingZeroes(text)
	text = tostring(text)
	text = text:gsub("(%..-)0+$", "%1")
	text = text:gsub("%.$", "")
	return text
end

local function precisionForScaledValue(value)
	if value < 10 then
		return 2
	end
	if value < 100 then
		return 1
	end
	return 0
end

local function formatFixed(value, decimals)
	decimals = math.max(math.floor(decimals or 0), 0)
	if decimals <= 0 then
		return tostring(math.floor(value + 0.5))
	end
	return trimTrailingZeroes(string.format("%." .. tostring(decimals) .. "f", roundTo(value, decimals)))
end

local function suffixRecordFor(absValue)
	for index, record in ipairs(SUFFIXES) do
		if absValue >= record.threshold then
			return record, index
		end
	end
	return nil, nil
end

function NumberFormatter.Format(value, options)
	options = type(options) == "table" and options or {}
	local number = finiteNumber(value)
	local sign = number < 0 and "-" or ""
	local absValue = math.abs(number)
	local smallDecimals = math.max(math.floor(tonumber(options.smallDecimals) or 0), 0)

	if absValue < 1000 then
		return sign .. formatFixed(absValue, smallDecimals)
	end

	local record, index = suffixRecordFor(absValue)
	local scaled = absValue / record.threshold
	local precision = precisionForScaledValue(scaled)
	local rounded = roundTo(scaled, precision)

	-- If rounding crosses the next suffix boundary, display the cleaner unit.
	if rounded >= 1000 and index > 1 then
		record = SUFFIXES[index - 1]
		scaled = absValue / record.threshold
		precision = precisionForScaledValue(scaled)
		rounded = roundTo(scaled, precision)
	end

	return sign .. formatFixed(rounded, precision) .. record.suffix
end

function NumberFormatter.Integer(value)
	return NumberFormatter.Format(math.floor(finiteNumber(value)))
end

function NumberFormatter.Currency(amount)
	return "$" .. NumberFormatter.Format(math.max(math.floor(finiteNumber(amount)), 0))
end

function NumberFormatter.CurrencyRate(amount)
	return "$" .. NumberFormatter.Format(math.max(finiteNumber(amount), 0), {
		smallDecimals = 2,
	}) .. "/s"
end

function NumberFormatter.Percent(value)
	return NumberFormatter.Format(math.max(math.floor(finiteNumber(value)), 0)) .. "%"
end

function NumberFormatter.ChanceN(value)
	return "1 in " .. NumberFormatter.Format(math.max(math.floor(finiteNumber(value)), 0))
end

function NumberFormatter.XP(value, unitText)
	return NumberFormatter.Format(math.max(math.floor(finiteNumber(value)), 0)) .. (unitText or " XP")
end

return NumberFormatter
