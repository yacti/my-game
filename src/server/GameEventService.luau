local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local PlotWindService = require(Server:WaitForChild("PlotWindService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local GameEventService = {}

local UPDATE_SECONDS = 0.5

local runtimeFolder = nil
local activeFolder = nil
local started = false
local revision = 0
local lastSignature = nil
local activeWindInstanceId = nil
local notifiedInstanceIds = {}

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function logEvent(action, recordOrInstanceId)
	if type(recordOrInstanceId) == "table" then
		print(string.format(
			"[GameEventService] %s %s.%s (%s -> %s)",
			action,
			tostring(recordOrInstanceId.layer),
			tostring(recordOrInstanceId.eventId),
			tostring(math.floor(tonumber(recordOrInstanceId.startsAt) or 0)),
			tostring(math.floor(tonumber(recordOrInstanceId.endsAt) or 0))
		))
		return
	end
	print(string.format("[GameEventService] %s %s", action, tostring(recordOrInstanceId)))
end

local function getRuntimeFolder()
	if not (runtimeFolder and runtimeFolder.Parent) then
		runtimeFolder = ReplicatedStorage:FindFirstChild(GameEvents.RuntimeFolderName)
	end
	if not runtimeFolder then
		runtimeFolder = Instance.new("Folder")
		runtimeFolder.Name = GameEvents.RuntimeFolderName
		runtimeFolder.Parent = ReplicatedStorage
	end

	if not (activeFolder and activeFolder.Parent == runtimeFolder) then
		activeFolder = runtimeFolder:FindFirstChild(GameEvents.ActiveFolderName)
	end
	if not activeFolder then
		activeFolder = Instance.new("Folder")
		activeFolder.Name = GameEvents.ActiveFolderName
		activeFolder.Parent = runtimeFolder
	end

	return runtimeFolder
end

local function getActiveFolder()
	getRuntimeFolder()
	return activeFolder
end

local function sortedActiveRecords(records)
	local copy = {}
	for index, record in ipairs(records or {}) do
		if index > GameEvents.MaxReplicatedActiveEvents then
			break
		end
		copy[#copy + 1] = record
	end
	table.sort(copy, function(left, right)
		local leftDisplay = tonumber(left.displayPriority) or 0
		local rightDisplay = tonumber(right.displayPriority) or 0
		if leftDisplay ~= rightDisplay then
			return leftDisplay > rightDisplay
		end
		if left.endsAt ~= right.endsAt then
			return left.endsAt < right.endsAt
		end
		return tostring(left.eventId) < tostring(right.eventId)
	end)
	return copy
end

local function signatureFor(records, nextWeather)
	local parts = {}
	for _, record in ipairs(sortedActiveRecords(records)) do
		parts[#parts + 1] = table.concat({
			tostring(record.instanceId),
			tostring(record.eventId),
			tostring(record.layer),
			tostring(record.startsAt),
			tostring(record.endsAt),
			tostring(record.displayPriority),
		}, ":")
	end
	if nextWeather then
		parts[#parts + 1] = "next:" .. tostring(nextWeather.eventId) .. ":" .. tostring(nextWeather.startsAt)
	end
	return table.concat(parts, "|")
end

local function clearActiveFolder(folder)
	for _, child in ipairs(folder:GetChildren()) do
		child:Destroy()
	end
end

local function writeRecord(folder, record)
	local child = Instance.new("Folder")
	child.Name = tostring(record.instanceId)
	child:SetAttribute(State.GameEvent.EventId, record.eventId)
	child:SetAttribute(State.GameEvent.Layer, record.layer)
	child:SetAttribute(State.GameEvent.Source, record.source)
	child:SetAttribute(State.GameEvent.StartsAt, record.startsAt)
	child:SetAttribute(State.GameEvent.EndsAt, record.endsAt)
	child:SetAttribute(State.GameEvent.Priority, record.priority)
	child:SetAttribute(State.GameEvent.DisplayPriority, record.displayPriority)
	child:SetAttribute(State.GameEvent.DisplayFrame, record.displayFrame)
	child.Parent = folder
end

local function publishSnapshot(records, nextWeather)
	local folder = getRuntimeFolder()
	local active = getActiveFolder()
	clearActiveFolder(active)
	for _, record in ipairs(sortedActiveRecords(records)) do
		writeRecord(active, record)
	end

	if nextWeather then
		folder:SetAttribute(State.GameEvent.NextWeatherEventId, nextWeather.eventId)
		folder:SetAttribute(State.GameEvent.NextWeatherStartsAt, nextWeather.startsAt)
	else
		folder:SetAttribute(State.GameEvent.NextWeatherEventId, nil)
		folder:SetAttribute(State.GameEvent.NextWeatherStartsAt, nil)
	end

	revision += 1
	folder:SetAttribute(State.GameEvent.Revision, revision)
end

local function activeWindRecord(records)
	for _, record in ipairs(records or {}) do
		if record.eventId == GameEvents.Ids.Windy then
			return record
		end
	end
	return nil
end

local function updateHandlers(records)
	local windRecord = activeWindRecord(records)
	if windRecord then
		if activeWindInstanceId ~= windRecord.instanceId then
			if activeWindInstanceId then
				logEvent("Stopping", activeWindInstanceId)
				RuntimeGuard.Run("GameEventService.StopWind", PlotWindService.StopWind, activeWindInstanceId)
			end
			activeWindInstanceId = windRecord.instanceId
			logEvent("Starting", windRecord)
			RuntimeGuard.Run("GameEventService.StartWind", PlotWindService.StartWind, windRecord)
		end
	elseif activeWindInstanceId then
		logEvent("Stopping", activeWindInstanceId)
		RuntimeGuard.Run("GameEventService.StopWind", PlotWindService.StopWind, activeWindInstanceId)
		activeWindInstanceId = nil
	end
end

local function updatePreNotice(now, nextWeather)
	for instanceId, startsAt in pairs(notifiedInstanceIds) do
		if tonumber(startsAt) and startsAt < now - 3600 then
			notifiedInstanceIds[instanceId] = nil
		end
	end

	if not nextWeather or nextWeather.eventId ~= GameEvents.Ids.Windy then
		return
	end
	local config = GameEvents.GetEvent(GameEvents.Ids.Windy) or {}
	local preNoticeSeconds = math.max(tonumber(config.preNoticeSeconds) or 0, 0)
	if preNoticeSeconds <= 0 then
		return
	end

	local untilStart = nextWeather.startsAt - now
	if untilStart <= 0 or untilStart > preNoticeSeconds then
		return
	end
	if notifiedInstanceIds[nextWeather.instanceId] then
		return
	end
	notifiedInstanceIds[nextWeather.instanceId] = nextWeather.startsAt
	RuntimeGuard.Run("GameEventService.NotifyWindStarting", PlotWindService.NotifyWindStarting)
end

local function update()
	local now = serverNow()
	local snapshot = GameEvents.WeatherSnapshot(now)
	local records = snapshot.activeRecords or {}
	local nextWeather = snapshot.nextWeather

	local signature = signatureFor(records, nextWeather)
	if signature ~= lastSignature then
		lastSignature = signature
		publishSnapshot(records, nextWeather)
	end

	updateHandlers(records)
	updatePreNotice(now, nextWeather)
end

function GameEventService.Start()
	if started then
		return
	end
	started = true

	getRuntimeFolder()
	update()
	RuntimeGuard.Spawn("GameEventService.Loop", function()
		while true do
			task.wait(UPDATE_SECONDS)
			update()
		end
	end)
end

return GameEventService
