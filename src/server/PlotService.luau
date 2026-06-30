local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets       = require(ReplicatedStorage.Shared:WaitForChild("Assets"))
local Balance      = require(ReplicatedStorage.Shared:WaitForChild("Balance"))
local Cosmetics    = require(ReplicatedStorage.Shared:WaitForChild("Cosmetics"))
local PetCatalog   = require(ReplicatedStorage.Shared:WaitForChild("PetCatalog"))
local PetGeometry  = require(ReplicatedStorage.Shared:WaitForChild("PetGeometry"))
local PetNicknames = require(ReplicatedStorage.Shared:WaitForChild("PetNicknames"))
local State        = require(ReplicatedStorage.Shared:WaitForChild("State"))
local FeedMachines = require(script.Parent:WaitForChild("feedMachines"))
local PlotGridService = require(script.Parent:WaitForChild("PlotGridService"))
local InstanceVisibility = require(script.Parent:WaitForChild("InstanceVisibility"))

local PetModels = Assets.WaitFor(Assets.Names.PetModels)

local FOOTPRINT_BOUNDS_EPSILON = 0.001
local OVERLAP_QUERY_INSET = 0.05
local BOX_CORNER_SIGNS = { -1, 1 }
local PET_PATH_PADDING_SCALE = 0.75
local NAV_OBSTACLE_STATIC_KEY = "static"
local NAV_OBSTACLE_MODE_DEFAULT = "Default"
local NAV_OBSTACLE_MODE_IGNORE_PATCHES = "IgnorePatches"
local NAV_OBSTACLE_MODE_IGNORE_ALL = "IgnoreAll"
local ROLL_AREA_NAME = "RollArea"
local EDIT_SELECTION_HITBOX_NAME = "EditSelectionHitbox"
local STARTER_AREA_NAME = "StarterArea"
local STARTER_GRID_PART_NAME = "GridPart"
local PLOT_HOLDER_NAME = "PlotHolder"
local OWNER_BILLBOARD_NAME = "PlayerName"
local OWNER_BILLBOARD_FRAME_NAME = "Frame"
local OWNER_ICON_NAME = "Icon"
local OWNER_NAME_LABEL_NAME = "Name"
local OWNER_FARM_LABEL_NAME = "PlayerName"
local SIGNS_FOLDER_NAME = "Signs"
local PLAYER_SIGN_NAME = "PlayerSign"
local PLAYER_SIGN_INFO_NAME = "PlayerInfo"
local plotOwners
local petNicknameRandom = Random.new()

local ROLL_AREA_VISIBILITY_OPTIONS = {
	RuntimeHiddenAsVisible = true,
	RuntimeHiddenVisualAsVisible = true,
	RuntimeHiddenCanCollide = function(part)
		local current = part
		while current do
			if current.Name == "Path" then
				return false
			end
			current = current.Parent
		end
		return true
	end,
}

local function restoreRollAreaPresentation(plot)
	local rollArea = plot and plot:FindFirstChild(ROLL_AREA_NAME)
	if not rollArea then
		return
	end

	InstanceVisibility.ForgetTree(rollArea)
	InstanceVisibility.SetTreeActive(rollArea, true, ROLL_AREA_VISIBILITY_OPTIONS)
end

local function findDescendant(root, name, className)
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

local function addPlotOwnerBillboardDisplay(plot, displays)
	local starterArea = plot and plot:FindFirstChild(STARTER_AREA_NAME)
	local gridPart = starterArea and starterArea:FindFirstChild(STARTER_GRID_PART_NAME)
	local holder = gridPart and gridPart:FindFirstChild(PLOT_HOLDER_NAME)
	local billboard = holder and holder:FindFirstChild(OWNER_BILLBOARD_NAME)
	if not (billboard and billboard:IsA("BillboardGui")) then
		return
	end

	local frame = billboard:FindFirstChild(OWNER_BILLBOARD_FRAME_NAME)
	local icon = frame and frame:FindFirstChild(OWNER_ICON_NAME)
	local nameLabel = frame and frame:FindFirstChild(OWNER_NAME_LABEL_NAME)

	displays[#displays + 1] = {
		root = billboard,
		icon = icon and icon:IsA("ImageLabel") and icon or nil,
		nameLabel = nameLabel and nameLabel:IsA("TextLabel") and nameLabel or nil,
	}
end

local function addPlayerSignDisplay(plot, displays)
	local signs = plot and plot:FindFirstChild(SIGNS_FOLDER_NAME)
	local sign = signs and signs:FindFirstChild(PLAYER_SIGN_NAME)
	if not sign then
		return
	end

	local surfaceGui = findDescendant(sign, "SurfaceGui", "SurfaceGui")
	local info = surfaceGui and surfaceGui:FindFirstChild(PLAYER_SIGN_INFO_NAME)
	local icon = info and info:FindFirstChild(OWNER_ICON_NAME)
	local nameLabel = info and info:FindFirstChild(OWNER_NAME_LABEL_NAME)
	local farmLabel = info and info:FindFirstChild(OWNER_FARM_LABEL_NAME)

	displays[#displays + 1] = {
		root = surfaceGui,
		icon = icon and icon:IsA("ImageLabel") and icon or nil,
		nameLabel = nameLabel and nameLabel:IsA("TextLabel") and nameLabel or nil,
		farmLabel = farmLabel and farmLabel:IsA("TextLabel") and farmLabel or nil,
		sign = sign,
	}
end

local function getPlotOwnerDisplays(plot)
	local displays = {}
	addPlotOwnerBillboardDisplay(plot, displays)
	addPlayerSignDisplay(plot, displays)
	return displays
end

local function clearPlotOwnerDisplay(plot)
	for _, display in ipairs(getPlotOwnerDisplays(plot)) do
		if display.root and display.root:IsA("LayerCollector") then
			display.root.Enabled = false
		end
		if display.icon then
			display.icon.Image = ""
		end
		if display.nameLabel then
			display.nameLabel.Text = ""
		end
		if display.farmLabel then
			display.farmLabel.Text = ""
		end
	end
end

