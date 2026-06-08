local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local AutoPromptButtonController = {}

local HUD_NAME = "HUD"
local BUTTON_NAME = "AutoPromptButton"
local ICON_NAME = "Icon"
local TOUCH_GUI_NAME = "TouchGui"
local TOUCH_CONTROL_FRAME_NAME = "TouchControlFrame"
local JUMP_BUTTON_NAME = "JumpButton"
local FEED_ICON_TEXT_ATTR = "FeedIconText"
local COLLECT_ICON_TEXT_ATTR = "CollectIconText"
local FEED_ICON_IMAGE_ATTR = "FeedIconImage"
local COLLECT_ICON_IMAGE_ATTR = "CollectIconImage"
local AUTO_MODE_ATTR = "AutoPromptMode"
local REPEAT_SECONDS = 0.5
local REFRESH_SECONDS = 0.1
local GAP_SCALE = 0.12
local MIN_DIAMETER = 24

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local hud = nil
local button = nil
local icon = nil
local pressed = false
local lockedMode = nil
local lockedTarget = nil
local currentCandidate = nil
local nextActionAt = 0
local refreshAccumulator = 0
local warnedMissingTouchGui = false

local function warnOnceMissingTouchGui()
	if warnedMissingTouchGui then
		return
	end
	warnedMissingTouchGui = true
	warn("[AutoPromptButtonController] Missing mobile TouchGui jump button; auto prompt button will stay hidden")
end

local function isPressInput(input)
	return input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1
end

local function findJumpButton()
	local touchGui = playerGui:FindFirstChild(TOUCH_GUI_NAME)
	local touchFrame = touchGui and touchGui:FindFirstChild(TOUCH_CONTROL_FRAME_NAME)
	local jumpButton = touchFrame and touchFrame:FindFirstChild(JUMP_BUTTON_NAME)
	if jumpButton and jumpButton:IsA("GuiObject") then
		return jumpButton
	end
	return nil
end

local function copyJumpButtonStyle(jumpButton)
	if not (button and jumpButton and jumpButton:IsA("GuiObject")) then
		return
	end

	button.BackgroundColor3 = jumpButton.BackgroundColor3
	button.BackgroundTransparency = jumpButton.BackgroundTransparency
	button.BorderColor3 = jumpButton.BorderColor3
	button.BorderSizePixel = jumpButton.BorderSizePixel
	button.AutoButtonColor = false

	if jumpButton:IsA("ImageButton") or jumpButton:IsA("ImageLabel") then
		button.Image = jumpButton.Image
		button.ImageColor3 = jumpButton.ImageColor3
		button.ImageTransparency = jumpButton.ImageTransparency
		button.ImageRectOffset = jumpButton.ImageRectOffset
		button.ImageRectSize = jumpButton.ImageRectSize
		button.ScaleType = jumpButton.ScaleType
		button.SliceCenter = jumpButton.SliceCenter
		button.SliceScale = jumpButton.SliceScale
	end
end

local function positionBesideJumpButton(jumpButton)
	if not (hud and button and jumpButton) then
		return false
	end

	local jumpSize = jumpButton.AbsoluteSize
	local hudSize = hud.AbsoluteSize
	if jumpSize.X <= 0 or jumpSize.Y <= 0 or hudSize.X <= 0 or hudSize.Y <= 0 then
		return false
	end

	local diameter = math.max(MIN_DIAMETER, math.floor(math.min(jumpSize.X, jumpSize.Y) * 0.5))
	local radius = diameter * 0.5
	local gap = diameter * GAP_SCALE
	local jumpPosition = jumpButton.AbsolutePosition
	local hudPosition = hud.AbsolutePosition
	local screenCenter = Vector2.new(
		jumpPosition.X + jumpSize.X - radius,
		jumpPosition.Y - radius - gap
	)

	local minX = hudPosition.X + radius
	local maxX = hudPosition.X + hudSize.X - radius
	local minY = hudPosition.Y + radius
	local maxY = hudPosition.Y + hudSize.Y - radius
	screenCenter = Vector2.new(
		math.clamp(screenCenter.X, minX, maxX),
		math.clamp(screenCenter.Y, minY, maxY)
	)

	button.Size = UDim2.fromOffset(diameter, diameter)
	button.Position = UDim2.fromOffset(screenCenter.X - hudPosition.X, screenCenter.Y - hudPosition.Y)
	return true
end

