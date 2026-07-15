-- Player-facing on/off preferences shown in the Settings menu. The profile is
-- authoritative; the replica carries a sanitized copy to the owning client and
-- acceptGifts is additionally mirrored to a public player attribute (see
-- State.Player.AcceptGiftsDisabled) so other clients can hide gift prompts.
local PlayerSettings = {}

PlayerSettings.Keys = {
	MusicEnabled = "musicEnabled",
	TreeAutoCollect = "treeAutoCollect",
	AcceptGifts = "acceptGifts",
	MotionSickness = "motionSickness",
	HidePetsInEditMode = "hidePetsInEditMode",
}

PlayerSettings.Defaults = {
	musicEnabled = true,
	treeAutoCollect = true,
	acceptGifts = true,
	motionSickness = false,
	hidePetsInEditMode = false,
}

-- Returns a fresh table containing only known keys as booleans; anything
-- missing or malformed falls back to its default.
function PlayerSettings.CopySettings(value)
	if type(value) ~= "table" then
		value = {}
	end
	local copy = {}
	for _, key in pairs(PlayerSettings.Keys) do
		local entry = value[key]
		if type(entry) == "boolean" then
			copy[key] = entry
		else
			copy[key] = PlayerSettings.Defaults[key]
		end
	end
	return copy
end

function PlayerSettings.Get(settings, key)
	if type(settings) == "table" and type(settings[key]) == "boolean" then
		return settings[key]
	end
	return PlayerSettings.Defaults[key]
end

return PlayerSettings
