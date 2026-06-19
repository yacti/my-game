local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local CloudController = require(script.Parent:WaitForChild("CloudController"))
local PlotScope = require(script.Parent:WaitForChild("PlotScope"))
local PlotWindLines = require(script.Parent:WaitForChild("PlotWindLines"))
local TreeMotionEffects = require(script.Parent:WaitForChild("TreeMotionEffects"))

local PlotWindController = {}

local HUD_NAME = "HUD"
local BUFFS_NAME = "Buffs"
local WIND_BUFF_NAME = "Wind"
local WIND_TIMER_NAME = "Timer"
local WIND_SOUND_NAME = "Wind"
local WIND_DIRECTION = Vector3.new(-1, 0, 0)
local WIND_CLOUD_SPEED_MULTIPLIER = 15
local DEFAULT_CLOUD_UPDATE_HZ = 10
local WIND_CLOUD_UPDATE_HZ = 60
local DEFAULT_WIND_UP_SECONDS = 4
local DEFAULT_WIND_ACTIVE_SECONDS = 30
local DEFAULT_WIND_DOWN_SECONDS = 4
local WAIT_STEP = 0.1

local PlotWindEffect = Remotes.get(Remotes.Names.PlotWindEffect)

local player = Players.LocalPlayer
local started = false
local scopedPlots = {}
local activeToken = nil
local windBuffRecord = nil
local warnedMissingWindBuff = false

local function warnWind(message)
	warn("[PlotWindController] " .. message)
end

local function resolveWindBuff(shouldWarn)
	if windBuffRecord
		and windBuffRecord.root.Parent
		and windBuffRecord.timer.Parent then
		return windBuffRecord
	end

	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	local hud = playerGui and playerGui:FindFirstChild(HUD_NAME)
	local buffs = hud and hud:FindFirstChild(BUFFS_NAME)
	local windBuff = buffs and buffs:FindFirstChild(WIND_BUFF_NAME)
	local timer = windBuff and windBuff:FindFirstChild(WIND_TIMER_NAME)
	if windBuff and windBuff:IsA("GuiObject") and timer and timer:IsA("TextLabel") then
		windBuffRecord = {
			root = windBuff,
			timer = timer,
		}
		return windBuffRecord
	end

	windBuffRecord = nil
	if shouldWarn and not warnedMissingWindBuff then
		warnedMissingWindBuff = true
		warnWind("Missing PlayerGui.HUD.Buffs.Wind.Timer TextLabel; wind buff UI skipped")
	end
	return nil
end

local function setWindBuffVisible(visible, remainingSeconds)
	local record = resolveWindBuff(visible)
	if not record then
		return
	end
	record.root.Visible = visible
	if visible then
		local remaining = math.max(0, math.ceil(tonumber(remainingSeconds) or 0))
		record.timer.Text = tostring(remaining) .. "s"
	end
end

local function hideWindBuff()
	setWindBuffVisible(false, 0)
end

local function startWindBuffCountdown(token)
	task.spawn(function()
		while not token.cancelled do
			local remaining = (token.windEndsAt or os.clock()) - os.clock()
			if remaining <= 0 then
				break
			end
			setWindBuffVisible(true, remaining)
			task.wait(math.min(WAIT_STEP, remaining))
		end
	end)
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

