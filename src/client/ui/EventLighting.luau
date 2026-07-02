-- Arbitrates ReplicatedStorage.Lighting presets between concurrent events.
-- Events claim a preset with a priority (from GameEvents config); the highest
-- priority claim owns Lighting. Releasing a claim re-applies the next-best
-- remaining claim, or the Default preset when none remain -- so a storm
-- ending mid-alien no longer resets the alien's sky (and vice versa).
--
-- This module owns the preset machinery that previously lived duplicated in
-- ThunderstormController and AlienEventController.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local EventLighting = {}

local DEFAULT_PRESET_NAME = "Default"
local LIGHTING_CHILD_PROPERTIES = {
	Atmosphere = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" },
	BloomEffect = { "Intensity", "Size", "Threshold" },
	ColorCorrectionEffect = { "Brightness", "Contrast", "Saturation", "TintColor" },
	SunRaysEffect = { "Intensity" },
}

local claims = {}
local claimOrder = 0
local appliedPresetName = nil
local activeTweens = {}

local function trackTween(tween)
	activeTweens[#activeTweens + 1] = tween
	return tween
end

local function cancelActiveTweens()
	for _, tween in ipairs(activeTweens) do
		tween:Cancel()
	end
	table.clear(activeTweens)
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

local function tweenProperties(instance, source, properties, seconds)
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
		trackTween(TweenService:Create(instance, TweenInfo.new(math.max(seconds, 0), Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), tweenable)):Play()
	end
end

local function fadeOutLightingChild(child, seconds)
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
		trackTween(TweenService:Create(child, TweenInfo.new(math.max(seconds, 0), Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), tweenable)):Play()
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

local function applyLightingChildren(preset, seconds)
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
				tweenProperties(existing, child, LIGHTING_CHILD_PROPERTIES[child.ClassName], seconds)
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
				fadeOutLightingChild(child, seconds)
			end
		end
	end
end

local function tweenLightingTo(name, seconds)
	local preset = lightingPreset(name)
	if not preset then
		warn("[EventLighting] Missing ReplicatedStorage.Lighting." .. tostring(name))
		return
	end
	applyLightingChildren(preset, seconds)
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
		trackTween(TweenService:Create(Lighting, TweenInfo.new(math.max(seconds, 0), Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), tweenable)):Play()
	end
end

local function winningClaim()
	local best = nil
	for _, claim in pairs(claims) do
		if not best
			or claim.priority > best.priority
			or (claim.priority == best.priority and claim.order > best.order) then
			best = claim
		end
	end
	return best
end

local function reapply(seconds)
	local claim = winningClaim()
	local presetName = claim and claim.presetName or DEFAULT_PRESET_NAME
	if presetName == appliedPresetName then
		return
	end
	appliedPresetName = presetName
	cancelActiveTweens()
	tweenLightingTo(presetName, seconds)
end

-- Claim (or refresh) lighting for an owner. The highest-priority claim's
-- preset is applied; ties go to the most recent claim.
function EventLighting.Claim(ownerId, presetName, priority, seconds)
	if type(ownerId) ~= "string" or type(presetName) ~= "string" then
		return
	end
	claimOrder += 1
	claims[ownerId] = {
		presetName = presetName,
		priority = tonumber(priority) or 0,
		order = claimOrder,
	}
	reapply(tonumber(seconds) or 0)
end

-- Release an owner's claim. Lighting moves to the next-best claim, or the
-- Default preset when none remain. No-op (and no reset) when a higher
-- priority claim still owns the scene.
function EventLighting.Release(ownerId, seconds)
	if claims[ownerId] == nil then
		return
	end
	claims[ownerId] = nil
	reapply(tonumber(seconds) or 0)
end

return EventLighting
