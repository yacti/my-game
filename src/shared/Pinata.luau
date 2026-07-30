-- Shared contract for the admin-spawned pinata event: variant balance, the
-- reward pool, the phase-locked drop curve, and the reward-split allocator.
--
-- The pinata itself is a Studio-owned model under ReplicatedStorage.Assets.Misc
-- (DefaultPinata / GoldenPinata), spawned by src/server/PinataService.luau onto
-- a free Workspace.Map.PinataSpawn part and rendered by
-- src/client/ui/PinataController.luau. Server owns HP, the damage ledger, the
-- split and every grant; the client owns presentation only.
--
-- Two functions here are deliberately pure so they can be exercised straight
-- from the command bar without spawning anything:
--   Pinata.DropOffsetAt  -- the drop/bounce curve, shared by client render and
--                           the server's "don't damage an airborne pinata" gate
--   Pinata.SplitRewards  -- the damage-share allocator (see the ADR comment on
--                           SplitRewards for why it rounds the way it does)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local NotificationConfig = require(ReplicatedStorage.Shared:WaitForChild("Notifications"))
local ShopBalance = require(ReplicatedStorage.Shared:WaitForChild("ShopBalance"))

local Pinata = {}

-- ── Identity ──────────────────────────────────────────────────────────────────

-- Runtime folder the server creates under Workspace to hold live pinatas and
-- their dropped rewards. Not Studio-authored.
Pinata.RuntimeFolderName = "Pinatas"
Pinata.DropsFolderName = "PinataDrops"

-- Studio-authored, under Workspace.Map. A Folder of anchored marker parts, each
-- itself also named PinataSpawn, plus one PinataFloor part.
Pinata.SpawnFolderName = "PinataSpawn"
-- A large invisible slab inside the spawn folder whose TOP surface is the plane
-- every pinata rests on. The markers only supply X/Z: their own Y is not a
-- reliable ground height (they sit well above the terrain and have been
-- re-authored at least once), which is what made pinatas sit inconsistently.
-- It must also be excluded from spawn-slot selection -- it lives in the same
-- folder and is a BasePart, so a naive scan would treat it as a 9th slot.
Pinata.FloorPartName = "PinataFloor"

-- Studio-authored templates under ReplicatedStorage.Assets.Misc.
Pinata.StickModelName = "PinataStick"
Pinata.StickHandleName = "Handle"
Pinata.RewardsFolderName = "PhysicalRewards"
Pinata.BillboardTemplateName = "PinataBillboard"

-- Swing animation ids live as attributes on the Studio-owned PinataStick model
-- (the BeeCampController IdleAnimationId convention), not in code. Alternated
-- per swing. Missing/invalid ids warn and skip -- no fallback animation.
--
-- NOTE: both authored animations upload with Looped = true, so the loaded track
-- MUST have Looped forced false or one click swings forever. The flag only
-- reads correctly once the asset has resolved (Length > 0); read it earlier and
-- you get a misleading `false`.
Pinata.SwingAnimationAttributes = { "SwingAnimationId1", "SwingAnimationId2" }
Pinata.AnimationIdPattern = "^rbxassetid://%d+$"

-- How far into the swing the bat actually connects. Damage, sound, shake and
-- the highlight flash are all fired at this instant rather than on the click,
-- so the impact reads as landing with the animation instead of ahead of it.
-- Measured animation lengths are ~0.53s and ~0.47s, so contact lands ~0.22s in.
Pinata.SwingContactFraction = 0.45
-- Used only until a track's real Length has resolved.
Pinata.SwingContactFallbackSeconds = 0.22
-- While the stick is held but not swinging, the right arm is pinned to its
-- DEFAULT IDLE pose (hanging down at the side) so the walk/run cycle does not
-- swing the bat around. This is done by zeroing the right-arm Motor6D
-- Transforms after the animator has run each frame -- an identity Transform is
-- exactly the rig's neutral pose -- rather than by freezing a frame of the
-- swing animation, which would hold a mid-wind-up pose instead.
-- The override is released for this long while a swing plays.
Pinata.ArmHoldSwingReleaseSeconds = 0.6

-- A local swing suppresses exactly one incoming HP-change reaction, so the
-- player does not get the polish twice (once predicted, once when the server's
-- HP write replicates back). Generous enough to cover a slow round trip, and
-- self-clearing so a rejected swing cannot swallow someone else's hit.
Pinata.LocalHitSuppressSeconds = 0.6

