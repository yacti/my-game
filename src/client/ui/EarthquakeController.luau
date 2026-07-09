-- Earthquake visuals are snapshot-driven like the wind and tsunami events:
-- there is no dedicated remote. The controller polls
-- ReplicatedStorage.GameEvents.Active for an Earthquake record and renders a
-- camera rumble plus a looping rumble bed. The long active window plays as
-- pulsed tremor bursts with calm between: the burst schedule comes from
-- GameEvents.EarthquakePulses (deterministically seeded from startsAt, the
-- same schedule the server constrains mutation hits into) and gates both the
-- shake and the audio, with both fading in/out inside each burst window so
-- the calm gaps stay quiet. Everything is a pure function of (now - startsAt) -- so late
-- joiners resume mid-schedule with no tween bookkeeping. The shake is
-- strictly positional (Humanoid.CameraOffset, vertical-dominant); rotational
-- shake is what reads as nauseating. A dusty lighting preset and the authored
-- EarthquakeEvent dust VFX (played where it sits, no motion) persist across
-- the whole event rather than pulsing. The server independently applies the
-- Shaken mutations.
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local EventLighting = require(script.Parent:WaitForChild("EventLighting"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local EarthquakeController = {}

-- Lighting is claimed through EventLighting with the event's configured
-- priority, so higher-priority concurrent events (Alien) keep the sky.
local EARTHQUAKE_LIGHTING_PRIORITY = tonumber((GameEvents.GetEvent(GameEvents.Ids.Earthquake) or {}).priority) or 0

local LOCAL_FOLDER_NAME = "__LocalEarthquake"
local VFX_LINGER_SECONDS = 4
local LIGHTING_TWEEN_IN_MIN_SECONDS = 0.75
local WAIT_SECONDS = 10
local RUMBLE_TRACK = { soundId = "rbxassetid://9085909202", volume = 0.45 }
-- Peak offset ~0.23 studs, dominated by the vertical axis: reads as ground
-- rumble rather than head-sway.
local SHAKE_AMPLITUDE = Vector3.new(0.08, 0.2, 0.08)
-- Noise sample rates (~Hz). Below ~3 Hz the motion reads as seasick swaying;
-- above ~20 Hz it aliases at 60 fps.
local SHAKE_NOISE_RATES = Vector3.new(7.3, 11, 8.7)
local REFRESH_SECONDS = 0.25
local RUNTIME_WAIT_SECONDS = 15

local player = Players.LocalPlayer
local started = false
local activeToken = nil
local runtimeFolder = nil
local activeFolder = nil
local warnedMissingRuntime = false
local runtimeWarnAt = nil

local function warnEarthquake(message)
	warn("[EarthquakeController] " .. message)
end

local function serverNow()
	return Workspace:GetServerTimeNow()
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
			warnEarthquake("Missing ReplicatedStorage." .. GameEvents.RuntimeFolderName .. "." .. GameEvents.ActiveFolderName .. "; earthquake effects disabled")
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

local function activeEarthquakeRecord()
	local folder = resolveRuntime()
	if not folder then
		return nil
	end
	local now = serverNow()
	for _, child in ipairs(folder:GetChildren()) do
		if child:GetAttribute(State.GameEvent.EventId) == GameEvents.Ids.Earthquake then
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

local function timingsFor()
	local config = GameEvents.GetEvent(GameEvents.Ids.Earthquake) or {}
	local earthquake = type(config.earthquake) == "table" and config.earthquake or {}
	local windUpSeconds, activeSeconds, windDownSeconds = GameEvents.EarthquakeTimings(config)
	return {
		windUpSeconds = windUpSeconds,
		activeSeconds = activeSeconds,
		windDownSeconds = windDownSeconds,
		swellSeconds = tonumber(earthquake.swellSeconds) or 5,
		burstEaseSeconds = tonumber(earthquake.burstEaseSeconds) or 5,
	}
end

local function currentHumanoid()
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
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

local function cloneEventVfx()
	local assets = ReplicatedStorage:WaitForChild("Assets", WAIT_SECONDS)
	local vfx = assets and assets:WaitForChild("EventVFX", WAIT_SECONDS)
	local template = vfx and vfx:FindFirstChild("EarthquakeEvent")
	if not template then
		warnEarthquake("Missing ReplicatedStorage.Assets.EventVFX.EarthquakeEvent")
		return nil
	end
	local clone = template:Clone()
	prepareInstance(clone)
	clone.Parent = localFolder()
	return clone
end

-- Lighting and dust wind down together with the rumble; also the hard-cut
-- path when the record vanishes early.
local function endAmbience(token, seconds)
	if token.ambienceEnded then
		return
	end
	token.ambienceEnded = true
	EventLighting.Release(GameEvents.Ids.Earthquake, seconds)
	local vfx = token.vfx
	token.vfx = nil
	if vfx then
		for _, descendant in ipairs(vfx:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end
		Debris:AddItem(vfx, VFX_LINGER_SECONDS)
	end
end

-- Quadratic ramp over the wind-up, full strength through the active window,
-- quadratic fade over the wind-down. The fade completes exactly at the
-- record's endsAt, so the hard cleanup cut when the record vanishes is
-- inaudible and invisible.
local function rumbleIntensity(elapsed, timings)
	if elapsed < 0 then
		return 0
	end
	if elapsed < timings.windUpSeconds then
		local alpha = elapsed / math.max(timings.windUpSeconds, 0.01)
		return alpha * alpha
	end
	local sustainEnds = timings.windUpSeconds + timings.activeSeconds
	if elapsed < sustainEnds then
		return 1
	end
	local down = (elapsed - sustainEnds) / math.max(timings.windDownSeconds, 0.01)
	return math.clamp(1 - down, 0, 1) ^ 2
end

local function updateEarthquake(token)
	local elapsed = serverNow() - token.startsAt
	local intensity = rumbleIntensity(elapsed, token.timings)
	local shakeFactor, audioFactor = GameEvents.EarthquakePulseFactors(
		elapsed,
		token.pulses,
		token.timings.swellSeconds,
		token.timings.burstEaseSeconds
	)

	if not token.ambienceEnded and elapsed >= token.timings.windUpSeconds + token.timings.activeSeconds then
		endAmbience(token, token.timings.windDownSeconds)
	end

	local rumble = token.rumble
	if rumble and rumble.Parent then
		rumble.Volume = RUMBLE_TRACK.volume * intensity * audioFactor
	end

	local humanoid = token.humanoid
	if not (humanoid and humanoid.Parent) then
		return
	end
	local shake = intensity * shakeFactor
	if shake <= 0 then
		if token.offsetApplied then
			token.offsetApplied = false
			humanoid.CameraOffset = Vector3.zero
		end
		return
	end
	-- math.noise spans roughly [-0.5, 0.5]; the x2 normalizes to [-1, 1].
	local now = os.clock()
	token.offsetApplied = true
	humanoid.CameraOffset = Vector3.new(
		math.noise(now * SHAKE_NOISE_RATES.X, 17.3) * 2 * SHAKE_AMPLITUDE.X,
		math.noise(now * SHAKE_NOISE_RATES.Y, 91.7) * 2 * SHAKE_AMPLITUDE.Y,
		math.noise(now * SHAKE_NOISE_RATES.Z, 43.1) * 2 * SHAKE_AMPLITUDE.Z
	) * shake
end

local function cleanupToken(token)
	if not token then
		return
	end
	token.cancelled = true
	for _, connection in ipairs(token.connections) do
		connection:Disconnect()
	end
	table.clear(token.connections)
	endAmbience(token, token.timings.windDownSeconds)
	local rumble = token.rumble
	token.rumble = nil
	if rumble and rumble.Parent then
		rumble:Stop()
		rumble:Destroy()
	end
	-- Zero both the bound humanoid and the current one: a respawn between the
	-- last rebind and cleanup must not leave a stale offset behind.
	local bound = token.humanoid
	if bound and bound.Parent then
		bound.CameraOffset = Vector3.zero
	end
	local humanoid = currentHumanoid()
	if humanoid and humanoid ~= bound then
		humanoid.CameraOffset = Vector3.zero
	end
	if activeToken == token then
		activeToken = nil
	end
end

local function beginEarthquake(record)
	if activeToken then
		cleanupToken(activeToken)
	end
	local token = {
		instanceId = record.instanceId,
		startsAt = record.startsAt,
		endsAt = record.endsAt,
		timings = timingsFor(),
		pulses = GameEvents.EarthquakePulses(GameEvents.GetEvent(GameEvents.Ids.Earthquake), record.startsAt),
		connections = {},
		humanoid = currentHumanoid(),
		rumble = nil,
		vfx = nil,
		ambienceEnded = false,
		offsetApplied = false,
		cancelled = false,
	}
	activeToken = token

	-- Skip the ambience entirely when only the wind-down tail remains; the
	-- update loop would end it on the first frame anyway.
	local elapsed = serverNow() - record.startsAt
	if elapsed < token.timings.windUpSeconds + token.timings.activeSeconds then
		local tweenIn = math.max(token.timings.windUpSeconds - math.max(elapsed, 0), LIGHTING_TWEEN_IN_MIN_SECONDS)
		EventLighting.Claim(GameEvents.Ids.Earthquake, "Earthquake", EARTHQUAKE_LIGHTING_PRIORITY, tweenIn)
		token.vfx = cloneEventVfx()
	end

	-- Respawn mid-quake: rebind so the rumble resumes on the new humanoid.
	token.connections[#token.connections + 1] = RuntimeGuard.Connect(player.CharacterAdded, "EarthquakeController.CharacterAdded", function(character)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid and not token.cancelled then
			token.humanoid = humanoid
		end
	end)

	local rumble = Instance.new("Sound")
	rumble.Name = "__EarthquakeRumble"
	rumble.SoundId = RUMBLE_TRACK.soundId
	rumble.Volume = 0
	rumble.Looped = true
	rumble.Parent = SoundService
	rumble:Play()
	token.rumble = rumble

	updateEarthquake(token)
end

local function refresh()
	if not onboardingComplete() then
		if activeToken then
			cleanupToken(activeToken)
		end
		return
	end

	local record = activeEarthquakeRecord()
	if not record then
		if activeToken then
			cleanupToken(activeToken)
		end
		return
	end
	if activeToken and activeToken.instanceId == record.instanceId then
		return
	end
	beginEarthquake(record)
end

function EarthquakeController.start()
	if started then
		return
	end
	started = true
	clearLocalFolder()

	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, refresh)

	local refreshElapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "EarthquakeController.Update", function(deltaTime)
		refreshElapsed += deltaTime
		if refreshElapsed >= REFRESH_SECONDS then
			refreshElapsed = 0
			refresh()
		end
		if activeToken then
			updateEarthquake(activeToken)
		end
	end)
end

return EarthquakeController
