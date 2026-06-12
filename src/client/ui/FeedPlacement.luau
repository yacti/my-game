-- Feed/seed placement preview. Players equip an inventory tool, click an
-- unlocked grid cell, then confirm or adjust through the Studio-authored
-- ReplicatedStorage.UI.BillboardGUIs.PlacementEdit billboard.

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local GrowingVisuals = require(Shared:WaitForChild("GrowingVisuals"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local State   = require(Shared:WaitForChild("State"))
local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local NotificationUi = require(script.Parent:WaitForChild("Notifications"))
local PlacementEditAnchor = require(script.Parent:WaitForChild("PlacementEditAnchor"))
local PlacementGrid = require(script.Parent:WaitForChild("PlacementGrid"))
local PlacementInput = require(script.Parent:WaitForChild("PlacementInput"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local PREVIEW_PART_TRANSPARENCY = 0.2
local PREVIEW_BLOCKED_COLOR = Color3.fromRGB(255, 65, 65)
-- World-space gap above the placeable's bounding-box top (the panel anchors
-- to a PlacementEditAnchor attachment, not a fixed part).
local PLACEMENT_EDIT_OFFSET = Vector3.new(0, 2.5, 0)
local PLACEMENT_EDIT_DRAG_TRANSPARENCY = 0.6
local FOOTPRINT_BOUNDS_EPSILON = 0.001
local OVERLAP_QUERY_INSET = 0.05
local BOX_CORNER_SIGNS = { -1, 1 }
local EDIT_SELECTION_HITBOX_NAME = "EditSelectionHitbox"
local ROTATION_TWEEN_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function isHiddenPreviewPart(part)
	return part.Name:match("^BaseFood") ~= nil or part.Name == EDIT_SELECTION_HITBOX_NAME
end

-- Templates live at ReplicatedStorage.Assets.FeedMachines.<Class>.<DisplayName>. The
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
	["no-cosmetic-tool"] = "Equip a cosmetic before placing.",
	["no-feed-tool"] = "Equip a feed machine before placing.",
	["no-profile"] = "Your save data is not ready yet.",
	["out-of-bounds"] = "Place items inside unlocked plot cells.",
	["overlap"] = "That spot is already occupied.",
	["rate-limited"] = "Please wait before placing again.",
	["save-failed"] = "Could not save that placement. Please try again.",
	["setup-failed"] = "Could not set up that feed machine.",
	["too-far"] = "Move closer to place that item.",
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

local function placeableHitboxRootFromPart(plot, part)
	local current = part
	while current and current ~= plot do
		local feedType = current:GetAttribute(State.Feed.Type)
		if type(feedType) == "string" and feedType ~= "" and current:GetAttribute(State.Feed.Index) then
			if current:IsA("BasePart") then return current end
			if current:IsA("Model") then return current end
			return nil
		end
		local cosmeticId = current:GetAttribute(State.Cosmetic.Id)
		if type(cosmeticId) == "string" and cosmeticId ~= "" and current:GetAttribute(State.Cosmetic.Index) then
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

local function placementBoundsPart(model)
	local hitbox = model:FindFirstChild(EDIT_SELECTION_HITBOX_NAME)
	if hitbox and hitbox:IsA("BasePart") then
		return hitbox
	end
	return model.PrimaryPart
end

local function validToolGuid(guid)
	return type(guid) == "string" and guid ~= ""
end

function FeedPlacement.start()
	local player           = Players.LocalPlayer
	local PlayerGui        = player:WaitForChild("PlayerGui")
	local PlaceCosmetic = Remotes.get(Remotes.Names.PlaceCosmetic)
	local PlaceCosmeticResult = Remotes.get(Remotes.Names.PlaceCosmeticResult)
	local PlaceFeedMachine = Remotes.get(Remotes.Names.PlaceFeedMachine)
	local PlaceFeedMachineResult = Remotes.get(Remotes.Names.PlaceFeedMachineResult)
	local placementEditTemplate = BillboardGuiTemplates.Find("PlacementEdit")
	if not (placementEditTemplate and placementEditTemplate:IsA("BillboardGui")) then
		warn("[FeedPlacement] Missing " .. BillboardGuiTemplates.Path("PlacementEdit") .. " BillboardGui")
		return
	end

	local placementEdit = placementEditTemplate:Clone()
	UiEffects.BindBillboardPop(placementEdit)
	placementEdit.Enabled = false

	-- Wrapped so the whole panel fades as one layer while dragging.
	local placementEditCanvas = UiEffects.WrapInCanvasGroup(placementEdit)
	placementEdit.StudsOffsetWorldSpace = PLACEMENT_EDIT_OFFSET
	placementEdit.Parent = PlayerGui

	local options = placementEditCanvas:FindFirstChild("options")
	local confirmBtn = options and options:FindFirstChild("confirm")
	local moveBtn = options and options:FindFirstChild("move")
	local rotateBtn = options and options:FindFirstChild("rotate")
	local tipLabel = placementEditCanvas:FindFirstChild("tip")
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
	local activeCosmeticId = nil
	local activeTool = nil
	local activeToolGuid = nil
	local selectedLX, selectedLZ = nil, nil
	local previewPlacementHeight = nil
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
	local worldTap = PlacementInput.NewTapRecognizer()
	local ignoreWorldInputUntil = 0
	local boundTools = setmetatable({}, { __mode = "k" })
	local rotationTween = nil
	local rotationTweenValue = nil
	local rotationTweenConnection = nil
	local rotationTweenToken = 0

	local function snapToGrid(v) return math.round(v) end

	local function isOfflineProgressPending()
		return player:GetAttribute(State.Player.OfflineProgressPending) == true
	end

	local function setGridEffectEnabled(enabled)
		if placementGrid then placementGrid:SetEnabled(enabled) end
	end

	local getPlayerFloor
	local getPlayerPlot

	local function previewAdornee()
		if not (preview and preview.Parent) then return nil end
		return PlacementEditAnchor.Attach(preview)
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
		placementEdit.Enabled = visible and placementEdit.Adornee ~= nil
		if tipLabel and tipLabel:IsA("TextLabel") then
			tipLabel.Text = moving and "Release to place" or "Hold to move"
		end
		local targetTransparency = moving and PLACEMENT_EDIT_DRAG_TRANSPARENCY or 0
		UiEffects.SetGroupTransparency(placementEditCanvas, targetTransparency, not placementEdit.Enabled)
	end

	setPlacementEditVisible(false)

	local function cachePlacementBounds(template)
		previewPlacementHeight = templateHeight(template)
		previewBoundsOffset = CFrame.new()
		previewBoundsSize = nil
		if not template then return end
		if template:IsA("BasePart") then
			previewBoundsSize = template.Size
		elseif template:IsA("Model") then
			local boundsPart = placementBoundsPart(template)
			if boundsPart then
				previewBoundsOffset = template:GetPivot():ToObjectSpace(boundsPart.CFrame)
				previewBoundsSize = boundsPart.Size
			end
		end
	end

	local function shouldUseTreeSaplingPreview()
		return activeSeedId ~= nil and activeFeedType ~= nil and GrowingVisuals.FeedClassFor(activeFeedType) == "Tree"
	end

	local function activeTemplate()
		if activeCosmeticId then
			return Cosmetics.GetTemplate(activeCosmeticId)
		end
		return activeFeedType and findTemplate(activeFeedType) or nil
	end

	local function buildPreview()
		if preview then preview:Destroy() end
		previewPartColors = {}
		local template = activeTemplate()
		if not template then return end
		-- Tree seeds preview as saplings, but reserve the mature tree footprint.
		cachePlacementBounds(template)
		local clone = shouldUseTreeSaplingPreview()
			and GrowingVisuals.BuildTreeSapling(activeFeedType)
			or template:Clone()
		if not clone then return end
		clone.Name = "__PlacementPreview"
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

	local cancelRotationTween

	local function destroyPreview()
		if cancelRotationTween then
			cancelRotationTween()
		end
		if preview then preview:Destroy() preview = nil end
		placing         = false
		currentRotation = 0
		selectedLX      = nil
		selectedLZ      = nil
		previewPlacementHeight = nil
		previewBoundsOffset = CFrame.new()
		previewBoundsSize = nil
		previewPartColors = {}
		currentPlacementBlocked = true
		pendingPlacementRequestId = nil
		pendingPlacementCFrame = nil
		pendingSuppressOverlapError = false
		unequippedWhilePending = false
		moving = false
		worldTap:Cancel()
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

	function cancelRotationTween()
		rotationTweenToken += 1
		if rotationTween then
			rotationTween:Cancel()
			rotationTween = nil
		end
		if rotationTweenConnection then
			rotationTweenConnection:Disconnect()
			rotationTweenConnection = nil
		end
		if rotationTweenValue then
			rotationTweenValue:Destroy()
			rotationTweenValue = nil
		end
	end

	local function tweenPreviewTo(cframe)
		if not preview then return end
		cancelRotationTween()

		rotationTweenToken += 1
		local token = rotationTweenToken
		local value = Instance.new("CFrameValue")
		value.Value = preview:GetPivot()
		rotationTweenValue = value
		rotationTweenConnection = RuntimeGuard.Connect(value:GetPropertyChangedSignal("Value"), "FeedPlacement.RotateTweenStep", function()
			if preview then
				setPreviewCFrame(preview, value.Value)
				if shouldUseTreeSaplingPreview() then
					GrowingVisuals.AlignBottomToFloorTop(preview, getPlayerFloor())
				end
			end
		end)
		rotationTween = TweenService:Create(value, ROTATION_TWEEN_INFO, { Value = cframe })
		RuntimeGuard.Connect(rotationTween.Completed, "FeedPlacement.RotateTweenCompleted", function()
			if rotationTweenToken ~= token then
				return
			end
			if preview then
				setPreviewCFrame(preview, cframe)
				if shouldUseTreeSaplingPreview() then
					GrowingVisuals.AlignBottomToFloorTop(preview, getPlayerFloor())
				end
			end
			rotationTween = nil
			if rotationTweenConnection then
				rotationTweenConnection:Disconnect()
				rotationTweenConnection = nil
			end
			if rotationTweenValue then
				rotationTweenValue:Destroy()
				rotationTweenValue = nil
			end
		end)
		rotationTween:Play()
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
			local boundsPart = placementBoundsPart(preview)
			if boundsPart then
				local boundsOffset = preview:GetPivot():ToObjectSpace(boundsPart.CFrame)
				return cframe * boundsOffset, boundsPart.Size
			end
		end
		return nil, nil
	end

	local function applyPreviewCFrame()
		if not preview then return end
		local cf = getSelectedCFrame()
		if not cf then return end
		cancelRotationTween()
		setPreviewCFrame(preview, cf)
		if shouldUseTreeSaplingPreview() then
			GrowingVisuals.AlignBottomToFloorTop(preview, getPlayerFloor())
		end
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

	local function previewOverlapsPlaceable()
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
			if placeableHitboxRootFromPart(plot, part) then
				return true
			end
		end
		return false
	end

	local function previewPlacementBlocked()
		return not previewFitsOnGrid() or previewOverlapsPlaceable()
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
			local cframe = getSelectedCFrame()
			if cframe then
				tweenPreviewTo(cframe)
			end
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
		if isOfflineProgressPending() then return end
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
		if not validToolGuid(activeToolGuid) then return end

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
		if activeCosmeticId then
			PlaceCosmetic:FireServer(pendingPlacementRequestId, cf, activeToolGuid)
		else
			PlaceFeedMachine:FireServer(pendingPlacementRequestId, cf, activeToolGuid)
		end
	end

	local function beginMoving()
		if not placing or not preview or pendingPlacementRequestId ~= nil then return end
		moving = true
		worldTap:Cancel()
		setPlacementEditVisible(true)
	end

	local function stopMoving()
		if not moving then return end
		moving = false
		setPlacementEditVisible(preview ~= nil)
	end

	local function updateDragPreview(screenPosition)
		if not moving then
			return
		end
		if pendingPlacementRequestId ~= nil then
			moving = false
			setPlacementEditVisible(false)
			return
		end
		if not placing or not preview or not preview.Parent then
			stopMoving()
			return
		end
		if screenPosition then
			selectFloorCellFromScreen(screenPosition)
		end
	end

	local function handleWorldPlacementTap(screenPosition)
		if not screenPosition then return end
		if preview and selectedLX ~= nil and selectedLZ ~= nil then
			if screenHitsPreview(screenPosition) then return end
			confirmPlacement(false)
		else
			selectFloorCellFromScreen(screenPosition)
		end
	end

	RuntimeGuard.Connect(UserInputService.InputBegan, "FeedPlacement.InputBegan", function(input, gpe)
		if isOfflineProgressPending() then return end
		if gpe or not placing or moving then return end
		if input.KeyCode == Enum.KeyCode.R then
			rotatePreview()
		elseif input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			if os.clock() < ignoreWorldInputUntil then return end
			if PlacementInput.IsInteractiveGuiAt(input.Position) then return end
			if input.UserInputType == Enum.UserInputType.Touch then
				worldTap:Begin(input)
			else
				handleWorldPlacementTap(input.Position)
			end
		end
	end)

	if confirmBtn then
		RuntimeGuard.Connect(confirmBtn.InputBegan, "FeedPlacement.ConfirmInputBegan", function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				ignoreWorldInputUntil = os.clock() + 0.2
			end
		end)
		RuntimeGuard.Connect(confirmBtn.Activated, "FeedPlacement.ConfirmActivated", confirmPlacement)
	end
	PlacementInput.BindMoveDrag(moveBtn, "FeedPlacement.MoveDrag", {
		canStart = function()
			return not isOfflineProgressPending()
				and placing
				and preview ~= nil
				and pendingPlacementRequestId == nil
		end,
		onStart = function()
			ignoreWorldInputUntil = os.clock() + 0.2
			beginMoving()
		end,
		onContinue = function(screenPosition)
			updateDragPreview(screenPosition)
		end,
		onEnd = function(screenPosition)
			ignoreWorldInputUntil = os.clock() + 0.2
			updateDragPreview(screenPosition)
			stopMoving()
		end,
	})
	RuntimeGuard.Connect(moveBtn.InputBegan, "FeedPlacement.MoveInputBegan", function(input)
		if PlacementInput.IsPressInput(input) then
			ignoreWorldInputUntil = os.clock() + 0.2
		end
	end)
	RuntimeGuard.Connect(rotateBtn.InputBegan, "FeedPlacement.RotateInputBegan", function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			ignoreWorldInputUntil = os.clock() + 0.2
		end
	end)
	RuntimeGuard.Connect(rotateBtn.Activated, "FeedPlacement.RotateActivated", function()
		if isOfflineProgressPending() then return end
		rotatePreview()
	end)

	RuntimeGuard.Connect(UserInputService.InputChanged, "FeedPlacement.InputChanged", function(input)
		worldTap:Changed(input)
	end)
	RuntimeGuard.Connect(UserInputService.InputEnded, "FeedPlacement.InputEnded", function(input)
		local tap = worldTap:End(input)
		if not tap then
			return
		end
		if isOfflineProgressPending() or not placing or moving then return end
		if os.clock() < ignoreWorldInputUntil then return end
		handleWorldPlacementTap(tap.position)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.OfflineProgressPending), "FeedPlacement.OfflineProgressPendingChanged", function()
		if isOfflineProgressPending() then
			destroyPreview()
		end
	end)

	local function handlePlaceResult(requestId, success, reason)
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
				activeCosmeticId = nil
				activeToolGuid = nil
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
			activeCosmeticId = nil
			activeToolGuid = nil
			destroyPreview()
			return
		end

		if not placedCFrame then
			activeFeedType = nil
			activeSeedId = nil
			activeCosmeticId = nil
			activeToolGuid = nil
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
		activeCosmeticId = nil
		activeTool = nil
		activeToolGuid = nil
		destroyPreview()
	end

	RuntimeGuard.Connect(PlaceFeedMachineResult.OnClientEvent, "FeedPlacement.PlaceFeedResult", handlePlaceResult)
	RuntimeGuard.Connect(PlaceCosmeticResult.OnClientEvent, "FeedPlacement.PlaceCosmeticResult", handlePlaceResult)

	local function bindTool(tool)
		if not tool:IsA("Tool") or boundTools[tool] then return end
		local toolGuid = tool:GetAttribute(State.Tool.Guid)
		if not validToolGuid(toolGuid) then return end
		local cosmeticId = tool:GetAttribute(State.Cosmetic.Id)
		if type(cosmeticId) == "string" and cosmeticId ~= "" then
			if not Cosmetics.GetTemplate(cosmeticId) then return end
			boundTools[tool] = true

			local function activateCosmeticTool()
				activeTool = tool
				activeToolGuid = toolGuid
				activeFeedType = nil
				activeSeedId = nil
				activeCosmeticId = cosmeticId
				placing = true
				currentRotation = 0
				selectedLX = nil
				selectedLZ = nil
				currentPlacementBlocked = true
				setPlacementEditVisible(false)
				setConfirmVisible(true)
				setConfirmEnabled(false)
				setGridEffectEnabled(true)
			end

			RuntimeGuard.Connect(tool.Equipped, "FeedPlacement.CosmeticToolEquipped", activateCosmeticTool)
			if tool.Parent == player.Character then
				activateCosmeticTool()
			end

			RuntimeGuard.Connect(tool.Unequipped, "FeedPlacement.CosmeticToolUnequipped", function()
				if activeTool ~= tool then
					return
				end
				activeTool = nil
				activeToolGuid = nil
				if pendingPlacementRequestId ~= nil then
					unequippedWhilePending = true
					setGridEffectEnabled(false)
					return
				end
				destroyPreview()
				activeCosmeticId = nil
			end)
			return
		end
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
			activeToolGuid = toolGuid
			activeFeedType  = toolFeedType
			activeSeedId = type(seedId) == "string" and seedId ~= "" and seedId or nil
			activeCosmeticId = nil
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

		RuntimeGuard.Connect(tool.Equipped, "FeedPlacement.ToolEquipped", activateTool)
		if tool.Parent == player.Character then
			activateTool()
		end

		RuntimeGuard.Connect(tool.Unequipped, "FeedPlacement.ToolUnequipped", function()
			if activeTool ~= tool then
				return
			end
			activeTool = nil
			activeToolGuid = nil
			if pendingPlacementRequestId ~= nil then
				unequippedWhilePending = true
				setGridEffectEnabled(false)
				return
			end
			destroyPreview()
			activeFeedType = nil
			activeSeedId = nil
			activeCosmeticId = nil
		end)
	end

	local function watchBackpack()
		for _, item in ipairs(player.Backpack:GetChildren()) do bindTool(item) end
	end

	local function watchCharacter(character)
		if not character then return end
		for _, item in ipairs(character:GetChildren()) do bindTool(item) end
		RuntimeGuard.Connect(character.ChildAdded, "FeedPlacement.CharacterChildAdded", bindTool)
	end

	RuntimeGuard.Connect(player.Backpack.ChildAdded, "FeedPlacement.BackpackChildAdded", bindTool)
	RuntimeGuard.Connect(player.CharacterAdded, "FeedPlacement.CharacterAdded", function(character)
		destroyPreview()
		watchBackpack()
		watchCharacter(character)
	end)

	watchBackpack()
	watchCharacter(player.Character)
end

return FeedPlacement
