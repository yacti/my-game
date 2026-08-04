local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local HoverOver = {}

local HUD_NAME = "HUD"
local TEMPLATE_NAME = "HoverOver"
local RUNTIME_NAME = "__HoverOver"
local HOVER_Z_INDEX = 9999
local HOVER_TEXT_Z_INDEX = 10000
local POINTER_OFFSET = Vector2.new(6, 6)
local TAP_MOVE_THRESHOLD = 12
local SHOW_XP_LINE = false

local player = Players.LocalPlayer
local bindings = {}
local popup = nil
local itemNameLabel = nil
local rarityLabel = nil
local xpLabel = nil
local baseFrameSize = nil
local baseLabelSizes = nil
local warnedMissing = false
local started = false
local activeBinding = nil
local activeAnchor = nil
local activeMode = nil
local activeRarity = nil
local activePoint = nil
local rarityConnection = nil
local visibilityConnections = {}
local touchCandidate = nil

local function disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

local function descendant(root, name, className)
	for _, item in ipairs(root and root:GetDescendants() or {}) do
		if item.Name == name and (not className or item:IsA(className)) then
			return item
		end
	end
	return nil
end

local function warnMissing(message)
	if warnedMissing then
		return
	end
	warn(message)
	warnedMissing = true
end

local function sourceTemplate()
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local hud = uiFolder and uiFolder:FindFirstChild(HUD_NAME)
	local template = hud and hud:FindFirstChild(TEMPLATE_NAME)
	if template and template:IsA("GuiObject") then
		return template
	end
	warnMissing("[HoverOver] Missing ReplicatedStorage.UI.HUD.HoverOver GuiObject")
	return nil
end

local function applyZIndex(root)
	local function zIndexFor(guiObject)
		if guiObject:IsA("TextLabel") or guiObject:IsA("TextButton") then
			return HOVER_TEXT_Z_INDEX
		end
		return HOVER_Z_INDEX
	end
	if root:IsA("GuiObject") then
		root.ZIndex = zIndexFor(root)
	end
	for _, item in ipairs(root:GetDescendants()) do
		if item:IsA("GuiObject") then
			item.ZIndex = zIndexFor(item)
		end
	end
end

local function ensurePopup()
	if popup and popup.Parent then
		applyZIndex(popup)
		return popup
	end

	local template = sourceTemplate()
	if not template then
		return nil
	end

	local menu = MenuGui.Get("HoverOver")
	if not menu then
		return nil
	end

	local existing = menu:FindFirstChild(RUNTIME_NAME)
	if existing and existing:IsA("GuiObject") then
		popup = existing
	else
		popup = template:Clone()
		popup.Name = RUNTIME_NAME
		popup.Parent = menu
	end

	popup.AnchorPoint = Vector2.new(0, 0)
	popup.Visible = false
	popup.Selectable = false
	popup.Active = false
	applyZIndex(popup)

	itemNameLabel = descendant(popup, "ItemName", "TextLabel")
	rarityLabel = descendant(popup, "Rarity", "TextLabel")
	xpLabel = descendant(popup, "XP", "TextLabel")
	if not (itemNameLabel and rarityLabel) then
		warnMissing("[HoverOver] HoverOver template missing Holder.ItemName or Holder.Rarity TextLabel")
		popup.Visible = false
		return nil
	end

	-- Base sizes come from the pristine template (not the runtime clone, which
	-- may have been shrunk by the old resizing logic).
	baseFrameSize = template.Size
	baseLabelSizes = {}
	local labelTemplateNames = { [itemNameLabel] = "ItemName", [rarityLabel] = "Rarity" }
	if xpLabel then
		labelTemplateNames[xpLabel] = "XP"
	end
	for label, templateName in pairs(labelTemplateNames) do
		local templateLabel = descendant(template, templateName, "TextLabel")
		baseLabelSizes[label] = templateLabel and templateLabel.Size or label.Size
	end

	RuntimeGuard.Connect(popup.Destroying, "HoverOver.PopupDestroying", function()
		HoverOver.Hide()
		popup = nil
		itemNameLabel = nil
		rarityLabel = nil
		xpLabel = nil
	end)

	return popup
end

