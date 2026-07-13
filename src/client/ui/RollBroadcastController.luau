-- Renders rare-roll broadcasts into the chat window as system messages.
-- Rarity styling comes from the shared Rarities module: static tiers color the
-- item name via rich text; animated tiers (Mythical) get a UIGradient attached
-- through OnChatWindowAdded whose ColorSequence is re-stamped every frame so
-- the rainbow keeps moving after the message renders.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
-- Stop restamping a message's gradient once it has scrolled out of relevance;
-- also bounds the animation set so a busy chat never grows the loop.
local GRADIENT_LIFETIME_SECONDS = 60
local MAX_ANIMATED_GRADIENTS = 20
local RAINBOW_KEYPOINT_COUNT = 7
local RAINBOW_HUE_SPAN = 0.6 -- fraction of the hue wheel visible across the label

local generalChannel = nil
local warnedMissingChannel = false
local animatedGradients = {}
local heartbeatConnection = nil

local function escapeRichText(text)
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	return text
end

local function mythicalSequenceAt(timeSeconds)
	local definition = Rarities.Get(Rarities.Mythical)
	local period = (definition and definition.RainbowPeriod) or 4
	local phase = ((tonumber(timeSeconds) or 0) / period) % 1
	local keypoints = table.create(RAINBOW_KEYPOINT_COUNT + 1)
	for index = 0, RAINBOW_KEYPOINT_COUNT do
		local alpha = index / RAINBOW_KEYPOINT_COUNT
		keypoints[index + 1] = ColorSequenceKeypoint.new(
			alpha,
			Color3.fromHSV((phase + alpha * RAINBOW_HUE_SPAN) % 1, 0.85, 1)
		)
	end
	return ColorSequence.new(keypoints)
end

local function itemNameHexFor(rarity)
	local definition = Rarities.Get(rarity)
	if definition and definition.Animated then
		-- The gradient multiplies label colors, so animated tiers stay white
		-- and let the gradient supply the rainbow.
		return "#FFFFFF"
	end
	local color = Rarities.TextColorFor(rarity)
	return color and ("#" .. color:ToHex()) or "#FFFFFF"
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
		'%s<b>%s</b> rolled a <b>%s</b> <font color="%s"><b>%s</b></font>!',
		prefix,
		escapeRichText(flaggedPlayerName(payload)),
		escapeRichText(payload.chanceText),
		itemNameHexFor(payload.rarity),
		escapeRichText(payload.itemName)
	)
end

local function ensureAnimationLoop()
	if heartbeatConnection then
		return
	end
	heartbeatConnection = RuntimeGuard.Connect(RunService.Heartbeat, "RollBroadcastController.AnimateGradients", function()
		local now = os.clock()
		local sequence = mythicalSequenceAt(now)
		for index = #animatedGradients, 1, -1 do
			local entry = animatedGradients[index]
			if now - entry.startedAt > GRADIENT_LIFETIME_SECONDS then
				table.remove(animatedGradients, index)
			else
				entry.gradient.Color = sequence
			end
		end
		if #animatedGradients == 0 and heartbeatConnection then
			heartbeatConnection:Disconnect()
			heartbeatConnection = nil
		end
	end)
end

local function trackAnimatedGradient(gradient)
	animatedGradients[#animatedGradients + 1] = {
		gradient = gradient,
		startedAt = os.clock(),
	}
	while #animatedGradients > MAX_ANIMATED_GRADIENTS do
		table.remove(animatedGradients, 1)
	end
	ensureAnimationLoop()
end

local function rarityFromMetadata(metadata)
	if type(metadata) ~= "string" then
		return nil
	end
	if string.sub(metadata, 1, #METADATA_PREFIX) ~= METADATA_PREFIX then
		return nil
	end
	local rarity = string.sub(metadata, #METADATA_PREFIX + 1)
	if not Rarities.IsValid(rarity) then
		return nil
	end
	return rarity
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

local function bindChatWindowStyling()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return
	end
	local configuration = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	if not configuration then
		warn("[RollBroadcastController] Missing ChatWindowConfiguration; broadcasts render without gradient styling")
		return
	end
	-- OnChatWindowAdded is a singleton callback on TextChatService; this
	-- controller must stay its only owner or styling will silently break.
	TextChatService.OnChatWindowAdded = function(textChatMessage)
		local rarity = rarityFromMetadata(textChatMessage.Metadata)
		if not rarity then
			return nil
		end
		local definition = Rarities.Get(rarity)
		if not (definition and definition.Animated) then
			return nil
		end
		local properties = configuration:DeriveNewMessageProperties()
		local gradient = Instance.new("UIGradient")
		gradient.Color = mythicalSequenceAt(os.clock())
		gradient.Parent = properties
		trackAnimatedGradient(gradient)
		return properties
	end
end

function RollBroadcastController.start()
	bindChatWindowStyling()

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
