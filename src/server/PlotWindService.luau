local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local EventEligibility = require(Server:WaitForChild("EventEligibility"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local TreeClicker = require(Server:WaitForChild("feedMachines"):WaitForChild("Trees"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlotWindService = {}

local WAIT_STEP = 0.25
local rng = Random.new()
local recordsByUserId = {}
local activeWindSession = nil

local function userKey(player)
	return player and player.UserId or nil
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function numberValue(value, fallback)
	value = tonumber(value)
	if value == nil then
		return fallback
	end
	return value
end

local function integerValue(value, fallback)
	return math.max(math.floor(numberValue(value, fallback)), 0)
end

local function hasRecords()
	return next(recordsByUserId) ~= nil
end

local function isActiveRecord(player, plot, record)
	local key = userKey(player)
	return key ~= nil
		and recordsByUserId[key] == record
		and not record.cancelled
		and player.Parent == Players
		and PlotService.GetPlayerPlot(player) == plot
end

local function isWindEligible(player, plot, record)
	if not isActiveRecord(player, plot, record) then
		return false
	end
	local eligible = EventEligibility.IsEligibleForPlot(player, plot)
	return eligible == true
end

local function isTreeFeed(feed)
	return feed:IsA("Model") and feed:GetAttribute(State.Feed.Class) == "Tree"
end

local function collectTrees(plot)
	local trees = {}
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		if isTreeFeed(feed) then
			trees[#trees + 1] = feed
		end
	end
	return trees
end

local function windSettings()
	local config = GameEvents.GetEvent(GameEvents.Ids.Windy) or {}
	local wind = type(config.wind) == "table" and config.wind or {}
	local windUpSeconds, activeSeconds, windDownSeconds, totalSeconds = GameEvents.WindTimings(config)
	local minFruitPerWave = integerValue(wind.minFruitPerWave, 2)
	local maxFruitPerWave = math.max(integerValue(wind.maxFruitPerWave, 4), minFruitPerWave)
	return {
		windUpSeconds = windUpSeconds,
		activeSeconds = activeSeconds,
		windDownSeconds = windDownSeconds,
		totalSeconds = totalSeconds,
		minTreeWaves = integerValue(wind.minTreeWaves, 18),
		maxTreeWaves = integerValue(wind.maxTreeWaves, 52),
		minFruitPerWave = minFruitPerWave,
		maxFruitPerWave = maxFruitPerWave,
		minShakeGap = math.max(numberValue(wind.minShakeGap, 0.5), 0),
		treeEffectRadius = math.max(numberValue(wind.treeEffectRadius, 35), 0),
		maxWaveEventsPerHeartbeat = math.max(integerValue(wind.maxWaveEventsPerHeartbeat, 50), 1),
		shakeStartPadding = math.max(numberValue(wind.shakeStartPadding, 0.1), 0),
		shakeEndPadding = math.max(numberValue(wind.shakeEndPadding, 0.2), 0),
	}
end

local function sessionActive(session)
	return session
		and not session.cancelled
		and activeWindSession == session
		and serverNow() < session.endsAt
end

local function waitWhileSessionActive(session, seconds)
	local deadline = os.clock() + math.max(0, seconds)
	while sessionActive(session) and hasRecords() do
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			return true
		end
		task.wait(math.min(WAIT_STEP, remaining))
	end
	return false
end

local function triggerTreeWave(session, player, plot, record, tree, amount)
	local ok, didRun = RuntimeGuard.Run("PlotWindService.TriggerWindWave", function()
		if not sessionActive(session) then
			return false
		end
		if not isWindEligible(player, plot, record) then
			return false
		end
		if not tree:IsDescendantOf(plot) then
			return false
		end
		TreeClicker.TriggerWindWave(tree, player, amount, {
			effectRadius = session.settings.treeEffectRadius,
			includeTriggeringPlayer = false,
		})
		return true
	end)
	return ok == true and didRun == true
end

local function registeredEntries()
	local entries = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local key = userKey(player)
		local record = key and recordsByUserId[key] or nil
		local plot = record and PlotService.GetPlayerPlot(player) or nil
		if plot and isActiveRecord(player, plot, record) then
			entries[#entries + 1] = {
				player = player,
				plot = plot,
				record = record,
			}
		end
	end
	return entries
end

local function eligibleEntries()
	local entries = {}
	for _, entry in ipairs(registeredEntries()) do
		if isWindEligible(entry.player, entry.plot, entry.record) then
			entries[#entries + 1] = entry
		end
	end
	return entries
end

local function sampleWaveTimes(settings)
	local activeSeconds = settings.activeSeconds
	if activeSeconds <= 0 then
		return {}
	end

	local minCount = math.max(settings.minTreeWaves, 0)
	local maxCount = math.max(settings.maxTreeWaves, minCount)
	local count = rng:NextInteger(minCount, maxCount)
	if count <= 0 then
		return {}
	end

	local first = math.min(settings.shakeStartPadding, math.max(activeSeconds - settings.shakeEndPadding, 0))
	local last = math.max(first, activeSeconds - settings.shakeEndPadding)
	if count <= 1 or settings.minShakeGap <= 0 then
		return {
			settings.windUpSeconds + rng:NextNumber(first, last),
		}
	end

	local maxFittable = math.floor((last - first) / settings.minShakeGap) + 1
	count = math.max(math.min(count, maxFittable), 1)
	if count <= 1 then
		return {
			settings.windUpSeconds + rng:NextNumber(first, last),
		}
	end

	local latestFirst = last - ((count - 1) * settings.minShakeGap)
	local current = rng:NextNumber(first, latestFirst)
	local times = { settings.windUpSeconds + current }
	for index = 2, count do
		local remainingAfterThis = count - index
		local latest = last - (remainingAfterThis * settings.minShakeGap)
		current = rng:NextNumber(current + settings.minShakeGap, latest)
		times[index] = settings.windUpSeconds + current
	end
	return times
end

local function buildWaveQueue(session, entries, minElapsed)
	local queue = {}
	minElapsed = math.max(numberValue(minElapsed, 0), 0)
	for _, entry in ipairs(entries) do
		for _, tree in ipairs(collectTrees(entry.plot)) do
			for _, shakeTime in ipairs(sampleWaveTimes(session.settings)) do
				if shakeTime > minElapsed and session.startsAt + shakeTime < session.endsAt then
					queue[#queue + 1] = {
						time = shakeTime,
						player = entry.player,
						plot = entry.plot,
						record = entry.record,
						tree = tree,
						amount = rng:NextInteger(session.settings.minFruitPerWave, session.settings.maxFruitPerWave),
					}
				end
			end
		end
	end
	table.sort(queue, function(a, b)
		return a.time < b.time
	end)
	return queue
end

local function compactQueue(session)
	local queueIndex = session.queueIndex or 1
	if queueIndex <= 1 then
		return
	end

	local compacted = {}
	for index = queueIndex, #session.queue do
		compacted[#compacted + 1] = session.queue[index]
	end
	session.queue = compacted
	session.queueIndex = 1
end

local function nextQueuedEvent(session)
	return session.queue[session.queueIndex or 1]
end

local processWaveQueue
local scheduleNewlyEligibleEntries

local function ensureProcessor(session)
	if not sessionActive(session) or session.processing then
		return
	end
	session.processing = true
	RuntimeGuard.Spawn("PlotWindService.WaveQueue." .. tostring(session.instanceId), processWaveQueue, session)
end

processWaveQueue = function(session)
	while sessionActive(session) and hasRecords() do
		scheduleNewlyEligibleEntries(session)
		local elapsed = serverNow() - session.startsAt
		local processed = 0
		local checked = 0
		local maxChecks = session.settings.maxWaveEventsPerHeartbeat * 4
		while nextQueuedEvent(session)
			and nextQueuedEvent(session).time <= elapsed
			and processed < session.settings.maxWaveEventsPerHeartbeat
			and checked < maxChecks do
			local event = nextQueuedEvent(session)
			session.queueIndex += 1
			checked += 1
			if triggerTreeWave(session, event.player, event.plot, event.record, event.tree, event.amount) then
				processed += 1
			end
		end

		if serverNow() >= session.endsAt then
			break
		end

		if (session.queueIndex or 1) > 128 and (session.queueIndex or 1) > (#session.queue / 2) then
			compactQueue(session)
		end

		local nextEvent = nextQueuedEvent(session)
		if not nextEvent then
			if not waitWhileSessionActive(session, WAIT_STEP) then
				break
			end
		elseif nextEvent.time <= elapsed then
			RunService.Heartbeat:Wait()
		else
			local nextTime = math.min(session.endsAt - session.startsAt, nextEvent.time)
			local waitSeconds = math.max(0, nextTime - elapsed)
			if waitSeconds <= 0 then
				RunService.Heartbeat:Wait()
			elseif not waitWhileSessionActive(session, waitSeconds) then
				break
			end
		end
	end
	session.processing = false
end

local function scheduleEntries(session, entries)
	if not sessionActive(session) or #entries == 0 then
		return
	end

	local schedulableEntries = {}
	for _, entry in ipairs(entries) do
		local key = userKey(entry.player)
		if key and not session.scheduledByUserId[key] and isWindEligible(entry.player, entry.plot, entry.record) then
			session.scheduledByUserId[key] = true
			schedulableEntries[#schedulableEntries + 1] = entry
		end
	end
	if #schedulableEntries == 0 then
		return
	end

	local minElapsed = math.max(serverNow() - session.startsAt, 0)
	local queue = buildWaveQueue(session, schedulableEntries, minElapsed)
	if #queue == 0 then
		return
	end

	compactQueue(session)
	for _, event in ipairs(queue) do
		session.queue[#session.queue + 1] = event
	end
	table.sort(session.queue, function(a, b)
		return a.time < b.time
	end)

	if not session.processing then
		ensureProcessor(session)
	end
end

scheduleNewlyEligibleEntries = function(session)
	local entries = {}
	for _, entry in ipairs(registeredEntries()) do
		local key = userKey(entry.player)
		if key and not session.scheduledByUserId[key] and isWindEligible(entry.player, entry.plot, entry.record) then
			entries[#entries + 1] = entry
		end
	end
	scheduleEntries(session, entries)
end

function PlotWindService.NotifyWindStarting()
	local config = GameEvents.GetEvent(GameEvents.Ids.Windy) or {}
	local text = config.preNoticeText or "It's getting windy..."
	local lifetime = math.max(numberValue(config.preNoticeSeconds, 3), 0)
	for _, entry in ipairs(eligibleEntries()) do
		RuntimeGuard.Run("PlotWindService.NotifyWindStarting", function()
			NotificationService.Notify(entry.player, {
				text = text,
				lifetime = lifetime,
				preserveTrailingPeriods = true,
			})
		end)
	end
end

function PlotWindService.StartWind(eventRecord)
	if type(eventRecord) ~= "table" then
		return
	end
	if activeWindSession then
		PlotWindService.StopWind(activeWindSession.instanceId)
	end

	local settings = windSettings()
	activeWindSession = {
		instanceId = tostring(eventRecord.instanceId or ""),
		startsAt = numberValue(eventRecord.startsAt, serverNow()),
		endsAt = numberValue(eventRecord.endsAt, serverNow() + settings.totalSeconds),
		settings = settings,
		queue = {},
		queueIndex = 1,
		processing = false,
		scheduledByUserId = {},
		cancelled = false,
	}

	scheduleEntries(activeWindSession, eligibleEntries())
	ensureProcessor(activeWindSession)
end

function PlotWindService.StopWind(instanceId)
	local session = activeWindSession
	if not session then
		return
	end
	if instanceId ~= nil and tostring(instanceId) ~= tostring(session.instanceId) then
		return
	end
	session.cancelled = true
	activeWindSession = nil
end

function PlotWindService.StartForPlayer(player, plot)
	local key = userKey(player)
	if key == nil or not plot then
		return
	end

	PlotWindService.StopForPlayer(player)

	local record = {
		cancelled = false,
	}
	recordsByUserId[key] = record

	local session = activeWindSession
	if sessionActive(session) then
		scheduleEntries(session, {
			{
				player = player,
				plot = plot,
				record = record,
			},
		})
		ensureProcessor(session)
	end
end

function PlotWindService.StopForPlayer(player)
	local key = userKey(player)
	if key == nil then
		return
	end
	local record = recordsByUserId[key]
	if not record then
		return
	end
	record.cancelled = true
	recordsByUserId[key] = nil
	if activeWindSession then
		activeWindSession.scheduledByUserId[key] = nil
	end
end

return PlotWindService
