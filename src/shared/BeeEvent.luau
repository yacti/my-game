-- BeeEvent: hourly meta event at the Honeycomb camp (Workspace.Map.BeeEvent).
-- One shared swarm of 9 bees leaves the BeeHive at the top of each epoch hour
-- and visits eligible players' farms one at a time (storm-style turn queue),
-- pollinating 4-6 foods per farm with the Pollinated mutation. Players deposit
-- harvested Pollinated food into the camp Jar for tiered seed rewards;
-- per-player progress lives in profile.Data.BeeEvent as a single numeric
-- deposit counter (one jar, one mutation), tiers loop 1 -> 2 -> ... -> 5 -> 1.
--
-- BeeEvent.Flight is the deterministic flight sim shared by every client: the
-- server authors one seed + cell list + pollination schedule per plot turn,
-- and each client derives identical bee positions as a pure function of
-- Workspace:GetServerTimeNow() -- no per-frame replication (same philosophy as
-- GameEvents.EarthquakePulses).
local Workspace = game:GetService("Workspace")

local BeeEvent = {}

-- Master switch: false hides the camp interactions and makes the server
-- refuse deposits, without tearing out the feature.
BeeEvent.Enabled = true

BeeEvent.SlotSeconds = 60 * 60

BeeEvent.MutationId = "Pollinated"

-- Required deposits into the Jar per tier, and the seed granted on
-- completion. Tiers loop: completing the last tier restarts at 1.
-- Reward seeds are EventOnly + Exclusive with PercentageOfBest patches
-- (0.5 / 0.75 / 1.25 / 2 / 3 of the best same-class static machine on the
-- plot). Foxglove and Hibiscus are the only patches above the Alien event's
-- Eyeshroom (1.66), matching their 250/500 deposit grind.
BeeEvent.Tiers = {
	{ required = 10, rewardSeedId = "WildflowerSeed" },
	{ required = 50, rewardSeedId = "SunflowerSeed" },
	-- The authored Studio SeedID is RosePatchSeed (not "RoseSeed").
	{ required = 100, rewardSeedId = "RosePatchSeed" },
	{ required = 250, rewardSeedId = "FoxgloveSeed" },
	{ required = 500, rewardSeedId = "HibiscusSeed" },
}

BeeEvent.MaxDepositDistance = 14

BeeEvent.MapFolderName = "BeeEvent"
BeeEvent.ActiveFolderName = "Active"
BeeEvent.HiveModelName = "Honeycomb"
BeeEvent.HiveMeshName = "BeeHive"
BeeEvent.HiveTimerGuiName = "NextBeeEvent"
BeeEvent.JarName = "Jar"
BeeEvent.JarGlassName = "Glass"
-- Studio-authored billboard name uses the "Pollenated" [sic] spelling; the
-- instance name must match exactly, so the typo is contained here.
BeeEvent.JarBillboardName = "PollenatedFoodAmount"
BeeEvent.BeekeeperName = "Beekeeper"
BeeEvent.BeekeeperDialogueGuiName = "BeekeeperDialogue"
BeeEvent.EventInactiveName = "EventInactive"
BeeEvent.BeeFaceName = "BeeFace"
BeeEvent.TeleportPartName = "EventTeleport"
BeeEvent.BeeTemplateName = "Bee"
BeeEvent.BeeSpawnPrefix = "BeeSpawn"
BeeEvent.BeeCount = 9

function BeeEvent.NormalizeTier(tier)
	tier = tonumber(tier)
	if tier == nil or tier ~= math.floor(tier) then
		return 1
	end
	if BeeEvent.Tiers[tier] then
		return tier
	end
	return 1
end

function BeeEvent.TierConfig(tier)
	return BeeEvent.Tiers[BeeEvent.NormalizeTier(tier)]
end

function BeeEvent.NextTier(tier)
	tier = BeeEvent.NormalizeTier(tier) + 1
	if BeeEvent.Tiers[tier] then
		return tier
	end
	return 1
end

function BeeEvent.RequiredFor(tier)
	return BeeEvent.TierConfig(tier).required
end

