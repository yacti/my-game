-- AppleTree FeedMachine.
--
-- Click the trunk to drop a fresh CHAIN[1] from one of the BaseFood
-- slots. The fruit physics-falls and settles. The first drop becomes
-- the tree's "ground fruit"; every subsequent drop despawns on settle
-- and adds its template's XP to the ground fruit. The ground fruit
-- accumulates XP and morphs to the next link in the chain whenever it
-- crosses a foodType's MaxXP milestone (cumulative thresholds, like
-- TimedNew). After the terminal stage the XP keeps accumulating without
-- further morphs; pickup gives the terminal foodType with the full XP.
--
-- Pickup is via E-prompt on the ground fruit only — airborne fruits
-- are non-collectible. Picking up gives the player a Tool with the
-- ground fruit's current foodType + accumulated XP. The ground fruit
-- clears and the next drop starts a fresh CHAIN[1].
--
-- Tunable attribute on the template:
--   ClickCooldown (number, default 0.5)
-- Per-foodType MaxXP is read from each food template's MaxXP attribute.
-- The chain order is owned by this module — adding new clicker foods is
-- one append in CHAIN.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food   = require(Shared:WaitForChild("Food"))
local State  = require(Shared:WaitForChild("State"))

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

-- One-shot per missing chain food, so the same warning doesn't spam.
local warnedMissingTemplate = {}

-- state[machine] = {
--   owner, plot, lastClick, conns,
--   slots = { [i] = { anchor, foodPart, respawnAt } },
--   ground = { foodType, xp, model, primary, prompt, conn } | nil,
--   airborne = { [Model|BasePart] = true },
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

local function fruitHalfHeight(foodType)
	local t = Food.GetTemplate(foodType)
	if not t then return 0 end
	if t:IsA("BasePart") then return t.Size.Y / 2 end
	if t:IsA("Model") and t.PrimaryPart then return t.PrimaryPart.Size.Y / 2 end
	return 0
end

-- Deterministic resting spot for the ground fruit: just past the trunk's
-- local +Z edge, on the floor surface. Computed from the trunk's pose so
-- the fruit lands in the same world spot regardless of how a falling
-- fruit's physics happen to settle (slot anchors live inside the trunk
-- volume; relying on physics put fruits at random stuck positions).
-- The ground fruit follows the tree's rotation, so re-rotating the tree
-- rotates the fruit's location with it.
local function computeGroundCFrame(machine, foodType)
	local trunk = machine.PrimaryPart
	if not trunk then return nil end
	local halfH = fruitHalfHeight(foodType)
	local localOffset = CFrame.new(0, -trunk.Size.Y / 2 + halfH, trunk.Size.Z / 2 + 1.5)
	return trunk.CFrame * localOffset
end

-- ── Slot visuals (cosmetic on-tree fruits) ────────────────────────────────────

local function configureSlotPart(part)
	part.Anchored   = true
	part.CanCollide = false
	-- CanQuery=false so the trunk's ClickDetector raycast hits the trunk,
	-- not the on-tree fruit visual hanging in front of it.
	part.CanQuery   = false
	part.CanTouch   = false
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
	-- Deliberately not "SlotAnchor" — that name is what the
	-- TimedSlotBillboard / FoodXPBillboard client picks up to render an
	-- XP badge. AppleTree's on-tree fruits are cosmetic placeholders that
	-- don't carry meaningful XP, so we use a different name to opt out.
	anchor.Name         = "AppleSlot"
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

-- ── Falling fruits ────────────────────────────────────────────────────────────

local function configureFallingPart(part, isPrimary)
	part.Anchored   = false
	-- Only the primary collides (so the fruit lands on a real surface);
	-- sub-parts pass through so they don't push the player around.
	part.CanCollide = isPrimary
	part.CanQuery   = false
	part.CanTouch   = false
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
	part.Anchored   = true
	-- Primary collides + queryable so the ProximityPrompt's LOS raycast
	-- has something to hit; sub-parts pass through.
	part.CanCollide = isPrimary
	part.CanQuery   = isPrimary
	part.CanTouch   = false
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
	-- Opt the ground fruit into the food XP billboard (see
	-- TimedSlotBillboard.isSlotFood). The billboard is range-gated client-
	-- side so this only renders when the player walks up to the fruit.
	visual:SetAttribute("TrackedFood", true)
	visual.Parent = workspace
	return visual, primary
end

local function destroyGroundFruit(s)
	if not s.ground then return end
	if s.ground.conn then s.ground.conn:Disconnect() end
	if s.ground.model and s.ground.model.Parent then s.ground.model:Destroy() end
	s.ground = nil
end

-- forward decl so handlers can call each other
local pickupGroundFruit
local function spawnGroundFruit(machine, s, foodType, xp, worldCF)
	local visual, primary = makeGroundFruitVisual(foodType, worldCF)
	if not visual then return end

	visual:SetAttribute("XP", xp)

	local prompt                 = Instance.new("ProximityPrompt")
	prompt.ActionText            = "Pick Up"
	prompt.KeyboardKeyCode       = Enum.KeyCode.E
	prompt.HoldDuration          = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight   = false
	prompt.Enabled               = s.owner:GetAttribute("EditMode") ~= true
	prompt.Parent                = primary

	s.ground = {
		foodType = foodType,
		xp       = xp,
		model    = visual,
		primary  = primary,
		prompt   = prompt,
		conn     = nil,
	}
	s.ground.conn = prompt.Triggered:Connect(function(player)
		if player ~= s.owner then return end
		if s.owner:GetAttribute("EditMode") == true then return end
		pickupGroundFruit(machine, s, player)
	end)
end

