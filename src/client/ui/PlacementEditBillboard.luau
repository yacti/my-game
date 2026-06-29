local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlacementEditBillboard = {}

local WORLD_Y_OFFSET = -1.5

local BASE_OFFSET = Vector3.new(0, WORLD_Y_OFFSET, 0)
local trackedBillboards = setmetatable({}, { __mode = "k" })
local CONTROLLER_HINT_KEYCODES = {
	rotate = Enum.KeyCode.ButtonY,
	confirm = Enum.KeyCode.ButtonR2,
}
local LEGACY_MOVE_HINT_CHILD_NAMES = {
	Down = true,
	Left = true,
	Right = true,
	Up = true,
}

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

local function hasConnectedController()
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

	if UserInputService.GamepadEnabled then
		return true
	end
	local ok, gamepads = pcall(UserInputService.GetConnectedGamepads, UserInputService)
	return ok and type(gamepads) == "table" and #gamepads > 0
end

local function gamepadButtonImage(keyCode)
	local ok, image = pcall(UserInputService.GetImageForKeyCode, UserInputService, keyCode)
	if ok and type(image) == "string" and image ~= "" then
		return image
	end
	return nil
end

local function setControllerHintVisible(hint, visible)
	hint.Visible = visible
end

local function clearMoveControllerHint(options)
	local moveButton = options:FindFirstChild("move")
	local hint = moveButton and moveButton:FindFirstChild("ControllerHint")
	if not (hint and hint:IsA("ImageLabel")) then
		return
	end

	for _, child in ipairs(hint:GetChildren()) do
		if LEGACY_MOVE_HINT_CHILD_NAMES[child.Name] then
			child:Destroy()
		end
	end

	hint.Image = ""
	hint.ImageTransparency = 1
	hint.Visible = false
	hint:SetAttribute("ControllerHintType", nil)
	hint:SetAttribute("KeyCode", nil)
	hint:SetAttribute("RobloxTextureFamily", nil)
end

local function applyControllerHints(billboard)
	local options = billboard:FindFirstChild("options", true)
	if not options then
		return
	end
	local controllerConnected = hasConnectedController()

	clearMoveControllerHint(options)

	for buttonName, keyCode in pairs(CONTROLLER_HINT_KEYCODES) do
		local button = options:FindFirstChild(buttonName)
		local hint = button and button:FindFirstChild("ControllerHint")
		if hint and hint:IsA("ImageLabel") then
			local image = gamepadButtonImage(keyCode)
			if image then
				hint.Image = image
			end
			hint.ImageTransparency = 0
			hint:SetAttribute("KeyCode", keyCode.Name)
			setControllerHintVisible(hint, controllerConnected and image ~= nil)
		end
	end
end

local function refreshTrackedControllerHints()
	for billboard in pairs(trackedBillboards) do
		if billboard.Parent then
			applyControllerHints(billboard)
		else
			trackedBillboards[billboard] = nil
		end
	end
end

function PlacementEditBillboard.Apply(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return nil
	end

	trackedBillboards[billboard] = true
	billboard.AlwaysOnTop = true
	billboard.StudsOffset = Vector3.zero
	billboard.StudsOffsetWorldSpace = BASE_OFFSET
	applyControllerHints(billboard)
end

RuntimeGuard.Connect(UserInputService.GamepadConnected, "PlacementEditBillboard.GamepadConnected", refreshTrackedControllerHints)
RuntimeGuard.Connect(UserInputService.GamepadDisconnected, "PlacementEditBillboard.GamepadDisconnected", refreshTrackedControllerHints)
RuntimeGuard.Connect(UserInputService.LastInputTypeChanged, "PlacementEditBillboard.LastInputTypeChanged", refreshTrackedControllerHints)

return PlacementEditBillboard
