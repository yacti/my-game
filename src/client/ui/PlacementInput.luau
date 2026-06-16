local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlacementInput = {}

local DEFAULT_TAP_MOVE_THRESHOLD = 16
local MOVE_DRAG_DETECTOR_NAME = "__PlacementMoveDragDetector"

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
