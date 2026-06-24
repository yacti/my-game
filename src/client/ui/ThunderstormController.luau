local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local ThunderstormController = {}

local LOCAL_FOLDER_NAME = "__LocalThunderstorm"
local RAIN_BACKING_TRACK_SOUND_ID = "rbxassetid://5911952995"
local RAIN_BACKING_TRACK_VOLUME = 0.35
local THUNDER_FALLBACK_SOUND_ID = "rbxassetid://93403424380357"
local DEFAULT_THUNDER_RANGE = 500
local MAX_ACTIVE_STRIKES = 12
local STRIKE_LIFETIME = 0.35
local WAIT_SECONDS = 10
local CLOUD_TRAVEL_SECONDS = 2

local LIGHTING_CHILD_PROPERTIES = {
	Atmosphere = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" },
	BloomEffect = { "Intensity", "Size", "Threshold" },
	ColorCorrectionEffect = { "Brightness", "Contrast", "Saturation", "TintColor" },
	SunRaysEffect = { "Intensity" },
}

local player = Players.LocalPlayer
local started = false
local activeToken = nil
local pendingEffect = nil
local activeStrikes = {}

local function warnStorm(message)
	warn("[ThunderstormController] " .. message)
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

local function setBasePartTransparency(instance, transparency)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = transparency
		end
	end
	if instance:IsA("BasePart") then
		instance.Transparency = transparency
	end
end

local function cloneMiscTemplate(name, options)
	local misc = assetsFolder()
	local template = misc and misc:FindFirstChild(name)
	if not template then
		warnStorm("Missing ReplicatedStorage.Assets.Misc." .. name)
		return nil
	end
	options = type(options) == "table" and options or {}
	local clone = template:Clone()
	prepareInstance(clone)
	if options.startHidden == true then
		setBasePartTransparency(clone, 1)
	end
	clone.Parent = localFolder()
	return clone
end

