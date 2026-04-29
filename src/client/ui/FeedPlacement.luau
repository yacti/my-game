-- Feed machine placement HUD + preview. Prefers a ScreenGui template at
-- ReplicatedStorage.UI.FeedPlacementGui (editable in Studio) with a descendant
-- TextButton named "ConfirmButton"; falls back to a code-built HUD otherwise.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local State   = require(Shared:WaitForChild("State"))

-- Templates live at ReplicatedStorage.FeedMachines.<Class>.<FeedType>. The
-- equipped FeedMachine tool carries a FeedType attribute; we search the
-- FeedMachines tree for a template (BasePart or Model) with matching name.
local function findTemplate(feedType)
	local root = ReplicatedStorage:WaitForChild("FeedMachines")
	for _, classFolder in ipairs(root:GetChildren()) do
		if classFolder:IsA("Folder") then
			local t = classFolder:FindFirstChild(feedType)
			if t and (t:IsA("BasePart") or t:IsA("Model")) then return t end
		end
	end
	return nil
end

local function previewSizeY(preview)
	if preview:IsA("BasePart") then return preview.Size.Y end
	if preview:IsA("Model") then
		local pp = preview.PrimaryPart
		if pp then return pp.Size.Y end
		return preview:GetExtentsSize().Y
	end
	return 2
end

local function setPreviewProps(part)
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.Transparency = 0.5
	part.CastShadow   = false
end

local FeedPlacement = {}

local PREVIEW_DIST = 8

local function findConfirmButton(gui)
	local named = gui:FindFirstChild("ConfirmButton", true)
	if named and named:IsA("TextButton") then return named end
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextButton") then return d end
	end
	return nil
end

local function cloneTemplate()
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local template = uiFolder and uiFolder:FindFirstChild("FeedPlacementGui")
	if template and template:IsA("ScreenGui") then
		local clone = template:Clone()
		clone.Enabled = false
		return clone
	end
	return nil
end

local function buildFallbackGui()
	local gui = Instance.new("ScreenGui")
	gui.Name         = "FeedPlacementGui"
	gui.ResetOnSpawn = false
	gui.Enabled      = false

	local confirmBtn = Instance.new("TextButton")
	confirmBtn.Name             = "ConfirmButton"
	confirmBtn.Size             = UDim2.new(0, 200, 0, 55)
	confirmBtn.Position         = UDim2.new(0.5, -100, 1, -80)
	confirmBtn.BackgroundColor3 = Color3.fromRGB(46, 204, 113)
	confirmBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
	confirmBtn.Text             = "Place Feed Machine"
	confirmBtn.Font             = Enum.Font.GothamBold
	confirmBtn.TextScaled       = true
	confirmBtn.BorderSizePixel  = 0
	confirmBtn.Parent           = gui
	Instance.new("UICorner", confirmBtn).CornerRadius = UDim.new(0, 8)

	local hint = Instance.new("TextLabel")
	hint.Name                     = "Hint"
	hint.Size                     = UDim2.new(0, 200, 0, 30)
	hint.Position                 = UDim2.new(0.5, -100, 1, -115)
	hint.BackgroundTransparency   = 1
	hint.Text                     = "[R] Rotate  •  Confirm to place"
	hint.Font                     = Enum.Font.Gotham
	hint.TextColor3               = Color3.fromRGB(255, 255, 255)
	hint.TextSize                 = 14
	hint.TextStrokeTransparency   = 0
	hint.Parent                   = gui

	return gui
end

