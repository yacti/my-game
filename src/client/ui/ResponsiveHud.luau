local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local ResponsiveHud = {}

local BASE_SHORT_SIDE = 853
local SATCHEL_PADDING_PIXELS = 12
local FALLBACK_SATCHEL_RESERVED_PIXELS = 90

local records = {}
local scheduleUpdate = nil

local function disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

local function viewportSize()
	local camera = Workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(BASE_SHORT_SIDE, BASE_SHORT_SIDE)
end

local function strokeDivisorFor(viewport)
	local shortSide = math.min(viewport.X, viewport.Y)
	if type(shortSide) ~= "number" or shortSide <= 0 then
		return 1
	end
	return math.clamp(math.round((BASE_SHORT_SIDE / shortSide) * 2) / 2, 1, 3)
end

local function playerGuiForHud(hud)
	local parent = hud and hud.Parent
	if parent and parent:IsA("PlayerGui") then
		return parent
	end
	local player = Players.LocalPlayer
	return player and player:FindFirstChildOfClass("PlayerGui") or nil
end

local function satchelHotbar(playerGui)
	local backpackGui = playerGui and playerGui:FindFirstChild("BackpackGui")
	local backpack = backpackGui and backpackGui:FindFirstChild("Backpack")
	local hotbar = backpack and backpack:FindFirstChild("Hotbar")
	return hotbar and hotbar:IsA("GuiObject") and hotbar or nil
end

local function disconnectHotbar(record)
	disconnect(record.hotbarSizeConnection)
	disconnect(record.hotbarPositionConnection)
	record.hotbarSizeConnection = nil
	record.hotbarPositionConnection = nil
	record.hotbar = nil
end

local function bindHotbar(record, hotbar)
	if record.hotbar == hotbar then
		return
	end

	disconnectHotbar(record)
	record.hotbar = hotbar
	if not hotbar then
		return
	end

	record.hotbarSizeConnection = RuntimeGuard.Connect(
		hotbar:GetPropertyChangedSignal("AbsoluteSize"),
		"ResponsiveHud.HotbarAbsoluteSize",
		function()
			scheduleUpdate(record)
		end
	)
	record.hotbarPositionConnection = RuntimeGuard.Connect(
		hotbar:GetPropertyChangedSignal("AbsolutePosition"),
		"ResponsiveHud.HotbarAbsolutePosition",
		function()
			scheduleUpdate(record)
		end
	)
end

local function fallbackAllowedBottom(hud)
	local hudBottom = hud.AbsolutePosition.Y + hud.AbsoluteSize.Y
	return hudBottom - FALLBACK_SATCHEL_RESERVED_PIXELS
end

local function satchelAllowedBottom(record)
	local playerGui = record.playerGui or playerGuiForHud(record.hud)
	record.playerGui = playerGui

	local hotbar = satchelHotbar(playerGui)
	bindHotbar(record, hotbar)
	if hotbar and hotbar.AbsoluteSize.Y > 0 then
		return hotbar.AbsolutePosition.Y - SATCHEL_PADDING_PIXELS
	end
	return fallbackAllowedBottom(record.hud)
end

local function basePosition(record, key, guiObject)
	local stored = record.basePositions[key]
	if stored then
		return stored
	end
	stored = guiObject.Position
	record.basePositions[key] = stored
	return stored
end

local function positionWithYOffset(position, offsetY)
	return UDim2.new(position.X.Scale, position.X.Offset, position.Y.Scale, position.Y.Offset + offsetY)
end

local function setOpenUdim2Attributes(instance, prefix, value)
	instance:SetAttribute(prefix .. "Scale", value.Scale)
	instance:SetAttribute(prefix .. "Offset", value.Offset)
end

local function writeOpenStateAttributes(instance, state)
	if not (instance and state) then
		return
	end
	setOpenUdim2Attributes(instance, "UiEffectsOpenX", state.openPosition.X)
	setOpenUdim2Attributes(instance, "UiEffectsOpenY", state.openPosition.Y)
	setOpenUdim2Attributes(instance, "UiEffectsOpenSizeX", state.openSize.X)
	setOpenUdim2Attributes(instance, "UiEffectsOpenSizeY", state.openSize.Y)
end

local function guiBottom(guiObject)
	return guiObject.AbsolutePosition.Y + guiObject.AbsoluteSize.Y
end

local function openUdim2(instance, prefix, fallback)
	local scale = instance:GetAttribute(prefix .. "Scale")
	local offset = instance:GetAttribute(prefix .. "Offset")
	if type(scale) == "number" and type(offset) == "number" then
		return UDim.new(scale, offset)
	end
	return fallback
end