local function setPlotVacantPresentation(plot, vacant)
	if not plot then return end
	local rollArea = plot:FindFirstChild(ROLL_AREA_NAME)

	if vacant then
		if rollArea then
			InstanceVisibility.SetTreeActive(rollArea, false, ROLL_AREA_VISIBILITY_OPTIONS)
		end
		clearPlotOwnerDisplay(plot)
	else
		restoreRollAreaPresentation(plot)
	end
end

local function setPlotOwnerDisplay(plot, player, plotIndex)
	local displays = getPlotOwnerDisplays(plot)
	if #displays == 0 then
		return
	end

	local displayName = player.DisplayName ~= "" and player.DisplayName or player.Name
	for _, display in ipairs(displays) do
		if display.root and display.root:IsA("LayerCollector") then
			display.root.Enabled = true
		end
		if display.nameLabel then
			display.nameLabel.Text = display.farmLabel and (displayName .. "'s") or displayName
		end
		if display.farmLabel then
			display.farmLabel.Text = "Farm"
		end
		if display.icon then
			display.icon.Image = ""
		end
	end
	local userId = player.UserId
	if userId <= 0 then
		return
	end

	task.spawn(function()
		local ok, content = pcall(
			Players.GetUserThumbnailAsync,
			Players,
			userId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size150x150
		)
		if not ok or type(content) ~= "string" or content == "" then
			warn(string.format("[PlotService] Could not load owner thumbnail for user %d", userId))
			return
		end
		if plotOwners[plotIndex] ~= userId then
			return
		end
		for _, display in ipairs(displays) do
			local icon = display.icon
			if icon and icon:IsDescendantOf(plot) then
				icon.Image = content
			end
		end
	end)
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

local function cosmeticHitboxRootFromPart(plot, part)
	local current = part
	while current and current ~= plot do
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

local function placeableHitboxRootFromPart(plot, part)
	return feedHitboxRootFromPart(plot, part) or cosmeticHitboxRootFromPart(plot, part)
end

