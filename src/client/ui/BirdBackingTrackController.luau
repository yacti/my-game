local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local BirdBackingTrackController = {}

local SOUNDS_FOLDER_NAME = "Sounds"
local SOUND_NAME = "BirdBackingTrack"
local DEFAULT_VOLUME = 0.03

local started = false
local activeSound = nil

local function soundTemplate()
	local sounds = ReplicatedStorage:WaitForChild(SOUNDS_FOLDER_NAME)
	local template = sounds:WaitForChild(SOUND_NAME)
	return template:IsA("Sound") and template or nil
end

function BirdBackingTrackController.start()
	if started then
		return
	end
	started = true

	local template = soundTemplate()
	if not template then
		warn("[BirdBackingTrackController] Missing ReplicatedStorage.Sounds.BirdBackingTrack Sound")
		return
	end

	activeSound = template:Clone()
	activeSound.Name = SOUND_NAME
	activeSound.Looped = true
	activeSound.Volume = tonumber(template.Volume) or DEFAULT_VOLUME
	activeSound.Parent = SoundService
	activeSound:Play()
end

return BirdBackingTrackController
