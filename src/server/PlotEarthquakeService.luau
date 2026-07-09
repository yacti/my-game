-- Earthquake weather event: a global tremor with no dedicated remote --
-- clients render the rumble from the replicated snapshot record. The active
-- window plays as pulsed tremor bursts with calm between (the schedule comes
-- from GameEvents.EarthquakePulses, deterministically seeded from startsAt so
-- clients render the identical bursts). This service owns the gameplay: each
-- eligible player has 6-12 of their fruit turn Shaken, scattered across the
-- bursts so hits only land while the ground visibly shakes. Players are
-- tracked through a per-player registry (the Windy pattern) so mid-event
-- joiners are picked up prorated: hit times are rolled over the full window
-- and instants already in the past are discarded.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local EventEligibility = require(Server:WaitForChild("EventEligibility"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlotEarthquakeService = {}

local WAIT_STEP = 0.25
local SNAPSHOT_DEBOUNCE_SECONDS = 2
local rng = Random.new()
local recordsByUserId = {}
local activeSession = nil

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

local function printEarthquakeLifecycle(action, session, detail)
	local suffix = ""
	if detail ~= nil and detail ~= "" then
		suffix = " " .. tostring(detail)
	end
	print(string.format(
		"[PlotEarthquakeService] Earthquake %s %s (%d -> %d)%s",
		tostring(action),
		tostring(session.instanceId),
		math.floor(tonumber(session.startsAt) or 0),
		math.floor(tonumber(session.endsAt) or 0),
		suffix
	))
end

local function displayNameForFood(foodId)
	local producerFeedType, sourceFoodId = Food.ParseJamFoodId(foodId)
	if producerFeedType and sourceFoodId then
		local sourceTemplate = Food.GetTemplate(sourceFoodId)
		return (sourceTemplate and sourceTemplate.Name or sourceFoodId) .. " Jam"
	end
	local template = type(foodId) == "string" and Food.GetTemplate(foodId) or nil
	return template and template.Name or tostring(foodId or "food")
end

local function multiplierLabel(multiplier)
	local value = tonumber(multiplier) or 1
	if value % 1 == 0 then
		return tostring(math.floor(value))
	end
	return tostring(value)
end

local function settingsFor()
	local config = GameEvents.GetEvent(GameEvents.Ids.Earthquake) or {}
	local earthquake = type(config.earthquake) == "table" and config.earthquake or {}
	local windUpSeconds, activeSeconds, windDownSeconds, totalSeconds = GameEvents.EarthquakeTimings(config)
	local minMutations = integerValue(earthquake.minMutationsPerPlot, 2)
	local maxMutations = math.max(integerValue(earthquake.maxMutationsPerPlot, 5), minMutations)
	return {
		mutationId = config.appliedMutationId or Mutations.Ids.Shaken,
		windUpSeconds = windUpSeconds,
		activeSeconds = activeSeconds,
		windDownSeconds = windDownSeconds,
		totalSeconds = totalSeconds,
		minMutationsPerPlot = minMutations,
		maxMutationsPerPlot = maxMutations,
		targetRetrySeconds = math.max(numberValue(earthquake.targetRetrySeconds, 2), 0),
		burstEaseSeconds = math.max(numberValue(earthquake.burstEaseSeconds, 0.5), 0),
	}
end

local function isEventEligible(player)
	local eligible = EventEligibility.IsEligible(player)
	return eligible == true
end

local function isActiveRecord(player, plot, record)
	local key = userKey(player)
	return key ~= nil
		and recordsByUserId[key] == record
		and not record.cancelled
		and player.Parent == Players
		and PlotService.GetPlayerPlot(player) == plot
end

local function isQuakeEligible(player, plot, record)
	if not isActiveRecord(player, plot, record) then
		return false
	end
	local eligible = EventEligibility.IsEligibleForPlot(player, plot)
	return eligible == true
end

local function sessionActive(session)
	return session and not session.cancelled and activeSession == session
end

local function cancellableWait(session, seconds)
	local deadline = os.clock() + math.max(tonumber(seconds) or 0, 0)
	while sessionActive(session) do
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			return true
		end
		task.wait(math.min(WAIT_STEP, remaining))
	end
	return false
end

local function collectTargets(plot, mutationId)
	local targets = {}
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		for _, target in ipairs(FeedMachines.CollectMutationTargets(feed, mutationId)) do
			targets[#targets + 1] = target
		end
	end
	return targets
end

local function notifyPlayer(player, text, lifetime)
	RuntimeGuard.Run("PlotEarthquakeService.NotifyPlayer", function()
		NotificationService.Notify(player, {
			text = text,
			lifetime = lifetime,
			preserveTrailingPeriods = true,
		})
	end)
end

local function notifyLoadedNonOnboarding(text, lifetime)
	for _, player in ipairs(Players:GetPlayers()) do
		if isEventEligible(player) then
			notifyPlayer(player, text, lifetime)
		end
	end
end

local function targetStillValid(target, mutationId)
	if type(target) ~= "table" or typeof(target.machine) ~= "Instance" or not target.machine.Parent then
		return false
	end
	local targets = FeedMachines.CollectMutationTargets(target.machine, mutationId)
	for _, current in ipairs(targets) do
		if current.targetKey == target.targetKey then
			return true
		end
	end
	return false
end

local function entryStillEligible(session, entry)
	if not (sessionActive(session) and entry and entry.player) then
		return false
	end
	if not isActiveRecord(entry.player, entry.plot, entry.record) then
		return false
	end
	local eligible, _, context = EventEligibility.IsEligibleForPlot(entry.player, entry.plot)
	if not eligible then
		return false
	end
	return context and context.plot == entry.plot
end

local function scheduleOwnerSnapshot(session, entry)
	if type(session.snapshotProfileState) ~= "function" then
		return
	end
	local player = entry and entry.player
	local userId = player and player.UserId
	if not userId then
		return
	end
	local token = {}
	session.snapshotTokens[userId] = token
	task.delay(SNAPSHOT_DEBOUNCE_SECONDS, function()
		RuntimeGuard.Run("PlotEarthquakeService.SnapshotOwner." .. tostring(userId), function()
			if session.snapshotTokens[userId] ~= token then
				return
			end
			session.snapshotTokens[userId] = nil
			local profile = PlayerDataService.GetProfile(player)
			if not (profile and player.Parent == Players and PlotService.GetPlayerPlot(player) == entry.plot) then
				return
			end
			local ok = session.snapshotProfileState(player, entry.plot, profile)
			if ok ~= true then
				warn("[PlotEarthquakeService] Snapshot failed after earthquake mutation for user " .. tostring(userId))
			end
		end)
	end)
end

local function chooseTarget(session, entry, retrySeconds)
	local deadline = os.clock() + math.max(retrySeconds, 0)
	while entryStillEligible(session, entry) do
		local targets = collectTargets(entry.plot, session.settings.mutationId)
		if #targets > 0 then
			return targets[rng:NextInteger(1, #targets)]
		end
		if os.clock() >= deadline then
			return nil
		end
		task.wait(math.min(WAIT_STEP, math.max(deadline - os.clock(), 0)))
	end
	return nil
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

-- Hits must land only while the ground visibly shakes, so sampling happens in
-- concatenated-burst-time: roll the full-window hit count, spread it with one
-- random time per equal segment (the tsunami's underwater pattern) over the
-- summed burst lengths, then map each point back to its absolute offset
-- inside a burst. Bursts are inset by the ease ramp on both edges so a hit
-- only ever lands while the shake is at (or near) full strength.
local MUTATION_EDGE_INSET_SECONDS = 0.5

local function sampleMutationTimes(settings, pulses)
	local times = {}
	local count = rng:NextInteger(settings.minMutationsPerPlot, settings.maxMutationsPerPlot)
	if count <= 0 then
		return times
	end
	local edgeInset = math.max(settings.burstEaseSeconds, MUTATION_EDGE_INSET_SECONDS)
	local spans = {}
	local totalBurstSeconds = 0
	for _, pulse in ipairs(type(pulses) == "table" and pulses or {}) do
		local spanStart = pulse.startOffset + edgeInset
		local spanLength = (pulse.endOffset - edgeInset) - spanStart
		if spanLength > 0 then
			spans[#spans + 1] = { startOffset = spanStart, length = spanLength }
			totalBurstSeconds += spanLength
		end
	end
	if totalBurstSeconds <= 0 then
		return times
	end
	local segment = totalBurstSeconds / count
	for index = 1, count do
		local point = (index - 1) * segment + rng:NextNumber(0, segment)
		for spanIndex, span in ipairs(spans) do
			if point <= span.length or spanIndex == #spans then
				times[#times + 1] = span.startOffset + math.min(point, span.length)
				break
			end
			point -= span.length
		end
	end
	return times
end

local function runShakePhase(session, entry, times)
	for _, timeOffset in ipairs(times) do
		if not cancellableWait(session, (session.startsAt + timeOffset) - serverNow()) then
			return
		end
		if not entryStillEligible(session, entry) then
			return
		end
		local target = chooseTarget(session, entry, session.settings.targetRetrySeconds)
		-- A missing target only skips this hit (unlike the tsunami's abort):
		-- fresh unmutated fruit can appear later in the window.
		if target and targetStillValid(target, session.settings.mutationId) then
			local applied, result = FeedMachines.ApplyMutation(target.machine, target.targetKey, session.settings.mutationId)
			if applied then
				scheduleOwnerSnapshot(session, entry)
				local xpMultiplier = Mutations.XPMultiplier(session.settings.mutationId) or 1
				notifyPlayer(entry.player, string.format(
					"Your %s was shaken by the earthquake! (x%s XP)",
					displayNameForFood((result and result.foodId) or target.foodId),
					multiplierLabel(xpMultiplier)
				), 5)
			end
		end
	end
end

local function scheduleEntry(session, entry)
	local key = userKey(entry.player)
	if not key or session.scheduledByUserId[key] then
		return
	end
	if not isQuakeEligible(entry.player, entry.plot, entry.record) then
		return
	end
	-- Mark before the empty-times early-out (the Windy pattern) so a too-late
	-- joiner is not re-rolled on every pickup tick.
	session.scheduledByUserId[key] = true

	local minElapsed = math.max(serverNow() - session.startsAt, 0)
	local times = {}
	for _, timeOffset in ipairs(sampleMutationTimes(session.settings, session.pulses)) do
		if timeOffset > minElapsed and session.startsAt + timeOffset < session.endsAt then
			times[#times + 1] = timeOffset
		end
	end
	local offsets = {}
	for index, timeOffset in ipairs(times) do
		offsets[index] = string.format("%.1f", timeOffset)
	end
	printEarthquakeLifecycle("schedule", session, string.format("user=%d hits=%d t=[%s]", key, #times, table.concat(offsets, ",")))
	if #times == 0 then
		return
	end
	RuntimeGuard.Spawn(
		"PlotEarthquakeService.Shake." .. tostring(session.instanceId) .. "." .. tostring(key),
		runShakePhase,
		session,
		entry,
		times
	)
end

local function runEarthquake(session)
	local config = GameEvents.GetEvent(GameEvents.Ids.Earthquake) or {}
	-- Manual events never get the scheduler pre-notice (updatePreNotice only
	-- covers cadenced configs), so send it here like the tsunami does.
	notifyLoadedNonOnboarding(config.preNoticeText or "The ground begins to tremble...", 5)
	while sessionActive(session) and serverNow() < session.endsAt do
		for _, entry in ipairs(registeredEntries()) do
			scheduleEntry(session, entry)
		end
		task.wait(WAIT_STEP)
	end
	if not sessionActive(session) then
		return
	end
	session.complete()
end

local function cleanupFailedEarthquake(session)
	if type(session) ~= "table" or session.failureCleanupDone then
		return
	end
	session.failureCleanupDone = true
	session.cancelled = true
	if not session.loggedEnd then
		session.loggedEnd = true
		printEarthquakeLifecycle("end", session, "failed")
	end
	if type(session.complete) == "function" then
		RuntimeGuard.Run("PlotEarthquakeService.FailedComplete." .. tostring(session.instanceId), session.complete)
	end
end

local function runEarthquakeGuarded(session)
	local ok, err = RuntimeGuard.Try("PlotEarthquakeService.Run." .. tostring(session and session.instanceId), runEarthquake, session)
	if ok then
		return
	end
	warn(err)
	cleanupFailedEarthquake(session)
end

function PlotEarthquakeService.StartEarthquake(eventRecord, callbacks)
	if type(eventRecord) ~= "table" then
		return
	end
	if activeSession then
		PlotEarthquakeService.StopEarthquake(activeSession.instanceId)
	end
	callbacks = type(callbacks) == "table" and callbacks or {}

	local settings = settingsFor()
	local startsAt = numberValue(eventRecord.startsAt, serverNow())
	local endsAt = numberValue(eventRecord.endsAt, startsAt + settings.totalSeconds)
	local session = {
		instanceId = tostring(eventRecord.instanceId or ""),
		startsAt = startsAt,
		endsAt = endsAt,
		settings = settings,
		pulses = GameEvents.EarthquakePulses(GameEvents.GetEvent(GameEvents.Ids.Earthquake), startsAt),
		scheduledByUserId = {},
		snapshotProfileState = callbacks.snapshotProfileState,
		snapshotTokens = {},
		cancelled = false,
	}
	session.complete = function()
		if not session.loggedEnd then
			session.loggedEnd = true
			printEarthquakeLifecycle("end", session, "completed")
		end
		if activeSession == session then
			activeSession = nil
		end
		if type(callbacks.complete) == "function" then
			callbacks.complete(session.instanceId)
		end
	end
	activeSession = session
	printEarthquakeLifecycle("start", session, string.format("window=%ds bursts=%d", math.floor(settings.activeSeconds), #session.pulses))

	RuntimeGuard.Spawn("PlotEarthquakeService.RunGuarded." .. session.instanceId, runEarthquakeGuarded, session)
end

function PlotEarthquakeService.NotifyEarthquakeStarting()
	local config = GameEvents.GetEvent(GameEvents.Ids.Earthquake) or {}
	local text = config.preNoticeText or "The ground begins to tremble..."
	local lifetime = math.max(numberValue(config.preNoticeSeconds, 5), 0)
	notifyLoadedNonOnboarding(text, lifetime)
end

function PlotEarthquakeService.StopEarthquake(instanceId)
	local session = activeSession
	if not session then
		return
	end
	if instanceId ~= nil and tostring(instanceId) ~= tostring(session.instanceId) then
		return
	end
	session.cancelled = true
	if not session.loggedEnd then
		session.loggedEnd = true
		printEarthquakeLifecycle("end", session, "stopped")
	end
	activeSession = nil
end

function PlotEarthquakeService.StartForPlayer(player, plot)
	local key = userKey(player)
	if key == nil or not plot then
		return
	end

	PlotEarthquakeService.StopForPlayer(player)

	local record = {
		cancelled = false,
	}
	recordsByUserId[key] = record

	local session = activeSession
	if sessionActive(session) then
		scheduleEntry(session, {
			player = player,
			plot = plot,
			record = record,
		})
	end
end

function PlotEarthquakeService.StopForPlayer(player)
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
	if activeSession then
		activeSession.scheduledByUserId[key] = nil
	end
end

return PlotEarthquakeService
