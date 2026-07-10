local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
	Tornado = "Tornado",
	Tsunami = "Tsunami",
	Earthquake = "Earthquake",
	Alien = "Alien",
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
		cadenceSeconds = 60 * 60,
		offsetSeconds = 30 * 60,
		priority = 2,
		displayPriority = 2,
		preNoticeSeconds = 5,
		preNoticeText = "A storm is approaching",
		appliedMutationId = "Lightning",
		storm = {
			windUpSeconds = 10,
			-- One 30s turn per eligible player, up to 8; the session timer sizes
			-- itself to the turn queue like the tornado (see Tornado comment).
			plotTurnSeconds = 30,
			maxPlotTurns = 8,
			windDownSeconds = 10,
			-- Short linger after the last turn so a player who joins right as
			-- the queue empties still gets one; baked into the published timer.
			emptyQueueGraceSeconds = 10,
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
	[GameEvents.Ids.Tornado] = {
		eventId = GameEvents.Ids.Tornado,
		layer = GameEvents.Layers.Weather,
		source = GameEvents.Sources.Schedule,
		displayFrame = "Tornado",
		-- StormChaser rotation: Earthquake -> Tsunami -> Tornado, one per epoch
		-- hour (slot = hour % 3), so each event recurs every 3 hours.
		cadenceSeconds = 3 * 60 * 60,
		offsetSeconds = 2 * 60 * 60,
		priority = 3,
		displayPriority = 3,
		preNoticeSeconds = 5,
		preNoticeText = "A tornado is forming...",
		appliedMutationId = "Twisted",
		tornado = {
			windUpSeconds = 10,
			-- One 45s turn per eligible player, up to 8. The session timer sizes
			-- itself to the turn queue (a join adds a turn, a leave removes one)
			-- and the published record follows, clamped to the config-max window
			-- of 10 + 45*8 + 10 = 380s.
			plotTurnSeconds = 45,
			maxPlotTurns = 8,
			windDownSeconds = 10,
			-- Short linger after the last turn so a player who joins right as
			-- the queue empties still gets one; baked into the published timer
			-- so the countdown runs smoothly to zero.
			emptyQueueGraceSeconds = 10,
			minMutationsPerPlot = 4,
			maxMutationsPerPlot = 8,
			targetRetrySeconds = 2,
			tornadoSoundRange = 500,
			funnelTouchdownSeconds = 1,
			funnelTravelSeconds = 4,
			funnelFadeSeconds = 0.75,
			wanderWaypointSeconds = 2.5,
			spinRevolutionsPerSecond = 1.5,
		},
	},
	[GameEvents.Ids.Tsunami] = {
		eventId = GameEvents.Ids.Tsunami,
		layer = GameEvents.Layers.Weather,
		source = GameEvents.Sources.Schedule,
		displayFrame = "Tsunami",
		-- StormChaser rotation slot 1 (see Tornado comment).
		cadenceSeconds = 3 * 60 * 60,
		offsetSeconds = 60 * 60,
		priority = 4,
		displayPriority = 4,
		preNoticeSeconds = 5,
		preNoticeText = "A tsunami is approaching...",
		appliedMutationId = "Aqua",
		tsunami = {
			windUpSeconds = 6,
			windDownSeconds = 5,
			studsPerSecond = 100,
			-- 6 windUp + ~45.7 wave travel (map length / 100 studs/s) + 273
			-- underwater + 5 windDown ~= 330s total.
			underwaterSeconds = 273,
			underwaterGravity = 25,
			minMutationsPerPlot = 4,
			maxMutationsPerPlot = 8,
			targetRetrySeconds = 2,
			hitCheckSeconds = 0.1,
			entranceSinkStuds = 260,
			lightingTweenInSeconds = 0.75,
			lightingTweenOutSeconds = 3,
		},
	},
	[GameEvents.Ids.Earthquake] = {
		eventId = GameEvents.Ids.Earthquake,
		layer = GameEvents.Layers.Weather,
		source = GameEvents.Sources.Schedule,
		displayFrame = "Earthquake",
		-- StormChaser rotation slot 0 (see Tornado comment).
		cadenceSeconds = 3 * 60 * 60,
		offsetSeconds = 0,
		priority = 5,
		displayPriority = 5,
		preNoticeSeconds = 5,
		preNoticeText = "The ground begins to tremble...",
		appliedMutationId = "Shaken",
		earthquake = {
			windUpSeconds = 6,
			-- 6 + 290 + 4 = 300s total. The active window plays as pulsed tremor
			-- bursts with calm between (see EarthquakePulses), not continuous shake.
			durationSeconds = 290,
			windDownSeconds = 4,
			minMutationsPerPlot = 4,
			maxMutationsPerPlot = 8,
			targetRetrySeconds = 2,
			burstSeconds = 20,
			calmSecondsMin = 20,
			calmSecondsMax = 20,
			swellSeconds = 5,
			burstEaseSeconds = 5,
		},
	},
	[GameEvents.Ids.Alien] = {
		eventId = GameEvents.Ids.Alien,
		layer = GameEvents.Layers.Chaos,
		source = GameEvents.Sources.AdminCommand,
		displayFrame = "Alien",
		priority = 100,
		displayPriority = 100,
		maxGlobalDurationSeconds = 10 * 60,
		appliedMutationId = "Alien",
		alien = {
			windUpSeconds = 10,
			plotVisitSeconds = 20,
			maxVisitsPerPlayer = 3,
			maxTotalVisits = 24,
			windDownSeconds = 6,
			minZapsPerVisit = 1,
			maxZapsPerVisit = 3,
			zapAppearSeconds = 0.25,
			zapFadeSeconds = 1.2,
			ufoMaxTiltDegrees = 15,
			ufoTravelSeconds = 4,
			zapSoundRange = 500,
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
	if type(config.tornado) == "table" then
		return select(4, GameEvents.TornadoTimings(config))
	end
	if type(config.tsunami) == "table" then
		return select(4, GameEvents.TsunamiTimings(config))
	end
	if type(config.earthquake) == "table" then
		return select(4, GameEvents.EarthquakeTimings(config))
	end
	if type(config.alien) == "table" then
		return select(4, GameEvents.AlienTimings(config))
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

function GameEvents.TornadoTimings(config)
	config = config or GameEvents.GetEvent(GameEvents.Ids.Tornado)
	local tornado = type(config) == "table" and config.tornado or nil
	tornado = type(tornado) == "table" and tornado or {}
	local windUp = math.max(numeric(tornado.windUpSeconds, 10), 0)
	local turn = math.max(numeric(tornado.plotTurnSeconds, 20), 0)
	local maxTurns = math.max(math.floor(numeric(tornado.maxPlotTurns, 8)), 0)
	local windDown = math.max(numeric(tornado.windDownSeconds, 10), 0)
	return windUp, turn * maxTurns, windDown, windUp + (turn * maxTurns) + windDown
end

-- The tsunami wave's spawn, touch slab, and end line live on the Studio-owned
-- template (ReplicatedStorage.Assets.Misc.Tsunami), which never moves during
-- the event -- both server and client derive the identical deterministic wave
-- position from it. The lookup is non-yielding with numeric fallbacks so a
-- degraded require (tests, early boot) still gets sane values; only a
-- successful read is cached. Slab math assumes the template's authored
-- identity rotation (axis-aligned parts).
local TSUNAMI_GEOMETRY_FALLBACK = {
	meshStartZ = 1101.16,
	endZ = -3466.53,
	touchCenterX = 52.3,
	touchCenterY = 42.75,
	touchStartZ = 1178.3,
	touchSizeX = 2047.9,
	touchSizeY = 266.9,
	touchSizeZ = 25.4,
}

local cachedTsunamiGeometry = nil

function GameEvents.TsunamiGeometry()
	if cachedTsunamiGeometry then
		return cachedTsunamiGeometry
	end
	local geometry = nil
	pcall(function()
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local misc = assets and assets:FindFirstChild("Misc")
		local template = misc and misc:FindFirstChild("Tsunami")
		local mesh = template and template:FindFirstChild("TsunamiMesh")
		local touch = template and template:FindFirstChild("TouchPart")
		local endMarker = template and template:FindFirstChild("TsunamiEnd")
		if mesh and mesh:IsA("BasePart")
			and touch and touch:IsA("BasePart")
			and endMarker and endMarker:IsA("BasePart") then
			geometry = {
				meshStartZ = mesh.Position.Z,
				endZ = endMarker.Position.Z,
				touchCenterX = touch.Position.X,
				touchCenterY = touch.Position.Y,
				touchStartZ = touch.Position.Z,
				touchSizeX = touch.Size.X,
				touchSizeY = touch.Size.Y,
				touchSizeZ = touch.Size.Z,
			}
		end
	end)
	if geometry then
		cachedTsunamiGeometry = geometry
		return geometry
	end
	return TSUNAMI_GEOMETRY_FALLBACK
end

function GameEvents.TsunamiTravelSeconds(tsunami)
	tsunami = type(tsunami) == "table" and tsunami or {}
	local studsPerSecond = math.max(numeric(tsunami.studsPerSecond, 50), 1)
	local geometry = GameEvents.TsunamiGeometry()
	return math.max(geometry.meshStartZ - geometry.endZ, 0) / studsPerSecond
end

function GameEvents.TsunamiTimings(config)
	config = config or GameEvents.GetEvent(GameEvents.Ids.Tsunami)
	local tsunami = type(config) == "table" and config.tsunami or nil
	tsunami = type(tsunami) == "table" and tsunami or {}
	local windUp = math.max(numeric(tsunami.windUpSeconds, 6), 0)
	-- The active window covers the full wave sweep plus one underwater phase,
	-- so players hit at the end of travel finish before the record ends.
	local travel = GameEvents.TsunamiTravelSeconds(tsunami)
	local underwater = math.max(numeric(tsunami.underwaterSeconds, 120), 0)
	local active = travel + underwater
	local windDown = math.max(numeric(tsunami.windDownSeconds, 5), 0)
	return windUp, active, windDown, windUp + active + windDown
end

function GameEvents.EarthquakeTimings(config)
	config = config or GameEvents.GetEvent(GameEvents.Ids.Earthquake)
	local earthquake = type(config) == "table" and config.earthquake or nil
	earthquake = type(earthquake) == "table" and earthquake or {}
	local windUp = math.max(numeric(earthquake.windUpSeconds, 6), 0)
	local active = math.max(numeric(earthquake.durationSeconds, 30), 0)
	local windDown = math.max(numeric(earthquake.windDownSeconds, 4), 0)
	return windUp, active, windDown, windUp + active + windDown
end

-- Deterministic tremor-burst schedule for the earthquake's active window:
-- burstSeconds of shake, then a seeded-random calm gap, repeating until the
-- window ends. Seeded from the record's startsAt (identical on the server
-- session, the replicated record, and dev-command records), so the server's
-- mutation hits and every client's shake -- including late joiners -- agree
-- on the exact same bursts. Offsets are seconds relative to startsAt.
function GameEvents.EarthquakePulses(config, startsAt)
	local windUp, active = GameEvents.EarthquakeTimings(config)
	local earthquake = type(config) == "table" and config.earthquake or nil
	earthquake = type(earthquake) == "table" and earthquake or {}
	local burstSeconds = math.max(numeric(earthquake.burstSeconds, 8), 1)
	local calmMin = math.max(numeric(earthquake.calmSecondsMin, 25), 1)
	local calmMax = math.max(numeric(earthquake.calmSecondsMax, 35), calmMin)
	local activeEnd = windUp + active
	local rand = Random.new(math.floor(numeric(startsAt, 0)))
	local pulses = {}
	local cursor = windUp
	while cursor < activeEnd do
		pulses[#pulses + 1] = {
			startOffset = cursor,
			endOffset = math.min(cursor + burstSeconds, activeEnd),
		}
		cursor += burstSeconds + rand:NextNumber(calmMin, calmMax)
	end
	return pulses
end

-- Shake/audio gates in [0, 1] over the pulse schedule. Both fades live
-- entirely inside the burst window -- rise from the burst's start, fall to
-- silence exactly at its end -- so the calm gaps between bursts stay truly
-- quiet and still. Shake ramps over easeSeconds on both edges; audio rises
-- over swellSeconds (its slower swell doubles as the tremor's tell) and falls
-- with the shake. Pure function of elapsed, so late joiners land
-- mid-schedule with no bookkeeping.
function GameEvents.EarthquakePulseFactors(elapsed, pulses, swellSeconds, easeSeconds)
	swellSeconds = math.max(numeric(swellSeconds, 5), 0.01)
	easeSeconds = math.max(numeric(easeSeconds, 5), 0.01)
	local shakeFactor = 0
	local audioFactor = 0
	for _, pulse in ipairs(type(pulses) == "table" and pulses or {}) do
		local fadeOut = math.clamp((pulse.endOffset - elapsed) / easeSeconds, 0, 1)
		local shake = math.min(math.clamp((elapsed - pulse.startOffset) / easeSeconds, 0, 1), fadeOut)
		local audio = math.min(math.clamp((elapsed - pulse.startOffset) / swellSeconds, 0, 1), fadeOut)
		shakeFactor = math.max(shakeFactor, shake)
		audioFactor = math.max(audioFactor, audio)
	end
	return shakeFactor, audioFactor
end

function GameEvents.AlienTimings(config)
	config = config or GameEvents.GetEvent(GameEvents.Ids.Alien)
	local alien = type(config) == "table" and config.alien or nil
	alien = type(alien) == "table" and alien or {}
	local windUp = math.max(numeric(alien.windUpSeconds, 10), 0)
	local visit = math.max(numeric(alien.plotVisitSeconds, 8), 0)
	local maxVisits = math.max(math.floor(numeric(alien.maxTotalVisits, 24)), 0)
	local windDown = math.max(numeric(alien.windDownSeconds, 6), 0)
	return windUp, visit * maxVisits, windDown, windUp + (visit * maxVisits) + windDown
end

local function compareLayerRecords(left, right)
	local leftPriority = numeric(left.priority, 0)
	local rightPriority = numeric(right.priority, 0)
	if leftPriority ~= rightPriority then
		return leftPriority > rightPriority
	end
	local leftStartsAt = numeric(left.startsAt, 0)
	local rightStartsAt = numeric(right.startsAt, 0)
	if leftStartsAt ~= rightStartsAt then
		return leftStartsAt < rightStartsAt
	end
	return tostring(left.instanceId or "") < tostring(right.instanceId or "")
end

function GameEvents.ApplyLayerConfigs(records)
	if type(records) ~= "table" then
		return {}
	end

	local recordsByLayer = {}
	for _, record in ipairs(records) do
		if type(record) == "table" and type(record.layer) == "string" then
			local layerRecords = recordsByLayer[record.layer]
			if not layerRecords then
				layerRecords = {}
				recordsByLayer[record.layer] = layerRecords
			end
			layerRecords[#layerRecords + 1] = record
		end
	end

	local selected = {}
	for layer, layerRecords in pairs(recordsByLayer) do
		table.sort(layerRecords, compareLayerRecords)
		local layerConfig = GameEvents.LayerConfigs[layer] or {}
		local maxActive = math.max(math.floor(numeric(layerConfig.maxActive, 1)), 0)
		if layerConfig.stacking == "Single" then
			maxActive = math.min(maxActive, 1)
		end
		for index = 1, math.min(#layerRecords, maxActive) do
			selected[#selected + 1] = layerRecords[index]
		end
	end

	table.sort(selected, compareLayerRecords)
	return selected
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
