local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local AnimalAmbientSounds = {}

local DEFAULT_SOUND_RANGE = 50
local DEFAULT_SEQUENCE_GAP_SECONDS = 1
local LOAD_TIMEOUT_SECONDS = 5
local END_TIMEOUT_PADDING_SECONDS = 2

local started = false
local activeEvolutionSeqByPet = setmetatable({}, { __mode = "k" })

local function isPet(instance)
	return instance and instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil
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

local function payloadStillValid(pet, petId)
	return typeof(pet) == "Instance"
		and isPet(pet)
		and pet:IsDescendantOf(Workspace)
		and type(petId) == "string"
		and petId ~= ""
		and pet:GetAttribute(State.Pet.Id) == petId
end

local function waitForLoaded(sound)
	if not sound or not sound.Parent or sound.IsLoaded then
		return sound ~= nil and sound.Parent ~= nil
	end

	local loaded = false
	local connection = sound.Loaded:Connect(function()
		loaded = true
	end)
	local deadline = os.clock() + LOAD_TIMEOUT_SECONDS
	while sound.Parent and not loaded and not sound.IsLoaded and os.clock() < deadline do
		task.wait(0.05)
	end
	connection:Disconnect()
	return sound.Parent ~= nil
end

local function waitForEnded(sound)
	if not (sound and sound.Parent) then
		return
	end

	local ended = false
	local connection = sound.Ended:Connect(function()
		ended = true
	end)
	waitForLoaded(sound)

	local timeLength = sound.IsLoaded and tonumber(sound.TimeLength) or 0
	local playbackSpeed = math.max(tonumber(sound.PlaybackSpeed) or 1, 0.01)
	local timeout = math.max((timeLength / playbackSpeed) + END_TIMEOUT_PADDING_SECONDS, LOAD_TIMEOUT_SECONDS)
	local deadline = os.clock() + timeout
	while sound.Parent and not ended and os.clock() < deadline do
		task.wait(0.05)
	end
	connection:Disconnect()
end

local function playAnimalSound(petId, soundParent, playbackSpeed, range, ownCleanup)
	return SoundEffects.PlayAnimal(petId, {
		parent = soundParent,
		playbackSpeed = tonumber(playbackSpeed) or 1,
		range = tonumber(range) or DEFAULT_SOUND_RANGE,
		cleanup = ownCleanup ~= true,
	})
end

local function playEvolutionSequence(pet, petId, soundParent, payload)
	local playbackSpeeds = type(payload.playbackSpeeds) == "table" and payload.playbackSpeeds or {}
	local gap = tonumber(payload.gap) or DEFAULT_SEQUENCE_GAP_SECONDS
	local range = tonumber(payload.range) or DEFAULT_SOUND_RANGE
	local soundPetId = type(payload.soundPetId) == "string" and payload.soundPetId or petId

	for index = 1, #playbackSpeeds do
		if not payloadStillValid(pet, petId) or not soundParent.Parent then
			return
		end

		local sound = playAnimalSound(soundPetId, soundParent, playbackSpeeds[index], range, true)
		waitForEnded(sound)
		if sound and sound.Parent then
			sound:Destroy()
		end

		if index < #playbackSpeeds then
			task.wait(gap)
		end
	end
end

local function playPayload(payload)
	if type(payload) ~= "table" then
		return
	end
	local pet = payload.pet
	local petId = payload.petId
	if not payloadStillValid(pet, petId) then
		return
	end

	local soundParent = pet.PrimaryPart or firstBasePart(pet)
	if not soundParent then
		return
	end

	if payload.evolutionBurst == true then
		local seq = tonumber(payload.seq)
		if seq and activeEvolutionSeqByPet[pet] == seq then
			return
		end
		activeEvolutionSeqByPet[pet] = seq or true
		task.spawn(function()
			RuntimeGuard.Run("AnimalAmbientSounds.EvolutionSequence", playEvolutionSequence, pet, petId, soundParent, payload)
			if activeEvolutionSeqByPet[pet] == (seq or true) then
				activeEvolutionSeqByPet[pet] = nil
			end
		end)
		return
	end

	local soundPetId = type(payload.soundPetId) == "string" and payload.soundPetId or petId
	playAnimalSound(soundPetId, soundParent, payload.playbackSpeed, payload.range, false)
end

function AnimalAmbientSounds.start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.AnimalAmbientSound).OnClientEvent, "AnimalAmbientSounds.Event", playPayload)
end

return AnimalAmbientSounds
