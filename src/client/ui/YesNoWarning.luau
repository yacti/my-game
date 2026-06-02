local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))

local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local YesNoWarning = {}

local TEMPLATE_NAME = "YesNoWarning"
local TEMPLATE_WAIT_SECONDS = 10

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

local function cloneTemplate(playerGui)
	local uiFolder = ReplicatedStorage:WaitForChild("UI", TEMPLATE_WAIT_SECONDS)
	if not uiFolder then
		warn("[YesNoWarning] Missing ReplicatedStorage.UI; warning prompts disabled")
		return nil
	end

	local template = uiFolder:WaitForChild(TEMPLATE_NAME, TEMPLATE_WAIT_SECONDS)
	if not (template and template:IsA("GuiObject")) then
		warn("[YesNoWarning] Missing ReplicatedStorage.UI.YesNoWarning GuiObject")
		return nil
	end

	local hud = playerGui:WaitForChild("HUD", TEMPLATE_WAIT_SECONDS)
	if not (hud and hud:IsA("ScreenGui")) then
		warn("[YesNoWarning] Missing PlayerGui.HUD ScreenGui")
		return nil
	end

	local existing = findDescendant(hud, TEMPLATE_NAME, "GuiObject")
	if existing then
		existing:Destroy()
	end

	local clone = template:Clone()
	clone.Visible = false
	clone.Parent = hud
	return clone
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
			rarityConnection = RunService.RenderStepped:Connect(function()
				setItemColor(Rarities.ColorFor(rarity, os.clock()) or Rarities.ColorFor(Rarities.Common))
			end)
		end
	else
		setItemColor(Rarities.ColorFor(Rarities.Common))
	end
end

local function finish(result, reason)
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
		task.spawn(callback, result == true, reason)
	end

	if not frame then
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

function YesNoWarning.start()
	if started then
		return ready
	end
	started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	frame = cloneTemplate(playerGui)
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

	yesButton.Activated:Connect(function()
		finish(true, "yes")
	end)
	noButton.Activated:Connect(function()
		finish(false, "no")
	end)
	closeButton.Activated:Connect(function()
		finish(false, "closed")
	end)

	ready = true
	return true
end

function YesNoWarning.Prompt(options, callback)
	if not YesNoWarning.start() then
		return false
	end

	if activePrompt then
		finish(false, "replaced")
	end

	activePrompt = {
		callback = callback,
	}
	render(options)
	transitionToken += 1
	if panelState then
		UiEffects.PlayOpen(frame, panelState)
	else
		frame.Visible = true
	end
	return true
end

function YesNoWarning.Cancel(reason)
	finish(false, reason or "cancelled")
end

return YesNoWarning