local function openPosition(instance)
	local x = openUdim2(instance, "UiEffectsOpenX", instance.Position.X)
	local y = openUdim2(instance, "UiEffectsOpenY", instance.Position.Y)
	return UDim2.new(
		x.Scale,
		x.Offset,
		y.Scale,
		y.Offset
	)
end

local function openSize(instance)
	local x = openUdim2(instance, "UiEffectsOpenSizeX", instance.Size.X)
	local y = openUdim2(instance, "UiEffectsOpenSizeY", instance.Size.Y)
	return UDim2.new(
		x.Scale,
		x.Offset,
		y.Scale,
		y.Offset
	)
end

local function childOpenBottom(parent, child)
	local parentSize = parent.AbsoluteSize
	local position = openPosition(child)
	local size = openSize(child)
	local childHeight = parentSize.Y * size.Y.Scale + size.Y.Offset
	local childCenterY = parent.AbsolutePosition.Y + parentSize.Y * position.Y.Scale + position.Y.Offset
	return childCenterY - child.AnchorPoint.Y * childHeight + childHeight
end

local function rollButtonsVisibleBottom(rollButtons)
	local bottom = nil
	for _, childName in ipairs({ "UpgradeLuckFrame", "RollDropAreaFrame" }) do
		local child = rollButtons:FindFirstChild(childName)
		if child and child:IsA("GuiObject") then
			local childBottom = childOpenBottom(rollButtons, child)
			bottom = bottom and math.max(bottom, childBottom) or childBottom
		end
	end
	return bottom or guiBottom(rollButtons)
end

local function copyPanelState(state)
	if type(state) ~= "table" then
		return nil
	end
	return {
		openPosition = state.openPosition,
		openSize = state.openSize,
		closedPosition = state.closedPosition,
		closedSize = state.closedSize,
	}
end

local function panelContainerRect(panel)
	local parent = panel and panel.Parent
	if parent and parent:IsA("GuiObject") then
		return parent.AbsolutePosition, parent.AbsoluteSize
	end
	return Vector2.new(0, 0), viewportSize()
end

local function panelStateBottom(panel, state)
	if not (panel and state) then
		return nil
	end
	local parentPosition, parentSize = panelContainerRect(panel)
	local size = state.openSize
	local position = state.openPosition
	local height = parentSize.Y * size.Y.Scale + size.Y.Offset
	local centerY = parentPosition.Y + parentSize.Y * position.Y.Scale + position.Y.Offset
	return centerY - panel.AnchorPoint.Y * height + height
end

local function applyPanelStateShift(panel, state, baseState, offsetY)
	state.openPosition = positionWithYOffset(baseState.openPosition, offsetY)
	state.openSize = baseState.openSize
	state.closedPosition = positionWithYOffset(baseState.closedPosition, offsetY)
	state.closedSize = baseState.closedSize
	writeOpenStateAttributes(panel, state)
end

local function shiftAboveAllowedBottom(record, key, guiObject, allowedBottom, bottomFn)
	if not (guiObject and guiObject:IsA("GuiObject")) then
		return
	end

	local base = basePosition(record, key, guiObject)
	guiObject.Position = base

	if record.context.isTouch ~= true then
		return
	end
	if type(allowedBottom) ~= "number" then
		return
	end

	local bottom = bottomFn and bottomFn(guiObject) or guiBottom(guiObject)
	if bottom <= allowedBottom then
		return
	end

	local shift = math.ceil(bottom - allowedBottom)
	guiObject.Position = positionWithYOffset(base, -shift)
end

local function shiftPanelStateAboveAllowedBottom(record, panelRecord)
	local panel = panelRecord and panelRecord.panel
	local state = panelRecord and panelRecord.state
	local baseState = panelRecord and panelRecord.baseState
	if not (panel and panel:IsA("GuiObject") and state and baseState) then
		return
	end

	local offsetY = 0
	if record.context.isTouch == true and type(record.context.satchelAllowedBottom) == "number" then
		local bottom = panelStateBottom(panel, baseState)
		if bottom and bottom > record.context.satchelAllowedBottom then
			offsetY = -math.ceil(bottom - record.context.satchelAllowedBottom)
		end
	end
	applyPanelStateShift(panel, state, baseState, offsetY)
end

local function updateRollButtons(record)
	local rollButtons = record.hud:FindFirstChild("RollButtons")
	if not (rollButtons and rollButtons:IsA("GuiObject")) then
		return
	end

	shiftAboveAllowedBottom(record, "RollButtons", rollButtons, record.context.satchelAllowedBottom, rollButtonsVisibleBottom)
end

