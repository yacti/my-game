local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local RollLuckController = {}

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

local function formatPercent(value)
	return tostring(math.floor(tonumber(value) or 0)) .. "%"
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

	local frame = hud:WaitForChild("RollLuckFrame", HUD_WAIT_SECONDS)
	if not (frame and frame:IsA("GuiObject")) then
		warn("[RollLuckController] Missing HUD.RollLuckFrame")
		return
	end

	local luckLabel = findDescendant(frame, "LuckLabel", "TextLabel")
	local upgradeButton = findDescendant(frame, "UpgradeButton", "GuiButton")
	local errorLabel = findDescendant(frame, "ErrorLabel", "TextLabel")
	if not (luckLabel and upgradeButton) then
		warn("[RollLuckController] Roll luck UI is missing required named instances")
		return
	end

	local RollLuckStateRequest = Remotes.get(Remotes.Names.RollLuckStateRequest)
	local RollLuckStateUpdated = Remotes.get(Remotes.Names.RollLuckStateUpdated)
	local RollLuckUpgradeRequest = Remotes.get(Remotes.Names.RollLuckUpgradeRequest)
	local RollLuckUpgradeResult = Remotes.get(Remotes.Names.RollLuckUpgradeResult)
	local CurrencyUpdated = Remotes.get(Remotes.Names.CurrencyUpdated)

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

	local function setError(text)
		if errorLabel then
			errorLabel.Text = text or ""
			errorLabel.Visible = text ~= nil and text ~= ""
		end
	end

	local function requestState()
		lastStateRequest = os.clock()
		RollLuckStateRequest:FireServer()
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

	local function render()
		local state = latestState or {}
		currentCurrency = tonumber(state.currency) or currentCurrency
		local currentLuck = tonumber(state.currentLuckPercent) or 0
		local nextLuck = tonumber(state.nextLuckPercent) or currentLuck

		if state.isMaxLevel == true then
			luckLabel.Text = formatPercent(currentLuck) .. " -> Max"
			upgradeButton.Text = "Max"
		else
			luckLabel.Text = formatPercent(currentLuck) .. " -> " .. formatPercent(nextLuck)
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

	upgradeButton.Activated:Connect(function()
		if not canUpgrade() then
			return
		end
		pendingRequest = true
		nextRequestId += 1
		setError(nil)
		render()
		RollLuckUpgradeRequest:FireServer(nextRequestId)
	end)

	RuntimeGuard.Connect(RollLuckStateUpdated.OnClientEvent, "RollLuckController.StateUpdated", function(payload)
		if type(payload) ~= "table" then
			return
		end
		latestState = payload
		setError(nil)
		render()
	end)

	RuntimeGuard.Connect(RollLuckUpgradeResult.OnClientEvent, "RollLuckController.UpgradeResult", function(payload)
		if type(payload) ~= "table" then
			return
		end
		pendingRequest = false
		if type(payload.state) == "table" then
			latestState = payload.state
		end
		if payload.success ~= true then
			setError(codeToMessage(payload.code))
		else
			setError(nil)
		end
		render()
	end)

	RuntimeGuard.Connect(CurrencyUpdated.OnClientEvent, "RollLuckController.CurrencyUpdated", function(amount)
		currentCurrency = tonumber(amount) or currentCurrency
		if latestState then
			latestState.currency = currentCurrency
		end
		render()
	end)

	RuntimeGuard.Spawn("RollLuckController.ProximityLoop", function()
		while frame.Parent do
			RuntimeGuard.Run("RollLuckController.ProximityTick", function()
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

return RollLuckController
