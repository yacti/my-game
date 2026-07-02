local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local CloudController = require(script.Parent:WaitForChild("CloudController"))
local EventLighting = require(script.Parent:WaitForChild("EventLighting"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local AlienEventController = {}

-- Lighting is claimed through EventLighting with the event's configured
-- priority (Alien = 100), so a concurrent lower-priority storm ending cannot
-- reset the alien sky.
local ALIEN_LIGHTING_PRIORITY = tonumber((GameEvents.GetEvent(GameEvents.Ids.Alien) or {}).priority) or 0

local LOCAL_FOLDER_NAME = "__LocalAlienEvent"
local BACKING_TRACK_SOUND_ID = "rbxassetid://1841164614"
local BACKING_TRACK_VOLUME = 0.35
local ZAP_SOUND_ID = "rbxassetid://2674547670"
local DEFAULT_SOUND_RANGE = 500
local WAIT_SECONDS = 10
local LEVEL_SECONDS = 0.25
local PROP_ROTATION_RADIANS_PER_SECOND = math.rad(18)

local player = Players.LocalPlayer
local started = false
local activeToken = nil
local pendingEffect = nil

local function warnAlien(message)
	warn("[AlienEventController] " .. message)
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

local function assetsRoot()
	return ReplicatedStorage:WaitForChild("Assets", WAIT_SECONDS)
end

local function miscFolder()
	local assets = assetsRoot()
	return assets and assets:WaitForChild("Misc", WAIT_SECONDS)
end

local function alienVfxFolder()
	local assets = assetsRoot()
	local eventVfx = assets and assets:WaitForChild("EventVFX", WAIT_SECONDS)
	local alien = eventVfx and eventVfx:WaitForChild("AlienEvent", WAIT_SECONDS)
	return alien and alien:IsA("Folder") and alien or nil
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

local function pivotOf(instance)
	if instance:IsA("BasePart") then
		return instance.CFrame
	end
	if instance:IsA("Model") then
		return instance:GetPivot()
	end
	return CFrame.identity
end

local function setPivot(instance, cframe)
	if instance:IsA("BasePart") then
		instance.CFrame = cframe
	elseif instance:IsA("Model") then
		instance:PivotTo(cframe)
	end
end

local function trackTween(token, tween)
	if token and tween then
		token.tweens[#token.tweens + 1] = tween
	end
	return tween
end

local function rememberTransparency(token, part)
	if token.originalTransparency[part] == nil then
		token.originalTransparency[part] = part.Transparency
	end
	return token.originalTransparency[part]
end

local function isLight(instance)
	return instance:IsA("PointLight")
		or instance:IsA("SpotLight")
		or instance:IsA("SurfaceLight")
end

local function rememberLightState(token, light)
	local state = token.originalLightState[light]
	if not state then
		local hasRange, range = pcall(function()
			return light.Range
		end)
		state = {
			brightness = light.Brightness,
			range = hasRange and range or nil,
			enabled = light.Enabled,
		}
		token.originalLightState[light] = state
	end
	return state
end

local function eachLight(instance, callback)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if isLight(descendant) then
			callback(descendant)
		end
	end
	if isLight(instance) then
		callback(instance)
	end
end

local function isBeamLike(instance)
	return instance:IsA("Beam") or instance:IsA("Trail")
end

local function rememberBeamLikeState(token, beamLike)
	local state = token.originalBeamLikeState[beamLike]
	if not state then
		state = {
			transparency = beamLike.Transparency,
			enabled = beamLike.Enabled,
			progress = beamLike.Enabled and 1 or 0,
		}
		token.originalBeamLikeState[beamLike] = state
	end
	return state
end

local function eachBeamLike(instance, callback)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if isBeamLike(descendant) then
			callback(descendant)
		end
	end
	if isBeamLike(instance) then
		callback(instance)
	end
end

local function applyBeamLikeProgress(beamLike, original, progress)
	progress = math.clamp(tonumber(progress) or 0, 0, 1)
	local keypoints = table.create(#original.Keypoints)
	for index, keypoint in ipairs(original.Keypoints) do
		keypoints[index] = NumberSequenceKeypoint.new(
			keypoint.Time,
			1 + ((keypoint.Value - 1) * progress),
			keypoint.Envelope * progress
		)
	end
	beamLike.Transparency = NumberSequence.new(keypoints)
end

local function eachBasePart(instance, callback)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			callback(descendant)
		end
	end
	if instance:IsA("BasePart") then
		callback(instance)
	end
end

local function setInstanceHidden(token, instance, hidden, predicate)
	eachBasePart(instance, function(part)
		if not predicate or predicate(part) then
			local original = rememberTransparency(token, part)
			part.Transparency = hidden and 1 or original
		end
	end)
end

local function tweenInstanceHidden(token, instance, hidden, seconds, predicate)
	seconds = math.max(tonumber(seconds) or 0, 0)
	eachBasePart(instance, function(part)
		if not predicate or predicate(part) then
			local original = rememberTransparency(token, part)
			local target = hidden and 1 or original
			if seconds <= 0 then
				part.Transparency = target
			else
				trackTween(token, TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
					Transparency = target,
				})):Play()
			end
		end
	end)
end

local function tweenInstanceTransparency(token, instance, transparency, seconds)
	seconds = math.max(tonumber(seconds) or 0, 0)
	eachBasePart(instance, function(part)
		if seconds <= 0 then
			part.Transparency = transparency
		else
			trackTween(token, TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
				Transparency = transparency,
			})):Play()
		end
	end)
