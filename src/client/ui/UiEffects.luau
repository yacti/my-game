local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local UiEffects = {}

local BUTTON_EFFECTS_ATTR = "UiEffectsButtonBound"
local BILLBOARD_POP_ATTR = "UiEffectsBillboardPopBound"
local GENERATED_SCALE_ATTR = "UiEffectsGeneratedScale"

local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BILLBOARD_POP_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BILLBOARD_HIDE_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BILLBOARD_POP_START_SCALE = 0.18
local BILLBOARD_MANAGED_MAX_DISTANCE = 100000
local BILLBOARD_DISTANCE_CHECK_INTERVAL = 0.15

local function darken(color, amount)
	return Color3.new(
		math.clamp(color.R * amount, 0, 1),
		math.clamp(color.G * amount, 0, 1),
		math.clamp(color.B * amount, 0, 1)
	)
end

local function scaleUDim2(value, scale)
	return UDim2.new(
		value.X.Scale * scale,
		math.floor(value.X.Offset * scale),
		value.Y.Scale * scale,
		math.floor(value.Y.Offset * scale)
	)
end

local function findScale(guiObject)
	return guiObject:FindFirstChildOfClass("UIScale")
end

local function ensureScale(guiObject)
	local scale = findScale(guiObject)
	if scale then
		return scale
	end
	scale = Instance.new("UIScale")
	scale.Name = "UiEffectsScale"
	scale:SetAttribute(GENERATED_SCALE_ATTR, true)
	scale.Parent = guiObject
	return scale
end

local function tween(instance, tweenInfo, props)
	local created = TweenService:Create(instance, tweenInfo, props)
	created:Play()
	return created
end

local function buttonColorTarget(button)
	if button:IsA("ImageButton") then
		return "ImageColor3", button.ImageColor3
	end
	return "BackgroundColor3", button.BackgroundColor3
end

local pressedButtons = setmetatable({}, { __mode = "k" })
local billboardBaseSizes = setmetatable({}, { __mode = "k" })
local billboardPopTokens = setmetatable({}, { __mode = "k" })
local distanceBillboards = setmetatable({}, { __mode = "k" })
local inputEndedConnection = nil
local billboardDistanceConnection = nil

local function ensureInputEndedConnection()
	if inputEndedConnection then
		return
	end

	inputEndedConnection = RuntimeGuard.Connect(UserInputService.InputEnded, "UiEffects.InputEnded", function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		for _, release in pairs(pressedButtons) do
			release()
		end
	end)
end

function UiEffects.BindButton(button)
	if not (button and button:IsA("GuiButton")) then
		return
	end
	if button:GetAttribute(BUTTON_EFFECTS_ATTR) == true then
		return
	end
	button:SetAttribute(BUTTON_EFFECTS_ATTR, true)

	local colorProp, baseColor = buttonColorTarget(button)
	local hoverColor = darken(baseColor, 0.72)
	local uiScale = ensureScale(button)
	local baseScale = uiScale.Scale
	local hovering = false
	local pressing = false

	ensureInputEndedConnection()

	local function setHover(active)
		if button.Active == false then
			active = false
		end
		hovering = active
		tween(button, HOVER_TWEEN, {
			[colorProp] = active and hoverColor or baseColor,
		})
	end

	local function setPressed(active)
		if button.Active == false then
			active = false
		end
		pressing = active
		if uiScale then
			tween(uiScale, PRESS_TWEEN, {
				Scale = active and baseScale * 0.92 or baseScale,
			})
		end
	end

	local function releasePress()
		if not pressing then
			return
		end
		pressedButtons[button] = nil
		setPressed(false)
		if not hovering then
			setHover(false)
		end
	end

	RuntimeGuard.Connect(button.MouseEnter, "UiEffects.MouseEnter", function()
		setHover(true)
	end)

	RuntimeGuard.Connect(button.MouseLeave, "UiEffects.MouseLeave", function()
		setHover(false)
		releasePress()
	end)

	RuntimeGuard.Connect(button.MouseButton1Down, "UiEffects.MouseButton1Down", function()
		setPressed(true)
		if pressing then
			pressedButtons[button] = releasePress
		end
	end)

	RuntimeGuard.Connect(button.MouseButton1Up, "UiEffects.MouseButton1Up", function()
		releasePress()
	end)

	RuntimeGuard.Connect(button.Destroying, "UiEffects.ButtonDestroying", function()
		pressedButtons[button] = nil
	end)
end

