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
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local RollConfig = require(Shared:WaitForChild("RollConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Shovel = require(Shared:WaitForChild("Shovel"))
local State   = require(Shared:WaitForChild("State"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local PromptInteract = Remotes.get(Remotes.Names.PromptInteract)

local LocalPrompts = {}
LocalPrompts.AutoModes = {
	Feed = "Feed",
	Collect = "Collect",
}

local player = Players.LocalPlayer
local backpack = player:WaitForChild("Backpack")
local byTarget = {} -- [Instance] = { [kind] = ProximityPrompt }
local pendingPromptParents = setmetatable({}, { __mode = "k" }) -- [Instance] = { [kind] = { RBXScriptConnection } }
local externalPrompts = setmetatable({}, { __mode = "k" }) -- [ProximityPrompt] = { isAvailable: function, allowWhileShovelEquipped: boolean }
local tutorialActive = false
local tutorialStage = Onboarding.Stages.Complete

local PROMPT_ATTACHMENT_PREFIX = "__LocalPromptAttachment_"
local PROMPT_TEMPLATE_FOLDER_NAME = "PromptTemplates"
local DEFAULT_PROMPT_TEMPLATE_NAME = "LocalPrompt"
local DEFAULT_PROMPT_DISTANCE = 10
local PET_FEED_PROMPT_DISTANCE = 8
local FOOD_PICKUP_PROMPT_DISTANCE = 8
local GRID_UNLOCK_PROMPT_DISTANCE = 5
local CRATE_ROLL_PROMPT_DISTANCE = RollConfig.Button.InteractionDistance
local CRATE_ROLL_PROMPT_Y_OFFSET = -3
local ROLL_BUTTON_UNAVAILABLE_ATTR = "RollButtonUnavailable"
local warnedInvalidPromptTemplates = {}
local warnedMissingPromptTemplates = {}
local AUTO_PROMPT_ACTIONS = {
	PetFeed = Interactions.Actions.PetFeed,
	PatchHarvest = Interactions.Actions.PatchHarvest,
	TreeGroundPickup = Interactions.Actions.TreeGroundPickup,
}

local function isLocalPromptAttachment(instance)
	return instance:IsA("Attachment") and instance.Name:sub(1, #PROMPT_ATTACHMENT_PREFIX) == PROMPT_ATTACHMENT_PREFIX
end

local function getPlot()
	return PlotResolver.ResolveForPlayer(player)
end

local function isInOwnPlot(instance)
	local plot = getPlot()
	if plot == nil then return nil end
	return instance ~= nil and instance:IsDescendantOf(plot)
end

local function isShovelEquipped()
	local character = player.Character
	if not character then
		return false
	end
	for _, child in ipairs(character:GetChildren()) do
		if Shovel.IsTool(child) then
			return true
		end
	end
	return false
end

local function isEditMode()
	return player:GetAttribute("EditMode") == true
end

local function applyTutorialState(state)
	state = Onboarding.SanitizeState(state, Onboarding.CompleteState())
	tutorialActive = Onboarding.IsActive(state.Stage)
	tutorialStage = state.Stage
end

local function isExpandFarmGridTarget(target)
	local gridPart = PlotGrid.GridPartFromInstance(target)
	if not gridPart then
		return false
	end
	return Onboarding.IsExpandFarmGridCoordinate(
		PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.X)),
		PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.Z))
	)
end

local function isHiddenByTutorial(kind, target)
	if not tutorialActive then
		return false
	end
	if kind == "GridPartUnlock" and tutorialStage == Onboarding.Stages.ExpandFarm then
		return not isExpandFarmGridTarget(target)
	end
	return tutorialActive and Onboarding.ShouldHidePromptKindDuringActiveTutorial(kind)
end

local function firstBasePartDescendant(instance)
	if instance:IsA("BasePart") then return instance end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then return descendant end
	end
	return nil
end

local function promptPartFor(instance, kind)
	if instance:IsA("BasePart") then return instance end
	if instance:IsA("Model") then
		return instance.PrimaryPart or (kind == "GridPartUnlock" and firstBasePartDescendant(instance) or nil)
	end
	if kind == "GridPartUnlock" then return firstBasePartDescendant(instance) end
	return nil
end

local function playerRootPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function instanceWorldCenter(instance)
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local cframe = instance:GetBoundingBox()
		return cframe.Position
	end
	local part = firstBasePartDescendant(instance)
	return part and part.Position or nil
end

local function isVisiblePromptTarget(instance)
	if instance:IsA("BasePart") then
		return instance.Transparency < 1
	end
	if instance:IsA("Model") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.Transparency < 1 then
				return true
			end
		end
	end
	return false
end

local function isRollButton(instance)
	if not (instance and instance:IsA("BasePart") and instance.Name == "Button") then
		return false
	end
	local folder = instance.Parent
	local rollArea = folder and folder.Parent
	return folder ~= nil
		and folder:IsA("Folder")
		and folder.Name == "Button"
		and rollArea ~= nil
		and rollArea:IsA("Folder")
		and rollArea.Name == "RollArea"
end

local function gridPartAt(plot, x, z)
	if not plot then return nil end
	for _, folderName in ipairs({ PlotGrid.Folders.Starter, PlotGrid.Folders.Unlockable }) do
		local folder = plot:FindFirstChild(folderName)
		if folder then
			for _, child in ipairs(folder:GetChildren()) do
				if child:IsA("BasePart")
					and PlotGrid.NormalizeInteger(child:GetAttribute(PlotGrid.Attributes.X)) == x
					and PlotGrid.NormalizeInteger(child:GetAttribute(PlotGrid.Attributes.Z)) == z then
					return child
				end
			end
		end
	end
	return nil
end

local function addVisibleFenceCandidate(candidates, fence)
	if fence and (fence:IsA("BasePart") or fence:IsA("Model")) and isVisiblePromptTarget(fence) then
		candidates[#candidates + 1] = fence
	end
end

local function visibleFencesForGridPart(gridPart)
	local candidates = {}
	if not PlotGrid.IsUnlockableGridPart(gridPart) then
		return candidates
	end

	for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
		addVisibleFenceCandidate(candidates, gridPart:FindFirstChild("Fence" .. tostring(sideNumber)))
	end

	local plot = gridPart.Parent and gridPart.Parent.Parent or nil
	local x = PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.X))
	local z = PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.Z))
	if not x or not z then
		return candidates
	end

	for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
		local side = PlotGrid.SideByNumber[sideNumber]
		local neighbor = gridPartAt(plot, x + side.dx, z + side.dz)
		local fence = neighbor and neighbor:FindFirstChild("Fence" .. tostring(side.opposite)) or nil
		addVisibleFenceCandidate(candidates, fence)
	end

	return candidates