-- Only a name-only payload resizes the popup: it shrinks to the ItemName
-- line's share of the template so a lone line isn't floating in a tall frame.
-- Any payload with more lines keeps the template sizes as-is.
local function applyLineLayout(showRarity, showXP)
	if not popup then
		return
	end
	if rarityLabel then
		rarityLabel.Visible = showRarity
	end
	if xpLabel then
		xpLabel.Visible = showXP
	end
	if not (baseFrameSize and baseLabelSizes) then
		return
	end
	if showRarity or showXP then
		popup.Size = baseFrameSize
		for label, size in pairs(baseLabelSizes) do
			label.Size = size
		end
		return
	end
	local total = 0
	local visible = 0
	for label, size in pairs(baseLabelSizes) do
		total += size.Y.Scale
		if label == itemNameLabel then
			visible += size.Y.Scale
		end
	end
	local fraction = (total > 0 and visible > 0) and visible / total or 1
	popup.Size = UDim2.new(
		baseFrameSize.X.Scale,
		baseFrameSize.X.Offset,
		baseFrameSize.Y.Scale * fraction,
		baseFrameSize.Y.Offset * fraction
	)
	for label, size in pairs(baseLabelSizes) do
		label.Size = UDim2.new(size.X.Scale, size.X.Offset, size.Y.Scale / fraction, size.Y.Offset)
	end
end

local function screenBounds()
	local playerGui = player:FindFirstChild("PlayerGui")
	local menu = playerGui and playerGui:FindFirstChild("Menu")
	if menu and menu:IsA("ScreenGui") then
		return menu.AbsoluteSize
	end
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1920, 1080)
end

local function menuGuiInset()
	local playerGui = player:FindFirstChild("PlayerGui")
	local menu = playerGui and playerGui:FindFirstChild("Menu")
	if menu and menu:IsA("ScreenGui") and menu.IgnoreGuiInset then
		return Vector2.zero
	end
	local topLeftInset = GuiService:GetGuiInset()
	return Vector2.new(topLeftInset.X, topLeftInset.Y)
end

local function toMenuPoint(screenPoint)
	return screenPoint - menuGuiInset()
end

local function clampPoint(point)
	local frame = ensurePopup()
	if not frame then
		return point
	end

	local bounds = screenBounds()
	local size = frame.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		size = Vector2.new(180, 56)
	end

	return Vector2.new(
		math.clamp(point.X, 0, math.max(bounds.X - size.X, 0)),
		math.clamp(point.Y, 0, math.max(bounds.Y - size.Y, 0))
	)
end

local function positionPopup(point)
	local frame = ensurePopup()
	if not (frame and point) then
		return
	end
	local target = clampPoint(point + POINTER_OFFSET)
	frame.Position = UDim2.fromOffset(math.floor(target.X), math.floor(target.Y))
end

local function anchorBottomRight(guiObject)
	return toMenuPoint(guiObject.AbsolutePosition + guiObject.AbsoluteSize)
end

local function applyColorToLabelStack(root, color)
	if not (root and color) then
		return
	end
	local function apply(label)
		if not (label:IsA("TextLabel") or label:IsA("TextButton")) then
			return
		end
		label.TextColor3 = color
		local gradient = label:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = ColorSequence.new(color)
		end
	end
	apply(root)
	for _, item in ipairs(root:GetDescendants()) do
		apply(item)
	end
end

local function disconnectRarityRender()
	if rarityConnection then
		rarityConnection:Disconnect()
		rarityConnection = nil
	end
end

local function refreshRarityColor()
	if not (popup and rarityLabel and activeRarity) then
		return
	end
	local color = Rarities.ColorFor(activeRarity, os.clock()) or Rarities.ColorFor(Rarities.Common)
	applyColorToLabelStack(rarityLabel, color)
end

local function normalizedPayload(payload)
	if type(payload) ~= "table" then
		return nil
	end
	local name = tostring(payload.name or payload.Name or payload.itemName or payload.ItemName or "")
	if name == "" then
		return nil
	end

	-- `subtitle` takes over the Rarity line with literal text, for rewards that
	-- have no rarity to show: a cash amount, "Reward" for a timeskip. It exists
	-- because `rarity` cannot carry arbitrary text -- anything that is not a
	-- real rarity is coerced to Common below, which would render "$6,250" as
	-- "Common". Kept as a separate field so that coercion still protects the
	-- rarity path from typos.
	local subtitle = payload.subtitle or payload.Subtitle
	if type(subtitle) ~= "string" or subtitle == "" then
		subtitle = nil
	end
	local subtitleColor = payload.subtitleColor or payload.SubtitleColor
	if typeof(subtitleColor) ~= "Color3" then
		subtitleColor = nil
	end

	local rarity = payload.rarity or payload.Rarity
	if rarity ~= nil and (type(rarity) ~= "string" or not Rarities.IsValid(rarity)) then
		rarity = Rarities.Common
	end
	local xp = payload.xp or payload.Xp or payload.XP
	if not SHOW_XP_LINE or type(xp) ~= "string" or xp == "" then
		xp = nil
	end
	return {
		name = name,
		rarity = rarity,
		subtitle = subtitle,
		subtitleColor = subtitleColor,
		xp = xp,
	}
end