function FeedPlacement.start()
	local player           = Players.LocalPlayer
	local PlayerGui        = player:WaitForChild("PlayerGui")
	local PlaceFeedMachine = Remotes.get(Remotes.Names.PlaceFeedMachine)

	local gui = cloneTemplate() or buildFallbackGui()
	gui.Parent = PlayerGui
	local confirmBtn = findConfirmButton(gui)

	local preview, currentRotation, placing = nil, 0, false
	local activeFeedType = nil  -- set when a FeedMachine tool is equipped

	local function snapToGrid(v) return math.round(v) end

	local function buildPreview()
		if preview then preview:Destroy() end
		local template = activeFeedType and findTemplate(activeFeedType)
		if not template then return end
		local clone = template:Clone()
		clone.Name = "__FeedPreview"
		if clone:IsA("BasePart") then
			setPreviewProps(clone)
			-- strip ClickDetectors / ProximityPrompts so the preview is purely visual
			for _, c in ipairs(clone:GetChildren()) do c:Destroy() end
		elseif clone:IsA("Model") then
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then setPreviewProps(d) end
				if d:IsA("ClickDetector") or d:IsA("ProximityPrompt") then d:Destroy() end
			end
		end
		clone.Parent = workspace
		preview = clone
	end

	local function destroyPreview()
		if preview then preview:Destroy() preview = nil end
		gui.Enabled     = false
		placing         = false
		currentRotation = 0
	end

	-- The player's plot Floor — used to snap the preview in floor-local
	-- axes so the grid + rotation align with a rotated plot rather than
	-- world axes. RespawnLocation is set server-side to the plot's
	-- SpawnLocation, so its parent is the plot.
	local function getPlayerFloor()
		local plot = player.RespawnLocation and player.RespawnLocation.Parent
		return plot and plot:FindFirstChild("Floor") or nil
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
		local floor  = getPlayerFloor()
		local halfH  = preview and previewSizeY(preview) / 2 or 2

		if floor then
			-- Snap in floor-local: convert the aim point into the floor's
			-- frame, round to the integer grid there, then transform back.
			-- The placement Y rides on the floor's local top surface.
			local localTarget = floor.CFrame:PointToObjectSpace(target)
			local snappedLX   = snapToGrid(localTarget.X)
			local snappedLZ   = snapToGrid(localTarget.Z)
			local localCF     = CFrame.new(snappedLX, floor.Size.Y / 2 + halfH, snappedLZ)
				* CFrame.Angles(0, math.rad(currentRotation), 0)
			return floor.CFrame * localCF
		end

		-- Fallback: world-axis snap when no plot is found.
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
		local sy = floorY + halfH
		return CFrame.new(sx, sy, sz) * CFrame.Angles(0, math.rad(currentRotation), 0)
	end

	RunService.RenderStepped:Connect(function()
		if not placing or not preview then return end
		local cf = getPreviewCFrame()
		if not cf then return end
		if preview:IsA("BasePart") then
			preview.CFrame = cf
		elseif preview:IsA("Model") then
			preview:PivotTo(cf)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe or not placing then return end
		if input.KeyCode == Enum.KeyCode.R then
			currentRotation = (currentRotation + 90) % 360
		end
	end)

	if confirmBtn then
		confirmBtn.Activated:Connect(function()
			if not placing or not preview then return end
			local cf = getPreviewCFrame()
			if cf then PlaceFeedMachine:FireServer(cf) end
			destroyPreview()
		end)
	end

	local function bindTool(tool)
		if not tool:IsA("Tool") then return end
		if tool:GetAttribute(State.Feed.Type) == nil then return end
		tool.Equipped:Connect(function()
			activeFeedType  = tool:GetAttribute(State.Feed.Type)
			placing         = true
			currentRotation = 0
			buildPreview()
			gui.Enabled = true
		end)
		tool.Unequipped:Connect(function()
			destroyPreview()
			activeFeedType = nil
		end)
	end

	local function watchBackpack()
		for _, item in ipairs(player.Backpack:GetChildren()) do bindTool(item) end
		player.Backpack.ChildAdded:Connect(bindTool)
	end

	player.CharacterAdded:Connect(function()
		destroyPreview()
		watchBackpack()
	end)

	watchBackpack()
end

return FeedPlacement
