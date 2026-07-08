-- Server-only control plane for global live events.
--
-- DataStore (LiveEvents_v1 / GlobalState) is the durable source of truth and is
-- written exclusively through UpdateAsync with pure, non-yielding transforms.
-- MessagingService (topic LiveEvents_v1) is a best-effort fast path carrying
-- compact revision-gated deltas. Every server reconciles from the DataStore on
-- startup and on a jittered poll, so missed messages self-heal.
--
-- There is intentionally no client surface: no remotes, no admin UI, no player
-- allowlist. Commands run from the live Developer Console server command bar,
-- which Roblox restricts to users with edit permission on the place:
--
--   local LiveEvents = require(game.ServerScriptService.Server.LiveEventCommandService)
--   LiveEvents.StartGlobalEvent("Alien", { durationSeconds = 120, commandId = "alien-test-1" })
--   LiveEvents.ListGlobalEvents()
--   LiveEvents.StopGlobalEvent(instanceId)
--   LiveEvents.StopGlobalEventsByEventId("Alien")
--   LiveEvents.StopGlobalEventsByLayer("Chaos")
--   LiveEvents.StopAllGlobalEvents()
--   LiveEvents.SendGlobalMessage("We are coming...", { preset = "Alien" })
--   LiveEvents.ClearGlobalMessages()
--   LiveEvents.SetAdminPartyPad(true)
--   LiveEvents.DropAdminCrate("UFOCrate")   -- also InfernoCrate | SaturnCrate
--   LiveEvents.SetAdminPartyPad(false)
--   LiveEvents.SetAdminLuck(5, 1800)        -- x5 admin luck for 30 min, all servers
--   LiveEvents.StopAdminLuck()
--   LiveEvents.GetAdminLuck()
--   LiveEvents.ReconcileNow()
--
-- Command writes fail closed: if the DataStore write does not succeed, nothing
-- starts locally and nothing is published.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local AdminLuckService = require(Server:WaitForChild("AdminLuckService"))
local GameEventService = require(Server:WaitForChild("GameEventService"))
local RollService = require(Server:WaitForChild("RollService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AdminMessagePresets = require(Shared:WaitForChild("AdminMessagePresets"))
local AdminPanelConfig = require(Shared:WaitForChild("AdminPanelConfig"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local RollChances = require(Shared:WaitForChild("RollChances"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local LiveEventCommandService = {}

local STORE_NAME = "LiveEvents_v1"
local STORE_KEY = "GlobalState"
local TOPIC = "LiveEvents_v1"
local EXTERNAL_SOURCE_KEY = "LiveEvents"
local STATE_VERSION = 1
local PAYLOAD_VERSION = 1

-- Only Chaos-layer events may be started globally; weather stays schedule-driven.
local ALLOWED_GLOBAL_LAYERS = {
	[GameEvents.Layers.Chaos] = true,
}

-- Absolute ceiling regardless of per-event config (fat-finger protection).
local MAX_EVENT_DURATION_SECONDS = 72 * 3600
local MAX_OPERATOR_NOTE_LENGTH = 120

local MAX_PROCESSED_COMMANDS = 64
local MAX_AUDIT_ENTRIES = 64

local RECONCILE_BASE_SECONDS = 20
local RECONCILE_JITTER_SECONDS = 10
-- Same-key writes are throttled experience-wide at 6 seconds; keep a margin.
local WRITE_MIN_INTERVAL_SECONDS = 6.5
local WRITE_ATTEMPTS = 3
local WRITE_RETRY_BASE_SECONDS = 2
local BUDGET_WAIT_STEP_SECONDS = 0.5
local BUDGET_WAIT_TIMEOUT_SECONDS = 10
-- Expired records are pruned from durable state during command writes only;
-- reconciles just ignore them.
local EXPIRED_PRUNE_GRACE_SECONDS = 120

-- Global admin messages (HUD AdminText). durationSeconds is the receivable
-- window (late joiners within it still see the message); on-screen display
-- time is client-side (AdminMessagePresets.DisplaySeconds).
local MAX_GLOBAL_MESSAGES = 8
local DEFAULT_MESSAGE_SECONDS = 30
local MAX_MESSAGE_SECONDS = 300
-- Byte cap keeps the full message delta safely under the ~1KB payload limit.
local MAX_MESSAGE_TEXT_BYTES = 180
-- Replicated children outlive endsAt by this buffer so a message shown right
-- before expiry still finishes its client display before removal.
local MESSAGE_REMOVE_BUFFER_SECONDS = 15

local rng = Random.new()

local started = false
local dataStore = nil
local getOptions = nil
local subscription = nil
local localRevision = 0
local localActive = {}
local localMessages = {}
local messagesFolder = nil
local commandBusy = false
local lastWriteClock = -math.huge
local reconcilePending = false
local reconcileFailureStreak = 0

local function serverNow()
	return Workspace:GetServerTimeNow()
end

local function finiteNumber(value)
	local numberValue = tonumber(value)
	if numberValue == nil or numberValue ~= numberValue or math.abs(numberValue) == math.huge then
		return nil
	end
	return numberValue
end

local function copyRecord(record)
	if type(record) ~= "table" then
		return nil
	end
	local copy = {}
	for key, value in pairs(record) do
		copy[key] = value
	end
	return copy
end

local function freshState()
	return {
		version = STATE_VERSION,
		revision = 0,
		updatedAt = 0,
		active = {},
		messages = {},
		adminParty = { padActive = false },
		adminLuck = { multiplier = 1, startsAt = 0, endsAt = 0 },
		processedCommands = {},
		audit = {},
	}
end

-- Pure (runs inside UpdateAsync transforms). Inactive is canonically
-- { multiplier = 1, startsAt = 0, endsAt = 0 }; anything malformed collapses
-- to inactive rather than poisoning future rewrites.
local function sanitizeAdminLuck(record)
	local inactive = { multiplier = 1, startsAt = 0, endsAt = 0 }
	if type(record) ~= "table" then
		return inactive
	end
	local multiplier = finiteNumber(record.multiplier)
	local startsAt = finiteNumber(record.startsAt)
	local endsAt = finiteNumber(record.endsAt)
	if not multiplier or multiplier <= 1 or not startsAt or not endsAt or endsAt <= startsAt then
		return inactive
	end
	return {
		multiplier = multiplier,
		startsAt = startsAt,
		endsAt = math.min(endsAt, startsAt + MAX_EVENT_DURATION_SECONDS),
		commandId = type(record.commandId) == "string" and record.commandId or nil,
	}
end

local function sanitizeRecord(record)
	if type(record) ~= "table" then
		return nil
	end
	if type(record.instanceId) ~= "string" or record.instanceId == "" then
		return nil
	end
	if type(record.eventId) ~= "string" or record.eventId == "" then
		return nil
	end
	if type(record.layer) ~= "string" or record.layer == "" then
		return nil
	end
	local startsAt = finiteNumber(record.startsAt)
	local endsAt = finiteNumber(record.endsAt)
	if not startsAt or not endsAt or endsAt <= startsAt then
		return nil
	end
	-- Whitelist known fields (hostile extra fields in durable state could poison
	-- every future rewrite) and clamp duration so a corrupt endsAt can always be
	-- pruned once it lapses.
	return {
		instanceId = record.instanceId,
		eventId = record.eventId,
		layer = record.layer,
		source = type(record.source) == "string" and record.source or nil,
		startsAt = startsAt,
		endsAt = math.min(endsAt, startsAt + MAX_EVENT_DURATION_SECONDS),
		priority = finiteNumber(record.priority),
		displayPriority = finiteNumber(record.displayPriority),
		displayFrame = type(record.displayFrame) == "string" and record.displayFrame or nil,
		commandId = type(record.commandId) == "string" and record.commandId or nil,
		createdAt = finiteNumber(record.createdAt),
		sourceJobId = type(record.sourceJobId) == "string" and record.sourceJobId or nil,
		placeId = finiteNumber(record.placeId),
	}
end

local function sanitizeMessageRecord(record)
	if type(record) ~= "table" then
		return nil
	end
	if type(record.messageId) ~= "string" or record.messageId == "" then
		return nil
	end
	if not AdminMessagePresets.Get(record.presetId) then
		return nil
	end
	if type(record.text) ~= "string" or record.text == "" or #record.text > MAX_MESSAGE_TEXT_BYTES or utf8.len(record.text) == nil then
		return nil
	end
	local startsAt = finiteNumber(record.startsAt)
	local endsAt = finiteNumber(record.endsAt)
	if not startsAt or not endsAt or endsAt <= startsAt then
		return nil
	end
	return {
		messageId = record.messageId,
		presetId = record.presetId,
		text = record.text,
		startsAt = startsAt,
		endsAt = math.min(endsAt, startsAt + MAX_MESSAGE_SECONDS),
		commandId = type(record.commandId) == "string" and record.commandId or nil,
		createdAt = finiteNumber(record.createdAt),
		sourceJobId = type(record.sourceJobId) == "string" and record.sourceJobId or nil,
		placeId = finiteNumber(record.placeId),
	}
end

local function sanitizeAuditEntry(entry)
	if type(entry) ~= "table" then
		return nil
	end
	local clean = {}
	for key, value in pairs(entry) do
		if type(key) == "string" then
			local valueType = type(value)
			if valueType == "string" or valueType == "number" or valueType == "boolean" then
				clean[key] = value
			elseif valueType == "table" then
				-- Keep bounded string arrays (e.g. stopped instanceIds).
				local list = {}
				for _, item in ipairs(value) do
					if type(item) ~= "string" or #list >= 32 then
						list = nil
						break
					end
					list[#list + 1] = item
				end
				if list then
					clean[key] = list
				end
			end
		end
	end
	return clean
end

-- Pure: safe to run inside UpdateAsync transforms. Never yields.
local function sanitizeState(raw)
	if type(raw) ~= "table" then
		return freshState()
	end
	local version = finiteNumber(raw.version)
	if version == nil or version < STATE_VERSION then
		return freshState()
	end
	if version > STATE_VERSION then
		return nil, "state-version-newer"
	end

	local state = freshState()
	state.revision = math.max(math.floor(finiteNumber(raw.revision) or 0), 0)
	state.updatedAt = finiteNumber(raw.updatedAt) or 0
	if type(raw.active) == "table" then
		for instanceId, record in pairs(raw.active) do
			local sanitized = sanitizeRecord(record)
			if type(instanceId) == "string" and sanitized and sanitized.instanceId == instanceId then
				state.active[instanceId] = sanitized
			end
		end
	end
	if type(raw.messages) == "table" then
		for messageId, record in pairs(raw.messages) do
			local sanitized = sanitizeMessageRecord(record)
			if type(messageId) == "string" and sanitized and sanitized.messageId == messageId then
				state.messages[messageId] = sanitized
			end
		end
	end
	if type(raw.adminParty) == "table" then
		state.adminParty.padActive = raw.adminParty.padActive == true
	end
	state.adminLuck = sanitizeAdminLuck(raw.adminLuck)
	-- Read only the newest capped window so a corrupt/bloated durable state
	-- cannot stall transforms (which may run multiple times per write).
	if type(raw.processedCommands) == "table" then
		local rawCommands = raw.processedCommands
		for index = math.max(#rawCommands - MAX_PROCESSED_COMMANDS + 1, 1), #rawCommands do
			local entry = rawCommands[index]
			if type(entry) == "table" and type(entry.id) == "string" and type(entry.hash) == "string" then
				state.processedCommands[#state.processedCommands + 1] = {
					id = entry.id,
					hash = entry.hash,
					revision = finiteNumber(entry.revision) or 0,
					at = finiteNumber(entry.at) or 0,
				}
			end
		end
	end
	if type(raw.audit) == "table" then
		local rawAudit = raw.audit
		for index = math.max(#rawAudit - MAX_AUDIT_ENTRIES + 1, 1), #rawAudit do
			local entry = sanitizeAuditEntry(rawAudit[index])
			if entry then
				state.audit[#state.audit + 1] = entry
			end
		end
	end
	return state
end

local function findProcessedCommand(state, commandId)
	for _, entry in ipairs(state.processedCommands) do
		if entry.id == commandId then
			return entry
		end
	end
	return nil
end

local function appendCapped(list, entry, maxEntries)
	list[#list + 1] = entry
	while #list > maxEntries do
		table.remove(list, 1)
	end
end

local function pruneExpired(state, now)
	for instanceId, record in pairs(state.active) do
		if (finiteNumber(record.endsAt) or 0) + EXPIRED_PRUNE_GRACE_SECONDS <= now then
			state.active[instanceId] = nil
		end
	end
	for messageId, record in pairs(state.messages) do
		if (finiteNumber(record.endsAt) or 0) + EXPIRED_PRUNE_GRACE_SECONDS <= now then
			state.messages[messageId] = nil
		end
	end
end

local function compareRecords(left, right)
	local leftPriority = finiteNumber(left.priority) or 0
	local rightPriority = finiteNumber(right.priority) or 0
	if leftPriority ~= rightPriority then
		return leftPriority > rightPriority
	end
	local leftStartsAt = finiteNumber(left.startsAt) or 0
	local rightStartsAt = finiteNumber(right.startsAt) or 0
	if leftStartsAt ~= rightStartsAt then
		return leftStartsAt < rightStartsAt
	end
	return tostring(left.instanceId) < tostring(right.instanceId)
end

local function layerMaxActive(layer)
	local layerConfig = GameEvents.LayerConfigs[layer] or {}
	local maxActive = math.max(math.floor(finiteNumber(layerConfig.maxActive) or 1), 0)
	if layerConfig.stacking == "Single" then
		maxActive = math.min(maxActive, 1)
	end
	return maxActive
end

local function pushToGameEventService()
	local now = serverNow()
	local records = {}
	for _, record in pairs(localActive) do
		if (finiteNumber(record.endsAt) or 0) > now then
			records[#records + 1] = record
		end
	end
	RuntimeGuard.Run("LiveEventCommandService.PushExternalRecords", function()
		GameEventService.SetExternalManualRecords(EXTERNAL_SOURCE_KEY, records)
	end)
end

local function getMessagesFolder()
	if not (messagesFolder and messagesFolder.Parent) then
		messagesFolder = ReplicatedStorage:FindFirstChild(AdminMessagePresets.FolderName)
	end
	if not messagesFolder then
		messagesFolder = Instance.new("Folder")
		messagesFolder.Name = AdminMessagePresets.FolderName
		messagesFolder.Parent = ReplicatedStorage
	end
	return messagesFolder
end

-- Mirrors localMessages into the replicated AdminMessages folder for clients.
-- Idempotent; also serves as the expiry sweep (children outlive endsAt by the
-- remove buffer so in-flight client displays are never cut short by expiry --
-- only ClearGlobalMessages removes a message early).
local function publishAdminMessages()
	local folder = getMessagesFolder()
	local now = serverNow()
	local wanted = {}
	for messageId, record in pairs(localMessages) do
		if record.endsAt + MESSAGE_REMOVE_BUFFER_SECONDS > now then
			wanted[messageId] = record
		end
	end
	for _, child in ipairs(folder:GetChildren()) do
		if not wanted[child.Name] then
			child:Destroy()
		end
	end
	for messageId, record in pairs(wanted) do
		if not folder:FindFirstChild(messageId) then
			local child = Instance.new("Folder")
			child.Name = messageId
			child:SetAttribute(State.AdminMessage.PresetId, record.presetId)
			child:SetAttribute(State.AdminMessage.Text, record.text)
			child:SetAttribute(State.AdminMessage.StartsAt, record.startsAt)
			child:SetAttribute(State.AdminMessage.EndsAt, record.endsAt)
			child.Parent = folder
		end
	end
end

local localAdminPadActive = false
local localAdminLuck = { multiplier = 1, startsAt = 0, endsAt = 0 }

local function applyAdminPartyPad(padActive)
	localAdminPadActive = padActive == true
	RuntimeGuard.Run("LiveEventCommandService.ApplyAdminPartyPad", function()
		RollService.SetAdminPartyPadActive(localAdminPadActive)
	end)
end

local function applyAdminLuck(record)
	localAdminLuck = sanitizeAdminLuck(record)
	RuntimeGuard.Run("LiveEventCommandService.ApplyAdminLuck", function()
		AdminLuckService.Apply(localAdminLuck.multiplier, localAdminLuck.endsAt)
	end)
end

local function applyState(state, force)
	if not state then
		return false
	end
	if not force and state.revision <= localRevision then
		return false
	end
	localRevision = state.revision
	localActive = {}
	for instanceId, record in pairs(state.active) do
		localActive[instanceId] = record
	end
	localMessages = {}
	for messageId, record in pairs(state.messages or {}) do
		localMessages[messageId] = record
	end
	pushToGameEventService()
	publishAdminMessages()
	applyAdminPartyPad(type(state.adminParty) == "table" and state.adminParty.padActive)
	applyAdminLuck(state.adminLuck)
	return true
end

local function scheduleReconcile(reason)
	if reconcilePending then
		return
	end
	reconcilePending = true
	RuntimeGuard.Spawn("LiveEventCommandService.GapReconcile", function()
		task.wait(1)
		reconcilePending = false
		LiveEventCommandService.ReconcileNow(reason)
	end)
end

local function onMessage(message)
	local data = type(message) == "table" and message.Data or nil
	if type(data) ~= "table" then
		return
	end
	if finiteNumber(data.v) ~= PAYLOAD_VERSION then
		return
	end
	local messageRevision = finiteNumber(data.revision)
	if not messageRevision or messageRevision <= localRevision then
		return
	end
	local hadGap = messageRevision > localRevision + 1

	if data.action == "start" then
		local record = sanitizeRecord(data.record)
		if not record then
			scheduleReconcile("invalid-start-delta")
			return
		end
		if type(data.removedInstanceIds) == "table" then
			for _, instanceId in ipairs(data.removedInstanceIds) do
				if type(instanceId) == "string" then
					localActive[instanceId] = nil
				end
			end
		end
		localActive[record.instanceId] = record
	elseif data.action == "stop" then
		if type(data.instanceIds) ~= "table" then
			scheduleReconcile("invalid-stop-delta")
			return
		end
		for _, instanceId in ipairs(data.instanceIds) do
			if type(instanceId) == "string" then
				localActive[instanceId] = nil
			end
		end
	elseif data.action == "message" then
		local record = sanitizeMessageRecord(data.message)
		if not record then
			scheduleReconcile("invalid-message-delta")
			return
		end
		if type(data.removedMessageIds) == "table" then
			for _, messageId in ipairs(data.removedMessageIds) do
				if type(messageId) == "string" then
					localMessages[messageId] = nil
				end
			end
		end
		localMessages[record.messageId] = record
	elseif data.action == "clearMessages" then
		localMessages = {}
	elseif data.action == "adminParty" then
		applyAdminPartyPad(data.padActive == true)
	elseif data.action == "adminLuck" then
		-- Replace semantics; a stop travels as the canonical inactive record.
		if type(data.adminLuck) ~= "table" then
			scheduleReconcile("invalid-adminluck-delta")
			return
		end
		applyAdminLuck(data.adminLuck)
	elseif data.action == "adminDrop" then
		-- One-shot for players present right now: applied on delta receipt
		-- only, never replayed from reconcile. A server that misses this
		-- message skips the drop (drop again to cover it).
		if RollChances.GetAdminCrate(data.crateId) then
			RuntimeGuard.Run("LiveEventCommandService.ApplyAdminDrop", function()
				RollService.DropAdminCrate(data.crateId)
			end)
		end
	else
		scheduleReconcile("unknown-delta-action")
		return
	end

	localRevision = messageRevision
	pushToGameEventService()
	publishAdminMessages()
	if hadGap then
		scheduleReconcile("revision-gap")
	end
end

local function publishDelta(payload)
	local ok, err = pcall(function()
		MessagingService:PublishAsync(TOPIC, payload)
	end)
	if not ok then
		warn("[LiveEventCommandService] PublishAsync failed (reconcile polls will cover): " .. tostring(err))
	end
	return ok
end

local function waitForWriteBudget()
	local deadline = os.clock() + BUDGET_WAIT_TIMEOUT_SECONDS
	while DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) <= 0 do
		if os.clock() >= deadline then
			return false
		end
		task.wait(BUDGET_WAIT_STEP_SECONDS)
	end
	return true
end

local function waitForWriteSpacing()
	local elapsed = os.clock() - lastWriteClock
	if elapsed < WRITE_MIN_INTERVAL_SECONDS then
		task.wait(WRITE_MIN_INTERVAL_SECONDS - elapsed)
	end
end

-- Serializes all command writes through one UpdateAsync pipeline. `mutate` must
-- be pure and non-yielding: it receives sanitized state and returns
-- (true, delta) after mutating state in place, or (false, code) to reject.
-- Everything variable (GUIDs, hashes, timestamps, records) is precomputed by
-- the caller before this function runs. `prepare` (optional) runs outside the
-- transform right before each write attempt with the commit-time clock, so
-- callers can restamp record times after waiting in the write queue.
local function runCommandWrite(commandId, commandHash, auditEntry, mutate, prepare)
	if not (started and dataStore) then
		return false, "datastore-unavailable"
	end

	while commandBusy do
		task.wait(0.1)
	end
	commandBusy = true

	local outcome = nil
	local lastError = nil
	for attempt = 1, WRITE_ATTEMPTS do
		waitForWriteSpacing()
		if not waitForWriteBudget() then
			lastError = "datastore-budget-exhausted"
		else
			local writeNow = serverNow()
			if prepare then
				-- pcall so a throwing prepare can never leak the commandBusy lock
				-- and deadlock every subsequent command.
				local prepared, prepareError = pcall(prepare, writeNow)
				if not prepared then
					lastError = "prepare-failed: " .. tostring(prepareError)
					break
				end
			end
			local ok, err = pcall(function()
				dataStore:UpdateAsync(STORE_KEY, function(raw)
					outcome = nil
					local state, stateCode = sanitizeState(raw)
					if not state then
						outcome = { status = stateCode or "state-invalid" }
						return nil
					end
					local processed = findProcessedCommand(state, commandId)
					if processed then
						if processed.hash == commandHash then
							outcome = { status = "idempotent", state = state }
						else
							outcome = { status = "command-conflict" }
						end
						return nil
					end
					pruneExpired(state, writeNow)
					local mutated, deltaOrCode = mutate(state)
					if not mutated then
						outcome = { status = deltaOrCode or "rejected" }
						return nil
					end
					state.revision += 1
					state.updatedAt = writeNow
					appendCapped(state.processedCommands, {
						id = commandId,
						hash = commandHash,
						revision = state.revision,
						at = writeNow,
					}, MAX_PROCESSED_COMMANDS)
					appendCapped(state.audit, auditEntry, MAX_AUDIT_ENTRIES)
					outcome = { status = "written", state = state, delta = deltaOrCode }
					return state
				end)
			end)
			lastWriteClock = os.clock()
			if ok then
				break
			end
			outcome = nil
			lastError = tostring(err)
		end
		if attempt < WRITE_ATTEMPTS then
			task.wait(WRITE_RETRY_BASE_SECONDS * attempt)
		end
	end
	commandBusy = false

	if not outcome then
		warn("[LiveEventCommandService] Command write failed closed (" .. tostring(commandId) .. "): " .. tostring(lastError))
		if lastError == "datastore-budget-exhausted" then
			return false, lastError
		end
		return false, "datastore-write-failed"
	end
	if outcome.status == "idempotent" then
		applyState(outcome.state, false)
		return true, "idempotent"
	end
	if outcome.status ~= "written" then
		return false, outcome.status
	end

	-- Revision-aware, never force: while this thread was suspended in
	-- UpdateAsync, a delta for a LATER revision from another server may already
	-- have advanced local state; applying our older snapshot over it would
	-- regress. In that overtake case the delta's gap detection has already
	-- scheduled a reconcile.
	applyState(outcome.state, false)
	if outcome.delta then
		outcome.delta.v = PAYLOAD_VERSION
		outcome.delta.revision = outcome.state.revision
		outcome.delta.commandId = commandId
		publishDelta(outcome.delta)
	end
	return true, outcome.state
end

local function normalizedCommandId(options)
	local commandId = options.commandId
	if commandId ~= nil then
		-- 64-char cap keeps start deltas (which carry the id twice) safely under
		-- the ~1KB MessagingService payload limit.
		if type(commandId) ~= "string" or commandId == "" or #commandId > 64 or utf8.len(commandId) == nil then
			return nil
		end
		return commandId
	end
	return HttpService:GenerateGUID(false)
end

local function normalizedOperatorNote(options)
	local note = options.operatorNote
	if note == nil then
		return nil, true
	end
	if type(note) ~= "string" then
		return nil, false
	end
	-- DataStores reject non-UTF-8 strings, and a byte-based truncation can split
	-- a multi-byte codepoint; validate and truncate on codepoint boundaries.
	local length = utf8.len(note)
	if length == nil then
		return nil, false
	end
	if length > MAX_OPERATOR_NOTE_LENGTH then
		note = string.sub(note, 1, utf8.offset(note, MAX_OPERATOR_NOTE_LENGTH + 1) - 1)
	end
	return note, true
end

local function baseAuditEntry(commandId, action, note)
	return {
		commandId = commandId,
		action = action,
		createdAt = os.time(),
		sourceJobId = game.JobId,
		placeId = game.PlaceId,
		note = note,
	}
end

function LiveEventCommandService.StartGlobalEvent(eventId, options)
	if type(eventId) ~= "string" or eventId == "" then
		return false, "invalid-event"
	end
	local config = GameEvents.GetEvent(eventId)
	if not config then
		return false, "unknown-event"
	end
	local layer = config.layer
	if type(layer) ~= "string" or not GameEvents.LayerConfigs[layer] then
		return false, "invalid-layer"
	end
	if not ALLOWED_GLOBAL_LAYERS[layer] then
		return false, "layer-not-allowed"
	end
	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		return false, "invalid-options"
	end

	local durationSeconds
	if options.durationSeconds == nil then
		durationSeconds = GameEvents.TotalDuration(config)
	else
		durationSeconds = finiteNumber(options.durationSeconds)
	end
	if not durationSeconds or durationSeconds <= 0 then
		return false, "invalid-duration"
	end
	local durationCap = math.min(
		finiteNumber(config.maxGlobalDurationSeconds) or MAX_EVENT_DURATION_SECONDS,
		MAX_EVENT_DURATION_SECONDS
	)
	if durationSeconds > durationCap then
		return false, "duration-too-long", durationCap
	end

	local commandId = normalizedCommandId(options)
	if not commandId then
		return false, "invalid-command-id"
	end
	local note, noteOk = normalizedOperatorNote(options)
	if not noteOk then
		return false, "invalid-options"
	end

	-- startsAt/endsAt are restamped at commit time (see prepare below) so time
	-- spent waiting in the write queue does not eat into the event duration.
	local startsAt = serverNow()
	local record = {
		instanceId = string.format("Global_%s_%s_%s", layer, eventId, HttpService:GenerateGUID(false)),
		eventId = eventId,
		layer = layer,
		source = GameEvents.Sources.AdminCommand,
		startsAt = startsAt,
		endsAt = startsAt + durationSeconds,
		priority = finiteNumber(config.priority) or 0,
		displayPriority = finiteNumber(config.displayPriority) or 0,
		displayFrame = config.displayFrame or eventId,
		commandId = commandId,
		createdAt = os.time(),
		sourceJobId = game.JobId,
		placeId = game.PlaceId,
	}
	local commandHash = table.concat({ "start", eventId, tostring(durationSeconds) }, ":")
	local auditEntry = baseAuditEntry(commandId, "start", note)
	auditEntry.eventId = eventId
	auditEntry.instanceId = record.instanceId
	auditEntry.durationSeconds = durationSeconds

	local maxActive = layerMaxActive(layer)
	local ok, result = runCommandWrite(commandId, commandHash, auditEntry, function(state)
		local removedInstanceIds = {}
		-- Same event ID is single-instance globally: replace atomically.
		for instanceId, activeRecord in pairs(state.active) do
			if activeRecord.eventId == eventId then
				state.active[instanceId] = nil
				removedInstanceIds[#removedInstanceIds + 1] = instanceId
			end
		end

		-- Respect layer caps: reject or displace strictly by priority.
		state.active[record.instanceId] = record
		local layerRecords = {}
		for _, activeRecord in pairs(state.active) do
			if activeRecord.layer == layer then
				layerRecords[#layerRecords + 1] = activeRecord
			end
		end
		if #layerRecords > maxActive then
			table.sort(layerRecords, compareRecords)
			for index = maxActive + 1, #layerRecords do
				local displaced = layerRecords[index]
				if displaced.instanceId == record.instanceId then
					state.active[record.instanceId] = nil
					return false, "layer-full"
				end
				state.active[displaced.instanceId] = nil
				removedInstanceIds[#removedInstanceIds + 1] = displaced.instanceId
			end
		end

		return true, {
			action = "start",
			record = record,
			removedInstanceIds = removedInstanceIds,
		}
	end, function(commitNow)
		record.startsAt = commitNow
		record.endsAt = commitNow + durationSeconds
	end)

	if not ok then
		return false, result
	end
	if result == "idempotent" then
		-- A previous invocation of this commandId already wrote the record; the
		-- newly generated record above was not committed. Return the durable one
		-- if it is still running, otherwise make the no-op unmistakable: the
		-- command happened before and its event has since stopped/expired. Use a
		-- fresh commandId to start a new run.
		local idempotentNow = serverNow()
		for _, activeRecord in pairs(localActive) do
			if activeRecord.commandId == commandId
				and (finiteNumber(activeRecord.endsAt) or 0) > idempotentNow then
				return true, copyRecord(activeRecord)
			end
		end
		return true, "already-processed-not-active"
	end
	print(string.format(
		"[LiveEventCommandService] Started global %s.%s (%s, %ds, command %s)",
		layer,
		eventId,
		record.instanceId,
		math.floor(durationSeconds),
		commandId
	))
	return true, copyRecord(record)
end

local function runStopCommand(action, commandHash, auditExtras, matcher)
	local commandId = HttpService:GenerateGUID(false)
	local auditEntry = baseAuditEntry(commandId, action, nil)
	for key, value in pairs(auditExtras) do
		auditEntry[key] = value
	end

	local stoppedInstanceIds = nil
	local ok, result = runCommandWrite(commandId, commandHash, auditEntry, function(state)
		local removed = {}
		for instanceId, record in pairs(state.active) do
			if matcher(instanceId, record) then
				state.active[instanceId] = nil
				removed[#removed + 1] = instanceId
			end
		end
		if #removed == 0 then
			return false, "no-match"
		end
		table.sort(removed)
		stoppedInstanceIds = removed
		auditEntry.instanceIds = removed
		return true, {
			action = "stop",
			instanceIds = removed,
		}
	end)

	if not ok then
		if result == "no-match" then
			return true, 0
		end
		return false, result
	end
	if type(stoppedInstanceIds) ~= "table" then
		return true, 0
	end
	print(string.format(
		"[LiveEventCommandService] Stopped %d global event(s) via %s",
		#stoppedInstanceIds,
		action
	))
	return true, #stoppedInstanceIds, stoppedInstanceIds
end

function LiveEventCommandService.StopGlobalEvent(instanceId)
	if type(instanceId) ~= "string" or instanceId == "" then
		return false, "invalid-instance"
	end
	return runStopCommand("stop-instance", "stop:" .. instanceId, { instanceId = instanceId }, function(activeInstanceId)
		return activeInstanceId == instanceId
	end)
end

function LiveEventCommandService.StopGlobalEventsByEventId(eventId)
	if type(eventId) ~= "string" or eventId == "" then
		return false, "invalid-event"
	end
	return runStopCommand("stop-event", "stopEvent:" .. eventId, { eventId = eventId }, function(_, record)
		return record.eventId == eventId
	end)
end

function LiveEventCommandService.StopGlobalEventsByLayer(layer)
	if type(layer) ~= "string" or not GameEvents.LayerConfigs[layer] then
		return false, "invalid-layer"
	end
	return runStopCommand("stop-layer", "stopLayer:" .. layer, { layer = layer }, function(_, record)
		return record.layer == layer
	end)
end

function LiveEventCommandService.StopAllGlobalEvents()
	return runStopCommand("stop-all", "stopAll", {}, function()
		return true
	end)
end

function LiveEventCommandService.SendGlobalMessage(text, options)
	if type(text) ~= "string" then
		return false, "invalid-text"
	end
	text = string.match(text, "^%s*(.-)%s*$")
	if text == "" or utf8.len(text) == nil then
		return false, "invalid-text"
	end
	if #text > MAX_MESSAGE_TEXT_BYTES then
		return false, "text-too-long", MAX_MESSAGE_TEXT_BYTES
	end
	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		return false, "invalid-options"
	end

	local presetId = options.preset
	if presetId == nil then
		presetId = AdminMessagePresets.Ids.Owner
	end
	local preset = AdminMessagePresets.Get(presetId)
	if not preset then
		return false, "unknown-preset"
	end

	local durationSeconds
	if options.durationSeconds == nil then
		durationSeconds = DEFAULT_MESSAGE_SECONDS
	else
		durationSeconds = finiteNumber(options.durationSeconds)
	end
	if not durationSeconds or durationSeconds <= 0 then
		return false, "invalid-duration"
	end
	if durationSeconds > MAX_MESSAGE_SECONDS then
		return false, "duration-too-long", MAX_MESSAGE_SECONDS
	end

	local commandId = normalizedCommandId(options)
	if not commandId then
		return false, "invalid-command-id"
	end
	local note, noteOk = normalizedOperatorNote(options)
	if not noteOk then
		return false, "invalid-options"
	end

	-- startsAt/endsAt are restamped at commit time (prepare below).
	local startsAt = serverNow()
	local record = {
		messageId = string.format("Msg_%s_%s", presetId, HttpService:GenerateGUID(false)),
		presetId = presetId,
		text = text,
		startsAt = startsAt,
		endsAt = startsAt + durationSeconds,
		commandId = commandId,
		createdAt = os.time(),
		sourceJobId = game.JobId,
		placeId = game.PlaceId,
	}
	local commandHash = table.concat({ "message", presetId, tostring(durationSeconds), text }, ":")
	local auditEntry = baseAuditEntry(commandId, "message", note)
	auditEntry.presetId = presetId
	auditEntry.messageId = record.messageId
	auditEntry.text = text

	local ok, result = runCommandWrite(commandId, commandHash, auditEntry, function(state)
		local removedMessageIds = {}
		state.messages[record.messageId] = record

		-- Cap durable messages; displace the oldest by startsAt.
		local messageRecords = {}
		for _, messageRecord in pairs(state.messages) do
			messageRecords[#messageRecords + 1] = messageRecord
		end
		if #messageRecords > MAX_GLOBAL_MESSAGES then
			table.sort(messageRecords, function(left, right)
				if left.startsAt ~= right.startsAt then
					return left.startsAt < right.startsAt
				end
				return tostring(left.messageId) < tostring(right.messageId)
			end)
			for index = 1, #messageRecords - MAX_GLOBAL_MESSAGES do
				local displaced = messageRecords[index]
				if displaced.messageId ~= record.messageId then
					state.messages[displaced.messageId] = nil
					removedMessageIds[#removedMessageIds + 1] = displaced.messageId
				end
			end
		end

		return true, {
			action = "message",
			message = record,
			removedMessageIds = removedMessageIds,
		}
	end, function(commitNow)
		record.startsAt = commitNow
		record.endsAt = commitNow + durationSeconds
	end)

	if not ok then
		return false, result
	end
	if result == "idempotent" then
		local idempotentNow = serverNow()
		for _, messageRecord in pairs(localMessages) do
			if messageRecord.commandId == commandId
				and (finiteNumber(messageRecord.endsAt) or 0) > idempotentNow then
				return true, copyRecord(messageRecord)
			end
		end
		return true, "already-processed-not-active"
	end
	print(string.format(
		"[LiveEventCommandService] Sent global message as %s (%s, %ds window, command %s)",
		presetId,
		record.messageId,
		math.floor(durationSeconds),
		commandId
	))
	return true, copyRecord(record)
end

function LiveEventCommandService.ClearGlobalMessages()
	local commandId = HttpService:GenerateGUID(false)
	local auditEntry = baseAuditEntry(commandId, "clear-messages", nil)

	local clearedCount = nil
	local ok, result = runCommandWrite(commandId, "clearMessages", auditEntry, function(state)
		local removed = 0
		for messageId in pairs(state.messages) do
			state.messages[messageId] = nil
			removed += 1
		end
		if removed == 0 then
			return false, "no-match"
		end
		clearedCount = removed
		auditEntry.clearedCount = removed
		return true, {
			action = "clearMessages",
		}
	end)

	if not ok then
		if result == "no-match" then
			return true, 0
		end
		return false, result
	end
	if type(clearedCount) ~= "number" then
		return true, 0
	end
	print(string.format("[LiveEventCommandService] Cleared %d global message(s)", clearedCount))
	return true, clearedCount
end

function LiveEventCommandService.ListGlobalMessages()
	local now = serverNow()
	local records = {}
	for _, record in pairs(localMessages) do
		if (finiteNumber(record.endsAt) or 0) > now then
			records[#records + 1] = copyRecord(record)
		end
	end
	table.sort(records, function(left, right)
		if left.startsAt ~= right.startsAt then
			return left.startsAt < right.startsAt
		end
		return tostring(left.messageId) < tostring(right.messageId)
	end)
	return records, localRevision
end

-- Toggles the admin party drop pad on every plot on every server (durable:
-- new servers reconcile the pad state at boot).
function LiveEventCommandService.SetAdminPartyPad(active, options)
	if type(active) ~= "boolean" then
		return false, "invalid-active"
	end
	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		return false, "invalid-options"
	end
	local commandId = normalizedCommandId(options)
	if not commandId then
		return false, "invalid-command-id"
	end
	local note, noteOk = normalizedOperatorNote(options)
	if not noteOk then
		return false, "invalid-options"
	end

	local auditEntry = baseAuditEntry(commandId, "admin-party-pad", note)
	auditEntry.padActive = active

	local ok, result = runCommandWrite(commandId, "adminPartyPad:" .. tostring(active), auditEntry, function(state)
		if state.adminParty.padActive == active then
			return false, "no-change"
		end
		state.adminParty.padActive = active
		return true, {
			action = "adminParty",
			padActive = active,
		}
	end)

	if not ok then
		if result == "no-change" then
			return true, "no-change"
		end
		return false, result
	end
	print(string.format("[LiveEventCommandService] Admin party pad %s globally", active and "ENABLED" or "DISABLED"))
	return true, active
end

-- Applies a global admin luck boost on every server (durable: booting servers
-- reconcile it). Additive on top of crate/player/server luck in RollChances.
-- Replace semantics: a new boost overwrites the running one from commit time.
-- Multipliers are whitelisted (AdminPanelConfig.AllowedLuckMultipliers).
function LiveEventCommandService.SetAdminLuck(multiplier, durationSeconds, options)
	multiplier = finiteNumber(multiplier)
	if not multiplier or not AdminPanelConfig.IsAllowedLuckMultiplier(multiplier) then
		return false, "invalid-multiplier"
	end
	durationSeconds = finiteNumber(durationSeconds)
	if not durationSeconds or durationSeconds <= 0 then
		return false, "invalid-duration"
	end
	if durationSeconds > MAX_EVENT_DURATION_SECONDS then
		return false, "duration-too-long", MAX_EVENT_DURATION_SECONDS
	end
	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		return false, "invalid-options"
	end
	local commandId = normalizedCommandId(options)
	if not commandId then
		return false, "invalid-command-id"
	end
	local note, noteOk = normalizedOperatorNote(options)
	if not noteOk then
		return false, "invalid-options"
	end

	-- startsAt/endsAt are restamped at commit time (prepare below).
	local startsAt = serverNow()
	local record = {
		multiplier = multiplier,
		startsAt = startsAt,
		endsAt = startsAt + durationSeconds,
		commandId = commandId,
	}
	local commandHash = table.concat({ "adminLuck", tostring(multiplier), tostring(durationSeconds) }, ":")
	local auditEntry = baseAuditEntry(commandId, "admin-luck", note)
	auditEntry.multiplier = multiplier
	auditEntry.durationSeconds = durationSeconds

	local ok, result = runCommandWrite(commandId, commandHash, auditEntry, function(state)
		state.adminLuck = {
			multiplier = record.multiplier,
			startsAt = record.startsAt,
			endsAt = record.endsAt,
			commandId = record.commandId,
		}
		return true, {
			action = "adminLuck",
			adminLuck = state.adminLuck,
		}
	end, function(commitNow)
		record.startsAt = commitNow
		record.endsAt = commitNow + durationSeconds
	end)

	if not ok then
		return false, result
	end
	if result == "idempotent" then
		local idempotentNow = serverNow()
		if localAdminLuck.commandId == commandId and (finiteNumber(localAdminLuck.endsAt) or 0) > idempotentNow then
			return true, copyRecord(localAdminLuck)
		end
		return true, "already-processed-not-active"
	end
	print(string.format(
		"[LiveEventCommandService] Admin luck x%d for %ds globally (command %s)",
		math.floor(multiplier),
		math.floor(durationSeconds),
		commandId
	))
	return true, copyRecord(record)
end

function LiveEventCommandService.StopAdminLuck(options)
	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		return false, "invalid-options"
	end
	local commandId = normalizedCommandId(options)
	if not commandId then
		return false, "invalid-command-id"
	end
	local note, noteOk = normalizedOperatorNote(options)
	if not noteOk then
		return false, "invalid-options"
	end

	local auditEntry = baseAuditEntry(commandId, "admin-luck-stop", note)

	local stopNow = serverNow()
	local ok, result = runCommandWrite(commandId, "adminLuckStop", auditEntry, function(state)
		local active = state.adminLuck
			and (finiteNumber(state.adminLuck.multiplier) or 1) > 1
			and (finiteNumber(state.adminLuck.endsAt) or 0) > stopNow
		if not active then
			return false, "no-change"
		end
		state.adminLuck = { multiplier = 1, startsAt = 0, endsAt = 0 }
		return true, {
			action = "adminLuck",
			adminLuck = state.adminLuck,
		}
	end, function(commitNow)
		stopNow = commitNow
	end)

	if not ok then
		if result == "no-change" then
			return true, "no-change"
		end
		return false, result
	end
	if result == "idempotent" then
		return true, "already-processed"
	end
	print("[LiveEventCommandService] Admin luck stopped globally")
	return true, "stopped"
end

function LiveEventCommandService.GetAdminLuck()
	local now = serverNow()
	if (finiteNumber(localAdminLuck.multiplier) or 1) > 1 and (finiteNumber(localAdminLuck.endsAt) or 0) > now then
		return copyRecord(localAdminLuck), localRevision
	end
	return nil, localRevision
end

-- Drops one admin crate (InfernoCrate/SaturnCrate/UFOCrate) on every eligible
-- player's admin pad, on every server. One-shot: players present right now.
function LiveEventCommandService.DropAdminCrate(crateId, options)
	local crate = RollChances.GetAdminCrate(crateId)
	if not crate then
		return false, "unknown-admin-crate"
	end
	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		return false, "invalid-options"
	end
	local commandId = normalizedCommandId(options)
	if not commandId then
		return false, "invalid-command-id"
	end
	local note, noteOk = normalizedOperatorNote(options)
	if not noteOk then
		return false, "invalid-options"
	end

	local auditEntry = baseAuditEntry(commandId, "admin-drop", note)
	auditEntry.crateId = crateId

	local ok, result = runCommandWrite(commandId, "adminDrop:" .. crateId, auditEntry, function(state)
		if not state.adminParty.padActive then
			return false, "pad-inactive"
		end
		-- No durable mutation: the drop itself is a one-shot broadcast. The
		-- write still bumps revision and records idempotency + audit.
		return true, {
			action = "adminDrop",
			crateId = crateId,
		}
	end)

	if not ok then
		return false, result
	end
	if result == "idempotent" then
		return true, "already-processed"
	end
	-- Apply locally for this server's players; other servers apply on delta.
	local dropOk, droppedOrCode, skipped = RollService.DropAdminCrate(crateId)
	if not dropOk then
		warn("[LiveEventCommandService] Local admin drop skipped: " .. tostring(droppedOrCode))
		return true, 0, 0
	end
	return true, droppedOrCode, skipped
end

function LiveEventCommandService.ListGlobalEvents()
	-- Expired records linger in durable state until the next command write
	-- prunes them; hide them here so operators see what is actually running.
	local now = serverNow()
	local records = {}
	for _, record in pairs(localActive) do
		if (finiteNumber(record.endsAt) or 0) > now then
			records[#records + 1] = copyRecord(record)
		end
	end
	table.sort(records, compareRecords)
	return records, localRevision
end

function LiveEventCommandService.ReconcileNow(reason)
	if not (started and dataStore) then
		return false, "datastore-unavailable"
	end
	if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync) <= 0 then
		return false, "datastore-budget-exhausted"
	end

	local ok, rawOrError = pcall(function()
		return dataStore:GetAsync(STORE_KEY, getOptions)
	end)
	if not ok then
		-- Persistent failure (e.g. Studio without API access) would otherwise
		-- warn every poll forever; log the first few, then sample.
		reconcileFailureStreak += 1
		if reconcileFailureStreak <= 3 or reconcileFailureStreak % 20 == 0 then
			warn(string.format(
				"[LiveEventCommandService] Reconcile read failed%s (streak %d): %s",
				reason and (" (" .. tostring(reason) .. ")") or "",
				reconcileFailureStreak,
				tostring(rawOrError)
			))
		end
		return false, "datastore-read-failed"
	end
	reconcileFailureStreak = 0

	local state, stateCode = sanitizeState(rawOrError)
	if not state then
		warn("[LiveEventCommandService] Reconcile ignored durable state: " .. tostring(stateCode))
		return false, stateCode
	end
	-- Never regress: a poll can be older than a just-applied message.
	applyState(state, false)
	return true, state.revision
end

local function subscribeWithRetry()
	local attempt = 0
	while started and not subscription do
		attempt += 1
		local ok, connectionOrError = pcall(function()
			return MessagingService:SubscribeAsync(TOPIC, function(message)
				RuntimeGuard.Run("LiveEventCommandService.OnMessage", onMessage, message)
			end)
		end)
		if ok then
			subscription = connectionOrError
			return
		end
		warn(string.format(
			"[LiveEventCommandService] SubscribeAsync failed (attempt %d, polling still active): %s",
			attempt,
			tostring(connectionOrError)
		))
		task.wait(math.min(5 * attempt, 60))
	end
end

function LiveEventCommandService.Start()
	if started then
		return
	end
	started = true

	-- Always create the replicated messages folder so clients can bind to it
	-- even when the DataStore is unavailable and the control plane is disabled.
	getMessagesFolder()

	local ok, storeOrError = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("[LiveEventCommandService] DataStore unavailable; global live events disabled: " .. tostring(storeOrError))
		return
	end
	dataStore = storeOrError
	getOptions = Instance.new("DataStoreGetOptions")
	getOptions.UseCache = false

	-- Subscribe before the first read so a command landing in between is not
	-- missed until the next poll.
	RuntimeGuard.Spawn("LiveEventCommandService.Subscribe", subscribeWithRetry)
	RuntimeGuard.Spawn("LiveEventCommandService.ReconcileLoop", function()
		-- Wait (bounded) for the subscription to actually establish before the
		-- initial read; SubscribeAsync yields, so spawn order alone is not enough
		-- to close the race. The poll covers the timeout case regardless.
		local subscribeDeadline = os.clock() + 5
		while not subscription and os.clock() < subscribeDeadline do
			task.wait(0.1)
		end
		LiveEventCommandService.ReconcileNow("startup")
		while started do
			task.wait(RECONCILE_BASE_SECONDS + rng:NextNumber(0, RECONCILE_JITTER_SECONDS))
			LiveEventCommandService.ReconcileNow()
			-- Sweep: drops replicated message children that outlived their
			-- remove buffer (reconcile alone cannot, since expired records are
			-- only pruned from durable state on command writes).
			RuntimeGuard.Run("LiveEventCommandService.MessageSweep", publishAdminMessages)
		end
	end)
end

return LiveEventCommandService
