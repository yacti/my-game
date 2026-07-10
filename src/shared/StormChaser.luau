-- StormChaser: always-on meta event tying the three storm weather events into
-- one repeating cycle. Slots are anchored to real epoch hours via the synced
-- server clock (slot = hour % 3), matching the cadence/offset scheduling of
-- Earthquake/Tsunami/Tornado in GameEvents, so every server runs the same
-- rotation. Players deposit mutated fruit into the crates at
-- Workspace.Map["3HourlyEvent"].Active for tiered seed rewards; per-player
-- progress lives in profile.Data.StormChaser.
local Workspace = game:GetService("Workspace")

local StormChaser = {}

StormChaser.SlotSeconds = 60 * 60

-- Slot index (hour % 3) -> weather eventId. Must stay in lockstep with the
-- offsetSeconds values in GameEvents.EventConfigs.
StormChaser.Cycle = { "Earthquake", "Tsunami", "Tornado" }

-- Crate mutation -> required deposits per tier, and the seed granted when all
-- three crates are filled. Tiers loop: completing the last tier restarts at 1.
StormChaser.Tiers = {
	{
		required = { Twisted = 5, Shaken = 5, Aqua = 5 },
		rewardSeedId = "CoconutTreeSeed",
	},
	{
		required = { Twisted = 15, Shaken = 15, Aqua = 15 },
		rewardSeedId = "AgavePatchSeed",
	},
	{
		required = { Twisted = 30, Shaken = 30, Aqua = 30 },
		rewardSeedId = "LycheeTreeSeed",
	},
}

StormChaser.CrateMutationIds = { "Twisted", "Shaken", "Aqua" }

StormChaser.CrateNames = {
	Twisted = "TwistedCrate",
	Shaken = "ShakenCrate",
	Aqua = "AquaCrate",
}

StormChaser.ForecastLines = {
	Earthquake = "I think an earthquake is imminent!",
	Tsunami = "After an earthquake, usually comes a tsunami...",
	Tornado = "I'm tracking a supercell! I think a tornado will touch down",
}

StormChaser.MaxDepositDistance = 14

StormChaser.MapFolderName = "3HourlyEvent"
StormChaser.ActiveFolderName = "Active"
StormChaser.TeleportPartName = "EventTeleport"

function StormChaser.NormalizeTier(tier)
	tier = tonumber(tier)
	if tier == nil or tier ~= math.floor(tier) then
		return 1
	end
	if StormChaser.Tiers[tier] then
		return tier
	end
	return 1
end

function StormChaser.TierConfig(tier)
	return StormChaser.Tiers[StormChaser.NormalizeTier(tier)]
end

function StormChaser.NextTier(tier)
	tier = StormChaser.NormalizeTier(tier) + 1
	if StormChaser.Tiers[tier] then
		return tier
	end
	return 1
end

function StormChaser.RequiredFor(tier, mutationId)
	local config = StormChaser.TierConfig(tier)
	return config.required[mutationId]
end

local function eventIdForSlotStart(slotStart)
	local hour = math.floor(slotStart / StormChaser.SlotSeconds)
	return StormChaser.Cycle[hour % #StormChaser.Cycle + 1]
end

-- The cycle event whose slot contains `now` (it plays at the top of the slot).
function StormChaser.CurrentEvent(now)
	local slotStart = math.floor(now / StormChaser.SlotSeconds) * StormChaser.SlotSeconds
	return eventIdForSlotStart(slotStart), slotStart
end

-- The next cycle event after `now`: eventId, startsAt.
function StormChaser.NextEvent(now)
	local slotStart = (math.floor(now / StormChaser.SlotSeconds) + 1) * StormChaser.SlotSeconds
	return eventIdForSlotStart(slotStart), slotStart
end

function StormChaser.FindActiveFolder()
	local map = Workspace:FindFirstChild("Map")
	local eventFolder = map and map:FindFirstChild(StormChaser.MapFolderName)
	return eventFolder and eventFolder:FindFirstChild(StormChaser.ActiveFolderName) or nil
end

function StormChaser.FindCrate(activeFolder, mutationId)
	local crateName = StormChaser.CrateNames[mutationId]
	if not (activeFolder and crateName) then
		return nil
	end
	return activeFolder:FindFirstChild(crateName)
end

return StormChaser
