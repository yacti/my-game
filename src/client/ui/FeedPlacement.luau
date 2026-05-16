-- Feed machine placement HUD + preview. Prefers a ScreenGui template at
-- ReplicatedStorage.UI.FeedPlacementGui (editable in Studio) with a descendant
-- TextButton named "ConfirmButton"; falls back to a code-built HUD otherwise.

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local State   = require(Shared:WaitForChild("State"))
local NotificationUi = require(script.Parent:WaitForChild("Notifications"))

local PREVIEW_TRANSPARENCY = 0.5
local PREVIEW_START_TRANSPARENCY = 1
local PREVIEW_BLOCKED_COLOR = Color3.fromRGB(255, 65, 65)
local PREVIEW_SHOW_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PREVIEW_SELECT_BOUNCE_HEIGHT = 0.9
local PREVIEW_SELECT_BOUNCE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
local PREVIEW_BOUNCE_HEIGHT = 0.45
local PREVIEW_BOUNCE_UP_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PREVIEW_BOUNCE_DOWN_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)

local function isHiddenPreviewPart(part)
	return part.Name:match("^BaseFood") ~= nil
end

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
	part.Transparency = isHiddenPreviewPart(part) and 1 or PREVIEW_START_TRANSPARENCY
	part.CastShadow   = false
end

local FeedPlacement = {}

local PLACEMENT_FAILURE_MESSAGES = {
	["busy"] = "Please wait before placing another feed machine.",
	["no-feed-tool"] = "Equip a feed machine before placing.",
	["out-of-bounds"] = "Place feed machines inside your plot.",
	["overlap"] = "That spot is already occupied.",
	["rate-limited"] = "Please wait before placing again.",
}

local function placementFailureMessage(reason)
	return PLACEMENT_FAILURE_MESSAGES[reason] or "Could not place feed machine."
end

local function forEachPreviewPart(preview, callback)
	if preview:IsA("BasePart") then
		if not isHiddenPreviewPart(preview) then callback(preview) end
	elseif preview:IsA("Model") then
		for _, d in ipairs(preview:GetDescendants()) do
			if d:IsA("BasePart") and not isHiddenPreviewPart(d) then callback(d) end
		end
	end
end

local function feedHitboxRootFromPart(plot, part)
	local current = part
	while current and current ~= plot do
		if current:GetAttribute("FeedType") and current:GetAttribute("FeedIndex") then
			if current:IsA("BasePart") then return current end
			if current:IsA("Model") and current.PrimaryPart == part then return current end
			return nil
		end
		current = current.Parent
	end
	return nil
end

local function playPreviewShowTween(preview)
	forEachPreviewPart(preview, function(part)
		part.Transparency = PREVIEW_START_TRANSPARENCY
		TweenService:Create(part, PREVIEW_SHOW_TWEEN, {
			Transparency = PREVIEW_TRANSPARENCY,
		}):Play()
	end)
end

local function setPreviewCFrame(preview, cframe)
	if preview:IsA("BasePart") then
		preview.CFrame = cframe
	elseif preview:IsA("Model") then
		preview:PivotTo(cframe)
	end
end

local function playPreviewBounce(preview, baseCFrame, onComplete)
	local cfValue = Instance.new("CFrameValue")
	cfValue.Value = baseCFrame

	local function apply(value)
		if not preview.Parent then return end
		setPreviewCFrame(preview, value)
	end

	local changed = cfValue:GetPropertyChangedSignal("Value"):Connect(function()
		apply(cfValue.Value)
	end)

	local upCFrame = baseCFrame + baseCFrame.UpVector * PREVIEW_BOUNCE_HEIGHT
	local upTween = TweenService:Create(cfValue, PREVIEW_BOUNCE_UP_TWEEN, { Value = upCFrame })
	local downTween = TweenService:Create(cfValue, PREVIEW_BOUNCE_DOWN_TWEEN, { Value = baseCFrame })

	upTween.Completed:Connect(function()
		if preview.Parent then
			downTween:Play()
		else
			changed:Disconnect()
			cfValue:Destroy()
			if onComplete then onComplete() end
		end
	end)

	downTween.Completed:Connect(function()
		changed:Disconnect()
		cfValue:Destroy()
		if onComplete then onComplete() end
	end)

	upTween:Play()