end

local function setLightsHidden(token, instance, hidden)
	eachLight(instance, function(light)
		local original = rememberLightState(token, light)
		if hidden then
			light.Brightness = 0
			if original.range then
				pcall(function()
					light.Range = 0
				end)
			end
			light.Enabled = false
		else
			light.Enabled = original.enabled
			light.Brightness = original.brightness
			if original.range then
				pcall(function()
					light.Range = original.range
				end)
			end
		end
	end)
end

local function tweenLightsHidden(token, instance, hidden, seconds)
	seconds = math.max(tonumber(seconds) or 0, 0)
	eachLight(instance, function(light)
		local original = rememberLightState(token, light)
		local tweenable = {
			Brightness = hidden and 0 or original.brightness,
		}
		if original.range then
			tweenable.Range = hidden and 0 or original.range
		end
		if not hidden then
			light.Enabled = original.enabled
		end
		if seconds <= 0 then
			for property, value in pairs(tweenable) do
				pcall(function()
					light[property] = value
				end)
			end
			if hidden then
				light.Enabled = false
			end
			return
		end
		local tween = trackTween(token, TweenService:Create(light, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), tweenable))
		tween.Completed:Connect(function()
			if hidden and light.Parent then
				light.Enabled = false
			end
		end)
		tween:Play()
	end)
end

local function setBeamLikesHidden(token, instance, hidden)
	eachBeamLike(instance, function(beamLike)
		local state = rememberBeamLikeState(token, beamLike)
		state.progress = hidden and 0 or 1
		beamLike.Enabled = not hidden
		applyBeamLikeProgress(beamLike, state.transparency, state.progress)
	end)
end

local function tweenBeamLikesHidden(token, instance, hidden, seconds)
	seconds = math.max(tonumber(seconds) or 0, 0)
	eachBeamLike(instance, function(beamLike)
		local state = rememberBeamLikeState(token, beamLike)
		local targetProgress = hidden and 0 or 1
		if not hidden then
			beamLike.Enabled = true
		end
		if seconds <= 0 then
			state.progress = targetProgress
			applyBeamLikeProgress(beamLike, state.transparency, state.progress)
			if hidden then
				beamLike.Enabled = false
			end
			return
		end

		local value = Instance.new("NumberValue")
		value.Value = state.progress
		local connection = value.Changed:Connect(function(nextProgress)
			if beamLike.Parent then
				state.progress = nextProgress
				applyBeamLikeProgress(beamLike, state.transparency, nextProgress)
			end
		end)
		local tween = trackTween(token, TweenService:Create(value, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
			Value = targetProgress,
		}))
		tween.Completed:Connect(function()
			connection:Disconnect()
			value:Destroy()
			state.progress = targetProgress
			if beamLike.Parent then
				applyBeamLikeProgress(beamLike, state.transparency, state.progress)
				if hidden then
					beamLike.Enabled = false
				end
			end
		end)
		tween:Play()
	end)