local function callPayloadProvider(binding)
	if not binding then
		return nil
	end
	local provider = binding.payloadProvider
	if type(provider) == "function" then
		local ok, payload = RuntimeGuard.Run("HoverOver.PayloadProvider", provider, binding.guiObject)
		if ok then
			return normalizedPayload(payload)
		end
	elseif type(provider) == "table" then
		return normalizedPayload(provider)
	end
	return nil
end

local function disconnectVisibilityConnections()
	for _, connection in ipairs(visibilityConnections) do
		connection:Disconnect()
	end
	table.clear(visibilityConnections)
end

local function isVisibleInTree(guiObject)
	local current = guiObject
	while current do
		if current:IsA("ScreenGui") then
			return current.Enabled
		elseif current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end
	return false
end

local function watchActiveAnchor(anchor)
	disconnectVisibilityConnections()
	activeAnchor = anchor
	if not anchor then
		return
	end

	local current = anchor
	while current do
		if current:IsA("ScreenGui") then
			visibilityConnections[#visibilityConnections + 1] = RuntimeGuard.Connect(current:GetPropertyChangedSignal("Enabled"), "HoverOver.ScreenGuiEnabled", function()
				if activeAnchor == anchor and not isVisibleInTree(anchor) then
					HoverOver.Hide()
				end
			end)
			break
		elseif current:IsA("GuiObject") then
			visibilityConnections[#visibilityConnections + 1] = RuntimeGuard.Connect(current:GetPropertyChangedSignal("Visible"), "HoverOver.VisibleChanged", function()
				if activeAnchor == anchor and not isVisibleInTree(anchor) then
					HoverOver.Hide()
				end
			end)
		end
		current = current.Parent
	end

	visibilityConnections[#visibilityConnections + 1] = RuntimeGuard.Connect(anchor.Destroying, "HoverOver.AnchorDestroying", function()
		if activeAnchor == anchor then
			HoverOver.Hide()
		end
	end)
	visibilityConnections[#visibilityConnections + 1] = RuntimeGuard.Connect(anchor.AncestryChanged, "HoverOver.AnchorAncestryChanged", function()
		if activeAnchor == anchor and not anchor:IsDescendantOf(game) then
			HoverOver.Hide()
		end
	end)
end

function HoverOver.Hide()
	disconnectRarityRender()
	disconnectVisibilityConnections()
	activeBinding = nil
	activeAnchor = nil
	activeMode = nil
	activeRarity = nil
	activePoint = nil
	if popup then
		popup.Visible = false
	end
end

function HoverOver.Show(payload, anchorGuiOrPosition, mode)
	payload = normalizedPayload(payload)
	local frame = ensurePopup()
	if not (payload and frame and itemNameLabel and rarityLabel) then
		return false
	end

	-- A subtitle occupies the rarity line, so the two are mutually exclusive.
	local secondLine = payload.subtitle or payload.rarity
	UiEffects.SetTextStack(itemNameLabel, payload.name)
	UiEffects.SetTextStack(rarityLabel, secondLine or "")
	if xpLabel then
		UiEffects.SetTextStack(xpLabel, payload.xp or "")
	end
	applyLineLayout(secondLine ~= nil, payload.xp ~= nil and xpLabel ~= nil)

	disconnectRarityRender()
	if payload.subtitle then
		-- Free text has no rarity to animate. Clearing activeRarity also stops
		-- refreshRarityColor from repainting this line on a later frame.
		activeRarity = nil
		applyColorToLabelStack(rarityLabel, payload.subtitleColor or Color3.fromRGB(255, 255, 255))
	else
		activeRarity = payload.rarity
		refreshRarityColor()
		local definition = activeRarity and Rarities.Get(activeRarity) or nil
		if definition and definition.Animated then
			rarityConnection = RuntimeGuard.Connect(RunService.RenderStepped, "HoverOver.RarityRender", refreshRarityColor)
		end
	end

	if typeof(anchorGuiOrPosition) == "Vector2" then
		activePoint = toMenuPoint(anchorGuiOrPosition)
	elseif typeof(anchorGuiOrPosition) == "Instance" and anchorGuiOrPosition:IsA("GuiObject") then
		activePoint = anchorBottomRight(anchorGuiOrPosition)
	else
		activePoint = toMenuPoint(UserInputService:GetMouseLocation())
	end

	activeMode = mode or "manual"
	frame.Visible = true
	positionPopup(activePoint)
	task.defer(function()
		if frame.Parent and frame.Visible and activePoint then
			positionPopup(activePoint)
		end
	end)

	return true
end

local function showBinding(binding, point, mode)
	if not (binding and binding.guiObject and binding.guiObject.Parent) then
		return false
	end
	if not isVisibleInTree(binding.guiObject) then
		return false
	end
	local payload = callPayloadProvider(binding)
	if not payload then
		return false
	end
	activeBinding = binding
	watchActiveAnchor(binding.guiObject)
	return HoverOver.Show(payload, point or binding.guiObject, mode)
