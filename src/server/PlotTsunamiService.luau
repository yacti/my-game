-- Tsunami weather event: one global wave sweeps the map along -Z on a fully
-- deterministic timeline (spawn, speed, and end line come from the Studio
-- template via GameEvents.TsunamiGeometry). There is no dedicated remote --
-- clients render the wave from the replicated snapshot record, while this
-- service evaluates the identical timeline to decide which players the touch
-- slab envelops and applies the gameplay: each eligible player hit gets a
-- per-player underwater phase during which 2-5 of their fruit turn Aqua.
-- Players present and eligible when the wave launches ("veterans") ride it:
-- the slab hits them during the sweep, and anyone it misses is enrolled when
-- the wave reaches the end line and the map counts as flooded. Everyone else
-- (late joiners, rejoins, players whose onboarding/profile resolves after
-- launch) drops straight into the underwater phase on becoming eligible, with
-- the window clamped to the global flood end so late entry never pays better.
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

local PlotTsunamiService = {}

local WAIT_STEP = 0.25
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

local function printTsunamiLifecycle(action, session, detail)
	local suffix = ""
	if detail ~= nil and detail ~= "" then
		suffix = " " .. tostring(detail)
	end
	print(string.format(
		"[PlotTsunamiService] Tsunami %s %s (%d -> %d)%s",
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
	local config = GameEvents.GetEvent(GameEvents.Ids.Tsunami) or {}
	local tsunami = type(config.tsunami) == "table" and config.tsunami or {}
	local windUpSeconds, activeSeconds, windDownSeconds, totalSeconds = GameEvents.TsunamiTimings(config)
	local minMutations = integerValue(tsunami.minMutationsPerPlot, 2)
	local maxMutations = math.max(integerValue(tsunami.maxMutationsPerPlot, 5), minMutations)
	return {
		mutationId = config.appliedMutationId or Mutations.Ids.Aqua,
		windUpSeconds = windUpSeconds,
		activeSeconds = activeSeconds,
		windDownSeconds = windDownSeconds,
		totalSeconds = totalSeconds,
		travelSeconds = GameEvents.TsunamiTravelSeconds(tsunami),
		studsPerSecond = math.max(numberValue(tsunami.studsPerSecond, 50), 1),
		underwaterSeconds = math.max(numberValue(tsunami.underwaterSeconds, 120), 0),
		minMutationsPerPlot = minMutations,
		maxMutationsPerPlot = maxMutations,
		targetRetrySeconds = math.max(numberValue(tsunami.targetRetrySeconds, 2), 0),
		hitCheckSeconds = math.clamp(numberValue(tsunami.hitCheckSeconds, 0.1), 0.05, 1),
		geometry = GameEvents.TsunamiGeometry(),
	}
end

local function isEventEligible(player)
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
	RuntimeGuard.Run("PlotTsunamiService.NotifyPlayer", function()
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
		RuntimeGuard.Run("PlotTsunamiService.SnapshotOwner." .. tostring(userId), function()
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
				warn("[PlotTsunamiService] Snapshot failed after tsunami mutation for user " .. tostring(userId))
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

-- Pure AABB test against the moving touch slab. The slab only exists while the
-- wave is traveling; players who join (or finish onboarding) behind the wave
-- are instead enrolled once the wave reaches the end line and the map counts
-- as flooded. Assumes the template's authored identity rotation.
local function slabContains(session, position, now)
	local settings = session.settings
	local geometry = settings.geometry
	local travelElapsed = now - session.startsAt - settings.windUpSeconds
	if travelElapsed <= 0 or travelElapsed >= settings.travelSeconds then
		return false
	end
	local slabZ = geometry.touchStartZ - settings.studsPerSecond * travelElapsed
	return math.abs(position.X - geometry.touchCenterX) <= geometry.touchSizeX / 2
		and math.abs(position.Y - geometry.touchCenterY) <= geometry.touchSizeY / 2
		and math.abs(position.Z - slabZ) <= geometry.touchSizeZ / 2
end

-- Per-player underwater phase: spread the rolled mutation count across the
-- window with one random time per equal segment, so hits feel scattered but
-- still cover the whole window. Flood enrollees get the time left until the
-- global flood ends, with the mutation roll prorated to match, so joining
-- late never pays better than riding out the wave.
local function runUnderwaterPhase(session, entry)
	local windowSeconds = math.min(
		numberValue(entry.windowSeconds, session.settings.underwaterSeconds),
		session.settings.underwaterSeconds
	)
	local count = rng:NextInteger(session.settings.minMutationsPerPlot, session.settings.maxMutationsPerPlot)
	if windowSeconds < session.settings.underwaterSeconds then
		count = math.floor(count * windowSeconds / math.max(session.settings.underwaterSeconds, 1) + 0.5)
	end
	printTsunamiLifecycle("underwater", session, string.format(
		"user=%d mutations=%d window=%ds",
		entry.userId,
		count,
		math.floor(windowSeconds)
	))
	if count <= 0 or windowSeconds <= 0 then
		return
	end
	local segment = windowSeconds / count
	local previousTime = 0
	for index = 1, count do
		local mutateAt = (index - 1) * segment + rng:NextNumber(0, segment)
		if not cancellableWait(session, mutateAt - previousTime) then
			return
		end
		previousTime = mutateAt
		if not entryStillEligible(session, entry) then
			return
		end
		local target = chooseTarget(session, entry, session.settings.targetRetrySeconds)
		if not target or not targetStillValid(target, session.settings.mutationId) then
			return
		end
		local applied, result = FeedMachines.ApplyMutation(target.machine, target.targetKey, session.settings.mutationId)
		if applied then
			scheduleOwnerSnapshot(session, entry)
			local xpMultiplier = Mutations.XPMultiplier(session.settings.mutationId) or 1
			notifyPlayer(entry.player, string.format(
				"Your %s has been soaked by the tsunami! (x%s XP)",
				displayNameForFood((result and result.foodId) or target.foodId),
				multiplierLabel(xpMultiplier)
			), 5)
		end
	end
end

local function tryHitPlayer(session, player, now)
	local userId = player.UserId
	if session.hitByUserId[userId] then
		return
	end
	-- After the sweep the whole map is flooded, so position no longer matters.
	-- During the sweep, veterans (present and eligible at wave launch) are hit
	-- only by the traveling slab; newcomers fall through and drop straight
	-- into the underwater phase as soon as they're eligible.
	local flooded = now >= session.sweepEndsAt
	local veteran = session.veteranUserIds[userId] == true
	if not flooded and veteran then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (root and slabContains(session, root.Position, now)) then
			return
		end
	end
	local eligible, code, context = EventEligibility.IsEligible(player)
	if not (eligible == true and context and context.plot) then
		-- Ineligibility here is usually transient (profile load, plot assign,
		-- offline-progress ack), so late joiners the slab is still enveloping
		-- must stay retryable; only an actual hit consumes the player.
		if session.skipCodeByUserId[userId] ~= code then
			session.skipCodeByUserId[userId] = code
			printTsunamiLifecycle("hit-skipped", session, string.format("user=%d code=%s", userId, tostring(code)))
		end
		return
	end
	session.skipCodeByUserId[userId] = nil
	session.hitByUserId[userId] = true
	local via = flooded and "flood" or (veteran and "wave" or "join")
	printTsunamiLifecycle("hit", session, string.format("user=%d via=%s", userId, via))
	local entry = {
		player = player,
		userId = userId,
		plot = context.plot,
		windowSeconds = math.min(
			math.max(session.underwaterEndsAt - now, 0),
			session.settings.underwaterSeconds
		),
	}
	RuntimeGuard.Spawn(
		"PlotTsunamiService.Underwater." .. tostring(session.instanceId) .. "." .. tostring(userId),
		runUnderwaterPhase,
		session,
		entry
	)
end

-- Whoever is present and eligible when the wave launches rides it out; taken
-- once so everyone who shows up (or becomes eligible) afterwards enrolls
-- straight into the underwater phase. On a backdated start the snapshot runs
-- immediately, so a fresh server's current players still get slab hits for
-- whatever sweep remains.
local function snapshotVeterans(session)
	for _, player in ipairs(Players:GetPlayers()) do
		if isEventEligible(player) then
			session.veteranUserIds[player.UserId] = true
		end
	end
end

local function runHitLoop(session)
	while sessionActive(session) do
		local now = serverNow()
		if now >= math.min(session.underwaterEndsAt, session.endsAt) then
			break
		end
		if now >= session.waveLaunchAt then
			if not session.veteransSnapshotted then
				session.veteransSnapshotted = true
				snapshotVeterans(session)
			end
			for _, player in ipairs(Players:GetPlayers()) do
				tryHitPlayer(session, player, now)
			end
		end
		task.wait(session.settings.hitCheckSeconds)
	end
end

local function runTsunami(session)
	session.phase = "windUp"
	local config = GameEvents.GetEvent(GameEvents.Ids.Tsunami) or {}
	notifyLoadedNonOnboarding(config.preNoticeText or "A tsunami is approaching...", 5)
	RuntimeGuard.Spawn("PlotTsunamiService.HitLoop." .. tostring(session.instanceId), runHitLoop, session)

	if not cancellableWait(session, math.max((session.endsAt - session.settings.windDownSeconds) - serverNow(), 0)) then
		return
	end
	session.phase = "windDown"
	cancellableWait(session, math.max(session.endsAt - serverNow(), 0))
	if not sessionActive(session) then
		return
	end
	session.complete()
end

local function cleanupFailedTsunami(session)
	if type(session) ~= "table" or session.failureCleanupDone then
		return
	end
	session.failureCleanupDone = true
	session.cancelled = true
	if not session.loggedEnd then
		session.loggedEnd = true
		printTsunamiLifecycle("end", session, "failed")
	end
	if type(session.complete) == "function" then
		RuntimeGuard.Run("PlotTsunamiService.FailedComplete." .. tostring(session.instanceId), session.complete)
	end
end

local function runTsunamiGuarded(session)
	local ok, err = RuntimeGuard.Try("PlotTsunamiService.Run." .. tostring(session and session.instanceId), runTsunami, session)
	if ok then
		return
	end
	warn(err)
	cleanupFailedTsunami(session)
end

function PlotTsunamiService.StartTsunami(eventRecord, callbacks)
	if type(eventRecord) ~= "table" then
		return
	end
	if activeSession then
		PlotTsunamiService.StopTsunami(activeSession.instanceId)
	end
	callbacks = type(callbacks) == "table" and callbacks or {}

	local settings = settingsFor()
	local startsAt = numberValue(eventRecord.startsAt, serverNow())
	local endsAt = numberValue(eventRecord.endsAt, startsAt + settings.totalSeconds)
	local waveLaunchAt = startsAt + settings.windUpSeconds
	local sweepEndsAt = waveLaunchAt + settings.travelSeconds
	local session = {
		instanceId = tostring(eventRecord.instanceId or ""),
		startsAt = startsAt,
		endsAt = endsAt,
		waveLaunchAt = waveLaunchAt,
		sweepEndsAt = sweepEndsAt,
		underwaterEndsAt = sweepEndsAt + settings.underwaterSeconds,
		settings = settings,
		hitByUserId = {},
		skipCodeByUserId = {},
		veteranUserIds = {},
		veteransSnapshotted = false,
		snapshotProfileState = callbacks.snapshotProfileState,
		snapshotTokens = {},
		cancelled = false,
		phase = "idle",
	}
	session.complete = function()
		if not session.loggedEnd then
			session.loggedEnd = true
			printTsunamiLifecycle("end", session, "completed")
		end
		if activeSession == session then
			activeSession = nil
		end
		if type(callbacks.complete) == "function" then
			callbacks.complete(session.instanceId)
		end
	end
	activeSession = session
	printTsunamiLifecycle("start", session, string.format("travel=%ds", math.floor(settings.travelSeconds)))

	RuntimeGuard.Spawn("PlotTsunamiService.RunGuarded." .. session.instanceId, runTsunamiGuarded, session)
end

-- A player who leaves mid-event and rejoins is a newcomer again: forget their
-- session marks so they re-enroll straight into the underwater phase (their
-- old phase task exits on its own via entryStillEligible).
RuntimeGuard.Connect(Players.PlayerRemoving, "PlotTsunamiService.PlayerRemoving", function(player)
	local session = activeSession
	if not session then
		return
	end
	session.hitByUserId[player.UserId] = nil
	session.skipCodeByUserId[player.UserId] = nil
	session.veteranUserIds[player.UserId] = nil
end)

function PlotTsunamiService.NotifyTsunamiApproaching()
	local config = GameEvents.GetEvent(GameEvents.Ids.Tsunami) or {}
	local text = config.preNoticeText or "A tsunami is approaching..."
	local lifetime = math.max(numberValue(config.preNoticeSeconds, 5), 0)
	notifyLoadedNonOnboarding(text, lifetime)
end

function PlotTsunamiService.StopTsunami(instanceId)
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
		printTsunamiLifecycle("end", session, "stopped")
	end
	activeSession = nil
end

return PlotTsunamiService
