local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameEvents = {}

GameEvents.RuntimeFolderName = "GameEvents"
GameEvents.ActiveFolderName = "Active"
GameEvents.MaxReplicatedActiveEvents = 8

GameEvents.Layers = {
	Weather = "Weather",
	Chaos = "Chaos",
	-- The Travelling Merchant sits on its own layer purely so it never
	-- arbitrates against anything: a merchant visit is a shop opening, not a
	-- weather condition, and it should neither displace a storm nor be
	-- displaced by one. maxActive 1 keeps that to a single carriage.
	Merchant = "Merchant",
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
	Bee = "Bee",
	Sprinkle = "Sprinkle",
	Merchant = "Merchant",
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
	[GameEvents.Layers.Merchant] = {
		stacking = "Multiple",
		maxActive = 1,
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
		-- DisasterPool member: scheduled through GameEvents.DisasterPool (one
		-- disaster per hour at :30, fixed rotation), not by cadence/offset.
		-- cadenceSeconds kept for reference/manual paths only.
		pooled = true,
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
		-- DisasterPool member (see Stormy comment).
		pooled = true,
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
		-- DisasterPool member (see Stormy comment).
		pooled = true,
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
		-- DisasterPool member (see Stormy comment).
		pooled = true,
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
		-- Admin-party Aliens run until explicitly stopped. This is both the
		-- default record length and the hidden failsafe ceiling.
		maxGlobalDurationSeconds = 60 * 60,
		appliedMutationId = "Alien",
		alien = {
			failsafeDurationSeconds = 60 * 60,
			windUpSeconds = 10,
			plotVisitSeconds = 20,
			-- After each consumed turn the UFO breaks off and laps the map
			-- before the next visit. Throttles the overall mutation rate
			-- without shortening the hover; 0 disables the break.
			interVisitRoamSeconds = 15,
			-- Keep at most one pending turn per player and refresh this rolling
			-- queue after every visit. Eight matches the live server size while
			-- still allowing fair rotation if that size changes.
			maxQueuedTurns = 8,
			-- Both the failsafe expiry and an operator stop fade the sky,
			-- lighting and UFO out over this window.
			windDownSeconds = 20,
			minZapsPerVisit = 1,
			maxZapsPerVisit = 3,
			zapAppearSeconds = 0.25,
			zapFadeSeconds = 1.2,
			ufoMaxTiltDegrees = 15,
			ufoTravelSeconds = 4,
			zapSoundRange = 500,
		},
	},
	[GameEvents.Ids.Bee] = {
		eventId = GameEvents.Ids.Bee,
		layer = GameEvents.Layers.Weather,
		source = GameEvents.Sources.Schedule,
		displayFrame = "Bee",
		-- Hourly at :00. Outranks the coinciding Windy occurrence (Weather is
		-- Single stacking); the :30 disaster-pool slot never intersects.
		cadenceSeconds = 60 * 60,
		offsetSeconds = 0,
		priority = 6,
		displayPriority = 6,
		preNoticeSeconds = 5,
		preNoticeText = "You hear buzzing in the distance...",
		appliedMutationId = "Pollinated",
		bee = {
			windUpSeconds = 5,
			-- One 60s turn per queued farm ("the bees stay for a minute"), up
			-- to 8. The session timer sizes itself to the turn queue like the
			-- tornado; travelEstimateSeconds is the per-turn scheduling
			-- estimate for the swarm's farm-to-farm transit -- real legs are
			-- distance-based at transitSpeedStuds, clamped below.
			plotTurnSeconds = 60,
			maxPlotTurns = 8,
			travelEstimateSeconds = 9,
			transitSpeedStuds = 18,
			travelMinSeconds = 3,
			travelMaxSeconds = 30,
			emptyQueueGraceSeconds = 10,
			-- Covers the return flight to the hive plus the tween-out.
			windDownSeconds = 13,
			minPollinationsPerPlot = 4,
			maxPollinationsPerPlot = 6,
			hoverSeconds = 15,
			hoverHeightStuds = 2,
			hoverOrbitRadius = 1.2,
			hoverOrbitPeriod = 3,
			beesPerSwarm = 9,
			altitudeMin = 3,
			altitudeMax = 6,
			bobAmplitude = 0.5,
			bobPeriod = 1.6,
			roamSpeedStuds = 9,
			waypointPauseChance = 0.25,
			pauseSecondsMin = 0.5,
			pauseSecondsMax = 1.5,
			segmentSecondsMin = 1.5,
			segmentSecondsMax = 4,
			wingFlapHz = 13,
			wingFlapRadians = math.rad(55),
			maxBankRadians = math.rad(35),
			cellPaddingStuds = 2,
			targetRetrySeconds = 2,
			-- Per-bee one-shot buzz (ReplicatedStorage.Sounds.BeeBuzz), played
			-- once every buzzMin..buzzMax seconds per bee, no loop.
			buzzMinSeconds = 10,
			buzzMaxSeconds = 30,
			buzzSoundRange = 70,
		},
	},
	[GameEvents.Ids.Sprinkle] = {
		eventId = GameEvents.Ids.Sprinkle,
		layer = GameEvents.Layers.Chaos,
		source = GameEvents.Sources.AdminCommand,
		-- No Sprinkle frame is authored under HUD.TopBar.CurrentEvent, so
		-- EventHudController skips this event entirely (see its HIDDEN_EVENT_IDS).
		-- Player feedback is toasts. Authoring a frame later is a one-line change.
		displayFrame = nil,
		-- Below Alien so a concurrent admin party keeps the TopBar and the Chaos
		-- layer's displacement ordering; Chaos.maxActive = 3 fits both.
		priority = 99,
		displayPriority = 99,
		-- Turn-based: a normal run ends on its own once every queued player has had
		-- their single turn. This is the record length and the hidden failsafe
		-- ceiling only -- the operator's Stop and the drained queue both finish it
		-- long before this in practice.
		maxGlobalDurationSeconds = 30 * 60,
		-- Sprinkle boosts XP in place and leaves no permanent tag on the food.
		appliedMutationId = nil,
		sprinkle = {
			failsafeDurationSeconds = 30 * 60,
			-- Covers the 200-stud entrance fall plus the landing settle.
			windUpSeconds = 4,
			-- Covers the 200-stud exit rise plus the transparency fade, paced so
			-- players can actually watch him leave (~33 studs/s) rather than
			-- having him vanish upward in a second.
			windDownSeconds = 6,
			entranceFallStuds = 200,
			exitRiseStuds = 200,

			-- Tied to the rig's scale, not picked in isolation. The client plays the
			-- stock R15 walk at speedStuds / (16 * rigScale) (see
			-- SprinkleEventController), and that cycle was tuned to read well around
			-- 0.4 -- a giant taking slow, long strides. The rig is ScaleTo(7), so 45
			-- lands on 0.40; leaving this at the old 20 ran the legs at 0.18 and he
			-- moon-walked across the farm. Rescale the rig and this wants
			-- 16 * newScale * 0.4 to keep the same gait.
			walkSpeedStuds = 45,
			travelMinSeconds = 3,
			travelMaxSeconds = 25,
			turnRateDegrees = 360,
			-- Ease applied at both ends of every move so arriving at a stop
			-- decelerates instead of stopping dead.
			phaseEaseSeconds = 0.4,

			-- A grid cell is 16x16 and a full plot is only ~80x176, so a radius
			-- much above this would cover the whole plot from anywhere on it and
			-- make the stops invisible. Separation matches the radius so the
			-- chosen areas never overlap.
			--
			-- Stop COUNT is driven by how much plot the player has bought, not by
			-- crop layout: at or below singleStopMaxCells a farm always gets
			-- exactly one sprinkle (a starter plot fits inside one wave anyway),
			-- and above it the turn gets a random 1..maxStopsPerPlot so repeat
			-- events do not play out identically.
			singleStopMaxCells = 4,
			maxStopsPerPlot = 3,
			waveRadiusStuds = 24,
			minStopSeparationStuds = 24,
			standOffsetStuds = 6,

			waveSeconds = 5,
			waveXPMultiplier = 1.5,
			-- The boost is applied as this many equal steps across waveSeconds so
			-- patch fruit visibly swells (clients derive scale from the replicated
			-- XP anchor, so the ramp needs no client code). See RampStepMultiplier.
			waveRampSteps = 10,
			waveRaiseSeconds = 0.6,
			waveLowerSeconds = 0.6,
			armRaiseDegrees = 100,
			-- The wave is a two-axis stir, not a flat wiper: waveSwingDegrees is
			-- the lateral sweep and waveForeAftDegrees the fore/aft component 90
			-- degrees out of phase, so the wand tip traces an ellipse. Elbow,
			-- wrist, head and waist read the same wave through SprinkleEvent.WaveLag
			-- and therefore trail it, which is what makes the arm whip and the head
			-- follow the wand instead of everything moving as one rigid piece.
			waveSwingDegrees = 38,
			waveForeAftDegrees = 20,
			elbowSwingDegrees = 24,
			wristSwingDegrees = 30,
			headSwingDegrees = 18,
			headNodDegrees = 7,
			waistSwingDegrees = 9,
			waveSwingHz = 1.15,

			-- Tuned down from 12-per-0.15s, which put ~400 live particles on screen
			-- at once (the emitter's authored Lifetime is 5-10s, so bursts stack)
			-- and whited out the whole farm. ~14 bursts of 4 reads as a sprinkle.
			sparkleBurstCount = 4,
			sparkleBurstSeconds = 0.35,
			magicSoundSeconds = 1,
			-- MagicSound is authored RollOffMaxDistance = 10000 (audible map-wide);
			-- SoundEffects.Play must be given this explicit range.
			magicSoundRange = 200,
			magicSoundPitchVariance = 0.3,

			-- Turn-based: ONE turn (1-3 stops) per player, never a revisit, and the
			-- event ends once everyone queued has had theirs. Eight matches the live
			-- server size. failsafeDurationSeconds is only the ceiling -- a normal
			-- run completes early, as soon as the queue drains.
			maxQueuedTurns = 8,
			-- Short linger after the last turn so someone who becomes eligible just
			-- as the queue empties still gets a turn (same idea as the storm's and
			-- the bee's emptyQueueGraceSeconds). New joiners go on the END of the
			-- queue, and a new arrival restarts this grace.
			--
			-- Deliberately much shorter than the storm's and bee's 10s: this is dead
			-- time during which the whole server watches him stand still before he
			-- jumps out, and the poll is once a second so 3s still catches a joiner.
			emptyQueueGraceSeconds = 3,
			interVisitPauseSeconds = 1,
		},
	},
	[GameEvents.Ids.Merchant] = {
		eventId = GameEvents.Ids.Merchant,
		layer = GameEvents.Layers.Merchant,
		source = GameEvents.Sources.Schedule,
		-- No Merchant frame is authored under HUD.TopBar.CurrentEvent, so
		-- EventHudController skips this event entirely (see its
		-- HIDDEN_EVENT_IDS). The carriage carries its own "leaving in ..."
		-- billboard, which is where a player actually looks. Authoring a frame
		-- later is a one-line change.
		displayFrame = nil,
		-- Hourly on the hour. This deliberately runs alongside the Bee swarm
		-- (same cadence and offset): the two are at opposite ends of the map
		-- and want different things from the player, so they were kept
		-- together rather than staggered.
		cadenceSeconds = 60 * 60,
		offsetSeconds = 0,
		-- Its own layer, so these only order it against itself.
		priority = 1,
		displayPriority = 1,
		preNoticeSeconds = 5,
		preNoticeText = "A travelling merchant is arriving...",
		-- The merchant trades; he does not touch food already on the plot.
		appliedMutationId = nil,
		-- Flat window, so TotalDuration's durationSeconds fallback covers it
		-- and no Merchant timings function is needed.
		durationSeconds = 10 * 60,
		maxGlobalDurationSeconds = 10 * 60,
	},
}

-- One disaster per epoch hour at :30, rotating in fixed order (slot = epoch
-- hour, members[slot % 4 + 1]) -- pure math so every server independently
-- agrees, same style as the old StormChaser cycle. Members carry
-- `pooled = true` in EventConfigs, which removes them from per-config
-- cadence scheduling in WeatherSnapshot; manual/live-event paths are
-- unaffected.
GameEvents.DisasterPool = {
	slotSeconds = 60 * 60,
	offsetSeconds = 30 * 60,
	members = {
		GameEvents.Ids.Stormy,
		GameEvents.Ids.Earthquake,
		GameEvents.Ids.Tsunami,
		GameEvents.Ids.Tornado,
	},
}

function GameEvents.DisasterForSlot(slotIndex)
	local members = GameEvents.DisasterPool.members
	return members[math.floor(tonumber(slotIndex) or 0) % #members + 1]
end

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
	if type(config.bee) == "table" then
		return select(4, GameEvents.BeeTimings(config))
	end
	if type(config.sprinkle) == "table" then
		return select(4, GameEvents.SprinkleTimings(config))
	end
	return math.max(numeric(config.durationSeconds, 0), 0)
end

-- windUp, active, windDown, total. The active window is the config-max turn
-- queue (turn + per-turn transit estimate, times maxPlotTurns); the live
-- session floats its endsAt below this cap as the queue grows and shrinks,
-- exactly like the tornado. Total = 5 + 8 * (60 + 9) + 13 = 570s (9.5 min),
-- ending 30s before the :10 Windy slot even fully extended.
function GameEvents.BeeTimings(config)
	config = config or GameEvents.GetEvent(GameEvents.Ids.Bee)
	local bee = type(config) == "table" and config.bee or nil
	bee = type(bee) == "table" and bee or {}
	local windUp = math.max(numeric(bee.windUpSeconds, 5), 0)
	local turn = math.max(numeric(bee.plotTurnSeconds, 60), 0)
	local travel = math.max(numeric(bee.travelEstimateSeconds, 9), 0)
	local maxTurns = math.max(math.floor(numeric(bee.maxPlotTurns, 8)), 0)
	local windDown = math.max(numeric(bee.windDownSeconds, 13), 0)
	local active = (turn + travel) * maxTurns
	return windUp, active, windDown, windUp + active + windDown
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
	local windDown = math.max(numeric(alien.windDownSeconds, 6), 0)
	local total = math.max(numeric(alien.failsafeDurationSeconds, 60 * 60), windUp + windDown)
	return windUp, math.max(total - windUp - windDown, 0), windDown, total
end

-- Same shape as AlienTimings: an admin-toggled event whose record length IS its
-- failsafe, so the active window is whatever is left after the entrance fall and
-- the exit jump.
function GameEvents.SprinkleTimings(config)
	config = config or GameEvents.GetEvent(GameEvents.Ids.Sprinkle)
	local sprinkle = type(config) == "table" and config.sprinkle or nil
	sprinkle = type(sprinkle) == "table" and sprinkle or {}
	local windUp = math.max(numeric(sprinkle.windUpSeconds, 4), 0)
	local windDown = math.max(numeric(sprinkle.windDownSeconds, 3), 0)
	local total = math.max(numeric(sprinkle.failsafeDurationSeconds, 30 * 60), windUp + windDown)
	return windUp, math.max(total - windUp - windDown, 0), windDown, total
end

-- Multiplier for ramp step `step` of `steps`, so that the product of every step
-- is EXACTLY waveXPMultiplier no matter how many steps are used:
--
--   m_k = (1 + (M-1)*k/N) / (1 + (M-1)*(k-1)/N)
--
-- Each step re-reads the target's current XP, so natural growth during the wave
-- is preserved rather than frozen, and rounding cannot drift the total.
function GameEvents.SprinkleRampStepMultiplier(multiplier, step, steps)
	multiplier = numeric(multiplier, 1)
	steps = math.max(math.floor(numeric(steps, 1)), 1)
	step = math.clamp(math.floor(numeric(step, 1)), 1, steps)
	local gain = multiplier - 1
	local previous = 1 + gain * ((step - 1) / steps)
	if previous <= 0 then
		return 1
	end
	return (1 + gain * (step / steps)) / previous
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

	local function considerCandidate(current)
		if not suppressedInstanceIds[current.instanceId]
			and now >= current.startsAt
			and now < current.endsAt
			and not completionBlockApplies(current, completionBlocksByLayer)
			and comparePriority(current, active) then
			active = current
		end
	end

	local function considerNext(nextCandidate)
		if not completionBlockApplies(nextCandidate, completionBlocksByLayer)
			and compareNext(nextCandidate, nextWeather) then
			nextWeather = nextCandidate
		end
	end

	for _, config in pairs(GameEvents.EventConfigs) do
		-- DisasterPool members are scheduled through the pool below, never by
		-- their own cadence/offset.
		if config.layer == GameEvents.Layers.Weather and config.cadenceSeconds and not config.pooled then
			local start = scheduledStartAt(config, now)
			considerCandidate(scheduledInstance(config, start))

			local nextStart = start
			if now >= start then
				nextStart = start + math.max(numeric(config.cadenceSeconds, 0), 1)
			end
			considerNext(scheduledInstance(config, nextStart))
		end
	end

	-- Disaster pool: one member per slot, chosen by the deterministic
	-- fixed rotation in DisasterForSlot.
	local pool = GameEvents.DisasterPool
	local slotSeconds = math.max(numeric(pool.slotSeconds, 3600), 1)
	local poolOffset = numeric(pool.offsetSeconds, 0)
	local slotStart = math.floor((now - poolOffset) / slotSeconds) * slotSeconds + poolOffset
	local currentConfig = GameEvents.GetEvent(GameEvents.DisasterForSlot(math.floor(slotStart / slotSeconds)))
	if currentConfig then
		considerCandidate(scheduledInstance(currentConfig, slotStart))
	end
	local nextSlotStart = slotStart + slotSeconds
	local nextConfig = GameEvents.GetEvent(GameEvents.DisasterForSlot(math.floor(nextSlotStart / slotSeconds)))
	if nextConfig then
		considerNext(scheduledInstance(nextConfig, nextSlotStart))
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

-- Cadence scheduling for a non-Weather layer.
--
-- WeatherSnapshot deliberately stays separate rather than being generalised:
-- it also owns the disaster pool and the nextWeather lookahead, and it collapses
-- its layer to a single winner by priority. A layer like Merchant wants neither
-- -- it just wants "is my scheduled window open right now". Every record this
-- produces still goes through ApplyLayerConfigs with the rest, so the layer's
-- own maxActive is what finally bounds it.
--
-- Returns an array of active records (possibly empty), plus the next start time
-- for the layer so a caller can show a countdown to the next visit.
function GameEvents.ScheduleSnapshot(layer, now, suppressedInstanceIds, completionBlocksByLayer)
	now = numeric(now, os.time())
	suppressedInstanceIds = type(suppressedInstanceIds) == "table" and suppressedInstanceIds or {}
	completionBlocksByLayer = type(completionBlocksByLayer) == "table" and completionBlocksByLayer or {}

	local activeRecords = {}
	local nextStartsAt = nil

	for _, config in pairs(GameEvents.EventConfigs) do
		if config.layer == layer and config.cadenceSeconds and not config.pooled then
			local start = scheduledStartAt(config, now)
			local record = scheduledInstance(config, start)
			if not suppressedInstanceIds[record.instanceId]
				and now >= record.startsAt
				and now < record.endsAt
				and not completionBlockApplies(record, completionBlocksByLayer) then
				activeRecords[#activeRecords + 1] = record
			end

			local upcoming = start
			if now >= start then
				upcoming = start + math.max(numeric(config.cadenceSeconds, 0), 1)
			end
			if nextStartsAt == nil or upcoming < nextStartsAt then
				nextStartsAt = upcoming
			end
		end
	end

	table.sort(activeRecords, comparePriority)

	return {
		activeRecords = activeRecords,
		nextStartsAt = nextStartsAt,
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
