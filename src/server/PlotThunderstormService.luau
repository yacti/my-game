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

local PlotThunderstormService = {}

local ThunderstormEffect = Remotes.get(Remotes.Names.ThunderstormEffect)

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

local function displayNameForFood(foodId)
	local producerFeedType, sourceFoodId = Food.ParseJamFoodId(foodId)
	if producerFeedType and sourceFoodId then
		local sourceTemplate = Food.GetTemplate(sourceFoodId)
		return (sourceTemplate and sourceTemplate.Name or sourceFoodId) .. " Jam"
	end
	local template = type(foodId) == "string" and Food.GetTemplate(foodId) or nil
	return template and template.Name or tostring(foodId or "food")
end

local function settingsFor()
	local config = GameEvents.GetEvent(GameEvents.Ids.Stormy) or {}
	local storm = type(config.storm) == "table" and config.storm or {}
	local windUpSeconds, activeSeconds, windDownSeconds, totalSeconds = GameEvents.StormTimings(config)
	local minStrikes = integerValue(storm.minStrikesPerPlot, 5)
	local maxStrikes = math.max(integerValue(storm.maxStrikesPerPlot, 15), minStrikes)
	return {
		mutationId = config.appliedMutationId or Mutations.Ids.Lightning,
		windUpSeconds = windUpSeconds,
		activeSeconds = activeSeconds,
		windDownSeconds = windDownSeconds,
		totalSeconds = totalSeconds,
		plotTurnSeconds = math.max(numberValue(storm.plotTurnSeconds, 30), 0),
		maxPlotTurns = integerValue(storm.maxPlotTurns, 8),
		minStrikesPerPlot = minStrikes,
		maxStrikesPerPlot = maxStrikes,
		targetRetrySeconds = math.max(numberValue(storm.targetRetrySeconds, 2), 0),
		thunderSoundRange = math.max(numberValue(storm.thunderSoundRange, 500), 0),
		rainFollowHeight = math.max(numberValue(storm.rainFollowHeight, 30), 0),
		cloudStartHeight = math.max(numberValue(storm.cloudStartHeight, 100), 0),
		cloudPlotHeight = math.max(numberValue(storm.cloudPlotHeight, 100), 0),
		cloudTravelSeconds = math.max(numberValue(storm.cloudTravelSeconds, 2), 0),
	}
end

local function isEventEligible(player)
	local eligible = EventEligibility.IsEligible(player)
	return eligible == true
end

local function blockedOnboardingViewers()
	local blocked = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local _, code = EventEligibility.IsEligible(player)
		if code == "onboarding" then
			blocked[player.UserId] = true
		end
	end
	return blocked
end

local function viewerEligible(session, player)
	if not (session and player) then
		return false
	end
	if session.blockedViewerUserIds[player.UserId] then
		return false
	end
	local eligible, code = EventEligibility.IsEligible(player)
	if code == "onboarding" then
		session.blockedViewerUserIds[player.UserId] = true
		return false
	end
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

local function fireViewer(player, command, payload)
	RuntimeGuard.Run("PlotThunderstormService.FireClient." .. tostring(command), function()
		ThunderstormEffect:FireClient(player, command, payload)
	end)
end

local function syncPayload(session)
	return {
		instanceId = session.instanceId,
		startsAt = session.startsAt,
		endsAt = session.endsAt,
		phase = session.phase,
		settings = session.publicSettings,
		mapCenter = session.mapCenter,
		cloudOrigin = session.currentCloudOrigin,
		currentPlotCenter = session.currentPlotCenter,
		currentCloudOrigin = session.currentCloudOrigin,
		currentTurnEndsAt = session.currentTurnEndsAt,
	}
end

local function syncViewer(session, player)
	fireViewer(player, "sync", syncPayload(session))
	session.syncedViewers[player.UserId] = true
end