end

local function nearestVisibleFenceForGridPart(gridPart)
	local candidates = visibleFencesForGridPart(gridPart)
	if #candidates == 0 then return nil end

	local rootPosition = playerRootPosition()
	if not rootPosition then
		return candidates[1]
	end

	local bestFence = candidates[1]
	local bestDistance = math.huge
	for _, fence in ipairs(candidates) do
		local center = instanceWorldCenter(fence)
		local distance = center and (center - rootPosition).Magnitude or math.huge
		if distance < bestDistance then
			bestFence = fence
			bestDistance = distance
		end
	end
	return bestFence
end

local function promptAnchorInstance(instance, kind)
	if kind == "GridPartUnlock" and PlotGrid.IsUnlockableGridPart(instance) then
		return nearestVisibleFenceForGridPart(instance) or instance
	end
	return instance
end

local function promptAttachmentName(instance, kind)
	if kind == "GridPartUnlock" and PlotGrid.IsUnlockableGridPart(instance) then
		local x = PlotGrid.NormalizeInteger(instance:GetAttribute(PlotGrid.Attributes.X)) or 0
		local z = PlotGrid.NormalizeInteger(instance:GetAttribute(PlotGrid.Attributes.Z)) or 0
		return PROMPT_ATTACHMENT_PREFIX .. kind .. "_" .. PlotGrid.CoordKey(x, z)
	end
	return PROMPT_ATTACHMENT_PREFIX .. kind
