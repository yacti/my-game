-- Shared contract for the Sprinkle chaos event (yactiNPC tours farms with a
-- magic wand and boosts nearby food XP).
--
-- The server owns eligibility, stop selection, timing and the XP boost; the
-- client owns 100% of the NPC's rendering. This module holds the names both
-- sides need plus the pure math the client uses to pose and move the rig.
--
-- Everything here is deliberately pure and non-yielding: the client derives the
-- NPC's entire pose from (phase payload, Workspace:GetServerTimeNow()), so a
-- late joiner lands at the correct point of the current phase instead of
-- snapping in from the spawn marker.

local SprinkleEvent = {}

---------------------------------------------------------------------------
-- Studio-authored asset names
---------------------------------------------------------------------------

-- ReplicatedStorage.Assets.Misc.*
SprinkleEvent.NpcModelName = "yactiNPC"
SprinkleEvent.WandModelName = "MagicWand"
SprinkleEvent.WandHandleName = "Handle"
-- The wand's particle origin: MagicWand.Union.Emit (an Attachment).
SprinkleEvent.WandEmitPartName = "Union"
SprinkleEvent.WandEmitAttachmentName = "Emit"

-- ReplicatedStorage.Assets.VFX.SprinkleSparkles.SprinkleSparklesAttachment.*
SprinkleEvent.SparklesModelName = "SprinkleSparkles"
SprinkleEvent.SparklesAttachmentName = "SprinkleSparklesAttachment"
SprinkleEvent.SparklesParticleName = "SprinkleSparklesParticle"

-- ReplicatedStorage.Sounds.MagicSound
SprinkleEvent.MagicSoundName = "MagicSound"

-- Workspace.Map.*
SprinkleEvent.WorldFolderName = "SprinkleEvent"
SprinkleEvent.SpawnMarkerName = "yactiNPCspawn"

-- Runtime name of the client-local rig, so teardown never has to guess.
SprinkleEvent.RuntimeNpcName = "__SprinkleYactiNPC"
SprinkleEvent.RuntimeWandName = "__SprinkleMagicWand"

