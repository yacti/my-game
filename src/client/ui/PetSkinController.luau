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
local YesNoWarning = require(script.Parent:WaitForChild("YesNoWarning"))

local PetSkinController = {}

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
			local guid = ToolIdentity.GuidOf(child)
			if type(petSkinId) == "string"
				and PetSkinCatalog.Get(petSkinId)
				and PetSkinCatalog.TemplateFor(petSkinId)
				and ToolIdentity.IsValidGuid(guid) then
				return child, petSkinId
			end
		end
	end
	return nil
end

function PetSkinController.start()
	local player = Players.LocalPlayer
	local requestRemote = Remotes.get(Remotes.Names.ApplyPetSkinRequest)
	local resultRemote = Remotes.get(Remotes.Names.ApplyPetSkinResult)
	local promptOpen = false
	local confirmationTool = nil
	local confirmationPet = nil
	local pendingRequestId = nil
	local pendingDeadline = 0
	local nextRequestId = 0

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

	local function confirmApply(pet)
		if promptOpen or pendingRequestId ~= nil then return end
		local tool, petSkinId = equippedPetSkinTool(player)
		if not (tool and petSkinId and pet and pet.Parent) then return end
		local oldSkinId = pet:GetAttribute(State.Pet.SkinId)
		local replacing = type(oldSkinId) == "string" and PetSkinCatalog.Get(oldSkinId) ~= nil
		promptOpen = true
		confirmationTool = tool
		confirmationPet = pet
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
			local contextMatches = confirmationTool == tool and confirmationPet == pet
			confirmationTool = nil
			confirmationPet = nil
			promptOpen = false
			if confirmed and contextMatches and tool.Parent == player.Character and pet.Parent then
				sendApply(pet, tool)
			end
		end)
		if not opened then
			promptOpen = false
			confirmationTool = nil
			confirmationPet = nil
		end
	end

	local function resolveFeedPromptOverride(pet)
		local _, petSkinId = equippedPetSkinTool(player)
		if not petSkinId then
			return nil
		end
		local oldSkinId = pet:GetAttribute(State.Pet.SkinId)
		local replacing = type(oldSkinId) == "string" and PetSkinCatalog.Get(oldSkinId) ~= nil
		return {
			actionText = (replacing and "Replace with " or "Apply ") .. PetSkinCatalog.NameFor(petSkinId),
			enabled = not promptOpen and pendingRequestId == nil,
		}
	end

	LocalPrompts.SetPetFeedPromptOverride(resolveFeedPromptOverride, confirmApply)

	RuntimeGuard.Connect(resultRemote.OnClientEvent, "PetSkinController.ApplyResult", function(requestId, success, code)
		if requestId ~= pendingRequestId then return end
		pendingRequestId = nil
		pendingDeadline = 0
		if not success then
			Notifications.show({ kind = NotificationConfig.Kinds.Error, text = failureMessage(code) })
		end
	end)

	RuntimeGuard.Connect(RunService.Heartbeat, "PetSkinController.RequestState", function()
		if promptOpen then
			local equippedTool = equippedPetSkinTool(player)
			if equippedTool ~= confirmationTool or not (confirmationPet and confirmationPet.Parent) then
				promptOpen = false
				confirmationTool = nil
				confirmationPet = nil
				YesNoWarning.Cancel("context-changed")
			end
		end
		if pendingRequestId ~= nil and os.clock() >= pendingDeadline then
			pendingRequestId = nil
			pendingDeadline = 0
			Notifications.show({ kind = NotificationConfig.Kinds.Error, text = failureMessage("timeout") })
		end
	end)

	RuntimeGuard.Connect(player.CharacterAdded, "PetSkinController.CharacterAdded", function()
		if promptOpen then
			YesNoWarning.Cancel("character-reset")
		end
		pendingRequestId = nil
		pendingDeadline = 0
		promptOpen = false
		confirmationTool = nil
		confirmationPet = nil
	end)
end

return PetSkinController
