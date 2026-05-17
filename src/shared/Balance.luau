local Balance = {}

Balance.MIN_SCALE = 1.0
Balance.MAX_SCALE = 2.0

function Balance.ScaleForXP(xp, maxXP)
	if type(maxXP) ~= "number" or maxXP <= 0 then
		return Balance.MAX_SCALE
	end
	local progress = math.clamp((xp or 0) / maxXP, 0, 1)
	return Balance.MIN_SCALE + (Balance.MAX_SCALE - Balance.MIN_SCALE) * progress
end

function Balance.XPProgress(xp, maxXP)
	if type(maxXP) ~= "number" or maxXP <= 0 then return 1 end
	return math.clamp((xp or 0) / maxXP, 0, 1)
end

return Balance
