-- Shared derivation of patch slot XP from its growth anchor.
--
-- Patch growth is deterministic, so the server does not tick or replicate
-- per-interval XP. It publishes a base XP and a growth-start timestamp once
-- per slot (re-anchored on harvest/respawn/restore), and both server and
-- clients derive the current XP from elapsed time:
--
--   xp(now) = baseXP + floor((now - growthStart) / growRate) * xpPerInterval
--
-- Timestamps use Workspace:GetServerTimeNow() so clients share the clock.
-- The server remains authoritative: harvest/persistence values are computed
-- server-side from server state; clients use this only for presentation.

local PatchScale = require(script.Parent:WaitForChild("PatchScale"))
local State = require(script.Parent:WaitForChild("State"))

local PatchGrowth = {}

PatchGrowth.DEFAULT_GROW_RATE = 3

function PatchGrowth.NormalizeGrowRate(value)
	if type(value) ~= "number" or value <= 0 then
		return PatchGrowth.DEFAULT_GROW_RATE
	end
	return value
end

function PatchGrowth.ComputeXPFromState(baseXP, growthStart, growRate, xpPerInterval, now)
	baseXP = tonumber(baseXP) or 0
	if type(growthStart) ~= "number" or type(now) ~= "number" then
		return baseXP
	end
	growRate = PatchGrowth.NormalizeGrowRate(growRate)
	local elapsed = math.max(now - growthStart, 0)
	return baseXP + math.floor(elapsed / growRate) * (tonumber(xpPerInterval) or 0)
end

-- Presentation helper: derives a slot food's current XP from its replicated
-- attributes and the owning machine's template attributes.
function PatchGrowth.ComputeXPForFood(food, machine, now)
	local baseXP = tonumber(food:GetAttribute(State.Food.XP)) or 0
	local growthStart = food:GetAttribute(State.Food.GrowthStart)
	if type(growthStart) ~= "number" then
		return baseXP
	end
	local growRate = machine and machine:GetAttribute(State.Feed.GrowRate) or nil
	local xpPerInterval = PatchScale.NormalizePatchXP(machine and machine:GetAttribute(State.Feed.XP) or nil)
	return PatchGrowth.ComputeXPFromState(baseXP, growthStart, growRate, xpPerInterval, now)
end

return PatchGrowth