end

local function promptAnchorWorldPosition(instance, kind)
	if kind == "CrateRoll" and instance:IsA("BasePart") then
		return instance.Position + Vector3.new(0, CRATE_ROLL_PROMPT_Y_OFFSET, 0)
	end
	local anchor = promptAnchorInstance(instance, kind)
	return anchor and instanceWorldCenter(anchor) or nil
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

local function autoModeForKind(kind)
	if kind == "PetFeed" then
		return LocalPrompts.AutoModes.Feed
	end
	if kind == "PatchHarvest" or kind == "TreeGroundPickup" then
		return LocalPrompts.AutoModes.Collect
	end
	return nil
end

local function promptParentFor(instance, kind)
	local anchor = promptAnchorInstance(instance, kind)
	local part = anchor and promptPartFor(anchor, kind) or nil
	if not part then return nil end

	local attachmentName = promptAttachmentName(instance, kind)
	local attachment = part:FindFirstChild(attachmentName)
	if attachment then
		if attachment:IsA("Attachment") then
			local worldPosition = promptAnchorWorldPosition(instance, kind)
			if worldPosition then
				attachment.WorldPosition = worldPosition
			end
			return attachment
		end
		return part
	end

	attachment = Instance.new("Attachment")
	attachment.Name = attachmentName
	attachment.Parent = part
	local worldPosition = promptAnchorWorldPosition(instance, kind)
	if worldPosition then
		attachment.WorldPosition = worldPosition
	end
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

local function isGrowingSeedFeed(instance)
	return instance ~= nil and instance:GetAttribute(State.Seed.Phase) == "GrowingSeed"
end

local function owningGridPart(instance)
	return PlotGrid.GridPartFromInstance(instance)
end

local function gridUnlockContext(target)
	local gridPart = owningGridPart(target)
	if not gridPart or gridPart:GetAttribute(State.Grid.Purchasable) ~= true then
		return false
	end
	if not nearestVisibleFenceForGridPart(gridPart) then
		return false
	end
	return true
end

local function feedMachineClass(machine)
	local feedClass = machine:GetAttribute(State.Feed.Class)
	if type(feedClass) == "string" and feedClass ~= "" then
		return feedClass
	end
	return nil
end

local function isPromptedFeedMachine(machine)
	local feedClass = feedMachineClass(machine)
	return feedClass == "Processor" or feedClass == "JamBarrel"
end

local function feedMachineActionText(machine, defaultDepositText, defaultTakeText)
	if feedMachineClass(machine) == "JamBarrel" then
		return "Make", "Collect"
	end
	return defaultDepositText, defaultTakeText
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

local function processorContext(machine)
	local depositText, takeText = feedMachineActionText(machine, "Feed", "Collect")
	if isEditMode() then return false, takeText end
	local accepted = acceptedFoodType(machine)
	local maxQueue = machine:GetAttribute(State.Feed.MaxQueue) or 5
	local queueCount = machine:GetAttribute(State.Feed.QueueCount) or 0
	local readyCount = machine:GetAttribute(State.Feed.ReadyCount) or 0
	local equippedFood = Food.GetEquipped(player, nil)
	local foodMatches = equippedFood ~= nil and (accepted == nil or Food.TypeOf(equippedFood) == accepted)
	local canDeposit = foodMatches and queueCount < maxQueue
	if canDeposit then return true, depositText end
	if equippedFood ~= nil and not foodMatches then return true, depositText end
	if readyCount > 0 then return true, takeText end
	return true, depositText
end

local function promptActivationDistance(kind)
	if kind == "PetFeed" then return PET_FEED_PROMPT_DISTANCE end
	if kind == "TreeGroundPickup" then return FOOD_PICKUP_PROMPT_DISTANCE end
	if kind == "GridPartUnlock" then return GRID_UNLOCK_PROMPT_DISTANCE end
	if kind == "CrateRoll" then return CRATE_ROLL_PROMPT_DISTANCE end
	return DEFAULT_PROMPT_DISTANCE
end

