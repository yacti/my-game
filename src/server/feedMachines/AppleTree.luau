-- AppleTree FeedMachine.
--
-- Click the trunk (PrimaryPart) to drop a fruit from one of the BaseFood
-- slots. The fruit spawns as a Tool at the slot's anchor, falls with
-- gravity, bounces, and anchors when it settles so it can't be kicked
-- around. The slot's visual disappears for `respawnDelay` seconds, then
-- regrows. Players collect the fallen fruit by walking into it (Tool
-- touch pickup, same as Clicker).
--
-- The E-prompt at the bottom of the PrimaryPart upgrades the tree using
-- player Currency. Each level dictates which food the tree drops; the
-- on-tree slot visuals re-skin to match. Hidden at max level and during
-- edit mode. Visible only to the owner — server creates the prompt, the
-- client-side AppleTreeUI script hides it for non-owners (client Style
-- changes don't replicate, so each client decides independently).
--
-- Level persists across pickup/place via the FeedMachineTool's Level
-- attribute (set in init.server.luau's setupFeedPickup, read in
-- PlaceFeedMachine).
--
-- All economy lives in Shared.ClickerBalance.

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local Shared          = ReplicatedStorage:WaitForChild("Shared")
local Food            = require(Shared:WaitForChild("Food"))
local Remotes         = require(Shared:WaitForChild("Remotes"))
local State           = require(Shared:WaitForChild("State"))
local ClickerBalance  = require(Shared:WaitForChild("ClickerBalance"))

local PlayerDataService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("PlayerDataService"))
local CurrencyUpdated   = Remotes.get("CurrencyUpdated")

local AppleTree = {}

-- A fruit's Handle is below SETTLE_VELOCITY studs/s for SETTLE_DURATION
-- seconds before we anchor it. Two simple thresholds — picks up after
-- the bounce damps out without needing collision callbacks.
local SETTLE_VELOCITY = 0.5
local SETTLE_DURATION = 0.3

-- [machine] = {
--   owner, plot, level, lastClick, balance, conns, prompt,
--   slots = { [i] = { anchor, foodPart, state, respawnAt } },
-- }
-- slot.state is one of: "ready" (visual on tree, can be dropped), "dropped"
-- (a Tool is mid-air or on the ground waiting to be picked up), "empty"
-- (post-pickup, visual hidden, regrows at respawnAt).
local state = {}

local function feedTypeOf(machine)
	return machine:GetAttribute(State.Feed.Type) or machine.Name
end

local function configureSlotPart(part)
	part.Anchored   = true
	part.CanCollide = false
	-- CanQuery=false so the trunk's ClickDetector raycast hits the trunk,
	-- not the on-tree fruit visual hanging in front of it.
	part.CanQuery   = false
	part.CanTouch   = false
end

local function spawnSlotVisual(slot, foodType)
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

-- Re-skin every slot's on-tree visual to the new foodType. Slots in
-- "dropped" or "empty" state have no visual right now; respawns will
-- pick up the new foodType when they fire.
local function reskinReadySlots(s, foodType)
	for _, slot in ipairs(s.slots) do
		if slot.state == "ready" then
			clearSlotVisual(slot)
			slot.foodPart = spawnSlotVisual(slot, foodType)
		end
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

-- Watch a falling fruit's Handle: anchor it once it settles, and free
-- the slot when the Tool leaves workspace (player touched it → Roblox
-- moves Tool to Backpack, firing AncestryChanged).
local function trackFallingFruit(s, slot, tool)
	local handle = tool.Handle
	if not handle then return end

	task.spawn(function()
		local stillSince = nil
		while tool.Parent == workspace and handle.Parent do
			if handle.AssemblyLinearVelocity.Magnitude < SETTLE_VELOCITY then
				stillSince = stillSince or os.clock()
				if os.clock() - stillSince >= SETTLE_DURATION then
					if handle.Parent then handle.Anchored = true end
					return
				end
			else
				stillSince = nil
			end
			RunService.Heartbeat:Wait()
		end
	end)

	local conn
	conn = tool.AncestryChanged:Connect(function(_, parent)
		if parent ~= workspace then
			-- Tool left the world (picked up, destroyed, etc.). Unanchor
			-- defensively so an equipped tool follows the player normally.
			if handle.Parent then handle.Anchored = false end
			conn:Disconnect()
			if slot.state == "dropped" then
				slot.state     = "empty"
				slot.respawnAt = os.clock() + (s.balance.respawnDelay or 1)
			end
		end
	end)
