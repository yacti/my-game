-- Processor FeedMachine: a single ProximityPrompt context-switches between
-- Deposit and Take based on what the owner has equipped.
--
--   owner has accepted food equipped       → "Deposit Food", queues one
--   owner empty-handed and ReadyCount > 0  → "Take Food", dispenses all ready
--   neither                                → prompt disabled
--
-- Each item processes for ProcessDuration wall-clock seconds (so progress
-- accrues offline). Dispensed Tools have XP boosted by XPMultiplier.
--
-- Tunable attributes on the template (see Shared.State.Feed):
--   FoodType         (string,  default "Apple")     accepted food type
--   ProcessDuration  (number,  default 30 seconds)  per item
--   XPMultiplier     (number,  default 2)           applied to dispensed XP
--   MaxQueue         (number,  default 5)
--
-- Persistence: the queue (foodType + depositedAt as os.time() Unix seconds)
-- is serialized into the FeedPlacement record by Serialize() and restored
-- on plot load via Apply(). Because depositedAt is wall-clock, items
-- finish processing while the player is offline.
--
-- Note: picking up the machine while items are queued loses them. The
-- inventory pickup logic in init.server.luau refuses pickup when
-- QueueCount > 0.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(ReplicatedStorage.Shared:WaitForChild("State"))
local Food  = require(ReplicatedStorage.Shared:WaitForChild("Food"))

local Processor = {}

-- [machine] = { owner, plot, queue: { { foodType, depositedAt }, ... }, prompt }
local state = {}

local function refreshAttrs(machine, s)
	local now      = os.time()
	local duration = machine:GetAttribute(State.Feed.ProcessDuration) or 30
	local accepted = machine:GetAttribute(State.Feed.FoodType) or "Apple"
	local ready    = 0
	for _, item in ipairs(s.queue) do
		if now - item.depositedAt >= duration then ready += 1 end
	end
	machine:SetAttribute(State.Feed.QueueCount, #s.queue)
	machine:SetAttribute(State.Feed.ReadyCount, ready)

	if s.prompt then
		local hasEquipped = Food.GetEquipped(s.owner, accepted) ~= nil
		if hasEquipped then
			s.prompt.ActionText = "Deposit Food"
			s.prompt.Enabled    = true
		elseif ready > 0 then
			s.prompt.ActionText = "Take Food"
			s.prompt.Enabled    = true
		else
			s.prompt.Enabled    = false
		end
	end
end

-- Single shared heartbeat: keeps ready count + prompt context fresh
-- across all processors.
task.spawn(function()
	while true do
		task.wait(1)
		for machine, s in pairs(state) do
			if machine.Parent then refreshAttrs(machine, s) end
		end
	end
end)

local function dispenseAllReady(machine, s, player)
	local now      = os.time()
	local duration = machine:GetAttribute(State.Feed.ProcessDuration) or 30
	local mult     = machine:GetAttribute(State.Feed.XPMultiplier) or 2

	local i = 1
	while i <= #s.queue do
		local item = s.queue[i]
		if now - item.depositedAt >= duration then
			table.remove(s.queue, i)
			local boostXP = Food.BaseXP(item.foodType) * mult
			local tool    = Food.MakeTool(item.foodType, boostXP)
			if tool then
				tool:SetAttribute("XPMultiplier", mult)
				tool.Parent = player.Backpack
			end
		else
			i += 1
		end
	end
	refreshAttrs(machine, s)
end

local function depositOne(machine, s, player)
	local maxQueue = machine:GetAttribute(State.Feed.MaxQueue) or 5
	if #s.queue >= maxQueue then return end
	local accepted = machine:GetAttribute(State.Feed.FoodType) or "Apple"
	local food = Food.GetEquipped(player, accepted)
	if not food then return end
	local foodType = food:GetAttribute(State.Food.Type)
	food:Destroy()
	table.insert(s.queue, { foodType = foodType, depositedAt = os.time() })
	refreshAttrs(machine, s)
end

function Processor.Setup(machine, plot, owner)
	local s = { owner = owner, plot = plot, queue = {} }
	state[machine] = s

	-- Single context-switching prompt: Deposit when food equipped, Take
	-- when ready food is waiting.
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText      = "Take Food"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration    = 0
	prompt.UIOffset        = Vector2.new(0, -60)
	prompt.Enabled         = false
	prompt.Parent          = machine
	s.prompt = prompt

	prompt.Triggered:Connect(function(player)
		if player ~= owner then return end
		local accepted = machine:GetAttribute(State.Feed.FoodType) or "Apple"
		if Food.GetEquipped(player, accepted) then
			depositOne(machine, s, player)
		else
			dispenseAllReady(machine, s, player)
		end
	end)
end

function Processor.Teardown(machine)
	state[machine] = nil
end

function Processor.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local queue = table.create(#s.queue)
	for _, item in ipairs(s.queue) do
		queue[#queue+1] = { foodType = item.foodType, depositedAt = item.depositedAt }
	end
	return { queue = queue }
end

function Processor.Apply(machine, placement)
	local s = state[machine]
	if not s then return end
	if type(placement.queue) == "table" then
		for _, item in ipairs(placement.queue) do
			if type(item) == "table" and item.foodType and item.depositedAt then
				table.insert(s.queue, { foodType = item.foodType, depositedAt = item.depositedAt })
			end
		end
		refreshAttrs(machine, s)
	end
end

return Processor
