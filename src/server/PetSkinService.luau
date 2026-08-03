local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local AnimalAmbientSoundService = require(Server:WaitForChild("AnimalAmbientSoundService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PetMotionService = require(Server:WaitForChild("PetMotionService"))
local PetSkinTools = require(Server:WaitForChild("PetSkinTools"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlotService = require(Server:WaitForChild("PlotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetSkinCatalog = require(Shared:WaitForChild("PetSkinCatalog"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local ToolIdentity = require(Shared:WaitForChild("ToolIdentity"))

local PetSkinService = {}

local RATE_SECONDS = 0.35
local APPLY_DISTANCE = 18
local CUE_KIND = "PetSkinApply"

local locks = {}
local lastRequestAt = {}

local function validRequestId(requestId)
	return (type(requestId) == "number" and requestId == requestId and math.abs(requestId) < math.huge)
		or (type(requestId) == "string" and requestId ~= "" and #requestId <= 64)
end

local function takeRateLimit(player)
	local key = player and player.UserId
	if not key then
		return false
	end
	local now = os.clock()
	if now - (lastRequestAt[key] or 0) < RATE_SECONDS then
		return false
	end
	lastRequestAt[key] = now
	return true
end

local function rootPart(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function isNear(player, pet)
	local root = rootPart(player)
	return root ~= nil and (root.Position - pet:GetPivot().Position).Magnitude <= APPLY_DISTANCE
end

local function resolvePet(plot, target)
	if typeof(target) ~= "Instance" or not target:IsDescendantOf(plot) then
		return nil
	end
	local current = target
	while current and current ~= plot do
		if current:IsA("Model")
			and type(current:GetAttribute(State.Pet.Index)) == "number"
			and type(current:GetAttribute(State.Pet.Id)) == "string" then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function sendResult(remote, player, requestId, success, code, payload)
	remote:FireClient(player, requestId, success == true, code, payload)
end

local function saveProfile(profile)
	return pcall(function()
		profile:Save()
	end)
end

local function publishSkinApplyCue(pet, oldPetId, oldSkinId, targetSkinId, oldScale, pivot)
	local seq = (pet:GetAttribute(State.Pet.EvolutionSeq) or 0) + 1
	pet:SetAttribute(State.Pet.EvolutionOldPetId, oldPetId)
	pet:SetAttribute(State.Pet.EvolutionOldScale, oldScale)
	pet:SetAttribute(State.Pet.EvolutionPivot, pivot)
	pet:SetAttribute(State.Pet.EvolutionPathPetIds, HttpService:JSONEncode({ oldPetId }))
	pet:SetAttribute(State.Pet.EvolutionCueKind, CUE_KIND)
	pet:SetAttribute(State.Pet.EvolutionOldSkinId, oldSkinId)
	pet:SetAttribute(State.Pet.EvolutionTargetSkinId, targetSkinId)
	pet:SetAttribute(State.Pet.EvolutionSeq, seq)
	task.delay(8, function()
		RuntimeGuard.Run("PetSkinService.ClearCue", function()
			if pet.Parent and pet:GetAttribute(State.Pet.EvolutionSeq) == seq then
				pet:SetAttribute(State.Pet.EvolutionOldPetId, nil)
				pet:SetAttribute(State.Pet.EvolutionOldScale, nil)
				pet:SetAttribute(State.Pet.EvolutionPivot, nil)
				pet:SetAttribute(State.Pet.EvolutionPathPetIds, nil)
				pet:SetAttribute(State.Pet.EvolutionCueKind, nil)
				pet:SetAttribute(State.Pet.EvolutionOldSkinId, nil)
				pet:SetAttribute(State.Pet.EvolutionTargetSkinId, nil)
			end
		end)
	end)
end

function PetSkinService.Start(config)
	config = type(config) == "table" and config or {}
	local isGameplayBlocked = type(config.isGameplayBlocked) == "function" and config.isGameplayBlocked or function()
		return false
	end
	local requestRemote = Remotes.get(Remotes.Names.ApplyPetSkinRequest)
	local resultRemote = Remotes.get(Remotes.Names.ApplyPetSkinResult)

	RuntimeGuard.Connect(Players.PlayerRemoving, "PetSkinService.PlayerRemoving", function(player)
		locks[player.UserId] = nil
		lastRequestAt[player.UserId] = nil
	end)

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "PetSkinService.ApplyRequest", function(player, requestId, target, toolGuid)
		if not validRequestId(requestId) or not ToolIdentity.IsValidGuid(toolGuid) or #toolGuid > 64 then
			sendResult(resultRemote, player, requestId, false, "invalid-request")
			return
		end
		if not takeRateLimit(player) then
			sendResult(resultRemote, player, requestId, false, "rate-limited")
			return
		end
		local key = player.UserId
		if locks[key] or isGameplayBlocked(player) or OfflineProgressService.IsPending(player) then
			sendResult(resultRemote, player, requestId, false, "busy")
			return
		end
		locks[key] = true
		local transaction = nil
		local ok, err = pcall(function()
			local plot = PlotService.GetPlayerPlot(player)
			local profile = PlayerDataService.GetProfile(player)
			if not (plot and profile) then
				sendResult(resultRemote, player, requestId, false, "no-plot")
				return
			end
			local pet = resolvePet(plot, target)
			if not pet then
				sendResult(resultRemote, player, requestId, false, "invalid-target")
				return
			end
			if not isNear(player, pet) then
				sendResult(resultRemote, player, requestId, false, "too-far")
				return
			end
			local tool = ToolIdentity.FindEquippedByGuid(player, toolGuid, PetSkinTools.IsPetSkinTool)
			if not tool then
				sendResult(resultRemote, player, requestId, false, "no-pet-skin")
				return
			end
			if ToolIdentity.IsFavourite(tool) then
				sendResult(resultRemote, player, requestId, false, "favourited")
				return
			end
			local petSkinId = PetSkinTools.PetSkinIdOf(tool)
			local skinDefinition = PetSkinCatalog.Get(petSkinId)
			local petIndex = pet:GetAttribute(State.Pet.Index)
			local petData = profile.Data.Pets and profile.Data.Pets[petIndex]
			if not (skinDefinition and petData) then
				sendResult(resultRemote, player, requestId, false, "invalid-pet-skin")
				return
			end

			local oldSkinId = type(petData.skinId) == "string" and petData.skinId or nil
			local oldPetId = petData.petId
			local oldScale = pet:GetScale()
			local oldPivot = PetMotionService.GetLogicalPivot(pet)
			local oldParent = tool.Parent
			local inventory = profile.Data.PetSkinInventory or {}
			local oldCount = math.max(math.floor(tonumber(inventory[petSkinId]) or 0), 0)
			if oldCount <= 0 then
				sendResult(resultRemote, player, requestId, false, "missing-inventory")
				return
			end

			-- Reserve the exact Tool while the save is in flight; this prevents a
			-- death/equip race without consuming it before persistence succeeds.
			tool.Parent = nil
			transaction = {
				tool = tool,
				oldParent = oldParent,
				profile = profile,
				plot = plot,
				petData = petData,
				petIndex = petIndex,
				petSkinId = petSkinId,
				oldSkinId = oldSkinId,
				oldPetId = oldPetId,
				oldCount = oldCount,
				oldPivot = oldPivot,
			}
			petData.skinId = petSkinId
			inventory[petSkinId] = oldCount - 1
			if inventory[petSkinId] <= 0 then
				inventory[petSkinId] = nil
			end
			profile.Data.PetSkinInventory = inventory

			local newPet = PlotService.ReplacePetAt(plot, pet, oldPetId, petIndex, petData.xp or 0, oldPivot, petSkinId)
			if not newPet then
				petData.skinId = oldSkinId
				inventory[petSkinId] = oldCount
				tool.Parent = oldParent
				transaction = nil
				sendResult(resultRemote, player, requestId, false, "visual-build-failed")
				return
			end
			transaction.newPet = newPet
			newPet:SetAttribute(State.Pet.XP, petData.xp or 0)
			newPet:SetAttribute(State.Pet.Money, petData.money or 0)
			PetMotionService.Register(plot, newPet)

			if not saveProfile(profile) then
				petData.skinId = oldSkinId
				inventory[petSkinId] = oldCount
				local restoredPet = PlotService.ReplacePetAt(plot, newPet, oldPetId, petIndex, petData.xp or 0, oldPivot, oldSkinId)
				if restoredPet then
					restoredPet:SetAttribute(State.Pet.XP, petData.xp or 0)
					restoredPet:SetAttribute(State.Pet.Money, petData.money or 0)
					PetMotionService.Register(plot, restoredPet)
				end
				local backpack = player:FindFirstChildOfClass("Backpack")
				tool.Parent = oldParent and oldParent.Parent and oldParent or backpack
				transaction = nil
				sendResult(resultRemote, player, requestId, false, "save-failed")
				return
			end

			transaction.committed = true
			tool:Destroy()
			RuntimeGuard.Run("PetSkinService.PublishInventory", PlayerReplicaService.PublishInventories, player, profile)
			RuntimeGuard.Run(
				"PetSkinService.PublishEvolutionCue",
				publishSkinApplyCue,
				newPet,
				oldPetId,
				oldSkinId,
				petSkinId,
				oldScale,
				oldPivot
			)
			RuntimeGuard.Run(
				"PetSkinService.PlayEvolutionBurst",
				AnimalAmbientSoundService.PlayEvolutionBurst,
				newPet,
				{ oldPetId }
			)
			sendResult(resultRemote, player, requestId, true, "ok", {
				pet = newPet,
				petSkinId = petSkinId,
				replacedPetSkinId = oldSkinId,
			})
			transaction.resultSent = true
		end)
		locks[key] = nil
		if not ok then
			warn("[PetSkinService] Apply failed: " .. tostring(err))
			if transaction and not transaction.committed then
				local petData = transaction.petData
				petData.skinId = transaction.oldSkinId
				local inventory = transaction.profile.Data.PetSkinInventory or {}
				inventory[transaction.petSkinId] = transaction.oldCount
				transaction.profile.Data.PetSkinInventory = inventory
				local livePet = transaction.newPet
				if livePet and livePet.Parent then
					local restored = PlotService.ReplacePetAt(
						transaction.plot,
						livePet,
						transaction.oldPetId,
						transaction.petIndex,
						petData.xp or 0,
						transaction.oldPivot,
						transaction.oldSkinId
					)
					if restored then
						restored:SetAttribute(State.Pet.XP, petData.xp or 0)
						restored:SetAttribute(State.Pet.Money, petData.money or 0)
						PetMotionService.Register(transaction.plot, restored)
					end
				end
				local backpack = player:FindFirstChildOfClass("Backpack")
				if transaction.tool and not transaction.tool.Parent then
					transaction.tool.Parent = transaction.oldParent and transaction.oldParent.Parent and transaction.oldParent or backpack
				end
			end
			if transaction and transaction.committed then
				-- Persistence is authoritative. If a post-commit presentation step
				-- failed, never tell the client the consumed application failed.
				if not transaction.resultSent then
					sendResult(resultRemote, player, requestId, true, "ok", {
						pet = transaction.newPet,
						petSkinId = transaction.petSkinId,
						replacedPetSkinId = transaction.oldSkinId,
					})
				end
			else
				sendResult(resultRemote, player, requestId, false, "server-error")
			end
		end
	end)
end

return PetSkinService
