local GameEvents = {}

GameEvents.RuntimeFolderName = "GameEvents"
GameEvents.ActiveFolderName = "Active"
GameEvents.MaxReplicatedActiveEvents = 8

GameEvents.Layers = {
	Weather = "Weather",
	Chaos = "Chaos",
}

GameEvents.Sources = {
	Schedule = "Schedule",
	AdminCommand = "AdminCommand",
}

GameEvents.Ids = {
	Sunny = "Sunny",
	Windy = "Windy",
	Stormy = "Stormy",
}

GameEvents.LayerConfigs = {
	[GameEvents.Layers.Weather] = {
		stacking = "Single",
		maxActive = 1,
	},
	[GameEvents.Layers.Chaos] = {
		stacking = "Multiple",
		maxActive = 3,
	},
}

GameEvents.EventConfigs = {
	[GameEvents.Ids.Windy] = {
		eventId = GameEvents.Ids.Windy,
		layer = GameEvents.Layers.Weather,
		source = GameEvents.Sources.Schedule,
		displayFrame = "Windy",
		cadenceSeconds = 10 * 60,
		offsetSeconds = 0,
		priority = 1,
		displayPriority = 1,
		preNoticeSeconds = 3,
		preNoticeText = "It's getting windy...",
		appliedMutationId = nil,
		wind = {
			windUpSeconds = 4,
			durationSeconds = 52,
			windDownSeconds = 4,
			minTreeWaves = 32,
			maxTreeWaves = 52,
			minFruitPerWave = 2,
			maxFruitPerWave = 4,
			minShakeGap = 1,
			treeEffectRadius = 35,
			maxWaveEventsPerHeartbeat = 50,
			shakeStartPadding = 0.1,
			shakeEndPadding = 0.2,
		},
	},
	[GameEvents.Ids.Stormy] = {
		eventId = GameEvents.Ids.Stormy,
		layer = GameEvents.Layers.Weather,
		source = GameEvents.Sources.Schedule,
		displayFrame = "Stormy",
		cadenceSeconds = 30 * 60,
		offsetSeconds = 0,
		priority = 2,
		displayPriority = 2,
		preNoticeSeconds = 5,
		preNoticeText = "A storm is approaching",
		appliedMutationId = "Lightning",
		storm = {
			windUpSeconds = 10,
			plotTurnSeconds = 30,
			maxPlotTurns = 8,
			windDownSeconds = 10,
			minStrikesPerPlot = 3,
			maxStrikesPerPlot = 7,
			targetRetrySeconds = 2,
			thunderSoundRange = 500,
			rainFollowHeight = 30,
			cloudStartHeight = 100,
			cloudPlotHeight = 100,
			cloudTravelSeconds = 6,
		},
	},
}

local function numeric(value, fallback)
	value = tonumber(value)
	if value == nil then
		return fallback
	end
	return value
end

function GameEvents.GetEvent(eventId)
	return GameEvents.EventConfigs[eventId]
end

function GameEvents.TotalDuration(config)
	if type(config) ~= "table" then
		return 0
	end
	if type(config.wind) == "table" then
		return select(4, GameEvents.WindTimings(config))
	end
	if type(config.storm) == "table" then
		return select(4, GameEvents.StormTimings(config))
	end
	return math.max(numeric(config.durationSeconds, 0), 0)
end

function GameEvents.WindTimings(config)
	config = config or GameEvents.GetEvent(GameEvents.Ids.Windy)
	local wind = type(config) == "table" and config.wind or nil
	wind = type(wind) == "table" and wind or {}
	local windUp = math.max(numeric(wind.windUpSeconds, 4), 0)
	local active = math.max(numeric(wind.durationSeconds, numeric(wind.activeSeconds, 52)), 0)
	local windDown = math.max(numeric(wind.windDownSeconds, 4), 0)
	return windUp, active, windDown, windUp + active + windDown
end