local function trackTween(token, tween)
	if token and tween then
		token.tweens[#token.tweens + 1] = tween
	end
	return tween
end

local function tweenBasePartTransparency(instance, transparency, seconds)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			TweenService:Create(descendant, TweenInfo.new(seconds), { Transparency = transparency }):Play()
		end
	end
	if instance:IsA("BasePart") then
		TweenService:Create(instance, TweenInfo.new(seconds), { Transparency = transparency }):Play()
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

local function lightingPreset(name)
	local lightingFolder = ReplicatedStorage:FindFirstChild("Lighting")
	local preset = lightingFolder and lightingFolder:FindFirstChild(name)
	return preset and preset:IsA("Folder") and preset or nil
end

local function lightingSettings(preset)
	local module = preset and preset:FindFirstChild("LightingSettings")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			return type(result.Lighting) == "table" and result.Lighting or {}
		end
	end
	return {}
end

local function isLightingChild(instance)
	return instance:IsA("Atmosphere")
		or instance:IsA("Sky")
		or instance:IsA("BloomEffect")
		or instance:IsA("ColorCorrectionEffect")
		or instance:IsA("SunRaysEffect")
end

local function lightingChildKey(instance)
	return instance.ClassName .. ":" .. instance.Name
end

local function tweenProperties(instance, source, properties, seconds, token)
	local tweenable = {}
	for _, property in ipairs(properties or {}) do
		local ok, value = pcall(function()
			return source[property]
		end)
		if ok and (typeof(value) == "Color3" or type(value) == "number") then
			tweenable[property] = value
		elseif ok then
			pcall(function()
				instance[property] = value
			end)
		end
	end
	if next(tweenable) then
		trackTween(token, TweenService:Create(instance, TweenInfo.new(math.max(seconds, 0), Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), tweenable)):Play()
	end
end

local function fadeOutLightingChild(child, seconds, token)
	local properties = LIGHTING_CHILD_PROPERTIES[child.ClassName]
	local tweenable = {}
	if child:IsA("SunRaysEffect") then
		tweenable.Intensity = 0
	elseif child:IsA("BloomEffect") then
		tweenable.Intensity = 0
	elseif child:IsA("Atmosphere") then
		tweenable.Density = 0
		tweenable.Haze = 0
		tweenable.Glare = 0
	elseif child:IsA("ColorCorrectionEffect") then
		tweenable.Brightness = 0
		tweenable.Contrast = 0
		tweenable.Saturation = 0
	end
	if next(tweenable) and properties then
		trackTween(token, TweenService:Create(child, TweenInfo.new(math.max(seconds, 0), Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), tweenable)):Play()
	end
	task.delay(math.max(seconds, 0), function()
		if child.Parent == Lighting then
			child:Destroy()
		end
	end)
end

local function copyTweenableProperties(destination, source)
	for _, property in ipairs(LIGHTING_CHILD_PROPERTIES[source.ClassName] or {}) do
		local ok, value = pcall(function()
			return source[property]
		end)
		if ok then
			pcall(function()
				destination[property] = value
			end)
		end
	end
end

local function applyLightingChildren(preset, seconds, token)
	local currentByKey = {}
	local currentByClass = {}
	for _, child in ipairs(Lighting:GetChildren()) do
		if isLightingChild(child) then
			currentByKey[lightingChildKey(child)] = child
			currentByClass[child.ClassName] = currentByClass[child.ClassName] or child
		end
	end
	local targetKeys = {}
	for _, child in ipairs(preset:GetChildren()) do
		if isLightingChild(child) then
			local key = lightingChildKey(child)
			targetKeys[key] = true
			if child:IsA("Sky") then
				local existing = currentByClass.Sky
				if existing then
					existing:Destroy()
				end
				child:Clone().Parent = Lighting
			else
				local existing = currentByKey[key]
				if not existing then
					existing = child:Clone()
					local sameClass = currentByClass[child.ClassName]
					if sameClass then
						copyTweenableProperties(existing, sameClass)
					end
					existing.Parent = Lighting
				end
				tweenProperties(existing, child, LIGHTING_CHILD_PROPERTIES[child.ClassName], seconds, token)
				pcall(function()
					existing.Enabled = child.Enabled
				end)
			end
		end
	end
	for key, child in pairs(currentByKey) do
		if not targetKeys[key] then
			if child:IsA("Sky") then
				child:Destroy()
			else
				fadeOutLightingChild(child, seconds, token)
			end
		end
	end
end

local function tweenLightingTo(name, seconds, token)
	local preset = lightingPreset(name)
	if not preset then
		warnStorm("Missing ReplicatedStorage.Lighting." .. name)
		return
	end
	applyLightingChildren(preset, seconds, token)
	local tweenable = {}
	for property, value in pairs(lightingSettings(preset)) do
		if typeof(value) == "Color3" or type(value) == "number" then
			tweenable[property] = value
		else
			pcall(function()
				Lighting[property] = value
			end)
		end
	end
	if next(tweenable) then
		trackTween(token, TweenService:Create(Lighting, TweenInfo.new(math.max(seconds, 0), Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), tweenable)):Play()
	end
end

local function playerPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function startRain(token, origin)
	if token.rain then
		return
	end
	local rain = cloneMiscTemplate("Rain")
	if not rain then
		return
	end
	token.rain = rain
	local height = tonumber(token.settings and token.settings.rainFollowHeight) or 30
	local initialPivot = pivotOf(rain)
	local rotation = initialPivot - initialPivot.Position
	local function update()
		local position = playerPosition() or origin or Vector3.zero
		setPivot(rain, CFrame.new(position + Vector3.new(0, height, 0)) * rotation)
	end
	update()
	token.rainConnection = RuntimeGuard.Connect(RunService.Heartbeat, "ThunderstormController.RainFollow", update)
end

local function stopRain(token)
	if token.rainConnection then
		token.rainConnection:Disconnect()
		token.rainConnection = nil
	end
	if token.rain then
		for _, descendant in ipairs(token.rain:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end
		Debris:AddItem(token.rain, 4)
		token.rain = nil
	end
end

local function stopRainBackingTrack(token, seconds)
	local sound = token and token.rainBackingTrack
	if not sound then
		return
	end
	if token.rainBackingTween then
		token.rainBackingTween:Cancel()
		token.rainBackingTween = nil
	end
	seconds = math.max(tonumber(seconds) or 0, 0)
	if seconds <= 0 then
		sound:Stop()
		sound:Destroy()
		token.rainBackingTrack = nil
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Volume = 0,
	})
	token.rainBackingTween = tween
	token.tweens[#token.tweens + 1] = tween
	tween.Completed:Connect(function()
		if token.rainBackingTrack == sound then
			token.rainBackingTrack = nil
			token.rainBackingTween = nil
		end
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
	tween:Play()
end

local function startRainBackingTrack(token, seconds)
	if token.rainBackingTrack then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "__ThunderstormRainBackingTrack"
	sound.SoundId = RAIN_BACKING_TRACK_SOUND_ID
	sound.Volume = 0
	sound.Looped = true
	sound.Parent = SoundService
	token.rainBackingTrack = sound
	sound:Play()

	seconds = math.max(tonumber(seconds) or 0, 0)
	if seconds <= 0 then
		sound.Volume = RAIN_BACKING_TRACK_VOLUME
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Volume = RAIN_BACKING_TRACK_VOLUME,
	})
	token.rainBackingTween = tween
	token.tweens[#token.tweens + 1] = tween
	tween:Play()
end

local function ensureCloud(token, origin)
	if token.cloud and token.cloud.Parent then
		return token.cloud
	end
	local cloud = cloneMiscTemplate("ThunderCloud", {
		startHidden = true,
	})
	if not cloud then
		return nil
	end
	token.cloud = cloud
	local pivot = pivotOf(cloud)
	token.cloudRotation = pivot - pivot.Position
	setPivot(cloud, CFrame.new(origin or Vector3.zero) * token.cloudRotation)
	tweenBasePartTransparency(cloud, 0.1, math.max(tonumber(token.settings and token.settings.windUpSeconds) or 0.25, 0.25))
	return cloud
end

local function moveCloud(token, origin, seconds)
	local cloud = ensureCloud(token, origin)
	if not cloud then
		return
	end
	local cframe = CFrame.new(origin) * token.cloudRotation
	if token.cloudTween then
		token.cloudTween:Cancel()
		token.cloudTween = nil
	end
	if seconds <= 0 then
		setPivot(cloud, cframe)
		return
	end
	if cloud:IsA("BasePart") then
		local tween = trackTween(token, TweenService:Create(cloud, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
			CFrame = cframe,
		}))
		token.cloudTween = tween
		tween:Play()
		return
	end
	local value = Instance.new("CFrameValue")
	value.Value = pivotOf(cloud)
	local connection = value.Changed:Connect(function(nextCFrame)
		if token.cancelled or not cloud.Parent then
			return
		end
		setPivot(cloud, nextCFrame)
	end)
	local tween = trackTween(token, TweenService:Create(value, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Value = cframe,
	}))
	token.cloudTween = tween
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if token.cloudTween == tween then
			token.cloudTween = nil
		end
	end)
	tween:Play()