-- The next hourly bee event start after `now` (events run at the top of each
-- epoch hour, matching the Bee config's cadence/offset in GameEvents).
function BeeEvent.NextEventStart(now)
	return (math.floor((tonumber(now) or 0) / BeeEvent.SlotSeconds) + 1) * BeeEvent.SlotSeconds
end

function BeeEvent.FindMapFolder()
	local map = Workspace:FindFirstChild("Map")
	return map and map:FindFirstChild(BeeEvent.MapFolderName) or nil
end

function BeeEvent.FindActiveFolder()
	local eventFolder = BeeEvent.FindMapFolder()
	return eventFolder and eventFolder:FindFirstChild(BeeEvent.ActiveFolderName) or nil
end

function BeeEvent.FindJar(activeFolder)
	activeFolder = activeFolder or BeeEvent.FindActiveFolder()
	return activeFolder and activeFolder:FindFirstChild(BeeEvent.JarName) or nil
end

function BeeEvent.FindHiveMesh()
	local eventFolder = BeeEvent.FindMapFolder()
	local hive = eventFolder and eventFolder:FindFirstChild(BeeEvent.HiveModelName)
	local mesh = hive and hive:FindFirstChild(BeeEvent.HiveMeshName)
	return mesh and mesh:IsA("BasePart") and mesh or nil
end

-- World positions of the BeeSpawn1..9 attachments on the hive, indexed by bee
-- number. Missing attachments leave nil holes the caller must handle.
function BeeEvent.HiveSpawnPositions()
	local mesh = BeeEvent.FindHiveMesh()
	if not mesh then
		return nil
	end
	local positions = {}
	for index = 1, BeeEvent.BeeCount do
		local attachment = mesh:FindFirstChild(BeeEvent.BeeSpawnPrefix .. tostring(index))
		if attachment and attachment:IsA("Attachment") then
			positions[index] = attachment.WorldPosition
		end
	end
	return positions
end

---------------------------------------------------------------------------
-- Deterministic flight sim
---------------------------------------------------------------------------
-- Pure functions of (seed, beeIndex, time): identical on the server and on
-- every client, including late joiners. Nothing here reads Workspace.

BeeEvent.Flight = {}

local BEE_SEED_STRIDE = 7919
local BOB_PHASE_PER_BEE = 0.7
local ORBIT_BOB_STUDS = 0.2

local function numeric(value, fallback)
	value = tonumber(value)
	if value == nil then
		return fallback
	end
	return value
end

local function easedAlpha(alpha)
	-- Quad InOut without a TweenService dependency (pure module).
	alpha = math.clamp(alpha, 0, 1)
	if alpha < 0.5 then
		return 2 * alpha * alpha
	end
	return 1 - 2 * (1 - alpha) * (1 - alpha)
end

BeeEvent.Flight.EasedAlpha = easedAlpha

function BeeEvent.Flight.RngFor(seed, beeIndex)
	local base = (math.floor(numeric(seed, 0)) + math.floor(numeric(beeIndex, 0)) * BEE_SEED_STRIDE) % 0x7FFFFFFF
	return Random.new(base)
end

-- Builds one bee's floor-local roam timeline covering [startsAt, endsAt]:
-- eased hops between random points inside the plot's unlocked cell rects at a
-- random cruising altitude, with occasional short hover-pauses. Cells are
-- floor-local rects { minX, maxX, minZ, maxZ } (padding pre-applied by the
-- server). Consumes the RNG only here, never per frame.
function BeeEvent.Flight.BuildTimeline(seed, beeIndex, cells, startsAt, endsAt, settings)
	settings = type(settings) == "table" and settings or {}
	cells = type(cells) == "table" and cells or {}
	local rng = BeeEvent.Flight.RngFor(seed, beeIndex)
	local roamSpeed = math.max(numeric(settings.roamSpeedStuds, 9), 0.5)
	local altitudeMin = numeric(settings.altitudeMin, 3)
	local altitudeMax = math.max(numeric(settings.altitudeMax, 6), altitudeMin)
	local segMin = math.max(numeric(settings.segmentSecondsMin, 1.5), 0.1)
	local segMax = math.max(numeric(settings.segmentSecondsMax, 4), segMin)
	local pauseChance = math.clamp(numeric(settings.waypointPauseChance, 0.25), 0, 1)
	local pauseMin = math.max(numeric(settings.pauseSecondsMin, 0.5), 0.05)
	local pauseMax = math.max(numeric(settings.pauseSecondsMax, 1.5), pauseMin)

	local function randomPoint()
		if #cells == 0 then
			return Vector3.new(0, rng:NextNumber(altitudeMin, altitudeMax), 0)
		end
		local cell = cells[rng:NextInteger(1, #cells)]
		local minX = numeric(cell.minX, 0)
		local maxX = math.max(numeric(cell.maxX, 0), minX)
		local minZ = numeric(cell.minZ, 0)
		local maxZ = math.max(numeric(cell.maxZ, 0), minZ)
		return Vector3.new(
			rng:NextNumber(minX, maxX),
			rng:NextNumber(altitudeMin, altitudeMax),
			rng:NextNumber(minZ, maxZ)
		)
	end

	startsAt = numeric(startsAt, 0)
	endsAt = math.max(numeric(endsAt, startsAt), startsAt)
	local segments = {}
	local cursor = startsAt
	local current = randomPoint()
	while cursor < endsAt do
		local target = randomPoint()
		local travelSeconds = math.clamp((target - current).Magnitude / roamSpeed, segMin, segMax)
		segments[#segments + 1] = {
			t0 = cursor,
			t1 = cursor + travelSeconds,
			from = current,
			to = target,
		}
		cursor += travelSeconds
		current = target
		if cursor < endsAt and rng:NextNumber() < pauseChance then
			local pauseSeconds = rng:NextNumber(pauseMin, pauseMax)
			segments[#segments + 1] = {
				t0 = cursor,
				t1 = cursor + pauseSeconds,
				from = current,
				to = current,
			}
			cursor += pauseSeconds
		end
	end
	if #segments == 0 then
		segments[1] = { t0 = startsAt, t1 = endsAt, from = current, to = current }
	end
	return segments
end

-- Floor-local roam position at time t, including the hover-bob layer.
function BeeEvent.Flight.SampleLocal(timeline, t, settings, beeIndex)
	settings = type(settings) == "table" and settings or {}
	local first = timeline[1]
	local last = timeline[#timeline]
	if not first then
		return Vector3.zero
	end
	t = math.clamp(numeric(t, first.t0), first.t0, last.t1)
	local segment = last
	for index = 1, #timeline do
		local candidate = timeline[index]
		if t <= candidate.t1 then
			segment = candidate
			break
		end
	end
	local span = segment.t1 - segment.t0
	local alpha = span > 0 and easedAlpha((t - segment.t0) / span) or 1
	local position = segment.from:Lerp(segment.to, alpha)
	local bobAmplitude = numeric(settings.bobAmplitude, 0.5)
	local bobPeriod = math.max(numeric(settings.bobPeriod, 1.6), 0.1)
	local bob = bobAmplitude * math.sin((2 * math.pi / bobPeriod) * t + numeric(beeIndex, 0) * BOB_PHASE_PER_BEE)
	return position + Vector3.new(0, bob, 0)
end

-- World-space pollination orbit sample: circle hoverHeightStuds above the
-- food at hoverOrbitRadius, one revolution per hoverOrbitPeriod, phase-offset
-- per bee so concurrent hovers never look cloned.
function BeeEvent.Flight.HoverPosition(targetPosition, t, hoverStartsAt, settings, beeIndex)
	settings = type(settings) == "table" and settings or {}
	local radius = numeric(settings.hoverOrbitRadius, 1.2)
	local period = math.max(numeric(settings.hoverOrbitPeriod, 3), 0.25)
	local height = numeric(settings.hoverHeightStuds, 2)
	local angle = (2 * math.pi / period) * (numeric(t, 0) - numeric(hoverStartsAt, 0)) + numeric(beeIndex, 0)
	local bob = ORBIT_BOB_STUDS * math.sin(angle * 2)
	return targetPosition + Vector3.new(math.cos(angle) * radius, height + bob, math.sin(angle) * radius)
end

return BeeEvent
