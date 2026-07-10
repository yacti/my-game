-- Client-side scarecrow jump animation for FeedClass=Scarecrow machines.
--
-- No remote drives this: jumps are phase-locked to the replicated server
-- clock (Workspace:GetServerTimeNow() % JumpSeconds), the same boundary the
-- server shakes trees on, so every client renders every scarecrow jumping at
-- the same moment without any network traffic. The server never moves the
-- model; this module applies temporary client-side pivots and restores the
-- authored CFrames exactly when each jump window ends (same ownership story
-- as TreeMotionEffects).
--
-- Presentation is plot-scoped via PlotScope and distance-gated per model;
-- one shared RenderStepped connection exists only while any scarecrow is
-- tracked (idle self-disconnect).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ScarecrowBalance = require(Shared:WaitForChild("ScarecrowBalance"))
local State = require(Shared:WaitForChild("State"))

local PlotScope = require(script.Parent:WaitForChild("PlotScope"))

local SCOPE_RANGE = 100 -- studs from plot floor for tracking (matches tree visuals)
local RENDER_DISTANCE = 100 -- studs from camera before a jump is animated

-- Shared with the server, which delays each shake wave by this much so fruit
-- drops on landing.
local JUMP_DURATION = ScarecrowBalance.JumpDuration
local JUMP_HEIGHT = 1.5
local HEAD_AMPLITUDE = 0.7
local HEAD_NOD_RADIANS = math.rad(14) -- pitch swing around the arm axis
local HEAD_PHASE_LAG = 0.6 -- radians behind the body arc
-- After the body lands, the head keeps going: a damped bounce that starts at
-- the flight swing's landing value (sin(pi - lag), value-continuous) and
-- decays to ~1% before the restore, so nothing snaps.
local HEAD_SETTLE_SECONDS = 0.8
local BOUNCE_FREQUENCY = 14 -- rad/s, ~2 visible bounces per settle
local BOUNCE_DAMPING = 5 -- 1/s exponential decay
local LANDING_SWING = math.sin(math.pi - HEAD_PHASE_LAG)
local DEFAULT_JUMP_SECONDS = 10

local ScarecrowJumpEffects = {}

-- [model] = { jumpSeconds, head, active = { basePivot, headBaseOffset } | nil }
local tracked = {}
local renderConnection = nil

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function restore(model, record)
	local active = record.active
	if not active then return end
	record.active = nil
	if not model.Parent then return end
	model:PivotTo(active.basePivot)
	if record.head and record.head.Parent then
		record.head:PivotTo(active.basePivot * active.headBaseOffset)
	end
end

local function untrack(model)
	local record = tracked[model]
	if not record then return end
	restore(model, record)
	tracked[model] = nil
	if next(tracked) == nil and renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

local function updateModel(model, record, now, cameraPosition)
	if not model.Parent then
		tracked[model] = nil
		return
	end
	local phase = now % record.jumpSeconds
	local animationWindow = JUMP_DURATION + record.headSettle

	if phase >= animationWindow then
		if record.active then
			restore(model, record)
		end
		return
	end

	if not record.active then
		-- Join only at takeoff (mid-settle has no captured baseline), and only
		-- when someone can see it; active windows always run to completion so
		-- the base pivots restore even if the player walks away mid-hop.
		if phase >= JUMP_DURATION then
			return
		end
		if cameraPosition and (model:GetPivot().Position - cameraPosition).Magnitude > RENDER_DISTANCE then
			return
		end
		local basePivot = model:GetPivot()
		record.active = {
			basePivot = basePivot,
			headBaseOffset = record.head and basePivot:ToObjectSpace(record.head:GetPivot()) or nil,
		}
	end

	local active = record.active
	local pivot = active.basePivot
	local swing
	if phase < JUMP_DURATION then
		local t = phase / JUMP_DURATION
		pivot += Vector3.new(0, JUMP_HEIGHT * math.sin(math.pi * t), 0)
		-- Reactive bob: trails the body arc. Ramp in from rest so the head
		-- doesn't snap to the lagged value on the first frame.
		swing = math.sin(math.pi * t - HEAD_PHASE_LAG) * math.min(t / 0.25, 1)
	else
		-- Body has landed; the head overshoots and bounces to rest.
		local settleTime = phase - JUMP_DURATION
		swing = LANDING_SWING * math.cos(BOUNCE_FREQUENCY * settleTime) * math.exp(-BOUNCE_DAMPING * settleTime)
	end
	model:PivotTo(pivot)
	if record.head and record.head.Parent and active.headBaseOffset then
		-- The PumpkinHead Model has no PrimaryPart, so its pivot orientation is
		-- the rotated Body union's — offsets must NOT be applied in head-local
		-- space. Lift is world-up; the nod pitches around the scarecrow's arm
		-- axis (model-local Z; the face looks along model-local X).
		local headCF = pivot * active.headBaseOffset
		local nodded = CFrame.fromAxisAngle(pivot.ZVector, HEAD_NOD_RADIANS * swing) * headCF.Rotation
			+ headCF.Position
			+ Vector3.new(0, HEAD_AMPLITUDE * swing, 0)
		record.head:PivotTo(nodded)
	end
