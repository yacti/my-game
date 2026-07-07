local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local EventLighting = require(script.Parent:WaitForChild("EventLighting"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local TornadoController = {}

-- Lighting is claimed through EventLighting with the event's configured
-- priority, so higher-priority concurrent events (Alien) keep the sky.
local TORNADO_LIGHTING_PRIORITY = tonumber((GameEvents.GetEvent(GameEvents.Ids.Tornado) or {}).priority) or 0

local LOCAL_FOLDER_NAME = "__LocalTornado"
local WIND_SOUND_NAME = "Wind"
local BACKING_TRACK_NAME = "__TornadoWindBackingTrack"
local FUNNEL_WIND_NAME = "__TornadoFunnelWind"
local BACKING_TRACK_VOLUME_SCALE = 0.5
local FUNNEL_WIND_VOLUME = 0.9
local DEFAULT_TORNADO_SOUND_RANGE = 500
local MUTATE_BURST_LIFETIME = 2
local WAIT_SECONDS = 10

local started = false
local activeToken = nil
local pendingEffect = nil

local function warnTornado(message)
	warn("[TornadoController] " .. message)
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

local function assetsFolder()
	local assets = ReplicatedStorage:WaitForChild("Assets", WAIT_SECONDS)
	return assets and assets:WaitForChild("Misc", WAIT_SECONDS)
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
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = false
	end
end

-- Fade helpers keep each part's authored transparency (the outer funnel mesh
-- is baked at 0.4), scaling toward fully hidden instead of clobbering it.
local function collectOriginalTransparencies(instance)
	local originals = {}
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			originals[descendant] = descendant.Transparency
		end
	end
	if instance:IsA("BasePart") then
		originals[instance] = instance.Transparency
	end
	return originals
end

local function applyVisibility(originals, visibility)
	visibility = math.clamp(visibility, 0, 1)
	for part, original in pairs(originals) do
		if part.Parent then
			part.Transparency = 1 - visibility * (1 - original)
		end
	end
end

local function tweenVisibility(token, originals, visibility, seconds)
	visibility = math.clamp(visibility, 0, 1)
	if seconds <= 0 then
		applyVisibility(originals, visibility)
		return
	end
	for part, original in pairs(originals) do
		if part.Parent then
			local tween = TweenService:Create(part, TweenInfo.new(seconds), {
				Transparency = 1 - visibility * (1 - original),
			})
			token.tweens[#token.tweens + 1] = tween
			tween:Play()
		end
	end
end

local function cloneMiscTemplate(name)
	local misc = assetsFolder()
	local template = misc and misc:FindFirstChild(name)
	if not template then
		warnTornado("Missing ReplicatedStorage.Assets.Misc." .. name)
		return nil
	end
	local clone = template:Clone()
	prepareInstance(clone)
	clone.Parent = localFolder()
	return clone
end

local function windSoundTemplate()
	local sounds = ReplicatedStorage:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(WIND_SOUND_NAME)
	if template and template:IsA("Sound") then
		return template
	end
	warnTornado("Missing ReplicatedStorage.Sounds.Wind Sound; tornado audio skipped")
	return nil
end

local function stopBackingTrack(token, seconds)
	local sound = token and token.backingTrack
	if not sound then
		return
	end
	if token.backingTween then
		token.backingTween:Cancel()
		token.backingTween = nil
	end
	seconds = math.max(tonumber(seconds) or 0, 0)
	if seconds <= 0 then
		sound:Stop()
		sound:Destroy()
		token.backingTrack = nil
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Volume = 0,
	})
	token.backingTween = tween
	token.tweens[#token.tweens + 1] = tween
	tween.Completed:Connect(function()
		if token.backingTrack == sound then
			token.backingTrack = nil
			token.backingTween = nil
		end
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
	tween:Play()
end

local function startBackingTrack(token, seconds)
	if token.backingTrack then
		return
	end
	local template = windSoundTemplate()
	if not template then
		return
	end
	local sound = template:Clone()
	sound.Name = BACKING_TRACK_NAME
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	token.backingTrack = sound
	sound:Play()

	local targetVolume = (tonumber(template.Volume) or 0.5) * BACKING_TRACK_VOLUME_SCALE
	seconds = math.max(tonumber(seconds) or 0, 0)
	if seconds <= 0 then
		sound.Volume = targetVolume
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Volume = targetVolume,
	})
	token.backingTween = tween
	token.tweens[#token.tweens + 1] = tween
	tween:Play()
end

local function ensureCloud(token)
	if token.cloud and token.cloud.Parent then
		return token.cloud
	end
	-- The cloud is a static backdrop: the clone keeps the authored world
	-- placement (parts are anchored by prepareInstance) and is never moved.
	local cloud = cloneMiscTemplate("TornadoCloud")
	if not cloud then
		return nil
	end
	token.cloud = cloud
	token.cloudOriginals = collectOriginalTransparencies(cloud)
	applyVisibility(token.cloudOriginals, 0)
	tweenVisibility(token, token.cloudOriginals, 1, math.max(tonumber(token.settings and token.settings.windUpSeconds) or 0.25, 0.25))
	return cloud
end

local function funnelCorePart(funnel)
	local core = nil
	for _, descendant in ipairs(funnel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if not core or descendant.Size.Magnitude < core.Size.Magnitude then
				core = descendant
			end
		end
	end
	return core
end

local function funnelVisibility(token, now)
	local turn = token.turn
	if not turn then
		return 0
	end
	local fadeSeconds = math.max(tonumber(token.settings and token.settings.funnelFadeSeconds) or 0.75, 0.05)
	local fadeIn = math.clamp((now - (turn.appearAt - fadeSeconds)) / fadeSeconds, 0, 1)
	local fadeOut = math.clamp((turn.endsAt - now) / fadeSeconds, 0, 1)
	return math.min(fadeIn, fadeOut)
end

local function updateFunnel(token, deltaTime)
	local funnel = token.funnel
	if not (funnel and funnel.Parent) then
		return
	end
	local now = serverNow()
	local visibility = funnelVisibility(token, now)
	applyVisibility(token.funnelOriginals, visibility)
	if token.funnelWind then
		token.funnelWind.Volume = FUNNEL_WIND_VOLUME * visibility
	end
	local turn = token.turn
	if not turn or visibility <= 0 then
		return
	end

	local spinSpeed = math.max(tonumber(token.settings and token.settings.spinRevolutionsPerSecond) or 1.5, 0)
	token.spinAngle = (token.spinAngle or 0) + deltaTime * 2 * math.pi * spinSpeed

	local waypointSeconds = math.max(tonumber(token.settings and token.settings.wanderWaypointSeconds) or 2.5, 0.1)
	local progress = math.max(now - turn.startsAt, 0) / waypointSeconds
	local index = math.clamp(math.floor(progress) + 1, 1, #turn.waypoints - 1)
	local alpha = math.clamp(progress - (index - 1), 0, 1)
	alpha = alpha * alpha * (3 - 2 * alpha)
	local offset = turn.waypoints[index]:Lerp(turn.waypoints[index + 1], alpha)
	local bboxCFrame = turn.floorCFrame
		* CFrame.new(offset.X, turn.floorSize.Y / 2 + token.funnelSize.Y / 2, offset.Y)
		* CFrame.Angles(0, token.spinAngle, 0)
	funnel:PivotTo(bboxCFrame * token.funnelPivotFromBbox)
end

local function ensureFunnel(token)
	if token.funnel and token.funnel.Parent then
		return token.funnel
	end
	local funnel = cloneMiscTemplate("Tornado")
	if not funnel then
		return nil
	end
	token.funnel = funnel
	token.funnelOriginals = collectOriginalTransparencies(funnel)
	applyVisibility(token.funnelOriginals, 0)
	token.spinAngle = 0

	local bboxCFrame, bboxSize = funnel:GetBoundingBox()
	token.funnelSize = bboxSize
	token.funnelPivotFromBbox = bboxCFrame:ToObjectSpace(funnel:GetPivot())

	local core = funnelCorePart(funnel)
	local windTemplate = windSoundTemplate()
	if core and windTemplate then
		local sound = windTemplate:Clone()
		sound.Name = FUNNEL_WIND_NAME
		sound.Looped = true
		sound.Volume = 0
		sound.RollOffMinDistance = 15
		sound.RollOffMaxDistance = tonumber(token.settings and token.settings.tornadoSoundRange) or DEFAULT_TORNADO_SOUND_RANGE
		sound.Parent = core
		sound:Play()
		token.funnelWind = sound
	end

	token.funnelConnection = RuntimeGuard.Connect(RunService.Heartbeat, "TornadoController.Funnel", function(deltaTime)
		updateFunnel(token, deltaTime)
	end)
	return funnel
end

local function buildTurn(token, floorCFrame, floorSize, wanderSeed, startsAt, endsAt)
	if typeof(floorCFrame) ~= "CFrame" or typeof(floorSize) ~= "Vector3" then
		return nil
	end
	startsAt = tonumber(startsAt)
	endsAt = tonumber(endsAt)
	if not (startsAt and endsAt) then
		return nil
	end
	if not (token.funnelSize) then
		return nil
	end
	local waypointSeconds = math.max(tonumber(token.settings and token.settings.wanderWaypointSeconds) or 2.5, 0.1)
	local touchdownSeconds = math.max(tonumber(token.settings and token.settings.funnelTouchdownSeconds) or 1, 0)
	local halfX = math.max(floorSize.X / 2 - token.funnelSize.X / 2, 0)
	local halfZ = math.max(floorSize.Z / 2 - token.funnelSize.Z / 2, 0)
	local wanderRng = Random.new(tonumber(wanderSeed) or 0)
	local waypoints = { Vector2.zero }
	local segments = math.max(math.ceil(math.max(endsAt - startsAt, 1) / waypointSeconds), 1)
	for index = 1, segments do
		waypoints[index + 1] = Vector2.new(wanderRng:NextNumber(-halfX, halfX), wanderRng:NextNumber(-halfZ, halfZ))
	end
	return {
		startsAt = startsAt,
		endsAt = endsAt,
		appearAt = startsAt + touchdownSeconds,
		floorCFrame = floorCFrame,
		floorSize = floorSize,
		waypoints = waypoints,
	}
end

local function cleanupToken(token)
	if not token then
		return
	end
	token.cancelled = true
	for _, tween in ipairs(token.tweens) do
		tween:Cancel()
	end
	stopBackingTrack(token, 0)
	if token.funnelConnection then
		token.funnelConnection:Disconnect()
		token.funnelConnection = nil
	end
	if token.funnelWind then
		token.funnelWind:Stop()
		token.funnelWind = nil
	end
	if token.funnel then
		token.funnel:Destroy()
		token.funnel = nil
	end
	if token.cloud then
		token.cloud:Destroy()
		token.cloud = nil
	end
	EventLighting.Release(GameEvents.Ids.Tornado, 0.35)
	if activeToken == token then
		activeToken = nil
	end
end

local function beginTornado(payload)
	if activeToken then
		cleanupToken(activeToken)
	end
	local token = {
		instanceId = payload and payload.instanceId,
		settings = payload and payload.settings or {},
		tweens = {},
		turn = nil,
		cancelled = false,
	}
	activeToken = token
	local windUpSeconds = tonumber(token.settings.windUpSeconds) or 0
	EventLighting.Claim(GameEvents.Ids.Tornado, "Tornado", TORNADO_LIGHTING_PRIORITY, windUpSeconds)
	startBackingTrack(token, windUpSeconds)
	ensureCloud(token)
	ensureFunnel(token)
end

local function ensureTornado(payload)
	if not activeToken or (payload and activeToken.instanceId ~= payload.instanceId) then
		beginTornado(payload or {})
	end
	return activeToken
end

local function handlePlotTurn(payload)
	local token = ensureTornado(payload)
	if not ensureFunnel(token) then
		return
	end
	local turn = buildTurn(token, payload.floorCFrame, payload.floorSize, payload.wanderSeed, payload.startsAt, payload.endsAt)
	if not turn then
		return
	end
	token.turn = turn
end

local function handleMutate(payload)
	if not activeToken or type(payload) ~= "table" then
		return
	end
	local targetPosition = payload.targetPosition
	if typeof(targetPosition) ~= "Vector3" then
		return
	end
	local template = Mutations.Template(payload.mutationId)
	if not template then
		return
	end
	local part = Instance.new("Part")
	part.Name = "__TornadoMutateBurst"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.Size = Vector3.new(0.25, 0.25, 0.25)
	part.Position = targetPosition
	part.Parent = localFolder()
	for _, descendant in ipairs(template:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			local emitter = descendant:Clone()
			emitter.Enabled = false
			emitter.Parent = part
			emitter:Emit(15)
		end
	end
	Debris:AddItem(part, MUTATE_BURST_LIFETIME)
end

local function handleWindDown(payload)
	if not activeToken then
		return
	end
	local endsAt = type(payload) == "table" and tonumber(payload.endsAt) or nil
	local seconds = math.max(endsAt and (endsAt - serverNow()) or 0, 0)
	EventLighting.Release(GameEvents.Ids.Tornado, seconds)
	stopBackingTrack(activeToken, seconds)
	local turn = activeToken.turn
	if turn then
		local fadeSeconds = math.max(tonumber(activeToken.settings and activeToken.settings.funnelFadeSeconds) or 0.75, 0.05)
		turn.endsAt = math.min(turn.endsAt, serverNow() + fadeSeconds)
	end
	if activeToken.cloudOriginals then
		tweenVisibility(activeToken, activeToken.cloudOriginals, 0, math.min(seconds, 1))
	end
end

local function handleSync(payload)
	if type(payload) ~= "table" then
		return
	end
	if payload.phase == "windDown" then
		ensureTornado(payload)
		handleWindDown(payload)
	elseif payload.phase == "plotTurn" then
		local token = ensureTornado(payload)
		if ensureFunnel(token) then
			local turn = buildTurn(
				token,
				payload.currentFloorCFrame,
				payload.currentFloorSize,
				payload.currentWanderSeed,
				payload.currentTurnStartsAt,
				payload.currentTurnEndsAt
			)
			if turn then
				token.turn = turn
			end
		end
	else
		ensureTornado(payload)
	end
end

local function onEffect(command, payload)
	if not hasOnboardingState() then
		if command ~= "mutate" then
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
		beginTornado(payload or {})
	elseif command == "plotTurn" then
		handlePlotTurn(payload or {})
	elseif command == "mutate" then
		handleMutate(payload or {})
	elseif command == "windDown" then
		handleWindDown(payload or {})
	elseif command == "end" then
		if activeToken then
			cleanupToken(activeToken)
		end
	elseif command == "sync" then
		handleSync(payload or {})
	end
end

function TornadoController.start()
	if started then
		return
	end
	started = true
	clearLocalFolder()
	RuntimeGuard.Connect(Remotes.get(Remotes.Names.TornadoEffect).OnClientEvent, "TornadoController.Effect", onEffect)
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

return TornadoController
