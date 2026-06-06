local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticShopBalance = require(Shared:WaitForChild("CosmeticShopBalance"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local ShopPanelController = require(script.Parent:WaitForChild("ShopPanelController"))

local CosmeticShopController = {}
local COSMETIC_PREVIEW_OPTIONS = {
	targetMaxDimension = 5,
	zoom = 1.755,
}

local function templateFor(item)
	return Cosmetics.GetTemplate(item and item.ItemID)
end

local function displayNameFor(item)
	return Cosmetics.DisplayNameFor(item and item.ItemID)
end

function CosmeticShopController.start()
	ShopPanelController.Start({
		debugName = "CosmeticShopController",
		uiName = "CosmeticShop",
		panelName = "CosmeticShop",
		shopPartName = "CosmeticShop",
		itemPrefix = "CosmeticShopItem",
		items = CosmeticShopBalance.ClientItems(),
		purchaseRequest = Remotes.get(Remotes.Names.CosmeticShopPurchaseRequest),
		purchaseResult = Remotes.get(Remotes.Names.CosmeticShopPurchaseResult),
		getItemId = function(item)
			return item.ItemID
		end,
		getDisplayName = displayNameFor,
		getDescription = function(item)
			return Cosmetics.DescriptionFor(item.ItemID)
		end,
		getPrice = function(item)
			return item.Price
		end,
		getRequiredRebirths = function()
			return 0
		end,
		getDevProductId = function(item)
			return item.DevProductId
		end,
		getPreviewTemplate = templateFor,
		getPreviewOptions = function()
			return COSMETIC_PREVIEW_OPTIONS
		end,
	})
end

return CosmeticShopController
