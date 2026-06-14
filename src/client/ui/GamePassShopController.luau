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

local GamePassShopController = {}

local PANEL_NAME = "RobuxShop"
local PROMPT_TIMEOUT_SECONDS = 15

local player = Players.LocalPlayer
local gamePassPriceById = {}
local pendingPromptKey = nil
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

local function ownershipMap()
	local map = PlayerStateStore.Get(PlayerStateStore.Fields.GamePassOwnership)
	return type(map) == "table" and map or {}
end

local function ownsPass(passKey)
	if passKey == ShopBalance.GamePassKeys.VIP and PlayerStateStore.Get(PlayerStateStore.Fields.VipOwned) == true then
		return true
	end
	return ownershipMap()[passKey] == true
end

local function robuxText(id, onLoaded)
	id = tonumber(id) or 0
	if id <= 0 then
		return "Robux"
	end
	if gamePassPriceById[id] then
		return gamePassPriceById[id]
	end

	gamePassPriceById[id] = "Robux"
	RuntimeGuard.Spawn("GamePassShopController.GamePassInfo", function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.GamePass)
		if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
			gamePassPriceById[id] = NumberFormatter.Format(info.PriceInRobux)
			if onLoaded then
				onLoaded()
			end
		end
	end)
	return gamePassPriceById[id]
end

local function addCard(cards, pass, card, source)
	if card and card:IsA("GuiObject") then
		cards[#cards + 1] = {
			pass = pass,
			card = card,
			source = source,
		}
	else
		warn("[GamePassShopController] Missing " .. tostring(source))
	end
end

local function findShopCards()
	local panel = MenuGui.GetFrame(PANEL_NAME, "GamePassShopController")
	if not panel then
		return {}
	end

	local cards = {}
	local sfHolder = panel:FindFirstChild("SFHolder", true)
	local featured = sfHolder and sfHolder:FindFirstChild("Featured")
	local gamepasses = sfHolder and sfHolder:FindFirstChild("Gamepasses")

	for _, pass in ipairs(ShopBalance.AllGamePasses()) do
		if type(pass.FeaturedCardName) == "string" and pass.FeaturedCardName ~= "" then
			addCard(cards, pass, featured and featured:FindFirstChild(pass.FeaturedCardName), "RobuxShop.SFHolder.Featured." .. pass.FeaturedCardName)
		end
		addCard(cards, pass, gamepasses and gamepasses:FindFirstChild(pass.ShopCardName), "RobuxShop.SFHolder.Gamepasses." .. tostring(pass.ShopCardName))
	end
	return cards
end

local function bindShopCard(record, renderAll)
	local card = record.card
	local pass = record.pass
	local buyButton = child(card, "BuyButton", "GuiButton")
	local priceLabel = buyButton and descendant(buyButton, "Price", "TextLabel")
	local sold = child(card, "Sold", "GuiObject")
	if not (buyButton and priceLabel and sold) then
		warn("[GamePassShopController] " .. tostring(record.source) .. " is missing BuyButton, Price, or Sold")
		return nil
	end

	print(string.format(
		"[GamePassShopController] bound pass=%s source=%s gamePassId=%s",
		tostring(pass.Key),
		tostring(record.source),
		tostring(pass.GamePassId)
	))
	UiEffects.BindButton(buyButton)

	local function render()
		local owned = ownsPass(pass.Key)
		local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
		local id = tonumber(pass.GamePassId) or 0
		sold.Visible = owned
		buyButton.Visible = true
		setTextStack(priceLabel, robuxText(id, renderAll))
		UiEffects.SetButtonEnabled(buyButton, ready and not owned and pendingPromptKey == nil and id > 0)
	end

	RuntimeGuard.Connect(buyButton.Activated, "GamePassShopController.Buy." .. tostring(record.source), function()
		local id = tonumber(pass.GamePassId) or 0
		if pendingPromptKey ~= nil or ownsPass(pass.Key) or id <= 0 or PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
			return
		end
		promptToken += 1
		local token = promptToken
		pendingPromptKey = pass.Key
		print(string.format("[GamePassShopController] prompt-purchase pass=%s gamePassId=%s", tostring(pass.Key), tostring(id)))
		renderAll()
		RuntimeGuard.Run("GamePassShopController.PromptGamePassPurchase", function()
			MarketplaceService:PromptGamePassPurchase(player, id)
		end)
		task.delay(PROMPT_TIMEOUT_SECONDS, function()
			if pendingPromptKey == pass.Key and promptToken == token then
				pendingPromptKey = nil
				renderAll()
			end
		end)
	end)

	return render
end

function GamePassShopController.start()
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

	RuntimeGuard.Connect(MarketplaceService.PromptGamePassPurchaseFinished, "GamePassShopController.PromptGamePassPurchaseFinished", function(finishedPlayer, purchasedGamePassId)
		if finishedPlayer ~= player or not ShopBalance.GamePassForId(purchasedGamePassId) then
			return
		end
		promptToken += 1
		pendingPromptKey = nil
		print(string.format("[GamePassShopController] purchase-finished gamePassId=%s", tostring(purchasedGamePassId)))
		renderAll()
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, renderAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.GamePassOwnership, renderAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.VipOwned, renderAll)
	renderAll()
end

return GamePassShopController
