-- Client-only polish for FeedClass=Tree visuals.
-- Server owns gameplay state; this module renders transient shake, drop,
-- slot respawn effects, close-range ground fruit, and ground XP billboards
-- locally from replicated marker attributes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Food    = require(Shared:WaitForChild("Food"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State   = require(Shared:WaitForChild("State"))
local PlotScope = require(script.Parent:WaitForChild("PlotScope"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local TreeMotionEffects = require(script.Parent:WaitForChild("TreeMotionEffects"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local XPBillboardTemplate = require(script.Parent:WaitForChild("XPBillboardTemplate"))

local TreeVisuals = {}

local LOCAL_GROUND_VISUAL_FOLDER = "__ClientTreeGroundVisuals"
local TREE_SHAKE_SOUND_ATTACHMENT = "__TreeShakeSoundSource"
local RESPAWN_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DROP_TWEEN_INFO    = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local XP_COUNT_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local START_SCALE        = 0.35
local BILLBOARD_RANGE    = 40
local GROUND_VISUAL_RANGE = 90
local SCOPE_RANGE        = 100
local TREE_SHAKE_SOUND_RANGE = 35
local TREE_SHAKE_SOUND_MIN_RANGE = 4
local TREE_SHAKE_SOUND_HEIGHT = 3
local GROUND_VISUAL_CHECK_INTERVAL = 0.2

local player = Players.LocalPlayer
local animated = {}
local billboards = {}
local pendingGroundFood = {}
local groundMarkers = {}

local function isTreeClicker(tree)
	if not tree or not tree:IsA("Model") then return false end
	return tree:GetAttribute(State.Feed.Class) == "Tree"
end

local function isTreeSlotFood(obj)
	local parent = obj.Parent
	if not parent or parent.Name ~= "SlotAnchor" then return false end
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end

	local tree = parent.Parent
	return isTreeClicker(tree)
end

local function isTreeGroundMarker(obj)
	return (obj:IsA("BasePart") or obj:IsA("Model"))
		and obj:GetAttribute(State.TreeClicker.GroundPile) == true
		and obj:GetAttribute(State.TreeClicker.SlotIndex) ~= nil
		and obj:GetAttribute(State.Food.Id) ~= nil
		and obj:GetAttribute(State.TreeClicker.LocalVisual) ~= true
end

local function isTreeGroundCandidate(obj)
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end
	if obj:GetAttribute(State.TreeClicker.LocalVisual) == true then return false end
	if obj:GetAttribute(State.TreeClicker.GroundPile) == true then return true end
	if obj.Name:match("^BaseFoodGround%d+$") == nil then return false end
	local ancestor = obj.Parent
	while ancestor do
		if isTreeClicker(ancestor) then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
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

local function localGroundVisualFolder()
	local folder = Workspace:FindFirstChild(LOCAL_GROUND_VISUAL_FOLDER)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if folder then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = LOCAL_GROUND_VISUAL_FOLDER
	folder.Parent = Workspace
	return folder
end

local function clearGameplayAttributes(instance)
	instance:SetAttribute(State.TreeClicker.GroundPile, nil)
	instance:SetAttribute(State.TreeClicker.SlotIndex, nil)
	instance:SetAttribute(State.Food.Id, nil)
	instance:SetAttribute(State.Food.Type, nil)
	instance:SetAttribute(State.Food.XP, nil)
	instance:SetAttribute(State.TreeClicker.LocalVisual, true)
end

local function localGroundHalfHeight(visual)
	if visual:IsA("BasePart") then return visual.Size.Y / 2 end
	if visual:IsA("Model") and visual.PrimaryPart then return visual.PrimaryPart.Size.Y / 2 end
	return 0
end

local function localGroundCFrame(marker, visual)
	local dy = localGroundHalfHeight(visual) - marker.Size.Y / 2
	return marker.CFrame * CFrame.new(0, dy, 0)
end

local function cloneLocalGroundVisual(marker)
	local foodId = marker:GetAttribute(State.Food.Id)
	if type(foodId) ~= "string" then return nil end
	local template = Food.GetTemplate(foodId)
	if not template then return nil end

	local clone = template:Clone()
	clearGameplayAttributes(clone)
	if clone:IsA("BasePart") then
		configureEffectPart(clone)
		clone.CFrame = localGroundCFrame(marker, clone)
	elseif clone:IsA("Model") then
		if not clone.PrimaryPart then
			clone:Destroy()
			return nil
		end
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then configureEffectPart(d) end
		end
		clone:PivotTo(localGroundCFrame(marker, clone))
	else
		clone:Destroy()
		return nil
	end
	clone.Name = "__TreeGroundVisual"
	clone.Parent = localGroundVisualFolder()
	return clone
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
	label.Text = NumberFormatter.XP(xp, " xp")
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

	local gui, label = XPBillboardTemplate.Clone("TreeVisuals")
	if not gui then return false end
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
	UiEffects.BindBillboardDistancePop(gui)
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

	return true
end

local function cleanupGroundMarker(marker)
	local record = groundMarkers[marker]
	if not record then return end
	if record.visual then
		record.visual:Destroy()
	end
	groundMarkers[marker] = nil
	local billboard = billboards[marker]
	if billboard then
		for _, conn in ipairs(billboard.conns) do
			conn:Disconnect()
		end
		stopXPCounter(billboard)
		if billboard.gui then billboard.gui:Destroy() end
		billboards[marker] = nil
	end
end

local function trackGroundMarker(marker)
	if not isTreeGroundMarker(marker) then
		cleanupGroundMarker(marker)
		return false
	end
	if not groundMarkers[marker] then
		groundMarkers[marker] = {
			visual = nil,
			foodId = marker:GetAttribute(State.Food.Id),
		}
	end
	attachXPBillboard(marker)
	return true
end

function TreeVisuals.GroundVisualForMarker(marker)
	local record = groundMarkers[marker]
	if record and record.visual and record.visual.Parent then
		return record.visual
	end
	return nil
end

local function trackGroundFoodCandidate(obj)
	if not isTreeGroundCandidate(obj) then return end
	if pendingGroundFood[obj] then return end

	local conns = {}
	local function tryAttach()
		trackGroundMarker(obj)
	end

	table.insert(conns, obj:GetAttributeChangedSignal(State.TreeClicker.GroundPile):Connect(tryAttach))
	table.insert(conns, obj:GetAttributeChangedSignal(State.TreeClicker.SlotIndex):Connect(tryAttach))
	table.insert(conns, obj:GetAttributeChangedSignal(State.Food.Type):Connect(tryAttach))
	table.insert(conns, obj:GetAttributeChangedSignal(State.Food.Id):Connect(tryAttach))
	table.insert(conns, obj:GetAttributeChangedSignal(State.Food.XP):Connect(tryAttach))
	if obj:IsA("Model") then
		table.insert(conns, obj.DescendantAdded:Connect(function()
			tryAttach()
		end))
	end
	table.insert(conns, obj.AncestryChanged:Connect(function()
		if not obj:IsDescendantOf(Workspace) then
			cleanupGroundMarker(obj)
			clearPendingGroundFood(obj)
		end
	end))
	pendingGroundFood[obj] = conns

	task.defer(tryAttach)
end

local function playerRootPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function markerPosition(marker)
	if marker:IsA("BasePart") then return marker.Position end
	if marker:IsA("Model") then return marker:GetPivot().Position end
	return nil
end

-- Per-marker RuntimeGuard.Run is hoisted out of this pass; the Heartbeat
-- connection wrapper already guards the whole tick.
local function updateGroundVisuals()
	local rootPosition = playerRootPosition()
	for marker, record in pairs(groundMarkers) do
		if not isTreeGroundMarker(marker) or not marker:IsDescendantOf(Workspace) then
			cleanupGroundMarker(marker)
		else
			local position = rootPosition and markerPosition(marker) or nil
			local inRange = position ~= nil and (position - rootPosition).Magnitude <= GROUND_VISUAL_RANGE
			local foodId = marker:GetAttribute(State.Food.Id)
			if (not inRange) or type(foodId) ~= "string" then
				if record.visual then
					record.visual:Destroy()
					record.visual = nil
				end
				record.foodId = foodId
			else
				if record.visual and record.foodId ~= foodId then
					record.visual:Destroy()
					record.visual = nil
				end
				if not record.visual then
					record.visual = cloneLocalGroundVisual(marker)
					record.foodId = foodId
				elseif record.visual:IsA("BasePart") then
					record.visual.CFrame = localGroundCFrame(marker, record.visual)
				elseif record.visual:IsA("Model") then
					record.visual:PivotTo(localGroundCFrame(marker, record.visual))
				end
			end
		end
	end
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

	RuntimeGuard.Connect(food.AncestryChanged, "TreeVisuals.FoodAncestryChanged", function()
		if not food:IsDescendantOf(Workspace) then
			animated[food] = nil
		end
	end)
end

local function scanTreeVisualRoot(root)
	if not root then return end
	for _, obj in ipairs(root:GetDescendants()) do
		if isTreeGroundCandidate(obj) then
			trackGroundFoodCandidate(obj)
		elseif isTreeSlotFood(obj) then
			animate(obj)
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

local function treeShakeSoundParent(tree, fallback)
	local primary = tree.PrimaryPart
	if not (primary and primary:IsA("BasePart")) then
		return fallback
	end

	local attachment = primary:FindFirstChild(TREE_SHAKE_SOUND_ATTACHMENT)
	if not (attachment and attachment:IsA("Attachment")) then
		attachment = Instance.new("Attachment")
		attachment.Name = TREE_SHAKE_SOUND_ATTACHMENT
		attachment.Parent = primary
	end
	attachment.Position = Vector3.new(0, (-primary.Size.Y / 2) + TREE_SHAKE_SOUND_HEIGHT, 0)
	return attachment
end

function TreeVisuals.start()
	PlotScope.Bind({
		label = "TreeVisuals",
		nearbyRange = SCOPE_RANGE,
		onPlotAdded = function(plot)
			RuntimeGuard.Run("TreeVisuals.ScanRoot", scanTreeVisualRoot, plot)
			local conn = RuntimeGuard.Connect(plot.DescendantAdded, "TreeVisuals.RootDescendantAdded", function(obj)
				if isTreeSlotFood(obj) then
					animate(obj)
				end
				trackGroundFoodCandidate(obj)
			end)
			return function()
				if conn then conn:Disconnect() end
				-- `animated` is intentionally kept: it self-cleans when food
				-- leaves Workspace and prevents replaying the grow-in tween
				-- every time a plot re-enters scope.
				for marker in pairs(groundMarkers) do
					if marker:IsDescendantOf(plot) then cleanupGroundMarker(marker) end
				end
				for obj in pairs(pendingGroundFood) do
					if obj:IsDescendantOf(plot) then clearPendingGroundFood(obj) end
				end
				TreeMotionEffects.ClearPlot(plot)
			end
		end,
	})

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "TreeVisuals.GroundVisualHeartbeat", function(dt)
		elapsed += dt
		if elapsed < GROUND_VISUAL_CHECK_INTERVAL then return end
		elapsed = 0
		updateGroundVisuals()
	end)

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.TreeClickerEffect).OnClientEvent, "TreeVisuals.TreeClickerEffect", function(payload)
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
		if payload.playSound ~= false then
			SoundEffects.PlayVaried(SoundEffects.Names.TreeShaken, {
				parent = treeShakeSoundParent(tree, anchor),
				range = TREE_SHAKE_SOUND_RANGE,
				rollOffMinDistance = TREE_SHAKE_SOUND_MIN_RANGE,
			})
		end
		if payload.shakeTree ~= false then
			TreeMotionEffects.ShakeTree(tree)
		end
		renderDrop(anchor, marker, foodId, duration)
	end)
end

return TreeVisuals
