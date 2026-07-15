-- Single client-side gate for rapid shake presentation. The profile-backed
-- setting is read from PlayerStateStore so every effect uses the same value.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerSettings = require(Shared:WaitForChild("PlayerSettings"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local MotionSickness = {}

function MotionSickness.IsEnabled()
	local settings = PlayerStateStore.Get(PlayerStateStore.Fields.PlayerSettings)
	return PlayerSettings.Get(settings, PlayerSettings.Keys.MotionSickness)
end

function MotionSickness.AllowsShakeEffects()
	return not MotionSickness.IsEnabled()
end

return MotionSickness
