local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlotScope = require(script.Parent:WaitForChild("PlotScope"))
local TreeMotionEffects = require(script.Parent:WaitForChild("TreeMotionEffects"))

local PlotWindController = {}

local HUD_NAME = "HUD"
local BUFFS_NAME = "Buffs"
local WIND_BUFF_NAME = "Wind"
local WIND_TIMER_NAME = "Timer"
local WIND_EFFECT_NAME = "WindEffect"
local WIND_SOUND_NAME = "Wind"
local DEFAULT_WIND_UP_SECONDS = 4
local DEFAULT_WIND_ACTIVE_SECONDS = 30
local DEFAULT_WIND_DOWN_SECONDS = 4
local WAIT_STEP = 0.1
local ASSET_WAIT_SECONDS = 10

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

local function directWindModels(plot)
	local matches = {}
	for _, child in ipairs(plot:GetChildren()) do
		if child.Name == WIND_EFFECT_NAME and child:IsA("Model") then
			matches[#matches + 1] = child
		end
	end
	return matches
end

local function waitForWindModel(plot, token)
	local deadline = os.clock() + ASSET_WAIT_SECONDS
	while not token.cancelled and plot:IsDescendantOf(Workspace) do
		local matches = directWindModels(plot)
		if #matches == 1 then
			return matches[1]
		elseif #matches > 1 then
			warnWind(string.format("%s has %d direct WindEffect models; plot wind skipped", plot:GetFullName(), #matches))
			return nil
		end
		if os.clock() >= deadline then
			break
		end
		task.wait(WAIT_STEP)
	end
	if not token.cancelled then
		warnWind(plot:GetFullName() .. " has no direct WindEffect model; plot wind skipped")
	end
	return nil
end

local function collectBeamRecords(windModel, shouldWarn)
	local records = {}
	for _, descendant in ipairs(windModel:GetDescendants()) do
		if descendant:IsA("Beam") then
			records[#records + 1] = {
				beam = descendant,
				enabled = false,
				transparency = descendant.Transparency,
			}
		end
	end
	if #records == 0 then
		if shouldWarn ~= false then
			warnWind(windModel:GetFullName() .. " has no Beam descendants; plot wind skipped")
		end
		return nil
	end
	return records
end

local function waitForBeamRecords(windModel, token)
	local deadline = os.clock() + ASSET_WAIT_SECONDS
	while not token.cancelled and windModel:IsDescendantOf(Workspace) do
		local records = collectBeamRecords(windModel, false)
		if records then
			return records
		end
		if os.clock() >= deadline then
			break
		end
		task.wait(WAIT_STEP)
	end
	if not token.cancelled then
		warnWind(windModel:GetFullName() .. " has no Beam descendants; plot wind skipped")
	end
	return nil
end

local function blendedTransparency(sequence, alpha)
	alpha = math.clamp(alpha, 0, 1)
	local keypoints = {}
	for index, keypoint in ipairs(sequence.Keypoints) do
		local value = 1 + ((keypoint.Value - 1) * alpha)
		local envelope = keypoint.Envelope * alpha
		keypoints[index] = NumberSequenceKeypoint.new(keypoint.Time, value, envelope)
	end
	return NumberSequence.new(keypoints)
end

local function applyBeamAlpha(records, alpha)
	for _, record in ipairs(records) do
		if record.beam.Parent then
			if alpha > 0 then
				record.beam.Enabled = true
				record.beam.Transparency = blendedTransparency(record.transparency, alpha)
			elseif alpha <= 0 then
				record.beam.Transparency = record.transparency
				record.beam.Enabled = record.enabled
			end
		end
	end
end

local function tweenBeamAlpha(records, alpha, tweenInfo, token)
	local value = Instance.new("NumberValue")
	value.Value = alpha == 0 and 1 or 0
	local connection = value.Changed:Connect(function(nextAlpha)
		if not token.cancelled then
			applyBeamAlpha(records, nextAlpha)
		end
	end)
	local tween = TweenService:Create(value, tweenInfo, { Value = alpha })
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if not token.cancelled then
			applyBeamAlpha(records, alpha)
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
	local targetVolume = ((tonumber(template.Volume) or 0.5) * 0.425)
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
	if token.beamRecords then
		applyBeamAlpha(token.beamRecords, 0)
	end
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
		beamRecords = nil,
		sound = nil,
		windEndsAt = os.clock() + windUpSeconds + activeSeconds + windDownSeconds,
	}
	activeToken = token
	startWindBuffCountdown(token)

	task.spawn(function()
		local windModel = waitForWindModel(plot, token)
		if not windModel then
			cleanupToken(token)
			return
		end
		local beamRecords = waitForBeamRecords(windModel, token)
		if not beamRecords then
			cleanupToken(token)
			return
		end
		token.beamRecords = beamRecords
		token.activeTrees = collectTrees(plot)
		task.delay(windUpSeconds + activeSeconds + windDownSeconds + 0.25, function()
			if activeToken == token then
				cleanupToken(token)
			end
		end)

		tweenBeamAlpha(beamRecords, 1, TweenInfo.new(windUpSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), token)
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

		tweenBeamAlpha(beamRecords, 0, TweenInfo.new(windDownSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), token)
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
