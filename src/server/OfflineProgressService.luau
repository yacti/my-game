local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local OfflineProgressService = {}

local FLASH_ACK_TIMEOUT_SECONDS = 10
local DEFAULT_STARTER_PET_ID = "Pet1"

local sessions = {}
local systems = {}
local nextSeq = 0
local started = false

local function userKey(player)
	return player and player.UserId or nil
end

local function userLabel(player)
	return tostring(player and player.UserId or "unknown")
end

local function now()
	return os.time()
end

local function safeElapsed(joinTime, lastSeen)
	local elapsed = (tonumber(joinTime) or 0) - (tonumber(lastSeen) or 0)
	if elapsed ~= elapsed or math.abs(elapsed) == math.huge then
		return 0
	end
	return math.max(math.floor(elapsed), 0)
end

local function hasPotentialOfflineProgress(profile, elapsed)
	if elapsed <= 0 then
		return false
	end
	local data = profile and profile.Data
	if type(data) ~= "table" then
		return false
	end
	if type(data.Pets) == "table" then
		for index, pet in ipairs(data.Pets) do
			if type(pet) == "table" then
				local petId = type(pet.petId) == "string" and pet.petId or DEFAULT_STARTER_PET_ID
				if index > 1
					or petId ~= DEFAULT_STARTER_PET_ID
					or (tonumber(pet.xp) or 0) > 0
					or (tonumber(pet.money) or 0) > 0 then
					return true
				end
			end
		end
	end
	if type(data.FeedPlacements) == "table" then
		for _, placement in ipairs(data.FeedPlacements) do
			if type(placement) == "table" then
				if placement.phase == "GrowingSeed" then
					return true
				end
				if type(placement.slots) == "table" or type(placement.queue) == "table" then
					return true
				end
			end
		end
	end
	return false
end

local function publish(player, session, phase)
	if session then
		session.phase = phase or session.phase or "pending"
	end
	RuntimeGuard.Run("OfflineProgressService.Publish", function()
		PlayerReplicaService.PublishJoinBackShowcase(player, session and {
			seq = session.seq,
			phase = session.phase,
		} or nil)
	end)
end

local function setPendingAttribute(player, pending)
	RuntimeGuard.Run("OfflineProgressService.SetPendingAttribute", function()
		player:SetAttribute(State.Player.OfflineProgressPending, pending == true)
	end)
end

local function sessionFor(player)
	local key = userKey(player)
	return key and sessions[key] or nil
end

function OfflineProgressService.RegisterSystem(name, applyCallback)
	if type(name) ~= "string" or name == "" or type(applyCallback) ~= "function" then
		return false
	end
	systems[name] = applyCallback
	return true
end

function OfflineProgressService.Begin(player, plot, profile)
	local key = userKey(player)
	if key == nil then
		return nil, "invalid-player"
	end

	OfflineProgressService.Clear(player)

	local lastSeen = tonumber(profile and profile.Data and profile.Data.LastSeen) or 0
	local joinTime = now()
	local elapsed = safeElapsed(joinTime, lastSeen)
	if not hasPotentialOfflineProgress(profile, elapsed) then
		setPendingAttribute(player, false)
		return nil, "not-eligible"
	end

	nextSeq += 1
	local session = {
		player = player,
		plot = plot,
		profile = profile,
		lastSeen = lastSeen,
		joinTime = joinTime,
		seq = nextSeq,
		phase = "pending",
		applied = false,
		applying = false,
		appliedSeq = nil,
		systemApplied = {},
		showcaseStarted = false,
		timeoutScheduled = false,
	}
	sessions[key] = session
	setPendingAttribute(player, true)
	return session, "pending"
end

function OfflineProgressService.Publish(player)
	local session = sessionFor(player)
	if session then
		publish(player, session, session.phase)
	else
		publish(player, nil)
	end
end

function OfflineProgressService.IsPending(player)
	local session = sessionFor(player)
	return session ~= nil and session.applied ~= true
end

function OfflineProgressService.ContextFor(player)
	return sessionFor(player)
end

