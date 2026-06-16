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
local CORNER_NAME = "UICorner"
local TOUCH_GUI_NAME = "TouchGui"
local TOUCH_CONTROL_FRAME_NAME = "TouchControlFrame"
local JUMP_BUTTON_NAME = "JumpButton"
local FEED_ICON_IMAGE_ATTR = "FeedIconImage"
local COLLECT_ICON_IMAGE_ATTR = "CollectIconImage"
local AUTO_MODE_ATTR = "AutoPromptMode"
local FEED_ICON_IMAGE = "rbxassetid://119576309332002"
local COLLECT_ICON_IMAGE = "rbxasset://textures/ui/Controls/TouchTapIcon.png"
local CONTROL_BACKGROUND_COLOR = Color3.fromRGB(58, 61, 68)
local CONTROL_BACKGROUND_TRANSPARENCY = 0.28
local REFRESH_SECONDS = 0.1
local GAP_SCALE = 0.12
local BUTTON_JUMP_SIZE_SCALE = 0.5 * 1.3 * 1.15
local MIN_DIAMETER = math.floor(24 * 1.3 * 1.15)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local hud = nil
local button = nil
local icon = nil
local pressed = false
local activePressInput = nil
local activePressInputType = nil
local lockedMode = nil
local currentCandidate = nil
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

local function clearTextSignage(guiObject)
	if guiObject:IsA("TextLabel") or guiObject:IsA("TextButton") then
		guiObject.Text = ""
		guiObject.TextTransparency = 1
		guiObject.TextStrokeTransparency = 1
	end

	for _, descendant in ipairs(guiObject:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			descendant.Text = ""
			descendant.TextTransparency = 1
			descendant.TextStrokeTransparency = 1
		end
	end
end

local function configureButtonIconDefaults()
	if not button then
		return
	end

	button:SetAttribute("FeedIconText", nil)
	button:SetAttribute("CollectIconText", nil)
	local feedIconImage = button:GetAttribute(FEED_ICON_IMAGE_ATTR)
	if type(feedIconImage) ~= "string" or feedIconImage == "" then
		button:SetAttribute(FEED_ICON_IMAGE_ATTR, FEED_ICON_IMAGE)
	end
	local collectIconImage = button:GetAttribute(COLLECT_ICON_IMAGE_ATTR)
	if type(collectIconImage) ~= "string" or collectIconImage == "" then
		button:SetAttribute(COLLECT_ICON_IMAGE_ATTR, COLLECT_ICON_IMAGE)
	end
end

local function ensureButtonBackgroundShape()
	if not button then
		return
	end

	local corner = button:FindFirstChild(CORNER_NAME)
	if not (corner and corner:IsA("UICorner")) then
		corner = Instance.new("UICorner")
		corner.Name = CORNER_NAME
		corner.Parent = button
	end
	corner.CornerRadius = UDim.new(1, 0)
end

local function ensureImageIcon(iconObject)
	if iconObject:IsA("ImageLabel") or iconObject:IsA("ImageButton") then
		clearTextSignage(iconObject)
		return iconObject
	end
	if not (iconObject:IsA("TextLabel") or iconObject:IsA("TextButton")) then
		return nil
	end

	clearTextSignage(iconObject)
	local imageIcon = iconObject:FindFirstChild("Image")
	if not (imageIcon and imageIcon:IsA("ImageLabel")) then
		imageIcon = Instance.new("ImageLabel")
		imageIcon.Name = "Image"
		imageIcon.BackgroundTransparency = 1
		imageIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		imageIcon.Position = UDim2.fromScale(0.5, 0.5)
		imageIcon.Size = UDim2.fromScale(1, 1)
		imageIcon.ZIndex = iconObject.ZIndex + 1
		imageIcon.ScaleType = Enum.ScaleType.Fit
		imageIcon.Parent = iconObject
	end
	imageIcon.Visible = true
	return imageIcon
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
	button.Image = ""
	button.BackgroundColor3 = CONTROL_BACKGROUND_COLOR
	button.BackgroundTransparency = CONTROL_BACKGROUND_TRANSPARENCY
	button.BorderSizePixel = 0

	if jumpButton:IsA("ImageButton") or jumpButton:IsA("ImageLabel") then
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

	local diameter = math.max(MIN_DIAMETER, math.floor(math.min(jumpSize.X, jumpSize.Y) * BUTTON_JUMP_SIZE_SCALE))
	local radius = diameter * 0.5
	local gap = diameter * GAP_SCALE
	local jumpPosition = jumpButton.AbsolutePosition
	local hudPosition = hud.AbsolutePosition
	local screenCenter = Vector2.new(
		jumpPosition.X - radius - gap,
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

	if icon:IsA("ImageLabel") or icon:IsA("ImageButton") then
		local attrName = mode == LocalPrompts.AutoModes.Feed and FEED_ICON_IMAGE_ATTR or COLLECT_ICON_IMAGE_ATTR
		local image = button:GetAttribute(attrName)
		if type(image) == "string" and image ~= "" then
			icon.Image = image
		end
		icon.Visible = true
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

local function refreshIdleState(options)
	if pressed then
		return
	end
	if not refreshLayout() then
		currentCandidate = nil
		return
	end

	options = type(options) == "table" and options or {}
	local useLiveLookup = options.liveLookup == true and currentCandidate ~= nil
	currentCandidate = LocalPrompts.ResolveAutoPromptCandidate(nil, {
		liveLookup = useLiveLookup,
		skipRefresh = true,
	})
	if currentCandidate then
		setButtonMode(currentCandidate.mode, true)
	else
		setButtonMode(nil, false)
	end
end

local function beginPress(input)
	if pressed or not button or not button.Visible then
		return
	end

	currentCandidate = LocalPrompts.BeginAutoHold(nil, { immediate = true })
	if not currentCandidate then
		setButtonMode(nil, false)
		return
	end

	pressed = true
	activePressInput = input
	activePressInputType = input.UserInputType
	lockedMode = currentCandidate.mode
	setButtonMode(lockedMode, true)
end

local function endPress(input)
	if not pressed then
		return
	end
	if input ~= nil and activePressInput ~= nil and input ~= activePressInput then
		if activePressInputType ~= Enum.UserInputType.Touch or input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
	end

	pressed = false
	activePressInput = nil
	activePressInputType = nil
	lockedMode = nil
	LocalPrompts.EndAutoHold()
	refreshIdleState({ liveLookup = true })
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
	configureButtonIconDefaults()
	ensureButtonBackgroundShape()
	icon = ensureImageIcon(icon)
	if not icon then
		warn("[AutoPromptButtonController] HUD.AutoPromptButton Icon must be an image or text-backed GuiObject")
		return
	end

	UiEffects.BindButton(button, { silent = true })
	setButtonMode(nil, false)

	RuntimeGuard.Connect(button.InputBegan, "AutoPromptButton.InputBegan", function(input)
		if isPressInput(input) then
			beginPress(input)
		end
	end)
	RuntimeGuard.Connect(button.InputEnded, "AutoPromptButton.InputEnded", function(input)
		if isPressInput(input) then
			endPress(input)
		end
	end)
	RuntimeGuard.Connect(UserInputService.InputEnded, "AutoPromptButton.GlobalInputEnded", function(input)
		if isPressInput(input) then
			endPress(input)
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
				refreshIdleState({ liveLookup = true })
			end
		end
	end)
end

return AutoPromptButtonController