end

local function setEmittersEnabled(instance, enabled)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = enabled
		end
	end
end

local function setBeamZapping(token, beam, active, seconds)
	if not beam then
		return
	end
	if not active then
		setEmittersEnabled(beam, false)
	end
	tweenInstanceTransparency(token, beam, active and 0 or 1, seconds)
	tweenLightsHidden(token, beam, not active, seconds)
	tweenBeamLikesHidden(token, beam, not active, seconds)
end

local function emitBurst(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			local emitCount = tonumber(descendant:GetAttribute("EmitCount")) or 1
			local emitDelay = math.max(tonumber(descendant:GetAttribute("EmitDelay")) or 0, 0)
			if emitDelay > 0 then
				task.delay(emitDelay, function()
					if descendant.Parent then
						descendant:Emit(emitCount)
					end
				end)
			else
				descendant:Emit(emitCount)
			end
		end
	end
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
	local sound = Instance.new("Sound")
	sound.Name = "__AlienBackingTrack"
	sound.SoundId = BACKING_TRACK_SOUND_ID
	sound.Volume = 0
	sound.Looped = true
	sound.Parent = SoundService
	token.backingTrack = sound
	sound:Play()

	seconds = math.max(tonumber(seconds) or 0, 0)
	if seconds <= 0 then
		sound.Volume = BACKING_TRACK_VOLUME
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Volume = BACKING_TRACK_VOLUME,
	})
	token.backingTween = tween
	token.tweens[#token.tweens + 1] = tween
	tween:Play()
end

local function cloneMiscTemplate(name)
	local misc = miscFolder()
	local template = misc and misc:FindFirstChild(name)
	if not template then
		warnAlien("Missing ReplicatedStorage.Assets.Misc." .. name)
		return nil
	end
	local clone = template:Clone()
	prepareInstance(clone)
	return clone
end

local function bodyPredicate(beam)
	return function(part)
		return not (beam and (part == beam or part:IsDescendantOf(beam)))
	end
end

local function cloneUfo(token, origin)
	local ufo = cloneMiscTemplate("UFOEvent")
	if not ufo then
		return
	end
	token.ufo = ufo
	local beam = ufo:FindFirstChild("Beam", true)
	if beam and beam:IsA("BasePart") then
		token.ufoBeam = beam
	end
	local pivot = pivotOf(ufo)
	token.ufoHeight = pivot.Position.Y
	token.ufoRotation = pivot - pivot.Position
	local start = origin or Vector3.zero
	local position = Vector3.new(start.X, token.ufoHeight, start.Z)
	setPivot(ufo, CFrame.new(position) * token.ufoRotation)
	setInstanceHidden(token, ufo, true)
	ufo.Parent = localFolder()
	if token.ufoBeam then
		setBeamZapping(token, token.ufoBeam, false, 0)
	end
	tweenInstanceHidden(token, ufo, false, tonumber(token.settings.windUpSeconds) or 0, bodyPredicate(token.ufoBeam))
end

local function cloneAlienVfx(token)
	local template = alienVfxFolder()
	if not template then
		warnAlien("Missing ReplicatedStorage.Assets.EventVFX.AlienEvent")
		return
	end
	for _, child in ipairs(template:GetChildren()) do
		local clone = child:Clone()
		prepareInstance(clone)
		if child.Name == "AlienBeam" then
			token.alienBeams[#token.alienBeams + 1] = clone
			setInstanceHidden(token, clone, true)
			setLightsHidden(token, clone, true)
			setBeamLikesHidden(token, clone, true)
			setEmittersEnabled(clone, false)
			clone.Parent = localFolder()
			tweenInstanceHidden(token, clone, false, tonumber(token.settings.windUpSeconds) or 0)
			tweenLightsHidden(token, clone, false, tonumber(token.settings.windUpSeconds) or 0)
			tweenBeamLikesHidden(token, clone, false, tonumber(token.settings.windUpSeconds) or 0)
			task.delay(math.max(tonumber(token.settings.windUpSeconds) or 0, 0), function()
				if not token.cancelled and clone.Parent then
					setEmittersEnabled(clone, true)
				end
			end)
		elseif child.Name == "StarBlock" then
			token.starBlock = clone
			setInstanceHidden(token, clone, true)
			setEmittersEnabled(clone, false)
			clone.Parent = localFolder()
		elseif child.Name == "UFOProps" then
			token.ufoProps = clone
			token.ufoPropsBasePivot = pivotOf(clone)
			setInstanceHidden(token, clone, true)
			setEmittersEnabled(clone, false)
			clone.Parent = localFolder()
		else
			setInstanceHidden(token, clone, true)
			clone.Parent = localFolder()
			tweenInstanceHidden(token, clone, false, tonumber(token.settings.windUpSeconds) or 0)
		end
	end
end

local function startPropsRotation(token)
	if not token.ufoProps or token.propsConnection then
		return
	end
	token.propsRotation = token.propsRotation or 0
	token.propsConnection = RuntimeGuard.Connect(RunService.Heartbeat, "AlienEventController.PropsRotation", function(deltaTime)
		if token.cancelled or not token.ufoProps or not token.ufoProps.Parent then
			return
		end
		token.propsRotation += deltaTime * PROP_ROTATION_RADIANS_PER_SECOND
		setPivot(token.ufoProps, token.ufoPropsBasePivot * CFrame.Angles(0, token.propsRotation, 0))
	end)
end

local function revealAmbient(token, seconds)
	if not token or token.ambientRevealed then
		return
	end
	token.ambientRevealed = true
	seconds = math.max(tonumber(seconds) or 0.5, 0)
	if token.starBlock then
		setEmittersEnabled(token.starBlock, true)
		tweenInstanceHidden(token, token.starBlock, false, seconds)
	end
	if token.ufoProps then
		setEmittersEnabled(token.ufoProps, true)
		tweenInstanceHidden(token, token.ufoProps, false, seconds)
		startPropsRotation(token)
	end
end

local function ufoCFrame(token, position, direction, tilted)
	local rotation = token.ufoRotation or CFrame.identity
	local cframe = CFrame.new(position)
	if tilted and typeof(direction) == "Vector3" and direction.Magnitude > 0.1 then
		local flat = Vector3.new(direction.X, 0, direction.Z)
		if flat.Magnitude > 0.1 then
			local unit = flat.Unit
			local tilt = math.rad(tonumber(token.settings.ufoMaxTiltDegrees) or 15)
			cframe *= CFrame.Angles(unit.Z * tilt, 0, -unit.X * tilt)
		end
	end
	return cframe * rotation
end

local function moveUfoTo(token, targetPosition, seconds, tilted, levelAfter)
	if not (token and token.ufo and token.ufo.Parent and typeof(targetPosition) == "Vector3") then
		return
	end
	local current = pivotOf(token.ufo)
	local target = Vector3.new(targetPosition.X, token.ufoHeight or current.Position.Y, targetPosition.Z)
	local targetCFrame = ufoCFrame(token, target, target - current.Position, tilted)
	if token.ufoTween then
		token.ufoTween:Cancel()
		token.ufoTween = nil
	end
	seconds = math.max(tonumber(seconds) or 0, 0)
	if seconds <= 0 then
		setPivot(token.ufo, targetCFrame)
		if levelAfter then
			setPivot(token.ufo, ufoCFrame(token, target, nil, false))
		end
		return
	end
	local value = Instance.new("CFrameValue")
	value.Value = current
	local connection = value.Changed:Connect(function(nextCFrame)
		if token.cancelled or not token.ufo.Parent then
			return
		end
		setPivot(token.ufo, nextCFrame)
	end)
	local tween = trackTween(token, TweenService:Create(value, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Value = targetCFrame,
	}))
	token.ufoTween = tween
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if token.ufoTween == tween then
			token.ufoTween = nil
		end
		if levelAfter and not token.cancelled and token.ufo and token.ufo.Parent then
			moveUfoTo(token, target, LEVEL_SECONDS, false, false)
		end
	end)
	tween:Play()
