local PlotSizes = {}

PlotSizes.MIN_SIZE = 1
PlotSizes.MAX_SIZE = 4

-- Server-authoritative defaults; tune these values as the economy settles.
PlotSizes.UPGRADE_PRICES = {
	[2] = 3,
	[3] = 3,
	[4] = 3,
}

local function finiteNumber(value, fallback)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	return value
end

function PlotSizes.Clamp(size)
	size = math.floor(finiteNumber(size, PlotSizes.MIN_SIZE))
	return math.clamp(size, PlotSizes.MIN_SIZE, PlotSizes.MAX_SIZE)
end

function PlotSizes.NextSize(size)
	size = PlotSizes.Clamp(size)
	if size >= PlotSizes.MAX_SIZE then
		return nil
	end
	return size + 1
end

function PlotSizes.UpgradePrice(size)
	size = PlotSizes.Clamp(size)
	return PlotSizes.UPGRADE_PRICES[size]
end

function PlotSizes.ReferenceName(size)
	return "Size" .. tostring(PlotSizes.Clamp(size))
end

function PlotSizes.AssetModelName(size)
	return "Size" .. tostring(PlotSizes.Clamp(size)) .. "Assets"
end

return PlotSizes
