local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MailboxConfig = require(Shared:WaitForChild("MailboxConfig"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local MailboxCollisionController = {}

local player = Players.LocalPlayer
local originalCanCollide = setmetatable({}, { __mode = "k" })
local watchedPlots = setmetatable({}, { __mode = "k" })
local watchedContainers = setmetatable({}, { __mode = "k" })
local refreshScheduled = false

local function isPlotCandidate(instance)
	return instance ~= nil
		and (instance:IsA("Model") or instance:IsA("Folder"))
		and instance.Name:match("^Plot%d+$") ~= nil
end

local function plotContainer()
	return Workspace:FindFirstChild("Plots") or Workspace
end

local function mailboxForPlot(plot)
	local signs = plot and plot:FindFirstChild(MailboxConfig.SignsFolderName)
	return signs and signs:FindFirstChild(MailboxConfig.MailboxName) or nil
end

local function applyPartCollision(part, collides)
	if not (part and part:IsA("BasePart")) then
		return
	end
	if collides then
		local original = originalCanCollide[part]
		if original ~= nil then
			part.CanCollide = original
		end
	else
		if originalCanCollide[part] == nil then
			originalCanCollide[part] = part.CanCollide
		end
		part.CanCollide = false
	end
end

local function applyMailboxCollision(mailbox, collides)
	if not mailbox then
		return
	end
	applyPartCollision(mailbox, collides)
	for _, descendant in ipairs(mailbox:GetDescendants()) do
		applyPartCollision(descendant, collides)
	end
end

local function candidatePlots()
	local plots = {}
	local container = plotContainer()
	for _, child in ipairs(container:GetChildren()) do
		if isPlotCandidate(child) then
			plots[#plots + 1] = child
		end
	end
	return plots
end

local function refreshAll()
	local ownedPlot = PlotResolver.ResolveForPlayer(player)
	for _, plot in ipairs(candidatePlots()) do
		applyMailboxCollision(mailboxForPlot(plot), plot == ownedPlot)
	end
end

local function scheduleRefresh()
	if refreshScheduled then
		return
	end
	refreshScheduled = true
	task.defer(function()
		refreshScheduled = false
		RuntimeGuard.Run("MailboxCollisionController.Refresh", refreshAll)
	end)
end

local function watchPlot(plot)
	if not isPlotCandidate(plot) or watchedPlots[plot] then
		return
	end
	watchedPlots[plot] = true
	RuntimeGuard.Connect(plot.DescendantAdded, "MailboxCollisionController.PlotDescendantAdded", function(descendant)
		local mailbox = mailboxForPlot(plot)
		if descendant.Name == MailboxConfig.MailboxName
			or (mailbox and (descendant == mailbox or descendant:IsDescendantOf(mailbox))) then
			scheduleRefresh()
		end
	end)
	RuntimeGuard.Connect(plot.Destroying, "MailboxCollisionController.PlotDestroying", function()
		watchedPlots[plot] = nil
	end)
	scheduleRefresh()
end

local function watchContainer(container)
	if not container or watchedContainers[container] then
		return
	end
	watchedContainers[container] = true
	for _, child in ipairs(container:GetChildren()) do
		watchPlot(child)
	end
	RuntimeGuard.Connect(container.ChildAdded, "MailboxCollisionController.ContainerChildAdded", function(child)
		watchPlot(child)
		if child.Name == "Plots" then
			watchContainer(child)
			for _, plot in ipairs(child:GetChildren()) do
				watchPlot(plot)
			end
		end
		scheduleRefresh()
	end)
	RuntimeGuard.Connect(container.Destroying, "MailboxCollisionController.ContainerDestroying", function()
		watchedContainers[container] = nil
	end)
end

function MailboxCollisionController.start()
	watchContainer(Workspace)
	watchContainer(plotContainer())
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "MailboxCollisionController.AssignedPlotChanged", scheduleRefresh)
	RuntimeGuard.Connect(Workspace.ChildAdded, "MailboxCollisionController.WorkspaceChildAdded", function(child)
		if child.Name == "Plots" then
			watchContainer(child)
			for _, plot in ipairs(child:GetChildren()) do
				watchPlot(plot)
			end
			scheduleRefresh()
		end
	end)
	scheduleRefresh()
end

return MailboxCollisionController
