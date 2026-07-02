-- Client-side presentation for the admin party pad. The server keeps pad
-- emitters replicated-off and drives state through attributes:
--   plot.OwnerUserId        - occupancy (set by PlotService)
--   area.AdminPartyActive   - pad shown (occupied plot + party on)
--   area.AdminPartyEntrance - counter bumped once per party toggle-on
-- This controller plays the 10-stud drop-in for everyone when the entrance
-- counter bumps, and enables the pad's particles only on the local player's
-- own plot. Mid-party plot claims show the pad in place (no entrance).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local AdminPartyPadController = {}

local ADMIN_PARTY_FOLDER_NAME = "AdminParty"
local ADMIN_PARTY_DROP_AREA_NAME = "AdminPartyDropArea"
local ADMIN_PAD_ACTIVE_ATTRIBUTE = "AdminPartyActive"
local ADMIN_PAD_ENTRANCE_ATTRIBUTE = "AdminPartyEntrance"
local PLOT_OWNER_ATTRIBUTE = "OwnerUserId"

local ENTRANCE_DROP_STUDS = 10
local ENTRANCE_SECONDS = 1.2
local PAD_WAIT_SECONDS = 30
local SWEEP_SECONDS = 5

local player = Players.LocalPlayer

local entries = {} -- [plot] = { area, restPivot, connections, dropElapsed? }
local heartbeat = nil

local function anyEntranceActive()
	for _, entry in pairs(entries) do
		if entry.dropElapsed then
			return true
		end
	end
	return false
end

local function stepEntrances(dt)
	for _, entry in pairs(entries) do
		if entry.dropElapsed then
			entry.dropElapsed += dt
			local progress = math.clamp(entry.dropElapsed / ENTRANCE_SECONDS, 0, 1)
			local alpha = TweenService:GetValue(progress, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
			entry.area:PivotTo(entry.restPivot + Vector3.new(0, ENTRANCE_DROP_STUDS * (1 - alpha), 0))
			if progress >= 1 then
				entry.area:PivotTo(entry.restPivot)
				entry.dropElapsed = nil
			end
		end
	end
	if not anyEntranceActive() and heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

local function beginEntrance(entry)
	entry.dropElapsed = 0
	entry.area:PivotTo(entry.restPivot + Vector3.new(0, ENTRANCE_DROP_STUDS, 0))
	if not heartbeat then
		heartbeat = RunService.Heartbeat:Connect(function(dt)
			RuntimeGuard.Run("AdminPartyPadController.Entrance", stepEntrances, dt)
		end)
	end
end

local function applyParticles(entry, plot)
	local enabled = entry.area:GetAttribute(ADMIN_PAD_ACTIVE_ATTRIBUTE) == true
		and plot:GetAttribute(PLOT_OWNER_ATTRIBUTE) == player.UserId
	-- Resolved fresh each apply: cached emitter lists go stale if the pad's
	-- descendants are ever replaced, and the periodic sweep re-runs this to
	-- recover from replication racing the local Enabled writes.
	for _, descendant in ipairs(entry.area:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = enabled
		end
	end
end

local function releaseEntry(plot)
	local entry = entries[plot]
	if not entry then
		return
	end
	entries[plot] = nil
	for _, connection in ipairs(entry.connections) do
		connection:Disconnect()
	end
	if not anyEntranceActive() and heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

local function watchPlot(plot)
	if entries[plot] then
		return
	end
	if not ((plot:IsA("Model") or plot:IsA("Folder")) and plot.Name:match("^Plot%d+$")) then
		return
	end

	local folder = plot:WaitForChild(ADMIN_PARTY_FOLDER_NAME, PAD_WAIT_SECONDS)
	local area = folder and folder:WaitForChild(ADMIN_PARTY_DROP_AREA_NAME, PAD_WAIT_SECONDS)
	if not area or plot.Parent == nil or entries[plot] then
		return
	end

	local entry = {
		area = area,
		restPivot = area:GetPivot(),
		connections = {},
	}
	entries[plot] = entry

	entry.connections[1] = area:GetAttributeChangedSignal(ADMIN_PAD_ENTRANCE_ATTRIBUTE):Connect(function()
		RuntimeGuard.Run("AdminPartyPadController.Begin", beginEntrance, entry)
	end)
	entry.connections[2] = area:GetAttributeChangedSignal(ADMIN_PAD_ACTIVE_ATTRIBUTE):Connect(function()
		RuntimeGuard.Run("AdminPartyPadController.Particles", applyParticles, entry, plot)
	end)
	entry.connections[3] = plot:GetAttributeChangedSignal(PLOT_OWNER_ATTRIBUTE):Connect(function()
		RuntimeGuard.Run("AdminPartyPadController.Particles", applyParticles, entry, plot)
	end)

	applyParticles(entry, plot)
end

local function watchPlotsFolder(folder)
	for _, plot in ipairs(folder:GetChildren()) do
		RuntimeGuard.Spawn("AdminPartyPadController.WatchPlot", watchPlot, plot)
	end
	RuntimeGuard.Connect(folder.ChildAdded, "AdminPartyPadController.PlotAdded", function(plot)
		RuntimeGuard.Spawn("AdminPartyPadController.WatchPlot", watchPlot, plot)
	end)
	RuntimeGuard.Connect(folder.ChildRemoved, "AdminPartyPadController.PlotRemoved", releaseEntry)
end

-- Periodic safety net: converges particle state even when a signal was
-- missed (attribute replicated before connections existed, a server emitter
-- write landing after the local one) and re-watches plots whose pad instance
-- was replaced.
local function sweep()
	while true do
		task.wait(SWEEP_SECONDS)
		for plot, entry in pairs(entries) do
			if entry.area.Parent == nil and plot.Parent ~= nil then
				releaseEntry(plot)
				RuntimeGuard.Spawn("AdminPartyPadController.WatchPlot", watchPlot, plot)
			else
				RuntimeGuard.Run("AdminPartyPadController.SweepParticles", applyParticles, entry, plot)
			end
		end
	end
end

function AdminPartyPadController.start()
	RuntimeGuard.Spawn("AdminPartyPadController.Sweep", sweep)
	local folder = Workspace:FindFirstChild("Plots")
	if folder and folder:IsA("Folder") then
		watchPlotsFolder(folder)
		return
	end
	local connection
	connection = RuntimeGuard.Connect(Workspace.ChildAdded, "AdminPartyPadController.PlotsFolder", function(child)
		if child.Name == "Plots" and child:IsA("Folder") then
			if connection then
				connection:Disconnect()
			end
			watchPlotsFolder(child)
		end
	end)
end

return AdminPartyPadController
