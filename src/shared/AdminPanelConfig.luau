-- Shared contract between the owner AdminPanel UI (client) and
-- AdminPanelService / LiveEventCommandService (server): the remote action ids,
-- the luck multipliers the control plane accepts, and the panel's time-step
-- sizes. The server validates against this module; the client only uses it to
-- build requests and previews.
local AdminPanelConfig = {}

-- Whitelist mirrored by the AdminPanel luck buttons (2x/5x/10x/25x).
-- SetAdminLuck rejects anything else, so a forged remote cannot pick an
-- arbitrary multiplier.
AdminPanelConfig.AllowedLuckMultipliers = { 2, 5, 10, 25 }

-- Same absolute ceiling as global live events (fat-finger protection).
AdminPanelConfig.MaxLuckDurationSeconds = 72 * 3600

AdminPanelConfig.LuckSmallStepSeconds = 30 * 60
AdminPanelConfig.LuckLargeStepSeconds = 6 * 3600

-- Pinata variants the panel may spawn, mirrored by the Pinata row's buttons.
-- SpawnPinata rejects anything else, so a forged remote cannot spawn an
-- arbitrary model name. Kept here (not in Pinata.luau) for the same reason
-- AllowedLuckMultipliers lives here: it is the shared client/server allowlist
-- that AdminPanelService and LiveEventCommandService both validate against.
AdminPanelConfig.PinataButtons = {
	{ button = "SpawnOneDefault", variant = "Default" },
	{ button = "SpawnOneGold", variant = "Golden" },
}

function AdminPanelConfig.IsAllowedPinataVariant(variant)
	if type(variant) ~= "string" then
		return false
	end
	for _, entry in ipairs(AdminPanelConfig.PinataButtons) do
		if entry.variant == variant then
			return true
		end
	end
	return false
end

AdminPanelConfig.Actions = {
	SendOwnerMessage = "SendOwnerMessage",
	SendAlienMessage = "SendAlienMessage",
	SetAdminLuck = "SetAdminLuck",
	RemoveAdminLuck = "RemoveAdminLuck",
	AlienStart = "AlienStart",
	AlienStop = "AlienStop",
	-- Sprinkle runs until Stop with a hidden failsafe, same shape as Alien.
	SprinkleStart = "SprinkleStart",
	SprinkleStop = "SprinkleStop",
	PadOn = "PadOn",
	PadOff = "PadOff",
	DropCrate = "DropCrate",
	-- One-shot pinata spawn / global clear (see docs/live-events.md).
	SpawnPinata = "SpawnPinata",
	ClearPinatas = "ClearPinatas",
	-- Panel closed client-side (X button / switching menus): disarms the
	-- panel server-side so armed state always matches what is on screen.
	ClosePanel = "ClosePanel",
}

function AdminPanelConfig.IsAllowedLuckMultiplier(multiplier)
	multiplier = tonumber(multiplier)
	if type(multiplier) ~= "number" or multiplier ~= multiplier then
		return false
	end
	for _, allowed in ipairs(AdminPanelConfig.AllowedLuckMultipliers) do
		if multiplier == allowed then
			return true
		end
	end
	return false
end

return AdminPanelConfig
