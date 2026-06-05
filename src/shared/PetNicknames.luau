local PetNicknames = {}

local NICKNAMES = {
	"Maya",
	"Marc",
	"Daire",
}

local COLOR_OVERRIDES = {
	Marc = Color3.fromRGB(34, 139, 34), -- Forest green
}

function PetNicknames.Pick(random)
	local rng = random or Random.new()
	return NICKNAMES[rng:NextInteger(1, #NICKNAMES)]
end

function PetNicknames.ColorFor(nickname)
	return COLOR_OVERRIDES[nickname]
end

return PetNicknames
