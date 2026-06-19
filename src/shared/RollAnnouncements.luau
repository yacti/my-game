local HttpService = game:GetService("HttpService")

local Rarities = require(script.Parent:WaitForChild("Rarities"))

local RollAnnouncements = {}

RollAnnouncements.Topic = "RollAnnouncementV1"
RollAnnouncements.MessageTtlSeconds = 90
RollAnnouncements.LocalBatchCap = 2
RollAnnouncements.LocalCooldownSeconds = 4
RollAnnouncements.DedupeTtlSeconds = 120

RollAnnouncements.Scope = {
	Server = "server",
	Global = "global",
}

RollAnnouncements.MaxLengths = {
	MessageId = 72,
	JobId = 128,
	PlayerName = 32,
	ItemName = 80,
	ChanceText = 32,
	Rarity = 24,
	RewardId = 80,
}

local RARITY_SCOPE = {
	[Rarities.Legendary] = RollAnnouncements.Scope.Server,
	[Rarities.Mythical] = RollAnnouncements.Scope.Server,
	[Rarities.Secret] = RollAnnouncements.Scope.Global,
}

local RARITY_PRIORITY = {
	[Rarities.Secret] = 1,
	[Rarities.Mythical] = 2,
	[Rarities.Legendary] = 3,
}

local RICH_TEXT_ESCAPES = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&#39;",
}

local function trim(text)
	return string.gsub(text, "^%s*(.-)%s*$", "%1")
end

local function sanitizeText(value, maxLength)
	if type(value) ~= "string" then
		return nil
	end
	value = trim(string.gsub(value, "[%c]", " "))
	value = string.gsub(value, "%s+", " ")
	if value == "" then
		return nil
	end
	maxLength = math.max(math.floor(tonumber(maxLength) or #value), 1)
	if #value > maxLength then
		value = string.sub(value, 1, maxLength)
		value = trim(value)
	end
	return value ~= "" and value or nil
end

local function finiteInteger(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	value = math.floor(value)
	if minimum and value < minimum then
		return nil
	end
	return value
end

function RollAnnouncements.ScopeForRarity(rarity)
	return RARITY_SCOPE[rarity]
end

function RollAnnouncements.IsAllowedRarity(rarity)
	return RARITY_SCOPE[rarity] ~= nil
end

function RollAnnouncements.PriorityForRarity(rarity)
	return RARITY_PRIORITY[rarity] or math.huge
end

function RollAnnouncements.EscapeRichText(text)
	text = tostring(text or "")
	return (string.gsub(text, "[&<>\"']", RICH_TEXT_ESCAPES))
end

function RollAnnouncements.PlainText(payload)
	if type(payload) ~= "table" then
		return nil
	end
	return string.format(
		"%s rolled a %s %s %s!",
		tostring(payload.playerName or "A player"),
		tostring(payload.chanceText or "1 in ?"),
		tostring(payload.rarity or "Rare"),
		tostring(payload.itemName or "item")
	)
end

function RollAnnouncements.NewMessageId()
	local ok, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if ok and type(guid) == "string" and guid ~= "" then
		return guid
	end
	return tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000000))
end

function RollAnnouncements.NormalizePayload(payload, options)
	options = type(options) == "table" and options or {}
	if type(payload) ~= "table" then
		return nil, "invalid-payload"
	end

	local rarity = sanitizeText(payload.rarity, RollAnnouncements.MaxLengths.Rarity)
	if not (rarity and RollAnnouncements.IsAllowedRarity(rarity) and Rarities.IsValid(rarity)) then
		return nil, "invalid-rarity"
	end

	local scope = sanitizeText(payload.scope, 16) or RollAnnouncements.ScopeForRarity(rarity)
	local expectedScope = RollAnnouncements.ScopeForRarity(rarity)
	if scope ~= expectedScope then
		return nil, "invalid-scope"
	end

	local normalized = {
		messageId = sanitizeText(payload.messageId, RollAnnouncements.MaxLengths.MessageId),
		originJobId = sanitizeText(payload.originJobId, RollAnnouncements.MaxLengths.JobId),
		playerName = sanitizeText(payload.playerName, RollAnnouncements.MaxLengths.PlayerName),
		itemName = sanitizeText(payload.itemName, RollAnnouncements.MaxLengths.ItemName),
		chanceText = sanitizeText(payload.chanceText, RollAnnouncements.MaxLengths.ChanceText),
		rarity = rarity,
		scope = scope,
		createdAt = finiteInteger(payload.createdAt, 0),
		userId = finiteInteger(payload.userId, 1),
		rollBatchId = finiteInteger(payload.rollBatchId, 1),
		offerId = finiteInteger(payload.offerId, 1),
		chanceN = finiteInteger(payload.chanceN, 1),
		rewardId = sanitizeText(payload.rewardId, RollAnnouncements.MaxLengths.RewardId),
		seedId = sanitizeText(payload.seedId, RollAnnouncements.MaxLengths.RewardId),
		miscId = sanitizeText(payload.miscId, RollAnnouncements.MaxLengths.RewardId),
	}

	if not normalized.messageId then
		return nil, "missing-message-id"
	end
	if not (normalized.playerName and normalized.itemName and normalized.chanceText) then
		return nil, "missing-text-field"
	end
	if not normalized.createdAt then
		return nil, "missing-created-at"
	end
	if not normalized.originJobId then
		return nil, "missing-origin-job-id"
	end
	if options.rejectStale == true and math.abs(os.time() - normalized.createdAt) > RollAnnouncements.MessageTtlSeconds then
		return nil, "stale-message"
	end

	return normalized, "ok"
end

return RollAnnouncements