function UiEffects.BindAllButtons(root)
	if not root then
		return
	end
	if root:IsA("GuiButton") then
		UiEffects.BindButton(root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiButton") then
			UiEffects.BindButton(descendant)
		end
	end
end

function UiEffects.PlayBillboardPop(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return nil
	end
	local distanceRecord = distanceBillboards[billboard]
	if distanceRecord and distanceRecord.allowPop ~= true then
		return nil
	end

	local baseSize = billboardBaseSizes[billboard] or billboard.Size
	billboardBaseSizes[billboard] = baseSize

	local token = (billboardPopTokens[billboard] or 0) + 1
	billboardPopTokens[billboard] = token

	billboard.Size = scaleUDim2(baseSize, BILLBOARD_POP_START_SCALE)
	local popTween = tween(billboard, BILLBOARD_POP_TWEEN, {
		Size = baseSize,
	})
	RuntimeGuard.Connect(popTween.Completed, "UiEffects.BillboardPopCompleted", function()
		if billboardPopTokens[billboard] ~= token then
			return
		end
		if billboard.Parent then
			billboard.Size = baseSize
		end
	end)
	return popTween
end

function UiEffects.BindBillboardPop(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return
	end
	if billboard:GetAttribute(BILLBOARD_POP_ATTR) == true then
		return
	end
	billboard:SetAttribute(BILLBOARD_POP_ATTR, true)

	RuntimeGuard.Connect(billboard:GetPropertyChangedSignal("Enabled"), "UiEffects.BillboardEnabled", function()
		if billboard.Enabled then
			UiEffects.PlayBillboardPop(billboard)
		end
	end)
	RuntimeGuard.Connect(billboard.Destroying, "UiEffects.BillboardDestroying", function()
		billboardBaseSizes[billboard] = nil
		billboardPopTokens[billboard] = nil
	end)

	if billboard.Enabled then
		task.defer(function()
			if billboard.Parent and billboard.Enabled then
				UiEffects.PlayBillboardPop(billboard)
			end
		end)
	end
end

local function billboardBaseSize(billboard)
	local baseSize = billboardBaseSizes[billboard] or billboard.Size
	billboardBaseSizes[billboard] = baseSize
	return baseSize
end

local function nextBillboardToken(billboard)
	local token = (billboardPopTokens[billboard] or 0) + 1
	billboardPopTokens[billboard] = token
	return token
end

local function billboardWorldPosition(billboard)
	local target = billboard.Adornee or billboard.Parent
	if not target then
		return nil
	end
	if target:IsA("Attachment") then
		return target.WorldPosition
	end
	if target:IsA("BasePart") then
		return target.Position
	end
	if target:IsA("Model") then
		return target:GetPivot().Position
	end
	return nil
end

local function distanceBillboardInRange(billboard, record)
	local camera = Workspace.CurrentCamera
	local position = camera and billboardWorldPosition(billboard)
	if not position then
		return true
	end
	return (camera.CFrame.Position - position).Magnitude <= record.maxDistance
end

local function distanceBillboardShouldShow(billboard, record)
	return record.desiredEnabled == true and distanceBillboardInRange(billboard, record)
end

local function playBillboardHide(billboard, record)
	local baseSize = billboardBaseSize(billboard)
	local token = nextBillboardToken(billboard)
	record.visible = false
	record.closing = true

	local hideTween = tween(billboard, BILLBOARD_HIDE_TWEEN, {
		Size = scaleUDim2(baseSize, BILLBOARD_POP_START_SCALE),
	})
	RuntimeGuard.Connect(hideTween.Completed, "UiEffects.BillboardHideCompleted", function()
		if billboardPopTokens[billboard] ~= token then
			return
		end
		record.closing = false
		if billboard.Parent and not distanceBillboardShouldShow(billboard, record) then
			billboard.Size = scaleUDim2(baseSize, 0)
		end
	end)
end

local function updateDistanceBillboard(billboard)
	local record = distanceBillboards[billboard]
	if not record then
		return
	end

	if record.desiredEnabled ~= true then
		record.visible = false
		record.closing = false
		billboard.Size = billboardBaseSize(billboard)
		return
	end

	if distanceBillboardShouldShow(billboard, record) then
		if record.visible == true and billboard.Enabled then
			return
		end
		record.visible = true
		record.closing = false
		record.allowPop = true
		UiEffects.PlayBillboardPop(billboard)
		record.allowPop = false
	elseif record.visible == true then
		playBillboardHide(billboard, record)
	elseif not record.closing then
		billboard.Size = scaleUDim2(billboardBaseSize(billboard), 0)
	end
end

local function ensureBillboardDistanceConnection()
	if billboardDistanceConnection then
		return
	end

	-- Distance gating only tracks player/camera movement, so it does not need
	-- frame-rate cadence; Enabled changes still update immediately through
	-- their own property signal.
	local elapsed = 0
	billboardDistanceConnection = RuntimeGuard.Connect(RunService.Heartbeat, "UiEffects.BillboardDistance", function(dt)
		elapsed += dt
		if elapsed < BILLBOARD_DISTANCE_CHECK_INTERVAL then return end
		elapsed = 0
		for billboard in pairs(distanceBillboards) do
			if billboard.Parent == nil then
				distanceBillboards[billboard] = nil
			else
				updateDistanceBillboard(billboard)
			end
		end
	end)
end

function UiEffects.BindBillboardDistancePop(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return
	end

	local maxDistance = billboard.MaxDistance
	if type(maxDistance) ~= "number" or maxDistance <= 0 then
		return
	end

	UiEffects.BindBillboardPop(billboard)

	local record = {
		maxDistance = maxDistance,
		desiredEnabled = billboard.Enabled,
		visible = false,
		closing = false,
	}
	distanceBillboards[billboard] = record
	billboard.MaxDistance = BILLBOARD_MANAGED_MAX_DISTANCE

	RuntimeGuard.Connect(billboard:GetPropertyChangedSignal("Enabled"), "UiEffects.DistanceBillboardEnabled", function()
		record.desiredEnabled = billboard.Enabled
		updateDistanceBillboard(billboard)
	end)
	RuntimeGuard.Connect(billboard.Destroying, "UiEffects.DistanceBillboardDestroying", function()
		distanceBillboards[billboard] = nil
	end)

	ensureBillboardDistanceConnection()
	updateDistanceBillboard(billboard)
end

function UiEffects.SetTextStack(root, text)
	if not root then
		return
	end
	if root:IsA("TextLabel") or root:IsA("TextButton") then
		root.Text = text
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			descendant.Text = text
		end
	end
end

function UiEffects.SetButtonEnabled(button, enabled)
	if not button then
		return
	end
	button.Active = enabled
	button.AutoButtonColor = enabled
	if button:IsA("ImageButton") then
		button.ImageTransparency = enabled and 0 or 0.45
	end
	for _, descendant in ipairs(button:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			descendant.TextTransparency = enabled and 0 or 0.35
		elseif descendant:IsA("ImageLabel") then
			descendant.ImageTransparency = enabled and 0 or 0.35
		end
	end
end

function UiEffects.FormatCurrency(amount)
	return NumberFormatter.Currency(amount)
end

function UiEffects.PreparePanel(panel)
	if not panel then
		return nil
	end

	local openPosition = panel.Position
	local openSize = panel.Size
	local closedPosition = UDim2.new(openPosition.X.Scale, openPosition.X.Offset, 1.18, openPosition.Y.Offset)
	local closedSize = scaleUDim2(openSize, 0.86)

	panel:SetAttribute("UiEffectsOpenXScale", openPosition.X.Scale)
	panel:SetAttribute("UiEffectsOpenXOffset", openPosition.X.Offset)
	panel:SetAttribute("UiEffectsOpenYScale", openPosition.Y.Scale)
	panel:SetAttribute("UiEffectsOpenYOffset", openPosition.Y.Offset)
	panel:SetAttribute("UiEffectsOpenSizeXScale", openSize.X.Scale)
	panel:SetAttribute("UiEffectsOpenSizeXOffset", openSize.X.Offset)
	panel:SetAttribute("UiEffectsOpenSizeYScale", openSize.Y.Scale)
	panel:SetAttribute("UiEffectsOpenSizeYOffset", openSize.Y.Offset)

	panel.Position = closedPosition
	panel.Size = closedSize
	panel.Visible = false

	return {
		openPosition = openPosition,
		openSize = openSize,
		closedPosition = closedPosition,
		closedSize = closedSize,
	}
end

function UiEffects.PlayOpen(panel, state)
	if not (panel and state) then
		return nil
	end
	panel.Visible = true
	panel.Position = state.closedPosition
	panel.Size = state.closedSize
	return tween(panel, OPEN_TWEEN, {
		Position = state.openPosition,
		Size = state.openSize,
	})
end

function UiEffects.PlayClose(panel, state, onComplete)
	if not (panel and state) then
		if onComplete then
			onComplete()
		end
		return nil
	end
	local closeTween = tween(panel, CLOSE_TWEEN, {
		Position = state.closedPosition,
		Size = state.closedSize,
	})
	RuntimeGuard.Connect(closeTween.Completed, "UiEffects.PlayCloseCompleted", function()
		panel.Visible = false
		if onComplete then
			onComplete()
		end
	end)
	return closeTween
end

return UiEffects
