-- Client-only scale presentation for mature patch slot fruit.
-- Server owns XP and harvest state; this module decides which nearby fruit
-- should spend local work applying the latest visual scale.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PatchGrowth = require(Shared:WaitForChild("PatchGrowth"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local PlotScope = require(script.Parent:WaitForChild("PlotScope"))

local PatchSlotVisuals = {}

local VISUAL_RANGE = 70
local SCOPE_RANGE = 80
local RANGE_CHECK_INTERVAL = 0.2
local MAX_SCALE_UPDATES_PER_STEP = 80

-- Blinking eyes, keyed by FoodId. The part squashes on Y about its own centre
-- and springs back. Purely local: the food model itself is replicated, so
-- every client in range runs this on its own copy and nobody sees a static
-- eye. Timings are rolled per plant per client -- two players will not blink
-- on the same frame, which is invisible in practice and costs no replication.
local BLINK_FOODS = {
	Eyeshroom = {
		partName = "Eye",
		minGapSeconds = 2,
		maxGapSeconds = 8,
		closeSeconds = 0.09,
		openSeconds = 0.13,
		-- Never all the way to zero: meshes render badly at zero scale.
		squash = 0.12,
	},
}

local player = Players.LocalPlayer
local tracked = {} -- [foodModel] = record
local pendingScaleSync = {} -- array of foodModels awaiting a one-shot true-scale apply
local pendingScaleSyncSet = {} -- [foodModel] = true (dedup for pendingScaleSync)
local blinking = {} -- [record] = true while a blink is mid-flight (per-frame work)
local blinkRng = Random.new()

local function isPatchSlotFood(obj)
	if not (obj:IsA("BasePart") or obj:IsA("Model")) then return false end
	if obj:GetAttribute(State.Food.Id) == nil and obj:GetAttribute(State.Food.Type) == nil then return false end
	local anchor = obj.Parent
	if not anchor or anchor.Name ~= "SlotAnchor" then return false end
	local machine = anchor.Parent
	return machine ~= nil and machine:GetAttribute(State.Feed.Class) == "Patch"
end

local function foodPosition(food)
	if food:IsA("BasePart") then return food.Position end
	if food:IsA("Model") then return food:GetPivot().Position end
	return Vector3.zero
end

local function currentScaleFor(food, machine, now)
	-- Slot XP is derived locally from the replicated growth anchor; the
	-- server only re-publishes attributes on harvest/respawn/restore/move.
	return PatchGrowth.ComputeScaleForFood(food, machine, now)
end

local function disconnectAll(record)
	for _, conn in ipairs(record.conns) do
		conn:Disconnect()
	end
	table.clear(record.conns)
end

local function cleanup(food)
	local record = tracked[food]
	if not record then return end
	disconnectAll(record)
	blinking[record] = nil
	tracked[food] = nil
end

---------------------------------------------------------------------------
-- Blinking eyes
---------------------------------------------------------------------------

-- The eye's size is always derived, never accumulated: baseSize is the size at
-- model scale 1, so writing base * modelScale * squash stays correct no matter
-- how many growth ScaleTo passes land mid-blink (ScaleTo multiplies sizes by
-- the same factor this formula does), and the blink always resolves back to
-- exactly the size growth alone would have produced.
local function applyEyeSize(record, squash)
	local eye = record.eye
	if not (eye and eye.part.Parent) then return end
	local scale = record.food:GetScale()
	local base = eye.baseSize
	eye.part.Size = Vector3.new(base.X * scale, base.Y * scale * squash, base.Z * scale)
end

local function scheduleNextBlink(record, now)
	local config = record.eye.config
	record.eye.nextBlinkAt = now + blinkRng:NextNumber(config.minGapSeconds, config.maxGapSeconds)
end

local function bindEye(record, food, now)
	local config = BLINK_FOODS[food:GetAttribute(State.Food.Id)]
	if not config then return end
	local part = food:FindFirstChild(config.partName)
	if not (part and part:IsA("BasePart")) then return end

	local scale = food:GetScale()
	if scale <= 0 then return end
	record.eye = {
		part = part,
		config = config,
		-- Captured before any blink, so it is growth's size, not a squashed one.
		baseSize = part.Size / scale,
		nextBlinkAt = 0,
		startedAt = nil,
	}
	scheduleNextBlink(record, now)
end

-- Runs unthrottled but only over eyes actually mid-blink (a handful at most);
-- the 0.2s scheduling tick is what decides when one starts.
local function stepBlinks(now)
	for record in pairs(blinking) do
		local eye = record.eye
		if not (record.food:IsDescendantOf(Workspace) and eye and eye.part.Parent) then
			blinking[record] = nil
			continue
		end
		local elapsed = now - eye.startedAt
		local config = eye.config
		if elapsed < config.closeSeconds then
			local alpha = elapsed / config.closeSeconds
			applyEyeSize(record, 1 - (1 - config.squash) * alpha)
		elseif elapsed < config.closeSeconds + config.openSeconds then
			local alpha = (elapsed - config.closeSeconds) / config.openSeconds
			applyEyeSize(record, config.squash + (1 - config.squash) * alpha)
		else
			applyEyeSize(record, 1)
			eye.startedAt = nil
			blinking[record] = nil
		end
	end
end

-- Returns true only when a ScaleTo was actually applied so the per-step
-- budget counts real work, not no-op checks.
local function applyScale(record, now)
	local food = record.food
	if not food:IsDescendantOf(Workspace) then
		cleanup(food)
		return false
	end

	local scale = currentScaleFor(food, record.machine, now)
	if record.lastScale and math.abs(record.lastScale - scale) < 0.0001 then
		return false
	end

	food:ScaleTo(scale)
	record.lastScale = scale
	return true
end

local function addConnection(record, conn)
	if conn then
		table.insert(record.conns, conn)
	end
end

local function track(food)
	if tracked[food] or not isPatchSlotFood(food) then return end
	if not food:IsA("Model") then return end

	local machine = food.Parent and food.Parent.Parent
	if not machine then return end

	local record = {
		food = food,
		machine = machine,
		conns = {},
		lastScale = nil,
	}
	tracked[food] = record
	bindEye(record, food, os.clock())

	addConnection(record, RuntimeGuard.Connect(food.AncestryChanged, "PatchSlotVisuals.AncestryChanged", function()
		if not food:IsDescendantOf(Workspace) then
			cleanup(food)
		end
	end))

	-- A replicated machine move stomps locally scaled part layouts; drop the
	-- cached scale so the next pass re-applies against the fresh geometry.
	local anchor = food.Parent
	addConnection(record, RuntimeGuard.Connect(anchor:GetPropertyChangedSignal("CFrame"), "PatchSlotVisuals.AnchorMoved", function()
		record.lastScale = nil
	end))
end

local function scanRoot(root)
	if not root then return end
	for _, obj in ipairs(root:GetDescendants()) do
		if isPatchSlotFood(obj) then
			track(obj)
		end
	end
end

-- One-shot true-scale sync for fruit as it replicates in (initial join
-- snapshot and later stream-ins), at any distance; ongoing growth updates
-- stay range gated. Drained by the heartbeat under the shared budget.
local function queueScaleSync(obj)
	if pendingScaleSyncSet[obj] then return end
	if not (obj:IsA("Model") and isPatchSlotFood(obj)) then return end
	pendingScaleSyncSet[obj] = true
	table.insert(pendingScaleSync, obj)
end

local function drainScaleSyncQueue(now, budget)
	local applied = 0
	while #pendingScaleSync > 0 and applied < budget do
		local food = table.remove(pendingScaleSync)
		pendingScaleSyncSet[food] = nil
		if food:IsDescendantOf(Workspace) then
			local machine = food.Parent and food.Parent.Parent
			if machine then
				local scale = currentScaleFor(food, machine, now)
				food:ScaleTo(scale)
				local record = tracked[food]
				if record then
					record.lastScale = scale
				end
				applied += 1
			end
		end
	end
	return applied
end

-- Per-item RuntimeGuard.Run is hoisted out of this pass; the Heartbeat
-- connection wrapper already guards the whole tick.
local function updateVisibleScales()
	local now = Workspace:GetServerTimeNow()
	local scaled = drainScaleSyncQueue(now, MAX_SCALE_UPDATES_PER_STEP)

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local blinkNow = os.clock()
	for food, record in pairs(tracked) do
		if not food:IsDescendantOf(Workspace) then
			cleanup(food)
		else
			local inRange = (foodPosition(food) - hrp.Position).Magnitude <= VISUAL_RANGE
			-- Blinks are only scheduled for fruit the player can actually see.
			-- 0.2s scheduling granularity is still well under the shortest gap.
			if inRange and record.eye and not record.eye.startedAt and blinkNow >= record.eye.nextBlinkAt then
				record.eye.startedAt = blinkNow
				blinking[record] = true
				scheduleNextBlink(record, blinkNow)
			end
			if inRange and scaled < MAX_SCALE_UPDATES_PER_STEP and applyScale(record, now) then
				scaled += 1
			end
		end
	end
end

function PatchSlotVisuals.start()
	PlotScope.Bind({
		label = "PatchSlotVisuals",
		nearbyRange = SCOPE_RANGE,
		onPlotAdded = function(plot)
			scanRoot(plot)
			local conn = RuntimeGuard.Connect(plot.DescendantAdded, "PatchSlotVisuals.PlotDescendantAdded", function(obj)
				if isPatchSlotFood(obj) then
					track(obj)
				end
			end)
			return function()
				if conn then conn:Disconnect() end
				for food in pairs(tracked) do
					if food:IsDescendantOf(plot) then cleanup(food) end
				end
			end
		end,
	})

	-- True scale on load: fruit replicates in at the server's last published
	-- scale, so sync every fruit once as it appears — initial snapshot and
	-- later stream-ins alike — regardless of distance.
	RuntimeGuard.Spawn("PatchSlotVisuals.InitialScaleSync", function()
		if not game:IsLoaded() then
			game.Loaded:Wait()
		end
		local plots, container = PlotScope.CandidatePlots()
		RuntimeGuard.Connect(container.DescendantAdded, "PatchSlotVisuals.StreamedIn", queueScaleSync)
		for _, plot in ipairs(plots) do
			for _, obj in ipairs(plot:GetDescendants()) do
				queueScaleSync(obj)
			end
		end
	end)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "PatchSlotVisuals.Heartbeat", function(dt)
		-- Blinks need every frame to read smoothly, but only for the few eyes
		-- actually mid-blink; the throttled pass below does the rest.
		if next(blinking) then
			stepBlinks(os.clock())
		end
		elapsed += dt
		if elapsed < RANGE_CHECK_INTERVAL then return end
		elapsed = 0
		updateVisibleScales()
	end)
end

return PatchSlotVisuals
