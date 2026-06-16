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
local PlacementEditAnchor = require(script.Parent:WaitForChild("PlacementEditAnchor"))
local PlacementGrid = require(script.Parent:WaitForChild("PlacementGrid"))
local PlacementInput = require(script.Parent:WaitForChild("PlacementInput"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local FeedEditController = {}

local EDIT_MODE_ATTR = "EditMode"
local HUD_NAME = "HUD"
local EDIT_BUTTON_NAME = "EditModeButton"
local EXIT_EDIT_BUTTON_NAME = "ExitEditMode"
local TOPBAR_EDIT_ICON_NAME = "EditMode"
local TOPBAR_EDIT_ICON_IMAGE = "rbxassetid://116968621046326"
local EDIT_MODE_ICON_PENDING_SECONDS = 1.5
local PLACEMENT_EDIT_NAME = "PlacementEdit"
local FOOTPRINT_BOUNDS_EPSILON = 0.001
local FLOOR_Y_TOLERANCE_BELOW = 5
local FLOOR_Y_TOLERANCE_ABOVE = 14
local SELECTION_ALLOWED_COLOR = Color3.fromRGB(0, 228, 10)
local SELECTION_BLOCKED_COLOR = Color3.fromRGB(255, 65, 65)
-- World-space gap above the placeable primary-part bottom.
local PLACEMENT_EDIT_OFFSET = Vector3.new(0, 5, 0)
local PLACEMENT_EDIT_DRAG_TRANSPARENCY = 0.6
local DRAG_CELL_DEADZONE = 0.2
local DRAG_AXIS_MIN_PIXELS = 0.5
local DRAG_AXIS_CONDITION_MIN = 0.18
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

local function requireTopbarIcon()
	local satchelRoot = ReplicatedStorage:WaitForChild("Satchel", 10)
	if not satchelRoot then
		warn("[FeedEditController] Missing ReplicatedStorage.Satchel; edit toolbar icon will not start")
		return nil
	end

	local loader = satchelRoot:WaitForChild("SatchelLoader", 10)
	local satchelModule = loader and loader:WaitForChild("Satchel", 10)
	local packages = satchelModule and satchelModule:WaitForChild("Packages", 10)
	local topbarPlus = packages and packages:WaitForChild("topbarplus", 10)
	if not topbarPlus then
		warn("[FeedEditController] Missing Satchel TopbarPlus module; edit toolbar icon will not start")
		return nil
	end

	return require(topbarPlus)
end

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

local function floorLocalBoundsFromBox(floor, boundsCF, boundsSize)
	local halfBounds = Vector3.new(boundsSize.X / 2, boundsSize.Y / 2, boundsSize.Z / 2)
	local minX = math.huge
	local maxX = -math.huge
	local minZ = math.huge
	local maxZ = -math.huge

	for _, sx in ipairs(BOX_CORNER_SIGNS) do
		for _, sy in ipairs(BOX_CORNER_SIGNS) do
			for _, sz in ipairs(BOX_CORNER_SIGNS) do
				local worldCorner = boundsCF:PointToWorldSpace(Vector3.new(
					sx * halfBounds.X,
					sy * halfBounds.Y,
					sz * halfBounds.Z
				))
				local floorCorner = floor.CFrame:PointToObjectSpace(worldCorner)
				minX = math.min(minX, floorCorner.X)
				maxX = math.max(maxX, floorCorner.X)
				minZ = math.min(minZ, floorCorner.Z)
				maxZ = math.max(maxZ, floorCorner.Z)
			end
		end
	end

	if minX == math.huge then return nil end
	return minX, maxX, minZ, maxZ
end

local function boundsOverlapOnFloor(floor, aCF, aSize, bCF, bSize)
	if not aCF or not aSize or not bCF or not bSize then
		return true
	end

	local aMinX, aMaxX, aMinZ, aMaxZ = floorLocalBoundsFromBox(floor, aCF, aSize)
	local bMinX, bMaxX, bMinZ, bMaxZ = floorLocalBoundsFromBox(floor, bCF, bSize)
	if not aMinX or not bMinX then
		return true
	end

	return aMinX < bMaxX
		and aMaxX > bMinX
		and aMinZ < bMaxZ
		and aMaxZ > bMinZ
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

	local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
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

local function pointInsideUnlockedGrid(plot, worldPoint, gridParts)
	local parts = gridParts or unlockedGridParts(plot)
	for _, part in ipairs(parts) do
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

local function boundsFitOnUnlockedGrid(plot, boundsCF, boundsSize, gridParts)
	if not plot then return false end
	local halfBounds = Vector3.new(boundsSize.X / 2, 0, boundsSize.Z / 2)
	local parts = gridParts or unlockedGridParts(plot)
	if not pointInsideUnlockedGrid(plot, boundsCF.Position, parts) then
		return false
	end
	for _, sx in ipairs(BOX_CORNER_SIGNS) do
		for _, sz in ipairs(BOX_CORNER_SIGNS) do
			local worldCorner = boundsCF:PointToWorldSpace(Vector3.new(
				sx * halfBounds.X,
				0,
				sz * halfBounds.Z
			))
			if not pointInsideUnlockedGrid(plot, worldCorner, parts) then
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
	if instance:IsA("Model") and instance.PrimaryPart then
		return instance.PrimaryPart.Size.Y / 2
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

	local oldEditButton = hud:FindFirstChild(EDIT_BUTTON_NAME, true)
	if oldEditButton and oldEditButton:IsA("GuiButton") then
		oldEditButton.Visible = false
		oldEditButton.Active = false
	end
	local exitEditButton = hud:FindFirstChild(EXIT_EDIT_BUTTON_NAME, true)
	if not (exitEditButton and exitEditButton:IsA("GuiButton")) then
		warn("[FeedEditController] HUD missing ExitEditMode GuiButton")
		return
	end

	local Icon = requireTopbarIcon()
	if not Icon then
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
	local selectedAnchor = nil
	local selectedPivotOffset = 0
	local selectedPrimaryOffset = CFrame.new()
	local selectedLX = 0
	local selectedLZ = 0
	local selectedLRY = 0
	local committedCFrame = nil
	local currentBlocked = false
	local moving = false
	local dragState = nil
	local selectionTap = PlacementInput.NewTapRecognizer()
	local nextRequestId = 0
	local pendingRequestId = nil
	local pendingTargetCFrame = nil
	local pendingOriginalCFrame = nil
	local ignoreWorldInputUntil = 0
	local lastForcedOffRequest = 0
	local exitEditButtonOpen = false
	local exitEditButtonTransitionToken = 0
	local syncingEditModeIcon = false
	local pendingDesiredEditMode = nil
	local pendingDesiredEditModeExpiresAt = 0
	local rotationTween = nil
	local rotationTweenValue = nil
	local rotationTweenConnection = nil
	local rotationTweenToken = 0

	local editModeIcon = Icon.new()
		:setName(TOPBAR_EDIT_ICON_NAME)
		:setImage(TOPBAR_EDIT_ICON_IMAGE)
		:setImageScale(0.58)
		:setCaption("Edit mode")
		:setOrder(0)
		:autoDeselect(false)
	editModeIcon:modifyTheme({
		{ "IconButton", "BackgroundColor3", Color3.fromRGB(0, 0, 0) },
		{ "IconButton", "BackgroundTransparency", 0.2 },
		{ "IconCorners", "CornerRadius", UDim.new(1, 0) },
		{ "IconImage", "ImageColor3", Color3.fromRGB(255, 255, 255), "Deselected" },
		{ "IconImage", "ImageColor3", Color3.fromRGB(255, 65, 65), "Selected" },
		{ "IconSpot", "BackgroundTransparency", 1, "Selected" },
		{ "IconSpotGradient", "Enabled", false, "Selected" },
	})
	editModeIcon:setEnabled(false)

	local placementEdit = placementEditTemplate:Clone()
	UiEffects.BindBillboardPop(placementEdit)
	placementEdit.Enabled = false
	-- Wrapped so the whole panel fades as one layer while dragging.
	local placementEditCanvas = UiEffects.WrapInCanvasGroup(placementEdit)
	placementEdit.StudsOffset = Vector3.zero
	placementEdit.StudsOffsetWorldSpace = PLACEMENT_EDIT_OFFSET
	placementEdit.Parent = playerGui

	local options = placementEditCanvas:FindFirstChild("options")
	local confirmButton = options and options:FindFirstChild("confirm")
	local moveButton = options and options:FindFirstChild("move")
	local rotateButton = options and options:FindFirstChild("rotate")
	local tipLabel = placementEditCanvas:FindFirstChild("tip")
	if not (moveButton and moveButton:IsA("GuiButton") and rotateButton and rotateButton:IsA("GuiButton")) then
		warn("[FeedEditController] PlacementEdit missing move/rotate GuiButtons")
		placementEdit:Destroy()
		return
	end
	local silentUiEffects = { silent = true }
	UiEffects.BindButton(exitEditButton, silentUiEffects)
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
		local showcase = PlayerStateStore.Get(PlayerStateStore.Fields.JoinBackShowcase)
		if type(showcase) == "table" then
			return true
		end
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

	local function selectedTargetCFrameAt(lx, lz, floor)
		floor = floor or getPlayerFloor()
		if not floor then return nil end
		return floor.CFrame
			* CFrame.new(lx, floor.Size.Y / 2 + selectedPivotOffset, lz)
			* CFrame.Angles(0, selectedLRY, 0)
	end

	local function selectedTargetCFrame(floor)
		return selectedTargetCFrameAt(selectedLX, selectedLZ, floor)
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

	local function selectedPlacementBlocked(cframe, floor, plot, gridParts)
		floor = floor or getPlayerFloor()
		plot = plot or getPlayerPlot()
		if not floor or not plot then return true end
		local boundsCF, boundsSize = selectedBoundsAt(cframe)
		if not boundsCF or not boundsSize then return true end
		if not boundsFitOnFloor(floor, boundsCF, boundsSize)
			or not boundsFitOnUnlockedGrid(plot, boundsCF, boundsSize, gridParts) then
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
				local placeableBoundsCF, placeableBoundsSize = placeableBounds(placeable)
				if boundsOverlapOnFloor(floor, boundsCF, querySize, placeableBoundsCF, placeableBoundsSize) then
					return true
				end
			end
		end
		return false
	end

	local function setSelectionBlocked(blocked)
		if currentBlocked == blocked then
			return
		end
		currentBlocked = blocked
		selectionBox.Color3 = blocked and SELECTION_BLOCKED_COLOR or SELECTION_ALLOWED_COLOR
	end

	local function applySelectionPreview(cframe, floor, plot, gridParts)
		if not selectedFeed then return end
		cframe = cframe or selectedTargetCFrame(floor)
		if not cframe then return end
		cancelRotationTween()
		setObjectCFrame(selectedFeed, cframe)
		setSelectionBlocked(selectedPlacementBlocked(cframe, floor, plot, gridParts))
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
		dragState = nil
		if restore and selectedFeed and committedCFrame then
			setObjectCFrame(selectedFeed, committedCFrame)
		end
		selectedFeed = nil
		selectedPrimary = nil
		committedCFrame = nil
		selectionTap:Cancel()
		placementEdit.Enabled = false
		placementEdit.Adornee = nil
		if selectedAnchor then
			selectedAnchor:Destroy()
			selectedAnchor = nil
		end
		UiEffects.SetGroupTransparency(placementEditCanvas, 0, true)
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
		SoundEffects.PlayVaried(SoundEffects.Names.FruitPop)
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

		selectedAnchor = PlacementEditAnchor.Attach(feed)
		placementEdit.Adornee = selectedAnchor or primary
		placementEdit.Enabled = true
		selectionBox.Adornee = primary
		selectionBox.Parent = primary
		if tipLabel and tipLabel:IsA("TextLabel") then
			tipLabel.Text = "Hold to move"
		end
		applySelectionPreview()
	end

	local function floorLocalPointFromScreen(screenPosition, floor)
		floor = floor or getPlayerFloor()
		local camera = Workspace.CurrentCamera
		if not floor or not camera then return nil end

		local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
		local planePoint = floor.CFrame:PointToWorldSpace(Vector3.new(0, floor.Size.Y / 2, 0))
		local planeNormal = floor.CFrame.UpVector
		local denominator = ray.Direction:Dot(planeNormal)
		if math.abs(denominator) < 0.0001 then return nil end

		local distance = (planePoint - ray.Origin):Dot(planeNormal) / denominator
		if distance < 0 then return nil end
		return floor.CFrame:PointToObjectSpace(ray.Origin + ray.Direction * distance)
	end

	local function floorPointFromScreen(screenPosition, floor)
		floor = floor or getPlayerFloor()
		if not floor then return nil end
		local localTarget = floorLocalPointFromScreen(screenPosition, floor)
		if not localTarget then return nil end
		local halfX = floor.Size.X / 2
		local halfZ = floor.Size.Z / 2
		local lx = math.clamp(math.round(localTarget.X), -halfX, halfX)
		local lz = math.clamp(math.round(localTarget.Z), -halfZ, halfZ)
		return lx, lz
	end

	local function snappedDragDelta(value)
		if math.abs(value) < DRAG_CELL_DEADZONE then
			return 0
		end
		return math.round(value)
	end

	local function screenPointForFloorLocal(camera, floor, lx, localY, lz)
		local worldPoint = floor.CFrame:PointToWorldSpace(Vector3.new(lx, localY, lz))
		local screenPoint = camera:WorldToScreenPoint(worldPoint)
		if screenPoint.Z <= 0 then
			return nil
		end
		return Vector2.new(screenPoint.X, screenPoint.Y)
	end

	local function beginScreenDrag(screenPosition, floor, startLX, startLZ)
		local camera = Workspace.CurrentCamera
		if not camera or not floor or not screenPosition then
			return nil
		end
		local localY = floor.Size.Y / 2 + selectedPivotOffset
		local origin = screenPointForFloorLocal(camera, floor, startLX, localY, startLZ)
		local xPoint = screenPointForFloorLocal(camera, floor, startLX + 1, localY, startLZ)
		local zPoint = screenPointForFloorLocal(camera, floor, startLX, localY, startLZ + 1)
		if not origin or not xPoint or not zPoint then
			return nil
		end
		local xAxis = xPoint - origin
		local zAxis = zPoint - origin
		if xAxis.Magnitude < DRAG_AXIS_MIN_PIXELS or zAxis.Magnitude < DRAG_AXIS_MIN_PIXELS then
			return nil
		end
		local determinant = xAxis.X * zAxis.Y - xAxis.Y * zAxis.X
		local condition = math.abs(determinant) / (xAxis.Magnitude * zAxis.Magnitude)
		return {
			startScreen = screenPosition,
			startLX = startLX,
			startLZ = startLZ,
			xAxis = xAxis,
			zAxis = zAxis,
			determinant = determinant,
			useAxisProjection = condition < DRAG_AXIS_CONDITION_MIN,
			pendingFirstMove = true,
		}
	end

	local function dragTargetFromScreen(state, screenPosition)
		if not state or not screenPosition then
			return nil
		end
		if state.pendingFirstMove then
			state.pendingFirstMove = false
			state.startScreen = screenPosition
			return state.startLX, state.startLZ, state.startLX, state.startLZ
		end
		local delta = screenPosition - state.startScreen
		local xCells
		local zCells
		if state.useAxisProjection then
			xCells = delta:Dot(state.xAxis) / state.xAxis:Dot(state.xAxis)
			zCells = delta:Dot(state.zAxis) / state.zAxis:Dot(state.zAxis)
		else
			xCells = (delta.X * state.zAxis.Y - delta.Y * state.zAxis.X) / state.determinant
			zCells = (state.xAxis.X * delta.Y - state.xAxis.Y * delta.X) / state.determinant
		end
		local rawLX = state.startLX + xCells
		local rawLZ = state.startLZ + zCells
		return state.startLX + snappedDragDelta(xCells), state.startLZ + snappedDragDelta(zCells), rawLX, rawLZ
	end

	local function selectedFitsOnGridAt(lx, lz, floor, plot, gridParts)
		floor = floor or getPlayerFloor()
		plot = plot or getPlayerPlot()
		if not floor or not plot then return false end
		local cframe = selectedTargetCFrameAt(lx, lz, floor)
		local boundsCF, boundsSize = selectedBoundsAt(cframe)
		if not boundsCF or not boundsSize then return false end
		return boundsFitOnFloor(floor, boundsCF, boundsSize)
			and boundsFitOnUnlockedGrid(plot, boundsCF, boundsSize, gridParts)
	end

	local function nearestSelectedLocalPoint(localTarget, floor, plot, gridParts)
		floor = floor or getPlayerFloor()
		plot = plot or getPlayerPlot()
		if not floor or not plot then return nil, nil end
		local parts = gridParts or unlockedGridParts(plot)
		if #parts == 0 then return nil, nil end

		local halfFloorX = floor.Size.X / 2
		local halfFloorZ = floor.Size.Z / 2
		local targetWorld = floor.CFrame:PointToWorldSpace(Vector3.new(localTarget.X, floor.Size.Y / 2, localTarget.Z))
		local bestFitLX, bestFitLZ, bestFitDistanceSq = nil, nil, math.huge
		local bestAnyLX, bestAnyLZ, bestAnyDistanceSq = nil, nil, math.huge
		local searchRadius = 1
		if selectedPrimary then
			searchRadius = math.max(searchRadius, math.ceil(math.max(selectedPrimary.Size.X, selectedPrimary.Size.Z) / 2) + 1)
		end

		local checkedCells = {}
		local function consider(lx, lz)
			local checkedColumn = checkedCells[lx]
			if checkedColumn and checkedColumn[lz] then return end
			if not checkedColumn then
				checkedColumn = {}
				checkedCells[lx] = checkedColumn
			end
			checkedColumn[lz] = true

			local candidateWorld = floor.CFrame:PointToWorldSpace(Vector3.new(lx, floor.Size.Y / 2, lz))
			if not pointInsideUnlockedGrid(plot, candidateWorld, parts) then return end

			local dx = lx - localTarget.X
			local dz = lz - localTarget.Z
			local distanceSq = dx * dx + dz * dz
			if distanceSq < bestAnyDistanceSq then
				bestAnyLX, bestAnyLZ, bestAnyDistanceSq = lx, lz, distanceSq
			end
			if selectedFitsOnGridAt(lx, lz, floor, plot, parts) and distanceSq < bestFitDistanceSq then
				bestFitLX, bestFitLZ, bestFitDistanceSq = lx, lz, distanceSq
			end
		end

		for _, gridPart in ipairs(parts) do
			local gridLocal = gridPart.CFrame:PointToObjectSpace(targetWorld)
			local clampedWorld = gridPart.CFrame:PointToWorldSpace(Vector3.new(
				math.clamp(gridLocal.X, -gridPart.Size.X / 2, gridPart.Size.X / 2),
				gridLocal.Y,
				math.clamp(gridLocal.Z, -gridPart.Size.Z / 2, gridPart.Size.Z / 2)
			))
			local floorLocal = floor.CFrame:PointToObjectSpace(clampedWorld)
			local baseLX = math.clamp(math.round(floorLocal.X), -halfFloorX, halfFloorX)
			local baseLZ = math.clamp(math.round(floorLocal.Z), -halfFloorZ, halfFloorZ)
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
		local floor = getPlayerFloor()
		local plot = getPlayerPlot()
		if not floor or not plot then return end
		local lx, lz
		local gridParts = unlockedGridParts(plot)
		if #gridParts == 0 then return end
		if dragState then
			local directLX, directLZ, rawLX, rawLZ = dragTargetFromScreen(dragState, screenPosition)
			if directLX == nil or directLZ == nil then return end
			local directWorld = floor.CFrame:PointToWorldSpace(Vector3.new(directLX, floor.Size.Y / 2, directLZ))
			local directInsideUnlockedGrid = pointInsideUnlockedGrid(plot, directWorld, gridParts)
			if directInsideUnlockedGrid and selectedFitsOnGridAt(directLX, directLZ, floor, plot, gridParts) then
				lx, lz = directLX, directLZ
			else
				lx, lz = nearestSelectedLocalPoint(Vector3.new(rawLX, floor.Size.Y / 2, rawLZ), floor, plot, gridParts)
			end
		else
			lx, lz = floorPointFromScreen(screenPosition, floor)
		end
		if not lx or not lz then return end
		if selectedLX == lx and selectedLZ == lz then return end
		local worldPoint = floor.CFrame:PointToWorldSpace(Vector3.new(lx, floor.Size.Y / 2, lz))
		if not pointInsideUnlockedGrid(plot, worldPoint, gridParts) then return end
		selectedLX = lx
		selectedLZ = lz
		local cframe = selectedTargetCFrame(floor)
		applySelectionPreview(cframe, floor, plot, gridParts)
	end

	local function beginMoving(screenPosition)
		if not selectedFeed or pendingRequestId ~= nil then return end
		moving = true
		dragState = beginScreenDrag(screenPosition, getPlayerFloor(), selectedLX, selectedLZ)
		selectionTap:Cancel()
		if tipLabel and tipLabel:IsA("TextLabel") then
			tipLabel.Text = "Release to move"
		end
		UiEffects.SetGroupTransparency(placementEditCanvas, PLACEMENT_EDIT_DRAG_TRANSPARENCY)
	end

	local function stopMoving()
		if not moving then return end
		moving = false
		dragState = nil
		if tipLabel and tipLabel:IsA("TextLabel") then
			tipLabel.Text = currentBlocked and "Blocked" or "Hold to move"
		end
		UiEffects.SetGroupTransparency(placementEditCanvas, 0)
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
		setSelectionBlocked(selectedPlacementBlocked(cframe))
		sendMoveRequest()
	end

	local function setPendingDesiredEditMode(enabled)
		pendingDesiredEditMode = enabled
		if enabled == nil then
			pendingDesiredEditModeExpiresAt = 0
		else
			pendingDesiredEditModeExpiresAt = os.clock() + EDIT_MODE_ICON_PENDING_SECONDS
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
			UiEffects.PlayOpen(exitEditButton, exitEditButtonPanelState, silentUiEffects)
		else
			UiEffects.PlayClose(exitEditButton, exitEditButtonPanelState, function()
				if exitEditButtonTransitionToken ~= token and exitEditButtonOpen then
					exitEditButton.Visible = true
				end
			end, silentUiEffects)
		end
	end

	local function desiredEditModeIconSelected()
		if not buttonVisible then
			return false
		end
		if pendingDesiredEditMode ~= nil then
			if pendingDesiredEditMode == editEnabled or os.clock() >= pendingDesiredEditModeExpiresAt then
				setPendingDesiredEditMode(nil)
			else
				return pendingDesiredEditMode
			end
		end
		return editEnabled
	end

	local function setEditModeIconSelected(selected)
		if editModeIcon.isSelected == selected then
			return
		end
		syncingEditModeIcon = true
		if selected then
			editModeIcon:select("Controller", editModeIcon)
		else
			editModeIcon:deselect("Controller", editModeIcon)
		end
		syncingEditModeIcon = false
	end

	local function refreshEditButtonVisibility()
		if editModeIcon.enabled ~= buttonVisible then
			editModeIcon:setEnabled(buttonVisible)
		end
		setEditModeIconSelected(desiredEditModeIconSelected())
		setExitEditButtonOpen(buttonVisible and editEnabled)
	end

	local function refreshButtonVisibility()
		local floor = getPlayerFloor()
		local visible = floor ~= nil and isOnFloor(floor) and not isOfflineProgressPending()
		buttonVisible = visible
		refreshEditButtonVisibility()
		if not visible then
			setPendingDesiredEditMode(nil)
			setEditModeIconSelected(false)
		end
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
		if pendingDesiredEditMode == editEnabled then
			setPendingDesiredEditMode(nil)
		end
		refreshEditButtonVisibility()
		setGridEnabled(editEnabled)
		if not editEnabled then
			clearSelection(true)
		end
	end

	RuntimeGuard.Connect(editModeIcon.toggled, "FeedEditController.EditModeIconToggled", function(selected, fromSource)
		if syncingEditModeIcon or fromSource ~= "User" then return end
		if isOfflineProgressPending() or not buttonVisible then
			setPendingDesiredEditMode(nil)
			refreshEditButtonVisibility()
			return
		end

		if selected then
			if editEnabled or pendingDesiredEditMode == true then return end
			setPendingDesiredEditMode(true)
			refreshEditButtonVisibility()
			FeedEditModeRequest:FireServer(true)
		else
			if not editEnabled and pendingDesiredEditMode ~= true then
				setPendingDesiredEditMode(nil)
				refreshEditButtonVisibility()
				return
			end
			setPendingDesiredEditMode(false)
			refreshEditButtonVisibility()
			FeedEditModeRequest:FireServer(false)
		end
	end)
	RuntimeGuard.Connect(exitEditButton.Activated, "FeedEditController.ExitEditButtonActivated", function()
		if not buttonVisible or not editEnabled then return end
		setPendingDesiredEditMode(false)
		refreshEditButtonVisibility()
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
		onStart = function(screenPosition)
			ignoreWorldInputUntil = os.clock() + 0.2
			beginMoving(screenPosition)
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
	PlayerStateStore.Observe(PlayerStateStore.Fields.JoinBackShowcase, function()
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
		while exitEditButton.Parent do
			RuntimeGuard.Run("FeedEditController.RefreshButtonVisibility", refreshButtonVisibility)
			task.wait(0.1)
		end
	end)

	refreshButtonVisibility()
	refreshEditState()
end

return FeedEditController
