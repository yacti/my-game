-- Sprinkle: yactiNPC drops onto the island, tours eligible farms with a magic
-- wand, and boosts nearby food XP by +50% over a 5-second wave per stop.
--
-- Structurally this is PlotAlienEventService: an admin-toggled Chaos event with
-- a rolling per-player turn queue, viewer sync, and a hidden failsafe. The parts
-- that differ are the targeting (stops are chosen by where the food actually is,
-- inside unlocked grid cells) and the effect (a stepped XP ramp, not a mutation).
--
-- Server/client split, per the project's event convention: this service owns
-- eligibility, stop selection, timing and the XP writes; it publishes a single
-- "stage" describing what the NPC should be doing between two server timestamps,
-- and SprinkleEventController renders every frame of it locally. No NPC physics,
-- pathfinding or animation crosses the network.

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
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local SprinkleEvent = require(Shared:WaitForChild("SprinkleEvent"))

local PlotSprinkleService = {}

local SprinkleEventEffect = Remotes.get(Remotes.Names.SprinkleEventEffect)

local WAIT_STEP = 0.25
local VIEWER_SYNC_SECONDS = 1
local SNAPSHOT_DEBOUNCE_SECONDS = 2
local ENTRY_POLL_SECONDS = 1
-- Floor under a within-plot hop so a 2-stud correction still reads as a step
-- rather than a teleport. Inter-plot legs use travelMinSeconds instead.
local MIN_WALK_SECONDS = 0.4
local Phases = SprinkleEvent.Phases

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

local function printSprinkleLifecycle(action, session, detail)
	local suffix = ""
	if detail ~= nil and detail ~= "" then
		suffix = " " .. tostring(detail)
	end
	print(string.format(
		"[PlotSprinkleService] Sprinkle %s %s (%d -> %d)%s",
		tostring(action),
		tostring(session.instanceId),
		math.floor(tonumber(session.startsAt) or 0),
		math.floor(tonumber(session.endsAt) or 0),
		suffix
	))
end

local function settingsFor()
	local config = GameEvents.GetEvent(GameEvents.Ids.Sprinkle) or {}
	local sprinkle = type(config.sprinkle) == "table" and config.sprinkle or {}
	-- The active window is implicit: this event ends when its queue drains, not
	-- on a clock, so only the two edges and the ceiling are needed here.
	local windUpSeconds, _, windDownSeconds, totalSeconds = GameEvents.SprinkleTimings(config)
	return {
		windUpSeconds = windUpSeconds,
		windDownSeconds = windDownSeconds,
		totalSeconds = totalSeconds,

		entranceFallStuds = math.max(numberValue(sprinkle.entranceFallStuds, 200), 0),
		exitRiseStuds = math.max(numberValue(sprinkle.exitRiseStuds, 200), 0),

		walkSpeedStuds = math.max(numberValue(sprinkle.walkSpeedStuds, 20), 1),
		travelMinSeconds = math.max(numberValue(sprinkle.travelMinSeconds, 3), 0),
		travelMaxSeconds = math.max(numberValue(sprinkle.travelMaxSeconds, 25), 1),
		turnRateDegrees = math.max(numberValue(sprinkle.turnRateDegrees, 360), 1),
		phaseEaseSeconds = math.max(numberValue(sprinkle.phaseEaseSeconds, 0.4), 0),

		singleStopMaxCells = math.max(integerValue(sprinkle.singleStopMaxCells, 4), 0),
		maxStopsPerPlot = math.max(integerValue(sprinkle.maxStopsPerPlot, 3), 1),
		waveRadiusStuds = math.max(numberValue(sprinkle.waveRadiusStuds, 24), 1),
		minStopSeparationStuds = math.max(numberValue(sprinkle.minStopSeparationStuds, 24), 0),
		standOffsetStuds = math.max(numberValue(sprinkle.standOffsetStuds, 6), 0),

		waveSeconds = math.max(numberValue(sprinkle.waveSeconds, 5), 0.1),
		waveXPMultiplier = math.max(numberValue(sprinkle.waveXPMultiplier, 1.5), 1),
		waveRampSteps = math.max(integerValue(sprinkle.waveRampSteps, 10), 1),
		waveRaiseSeconds = math.max(numberValue(sprinkle.waveRaiseSeconds, 0.6), 0),
		waveLowerSeconds = math.max(numberValue(sprinkle.waveLowerSeconds, 0.6), 0),
		armRaiseDegrees = numberValue(sprinkle.armRaiseDegrees, 100),
		waveSwingDegrees = math.max(numberValue(sprinkle.waveSwingDegrees, 38), 0),
		waveForeAftDegrees = math.max(numberValue(sprinkle.waveForeAftDegrees, 20), 0),
		elbowSwingDegrees = math.max(numberValue(sprinkle.elbowSwingDegrees, 24), 0),
		wristSwingDegrees = math.max(numberValue(sprinkle.wristSwingDegrees, 30), 0),
		headSwingDegrees = math.max(numberValue(sprinkle.headSwingDegrees, 18), 0),
		headNodDegrees = math.max(numberValue(sprinkle.headNodDegrees, 7), 0),
		waistSwingDegrees = math.max(numberValue(sprinkle.waistSwingDegrees, 9), 0),
		waveSwingHz = math.max(numberValue(sprinkle.waveSwingHz, 1.15), 0),

		sparkleBurstCount = math.max(integerValue(sprinkle.sparkleBurstCount, 12), 1),
		sparkleBurstSeconds = math.max(numberValue(sprinkle.sparkleBurstSeconds, 0.15), 0.05),
		magicSoundSeconds = math.max(numberValue(sprinkle.magicSoundSeconds, 1), 0.1),
		magicSoundRange = math.max(numberValue(sprinkle.magicSoundRange, 200), 1),
		magicSoundPitchVariance = math.clamp(numberValue(sprinkle.magicSoundPitchVariance, 0.3), 0, 0.9),

		maxQueuedTurns = math.max(integerValue(sprinkle.maxQueuedTurns, 8), 1),
		emptyQueueGraceSeconds = math.max(numberValue(sprinkle.emptyQueueGraceSeconds, 10), 0),
		interVisitPauseSeconds = math.max(numberValue(sprinkle.interVisitPauseSeconds, 1), 0),
	}