local function isFeedPlacementRoot(instance)
	return instance ~= nil
		and (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(instance:GetAttribute(State.Feed.Type)) == "string"
		and instance:GetAttribute(State.Feed.Type) ~= ""
		and instance:GetAttribute(State.Feed.Index) ~= nil
end

local function isCosmeticPlacementRoot(instance)
	return instance ~= nil
		and (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(instance:GetAttribute(State.Cosmetic.Id)) == "string"
		and instance:GetAttribute(State.Cosmetic.Id) ~= ""
		and instance:GetAttribute(State.Cosmetic.Index) ~= nil
end

local function canIgnorePlacementOverlap(movingKind, movingCosmeticId, hitPlaceable)
	if movingKind == "Feed" then
		return isCosmeticPlacementRoot(hitPlaceable) and Cosmetics.CanOverlapFeed(hitPlaceable)
	end
	if movingKind == "Cosmetic" then
		if Cosmetics.CanOverlapFeed(movingCosmeticId) then
			return isFeedPlacementRoot(hitPlaceable) or isCosmeticPlacementRoot(hitPlaceable)
		end
		return isCosmeticPlacementRoot(hitPlaceable) and Cosmetics.CanOverlapFeed(hitPlaceable)
	end
	return false
end

local function collectPlots()
	local list = {}
	local folder = Workspace:FindFirstChild("Plots")
	if folder then
		for _, plot in pairs(folder:GetChildren()) do
			table.insert(list, plot)
		end
	else
		for _, obj in pairs(Workspace:GetChildren()) do
			if obj.Name:match("^Plot%d") then
				table.insert(list, obj)
			end
		end
	end
	table.sort(list, function(a, b)
		local na = tonumber(a.Name:match("%d+$")) or 0
		local nb = tonumber(b.Name:match("%d+$")) or 0
		return na < nb
	end)
	return list
end

local plots       = collectPlots()
plotOwners        = {}
local playerPlots = {}
local localToWorldOnFloorTop
local plotPlacementRecords = setmetatable({}, { __mode = "k" })

-- Monotonic per-plot counter bumped whenever navigation obstacle bounds may
-- have changed. Kept outside placementRecord so it survives record clears;
-- consumers (PetNavigation grid cache) compare versions to invalidate.
local navObstacleVersions = setmetatable({}, { __mode = "k" })

local PlotService = {}

PlotService.NavigationObstacleModes = {
	Default = NAV_OBSTACLE_MODE_DEFAULT,
	IgnorePatches = NAV_OBSTACLE_MODE_IGNORE_PATCHES,
	IgnoreAll = NAV_OBSTACLE_MODE_IGNORE_ALL,
}

local function userKey(player)
	return player and player.UserId or nil
end

local function placementRecord(plot)
	local record = plotPlacementRecords[plot]
	if record then
		return record
	end
	record = {
		feeds = {},
		feedSet = {},
		feedConns = {},
		cosmetics = {},
		cosmeticSet = {},
		cosmeticConns = {},
		navStaticObstacleEntries = nil,
		navObstacleDirty = true,
	}
	plotPlacementRecords[plot] = record
	return record
end

local function markPlacementBoundsDirty(plot)
	if not plot then return end
	navObstacleVersions[plot] = (navObstacleVersions[plot] or 0) + 1
	local record = plotPlacementRecords[plot]
	if record then
		record.navStaticObstacleEntries = nil
		record.navObstacleDirty = true
	end
end

local function disconnectConnections(connections)
	if not connections then return end
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
end

local function removeFromArray(array, value)
	for index = #array, 1, -1 do
		if array[index] == value then
			table.remove(array, index)
			return
		end
	end
end

local unregisterFeedRoot
local unregisterCosmeticRoot

local function sortedIndexedCopy(array, indexAttribute)
	local result = {}
	for _, instance in ipairs(array) do
		if instance.Parent and instance:GetAttribute(indexAttribute) ~= nil then
			result[#result + 1] = instance
		end
	end
	table.sort(result, function(a, b)
		return (a:GetAttribute(indexAttribute) or 0) < (b:GetAttribute(indexAttribute) or 0)
	end)
	return result
end

local function registerFeedRoot(plot, root)
	if not (plot and root and root:IsDescendantOf(plot)) then return end
	local record = placementRecord(plot)
	if record.feedSet[root] then return end
	record.feedSet[root] = true
	record.feeds[#record.feeds + 1] = root
	markPlacementBoundsDirty(plot)
	local connections = {}
	connections[#connections + 1] = root.Destroying:Connect(function()
		unregisterFeedRoot(plot, root)
	end)
	connections[#connections + 1] = root.AncestryChanged:Connect(function()
		if not root:IsDescendantOf(plot) then
			unregisterFeedRoot(plot, root)
		end
	end)
	record.feedConns[root] = connections
end

unregisterFeedRoot = function(plot, root)
	local record = plot and plotPlacementRecords[plot]
	if not (record and record.feedSet[root]) then return end
	record.feedSet[root] = nil
	removeFromArray(record.feeds, root)
	disconnectConnections(record.feedConns[root])
	record.feedConns[root] = nil
	markPlacementBoundsDirty(plot)
end

local function registerCosmeticRoot(plot, root)
	if not (plot and root and root:IsDescendantOf(plot)) then return end
	local record = placementRecord(plot)
	if record.cosmeticSet[root] then return end
	record.cosmeticSet[root] = true
	record.cosmetics[#record.cosmetics + 1] = root
	markPlacementBoundsDirty(plot)
	local connections = {}
	connections[#connections + 1] = root.Destroying:Connect(function()
		unregisterCosmeticRoot(plot, root)
	end)
	connections[#connections + 1] = root.AncestryChanged:Connect(function()
		if not root:IsDescendantOf(plot) then
			unregisterCosmeticRoot(plot, root)
		end
	end)
	record.cosmeticConns[root] = connections
end

unregisterCosmeticRoot = function(plot, root)
	local record = plot and plotPlacementRecords[plot]
	if not (record and record.cosmeticSet[root]) then return end
	record.cosmeticSet[root] = nil
	removeFromArray(record.cosmetics, root)
	disconnectConnections(record.cosmeticConns[root])
	record.cosmeticConns[root] = nil
	markPlacementBoundsDirty(plot)
end

local function clearPlacementRecord(plot)
	local record = plot and plotPlacementRecords[plot]
	if not record then return end
	for root, connections in pairs(record.feedConns) do
		disconnectConnections(connections)
		record.feedSet[root] = nil
	end
	for root, connections in pairs(record.cosmeticConns) do
		disconnectConnections(connections)
		record.cosmeticSet[root] = nil
	end
	plotPlacementRecords[plot] = nil
	navObstacleVersions[plot] = (navObstacleVersions[plot] or 0) + 1
end

function PlotService.AssignPlot(player)
	local key = userKey(player)
	if key == nil then
		return nil, nil
	end

	for i, plot in ipairs(plots) do
		if not plotOwners[i] then
			plotOwners[i]  = key
			playerPlots[key] = i
			setPlotVacantPresentation(plot, false)
			setPlotOwnerDisplay(plot, player, i)
			return plot, i
		end
	end
	return nil, nil
end

function PlotService.GetPlayerPlot(player)
	local key = userKey(player)
	local i = key and playerPlots[key] or nil
	return i and plots[i] or nil
end

function PlotService.GetFloor(plot)
	local floor = plot and plot:FindFirstChild("Floor")
	return floor and floor:IsA("BasePart") and floor or nil
end

function PlotService.FreePlot(player)
	local key = userKey(player)
	local i = key and playerPlots[key] or nil
	if i then
		local plot = plots[i]
		plotOwners[i]       = nil
		playerPlots[key] = nil
		clearPlacementRecord(plot)
		setPlotVacantPresentation(plot, true)
	end
end

function PlotService.SyncVacantPlotVisibility()
	for i, plot in ipairs(plots) do
		setPlotVacantPresentation(plot, plotOwners[i] == nil)
	end
end

-- Returns all pet Models on the plot, sorted by PetIndex
function PlotService.GetSortedPets(plot)
	local pets = {}
	for _, obj in pairs(plot:GetChildren()) do
		if obj:IsA("Model") and obj:GetAttribute("PetIndex") then
			table.insert(pets, obj)
		end
	end
	table.sort(pets, function(a, b)
		return (a:GetAttribute("PetIndex") or 0) < (b:GetAttribute("PetIndex") or 0)
	end)
	return pets
end

-- Returns all FeedMachine instances on the plot (BaseParts and Models),
-- sorted by FeedIndex (which is assigned per-plot and matches the
-- placement array index in profile data).
function PlotService.GetSortedFeeds(plot)
	if not plot then return {} end
	return sortedIndexedCopy(placementRecord(plot).feeds, State.Feed.Index)
end

-- Returns all cosmetic instances on the plot, sorted by CosmeticIndex.
function PlotService.GetSortedCosmetics(plot)
	if not plot then return {} end
	return sortedIndexedCopy(placementRecord(plot).cosmetics, State.Cosmetic.Index)
end

-- Templates can be either BasePart or Model. Returns the Y-extent used
-- for stacking the machine on the floor surface.
local function templateHeight(template)
	if template:IsA("BasePart") then return template.Size.Y end
	if template:IsA("Model") then
		local pp = template.PrimaryPart
		if pp then return pp.Size.Y end
		return template:GetExtentsSize().Y
	end
	return 0
end

-- Anchors and positions a placed feed (Part or Model) at the given CFrame.
local function anchorAndPlace(clone, cframe)
	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CFrame   = cframe
	elseif clone:IsA("Model") then
		for _, p in ipairs(clone:GetDescendants()) do
			if p:IsA("BasePart") then p.Anchored = true end
		end
		clone:PivotTo(cframe)
	end
end

local function stripPromptTemplates(clone)
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		end
	end
end

local function applyFeedIdentity(instance, feedType, feedIndex)
	instance:SetAttribute(State.Feed.Type, feedType)
	instance:SetAttribute(State.Feed.Index, feedIndex)
	local feedClass = FeedMachines.GetClass(feedType)
	if feedClass then
		instance:SetAttribute(State.Feed.Class, feedClass)
	end
end

local function configurePatchRuntimeParts(instance, feedType)
	if FeedMachines.GetClass(feedType) ~= "Patch" then
		return
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false

			if descendant.Name == EDIT_SELECTION_HITBOX_NAME then
				descendant.CanQuery = true
				descendant.Transparency = 1
				descendant.CastShadow = false
			else
				descendant.CanQuery = false
			end

			if descendant.Name == "BaseFood" then
				descendant.Transparency = 1
				descendant.CastShadow = false
			end
		end
	end
end

local function configureTreeRuntimeParts(instance, feedType)
	if FeedMachines.GetClass(feedType) ~= "Tree" or not instance:IsA("Model") then
		return
	end

	local primary = instance.PrimaryPart
	if not primary then
		return
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local isPrimary = descendant == primary
			descendant.CanQuery = isPrimary
			descendant.CanTouch = isPrimary
		end
	end
end

local function applyCosmeticIdentity(instance, cosmeticId, cosmeticIndex)
	instance:SetAttribute(State.Cosmetic.Id, cosmeticId)
	instance:SetAttribute(State.Cosmetic.Index, cosmeticIndex)
end

local function normalizePetModel(model)
	local primary = model.PrimaryPart
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = descendant == primary
			descendant.Massless = true
		elseif descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		end
	end
end

local function petVisualForId(petId)
	local definition = PetCatalog.GetDefinition(petId)
	if not definition then return nil, nil end

	local visual = definition.Visual
	local modelName = visual and visual.ModelName
	if type(modelName) ~= "string" or modelName == "" then
		return nil, definition
	end

	local template = PetModels:FindFirstChild(modelName)
	if not (template and template:IsA("Model")) then
		return nil, definition
	end
	return template, definition
end

local function numberAttributeOrDefault(instance, attributeName, defaultValue)
	local value = instance:GetAttribute(attributeName)
	return type(value) == "number" and value or defaultValue
end

local function applyPetIdAttributes(pet, definition)
	local templatePetId = pet:GetAttribute(State.Pet.Id)
	local useTemplateProgression = templatePetId == definition.Id
	local nickname = PetNicknames.Pick(petNicknameRandom)

	pet:SetAttribute(State.Pet.Id, definition.Id)
	pet:SetAttribute(State.Pet.Order, useTemplateProgression
		and numberAttributeOrDefault(pet, State.Pet.Order, definition.Order)
		or definition.Order)
	pet:SetAttribute(State.Pet.MaxXP, useTemplateProgression
		and numberAttributeOrDefault(pet, State.Pet.MaxXP, definition.MaxXP)
		or definition.MaxXP)
	pet:SetAttribute(State.Pet.WalkSpeed, useTemplateProgression
		and numberAttributeOrDefault(pet, State.Pet.WalkSpeed, definition.WalkSpeed)
		or definition.WalkSpeed)
	pet:SetAttribute(State.Pet.MoneyRate, numberAttributeOrDefault(pet, State.Pet.MoneyRate, 1))
	pet:SetAttribute(State.Pet.Nickname, nickname)
	pet:SetAttribute(State.Pet.NicknameColor, PetNicknames.ColorFor(nickname))
end

local function modelPivotFloorOffset(model)
	return PetGeometry.PivotFloorOffset(model) or 0
end

local function seatPetOnFloor(pet, floor, lx, lz, lry)
	pet:PivotTo(localToWorldOnFloorTop(floor, lx, lz, modelPivotFloorOffset(pet), lry))
end

local function petFootprintMetrics(floor, pet)
	local pivotLocal = floor.CFrame:PointToObjectSpace(pet:GetPivot().Position)
	local boundsCF, boundsSize = pet:GetBoundingBox()
	local halfBounds = Vector3.new(boundsSize.X / 2, boundsSize.Y / 2, boundsSize.Z / 2)
	local maxX = 0
	local maxZ = 0

	for _, sx in ipairs(BOX_CORNER_SIGNS) do
		for _, sy in ipairs(BOX_CORNER_SIGNS) do
			for _, sz in ipairs(BOX_CORNER_SIGNS) do
				local worldCorner = boundsCF:PointToWorldSpace(Vector3.new(
					sx * halfBounds.X,
					sy * halfBounds.Y,
					sz * halfBounds.Z
				))
				local floorCorner = floor.CFrame:PointToObjectSpace(worldCorner)
				maxX = math.max(maxX, math.abs(floorCorner.X - pivotLocal.X))
				maxZ = math.max(maxZ, math.abs(floorCorner.Z - pivotLocal.Z))
			end
		end
	end

	local rotationSafePadding = math.max(maxX, maxZ)
	return rotationSafePadding, rotationSafePadding, boundsSize.Y
end

local function petFootprintPadding(floor, pet)
	local paddingX, paddingZ = petFootprintMetrics(floor, pet)
	return paddingX, paddingZ
end

local function petPathFootprintPadding(floor, pet)
	local paddingX, paddingZ = petFootprintMetrics(floor, pet)
	return paddingX * PET_PATH_PADDING_SCALE, paddingZ * PET_PATH_PADDING_SCALE
end

local function petNavigationMetrics(floor, pet)
	local paddingX, paddingZ, height = petFootprintMetrics(floor, pet)
	return paddingX * PET_PATH_PADDING_SCALE, paddingZ * PET_PATH_PADDING_SCALE, height
end

local function petFloorLocalBounds(floor, pet, plot)
	local paddingX, paddingZ = petPathFootprintPadding(floor, pet)
	if plot then
		local minX, maxX, minZ, maxZ = PlotGridService.GetUnlockedLocalBounds(plot, paddingX, paddingZ)
		if minX and minX < maxX and minZ < maxZ then
			return minX, maxX, minZ, maxZ
		end
		return 0, 0, 0, 0
	end

	local halfX = math.max(floor.Size.X / 2 - paddingX, 0)
	local halfZ = math.max(floor.Size.Z / 2 - paddingZ, 0)
	return -halfX, halfX, -halfZ, halfZ
end

local function fitPetOnUnlockedGrid(plot, pet, floor, lx, lz, lry, preferRandom)
	local paddingX, paddingZ = petPathFootprintPadding(floor, pet)
	local fitLX, fitLZ
	if preferRandom then
		fitLX, fitLZ = PlotGridService.RandomUnlockedPoint(plot, Random.new(), paddingX, paddingZ)
	else
		fitLX, fitLZ = PlotGridService.NearestUnlockedPoint(plot, lx, lz, paddingX, paddingZ)
	end
	if not fitLX or not fitLZ
		or not PlotGridService.IsWalkableFootprint(plot, fitLX, fitLZ, paddingX, paddingZ) then
		fitLX, fitLZ = PlotGridService.FirstUnlockedPoint(plot, paddingX, paddingZ)
	end
	if not fitLX or not fitLZ
		or not PlotGridService.IsWalkableFootprint(plot, fitLX, fitLZ, paddingX, paddingZ) then
		local looseLX, looseLZ
		if preferRandom then
			looseLX, looseLZ = PlotGridService.RandomUnlockedPoint(plot, Random.new(), 0, 0)
		else
			looseLX, looseLZ = PlotGridService.NearestUnlockedPoint(plot, lx, lz, 0, 0)
		end
		if not looseLX or not looseLZ
			or not PlotGridService.IsWalkableFootprint(plot, looseLX, looseLZ, 0, 0) then
			looseLX, looseLZ = PlotGridService.FirstUnlockedPoint(plot, 0, 0)
		end
		if not looseLX or not looseLZ
			or not PlotGridService.IsWalkableFootprint(plot, looseLX, looseLZ, 0, 0) then
			return false
		end
		seatPetOnFloor(pet, floor, looseLX, looseLZ, lry)
		return true, looseLX, looseLZ
	end
	seatPetOnFloor(pet, floor, fitLX, fitLZ, lry)
	return true, fitLX, fitLZ
end

-- ── Floor-local placement helpers ─────────────────────────────────────────────
-- All persisted feed/pet positions are stored in the floor's *local* frame
-- (lx, lz on the floor surface, lry as Y rotation in floor space) so they
-- survive Floor rotations and translations. World coordinates are always
-- derived at runtime via floor.CFrame.

-- World CFrame for an object whose feet sit on the floor's top surface,
-- offset by halfHeight along the floor's local up axis, and rotated lry
-- around the floor's local up.
function localToWorldOnFloorTop(floor, lx, lz, halfHeight, lry)
	local localCF = CFrame.new(lx, floor.Size.Y / 2 + halfHeight, lz)
		* CFrame.Angles(0, lry or 0, 0)
	return floor.CFrame * localCF
end

local function placementBoundsPart(model)
	local hitbox = model:FindFirstChild(EDIT_SELECTION_HITBOX_NAME)
	if hitbox and hitbox:IsA("BasePart") then
		return hitbox
	end
	return model.PrimaryPart
end

local function modelPlacementBounds(model, placementCF)
	local boundsPart = placementBoundsPart(model)
	if not boundsPart then return nil, nil end
	local boundsOffset = model:GetPivot():ToObjectSpace(boundsPart.CFrame)
	return placementCF * boundsOffset, boundsPart.Size
end

local function feedPlacementBounds(floor, feedType, lx, lz, lry)
	local template = FeedMachines.GetTemplate(feedType)
	if not template then return nil, nil end

	local height = templateHeight(template)
	local placementCF = localToWorldOnFloorTop(floor, lx, lz, height / 2, lry)
	if template:IsA("BasePart") then
		return placementCF, template.Size
	end
	if template:IsA("Model") then
		return modelPlacementBounds(template, placementCF)
	end
	return nil, nil
end

local function cosmeticPlacementBounds(floor, cosmeticId, lx, lz, lry)
	local template = Cosmetics.GetTemplate(cosmeticId)
	if not template then return nil, nil end

	local height = templateHeight(template)
	local placementCF = localToWorldOnFloorTop(floor, lx, lz, height / 2, lry)
	if template:IsA("BasePart") then
		return placementCF, template.Size
	end
	if template:IsA("Model") then
		return modelPlacementBounds(template, placementCF)
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

local function placementBoundsForInstance(instance)
	if instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end
	if instance:IsA("Model") then
		local boundsPart = placementBoundsPart(instance)
		if boundsPart then
			return boundsPart.CFrame, boundsPart.Size
		end
	end
	return nil, nil
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

-- Inverse: given a world pivot, return its (lx, lz, lry) in the floor's
-- local frame. Y is dropped — we only persist the planar offset because
-- machines and pets always rest on the floor surface.
local function worldPivotToFloorLocal(floor, world)
	local localCF = floor.CFrame:ToObjectSpace(world)
	local _, lry  = localCF:ToEulerAnglesXYZ()
	return localCF.X, localCF.Z, lry
end

-- Clones a pet Model template, applies scale, positions it on the floor at
-- floor-local (lx, lz) with floor-local Y rotation lry. Returns the clone
-- (not yet parented to the plot).
function PlotService.CreatePet(petId, petIndex, xp, floor, lx, lz, lry)
	local template, definition = petVisualForId(petId)
	if not template then
		warn("[PlotService] No pet visual template: " .. tostring(petId))
		return nil
	end
	if not template.PrimaryPart then
		warn("[PlotService] Pet visual template missing PrimaryPart: " .. petId)
		return nil
	end

	local clone = template:Clone()
	stripPromptTemplates(clone)
	normalizePetModel(clone)
	applyPetIdAttributes(clone, definition)
	clone:SetAttribute(State.Pet.Index, petIndex)
	clone:SetAttribute(State.Pet.MotionState, PetCatalog.MotionStates.Idle)

	local scale = Balance.ScaleForXP(xp or 0, clone:GetAttribute(State.Pet.MaxXP))
	local visualBaseScale = clone:GetScale()
	clone:SetAttribute(State.Pet.VisualBaseScale, visualBaseScale)
	clone:ScaleTo(visualBaseScale * scale)

	seatPetOnFloor(clone, floor, lx, lz, lry)
	return clone
end

-- pets: array of { petId, xp, money, lx?, lz?, lry? } (1-indexed). Pets without
-- saved positions (legacy saves) get a random floor-local position once;
-- savePetsFromPlot will persist their new lx/lz/lry on the next snapshot.
function PlotService.SpawnPetsForPlot(plot, pets)
	if type(pets) ~= "table" then
		pets = {}
	end
	local expected = #pets
	local floor = PlotService.GetFloor(plot)
	if not floor then
		warn("[PlotService] " .. plot.Name .. " has no Floor — cannot spawn pets")
		return 0, expected
	end

	local spawned = 0
	local restoredPets = {}
	local unspawnedPets = {}
	for _, petData in ipairs(pets) do
		local lx, lz, lry = nil, nil, 0
		local hadSavedPosition = petData.lx ~= nil and petData.lz ~= nil
		if petData.lx ~= nil and petData.lz ~= nil then
			lx, lz, lry = petData.lx, petData.lz, petData.lry or 0
		else
			lx, lz = PlotGridService.RandomUnlockedPoint(plot, Random.new(), 0, 0)
		end
		if not lx or not lz then
			lx, lz = PlotGridService.FirstUnlockedPoint(plot, 0, 0)
		end
		if not lx or not lz then
			warn(string.format("[PlotService] No unlocked grid cell available to spawn pet %s for %s", tostring(petData.petId), plot.Name))
			unspawnedPets[#unspawnedPets + 1] = petData
			continue
		end
		local petId = petData.petId
		local clone = PlotService.CreatePet(petId, spawned + 1, petData.xp or 0, floor, lx, lz, lry)
		if not clone then
			unspawnedPets[#unspawnedPets + 1] = petData
			continue
		end

		local fitted, fitLX, fitLZ = fitPetOnUnlockedGrid(plot, clone, floor, lx, lz, lry, not hadSavedPosition)
		if not fitted then
			warn(string.format(
				"[PlotService] Could not fit pet %s inside unlocked grid for %s",
				tostring(petId),
				plot.Name
			))
			clone:Destroy()
			unspawnedPets[#unspawnedPets + 1] = petData
			continue
		end
		clone.Parent = plot
		if fitLX and fitLZ then
			seatPetOnFloor(clone, floor, fitLX, fitLZ, lry)
		end
		spawned += 1
		restoredPets[#restoredPets + 1] = petData
	end

	for key in pairs(pets) do
		pets[key] = nil
	end
	for _, petData in ipairs(restoredPets) do
		pets[#pets + 1] = petData
	end
	for _, petData in ipairs(unspawnedPets) do
		pets[#pets + 1] = petData
	end

	return spawned, expected
end

-- Replaces a pet Model in place with a new pet id, keeping its plot position.
-- Returns the new Model (already parented), or nil on failure.
function PlotService.ReplacePetAt(plot, oldPet, newPetId, petIndex, xp, worldPivot)
	local floor = PlotService.GetFloor(plot)
	if not floor then return nil end
	local lx, lz, lry = worldPivotToFloorLocal(floor, worldPivot or oldPet:GetPivot())
	local clone = PlotService.CreatePet(newPetId, petIndex, xp or 0, floor, lx, lz, lry)
	if clone then
		oldPet:Destroy()
		clone.Parent = plot
	end
	return clone
end

-- Re-applies scale to a pet based on its current XP (does not move it).
function PlotService.RescalePet(pet, xp, worldPivot)
	local maxXP = pet:GetAttribute(State.Pet.MaxXP)
	local scale = Balance.ScaleForXP(xp or 0, maxXP)
	local visualBaseScale = pet:GetAttribute(State.Pet.VisualBaseScale) or pet:GetScale()
	local floor = pet.Parent and PlotService.GetFloor(pet.Parent) or nil
	local lx, lz, lry
	if floor then
		lx, lz, lry = worldPivotToFloorLocal(floor, worldPivot or pet:GetPivot())
	end
	pet:ScaleTo(visualBaseScale * scale)
	if floor then
		seatPetOnFloor(pet, floor, lx, lz, lry)
	end
end

function PlotService.ApplyPetIdAttributes(pet, petId)
	local definition = PetCatalog.GetDefinition(petId)
	if not definition then return false end
	applyPetIdAttributes(pet, definition)
	return true
end

function PlotService.SpawnFeedsForPlot(plot, placements)
	placements = placements or {}
	local floor = PlotService.GetFloor(plot)
	if not floor then
		warn("[PlotService] " .. plot.Name .. " has no Floor — cannot spawn feeds")
		return
	end

	for i, rec in ipairs(placements) do
		local feedType = type(rec) == "table" and rec.type or nil
		if type(feedType) ~= "string" then
			warn("[PlotService] Skipping feed placement with no feed type")
			continue
		end
		local lx, lz = PlotGridService.NearestUnlockedPoint(plot, rec.lx or 0, rec.lz or 0)
		PlotService.PlaceFeedWithIndex(plot, feedType, i, lx, lz, rec.lry or 0)
	end
end

function PlotService.NextFeedIndex(plot)
	local maxIndex = 0
	for _, f in ipairs(PlotService.GetSortedFeeds(plot)) do
		local idx = f:GetAttribute(State.Feed.Index) or 0
		if idx > maxIndex then maxIndex = idx end
	end
	return maxIndex + 1
end

function PlotService.NextCosmeticIndex(plot)
	local maxIndex = 0
	for _, cosmetic in ipairs(PlotService.GetSortedCosmetics(plot)) do
		local idx = cosmetic:GetAttribute(State.Cosmetic.Index) or 0
		if idx > maxIndex then maxIndex = idx end
	end
	return maxIndex + 1
end

-- Spawns a feed/growing instance at a specific floor-local placement index.
-- The optional template override is used for growing visuals such as saplings.
function PlotService.PlaceFeedWithIndex(plot, feedType, feedIndex, lx, lz, lry, templateOverride)
	local floor = PlotService.GetFloor(plot)
	if not floor then return nil end

	local template = templateOverride or FeedMachines.GetTemplate(feedType)
	if not template then
		warn("[PlotService] No feed template: " .. tostring(feedType))
		return nil
	end

	local clone = template:Clone()
	stripPromptTemplates(clone)
	applyFeedIdentity(clone, feedType, feedIndex)
	configurePatchRuntimeParts(clone, feedType)
	configureTreeRuntimeParts(clone, feedType)

	local height = templateHeight(clone)
	anchorAndPlace(clone, localToWorldOnFloorTop(floor, lx, lz, height / 2, lry))
	clone.Parent = plot
	registerFeedRoot(plot, clone)
	return clone
end

-- Spawns a single mature FeedMachine at floor-local (lx, lz, lry). Returns the
-- new instance (BasePart or Model) with FeedType and FeedIndex set,
-- parented to the plot.
function PlotService.PlaceFeed(plot, feedType, lx, lz, lry)
	return PlotService.PlaceFeedWithIndex(plot, feedType, PlotService.NextFeedIndex(plot), lx, lz, lry)
end

function PlotService.PlaceCosmeticWithIndex(plot, cosmeticId, cosmeticIndex, lx, lz, lry)
	local floor = PlotService.GetFloor(plot)
	if not floor then return nil end

	local template = Cosmetics.GetTemplate(cosmeticId)
	if not template then
		warn("[PlotService] No cosmetic template: " .. tostring(cosmeticId))
		return nil
	end

	local clone = template:Clone()
	stripPromptTemplates(clone)
	applyCosmeticIdentity(clone, cosmeticId, cosmeticIndex)

	local height = templateHeight(clone)
	anchorAndPlace(clone, localToWorldOnFloorTop(floor, lx, lz, height / 2, lry))
	clone.Parent = plot
	registerCosmeticRoot(plot, clone)
	return clone
end

function PlotService.PlaceCosmetic(plot, cosmeticId, lx, lz, lry)
	return PlotService.PlaceCosmeticWithIndex(plot, cosmeticId, PlotService.NextCosmeticIndex(plot), lx, lz, lry)
end

function PlotService.FeedPlacementFitsOnFloor(plot, feedType, lx, lz, lry)
	local floor = PlotService.GetFloor(plot)
	if not floor then return false end

	local boundsCF, boundsSize = feedPlacementBounds(floor, feedType, lx, lz, lry)
	if not boundsCF or not boundsSize then return false end

	return boundsFitOnFloor(floor, boundsCF, boundsSize)
		and PlotGridService.CanPlaceFootprint(plot, boundsCF, boundsSize)
end

function PlotService.CosmeticPlacementFitsOnFloor(plot, cosmeticId, lx, lz, lry)
	local floor = PlotService.GetFloor(plot)
	if not floor then return false end

	local boundsCF, boundsSize = cosmeticPlacementBounds(floor, cosmeticId, lx, lz, lry)
	if not boundsCF or not boundsSize then return false end

	return boundsFitOnFloor(floor, boundsCF, boundsSize)
		and PlotGridService.CanPlaceFootprint(plot, boundsCF, boundsSize)
end

local function placementOverlapsBounds(plot, boundsCF, boundsSize, excludedPlaceable, options)
	if not boundsCF or not boundsSize then return true end
	local floor = PlotService.GetFloor(plot)
	if not floor then return true end
	options = options or {}

	local querySize = Vector3.new(
		math.max(boundsSize.X - OVERLAP_QUERY_INSET, 0.05),
		boundsSize.Y,
		math.max(boundsSize.Z - OVERLAP_QUERY_INSET, 0.05)
	)

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { plot }

	for _, part in ipairs(Workspace:GetPartBoundsInBox(boundsCF, querySize, params)) do
		local hitPlaceable = placeableHitboxRootFromPart(plot, part)
		if hitPlaceable
			and hitPlaceable ~= excludedPlaceable
			and not canIgnorePlacementOverlap(options.movingKind, options.cosmeticId, hitPlaceable) then
			local hitBoundsCF, hitBoundsSize = placementBoundsForInstance(hitPlaceable)
			if boundsOverlapOnFloor(floor, boundsCF, querySize, hitBoundsCF, hitBoundsSize) then
				return true
			end
		end
	end
	return false
end

local function feedPlacementOverlaps(plot, feedType, lx, lz, lry, excludedFeed)
	local floor = PlotService.GetFloor(plot)
	if not floor then return true end

	local boundsCF, boundsSize = feedPlacementBounds(floor, feedType, lx, lz, lry)
	return placementOverlapsBounds(plot, boundsCF, boundsSize, excludedFeed, {
		movingKind = "Feed",
	})
end

local function cosmeticPlacementOverlaps(plot, cosmeticId, lx, lz, lry, excludedCosmetic)
	local floor = PlotService.GetFloor(plot)
	if not floor then return true end

	local boundsCF, boundsSize = cosmeticPlacementBounds(floor, cosmeticId, lx, lz, lry)
	return placementOverlapsBounds(plot, boundsCF, boundsSize, excludedCosmetic, {
		movingKind = "Cosmetic",
		cosmeticId = cosmeticId,
	})
end

function PlotService.FeedPlacementOverlaps(plot, feedType, lx, lz, lry)
	return feedPlacementOverlaps(plot, feedType, lx, lz, lry)
end

function PlotService.FeedPlacementOverlapsExcept(plot, feedType, lx, lz, lry, excludedFeed)
	return feedPlacementOverlaps(plot, feedType, lx, lz, lry, excludedFeed)
end

function PlotService.CosmeticPlacementOverlaps(plot, cosmeticId, lx, lz, lry)
	return cosmeticPlacementOverlaps(plot, cosmeticId, lx, lz, lry)
end

function PlotService.CosmeticPlacementOverlapsExcept(plot, cosmeticId, lx, lz, lry, excludedCosmetic)
	return cosmeticPlacementOverlaps(plot, cosmeticId, lx, lz, lry, excludedCosmetic)
end

function PlotService.RepositionFeed(plot, feed, lx, lz, lry)
	local floor = PlotService.GetFloor(plot)
	if not floor or not feed or not feed:IsDescendantOf(plot) then return nil end
	if not (feed:IsA("BasePart") or feed:IsA("Model")) then return nil end

	local height = templateHeight(feed)
	local cframe = localToWorldOnFloorTop(floor, lx, lz, height / 2, lry)
	anchorAndPlace(feed, cframe)
	markPlacementBoundsDirty(plot)
	return cframe
end

function PlotService.RepositionCosmetic(plot, cosmetic, lx, lz, lry)
	local floor = PlotService.GetFloor(plot)
	if not floor or not cosmetic or not cosmetic:IsDescendantOf(plot) then return nil end
	if not (cosmetic:IsA("BasePart") or cosmetic:IsA("Model")) then return nil end

	local height = templateHeight(cosmetic)
	local cframe = localToWorldOnFloorTop(floor, lx, lz, height / 2, lry)
	anchorAndPlace(cosmetic, cframe)
	markPlacementBoundsDirty(plot)
	return cframe
end

-- Exposed for callers (init.server.luau saveFeedState / savePetsFromPlot,
-- the PlaceFeedMachine remote) to convert between world pivot and the
-- floor-local frame we persist in.
function PlotService.WorldPivotToFloorLocal(floor, world)
	return worldPivotToFloorLocal(floor, world)
end

function PlotService.LocalToWorldOnFloorTop(floor, lx, lz, halfHeight, lry)
	return localToWorldOnFloorTop(floor, lx, lz, halfHeight, lry)
end

function PlotService.PetPivotFloorOffset(pet)
	return modelPivotFloorOffset(pet)
end

function PlotService.SeatPetOnFloor(pet, floor, lx, lz, lry)
	return seatPetOnFloor(pet, floor, lx, lz, lry)
end

function PlotService.PetFloorLocalBounds(floor, pet, plot)
	return petFloorLocalBounds(floor, pet, plot)
end

function PlotService.PetFootprintPadding(floor, pet)
	return petFootprintPadding(floor, pet)
end

function PlotService.PetPathFootprintPadding(floor, pet)
	return petPathFootprintPadding(floor, pet)
end

function PlotService.PetNavigationMetrics(floor, pet)
	return petNavigationMetrics(floor, pet)
end

function PlotService.FitPetOnUnlockedGrid(plot, pet, lx, lz, lry, preferRandom)
	local floor = PlotService.GetFloor(plot)
	if not floor then return false end
	return fitPetOnUnlockedGrid(plot, pet, floor, lx, lz, lry or 0, preferRandom == true)
end

function PlotService.GetNavigationObstacleVersion(plot)
	return plot and navObstacleVersions[plot] or 0
end

local function normalizeNavigationObstacleMode(mode)
	if mode == NAV_OBSTACLE_MODE_IGNORE_PATCHES or mode == NAV_OBSTACLE_MODE_IGNORE_ALL then
		return mode
	end
	return NAV_OBSTACLE_MODE_DEFAULT
end

local function navigationObstacleEntries(plot, floor)
	local record = placementRecord(plot)
	if record.navObstacleDirty == false and record.navStaticObstacleEntries then
		return record.navStaticObstacleEntries
	end

	local entries = {}
	local function addObstacle(instance, isFeed, tokenId)
		local boundsCF, boundsSize
		if instance:IsA("BasePart") then
			boundsCF, boundsSize = instance.CFrame, instance.Size
		elseif instance:IsA("Model") then
			local boundsPart = placementBoundsPart(instance)
			if boundsPart then
				boundsCF, boundsSize = boundsPart.CFrame, boundsPart.Size
			end
		end

		if boundsCF and boundsSize then
			local minX, maxX, minZ, maxZ = floorLocalBoundsFromBox(floor, boundsCF, boundsSize)
			if minX then
				entries[#entries + 1] = {
					instance = instance,
					isFeed = isFeed == true,
					tokenId = tokenId,
					minX = minX,
					maxX = maxX,
					minZ = minZ,
					maxZ = maxZ,
				}
			end
		end
	end

	local feedOrder = 0
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		feedOrder += 1
		local feedIndex = feed:GetAttribute(State.Feed.Index)
		addObstacle(feed, true, tostring(feedIndex or feedOrder))
	end
	for _, cosmetic in ipairs(PlotService.GetSortedCosmetics(plot)) do
		if not Cosmetics.CanOverlapFeed(cosmetic) then
			addObstacle(cosmetic, false)
		end
	end

	record.navStaticObstacleEntries = entries
	record.navObstacleDirty = false
	return entries
end

function PlotService.GetNavigationObstacleSnapshot(plot, now, mode)
	local floor = PlotService.GetFloor(plot)
	if not floor then return {}, NAV_OBSTACLE_STATIC_KEY end
	if type(now) ~= "number" then
		now = Workspace:GetServerTimeNow()
	end
	mode = normalizeNavigationObstacleMode(mode)
	if mode == NAV_OBSTACLE_MODE_IGNORE_ALL then
		return {}, NAV_OBSTACLE_STATIC_KEY
	end

	local entries = navigationObstacleEntries(plot, floor)
	local obstacles = {}
	local tokens = {}
	for _, entry in ipairs(entries) do
		local blocks = true
		local token = "block"
		if entry.isFeed then
			if mode == NAV_OBSTACLE_MODE_IGNORE_PATCHES
				and entry.instance:GetAttribute(State.Feed.Class) == "Patch" then
				continue
			end

			blocks, token = FeedMachines.BlocksPetNavigation(entry.instance, now)
			if type(token) ~= "string" or token == "" then
				token = blocks and "block" or "walkable"
			end
			if token ~= "block" then
				tokens[#tokens + 1] = tostring(entry.tokenId) .. ":" .. token
			end
		end

		if blocks ~= false then
			obstacles[#obstacles + 1] = entry
		end
	end

	local key = #tokens > 0 and table.concat(tokens, "|") or NAV_OBSTACLE_STATIC_KEY
	return obstacles, key
end

function PlotService.GetNavigationObstacleBounds(plot)
	local obstacles = PlotService.GetNavigationObstacleSnapshot(plot)
	return obstacles
end

-- Exposed so PlaceFeedMachine can compute placement Y from the template alone.
function PlotService.TemplateHeight(template)
	return templateHeight(template)
end

function PlotService.DestroyPets(plot)
	for _, pet in ipairs(PlotService.GetSortedPets(plot)) do
		pet:Destroy()
	end
end

function PlotService.DestroyFeeds(plot)
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		feed:Destroy()
	end
end

function PlotService.DestroyCosmetics(plot)
	for _, cosmetic in ipairs(PlotService.GetSortedCosmetics(plot)) do
		cosmetic:Destroy()
	end
end

return PlotService
