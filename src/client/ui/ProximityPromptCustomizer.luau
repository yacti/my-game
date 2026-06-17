local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local ProximityPromptCustomizer = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local UI_FOLDER_NAME = "UI"
local CUSTOMIZER_FOLDER_NAME = "ProximityPromptCustomizer"
local DEFAULT_THEME_NAME = "Default"

-- Prompt-specific attributes may provide optional price text or billboard offset.
local PRICE_ATTRIBUTE = "PromptPrice"
local STUDS_OFFSET_ATTRIBUTE = "PromptStudsOffset"
local PRICE_AFFORDABLE_COLOR = Color3.fromRGB(126, 229, 124)
local PRICE_UNAFFORDABLE_COLOR = Color3.fromRGB(236, 95, 95)

local PROMPT_DESTROY_DELAY_SECONDS = 0.2

local GAMEPAD_BUTTON_IMAGE = {
	[Enum.KeyCode.ButtonX] = "rbxasset://textures/ui/Controls/xboxX.png",
	[Enum.KeyCode.ButtonY] = "rbxasset://textures/ui/Controls/xboxY.png",
	[Enum.KeyCode.ButtonA] = "rbxasset://textures/ui/Controls/xboxA.png",
	[Enum.KeyCode.ButtonB] = "rbxasset://textures/ui/Controls/xboxB.png",
	[Enum.KeyCode.DPadLeft] = "rbxasset://textures/ui/Controls/dpadLeft.png",
	[Enum.KeyCode.DPadRight] = "rbxasset://textures/ui/Controls/dpadRight.png",
	[Enum.KeyCode.DPadUp] = "rbxasset://textures/ui/Controls/dpadUp.png",
	[Enum.KeyCode.DPadDown] = "rbxasset://textures/ui/Controls/dpadDown.png",
	[Enum.KeyCode.ButtonSelect] = "rbxasset://textures/ui/Controls/xboxmenu.png",
	[Enum.KeyCode.ButtonL1] = "rbxasset://textures/ui/Controls/xboxLS.png",
	[Enum.KeyCode.ButtonR1] = "rbxasset://textures/ui/Controls/xboxRS.png",
}

local KEYBOARD_BUTTON_IMAGE = {
	[Enum.KeyCode.Backspace] = "rbxasset://textures/ui/Controls/backspace.png",
	[Enum.KeyCode.Return] = "rbxasset://textures/ui/Controls/return.png",
	[Enum.KeyCode.LeftShift] = "rbxasset://textures/ui/Controls/shift.png",
	[Enum.KeyCode.RightShift] = "rbxasset://textures/ui/Controls/shift.png",
	[Enum.KeyCode.Tab] = "rbxasset://textures/ui/Controls/tab.png",
}

local KEYBOARD_BUTTON_ICON_MAPPING = {
	["'"] = "rbxasset://textures/ui/Controls/apostrophe.png",
	[","] = "rbxasset://textures/ui/Controls/comma.png",
	["`"] = "rbxasset://textures/ui/Controls/graveaccent.png",
	["."] = "rbxasset://textures/ui/Controls/period.png",
	[" "] = "rbxasset://textures/ui/Controls/spacebar.png",
}

local KEY_CODE_TO_TEXT_MAPPING = {
	[Enum.KeyCode.LeftControl] = "Ctrl",
	[Enum.KeyCode.RightControl] = "Ctrl",
	[Enum.KeyCode.LeftAlt] = "Alt",
	[Enum.KeyCode.RightAlt] = "Alt",
	[Enum.KeyCode.F1] = "F1",
	[Enum.KeyCode.F2] = "F2",
	[Enum.KeyCode.F3] = "F3",
	[Enum.KeyCode.F4] = "F4",
	[Enum.KeyCode.F5] = "F5",
	[Enum.KeyCode.F6] = "F6",
	[Enum.KeyCode.F7] = "F7",
	[Enum.KeyCode.F8] = "F8",
	[Enum.KeyCode.F9] = "F9",
	[Enum.KeyCode.F10] = "F10",
	[Enum.KeyCode.F11] = "F11",
	[Enum.KeyCode.F12] = "F12",
}

