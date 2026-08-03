local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventPromptConfig = require(Shared:WaitForChild("EventPromptConfig"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local FeedPlacement = require(script.Parent:WaitForChild("FeedPlacement"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local EventRsvpPromptController = {}

local ELIGIBILITY_POLL_SECONDS = 0.25
local API_RETRY_DELAYS_SECONDS = { 2, 5 }
local UPDATE_LOG_PANEL_NAME = "UpdateLog"
local LOADING_SCREEN_NAME = "LoadingScreen"

local started = false
local attemptedEventId = nil
local requestedEventId = nil
local requestedRsvpStatus = nil
local promptInProgress = false
local warned = {}
local playerGui = nil
local updateLogFrame = nil

local player = Players.LocalPlayer
local requestRemote = Remotes.get(Remotes.Names.EventRsvpPromptRequest)
local resultRemote = Remotes.get(Remotes.Names.EventRsvpPromptResult)

local function warnOnce(key, message)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[EventRsvpPromptController] " .. message)
end

local function sanitizeId(value)
	if type(value) ~= "string" then
		return nil
	end
	value = string.match(value, "^%s*(.-)%s*$")
	return value ~= "" and value or nil
end

local function isKnownRsvpStatus(value)
	return value == Enum.RsvpStatus.Going
		or value == Enum.RsvpStatus.NotGoing
		or value == Enum.RsvpStatus.None
end

local function isOnboardingComplete()
	local state = Onboarding.SanitizeState(
		PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding),
		Onboarding.CompleteState()
	)
	return Onboarding.IsComplete(state.Stage)
end

local function isUpdateLogBlocking(updateLogFrame)
	if not updateLogFrame then
		return false
	end
	if updateLogFrame.Visible then
		return true
	end

	-- Give the join-time update log priority even during its delayed auto-open.
	-- Once the player closes it, the replicated acknowledgement opens this gate.
	local updateId = sanitizeId(updateLogFrame:GetAttribute(State.UpdateLog.Id))
	local lastSeenId = sanitizeId(PlayerStateStore.Get(PlayerStateStore.Fields.LastSeenUpdateLogId))
	return updateId ~= nil and lastSeenId ~= updateId
end

local function isMenuPanelVisible(playerGui)
	local menu = playerGui:FindFirstChild("Menu")
	if not (menu and menu:IsA("ScreenGui") and menu.Enabled) then
		return false
	end
	for _, child in ipairs(menu:GetChildren()) do
		if child:IsA("GuiObject") and child.Visible then
			return true
		end
	end
	return false
end

local function isEligible(playerGui, updateLogFrame)
	if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
		return false
	end
	if not isOnboardingComplete() then
		return false
	end
	if playerGui:FindFirstChild(LOADING_SCREEN_NAME) then
		return false
	end
	if player:GetAttribute(State.Player.OfflineProgressPending) == true
		or player:GetAttribute(State.Player.AFKRejoinPending) == true
		or player:GetAttribute(State.Player.InventoryRestorePending) == true then
		return false
	end
	if type(PlayerStateStore.Get(PlayerStateStore.Fields.JoinBackShowcase)) == "table" then
		return false
	end

	-- All project menu panels, including the update log and YesNoWarning,
	-- share this one gate with Roblox's own blocking menu and placement prompt.
	if MenuGui.ActivePanel() ~= nil
		or isMenuPanelVisible(playerGui)
		or isUpdateLogBlocking(updateLogFrame) then
		return false
	end
	if GuiService.MenuIsOpen or FeedPlacement.IsPromptBlockingActive() then
		return false
	end
	if player:GetAttribute("EditMode") == true then
		return false
	end
	return true
end

local function readEventAndRsvpStatus(eventId)
	local attempts = #API_RETRY_DELAYS_SECONDS + 1
	local lastError = nil

	for attempt = 1, attempts do
		local eventOk, eventOrError = pcall(function()
			return SocialService:GetExperienceEventAsync(eventId)
		end)
		if eventOk and type(eventOrError) == "table" then
			if eventOrError.HasStarted == true or eventOrError.HasEnded == true then
				return nil, "unavailable"
			end

			local statusOk, statusOrError = pcall(function()
				return SocialService:GetEventRsvpStatusAsync(eventId)
			end)
			if statusOk and isKnownRsvpStatus(statusOrError) then
				return statusOrError, nil
			end
			lastError = statusOrError
		else
			lastError = eventOrError
		end

		local retryDelay = API_RETRY_DELAYS_SECONDS[attempt]
		if retryDelay then
			task.wait(retryDelay)
		end
	end

	warnOnce("validation-" .. eventId, "Could not validate event " .. eventId .. ": " .. tostring(lastError))
	return nil, "api-failed"
end

local function runNativePrompt(eventId, previousStatus)
	if previousStatus == Enum.RsvpStatus.Going then
		requestRemote:FireServer("complete", eventId)
		return
	end

	promptInProgress = true
	local ok, statusOrError = pcall(function()
		return SocialService:PromptRsvpToEventAsync(eventId)
	end)
	promptInProgress = false

	if not ok then
		warnOnce("prompt-" .. eventId, "Native RSVP prompt failed for event " .. eventId .. ": " .. tostring(statusOrError))
		requestRemote:FireServer("failed", eventId)
		return
	end
	if not isKnownRsvpStatus(statusOrError) then
		warnOnce("prompt-status-" .. eventId, "Native RSVP prompt returned an unknown status for event " .. eventId)
	end

	-- PromptRsvpToEventAsync returns only after registration or dismissal.
	requestRemote:FireServer("complete", eventId)
end

local function waitForFinalEligibilityAndPrompt(eventId, rsvpStatus)
	while player:IsDescendantOf(Players) do
		if sanitizeId(PlayerStateStore.Get(PlayerStateStore.Fields.LastPromptedEventId)) == eventId then
			requestRemote:FireServer("failed", eventId)
			return
		end
		if playerGui and isEligible(playerGui, updateLogFrame) then
			runNativePrompt(eventId, rsvpStatus)
			return
		end
		task.wait(ELIGIBILITY_POLL_SECONDS)
	end
end

local function onResult(payload)
	if type(payload) ~= "table" or payload.eventId ~= requestedEventId then
		return
	end

	local eventId = requestedEventId
	local rsvpStatus = requestedRsvpStatus
	requestedEventId = nil
	requestedRsvpStatus = nil

	if payload.code ~= "granted" or promptInProgress then
		return
	end
	RuntimeGuard.Spawn(
		"EventRsvpPromptController.PromptWhenEligible." .. eventId,
		waitForFinalEligibilityAndPrompt,
		eventId,
		rsvpStatus
	)
end

local function waitForEligibilityAndRequest()
	local eventId = EventPromptConfig.GetActiveEventId()
	if not eventId then
		return
	end

	playerGui = player:WaitForChild("PlayerGui")
	updateLogFrame = MenuGui.GetFrame(UPDATE_LOG_PANEL_NAME, "EventRsvpPromptController")
	while player:IsDescendantOf(Players) do
		if sanitizeId(PlayerStateStore.Get(PlayerStateStore.Fields.LastPromptedEventId)) == eventId then
			return
		end
		if isEligible(playerGui, updateLogFrame) then
			break
		end
		task.wait(ELIGIBILITY_POLL_SECONDS)
	end
	if not player:IsDescendantOf(Players) then
		return
	end

	attemptedEventId = eventId
	local rsvpStatus, reason = readEventAndRsvpStatus(eventId)
	if not rsvpStatus then
		if reason == "unavailable" then
			warnOnce("unavailable-" .. eventId, "Configured event " .. eventId .. " is not upcoming")
		end
		return
	end

	requestedEventId = eventId
	requestedRsvpStatus = rsvpStatus
	requestRemote:FireServer("request", eventId)
end

function EventRsvpPromptController.start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(resultRemote.OnClientEvent, "EventRsvpPromptController.Result", onResult)
	if attemptedEventId == nil then
		RuntimeGuard.Spawn("EventRsvpPromptController.WaitForEligibility", waitForEligibilityAndRequest)
	end
end

return EventRsvpPromptController
