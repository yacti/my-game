local Balance = {}

Balance.MAX_PET_LEVEL = 10
Balance.MIN_SCALE = 1.0
Balance.MAX_SCALE = 2.0

function Balance.PetLevelFromType(petType)
	return tonumber(tostring(petType):match("%d+")) or 1
end

function Balance.NextPetType(petType)
	local level = Balance.PetLevelFromType(petType)
	if level >= Balance.MAX_PET_LEVEL then return nil end
	return "Pet" .. (level + 1)
end

function Balance.XPToEvolve(level)
	if level >= Balance.MAX_PET_LEVEL then return math.huge end
	return 10 * level
end

function Balance.ScaleForXP(xp, level)
	if level >= Balance.MAX_PET_LEVEL then
		return Balance.MAX_SCALE
	end
	local threshold = Balance.XPToEvolve(level)
	local progress = math.clamp(xp / threshold, 0, 1)
	return Balance.MIN_SCALE + (Balance.MAX_SCALE - Balance.MIN_SCALE) * progress
end

function Balance.XPProgress(xp, level)
	if level >= Balance.MAX_PET_LEVEL then return 1 end
	return math.clamp(xp / Balance.XPToEvolve(level), 0, 1)
end

return Balance
