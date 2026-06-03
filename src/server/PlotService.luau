local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets       = require(ReplicatedStorage.Shared:WaitForChild("Assets"))
local Balance      = require(ReplicatedStorage.Shared:WaitForChild("Balance"))
local PetCatalog   = require(ReplicatedStorage.Shared:WaitForChild("PetCatalog"))
local State        = require(ReplicatedStorage.Shared:WaitForChild("State"))
local FeedMachines = require(script.Parent:WaitForChild("feedMachines"))
local PlotGridService = require(script.Parent:WaitForChild("PlotGridService"))
local InstanceVisibility = require(script.Parent:WaitForChild("InstanceVisibility"))

local PetModels = Assets.WaitFor(Assets.Names.PetModels)

local FOOTPRINT_BOUNDS_EPSILON = 0.001
local OVERLAP_QUERY_INSET = 0.05
local BOX_CORNER_SIGNS = { -1, 1 }
local ROLL_AREA_NAME = "RollArea"

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

local function setPlotVacantPresentation(plot, vacant)
	if not plot then return end
	local rollArea = plot:FindFirstChild(ROLL_AREA_NAME)
	if not rollArea then return end

	if vacant then
		InstanceVisibility.SetTreeActive(rollArea, false, ROLL_AREA_VISIBILITY_OPTIONS)
	else
		restoreRollAreaPresentation(plot)
	end
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
local plotOwners  = {}
local playerPlots = {}
local localToWorldOnFloorTop

local PlotService = {}

function PlotService.AssignPlot(player)
	for i, plot in ipairs(plots) do
		if not plotOwners[i] then
			plotOwners[i]       = player
			playerPlots[player] = i
			setPlotVacantPresentation(plot, false)
			return plot, i
		end
	end
	return nil, nil
end

function PlotService.GetPlayerPlot(player)
	local i = playerPlots[player]
	return i and plots[i] or nil
end

function PlotService.GetFloor(plot)
	local floor = plot and plot:FindFirstChild("Floor")
	return floor and floor:IsA("BasePart") and floor or nil
end

function PlotService.FreePlot(player)
	local i = playerPlots[player]
	if i then
		local plot = plots[i]
		plotOwners[i]       = nil
		playerPlots[player] = nil
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
	local feeds = {}
	for _, obj in pairs(plot:GetDescendants()) do
		local feedType = obj:GetAttribute(State.Feed.Type)
		if (obj:IsA("BasePart") or obj:IsA("Model"))
			and type(feedType) == "string"
			and feedType ~= ""
			and obj:GetAttribute(State.Feed.Index) then
			table.insert(feeds, obj)
		end
	end
	table.sort(feeds, function(a, b)
		return (a:GetAttribute(State.Feed.Index) or 0) < (b:GetAttribute(State.Feed.Index) or 0)
	end)
	return feeds
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
end

local function modelPivotFloorOffset(model)
	local pivot = model:GetPivot()
	local boundsCF, boundsSize = model:GetBoundingBox()
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

local function seatPetOnFloor(pet, floor, lx, lz, lry)
	pet:PivotTo(localToWorldOnFloorTop(floor, lx, lz, modelPivotFloorOffset(pet), lry))
end

local function petFootprintPadding(floor, pet)
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
	return rotationSafePadding, rotationSafePadding
end

local function petFloorLocalBounds(floor, pet, plot)
	local paddingX, paddingZ = petFootprintPadding(floor, pet)
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
	local paddingX, paddingZ = petFootprintPadding(floor, pet)
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
		return false
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

local function feedPlacementBounds(floor, feedType, lx, lz, lry)
	local template = FeedMachines.GetTemplate(feedType)
	if not template then return nil, nil end

	local height = templateHeight(template)
	local placementCF = localToWorldOnFloorTop(floor, lx, lz, height / 2, lry)
	if template:IsA("BasePart") then
		return placementCF, template.Size
	end
	if template:IsA("Model") then
		local primary = template.PrimaryPart
		if not primary then return nil, nil end
		local primaryOffset = template:GetPivot():ToObjectSpace(primary.CFrame)
		return placementCF * primaryOffset, primary.Size
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
	pets = pets or {}
	local floor = PlotService.GetFloor(plot)
	if not floor then
		warn("[PlotService] " .. plot.Name .. " has no Floor — cannot spawn pets")
		return
	end

	for i, petData in ipairs(pets) do
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
			continue
		end
		local petId = petData.petId
		local clone = PlotService.CreatePet(petId, i, petData.xp or 0, floor, lx, lz, lry)
		if clone then
			local fitted = fitPetOnUnlockedGrid(plot, clone, floor, lx, lz, lry, not hadSavedPosition)
			if not fitted then
				warn(string.format(
					"[PlotService] Could not fit pet %s inside unlocked grid for %s",
					tostring(petId),
					plot.Name
				))
				clone:Destroy()
				continue
			end
			clone.Parent = plot
		end
	end
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

	local height = templateHeight(clone)
	anchorAndPlace(clone, localToWorldOnFloorTop(floor, lx, lz, height / 2, lry))
	clone.Parent = plot
	return clone
