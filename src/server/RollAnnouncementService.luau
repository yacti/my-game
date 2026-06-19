local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local TelemetryService = require(Server:WaitForChild("TelemetryService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollAnnouncements = require(Shared:WaitForChild("RollAnnouncements"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local RollAnnouncementService = {}

local started = false
local subscription = nil
local seenMessageIds = {}
local lastLocalAnnouncementByUser = {}

local RollAnnouncementRemote = Remotes.get(Remotes.Names.RollAnnouncement)

local function userKey(player)
	return player and player.UserId or nil
end

local function playerName(player)
	if not player then
		return "A player"
	end
	if type(player.DisplayName) == "string" and player.DisplayName ~= "" then
		return player.DisplayName
	end
	return player.Name or "A player"
end

local function pruneSeen(nowSeconds)
	for messageId, expiresAt in pairs(seenMessageIds) do
		if expiresAt <= nowSeconds then
			seenMessageIds[messageId] = nil
		end
	end
end

local function markSeen(messageId)
	local nowSeconds = os.time()
	pruneSeen(nowSeconds)
	if seenMessageIds[messageId] then
		return false
	end
	seenMessageIds[messageId] = nowSeconds + RollAnnouncements.DedupeTtlSeconds
	return true
end

local function telemetryFields(payload, extra)
	local fields = type(extra) == "table" and extra or {}
	fields.userId = payload.userId
	fields.rarity = payload.rarity
	fields.chanceText = payload.chanceText
	fields.rewardId = payload.rewardId
	fields.seedId = payload.seedId
	fields.miscId = payload.miscId
	fields.rollBatchId = payload.rollBatchId
	fields.scope = payload.scope
	return fields
end

local function fireLocal(payload, source)
	local normalized, code = RollAnnouncements.NormalizePayload(payload)
	if not normalized then
		TelemetryService.Warn("roll_announcement_rejected", {
			reason = code,
			source = source,
		})
		return false, code
	end

	RuntimeGuard.Run("RollAnnouncementService.FireAllClients", function()
		RollAnnouncementRemote:FireAllClients(normalized)
	end)
	TelemetryService.Record("roll_announcement_sent", telemetryFields(normalized, {
		source = source,
	}))
	return true, "ok", normalized
end

local function publishGlobal(payload)
	RuntimeGuard.Spawn("RollAnnouncementService.PublishGlobal", function()
		local normalized, code = RollAnnouncements.NormalizePayload(payload)
		if not normalized then
			TelemetryService.Warn("roll_announcement_messaging_failed", {
				reason = code,
				stage = "normalize-publish",
			})
			return
		end

		local ok, err = pcall(function()
			MessagingService:PublishAsync(RollAnnouncements.Topic, normalized)
		end)
		if not ok then
			TelemetryService.Warn("roll_announcement_messaging_failed", telemetryFields(normalized, {
				reason = tostring(err),
				stage = "publish",
			}))
		end
	end)
end

local function sanitizeOfferPayload(player, rollBatchId, offer)
	if type(offer) ~= "table" then
		return nil
	end

	local rarity = offer.rarity
	local scope = RollAnnouncements.ScopeForRarity(rarity)
	if not scope then
		return nil
	end

	local itemName = offer.displayName or offer.rewardId or offer.seedId or offer.miscId or offer.feedType
	local payload = {
		messageId = RollAnnouncements.NewMessageId(),
		originJobId = game.JobId,
		createdAt = os.time(),
		scope = scope,
		userId = userKey(player),
		playerName = playerName(player),
		itemName = itemName,
		chanceText = offer.rngChanceText,
		rarity = rarity,
		rollBatchId = rollBatchId or offer.rollBatchId,
		offerId = offer.offerId,
		chanceN = offer.chanceN,
		rewardId = offer.rewardId,
		seedId = offer.seedId,
		miscId = offer.miscId,
	}

	local normalized = RollAnnouncements.NormalizePayload(payload)
	return normalized
end

local function sortCandidates(candidates)
	table.sort(candidates, function(a, b)
		local priorityA = RollAnnouncements.PriorityForRarity(a.rarity)
		local priorityB = RollAnnouncements.PriorityForRarity(b.rarity)
		if priorityA ~= priorityB then
			return priorityA < priorityB
		end

		local chanceA = tonumber(a.chanceN) or 0
		local chanceB = tonumber(b.chanceN) or 0
		if chanceA ~= chanceB then
			return chanceA > chanceB
		end
		return tostring(a.messageId) < tostring(b.messageId)
	end)
end

local function collectCandidates(player, rollBatchId, offers)
	local candidates = {}
	for _, offer in ipairs(type(offers) == "table" and offers or {}) do
		local payload = sanitizeOfferPayload(player, rollBatchId, offer)
		if payload then
			candidates[#candidates + 1] = payload
		end
	end
	sortCandidates(candidates)
	return candidates
end

local function announceCandidates(candidates)
	local localSent = 0
	local localCooldownKey = nil
	local localCooldownAllowed = true
	local nowSeconds = os.clock()

	for _, payload in ipairs(candidates) do
		if payload.scope == RollAnnouncements.Scope.Server and payload.userId then
			localCooldownKey = payload.userId
			local lastSent = lastLocalAnnouncementByUser[localCooldownKey]
			localCooldownAllowed = not (lastSent and nowSeconds - lastSent < RollAnnouncements.LocalCooldownSeconds)
			break
		end
	end

	for _, payload in ipairs(candidates) do
		if payload.scope == RollAnnouncements.Scope.Global then
			if markSeen(payload.messageId) then
				fireLocal(payload, "global-local")
				publishGlobal(payload)
			end
		elseif localCooldownAllowed and localSent < RollAnnouncements.LocalBatchCap then
			localSent += 1
			fireLocal(payload, "server")
		end
	end

	if localSent > 0 and localCooldownKey then
		lastLocalAnnouncementByUser[localCooldownKey] = nowSeconds
	end
end

function RollAnnouncementService.ScheduleRoll(player, rollBatchId, offers, delaySeconds)
	local candidates = collectCandidates(player, rollBatchId, offers)
	if #candidates == 0 then
		return false, "no-candidates"
	end

	delaySeconds = math.max(tonumber(delaySeconds) or 0, 0)
	task.delay(delaySeconds, function()
		RuntimeGuard.Run("RollAnnouncementService.AnnounceCandidates", announceCandidates, candidates)
	end)
	return true, "ok"
end

local function handleMessage(message)
	local payload, code = RollAnnouncements.NormalizePayload(message and message.Data, {
		rejectStale = true,
	})
	if not payload then
		TelemetryService.Warn("roll_announcement_messaging_failed", {
			reason = code,
			stage = "receive",
		})
		return
	end
	if payload.originJobId == game.JobId then
		return
	end
	if not markSeen(payload.messageId) then
		return
	end
	fireLocal(payload, "global-received")
end

function RollAnnouncementService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Spawn("RollAnnouncementService.Subscribe", function()
		local ok, result = pcall(function()
			return MessagingService:SubscribeAsync(RollAnnouncements.Topic, function(message)
				RuntimeGuard.Run("RollAnnouncementService.MessageReceived", handleMessage, message)
			end)
		end)
		if ok then
			subscription = result
		else
			TelemetryService.Warn("roll_announcement_messaging_failed", {
				reason = tostring(result),
				stage = "subscribe",
			})
		end
	end)

	RuntimeGuard.Connect(Players.PlayerRemoving, "RollAnnouncementService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			lastLocalAnnouncementByUser[key] = nil
		end
	end)
end

function RollAnnouncementService.Stop()
	if subscription then
		subscription:Disconnect()
		subscription = nil
	end
	started = false
end

return RollAnnouncementService
