local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerSettings = require(Shared:WaitForChild("PlayerSettings"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local MusicPlaylistController = {}

local LOADING_SCREEN_NAME = "LoadingScreen"
local SOUNDS_FOLDER_NAME = "Sounds"
local PLAYLIST_FOLDER_NAME = "MusicPlaylist"

local FADE_IN_SECONDS = 20
local MIN_SILENCE_SECONDS = 15
local MAX_SILENCE_SECONDS = 120
local DEFAULT_VOLUME = 0.1
local MUSIC_VOLUME_MULTIPLIER = 0.65
local LOAD_TIMEOUT_SECONDS = 15
local TRACK_END_PADDING_SECONDS = 5

local MUSIC_STOP_FADE_SECONDS = 0.75

local rng = Random.new()
local started = false
local musicEnabled = true
local activeSound = nil
local playbackSuppressors = {}
local playbackRevision = 0

local function playbackAllowed()
	return musicEnabled and next(playbackSuppressors) == nil
end

local function waitForLoadingScreenDismissed()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local loadingScreen = playerGui:FindFirstChild(LOADING_SCREEN_NAME)
	if not loadingScreen then
		return
	end

	while playerGui:FindFirstChild(LOADING_SCREEN_NAME) do
		local removed = playerGui.ChildRemoved:Wait()
		if removed.Name == LOADING_SCREEN_NAME then
			return
		end
	end
end

local function getPlaylist()
	local sounds = ReplicatedStorage:WaitForChild(SOUNDS_FOLDER_NAME)
	return sounds:WaitForChild(PLAYLIST_FOLDER_NAME)
end

local function getTracks(playlist)
	local tracks = {}
	for _, child in ipairs(playlist:GetChildren()) do
		if child:IsA("Sound") and child.SoundId ~= "" then
			table.insert(tracks, child)
		end
	end
	return tracks
end

local function chooseTrack(playlist)
	local tracks = getTracks(playlist)
	if #tracks == 0 then
		return nil
	end
	return tracks[rng:NextInteger(1, #tracks)]
end

local function waitForLoaded(sound)
	if sound.IsLoaded then
		return true
	end

	local loaded = false
	local connection = sound.Loaded:Connect(function()
		loaded = true
	end)
	local deadline = os.clock() + LOAD_TIMEOUT_SECONDS
	while sound.Parent and not loaded and not sound.IsLoaded and os.clock() < deadline do
		task.wait(0.1)
	end
	connection:Disconnect()

	return loaded or sound.IsLoaded
end

local function waitForEnded(sound, ended)
	local timeLength = tonumber(sound.TimeLength) or 0
	local timeout = math.max(timeLength + TRACK_END_PADDING_SECONDS, LOAD_TIMEOUT_SECONDS)
	local deadline = os.clock() + timeout
	while sound.Parent and not ended() and os.clock() < deadline do
		task.wait(0.25)
	end
	return ended()
end

local function preloadSound(sound)
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync({ sound })
	end)
	if not ok then
		warn("[MusicPlaylistController] Music preload failed: " .. tostring(err))
	end
	return waitForLoaded(sound)
end

-- Fading to silence and destroying the active sound unparents it, which also
-- unblocks waitForEnded so the playlist loop can park until re-enabled.
local function stopActiveTrack()
	local sound = activeSound
	activeSound = nil
	if not (sound and sound.Parent) then
		return
	end
	TweenService:Create(
		sound,
		TweenInfo.new(MUSIC_STOP_FADE_SECONDS, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ Volume = 0 }
	):Play()
	task.delay(MUSIC_STOP_FADE_SECONDS, function()
		sound:Destroy()
	end)
end

local function interruptibleWait(seconds, revision)
	local deadline = os.clock() + math.max(tonumber(seconds) or 0, 0)
	while playbackRevision == revision and os.clock() < deadline do
		task.wait(math.min(0.25, math.max(deadline - os.clock(), 0)))
	end
end

local function playTrack(template)
	if not playbackAllowed() then
		return false
	end

	local targetVolume = tonumber(template.Volume) or DEFAULT_VOLUME
	if targetVolume <= 0 then
		targetVolume = DEFAULT_VOLUME
	end
	targetVolume *= MUSIC_VOLUME_MULTIPLIER

	local sound = template:Clone()
	sound.Name = "CurrentMusicTrack"
	sound.Looped = false
	sound.Volume = 0
	sound.Parent = SoundService

	if not preloadSound(sound) then
		warn("[MusicPlaylistController] Music track failed to load: " .. template.SoundId)
		sound:Destroy()
		return false
	end

	sound.TimePosition = 0
	sound.Volume = 0

	local ended = false
	local endedConnection = sound.Ended:Connect(function()
		ended = true
	end)

	activeSound = sound
	sound:Play()
	TweenService:Create(
		sound,
		TweenInfo.new(FADE_IN_SECONDS, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ Volume = targetVolume }
	):Play()

	local completed = waitForEnded(sound, function()
		return ended
	end)
	endedConnection:Disconnect()
	if activeSound == sound then
		activeSound = nil
	end
	sound:Destroy()
	return completed
end

local function runPlaylist()
	waitForLoadingScreenDismissed()

	local playlist = getPlaylist()
	while true do
		while not playbackAllowed() do
			task.wait(0.5)
		end

		local template = chooseTrack(playlist)
		local completed = false
		if template then
			local ok, result = RuntimeGuard.Run("MusicPlaylistController.PlayTrack", playTrack, template)
			completed = ok and result == true
		else
			warn("[MusicPlaylistController] ReplicatedStorage.Sounds.MusicPlaylist has no playable tracks")
		end

		local revision = playbackRevision
		if completed then
			interruptibleWait(rng:NextNumber(MIN_SILENCE_SECONDS, MAX_SILENCE_SECONDS), revision)
		else
			interruptibleWait(1, revision)
		end
	end
end

-- Event soundtracks can temporarily own the music channel without changing
-- the player's persisted Music setting. Multiple suppressors compose safely.
function MusicPlaylistController.SetPlaybackSuppressed(suppressorId, suppressed)
	if type(suppressorId) ~= "string" or suppressorId == "" then
		return
	end
	if suppressed then
		if playbackSuppressors[suppressorId] then
			return
		end
		playbackSuppressors[suppressorId] = true
		playbackRevision += 1
		stopActiveTrack()
	else
		if not playbackSuppressors[suppressorId] then
			return
		end
		playbackSuppressors[suppressorId] = nil
		playbackRevision += 1
	end
end

function MusicPlaylistController.start()
	if started then
		return
	end
	started = true

	local function onSettingsChanged(value)
		local enabled = PlayerSettings.Get(PlayerSettings.CopySettings(value), PlayerSettings.Keys.MusicEnabled)
		if enabled == musicEnabled then
			return
		end
		musicEnabled = enabled
		playbackRevision += 1
		if not playbackAllowed() then
			stopActiveTrack()
		end
	end
	onSettingsChanged(PlayerStateStore.Get(PlayerStateStore.Fields.PlayerSettings))
	PlayerStateStore.Observe(PlayerStateStore.Fields.PlayerSettings, onSettingsChanged)

	task.spawn(runPlaylist)
end

return MusicPlaylistController
