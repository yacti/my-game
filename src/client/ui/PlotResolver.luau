local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local State = require(Shared:WaitForChild("State"))

local PlotResolver = {}

local function isPlotCandidate(instance)
	return instance ~= nil
		and (instance:IsA("Model") or instance:IsA("Folder"))
		and instance.Name:match("^Plot%d+$") ~= nil
end

local function uniquePlotNamed(parent, plotName)
	if not parent then
		return nil
	end

	local match = nil
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == plotName and isPlotCandidate(child) then
			if match then
				return nil
			end
			match = child
		end
	end
	return match
end

local function plotFromAssignedName(player)
	local plotName = player:GetAttribute(State.Player.AssignedPlotName)
	if type(plotName) ~= "string" or plotName == "" then
		return nil
	end

	local plotsFolder = Workspace:FindFirstChild("Plots")
	local folderPlot = uniquePlotNamed(plotsFolder, plotName)
	if folderPlot then
		return folderPlot
	end

	if plotsFolder then
		return nil
	end
	return uniquePlotNamed(Workspace, plotName)
end

function PlotResolver.ResolveForPlayer(player)
	local spawnLocation = player and player.RespawnLocation
	local spawnPlot = spawnLocation and spawnLocation.Parent
	if isPlotCandidate(spawnPlot) then
		return spawnPlot
	end

	return player and plotFromAssignedName(player) or nil
end

return PlotResolver
