local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local PetSkinCatalog = require(Shared:WaitForChild("PetSkinCatalog"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local LocalPrompts = require(script.Parent:WaitForChild("LocalPrompts"))
local Notifications = require(script.Parent:WaitForChild("Notifications"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local YesNoWarning = require(script.Parent:WaitForChild("YesNoWarning"))

local PetSkinController = {}

local PROMPT_DISTANCE = 18
local UPDATE_INTERVAL = 0.1
local ATTACHMENT_NAME = "__PetSkinApplyPromptAttachment"
local REQUEST_TIMEOUT_SECONDS = 10

local FAILURE_MESSAGES = {
	busy = "Please wait before applying another Pet Skin",
	favourited = "Unfavourite this Pet Skin before applying it",
	["invalid-target"] = "That pet does not belong to you",
	["missing-inventory"] = "That Pet Skin is no longer in your inventory",
	["no-pet-skin"] = "Hold the Pet Skin you want to apply",
	["rate-limited"] = "Please wait before applying another Pet Skin",
	["save-failed"] = "Could not save that Pet Skin. Your item was not consumed",
	timeout = "The Pet Skin request timed out. Your item was not consumed; please try again",
	["too-far"] = "Move closer to that pet",
	["visual-build-failed"] = "That Pet Skin could not be loaded",
}

local function failureMessage(code)
	return FAILURE_MESSAGES[code] or "Could not apply that Pet Skin"
end

local function equippedPetSkinTool(player)
	local character = player.Character
	if not character then return nil end
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			local petSkinId = child:GetAttribute(State.PetSkin.Id)
			if type(petSkinId) == "string" and PetSkinCatalog.Get(petSkinId) then
				return child, petSkinId
			end
		end
	end
	return nil
end

local function playerRootPosition(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function isPet(instance)
	return instance:IsA("Model") and type(instance:GetAttribute(State.Pet.Index)) == "number"
end

function PetSkinController.start()
	local player = Players.LocalPlayer
	local requestRemote = Remotes.get(Remotes.Names.ApplyPetSkinRequest)
	local resultRemote = Remotes.get(Remotes.Names.ApplyPetSkinResult)
	local promptRecord = nil
	local currentPet = nil
	local promptOpen = false
	local pendingRequestId = nil
	local pendingDeadline = 0
	local nextRequestId = 0
	local elapsed = UPDATE_INTERVAL

	local function clearPrompt()
		currentPet = nil
		if not promptRecord then return end
		if promptRecord.triggered then promptRecord.triggered:Disconnect() end
		if promptRecord.unregister then promptRecord.unregister() end
		promptRecord.prompt.Enabled = false
		promptRecord.prompt:Destroy()
		if promptRecord.attachment.Parent then promptRecord.attachment:Destroy() end
		promptRecord = nil
	end

	local function promptAvailable()
		local tool = equippedPetSkinTool(player)
		local plot = PlotResolver.ResolveForPlayer(player)
		return not promptOpen
			and pendingRequestId == nil
			and tool ~= nil
			and plot ~= nil
			and currentPet ~= nil
			and currentPet.Parent ~= nil
			and currentPet:IsDescendantOf(plot)
			and player:GetAttribute(State.Player.OfflineProgressPending) ~= true
	end

	local function sendApply(pet, tool)
		local guid = ToolIdentity.GuidOf(tool)
		if not ToolIdentity.IsValidGuid(guid) then
			Notifications.show({ kind = NotificationConfig.Kinds.Error, text = failureMessage("no-pet-skin") })
			return
		end
		nextRequestId += 1
		pendingRequestId = nextRequestId
		pendingDeadline = os.clock() + REQUEST_TIMEOUT_SECONDS
		requestRemote:FireServer(nextRequestId, pet, guid)
	end

	local function confirmApply()
		if promptOpen or pendingRequestId ~= nil then return end
		local tool, petSkinId = equippedPetSkinTool(player)
		local pet = currentPet
		if not (tool and petSkinId and pet and pet.Parent) then return end
		local oldSkinId = pet:GetAttribute(State.Pet.SkinId)
		local replacing = type(oldSkinId) == "string" and PetSkinCatalog.Get(oldSkinId) ~= nil
		promptOpen = true
		local skinName = PetSkinCatalog.NameFor(petSkinId)
		local opened = YesNoWarning.Prompt({
			title = replacing and "Replace Pet Skin?" or "Apply Pet Skin?",
			question = replacing
				and "The current skin will be permanently replaced and this item will be consumed:"
				or "This item will be permanently consumed:",
			itemText = skinName,
			itemRarity = PetSkinCatalog.RarityFor(petSkinId),
			yesText = "Apply",
			noText = "Cancel",
		}, function(confirmed)
			promptOpen = false
			if confirmed and tool.Parent == player.Character and pet.Parent then
				sendApply(pet, tool)
			end
		end)
		if not opened then promptOpen = false end
	end

	local function ensurePrompt(pet)
		local primary = pet.PrimaryPart
		if not primary then
			clearPrompt()
			return
		end
		if not promptRecord then
			local attachment = Instance.new("Attachment")
			attachment.Name = ATTACHMENT_NAME
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "PetSkinApplyPrompt"
			prompt.KeyboardKeyCode = Enum.KeyCode.E
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = PROMPT_DISTANCE
			prompt.RequiresLineOfSight = false
			prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
			prompt.Enabled = false
			prompt.Parent = attachment
			promptRecord = { attachment = attachment, prompt = prompt }
			promptRecord.unregister = LocalPrompts.RegisterExternalPrompt(prompt, promptAvailable, {
				highlightTarget = function() return currentPet end,
			})
			promptRecord.triggered = RuntimeGuard.Connect(prompt.Triggered, "PetSkinController.PromptTriggered", confirmApply)
		end
		currentPet = pet
		local _, petSkinId = equippedPetSkinTool(player)
		promptRecord.prompt.ActionText = "Apply " .. PetSkinCatalog.NameFor(petSkinId)
		if promptRecord.attachment.Parent ~= primary then
			promptRecord.attachment.Parent = primary
		end
		local boundsCF, boundsSize = pet:GetBoundingBox()
		promptRecord.attachment.Position = primary.CFrame:PointToObjectSpace(
			boundsCF.Position + Vector3.new(0, boundsSize.Y * 0.5 + 1, 0)
		)
	end

	local function updatePrompt()
		if promptOpen or pendingRequestId ~= nil then
			if promptRecord then promptRecord.prompt.Enabled = false end
			return
		end
		local tool = equippedPetSkinTool(player)
		local plot = PlotResolver.ResolveForPlayer(player)
		local rootPosition = playerRootPosition(player)
		if not (tool and plot and rootPosition) then
			clearPrompt()
			return
		end
		local nearest = nil
		local nearestDistance = PROMPT_DISTANCE
		for _, child in ipairs(plot:GetChildren()) do
			if isPet(child) then
				local distance = (child:GetPivot().Position - rootPosition).Magnitude
				if distance <= nearestDistance then
					nearest = child
					nearestDistance = distance
				end
			end
		end
		if nearest then ensurePrompt(nearest) else clearPrompt() end
	end

	RuntimeGuard.Connect(resultRemote.OnClientEvent, "PetSkinController.ApplyResult", function(requestId, success, code)
		if requestId ~= pendingRequestId then return end
		pendingRequestId = nil
		pendingDeadline = 0
		if not success then
			Notifications.show({ kind = NotificationConfig.Kinds.Error, text = failureMessage(code) })
		end
		updatePrompt()
	end)

	RuntimeGuard.Connect(RunService.Heartbeat, "PetSkinController.PromptUpdate", function(dt)
		if pendingRequestId ~= nil and os.clock() >= pendingDeadline then
			pendingRequestId = nil
			pendingDeadline = 0
			Notifications.show({ kind = NotificationConfig.Kinds.Error, text = failureMessage("timeout") })
		end
		elapsed += dt
		if elapsed < UPDATE_INTERVAL then return end
		elapsed = 0
		updatePrompt()
	end)

	RuntimeGuard.Connect(player.CharacterAdded, "PetSkinController.CharacterAdded", function()
		pendingRequestId = nil
		pendingDeadline = 0
		promptOpen = false
		clearPrompt()
	end)
end

return PetSkinController
