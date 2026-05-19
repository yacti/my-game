local PlotService = require(script.Parent:WaitForChild("PlotService"))

local CELL_SIZE = 2.5
local CLEARANCE_PADDING = 0.25
local DESTINATION_ATTEMPTS = 24
local MAX_ROUTE_POINTS = 160
local MIN_DESTINATION_DISTANCE = 4
local MAX_CORNER_RADIUS = 1.75
local LINE_SAMPLE_STEP = CELL_SIZE * 0.5

local SQRT_2 = math.sqrt(2)
local DIRECTIONS = {
	{ dx = 1, dz = 0, cost = 1 },
	{ dx = -1, dz = 0, cost = 1 },
	{ dx = 0, dz = 1, cost = 1 },
	{ dx = 0, dz = -1, cost = 1 },
	{ dx = 1, dz = 1, cost = SQRT_2 },
	{ dx = 1, dz = -1, cost = SQRT_2 },
	{ dx = -1, dz = 1, cost = SQRT_2 },
	{ dx = -1, dz = -1, cost = SQRT_2 },
}

local PetNavigation = {}

local function point(lx, lz)
	return { lx = lx, lz = lz }
end

local function distance(a, b)
	local dx = a.lx - b.lx
	local dz = a.lz - b.lz
	return math.sqrt(dx * dx + dz * dz)
end

local function key(ix, iz)
	return tostring(ix) .. ":" .. tostring(iz)
end

local function clamp(value, minValue, maxValue)
	return math.clamp(value, minValue, maxValue)
end