end

local function thunderSoundParent(position)
	local part = Instance.new("Part")
	part.Name = "__ThunderSoundSource"
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

local function playThunder(position, range)
	local parent = thunderSoundParent(position)
	local sound = SoundEffects.Play(SoundEffects.Names.ThunderStrike, {
		parent = parent,
		range = range or DEFAULT_THUNDER_RANGE,
		rollOffMinDistance = 8,
	})
	if sound then
		return
	end
	sound = Instance.new("Sound")
	sound.SoundId = THUNDER_FALLBACK_SOUND_ID
	sound.Volume = 0.85
	sound.RollOffMaxDistance = range or DEFAULT_THUNDER_RANGE
	sound.RollOffMinDistance = 8
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 8)
end

local function removeOldestStrike()
	local oldest = table.remove(activeStrikes, 1)
	if oldest and oldest.Parent then
		oldest:Destroy()
	end
end

local function scaledLocalPosition(position, originalSize, newSize)
	return Vector3.new(
		originalSize.X ~= 0 and position.X * (newSize.X / originalSize.X) or position.X,
		originalSize.Y ~= 0 and position.Y * (newSize.Y / originalSize.Y) or position.Y,
		originalSize.Z ~= 0 and position.Z * (newSize.Z / originalSize.Z) or position.Z
	)
end

