-- Shared plot-scope registry for plot-local presentation modules.
-- Keeps a per-consumer set of in-scope plots: the player's assigned plot plus,
-- when nearbyRange is given, any plot whose Floor bounds are within that many
-- studs of the character. Rebinds on plot reassignment. Consumers get
-- onPlotAdded(plot) when a plot enters scope and may return a cleanup function
-- that runs when it leaves (reassignment, distance, or removal from Workspace).
--
-- Distance is measured to the closest point on the Floor part's bounds, not the
-- plot center — floors are far larger than the per-item visual ranges, so a
-- center check would drop plots the player is standing next to.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local SCOPE_CHECK_INTERVAL = 0.5
local EXIT_MARGIN = 20

local player = Players.LocalPlayer

local PlotScope = {}

local function isPlotCandidate(instance)
	return (instance:IsA("Model") or instance:IsA("Folder")) and instance.Name:match("^Plot%d+$") ~= nil
end

local function candidatePlots()
	local plots = {}
	local folder = Workspace:FindFirstChild("Plots")
	local container = folder or Workspace
	for _, child in ipairs(container:GetChildren()) do
		if isPlotCandidate(child) then
			table.insert(plots, child)
		end
	end
	return plots
end

local function distanceToPlot(plot, position)
	local floor = plot:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") then
		local localPos = floor.CFrame:PointToObjectSpace(position)
		local half = floor.Size / 2
		local clamped = Vector3.new(
			math.clamp(localPos.X, -half.X, half.X),
			math.clamp(localPos.Y, -half.Y, half.Y),
			math.clamp(localPos.Z, -half.Z, half.Z)
		)
		return (localPos - clamped).Magnitude
	end
	return (plot:GetPivot().Position - position).Magnitude
end

-- opts: { label, nearbyRange?, onPlotAdded }. nearbyRange nil means assigned
-- plot only. onPlotAdded may return a cleanup function.
function PlotScope.Bind(opts)
	local label = opts.label or "PlotScope"
	local nearbyRange = opts.nearbyRange
	local onPlotAdded = opts.onPlotAdded

	local scoped = {} -- [plot] = cleanup function, or true when none returned

	local function addPlot(plot)
		if scoped[plot] then return end
		local ok, cleanupFn = RuntimeGuard.Run(label .. ".PlotAdded", onPlotAdded, plot)
		scoped[plot] = (ok and type(cleanupFn) == "function") and cleanupFn or true
	end

	local function removePlot(plot)
		local cleanupFn = scoped[plot]
		if cleanupFn == nil then return end
		scoped[plot] = nil
		if type(cleanupFn) == "function" then
			RuntimeGuard.Run(label .. ".PlotRemoved", cleanupFn)
		end
	end

	local function refresh()
		local assigned = PlotResolver.ResolveForPlayer(player)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local position = root and root:IsA("BasePart") and root.Position or nil

		local wanted = {}
		if assigned and assigned:IsDescendantOf(Workspace) then
			wanted[assigned] = true
		end
		if nearbyRange then
			if position then
				for _, plot in ipairs(candidatePlots()) do
					if not wanted[plot] then
						-- Hysteresis: already-scoped plots only leave once the
						-- player is EXIT_MARGIN beyond the entry range.
						local limit = scoped[plot] ~= nil and (nearbyRange + EXIT_MARGIN) or nearbyRange
						if distanceToPlot(plot, position) <= limit then
							wanted[plot] = true
						end
					end
				end
			else
				-- No character root (death/teleport): keep the current nearby
				-- set instead of evicting and rebuilding everything on respawn.
				for plot in pairs(scoped) do
					wanted[plot] = true
				end
			end
		end

		for plot in pairs(scoped) do
			if not wanted[plot] or not plot:IsDescendantOf(Workspace) then
				removePlot(plot)
			end
		end
		for plot in pairs(wanted) do
			if plot:IsDescendantOf(Workspace) then
				addPlot(plot)
			end
		end
	end

	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), label .. ".AssignedPlotChanged", refresh)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, label .. ".ScopeHeartbeat", function(dt)
		elapsed += dt
		if elapsed < SCOPE_CHECK_INTERVAL then return end
		elapsed = 0
		refresh()
	end)

	RuntimeGuard.Run(label .. ".InitialScope", refresh)
end

return PlotScope
