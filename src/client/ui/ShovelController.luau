local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local Shovel = require(Shared:WaitForChild("Shovel"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local NotificationUi = require(script.Parent:WaitForChild("Notifications"))
local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local YesNoWarning = require(script.Parent:WaitForChild("YesNoWarning"))

local ShovelController = {}

local DELETE_PROMPT_ATTACHMENT_NAME = "__ShovelDeletePromptAttachment"
local DELETE_PROMPT_DISTANCE = 18

local DELETE_FAILURE_MESSAGES = {
	["busy"] = "Please wait before deleting another item.",
	["invalid-target"] = "You can only delete feed machines and cosmetics with the shovel.",
	["no-plot"] = "You need a claimed plot to delete items.",
	["no-shovel"] = "Equip the shovel before deleting items.",
	["rate-limited"] = "Please wait before deleting again.",
	["save-failed"] = "Could not save that deletion. Please try again.",
	["too-far"] = "Move closer to delete that item.",
}

local function deleteFailureMessage(reason)
	return DELETE_FAILURE_MESSAGES[reason] or "Could not delete that item."
end

local function feedTemplate(feedType)
	if type(feedType) ~= "string" or feedType == "" then
		return nil
	end

	local root = Assets.Find(Assets.Names.FeedMachines)
	if not root then
		return nil
	end
	for _, classFolder in ipairs(root:GetChildren()) do
		if classFolder:IsA("Folder") then
			for _, template in ipairs(classFolder:GetChildren()) do
				if (template:IsA("BasePart") or template:IsA("Model"))
					and template:GetAttribute(State.Feed.Type) == feedType then
					return template
				end
			end
		end
	end
	return nil
end

local function isFeedPlacement(instance)
	if not instance then
		return false
	end
	local feedType = instance and instance:GetAttribute(State.Feed.Type)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(feedType) == "string"
		and feedType ~= ""
		and instance:GetAttribute(State.Feed.Index) ~= nil
end

local function isCosmeticPlacement(instance)
	if not instance then
		return false
	end
	local cosmeticId = instance and instance:GetAttribute(State.Cosmetic.Id)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(cosmeticId) == "string"
		and cosmeticId ~= ""
		and instance:GetAttribute(State.Cosmetic.Index) ~= nil
end

local function deleteTargetRootFromInstance(plot, instance)
	local current = instance
	while current and current ~= plot do
		if isFeedPlacement(current) or isCosmeticPlacement(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function rarityForTarget(target)
	if not target then
		return nil
	end

	local cosmeticId = target:GetAttribute(State.Cosmetic.Id)
	if type(cosmeticId) == "string" and cosmeticId ~= "" then
		local rarity = target:GetAttribute(State.Cosmetic.Rarity)
		if type(rarity) == "string" and rarity ~= "" then
			return rarity
		end
		return Cosmetics.RarityFor(cosmeticId)
	end

	local seedId = target:GetAttribute(State.Seed.Id)
	if type(seedId) == "string" and seedId ~= "" then
		return Seeds.RarityFor(seedId)
	end

	local rarity = target:GetAttribute(State.Feed.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end

	local template = feedTemplate(target:GetAttribute(State.Feed.Type))
	rarity = template and template:GetAttribute(State.Feed.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end
	return nil
end

local function displayNameForTarget(target)
	if not target then
		return "Item"
	end
	local cosmeticId = target:GetAttribute(State.Cosmetic.Id)
	if type(cosmeticId) == "string" and cosmeticId ~= "" then
		return Cosmetics.DisplayNameFor(cosmeticId) or target.Name
	end
	return target.Name
end

local function questionItemText(name)
	name = tostring(name or "Item")
	if name:sub(-1) == "?" then
		return name
	end
	return name .. "?"
end

local function firstBasePartDescendant(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

local function targetWorldCenter(target)
	if target:IsA("BasePart") then
		return target.Position
	end
	if target:IsA("Model") then
		local cframe = target:GetBoundingBox()
		return cframe.Position
	end
	local part = firstBasePartDescendant(target)
	return part and part.Position or nil
end

local function promptParentForTarget(target)
	local part = target:IsA("BasePart") and target or target.PrimaryPart or firstBasePartDescendant(target)
	if not part then
		return nil
	end
	local attachment = part:FindFirstChild(DELETE_PROMPT_ATTACHMENT_NAME)
	if attachment and not attachment:IsA("Attachment") then
		return part
	end
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = DELETE_PROMPT_ATTACHMENT_NAME
		attachment.Parent = part
	end
	local position = targetWorldCenter(target)
	if position then
		attachment.WorldPosition = position
	end
	return attachment
end

function ShovelController.start()
	local player = Players.LocalPlayer
	local ShovelDeleteRequest = Remotes.get(Remotes.Names.ShovelDeleteRequest)
	local ShovelDeleteResult = Remotes.get(Remotes.Names.ShovelDeleteResult)

	local equippedTool = nil
	local promptOpen = false
	local promptToken = 0
	local nextRequestId = 0
	local pendingRequestId = nil
	local pendingTarget = nil
	local boundTools = setmetatable({}, { __mode = "k" })
	local deletePrompts = {}
	local deleteTargets = {}
	local deleteTargetConnections = {}
	local plotDescendantConnection = nil

	local refreshDeletePrompts
	local clearDeletePrompts
	local unregisterDeleteTarget

	local function isEquipped()
		return equippedTool ~= nil and equippedTool.Parent == player.Character
	end

	local function isOfflineProgressPending()
		return player:GetAttribute(State.Player.OfflineProgressPending) == true
	end

	local function cancelPrompt()
		promptToken += 1
		promptOpen = false
		YesNoWarning.Cancel("cancelled")
		if refreshDeletePrompts then
			refreshDeletePrompts(false)
		end
	end

	local function requestDelete(target)
		if pendingRequestId ~= nil or not target or not target.Parent then
			return
		end
		if isOfflineProgressPending() then
			return
		end
		local shovelGuid = ToolIdentity.GuidOf(equippedTool)
		if not ToolIdentity.IsValidGuid(shovelGuid) then
			NotificationUi.show({
				kind = NotificationConfig.Kinds.Error,
				text = deleteFailureMessage("no-shovel"),
			})
			return
		end
		nextRequestId += 1
		pendingRequestId = nextRequestId
		pendingTarget = target
		if refreshDeletePrompts then
			refreshDeletePrompts(false)
		end
		ShovelDeleteRequest:FireServer(pendingRequestId, target, shovelGuid)
	end

	local function promptDelete(target)
		if promptOpen or pendingRequestId ~= nil or not target then
			return
		end
		if isOfflineProgressPending() then
			return
		end

		promptToken += 1
		local token = promptToken
		promptOpen = true
		if refreshDeletePrompts then
			refreshDeletePrompts(false)
		end

		local opened = YesNoWarning.Prompt({
			title = "Delete Item?",
			question = "Are you sure you want to delete",
			itemText = questionItemText(displayNameForTarget(target)),
			itemRarity = rarityForTarget(target),
			yesText = "Yes",
			noText = "No",
		}, function(confirmed)
			if token ~= promptToken then
				return
			end
			promptOpen = false
			if confirmed and isEquipped() and target.Parent then
				requestDelete(target)
			elseif refreshDeletePrompts then
				refreshDeletePrompts(false)
			end
		end)

		if not opened then
			promptOpen = false
			if refreshDeletePrompts then
				refreshDeletePrompts(false)
			end
		end
	end

	local function removeDeletePrompt(target)
		local record = deletePrompts[target]
		if not record then
			return
		end
		for _, connection in ipairs(record.connections) do
			connection:Disconnect()
		end
		if record.unregisterExternalPrompt then
			record.unregisterExternalPrompt()
		end
		if record.prompt then
			record.prompt:Destroy()
		end
		if record.attachment and record.attachment.Parent then
			record.attachment:Destroy()
		end
		deletePrompts[target] = nil
	end

	unregisterDeleteTarget = function(target)
		removeDeletePrompt(target)
		local connection = deleteTargetConnections[target]
		if connection then
			connection:Disconnect()
			deleteTargetConnections[target] = nil
		end
		deleteTargets[target] = nil
	end

	clearDeletePrompts = function()
		local targets = {}
		for target in pairs(deletePrompts) do
			targets[#targets + 1] = target
		end
		for _, target in ipairs(targets) do
			removeDeletePrompt(target)
		end
	end

	local function clearDeleteTargetIndex()
		local targets = {}
		for target in pairs(deleteTargets) do
			targets[#targets + 1] = target
		end
		for _, target in ipairs(targets) do
			unregisterDeleteTarget(target)
		end
	end

	local function isDeletePromptAvailable(target)
		if promptOpen or pendingRequestId ~= nil or not isEquipped() or not target or not target.Parent then
			return false
		end
		local plot = PlotResolver.ResolveForPlayer(player)
		return plot ~= nil
			and target:IsDescendantOf(plot)
			and (isFeedPlacement(target) or isCosmeticPlacement(target))
	end

	local function addDeletePrompt(target)
		if deletePrompts[target] then
			return
		end

		local parent = promptParentForTarget(target)
		if not parent then
			return
		end

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ShovelDeletePrompt"
		prompt.ActionText = "Delete"
		prompt.ObjectText = ""
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0.25
		prompt.MaxActivationDistance = DELETE_PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
		prompt.Enabled = false
		prompt.Parent = parent

		local record = {
			prompt = prompt,
			attachment = parent:IsA("Attachment") and parent or nil,
			connections = {},
		}
		record.unregisterExternalPrompt = LocalPrompts.RegisterExternalPrompt(prompt, function()
			return isDeletePromptAvailable(target)
		end, {
			allowWhileShovelEquipped = true,
		})
		record.connections[#record.connections + 1] = RuntimeGuard.Connect(prompt.Triggered, "ShovelController.DeletePromptTriggered", function()
			if isEquipped() and target.Parent then
				promptDelete(target)
			end
		end)
		record.connections[#record.connections + 1] = RuntimeGuard.Connect(target.AncestryChanged, "ShovelController.DeleteTargetAncestryChanged", function()
			if not target:IsDescendantOf(Workspace) then
				removeDeletePrompt(target)
			end
		end)
		deletePrompts[target] = record
	end

	local function registerDeleteTarget(target, plot)
		if not target or deleteTargets[target] then
			return
		end
		if not target.Parent then
			return
		end
		plot = plot or PlotResolver.ResolveForPlayer(player)
		if not plot or not target:IsDescendantOf(plot) then
			return
		end
		if not (isFeedPlacement(target) or isCosmeticPlacement(target)) then
			return
		end

		deleteTargets[target] = true
		deleteTargetConnections[target] = RuntimeGuard.Connect(target.AncestryChanged, "ShovelController.IndexedTargetAncestryChanged", function()
			local currentPlot = PlotResolver.ResolveForPlayer(player)
			if not target.Parent or not currentPlot or not target:IsDescendantOf(currentPlot) then
				unregisterDeleteTarget(target)
			end
		end)
	end

	local function tryIndexDeleteTarget(instance, plot)
		plot = plot or PlotResolver.ResolveForPlayer(player)
		if not plot then
			return
		end
		local target = deleteTargetRootFromInstance(plot, instance)
		if target then
			registerDeleteTarget(target, plot)
		end
	end

	local function rebuildDeleteTargetIndex()
		clearDeleteTargetIndex()
		local plot = PlotResolver.ResolveForPlayer(player)
		if not plot then
			return
		end
		for _, descendant in ipairs(plot:GetDescendants()) do
			tryIndexDeleteTarget(descendant, plot)
		end
	end

	local function bindPlotIndexWatcher()
		if plotDescendantConnection then
			plotDescendantConnection:Disconnect()
			plotDescendantConnection = nil
		end
		local plot = PlotResolver.ResolveForPlayer(player)
		if not plot then
			return
		end
		plotDescendantConnection = RuntimeGuard.Connect(plot.DescendantAdded, "ShovelController.PlotDescendantAdded", function(instance)
			tryIndexDeleteTarget(instance, plot)
			if not isEquipped() then
				return
			end
			task.defer(function()
				RuntimeGuard.Run("ShovelController.TryBindDeferred", tryIndexDeleteTarget, instance, plot)
				RuntimeGuard.Run("ShovelController.RefreshPromptsDeferred", refreshDeletePrompts, false)
			end)
		end)
	end

	local function bindIndexedDeleteTargets()
		local targets = {}
		for target in pairs(deleteTargets) do
			targets[#targets + 1] = target
		end
		for _, target in ipairs(targets) do
			if not target.Parent then
				unregisterDeleteTarget(target)
			elseif isDeletePromptAvailable(target) then
				addDeletePrompt(target)
			end
		end
	end

	refreshDeletePrompts = function(shouldScan)
		local plot = PlotResolver.ResolveForPlayer(player)
		if isOfflineProgressPending() or not isEquipped() or not plot then
			clearDeletePrompts()
			return
		end

		if shouldScan then
			rebuildDeleteTargetIndex()
		end
		bindIndexedDeleteTargets()

		for target, record in pairs(deletePrompts) do
			if not target.Parent
				or not target:IsDescendantOf(plot)
				or not (isFeedPlacement(target) or isCosmeticPlacement(target)) then
				unregisterDeleteTarget(target)
				continue
			end

			record.prompt.ObjectText = ""
			if not isDeletePromptAvailable(target) then
				record.prompt.Enabled = false
			end
		end
	end

	local function bindTool(tool)
		if not Shovel.IsTool(tool) or boundTools[tool] then
			return
		end
		boundTools[tool] = true

		local function activateTool()
			equippedTool = tool
			refreshDeletePrompts(false)
		end

		RuntimeGuard.Connect(tool.Equipped, "ShovelController.ToolEquipped", activateTool)
		if tool.Parent == player.Character then
			activateTool()
		end
		RuntimeGuard.Connect(tool.Unequipped, "ShovelController.ToolUnequipped", function()
			if equippedTool == tool then
				equippedTool = nil
				cancelPrompt()
				clearDeletePrompts()
			end
		end)
	end

	local function scanTools()
		for _, item in ipairs(player.Backpack:GetChildren()) do
			bindTool(item)
		end
		if player.Character then
			for _, item in ipairs(player.Character:GetChildren()) do
				bindTool(item)
			end
		end
	end

	RuntimeGuard.Connect(ShovelDeleteResult.OnClientEvent, "ShovelController.DeleteResult", function(requestId, success, reason)
		if requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		local target = pendingTarget
		pendingTarget = nil
		if success then
			if target then
				unregisterDeleteTarget(target)
			end
			refreshDeletePrompts(false)
			return
		end
		refreshDeletePrompts(false)
		NotificationUi.show({
			kind = NotificationConfig.Kinds.Error,
			text = deleteFailureMessage(reason),
		})
	end)

	RuntimeGuard.Connect(player.Backpack.ChildAdded, "ShovelController.BackpackChildAdded", bindTool)
	RuntimeGuard.Connect(player.CharacterAdded, "ShovelController.CharacterAdded", function(character)
		equippedTool = nil
		cancelPrompt()
		clearDeletePrompts()
		RuntimeGuard.Connect(character.ChildAdded, "ShovelController.CharacterChildAdded", bindTool)
		task.defer(function()
			RuntimeGuard.Run("ShovelController.ScanToolsDeferred", scanTools)
		end)
	end)
	if player.Character then
		RuntimeGuard.Connect(player.Character.ChildAdded, "ShovelController.InitialCharacterChildAdded", bindTool)
	end
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "ShovelController.AssignedPlotChanged", function()
		rebuildDeleteTargetIndex()
		bindPlotIndexWatcher()
		if isEquipped() then
			clearDeletePrompts()
			refreshDeletePrompts(false)
		end
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.OfflineProgressPending), "ShovelController.OfflineProgressPendingChanged", function()
		cancelPrompt()
		if isOfflineProgressPending() then
			clearDeletePrompts()
		elseif isEquipped() then
			refreshDeletePrompts(false)
		end
	end)
	rebuildDeleteTargetIndex()
	bindPlotIndexWatcher()
	RuntimeGuard.Run("ShovelController.ScanToolsInitial", scanTools)
end

return ShovelController
