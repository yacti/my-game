local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")

local Remotes          = ReplicatedStorage:WaitForChild("Remotes")
local PlaceFeedMachine = Remotes:WaitForChild("PlaceFeedMachine")
local FeedTemplate     = ReplicatedStorage:WaitForChild("FeedMachines"):WaitForChild("Feed1")

-- Confirm button UI
local screenGui = Instance.new("ScreenGui")
screenGui.Name          = "FeedPlacementGui"
screenGui.ResetOnSpawn  = false
screenGui.Enabled       = false
screenGui.Parent        = PlayerGui

local confirmBtn = Instance.new("TextButton")
confirmBtn.Size             = UDim2.new(0, 200, 0, 55)
confirmBtn.Position         = UDim2.new(0.5, -100, 1, -80)
confirmBtn.BackgroundColor3 = Color3.fromRGB(46, 204, 113)
confirmBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
confirmBtn.Text             = "Place Feed Machine"
confirmBtn.Font             = Enum.Font.GothamBold
confirmBtn.TextScaled       = true
confirmBtn.BorderSizePixel  = 0
confirmBtn.Parent           = screenGui
Instance.new("UICorner", confirmBtn).CornerRadius = UDim.new(0, 8)

local hintLabel = Instance.new("TextLabel")
hintLabel.Size               = UDim2.new(0, 200, 0, 30)
hintLabel.Position           = UDim2.new(0.5, -100, 1, -115)
hintLabel.BackgroundTransparency = 1
hintLabel.Text               = "[R] Rotate  •  Confirm to place"
hintLabel.Font               = Enum.Font.Gotham
hintLabel.TextColor3         = Color3.fromRGB(255, 255, 255)
hintLabel.TextSize           = 14
hintLabel.TextStrokeTransparency = 0
hintLabel.Parent             = screenGui

-- State
local preview         = nil
local currentRotation = 0
local placing         = false

local PREVIEW_DIST = 8

local function snapToGrid(v)
	return math.round(v)
end

local function buildPreview()
	if preview then preview:Destroy() end
	local clone = FeedTemplate:Clone()
	clone.Anchored          = true
	clone.CanCollide        = false
	clone.Transparency      = 0.5
	clone.CastShadow        = false
	clone.Name              = "__FeedPreview"
	for _, c in ipairs(clone:GetChildren()) do c:Destroy() end
	clone.Parent = workspace
	preview = clone
end

local function destroyPreview()
	if preview then preview:Destroy() preview = nil end
	screenGui.Enabled = false
	placing           = false
	currentRotation   = 0
end

local function getPreviewCFrame()
	local char = player.Character
	if not char then return nil end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local look = hrp.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.001 then flat = Vector3.new(0, 0, -1) end
	flat = flat.Unit

	local target = hrp.Position + flat * PREVIEW_DIST

	-- Raycast down to find floor surface
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, preview }

	local hit = workspace:Raycast(
		Vector3.new(target.X, hrp.Position.Y + 5, target.Z),
		Vector3.new(0, -30, 0),
		params
	)
	local floorY = hit and hit.Position.Y or (hrp.Position.Y - 3)

	local sx = snapToGrid(target.X)
	local sz = snapToGrid(target.Z)
	local sy = floorY + (preview and preview.Size.Y / 2 or 2)

	return CFrame.new(sx, sy, sz) * CFrame.Angles(0, math.rad(currentRotation), 0)
end

-- Update preview position every frame
RunService.RenderStepped:Connect(function()
	if not placing or not preview then return end
	local cf = getPreviewCFrame()
	if cf then preview.CFrame = cf end
end)

-- R to rotate 90 degrees
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe or not placing then return end
	if input.KeyCode == Enum.KeyCode.R then
		currentRotation = (currentRotation + 90) % 360
	end
end)

-- Confirm placement
confirmBtn.Activated:Connect(function()
	if not placing or not preview then return end
	local cf = getPreviewCFrame()
	if cf then
		PlaceFeedMachine:FireServer(cf)
	end
	destroyPreview()
end)

-- Watch a tool for equip/unequip
local function bindTool(tool)
	if tool.Name ~= "FeedMachine" then return end
	tool.Equipped:Connect(function()
		placing         = true
		currentRotation = 0
		buildPreview()
		screenGui.Enabled = true
	end)
	tool.Unequipped:Connect(function()
		destroyPreview()
	end)
end

local function watchBackpack()
	for _, item in ipairs(player.Backpack:GetChildren()) do
		bindTool(item)
	end
	player.Backpack.ChildAdded:Connect(bindTool)
end

-- Cancel placement on respawn
player.CharacterAdded:Connect(function()
	destroyPreview()
	watchBackpack()
end)

watchBackpack()
