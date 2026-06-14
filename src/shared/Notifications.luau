local Notifications = {}

Notifications.MaxVisible = 5
Notifications.MaxLifetimeSeconds = 5
Notifications.DefaultLifetimeSeconds = Notifications.MaxLifetimeSeconds

Notifications.Kinds = {
	Info = "info",
	Success = "success",
	Error = "error",
}

Notifications.TextColors = {
	[Notifications.Kinds.Info] = Color3.fromRGB(255, 255, 255),
	[Notifications.Kinds.Success] = Color3.fromRGB(110, 255, 135),
	[Notifications.Kinds.Error] = Color3.fromRGB(255, 105, 105),
}

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
		if type(payload.sound) == "string" and payload.sound ~= "" then
			normalized.sound = payload.sound
		end
	end

	if type(normalized.text) ~= "string" then
		return nil
	end

	normalized.text = string.gsub(normalized.text, "^%s*(.-)%s*$", "%1")
	if normalized.text == "" then
		return nil
	end

	normalized.kind = normalizeKind(normalized.kind)
	normalized.lifetime = normalizeLifetime(normalized.lifetime)

	return normalized
end

return Notifications
