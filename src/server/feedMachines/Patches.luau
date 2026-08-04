-- Shared timed-growth FeedMachine implementation.
--
-- Patch templates produce one exact FoodDrop food id. Each BaseFood slot
-- earns the patch's XP value every GrowRate seconds and harvest grants the
-- accumulated XP on the produced food tool. Harvesting empties the slot for a
-- short respawn delay, then the same food starts accumulating from zero again.
--
-- Growth is derived, not ticked: the server stores a base XP plus a
-- growth-start timestamp per slot and publishes both as attributes once per
-- anchor change (spawn, harvest, respawn, restore, offline credit). Current
-- XP is computed on demand via PatchGrowth, so there is no per-second growth
-- loop and no per-second attribute replication. Harvest and persistence read
-- the same derived value, so earnings are unchanged.
--
-- Tunable attribute on the model:
--   FoodDrop (string, required) exact food id produced by each slot
--   XP       (number, default 1) XP gained per growth interval
--   GrowRate (number, default 3) seconds per growth interval

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent.Parent
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Food = require(ReplicatedStorage.Shared:WaitForChild("Food"))
local Mutations = require(ReplicatedStorage.Shared:WaitForChild("Mutations"))
local PatchGrowth = require(ReplicatedStorage.Shared:WaitForChild("PatchGrowth"))
local PatchScale = require(ReplicatedStorage.Shared:WaitForChild("PatchScale"))
local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local Patches = {}

local HARVEST_RESPAWN_DELAY = 3
local NAV_BLOCK_SCALE_THRESHOLD = 1.5
local OFFLINE_GROW_FRACTION = 0.04
local EDIT_MODE_ATTR = "EditMode"
local GROWING_SEED_PHASE = "GrowingSeed"

-- Offline progress runs at this fraction of the online rate. Tunable in one
-- place; not on the machine attribute since it's an economy-wide knob for
-- patch machines.

-- Mature slot fruit scale is rendered locally by PatchSlotVisuals. Harvested
-- tools still use the shared scale formula on the server.

-- [machine] = {
--   owner, plot, foodId, patchXP, lastTick, awaitingOfflineProgress,
--   slots = { [i] = {
--     baseXP, growthStart (server clock), respawnAt (wall clock),
--     pendingOfflineGrowthElapsed, pendingMaterialize, respawnToken,
--     anchor, foodPart,
--   } },
-- }
local state = {}

-- [anchor] = { machine = Model, slotIndex = number }; same lifecycle as
-- `state` (populated at Setup, cleared at Teardown).
local anchorIndex = {}

local function serverNow()
	return Workspace:GetServerTimeNow()
end

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

local function growRateFor(machine)
	return PatchGrowth.NormalizeGrowRate(machine:GetAttribute(State.Feed.GrowRate))
end

local function slotXPNow(machine, slot, now)
	if slot.respawnAt or type(slot.growthStart) ~= "number" then
		return slot.baseXP or 0
	end
	return PatchGrowth.ComputeXPFromState(slot.baseXP, slot.growthStart, growRateFor(machine), slot.patchXP, now)
end

local function publishSlotGrowth(slot)
	local food = slot.foodPart
	if not food then return end
	food:SetAttribute(State.Food.XP, slot.baseXP or 0)
	food:SetAttribute(State.Food.GrowthStart, slot.growthStart)
	food:SetAttribute(State.Food.RespawnAt, nil)
	Mutations.ApplyAttribute(food, slot.mutationIds, slot.primaryMutationId)
	food:SetAttribute(State.Food.StealReservationId, slot.stealReservationId)
	food:SetAttribute(State.Food.StealReservationExpiresAt, slot.stealReservationExpiresAt)
end

local function publishSlotRespawn(slot)
	if slot.anchor then
		slot.anchor:SetAttribute(State.Food.RespawnAt, slot.respawnAt)
	end
	if slot.foodPart then
		slot.foodPart:SetAttribute(State.Food.RespawnAt, nil)
	end
end

local function clearSlotStealReservation(slot)
	slot.stealReservationId = nil
	slot.stealReservationExpiresAt = nil
	if slot.anchor then
		slot.anchor:SetAttribute(State.Food.StealReservationId, nil)
		slot.anchor:SetAttribute(State.Food.StealReservationExpiresAt, nil)
	end
	if slot.foodPart then
		slot.foodPart:SetAttribute(State.Food.StealReservationId, nil)
		slot.foodPart:SetAttribute(State.Food.StealReservationExpiresAt, nil)
	end
