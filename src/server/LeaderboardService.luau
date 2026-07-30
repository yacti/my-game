-- Server authority for the two global leaderboards on Workspace.Leaderboard.
-- See Shared.Leaderboards for the board definitions and, more importantly, for
-- why the traffic is shaped the way it is -- this game runs 8-player servers, so
-- the naive "every server polls GetSortedAsync and writes every player"
-- leaderboard would burn a flat 25% of the experience-wide List budget and 46%
-- of each server's Write budget (a pool shared with ProfileStore).
--
-- Three moving parts:
--
--   Truth       OrderedDataStore, one per board, keyed by userId. Permanent.
--   Write path  Every player is written when they leave. On the 30s timer only
--               players at or above the current rank-100 cutoff are written,
--               because nobody below it can change what the board shows.
--   Read path   A MemoryStore HashMap per board holds the rendered top-100 as
--               JSON. Every server reads that; when it goes stale exactly one
--               server wins a short-TTL lock and does the single GetSortedAsync
--               that refreshes it for the whole game.
--
-- Failure modes are all "show something slightly old", never "hammer the
-- store": a missing snapshot disables periodic writes entirely (falling back to
-- leave-writes, which still fill the board), and a failed refresh leaves the
-- previous snapshot up until its much longer TTL expires.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Leaderboards = require(Shared:WaitForChild("Leaderboards"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local AdminPanelService = require(script.Parent:WaitForChild("AdminPanelService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local LeaderboardService = {}

local IS_STUDIO = RunService:IsStudio()
local SYNC_REQUEST_RATE_SECONDS = 5
local SHUTDOWN_FLUSH_TIMEOUT_SECONDS = 5

local syncRemote = Remotes.get(Remotes.Names.LeaderboardSync)
local syncRequestRemote = Remotes.get(Remotes.Names.LeaderboardSyncRequest)

local started = false
local records = {} -- [boardId] = record
local lastWritten = {} -- [userId] = { [boardId] = score last successfully written }
local lastKnown = {} -- [userId] = { [boardId] = most recent score seen }
local nameCache = {} -- [userId] = display name
local lastSyncRequest = {} -- [userId] = os.clock of last client sync request

local function userKey(player)
	local userId = player and tonumber(player.UserId)
	if type(userId) ~= "number" or userId ~= userId or userId % 1 ~= 0 or userId == 0 then
		return nil
	end
	return userId
end

-- Admin-granted cash and test rolls must never top a live board. Excluded at
-- the write path rather than the read path, so the store simply never contains
-- an admin row and the top page is always 100 real players.
--
-- Not applied in Studio: the owner is the one playtesting, and excluding them
-- would leave the board permanently empty in Play Solo. Studio already writes to
-- the _dev stores, so nothing reaches the live ranking either way.
local function isExcluded(userId)
	if IS_STUDIO then
		return false
	end
	return AdminPanelService.IsAdmin(userId)
end

local function scoreFor(profile, board)
	if not (profile and profile.Data) then
		return nil
	end
	return Leaderboards.ClampScore(profile.Data[board.ProfileField])
end

--[[ Snapshot payload shape (JSON in MemoryStore, table over the remote):
	{
		at = <os.time when built>,
		cutoff = <score at rank 100, or 0 while the board is not yet full>,
		entries = { { u = userId, n = name, v = score }, ... },
	}
]]

local function decodeSnapshot(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(decoded) ~= "table" or type(decoded.entries) ~= "table" then
		return nil
	end
	decoded.at = tonumber(decoded.at) or 0
	decoded.cutoff = Leaderboards.ClampScore(decoded.cutoff)
	return decoded
end

local function broadcast(record, player)
	local payload = record.payload
	if not payload then
		return
	end
	RuntimeGuard.Run("LeaderboardService.Broadcast." .. record.board.Id, function()
		if player then
			syncRemote:FireClient(player, record.board.Id, payload)
		else
			syncRemote:FireAllClients(record.board.Id, payload)
		end
	end)
end

local function applySnapshot(record, snapshot)
	if not snapshot then
		return false
	end
	-- Never move backwards: a server that read a stale snapshot moments after a
	-- refresh would otherwise flap the board between two versions.
	if record.payload and snapshot.at <= record.payload.at then
		return false
	end
	record.payload = snapshot
	record.cutoff = snapshot.cutoff

	-- Who is currently *visible* on the board, for the write gate below. Without
	-- this, a player above the cutoff who then spends down would keep their old
	-- higher score in the store until they left -- on a board captioned "RIGHT
	-- NOW", showing stale inflated cash for precisely the players everyone reads.
	local onBoard = {}
	for _, entry in ipairs(snapshot.entries) do
		local userId = tonumber(entry.u)
		if userId then
			onBoard[userId] = true
		end
	end
	record.onBoard = onBoard

	broadcast(record)
	return true
end

local function readSnapshot(record)
	local raw
	local ok = pcall(function()
		raw = record.memory:GetAsync(Leaderboards.SnapshotKey)
	end)
	if not ok then
		return nil
	end
	return decodeSnapshot(raw)
end

-- Batched name lookup: one call covers the whole page, versus 100 separate
-- GetNameFromUserIdAsync calls. Only the refreshing server ever pays this.
local function resolveNames(userIds)
	local missing = {}
	for _, userId in ipairs(userIds) do
		if nameCache[userId] == nil then
			missing[#missing + 1] = userId
		end
	end

	if #missing > 0 then
		local infos
		local ok = pcall(function()
			infos = UserService:GetUserInfosByUserIdsAsync(missing)
		end)
		if ok and type(infos) == "table" then
			for _, info in ipairs(infos) do
				local id = tonumber(info.Id)
				if id then
					local name = info.DisplayName
					if type(name) ~= "string" or name == "" then
						name = info.Username
					end
					if type(name) == "string" and name ~= "" then
						nameCache[id] = name
					end
				end
			end
		end
	end

	local names = {}
	for _, userId in ipairs(userIds) do
		names[userId] = nameCache[userId] or "Player"
	end
	return names
end

-- The one expensive call, made by a single server per refresh period for the
-- whole game.
local function buildSnapshot(record)
	local page
	local ok, err = pcall(function()
		local pages = record.ordered:GetSortedAsync(false, Leaderboards.MaxEntries)
		page = pages:GetCurrentPage()
	end)
	if not ok then
		warn(string.format("[LeaderboardService] %s GetSortedAsync failed: %s", record.board.Id, tostring(err)))
		return nil
	end
	if type(page) ~= "table" then
		return nil
	end

	local userIds = {}
	local scores = {}
	for _, entry in ipairs(page) do
		local userId = tonumber(entry.key)
		-- Defensive: admins are never written, but a legacy row would otherwise
		-- occupy a slot forever. Dropping it leaves 99 rows rather than costing
		-- a second List call to backfill.
		if userId and userId > 0 and not isExcluded(userId) then
			userIds[#userIds + 1] = userId
			scores[userId] = Leaderboards.ClampScore(entry.value)
		end
	end

	local names = resolveNames(userIds)

	local entries = {}
	for index, userId in ipairs(userIds) do
		entries[index] = {
			u = userId,
			n = names[userId],
			v = scores[userId],
		}
	end

	-- Only a full board has a meaningful cutoff; while it is still filling every
	-- score is potentially top-100, so the cutoff stays 0 and nothing is gated.
	--
	-- Derived from the raw page, never from the filtered entries. A single
	-- dropped row (a legacy admin entry, a malformed key) would otherwise leave
	-- 99 entries, hold the cutoff at 0 permanently, and silently re-enable the
	-- write storm this whole design exists to prevent -- every server writing
	-- every player every 30s, at ~46% of the per-server write budget.
	local cutoff = 0
	if #page >= Leaderboards.MaxEntries then
		cutoff = Leaderboards.ClampScore(page[#page].value)
	end

	return {
		at = os.time(),
		cutoff = cutoff,
		entries = entries,
	}
end

-- Returns true only for the single server that wins the period's lock. The lock
-- TTL is short, so a winner that dies mid-refresh just delays the next refresh
-- rather than wedging the board.
local function claimRefresh(record)
	local won = false
	local ok = pcall(function()
		record.memory:UpdateAsync(Leaderboards.RefreshLockKey, function(existing)
			if existing ~= nil then
				return nil -- someone else is already refreshing; abort the write
			end
			won = true
			return game.JobId
		end, Leaderboards.RefreshLockSeconds)
	end)
	return ok and won
end

local function publishSnapshot(record, snapshot)
	local encoded
	local ok = pcall(function()
		encoded = HttpService:JSONEncode(snapshot)
	end)
	if not ok then
		return false
	end
	local published = pcall(function()
		record.memory:SetAsync(Leaderboards.SnapshotKey, encoded, Leaderboards.SnapshotTtlSeconds)
	end)
	if not published then
		warn(string.format("[LeaderboardService] %s snapshot publish failed", record.board.Id))
	end
	return published
end

-- Race for the lock the moment the snapshot is stale, with no extra grace
-- period. Two earlier attempts to damp lock contention (a remembered race
-- deadline, then a random grace past the deadline) both silently stretched the
-- refresh to 60s, because a server's own read tick sits nearly in phase with the
-- staleness deadline -- any delay at all pushes the decision into the next 30s
-- tick.
--
-- Damping was not needed anyway. A refresh lands within a second or two of the
-- deadline, and servers only read every RefreshSeconds, so just the ~2/30 of
-- servers whose tick falls in that window ever see a stale snapshot and spend a
-- lock request. At 2,500 servers that is ~340 attempts/min per board against a
-- 100,000/min per-structure ceiling. The lock does the deduping; a lost race
-- costs 2 request units.
local function shouldRace(snapshot)
	return os.time() - (snapshot and snapshot.at or 0) >= Leaderboards.SnapshotStaleSeconds
end

local function refreshBoard(record)
	local snapshot = readSnapshot(record)
	applySnapshot(record, snapshot)

	if not shouldRace(snapshot) then
		return
	end
	if not claimRefresh(record) then
		return
	end

	local built = buildSnapshot(record)
	if not built then
		return
	end
	publishSnapshot(record, built)
	applySnapshot(record, built)
end

local function writeScore(record, userId, score)
	local ok, err = pcall(function()
		record.ordered:SetAsync(tostring(userId), score)
	end)
	if not ok then
		warn(string.format("[LeaderboardService] %s write failed for %d: %s", record.board.Id, userId, tostring(err)))
		return false
	end
	local written = lastWritten[userId]
	if not written then
		written = {}
		lastWritten[userId] = written
	end
	written[record.board.Id] = score
	return true
end

local function observe(userId, boardId, score)
	local known = lastKnown[userId]
	if not known then
		known = {}
		lastKnown[userId] = known
	end
	known[boardId] = score
end

-- True when writing this score could change what any player sees. A score below
-- the cutoff that is not already on the board is invisible either way, and gets
-- flushed on leave regardless, so skipping it loses nothing.
local function shouldWritePeriodically(record, userId, score)
	if score <= 0 then
		return false
	end
	-- No snapshot yet means no known cutoff. Fail closed rather than assuming
	-- everyone qualifies: a MemoryStore outage must not cascade into a
	-- DataStore write storm across every server in the game.
	if record.cutoff == nil then
		return false
	end
	-- Below the cutoff and not currently displayed: nothing to correct.
	-- Players already on the board stay dirty-tracked so a score that falls
	-- (spending, rebirth) is corrected downward instead of sitting stale.
	if score < record.cutoff and not (record.onBoard and record.onBoard[userId]) then
		return false
	end
	local written = lastWritten[userId]
	return not written or written[record.board.Id] ~= score
end

local function writeLoopTick()
	for _, player in ipairs(Players:GetPlayers()) do
		local userId = userKey(player)
		if userId and not isExcluded(userId) then
			local profile = PlayerDataService.GetProfile(player)
			if profile then
				for _, record in pairs(records) do
					local score = scoreFor(profile, record.board)
					if score then
						observe(userId, record.board.Id, score)
						if shouldWritePeriodically(record, userId, score) then
							writeScore(record, userId, score)
						end
					end
				end
			end
		end
	end
end

local function forgetPlayer(userId)
	lastWritten[userId] = nil
	lastKnown[userId] = nil
	lastSyncRequest[userId] = nil
end

-- The scores this player still owes the store, resolved before anything yields
-- so the profile teardown running alongside us cannot race it away.
local function pendingWrites(userId, profile)
	local known = lastKnown[userId]
	local written = lastWritten[userId]
	local pending = {}

	for _, record in pairs(records) do
		local score = scoreFor(profile, record.board)
		if score == nil and known then
			-- Profile already released; the last score the write loop observed
			-- is still accurate enough to rank on.
			score = known[record.board.Id]
		end
		if score and score > 0 and (not written or written[record.board.Id] ~= score) then
			pending[#pending + 1] = { record = record, score = score }
		end
	end
	return pending
end

-- Every player's final score lands in the store on the way out, which is what
-- keeps the board complete despite the cutoff gate on the periodic path.
local function flushPlayer(player, blocking)
	local userId = userKey(player)
	if not userId or isExcluded(userId) then
		return
	end

	local pending = pendingWrites(userId, PlayerDataService.GetProfile(player))
	if #pending == 0 then
		if not blocking then
			forgetPlayer(userId)
		end
		return
	end

	if blocking then
		for _, item in ipairs(pending) do
			writeScore(item.record, userId, item.score)
		end
		return
	end

	-- One task for all boards, forgetting the player only once every write has
	-- landed: writeScore repopulates lastWritten after it yields, so clearing
	-- the bookkeeping earlier would resurrect an entry for a departed player and
	-- leak a table per session.
	RuntimeGuard.Spawn("LeaderboardService.Flush." .. tostring(userId), function()
		for _, item in ipairs(pending) do
			writeScore(item.record, userId, item.score)
		end
		forgetPlayer(userId)
	end)
end

local function handleSyncRequest(player)
	local userId = userKey(player)
	if not userId then
		return
	end
	local now = os.clock()
	local previous = lastSyncRequest[userId]
	if previous and now - previous < SYNC_REQUEST_RATE_SECONDS then
		return
	end
	lastSyncRequest[userId] = now

	for _, record in pairs(records) do
		broadcast(record, player)
	end
end

function LeaderboardService.Start()
	if started then
		return
	end
	started = true

	for _, board in ipairs(Leaderboards.Boards) do
		records[board.Id] = {
			board = board,
			ordered = DataStoreService:GetOrderedDataStore(Leaderboards.StoreNameFor(board, IS_STUDIO)),
			memory = MemoryStoreService:GetHashMap(Leaderboards.SnapshotMapNameFor(board, IS_STUDIO)),
			payload = nil,
			cutoff = nil,
			onBoard = nil,
		}
	end

	RuntimeGuard.Connect(syncRequestRemote.OnServerEvent, "LeaderboardService.SyncRequest", handleSyncRequest)

	-- flushPlayer owns forgetting the player, once its writes have landed.
	RuntimeGuard.Connect(Players.PlayerRemoving, "LeaderboardService.PlayerRemoving", function(player)
		flushPlayer(player, false)
	end)

	RuntimeGuard.Spawn("LeaderboardService.RefreshLoop", function()
		task.wait(math.random() * Leaderboards.StartJitterSeconds)
		while true do
			for _, record in pairs(records) do
				RuntimeGuard.Run("LeaderboardService.Refresh." .. record.board.Id, refreshBoard, record)
			end
			task.wait(Leaderboards.RefreshSeconds)
		end
	end)

	RuntimeGuard.Spawn("LeaderboardService.WriteLoop", function()
		task.wait(math.random() * Leaderboards.StartJitterSeconds)
		while true do
			RuntimeGuard.Run("LeaderboardService.WriteTick", writeLoopTick)
			task.wait(Leaderboards.WriteSeconds)
		end
	end)
end

-- Called from BindToClose, which shares a 30s budget with the profile teardown
-- and its 25s ProfileStore drain. Writes must land before profiles are released,
-- but running them one player at a time would serialise up to 2*players
-- SetAsync round trips into that budget -- so they go out in parallel and this
-- waits on the batch with a hard ceiling. A score is worth far less than a
-- clean shutdown, so the deadline wins.
function LeaderboardService.Flush()
	local players = Players:GetPlayers()
	local remaining = #players
	if remaining == 0 then
		return
	end

	for _, player in ipairs(players) do
		RuntimeGuard.Spawn("LeaderboardService.ShutdownFlush", function()
			flushPlayer(player, true)
			remaining -= 1
		end)
	end

	local deadline = os.clock() + SHUTDOWN_FLUSH_TIMEOUT_SECONDS
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
	if remaining > 0 then
		warn(string.format("[LeaderboardService] shutdown flush timed out with %d player(s) pending", remaining))
	end
end

return LeaderboardService
