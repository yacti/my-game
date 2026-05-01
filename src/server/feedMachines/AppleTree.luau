-- Shared tree-clicker FeedMachine implementation for AppleTree/CherryTree.
--
-- Server owns gameplay state: click validation, per-slot piles, XP, pickup
-- prompts, persistence, and chain morphing. Clients own transient visuals:
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
-- Tunable attribute on the template:
--   MaxClicksPerSecond (number, default 5; capped at 5 to limit autoclickers)
--   XPMultiplier       (number, default 1; multiplies XP added per drop)
-- Per-foodId MaxXP is read from each food template's MaxXP attribute.
-- The exact food chain and tunables come from per-tree balance modules.

local PhysicsService    = game:GetService("PhysicsService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food   = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local State  = require(Shared:WaitForChild("State"))

local AppleTreeBalance = require(script.Parent:WaitForChild("AppleTreeBalance"))
local CherryTreeBalance = require(script.Parent:WaitForChild("CherryTreeBalance"))

local TreeClickerEffect = Remotes.get(Remotes.Names.TreeClickerEffect)

-- Collision groups: tree-clicker fruits and ground markers physically collide
-- only with the plot Floor. Drops are now visual client tweens, but ground
-- fruit still uses this setup so prompts and floor placement behave cleanly.
local FRUIT_GROUP = "AppleTreeFruit"
local FLOOR_GROUP = "PlotFloor"

local function ensureCollisionGroups()
	pcall(function() PhysicsService:RegisterCollisionGroup(FRUIT_GROUP) end)
	pcall(function() PhysicsService:RegisterCollisionGroup(FLOOR_GROUP) end)
	PhysicsService:CollisionGroupSetCollidable(FRUIT_GROUP, "Default",   false)
	PhysicsService:CollisionGroupSetCollidable(FRUIT_GROUP, FRUIT_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(FRUIT_GROUP, FLOOR_GROUP, true)
end
ensureCollisionGroups()

local TreeClicker = {}

local BALANCES = {
	[AppleTreeBalance.FeedType] = AppleTreeBalance,
	[CherryTreeBalance.FeedType] = CherryTreeBalance,
}

-- state[machine] = {
--   owner, plot, balance, lastClick, conns,
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
	return machine:GetAttribute(State.Feed.Type) or machine.Name
end

local function balanceFor(machine)
	return BALANCES[feedTypeOf(machine)] or AppleTreeBalance
end

local function maxXPFor(foodId)
	local t = Food.GetTemplate(foodId)
	return t and (t:GetAttribute("MaxXP") or 5) or 5
end

local function dropXPFor(foodId)
	local t = Food.GetTemplate(foodId)
	return t and (t:GetAttribute(State.Food.XP) or 1) or 1
end

local function xpMultiplierFor(machine)
	local multiplier = machine:GetAttribute(State.Feed.XPMultiplier)
	if type(multiplier) ~= "number" or multiplier <= 0 then
		return 1
	end
	return multiplier
end

local function clickIntervalFor(machine)
	local balance = balanceFor(machine)
	local maxClicksPerSecond = machine:GetAttribute(State.Feed.MaxClicksPerSecond)
	if type(maxClicksPerSecond) ~= "number" or maxClicksPerSecond <= 0 then
		maxClicksPerSecond = balance.DefaultMaxClicksPerSecond
	else
		maxClicksPerSecond = math.min(maxClicksPerSecond, balance.DefaultMaxClicksPerSecond)
	end
	return 1 / maxClicksPerSecond
end

local function chainStageOf(balance, foodId)
	for i, id in ipairs(balance.Chain) do if id == foodId then return i end end
	return nil
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

local function spawnSlotVisual(slot, balance)
	local foodId = balance.Chain[1]
	local template = Food.GetTemplate(foodId)
	if not template then return nil end
	local clone = template:Clone()
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
	-- Primary queryable so the ProximityPrompt's LOS raycast has something to
	-- hit. CanCollide stays true on the primary, but FRUIT_GROUP rules mean it
	-- only physical-collides with the Floor it sits on.
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
	if slot.ground.conn then slot.ground.conn:Disconnect() end
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

	local prompt                 = Instance.new("ProximityPrompt")
	prompt.ActionText            = "Pick Up"
	prompt.KeyboardKeyCode       = Enum.KeyCode.E
	prompt.HoldDuration          = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight   = false
	prompt.Enabled               = s.owner:GetAttribute("EditMode") ~= true
	prompt.Parent                = primary

	slot.ground = {
		foodId   = foodId,
		xp       = xp,
		model    = visual,
		primary  = primary,
		prompt   = prompt,
		conn     = nil,
	}
	slot.ground.conn = prompt.Triggered:Connect(function(player)
		if player ~= s.owner then return end
		if s.owner:GetAttribute("EditMode") == true then return end
		pickupSlotGround(machine, s, slot, player)
	end)
end

-- Add XP to the slot's ground fruit; advance through the chain whenever
-- cumulative xp crosses a stage's MaxXP. Past the terminal stage, xp
-- keeps accumulating without further morphs.
local function addXPToSlotGround(machine, s, slot, deltaXP)
	if not slot.ground then return end
	slot.ground.xp = slot.ground.xp + deltaXP
	slot.ground.model:SetAttribute(State.Food.XP, slot.ground.xp)

	local stage    = chainStageOf(s.balance, slot.ground.foodId) or 1
	local advanced = false
	while stage < #s.balance.Chain and slot.ground.xp >= maxXPFor(s.balance.Chain[stage]) do
		stage    = stage + 1
		advanced = true
	end
	if advanced then
		local newType = s.balance.Chain[stage]
		local xp = slot.ground.xp
		destroySlotGround(slot)
		spawnSlotGround(machine, s, slot, newType, xp)
	end
end

pickupSlotGround = function(machine, s, slot, player)
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
		addXPToSlotGround(machine, s, slot, dropXP)
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
			slot.foodPart  = spawnSlotVisual(slot, s.balance)
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
			TreeClickerEffect:FireClient(player, payload)
		end
	end
end

-- Single 4Hz heartbeat across all AppleTree machines.
task.spawn(function()
	while true do
		task.wait(0.25)
		for machine, s in pairs(state) do
			if machine.Parent then tickRespawns(s) end
		end
	end
end)

local function onTreeClicked(machine, s, player)
	if player ~= s.owner then return end
	if s.owner:GetAttribute("EditMode") == true then return end

	local clickInterval = clickIntervalFor(machine)
	local now = os.clock()
	if now - s.lastClick < clickInterval then return end

	local slot = findReadySlot(s)
	if not slot then return end

	clearSlotVisual(slot)
	slot.respawnAt = now + s.balance.SlotRespawn
	s.lastClick = now

	local foodId = s.balance.Chain[1]
	fireEffectNearby(machine, s.balance, slot.anchor, slot.marker, foodId)
	task.delay(s.balance.DropEffectDuration, function()
		applyDrop(machine, s, slot, foodId)
	end)
end

-- ── Setup / teardown ──────────────────────────────────────────────────────────

local function suffixNumber(name: string, prefix: string)
	local suffix = name:match("^" .. prefix .. "(%d+)$")
	return suffix and tonumber(suffix) or nil
end

local function setupSlots(machine, s)
	-- Index the ground markers by their numeric suffix.
	local markers = {}
	for _, child in ipairs(machine:GetChildren()) do
		if child:IsA("BasePart") then
			local n = suffixNumber(child.Name, "BaseFoodGround")
			if n then
				markers[n] = child
				configureMarker(child)
			end
		end
	end

	-- Then walk BaseFoodN slots and pair each with its same-numbered marker.
	for _, child in ipairs(machine:GetChildren()) do
		if child:IsA("BasePart") then
			local n = suffixNumber(child.Name, "BaseFood")
			if n then
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
					slot.foodPart = spawnSlotVisual(slot, s.balance)
					table.insert(s.slots, slot)
				end
			end
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
	table.insert(s.conns, detector.MouseClick:Connect(function(player)
		onTreeClicked(machine, s, player)
	end))
end

function TreeClicker.Setup(machine, plot, owner)
	local balance = balanceFor(machine)
	if not machine:IsA("Model") or not machine.PrimaryPart then
		warn(string.format("[%s] expected Model with PrimaryPart", balance.WarnPrefix))
		return
	end

	-- Tag the plot's Floor so AppleTree fruits can physically collide
	-- with it (and only it). Idempotent across multiple AppleTrees on
	-- the same plot.
	local floor = plot:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") and floor.CollisionGroup ~= FLOOR_GROUP then
		floor.CollisionGroup = FLOOR_GROUP
	end

	local s = {
		balance   = balance,
		owner     = owner,
		plot      = plot,
		lastClick = 0,
		slots     = {},
		conns     = {},
	}
	state[machine] = s

	setupSlots(machine, s)
	setupClickDetector(machine, s)

	-- Toggle every slot's pickup prompt with edit mode.
	table.insert(s.conns, owner:GetAttributeChangedSignal("EditMode"):Connect(function()
		local enabled = owner:GetAttribute("EditMode") ~= true
		for _, slot in ipairs(s.slots) do
			if slot.ground and slot.ground.prompt then
				slot.ground.prompt.Enabled = enabled
			end
		end
	end))
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
			local foodId = tostring(entry.foodId or entry.foodType or s.balance.Chain[1])
			if not chainStageOf(s.balance, foodId) then foodId = s.balance.Chain[1] end
			local xp = math.max(tonumber(entry.xp) or 0, 0)
			destroySlotGround(slot)
			spawnSlotGround(machine, s, slot, foodId, xp)
		end
	end
end

return TreeClicker
