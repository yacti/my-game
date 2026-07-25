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
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlotAlienEventService = {}

local AlienEventEffect = Remotes.get(Remotes.Names.AlienEventEffect)

local WAIT_STEP = 0.25
local VIEWER_SYNC_SECONDS = 1
local SNAPSHOT_DEBOUNCE_SECONDS = 2
local rng = Random.new()
local activeSession = nil

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

local function printAlienLifecycle(action, session, detail)
	local suffix = ""
	if detail ~= nil and detail ~= "" then
		suffix = " " .. tostring(detail)
	end
	print(string.format(
		"[PlotAlienEventService] Alien %s %s (%d -> %d)%s",
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
	local config = GameEvents.GetEvent(GameEvents.Ids.Alien) or {}
	local alien = type(config.alien) == "table" and config.alien or {}
	local windUpSeconds, activeSeconds, windDownSeconds, totalSeconds = GameEvents.AlienTimings(config)
	local minZaps = integerValue(alien.minZapsPerVisit, 1)
	local maxZaps = math.max(integerValue(alien.maxZapsPerVisit, 5), minZaps)
	return {
		mutationId = config.appliedMutationId or Mutations.Ids.Alien,
		windUpSeconds = windUpSeconds,
		activeSeconds = activeSeconds,
		windDownSeconds = windDownSeconds,
		totalSeconds = totalSeconds,
		plotVisitSeconds = math.max(numberValue(alien.plotVisitSeconds, 8), 0),
		interVisitRoamSeconds = math.max(numberValue(alien.interVisitRoamSeconds, 0), 0),
		maxQueuedTurns = math.max(integerValue(alien.maxQueuedTurns, 8), 1),
		minZapsPerVisit = minZaps,
		maxZapsPerVisit = maxZaps,
		zapAppearSeconds = math.max(numberValue(alien.zapAppearSeconds, 0.25), 0),
		zapFadeSeconds = math.max(numberValue(alien.zapFadeSeconds, 1.2), 0),
		ufoMaxTiltDegrees = math.max(numberValue(alien.ufoMaxTiltDegrees, 15), 0),
		ufoTravelSeconds = math.max(numberValue(alien.ufoTravelSeconds, 4), 0),
		zapSoundRange = math.max(numberValue(alien.zapSoundRange, 500), 0),
	}
end

local function isEventEligible(player)
	local eligible = EventEligibility.IsEligible(player)
	return eligible == true
end

local function viewerEligible(session, player)
	if not (session and player) then
		return false
	end
	local eligible = EventEligibility.IsEligible(player)
	return eligible == true
end

local function plotCenter(plot)
	local floor = PlotService.GetFloor(plot)
	if floor then
		return floor.Position
	end
	if plot and plot:IsA("Model") then
		return plot:GetPivot().Position
	end
	return nil
end

local function mapCenter()
	local map = Workspace:FindFirstChild("Map")
	local center = map and map:FindFirstChild("CENTER")
	if center and center:IsA("BasePart") then
		return center.Position
	end
	return Vector3.zero
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

local function shuffle(list)
	for index = #list, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		list[index], list[swapIndex] = list[swapIndex], list[index]
	end
end

local function eligibleEntries(mutationId)
	local entries = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local eligible, _, context = EventEligibility.IsEligible(player)
		if eligible and context then
			local plot = context.plot
			local center = plotCenter(plot)
			if plot and center and #collectTargets(plot, mutationId) > 0 then
				entries[#entries + 1] = {
					player = player,
					userId = player.UserId,
					plot = plot,
					plotCenter = center,
				}
			end
		end
	end
	shuffle(entries)
	return entries
end

local function fireViewer(player, command, payload)
	RuntimeGuard.Run("PlotAlienEventService.FireClient." .. tostring(command), function()
		AlienEventEffect:FireClient(player, command, payload)
	end)
end

local function shouldFireViewer(session, player, command)
	if command == "end" and session.syncedViewers and session.syncedViewers[player.UserId] then
		return true
	end
	return viewerEligible(session, player)
end

local function syncPayload(session)
	return {
		instanceId = session.instanceId,
		startsAt = session.startsAt,
		endsAt = session.endsAt,
		phase = session.phase,
		settings = session.publicSettings,
		mapCenter = session.mapCenter,
		currentPlotCenter = session.currentPlotCenter,
		currentVisitEndsAt = session.currentVisitEndsAt,
		currentRoamEndsAt = session.currentRoamEndsAt,
	}
end

local function syncViewer(session, player)
	fireViewer(player, "sync", syncPayload(session))
	session.syncedViewers[player.UserId] = true
end

local function fireViewers(session, command, payload)
	for _, player in ipairs(Players:GetPlayers()) do
		if shouldFireViewer(session, player, command) then
			if command ~= "start"
				and command ~= "sync"
				and command ~= "end"
				and not session.syncedViewers[player.UserId] then
				syncViewer(session, player)
			end
			fireViewer(player, command, payload)
			if command == "start" or command == "sync" then
				session.syncedViewers[player.UserId] = true
			end
		end
	end
end

local function notifyPlayer(player, text, lifetime)
	RuntimeGuard.Run("PlotAlienEventService.NotifyPlayer", function()
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

local function notifyViewers(session, text, lifetime)
	for _, player in ipairs(Players:GetPlayers()) do
		if viewerEligible(session, player) then
			notifyPlayer(player, text, lifetime)
		end
	end
end

local function syncNewViewers(session)
	-- Drop synced flags for players who left, so a rejoining player (same
	-- UserId) counts as a fresh viewer and gets a full state sync.
	for userId in pairs(session.syncedViewers) do
		if not Players:GetPlayerByUserId(userId) then
			session.syncedViewers[userId] = nil
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if viewerEligible(session, player) and not session.syncedViewers[player.UserId] then
			syncViewer(session, player)
		end
	end
end

local function startViewerSync(session)
	RuntimeGuard.Spawn("PlotAlienEventService.ViewerSync." .. session.instanceId, function()
		while sessionActive(session) do
			syncNewViewers(session)
			task.wait(VIEWER_SYNC_SECONDS)
		end
	end)
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
	local eligible, _, context = EventEligibility.IsEligibleForPlot(entry.player, entry.plot)
	if not eligible then
		return false
	end
	return context and context.plot == entry.plot
end

local function canRefreshQueue(session)
	return sessionActive(session)
		and serverNow() < session.endsAt - session.settings.windDownSeconds
end

-- Refresh the queue from current plot/player truth after every turn. Queued
-- entries are replaced with fresh Player/plot references on rejoin, leavers
-- and exhausted plots are removed, and players with fewer completed turns are
-- appended first. This gives late joiners a prompt first turn without starving
-- players whose plots still have Alien-eligible targets.
local function refreshVisitQueue(session)
	if not canRefreshQueue(session) then
		return 0
	end

	local currentEntries = eligibleEntries(session.settings.mutationId)
	local currentByUserId = {}
	for _, entry in ipairs(currentEntries) do
		currentByUserId[entry.userId] = entry
	end

	for index = #session.entries, 1, -1 do
		local queuedEntry = session.entries[index]
		local currentEntry = currentByUserId[queuedEntry.userId]
		if currentEntry then
			-- A rejoin creates a new Player instance and can recreate the plot.
			-- Preserve the fair queue position while refreshing both references.
			session.entries[index] = currentEntry
			session.queuedUserIds[currentEntry.userId] = true
		else
			session.queuedUserIds[queuedEntry.userId] = nil
			table.remove(session.entries, index)
		end
	end

	local candidates = {}
	for _, entry in ipairs(currentEntries) do
		if not session.queuedUserIds[entry.userId] then
			candidates[#candidates + 1] = entry
		end
	end
	table.sort(candidates, function(left, right)
		local leftTurns = session.completedTurnsByUserId[left.userId] or 0
		local rightTurns = session.completedTurnsByUserId[right.userId] or 0
		if leftTurns ~= rightTurns then
			return leftTurns < rightTurns
		end
		return left.userId < right.userId
	end)

	local added = 0
	for _, entry in ipairs(candidates) do
		if #session.entries >= session.settings.maxQueuedTurns then
			break
		end
		session.entries[#session.entries + 1] = entry
		session.queuedUserIds[entry.userId] = true
		added += 1
	end
	return added
end

local function chooseVisitTarget(session, entry)
	local targets = collectTargets(entry.plot, session.settings.mutationId)
	if #targets == 0 then
		return nil
	end
	shuffle(targets)
	return targets[1]
end

local function nextQueuedEntry(session)
	local entry = table.remove(session.entries, 1)
	if entry then
		session.queuedUserIds[entry.userId] = nil
	end
	return entry
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
		RuntimeGuard.Run("PlotAlienEventService.SnapshotOwner." .. tostring(userId), function()
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
				warn("[PlotAlienEventService] Snapshot failed after alien mutation for user " .. tostring(userId))
			end
		end)
	end)
end

local function runPlotVisit(session, entry)
	if not entryStillEligible(session, entry) then
		return false
	end
	local zapCount = rng:NextInteger(session.settings.minZapsPerVisit, session.settings.maxZapsPerVisit)
	local visitStartsAt = serverNow()
	local visitEndsAt = math.min(visitStartsAt + session.settings.plotVisitSeconds, session.endsAt - session.settings.windDownSeconds)
	session.phase = "plotVisit"
	session.currentPlotCenter = entry.plotCenter
	session.currentVisitEndsAt = visitEndsAt
	fireViewers(session, "plotVisit", {
		instanceId = session.instanceId,
		userId = entry.userId,
		plot = entry.plot,
		plotCenter = entry.plotCenter,
		startsAt = visitStartsAt,
		endsAt = visitEndsAt,
		settings = session.publicSettings,
	})
	local displayName = entry.player.DisplayName ~= "" and entry.player.DisplayName or entry.player.Name
	notifyViewers(session, string.format("A UFO is hovering over %s's plot", displayName), 5)

	if not cancellableWait(session, math.min(session.settings.ufoTravelSeconds, math.max(visitEndsAt - serverNow(), 0))) then
		return false
	end

	local ranAnyZap = false
	local zapCycleSeconds = math.min(session.settings.zapAppearSeconds, 0.25)
		+ session.settings.zapAppearSeconds
		+ 0.1
		+ session.settings.zapFadeSeconds
		+ 0.05
	-- Spread the visit's zaps across the remaining hover window so a longer
	-- plotVisitSeconds gives more breathing room between zaps, never tighter
	-- than a single zap VFX cycle.
	local zapWindow = math.max(visitEndsAt - serverNow(), 0)
	local zapInterval = math.max(zapWindow / math.max(zapCount, 1), zapCycleSeconds)
	for zapIndex = 1, zapCount do
		if not sessionActive(session) or serverNow() >= visitEndsAt then
			break
		end
		if not entryStillEligible(session, entry) then
			break
		end
		if visitEndsAt - serverNow() < zapCycleSeconds then
			break
		end
		local target = chooseVisitTarget(session, entry)
		if not target then
			break
		end
		if not targetStillValid(target, session.settings.mutationId) then
			continue
		end
		local applied, result = FeedMachines.ApplyMutation(target.machine, target.targetKey, session.settings.mutationId)
		if applied then
			ranAnyZap = true
			scheduleOwnerSnapshot(session, entry)
			local targetPosition = result and result.position or target.position
			local xpMultiplier = Mutations.XPMultiplier(session.settings.mutationId) or 1
			notifyPlayer(entry.player, string.format(
				"Your %s has been zapped by aliens! (x%s XP)",
				displayNameForFood((result and result.foodId) or target.foodId),
				multiplierLabel(xpMultiplier)
			), 5)
			fireViewers(session, "zap", {
				instanceId = session.instanceId,
				zapId = string.format("%s_%d_%d_%d", session.instanceId, entry.userId, session.visitSequence or 0, zapIndex),
				serverTime = serverNow(),
				mutationId = session.settings.mutationId,
				targetPosition = targetPosition,
				plotCenter = entry.plotCenter,
				zapSoundRange = session.settings.zapSoundRange,
				settings = session.publicSettings,
			})
			if not cancellableWait(session, math.min(zapInterval, math.max(visitEndsAt - serverNow(), 0))) then
				break
			end
		end
	end
	return ranAnyZap
end

-- Runs after every consumed turn -- including skipped/ineligible ones, so a
-- server full of saturated plots cannot degenerate into rapid-fire visits.
-- The UFO breaks off and laps the map, throttling the mutation rate without
-- shortening the hover itself. Clamped so it never eats into the wind-down.
local function runInterVisitRoam(session)
	local roamSeconds = session.settings.interVisitRoamSeconds
	if roamSeconds <= 0 then
		return
	end
	local roamEndsAt = math.min(serverNow() + roamSeconds, session.endsAt - session.settings.windDownSeconds)
	if roamEndsAt <= serverNow() then
		return
	end
	session.phase = "roam"
	session.currentPlotCenter = nil
	session.currentVisitEndsAt = nil
	session.currentRoamEndsAt = roamEndsAt
	fireViewers(session, "roam", {
		instanceId = session.instanceId,
		startsAt = serverNow(),
		endsAt = roamEndsAt,
		roamSeed = session.visitSequence,
		mapCenter = session.mapCenter,
		settings = session.publicSettings,
	})
	cancellableWait(session, math.max(roamEndsAt - serverNow(), 0))
	session.currentRoamEndsAt = nil
end

-- The global/admin record owns the fixed 30-minute failsafe. With no turns
-- queued the UFO idles and keeps polling for fresh joiners or newly-grown
-- targets instead of winding down before the operator stops it.
local ENTRY_POLL_SECONDS = 1
local function waitForNewEntries(session)
	session.phase = "waitingForPlayers"
	session.currentPlotCenter = nil
	session.currentVisitEndsAt = nil
	session.currentRoamEndsAt = nil
	while sessionActive(session) and serverNow() < session.endsAt - session.settings.windDownSeconds do
		if refreshVisitQueue(session) > 0 then
			return true
		end
		task.wait(ENTRY_POLL_SECONDS)
	end
	return false
end

local function runAlien(session)
	session.phase = "windUp"
	fireViewers(session, "start", {
		instanceId = session.instanceId,
		startsAt = session.startsAt,
		endsAt = session.endsAt,
		settings = session.publicSettings,
		mapCenter = session.mapCenter,
	})
	startViewerSync(session)
	if not cancellableWait(session, math.max((session.startsAt + session.settings.windUpSeconds) - serverNow(), 0)) then
		return
	end

	local ranAnyVisit = false
	while sessionActive(session) do
		if serverNow() >= session.endsAt - session.settings.windDownSeconds then
			break
		end
		refreshVisitQueue(session)

		local entry = nextQueuedEntry(session)
		if entry then
			session.visitSequence += 1
			if entryStillEligible(session, entry) then
				ranAnyVisit = runPlotVisit(session, entry) or ranAnyVisit
				session.completedTurnsByUserId[entry.userId] = (session.completedTurnsByUserId[entry.userId] or 0) + 1
			end
			runInterVisitRoam(session)
		elseif not waitForNewEntries(session) then
			break
		end
	end

	if not sessionActive(session) then
		return
	end
	session.phase = "windDown"
	session.currentPlotCenter = nil
	session.currentVisitEndsAt = nil
	session.currentRoamEndsAt = nil
	-- One shot per server: an early wind-down suppresses this instance locally
	-- until endsAt whether or not any zaps landed, so a still-active global
	-- record cannot restart the alien on this server.
	local earlyWindDown = serverNow() < session.endsAt - session.settings.windDownSeconds - 0.1
	if earlyWindDown then
		session.suppressActiveRecord()
	end
	fireViewers(session, "windDown", {
		instanceId = session.instanceId,
		startsAt = serverNow(),
		endsAt = math.min(serverNow() + session.settings.windDownSeconds, session.endsAt),
		ranAnyVisit = ranAnyVisit,
	})
	cancellableWait(session, session.settings.windDownSeconds)
	if not sessionActive(session) then
		return
	end
	fireViewers(session, "end", {
		instanceId = session.instanceId,
	})
	session.complete()
end

local function cleanupFailedAlien(session)
	if type(session) ~= "table" or session.failureCleanupDone then
		return
	end
	session.failureCleanupDone = true
	session.cancelled = true
	if not session.loggedEnd then
		session.loggedEnd = true
		printAlienLifecycle("end", session, "failed")
	end
	RuntimeGuard.Run("PlotAlienEventService.FailedEnd." .. tostring(session.instanceId), function()
		fireViewers(session, "end", {
			instanceId = session.instanceId,
		})
	end)
	if type(session.complete) == "function" then
		RuntimeGuard.Run("PlotAlienEventService.FailedComplete." .. tostring(session.instanceId), session.complete)
	end
end

local function runAlienGuarded(session)
	local ok, err = RuntimeGuard.Try("PlotAlienEventService.Run." .. tostring(session and session.instanceId), runAlien, session)
	if ok then
		return
	end
	warn(err)
	cleanupFailedAlien(session)
end

function PlotAlienEventService.StartAlien(eventRecord, callbacks)
	if type(eventRecord) ~= "table" then
		return
	end
	if activeSession then
		PlotAlienEventService.StopAlien(activeSession.instanceId)
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
		publicSettings = {
			windUpSeconds = settings.windUpSeconds,
			windDownSeconds = settings.windDownSeconds,
			plotVisitSeconds = settings.plotVisitSeconds,
			interVisitRoamSeconds = settings.interVisitRoamSeconds,
			ufoTravelSeconds = settings.ufoTravelSeconds,
			ufoMaxTiltDegrees = settings.ufoMaxTiltDegrees,
			zapAppearSeconds = settings.zapAppearSeconds,
			zapFadeSeconds = settings.zapFadeSeconds,
			zapSoundRange = settings.zapSoundRange,
		},
		mapCenter = mapCenter(),
		entries = {},
		queuedUserIds = {},
		completedTurnsByUserId = {},
		visitSequence = 0,
		syncedViewers = {},
		snapshotProfileState = callbacks.snapshotProfileState,
		snapshotTokens = {},
		cancelled = false,
		suppressedActiveRecord = false,
		phase = "idle",
	}
	session.suppressActiveRecord = function()
		if session.suppressedActiveRecord then
			return
		end
		session.suppressedActiveRecord = true
		if type(callbacks.complete) == "function" then
			callbacks.complete(session.instanceId, {
				blockLowerPriorityUntil = session.endsAt,
				keepHandlerRunning = true,
			})
		end
	end
	session.complete = function()
		if not session.loggedEnd then
			session.loggedEnd = true
			printAlienLifecycle("end", session, "completed")
		end
		if activeSession == session then
			activeSession = nil
		end
		if not session.suppressedActiveRecord and type(callbacks.complete) == "function" then
			callbacks.complete(session.instanceId)
		end
	end
	activeSession = session
	refreshVisitQueue(session)
	printAlienLifecycle("start", session, string.format("visits=%d", #session.entries))
	notifyLoadedNonOnboarding("Aliens are invading...", 5)

	RuntimeGuard.Spawn("PlotAlienEventService.RunGuarded." .. session.instanceId, runAlienGuarded, session)
end

function PlotAlienEventService.StopAlien(instanceId)
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
		printAlienLifecycle("end", session, "stopped")
	end
	-- Operator stops fade out like a natural wind-down instead of hard-cutting.
	-- The delayed "end" is instanceId-guarded on the client, so a new alien
	-- starting inside the fade window is not torn down by the old instance.
	local windDownSeconds = session.settings.windDownSeconds
	session.phase = "windDown"
	session.currentPlotCenter = nil
	session.currentVisitEndsAt = nil
	session.currentRoamEndsAt = nil
	fireViewers(session, "windDown", {
		instanceId = session.instanceId,
		startsAt = serverNow(),
		endsAt = serverNow() + windDownSeconds,
	})
	activeSession = nil
	task.delay(windDownSeconds, function()
		fireViewers(session, "end", {
			instanceId = session.instanceId,
		})
	end)
end

return PlotAlienEventService