local function fireViewers(session, command, payload)
	for _, player in ipairs(Players:GetPlayers()) do
		if viewerEligible(session, player) then
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
	RuntimeGuard.Run("PlotThunderstormService.NotifyPlayer", function()
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
	for _, player in ipairs(Players:GetPlayers()) do
		if viewerEligible(session, player) and not session.syncedViewers[player.UserId] then
			syncViewer(session, player)
		end
	end
end

local function startViewerSync(session)
	RuntimeGuard.Spawn("PlotThunderstormService.ViewerSync." .. session.instanceId, function()
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
		RuntimeGuard.Run("PlotThunderstormService.SnapshotOwner." .. tostring(userId), function()
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
				warn("[PlotThunderstormService] Snapshot failed after storm mutation for user " .. tostring(userId))
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

local function runPlotTurn(session, entry)
	if not entryStillEligible(session, entry) then
		return false
	end
	local turnStartsAt = serverNow()
	local turnEndsAt = math.min(turnStartsAt + session.settings.plotTurnSeconds, session.endsAt - session.settings.windDownSeconds)
	local strikeCount = rng:NextInteger(session.settings.minStrikesPerPlot, session.settings.maxStrikesPerPlot)
	local cloudOrigin = entry.plotCenter + Vector3.new(0, session.settings.cloudPlotHeight, 0)
	session.phase = "plotTurn"
	session.currentPlotCenter = entry.plotCenter
	session.currentCloudOrigin = cloudOrigin
	session.currentTurnEndsAt = turnEndsAt
	fireViewers(session, "plotTurn", {
		instanceId = session.instanceId,
		userId = entry.userId,
		plot = entry.plot,
		plotCenter = entry.plotCenter,
		cloudOrigin = cloudOrigin,
		startsAt = turnStartsAt,
		endsAt = turnEndsAt,
		settings = session.publicSettings,
	})
	local displayName = entry.player.DisplayName ~= "" and entry.player.DisplayName or entry.player.Name
	notifyViewers(session, string.format("The storm is now over %s's plot", displayName), 5)

	if not cancellableWait(session, math.min(session.settings.cloudTravelSeconds, math.max(turnEndsAt - serverNow(), 0))) then
		return false
	end

	local gap = strikeCount > 0 and (session.settings.plotTurnSeconds / strikeCount) or session.settings.plotTurnSeconds
	for strikeIndex = 1, strikeCount do
		if not sessionActive(session) or serverNow() >= turnEndsAt then
			break
		end
		if not entryStillEligible(session, entry) then
			break
		end
		if strikeIndex > 1 and not cancellableWait(session, math.min(gap, math.max(turnEndsAt - serverNow(), 0))) then
			break
		end
		local target = chooseTarget(session, entry, session.settings.targetRetrySeconds)
		if not target or not targetStillValid(target, session.settings.mutationId) then
			break
		end
		local applied, result = FeedMachines.ApplyMutation(target.machine, target.targetKey, session.settings.mutationId)
		if applied then
			scheduleOwnerSnapshot(session, entry)
			local targetPosition = result and result.position or target.position
			notifyPlayer(entry.player, string.format(
				"Your %s got struck by lightning!",
				displayNameForFood((result and result.foodId) or target.foodId)
			), 5)
			fireViewers(session, "strike", {
				instanceId = session.instanceId,
				strikeId = string.format("%s_%d_%d", session.instanceId, entry.userId, strikeIndex),
				serverTime = serverNow(),
				mutationId = session.settings.mutationId,
				targetPosition = targetPosition,
				cloudOrigin = cloudOrigin,
				thunderSoundRange = session.settings.thunderSoundRange,
				settings = session.publicSettings,
			})
		end
	end
	return true
end

local function runStorm(session)
	session.phase = "windUp"
	session.currentCloudOrigin = session.mapCenter + Vector3.new(0, session.settings.cloudStartHeight, 0)
	fireViewers(session, "start", {
		instanceId = session.instanceId,
		startsAt = session.startsAt,
		endsAt = session.endsAt,
		settings = session.publicSettings,
		mapCenter = session.mapCenter,
		cloudOrigin = session.currentCloudOrigin,
	})
	startViewerSync(session)
	if not cancellableWait(session, math.max((session.startsAt + session.settings.windUpSeconds) - serverNow(), 0)) then
		return
	end

	local ranAnyTurn = false
	for _, entry in ipairs(session.entries) do
		if not sessionActive(session) then
			return
		end
		if serverNow() >= session.endsAt - session.settings.windDownSeconds then
			break
		end
		ranAnyTurn = runPlotTurn(session, entry) or ranAnyTurn
	end

	if not sessionActive(session) then
		return
	end
	session.phase = "windDown"
	session.currentPlotCenter = nil
	session.currentCloudOrigin = nil
	session.currentTurnEndsAt = nil
	local earlyWindDown = serverNow() < session.endsAt - session.settings.windDownSeconds - 0.1
	if earlyWindDown then
		session.suppressActiveRecord()
	end
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

function PlotThunderstormService.StartStorm(eventRecord, callbacks)
	if type(eventRecord) ~= "table" then
		return
	end
	if activeSession then
		PlotThunderstormService.StopStorm(activeSession.instanceId)
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
			rainFollowHeight = settings.rainFollowHeight,
			cloudStartHeight = settings.cloudStartHeight,
			cloudPlotHeight = settings.cloudPlotHeight,
			cloudTravelSeconds = settings.cloudTravelSeconds,
			thunderSoundRange = settings.thunderSoundRange,
		},
		mapCenter = mapCenter(),
		entries = eligibleEntries(settings.mutationId, settings.maxPlotTurns),
		syncedViewers = {},
		blockedViewerUserIds = blockedOnboardingViewers(),
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
		if activeSession == session then
			activeSession = nil
		end
		if not session.suppressedActiveRecord and type(callbacks.complete) == "function" then
			callbacks.complete(session.instanceId)
		end
	end
	activeSession = session

	RuntimeGuard.Spawn("PlotThunderstormService.Run." .. session.instanceId, runStorm, session)
end

function PlotThunderstormService.NotifyStormApproaching()
	local config = GameEvents.GetEvent(GameEvents.Ids.Stormy) or {}
	local text = config.preNoticeText or "A storm is approaching"
	local lifetime = math.max(numberValue(config.preNoticeSeconds, 5), 0)
	notifyLoadedNonOnboarding(text, lifetime)
end

function PlotThunderstormService.StopStorm(instanceId)
	local session = activeSession
	if not session then
		return
	end
	if instanceId ~= nil and tostring(instanceId) ~= tostring(session.instanceId) then
		return
	end
	session.cancelled = true
	fireViewers(session, "end", {
		instanceId = session.instanceId,
	})
	activeSession = nil
end

return PlotThunderstormService