local warnedMessages = {}

local function warnOnce(key, message)
	if warnedMessages[key] then
		return
	end
	warnedMessages[key] = true
	warn(message)
end

local function child(parent, name, className)
	local instance = parent and parent:FindFirstChild(name)
	if not instance or (className and not instance:IsA(className)) then
		return nil
	end
	return instance
end

local function themeFolder()
	local ui = ReplicatedStorage:FindFirstChild(UI_FOLDER_NAME)
	local folder = ui and ui:FindFirstChild(CUSTOMIZER_FOLDER_NAME)
	if not folder or not folder:IsA("Folder") then
		warnOnce("missing-folder", "[ProximityPromptCustomizer] Missing ReplicatedStorage.UI.ProximityPromptCustomizer folder")
		return nil
	end
	return folder
end

local function themeTemplate(prompt)
	local folder = themeFolder()
	if not folder then
		return nil
	end

	local promptTheme = prompt:GetAttribute("Theme")
	if type(promptTheme) == "string" and promptTheme ~= "" then
		local themed = folder:FindFirstChild(promptTheme)
		if themed and themed:IsA("BillboardGui") then
			return themed
		end
	end

	local defaultTheme = folder:FindFirstChild(DEFAULT_THEME_NAME)
	if defaultTheme and defaultTheme:IsA("BillboardGui") then
		return defaultTheme
	end

	warnOnce("missing-default", "[ProximityPromptCustomizer] Missing ReplicatedStorage.UI.ProximityPromptCustomizer.Default BillboardGui")
	return nil
end

local function setUpCircularProgressBar(bar)
	local leftGradient = child(child(child(bar, "LeftGradient", "Frame"), "ProgressBarImage", "ImageLabel"), "UIGradient", "UIGradient")
	local rightGradient = child(child(child(bar, "RightGradient", "Frame"), "ProgressBarImage", "ImageLabel"), "UIGradient", "UIGradient")
	local progress = child(bar, "Progress", "NumberValue")
	if not leftGradient or not rightGradient or not progress then
		return false
	end

	progress.Changed:Connect(function(value)
		local angle = math.clamp(value * 360, 0, 360)
		leftGradient.Rotation = math.clamp(angle, 180, 360)
		rightGradient.Rotation = math.clamp(angle, 0, 180)
	end)
	return true
end