end

local function clearExpiredSlotStealReservation(slot)
	if not slot or slot.stealReservationId == nil then
		return false
	end
	local expiresAt = tonumber(slot.stealReservationExpiresAt)
	if expiresAt and expiresAt > os.time() then
		return false
	end
	clearSlotStealReservation(slot)
	return true
end

local function addSlotReservationRecord(record, slot)
	if type(slot.stealReservationId) == "string" and slot.stealReservationId ~= "" then
		record.stealReservationId = slot.stealReservationId
		record.stealReservationExpiresAt = slot.stealReservationExpiresAt
	end
	return record
end

local function restoreSlotReservation(slot, savedSlot)
	slot.stealReservationId = nil
	slot.stealReservationExpiresAt = nil
	local reservationId = type(savedSlot.stealReservationId) == "string" and savedSlot.stealReservationId or nil
	if reservationId and reservationId ~= "" then
		slot.stealReservationId = reservationId
		slot.stealReservationExpiresAt = tonumber(savedSlot.stealReservationExpiresAt) or os.time()
	end
end

-- Banks `effectiveSeconds` of growth into baseXP and re-anchors growthStart
-- so the leftover partial interval keeps counting from `now`.
local function anchorSlotGrowth(machine, slot, effectiveSeconds, now)
	local growRate = growRateFor(machine)
	effectiveSeconds = math.max(tonumber(effectiveSeconds) or 0, 0)
	local intervals = math.floor(effectiveSeconds / growRate)
	slot.baseXP = (slot.baseXP or 0) + intervals * slot.patchXP
	slot.growthStart = now - (effectiveSeconds - intervals * growRate)
end

-- Adds extra growth seconds (e.g. offline credit) on top of whatever the slot
-- has already accrued, whether it is currently growing or frozen.
local function creditSlotGrowth(machine, slot, extraSeconds, now)
	local current
	if type(slot.growthStart) == "number" then
		current = math.max(now - slot.growthStart, 0)
	else
		current = math.max(tonumber(slot.pendingOfflineGrowthElapsed) or 0, 0)
	end
	slot.pendingOfflineGrowthElapsed = nil
	anchorSlotGrowth(machine, slot, current + math.max(tonumber(extraSeconds) or 0, 0), now)
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
	clone:SetAttribute(State.Food.XP, slot.baseXP or 0)
	clone:SetAttribute(State.Food.GrowthStart, slot.growthStart)
	clone:SetAttribute(State.Food.RespawnAt, nil)
	Mutations.ApplyAttribute(clone, slot.mutationIds, slot.primaryMutationId)
	clone:SetAttribute(State.Food.StealReservationId, slot.stealReservationId)
	clone:SetAttribute(State.Food.StealReservationExpiresAt, slot.stealReservationExpiresAt)
	if clone:IsA("BasePart") then
		configureSlotPart(clone)
		clone:PivotTo(slot.anchor.CFrame)
	elseif clone:IsA("Model") then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then configureSlotPart(d) end
		end
		clone:PivotTo(slot.anchor.CFrame)
		-- Initialize before parenting so clients never see a full-size flash.
		clone:ScaleTo(PatchScale.ComputeScale(slot.baseXP or 0, slot.patchXP, foodId))
		-- Stream the fruit as one unit so clients never ScaleTo a model whose
		-- remaining parts arrive later at server geometry.
		clone.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end
	clone.Parent = slot.anchor
	return clone
end

-- Brings an empty slot back after its respawn delay. Deferred while the
-- owner is in edit mode so the machine's bounds stay stable mid-drag.
local function materializeSlot(machine, s, slot)
	if s.owner and s.owner:GetAttribute(EDIT_MODE_ATTR) == true then
		slot.pendingMaterialize = true
		return
	end
	slot.pendingMaterialize = nil
	slot.respawnAt = nil
	-- Fruit plants with its first interval already banked, so a fresh slot
	-- reads one tick of XP instead of zero.
	slot.baseXP = slot.patchXP
	slot.growthStart = serverNow()
	publishSlotRespawn(slot)
	if slot.foodPart then slot.foodPart:Destroy() end
	slot.foodPart = spawnFoodAtSlot(slot)
end