end

local function soundParent(position)
	local part = Instance.new("Part")
	part.Name = "__AlienZapSoundSource"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
	part.Size = Vector3.new(0.25, 0.25, 0.25)
	part.Position = position
	part.Parent = localFolder()
	Debris:AddItem(part, 8)
	return part
end

local function playZapSound(position, range)
	local sound = Instance.new("Sound")
	sound.SoundId = ZAP_SOUND_ID
	sound.Volume = 0.85
	sound.RollOffMaxDistance = range or DEFAULT_SOUND_RANGE
	sound.RollOffMinDistance = 8
	sound.Parent = soundParent(position)
	sound:Play()
	Debris:AddItem(sound, 8)
end

local function runZap(token, payload)
	local targetPosition = payload and payload.targetPosition
	if typeof(targetPosition) ~= "Vector3" or not token.ufoBeam then
		return
	end
	token.zapSequence = (token.zapSequence or 0) + 1
	local zapSequence = token.zapSequence
	local appearSeconds = math.max(tonumber(token.settings.zapAppearSeconds) or 0.25, 0)
	local fadeSeconds = math.max(tonumber(token.settings.zapFadeSeconds) or 1.2, 0)
	moveUfoTo(token, targetPosition, math.min(appearSeconds, 0.25), false, false)
	task.wait(math.min(appearSeconds, 0.25))
	if token.cancelled or token.zapSequence ~= zapSequence then
		return
	end
	setBeamZapping(token, token.ufoBeam, true, appearSeconds)
	task.wait(appearSeconds)
	if token.cancelled or token.zapSequence ~= zapSequence then
		return
	end
	tweenInstanceTransparency(token, token.ufoBeam, 0, 0)
	setEmittersEnabled(token.ufoBeam, true)
	emitBurst(token.ufoBeam)
	playZapSound(targetPosition, tonumber(payload.zapSoundRange) or tonumber(token.settings.zapSoundRange) or DEFAULT_SOUND_RANGE)
	task.wait(0.1)
	if token.cancelled or token.zapSequence ~= zapSequence then
		return
	end
	setEmittersEnabled(token.ufoBeam, false)
	setBeamZapping(token, token.ufoBeam, false, fadeSeconds)
	task.wait(fadeSeconds)