end

local function dropFruitFromSlot(machine, s, slot)
	local foodType = ClickerBalance.FoodAt(feedTypeOf(machine), s.level)
	if not foodType then return false end

	local tool = Food.MakeTool(foodType)
	if not tool then return false end
	tool:SetAttribute("SourceFeedIndex", machine:GetAttribute(State.Feed.Index))

	clearSlotVisual(slot)
	slot.state = "dropped"

	tool.Parent = workspace
	if tool.Handle then
		tool.Handle.CFrame = slot.anchor.CFrame
	end
	trackFallingFruit(s, slot, tool)
	return true
end

local function findReadySlot(s)
	for _, slot in ipairs(s.slots) do
		if slot.state == "ready" then return slot end
	end
	return nil
end

local function tickRespawns(machine, s)
	local now      = os.clock()
	local foodType = ClickerBalance.FoodAt(feedTypeOf(machine), s.level)
	if not foodType then return end
	for _, slot in ipairs(s.slots) do
		if slot.state == "empty" and slot.respawnAt and now >= slot.respawnAt then
			slot.state     = "ready"
			slot.respawnAt = nil
			slot.foodPart  = spawnSlotVisual(slot, foodType)
		end
	end
end

-- Single 4Hz heartbeat for all AppleTree machines. respawnDelay is
-- 1s by default, so a quarter-second tick keeps perceived latency low
-- without burning cycles.
task.spawn(function()
	while true do
		task.wait(0.25)
		for machine, s in pairs(state) do
			if machine.Parent then tickRespawns(machine, s) end
		end
	end
end)

local function refreshUpgradePrompt(machine, s)
	if not s.prompt then return end
	local feedType = feedTypeOf(machine)
	local cost     = ClickerBalance.UpgradeCost(feedType, s.level)
	local editing  = s.owner:GetAttribute("EditMode") == true

	if not cost then
		-- Max level — hide entirely.
		s.prompt.Enabled    = false
		s.prompt.ActionText = ""
		return
	end

	s.prompt.Enabled    = not editing
	s.prompt.ActionText = string.format("Upgrade — $%d", cost)
end

local function tryUpgrade(machine, s, player)
	if player ~= s.owner then return end
	if s.owner:GetAttribute("EditMode") == true then return end

	local feedType = feedTypeOf(machine)
	local cost     = ClickerBalance.UpgradeCost(feedType, s.level)
	if not cost then return end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then return end
	local currency = profile.Data.Currency or 0
	if currency < cost then return end

	profile.Data.Currency = currency - cost
	CurrencyUpdated:FireClient(player, profile.Data.Currency)

	s.level = ClickerBalance.ClampLevel(feedType, s.level + 1)
	machine:SetAttribute("Level", s.level)

	local newFoodType = ClickerBalance.FoodAt(feedType, s.level)
	if newFoodType then reskinReadySlots(s, newFoodType) end
	refreshUpgradePrompt(machine, s)
end

