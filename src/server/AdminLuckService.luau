-- Holds the globally-applied admin luck boost. The boost is set through the
-- live-events control plane (LiveEventCommandService.SetAdminLuck) so every
-- server converges on the same value; this module only owns the local
-- application: RollService reads CurrentMultiplier() as one more additive
-- luck term, and clients read the ReplicatedStorage attributes for the
-- HUD.Buffs.AdminLuck badge.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local State = require(Shared:WaitForChild("State"))

local AdminLuckService = {}

local BASE_MULTIPLIER = 1

local started = false
local currentMultiplier = BASE_MULTIPLIER
local endsAt = 0
local expireToken = 0

local function now()
	return Workspace:GetServerTimeNow()
end

local function finiteNumber(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	return value
end

local function publish()
	ReplicatedStorage:SetAttribute(State.AdminLuck.Multiplier, currentMultiplier)
	ReplicatedStorage:SetAttribute(State.AdminLuck.EndsAt, endsAt)
end

local function expireIfNeeded()
	if endsAt > 0 and now() >= endsAt then
		currentMultiplier = BASE_MULTIPLIER
		endsAt = 0
		publish()
	end
end

local function scheduleExpiration()
	expireToken += 1
	local token = expireToken
	local delaySeconds = endsAt - now()
	if delaySeconds <= 0 then
		expireIfNeeded()
		return
	end

	task.delay(delaySeconds + 0.1, function()
		if token ~= expireToken then
			return
		end
		expireIfNeeded()
	end)
end

-- Replace semantics: whatever the control plane hands over is the new truth.
-- Apply(1, 0) (or an expired endsAt) clears the boost.
function AdminLuckService.Apply(multiplier, endsAtValue)
	multiplier = finiteNumber(multiplier) or BASE_MULTIPLIER
	endsAtValue = finiteNumber(endsAtValue) or 0
	if multiplier <= BASE_MULTIPLIER or endsAtValue <= now() then
		multiplier = BASE_MULTIPLIER
		endsAtValue = 0
	end

	currentMultiplier = multiplier
	endsAt = endsAtValue
	publish()
	scheduleExpiration()
end

function AdminLuckService.CurrentMultiplier()
	expireIfNeeded()
	return currentMultiplier
end

function AdminLuckService.Start()
	if started then
		return
	end
	started = true

	currentMultiplier = BASE_MULTIPLIER
	endsAt = 0
	publish()
end

return AdminLuckService
