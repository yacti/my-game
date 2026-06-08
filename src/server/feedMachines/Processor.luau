-- Processor FeedMachine: client-local prompts stay available and context-switch
-- between Deposit and Take based on what the owner has equipped. The server
-- only validates and performs the requested action.
--
--   owner has accepted food group equipped → "Deposit Food", queues one
--   owner empty-handed and ReadyCount > 0  → "Take Food", dispenses all ready
--   owner has wrong food group equipped    → error notification
--
-- Each item processes for ProcessDuration wall-clock seconds (so progress
-- accrues offline). Dispensed Tools preserve the deposited tool's XP, boosted
-- by the machine's XPMultiplier attribute.
--
-- Tunable attributes on the template (see Shared.State.Feed):
--   FoodType         (string,  default "Fruit")     accepted food group; "Any" accepts all food
--   ProcessDuration  (number,  default 30 seconds)  per item
--   XPMultiplier     (number,  default 2)           multiplier applied to dispensed XP
--   MaxQueue         (number,  default 5)
--
-- Persistence: the queue (foodId + depositedAt as os.time() Unix seconds)
-- is serialized into the FeedPlacement record by Serialize() and restored
-- on plot load via Apply(). Because depositedAt is wall-clock, items
-- finish processing while the player is offline.
--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent.Parent
local NotificationService = require(Server:WaitForChild("NotificationService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Food    = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State   = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local Processor = {}
local ProcessorDepositEffect = Remotes.get(Remotes.Names.ProcessorDepositEffect)

-- [machine] = { owner, plot, queue: { { foodId, xp, depositedAt }, ... } }
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

local function notifyWrongFoodType(machine, player, accepted)
	local processorName = machine.Name
	NotificationService.Error(player, string.format(
		"This won't work, you can only place \"%s\" inside the \"%s\"!",
		tostring(accepted or "Food"),
		tostring(processorName)
	))
end

local function xpMultiplierFor(machine)
	local multiplier = machine:GetAttribute(State.Feed.XPMultiplier)
	if type(multiplier) ~= "number" or multiplier <= 0 then
		multiplier = machine:GetAttribute(State.Feed.XP)
	end
	if type(multiplier) ~= "number" or multiplier <= 0 then
		return 2
	end
	return multiplier
end

local function refreshAttrs(machine, s, nowOverride)
	local now      = tonumber(nowOverride) or s.freezeNow or os.time()
	local duration = machine:GetAttribute(State.Feed.ProcessDuration) or 30
	local ready    = 0
	local queueReadyAt = nil
	for _, item in ipairs(s.queue) do
		local readyAt = item.depositedAt + duration
		if now >= readyAt then ready += 1 end
		if queueReadyAt == nil or readyAt > queueReadyAt then
			queueReadyAt = readyAt
		end
	end
	machine:SetAttribute(State.Feed.QueueCount, #s.queue)
	machine:SetAttribute(State.Feed.ReadyCount, ready)
	machine:SetAttribute(State.Feed.QueueReadyAt, queueReadyAt)
end

-- Single shared heartbeat keeps replicated queue/ready counts fresh for
-- client-local prompt context.
RuntimeGuard.Spawn("Processor.RefreshLoop", function()
	while true do
		task.wait(1)
		for machine, s in pairs(state) do
			if machine.Parent then
				RuntimeGuard.Run("Processor.RefreshAttrs", refreshAttrs, machine, s)
			end
		end
	end
end)

local function dispenseAllReady(machine, s, player)
	local now      = os.time()
	local duration = machine:GetAttribute(State.Feed.ProcessDuration) or 30
	local mult     = xpMultiplierFor(machine)

	local i = 1
	while i <= #s.queue do
		local item = s.queue[i]
		if now - item.depositedAt >= duration then
			table.remove(s.queue, i)
			local foodId = item.foodId or item.foodType -- foodType kept for old saves
			local inputXP = tonumber(item.xp) or Food.BaseXP(foodId)
			local boostXP = inputXP * mult
			local tool    = Food.MakeTool(foodId, boostXP)
			if tool then
				if not ToolGrantService.GrantTool(player, tool) then
					tool:Destroy()
				end
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
	local foodXP = Food.XPOf(food)
	if foodXP == nil then return end
	local foodGuid = ToolIdentity.EnsureGuid(food)
	if not ToolIdentity.DestroyIfGuidMatches(food, foodGuid) then return end
	table.insert(s.queue, { foodId = foodId, xp = foodXP, depositedAt = os.time() })
	refreshAttrs(machine, s)
	RuntimeGuard.Run("Processor.DepositEffect", function()
		ProcessorDepositEffect:FireClient(player, machine, foodId)
	end)
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
	local equippedFood = Food.GetEquipped(player, nil)
	if equippedFood ~= nil and accepted ~= nil and Food.TypeOf(equippedFood) ~= accepted then
		notifyWrongFoodType(machine, player, accepted)
		return
	end

	local canDeposit = equippedFood ~= nil and #s.queue < maxQueue
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
		queue[#queue+1] = {
			foodId = item.foodId or item.foodType,
			xp = item.xp,
			depositedAt = item.depositedAt,
		}
	end
	return { queue = queue }
end

function Processor.Apply(machine, placement, options)
	local s = state[machine]
	if not s then return end
	options = type(options) == "table" and options or {}
	if type(placement.queue) == "table" then
		for _, item in ipairs(placement.queue) do
			if type(item) == "table" and (item.foodId or item.foodType) and item.depositedAt then
				table.insert(s.queue, {
					foodId = item.foodId or item.foodType,
					xp = item.xp,
					depositedAt = item.depositedAt,
				})
			end
		end
		if options.deferOfflineProgress == true then
			s.freezeNow = tonumber(options.freezeAt) or os.time()
		end
		refreshAttrs(machine, s)
	end
end

function Processor.ApplyOfflineProgress(machine, context)
	local s = state[machine]
	if not s then return true end
	context = type(context) == "table" and context or {}
	local joinTime = tonumber(context.joinTime) or os.time()
	local applyTime = tonumber(context.applyTime) or os.time()
	local pendingDuration = math.max(applyTime - joinTime, 0)
	local duration = machine:GetAttribute(State.Feed.ProcessDuration) or 30
	for _, item in ipairs(s.queue) do
		local depositedAt = tonumber(item.depositedAt)
		if depositedAt and depositedAt + duration > joinTime then
			item.depositedAt = depositedAt + pendingDuration
		end
	end
	s.freezeNow = nil
	refreshAttrs(machine, s)
	return true
end

return Processor
