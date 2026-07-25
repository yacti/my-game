local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollLuckBalance = require(Shared:WaitForChild("RollLuckBalance"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local StationFocus = require(script.Parent:WaitForChild("StationFocus"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local RollLuckController = {}

local PROXIMITY_CHECK_SECONDS = 0.1
local STATE_RETRY_SECONDS = 2
local HUD_WAIT_SECONDS = 10

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

local function upgradeButtonTextRoot(button)
	if not button then
		return nil
	end
	if button:IsA("TextButton") then
		return button
	end

	local price = button:FindFirstChild("Price")
	if price and (price:IsA("TextLabel") or price:IsA("TextButton")) then
		return price
	end
	return findDescendant(button, "Price", "TextLabel")
end

local function updateUpgradeButton(button, cannotAffordImage, enabled, showCannotAfford)
	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
	if cannotAffordImage then
		cannotAffordImage.Visible = showCannotAfford
	end
end

local function formatPercent(value)
	return NumberFormatter.IntegerWithSeparators(value) .. "%"
end

local function codeToMessage(code)
	if code == "insufficient-currency" then
		return "Not enough currency."
	end
	if code == "too-far" then
		return "Move closer to the roll button."
	end
	if code == "max-level" then
		return "Luck is already maxed."
	end
	if code == "busy" or code == "rate-limited" then
		return "Try again in a moment."
	end
	if code == "no-profile" then
		return "Save data is still loading."
	end
	return "Could not upgrade luck."
end

function RollLuckController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild("HUD", HUD_WAIT_SECONDS)
	if not hud then
		warn("[RollLuckController] Missing PlayerGui.HUD")
		return
	end

	local rollButtons = hud:WaitForChild("RollButtons", HUD_WAIT_SECONDS)
	if not (rollButtons and rollButtons:IsA("GuiObject")) then
		warn("[RollLuckController] Missing HUD.RollButtons")
		return
	end

	local frame = rollButtons:WaitForChild("UpgradeLuckFrame", HUD_WAIT_SECONDS)
	if not (frame and frame:IsA("GuiObject")) then
		warn("[RollLuckController] Missing HUD.RollButtons.UpgradeLuckFrame")
		return
	end

	local luckLabel = findDescendant(frame, "LuckLabel", "TextLabel")
	local upgradeButton = findDescendant(frame, "UpgradeButton", "GuiButton")
	local upgradeButtonText = upgradeButtonTextRoot(upgradeButton)
	local cannotAffordImage = upgradeButton and findDescendant(upgradeButton, "CannotAfford", "ImageLabel")
	local errorLabel = findDescendant(frame, "ErrorLabel", "TextLabel")
	if not (luckLabel and upgradeButton and upgradeButtonText and cannotAffordImage) then
		warn("[RollLuckController] Roll luck UI is missing required named instances")
		return
	end

	local RollLuckUpgradeRequest = Remotes.get(Remotes.Names.RollLuckUpgradeRequest)
	local RollLuckUpgradeResult = Remotes.get(Remotes.Names.RollLuckUpgradeResult)
	local silentUiEffects = { silent = true }

	UiEffects.BindButton(upgradeButton, silentUiEffects)
	local panelState = UiEffects.PreparePanel(frame)

	local latestState = nil
	local currentCurrency = 0
	local pendingRequest = false
	local nextRequestId = 0
	local lastStateRequest = 0
	local wasNear = false
	local isOpen = false
	local transitionToken = 0
	local render

	local function setError(text)
		if errorLabel then
			errorLabel.Text = text or ""
			errorLabel.Visible = text ~= nil and text ~= ""
		end
	end

	local function buildReplicaState()
		local level = RollLuckBalance.LevelFor(PlayerStateStore.Get(PlayerStateStore.Fields.RollLuckLevel))
		local currency = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Currency)) or currentCurrency
		local state = RollLuckBalance.ToState(level, currency)
		state.profileReady = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
		return state
	end

	local function requestState()
		lastStateRequest = os.clock()
		latestState = buildReplicaState()
		render()
	end

	local function canUpgrade()
		if pendingRequest then
			return false
		end
		local state = latestState
		if type(state) ~= "table" or state.profileReady ~= true or state.isMaxLevel == true then
			return false
		end
		local price = tonumber(state.price) or math.huge
		return currentCurrency >= price
	end

	render = function()
		local state = latestState or {}
		currentCurrency = tonumber(state.currency) or currentCurrency
		local currentLuck = tonumber(state.currentLuckPercent) or 0
		local nextLuck = tonumber(state.nextLuckPercent) or currentLuck
		local price = tonumber(state.price)

		if state.isMaxLevel == true then
			luckLabel.Text = formatPercent(currentLuck) .. " -> Max"
			UiEffects.SetTextStack(upgradeButtonText, "Max")
		else
			luckLabel.Text = formatPercent(currentLuck) .. " -> " .. formatPercent(nextLuck)
			UiEffects.SetTextStack(upgradeButtonText, UiEffects.FormatCurrency(price or 0))
		end

		local canBuy = canUpgrade()
		local showCannotAfford = price ~= nil and state.profileReady == true and state.isMaxLevel ~= true and currentCurrency < price
		updateUpgradeButton(upgradeButton, cannotAffordImage, canBuy, showCannotAfford)
	end

	local function openPanel()
		if isOpen then
			return
		end
		isOpen = true
		transitionToken += 1
		UiEffects.PlayOpen(frame, panelState, silentUiEffects)
	end

	local function closePanel()
		if not isOpen then
			return
		end
		isOpen = false
		transitionToken += 1
		local token = transitionToken
		UiEffects.PlayClose(frame, panelState, function()
			if transitionToken == token and not isOpen then
				frame.Visible = false
			end
		end, silentUiEffects)
	end

	RuntimeGuard.Connect(upgradeButton.Activated, "RollLuckController.UpgradeActivated", function()
		if not canUpgrade() then
			return
		end
		pendingRequest = true
		nextRequestId += 1
		setError(nil)
		render()
		RollLuckUpgradeRequest:FireServer(nextRequestId)
	end)

	RuntimeGuard.Connect(RollLuckUpgradeResult.OnClientEvent, "RollLuckController.UpgradeResult", function(payload)
		if type(payload) ~= "table" then
			return
		end
		pendingRequest = false
		latestState = buildReplicaState()
		if payload.success ~= true then
			setError(codeToMessage(payload.code))
		else
			setError(nil)
		end
		render()
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, function()
		latestState = buildReplicaState()
		render()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.RollLuckLevel, function()
		latestState = buildReplicaState()
		render()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, function()
		latestState = buildReplicaState()
		render()
	end)

	RuntimeGuard.Spawn("RollLuckController.ProximityLoop", function()
		while frame.Parent do
			RuntimeGuard.Run("RollLuckController.ProximityTick", function()
				local near = StationFocus.IsRollActive()
				if near then
					openPanel()
				else
					closePanel()
				end
				if near and (not wasNear or os.clock() - lastStateRequest >= STATE_RETRY_SECONDS) then
					requestState()
				elseif not near then
					pendingRequest = false
					setError(nil)
				end
				wasNear = near
				render()
			end)
			task.wait(PROXIMITY_CHECK_SECONDS)
		end
	end)

	requestState()
	render()
end

return RollLuckController
