-- Global cross-server leaderboards rendered on Workspace.Leaderboard.
--
-- Two boards, each ranked by one OrderedDataStore. The ranking is genuinely
-- game-wide, and the read path is built for small servers: this game runs
-- 8-player servers, so server count scales as CCU/8 and anything done
-- per-server fans out 7.5x harder than it would on 60-player servers while the
-- DataStore budgets only track CCU.
--
-- That rules out the obvious design (every server calls GetSortedAsync on a
-- timer). At 8 players a server gets 5 + 2*players = 21 List requests/min and
-- 30 + 5*players = 70 Write requests/min, and the experience-wide budgets are
-- 300 + 2*CCU List and 300 + 20*CCU Write. Polling from every server costs a
-- flat 25% of the game-wide List budget at any CCU, and writing every player on
-- a timer costs 46% of each server's Write budget -- a pool shared with
-- ProfileStore, so leaderboard traffic would be throttling profile saves.
--
-- So the traffic is collapsed twice:
--
--  1. Writes are cutoff-gated. Each refresh publishes the score at rank 100; a
--     player below it cannot appear on the board, so writing them changes
--     nothing anyone can see and they are written only when they leave (which
--     keeps the store complete for when they eventually climb). Only players at
--     or above the cutoff are written on the timer. At scale almost no
--     8-player server holds a top-100 player, so periodic writes collapse to
--     roughly zero and total volume tracks session churn, not CCU x ticks.
--
--  2. Reads go through one shared MemoryStore snapshot. Servers read a
--     ready-to-render JSON payload rather than the OrderedDataStore; when the
--     snapshot goes stale exactly one server wins a short-TTL lock and does the
--     GetSortedAsync itself. Game-wide that is 2 List calls per refresh period
--     no matter how many servers exist. MemoryStore quotas are experience-wide
--     and huge (1000 + 120*CCU units/min), which is exactly the fan-out it is
--     designed to absorb.
--
-- Neither board needs a counter of its own -- both scores already live on the
-- profile:
--   TopRolls -> Data.LifetimeCrateRolls (monotonic; one per crate a roll spawns,
--               so a player with three unlocked drop areas gains three a roll)
--   TopCash  -> Data.Currency (the live balance, which rebirth resets to zero --
--               hence the "RIGHT NOW" subheader instead of "ALL TIME")
--
-- This module is the single source of board ids, store names, cadences, and
-- value clamping, so the writer, the refresher, and the client renderer can
-- never disagree about them.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(ReplicatedStorage.Shared:WaitForChild("PlayerState"))

local Leaderboards = {}

-- Workspace folder holding one Model per board.
Leaderboards.FolderName = "Leaderboard"

-- Also GetSortedAsync's per-page ceiling, which is why one call fills a board.
Leaderboards.MaxEntries = 100

-- How often a server pulls the shared snapshot, and how stale the snapshot may
-- get before someone refreshes it. Both are 30s, so a score reaches other
-- servers in ~30s typical and ~60s worst case.
Leaderboards.RefreshSeconds = 30
Leaderboards.SnapshotStaleSeconds = 30
Leaderboards.WriteSeconds = 30

-- Snapshot outlives its staleness window by a wide margin so a failed refresh
-- shows a slightly old board instead of an empty one.
Leaderboards.SnapshotTtlSeconds = 600

-- Only one server should rebuild a board per period. The lock TTL covers a
-- GetSortedAsync plus a name batch with room to spare; if the winner dies
-- mid-refresh the lock simply expires and the next server takes over.
Leaderboards.RefreshLockSeconds = 20

-- Spread the first snapshot read so servers booting together do not align.
Leaderboards.StartJitterSeconds = 30

-- OrderedDataStore takes an int64, but Lua numbers are doubles and stop being
-- exact integers past 2^53. Clamp to the safe range rather than silently
-- ranking on rounded values. Currency tops out in the low billions (the last
-- rebirth tier costs 5e9), so this ceiling is never reached in practice.
Leaderboards.MaxScore = 9e15

-- Rows 1-3 have their own taller templates with the rank text baked in; every
-- other row clones the plain template and has its rank written at render time.
Leaderboards.RowTemplateName = "PlayerLabelTemplate"
Leaderboards.PodiumTemplateNames = {
	"PlayerLabelTemplate1",
	"PlayerLabelTemplate2",
	"PlayerLabelTemplate3",
}

Leaderboards.Boards = {
	{
		Id = "TopRolls",
		ModelName = "TopRolls",
		StoreName = "Leaderboard_TopRolls_v1",
		Header = "TOP ROLLS",
		Subheader = "ALL TIME",
		YourLabel = "YOUR ROLLS:",
		-- ProfileField is what the server ranks; ReplicaField is what YourStat
		-- reads locally. Same value today, named apart so a future divergence
		-- cannot silently rank one number and display another.
		ProfileField = "LifetimeCrateRolls",
		ReplicaField = PlayerState.Fields.LifetimeCrateRolls,
	},
	{
		Id = "TopCash",
		ModelName = "TopCash",
		StoreName = "Leaderboard_TopCash_v1",
		Header = "TOP CASH",
		-- Not "ALL TIME": this is the live balance and rebirth zeroes it.
		Subheader = "RIGHT NOW",
		YourLabel = "YOUR CASH:",
		ProfileField = "Currency",
		ReplicaField = PlayerState.Fields.Currency,
	},
}

local boardsById = {}
for _, board in ipairs(Leaderboards.Boards) do
	boardsById[board.Id] = board
end

function Leaderboards.GetBoard(boardId)
	return boardsById[boardId]
end

-- Studio playtests must never write into the live ranking. ProfileStore already
-- swaps to its mock store in Studio; this is the same idea for the boards, and
-- it covers the MemoryStore keys too.
local function devSuffixed(name, isStudio)
	if isStudio then
		return name .. "_dev"
	end
	return name
end

function Leaderboards.StoreNameFor(board, isStudio)
	if not board then
		return nil
	end
	return devSuffixed(board.StoreName, isStudio)
end

-- One HashMap per board rather than one shared map: the per-data-structure
-- ceiling is 100,000 request units/min, and splitting halves each board's share.
function Leaderboards.SnapshotMapNameFor(board, isStudio)
	if not board then
		return nil
	end
	return devSuffixed(board.StoreName .. "_snapshot", isStudio)
end

Leaderboards.SnapshotKey = "top"
Leaderboards.RefreshLockKey = "refresh"

-- OrderedDataStore rejects non-integers and out-of-range values outright, so
-- every score passes through here before it is written or ranked.
function Leaderboards.ClampScore(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.clamp(math.floor(value), 0, Leaderboards.MaxScore)
end

-- rbxthumb is resolved by the engine, so a 100-row board costs zero Lua web
-- calls and cannot be rate limited. The templates ship with the retired
-- roblox.com/headshot-thumbnail URL, which no longer resolves reliably in game.
function Leaderboards.HeadshotFor(userId)
	userId = tonumber(userId)
	if not userId or userId <= 0 then
		return ""
	end
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", math.floor(userId))
end

function Leaderboards.TemplateNameForRank(rank)
	return Leaderboards.PodiumTemplateNames[rank] or Leaderboards.RowTemplateName
end

return Leaderboards
