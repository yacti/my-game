-- Shared timed-growth FeedMachine implementation.
--
-- Each BaseFood slot in the model grows independently along a chain of
-- food ids, accumulating XP at GrowRate per second. MaxXP attributes on
-- the food templates are *cumulative* milestones — Food1=5, Food2=10,
-- Food3=15, … — so the slot's XP just keeps counting up and the stage
-- advances each time it crosses the next threshold. XP is never reset on
-- evolution; harvest gives a Tool whose XP equals the slot's accumulated
-- value. The slot caps at the terminal stage's final threshold.
--
-- A per-slot ProximityPrompt (E) lets the player harvest at any growth
-- stage; the dispensed Tool's XP equals the slot's accumulated XP for
-- the current stage. Harvesting empties the slot for HARVEST_RESPAWN_DELAY
-- seconds, then it materializes fresh first-stage food and starts growing again.
--
-- Picking the *machine* up via the F prompt (handled in init.server.luau)
-- collects every slot's current food into the player's backpack via
-- Patches.PrePickup, then destroys the machine.
--
-- Tunable attribute on the model:
--   GrowRate (number, default 1)  xp per second per slot
--
-- Per-stage MaxXP is read from each food template's MaxXP attribute.
-- Chain/timing/scale tuning comes from per-feed balance modules.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Food = require(ReplicatedStorage.Shared:WaitForChild("Food"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local PatchBalance = script.Parent:WaitForChild("Patch")
local PumpkinPatchBalance = require(PatchBalance:WaitForChild("PumpkinPatchBalance"))

local Patches = {}

local BALANCES = {
	[PumpkinPatchBalance.FeedType] = PumpkinPatchBalance,
}

-- Offline progress runs at this fraction of the online rate. With the
-- default GrowRate=1 xp/sec, 0.001 means a slot earns ~1 xp per 1000s
-- (~17 min) while the player is away — roughly 14 hours offline to fully
-- evolve a slot. Tunable in one place; not on the machine attribute since
-- it's an economy-wide knob per feed type, not per-instance.

-- Per-stage scale: every freshly-spawned slot food starts at SCALE_MIN
-- and grows linearly to SCALE_MAX as its xp climbs from the previous
-- stage's threshold to the current stage's threshold. Resets each
-- evolution. Only applies to Model templates (Model:ScaleTo).

-- [machine] = {
--   owner, plot, balance, lastTick,
--   slots = { [i] = { stage, xp, anchor, foodPart } },
--   conns = {},
-- }
local state = {}

local function feedTypeOf(machine)
	return machine:GetAttribute(State.Feed.Type) or machine.Name
end

local function balanceFor(machine)
	return BALANCES[feedTypeOf(machine)] or PumpkinPatchBalance
end

local function maxXPFor(balance, stageIndex)
	local foodId = balance.Chain[stageIndex]
	if not foodId then return math.huge end
	local t = Food.GetTemplate(foodId)
	return t and (t:GetAttribute("MaxXP") or 5) or 5
end

local function configureSlotPart(part)
	part.Anchored   = true
	part.CanCollide = false
	part.CanQuery   = false
end

local function slotAlignedCFrame(slot, visual)
	local target = slot.anchor.CFrame
	if visual:IsA("BasePart") then
		return target * CFrame.new(0, visual.Size.Y / 2 - slot.anchor.Size.Y / 2, 0)
	elseif visual:IsA("Model") then
		local pivot = visual:GetPivot()
		local boxCFrame, boxSize = visual:GetBoundingBox()
		local boxCenterLocal = pivot:PointToObjectSpace(boxCFrame.Position)
		local bottomLocalY = boxCenterLocal.Y - boxSize.Y / 2
		local targetBottomLocalY = -slot.anchor.Size.Y / 2
		return target * CFrame.new(0, targetBottomLocalY - bottomLocalY, 0)
	else
		return target
	end
end

local function spawnFoodAtSlot(slot, stageIndex)
	local foodId = slot.balance.Chain[stageIndex]
	local template = Food.GetTemplate(foodId)
	if not template then return nil end
	local clone = template:Clone()
	clone:SetAttribute(State.Food.Id, foodId)
	clone:SetAttribute(State.Food.Type, Food.TypeFor(foodId))
	clone:SetAttribute("XP", slot.xp or 0)
	if clone:IsA("BasePart") then
		configureSlotPart(clone)
		clone.CFrame = slotAlignedCFrame(slot, clone)
	elseif clone:IsA("Model") then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then configureSlotPart(d) end
		end
		clone:PivotTo(slotAlignedCFrame(slot, clone))
	end
	clone.Parent = slot.anchor
	return clone
end

-- Returns the slot's normalized progress (0..1) within its current stage.
-- xp is cumulative, so we lerp between the previous stage's threshold and
-- the current stage's threshold.
local function stageProgress(slot)
	local prev = slot.stage > 1 and maxXPFor(slot.balance, slot.stage - 1) or 0
	local curr = maxXPFor(slot.balance, slot.stage)
	local range = curr - prev
	if range <= 0 then return 1 end
	return math.clamp((slot.xp - prev) / range, 0, 1)
end

local function applySlotScale(slot)
	if not slot.foodPart or not slot.foodPart:IsA("Model") then return end
	local scale = slot.balance.ScaleMin + (slot.balance.ScaleMax - slot.balance.ScaleMin) * stageProgress(slot)
	slot.foodPart:ScaleTo(scale)
end

-- The slot's harvest prompt is enabled when the slot has a food (not in
-- respawn delay) AND the owner is NOT in edit mode. Centralized here so
-- materializeRespawn / harvest / EditMode change all share one rule.
local function refreshSlotPrompt(slot, owner)
	if not slot.prompt then return end
	if owner:GetAttribute("EditMode") == true then
		slot.prompt.Enabled = false
	else
		slot.prompt.Enabled = not slot.respawnAt
	end
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
		slot.foodPart:SetAttribute(State.Food.XP, slot.xp)
		applySlotScale(slot)
	end
end

local function materializeRespawn(slot, owner)
	slot.respawnAt = nil
	slot.stage     = 1
	slot.xp        = 0
	slot.foodPart  = spawnFoodAtSlot(slot, 1)
	applySlotScale(slot)
	refreshSlotPrompt(slot, owner)
end

local function applyGrowth(machine, s, seconds)
	if seconds <= 0 then return end
	local growRate = machine:GetAttribute("GrowRate") or s.balance.DefaultGrowRate
	local now      = os.time()
	for _, slot in ipairs(s.slots) do
		if slot.respawnAt then
			-- Slot is empty post-harvest. Materialize chain[1] once the
			-- delay has elapsed; growth starts on the next tick.
			if now >= slot.respawnAt then materializeRespawn(slot, s.owner) end
		else
			-- Terminal stage still ticks xp toward its own cap (e.g. Food10
			-- climbs from 45 to 50), so keep growing regardless of stage.
			slot.xp += seconds * growRate
			-- Cumulative thresholds: advance while xp has crossed the
			-- current stage's MaxXP. Don't subtract — xp is the running
			-- total across stages.
			while slot.stage < #s.balance.Chain and slot.xp >= maxXPFor(s.balance, slot.stage) do
				setSlotStage(slot, slot.stage + 1, slot.xp)
			end
			if slot.stage == #s.balance.Chain then
				local cap = maxXPFor(s.balance, slot.stage)
				if slot.xp > cap then slot.xp = cap end
			end
			refreshSlotXP(slot)
		end
	end
end

-- Single shared heartbeat across all patch-style machines (1Hz tick).
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
	local scale = slot.balance.ScaleMin + (slot.balance.ScaleMax - slot.balance.ScaleMin) * stageProgress(slot)
	tool:ScaleTo(scale)
end

local function harvest(machine, s, slotIndex, player)
	if player ~= s.owner then return end
	local slot = s.slots[slotIndex]
	if not slot or slot.respawnAt then return end  -- empty during respawn delay
	local foodId = slot.balance.Chain[slot.stage]
	if not foodId then return end
	local tool = Food.MakeTool(foodId, slot.xp)
	if not tool then return end
	scaleToolToSlot(tool, slot)
	tool.Parent = player.Backpack

	-- Empty the slot, start respawn timer; materializeRespawn restores it.
	if slot.foodPart then slot.foodPart:Destroy() end
	slot.foodPart  = nil
	slot.stage     = 1
	slot.xp        = 0
	slot.respawnAt = os.time() + s.balance.HarvestRespawnDelay
	refreshSlotPrompt(slot, s.owner)
end

-- Anchor the slot at the BaseFood's bottom face so the food clone grows from
-- the same vertical base point regardless of the marker's thickness.
local function makeSlotAnchor(machine, baseFoodPart)
	local anchor = Instance.new("Part")
	anchor.Name         = "SlotAnchor"
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.CanTouch     = false
	anchor.Transparency = 1
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame       = baseFoodPart.CFrame * CFrame.new(0, -baseFoodPart.Size.Y / 2 + anchor.Size.Y / 2, 0)
	anchor.Parent       = machine
	return anchor
end

function Patches.Setup(machine, plot, owner)
	if not machine:IsA("Model") then
		warn(string.format("[%s] expected Model, got %s", balanceFor(machine).WarnPrefix, machine.ClassName))
		return
	end

	local s = { owner = owner, plot = plot, balance = balanceFor(machine), slots = {}, lastTick = os.time(), conns = {} }
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

			local slot = { balance = s.balance, stage = 1, xp = 0, anchor = anchor, foodPart = nil, prompt = prompt, respawnAt = nil }
			slot.foodPart = spawnFoodAtSlot(slot, 1)
			applySlotScale(slot)
			refreshSlotPrompt(slot, owner)
			table.insert(s.slots, slot)

			local idx = #s.slots
			table.insert(s.conns, prompt.Triggered:Connect(function(player)
				harvest(machine, s, idx, player)
			end))
		end
	end

	-- React to edit-mode toggles by refreshing every slot prompt.
	table.insert(s.conns, owner:GetAttributeChangedSignal("EditMode"):Connect(function()
		for _, slot in ipairs(s.slots) do refreshSlotPrompt(slot, owner) end
	end))
end

function Patches.Teardown(machine)
	local s = state[machine]
	if not s then return end
	for _, c in ipairs(s.conns) do c:Disconnect() end
	state[machine] = nil
end

function Patches.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local slots = table.create(#s.slots)
	for _, slot in ipairs(s.slots) do
		slots[#slots+1] = { stage = slot.stage, xp = slot.xp, respawnAt = slot.respawnAt }
	end
	return { slots = slots, lastTick = s.lastTick }
end

function Patches.Apply(machine, placement)
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
			else
				local stage = math.clamp(savedSlot.stage or 1, 1, #s.balance.Chain)
				local xp    = math.max(savedSlot.xp or 0, 0)
				setSlotStage(slot, stage, xp)
				refreshSlotXP(slot)
			end
			refreshSlotPrompt(slot, s.owner)
		end
	end

	local lastTick = tonumber(placement.lastTick) or now
	local elapsed  = now - lastTick
	-- Offline credit runs at OFFLINE_GROW_FRACTION of the online rate.
	-- applyGrowth treats `seconds` as multiplier on growRate, so scaling
	-- here is equivalent to scaling growRate for this single call.
	applyGrowth(machine, s, elapsed * s.balance.OfflineGrowFraction)
	s.lastTick = os.time()
end

-- Hook called by setupFeedPickup before the machine is destroyed. We hand
-- every slot's current food (foodId + accumulated XP) to the player as
-- a Tool, then return true to permit the pickup.
function Patches.PrePickup(machine, player)
	local s = state[machine]
	if not s or s.owner ~= player then return false end
	for _, slot in ipairs(s.slots) do
		-- Slots in the respawn delay are empty; nothing to give back.
		if not slot.respawnAt then
			local foodId = slot.balance.Chain[slot.stage]
			if foodId then
				local tool = Food.MakeTool(foodId, slot.xp)
				if tool then
					scaleToolToSlot(tool, slot)
					tool.Parent = player.Backpack
				end
			end
		end
	end
	return true
end

return Patches