local function configurePrompt(prompt, kind)
	prompt.Name = "__LocalPrompt_" .. kind
	prompt.HoldDuration = 0
	prompt.ObjectText = ""
	prompt.MaxActivationDistance = promptActivationDistance(kind)
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Style = Enum.ProximityPromptStyle.Custom
	if prompt:GetAttribute("Theme") == nil then
		prompt:SetAttribute("Theme", kind)
	end
	if kind == "GridPartUnlock" then
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0.25
	else
		prompt.KeyboardKeyCode = Enum.KeyCode.E
	end
end

local function promptTemplateFor(kind)
	local uiFolder = ReplicatedStorage:FindFirstChild("UI")
	local promptTemplates = uiFolder and uiFolder:FindFirstChild(PROMPT_TEMPLATE_FOLDER_NAME)
	local specificTemplate = promptTemplates and promptTemplates:FindFirstChild(kind)
	if specificTemplate then
		if specificTemplate:IsA("ProximityPrompt") then
			return specificTemplate
		end
		if not warnedInvalidPromptTemplates[kind] then
			warn(string.format("[LocalPrompts] %s is %s, expected ProximityPrompt", specificTemplate:GetFullName(), specificTemplate.ClassName))
			warnedInvalidPromptTemplates[kind] = true
		end
	end

	local defaultTemplate = uiFolder and uiFolder:FindFirstChild(DEFAULT_PROMPT_TEMPLATE_NAME)
	if defaultTemplate and defaultTemplate:IsA("ProximityPrompt") then
		return defaultTemplate
	end
	if not warnedMissingPromptTemplates[kind] then
		warn(string.format(
			"[LocalPrompts] Missing ReplicatedStorage.UI.%s.%s or ReplicatedStorage.UI.%s ProximityPrompt",
			PROMPT_TEMPLATE_FOLDER_NAME,
			kind,
			DEFAULT_PROMPT_TEMPLATE_NAME
		))
		warnedMissingPromptTemplates[kind] = true
	end
	return nil
end

local function clonePrompt(kind)
	local template = promptTemplateFor(kind)
	return template and template:Clone() or nil
end

local scanPlot
local refreshPrompt
local refreshAll

function LocalPrompts.RegisterExternalPrompt(prompt, isAvailable, options)
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		return function() end
	end
	prompt.Enabled = false
	prompt.ObjectText = ""
	prompt.Style = Enum.ProximityPromptStyle.Custom
	options = type(options) == "table" and options or {}
	externalPrompts[prompt] = {
		isAvailable = type(isAvailable) == "function" and isAvailable or function()
			return true
		end,
		allowWhileShovelEquipped = options.allowWhileShovelEquipped == true,
	}
	local destroyingConnection
	destroyingConnection = RuntimeGuard.Connect(prompt.Destroying, "LocalPrompts.ExternalPromptDestroying", function()
		externalPrompts[prompt] = nil
		if destroyingConnection then
			destroyingConnection:Disconnect()
			destroyingConnection = nil
		end
	end)
	return function()
		externalPrompts[prompt] = nil
		if destroyingConnection then
			destroyingConnection:Disconnect()
			destroyingConnection = nil
		end
	end
end

function LocalPrompts.FindAutoPromptCandidate(mode, lockedTarget)
	if mode ~= nil and mode ~= LocalPrompts.AutoModes.Feed and mode ~= LocalPrompts.AutoModes.Collect then
		return nil
	end
	if lockedTarget ~= nil and typeof(lockedTarget) ~= "Instance" then
		return nil
	end
	if isShovelEquipped() then
		return nil
	end

	local rootPosition = playerRootPosition()
	if not rootPosition then
		return nil
	end

	local closest = nil
	local closestDistance = math.huge
	for target, bucket in pairs(byTarget) do
		if lockedTarget ~= nil and target ~= lockedTarget then
			continue
		end
		for kind, prompt in pairs(bucket) do
			local action = AUTO_PROMPT_ACTIONS[kind]
			local candidateMode = autoModeForKind(kind)
			if not action or not candidateMode or (mode ~= nil and candidateMode ~= mode) then
				continue
			end

			refreshPrompt(target, kind, prompt)
			if prompt.Parent == nil or target.Parent == nil or not prompt.Enabled then
				continue
			end

			local distance = promptDistance(prompt, rootPosition)
			if distance and distance <= prompt.MaxActivationDistance and distance < closestDistance then
				closest = {
					mode = candidateMode,
					kind = kind,
					action = action,
					target = target,
					distance = distance,
				}
				closestDistance = distance
			end
		end
	end

	refreshAll(false)
	return closest
