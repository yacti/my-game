-- Client-local ProximityPrompts. The prompt instances and their contextual text
-- are local presentation only; every trigger sends an intent to the server,
-- where ownership, distance, edit mode, inventory, and machine state are
-- validated before anything changes.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared:WaitForChild("Balance"))
local Food    = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local State   = require(Shared:WaitForChild("State"))

local PromptInteract = Remotes.get(Remotes.Names.PromptInteract)

local LocalPrompts = {}

local player = Players.LocalPlayer
local backpack = player:WaitForChild("Backpack")
local byTarget = {} -- [Instance] = { [kind] = ProximityPrompt }

local function getPlot()
	local spawnLocation = player.RespawnLocation
	return spawnLocation and spawnLocation.Parent or nil
end

local function isInOwnPlot(instance)
	local plot = getPlot()
	return plot ~= nil and instance ~= nil and instance:IsDescendantOf(plot)
end

local function equippedTool()
	local character = player.Character
	return character and character:FindFirstChildWhichIsA("Tool") or nil
end

local function isEditMode()
	local tool = equippedTool()
	return (tool ~= nil and tool.Name == "EditTool") or player:GetAttribute("EditMode") == true
end

local function promptParentFor(instance)
	if instance:IsA("BasePart") then return instance end
	if instance:IsA("Model") then return instance.PrimaryPart end
	return nil
end

local function isFeedMachine(instance)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.Feed.Type) ~= nil
		and instance:GetAttribute(State.Feed.Index) ~= nil
end

local function isProcessor(machine)
	return machine:GetAttribute(State.Feed.Class) == "Processor"
		or machine:GetAttribute(State.Feed.Type) == "Processor1"
end

local function acceptedFoodType(machine)
	local foodType = machine:GetAttribute(State.Feed.FoodType)
	if foodType == "Any" then return nil end
	if type(foodType) ~= "string" or foodType == "" then return "Fruit" end
	return foodType
end

local function hasSlotFood(anchor)
	for _, child in ipairs(anchor:GetChildren()) do
		if (child:IsA("BasePart") or child:IsA("Model")) and child:GetAttribute(State.Food.Id) ~= nil then
			return true
		end
	end
	return false
end

local function hasFeedablePetFood()
	return Food.FindFirstInBackpack(player) ~= nil
end

local function petCanGainXP(pet)
	local petType = pet:GetAttribute(State.Pet.Type)
	local level = Balance.PetLevelFromType(petType)
	return level < Balance.MAX_PET_LEVEL
end

local function processorContext(machine)
	if isEditMode() then return false, "Take Food" end
	local accepted = acceptedFoodType(machine)
	local maxQueue = machine:GetAttribute(State.Feed.MaxQueue) or 5
	local queueCount = machine:GetAttribute(State.Feed.QueueCount) or 0
	local readyCount = machine:GetAttribute(State.Feed.ReadyCount) or 0
	local canDeposit = Food.GetEquipped(player, accepted) ~= nil and queueCount < maxQueue
	if canDeposit then return true, "Deposit Food" end
	if readyCount > 0 then return true, "Take Food" end
	return false, "Take Food"
end

local function configurePrompt(prompt, kind)
	prompt.Name = "__LocalPrompt_" .. kind
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	if kind == "FeedPickup" then
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.HoldDuration = 0.5
	else
		prompt.KeyboardKeyCode = Enum.KeyCode.E
	end
end

local function removePrompt(target, kind)
	local bucket = byTarget[target]
	local prompt = bucket and bucket[kind]
	if prompt then prompt:Destroy() end
	if bucket then
		bucket[kind] = nil
		if next(bucket) == nil then byTarget[target] = nil end
	end
end

local function addPrompt(target, kind, action, parent)
	if not target or not parent then return end
	byTarget[target] = byTarget[target] or {}
	if byTarget[target][kind] then return end

	local prompt = Instance.new("ProximityPrompt")
	configurePrompt(prompt, kind)
	prompt.Parent = parent
	prompt.Triggered:Connect(function()
		PromptInteract:FireServer(action, target)
	end)

	byTarget[target][kind] = prompt
end

local function tryBind(instance)
	if not isInOwnPlot(instance) then return end

	if instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil then
		addPrompt(instance, "PetFeed", "PetFeed", promptParentFor(instance))
	end

	if isFeedMachine(instance) then
		local parent = promptParentFor(instance)
		addPrompt(instance, "FeedPickup", "FeedPickup", parent)
		if isProcessor(instance) then
			addPrompt(instance, "FeedMachine", "FeedMachine", parent)
		end
	end

	if instance:IsA("BasePart") and instance.Name == "SlotAnchor" then
		local machine = instance.Parent
		if machine and machine:GetAttribute(State.Feed.Class) == "Patch" then
			addPrompt(instance, "PatchHarvest", "PatchHarvest", instance)
		end
	end

	if (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.TreeClicker.GroundPile) == true
		and instance.Parent ~= nil
		and instance.Parent.Name == State.TreeClicker.GroundFolder then
		addPrompt(instance, "TreeGroundPickup", "TreeGroundPickup", promptParentFor(instance))
	end
end

local function scanPlot()
	local plot = getPlot()
	if not plot then return end
	for _, descendant in ipairs(plot:GetDescendants()) do
		tryBind(descendant)
	end
end

local function refreshPrompt(target, kind, prompt)
	if prompt.Parent == nil or target.Parent == nil or not isInOwnPlot(target) then
		removePrompt(target, kind)
		return
	end

	if kind == "PetFeed" then
		prompt.ActionText = "Feed"
		prompt.Enabled = not isEditMode() and hasFeedablePetFood() and petCanGainXP(target)
	elseif kind == "FeedPickup" then
		prompt.ActionText = "Pick Up"
		prompt.Enabled = isEditMode()
	elseif kind == "FeedMachine" then
		local enabled, actionText = processorContext(target)
		prompt.ActionText = actionText
		prompt.Enabled = enabled
	elseif kind == "PatchHarvest" then
		prompt.ActionText = "Harvest"
		prompt.Enabled = not isEditMode() and hasSlotFood(target)
	elseif kind == "TreeGroundPickup" then
		prompt.ActionText = "Pick Up"
		prompt.Enabled = not isEditMode()
	end
end

local function refreshAll()
	scanPlot()
	for target, bucket in pairs(byTarget) do
		for kind, prompt in pairs(bucket) do
			refreshPrompt(target, kind, prompt)
		end
	end
end

function LocalPrompts.start()
	Workspace.DescendantAdded:Connect(function(instance)
		task.defer(tryBind, instance)
	end)

	player:GetAttributeChangedSignal("EditMode"):Connect(refreshAll)
	local function watchCharacter(character)
		if not character then return end
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then refreshAll() end
		end)
		character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then refreshAll() end
		end)
		refreshAll()
	end
	player.CharacterAdded:Connect(watchCharacter)
	watchCharacter(player.Character)
	backpack.ChildAdded:Connect(refreshAll)
	backpack.ChildRemoved:Connect(refreshAll)

	task.defer(refreshAll)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator >= 0.1 then
			accumulator = 0
			refreshAll()
		end
	end)
end

return LocalPrompts
