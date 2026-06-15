local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local TreeVisuals = require(script.Parent:WaitForChild("AppleTreeSlotVisuals"))

local FoodStealController = {}

local PROMPT_KIND = "FoodSteal"
local PROMPT_DISTANCE = 10
local PROMPT_ATTACHMENT_NAME = "__LocalPrompt_FoodStealAttachment"

local player = Players.LocalPlayer
local requestRemote = Remotes.get(Remotes.Names.FoodStealRequest)
local resultRemote = Remotes.get(Remotes.Names.FoodStealResult)
local cancelRemote = Remotes.get(Remotes.Names.FoodStealCancel)

local tracked = {}
local plotConnections = {}
local nextRequestId = 0
local pendingRequestId = nil
local pendingProductId = nil
local pendingReservationId = nil

local function plotsFolder()
	local folder = Workspace:FindFirstChild("Plots")
	return folder and folder:IsA("Folder") and folder or nil
end

local function ownPlot()
	return PlotResolver.ResolveForPlayer(player)
end

local function plotOf(instance)
	local folder = plotsFolder()
	local current = instance
	while current and current.Parent do
		if current.Parent == folder then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function isInOtherPlot(instance)
	local plot = plotOf(instance)
	local owned = ownPlot()
	return plot ~= nil and owned ~= nil and plot ~= owned
end

local function firstBasePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function patchSlotFoodTarget(anchor)
	for _, child in ipairs(anchor:GetChildren()) do
		if (child:IsA("BasePart") or child:IsA("Model")) and child:GetAttribute(State.Food.Id) ~= nil then
			return child
		end
	end
	return nil
end

local function hasPatchSlotFood(anchor)
	return patchSlotFoodTarget(anchor) ~= nil
end

local function isPatchStealTarget(instance)
	if not (instance and instance:IsA("BasePart") and instance.Name == "SlotAnchor") then
		return false
	end
	local machine = instance.Parent
	return machine ~= nil and machine:GetAttribute(State.Feed.Class) == "Patch"
end

local function promptHighlightTarget(target)
	if isPatchStealTarget(target) then
		return patchSlotFoodTarget(target)
	end
	return TreeVisuals.GroundVisualForMarker(target) or target
end

local function isTreeGroundCandidate(instance)
	if not (instance and (instance:IsA("BasePart") or instance:IsA("Model"))) then
		return false
	end
	if instance:GetAttribute(State.TreeClicker.LocalVisual) == true then
		return false
	end
	if instance.Name:match("^BaseFoodGround%d+$") == nil then
		return false
	end
	local current = instance.Parent
	while current do
		if current:GetAttribute(State.Feed.Class) == "Tree" then
			return true
		end
		current = current.Parent
	end
	return false
end

local function isTreeStealAvailable(instance)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.TreeClicker.GroundPile) == true
		and instance:GetAttribute(State.TreeClicker.LocalVisual) ~= true
		and instance:GetAttribute(State.TreeClicker.SlotIndex) ~= nil
		and instance:GetAttribute(State.Food.Id) ~= nil
end

local function isStealTarget(instance)
	return isPatchStealTarget(instance) or isTreeGroundCandidate(instance)
end

local function hasActiveReservation(target)
	if target:GetAttribute(State.Food.StealReservationId) == nil then
		return false
	end
	local expiresAt = tonumber(target:GetAttribute(State.Food.StealReservationExpiresAt))
	return expiresAt ~= nil and expiresAt > os.time()
end

local function isAvailable(target)
	if pendingRequestId ~= nil or pendingProductId ~= nil then
		return false
	end
	if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
		return false
	end
	if player:GetAttribute(State.Player.OfflineProgressPending) == true then
		return false
	end
	if not isInOtherPlot(target) then
		return false
	end
	if hasActiveReservation(target) then
		return false
	end
	if isPatchStealTarget(target) then
		return hasPatchSlotFood(target)
	end
	if isTreeGroundCandidate(target) then
		return isTreeStealAvailable(target)
	end
	return false
end

local function attachmentFor(target)
	local part = firstBasePart(target)
	if not part then
		return nil
	end
	local attachment = part:FindFirstChild(PROMPT_ATTACHMENT_NAME)
	if attachment and attachment:IsA("Attachment") then
		return attachment
	end
	attachment = Instance.new("Attachment")
	attachment.Name = PROMPT_ATTACHMENT_NAME
	attachment.Parent = part
	return attachment
