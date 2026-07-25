-- Bee event session: one shared swarm of 9 bees leaves the Honeycomb hive and
-- visits eligible players' farms one at a time (a serial turn queue, ported
-- from PlotTornadoService). Each 60s farm turn pollinates 4-6 foods via 15s
-- hovers running concurrently on distinct bees.
--
-- The server never simulates flight. Each turn it authors a deterministic
-- schedule (RNG seed, unlocked-cell rects, pollination targets with absolute
-- hover windows) and broadcasts it once; every client derives identical bee
-- positions from BeeEvent.Flight as a pure function of the synced clock.
-- Mutations are applied server-side at each hover's scheduled end, with the
-- same revalidation the storm events use.
--
-- Queue semantics match the tornado: the initial queue is built at start
-- (nearest-neighbor from the hive so farm-to-farm transit legs stay short),
-- joins mid-event append a full turn and extend the published endsAt, leaves
-- remove queued turns, and everything clamps to capEndsAt (the config-max
-- 570s window from GameEvents.BeeTimings).
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
local BeeEvent = require(Shared:WaitForChild("BeeEvent"))
local Food = require(Shared:WaitForChild("Food"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlotBeeService = {}

local BeeEventEffect = Remotes.get(Remotes.Names.BeeEventEffect)

local WAIT_STEP = 0.25
local VIEWER_SYNC_SECONDS = 1
local SNAPSHOT_DEBOUNCE_SECONDS = 2
-- Minimum lead-in before the first hover can start after the swarm arrives.
local FIRST_HOVER_DELAY_SECONDS = 4
-- Hovers must finish at least this long before the turn ends so the bee
-- visibly resumes roaming.
local HOVER_END_MARGIN_SECONDS = 1
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

local function printBeeLifecycle(action, session, detail)
	local suffix = ""
	if detail ~= nil and detail ~= "" then
		suffix = " " .. tostring(detail)
	end
	print(string.format(
		"[PlotBeeService] Bee event %s %s (%d -> %d)%s",
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
	local config = GameEvents.GetEvent(GameEvents.Ids.Bee) or {}
	local bee = type(config.bee) == "table" and config.bee or {}
	local windUpSeconds, activeSeconds, windDownSeconds, totalSeconds = GameEvents.BeeTimings(config)
	local minPollinations = math.max(integerValue(bee.minPollinationsPerPlot, 4), 1)
	local maxPollinations = math.max(integerValue(bee.maxPollinationsPerPlot, 6), minPollinations)
	local travelMin = math.max(numberValue(bee.travelMinSeconds, 3), 0.5)
	return {
		mutationId = config.appliedMutationId or Mutations.Ids.Pollinated,
		windUpSeconds = windUpSeconds,
		activeSeconds = activeSeconds,
		windDownSeconds = windDownSeconds,
		totalSeconds = totalSeconds,
		plotTurnSeconds = math.max(numberValue(bee.plotTurnSeconds, 60), 20),
		maxPlotTurns = integerValue(bee.maxPlotTurns, 8),
		travelEstimateSeconds = math.max(numberValue(bee.travelEstimateSeconds, 9), 0),
		transitSpeedStuds = math.max(numberValue(bee.transitSpeedStuds, 18), 1),
		travelMinSeconds = travelMin,
		travelMaxSeconds = math.max(numberValue(bee.travelMaxSeconds, 30), travelMin),
		emptyQueueGraceSeconds = math.max(numberValue(bee.emptyQueueGraceSeconds, 10), 0),
		minPollinationsPerPlot = minPollinations,
		maxPollinationsPerPlot = maxPollinations,
		hoverSeconds = math.max(numberValue(bee.hoverSeconds, 15), 1),
		hoverHeightStuds = numberValue(bee.hoverHeightStuds, 2),
		hoverOrbitRadius = numberValue(bee.hoverOrbitRadius, 1.2),
		hoverOrbitPeriod = numberValue(bee.hoverOrbitPeriod, 3),
		beesPerSwarm = math.clamp(integerValue(bee.beesPerSwarm, BeeEvent.BeeCount), 1, BeeEvent.BeeCount),
		altitudeMin = numberValue(bee.altitudeMin, 3),
		altitudeMax = numberValue(bee.altitudeMax, 6),
		bobAmplitude = numberValue(bee.bobAmplitude, 0.5),
		bobPeriod = numberValue(bee.bobPeriod, 1.6),
		roamSpeedStuds = math.max(numberValue(bee.roamSpeedStuds, 9), 0.5),
		waypointPauseChance = numberValue(bee.waypointPauseChance, 0.25),
		pauseSecondsMin = numberValue(bee.pauseSecondsMin, 0.5),
		pauseSecondsMax = numberValue(bee.pauseSecondsMax, 1.5),
		segmentSecondsMin = numberValue(bee.segmentSecondsMin, 1.5),
		segmentSecondsMax = numberValue(bee.segmentSecondsMax, 4),
		wingFlapHz = numberValue(bee.wingFlapHz, 13),
		wingFlapRadians = numberValue(bee.wingFlapRadians, math.rad(55)),
		maxBankRadians = numberValue(bee.maxBankRadians, math.rad(35)),
		cellPaddingStuds = math.max(numberValue(bee.cellPaddingStuds, 2), 0),
		targetRetrySeconds = math.max(numberValue(bee.targetRetrySeconds, 2), 0),
		buzzMinSeconds = numberValue(bee.buzzMinSeconds, 10),
		buzzMaxSeconds = numberValue(bee.buzzMaxSeconds, 30),
		buzzSoundRange = numberValue(bee.buzzSoundRange, 70),
	}
end

-- Everything the client flight sim needs; all plain numbers/strings.
local function publicSettingsFor(settings)
	return table.clone(settings)
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

local function hivePosition()
	local mesh = BeeEvent.FindHiveMesh()
	return mesh and mesh.Position or nil
end

-- Initial queue order: greedy nearest-neighbor chain starting at the hive, so
-- the swarm's farm-to-farm transit legs stay short on the ring plot layout.
-- Late joins still append to the end of the queue (storm parity).
local function orderNearestNeighbor(entries, fromPosition)
	local remaining = table.clone(entries)
	local ordered = {}
	local cursor = fromPosition
	while #remaining > 0 do
		local bestIndex = 1
		if cursor then
			local bestDistance = math.huge
			for index, entry in ipairs(remaining) do
				local distance = (entry.plotCenter - cursor).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					bestIndex = index
				end
			end
		end
		local entry = table.remove(remaining, bestIndex)
		ordered[#ordered + 1] = entry
		cursor = entry.plotCenter
	end
	return ordered
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
	entries = orderNearestNeighbor(entries, hivePosition())
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
	RuntimeGuard.Run("PlotBeeService.FireClient." .. tostring(command), function()
		BeeEventEffect:FireClient(player, command, payload)
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
		spawnPositions = session.spawnPositions,
		currentTurn = session.currentTurn,
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
	RuntimeGuard.Run("PlotBeeService.NotifyPlayer", function()
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
	RuntimeGuard.Spawn("PlotBeeService.ViewerSync." .. session.instanceId, function()
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

-- Session endsAt tracks the committed schedule: the in-flight turn, queued
-- turns at (plotTurnSeconds + travelEstimateSeconds) each, the trailing
-- empty-queue linger, then wind-down (which covers the return flight) --
-- clamped to capEndsAt. Joins extend it, leaves shrink it, and the published
-- record follows via updateEndsAt so the HUD countdown stays honest.
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
	local perTurnSeconds = settings.plotTurnSeconds + settings.travelEstimateSeconds
	local endsAt = math.min(
		base + queuedTurnsRemaining(session) * perTurnSeconds + trailing,
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

-- A new turn is only accepted while a FULL turn (transit + 60s) can still
-- finish before the cap -- late joiners never get partial visits.
local function canScheduleEntry(session)
	local settings = session.settings
	local latestTurnEnd = session.capEndsAt - settings.windDownSeconds
	return sessionActive(session)
		and #session.entries < settings.maxPlotTurns
		and serverNow() + settings.travelMinSeconds + settings.plotTurnSeconds <= latestTurnEnd
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
		RuntimeGuard.Run("PlotBeeService.SnapshotOwner." .. tostring(userId), function()
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
				warn("[PlotBeeService] Snapshot failed after pollination for user " .. tostring(userId))
			end
		end)
	end)
end

local function clearTurnState(session)
	session.currentTurn = nil
	session.currentTurnEndsAt = nil
end

-- Picks the turn's pollination targets and assigns each a distinct bee with an
-- absolute hover window inside [arrival + lead-in, turnEnd - hover - margin].
-- Distinct bees mean every hover runs concurrently without re-planning.
local function buildPollinationSchedule(session, entry, turnStartsAt, turnEndsAt)
	local settings = session.settings
	local targets = collectTargets(entry.plot, settings.mutationId)
	if #targets == 0 then
		return {}
	end
	-- Shuffle targets, then take up to the rolled pollination count.
	for index = #targets, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		targets[index], targets[swapIndex] = targets[swapIndex], targets[index]
	end
	local desired = rng:NextInteger(settings.minPollinationsPerPlot, settings.maxPollinationsPerPlot)
	local count = math.min(desired, #targets, settings.beesPerSwarm)

	local beeIndices = {}
	for index = 1, settings.beesPerSwarm do
		beeIndices[index] = index
	end
	for index = #beeIndices, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		beeIndices[index], beeIndices[swapIndex] = beeIndices[swapIndex], beeIndices[index]
	end

	local earliest = turnStartsAt + FIRST_HOVER_DELAY_SECONDS
	local latest = turnEndsAt - settings.hoverSeconds - HOVER_END_MARGIN_SECONDS
	if latest < earliest then
		latest = earliest
	end

	local pollinations = {}
	for index = 1, count do
		local target = targets[index]
		local hoverStartsAt = rng:NextNumber(earliest, latest)
		pollinations[index] = {
			index = index,
			beeIndex = beeIndices[index],
			targetPosition = target.position,
			machine = target.machine,
			targetKey = target.targetKey,
			foodId = target.foodId,
			hoverStartsAt = hoverStartsAt,
			hoverEndsAt = hoverStartsAt + settings.hoverSeconds,
		}
	end
	table.sort(pollinations, function(left, right)
		return left.hoverEndsAt < right.hoverEndsAt
	end)
	return pollinations
end

local function applyPollination(session, entry, pollination)
	local target = {
		machine = pollination.machine,
		targetKey = pollination.targetKey,
		position = pollination.targetPosition,
		foodId = pollination.foodId,
	}
	if not targetStillValid(target, session.settings.mutationId) then
		return
	end
	local applied, result = FeedMachines.ApplyMutation(target.machine, target.targetKey, session.settings.mutationId)
	if not applied then
		return
	end
	scheduleOwnerSnapshot(session, entry)
	local xpMultiplier = Mutations.XPMultiplier(session.settings.mutationId) or 1
	notifyPlayer(entry.player, string.format(
		"Your %s has been pollinated by the bees! (x%s XP)",
		displayNameForFood((result and result.foodId) or target.foodId),
		multiplierLabel(xpMultiplier)
	), 5)
	fireViewers(session, "pollinated", {
		instanceId = session.instanceId,
		userId = entry.userId,
		pollinationIndex = pollination.index,
		mutationId = session.settings.mutationId,
		targetPosition = (result and result.position) or target.position,
		foodId = (result and result.foodId) or target.foodId,
	})
end

local function runPlotTurn(session, entry)
	if not entryStillEligible(session, entry) then
		return "skipped"
	end
	local floor = PlotService.GetFloor(entry.plot)
	if not floor then
		return "skipped"
	end
	local settings = session.settings
	local now = serverNow()
	-- The swarm flies from wherever it is (hive or the previous farm) at its
	-- transit pace; the leg length is real distance, never artificially fast.
	local travelDistance = (entry.plotCenter - session.swarmFrom).Magnitude
	local travelSeconds = math.clamp(travelDistance / settings.transitSpeedStuds, settings.travelMinSeconds, settings.travelMaxSeconds)
	local turnStartsAt = now + travelSeconds
	local latestTurnEnd = session.capEndsAt - settings.windDownSeconds
	local turnEndsAt = turnStartsAt + settings.plotTurnSeconds
	-- Full visits only: a turn that cannot run its whole length under the cap
	-- is not started (the owner spectates; next event is at most an hour out).
	if turnEndsAt > latestTurnEnd then
		return "no-fit"
	end

	local cells = PlotGridService.UnlockedCellBounds(entry.plot, settings.cellPaddingStuds) or {}
	local pollinations = buildPollinationSchedule(session, entry, turnStartsAt, turnEndsAt)
	local seed = rng:NextInteger(0, 0x3FFFFFFF)

	local turnPayload = {
		instanceId = session.instanceId,
		userId = entry.userId,
		plot = entry.plot,
		plotCenter = entry.plotCenter,
		floorCFrame = floor.CFrame,
		floorSize = floor.Size,
		seed = seed,
		cells = cells,
		swarmFrom = session.swarmFrom,
		travelSeconds = travelSeconds,
		startsAt = turnStartsAt,
		endsAt = turnEndsAt,
		pollinations = pollinations,
		settings = session.publicSettings,
	}
	session.phase = "plotTurn"
	session.currentTurn = turnPayload
	session.currentTurnEndsAt = turnEndsAt
	recomputeEndsAt(session)
	fireViewers(session, "plotTurn", turnPayload)
	local displayName = entry.player.DisplayName ~= "" and entry.player.DisplayName or entry.player.Name
	notifyViewers(session, string.format("The bees are swarming %s's plot", displayName), 5)

	-- Hovers are sorted by end time; walk them, applying each mutation at its
	-- scheduled hover end (server-timed and authoritative -- clients derive
	-- the same instant from the same schedule).
	local aborted = false
	for _, pollination in ipairs(pollinations) do
		if not cancellableWait(session, math.max(pollination.hoverEndsAt - serverNow(), 0)) then
			return "cancelled"
		end
		if not entryStillEligible(session, entry) then
			aborted = true
			break
		end
		-- Players who become eligible mid-turn join the queue (and extend the
		-- timer) here rather than waiting for the next turn boundary.
		scheduleNewlyEligibleEntries(session)
		applyPollination(session, entry, pollination)
	end

	if aborted then
		fireViewers(session, "plotLeave", {
			instanceId = session.instanceId,
			userId = entry.userId,
		})
		session.swarmFrom = entry.plotCenter
		return "aborted"
	end

	-- Pollinations land before the turn is up, but the swarm visibly keeps
	-- roaming the farm until turnEndsAt -- hold the turn to match, so the
	-- schedule keeps its minute-per-farm shape and late joiners keep queueing.
	while sessionActive(session) and serverNow() < turnEndsAt do
		if not entryStillEligible(session, entry) then
			fireViewers(session, "plotLeave", {
				instanceId = session.instanceId,
				userId = entry.userId,
			})
			break
		end
		if not cancellableWait(session, math.min(2, turnEndsAt - serverNow())) then
			return "cancelled"
		end
		scheduleNewlyEligibleEntries(session)
	end
	session.swarmFrom = entry.plotCenter
	return "completed"
end

-- With the turn queue empty the swarm lingers briefly instead of flying home,
-- so a player who joins right as the last turn ends still gets one.
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

local function runBees(session)
	session.phase = "windUp"
	fireViewers(session, "start", {
		instanceId = session.instanceId,
		startsAt = session.startsAt,
		endsAt = session.endsAt,
		settings = session.publicSettings,
		spawnPositions = session.spawnPositions,
	})
	startViewerSync(session)
	if not cancellableWait(session, math.max((session.startsAt + session.settings.windUpSeconds) - serverNow(), 0)) then
		return
	end

	local ranAnyTurn = false
	while sessionActive(session) do
		if not canScheduleEntry(session) and queuedTurnsRemaining(session) == 0 then
			break
		end
		scheduleNewlyEligibleEntries(session)

		local entry = nextQueuedEntry(session)
		if entry then
			local outcome = runPlotTurn(session, entry)
			if outcome == "cancelled" then
				return
			end
			if outcome == "no-fit" then
				break
			end
			ranAnyTurn = ranAnyTurn or outcome == "completed" or outcome == "aborted"
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
		spawnPositions = session.spawnPositions,
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

local function cleanupFailedSession(session)
	if type(session) ~= "table" or session.failureCleanupDone then
		return
	end
	session.failureCleanupDone = true
	session.cancelled = true
	disconnectSessionConnections(session)
	if not session.loggedEnd then
		session.loggedEnd = true
		printBeeLifecycle("end", session, "failed")
	end
	RuntimeGuard.Run("PlotBeeService.FailedEnd." .. tostring(session.instanceId), function()
		fireViewers(session, "end", {
			instanceId = session.instanceId,
		})
	end)
	if type(session.complete) == "function" then
		RuntimeGuard.Run("PlotBeeService.FailedComplete." .. tostring(session.instanceId), session.complete)
	end
end

local function runBeesGuarded(session)
	local ok, err = RuntimeGuard.Try("PlotBeeService.Run." .. tostring(session and session.instanceId), runBees, session)
	if ok then
		return
	end
	warn(err)
	cleanupFailedSession(session)
end

function PlotBeeService.StartBee(eventRecord, callbacks)
	if type(eventRecord) ~= "table" then
		return
	end
	if activeSession then
		PlotBeeService.StopBee(activeSession.instanceId)
	end
	callbacks = type(callbacks) == "table" and callbacks or {}

	local settings = settingsFor()
	local startsAt = numberValue(eventRecord.startsAt, serverNow())
	local endsAt = numberValue(eventRecord.endsAt, startsAt + settings.totalSeconds)
	-- A restart mid-window re-derives the occurrence with startsAt in the
	-- past; if the remaining window cannot fit even one full turn, complete
	-- immediately instead of flying an empty swarm.
	if serverNow() + settings.windUpSeconds + settings.travelMinSeconds + settings.plotTurnSeconds
		> endsAt - settings.windDownSeconds then
		if type(callbacks.complete) == "function" then
			callbacks.complete(tostring(eventRecord.instanceId or ""), nil)
		end
		return
	end

	local initialEntries = eligibleEntries(settings.mutationId, settings.maxPlotTurns)
	local spawnPositions = BeeEvent.HiveSpawnPositions()
	if not spawnPositions then
		warn("[PlotBeeService] Missing Workspace.Map.BeeEvent hive spawns; bees will emerge at the first farm")
	end
	local session = {
		instanceId = tostring(eventRecord.instanceId or ""),
		startsAt = startsAt,
		endsAt = endsAt,
		-- The record's endsAt is the hard ceiling; session.endsAt floats below
		-- it as the turn queue grows and shrinks.
		capEndsAt = endsAt,
		updateEndsAt = callbacks.updateEndsAt,
		settings = settings,
		publicSettings = publicSettingsFor(settings),
		spawnPositions = spawnPositions,
		swarmFrom = hivePosition() or (initialEntries[1] and initialEntries[1].plotCenter) or Vector3.zero,
		entries = initialEntries,
		nextEntryIndex = 1,
		scheduledByUserId = scheduledMapFor(initialEntries),
		syncedViewers = {},
		snapshotProfileState = callbacks.snapshotProfileState,
		snapshotTokens = {},
		cancelled = false,
		phase = "idle",
	}
	session.complete = function()
		if not session.loggedEnd then
			session.loggedEnd = true
			printBeeLifecycle("end", session, "completed")
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
		RuntimeGuard.Run("PlotBeeService.PlayerRemoving." .. session.instanceId, function()
			removeQueuedEntriesFor(session, player)
		end)
	end)
	activeSession = session
	recomputeEndsAt(session)
	printBeeLifecycle("start", session, string.format("entries=%d", #session.entries))

	RuntimeGuard.Spawn("PlotBeeService.RunGuarded." .. session.instanceId, runBeesGuarded, session)
end

function PlotBeeService.NotifyBeesApproaching()
	local config = GameEvents.GetEvent(GameEvents.Ids.Bee) or {}
	local text = config.preNoticeText or "You hear buzzing in the distance..."
	local lifetime = math.max(numberValue(config.preNoticeSeconds, 5), 0)
	notifyLoadedNonOnboarding(text, lifetime)
end

function PlotBeeService.StopBee(instanceId)
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
		printBeeLifecycle("end", session, "stopped")
	end
	fireViewers(session, "end", {
		instanceId = session.instanceId,
	})
	activeSession = nil
end

return PlotBeeService
