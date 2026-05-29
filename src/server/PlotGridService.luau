local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local State = require(Shared:WaitForChild("State"))

local CurrencyService = require(script.Parent:WaitForChild("CurrencyService"))
local InstanceVisibility = require(script.Parent:WaitForChild("InstanceVisibility"))

local PlotGridService = {}

local DEFAULT_PURCHASE_DISTANCE = 14
local POINT_EPSILON = 0.001
local RUNTIME_FLOOR_NAME = "Floor"

local indexesByPlot = setmetatable({}, { __mode = "k" })
local statesByPlot = setmetatable({}, { __mode = "k" })

local GRID_VISIBILITY_OPTIONS = {
	RuntimeHiddenAsVisible = true,
	RuntimeHiddenVisualAsVisible = true,
	RuntimeHiddenCanCollide = function(part)
		return part.Name ~= "VacantGridPart"
	end,
}

local function setBasePartActive(part, active)
	InstanceVisibility.SetActive(part, active, GRID_VISIBILITY_OPTIONS)
end

local function setInstanceTreeActive(instance, active)
	InstanceVisibility.SetTreeActive(instance, active, GRID_VISIBILITY_OPTIONS)
end

local function collectGridParts(folder, isStarter)
	local cells = {}
	if not folder then return cells end
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") then
			cells[#cells + 1] = {
				part = child,
				starter = isStarter,
				unlockable = not isStarter,
			}
		end
	end
	return cells
end

local function floorForPlot(plot)
	local floor = plot and plot:FindFirstChild(RUNTIME_FLOOR_NAME)
	return floor and floor:IsA("BasePart") and floor or nil
end

local function ensureRuntimeFloor(plot, cells)
	local floor = floorForPlot(plot)
	if floor then return floor end
	if #cells == 0 then return nil end

	local first = cells[1].part
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, cell in ipairs(cells) do
		local part = cell.part
		local localPos = first.CFrame:PointToObjectSpace(part.Position)
		local halfX = part.Size.X / 2
		local halfY = part.Size.Y / 2
		local halfZ = part.Size.Z / 2
		minX = math.min(minX, localPos.X - halfX)
		maxX = math.max(maxX, localPos.X + halfX)
		minY = math.min(minY, localPos.Y - halfY)
		maxY = math.max(maxY, localPos.Y + halfY)
		minZ = math.min(minZ, localPos.Z - halfZ)
		maxZ = math.max(maxZ, localPos.Z + halfZ)
	end

	floor = Instance.new("Part")
	floor.Name = RUNTIME_FLOOR_NAME
	floor.Anchored = true
	floor.Transparency = 1
	floor.CanCollide = false
	floor.CanTouch = false
	floor.CanQuery = false
	floor.CastShadow = false
	floor.Size = Vector3.new(math.max(maxX - minX, 1), math.max(maxY - minY, 0.2), math.max(maxZ - minZ, 1))
	floor.CFrame = first.CFrame * CFrame.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	floor.Parent = plot
	return floor
end

local function floorLocalBoundsForPart(floor, part)
	local half = part.Size / 2
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local world = part.CFrame:PointToWorldSpace(Vector3.new(sx * half.X, 0, sz * half.Z))
			local localPoint = floor.CFrame:PointToObjectSpace(world)
			minX = math.min(minX, localPoint.X)
			maxX = math.max(maxX, localPoint.X)
			minZ = math.min(minZ, localPoint.Z)
			maxZ = math.max(maxZ, localPoint.Z)
		end
	end
	return minX, maxX, minZ, maxZ
end

local function sortedUnlockableCells(index)
	local cells = table.clone(index.unlockableCells)
	table.sort(cells, function(a, b)
		if a.z ~= b.z then return a.z < b.z end
		if a.x ~= b.x then return a.x < b.x end
		return a.coordKey < b.coordKey
	end)
	return cells
end

local function isUnlocked(unlockedKeys, cell)
	return cell ~= nil and (cell.starter == true or unlockedKeys[cell.coordKey] == true)
end

