local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local CashPackShopController = {}

local PANEL_NAME = "RobuxShop"
local CASH_PACKS_NAME = "CashPacks"
local PROMPT_TIMEOUT_SECONDS = 15

local player = Players.LocalPlayer
local productPriceById = {}
local pendingProductId = nil
local promptToken = 0

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

local function setTextStack(root, text)
	UiEffects.SetTextStack(root, tostring(text or ""))
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
	RuntimeGuard.Spawn("CashPackShopController.ProductInfo", function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, productId, Enum.InfoType.Product)
		if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
			productPriceById[productId] = NumberFormatter.Robux(info.PriceInRobux)
			if onLoaded then
				onLoaded()
			end
		end
	end)
	return productPriceById[productId]
end

local function hourlyIncome()
	return math.max(tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.HourlyPetIncome)) or 0, 0)
end

local function payoutFor(pack)
	return ShopBalance.CashPackPayout(pack, hourlyIncome())
end

local function findShopCards()
	local panel = MenuGui.GetFrame(PANEL_NAME, "CashPackShopController")
	if not panel then
		return {}
	end

	local sfHolder = panel:FindFirstChild("SFHolder", true)
	local cashPacks = sfHolder and sfHolder:FindFirstChild(CASH_PACKS_NAME)
	if not (cashPacks and cashPacks:IsA("GuiObject")) then
		warn("[CashPackShopController] Missing RobuxShop.SFHolder.CashPacks")
		return {}
	end

	local cards = {}
	for _, pack in ipairs(ShopBalance.AllCashPacks()) do
		local card = cashPacks:FindFirstChild(pack.PackId)
		if card and card:IsA("GuiObject") then
			cards[#cards + 1] = {
				pack = pack,
				card = card,
				source = "RobuxShop.SFHolder.CashPacks." .. tostring(pack.PackId),
			}
		else
			warn("[CashPackShopController] Missing RobuxShop.SFHolder.CashPacks." .. tostring(pack.PackId))
		end
	end
	return cards
end

local function bindShopCard(record, renderAll)
	local card = record.card
	local pack = record.pack
	local buyButton = child(card, "BuyButton", "GuiButton")
	local titleLabel = descendant(card, "Title", "TextLabel")
	local amountLabel = descendant(card, "Amount", "TextLabel")
	local priceLabel = buyButton and descendant(buyButton, "Price", "TextLabel")
	if not (buyButton and amountLabel and priceLabel) then
		warn("[CashPackShopController] " .. tostring(record.source) .. " is missing Amount, BuyButton, or Price")
		return nil
	end

	UiEffects.BindButton(buyButton)

	local function render()
		local productId = tonumber(pack.DevProductId) or 0
		local payout = payoutFor(pack)
		local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true

		if titleLabel then
			setTextStack(titleLabel, pack.DisplayName)
		end
		setTextStack(amountLabel, NumberFormatter.Currency(payout))
		setTextStack(priceLabel, robuxText(productId, renderAll))
		UiEffects.SetButtonEnabled(buyButton, ready and payout > 0 and pendingProductId == nil and productId > 0)
	end

	RuntimeGuard.Connect(buyButton.Activated, "CashPackShopController.Buy." .. tostring(pack.PackId), function()
		local productId = tonumber(pack.DevProductId) or 0
		if pendingProductId ~= nil
			or productId <= 0
			or payoutFor(pack) <= 0
			or PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
			return
		end

		promptToken += 1
		local token = promptToken
		pendingProductId = productId
		renderAll()
		RuntimeGuard.Run("CashPackShopController.PromptProductPurchase", function()
			MarketplaceService:PromptProductPurchase(player, productId)
		end)
		task.delay(PROMPT_TIMEOUT_SECONDS, function()
			if pendingProductId == productId and promptToken == token then
				pendingProductId = nil
				renderAll()
			end
		end)
	end)

	return render
end

function CashPackShopController.start()
	local renderers = {}
	local renderAll
	renderAll = function()
		for _, render in ipairs(renderers) do
			render()
		end
	end

	for _, record in ipairs(findShopCards()) do
		local render = bindShopCard(record, renderAll)
		if render then
			renderers[#renderers + 1] = render
		end
	end

	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "CashPackShopController.PromptProductPurchaseFinished", function(userId, productId)
		if userId ~= player.UserId or productId ~= pendingProductId then
			return
		end
		promptToken += 1
		pendingProductId = nil
		renderAll()
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, renderAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.HourlyPetIncome, renderAll)
	renderAll()
end

return CashPackShopController