end

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
	local PlaceFeedMachineResult = Remotes.get(Remotes.Names.PlaceFeedMachineResult)

	local gui = PlayerGui:FindFirstChild("HUD")
	if not (gui and gui:IsA("ScreenGui") and findConfirmButton(gui)) then
		gui = cloneTemplate() or buildFallbackGui()
		gui.Parent = PlayerGui
	end
	local confirmBtn = findConfirmButton(gui)
	local placementControls = gui:FindFirstChild("PlacementControls", true)
	local confirmDefaults = confirmBtn and {
		Active = confirmBtn.Active,
		AutoButtonColor = confirmBtn.AutoButtonColor,
		BackgroundTransparency = confirmBtn.BackgroundTransparency,
		TextTransparency = confirmBtn.TextTransparency,
		Visible = confirmBtn.Visible,
	} or nil

	local preview, currentRotation, placing = nil, 0, false
	local activeFeedType = nil  -- set when a FeedMachine tool is equipped
	local selectedLX, selectedLZ = nil, nil
	local bouncingPreview = nil
	local previewMotionToken = 0
	local previewPartColors = {}
	local currentPlacementBlocked = true
	local nextPlacementRequestId = 0
	local pendingPlacementRequestId = nil
	local pendingPlacementCFrame = nil
	local unequippedWhilePending = false

	local function snapToGrid(v) return math.round(v) end

	local function setPlacementVisible(visible)
		if placementControls and placementControls:IsA("GuiObject") then
			placementControls.Visible = visible
		else
			gui.Enabled = visible
		end
	end

	local function setConfirmVisible(visible)
		if not confirmBtn or not confirmDefaults then return end
		confirmBtn.Visible = visible and confirmDefaults.Visible or false
	end

	local function setConfirmEnabled(enabled)
		if not confirmBtn or not confirmDefaults then return end
		confirmBtn.Active = enabled
		confirmBtn.AutoButtonColor = enabled and confirmDefaults.AutoButtonColor or false
		confirmBtn.BackgroundTransparency = enabled
			and confirmDefaults.BackgroundTransparency
			or math.max(confirmDefaults.BackgroundTransparency, 0.25)
		confirmBtn.TextTransparency = enabled
			and confirmDefaults.TextTransparency
			or math.max(confirmDefaults.TextTransparency, 0.45)
	end

	setPlacementVisible(false)

	local function buildPreview()
		if preview then preview:Destroy() end
		previewPartColors = {}
		local template = activeFeedType and findTemplate(activeFeedType)
		if not template then return end
		local clone = template:Clone()
		clone.Name = "__FeedPreview"
		local function preparePreviewPart(part)
			previewPartColors[part] = part.Color
			setPreviewProps(part)
		end
		if clone:IsA("BasePart") then
			preparePreviewPart(clone)
			-- strip ClickDetectors / ProximityPrompts so the preview is purely visual
			for _, c in ipairs(clone:GetChildren()) do c:Destroy() end
		elseif clone:IsA("Model") then
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then preparePreviewPart(d) end
				if d:IsA("ClickDetector") or d:IsA("ProximityPrompt") then d:Destroy() end
			end
		end
		clone.Parent = workspace
		preview = clone
	end

	local function destroyPreview()
		if preview then preview:Destroy() preview = nil end
		placing         = false
		currentRotation = 0
		selectedLX      = nil
		selectedLZ      = nil
		bouncingPreview = nil
		previewMotionToken += 1
		previewPartColors = {}
		currentPlacementBlocked = true
		pendingPlacementRequestId = nil
		pendingPlacementCFrame = nil
		unequippedWhilePending = false
		setPlacementVisible(false)
		setConfirmVisible(true)
		setConfirmEnabled(false)
	end

	-- The player's plot Floor — used to snap the preview in floor-local
	-- axes so the grid + rotation align with a rotated plot rather than
	-- world axes. RespawnLocation is set server-side to the plot's
	-- SpawnLocation, so its parent is the plot.
	local function getPlayerFloor()
		local plot = player.RespawnLocation and player.RespawnLocation.Parent
		return plot and plot:FindFirstChild("Floor") or nil
	end

	local function getPlayerPlot()
		return player.RespawnLocation and player.RespawnLocation.Parent or nil
	end

	local function ensurePreview()
		if preview then return true end
		buildPreview()
		return preview ~= nil
	end

	local function getSelectedCFrame()
		local floor = getPlayerFloor()
		if not floor or not floor:IsA("BasePart") then return nil end
		if selectedLX == nil or selectedLZ == nil then return nil end
		if not preview then return nil end

		local halfH = previewSizeY(preview) / 2
		local localCF = CFrame.new(selectedLX, floor.Size.Y / 2 + halfH, selectedLZ)
			* CFrame.Angles(0, math.rad(currentRotation), 0)
		return floor.CFrame * localCF
	end

	local function applyPreviewCFrame()
		if not preview then return end
		local cf = getSelectedCFrame()
		if not cf then return end
		setPreviewCFrame(preview, cf)
	end

	local function getPreviewBounds()
		if not preview then return nil, nil end
		if preview:IsA("BasePart") then
			return preview.CFrame, preview.Size
		end
		if preview:IsA("Model") then
			local primary = preview.PrimaryPart
			if primary then return primary.CFrame, primary.Size end
		end
		return nil, nil
	end

	local function previewOverlapsFeed()
		local plot = getPlayerPlot()
		if not plot then return true end
		local boundsCF, boundsSize = getPreviewBounds()
		if not boundsCF or not boundsSize then return true end

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { plot }

		for _, part in ipairs(workspace:GetPartBoundsInBox(boundsCF, boundsSize, params)) do
			if feedHitboxRootFromPart(plot, part) then
				return true
			end
		end
		return false
	end

	local function setPreviewBlocked(blocked)
		currentPlacementBlocked = blocked
		if preview then
			forEachPreviewPart(preview, function(part)
				part.Color = blocked and PREVIEW_BLOCKED_COLOR or (previewPartColors[part] or part.Color)
			end)
		end
		setConfirmVisible(not blocked)
		setConfirmEnabled(not blocked)
	end

	local function playPreviewSelectBounce(baseCFrame)
		if not preview then return end
		previewMotionToken += 1
		local token = previewMotionToken
		local bouncing = preview
		local cfValue = Instance.new("CFrameValue")
		cfValue.Value = baseCFrame + baseCFrame.UpVector * PREVIEW_SELECT_BOUNCE_HEIGHT
		setPreviewCFrame(bouncing, cfValue.Value)

		local changed = cfValue:GetPropertyChangedSignal("Value"):Connect(function()
			if token ~= previewMotionToken or preview ~= bouncing or not bouncing.Parent then return end
			setPreviewCFrame(bouncing, cfValue.Value)
		end)

		local tween = TweenService:Create(cfValue, PREVIEW_SELECT_BOUNCE_TWEEN, { Value = baseCFrame })
		tween.Completed:Connect(function()
			changed:Disconnect()
			cfValue:Destroy()
			if token == previewMotionToken and preview == bouncing and bouncing.Parent then
				setPreviewCFrame(bouncing, baseCFrame)
			end
		end)
		tween:Play()
	end

	local function selectFloorCellFromScreen(screenPosition)
		local floor = getPlayerFloor()
		local camera = workspace.CurrentCamera
		if not floor or not floor:IsA("BasePart") or not camera then return false end

		local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { floor }

		local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
		if not hit then return false end

		local localTarget = floor.CFrame:PointToObjectSpace(hit.Position)
		local halfX = floor.Size.X / 2
		local halfZ = floor.Size.Z / 2
		if math.abs(localTarget.X) > halfX or math.abs(localTarget.Z) > halfZ then
			return false
		end

		local snappedLX = snapToGrid(localTarget.X)
		local snappedLZ = snapToGrid(localTarget.Z)
		if math.abs(snappedLX) > halfX or math.abs(snappedLZ) > halfZ then
			return false
		end

		if not ensurePreview() then return false end
		selectedLX = snappedLX
		selectedLZ = snappedLZ
		applyPreviewCFrame()
		playPreviewShowTween(preview)
		setPreviewBlocked(previewOverlapsFeed())
		local cf = getSelectedCFrame()
		if cf then playPreviewSelectBounce(cf) end
		return true
	end

	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe or not placing then return end
		if input.KeyCode == Enum.KeyCode.R then
			currentRotation = (currentRotation + 90) % 360
			previewMotionToken += 1
			applyPreviewCFrame()
			if selectedLX ~= nil and selectedLZ ~= nil then
				setPreviewBlocked(previewOverlapsFeed())
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			selectFloorCellFromScreen(input.Position)
		end
	end)

	if confirmBtn then
		confirmBtn.Activated:Connect(function()
			if pendingPlacementRequestId ~= nil then return end
			if not placing or not preview or selectedLX == nil or selectedLZ == nil or currentPlacementBlocked then return end
			local cf = getSelectedCFrame()
			if not cf then return end

			nextPlacementRequestId += 1
			pendingPlacementRequestId = nextPlacementRequestId
			pendingPlacementCFrame = cf
			unequippedWhilePending = false
			placing = false
			setConfirmEnabled(false)
			PlaceFeedMachine:FireServer(pendingPlacementRequestId, cf)
		end)
	end

	PlaceFeedMachineResult.OnClientEvent:Connect(function(requestId, success, reason)
		if requestId ~= pendingPlacementRequestId then return end
		pendingPlacementRequestId = nil
		local placedCFrame = pendingPlacementCFrame
		pendingPlacementCFrame = nil

		if not success then
			if unequippedWhilePending then
				activeFeedType = nil
				destroyPreview()
				return
			end
			placing = true
			setPlacementVisible(true)
			if preview and selectedLX ~= nil and selectedLZ ~= nil then
				setPreviewBlocked(previewOverlapsFeed())
			else
				currentPlacementBlocked = true
				setConfirmEnabled(false)
			end
			NotificationUi.show({
				kind = NotificationConfig.Kinds.Error,
				text = placementFailureMessage(reason),
			})
			return
		end

		if not preview then
			activeFeedType = nil
			destroyPreview()
			return
		end

		if not placedCFrame then
			activeFeedType = nil
			destroyPreview()
			return
		end

		local placedPreview = preview
		placing = false
		setPlacementVisible(false)
		setConfirmEnabled(false)
		previewMotionToken += 1
		bouncingPreview = placedPreview
		playPreviewBounce(placedPreview, placedCFrame, function()
			if preview == placedPreview then
				activeFeedType = nil
				destroyPreview()
			else
				bouncingPreview = nil
			end
		end)
	end)

	local function bindTool(tool)
		if not tool:IsA("Tool") then return end
		if tool:GetAttribute(State.Feed.Type) == nil then return end
		tool.Equipped:Connect(function()
			activeFeedType  = tool:GetAttribute(State.Feed.Type)
			placing         = true
			currentRotation = 0
			selectedLX      = nil
			selectedLZ      = nil
			currentPlacementBlocked = true
			setPlacementVisible(true)
			setConfirmVisible(true)
			setConfirmEnabled(false)
		end)
		tool.Unequipped:Connect(function()
			if pendingPlacementRequestId ~= nil then
				unequippedWhilePending = true
				return
			end
			if bouncingPreview then
				activeFeedType = nil
				return
			end
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