local function setupSlots(machine, s)
	-- Each BaseFood child becomes a slot anchor; the original part is
	-- destroyed and replaced with a tiny invisible anchor part. The food
	-- visual (a clone of the leveled food template) parents to the anchor.
	for _, child in ipairs(machine:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "BaseFood" then
			local anchor = makeSlotAnchor(machine, child)
			child:Destroy()
			table.insert(s.slots, {
				anchor    = anchor,
				foodPart  = nil,
				state     = "ready",
				respawnAt = nil,
			})
		end
	end
	local foodType = ClickerBalance.FoodAt(feedTypeOf(machine), s.level)
	for _, slot in ipairs(s.slots) do
		slot.foodPart = spawnSlotVisual(slot, foodType)
	end
end

local function setupClickDetector(machine, s)
	local primary = machine.PrimaryPart
	if not primary then return end
	local detector = Instance.new("ClickDetector")
	detector.MaxActivationDistance = 24
	detector.Parent = primary

	table.insert(s.conns, detector.MouseClick:Connect(function(player)
		if player ~= s.owner then return end
		if s.owner:GetAttribute("EditMode") == true then return end

		local cooldown = s.balance.clickCooldown or 0.5
		local now = os.clock()
		if now - s.lastClick < cooldown then return end

		local slot = findReadySlot(s)
		if not slot then return end
		if dropFruitFromSlot(machine, s, slot) then
			s.lastClick = now
		end
	end))
end

local function setupUpgradePrompt(machine, s)
	local primary = machine.PrimaryPart
	if not primary then return end

	local promptAnchor = Instance.new("Attachment")
	promptAnchor.Name     = "UpgradeAnchor"
	promptAnchor.Position = Vector3.new(0, -primary.Size.Y / 2 + 0.5, 0)
	promptAnchor.Parent   = primary

	local prompt                 = Instance.new("ProximityPrompt")
	prompt.ActionText            = ""
	prompt.KeyboardKeyCode       = Enum.KeyCode.E
	prompt.HoldDuration          = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight   = false
	prompt.Parent                = promptAnchor

	s.prompt = prompt
	table.insert(s.conns, prompt.Triggered:Connect(function(player)
		tryUpgrade(machine, s, player)
	end))
	refreshUpgradePrompt(machine, s)
end

function AppleTree.Setup(machine, plot, owner)
	if not machine:IsA("Model") or not machine.PrimaryPart then
		warn("[AppleTree] expected Model with PrimaryPart, got " .. tostring(machine.ClassName))
		return
	end

	local feedType = feedTypeOf(machine)
	local balance  = ClickerBalance.Get(feedType)
	if not balance then
		warn(string.format("[AppleTree] no ClickerBalance entry for FeedType %q", feedType))
		return
	end

	local s = {
		owner     = owner,
		plot      = plot,
		level     = 1,
		lastClick = 0,
		slots     = {},
		balance   = balance,
		conns     = {},
	}
	state[machine] = s

	-- Owner identity is published as an attribute so the client-side UI
	-- script can hide the upgrade prompt for non-owners.
	machine:SetAttribute("OwnerUserId", owner.UserId)
	machine:SetAttribute("Level", s.level)

	setupSlots(machine, s)
	setupClickDetector(machine, s)
	setupUpgradePrompt(machine, s)

	table.insert(s.conns, owner:GetAttributeChangedSignal("EditMode"):Connect(function()
		refreshUpgradePrompt(machine, s)
	end))
end

function AppleTree.Teardown(machine)
	local s = state[machine]
	if not s then return end
	for _, c in ipairs(s.conns) do c:Disconnect() end
	state[machine] = nil
end

function AppleTree.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	return { level = s.level }
end

function AppleTree.Apply(machine, placement)
	local s = state[machine]
	if not s or type(placement) ~= "table" then return end
	local feedType = feedTypeOf(machine)
	local level    = ClickerBalance.ClampLevel(feedType, tonumber(placement.level) or 1)
	s.level = level
	machine:SetAttribute("Level", level)

	local foodType = ClickerBalance.FoodAt(feedType, level)
	if foodType then reskinReadySlots(s, foodType) end
	refreshUpgradePrompt(machine, s)
end

return AppleTree
