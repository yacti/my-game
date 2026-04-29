-- Client-only polish for AppleTree visuals.
-- Server owns gameplay state; this module renders transient shake, drop,
-- slot respawn effects, and AppleTree ground XP billboards locally from
-- replicated attributes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Food    = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local AppleTreeSlotVisuals = {}

local RESPAWN_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DROP_TWEEN_INFO    = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local XP_COUNT_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local START_SCALE        = 0.35
local SHAKE_DURATION     = 0.25
local SHAKE_ANGLE        = math.rad(5)
local SHAKE_OFFSET       = 0.12
local BILLBOARD_RANGE    = 40
local GROUND_FOOD_RESCAN_DELAYS = { 0.25, 1, 3 }
local XP_TEXT_COLOR      = Color3.fromRGB(255, 255, 255)
local XP_GAIN_TEXT_COLOR = Color3.fromRGB(255, 236, 120)

local animated = {}
local billboards = {}
local pendingGroundFood = {}
local shakeIds = {}

local function isAppleTreeSlotFood(obj)
	local parent = obj.Parent
	if not parent or parent.Name ~= "SlotAnchor" then return false end
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end

	local tree = parent.Parent
	return tree ~= nil and tree:IsA("Model") and tree.Name == "AppleTree"
end

local function isAppleTreeGroundFood(obj)
	return (obj:IsA("BasePart") or obj:IsA("Model"))
		and obj:GetAttribute("SlotIndex") ~= nil
		and obj:GetAttribute("FoodType") ~= nil
end

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

local function tweenTransparency(parts)
	for _, part in ipairs(parts) do
		local targetTransparency = part.Transparency
		part.Transparency = 1
		TweenService:Create(part, RESPAWN_TWEEN_INFO, {
			Transparency = targetTransparency,
		}):Play()
	end
end

local function tweenPartGrow(part)
	local targetSize = part.Size
	local targetCFrame = part.CFrame
	part.Size = targetSize * START_SCALE
	part.CFrame = targetCFrame
	TweenService:Create(part, RESPAWN_TWEEN_INFO, {
		Size = targetSize,
		CFrame = targetCFrame,
	}):Play()
end

local function tweenModelGrow(model)
	if not model.PrimaryPart then return end

	local scale = Instance.new("NumberValue")
	scale.Value = START_SCALE
	model:ScaleTo(START_SCALE)

	scale.Changed:Connect(function(value)
		if model.Parent then
			model:ScaleTo(value)
		end
	end)

	local tween = TweenService:Create(scale, RESPAWN_TWEEN_INFO, { Value = 1 })
	tween.Completed:Connect(function()
		if model.Parent then
			model:ScaleTo(1)
		end
		scale:Destroy()
	end)
	tween:Play()
end

