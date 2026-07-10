-- Tsunami visuals are snapshot-driven like the wind event: there is no
-- dedicated remote. The controller polls ReplicatedStorage.GameEvents.Active
-- for a Tsunami record and renders everything locally off server time -- the
-- wave's position is a pure function of (now - startsAt), using the same
-- template geometry the server evaluates for hit detection, so both sides
-- agree on when the touch slab envelops the local character. Contact starts
-- the local two-minute underwater phase (lighting preset, underwater reverb,
-- impact + drone audio, bubbles VFX); the server independently applies the
-- Aqua mutations.
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
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local EventLighting = require(script.Parent:WaitForChild("EventLighting"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local TsunamiController = {}

-- Lighting is claimed through EventLighting with the event's configured
-- priority, so higher-priority concurrent events (Alien) keep the sky.
local TSUNAMI_LIGHTING_PRIORITY = tonumber((GameEvents.GetEvent(GameEvents.Ids.Tsunami) or {}).priority) or 0

local LOCAL_FOLDER_NAME = "__LocalTsunami"
local SIREN_TRACK = { soundId = "rbxassetid://792323017", volume = 0.15 }
local IMPACT_SOUND = { soundId = "rbxassetid://83673781452193", volume = 0.525 }
local DRONE_TRACK = { soundId = "rbxassetid://94473522240855", volume = 0.375, fadeSeconds = 1 }
local SIREN_STOP_SECONDS = 0.5
local IMPACT_MAX_LIFETIME = 15
local VFX_LINGER_SECONDS = 4
local REFRESH_SECONDS = 0.25
local RUNTIME_WAIT_SECONDS = 15
local WAIT_SECONDS = 10

local player = Players.LocalPlayer
local started = false
local activeToken = nil
local runtimeFolder = nil
local activeFolder = nil
local warnedMissingRuntime = false
local runtimeWarnAt = nil

local function warnTsunami(message)
	warn("[TsunamiController] " .. message)
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function numberValue(value, fallback)
	value = tonumber(value)
	if value == nil then
		return fallback
	end
	return value
end

local function resolveRuntime()
	if activeFolder and activeFolder.Parent then
		return activeFolder
	end

	runtimeFolder = ReplicatedStorage:FindFirstChild(GameEvents.RuntimeFolderName)
	activeFolder = runtimeFolder and runtimeFolder:FindFirstChild(GameEvents.ActiveFolderName)
	if not activeFolder and not warnedMissingRuntime then
		runtimeWarnAt = runtimeWarnAt or (os.clock() + RUNTIME_WAIT_SECONDS)
		if os.clock() >= runtimeWarnAt then
			warnedMissingRuntime = true
			warnTsunami("Missing ReplicatedStorage." .. GameEvents.RuntimeFolderName .. "." .. GameEvents.ActiveFolderName .. "; tsunami visuals disabled")
		end
	elseif activeFolder then
		runtimeWarnAt = nil
	end
	return activeFolder
end

local function onboardingComplete()
	local state = PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding)
	return type(state) == "table" and not Onboarding.IsActive(Onboarding.SanitizeState(state, Onboarding.CompleteState()).Stage)
end

local function activeTsunamiRecord()
	local folder = resolveRuntime()
	if not folder then
		return nil
	end
	local now = serverNow()
	for _, child in ipairs(folder:GetChildren()) do
		if child:GetAttribute(State.GameEvent.EventId) == GameEvents.Ids.Tsunami then
			local startsAt = tonumber(child:GetAttribute(State.GameEvent.StartsAt))
			local endsAt = tonumber(child:GetAttribute(State.GameEvent.EndsAt))
			if startsAt and endsAt and now >= startsAt and now < endsAt then
				return {
					instanceId = child.Name,
					startsAt = startsAt,
					endsAt = endsAt,
				}
			end
		end
	end
	return nil
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

-- Fade helpers keep each part's authored transparency (the TouchPart and
-- TsunamiEnd markers are baked at 1), scaling toward fully hidden instead of
-- clobbering it.
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

