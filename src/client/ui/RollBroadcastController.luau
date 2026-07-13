-- Renders rare-roll broadcasts into the chat window as system messages.
-- Rarity styling comes from the shared Rarities module: static tiers color the
-- item name via a single rich-text font tag; animated tiers (Mythical,
-- Exclusive) get a per-character rich-text gradient sampled from the tier's
-- color cycle. The gradient is static per message by engine constraint: the
-- default chat renderer only honors UIGradients on PrefixTextProperties, takes
-- a one-time clone of them at mount, and the rendered label lives in CoreGui
-- where LocalScripts cannot reach it — so neither gradient mutation nor
-- TweenService can animate a delivered message (verified empirically 2026-07).
-- Each message samples the cycle at its own display time, so consecutive
-- broadcasts still shimmer relative to each other.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollBroadcasts = require(Shared:WaitForChild("RollBroadcasts"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local RollBroadcastController = {}

local METADATA_PREFIX = "RollBroadcast|"
local GLOBAL_PREFIX = utf8.char(0x1F30D) .. " " -- globe emoji marks cross-server rolls
local CHANNELS_WAIT_SECONDS = 10
-- Fraction of the tier's color cycle spread across the item name's characters.
local GRADIENT_TEXT_SPAN = 0.6

local generalChannel = nil
local warnedMissingChannel = false

local function escapeRichText(text)
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	return text
end

-- Per-character gradient for animated tiers: each grapheme gets its own font
-- tag, sampling the tier's color cycle (rainbow for Mythical, color stops for
-- Exclusive) across GRADIENT_TEXT_SPAN of one period. Anchoring the sample at
-- display time gives every broadcast a different phase.
local function animatedNameMarkup(rarity, itemName, definition)
	local period = definition.RainbowPeriod or definition.TweenPeriod or 4
	local graphemes = {}
	for first, last in utf8.graphemes(itemName) do
		graphemes[#graphemes + 1] = string.sub(itemName, first, last)
	end
	local count = #graphemes
	local now = os.clock()
	local pieces = table.create(count)
	for index, grapheme in ipairs(graphemes) do
		local alpha = count > 1 and (index - 1) / (count - 1) or 0
		local color = Rarities.TextColorFor(rarity, now + alpha * period * GRADIENT_TEXT_SPAN)
		pieces[index] = string.format('<font color="#%s">%s</font>', color:ToHex(), escapeRichText(grapheme))
	end
	return table.concat(pieces)
end

local function itemNameMarkup(rarity, itemName)
	local definition = Rarities.Get(rarity)
	if definition and definition.Animated then
		return "<b>" .. animatedNameMarkup(rarity, itemName, definition) .. "</b>"
	end
	local color = Rarities.TextColorFor(rarity)
	local hex = color and ("#" .. color:ToHex()) or "#FFFFFF"
	return string.format('<font color="%s"><b>%s</b></font>', hex, escapeRichText(itemName))
end

local function flaggedPlayerName(payload)
	local flag = RollBroadcasts.FlagEmojiFor(payload.countryCode)
	if flag then
		return flag .. " " .. payload.playerName
	end
	return payload.playerName
end

local function buildMessageText(scope, payload)
	local prefix = scope == RollBroadcasts.Scope.Global and GLOBAL_PREFIX or ""
	return string.format(
		"%s<b>%s</b> rolled a <b>%s</b> %s!",
		prefix,
		escapeRichText(flaggedPlayerName(payload)),
		escapeRichText(payload.chanceText),
		itemNameMarkup(payload.rarity, payload.itemName)
	)
end

local function getGeneralChannel()
	if generalChannel and generalChannel.Parent then
		return generalChannel
	end
	local channels = TextChatService:WaitForChild("TextChannels", CHANNELS_WAIT_SECONDS)
	generalChannel = channels and channels:FindFirstChild("RBXGeneral") or nil
	if not generalChannel and not warnedMissingChannel then
		warnedMissingChannel = true
		warn("[RollBroadcastController] Missing TextChatService.TextChannels.RBXGeneral; roll broadcasts disabled")
	end
	return generalChannel
end

local function displayLegacyMessage(scope, payload)
	local prefix = scope == RollBroadcasts.Scope.Global and GLOBAL_PREFIX or ""
	pcall(function()
		StarterGui:SetCore("ChatMakeSystemMessage", {
			Text = string.format("%s%s rolled a %s %s!", prefix, flaggedPlayerName(payload), payload.chanceText, payload.itemName),
			Color = Rarities.TextColorFor(payload.rarity) or Color3.new(1, 1, 1),
		})
	end)
end

local function displayMessage(scope, payload)
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		displayLegacyMessage(scope, payload)
		return
	end
	local channel = getGeneralChannel()
	if not channel then
		return
	end
	channel:DisplaySystemMessage(buildMessageText(scope, payload), METADATA_PREFIX .. payload.rarity)
end

function RollBroadcastController.start()
	local remote = Remotes.get(Remotes.Names.RollBroadcastEffect)
	RuntimeGuard.Connect(remote.OnClientEvent, "RollBroadcastController.OnBroadcast", function(data)
		local payload = RollBroadcasts.ValidatePayload(data)
		if not payload then
			return
		end
		local scope = data.scope == RollBroadcasts.Scope.Global and RollBroadcasts.Scope.Global or RollBroadcasts.Scope.Server
		displayMessage(scope, payload)
	end)
end

return RollBroadcastController
