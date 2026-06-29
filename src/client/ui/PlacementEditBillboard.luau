local UserInputService = game:GetService("UserInputService")

local PlacementEditBillboard = {}

local WORLD_Y_OFFSET = -1.5

local BASE_OFFSET = Vector3.new(0, WORLD_Y_OFFSET, 0)
local CONTROLLER_HINT_KEYCODES = {
	move = Enum.KeyCode.DPadUp,
	rotate = Enum.KeyCode.ButtonY,
	confirm = Enum.KeyCode.ButtonR2,
}

local function gamepadButtonImage(keyCode)
	local ok, image = pcall(UserInputService.GetImageForKeyCode, UserInputService, keyCode)
	if ok and type(image) == "string" and image ~= "" then
		return image
	end
	return nil
end

local function applyControllerHints(billboard)
	local options = billboard:FindFirstChild("options", true)
	if not options then
		return
	end

	for buttonName, keyCode in pairs(CONTROLLER_HINT_KEYCODES) do
		local button = options:FindFirstChild(buttonName)
		local hint = button and button:FindFirstChild("ControllerHint")
		if hint and hint:IsA("ImageLabel") then
			local image = gamepadButtonImage(keyCode)
			hint.Visible = image ~= nil
			if image then
				hint.Image = image
			end
		end
	end
end

function PlacementEditBillboard.Apply(billboard)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return nil
	end

	billboard.AlwaysOnTop = true
	billboard.StudsOffset = Vector3.zero
	billboard.StudsOffsetWorldSpace = BASE_OFFSET
	applyControllerHints(billboard)
end

return PlacementEditBillboard