-- Name of the welded stick accessory on the character. Deliberately NOT a Tool:
-- Humanoid:EquipTool would unequip whatever the player is holding, and five
-- systems read the equipped tool as FindFirstChildWhichIsA("Tool") -- including
-- Food.GetEquipped, which drives pet feeding. See the plan's ADR-1.
Pinata.StickAccessoryName = "PinataStickAccessory"

-- ── Balance ───────────────────────────────────────────────────────────────────

Pinata.SwingDamage = 1
-- Server-enforced. This is the only thing bounding damage rate, for exploiters
-- and legitimate players alike, which is why there is deliberately no
-- per-player damage cap (a cap would make solo breaking impossible).
Pinata.SwingCooldownSeconds = 0.45
-- Radius at which the stick appears/disappears, measured to the pinata's
-- SURFACE (see DistanceToModel).
Pinata.AutoEquipRadius = 15
-- How close you must be for a swing to land. Just inside the auto-equip radius,
-- so if you are holding the stick you can essentially always connect.
Pinata.SwingReachStuds = 14

Pinata.LifetimeSeconds = 30 * 60
Pinata.MaxActive = 8

-- Stud height the pinata falls from, and how long the drop+bounce takes.
Pinata.SpawnHeight = 20
Pinata.DropSeconds = 1.6

