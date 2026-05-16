local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))
local MarketProducts = require(ReplicatedStorage.Shared:WaitForChild("MarketProducts"))

local MarketCatalog = {}

local IN_SHOP_ATTRIBUTE = State.Feed.InShop or "InShop"
local SHOP_PRICE_ATTRIBUTE = State.Feed.ShopPrice or "ShopPrice"
local SHOP_RARITY_RATE_ATTRIBUTE = State.Feed.ShopRarityRate or "ShopRarityRate"
local SHOP_STOCK_RANGE_ATTRIBUTE = State.Feed.ShopStockRange or "ShopStockRange"
local SHOP_ROBUX_PRODUCT_ID_ATTRIBUTE = State.Feed.ShopRobuxProductId or "ShopRobuxProductId"
local SHOP_ROBUX_PRICE_ATTRIBUTE = State.Feed.ShopRobuxPrice or "ShopRobuxPrice"

local REQUIRED_ATTRIBUTES = {
	SHOP_PRICE_ATTRIBUTE,
	SHOP_RARITY_RATE_ATTRIBUTE,
	SHOP_STOCK_RANGE_ATTRIBUTE,
}

local OPTIONAL_ATTRIBUTES = {
	IN_SHOP_ATTRIBUTE,
	SHOP_ROBUX_PRODUCT_ID_ATTRIBUTE,
	SHOP_ROBUX_PRICE_ATTRIBUTE,
}

local function isFeedTemplate(instance)
	return instance:IsA("BasePart") or instance:IsA("Model")
end

local function hasAnyShopAttribute(template)
	if template:GetAttribute(IN_SHOP_ATTRIBUTE) ~= nil then
		return true
	end
	for _, attrName in ipairs(REQUIRED_ATTRIBUTES) do
		if template:GetAttribute(attrName) ~= nil then
			return true
		end
	end
	for _, attrName in ipairs(OPTIONAL_ATTRIBUTES) do
		if template:GetAttribute(attrName) ~= nil then
			return true
		end
	end
	return false
end

local function validateNumber(value, minValue, maxValue)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return false
	end
	if minValue ~= nil and value < minValue then
		return false
	end
	if maxValue ~= nil and value > maxValue then
		return false
	end
	return true
end

