local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Server = script.Parent
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local TreeClicker = require(Server:WaitForChild("feedMachines"):WaitForChild("Trees"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlotWindService = {}

local WIND_UP_SECONDS = 4
local WIND_ACTIVE_SECONDS = 30
local WIND_DOWN_SECONDS = 4
local MIN_SEQUENCE_INTERVAL = 120
local MAX_SEQUENCE_INTERVAL = 240
local MIN_TREE_WAVES = 10
local MAX_TREE_WAVES = 30
local MIN_FRUIT_PER_WAVE = 2
local MAX_FRUIT_PER_WAVE = 4
local MIN_SHAKE_GAP = 0.5
local TREE_EFFECT_RADIUS = 35
local MAX_WAVE_EVENTS_PER_HEARTBEAT = 50
local SHAKE_START_PADDING = 0.1
local SHAKE_END_PADDING = 0.2
local PRE_WIND_NOTICE_SECONDS = 3
local PRE_WIND_NOTICE_TEXT = "It's getting windy..."
local WAIT_STEP = 0.25

local PlotWindEffect = Remotes.get(Remotes.Names.PlotWindEffect)
local rng = Random.new()
local recordsByUserId = {}
local globalLoopRunning = false

local TOTAL_WIND_SECONDS = WIND_UP_SECONDS + WIND_ACTIVE_SECONDS + WIND_DOWN_SECONDS

local function userKey(player)
	return player and player.UserId or nil
end

local function hasRecords()
	return next(recordsByUserId) ~= nil
end

local function waitWhileRegistered(seconds)
	local deadline = os.clock() + math.max(0, seconds)
	while hasRecords() do
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			return true
		end
		task.wait(math.min(WAIT_STEP, remaining))
	end
	return false
end

local function isActiveRecord(player, plot, record)
	local key = userKey(player)
	return key ~= nil
		and recordsByUserId[key] == record
		and not record.cancelled
		and player.Parent == Players
		and PlotService.GetPlayerPlot(player) == plot
end

local function isOnboardingActive(player)
	local profile = PlayerDataService.GetProfile(player)
	return profile ~= nil and OnboardingService.IsActive(profile)
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

local function sampleWaveTimes()
	local count = rng:NextInteger(MIN_TREE_WAVES, MAX_TREE_WAVES)
	if count <= 1 then
		return {
			WIND_UP_SECONDS + rng:NextNumber(SHAKE_START_PADDING, WIND_ACTIVE_SECONDS - SHAKE_END_PADDING),
		}
	end

	local latestFirst = WIND_ACTIVE_SECONDS - SHAKE_END_PADDING - ((count - 1) * MIN_SHAKE_GAP)
	local current = rng:NextNumber(SHAKE_START_PADDING, latestFirst)
	local times = { WIND_UP_SECONDS + current }
	for index = 2, count do
		local remainingAfterThis = count - index
		local latest = WIND_ACTIVE_SECONDS - SHAKE_END_PADDING - (remainingAfterThis * MIN_SHAKE_GAP)
		current = rng:NextNumber(current + MIN_SHAKE_GAP, latest)
		times[index] = WIND_UP_SECONDS + current
	end
	return times
end

local function triggerTreeWave(player, plot, record, tree, amount)
	RuntimeGuard.Run("PlotWindService.TriggerWindWave", function()
		if not isActiveRecord(player, plot, record) then
			return
		end
		if isOnboardingActive(player) then
			return
		end
		if not tree:IsDescendantOf(plot) then
			return
		end
		TreeClicker.TriggerWindWave(tree, player, amount, {
			effectRadius = TREE_EFFECT_RADIUS,
			includeTriggeringPlayer = false,
		})
	end)
end

local function eligibleEntries()
	local entries = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local key = userKey(player)
		local record = key and recordsByUserId[key] or nil
		local plot = record and PlotService.GetPlayerPlot(player) or nil
		if plot
			and isActiveRecord(player, plot, record)
			and not isOnboardingActive(player) then
			entries[#entries + 1] = {
				player = player,
				plot = plot,
				record = record,
			}
		end
	end
	return entries
end

local function fireWindEffects(entries)
	for _, entry in ipairs(entries) do
		RuntimeGuard.Run("PlotWindService.FireClient", function()
			PlotWindEffect:FireClient(entry.player, {
				plot = entry.plot,
				windUp = WIND_UP_SECONDS,
				active = WIND_ACTIVE_SECONDS,
				windDown = WIND_DOWN_SECONDS,
			})
		end)
	end
end

local function notifyWindStarting(entries)
	for _, entry in ipairs(entries) do
		RuntimeGuard.Run("PlotWindService.NotifyWindStarting", function()
			NotificationService.Notify(entry.player, {
				text = PRE_WIND_NOTICE_TEXT,
				lifetime = PRE_WIND_NOTICE_SECONDS,
				preserveTrailingPeriods = true,
			})
		end)
	end
end

local function buildWaveQueue(entries)
	local queue = {}
	for _, entry in ipairs(entries) do
		for _, tree in ipairs(collectTrees(entry.plot)) do
			for _, shakeTime in ipairs(sampleWaveTimes()) do
				queue[#queue + 1] = {
					time = shakeTime,
					player = entry.player,
					plot = entry.plot,
					record = entry.record,
					tree = tree,
					amount = rng:NextInteger(MIN_FRUIT_PER_WAVE, MAX_FRUIT_PER_WAVE),
				}
			end
		end
	end
	table.sort(queue, function(a, b)
		return a.time < b.time
	end)
	return queue
end

local function processWaveQueue(queue)
	local sequenceStartedAt = os.clock()
	local index = 1
	while hasRecords() do
		local elapsed = os.clock() - sequenceStartedAt
		local processed = 0
		while index <= #queue
			and queue[index].time <= elapsed
			and processed < MAX_WAVE_EVENTS_PER_HEARTBEAT do
			local event = queue[index]
			triggerTreeWave(event.player, event.plot, event.record, event.tree, event.amount)
			index += 1
			processed += 1
		end

		if elapsed >= TOTAL_WIND_SECONDS and index > #queue then
			return
		end

		if index <= #queue and queue[index].time <= elapsed then
			RunService.Heartbeat:Wait()
			continue
		end

		local nextTime = TOTAL_WIND_SECONDS
		if index <= #queue then
			nextTime = math.min(nextTime, queue[index].time)
		end
		local waitSeconds = math.max(0, nextTime - elapsed)
		if waitSeconds <= 0 then
			RunService.Heartbeat:Wait()
		elseif not waitWhileRegistered(waitSeconds) then
			return
		end
	end
end

local function runSequence()
	local entries = eligibleEntries()
	if #entries == 0 then
		return false
	end

	notifyWindStarting(entries)
	if not waitWhileRegistered(PRE_WIND_NOTICE_SECONDS) then
		return false
	end

	entries = eligibleEntries()
	if #entries == 0 then
		return false
	end

	fireWindEffects(entries)
	processWaveQueue(buildWaveQueue(entries))
	return true
end

local function runGlobalLoop()
	local waitSeconds = rng:NextNumber(MIN_SEQUENCE_INTERVAL, MAX_SEQUENCE_INTERVAL)
	while hasRecords() do
		if not waitWhileRegistered(waitSeconds) then
			break
		end
		local sequenceStartedAt = os.clock()
		local _, hadEligiblePlayers = RuntimeGuard.Run("PlotWindService.Sequence", runSequence)
		local elapsed = hadEligiblePlayers and (os.clock() - sequenceStartedAt) or 0
		local intervalSeconds = rng:NextNumber(MIN_SEQUENCE_INTERVAL, MAX_SEQUENCE_INTERVAL)
		waitSeconds = math.max(0, intervalSeconds - elapsed)
	end
end

local function ensureGlobalLoop()
	if globalLoopRunning then
		return
	end
	globalLoopRunning = true
	RuntimeGuard.Spawn("PlotWindService.GlobalLoop", function()
		runGlobalLoop()
		globalLoopRunning = false
		if hasRecords() then
			ensureGlobalLoop()
		end
	end)
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

	ensureGlobalLoop()
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
end

return PlotWindService