end

---------------------------------------------------------------------------
-- Eligibility and viewer plumbing (identical policy to the Alien event)
---------------------------------------------------------------------------

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

local function fireViewer(player, command, payload)
	RuntimeGuard.Run("PlotSprinkleService.FireClient." .. tostring(command), function()
		SprinkleEventEffect:FireClient(player, command, payload)
	end)
end

local function shouldFireViewer(session, player, command)
	-- A viewer who has already been synced must still receive "end", or their
	-- client is left holding an NPC it will never tear down.
	if command == "end" and session.syncedViewers and session.syncedViewers[player.UserId] then
		return true
	end
	return viewerEligible(session, player)
end

local function startPayload(session)
	return {
		instanceId = session.instanceId,
		startsAt = session.startsAt,
		endsAt = session.endsAt,
		settings = session.publicSettings,
		spawnPosition = session.spawnPosition,
	}
end

local function syncPayload(session)
	local payload = startPayload(session)
	payload.phase = session.phase
	-- The stage is the whole state a client needs: a late joiner replays the
	-- in-flight stage from its own timestamps and lands at the right point on
	-- the leg instead of snapping in from the spawn marker.
	payload.stage = session.stage
	return payload
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
	RuntimeGuard.Run("PlotSprinkleService.NotifyPlayer", function()
		NotificationService.Notify(player, {
			-- Every toast this service sends is a Fairy yacti line, so the hot pink
			-- kind is set here rather than at each call site.
			kind = NotificationConfig.Kinds.Sprinkle,
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
	RuntimeGuard.Spawn("PlotSprinkleService.ViewerSync." .. session.instanceId, function()
		while sessionActive(session) do
			syncNewViewers(session)
			task.wait(VIEWER_SYNC_SECONDS)
		end
	end)
end

---------------------------------------------------------------------------
-- Targeting
---------------------------------------------------------------------------

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

-- Top plane of the plot's grid, which is what the NPC stands on. Derived from
-- the runtime Floor part rather than hardcoded, because the plot template's
-- internal Y planes have been re-authored before.
local function plotGroundY(floor)
	return floor.Position.Y + floor.Size.Y / 2
end

local function flatDistance(a, b)
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function collectPlotTargets(plot)
	local targets = {}
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		for _, target in ipairs(FeedMachines.CollectBoostTargets(feed)) do
			if typeof(target.position) == "Vector3" then
				targets[#targets + 1] = target
			end
		end
	end
	return targets
end

-- Keeps only food standing on an unlocked grid cell. This is what makes the
-- stops "dictated by unlocked GridParts" -- a tree canopy overhanging a locked
-- cell does not pull yacti onto ground the player has not bought yet.
local function unlockedTargetFilter(rects, floor)
	if type(rects) ~= "table" or #rects == 0 then
		return nil
	end
	return function(worldPosition)
		local localPoint = floor.CFrame:PointToObjectSpace(worldPosition)
		for _, rect in ipairs(rects) do
			if localPoint.X >= rect.minX and localPoint.X <= rect.maxX
				and localPoint.Z >= rect.minZ and localPoint.Z <= rect.maxZ then
				return true
			end
		end
		return false
	end
end

-- Where yacti stands for a stop: `standOffsetStuds` back from the area centre
-- toward the middle of the plot, snapped onto walkable unlocked ground. Offsetting
-- inward (rather than outward) keeps him reliably inside the unlocked region, and
-- he then faces outward at the crops so the wand hangs over the target area.
local function standPositionFor(plot, floor, areaCenter, settings)
	local groundY = plotGroundY(floor)
	local centerLocal = floor.CFrame:PointToObjectSpace(areaCenter)
	local direction = Vector2.new(-centerLocal.X, -centerLocal.Z)
	if direction.Magnitude < 0.001 then
		-- The area is dead-centre on the plot; fall back to the floor's -Z.
		direction = Vector2.new(0, -1)
	end
	direction = direction.Unit

	local wantedX = centerLocal.X + direction.X * settings.standOffsetStuds
	local wantedZ = centerLocal.Z + direction.Y * settings.standOffsetStuds
	local localX, localZ = PlotGridService.NearestUnlockedPoint(plot, wantedX, wantedZ, 2, 2)
	if type(localX) ~= "number" or type(localZ) ~= "number" then
		localX, localZ = wantedX, wantedZ
	end

	local world = floor.CFrame:PointToWorldSpace(Vector3.new(localX, 0, localZ))
	return Vector3.new(world.X, groundY, world.Z)
end

-- How many stops this turn gets. Driven by how much plot the player has bought,
-- NOT by how the crops happen to be arranged: a starter farm always gets exactly
-- one sprinkle, and anything bigger gets a random 1-3 so repeat events do not
-- feel identical.
local function stopBudgetFor(settings, unlockedCellCount)
	if unlockedCellCount <= settings.singleStopMaxCells then
		return 1
	end
	return rng:NextInteger(1, settings.maxStopsPerPlot)
end

-- Greedy maximum coverage within that budget: repeatedly stand where the wand
-- covers the most not-yet-covered food, requiring each new stop to sit at least
-- minStopSeparationStuds from every stop already chosen so their areas never
-- overlap. Because a covered target is removed from the pool, the stops of a
-- turn partition the food and nothing is ever boosted twice.
local function chooseStops(plot, floor, targets, settings, stopBudget)
	local remaining = table.clone(targets)
	local stops = {}

	while #stops < stopBudget and #remaining > 0 do
		local bestCandidate, bestCount = nil, 0
		for _, candidate in ipairs(remaining) do
			local farEnough = true
			for _, stop in ipairs(stops) do
				if flatDistance(candidate.position, stop.center) < settings.minStopSeparationStuds then
					farEnough = false
					break
				end
			end
			if farEnough then
				local count = 0
				for _, other in ipairs(remaining) do
					if flatDistance(candidate.position, other.position) <= settings.waveRadiusStuds then
						count += 1
					end
				end
				if count > bestCount then
					bestCandidate, bestCount = candidate, count
				end
			end
		end
		if not bestCandidate then
			break
		end

		local center = bestCandidate.position
		local covered = {}
		for index = #remaining, 1, -1 do
			local target = remaining[index]
			if flatDistance(center, target.position) <= settings.waveRadiusStuds then
				covered[#covered + 1] = target
				table.remove(remaining, index)
			end
		end

		stops[#stops + 1] = {
			center = center,
			targets = covered,
			standPosition = standPositionFor(plot, floor, center, settings),
		}
	end

	return stops
end

---------------------------------------------------------------------------
-- Stage publishing (the single thing clients render)
---------------------------------------------------------------------------

local function publishStage(session, stage)
	session.stage = stage
	session.phase = stage.phase
	fireViewers(session, "stage", stage)
end

-- Where the NPC logically is right now, derived the same way the client derives
-- it. Used so a stop mid-leg lifts off from his real position rather than from
-- the leg's endpoint.
local function currentGroundPosition(session)
	local stage = session.stage
	if type(stage) ~= "table" then
		return session.spawnPosition
	end
	if stage.phase == Phases.Travel or stage.phase == Phases.WalkTo then
		local alpha = SprinkleEvent.EasedProgress(
			serverNow(),
			stage.startsAt,
			stage.endsAt,
			session.settings.phaseEaseSeconds
		)
		return stage.from:Lerp(stage.to, alpha)
	end
	return stage.to or stage.from or session.spawnPosition
end

-- Walks to `toPosition`, publishing a stage the client interpolates. Returns
-- false when the session was cancelled mid-leg.
local function runMove(session, phase, toPosition, facing)
	local settings = session.settings
	local from = currentGroundPosition(session)
	local distance = (toPosition - from).Magnitude
	local seconds = distance / settings.walkSpeedStuds
	if phase == Phases.Travel then
		seconds = math.clamp(seconds, settings.travelMinSeconds, settings.travelMaxSeconds)
	else
		seconds = math.clamp(seconds, MIN_WALK_SECONDS, settings.travelMaxSeconds)
	end

	local startsAt = serverNow()
	local latest = session.endsAt - settings.windDownSeconds
	local endsAt = math.min(startsAt + seconds, latest)
	if endsAt <= startsAt then
		return false
	end

	publishStage(session, {
		phase = phase,
		from = from,
		to = toPosition,
		facing = facing,
		startsAt = startsAt,
		endsAt = endsAt,
	})
	return cancellableWait(session, endsAt - startsAt)
end

---------------------------------------------------------------------------
-- The wave: a stepped XP ramp whose steps multiply to exactly waveXPMultiplier
---------------------------------------------------------------------------

local function applyRampMultiplier(ramp, multiplier)
	if multiplier <= 1 then
		return 0
	end
	local applied = 0
	for _, target in ipairs(ramp.targets) do
		if target.machine and target.machine.Parent then
			-- ApplyGrowthBoost re-validates the target itself (harvested, stolen,
			-- reserved and respawning slots all return false), so a target that
			-- disappears mid-ramp is simply skipped.
			local ok = FeedMachines.ApplyGrowthBoost(target.machine, target.targetKey, multiplier)
			if ok then
				applied += 1
			end
		end
	end
	return applied
end

-- Total multiplier still owed after `appliedSteps` of `steps` have landed.
-- Product of steps k..N of the per-step multiplier telescopes to this.
local function remainingRampMultiplier(settings, appliedSteps)
	local gain = settings.waveXPMultiplier - 1
	local applied = 1 + gain * (appliedSteps / settings.waveRampSteps)
	if applied <= 0 then
		return 1
	end
	return settings.waveXPMultiplier / applied
end

-- Applies whatever the in-flight wave still owes, in one write. Called when the
-- operator stops mid-wave so nobody is ever left with a partial boost, and so
-- Stop does not have to block for the rest of the 5 seconds.
local function flushRamp(session)
	local ramp = session.activeRamp
	if type(ramp) ~= "table" or ramp.flushed then
		return
	end
	ramp.flushed = true
	session.activeRamp = nil
	local multiplier = remainingRampMultiplier(session.settings, ramp.appliedSteps)
	if multiplier > 1 then
		local applied = applyRampMultiplier(ramp, multiplier)
		print(string.format(
			"[PlotSprinkleService] flush user=%d step=%d/%d x%.4f targets=%d",
			ramp.userId,
			ramp.appliedSteps,
			session.settings.waveRampSteps,
			multiplier,
			applied
		))
	end
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
		RuntimeGuard.Run("PlotSprinkleService.SnapshotOwner." .. tostring(userId), function()
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
				warn("[PlotSprinkleService] Snapshot failed after sprinkle boost for user " .. tostring(userId))
			end
		end)
	end)
end

-- Runs one stop's 5-second wave. Returns whether anything was actually boosted;
-- turn-level bookkeeping and reporting belong to the caller.
local function runWave(session, entry, stop)
	local settings = session.settings
	local startsAt = serverNow()
	local endsAt = math.min(startsAt + settings.waveSeconds, session.endsAt - settings.windDownSeconds)
	if endsAt <= startsAt then
		return false
	end

	local ramp = {
		userId = entry.userId,
		targets = stop.targets,
		appliedSteps = 0,
		flushed = false,
	}
	session.activeRamp = ramp

	publishStage(session, {
		phase = Phases.Wave,
		from = stop.standPosition,
		to = stop.standPosition,
		facing = stop.center,
		areaCenter = stop.center,
		startsAt = startsAt,
		endsAt = endsAt,
	})

	local stepSeconds = (endsAt - startsAt) / settings.waveRampSteps
	local appliedAny = false
	for step = 1, settings.waveRampSteps do
		if not cancellableWait(session, stepSeconds) then
			break
		end
		if ramp.flushed then
			break
		end
		local multiplier = GameEvents.SprinkleRampStepMultiplier(
			settings.waveXPMultiplier,
			step,
			settings.waveRampSteps
		)
		if applyRampMultiplier(ramp, multiplier) > 0 then
			appliedAny = true
		end
		ramp.appliedSteps = step
	end

	if session.activeRamp == ramp then
		session.activeRamp = nil
	end

	if appliedAny then
		-- Per wave, not per turn: a turn cut short by a leaver still persists the
		-- boosts it already landed.
		scheduleOwnerSnapshot(session, entry)
	end
	return appliedAny
end

---------------------------------------------------------------------------
-- Turn queue (ported from PlotAlienEventService)
---------------------------------------------------------------------------

local function shuffle(list)
	for index = #list, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		list[index], list[swapIndex] = list[swapIndex], list[index]
	end
end

-- Stamps the order in which each player first became a valid target, so the
-- queue is genuinely first-come-first-served and a new joiner lands on the END
-- of it rather than being interleaved by UserId.
local function noteDiscovery(session, userId)
	if session.discoveryOrder[userId] == nil then
		session.discoverySequence += 1
		session.discoveryOrder[userId] = session.discoverySequence
	end
	return session.discoveryOrder[userId]
end

local function eligibleEntries(session)
	-- Shuffled BEFORE discovery order is stamped, not after: the queue is sorted
	-- by discovery order, so shuffling the results afterwards would have had no
	-- effect at all and the first batch would silently have run in
	-- Players:GetPlayers() order. Randomising here is what actually gives
	-- everyone already in the server an equal shot at going first; after that,
	-- discovery order rules and new joiners land at the end.
	local players = Players:GetPlayers()
	shuffle(players)

	local entries = {}
	for _, player in ipairs(players) do
		local eligible, _, context = EventEligibility.IsEligible(player)
		if eligible and context then
			local plot = context.plot
			local center = plotCenter(plot)
			if plot and center and #collectPlotTargets(plot) > 0 then
				noteDiscovery(session, player.UserId)
				entries[#entries + 1] = {
					player = player,
					userId = player.UserId,
					plot = plot,
					plotCenter = center,
				}
			end
		end
	end
	return entries
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

-- Refresh the queue from current plot/player truth after every visit. Queued
-- entries are replaced with fresh Player/plot references on rejoin, and leavers
-- and exhausted plots are removed.
--
-- ONE turn per player: a player who has had their turn is never queued again, so
-- the event drains its queue and finishes rather than looping forever. New
-- joiners append to the END, in the order they first became valid targets.
local function refreshVisitQueue(session)
	if not canRefreshQueue(session) then
		return 0
	end

	local currentEntries = eligibleEntries(session)
	local currentByUserId = {}
	for _, entry in ipairs(currentEntries) do
		currentByUserId[entry.userId] = entry
	end

	for index = #session.entries, 1, -1 do
		local queuedEntry = session.entries[index]
		local currentEntry = currentByUserId[queuedEntry.userId]
		if currentEntry then
			-- A rejoin creates a new Player instance and can recreate the plot.
			-- Preserve the queue position while refreshing both references.
			session.entries[index] = currentEntry
			session.queuedUserIds[currentEntry.userId] = true
		else
			session.queuedUserIds[queuedEntry.userId] = nil
			table.remove(session.entries, index)
		end
	end

	local candidates = {}
	for _, entry in ipairs(currentEntries) do
		if not session.queuedUserIds[entry.userId] and not session.visitedUserIds[entry.userId] then
			candidates[#candidates + 1] = entry
		end
	end
	table.sort(candidates, function(left, right)
		return (session.discoveryOrder[left.userId] or 0) < (session.discoveryOrder[right.userId] or 0)
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

local function nextQueuedEntry(session)
	local entry = table.remove(session.entries, 1)
	if entry then
		session.queuedUserIds[entry.userId] = nil
	end
	return entry
end

---------------------------------------------------------------------------
-- Visit
---------------------------------------------------------------------------

local function runPlotVisit(session, entry)
	if not entryStillEligible(session, entry) then
		return false
	end
	local floor = PlotService.GetFloor(entry.plot)
	if not floor then
		return false
	end

	local settings = session.settings
	-- One read of the unlocked grid serves both jobs: filtering food onto bought
	-- ground, and sizing the turn.
	local cells = PlotGridService.UnlockedCellBounds(entry.plot, 0)
	local cellCount = type(cells) == "table" and #cells or 0

	local targets = collectPlotTargets(entry.plot)
	local insideUnlocked = unlockedTargetFilter(cells, floor)
	if insideUnlocked then
		for index = #targets, 1, -1 do
			if not insideUnlocked(targets[index].position) then
				table.remove(targets, index)
			end
		end
	end
	if #targets == 0 then
		return false
	end

	local stopBudget = stopBudgetFor(settings, cellCount)
	local stops = chooseStops(entry.plot, floor, targets, settings, stopBudget)
	if #stops == 0 then
		return false
	end
	print(string.format(
		"[PlotSprinkleService] turn user=%d cells=%d budget=%d stops=%d eligibleTargets=%d",
		entry.userId, cellCount, stopBudget, #stops, #targets
	))

	local displayName = entry.player.DisplayName ~= "" and entry.player.DisplayName or entry.player.Name
	notifyViewers(session, string.format("Fairy yacti is performing magic on %s's farm!", displayName), 5)

	-- chooseStops removes each target from the pool as soon as a stop covers it,
	-- so these stops partition the farm's food: `boosted` counts DISTINCT crops,
	-- every one of them boosted exactly once. It can never exceed eligibleTargets.
	local boosted = 0
	for index, stop in ipairs(stops) do
		local phase = index == 1 and Phases.Travel or Phases.WalkTo
		if not runMove(session, phase, stop.standPosition, stop.center) then
			break
		end
		if not entryStillEligible(session, entry) then
			break
		end
		if runWave(session, entry, stop) then
			boosted += #stop.targets
			print(string.format(
				"[PlotSprinkleService] wave user=%d stop=%d/%d targets=%d x%.2f (turn total %d)",
				entry.userId, index, #stops, #stop.targets, settings.waveXPMultiplier, boosted
			))
		end
	end

	if boosted > 0 then
		notifyPlayer(entry.player, "Fairy yacti performed magic on your farm! (+50% XP)", 5)
	end
	return boosted > 0
end

-- The queue has drained: every player who was queued has had their one turn.
-- yacti stands still for a short grace in case someone becomes eligible right at
-- the end (a late joiner, or a farm whose first crop just matured); if nobody
-- does, the event is over and he leaves. This grace -- not the 30-minute
-- failsafe -- is what ends a normal run.
local function waitForNewEntries(session)
	local settings = session.settings
	local position = currentGroundPosition(session)
	local graceEndsAt = math.min(
		serverNow() + settings.emptyQueueGraceSeconds,
		session.endsAt - settings.windDownSeconds
	)
	publishStage(session, {
		phase = Phases.Idle,
		from = position,
		to = position,
		startsAt = serverNow(),
		endsAt = graceEndsAt,
	})
	while sessionActive(session) and serverNow() < graceEndsAt do
		if refreshVisitQueue(session) > 0 then
			return true
		end
		task.wait(ENTRY_POLL_SECONDS)
	end
	return false
end

local function publishDeparture(session, startsAt, endsAt)
	local position = currentGroundPosition(session)
	publishStage(session, {
		phase = Phases.Depart,
		from = position,
		to = position,
		startsAt = startsAt,
		endsAt = endsAt,
	})
end

local function runSprinkle(session)
	local settings = session.settings
	session.phase = "windUp"
	fireViewers(session, "start", startPayload(session))
	startViewerSync(session)

	-- The entrance: fall from entranceFallStuds above the marker and land. The
	-- ground position never changes, so the drop is purely the client's vertical.
	publishStage(session, {
		phase = Phases.Arrive,
		from = session.spawnPosition,
		to = session.spawnPosition,
		startsAt = session.startsAt,
		endsAt = session.startsAt + settings.windUpSeconds,
	})
	if not cancellableWait(session, math.max((session.startsAt + settings.windUpSeconds) - serverNow(), 0)) then
		return
	end

	while sessionActive(session) do
		if serverNow() >= session.endsAt - settings.windDownSeconds then
			break
		end
		refreshVisitQueue(session)

		local entry = nextQueuedEntry(session)
		if entry then
			-- Marked as visited whether or not the turn actually ran: a player
			-- whose plot went empty or who left mid-queue has had their slot, and
			-- re-queueing them is what would turn this back into an endless loop.
			session.visitedUserIds[entry.userId] = true
			if entryStillEligible(session, entry) then
				runPlotVisit(session, entry)
			end
			if settings.interVisitPauseSeconds > 0 and not cancellableWait(session, settings.interVisitPauseSeconds) then
				break
			end
		elseif not waitForNewEntries(session) then
			break
		end
	end

	if not sessionActive(session) then
		return
	end

	-- One shot per server: an early wind-down suppresses this instance locally
	-- until endsAt, so a still-active global record cannot restart it here.
	local earlyWindDown = serverNow() < session.endsAt - settings.windDownSeconds - 0.1
	if earlyWindDown then
		session.suppressActiveRecord()
	end
	local departStartsAt = serverNow()
	publishDeparture(session, departStartsAt, math.min(departStartsAt + settings.windDownSeconds, session.endsAt))
	cancellableWait(session, settings.windDownSeconds)
	if not sessionActive(session) then
		return
	end
	fireViewers(session, "end", { instanceId = session.instanceId })
	session.complete()
end

local function cleanupFailedSprinkle(session)
	if type(session) ~= "table" or session.failureCleanupDone then
		return
	end
	session.failureCleanupDone = true
	session.cancelled = true
	if not session.loggedEnd then
		session.loggedEnd = true
		printSprinkleLifecycle("end", session, "failed")
	end
	RuntimeGuard.Run("PlotSprinkleService.FailedEnd." .. tostring(session.instanceId), function()
		fireViewers(session, "end", { instanceId = session.instanceId })
	end)
	if type(session.complete) == "function" then
		RuntimeGuard.Run("PlotSprinkleService.FailedComplete." .. tostring(session.instanceId), session.complete)
	end
end

local function runSprinkleGuarded(session)
	local ok, err = RuntimeGuard.Try("PlotSprinkleService.Run." .. tostring(session and session.instanceId), runSprinkle, session)
	if ok then
		return
	end
	warn(err)
	cleanupFailedSprinkle(session)
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

-- The spawn marker is a Part under Workspace.Map and can stream out on clients,
-- so the server resolves it once and publishes the position. Clients never read
-- it directly.
local function resolveSpawnPosition()
	local map = Workspace:FindFirstChild("Map")
	local marker = map and map:FindFirstChild(SprinkleEvent.SpawnMarkerName)
	if marker and marker:IsA("BasePart") then
		return Vector3.new(marker.Position.X, marker.Position.Y + marker.Size.Y / 2, marker.Position.Z)
	end
	warn("[PlotSprinkleService] Missing Workspace.Map." .. SprinkleEvent.SpawnMarkerName .. "; using map centre")
	local center = map and map:FindFirstChild("CENTER")
	if center and center:IsA("BasePart") then
		return center.Position
	end
	return Vector3.zero
end

function PlotSprinkleService.StartSprinkle(eventRecord, callbacks)
	if type(eventRecord) ~= "table" then
		return
	end
	if activeSession then
		PlotSprinkleService.StopSprinkle(activeSession.instanceId)
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
		-- Only what the renderer needs; the targeting numbers stay server-side.
		publicSettings = {
			windUpSeconds = settings.windUpSeconds,
			windDownSeconds = settings.windDownSeconds,
			entranceFallStuds = settings.entranceFallStuds,
			exitRiseStuds = settings.exitRiseStuds,
			walkSpeedStuds = settings.walkSpeedStuds,
			turnRateDegrees = settings.turnRateDegrees,
			phaseEaseSeconds = settings.phaseEaseSeconds,
			waveSeconds = settings.waveSeconds,
			waveRaiseSeconds = settings.waveRaiseSeconds,
			waveLowerSeconds = settings.waveLowerSeconds,
			armRaiseDegrees = settings.armRaiseDegrees,
			waveSwingDegrees = settings.waveSwingDegrees,
			waveForeAftDegrees = settings.waveForeAftDegrees,
			elbowSwingDegrees = settings.elbowSwingDegrees,
			wristSwingDegrees = settings.wristSwingDegrees,
			headSwingDegrees = settings.headSwingDegrees,
			headNodDegrees = settings.headNodDegrees,
			waistSwingDegrees = settings.waistSwingDegrees,
			waveSwingHz = settings.waveSwingHz,
			sparkleBurstCount = settings.sparkleBurstCount,
			sparkleBurstSeconds = settings.sparkleBurstSeconds,
			magicSoundSeconds = settings.magicSoundSeconds,
			magicSoundRange = settings.magicSoundRange,
			magicSoundPitchVariance = settings.magicSoundPitchVariance,
		},
		spawnPosition = resolveSpawnPosition(),
		stage = nil,
		entries = {},
		queuedUserIds = {},
		-- One turn each: a userId in here is never queued again this run.
		visitedUserIds = {},
		discoveryOrder = {},
		discoverySequence = 0,
		activeRamp = nil,
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
			printSprinkleLifecycle("end", session, "completed")
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
	printSprinkleLifecycle("start", session, string.format("visits=%d", #session.entries))
	notifyLoadedNonOnboarding("Fairy yacti has landed with his magic wand...", 5)

	RuntimeGuard.Spawn("PlotSprinkleService.RunGuarded." .. session.instanceId, runSprinkleGuarded, session)
end

function PlotSprinkleService.StopSprinkle(instanceId)
	local session = activeSession
	if not session then
		return
	end
	if instanceId ~= nil and tostring(instanceId) ~= tostring(session.instanceId) then
		return
	end

	-- Settle the in-flight wave before anything else: the operator's Stop must
	-- never leave a farm holding a partial multiplier, and flushing is instant
	-- so Stop does not have to wait out the remaining wave seconds.
	RuntimeGuard.Run("PlotSprinkleService.FlushRamp." .. tostring(session.instanceId), flushRamp, session)

	session.cancelled = true
	if not session.loggedEnd then
		session.loggedEnd = true
		printSprinkleLifecycle("end", session, "stopped")
	end

	-- Operator stops depart like a natural wind-down instead of hard-cutting.
	-- The delayed "end" is instanceId-guarded on the client, so a new sprinkle
	-- starting inside the fade window is not torn down by the old instance.
	local windDownSeconds = session.settings.windDownSeconds
	local startsAt = serverNow()
	publishDeparture(session, startsAt, startsAt + windDownSeconds)
	activeSession = nil
	task.delay(windDownSeconds, function()
		fireViewers(session, "end", { instanceId = session.instanceId })
	end)
end

return PlotSprinkleService
