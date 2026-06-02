-- Feed/seed placement preview. Players equip an inventory tool, click an
-- unlocked grid cell, then confirm or adjust through the Studio-authored
-- ReplicatedStorage.UI.PlacementEdit billboard.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local GrowingVisuals = require(Shared:WaitForChild("GrowingVisuals"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State   = require(Shared:WaitForChild("State"))
local NotificationUi = require(script.Parent:WaitForChild("Notifications"))
local PlacementGrid = require(script.Parent:WaitForChild("PlacementGrid"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local PREVIEW_PART_TRANSPARENCY = 0.2
local PREVIEW_BLOCKED_COLOR = Color3.fromRGB(255, 65, 65)
local PLACEMENT_EDIT_FLOOR_OFFSET = 3
local FOOTPRINT_BOUNDS_EPSILON = 0.001
local OVERLAP_QUERY_INSET = 0.05
local BOX_CORNER_SIGNS = { -1, 1 }

local function isHiddenPreviewPart(part)
	return part.Name:match("^BaseFood") ~= nil
end

-- Templates live at ReplicatedStorage.FeedMachines.<Class>.<DisplayName>. The
-- equipped FeedMachine tool carries the stable FeedType attribute; template
-- names are visual only.
local function findTemplate(feedType)
	return GrowingVisuals.FeedTemplateFor(feedType)
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

local function templateHeight(template)
	if template:IsA("BasePart") then return template.Size.Y end
	if template:IsA("Model") then
		local primary = template.PrimaryPart
		if primary then return primary.Size.Y end
		return template:GetExtentsSize().Y
	end
	return nil
end

local function setPreviewProps(part)
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.Transparency = (isHiddenPreviewPart(part) or part.Transparency >= 1)
		and 1
		or PREVIEW_PART_TRANSPARENCY
	part.CastShadow   = false
end

local FeedPlacement = {}

local PLACEMENT_FAILURE_MESSAGES = {
	["busy"] = "Please wait before placing another feed machine.",
	["no-feed-tool"] = "Equip a feed machine before placing.",
	["out-of-bounds"] = "Place feed machines inside your plot.",
	["overlap"] = "That spot is already occupied.",
	["rate-limited"] = "Please wait before placing again.",
	["too-far"] = "Move closer to place that feed machine.",
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

local function boundsFitOnFloor(floor, boundsCF, boundsSize)
	local halfFloorX = floor.Size.X / 2 + FOOTPRINT_BOUNDS_EPSILON
	local halfFloorZ = floor.Size.Z / 2 + FOOTPRINT_BOUNDS_EPSILON
	local halfBounds = Vector3.new(boundsSize.X / 2, boundsSize.Y / 2, boundsSize.Z / 2)

	for _, sx in ipairs(BOX_CORNER_SIGNS) do
		for _, sy in ipairs(BOX_CORNER_SIGNS) do
			for _, sz in ipairs(BOX_CORNER_SIGNS) do
				local worldCorner = boundsCF:PointToWorldSpace(Vector3.new(
					sx * halfBounds.X,
					sy * halfBounds.Y,
					sz * halfBounds.Z
				))
				local floorCorner = floor.CFrame:PointToObjectSpace(worldCorner)
				if math.abs(floorCorner.X) > halfFloorX or math.abs(floorCorner.Z) > halfFloorZ then
					return false
				end
			end
		end
	end

	return true
end

local function unlockedGridParts(plot)
	local parts = {}
	if not plot then return parts end
	for _, folderName in ipairs({ PlotGrid.Folders.Starter, PlotGrid.Folders.Unlockable }) do
		local folder = plot:FindFirstChild(folderName)
		if folder then
			for _, child in ipairs(folder:GetChildren()) do
				if child:IsA("BasePart") and child:GetAttribute(State.Grid.Unlocked) == true then
					parts[#parts + 1] = child
				end
			end
		end
	end
	return parts
end

local function pointInsideGridPart(part, worldPoint)
	local localPoint = part.CFrame:PointToObjectSpace(worldPoint)
	return math.abs(localPoint.X) <= part.Size.X / 2 + FOOTPRINT_BOUNDS_EPSILON
		and math.abs(localPoint.Z) <= part.Size.Z / 2 + FOOTPRINT_BOUNDS_EPSILON
end

local function pointInsideUnlockedGrid(plot, worldPoint)
	for _, part in ipairs(unlockedGridParts(plot)) do
		if pointInsideGridPart(part, worldPoint) then
			return true
		end
	end
	return false
end

local function boundsFitOnUnlockedGrid(plot, boundsCF, boundsSize)
	if not plot then return false end
	local halfBounds = Vector3.new(boundsSize.X / 2, 0, boundsSize.Z / 2)
	if not pointInsideUnlockedGrid(plot, boundsCF.Position) then
		return false
	end
	for _, sx in ipairs(BOX_CORNER_SIGNS) do
		for _, sz in ipairs(BOX_CORNER_SIGNS) do
			local worldCorner = boundsCF:PointToWorldSpace(Vector3.new(
				sx * halfBounds.X,
				0,
				sz * halfBounds.Z
			))
			if not pointInsideUnlockedGrid(plot, worldCorner) then
				return false
			end
		end
	end
	return true
end

local function feedHitboxRootFromPart(plot, part)
	local current = part
	while current and current ~= plot do
		local feedType = current:GetAttribute(State.Feed.Type)
		if type(feedType) == "string" and feedType ~= "" and current:GetAttribute(State.Feed.Index) then
			if current:IsA("BasePart") then return current end
			if current:IsA("Model") then return current end
			return nil
		end
		current = current.Parent
	end
	return nil
end

local function setPreviewCFrame(preview, cframe)
	if preview:IsA("BasePart") then
		preview.CFrame = cframe
	elseif preview:IsA("Model") then
		preview:PivotTo(cframe)
	end
end

local function firstBasePart(root)
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Model") then
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("BasePart") then
				return descendant
			end
		end
	end
	return nil
end

function FeedPlacement.start()
	local player           = Players.LocalPlayer
	local PlayerGui        = player:WaitForChild("PlayerGui")
	local PlaceFeedMachine = Remotes.get(Remotes.Names.PlaceFeedMachine)
	local PlaceFeedMachineResult = Remotes.get(Remotes.Names.PlaceFeedMachineResult)
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local placementEditTemplate = uiFolder and uiFolder:FindFirstChild("PlacementEdit")
	if not (placementEditTemplate and placementEditTemplate:IsA("BillboardGui")) then
		warn("[FeedPlacement] Missing ReplicatedStorage.UI.PlacementEdit BillboardGui")
		return
	end

	local placementEdit = placementEditTemplate:Clone()
	placementEdit.Enabled = false
	placementEdit.Parent = PlayerGui

	local options = placementEdit:FindFirstChild("options")
	local confirmBtn = options and options:FindFirstChild("confirm")
	local moveBtn = options and options:FindFirstChild("move")
	local rotateBtn = options and options:FindFirstChild("rotate")
	local tipLabel = placementEdit:FindFirstChild("tip")
	if not (confirmBtn and confirmBtn:IsA("GuiButton")
		and moveBtn and moveBtn:IsA("GuiButton")
		and rotateBtn and rotateBtn:IsA("GuiButton")) then
		warn("[FeedPlacement] PlacementEdit missing confirm/move/rotate GuiButtons")
		placementEdit:Destroy()
		return
	end
	local confirmDefaults = {
		Active = confirmBtn.Active,
		AutoButtonColor = confirmBtn.AutoButtonColor,
		ImageTransparency = confirmBtn:IsA("ImageButton") and confirmBtn.ImageTransparency or nil,
		BackgroundTransparency = confirmBtn.BackgroundTransparency,
		Visible = confirmBtn.Visible,
	}

	local preview, currentRotation, placing = nil, 0, false
	local activeFeedType = nil  -- set when a FeedMachine tool is equipped
	local activeSeedId = nil
	local activeTool = nil
	local selectedLX, selectedLZ = nil, nil
	local previewPlacementHeight = nil
	local previewPrimaryOffset = CFrame.new()
	local previewBoundsOffset = CFrame.new()
	local previewBoundsSize = nil
	local previewPartColors = {}
	local currentPlacementBlocked = true
	local nextPlacementRequestId = 0
	local pendingPlacementRequestId = nil
	local pendingPlacementCFrame = nil
	local pendingSuppressOverlapError = false
	local unequippedWhilePending = false
	local placementGrid = nil
	local moving = false
	local touchScreenPosition = nil
	local ignoreWorldInputUntil = 0
	local boundTools = setmetatable({}, { __mode = "k" })

	local function snapToGrid(v) return math.round(v) end

	local function setGridEffectEnabled(enabled)
		if placementGrid then placementGrid:SetEnabled(enabled) end
	end

	local getPlayerFloor
	local getPlayerPlot

	local function previewAdornee()
		if not preview then return nil end
		if preview:IsA("BasePart") then return preview end
		if preview:IsA("Model") then return preview.PrimaryPart or firstBasePart(preview) end
		return nil
	end

	local function updatePlacementEditOffset()
		local floor = getPlayerFloor and getPlayerFloor() or nil
		local adornee = placementEdit.Adornee
		if not (floor and floor:IsA("BasePart") and adornee and selectedLX ~= nil and selectedLZ ~= nil) then
			return
		end
		local worldPosition = floor.CFrame:PointToWorldSpace(Vector3.new(
			selectedLX,
			floor.Size.Y / 2 + PLACEMENT_EDIT_FLOOR_OFFSET,
			selectedLZ
		))
		placementEdit.StudsOffsetWorldSpace = worldPosition - adornee.Position
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
		if confirmBtn:IsA("ImageButton") and confirmDefaults.ImageTransparency ~= nil then
			confirmBtn.ImageTransparency = enabled
				and confirmDefaults.ImageTransparency
				or math.max(confirmDefaults.ImageTransparency, 0.45)
		end
	end

	local function setPlacementEditVisible(visible)
		placementEdit.Adornee = visible and previewAdornee() or nil
		if not placementEdit.Adornee then
			placementEdit.StudsOffsetWorldSpace = Vector3.zero
		else
			updatePlacementEditOffset()
		end
		placementEdit.Enabled = visible and placementEdit.Adornee ~= nil
		if tipLabel and tipLabel:IsA("TextLabel") then
			tipLabel.Text = moving and "Release to place" or "Hold to move"
		end
	end

	setPlacementEditVisible(false)

	local function cachePlacementBounds(template)
		previewPlacementHeight = templateHeight(template)
		previewBoundsOffset = CFrame.new()
		previewBoundsSize = nil
		if not template then return end
		if template:IsA("BasePart") then
			previewBoundsSize = template.Size
		elseif template:IsA("Model") and template.PrimaryPart then
			previewBoundsOffset = template:GetPivot():ToObjectSpace(template.PrimaryPart.CFrame)
			previewBoundsSize = template.PrimaryPart.Size
		end
	end

	local function shouldUseTreeSaplingPreview()
		return activeSeedId ~= nil and GrowingVisuals.FeedClassFor(activeFeedType) == "Tree"
	end

	local function buildPreview()
		if preview then preview:Destroy() end
		previewPartColors = {}
		local template = activeFeedType and findTemplate(activeFeedType)
		if not template then return end
		-- Tree seeds preview as saplings, but reserve the mature tree footprint.
		cachePlacementBounds(template)
		local clone = shouldUseTreeSaplingPreview()
			and GrowingVisuals.BuildTreeSapling(activeFeedType)
			or template:Clone()
		if not clone then return end
		clone.Name = "__FeedPreview"
		local function preparePreviewPart(part)
			previewPartColors[part] = part.Color
			setPreviewProps(part)
		end
		if clone:IsA("BasePart") then
			preparePreviewPart(clone)
			previewPrimaryOffset = CFrame.new()
			-- strip ClickDetectors / ProximityPrompts so the preview is purely visual
			for _, c in ipairs(clone:GetChildren()) do c:Destroy() end
		elseif clone:IsA("Model") then
			if clone.PrimaryPart then
				previewPrimaryOffset = clone:GetPivot():ToObjectSpace(clone.PrimaryPart.CFrame)
			else
				previewPrimaryOffset = CFrame.new()
			end
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
		previewPlacementHeight = nil
		previewPrimaryOffset = CFrame.new()
		previewBoundsOffset = CFrame.new()
		previewBoundsSize = nil
		previewPartColors = {}
		currentPlacementBlocked = true
		pendingPlacementRequestId = nil
		pendingPlacementCFrame = nil
		pendingSuppressOverlapError = false
		unequippedWhilePending = false
		moving = false
		touchScreenPosition = nil
		setGridEffectEnabled(false)
		setPlacementEditVisible(false)
		setConfirmVisible(true)
		setConfirmEnabled(false)
	end

	-- The player's plot Floor is used to snap the preview in plot-local axes,
	-- so the grid and rotation align with rotated plots.
	getPlayerFloor = function()
		local plot = PlotResolver.ResolveForPlayer(player)
		return plot and plot:FindFirstChild("Floor") or nil
	end

	getPlayerPlot = function()
		return PlotResolver.ResolveForPlayer(player)
	end

	placementGrid = PlacementGrid.new(getPlayerFloor)

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

		local halfH = (previewPlacementHeight or previewSizeY(preview)) / 2
		local localCF = CFrame.new(selectedLX, floor.Size.Y / 2 + halfH, selectedLZ)
			* CFrame.Angles(0, math.rad(currentRotation), 0)
		return floor.CFrame * localCF
	end

	local function getPreviewBoundsAt(cframe)
		if not preview or typeof(cframe) ~= "CFrame" then return nil, nil end
		if previewBoundsSize then
			return cframe * previewBoundsOffset, previewBoundsSize
		end
		if preview:IsA("BasePart") then
			return cframe, preview.Size
		end
		if preview:IsA("Model") then
			local primary = preview.PrimaryPart
			if primary then
				return cframe * previewPrimaryOffset, primary.Size
			end
		end
		return nil, nil
	end

	local function applyPreviewCFrame()
		if not preview then return end
		local cf = getSelectedCFrame()
		if not cf then return end
		setPreviewCFrame(preview, cf)
		if shouldUseTreeSaplingPreview() then
			GrowingVisuals.AlignBottomToFloorTop(preview, getPlayerFloor())
		end
		updatePlacementEditOffset()
	end

	local function getPreviewBounds()
		return getPreviewBoundsAt(getSelectedCFrame())
	end

	local function previewFitsOnGridAt(lx, lz)
		local floor = getPlayerFloor()
		local plot = getPlayerPlot()
		if not floor or not floor:IsA("BasePart") then return false end
		if not preview then return false end
		local halfH = (previewPlacementHeight or previewSizeY(preview)) / 2
		local localCF = CFrame.new(lx, floor.Size.Y / 2 + halfH, lz)
			* CFrame.Angles(0, math.rad(currentRotation), 0)
		local boundsCF, boundsSize = getPreviewBoundsAt(floor.CFrame * localCF)
		if not boundsCF or not boundsSize then return false end
		return boundsFitOnFloor(floor, boundsCF, boundsSize)
			and boundsFitOnUnlockedGrid(plot, boundsCF, boundsSize)
	end

	local function previewFitsOnGrid()
		if selectedLX == nil or selectedLZ == nil then return false end
		return previewFitsOnGridAt(selectedLX, selectedLZ)
	end

	local function previewOverlapsFeed()
		local plot = getPlayerPlot()
		if not plot then return true end
		local boundsCF, boundsSize = getPreviewBounds()
		if not boundsCF or not boundsSize then return true end
		local querySize = Vector3.new(
			math.max(boundsSize.X - OVERLAP_QUERY_INSET, 0.05),
			boundsSize.Y,
			math.max(boundsSize.Z - OVERLAP_QUERY_INSET, 0.05)
		)

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { plot }

		for _, part in ipairs(workspace:GetPartBoundsInBox(boundsCF, querySize, params)) do
			if feedHitboxRootFromPart(plot, part) then
				return true
			end
		end
		return false
	end

	local function previewPlacementBlocked()
		return not previewFitsOnGrid() or previewOverlapsFeed()
	end

	local function screenHitsPreview(screenPosition)
		local camera = workspace.CurrentCamera
		local boundsCF, boundsSize = getPreviewBounds()
		if not camera or not boundsCF or not boundsSize then return false end

		local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
		local origin = boundsCF:PointToObjectSpace(ray.Origin)
		local direction = boundsCF:VectorToObjectSpace(ray.Direction)
		local half = boundsSize / 2
		local tMin = -math.huge
		local tMax = math.huge

		for _, axis in ipairs({
			{ origin = origin.X, direction = direction.X, half = half.X },
			{ origin = origin.Y, direction = direction.Y, half = half.Y },
			{ origin = origin.Z, direction = direction.Z, half = half.Z },
		}) do
			local axisOrigin = axis.origin
			local axisDirection = axis.direction
			local axisHalf = axis.half
			if math.abs(axisDirection) < 0.0001 then
				if axisOrigin < -axisHalf or axisOrigin > axisHalf then
					return false
				end
			else
				local t1 = (-axisHalf - axisOrigin) / axisDirection
				local t2 = (axisHalf - axisOrigin) / axisDirection
				tMin = math.max(tMin, math.min(t1, t2))
				tMax = math.min(tMax, math.max(t1, t2))
				if tMin > tMax then
					return false
				end
			end
		end

		return tMax >= 0
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

	local function rotatePreview()
		currentRotation = (currentRotation + 90) % 360
		if preview and selectedLX ~= nil and selectedLZ ~= nil then
			applyPreviewCFrame()
			setPreviewBlocked(previewPlacementBlocked())
		end
	end

	local function floorLocalPointFromScreen(screenPosition)
		local floor = getPlayerFloor()
		local camera = workspace.CurrentCamera
		if not floor or not floor:IsA("BasePart") or not camera then return nil end

		local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
		local planePoint = floor.CFrame:PointToWorldSpace(Vector3.new(0, floor.Size.Y / 2, 0))
		local planeNormal = floor.CFrame.UpVector
		local denominator = ray.Direction:Dot(planeNormal)
		if math.abs(denominator) < 0.0001 then return nil end

		local distance = (planePoint - ray.Origin):Dot(planeNormal) / denominator
		if distance < 0 then return nil end
		return floor.CFrame:PointToObjectSpace(ray.Origin + ray.Direction * distance)
	end

	local function nearestUnlockedLocalPoint(localTarget)
		local floor = getPlayerFloor()
		local plot = getPlayerPlot()
		if not floor or not plot then return nil, nil end

		local halfFloorX = floor.Size.X / 2
		local halfFloorZ = floor.Size.Z / 2
		local targetWorld = floor.CFrame:PointToWorldSpace(Vector3.new(localTarget.X, floor.Size.Y / 2, localTarget.Z))
		local bestFitLX, bestFitLZ, bestFitDistance = nil, nil, math.huge
		local bestAnyLX, bestAnyLZ, bestAnyDistance = nil, nil, math.huge
		local searchRadius = 1
		if preview then
			local halfH = (previewPlacementHeight or previewSizeY(preview)) / 2
			local boundsCF = floor.CFrame
				* CFrame.new(0, floor.Size.Y / 2 + halfH, 0)
				* CFrame.Angles(0, math.rad(currentRotation), 0)
			local _, boundsSize = getPreviewBoundsAt(boundsCF)
			if boundsSize then
				searchRadius = math.max(searchRadius, math.ceil(math.max(boundsSize.X, boundsSize.Z) / 2) + 1)
			end
		end

		local function consider(lx, lz)
			local candidateWorld = floor.CFrame:PointToWorldSpace(Vector3.new(lx, floor.Size.Y / 2, lz))
			if not pointInsideUnlockedGrid(plot, candidateWorld) then return end

			local distance = (Vector2.new(lx, lz) - Vector2.new(localTarget.X, localTarget.Z)).Magnitude
			if distance < bestAnyDistance then
				bestAnyLX, bestAnyLZ, bestAnyDistance = lx, lz, distance
			end
			if previewFitsOnGridAt(lx, lz) and distance < bestFitDistance then
				bestFitLX, bestFitLZ, bestFitDistance = lx, lz, distance
			end
		end

		for _, gridPart in ipairs(unlockedGridParts(plot)) do
			local gridLocal = gridPart.CFrame:PointToObjectSpace(targetWorld)
			local clampedWorld = gridPart.CFrame:PointToWorldSpace(Vector3.new(
				math.clamp(gridLocal.X, -gridPart.Size.X / 2, gridPart.Size.X / 2),
				gridLocal.Y,
				math.clamp(gridLocal.Z, -gridPart.Size.Z / 2, gridPart.Size.Z / 2)
			))
			local floorLocal = floor.CFrame:PointToObjectSpace(clampedWorld)
			local baseLX = math.clamp(snapToGrid(floorLocal.X), -halfFloorX, halfFloorX)
			local baseLZ = math.clamp(snapToGrid(floorLocal.Z), -halfFloorZ, halfFloorZ)
			for dx = -searchRadius, searchRadius do
				for dz = -searchRadius, searchRadius do
					consider(
						math.clamp(baseLX + dx, -halfFloorX, halfFloorX),
						math.clamp(baseLZ + dz, -halfFloorZ, halfFloorZ)
					)
				end
			end
		end

		return bestFitLX or bestAnyLX, bestFitLZ or bestAnyLZ
	end

	local function selectFloorCellFromScreen(screenPosition)
		local floor = getPlayerFloor()
		local plot = getPlayerPlot()
		if not floor or not floor:IsA("BasePart") or not plot then return false end

		if not ensurePreview() then return false end
		local localTarget = floorLocalPointFromScreen(screenPosition)
		if not localTarget then return false end
		local snappedLX, snappedLZ = nearestUnlockedLocalPoint(localTarget)
		if snappedLX == nil or snappedLZ == nil then return false end

		setGridEffectEnabled(true)
		selectedLX = snappedLX
		selectedLZ = snappedLZ
		applyPreviewCFrame()
		setPlacementEditVisible(true)
		setPreviewBlocked(previewPlacementBlocked())
		return true
	end

	local function confirmPlacement(showBlockedError)
		if pendingPlacementRequestId ~= nil then return end
		if not placing or not preview or selectedLX == nil or selectedLZ == nil then return end
		if currentPlacementBlocked then
			if showBlockedError ~= false then
				NotificationUi.show({
					kind = NotificationConfig.Kinds.Error,
					text = placementFailureMessage("overlap"),
				})
			end
			return
		end
		local cf = getSelectedCFrame()
		if not cf then return end

		nextPlacementRequestId += 1
		pendingPlacementRequestId = nextPlacementRequestId
		pendingPlacementCFrame = cf
		pendingSuppressOverlapError = showBlockedError == false
		unequippedWhilePending = false
		placing = false
		moving = false
		setGridEffectEnabled(false)
		setPlacementEditVisible(false)
		setConfirmEnabled(false)
		PlaceFeedMachine:FireServer(pendingPlacementRequestId, cf)
	end

	local function beginMoving(input)
		if not placing or not preview or pendingPlacementRequestId ~= nil then return end
		moving = true
		if input and input.UserInputType == Enum.UserInputType.Touch then
			touchScreenPosition = input.Position
		else
			touchScreenPosition = nil
		end
		setPlacementEditVisible(true)
	end

	local function stopMoving()
		if not moving then return end
		moving = false
		touchScreenPosition = nil
		setPlacementEditVisible(preview ~= nil)
	end

	local function screenPositionForDrag()
		if touchScreenPosition then
			return touchScreenPosition
		end
		return UserInputService:GetMouseLocation()
	end

	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe or not placing then return end
		if input.KeyCode == Enum.KeyCode.R then
			rotatePreview()
		elseif input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			if os.clock() < ignoreWorldInputUntil then return end
			if preview and selectedLX ~= nil and selectedLZ ~= nil then
				if screenHitsPreview(input.Position) then return end
				confirmPlacement(false)
			else
				selectFloorCellFromScreen(input.Position)
			end
		end
	end)

	if confirmBtn then
		confirmBtn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				ignoreWorldInputUntil = os.clock() + 0.2
			end
		end)
		confirmBtn.Activated:Connect(confirmPlacement)
	end
	moveBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			ignoreWorldInputUntil = os.clock() + 0.2
			beginMoving(input)
		end
	end)
	moveBtn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			ignoreWorldInputUntil = os.clock() + 0.2
			stopMoving()
		end
	end)
	rotateBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			ignoreWorldInputUntil = os.clock() + 0.2
		end
	end)
	rotateBtn.Activated:Connect(function()
		rotatePreview()
	end)

	UserInputService.InputChanged:Connect(function(input)
		if moving and input.UserInputType == Enum.UserInputType.Touch then
			touchScreenPosition = input.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			stopMoving()
		end
	end)
	RunService.RenderStepped:Connect(function()
		if moving then
			selectFloorCellFromScreen(screenPositionForDrag())
		end
	end)

	PlaceFeedMachineResult.OnClientEvent:Connect(function(requestId, success, reason)
		if requestId ~= pendingPlacementRequestId then return end
		pendingPlacementRequestId = nil
		local placedCFrame = pendingPlacementCFrame
		local suppressOverlapError = pendingSuppressOverlapError
		pendingPlacementCFrame = nil
		pendingSuppressOverlapError = false

		if not success then
			if unequippedWhilePending then
				activeFeedType = nil
				activeSeedId = nil
				destroyPreview()
				return
			end
			placing = true
			setPlacementEditVisible(preview ~= nil)
			setGridEffectEnabled(true)
			if preview and selectedLX ~= nil and selectedLZ ~= nil then
				setPreviewBlocked(previewPlacementBlocked())
			else
				currentPlacementBlocked = true
				setConfirmEnabled(false)
			end
			if not (suppressOverlapError and reason == "overlap") then
				NotificationUi.show({
					kind = NotificationConfig.Kinds.Error,
					text = placementFailureMessage(reason),
				})
			end
			return
		end

		if not preview then
			activeFeedType = nil
			activeSeedId = nil
			destroyPreview()
			return
		end

		if not placedCFrame then
			activeFeedType = nil
			activeSeedId = nil
			destroyPreview()
			return
		end

		placing = false
		setPlacementEditVisible(false)
		setGridEffectEnabled(false)
		setConfirmEnabled(false)
		setPreviewCFrame(preview, placedCFrame)
		activeFeedType = nil
		activeSeedId = nil
		activeTool = nil
		destroyPreview()
	end)

	local function bindTool(tool)
		if not tool:IsA("Tool") or boundTools[tool] then return end
		local seedId = tool:GetAttribute(State.Seed.Id)
		local toolFeedType = nil
		if type(seedId) == "string" and seedId ~= "" then
			toolFeedType = Seeds.FeedTypeFor(seedId)
		else
			toolFeedType = tool:GetAttribute(State.Feed.Type)
		end
		if type(toolFeedType) ~= "string" or toolFeedType == "" then return end
		boundTools[tool] = true

		local function activateTool()
			activeTool = tool
			activeFeedType  = toolFeedType
			activeSeedId = type(seedId) == "string" and seedId ~= "" and seedId or nil
			placing         = true
			currentRotation = 0
			selectedLX      = nil
			selectedLZ      = nil
			currentPlacementBlocked = true
			setPlacementEditVisible(false)
			setConfirmVisible(true)
			setConfirmEnabled(false)
			setGridEffectEnabled(true)
		end

		tool.Equipped:Connect(activateTool)
		if tool.Parent == player.Character then
			activateTool()
		end

		tool.Unequipped:Connect(function()
			if activeTool ~= tool then
				return
			end
			activeTool = nil
			if pendingPlacementRequestId ~= nil then
				unequippedWhilePending = true
				setGridEffectEnabled(false)
				return
			end
			destroyPreview()
			activeFeedType = nil
			activeSeedId = nil
		end)
	end

	local function watchBackpack()
		for _, item in ipairs(player.Backpack:GetChildren()) do bindTool(item) end
	end

	local function watchCharacter(character)
		if not character then return end
		for _, item in ipairs(character:GetChildren()) do bindTool(item) end
		character.ChildAdded:Connect(bindTool)
	end

	player.Backpack.ChildAdded:Connect(bindTool)
	player.CharacterAdded:Connect(function(character)
		destroyPreview()
		watchBackpack()
		watchCharacter(character)
	end)

	watchBackpack()
	watchCharacter(player.Character)
end

return FeedPlacement