local function scheduleSlotRespawn(machine, s, slot, delaySeconds)
	slot.respawnToken = (slot.respawnToken or 0) + 1
	local token = slot.respawnToken
	task.delay(math.max(tonumber(delaySeconds) or 0, 0), function()
		RuntimeGuard.Run("Patches.SlotRespawn", function()
			if state[machine] ~= s or slot.respawnToken ~= token then return end
			if not machine.Parent or not slot.respawnAt then return end
			-- respawnAt may have been pushed back (offline progress shifts
			-- it by the pending duration); re-arm instead of materializing.
			local remaining = slot.respawnAt - os.time()
			if remaining > 0.05 then
				scheduleSlotRespawn(machine, s, slot, remaining)
				return
			end
			materializeSlot(machine, s, slot)
		end)
	end)
end

local function emptySlot(slot, respawnAt)
	if slot.foodPart then slot.foodPart:Destroy() end
	slot.foodPart = nil
	slot.baseXP = 0
	slot.growthStart = nil
	slot.mutationIds = nil
	slot.primaryMutationId = nil
	slot.pendingOfflineGrowthElapsed = nil
	slot.respawnAt = respawnAt
	clearSlotStealReservation(slot)
	publishSlotRespawn(slot)
end

local function scaleToolToXP(tool, xp, patchXP, foodId)
	-- Tool inherits from Model, so :ScaleTo works on the whole Tool —
	-- handle + welded sub-parts scale together.
	tool:ScaleTo(PatchScale.ComputeScale(xp, patchXP, foodId))
end

