local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local StarterPackController = {}

local PANEL_NAME = "RobuxShop"
local CARD_NAME = "StarterPack"
local PREVIEW_OPTIONS = {
	targetMaxDimension = 3,
	zoom = 1.8,
}

local player = Players.LocalPlayer
local productPriceById = {}
local nextRequestId = 0
local pendingRequestId = nil
local rarityLabels = {}
local rarityConnection = nil

local function child(parent, name, className)
	local found = parent and parent:FindFirstChild(name)
	if found and (not className or found:IsA(className)) then
		return found
	end
	return nil
end

local function descendant(parent, name, className)
	for _, item in ipairs(parent and parent:GetDescendants() or {}) do
		if item.Name == name and (not className or item:IsA(className)) then
			return item
		end
	end
	return nil
end

local function sortedGuiChildren(parent, name)
	local children = {}
	for _, item in ipairs(parent and parent:GetChildren() or {}) do
		if item.Name == name and item:IsA("GuiObject") then
			children[#children + 1] = item
		end
	end
	table.sort(children, function(left, right)
		if left.LayoutOrder ~= right.LayoutOrder then
			return left.LayoutOrder < right.LayoutOrder
		end
		if left.Position.X.Scale ~= right.Position.X.Scale then
			return left.Position.X.Scale < right.Position.X.Scale
		end
		return left.Position.X.Offset < right.Position.X.Offset
	end)
	return children
end

local function findShopCard()
	local panel = MenuGui.GetFrame(PANEL_NAME, "StarterPackController")
	if not panel then
		return nil
	end
	local sfHolder = panel:FindFirstChild("SFHolder", true)
	local featured = sfHolder and sfHolder:FindFirstChild("Featured")
	local card = featured and featured:FindFirstChild(CARD_NAME)
	if card and card:IsA("GuiObject") then
		return card
	end
	warn("[StarterPackController] Missing RobuxShop.SFHolder.Featured.StarterPack")
	return nil
end

local function setTextStack(root, text)
	UiEffects.SetTextStack(root, tostring(text or ""))
end

local function applyColorToLabelStack(root, color)
	if not (root and color) then
		return
	end
	local function apply(label)
		if not (label:IsA("TextLabel") or label:IsA("TextButton")) then
			return
		end
		label.TextColor3 = color
		local gradient = label:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = ColorSequence.new(color)
		end
	end
	apply(root)
	for _, item in ipairs(root:GetDescendants()) do
		apply(item)
	end
end

local function refreshRarityLabels()
	for label, rarity in pairs(rarityLabels) do
		if not (label and label.Parent) then
			rarityLabels[label] = nil
		else
			local color = Rarities.ColorFor(rarity, os.clock()) or Rarities.ColorFor(Rarities.Common)
			applyColorToLabelStack(label, color)
		end
	end
end

local function registerRarityLabel(label, rarity)
	if not label then
		return
	end
	local value = type(rarity) == "string" and rarity ~= "" and rarity or Rarities.Common
	rarityLabels[label] = value
	refreshRarityLabels()
	if rarityConnection then
		return
	end
	local definition = Rarities.Get(value)
	if definition and definition.Animated then
		rarityConnection = RuntimeGuard.Connect(RunService.RenderStepped, "StarterPackController.RarityRender", refreshRarityLabels)
	end
end

local function disconnectRarityRender()
	if rarityConnection then
		rarityConnection:Disconnect()
		rarityConnection = nil
	end
end

local function robuxText(productId, onLoaded)
	productId = tonumber(productId) or 0
	if productId <= 0 then
		return "Robux"
	end
	if productPriceById[productId] then
		return productPriceById[productId]
	end

	productPriceById[productId] = "Robux"
	RuntimeGuard.Spawn("StarterPackController.ProductInfo", function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, productId, Enum.InfoType.Product)
		if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
			productPriceById[productId] = NumberFormatter.Format(info.PriceInRobux)
			if onLoaded then
				onLoaded()
			end
		end
	end)
	return productPriceById[productId]
end

local function renderRewardSlot(slot, reward)
	local icon = descendant(slot, "Icon", "ViewportFrame")
	local nameLabel = child(slot, "Name", "TextLabel") or descendant(slot, "Name", "TextLabel")
	local amountLabel = child(slot, "Amount", "TextLabel") or descendant(slot, "Amount", "TextLabel")
	local seedId = reward and reward.SeedId
	local amount = math.max(math.floor(tonumber(reward and reward.Amount) or 0), 0)

	slot.Visible = reward ~= nil
	ViewportPreview.Render(icon, Seeds.GetTemplate(seedId), PREVIEW_OPTIONS)
	setTextStack(nameLabel, Seeds.DisplayNameFor(seedId))
	registerRarityLabel(nameLabel, Seeds.RarityFor(seedId))
	if amountLabel then
		amountLabel.Visible = amount > 1
		setTextStack(amountLabel, amount > 1 and string.format("(%s)", NumberFormatter.Integer(amount)) or "")
	end
end

local function bindCard(card)
	local pack = ShopBalance.GetStarterPack()
	local buyButton = child(card, "BuyButton", "GuiButton")
	local priceLabel = buyButton and descendant(buyButton, "Price", "TextLabel")
	local title = child(card, "Name", "TextLabel")
	local sold = child(card, "Sold", "GuiObject")
	local items = child(card, "Items", "GuiObject")
	local slots = sortedGuiChildren(items, "Template")
	if not (pack and buyButton and priceLabel and sold and items and #slots == 4) then
		warn("[StarterPackController] StarterPack card is missing required named instances")
		return nil
	end

	UiEffects.BindButton(buyButton)
	setTextStack(title, pack.DisplayName or "Starter Pack")
	for index, reward in ipairs(pack.Rewards or {}) do
		if slots[index] then
			renderRewardSlot(slots[index], reward)
		end
	end

	local requestRemote = Remotes.get(Remotes.Names.StarterPackPurchaseRequest)
	local resultRemote = Remotes.get(Remotes.Names.StarterPackPurchaseResult)

	local function render()
		local owned = PlayerStateStore.Get(PlayerStateStore.Fields.StarterPackPurchased) == true
		local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
		local productId = tonumber(pack.DevProductId) or 0

		sold.Visible = owned
		buyButton.Visible = true
		setTextStack(priceLabel, robuxText(productId, render))
		UiEffects.SetButtonEnabled(buyButton, ready and not owned and productId > 0 and pendingRequestId == nil)
	end

	RuntimeGuard.Connect(buyButton.Activated, "StarterPackController.Buy", function()
		local owned = PlayerStateStore.Get(PlayerStateStore.Fields.StarterPackPurchased) == true
		if pendingRequestId ~= nil or owned or PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
			return
		end
		nextRequestId += 1
		pendingRequestId = nextRequestId
		render()
		requestRemote:FireServer(pendingRequestId)
	end)

	RuntimeGuard.Connect(resultRemote.OnClientEvent, "StarterPackController.PurchaseResult", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		render()
		local productId = tonumber(payload.productId) or 0
		if payload.success == true and productId > 0 then
			RuntimeGuard.Run("StarterPackController.PromptProductPurchase", function()
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
		end
	end)

	RuntimeGuard.Connect(card.Destroying, "StarterPackController.CardDestroying", function()
		rarityLabels = {}
		disconnectRarityRender()
	end)

	return render
end

function StarterPackController.start()
	local card = findShopCard()
	if not card then
		return
	end
	local render = bindCard(card)
	if not render then
		return
	end

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.StarterPackPurchased, render)
	render()
end

return StarterPackController
