local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local UpdateTimerController = {}

local HUD_NAME = "HUD"
local FRAME_NAME = "UpdateTimer"
local HOLDER_NAME = "Holder"
local TAP_NAME = "Tap"
local NOTIFY_BUTTON_NAME = "NotifyButton"
local TIMER_LABEL_NAME = "UpdateTimer"
local HUD_WAIT_SECONDS = 10
local TIMER_UPDATE_SECONDS = 0.5
local EVENT_DETAILS_REFRESH_SECONDS = 180
local DEFAULT_TIMER_TEXT_MODE = "update"
local TIMER_TEXT_BY_MODE = {
	party = "Admin party in:",
	update = "Update in:",
}

local player = Players.LocalPlayer
local warned = {}

local frame = nil
local tapButton = nil
local notifyButton = nil
local timerLabel = nil

local currentEventId = nil
local currentStartAt = nil
local currentRsvpStatus = nil
local promptBusy = false
local rsvpStatusFailed = false
local rsvpRetryAvailable = false
local requestGeneration = 0
local heartbeatConnection = nil

local function warnOnce(key, message)
	if warned[key] then
		return
	end
	warn(message)
	warned[key] = true
end

local function trim(value)
	return string.match(value, "^%s*(.-)%s*$")
end

local function sanitizeEventId(value)
	if type(value) ~= "string" then
		return nil
	end

	local eventId = trim(value)
	if eventId == "" then
		return nil
	end
	return eventId
end

local function child(parent, name, className)
	local found = parent and parent:FindFirstChild(name)
	if found and found:IsA(className) then
		return found
	end
	return nil
end

local function setTapEnabled(enabled)
	if not tapButton then
		return
	end
	tapButton.Active = enabled
	tapButton.Selectable = enabled
end

local function setPromptVisible(visible)
	if notifyButton then
		notifyButton.Visible = visible
	end
	setTapEnabled(visible)
end

local function now()
	return Workspace:GetServerTimeNow()
end

