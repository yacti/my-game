local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local Shovel = require(Shared:WaitForChild("Shovel"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local NotificationUi = require(script.Parent:WaitForChild("Notifications"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local YesNoWarning = require(script.Parent:WaitForChild("YesNoWarning"))

local ShovelController = {}

local DELETE_FAILURE_MESSAGES = {
	["busy"] = "Please wait before deleting another plant.",
	["invalid-target"] = "You can only delete plants with the shovel.",
	["no-plot"] = "You need a claimed plot to delete plants.",
	["no-shovel"] = "Equip the shovel before deleting plants.",
	["rate-limited"] = "Please wait before deleting again.",
	["save-failed"] = "Could not save that deletion. Please try again.",
	["too-far"] = "Move closer to delete that plant.",
}

local function deleteFailureMessage(reason)
	return DELETE_FAILURE_MESSAGES[reason] or "Could not delete that plant."
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

local function feedClassFor(feed)
	local feedClass = feed and feed:GetAttribute(State.Feed.Class)
	if type(feedClass) == "string" and feedClass ~= "" then
		return feedClass
	end
	local template = feedTemplate(feed and feed:GetAttribute(State.Feed.Type))
	return template and template:GetAttribute(State.Feed.Class) or nil
end

local function isPlant(feed)
	if not feed then
		return false
	end
	if feed:GetAttribute(State.Seed.Phase) == "GrowingSeed" then
		return true
	end
	local feedClass = feedClassFor(feed)
	return feedClass == "Patch" or feedClass == "Tree"
end

local function plantRootFromInstance(plot, instance)
	local current = instance
	while current and current ~= plot do
		if (current:IsA("BasePart") or current:IsA("Model"))
			and type(current:GetAttribute(State.Feed.Type)) == "string"
			and current:GetAttribute(State.Feed.Type) ~= ""
			and current:GetAttribute(State.Feed.Index) ~= nil
			and isPlant(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function rarityForFeed(feed)
	if not feed then
		return nil
	end

	local seedId = feed:GetAttribute(State.Seed.Id)
	if type(seedId) == "string" and seedId ~= "" then
		return Seeds.RarityFor(seedId)
	end

	local rarity = feed:GetAttribute(State.Feed.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end

	local template = feedTemplate(feed:GetAttribute(State.Feed.Type))
	rarity = template and template:GetAttribute(State.Feed.Rarity)
	if type(rarity) == "string" and rarity ~= "" then
		return rarity
	end
	return nil
end

local function questionItemText(name)
	name = tostring(name or "Item")
	if name:sub(-1) == "?" then
		return name
	end
	return name .. "?"
end

local function raycastPlant(plot, screenPosition)
	local camera = Workspace.CurrentCamera
	if not plot or not camera then
		return nil
	end

	local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { plot }

	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	return hit and plantRootFromInstance(plot, hit.Instance) or nil
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
	local boundTools = setmetatable({}, { __mode = "k" })

	local function isEquipped()
		return equippedTool ~= nil and equippedTool.Parent == player.Character
	end

	local function cancelPrompt()
		promptToken += 1
		promptOpen = false
		YesNoWarning.Cancel("cancelled")
	end

	local function requestDelete(feed)
		if pendingRequestId ~= nil or not feed or not feed.Parent then
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
		ShovelDeleteRequest:FireServer(pendingRequestId, feed, shovelGuid)
	end

	local function promptDelete(feed)
		if promptOpen or pendingRequestId ~= nil or not feed then
			return
		end

		promptToken += 1
		local token = promptToken
		promptOpen = true

		local opened = YesNoWarning.Prompt({
			title = "Delete Plant?",
			question = "Are you sure you want to delete",
			itemText = questionItemText(feed.Name),
			itemRarity = rarityForFeed(feed),
			yesText = "Yes",
			noText = "No",
		}, function(confirmed)
			if token ~= promptToken then
				return
			end
			promptOpen = false
			if confirmed and isEquipped() and feed.Parent then
				requestDelete(feed)
			end
		end)

		if not opened then
			promptOpen = false
		end
	end

	local function bindTool(tool)
		if not Shovel.IsTool(tool) or boundTools[tool] then
			return
		end
		boundTools[tool] = true

		local function activateTool()
			equippedTool = tool
		end

		RuntimeGuard.Connect(tool.Equipped, "ShovelController.ToolEquipped", activateTool)
		if tool.Parent == player.Character then
			activateTool()
		end
		RuntimeGuard.Connect(tool.Unequipped, "ShovelController.ToolUnequipped", function()
			if equippedTool == tool then
				equippedTool = nil
				cancelPrompt()
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

	RuntimeGuard.Connect(UserInputService.InputBegan, "ShovelController.InputBegan", function(input, gameProcessed)
		if gameProcessed or promptOpen or pendingRequestId ~= nil or not isEquipped() then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local plot = PlotResolver.ResolveForPlayer(player)
		local plant = raycastPlant(plot, input.Position)
		if plant then
			promptDelete(plant)
		end
	end)

	RuntimeGuard.Connect(ShovelDeleteResult.OnClientEvent, "ShovelController.DeleteResult", function(requestId, success, reason)
		if requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		if success then
			return
		end
		NotificationUi.show({
			kind = NotificationConfig.Kinds.Error,
			text = deleteFailureMessage(reason),
		})
	end)

	RuntimeGuard.Connect(player.Backpack.ChildAdded, "ShovelController.BackpackChildAdded", bindTool)
	RuntimeGuard.Connect(player.CharacterAdded, "ShovelController.CharacterAdded", function(character)
		equippedTool = nil
		cancelPrompt()
		RuntimeGuard.Connect(character.ChildAdded, "ShovelController.CharacterChildAdded", bindTool)
		task.defer(function()
			RuntimeGuard.Run("ShovelController.ScanToolsDeferred", scanTools)
		end)
	end)
	if player.Character then
		RuntimeGuard.Connect(player.Character.ChildAdded, "ShovelController.InitialCharacterChildAdded", bindTool)
	end
	RuntimeGuard.Run("ShovelController.ScanToolsInitial", scanTools)
end

return ShovelController
