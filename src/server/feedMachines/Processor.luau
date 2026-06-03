-- Processor FeedMachine: client-local prompts context-switch between Deposit
-- and Take based on what the owner has equipped. The server only validates
-- and performs the requested action.
--
--   owner has accepted food group equipped → "Deposit Food", queues one
--   owner empty-handed and ReadyCount > 0  → "Take Food", dispenses all ready
--   neither                                → prompt disabled
--
-- Each item processes for ProcessDuration wall-clock seconds (so progress
-- accrues offline). Dispensed Tools have XP boosted by the machine's XP
-- attribute.
--
-- Tunable attributes on the template (see Shared.State.Feed):
--   FoodType         (string,  default "Fruit")     accepted food group; "Any" accepts all food
--   ProcessDuration  (number,  default 30 seconds)  per item
--   XP               (number,  default 2)           multiplier applied to dispensed XP
--   MaxQueue         (number,  default 5)
--
-- Persistence: the queue (foodId + depositedAt as os.time() Unix seconds)
-- is serialized into the FeedPlacement record by Serialize() and restored
-- on plot load via Apply(). Because depositedAt is wall-clock, items
-- finish processing while the player is offline.
--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Food    = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local State   = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local Processor = {}
local ProcessorDepositEffect = Remotes.get(Remotes.Names.ProcessorDepositEffect)

-- [machine] = { owner, plot, queue: { { foodId, depositedAt }, ... } }
local state = {}

local function acceptedFoodType(machine)
	local foodType = machine:GetAttribute(State.Feed.FoodType)
	if foodType == "Any" then
		return nil
	end
	if type(foodType) ~= "string" or foodType == "" then
		return "Fruit"
	end
	return foodType
end

local function refreshAttrs(machine, s)
	local now      = os.time()
	local duration = machine:GetAttribute(State.Feed.ProcessDuration) or 30
	local ready    = 0
	for _, item in ipairs(s.queue) do
		if now - item.depositedAt >= duration then ready += 1 end
	end
	machine:SetAttribute(State.Feed.QueueCount, #s.queue)
	machine:SetAttribute(State.Feed.ReadyCount, ready)
end

-- Single shared heartbeat keeps replicated queue/ready counts fresh for
-- client-local prompt context.
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
	local mult     = machine:GetAttribute(State.Feed.XP) or 2

	local i = 1
	while i <= #s.queue do
		local item = s.queue[i]
		if now - item.depositedAt >= duration then
			table.remove(s.queue, i)
			local foodId = item.foodId or item.foodType -- foodType kept for old saves
			local boostXP = Food.BaseXP(foodId) * mult
			local tool    = Food.MakeTool(foodId, boostXP)
			if tool then
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
	local accepted = acceptedFoodType(machine)
	local food = Food.GetEquipped(player, accepted)
	if not food then return end
	local foodId = Food.IdOf(food)
	if not foodId then return end
	local foodGuid = ToolIdentity.EnsureGuid(food)
	if not ToolIdentity.DestroyIfGuidMatches(food, foodGuid) then return end
	table.insert(s.queue, { foodId = foodId, depositedAt = os.time() })
	refreshAttrs(machine, s)
	ProcessorDepositEffect:FireClient(player, machine, foodId)
end

local function promptParentFor(machine)
	if machine:IsA("BasePart") then return machine end
	if machine:IsA("Model") then return machine.PrimaryPart end
	return nil
end

function Processor.Setup(machine, plot, owner)
	local promptParent = promptParentFor(machine)
	if not promptParent then
		warn("[Processor] expected BasePart or Model with PrimaryPart")
		return
	end

	local s = { owner = owner, plot = plot, queue = {} }
	state[machine] = s
	refreshAttrs(machine, s)
end

function Processor.Teardown(machine)
	state[machine] = nil
end

function Processor.Interact(machine, player)
	local s = state[machine]
	if not s or player ~= s.owner then return end
	if s.owner:GetAttribute("EditMode") == true then return end

	local accepted   = acceptedFoodType(machine)
	local maxQueue   = machine:GetAttribute(State.Feed.MaxQueue) or 5
	local canDeposit = Food.GetEquipped(player, accepted) ~= nil and #s.queue < maxQueue
	if canDeposit then
		depositOne(machine, s, player)
	else
		dispenseAllReady(machine, s, player)
	end
end

function Processor.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local queue = table.create(#s.queue)
	for _, item in ipairs(s.queue) do
		queue[#queue+1] = { foodId = item.foodId or item.foodType, depositedAt = item.depositedAt }
	end
	return { queue = queue }
end

function Processor.Apply(machine, placement)
	local s = state[machine]
	if not s then return end
	if type(placement.queue) == "table" then
		for _, item in ipairs(placement.queue) do
			if type(item) == "table" and (item.foodId or item.foodType) and item.depositedAt then
				table.insert(s.queue, { foodId = item.foodId or item.foodType, depositedAt = item.depositedAt })
			end
		end
		refreshAttrs(machine, s)
	end
end

return Processor