local function harvest(machine, s, slotIndex, player)
	if player ~= s.owner then return false end
	if player:GetAttribute(EDIT_MODE_ATTR) == true then return false end
	local slot = s.slots[slotIndex]
	if not slot or slot.respawnAt then return false end  -- empty during respawn delay
	clearExpiredSlotStealReservation(slot)
	if slot.stealReservationId ~= nil then return false end
	local foodId = s.foodId
	if not foodId then return false end
	local xp = slotXPNow(machine, slot, serverNow())
	local tool = Food.MakeTool(foodId, xp, slot.mutationIds, slot.primaryMutationId)
	if not tool then return false end
	scaleToolToXP(tool, xp, slot.patchXP, foodId)
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

	-- Empty the slot, start respawn timer; materializeSlot restores it.
	emptySlot(slot, os.time() + HARVEST_RESPAWN_DELAY)
	scheduleSlotRespawn(machine, s, slot, HARVEST_RESPAWN_DELAY)
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
	}
	state[machine] = s

	if owner then
		s.editModeConn = RuntimeGuard.Connect(owner:GetAttributeChangedSignal(EDIT_MODE_ATTR), "Patches.EditModeChanged", function()
			if owner:GetAttribute(EDIT_MODE_ATTR) == true then return end
			for _, slot in ipairs(s.slots) do
				if slot.pendingMaterialize then
					materializeSlot(machine, s, slot)
				end
			end
		end)
	end

	local now = serverNow()
	for _, child in ipairs(machine:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "BaseFood" then
			local anchor = makeSlotAnchor(machine, child)
			child:Destroy()

			local slot = {
				foodId = s.foodId,
				patchXP = s.patchXP,
				-- First interval is banked at plant time (see materializeSlot).
				baseXP = s.patchXP,
				growthStart = now,
				anchor = anchor,
				foodPart = nil,
				stealReservationId = nil,
				mutationIds = nil,
				primaryMutationId = nil,
				respawnAt = nil,
			}
			slot.foodPart = spawnFoodAtSlot(slot)
			table.insert(s.slots, slot)
			anchorIndex[anchor] = { machine = machine, slotIndex = #s.slots }
		end
	end
end

-- Re-rates a machine to a new XP-per-interval (dynamic PercentageOfBest
-- resolution). Fully-elapsed intervals are banked at the OLD rate first
-- (anchorSlotGrowth reads slot.patchXP), then the rate swaps and the machine
-- attribute republishes so client derivation (PatchGrowth) stays consistent.
function Patches.SetResolvedPatchXP(machine, resolvedXP)
	local s = state[machine]
	if not s then return end
	resolvedXP = PatchScale.NormalizePatchXP(resolvedXP)
	if s.patchXP == resolvedXP then
		if machine:GetAttribute(State.Feed.XP) ~= resolvedXP then
			machine:SetAttribute(State.Feed.XP, resolvedXP)
		end
		return
	end
	local now = serverNow()
	for _, slot in ipairs(s.slots) do
		if not slot.respawnAt and type(slot.growthStart) == "number" then
			anchorSlotGrowth(machine, slot, now - slot.growthStart, now)
		end
		-- Frozen slots (offline-progress pending) and respawn-pending slots
		-- just swap: baseXP is absolute, and pending growth seconds convert
		-- at the new rate when they materialize.
		slot.patchXP = resolvedXP
		if slot.foodPart then
			publishSlotGrowth(slot)
		end
	end
	s.patchXP = resolvedXP
	machine:SetAttribute(State.Feed.XP, resolvedXP)
end

function Patches.Teardown(machine)
	local s = state[machine]
	if s then
		if s.editModeConn then
			s.editModeConn:Disconnect()
		end
		for _, slot in ipairs(s.slots) do
			-- Invalidate any scheduled respawn callbacks.
			slot.respawnToken = (slot.respawnToken or 0) + 1
			if slot.anchor then
				anchorIndex[slot.anchor] = nil
			end
		end
	end
	state[machine] = nil
end

function Patches.Serialize(machine)
	local s = state[machine]
	if not s then return nil end

	-- Between a deferred Apply and ApplyOfflineProgress the slots are frozen
	-- at their saved values; re-emit those so no offline credit is lost.
	-- (snapshotProfileState applies pending offline progress first, so this
	-- is a defensive path.)
	if s.awaitingOfflineProgress then
		local slots = table.create(#s.slots)
		for _, slot in ipairs(s.slots) do
			slots[#slots + 1] = addSlotReservationRecord({
				xp = slot.baseXP or 0,
				growthElapsed = slot.pendingOfflineGrowthElapsed or 0,
				respawnAt = slot.respawnAt,
				mutationIds = slot.mutationIds,
				primaryMutationId = slot.primaryMutationId,
			}, slot)
		end
		return { slots = slots, lastTick = s.lastTick }
	end

	local now = serverNow()
	local growRate = growRateFor(machine)
	local slots = table.create(#s.slots)
	for _, slot in ipairs(s.slots) do
		if slot.respawnAt then
			slots[#slots + 1] = addSlotReservationRecord({
				xp = 0,
				growthElapsed = 0,
				respawnAt = slot.respawnAt,
			}, slot)
		else
			local elapsed = 0
			if type(slot.growthStart) == "number" then
				elapsed = math.max(now - slot.growthStart, 0)
			end
			local intervals = math.floor(elapsed / growRate)
			slots[#slots + 1] = addSlotReservationRecord({
				xp = (slot.baseXP or 0) + intervals * slot.patchXP,
				growthElapsed = elapsed - intervals * growRate,
				respawnAt = nil,
				mutationIds = slot.mutationIds,
				primaryMutationId = slot.primaryMutationId,
			}, slot)
		end
	end
	return { slots = slots, lastTick = os.time() }
end

function Patches.Apply(machine, placement, options)
	local s = state[machine]
	if not s then return end
	if type(placement.slots) ~= "table" then return end
	options = type(options) == "table" and options or {}
	local deferOfflineProgress = options.deferOfflineProgress == true

	local nowWall = os.time()
	local now = serverNow()
	local lastTick = tonumber(placement.lastTick) or nowWall
	-- Offline credit runs at OFFLINE_GROW_FRACTION of the online rate.
	local offlineSeconds = math.max(nowWall - lastTick, 0) * OFFLINE_GROW_FRACTION

	for i, savedSlot in ipairs(placement.slots) do
		local slot = s.slots[i]
		if slot and type(savedSlot) == "table" then
			local respawnAt = tonumber(savedSlot.respawnAt)
			if respawnAt and (deferOfflineProgress or respawnAt > nowWall) then
				-- Still in the post-harvest delay; keep slot empty. In the
				-- deferred path ApplyOfflineProgress shifts respawnAt and
				-- arms the timer once the pending window resolves.
				emptySlot(slot, respawnAt)
				if not deferOfflineProgress then
					scheduleSlotRespawn(machine, s, slot, respawnAt - nowWall)
				end
			else
				local savedXP = math.max(tonumber(savedSlot.xp) or 0, 0)
				local savedElapsed = math.max(tonumber(savedSlot.growthElapsed) or 0, 0)
				restoreSlotReservation(slot, savedSlot)
				slot.respawnAt = nil
				publishSlotRespawn(slot)
				slot.pendingMaterialize = nil
				slot.baseXP = savedXP
				slot.mutationIds = Mutations.SanitizeList(savedSlot.mutationIds or savedSlot.mutations)
				slot.primaryMutationId = Mutations.Primary(slot.mutationIds, savedSlot.primaryMutationId or savedSlot.primaryMutation)
				slot.growthStart = nil
				slot.pendingOfflineGrowthElapsed = savedElapsed
				if not deferOfflineProgress then
					creditSlotGrowth(machine, slot, offlineSeconds, now)
				end
				if not slot.foodPart then
					slot.foodPart = spawnFoodAtSlot(slot)
				else
					publishSlotGrowth(slot)
				end
			end
		end
	end

	s.lastTick = lastTick
	if deferOfflineProgress then
		-- Slots stay frozen (no growthStart) until ApplyOfflineProgress.
		s.awaitingOfflineProgress = true
		return
	end
	s.lastTick = os.time()
end

function Patches.ApplyOfflineProgress(machine, context)
	local s = state[machine]
	if not s then return true end
	context = type(context) == "table" and context or {}
	local joinTime = tonumber(context.joinTime) or os.time()
	local applyTime = tonumber(context.applyTime) or os.time()
	local pendingDuration = math.max(applyTime - joinTime, 0)

	local now = serverNow()
	local offlineSeconds = math.max(joinTime - (tonumber(s.lastTick) or joinTime), 0) * OFFLINE_GROW_FRACTION
	-- The join-back showcase reports the XP the crops banked while away, so
	-- measure it as the baseXP delta creditSlotGrowth actually applies.
	local totals = type(context.totals) == "table" and context.totals or nil
	local creditedXP = 0

	for _, slot in ipairs(s.slots) do
		if type(slot.respawnAt) == "number" then
			if slot.respawnAt > joinTime then
				slot.respawnAt += pendingDuration
			end
			publishSlotRespawn(slot)
			scheduleSlotRespawn(machine, s, slot, slot.respawnAt - os.time())
		else
			local beforeXP = slot.baseXP or 0
			creditSlotGrowth(machine, slot, offlineSeconds, now)
			creditedXP += math.max((slot.baseXP or 0) - beforeXP, 0)
			publishSlotGrowth(slot)
		end
	end

	if totals then
		totals.xp += creditedXP
	end

	s.awaitingOfflineProgress = nil
	s.lastTick = os.time()
	return true
end

function Patches.HarvestAnchor(anchor, player)
	local entry = anchor and anchorIndex[anchor]
	if not entry then return false end
	local s = state[entry.machine]
	if not s or not entry.machine.Parent then return false end
	return harvest(entry.machine, s, entry.slotIndex, player)
end

local function reserveSlotForCollectAll(machine, slot, slotIndex, reservationId, expiresAt)
	if not slot or slot.respawnAt or not slot.foodPart then
		return nil
	end
	clearExpiredSlotStealReservation(slot)
	if slot.stealReservationId ~= nil then
		return nil
	end
	local foodId = slot.foodId
	if type(foodId) ~= "string" or foodId == "" then
		return nil
	end

	local xp = slotXPNow(machine, slot, serverNow())
	slot.stealReservationId = reservationId
	slot.stealReservationExpiresAt = tonumber(expiresAt) or os.time()
	if slot.anchor then
		slot.anchor:SetAttribute(State.Food.StealReservationId, reservationId)
		slot.anchor:SetAttribute(State.Food.StealReservationExpiresAt, slot.stealReservationExpiresAt)
	end
	if slot.foodPart then
		slot.foodPart:SetAttribute(State.Food.StealReservationId, reservationId)
		slot.foodPart:SetAttribute(State.Food.StealReservationExpiresAt, slot.stealReservationExpiresAt)
	end

	return {
		sourceKind = "Patch",
		sourceFeedIndex = machine:GetAttribute(State.Feed.Index),
		sourceSlotIndex = slotIndex,
		foodId = foodId,
		xp = xp,
		scale = PatchScale.ComputeScale(xp, slot.patchXP, foodId),
		mutationIds = slot.mutationIds,
		primaryMutationId = slot.primaryMutationId,
	}
end

function Patches.ReserveCollectAll(machine, player, reservationId, expiresAt, limit)
	local s = state[machine]
	if not (s and machine.Parent) then return false, "not-ready" end
	if player ~= s.owner then return false, "not-owner" end
	if player:GetAttribute(EDIT_MODE_ATTR) == true then return false, "edit-mode" end
	if type(reservationId) ~= "string" or reservationId == "" then return false, "invalid-reservation" end

	limit = math.max(math.floor(tonumber(limit) or 0), 0)
	local items = {}
	for slotIndex, slot in ipairs(s.slots) do
		if limit > 0 and #items >= limit then
			break
		end
		local item = reserveSlotForCollectAll(machine, slot, slotIndex, reservationId, expiresAt)
		if item then
			items[#items + 1] = item
		end
	end
	return true, {
		items = items,
	}
end

local function slotForCollectAllItem(machine, item)
	local s = machine and state[machine]
	if not s then
		return nil, nil
	end
	local slotIndex = math.max(math.floor(tonumber(item and item.sourceSlotIndex) or 0), 0)
	return s.slots[slotIndex], s
end

function Patches.ReleaseCollectAll(machine, item, reservationId)
	local slot = slotForCollectAllItem(machine, item)
	if not slot or slot.stealReservationId ~= reservationId then
		return false
	end
	clearSlotStealReservation(slot)
	return true
end

function Patches.CommitCollectAll(machine, item, reservationId)
	local slot, s = slotForCollectAllItem(machine, item)
	if not slot or not s or slot.stealReservationId ~= reservationId then
		return false
	end
	emptySlot(slot, os.time() + HARVEST_RESPAWN_DELAY)
	scheduleSlotRespawn(machine, s, slot, HARVEST_RESPAWN_DELAY)
	return true, machine
end

function Patches.ReserveStealTarget(anchor, player, reservationId, expiresAt)
	local entry = anchor and anchorIndex[anchor]
	if not entry then return false, "not-patch" end
	local machine = entry.machine
	local s = state[machine]
	if not s or not machine.Parent then return false, "not-ready" end
	if player == s.owner then return false, "own-food" end
	if s.owner and s.owner:GetAttribute(EDIT_MODE_ATTR) == true then return false, "source-edit-mode" end
	if type(reservationId) ~= "string" or reservationId == "" then return false, "invalid-reservation" end
	local slot = s.slots[entry.slotIndex]
	if not slot or slot.respawnAt or not slot.foodPart then return false, "no-food" end
	clearExpiredSlotStealReservation(slot)
	if slot.stealReservationId ~= nil then return false, "reserved" end
	local foodId = s.foodId
	if type(foodId) ~= "string" or foodId == "" then return false, "no-food" end

	local xp = slotXPNow(machine, slot, serverNow())
	slot.stealReservationId = reservationId
	slot.stealReservationExpiresAt = tonumber(expiresAt) or os.time()
	slot.anchor:SetAttribute(State.Food.StealReservationId, reservationId)
	slot.anchor:SetAttribute(State.Food.StealReservationExpiresAt, slot.stealReservationExpiresAt)
	if slot.foodPart then
		slot.foodPart:SetAttribute(State.Food.StealReservationId, reservationId)
		slot.foodPart:SetAttribute(State.Food.StealReservationExpiresAt, slot.stealReservationExpiresAt)
	end

	return true, {
		foodId = foodId,
		xp = xp,
		scale = PatchScale.ComputeScale(xp, slot.patchXP, foodId),
		mutationIds = slot.mutationIds,
		primaryMutationId = slot.primaryMutationId,
		sourceKind = "Patch",
		sourceOwnerUserId = s.owner and s.owner.UserId or 0,
		sourceFeedIndex = machine:GetAttribute(State.Feed.Index),
		sourceSlotIndex = entry.slotIndex,
	}, machine
end

local function slotPosition(slot)
	local food = slot and slot.foodPart
	if food then
		if food:IsA("BasePart") then
			return food.Position
		elseif food:IsA("Model") then
			return food:GetPivot().Position
		end
	end
	local anchor = slot and slot.anchor
	return anchor and anchor.Position or nil
end

function Patches.CollectMutationTargets(machine, mutationId)
	local s = state[machine]
	if not (s and machine.Parent) then
		return {}
	end
	local targets = {}
	for slotIndex, slot in ipairs(s.slots) do
		clearExpiredSlotStealReservation(slot)
		if not slot.respawnAt
			and slot.foodPart
			and slot.stealReservationId == nil
			and Mutations.CanAccept(slot.mutationIds, mutationId) then
			local position = slotPosition(slot)
			if position then
				targets[#targets + 1] = {
					kind = "Patch",
					machine = machine,
					targetKey = slotIndex,
					position = position,
					foodId = slot.foodId,
				}
			end
		end
	end
	return targets
end

function Patches.ApplyMutation(machine, targetKey, mutationId)
	local s = state[machine]
	local slot = s and s.slots[tonumber(targetKey) or 0]
	if not (slot and slot.foodPart and not slot.respawnAt) then
		return false, "no-food"
	end
	clearExpiredSlotStealReservation(slot)
	if slot.stealReservationId ~= nil then
		return false, "reserved"
	end
	local canAccept, rejectReason = Mutations.CanAccept(slot.mutationIds, mutationId)
	if not canAccept then
		return false, rejectReason
	end
	local nextMutationIds, added = Mutations.Add(slot.mutationIds, mutationId)
	if not added then
		return false, "already-mutated"
	end
	local multiplier = Mutations.XPMultiplier(mutationId) or 1

	local now = serverNow()
	local growRate = growRateFor(machine)
	local elapsed = type(slot.growthStart) == "number" and math.max(now - slot.growthStart, 0) or 0
	local residual = elapsed - (math.floor(elapsed / growRate) * growRate)
	slot.baseXP = slotXPNow(machine, slot, now) * multiplier
	slot.growthStart = now - residual
	slot.mutationIds = nextMutationIds
	slot.primaryMutationId = mutationId
	publishSlotGrowth(slot)
	return true, {
		position = slotPosition(slot),
		foodId = slot.foodId,
		mutationIds = nextMutationIds,
		primaryMutationId = slot.primaryMutationId,
	}
end

-- Growth-boost targets (Sprinkle event). No mutation gate: a boost is a plain
-- XP multiply that leaves no permanent tag, so already-mutated fruit is still
-- eligible. Respawning slots have nothing to boost.
function Patches.CollectBoostTargets(machine)
	local s = state[machine]
	if not (s and machine.Parent) then
		return {}
	end
	local targets = {}
	for slotIndex, slot in ipairs(s.slots) do
		clearExpiredSlotStealReservation(slot)
		-- A live steal reservation locked this fruit's price at reservation time;
		-- moving its XP underneath the thief would desync what they were quoted.
		if not slot.respawnAt and slot.foodPart and slot.stealReservationId == nil then
			local position = slotPosition(slot)
			if position then
				targets[#targets + 1] = {
					kind = "Patch",
					machine = machine,
					targetKey = slotIndex,
					position = position,
					foodId = slot.foodId,
				}
			end
		end
	end
	return targets
end

-- Re-anchors the slot exactly the way ApplyMutation does, minus every piece of
-- mutation bookkeeping. Patch XP is never ticked or replicated per interval --
-- it is derived from (baseXP, growthStart) by PatchGrowth.ComputeXPFromState --
-- so the boost is "bake the current derived XP times the multiplier into
-- baseXP, then restart the growth clock mid-interval".
--
-- Preserving `residual` is what keeps natural growth intact: without it every
-- boost would also silently reset the player's progress toward the next XP tick.
--
-- Because PatchSlotVisuals recomputes ScaleTo from these same attributes every
-- heartbeat, a stepped ramp of these calls makes the fruit visibly swell with no
-- client-side code at all.
function Patches.ApplyGrowthBoost(machine, targetKey, multiplier)
	local s = state[machine]
	local slot = s and s.slots[tonumber(targetKey) or 0]
	if not (slot and slot.foodPart and not slot.respawnAt) then
		return false, "no-food"
	end
	multiplier = tonumber(multiplier)
	if not multiplier or multiplier ~= multiplier or multiplier <= 0 then
		return false, "invalid-multiplier"
	end
	clearExpiredSlotStealReservation(slot)
	if slot.stealReservationId ~= nil then
		return false, "reserved"
	end

	local now = serverNow()
	local growRate = growRateFor(machine)
	local elapsed = type(slot.growthStart) == "number" and math.max(now - slot.growthStart, 0) or 0
	local residual = elapsed - (math.floor(elapsed / growRate) * growRate)
	slot.baseXP = slotXPNow(machine, slot, now) * multiplier
	slot.growthStart = now - residual
	publishSlotGrowth(slot)
	return true, {
		position = slotPosition(slot),
		foodId = slot.foodId,
		xp = slot.baseXP,
	}
end

function Patches.ReleaseSteal(machine, reservation, reservationId)
	local s = machine and state[machine]
	if not s then return false end
	local slotIndex = reservation and reservation.sourceSlotIndex
	local slot = s.slots[slotIndex]
	if not slot or slot.stealReservationId ~= reservationId then return false end
	clearSlotStealReservation(slot)
	return true
end

function Patches.CommitSteal(machine, reservation, reservationId)
	local s = machine and state[machine]
	if not s then return false end
	local slotIndex = reservation and reservation.sourceSlotIndex
	local slot = s.slots[slotIndex]
	if not slot or slot.stealReservationId ~= reservationId then return false end
	emptySlot(slot, os.time() + HARVEST_RESPAWN_DELAY)
	scheduleSlotRespawn(machine, s, slot, HARVEST_RESPAWN_DELAY)
	return true, machine
end

function Patches.HasGrowthCreditTarget(machine)
	local s = state[machine]
	return s ~= nil and machine.Parent ~= nil and type(s.slots) == "table" and #s.slots > 0
end

function Patches.CreditGrowthSeconds(machine, seconds)
	local s = state[machine]
	seconds = math.max(tonumber(seconds) or 0, 0)
	if not (s and machine.Parent and seconds > 0) then
		return false, "not-ready"
	end

	local nowWall = os.time()
	local nowServer = serverNow()
	local changedSlots = 0

	for _, slot in ipairs(s.slots) do
		if type(slot.respawnAt) == "number" then
			local remainingRespawn = math.max(slot.respawnAt - nowWall, 0)
			if seconds < remainingRespawn then
				slot.respawnAt -= seconds
				publishSlotRespawn(slot)
				scheduleSlotRespawn(machine, s, slot, slot.respawnAt - nowWall)
				changedSlots += 1
			else
				local leftoverSeconds = seconds - remainingRespawn
				materializeSlot(machine, s, slot)
				if not slot.respawnAt and slot.foodPart and leftoverSeconds > 0 then
					creditSlotGrowth(machine, slot, leftoverSeconds, nowServer)
					publishSlotGrowth(slot)
				end
				changedSlots += 1
			end
		elseif slot.foodPart then
			creditSlotGrowth(machine, slot, seconds, nowServer)
			publishSlotGrowth(slot)
			changedSlots += 1
		end
	end

	if changedSlots <= 0 then
		return false, "no-slots"
	end
	s.lastTick = os.time()
	return true, {
		changedSlots = changedSlots,
	}
end

function Patches.BlocksPetNavigation(machine, now)
	if machine and machine:GetAttribute(State.Seed.Phase) == GROWING_SEED_PHASE then
		return false, "walkable"
	end

	local s = machine and state[machine]
	if not s or type(s.slots) ~= "table" or #s.slots == 0 then
		return true, "block"
	end

	if type(now) ~= "number" then
		now = serverNow()
	end

	for _, slot in ipairs(s.slots) do
		if type(slot) ~= "table" then
			return true, "block"
		end

		if not slot.respawnAt then
			if slot.foodPart and slot.foodPart.Parent then
				local scale = PatchScale.ComputeScale(slotXPNow(machine, slot, now), slot.patchXP, slot.foodId)
				if scale >= NAV_BLOCK_SCALE_THRESHOLD then
					return true, "block"
				end
			end
		end
	end

	return false, "walkable"
end

-- Re-syncs each slot food model's server-side geometry to its current derived
-- scale. Server geometry otherwise stays at the last published scale (clients
-- render live growth locally; see PatchSlotVisuals), so callers must resync
-- before pivoting the machine or the replicated part CFrames stomp clients'
-- scaled layouts. Geometry only: growth bookkeeping is untouched.
function Patches.ResyncVisualScales(machine)
	local s = state[machine]
	if not s then return end
	local now = serverNow()
	for _, slot in ipairs(s.slots) do
		local food = slot.foodPart
		if food and food:IsA("Model") and food.Parent then
			food:ScaleTo(PatchScale.ComputeScale(slotXPNow(machine, slot, now), slot.patchXP, slot.foodId))
		end
	end
end

return Patches