local function scheduleFlashAckTimeout(player, session)
	if session.timeoutScheduled then
		return
	end
	session.timeoutScheduled = true
	task.delay(FLASH_ACK_TIMEOUT_SECONDS, function()
		RuntimeGuard.Run("OfflineProgressService.FlashAckTimeout." .. userLabel(player), function()
			local current = sessionFor(player)
			if current ~= session or session.applied == true or session.showcaseStarted ~= true then
				return
			end
			OfflineProgressService.ApplyPending(player, "timeout")
		end)
	end)
end

function OfflineProgressService.MarkShowcaseStarted(player, seq)
	local session = sessionFor(player)
	if not session or session.applied == true then
		return false, "not-pending"
	end
	if tonumber(seq) ~= session.seq then
		return false, "stale-seq"
	end
	session.showcaseStarted = true
	publish(player, session, "started")
	scheduleFlashAckTimeout(player, session)
	return true, "ok"
end

function OfflineProgressService.ApplyPending(player, reason)
	local key = userKey(player)
	local session = key and sessions[key] or nil
	if not session then
		setPendingAttribute(player, false)
		return true, "not-pending"
	end
	if session.applied == true then
		return true, "already-applied"
	end
	if session.applying == true then
		return false, "busy"
	end

	session.applying = true
	local context = {
		player = player,
		plot = session.plot,
		profile = session.profile,
		lastSeen = session.lastSeen,
		joinTime = session.joinTime,
		applyTime = now(),
		reason = reason or "manual",
		seq = session.seq,
	}

	for name, applyCallback in pairs(systems) do
		if session.systemApplied[name] ~= true then
			local ok, appliedOrCode = RuntimeGuard.Run("OfflineProgressService.ApplySystem." .. tostring(name), applyCallback, context)
			if ok ~= true or appliedOrCode == false then
				session.applying = false
				warn(string.format(
					"[OfflineProgressService] Failed applying offline system %s for user %s: %s",
					tostring(name),
					userLabel(player),
					tostring(appliedOrCode)
				))
				return false, tostring(appliedOrCode or "system-failed")
			end
			session.systemApplied[name] = true
		end
	end

	if session.profile and session.profile.Data then
		session.profile.Data.LastSeen = now()
	end
	session.applied = true
	session.appliedSeq = session.seq
	session.applying = false
	setPendingAttribute(player, false)
	publish(player, session, "applied")
	return true, "applied"
end

function OfflineProgressService.ApplyPendingBeforeSnapshot(player)
	if not OfflineProgressService.IsPending(player) then
		return true, "not-pending"
	end
	return OfflineProgressService.ApplyPending(player, "snapshot")
end

function OfflineProgressService.MarkClientComplete(player, seq)
	local session = sessionFor(player)
	if not session then
		publish(player, nil)
		return true, "not-pending"
	end
	if tonumber(seq) ~= session.seq then
		return false, "stale-seq"
	end
	if session.showcaseStarted ~= true then
		return false, "not-started"
	end
	if session.applied ~= true then
		local ok, code = OfflineProgressService.ApplyPending(player, "client-complete")
		if not ok then
			return false, code
		end
	end
	publish(player, session, "complete")
	OfflineProgressService.Clear(player)
	return true, "ok"
end

function OfflineProgressService.Clear(player)
	local key = userKey(player)
	if key == nil then
		return
	end
	sessions[key] = nil
	setPendingAttribute(player, false)
	publish(player, nil)
end

function OfflineProgressService.Start()
	if started then
		return
	end
	started = true

	local requestRemote = Remotes.get(Remotes.Names.JoinBackShowcaseRequest)
	RuntimeGuard.Connect(requestRemote.OnServerEvent, "OfflineProgressService.JoinBackShowcaseRequest", function(player, action, seq)
		if action == "showcaseStarted" then
			OfflineProgressService.MarkShowcaseStarted(player, seq)
		elseif action == "flashComplete" then
			local session = sessionFor(player)
			if session and tonumber(seq) == session.seq and session.showcaseStarted == true then
				OfflineProgressService.ApplyPending(player, "flash")
			end
		elseif action == "clientComplete" then
			OfflineProgressService.MarkClientComplete(player, seq)
		end
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "OfflineProgressService.PlayerRemoving", function(player)
		if OfflineProgressService.IsPending(player) then
			OfflineProgressService.ApplyPending(player, "teardown")
		end
		OfflineProgressService.Clear(player)
	end)
end

return OfflineProgressService