local function intField(value, minimum, maximum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	value = math.floor(value)
	if minimum and value < minimum then
		return nil
	end
	if maximum and value > maximum then
		return nil
	end
	return value
end

local function eventTimeToUnixSeconds(value)
	if type(value) ~= "table" then
		return nil
	end

	local year = intField(value.Year, 1)
	local month = intField(value.Month, 1, 12)
	local day = intField(value.Day, 1, 31)
	if not (year and month and day) then
		return nil
	end

	local hour = intField(value.Hour or 0, 0, 23)
	local minute = intField(value.Minute or 0, 0, 59)
	local second = intField(value.Second or 0, 0, 59)
	local millisecond = intField(value.Millisecond or 0, 0, 999)
	if not (hour and minute and second and millisecond) then
		return nil
	end

	local ok, dateTime = pcall(function()
		return DateTime.fromUniversalTime(year, month, day, hour, minute, second, millisecond)
	end)
	if not ok or typeof(dateTime) ~= "DateTime" then
		return nil
	end
	return dateTime.UnixTimestampMillis / 1000
end

local function rsvpStatusKnown(value)
	return value == Enum.RsvpStatus.Going
		or value == Enum.RsvpStatus.NotGoing
		or value == Enum.RsvpStatus.None
end

local function isPromptableStatus(value)
	return value == Enum.RsvpStatus.NotGoing or value == Enum.RsvpStatus.None
end

local function formatRemaining(seconds)
	seconds = math.max(math.ceil(tonumber(seconds) or 0), 0)

	local days = math.floor(seconds / 86400)
	if days > 0 then
		local hours = math.floor((seconds % 86400) / 3600)
		return string.format("%dd %dh", days, hours)
	end

	local hours = math.floor(seconds / 3600)
	if hours > 0 then
		local minutes = math.floor((seconds % 3600) / 60)
		return string.format("%dh %dm", hours, minutes)
	end

	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60
	return string.format("%dm %ds", minutes, remainder)
end

local function timerTextPrefix()
	local mode = ReplicatedStorage:GetAttribute(State.UpdateEvent.TimerTextMode)
	if type(mode) == "string" then
		mode = string.lower(trim(mode))
	end
	return TIMER_TEXT_BY_MODE[mode] or TIMER_TEXT_BY_MODE[DEFAULT_TIMER_TEXT_MODE]
end

local function clearLoadedEvent()
	currentStartAt = nil
	currentRsvpStatus = nil
	promptBusy = false
	rsvpStatusFailed = false
	rsvpRetryAvailable = false
	if frame then
		frame.Visible = false
	end
	setPromptVisible(false)
end

local function isCurrentRequest(eventId, generation)
	return currentEventId == eventId and requestGeneration == generation and frame ~= nil
end

local function render()
	if not (frame and timerLabel and currentStartAt) then
		if frame then
			frame.Visible = false
		end
		setPromptVisible(false)
		return
	end

	local remaining = currentStartAt - now()
	if remaining <= 0 then
		frame.Visible = false
		setPromptVisible(false)
		return
	end

	frame.Visible = true
	timerLabel.Text = timerTextPrefix() .. " " .. formatRemaining(remaining)

	local promptVisible = not promptBusy
		and (
			isPromptableStatus(currentRsvpStatus)
			or (rsvpStatusFailed and rsvpRetryAvailable)
		)
	setPromptVisible(promptVisible)
end

local function readRsvpStatus(eventId)
	local ok, status = pcall(function()
		return SocialService:GetEventRsvpStatusAsync(eventId)
	end)
	return ok, status
end

local function applyRsvpStatus(eventId, ok, status, allowRetry)
	allowRetry = allowRetry ~= false

	if ok and rsvpStatusKnown(status) then
		currentRsvpStatus = status
		rsvpStatusFailed = false
		rsvpRetryAvailable = false
	else
		currentRsvpStatus = nil
		rsvpStatusFailed = true
		rsvpRetryAvailable = allowRetry
		warnOnce(
			"rsvp-status-" .. tostring(eventId),
			"[UpdateTimerController] Failed to read RSVP status for update event " .. tostring(eventId) .. ": " .. tostring(status)
		)
	end
	render()
end

local function fetchRsvpStatus(eventId, generation, allowRetry)
	local ok, status = readRsvpStatus(eventId)
	if not isCurrentRequest(eventId, generation) then
		return
	end

	applyRsvpStatus(eventId, ok, status, allowRetry)
end

local function loadEvent(eventId, preserveExisting)
	requestGeneration += 1
	currentEventId = eventId

	if not preserveExisting then
		clearLoadedEvent()
	end

	if not eventId then
		clearLoadedEvent()
		return
	end

	local generation = requestGeneration
	RuntimeGuard.Spawn("UpdateTimerController.FetchEvent." .. tostring(eventId), function()
		local ok, event = pcall(function()
			return SocialService:GetExperienceEventAsync(eventId)
		end)
		if not isCurrentRequest(eventId, generation) then
			return
		end

		if not ok or type(event) ~= "table" then
			warnOnce(
				"event-fetch-" .. tostring(eventId),
				"[UpdateTimerController] Failed to fetch update event " .. tostring(eventId) .. ": " .. tostring(event)
			)
			if not preserveExisting then
				clearLoadedEvent()
			end
			return
		end

		local startAt = eventTimeToUnixSeconds(event.StartTime)
		if not startAt then
			warnOnce(
				"event-start-" .. tostring(eventId),
				"[UpdateTimerController] Update event " .. tostring(eventId) .. " has invalid StartTime"
			)
			if not preserveExisting then
				clearLoadedEvent()
			end
			return
		end

		if event.HasEnded == true or startAt <= now() then
			clearLoadedEvent()
			return
		end

		currentStartAt = startAt
		currentRsvpStatus = nil
		rsvpStatusFailed = false
		rsvpRetryAvailable = false
		render()
		fetchRsvpStatus(eventId, generation, true)
	end)
end

local function onEventIdChanged()
	loadEvent(sanitizeEventId(ReplicatedStorage:GetAttribute(State.UpdateEvent.EventId)))
end

local function bindHud()
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild(HUD_NAME, HUD_WAIT_SECONDS)
	if not (hud and hud:IsA("ScreenGui")) then
		warnOnce("missing-hud", "[UpdateTimerController] Missing PlayerGui.HUD")
		return nil
	end

	frame = child(hud, FRAME_NAME, "GuiObject")
	local holder = child(frame, HOLDER_NAME, "GuiObject")
	tapButton = child(frame, TAP_NAME, "GuiButton")
	notifyButton = child(holder, NOTIFY_BUTTON_NAME, "GuiButton")
	timerLabel = child(holder, TIMER_LABEL_NAME, "TextLabel")

	if not (frame and holder and tapButton and notifyButton and timerLabel) then
		warnOnce("missing-ui", "[UpdateTimerController] HUD.UpdateTimer is missing Tap, Holder.NotifyButton, or Holder.UpdateTimer")
		if frame then
			frame.Visible = false
		end
		return nil
	end

	frame.Visible = false
	setPromptVisible(false)
	tapButton.AutoButtonColor = false
	UiEffects.BindButton(tapButton)

	return hud
end

local function promptRsvp()
	if promptBusy or not (currentEventId and currentStartAt) then
		return
	end
	if currentStartAt <= now() then
		render()
		return
	end

	local eventId = currentEventId
	local generation = requestGeneration

	if rsvpStatusFailed and rsvpRetryAvailable then
		rsvpRetryAvailable = false
		promptBusy = true
		render()

		RuntimeGuard.Spawn("UpdateTimerController.RetryRsvpStatus." .. tostring(eventId), function()
			local ok, status = readRsvpStatus(eventId)
			if not isCurrentRequest(eventId, generation) then
				return
			end

			promptBusy = false
			applyRsvpStatus(eventId, ok, status, false)
			if isPromptableStatus(currentRsvpStatus) then
				promptRsvp()
			end
		end)
		return
	end

	if not isPromptableStatus(currentRsvpStatus) then
		return
	end

	promptBusy = true
	render()

	RuntimeGuard.Spawn("UpdateTimerController.PromptRsvp." .. tostring(eventId), function()
		local ok, status = pcall(function()
			return SocialService:PromptRsvpToEventAsync(eventId)
		end)
		if not isCurrentRequest(eventId, generation) then
			return
		end

		promptBusy = false
		if ok and rsvpStatusKnown(status) then
			currentRsvpStatus = status
			rsvpStatusFailed = false
		else
			warnOnce(
				"prompt-" .. tostring(eventId),
				"[UpdateTimerController] Failed to prompt RSVP for update event " .. tostring(eventId) .. ": " .. tostring(status)
			)
		end
		render()
	end)
end

function UpdateTimerController.start()
	local hud = bindHud()
	if not hud then
		return
	end

	RuntimeGuard.Connect(tapButton.Activated, "UpdateTimerController.TapActivated", promptRsvp)
	RuntimeGuard.Connect(
		ReplicatedStorage:GetAttributeChangedSignal(State.UpdateEvent.EventId),
		"UpdateTimerController.EventIdChanged",
		onEventIdChanged
	)
	RuntimeGuard.Connect(
		ReplicatedStorage:GetAttributeChangedSignal(State.UpdateEvent.TimerTextMode),
		"UpdateTimerController.TimerTextModeChanged",
		render
	)

	local elapsed = 0
	local eventRefreshElapsed = 0
	heartbeatConnection = RuntimeGuard.Connect(RunService.Heartbeat, "UpdateTimerController.Heartbeat", function(deltaTime)
		elapsed += deltaTime
		if elapsed < TIMER_UPDATE_SECONDS then
			eventRefreshElapsed += deltaTime
			if eventRefreshElapsed >= EVENT_DETAILS_REFRESH_SECONDS and currentEventId and not promptBusy then
				eventRefreshElapsed = 0
				loadEvent(currentEventId, true)
			end
			return
		end
		elapsed = 0
		eventRefreshElapsed += deltaTime
		render()
		if eventRefreshElapsed >= EVENT_DETAILS_REFRESH_SECONDS and currentEventId and not promptBusy then
			eventRefreshElapsed = 0
			loadEvent(currentEventId, true)
		end
	end)

	RuntimeGuard.Connect(hud.Destroying, "UpdateTimerController.HudDestroying", function()
		requestGeneration += 1
		if heartbeatConnection then
			heartbeatConnection:Disconnect()
			heartbeatConnection = nil
		end
	end)

	onEventIdChanged()
end

return UpdateTimerController
