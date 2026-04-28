-- AppleTree FeedMachine.
--
-- Click the trunk to drop a fresh CHAIN[1] from one of the on-tree
-- BaseFood slots. The fruit physics-falls and resolves into one of the
-- tree's BaseFoodGround pools — either by overlapping a BaseFoodGround
-- mid-flight (Touched) or, as a fallback, by snapping to the nearest
-- BaseFoodGround once it stops moving (or after FALL_TIMEOUT). Each
-- BaseFoodGround maintains its own independent XP pool and morphs
-- through CHAIN at its own pace; pickup is a per-pool E-prompt that
-- gives the player a Tool with that pool's foodType + accumulated XP.
--
-- BaseFoodGround markers are server-only anchors: invisible to the
-- player; the pool's visual fruit (which sits on top) is the only
-- thing that's seen, so a BaseFoodGround "appearing" only happens
-- once a fruit has actually landed there.
--
-- Tunable attribute on the template:
--   ClickCooldown (number, default 0.5)
-- Per-foodType MaxXP read from each food template's MaxXP attribute.
-- The chain is owned by this module — adding a clicker food is one
-- append in CHAIN.

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
local SETTLE_VELOCITY  = 0.5  -- studs/s; primary is "still" below this
local SETTLE_DURATION  = 0.3  -- seconds it must stay still to count as settled
local FALL_TIMEOUT     = 5    -- safety: stuck fruits force-resolve at nearest ground

-- One-shot per missing chain food, so the same warning doesn't spam.
local warnedMissingTemplate = {}

