local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local GearShopBalance = require(Shared:WaitForChild("GearShopBalance"))
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
local TREE_DELETE_PROMPT_HEIGHT_ABOVE_PRIMARY_BOTTOM = 3
local PROMPT_UPDATE_INTERVAL = 0.1

local DELETE_FAILURE_MESSAGES = {
	["busy"] = "Please wait before deleting another item",
	["invalid-target"] = "You can only delete feed machines and cosmetics with the shovel",
	["no-plot"] = "You need a claimed plot to delete items",
	["no-shovel"] = "Equip the shovel before deleting items",
	["rate-limited"] = "Please wait before deleting again",
	["save-failed"] = "Could not save that deletion. Please try again",
	["too-far"] = "Move closer to delete that item",
	["tutorial-locked"] = "You can't delete this during the tutorial!",
}

local function deleteFailureMessage(reason)
	return DELETE_FAILURE_MESSAGES[reason] or "Could not delete that item"
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

	local feedType = target:GetAttribute(State.Feed.Type)
	local template = feedTemplate(feedType)
	rarity = template and template:GetAttribute(State.Feed.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end

	rarity = Seeds.RarityForFeedType(feedType)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end

	local shopItem = GearShopBalance.Get(feedType)
	rarity = shopItem and shopItem.Rarity
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

local function targetPromptWorldPosition(target)
	if target:IsA("BasePart") then
		return target.Position
	end
	if target:IsA("Model") then
		local primary = target.PrimaryPart
		if target:GetAttribute(State.Feed.Class) == "Tree" and primary then
			local primaryBottom = (primary.CFrame * CFrame.new(0, -primary.Size.Y / 2, 0)).Position
			return primaryBottom + Vector3.new(0, TREE_DELETE_PROMPT_HEIGHT_ABOVE_PRIMARY_BOTTOM, 0)
		end
		local cframe = target:GetBoundingBox()
		return cframe.Position
	end
	local part = firstBasePartDescendant(target)
	return part and part.Position or nil
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
	local deleteTargets = {}
	local deleteTargetParts = setmetatable({}, { __mode = "k" })
	local deleteTargetConnections = {}
	local plotDescendantConnection = nil

	-- One prompt follows the nearest deletable item instead of one prompt per
	-- item: LocalPrompts only ever shows the single closest prompt, so a
	-- per-item fleet is pure instance/refresh overhead.
	local roamingPrompt = nil -- { prompt, attachment, triggeredConnection, unregisterExternalPrompt }
	local currentTarget = nil

	local updateRoamingPrompt

	local function isEquipped()
		return equippedTool ~= nil and equippedTool.Parent == player.Character
	end

	local function isOfflineProgressPending()
		return player:GetAttribute(State.Player.OfflineProgressPending) == true
	end

	local function playerRootPosition()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return root and root:IsA("BasePart") and root.Position or nil
	end

	local function destroyRoamingPrompt()
		currentTarget = nil
		local record = roamingPrompt
		if not record then
			return
		end
		roamingPrompt = nil
		if record.triggeredConnection then
			record.triggeredConnection:Disconnect()
		end
		if record.unregisterExternalPrompt then
			record.unregisterExternalPrompt()
		end
		-- Hide before destroying so a shown prompt fires PromptHidden for the
		-- customizer instead of relying solely on its Destroying fallback.
		record.prompt.Enabled = false
		record.prompt:Destroy()
		if record.attachment.Parent then
			record.attachment:Destroy()
		end
	end

	local function cancelPrompt()
		promptToken += 1
		promptOpen = false
		YesNoWarning.Cancel("cancelled")
		if updateRoamingPrompt then
			updateRoamingPrompt()
		end
	end

	local function isDeletePromptAvailable()
		if promptOpen or pendingRequestId ~= nil or not isEquipped() or isOfflineProgressPending() then
			return false
		end
		local target = currentTarget
		if not target or not target.Parent then
			return false
		end
		local plot = PlotResolver.ResolveForPlayer(player)
		return plot ~= nil
			and target:IsDescendantOf(plot)
			and (isFeedPlacement(target) or isCosmeticPlacement(target))
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
		updateRoamingPrompt()
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
		updateRoamingPrompt()

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
			else
				updateRoamingPrompt()
			end
		end)

		if not opened then
			promptOpen = false
			updateRoamingPrompt()
		end
	end

	local function positionPartFor(target)
		local cached = deleteTargetParts[target]
		if cached and cached.Parent and (cached == target or cached:IsDescendantOf(target)) then
			return cached
		end
		local part = target:IsA("BasePart") and target
			or (target:IsA("Model") and target.PrimaryPart)
			or firstBasePartDescendant(target)
		deleteTargetParts[target] = part
		return part
	end

	local function nearestDeleteTarget(rootPosition)
		local best = nil
		local bestPart = nil
		local bestDistanceSq = DELETE_PROMPT_DISTANCE * DELETE_PROMPT_DISTANCE
		for target in pairs(deleteTargets) do
			local part = target.Parent and positionPartFor(target) or nil
			if part then
				local offset = part.Position - rootPosition
				local distanceSq = offset:Dot(offset)
				if distanceSq <= bestDistanceSq then
					best = target
					bestPart = part
					bestDistanceSq = distanceSq
				end
			end
		end
		return best, bestPart
	end

	local function attachRoamingPrompt(target, part)
		local record = roamingPrompt
		if not record then
			local attachment = Instance.new("Attachment")
			attachment.Name = DELETE_PROMPT_ATTACHMENT_NAME

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
			prompt.Parent = attachment

			record = {
				prompt = prompt,
				attachment = attachment,
			}
			record.unregisterExternalPrompt = LocalPrompts.RegisterExternalPrompt(prompt, isDeletePromptAvailable, {
				allowWhileShovelEquipped = true,
			})
			record.triggeredConnection = RuntimeGuard.Connect(prompt.Triggered, "ShovelController.DeletePromptTriggered", function()
				local triggeredTarget = currentTarget
				if isEquipped() and triggeredTarget and triggeredTarget.Parent then
					promptDelete(triggeredTarget)
				end
			end)
			roamingPrompt = record
		end

		if record.attachment.Parent ~= part then
			record.attachment.Parent = part
		end
		if target ~= currentTarget then
			currentTarget = target
			record.attachment.WorldPosition = targetPromptWorldPosition(target) or part.Position
		end
	end

	updateRoamingPrompt = function()
		if isOfflineProgressPending() or not isEquipped() then
			destroyRoamingPrompt()
			return
		end
		if promptOpen or pendingRequestId ~= nil then
			-- Keep the current target locked while a confirm dialog or delete
			-- request is in flight; just make sure the prompt is hidden.
			if roamingPrompt then
				roamingPrompt.prompt.Enabled = false
			end
			return
		end
		if roamingPrompt and (roamingPrompt.prompt.Parent == nil or roamingPrompt.attachment.Parent == nil) then
			-- The part the prompt was riding on got destroyed; rebuild below.
			destroyRoamingPrompt()
		end

		local rootPosition = playerRootPosition()
		local target, part
		if rootPosition then
			target, part = nearestDeleteTarget(rootPosition)
		end
		if not target or not part then
			currentTarget = nil
			if roamingPrompt then
				roamingPrompt.prompt.Enabled = false
			end
			return
		end
		attachRoamingPrompt(target, part)
	end

	local function unregisterDeleteTarget(target)
		local connection = deleteTargetConnections[target]
		if connection then
			connection:Disconnect()
			deleteTargetConnections[target] = nil
		end
		deleteTargets[target] = nil
		deleteTargetParts[target] = nil
		if currentTarget == target then
			currentTarget = nil
			if roamingPrompt then
				roamingPrompt.prompt.Enabled = false
			end
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
			-- Attributes are often applied right after parenting; retry once
			-- next step. The roaming-prompt heartbeat picks new targets up on
			-- its own, so no prompt refresh is needed here.
			task.defer(function()
				RuntimeGuard.Run("ShovelController.TryBindDeferred", tryIndexDeleteTarget, instance, plot)
			end)
		end)
	end

	local function bindTool(tool)
		if not Shovel.IsTool(tool) or boundTools[tool] then
			return
		end
		boundTools[tool] = true

		local function activateTool()
			equippedTool = tool
			updateRoamingPrompt()
		end

		RuntimeGuard.Connect(tool.Equipped, "ShovelController.ToolEquipped", activateTool)
		if tool.Parent == player.Character then
			activateTool()
		end
		RuntimeGuard.Connect(tool.Unequipped, "ShovelController.ToolUnequipped", function()
			if equippedTool == tool then
				equippedTool = nil
				cancelPrompt()
				destroyRoamingPrompt()
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
			updateRoamingPrompt()
			return
		end
		updateRoamingPrompt()
		NotificationUi.show({
			kind = NotificationConfig.Kinds.Error,
			text = deleteFailureMessage(reason),
		})
	end)

	RuntimeGuard.Connect(player.Backpack.ChildAdded, "ShovelController.BackpackChildAdded", bindTool)
	RuntimeGuard.Connect(player.CharacterAdded, "ShovelController.CharacterAdded", function(character)
		equippedTool = nil
		cancelPrompt()
		destroyRoamingPrompt()
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
		destroyRoamingPrompt()
		updateRoamingPrompt()
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.OfflineProgressPending), "ShovelController.OfflineProgressPendingChanged", function()
		cancelPrompt()
	end)

	local accumulator = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "ShovelController.Heartbeat", function(dt)
		accumulator += dt
		if accumulator < PROMPT_UPDATE_INTERVAL then
			return
		end
		accumulator = 0
		if not isEquipped() then
			return
		end
		RuntimeGuard.Run("ShovelController.RoamingPromptHeartbeat", updateRoamingPrompt)
	end)

	rebuildDeleteTargetIndex()
	bindPlotIndexWatcher()
	RuntimeGuard.Run("ShovelController.ScanToolsInitial", scanTools)
end

return ShovelController
