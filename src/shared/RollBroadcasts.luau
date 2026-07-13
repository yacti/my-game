-- Contract for rare-roll chat broadcasts: which rarities announce to the
-- rolling player's server vs. across all servers, and the rate windows both
-- sides enforce. Excess broadcasts inside a window are DROPPED, never queued,
-- so a mass-secret event can only ever surface the window limit in chat.
local Shared = script.Parent
local Rarities = require(Shared:WaitForChild("Rarities"))

local RollBroadcasts = {}

-- Rarities announced to everyone in the rolling player's server.
RollBroadcasts.ServerRarities = {
	[Rarities.Mythical] = true,
	[Rarities.Secret] = true,
}

-- Rarities additionally announced across all servers via MessagingService.
RollBroadcasts.GlobalRarities = {
	[Rarities.Secret] = true,
}

RollBroadcasts.Scope = {
	Server = "server",
	Global = "global",
}

RollBroadcasts.WindowSeconds = 5
-- Received global messages a server will display per window.
RollBroadcasts.GlobalDisplayLimit = 50
-- MessagingService publishes a single server may send per window.
RollBroadcasts.GlobalPublishLimit = 10
-- Local (same-server) chat announcements per window.
RollBroadcasts.ServerDisplayLimit = 25

local MAX_PLAYER_NAME_LENGTH = 50
local MAX_ITEM_NAME_LENGTH = 80
local MAX_CHANCE_TEXT_LENGTH = 40

local function boundedString(value, maxLength)
	if type(value) ~= "string" or #value == 0 or #value > maxLength then
		return nil
	end
	return value
end

-- Shared by the server's MessagingService handler and the client's remote
-- handler: both receive data from a boundary and must not trust field shapes.
-- Returns a sanitized copy holding only the broadcast fields, or nil.
function RollBroadcasts.ValidatePayload(data)
	if type(data) ~= "table" then
		return nil
	end
	local playerName = boundedString(data.playerName, MAX_PLAYER_NAME_LENGTH)
	local itemName = boundedString(data.itemName, MAX_ITEM_NAME_LENGTH)
	local chanceText = boundedString(data.chanceText, MAX_CHANCE_TEXT_LENGTH)
	local rarity = data.rarity
	if not (playerName and itemName and chanceText) then
		return nil
	end
	if type(rarity) ~= "string" or not Rarities.IsValid(rarity) then
		return nil
	end
	-- Optional: ISO 3166-1 alpha-2 country of the roller; a broadcast without
	-- one (lookup failed) simply renders flagless.
	local countryCode = data.countryCode
	if not (type(countryCode) == "string" and string.match(countryCode, "^%u%u$")) then
		countryCode = nil
	end
	return {
		playerName = playerName,
		itemName = itemName,
		chanceText = chanceText,
		rarity = rarity,
		countryCode = countryCode,
	}
end

-- "IE" -> the two regional-indicator codepoints that render as that country's
-- flag emoji. Returns nil for anything but two uppercase ASCII letters.
function RollBroadcasts.FlagEmojiFor(countryCode)
	if not (type(countryCode) == "string" and string.match(countryCode, "^%u%u$")) then
		return nil
	end
	local first = 0x1F1E6 + string.byte(countryCode, 1) - string.byte("A")
	local second = 0x1F1E6 + string.byte(countryCode, 2) - string.byte("A")
	return utf8.char(first) .. utf8.char(second)
end

return RollBroadcasts
