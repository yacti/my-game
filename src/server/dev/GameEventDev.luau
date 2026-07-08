-- Studio-only command surface for manual game events (Tsunami, Earthquake,
-- Alien...). GameEventService intentionally has no client or admin remote, and
-- command-bar/MCP execution runs in a separate VM whose requires are stateless
-- module copies -- so, like PlotStressTest, the live server watches an
-- attribute on ServerScriptService.Server and any VM can drive it:
--
--   Server:SetAttribute("GameEventDevCommand", HttpService:JSONEncode({
--       action = "start", eventId = "Earthquake", startsAtOffset = -21,
--   }))
--
-- Actions: start (eventId, startsAtOffset?, durationSeconds?),
-- stop (instanceId), complete (instanceId), disable-tutorial (all players).
-- Each command's outcome is JSON-encoded into the GameEventDevResult
-- attribute for the caller to read back.
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Server = script.Parent.Parent
local GameEventService = require(Server:WaitForChild("GameEventService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local GameEventDev = {}

local SERVER_FOLDER = ServerScriptService:WaitForChild("Server")
local COMMAND_ATTR = "GameEventDevCommand"
local RESULT_ATTR = "GameEventDevResult"

local watchConnection = nil

local function writeResult(payload)
	SERVER_FOLDER:SetAttribute(RESULT_ATTR, HttpService:JSONEncode(payload))
end

local function disableTutorialForAll()
	local completed = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = PlayerDataService.GetProfile(player)
		if profile and profile.Data then
			profile.Data.Onboarding = Onboarding.CompleteState()
			PlayerReplicaService.PublishOnboarding(player, profile)
			completed += 1
		end
	end
	return { ok = true, completed = completed }
end

local function runCommand(command)
	local action = command.action
	if action == "start" then
		local options = {}
		if type(command.startsAtOffset) == "number" then
			options.startsAt = Workspace:GetServerTimeNow() + command.startsAtOffset
		end
		if type(command.durationSeconds) == "number" then
			options.durationSeconds = command.durationSeconds
		end
		local ok, result = GameEventService.StartManualEvent(command.eventId, options)
		if ok then
			return { ok = true, instanceId = result.instanceId, startsAt = result.startsAt, endsAt = result.endsAt }
		end
		return { ok = false, code = tostring(result) }
	elseif action == "stop" then
		local ok, code = GameEventService.StopManualEvent(command.instanceId)
		return { ok = ok == true, code = code }
	elseif action == "complete" then
		GameEventService.CompleteInstance(command.instanceId)
		return { ok = true }
	elseif action == "disable-tutorial" then
		return disableTutorialForAll()
	end
	return { ok = false, code = "unknown-action" }
end

local function onCommand()
	local raw = SERVER_FOLDER:GetAttribute(COMMAND_ATTR)
	if type(raw) ~= "string" or raw == "" then
		return
	end
	SERVER_FOLDER:SetAttribute(COMMAND_ATTR, nil)
	local ok, command = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(command) ~= "table" then
		writeResult({ ok = false, code = "invalid-json" })
		return
	end
	writeResult(runCommand(command))
end

function GameEventDev.Watch()
	if not RunService:IsStudio() then
		return false, "not-studio"
	end
	if watchConnection then
		return true
	end
	watchConnection = RuntimeGuard.Connect(SERVER_FOLDER:GetAttributeChangedSignal(COMMAND_ATTR), "GameEventDev.CommandChanged", onCommand)
	onCommand()
	return true
end

return GameEventDev