local function readRecord(template, className, errors)
	local feedType = template:GetAttribute(State.Feed.Type)
	if type(feedType) ~= "string" or feedType == "" then
		return nil
	end

	local source = template:GetFullName()
	local inShop = template:GetAttribute(IN_SHOP_ATTRIBUTE)
	if inShop == false then
		return nil
	end
	if inShop ~= true then
		if hasAnyShopAttribute(template) and errors then
			errors[#errors + 1] = string.format("%s has shop attributes but %s is not true", source, IN_SHOP_ATTRIBUTE)
		end
		return nil
	end

	local hasAllRequired = true
	for _, attrName in ipairs(REQUIRED_ATTRIBUTES) do
		if template:GetAttribute(attrName) == nil then
			hasAllRequired = false
			if errors then
				errors[#errors + 1] = string.format("%s has partial shop config: missing %s", source, attrName)
			end
		end
	end
	if not hasAllRequired then
		return nil
	end

	local price = template:GetAttribute(SHOP_PRICE_ATTRIBUTE)
	if not validateNumber(price, 0, nil) then
		if errors then
			errors[#errors + 1] = string.format("%s has invalid %s %q", source, SHOP_PRICE_ATTRIBUTE, tostring(price))
		end
		return nil
	end

	local rarityRate = template:GetAttribute(SHOP_RARITY_RATE_ATTRIBUTE)
	if not validateNumber(rarityRate, 0, 100) then
		if errors then
			errors[#errors + 1] = string.format("%s has invalid %s %q", source, SHOP_RARITY_RATE_ATTRIBUTE, tostring(rarityRate))
		end
		return nil
	end

	local stockRange = template:GetAttribute(SHOP_STOCK_RANGE_ATTRIBUTE)
	if typeof(stockRange) ~= "NumberRange" then
		if errors then
			errors[#errors + 1] = string.format("%s has invalid %s; expected NumberRange", source, SHOP_STOCK_RANGE_ATTRIBUTE)
		end
		return nil
	end
	local stockMin = math.floor(stockRange.Min)
	local stockMax = math.floor(stockRange.Max)
	if stockMin < 0 or stockMax < stockMin then
		if errors then
			errors[#errors + 1] = string.format("%s has invalid %s %s", source, SHOP_STOCK_RANGE_ATTRIBUTE, tostring(stockRange))
		end
		return nil
	end

	local robuxProductId = template:GetAttribute(SHOP_ROBUX_PRODUCT_ID_ATTRIBUTE) or MarketProducts.FeedProductIds[feedType]
	if robuxProductId ~= nil and not validateNumber(robuxProductId, 1, nil) then
		if errors then
			errors[#errors + 1] = string.format("%s has invalid %s %q", source, SHOP_ROBUX_PRODUCT_ID_ATTRIBUTE, tostring(robuxProductId))
		end
		robuxProductId = nil
	end

	local robuxPrice = template:GetAttribute(SHOP_ROBUX_PRICE_ATTRIBUTE)
	if robuxPrice ~= nil and not validateNumber(robuxPrice, 0, nil) then
		if errors then
			errors[#errors + 1] = string.format("%s has invalid %s %q", source, SHOP_ROBUX_PRICE_ATTRIBUTE, tostring(robuxPrice))
		end
		robuxPrice = nil
	end

	return {
		feedType = feedType,
		displayName = template.Name,
		feedClass = className,
		price = math.floor(price),
		rarityRate = rarityRate,
		stockMin = stockMin,
		stockMax = stockMax,
		robuxProductId = robuxProductId and math.floor(robuxProductId) or nil,
		robuxPrice = robuxPrice and math.floor(robuxPrice) or nil,
		template = template,
	}
end

local function sortCatalog(catalog)
	table.sort(catalog, function(a, b)
		if a.price ~= b.price then
			return a.price < b.price
		end
		return a.feedType < b.feedType
	end)
end

local function versionHash(catalog)
	local hash = 5381
	local function addString(value)
		for i = 1, #value do
			hash = (hash * 33 + string.byte(value, i)) % 2147483647
		end
	end

	for _, item in ipairs(catalog) do
		addString(item.feedType)
		addString(":")
		addString(tostring(item.price))
		addString(":")
		addString(tostring(item.rarityRate))
		addString(":")
		addString(tostring(item.stockMin))
		addString(":")
		addString(tostring(item.stockMax))
		addString(";")
	end
	return hash
end

local function collectCatalog(errors)
	local root = ReplicatedStorage:WaitForChild("FeedMachines")
	local catalog = {}
	local byFeedType = {}

	for _, classFolder in ipairs(root:GetChildren()) do
		if classFolder:IsA("Folder") then
			for _, template in ipairs(classFolder:GetChildren()) do
				if not isFeedTemplate(template) then
					continue
				end
				local feedClass = template:GetAttribute(State.Feed.Class)
				if type(feedClass) ~= "string" or feedClass == "" then
					feedClass = classFolder.Name
				end
				local record = readRecord(template, feedClass, errors)
				if record then
					if byFeedType[record.feedType] then
						if errors then
							errors[#errors + 1] = string.format("Duplicate market item FeedType %q", record.feedType)
						end
					else
						byFeedType[record.feedType] = record
						catalog[#catalog + 1] = record
					end
				end
			end
		end
	end

	sortCatalog(catalog)
	return catalog, byFeedType, versionHash(catalog)
end

function MarketCatalog.GetCatalog()
	local catalog, _, version = collectCatalog(nil)
	return catalog, version
end

function MarketCatalog.GetByFeedType()
	local catalog = MarketCatalog.GetCatalog()
	local byFeedType = {}
	for _, item in ipairs(catalog) do
		byFeedType[item.feedType] = item
	end
	return byFeedType
end

function MarketCatalog.Validate(errors)
	collectCatalog(errors)
end

function MarketCatalog.ToClientItem(item)
	return {
		feedType = item.feedType,
		displayName = item.displayName,
		feedClass = item.feedClass,
		price = item.price,
		robuxProductId = item.robuxProductId,
		robuxPrice = item.robuxPrice,
	}
end

function MarketCatalog.ToClientCatalog(catalog)
	local out = {}
	for _, item in ipairs(catalog or MarketCatalog.GetCatalog()) do
		out[#out + 1] = MarketCatalog.ToClientItem(item)
	end
	return out
end

local function seedFrom(cycleId, catalogVersion, salt)
	local seed = (tonumber(cycleId) or 0) * 1103515245 + (tonumber(catalogVersion) or 0) * 12345
	if salt then
		for i = 1, #salt do
			seed += string.byte(salt, i) * i
		end
	end
	seed = seed % 2147483647
	if seed < 1 then
		seed += 1
	end
	return seed
end

function MarketCatalog.GenerateOffer(catalog, cycleId, cycleStart, cycleEnd, salt)
	catalog = catalog or MarketCatalog.GetCatalog()
	local catalogVersion = versionHash(catalog)
	local rng = Random.new(seedFrom(cycleId, catalogVersion, salt))
	local items = {}

	for _, item in ipairs(catalog) do
		local amount = 0
		if item.rarityRate >= 100 or rng:NextNumber(0, 100) < item.rarityRate then
			amount = rng:NextInteger(item.stockMin, item.stockMax)
		end
		items[item.feedType] = amount
	end

	return {
		cycleId = cycleId,
		cycleStart = cycleStart,
		cycleEnd = cycleEnd,
		catalogVersion = catalogVersion,
		items = items,
	}
end

return MarketCatalog
