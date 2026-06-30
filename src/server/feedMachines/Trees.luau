-- Shared tree-clicker FeedMachine implementation for FeedClass=Tree machines.
--
-- Server owns gameplay state: click validation, per-slot piles, XP, pickup,
-- and persistence. Clients own transient visuals:
-- tree shake, falling food animation, slot respawn tween, and XP billboards.
--
-- Each tree model carries numbered pairs:
--   BaseFood1..N        — on-tree fruit slots (cosmetic + spawn anchors)
--   BaseFoodGround1..N  — invisible ground markers (one per slot)
-- Each numbered slot owns its own BaseFoodGround pile. When an accepted click
-- selects a ready slot, the server clears that slot's on-tree visual, fires a
-- nearby-only TreeClickerEffect, then applies the authoritative pile/XP update
-- after the balance module's drop effect duration so replicated state lands
-- with the animation.
--
-- Ground pile state replicates on the invisible BaseFoodGround marker with
-- TreeClickerGroundPile, FoodId, FoodType, XP, and TreeClickerSlotIndex
-- attributes. Clients render close-range fruit visuals and XP billboards from
-- those attributes. Pickup gives a Tool with the pile's current foodId +
-- accumulated XP and clears that slot only.
--
-- Tunable attributes on the template:
--   FoodDrop           (string, food id dropped by each accepted click)
--   XP                 (number, default 1; multiplier applied to each drop's XP)
-- Timing tunables come from per-tree balance modules.

local PhysicsService    = game:GetService("PhysicsService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Server = script.Parent.Parent
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food   = require(Shared:WaitForChild("Food"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State  = require(Shared:WaitForChild("State"))

local TreeBalance = script.Parent:WaitForChild("Tree")
local AppleTreeBalance = require(TreeBalance:WaitForChild("AppleTreeBalance"))
local CherryTreeBalance = require(TreeBalance:WaitForChild("CherryTreeBalance"))

local TreeClickerEffect = Remotes.get(Remotes.Names.TreeClickerEffect)
local TreeClickerRequest = Remotes.get(Remotes.Names.TreeClickerRequest)

local MAX_CLICKS_PER_SECOND = 5
local REMOTE_CLICK_REFILL_RATE = 5
local REMOTE_CLICK_BURST = 8
local CLICK_DISTANCE = 24
local TREE_CLICK_TARGET_NAME = "LeafShake"

local DEFAULT_BALANCE = {
	SlotRespawn = 1,
	DropEffectDuration = 0.45,
	EffectRadius = 35,
}

-- Collision groups: tree-clicker fruits and ground markers physically collide
-- only with the plot Floor. Ground fruit geometry is now local client
-- presentation, while server markers remain invisible authority/prompt targets.
local FRUIT_GROUP = "AppleTreeFruit"
local FLOOR_GROUP = "PlotFloor"

local function ensureCollisionGroups()
	RuntimeGuard.Run("TreeClicker.RegisterFruitCollisionGroup", function()
		PhysicsService:RegisterCollisionGroup(FRUIT_GROUP)
	end)
	RuntimeGuard.Run("TreeClicker.RegisterFloorCollisionGroup", function()
		PhysicsService:RegisterCollisionGroup(FLOOR_GROUP)
	end)
	RuntimeGuard.Run("TreeClicker.ConfigureCollisionGroups", function()
		PhysicsService:CollisionGroupSetCollidable(FRUIT_GROUP, "Default", false)
		PhysicsService:CollisionGroupSetCollidable(FRUIT_GROUP, FRUIT_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(FRUIT_GROUP, FLOOR_GROUP, true)
	end)
end
ensureCollisionGroups()

local TreeClicker = {}

local BALANCES = {
	[AppleTreeBalance.FeedType] = AppleTreeBalance,
	[CherryTreeBalance.FeedType] = CherryTreeBalance,
}

-- state[machine] = {
--   owner, plot, balance, foodDrop, lastClick, conns, detectors,
--   slots = { [i] = {
--     n,             -- numeric suffix shared by BaseFoodN and BaseFoodGroundN
--     anchor,        -- invisible spawn point, replaces BaseFoodN
--     marker,        -- BaseFoodGroundN part (invisible, used as CFrame ref)
--     foodPart,      -- on-tree visual, respawning
--     respawnAt,
--     ground,        -- { foodId, xp, marker } | nil
--     respawnToken,
--   } },
-- }
local state = {}
local groundToSlot = {}
local remoteClickBuckets = {}

local function feedTypeOf(machine)
	local feedType = machine:GetAttribute(State.Feed.Type)
	if type(feedType) == "string" and feedType ~= "" then
		return feedType
	end
	return nil
end

local function balanceFor(machine)
	local feedType = feedTypeOf(machine)
	if not feedType then return nil end
	local balance = BALANCES[feedType]
	if balance then return balance end

	return {
		FeedType = feedType,
		WarnPrefix = feedType,
		SlotRespawn = DEFAULT_BALANCE.SlotRespawn,
		DropEffectDuration = DEFAULT_BALANCE.DropEffectDuration,
		EffectRadius = DEFAULT_BALANCE.EffectRadius,
	}
end

local function foodDropFor(machine, balance)
	local foodId = machine:GetAttribute(State.Feed.FoodDrop)
	if type(foodId) ~= "string" or foodId == "" then
		warn(string.format("[%s] missing %s attribute on %s", balance.WarnPrefix, State.Feed.FoodDrop, machine:GetFullName()))
		return nil
	end
	if not Food.GetTemplate(foodId) then
		warn(string.format("[%s] unknown %s %q on %s", balance.WarnPrefix, State.Feed.FoodDrop, foodId, machine:GetFullName()))
		return nil
	end
	return foodId
end

local function dropXPFor(foodId)
	local t = Food.GetTemplate(foodId)
	return t and (t:GetAttribute(State.Food.XP) or 1) or 1
end

local function xpMultiplierFor(machine)
	local multiplier = machine:GetAttribute(State.Feed.XP)
	if type(multiplier) ~= "number" or multiplier <= 0 then
		return 1
	end
	return multiplier
end

local function clickIntervalFor()
	return 1 / MAX_CLICKS_PER_SECOND
end

local function userKey(player)
	return player and player.UserId or nil
end

local function allowRemoteTreeClick(player)
	local key = userKey(player)
	if key == nil then
		return false
	end

	local now = os.clock()
	local bucket = remoteClickBuckets[key]
	if not bucket then
		bucket = {
			tokens = REMOTE_CLICK_BURST,
			updatedAt = now,
		}
		remoteClickBuckets[key] = bucket
	end

	local elapsed = math.max(0, now - bucket.updatedAt)
	bucket.updatedAt = now
	bucket.tokens = math.min(REMOTE_CLICK_BURST, bucket.tokens + (elapsed * REMOTE_CLICK_REFILL_RATE))
	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens -= 1
	return true
end

-- ── Slot visuals (cosmetic on-tree fruits) ────────────────────────────────────

local function configureSlotPart(part)
	part.Anchored       = true
	part.CanCollide     = false
	-- CanQuery=false so the trunk's ClickDetector raycast hits the trunk,
	-- not the on-tree fruit visual hanging in front of it.
	part.CanQuery       = false
	part.CanTouch       = false
	part.CollisionGroup = FRUIT_GROUP
end

local function disableBakedBillboards(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			descendant.Enabled = false
		end
	end
end

local function spawnSlotVisual(slot, foodId)
	local template = Food.GetTemplate(foodId)
	if not template then return nil end
	local clone = template:Clone()
	disableBakedBillboards(clone)
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

local function clearSlotVisual(slot)
	if slot.foodPart then
		slot.foodPart:Destroy()
		slot.foodPart = nil
	end
end

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

local function configureMarker(marker)
	marker.Anchored       = true
	marker.CanCollide     = false
	marker.CanQuery       = false
	marker.CanTouch       = false
	marker.Transparency   = 1
	marker.CollisionGroup = FRUIT_GROUP
end

-- ── Ground fruit state ────────────────────────────────────────────────────────

local function setGroundMarkerState(marker, slot, foodId, xp, mutationIds, primaryMutationId)
	marker:SetAttribute(State.TreeClicker.GroundPile, true)
	marker:SetAttribute(State.TreeClicker.SlotIndex, slot.n)
	marker:SetAttribute(State.Food.Id, foodId)
	marker:SetAttribute(State.Food.Type, Food.TypeFor(foodId))
	marker:SetAttribute(State.Food.XP, xp)
	Mutations.ApplyAttribute(marker, mutationIds, primaryMutationId)
	marker:SetAttribute(State.Food.StealReservationId, slot.ground and slot.ground.stealReservationId or nil)
	marker:SetAttribute(State.Food.StealReservationExpiresAt, slot.ground and slot.ground.stealReservationExpiresAt or nil)
end

local function clearGroundMarkerState(marker)
	marker:SetAttribute(State.TreeClicker.GroundPile, nil)
	marker:SetAttribute(State.TreeClicker.SlotIndex, nil)
	marker:SetAttribute(State.Food.Id, nil)
	marker:SetAttribute(State.Food.Type, nil)
	marker:SetAttribute(State.Food.XP, nil)
	marker:SetAttribute(State.Food.MutationIds, nil)
	marker:SetAttribute(State.Food.PrimaryMutationId, nil)
	marker:SetAttribute(State.Food.StealReservationId, nil)
	marker:SetAttribute(State.Food.StealReservationExpiresAt, nil)
end

local function destroySlotGround(slot)
	if not slot.ground then return end
	groundToSlot[slot.ground.marker] = nil
	clearGroundMarkerState(slot.ground.marker)
	slot.ground = nil
end

local function clearGroundStealReservation(slot)
	if not slot or not slot.ground then
		return
	end
	slot.ground.stealReservationId = nil
	slot.ground.stealReservationExpiresAt = nil
	slot.ground.marker:SetAttribute(State.Food.StealReservationId, nil)
	slot.ground.marker:SetAttribute(State.Food.StealReservationExpiresAt, nil)
end

local function clearExpiredGroundStealReservation(slot)
	if not slot or not slot.ground or slot.ground.stealReservationId == nil then
		return false
	end
	local expiresAt = tonumber(slot.ground.stealReservationExpiresAt)
	if expiresAt and expiresAt > os.time() then
		return false
	end
	clearGroundStealReservation(slot)
	return true
end

local function setGroundStealReservation(slot, reservationId, expiresAt)
	if not slot or not slot.ground then
		return
	end
	if type(reservationId) == "string" and reservationId ~= "" then
		slot.ground.stealReservationId = reservationId
		slot.ground.stealReservationExpiresAt = tonumber(expiresAt) or os.time()
		slot.ground.marker:SetAttribute(State.Food.StealReservationId, slot.ground.stealReservationId)
		slot.ground.marker:SetAttribute(State.Food.StealReservationExpiresAt, slot.ground.stealReservationExpiresAt)
	else
		clearGroundStealReservation(slot)
	end
end

local function addGroundReservationRecord(record, ground)
	if type(ground.stealReservationId) == "string" and ground.stealReservationId ~= "" then
		record.stealReservationId = ground.stealReservationId
		record.stealReservationExpiresAt = ground.stealReservationExpiresAt
	end
	return record
end

-- forward decl so handlers can call each other
local pickupSlotGround
local function spawnSlotGround(machine, s, slot, foodId, xp, mutationIds, primaryMutationId)
	mutationIds = Mutations.SanitizeList(mutationIds)
	primaryMutationId = Mutations.Primary(mutationIds, primaryMutationId)
	setGroundMarkerState(slot.marker, slot, foodId, xp, mutationIds, primaryMutationId)
	slot.ground = {
		foodId   = foodId,
		xp       = xp,
		mutationIds = mutationIds,
		primaryMutationId = primaryMutationId,
		marker   = slot.marker,
		stealReservationId = nil,
	}
	groundToSlot[slot.marker] = {
		machine = machine,
		state = s,
		slot = slot,
	}
end

local function addXPToSlotGround(slot, deltaXP)
	if not slot.ground then return end
	slot.ground.xp = slot.ground.xp + deltaXP
	slot.ground.marker:SetAttribute(State.Food.XP, slot.ground.xp)
end

pickupSlotGround = function(machine, s, slot, player)
	if player ~= s.owner then return false end
	if s.owner:GetAttribute("EditMode") == true then return false end
	if not slot.ground then return false end
	clearExpiredGroundStealReservation(slot)
	if slot.ground.stealReservationId ~= nil then return false end
	local tool = Food.MakeTool(slot.ground.foodId, slot.ground.xp, slot.ground.mutationIds, slot.ground.primaryMutationId)
	if not tool then return false end
	if not ToolGrantService.GrantTool(player, tool, {
		deferAutoEquip = true,
		autoEquipPolicy = "firstInBurst",
		autoEquipBurstGap = 3,
	}) then
		tool:Destroy()
		return false
	end
	local groundMarker = slot.ground.marker
	local profile = PlayerDataService.GetProfile(player)
	if profile then
		OnboardingService.OnTreeFruitPicked(player, profile, machine, groundMarker)
	end
	destroySlotGround(slot)
	return true, machine
end

local function applyDrop(machine, s, slot, foodId, player)
	if not state[machine] then return end
	local dropXP = dropXPFor(foodId) * xpMultiplierFor(machine)
	local dropped = false
	if slot.ground then
		clearExpiredGroundStealReservation(slot)
		if slot.ground.stealReservationId ~= nil then
			return
		end
		addXPToSlotGround(slot, dropXP)
		dropped = true
	else
		spawnSlotGround(machine, s, slot, foodId, dropXP)
		dropped = slot.ground ~= nil
	end
	if not dropped then
		return
	end
	local profile = player and PlayerDataService.GetProfile(player)
	if profile then
		OnboardingService.OnTreeClicked(player, profile, machine, foodId, slot.n)
	end
end

local function readySlots(s)
	local ready = {}
	for _, slot in ipairs(s.slots) do
		if slot.foodPart and not slot.respawnAt then
			table.insert(ready, slot)
		end
	end
	return ready
end

local function findReadySlot(s)
	local ready = readySlots(s)
	if #ready == 0 then return nil end
	return ready[math.random(1, #ready)]
end

local function isPlayerNear(player, origin, radius)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil and root:IsA("BasePart") and (root.Position - origin).Magnitude <= radius
end

local function isPlayerNearTree(player, machine)
	local primary = machine and machine.PrimaryPart
	return primary ~= nil and isPlayerNear(player, primary.Position, CLICK_DISTANCE)
end

local function leafShakePart(machine)
	local part = machine and machine:FindFirstChild(TREE_CLICK_TARGET_NAME, true)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function configureLeafShakePart(part)
	part.CanQuery = true
	part.CanCollide = false
	part.CanTouch = false
end

local function treeClickTargets(machine)
	local targets = {}
	local leafShake = leafShakePart(machine)
	if leafShake then
		configureLeafShakePart(leafShake)
		targets[#targets + 1] = leafShake
	end

	local primary = machine and machine.PrimaryPart
	if primary and primary:IsA("BasePart") and primary ~= leafShake then
		targets[#targets + 1] = primary
	end
	return targets
end

local function fireEffectNearby(machine, balance, anchor, marker, foodId, triggeringPlayer, effectOptions)
	effectOptions = type(effectOptions) == "table" and effectOptions or {}
	local effectRadius = tonumber(effectOptions.effectRadius) or balance.EffectRadius
	local includeTriggeringPlayer = effectOptions.includeTriggeringPlayer ~= false
	local origin = anchor.Position
	local payload = {
		machine = machine,
		anchor = anchor,
		marker = marker,
		foodId = foodId,
		duration = balance.DropEffectDuration,
		playSound = effectOptions.playSound ~= false,
		shakeTree = effectOptions.shakeTree ~= false,
	}
	for _, player in ipairs(Players:GetPlayers()) do
		if (includeTriggeringPlayer and player == triggeringPlayer) or isPlayerNear(player, origin, effectRadius) then
			RuntimeGuard.Run("TreeClicker.EffectFireClient", function()
				TreeClickerEffect:FireClient(player, payload)
			end)
		end
	end
end

local function scheduleSlotRespawn(machine, s, slot)
	slot.respawnToken = (slot.respawnToken or 0) + 1
	local token = slot.respawnToken
	slot.respawnAt = os.clock() + s.balance.SlotRespawn

	task.delay(s.balance.SlotRespawn, function()
		RuntimeGuard.Run("TreeClicker.SlotRespawn", function()
			if state[machine] ~= s or slot.respawnToken ~= token or not slot.respawnAt then
				return
			end
			slot.respawnAt = nil
			slot.foodPart = spawnSlotVisual(slot, s.foodDrop)
		end)
	end)
end

local function triggerReadySlotDrop(machine, s, slot, player, effectOptions)
	if not (slot and slot.foodPart and not slot.respawnAt) then
		return false
	end

	clearSlotVisual(slot)
	scheduleSlotRespawn(machine, s, slot)

	local foodId = s.foodDrop
	fireEffectNearby(machine, s.balance, slot.anchor, slot.marker, foodId, player, effectOptions)
	task.delay(s.balance.DropEffectDuration, function()
		RuntimeGuard.Run("TreeClicker.ApplyDrop", applyDrop, machine, s, slot, foodId, player)
	end)
	return true
end

local function onTreeClicked(machine, s, player, effectOptions)
	if player ~= s.owner then return false end
	if s.owner:GetAttribute("EditMode") == true then return false end

	local clickInterval = clickIntervalFor()
	local now = os.clock()
	if now - s.lastClick < clickInterval then return false end

	local slot = findReadySlot(s)
	if not slot then return false end

	if not triggerReadySlotDrop(machine, s, slot, player, effectOptions) then
		return false
	end
	s.lastClick = now
	return true
end

-- ── Setup / teardown ──────────────────────────────────────────────────────────

local function suffixNumber(name: string, prefix: string)
	local suffix = name:match("^" .. prefix .. "(%d+)$")
	return suffix and tonumber(suffix) or nil
end

local function slotParts(machine, prefix)
	local parts = {}
	for _, descendant in ipairs(machine:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local n = suffixNumber(descendant.Name, prefix)
			if n then
				table.insert(parts, { n = n, part = descendant })
			end
		end
	end
	table.sort(parts, function(a, b) return a.n < b.n end)
	return parts
end

local function setupSlots(machine, s)
	-- Index the ground markers by their numeric suffix.
	local markers = {}
	for _, entry in ipairs(slotParts(machine, "BaseFoodGround")) do
		markers[entry.n] = entry.part
		configureMarker(entry.part)
	end

	-- Then walk BaseFoodN slots and pair each with its same-numbered marker.
	for _, entry in ipairs(slotParts(machine, "BaseFood")) do
		local n = entry.n
		local child = entry.part
		local marker = markers[n]
		if not marker then
			warn(string.format(
				"[%s] BaseFood%d has no matching BaseFoodGround%d on %s",
				s.balance.WarnPrefix, n, n, machine:GetFullName()
			))
		else
			local anchor = makeSlotAnchor(machine, child)
			child:Destroy()
			local slot = {
				n         = n,
				anchor    = anchor,
				marker    = marker,
				foodPart  = nil,
				respawnAt = nil,
				ground    = nil,
			}
			slot.foodPart = spawnSlotVisual(slot, s.foodDrop)
			table.insert(s.slots, slot)
		end
	end

	table.sort(s.slots, function(a, b) return a.n < b.n end)
end

local function setupClickDetector(machine, s)
	for _, target in ipairs(treeClickTargets(machine)) do
		local detector = Instance.new("ClickDetector")
		detector.Name = "TreeClickDetector"
		detector.MaxActivationDistance = CLICK_DISTANCE
		detector.Parent = target
		table.insert(s.detectors, detector)
		table.insert(s.conns, RuntimeGuard.Connect(detector.MouseClick, "TreeClicker.MouseClick", function(player)
			onTreeClicked(machine, s, player)
		end))
	end
end

function TreeClicker.Setup(machine, plot, owner)
	local balance = balanceFor(machine)
	if not balance then
		warn(string.format("[TreeClicker] unknown %s %q", State.Feed.Type, tostring(feedTypeOf(machine))))
		return
	end
	if not machine:IsA("Model") or not machine.PrimaryPart then
		warn(string.format("[%s] expected Model with PrimaryPart", balance.WarnPrefix))
		return
	end
	local foodDrop = foodDropFor(machine, balance)
	if not foodDrop then return end

	-- Tag the plot's Floor so AppleTree fruits can physically collide
	-- with it (and only it). Idempotent across multiple AppleTrees on
	-- the same plot.
	local floor = plot:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") and floor.CollisionGroup ~= FLOOR_GROUP then
		floor.CollisionGroup = FLOOR_GROUP
	end

	local s = {
		balance   = balance,
		foodDrop = foodDrop,
		owner     = owner,
		plot      = plot,
		lastClick = 0,
		slots     = {},
		conns     = {},
		detectors = {},
	}
	state[machine] = s

	setupSlots(machine, s)
	setupClickDetector(machine, s)

end

function TreeClicker.Teardown(machine)
	local s = state[machine]
	if not s then return end
	for _, c in ipairs(s.conns) do c:Disconnect() end
	for _, detector in ipairs(s.detectors) do
		if detector.Parent then
			detector:Destroy()
		end
	end
	for _, slot in ipairs(s.slots) do
		slot.respawnToken = (slot.respawnToken or 0) + 1
		destroySlotGround(slot)
	end
	state[machine] = nil
end

local function onTreeClickRequest(player, machine)
	if not allowRemoteTreeClick(player) then
		return
	end
	if typeof(machine) ~= "Instance" or not machine:IsA("Model") then
		return
	end
	local s = state[machine]
	if not s or not machine:IsDescendantOf(s.plot) then
		return
	end
	if not isPlayerNearTree(player, machine) then
		return
	end
	onTreeClicked(machine, s, player)
end

RuntimeGuard.Connect(TreeClickerRequest.OnServerEvent, "TreeClicker.Request", onTreeClickRequest)
RuntimeGuard.Connect(Players.PlayerRemoving, "TreeClicker.PlayerRemoving", function(player)
	local key = userKey(player)
	if key ~= nil then
		remoteClickBuckets[key] = nil
	end
end)

-- Persist piles per slot. Position is regenerated from each slot's
-- BaseFoodGround marker on Apply, so we only save foodId + xp.
function TreeClicker.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local piles = {}
	local any = false
	for _, slot in ipairs(s.slots) do
		if slot.ground then
			piles[tostring(slot.n)] = addGroundReservationRecord({
				foodId = slot.ground.foodId,
				xp = slot.ground.xp,
				mutationIds = slot.ground.mutationIds,
				primaryMutationId = slot.ground.primaryMutationId,
			}, slot.ground)
			any = true
		end
	end
	if not any then return nil end
	return { piles = piles }
end

function TreeClicker.Apply(machine, placement)
	local s = state[machine]
	if not s or type(placement) ~= "table" then return end
	local piles = placement.piles
	if type(piles) ~= "table" then return end

	for _, slot in ipairs(s.slots) do
		local entry = piles[tostring(slot.n)]
		if type(entry) == "table" then
			local xp = math.max(tonumber(entry.xp) or 0, 0)
			destroySlotGround(slot)
			local foodId = Food.GetTemplate(entry.foodId) and entry.foodId or s.foodDrop
			spawnSlotGround(machine, s, slot, foodId, xp, entry.mutationIds or entry.mutations, entry.primaryMutationId or entry.primaryMutation)
			setGroundStealReservation(slot, entry.stealReservationId, entry.stealReservationExpiresAt)
		end
	end
end

function TreeClicker.PickupGround(ground, player)
	if not ground then return false end
	local current = ground
	while current do
		local record = groundToSlot[current]
		if record and record.machine.Parent and state[record.machine] == record.state then
			return pickupSlotGround(record.machine, record.state, record.slot, player)
		end
		current = current.Parent
	end
	return false
end

local function reserveSlotGroundForCollectAll(machine, slot, reservationId, expiresAt)
	if not (slot and slot.ground) then
		return nil
	end
	clearExpiredGroundStealReservation(slot)
	if slot.ground.stealReservationId ~= nil then
		return nil
	end

	slot.ground.stealReservationId = reservationId
	slot.ground.stealReservationExpiresAt = tonumber(expiresAt) or os.time()
	slot.ground.marker:SetAttribute(State.Food.StealReservationId, reservationId)
	slot.ground.marker:SetAttribute(State.Food.StealReservationExpiresAt, slot.ground.stealReservationExpiresAt)
	return {
		sourceKind = "Tree",
		sourceFeedIndex = machine:GetAttribute(State.Feed.Index),
		sourceSlotIndex = slot.n,
		foodId = slot.ground.foodId,
		xp = slot.ground.xp,
		mutationIds = slot.ground.mutationIds,
		primaryMutationId = slot.ground.primaryMutationId,
	}
end

function TreeClicker.ReserveCollectAll(machine, player, reservationId, expiresAt, limit)
	local s = machine and state[machine]
	if not (s and machine.Parent) then return false, "not-ready" end
	if player ~= s.owner then return false, "not-owner" end
	if s.owner:GetAttribute("EditMode") == true then return false, "edit-mode" end
	if type(reservationId) ~= "string" or reservationId == "" then return false, "invalid-reservation" end

	limit = math.max(math.floor(tonumber(limit) or 0), 0)
	local items = {}
	for _, slot in ipairs(s.slots) do
		if limit > 0 and #items >= limit then
			break
		end
		local item = reserveSlotGroundForCollectAll(machine, slot, reservationId, expiresAt)
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
		return nil
	end
	local slotIndex = tonumber(item and item.sourceSlotIndex)
	for _, slot in ipairs(s.slots) do
		if slot.n == slotIndex then
			return slot
		end
	end
	return nil
end

function TreeClicker.ReleaseCollectAll(machine, item, reservationId)
	local slot = slotForCollectAllItem(machine, item)
	if not slot or not slot.ground or slot.ground.stealReservationId ~= reservationId then
		return false
	end
	clearGroundStealReservation(slot)
	return true
end

function TreeClicker.CommitCollectAll(machine, item, reservationId)
	local slot = slotForCollectAllItem(machine, item)
	if not slot or not slot.ground or slot.ground.stealReservationId ~= reservationId then
		return false
	end
	destroySlotGround(slot)
	return true, machine
end

local function recordForGround(ground)
	local current = ground
	while current do
		local record = groundToSlot[current]
		if record and record.machine.Parent and state[record.machine] == record.state then
			return record
		end
		current = current.Parent
	end
	return nil
end

function TreeClicker.CollectMutationTargets(machine, mutationId)
	local s = machine and state[machine]
	if not (s and machine.Parent) then
		return {}
	end
	local targets = {}
	for _, slot in ipairs(s.slots) do
		clearExpiredGroundStealReservation(slot)
		if slot.ground
			and slot.ground.stealReservationId == nil
			and not Mutations.Contains(slot.ground.mutationIds, mutationId) then
			targets[#targets + 1] = {
				kind = "Tree",
				machine = machine,
				targetKey = slot.n,
				position = slot.marker.Position,
				foodId = slot.ground.foodId,
			}
		end
	end
	return targets
end

function TreeClicker.ApplyMutation(machine, targetKey, mutationId)
	local s = machine and state[machine]
	if not s then
		return false, "not-ready"
	end
	targetKey = tonumber(targetKey)
	local slot = nil
	for _, candidate in ipairs(s.slots) do
		if candidate.n == targetKey then
			slot = candidate
			break
		end
	end
	if not (slot and slot.ground) then
		return false, "no-food"
	end
	clearExpiredGroundStealReservation(slot)
	if slot.ground.stealReservationId ~= nil then
		return false, "reserved"
	end
	local nextMutationIds, added = Mutations.Add(slot.ground.mutationIds, mutationId)
	if not added then
		return false, "already-mutated"
	end
	local multiplier = Mutations.XPMultiplier(mutationId) or 1
	slot.ground.xp *= multiplier
	slot.ground.mutationIds = nextMutationIds
	slot.ground.primaryMutationId = mutationId
	setGroundMarkerState(slot.ground.marker, slot, slot.ground.foodId, slot.ground.xp, nextMutationIds, slot.ground.primaryMutationId)
	return true, {
		position = slot.ground.marker.Position,
		foodId = slot.ground.foodId,
		mutationIds = nextMutationIds,
		primaryMutationId = slot.ground.primaryMutationId,
	}
end

function TreeClicker.ReserveStealTarget(ground, player, reservationId, expiresAt)
	if type(reservationId) ~= "string" or reservationId == "" then return false, "invalid-reservation" end
	local record = recordForGround(ground)
	if not record then return false, "not-tree-ground" end
	local machine = record.machine
	local s = record.state
	local slot = record.slot
	if player == s.owner then return false, "own-food" end
	if s.owner and s.owner:GetAttribute("EditMode") == true then return false, "source-edit-mode" end
	if not slot.ground then return false, "no-food" end
	clearExpiredGroundStealReservation(slot)
	if slot.ground.stealReservationId ~= nil then return false, "reserved" end

	slot.ground.stealReservationId = reservationId
	slot.ground.stealReservationExpiresAt = tonumber(expiresAt) or os.time()
	slot.ground.marker:SetAttribute(State.Food.StealReservationId, reservationId)
	slot.ground.marker:SetAttribute(State.Food.StealReservationExpiresAt, slot.ground.stealReservationExpiresAt)
	return true, {
			foodId = slot.ground.foodId,
			xp = slot.ground.xp,
			mutationIds = slot.ground.mutationIds,
			primaryMutationId = slot.ground.primaryMutationId,
			sourceKind = "Tree",
		sourceOwnerUserId = s.owner and s.owner.UserId or 0,
		sourceFeedIndex = machine:GetAttribute(State.Feed.Index),
		sourceSlotIndex = slot.n,
	}, machine
end

local function slotForReservation(machine, reservation)
	local s = machine and state[machine]
	if not s then return nil end
	local slotIndex = reservation and reservation.sourceSlotIndex
	for _, slot in ipairs(s.slots) do
		if slot.n == slotIndex then
			return slot
		end
	end
	return nil
end

function TreeClicker.ReleaseSteal(machine, reservation, reservationId)
	local slot = slotForReservation(machine, reservation)
	if not slot or not slot.ground or slot.ground.stealReservationId ~= reservationId then return false end
	clearGroundStealReservation(slot)
	return true
end

function TreeClicker.CommitSteal(machine, reservation, reservationId)
	local slot = slotForReservation(machine, reservation)
	if not slot or not slot.ground or slot.ground.stealReservationId ~= reservationId then return false end
	destroySlotGround(slot)
	return true, machine
end

function TreeClicker.TriggerDrop(machine, player, effectOptions)
	local s = machine and state[machine]
	if not (s and machine.Parent) then
		return false, "not-setup"
	end
	if player ~= s.owner then
		return false, "not-owner"
	end
	return onTreeClicked(machine, s, player, effectOptions)
end

function TreeClicker.TriggerWindWave(machine, player, amount, effectOptions)
	local s = machine and state[machine]
	if not (s and machine.Parent) then
		return false, "not-setup"
	end
	if player ~= s.owner then
		return false, "not-owner"
	end
	if s.owner:GetAttribute("EditMode") == true then
		return false, "edit-mode"
	end

	amount = math.max(math.floor(tonumber(amount) or 0), 0)
	if amount <= 0 then
		return false, "invalid-amount"
	end

	local ready = readySlots(s)
	if #ready == 0 then
		return false, "no-ready-slots"
	end

	local dropped = 0
	for dropIndex = 1, math.min(amount, #ready) do
		local slot = table.remove(ready, math.random(1, #ready))
		local dropOptions = {}
		if type(effectOptions) == "table" then
			for key, value in pairs(effectOptions) do
				dropOptions[key] = value
			end
		end
		if dropIndex > 1 then
			dropOptions.playSound = false
			dropOptions.shakeTree = false
		end
		if triggerReadySlotDrop(machine, s, slot, player, dropOptions) then
			dropped += 1
		end
	end

	if dropped <= 0 then
		return false, "no-drops"
	end
	return true, dropped
end

function TreeClicker.StressClick(machine, player)
	if not RunService:IsStudio() then
		return false, "not-studio"
	end
	return TreeClicker.TriggerDrop(machine, player)
end

return TreeClicker
