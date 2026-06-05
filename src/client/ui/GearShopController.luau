local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GearShopBalance = require(Shared:WaitForChild("GearShopBalance"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local ShopPanelController = require(script.Parent:WaitForChild("ShopPanelController"))

local GearShopController = {}

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
		getDescription = function(item)
			return item.Description or ""
		end,
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
	})
end

return GearShopController
