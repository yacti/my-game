local Notifications = {}

Notifications.MaxVisible = 5
Notifications.MaxLifetimeSeconds = 5
Notifications.DefaultLifetimeSeconds = Notifications.MaxLifetimeSeconds

Notifications.Kinds = {
	Info = "info",
	Success = "success",
	Error = "error",
	Rebirth = "rebirth",
	-- Text colour animates with the Mythical rarity rainbow (see Rarities)
	-- while the notification is on screen.
	Mythical = "mythical",
	-- Text colour shimmers between the two golds below (see GoldenColorAt)
	-- while the notification is on screen. Used by the Golden Pinata spawn toast.
	Golden = "golden",
}

Notifications.TextColors = {
	[Notifications.Kinds.Info] = Color3.fromRGB(255, 255, 255),
	[Notifications.Kinds.Success] = Color3.fromRGB(110, 255, 135),
	[Notifications.Kinds.Error] = Color3.fromRGB(255, 105, 105),
	[Notifications.Kinds.Rebirth] = Color3.fromRGB(210, 80, 255),
	[Notifications.Kinds.Mythical] = Color3.fromRGB(255, 0, 255),
	-- First stop of the shimmer, so the frame before the animation loop's first
	-- tick is already gold rather than a flash of another colour.
	[Notifications.Kinds.Golden] = Color3.fromRGB(255, 184, 0),
}

-- The Golden shimmer: one period travels to the second gold and back. Pure and
-- clock-driven, matching Rarities.ColorFor, so the client can sample it per
-- frame with no per-toast state.
Notifications.GoldenTweenColors = {
	Color3.fromRGB(255, 184, 0),
	Color3.fromRGB(255, 241, 0),
}
Notifications.GoldenTweenPeriod = 1.5

function Notifications.GoldenColorAt(timeSeconds)
	local from, to = Notifications.GoldenTweenColors[1], Notifications.GoldenTweenColors[2]
	local period = Notifications.GoldenTweenPeriod
	local clock = tonumber(timeSeconds) or 0
	if clock ~= clock or period <= 0 then
		return from
	end
	-- Cosine ping-pong: 0 at both ends of the period, 1 at the midpoint, so the
	-- two stops ease into each other instead of snapping back.
	local alpha = 0.5 - 0.5 * math.cos((clock / period) * math.pi * 2)
	return from:Lerp(to, alpha)
end

local DEFAULT_KIND = Notifications.Kinds.Info

local function normalizeKind(kind)
	for _, allowed in pairs(Notifications.Kinds) do
		if kind == allowed then
			return kind
		end
	end
	return DEFAULT_KIND
end

local function normalizeLifetime(lifetime)
	if type(lifetime) ~= "number" or lifetime <= 0 or lifetime ~= lifetime or lifetime == math.huge then
		return Notifications.DefaultLifetimeSeconds
	end
	return math.clamp(lifetime, 1, Notifications.MaxLifetimeSeconds)
end

function Notifications.Normalize(payload)
	local normalized = {}

	if type(payload) == "string" then
		normalized.text = payload
	elseif type(payload) == "table" then
		normalized.text = payload.text or payload.message or payload[1]
		normalized.kind = payload.kind
		normalized.lifetime = payload.lifetime or payload.duration
		normalized.preserveTrailingPeriods = payload.preserveTrailingPeriods == true
		if type(payload.sound) == "string" and payload.sound ~= "" then
			normalized.sound = payload.sound
		end
	end

	if type(normalized.text) ~= "string" then
		return nil
	end

	normalized.text = string.gsub(normalized.text, "^%s*(.-)%s*$", "%1")
	if not normalized.preserveTrailingPeriods then
		normalized.text = string.gsub(normalized.text, "%.+$", "")
	end
	if normalized.text == "" then
		return nil
	end

	normalized.kind = normalizeKind(normalized.kind)
	normalized.lifetime = normalizeLifetime(normalized.lifetime)

	return normalized
end

return Notifications
