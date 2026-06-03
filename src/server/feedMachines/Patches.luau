-- Shared timed-growth FeedMachine implementation.
--
-- Patch templates produce one exact FoodDrop food id. Each BaseFood slot
-- earns the patch's XP value every GrowRate seconds and harvest grants the
-- accumulated XP on the produced food tool. Harvesting empties the slot for a
-- short respawn delay, then the same food starts accumulating from zero again.
--
-- Tunable attribute on the model:
--   FoodDrop (string, required) exact food id produced by each slot
--   XP       (number, default 1) XP gained per growth interval
--   GrowRate (number, default 1) seconds per growth interval

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Food = require(ReplicatedStorage.Shared:WaitForChild("Food"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local Patches = {}

local DEFAULT_XP = 1
local DEFAULT_GROW_RATE = 1
local HARVEST_RESPAWN_DELAY = 3
local OFFLINE_GROW_FRACTION = 0.001
local SCALE_MIN = 0.3
local SCALE_MAX = 2.75
local SCALE_MAX_BASE_XP_MULTIPLIER = 500
local EDIT_MODE_ATTR = "EditMode"

-- Offline progress runs at this fraction of the online rate. With default
-- XP=1 and GrowRate=1, 0.001 means a slot earns ~1 xp per 1000s (~17 min)
-- while the player is away. Tunable in one place; not on the machine
-- attribute since it's an economy-wide knob for patch machines.

-- Every freshly-spawned slot food starts at SCALE_MIN and grows linearly to
-- SCALE_MAX as its XP climbs from the patch's XP to patchXP * 500. Only
-- applies to Model templates (Model:ScaleTo).

-- [machine] = {
--   owner, plot, foodId, patchXP, lastTick,
--   slots = { [i] = { xp, growthElapsed, anchor, foodPart, respawnAt } },
-- }
local state = {}

local function foodDropFor(machine)
	local foodId = machine:GetAttribute(State.Feed.FoodDrop)
	if type(foodId) ~= "string" or foodId == "" then
		warn(string.format("[Patches] missing %s attribute on %s", State.Feed.FoodDrop, machine:GetFullName()))
		return nil
	end
	if not Food.GetTemplate(foodId) then
		warn(string.format("[Patches] unknown %s %q on %s", State.Feed.FoodDrop, foodId, machine:GetFullName()))
		return nil
	end
	return foodId
end

local function patchXPFor(machine)
	local patchXP = machine:GetAttribute(State.Feed.XP)
	if type(patchXP) ~= "number" or patchXP <= 0 then
		return DEFAULT_XP
	end
	return patchXP
end

local function configureSlotPart(part)
	part.Anchored   = true
	part.CanCollide = false
	part.CanQuery   = false
end

local function spawnFoodAtSlot(slot)
	local foodId = slot.foodId
	local template = Food.GetTemplate(foodId)
	if not template then return nil end
	local clone = template:Clone()
	clone:SetAttribute(State.Food.Id, foodId)
	clone:SetAttribute(State.Food.Type, Food.TypeFor(foodId))
	clone:SetAttribute(State.Food.XP, slot.xp or 0)
	if clone:IsA("BasePart") then
		configureSlotPart(clone)
		clone:PivotTo(slot.anchor.CFrame)
	elseif clone:IsA("Model") then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then configureSlotPart(d) end
		end
		clone:PivotTo(slot.anchor.CFrame)
	end
	clone.Parent = slot.anchor
	return clone
end

local function scaleProgress(slot)
	local minXP = slot.patchXP
	local maxXP = slot.patchXP * SCALE_MAX_BASE_XP_MULTIPLIER
	local range = maxXP - minXP
	if range <= 0 then return 1 end
	return math.clamp((slot.xp - minXP) / range, 0, 1)
end

local function applySlotScale(slot)
	if not slot.foodPart or not slot.foodPart:IsA("Model") then return end
	local scale = SCALE_MIN + (SCALE_MAX - SCALE_MIN) * scaleProgress(slot)
	slot.foodPart:ScaleTo(scale)
end

local function refreshSlotVisual(slot)
	if not slot.foodPart and not slot.respawnAt then
		slot.foodPart = spawnFoodAtSlot(slot)
	end
	if slot.foodPart then
		slot.foodPart:SetAttribute(State.Food.XP, slot.xp)
		applySlotScale(slot)
	end
end

local function refreshAllSlotVisuals(s)
	for _, slot in ipairs(s.slots) do
		refreshSlotVisual(slot)
	end
	s.deferVisualRefresh = false
end

local function materializeRespawn(slot, deferVisualRefresh)
	slot.respawnAt = nil
	slot.xp        = 0
	slot.growthElapsed = 0
	if deferVisualRefresh then return end
	slot.foodPart  = spawnFoodAtSlot(slot)
	applySlotScale(slot)
end

local function applyGrowth(machine, s, seconds)
	if seconds <= 0 then return end
	local growRate = machine:GetAttribute(State.Feed.GrowRate)
	if type(growRate) ~= "number" or growRate <= 0 then
		growRate = DEFAULT_GROW_RATE
	end
	local deferVisualRefresh = s.owner and s.owner:GetAttribute(EDIT_MODE_ATTR) == true
	local xpPerInterval = s.patchXP
	local now      = os.time()
	for _, slot in ipairs(s.slots) do
		if slot.respawnAt then
			-- Slot is empty post-harvest. Materialize food once the
			-- delay has elapsed; growth starts on the next tick.
			if now >= slot.respawnAt then
				materializeRespawn(slot, deferVisualRefresh)
				if deferVisualRefresh then
					s.deferVisualRefresh = true
				end
			end
		else
			slot.growthElapsed = (slot.growthElapsed or 0) + seconds
			local intervals = math.floor(slot.growthElapsed / growRate)
			if intervals > 0 then
				slot.growthElapsed -= intervals * growRate
				slot.xp += intervals * xpPerInterval
				if deferVisualRefresh then
					s.deferVisualRefresh = true
				else
					refreshSlotVisual(slot)
				end
			end
		end
	end
end

-- Single shared heartbeat across all patch-style machines (1Hz tick).
task.spawn(function()
	while true do
		task.wait(1)
		for machine, s in pairs(state) do
			if machine.Parent then
				if s.deferVisualRefresh and not (s.owner and s.owner:GetAttribute(EDIT_MODE_ATTR) == true) then
					refreshAllSlotVisuals(s)
				end
				applyGrowth(machine, s, 1)
				s.lastTick = os.time()
			end
		end
	end
end)

local function scaleToolToSlot(tool, slot)
	-- Tool inherits from Model, so :ScaleTo works on the whole Tool —
	-- handle + welded sub-parts scale together.
	local scale = SCALE_MIN + (SCALE_MAX - SCALE_MIN) * scaleProgress(slot)
	tool:ScaleTo(scale)
end

local function harvest(machine, s, slotIndex, player)
	if player ~= s.owner then return end
	if player:GetAttribute("EditMode") == true then return end
	local slot = s.slots[slotIndex]
	if not slot or slot.respawnAt then return end  -- empty during respawn delay
	local foodId = s.foodId
	if not foodId then return end
	local tool = Food.MakeTool(foodId, slot.xp)
	if not tool then return end
	scaleToolToSlot(tool, slot)
	tool.Parent = player.Backpack

	-- Empty the slot, start respawn timer; materializeRespawn restores it.
	if slot.foodPart then slot.foodPart:Destroy() end
	slot.foodPart  = nil
	slot.xp        = 0
	slot.growthElapsed = 0
	slot.respawnAt = os.time() + HARVEST_RESPAWN_DELAY
end

-- Anchor the slot at the BaseFood's bottom face. Patch food templates are
-- expected to author their pivot at the bottom contact point.
local function makeSlotAnchor(machine, baseFoodPart)
	local anchor = Instance.new("Part")
	anchor.Name         = "SlotAnchor"
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CanQuery     = false
	anchor.CanTouch     = false
	anchor.Transparency = 1
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame       = baseFoodPart.CFrame * CFrame.new(0, -baseFoodPart.Size.Y / 2, 0)
	anchor.Parent       = machine
	return anchor
end

function Patches.Setup(machine, plot, owner)
	if not machine:IsA("Model") then
		warn(string.format("[Patches] expected Model, got %s", machine.ClassName))
		return
	end
	local foodId = foodDropFor(machine)
	if not foodId then
		return
	end

	local s = {
		owner = owner,
		plot = plot,
		foodId = foodId,
		patchXP = patchXPFor(machine),
		slots = {},
		lastTick = os.time(),
		deferVisualRefresh = false,
	}
	state[machine] = s

	if owner then
		s.editModeConn = owner:GetAttributeChangedSignal(EDIT_MODE_ATTR):Connect(function()
			if s.deferVisualRefresh and owner:GetAttribute(EDIT_MODE_ATTR) ~= true then
				refreshAllSlotVisuals(s)
			end
		end)
	end

	for _, child in ipairs(machine:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "BaseFood" then
			local anchor = makeSlotAnchor(machine, child)
			child:Destroy()

			local slot = {
				foodId = s.foodId,
				patchXP = s.patchXP,
				xp = 0,
				growthElapsed = 0,
				anchor = anchor,
				foodPart = nil,
				respawnAt = nil,
			}
			slot.foodPart = spawnFoodAtSlot(slot)
			applySlotScale(slot)
			table.insert(s.slots, slot)
		end
	end
end

function Patches.Teardown(machine)
	local s = state[machine]
	if s and s.editModeConn then
		s.editModeConn:Disconnect()
	end
	state[machine] = nil
end

function Patches.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local slots = table.create(#s.slots)
	for _, slot in ipairs(s.slots) do
		slots[#slots+1] = {
			xp = slot.xp,
			growthElapsed = slot.growthElapsed,
			respawnAt = slot.respawnAt,
		}
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
				slot.xp        = 0
				slot.growthElapsed = 0
				slot.respawnAt = respawnAt
			else
				local xp = math.max(tonumber(savedSlot.xp) or 0, 0)
				slot.respawnAt = nil
				slot.xp = xp
				slot.growthElapsed = math.max(tonumber(savedSlot.growthElapsed) or 0, 0)
				if not slot.foodPart then
					slot.foodPart = spawnFoodAtSlot(slot)
				end
				refreshSlotVisual(slot)
			end
		end
	end

	local lastTick = tonumber(placement.lastTick) or now
	local elapsed  = now - lastTick
	-- Offline credit runs at OFFLINE_GROW_FRACTION of the online rate.
-- applyGrowth receives effective online seconds, so scaling here is
-- equivalent to scaling the amount of interval progress for this single call.
	applyGrowth(machine, s, elapsed * OFFLINE_GROW_FRACTION)
	s.lastTick = os.time()
end

function Patches.HarvestAnchor(anchor, player)
	if not anchor or not anchor:IsA("BasePart") then return false end
	for machine, s in pairs(state) do
		if machine.Parent then
			for i, slot in ipairs(s.slots) do
				if slot.anchor == anchor then
					harvest(machine, s, i, player)
					return true
				end
			end
		end
	end
	return false
end

return Patches
