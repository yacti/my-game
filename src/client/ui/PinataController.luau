-- Client presentation for admin-spawned pinatas. Pure presentation: HP, the
-- damage ledger, the reward split and every grant are server-owned and arrive
-- as State.Pinata.* attributes on the replicated Model. Nothing here mutates
-- gameplay state; the only outbound call is the argument-free swing intent.
--
-- Three things here are less obvious than they look:
--
-- 1. The drop-in bounce is PHASE-LOCKED to the server clock (Pinata.DropAt),
--    not triggered by ChildAdded. Under StreamingEnabled, ChildAdded fires on
--    stream-IN, so an event-triggered animation would replay the whole 20-stud
--    fall for anyone walking up twenty minutes later, and again on every
--    stream-out/in. Deriving the offset from elapsed server time makes
--    re-entry idempotent and converges every client on the same pose.
-- 2. The drop offset and the hit shake are two writers of the same pivot, so
--    they compose inside ONE record and ONE RenderStepped connection that
--    iterates tracked pinatas and prunes dead entries.
-- 3. Hit polish for the LOCAL player's own swing plays immediately on accepted
--    input rather than waiting for the HP attribute to change -- that optimism
--    is the acknowledgement. HP itself is never touched locally.
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Pinata = require(Shared:WaitForChild("Pinata"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local MotionSickness = require(script.Parent:WaitForChild("MotionSickness"))
local PlacementInput = require(script.Parent:WaitForChild("PlacementInput"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local PinataController = {}

local player = Players.LocalPlayer
local swingRemote = Remotes.get(Remotes.Names.PinataSwingRequest)

local SHAKE_DURATION = 0.28
local SHAKE_OFFSET = 0.55
local SHAKE_ANGLE = math.rad(7)
local SHAKE_FREQUENCY = 40
local HIGHLIGHT_FLASH_IN = 0.04
local HIGHLIGHT_FLASH_OUT = 0.22
local HIGHLIGHT_PEAK = 0.55
-- One reaction per pinata per window. Roblox stops rendering Highlights past a
-- per-client cap and Debris-managed Sounds have a 1s floor, so one flash and
-- one sound per individual hit is not survivable with many hitters.
local REMOTE_HIT_THROTTLE = 0.1
local BILLBOARD_RANGE = 75
local TAP_MOVE_THRESHOLD = 12
local TAP_MAX_SECONDS = 0.4
local SWING_KEYCODE = Enum.KeyCode.ButtonX
-- FruitPop is the game's established collect sound (tree pickups, harvests).
local PICKUP_SOUND_THROTTLE = 0.06

-- record = { model, primary, variantId, config, dropAt, billboard, fillFrame,
--            healthLabel, highlight, maxHp, hp, shakeStartedAt, lastPolishAt,
--            suppressHpPolishUntil, basePivot, needsRestore, connections }
local records = {}
-- dropRecord = { part, restPosition, origin, spawnedAt, seed, baseCFrame, connections }
local dropRecords = {}
local renderConnection = nil
local animationTracks = {}
-- Right-arm joints pinned to their neutral pose while the stick is out, and the
-- window during which a swing is allowed to drive them instead.
local armMotors = {}
local armHoldActive = false
local armHoldReleaseUntil = 0
local nextSwingIndex = 1
local localSwingReadyAt = 0
-- Incremented per swing so a scheduled contact belonging to a superseded swing
-- is discarded instead of firing late.
local swingToken = 0
local lastPickupSoundAt = 0
local touchStart = nil

local function serverNow()
	return Workspace:GetServerTimeNow()
end

-- ── Render ────────────────────────────────────────────────────────────────────

local function stopRenderIfIdle()
	if renderConnection and next(records) == nil and next(dropRecords) == nil then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

-- Launch arc -> landing bounces -> idle bob, all derived from the drop's
-- DropSpawnedAt stamp rather than from when this client happened to see it.
local function stepDrops(serverTime)
	for part, record in pairs(dropRecords) do
		if not part.Parent then
			dropRecords[part] = nil
			continue
		end
		local elapsed = serverTime - record.spawnedAt
		local position = Pinata.DropVisualPosition(record.restPosition, record.origin, elapsed, record.seed)
		if elapsed < Pinata.DropFlightSeconds then
			-- Tumble while airborne; settle upright once it lands.
			local spin = elapsed * Pinata.DropSpinSpeed
			part.CFrame = CFrame.new(position) * CFrame.Angles(spin, spin * 0.7, 0)
		else
			part.CFrame = CFrame.new(position) * record.baseCFrame.Rotation
		end
	end
end

local function stepRecords()
	local now = os.clock()
	local serverTime = serverNow()
	for model, record in pairs(records) do
		if not (model.Parent and record.primary and record.primary.Parent) then
			continue
		end

		local offsetY = 0
		if MotionSickness.AllowsShakeEffects() then
			offsetY = Pinata.DropOffsetAt(serverTime - record.dropAt, record.variantId)
		end

		local shakeX, shakeRoll = 0, 0
		if record.shakeStartedAt then
			local elapsed = now - record.shakeStartedAt
			if elapsed >= SHAKE_DURATION or not MotionSickness.AllowsShakeEffects() then
				record.shakeStartedAt = nil
			else
				local fade = 1 - (elapsed / SHAKE_DURATION)
				local wave = math.sin(elapsed * SHAKE_FREQUENCY) * fade
				shakeX = wave * SHAKE_OFFSET
				shakeRoll = wave * SHAKE_ANGLE
			end
		end

		if offsetY ~= 0 or shakeX ~= 0 or shakeRoll ~= 0 or record.needsRestore then
			model:PivotTo(record.basePivot
				* CFrame.new(shakeX, offsetY, 0)
				* CFrame.Angles(0, 0, shakeRoll))
			-- One final write once everything settles, so the model lands on
			-- exactly the authored pivot instead of a near-zero residual.
			record.needsRestore = (offsetY ~= 0 or shakeX ~= 0 or shakeRoll ~= 0)
		end
	end
	stepDrops(serverTime)
	stopRenderIfIdle()
end

local function ensureRender()
	if renderConnection then
		return
	end
	renderConnection = RuntimeGuard.Connect(RunService.RenderStepped, "PinataController.Render", function()
		RuntimeGuard.Run("PinataController.StepRecords", stepRecords)
	end)
end

-- ── Presentation ──────────────────────────────────────────────────────────────

local function renderHealth(record)
	if record.fillFrame then
		local fraction = 0
		if record.maxHp > 0 then
			fraction = math.clamp(record.hp / record.maxHp, 0, 1)
		end
		record.fillFrame.Size = UDim2.new(fraction, 0, 1, 0)
	end
	if record.healthLabel then
		-- Plain integers, matching the authored "50/100" template. Deliberately
		-- not NumberFormatter.Currency: this is hit points, not money, and the
		-- currency formatter would render 1000 HP as "$1K".
		record.healthLabel.Text = string.format("%d/%d", math.max(record.hp, 0), record.maxHp)
	end
end

local function flashHighlight(record)
	local highlight = record.highlight
	if not (highlight and highlight.Parent) then
		return
	end
	TweenService:Create(highlight, TweenInfo.new(HIGHLIGHT_FLASH_IN), {
		FillTransparency = 1 - HIGHLIGHT_PEAK,
	}):Play()
	task.delay(HIGHLIGHT_FLASH_IN, function()
		if highlight and highlight.Parent then
			TweenService:Create(highlight, TweenInfo.new(HIGHLIGHT_FLASH_OUT), {
				FillTransparency = 1,
			}):Play()
		end
	end)
end

local function soundEmitter(record)
	local primary = record.primary
	if not (primary and primary.Parent) then
		return nil
	end
	local attachment = primary:FindFirstChild("PinataHitSound")
	if not (attachment and attachment:IsA("Attachment")) then
		attachment = Instance.new("Attachment")
		attachment.Name = "PinataHitSound"
		attachment.Parent = primary
	end
	return attachment
end

-- The single place a hit is presented, for both the local player's own swing
-- (fired at animation contact) and other players' hits (driven by the HP
-- attribute). Owns lastPolishAt so one throttle governs both paths.
-- `silent` suppresses only the hit sound, for the killing blow where the
-- confetti sound plays instead.
local function playHitPolish(record, silent)
	record.lastPolishAt = os.clock()
	record.shakeStartedAt = os.clock()
	ensureRender()
	flashHighlight(record)
	if silent then
		return
	end
	SoundEffects.PlayVaried(SoundEffects.Names.PinataHit, {
		parent = soundEmitter(record),
		range = Pinata.HitSoundRange,
		rollOffMinDistance = Pinata.HitSoundMinRange,
		pitchVariance = Pinata.HitPitchVariance,
	})
end

-- One-shot confetti burst from the centre of the pinata, plus the celebration
-- sound played positionally. Follows the house burst pattern (BeeEventController):
-- clone the Studio template, disable its emitters, :Emit() a fixed count, and
-- let Debris clean the whole thing up.
local function playBreakEffect(record)
	if record.brokenPlayed then
		return
	end
	record.brokenPlayed = true

	-- A final flash and shake, but the confetti sound replaces the hit sound so
	-- the two do not stack on the killing blow.
	playHitPolish(record, true)

	local origin = record.primary and record.primary.Position
	if not origin then
		return
	end
	-- Burst from the middle of the model rather than the pivot, so a tall
	-- Golden does not throw its confetti out of its feet.
	local okBox, boxCFrame = pcall(function()
		local cf = record.model:GetBoundingBox()
		return cf
	end)
	if okBox and typeof(boxCFrame) == "CFrame" then
		origin = boxCFrame.Position
	end

	local burst = nil
	local vfxFolder = Assets.Find(Assets.Names.VFX)
	local template = vfxFolder and vfxFolder:FindFirstChild(Pinata.BreakVfxName)
	if template and template:IsA("BasePart") then
		burst = template:Clone()
		burst.Name = "PinataConfettiBurst"
		burst.Anchored = true
		burst.CanCollide = false
		burst.CanQuery = false
		burst.CanTouch = false
		burst.Transparency = 1
		burst.Position = origin
		for _, descendant in ipairs(burst:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				-- The authored emitters ship Enabled = true and would spray
				-- continuously; a break is a one-shot burst.
				descendant.Enabled = false
				local count = tonumber(descendant:GetAttribute("EmitCount")) or Pinata.BreakVfxEmitCount
				descendant:Emit(math.max(math.floor(count), 1))
			end
		end
		burst.Parent = Workspace
		Debris:AddItem(burst, Pinata.BreakVfxLifetimeSeconds)
	else
		warn("[PinataController] Missing Assets.VFX." .. Pinata.BreakVfxName .. "; confetti skipped")
	end

	-- Parented to the burst, NOT to the pinata: the server destroys the model
	-- shortly after the break, which would cut the sound off mid-playback.
	SoundEffects.Play(SoundEffects.Names.Confetti, {
		parent = burst or soundEmitter(record),
		range = Pinata.BreakSoundRange,
		rollOffMinDistance = Pinata.BreakSoundMinRange,
	})
end

local function attachBillboard(record)
	local template = BillboardGuiTemplates.Find(Pinata.BillboardTemplateName)
	if not template then
		warn("[PinataController] Missing " .. Pinata.BillboardTemplateName .. " billboard; health bar skipped")
		return
	end
	local gui = template:Clone()
	local healthFrame = gui:FindFirstChild("Health")
	local fillFrame = healthFrame and healthFrame:FindFirstChild("Fill")
	local healthLabel = healthFrame and healthFrame:FindFirstChild("Health")
	if not (fillFrame and fillFrame:IsA("GuiObject") and healthLabel and healthLabel:IsA("TextLabel")) then
		warn("[PinataController] PinataBillboard is missing Health.Fill / Health.Health; health bar skipped")
		gui:Destroy()
		return
	end

	record.billboard = gui
	record.fillFrame = fillFrame
	record.healthLabel = healthLabel
	-- Content on the clone, before binding; UiEffects owns Size afterwards.
	renderHealth(record)
	-- Golden is 17.2 studs tall, so the authored 6-stud offset would put the
	-- bar inside the model. Per-variant, set before the pop binds.
	gui.StudsOffset = Vector3.new(0, record.config.BillboardStudsOffsetY, 0)
	gui.MaxDistance = BILLBOARD_RANGE
	UiEffects.BindBillboardPop(gui)
	gui.Adornee = record.primary
	gui.Parent = record.primary
	UiEffects.BindBillboardDistancePop(gui)
end

local function attachHighlight(record)
	local highlight = Instance.new("Highlight")
	highlight.Name = "PinataHitFlash"
	highlight.Adornee = record.model
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	-- Parented to the camera so it stays purely client-local and never rides
	-- the replicated model (the LocalPrompts FoodPetHighlight pattern).
	highlight.Parent = Workspace.CurrentCamera or record.model
	record.highlight = highlight
end

-- ── Tracking ──────────────────────────────────────────────────────────────────

local function untrack(model)
	local record = records[model]
	if not record then
		return
	end
	records[model] = nil
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	if record.billboard then
		record.billboard:Destroy()
	end
	if record.highlight then
		record.highlight:Destroy()
	end
	stopRenderIfIdle()
end

local function track(model)
	if records[model] or not model:IsA("Model") then
		return
	end
	local variantId = model:GetAttribute(State.Pinata.Variant)
	local config = Pinata.VariantConfig(variantId)
	local primary = model.PrimaryPart
	if not (config and primary) then
		return
	end

	local record = {
		model = model,
		primary = primary,
		variantId = variantId,
		config = config,
		dropAt = tonumber(model:GetAttribute(State.Pinata.DropAt)) or serverNow(),
		maxHp = tonumber(model:GetAttribute(State.Pinata.MaxHp)) or config.MaxHp,
		hp = tonumber(model:GetAttribute(State.Pinata.Hp)) or config.MaxHp,
		basePivot = model:GetPivot(),
		shakeStartedAt = nil,
		lastPolishAt = 0,
		suppressHpPolishUntil = nil,
		brokenPlayed = false,
		needsRestore = false,
		connections = {},
	}
	records[model] = record

	attachBillboard(record)
	attachHighlight(record)

	table.insert(record.connections, RuntimeGuard.Connect(
		model:GetAttributeChangedSignal(State.Pinata.Hp),
		"PinataController.HpChanged",
		function()
			local nextHp = tonumber(model:GetAttribute(State.Pinata.Hp)) or 0
			local dropped = record.hp - nextHp
			record.hp = nextHp
			renderHealth(record)
			if dropped <= 0 then
				return
			end

			-- Killing blow: confetti + celebration sound, always. Deliberately
			-- ahead of the local-swing suppression -- that only exists to stop
			-- a doubled HIT sound, and must never swallow the break.
			if nextHp <= 0 then
				record.suppressHpPolishUntil = nil
				RuntimeGuard.Run("PinataController.PlayBreakEffect", playBreakEffect, record)
				return
			end

			local now = os.clock()
			-- Our own swing already played this hit at contact time. Consume the
			-- claim (one-shot) so the echo of the server's HP write does not
			-- play a second sound for the same swing.
			if record.suppressHpPolishUntil and now < record.suppressHpPolishUntil then
				record.suppressHpPolishUntil = nil
				return
			end
			record.suppressHpPolishUntil = nil

			-- Someone else's hit. Throttled: with twenty hitters the raw rate
			-- would be dozens of sounds a second on one client.
			if now - record.lastPolishAt >= REMOTE_HIT_THROTTLE then
				playHitPolish(record)
			end
		end
	))

	ensureRender()
end

-- ── Swing input ───────────────────────────────────────────────────────────────

local function nearestRecord(maxDistance)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local best, bestDistance = nil, math.huge
	for model, record in pairs(records) do
		if model.Parent then
			-- Surface distance: pinatas hang well above the ground, so pivot
			-- distance would read as out-of-range while standing underneath.
			local distance = Pinata.DistanceToModel(model, root.Position)
			if distance <= maxDistance and distance < bestDistance then
				best, bestDistance = record, distance
			end
		end
	end
	return best
end

local function stickModel()
	local character = player.Character
	return character and character:FindFirstChild(Pinata.StickAccessoryName) or nil
end

local function loadSwingTracks()
	if #animationTracks > 0 then
		return animationTracks
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local misc = assets and assets:FindFirstChild("Misc")
	local template = misc and misc:FindFirstChild(Pinata.StickModelName)
	if not (animator and template) then
		return animationTracks
	end

	for _, attributeName in ipairs(Pinata.SwingAnimationAttributes) do
		local animationId = template:GetAttribute(attributeName)
		if type(animationId) == "string" and animationId:match(Pinata.AnimationIdPattern) then
			local animation = Instance.new("Animation")
			animation.Name = attributeName
			animation.AnimationId = animationId
			local ok, track = pcall(function()
				return animator:LoadAnimation(animation)
			end)
			if ok and track then
				track.Priority = Enum.AnimationPriority.Action
				-- MUST be explicit. A swing is one-shot per click, but an
				-- uploaded animation can carry Looped = true and the track
				-- inherits it -- which reads in game as the character
				-- auto-attacking forever after a single click.
				track.Looped = false
				animationTracks[#animationTracks + 1] = track
			else
				animation:Destroy()
				warn("[PinataController] Failed to load swing animation " .. animationId)
			end
		else
			warn("[PinataController] PinataStick." .. attributeName .. " missing or malformed; swing animation skipped")
		end
	end
	return animationTracks
end

local function clearSwingTracks()
	for _, track in ipairs(animationTracks) do
		pcall(function()
			track:Stop(0)
			track:Destroy()
		end)
	end
	animationTracks = {}
	nextSwingIndex = 1
	armMotors = {}
end

-- Pins the right arm to the rig's DEFAULT IDLE pose (hanging at the side) while
-- the stick is out, so the walk/run cycle does not swing the bat around.
--
-- Animation tracks write to the joint's Transform, so zeroing it each frame
-- cancels the walk animation's contribution for those joints only -- legs,
-- torso and left arm keep animating normally (verified: legs still travel ~0.8
-- while the hand is pinned). An identity Transform is precisely the rig's
-- neutral pose, which is why this reads as "arm down at the side" rather than
-- as a frozen frame of some animation.
--
-- This rig's joints are AnimationConstraint, NOT Motor6D -- the avatar has zero
-- Motor6Ds despite being R15. Both are accepted so a classic rig still works.
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

local function collectArmMotors(character)
	armMotors = {}
	if not character then
		return
	end
	-- R15: one joint per limb, parented to the child limb.
	for _, limbName in ipairs({ "RightUpperArm", "RightLowerArm", "RightHand" }) do
		local joint = armJointIn(character:FindFirstChild(limbName))
		if joint then
			armMotors[#armMotors + 1] = joint
		end
	end
	if #armMotors > 0 then
		return
	end
	-- R6 fallback: a single shoulder joint on the torso.
	local torso = character:FindFirstChild("Torso")
	local shoulder = torso and torso:FindFirstChild("Right Shoulder")
	if shoulder and (shoulder:IsA("AnimationConstraint") or shoulder:IsA("Motor6D")) then
		armMotors[1] = shoulder
	end
	if #armMotors == 0 then
		warn("[PinataController] No right-arm joints found; arm hold skipped")
	end
end

local function startArmHold()
	armHoldActive = true
	collectArmMotors(player.Character)
end

local function stopArmHold()
	armHoldActive = false
	armMotors = {}
end

-- Must run on RunService.Stepped. Measured against the alternatives: writing
-- from RenderStepped (even after RenderPriority.Character) or PreRender is
-- overwritten by the animator and the arm keeps swinging; only Stepped runs
-- late enough for the value to survive the frame.
local function stepArmHold()
	if not armHoldActive or os.clock() < armHoldReleaseUntil then
		return
	end
	for index = #armMotors, 1, -1 do
		local motor = armMotors[index]
		if motor.Parent then
			motor.Transform = CFrame.identity
		else
			table.remove(armMotors, index)
		end
	end
end

-- One click = one swing, alternating between the two authored animations.
-- Any still-playing track is stopped first so a fast second click cannot blend
-- the two together into a stuck pose. Returns how long until the bat connects,
-- so the caller can line the impact up with the animation.
local function playSwingAnimation()
	local tracks = loadSwingTracks()
	if #tracks == 0 then
		return Pinata.SwingContactFallbackSeconds
	end
	local track = tracks[((nextSwingIndex - 1) % #tracks) + 1]
	nextSwingIndex += 1
	pcall(function()
		for _, other in ipairs(tracks) do
			if other ~= track and other.IsPlaying then
				other:Stop(0.05)
			end
		end
		-- Restart from the beginning even if this same track is mid-play.
		if track.IsPlaying then
			track:Stop(0)
		end
		-- Re-assert every time: both authored animations upload Looped = true,
		-- and the flag only settles once the asset has resolved, so a value set
		-- at load time can be set before the real one arrives.
		track.Looped = false
		track:Play(0.08)
	end)

	-- Length only resolves once the asset has downloaded; until then use the
	-- measured-average fallback rather than firing contact instantly.
	local length = track.Length
	if type(length) ~= "number" or length ~= length or length <= 0 then
		return Pinata.SwingContactFallbackSeconds
	end
	return length * Pinata.SwingContactFraction
end

-- The moment the bat connects: this is the ONLY place a local swing produces
-- damage or presentation. Firing the remote here too (rather than on the click)
-- keeps the health bar, the sound and the shake on the same frame.
local function onSwingContact(token)
	if token ~= swingToken then
		return -- superseded by a newer swing
	end
	if not stickModel() then
		return
	end
	swingRemote:FireServer()

	local record = nearestRecord(Pinata.SwingReachStuds)
	if not (record and Pinata.HasLanded(serverNow() - record.dropAt)) then
		return
	end
	-- Predicted presentation only; HP itself still comes from the server. Claim
	-- the HP change this swing is about to cause so the attribute listener does
	-- not play the same hit a second time.
	record.suppressHpPolishUntil = os.clock() + Pinata.LocalHitSuppressSeconds
	playHitPolish(record)
end

local function trySwing()
	-- Only while the server has given us the stick.
	if not stickModel() then
		return
	end
	local now = os.clock()
	if now < localSwingReadyAt then
		return
	end
	-- Mirrors the server cooldown so local prediction rarely disagrees.
	localSwingReadyAt = now + Pinata.SwingCooldownSeconds

	local contactDelay = playSwingAnimation()
	-- Let the swing animation drive the arm; the idle hold resumes after it.
	armHoldReleaseUntil = now + Pinata.ArmHoldSwingReleaseSeconds
	swingToken += 1
	local token = swingToken
	task.delay(contactDelay, function()
		RuntimeGuard.Run("PinataController.SwingContact", onSwingContact, token)
	end)
end

local function swingBlocked(screenPosition)
	if UserInputService:GetFocusedTextBox() ~= nil then
		return true
	end
	if screenPosition and PlacementInput.IsInteractiveGuiAt(screenPosition) then
		return true
	end
	if player:GetAttribute("EditMode") == true then
		return true
	end
	return false
end

local function onInputBegan(input, gameProcessed)
	if input.KeyCode == SWING_KEYCODE then
		if not gameProcessed and not swingBlocked(nil) then
			RuntimeGuard.Run("PinataController.GamepadSwing", trySwing)
		end
		return
	end
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if not swingBlocked(PlacementInput.ScreenPosition(input)) then
			RuntimeGuard.Run("PinataController.MouseSwing", trySwing)
		end
	elseif input.UserInputType == Enum.UserInputType.Touch then
		-- Touch begins a camera pan too, so a tap is only committed on release
		-- if the finger barely moved. Without this you cannot rotate the camera
		-- near a pinata without swinging.
		touchStart = { position = PlacementInput.ScreenPosition(input), at = os.clock() }
	end
end

local function onInputEnded(input)
	if input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local start = touchStart
	touchStart = nil
	if not start then
		return
	end
	local finish = PlacementInput.ScreenPosition(input)
	if not (start.position and finish) then
		return
	end
	if os.clock() - start.at > TAP_MAX_SECONDS then
		return
	end
	if (finish - start.position).Magnitude > TAP_MOVE_THRESHOLD then
		return
	end
	if swingBlocked(finish) then
		return
	end
	RuntimeGuard.Run("PinataController.TouchSwing", trySwing)
end

-- ── Drops ─────────────────────────────────────────────────────────────────────

local function untrackDrop(part)
	local record = dropRecords[part]
	if not record then
		return
	end
	dropRecords[part] = nil
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end

	-- Pickup sound. Purely client-side: our own drop vanished while we were
	-- standing on it, which only happens when the server granted it. The
	-- distance check keeps an admin CLEAR from firing a burst of pops for drops
	-- we were nowhere near.
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local mine = tonumber(part:GetAttribute(State.Pinata.DropOwner)) == player.UserId
	if mine and root and (root.Position - record.restPosition).Magnitude <= Pinata.DropCollectRadius + 2 then
		local now = os.clock()
		-- One sweep can collect several at once; a small gate stops them landing
		-- on the same frame. PlayVaried's pitch spread makes a run of pickups
		-- read as a cascade rather than a flat repeat.
		if now - lastPickupSoundAt >= PICKUP_SOUND_THROTTLE then
			lastPickupSoundAt = now
			SoundEffects.PlayVaried(SoundEffects.Names.FruitPop)
		end
	end

	stopRenderIfIdle()
end

local function bindDrop(part)
	if not part:IsA("BasePart") or dropRecords[part] then
		return
	end

	local record = {
		part = part,
		-- The server's position is authoritative and never moves; every phase
		-- of the presentation is drawn relative to it.
		restPosition = part.Position,
		origin = part:GetAttribute(State.Pinata.DropOrigin),
		spawnedAt = tonumber(part:GetAttribute(State.Pinata.DropSpawnedAt)) or serverNow(),
		-- Stable per-drop seed so the bob phase is consistent across clients.
		seed = math.floor(part.Position.X * 7 + part.Position.Z * 13),
		baseCFrame = part.CFrame,
		connections = {},
	}
	if typeof(record.origin) ~= "Vector3" then
		record.origin = record.restPosition
	end
	dropRecords[part] = record

	local function refreshOwner()
		local owner = tonumber(part:GetAttribute(State.Pinata.DropOwner))
		local mine = owner == player.UserId
		for _, descendant in ipairs(part:GetDescendants()) do
			if descendant:IsA("BillboardGui") then
				-- Local-only property write on a replicated instance: each
				-- client shows only its own drops. Deliberately not
				-- UiEffects-bound -- these are server-owned and a stream-in
				-- would silently invalidate the cached base Size/MaxDistance.
				descendant.Enabled = mine
			end
		end
	end
	refreshOwner()
	table.insert(record.connections, RuntimeGuard.Connect(
		part:GetAttributeChangedSignal(State.Pinata.DropOwner),
		"PinataController.DropOwnerChanged",
		refreshOwner
	))

	ensureRender()
end

local function bindFolder(folder, onAdded)
	for _, child in ipairs(folder:GetChildren()) do
		RuntimeGuard.Run("PinataController.BindExisting", onAdded, child)
	end
	RuntimeGuard.Connect(folder.ChildAdded, "PinataController.ChildAdded", onAdded)
end

function PinataController.start()
	RuntimeGuard.Spawn("PinataController.Watch", function()
		local pinataFolder = Workspace:WaitForChild(Pinata.RuntimeFolderName, 30)
		if pinataFolder then
			bindFolder(pinataFolder, track)
			RuntimeGuard.Connect(pinataFolder.ChildRemoved, "PinataController.PinataRemoved", untrack)
		else
			warn("[PinataController] Workspace." .. Pinata.RuntimeFolderName .. " never appeared; pinatas will not render")
		end

		local dropFolder = Workspace:WaitForChild(Pinata.DropsFolderName, 30)
		if dropFolder then
			bindFolder(dropFolder, bindDrop)
			RuntimeGuard.Connect(dropFolder.ChildRemoved, "PinataController.DropRemoved", untrackDrop)
		end
	end)

	RuntimeGuard.Connect(UserInputService.InputBegan, "PinataController.InputBegan", onInputBegan)
	RuntimeGuard.Connect(UserInputService.InputEnded, "PinataController.InputEnded", onInputEnded)

	-- Stepped, not RenderStepped: see stepArmHold. Connected once for the
	-- session; it early-outs to almost nothing whenever the stick is not out.
	RuntimeGuard.Connect(RunService.Stepped, "PinataController.ArmHold", function()
		RuntimeGuard.Run("PinataController.StepArmHold", stepArmHold)
	end)

	-- The server adds/removes the welded stick as the player enters and leaves
	-- range; mirror that with the arm-hold pose.
	local function bindCharacter(character)
		RuntimeGuard.Connect(character.ChildAdded, "PinataController.CharacterChildAdded", function(child)
			if child.Name == Pinata.StickAccessoryName then
				RuntimeGuard.Run("PinataController.StartArmHold", startArmHold)
			end
		end)
		RuntimeGuard.Connect(character.ChildRemoved, "PinataController.CharacterChildRemoved", function(child)
			if child.Name == Pinata.StickAccessoryName then
				RuntimeGuard.Run("PinataController.StopArmHold", stopArmHold)
			end
		end)
		if character:FindFirstChild(Pinata.StickAccessoryName) then
			RuntimeGuard.Run("PinataController.StartArmHold", startArmHold)
		end
	end

	-- Animation tracks belong to one Animator; drop them when it goes away.
	RuntimeGuard.Connect(player.CharacterAdded, "PinataController.CharacterAdded", function(character)
		clearSwingTracks()
		touchStart = nil
		bindCharacter(character)
	end)
	if player.Character then
		bindCharacter(player.Character)
	end
end

return PinataController
