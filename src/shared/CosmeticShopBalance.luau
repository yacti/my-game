local CosmeticShopBalance = {}

CosmeticShopBalance.Items = {
	{
		ItemID = "Path",
		Price = 2500,
		DevProductId = 0,
	},
	{
		ItemID = "PebblePath",
		Price = 3000,
		DevProductId = 0,
	},
	{
		ItemID = "GrassPath",
		Price = 5000,
		DevProductId = 0,
	},
	{
		ItemID = "Haybale",
		Price = 10000,
		DevProductId = 0,
	},
	{
		ItemID = "TikiTorch",
		Price = 50000,
		DevProductId = 0,
	},
	{
		ItemID = "Arch",
		Price = 250000,
		DevProductId = 0,
	},
	{
		ItemID = "Bench",
		Price = 500000,
		DevProductId = 0,
	},
	{
		ItemID = "Fountain",
		Price = 1000000,
		DevProductId = 0,
	},
	{
		ItemID = "Pond",
		Price = 50000000,
		DevProductId = 0,
	},
	{
		ItemID = "Golden Fountain",
		Price = 100000000,
		DevProductId = 0,
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

function CosmeticShopBalance.Get(itemId)
	for _, item in ipairs(CosmeticShopBalance.Items) do
		if item.ItemID == itemId then
			return copy(item)
		end
	end
	return nil
end

function CosmeticShopBalance.All()
	local items = {}
	for _, item in ipairs(CosmeticShopBalance.Items) do
		items[#items + 1] = copy(item)
	end
	table.sort(items, function(a, b)
		local aPrice = int(a.Price, 0)
		local bPrice = int(b.Price, 0)
		if aPrice == bPrice then
			return tostring(a.ItemID) < tostring(b.ItemID)
		end
		return aPrice < bPrice
	end)
	return items
end

function CosmeticShopBalance.ForProductId(productId)
	productId = int(productId, 0)
	if productId <= 0 then
		return nil
	end
	for _, item in ipairs(CosmeticShopBalance.Items) do
		if int(item.DevProductId, 0) == productId then
			return copy(item)
		end
	end
	return nil
end

function CosmeticShopBalance.Price(item)
	return int(item and item.Price, 0)
end

function CosmeticShopBalance.ClientItems()
	return CosmeticShopBalance.All()
end

function CosmeticShopBalance.Validate(errors)
	errors = errors or {}
	local seenItems = {}
	local seenProducts = {}

	for index, item in ipairs(CosmeticShopBalance.Items) do
		local source = "CosmeticShopBalance.Items[" .. tostring(index) .. "]"
		if type(item) ~= "table" then
			errors[#errors + 1] = source .. " must be a table"
			continue
		end
		if type(item.ItemID) ~= "string" or item.ItemID == "" then
			errors[#errors + 1] = source .. " has invalid ItemID"
		elseif seenItems[item.ItemID] then
			errors[#errors + 1] = "Duplicate CosmeticShop ItemID " .. tostring(item.ItemID)
		else
			seenItems[item.ItemID] = true
		end
		if type(item.Price) ~= "number" or item.Price < 0 or item.Price % 1 ~= 0 then
			errors[#errors + 1] = source .. " has invalid Price"
		end
		if item.DevProductId ~= nil then
			if type(item.DevProductId) ~= "number" or item.DevProductId < 0 or item.DevProductId % 1 ~= 0 then
				errors[#errors + 1] = source .. " has invalid DevProductId"
			elseif item.DevProductId > 0 then
				if seenProducts[item.DevProductId] then
					errors[#errors + 1] = string.format("Duplicate CosmeticShop DevProductId %d", item.DevProductId)
				end
				seenProducts[item.DevProductId] = true
			end
		end
	end

	return #errors == 0
end

return CosmeticShopBalance
