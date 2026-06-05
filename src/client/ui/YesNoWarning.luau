local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local YesNoWarning = {}

local TEMPLATE_NAME = "YesNoWarning"

local started = false
local ready = false
local frame = nil
local panelState = nil
local descriptionLabel = nil
local itemLabel = nil
local titleLabel = nil
local yesButton = nil
local noButton = nil
local closeButton = nil
local activePrompt = nil
local pendingResult = false
local pendingReason = nil
local rarityConnection = nil
local transitionToken = 0

local function findDescendant(root, name, className)
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

local function disconnectRarity()
	if rarityConnection then
		rarityConnection:Disconnect()
		rarityConnection = nil
	end
end

local function setText(root, text)
	if root then
		UiEffects.SetTextStack(root, text or "")
	end
end

local function setItemColor(color)
	if itemLabel then
		itemLabel.TextColor3 = color
	end
end

local function getFrame()
	local frame = MenuGui.GetFrame(TEMPLATE_NAME, "YesNoWarning")
	if frame then
		frame.Visible = false
	end
	return frame
end

local function render(options)
	options = options or {}
	setText(titleLabel, options.title or "Warning")
	setText(descriptionLabel, options.question or options.text or "")
	setText(itemLabel, options.itemText or options.itemName or "")
	setText(yesButton, options.yesText or "Yes")
	setText(noButton, options.noText or "No")

	if itemLabel then
		itemLabel.Visible = (options.itemText or options.itemName or "") ~= ""
	end

	disconnectRarity()
	local rarity = options.itemRarity
	local color = options.itemColor
	if typeof(color) == "Color3" then
		setItemColor(color)
	elseif type(rarity) == "string" and Rarities.Get(rarity) then
		setItemColor(Rarities.ColorFor(rarity, os.clock()) or Rarities.ColorFor(Rarities.Common))
		if Rarities.Get(rarity).Animated then
			rarityConnection = RuntimeGuard.Connect(RunService.RenderStepped, "YesNoWarning.RarityRender", function()
				if not activePrompt or not frame or not frame.Parent or not itemLabel or not itemLabel.Parent then
					disconnectRarity()
					return
				end
				setItemColor(Rarities.ColorFor(rarity, os.clock()) or Rarities.ColorFor(Rarities.Common))
			end)
		end
	else
		setItemColor(Rarities.ColorFor(Rarities.Common))
	end
end

local function finish(result, reason, instant)
	if not activePrompt then
		return
	end

	local prompt = activePrompt
	activePrompt = nil
	disconnectRarity()
	transitionToken += 1
	local token = transitionToken

	local callback = prompt.callback
	if callback then
		RuntimeGuard.Spawn("YesNoWarning.Callback", callback, result == true, reason)
	end

	if not frame then
		return
	end
	if instant then
		frame.Visible = false
		if panelState then
			frame.Position = panelState.closedPosition
			frame.Size = panelState.closedSize
		end
		return
	end
	if panelState then
		UiEffects.PlayClose(frame, panelState, function()
			if transitionToken == token and not activePrompt then
				frame.Visible = false
			end
		end)
	else
		frame.Visible = false
	end
end

local function showPanel()
	if panelState then
		UiEffects.PlayOpen(frame, panelState)
	else
		frame.Visible = true
	end
end

local function hidePanel(switching)
	local result = pendingResult == true
	local reason = pendingReason or (switching and "switched" or "closed")
	pendingResult = false
	pendingReason = nil
	finish(result, reason, switching == true)
end

function YesNoWarning.start()
	if started then
		return ready
	end
	started = true

	frame = getFrame()
	if not frame then
		return false
	end

	descriptionLabel = findDescendant(frame, "Description", "TextLabel")
	itemLabel = findDescendant(frame, "Item", "TextLabel")
	titleLabel = findDescendant(frame, "Title", "TextLabel")
	yesButton = findDescendant(frame, "Yes", "GuiButton")
	noButton = findDescendant(frame, "No", "GuiButton")
	closeButton = findDescendant(frame, "CloseButton", "GuiButton")

	if not (descriptionLabel and itemLabel and yesButton and noButton and closeButton) then
		warn("[YesNoWarning] YesNoWarning UI is missing Description, Item, Yes, No, or CloseButton")
		frame.Visible = false
		return false
	end

	UiEffects.BindButton(yesButton)
	UiEffects.BindButton(noButton)
	UiEffects.BindButton(closeButton)
	panelState = UiEffects.PreparePanel(frame)
	frame.Visible = false

	MenuGui.RegisterPanel(TEMPLATE_NAME, {
		open = showPanel,
		close = hidePanel,
	})

	RuntimeGuard.Connect(yesButton.Activated, "YesNoWarning.YesActivated", function()
		pendingResult = true
		pendingReason = "yes"
		MenuGui.ClosePanel(TEMPLATE_NAME)
	end)
	RuntimeGuard.Connect(noButton.Activated, "YesNoWarning.NoActivated", function()
		pendingResult = false
		pendingReason = "no"
		MenuGui.ClosePanel(TEMPLATE_NAME)
	end)
	RuntimeGuard.Connect(closeButton.Activated, "YesNoWarning.CloseActivated", function()
		pendingResult = false
		pendingReason = "closed"
		MenuGui.ClosePanel(TEMPLATE_NAME)
	end)

	ready = true
	return true
end

function YesNoWarning.Prompt(options, callback)
	if not YesNoWarning.start() then
		return false
	end

	if activePrompt then
		local prompt = activePrompt
		activePrompt = nil
		disconnectRarity()
		if prompt.callback then
			RuntimeGuard.Spawn("YesNoWarning.Callback", prompt.callback, false, "replaced")
		end
	end

	activePrompt = {
		callback = callback,
	}
	pendingResult = false
	pendingReason = nil
	render(options)
	return MenuGui.OpenPanel(TEMPLATE_NAME)
end

function YesNoWarning.Cancel(reason)
	pendingResult = false
	pendingReason = reason or "cancelled"
	MenuGui.ClosePanel(TEMPLATE_NAME)
end

return YesNoWarning
