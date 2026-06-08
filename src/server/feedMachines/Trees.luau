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

local Server = script.Parent.Parent
local OnboardingService = require(Server:WaitForChild("OnboardingService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food   = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State  = require(Shared:WaitForChild("State"))

local TreeBalance = script.Parent:WaitForChild("Tree")
local AppleTreeBalance = require(TreeBalance:WaitForChild("AppleTreeBalance"))
local CherryTreeBalance = require(TreeBalance:WaitForChild("CherryTreeBalance"))

local TreeClickerEffect = Remotes.get(Remotes.Names.TreeClickerEffect)

local MAX_CLICKS_PER_SECOND = 5

local DEFAULT_BALANCE = {
	SlotRespawn = 1,
	DropEffectDuration = 0.45,
	EffectRadius = 75,
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
--   owner, plot, balance, foodDrop, lastClick, conns,
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

local function setGroundMarkerState(marker, slot, foodId, xp)
	marker:SetAttribute(State.TreeClicker.GroundPile, true)
	marker:SetAttribute(State.TreeClicker.SlotIndex, slot.n)
	marker:SetAttribute(State.Food.Id, foodId)
	marker:SetAttribute(State.Food.Type, Food.TypeFor(foodId))
	marker:SetAttribute(State.Food.XP, xp)
end

local function clearGroundMarkerState(marker)
	marker:SetAttribute(State.TreeClicker.GroundPile, nil)
	marker:SetAttribute(State.TreeClicker.SlotIndex, nil)
	marker:SetAttribute(State.Food.Id, nil)
	marker:SetAttribute(State.Food.Type, nil)
	marker:SetAttribute(State.Food.XP, nil)
end

local function destroySlotGround(slot)
	if not slot.ground then return end
	groundToSlot[slot.ground.marker] = nil
	clearGroundMarkerState(slot.ground.marker)
	slot.ground = nil
end

-- forward decl so handlers can call each other
local pickupSlotGround
local function spawnSlotGround(machine, s, slot, foodId, xp)
	setGroundMarkerState(slot.marker, slot, foodId, xp)
	slot.ground = {
		foodId   = foodId,
		xp       = xp,
		marker   = slot.marker,
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
	local tool = Food.MakeTool(slot.ground.foodId, slot.ground.xp)
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

local function findReadySlot(s)
	local ready = {}
	for _, slot in ipairs(s.slots) do
		if slot.foodPart and not slot.respawnAt then
			table.insert(ready, slot)
		end
	end
	if #ready == 0 then return nil end
	return ready[math.random(1, #ready)]
end

local function isPlayerNear(player, origin, radius)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil and root:IsA("BasePart") and (root.Position - origin).Magnitude <= radius
end

local function fireEffectNearby(machine, balance, anchor, marker, foodId)
	local origin = anchor.Position
	local payload = {
		machine = machine,
		anchor = anchor,
		marker = marker,
		foodId = foodId,
		duration = balance.DropEffectDuration,
	}
	for _, player in ipairs(Players:GetPlayers()) do
		if isPlayerNear(player, origin, balance.EffectRadius) then
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

local function onTreeClicked(machine, s, player)
	if player ~= s.owner then return end
	if s.owner:GetAttribute("EditMode") == true then return end

	local clickInterval = clickIntervalFor()
	local now = os.clock()
	if now - s.lastClick < clickInterval then return end

	local slot = findReadySlot(s)
	if not slot then return end

	clearSlotVisual(slot)
	scheduleSlotRespawn(machine, s, slot)
	s.lastClick = now

	local foodId = s.foodDrop
	fireEffectNearby(machine, s.balance, slot.anchor, slot.marker, foodId)
	task.delay(s.balance.DropEffectDuration, function()
		RuntimeGuard.Run("TreeClicker.ApplyDrop", applyDrop, machine, s, slot, foodId, player)
	end)
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
	local primary = machine.PrimaryPart
	if not primary then return end
	local detector = Instance.new("ClickDetector")
	detector.MaxActivationDistance = 24
	detector.Parent = primary
	table.insert(s.conns, RuntimeGuard.Connect(detector.MouseClick, "TreeClicker.MouseClick", function(player)
		onTreeClicked(machine, s, player)
	end))
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
	}
	state[machine] = s

	setupSlots(machine, s)
	setupClickDetector(machine, s)

end

function TreeClicker.Teardown(machine)
	local s = state[machine]
	if not s then return end
	for _, c in ipairs(s.conns) do c:Disconnect() end
	for _, slot in ipairs(s.slots) do
		slot.respawnToken = (slot.respawnToken or 0) + 1
		destroySlotGround(slot)
	end
	state[machine] = nil
end

-- Persist piles per slot. Position is regenerated from each slot's
-- BaseFoodGround marker on Apply, so we only save foodId + xp.
function TreeClicker.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local piles = {}
	local any = false
	for _, slot in ipairs(s.slots) do
		if slot.ground then
			piles[tostring(slot.n)] = {
				foodId = slot.ground.foodId,
				xp     = slot.ground.xp,
			}
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
			spawnSlotGround(machine, s, slot, s.foodDrop, xp)
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

return TreeClicker
