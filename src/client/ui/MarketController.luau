local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local State = require(Shared:WaitForChild("State"))
local MarketProducts = require(Shared:WaitForChild("MarketProducts"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local MarketController = {}

local GENERATED_CARD_ATTR = "MarketGeneratedCard"
local OPEN_TOUCH_DEBOUNCE = 1
local TOUCH_CHECK_INTERVAL = 0.15
local STATE_RETRY_SECONDS = 2
local TREE_SPIN_RADIANS_PER_SECOND = math.rad(18)
local PENDING_PURCHASE_TIMEOUT_SECONDS = 8

local function waitForDirectChild(parent, name, className)
	local child = parent:WaitForChild(name, 10)
	if not child or not child:IsA(className) then
		warn(string.format("[MarketController] Missing %s.%s (%s)", parent:GetFullName(), name, className))
		return nil
	end
	return child
end

local function directChild(parent, name, className)
	local child = parent and parent:FindFirstChild(name)
	if not child or not child:IsA(className) then
		return nil
	end
	return child
end

local function formatCountdown(seconds)
	seconds = math.max(math.floor(seconds or 0), 0)
	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60
	return string.format("%02d:%02d", minutes, remainder)
end

local function findFeedTemplate(feedType)
	local root = ReplicatedStorage:FindFirstChild("FeedMachines")
	if not root then
		return nil
	end
	for _, instance in ipairs(root:GetDescendants()) do
		if (instance:IsA("BasePart") or instance:IsA("Model")) and instance:GetAttribute(State.Feed.Type) == feedType then
			return instance
		end
	end
	return nil
end

local function clearViewport(viewport)
	for _, child in ipairs(viewport:GetChildren()) do
		if child:IsA("WorldModel") or child:IsA("Camera") then
			child:Destroy()
		end
	end
end

local function modelFromTemplateClone(clone)
	if clone:IsA("Model") then
		return clone
	end
	if clone:IsA("BasePart") then
		local model = Instance.new("Model")
		model.Name = clone.Name
		clone.Parent = model
		model.PrimaryPart = clone
		return model
	end
	return nil
end

local function renderViewport(viewport, feedType, shouldSpin, spinConnections)
	local template = findFeedTemplate(feedType)
	if not template then
		return
	end

	clearViewport(viewport)

	local world = Instance.new("WorldModel")
	world.Name = "PreviewWorld"
	world.Parent = viewport

	local clone = template:Clone()
	local model = modelFromTemplateClone(clone)
	if not model then
		clone:Destroy()
		return
	end
	model.Parent = world

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end

	model:PivotTo(CFrame.new())
	local boundingCFrame, size = model:GetBoundingBox()
	model:PivotTo(CFrame.new(-boundingCFrame.Position) * model:GetPivot())
	_, size = model:GetBoundingBox()

	local maxSize = math.max(size.X, size.Y, size.Z, 1)
	local camera = Instance.new("Camera")
	camera.Name = "PreviewCamera"
	camera.CFrame = CFrame.lookAt(
		Vector3.new(0, maxSize * 0.35, maxSize * 2.2),
		Vector3.new(0, maxSize * 0.1, 0)
	)
	camera.FieldOfView = 35
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	if shouldSpin then
		local angle = 0
		local conn = RunService.RenderStepped:Connect(function(dt)
			if not model.Parent then
				return
			end
			angle = (angle + dt * TREE_SPIN_RADIANS_PER_SECOND) % (math.pi * 2)
			model:PivotTo(CFrame.Angles(0, angle, 0))
		end)
		spinConnections[#spinConnections + 1] = conn
	end
end

local function cloneMarketTemplate()
	local uiFolder = ReplicatedStorage:WaitForChild("UI")
	local template = uiFolder:WaitForChild("MarketGui", 10)
	if template and template:IsA("ScreenGui") then
		return template:Clone()
	end
	warn("[MarketController] Missing ReplicatedStorage.UI.MarketGui")
	return nil
end

function MarketController.start()
	local player = Players.LocalPlayer
	local PlayerGui = player:WaitForChild("PlayerGui")

	local existingGui = PlayerGui:FindFirstChild("MarketGui")
	if existingGui then
		existingGui:Destroy()
	end

	local marketGui = cloneMarketTemplate()
	if not marketGui then
		return
	end
	marketGui.Parent = PlayerGui

	local market = waitForDirectChild(marketGui, "Market", "Frame")
	if not market then
		return
	end

	local closeButton = waitForDirectChild(market, "CloseButton", "ImageButton")
	local sfHolder = waitForDirectChild(market, "ScrollHolder", "ScrollingFrame")
	local template = sfHolder and waitForDirectChild(sfHolder, "ItemTemplate", "Frame")
	local background = waitForDirectChild(market, "Background", "Frame")
	local header = background and waitForDirectChild(background, "Header", "Frame")
	local restockTimer = header and waitForDirectChild(header, "RestockTimer", "TextLabel")
	local restockButton = header and waitForDirectChild(header, "Restock", "ImageButton")

	if not (closeButton and sfHolder and template and restockTimer and restockButton) then
		return
	end

	template.Visible = false
	marketGui.Enabled = false
	local panelState = UiEffects.PreparePanel(market)
	UiEffects.BindButton(closeButton)
	UiEffects.BindButton(restockButton)
	UiEffects.SetButtonEnabled(restockButton, true)

	local MarketStateRequest = Remotes.get(Remotes.Names.MarketStateRequest)
	local MarketStateUpdated = Remotes.get(Remotes.Names.MarketStateUpdated)
	local MarketPurchaseRequest = Remotes.get(Remotes.Names.MarketPurchaseRequest)
	local MarketPurchaseResult = Remotes.get(Remotes.Names.MarketPurchaseResult)
	local MarketRestockResult = Remotes.get(Remotes.Names.MarketRestockResult)

	local cardsByFeedType = {}
	local spinConnections = {}
	local latestCatalog = {}
	local latestRemaining = {}
	local currentCurrency = 0
	local serverTimeOffset = 0
	local cycleEnd = 0
	local lastStateRequest = 0
	local nextPurchaseRequestId = 0
	local pendingPurchases = {}
	local lastOpenTouch = 0
	local isOpen = false
	local transitionToken = 0

	local function cleanupCards()
		for _, conn in ipairs(spinConnections) do
			conn:Disconnect()
		end
		table.clear(spinConnections)
		table.clear(cardsByFeedType)

		for _, child in ipairs(sfHolder:GetChildren()) do
			if child:GetAttribute(GENERATED_CARD_ATTR) == true then
				child:Destroy()
			end
		end
	end

	local function prunePendingPurchases()
		local now = os.clock()
		for feedType, startedAt in pairs(pendingPurchases) do
			if type(startedAt) ~= "number" or now - startedAt > PENDING_PURCHASE_TIMEOUT_SECONDS then
				pendingPurchases[feedType] = nil
			end
		end
	end

	local function isPurchasePending(feedType)
		prunePendingPurchases()
		return pendingPurchases[feedType] ~= nil
	end

	local function updateCard(item)
		local card = cardsByFeedType[item.feedType]
		if not card then
			return
		end
		local remaining = latestRemaining[item.feedType] or 0
		local cashBtn = directChild(directChild(card, "BuyBtns", "Frame"), "CashBtn", "ImageButton")
		local robuxBtn = directChild(directChild(card, "BuyBtns", "Frame"), "RobuxBtn", "ImageButton")

		UiEffects.SetTextStack(directChild(card, "ItemName", "TextLabel"), item.displayName or item.feedType)
		UiEffects.SetTextStack(directChild(card, "Stock", "TextLabel"), "Stock: " .. tostring(remaining))

		if cashBtn then
			UiEffects.SetTextStack(directChild(cashBtn, "PriceLabel", "TextLabel"), UiEffects.FormatCurrency(item.price))
			local canBuy = remaining > 0 and currentCurrency >= (item.price or 0) and not isPurchasePending(item.feedType)
			UiEffects.SetButtonEnabled(cashBtn, canBuy)
		end

		if robuxBtn then
			local hasRobuxProduct = type(item.robuxProductId) == "number"
			local robuxText = "Soon"
			if hasRobuxProduct then
				robuxText = type(item.robuxPrice) == "number" and ("R$" .. tostring(item.robuxPrice)) or "Robux"
			end
			UiEffects.SetTextStack(directChild(robuxBtn, "PriceLabel", "TextLabel"), robuxText)
			UiEffects.SetButtonEnabled(robuxBtn, hasRobuxProduct)
		end
	end

	local function rebuildCards()
		cleanupCards()
		for index, item in ipairs(latestCatalog) do
			local card = template:Clone()
			card.Name = "MarketItem_" .. item.feedType
			card.LayoutOrder = index
			card.Visible = true
			card:SetAttribute(GENERATED_CARD_ATTR, true)
			card.Parent = sfHolder
			cardsByFeedType[item.feedType] = card

			local iconHolder = directChild(card, "IconHolder", "Frame")
			local viewport = iconHolder and directChild(iconHolder, "ItemIcon", "ViewportFrame")
			if viewport then
				renderViewport(viewport, item.feedType, item.feedClass == "Tree", spinConnections)
			end

			local cashBtn = directChild(directChild(card, "BuyBtns", "Frame"), "CashBtn", "ImageButton")
			if cashBtn then
				UiEffects.BindButton(cashBtn)
				cashBtn.Activated:Connect(function()
					if isPurchasePending(item.feedType) then
						return
					end
					local remaining = latestRemaining[item.feedType] or 0
					if remaining <= 0 or currentCurrency < (item.price or 0) then
						return
					end
					nextPurchaseRequestId += 1
					pendingPurchases[item.feedType] = os.clock()
					updateCard(item)
					MarketPurchaseRequest:FireServer(nextPurchaseRequestId, item.feedType)
				end)
			end
			local robuxBtn = directChild(directChild(card, "BuyBtns", "Frame"), "RobuxBtn", "ImageButton")
			if robuxBtn then
				UiEffects.BindButton(robuxBtn)
				robuxBtn.Activated:Connect(function()
					if type(item.robuxProductId) ~= "number" then
						return
					end
					MarketplaceService:PromptProductPurchase(player, item.robuxProductId)
				end)
			end

			updateCard(item)
		end
	end

	local function updateAllCards()
		for _, item in ipairs(latestCatalog) do
			updateCard(item)
		end
	end

	local function requestState()
		lastStateRequest = os.clock()
		MarketStateRequest:FireServer()
	end

	local function openMarket()
		if isOpen then
			requestState()
			return
		end
		isOpen = true
		transitionToken += 1
		marketGui.Enabled = true
		UiEffects.PlayOpen(market, panelState)
		requestState()
	end

	local function closeMarket()
		if not isOpen then
			return
		end
		isOpen = false
		transitionToken += 1
		local token = transitionToken
		UiEffects.PlayClose(market, panelState, function()
			if transitionToken == token and not isOpen then
				marketGui.Enabled = false
			end
		end)
	end

	closeButton.Activated:Connect(closeMarket)
	restockButton.Activated:Connect(function()
		MarketplaceService:PromptProductPurchase(player, MarketProducts.RestockProductId)
	end)

	MarketStateUpdated.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		latestCatalog = type(payload.catalog) == "table" and payload.catalog or {}
		latestRemaining = type(payload.remaining) == "table" and payload.remaining or {}
		currentCurrency = tonumber(payload.currency) or currentCurrency
		cycleEnd = tonumber(payload.cycleEnd) or 0
		serverTimeOffset = (tonumber(payload.serverTime) or os.time()) - os.time()
		prunePendingPurchases()
		rebuildCards()
	end)

	MarketPurchaseResult.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local feedType = payload.feedType
		if type(feedType) == "string" then
			pendingPurchases[feedType] = nil
			if type(payload.remaining) == "number" then
				latestRemaining[feedType] = payload.remaining
			end
		end
		if type(payload.currency) == "number" then
			currentCurrency = payload.currency
		end
		updateAllCards()
	end)

	MarketRestockResult.OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and payload.success == true then
			requestState()
		end
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, wasPurchased)
		if userId ~= player.UserId or not wasPurchased then
			return
		end
		if productId == MarketProducts.RestockProductId or MarketProducts.FeedTypeForProductId(productId) then
			task.delay(0.5, requestState)
		end
	end)

	Remotes.get(Remotes.Names.CurrencyUpdated).OnClientEvent:Connect(function(amount)
		currentCurrency = tonumber(amount) or currentCurrency
		updateAllCards()
	end)

	task.spawn(function()
		while true do
			local adjustedNow = os.time() + serverTimeOffset
			UiEffects.SetTextStack(restockTimer, formatCountdown(cycleEnd - adjustedNow))
			if isOpen and cycleEnd <= adjustedNow and os.clock() - lastStateRequest >= STATE_RETRY_SECONDS then
				requestState()
			end
			task.wait(1)
		end
	end)

	local marketPart = Workspace:WaitForChild("MarketPart", 10)
	if marketPart and marketPart:IsA("BasePart") then
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include

		local function characterIsTouchingMarket()
			local character = player.Character
			if not character then
				return false
			end
			overlapParams.FilterDescendantsInstances = { character }
			return #Workspace:GetPartsInPart(marketPart, overlapParams) > 0
		end

		marketPart.Touched:Connect(function(hit)
			local character = player.Character
			if not character or not hit:IsDescendantOf(character) then
				return
			end
			if os.clock() - lastOpenTouch < OPEN_TOUCH_DEBOUNCE then
				return
			end
			lastOpenTouch = os.clock()
			openMarket()
		end)

		local touchCheckElapsed = 0
		RunService.Heartbeat:Connect(function(dt)
			touchCheckElapsed += dt
			if touchCheckElapsed < TOUCH_CHECK_INTERVAL then
				return
			end
			touchCheckElapsed = 0

			if characterIsTouchingMarket() then
				if not isOpen and os.clock() - lastOpenTouch >= OPEN_TOUCH_DEBOUNCE then
					lastOpenTouch = os.clock()
					openMarket()
				end
			elseif isOpen then
				closeMarket()
			end
		end)
	else
		warn("[MarketController] Missing Workspace.MarketPart")
	end

	task.delay(1, requestState)
end

return MarketController
