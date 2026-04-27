-- TimedNew FeedMachine (Model template).
--
-- Each BaseFood slot in the model grows independently along a chain of
-- food types, accumulating XP at GrowRate per second. MaxXP attributes on
-- the food templates are *cumulative* milestones — Food1=5, Food2=10,
-- Food3=15, … — so the slot's XP just keeps counting up and the stage
-- advances each time it crosses the next threshold. XP is never reset on
-- evolution; harvest gives a Tool whose XP equals the slot's accumulated
-- value. The slot caps at the terminal stage's threshold (CHAIN[#CHAIN]).
--
-- A per-slot ProximityPrompt (E) lets the player harvest at any growth
-- stage; the dispensed Tool's XP equals the slot's accumulated XP for
-- the current stage. Harvesting empties the slot for HARVEST_RESPAWN_DELAY
-- seconds, then it materializes a fresh CHAIN[1] and starts growing again.
--
-- Picking the *machine* up via the F prompt (handled in init.server.luau)
-- collects every slot's current food into the player's backpack via
-- TimedNew.PrePickup, then destroys the machine.
--
-- Tunable attribute on the model:
--   GrowRate (number, default 1)  xp per second per slot
--
-- Per-stage MaxXP is read from each food template's MaxXP attribute.
-- The chain order is owned by this module (not Balance) so adding new
-- timed variants is a single-file change.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Food = require(ReplicatedStorage.Shared:WaitForChild("Food"))

local TimedNew = {}

local CHAIN = {
	"Food1_Timed", "Food2_Timed", "Food3_Timed", "Food4_Timed", "Food5_Timed",
	"Food6_Timed", "Food7_Timed", "Food8_Timed", "Food9_Timed", "Food10_Timed",
}

local HARVEST_RESPAWN_DELAY = 3  -- seconds; slot is empty before chain[1] reappears

-- Offline progress runs at this fraction of the online rate. With the
-- default GrowRate=1 xp/sec, 0.001 means a slot earns ~1 xp per 1000s
-- (~17 min) while the player is away — roughly 14 hours offline to fully
-- evolve a slot. Tunable in one place; not on the machine attribute since
-- it's an economy-wide knob, not per-instance.
local OFFLINE_GROW_FRACTION = 0.001

-- Per-stage scale: every freshly-spawned slot food starts at SCALE_MIN
-- and grows linearly to SCALE_MAX as its xp climbs from the previous
-- stage's threshold to the current stage's threshold. Resets each
-- evolution. Only applies to Model templates (Model:ScaleTo).
local SCALE_MIN = 0.3
local SCALE_MAX = 1.5

-- [machine] = {
--   owner, plot, lastTick,
--   slots = { [i] = { stage, xp, anchor, foodPart } },
--   conns = {},
-- }
local state = {}

local function maxXPFor(stageIndex)
	local foodType = CHAIN[stageIndex]
	if not foodType then return math.huge end
	local t = Food.GetTemplate(foodType)
	return t and (t:GetAttribute("MaxXP") or 5) or 5
end

local function configureSlotPart(part)
	part.Anchored   = true
	part.CanCollide = false
	part.CanQuery   = false
end

local function spawnFoodAtSlot(slot, stageIndex)
	local foodType = CHAIN[stageIndex]
	local template = Food.GetTemplate(foodType)
	if not template then return nil end
	local clone = template:Clone()
	clone:SetAttribute("FoodType", foodType)
	clone:SetAttribute("XP", slot.xp or 0)
	if clone:IsA("BasePart") then
		configureSlotPart(clone)
		clone.CFrame = slot.anchor.CFrame
	elseif clone:IsA("Model") then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then configureSlotPart(d) end
		end
		clone:PivotTo(slot.anchor.CFrame)
	end
	clone.Parent = slot.anchor
	return clone
end

-- Returns the slot's normalized progress (0..1) within its current stage.
-- xp is cumulative, so we lerp between the previous stage's threshold and
-- the current stage's threshold.
local function stageProgress(slot)
	local prev = slot.stage > 1 and maxXPFor(slot.stage - 1) or 0
	local curr = maxXPFor(slot.stage)
	local range = curr - prev
	if range <= 0 then return 1 end
	return math.clamp((slot.xp - prev) / range, 0, 1)
