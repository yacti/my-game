local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Seeds = require(Shared:WaitForChild("Seeds"))
local State = require(Shared:WaitForChild("State"))

local FeedGrowthService = {}

local GROWING_PHASE = "GrowingSeed"
local MATURITY_CHECK_SECONDS = 2

FeedGrowthService.Phase = GROWING_PHASE

local state = {}
local onMatureCallback = nil
local started = false

local function now()
	return os.time()
end

local function seedTemplateFeedType(seedId)
	return Seeds.FeedTypeFor(seedId)
end

local function targetDisplayName(feedType)
	local template = FeedMachines.GetTemplate(feedType)
	return template and template.Name or feedType
end

local function setGrowingAttributes(instance, seedId, feedType, growEndAt)
	instance:SetAttribute(State.Seed.Phase, GROWING_PHASE)
	instance:SetAttribute(State.Seed.Id, seedId)
	instance:SetAttribute(State.Seed.GrowEndAt, growEndAt)
	instance:SetAttribute(State.Seed.TargetDisplayName, targetDisplayName(feedType))
end

local function clearGrowingAttributes(instance)
	instance:SetAttribute(State.Seed.Phase, nil)
	instance:SetAttribute(State.Seed.Id, nil)
	instance:SetAttribute(State.Seed.GrowEndAt, nil)
	instance:SetAttribute(State.Seed.TargetDisplayName, nil)
end

local function register(instance, data)
	state[instance] = data
	instance.Destroying:Connect(function()
		state[instance] = nil
	end)
end

function FeedGrowthService.IsGrowing(instance)
	return instance ~= nil and instance:GetAttribute(State.Seed.Phase) == GROWING_PHASE
end

local function hidePatchFoodMarkers(machine)
	for _, descendant in ipairs(machine:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name == "BaseFood" then
			descendant.Transparency = 1
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
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
	local template = FeedMachines.GetTemplate(feedType)
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

local function applySaplingTreeColors(sapling, feedType)
	local template = FeedMachines.GetTemplate(feedType)
	if not template then
		return
	end

	local sourceLeaf = firstBasePartNamed(template, { "Leaf", "Leaves" })
	if sourceLeaf then
		applyColorToNamedParts(sapling, { "Leaf", "Leaves" }, sourceLeaf.Color)
	end

	local sourceTrunkLight = firstBasePartNamed(template, { "TrunkLight" })
	if sourceTrunkLight then
		applyColorToNamedParts(sapling, { "TrunkLight" }, sourceTrunkLight.Color)
	end
end

local function saplingTemplateFor(feedType)
	local misc = ReplicatedStorage:FindFirstChild("Misc")
	local sapling = misc and misc:FindFirstChild("Sapling")
	if not (sapling and sapling:IsA("Model")) then
		warn("[FeedGrowthService] Missing ReplicatedStorage.Misc.Sapling Model")
		return nil
	end

	local clone = sapling:Clone()
	local size = targetPrimarySize(feedType)
	if size then
		scaleModelXZ(clone, size)
	end
	applySaplingTreeColors(clone, feedType)
	return clone
end

local function alignBottomToFloorTop(plot, instance)
	local floor = PlotService.GetFloor(plot)
	if not floor then
		return
	end

	local boundsCF, boundsSize = instance:GetBoundingBox()
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

local function createGrowingVisual(plot, seedId, feedType, feedIndex, lx, lz, lry)
	local feedClass = FeedMachines.GetClass(feedType)
	local visual
	if feedClass == "Patch" then
		visual = PlotService.PlaceFeedWithIndex(plot, feedType, feedIndex, lx, lz, lry)
		if visual then
			hidePatchFoodMarkers(visual)
		end
	elseif feedClass == "Tree" then
		local sapling = saplingTemplateFor(feedType)
		if sapling then
			visual = PlotService.PlaceFeedWithIndex(plot, feedType, feedIndex, lx, lz, lry, sapling)
			sapling:Destroy()
			if visual then
				alignBottomToFloorTop(plot, visual)
			end
		end
	else
		warn("[FeedGrowthService] Unsupported growing feed class: " .. tostring(feedClass))
	end
	return visual
end

local function placeMature(plot, feedType, feedIndex, lx, lz, lry, owner, shouldSetup)
	local machine = PlotService.PlaceFeedWithIndex(plot, feedType, feedIndex, lx, lz, lry)
	if not machine then
		return nil
	end
	clearGrowingAttributes(machine)
	if shouldSetup ~= false then
		FeedMachines.Setup(machine, plot, owner)
	end
	return machine
end

local function matureInstance(instance)
	local data = state[instance]
	if not data or not instance.Parent then
		return nil
	end

	local plot = data.plot
	local floor = PlotService.GetFloor(plot)
	if not floor then
		return nil
	end

	local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, instance:GetPivot())
	local feedIndex = instance:GetAttribute(State.Feed.Index)
	local feedType = data.feedType
	local owner = data.owner

	state[instance] = nil
	instance:Destroy()

	local mature = placeMature(plot, feedType, feedIndex, lx, lz, lry, owner)
	if mature and onMatureCallback then
		onMatureCallback(owner, plot, mature)
	end
	return mature
