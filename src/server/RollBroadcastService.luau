-- Announces rare roll reveals to chat. Server scope (Mythical+) fires a
-- RemoteEvent to everyone in this server; global scope (Secret) additionally
-- publishes on a fire-and-forget MessagingService topic that every server
-- mirrors into its own chat. No DataStore durability and no queueing: a
-- broadcast that misses its rate window is dropped, and late joiners never
-- see past announcements.
local LocalizationService = game:GetService("LocalizationService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollBroadcasts = require(Shared:WaitForChild("RollBroadcasts"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local RollBroadcastService = {}

local TOPIC = "RollBroadcasts_v1"

local started = false
local subscription = nil

-- Sliding windows of os.clock() stamps, append-only so pruning pops from the
-- front. Bounded by their limits (max 50 entries), so table.remove is cheap.
local serverDisplayTimes = {}
local globalDisplayTimes = {}
local globalPublishTimes = {}

-- ISO country codes by UserId, prefetched at join so the announce path never
-- waits on the lookup. false marks a failed lookup (render flagless) so we
-- don't hammer the API retrying it.
local countryCodeByUserId = {}

local function fetchCountryCode(player)
	local userId = player.UserId
	if countryCodeByUserId[userId] ~= nil then
		return
	end
	local ok, code = pcall(LocalizationService.GetCountryRegionForPlayerAsync, LocalizationService, player)
	if countryCodeByUserId[userId] ~= nil then
		return
	end
	if ok and type(code) == "string" and string.match(code, "^%u%u$") then
		countryCodeByUserId[userId] = code
	else
		countryCodeByUserId[userId] = false
	end
end

local function windowAllow(times, limit)
	local now = os.clock()
	local windowStart = now - RollBroadcasts.WindowSeconds
	while times[1] and times[1] < windowStart do
		table.remove(times, 1)
	end
	if #times >= limit then
		return false
	end
	times[#times + 1] = now
	return true
end

local function fireToServer(scope, payload)
	Remotes.get(Remotes.Names.RollBroadcastEffect):FireAllClients({
		scope = scope,
		playerName = payload.playerName,
		itemName = payload.itemName,
		chanceText = payload.chanceText,
		rarity = payload.rarity,
		countryCode = payload.countryCode,
	})
end

local function onMessage(message)
	local data = type(message) == "table" and message.Data or nil
	local payload = RollBroadcasts.ValidatePayload(data)
	if not payload then
		return
	end
	if not RollBroadcasts.GlobalRarities[payload.rarity] then
		return
	end
	-- The origin server already announced this roll locally through the
	-- server-scope path; ignoring our own echo is what keeps a Secret from
	-- appearing twice in the server it was rolled in.
	if data.jobId == game.JobId then
		return
	end
	if not windowAllow(globalDisplayTimes, RollBroadcasts.GlobalDisplayLimit) then
		return
	end
	fireToServer(RollBroadcasts.Scope.Global, payload)
end

local function subscribeWithRetry()
	local attempt = 0
	while started and not subscription do
		attempt += 1
		local ok, connectionOrError = pcall(function()
			return MessagingService:SubscribeAsync(TOPIC, function(message)
				RuntimeGuard.Run("RollBroadcastService.OnMessage", onMessage, message)
			end)
		end)
		if ok then
			subscription = connectionOrError
			return
		end
		warn(string.format(
			"[RollBroadcastService] SubscribeAsync failed (attempt %d, global broadcasts unavailable): %s",
			attempt,
			tostring(connectionOrError)
		))
		task.wait(math.min(5 * attempt, 60))
	end
end

-- Called by RollService at reveal time (after the crate fall visual) with a
-- public roll offer. Rarity gating lives here so call sites stay unconditional;
-- anything below Mythical returns immediately.
function RollBroadcastService.AnnounceOffer(player, offer)
	if not started or type(offer) ~= "table" then
		return
	end
	local rarity = offer.rarity
	if type(rarity) ~= "string" or not RollBroadcasts.ServerRarities[rarity] then
		return
	end
	if not (player and player.Parent) then
		return
	end

	-- Announce the item's base odds, not the luck-adjusted roll text, matching
	-- how admin drops already present reveals.
	local chanceN = tonumber(offer.chanceN)
	local chanceText
	if chanceN and chanceN > 0 then
		chanceText = NumberFormatter.ChanceN(chanceN)
	elseif type(offer.rngChanceText) == "string" and #offer.rngChanceText > 0 then
		chanceText = offer.rngChanceText
	else
		return
	end

	-- Cache miss (announce raced the join-time prefetch): fetch inline; this
	-- runs on the delayed reveal thread, so the yield is harmless.
	if countryCodeByUserId[player.UserId] == nil then
		fetchCountryCode(player)
	end

	local payload = {
		playerName = tostring(player.DisplayName or player.Name),
		itemName = tostring(offer.displayName or offer.rewardId or ""),
		chanceText = chanceText,
		rarity = rarity,
		countryCode = countryCodeByUserId[player.UserId] or nil,
	}
	if not RollBroadcasts.ValidatePayload(payload) then
		return
	end

	if windowAllow(serverDisplayTimes, RollBroadcasts.ServerDisplayLimit) then
		fireToServer(RollBroadcasts.Scope.Server, payload)
	end

	if RollBroadcasts.GlobalRarities[rarity] and windowAllow(globalPublishTimes, RollBroadcasts.GlobalPublishLimit) then
		payload.jobId = game.JobId
		local ok, err = pcall(function()
			MessagingService:PublishAsync(TOPIC, payload)
		end)
		if not ok then
			warn("[RollBroadcastService] PublishAsync failed (global broadcast dropped): " .. tostring(err))
		end
	end
end

function RollBroadcastService.Start()
	if started then
		return
	end
	started = true
	RuntimeGuard.Connect(Players.PlayerAdded, "RollBroadcastService.PlayerAdded", function(player)
		RuntimeGuard.Spawn("RollBroadcastService.FetchCountry." .. tostring(player.UserId), fetchCountryCode, player)
	end)
	RuntimeGuard.Connect(Players.PlayerRemoving, "RollBroadcastService.PlayerRemoving", function(player)
		countryCodeByUserId[player.UserId] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		RuntimeGuard.Spawn("RollBroadcastService.FetchCountry." .. tostring(player.UserId), fetchCountryCode, player)
	end
	RuntimeGuard.Spawn("RollBroadcastService.Subscribe", subscribeWithRetry)
end

return RollBroadcastService