end

local function applySlotScale(slot)
	if not slot.foodPart or not slot.foodPart:IsA("Model") then return end
	local scale = SCALE_MIN + (SCALE_MAX - SCALE_MIN) * stageProgress(slot)
	slot.foodPart:ScaleTo(scale)
end

local function setSlotStage(slot, stageIndex, xp)
	if slot.foodPart then slot.foodPart:Destroy() end
	slot.stage    = stageIndex
	slot.xp       = xp or 0
	slot.foodPart = spawnFoodAtSlot(slot, stageIndex)
	applySlotScale(slot)
end

local function refreshSlotXP(slot)
	if slot.foodPart then
		slot.foodPart:SetAttribute("XP", slot.xp)
		applySlotScale(slot)
	end
end

local function materializeRespawn(slot)
	slot.respawnAt = nil
	slot.stage     = 1
	slot.xp        = 0
	slot.foodPart  = spawnFoodAtSlot(slot, 1)
	applySlotScale(slot)
	if slot.prompt then slot.prompt.Enabled = true end
end

local function applyGrowth(machine, s, seconds)
	if seconds <= 0 then return end
	local growRate = machine:GetAttribute("GrowRate") or 1
	local now      = os.time()
	for _, slot in ipairs(s.slots) do
		if slot.respawnAt then
			-- Slot is empty post-harvest. Materialize chain[1] once the
			-- delay has elapsed; growth starts on the next tick.
			if now >= slot.respawnAt then materializeRespawn(slot) end
		else
			-- Terminal stage still ticks xp toward its own cap (e.g. Food10
			-- climbs from 45 to 50), so keep growing regardless of stage.
			slot.xp += seconds * growRate
			-- Cumulative thresholds: advance while xp has crossed the
			-- current stage's MaxXP. Don't subtract — xp is the running
			-- total across stages.
			while slot.stage < #CHAIN and slot.xp >= maxXPFor(slot.stage) do
				setSlotStage(slot, slot.stage + 1, slot.xp)
			end
			if slot.stage == #CHAIN then
				local cap = maxXPFor(slot.stage)
				if slot.xp > cap then slot.xp = cap end
			end
			refreshSlotXP(slot)
		end
	end
end

-- Single shared heartbeat across all TimedNew machines (1Hz tick).
task.spawn(function()
	while true do
		task.wait(1)
		for machine, s in pairs(state) do
			if machine.Parent then
				applyGrowth(machine, s, 1)
				s.lastTick = os.time()
			end
		end
	end
end)

local function scaleToolToSlot(tool, slot)
	-- Tool inherits from Model, so :ScaleTo works on the whole Tool —
	-- handle + welded sub-parts scale together.
	local scale = SCALE_MIN + (SCALE_MAX - SCALE_MIN) * stageProgress(slot)
	tool:ScaleTo(scale)
end

local function harvest(machine, s, slotIndex, player)
	if player ~= s.owner then return end
	local slot = s.slots[slotIndex]
	if not slot or slot.respawnAt then return end  -- empty during respawn delay
	local foodType = CHAIN[slot.stage]
	if not foodType then return end
	local tool = Food.MakeTool(foodType, slot.xp)
	if not tool then return end
	scaleToolToSlot(tool, slot)
	tool.Parent = player.Backpack

	-- Empty the slot, start respawn timer; materializeRespawn restores it.
	if slot.foodPart then slot.foodPart:Destroy() end
	slot.foodPart  = nil
	slot.stage     = 1
	slot.xp        = 0
	slot.respawnAt = os.time() + HARVEST_RESPAWN_DELAY
	if slot.prompt then slot.prompt.Enabled = false end
end

-- Anchor the slot at the BaseFood's CFrame so the food clone has a stable
-- parent that survives evolutions and harvests. The anchor is invisible,
-- non-colliding, and untouchable so it doesn't interfere with anything.
local function makeSlotAnchor(machine, baseFoodPart)
	local anchor = Instance.new("Part")
	anchor.Name         = "SlotAnchor"
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.CanTouch     = false
	anchor.Transparency = 1
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame       = baseFoodPart.CFrame
	anchor.Parent       = machine
	return anchor