local function playWindSound(token, windUpSeconds)
	local template = windSoundTemplate()
	if not template then
		return
	end

	local sound = template:Clone()
	local targetVolume = ((tonumber(template.Volume) or 0.5) * 0.5)
	sound.Name = WIND_SOUND_NAME
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = localSoundParent()
	sound:Play()
	token.sound = sound

	local fadeIn = TweenService:Create(sound, TweenInfo.new(windUpSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Volume = targetVolume,
	})
	token.tweens[#token.tweens + 1] = fadeIn
	fadeIn:Play()
end

local function fadeOutSound(token, windDownSeconds)
	local sound = token.sound
	if not (sound and sound.Parent) then
		return
	end
	local fadeOut = TweenService:Create(sound, TweenInfo.new(windDownSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Volume = 0,
	})
	token.tweens[#token.tweens + 1] = fadeOut
	fadeOut.Completed:Connect(function()
		if sound.Parent then
			sound:Destroy()
		end
		if token.sound == sound then
			token.sound = nil
		end
	end)
	fadeOut:Play()
	task.delay(windDownSeconds + 0.1, function()
		if token.sound == sound and sound.Parent then
			sound:Destroy()
			token.sound = nil
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
	if token.sound and token.sound.Parent then
		token.sound:Destroy()
	end
	hideWindBuff()
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

local function playSequence(plot, windUpSeconds, activeSeconds, windDownSeconds)
	if activeToken then
		cleanupToken(activeToken)
	end

	windUpSeconds = math.max(tonumber(windUpSeconds) or DEFAULT_WIND_UP_SECONDS, 0)
	activeSeconds = math.max(tonumber(activeSeconds) or DEFAULT_WIND_ACTIVE_SECONDS, 0)
	windDownSeconds = math.max(tonumber(windDownSeconds) or DEFAULT_WIND_DOWN_SECONDS, 0)
	local token = {
		cancelled = false,
		tweens = {},
		activeTrees = {},
		windLines = nil,
		sound = nil,
		windEndsAt = os.clock() + windUpSeconds + activeSeconds + windDownSeconds,
	}
	activeToken = token
	startWindBuffCountdown(token)

	task.spawn(function()
		token.windLines = PlotWindLines.Start(plot, {
			direction = WIND_DIRECTION,
		})
		if not token.windLines then
			warnWind(plot:GetFullName() .. " could not start plot wind lines")
		end
		token.activeTrees = collectTrees(plot)
		task.delay(windUpSeconds + activeSeconds + windDownSeconds + 0.25, function()
			if activeToken == token then
				cleanupToken(token)
			end
		end)

		tweenWindLineIntensity(token.windLines, 1, TweenInfo.new(windUpSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), token)
		tweenCloudSpeedMultiplier(WIND_CLOUD_SPEED_MULTIPLIER, TweenInfo.new(windUpSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), token)
		tweenCloudUpdateHz(WIND_CLOUD_UPDATE_HZ, TweenInfo.new(windUpSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), token)
		playWindSound(token, windUpSeconds)
		for _, tree in ipairs(token.activeTrees) do
			TreeMotionEffects.SwayTree(tree, windUpSeconds + activeSeconds + windDownSeconds)
		end

		if not cancellableWait(token, windUpSeconds) then
			return
		end

		if not cancellableWait(token, activeSeconds) then
			return
		end

		tweenWindLineIntensity(token.windLines, 0, TweenInfo.new(windDownSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), token)
		tweenCloudSpeedMultiplier(1, TweenInfo.new(windDownSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), token)
		tweenCloudUpdateHz(DEFAULT_CLOUD_UPDATE_HZ, TweenInfo.new(windDownSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), token)
		fadeOutSound(token, windDownSeconds)
		if not cancellableWait(token, windDownSeconds) then
			return
		end
		cleanupToken(token)
	end)
end

local function onPlotWindEffect(payload)
	if type(payload) ~= "table" then
		return
	end
	local plot = payload.plot
	if typeof(plot) ~= "Instance" or not (plot:IsA("Model") or plot:IsA("Folder")) then
		return
	end
	if not scopedPlots[plot] then
		return
	end
	if not plot:IsDescendantOf(Workspace) then
		return
	end
	playSequence(plot, payload.windUp, payload.active, payload.windDown)
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
			return function()
				scopedPlots[plot] = nil
				if activeToken then
					cleanupToken(activeToken)
				end
			end
		end,
	})

	RuntimeGuard.Connect(PlotWindEffect.OnClientEvent, "PlotWindController.Event", onPlotWindEffect)
	task.defer(hideWindBuff)
end

return PlotWindController
