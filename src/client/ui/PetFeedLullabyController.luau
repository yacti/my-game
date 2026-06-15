local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local PetFeedLullabyController = {}

local IDLE_RESET_SECONDS = 3
local MAX_ACTIVE_SOUNDS = 10

local function semitoneRatio(offset)
	return 2 ^ (offset / 12)
end

local NOTE_RATIOS = {
	C = 1,
	D = semitoneRatio(2),
	E = semitoneRatio(4),
	F = semitoneRatio(5),
	G = semitoneRatio(7),
	A = semitoneRatio(9),
}

local MELODY = {
	"C", "C", "G", "G", "A", "A", "G",
	"F", "F", "E", "E", "D", "D", "C",
	"G", "G", "F", "F", "E", "E", "D",
	"G", "G", "F", "F", "E", "E", "D",
	"C", "C", "G", "G", "A", "A", "G",
	"F", "F", "E", "E", "D", "D", "C",
}

local nextNoteIndex = 1
local lastFeedAt = nil
local activeSounds = {}

local function pruneActiveSounds()
	local kept = {}
	for _, sound in ipairs(activeSounds) do
		if sound and sound.Parent ~= nil then
			kept[#kept + 1] = sound
		end
	end
	activeSounds = kept
end

local function destroyOldestUntilUnderCap()
	while #activeSounds >= MAX_ACTIVE_SOUNDS do
		local sound = table.remove(activeSounds, 1)
		if sound and sound.Parent ~= nil then
			sound:Destroy()
		end
	end
end

function PetFeedLullabyController.PlayNextFeedNote()
	local now = os.clock()
	if lastFeedAt == nil or now - lastFeedAt > IDLE_RESET_SECONDS then
		nextNoteIndex = 1
	end
	lastFeedAt = now

	local note = MELODY[nextNoteIndex] or "C"
	nextNoteIndex += 1
	if nextNoteIndex > #MELODY then
		nextNoteIndex = 1
	end

	pruneActiveSounds()
	destroyOldestUntilUnderCap()

	local sound = SoundEffects.Play(SoundEffects.Names.PetFed, {
		playbackSpeed = NOTE_RATIOS[note] or 1,
	})
	if sound then
		activeSounds[#activeSounds + 1] = sound
	end
end

return PetFeedLullabyController
