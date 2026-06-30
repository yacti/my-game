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

local GrowSkipController = {}

local APPLE_TREE_SEED_ID = "AppleTreeSeed"
local PROMPT_KIND = "GrowSkip"
local PROMPT_DISTANCE = 10
local PROMPT_ATTACHMENT_NAME = "__LocalPrompt_GrowSkipAttachment"
local PROMPT_HEIGHT_ABOVE_PRIMARY_BOTTOM = 5
local EDIT_MODE_ATTR = "EditMode"

local player = Players.LocalPlayer
local requestRemote = Remotes.get(Remotes.Names.GrowSkipRequest)
local resultRemote = Remotes.get(Remotes.Names.GrowSkipResult)

local tracked = {}
local plotConnections = {}
local nextRequestId = 0
local pendingRequestId = nil
local pendingProductId = nil

local function ownPlot()
	return PlotResolver.ResolveForPlayer(player)
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

local function isGrowingTreeSapling(instance)
	return instance ~= nil
		and (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.Seed.Phase) == "GrowingSeed"
		and instance:GetAttribute(State.Feed.Class) == "Tree"
		and instance:GetAttribute(State.Seed.Id) ~= APPLE_TREE_SEED_ID
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
	if player:GetAttribute(EDIT_MODE_ATTR) == true then
		return false
	end
	local plot = ownPlot()
	if not (plot and target:IsDescendantOf(plot)) then
		return false
	end
	return isGrowingTreeSapling(target)
end

local function attachmentFor(target)
	local part = firstBasePart(target)
	if not part then
		return nil
	end
	local attachment = part:FindFirstChild(PROMPT_ATTACHMENT_NAME)
	if attachment and attachment:IsA("Attachment") then
		attachment.Position = Vector3.new(0, -part.Size.Y * 0.5 + PROMPT_HEIGHT_ABOVE_PRIMARY_BOTTOM, 0)
		return attachment
	end
	attachment = Instance.new("Attachment")
	attachment.Name = PROMPT_ATTACHMENT_NAME
	attachment.Position = Vector3.new(0, -part.Size.Y * 0.5 + PROMPT_HEIGHT_ABOVE_PRIMARY_BOTTOM, 0)
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

local function requestSkip(target)
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
	if tracked[target] or not isGrowingTreeSapling(target) then
		return
	end
	local attachment = attachmentFor(target)
	if not attachment then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "__LocalPrompt_" .. PROMPT_KIND
	prompt.ActionText = "Skip Grow"
	prompt.ObjectText = ""
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt:SetAttribute("Theme", "TreeGroundPickup")
	prompt.Parent = attachment

	local record = {
		prompt = prompt,
		attachment = attachment,
		connections = {},
	}
	tracked[target] = record
	record.unregister = LocalPrompts.RegisterExternalPrompt(prompt, function()
		return isAvailable(target)
	end)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(prompt.Triggered, "GrowSkipController.Triggered", function()
		requestSkip(target)
	end)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(target.AncestryChanged, "GrowSkipController.TargetAncestry", function()
		if not target:IsDescendantOf(Workspace) then
			cleanupTarget(target)
		end
	end)
	for _, attributeName in ipairs({ State.Seed.Phase, State.Seed.Id, State.Feed.Class }) do
		record.connections[#record.connections + 1] = RuntimeGuard.Connect(
			target:GetAttributeChangedSignal(attributeName),
			"GrowSkipController.TargetAttribute",
			function()
				if not isGrowingTreeSapling(target) then
					cleanupTarget(target)
				end
			end
		)
	end
end

local function tryBind(instance)
	if isGrowingTreeSapling(instance) then
		bindTarget(instance)
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

local function scanPlot()
	clearAll()
	local plot = ownPlot()
	if not plot then
		return
	end
	for _, descendant in ipairs(plot:GetDescendants()) do
		tryBind(descendant)
	end
	tryBind(plot)
	plotConnections[#plotConnections + 1] = RuntimeGuard.Connect(plot.DescendantAdded, "GrowSkipController.DescendantAdded", function(instance)
		task.defer(function()
			RuntimeGuard.Run("GrowSkipController.TryBind", tryBind, instance)
		end)
	end)
	plotConnections[#plotConnections + 1] = RuntimeGuard.Connect(plot.AncestryChanged, "GrowSkipController.PlotAncestry", function()
		if not plot:IsDescendantOf(Workspace) then
			clearAll()
		end
	end)
end

function GrowSkipController.start()
	RuntimeGuard.Connect(resultRemote.OnClientEvent, "GrowSkipController.Result", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		local productId = tonumber(payload.productId) or 0
		local reservationId = payload.reservationId
		if payload.success == true and productId > 0 and type(reservationId) == "string" then
			pendingProductId = productId
			RuntimeGuard.Run("GrowSkipController.PromptProductPurchase", function()
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
		else
			pendingProductId = nil
		end
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "GrowSkipController.PromptFinished", function(userId, productId, _wasPurchased)
		if userId ~= player.UserId or productId ~= pendingProductId then
			return
		end
		pendingProductId = nil
	end)

	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "GrowSkipController.AssignedPlotChanged", scanPlot)
	RuntimeGuard.Connect(Workspace.ChildAdded, "GrowSkipController.WorkspaceChildAdded", function(child)
		if child.Name == "Plots" and child:IsA("Folder") then
			task.defer(scanPlot)
		end
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, function()
		task.defer(scanPlot)
	end)
	task.defer(scanPlot)
end

return GrowSkipController
