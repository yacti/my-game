-- Client-only polish for tree-clicker visuals (AppleTree/CherryTree).
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
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State   = require(Shared:WaitForChild("State"))

local AppleTreeSlotVisuals = {}

local RESPAWN_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DROP_TWEEN_INFO    = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local XP_COUNT_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local START_SCALE        = 0.35
local SHAKE_DURATION     = 0.25
local SHAKE_ANGLE        = math.rad(5)
local SHAKE_OFFSET       = 0.12
local BILLBOARD_RANGE    = 40
local GROUND_XP_TEMPLATE_NAME = "TreeGroundXPBillboard"
local GROUND_FOOD_RESCAN_DELAYS = { 0.25, 1, 3 }
local XP_LABEL_NAME      = "XPLabel"

local animated = {}
local activeShakeTargets = {}
local billboards = {}
local pendingGroundFood = {}
local shakeIds = {}
local warnedMissingGroundXPTemplate = false
local warnedMissingGroundXPLabel = false

local function isTreeClicker(tree)
	if not tree or not tree:IsA("Model") then return false end
	local feedType = tree:GetAttribute(State.Feed.Type)
	return feedType == "AppleTree" or feedType == "CherryTree"
end

local function isAppleTreeSlotFood(obj)
	local parent = obj.Parent
	if not parent or parent.Name ~= "SlotAnchor" then return false end
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end

	local tree = parent.Parent
	return isTreeClicker(tree)
end

local function isAppleTreeGroundFood(obj)
	return (obj:IsA("BasePart") or obj:IsA("Model"))
		and obj:GetAttribute(State.TreeClicker.GroundPile) == true
		and obj:GetAttribute(State.TreeClicker.SlotIndex) ~= nil
		and obj:GetAttribute(State.Food.Id) ~= nil
end

local function isAppleTreeGroundCandidate(obj)
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end
	if obj:GetAttribute(State.TreeClicker.GroundPile) == true then return true end
	return obj.Parent ~= nil and obj.Parent.Name == State.TreeClicker.GroundFolder
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

local function cloneFoodEffect(foodId)
	local template = Food.GetTemplate(foodId)
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

local function cloneGroundXPTemplate()
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local template = uiFolder and uiFolder:FindFirstChild(GROUND_XP_TEMPLATE_NAME)
	if not (template and template:IsA("BillboardGui")) then
		if not warnedMissingGroundXPTemplate then
			warn("[AppleTreeSlotVisuals] Missing ReplicatedStorage.UI.TreeGroundXPBillboard BillboardGui")
			warnedMissingGroundXPTemplate = true
		end
		return nil
	end
	return template:Clone()
end

local function findXPLabel(gui)
	local label = gui:FindFirstChild(XP_LABEL_NAME, true)
	if label and label:IsA("TextLabel") then
		return label
	end
	if not warnedMissingGroundXPLabel then
		warn("[AppleTreeSlotVisuals] TreeGroundXPBillboard missing XPLabel TextLabel")
		warnedMissingGroundXPLabel = true
	end
	return nil
end

local function roundedXP(value)
	return math.floor((tonumber(value) or 0) + 0.5)
end

local function currentXPFor(food)
	return tonumber(food:GetAttribute(State.Food.XP)) or 0
end

local function gainTextColorFor(label)
	local color = label:GetAttribute("GainTextColor")
	return typeof(color) == "Color3" and color or label.TextColor3
end