local function assetsFolder(name)
	local assets = ReplicatedStorage:WaitForChild("Assets", WAIT_SECONDS)
	return assets and assets:WaitForChild(name, WAIT_SECONDS)
end

local function cloneWaveTemplate()
	local misc = assetsFolder("Misc")
	local template = misc and misc:FindFirstChild("Tsunami")
	if not template then
		warnTsunami("Missing ReplicatedStorage.Assets.Misc.Tsunami")
		return nil
	end
	local clone = template:Clone()
	prepareInstance(clone)
	clone.Parent = localFolder()
	return clone
end

local function cloneEventVfx()
	local vfx = assetsFolder("EventVFX")
	local template = vfx and vfx:FindFirstChild("TsunamiEvent")
	if not template then
		warnTsunami("Missing ReplicatedStorage.Assets.EventVFX.TsunamiEvent")
		return nil
	end
	local clone = template:Clone()
	prepareInstance(clone)
	clone.Parent = localFolder()
	return clone
end

local function timingsFor()
	local config = GameEvents.GetEvent(GameEvents.Ids.Tsunami) or {}
	local tsunami = type(config.tsunami) == "table" and config.tsunami or {}
	local windUpSeconds, _, windDownSeconds = GameEvents.TsunamiTimings(config)
	return {
		windUpSeconds = windUpSeconds,
		windDownSeconds = windDownSeconds,
		travelSeconds = GameEvents.TsunamiTravelSeconds(tsunami),
		studsPerSecond = math.max(numberValue(tsunami.studsPerSecond, 50), 1),
		underwaterSeconds = math.max(numberValue(tsunami.underwaterSeconds, 120), 0),
		underwaterGravity = math.max(numberValue(tsunami.underwaterGravity, 25), 0),
		entranceSinkStuds = math.max(numberValue(tsunami.entranceSinkStuds, 260), 0),
		lightingTweenInSeconds = math.max(numberValue(tsunami.lightingTweenInSeconds, 0.75), 0),
		lightingTweenOutSeconds = math.max(numberValue(tsunami.lightingTweenOutSeconds, 3), 0),
		geometry = GameEvents.TsunamiGeometry(),
	}
end

