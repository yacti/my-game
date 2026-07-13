local ConfigService = game:GetService("ConfigService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local SkipTimeStationService = {}

-- Mailbox vs SkipTimeSign A/B test. The Creator Hub config key holds the
-- control default ("mailbox"); the experiment overrides it to "sign" for the
-- treatment group. Enrollment happens per player at GetValue(), so this must
-- use GetConfigForPlayerAsync — the experience-wide GetConfigAsync snapshot
-- never returns experiment variants.
local CONFIG_KEY = "SkipTimeStation"
local STATION_MAILBOX = "mailbox"
local STATION_SIGN = "sign"
local RETRY_DELAYS_SECONDS = { 2, 5, 10 }
-- Studio never enrolls in experiments; set this attribute on the Server
-- script folder (command bar) to "sign" to playtest the treatment variant.
local STUDIO_OVERRIDE_ATTR = "SkipTimeStationOverride"

local SERVER_FOLDER = ServerScriptService:WaitForChild("Server")

local started = false

local function normalizeStation(value)
	if type(value) ~= "string" then
		return nil
	end
	value = string.lower(value)
	if value == STATION_MAILBOX or value == STATION_SIGN then
		return value
	end
	return nil
end

local function studioOverride()
	if not RunService:IsStudio() then
		return nil
	end
	return normalizeStation(SERVER_FOLDER:GetAttribute(STUDIO_OVERRIDE_ATTR))
end

local function fetchStationFor(player)
	local snapshot = ConfigService:GetConfigForPlayerAsync(player)
	return snapshot and normalizeStation(snapshot:GetValue(CONFIG_KEY)) or nil
end

local function resolveStationFor(player)
	local override = studioOverride()
	if override then
		return override
	end
	for attempt = 1, #RETRY_DELAYS_SECONDS + 1 do
		local ok, station = pcall(fetchStationFor, player)
		if ok then
			return station or STATION_MAILBOX
		end
		if attempt <= #RETRY_DELAYS_SECONDS then
			task.wait(RETRY_DELAYS_SECONDS[attempt])
		else
			warn(string.format(
				"[SkipTimeStationService] Config lookup failed for %d, defaulting to %s: %s",
				player.UserId,
				STATION_MAILBOX,
				tostring(station)
			))
		end
		if player.Parent == nil then
			return nil
		end
	end
	return STATION_MAILBOX
end

local function assignStation(player)
	local station = resolveStationFor(player)
	if station and player.Parent ~= nil then
		player:SetAttribute(State.Player.SkipTimeStation, station)
	end
end

function SkipTimeStationService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Players.PlayerAdded, "SkipTimeStationService.PlayerAdded", function(player)
		RuntimeGuard.Spawn("SkipTimeStationService.Assign." .. tostring(player.UserId), assignStation, player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		RuntimeGuard.Spawn("SkipTimeStationService.Assign." .. tostring(player.UserId), assignStation, player)
	end

	if RunService:IsStudio() then
		RuntimeGuard.Connect(
			SERVER_FOLDER:GetAttributeChangedSignal(STUDIO_OVERRIDE_ATTR),
			"SkipTimeStationService.StudioOverride",
			function()
				for _, player in ipairs(Players:GetPlayers()) do
					RuntimeGuard.Spawn("SkipTimeStationService.Assign." .. tostring(player.UserId), assignStation, player)
				end
			end
		)
	end
end

return SkipTimeStationService
