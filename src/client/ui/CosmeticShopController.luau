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
-- Per-item camera overrides. Preview size on screen scales with zoom (the
-- camera pulls in by 1/zoom), so doubling it doubles the rendered item.
local COSMETIC_PREVIEW_OVERRIDES = {
	Pond = {
		targetMaxDimension = COSMETIC_PREVIEW_OPTIONS.targetMaxDimension,
		zoom = COSMETIC_PREVIEW_OPTIONS.zoom * 2,
		-- The pond is flat and wide, so it frames low; lift it in the viewport.
		verticalOffset = 0.6,
	},
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
		getPreviewOptions = function(item)
			return COSMETIC_PREVIEW_OVERRIDES[item and item.ItemID] or COSMETIC_PREVIEW_OPTIONS
		end,
	})
end

return CosmeticShopController