local function addGuiObjectTweens(guiObject, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	local backgroundTransparency = guiObject.BackgroundTransparency
	guiObject.BackgroundTransparency = 1
	table.insert(tweensForButtonHoldBegin, TweenService:Create(guiObject, tweenInfoFast, { BackgroundTransparency = 1 }))
	table.insert(tweensForButtonHoldEnd, TweenService:Create(guiObject, tweenInfoFast, { BackgroundTransparency = backgroundTransparency }))
	table.insert(tweensForFadeOut, TweenService:Create(guiObject, tweenInfoFast, { BackgroundTransparency = 1 }))
	table.insert(tweensForFadeIn, TweenService:Create(guiObject, tweenInfoFast, { BackgroundTransparency = backgroundTransparency }))
end

local function addImageTweens(imageLabel, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	local imageTransparency = imageLabel.ImageTransparency
	imageLabel.ImageTransparency = 1
	table.insert(tweensForButtonHoldBegin, TweenService:Create(imageLabel, tweenInfoFast, { ImageTransparency = 1 }))
	table.insert(tweensForButtonHoldEnd, TweenService:Create(imageLabel, tweenInfoFast, { ImageTransparency = imageTransparency }))
	table.insert(tweensForFadeOut, TweenService:Create(imageLabel, tweenInfoFast, { ImageTransparency = 1 }))
	table.insert(tweensForFadeIn, TweenService:Create(imageLabel, tweenInfoFast, { ImageTransparency = imageTransparency }))
end

local function addTextTweens(textLabel, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	local textTransparency = textLabel.TextTransparency
	local textStrokeTransparency = textLabel.TextStrokeTransparency
	textLabel.TextTransparency = 1
	textLabel.TextStrokeTransparency = 1
	table.insert(tweensForButtonHoldBegin, TweenService:Create(textLabel, tweenInfoFast, { TextTransparency = 1, TextStrokeTransparency = 1 }))
	table.insert(tweensForButtonHoldEnd, TweenService:Create(textLabel, tweenInfoFast, { TextTransparency = textTransparency, TextStrokeTransparency = textStrokeTransparency }))
	table.insert(tweensForFadeOut, TweenService:Create(textLabel, tweenInfoFast, { TextTransparency = 1, TextStrokeTransparency = 1 }))
	table.insert(tweensForFadeIn, TweenService:Create(textLabel, tweenInfoFast, { TextTransparency = textTransparency, TextStrokeTransparency = textStrokeTransparency }))
end

local function addUIStrokeTweens(uiStroke, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	local transparency = uiStroke.Transparency
	uiStroke.Transparency = 1
	table.insert(tweensForButtonHoldBegin, TweenService:Create(uiStroke, tweenInfoFast, { Transparency = 1 }))
	table.insert(tweensForButtonHoldEnd, TweenService:Create(uiStroke, tweenInfoFast, { Transparency = transparency }))
	table.insert(tweensForFadeOut, TweenService:Create(uiStroke, tweenInfoFast, { Transparency = 1 }))
	table.insert(tweensForFadeIn, TweenService:Create(uiStroke, tweenInfoFast, { Transparency = transparency }))
end

local function addUnexpectedChildTweens(childInstance, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	if childInstance:IsA("UIStroke") then
		addUIStrokeTweens(childInstance, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	elseif childInstance:IsA("UIGradient") then
		return
	elseif childInstance:IsA("GuiObject") then
		addGuiObjectTweens(childInstance, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
		if childInstance:IsA("TextLabel") then
			addTextTweens(childInstance, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
		elseif childInstance:IsA("ImageLabel") or childInstance:IsA("ImageButton") then
			addImageTweens(childInstance, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
		end
	end

	for _, grandChild in ipairs(childInstance:GetChildren()) do
		addUnexpectedChildTweens(grandChild, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	end
end

local function promptParts(promptUI)
	local frame = child(promptUI, "PromptFrame", "GuiObject")
	local textButton = child(promptUI, "TextButton", "TextButton")
	local inputFrame = child(frame, "InputFrame", "Frame")
	local actionText = child(frame, "ActionText", "TextLabel")
	local objectText = child(frame, "ObjectText", "TextLabel") -- Optional for compact one-line themes.
	local priceText = child(frame, "PriceText", "TextLabel") -- Optional; populated from the PromptPrice attribute.
	local resizeableInputFrame = child(inputFrame, "Frame", "Frame")
	local inputFrameScaler = child(resizeableInputFrame, "UIScale", "UIScale")
	local buttonFrame = child(resizeableInputFrame, "ButtonFrame", "GuiObject")
	local buttonImage = child(resizeableInputFrame, "ButtonImage", "ImageLabel")
	local buttonText = child(resizeableInputFrame, "ButtonText", "TextLabel")
	local icon = child(resizeableInputFrame, "ButtonTextImage", "ImageLabel")
	local progressBar = child(resizeableInputFrame, "ProgressBar", "Frame")

	if not frame
		or not textButton
		or not inputFrame
		or not actionText
		or not resizeableInputFrame
		or not inputFrameScaler
		or not buttonFrame
		or not buttonImage
		or not buttonText
		or not icon
		or not progressBar then
		return nil
	end

	return {
		frame = frame,
		textButton = textButton,
		inputFrame = inputFrame,
		actionText = actionText,
		objectText = objectText,
		priceText = priceText,
		resizeableInputFrame = resizeableInputFrame,
		inputFrameScaler = inputFrameScaler,
		buttonFrame = buttonFrame,
		buttonImage = buttonImage,
		buttonText = buttonText,
		icon = icon,
		progressBar = progressBar,
	}
end

local function createPrompt(prompt, inputType)
	local template = themeTemplate(prompt)
	if not template then
		return nil
	end

	local promptUI = template:Clone()
	local parts = promptParts(promptUI)
	if not parts then
		promptUI:Destroy()
		warnOnce("invalid-theme-" .. template:GetFullName(), "[ProximityPromptCustomizer] Invalid prompt theme structure: " .. template:GetFullName())
		return nil
	end

	local tweensForButtonHoldBegin = {}
	local tweensForButtonHoldEnd = {}
	local tweensForFadeOut = {}
	local tweensForFadeIn = {}
	local tweenInfoInFullDuration = TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	local tweenInfoFast = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tweenInfoQuick = TweenInfo.new(0.06, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	local tweenInfoInstant = TweenInfo.new(0, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

	promptUI.Enabled = true

	local frame = parts.frame
	local actionText = parts.actionText
	local objectText = parts.objectText
	local priceText = parts.priceText
	local inputFrameScaler = parts.inputFrameScaler
	local buttonFrame = parts.buttonFrame
	local buttonImage = parts.buttonImage
	local buttonText = parts.buttonText
	local icon = parts.icon
	local progressBar = parts.progressBar

	local originalFrameSize = frame.Size
	local frameBackgroundTransparency = frame.BackgroundTransparency
	frame.BackgroundTransparency = 1
	table.insert(tweensForButtonHoldBegin, TweenService:Create(frame, tweenInfoFast, { Size = UDim2.fromScale(0.5, 1), BackgroundTransparency = 1 }))
	table.insert(tweensForButtonHoldEnd, TweenService:Create(frame, tweenInfoFast, { Size = originalFrameSize, BackgroundTransparency = frameBackgroundTransparency }))
	table.insert(tweensForFadeOut, TweenService:Create(frame, tweenInfoFast, { Size = UDim2.fromScale(0.5, 1), BackgroundTransparency = 1 }))
	table.insert(tweensForFadeIn, TweenService:Create(frame, tweenInfoFast, { Size = originalFrameSize, BackgroundTransparency = frameBackgroundTransparency }))
	if frame:IsA("ImageLabel") or frame:IsA("ImageButton") then
		local frameImageTransparency = frame.ImageTransparency
		frame.ImageTransparency = 1
		table.insert(tweensForButtonHoldBegin, TweenService:Create(frame, tweenInfoFast, { ImageTransparency = 1 }))
		table.insert(tweensForButtonHoldEnd, TweenService:Create(frame, tweenInfoFast, { ImageTransparency = frameImageTransparency }))
		table.insert(tweensForFadeOut, TweenService:Create(frame, tweenInfoFast, { ImageTransparency = 1 }))
		table.insert(tweensForFadeIn, TweenService:Create(frame, tweenInfoFast, { ImageTransparency = frameImageTransparency }))
	end

	local expectedFrameChildren = {
		[parts.inputFrame] = false,
		[actionText] = true,
	}
	if objectText then
		expectedFrameChildren[objectText] = true
	end
	if priceText then
		expectedFrameChildren[priceText] = true
	end
	for _, frameChild in ipairs(frame:GetChildren()) do
		if expectedFrameChildren[frameChild] == nil then
			addUnexpectedChildTweens(frameChild, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
		elseif expectedFrameChildren[frameChild] == true then
			for _, grandChild in ipairs(frameChild:GetChildren()) do
				addUnexpectedChildTweens(grandChild, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
			end
		end
	end

	local inputFrameScaleFactor = inputType == Enum.ProximityPromptInputType.Touch and 1.6 or 1.33
	table.insert(tweensForButtonHoldBegin, TweenService:Create(inputFrameScaler, tweenInfoFast, { Scale = inputFrameScaleFactor }))
	table.insert(tweensForButtonHoldEnd, TweenService:Create(inputFrameScaler, tweenInfoFast, { Scale = 1 }))

	addTextTweens(actionText, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	if objectText then
		addTextTweens(objectText, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	end
	if priceText then
		addTextTweens(priceText, tweenInfoFast, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
	end

	local buttonFrameBackgroundTransparency = buttonFrame.BackgroundTransparency
	table.insert(tweensForFadeOut, TweenService:Create(buttonFrame, tweenInfoQuick, { BackgroundTransparency = 1 }))
	table.insert(tweensForFadeIn, TweenService:Create(buttonFrame, tweenInfoQuick, { BackgroundTransparency = buttonFrameBackgroundTransparency }))
	if buttonFrame:IsA("ImageLabel") or buttonFrame:IsA("ImageButton") then
		local buttonFrameImageTransparency = buttonFrame.ImageTransparency
		table.insert(tweensForFadeOut, TweenService:Create(buttonFrame, tweenInfoQuick, { ImageTransparency = 1 }))
		table.insert(tweensForFadeIn, TweenService:Create(buttonFrame, tweenInfoQuick, { ImageTransparency = buttonFrameImageTransparency }))
	end
	for _, buttonFrameChild in ipairs(buttonFrame:GetChildren()) do
		if buttonFrameChild:IsA("UIStroke") then
			local transparency = buttonFrameChild.Transparency
			table.insert(tweensForFadeOut, TweenService:Create(buttonFrameChild, tweenInfoQuick, { Transparency = 1 }))
			table.insert(tweensForFadeIn, TweenService:Create(buttonFrameChild, tweenInfoQuick, { Transparency = transparency }))
		end
	end

	local function setupButtonTextTweens()
		local textBackgroundTransparency = buttonText.BackgroundTransparency
		buttonText.BackgroundTransparency = 1
		addTextTweens(buttonText, tweenInfoQuick, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
		table.insert(tweensForFadeIn, TweenService:Create(buttonText, tweenInfoQuick, { BackgroundTransparency = textBackgroundTransparency }))
		for _, buttonTextChild in ipairs(buttonText:GetChildren()) do
			if buttonTextChild:IsA("UIStroke") then
				local transparency = buttonTextChild.Transparency
				table.insert(tweensForFadeOut, TweenService:Create(buttonTextChild, tweenInfoQuick, { Transparency = 1 }))
				table.insert(tweensForFadeIn, TweenService:Create(buttonTextChild, tweenInfoQuick, { Transparency = transparency }))
			end
		end
	end

	local function setupButtonImageTweens()
		local buttonImageBackgroundTransparency = buttonImage.BackgroundTransparency
		buttonImage.BackgroundTransparency = 1
		addImageTweens(buttonImage, tweenInfoQuick, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
		table.insert(tweensForFadeIn, TweenService:Create(buttonImage, tweenInfoQuick, { BackgroundTransparency = buttonImageBackgroundTransparency }))
	end

	local function setupIconTweens()
		local iconBackgroundTransparency = icon.BackgroundTransparency
		icon.BackgroundTransparency = 1
		addImageTweens(icon, tweenInfoQuick, tweensForButtonHoldBegin, tweensForButtonHoldEnd, tweensForFadeOut, tweensForFadeIn)
		table.insert(tweensForFadeIn, TweenService:Create(icon, tweenInfoQuick, { BackgroundTransparency = iconBackgroundTransparency }))
	end

	if inputType == Enum.ProximityPromptInputType.Gamepad then
		if GAMEPAD_BUTTON_IMAGE[prompt.GamepadKeyCode] then
			setupIconTweens()
			icon.Image = GAMEPAD_BUTTON_IMAGE[prompt.GamepadKeyCode]
			buttonText.Visible = false
			buttonImage.Visible = false
			icon.Visible = true
		end
	elseif inputType == Enum.ProximityPromptInputType.Touch then
		setupButtonImageTweens()
		buttonImage.Image = "rbxasset://textures/ui/Controls/TouchTapIcon.png"
		buttonText.Visible = false
		icon.Visible = false
		buttonImage.Visible = true
	else
		setupButtonImageTweens()
		buttonImage.Visible = true

		local buttonTextString = UserInputService:GetStringForKeyCode(prompt.KeyboardKeyCode)
		local buttonTextImage = KEYBOARD_BUTTON_IMAGE[prompt.KeyboardKeyCode]
		if buttonTextImage == nil then
			buttonTextImage = KEYBOARD_BUTTON_ICON_MAPPING[buttonTextString]
		end

		if buttonTextImage == nil then
			local keyCodeMappedText = KEY_CODE_TO_TEXT_MAPPING[prompt.KeyboardKeyCode]
			if keyCodeMappedText then
				buttonTextString = keyCodeMappedText
			end
		end

		if buttonTextImage then
			setupIconTweens()
			icon.Image = buttonTextImage
			buttonText.Visible = false
			icon.Visible = true
		elseif buttonTextString ~= nil and buttonTextString ~= "" then
			if string.len(buttonTextString) > 2 then
				buttonText.TextSize = math.round(buttonText.TextSize * 6 / 7)
			end
			setupButtonTextTweens()
			buttonText.Text = buttonTextString
			icon.Visible = false
			buttonText.Visible = true
		else
			warn("[ProximityPromptCustomizer] Unsupported keycode for prompt " .. prompt:GetFullName() .. ": " .. tostring(prompt.KeyboardKeyCode))
			promptUI:Destroy()
			return nil
		end
	end

	local buttonDown = false
	if inputType == Enum.ProximityPromptInputType.Touch or prompt.ClickablePrompt then
		parts.textButton.InputBegan:Connect(function(input)
			if (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1)
				and input.UserInputState ~= Enum.UserInputState.Change then
				prompt:InputHoldBegin()
				buttonDown = true
			end
		end)
		parts.textButton.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				if buttonDown then
					buttonDown = false
					prompt:InputHoldEnd()
				end
			end
		end)
		promptUI.Active = true
	end

	if prompt.HoldDuration > 0 and setUpCircularProgressBar(progressBar) then
		table.insert(tweensForButtonHoldBegin, TweenService:Create(progressBar.Progress, tweenInfoInFullDuration, { Value = 1 }))
		table.insert(tweensForButtonHoldEnd, TweenService:Create(progressBar.Progress, tweenInfoInstant, { Value = 0 }))
	end

	local holdBeganConnection
	local holdEndedConnection
	if prompt.HoldDuration > 0 then
		holdBeganConnection = prompt.PromptButtonHoldBegan:Connect(function()
			for _, tween in ipairs(tweensForButtonHoldBegin) do
				tween:Play()
			end
		end)

		holdEndedConnection = prompt.PromptButtonHoldEnded:Connect(function()
			for _, tween in ipairs(tweensForButtonHoldEnd) do
				tween:Play()
			end
		end)
	end

	local triggeredConnection = prompt.Triggered:Connect(function()
		for _, tween in ipairs(tweensForFadeOut) do
			tween:Play()
		end
	end)

	local triggerEndedConnection = prompt.TriggerEnded:Connect(function()
		for _, tween in ipairs(tweensForFadeIn) do
			tween:Play()
		end
	end)

	local function updateUIFromPrompt()
		actionText.Text = prompt.ActionText
		actionText.AutoLocalize = prompt.AutoLocalize
		actionText.RootLocalizationTable = prompt.RootLocalizationTable
		if objectText then
			objectText.Text = prompt.ObjectText
			objectText.AutoLocalize = prompt.AutoLocalize
			objectText.RootLocalizationTable = prompt.RootLocalizationTable
		end
	end

	local changedConnection = prompt.Changed:Connect(function()
		RuntimeGuard.Run("ProximityPromptCustomizer.UpdatePrompt", updateUIFromPrompt)
	end)
	RuntimeGuard.Run("ProximityPromptCustomizer.InitialUpdatePrompt", updateUIFromPrompt)

	local function updatePriceText()
		if not priceText then
			return
		end
		local price = tonumber(prompt:GetAttribute(PRICE_ATTRIBUTE))
		if not price then
			priceText.Visible = false
			return
		end
		local currency = tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Currency)) or 0
		priceText.Text = NumberFormatter.Currency(price)
		priceText.TextColor3 = currency >= price and PRICE_AFFORDABLE_COLOR or PRICE_UNAFFORDABLE_COLOR
		priceText.Visible = true
	end

	local priceAttributeConnection = nil
	local priceCurrencyConnection = nil
	if priceText then
		priceAttributeConnection = RuntimeGuard.Connect(prompt:GetAttributeChangedSignal(PRICE_ATTRIBUTE), "ProximityPromptCustomizer.PriceChanged", updatePriceText)
		priceCurrencyConnection = PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, function()
			RuntimeGuard.Run("ProximityPromptCustomizer.PriceCurrencyChanged", updatePriceText)
		end)
		RuntimeGuard.Run("ProximityPromptCustomizer.InitialUpdatePrice", updatePriceText)
	end

	local promptOffset = prompt:GetAttribute(STUDS_OFFSET_ATTRIBUTE)
	if typeof(promptOffset) == "Vector3" then
		promptUI.StudsOffset += promptOffset
	end
	promptUI.Adornee = prompt.Parent
	promptUI.Parent = playerGui

	for _, tween in ipairs(tweensForFadeIn) do
		tween:Play()
	end

	return function()
		if holdBeganConnection then
			holdBeganConnection:Disconnect()
		end
		if holdEndedConnection then
			holdEndedConnection:Disconnect()
		end
		triggeredConnection:Disconnect()
		triggerEndedConnection:Disconnect()
		changedConnection:Disconnect()
		if priceAttributeConnection then
			priceAttributeConnection:Disconnect()
		end
		if priceCurrencyConnection then
			priceCurrencyConnection:Disconnect()
		end

		-- Hide instantly; defer the Destroy so in-flight deferred signals and
		-- tweens finish against a live instance.
		promptUI.Enabled = false

		task.wait(PROMPT_DESTROY_DELAY_SECONDS)
		promptUI:Destroy()
	end
end

function ProximityPromptCustomizer.start()
	RuntimeGuard.Connect(ProximityPromptService.PromptShown, "ProximityPromptCustomizer.PromptShown", function(prompt, inputType)
		if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
			return
		end

		local cleanup = createPrompt(prompt, inputType)
		if not cleanup then
			return
		end

		-- PromptHidden never fires for a prompt destroyed while shown (Destroy
		-- disconnects its signals), so listen for Destroying as well or the
		-- cloned billboard and its connections leak in PlayerGui.
		local hiddenConnection = nil
		local destroyingConnection = nil
		local cleanedUp = false
		local function runCleanup()
			if cleanedUp then
				return
			end
			cleanedUp = true
			if hiddenConnection then
				hiddenConnection:Disconnect()
				hiddenConnection = nil
			end
			if destroyingConnection then
				destroyingConnection:Disconnect()
				destroyingConnection = nil
			end
			cleanup()
		end

		hiddenConnection = RuntimeGuard.Connect(prompt.PromptHidden, "ProximityPromptCustomizer.PromptHidden", runCleanup)
		destroyingConnection = RuntimeGuard.Connect(prompt.Destroying, "ProximityPromptCustomizer.PromptDestroying", runCleanup)
		if prompt.Parent == nil then
			-- Destroyed before this handler ran; neither signal will fire.
			runCleanup()
		end
	end)
end

return ProximityPromptCustomizer
