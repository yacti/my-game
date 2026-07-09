-- Scarecrow FeedMachine implementation for FeedClass=Scarecrow machines.
--
-- A placed scarecrow "jumps" on global server-clock boundaries and shakes
-- every Tree machine within JumpRadius studs of it, dropping ALL ready fruit
-- on each tree (TreeClicker.TriggerWindWave) — a placed, always-on mini
-- version of PlotWindService's Windy waves, scoped to its own plot.
--
-- Jumps are phase-locked to Workspace:GetServerTimeNow() % JumpSeconds so
-- every scarecrow with the same interval jumps at the same moment on every
-- plot and every client. The jump animation is pure client presentation
-- derived from the same synced clock (see client ScarecrowJumpEffects);
-- the server never moves the model and no remote is fired. The shake wave
-- fires ScarecrowBalance.JumpDuration after each boundary, when the
-- client-rendered hop lands.
--
-- No stacking: a tree remembers when ANY scarecrow last shook it and a
-- scarecrow only re-shakes a tree once its own interval has elapsed since
-- then, so overlapping radii extend coverage but never multiply income.
-- Only successful shakes mark the tree — a fruitless tree stays eligible.
--
-- No offline progress by design: fruit ready-state is capped by tree slots,
-- so an offline scarecrow would only move fruit into unclaimed ground piles.
--
-- Tunable attributes on the template:
--   JumpSeconds (number, default 10; seconds between jumps, min 1)
--   JumpRadius  (number, default 35; tree-shake radius in studs)

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local Server = script.Parent.Parent
local TreeClicker = require(script.Parent:WaitForChild("Trees"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ScarecrowBalance = require(Shared:WaitForChild("ScarecrowBalance"))
local State  = require(Shared:WaitForChild("State"))

local DEFAULT_JUMP_SECONDS = 10
local DEFAULT_JUMP_RADIUS  = 35
local MIN_JUMP_SECONDS     = 1

-- Sync makes every scarecrow come due on the same frame; budgets spread the
-- burst over following heartbeats (past-due jumps carry over) so one boundary
-- never spikes a frame. A couple frames of delay is invisible.
local MAX_JUMPS_PER_HEARTBEAT       = 4
local MAX_TREE_SHAKES_PER_HEARTBEAT = 25
-- Tolerates the small processing drift budgets introduce so the no-stack gate
-- doesn't skip a tree that is due "in spirit".
local GATE_EPSILON = 0.5
-- Player-to-tree distance for the nearby-only TreeClickerEffect fan-out,
-- matching player clicks and PlotWindService waves.
local EFFECT_RADIUS = 35
-- TriggerWindWave clamps the requested amount to the tree's ready slots.
local ALL_READY_FRUIT = 1e9
-- Shake when the client-rendered hop lands, not at takeoff: tick boundaries
-- are computed on a clock shifted back by the jump animation duration.
local LANDING_DELAY = ScarecrowBalance.JumpDuration

local Scarecrow = {}

-- One record per active scarecrow; no per-instance connections.
local actives = {}
-- Last successful scarecrow shake per tree, shared across all scarecrows.
-- Weak keys so destroyed trees self-clean.
local lastTreeShakeAt = setmetatable({}, { __mode = "k" })

local heartbeatConnection = nil

-- PlotService requires feedMachines/init which requires this module, so the
-- reference must resolve lazily after both finish loading.
local PlotService = nil
local function plotService()
	if not PlotService then
		PlotService = require(Server:WaitForChild("PlotService"))
	end
	return PlotService
end

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function treesInRadius(record)
	local version = plotService().GetNavigationObstacleVersion(record.plot)
	if record.trees and record.treeCacheVersion == version then
		return record.trees
	end
	local origin = record.primary.Position
	local trees = {}
	for _, feed in ipairs(plotService().GetSortedFeeds(record.plot)) do
		if feed:IsA("Model") and feed:GetAttribute(State.Feed.Class) == "Tree" then
			local primary = feed.PrimaryPart
			if primary and (primary.Position - origin).Magnitude <= record.jumpRadius then
				trees[#trees + 1] = feed
			end
		end
	end
	record.trees = trees
	record.treeCacheVersion = version
	return trees
end

local function processJump(record, now, shakeBudget)
	local shakes = 0
	for _, tree in ipairs(treesInRadius(record)) do
		if shakes >= shakeBudget then
			break
		end
		if tree.Parent then
			local last = lastTreeShakeAt[tree]
			if not last or (now - last) >= (record.jumpSeconds - GATE_EPSILON) then
				shakes += 1
				local ok, dropped = RuntimeGuard.Run("Scarecrow.Shake",
					TreeClicker.TriggerWindWave, tree, record.owner, ALL_READY_FRUIT, {
						effectRadius = EFFECT_RADIUS,
						includeTriggeringPlayer = false,
					})
				if ok and dropped then
					lastTreeShakeAt[tree] = now
				end
			end
		end
	end
	return shakes
end

local function onHeartbeat()
	local now = serverNow()
	local jumps, shakes = 0, 0
	for machine, record in pairs(actives) do
		if jumps >= MAX_JUMPS_PER_HEARTBEAT or shakes >= MAX_TREE_SHAKES_PER_HEARTBEAT then
			break
		end
		if not machine.Parent or not record.primary.Parent then
			continue -- Destroying teardown is imminent
		end
		local boundary = math.floor((now - LANDING_DELAY) / record.jumpSeconds)
		if boundary > record.lastTick then
			jumps += 1
			record.lastTick = boundary
			local owner = record.owner
			if owner.Parent == Players and owner:GetAttribute("EditMode") ~= true then
				shakes += processJump(record, now, MAX_TREE_SHAKES_PER_HEARTBEAT - shakes)
			end
		end
	end
end

local function stopHeartbeatIfIdle()
	if heartbeatConnection and next(actives) == nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

local function ensureHeartbeat()
	if heartbeatConnection then return end
	heartbeatConnection = RuntimeGuard.Connect(RunService.Heartbeat, "Scarecrow.Heartbeat", onHeartbeat)
end

local function numberAttribute(machine, name, fallback)
	local value = tonumber(machine:GetAttribute(name))
	if value == nil or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	return value
end

function Scarecrow.Setup(machine, plot, owner)
	if not (machine:IsA("Model") and machine.PrimaryPart) then
		warn(string.format("[Scarecrow] %s must be a Model with a PrimaryPart", machine:GetFullName()))
		return
	end
	local jumpSeconds = math.max(
		numberAttribute(machine, State.Feed.JumpSeconds, DEFAULT_JUMP_SECONDS),
		MIN_JUMP_SECONDS
	)
	actives[machine] = {
		plot = plot,
		owner = owner,
		primary = machine.PrimaryPart,
		jumpSeconds = jumpSeconds,
		jumpRadius = math.max(numberAttribute(machine, State.Feed.JumpRadius, DEFAULT_JUMP_RADIUS), 0),
		-- Wait for the next global boundary rather than jumping on placement.
		lastTick = math.floor((serverNow() - LANDING_DELAY) / jumpSeconds),
		trees = nil,
		treeCacheVersion = nil,
	}
	ensureHeartbeat()
end

function Scarecrow.Teardown(machine)
	actives[machine] = nil
	stopHeartbeatIfIdle()
end

return Scarecrow
