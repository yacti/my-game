local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventPromptConfig = require(Shared:WaitForChild("EventPromptConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(script.Parent:WaitForChild("PlayerReplicaService"))

local EventRsvpPromptService = {}

local REQUEST_RATE_SECONDS = 1

local started = false
local pendingByUserId = {}
local lastRequestAtByUserId = {}

local requestRemote = Remotes.get(Remotes.Names.EventRsvpPromptRequest)
local resultRemote = Remotes.get(Remotes.Names.EventRsvpPromptResult)

local function userKey(player)
	return player and player.UserId or nil
end

local function sendResult(player, eventId, code)
	resultRemote:FireClient(player, {
		eventId = eventId,
		code = code,
	})
end

local function takeRequestRateLimit(key)
	local now = os.clock()
	local previous = lastRequestAtByUserId[key]
	if previous and now - previous < REQUEST_RATE_SECONDS then
		return false
	end
	lastRequestAtByUserId[key] = now
	return true
end

local function requestPrompt(player, eventId, profile, key)
	if not takeRequestRateLimit(key) then
		return
	end
	if profile.Data.LastPromptedEventId == eventId then
		PlayerReplicaService.PublishLastPromptedEventId(player, profile)
		sendResult(player, eventId, "already-prompted")
		return
	end
	if pendingByUserId[key] ~= nil then
		sendResult(player, eventId, "busy")
		return
	end

	pendingByUserId[key] = eventId
	sendResult(player, eventId, "granted")
end

local function completePrompt(player, eventId, profile, key)
	if pendingByUserId[key] ~= eventId then
		return
	end
	pendingByUserId[key] = nil

	if profile.Data.LastPromptedEventId == eventId then
		return
	end
	profile.Data.LastPromptedEventId = eventId
	PlayerReplicaService.PublishLastPromptedEventId(player, profile)

	-- ProfileStore owns retry/autosave behavior. This asks it to save promptly;
	-- retaining the in-session mutation also lets later autosave/session close
	-- persist it if the immediate backend write fails.
	local ok, err = pcall(function()
		profile:Save()
	end)
	if not ok then
		warn("[EventRsvpPromptService] Failed to request profile save: " .. tostring(err))
	end
end

local function handleRequest(player, action, submittedEventId)
	if type(action) ~= "string" or type(submittedEventId) ~= "string" then
		return
	end

	local activeEventId = EventPromptConfig.GetActiveEventId()
	if not activeEventId or submittedEventId ~= activeEventId then
		return
	end

	local key = userKey(player)
	local profile = key and PlayerDataService.GetProfile(player) or nil
	if not (key and profile and profile:IsActive()) then
		return
	end

	if action == "request" then
		requestPrompt(player, activeEventId, profile, key)
	elseif action == "complete" then
		completePrompt(player, activeEventId, profile, key)
	elseif action == "failed" and pendingByUserId[key] == activeEventId then
		pendingByUserId[key] = nil
	end
end

function EventRsvpPromptService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(requestRemote.OnServerEvent, "EventRsvpPromptService.Request", handleRequest)
	RuntimeGuard.Connect(Players.PlayerRemoving, "EventRsvpPromptService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			pendingByUserId[key] = nil
			lastRequestAtByUserId[key] = nil
		end
	end)
end

return EventRsvpPromptService
