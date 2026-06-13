-- Shared scale math for mature patch slot fruit and harvested patch food tools.
-- The server owns XP; clients use this only to render local fruit presentation.
local PatchScale = {}

PatchScale.DEFAULT_XP = 1
PatchScale.MIN = 0.3
PatchScale.MAX = 2.75
PatchScale.MAX_BASE_XP_MULTIPLIER = 1250

function PatchScale.NormalizePatchXP(value)
	if type(value) ~= "number" or value <= 0 then
		return PatchScale.DEFAULT_XP
	end
	return value
end

function PatchScale.Progress(xp, patchXP)
	local normalizedPatchXP = PatchScale.NormalizePatchXP(patchXP)
	local minXP = normalizedPatchXP
	local maxXP = normalizedPatchXP * PatchScale.MAX_BASE_XP_MULTIPLIER
	local range = maxXP - minXP
	if range <= 0 then return 1 end
	return math.clamp(((tonumber(xp) or 0) - minXP) / range, 0, 1)
end

function PatchScale.ComputeScale(xp, patchXP)
	return PatchScale.MIN + (PatchScale.MAX - PatchScale.MIN) * PatchScale.Progress(xp, patchXP)
end

return PatchScale
