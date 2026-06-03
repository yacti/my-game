local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))
local RollDropAreaBalance = require(Shared:WaitForChild("RollDropAreaBalance"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local RollDropAreaController = {}

local PROXIMITY_DISTANCE = RollConfig.Button.InteractionDistance
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

local function getAssignedPlot(player)
	return PlotResolver.ResolveForPlayer(player)
end

local function rollButtonForPlot(plot)
	local rollArea = plot and plot:FindFirstChild("RollArea")
	local buttonFolder = rollArea and rollArea:FindFirstChild("Button")
	local button = buttonFolder and buttonFolder:FindFirstChild("Button")
	return button and button:IsA("BasePart") and button or nil
end

local function rootPart(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function isNearRollButton(player)
	local root = rootPart(player)
	local button = rollButtonForPlot(getAssignedPlot(player))
	return root ~= nil and button ~= nil and (root.Position - button.Position).Magnitude <= PROXIMITY_DISTANCE
end

local function formatPads(count, total)
	return tostring(math.max(math.floor(tonumber(count) or 0), 0))
		.. "/"
		.. tostring(math.max(math.floor(tonumber(total) or 0), 0))
		.. " Pads"
end

local function codeToMessage(code)
	if code == "insufficient-currency" then
		return "Not enough currency."
	end
	if code == "too-far" then
		return "Move closer to the roll button."
	end
	if code == "max-level" then
		return "Drop areas are already maxed."
	end
	if code == "busy" or code == "rate-limited" then
		return "Try again in a moment."
	end
	if code == "no-profile" then
		return "Save data is still loading."
	end
	return "Could not upgrade drop areas."
end

function RollDropAreaController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild("HUD", HUD_WAIT_SECONDS)
	if not hud then
		warn("[RollDropAreaController] Missing PlayerGui.HUD")
		return
	end

	local frame = hud:WaitForChild("RollDropAreaFrame", HUD_WAIT_SECONDS)
	if not (frame and frame:IsA("GuiObject")) then
		warn("[RollDropAreaController] Missing HUD.RollDropAreaFrame")
		return
	end

	local dropAreaLabel = findDescendant(frame, "DropAreaLabel", "TextLabel")
	local upgradeButton = findDescendant(frame, "UpgradeButton", "GuiButton")
	local errorLabel = findDescendant(frame, "ErrorLabel", "TextLabel")
	if not (dropAreaLabel and upgradeButton) then
		warn("[RollDropAreaController] Roll drop area UI is missing required named instances")
		return
	end

	local RollDropAreaUpgradeRequest = Remotes.get(Remotes.Names.RollDropAreaUpgradeRequest)
	local RollDropAreaUpgradeResult = Remotes.get(Remotes.Names.RollDropAreaUpgradeResult)

	UiEffects.BindButton(upgradeButton)
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
		local level = RollDropAreaBalance.LevelFor(PlayerStateStore.Get(PlayerStateStore.Fields.RollDropAreaLevel))
		local currency = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Currency)) or currentCurrency
		local state = RollDropAreaBalance.ToState(level, currency)
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
		local unlockedCount = tonumber(state.unlockedPadCount) or 1
		local nextPadCount = tonumber(state.nextPadCount) or unlockedCount
		local totalPads = tonumber(state.totalPads) or unlockedCount

		if state.isMaxLevel == true then
			dropAreaLabel.Text = formatPads(unlockedCount, totalPads) .. " -> Max"
			upgradeButton.Text = "Max"
		else
			dropAreaLabel.Text = formatPads(unlockedCount, totalPads) .. " -> " .. formatPads(nextPadCount, totalPads)
			upgradeButton.Text = UiEffects.FormatCurrency(state.price or 0)
		end

		UiEffects.SetButtonEnabled(upgradeButton, canUpgrade())
	end

	local function openPanel()
		if isOpen then
			return
		end
		isOpen = true
		transitionToken += 1
		UiEffects.PlayOpen(frame, panelState)
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
		end)
	end

	RuntimeGuard.Connect(upgradeButton.Activated, "RollDropAreaController.UpgradeActivated", function()
		if not canUpgrade() then
			return
		end
		pendingRequest = true
		nextRequestId += 1
		setError(nil)
		render()
		RollDropAreaUpgradeRequest:FireServer(nextRequestId)
	end)

	RuntimeGuard.Connect(RollDropAreaUpgradeResult.OnClientEvent, "RollDropAreaController.UpgradeResult", function(payload)
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
	PlayerStateStore.Observe(PlayerStateStore.Fields.RollDropAreaLevel, function()
		latestState = buildReplicaState()
		render()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, function()
		latestState = buildReplicaState()
		render()
	end)

	RuntimeGuard.Spawn("RollDropAreaController.ProximityLoop", function()
		while frame.Parent do
			RuntimeGuard.Run("RollDropAreaController.ProximityTick", function()
				local near = isNearRollButton(player)
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

return RollDropAreaController