end

-- Spawns a single mature FeedMachine at floor-local (lx, lz, lry). Returns the
-- new instance (BasePart or Model) with FeedType and FeedIndex set,
-- parented to the plot.
function PlotService.PlaceFeed(plot, feedType, lx, lz, lry)
	return PlotService.PlaceFeedWithIndex(plot, feedType, PlotService.NextFeedIndex(plot), lx, lz, lry)
end

function PlotService.FeedPlacementFitsOnFloor(plot, feedType, lx, lz, lry)
	local floor = PlotService.GetFloor(plot)
	if not floor then return false end

	local boundsCF, boundsSize = feedPlacementBounds(floor, feedType, lx, lz, lry)
	if not boundsCF or not boundsSize then return false end

	return boundsFitOnFloor(floor, boundsCF, boundsSize)
		and PlotGridService.CanPlaceFootprint(plot, boundsCF, boundsSize)
end

local function feedPlacementOverlaps(plot, feedType, lx, lz, lry, excludedFeed)
	local floor = PlotService.GetFloor(plot)
	if not floor then return true end

	local boundsCF, boundsSize = feedPlacementBounds(floor, feedType, lx, lz, lry)
	if not boundsCF or not boundsSize then return true end
	local querySize = Vector3.new(
		math.max(boundsSize.X - OVERLAP_QUERY_INSET, 0.05),
		boundsSize.Y,
		math.max(boundsSize.Z - OVERLAP_QUERY_INSET, 0.05)
	)

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { plot }

	for _, part in ipairs(Workspace:GetPartBoundsInBox(boundsCF, querySize, params)) do
		local hitFeed = feedHitboxRootFromPart(plot, part)
		if hitFeed and hitFeed ~= excludedFeed then
			return true
		end
	end
	return false
end

function PlotService.FeedPlacementOverlaps(plot, feedType, lx, lz, lry)
	return feedPlacementOverlaps(plot, feedType, lx, lz, lry)
end

function PlotService.FeedPlacementOverlapsExcept(plot, feedType, lx, lz, lry, excludedFeed)
	return feedPlacementOverlaps(plot, feedType, lx, lz, lry, excludedFeed)
end

function PlotService.RepositionFeed(plot, feed, lx, lz, lry)
	local floor = PlotService.GetFloor(plot)
	if not floor or not feed or not feed:IsDescendantOf(plot) then return nil end
	if not (feed:IsA("BasePart") or feed:IsA("Model")) then return nil end

	local height = templateHeight(feed)
	local cframe = localToWorldOnFloorTop(floor, lx, lz, height / 2, lry)
	anchorAndPlace(feed, cframe)
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

function PlotService.FitPetOnUnlockedGrid(plot, pet, lx, lz, lry, preferRandom)
	local floor = PlotService.GetFloor(plot)
	if not floor then return false end
	return fitPetOnUnlockedGrid(plot, pet, floor, lx, lz, lry or 0, preferRandom == true)
end

function PlotService.GetNavigationObstacleBounds(plot)
	local floor = PlotService.GetFloor(plot)
	if not floor then return {} end

	local obstacles = {}
	for _, feed in ipairs(PlotService.GetSortedFeeds(plot)) do
		local boundsCF, boundsSize
		if feed:IsA("BasePart") then
			boundsCF, boundsSize = feed.CFrame, feed.Size
		elseif feed:IsA("Model") then
			local primary = feed.PrimaryPart
			if primary then
				boundsCF, boundsSize = primary.CFrame, primary.Size
			end
		end

		if boundsCF and boundsSize then
			local minX, maxX, minZ, maxZ = floorLocalBoundsFromBox(floor, boundsCF, boundsSize)
			if minX then
				obstacles[#obstacles + 1] = {
					instance = feed,
					minX = minX,
					maxX = maxX,
					minZ = minZ,
					maxZ = maxZ,
				}
			end
		end
	end

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

return PlotService
