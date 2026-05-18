local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local RebirthController = {}

local GENERATED_REWARD_ATTR = "RebirthGeneratedReward"
local STATE_RETRY_SECONDS = 2

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
	local prefix = amount > 1 and ("x" .. tostring(amount) .. " ") or ""
	if reward.kind == "Pet" then
		return prefix .. tostring(reward.displayName or reward.petId or "Pet")
	end
	if reward.kind == "FeedMachine" then
		return prefix .. tostring(reward.displayName or reward.feedType or "Feed Machine")
	end
	return prefix .. tostring(reward.displayName or reward.kind or "Reward")
end

local function cloneTemplate()
	local uiFolder = ReplicatedStorage:WaitForChild("UI")
	local template = uiFolder:WaitForChild("Rebirth", 10)
	if template and template:IsA("ScreenGui") then
		return template:Clone()
	end
	warn("[RebirthController] Missing ReplicatedStorage.UI.Rebirth")
	return nil
end

local function findHudOpenButton(playerGui)
	local hud = playerGui:WaitForChild("HUD", 10)
	if not hud then
		warn("[RebirthController] Missing PlayerGui.HUD for rebirth open button")
		return nil
	end
	return findDescendant(hud, "RebirthOpenButton", "GuiButton")
end

function RebirthController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild("Rebirth")
	if existing then
		existing:Destroy()
	end

	local rebirthGui = cloneTemplate()
	if not rebirthGui then
		return
	end
	rebirthGui.Parent = playerGui
	rebirthGui.Enabled = true

	local panel = findDescendant(rebirthGui, "Panel", "GuiObject")
	local closeButton = findDescendant(rebirthGui, "CloseButton", "GuiButton")
	local openButton = findHudOpenButton(playerGui)
		or findDescendant(rebirthGui, "OpenButton", "GuiButton")
		or findDescendant(rebirthGui, "RebirthOpenButton", "GuiButton")
	local rebirthButton = findDescendant(rebirthGui, "RebirthButton", "GuiButton")
	local skipButton = findDescendant(rebirthGui, "SkipButton", "GuiButton")
	local tierLabel = findDescendant(rebirthGui, "TierLabel", "TextLabel")
	local priceLabel = findDescendant(rebirthGui, "PriceLabel", "TextLabel")
	local cashLabel = findDescendant(rebirthGui, "CashLabel", "TextLabel")
	local progressBar = findDescendant(rebirthGui, "ProgressBar", "GuiObject")
	local progressFill = progressBar and findDescendant(progressBar, "Fill", "GuiObject") or findDescendant(rebirthGui, "Fill", "GuiObject")
	local rewardList = findDescendant(rebirthGui, "RewardList", "GuiObject")
	local rewardTemplate = rewardList and findDescendant(rewardList, "RewardTemplate", "GuiObject")
	local errorLabel = findDescendant(rebirthGui, "ErrorLabel", "TextLabel")

	if not (panel and closeButton and rebirthButton and skipButton and tierLabel and priceLabel and cashLabel and progressFill and rewardList and rewardTemplate) then
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
	rebirthGui.Enabled = false
	local panelState = UiEffects.PreparePanel(panel)

	local RebirthStateRequest = Remotes.get(Remotes.Names.RebirthStateRequest)
	local RebirthStateUpdated = Remotes.get(Remotes.Names.RebirthStateUpdated)
	local RebirthRequest = Remotes.get(Remotes.Names.RebirthRequest)
	local RebirthResult = Remotes.get(Remotes.Names.RebirthResult)
	local CurrencyUpdated = Remotes.get(Remotes.Names.CurrencyUpdated)

	local latestState = nil
	local currentCurrency = 0
	local nextPrice = 0
	local skipProductId = nil
	local pendingRequest = false
	local nextRequestId = 0
	local lastStateRequest = 0
	local isOpen = false
	local transitionToken = 0

	local function setError(text)
		if errorLabel then
			errorLabel.Text = text or ""
			errorLabel.Visible = text ~= nil and text ~= ""
		end
	end

	local function requestState()
		lastStateRequest = os.clock()
		RebirthStateRequest:FireServer()
	end

	local function setProgress(progress)
		progress = math.clamp(tonumber(progress) or 0, 0, 1)
		progressFill.Size = UDim2.new(progress, 0, progressFill.Size.Y.Scale, progressFill.Size.Y.Offset)
	end

	local function clearGeneratedRewards()
		for _, child in ipairs(rewardList:GetChildren()) do
			if child:GetAttribute(GENERATED_REWARD_ATTR) == true then
				child:Destroy()
			end
		end
	end

	local function renderRewards(rewards)
		clearGeneratedRewards()
		for index, reward in ipairs(type(rewards) == "table" and rewards or {}) do
			local row = rewardTemplate:Clone()
			row.Name = "Reward_" .. tostring(index)
			row.LayoutOrder = index
			row.Visible = true
			row:SetAttribute(GENERATED_REWARD_ATTR, true)
			UiEffects.SetTextStack(row, rewardText(reward))
			row.Parent = rewardList
		end
	end

	local function render()
		local state = latestState or {}
		currentCurrency = tonumber(state.currency) or currentCurrency
		nextPrice = tonumber(state.price) or nextPrice
		skipProductId = tonumber(state.skipProductId)

		if state.maxTier == true then
			UiEffects.SetTextStack(tierLabel, "Max Rebirth")
			UiEffects.SetTextStack(priceLabel, "Max")
			UiEffects.SetTextStack(cashLabel, UiEffects.FormatCurrency(currentCurrency))
			setProgress(1)
			UiEffects.SetButtonEnabled(rebirthButton, false)
			UiEffects.SetButtonEnabled(skipButton, false)
			renderRewards({})
			return
		end

		local nextTier = tonumber(state.nextTier) or 0
		UiEffects.SetTextStack(tierLabel, "Rebirth " .. tostring(nextTier))
		UiEffects.SetTextStack(priceLabel, UiEffects.FormatCurrency(nextPrice))
		UiEffects.SetTextStack(cashLabel, UiEffects.FormatCurrency(currentCurrency) .. " / " .. UiEffects.FormatCurrency(nextPrice))
		setProgress(nextPrice > 0 and currentCurrency / nextPrice or 0)

		local canRebirth = state.profileReady == true and nextPrice > 0 and currentCurrency >= nextPrice and not pendingRequest
		UiEffects.SetButtonEnabled(rebirthButton, canRebirth)
		UiEffects.SetButtonEnabled(skipButton, state.profileReady == true and type(skipProductId) == "number" and skipProductId > 0 and not pendingRequest)
		renderRewards(state.rewards)
	end

	local function openPanel()
		if isOpen then
			requestState()
			return
		end
		isOpen = true
		transitionToken += 1
		rebirthGui.Enabled = true
		UiEffects.PlayOpen(panel, panelState)
		requestState()
	end

	local function closePanel()
		if not isOpen then
			return
		end
		isOpen = false
		transitionToken += 1
		local token = transitionToken
		UiEffects.PlayClose(panel, panelState, function()
			if transitionToken == token and not isOpen then
				rebirthGui.Enabled = false
			end
		end)
	end

	closeButton.Activated:Connect(closePanel)
	if openButton then
		openButton.Activated:Connect(openPanel)
	end

	rebirthButton.Activated:Connect(function()
		if pendingRequest or currentCurrency < nextPrice or nextPrice <= 0 then
			return
		end
		pendingRequest = true
		nextRequestId += 1
		setError(nil)
		render()
		RebirthRequest:FireServer(nextRequestId)
	end)

	skipButton.Activated:Connect(function()
		if pendingRequest or type(skipProductId) ~= "number" or skipProductId <= 0 then
			return
		end
		MarketplaceService:PromptProductPurchase(player, skipProductId)
	end)

	RebirthStateUpdated.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		latestState = payload
		setError(nil)
		render()
	end)

	RebirthResult.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		pendingRequest = false
		if type(payload.state) == "table" then
			latestState = payload.state
		end
		if payload.success ~= true then
			setError(tostring(payload.code or "Could not rebirth."))
		else
			setError(nil)
		end
		render()
	end)

	CurrencyUpdated.OnClientEvent:Connect(function(amount)
		currentCurrency = tonumber(amount) or currentCurrency
		if latestState then
			latestState.currency = currentCurrency
		end
		render()
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, wasPurchased)
		if userId ~= player.UserId or not wasPurchased then
			return
		end
		if type(skipProductId) == "number" and productId == skipProductId then
			task.delay(0.5, requestState)
		end
	end)

	task.spawn(function()
		while rebirthGui.Parent do
			task.wait(STATE_RETRY_SECONDS)
			if isOpen and os.clock() - lastStateRequest >= STATE_RETRY_SECONDS then
				requestState()
			end
		end
	end)

	requestState()
	render()
end

return RebirthController