-- Add XP to the ground fruit; advance through the chain whenever
-- cumulative xp crosses a stage's MaxXP. Past the terminal stage — or
-- past the last stage that has a registered food template — xp keeps
-- accumulating without further morphs. The ground fruit always lives
-- at the tree's deterministic ground spot; morphing recomputes the
-- spot for the new foodType's height and respawns the visual there.
local function addXPToGround(machine, s, deltaXP)
	if not s.ground then return end
	s.ground.xp = s.ground.xp + deltaXP
	if s.ground.model and s.ground.model.Parent then
		s.ground.model:SetAttribute("XP", s.ground.xp)
	end

	local startStage = chainStageOf(s.ground.foodType)
	local stage      = startStage
	while stage < #CHAIN do
		if s.ground.xp < maxXPFor(CHAIN[stage]) then break end
		local nextType = CHAIN[stage + 1]
		-- Halt the morph if the next chain entry has no food template.
		-- The fruit stays at its current stage and keeps accumulating XP.
		if not Food.GetTemplate(nextType) then
			if not warnedMissingTemplate[nextType] then
				warnedMissingTemplate[nextType] = true
				warn(string.format(
					"[AppleTree] no food template for %q — morph halts at %s. Add a Food%d_Clicker template to ReplicatedStorage.Food to enable further morphs.",
					nextType, CHAIN[stage], stage + 1
				))
			end
			break
		end
		stage = stage + 1
	end
	if stage > startStage then
		local newType = CHAIN[stage]
		local xp      = s.ground.xp
		local cf      = computeGroundCFrame(machine, newType)
		destroyGroundFruit(s)
		if cf then spawnGroundFruit(machine, s, newType, xp, cf) end
	end
end

pickupGroundFruit = function(machine, s, player)
	if not s.ground then return end
	local tool = Food.MakeTool(s.ground.foodType, s.ground.xp)
	if not tool then return end
	tool.Parent = player.Backpack
	destroyGroundFruit(s)
end

-- Watch a falling fruit's primary; once it stops moving, despawn the
-- visual and resolve the merge. The falling fruit's settled position is
-- not used for the ground fruit — the ground fruit's spot is always
-- the deterministic computeGroundCFrame so it doesn't end up wedged
-- inside the trunk.
local function trackFallingFruit(machine, s, falling, primary)
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
					if s.ground then
						addXPToGround(machine, s, dropXP)
					else
						local cf = computeGroundCFrame(machine, foodType)
						if cf then spawnGroundFruit(machine, s, foodType, dropXP, cf) end
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

local function findReadySlot(s)
	for _, slot in ipairs(s.slots) do
		if slot.foodPart and not slot.respawnAt then return slot end
	end
	return nil
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
	trackFallingFruit(machine, s, falling, primary)
end

-- ── Setup / teardown ──────────────────────────────────────────────────────────

local function setupSlots(machine, s)
	for _, child in ipairs(machine:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "BaseFood" then
			local anchor = makeSlotAnchor(machine, child)
			child:Destroy()
			local slot = { anchor = anchor, foodPart = nil, respawnAt = nil }
			slot.foodPart = spawnSlotVisual(slot)
			table.insert(s.slots, slot)
		end
	end
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

	local s = {
		owner     = owner,
		plot      = plot,
		lastClick = 0,
		slots     = {},
		ground    = nil,
		airborne  = {},
		conns     = {},
	}
	state[machine] = s

	setupSlots(machine, s)
	setupClickDetector(machine, s)

	-- Toggle the ground fruit's E prompt with edit mode.
	table.insert(s.conns, owner:GetAttributeChangedSignal("EditMode"):Connect(function()
		if s.ground and s.ground.prompt then
			s.ground.prompt.Enabled = owner:GetAttribute("EditMode") ~= true
		end
	end))
end

function AppleTree.Teardown(machine)
	local s = state[machine]
	if not s then return end
	for _, c in ipairs(s.conns) do c:Disconnect() end
	destroyGroundFruit(s)
	-- Picking the tree up wipes any in-flight or settled fruits tied to
	-- it; players who care should pick the ground fruit up first.
	for falling in pairs(s.airborne) do
		if falling.Parent then falling:Destroy() end
	end
	state[machine] = nil
end

-- Persist just the ground fruit's foodType + xp. Position is recomputed
-- from the tree's pose on Apply, so a tree picked up + re-placed (or
-- whose floor was rotated) lands the fruit at the correct new spot.
function AppleTree.Serialize(machine)
	local s = state[machine]
	if not s or not s.ground then return nil end
	return {
		groundFruit = {
			foodType = s.ground.foodType,
			xp       = s.ground.xp,
		},
	}
end

function AppleTree.Apply(machine, placement)
	local s = state[machine]
	if not s or type(placement) ~= "table" then return end
	local g = placement.groundFruit
	if type(g) ~= "table" then return end

	local foodType = tostring(g.foodType or CHAIN[1])
	if chainStageOf(foodType) > #CHAIN then foodType = CHAIN[#CHAIN] end
	-- Saved foodType might point at a stage whose template no longer exists
	-- (e.g. someone removed a food). Walk back to the nearest available stage.
	while not Food.GetTemplate(foodType) and chainStageOf(foodType) > 1 do
		foodType = CHAIN[chainStageOf(foodType) - 1]
	end
	if not Food.GetTemplate(foodType) then return end

	local xp = math.max(tonumber(g.xp) or 0, 0)
	local cf = computeGroundCFrame(machine, foodType)
	if not cf then return end

	destroyGroundFruit(s)
	spawnGroundFruit(machine, s, foodType, xp, cf)
end

return AppleTree
