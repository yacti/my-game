local ConfigService = game:GetService("ConfigService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local StealSettingService = {}

-- Food-steal pricing A/B test. The Creator Hub config key holds the control
-- default ("normal", one steal dev product for every food); the experiment
-- overrides it to "tiered" for the treatment group, which prices each steal by
-- the stolen food's rarity. Enrollment happens per player at GetValue(), so
-- this must use GetConfigForPlayerAsync — the experience-wide GetConfigAsync
-- snapshot never returns experiment variants.
local CONFIG_KEY = "StealSetting"
local SETTING_NORMAL = "normal"
local SETTING_TIERED = "tiered"
local RETRY_DELAYS_SECONDS = { 2, 5, 10 }
-- Studio never enrolls in experiments; set this attribute on the Server script
-- folder (command bar) to "tiered" to playtest the treatment variant.
local STUDIO_OVERRIDE_ATTR = "StealSettingOverride"

local SERVER_FOLDER = ServerScriptService:WaitForChild("Server")

local started = false

local function normalizeSetting(value)
	if type(value) ~= "string" then
		return nil
	end
	value = string.lower(value)
	if value == SETTING_NORMAL or value == SETTING_TIERED then
		return value
	end
	return nil
end

local function studioOverride()
	if not RunService:IsStudio() then
		return nil
	end
	return normalizeSetting(SERVER_FOLDER:GetAttribute(STUDIO_OVERRIDE_ATTR))
end

local function fetchSettingFor(player)
	local snapshot = ConfigService:GetConfigForPlayerAsync(player)
	return snapshot and normalizeSetting(snapshot:GetValue(CONFIG_KEY)) or nil
end

local function resolveSettingFor(player)
	local override = studioOverride()
	if override then
		return override
	end
	for attempt = 1, #RETRY_DELAYS_SECONDS + 1 do
		local ok, setting = pcall(fetchSettingFor, player)
		if ok then
			return setting or SETTING_NORMAL
		end
		if attempt <= #RETRY_DELAYS_SECONDS then
			task.wait(RETRY_DELAYS_SECONDS[attempt])
		else
			warn(string.format(
				"[StealSettingService] Config lookup failed for %d, defaulting to %s: %s",
				player.UserId,
				SETTING_NORMAL,
				tostring(setting)
			))
		end
		if player.Parent == nil then
			return nil
		end
	end
	return SETTING_NORMAL
end

local function assignSetting(player)
	local setting = resolveSettingFor(player)
	if setting and player.Parent ~= nil then
		player:SetAttribute(State.Player.StealSetting, setting)
	end
end

-- Steals attempted before the config resolves (or after a failed lookup) use
-- the control product, never a tiered one.
function StealSettingService.Get(player)
	local setting = player and normalizeSetting(player:GetAttribute(State.Player.StealSetting))
	return setting or SETTING_NORMAL
end

function StealSettingService.IsTiered(player)
	return StealSettingService.Get(player) == SETTING_TIERED
end

function StealSettingService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Players.PlayerAdded, "StealSettingService.PlayerAdded", function(player)
		RuntimeGuard.Spawn("StealSettingService.Assign." .. tostring(player.UserId), assignSetting, player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		RuntimeGuard.Spawn("StealSettingService.Assign." .. tostring(player.UserId), assignSetting, player)
	end

	if RunService:IsStudio() then
		RuntimeGuard.Connect(
			SERVER_FOLDER:GetAttributeChangedSignal(STUDIO_OVERRIDE_ATTR),
			"StealSettingService.StudioOverride",
			function()
				for _, player in ipairs(Players:GetPlayers()) do
					RuntimeGuard.Spawn("StealSettingService.Assign." .. tostring(player.UserId), assignSetting, player)
				end
			end
		)
	end
end

return StealSettingService
