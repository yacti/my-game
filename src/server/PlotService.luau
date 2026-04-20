local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Balance = require(ReplicatedStorage.Shared:WaitForChild("Balance"))

local PetTemplates  = ReplicatedStorage:WaitForChild("Pets")
local FeedTemplates = ReplicatedStorage:WaitForChild("FeedMachines")

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

function PlotService.GetSortedFeeds(plot)
	local feeds = {}
	for _, obj in pairs(plot:GetDescendants()) do
		if obj:IsA("BasePart") and obj:GetAttribute("FeedType") and obj:GetAttribute("FeedIndex") then
			table.insert(feeds, obj)
		end
	end
	table.sort(feeds, function(a, b)
		local ta, tb = a:GetAttribute("FeedType"), b:GetAttribute("FeedType")
		if ta ~= tb then return ta < tb end
		return (a:GetAttribute("FeedIndex") or 0) < (b:GetAttribute("FeedIndex") or 0)
	end)
	return feeds
end

-- Pivots a pet Model to (x, baseY + half-height, z) given its current scale.
local function pivotPetTo(model, x, baseY, z)
	local extents = model:GetExtentsSize()
	model:PivotTo(CFrame.new(x, baseY + extents.Y / 2, z))
end

-- Clones a pet Model template, applies scale, positions it on the floor, sets attributes.
-- Returns the clone (not yet parented to the plot).
function PlotService.CreatePet(petType, petIndex, xp, floor, x, z)
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

	local baseY = floor.Position.Y + floor.Size.Y / 2
	pivotPetTo(clone, x, baseY, z)
	return clone
end

-- pets: array of { type, xp, money } (1-indexed)
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
		local rx = floor.Position.X + (math.random() * 2 - 1) * halfX
		local rz = floor.Position.Z + (math.random() * 2 - 1) * halfZ
		local clone = PlotService.CreatePet(petData.type, i, petData.xp or 0, floor, rx, rz)
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
	local pivot = oldPet:GetPivot()
	local x, z = pivot.X, pivot.Z
	oldPet:Destroy()
	local clone = PlotService.CreatePet(newType, petIndex, xp or 0, floor, x, z)
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

	local baseY = floor.Position.Y + floor.Size.Y / 2

	for i, rec in ipairs(placements) do
		local feedType = rec.type or "Feed1"
		local template = FeedTemplates:FindFirstChild(feedType)
		if not template then
			warn("[PlotService] No feed template: " .. feedType)
			continue
		end
		local clone = template:Clone()
		clone:SetAttribute("FeedType",  feedType)
		clone:SetAttribute("FeedIndex", i)
		clone.Anchored = true
		local px = floor.Position.X + (rec.offX or 0)
		local pz = floor.Position.Z + (rec.offZ or 0)
		local py = baseY + clone.Size.Y / 2
		clone.CFrame = CFrame.new(px, py, pz) * CFrame.Angles(0, rec.rotY or 0, 0)
		clone.Parent = plot
	end
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