-- Dropped rewards: how long before an uncollected drop is auto-granted to its
-- owner, how close you must be to walk one up, and how long after the break
-- they stay inert (so the client's arc animation lands before pickup).
Pinata.DropCollectSeconds = 60
Pinata.DropCollectRadius = 6
-- Must equal DropFlightSeconds: a drop stays inert until it has visually landed.
Pinata.DropArmDelaySeconds = 0.8
-- How far rewards are flung from the pinata. Drops are placed in three rings at
-- 35% / 67% / 100% of this, so a break scatters them across a wide area rather
-- than piling them at the base.
Pinata.DropScatterRadius = 26

-- Drop presentation (client-only, phase-locked to the DropSpawnedAt attribute
-- so stream-in and late joins converge instead of replaying the burst).
-- Flight matches DropArmDelaySeconds so a drop cannot be collected while it is
-- still visually in the air.
Pinata.DropFlightSeconds = 0.8
-- Peak of the launch arc above the straight-line path. The horizontal travel
-- eases out hard, so rewards burst away from the pinata fast and then settle.
-- Scaled up with DropScatterRadius: a long throw on a low arc reads as sliding
-- rather than being flung.
Pinata.DropArcHeight = 10
Pinata.DropSpinSpeed = 9
-- Landing bounces: two decaying hops before the drop comes to rest.
Pinata.DropBounceSeconds = 0.6
Pinata.DropBounceHeight = 1.6
Pinata.DropBounceCount = 2
-- Idle bob once settled. Period is varied per drop inside this range so a pile
-- of rewards does not pulse in lockstep.
Pinata.DropBobPeriodMin = 2
Pinata.DropBobPeriodMax = 3
Pinata.DropBobHeight = 0.45

-- Minimum stake to enter the reward split, as a fraction of max HP. Stops
-- drive-by tagging: one swing should not earn a leftover unit.
Pinata.MinDamageShareOfMaxHp = 0.01

-- Hit presentation (client), kept here so server and client agree on the range.
Pinata.HitSoundRange = 40
Pinata.HitSoundMinRange = 8
Pinata.HitPitchVariance = 0.3

-- Break presentation: a one-shot confetti burst from the Studio-owned
-- Assets.VFX.Confetti part (an Attachment holding several emitters), plus the
-- celebration sound. The authored emitters ship Enabled = true, so the clone
-- must disable them and use :Emit() or it would spray forever.
Pinata.BreakVfxName = "Confetti"
-- Per emitter. The template has five, so this is the burst size divided among
-- them. Individual emitters may override with an EmitCount attribute.
Pinata.BreakVfxEmitCount = 45
-- Authored particle lifetime tops out at 4s; clean up a little after that.
Pinata.BreakVfxLifetimeSeconds = 5.5
-- ConfettiSound is authored with RollOffMaxDistance 10000 (i.e. audible
-- everywhere). A pinata break is a world event, so it is played positionally
-- with a real falloff instead -- wider than a hit, since it is the payoff.
Pinata.BreakSoundRange = 90
Pinata.BreakSoundMinRange = 15

-- ── Reward kinds ──────────────────────────────────────────────────────────────

Pinata.RewardKinds = {
	GrowSkip = "GrowSkip",
	Cash = "Cash",
	DurianTicket = "DurianTicket",
}

-- Keys match the Studio-authored children of Assets.Misc.PhysicalRewards.
-- Skip durations resolve from ShopBalance so the pinata and the paid Skip5m /
-- Skip30m products can never drift apart.
Pinata.Rewards = {
	["5MinSkip"] = { Kind = Pinata.RewardKinds.GrowSkip, SkipId = "Skip5m", DisplayName = "5 minute grow skip" },
	["30MinSkip"] = { Kind = Pinata.RewardKinds.GrowSkip, SkipId = "Skip30m", DisplayName = "30 minute grow skip" },
	["SmallCash"] = { Kind = Pinata.RewardKinds.Cash, CashId = "Small", DisplayName = "Cash" },
	["MediumCash"] = { Kind = Pinata.RewardKinds.Cash, CashId = "Medium", DisplayName = "Cash" },
	["DurianTicket"] = { Kind = Pinata.RewardKinds.DurianTicket, Amount = 1, DisplayName = "Durian Ticket" },
}

-- ############################################################################
-- ## TEMPORARY TEST VALUES -- DO NOT SHIP                                    ##
-- ## Both MaxHp are set to 5 so a pinata can be broken in a couple of swings ##
-- ## while testing the reward split and drops.                               ##
-- ## RESTORE BEFORE RELEASE: Default = 250, Golden = 1000.                   ##
-- ############################################################################
Pinata.Variants = {
	Default = {
		VariantId = "Default",
		ModelName = "DefaultPinata",
		DisplayName = "Pinata",
		MaxHp = 5, -- TEST VALUE, ships as 250
		-- Notification kind for the spawn toast: the rarity rainbow.
		ToastKind = NotificationConfig.Kinds.Mythical,
		-- Billboard sits above a ~9.5 stud model.
		BillboardStudsOffsetY = 6,
		Pool = {
			{ Id = "5MinSkip", Count = 4 },
			{ Id = "30MinSkip", Count = 2 },
			{ Id = "SmallCash", Count = 8 },
			{ Id = "MediumCash", Count = 2 },
		},
	},
	Golden = {
		VariantId = "Golden",
		ModelName = "GoldenPinata",
		DisplayName = "Golden Pinata",
		MaxHp = 5, -- TEST VALUE, ships as 1000
		-- Gold shimmer instead of the rainbow, so the rarer variant reads as gold.
		ToastKind = NotificationConfig.Kinds.Golden,
		-- Golden is ~17.2 studs tall, so the authored 6-stud offset would put
		-- the health bar inside the model.
		BillboardStudsOffsetY = 10,
		Pool = {
			{ Id = "5MinSkip", Count = 8 },
			{ Id = "30MinSkip", Count = 4 },
			{ Id = "SmallCash", Count = 12 },
			{ Id = "MediumCash", Count = 6 },
			{ Id = "DurianTicket", Count = 2 },
		},
	},
}

-- Stable order for UI/telemetry. Not the split order (see SplitRewards).
Pinata.VariantIds = { "Default", "Golden" }

function Pinata.VariantConfig(variantId)
	if type(variantId) ~= "string" then
		return nil
	end
	return Pinata.Variants[variantId]
end

function Pinata.IsVariant(variantId)
	return Pinata.VariantConfig(variantId) ~= nil
end

function Pinata.RewardConfig(rewardId)
	if type(rewardId) ~= "string" then
		return nil
	end
	return Pinata.Rewards[rewardId]
end

-- Seconds of growth a grow-skip drop applies, resolved from the shared shop
-- balance rather than duplicated here.
function Pinata.GrowSkipSeconds(rewardId)
	local reward = Pinata.RewardConfig(rewardId)
	if not (reward and reward.Kind == Pinata.RewardKinds.GrowSkip) then
		return 0
	end
	local product = ShopBalance.GrowSkipForSkipId(reward.SkipId)
	local seconds = product and tonumber(product.DurationSeconds) or 0
	if seconds ~= seconds or seconds <= 0 then
		return 0
	end
	return math.floor(seconds)
end

-- ── Instance lookup ───────────────────────────────────────────────────────────
-- Non-yielding: safe to call from render loops and heartbeat sweeps.

function Pinata.FindRuntimeFolder()
	return Workspace:FindFirstChild(Pinata.RuntimeFolderName)
end

function Pinata.FindDropsFolder()
	return Workspace:FindFirstChild(Pinata.DropsFolderName)
end

function Pinata.FindSpawnFolder()
	local map = Workspace:FindFirstChild("Map")
	return map and map:FindFirstChild(Pinata.SpawnFolderName) or nil
end

function Pinata.FindFloor()
	local folder = Pinata.FindSpawnFolder()
	local floor = folder and folder:FindFirstChild(Pinata.FloorPartName)
	return (floor and floor:IsA("BasePart")) and floor or nil
end

-- World Y of the surface pinatas and their drops rest on, or nil if the floor
-- part is missing (callers should skip rather than guess a height).
function Pinata.FloorTopY()
	local floor = Pinata.FindFloor()
	if not floor then
		return nil
	end
	return floor.Position.Y + floor.Size.Y * 0.5
end

-- Spawn markers only: everything in the folder except the floor slab.
function Pinata.SpawnMarkers()
	local markers = {}
	local folder = Pinata.FindSpawnFolder()
	if not folder then
		return markers
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") and child.Name ~= Pinata.FloorPartName then
			markers[#markers + 1] = child
		end
	end
	return markers
end

-- Pivot that rests `model` on the floor at the marker's X/Z. Uses the bounding
-- box rather than the pivot directly, because a model's pivot is not
-- necessarily at the centre or the base of its geometry.
function Pinata.RestingPivot(model, marker, floorTopY)
	if not (model and marker) then
		return nil
	end
	local boxCFrame, boxSize = model:GetBoundingBox()
	local pivot = model:GetPivot()
	-- How far the geometry's lowest point sits below the pivot.
	local bottomBelowPivot = pivot.Position.Y - (boxCFrame.Position.Y - boxSize.Y * 0.5)
	return CFrame.new(marker.Position.X, floorTopY + bottomBelowPivot, marker.Position.Z)
end

-- ── Drop curve ────────────────────────────────────────────────────────────────

-- Restitution per bounce and how many bounces before the pinata settles.
local DROP_RESTITUTION = 0.32
local DROP_BOUNCES = 3

-- Segment table for a bouncing fall from `height`, in arbitrary "gravity time"
-- units (span scales with sqrt(height), which is what makes it read as gravity).
-- Segment 1 is the initial half-parabola fall; the rest are full up-down arcs.
local function dropSegments(height)
	local segments = { { span = math.sqrt(height), peak = height, fall = true } }
	local total = segments[1].span
	local peak = height
	for _ = 1, DROP_BOUNCES do
		peak *= DROP_RESTITUTION
		local span = 2 * math.sqrt(peak)
		segments[#segments + 1] = { span = span, peak = peak, fall = false }
		total += span
	end
	return segments, total
end

-- Vertical offset above the resting position at `elapsed` seconds since spawn.
--
-- Phase-locked to the server clock on purpose: the client derives elapsed from
-- the pinata's DropAt attribute rather than animating off ChildAdded. Under
-- StreamingEnabled, ChildAdded fires on stream-IN, so an event-triggered
-- animation would replay the whole 20-stud drop for anyone who walks up twenty
-- minutes later, and again on every stream-out/in. This returns exactly 0 once
-- the window has passed, which makes re-entry idempotent for free.
function Pinata.DropOffsetAt(elapsed, variantId)
	local config = Pinata.VariantConfig(variantId)
	local height = Pinata.SpawnHeight
	local duration = Pinata.DropSeconds
	if not config or duration <= 0 or height <= 0 then
		return 0
	end
	if type(elapsed) ~= "number" or elapsed ~= elapsed then
		return 0
	end
	if elapsed < 0 then
		return height
	end
	if elapsed >= duration then
		return 0
	end

	local segments, totalSpan = dropSegments(height)
	-- Map real seconds onto gravity time so the whole thing lasts `duration`.
	local t = (elapsed / duration) * totalSpan
	for _, segment in ipairs(segments) do
		if t < segment.span then
			local alpha = t / segment.span
			if segment.fall then
				-- Descending half-parabola: peak at alpha 0, ground at alpha 1.
				return segment.peak * (1 - alpha * alpha)
			end
			-- Full arc: ground at both ends, peak at the midpoint.
			local centered = 2 * alpha - 1
			return segment.peak * (1 - centered * centered)
		end
		t -= segment.span
	end
	return 0
end

-- True once the pinata has finished falling. The server refuses swings before
-- this so nobody damages a pinata that is visually still in the air.
function Pinata.HasLanded(elapsed)
	return type(elapsed) == "number" and elapsed == elapsed and elapsed >= Pinata.DropSeconds
end

-- Distance from a world position to the pinata's nearest SURFACE, not its
-- pivot. This matters a lot: the authored spawn markers sit ~17 studs above the
-- ground, so the pinatas hang, and Golden is 17.2 studs tall. Measured to the
-- pivot, a player standing directly underneath a Golden is ~16 studs away and
-- could never reach it. Returns 0 when the position is inside the model.
function Pinata.DistanceToModel(model, position)
	if not (model and model:IsA("Model") and typeof(position) == "Vector3") then
		return math.huge
	end
	local ok, cframe, size = pcall(function()
		local boxCFrame, boxSize = model:GetBoundingBox()
		return boxCFrame, boxSize
	end)
	if not ok or not cframe then
		return math.huge
	end
	local localPoint = cframe:PointToObjectSpace(position)
	local half = size * 0.5
	local clamped = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	return (localPoint - clamped).Magnitude
end

-- ── Drop presentation ─────────────────────────────────────────────────────────

-- Per-drop bob period, spread deterministically across the configured range so
-- every client agrees and neighbouring drops fall out of phase with each other.
function Pinata.DropBobPeriod(seed)
	-- Multiply by a prime before the modulo: without it, drops with adjacent
	-- seeds land on almost the same period and still bob in near-lockstep.
	local n = (math.abs(math.floor(tonumber(seed) or 0)) * 37) % 97
	local alpha = n / 96
	return Pinata.DropBobPeriodMin + alpha * (Pinata.DropBobPeriodMax - Pinata.DropBobPeriodMin)
end

-- Where a dropped reward should be drawn `elapsed` seconds after it burst out
-- of the pinata. Pure, so it is identical on every client and can be unit
-- checked from the command bar.
--
--   0 .. DropFlightSeconds        launch: eased-out horizontal travel from the
--                                 pinata centre plus a ballistic arc
--   .. + DropBounceSeconds        two decaying bounces on landing
--   thereafter                    slow idle bob until collected
--
-- `restPosition` is the authoritative server position; every phase is expressed
-- relative to it, so a client that joins late simply draws the bob.
function Pinata.DropVisualPosition(restPosition, origin, elapsed, seed)
	if typeof(restPosition) ~= "Vector3" then
		return restPosition
	end
	if typeof(origin) ~= "Vector3" then
		origin = restPosition
	end
	if type(elapsed) ~= "number" or elapsed ~= elapsed then
		return restPosition
	end
	if elapsed <= 0 then
		return origin
	end

	if elapsed < Pinata.DropFlightSeconds then
		local t = elapsed / Pinata.DropFlightSeconds
		-- Ease out: almost all the horizontal distance is covered early, which
		-- is what sells it as an explosion rather than a lob.
		local horizontal = 1 - (1 - t) * (1 - t)
		local flat = origin:Lerp(restPosition, horizontal)
		-- Ballistic hump, zero at both ends.
		local arc = Pinata.DropArcHeight * math.sin(math.pi * t)
		return Vector3.new(flat.X, flat.Y + arc, flat.Z)
	end

	local since = elapsed - Pinata.DropFlightSeconds
	if since < Pinata.DropBounceSeconds then
		local t = since / Pinata.DropBounceSeconds
		-- |sin| gives repeated hops; the linear term decays them to nothing so
		-- the drop settles exactly on the rest position.
		local hops = math.abs(math.sin(math.pi * t * Pinata.DropBounceCount))
		local decay = 1 - t
		return restPosition + Vector3.new(0, Pinata.DropBounceHeight * hops * decay * decay, 0)
	end

	local period = Pinata.DropBobPeriod(seed)
	local t = since - Pinata.DropBounceSeconds
	-- Starts at 0 and stays non-negative so the drop never sinks into the floor.
	local bob = (1 - math.cos(t / period * math.pi * 2)) * 0.5
	return restPosition + Vector3.new(0, Pinata.DropBobHeight * bob, 0)
end

-- ── Reward split ──────────────────────────────────────────────────────────────

local function integerOrZero(value)
	local number = tonumber(value)
	if type(number) ~= "number" or number ~= number or math.abs(number) == math.huge then
		return 0
	end
	return math.floor(number)
end

-- Splits a variant's reward pool across a damage ledger.
--
--   ledger : { [userId] = damageDealt }
--   pool   : array of { Id = <reward id>, Count = <n> } (defaults to the variant's)
--   returns: { [userId] = { [rewardId] = count } }, plus the eligible-share map
--
-- Method: largest remainder (Hamilton), with two deliberate deviations.
--
-- Why largest remainder at all: awarding every leftover unit to the top damager
-- violates the quota rule (each player must get the floor or the ceiling of
-- their exact share). On a 32-item Golden pool a 60% player is entitled to 19.2
-- items, so quota permits 19 or 20 -- top-damage-first hands them 22. Largest
-- remainder cannot breach quota by construction, and its famous weakness (the
-- Alabama paradox) needs a varying house size, which we do not have: reward
-- counts are fixed per variant.
--
-- Deviation 1: categories are processed RAREST FIRST and remainder ties are
-- broken by descending damage, so the top damager wins the scarcest reward
-- (both durian tickets in a 40/60 two-player split).
-- Deviation 2: leftovers are BALANCED ACROSS CATEGORIES -- the next leftover
-- goes to whoever has won the fewest so far. Without this the leader sweeps
-- every category and lands at 69% of a pool they are 60% entitled to; with it,
-- 62.5%.
--
-- Both deviations preserve quota: a player gains at most one extra unit per
-- category, so every allocation stays within [floor, ceil] of the exact share.
function Pinata.SplitRewards(ledger, pool, maxHp)
	local allocation = {}
	local shares = {}
	if type(ledger) ~= "table" then
		return allocation, shares
	end

	local minimumDamage = 0
	local hp = tonumber(maxHp)
	if type(hp) == "number" and hp == hp and hp > 0 then
		minimumDamage = hp * Pinata.MinDamageShareOfMaxHp
	end

	-- Eligible contributors only.
	local contributors = {}
	local totalDamage = 0
	for userId, damage in pairs(ledger) do
		local id = integerOrZero(userId)
		local dealt = tonumber(damage) or 0
		if id ~= 0 and dealt > 0 and dealt >= minimumDamage then
			contributors[#contributors + 1] = { userId = id, damage = dealt }
			totalDamage += dealt
		end
	end
	if totalDamage <= 0 or #contributors == 0 then
		return allocation, shares
	end

	for _, entry in ipairs(contributors) do
		entry.share = entry.damage / totalDamage
		shares[entry.userId] = entry.share
		allocation[entry.userId] = {}
	end

	-- Rarest category first; Id breaks count ties so the order is deterministic.
	local categories = {}
	for _, entry in ipairs(type(pool) == "table" and pool or {}) do
		local count = integerOrZero(entry and entry.Count)
		if type(entry) == "table" and type(entry.Id) == "string" and count > 0 then
			categories[#categories + 1] = { id = entry.Id, count = count }
		end
	end
	table.sort(categories, function(a, b)
		if a.count ~= b.count then
			return a.count < b.count
		end
		return a.id < b.id
	end)

	local leftoversWon = {}
	for _, entry in ipairs(contributors) do
		leftoversWon[entry.userId] = 0
	end

	for _, category in ipairs(categories) do
		local assigned = 0
		for _, entry in ipairs(contributors) do
			local base = math.floor(entry.share * category.count)
			allocation[entry.userId][category.id] = base
			assigned += base
		end

		local remainder = category.count - assigned
		if remainder > 0 then
			-- Fewest leftovers so far wins; then most damage; then lowest
			-- UserId so a tie is reproducible in tests.
			local ranked = table.clone(contributors)
			table.sort(ranked, function(a, b)
				local wonA, wonB = leftoversWon[a.userId], leftoversWon[b.userId]
				if wonA ~= wonB then
					return wonA < wonB
				end
				if a.damage ~= b.damage then
					return a.damage > b.damage
				end
				return a.userId < b.userId
			end)
			for index = 1, math.min(remainder, #ranked) do
				local userId = ranked[index].userId
				allocation[userId][category.id] += 1
				leftoversWon[userId] += 1
			end
		end
	end

	return allocation, shares
end

return Pinata