end

function TimedNew.Setup(machine, plot, owner)
	if not machine:IsA("Model") then
		warn("[TimedNew] expected Model, got " .. machine.ClassName)
		return
	end

	local s = { owner = owner, plot = plot, slots = {}, lastTick = os.time(), conns = {} }
	state[machine] = s

	for _, child in ipairs(machine:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "BaseFood" then
			local anchor = makeSlotAnchor(machine, child)
			child:Destroy()

			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText            = "Harvest"
			prompt.KeyboardKeyCode       = Enum.KeyCode.E
			prompt.HoldDuration          = 0
			prompt.MaxActivationDistance = 10
			-- The anchor is invisible/tiny with CanQuery=false; the food
			-- clone in front of it is also CanQuery=false. Disable the LOS
			-- raycast so the prompt shows reliably regardless of either.
			prompt.RequiresLineOfSight   = false
			prompt.Parent                = anchor

			local slot = { stage = 1, xp = 0, anchor = anchor, foodPart = nil, prompt = prompt, respawnAt = nil }
			slot.foodPart = spawnFoodAtSlot(slot, 1)
			applySlotScale(slot)
			table.insert(s.slots, slot)

			local idx = #s.slots
			table.insert(s.conns, prompt.Triggered:Connect(function(player)
				harvest(machine, s, idx, player)
			end))
		end
	end
end

function TimedNew.Teardown(machine)
	local s = state[machine]
	if not s then return end
	for _, c in ipairs(s.conns) do c:Disconnect() end
	state[machine] = nil
end

function TimedNew.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local slots = table.create(#s.slots)
	for _, slot in ipairs(s.slots) do
		slots[#slots+1] = { stage = slot.stage, xp = slot.xp, respawnAt = slot.respawnAt }
	end
	return { slots = slots, lastTick = s.lastTick }
end

function TimedNew.Apply(machine, placement)
	local s = state[machine]
	if not s then return end
	if type(placement.slots) ~= "table" then return end

	local now = os.time()
	for i, savedSlot in ipairs(placement.slots) do
		local slot = s.slots[i]
		if slot and type(savedSlot) == "table" then
			local respawnAt = tonumber(savedSlot.respawnAt)
			if respawnAt and respawnAt > now then
				-- Still in the post-harvest delay; keep slot empty.
				if slot.foodPart then slot.foodPart:Destroy() end
				slot.foodPart  = nil
				slot.stage     = 1
				slot.xp        = 0
				slot.respawnAt = respawnAt
				if slot.prompt then slot.prompt.Enabled = false end
			else
				local stage = math.clamp(savedSlot.stage or 1, 1, #CHAIN)
				local xp    = math.max(savedSlot.xp or 0, 0)
				setSlotStage(slot, stage, xp)
				refreshSlotXP(slot)
				if slot.prompt then slot.prompt.Enabled = true end
			end
		end
	end

	local lastTick = tonumber(placement.lastTick) or now
	local elapsed  = now - lastTick
	-- Offline credit runs at OFFLINE_GROW_FRACTION of the online rate.
	-- applyGrowth treats `seconds` as multiplier on growRate, so scaling
	-- here is equivalent to scaling growRate for this single call.
	applyGrowth(machine, s, elapsed * OFFLINE_GROW_FRACTION)
	s.lastTick = os.time()
end

-- Hook called by setupFeedPickup before the machine is destroyed. We hand
-- every slot's current food (foodType + accumulated XP) to the player as
-- a Tool, then return true to permit the pickup.
function TimedNew.PrePickup(machine, player)
	local s = state[machine]
	if not s or s.owner ~= player then return false end
	for _, slot in ipairs(s.slots) do
		-- Slots in the respawn delay are empty; nothing to give back.
		if not slot.respawnAt then
			local foodType = CHAIN[slot.stage]
			if foodType then
				local tool = Food.MakeTool(foodType, slot.xp)
				if tool then
					scaleToolToSlot(tool, slot)
					tool.Parent = player.Backpack
				end
			end
		end
	end
	return true
end

return TimedNew
