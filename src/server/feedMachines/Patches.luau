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

local Server = script.Parent.Parent
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Food = require(ReplicatedStorage.Shared:WaitForChild("Food"))
local PatchScale = require(ReplicatedStorage.Shared:WaitForChild("PatchScale"))
local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local Patches = {}

local DEFAULT_GROW_RATE = 1
local HARVEST_RESPAWN_DELAY = 3
local OFFLINE_GROW_FRACTION = 1
local EDIT_MODE_ATTR = "EditMode"

-- Offline progress runs at this fraction of the online rate. Temporarily set
-- to full speed for testing. Tunable in one place; not on the machine
-- attribute since it's an economy-wide knob for patch machines.

-- Mature slot fruit scale is rendered locally by PatchSlotVisuals. Harvested
-- tools still use the shared scale formula on the server.

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
	return PatchScale.NormalizePatchXP(machine:GetAttribute(State.Feed.XP))
end

local function reportSlotXPGained(machine, owner, xpGained)
	local profile = owner and PlayerDataService.GetProfile(owner)
	if profile then
		OnboardingService.OnPatchXPGained(owner, profile, machine, xpGained)
	end
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
		-- Initialize before parenting so clients never see a full-size flash.
		clone:ScaleTo(PatchScale.ComputeScale(slot.xp or 0, slot.patchXP))
	end
	clone.Parent = slot.anchor
	return clone
end

local function refreshSlotVisual(slot)
	if not slot.foodPart and not slot.respawnAt then
		slot.foodPart = spawnFoodAtSlot(slot)
	end
	if slot.foodPart then
		slot.foodPart:SetAttribute(State.Food.XP, slot.xp)
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
				local gainedXP = intervals * xpPerInterval
				slot.xp += gainedXP
				reportSlotXPGained(machine, s.owner, gainedXP)
				if deferVisualRefresh then
					s.deferVisualRefresh = true
				else
					refreshSlotVisual(slot)
				end
			end
		end
	end
end

local function isOfflineProgressPending(s)
	return s.owner and s.owner:GetAttribute(State.Player.OfflineProgressPending) == true
end

-- Single shared heartbeat across all patch-style machines (1Hz tick).
RuntimeGuard.Spawn("Patches.GrowthLoop", function()
	while true do
		task.wait(1)
		for machine, s in pairs(state) do
			RuntimeGuard.Run("Patches.GrowthTick", function()
				if machine.Parent then
					if isOfflineProgressPending(s) then
						return
					end
					if s.deferVisualRefresh and not (s.owner and s.owner:GetAttribute(EDIT_MODE_ATTR) == true) then
						refreshAllSlotVisuals(s)
					end
					applyGrowth(machine, s, 1)
					s.lastTick = os.time()
				end
			end)
		end
	end
end)

local function scaleToolToSlot(tool, slot)
	-- Tool inherits from Model, so :ScaleTo works on the whole Tool —
	-- handle + welded sub-parts scale together.
	local scale = PatchScale.ComputeScale(slot.xp, slot.patchXP)
	tool:ScaleTo(scale)
end

local function harvest(machine, s, slotIndex, player)
	if player ~= s.owner then return false end
	if player:GetAttribute("EditMode") == true then return false end
	local slot = s.slots[slotIndex]
	if not slot or slot.respawnAt then return false end  -- empty during respawn delay
	local foodId = s.foodId
	if not foodId then return false end
	local tool = Food.MakeTool(foodId, slot.xp)
	if not tool then return false end
	scaleToolToSlot(tool, slot)
	if not ToolGrantService.GrantTool(player, tool, {
		deferAutoEquip = true,
		autoEquipPolicy = "firstInBurst",
		autoEquipBurstGap = 3,
	}) then
		tool:Destroy()
		return false
	end

	local profile = PlayerDataService.GetProfile(player)
	if profile then
		OnboardingService.OnPatchHarvested(player, profile, machine, foodId)
	end

	-- Empty the slot, start respawn timer; materializeRespawn restores it.
	if slot.foodPart then slot.foodPart:Destroy() end
	slot.foodPart  = nil
	slot.xp        = 0
	slot.growthElapsed = 0
	slot.respawnAt = os.time() + HARVEST_RESPAWN_DELAY
	return true, machine
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
		s.editModeConn = RuntimeGuard.Connect(owner:GetAttributeChangedSignal(EDIT_MODE_ATTR), "Patches.EditModeChanged", function()
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

function Patches.Apply(machine, placement, options)
	local s = state[machine]
	if not s then return end
	if type(placement.slots) ~= "table" then return end
	options = type(options) == "table" and options or {}
	local deferOfflineProgress = options.deferOfflineProgress == true

	local now = os.time()
	for i, savedSlot in ipairs(placement.slots) do
		local slot = s.slots[i]
		if slot and type(savedSlot) == "table" then
			local respawnAt = tonumber(savedSlot.respawnAt)
			if respawnAt and (deferOfflineProgress or respawnAt > now) then
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
	if deferOfflineProgress then
		s.lastTick = lastTick
		return
	end
	local elapsed  = now - lastTick
	-- Offline credit runs at OFFLINE_GROW_FRACTION of the online rate.
-- applyGrowth receives effective online seconds, so scaling here is
-- equivalent to scaling the amount of interval progress for this single call.
	applyGrowth(machine, s, elapsed * OFFLINE_GROW_FRACTION)
	s.lastTick = os.time()
end

function Patches.ApplyOfflineProgress(machine, context)
	local s = state[machine]
	if not s then return true end
	context = type(context) == "table" and context or {}
	local joinTime = tonumber(context.joinTime) or os.time()
	local applyTime = tonumber(context.applyTime) or os.time()
	local pendingDuration = math.max(applyTime - joinTime, 0)

	for _, slot in ipairs(s.slots) do
		if type(slot.respawnAt) == "number" and slot.respawnAt > joinTime then
			slot.respawnAt += pendingDuration
		end
	end

	local elapsed = math.max(joinTime - (tonumber(s.lastTick) or joinTime), 0)
	applyGrowth(machine, s, elapsed * OFFLINE_GROW_FRACTION)
	s.lastTick = os.time()
	return true
end

function Patches.HarvestAnchor(anchor, player)
	if not anchor or not anchor:IsA("BasePart") then return false end
	for machine, s in pairs(state) do
		if machine.Parent then
			for i, slot in ipairs(s.slots) do
				if slot.anchor == anchor then
					return harvest(machine, s, i, player)
				end
			end
		end
	end
	return false
end

return Patches
