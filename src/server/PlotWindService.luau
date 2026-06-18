local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
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
local MIN_SEQUENCE_INTERVAL = 90
local MAX_SEQUENCE_INTERVAL = 180
local MIN_TREE_WAVES = 10
local MAX_TREE_WAVES = 30
local MIN_FRUIT_PER_WAVE = 2
local MAX_FRUIT_PER_WAVE = 4
local MIN_SHAKE_GAP = 0.5
local TREE_EFFECT_RADIUS = 35
local SHAKE_START_PADDING = 0.1
local SHAKE_END_PADDING = 0.2
local WAIT_STEP = 0.25

local PlotWindEffect = Remotes.get(Remotes.Names.PlotWindEffect)
local rng = Random.new()
local recordsByUserId = {}

local TOTAL_WIND_SECONDS = WIND_UP_SECONDS + WIND_ACTIVE_SECONDS + WIND_DOWN_SECONDS

local function userKey(player)
	return player and player.UserId or nil
end

local function cancellableWait(record, seconds)
	local deadline = os.clock() + math.max(0, seconds)
	while not record.cancelled do
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

local function buildWaveQueue(plot)
	local queue = {}
	for _, tree in ipairs(collectTrees(plot)) do
		for _, shakeTime in ipairs(sampleWaveTimes()) do
			queue[#queue + 1] = {
				time = shakeTime,
				tree = tree,
				amount = rng:NextInteger(MIN_FRUIT_PER_WAVE, MAX_FRUIT_PER_WAVE),
			}
		end
	end
	table.sort(queue, function(a, b)
		return a.time < b.time
	end)
	return queue
end

local function processWaveQueue(player, plot, record, queue)
	local sequenceStartedAt = os.clock()
	local index = 1
	while not record.cancelled do
		local elapsed = os.clock() - sequenceStartedAt
		while index <= #queue and queue[index].time <= elapsed do
			triggerTreeWave(player, plot, record, queue[index].tree, queue[index].amount)
			index += 1
		end

		if elapsed >= TOTAL_WIND_SECONDS then
			return
		end

		local nextTime = TOTAL_WIND_SECONDS
		if index <= #queue then
			nextTime = math.min(nextTime, queue[index].time)
		end
		if not cancellableWait(record, math.max(0, nextTime - elapsed)) then
			return
		end
	end
end

local function runSequence(player, plot, record)
	if isOnboardingActive(player) then
		return
	end
	RuntimeGuard.Run("PlotWindService.FireClient", function()
		PlotWindEffect:FireClient(player, {
			plot = plot,
			windUp = WIND_UP_SECONDS,
			active = WIND_ACTIVE_SECONDS,
			windDown = WIND_DOWN_SECONDS,
		})
	end)

	processWaveQueue(player, plot, record, buildWaveQueue(plot))
end

local function runLoop(player, plot, record)
	local waitSeconds = rng:NextNumber(MIN_SEQUENCE_INTERVAL, MAX_SEQUENCE_INTERVAL)
	while not record.cancelled and player.Parent == Players and PlotService.GetPlayerPlot(player) == plot do
		if isOnboardingActive(player) then
			if not cancellableWait(record, WAIT_STEP) then
				break
			end
			waitSeconds = rng:NextNumber(MIN_SEQUENCE_INTERVAL, MAX_SEQUENCE_INTERVAL)
			continue
		end
		if not cancellableWait(record, waitSeconds) then
			break
		end
		if isOnboardingActive(player) then
			waitSeconds = rng:NextNumber(MIN_SEQUENCE_INTERVAL, MAX_SEQUENCE_INTERVAL)
			continue
		end
		local sequenceStartedAt = os.clock()
		RuntimeGuard.Run("PlotWindService.Sequence", runSequence, player, plot, record)
		local elapsed = os.clock() - sequenceStartedAt
		local intervalSeconds = rng:NextNumber(MIN_SEQUENCE_INTERVAL, MAX_SEQUENCE_INTERVAL)
		waitSeconds = math.max(0, intervalSeconds - elapsed)
	end
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

	RuntimeGuard.Spawn("PlotWindService.Loop." .. tostring(key), runLoop, player, plot, record)
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
