local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UiEffects = {}

local BUTTON_EFFECTS_ATTR = "UiEffectsButtonBound"

local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

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
local inputEndedConnection = nil

local function ensureInputEndedConnection()
	if inputEndedConnection then
		return
	end

	inputEndedConnection = UserInputService.InputEnded:Connect(function(input)
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
	local uiScale = findScale(button)
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
				Scale = active and 0.92 or 1,
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

	button.MouseEnter:Connect(function()
		setHover(true)
	end)

	button.MouseLeave:Connect(function()
		setHover(false)
		releasePress()
	end)

	button.MouseButton1Down:Connect(function()
		setPressed(true)
		if pressing then
			pressedButtons[button] = releasePress
		end
	end)

	button.MouseButton1Up:Connect(function()
		releasePress()
	end)

	button.Destroying:Connect(function()
		pressedButtons[button] = nil
	end)
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
	return "$" .. tostring(math.floor(tonumber(amount) or 0))
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
	closeTween.Completed:Connect(function()
		panel.Visible = false
		if onComplete then
			onComplete()
		end
	end)
	return closeTween
end

return UiEffects
