-- Character presets for global admin messages rendered through the
-- Studio-authored ReplicatedStorage.UI.HUD.AdminText frames.
--
-- Each preset picks a template frame ("Owner" or "Other") and may override the
-- authored display name, profile image, name colour, and message text colour.
-- Fields left nil keep whatever is authored on the Studio template (the Owner
-- frame's photo, name, and verified badge are authored, so its preset
-- overrides nothing but the text colour).
--
-- Adding a character later = adding one entry here (and, if it needs a new
-- layout, authoring another template frame in Studio).

local AdminMessagePresets = {}

-- Replicated runtime folder the server publishes active messages into.
AdminMessagePresets.FolderName = "AdminMessages"

-- Client display tuning (server only stores/validates; clients render).
AdminMessagePresets.DisplaySeconds = 11
AdminMessagePresets.MaxVisible = 3

AdminMessagePresets.Ids = {
	Owner = "Owner",
	Alien = "Alien",
}

AdminMessagePresets.Presets = {
	[AdminMessagePresets.Ids.Owner] = {
		presetId = AdminMessagePresets.Ids.Owner,
		frameName = "Owner",
		image = "rbxassetid://137249489540941",
		textColor = Color3.fromRGB(255, 255, 255),
		soundId = "rbxassetid://133824819874255",
		soundVolume = 0.65,
	},
	[AdminMessagePresets.Ids.Alien] = {
		presetId = AdminMessagePresets.Ids.Alien,
		frameName = "Other",
		displayName = "Mr. Alien",
		image = "rbxassetid://114139662257349",
		-- Name and text share the alien mutation display green
		-- (see Mutations.DisplayColors).
		nameColor = Color3.fromRGB(107, 255, 137),
		textColor = Color3.fromRGB(107, 255, 137),
		soundId = "rbxassetid://136287116644259",
		soundVolume = 0.65,
		minPlaybackSpeed = 0.7,
		maxPlaybackSpeed = 1.3,
	},
}

function AdminMessagePresets.Get(presetId)
	if type(presetId) ~= "string" then
		return nil
	end
	return AdminMessagePresets.Presets[presetId]
end

return AdminMessagePresets
