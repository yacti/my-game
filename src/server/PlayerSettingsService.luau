-- Owns the Settings menu toggles: validates PlayerSettingsUpdateRequest
-- payloads, persists them on the profile, republishes the replica field, and
-- mirrors acceptGifts to the public AcceptGiftsDisabled player attribute so
-- giver clients can hide gift prompts without asking the server.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerSettings = require(Shared:WaitForChild("PlayerSettings"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(script.Parent:WaitForChild("PlayerReplicaService"))
local RollService = require(script.Parent:WaitForChild("RollService"))

local REQUEST_MIN_INTERVAL_SECONDS = 0.2

local PlayerSettingsService = {}

local lastRequestAt = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function applyAcceptGiftsAttribute(player, settings)
	local acceptGifts = PlayerSettings.Get(settings, PlayerSettings.Keys.AcceptGifts)
	player:SetAttribute(State.Player.AcceptGiftsDisabled, if acceptGifts then nil else true)
end

-- Called by init.server once the profile is loaded so the attribute mirror is
-- in place before other players can see the character.
function PlayerSettingsService.ApplyToPlayer(player, profile)
	if not (player and profile) then
		return
	end
	applyAcceptGiftsAttribute(player, profile.Data.PlayerSettings)
end

function PlayerSettingsService.Start()
	RuntimeGuard.Connect(
		Remotes.get(Remotes.Names.PlayerSettingsUpdateRequest).OnServerEvent,
		"PlayerSettingsService.UpdateRequest",
		function(player, payload)
			local key = userKey(player)
			if not key or type(payload) ~= "table" then
				return
			end

			local now = os.clock()
			if now - (lastRequestAt[key] or 0) < REQUEST_MIN_INTERVAL_SECONDS then
				return
			end
			lastRequestAt[key] = now

			local profile = PlayerDataService.GetProfile(player)
			if not profile then
				return
			end

			-- Merge: only known keys with boolean values are applied; the rest
			-- of the payload is ignored.
			local settings = PlayerSettings.CopySettings(profile.Data.PlayerSettings)
			local preservedAutoRollBefore = PlayerSettings.Get(
				settings,
				PlayerSettings.Keys.PreserveAutoRollOnRejoin
			)
			local changed = false
			for _, settingKey in pairs(PlayerSettings.Keys) do
				local value = payload[settingKey]
				if type(value) == "boolean" and settings[settingKey] ~= value then
					settings[settingKey] = value
					changed = true
				end
			end
			if not changed then
				return
			end

			profile.Data.PlayerSettings = settings
			local preservedAutoRollAfter = PlayerSettings.Get(
				settings,
				PlayerSettings.Keys.PreserveAutoRollOnRejoin
			)
			if preservedAutoRollBefore ~= preservedAutoRollAfter then
				-- Enabling captures the live state; disabling clears only the saved
				-- state and deliberately leaves this server's auto-roll session alone.
				RollService.SaveAutoRollPreference(player, profile)
			end
			PlayerReplicaService.PublishPlayerSettings(player, profile)
			applyAcceptGiftsAttribute(player, settings)
		end
	)

	RuntimeGuard.Connect(Players.PlayerRemoving, "PlayerSettingsService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			lastRequestAt[key] = nil
		end
	end)
end

return PlayerSettingsService