end

local function bindingForGuiObject(guiObject)
	local current = guiObject
	while current do
		local binding = bindings[current]
		if binding then
			return binding
		end
		current = current.Parent
	end
	return nil
end

local function bindingAtPosition(position)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil
	end
	local objects = playerGui:GetGuiObjectsAtPosition(position.X, position.Y)
	for _, object in ipairs(objects) do
		if popup and object:IsDescendantOf(popup) then
			continue
		end
		local binding = bindingForGuiObject(object)
		if binding then
			return binding
		end
	end
	return nil
end

local function pointerPosition(input)
	if input and input.Position then
		return Vector2.new(input.Position.X, input.Position.Y)
	end
	return UserInputService:GetMouseLocation()
end

local function handleSelectionChanged()
	local selected = GuiService.SelectedObject
	local binding = selected and bindingForGuiObject(selected) or nil
	if binding then
		showBinding(binding, binding.guiObject, "selection")
	elseif activeMode == "selection" then
		HoverOver.Hide()
	end
end

local function startGlobalInput()
	RuntimeGuard.Connect(UserInputService.InputBegan, "HoverOver.InputBegan", function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local position = pointerPosition(input)
		touchCandidate = {
			input = input,
			start = position,
			last = position,
			binding = bindingAtPosition(position),
			moved = false,
		}
	end)

	RuntimeGuard.Connect(UserInputService.InputChanged, "HoverOver.InputChanged", function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and activeMode == "mouse" and activeBinding then
			activePoint = toMenuPoint(UserInputService:GetMouseLocation())
			positionPopup(activePoint)
			return
		end

		if not (touchCandidate and touchCandidate.input == input) then
			return
		end
		local position = pointerPosition(input)
		touchCandidate.last = position
		if (position - touchCandidate.start).Magnitude > TAP_MOVE_THRESHOLD then
			touchCandidate.moved = true
		end
	end)

	RuntimeGuard.Connect(UserInputService.InputEnded, "HoverOver.InputEnded", function(input)
		if not (touchCandidate and touchCandidate.input == input) then
			return
		end
		local candidate = touchCandidate
		touchCandidate = nil
		local position = pointerPosition(input)
		if candidate.moved or (position - candidate.start).Magnitude > TAP_MOVE_THRESHOLD then
			return
		end
		local binding = bindingAtPosition(position) or candidate.binding
		if binding then
			showBinding(binding, position, "touch")
		else
			HoverOver.Hide()
		end
	end)

	RuntimeGuard.Connect(GuiService:GetPropertyChangedSignal("SelectedObject"), "HoverOver.SelectedObjectChanged", handleSelectionChanged)
end

local function disconnectBinding(binding)
	for _, connection in ipairs(binding.connections) do
		disconnect(connection)
	end
	table.clear(binding.connections)
	if binding.guiObject then
		if binding.originalSelectable ~= nil then
			binding.guiObject.Selectable = binding.originalSelectable
		end
		if activeBinding == binding then
			HoverOver.Hide()
		end
	end
end

function HoverOver.Bind(guiObject, payloadProvider)
	if not (guiObject and guiObject:IsA("GuiObject")) then
		return nil
	end

	local existing = bindings[guiObject]
	if existing then
		disconnectBinding(existing)
	end

	local binding = {
		guiObject = guiObject,
		payloadProvider = payloadProvider,
		originalSelectable = guiObject.Selectable,
		connections = {},
	}
	bindings[guiObject] = binding
	guiObject.Selectable = true

	binding.connections[#binding.connections + 1] = RuntimeGuard.Connect(guiObject.MouseEnter, "HoverOver.MouseEnter", function()
		showBinding(binding, UserInputService:GetMouseLocation(), "mouse")
	end)
	binding.connections[#binding.connections + 1] = RuntimeGuard.Connect(guiObject.MouseLeave, "HoverOver.MouseLeave", function()
		if activeBinding == binding and activeMode == "mouse" then
			HoverOver.Hide()
		end
	end)
	binding.connections[#binding.connections + 1] = RuntimeGuard.Connect(guiObject.Destroying, "HoverOver.BindingDestroying", function()
		if bindings[guiObject] == binding then
			bindings[guiObject] = nil
		end
		disconnectBinding(binding)
	end)

	return function()
		if bindings[guiObject] == binding then
			bindings[guiObject] = nil
		end
		disconnectBinding(binding)
	end
end

function HoverOver.start()
	if started then
		return
	end
	started = true
	ensurePopup()
	startGlobalInput()
end

return HoverOver