local function updateOnboarding(record)
	local onboarding = record.hud:FindFirstChild("Onboarding")
	if not (onboarding and onboarding:IsA("GuiObject")) then
		return
	end

	shiftAboveAllowedBottom(record, "Onboarding", onboarding, record.context.satchelAllowedBottom)
end

local function updateRegisteredPanels(record)
	for _, panelRecord in pairs(record.bottomShiftPanels) do
		shiftPanelStateAboveAllowedBottom(record, panelRecord)
	end
end

local adjustments = {
	updateRollButtons,
	updateOnboarding,
	updateRegisteredPanels,
}

local function computeContext(record)
	local viewport = viewportSize()
	local shortSide = math.min(viewport.X, viewport.Y)
	return {
		hud = record.hud,
		viewport = viewport,
		shortSide = shortSide,
		isTouch = UserInputService.TouchEnabled,
		strokeDivisor = strokeDivisorFor(viewport),
		satchelAllowedBottom = satchelAllowedBottom(record),
	}
end

local function updateRecord(record)
	if not (record.hud and record.hud.Parent) then
		return
	end

	record.context = computeContext(record)
	for _, adjustment in ipairs(adjustments) do
		adjustment(record)
	end
end

scheduleUpdate = function(record)
	if record.updateScheduled then
		return
	end
	record.updateScheduled = true
	task.defer(function()
		record.updateScheduled = false
		RuntimeGuard.Run("ResponsiveHud.Update", updateRecord, record)
	end)
end

local function bindCamera(record)
	local camera = Workspace.CurrentCamera
	if record.camera == camera and record.cameraViewportConnection then
		return
	end

	disconnect(record.cameraViewportConnection)
	record.cameraViewportConnection = nil
	record.camera = camera

	if camera then
		record.cameraViewportConnection = RuntimeGuard.Connect(
			camera:GetPropertyChangedSignal("ViewportSize"),
			"ResponsiveHud.CameraViewportSize",
			function()
				scheduleUpdate(record)
			end
		)
	end
	scheduleUpdate(record)
end

local function cleanup(record)
	for _, connection in ipairs(record.connections) do
		disconnect(connection)
	end
	disconnect(record.cameraViewportConnection)
	disconnectHotbar(record)
	for _, panelRecord in pairs(record.bottomShiftPanels) do
		disconnect(panelRecord.destroyingConnection)
	end
	records[record.hud] = nil
end

function ResponsiveHud.Bind(hud)
	if not (hud and hud:IsA("ScreenGui")) then
		return
	end
	if records[hud] then
		return
	end

	local record = {
		hud = hud,
		playerGui = playerGuiForHud(hud),
		basePositions = {},
		bottomShiftPanels = {},
		connections = {},
		context = {},
		updateScheduled = false,
	}
	records[hud] = record

	record.connections[#record.connections + 1] = RuntimeGuard.Connect(
		Workspace:GetPropertyChangedSignal("CurrentCamera"),
		"ResponsiveHud.CurrentCameraChanged",
		function()
			bindCamera(record)
		end
	)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(hud.Destroying, "ResponsiveHud.HudDestroying", function()
		cleanup(record)
	end)

	local playerGui = record.playerGui
	if playerGui then
		record.connections[#record.connections + 1] = RuntimeGuard.Connect(
			playerGui.DescendantAdded,
			"ResponsiveHud.PlayerGuiDescendantAdded",
			function(descendant)
				if descendant.Name == "BackpackGui" or descendant.Name == "Backpack" or descendant.Name == "Hotbar" then
					scheduleUpdate(record)
				end
			end
		)
	end

	bindCamera(record)
	scheduleUpdate(record)
end

function ResponsiveHud.RegisterBottomShiftPanel(hud, key, panel, panelState)
	if not (hud and hud:IsA("ScreenGui") and panel and panel:IsA("GuiObject")) then
		return
	end
	if type(panelState) ~= "table" then
		return
	end
	local record = records[hud]
	if not record then
		ResponsiveHud.Bind(hud)
		record = records[hud]
	end
	if not record then
		return
	end

	key = tostring(key or panel.Name)
	local existing = record.bottomShiftPanels[key]
	if existing then
		disconnect(existing.destroyingConnection)
	end

	record.bottomShiftPanels[key] = {
		panel = panel,
		state = panelState,
		baseState = copyPanelState(panelState),
		destroyingConnection = RuntimeGuard.Connect(panel.Destroying, "ResponsiveHud.BottomShiftPanelDestroying", function()
			local current = records[hud]
			if current then
				current.bottomShiftPanels[key] = nil
			end
		end),
	}
	RuntimeGuard.Run("ResponsiveHud.RegisterBottomShiftPanel.Update", updateRecord, record)
end

return ResponsiveHud
