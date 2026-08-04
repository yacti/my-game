local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetSkinCatalog = require(Shared:WaitForChild("PetSkinCatalog"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local AnimalAmbientSoundService = {}

local AMBIENT_MIN_SECONDS = 10
local AMBIENT_MAX_SECONDS = 50
local ELIGIBLE_DISTANCE = 50
local SOUND_RANGE = 50
local PITCH_VARIANCE = 0.3
local EVOLUTION_BURST_START_DELAY = 3
local EVOLUTION_PREVIEW_STEP_SECONDS = 0.715
local EVOLUTION_BURST_GAP = 1
local EVOLUTION_BURST_FINAL_PITCH = 1.5
local EVOLUTION_AMBIENT_SUPPRESSION_SECONDS = 20

local AnimalAmbientSound = Remotes.get(Remotes.Names.AnimalAmbientSound)
local animalSoundsFolder = ReplicatedStorage:WaitForChild("Sounds"):WaitForChild("AnimalAmbientSounds")
local rng = Random.new()
local trackedPets = setmetatable({}, { __mode = "k" })
local started = false

local function isPet(instance)
	return instance and instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil
end

local function soundTemplateForPetId(petId)
	if type(petId) ~= "string" or petId == "" then
		return nil
	end
	local sound = animalSoundsFolder:FindFirstChild(petId)
	return sound and sound:IsA("Sound") and sound or nil
end

-- The client picks the actual sound; this only decides whether the pet has any
-- ambient audio to send, so a skin covers for a pet id with no template.
local function hasAmbientAudio(pet, petId)
	-- The client drops any payload whose petId does not match the live pet, so
	-- a skin cannot rescue a pet that has no id to validate against.
	if type(petId) ~= "string" or petId == "" then
		return false
	end
	local petSkinId = pet:GetAttribute(State.Pet.SkinId)
	local definition = type(petSkinId) == "string" and PetSkinCatalog.Get(petSkinId) or nil
	if definition and type(definition.SoundId) == "string" then
		return true
	end
	return soundTemplateForPetId(petId) ~= nil
end

local function firstBasePart(instance)
	if not instance then
		return nil
	end
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

local function petPosition(pet)
	local part = pet.PrimaryPart or firstBasePart(pet)
	return part and part.Position or nil
end

local function playerRootPosition(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function variedPitch()
	return rng:NextNumber(1 - PITCH_VARIANCE, 1 + PITCH_VARIANCE)
end

local function fireToNearbyPlayers(pet, playbackSpeed, extraPayload)
	if not (pet and pet.Parent and isPet(pet)) then
		return
	end
	local petId = pet:GetAttribute(State.Pet.Id)
	if not hasAmbientAudio(pet, petId) then
		return
	end
	local position = petPosition(pet)
	if not position then
		return
	end

	local payload = {
		pet = pet,
		petId = petId,
		playbackSpeed = tonumber(playbackSpeed) or 1,
		range = SOUND_RANGE,
	}
	if type(extraPayload) == "table" then
		for key, value in pairs(extraPayload) do
			payload[key] = value
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local rootPosition = playerRootPosition(player)
		if rootPosition and (rootPosition - position).Magnitude <= ELIGIBLE_DISTANCE then
			AnimalAmbientSound:FireClient(player, payload)
		end
	end
end

local function trackPet(pet)
	if trackedPets[pet] or not isPet(pet) then
		return
	end

	local record = {
		active = true,
	}
	trackedPets[pet] = record

	RuntimeGuard.Connect(pet.Destroying, "AnimalAmbientSoundService.PetDestroying", function()
		record.active = false
		trackedPets[pet] = nil
	end)

	RuntimeGuard.Spawn("AnimalAmbientSoundService.PetLoop", function()
		while record.active and pet.Parent do
			task.wait(rng:NextNumber(AMBIENT_MIN_SECONDS, AMBIENT_MAX_SECONDS))
			if not record.suppressAmbientUntil or os.clock() >= record.suppressAmbientUntil then
				RuntimeGuard.Run("AnimalAmbientSoundService.PlayAmbient", fireToNearbyPlayers, pet, variedPitch())
			end
		end
		trackedPets[pet] = nil
	end)
end

local function scanRoot(root)
	for _, instance in ipairs(root:GetDescendants()) do
		if isPet(instance) then
			trackPet(instance)
		end
	end
end

local function evolutionBurstStartDelay(pathPetIds)
	local pathLength = type(pathPetIds) == "table" and #pathPetIds or 0
	local intermediatePreviewCount = math.max(pathLength - 2, 0)
	return EVOLUTION_BURST_START_DELAY + intermediatePreviewCount * EVOLUTION_PREVIEW_STEP_SECONDS
end

function AnimalAmbientSoundService.PlayEvolutionBurst(pet, pathPetIds)
	if not isPet(pet) then
		return
	end

	local record = trackedPets[pet]
	if not record then
		trackPet(pet)
		record = trackedPets[pet]
	end

	local sequenceId = pet:GetAttribute(State.Pet.EvolutionSeq)
	if record then
		if type(sequenceId) == "number" and record.lastEvolutionBurstSeq == sequenceId then
			return
		end
		record.lastEvolutionBurstSeq = sequenceId
		record.suppressAmbientUntil = os.clock() + EVOLUTION_AMBIENT_SUPPRESSION_SECONDS
	end

	task.delay(evolutionBurstStartDelay(pathPetIds), function()
		RuntimeGuard.Run("AnimalAmbientSoundService.EvolutionBurstSequence", function()
			fireToNearbyPlayers(pet, nil, {
				evolutionBurst = true,
				seq = sequenceId,
				gap = EVOLUTION_BURST_GAP,
				playbackSpeeds = {
					variedPitch(),
					variedPitch(),
					EVOLUTION_BURST_FINAL_PITCH,
				},
			})
		end)
	end)
end

function AnimalAmbientSoundService.Start()
	if started then
		return
	end
	started = true

	scanRoot(Workspace)
	RuntimeGuard.Connect(Workspace.DescendantAdded, "AnimalAmbientSoundService.DescendantAdded", function(instance)
		if isPet(instance) then
			trackPet(instance)
		end
	end)
end

return AnimalAmbientSoundService