local function startLoopedTrack(token, name, track, fadeSeconds, targetVolume)
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = track.soundId
	sound.Volume = 0
	sound.Looped = true
	sound.Parent = SoundService
	sound:Play()
	targetVolume = targetVolume or track.volume
	fadeSeconds = math.max(tonumber(fadeSeconds) or 0, 0)
	if fadeSeconds <= 0 then
		sound.Volume = targetVolume
	else
		local tween = TweenService:Create(sound, TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
			Volume = targetVolume,
		})
		token.tweens[#token.tweens + 1] = tween
		tween:Play()
	end
	return sound
end

local function stopLoopedTrack(token, sound, seconds)
	if not (sound and sound.Parent) then
		return
	end
	seconds = math.max(tonumber(seconds) or 0, 0)
	if seconds <= 0 then
		sound:Stop()
		sound:Destroy()
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Volume = 0,
	})
	token.tweens[#token.tweens + 1] = tween
	tween.Completed:Connect(function()
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
	tween:Play()
end

local function stopSiren(token, seconds)
	local siren = token.siren
	if not siren then
		return
	end
	token.siren = nil
	stopLoopedTrack(token, siren, seconds)
end

local function stopDrone(token, seconds)
	local drone = token.drone
	if not drone then
		return
	end
	token.drone = nil
	stopLoopedTrack(token, drone, seconds)
end

-- Mirror of PlotTsunamiService.slabContains: the touch slab only exists while
-- the wave is traveling. A player the slab never touched (late join, behind
-- the wave, onboarding) still enters the underwater phase once the wave
-- reaches the end line and the map counts as flooded, matching the server.
local function slabContains(token, position, now)
	local timings = token.timings
	local geometry = timings.geometry
	local travelElapsed = now - token.startsAt - timings.windUpSeconds
	if travelElapsed <= 0 or travelElapsed >= timings.travelSeconds then
		return false
	end
	local slabZ = geometry.touchStartZ - timings.studsPerSecond * travelElapsed
	return math.abs(position.X - geometry.touchCenterX) <= geometry.touchSizeX / 2
		and math.abs(position.Y - geometry.touchCenterY) <= geometry.touchSizeY / 2
		and math.abs(position.Z - slabZ) <= geometry.touchSizeZ / 2
end

local function playImpactSound()
	local sound = Instance.new("Sound")
	sound.Name = "__TsunamiImpact"
	sound.SoundId = IMPACT_SOUND.soundId
	sound.Volume = IMPACT_SOUND.volume
	sound.Parent = SoundService
	sound.Ended:Connect(function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
	Debris:AddItem(sound, IMPACT_MAX_LIFETIME)
	sound:Play()
end

local function endUnderwater(token, seconds)
	local underwater = token.underwater
	if not underwater or underwater.ended then
		return
	end
	underwater.ended = true
	EventLighting.Release(GameEvents.Ids.Tsunami, seconds)
	if typeof(underwater.prevReverb) == "EnumItem" then
		SoundService.AmbientReverb = underwater.prevReverb
	end
	if type(underwater.prevGravity) == "number" then
		Workspace.Gravity = underwater.prevGravity
	end
	stopDrone(token, seconds)
	local vfx = underwater.vfx
	underwater.vfx = nil
	if vfx then
		for _, descendant in ipairs(vfx:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end
		Debris:AddItem(vfx, VFX_LINGER_SECONDS)
	end
end

-- durationSeconds defaults to the full underwater window (slab hits); flood
-- entries pass the time left until the global flood ends. playImpact is false
-- for flood entries -- the crash belongs to being struck, not to logging in
-- with the map already underwater.
local function beginUnderwater(token, durationSeconds, playImpact)
	if token.underwater then
		return
	end
	local timings = token.timings
	local underwater = {
		ended = false,
		endsAt = serverNow() + math.max(numberValue(durationSeconds, timings.underwaterSeconds), 0),
		prevReverb = SoundService.AmbientReverb,
		prevGravity = Workspace.Gravity,
		vfx = nil,
	}
	token.underwater = underwater
	stopSiren(token, SIREN_STOP_SECONDS)
	EventLighting.Claim(GameEvents.Ids.Tsunami, "Tsunami", TSUNAMI_LIGHTING_PRIORITY, timings.lightingTweenInSeconds)
	SoundService.AmbientReverb = Enum.ReverbType.UnderWater
	-- Client-side gravity only affects locally-simulated physics (the local
	-- character), so the floaty feel stays per-player like the rest of the phase.
	Workspace.Gravity = timings.underwaterGravity
	if playImpact ~= false then
		playImpactSound()
	end
	token.drone = startLoopedTrack(token, "__TsunamiDrone", DRONE_TRACK, DRONE_TRACK.fadeSeconds)
	underwater.vfx = cloneEventVfx()
end

local function updateTsunami(token)
	local now = serverNow()
	local elapsed = now - token.startsAt
	local timings = token.timings

	local wave = token.wave
	if wave and wave.Parent then
		local riseAlpha = timings.windUpSeconds > 0 and math.clamp(elapsed / timings.windUpSeconds, 0, 1) or 1
		local travelElapsed = math.clamp(elapsed - timings.windUpSeconds, 0, timings.travelSeconds)
		local sinkElapsed = elapsed - timings.windUpSeconds - timings.travelSeconds
		local sinkAlpha = 0
		if sinkElapsed > 0 then
			sinkAlpha = timings.windDownSeconds > 0 and math.clamp(sinkElapsed / timings.windDownSeconds, 0, 1) or 1
		end
		local yOffset = -(1 - riseAlpha) * timings.entranceSinkStuds - sinkAlpha * timings.entranceSinkStuds
		wave:PivotTo(token.authoredPivot * CFrame.new(0, yOffset, -timings.studsPerSecond * travelElapsed))
		applyVisibility(token.waveOriginals, math.min(riseAlpha, 1 - sinkAlpha))
		if sinkAlpha >= 1 then
			token.wave = nil
			token.waveOriginals = nil
			wave:Destroy()
			-- The wave is gone; anyone still hearing the siren was never hit.
			stopSiren(token, SIREN_STOP_SECONDS)
		end
	end

	if not token.hitDone then
		local sweepSeconds = timings.windUpSeconds + timings.travelSeconds
		if elapsed >= sweepSeconds then
			-- The wave reached the end line: the map is flooded, so anyone the
			-- slab never touched enters the phase now, clamped to the time left
			-- until the global flood ends.
			token.hitDone = true
			local remaining = sweepSeconds + timings.underwaterSeconds - elapsed
			if remaining > 0 then
				beginUnderwater(token, remaining, false)
			end
		else
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and slabContains(token, root.Position, now) then
				token.hitDone = true
				beginUnderwater(token)
			end
		end
	end

	local underwater = token.underwater
	if underwater and not underwater.ended and now >= underwater.endsAt then
		endUnderwater(token, timings.lightingTweenOutSeconds)
	end
end

local function cleanupToken(token)
	if not token then
		return
	end
	token.cancelled = true
	-- Cancel in-flight tweens before ending the phase so endUnderwater's own
	-- release tweens (lighting, VFX linger) aren't immediately killed; sounds
	-- hard-stop like the tornado's cleanup.
	for _, tween in ipairs(token.tweens) do
		tween:Cancel()
	end
	table.clear(token.tweens)
	stopSiren(token, 0)
	stopDrone(token, 0)
	endUnderwater(token, token.timings.lightingTweenOutSeconds)
	if token.wave then
		token.wave:Destroy()
		token.wave = nil
		token.waveOriginals = nil
	end
	if activeToken == token then
		activeToken = nil
	end
end

local function beginTsunami(record)
	if activeToken then
		cleanupToken(activeToken)
	end
	local timings = timingsFor()
	local token = {
		instanceId = record.instanceId,
		startsAt = record.startsAt,
		endsAt = record.endsAt,
		timings = timings,
		tweens = {},
		wave = nil,
		waveOriginals = nil,
		authoredPivot = nil,
		siren = nil,
		drone = nil,
		hitDone = false,
		underwater = nil,
		cancelled = false,
	}
	activeToken = token

	-- A token that starts after the wave has launched belongs to a late joiner
	-- (or a player whose onboarding just finished): skip the wave and siren
	-- entirely and drop straight into the underwater phase, clamped to the
	-- global flood end. This mirrors the server's veteran/newcomer split.
	local elapsed = serverNow() - record.startsAt
	if elapsed >= timings.windUpSeconds then
		token.hitDone = true
		local floodEndsElapsed = timings.windUpSeconds + timings.travelSeconds + timings.underwaterSeconds
		local duration = math.min(floodEndsElapsed - elapsed, timings.underwaterSeconds)
		if duration > 0 then
			beginUnderwater(token, duration, false)
		end
		return
	end
	local wave = cloneWaveTemplate()
	if wave then
		token.wave = wave
		token.authoredPivot = wave:GetPivot()
		token.waveOriginals = collectOriginalTransparencies(wave)
		applyVisibility(token.waveOriginals, 0)
		updateTsunami(token)
	end
	local fadeSeconds = math.max(timings.windUpSeconds - math.max(elapsed, 0), 0.25)
	token.siren = startLoopedTrack(token, "__TsunamiSiren", SIREN_TRACK, fadeSeconds)
end

local function refresh()
	if not onboardingComplete() then
		if activeToken then
			cleanupToken(activeToken)
		end
		return
	end

	local record = activeTsunamiRecord()
	if not record then
		if activeToken then
			cleanupToken(activeToken)
		end
		return
	end
	if activeToken and activeToken.instanceId == record.instanceId then
		return
	end
	beginTsunami(record)
end

function TsunamiController.start()
	if started then
		return
	end
	started = true
	clearLocalFolder()

	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, refresh)

	local refreshElapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "TsunamiController.Update", function(deltaTime)
		refreshElapsed += deltaTime
		if refreshElapsed >= REFRESH_SECONDS then
			refreshElapsed = 0
			refresh()
		end
		if activeToken then
			updateTsunami(activeToken)
		end
	end)
end

return TsunamiController
