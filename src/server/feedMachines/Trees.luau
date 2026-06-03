-- Shared tree-clicker FeedMachine implementation for AppleTree/CherryTree.
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
-- Ground pile models replicate with TreeClickerGroundPile, FoodId, FoodType,
-- XP, and TreeClickerSlotIndex attributes.
-- Clients render XP billboards from those attributes. Pickup gives a Tool with
-- the pile's current foodId + accumulated XP and clears that slot only.
--
-- Tunable attributes on the template:
--   FoodDrop           (string, food id dropped by each accepted click)
--   XP                 (number, default 1; multiplier applied to each drop's XP)
-- Timing tunables come from per-tree balance modules.

local PhysicsService    = game:GetService("PhysicsService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
-- only with the plot Floor. Drops are now visual client tweens, but ground
-- fruit still uses this setup so prompts and floor placement behave cleanly.
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
--     ground,        -- { foodId, xp, model, primary, prompt, conn } | nil
--   } },
-- }
local state = {}

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

local function groundFolder(machine)
	local folder = machine:FindFirstChild(State.TreeClicker.GroundFolder)
	if folder and folder:IsA("Folder") then return folder end

	if folder then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = State.TreeClicker.GroundFolder
	folder.Parent = machine
	return folder
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

-- ── Ground fruit ──────────────────────────────────────────────────────────────

local function configureGroundPart(part, isPrimary)
	part.Anchored       = true
	-- Primary remains queryable for client-local prompts and click targeting.
	-- CanCollide stays true on the primary, but FRUIT_GROUP rules mean it only
	-- physical-collides with the Floor it sits on.
	part.CanCollide     = isPrimary
	part.CanQuery       = isPrimary
	part.CanTouch       = isPrimary
	part.CollisionGroup = FRUIT_GROUP
end

local function fruitHalfHeight(foodId)
	local template = Food.GetTemplate(foodId)
	if not template then return 0 end
	if template:IsA("BasePart") then return template.Size.Y / 2 end
	if template:IsA("Model") and template.PrimaryPart then return template.PrimaryPart.Size.Y / 2 end
	return 0
end

local function groundCFrame(marker, foodId)
	-- Snap the ground fruit so its bottom aligns with the marker's
	-- bottom (the marker sits on the floor at design time, so this puts
	-- the fruit cleanly on the floor too).
	local dy = fruitHalfHeight(foodId) - marker.Size.Y / 2
	return marker.CFrame * CFrame.new(0, dy, 0)
end

local function makeGroundFruitVisual(foodId, worldCF)
	local template = Food.GetTemplate(foodId)
	if not template then return nil, nil end
	local visual, primary
	if template:IsA("BasePart") then
		visual  = template:Clone()
		primary = visual
		configureGroundPart(visual, true)
		visual.CFrame = worldCF
	elseif template:IsA("Model") then
		if not template.PrimaryPart then return nil, nil end
		visual  = template:Clone()
		primary = visual.PrimaryPart
		for _, d in ipairs(visual:GetDescendants()) do
			if d:IsA("BasePart") then configureGroundPart(d, d == primary) end
		end
		visual:PivotTo(worldCF)
	end
	if not visual or not primary then
		if visual then visual:Destroy() end
		return nil, nil
	end
	return visual, primary
end

local function destroySlotGround(slot)
	if not slot.ground then return end
	if slot.ground.model and slot.ground.model.Parent then slot.ground.model:Destroy() end
	slot.ground = nil
end

-- forward decl so handlers can call each other
local pickupSlotGround
local function spawnSlotGround(machine, s, slot, foodId, xp)
	local visual, primary = makeGroundFruitVisual(foodId, groundCFrame(slot.marker, foodId))
	if not visual then return end

	visual:SetAttribute(State.TreeClicker.GroundPile, true)
	visual:SetAttribute(State.TreeClicker.SlotIndex, slot.n)
	visual:SetAttribute(State.Food.Id, foodId)
	visual:SetAttribute(State.Food.Type, Food.TypeFor(foodId))
	visual:SetAttribute(State.Food.XP, xp)
	visual.Parent = groundFolder(machine)

	slot.ground = {
		foodId   = foodId,
		xp       = xp,
		model    = visual,
		primary  = primary,
	}
end

local function addXPToSlotGround(slot, deltaXP)
	if not slot.ground then return end
	slot.ground.xp = slot.ground.xp + deltaXP
	slot.ground.model:SetAttribute(State.Food.XP, slot.ground.xp)
end

pickupSlotGround = function(machine, s, slot, player)
	if player ~= s.owner then return end
	if s.owner:GetAttribute("EditMode") == true then return end
	if not slot.ground then return end
	local tool = Food.MakeTool(slot.ground.foodId, slot.ground.xp)
	if not tool then return end
	tool.Parent = player.Backpack
	destroySlotGround(slot)
end

local function applyDrop(machine, s, slot, foodId)
	if not state[machine] then return end
	local dropXP = dropXPFor(foodId) * xpMultiplierFor(machine)
	if slot.ground then
		addXPToSlotGround(slot, dropXP)
	else
		spawnSlotGround(machine, s, slot, foodId, dropXP)
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

local function tickRespawns(s)
	local now = os.clock()
	for _, slot in ipairs(s.slots) do
		if slot.respawnAt and now >= slot.respawnAt then
			slot.respawnAt = nil
			slot.foodPart  = spawnSlotVisual(slot, s.foodDrop)
		end
	end
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

-- Single 4Hz heartbeat across all AppleTree machines.
RuntimeGuard.Spawn("TreeClicker.RespawnLoop", function()
	while true do
		task.wait(0.25)
		for machine, s in pairs(state) do
			if machine.Parent then
				RuntimeGuard.Run("TreeClicker.TickRespawns", tickRespawns, s)
			end
		end
	end
end)

local function onTreeClicked(machine, s, player)
	if player ~= s.owner then return end
	if s.owner:GetAttribute("EditMode") == true then return end

	local clickInterval = clickIntervalFor()
	local now = os.clock()
	if now - s.lastClick < clickInterval then return end

	local slot = findReadySlot(s)
	if not slot then return end

	clearSlotVisual(slot)
	slot.respawnAt = now + s.balance.SlotRespawn
	s.lastClick = now

	local foodId = s.foodDrop
	fireEffectNearby(machine, s.balance, slot.anchor, slot.marker, foodId)
	task.delay(s.balance.DropEffectDuration, function()
		RuntimeGuard.Run("TreeClicker.ApplyDrop", applyDrop, machine, s, slot, foodId)
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
	for machine, s in pairs(state) do
		if machine.Parent then
			for _, slot in ipairs(s.slots) do
				local model = slot.ground and slot.ground.model
				if model and (ground == model or ground:IsDescendantOf(model)) then
					pickupSlotGround(machine, s, slot, player)
					return true
				end
			end
		end
	end
	return false
end

return TreeClicker
