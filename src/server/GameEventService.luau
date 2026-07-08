local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local PlotAlienEventService = require(Server:WaitForChild("PlotAlienEventService"))
local PlotThunderstormService = require(Server:WaitForChild("PlotThunderstormService"))
local PlotTornadoService = require(Server:WaitForChild("PlotTornadoService"))
local PlotTsunamiService = require(Server:WaitForChild("PlotTsunamiService"))
local PlotWindService = require(Server:WaitForChild("PlotWindService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local GameEventService = {}

local UPDATE_SECONDS = 0.5
-- Completed instances stay suppressed until record endsAt plus this buffer, so
-- long-lived external/global records cannot restart locally after early completion.
local SUPPRESS_AFTER_ENDS_SECONDS = 60
local SUPPRESS_FALLBACK_SECONDS = 3600

local runtimeFolder = nil
local activeFolder = nil
local started = false
local revision = 0
local lastSignature = nil
local activeInstanceIdsByEventId = {}
local activeRecordsByEventId = {}
local completedInstanceIds = {}
local completionBlocksByLayer = {}
local notifiedInstanceIds = {}
local serviceConfig = {}
local manualRecordsByInstanceId = {}
local manualSequence = 0
local externalRecordsBySource = {}

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function finiteNumber(value)
	local numberValue = tonumber(value)
	if numberValue == nil or numberValue ~= numberValue or math.abs(numberValue) == math.huge then
		return nil
	end
	return numberValue
end

local function optionNumber(options, name, fallback)
	if options[name] == nil then
		return fallback
	end
	return finiteNumber(options[name])
end

local function copyRecord(record)
	if type(record) ~= "table" then
		return nil
	end
	local copy = {}
	for key, value in pairs(record) do
		copy[key] = value
	end
	return copy
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

local function generatedManualInstanceId(eventId, layer, startsAt)
	repeat
		manualSequence += 1
		local instanceId = string.format(
			"Manual_%s_%s_%d_%d",
			tostring(layer),
			tostring(eventId),
			math.floor(tonumber(startsAt) or serverNow()),
			manualSequence
		)
		if not manualRecordsByInstanceId[instanceId] then
			return instanceId
		end
	until false
	return nil
end

local function pruneManualRecords(now)
	for instanceId, record in pairs(manualRecordsByInstanceId) do
		local endsAt = tonumber(record.endsAt) or 0
		if completedInstanceIds[instanceId] or endsAt <= now then
			manualRecordsByInstanceId[instanceId] = nil
		end
	end
end

local function activeManualRecords(now)
	pruneManualRecords(now)
	local records = {}
	for _, record in pairs(manualRecordsByInstanceId) do
		local startsAt = tonumber(record.startsAt) or 0
		local endsAt = tonumber(record.endsAt) or 0
		if now >= startsAt and now < endsAt then
			records[#records + 1] = record
		end
	end
	return records
end

local function recordEndsAtFor(instanceId)
	local record = manualRecordsByInstanceId[instanceId]
	if record then
		return finiteNumber(record.endsAt)
	end
	for _, activeRecord in pairs(activeRecordsByEventId) do
		if activeRecord.instanceId == instanceId then
			return finiteNumber(activeRecord.endsAt)
		end
	end
	for _, bucket in pairs(externalRecordsBySource) do
		local externalRecord = bucket[instanceId]
		if externalRecord then
			return finiteNumber(externalRecord.endsAt)
		end
	end
	return nil
end

local function suppressionUntilFor(instanceId, now)
	local endsAt = recordEndsAtFor(instanceId)
	if endsAt then
		return math.max(endsAt, now) + SUPPRESS_AFTER_ENDS_SECONDS
	end
	return now + SUPPRESS_FALLBACK_SECONDS
end

local function sanitizeExternalRecord(record)
	if type(record) ~= "table" then
		return nil
	end
	local instanceId = record.instanceId
	if type(instanceId) ~= "string" or instanceId == "" then
		return nil
	end
	local eventId = record.eventId
	local config = type(eventId) == "string" and GameEvents.GetEvent(eventId) or nil
	if not config then
		return nil
	end
	local layer = record.layer
	if type(layer) ~= "string" or not GameEvents.LayerConfigs[layer] then
		return nil
	end
	local startsAt = finiteNumber(record.startsAt)
	local endsAt = finiteNumber(record.endsAt)
	if not startsAt or not endsAt or endsAt <= startsAt then
		return nil
	end
	local displayFrame = record.displayFrame
	if type(displayFrame) ~= "string" or displayFrame == "" then
		displayFrame = config.displayFrame or eventId
	end
	return {
		instanceId = instanceId,
		eventId = eventId,
		layer = layer,
		source = type(record.source) == "string" and record.source or GameEvents.Sources.AdminCommand,
		startsAt = startsAt,
		endsAt = endsAt,
		priority = finiteNumber(record.priority) or tonumber(config.priority) or 0,
		displayPriority = finiteNumber(record.displayPriority) or tonumber(config.displayPriority) or 0,
		displayFrame = displayFrame,
	}
end

local function activeExternalRecords(now)
	local records = {}
	for _, bucket in pairs(externalRecordsBySource) do
		for instanceId, record in pairs(bucket) do
			if not completedInstanceIds[instanceId]
				and now >= record.startsAt
				and now < record.endsAt then
				records[#records + 1] = record
			end
		end
	end
	return records
end

local handlers = {
	[GameEvents.Ids.Windy] = {
		start = PlotWindService.StartWind,
		stop = PlotWindService.StopWind,
		preNotice = PlotWindService.NotifyWindStarting,
	},
	[GameEvents.Ids.Stormy] = {
		start = function(record, callbacks)
			PlotThunderstormService.StartStorm(record, callbacks)
		end,
		stop = PlotThunderstormService.StopStorm,
		preNotice = PlotThunderstormService.NotifyStormApproaching,
	},
	[GameEvents.Ids.Tornado] = {
		start = function(record, callbacks)
			PlotTornadoService.StartTornado(record, callbacks)
		end,
		stop = PlotTornadoService.StopTornado,
		preNotice = PlotTornadoService.NotifyTornadoApproaching,
	},
	[GameEvents.Ids.Tsunami] = {
		start = function(record, callbacks)
			PlotTsunamiService.StartTsunami(record, callbacks)
		end,
		stop = PlotTsunamiService.StopTsunami,
		preNotice = PlotTsunamiService.NotifyTsunamiApproaching,
	},
	[GameEvents.Ids.Alien] = {
		start = function(record, callbacks)
			PlotAlienEventService.StartAlien(record, callbacks)
		end,
		stop = PlotAlienEventService.StopAlien,
	},
}

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

local function activeRecordFor(records, eventId)
	for _, record in ipairs(records or {}) do
		if record.eventId == eventId then
			return record
		end
	end
	return nil
end

local function updateHandlers(records)
	for eventId, handler in pairs(handlers) do
		local record = activeRecordFor(records, eventId)
		local activeInstanceId = activeInstanceIdsByEventId[eventId]
		if record then
			if activeInstanceId ~= record.instanceId then
				if activeInstanceId and handler.stop then
					logEvent("Stopping", activeInstanceId)
					RuntimeGuard.Run("GameEventService.Stop." .. tostring(eventId), handler.stop, activeInstanceId)
				end
				activeInstanceIdsByEventId[eventId] = record.instanceId
				activeRecordsByEventId[eventId] = record
				logEvent("Starting", record)
				RuntimeGuard.Run("GameEventService.Start." .. tostring(eventId), handler.start, record, {
					complete = GameEventService.CompleteInstance,
					snapshotProfileState = serviceConfig.snapshotProfileState,
				})
			else
				activeRecordsByEventId[eventId] = record
			end
		elseif activeInstanceId then
			if handler.stop then
				logEvent("Stopping", activeInstanceId)
				RuntimeGuard.Run("GameEventService.Stop." .. tostring(eventId), handler.stop, activeInstanceId)
			end
			activeInstanceIdsByEventId[eventId] = nil
			activeRecordsByEventId[eventId] = nil
		end
	end
end

local function updatePreNotice(now, nextWeather)
	for instanceId, startsAt in pairs(notifiedInstanceIds) do
		if tonumber(startsAt) and startsAt < now - 3600 then
			notifiedInstanceIds[instanceId] = nil
		end
	end

	if not nextWeather then
		return
	end
	local handler = handlers[nextWeather.eventId]
	if not (handler and handler.preNotice) then
		return
	end
	local config = GameEvents.GetEvent(nextWeather.eventId) or {}
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
	RuntimeGuard.Run("GameEventService.NotifyStarting." .. tostring(nextWeather.eventId), handler.preNotice)
end

local function update()
	local now = serverNow()
	for instanceId, suppressedUntil in pairs(completedInstanceIds) do
		if (tonumber(suppressedUntil) or 0) <= now then
			completedInstanceIds[instanceId] = nil
		end
	end
	for layer, block in pairs(completionBlocksByLayer) do
		if type(block) ~= "table" or (tonumber(block.untilTime) or 0) <= now then
			completionBlocksByLayer[layer] = nil
		end
	end
	local snapshot = GameEvents.WeatherSnapshot(now, completedInstanceIds, completionBlocksByLayer)
	local records = {}
	for _, record in ipairs(snapshot.activeRecords or {}) do
		records[#records + 1] = record
	end
	for _, record in ipairs(activeManualRecords(now)) do
		records[#records + 1] = record
	end
	for _, record in ipairs(activeExternalRecords(now)) do
		records[#records + 1] = record
	end
	records = GameEvents.ApplyLayerConfigs(records)
	local nextWeather = snapshot.nextWeather

	local signature = signatureFor(records, nextWeather)
	if signature ~= lastSignature then
		lastSignature = signature
		publishSnapshot(records, nextWeather)
	end

	updateHandlers(records)
	updatePreNotice(now, nextWeather)
end

function GameEventService.CompleteInstance(instanceId, options)
	if type(instanceId) ~= "string" or instanceId == "" then
		return
	end
	options = type(options) == "table" and options or {}
	local keepHandlerRunning = options.keepHandlerRunning == true
	local now = serverNow()
	completedInstanceIds[instanceId] = suppressionUntilFor(instanceId, now)
	manualRecordsByInstanceId[instanceId] = nil
	for eventId, activeInstanceId in pairs(activeInstanceIdsByEventId) do
		if activeInstanceId == instanceId then
			local handler = handlers[eventId]
			local record = activeRecordsByEventId[eventId]
			local blockUntil = tonumber(options.blockLowerPriorityUntil)
			if record and blockUntil and blockUntil > now then
				completionBlocksByLayer[record.layer] = {
					instanceId = instanceId,
					priority = tonumber(record.priority) or 0,
					untilTime = blockUntil,
				}
			end
			if not keepHandlerRunning and handler and handler.stop then
				RuntimeGuard.Run("GameEventService.CompleteStop." .. tostring(eventId), handler.stop, instanceId)
			end
			activeInstanceIdsByEventId[eventId] = nil
			activeRecordsByEventId[eventId] = nil
		end
	end
	lastSignature = nil
	update()
end

-- Replaces the entire external record bucket for one source (e.g. the global
-- live-events control plane). Records are sanitized copies; invalid entries are
-- dropped with a warning count. Locally completed/suppressed instance IDs are
-- filtered at merge time in update(), not here, so suppression survives
-- repeated reconciles.
function GameEventService.SetExternalManualRecords(sourceKey, records)
	if type(sourceKey) ~= "string" or sourceKey == "" then
		return false, "invalid-source"
	end
	if records ~= nil and type(records) ~= "table" then
		return false, "invalid-records"
	end

	local bucket = {}
	local dropped = 0
	for _, record in ipairs(records or {}) do
		local sanitized = sanitizeExternalRecord(record)
		if sanitized then
			bucket[sanitized.instanceId] = sanitized
		else
			dropped += 1
		end
	end
	if dropped > 0 then
		warn(string.format(
			"[GameEventService] Dropped %d invalid external record(s) from source %s",
			dropped,
			sourceKey
		))
	end
	externalRecordsBySource[sourceKey] = next(bucket) ~= nil and bucket or nil

	if started then
		update()
	end
	return true
end

function GameEventService.StartManualEvent(eventId, options)
	local config = GameEvents.GetEvent(eventId)
	if not config then
		return false, "unknown-event"
	end
	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		return false, "invalid-options"
	end

	local layer = config.layer
	if type(layer) ~= "string" or not GameEvents.LayerConfigs[layer] then
		return false, "invalid-layer"
	end

	local now = serverNow()
	local startsAt = optionNumber(options, "startsAt", now)
	if startsAt == nil then
		return false, "invalid-options"
	end

	local durationSeconds = optionNumber(options, "durationSeconds", GameEvents.TotalDuration(config))
	if durationSeconds == nil or durationSeconds <= 0 then
		return false, "invalid-duration"
	end

	local instanceId = options.instanceId
	if instanceId ~= nil then
		if type(instanceId) ~= "string" or instanceId == "" then
			return false, "invalid-options"
		end
	else
		instanceId = generatedManualInstanceId(eventId, layer, startsAt)
	end
	if manualRecordsByInstanceId[instanceId] or completedInstanceIds[instanceId] then
		return false, "duplicate-instance"
	end

	local priority = optionNumber(options, "priority", tonumber(config.priority) or 0)
	local displayPriority = optionNumber(options, "displayPriority", tonumber(config.displayPriority) or priority)
	if priority == nil or displayPriority == nil then
		return false, "invalid-options"
	end

	local displayFrame = options.displayFrame
	if displayFrame ~= nil then
		if type(displayFrame) ~= "string" or displayFrame == "" then
			return false, "invalid-options"
		end
	else
		displayFrame = config.displayFrame or eventId
	end

	local record = {
		instanceId = instanceId,
		eventId = eventId,
		layer = layer,
		source = GameEvents.Sources.AdminCommand,
		startsAt = startsAt,
		endsAt = startsAt + durationSeconds,
		priority = priority,
		displayPriority = displayPriority,
		displayFrame = displayFrame,
	}
	manualRecordsByInstanceId[instanceId] = record
	lastSignature = nil
	update()
	return true, copyRecord(record)
end

function GameEventService.StopManualEvent(instanceId)
	if type(instanceId) ~= "string" or instanceId == "" then
		return false, "invalid-options"
	end
	if not manualRecordsByInstanceId[instanceId] then
		return false, "unknown-instance"
	end
	manualRecordsByInstanceId[instanceId] = nil
	lastSignature = nil
	update()
	return true
end

function GameEventService.StopManualEventsByEventId(eventId)
	if type(eventId) ~= "string" or eventId == "" then
		return 0
	end
	local stoppedCount = 0
	for instanceId, record in pairs(manualRecordsByInstanceId) do
		if record.eventId == eventId then
			manualRecordsByInstanceId[instanceId] = nil
			stoppedCount += 1
		end
	end
	if stoppedCount > 0 then
		lastSignature = nil
		update()
	end
	return stoppedCount
end

function GameEventService.StopManualEventsByLayer(layer)
	if type(layer) ~= "string" or layer == "" then
		return 0
	end
	local stoppedCount = 0
	for instanceId, record in pairs(manualRecordsByInstanceId) do
		if record.layer == layer then
			manualRecordsByInstanceId[instanceId] = nil
			stoppedCount += 1
		end
	end
	if stoppedCount > 0 then
		lastSignature = nil
		update()
	end
	return stoppedCount
end

function GameEventService.Configure(config)
	if type(config) ~= "table" then
		return
	end
	if type(config.snapshotProfileState) == "function" then
		serviceConfig.snapshotProfileState = config.snapshotProfileState
	end
end

function GameEventService.Start(config)
	if started then
		GameEventService.Configure(config)
		return
	end
	GameEventService.Configure(config)
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