function GameEvents.StormTimings(config)
	config = config or GameEvents.GetEvent(GameEvents.Ids.Stormy)
	local storm = type(config) == "table" and config.storm or nil
	storm = type(storm) == "table" and storm or {}
	local windUp = math.max(numeric(storm.windUpSeconds, 5), 0)
	local turn = math.max(numeric(storm.plotTurnSeconds, 30), 0)
	local maxTurns = math.max(math.floor(numeric(storm.maxPlotTurns, 8)), 0)
	local windDown = math.max(numeric(storm.windDownSeconds, 5), 0)
	return windUp, turn * maxTurns, windDown, windUp + (turn * maxTurns) + windDown
end

local function scheduledStartAt(config, now)
	local cadence = math.max(numeric(config.cadenceSeconds, 0), 1)
	local offset = numeric(config.offsetSeconds, 0)
	return math.floor((now - offset) / cadence) * cadence + offset
end

local function instanceId(config, startsAt)
	return string.format("%s_%s_%d", tostring(config.layer), tostring(config.eventId), math.floor(startsAt))
end

local function scheduledInstance(config, startsAt)
	local duration = GameEvents.TotalDuration(config)
	return {
		instanceId = instanceId(config, startsAt),
		eventId = config.eventId,
		layer = config.layer,
		source = config.source or GameEvents.Sources.Schedule,
		startsAt = startsAt,
		endsAt = startsAt + duration,
		priority = numeric(config.priority, 0),
		displayPriority = numeric(config.displayPriority, 0),
		displayFrame = config.displayFrame or config.eventId,
	}
end

local function comparePriority(left, right)
	if not right then
		return true
	end
	local leftPriority = numeric(left.priority, 0)
	local rightPriority = numeric(right.priority, 0)
	if leftPriority ~= rightPriority then
		return leftPriority > rightPriority
	end
	return tostring(left.eventId) < tostring(right.eventId)
end

local function compareNext(left, right)
	if not right then
		return true
	end
	if left.startsAt ~= right.startsAt then
		return left.startsAt < right.startsAt
	end
	return comparePriority(left, right)
end

local function completionBlockApplies(record, blocksByLayer)
	if type(record) ~= "table" or type(blocksByLayer) ~= "table" then
		return false
	end
	local block = blocksByLayer[record.layer]
	if type(block) ~= "table" then
		return false
	end
	local blockUntil = numeric(block.untilTime, 0)
	if blockUntil <= numeric(record.startsAt, 0) then
		return false
	end
	if tostring(block.instanceId or "") == tostring(record.instanceId or "") then
		return false
	end
	return numeric(record.priority, 0) < numeric(block.priority, 0)
end

function GameEvents.WeatherSnapshot(now, suppressedInstanceIds, completionBlocksByLayer)
	now = numeric(now, os.time())
	suppressedInstanceIds = type(suppressedInstanceIds) == "table" and suppressedInstanceIds or {}
	completionBlocksByLayer = type(completionBlocksByLayer) == "table" and completionBlocksByLayer or {}
	local active = nil
	local nextWeather = nil

	for _, config in pairs(GameEvents.EventConfigs) do
		if config.layer == GameEvents.Layers.Weather and config.cadenceSeconds then
			local start = scheduledStartAt(config, now)
			local current = scheduledInstance(config, start)
			if not suppressedInstanceIds[current.instanceId]
				and now >= current.startsAt
				and now < current.endsAt
				and not completionBlockApplies(current, completionBlocksByLayer)
				and comparePriority(current, active) then
				active = current
			end

			local nextStart = start
			if now >= start then
				nextStart = start + math.max(numeric(config.cadenceSeconds, 0), 1)
			end
			local nextCandidate = scheduledInstance(config, nextStart)
			if not completionBlockApplies(nextCandidate, completionBlocksByLayer)
				and compareNext(nextCandidate, nextWeather) then
				nextWeather = nextCandidate
			end
		end
	end

	local activeRecords = {}
	if active then
		activeRecords[1] = active
	end

	return {
		activeRecords = activeRecords,
		nextWeather = nextWeather,
	}
end

function GameEvents.FormatDuration(seconds)
	seconds = math.max(math.ceil(numeric(seconds, 0)), 0)
	local minutes = math.floor(seconds / 60)
	local remainingSeconds = seconds % 60
	if minutes > 0 then
		return string.format("%dm %02ds", minutes, remainingSeconds)
	end
	return string.format("%ds", remainingSeconds)
end

return GameEvents
