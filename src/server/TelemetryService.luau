local HttpService = game:GetService("HttpService")

local TelemetryService = {}

local INFO_LOGGING_ENABLED = false

local function sanitize(value, depth)
	depth = depth or 0
	if depth > 3 then
		return "<max-depth>"
	end

	local valueType = typeof(value)
	if valueType == "Instance" then
		return value:GetFullName()
	end
	if valueType == "Vector3" then
		return {
			x = math.round(value.X * 100) / 100,
			y = math.round(value.Y * 100) / 100,
			z = math.round(value.Z * 100) / 100,
		}
	end
	if valueType == "CFrame" then
		return sanitize(value.Position, depth + 1)
	end
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		if type(key) == "string" or type(key) == "number" then
			copy[key] = sanitize(child, depth + 1)
		end
	end
	return copy
end

local function emit(level, eventName, fields)
	local payload = sanitize(fields or {})
	payload.event = eventName
	payload.time = os.time()

	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	local line = "[Telemetry] " .. tostring(eventName) .. " " .. (ok and encoded or tostring(payload))
	if level == "warn" then
		warn(line)
	else
		print(line)
	end
end

function TelemetryService.Record(eventName, fields)
	if INFO_LOGGING_ENABLED then
		emit("info", eventName, fields)
	end
end

function TelemetryService.Warn(eventName, fields)
	emit("warn", eventName, fields)
end

function TelemetryService.ForPlayer(player, fields)
	fields = fields or {}
	if player then
		fields.userId = player.UserId
	end
	return fields
end

return TelemetryService
