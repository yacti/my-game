local PlotGrid = {}

PlotGrid.Folders = {
	Starter = "StarterArea",
	Unlockable = "GridAreas",
}

PlotGrid.Attributes = {
	X = "GridX",
	Z = "GridZ",
	UnlockPrice = "UnlockPrice",
}

PlotGrid.SideByNumber = {
	-- Fence assets are authored with Fence1 on the inside/right edge of the
	-- purchasable strip. In the current GridX coordinate layout, that side is
	-- the neighbor at GridX - 1.
	[1] = { number = 1, name = "right", dx = -1, dz = 0, opposite = 3 },
	[2] = { number = 2, name = "top", dx = 0, dz = 1, opposite = 4 },
	[3] = { number = 3, name = "left", dx = 1, dz = 0, opposite = 1 },
	[4] = { number = 4, name = "bottom", dx = 0, dz = -1, opposite = 2 },
}

PlotGrid.SideNumbers = { 1, 2, 3, 4 }

PlotGrid.Corners = {
	CornerFence1_2 = { 1, 2 },
	CornerFence2_3 = { 2, 3 },
	CornerFence3_4 = { 3, 4 },
	CornerFence1_4 = { 1, 4 },
}

local CORNER_BY_KEY = {}
for name, sides in pairs(PlotGrid.Corners) do
	CORNER_BY_KEY[tostring(math.min(sides[1], sides[2])) .. "_" .. tostring(math.max(sides[1], sides[2]))] = name
end

function PlotGrid.CoordKey(x, z)
	return tostring(x) .. ":" .. tostring(z)
end

function PlotGrid.NormalizeInteger(value)
	local number = tonumber(value)
	if type(number) ~= "number" or number ~= number or math.abs(number) == math.huge then
		return nil
	end
	return math.floor(number)
end

function PlotGrid.NormalizeNonNegativeNumber(value)
	local number = tonumber(value)
	if type(number) ~= "number" or number ~= number or math.abs(number) == math.huge or number < 0 then
		return nil
	end
	return number
end

function PlotGrid.NormalizeCoordKey(value)
	if type(value) ~= "string" then return nil end
	value = value:match("^%s*(.-)%s*$")
	local x, z = value:match("^(-?%d+):(-?%d+)$")
	if not x or not z then
		x, z = value:match("^%a+_(-?%d+)_(-?%d+)$")
	end
	x = PlotGrid.NormalizeInteger(x)
	z = PlotGrid.NormalizeInteger(z)
	if not x or not z then return nil end
	return PlotGrid.CoordKey(x, z)
end

function PlotGrid.IsStarterGridPart(part)
	return part ~= nil
		and part:IsA("BasePart")
		and part.Parent ~= nil
		and part.Parent.Name == PlotGrid.Folders.Starter
end

function PlotGrid.IsUnlockableGridPart(part)
	return part ~= nil
		and part:IsA("BasePart")
		and part.Parent ~= nil
		and part.Parent.Name == PlotGrid.Folders.Unlockable
end

function PlotGrid.IsGridPart(part)
	return PlotGrid.IsStarterGridPart(part) or PlotGrid.IsUnlockableGridPart(part)
end

function PlotGrid.GridPartFromInstance(instance)
	local current = instance
	while current do
		if current:IsA("BasePart") and PlotGrid.IsGridPart(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

function PlotGrid.FenceNumberFromName(name)
	if type(name) ~= "string" then return nil end
	local number = name:match("^Fence([1-4])$")
	return number and tonumber(number) or nil
end

function PlotGrid.CornerSidesFromName(name)
	if type(name) ~= "string" then return nil end
	local a, b = name:match("^CornerFence([1-4])_([1-4])$")
	if not a or not b then return nil end
	a, b = tonumber(a), tonumber(b)
	if a == b then return nil end
	return a, b
end

function PlotGrid.CornerNameForSides(a, b)
	if type(a) ~= "number" or type(b) ~= "number" or a == b then return nil end
	return CORNER_BY_KEY[tostring(math.min(a, b)) .. "_" .. tostring(math.max(a, b))]
end

function PlotGrid.SanitizeUnlockedKeys(value)
	local keys = {}
	local seen = {}
	if type(value) ~= "table" then
		return keys
	end
	for _, rawKey in ipairs(value) do
		local key = PlotGrid.NormalizeCoordKey(rawKey)
		if key and not seen[key] then
			seen[key] = true
			keys[#keys + 1] = key
		end
	end
	return keys
end

function PlotGrid.LegacyExtraUnlockCount(plotSize)
	local size = PlotGrid.NormalizeInteger(plotSize) or 1
	return math.max(size - 1, 0)
end

return PlotGrid