end

local function fadeOutToken(token, seconds)
	seconds = math.max(tonumber(seconds) or 0, 0)
	stopBackingTrack(token, seconds)
	CloudController.SetTransparencyOverride(nil, seconds)
	EventLighting.Release(GameEvents.Ids.Alien, seconds)
	for _, alienBeam in ipairs(token.alienBeams) do
		setEmittersEnabled(alienBeam, false)
		tweenInstanceHidden(token, alienBeam, true, seconds)
		tweenLightsHidden(token, alienBeam, true, seconds)
		tweenBeamLikesHidden(token, alienBeam, true, seconds)
	end
	if token.starBlock then
		setEmittersEnabled(token.starBlock, false)
		tweenInstanceHidden(token, token.starBlock, true, seconds)
	end
	if token.ufoProps then
		setEmittersEnabled(token.ufoProps, false)
		tweenInstanceHidden(token, token.ufoProps, true, seconds)
	end
	if token.ufo then
		tweenInstanceHidden(token, token.ufo, true, seconds, bodyPredicate(token.ufoBeam))
	end
	if token.ufoBeam then
		setBeamZapping(token, token.ufoBeam, false, math.min(seconds, 1.5))
	end
end

local function cleanupToken(token)
	if not token then
		return
	end
	token.cancelled = true
	for _, tween in ipairs(token.tweens) do
		tween:Cancel()
	end
	if token.propsConnection then
		token.propsConnection:Disconnect()
		token.propsConnection = nil
	end
	stopBackingTrack(token, 0)
	CloudController.SetTransparencyOverride(nil, 0.35)
	EventLighting.Release(GameEvents.Ids.Alien, 0.35)
	clearLocalFolder()
	if activeToken == token then
		activeToken = nil
	end
