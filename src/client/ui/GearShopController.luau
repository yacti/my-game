local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GearShopBalance = require(Shared:WaitForChild("GearShopBalance"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local GearShopController = {}

local TEMPLATE_WAIT_SECONDS = 10
local PROXIMITY_SECONDS = 0.1
local productPriceById = {}

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

local function displayName(item)
	local template = feedTemplate(item.FeedType)
	return template and template.Name or item.FeedType or "Item"
end

local function robuxText(productId, onLoaded)
	productId = tonumber(productId) or 0
	if productId <= 0 then
		return "Robux"
	end
	local cached = productPriceById[productId]
	if cached then
		return cached
	end

	productPriceById[productId] = "Robux"
	RuntimeGuard.Spawn("GearShopController.ProductInfo", function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, productId, Enum.InfoType.Product)
		if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
			productPriceById[productId] = tostring(info.PriceInRobux)
			if onLoaded then
				onLoaded()
			end
		end
	end)
	return productPriceById[productId]
end

local function findDescendant(root, name, className)
	if not root then return nil end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

local function shopPart()
	local map = Workspace:FindFirstChild("Map")
	local shopParts = map and map:FindFirstChild("ShopParts")
	local part = shopParts and shopParts:FindFirstChild("GearShop")
	return part and part:IsA("BasePart") and part or nil
end

local function rootPart(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function nearShop(player)
	local part = shopPart()
	local root = rootPart(player)
	if not (part and root) then return false end

	local localPosition = part.CFrame:PointToObjectSpace(root.Position)
	local half = part.Size * 0.5
	return math.abs(localPosition.X) <= half.X
		and math.abs(localPosition.Y) <= half.Y
		and math.abs(localPosition.Z) <= half.Z
end

local function cloneGui(playerGui)
	local ui = ReplicatedStorage:WaitForChild("UI", TEMPLATE_WAIT_SECONDS)
	local template = ui and ui:WaitForChild("GearShop", TEMPLATE_WAIT_SECONDS)
	if not (template and template:IsA("ScreenGui")) then
		warn("[GearShopController] Missing ReplicatedStorage.UI.GearShop")
		return nil
	end

	local existing = playerGui:FindFirstChild("GearShop")
	if existing then
		existing:Destroy()
	end

	local clone = template:Clone()
	clone.Parent = playerGui
	return clone
end

function GearShopController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = cloneGui(playerGui)
	if not gui then return end

	local panel = gui:FindFirstChild("GearShop")
	local closeButton = panel and findDescendant(panel, "CloseButton", "GuiButton")
	local holder = panel and findDescendant(panel, "SFHolder", "ScrollingFrame")
	local template = holder and holder:FindFirstChild("Template")
	if not (panel and panel:IsA("GuiObject") and closeButton and holder and template and template:IsA("GuiObject")) then
		warn("[GearShopController] GearShop UI missing required instances")
		gui.Enabled = false
		return
	end

	local purchaseRequest = Remotes.get(Remotes.Names.GearShopPurchaseRequest)
	local purchaseResult = Remotes.get(Remotes.Names.GearShopPurchaseResult)

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
			local locked = current.rebirths < (tonumber(item.RequiredRebirths) or 0)
			local affordable = current.currency >= (tonumber(item.Price) or math.huge)
			local cashEnabled = current.ready and not locked and affordable and pendingRequestId == nil
			local robuxProductId = tonumber(item.DevProductId) or 0

			UiEffects.SetTextStack(row.nameLabel, displayName(item))
			UiEffects.SetTextStack(row.descriptionLabel, item.Description or "")
			UiEffects.SetTextStack(row.cashPriceLabel, UiEffects.FormatCurrency(item.Price or 0))
			UiEffects.SetTextStack(row.robuxPriceLabel, robuxText(item.DevProductId, render))

			if row.rarityLabel then
				local rarity = item.Rarity or Rarities.Common
				UiEffects.SetTextStack(row.rarityLabel, rarity)
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

	local function openPanel()
		if open or manuallyClosed then return end
		open = true
		transitionToken += 1
		render()
		UiEffects.PlayOpen(panel, panelState)
	end

	local function closePanel()
		if not open then return end
		open = false
		transitionToken += 1
		local token = transitionToken
		UiEffects.PlayClose(panel, panelState, function()
			if token == transitionToken and not open then
				panel.Visible = false
			end
		end)
	end

	for index, item in ipairs(GearShopBalance.ClientItems()) do
		local rowGui = template:Clone()
		rowGui.Name = "GearShopItem_" .. tostring(item.FeedType or index)
		rowGui.LayoutOrder = index
		rowGui.Visible = true
		rowGui.Parent = holder
		UiEffects.BindAllButtons(rowGui)
		ViewportPreview.Render(findDescendant(rowGui, "ItemIcon", "ViewportFrame"), feedTemplate(item.FeedType))

		local cashButton = findDescendant(rowGui, "CashBtn", "GuiButton")
		local robuxButton = findDescendant(rowGui, "RobuxBtn", "GuiButton")
		if cashButton then
			RuntimeGuard.Connect(cashButton.Activated, "GearShopController.Cash", function()
				if pendingRequestId ~= nil then return end
				local current = state()
				if not current.ready
					or current.rebirths < (tonumber(item.RequiredRebirths) or 0)
					or current.currency < (tonumber(item.Price) or math.huge) then
					return
				end
				nextRequestId += 1
				pendingRequestId = nextRequestId
				render()
				purchaseRequest:FireServer(pendingRequestId, item.FeedType)
			end)
		end
		if robuxButton then
			RuntimeGuard.Connect(robuxButton.Activated, "GearShopController.Robux", function()
				local productId = tonumber(item.DevProductId) or 0
				local current = state()
				if productId > 0 and current.ready and current.rebirths >= (tonumber(item.RequiredRebirths) or 0) then
					MarketplaceService:PromptProductPurchase(player, productId)
				end
			end)
		end

		rows[#rows + 1] = {
			item = item,
			nameLabel = rowGui:FindFirstChild("Name"),
			rarityLabel = rowGui:FindFirstChild("Rarity"),
			descriptionLabel = rowGui:FindFirstChild("Description"),
			lockedFrame = rowGui:FindFirstChild("isLocked"),
			cashButton = cashButton,
			robuxButton = robuxButton,
			cashPriceLabel = cashButton and findDescendant(cashButton, "Price", "TextLabel"),
			robuxPriceLabel = robuxButton and findDescendant(robuxButton, "Price", "TextLabel"),
			cannotAfford = cashButton and findDescendant(cashButton, "CannotAfford", "ImageLabel"),
		}
	end

	RuntimeGuard.Connect(closeButton.Activated, "GearShopController.Close", function()
		manuallyClosed = true
		closePanel()
	end)
	RuntimeGuard.Connect(purchaseResult.OnClientEvent, "GearShopController.Result", function(payload)
		if type(payload) == "table" and payload.requestId == pendingRequestId then
			pendingRequestId = nil
			render()
		end
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Rebirths, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, render)

	RuntimeGuard.Spawn("GearShopController.Proximity", function()
		while gui.Parent do
			if nearShop(player) then
				openPanel()
			else
				manuallyClosed = false
				closePanel()
			end
			task.wait(PROXIMITY_SECONDS)
		end
	end)

	render()
end

return GearShopController
