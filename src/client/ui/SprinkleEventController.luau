-- Renders the Sprinkle event: yactiNPC falls onto the island, walks farm to
-- farm, raises a magic wand and sprinkles sparkles over the crops.
--
-- Everything here is client-local presentation. The server publishes one
-- "stage" -- a phase plus two positions and two server timestamps -- and this
-- controller derives the rig's entire pose from (stage, GetServerTimeNow()).
-- Because the pose is a pure function of server time, a player who joins mid-leg
-- is placed at the correct point on that leg instead of snapping in from spawn,
-- and no NPC physics, pathfinding or animation crosses the network.
--
-- Two connections, both explicitly disposed on teardown:
--   RenderStepped -> root CFrame, sparkle bursts, magic sound
--   Stepped       -> right-arm joints (see stepArm; this MUST be Stepped)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local SprinkleEvent = require(Shared:WaitForChild("SprinkleEvent"))

local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local SprinkleEventController = {}

local Phases = SprinkleEvent.Phases
-- Below which a leg is treated as "standing still", so the rig keeps its facing
-- instead of snapping to the yaw of a sub-stud correction.
local MIN_FACING_SPEED = 0.05
-- Ground speed the stock R15 walk cycle is authored against, at scale 1.
local WALK_REFERENCE_STUDS_PER_SECOND = 16
local LANDING_DIP_SECONDS = 0.35
-- Knee-bend depth on touchdown, as a fraction of the rig's standing height, so
-- it stays proportional at any scale.
local LANDING_DIP_FRACTION = 0.12
-- Long enough to cover a full idle/walk cycle when measuring foot height.
local CALIBRATION_SAMPLE_SECONDS = 0.8
-- Seconds to blend between two animations' standing heights, matched to the
-- track crossfade so the switch reads as one motion instead of a pop.
local HEIGHT_BLEND_SECONDS = 0.25

local player = Players.LocalPlayer
local started = false

-- One live session at a time. `token` is the server instanceId: a delayed "end"
-- from a previous sprinkle must not tear down a new one that started inside the
-- old fade window.
local session = nil

-- Building the rig yields (foot-height calibration), so stages can arrive before
-- there is a session to put them on. They are parked here and applied the moment
-- the session exists, rather than dropped -- otherwise the NPC would hold a stale
-- pose until the server happened to publish its next stage.
local buildToken = nil
local pendingStage = nil

local function warnSprinkle(message)
	warn("[SprinkleEventController] " .. message)
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function numberValue(value, fallback)
	value = tonumber(value)
	if value == nil or value ~= value then
		return fallback
	end
	return value
end

---------------------------------------------------------------------------
-- Asset resolution (warn-and-skip: a missing prop disables the event, never
-- bricks the client)
---------------------------------------------------------------------------

local function assetsFolder()
	return ReplicatedStorage:FindFirstChild("Assets")
end

local function miscTemplate(name)
	local assets = assetsFolder()
	local misc = assets and assets:FindFirstChild("Misc")
	local template = misc and misc:FindFirstChild(name)
	return template and template:IsA("Model") and template or nil
end

local function sparkleParticleTemplate()
	local assets = assetsFolder()
	local vfx = assets and assets:FindFirstChild("VFX")
	local holder = vfx and vfx:FindFirstChild(SprinkleEvent.SparklesModelName)
	local attachment = holder and holder:FindFirstChild(SprinkleEvent.SparklesAttachmentName)
	local particle = attachment and attachment:FindFirstChild(SprinkleEvent.SparklesParticleName)
	return particle and particle:IsA("ParticleEmitter") and particle or nil
end

local function worldFolder()
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	return map:FindFirstChild(SprinkleEvent.WorldFolderName)
end

---------------------------------------------------------------------------
-- Rig construction
---------------------------------------------------------------------------

local function loadTrack(animator, animationId)
	if not animator or type(animationId) ~= "string" or not animationId:match(SprinkleEvent.AnimationIdPattern) then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		warnSprinkle("Failed to load animation " .. animationId)
		return nil
	end
	return track
end

-- How far the rig's root must sit above the ground, PER ANIMATION.
--
-- Neither the template's geometry nor Humanoid.HipHeight can answer this. The
-- template is stored in an unassembled authored pose (its feet sit above its
-- shins), and the stock R15 animations retarget imperfectly onto this
-- custom-scaled rig -- measured on the live rig, root-above-feet is 20.7 in the
-- neutral pose, 26.2-28.0 through the idle cycle, and 14.2-21.2 through the walk
-- cycle. Trusting HipHeight (20.7) buries his feet ~6 studs into the ground
-- while he stands and waves, which is exactly when players are looking at him.
--
-- So each pose is measured live and the cycle's MAXIMUM is used, which puts the
-- lowest foot of the cycle on the ground and never through it. This is also
-- self-correcting: swapping either animation id in Studio needs no code change,
-- and leaving one blank (the idle is blank today, because the stock R15 idle
-- stands this rig splay-legged) simply calibrates the neutral pose instead.
--
-- Cached per animation-id pair for the session -- calibration costs a couple of
-- seconds and the answer cannot change while the place is running.
local calibrationCache = {}

