local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local GrowingVisuals = {}

local function findFeedTemplate(feedType)
	if type(feedType) ~= "string" or feedType == "" then
		return nil
	end

	local root = ReplicatedStorage:FindFirstChild("FeedMachines")
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

local function targetPrimarySize(feedType)
	local template = findFeedTemplate(feedType)
	if not template then
		return nil
	end
	if template:IsA("BasePart") then
		return template.Size
	end
	if template:IsA("Model") and template.PrimaryPart then
		return template.PrimaryPart.Size
	end
	return nil
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
	local misc = ReplicatedStorage:FindFirstChild("Misc")
	local sapling = misc and misc:FindFirstChild("Sapling")
	if not (sapling and sapling:IsA("Model")) then
		warn("[GrowingVisuals] Missing ReplicatedStorage.Misc.Sapling Model")
		return nil
	end

	local clone = sapling:Clone()
	local size = targetPrimarySize(feedType)
	if size then
		scaleModelXZ(clone, size)
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
