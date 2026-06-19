local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollAnnouncements = require(Shared:WaitForChild("RollAnnouncements"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local RollAnnouncementController = {}

local CHANNEL_WAIT_SECONDS = 10
local METADATA = "Game.RollAnnouncement"

local channel = nil
local warnedMissingChannel = false

local function colorToHex(color)
	return string.format(
		"#%02X%02X%02X",
		math.clamp(math.floor(color.R * 255 + 0.5), 0, 255),
		math.clamp(math.floor(color.G * 255 + 0.5), 0, 255),
		math.clamp(math.floor(color.B * 255 + 0.5), 0, 255)
	)
end

local function fontSpan(text, color)
	return string.format('<font color="%s">%s</font>', colorToHex(color), RollAnnouncements.EscapeRichText(text))
end

local function colorAt(sequence, position)
	if typeof(sequence) ~= "ColorSequence" then
		return Color3.new(1, 1, 1)
	end

	local keypoints = sequence.Keypoints
	if #keypoints == 0 then
		return Color3.new(1, 1, 1)
	end
	if #keypoints == 1 or position <= keypoints[1].Time then
		return keypoints[1].Value
	end
	if position >= keypoints[#keypoints].Time then
		return keypoints[#keypoints].Value
	end

	for index = 1, #keypoints - 1 do
		local left = keypoints[index]
		local right = keypoints[index + 1]
		if position >= left.Time and position <= right.Time then
			local span = right.Time - left.Time
			local alpha = span > 0 and (position - left.Time) / span or 0
			return left.Value:Lerp(right.Value, alpha)
		end
	end

	return keypoints[#keypoints].Value
end

local function isSingleColor(sequence)
	if typeof(sequence) ~= "ColorSequence" then
		return true
	end
	local keypoints = sequence.Keypoints
	if #keypoints <= 1 then
		return true
	end
	local first = keypoints[1].Value
	for index = 2, #keypoints do
		if keypoints[index].Value ~= first then
			return false
		end
	end
	return true
end

local function utf8Chars(text)
	local ok, chars = pcall(function()
		local result = {}
		for _, codepoint in utf8.codes(text) do
			result[#result + 1] = utf8.char(codepoint)
		end
		return result
	end)
	if ok and #chars > 0 then
		return chars
	end

	local fallback = {}
	for index = 1, #text do
		fallback[#fallback + 1] = string.sub(text, index, index)
	end
	return fallback
end

local function highlighted(text, sequence)
	if isSingleColor(sequence) then
		return fontSpan(text, colorAt(sequence, 0.5))
	end

	local chars = utf8Chars(text)
	local parts = {}
	for index, char in ipairs(chars) do
		local position = #chars > 1 and (index - 1) / (#chars - 1) or 0.5
		parts[#parts + 1] = fontSpan(char, colorAt(sequence, position))
	end
	return table.concat(parts)
end

local function richMessage(payload)
	local sequence = Rarities.ChatColorSequenceFor(payload.rarity, os.clock()) or ColorSequence.new(Color3.new(1, 1, 1))
	return table.concat({
		RollAnnouncements.EscapeRichText(payload.playerName),
		" rolled a ",
		highlighted(payload.chanceText, sequence),
		" ",
		highlighted(payload.rarity, sequence),
		" ",
		highlighted(payload.itemName, sequence),
		"!",
	})
end

local function getChannel()
	if channel and channel.Parent then
		return channel
	end

	local textChannels = TextChatService:WaitForChild("TextChannels", CHANNEL_WAIT_SECONDS)
	local general = textChannels and textChannels:WaitForChild("RBXGeneral", CHANNEL_WAIT_SECONDS)
	if general and general:IsA("TextChannel") then
		channel = general
		return channel
	end

	if not warnedMissingChannel then
		warn("[RollAnnouncementController] Missing TextChatService.TextChannels.RBXGeneral")
		warnedMissingChannel = true
	end
	return nil
end

local function display(payload)
	local normalized = RollAnnouncements.NormalizePayload(payload, {
		rejectStale = true,
	})
	if not normalized then
		return
	end

	local textChannel = getChannel()
	if not textChannel then
		return
	end

	local ok = pcall(function()
		textChannel:DisplaySystemMessage(richMessage(normalized), METADATA)
	end)
	if not ok then
		RuntimeGuard.Run("RollAnnouncementController.DisplayPlain", function()
			textChannel:DisplaySystemMessage(RollAnnouncements.PlainText(normalized), METADATA)
		end)
	end
end

function RollAnnouncementController.start()
	RuntimeGuard.Connect(Remotes.get(Remotes.Names.RollAnnouncement).OnClientEvent, "RollAnnouncementController.Display", display)
end

return RollAnnouncementController
