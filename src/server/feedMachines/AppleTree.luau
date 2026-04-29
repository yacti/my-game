-- AppleTree FeedMachine.
--
-- The tree model carries numbered pairs:
--   BaseFood1..N        — on-tree fruit slots (cosmetic + spawn anchors)
--   BaseFoodGround1..N  — invisible ground markers (one per slot)
-- Each numbered slot owns its own BaseFoodGround pile. Clicking the trunk
-- drops a fresh CHAIN[1] from a random ready slot. The very first drop
-- per slot physics-falls and bounces; once it settles it snaps to that
-- slot's BaseFoodGround marker, becomes that slot's "ground fruit" with
-- a BillboardGUI XP counter and an E-pickup ProximityPrompt.
--
-- Every subsequent drop from the same slot physics-falls but passes
-- through that slot's ground fruit (NoCollisionConstraint) and is
-- destroyed on its first touch with the floor or its own ground fruit
-- — its template XP is added to that slot's pile. The pile chain-morphs
-- to the next link whenever its accumulated XP crosses the current
-- foodType's MaxXP threshold; pickup gives a Tool with that pile's
-- current foodType + accumulated XP and clears that slot only.
--
-- Tunable attribute on the template:
--   ClickCooldown (number, default 0.5)
-- Per-foodType MaxXP is read from each food template's MaxXP attribute.
-- The chain order is owned by this module — adding new clicker foods is
-- one append in CHAIN.