end

local function onRenderStep()
	-- Hold still while the player is editing their plot: a hopping model is
	-- hard to select and drag. The server skips shake waves in edit mode too.
	if player:GetAttribute("EditMode") == true then
		for model, record in pairs(tracked) do
			restore(model, record)
		end
		return
	end
	local now = serverNow()
	local camera = Workspace.CurrentCamera
	local cameraPosition = camera and camera.CFrame.Position or nil
	for model, record in pairs(tracked) do
		updateModel(model, record, now, cameraPosition)
	end
end

local function ensureRenderConnection()
	if renderConnection then return end
	renderConnection = RuntimeGuard.Connect(RunService.RenderStepped, "ScarecrowJumpEffects.Render", onRenderStep)
end

local function numberAttribute(instance, name, fallback)
	local value = tonumber(instance:GetAttribute(name))
	if value == nil or value ~= value or math.abs(value) == math.huge then
		return fallback
	end
	return value
end

local function track(model)
	if tracked[model] then return end
	if not model:IsA("Model") then return end
	if model:GetAttribute(State.Feed.Class) ~= "Scarecrow" then return end
	local jumpSeconds = math.max(numberAttribute(model, State.Feed.JumpSeconds, DEFAULT_JUMP_SECONDS), 1)
	tracked[model] = {
		jumpSeconds = jumpSeconds,
		-- Cap the settle so the animation window always closes before the
		-- next boundary opens.
		headSettle = math.clamp(jumpSeconds - JUMP_DURATION - 0.05, 0, HEAD_SETTLE_SECONDS),
		head = model:FindFirstChild("PumpkinHead") or model:FindFirstChild("PumpkinHead", true),
		active = nil,
	}
	ensureRenderConnection()
end

local function bindPlot(plot)
	local models = {}
	for _, child in ipairs(plot:GetChildren()) do
		track(child)
		if tracked[child] then
			models[child] = true
		end
	end
	local addedConn = RuntimeGuard.Connect(plot.ChildAdded, "ScarecrowJumpEffects.ChildAdded", function(child)
		track(child)
		if tracked[child] then
			models[child] = true
		end
	end)
	local removedConn = RuntimeGuard.Connect(plot.ChildRemoved, "ScarecrowJumpEffects.ChildRemoved", function(child)
		if models[child] then
			models[child] = nil
			untrack(child)
		end
	end)
	return function()
		if addedConn then addedConn:Disconnect() end
		if removedConn then removedConn:Disconnect() end
		for model in pairs(models) do
			untrack(model)
		end
	end
end

function ScarecrowJumpEffects.start()
	PlotScope.Bind({
		label = "ScarecrowJumpEffects",
		nearbyRange = SCOPE_RANGE,
		onPlotAdded = bindPlot,
	})
end

return ScarecrowJumpEffects
