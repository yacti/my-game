local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local UpdateLogController = {}

local PANEL_NAME = "UpdateLog"
local MENU_GROUP = "update-log"
local LOADING_SCREEN_NAME = "LoadingScreen"

local started = false

local function trim(value)
	return string.match(value, "^%s*(.-)%s*$")
end

local function sanitizeUpdateId(value)
	if type(value) ~= "string" then
		return nil
	end
	local updateId = trim(value)
	if updateId == "" then
		return nil
	end
	return updateId
end

local function findDescendant(root, name, className)
	for _, descendant in ipairs(root and root:GetDescendants() or {}) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

local function waitForLoadingScreenDismissed(playerGui)
	local loadingScreen = playerGui:FindFirstChild(LOADING_SCREEN_NAME)
	if not loadingScreen then
		return
	end

	while playerGui:FindFirstChild(LOADING_SCREEN_NAME) do
		local removed = playerGui.ChildRemoved:Wait()
		if removed.Name == LOADING_SCREEN_NAME then
			return
		end
	end
end

local function isOnboardingComplete(value)
	local state = Onboarding.SanitizeState(value, Onboarding.CompleteState())
	return Onboarding.IsComplete(state.Stage)
end

function UpdateLogController.start()
	if started then
		return
	end
	started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local panel = MenuGui.GetFrame(PANEL_NAME, "UpdateLogController")
	if not panel then
		return
	end

	local updateId = sanitizeUpdateId(panel:GetAttribute(State.UpdateLog.Id))
	if not updateId then
		warn("[UpdateLogController] Missing PlayerGui.Menu.UpdateLog UpdateLogId attribute")
		panel.Visible = false
		return
	end

	local closeButton = findDescendant(panel, "CloseButton", "GuiButton")
	if not closeButton then
		warn("[UpdateLogController] UpdateLog UI is missing CloseButton GuiButton")
		panel.Visible = false
		return
	end

	local closedRemote = Remotes.get(Remotes.Names.UpdateLogClosed)
	UiEffects.BindAllButtons(panel)

	local panelState = UiEffects.PreparePanel(panel)
	local isOpen = false
	local transitionToken = 0
	local autoOpenScheduled = false
	local localAcknowledged = false
	local lastSeenUpdateId = sanitizeUpdateId(PlayerStateStore.Get(PlayerStateStore.Fields.LastSeenUpdateLogId))
	local onboardingComplete = isOnboardingComplete(PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding))
	local joinBackShowcaseActive = type(PlayerStateStore.Get(PlayerStateStore.Fields.JoinBackShowcase)) == "table"
	local offlineProgressPending = player:GetAttribute(State.Player.OfflineProgressPending) == true

	local function shouldShow()
		if localAcknowledged then
			return false
		end
		if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
			return false
		end
		if not onboardingComplete then
			return false
		end
		if joinBackShowcaseActive then
			return false
		end
		if offlineProgressPending then
			return false
		end
		return lastSeenUpdateId ~= updateId
	end

	local function acknowledgeClosed()
		if localAcknowledged then
			return
		end
		localAcknowledged = true
		closedRemote:FireServer(updateId)
	end

	local function showPanel()
		if isOpen then
			return
		end
		isOpen = true
		transitionToken += 1
		UiEffects.PlayOpen(panel, panelState)
	end

	local function hidePanel(switching)
		if not isOpen and not panel.Visible then
			return
		end
		isOpen = false
		transitionToken += 1
		local token = transitionToken
		if not switching then
			acknowledgeClosed()
		end
		if switching then
			panel.Visible = false
			panel.Position = panelState.closedPosition
			panel.Size = panelState.closedSize
			return
		end
		UiEffects.PlayClose(panel, panelState, function()
			if transitionToken == token and not isOpen then
				panel.Visible = false
			end
		end)
	end

	local function maybeAutoOpen()
		if autoOpenScheduled or not shouldShow() then
			return
		end
		autoOpenScheduled = true
		RuntimeGuard.Spawn("UpdateLogController.AutoOpen", function()
			waitForLoadingScreenDismissed(playerGui)
			task.wait(0.5)
			autoOpenScheduled = false
			if shouldShow() then
				MenuGui.OpenPanel(PANEL_NAME)
			end
		end)
	end

	MenuGui.RegisterPanel(PANEL_NAME, {
		group = MENU_GROUP,
		open = showPanel,
		close = hidePanel,
	})

	RuntimeGuard.Connect(closeButton.Activated, "UpdateLogController.CloseActivated", function()
		MenuGui.ClosePanel(PANEL_NAME)
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, maybeAutoOpen)
	PlayerStateStore.Observe(PlayerStateStore.Fields.LastSeenUpdateLogId, function(value)
		lastSeenUpdateId = sanitizeUpdateId(value)
		maybeAutoOpen()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, function(value)
		onboardingComplete = isOnboardingComplete(value)
		maybeAutoOpen()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.JoinBackShowcase, function(value)
		joinBackShowcaseActive = type(value) == "table"
		maybeAutoOpen()
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.OfflineProgressPending), "UpdateLogController.OfflineProgressPendingChanged", function()
		offlineProgressPending = player:GetAttribute(State.Player.OfflineProgressPending) == true
		maybeAutoOpen()
	end)
	maybeAutoOpen()
end

return UpdateLogController
