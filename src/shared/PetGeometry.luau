local PetGeometry = {}

local BOX_CORNER_SIGNS = { -1, 1 }

local function finiteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function finiteVector3(value)
	return typeof(value) == "Vector3"
		and finiteNumber(value.X)
		and finiteNumber(value.Y)
		and finiteNumber(value.Z)
end

local function scanPartWorldCorners(part, callback)
	if not (part and part:IsA("BasePart") and finiteVector3(part.Size)) then
		return false
	end

	local halfSize = part.Size * 0.5
	for _, sx in ipairs(BOX_CORNER_SIGNS) do
		for _, sy in ipairs(BOX_CORNER_SIGNS) do
			for _, sz in ipairs(BOX_CORNER_SIGNS) do
				local corner = part.CFrame:PointToWorldSpace(Vector3.new(
					halfSize.X * sx,
					halfSize.Y * sy,
					halfSize.Z * sz
				))
				if finiteVector3(corner) then
					callback(corner)
				end
			end
		end
	end
	return true
end

local function scanInstanceParts(instance, callback)
	local scanned = false
	if instance:IsA("BasePart") then
		return scanPartWorldCorners(instance, callback)
	end
	if not instance:IsA("Model") then
		return false
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			scanned = scanPartWorldCorners(descendant, callback) or scanned
		end
	end
	return scanned
end

function PetGeometry.PartWorldYBounds(part)
	local lowest = math.huge
	local highest = -math.huge

	local scanned = scanPartWorldCorners(part, function(corner)
		lowest = math.min(lowest, corner.Y)
		highest = math.max(highest, corner.Y)
	end)
	if not scanned or lowest == math.huge or highest == -math.huge then
		return nil, nil
	end
	return lowest, highest
end

function PetGeometry.PrimaryPartPromptPosition(model, maxHeight)
	if not (model and model:IsA("Model")) then
		return nil
	end

	local primary = model.PrimaryPart
	if not primary then
		return nil
	end

	local lowestY, highestY = PetGeometry.PartWorldYBounds(primary)
	if not lowestY or not highestY then
		return nil
	end

	local height = math.max(highestY - lowestY, 0)
	local offset = math.min(height, math.max(tonumber(maxHeight) or 0, 0))
	return Vector3.new(primary.Position.X, lowestY + offset, primary.Position.Z)
end

function PetGeometry.WorldBottomCenterPosition(instance)
	if not (instance and (instance:IsA("Model") or instance:IsA("BasePart"))) then
		return nil
	end

	local center
	if instance:IsA("Model") then
		local cframe = instance:GetBoundingBox()
		center = cframe.Position
	else
		center = instance.Position
	end

	local lowestY = math.huge
	local scanned = scanInstanceParts(instance, function(corner)
		lowestY = math.min(lowestY, corner.Y)
	end)
	if not scanned or lowestY == math.huge then
		return nil
	end

	return Vector3.new(center.X, lowestY, center.Z)
end

function PetGeometry.WorldBottomFrontPosition(instance)
	if not (instance and (instance:IsA("Model") or instance:IsA("BasePart"))) then
		return nil
	end

	local cframe, size
	if instance:IsA("Model") then
		cframe, size = instance:GetBoundingBox()
	else
		cframe = instance.CFrame
		size = instance.Size
	end

	local bottomCenter = PetGeometry.WorldBottomCenterPosition(instance)
	if not (bottomCenter and finiteVector3(size)) then
		return nil
	end

	local frontCenter = cframe:PointToWorldSpace(Vector3.new(0, 0, -size.Z * 0.5 + 1))
	if not finiteVector3(frontCenter) then
		return nil
	end

	return Vector3.new(frontCenter.X, bottomCenter.Y, frontCenter.Z)
end

function PetGeometry.PivotFloorOffset(model)
	if not (model and (model:IsA("Model") or model:IsA("BasePart"))) then
		return nil
	end

	local pivot = model:IsA("Model") and model:GetPivot() or model.CFrame
	local lowestLocalY = math.huge
	local scanned = scanInstanceParts(model, function(corner)
		local pivotCorner = pivot:PointToObjectSpace(corner)
		if finiteVector3(pivotCorner) then
			lowestLocalY = math.min(lowestLocalY, pivotCorner.Y)
		end
	end)

	if not scanned or lowestLocalY == math.huge then
		return nil
	end
	return math.max(-lowestLocalY, 0)
end

return PetGeometry
