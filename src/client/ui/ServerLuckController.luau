local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local ConfettiEffect = require(script.Parent:WaitForChild("ConfettiEffect"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local ServerLuckController = {}

local HUD_NAME = "HUD"
local HUD_WAIT_SECONDS = 10
local PANEL_NAME = "RobuxShop"
local CARD_NAME = "ServerLuck"
local INACTIVE_TIMER_TEXT = "+15 Mins"
local TIMER_UPDATE_SECONDS = 0.25

local productPriceById = {}
local nextRequestId = 0
local pendingRequestId = nil

local function child(parent, name, className)
	local found = parent and parent:FindFirstChild(name)
	if found and (not className or found:IsA(className)) then
		return found
	end
	return nil
end

local function path(parent, names, className)
	local current = parent
	for _, name in ipairs(names) do
		current = child(current, name)
		if not current then
			return nil
		end
	end
	if className and not current:IsA(className) then
		return nil
	end
	return current
end

local function findShopCard()
	local panel = MenuGui.GetFrame(PANEL_NAME, "ServerLuckController")
	if not panel then
		return nil
	end
	local sfHolder = panel:FindFirstChild("SFHolder", true)
	local featured = sfHolder and sfHolder:FindFirstChild("Featured")
	local card = featured and featured:FindFirstChild(CARD_NAME)
	if card and card:IsA("GuiObject") then
		return card
	end
	warn("[ServerLuckController] Missing RobuxShop.SFHolder.Featured.ServerLuck")
	return nil
end

local function findHudBuff(playerGui)
	local hud = playerGui:WaitForChild(HUD_NAME, HUD_WAIT_SECONDS)
	if not hud then
		warn("[ServerLuckController] Missing PlayerGui.HUD")
		return nil
	end
	local buffs = hud:FindFirstChild("Buffs")
	local serverLuck = buffs and buffs:FindFirstChild(CARD_NAME)
	if serverLuck and serverLuck:IsA("GuiObject") then
		return serverLuck, hud
	end
	warn("[ServerLuckController] Missing HUD.Buffs.ServerLuck")
	return nil, hud
end

local function formatMultiplier(multiplier)
	local value = math.max(math.floor(tonumber(multiplier) or ShopBalance.ServerLuck.BaseMultiplier), ShopBalance.ServerLuck.BaseMultiplier)
	return tostring(value) .. "x"
end

local function formatTimer(seconds)
	seconds = math.max(math.ceil(tonumber(seconds) or 0), 0)
	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60
	return string.format("%02d:%02d", minutes, remainder)
end

local function serverState()
	local currentTime = Workspace:GetServerTimeNow()
	local multiplier = tonumber(ReplicatedStorage:GetAttribute(State.ServerLuck.Multiplier)) or ShopBalance.ServerLuck.BaseMultiplier
	local endAt = tonumber(ReplicatedStorage:GetAttribute(State.ServerLuck.EndsAt)) or 0
	local active = multiplier > ShopBalance.ServerLuck.BaseMultiplier and endAt > currentTime
	if not active then
		multiplier = ShopBalance.ServerLuck.BaseMultiplier
		endAt = 0
	end
	return {
		active = active,
		multiplier = math.min(math.max(math.floor(multiplier), ShopBalance.ServerLuck.BaseMultiplier), ShopBalance.ServerLuck.MaxMultiplier),
		endsAt = endAt,
		remaining = active and math.max(endAt - currentTime, 0) or 0,
	}
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
	RuntimeGuard.Spawn("ServerLuckController.ProductInfo", function()
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

local function bindShopCard(card)
	local currentLuckLabel = path(card, { "LuckValues", "CurrentLuck" }, "TextLabel")
	local nextLuckLabel = path(card, { "LuckValues", "NextLuck" }, "TextLabel")
	local timerLabel = path(card, { "IconHolder", "Timer" }, "TextLabel")
	local buyButton = child(card, "BuyButton", "GuiButton")
	local priceLabel = buyButton and path(buyButton, { "Price" }, "TextLabel")
	if not (currentLuckLabel and nextLuckLabel and timerLabel and buyButton and priceLabel) then
		warn("[ServerLuckController] ServerLuck shop card is missing required named instances")
		return nil
	end

	UiEffects.BindButton(buyButton)
	local purchaseRequestRemote = Remotes.get(Remotes.Names.ServerLuckPurchaseRequest)
	local purchaseResultRemote = Remotes.get(Remotes.Names.ServerLuckPurchaseResult)

	local function render()
		local state = serverState()
		local nextMultiplier = ShopBalance.ServerLuckNextMultiplier(state.multiplier)
		local productId = ShopBalance.ServerLuckProductForCurrentMultiplier(state.multiplier)
		local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true

		UiEffects.SetTextStack(currentLuckLabel, formatMultiplier(state.multiplier))
		UiEffects.SetTextStack(nextLuckLabel, formatMultiplier(nextMultiplier))
		UiEffects.SetTextStack(timerLabel, state.active and formatTimer(state.remaining) or INACTIVE_TIMER_TEXT)
		UiEffects.SetTextStack(priceLabel, robuxText(productId, render))
		UiEffects.SetButtonEnabled(buyButton, ready and productId > 0 and pendingRequestId == nil)
	end

	RuntimeGuard.Connect(buyButton.Activated, "ServerLuckController.Buy", function()
		local state = serverState()
		local productId = ShopBalance.ServerLuckProductForCurrentMultiplier(state.multiplier)
		if pendingRequestId ~= nil or productId <= 0 or PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
			return
		end
		nextRequestId += 1
		pendingRequestId = nextRequestId
		render()
		purchaseRequestRemote:FireServer(pendingRequestId)
	end)

	RuntimeGuard.Connect(purchaseResultRemote.OnClientEvent, "ServerLuckController.PurchaseResult", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		render()
		local productId = tonumber(payload.productId) or 0
		if payload.success == true and productId > 0 then
			RuntimeGuard.Run("ServerLuckController.PromptProductPurchase", function()
				MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
			end)
		end
	end)

	return render
end

local function bindHudBuff(buff)
	local timerLabel = child(buff, "Timer", "TextLabel")
	local multiplierLabel = child(buff, "Multiplier", "TextLabel")
	if not (timerLabel and multiplierLabel) then
		warn("[ServerLuckController] HUD.Buffs.ServerLuck is missing Timer or Multiplier")
		buff.Visible = false
		return nil
	end

	local function render()
		local state = serverState()
		buff.Visible = state.active
		if not state.active then
			return
		end
		UiEffects.SetTextStack(timerLabel, formatTimer(state.remaining))
		UiEffects.SetTextStack(multiplierLabel, formatMultiplier(state.multiplier))
	end

	return render
end

function ServerLuckController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local renderers = {}
	local shopCard = findShopCard()
	if shopCard then
		local renderShop = bindShopCard(shopCard)
		if renderShop then
			renderers[#renderers + 1] = renderShop
		end
	end

	local hudBuff, hud = findHudBuff(playerGui)
	if hudBuff then
		local renderHud = bindHudBuff(hudBuff)
		if renderHud then
			renderers[#renderers + 1] = renderHud
		end
	end

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.ServerLuckBoosted).OnClientEvent, "ServerLuckController.Boosted", function()
		ConfettiEffect.Emit()
	end)

	if #renderers == 0 then
		return
	end

	local function renderAll()
		for _, render in ipairs(renderers) do
			render()
		end
	end

	RuntimeGuard.Connect(ReplicatedStorage:GetAttributeChangedSignal(State.ServerLuck.Multiplier), "ServerLuckController.MultiplierChanged", renderAll)
	RuntimeGuard.Connect(ReplicatedStorage:GetAttributeChangedSignal(State.ServerLuck.EndsAt), "ServerLuckController.EndsAtChanged", renderAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, renderAll)

	local elapsed = 0
	local heartbeatConnection
	heartbeatConnection = RuntimeGuard.Connect(RunService.Heartbeat, "ServerLuckController.Heartbeat", function(deltaTime)
		elapsed += deltaTime
		if elapsed < TIMER_UPDATE_SECONDS then
			return
		end
		elapsed = 0
		renderAll()
	end)
	if hud then
		RuntimeGuard.Connect(hud.Destroying, "ServerLuckController.HudDestroying", function()
			if heartbeatConnection then
				heartbeatConnection:Disconnect()
				heartbeatConnection = nil
			end
		end)
	end

	renderAll()
end

return ServerLuckController
