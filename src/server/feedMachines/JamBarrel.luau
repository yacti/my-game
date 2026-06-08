-- Jam Barrel FeedMachine: held fruit goes in, generated jam food comes out.
-- The queue processes sequentially using absolute readyAt timestamps, so work
-- continues while the player is offline and restores through placement state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent.Parent
local NotificationService = require(Server:WaitForChild("NotificationService"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local JamBarrel = {}
local ProcessorDepositEffect = Remotes.get(Remotes.Names.ProcessorDepositEffect)

-- [machine] = { owner, plot, queue: { { sourceFoodId, sourceXP, readyAt }, ... } }
local state = {}

local function feedTypeOf(machine)
	local feedType = machine:GetAttribute(State.Feed.Type)
	if type(feedType) == "string" and feedType ~= "" then
		return feedType
	end
	return "JamBarrel"
end

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

local function durationFor(machine)
	local duration = machine:GetAttribute(State.Feed.ProcessDuration)
	if type(duration) ~= "number" or duration <= 0 then
		return 30
	end
	return duration
end

local function maxQueueFor(machine)
	local maxQueue = machine:GetAttribute(State.Feed.MaxQueue)
	if type(maxQueue) ~= "number" or maxQueue <= 0 then
		return 5
	end
	return math.floor(maxQueue)
end

local function xpMultiplierFor(machine)
	local multiplier = machine:GetAttribute(State.Feed.XPMultiplier)
	if type(multiplier) ~= "number" or multiplier <= 0 then
		multiplier = machine:GetAttribute(State.Feed.XP)
	end
	if type(multiplier) ~= "number" or multiplier <= 0 then
		return 1
	end
	return multiplier
end

local function refreshAttrs(machine, s, nowOverride)
	local now = tonumber(nowOverride) or s.freezeNow or os.time()
	local ready = 0
	local queueReadyAt = nil
	for _, item in ipairs(s.queue) do
		if type(item.readyAt) == "number" and now >= item.readyAt then
			ready += 1
		end
		if type(item.readyAt) == "number" and (queueReadyAt == nil or item.readyAt > queueReadyAt) then
			queueReadyAt = item.readyAt
		end
	end
	machine:SetAttribute(State.Feed.QueueCount, #s.queue)
	machine:SetAttribute(State.Feed.ReadyCount, ready)
	machine:SetAttribute(State.Feed.QueueReadyAt, queueReadyAt)
end

RuntimeGuard.Spawn("JamBarrel.RefreshLoop", function()
	while true do
		task.wait(1)
		for machine, s in pairs(state) do
			if machine.Parent then
				RuntimeGuard.Run("JamBarrel.RefreshAttrs", refreshAttrs, machine, s)
			end
		end
	end
end)

local function notifyWrongFoodType(machine, player, accepted)
	NotificationService.Error(player, string.format(
		"This won't work, you can only place \"%s\" inside the \"%s\"!",
		tostring(accepted or "Food"),
		tostring(machine.Name)
	))
end

local function notifyJamInput(player)
	NotificationService.Error(player, "This won't work, you can't process jam again!")
end

local function nextReadyAt(machine, s)
	local readyAt = os.time()
	for _, item in ipairs(s.queue) do
		if type(item.readyAt) == "number" and item.readyAt > readyAt then
			readyAt = item.readyAt
		end
	end
	return readyAt + durationFor(machine)
end

local function dispenseAllReady(machine, s, player)
	local now = os.time()
	local producerFeedType = feedTypeOf(machine)
	local multiplier = xpMultiplierFor(machine)

	local i = 1
	while i <= #s.queue do
		local item = s.queue[i]
		if type(item.readyAt) == "number" and now >= item.readyAt then
			table.remove(s.queue, i)
			local sourceFoodId = item.sourceFoodId or item.foodId or item.foodType
			if type(sourceFoodId) == "string" and sourceFoodId ~= "" then
				local sourceXP = tonumber(item.sourceXP) or tonumber(item.xp) or Food.BaseXP(sourceFoodId)
				local boostXP = sourceXP * multiplier
				local tool = Food.MakeJamTool(producerFeedType, sourceFoodId, boostXP)
				if tool then
					if not ToolGrantService.GrantTool(player, tool) then
						tool:Destroy()
					end
				end
			end
		else
			i += 1
		end
	end
	refreshAttrs(machine, s)
end

local function depositOne(machine, s, player, food)
	if #s.queue >= maxQueueFor(machine) then return end

	local sourceFoodId = Food.IdOf(food)
	if type(sourceFoodId) ~= "string" or sourceFoodId == "" then return end
	if Food.IsJamFoodId(sourceFoodId) then
		notifyJamInput(player)
		return
	end
	local sourceXP = Food.XPOf(food)
	if sourceXP == nil then return end

	local foodGuid = ToolIdentity.EnsureGuid(food)
	if not ToolIdentity.DestroyIfGuidMatches(food, foodGuid) then return end

	table.insert(s.queue, {
		sourceFoodId = sourceFoodId,
		sourceXP = sourceXP,
		readyAt = nextReadyAt(machine, s),
	})
	refreshAttrs(machine, s)
	RuntimeGuard.Run("JamBarrel.DepositEffect", function()
		ProcessorDepositEffect:FireClient(player, machine, sourceFoodId)
	end)
end

local function promptParentFor(machine)
	if machine:IsA("BasePart") then return machine end
	if machine:IsA("Model") then return machine.PrimaryPart end
	return nil
end

function JamBarrel.Setup(machine, plot, owner)
	local promptParent = promptParentFor(machine)
	if not promptParent then
		warn("[JamBarrel] expected BasePart or Model with PrimaryPart")
		return
	end

	local s = { owner = owner, plot = plot, queue = {} }
	state[machine] = s
	refreshAttrs(machine, s)
end

function JamBarrel.Teardown(machine)
	state[machine] = nil
end

function JamBarrel.Interact(machine, player)
	local s = state[machine]
	if not s or player ~= s.owner then return end
	if s.owner:GetAttribute("EditMode") == true then return end

	local equippedFood = Food.GetEquipped(player, nil)
	if equippedFood then
		local sourceFoodId = Food.IdOf(equippedFood)
		if Food.IsJamFoodId(sourceFoodId) then
			notifyJamInput(player)
			return
		end

		local accepted = acceptedFoodType(machine)
		if accepted ~= nil and Food.TypeOf(equippedFood) ~= accepted then
			notifyWrongFoodType(machine, player, accepted)
			return
		end

		if #s.queue < maxQueueFor(machine) then
			depositOne(machine, s, player, equippedFood)
			return
		end
	end

	dispenseAllReady(machine, s, player)
end

function JamBarrel.Serialize(machine)
	local s = state[machine]
	if not s then return nil end
	local queue = table.create(#s.queue)
	for _, item in ipairs(s.queue) do
		queue[#queue + 1] = {
			sourceFoodId = item.sourceFoodId or item.foodId or item.foodType,
			sourceXP = item.sourceXP or item.xp,
			readyAt = item.readyAt,
		}
	end
	return { queue = queue }
end

function JamBarrel.Apply(machine, placement, options)
	local s = state[machine]
	if not s then return end
	if type(placement.queue) ~= "table" then return end
	options = type(options) == "table" and options or {}

	local duration = durationFor(machine)
	for _, item in ipairs(placement.queue) do
		if type(item) == "table" then
			local sourceFoodId = item.sourceFoodId or item.foodId or item.foodType
			local sourceXP = item.sourceXP or item.xp
			local readyAt = item.readyAt
			if type(readyAt) ~= "number" and type(item.depositedAt) == "number" then
				readyAt = item.depositedAt + duration
			end
			if type(sourceFoodId) == "string" and sourceFoodId ~= "" and type(readyAt) == "number" then
				table.insert(s.queue, {
					sourceFoodId = sourceFoodId,
					sourceXP = sourceXP,
					readyAt = readyAt,
				})
			end
		end
	end
	if options.deferOfflineProgress == true then
		s.freezeNow = tonumber(options.freezeAt) or os.time()
	end
	refreshAttrs(machine, s)
end

function JamBarrel.ApplyOfflineProgress(machine, context)
	local s = state[machine]
	if not s then return true end
	context = type(context) == "table" and context or {}
	local joinTime = tonumber(context.joinTime) or os.time()
	local applyTime = tonumber(context.applyTime) or os.time()
	local pendingDuration = math.max(applyTime - joinTime, 0)
	for _, item in ipairs(s.queue) do
		local readyAt = tonumber(item.readyAt)
		if readyAt and readyAt > joinTime then
			item.readyAt = readyAt + pendingDuration
		end
	end
	s.freezeNow = nil
	refreshAttrs(machine, s)
	return true
end

return JamBarrel
