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
-- loop and no per-second attribute replication. Harvest, persistence, and
-- onboarding all read the same derived value, so earnings are unchanged.
--
-- Tunable attribute on the model:
--   FoodDrop (string, required) exact food id produced by each slot
--   XP       (number, default 1) XP gained per growth interval
--   GrowRate (number, default 3) seconds per growth interval

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent.Parent
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Food = require(ReplicatedStorage.Shared:WaitForChild("Food"))
local PatchGrowth = require(ReplicatedStorage.Shared:WaitForChild("PatchGrowth"))
local PatchScale = require(ReplicatedStorage.Shared:WaitForChild("PatchScale"))
local RuntimeGuard = require(ReplicatedStorage.Shared:WaitForChild("RuntimeGuard"))
local State = require(ReplicatedStorage.Shared:WaitForChild("State"))

local Patches = {}

local HARVEST_RESPAWN_DELAY = 3
local OFFLINE_GROW_FRACTION = 1 / 1000
local EDIT_MODE_ATTR = "EditMode"

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
--     lastReportedXP, anchor, foodPart,
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

-- Onboarding progress: reports the delta since the last report for this slot.
local function reportSlotXP(machine, s, slot, profile, xpNow)
	local gained = xpNow - (slot.lastReportedXP or 0)
	if gained <= 0 then return end
	slot.lastReportedXP = xpNow
	if s.owner and profile then
		OnboardingService.OnPatchXPGained(s.owner, profile, machine, gained)
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
	clone:SetAttribute(State.Food.XP, slot.baseXP or 0)
	clone:SetAttribute(State.Food.GrowthStart, slot.growthStart)
	if clone:IsA("BasePart") then
		configureSlotPart(clone)
		clone:PivotTo(slot.anchor.CFrame)
	elseif clone:IsA("Model") then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then configureSlotPart(d) end
		end
		clone:PivotTo(slot.anchor.CFrame)
		-- Initialize before parenting so clients never see a full-size flash.
		clone:ScaleTo(PatchScale.ComputeScale(slot.baseXP or 0, slot.patchXP))
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
	slot.baseXP = 0
	slot.growthStart = serverNow()
	slot.lastReportedXP = 0
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
	slot.pendingOfflineGrowthElapsed = nil
	slot.lastReportedXP = 0
	slot.respawnAt = respawnAt
end

local function isOfflineProgressPending(s)
	return s.owner and s.owner:GetAttribute(State.Player.OfflineProgressPending) == true
end

-- Onboarding pumpkin-XP progress is the only consumer that needs periodic
-- growth observation. This 1Hz loop does work only for players currently in
-- the gather-pumpkin-XP tutorial stage (early-game players with few patches);
-- for everyone else each pass is a cheap profile/stage check per player.
RuntimeGuard.Spawn("Patches.OnboardingXPLoop", function()
	while true do
		task.wait(1)
		for _, player in ipairs(Players:GetPlayers()) do
			RuntimeGuard.Run("Patches.OnboardingXPTick", function()
				local profile = PlayerDataService.GetProfile(player)
				if not profile or not OnboardingService.NeedsPatchXPReports(profile) then return end
				local now = serverNow()
				for machine, s in pairs(state) do
					if s.owner == player and machine.Parent and not isOfflineProgressPending(s) then
						for _, slot in ipairs(s.slots) do
							if not slot.respawnAt and slot.growthStart then
								reportSlotXP(machine, s, slot, profile, slotXPNow(machine, slot, now))
							end
						end
					end
				end
			end)
		end
	end
end)

local function scaleToolToXP(tool, xp, patchXP)
	-- Tool inherits from Model, so :ScaleTo works on the whole Tool —
	-- handle + welded sub-parts scale together.
	tool:ScaleTo(PatchScale.ComputeScale(xp, patchXP))
end

local function harvest(machine, s, slotIndex, player)
	if player ~= s.owner then return false end
	if player:GetAttribute(EDIT_MODE_ATTR) == true then return false end
	local slot = s.slots[slotIndex]
	if not slot or slot.respawnAt then return false end  -- empty during respawn delay
	local foodId = s.foodId
	if not foodId then return false end
	local xp = slotXPNow(machine, slot, serverNow())
	local tool = Food.MakeTool(foodId, xp)
	if not tool then return false end
	scaleToolToXP(tool, xp, slot.patchXP)
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
		reportSlotXP(machine, s, slot, profile, xp)
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
				baseXP = 0,
				growthStart = now,
				lastReportedXP = 0,
				anchor = anchor,
				foodPart = nil,
				respawnAt = nil,
			}
			slot.foodPart = spawnFoodAtSlot(slot)
			table.insert(s.slots, slot)
			anchorIndex[anchor] = { machine = machine, slotIndex = #s.slots }
		end
	end
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
			slots[#slots + 1] = {
				xp = slot.baseXP or 0,
				growthElapsed = slot.pendingOfflineGrowthElapsed or 0,
				respawnAt = slot.respawnAt,
			}
		end
		return { slots = slots, lastTick = s.lastTick }
	end

	local now = serverNow()
	local growRate = growRateFor(machine)
	local slots = table.create(#s.slots)
	for _, slot in ipairs(s.slots) do
		if slot.respawnAt then
			slots[#slots + 1] = { xp = 0, growthElapsed = 0, respawnAt = slot.respawnAt }
		else
			local elapsed = 0
			if type(slot.growthStart) == "number" then
				elapsed = math.max(now - slot.growthStart, 0)
			end
			local intervals = math.floor(elapsed / growRate)
			slots[#slots + 1] = {
				xp = (slot.baseXP or 0) + intervals * slot.patchXP,
				growthElapsed = elapsed - intervals * growRate,
				respawnAt = nil,
			}
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
				slot.respawnAt = nil
				slot.pendingMaterialize = nil
				slot.baseXP = savedXP
				slot.growthStart = nil
				slot.pendingOfflineGrowthElapsed = savedElapsed
				-- Report future onboarding gains relative to the saved XP so
				-- offline credit counts, matching the previous behavior.
				slot.lastReportedXP = savedXP
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

	for _, slot in ipairs(s.slots) do
		if type(slot.respawnAt) == "number" then
			if slot.respawnAt > joinTime then
				slot.respawnAt += pendingDuration
			end
			scheduleSlotRespawn(machine, s, slot, slot.respawnAt - os.time())
		else
			creditSlotGrowth(machine, slot, offlineSeconds, now)
			publishSlotGrowth(slot)
		end
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

return Patches
