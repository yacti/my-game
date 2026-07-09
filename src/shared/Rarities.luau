local Rarities = {}

Rarities.Common = "Common"
Rarities.Rare = "Rare"
Rarities.Epic = "Epic"
Rarities.Legendary = "Legendary"
Rarities.Mythical = "Mythical"
Rarities.Exclusive = "Exclusive"
Rarities.Secret = "Secret"

Rarities.Order = {
	Rarities.Common,
	Rarities.Rare,
	Rarities.Epic,
	Rarities.Legendary,
	Rarities.Mythical,
	Rarities.Exclusive,
	Rarities.Secret,
}

local DEFINITIONS = {
	[Rarities.Common] = {
		Name = Rarities.Common,
		Color = Color3.fromRGB(186, 186, 186),
		Animated = false,
	},
	[Rarities.Rare] = {
		Name = Rarities.Rare,
		Color = Color3.fromRGB(0, 162, 255),
		Animated = false,
	},
	[Rarities.Epic] = {
		Name = Rarities.Epic,
		Color = Color3.fromRGB(170, 85, 255),
		Animated = false,
	},
	[Rarities.Legendary] = {
		Name = Rarities.Legendary,
		Color = Color3.fromRGB(255, 221, 0),
		Animated = false,
	},
	[Rarities.Mythical] = {
		Name = Rarities.Mythical,
		Color = Color3.fromRGB(255, 0, 255),
		Animated = true,
		RainbowPeriod = 4,
	},
	[Rarities.Exclusive] = {
		Name = Rarities.Exclusive,
		Color = Color3.fromRGB(255, 255, 0),
		Animated = true,
		-- Two-colour ping-pong instead of the Mythical rainbow cycle.
		TweenColors = { Color3.fromRGB(255, 255, 0), Color3.fromRGB(255, 195, 0) },
		TweenPeriod = 2,
	},
	[Rarities.Secret] = {
		Name = Rarities.Secret,
		Color = Color3.fromRGB(20, 20, 20),
		-- Color is near-black for frames/overlays; text drawn over the game's
		-- black UIStrokes needs a readable variant or it disappears entirely.
		TextColor = Color3.fromRGB(220, 50, 50),
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

local function animatedColorAt(definition, timeSeconds)
	local colors = definition.TweenColors
	if colors then
		local period = definition.TweenPeriod or 2
		local alpha = 0.5 - 0.5 * math.cos(((tonumber(timeSeconds) or 0) / period) * 2 * math.pi)
		return colors[1]:Lerp(colors[2], alpha)
	end
	return Rarities.RainbowColorAt(timeSeconds)
end

function Rarities.ColorFor(rarity, timeSeconds)
	local definition = Rarities.Get(rarity)
	if not definition then
		return nil
	end
	if definition.Animated then
		return animatedColorAt(definition, timeSeconds)
	end
	return definition.Color
end

-- Use for TextColor3: same as ColorFor, except rarities whose display color is
-- too dark to read over text strokes provide a TextColor override.
function Rarities.TextColorFor(rarity, timeSeconds)
	local definition = Rarities.Get(rarity)
	if not definition then
		return nil
	end
	if definition.Animated then
		return animatedColorAt(definition, timeSeconds)
	end
	return definition.TextColor or definition.Color
end

return Rarities
