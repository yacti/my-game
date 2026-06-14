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

local VipController = {}

local PANEL_NAME = "RobuxShop"
local HUD_NAME = "HUD"
local HUD_WAIT_SECONDS = 10
local PROMPT_TIMEOUT_SECONDS = 15

local player = Players.LocalPlayer
local gamePassPriceById = {}
local pendingPrompt = false
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

local function gamePassId()
	return ShopBalance.VIPGamePassId()
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
	RuntimeGuard.Spawn("VipController.GamePassInfo", function()
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

local function findShopCards()
	local panel = MenuGui.GetFrame(PANEL_NAME, "VipController")
	if not panel then
		return {}
	end

	local cards = {}
	local sfHolder = panel:FindFirstChild("SFHolder", true)
	local featured = sfHolder and sfHolder:FindFirstChild("Featured")
	local featuredCard = featured and featured:FindFirstChild("VIP")
	if featuredCard and featuredCard:IsA("GuiObject") then
		cards[#cards + 1] = {
			card = featuredCard,
			source = "RobuxShop.SFHolder.Featured.VIP",
		}
	else
		warn("[VipController] Missing RobuxShop.SFHolder.Featured.VIP")
	end

	local gamepasses = sfHolder and sfHolder:FindFirstChild("Gamepasses")
	local gamepassesCard = gamepasses and gamepasses:FindFirstChild("VIP")
	if gamepassesCard and gamepassesCard:IsA("GuiObject") then
		cards[#cards + 1] = {
			card = gamepassesCard,
			source = "RobuxShop.SFHolder.Gamepasses.VIP",
		}
	else
		warn("[VipController] Missing RobuxShop.SFHolder.Gamepasses.VIP")
	end
	return cards
end

local function findHudBuff(playerGui)
	local hud = playerGui:WaitForChild(HUD_NAME, HUD_WAIT_SECONDS)
	if not hud then
		warn("[VipController] Missing PlayerGui.HUD")
		return nil
	end
	local buffs = hud:FindFirstChild("Buffs")
	local vip = buffs and buffs:FindFirstChild("VIP")
	if vip and vip:IsA("GuiObject") then
		return vip
	end
	warn("[VipController] Missing HUD.Buffs.VIP")
	return nil
end

local function bindShopCard(record, renderAll)
	local card = record.card
	local buyButton = child(card, "BuyButton", "GuiButton")
	local priceLabel = buyButton and descendant(buyButton, "Price", "TextLabel")
	local sold = child(card, "Sold", "GuiObject")
	if not (buyButton and priceLabel and sold) then
		warn("[VipController] " .. tostring(record.source) .. " is missing BuyButton, Price, or Sold")
		return nil
	end

	UiEffects.BindButton(buyButton)

	local function render()
		local owned = PlayerStateStore.Get(PlayerStateStore.Fields.VipOwned) == true
		local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
		local id = gamePassId()
		sold.Visible = owned
		buyButton.Visible = true
		setTextStack(priceLabel, robuxText(id, renderAll))
		UiEffects.SetButtonEnabled(buyButton, ready and not owned and not pendingPrompt and id > 0)
	end

	RuntimeGuard.Connect(buyButton.Activated, "VipController.Buy." .. tostring(record.source), function()
		local owned = PlayerStateStore.Get(PlayerStateStore.Fields.VipOwned) == true
		local id = gamePassId()
		if pendingPrompt or owned or id <= 0 or PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
			return
		end
		promptToken += 1
		local token = promptToken
		pendingPrompt = true
		renderAll()
		RuntimeGuard.Run("VipController.PromptGamePassPurchase", function()
			MarketplaceService:PromptGamePassPurchase(player, id)
		end)
		task.delay(PROMPT_TIMEOUT_SECONDS, function()
			if pendingPrompt and promptToken == token then
				pendingPrompt = false
				renderAll()
			end
		end)
	end)

	return render
end

local function bindHudBuff(buff)
	local icon = child(buff, "Icon", "ImageLabel")
	if not icon then
		warn("[VipController] HUD.Buffs.VIP is missing Icon")
		buff.Visible = false
		return nil
	end

	local function render()
		buff.Visible = PlayerStateStore.Get(PlayerStateStore.Fields.VipOwned) == true
	end
	return render
end

function VipController.start()
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

	local playerGui = player:WaitForChild("PlayerGui")
	local hudBuff = findHudBuff(playerGui)
	if hudBuff then
		local renderHud = bindHudBuff(hudBuff)
		if renderHud then
			renderers[#renderers + 1] = renderHud
		end
	end

	RuntimeGuard.Connect(MarketplaceService.PromptGamePassPurchaseFinished, "VipController.PromptGamePassPurchaseFinished", function(finishedPlayer, purchasedGamePassId)
		if finishedPlayer ~= player or tonumber(purchasedGamePassId) ~= gamePassId() then
			return
		end
		promptToken += 1
		pendingPrompt = false
		renderAll()
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, renderAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.VipOwned, renderAll)
	renderAll()
end

return VipController
