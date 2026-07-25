-- Bee event active-phase visuals. The server authors one deterministic
-- schedule per farm turn (seed, unlocked-cell rects, pollination hover
-- windows); this controller clones one local swarm of 9 bees into
-- Workspace.__LocalBeeEvent and derives every bee's position from
-- BeeEvent.Flight as a pure function of Workspace:GetServerTimeNow() -- so
-- every client (including late joiners synced by the server's 1s viewer
-- loop) renders identical flight with zero per-frame replication.
--
-- Presentation layered on top of the deterministic positions (never fed back
-- into them): yaw/bank smoothing, wing flutter about the authored PivotOffset
-- hinges, per-bee one-shot buzzes, and pollination sparkles.
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BeeEvent = require(Shared:WaitForChild("BeeEvent"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local EventLighting = require(script.Parent:WaitForChild("EventLighting"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local BeeEventController = {}

local BEE_LIGHTING_PRIORITY = tonumber((GameEvents.GetEvent(GameEvents.Ids.Bee) or {}).priority) or 0
local LIGHTING_PRESET_NAME = "Bees"

local LOCAL_FOLDER_NAME = "__LocalBeeEvent"
local WAIT_SECONDS = 10
local FADE_SECONDS = 1
local EMERGE_STAGGER_SECONDS = 0.15
-- Blend window easing a bee between its roam path and a pollination orbit.
local HOVER_BLEND_SECONDS = 1.5
-- Wing CFrame writes are skipped beyond this camera distance; positions are
-- never culled ("everyone sees everyone's bees").
local WING_DETAIL_DISTANCE = 150
local YAW_SMOOTH_PER_SECOND = 7
local BANK_SMOOTH_PER_SECOND = 5
local BANK_PER_YAW_RATE = 0.6
local MIN_MOVE_SPEED = 0.4
-- The bee mesh is authored with its RIGHT vector (+X of the PrimaryPart) as
-- its front, so a +90-degree yaw maps model +X onto the pose frame's -Z
-- travel direction.
local MODEL_FORWARD_CORRECTION = CFrame.Angles(0, math.rad(90), 0)
local SPARKLE_LIFETIME_SECONDS = 3

local started = false
local activeToken = nil
local pendingEffect = nil
local presentationRng = Random.new()

local function warnBee(message)
	warn("[BeeEventController] " .. message)
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function onboardingComplete()
	local state = PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding)
	return type(state) == "table" and not Onboarding.IsActive(Onboarding.SanitizeState(state, Onboarding.CompleteState()).Stage)
end

local function hasOnboardingState()
	return type(PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding)) == "table"
end

local function localFolder()
	local folder = Workspace:FindFirstChild(LOCAL_FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if folder then
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = LOCAL_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function clearLocalFolder()
	local folder = Workspace:FindFirstChild(LOCAL_FOLDER_NAME)
	if folder then
		folder:Destroy()
	end
end

local function beeTemplate()
	local assets = ReplicatedStorage:WaitForChild("Assets", WAIT_SECONDS)
	local misc = assets and assets:WaitForChild("Misc", WAIT_SECONDS)
	local template = misc and misc:FindFirstChild(BeeEvent.BeeTemplateName)
	if not (template and template:IsA("Model")) then
		warnBee("Missing ReplicatedStorage.Assets.Misc." .. BeeEvent.BeeTemplateName)
		return nil
	end
	return template
end

local function prepareInstance(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

local function setModelTransparency(model, transparency)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = transparency
		end
	end
end

local function tweenModelTransparency(token, model, transparency, seconds)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local tween = TweenService:Create(descendant, TweenInfo.new(seconds), { Transparency = transparency })
			token.tweens[#token.tweens + 1] = tween
			tween:Play()
		end
	end
end

-- Loose ring formation the swarm keeps while emerging/idling at the hive; a
-- late joiner mid-transit also seeds unknown bee positions from this shape.
local function formationOffset(beeIndex)
	local angle = (beeIndex / BeeEvent.BeeCount) * math.pi * 2
	return Vector3.new(math.cos(angle) * 2.5, (beeIndex % 3 - 1) * 0.8, math.sin(angle) * 2.5)
end

local function spawnPositionFor(token, beeIndex)
	local positions = token.spawnPositions
	local position = type(positions) == "table" and positions[beeIndex] or nil
	if typeof(position) == "Vector3" then
		return position
	end
	local hive = BeeEvent.FindHiveMesh()
	local anchor = hive and hive.Position or Vector3.zero
	return anchor + formationOffset(beeIndex)
end

local function buildBees(token)
	local template = beeTemplate()
	if not template then
		return false
	end
	local folder = localFolder()
	for beeIndex = 1, BeeEvent.BeeCount do
		local model = template:Clone()
		model.Name = "Bee" .. tostring(beeIndex)
		prepareInstance(model)
		setModelTransparency(model, 1)
		local spawn = spawnPositionFor(token, beeIndex)
		model:PivotTo(CFrame.new(spawn))
		model.Parent = folder

		local pivot = model:GetPivot()
		local wings = {}
		local animated = model:FindFirstChild("Animated")
		for wingNumber, sign in ipairs({ 1, -1 }) do
			local wing = animated and animated:FindFirstChild("Wing" .. tostring(wingNumber))
			if wing and wing:IsA("BasePart") then
				wings[#wings + 1] = {
					part = wing,
					restPivot = pivot:ToObjectSpace(wing:GetPivot()),
					sign = sign,
				}
			end
		end
		local body = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		token.bees[beeIndex] = {
			model = model,
			body = body,
			wings = wings,
			currentPosition = spawn,
			yaw = presentationRng:NextNumber(0, math.pi * 2),
			bank = 0,
			nextBuzzAt = serverNow() + presentationRng:NextNumber(1, tonumber(token.settings.buzzMaxSeconds) or 30),
		}
	end
	return true
end

local function sparkleTemplateEmitter()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local mutations = assets and assets:FindFirstChild("Mutations")
	local pollinated = mutations and mutations:FindFirstChild(BeeEvent.MutationId)
	if not pollinated then
		return nil
	end
	return pollinated:FindFirstChildWhichIsA("ParticleEmitter", true)
end

local function emitPollinationSparkle(position)
	if typeof(position) ~= "Vector3" then
		return
	end
	local emitterTemplate = sparkleTemplateEmitter()
	if not emitterTemplate then
		return
	end
	local part = Instance.new("Part")
	part.Name = "__BeePollinationSparkle"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.Size = Vector3.new(0.25, 0.25, 0.25)
	part.Position = position
	part.Parent = localFolder()
	local emitter = emitterTemplate:Clone()
	emitter.Enabled = false
	emitter.Parent = part
	emitter:Emit(25)
	Debris:AddItem(part, SPARKLE_LIFETIME_SECONDS)
end

local function cleanupToken(token)
	if not token then
		return
	end
	token.cancelled = true
	for _, tween in ipairs(token.tweens) do
		tween:Cancel()
	end
	clearLocalFolder()
	EventLighting.Release(GameEvents.Ids.Bee, 0.35)
	if activeToken == token then
		activeToken = nil
	end
end

local function beginEvent(payload, options)
	if activeToken then
		cleanupToken(activeToken)
	end
	options = type(options) == "table" and options or {}
	local token = {
		instanceId = payload and payload.instanceId,
		settings = type(payload and payload.settings) == "table" and payload.settings or {},
		spawnPositions = payload and payload.spawnPositions,
		bees = {},
		tweens = {},
		currentTurn = nil,
		timelines = nil,
		returnState = nil,
		cancelled = false,
	}
	activeToken = token
	if not buildBees(token) then
		cleanupToken(token)
		return nil
	end
	local windUpSeconds = tonumber(token.settings.windUpSeconds) or 0
	EventLighting.Claim(GameEvents.Ids.Bee, LIGHTING_PRESET_NAME, BEE_LIGHTING_PRIORITY, windUpSeconds)
	if options.instant then
		-- Late-join sync: the swarm is already out; skip the emergence fade.
		for _, bee in ipairs(token.bees) do
			setModelTransparency(bee.model, 0)
		end
	else
		for beeIndex, bee in ipairs(token.bees) do
			task.delay((beeIndex - 1) * EMERGE_STAGGER_SECONDS, function()
				if not token.cancelled and bee.model.Parent then
					tweenModelTransparency(token, bee.model, 0, FADE_SECONDS)
				end
			end)
		end
	end
	return token
end

local function ensureEvent(payload, options)
	if not activeToken or (payload and activeToken.instanceId ~= payload.instanceId) then
		return beginEvent(payload or {}, options)
	end
	return activeToken
end

-- Installs a turn schedule: deterministic per-bee roam timelines plus the
-- transit lead-in from wherever each bee currently is (late joiners seed
-- unknown positions from a formation around the server-provided swarmFrom).
local function applyTurn(token, turn)
	if type(turn) ~= "table" then
		return
	end
	token.currentTurn = turn
	token.returnState = nil
	token.timelines = {}
	local settings = token.settings
	for beeIndex, bee in ipairs(token.bees) do
		token.timelines[beeIndex] = BeeEvent.Flight.BuildTimeline(
			turn.seed,
			beeIndex,
			turn.cells,
			turn.startsAt,
			turn.endsAt,
			settings
		)
		if typeof(turn.swarmFrom) == "Vector3" and (bee.currentPosition - turn.swarmFrom).Magnitude > 500 then
			-- Fresh/desynced bee (late join): snap the transit origin to the
			-- swarm's authoritative departure point.
			bee.currentPosition = turn.swarmFrom + formationOffset(beeIndex)
		end
		bee.transitFrom = bee.currentPosition
	end
	for _, pollination in ipairs(turn.pollinations or {}) do
		pollination.cancelled = false
	end
end

local function cancelTurnPollinations(token)
	local turn = token.currentTurn
	if not turn then
		return
	end
	for _, pollination in ipairs(turn.pollinations or {}) do
		pollination.cancelled = true
	end
end

local function handleWindDown(token, payload)
	local now = serverNow()
	local endsAt = tonumber(payload and payload.endsAt) or now
	local budget = math.max(endsAt - now, 1)
	token.currentTurn = nil
	token.timelines = nil
	local settings = token.settings
	local transitSpeed = math.max(tonumber(settings.transitSpeedStuds) or 18, 1)
	local returns = {}
	for beeIndex, bee in ipairs(token.bees) do
		local target = spawnPositionFor(token, beeIndex)
		local seconds = math.clamp((target - bee.currentPosition).Magnitude / transitSpeed, 0.5, budget - 0.5)
		returns[beeIndex] = {
			from = bee.currentPosition,
			target = target,
			startsAt = now,
			endsAt = now + seconds,
		}
		task.delay(seconds, function()
			if not token.cancelled and bee.model.Parent then
				tweenModelTransparency(token, bee.model, 1, FADE_SECONDS)
			end
		end)
	end
	token.returnState = returns
	EventLighting.Release(GameEvents.Ids.Bee, math.min(budget, 3))
end

-- Deterministic world position for one bee at time `now`.
local function targetPositionFor(token, beeIndex, bee, now)
	local returnState = token.returnState and token.returnState[beeIndex]
	if returnState then
		local span = returnState.endsAt - returnState.startsAt
		local alpha = span > 0 and BeeEvent.Flight.EasedAlpha((now - returnState.startsAt) / span) or 1
		return returnState.from:Lerp(returnState.target, alpha)
	end

	local turn = token.currentTurn
	local timeline = turn and token.timelines and token.timelines[beeIndex]
	if not (turn and timeline) then
		-- Emerged but no farm yet: bob gently at the hive spawn.
		local settings = token.settings
		local bobAmplitude = tonumber(settings.bobAmplitude) or 0.5
		local bobPeriod = math.max(tonumber(settings.bobPeriod) or 1.6, 0.1)
		local bob = bobAmplitude * math.sin((2 * math.pi / bobPeriod) * now + beeIndex * 0.7)
		return spawnPositionFor(token, beeIndex) + Vector3.new(0, bob, 0)
	end

	local settings = token.settings
	local floorCFrame = turn.floorCFrame
	local function roamWorldAt(t)
		local localPosition = BeeEvent.Flight.SampleLocal(timeline, t, settings, beeIndex)
		local floorSize = turn.floorSize
		local surfaceY = typeof(floorSize) == "Vector3" and floorSize.Y / 2 or 0
		return floorCFrame:PointToWorldSpace(localPosition + Vector3.new(0, surfaceY, 0))
	end

	if now < turn.startsAt then
		-- Transit leg from the previous farm (or hive) at purposeful pace.
		local travelSeconds = math.max(tonumber(turn.travelSeconds) or 0, 0.1)
		local transitStartsAt = turn.startsAt - travelSeconds
		local stagger = (beeIndex - 1) * EMERGE_STAGGER_SECONDS
		local alpha = BeeEvent.Flight.EasedAlpha((now - transitStartsAt - stagger) / travelSeconds)
		local from = bee.transitFrom or turn.swarmFrom or bee.currentPosition
		return from:Lerp(roamWorldAt(turn.startsAt), alpha)
	end

	local roamWorld = roamWorldAt(now)

	-- Pollination override: this bee's assigned hover replaces the roam
	-- output during its window, with eased blends on both edges.
	for _, pollination in ipairs(turn.pollinations or {}) do
		if pollination.beeIndex == beeIndex and not pollination.cancelled then
			local machine = pollination.machine
			if typeof(machine) == "Instance" and machine.Parent == nil then
				-- Food destroyed/harvested mid-hover; resume roaming (the
				-- server independently skips the apply).
				pollination.cancelled = true
				break
			end
			local blendIn = pollination.hoverStartsAt - HOVER_BLEND_SECONDS
			local blendOut = pollination.hoverEndsAt + HOVER_BLEND_SECONDS
			if now >= blendIn and now <= blendOut then
				local orbit = BeeEvent.Flight.HoverPosition(
					pollination.targetPosition,
					now,
					pollination.hoverStartsAt,
					settings,
					beeIndex
				)
				if now < pollination.hoverStartsAt then
					local alpha = BeeEvent.Flight.EasedAlpha((now - blendIn) / HOVER_BLEND_SECONDS)
					return roamWorld:Lerp(orbit, alpha)
				elseif now <= pollination.hoverEndsAt then
					return orbit
				else
					local alpha = BeeEvent.Flight.EasedAlpha((now - pollination.hoverEndsAt) / HOVER_BLEND_SECONDS)
					return orbit:Lerp(roamWorld, alpha)
				end
			end
		end
	end

	return roamWorld
end

local function shortestAngle(delta)
	while delta > math.pi do
		delta -= math.pi * 2
	end
	while delta < -math.pi do
		delta += math.pi * 2
	end
	return delta
end

local function cameraPosition()
	local camera = Workspace.CurrentCamera
	return camera and camera.CFrame.Position or Vector3.zero
end

local function renderStep(deltaTime)
	local token = activeToken
	if not token then
		return
	end
	local now = serverNow()
	local settings = token.settings
	local flapHz = tonumber(settings.wingFlapHz) or 13
	local flapRadians = tonumber(settings.wingFlapRadians) or math.rad(55)
	local maxBank = tonumber(settings.maxBankRadians) or math.rad(35)
	local buzzMin = tonumber(settings.buzzMinSeconds) or 10
	local buzzMax = math.max(tonumber(settings.buzzMaxSeconds) or 30, buzzMin)
	local buzzRange = tonumber(settings.buzzSoundRange) or 70
	local flapAngle = flapRadians * math.sin(2 * math.pi * flapHz * now)
	local eyePosition = cameraPosition()

	for beeIndex, bee in ipairs(token.bees) do
		if bee.model.Parent then
			local targetPosition = targetPositionFor(token, beeIndex, bee, now)
			local velocity = targetPosition - bee.currentPosition
			local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
			local speed = deltaTime > 0 and horizontal.Magnitude / deltaTime or 0

			-- Presentation-only smoothing: yaw eases toward the travel
			-- direction, bank rolls into turns. Positions stay deterministic.
			local yawRate = 0
			if speed > MIN_MOVE_SPEED then
				local targetYaw = math.atan2(-horizontal.X, -horizontal.Z)
				local delta = shortestAngle(targetYaw - bee.yaw)
				local step = math.clamp(YAW_SMOOTH_PER_SECOND * deltaTime, 0, 1)
				bee.yaw += delta * step
				yawRate = delta * step / math.max(deltaTime, 1 / 240)
			end
			local targetBank = math.clamp(-yawRate * BANK_PER_YAW_RATE, -maxBank, maxBank)
			bee.bank += (targetBank - bee.bank) * math.clamp(BANK_SMOOTH_PER_SECOND * deltaTime, 0, 1)

			-- Bank rolls about the travel axis (yaw-frame Z) before the mesh
			-- forward correction, so the roll always leans into the turn.
			local pose = CFrame.new(targetPosition)
				* CFrame.Angles(0, bee.yaw, 0)
				* CFrame.Angles(0, 0, bee.bank)
				* MODEL_FORWARD_CORRECTION
			bee.model:PivotTo(pose)
			bee.currentPosition = targetPosition

			if (targetPosition - eyePosition).Magnitude <= WING_DETAIL_DISTANCE then
				for _, wing in ipairs(bee.wings) do
					wing.part:PivotTo(pose * wing.restPivot * CFrame.Angles(flapAngle * wing.sign, 0, 0))
				end
			end

			if now >= bee.nextBuzzAt then
				bee.nextBuzzAt = now + presentationRng:NextNumber(buzzMin, buzzMax)
				if bee.body then
					SoundEffects.Play(SoundEffects.Names.BeeBuzz, {
						parent = bee.body,
						range = buzzRange,
					})
				end
			end
		end
	end
end

local function handleSync(payload)
	if type(payload) ~= "table" then
		return
	end
	local token = ensureEvent(payload, { instant = true })
	if not token then
		return
	end
	if type(payload.currentTurn) == "table" then
		local localTurn = token.currentTurn
		if not localTurn or localTurn.startsAt ~= payload.currentTurn.startsAt then
			applyTurn(token, payload.currentTurn)
		end
	elseif payload.phase == "windDown" then
		if not token.returnState then
			handleWindDown(token, { endsAt = payload.endsAt })
		end
	end
end

local function onEffect(command, payload)
	if not hasOnboardingState() then
		if command ~= "pollinated" then
			pendingEffect = { command = command, payload = payload }
		end
		return
	end
	if not onboardingComplete() then
		pendingEffect = nil
		if activeToken then
			cleanupToken(activeToken)
		end
		return
	end
	if command == "start" then
		beginEvent(payload or {})
	elseif command == "plotTurn" then
		local token = ensureEvent(payload, { instant = true })
		if token then
			applyTurn(token, payload)
		end
	elseif command == "pollinated" then
		if activeToken and type(payload) == "table" then
			emitPollinationSparkle(payload.targetPosition)
		end
	elseif command == "plotLeave" then
		local token = activeToken
		if token and token.currentTurn and type(payload) == "table"
			and token.currentTurn.userId == payload.userId then
			cancelTurnPollinations(token)
		end
	elseif command == "windDown" then
		if activeToken then
			handleWindDown(activeToken, payload or {})
		end
	elseif command == "end" then
		if activeToken then
			cleanupToken(activeToken)
		end
	elseif command == "sync" then
		handleSync(payload or {})
	end
end

function BeeEventController.start()
	if started then
		return
	end
	started = true
	clearLocalFolder()
	RuntimeGuard.Connect(Remotes.get(Remotes.Names.BeeEventEffect).OnClientEvent, "BeeEventController.Effect", onEffect)
	RuntimeGuard.Connect(RunService.Heartbeat, "BeeEventController.Render", renderStep)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, function()
		if hasOnboardingState() and onboardingComplete() and pendingEffect then
			local effect = pendingEffect
			pendingEffect = nil
			onEffect(effect.command, effect.payload)
		elseif not onboardingComplete() and activeToken then
			pendingEffect = nil
			cleanupToken(activeToken)
		end
	end)
end

return BeeEventController