end

local function scheduleAmbientReveal(token)
	local windUpSeconds = math.max(tonumber(token.settings.windUpSeconds) or 0, 0)
	task.delay(windUpSeconds, function()
		if not token.cancelled then
			revealAmbient(token, 0.5)
		end
	end)
end

local function beginAlien(payload)
	if activeToken then
		cleanupToken(activeToken)
	end
	local token = {
		instanceId = payload and payload.instanceId,
		settings = payload and payload.settings or {},
		tweens = {},
		originalTransparency = {},
		originalLightState = {},
		originalBeamLikeState = {},
		alienBeams = {},
		cancelled = false,
		ambientRevealed = false,
		zapSequence = 0,
	}
	activeToken = token
	local origin = payload and payload.mapCenter or Vector3.zero
	local windUpSeconds = tonumber(token.settings.windUpSeconds) or 0
	EventLighting.Claim(GameEvents.Ids.Alien, "Alien", ALIEN_LIGHTING_PRIORITY, windUpSeconds)
	startBackingTrack(token, windUpSeconds)
	CloudController.SetTransparencyOverride(1, windUpSeconds)
	cloneAlienVfx(token)
	cloneUfo(token, origin)
	scheduleAmbientReveal(token)
end

local function ensureAlien(payload)
	if not activeToken or (payload and activeToken.instanceId ~= payload.instanceId) then
		beginAlien(payload or {})
	end
	return activeToken
end

local function handlePlotVisit(payload)
	local token = ensureAlien(payload)
	if type(payload) ~= "table" then
		return
	end
	revealAmbient(token, 0.5)
	if typeof(payload.plotCenter) ~= "Vector3" then
		return
	end
	local travelSeconds = tonumber(token.settings and token.settings.ufoTravelSeconds) or 4
	local seconds = math.min(math.max(travelSeconds, 0), math.max((tonumber(payload.endsAt) or serverNow()) - serverNow(), 0))
	moveUfoTo(token, payload.plotCenter, seconds, true, true)
end

local function handleZap(payload)
	if not activeToken or type(payload) ~= "table" then
		return
	end
	revealAmbient(activeToken, 0.5)
	task.spawn(runZap, activeToken, payload)
end

local function handleWindDown(payload)
	if not activeToken then
		return
	end
	local endsAt = type(payload) == "table" and tonumber(payload.endsAt) or nil
	local seconds = math.max(endsAt and (endsAt - serverNow()) or 0, 0)
	fadeOutToken(activeToken, seconds)
end

local function handleSync(payload)
	if type(payload) ~= "table" then
		return
	end
	if payload.phase == "windDown" then
		ensureAlien(payload)
		revealAmbient(activeToken, 0)
		handleWindDown(payload)
	elseif payload.phase == "plotVisit" then
		ensureAlien(payload)
		revealAmbient(activeToken, 0)
		if typeof(payload.currentPlotCenter) == "Vector3" then
			moveUfoTo(activeToken, payload.currentPlotCenter, 0, false, false)
		end
	else
		ensureAlien(payload)
	end
end

local function onEffect(command, payload)
	if not hasOnboardingState() then
		if command ~= "zap" then
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
		beginAlien(payload or {})
	elseif command == "plotVisit" then
		handlePlotVisit(payload or {})
	elseif command == "zap" then
		handleZap(payload or {})
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

function AlienEventController.start()
	if started then
		return
	end
	started = true
	clearLocalFolder()
	RuntimeGuard.Connect(Remotes.get(Remotes.Names.AlienEventEffect).OnClientEvent, "AlienEventController.Effect", onEffect)
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

return AlienEventController