end

local function cleanupTarget(target)
	local record = tracked[target]
	if not record then
		return
	end
	tracked[target] = nil
	if record.unregister then
		record.unregister()
	end
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	if record.prompt then
		record.prompt:Destroy()
	end
	if record.attachment and record.attachment.Parent then
		record.attachment:Destroy()
	end
end

local function requestSteal(target)
	if pendingRequestId ~= nil or pendingProductId ~= nil then
		return
	end
	if not isAvailable(target) then
		return
	end
	nextRequestId += 1
	pendingRequestId = nextRequestId
	requestRemote:FireServer(pendingRequestId, target)
end

local function bindTarget(target)
	if tracked[target] or not isStealTarget(target) then
		return
	end
	local attachment = attachmentFor(target)
	if not attachment then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "__LocalPrompt_" .. PROMPT_KIND
	prompt.ActionText = "Steal"
	prompt.ObjectText = ""
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt:SetAttribute("Theme", isPatchStealTarget(target) and "PatchHarvest" or "TreeGroundPickup")
	prompt.Parent = attachment

	local record = {
		prompt = prompt,
		attachment = attachment,
		connections = {},
	}
	tracked[target] = record
	record.unregister = LocalPrompts.RegisterExternalPrompt(prompt, function()
		return isAvailable(target)
	end, {
		highlightTarget = function()
			return promptHighlightTarget(target)
		end,
	})
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(prompt.Triggered, "FoodStealController.Triggered", function()
		requestSteal(target)
	end)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(target.AncestryChanged, "FoodStealController.TargetAncestry", function()
		if not target:IsDescendantOf(Workspace) then
			cleanupTarget(target)
		end
	end)
end

local function tryBind(instance)
	if isStealTarget(instance) then
		bindTarget(instance)
	end
	local parent = instance.Parent
	if parent and isPatchStealTarget(parent) then
		bindTarget(parent)
	end
end

local function clearAll()
	local targets = {}
	for target in pairs(tracked) do
		targets[#targets + 1] = target
	end
	for _, target in ipairs(targets) do
		cleanupTarget(target)
	end
	for _, connection in ipairs(plotConnections) do
		connection:Disconnect()
	end
	table.clear(plotConnections)
end

local function scanPlots()
	clearAll()
	local folder = plotsFolder()
	if not folder then
		return
	end
	for _, descendant in ipairs(folder:GetDescendants()) do
		tryBind(descendant)
	end
	plotConnections[#plotConnections + 1] = RuntimeGuard.Connect(folder.DescendantAdded, "FoodStealController.DescendantAdded", function(instance)
		task.defer(function()
			RuntimeGuard.Run("FoodStealController.TryBind", tryBind, instance)
		end)
	end)
	plotConnections[#plotConnections + 1] = RuntimeGuard.Connect(folder.AncestryChanged, "FoodStealController.PlotsAncestry", function()
		if not folder:IsDescendantOf(Workspace) then
			clearAll()
		end
	end)
end

function FoodStealController.start()
	RuntimeGuard.Connect(resultRemote.OnClientEvent, "FoodStealController.Result", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		local productId = tonumber(payload.productId) or 0
		local reservationId = payload.reservationId
		if payload.success == true and productId > 0 and type(reservationId) == "string" then
			pendingProductId = productId
			pendingReservationId = reservationId
			RuntimeGuard.Run("FoodStealController.PromptProductPurchase", function()
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
		else
			pendingProductId = nil
			pendingReservationId = nil
		end
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "FoodStealController.PromptFinished", function(userId, productId, wasPurchased)
		if userId ~= player.UserId or productId ~= pendingProductId then
			return
		end
		local reservationId = pendingReservationId
		pendingProductId = nil
		pendingReservationId = nil
		if wasPurchased ~= true and reservationId then
			cancelRemote:FireServer(reservationId)
		end
	end)

	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "FoodStealController.AssignedPlotChanged", scanPlots)
	RuntimeGuard.Connect(Workspace.ChildAdded, "FoodStealController.WorkspaceChildAdded", function(child)
		if child.Name == "Plots" and child:IsA("Folder") then
			task.defer(scanPlots)
		end
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, function()
		task.defer(scanPlots)
	end)
	task.defer(scanPlots)
end

return FoodStealController