local function positionOf(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then return instance.Position end
	if instance:IsA("Model") then
		if instance.PrimaryPart then return instance.PrimaryPart.Position end
		local ok, pivot = pcall(function() return instance:GetPivot() end)
		return ok and pivot.Position or nil
	end
	return nil
end

local function playerRootPosition(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function closestPointOnPart(part, worldPosition)
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	local half = part.Size / 2
	local clamped = Vector3.new(
		math.clamp(localPosition.X, -half.X, half.X),
		math.clamp(localPosition.Y, -half.Y, half.Y),
		math.clamp(localPosition.Z, -half.Z, half.Z)
	)
	return part.CFrame:PointToWorldSpace(clamped)
end

local function isPlayerNear(player, target, maxDistance)
	local root = playerRootPosition(player)
	local targetPosition = nil
	if root and target and target:IsA("BasePart") then
		targetPosition = closestPointOnPart(target, root)
	else
		targetPosition = positionOf(target)
	end
	return root ~= nil and targetPosition ~= nil and (root - targetPosition).Magnitude <= maxDistance
end

function PlotGridService.BuildIndex(plot)
	if not plot then return nil end

	local cached = indexesByPlot[plot]
	if cached then return cached end

	local starterFolder = plot:FindFirstChild(PlotGrid.Folders.Starter)
	local unlockableFolder = plot:FindFirstChild(PlotGrid.Folders.Unlockable)

	local cells = {}
	for _, cell in ipairs(collectGridParts(starterFolder, true)) do
		cells[#cells + 1] = cell
	end
	for _, cell in ipairs(collectGridParts(unlockableFolder, false)) do
		cells[#cells + 1] = cell
	end
	local floor = ensureRuntimeFloor(plot, cells)

	local index = {
		plot = plot,
		floor = floor,
		cells = cells,
		cellsByCoord = {},
		cellsByPart = {},
		starterKeys = {},
		unlockableCells = {},
	}

	for _, cell in ipairs(cells) do
		local part = cell.part
		cell.x = PlotGrid.NormalizeInteger(part:GetAttribute(PlotGrid.Attributes.X)) or 0
		cell.z = PlotGrid.NormalizeInteger(part:GetAttribute(PlotGrid.Attributes.Z)) or 0
		cell.price = PlotGrid.NormalizeNonNegativeNumber(part:GetAttribute(PlotGrid.Attributes.UnlockPrice)) or 0
		cell.coordKey = PlotGrid.CoordKey(cell.x, cell.z)
		cell.neighbors = {}
		cell.fences = {}
		cell.corners = {}
		cell.vacantGrid = part:FindFirstChild("VacantGrid")

		for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
			cell.fences[sideNumber] = part:FindFirstChild("Fence" .. tostring(sideNumber))
		end
		for _, child in ipairs(part:GetChildren()) do
			local a, b = PlotGrid.CornerSidesFromName(child.Name)
			if a and b then
				cell.corners[PlotGrid.CornerNameForSides(a, b)] = child
			end
		end

		if floor then
			cell.minX, cell.maxX, cell.minZ, cell.maxZ = floorLocalBoundsForPart(floor, part)
		end

		index.cellsByCoord[cell.coordKey] = cell
		index.cellsByPart[part] = cell
		if cell.starter then
			index.starterKeys[#index.starterKeys + 1] = cell.coordKey
		else
			index.unlockableCells[#index.unlockableCells + 1] = cell
		end
	end

	for _, cell in ipairs(cells) do
		for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
			local side = PlotGrid.SideByNumber[sideNumber]
			cell.neighbors[sideNumber] = index.cellsByCoord[PlotGrid.CoordKey(cell.x + side.dx, cell.z + side.dz)]
		end
	end

	indexesByPlot[plot] = index
	return index
end

local function stateForPlot(plot)
	local state = statesByPlot[plot]
	if state then return state end

	local index = PlotGridService.BuildIndex(plot)
	if not index then return nil end

	local unlockedKeys = {}
	for _, key in ipairs(index.starterKeys) do
		unlockedKeys[key] = true
	end
	state = {
		index = index,
		unlockedKeys = unlockedKeys,
	}
	statesByPlot[plot] = state
	return state
end

local function cellVisibleEdges(index, unlockedKeys)
	local edgesByCell = {}
	local frontierByCell = {}

	for _, cell in ipairs(index.cells) do
		local cellUnlocked = isUnlocked(unlockedKeys, cell)
		local edges = {}
		local frontier = false
		for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
			local neighbor = cell.neighbors[sideNumber]
			local oppositeSideNumber = PlotGrid.SideByNumber[sideNumber].opposite
			local neighborHasFence = neighbor ~= nil and neighbor.fences[oppositeSideNumber] ~= nil
			local neighborUnlocked = isUnlocked(unlockedKeys, neighbor)
			local visible = false
			if cellUnlocked and cell.fences[sideNumber] then
				visible = neighbor == nil or not neighborUnlocked
			elseif not cellUnlocked and neighborUnlocked then
				frontier = true
				visible = not neighborHasFence
			end
			if cell.starter and sideNumber == 4 then
				visible = false
			end
			edges[sideNumber] = visible
		end
		edgesByCell[cell] = edges
		frontierByCell[cell] = frontier
	end

	return edgesByCell, frontierByCell
end

local function cornerVisible(cell, sideA, sideB, edgesByCell)
	local edges = edgesByCell[cell]
	if not edges then return false end
	return edges[sideA] == true or edges[sideB] == true
end

local function applyCellVisibility(index, unlockedKeys)
	local edgesByCell, frontierByCell = cellVisibleEdges(index, unlockedKeys)

	for _, cell in ipairs(index.cells) do
		local part = cell.part
		local unlocked = isUnlocked(unlockedKeys, cell)
		local frontier = frontierByCell[cell] == true
		local purchasable = cell.unlockable and not unlocked and frontier and cell.price > 0

		part:SetAttribute(State.Grid.Unlocked, unlocked)
		part:SetAttribute(State.Grid.Frontier, frontier)
		part:SetAttribute(State.Grid.Purchasable, purchasable)
		part:SetAttribute(State.Grid.Visible, unlocked or frontier)
		part:SetAttribute(State.Grid.Price, cell.price)

		setBasePartActive(part, unlocked)
		if cell.vacantGrid then
			setInstanceTreeActive(cell.vacantGrid, frontier and not unlocked)
		end

		local edges = edgesByCell[cell]
		for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
			local fence = cell.fences[sideNumber]
			if fence then
				setInstanceTreeActive(fence, edges[sideNumber] == true)
			end
		end

		for cornerName, corner in pairs(cell.corners) do
			local sideA, sideB = PlotGrid.CornerSidesFromName(cornerName)
			setInstanceTreeActive(corner, sideA ~= nil and cornerVisible(cell, sideA, sideB, edgesByCell))
		end
	end
end

local function profileUnlockSet(index, profile)
	local unlockedKeys = {}
	for _, key in ipairs(index.starterKeys) do
		unlockedKeys[key] = true
	end

	local savedKeys = PlotGrid.SanitizeUnlockedKeys(profile and profile.Data and profile.Data.UnlockedGridKeys)
	if #savedKeys == 0 then
		savedKeys = PlotGrid.SanitizeUnlockedKeys(profile and profile.Data and profile.Data.UnlockedGridIds)
	end
	for _, key in ipairs(savedKeys) do
		if index.cellsByCoord[key] and not index.cellsByCoord[key].starter then
			unlockedKeys[key] = true
		end
	end

	-- Legacy migration only: old profiles may still have PlotSize, but the live
	-- expansion system is now coordinate-keyed unlocked grid cells.
	if #savedKeys == 0 and profile and profile.Data then
		local legacyCount = PlotGrid.LegacyExtraUnlockCount(profile.Data.PlotSize)
		if legacyCount > 0 then
			for indexNumber, cell in ipairs(sortedUnlockableCells(index)) do
				if indexNumber > legacyCount then break end
				unlockedKeys[cell.coordKey] = true
			end
		end
	end

	return unlockedKeys
end

local function saveUnlockSetToProfile(index, profile, unlockedKeys)
	if not profile or not profile.Data then return end
	local keys = {}
	for _, cell in ipairs(sortedUnlockableCells(index)) do
		if unlockedKeys[cell.coordKey] == true then
			keys[#keys + 1] = cell.coordKey
		end
	end
	profile.Data.UnlockedGridKeys = keys
	profile.Data.UnlockedGridIds = nil
end

function PlotGridService.ApplyProfileState(plot, profile)
	indexesByPlot[plot] = nil
	local index = PlotGridService.BuildIndex(plot)
	if not index then return false, "no-index" end

	local unlockedKeys = profileUnlockSet(index, profile)
	statesByPlot[plot] = {
		index = index,
		unlockedKeys = unlockedKeys,
	}
	saveUnlockSetToProfile(index, profile, unlockedKeys)
	applyCellVisibility(index, unlockedKeys)
	return true
end

function PlotGridService.ResetPlotState(plot)
	indexesByPlot[plot] = nil
	local index = PlotGridService.BuildIndex(plot)
	if not index then return false, "no-index" end

	local unlockedKeys = {}
	for _, key in ipairs(index.starterKeys) do
		unlockedKeys[key] = true
	end
	statesByPlot[plot] = {
		index = index,
		unlockedKeys = unlockedKeys,
	}
	applyCellVisibility(index, unlockedKeys)
	return true
end

function PlotGridService.ResetVacantPlotsToStarter(plots, plotOwners)
	if not plots then
		plots = {}
		local plotsFolder = Workspace:FindFirstChild("Plots")
		if plotsFolder then
			for _, plot in ipairs(plotsFolder:GetChildren()) do
				if plot:IsA("Model") then
					plots[#plots + 1] = plot
				end
			end
		else
			for _, instance in ipairs(Workspace:GetChildren()) do
				if instance:IsA("Model") and instance.Name:match("^Plot%d+$") then
					plots[#plots + 1] = instance
				end
			end
		end
	end
	for indexNumber, plot in ipairs(plots or {}) do
		if not plotOwners or not plotOwners[indexNumber] then
			PlotGridService.ResetPlotState(plot)
		end
	end
end

function PlotGridService.ResolveGridPart(target)
	return PlotGrid.GridPartFromInstance(target)
end

function PlotGridService.TryPurchaseCell(player, plot, profile, target)
	local state = stateForPlot(plot)
	if not state or not profile then return false, "no-profile" end

	local gridPart = PlotGridService.ResolveGridPart(target)
	local cell = gridPart and state.index.cellsByPart[gridPart] or nil
	if not cell or not cell.unlockable then return false, "invalid-target" end
	if not isPlayerNear(player, target or gridPart, DEFAULT_PURCHASE_DISTANCE) then return false, "too-far" end
	if isUnlocked(state.unlockedKeys, cell) then return false, "already-unlocked" end

	local _, frontierByCell = cellVisibleEdges(state.index, state.unlockedKeys)
	if frontierByCell[cell] ~= true then return false, "not-frontier" end
	if cell.price <= 0 then return false, "no-price" end

	local spent, spendCode, currency = CurrencyService.TrySpend(player, profile, cell.price)
	if not spent then
		return false, spendCode, currency
	end

	state.unlockedKeys[cell.coordKey] = true
	saveUnlockSetToProfile(state.index, profile, state.unlockedKeys)
	applyCellVisibility(state.index, state.unlockedKeys)
	return true, nil, cell.coordKey, cell.price
end

function PlotGridService.IsWalkablePoint(plot, lx, lz)
	return PlotGridService.IsWalkableFootprint(plot, lx, lz, 0, 0)
end

function PlotGridService.IsWalkableFootprint(plot, lx, lz, paddingX, paddingZ)
	local state = stateForPlot(plot)
	if not state then return false end

	paddingX = math.max(tonumber(paddingX) or 0, 0)
	paddingZ = math.max(tonumber(paddingZ) or 0, 0)
	local samples = {
		{ dx = 0, dz = 0 },
		{ dx = -paddingX, dz = -paddingZ },
		{ dx = -paddingX, dz = 0 },
		{ dx = -paddingX, dz = paddingZ },
		{ dx = 0, dz = -paddingZ },
		{ dx = 0, dz = paddingZ },
		{ dx = paddingX, dz = -paddingZ },
		{ dx = paddingX, dz = 0 },
		{ dx = paddingX, dz = paddingZ },
	}

	for _, sample in ipairs(samples) do
		local sampleLX = lx + sample.dx
		local sampleLZ = lz + sample.dz
		local sampleWalkable = false
		for _, cell in ipairs(state.index.cells) do
			if isUnlocked(state.unlockedKeys, cell)
				and cell.minX and sampleLX >= cell.minX - POINT_EPSILON and sampleLX <= cell.maxX + POINT_EPSILON
				and sampleLZ >= cell.minZ - POINT_EPSILON and sampleLZ <= cell.maxZ + POINT_EPSILON then
				sampleWalkable = true
				break
			end
		end
		if not sampleWalkable then
			return false
		end
	end

	return true
end

function PlotGridService.GetUnlockedLocalBounds(plot, paddingX, paddingZ)
	local state = stateForPlot(plot)
	if not state then return nil end

	paddingX = tonumber(paddingX) or 0
	paddingZ = tonumber(paddingZ) or 0
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	for _, cell in ipairs(state.index.cells) do
		if isUnlocked(state.unlockedKeys, cell) and cell.minX then
			minX = math.min(minX, cell.minX + paddingX)
			maxX = math.max(maxX, cell.maxX - paddingX)
			minZ = math.min(minZ, cell.minZ + paddingZ)
			maxZ = math.max(maxZ, cell.maxZ - paddingZ)
		end
	end

	if minX == math.huge then return nil end
	return minX, maxX, minZ, maxZ
end

function PlotGridService.NearestUnlockedPoint(plot, lx, lz, paddingX, paddingZ)
	local state = stateForPlot(plot)
	if not state then return lx, lz end
	paddingX = math.max(tonumber(paddingX) or 0, 0)
	paddingZ = math.max(tonumber(paddingZ) or 0, 0)
	if PlotGridService.IsWalkableFootprint(plot, lx, lz, paddingX, paddingZ) then
		return lx, lz
	end

	local bestLX, bestLZ = nil, nil
	local bestDistance = math.huge
	for _, cell in ipairs(state.index.cells) do
		if isUnlocked(state.unlockedKeys, cell)
			and cell.minX and cell.maxX - cell.minX > paddingX * 2
			and cell.maxZ - cell.minZ > paddingZ * 2 then
			local clampedLX = math.clamp(lx, cell.minX + paddingX, cell.maxX - paddingX)
			local clampedLZ = math.clamp(lz, cell.minZ + paddingZ, cell.maxZ - paddingZ)
			local dx = clampedLX - lx
			local dz = clampedLZ - lz
			local distance = dx * dx + dz * dz
			if distance < bestDistance then
				bestDistance = distance
				bestLX = clampedLX
				bestLZ = clampedLZ
			end
		end
	end
	return bestLX or lx, bestLZ or lz
end

function PlotGridService.RandomUnlockedPoint(plot, rng, paddingX, paddingZ)
	local state = stateForPlot(plot)
	if not state then return nil, nil end
	rng = rng or Random.new()
	paddingX = tonumber(paddingX) or 0
	paddingZ = tonumber(paddingZ) or 0

	local candidates = {}
	for _, cell in ipairs(state.index.cells) do
		if isUnlocked(state.unlockedKeys, cell)
			and cell.minX and cell.maxX - cell.minX > paddingX * 2
			and cell.maxZ - cell.minZ > paddingZ * 2 then
			candidates[#candidates + 1] = cell
		end
	end
	if #candidates == 0 then return nil, nil end

	local cell = candidates[rng:NextInteger(1, #candidates)]
	return rng:NextNumber(cell.minX + paddingX, cell.maxX - paddingX),
		rng:NextNumber(cell.minZ + paddingZ, cell.maxZ - paddingZ)
end

function PlotGridService.FirstUnlockedPoint(plot, paddingX, paddingZ)
	local state = stateForPlot(plot)
	if not state then return nil, nil end
	paddingX = math.max(tonumber(paddingX) or 0, 0)
	paddingZ = math.max(tonumber(paddingZ) or 0, 0)

	for _, cell in ipairs(state.index.cells) do
		if isUnlocked(state.unlockedKeys, cell)
			and cell.minX and cell.maxX - cell.minX > paddingX * 2
			and cell.maxZ - cell.minZ > paddingZ * 2 then
			return (cell.minX + cell.maxX) / 2, (cell.minZ + cell.maxZ) / 2
		end
	end
	return nil, nil
end

function PlotGridService.CanPlaceFootprint(plot, boundsCF, boundsSize)
	local floor = floorForPlot(plot)
	if not floor or typeof(boundsCF) ~= "CFrame" or typeof(boundsSize) ~= "Vector3" then
		return false
	end

	local samples = {
		Vector3.new(0, 0, 0),
	}
	local half = Vector3.new(boundsSize.X / 2, 0, boundsSize.Z / 2)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			samples[#samples + 1] = Vector3.new(sx * half.X, 0, sz * half.Z)
		end
	end

	for _, sample in ipairs(samples) do
		local worldPoint = boundsCF:PointToWorldSpace(sample)
		local localPoint = floor.CFrame:PointToObjectSpace(worldPoint)
		if not PlotGridService.IsWalkablePoint(plot, localPoint.X, localPoint.Z) then
			return false
		end
	end
	return true
end

return PlotGridService
