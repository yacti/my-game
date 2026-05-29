local Rarities = {}

Rarities.Common = "Common"
Rarities.Rare = "Rare"
Rarities.Epic = "Epic"
Rarities.Legendary = "Legendary"
Rarities.Mythical = "Mythical"
Rarities.Secret = "Secret"

Rarities.Order = {
	Rarities.Common,
	Rarities.Rare,
	Rarities.Epic,
	Rarities.Legendary,
	Rarities.Mythical,
	Rarities.Secret,
}

local DEFINITIONS = {
	[Rarities.Common] = {
		Name = Rarities.Common,
		RGB = { 128, 128, 128 },
		Color = Color3.fromRGB(128, 128, 128),
		Animated = false,
	},
	[Rarities.Rare] = {
		Name = Rarities.Rare,
		RGB = { 0, 162, 255 },
		Color = Color3.fromRGB(0, 162, 255),
		Animated = false,
	},
	[Rarities.Epic] = {
		Name = Rarities.Epic,
		RGB = { 170, 85, 255 },
		Color = Color3.fromRGB(170, 85, 255),
		Animated = false,
	},
	[Rarities.Legendary] = {
		Name = Rarities.Legendary,
		RGB = { 255, 221, 0 },
		Color = Color3.fromRGB(255, 221, 0),
		Animated = false,
	},
	[Rarities.Mythical] = {
		Name = Rarities.Mythical,
		RGB = { 255, 0, 255 },
		Color = Color3.fromRGB(255, 0, 255),
		Animated = true,
		RainbowPeriod = 4,
	},
	[Rarities.Secret] = {
		Name = Rarities.Secret,
		RGB = { 20, 20, 20 },
		Color = Color3.fromRGB(20, 20, 20),
		Animated = false,
	},
}

Rarities.Definitions = DEFINITIONS

function Rarities.Get(rarity)
	return DEFINITIONS[rarity]
end

function Rarities.IsValid(rarity)
	return DEFINITIONS[rarity] ~= nil
end

function Rarities.RainbowColorAt(timeSeconds)
	local period = DEFINITIONS[Rarities.Mythical].RainbowPeriod
	local hue = ((tonumber(timeSeconds) or 0) / period) % 1
	return Color3.fromHSV(hue, 0.85, 1)
end

function Rarities.ColorFor(rarity, timeSeconds)
	local definition = Rarities.Get(rarity)
	if not definition then
		return nil
	end
	if definition.Animated then
		return Rarities.RainbowColorAt(timeSeconds)
	end
	return definition.Color
end

return Rarities
