local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local EventEligibility = require(Server:WaitForChild("EventEligibility"))
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotGridService = require(Server:WaitForChild("PlotGridService"))
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlotTornadoService = {}

local TornadoEffect = Remotes.get(Remotes.Names.TornadoEffect)

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

local function printTornadoLifecycle(action, session, detail)
	local suffix = ""
	if detail ~= nil and detail ~= "" then
		suffix = " " .. tostring(detail)
	end
	print(string.format(
		"[PlotTornadoService] Tornado %s %s (%d -> %d)%s",
		tostring(action),
		tostring(session.instanceId),
		math.floor(tonumber(session.startsAt) or 0),
		math.floor(tonumber(session.endsAt) or 0),
		suffix
	))
end

local function integerValue(value, fallback)
	return math.max(math.floor(numberValue(value, fallback)), 0)
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
	local config = GameEvents.GetEvent(GameEvents.Ids.Tornado) or {}
	local tornado = type(config.tornado) == "table" and config.tornado or {}
	local windUpSeconds, activeSeconds, windDownSeconds, totalSeconds = GameEvents.TornadoTimings(config)
	local minMutations = integerValue(tornado.minMutationsPerPlot, 2)
	local maxMutations = math.max(integerValue(tornado.maxMutationsPerPlot, 6), minMutations)
	return {
		mutationId = config.appliedMutationId or Mutations.Ids.Twisted,
		windUpSeconds = windUpSeconds,
		activeSeconds = activeSeconds,
		windDownSeconds = windDownSeconds,
		totalSeconds = totalSeconds,
		plotTurnSeconds = math.max(numberValue(tornado.plotTurnSeconds, 20), 0),
		maxPlotTurns = integerValue(tornado.maxPlotTurns, 8),
		emptyQueueGraceSeconds = math.max(numberValue(tornado.emptyQueueGraceSeconds, 30), 0),
		minMutationsPerPlot = minMutations,
		maxMutationsPerPlot = maxMutations,
		targetRetrySeconds = math.max(numberValue(tornado.targetRetrySeconds, 2), 0),
		tornadoSoundRange = math.max(numberValue(tornado.tornadoSoundRange, 500), 0),
		funnelTouchdownSeconds = math.max(numberValue(tornado.funnelTouchdownSeconds, 1), 0),
		funnelTravelSeconds = math.max(numberValue(tornado.funnelTravelSeconds, 4), 0),
		funnelFadeSeconds = math.max(numberValue(tornado.funnelFadeSeconds, 0.75), 0),
		wanderWaypointSeconds = math.max(numberValue(tornado.wanderWaypointSeconds, 2.5), 0.1),
		spinRevolutionsPerSecond = math.max(numberValue(tornado.spinRevolutionsPerSecond, 1.5), 0),
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

local function eligibleEntries(mutationId, maxEntries)
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
	local capped = {}
	for index = 1, math.min(#entries, maxEntries) do
		capped[index] = entries[index]
	end
	return capped
end

local function scheduledMapFor(entries)
	local scheduled = {}
	for _, entry in ipairs(entries or {}) do
		if entry.userId then
			scheduled[entry.userId] = true
		end
	end
	return scheduled
end

local function fireViewer(player, command, payload)
	RuntimeGuard.Run("PlotTornadoService.FireClient." .. tostring(command), function()
		TornadoEffect:FireClient(player, command, payload)
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
		currentPlotCenter = session.currentPlotCenter,
		currentTurnStartsAt = session.currentTurnStartsAt,
		currentTurnEndsAt = session.currentTurnEndsAt,
		currentFloorCFrame = session.currentFloorCFrame,
		currentFloorSize = session.currentFloorSize,
		currentWaypoints = session.currentWaypoints,
		currentTravelSeconds = session.currentTravelSeconds,
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
	RuntimeGuard.Run("PlotTornadoService.NotifyPlayer", function()
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
	-- UserId) counts as a fresh viewer and gets a full state sync instead of
	-- waiting for the next plotTurn broadcast to rebuild their visuals.
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
	RuntimeGuard.Spawn("PlotTornadoService.ViewerSync." .. session.instanceId, function()
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

local function queuedTurnsRemaining(session)
	return math.max(#session.entries - ((session.nextEntryIndex or 1) - 1), 0)
end

-- Session endsAt tracks the committed schedule -- the in-flight turn, queued
-- turns at plotTurnSeconds each, the trailing empty-queue linger, then
-- wind-down -- clamped to the config-max window (capEndsAt). Joins extend it,
-- leaves shrink it, and the published event record follows via updateEndsAt
-- so the HUD countdown stays honest. The linger is part of the schedule up
-- front so the countdown never bumps upward at the end; once the linger is
-- underway (baseOverride) or wind-down has begun it is already spent.
local function recomputeEndsAt(session, baseOverride)
	local now = serverNow()
	local settings = session.settings
	local base
	if baseOverride then
		base = math.max(baseOverride, now)
	elseif session.phase == "plotTurn" and session.currentTurnEndsAt then
		base = math.max(session.currentTurnEndsAt, now)
	elseif session.phase == "idle" or session.phase == "windUp" then
		base = math.max(session.startsAt + settings.windUpSeconds, now)
	else
		base = now
	end
	local trailing = settings.windDownSeconds
	if not baseOverride and session.phase ~= "windDown" then
		trailing += settings.emptyQueueGraceSeconds
	end
	local endsAt = math.min(
		base + queuedTurnsRemaining(session) * settings.plotTurnSeconds + trailing,
		session.capEndsAt
	)
	if math.abs(endsAt - session.endsAt) < 0.05 then
		return
	end
	session.endsAt = endsAt
	if type(session.updateEndsAt) == "function" then
		session.updateEndsAt(session.instanceId, endsAt)
	end
end

local function canScheduleEntry(session)
	return sessionActive(session)
		and #session.entries < session.settings.maxPlotTurns
		and serverNow() < session.capEndsAt - session.settings.windDownSeconds
end

local function scheduleNewlyEligibleEntries(session)
	if not canScheduleEntry(session) then
		return 0
	end

	local remaining = session.settings.maxPlotTurns - #session.entries
	local added = 0
	for _, entry in ipairs(eligibleEntries(session.settings.mutationId, #Players:GetPlayers())) do
		if added >= remaining then
			break
		end
		if not session.scheduledByUserId[entry.userId] then
			session.scheduledByUserId[entry.userId] = true
			session.entries[#session.entries + 1] = entry
			added += 1
		end
	end
	if added > 0 then
		recomputeEndsAt(session)
	end
	return added
end

-- A leaver's queued (not yet started) turns come off the schedule right away;
-- clearing the scheduled flag lets a rejoin queue a fresh turn. A turn already
-- in flight is aborted by the entryStillEligible checks instead.
local function removeQueuedEntriesFor(session, player)
	local userId = player and player.UserId
	if not (sessionActive(session) and userId) then
		return
	end
	local removed = false
	for index = #session.entries, session.nextEntryIndex or 1, -1 do
		if session.entries[index].userId == userId then
			table.remove(session.entries, index)
			removed = true
		end
	end
	if removed then
		session.scheduledByUserId[userId] = nil
		recomputeEndsAt(session)
	end
end

local function disconnectSessionConnections(session)
	if session.playerRemovingConnection then
		session.playerRemovingConnection:Disconnect()
		session.playerRemovingConnection = nil
	end
end

local function nextQueuedEntry(session)
	local index = session.nextEntryIndex or 1
	local entry = session.entries[index]
	if entry then
		session.nextEntryIndex = index + 1
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
		RuntimeGuard.Run("PlotTornadoService.SnapshotOwner." .. tostring(userId), function()
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
				warn("[PlotTornadoService] Snapshot failed after tornado mutation for user " .. tostring(userId))
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

local function clearTurnState(session)
	session.currentPlotCenter = nil
	session.currentTurnStartsAt = nil
	session.currentTurnEndsAt = nil
	session.currentFloorCFrame = nil
	session.currentFloorSize = nil
	session.currentWaypoints = nil
	session.currentTravelSeconds = nil
end

-- Waypoints are floor-local Vector2s constrained to the plot's unlocked grid
-- cells, so the funnel never wanders over locked ground. Midpoints between
-- consecutive picks are re-rolled a few times toward walkable paths so the
-- funnel avoids cutting across locked corners of L-shaped unlock layouts.
local function buildWanderWaypoints(session, plot, turnSeconds)
	local waypointSeconds = session.settings.wanderWaypointSeconds
	local segments = math.max(math.ceil(math.max(turnSeconds, 1) / waypointSeconds), 1)
	local waypoints = {}
	for index = 1, segments + 1 do
		local lx, lz
		for attempt = 1, 4 do
			lx, lz = PlotGridService.RandomUnlockedPoint(plot, rng)
			if not lx then
				break
			end
			local previous = waypoints[index - 1]
			if not previous
				or PlotGridService.IsWalkablePoint(plot, (previous.X + lx) / 2, (previous.Y + lz) / 2)
				or attempt == 4 then
				break
			end
		end
		if not lx then
			break
		end
		waypoints[index] = Vector2.new(lx, lz)
	end
	if #waypoints == 0 then
		waypoints[1] = Vector2.zero
	end
	if #waypoints == 1 then
		waypoints[2] = waypoints[1]
	end
	return waypoints
end

local function runPlotTurn(session, entry)
	if not entryStillEligible(session, entry) then
		return false
	end
	local floor = PlotService.GetFloor(entry.plot)
	if not floor then
		return false
	end
	local turnStartsAt = serverNow()
	local turnEndsAt = math.min(turnStartsAt + session.settings.plotTurnSeconds, session.capEndsAt - session.settings.windDownSeconds)
	local mutationCount = rng:NextInteger(session.settings.minMutationsPerPlot, session.settings.maxMutationsPerPlot)
	local waypoints = buildWanderWaypoints(session, entry.plot, turnEndsAt - turnStartsAt)
	-- The funnel touches down quickly on the first plot, then travels visibly
	-- from plot to plot; mutations hold until it arrives.
	local travelSeconds = session.ranAnyPlotTurn and session.settings.funnelTravelSeconds
		or session.settings.funnelTouchdownSeconds
	session.ranAnyPlotTurn = true
	session.phase = "plotTurn"
	session.currentPlotCenter = entry.plotCenter
	session.currentTurnStartsAt = turnStartsAt
	session.currentTurnEndsAt = turnEndsAt
	session.currentFloorCFrame = floor.CFrame
	session.currentFloorSize = floor.Size
	session.currentWaypoints = waypoints
	session.currentTravelSeconds = travelSeconds
	recomputeEndsAt(session)
	fireViewers(session, "plotTurn", {
		instanceId = session.instanceId,
		userId = entry.userId,
		plot = entry.plot,
		plotCenter = entry.plotCenter,
		floorCFrame = floor.CFrame,
		floorSize = floor.Size,
		waypoints = waypoints,
		travelSeconds = travelSeconds,
		startsAt = turnStartsAt,
		endsAt = turnEndsAt,
		settings = session.publicSettings,
	})
	local displayName = entry.player.DisplayName ~= "" and entry.player.DisplayName or entry.player.Name
	notifyViewers(session, string.format("The tornado is now over %s's plot", displayName), 5)

	if not cancellableWait(session, math.min(travelSeconds, math.max(turnEndsAt - serverNow(), 0))) then
		return false
	end

	local gap = mutationCount > 0 and (session.settings.plotTurnSeconds / mutationCount) or session.settings.plotTurnSeconds
	for mutationIndex = 1, mutationCount do
		if not sessionActive(session) or serverNow() >= turnEndsAt then
			break
		end
		if not entryStillEligible(session, entry) then
			break
		end
		if mutationIndex > 1 and not cancellableWait(session, math.min(gap, math.max(turnEndsAt - serverNow(), 0))) then
			break
		end
		-- Players who become eligible mid-turn join the queue (and extend the
		-- timer) here rather than waiting for the next turn boundary.
		scheduleNewlyEligibleEntries(session)
		local target = chooseTarget(session, entry, session.settings.targetRetrySeconds)
		if not target or not targetStillValid(target, session.settings.mutationId) then
			break
		end
		local applied, result = FeedMachines.ApplyMutation(target.machine, target.targetKey, session.settings.mutationId)
		if applied then
			scheduleOwnerSnapshot(session, entry)
			local targetPosition = result and result.position or target.position
			local xpMultiplier = Mutations.XPMultiplier(session.settings.mutationId) or 1
			notifyPlayer(entry.player, string.format(
				"Your %s has been twisted by the tornado! (x%s XP)",
				displayNameForFood((result and result.foodId) or target.foodId),
				multiplierLabel(xpMultiplier)
			), 5)
			fireViewers(session, "mutate", {
				instanceId = session.instanceId,
				mutateId = string.format("%s_%d_%d", session.instanceId, entry.userId, mutationIndex),
				serverTime = serverNow(),
				mutationId = session.settings.mutationId,
				targetPosition = targetPosition,
				tornadoSoundRange = session.settings.tornadoSoundRange,
				settings = session.publicSettings,
			})
		end
	end
	-- Mutations usually land before the turn is up, but the funnel visibly
	-- stays on the plot until turnEndsAt -- hold the turn to match, so the
	-- schedule keeps its 45s-per-player shape and late joiners keep queueing.
	while sessionActive(session) and serverNow() < turnEndsAt and entryStillEligible(session, entry) do
		if not cancellableWait(session, math.min(2, turnEndsAt - serverNow())) then
			break
		end
		scheduleNewlyEligibleEntries(session)
	end
	return true
end

-- With the turn queue empty the tornado lingers briefly instead of winding
-- down, so a player who joins right as the last turn ends still gets one.
-- endsAt is held at the linger deadline (plus wind-down) so the HUD matches.
local function waitForNewEntries(session)
	local deadline = math.min(
		serverNow() + session.settings.emptyQueueGraceSeconds,
		session.capEndsAt - session.settings.windDownSeconds
	)
	if serverNow() >= deadline then
		return false
	end
	session.phase = "waitingForPlayers"
	clearTurnState(session)
	recomputeEndsAt(session, deadline)
	while sessionActive(session) and serverNow() < deadline do
		if scheduleNewlyEligibleEntries(session) > 0 then
			return true
		end
		task.wait(math.min(WAIT_STEP, math.max(deadline - serverNow(), 0)))
	end
	return sessionActive(session) and queuedTurnsRemaining(session) > 0
end

local function runTornado(session)
	session.phase = "windUp"
	fireViewers(session, "start", {
		instanceId = session.instanceId,
		startsAt = session.startsAt,
		endsAt = session.endsAt,
		settings = session.publicSettings,
	})
	startViewerSync(session)
	if not cancellableWait(session, math.max((session.startsAt + session.settings.windUpSeconds) - serverNow(), 0)) then
		return
	end

	local ranAnyTurn = false
	while sessionActive(session) do
		if serverNow() >= session.capEndsAt - session.settings.windDownSeconds then
			break
		end
		scheduleNewlyEligibleEntries(session)

		local entry = nextQueuedEntry(session)
		if entry then
			ranAnyTurn = runPlotTurn(session, entry) or ranAnyTurn
		elseif not waitForNewEntries(session) then
			break
		end
	end

	if not sessionActive(session) then
		return
	end
	session.phase = "windDown"
	clearTurnState(session)
	recomputeEndsAt(session, serverNow())
	fireViewers(session, "windDown", {
		instanceId = session.instanceId,
		startsAt = serverNow(),
		endsAt = math.min(serverNow() + session.settings.windDownSeconds, session.endsAt),
		ranAnyTurn = ranAnyTurn,
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

local function cleanupFailedTornado(session)
	if type(session) ~= "table" or session.failureCleanupDone then
		return
	end
	session.failureCleanupDone = true
	session.cancelled = true
	disconnectSessionConnections(session)
	if not session.loggedEnd then
		session.loggedEnd = true
		printTornadoLifecycle("end", session, "failed")
	end
	RuntimeGuard.Run("PlotTornadoService.FailedEnd." .. tostring(session.instanceId), function()
		fireViewers(session, "end", {
			instanceId = session.instanceId,
		})
	end)
	if type(session.complete) == "function" then
		RuntimeGuard.Run("PlotTornadoService.FailedComplete." .. tostring(session.instanceId), session.complete)
	end
end

local function runTornadoGuarded(session)
	local ok, err = RuntimeGuard.Try("PlotTornadoService.Run." .. tostring(session and session.instanceId), runTornado, session)
	if ok then
		return
	end
	warn(err)
	cleanupFailedTornado(session)
end

function PlotTornadoService.StartTornado(eventRecord, callbacks)
	if type(eventRecord) ~= "table" then
		return
	end
	if activeSession then
		PlotTornadoService.StopTornado(activeSession.instanceId)
	end
	callbacks = type(callbacks) == "table" and callbacks or {}

	local settings = settingsFor()
	local startsAt = numberValue(eventRecord.startsAt, serverNow())
	local endsAt = numberValue(eventRecord.endsAt, startsAt + settings.totalSeconds)
	local initialEntries = eligibleEntries(settings.mutationId, settings.maxPlotTurns)
	local session = {
		instanceId = tostring(eventRecord.instanceId or ""),
		startsAt = startsAt,
		endsAt = endsAt,
		-- The record's endsAt is the hard ceiling; session.endsAt floats below
		-- it as the turn queue grows and shrinks.
		capEndsAt = endsAt,
		updateEndsAt = callbacks.updateEndsAt,
		settings = settings,
		publicSettings = {
			windUpSeconds = settings.windUpSeconds,
			windDownSeconds = settings.windDownSeconds,
			tornadoSoundRange = settings.tornadoSoundRange,
			funnelTouchdownSeconds = settings.funnelTouchdownSeconds,
			funnelFadeSeconds = settings.funnelFadeSeconds,
			wanderWaypointSeconds = settings.wanderWaypointSeconds,
			spinRevolutionsPerSecond = settings.spinRevolutionsPerSecond,
		},
		entries = initialEntries,
		nextEntryIndex = 1,
		scheduledByUserId = scheduledMapFor(initialEntries),
		syncedViewers = {},
		snapshotProfileState = callbacks.snapshotProfileState,
		snapshotTokens = {},
		cancelled = false,
		ranAnyPlotTurn = false,
		phase = "idle",
	}
	session.complete = function()
		if not session.loggedEnd then
			session.loggedEnd = true
			printTornadoLifecycle("end", session, "completed")
		end
		disconnectSessionConnections(session)
		if activeSession == session then
			activeSession = nil
		end
		if type(callbacks.complete) == "function" then
			local options = nil
			-- Finishing inside the scheduled window still reserves the rest of
			-- it, so lower-priority events cannot slot into the freed time.
			if serverNow() < session.capEndsAt - 0.1 then
				options = { blockLowerPriorityUntil = session.capEndsAt }
			end
			callbacks.complete(session.instanceId, options)
		end
	end
	session.playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		RuntimeGuard.Run("PlotTornadoService.PlayerRemoving." .. session.instanceId, function()
			removeQueuedEntriesFor(session, player)
		end)
	end)
	activeSession = session
	recomputeEndsAt(session)
	printTornadoLifecycle("start", session, string.format("entries=%d", #session.entries))

	RuntimeGuard.Spawn("PlotTornadoService.RunGuarded." .. session.instanceId, runTornadoGuarded, session)
end

function PlotTornadoService.NotifyTornadoApproaching()
	local config = GameEvents.GetEvent(GameEvents.Ids.Tornado) or {}
	local text = config.preNoticeText or "A tornado is forming..."
	local lifetime = math.max(numberValue(config.preNoticeSeconds, 5), 0)
	notifyLoadedNonOnboarding(text, lifetime)
end

function PlotTornadoService.StopTornado(instanceId)
	local session = activeSession
	if not session then
		return
	end
	if instanceId ~= nil and tostring(instanceId) ~= tostring(session.instanceId) then
		return
	end
	session.cancelled = true
	disconnectSessionConnections(session)
	if not session.loggedEnd then
		session.loggedEnd = true
		printTornadoLifecycle("end", session, "stopped")
	end
	fireViewers(session, "end", {
		instanceId = session.instanceId,
	})
	activeSession = nil
end

return PlotTornadoService
