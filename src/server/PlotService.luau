local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Balance      = require(ReplicatedStorage.Shared:WaitForChild("Balance"))
local FeedMachines = require(script.Parent:WaitForChild("feedMachines"))

local PetTemplates = ReplicatedStorage:WaitForChild("Pets")

local FLOOR_MARGIN = 8

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

local PlotService = {}

function PlotService.GetPlots()
	return plots
end

function PlotService.AssignPlot(player)
	for i, plot in ipairs(plots) do
		if not plotOwners[i] then
			plotOwners[i]       = player
			playerPlots[player] = i
			return plot, i
		end
	end
	return nil, nil
end

function PlotService.GetPlayerPlot(player)
	local i = playerPlots[player]
	return i and plots[i] or nil
end

function PlotService.FreePlot(player)
	local i = playerPlots[player]
	if i then
		plotOwners[i]       = nil
		playerPlots[player] = nil
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
		if (obj:IsA("BasePart") or obj:IsA("Model"))
			and obj:GetAttribute("FeedType")
			and obj:GetAttribute("FeedIndex") then
			table.insert(feeds, obj)
		end
	end
	table.sort(feeds, function(a, b)
		return (a:GetAttribute("FeedIndex") or 0) < (b:GetAttribute("FeedIndex") or 0)
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

-- ── Floor-local placement helpers ─────────────────────────────────────────────
-- All persisted feed/pet positions are stored in the floor's *local* frame
-- (lx, lz on the floor surface, lry as Y rotation in floor space) so they
-- survive Floor rotations and translations. World coordinates are always
-- derived at runtime via floor.CFrame.

-- World CFrame for an object whose feet sit on the floor's top surface,
-- offset by halfHeight along the floor's local up axis, and rotated lry
-- around the floor's local up.
local function localToWorldOnFloorTop(floor, lx, lz, halfHeight, lry)
	local localCF = CFrame.new(lx, floor.Size.Y / 2 + halfHeight, lz)
		* CFrame.Angles(0, lry or 0, 0)
	return floor.CFrame * localCF
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
function PlotService.CreatePet(petType, petIndex, xp, floor, lx, lz, lry)
	local template = PetTemplates:FindFirstChild(petType)
	if not template then
		warn("[PlotService] No pet template: " .. tostring(petType))
		return nil
	end
	if not template.PrimaryPart then
		warn("[PlotService] Pet template missing PrimaryPart: " .. petType)
		return nil
	end

	local clone = template:Clone()
	clone:SetAttribute("PetType",  petType)
	clone:SetAttribute("PetIndex", petIndex)
	-- MoneyRate is on the template; Clone carries it. Ensure present:
	if clone:GetAttribute("MoneyRate") == nil then
		clone:SetAttribute("MoneyRate", Balance.PetLevelFromType(petType))
	end

	local level = Balance.PetLevelFromType(petType)
	local scale = Balance.ScaleForXP(xp or 0, level)
	clone:ScaleTo(scale)

	local extents = clone:GetExtentsSize()
	clone:PivotTo(localToWorldOnFloorTop(floor, lx, lz, extents.Y / 2, lry))
	return clone
end

-- pets: array of { type, xp, money, lx?, lz?, lry? } (1-indexed). Pets without
-- saved positions (legacy saves) get a random floor-local position once;
-- savePetsFromPlot will persist their new lx/lz/lry on the next snapshot.
function PlotService.SpawnPetsForPlot(plot, pets)
	pets = pets or {}
	local floor = plot:FindFirstChild("Floor")
	if not floor then
		warn("[PlotService] " .. plot.Name .. " has no Floor — cannot spawn pets")
		return
	end

	local halfX = floor.Size.X / 2 - FLOOR_MARGIN
	local halfZ = floor.Size.Z / 2 - FLOOR_MARGIN

	for i, petData in ipairs(pets) do
		local lx, lz, lry
		if petData.lx ~= nil and petData.lz ~= nil then
			lx, lz, lry = petData.lx, petData.lz, petData.lry or 0
		else
			lx  = (math.random() * 2 - 1) * halfX
			lz  = (math.random() * 2 - 1) * halfZ
			lry = 0
		end
		local clone = PlotService.CreatePet(petData.type, i, petData.xp or 0, floor, lx, lz, lry)
		if clone then
			clone.Parent = plot
		end
	end
end

-- Replaces a pet Model in place with a new pet type, keeping its plot position.
-- Returns the new Model (already parented), or nil on failure.
function PlotService.ReplacePetAt(plot, oldPet, newType, petIndex, xp)
	local floor = plot:FindFirstChild("Floor")
	if not floor then return nil end
	local lx, lz, lry = worldPivotToFloorLocal(floor, oldPet:GetPivot())
	oldPet:Destroy()
	local clone = PlotService.CreatePet(newType, petIndex, xp or 0, floor, lx, lz, lry)
	if clone then
		clone.Parent = plot
	end
	return clone
end

-- Re-applies scale to a pet based on its current XP (does not move it).
function PlotService.RescalePet(pet, xp)
	local petType = pet:GetAttribute("PetType")
	local level = Balance.PetLevelFromType(petType)
	local scale = Balance.ScaleForXP(xp or 0, level)
	pet:ScaleTo(scale)
end

function PlotService.SpawnFeedsForPlot(plot, placements)
	placements = placements or {}
	local floor = plot:FindFirstChild("Floor")
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
		local template = FeedMachines.GetTemplate(feedType)
		if not template then
			warn("[PlotService] No feed template: " .. feedType)
			continue
		end
		local clone = template:Clone()
		clone:SetAttribute("FeedType",  feedType)
		clone:SetAttribute("FeedIndex", i)

		local height = templateHeight(clone)
		anchorAndPlace(clone, localToWorldOnFloorTop(floor, rec.lx or 0, rec.lz or 0, height / 2, rec.lry or 0))
		clone.Parent = plot
	end
end

-- Spawns a single FeedMachine at floor-local (lx, lz, lry). Returns the
-- new instance (BasePart or Model) with FeedType and FeedIndex set,
-- parented to the plot.
function PlotService.PlaceFeed(plot, feedType, lx, lz, lry)
	local floor = plot:FindFirstChild("Floor")
	if not floor then return nil end

	local template = FeedMachines.GetTemplate(feedType)
	if not template then
		warn("[PlotService] No feed template: " .. tostring(feedType))
		return nil
	end

	local clone = template:Clone()
	clone:SetAttribute("FeedType", feedType)

	local maxIndex = 0
	for _, f in ipairs(PlotService.GetSortedFeeds(plot)) do
		local idx = f:GetAttribute("FeedIndex") or 0
		if idx > maxIndex then maxIndex = idx end
	end
	clone:SetAttribute("FeedIndex", maxIndex + 1)

	local height = templateHeight(clone)
	anchorAndPlace(clone, localToWorldOnFloorTop(floor, lx, lz, height / 2, lry))
	clone.Parent = plot
	return clone
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
