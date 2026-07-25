-- Shared scale math for mature patch slot fruit and harvested patch food tools.
-- The server owns XP; clients use this only to render local fruit presentation.
local PatchScale = {}

PatchScale.DEFAULT_XP = 1
PatchScale.MIN = 0.3
PatchScale.MAX = 2.75
PatchScale.MAX_BASE_XP_MULTIPLIER = 2500

-- Per-food max-scale overrides. The XP ceiling stretches with the extra scale
-- range, so overridden foods grow at the same scale-per-XP rate as everything
-- else and simply keep growing longer before capping.
PatchScale.FoodMaxOverrides = {
	Sunflower = 8,
}

local function boundsFor(foodId)
	local max = foodId ~= nil and PatchScale.FoodMaxOverrides[foodId] or PatchScale.MAX
	local multiplier = PatchScale.MAX_BASE_XP_MULTIPLIER
	if max ~= PatchScale.MAX then
		multiplier = 1 + (multiplier - 1) * (max - PatchScale.MIN) / (PatchScale.MAX - PatchScale.MIN)
	end
	return max, multiplier
end

function PatchScale.NormalizePatchXP(value)
	if type(value) ~= "number" or value <= 0 then
		return PatchScale.DEFAULT_XP
	end
	return value
end

function PatchScale.Progress(xp, patchXP, foodId)
	local normalizedPatchXP = PatchScale.NormalizePatchXP(patchXP)
	local _, maxBaseXPMultiplier = boundsFor(foodId)
	local minXP = normalizedPatchXP
	local maxXP = normalizedPatchXP * maxBaseXPMultiplier
	local range = maxXP - minXP
	if range <= 0 then return 1 end
	return math.clamp(((tonumber(xp) or 0) - minXP) / range, 0, 1)
end

function PatchScale.ComputeScale(xp, patchXP, foodId)
	local max = boundsFor(foodId)
	return PatchScale.MIN + (max - PatchScale.MIN) * PatchScale.Progress(xp, patchXP, foodId)
end

return PatchScale