local function renderStrike(cloudOrigin, targetPosition)
	if typeof(cloudOrigin) ~= "Vector3" or typeof(targetPosition) ~= "Vector3" then
		return
	end
	while #activeStrikes >= MAX_ACTIVE_STRIKES do
		removeOldestStrike()
	end
	local strike = cloneMiscTemplate("LightningStrike")
	if not (strike and strike:IsA("BasePart")) then
		if strike then
			strike:Destroy()
		end
		return
	end
	local distance = (cloudOrigin - targetPosition).Magnitude
	if distance <= 0.1 then
		strike:Destroy()
		return
	end
	local originalSize = strike.Size
	local attachment = strike:FindFirstChild("StrikeAttachment")
	if attachment and attachment:IsA("Attachment") then
		local originalAttachmentPosition = attachment.Position
		strike.Size = Vector3.new(originalSize.X, originalSize.Y, distance)
		attachment.Position = scaledLocalPosition(originalAttachmentPosition, originalSize, strike.Size)
	else
		strike.Size = Vector3.new(originalSize.X, originalSize.Y, distance)
	end
	strike.CFrame = CFrame.lookAt(cloudOrigin:Lerp(targetPosition, 0.5), targetPosition)
	if attachment and attachment:IsA("Attachment") then
		strike.CFrame += targetPosition - attachment.WorldPosition
	end
	activeStrikes[#activeStrikes + 1] = strike
	tweenBasePartTransparency(strike, 1, STRIKE_LIFETIME)
	task.delay(STRIKE_LIFETIME, function()
		for index, instance in ipairs(activeStrikes) do
			if instance == strike then
				table.remove(activeStrikes, index)
				break
			end
		end
		if strike.Parent then
			strike:Destroy()
		end
	end)
end

local function cleanupToken(token)
	if not token then
		return
	end
	token.cancelled = true
	for _, tween in ipairs(token.tweens) do
		tween:Cancel()
	end
	stopRainBackingTrack(token, 0)
	stopRain(token)
	if token.cloud then
		token.cloud:Destroy()
	end
	for _, strike in ipairs(activeStrikes) do
		if strike.Parent then
			strike:Destroy()
		end
	end
	table.clear(activeStrikes)
	tweenLightingTo("Default", 0.35)
	if activeToken == token then
		activeToken = nil
	end
end

local function beginStorm(payload)
	if activeToken then
		cleanupToken(activeToken)
	end
	local token = {
		instanceId = payload and payload.instanceId,
		settings = payload and payload.settings or {},
		tweens = {},
		cancelled = false,
	}
	activeToken = token
	local origin = payload and payload.cloudOrigin or payload and payload.mapCenter
	local windUpSeconds = tonumber(token.settings.windUpSeconds) or 0
	tweenLightingTo("Storm", windUpSeconds, token)
	startRainBackingTrack(token, windUpSeconds)
	startRain(token, origin)
	ensureCloud(token, origin)
end

local function ensureStorm(payload)
	if not activeToken or (payload and activeToken.instanceId ~= payload.instanceId) then
		beginStorm(payload or {})
	end
	return activeToken
end

local function handlePlotTurn(payload)
	local token = ensureStorm(payload)
	local origin = payload and payload.cloudOrigin
	if typeof(origin) ~= "Vector3" then
		return
	end
	local travelSeconds = tonumber(token.settings and token.settings.cloudTravelSeconds) or CLOUD_TRAVEL_SECONDS
	local seconds = math.min(math.max(travelSeconds, 0), math.max((tonumber(payload.endsAt) or serverNow()) - serverNow(), 0))
	moveCloud(token, origin, seconds)
end

local function handleStrike(payload)
	if not activeToken or type(payload) ~= "table" then
		return
	end
	renderStrike(payload.cloudOrigin, payload.targetPosition)
	if typeof(payload.targetPosition) == "Vector3" then
		playThunder(payload.targetPosition, tonumber(payload.thunderSoundRange) or DEFAULT_THUNDER_RANGE)
	end
end

local function handleWindDown(payload)
	if not activeToken then
		return
	end
	local endsAt = type(payload) == "table" and tonumber(payload.endsAt) or nil
	local seconds = math.max(endsAt and (endsAt - serverNow()) or 0, 0)
	tweenLightingTo("Default", seconds, activeToken)
	stopRainBackingTrack(activeToken, seconds)
	stopRain(activeToken)
	if activeToken.cloud then
		tweenBasePartTransparency(activeToken.cloud, 1, math.min(seconds, 1))
	end
end

local function handleSync(payload)
	if type(payload) ~= "table" then
		return
	end
	if payload.phase == "windDown" then
		ensureStorm(payload)
		handleWindDown(payload)
	elseif payload.phase == "plotTurn" then
		ensureStorm(payload)
		if typeof(payload.currentCloudOrigin) == "Vector3" then
			moveCloud(activeToken, payload.currentCloudOrigin, 0)
		end
	else
		ensureStorm(payload)
	end
end

local function onEffect(command, payload)
	if not hasOnboardingState() then
		if command ~= "strike" then
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
		beginStorm(payload or {})
	elseif command == "plotTurn" then
		handlePlotTurn(payload or {})
	elseif command == "strike" then
		handleStrike(payload or {})
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

function ThunderstormController.start()
	if started then
		return
	end
	started = true
	clearLocalFolder()
	RuntimeGuard.Connect(Remotes.get(Remotes.Names.ThunderstormEffect).OnClientEvent, "ThunderstormController.Effect", onEffect)
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

return ThunderstormController
