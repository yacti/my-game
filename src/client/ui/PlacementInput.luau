local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlacementInput = {}

local DEFAULT_TAP_MOVE_THRESHOLD = 16
local MOVE_DRAG_DETECTOR_NAME = "__PlacementMoveDragDetector"
local GAMEPAD_REPEAT_START_DELAY = 0.22
local GAMEPAD_REPEAT_INTERVAL = 0.09
local GAMEPAD_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 10
local guiNavigationLockDepth = 0
local guiNavigationRestore = nil
local guiNavigationLocks = {}

PlacementInput.GamepadKeyCodes = {
	Move = Enum.KeyCode.DPadUp,
	Rotate = Enum.KeyCode.ButtonY,
	Confirm = Enum.KeyCode.ButtonR2,
	Cancel = Enum.KeyCode.ButtonB,
}

local function screenPositionFrom(value)
	local valueType = typeof(value)
	if valueType == "Vector2" then
		return value
	end
	if valueType == "Vector3" then
		return Vector2.new(value.X, value.Y)
	end
	if valueType == "InputObject" then
		return screenPositionFrom(value.Position)
	end
	if valueType == "Instance" and value:IsA("InputObject") then
		return screenPositionFrom(value.Position)
	end
	return nil
end

local function isPressInput(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function isGamepadInputType(inputType)
	return inputType == Enum.UserInputType.Gamepad1
		or inputType == Enum.UserInputType.Gamepad2
		or inputType == Enum.UserInputType.Gamepad3
		or inputType == Enum.UserInputType.Gamepad4
		or inputType == Enum.UserInputType.Gamepad5
		or inputType == Enum.UserInputType.Gamepad6
		or inputType == Enum.UserInputType.Gamepad7
		or inputType == Enum.UserInputType.Gamepad8
end

local function readGuiServiceProperty(propertyName)
	local ok, value = pcall(function()
		return GuiService[propertyName]
	end)
	if ok then
		return value
	end
	return nil
end

local function writeGuiServiceProperty(propertyName, value)
	pcall(function()
		GuiService[propertyName] = value
	end)
end

local function clearGuiSelection()
	writeGuiServiceProperty("SelectedObject", nil)
end

local function lockGuiNavigation()
	if guiNavigationLockDepth == 0 then
		guiNavigationRestore = {
			AutoSelectGuiEnabled = readGuiServiceProperty("AutoSelectGuiEnabled"),
		}
		writeGuiServiceProperty("AutoSelectGuiEnabled", false)
	end
	guiNavigationLockDepth += 1
	clearGuiSelection()
end

local function unlockGuiNavigation()
	if guiNavigationLockDepth <= 0 then
		guiNavigationLockDepth = 0
		clearGuiSelection()
		return
	end

	guiNavigationLockDepth -= 1
	if guiNavigationLockDepth > 0 then
		clearGuiSelection()
		return
	end

	local restore = guiNavigationRestore
	guiNavigationRestore = nil
	if restore then
		if restore.AutoSelectGuiEnabled ~= nil then
			writeGuiServiceProperty("AutoSelectGuiEnabled", restore.AutoSelectGuiEnabled)
		end
	end
	clearGuiSelection()
end

local function isInteractiveGui(guiObject)
	local current = guiObject
	while current and current:IsA("GuiObject") do
		if current:IsA("GuiButton") or current.Active == true then
			return true
		end
		current = current.Parent
	end
	return false
end

function PlacementInput.IsPressInput(input)
	return input ~= nil and isPressInput(input)
end

function PlacementInput.IsGamepadInputType(inputType)
	return isGamepadInputType(inputType)
end

function PlacementInput.IsGamepadPreferred()
	local okPreferred, preferred = pcall(function()
		return UserInputService.PreferredInput
	end)
	local preferredInputEnum = Enum.PreferredInput
	if okPreferred and preferredInputEnum and preferred == preferredInputEnum.Gamepad then
		return true
	end

	local okLastInput, lastInputType = pcall(UserInputService.GetLastInputType, UserInputService)
	if okLastInput and isGamepadInputType(lastInputType) then
		return true
	end

	return false
end

function PlacementInput.ScreenPosition(value)
	return screenPositionFrom(value)
end

function PlacementInput.IsInteractiveGuiAt(screenPosition)
	local position = screenPositionFrom(screenPosition)
	if not position then
		return false
	end

	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChild("PlayerGui")
	if not playerGui then
		return false
	end

	local ok, guiObjects = pcall(function()
		return playerGui:GetGuiObjectsAtPosition(position.X, position.Y)
	end)
	if not ok or type(guiObjects) ~= "table" then
		return false
	end

	for _, guiObject in ipairs(guiObjects) do
		if isInteractiveGui(guiObject) then
			return true
		end
	end
	return false
end

function PlacementInput.SetGamepadGuiNavigationLocked(lockName, locked)
	lockName = tostring(lockName or "PlacementInput")
	locked = locked == true

	if locked then
		if guiNavigationLocks[lockName] then
			clearGuiSelection()
			return
		end
		guiNavigationLocks[lockName] = true
		lockGuiNavigation()
		return
	end

	if not guiNavigationLocks[lockName] then
		return
	end
	guiNavigationLocks[lockName] = nil
	unlockGuiNavigation()
end

function PlacementInput.ClearGamepadGuiSelection()
	clearGuiSelection()
end

function PlacementInput.CameraRelativeFloorStep(floor, direction)
	if not (floor and floor:IsA("BasePart")) then
		return nil, nil
	end
	if typeof(direction) ~= "Vector2" or direction.Magnitude <= 0 then
		return nil, nil
	end

	local normal = floor.CFrame.UpVector
	local camera = Workspace.CurrentCamera

	local function planarUnit(vector, fallback)
		local projected = vector - normal * vector:Dot(normal)
		if projected.Magnitude < 0.001 then
			projected = fallback - normal * fallback:Dot(normal)
		end
		if projected.Magnitude < 0.001 then
			return nil
		end
		return projected.Unit
	end

	local right = planarUnit(camera and camera.CFrame.RightVector or floor.CFrame.RightVector, floor.CFrame.RightVector)
	local forward = planarUnit(camera and camera.CFrame.LookVector or floor.CFrame.LookVector, floor.CFrame.LookVector)
	if not right or not forward then
		return nil, nil
	end

	local worldDirection = right * direction.X + forward * direction.Y
	if worldDirection.Magnitude < 0.001 then
		return nil, nil
	end

	local localDirection = floor.CFrame:VectorToObjectSpace(worldDirection.Unit)
	if math.abs(localDirection.X) >= math.abs(localDirection.Z) then
		return localDirection.X >= 0 and 1 or -1, 0
	end
	return 0, localDirection.Z >= 0 and 1 or -1
end

function PlacementInput.BindMoveDrag(button, label, callbacks)
	if not (button and button:IsA("GuiButton")) then
		return nil
	end

	local oldDetector = button:FindFirstChild(MOVE_DRAG_DETECTOR_NAME)
	if oldDetector then
		oldDetector:Destroy()
	end

	local dragging = false
	local activeInput = nil
	local activeInputType = nil

	local function currentPosition(input)
		if input and input.UserInputType == Enum.UserInputType.Touch then
			return screenPositionFrom(input)
		end
		return UserInputService:GetMouseLocation()
	end

	local function beginDrag(input)
		if callbacks.canStart and not callbacks.canStart() then
			activeInput = nil
			activeInputType = nil
			dragging = false
			return
		end

		activeInput = input
		activeInputType = input.UserInputType
		dragging = true
		if callbacks.onStart then
			callbacks.onStart(currentPosition(input))
		end
	end

	local function updateDrag(input)
		if not dragging then
			return
		end
		if activeInputType == Enum.UserInputType.Touch and input ~= activeInput then
			return
		end
		if activeInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end

		if callbacks.onContinue then
			callbacks.onContinue(currentPosition(input))
		end
	end

	local function endDrag(input)
		if not dragging then
			return
		end
		if activeInputType == Enum.UserInputType.Touch and input ~= activeInput then
			return
		end
		if activeInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end

		local position = currentPosition(input)
		dragging = false
		activeInput = nil
		activeInputType = nil
		if callbacks.onEnd then
			callbacks.onEnd(position)
		end
	end

	RuntimeGuard.Connect(button.InputBegan, label .. ".InputBegan", function(input)
		if not isPressInput(input) then
			return
		end
		beginDrag(input)
	end)

	RuntimeGuard.Connect(UserInputService.InputChanged, label .. ".InputChanged", function(input)
		if activeInputType == Enum.UserInputType.Touch then
			return
		end
		updateDrag(input)
	end)
	RuntimeGuard.Connect(UserInputService.TouchMoved, label .. ".TouchMoved", updateDrag)
	RuntimeGuard.Connect(UserInputService.InputEnded, label .. ".InputEnded", endDrag)

	RuntimeGuard.Connect(button.Destroying, label .. ".ButtonDestroying", function()
		if not dragging then
			return
		end

		dragging = false
		activeInput = nil
		activeInputType = nil
		if callbacks.onEnd then
			callbacks.onEnd(nil)
		end
	end)

	return true
end

function PlacementInput.BindGamepadPlacementControls(label, callbacks)
	callbacks = callbacks or {}
	label = tostring(label or "Placement")

	local actionPrefix = label .. ".Gamepad"
	local moving = false
	local dpadDirection = Vector2.zero
	local nextRepeatAt = 0

	local function isActive()
		return callbacks.isActive == nil or callbacks.isActive() == true
	end

	local function canMoveStart()
		return isActive() and (callbacks.canMoveStart == nil or callbacks.canMoveStart() == true)
	end

	local function canRotate()
		return isActive() and (callbacks.canRotate == nil or callbacks.canRotate() == true)
	end

	local function canConfirm()
		return isActive() and (callbacks.canConfirm == nil or callbacks.canConfirm() == true)
	end

	local function canCancel()
		return isActive() and (callbacks.canCancel == nil or callbacks.canCancel() == true)
	end

	local function sameDirection(a, b)
		return a.X == b.X and a.Y == b.Y
	end

	local function activeMoveDirection()
		return dpadDirection
	end

	local function stepMove(direction)
		if direction.Magnitude <= 0 or not callbacks.onMoveStep then
			return
		end
		callbacks.onMoveStep(direction)
	end

	local function setDpadDirection(nextDirection)
		if sameDirection(dpadDirection, nextDirection) then
			return
		end
		dpadDirection = nextDirection
		if moving and dpadDirection.Magnitude > 0 then
			stepMove(dpadDirection)
			nextRepeatAt = os.clock() + GAMEPAD_REPEAT_START_DELAY
		end
	end

	local function finishMove()
		if not moving then
			return
		end
		moving = false
		dpadDirection = Vector2.zero
		unlockGuiNavigation()
		if callbacks.onMoveEnd then
			callbacks.onMoveEnd()
		end
		clearGuiSelection()
	end

	local function beginMove()
		if moving then
			return true
		end
		if not canMoveStart() then
			return false
		end
		moving = true
		lockGuiNavigation()
		nextRepeatAt = os.clock() + GAMEPAD_REPEAT_START_DELAY
		if callbacks.onMoveStart then
			callbacks.onMoveStart()
		end
		return true
	end

	local function thumbstickAction(_, inputState, inputObject)
		if moving then
			clearGuiSelection()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end

	local function dpadDirectionFor(keyCode)
		if keyCode == Enum.KeyCode.DPadUp then
			return Vector2.new(0, 1)
		elseif keyCode == Enum.KeyCode.DPadDown then
			return Vector2.new(0, -1)
		elseif keyCode == Enum.KeyCode.DPadLeft then
			return Vector2.new(-1, 0)
		elseif keyCode == Enum.KeyCode.DPadRight then
			return Vector2.new(1, 0)
		end
		return Vector2.zero
	end

	local function dpadAction(_, inputState, inputObject)
		local direction = inputObject and dpadDirectionFor(inputObject.KeyCode) or Vector2.zero
		if inputState == Enum.UserInputState.Begin then
			if not beginMove() then
				return Enum.ContextActionResult.Pass
			end
			setDpadDirection(direction)
			return Enum.ContextActionResult.Sink
		elseif inputState == Enum.UserInputState.End and moving then
			if sameDirection(dpadDirection, direction) then
				setDpadDirection(Vector2.zero)
			end
			finishMove()
			return Enum.ContextActionResult.Sink
		elseif not moving then
			return Enum.ContextActionResult.Pass
		end
		return Enum.ContextActionResult.Sink
	end

	local function rotateAction(_, inputState)
		if inputState == Enum.UserInputState.Begin and canRotate() then
			if callbacks.onRotate then
				callbacks.onRotate()
			end
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end

	local function confirmAction(_, inputState)
		if inputState == Enum.UserInputState.Begin and canConfirm() then
			if callbacks.onConfirm then
				callbacks.onConfirm()
			end
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end

	local function cancelAction(_, inputState)
		if inputState == Enum.UserInputState.Begin and canCancel() then
			if moving then
				moving = false
				unlockGuiNavigation()
			end
			dpadDirection = Vector2.zero
			if callbacks.onCancel then
				callbacks.onCancel()
			end
			clearGuiSelection()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end

	ContextActionService:BindActionAtPriority(
		actionPrefix .. ".Thumbstick",
		thumbstickAction,
		false,
		GAMEPAD_ACTION_PRIORITY,
		Enum.KeyCode.Thumbstick1
	)
	ContextActionService:BindActionAtPriority(
		actionPrefix .. ".DPad",
		dpadAction,
		false,
		GAMEPAD_ACTION_PRIORITY,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight
	)
	ContextActionService:BindActionAtPriority(
		actionPrefix .. ".Rotate",
		rotateAction,
		false,
		GAMEPAD_ACTION_PRIORITY,
		PlacementInput.GamepadKeyCodes.Rotate
	)
	ContextActionService:BindActionAtPriority(
		actionPrefix .. ".Confirm",
		confirmAction,
		false,
		GAMEPAD_ACTION_PRIORITY,
		PlacementInput.GamepadKeyCodes.Confirm
	)
	ContextActionService:BindActionAtPriority(
		actionPrefix .. ".Cancel",
		cancelAction,
		false,
		GAMEPAD_ACTION_PRIORITY,
		PlacementInput.GamepadKeyCodes.Cancel
	)

	RuntimeGuard.Connect(RunService.RenderStepped, actionPrefix .. ".MoveRepeat", function()
		if not moving then
			return
		end
		clearGuiSelection()
		local direction = activeMoveDirection()
		if direction.Magnitude <= 0 then
			return
		end
		local now = os.clock()
		if now < nextRepeatAt then
			return
		end
		stepMove(direction)
		nextRepeatAt = now + GAMEPAD_REPEAT_INTERVAL
	end)

	return true
end

RuntimeGuard.Connect(RunService.RenderStepped, "PlacementInput.GamepadGuiNavigationLock", function()
	if guiNavigationLockDepth <= 0 then
		return
	end
	clearGuiSelection()
end)

function PlacementInput.NewTapRecognizer(options)
	options = options or {}
	local threshold = options.threshold or DEFAULT_TAP_MOVE_THRESHOLD
	local activeTap = nil

	local recognizer = {}

	function recognizer:Begin(input)
		if not input or input.UserInputType ~= Enum.UserInputType.Touch then
			return false
		end
		if activeTap ~= nil then
			return false
		end

		local position = screenPositionFrom(input)
		if not position then
			return false
		end

		activeTap = {
			input = input,
			startPosition = position,
			lastPosition = position,
			startedAt = os.clock(),
			dragged = false,
			startedOverGui = PlacementInput.IsInteractiveGuiAt(position),
		}
		return true
	end

	function recognizer:Changed(input)
		if not activeTap or input ~= activeTap.input then
			return
		end

		local position = screenPositionFrom(input)
		if not position then
			return
		end

		activeTap.lastPosition = position
		if (position - activeTap.startPosition).Magnitude > threshold then
			activeTap.dragged = true
		end
	end

	function recognizer:End(input)
		if not activeTap or input ~= activeTap.input then
			return nil
		end

		local position = screenPositionFrom(input) or activeTap.lastPosition
		activeTap.lastPosition = position
		local tap = activeTap
		activeTap = nil

		if (position - tap.startPosition).Magnitude > threshold then
			tap.dragged = true
		end
		if tap.dragged or tap.startedOverGui then
			return nil
		end

		return {
			position = position,
			startPosition = tap.startPosition,
			elapsed = os.clock() - tap.startedAt,
		}
	end

	function recognizer:Cancel()
		activeTap = nil
	end

	return recognizer
end

return PlacementInput
