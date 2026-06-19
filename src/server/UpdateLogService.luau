local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(script.Parent:WaitForChild("PlayerReplicaService"))

local UpdateLogService = {}

local RATE_SECONDS = 1
local UPDATE_LOG_FRAME_NAME = "UpdateLog"
local MENU_NAME = "Menu"

local started = false
local lastRequestAt = {}
local locks = {}

local closedRemote = Remotes.get(Remotes.Names.UpdateLogClosed)

local function userKey(player)
	return player and player.UserId or nil
end

local function trim(value)
	return string.match(value, "^%s*(.-)%s*$")
end

local function sanitizeUpdateId(value)
	if type(value) ~= "string" then
		return nil
	end
	local updateId = trim(value)
	if updateId == "" then
		return nil
	end
	return updateId
end

local function currentUpdateId()
	local ui = ReplicatedStorage:FindFirstChild("UI")
	local menu = ui and ui:FindFirstChild(MENU_NAME)
	local updateLog = menu and menu:FindFirstChild(UPDATE_LOG_FRAME_NAME)
	if not updateLog then
		return nil
	end
	return sanitizeUpdateId(updateLog:GetAttribute(State.UpdateLog.Id))
end

local function takeRateLimit(player)
	local key = userKey(player)
	if not key then
		return false
	end
	local now = os.clock()
	local previous = lastRequestAt[key]
	if previous and now - previous < RATE_SECONDS then
		return false
	end
	lastRequestAt[key] = now
	return true
end

local function saveProfile(profile)
	local ok, err = pcall(function()
		profile:Save()
	end)
	if not ok then
		warn("[UpdateLogService] Profile save failed: " .. tostring(err))
	end
	return ok
end

local function acknowledgeClosed(player, submittedUpdateId)
	if not takeRateLimit(player) then
		return
	end

	local updateId = currentUpdateId()
	if not updateId or sanitizeUpdateId(submittedUpdateId) ~= updateId then
		return
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return
	end

	local key = userKey(player)
	if not key or locks[key] then
		return
	end

	locks[key] = true
	local ok, err = pcall(function()
		if profile.Data.LastSeenUpdateLogId ~= updateId then
			profile.Data.LastSeenUpdateLogId = updateId
			PlayerReplicaService.PublishLastSeenUpdateLogId(player, profile)
			saveProfile(profile)
		else
			PlayerReplicaService.PublishLastSeenUpdateLogId(player, profile)
		end
	end)
	locks[key] = nil

	if not ok then
		warn("[UpdateLogService] Failed to acknowledge update log close: " .. tostring(err))
	end
end

function UpdateLogService.Start()
	if started then
		return
	end
	started = true

	if not currentUpdateId() then
		warn("[UpdateLogService] Missing ReplicatedStorage.UI.Menu.UpdateLog UpdateLogId attribute; update log auto-show disabled")
	end

	RuntimeGuard.Connect(closedRemote.OnServerEvent, "UpdateLogService.Closed", acknowledgeClosed)
	RuntimeGuard.Connect(Players.PlayerRemoving, "UpdateLogService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			lastRequestAt[key] = nil
			locks[key] = nil
		end
	end)
end

return UpdateLogService
