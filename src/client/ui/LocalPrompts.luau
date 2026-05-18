-- Client-local ProximityPrompts. The prompt instances and their contextual text
-- are local presentation only; every trigger sends an intent to the server,
-- where ownership, distance, edit mode, inventory, and machine state are
-- validated before anything changes.

local Players           = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Food    = require(Shared:WaitForChild("Food"))
local Interactions = require(Shared:WaitForChild("Interactions"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local PlotSizes = require(Shared:WaitForChild("PlotSizes"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local State   = require(Shared:WaitForChild("State"))

local PromptInteract = Remotes.get(Remotes.Names.PromptInteract)

local LocalPrompts = {}

local player = Players.LocalPlayer
local backpack = player:WaitForChild("Backpack")
local byTarget = {} -- [Instance] = { [kind] = ProximityPrompt }
local pendingPromptParents = setmetatable({}, { __mode = "k" }) -- [Instance] = { [kind] = { RBXScriptConnection } }

local PROMPT_ATTACHMENT_PREFIX = "__LocalPromptAttachment_"
local DEFAULT_PROMPT_DISTANCE = 10
local PET_FEED_PROMPT_DISTANCE = 8
local FOOD_PICKUP_PROMPT_DISTANCE = 8

local function findPlotByName(plotName)
	if type(plotName) ~= "string" or plotName == "" then return nil end
	local plotsFolder = Workspace:FindFirstChild("Plots")
	local plot = plotsFolder and plotsFolder:FindFirstChild(plotName) or nil
	return plot or Workspace:FindFirstChild(plotName)
end

local function getPlot()
	local assignedPlotName = player:GetAttribute(State.Player.AssignedPlotName)
	local assignedPlot = findPlotByName(assignedPlotName)
	if assignedPlot then return assignedPlot end

	local spawnLocation = player.RespawnLocation
	return spawnLocation and spawnLocation.Parent or nil
end

local function isInOwnPlot(instance)
	local plot = getPlot()
	if plot == nil then return nil end
	return instance ~= nil and instance:IsDescendantOf(plot)
end

local function equippedTool()
	local character = player.Character
	return character and character:FindFirstChildWhichIsA("Tool") or nil
end

local function isEditMode()
	local tool = equippedTool()
	return (tool ~= nil and tool.Name == "EditTool") or player:GetAttribute("EditMode") == true
end

local function promptPartFor(instance)
	if instance:IsA("BasePart") then return instance end
	if instance:IsA("Model") then return instance.PrimaryPart end
	return nil
end

local function playerRootPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function promptWorldPosition(prompt)
	local parent = prompt.Parent
	if parent and parent:IsA("Attachment") then return parent.WorldPosition end
	if parent and parent:IsA("BasePart") then return parent.Position end
	return nil
end

local function promptDistance(prompt, rootPosition)
	local position = promptWorldPosition(prompt)
	return position and (position - rootPosition).Magnitude or nil
end

local function promptParentFor(instance, kind)
	local part = promptPartFor(instance)
	if not part then return nil end

	local attachmentName = PROMPT_ATTACHMENT_PREFIX .. kind
	local attachment = part:FindFirstChild(attachmentName)
	if attachment then
		return attachment:IsA("Attachment") and attachment or part
	end

	attachment = Instance.new("Attachment")
	attachment.Name = attachmentName
	attachment.Parent = part
	return attachment
end

local function isTreeGroundPickupTarget(instance)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.TreeClicker.GroundPile) == true
		and instance.Parent ~= nil
		and instance.Parent.Name == State.TreeClicker.GroundFolder
end

local function isFeedMachine(instance)
	local feedType = instance:GetAttribute(State.Feed.Type)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(feedType) == "string"
		and feedType ~= ""
		and instance:GetAttribute(State.Feed.Index) ~= nil
end

local function isProcessor(machine)
	return machine:GetAttribute(State.Feed.Class) == "Processor"
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
	local maxXP = pet:GetAttribute(State.Pet.MaxXP)
	if type(maxXP) ~= "number" or maxXP <= 0 then return false end

	local xp = pet:GetAttribute(State.Pet.XP)
	if type(xp) ~= "number" or xp < maxXP then return true end

	return PetCatalog.NextPetId(pet:GetAttribute(State.Pet.Id)) ~= nil
end

local function plotSize()
	return PlotSizes.Clamp(player:GetAttribute(State.Player.PlotSize))
end

local function plotUpgradeText()
	local nextSize = PlotSizes.NextSize(plotSize())
	if not nextSize then
		return false, "Max Size"
	end

	local price = PlotSizes.UpgradePrice(nextSize)
	if type(price) ~= "number" then
		return false, "Upgrade"
	end
	return true, "Upgrade: $" .. tostring(price)
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

local function promptActivationDistance(kind)
	if kind == "PetFeed" then return PET_FEED_PROMPT_DISTANCE end
	if kind == "TreeGroundPickup" then return FOOD_PICKUP_PROMPT_DISTANCE end
	return DEFAULT_PROMPT_DISTANCE
end

local function configurePrompt(prompt, kind)
	prompt.Name = "__LocalPrompt_" .. kind
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = promptActivationDistance(kind)
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	if kind == "FeedPickup" then
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.HoldDuration = 0.5
	else
		prompt.KeyboardKeyCode = Enum.KeyCode.E
	end
end

local function removePrompt(target, kind)
	local pendingBucket = pendingPromptParents[target]
	local pendingConnections = pendingBucket and pendingBucket[kind]
	if pendingConnections then
		for _, connection in ipairs(pendingConnections) do
			connection:Disconnect()
		end
		pendingBucket[kind] = nil
		if next(pendingBucket) == nil then pendingPromptParents[target] = nil end
	end

	local bucket = byTarget[target]
	local prompt = bucket and bucket[kind]
	if prompt then
		local parent = prompt.Parent
		prompt:Destroy()
		if parent and parent:IsA("Attachment") and parent.Name == PROMPT_ATTACHMENT_PREFIX .. kind then
			parent:Destroy()
		end
	end
	if bucket then
		bucket[kind] = nil
		if next(bucket) == nil then byTarget[target] = nil end
	end
end

local addPrompt

local function waitForPromptParent(target, kind, action)
	if not target:IsA("Model") then return end

	pendingPromptParents[target] = pendingPromptParents[target] or {}
	if pendingPromptParents[target][kind] then return end

	local connections = {}
	local function clearPending()
		local bucket = pendingPromptParents[target]
		if not bucket or bucket[kind] ~= connections then return end
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		bucket[kind] = nil
		if next(bucket) == nil then pendingPromptParents[target] = nil end
	end

	local function retry()
		if not target:IsDescendantOf(Workspace) then
			clearPending()
			return
		end
		if promptPartFor(target) then
			clearPending()
			addPrompt(target, kind, action)
		end
	end

	connections[#connections + 1] = target:GetPropertyChangedSignal("PrimaryPart"):Connect(retry)
	connections[#connections + 1] = target.AncestryChanged:Connect(retry)
	pendingPromptParents[target][kind] = connections
	task.defer(retry)
end

addPrompt = function(target, kind, action)
	if not target then return end
	local parent = promptParentFor(target, kind)
	if not parent then
		waitForPromptParent(target, kind, action)
		return
	end
	byTarget[target] = byTarget[target] or {}
	if byTarget[target][kind] then return end

	local prompt = Instance.new("ProximityPrompt")
	configurePrompt(prompt, kind)
	prompt.Parent = parent
	prompt.Triggered:Connect(function()
		if kind == "TreeGroundPickup" then
			prompt.Enabled = false
		end
		PromptInteract:FireServer(action, target)
	end)
	target.AncestryChanged:Connect(function()
		if not target:IsDescendantOf(Workspace) then
			removePrompt(target, kind)
		end
	end)

	byTarget[target][kind] = prompt
end

local function tryBind(instance)
	if isInOwnPlot(instance) ~= true then return end

	if instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil then
		addPrompt(instance, "PetFeed", Interactions.Actions.PetFeed)
	end

	if isFeedMachine(instance) then
		addPrompt(instance, "FeedPickup", Interactions.Actions.FeedPickup)
		if isProcessor(instance) then
			addPrompt(instance, "FeedMachine", Interactions.Actions.FeedMachine)
		end
	end

	if instance:IsA("BasePart") and instance.Name == "SlotAnchor" then
		local machine = instance.Parent
		if machine and machine:GetAttribute(State.Feed.Class) == "Patch" then
			addPrompt(instance, "PatchHarvest", Interactions.Actions.PatchHarvest)
		end
	end

	if isTreeGroundPickupTarget(instance) then
		addPrompt(instance, "TreeGroundPickup", Interactions.Actions.TreeGroundPickup)
	end

	if instance:IsA("BasePart") and instance.Name == "UpgradeSize" then
		addPrompt(instance, "PlotSizeUpgrade", Interactions.Actions.PlotSizeUpgrade)
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
	if prompt.Parent == nil or target.Parent == nil then
		removePrompt(target, kind)
		return
	end
	local inOwnPlot = isInOwnPlot(target)
	if inOwnPlot == nil then
		prompt.Enabled = false
		return
	end
	if inOwnPlot == false then
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
		if not isTreeGroundPickupTarget(target) then
			removePrompt(target, kind)
			return
		end
		prompt.ActionText = "Pick Up"
		prompt.Enabled = not isEditMode()
	elseif kind == "PlotSizeUpgrade" then
		local canUpgrade, actionText = plotUpgradeText()
		prompt.ObjectText = "Plot Size"
		prompt.ActionText = actionText
		prompt.Enabled = not isEditMode() and canUpgrade
	end
end

local function refreshAll(shouldScan)
	if shouldScan then scanPlot() end

	local rootPosition = playerRootPosition()
	local closestPrompt = nil
	local closestDistance = math.huge

	for target, bucket in pairs(byTarget) do
		for kind, prompt in pairs(bucket) do
			refreshPrompt(target, kind, prompt)
			if prompt.Parent ~= nil and prompt.Enabled then
				local distance = rootPosition and promptDistance(prompt, rootPosition) or nil
				if distance and distance <= prompt.MaxActivationDistance then
					if distance < closestDistance then
						closestPrompt = prompt
						closestDistance = distance
					end
				else
					prompt.Enabled = false
				end
			end
		end
	end

	for _, bucket in pairs(byTarget) do
		for _, prompt in pairs(bucket) do
			if prompt.Parent ~= nil and prompt.Enabled and prompt ~= closestPrompt then
				prompt.Enabled = false
			end
		end
	end
end

function LocalPrompts.start()
	pcall(function()
		ProximityPromptService.MaxPromptsVisible = 1
	end)

	Workspace.DescendantAdded:Connect(function(instance)
		task.defer(tryBind, instance)
	end)

	player:GetAttributeChangedSignal(State.Player.AssignedPlotName):Connect(function() refreshAll(true) end)
	player:GetAttributeChangedSignal(State.Player.PlotSize):Connect(function() refreshAll(false) end)
	player:GetPropertyChangedSignal("RespawnLocation"):Connect(function() refreshAll(true) end)
	player:GetAttributeChangedSignal("EditMode"):Connect(function() refreshAll(false) end)
	local function watchCharacter(character)
		if not character then return end
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then refreshAll(false) end
		end)
		character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then refreshAll(false) end
		end)
		refreshAll(true)
	end
	player.CharacterAdded:Connect(watchCharacter)
	watchCharacter(player.Character)
	backpack.ChildAdded:Connect(function() refreshAll(false) end)
	backpack.ChildRemoved:Connect(function() refreshAll(false) end)

	task.defer(function() refreshAll(true) end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator >= 0.1 then
			accumulator = 0
			refreshAll(false)
		end
	end)
end

return LocalPrompts
