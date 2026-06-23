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

local CloudController = require(script.Parent:WaitForChild("CloudController"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotScope = require(script.Parent:WaitForChild("PlotScope"))
local PlotWindLines = require(script.Parent:WaitForChild("PlotWindLines"))
local TreeMotionEffects = require(script.Parent:WaitForChild("TreeMotionEffects"))

local PlotWindController = {}

local WIND_SOUND_NAME = "Wind"
local WIND_DIRECTION = Vector3.new(-1, 0, 0)
local WIND_CLOUD_SPEED_MULTIPLIER = 15
local DEFAULT_CLOUD_UPDATE_HZ = 10
local WIND_CLOUD_UPDATE_HZ = 60
local REFRESH_SECONDS = 0.25
local WAIT_STEP = 0.1
local RUNTIME_WAIT_SECONDS = 15

local player = Players.LocalPlayer
local started = false
local scopedPlots = {}
local activeToken = nil
local runtimeFolder = nil
local activeFolder = nil
local warnedMissingRuntime = false
local runtimeWarnAt = nil

local function warnWind(message)
	warn("[PlotWindController] " .. message)
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
			warnWind("Missing ReplicatedStorage." .. GameEvents.RuntimeFolderName .. "." .. GameEvents.ActiveFolderName .. "; wind visuals disabled")
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

local function currentPlot()
	for plot in pairs(scopedPlots) do
		if plot:IsDescendantOf(Workspace) then
			return plot
		end
	end
	return nil
end

local function activeWindRecord()
	local folder = resolveRuntime()
	if not folder then
		return nil
	end
	local now = serverNow()
	for _, child in ipairs(folder:GetChildren()) do
		if child:GetAttribute(State.GameEvent.EventId) == GameEvents.Ids.Windy then
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

local function cancellableWait(token, seconds)
	local deadline = os.clock() + math.max(0, seconds)
	while not token.cancelled do
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			return true
		end
		task.wait(math.min(WAIT_STEP, remaining))
	end
	return false
end

local function isTree(instance)
	return instance:IsA("Model") and instance:GetAttribute(State.Feed.Class) == "Tree"
end

local function collectTrees(plot)
	local trees = {}
	for _, descendant in ipairs(plot:GetDescendants()) do
		if isTree(descendant) then
			trees[#trees + 1] = descendant
		end
	end
	return trees
end

local function tweenWindLineIntensity(windLines, alpha, tweenInfo, token)
	if not windLines then
		return
	end
	if tweenInfo.Time <= 0 then
		windLines:SetIntensity(alpha)
		return
	end
	local value = Instance.new("NumberValue")
	value.Value = windLines:GetIntensity()
	local connection = value.Changed:Connect(function(nextAlpha)
		if not token.cancelled then
			windLines:SetIntensity(nextAlpha)
		end
	end)
	local tween = TweenService:Create(value, tweenInfo, { Value = alpha })
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if not token.cancelled then
			windLines:SetIntensity(alpha)
		end
	end)
	token.tweens[#token.tweens + 1] = tween
	tween:Play()
end

local function tweenCloudSpeedMultiplier(multiplier, tweenInfo, token)
	if tweenInfo.Time <= 0 then
		CloudController.SetSpeedMultiplier(multiplier)
		return
	end

	local value = Instance.new("NumberValue")
	value.Value = CloudController.GetSpeedMultiplier()
	local connection = value.Changed:Connect(function(nextMultiplier)
		if not token.cancelled then
			CloudController.SetSpeedMultiplier(nextMultiplier)
		end
	end)
	local tween = TweenService:Create(value, tweenInfo, { Value = multiplier })
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if not token.cancelled then
			CloudController.SetSpeedMultiplier(multiplier)
		end
	end)
	token.tweens[#token.tweens + 1] = tween
	tween:Play()
end

local function tweenCloudUpdateHz(hz, tweenInfo, token)
	if tweenInfo.Time <= 0 then
		CloudController.SetUpdateHz(hz)
		return
	end

	local value = Instance.new("NumberValue")
	value.Value = CloudController.GetUpdateHz()
	local connection = value.Changed:Connect(function(nextHz)
		if not token.cancelled then
			CloudController.SetUpdateHz(nextHz)
		end
	end)
	local tween = TweenService:Create(value, tweenInfo, { Value = hz })
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if not token.cancelled then
			CloudController.SetUpdateHz(hz)
		end
	end)
	token.tweens[#token.tweens + 1] = tween
	tween:Play()
end

local function windSoundTemplate()
	local sounds = ReplicatedStorage:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(WIND_SOUND_NAME)
	if template and template:IsA("Sound") then
		return template
	end
	warnWind("Missing ReplicatedStorage.Sounds.Wind Sound; wind audio skipped")
	return nil
end

local function localSoundParent()
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	return playerGui or SoundService
end

local function createWindSound(token, initialVolume)
	local template = windSoundTemplate()
	if not template then
		return nil, 0
	end

	local sound = template:Clone()
	local targetVolume = ((tonumber(template.Volume) or 0.5) * 0.5)
	sound.Name = WIND_SOUND_NAME
	sound.Looped = true
	sound.Volume = math.clamp(tonumber(initialVolume) or 0, 0, targetVolume)
	sound.Parent = localSoundParent()
	sound:Play()
	token.sound = sound
	return sound, targetVolume
end

local function tweenSoundVolume(token, targetVolume, seconds, easingDirection)
	local sound = token.sound
	if not (sound and sound.Parent) then
		return
	end
	if seconds <= 0 then
		sound.Volume = targetVolume
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Quad, easingDirection), {
		Volume = targetVolume,
	})
	token.tweens[#token.tweens + 1] = tween
	tween.Completed:Connect(function()
		if targetVolume <= 0 and sound.Parent then
			sound:Destroy()
		end
		if targetVolume <= 0 and token.sound == sound then
			token.sound = nil
		end
	end)
	tween:Play()
end

local function cleanupToken(token)
	if not token then
		return
	end
	token.cancelled = true
	for _, tween in ipairs(token.tweens) do
		tween:Cancel()
	end
	if token.sound and token.sound.Parent then
		token.sound:Destroy()
	end
	if token.windLines then
		token.windLines:Stop()
		token.windLines = nil
	end
	CloudController.SetSpeedMultiplier(1)
	CloudController.SetUpdateHz(DEFAULT_CLOUD_UPDATE_HZ)
	for _, tree in ipairs(token.activeTrees) do
		TreeMotionEffects.ClearTree(tree)
	end
	if activeToken == token then
		activeToken = nil
	end
end

local function windPhase(startsAt)
	local config = GameEvents.GetEvent(GameEvents.Ids.Windy)
	local windUpSeconds, activeSeconds, windDownSeconds = GameEvents.WindTimings(config)
	local elapsed = math.max(serverNow() - startsAt, 0)
	local windUpEnd = windUpSeconds
	local activeEnd = windUpSeconds + activeSeconds
	if elapsed < windUpEnd then
		return "windUp", elapsed, windUpSeconds, activeSeconds, windDownSeconds
	end
	if elapsed < activeEnd then
		return "active", elapsed, windUpSeconds, activeSeconds, windDownSeconds
	end
	return "windDown", elapsed, windUpSeconds, activeSeconds, windDownSeconds
end

local function playSequence(plot, record)
	if activeToken then
		cleanupToken(activeToken)
	end

	local phase, elapsed, windUpSeconds, activeSeconds, windDownSeconds = windPhase(record.startsAt)
	local remaining = math.max(record.endsAt - serverNow(), 0)
	if remaining <= 0 then
		return
	end

	local token = {
		instanceId = record.instanceId,
		cancelled = false,
		tweens = {},
		activeTrees = {},
		windLines = nil,
		sound = nil,
	}
	activeToken = token

	task.spawn(function()
		token.windLines = PlotWindLines.Start(plot, {
			direction = WIND_DIRECTION,
		})
		if not token.windLines then
			warnWind(plot:GetFullName() .. " could not start plot wind lines")
		end
		token.activeTrees = collectTrees(plot)
		task.delay(remaining + 0.25, function()
			if activeToken == token then
				cleanupToken(token)
			end
		end)

		for _, tree in ipairs(token.activeTrees) do
			TreeMotionEffects.SwayTree(tree, remaining)
		end

		local sound, targetVolume = createWindSound(token, phase == "windUp" and 0 or nil)
		if phase == "windUp" then
			local remainingUp = math.max(windUpSeconds - elapsed, 0)
			tweenWindLineIntensity(token.windLines, 1, TweenInfo.new(remainingUp, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), token)
			tweenCloudSpeedMultiplier(WIND_CLOUD_SPEED_MULTIPLIER, TweenInfo.new(remainingUp, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), token)
			tweenCloudUpdateHz(WIND_CLOUD_UPDATE_HZ, TweenInfo.new(remainingUp, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), token)
			if sound then
				tweenSoundVolume(token, targetVolume, remainingUp, Enum.EasingDirection.Out)
			end
			if not cancellableWait(token, remainingUp) then
				return
			end
			elapsed = windUpSeconds
		else
			if token.windLines then
				token.windLines:SetIntensity(1)
			end
			CloudController.SetSpeedMultiplier(WIND_CLOUD_SPEED_MULTIPLIER)
			CloudController.SetUpdateHz(WIND_CLOUD_UPDATE_HZ)
			if sound then
				sound.Volume = targetVolume
			end
		end

		if phase ~= "windDown" then
			local activeRemaining = math.max((windUpSeconds + activeSeconds) - elapsed, 0)
			if not cancellableWait(token, activeRemaining) then
				return
			end
		end

		local downElapsed = math.max(serverNow() - record.startsAt - windUpSeconds - activeSeconds, 0)
		local remainingDown = math.max(windDownSeconds - downElapsed, 0)
		tweenWindLineIntensity(token.windLines, 0, TweenInfo.new(remainingDown, Enum.EasingStyle.Quad, Enum.EasingDirection.In), token)
		tweenCloudSpeedMultiplier(1, TweenInfo.new(remainingDown, Enum.EasingStyle.Quad, Enum.EasingDirection.In), token)
		tweenCloudUpdateHz(DEFAULT_CLOUD_UPDATE_HZ, TweenInfo.new(remainingDown, Enum.EasingStyle.Quad, Enum.EasingDirection.In), token)
		tweenSoundVolume(token, 0, remainingDown, Enum.EasingDirection.In)
		if not cancellableWait(token, remainingDown) then
			return
		end
		cleanupToken(token)
	end)
end

local function refreshWind()
	if not onboardingComplete() then
		if activeToken then
			cleanupToken(activeToken)
		end
		return
	end

	local record = activeWindRecord()
	local plot = currentPlot()
	if not record or not plot then
		if activeToken then
			cleanupToken(activeToken)
		end
		return
	end
	if activeToken and activeToken.instanceId == record.instanceId then
		return
	end
	playSequence(plot, record)
end

function PlotWindController.start()
	if started then
		return
	end
	started = true

	PlotScope.Bind({
		label = "PlotWindController",
		onPlotAdded = function(plot)
			scopedPlots[plot] = true
			refreshWind()
			return function()
				scopedPlots[plot] = nil
				if activeToken then
					cleanupToken(activeToken)
				end
			end
		end,
	})

	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, refreshWind)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "PlotWindController.Refresh", function(dt)
		elapsed += dt
		if elapsed < REFRESH_SECONDS then
			return
		end
		elapsed = 0
		refreshWind()
	end)
end

return PlotWindController
