local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local ShopPanelController = {}

local SHOP_MENU_GROUP = "Shop"
local PROXIMITY_SECONDS = 0.1
local productPriceById = {}

local function findDescendant(root, name, className)
	if not root then return nil end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

local function shopPart(shopPartName)
	local map = Workspace:FindFirstChild("Map")
	local shopParts = map and map:FindFirstChild("ShopParts")
	local part = shopParts and shopParts:FindFirstChild(shopPartName)
	return part and part:IsA("BasePart") and part or nil
end

local function rootPart(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function nearShop(player, shopPartName)
	local part = shopPart(shopPartName)
	local root = rootPart(player)
	if not (part and root) then return false end

	local localPosition = part.CFrame:PointToObjectSpace(root.Position)
	local half = part.Size * 0.5
	return math.abs(localPosition.X) <= half.X
		and math.abs(localPosition.Y) <= half.Y
		and math.abs(localPosition.Z) <= half.Z
end

local function robuxText(productId, debugName, onLoaded)
	productId = tonumber(productId) or 0
	if productId <= 0 then
		return NumberFormatter.Robux(0)
	end
	local cached = productPriceById[productId]
	if cached then
		return cached
	end

	productPriceById[productId] = NumberFormatter.Robux(0)
	RuntimeGuard.Spawn(debugName .. ".ProductInfo", function()
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

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function valueFrom(config, methodName, item, fallback)
	local callback = config[methodName]
	if type(callback) == "function" then
		local ok, result = RuntimeGuard.Run(config.debugName .. "." .. methodName, callback, item)
		if ok and result ~= nil then
			return result
		end
	end
	return fallback
end

function ShopPanelController.Start(config)
	config = config or {}
	local debugName = tostring(config.debugName or "ShopPanelController")
	local uiName = tostring(config.uiName or "")
	local panelName = tostring(config.panelName or uiName)
	local shopPartName = tostring(config.shopPartName or uiName)
	local itemPrefix = tostring(config.itemPrefix or uiName .. "Item")
	local menuGroup = tostring(config.menuGroup or SHOP_MENU_GROUP)
	config.debugName = debugName
	if uiName == "" or panelName == "" or shopPartName == "" then
		warn("[" .. debugName .. "] Missing required shop config")
		return
	end

	local items = config.items
	if type(items) ~= "table" then
		items = {}
	end

	local player = Players.LocalPlayer
	local panel = MenuGui.GetFrame(panelName, debugName)
	if not panel then return end
	local gui = panel:FindFirstAncestorOfClass("ScreenGui")
	local closeButton = panel and findDescendant(panel, "CloseButton", "GuiButton")
	local holder = panel and findDescendant(panel, "SFHolder", "ScrollingFrame")
	local template = holder and holder:FindFirstChild("Template")
	if not (panel and panel:IsA("GuiObject") and closeButton and holder and template and template:IsA("GuiObject")) then
		warn("[" .. debugName .. "] Shop UI missing required instances")
		panel.Visible = false
		return
	end

	local purchaseRequest = config.purchaseRequest
	local purchaseResult = config.purchaseResult
	if not (purchaseRequest and purchaseResult) then
		warn("[" .. debugName .. "] Missing purchase remotes")
		panel.Visible = false
		return
	end

	UiEffects.BindAllButtons(panel)
	local panelState = UiEffects.PreparePanel(panel)
	panel.Visible = false

	local rows = {}
	local open = false
	local manuallyClosed = false
	local pendingRequestId = nil
	local nextRequestId = 0
	local transitionToken = 0

	for _, child in ipairs(holder:GetChildren()) do
		if child.Name == "Template" and child:IsA("GuiObject") then
			child.Visible = false
		end
	end

	local function state()
		return {
			currency = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Currency)) or 0,
			rebirths = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Rebirths)) or 0,
			ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true,
		}
	end

	local function render()
		local current = state()
		for _, row in ipairs(rows) do
			local item = row.item
			local itemId = valueFrom(config, "getItemId", item, "Item")
			local requiredRebirths = int(valueFrom(config, "getRequiredRebirths", item, 0), 0)
			local price = int(valueFrom(config, "getPrice", item, 0), 0)
			local locked = current.rebirths < requiredRebirths
			local affordable = current.currency >= price
			local cashEnabled = current.ready and not locked and pendingRequestId == nil
			local robuxProductId = int(valueFrom(config, "getDevProductId", item, 0), 0)

			UiEffects.SetTextStack(row.nameLabel, tostring(valueFrom(config, "getDisplayName", item, itemId or "Item")))
			UiEffects.SetTextStack(row.descriptionLabel, tostring(valueFrom(config, "getDescription", item, "")))
			UiEffects.SetTextStack(row.cashPriceLabel, UiEffects.FormatCurrency(price))
			UiEffects.SetTextStack(row.robuxPriceLabel, robuxText(robuxProductId, debugName, render))

			if row.rarityLabel then
				local rarity = valueFrom(config, "getRarity", item, nil) or Rarities.Common
				UiEffects.SetTextStack(row.rarityLabel, tostring(rarity))
				row.rarityLabel.TextColor3 = Rarities.ColorFor(rarity) or Rarities.ColorFor(Rarities.Common)
			end
			if row.lockedFrame then
				row.lockedFrame.Visible = locked
			end
			if row.cannotAfford then
				row.cannotAfford.Visible = not locked and not affordable
			end
			if row.cashButton then
				UiEffects.SetButtonEnabled(row.cashButton, cashEnabled)
			end
			if row.robuxButton then
				row.robuxButton.Visible = robuxProductId > 0
				UiEffects.SetButtonEnabled(row.robuxButton, current.ready and not locked and pendingRequestId == nil)
			end
		end
	end

	local function showPanel()
		if open then
			render()
			return
		end
		open = true
		transitionToken += 1
		render()
		UiEffects.PlayOpen(panel, panelState)
	end

	local function hidePanel(switching)
		if not open and not panel.Visible then return end
		open = false
		transitionToken += 1
		local token = transitionToken
		if switching then
			panel.Visible = false
			panel.Position = panelState.closedPosition
			panel.Size = panelState.closedSize
			return
		end
		UiEffects.PlayClose(panel, panelState, function()
			if token == transitionToken and not open then
				panel.Visible = false
			end
		end)
	end

	MenuGui.RegisterPanel(panelName, {
		group = menuGroup,
		open = showPanel,
		close = hidePanel,
		refresh = render,
	})

	for index, item in ipairs(items) do
		local itemId = valueFrom(config, "getItemId", item, index)
		local rowGui = template:Clone()
		rowGui.Name = itemPrefix .. "_" .. tostring(itemId)
		rowGui.LayoutOrder = index
		rowGui.Visible = true
		rowGui.Parent = holder
		UiEffects.BindAllButtons(rowGui)

		local previewTemplate = valueFrom(config, "getPreviewTemplate", item, nil)
		local previewOptions = valueFrom(config, "getPreviewOptions", item, nil)
		ViewportPreview.Render(findDescendant(rowGui, "ItemIcon", "ViewportFrame"), previewTemplate, previewOptions)

		local cashButton = findDescendant(rowGui, "CashBtn", "GuiButton")
		local robuxButton = findDescendant(rowGui, "RobuxBtn", "GuiButton")
		if cashButton then
			RuntimeGuard.Connect(cashButton.Activated, debugName .. ".Cash", function()
				if pendingRequestId ~= nil then return end
				local current = state()
				local requiredRebirths = int(valueFrom(config, "getRequiredRebirths", item, 0), 0)
				local price = int(valueFrom(config, "getPrice", item, 0), 0)
				if not current.ready or current.rebirths < requiredRebirths or current.currency < price then
					return
				end
				nextRequestId += 1
				pendingRequestId = nextRequestId
				render()
				purchaseRequest:FireServer(pendingRequestId, itemId)
			end)
		end
		if robuxButton then
			RuntimeGuard.Connect(robuxButton.Activated, debugName .. ".Robux", function()
				local productId = int(valueFrom(config, "getDevProductId", item, 0), 0)
				local requiredRebirths = int(valueFrom(config, "getRequiredRebirths", item, 0), 0)
				local current = state()
				if productId > 0 and current.ready and current.rebirths >= requiredRebirths then
					MarketplaceService:PromptProductPurchase(player, productId)
				end
			end)
		end

		rows[#rows + 1] = {
			item = item,
			nameLabel = findDescendant(rowGui, "Name", "TextLabel"),
			rarityLabel = findDescendant(rowGui, "Rarity", "TextLabel"),
			descriptionLabel = findDescendant(rowGui, "Description", "TextLabel"),
			lockedFrame = findDescendant(rowGui, "isLocked", "GuiObject"),
			cashButton = cashButton,
			robuxButton = robuxButton,
			cashPriceLabel = cashButton and findDescendant(cashButton, "Price", "TextLabel"),
			robuxPriceLabel = robuxButton and findDescendant(robuxButton, "Price", "TextLabel"),
			cannotAfford = cashButton and findDescendant(cashButton, "CannotAfford", "ImageLabel"),
		}
	end

	RuntimeGuard.Connect(closeButton.Activated, debugName .. ".Close", function()
		manuallyClosed = true
		MenuGui.ClosePanel(panelName)
	end)
	RuntimeGuard.Connect(purchaseResult.OnClientEvent, debugName .. ".Result", function(payload)
		if type(payload) == "table" and payload.requestId == pendingRequestId then
			pendingRequestId = nil
			render()
		end
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Rebirths, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, render)

	RuntimeGuard.Spawn(debugName .. ".Proximity", function()
		while gui and gui.Parent do
			if nearShop(player, shopPartName) then
				local activePanel = MenuGui.ActivePanel()
				if not manuallyClosed
					and (activePanel == nil or activePanel == panelName or MenuGui.ActivePanelGroup() == menuGroup) then
					MenuGui.OpenPanel(panelName)
				end
			else
				manuallyClosed = false
				if MenuGui.IsOpen(panelName) then
					MenuGui.ClosePanel(panelName)
				end
			end
			task.wait(PROXIMITY_SECONDS)
		end
	end)

	render()
end

return ShopPanelController