end

function FeedGrowthService.PlaceSeed(plot, owner, seedId, lx, lz, lry, feedIndex)
	local feedType = seedTemplateFeedType(seedId)
	local growTime = Seeds.GrowTimeFor(seedId)
	if not feedType or not growTime then
		return nil, "invalid-seed"
	end

	feedIndex = feedIndex or PlotService.NextFeedIndex(plot)
	local plantedAt = now()
	local growEndAt = plantedAt + growTime
	local visual = createGrowingVisual(plot, seedId, feedType, feedIndex, lx, lz, lry)
	if not visual then
		return nil, "place-failed"
	end

	setGrowingAttributes(visual, seedId, feedType, growEndAt)
	register(visual, {
		seedId = seedId,
		feedType = feedType,
		plot = plot,
		owner = owner,
		plantedAt = plantedAt,
		growTime = growTime,
	})
	return visual, "ok"
end

function FeedGrowthService.RestorePlacement(plot, owner, placement, feedIndex)
	if type(placement) ~= "table" or placement.phase ~= GROWING_PHASE then
		return nil, "not-growing"
	end

	local seedId = placement.seedId
	local feedType = seedTemplateFeedType(seedId) or placement.type
	local growTime = tonumber(placement.growTime) or Seeds.GrowTimeFor(seedId)
	local plantedAt = tonumber(placement.plantedAt) or now()
	if type(seedId) ~= "string" or type(feedType) ~= "string" or type(growTime) ~= "number" or growTime <= 0 then
		return nil, "invalid-growing-placement"
	end

	local lx = tonumber(placement.lx) or 0
	local lz = tonumber(placement.lz) or 0
	local lry = tonumber(placement.lry) or 0
	if plantedAt + growTime <= now() then
		return placeMature(plot, feedType, feedIndex, lx, lz, lry, owner, false), "mature"
	end

	local visual = createGrowingVisual(plot, seedId, feedType, feedIndex, lx, lz, lry)
	if not visual then
		return nil, "place-failed"
	end
	setGrowingAttributes(visual, seedId, feedType, plantedAt + growTime)
	register(visual, {
		seedId = seedId,
		feedType = feedType,
		plot = plot,
		owner = owner,
		plantedAt = plantedAt,
		growTime = growTime,
	})
	return visual, "growing"
end

function FeedGrowthService.Serialize(instance)
	if not FeedGrowthService.IsGrowing(instance) then
		return nil
	end

	local data = state[instance]
	local seedId = data and data.seedId or instance:GetAttribute(State.Seed.Id)
	local growEndAt = instance:GetAttribute(State.Seed.GrowEndAt)
	local growTime = data and data.growTime or Seeds.GrowTimeFor(seedId)
	local plantedAt = data and data.plantedAt
	if not plantedAt and type(growEndAt) == "number" and type(growTime) == "number" then
		plantedAt = growEndAt - growTime
	end

	return {
		phase = GROWING_PHASE,
		seedId = seedId,
		plantedAt = plantedAt or now(),
		growTime = growTime or Seeds.GrowTimeFor(seedId) or 1,
	}
end

function FeedGrowthService.Start(config)
	if started then
		return
	end
	started = true
	config = config or {}
	onMatureCallback = config.onMature

	task.spawn(function()
		while true do
			task.wait(MATURITY_CHECK_SECONDS)
			for instance, data in pairs(state) do
				if not instance.Parent then
					state[instance] = nil
				elseif data.plantedAt + data.growTime <= now() then
					matureInstance(instance)
				end
			end
		end
	end)
end

return FeedGrowthService