end

function LocalPrompts.TriggerAutoPrompt(candidate)
	if type(candidate) ~= "table" then
		return false
	end
	local action = candidate.action
	local target = candidate.target
	local kind = candidate.kind
	if AUTO_PROMPT_ACTIONS[kind] ~= action then
		return false
	end
	if typeof(target) ~= "Instance" or target.Parent == nil then
		return false
	end
	PromptInteract:FireServer(action, target)
	return true
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
		if parent and isLocalPromptAttachment(parent) then
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
		if promptPartFor(target, kind) then
			clearPending()
			addPrompt(target, kind, action)
		end
	end

	connections[#connections + 1] = RuntimeGuard.Connect(target:GetPropertyChangedSignal("PrimaryPart"), "LocalPrompts.RetryPrimaryPart", retry)
	connections[#connections + 1] = RuntimeGuard.Connect(target.AncestryChanged, "LocalPrompts.RetryAncestryChanged", retry)
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

	local prompt = clonePrompt(kind)
	if not prompt then return end
	configurePrompt(prompt, kind)
	prompt.Parent = parent
	RuntimeGuard.Connect(prompt.Triggered, "LocalPrompts.PromptTriggered." .. tostring(kind), function()
		if kind == "PetFeed" and target:GetAttribute(State.Pet.EvolutionPaused) == true then
			return
		end
		if kind == "TreeGroundPickup" then
			prompt.Enabled = false
		end
		PromptInteract:FireServer(action, target)
	end)
	RuntimeGuard.Connect(target.AncestryChanged, "LocalPrompts.TargetAncestryChanged." .. tostring(kind), function()
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
		if isPromptedFeedMachine(instance) then
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

	if instance:IsA("BasePart") and PlotGrid.IsUnlockableGridPart(instance) then
		addPrompt(instance, "GridPartUnlock", Interactions.Actions.GridPartUnlock)
	end

	if isRollButton(instance) then
		addPrompt(instance, "CrateRoll", Interactions.Actions.CrateRoll)
	end

end

scanPlot = function()
	local plot = getPlot()
	if not plot then return end
	for _, descendant in ipairs(plot:GetDescendants()) do
		tryBind(descendant)
	end
end

refreshPrompt = function(target, kind, prompt)
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
	if isHiddenByTutorial(kind, target) then
		prompt.Enabled = false
		return
	end
	prompt.ObjectText = ""

	if kind == "PetFeed" then
		prompt.ActionText = "Feed"
		prompt.Enabled = target:GetAttribute(State.Pet.EvolutionPaused) ~= true
			and not isEditMode()
			and hasFeedablePetFood()
			and petCanGainXP(target)
	elseif kind == "FeedMachine" then
		local enabled, actionText = processorContext(target)
		prompt.ActionText = actionText
		prompt.Enabled = enabled
	elseif kind == "PatchHarvest" then
		prompt.ActionText = "Collect"
		prompt.Enabled = not isEditMode()
			and not isGrowingSeedFeed(target.Parent)
			and hasSlotFood(target)
	elseif kind == "TreeGroundPickup" then
		if not isTreeGroundPickupTarget(target) then
			removePrompt(target, kind)
			return
		end
		prompt.ActionText = "Collect"
		prompt.Enabled = not isEditMode()
	elseif kind == "GridPartUnlock" then
		local parent = promptParentFor(target, kind)
		if not parent then
			prompt.Enabled = false
			return
		end
		if prompt.Parent ~= parent then
			local previousParent = prompt.Parent
			prompt.Parent = parent
			if previousParent and isLocalPromptAttachment(previousParent) then
				previousParent:Destroy()
			end
		end
		local canUnlock = gridUnlockContext(target)
		prompt.ActionText = "Buy"
		prompt.Enabled = not isEditMode() and canUnlock
	elseif kind == "CrateRoll" then
		if not isRollButton(target) then
			removePrompt(target, kind)
			return
		end
		prompt.ActionText = "Roll"
		prompt.Enabled = not isEditMode() and target:GetAttribute(ROLL_BUTTON_UNAVAILABLE_ATTR) ~= true
	end
end

refreshAll = function(shouldScan)
	if shouldScan then scanPlot() end

	local rootPosition = playerRootPosition()
	local shovelEquipped = isShovelEquipped()
	local closestPrompt = nil
	local closestDistance = math.huge

	for target, bucket in pairs(byTarget) do
		for kind, prompt in pairs(bucket) do
			if shovelEquipped then
				prompt.Enabled = false
				continue
			end
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

	for prompt, record in pairs(externalPrompts) do
		if prompt.Parent == nil then
			externalPrompts[prompt] = nil
			continue
		end

		if shovelEquipped and not record.allowWhileShovelEquipped then
			prompt.Enabled = false
			continue
		end

		prompt.Enabled = record.isAvailable(prompt) == true
		if prompt.Enabled then
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

	for _, bucket in pairs(byTarget) do
		for _, prompt in pairs(bucket) do
			if prompt.Parent ~= nil and prompt.Enabled and prompt ~= closestPrompt then
				prompt.Enabled = false
			end
		end
	end

	for prompt in pairs(externalPrompts) do
		if prompt.Parent ~= nil and prompt.Enabled and prompt ~= closestPrompt then
			prompt.Enabled = false
		end
	end
end

function LocalPrompts.start()
	pcall(function()
		ProximityPromptService.MaxPromptsVisible = 1
	end)

	RuntimeGuard.Connect(Workspace.DescendantAdded, "LocalPrompts.DescendantAdded", function(instance)
		task.defer(function()
			RuntimeGuard.Run("LocalPrompts.TryBindDeferred", tryBind, instance)
		end)
	end)

	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "LocalPrompts.AssignedPlotChanged", function()
		refreshAll(true)
	end)
	RuntimeGuard.Connect(player:GetPropertyChangedSignal("RespawnLocation"), "LocalPrompts.RespawnLocationChanged", function()
		refreshAll(true)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal("EditMode"), "LocalPrompts.EditModeChanged", function()
		refreshAll(false)
	end)
	applyTutorialState(PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding))
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, function(state)
		local wasTutorialActive = tutorialActive
		local previousTutorialStage = tutorialStage
		applyTutorialState(state)
		if tutorialActive ~= wasTutorialActive or tutorialStage ~= previousTutorialStage then
			refreshAll(false)
		end
	end)
	local function watchCharacter(character)
		if not character then return end
		RuntimeGuard.Connect(character.ChildAdded, "LocalPrompts.CharacterChildAdded", function(child)
			if child:IsA("Tool") then refreshAll(false) end
		end)
		RuntimeGuard.Connect(character.ChildRemoved, "LocalPrompts.CharacterChildRemoved", function(child)
			if child:IsA("Tool") then refreshAll(false) end
		end)
		refreshAll(true)
	end
	RuntimeGuard.Connect(player.CharacterAdded, "LocalPrompts.CharacterAdded", watchCharacter)
	RuntimeGuard.Run("LocalPrompts.InitialCharacter", watchCharacter, player.Character)
	RuntimeGuard.Connect(backpack.ChildAdded, "LocalPrompts.BackpackChildAdded", function()
		refreshAll(false)
	end)
	RuntimeGuard.Connect(backpack.ChildRemoved, "LocalPrompts.BackpackChildRemoved", function()
		refreshAll(false)
	end)

	task.defer(function()
		RuntimeGuard.Run("LocalPrompts.InitialRefresh", refreshAll, true)
	end)

	local accumulator = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "LocalPrompts.Heartbeat", function(dt)
		accumulator += dt
		if accumulator >= 0.1 then
			accumulator = 0
			RuntimeGuard.Run("LocalPrompts.RefreshHeartbeat", refreshAll, false)
		end
	end)
end

return LocalPrompts
