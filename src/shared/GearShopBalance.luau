local GearShopBalance = {}

GearShopBalance.Kinds = {
	FeedMachine = "FeedMachine",
}

GearShopBalance.Items = {
	{
		Kind = GearShopBalance.Kinds.FeedMachine,
		FeedType = "JamBarrel",
		Description = "Processes fruit into jam.",
		Rarity = "Rare",
		Price = 10000,
		DevProductId = 0,
		RequiredRebirths = 0,
	},
	{
		Kind = GearShopBalance.Kinds.FeedMachine,
		FeedType = "UpgradedJamBarrel",
		Description = "Processes fruit into jam.",
		Rarity = "Epic",
		Price = 50000,
		DevProductId = 0,
		RequiredRebirths = 0,
	},
	{
		Kind = GearShopBalance.Kinds.FeedMachine,
		FeedType = "GoldenJamBarrel",
		Description = "Processes fruit into jam.",
		Rarity = "Legendary",
		Price = 1000000,
		DevProductId = 0,
		RequiredRebirths = 0,
	},
}

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function copy(item)
	local out = {}
	for key, value in pairs(item or {}) do
		out[key] = value
	end
	return out
end

function GearShopBalance.Get(feedType)
	for _, item in ipairs(GearShopBalance.Items) do
		if item.FeedType == feedType then
			return copy(item)
		end
	end
	return nil
end

function GearShopBalance.All()
	local items = {}
	for _, item in ipairs(GearShopBalance.Items) do
		items[#items + 1] = copy(item)
	end
	table.sort(items, function(a, b)
		local aPrice = int(a.Price, 0)
		local bPrice = int(b.Price, 0)
		if aPrice == bPrice then
			return tostring(a.FeedType) < tostring(b.FeedType)
		end
		return aPrice < bPrice
	end)
	return items
end

function GearShopBalance.ForProductId(productId)
	productId = int(productId, 0)
	if productId <= 0 then
		return nil
	end
	for _, item in ipairs(GearShopBalance.Items) do
		if int(item.DevProductId, 0) == productId then
			return copy(item)
		end
	end
	return nil
end

function GearShopBalance.Price(item)
	return int(item and item.Price, 0)
end

function GearShopBalance.RequiredRebirths(item)
	return int(item and item.RequiredRebirths, 0)
end

function GearShopBalance.ClientItems()
	return GearShopBalance.All()
end

function GearShopBalance.Validate(errors)
	errors = errors or {}
	local seenProducts = {}
	local seenFeedTypes = {}

	for index, item in ipairs(GearShopBalance.Items) do
		local source = "GearShopBalance.Items[" .. tostring(index) .. "]"
		if type(item) ~= "table" then
			errors[#errors + 1] = source .. " must be a table"
			continue
		end
		if item.Kind ~= GearShopBalance.Kinds.FeedMachine then
			errors[#errors + 1] = source .. " has unsupported Kind " .. tostring(item.Kind)
		end
		if type(item.FeedType) ~= "string" or item.FeedType == "" then
			errors[#errors + 1] = source .. " has invalid FeedType"
		elseif seenFeedTypes[item.FeedType] then
			errors[#errors + 1] = "Duplicate GearShop FeedType " .. tostring(item.FeedType)
		else
			seenFeedTypes[item.FeedType] = true
		end
		if type(item.Price) ~= "number" or item.Price < 0 or item.Price % 1 ~= 0 then
			errors[#errors + 1] = source .. " has invalid Price"
		end
		if type(item.RequiredRebirths) ~= "number" or item.RequiredRebirths < 0 or item.RequiredRebirths % 1 ~= 0 then
			errors[#errors + 1] = source .. " has invalid RequiredRebirths"
		end
		if type(item.DevProductId) ~= "number" or item.DevProductId < 0 or item.DevProductId % 1 ~= 0 then
			errors[#errors + 1] = source .. " has invalid DevProductId"
		elseif item.DevProductId > 0 then
			if seenProducts[item.DevProductId] then
				errors[#errors + 1] = string.format("Duplicate GearShop DevProductId %d", item.DevProductId)
			end
			seenProducts[item.DevProductId] = true
		end
	end

	return #errors == 0
end

return GearShopBalance