local function renderXPText(label, xpOverride)
	local xp = roundedXP(xpOverride)
	label.Text = string.format("%d xp", xp)
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
		record.label.TextColor3 = record.baseTextColor
		renderXPText(record.label, targetXP)
		return
	end

	local value = Instance.new("NumberValue")
	value.Value = startXP
	record.counterValue = value
	record.label.TextColor3 = record.gainTextColor

	value.Changed:Connect(function(nextValue)
		record.displayedXP = nextValue
		renderXPText(record.label, nextValue)
	end)

	local tween = TweenService:Create(value, XP_COUNT_TWEEN_INFO, { Value = targetXP })
	record.counterTween = tween
	tween.Completed:Connect(function()
		if record.counterValue ~= value then return end
		record.displayedXP = targetXP
		record.counterTween = nil
		record.counterValue = nil
		renderXPText(record.label, targetXP)
		value:Destroy()
		TweenService:Create(record.label, TweenInfo.new(0.15), {
			TextColor3 = record.baseTextColor,
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

	local gui = cloneGroundXPTemplate()
	if not gui then return false end
	local label = findXPLabel(gui)
	if not label then
		gui:Destroy()
		return false
	end
	gui.Name = "XPBillboard"
	gui.Adornee = adornee
	gui.MaxDistance = BILLBOARD_RANGE

	local record = {
		gui = gui,
		conns = {},
		label = label,
		baseTextColor = label.TextColor3,
		gainTextColor = gainTextColorFor(label),
		displayedXP = currentXPFor(food),
		counterTween = nil,
		counterValue = nil,
	}
	renderXPText(label, record.displayedXP)
	local conns = {}
	table.insert(conns, food:GetAttributeChangedSignal(State.Food.XP):Connect(function()
		animateXPText(food, record)
	end))
	table.insert(conns, food:GetAttributeChangedSignal(State.Food.Type):Connect(function()
		renderXPText(label, record.displayedXP)
	end))
	table.insert(conns, food:GetAttributeChangedSignal(State.Food.Id):Connect(function()
		renderXPText(label, record.displayedXP)
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
	if not isAppleTreeGroundCandidate(obj) then return end
	if isAppleTreeGroundFood(obj) and attachXPBillboard(obj) then return end
	if pendingGroundFood[obj] then return end

	local conns = {}
	local function tryAttach()
		if isAppleTreeGroundFood(obj) and attachXPBillboard(obj) then
			clearPendingGroundFood(obj)
		end
	end

	table.insert(conns, obj:GetAttributeChangedSignal(State.TreeClicker.GroundPile):Connect(tryAttach))
	table.insert(conns, obj:GetAttributeChangedSignal(State.TreeClicker.SlotIndex):Connect(tryAttach))
	table.insert(conns, obj:GetAttributeChangedSignal(State.Food.Type):Connect(tryAttach))
	table.insert(conns, obj:GetAttributeChangedSignal(State.Food.Id):Connect(tryAttach))
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

local function renderDrop(anchor, marker, foodId, duration)
	if not anchor or not anchor.Parent or not marker or not marker.Parent then return end

	local effect = cloneFoodEffect(foodId)
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

local function applyShakeTarget(target, cframe)
	applyTargetCFrame(target.instance, cframe)
	if not target.children then return end

	for _, child in ipairs(target.children) do
		if child.instance.Parent then
			child.instance.CFrame = cframe * child.localCFrame
		end
	end
end

local function restoreTargets(targets)
	for _, target in ipairs(targets) do
		if target.instance.Parent then
			applyShakeTarget(target, target.baseCFrame)
		end
	end
end

local function hasLeafAncestor(part, tree)
	local parent = part.Parent
	while parent and parent ~= tree do
		if parent:IsA("BasePart") and parent.Name == "Leaf" then
			return true
		end
		parent = parent.Parent
	end
	return false
end

local function leafChildren(leaf)
	local children = {}
	for _, descendant in ipairs(leaf:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(children, {
				instance = descendant,
				localCFrame = leaf.CFrame:ToObjectSpace(descendant.CFrame),
			})
		end
	end
	return children
end

local function collectShakeTargets(tree)
	local targets = {}
	for _, d in ipairs(tree:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Leaf" and not hasLeafAncestor(d, tree) then
			table.insert(targets, {
				instance = d,
				baseCFrame = d.CFrame,
				children = leafChildren(d),
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

	local previousTargets = activeShakeTargets[tree]
	if previousTargets then
		restoreTargets(previousTargets)
	end

	local targets = collectShakeTargets(tree)
	if #targets == 0 then return end

	shakeIds[tree] = (shakeIds[tree] or 0) + 1
	local shakeId = shakeIds[tree]
	local startedAt = os.clock()
	activeShakeTargets[tree] = targets

	task.spawn(function()
		while shakeIds[tree] == shakeId do
			local elapsed = os.clock() - startedAt
			local alpha = elapsed / SHAKE_DURATION
			if alpha >= 1 then break end

			local fade = 1 - alpha
			for _, target in ipairs(targets) do
				if target.instance.Parent then
					local wave = math.sin((elapsed * 42) + target.phase) * fade
					applyShakeTarget(
						target,
						target.baseCFrame
							* CFrame.new(wave * SHAKE_OFFSET, 0, 0)
							* CFrame.Angles(0, 0, wave * SHAKE_ANGLE)
					)
				end
			end
			RunService.RenderStepped:Wait()
		end

		if shakeIds[tree] ~= shakeId or activeShakeTargets[tree] ~= targets then
			return
		end
		restoreTargets(targets)
		activeShakeTargets[tree] = nil
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

	RuntimeGuard.Connect(food.AncestryChanged, "AppleTreeSlotVisuals.FoodAncestryChanged", function()
		if not food:IsDescendantOf(Workspace) then
			animated[food] = nil
		end
	end)
end

function AppleTreeSlotVisuals.start()
	scanGroundFoods()
	for _, delaySeconds in ipairs(GROUND_FOOD_RESCAN_DELAYS) do
		task.delay(delaySeconds, function()
			RuntimeGuard.Run("AppleTreeSlotVisuals.RescanGroundFoods", scanGroundFoods)
		end)
	end

	RuntimeGuard.Connect(Workspace.DescendantAdded, "AppleTreeSlotVisuals.DescendantAdded", function(obj)
		if isAppleTreeSlotFood(obj) then
			animate(obj)
		end
		trackGroundFoodCandidate(obj)
	end)

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.TreeClickerEffect).OnClientEvent, "AppleTreeSlotVisuals.TreeClickerEffect", function(payload)
		if type(payload) ~= "table" then return end
		local tree = payload.machine
		local anchor = payload.anchor
		local marker = payload.marker
		local foodId = payload.foodId
		local duration = tonumber(payload.duration) or DROP_TWEEN_INFO.Time
		if typeof(tree) ~= "Instance" or not tree:IsA("Model") then return end
		if typeof(anchor) ~= "Instance" or not anchor:IsA("BasePart") then return end
		if typeof(marker) ~= "Instance" or not marker:IsA("BasePart") then return end
		if type(foodId) ~= "string" then return end
		shakeTree(tree)
		renderDrop(anchor, marker, foodId, duration)
	end)
end

return AppleTreeSlotVisuals
