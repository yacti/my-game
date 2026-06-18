local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local SoundEffects = {}

local DEFAULT_LIFETIME_SECONDS = 8
local DEFAULT_PITCH_VARIANCE = 0.3

local rng = Random.new()
local soundsFolder = nil
local animalSoundsFolder = nil

SoundEffects.Names = {
	UiOpen = "UiOpen",
	UiClose = "UiClose",
	UiButtonClick = "UiButtonClick",
	Error = "Error",
	FruitPop = "FruitPop",
	TreeShaken = "TreeShaken",
	PetFed = "PetFed",
	MoneyCollected = "MoneyCollected",
	FoodStolen = "FoodStolen",
	Confetti = "ConfettiSound",
	Drumroll = "Drumroll",
	RollButtonClick = "RollButtonClick",
	CrateBreak = "CrateBreak",
	RollReveal = "RollReveal",
	Wind = "Wind",
}

local function getSoundsFolder()
	if soundsFolder and soundsFolder.Parent then
		return soundsFolder
	end
	soundsFolder = ReplicatedStorage:WaitForChild("Sounds")
	return soundsFolder
end

local function getAnimalSoundsFolder()
	if animalSoundsFolder and animalSoundsFolder.Parent then
		return animalSoundsFolder
	end
	animalSoundsFolder = getSoundsFolder():WaitForChild("AnimalAmbientSounds")
	return animalSoundsFolder
end

local function soundTemplate(folder, soundName)
	local template = folder and folder:FindFirstChild(soundName)
	if template and template:IsA("Sound") then
		return template
	end
	return nil
end

local function randomPitch(baseSpeed, variance)
	baseSpeed = tonumber(baseSpeed) or 1
	variance = tonumber(variance) or DEFAULT_PITCH_VARIANCE
	return baseSpeed * rng:NextNumber(1 - variance, 1 + variance)
end

local function randomPitchRange(baseSpeed, minMultiplier, maxMultiplier)
	baseSpeed = tonumber(baseSpeed) or 1
	minMultiplier = tonumber(minMultiplier) or 1
	maxMultiplier = tonumber(maxMultiplier) or minMultiplier
	if maxMultiplier < minMultiplier then
		minMultiplier, maxMultiplier = maxMultiplier, minMultiplier
	end
	return baseSpeed * rng:NextNumber(minMultiplier, maxMultiplier)
end

local function cleanupAfterPlayback(sound)
	local lifetime = DEFAULT_LIFETIME_SECONDS
	if sound.IsLoaded and sound.TimeLength > 0 then
		lifetime = math.max(sound.TimeLength / math.max(sound.PlaybackSpeed, 0.01) + 1, 1)
	end
	Debris:AddItem(sound, lifetime)
end

local function configureSpatial(sound, range, minRange)
	range = tonumber(range)
	if not range or range <= 0 then
		return
	end
	minRange = tonumber(minRange)
	sound.RollOffMaxDistance = range
	sound.RollOffMinDistance = math.clamp(minRange or math.min(5, range), 0, range)
end

local function playTemplate(template, options)
	options = type(options) == "table" and options or {}
	if not template then
		return nil
	end

	local sound = template:Clone()
	sound.PlaybackSpeed = tonumber(options.playbackSpeed) or template.PlaybackSpeed
	if type(options.pitchMin) == "number" or type(options.pitchMax) == "number" then
		sound.PlaybackSpeed = randomPitchRange(sound.PlaybackSpeed, options.pitchMin, options.pitchMax)
	elseif options.pitchVariance == true then
		sound.PlaybackSpeed = randomPitch(sound.PlaybackSpeed, DEFAULT_PITCH_VARIANCE)
	elseif type(options.pitchVariance) == "number" then
		sound.PlaybackSpeed = randomPitch(sound.PlaybackSpeed, options.pitchVariance)
	end
	configureSpatial(sound, options.range, options.rollOffMinDistance)
	sound.Parent = options.parent or SoundService
	sound:Play()
	if options.cleanup ~= false then
		cleanupAfterPlayback(sound)
	end
	return sound
end

function SoundEffects.Play(soundName, options)
	return playTemplate(soundTemplate(getSoundsFolder(), soundName), options)
end

function SoundEffects.PlayVaried(soundName, options)
	options = type(options) == "table" and table.clone(options) or {}
	options.pitchVariance = options.pitchVariance or true
	return SoundEffects.Play(soundName, options)
end

function SoundEffects.PlayAnimal(petId, options)
	return playTemplate(soundTemplate(getAnimalSoundsFolder(), petId), options)
end

return SoundEffects
