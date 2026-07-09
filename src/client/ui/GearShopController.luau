local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GearShopBalance = require(Shared:WaitForChild("GearShopBalance"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local State = require(Shared:WaitForChild("State"))

local ShopPanelController = require(script.Parent:WaitForChild("ShopPanelController"))

local GearShopController = {}
local GEAR_PREVIEW_OPTIONS = {
	targetMaxDimension = 5,
	zoom = 1.755,
}

local function feedTemplate(feedType)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local feedMachines = assets and assets:FindFirstChild("FeedMachines")
	if type(feedType) ~= "string" or not feedMachines then
		return nil
	end
	for _, descendant in ipairs(feedMachines:GetDescendants()) do
		if (descendant:IsA("Model") or descendant:IsA("BasePart"))
			and descendant:GetAttribute("FeedType") == feedType then
			return descendant
		end
	end
	return nil
end

local function templateFor(item)
	return feedTemplate(item and item.FeedType)
end

local function displayNameFor(item)
	local template = templateFor(item)
	return template and template.Name or item and item.FeedType or "Item"
end

local function formatMultiplier(value)
	return NumberFormatter.Format(value, {
		smallDecimals = 2,
	})
end

local function formatSeconds(value)
	return NumberFormatter.Format(value, {
		smallDecimals = 2,
	})
end

local function descriptionFor(item)
	local description = item.Description or ""
	local template = templateFor(item)
	local feedClass = template and template:GetAttribute(State.Feed.Class)
	if feedClass == "Processor" or feedClass == "JamBarrel" then
		local multiplier = template:GetAttribute(State.Feed.XPMultiplier)
		local processDuration = template:GetAttribute(State.Feed.ProcessDuration)
		if type(multiplier) == "number" and multiplier > 0
			and type(processDuration) == "number" and processDuration > 0 then
			return string.format(
				"%sx XP multiplier, %ss process time",
				formatMultiplier(multiplier),
				formatSeconds(processDuration)
			)
		end
	elseif feedClass == "Scarecrow" then
		local jumpSeconds = template:GetAttribute(State.Feed.JumpSeconds)
		local jumpRadius = template:GetAttribute(State.Feed.JumpRadius)
		if type(jumpSeconds) == "number" and jumpSeconds > 0
			and type(jumpRadius) == "number" and jumpRadius > 0 then
			return string.format(
				"Shakes all fruit off trees within %d studs every %ss",
				jumpRadius,
				formatSeconds(jumpSeconds)
			)
		end
	end
	return description
end

function GearShopController.start()
	ShopPanelController.Start({
		debugName = "GearShopController",
		uiName = "GearShop",
		panelName = "GearShop",
		shopPartName = "GearShop",
		itemPrefix = "GearShopItem",
		items = GearShopBalance.ClientItems(),
		purchaseRequest = Remotes.get(Remotes.Names.GearShopPurchaseRequest),
		purchaseResult = Remotes.get(Remotes.Names.GearShopPurchaseResult),
		getItemId = function(item)
			return item.FeedType
		end,
		getDisplayName = displayNameFor,
		getDescription = descriptionFor,
		getRarity = function(item)
			return item.Rarity
		end,
		getPrice = function(item)
			return item.Price
		end,
		getRequiredRebirths = function(item)
			return item.RequiredRebirths
		end,
		getDevProductId = function(item)
			return item.DevProductId
		end,
		getPreviewTemplate = templateFor,
		getPreviewOptions = function()
			return GEAR_PREVIEW_OPTIONS
		end,
	})
end

return GearShopController