local function configureEffectPart(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

local function cloneFoodEffect(foodType)
	local template = Food.GetTemplate(foodType)
	if not template then return nil end

	local clone = template:Clone()
	if clone:IsA("BasePart") then
		configureEffectPart(clone)
	elseif clone:IsA("Model") then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then configureEffectPart(d) end
		end
	end
	return clone
end

local function effectHalfHeight(effect)
	if effect:IsA("BasePart") then return effect.Size.Y / 2 end
	if effect:IsA("Model") and effect.PrimaryPart then return effect.PrimaryPart.Size.Y / 2 end
	return 0
end

local function pivotEffect(effect, cframe)
	if effect:IsA("BasePart") then
		effect.CFrame = cframe
	elseif effect:IsA("Model") then
		effect:PivotTo(cframe)
	end
end

local function adorneeFor(food)
	if food:IsA("BasePart") then return food end
	if food:IsA("Model") then
		return food.PrimaryPart or food:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function maxXPFor(foodType)
	local template = Food.GetTemplate(foodType)
	return template and (template:GetAttribute("MaxXP") or 5) or 5
end

local function roundedXP(value)
	return math.floor((tonumber(value) or 0) + 0.5)
end

local function currentXPFor(food)
	return tonumber(food:GetAttribute("XP")) or 0
end

local function renderXPText(food, label, xpOverride)
	local xp = roundedXP(xpOverride or currentXPFor(food))
	local foodType = food:GetAttribute("FoodType")
	local maxXP = type(foodType) == "string" and maxXPFor(foodType) or 0
	label.Text = string.format("%d/%d xp", xp, maxXP)
end

local function stopXPCounter(record)
	if record.counterTween then
		record.counterTween:Cancel()
		record.counterTween = nil
	end
	if record.counterValue then
		record.counterValue:Destroy()
		record.counterValue = nil
	end
end

local function animateXPText(food, record)
	local targetXP = currentXPFor(food)
	local startXP = record.counterValue and record.counterValue.Value or record.displayedXP or targetXP
	stopXPCounter(record)

	if targetXP <= startXP then
		record.displayedXP = targetXP
		record.label.TextColor3 = XP_TEXT_COLOR
		renderXPText(food, record.label, targetXP)
		return
	end

	local value = Instance.new("NumberValue")
	value.Value = startXP
	record.counterValue = value
	record.label.TextColor3 = XP_GAIN_TEXT_COLOR

	value.Changed:Connect(function(nextValue)
		record.displayedXP = nextValue
		renderXPText(food, record.label, nextValue)
	end)

	local tween = TweenService:Create(value, XP_COUNT_TWEEN_INFO, { Value = targetXP })
	record.counterTween = tween
	tween.Completed:Connect(function()
		if record.counterValue ~= value then return end
		record.displayedXP = targetXP
		record.counterTween = nil
		record.counterValue = nil
		renderXPText(food, record.label, targetXP)
		value:Destroy()
		TweenService:Create(record.label, TweenInfo.new(0.15), {
			TextColor3 = XP_TEXT_COLOR,
		}):Play()
	end)
	tween:Play()
end

local function clearPendingGroundFood(food)
	local conns = pendingGroundFood[food]
	if not conns then return end
	for _, conn in ipairs(conns) do
		conn:Disconnect()
	end
	pendingGroundFood[food] = nil
end

local function attachXPBillboard(food)
	if billboards[food] then return true end

	local adornee = adorneeFor(food)
	if not adornee then return false end

	local gui = Instance.new("BillboardGui")
	gui.Name        = "XPBillboard"
	gui.Adornee     = adornee
	gui.Size        = UDim2.new(0, 80, 0, 24)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = BILLBOARD_RANGE

	local label = Instance.new("TextLabel")
	label.Size                   = UDim2.fromScale(1, 1)
	label.BackgroundColor3       = Color3.fromRGB(30, 30, 30)
	label.BackgroundTransparency = 0.2
	label.TextColor3             = XP_TEXT_COLOR
	label.Font                   = Enum.Font.GothamBold
	label.TextScaled             = true
	label.Parent                 = gui
	Instance.new("UICorner", label).CornerRadius = UDim.new(0, 6)

	local record = {
		gui = gui,
		conns = {},
		label = label,
		displayedXP = currentXPFor(food),
		counterTween = nil,
		counterValue = nil,
	}
	renderXPText(food, label, record.displayedXP)
	local conns = {}
	table.insert(conns, food:GetAttributeChangedSignal("XP"):Connect(function()
		animateXPText(food, record)
	end))
	table.insert(conns, food:GetAttributeChangedSignal("FoodType"):Connect(function()
		renderXPText(food, label, record.displayedXP)
	end))
	record.conns = conns

	gui.Parent = adornee
	billboards[food] = record

	table.insert(conns, food.AncestryChanged:Connect(function()
		if not food:IsDescendantOf(Workspace) then
			for _, conn in ipairs(conns) do
				conn:Disconnect()
			end
			stopXPCounter(record)
			clearPendingGroundFood(food)
			billboards[food] = nil
		end
	end))

	clearPendingGroundFood(food)
	return true
end

local function trackGroundFoodCandidate(obj)
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return end
	if isAppleTreeGroundFood(obj) and attachXPBillboard(obj) then return end
	if pendingGroundFood[obj] then return end

	local conns = {}
	local function tryAttach()
		if isAppleTreeGroundFood(obj) and attachXPBillboard(obj) then
			clearPendingGroundFood(obj)
		end
	end

	table.insert(conns, obj:GetAttributeChangedSignal("SlotIndex"):Connect(tryAttach))
	table.insert(conns, obj:GetAttributeChangedSignal("FoodType"):Connect(tryAttach))
	if obj:IsA("Model") then
		table.insert(conns, obj.DescendantAdded:Connect(function()
			tryAttach()
		end))
	end
	table.insert(conns, obj.AncestryChanged:Connect(function()
		if not obj:IsDescendantOf(Workspace) then
			clearPendingGroundFood(obj)
		end
	end))
	pendingGroundFood[obj] = conns

	task.defer(tryAttach)
	for _, delaySeconds in ipairs(GROUND_FOOD_RESCAN_DELAYS) do
		task.delay(delaySeconds, function()
			if pendingGroundFood[obj] and obj:IsDescendantOf(Workspace) then
				tryAttach()
			end
		end)
	end
end

local function scanGroundFoods()
	for _, obj in ipairs(Workspace:GetDescendants()) do
		if isAppleTreeGroundFood(obj) then
			trackGroundFoodCandidate(obj)
		end
	end
end

local function renderDrop(anchor, marker, foodType, duration)
	if not anchor or not anchor.Parent or not marker or not marker.Parent then return end

	local effect = cloneFoodEffect(foodType)
	if not effect then return end

	local startCFrame = anchor.CFrame
	local endCFrame = marker.CFrame * CFrame.new(0, effectHalfHeight(effect) - marker.Size.Y / 2, 0)
	pivotEffect(effect, startCFrame)
	effect.Parent = Workspace

	local cframeValue = Instance.new("CFrameValue")
	cframeValue.Value = startCFrame
	cframeValue.Changed:Connect(function(value)
		if effect.Parent then
			pivotEffect(effect, value)
		end
	end)

	local tweenInfo = duration and TweenInfo.new(duration, DROP_TWEEN_INFO.EasingStyle, DROP_TWEEN_INFO.EasingDirection) or DROP_TWEEN_INFO
	local tween = TweenService:Create(cframeValue, tweenInfo, { Value = endCFrame })
	tween.Completed:Connect(function()
		if effect.Parent then effect:Destroy() end
		cframeValue:Destroy()
	end)
	tween:Play()
end

local function targetCFrame(target)
	if target:IsA("BasePart") then return target.CFrame end
	if target:IsA("Model") then return target:GetPivot() end
	return CFrame.identity
end

local function applyTargetCFrame(target, cframe)
	if target:IsA("BasePart") then
		target.CFrame = cframe
	elseif target:IsA("Model") then
		target:PivotTo(cframe)
	end
end

local function collectShakeTargets(tree)
	local targets = {}
	for _, d in ipairs(tree:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Leaf" then
			table.insert(targets, {
				instance = d,
				baseCFrame = d.CFrame,
				phase = math.random() * math.pi * 2,
			})
		end
	end
	for _, anchor in ipairs(tree:GetChildren()) do
		if anchor.Name == "SlotAnchor" then
			for _, child in ipairs(anchor:GetChildren()) do
				if child:IsA("BasePart") or child:IsA("Model") then
					table.insert(targets, {
						instance = child,
						baseCFrame = targetCFrame(child),
						phase = #targets * 0.7,
					})
				end
			end
		end
	end
	return targets
end

local function shakeTree(tree)
	if not tree or not tree.Parent then return end
	local targets = collectShakeTargets(tree)
	if #targets == 0 then return end

	shakeIds[tree] = (shakeIds[tree] or 0) + 1
	local shakeId = shakeIds[tree]
	local startedAt = os.clock()

	task.spawn(function()
		while shakeIds[tree] == shakeId do
			local elapsed = os.clock() - startedAt
			local alpha = elapsed / SHAKE_DURATION
			if alpha >= 1 then break end

			local fade = 1 - alpha
			for _, target in ipairs(targets) do
				if target.instance.Parent then
					local wave = math.sin((elapsed * 42) + target.phase) * fade
					applyTargetCFrame(
						target.instance,
						target.baseCFrame
							* CFrame.new(wave * SHAKE_OFFSET, 0, 0)
							* CFrame.Angles(0, 0, wave * SHAKE_ANGLE)
					)
				end
			end
			RunService.RenderStepped:Wait()
		end

		if shakeIds[tree] ~= shakeId then return end
		for _, target in ipairs(targets) do
			if target.instance.Parent then
				applyTargetCFrame(target.instance, target.baseCFrame)
			end
		end
	end)
end

local function animate(food)
	if animated[food] then return end
	animated[food] = true

	local parts = partsOf(food)
	tweenTransparency(parts)

	if food:IsA("BasePart") then
		tweenPartGrow(food)
	elseif food:IsA("Model") then
		tweenModelGrow(food)
	end

	food.AncestryChanged:Connect(function()
		if not food:IsDescendantOf(Workspace) then
			animated[food] = nil
		end
	end)
end

function AppleTreeSlotVisuals.start()
	scanGroundFoods()
	for _, delaySeconds in ipairs(GROUND_FOOD_RESCAN_DELAYS) do
		task.delay(delaySeconds, scanGroundFoods)
	end

	Workspace.DescendantAdded:Connect(function(obj)
		if isAppleTreeSlotFood(obj) then
			animate(obj)
		end
		trackGroundFoodCandidate(obj)
	end)

	Remotes.get(Remotes.Names.AppleTreeEffect).OnClientEvent:Connect(function(tree, anchor, marker, foodType, duration)
		shakeTree(tree)
		renderDrop(anchor, marker, foodType, duration)
	end)
end

return AppleTreeSlotVisuals
