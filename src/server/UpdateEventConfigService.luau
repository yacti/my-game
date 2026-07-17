local ConfigService = game:GetService("ConfigService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local UpdateEventConfigService = {}

local EVENT_ID_CONFIG_KEY = "TimerUpdate"
local TIMER_TEXT_CONFIG_KEY = "UpdateTimerText"
local DEFAULT_TIMER_TEXT_MODE = "update"
local VALID_TIMER_TEXT_MODES = {
	party = true,
	update = true,
}
local MAX_INITIAL_ATTEMPTS = 6
local CONFIG_POLL_SECONDS = 180
local RETRY_DELAYS_SECONDS = { 2, 5, 10, 20, 30 }

local started = false
local snapshot = nil
local updateConnection = nil
local loadingSnapshot = false
local refreshingSnapshot = false

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

local function sanitizeTimerTextMode(value)
	if type(value) ~= "string" then
		return nil
	end

	local mode = string.lower(trim(value))
	if VALID_TIMER_TEXT_MODES[mode] then
		return mode
	end
	return nil
end

local function publish(eventId, timerTextMode)
	ReplicatedStorage:SetAttribute(State.UpdateEvent.EventId, sanitizeEventId(eventId))
	ReplicatedStorage:SetAttribute(
		State.UpdateEvent.TimerTextMode,
		sanitizeTimerTextMode(timerTextMode) or DEFAULT_TIMER_TEXT_MODE
	)
end

local function warnInvalidValue(value)
	if value == nil then
		warn("[UpdateEventConfigService] TimerUpdate config is missing or empty")
	elseif type(value) ~= "string" then
		warn("[UpdateEventConfigService] TimerUpdate config must be a string event ID, got " .. typeof(value))
	else
		warn("[UpdateEventConfigService] TimerUpdate config is empty")
	end
end

local function warnInvalidTimerTextMode(value)
	if value == nil then
		warn("[UpdateEventConfigService] UpdateTimerText config is missing; defaulting to 'update'")
	elseif type(value) ~= "string" then
		warn(
			"[UpdateEventConfigService] UpdateTimerText config must be 'update' or 'party', got " .. typeof(value)
		)
	else
		warn(
			"[UpdateEventConfigService] UpdateTimerText config must be 'update' or 'party', got " .. string.format("%q", value)
		)
	end
end

local function publishSnapshotValue()
	if not snapshot then
		publish(nil)
		return false
	end

	local ok, eventIdValue, timerTextValue = pcall(function()
		return snapshot:GetValue(EVENT_ID_CONFIG_KEY), snapshot:GetValue(TIMER_TEXT_CONFIG_KEY)
	end)
	if not ok then
		warn("[UpdateEventConfigService] Failed to read update timer config: " .. tostring(eventIdValue))
		publish(nil, DEFAULT_TIMER_TEXT_MODE)
		return false
	end

	local eventId = sanitizeEventId(eventIdValue)
	if not eventId then
		warnInvalidValue(eventIdValue)
	end

	local timerTextMode = sanitizeTimerTextMode(timerTextValue)
	if not timerTextMode then
		warnInvalidTimerTextMode(timerTextValue)
		timerTextMode = DEFAULT_TIMER_TEXT_MODE
	end

	publish(eventId, timerTextMode)
	if not eventId then
		return false
	end
	return true
end

local function refreshSnapshot()
	if not snapshot then
		return
	end
	if refreshingSnapshot then
		return
	end
	refreshingSnapshot = true

	local ok, err = pcall(function()
		snapshot:Refresh()
	end)
	refreshingSnapshot = false
	if not ok then
		warn("[UpdateEventConfigService] Failed to refresh config snapshot: " .. tostring(err))
		return
	end
	publishSnapshotValue()
end

local function connectSnapshotUpdates()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
	if not snapshot then
		return
	end

	updateConnection = RuntimeGuard.Connect(snapshot.UpdateAvailable, "UpdateEventConfigService.UpdateAvailable", refreshSnapshot)
end

local function loadSnapshotOnce(context)
	if loadingSnapshot then
		return false
	end
	loadingSnapshot = true

	local ok, result = pcall(function()
		return ConfigService:GetConfigAsync()
	end)
	loadingSnapshot = false

	if ok and result then
		snapshot = result
		publishSnapshotValue()
		connectSnapshotUpdates()
		return true
	end

	warn(string.format(
		"[UpdateEventConfigService] Failed to load config snapshot%s: %s",
		context and (" (" .. context .. ")") or "",
		tostring(result)
	))
	return false
end

local function pollConfig()
	while started do
		task.wait(CONFIG_POLL_SECONDS)
		if snapshot then
			refreshSnapshot()
		else
			loadSnapshotOnce("periodic poll")
		end
	end
end

local function loadInitialSnapshot()
	for attempt = 1, MAX_INITIAL_ATTEMPTS do
		if loadSnapshotOnce(string.format("attempt %d/%d", attempt, MAX_INITIAL_ATTEMPTS)) then
			return
		end

		if attempt < MAX_INITIAL_ATTEMPTS then
			task.wait(RETRY_DELAYS_SECONDS[attempt] or RETRY_DELAYS_SECONDS[#RETRY_DELAYS_SECONDS])
		end
	end

	publish(nil, DEFAULT_TIMER_TEXT_MODE)
	warn("[UpdateEventConfigService] TimerUpdate config unavailable after retries; update timer disabled")
end

function UpdateEventConfigService.Start()
	if started then
		return
	end
	started = true

	publish(nil, DEFAULT_TIMER_TEXT_MODE)
	RuntimeGuard.Spawn("UpdateEventConfigService.LoadInitialSnapshot", loadInitialSnapshot)
	RuntimeGuard.Spawn("UpdateEventConfigService.PollConfig", pollConfig)
end

return UpdateEventConfigService