local function buildGrid(plot, floor, pet)
	local minX, maxX, minZ, maxZ = PlotService.PetFloorLocalBounds(floor, pet)
	if minX >= maxX or minZ >= maxZ then
		return nil
	end

	local paddingX, paddingZ = PlotService.PetFootprintPadding(floor, pet)
	paddingX += CLEARANCE_PADDING
	paddingZ += CLEARANCE_PADDING

	local width = maxX - minX
	local depth = maxZ - minZ
	local columns = math.max(1, math.ceil(width / CELL_SIZE))
	local rows = math.max(1, math.ceil(depth / CELL_SIZE))
	local grid = {
		minX = minX,
		maxX = maxX,
		minZ = minZ,
		maxZ = maxZ,
		columns = columns,
		rows = rows,
		blocked = {},
		free = {},
	}

	local obstacles = PlotService.GetNavigationObstacleBounds(plot)
	for ix = 1, columns do
		grid.blocked[ix] = {}
		for iz = 1, rows do
			local center = PetNavigation.CellCenter(grid, ix, iz)
			local blocked = false
			for _, obstacle in ipairs(obstacles) do
				if center.lx >= obstacle.minX - paddingX
					and center.lx <= obstacle.maxX + paddingX
					and center.lz >= obstacle.minZ - paddingZ
					and center.lz <= obstacle.maxZ + paddingZ then
					blocked = true
					break
				end
			end

			grid.blocked[ix][iz] = blocked
			if not blocked then
				grid.free[#grid.free + 1] = { ix = ix, iz = iz }
			end
		end
	end

	return grid
end

function PetNavigation.CellCenter(grid, ix, iz)
	return point(
		clamp(grid.minX + (ix - 0.5) * CELL_SIZE, grid.minX, grid.maxX),
		clamp(grid.minZ + (iz - 0.5) * CELL_SIZE, grid.minZ, grid.maxZ)
	)
end

local function cellForPoint(grid, lx, lz)
	local ix = clamp(math.floor((lx - grid.minX) / CELL_SIZE) + 1, 1, grid.columns)
	local iz = clamp(math.floor((lz - grid.minZ) / CELL_SIZE) + 1, 1, grid.rows)
	return ix, iz
end

local function isBlocked(grid, ix, iz)
	return ix < 1
		or ix > grid.columns
		or iz < 1
		or iz > grid.rows
		or grid.blocked[ix][iz]
end

local function pointIsFree(grid, lx, lz)
	if lx < grid.minX or lx > grid.maxX or lz < grid.minZ or lz > grid.maxZ then
		return false
	end
	local ix, iz = cellForPoint(grid, lx, lz)
	return not isBlocked(grid, ix, iz)
end

local function lineIsClear(grid, fromPoint, toPoint)
	local length = distance(fromPoint, toPoint)
	if length <= 0.001 then
		return pointIsFree(grid, fromPoint.lx, fromPoint.lz)
	end

	local samples = math.max(1, math.ceil(length / LINE_SAMPLE_STEP))
	for index = 0, samples do
		local alpha = index / samples
		local lx = fromPoint.lx + (toPoint.lx - fromPoint.lx) * alpha
		local lz = fromPoint.lz + (toPoint.lz - fromPoint.lz) * alpha
		if not pointIsFree(grid, lx, lz) then
			return false
		end
	end
	return true
end

local function nearestFreeCell(grid, startIX, startIZ)
	if not isBlocked(grid, startIX, startIZ) then
		return startIX, startIZ
	end

	local queue = { { ix = startIX, iz = startIZ } }
	local seen = { [key(startIX, startIZ)] = true }
	local head = 1

	while head <= #queue do
		local current = queue[head]
		head += 1

		for _, direction in ipairs(DIRECTIONS) do
			local nextIX = current.ix + direction.dx
			local nextIZ = current.iz + direction.dz
			local nextKey = key(nextIX, nextIZ)
			if not seen[nextKey]
				and nextIX >= 1
				and nextIX <= grid.columns
				and nextIZ >= 1
				and nextIZ <= grid.rows then
				if not isBlocked(grid, nextIX, nextIZ) then
					return nextIX, nextIZ
				end
				seen[nextKey] = true
				queue[#queue + 1] = { ix = nextIX, iz = nextIZ }
			end
		end
	end

	return nil, nil
end

local function heuristic(aIX, aIZ, bIX, bIZ)
	local dx = math.abs(aIX - bIX)
	local dz = math.abs(aIZ - bIZ)
	local diagonal = math.min(dx, dz)
	local straight = math.max(dx, dz) - diagonal
	return diagonal * SQRT_2 + straight
end

local function reconstructPath(cameFrom, currentKey, cellsByKey)
	local reversed = {}
	while currentKey do
		local cell = cellsByKey[currentKey]
		reversed[#reversed + 1] = cell
		currentKey = cameFrom[currentKey]
	end

	local path = {}
	for index = #reversed, 1, -1 do
		path[#path + 1] = reversed[index]
	end
	return path
end

local function findPath(grid, startIX, startIZ, goalIX, goalIZ)
	if isBlocked(grid, startIX, startIZ) or isBlocked(grid, goalIX, goalIZ) then
		return nil
	end

	local startKey = key(startIX, startIZ)
	local goalKey = key(goalIX, goalIZ)
	local open = { startKey }
	local openSet = { [startKey] = true }
	local cellsByKey = { [startKey] = { ix = startIX, iz = startIZ } }
	local cameFrom = {}
	local gScore = { [startKey] = 0 }
	local fScore = { [startKey] = heuristic(startIX, startIZ, goalIX, goalIZ) }

	while #open > 0 do
		local bestIndex = 1
		local bestKey = open[1]
		local bestScore = fScore[bestKey] or math.huge
		for index = 2, #open do
			local candidateKey = open[index]
			local candidateScore = fScore[candidateKey] or math.huge
			if candidateScore < bestScore then
				bestIndex = index
				bestKey = candidateKey
				bestScore = candidateScore
			end
		end

		table.remove(open, bestIndex)
		openSet[bestKey] = nil
		local current = cellsByKey[bestKey]
		if bestKey == goalKey then
			return reconstructPath(cameFrom, bestKey, cellsByKey)
		end

		for _, direction in ipairs(DIRECTIONS) do
			local nextIX = current.ix + direction.dx
			local nextIZ = current.iz + direction.dz
			if not isBlocked(grid, nextIX, nextIZ) then
				if direction.dx ~= 0 and direction.dz ~= 0 then
					if isBlocked(grid, current.ix + direction.dx, current.iz)
						or isBlocked(grid, current.ix, current.iz + direction.dz) then
						continue
					end
				end

				local nextKey = key(nextIX, nextIZ)
				local tentativeScore = (gScore[bestKey] or math.huge) + direction.cost
				if tentativeScore < (gScore[nextKey] or math.huge) then
					cameFrom[nextKey] = bestKey
					cellsByKey[nextKey] = { ix = nextIX, iz = nextIZ }
					gScore[nextKey] = tentativeScore
					fScore[nextKey] = tentativeScore + heuristic(nextIX, nextIZ, goalIX, goalIZ)
					if not openSet[nextKey] then
						open[#open + 1] = nextKey
						openSet[nextKey] = true
					end
				end
			end
		end
	end

	return nil
end

local function chooseDestination(grid, startPoint, startIX, startIZ, rng)
	if #grid.free == 0 then
		return nil, nil
	end

	local minDistance = math.min(MIN_DESTINATION_DISTANCE, math.max(grid.maxX - grid.minX, grid.maxZ - grid.minZ) * 0.25)
	for _ = 1, DESTINATION_ATTEMPTS do
		local candidate = grid.free[rng:NextInteger(1, #grid.free)]
		local candidatePoint = PetNavigation.CellCenter(grid, candidate.ix, candidate.iz)
		if distance(startPoint, candidatePoint) >= minDistance
			and not (candidate.ix == startIX and candidate.iz == startIZ) then
			return candidate.ix, candidate.iz
		end
	end

	local bestCell = nil
	local bestDistance = -math.huge
	for _, candidate in ipairs(grid.free) do
		local candidatePoint = PetNavigation.CellCenter(grid, candidate.ix, candidate.iz)
		local candidateDistance = distance(startPoint, candidatePoint)
		if candidateDistance > bestDistance then
			bestDistance = candidateDistance
			bestCell = candidate
		end
	end

	return bestCell and bestCell.ix or nil, bestCell and bestCell.iz or nil
end

local function simplifyPath(grid, cellPath)
	if not cellPath or #cellPath == 0 then
		return {}
	end

	local points = {}
	for _, cell in ipairs(cellPath) do
		points[#points + 1] = PetNavigation.CellCenter(grid, cell.ix, cell.iz)
	end

	local simplified = { points[1] }
	local anchorIndex = 1
	while anchorIndex < #points do
		local nextIndex = #points
		while nextIndex > anchorIndex + 1 do
			if lineIsClear(grid, points[anchorIndex], points[nextIndex]) then
				break
			end
			nextIndex -= 1
		end
		simplified[#simplified + 1] = points[nextIndex]
		anchorIndex = nextIndex
	end

	return simplified
end

local function jitterFinalPoint(grid, path, rng)
	if #path < 2 then
		return
	end

	local final = path[#path]
	local previous = path[#path - 1]
	for _ = 1, 6 do
		local jittered = point(
			final.lx + rng:NextNumber(-CELL_SIZE * 0.3, CELL_SIZE * 0.3),
			final.lz + rng:NextNumber(-CELL_SIZE * 0.3, CELL_SIZE * 0.3)
		)
		if pointIsFree(grid, jittered.lx, jittered.lz) and lineIsClear(grid, previous, jittered) then
			path[#path] = jittered
			return
		end
	end
end

local function cornerRadius(grid, previousPoint, cornerPoint, nextPoint)
	local incoming = distance(previousPoint, cornerPoint)
	local outgoing = distance(cornerPoint, nextPoint)
	if incoming <= 0.001 or outgoing <= 0.001 then
		return 0
	end

	local radius = math.min(MAX_CORNER_RADIUS, incoming * 0.35, outgoing * 0.35)
	while radius >= 0.2 do
		local inAlpha = radius / incoming
		local outAlpha = radius / outgoing
		local entry = point(
			cornerPoint.lx + (previousPoint.lx - cornerPoint.lx) * inAlpha,
			cornerPoint.lz + (previousPoint.lz - cornerPoint.lz) * inAlpha
		)
		local exit = point(
			cornerPoint.lx + (nextPoint.lx - cornerPoint.lx) * outAlpha,
			cornerPoint.lz + (nextPoint.lz - cornerPoint.lz) * outAlpha
		)
		if lineIsClear(grid, entry, exit) then
			return radius
		end
		radius *= 0.5
	end

	return 0
end

local function toRoute(grid, path)
	local route = {}
	for index = 2, #path do
		local waypoint = path[index]
		local nextPoint = path[index + 1]
		local radius = 0
		if nextPoint then
			radius = cornerRadius(grid, path[index - 1], waypoint, nextPoint)
		end
		route[#route + 1] = {
			lx = waypoint.lx,
			lz = waypoint.lz,
			nextLX = nextPoint and nextPoint.lx or nil,
			nextLZ = nextPoint and nextPoint.lz or nil,
			cornerRadius = radius,
		}
	end
	return route
end

function PetNavigation.PlanWander(plot, floor, pet, startLX, startLZ, rng)
	local grid = buildGrid(plot, floor, pet)
	if not grid or #grid.free == 0 then
		return nil
	end

	local startIX, startIZ = cellForPoint(grid, startLX, startLZ)
	local recoveredStart = false
	if isBlocked(grid, startIX, startIZ) then
		startIX, startIZ = nearestFreeCell(grid, startIX, startIZ)
		recoveredStart = true
	end
	if not startIX or not startIZ then
		return nil
	end

	local startPoint = PetNavigation.CellCenter(grid, startIX, startIZ)
	local cellPath
	for _ = 1, DESTINATION_ATTEMPTS do
		local goalIX, goalIZ = chooseDestination(grid, startPoint, startIX, startIZ, rng)
		if goalIX and goalIZ then
			local candidatePath = findPath(grid, startIX, startIZ, goalIX, goalIZ)
			if candidatePath and #candidatePath >= 2 and #candidatePath <= MAX_ROUTE_POINTS then
				cellPath = candidatePath
				break
			end
		end
	end
	if not cellPath then
		return nil
	end

	local path = simplifyPath(grid, cellPath)
	if not recoveredStart and pointIsFree(grid, startLX, startLZ) then
		path[1] = point(startLX, startLZ)
	end
	jitterFinalPoint(grid, path, rng)

	return {
		startLX = startPoint.lx,
		startLZ = startPoint.lz,
		recoveredStart = recoveredStart,
		route = toRoute(grid, path),
	}
end

function PetNavigation.LegIsClear(plot, floor, pet, startLX, startLZ, targetLX, targetLZ)
	local grid = buildGrid(plot, floor, pet)
	if not grid then
		return false
	end

	return lineIsClear(grid, point(startLX, startLZ), point(targetLX, targetLZ))
end

return PetNavigation