local function measureRootAboveFeet(rig)
	local lowest = math.huge
	for _, descendant in ipairs(rig.model:GetDescendants()) do
		if descendant:IsA("BasePart")
			and not descendant:FindFirstAncestorOfClass("Accessory")
			and not (rig.wand and descendant:IsDescendantOf(rig.wand)) then
			lowest = math.min(lowest, descendant.Position.Y - descendant.Size.Y / 2)
		end
	end
	if lowest == math.huge then
		return nil
	end
	return rig.root.Position.Y - lowest
end

-- Measures the pose `track` produces. A nil track is not a failure: with no idle
-- animation authored the rig stands in its own neutral pose, and that pose still
-- has to be measured (its true offset is ~20.1, not the 20.7 HipHeight implies).
local function calibrateTrack(rig, track, fallback)
	if track then
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Core
		track:Play(0)
	end
	-- Let the animator settle the pose before the first sample.
	task.wait(0.2)
	local highest = nil
	local deadline = os.clock() + CALIBRATION_SAMPLE_SECONDS
	while os.clock() < deadline do
		RunService.Heartbeat:Wait()
		local value = measureRootAboveFeet(rig)
		if value then
			highest = math.max(highest or value, value)
		end
	end
	if track then
		track:Stop(0)
	end
	return highest or fallback
end

-- Fills in rig.idleHeight / rig.walkHeight. Yields, so it runs CONCURRENTLY with
-- the render loop rather than in front of it: while it works the rig is still
-- 200 studs up in its entrance fall, where a few studs of height error is
-- invisible, and it is long finished by touchdown. Blocking on it instead ate
-- the first ~2s of the drop on the first sprinkle of a session.
local function calibrateRig(rig)
	local neutral = rig.humanoid.HipHeight + rig.root.Size.Y / 2
	if neutral <= 0 or neutral ~= neutral then
		neutral = rig.root.Size.Y / 2
	end
	rig.idleHeight = neutral
	rig.walkHeight = neutral

	-- Scale is part of the key: the same animation ids give a different foot
	-- offset on a rescaled rig.
	local key = string.format("%s|%s|%.4f", tostring(rig.idleAnimationId), tostring(rig.walkAnimationId), rig.scale)
	local cached = calibrationCache[key]
	if cached then
		rig.idleHeight, rig.walkHeight = cached.idle, cached.walk
		return
	end

	rig.calibrating = true
	RuntimeGuard.Spawn("SprinkleEventController.Calibrate", function()
		local idle = calibrateTrack(rig, rig.idleTrack, neutral)
		local walk = calibrateTrack(rig, rig.walkTrack, idle)
		if rig.model.Parent then
			rig.idleHeight, rig.walkHeight = idle, walk
			calibrationCache[key] = { idle = idle, walk = walk }
		end
		rig.calibrating = false
	end)
end

