local ConfigService = game:GetService("ConfigService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local UpdateEventConfigService = {}

local CONFIG_KEY = "TimerUpdate"
local MAX_INITIAL_ATTEMPTS = 6
local RETRY_DELAYS_SECONDS = { 2, 5, 10, 20, 30 }

local started = false
local snapshot = nil
local updateConnection = nil

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

local function publish(eventId)
	ReplicatedStorage:SetAttribute(State.UpdateEvent.EventId, sanitizeEventId(eventId))
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

local function publishSnapshotValue()
	if not snapshot then
		publish(nil)
		return false
	end

	local ok, value = pcall(function()
		return snapshot:GetValue(CONFIG_KEY)
	end)
	if not ok then
		warn("[UpdateEventConfigService] Failed to read TimerUpdate config: " .. tostring(value))
		publish(nil)
		return false
	end

	local eventId = sanitizeEventId(value)
	if not eventId then
		warnInvalidValue(value)
		publish(nil)
		return false
	end

	publish(eventId)
	return true
end

local function refreshSnapshot()
	if not snapshot then
		return
	end

	local ok, err = pcall(function()
		snapshot:Refresh()
	end)
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

local function loadInitialSnapshot()
	for attempt = 1, MAX_INITIAL_ATTEMPTS do
		local ok, result = pcall(function()
			return ConfigService:GetConfigAsync()
		end)
		if ok and result then
			snapshot = result
			publishSnapshotValue()
			connectSnapshotUpdates()
			return
		end

		warn(string.format(
			"[UpdateEventConfigService] Failed to load config snapshot (attempt %d/%d): %s",
			attempt,
			MAX_INITIAL_ATTEMPTS,
			tostring(result)
		))

		if attempt < MAX_INITIAL_ATTEMPTS then
			task.wait(RETRY_DELAYS_SECONDS[attempt] or RETRY_DELAYS_SECONDS[#RETRY_DELAYS_SECONDS])
		end
	end

	publish(nil)
	warn("[UpdateEventConfigService] TimerUpdate config unavailable after retries; update timer disabled")
end

function UpdateEventConfigService.Start()
	if started then
		return
	end
	started = true

	publish(nil)
	RuntimeGuard.Spawn("UpdateEventConfigService.LoadInitialSnapshot", loadInitialSnapshot)
end

return UpdateEventConfigService
