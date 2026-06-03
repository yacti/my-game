local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GrowingVisuals = require(Shared:WaitForChild("GrowingVisuals"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
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
	RuntimeGuard.Connect(instance.Destroying, "FeedGrowthService.Destroying", function()
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

local function createGrowingVisual(plot, seedId, feedType, feedIndex, lx, lz, lry)
	local feedClass = FeedMachines.GetClass(feedType)
	local visual
	if feedClass == "Patch" then
		visual = PlotService.PlaceFeedWithIndex(plot, feedType, feedIndex, lx, lz, lry)
		if visual then
			hidePatchFoodMarkers(visual)
		end
	elseif feedClass == "Tree" then
		local sapling = GrowingVisuals.BuildTreeSapling(feedType)
		if sapling then
			visual = PlotService.PlaceFeedWithIndex(plot, feedType, feedIndex, lx, lz, lry, sapling)
			sapling:Destroy()
			if visual then
				GrowingVisuals.AlignBottomToFloorTop(visual, PlotService.GetFloor(plot))
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
		local setupOk = FeedMachines.Setup(machine, plot, owner)
		if not setupOk then
			machine:Destroy()
			return nil
		end
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
		RuntimeGuard.Run("FeedGrowthService.OnMature", onMatureCallback, owner, plot, mature)
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

	RuntimeGuard.Spawn("FeedGrowthService.MaturityLoop", function()
		while true do
			task.wait(MATURITY_CHECK_SECONDS)
			for instance, data in pairs(state) do
				RuntimeGuard.Run("FeedGrowthService.MaturityTick", function()
					if not instance.Parent then
						state[instance] = nil
					elseif data.plantedAt + data.growTime <= now() then
						matureInstance(instance)
					end
				end)
			end
		end
	end)
end

return FeedGrowthService
