local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local GrowingVisuals = require(Shared:WaitForChild("GrowingVisuals"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RebirthBalance = require(Shared:WaitForChild("RebirthBalance"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ConfettiEffect = require(script.Parent:WaitForChild("ConfettiEffect"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local RebirthController = {}

local GENERATED_REWARD_ATTR = "RebirthGeneratedReward"
local HUD_LEFT_BUTTONS_NAME = "LeftButtons"
local HUD_REBIRTH_BUTTON_NAME = "RebirthButton"
local MENU_REBIRTH_FRAME_NAME = "Rebirth"
local STATE_RETRY_SECONDS = 2
local productPriceById = {}

local function findDescendant(root, name, className)
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and descendant:IsA(className) then
			return descendant
		end
	end
	return nil
end

local function rewardText(reward)
	local amount = math.max(math.floor(tonumber(reward.amount) or 0), 0)
	local formattedAmount = NumberFormatter.Integer(amount)
	local prefix = amount > 1 and ("x" .. formattedAmount .. " ") or ""
	if reward.kind == "Pet" then
		if amount <= 1 then
			return "+1 Pet Slot"
		end
		return "+" .. formattedAmount .. " Pet Slots"
	end
	if reward.kind == "FeedMachine" then
		return prefix .. tostring(reward.displayName or reward.feedType or "Feed Machine")
	end
	return prefix .. tostring(reward.displayName or reward.kind or "Reward")
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
	RuntimeGuard.Spawn("RebirthController.ProductInfo", function()
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

local function petTemplateFor(petId)
	local visual = PetCatalog.VisualForPetId(petId)
	local modelName = visual and visual.ModelName
	if type(modelName) ~= "string" or modelName == "" then
		return nil
	end

	local petModels = Assets.Find(Assets.Names.PetModels)
	local template = petModels and petModels:FindFirstChild(modelName)
	return template and template:IsA("Model") and template or nil
end

local function rewardTemplateFor(reward)
	if type(reward) ~= "table" then
		return nil
	end
	if reward.kind == "Pet" then
		return petTemplateFor(reward.petId)
	end
	if reward.kind == "FeedMachine" then
		return GrowingVisuals.FeedTemplateFor(reward.feedType)
	end
	return nil
end

local function findHudOpenButton(playerGui)
	local hud = playerGui:WaitForChild("HUD", 10)
	if not hud then
		warn("[RebirthController] Missing PlayerGui.HUD for rebirth open button")
		return nil
	end

	local leftButtons = hud:FindFirstChild(HUD_LEFT_BUTTONS_NAME)
	if not (leftButtons and leftButtons:IsA("GuiObject")) then
		warn("[RebirthController] Missing HUD.LeftButtons for rebirth open button")
		return nil
	end

	local button = leftButtons:FindFirstChild(HUD_REBIRTH_BUTTON_NAME)
	if button and button:IsA("GuiButton") then
		return button
	end
	warn("[RebirthController] Missing HUD.LeftButtons.RebirthButton GuiButton")
	return nil
end

function RebirthController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local rebirthFrame = MenuGui.GetFrame(MENU_REBIRTH_FRAME_NAME, "RebirthController")
	if not rebirthFrame then
		return
	end

	local panel = findDescendant(rebirthFrame, "Panel", "GuiObject")
	local closeButton = findDescendant(rebirthFrame, "CloseButton", "GuiButton")
	local openButton = findHudOpenButton(playerGui)
	local rebirthButton = findDescendant(rebirthFrame, "RebirthButton", "GuiButton")
	local rebirthCannotAfford = rebirthButton and findDescendant(rebirthButton, "CannotAfford", "GuiObject")
	local skipButton = findDescendant(rebirthFrame, "SkipButton", "GuiButton")
	local skipButtonPrice = skipButton and findDescendant(skipButton, "Price", "TextLabel")
	local tierLabel = findDescendant(rebirthFrame, "TierLabel", "TextLabel")
	local cashLabel = findDescendant(rebirthFrame, "CashLabel", "TextLabel")
	local progressBar = findDescendant(rebirthFrame, "ProgressBar", "GuiObject")
	local progressFill = progressBar and findDescendant(progressBar, "Fill", "CanvasGroup") or findDescendant(rebirthFrame, "Fill", "CanvasGroup")
	local rewardList = findDescendant(rebirthFrame, "RewardList", "GuiObject")
	local rewardTemplate = rewardList and findDescendant(rewardList, "RewardTemplate", "GuiObject")
	local petHolderTemplate = rewardList and findDescendant(rewardList, "PetHolder", "GuiObject")
	local petViewportTemplate = petHolderTemplate and findDescendant(petHolderTemplate, "PetIcon", "ViewportFrame")
	local errorLabel = findDescendant(rebirthFrame, "ErrorLabel", "TextLabel")

	if not (panel and closeButton and rebirthButton and skipButton and skipButtonPrice and tierLabel and cashLabel and progressFill and rewardList and rewardTemplate and petHolderTemplate and petViewportTemplate) then
		warn("[RebirthController] Rebirth UI is missing required named instances")
		return
	end

	UiEffects.BindButton(closeButton)
	UiEffects.BindButton(rebirthButton)
	UiEffects.BindButton(skipButton)
	if openButton then
		UiEffects.BindButton(openButton)
	end
	rewardTemplate.Visible = false
	petHolderTemplate.Visible = false
	rebirthFrame.Visible = false
	progressFill.BackgroundTransparency = 1
	progressFill.AnchorPoint = Vector2.new(0, 0.5)
	progressFill.Position = UDim2.new(0, 0, 0.5, 0)
	local progressFillHeight = UDim.new(progressFill.Size.Y.Scale, progressFill.Size.Y.Offset)
	local panelState = UiEffects.PreparePanel(panel)

	local RebirthRequest = Remotes.get(Remotes.Names.RebirthRequest)
	local RebirthResult = Remotes.get(Remotes.Names.RebirthResult)

	local latestState = nil
	local currentCurrency = 0
	local nextPrice = 0
	local skipProductId = nil
	local pendingRequest = false
	local nextRequestId = 0
	local lastStateRequest = 0
	local isOpen = false
	local transitionToken = 0
	local renderedRewardsSignature = nil
	local render

	local function setError(text)
		if errorLabel then
			errorLabel.Text = text or ""
			errorLabel.Visible = text ~= nil and text ~= ""
		end
		if text ~= nil and text ~= "" then
			UiEffects.PlayError()
		end
	end

	local function buildReplicaState()
		local currency = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Currency)) or currentCurrency
		local rebirths = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Rebirths)) or 0
		local tierNumber, tier = RebirthBalance.GetNextTier(rebirths)
		local price = tier and math.max(math.floor(tonumber(tier.Price) or 0), 0) or 0

		return {
			profileReady = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true,
			rebirths = rebirths,
			nextTier = tier and tierNumber or nil,
			maxTier = tier == nil,
			price = price,
			currency = currency,
			progress = price > 0 and math.clamp(currency / price, 0, 1) or 1,
			rewards = RebirthBalance.ToClientRewards(tier),
			skipProductId = tier and math.max(math.floor(tonumber(tier.SkipProductId) or 0), 0) > 0 and tier.SkipProductId or nil,
		}
	end

	local function requestState()
		lastStateRequest = os.clock()
		latestState = buildReplicaState()
		render()
	end

	local function setProgress(progress)
		progress = math.clamp(tonumber(progress) or 0, 0, 1)
		progressFill.Size = UDim2.new(progress, 0, progressFillHeight.Scale, progressFillHeight.Offset)
		progressFill.Visible = progress > 0
	end

	local function clearGeneratedRewards()
		for _, child in ipairs(rewardList:GetChildren()) do
			if child:GetAttribute(GENERATED_REWARD_ATTR) == true then
				child:Destroy()
			end
		end
	end

	local function rewardsSignature(rewards)
		local parts = {}
		for index, reward in ipairs(type(rewards) == "table" and rewards or {}) do
			parts[index] = table.concat({
				tostring(reward.kind),
				tostring(reward.petId),
				tostring(reward.feedType),
				tostring(reward.amount),
				tostring(reward.displayName),
			}, "\31")
		end
		return table.concat(parts, "\30")
	end

	local function rewardViewportOptions(reward)
		if type(reward) == "table" and reward.kind == "Pet" then
			return {
				targetMaxDimension = ViewportPreview.PET_TARGET_MAX_DIMENSION,
				zoom = ViewportPreview.PET_VIEWPORT_ZOOM,
			}
		end
		return nil
	end

	local function renderRewardViewport(row, template, options)
		if not template then
			return
		end

		local itemIcon = findDescendant(row, "ItemIcon", "GuiObject")
		local viewport = petViewportTemplate:Clone()
		viewport.Name = "ItemViewport"
		if itemIcon then
			viewport.AnchorPoint = itemIcon.AnchorPoint
			viewport.Position = itemIcon.Position
			viewport.Size = itemIcon.Size
			viewport.LayoutOrder = itemIcon.LayoutOrder
			viewport.ZIndex = itemIcon.ZIndex
			viewport.Parent = itemIcon.Parent
		else
			viewport.Parent = row
		end
		viewport.Visible = true

		if ViewportPreview.Render(viewport, template, options) then
			if itemIcon then
				itemIcon.Visible = false
			end
		else
			viewport:Destroy()
		end
	end

	local function renderRewards(rewards)
		local signature = rewardsSignature(rewards)
		if signature == renderedRewardsSignature then
			return
		end
		renderedRewardsSignature = signature

		clearGeneratedRewards()
		for index, reward in ipairs(type(rewards) == "table" and rewards or {}) do
			local row = rewardTemplate:Clone()
			row.Name = "Reward_" .. tostring(index)
			row.LayoutOrder = index
			row.Visible = true
			row:SetAttribute(GENERATED_REWARD_ATTR, true)
			UiEffects.SetTextStack(row, rewardText(reward))
			renderRewardViewport(row, rewardTemplateFor(reward), rewardViewportOptions(reward))
			row.Parent = rewardList
		end
	end

	render = function()
		local state = latestState or {}
		currentCurrency = tonumber(state.currency) or currentCurrency
		nextPrice = tonumber(state.price) or nextPrice
		skipProductId = tonumber(state.skipProductId)

		if state.maxTier == true then
			UiEffects.SetTextStack(tierLabel, "Max Rebirth")
			UiEffects.SetTextStack(cashLabel, UiEffects.FormatCurrency(currentCurrency))
			setProgress(1)
			UiEffects.SetButtonEnabled(rebirthButton, false)
			if rebirthCannotAfford then
				rebirthCannotAfford.Visible = false
			end
			UiEffects.SetTextStack(skipButtonPrice, "Robux")
			UiEffects.SetButtonEnabled(skipButton, false)
			renderRewards({})
			return
		end

		local nextTier = tonumber(state.nextTier) or 0
		UiEffects.SetTextStack(tierLabel, "Rebirth " .. NumberFormatter.Integer(nextTier))
		UiEffects.SetTextStack(cashLabel, UiEffects.FormatCurrency(currentCurrency) .. " / " .. UiEffects.FormatCurrency(nextPrice))
		setProgress(nextPrice > 0 and currentCurrency / nextPrice or 0)

		local readyToAttemptRebirth = state.profileReady == true and nextPrice > 0 and not pendingRequest
		UiEffects.SetButtonEnabled(rebirthButton, readyToAttemptRebirth)
		if rebirthCannotAfford then
			rebirthCannotAfford.Visible = readyToAttemptRebirth and currentCurrency < nextPrice
		end
		UiEffects.SetTextStack(skipButtonPrice, robuxText(skipProductId, render))
		UiEffects.SetButtonEnabled(skipButton, state.profileReady == true and type(skipProductId) == "number" and skipProductId > 0 and not pendingRequest)
		renderRewards(state.rewards)
	end

	local function showPanel()
		if isOpen then
			requestState()
			return
		end
		isOpen = true
		transitionToken += 1
		rebirthFrame.Visible = true
		UiEffects.PlayOpen(panel, panelState)
		requestState()
	end

	local function hidePanel(switching)
		if not isOpen and not rebirthFrame.Visible then
			return
		end
		isOpen = false
		transitionToken += 1
		local token = transitionToken
		if switching then
			panel.Visible = false
			panel.Position = panelState.closedPosition
			panel.Size = panelState.closedSize
			rebirthFrame.Visible = false
			return
		end
		UiEffects.PlayClose(panel, panelState, function()
			if transitionToken == token and not isOpen then
				rebirthFrame.Visible = false
			end
		end)
	end

	MenuGui.RegisterPanel(MENU_REBIRTH_FRAME_NAME, {
		open = showPanel,
		close = hidePanel,
		refresh = requestState,
	})

	RuntimeGuard.Connect(closeButton.Activated, "RebirthController.CloseActivated", function()
		MenuGui.ClosePanel(MENU_REBIRTH_FRAME_NAME)
	end)
	if openButton then
		RuntimeGuard.Connect(openButton.Activated, "RebirthController.ToggleActivated", function()
			MenuGui.TogglePanel(MENU_REBIRTH_FRAME_NAME)
		end)
	end

	RuntimeGuard.Connect(rebirthButton.Activated, "RebirthController.RebirthActivated", function()
		if pendingRequest or currentCurrency < nextPrice or nextPrice <= 0 then
			return
		end
		pendingRequest = true
		nextRequestId += 1
		setError(nil)
		render()
		RebirthRequest:FireServer(nextRequestId)
	end)

	RuntimeGuard.Connect(skipButton.Activated, "RebirthController.SkipActivated", function()
		if pendingRequest or type(skipProductId) ~= "number" or skipProductId <= 0 then
			return
		end
		RuntimeGuard.Run("RebirthController.PromptProductPurchase", function()
			MarketplaceService:PromptProductPurchase(player, skipProductId)
		end)
	end)

	RuntimeGuard.Connect(RebirthResult.OnClientEvent, "RebirthController.Result", function(payload)
		if type(payload) ~= "table" then
			return
		end
		pendingRequest = false
		latestState = buildReplicaState()
		if payload.success ~= true then
			setError(tostring(payload.code or "Could not rebirth."))
		else
			setError(nil)
			ConfettiEffect.Emit()
		end
		render()
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, function()
		latestState = buildReplicaState()
		render()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Rebirths, function()
		latestState = buildReplicaState()
		render()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, function()
		latestState = buildReplicaState()
		render()
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "RebirthController.PromptPurchaseFinished", function(userId, productId, wasPurchased)
		if userId ~= player.UserId or not wasPurchased then
			return
		end
		if type(skipProductId) == "number" and productId == skipProductId then
			task.delay(0.5, function()
				RuntimeGuard.Run("RebirthController.DelayedStateRequest", requestState)
			end)
		end
	end)

	RuntimeGuard.Spawn("RebirthController.StateRetryLoop", function()
		while rebirthFrame.Parent do
			task.wait(STATE_RETRY_SECONDS)
			if isOpen and os.clock() - lastStateRequest >= STATE_RETRY_SECONDS then
				RuntimeGuard.Run("RebirthController.StateRetryRequest", requestState)
			end
		end
	end)

	requestState()
	render()
end

return RebirthController