-- Attributes authored on the yactiNPC template. Its bundled Animate LocalScript
-- cannot run on a client-rendered NPC (LocalScripts only run under the local
-- player's character), so the controller loads these by id itself. Attributes
-- rather than constants so they can be swapped in Studio without a code change.
SprinkleEvent.IdleAnimationAttribute = "IdleAnimationId"
SprinkleEvent.WalkAnimationAttribute = "WalkAnimationId"
-- The departure pair. Measured on this rig at the authored jump (507765000,
-- 1.083s, ships Looped = false): one frame of crouch at 0.05s, then the legs
-- tuck to rootAboveFeet 4.0 and HOLD there until ~1.18s, after which the
-- animation plays its landing recovery and drops the legs back down. That tail
-- must never be seen mid-flight, so the jump is crossfaded into the fall pose
-- (507767968, rock steady at 12.9-13.0 with the arms out) before it arrives.
SprinkleEvent.JumpAnimationAttribute = "JumpAnimationId"
SprinkleEvent.FallAnimationAttribute = "FallAnimationId"

-- When to leave the jump for the fall pose, and how long to blend. Comfortably
-- inside the 1.18s hold measured above.
SprinkleEvent.JumpHoldSeconds = 0.95
SprinkleEvent.JumpToFallBlendSeconds = 0.3

SprinkleEvent.AnimationIdPattern = "^rbxassetid://%d+$"

---------------------------------------------------------------------------
-- Phases published over the SprinkleEventEffect remote
---------------------------------------------------------------------------

SprinkleEvent.Phases = {
	Idle = "idle",
	Arrive = "arrive",
	Travel = "travel",
	WalkTo = "walkTo",
	Wave = "wave",
	Depart = "depart",
}

local function numeric(value, fallback)
	value = tonumber(value)
	if value == nil or value ~= value then
		return fallback
	end
	return value
end

---------------------------------------------------------------------------
-- Rig geometry
---------------------------------------------------------------------------

-- The scale both Studio assets were authored against: the yactiNPC template was
-- ScaleTo(6) (6x the 5.783-stud player avatar) and the MagicWand was drawn
-- 19.8 studs tall to suit it. The rig is now ScaleTo(7), so the wand and the
-- grip offset are scaled by rigScale/6 at runtime to keep the pair in
-- proportion. Rescaling the rig again needs no code change; re-authoring the
-- WAND at a different size is the only thing that would move this number.
-- (The wand's shaft is still the authored 19.8; the star on its tip carries the
-- model to ~25.9 overall, which is why he now holds a proportionally longer
-- wand than the 19.8-stud figure above describes.)
SprinkleEvent.AssetsAuthoredAtRigScale = 6

-- Where the wand handle sits relative to the right hand, expressed at the
-- authored scale above. Same shape as the pinata stick's grip: a short push down
-- the hand's -Y so the shaft reads as held rather than growing out of the wrist.
SprinkleEvent.WandGripOffset = CFrame.new(0, -0.4, 0) * CFrame.Angles(math.rad(90), 0, 0)

-- Scale to apply to wand-side assets so they stay proportional to the rig.
function SprinkleEvent.AssetScaleFor(rigScale)
	rigScale = numeric(rigScale, SprinkleEvent.AssetsAuthoredAtRigScale)
	local authored = math.max(SprinkleEvent.AssetsAuthoredAtRigScale, 0.01)
	if rigScale <= 0 then
		return 1
	end
	return rigScale / authored
end

-- Grip offset for a given rig scale: the translation scales with the hand, the
-- rotation does not.
function SprinkleEvent.WandGripOffsetFor(rigScale)
	local scale = SprinkleEvent.AssetScaleFor(rigScale)
	local position = SprinkleEvent.WandGripOffset.Position * scale
	return CFrame.new(position) * (SprinkleEvent.WandGripOffset - SprinkleEvent.WandGripOffset.Position)
end

-- Parts whose joint drives each piece of the wave. On this project's R15 rigs the
-- joints are AnimationConstraint, not Motor6D (the avatars have zero Motor6Ds
-- despite being R15) -- both expose .Transform and both are accepted. Each of
-- these parts owns exactly one joint, parented to the child part.
SprinkleEvent.PoseJointParts = {
	shoulder = "RightUpperArm",
	elbow = "RightLowerArm",
	wrist = "RightHand",
	neck = "Head",
	waist = "UpperTorso",
}
-- Classic R6 fallback: a single shoulder joint and a neck, both on the torso.
SprinkleEvent.R6TorsoName = "Torso"
SprinkleEvent.R6ShoulderName = "Right Shoulder"
SprinkleEvent.R6NeckName = "Neck"

-- Fractions of a swing cycle that each joint trails the shoulder by. This is
-- what turns a rigid single-axis sway into a whip: the upper arm leads, the
-- forearm follows, the wrist flicks last, and the head arrives late as if he is
-- watching the wand rather than driving it. Structural, not tuning -- the
-- amplitudes are the tunable part and live in GameEvents.
SprinkleEvent.WaveLag = {
	shoulder = 0,
	elbow = 0.10,
	wrist = 0.18,
	neck = 0.22,
	waist = 0.05,
}

---------------------------------------------------------------------------
-- Pure timing / pose math
---------------------------------------------------------------------------

-- Linear progress through [startsAt, endsAt], clamped. Returns 0 for a
-- zero-length window so callers land on the window's end state.
function SprinkleEvent.Progress(now, startsAt, endsAt)
	now = numeric(now, 0)
	startsAt = numeric(startsAt, 0)
	endsAt = numeric(endsAt, startsAt)
	local span = endsAt - startsAt
	if span <= 0 then
		return 1
	end
	return math.clamp((now - startsAt) / span, 0, 1)
end

-- Smoothstep-style ease applied only to the first/last `easeSeconds` of a move,
-- so long legs keep a constant cruise speed and only the ends are softened.
-- This is what keeps phase boundaries free of visible snapping.
function SprinkleEvent.EasedProgress(now, startsAt, endsAt, easeSeconds)
	startsAt = numeric(startsAt, 0)
	endsAt = numeric(endsAt, startsAt)
	local span = endsAt - startsAt
	local alpha = SprinkleEvent.Progress(now, startsAt, endsAt)
	easeSeconds = math.max(numeric(easeSeconds, 0), 0)
	if span <= 0 or easeSeconds <= 0 then
		return alpha
	end
	-- Never let the two ramps overlap, or the midpoint speed goes negative.
	local ease = math.min(easeSeconds / span, 0.5)
	if ease <= 0 then
		return alpha
	end

	-- Piecewise: quadratic in, linear cruise, quadratic out. Normalised by the
	-- total area so the result still spans exactly 0..1.
	local area = 1 - ease
	local function distance(t)
		if t < ease then
			return (t * t) / (2 * ease)
		end
		if t <= 1 - ease then
			return ease / 2 + (t - ease)
		end
		local remaining = 1 - t
		return area - (remaining * remaining) / (2 * ease)
	end
	return math.clamp(distance(alpha) / area, 0, 1)
end

-- Full-body pose for the 5-second wave, as offsets from the rig's neutral pose
-- (identity Transform = arm at the side, head level).
--
--   raise  -> ease up to armRaiseDegrees        (quad out, no snap into the pose)
--   wave   -> a two-axis stir at waveSwingHz    (continuous, so no seam)
--   lower  -> ease back to identity             (quad in, no snap out of it)
--
-- The stir is deliberately two-axis: a lateral sine on Z plus a fore/aft cosine
-- on X, 90 degrees out of phase, so the wand tip traces an ellipse instead of a
-- flat windscreen-wiper. Every joint reads that same wave through WaveLag, so
-- the arm whips and the head arrives late, watching the wand.
--
-- Every offset is scaled by `raised`, so the whole body eases into and out of
-- the performance together and nothing snaps at either seam.
--
-- `totalOverride` is the wave stage's real length, which the server clamps
-- against the wind-down. Passing it keeps the lower phase inside a shortened
-- wave, so the arm never gets stuck raised when a wave is cut short.
function SprinkleEvent.WavePose(elapsed, settings, totalOverride)
	settings = type(settings) == "table" and settings or {}
	elapsed = math.max(numeric(elapsed, 0), 0)

	local total = math.max(numeric(totalOverride, numeric(settings.waveSeconds, 5)), 0.01)
	local raise = math.clamp(numeric(settings.waveRaiseSeconds, 0.6), 0, total)
	local lower = math.clamp(numeric(settings.waveLowerSeconds, 0.6), 0, math.max(total - raise, 0))

	local raiseAngle = math.rad(numeric(settings.armRaiseDegrees, 100))
	local swing = math.rad(numeric(settings.waveSwingDegrees, 38))
	local foreAft = math.rad(numeric(settings.waveForeAftDegrees, 20))
	local elbowSwing = math.rad(numeric(settings.elbowSwingDegrees, 24))
	local wristSwing = math.rad(numeric(settings.wristSwingDegrees, 30))
	local headSwing = math.rad(numeric(settings.headSwingDegrees, 18))
	local headNod = math.rad(numeric(settings.headNodDegrees, 7))
	local waistSwing = math.rad(numeric(settings.waistSwingDegrees, 9))
	local swingHz = numeric(settings.waveSwingHz, 1.15)

	local raised
	if elapsed < raise and raise > 0 then
		-- Quad out: fast off the mark, settling into the raised pose.
		local t = elapsed / raise
		raised = 1 - (1 - t) * (1 - t)
	elseif elapsed > total - lower and lower > 0 then
		-- Quad in: eases away from the pose rather than dropping.
		local t = math.clamp((total - elapsed) / lower, 0, 1)
		raised = t * t
	else
		raised = 1
	end

	-- Phase-locked to the start of the wave window, so the motion is continuous
	-- and every client agrees on it from server time alone.
	local lag = SprinkleEvent.WaveLag
	local function phaseOf(joint)
		local offset = (lag[joint] or 0) / math.max(swingHz, 0.01)
		return 2 * math.pi * swingHz * (elapsed - offset)
	end

	return {
		raised = raised,
		-- Z lifts the arm out to the side and carries the main sway; X adds the
		-- fore/aft component that turns the sway into a stir.
		shoulder = CFrame.Angles(
			foreAft * math.cos(phaseOf("shoulder")) * raised,
			0,
			raiseAngle * raised + swing * math.sin(phaseOf("shoulder")) * raised
		),
		-- Trails the shoulder, over a standing bend that keeps the wand tip up
		-- rather than folding in toward his head as the arm lifts.
		elbow = CFrame.Angles(0, 0, -raiseAngle * 0.25 * raised + elbowSwing * math.sin(phaseOf("elbow")) * raised),
		-- The flick, last in the chain.
		wrist = CFrame.Angles(0, 0, wristSwing * math.sin(phaseOf("wrist")) * raised),
		-- He watches the wand: yaw follows it, with a small nod on the off-beat.
		neck = CFrame.Angles(
			headNod * math.cos(phaseOf("neck")) * raised,
			headSwing * math.sin(phaseOf("neck")) * raised,
			0
		),
		-- The torso joins in just enough that the arm is not moving alone.
		waist = CFrame.Angles(0, waistSwing * math.sin(phaseOf("waist")) * raised, 0),
	}
end

return SprinkleEvent
