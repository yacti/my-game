-- Server authority for the owner-only AdminPanel UI (ReplicatedStorage.UI.
-- Menu.AdminPanel). The panel is a thin client over LiveEventCommandService:
-- every button press arrives through AdminPanelCommandRequest, is validated
-- against a hardcoded owner allowlist, and is dispatched to the control plane.
--
-- The panel is invisible and inert until armed from the live server command
-- bar (F9 -> Server), which Roblox restricts to users with edit permission:
--
--   require(game.ServerScriptService.Server.AdminPanelService).Toggle()
--   require(game.ServerScriptService.Server.AdminPanelService).Toggle(17722150)
--
-- Toggle() flips the panel for every allowlisted admin in this server;
-- Toggle(userId) targets one player. Arming is per-server and non-durable.
-- Closing the panel client-side (X / switching menus) disarms it again, so
-- the remote gate always matches what is on screen.
--
-- Studio-only: command-bar/MCP VMs require stateless module copies, so the
-- live server also watches an attribute (same pattern as GameEventDev):
--
--   game.ServerScriptService.Server:SetAttribute("AdminPanelCommand", "toggle")
--
-- The outcome is JSON-encoded into the AdminPanelResult attribute.
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local LiveEventCommandService = require(Server:WaitForChild("LiveEventCommandService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AdminMessagePresets = require(Shared:WaitForChild("AdminMessagePresets"))
local AdminPanelConfig = require(Shared:WaitForChild("AdminPanelConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollChances = require(Shared:WaitForChild("RollChances"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local AdminPanelService = {}

-- Hardcoded owner allowlist, validated server-side on every remote call.
-- Deliberately not a group-rank lookup: rank checks add a web dependency and
-- silently widen the gate to whoever holds the rank later.
local ADMIN_USER_IDS = {
	[17722150] = true, -- yacti (group owner)
}

local Actions = AdminPanelConfig.Actions

local COMMAND_ATTR = "AdminPanelCommand"
local RESULT_ATTR = "AdminPanelResult"
local REQUEST_RATE_SECONDS = 0.5

local started = false
local enabled = {} -- [userId] = true while the panel is armed for that admin
local busy = {} -- [userId] = true while a control-plane command is in flight
local lastRequest = {}

local commandRequestRemote = Remotes.get(Remotes.Names.AdminPanelCommandRequest)
local commandResultRemote = Remotes.get(Remotes.Names.AdminPanelCommandResult)

local function now()
	return Workspace:GetServerTimeNow()
end

local function userKey(player)
	local userId = player and tonumber(player.UserId)
	if type(userId) ~= "number" or userId ~= userId or userId % 1 ~= 0 or userId == 0 then
		return nil
	end
	return userId
end

local function isEligible(player)
	local userId = userKey(player)
	if not userId then
		return false
	end
	if ADMIN_USER_IDS[userId] then
		return true
	end
	-- Studio-only: local test clients (including negative UserIds) may drive
	-- the panel so Play Solo / two-client testing works. Never applies live.
	return RunService:IsStudio()
end

local function setEnabled(player, active)
	local userId = userKey(player)
	if not userId then
		return
	end
	if active then
		enabled[userId] = true
	else
		enabled[userId] = nil
	end
	player:SetAttribute(State.AdminPanel.Enabled, active == true)
end

-- Server command bar / attribute surface. Toggle() flips every allowlisted
-- admin in this server; Toggle(userId) targets one player.
function AdminPanelService.Toggle(userId)
	local targets = {}
	if userId ~= nil then
		userId = tonumber(userId)
		local player = userId and Players:GetPlayerByUserId(userId)
		if not player then
			return false, "player-not-in-server"
		end
		if not isEligible(player) then
			return false, "not-allowlisted"
		end
		targets[1] = player
	else
		for _, player in ipairs(Players:GetPlayers()) do
			if isEligible(player) then
				targets[#targets + 1] = player
			end
		end
	end
	if #targets == 0 then
		return false, "no-eligible-admins"
	end

	local summary = {}
	for _, player in ipairs(targets) do
		local key = userKey(player)
		local active = not enabled[key]
		setEnabled(player, active)
		summary[#summary + 1] = string.format("%s (%d) %s", player.Name, key, active and "ON" or "OFF")
	end
	local text = table.concat(summary, ", ")
	print("[AdminPanelService] Panel toggled: " .. text)
	return true, text
end

local function operatorNote(player)
	return "AdminPanel " .. player.Name
end

-- Runs on a spawned thread: control-plane writes yield (DataStore spacing).
-- Returns (ok, code) where code is a short toast-friendly marker.
local function runAction(player, payload)
	local action = payload.action
	local note = operatorNote(player)

	if action == Actions.SendOwnerMessage or action == Actions.SendAlienMessage then
		local presetId = action == Actions.SendOwnerMessage and AdminMessagePresets.Ids.Owner or AdminMessagePresets.Ids.Alien
		local ok, result = LiveEventCommandService.SendGlobalMessage(payload.text, {
			preset = presetId,
			operatorNote = note,
		})
		return ok, ok and "message-sent" or tostring(result)
	end

	if action == Actions.SetAdminLuck then
		local ok, result = LiveEventCommandService.SetAdminLuck(payload.multiplier, payload.durationSeconds, {
			operatorNote = note,
		})
		return ok, ok and "luck-applied" or tostring(result)
	end

	if action == Actions.RemoveAdminLuck then
		local ok, result = LiveEventCommandService.StopAdminLuck({ operatorNote = note })
		if ok then
			return true, result == "no-change" and "no-luck-active" or "luck-removed"
		end
		return false, tostring(result)
	end

	if action == Actions.AlienStart then
		local ok, result = LiveEventCommandService.StartGlobalEvent("Alien", { operatorNote = note })
		if ok then
			return true, "alien-started"
		end
		return false, tostring(result)
	end

	if action == Actions.AlienStop then
		local ok, countOrCode = LiveEventCommandService.StopGlobalEventsByEventId("Alien")
		if ok then
			return true, "alien-stopped (" .. tostring(countOrCode) .. ")"
		end
		return false, tostring(countOrCode)
	end

	if action == Actions.SprinkleStart then
		local ok, result = LiveEventCommandService.StartGlobalEvent("Sprinkle", { operatorNote = note })
		if ok then
			return true, "sprinkle-started"
		end
		return false, tostring(result)
	end

	if action == Actions.SprinkleStop then
		local ok, countOrCode = LiveEventCommandService.StopGlobalEventsByEventId("Sprinkle")
		if ok then
			return true, "sprinkle-stopped (" .. tostring(countOrCode) .. ")"
		end
		return false, tostring(countOrCode)
	end

	if action == Actions.PadOn or action == Actions.PadOff then
		local ok, result = LiveEventCommandService.SetAdminPartyPad(action == Actions.PadOn, {
			operatorNote = note,
		})
		return ok, ok and (action == Actions.PadOn and "pad-on" or "pad-off") or tostring(result)
	end

	if action == Actions.DropCrate then
		if not RollChances.GetAdminCrate(payload.crateId) then
			return false, "unknown-admin-crate"
		end
		local ok, droppedOrCode = LiveEventCommandService.DropAdminCrate(payload.crateId, {
			operatorNote = note,
		})
		if ok then
			return true, "crate-dropped"
		end
		return false, tostring(droppedOrCode)
	end

	if action == Actions.SpawnPinata then
		-- Client-supplied discriminator: re-validate against the shared
		-- allowlist before it reaches the control plane, same as DropCrate.
		if not AdminPanelConfig.IsAllowedPinataVariant(payload.variant) then
			return false, "unknown-pinata-variant"
		end
		local ok, result = LiveEventCommandService.SpawnPinata(payload.variant, {
			operatorNote = note,
		})
		return ok, ok and ("pinata-spawned (" .. tostring(result) .. ")") or tostring(result)
	end

	if action == Actions.ClearPinatas then
		local ok, result = LiveEventCommandService.ClearPinatas({ operatorNote = note })
		return ok, ok and ("pinatas-cleared (" .. tostring(result) .. ")") or tostring(result)
	end

	return false, "unknown-action"
end

local function reply(player, requestId, ok, code)
	commandResultRemote:FireClient(player, {
		requestId = requestId,
		ok = ok == true,
		code = code,
	})
	if ok then
		NotificationService.Success(player, "Admin: " .. tostring(code))
	else
		NotificationService.Error(player, "Admin failed: " .. tostring(code))
	end
end

local function onCommandRequest(player, payload)
	if type(payload) ~= "table" or type(payload.action) ~= "string" then
		return
	end
	local key = userKey(player)
	-- Fail silently for anyone outside the gate: no oracle for exploiters.
	if not (key and isEligible(player) and enabled[key]) then
		warn(string.format(
			"[AdminPanelService] Dropped unauthorized panel command from %s (%s)",
			player and player.Name or "?",
			tostring(player and player.UserId)
		))
		return
	end

	if payload.action == Actions.ClosePanel then
		setEnabled(player, false)
		return
	end

	local requestId = payload.requestId
	if type(requestId) ~= "number" then
		return
	end

	local nowSeconds = now()
	if lastRequest[key] and nowSeconds - lastRequest[key] < REQUEST_RATE_SECONDS then
		reply(player, requestId, false, "rate-limited")
		return
	end
	lastRequest[key] = nowSeconds
	if busy[key] then
		reply(player, requestId, false, "busy")
		return
	end

	busy[key] = true
	RuntimeGuard.Spawn("AdminPanelService.RunAction", function()
		local ok, actionOk, code = pcall(runAction, player, payload)
		busy[key] = nil
		if not ok then
			warn("[AdminPanelService] Action failed: " .. tostring(actionOk))
			actionOk, code = false, "server-error"
		end
		if player.Parent == Players then
			reply(player, requestId, actionOk, code)
		end
	end)
end

local function watchDevCommands()
	local function writeResult(payload)
		Server:SetAttribute(RESULT_ATTR, HttpService:JSONEncode(payload))
	end
	Server:SetAttribute(COMMAND_ATTR, nil)
	RuntimeGuard.Connect(Server:GetAttributeChangedSignal(COMMAND_ATTR), "AdminPanelService.DevCommand", function()
		local command = Server:GetAttribute(COMMAND_ATTR)
		if type(command) ~= "string" or command == "" then
			return
		end
		Server:SetAttribute(COMMAND_ATTR, nil)
		local verb, argument = string.match(command, "^(%a+):?(%-?%d*)$")
		if verb ~= "toggle" then
			writeResult({ ok = false, code = "unknown-command" })
			return
		end
		local ok, result = AdminPanelService.Toggle(argument ~= "" and tonumber(argument) or nil)
		writeResult({ ok = ok, result = result })
	end)
end

function AdminPanelService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(commandRequestRemote.OnServerEvent, "AdminPanelService.CommandRequest", onCommandRequest)
	RuntimeGuard.Connect(Players.PlayerRemoving, "AdminPanelService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			enabled[key] = nil
			busy[key] = nil
			lastRequest[key] = nil
		end
	end)

	if RunService:IsStudio() then
		watchDevCommands()
	end
end

return AdminPanelService