local PhysicsService    = game:GetService("PhysicsService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food   = require(Shared:WaitForChild("Food"))
local State  = require(Shared:WaitForChild("State"))

-- Collision groups: AppleTree fruits and ground markers physically
-- collide ONLY with the plot Floor — they pass through the tree, the
-- player, other fruits, and the rest of the world. Touched still fires
-- regardless of group (we rely on it for the absorb trigger).
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

local AppleTree = {}

local CHAIN = {
	"Food1_Clicker",
	"Food2_Clicker",
	"Food3_Clicker",
	"Food4_Clicker",
	"Food5_Clicker",
	"Food6_Clicker",
	"Food7_Clicker",
	"Food8_Clicker",
	"Food9_Clicker",
	"Food10_Clicker",
}

local DEFAULT_COOLDOWN = 0.5  -- seconds; click rate when ClickCooldown attr is unset
local SLOT_RESPAWN     = 1    -- seconds; on-tree slot regrows after a drop
local SETTLE_VELOCITY  = 0.5  -- studs/s; fruit is "still" below this
local SETTLE_DURATION  = 0.3  -- seconds it must stay still before merging

-- state[machine] = {
--   owner, plot, lastClick, conns,
--   slots = { [i] = {
--     n,             -- numeric suffix shared by BaseFoodN and BaseFoodGroundN
--     anchor,        -- invisible spawn point, replaces BaseFoodN
--     marker,        -- BaseFoodGroundN part (invisible, used as CFrame ref)
--     foodPart,      -- on-tree visual, respawning
--     respawnAt,
--     ground,        -- { foodType, xp, model, primary, prompt, label, conn } | nil
--   } },
--   airborne = { [Model|BasePart] = true },  -- shared cleanup set
-- }
local state = {}

local function maxXPFor(foodType)
	local t = Food.GetTemplate(foodType)
	return t and (t:GetAttribute("MaxXP") or 5) or 5
end

local function dropXPFor(foodType)
	local t = Food.GetTemplate(foodType)
	return t and (t:GetAttribute("XP") or 1) or 1
end

local function chainStageOf(foodType)
	for i, ft in ipairs(CHAIN) do if ft == foodType then return i end end
	return 1
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

local function spawnSlotVisual(slot)
	local foodType = CHAIN[1]
	local template = Food.GetTemplate(foodType)
	if not template then return nil end
	local clone = template:Clone()
	clone:SetAttribute("FoodType", foodType)
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

-- ── Falling fruits ────────────────────────────────────────────────────────────

local function configureFallingPart(part, isPrimary)
	part.Anchored       = false
	-- Only the primary collides (so the fruit lands on a real surface);
	-- sub-parts pass through so they don't push the player around. The
	-- FRUIT_GROUP narrows that further so the primary only collides
	-- with the plot Floor — never the tree, leaves, or other fruits.
	part.CanCollide     = isPrimary
	part.CanQuery       = false
	part.CanTouch       = false
	part.CollisionGroup = FRUIT_GROUP
end

local function spawnFallingFruit(slot, foodType)
	local template = Food.GetTemplate(foodType)
	if not template then return nil, nil end
	local clone, primary
	if template:IsA("BasePart") then
		clone = template:Clone()
		configureFallingPart(clone, true)
		clone.CFrame = slot.anchor.CFrame
		primary = clone
	elseif template:IsA("Model") then
		if not template.PrimaryPart then return nil, nil end
		clone   = template:Clone()
		primary = clone.PrimaryPart
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then configureFallingPart(d, d == primary) end
		end
		clone:PivotTo(slot.anchor.CFrame)
	end
	if not clone or not primary then
		if clone then clone:Destroy() end
		return nil, nil
	end
	clone:SetAttribute("FoodType", foodType)
	clone.Parent = workspace
	return clone, primary
end

-- ── Ground fruit ──────────────────────────────────────────────────────────────

local function configureGroundPart(part, isPrimary)
	part.Anchored       = true
	-- Primary queryable so the ProximityPrompt's LOS raycast has
	-- something to hit; sub-parts pass through. CanTouch on the primary
	-- so a subsequent drop overlapping the ground fruit fires its
	-- Touched listener. CanCollide stays true on the primary, but the
	-- FRUIT_GROUP rules mean it only physical-collides with the Floor
	-- (which it sits on) — fruits pass through it.
	part.CanCollide     = isPrimary
	part.CanQuery       = isPrimary
	part.CanTouch       = isPrimary
	part.CollisionGroup = FRUIT_GROUP
end

local function fruitHalfHeight(foodType)
	local template = Food.GetTemplate(foodType)
	if not template then return 0 end
	if template:IsA("BasePart") then return template.Size.Y / 2 end
	if template:IsA("Model") and template.PrimaryPart then return template.PrimaryPart.Size.Y / 2 end
	return 0
end

local function groundCFrame(marker, foodType)
	-- Snap the ground fruit so its bottom aligns with the marker's
	-- bottom (the marker sits on the floor at design time, so this puts
	-- the fruit cleanly on the floor too).
	local dy = fruitHalfHeight(foodType) - marker.Size.Y / 2
	return marker.CFrame * CFrame.new(0, dy, 0)
end

local function makeGroundFruitVisual(foodType, worldCF)
	local template = Food.GetTemplate(foodType)
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
	visual:SetAttribute("FoodType", foodType)
	visual.Parent = workspace
	return visual, primary
end

local function destroySlotGround(slot)
	if not slot.ground then return end
	if slot.ground.conn then slot.ground.conn:Disconnect() end
	if slot.ground.model and slot.ground.model.Parent then slot.ground.model:Destroy() end
	slot.ground = nil
end

local function formatXPText(foodType, xp)
	local stage = chainStageOf(foodType)
	if stage < #CHAIN then
		return string.format("%d / %d XP", xp, maxXPFor(foodType))
	end
	return string.format("%d XP", xp)
end

local function attachXPBillboard(slot, primary)
	local bg = Instance.new("BillboardGui")
	bg.Name                   = "XPBillboard"
	bg.Size                   = UDim2.fromOffset(120, 28)
	bg.AlwaysOnTop            = true
	bg.LightInfluence         = 0
	bg.MaxDistance            = 40
	bg.StudsOffsetWorldSpace  = Vector3.new(0, primary.Size.Y / 2 + 0.6, 0)

	local label = Instance.new("TextLabel")
	label.Name                   = "Text"
	label.BackgroundTransparency = 1
	label.Size                   = UDim2.fromScale(1, 1)
	label.Font                   = Enum.Font.GothamBold
	label.TextColor3             = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3       = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextScaled             = true
	label.Parent                 = bg

	bg.Parent = primary
	slot.ground.label = label
end

local function refreshXPBillboard(slot)
	if not slot.ground or not slot.ground.label then return end
	slot.ground.label.Text = formatXPText(slot.ground.foodType, slot.ground.xp)
end

-- forward decl so handlers can call each other
local pickupSlotGround
local function spawnSlotGround(machine, s, slot, foodType, xp)
	local visual, primary = makeGroundFruitVisual(foodType, groundCFrame(slot.marker, foodType))
	if not visual then return end

	visual:SetAttribute("FoodType", foodType)
	visual:SetAttribute("XP", xp)
	visual:SetAttribute("SlotIndex", slot.n)

	local prompt                 = Instance.new("ProximityPrompt")
	prompt.ActionText            = "Pick Up"
	prompt.KeyboardKeyCode       = Enum.KeyCode.E
	prompt.HoldDuration          = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight   = false
	prompt.Enabled               = s.owner:GetAttribute("EditMode") ~= true
	prompt.Parent                = primary

	slot.ground = {
		foodType = foodType,
		xp       = xp,
		model    = visual,
		primary  = primary,
		prompt   = prompt,
		conn     = nil,
		label    = nil,
	}
	attachXPBillboard(slot, primary)
	refreshXPBillboard(slot)
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
	slot.ground.model:SetAttribute("XP", slot.ground.xp)
	refreshXPBillboard(slot)

	local stage    = chainStageOf(slot.ground.foodType)
	local advanced = false
	while stage < #CHAIN and slot.ground.xp >= maxXPFor(CHAIN[stage]) do
		stage    = stage + 1
		advanced = true
	end
	if advanced then
		local newType = CHAIN[stage]
		local xp = slot.ground.xp
		destroySlotGround(slot)
		spawnSlotGround(machine, s, slot, newType, xp)
	end
end

pickupSlotGround = function(machine, s, slot, player)
	if not slot.ground then return end
	local tool = Food.MakeTool(slot.ground.foodType, slot.ground.xp)
	if not tool then return end
	tool.Parent = player.Backpack
	destroySlotGround(slot)
end

-- Watch a falling fruit's primary and merge it into the slot's ground
-- fruit once it settles. If there's no slot ground yet, the falling
-- fruit becomes that slot's ground fruit (snapped to the slot's
-- BaseFoodGround marker).
local function trackFirstDrop(machine, s, slot, falling, primary)
	s.airborne[falling] = true
	local foodType = falling:GetAttribute("FoodType")
	local dropXP   = dropXPFor(foodType)

	task.spawn(function()
		local stillSince = nil
		while falling.Parent == workspace and primary.Parent do
			if primary.AssemblyLinearVelocity.Magnitude < SETTLE_VELOCITY then
				stillSince = stillSince or os.clock()
				if os.clock() - stillSince >= SETTLE_DURATION then
					if not state[machine] then return end
					s.airborne[falling] = nil
					falling:Destroy()
					if slot.ground then
						addXPToSlotGround(machine, s, slot, dropXP)
					else
						spawnSlotGround(machine, s, slot, foodType, dropXP)
					end
					return
				end
			else
				stillSince = nil
			end
			RunService.Heartbeat:Wait()
		end
		s.airborne[falling] = nil
	end)
