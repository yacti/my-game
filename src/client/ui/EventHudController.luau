local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local EventHudController = {}

local HUD_NAME = "HUD"
local TOP_BAR_NAME = "TopBar"
local CURRENT_EVENT_NAME = "CurrentEvent"
local EVENT_TIMER_NAME = "EventTimer"
local EVENT_TIMER_LABEL_NAME = "Timer"
local EVENT_TIMER_TITLE_NAME = "Title"
local CURRENT_EVENT_TIMER_NAME = "CurrentEventTimer"
local SUNNY_FRAME_NAME = "Sunny"
local ACTIVE_TIMER_TEXT = "NOW"
local IDLE_TIMER_TITLE = "Next event:"
local ACTIVE_TIMER_TITLE = "Current event"
local EVENT_CYCLE_SECONDS = 3
local REFRESH_SECONDS = 0.25
local RUNTIME_WAIT_SECONDS = 15

local EVENT_TIMER_NAMES = {
	[GameEvents.Ids.Windy] = "Wind",
	[GameEvents.Ids.Stormy] = "Storm",
	[GameEvents.Ids.Tornado] = "Tornado",
	[GameEvents.Ids.Tsunami] = "Tsunami",
	[GameEvents.Ids.Earthquake] = "Earthquake",
	[GameEvents.Ids.Alien] = "Alien",
}

local player = Players.LocalPlayer
local started = false
local warned = {}
local runtimeFolder = nil
local activeFolder = nil
local runtimeWarnAt = nil

local function warnOnce(key, message)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[EventHudController] " .. message)
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function child(parent, name, className)
	local instance = parent and parent:FindFirstChild(name)
	if instance and instance:IsA(className) then
		return instance
	end
	return nil
end

local function resolveHud()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local hud = playerGui and playerGui:FindFirstChild(HUD_NAME)
	if not hud then
		warnOnce("hud", "Missing PlayerGui.HUD; event TopBar skipped")
		return nil
	end
	local topBar = child(hud, TOP_BAR_NAME, "GuiObject")
	local currentEvent = child(topBar, CURRENT_EVENT_NAME, "GuiObject")
	local eventTimer = child(topBar, EVENT_TIMER_NAME, "GuiObject")
	local timerLabel = child(eventTimer, EVENT_TIMER_LABEL_NAME, "TextLabel")
	local titleLabel = child(eventTimer, EVENT_TIMER_TITLE_NAME, "TextLabel")
	local currentEventTimer = child(topBar, CURRENT_EVENT_TIMER_NAME, "TextLabel")
	if not (topBar and currentEvent and eventTimer and timerLabel and titleLabel and currentEventTimer) then
		warnOnce("shape", "HUD.TopBar is missing CurrentEvent, EventTimer.Timer, EventTimer.Title, or CurrentEventTimer")
		return nil
	end
	return {
		topBar = topBar,
		currentEvent = currentEvent,
		timerLabel = timerLabel,
		titleLabel = titleLabel,
		currentEventTimer = currentEventTimer,
	}
end

local function resolveRuntime()
	if activeFolder and activeFolder.Parent then
		return runtimeFolder, activeFolder
	end

	runtimeFolder = ReplicatedStorage:FindFirstChild(GameEvents.RuntimeFolderName)
	activeFolder = runtimeFolder and runtimeFolder:FindFirstChild(GameEvents.ActiveFolderName)
	if not (runtimeFolder and activeFolder) then
		runtimeWarnAt = runtimeWarnAt or (os.clock() + RUNTIME_WAIT_SECONDS)
		if os.clock() >= runtimeWarnAt then
			warnOnce("runtime", "Missing ReplicatedStorage." .. GameEvents.RuntimeFolderName .. "." .. GameEvents.ActiveFolderName .. "; event TopBar disabled")
		end
	else
		runtimeWarnAt = nil
	end
	return runtimeFolder, activeFolder
end

local function activeRecords()
	local _, folder = resolveRuntime()
	if not folder then
		return {}
	end

	local now = serverNow()
	local records = {}
	for _, childInstance in ipairs(folder:GetChildren()) do
		local startsAt = tonumber(childInstance:GetAttribute(State.GameEvent.StartsAt))
		local endsAt = tonumber(childInstance:GetAttribute(State.GameEvent.EndsAt))
		if startsAt and endsAt and now >= startsAt and now < endsAt then
			records[#records + 1] = {
				eventId = childInstance:GetAttribute(State.GameEvent.EventId),
				displayFrame = childInstance:GetAttribute(State.GameEvent.DisplayFrame),
				displayPriority = tonumber(childInstance:GetAttribute(State.GameEvent.DisplayPriority)) or 0,
				startsAt = startsAt,
				endsAt = endsAt,
			}
		end
	end

	table.sort(records, function(left, right)
		if left.displayPriority ~= right.displayPriority then
			return left.displayPriority > right.displayPriority
		end
		return tostring(left.eventId) < tostring(right.eventId)
	end)
	return records
end

local function setCurrentEventFrame(container, frameName)
	local found = false
	for _, childInstance in ipairs(container:GetChildren()) do
		if childInstance:IsA("GuiObject") then
			local visible = childInstance.Name == frameName
			childInstance.Visible = visible
			found = found or visible
		end
	end
	if not found then
		warnOnce("frame-" .. tostring(frameName), "HUD.TopBar.CurrentEvent is missing " .. tostring(frameName) .. " GuiObject")
	end
end

local function longestRemaining(records)
	local now = serverNow()
	local longest = 0
	for _, record in ipairs(records) do
		longest = math.max(longest, record.endsAt - now)
	end
	return longest
end

local function displayNameFor(record)
	local eventId = record and record.eventId
	return EVENT_TIMER_NAMES[eventId] or tostring((record and (record.displayFrame or eventId)) or "Event")
end

local function render()
	local hud = resolveHud()
	local runtime, folder = resolveRuntime()
	if not (hud and runtime and folder) then
		return
	end

	local records = activeRecords()
	if #records == 0 then
		setCurrentEventFrame(hud.currentEvent, SUNNY_FRAME_NAME)
		hud.titleLabel.Text = IDLE_TIMER_TITLE
		local nextStartsAt = tonumber(runtime:GetAttribute(State.GameEvent.NextWeatherStartsAt))
		hud.timerLabel.Text = GameEvents.FormatDuration((nextStartsAt or serverNow()) - serverNow())
		hud.currentEventTimer.Visible = false
		return
	end

	local cycleIndex = (math.floor(os.clock() / EVENT_CYCLE_SECONDS) % #records) + 1
	local record = records[cycleIndex]
	setCurrentEventFrame(hud.currentEvent, record.displayFrame or record.eventId)
	hud.titleLabel.Text = ACTIVE_TIMER_TITLE
	hud.timerLabel.Text = ACTIVE_TIMER_TEXT
	hud.currentEventTimer.Visible = true
	if #records == 1 then
		hud.currentEventTimer.Text = displayNameFor(record) .. " ends in " .. GameEvents.FormatDuration(longestRemaining(records))
	else
		hud.currentEventTimer.Text = "Events end in " .. GameEvents.FormatDuration(longestRemaining(records))
	end
end

function EventHudController.start()
	if started then
		return
	end
	started = true

	local elapsed = REFRESH_SECONDS
	RuntimeGuard.Connect(RunService.Heartbeat, "EventHudController.Render", function(dt)
		elapsed += dt
		if elapsed < REFRESH_SECONDS then
			return
		end
		elapsed = 0
		render()
	end)
end

return EventHudController
