local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(script.Parent:WaitForChild("Assets"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local GrowingVisuals = {}
local SAPLING_PRIMARY_PART_NAME = "PrimaryPart"

local function findFeedTemplate(feedType)
	if type(feedType) ~= "string" or feedType == "" then
		return nil
	end

	local root = Assets.Find(Assets.Names.FeedMachines)
	if not root then
		return nil
	end

	for _, classFolder in ipairs(root:GetChildren()) do
		if classFolder:IsA("Folder") then
			for _, template in ipairs(classFolder:GetChildren()) do
				if (template:IsA("BasePart") or template:IsA("Model"))
					and template:GetAttribute(State.Feed.Type) == feedType then
					return template
				end
			end
		end
	end
	return nil
end

local function scaleModelXZ(model, targetSize)
	local boundsCF, boundsSize = model:GetBoundingBox()
	if boundsSize.X <= 0 or boundsSize.Z <= 0 then
		return
	end

	local scaleX = targetSize.X / boundsSize.X
	local scaleZ = targetSize.Z / boundsSize.Z
	local pivot = model:GetPivot()

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local localCF = pivot:ToObjectSpace(descendant.CFrame)
			local localPosition = localCF.Position
			local localRotation = localCF - localPosition
			descendant.Size = Vector3.new(
				math.max(descendant.Size.X * scaleX, 0.05),
				descendant.Size.Y,
				math.max(descendant.Size.Z * scaleZ, 0.05)
			)
			descendant.CFrame = pivot
				* CFrame.new(localPosition.X * scaleX, localPosition.Y, localPosition.Z * scaleZ)
				* localRotation
		end
	end
end

local function targetPrimaryInfo(feedType)
	local template = findFeedTemplate(feedType)
	if not template then
		return nil, nil
	end
	if template:IsA("BasePart") then
		return template.Size, CFrame.new()
	end
	if template:IsA("Model") and template.PrimaryPart then
		local primaryOffset = template:GetPivot():ToObjectSpace(template.PrimaryPart.CFrame)
		return template.PrimaryPart.Size, primaryOffset - primaryOffset.Position
	end
	return nil, nil
end

local function visualLocalBounds(model, pivot)
	local boundsCF, boundsSize = model:GetBoundingBox()
	local minX = math.huge
	local maxX = -math.huge
	local minY = math.huge
	local minZ = math.huge
	local maxZ = -math.huge

	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local worldCorner = boundsCF:PointToWorldSpace(Vector3.new(
					boundsSize.X * 0.5 * sx,
					boundsSize.Y * 0.5 * sy,
					boundsSize.Z * 0.5 * sz
				))
				local localCorner = pivot:PointToObjectSpace(worldCorner)
				minX = math.min(minX, localCorner.X)
				maxX = math.max(maxX, localCorner.X)
				minY = math.min(minY, localCorner.Y)
				minZ = math.min(minZ, localCorner.Z)
				maxZ = math.max(maxZ, localCorner.Z)
			end
		end
	end

	if minX == math.huge then
		return nil
	end
	return minX, maxX, minY, minZ, maxZ
end

local function translateVisibleParts(model, worldOffset)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CFrame = descendant.CFrame + worldOffset
		end
	end
end

local function addSaplingPrimaryPart(model, primarySize, primaryRotation)
	if not primarySize then
		return
	end

	local pivot = model:GetPivot()
	local footprintCF = pivot * (primaryRotation or CFrame.new())
	local minX, maxX, minY, minZ, maxZ = visualLocalBounds(model, footprintCF)
	if minX then
		local centerX = (minX + maxX) / 2
		local centerZ = (minZ + maxZ) / 2
		local targetBottomY = -primarySize.Y / 2
		local localOffset = Vector3.new(-centerX, targetBottomY - minY, -centerZ)
		translateVisibleParts(model, footprintCF:VectorToWorldSpace(localOffset))
	end

	local footprint = Instance.new("Part")
	footprint.Name = SAPLING_PRIMARY_PART_NAME
	footprint.Anchored = true
	footprint.CanCollide = false
	footprint.CanQuery = true
	footprint.CanTouch = true
	footprint.CastShadow = false
	footprint.Transparency = 1
	footprint.Size = primarySize
	footprint.CFrame = footprintCF
	footprint.Parent = model
	model.PrimaryPart = footprint
end

local function basePartMatchesName(part, names)
	for _, name in ipairs(names) do
		if part.Name == name then
			return true
		end
	end
	return false
end

local function firstBasePartNamed(root, names)
	if not root then
		return nil
	end
	if root:IsA("BasePart") and basePartMatchesName(root, names) then
		return root
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") and basePartMatchesName(descendant, names) then
			return descendant
		end
	end
	return nil
end

local function applyColorToNamedParts(root, names, color)
	if not root then
		return
	end
	if root:IsA("BasePart") and basePartMatchesName(root, names) then
		root.Color = color
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") and basePartMatchesName(descendant, names) then
			descendant.Color = color
		end
	end
end

function GrowingVisuals.FeedTemplateFor(feedType)
	return findFeedTemplate(feedType)
end

function GrowingVisuals.FeedClassFor(feedType)
	local template = findFeedTemplate(feedType)
	if not template then
		return nil
	end

	local feedClass = template:GetAttribute(State.Feed.Class)
	if type(feedClass) == "string" and feedClass ~= "" then
		return feedClass
	end
	return template.Parent and template.Parent.Name or nil
end

function GrowingVisuals.ApplySaplingTreeColors(sapling, feedType)
	local template = findFeedTemplate(feedType)
	if not template then
		return
	end

	local sourceLeaf = firstBasePartNamed(template, { "Leaf", "Leaves" })
	if sourceLeaf then
		applyColorToNamedParts(sapling, { "Leaf", "Leaves" }, sourceLeaf.Color)
	end

	local sourceTrunk = firstBasePartNamed(template, { "TrunkLight", "Trunk" })
	if sourceTrunk then
		applyColorToNamedParts(sapling, { "TrunkLight", "Trunk" }, sourceTrunk.Color)
	end
end

function GrowingVisuals.BuildTreeSapling(feedType)
	local misc = Assets.Find(Assets.Names.Misc)
	local sapling = misc and misc:FindFirstChild("Sapling")
	if not (sapling and sapling:IsA("Model")) then
		warn("[GrowingVisuals] Missing ReplicatedStorage.Assets.Misc.Sapling Model")
		return nil
	end

	local clone = sapling:Clone()
	clone.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	local size, primaryRotation = targetPrimaryInfo(feedType)
	if size then
		scaleModelXZ(clone, size)
		addSaplingPrimaryPart(clone, size, primaryRotation)
	end
	GrowingVisuals.ApplySaplingTreeColors(clone, feedType)
	return clone
end

function GrowingVisuals.AlignBottomToFloorTop(instance, floor)
	if not (instance and floor and floor:IsA("BasePart")) then
		return
	end

	local boundsCF, boundsSize
	if instance:IsA("Model") then
		boundsCF, boundsSize = instance:GetBoundingBox()
	elseif instance:IsA("BasePart") then
		boundsCF, boundsSize = instance.CFrame, instance.Size
	else
		return
	end

	local minLocalY = math.huge
	for _, xSign in ipairs({ -1, 1 }) do
		for _, ySign in ipairs({ -1, 1 }) do
			for _, zSign in ipairs({ -1, 1 }) do
				local corner = boundsCF:PointToWorldSpace(Vector3.new(
					boundsSize.X * 0.5 * xSign,
					boundsSize.Y * 0.5 * ySign,
					boundsSize.Z * 0.5 * zSign
				))
				local localCorner = floor.CFrame:PointToObjectSpace(corner)
				minLocalY = math.min(minLocalY, localCorner.Y)
			end
		end
	end
	if minLocalY == math.huge then
		return
	end

	local targetLocalY = floor.Size.Y / 2
	local delta = targetLocalY - minLocalY
	instance:PivotTo(instance:GetPivot() + floor.CFrame.UpVector * delta)
end

return GrowingVisuals