end

-- Subsequent drops (this slot's ground exists): the fruit physics-
-- falls but passes through THIS slot's ground fruit, and is destroyed
-- on its first valid touch (floor or own ground) — its XP is added to
-- this slot's pile. Touches with the tree itself, the fruit's own
-- sub-parts, and player characters are ignored.
local function isIgnorableTouch(machine, falling, hit)
	if not hit then return true end
	if hit:IsDescendantOf(falling) then return true end
	if hit:IsDescendantOf(machine) then return true end
	local model = hit:FindFirstAncestorOfClass("Model")
	while model do
		if Players:GetPlayerFromCharacter(model) then return true end
		model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
	end
	return false
end

local function trackSubsequentDrop(machine, s, slot, falling, primary)
	s.airborne[falling] = true
	local foodType = falling:GetAttribute("FoodType")
	local dropXP   = dropXPFor(foodType)

	-- The FRUIT_GROUP rule already prevents this fruit from physically
	-- colliding with the slot's ground fruit (or any other fruit), so
	-- it passes through and Touched fires on overlap. CanTouch=true
	-- on the primary so floor + own-ground touches are both detected.
	primary.CanTouch = true

	local consumed = false
	local conn
	conn = primary.Touched:Connect(function(hit)
		if consumed then return end
		if isIgnorableTouch(machine, falling, hit) then return end
		consumed = true
		if conn then conn:Disconnect() end
		if not state[machine] then return end
		s.airborne[falling] = nil
		if falling.Parent then falling:Destroy() end
		if slot.ground then
			addXPToSlotGround(machine, s, slot, dropXP)
		else
			-- Race: ground was cleared mid-flight (pickup). Spawn fresh
			-- at this slot's marker.
			spawnSlotGround(machine, s, slot, foodType, dropXP)
		end
	end)
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
			slot.foodPart  = spawnSlotVisual(slot)
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

	local cooldown = machine:GetAttribute(State.Feed.ClickCooldown) or DEFAULT_COOLDOWN
	local now = os.clock()
	if now - s.lastClick < cooldown then return end

	local slot = findReadySlot(s)
	if not slot then return end

	clearSlotVisual(slot)
	slot.respawnAt = now + SLOT_RESPAWN

	local falling, primary = spawnFallingFruit(slot, CHAIN[1])
	if not falling then return end
	s.lastClick = now
	if slot.ground then
		trackSubsequentDrop(machine, s, slot, falling, primary)
	else
		trackFirstDrop(machine, s, slot, falling, primary)
	end
end

-- ── Setup / teardown ──────────────────────────────────────────────────────────

local function suffixNumber(name, prefix)
	return tonumber(string.match(name, "^" .. prefix .. "(%d+)$"))
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
						"[AppleTree] BaseFood%d has no matching BaseFoodGround%d on %s",
						n, n, machine:GetFullName()
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
					slot.foodPart = spawnSlotVisual(slot)
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

function AppleTree.Setup(machine, plot, owner)
	if not machine:IsA("Model") or not machine.PrimaryPart then
		warn("[AppleTree] expected Model with PrimaryPart")
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
		owner     = owner,
		plot      = plot,
		lastClick = 0,
		slots     = {},
		airborne  = {},
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

function AppleTree.Teardown(machine)
	local s = state[machine]
	if not s then return end
	for _, c in ipairs(s.conns) do c:Disconnect() end
	for _, slot in ipairs(s.slots) do
		destroySlotGround(slot)
	end
	-- Picking the tree up wipes any in-flight fruits tied to it; players
	-- who care should pick the ground fruits up first.
	for falling in pairs(s.airborne) do
		if falling.Parent then falling:Destroy() end
	end
	state[machine] = nil
end

-- Persist piles per slot. Position is regenerated from each slot's
-- BaseFoodGround marker on Apply, so we only save type + xp.
function AppleTree.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local piles = {}
	local any = false
	for _, slot in ipairs(s.slots) do
		if slot.ground then
			piles[tostring(slot.n)] = {
				foodType = slot.ground.foodType,
				xp       = slot.ground.xp,
			}
			any = true
		end
	end
	if not any then return nil end
	return { piles = piles }
end

function AppleTree.Apply(machine, placement)
	local s = state[machine]
	if not s or type(placement) ~= "table" then return end
	local piles = placement.piles
	if type(piles) ~= "table" then return end

	for _, slot in ipairs(s.slots) do
		local entry = piles[tostring(slot.n)]
		if type(entry) == "table" then
			local foodType = tostring(entry.foodType or CHAIN[1])
			if chainStageOf(foodType) > #CHAIN then foodType = CHAIN[#CHAIN] end
			local xp = math.max(tonumber(entry.xp) or 0, 0)
			destroySlotGround(slot)
			spawnSlotGround(machine, s, slot, foodType, xp)
		end
	end
end

return AppleTree
