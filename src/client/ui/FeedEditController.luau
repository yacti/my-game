local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local NotificationUi = require(script.Parent:WaitForChild("Notifications"))
local PlacementGrid = require(script.Parent:WaitForChild("PlacementGrid"))
local PlacementInput = require(script.Parent:WaitForChild("PlacementInput"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local FeedEditController = {}

local EDIT_MODE_ATTR = "EditMode"
local HUD_NAME = "HUD"
local EDIT_BUTTON_NAME = "EditModeButton"
local EXIT_EDIT_BUTTON_NAME = "ExitEditMode"
local PLACEMENT_EDIT_NAME = "PlacementEdit"
local FOOTPRINT_BOUNDS_EPSILON = 0.001
local FLOOR_Y_TOLERANCE_BELOW = 5
local FLOOR_Y_TOLERANCE_ABOVE = 14
local SELECTION_ALLOWED_COLOR = Color3.fromRGB(0, 228, 10)
local SELECTION_BLOCKED_COLOR = Color3.fromRGB(255, 65, 65)
local PLACEMENT_EDIT_FLOOR_OFFSET = 3
local OVERLAP_QUERY_INSET = 0.05
local SELECTION_RAY_DISTANCE = 1000
local BOX_CORNER_SIGNS = { -1, 1 }
local EDIT_SELECTION_HITBOX_NAME = "EditSelectionHitbox"
local ROTATION_TWEEN_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local placeableIndex = nil

local MOVE_FAILURE_MESSAGES = {
	["busy"] = "Please wait before moving another machine.",
	["invalid-target"] = "That machine cannot be moved.",
	["not-editing"] = "Enable edit mode before moving machines.",
	["out-of-bounds"] = "Keep machines inside unlocked plot cells.",
	["overlap"] = "That spot is already occupied.",
	["rate-limited"] = "Please wait before moving again.",
	["save-failed"] = "Could not save that move. Please try again.",
	["too-far"] = "Move closer to place that machine there.",
}

local GROWING_PLANT_MESSAGE = "You can't move growing plants!"

local function moveFailureMessage(reason)
	return MOVE_FAILURE_MESSAGES[reason] or "Could not move that machine."
end

local function firstBasePart(instance)
	if instance:IsA("BasePart") then return instance end
	if instance:IsA("Model") then
		local hitbox = instance:FindFirstChild(EDIT_SELECTION_HITBOX_NAME)
		if hitbox and hitbox:IsA("BasePart") then
			return hitbox
		end
		return instance.PrimaryPart
	end
	return nil
end

local function isMatureFeed(instance)
	return instance ~= nil
		and (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(instance:GetAttribute(State.Feed.Type)) == "string"
		and instance:GetAttribute(State.Feed.Type) ~= ""
		and instance:GetAttribute(State.Feed.Index) ~= nil
		and instance:GetAttribute(State.Seed.Phase) ~= "GrowingSeed"
end

local function isGrowingFeed(instance)
	return instance ~= nil
		and (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(instance:GetAttribute(State.Feed.Type)) == "string"
		and instance:GetAttribute(State.Feed.Type) ~= ""
		and instance:GetAttribute(State.Feed.Index) ~= nil
		and instance:GetAttribute(State.Seed.Phase) == "GrowingSeed"
end

local function isCosmetic(instance)
	return instance ~= nil
		and (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(instance:GetAttribute(State.Cosmetic.Id)) == "string"
		and instance:GetAttribute(State.Cosmetic.Id) ~= ""
		and instance:GetAttribute(State.Cosmetic.Index) ~= nil
end

local function placeableRootFromInstance(plot, instance)
	local current = instance
	while current and current ~= plot do
		if isMatureFeed(current) or isCosmetic(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function growingFeedRootFromInstance(plot, instance)
	local current = instance
	while current and current ~= plot do
		if isGrowingFeed(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function hasPlaceableRootAncestor(plot, instance)
	local current = instance.Parent
	while current and current ~= plot do
		if isMatureFeed(current) or isGrowingFeed(current) or isCosmetic(current) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function disconnectPlaceableIndex()
	if not placeableIndex then return end
	for _, conn in ipairs(placeableIndex.conns) do
		conn:Disconnect()
	end
	placeableIndex = nil
end

local function removePlaceableRoot(index, instance)
	if not index.rootSet[instance] then return end
	index.rootSet[instance] = nil
	for i = #index.roots, 1, -1 do
		if index.roots[i] == instance then
			table.remove(index.roots, i)
		end
	end
end

local function addPlaceableCandidate(index, instance)
	local plot = index.plot
	if not (plot and instance and instance:IsDescendantOf(plot)) then return end
	if instance:GetAttribute(State.TreeClicker.LocalVisual) == true then return end
	if (isMatureFeed(instance) or isGrowingFeed(instance) or isCosmetic(instance))
		and not hasPlaceableRootAncestor(plot, instance) then
		if not index.rootSet[instance] then
			index.rootSet[instance] = true
			index.roots[#index.roots + 1] = instance
		end
	end
end

local function ensurePlaceableIndex(plot)
	if not plot then
		disconnectPlaceableIndex()
		return nil
	end
	if placeableIndex and placeableIndex.plot == plot then
		return placeableIndex
	end

	disconnectPlaceableIndex()
	local index = {
		plot = plot,
		roots = {},
		rootSet = {},
		conns = {},
	}
	placeableIndex = index
	for _, descendant in ipairs(plot:GetDescendants()) do
		addPlaceableCandidate(index, descendant)
	end
	index.conns[#index.conns + 1] = RuntimeGuard.Connect(plot.DescendantAdded, "FeedEditController.PlaceableDescendantAdded", function(descendant)
		addPlaceableCandidate(index, descendant)
	end)
	index.conns[#index.conns + 1] = RuntimeGuard.Connect(plot.DescendantRemoving, "FeedEditController.PlaceableDescendantRemoving", function(descendant)
		removePlaceableRoot(index, descendant)
	end)
	return index
end

local function placeableRoots(plot)
	local roots = {}
	local index = ensurePlaceableIndex(plot)
	if not index then return roots end

	for _, root in ipairs(index.roots) do
		if root.Parent and root:IsDescendantOf(plot) then
			roots[#roots + 1] = root
		end
	end

	return roots
end

local function placeableHitboxRootFromPart(plot, part)
	local current = part
	while current and current ~= plot do
		local feedType = current:GetAttribute(State.Feed.Type)
		if type(feedType) == "string" and feedType ~= "" and current:GetAttribute(State.Feed.Index) then
			if current:GetAttribute(State.Seed.Phase) == "GrowingSeed" then return nil end
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

local function placeableBounds(instance)
	if instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end
	if instance:IsA("Model") then
		local boundsPart = firstBasePart(instance)
		if boundsPart then
			return boundsPart.CFrame, boundsPart.Size
		end
	end
	return nil, nil
end

local function rayBoxDistance(ray, boundsCF, boundsSize)
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
				return nil
			end
		else
			local t1 = (-axisHalf - axisOrigin) / axisDirection
			local t2 = (axisHalf - axisOrigin) / axisDirection
			tMin = math.max(tMin, math.min(t1, t2))
			tMax = math.min(tMax, math.max(t1, t2))
			if tMin > tMax then
				return nil
			end
		end
	end

	if tMax < 0 then return nil end
	return math.max(tMin, 0)
end

local function placeableRootFromScreen(plot, screenPosition)
	local camera = Workspace.CurrentCamera
	if not plot or not camera then return nil end

	local roots = placeableRoots(plot)
	if #roots == 0 then return nil end

	local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = roots

	local hit = Workspace:Raycast(ray.Origin, ray.Direction * SELECTION_RAY_DISTANCE, params)
	if hit then
		return placeableRootFromInstance(plot, hit.Instance) or growingFeedRootFromInstance(plot, hit.Instance)
	end

	local bestRoot = nil
	local bestDistance = math.huge
	for _, root in ipairs(roots) do
		local boundsCF, boundsSize = placeableBounds(root)
		local distance = boundsCF and boundsSize and rayBoxDistance(ray, boundsCF, boundsSize) or nil
		if distance and distance < bestDistance then
			bestRoot = root
			bestDistance = distance
		end
	end
	return bestRoot
end

local function plotGridParts(plot, unlockedOnly)
	local parts = {}
	if not plot then return parts end

	for _, folderName in ipairs({ PlotGrid.Folders.Starter, PlotGrid.Folders.Unlockable }) do
		local folder = plot:FindFirstChild(folderName)
		if folder then
			for _, child in ipairs(folder:GetChildren()) do
				if child:IsA("BasePart")
					and (not unlockedOnly or child:GetAttribute(State.Grid.Unlocked) == true) then
					parts[#parts + 1] = child
				end
			end
		end
	end
	return parts
end

local function unlockedGridParts(plot)
	return plotGridParts(plot, true)
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

local function pivotFloorOffset(instance)
	if instance:IsA("BasePart") then
		return instance.Size.Y / 2
	end

	local pivot = instance:GetPivot()
	local boundsCF, boundsSize = instance:GetBoundingBox()
	local halfBounds = Vector3.new(boundsSize.X / 2, boundsSize.Y / 2, boundsSize.Z / 2)
	local lowestLocalY = math.huge

	for _, sx in ipairs(BOX_CORNER_SIGNS) do
		for _, sy in ipairs(BOX_CORNER_SIGNS) do
			for _, sz in ipairs(BOX_CORNER_SIGNS) do
				local worldCorner = boundsCF:PointToWorldSpace(Vector3.new(
					sx * halfBounds.X,
					sy * halfBounds.Y,
					sz * halfBounds.Z
				))
				local pivotCorner = pivot:PointToObjectSpace(worldCorner)
				lowestLocalY = math.min(lowestLocalY, pivotCorner.Y)
			end
		end
	end

	if lowestLocalY == math.huge then return 0 end
	return math.max(-lowestLocalY, 0)
end

local function setObjectCFrame(instance, cframe)
	if instance:IsA("BasePart") then
		instance.CFrame = cframe
	elseif instance:IsA("Model") then
		instance:PivotTo(cframe)
	end
end

local function rootPosition()
	local player = Players.LocalPlayer
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function isOnFloor(floor)
	local position = rootPosition()
	if not position or not floor then return false end

	local localPosition = floor.CFrame:PointToObjectSpace(position)
	return math.abs(localPosition.X) <= floor.Size.X / 2
		and math.abs(localPosition.Z) <= floor.Size.Z / 2
		and localPosition.Y >= floor.Size.Y / 2 - FLOOR_Y_TOLERANCE_BELOW
		and localPosition.Y <= floor.Size.Y / 2 + FLOOR_Y_TOLERANCE_ABOVE
end

function FeedEditController.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild(HUD_NAME, 10)
	if not hud then
		warn("[FeedEditController] Missing HUD ScreenGui")
		return
	end

	local editButton = hud:FindFirstChild(EDIT_BUTTON_NAME, true)
	if not (editButton and editButton:IsA("GuiButton")) then
		warn("[FeedEditController] HUD missing EditModeButton GuiButton")
		return
	end
	local exitEditButton = hud:FindFirstChild(EXIT_EDIT_BUTTON_NAME, true)
	if not (exitEditButton and exitEditButton:IsA("GuiButton")) then
		warn("[FeedEditController] HUD missing ExitEditMode GuiButton")
		return
	end

	local placementEditTemplate = BillboardGuiTemplates.Find(PLACEMENT_EDIT_NAME)
	if not (placementEditTemplate and placementEditTemplate:IsA("BillboardGui")) then
		warn("[FeedEditController] Missing " .. BillboardGuiTemplates.Path(PLACEMENT_EDIT_NAME) .. " BillboardGui")
		return
	end

	local FeedEditModeRequest = Remotes.get(Remotes.Names.FeedEditModeRequest)
	local FeedMoveRequest = Remotes.get(Remotes.Names.FeedMoveRequest)
	local FeedMoveResult = Remotes.get(Remotes.Names.FeedMoveResult)

	local placementGrid = nil
	local editEnabled = player:GetAttribute(EDIT_MODE_ATTR) == true
	local buttonVisible = false
	local selectedFeed = nil
	local selectedPrimary = nil
	local selectedPivotOffset = 0
	local selectedPrimaryOffset = CFrame.new()
	local selectedLX = 0
	local selectedLZ = 0
	local selectedLRY = 0
	local committedCFrame = nil
	local currentBlocked = false
	local moving = false
	local selectionTap = PlacementInput.NewTapRecognizer()
	local nextRequestId = 0
	local pendingRequestId = nil
	local pendingTargetCFrame = nil
	local pendingOriginalCFrame = nil
	local ignoreWorldInputUntil = 0
	local lastForcedOffRequest = 0
	local editButtonOpen = false
	local exitEditButtonOpen = false
	local editButtonTransitionToken = 0
	local exitEditButtonTransitionToken = 0
	local rotationTween = nil
	local rotationTweenValue = nil
	local rotationTweenConnection = nil
	local rotationTweenToken = 0

	local placementEdit = placementEditTemplate:Clone()
	UiEffects.BindBillboardPop(placementEdit)
	placementEdit.Enabled = false
	placementEdit.Parent = playerGui

	local options = placementEdit:FindFirstChild("options")
	local confirmButton = options and options:FindFirstChild("confirm")
	local moveButton = options and options:FindFirstChild("move")
	local rotateButton = options and options:FindFirstChild("rotate")
	local tipLabel = placementEdit:FindFirstChild("tip")
	if not (moveButton and moveButton:IsA("GuiButton") and rotateButton and rotateButton:IsA("GuiButton")) then
		warn("[FeedEditController] PlacementEdit missing move/rotate GuiButtons")
		placementEdit:Destroy()
		return
	end
	UiEffects.BindButton(editButton)
	UiEffects.BindButton(exitEditButton)
	local editButtonPanelState = UiEffects.PreparePanel(editButton)
	local exitEditButtonPanelState = UiEffects.PreparePanel(exitEditButton)
	if confirmButton and confirmButton:IsA("GuiObject") then
		confirmButton.Visible = false
	end

	local selectionBox = Instance.new("SelectionBox")
	selectionBox.LineThickness = 0.035
	selectionBox.Color3 = SELECTION_ALLOWED_COLOR

	local function getPlayerPlot()
		return PlotResolver.ResolveForPlayer(player)
	end

	local function isOfflineProgressPending()
		return player:GetAttribute(State.Player.OfflineProgressPending) == true
	end

	local function getPlayerFloor()
		local plot = getPlayerPlot()
		local floor = plot and plot:FindFirstChild("Floor")
		return floor and floor:IsA("BasePart") and floor or nil
	end

	placementGrid = PlacementGrid.new(getPlayerFloor)

	local function setGridEnabled(enabled)
		if placementGrid then
			placementGrid:SetEnabled(enabled)
		end
	end

	local function selectedTargetCFrame()
		local floor = getPlayerFloor()
		if not floor then return nil end
		return floor.CFrame
			* CFrame.new(selectedLX, floor.Size.Y / 2 + selectedPivotOffset, selectedLZ)
			* CFrame.Angles(0, selectedLRY, 0)
	end

	local function updatePlacementEditOffset()
		local floor = getPlayerFloor()
		if not (floor and selectedPrimary and selectedFeed) then return end
		local worldPosition = floor.CFrame:PointToWorldSpace(Vector3.new(
			selectedLX,
			floor.Size.Y / 2 + PLACEMENT_EDIT_FLOOR_OFFSET,
			selectedLZ
		))
		placementEdit.StudsOffsetWorldSpace = worldPosition - selectedPrimary.Position
	end

	local function selectedBoundsAt(cframe)
		if not selectedFeed or not selectedPrimary then return nil, nil end
		if selectedFeed:IsA("BasePart") then
			return cframe, selectedFeed.Size
		end
		return cframe * selectedPrimaryOffset, selectedPrimary.Size
	end

	local function cancelRotationTween()
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

	local function tweenSelectedTo(cframe)
		if not selectedFeed then return end
		cancelRotationTween()

		rotationTweenToken += 1
		local token = rotationTweenToken
		local value = Instance.new("CFrameValue")
		value.Value = selectedFeed:GetPivot()
		rotationTweenValue = value
		rotationTweenConnection = RuntimeGuard.Connect(value:GetPropertyChangedSignal("Value"), "FeedEditController.RotateTweenStep", function()
			if selectedFeed then
				setObjectCFrame(selectedFeed, value.Value)
			end
		end)
		rotationTween = TweenService:Create(value, ROTATION_TWEEN_INFO, { Value = cframe })
		RuntimeGuard.Connect(rotationTween.Completed, "FeedEditController.RotateTweenCompleted", function()
			if rotationTweenToken ~= token then
				return
			end
			if selectedFeed then
				setObjectCFrame(selectedFeed, cframe)
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

	local function selectedPlacementBlocked(cframe)
		local floor = getPlayerFloor()
		local plot = getPlayerPlot()
		if not floor or not plot then return true end
		local boundsCF, boundsSize = selectedBoundsAt(cframe)
		if not boundsCF or not boundsSize then return true end
		if not boundsFitOnFloor(floor, boundsCF, boundsSize) or not boundsFitOnUnlockedGrid(plot, boundsCF, boundsSize) then
			return true
		end
		local querySize = Vector3.new(
			math.max(boundsSize.X - OVERLAP_QUERY_INSET, 0.05),
			boundsSize.Y,
			math.max(boundsSize.Z - OVERLAP_QUERY_INSET, 0.05)
		)

		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { plot }

		for _, part in ipairs(Workspace:GetPartBoundsInBox(boundsCF, querySize, params)) do
			local placeable = placeableHitboxRootFromPart(plot, part)
			if placeable and placeable ~= selectedFeed then
				return true
			end
		end
		return false
	end

	local function setSelectionBlocked(blocked)
		currentBlocked = blocked
		selectionBox.Color3 = blocked and SELECTION_BLOCKED_COLOR or SELECTION_ALLOWED_COLOR
	end

	local function applySelectionPreview()
		if not selectedFeed then return end
		local cframe = selectedTargetCFrame()
		if not cframe then return end
		cancelRotationTween()
		setObjectCFrame(selectedFeed, cframe)
		updatePlacementEditOffset()
		setSelectionBlocked(selectedPlacementBlocked(cframe))
	end

	local function clearPending()
		pendingRequestId = nil
		pendingTargetCFrame = nil
		pendingOriginalCFrame = nil
	end

	local function clearSelection(restore)
		if pendingRequestId ~= nil then return end
		cancelRotationTween()
		moving = false
		if restore and selectedFeed and committedCFrame then
			setObjectCFrame(selectedFeed, committedCFrame)
		end
		selectedFeed = nil
		selectedPrimary = nil
		committedCFrame = nil
		selectionTap:Cancel()
		placementEdit.Enabled = false
		placementEdit.Adornee = nil
		placementEdit.StudsOffsetWorldSpace = Vector3.zero
		selectionBox.Adornee = nil
		selectionBox.Parent = nil
	end

	local function sendMoveRequest()
		if not selectedFeed or pendingRequestId ~= nil then return end
		if isOfflineProgressPending() then return end
		local targetCFrame = selectedTargetCFrame()
		if not targetCFrame then return end

		nextRequestId += 1
		pendingRequestId = nextRequestId
		pendingTargetCFrame = targetCFrame
		pendingOriginalCFrame = committedCFrame
		FeedMoveRequest:FireServer(pendingRequestId, selectedFeed, targetCFrame)
	end

	local function selectFeed(feed)
		if pendingRequestId ~= nil then return end
		if selectedFeed == feed then return end
		clearSelection(true)

		local primary = firstBasePart(feed)
		local floor = getPlayerFloor()
		if not primary or not floor then return end

		selectedFeed = feed
		selectedPrimary = primary
		committedCFrame = feed:GetPivot()
		selectedPivotOffset = pivotFloorOffset(feed)
		selectedPrimaryOffset = feed:IsA("Model") and feed:GetPivot():ToObjectSpace(primary.CFrame) or CFrame.new()

		local localCF = floor.CFrame:ToObjectSpace(committedCFrame)
		selectedLX = math.round(localCF.X)
		selectedLZ = math.round(localCF.Z)
		local _, lry, _ = localCF:ToEulerAnglesXYZ()
		selectedLRY = math.round(lry / (math.pi / 2)) * (math.pi / 2)

		placementEdit.Adornee = primary
		placementEdit.Enabled = true
		selectionBox.Adornee = primary
		selectionBox.Parent = primary
		if tipLabel and tipLabel:IsA("TextLabel") then
			tipLabel.Text = "Hold to move"
		end
		applySelectionPreview()
	end

	local function floorPointFromScreen(screenPosition)
		local floor = getPlayerFloor()
		local plot = getPlayerPlot()
		local camera = Workspace.CurrentCamera
		if not floor or not plot or not camera then return nil end

		local gridParts = unlockedGridParts(plot)
		if #gridParts == 0 then return nil end

		local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = gridParts

		local hit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
		if not hit then return nil end

		local localTarget = floor.CFrame:PointToObjectSpace(hit.Position)
		local halfX = floor.Size.X / 2
		local halfZ = floor.Size.Z / 2
		if math.abs(localTarget.X) > halfX or math.abs(localTarget.Z) > halfZ then
			return nil
		end
		return math.round(localTarget.X), math.round(localTarget.Z)
	end

	local function updateDragPreview(screenPosition)
		if not moving or not selectedFeed or pendingRequestId ~= nil then return end
		if not editEnabled then
			clearSelection(true)
			return
		end
		if not selectedFeed.Parent or not selectedPrimary or not selectedPrimary.Parent then
			clearSelection(false)
			return
		end
		if not screenPosition then return end
		local lx, lz = floorPointFromScreen(screenPosition)
		if not lx or not lz then return end
		selectedLX = lx
		selectedLZ = lz
		applySelectionPreview()
	end

	local function beginMoving()
		if not selectedFeed or pendingRequestId ~= nil then return end
		moving = true
		selectionTap:Cancel()
		if tipLabel and tipLabel:IsA("TextLabel") then
			tipLabel.Text = "Release to move"
		end
	end

	local function stopMoving()
		if not moving then return end
		moving = false
		if tipLabel and tipLabel:IsA("TextLabel") then
			tipLabel.Text = currentBlocked and "Blocked" or "Hold to move"
		end
		if not selectedFeed or not selectedFeed.Parent or not selectedPrimary or not selectedPrimary.Parent then
			clearSelection(false)
			return
		end
		sendMoveRequest()
	end

	local function handleWorldEditTap(screenPosition)
		local plot = getPlayerPlot()
		if not plot then
			clearSelection(true)
			return
		end

		local placeable = placeableRootFromScreen(plot, screenPosition)
		if placeable then
			if isGrowingFeed(placeable) then
				NotificationUi.show({
					kind = NotificationConfig.Kinds.Error,
					text = GROWING_PLANT_MESSAGE,
				})
				clearSelection(true)
			else
				selectFeed(placeable)
			end
		else
			clearSelection(true)
		end
	end

	local function rotateSelected()
		if not selectedFeed or pendingRequestId ~= nil then return end
		selectedLRY = (selectedLRY + math.pi / 2) % (math.pi * 2)
		local cframe = selectedTargetCFrame()
		if not cframe then return end
		tweenSelectedTo(cframe)
		updatePlacementEditOffset()
		setSelectionBlocked(selectedPlacementBlocked(cframe))
		sendMoveRequest()
	end

	local function setEditButtonOpen(open)
		if editButtonOpen == open then
			return
		end
		editButtonOpen = open
		editButtonTransitionToken += 1
		local token = editButtonTransitionToken
		editButton.Active = open
		if open then
			UiEffects.PlayOpen(editButton, editButtonPanelState)
		else
			UiEffects.PlayClose(editButton, editButtonPanelState, function()
				if editButtonTransitionToken ~= token and editButtonOpen then
					editButton.Visible = true
				end
			end)
		end
	end

	local function setExitEditButtonOpen(open)
		if exitEditButtonOpen == open then
			return
		end
		exitEditButtonOpen = open
		exitEditButtonTransitionToken += 1
		local token = exitEditButtonTransitionToken
		exitEditButton.Active = open
		if open then
			UiEffects.PlayOpen(exitEditButton, exitEditButtonPanelState)
		else
			UiEffects.PlayClose(exitEditButton, exitEditButtonPanelState, function()
				if exitEditButtonTransitionToken ~= token and exitEditButtonOpen then
					exitEditButton.Visible = true
				end
			end)
		end
	end

	local function refreshEditButtonVisibility()
		setEditButtonOpen(buttonVisible and not editEnabled)
		setExitEditButtonOpen(buttonVisible and editEnabled)
	end

	local function refreshButtonVisibility()
		local floor = getPlayerFloor()
		local visible = floor ~= nil and isOnFloor(floor) and not isOfflineProgressPending()
		buttonVisible = visible
		refreshEditButtonVisibility()
		if not visible and editEnabled then
			setGridEnabled(false)
			clearSelection(true)
			if os.clock() - lastForcedOffRequest >= 0.2 then
				lastForcedOffRequest = os.clock()
				FeedEditModeRequest:FireServer(false)
			end
		end
	end

	local function refreshEditState()
		editEnabled = player:GetAttribute(EDIT_MODE_ATTR) == true
		refreshEditButtonVisibility()
		setGridEnabled(editEnabled)
		if not editEnabled then
			clearSelection(true)
		end
	end

	RuntimeGuard.Connect(editButton.Activated, "FeedEditController.EditButtonActivated", function()
		if isOfflineProgressPending() then return end
		if not buttonVisible or editEnabled then return end
		FeedEditModeRequest:FireServer(true)
	end)
	RuntimeGuard.Connect(exitEditButton.Activated, "FeedEditController.ExitEditButtonActivated", function()
		if not buttonVisible or not editEnabled then return end
		FeedEditModeRequest:FireServer(false)
	end)

	PlacementInput.BindMoveDrag(moveButton, "FeedEditController.MoveDrag", {
		canStart = function()
			return not isOfflineProgressPending()
				and editEnabled
				and selectedFeed ~= nil
				and selectedFeed.Parent ~= nil
				and pendingRequestId == nil
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
	RuntimeGuard.Connect(moveButton.InputBegan, "FeedEditController.MoveInputBegan", function(input)
		if PlacementInput.IsPressInput(input) then
			ignoreWorldInputUntil = os.clock() + 0.2
		end
	end)
	RuntimeGuard.Connect(rotateButton.InputBegan, "FeedEditController.RotateInputBegan", function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			ignoreWorldInputUntil = os.clock() + 0.2
		end
	end)
	RuntimeGuard.Connect(rotateButton.Activated, "FeedEditController.RotateActivated", rotateSelected)

	RuntimeGuard.Connect(UserInputService.InputBegan, "FeedEditController.InputBegan", function(input, gameProcessed)
		if isOfflineProgressPending() then return end
		if gameProcessed or not editEnabled or moving or pendingRequestId ~= nil then return end
		if os.clock() < ignoreWorldInputUntil then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if PlacementInput.IsInteractiveGuiAt(input.Position) then return end

		if input.UserInputType == Enum.UserInputType.Touch then
			selectionTap:Begin(input)
		else
			handleWorldEditTap(input.Position)
		end
	end)

	RuntimeGuard.Connect(UserInputService.InputChanged, "FeedEditController.InputChanged", function(input)
		selectionTap:Changed(input)
	end)

	RuntimeGuard.Connect(UserInputService.InputEnded, "FeedEditController.InputEnded", function(input)
		local tap = selectionTap:End(input)
		if not tap then
			return
		end
		if isOfflineProgressPending() or not editEnabled or moving or pendingRequestId ~= nil then return end
		if os.clock() < ignoreWorldInputUntil then return end
		handleWorldEditTap(tap.position)
	end)

	RuntimeGuard.Connect(FeedMoveResult.OnClientEvent, "FeedEditController.MoveResult", function(requestId, success, reason, snappedCFrame)
		if requestId ~= pendingRequestId then return end

		local targetCFrame = typeof(snappedCFrame) == "CFrame" and snappedCFrame or pendingTargetCFrame
		if success then
			if selectedFeed and targetCFrame then
				cancelRotationTween()
				setObjectCFrame(selectedFeed, targetCFrame)
				committedCFrame = targetCFrame
				applySelectionPreview()
			end
			clearPending()
			if not editEnabled then
				clearSelection(false)
			end
			return
		end

		if selectedFeed and pendingOriginalCFrame then
			cancelRotationTween()
			setObjectCFrame(selectedFeed, pendingOriginalCFrame)
			committedCFrame = pendingOriginalCFrame
			local floor = getPlayerFloor()
			if floor then
				local localCF = floor.CFrame:ToObjectSpace(committedCFrame)
				selectedLX = math.round(localCF.X)
				selectedLZ = math.round(localCF.Z)
				local _, lry, _ = localCF:ToEulerAnglesXYZ()
				selectedLRY = math.round(lry / (math.pi / 2)) * (math.pi / 2)
			end
			setSelectionBlocked(false)
		end
		clearPending()
		NotificationUi.show({
			kind = NotificationConfig.Kinds.Error,
			text = moveFailureMessage(reason),
		})
		if not editEnabled then
			clearSelection(false)
		end
	end)

	RuntimeGuard.Connect(player:GetAttributeChangedSignal(EDIT_MODE_ATTR), "FeedEditController.EditModeChanged", refreshEditState)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.OfflineProgressPending), "FeedEditController.OfflineProgressPendingChanged", function()
		if isOfflineProgressPending() then
			clearSelection(true)
			setGridEnabled(false)
			if editEnabled then
				FeedEditModeRequest:FireServer(false)
			end
		end
		refreshButtonVisibility()
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "FeedEditController.AssignedPlotChanged", function()
		disconnectPlaceableIndex()
		refreshButtonVisibility()
		refreshEditState()
	end)
	RuntimeGuard.Connect(player.CharacterAdded, "FeedEditController.CharacterAdded", function()
		clearSelection(true)
		task.defer(function()
			RuntimeGuard.Run("FeedEditController.RefreshButtonDeferred", refreshButtonVisibility)
		end)
	end)

	RuntimeGuard.Spawn("FeedEditController.RefreshLoop", function()
		while editButton.Parent do
			RuntimeGuard.Run("FeedEditController.RefreshButtonVisibility", refreshButtonVisibility)
			task.wait(0.1)
		end
	end)

	refreshButtonVisibility()
	refreshEditState()
end

return FeedEditController
