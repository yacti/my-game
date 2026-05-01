-- Client-only polish for Processor interactions.
-- Server owns deposits, queue state, and rewards; this module only renders a
-- local scale in/out effect after the server accepts a deposit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Food    = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local ProcessorVisuals = {}

local SCALE_IN_INFO  = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SCALE_OUT_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BOUNCE_UP_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BOUNCE_DOWN_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local START_SCALE    = 0.25
local PEAK_SCALE     = 0.85
local PROCESSOR_BOUNCE_SCALE = 1.08

local activeBounces = {}

local function partsOf(obj)
	if obj:IsA("BasePart") then return { obj } end
	local parts = {}
	for _, d in ipairs(obj:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

local function configureEffectPart(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

local function cloneFoodEffect(foodId)
	local template = Food.GetTemplate(foodId)
	if not template then return nil end

	local clone = template:Clone()
	for _, part in ipairs(partsOf(clone)) do
		configureEffectPart(part)
	end
	return clone
end

local function machinePivot(machine)
	if machine:IsA("BasePart") then return machine.CFrame end
	if machine:IsA("Model") then return machine:GetPivot() end
	return CFrame.identity
end

local function machineHeight(machine)
	if machine:IsA("BasePart") then return machine.Size.Y end
	if machine:IsA("Model") then return machine:GetExtentsSize().Y end
	return 2
end

local function effectHeight(effect)
	if effect:IsA("BasePart") then return effect.Size.Y end
	if effect:IsA("Model") then return effect:GetExtentsSize().Y end
	return 1
end

local function pivotEffect(effect, cframe)
	if effect:IsA("BasePart") then
		effect.CFrame = cframe
	elseif effect:IsA("Model") then
		effect:PivotTo(cframe)
	end
end

local function setTransparency(effect, transparency)
	for _, part in ipairs(partsOf(effect)) do
		part.Transparency = transparency
	end
end

local function tweenTransparency(effect, info, transparency)
	for _, part in ipairs(partsOf(effect)) do
		TweenService:Create(part, info, { Transparency = transparency }):Play()
	end
end

local function bouncePart(part)
	local baseSize = part.Size
	local baseCFrame = part.CFrame
	local upSize = baseSize * PROCESSOR_BOUNCE_SCALE
	local upCFrame = baseCFrame * CFrame.new(0, (upSize.Y - baseSize.Y) / 2, 0)

	local up = TweenService:Create(part, BOUNCE_UP_INFO, {
		Size = upSize,
		CFrame = upCFrame,
	})
	up.Completed:Connect(function()
		if not part.Parent then return end
		TweenService:Create(part, BOUNCE_DOWN_INFO, {
			Size = baseSize,
			CFrame = baseCFrame,
		}):Play()
	end)
	up:Play()
end

local function bounceModel(model)
	local previous = activeBounces[model]
	if previous then
		if previous.up then previous.up:Cancel() end
		if previous.down then previous.down:Cancel() end
		if previous.value then previous.value:Destroy() end
		if model.Parent then
			model:ScaleTo(previous.baseScale)
		end
	end

	local baseScale = model:GetScale()
	local value = Instance.new("NumberValue")
	value.Value = baseScale
	local record = {
		baseScale = baseScale,
		down = nil,
		up = nil,
		value = value,
	}
	activeBounces[model] = record

	value.Changed:Connect(function(nextScale)
		if model.Parent then
			model:ScaleTo(nextScale)
		end
	end)

	local up = TweenService:Create(value, BOUNCE_UP_INFO, {
		Value = baseScale * PROCESSOR_BOUNCE_SCALE,
	})
	record.up = up
	up.Completed:Connect(function()
		if activeBounces[model] ~= record or not model.Parent then
			value:Destroy()
			return
		end

		local down = TweenService:Create(value, BOUNCE_DOWN_INFO, {
			Value = baseScale,
		})
		record.down = down
		down.Completed:Connect(function()
			if activeBounces[model] == record then
				activeBounces[model] = nil
			end
			if model.Parent then
				model:ScaleTo(baseScale)
			end
			value:Destroy()
		end)
		down:Play()
	end)
	up:Play()
end

local function bounceProcessor(machine)
	if machine:IsA("BasePart") then
		bouncePart(machine)
	elseif machine:IsA("Model") then
		bounceModel(machine)
	end
end

local function renderPartEffect(effect)
	local targetSize = effect.Size
	effect.Size = targetSize * START_SCALE
	TweenService:Create(effect, SCALE_IN_INFO, { Size = targetSize * PEAK_SCALE }):Play()

	task.delay(SCALE_IN_INFO.Time, function()
		if not effect.Parent then return end
		TweenService:Create(effect, SCALE_OUT_INFO, { Size = targetSize * START_SCALE }):Play()
		tweenTransparency(effect, SCALE_OUT_INFO, 1)
	end)
end

local function renderModelEffect(effect)
	local scale = Instance.new("NumberValue")
	scale.Value = START_SCALE
	effect:ScaleTo(START_SCALE)

	scale.Changed:Connect(function(value)
		if effect.Parent then
			effect:ScaleTo(value)
		end
	end)

	local scaleIn = TweenService:Create(scale, SCALE_IN_INFO, { Value = PEAK_SCALE })
	scaleIn.Completed:Connect(function()
		if not effect.Parent then
			scale:Destroy()
			return
		end
		local scaleOut = TweenService:Create(scale, SCALE_OUT_INFO, { Value = START_SCALE })
		scaleOut.Completed:Connect(function()
			scale:Destroy()
		end)
		scaleOut:Play()
		tweenTransparency(effect, SCALE_OUT_INFO, 1)
	end)
	scaleIn:Play()
end

local function renderDeposit(machine, foodId)
	if not machine or not machine.Parent then return end

	bounceProcessor(machine)

	local effect = cloneFoodEffect(foodId)
	if not effect then return end

	setTransparency(effect, 0)
	local yOffset = (machineHeight(machine) + effectHeight(effect)) / 2 + 0.35
	pivotEffect(effect, machinePivot(machine) * CFrame.new(0, yOffset, 0))
	effect.Parent = Workspace

	if effect:IsA("BasePart") then
		renderPartEffect(effect)
	elseif effect:IsA("Model") then
		renderModelEffect(effect)
	end

	task.delay(SCALE_IN_INFO.Time + SCALE_OUT_INFO.Time + 0.05, function()
		if effect.Parent then
			effect:Destroy()
		end
	end)
end

function ProcessorVisuals.start()
	Remotes.get(Remotes.Names.ProcessorDepositEffect).OnClientEvent:Connect(renderDeposit)
end

return ProcessorVisuals