local function setIconForMode(mode)
	if not icon then
		return
	end

	if icon:IsA("TextLabel") or icon:IsA("TextButton") then
		if mode == LocalPrompts.AutoModes.Feed then
			icon.Text = tostring(button:GetAttribute(FEED_ICON_TEXT_ATTR) or "F")
		elseif mode == LocalPrompts.AutoModes.Collect then
			icon.Text = tostring(button:GetAttribute(COLLECT_ICON_TEXT_ATTR) or "C")
		end
	elseif icon:IsA("ImageLabel") or icon:IsA("ImageButton") then
		local attrName = mode == LocalPrompts.AutoModes.Feed and FEED_ICON_IMAGE_ATTR or COLLECT_ICON_IMAGE_ATTR
		local image = button:GetAttribute(attrName)
		if type(image) == "string" and image ~= "" then
			icon.Image = image
		end
	end
end

local function setButtonMode(mode, visible)
	if not button then
		return
	end

	button.Visible = visible == true
	button.Active = visible == true
	if mode then
		button:SetAttribute(AUTO_MODE_ATTR, mode)
		setIconForMode(mode)
	else
		button:SetAttribute(AUTO_MODE_ATTR, nil)
	end
end

local function refreshLayout()
	if not button then
		return false
	end
	if not UserInputService.TouchEnabled then
		setButtonMode(nil, false)
		return false
	end

	local jumpButton = findJumpButton()
	if not jumpButton then
		setButtonMode(nil, false)
		warnOnceMissingTouchGui()
		return false
	end

	copyJumpButtonStyle(jumpButton)
	return positionBesideJumpButton(jumpButton)
end

local function refreshIdleState()
	if pressed then
		return
	end
	if not refreshLayout() then
		currentCandidate = nil
		return
	end

	currentCandidate = LocalPrompts.FindAutoPromptCandidate()
	if currentCandidate then
		setButtonMode(currentCandidate.mode, true)
	else
		setButtonMode(nil, false)
	end
end

local function beginPress()
	if pressed or not button or not button.Visible then
		return
	end

	currentCandidate = LocalPrompts.FindAutoPromptCandidate()
	if not currentCandidate then
		setButtonMode(nil, false)
		return
	end

	pressed = true
	lockedMode = currentCandidate.mode
	lockedTarget = lockedMode == LocalPrompts.AutoModes.Feed and currentCandidate.target or nil
	nextActionAt = 0
	setButtonMode(lockedMode, true)
end

local function endPress()
	if not pressed then
		return
	end

	pressed = false
	lockedMode = nil
	lockedTarget = nil
	nextActionAt = 0
	refreshIdleState()
end

local function triggerHeldAction()
	if not pressed or not lockedMode then
		return
	end

	local candidate = LocalPrompts.FindAutoPromptCandidate(lockedMode, lockedTarget)
	if candidate then
		LocalPrompts.TriggerAutoPrompt(candidate)
		nextActionAt = os.clock() + REPEAT_SECONDS
	else
		nextActionAt = os.clock() + REFRESH_SECONDS
	end
end

function AutoPromptButtonController.start()
	if not UserInputService.TouchEnabled then
		return
	end

	hud = playerGui:WaitForChild(HUD_NAME, 10)
	if not (hud and hud:IsA("ScreenGui")) then
		warn("[AutoPromptButtonController] Missing PlayerGui.HUD ScreenGui")
		return
	end

	button = hud:FindFirstChild(BUTTON_NAME)
	if not (button and button:IsA("ImageButton")) then
		warn("[AutoPromptButtonController] Missing HUD.AutoPromptButton ImageButton")
		return
	end

	icon = button:FindFirstChild(ICON_NAME)
	if not (icon and icon:IsA("GuiObject")) then
		warn("[AutoPromptButtonController] HUD.AutoPromptButton missing Icon GuiObject")
		return
	end

	UiEffects.BindButton(button)
	setButtonMode(nil, false)

	RuntimeGuard.Connect(button.InputBegan, "AutoPromptButton.InputBegan", function(input)
		if isPressInput(input) then
			beginPress()
		end
	end)
	RuntimeGuard.Connect(button.InputEnded, "AutoPromptButton.InputEnded", function(input)
		if isPressInput(input) then
			endPress()
		end
	end)
	RuntimeGuard.Connect(UserInputService.InputEnded, "AutoPromptButton.GlobalInputEnded", function(input)
		if isPressInput(input) then
			endPress()
		end
	end)

	RuntimeGuard.Connect(RunService.Heartbeat, "AutoPromptButton.Heartbeat", function(dt)
		refreshAccumulator += dt
		if refreshAccumulator >= REFRESH_SECONDS then
			refreshAccumulator = 0
			if pressed then
				refreshLayout()
				setButtonMode(lockedMode, true)
			else
				refreshIdleState()
			end
		end

		if pressed and os.clock() >= nextActionAt then
			triggerHeldAction()
		end
	end)
end

return AutoPromptButtonController