-- The wand is a multi-part Model welded into the hand. Order matters: parent
-- first (welds between parts outside the DataModel do not initialise), then
-- move the WHOLE model rigidly so every part keeps its relative pose, then weld.
-- Setting only the handle's CFrame leaves the mesh at its template position and
-- the WeldConstraint locks in a huge offset -- which reads in game as the prop
-- flying around the map.
local function weldWand(character, hand, rigScale)
	local template = miscTemplate(SprinkleEvent.WandModelName)
	if not template then
		warnSprinkle("Missing Assets.Misc." .. SprinkleEvent.WandModelName .. "; wand skipped")
		return nil
	end

	local model = template:Clone()
	model.Name = SprinkleEvent.RuntimeWandName
	local handle = model.PrimaryPart or model:FindFirstChild(SprinkleEvent.WandHandleName)
	if not (handle and handle:IsA("BasePart")) then
		model:Destroy()
		warnSprinkle(SprinkleEvent.WandModelName .. " has no Handle/PrimaryPart; wand skipped")
		return nil
	end

	-- The wand is authored 19.8 studs tall to suit the rig at its authored scale.
	-- Scale it with the rig or it ends up taller than he is. Must happen before
	-- the grip delta is computed below, and before the sparkle emitter is
	-- parented in (ScaleTo cascades into ParticleEmitters, and the burst is
	-- tuned at the emitter's authored size).
	model:ScaleTo(SprinkleEvent.AssetScaleFor(rigScale))

	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			parts[#parts + 1] = descendant
		end
	end
	if #parts == 0 then
		model:Destroy()
		return nil
	end

	model.Parent = character

	local target = hand.CFrame * SprinkleEvent.WandGripOffsetFor(rigScale)
	local delta = target * handle.CFrame:Inverse()
	for _, part in ipairs(parts) do
		part.CFrame = delta * part.CFrame
	end

	for _, part in ipairs(parts) do
		if part ~= handle then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "SprinkleWandPartWeld"
			weld.Part0 = handle
			weld.Part1 = part
			weld.Parent = part
		end
	end

	-- Measured offset, not a re-derived one, so the grip cannot drift.
	local weld = Instance.new("Weld")
	weld.Name = "SprinkleWandWeld"
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = hand.CFrame:ToObjectSpace(handle.CFrame)
	weld.C1 = CFrame.identity
	weld.Parent = handle

	return model, handle
end

local function baseParts(model)
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			parts[#parts + 1] = descendant
		end
	end
	return parts
end

-- CanQuery/CanTouch go with CanCollide: nothing should raycast-hit or
-- touch-trigger off a prop the player is meant to walk straight through.
-- Written only when actually set, because this runs every frame for a window
-- (see holdCollisionCleared).
local function clearCollision(parts)
	for _, part in ipairs(parts) do
		if part.CanCollide then
			part.CanCollide = false
		end
		if part.CanQuery then
			part.CanQuery = false
		end
		if part.CanTouch then
			part.CanTouch = false
		end
	end
end

-- The Humanoid re-enables limb collision as it assembles the character, and it
-- does so a frame or more AFTER the model is parented -- not during the
-- parenting frame. Measured on the live rig, all 14 R15 body parts (everything
-- except the Head and the HumanoidRootPart) came back CanCollide = true within
-- ~100ms of parenting no matter what was written before, which is what let a
-- purely decorative NPC shove players around their own farm.
--
-- So the clear is HELD for a window rather than applied once: a single pass at
-- parent time is always overwritten, and a single deferred pass races the
-- assembly on a slow frame (this client can be rendering 300 crop patches).
--
-- The window is bounded rather than permanent because the engine only does this
-- the once: watching a rig that had been left solid, the flags never changed
-- again over the following 960 frames. The rig's Humanoid never leaves
-- FallingDown either (its root is anchored), so there are no state transitions
-- to re-trigger it. Two seconds is ~20x the measured margin and closes long
-- before the entrance fall ends.
local COLLISION_HOLD_SECONDS = 2

local function holdCollisionCleared(model, parts)
	RuntimeGuard.Spawn("SprinkleEventController.ClearCollision", function()
		local deadline = os.clock() + COLLISION_HOLD_SECONDS
		while os.clock() < deadline and model.Parent do
			RunService.Heartbeat:Wait()
			clearCollision(parts)
		end
	end)
end

-- This project's rigs are joined by AnimationConstraint, not Motor6D (the R15
-- avatars have zero Motor6Ds). Both expose .Transform and both are accepted so a
-- classic rig still works.
local function armJointIn(part)
	if not part then
		return nil
	end
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("AnimationConstraint") or child:IsA("Motor6D") then
			return child
		end
	end
	return nil
end

-- Named rather than positional, so each joint can be driven with its own part of
-- the wave (and a rig missing one simply loses that flourish).
local function collectPoseJoints(character)
	local joints = {}
	for role, partName in pairs(SprinkleEvent.PoseJointParts) do
		joints[role] = armJointIn(character:FindFirstChild(partName))
	end
	if not joints.shoulder then
		-- R6 fallback: shoulder and neck both hang off the torso.
		local torso = character:FindFirstChild(SprinkleEvent.R6TorsoName)
		if torso then
			local shoulder = torso:FindFirstChild(SprinkleEvent.R6ShoulderName)
			if shoulder and (shoulder:IsA("AnimationConstraint") or shoulder:IsA("Motor6D")) then
				joints.shoulder = shoulder
			end
			local neck = torso:FindFirstChild(SprinkleEvent.R6NeckName)
			if neck and (neck:IsA("AnimationConstraint") or neck:IsA("Motor6D")) then
				joints.neck = neck
			end
		end
	end
	if not joints.shoulder then
		warnSprinkle("No right-shoulder joint found; wand arm animation skipped")
	end
	return joints
end

local function buildRig()
	local template = miscTemplate(SprinkleEvent.NpcModelName)
	if not template then
		warnSprinkle("Missing Assets.Misc." .. SprinkleEvent.NpcModelName .. "; sprinkle skipped")
		return nil
	end
	local parent = worldFolder()
	if not parent then
		warnSprinkle("Missing Workspace.Map." .. SprinkleEvent.WorldFolderName .. "; sprinkle skipped")
		return nil
	end

	local model = template:Clone()
	model.Name = SprinkleEvent.RuntimeNpcName

	-- The bundled Health Script and Animate LocalScript are for player
	-- characters. Neither runs usefully on a client-local NPC (a LocalScript
	-- outside the local player's character never runs at all), so both go and
	-- this controller drives the animation itself.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if not (humanoid and root and root:IsA("BasePart")) then
		model:Destroy()
		warnSprinkle(SprinkleEvent.NpcModelName .. " has no Humanoid/HumanoidRootPart; sprinkle skipped")
		return nil
	end
	model.PrimaryPart = root

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	-- A decorative NPC must not die or ragdoll: this rig is joined by
	-- BallSocketConstraints, and anything that hands it to raw physics stretches
	-- it apart permanently.
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	--
	-- Do NOT put the humanoid into HumanoidStateType.Physics. That is the
	-- ragdoll state: measured on this rig, it let the ball sockets stretch the
	-- legs ~7 studs below where they belong and the rig never recovered, even
	-- after the state was changed back. Leaving the state machine alone keeps
	-- the assembly rigid (verified: root-to-feet holds at HipHeight + rootSize/2
	-- indefinitely with only the root anchored).
	--
	-- Anchored root, unanchored limbs -- which is also how the template ships
	-- (0 of its 20 parts are anchored). Movement is driven by writing root.CFrame.
	-- The anchoring must happen here, before the rig enters the world, or it
	-- drops on its first physics step. The collision flags set alongside it do
	-- not survive parenting -- see clearCollision, which runs again below.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = descendant == root
		end
	end
	clearCollision(baseParts(model))

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- Parent BEFORE welding: welds between parts outside the DataModel do not
	-- initialise reliably (the same rule the pinata stick follows).
	model.Parent = parent

	local rigScale = model:GetScale()

	local hand = model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm")
	local wand, wandHandle = nil, nil
	if hand and hand:IsA("BasePart") then
		wand, wandHandle = weldWand(model, hand, rigScale)
	else
		warnSprinkle("Rig has no right hand; wand skipped")
	end

	-- After parenting AND after the wand is in, so one snapshot covers the rig,
	-- its accessories and the prop.
	local parts = baseParts(model)
	clearCollision(parts)
	holdCollisionCleared(model, parts)

	local emitter = nil
	local particleTemplate = sparkleParticleTemplate()
	if particleTemplate and wand then
		local emitPart = wand:FindFirstChild(SprinkleEvent.WandEmitPartName)
		local attachment = emitPart and emitPart:FindFirstChild(SprinkleEvent.WandEmitAttachmentName)
		if attachment and attachment:IsA("Attachment") then
			emitter = particleTemplate:Clone()
			-- The template ships Enabled = true; a naive clone sprays forever.
			-- Bursts come from :Emit() only.
			emitter.Enabled = false
			emitter.Parent = attachment
		else
			warnSprinkle("MagicWand has no " .. SprinkleEvent.WandEmitAttachmentName .. " attachment; sparkles skipped")
		end
	elseif not particleTemplate then
		warnSprinkle("Missing Assets.VFX." .. SprinkleEvent.SparklesModelName .. "; sparkles skipped")
	end

	local idleAnimationId = model:GetAttribute(SprinkleEvent.IdleAnimationAttribute)
	local walkAnimationId = model:GetAttribute(SprinkleEvent.WalkAnimationAttribute)

	local rig = {
		model = model,
		root = root,
		humanoid = humanoid,
		wand = wand,
		wandHandle = wandHandle,
		emitter = emitter,
		joints = collectPoseJoints(model),
		scale = rigScale,
		idleAnimationId = idleAnimationId,
		walkAnimationId = walkAnimationId,
		idleTrack = loadTrack(animator, idleAnimationId),
		walkTrack = loadTrack(animator, walkAnimationId),
		jumpTrack = loadTrack(animator, model:GetAttribute(SprinkleEvent.JumpAnimationAttribute)),
		fallTrack = loadTrack(animator, model:GetAttribute(SprinkleEvent.FallAnimationAttribute)),
	}
	-- Non-blocking: see calibrateRig.
	calibrateRig(rig)
	return rig
end

---------------------------------------------------------------------------
-- Pose derivation
---------------------------------------------------------------------------

local function stageGroundPosition(stage, settings, now)
	if stage.phase == Phases.Travel or stage.phase == Phases.WalkTo then
		local alpha = SprinkleEvent.EasedProgress(now, stage.startsAt, stage.endsAt, settings.phaseEaseSeconds)
		return stage.from:Lerp(stage.to, alpha)
	end
	return stage.to or stage.from
end

-- Vertical offset above the ground position. Only the entrance and exit use it.
local function stageHeightOffset(stage, settings, now)
	if stage.phase == Phases.Arrive then
		-- Accelerating fall: slow off the mark, fastest at touchdown.
		local alpha = SprinkleEvent.Progress(now, stage.startsAt, stage.endsAt)
		return settings.entranceFallStuds * (1 - alpha * alpha)
	end
	if stage.phase == Phases.Depart then
		-- Accelerating rise, the exact mirror of the entrance fall: velocity is
		-- ZERO at the launch frame, so he eases out of the jump with no snap, then
		-- gains speed all the way up (0 -> ~66 studs/s over the window). An even
		-- rise had to start at full speed, which read as a snap the instant the
		-- Depart stage landed.
		local alpha = SprinkleEvent.Progress(now, stage.startsAt, stage.endsAt)
		return settings.exitRiseStuds * alpha * alpha
	end
	return 0
end

-- Knee-bend dip on touchdown so the landing reads as impact rather than a stop.
-- A vertical dip rather than Model:ScaleTo -- rescaling a welded, anchored rig
-- every frame fights both the welds and the animator.
--
-- Keyed off `record.landedAt` rather than the Arrive stage, because the server
-- publishes the next stage the instant the fall ends: reading the stage here
-- meant the dip was already gone by the frame it was supposed to start, so the
-- landing had no impact at all.
local function landingDip(record, now)
	local landedAt = record.landedAt
	if not landedAt then
		return 0
	end
	local since = now - landedAt
	if since < 0 or since > LANDING_DIP_SECONDS then
		return 0
	end
	local depth = (record.standHeight or 0) * LANDING_DIP_FRACTION
	-- One half-sine: down and back up.
	return -depth * math.sin((since / LANDING_DIP_SECONDS) * math.pi)
end

local function desiredFacing(record, stage, groundPosition)
	if typeof(stage.facing) == "Vector3" then
		local flat = Vector3.new(stage.facing.X - groundPosition.X, 0, stage.facing.Z - groundPosition.Z)
		if flat.Magnitude > MIN_FACING_SPEED then
			return math.atan2(-flat.X, -flat.Z)
		end
		return record.yaw
	end
	if stage.phase == Phases.Travel or stage.phase == Phases.WalkTo then
		local flat = Vector3.new(stage.to.X - stage.from.X, 0, stage.to.Z - stage.from.Z)
		if flat.Magnitude > MIN_FACING_SPEED then
			return math.atan2(-flat.X, -flat.Z)
		end
	end
	return record.yaw
end

---------------------------------------------------------------------------
-- Arm: hold while walking, pose while waving
---------------------------------------------------------------------------

-- MUST run on RunService.Stepped. Measured on this project: writing joint
-- Transforms from RenderStepped (even after RenderPriority.Character) or
-- PreRender is overwritten by the animator and the arm keeps swinging; only
-- Stepped runs late enough for the value to survive the frame.
--
-- Identity Transform is precisely the rig's neutral pose (arm hanging at the
-- side), so zeroing it cancels the walk cycle's contribution for these joints
-- only -- legs, torso and left arm keep animating normally.
local function stepArm()
	local record = session
	if not (record and record.rig) then
		return
	end
	local joints = record.rig.joints
	if not joints.shoulder then
		return
	end

	local function write(joint, cframe)
		if joint and joint.Parent then
			joint.Transform = cframe
		end
	end

	local stage = record.stage
	local pose = nil
	if stage and stage.phase == Phases.Wave then
		pose = SprinkleEvent.WavePose(
			serverNow() - stage.startsAt,
			record.settings,
			stage.endsAt - stage.startsAt
		)
	end

	-- The right arm is pinned every frame whether waving or not: identity holds
	-- the wand quietly at his side while he walks, and the pose takes over during
	-- a wave. Anything less and the walk cycle swings the wand around.
	write(joints.shoulder, pose and pose.shoulder or CFrame.identity)
	write(joints.elbow, pose and pose.elbow or CFrame.identity)
	write(joints.wrist, pose and pose.wrist or CFrame.identity)

	-- Head and waist are only claimed DURING a wave. Outside it they are left to
	-- the walk animation, which should keep owning them.
	if pose then
		write(joints.neck, pose.neck)
		write(joints.waist, pose.waist)
	end
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------

local function setTrack(record, wanted)
	if record.activeTrack == wanted then
		return
	end
	if record.activeTrack then
		record.activeTrack:Stop(0.2)
	end
	record.activeTrack = wanted
	if wanted then
		wanted.Looped = true
		wanted.Priority = Enum.AnimationPriority.Core
		wanted:Play(0.2)
	end
end

local function updateAnimation(record, stage, speedStuds)
	local rig = record.rig
	-- Calibration owns the tracks while it measures each pose; fighting it here
	-- would corrupt its own measurement.
	if rig.calibrating then
		return
	end
	-- The departure runs its own jump -> fall sequence off a timer (see
	-- playDeparture). Leave its tracks alone or this would stop them every frame.
	if stage.phase == Phases.Depart then
		return
	end
	if stage.phase == Phases.Travel or stage.phase == Phases.WalkTo then
		setTrack(record, rig.walkTrack or rig.idleTrack)
		if rig.walkTrack and record.activeTrack == rig.walkTrack then
			-- The stock R15 walk is authored for a scale-1 rig moving at ~16
			-- studs/s. A rig S times larger covers S times more ground per stride,
			-- so the playback rate must be divided by S or the cycle runs wildly
			-- fast and the feet skate -- dividing by 16 alone ran it 3x too quick
			-- at the current scale. At S=3 and 20 studs/s this settles near 0.42,
			-- which reads as a giant taking slow, long strides.
			local reference = WALK_REFERENCE_STUDS_PER_SECOND * math.max(rig.scale, 0.01)
			-- Floor is low on purpose: at 4x scale a short within-plot hop is only
			-- ~7 studs/s, which for a 26-stud-tall rig genuinely IS an amble. A
			-- higher floor would make the feet skate on exactly those legs.
			rig.walkTrack:AdjustSpeed(math.clamp(speedStuds / reference, 0.08, 2))
		end
		return
	end
	setTrack(record, rig.idleTrack)
end

local function updateWave(record, stage, now, deltaTime)
	if stage.phase ~= Phases.Wave then
		record.nextBurstAt = nil
		record.nextSoundAt = nil
		return
	end
	local rig = record.rig
	local settings = record.settings

	if rig.emitter then
		record.nextBurstAt = record.nextBurstAt or now
		if now >= record.nextBurstAt then
			rig.emitter:Emit(settings.sparkleBurstCount)
			record.nextBurstAt = now + settings.sparkleBurstSeconds
		end
	end

	-- MagicSound is authored RollOffMaxDistance = 10000 (audible map-wide), so
	-- the explicit range is what actually gives it falloff. Parented to the wand
	-- handle so it travels with the effect.
	record.nextSoundAt = record.nextSoundAt or now
	if now >= record.nextSoundAt then
		local variance = settings.magicSoundPitchVariance
		SoundEffects.Play(SprinkleEvent.MagicSoundName, {
			pitchMin = 1 - variance,
			pitchMax = 1 + variance,
			range = settings.magicSoundRange,
			parent = rig.wandHandle or rig.root,
		})
		record.nextSoundAt = now + settings.magicSoundSeconds
	end
end

local function render(deltaTime)
	local record = session
	if not (record and record.rig and record.stage) then
		return
	end
	local rig = record.rig
	if not rig.root.Parent then
		return
	end

	local now = serverNow()
	local stage = record.stage
	local settings = record.settings

	local ground = stageGroundPosition(stage, settings, now)
	local previousGround = record.lastGround or ground
	record.lastGround = ground
	local speedStuds = deltaTime > 0 and (ground - previousGround).Magnitude / deltaTime or 0

	-- Yaw is turned toward the target at a capped rate rather than snapped, so
	-- direction changes at stop boundaries read as a turn.
	local wantedYaw = desiredFacing(record, stage, ground)
	local maxTurn = math.rad(settings.turnRateDegrees) * deltaTime
	local delta = (wantedYaw - record.yaw + math.pi) % (2 * math.pi) - math.pi
	record.yaw += math.clamp(delta, -maxTurn, maxTurn)

	updateAnimation(record, stage, speedStuds)

	-- Blend between the two animations' standing heights over the same window as
	-- the track crossfade, so switching to the walk cycle is one continuous
	-- motion rather than a vertical pop.
	local wantedStand = (record.activeTrack == rig.walkTrack and rig.walkHeight) or rig.idleHeight
	local blend = math.clamp(deltaTime / HEIGHT_BLEND_SECONDS, 0, 1)
	record.standHeight = (record.standHeight or wantedStand) + (wantedStand - (record.standHeight or wantedStand)) * blend

	local height = stageHeightOffset(stage, settings, now) + landingDip(record, now)
	if stage.phase == Phases.Depart then
		-- The jump's launch frame extends the legs ~4 studs below the standing
		-- pose (measured: rootAboveFeet 17.8 against a 13.5 stand). Since the rise
		-- is now deliberately zero-velocity at that instant, nothing lifts him off
		-- it and the feet would punch through the ground. Raising the root by the
		-- overshoot is what a real crouch does -- the feet stay planted and the
		-- hips travel -- and it costs nothing once he tucks, because the tuck
		-- makes rootAboveFeet SMALLER than the stand height.
		local poseDrop = measureRootAboveFeet(rig)
		if poseDrop then
			height = math.max(height, poseDrop - record.standHeight)
		end
	end
	rig.root.CFrame = CFrame.new(ground + Vector3.new(0, record.standHeight + height, 0))
		* CFrame.Angles(0, record.yaw, 0)
	updateWave(record, stage, now, deltaTime)
end

---------------------------------------------------------------------------
-- Session lifecycle
---------------------------------------------------------------------------

-- Forward declaration: beginSession drains the stage queued during calibration.
local applyStage

local function teardown()
	-- Also cancels any build still in flight, so a rig finishing calibration
	-- after a stop cannot install itself over the top.
	buildToken = nil
	pendingStage = nil

	local record = session
	if not record then
		return
	end
	session = nil
	if record.renderConnection then
		record.renderConnection:Disconnect()
	end
	if record.armConnection then
		record.armConnection:Disconnect()
	end
	local rig = record.rig
	if rig then
		if rig.idleTrack then
			rig.idleTrack:Stop(0)
		end
		if rig.walkTrack then
			rig.walkTrack:Stop(0)
		end
		if rig.emitter then
			rig.emitter:Destroy()
		end
		if rig.model then
			rig.model:Destroy()
		end
	end
end

-- Fades over the depart stage's own length so the rig finishes vanishing exactly
-- as the 200-stud jump tops out, instead of disappearing a third of the way up.
-- The exit: he jumps, then holds an airborne pose for the rest of the rise.
--
-- The authored jump ships Looped = false and runs 1.083s, but its last ~0.15s is
-- a LANDING recovery that drops the legs back down -- which would read as him
-- flailing hundreds of studs up. So the fall pose is crossfaded in at
-- JumpHoldSeconds, comfortably inside the measured tuck.
--
-- Token-guarded because the session can be torn down inside that delay.
local function playDeparture(record)
	local rig = record.rig
	if not rig or rig.calibrating then
		return
	end

	-- Whatever the walk/idle left running must not blend over the launch.
	if record.activeTrack then
		record.activeTrack:Stop(0.1)
		record.activeTrack = nil
	end

	local token = record.token
	local jump = rig.jumpTrack
	local fall = rig.fallTrack

	if jump then
		-- Forced every time: an uploaded animation only reports its real Looped
		-- value once the asset has resolved, and a looping jump would re-crouch
		-- forever (the pinata swing trap).
		jump.Looped = false
		jump.Priority = Enum.AnimationPriority.Action
		jump:Play(0.1)
	end

	if not fall then
		return
	end
	task.delay(jump and SprinkleEvent.JumpHoldSeconds or 0, function()
		if session ~= record or record.token ~= token then
			return
		end
		if not (rig.model and rig.model.Parent) then
			return
		end
		fall.Looped = true
		fall.Priority = Enum.AnimationPriority.Action
		fall:Play(SprinkleEvent.JumpToFallBlendSeconds)
		if jump then
			jump:Stop(SprinkleEvent.JumpToFallBlendSeconds)
		end
	end)
end

local function fadeOut(record, stage)
	local rig = record.rig
	if not (rig and rig.model) then
		return
	end
	local seconds = math.max(stage.endsAt - math.max(serverNow(), stage.startsAt), 0.1)
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, descendant in ipairs(rig.model:GetDescendants()) do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			TweenService:Create(descendant, info, { Transparency = 1 }):Play()
		end
	end
end

local function normalizeSettings(raw)
	raw = type(raw) == "table" and raw or {}
	return {
		entranceFallStuds = math.max(numberValue(raw.entranceFallStuds, 200), 0),
		exitRiseStuds = math.max(numberValue(raw.exitRiseStuds, 200), 0),
		turnRateDegrees = math.max(numberValue(raw.turnRateDegrees, 360), 1),
		phaseEaseSeconds = math.max(numberValue(raw.phaseEaseSeconds, 0.4), 0),
		waveSeconds = math.max(numberValue(raw.waveSeconds, 5), 0.1),
		waveRaiseSeconds = math.max(numberValue(raw.waveRaiseSeconds, 0.6), 0),
		waveLowerSeconds = math.max(numberValue(raw.waveLowerSeconds, 0.6), 0),
		armRaiseDegrees = numberValue(raw.armRaiseDegrees, 100),
		waveSwingDegrees = math.max(numberValue(raw.waveSwingDegrees, 38), 0),
		waveForeAftDegrees = math.max(numberValue(raw.waveForeAftDegrees, 20), 0),
		elbowSwingDegrees = math.max(numberValue(raw.elbowSwingDegrees, 24), 0),
		wristSwingDegrees = math.max(numberValue(raw.wristSwingDegrees, 30), 0),
		headSwingDegrees = math.max(numberValue(raw.headSwingDegrees, 18), 0),
		headNodDegrees = math.max(numberValue(raw.headNodDegrees, 7), 0),
		waistSwingDegrees = math.max(numberValue(raw.waistSwingDegrees, 9), 0),
		waveSwingHz = math.max(numberValue(raw.waveSwingHz, 1.15), 0),
		sparkleBurstCount = math.max(math.floor(numberValue(raw.sparkleBurstCount, 12)), 1),
		sparkleBurstSeconds = math.max(numberValue(raw.sparkleBurstSeconds, 0.15), 0.05),
		magicSoundSeconds = math.max(numberValue(raw.magicSoundSeconds, 1), 0.1),
		magicSoundRange = math.max(numberValue(raw.magicSoundRange, 200), 1),
		magicSoundPitchVariance = math.clamp(numberValue(raw.magicSoundPitchVariance, 0.3), 0, 0.9),
	}
end

local function normalizeStage(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local from = typeof(raw.from) == "Vector3" and raw.from or nil
	local to = typeof(raw.to) == "Vector3" and raw.to or from
	if not (from and to) then
		return nil
	end
	return {
		phase = tostring(raw.phase or Phases.Idle),
		from = from,
		to = to,
		facing = typeof(raw.facing) == "Vector3" and raw.facing or nil,
		areaCenter = typeof(raw.areaCenter) == "Vector3" and raw.areaCenter or nil,
		startsAt = numberValue(raw.startsAt, serverNow()),
		endsAt = numberValue(raw.endsAt, serverNow()),
	}
end

local function beginSession(payload)
	teardown()

	local token = {}
	buildToken = token
	pendingStage = payload.stage

	-- Yields for foot-height calibration.
	local rig = buildRig()
	if buildToken ~= token then
		-- Superseded by a newer start, or torn down while we were calibrating.
		if rig and rig.model then
			rig.model:Destroy()
		end
		return
	end
	buildToken = nil
	if not rig then
		pendingStage = nil
		return
	end

	local record = {
		token = tostring(payload.instanceId or ""),
		settings = normalizeSettings(payload.settings),
		spawnPosition = typeof(payload.spawnPosition) == "Vector3" and payload.spawnPosition or Vector3.zero,
		stage = nil,
		rig = rig,
		yaw = 0,
		lastGround = nil,
		activeTrack = nil,
	}
	session = record

	-- Park the rig where the first stage will start it, so the frame between
	-- build and the first render never shows it at the origin.
	record.standHeight = rig.idleHeight
	rig.root.CFrame = CFrame.new(record.spawnPosition + Vector3.new(0, rig.idleHeight + record.settings.entranceFallStuds, 0))

	record.renderConnection = RuntimeGuard.Connect(RunService.RenderStepped, "SprinkleEventController.Render", render)
	record.armConnection = RuntimeGuard.Connect(RunService.Stepped, "SprinkleEventController.ArmHold", stepArm)

	-- Whatever the server published while we were calibrating.
	if pendingStage then
		local queued = pendingStage
		pendingStage = nil
		applyStage(queued)
	end
end

function applyStage(payload)
	local record = session
	if not record then
		-- No session yet: either a build is calibrating (park it for that build to
		-- pick up) or there is nothing to render.
		if buildToken then
			pendingStage = payload
		end
		return
	end
	local stage = normalizeStage(payload)
	if not stage then
		return
	end
	record.stage = stage
	if stage.phase == Phases.Arrive then
		-- Remember when the fall lands, so the touchdown dip survives the server
		-- swapping in the next stage on that exact frame.
		record.landedAt = stage.endsAt
	elseif stage.phase == Phases.Depart then
		playDeparture(record)
		fadeOut(record, stage)
	end
end

local function onEffect(command, payload)
	payload = type(payload) == "table" and payload or {}

	if command == "start" or command == "sync" then
		local instanceId = tostring(payload.instanceId or "")
		if buildToken then
			-- A build for this instance is already calibrating; just keep its
			-- newest stage rather than restarting the build.
			pendingStage = payload.stage or pendingStage
			return
		end
		if not (session and session.token == instanceId) then
			beginSession(payload)
		elseif payload.stage then
			applyStage(payload.stage)
		end
		return
	end

	if command == "stage" then
		applyStage(payload)
		return
	end

	if command == "end" then
		-- instanceId-guarded: a delayed "end" from the previous sprinkle must not
		-- tear down one that started inside the old fade window.
		if session and session.token == tostring(payload.instanceId or "") then
			teardown()
		end
		return
	end
end

function SprinkleEventController.start()
	if started then
		return
	end
	started = true

	local remote = Remotes.get(Remotes.Names.SprinkleEventEffect)
	if not remote then
		warnSprinkle("Missing SprinkleEventEffect remote; sprinkle disabled")
		return
	end

	RuntimeGuard.Connect(remote.OnClientEvent, "SprinkleEventController.Effect", function(command, payload)
		onEffect(command, payload)
	end)

	-- A respawn or a leave must not strand the rig; it is presentation only.
	RuntimeGuard.Connect(player.AncestryChanged, "SprinkleEventController.PlayerLeft", function()
		if not player:IsDescendantOf(Players) then
			teardown()
		end
	end)
end

return SprinkleEventController