-- state[machine] = {
--   owner, plot, lastClick, conns,
--   slots    = { [i] = { anchor, foodPart, respawnAt } },        -- on-tree
--   grounds  = { [i] = { marker, pool = nil | { foodType, xp, model, primary, prompt, conn } } },
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

-- ── On-tree slot visuals (cosmetic) ───────────────────────────────────────────

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
	-- Deliberately not "SlotAnchor" — that name is what the food XP
	-- billboard picks up. AppleTree's on-tree fruits are cosmetic.
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
	-- Primary collides so it can settle on the floor; sub-parts pass
	-- through. Primary CanTouch=true so it fires Touched against the
	-- BaseFoodGround marker mid-flight.
	part.CanCollide = isPrimary
	part.CanQuery   = false
	part.CanTouch   = isPrimary
	part.Massless   = false
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

-- ── Pool visuals (the fruit sitting on a BaseFoodGround) ──────────────────────

local function configurePoolPart(part, isPrimary)
	part.Anchored   = true
	-- CanCollide=false so a falling fruit can pass through the pool and
	-- reach the marker below to fire Touched. CanTouch=false so the
	-- falling fruit doesn't fire Touched against the pool itself.
	part.CanCollide = false
	part.CanQuery   = isPrimary  -- prompt LOS raycast hits the primary
	part.CanTouch   = false
end

local function makePoolVisual(foodType, worldCF)
	local template = Food.GetTemplate(foodType)
	if not template then return nil, nil end
	local visual, primary
	if template:IsA("BasePart") then
		visual  = template:Clone()
		primary = visual
		configurePoolPart(visual, true)
		visual.CFrame = worldCF
	elseif template:IsA("Model") then
		if not template.PrimaryPart then return nil, nil end
		visual  = template:Clone()
		primary = visual.PrimaryPart
		for _, d in ipairs(visual:GetDescendants()) do
			if d:IsA("BasePart") then configurePoolPart(d, d == primary) end
		end
		visual:PivotTo(worldCF)
	end
	if not visual or not primary then
		if visual then visual:Destroy() end
		return nil, nil
	end
	visual:SetAttribute("FoodType", foodType)
	-- Opt the pool fruit into the food XP billboard.
	visual:SetAttribute("TrackedFood", true)
	visual.Parent = workspace
	return visual, primary
end

-- World CFrame for a pool fruit sitting on top of its BaseFoodGround.
local function poolCFrame(marker, foodType)
	local halfH = fruitHalfHeight(foodType)
	return marker.CFrame * CFrame.new(0, marker.Size.Y / 2 + halfH, 0)
end

local function destroyPool(groundSlot)
	local pool = groundSlot.pool
	if not pool then return end
	if pool.conn then pool.conn:Disconnect() end
	if pool.model and pool.model.Parent then pool.model:Destroy() end
	groundSlot.pool = nil
end

-- forward decl so the prompt closure can reference pickup
local pickupPool

local function spawnPool(machine, s, groundSlot, foodType, xp)
	if not groundSlot.marker.Parent then return end
	local visual, primary = makePoolVisual(foodType, poolCFrame(groundSlot.marker, foodType))
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

	groundSlot.pool = {
		foodType = foodType,
		xp       = xp,
		model    = visual,
		primary  = primary,
		prompt   = prompt,
		conn     = nil,
	}
	groundSlot.pool.conn = prompt.Triggered:Connect(function(player)
		if player ~= s.owner then return end
		if s.owner:GetAttribute("EditMode") == true then return end
		pickupPool(machine, s, groundSlot, player)
	end)
end

local function addXPToPool(machine, s, groundSlot, deltaXP)
	local pool = groundSlot.pool
	if not pool then return end
	pool.xp = pool.xp + deltaXP
	if pool.model and pool.model.Parent then
		pool.model:SetAttribute("XP", pool.xp)
	end

	local startStage = chainStageOf(pool.foodType)
	local stage      = startStage
	while stage < #CHAIN do
		if pool.xp < maxXPFor(CHAIN[stage]) then break end
		local nextType = CHAIN[stage + 1]
		-- Halt the morph if the next chain entry has no food template.
		-- The pool stays at its current stage and keeps accumulating XP.
		if not Food.GetTemplate(nextType) then
			if not warnedMissingTemplate[nextType] then
				warnedMissingTemplate[nextType] = true
				warn(string.format(
					"[AppleTree] no food template for %q — morph halts at %s. Add a template to ReplicatedStorage.Food to enable further morphs.",
					nextType, CHAIN[stage]
				))
			end
			break
		end
		stage = stage + 1
	end
	if stage > startStage then
		local newType = CHAIN[stage]
		local xp      = pool.xp
		destroyPool(groundSlot)
		spawnPool(machine, s, groundSlot, newType, xp)
	end
end

pickupPool = function(machine, s, groundSlot, player)
	local pool = groundSlot.pool
	if not pool then return end
	local tool = Food.MakeTool(pool.foodType, pool.xp)
	if not tool then return end
	tool.Parent = player.Backpack
	destroyPool(groundSlot)
end

local function mergeIntoGround(machine, s, groundSlot, foodType, dropXP)
	if not groundSlot.pool then
		spawnPool(machine, s, groundSlot, foodType, dropXP)
	else
		addXPToPool(machine, s, groundSlot, dropXP)
	end
end

local function findGroundSlotByMarker(s, marker)
	for _, gs in ipairs(s.grounds) do
		if gs.marker == marker then return gs end
	end
	return nil
end

local function nearestGroundSlot(s, worldPos)
	local best, bestDist
	for _, gs in ipairs(s.grounds) do
		if gs.marker.Parent then
			local d = (gs.marker.Position - worldPos).Magnitude
			if not bestDist or d < bestDist then
				best     = gs
				bestDist = d
			end
		end
	end
	return best
end

-- Watch a falling fruit. Two resolution paths:
--   • Touch — the primary overlaps a BaseFoodGround mid-flight, fires
--             Touched, and we merge into that pool immediately.
--   • Settle/timeout — primary's velocity drops below SETTLE_VELOCITY
--             for SETTLE_DURATION (or FALL_TIMEOUT seconds elapse).
--             We snap to the nearest BaseFoodGround on this tree.
-- Whichever fires first wins; resolve() guards against double-firing.
local function trackFallingFruit(machine, s, falling, primary)
	s.airborne[falling] = true
	local foodType  = falling:GetAttribute("FoodType")
	local dropXP    = dropXPFor(foodType)
	local startTime = os.clock()

	local resolved = false
	local touchConn

	local function resolve(groundSlot)
		if resolved then return end
		resolved = true
		if touchConn then touchConn:Disconnect() touchConn = nil end
		s.airborne[falling] = nil
		if falling.Parent then falling:Destroy() end
		if not state[machine] or not groundSlot then return end
		mergeIntoGround(machine, s, groundSlot, foodType, dropXP)
	end

	touchConn = primary.Touched:Connect(function(other)
		if resolved then return end
		if other.Name ~= "BaseFoodGround" then return end
		local groundSlot = findGroundSlotByMarker(s, other)
		if groundSlot then resolve(groundSlot) end
	end)

	task.spawn(function()
		local stillSince = nil
		while not resolved and falling.Parent == workspace and primary.Parent do
			local now = os.clock()
			if now - startTime > FALL_TIMEOUT then
				resolve(nearestGroundSlot(s, primary.Position))
				return
			end
			if primary.AssemblyLinearVelocity.Magnitude < SETTLE_VELOCITY then
				stillSince = stillSince or now
				if now - stillSince >= SETTLE_DURATION then
					resolve(nearestGroundSlot(s, primary.Position))
					return
				end
			else
				stillSince = nil
			end
			RunService.Heartbeat:Wait()
		end
		-- Loop exited because falling was destroyed externally (e.g. tree
		-- picked up) without resolving. Drop airborne tracking.
		if not resolved then s.airborne[falling] = nil end
	end)
end

-- ── Click → drop ──────────────────────────────────────────────────────────────

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

-- ── Setup / teardown ─────────────────────────────────────────────────────────

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

local function setupGroundSlots(machine, s)
	for _, child in ipairs(machine:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "BaseFoodGround" then
			-- Server-only anchor: invisible, intangible, but still
			-- queryable for Touched events from falling fruit primaries.
			child.Transparency = 1
			child.CanCollide   = false
			child.CanQuery     = false
			child.CanTouch     = true
			child.Anchored     = true
			table.insert(s.grounds, { marker = child, pool = nil })
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
		grounds   = {},
		airborne  = {},
		conns     = {},
	}
	state[machine] = s

	setupGroundSlots(machine, s)
	setupSlots(machine, s)
	setupClickDetector(machine, s)

	-- Toggle every pool's E prompt with edit mode.
	table.insert(s.conns, owner:GetAttributeChangedSignal("EditMode"):Connect(function()
		local enabled = owner:GetAttribute("EditMode") ~= true
		for _, gs in ipairs(s.grounds) do
			if gs.pool and gs.pool.prompt then
				gs.pool.prompt.Enabled = enabled
			end
		end
	end))
end

function AppleTree.Teardown(machine)
	local s = state[machine]
	if not s then return end
	for _, c in ipairs(s.conns) do c:Disconnect() end
	for _, gs in ipairs(s.grounds) do destroyPool(gs) end
	for falling in pairs(s.airborne) do
		if falling.Parent then falling:Destroy() end
	end
	state[machine] = nil
end

-- Persist every non-empty pool. groundIndex is the position in s.grounds,
-- which is built deterministically by iterating the tree's children, so
-- it stays stable across save/load as long as the template's BaseFoodGround
-- count doesn't change.
function AppleTree.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local saved = {}
	for i, gs in ipairs(s.grounds) do
		if gs.pool then
			table.insert(saved, {
				groundIndex = i,
				foodType    = gs.pool.foodType,
				xp          = gs.pool.xp,
			})
		end
	end
	if #saved == 0 then return nil end
	return { groundFruits = saved }
end

function AppleTree.Apply(machine, placement)
	local s = state[machine]
	if not s or type(placement) ~= "table" then return end
	local list = placement.groundFruits
	if type(list) ~= "table" then return end
	for _, rec in ipairs(list) do
		local idx = tonumber(rec.groundIndex)
		local gs  = idx and s.grounds[idx]
		if gs and not gs.pool then
			local foodType = tostring(rec.foodType or CHAIN[1])
			-- Walk the foodType back if its template was removed since last save.
			while not Food.GetTemplate(foodType) and chainStageOf(foodType) > 1 do
				foodType = CHAIN[chainStageOf(foodType) - 1]
			end
			if Food.GetTemplate(foodType) then
				local xp = math.max(tonumber(rec.xp) or 0, 0)
				spawnPool(machine, s, gs, foodType, xp)
			end
		end
	end
end

return AppleTree
