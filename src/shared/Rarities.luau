local Rarities = {}

Rarities.Common = "Common"
Rarities.Rare = "Rare"
Rarities.Epic = "Epic"
Rarities.Legendary = "Legendary"
Rarities.Mythical = "Mythical"
Rarities.Secret = "Secret"
Rarities.Exclusive = "Exclusive"

Rarities.Order = {
	Rarities.Common,
	Rarities.Rare,
	Rarities.Epic,
	Rarities.Legendary,
	Rarities.Mythical,
	Rarities.Secret,
	Rarities.Exclusive,
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
		Color = Color3.fromRGB(0, 236, 255),
		Animated = true,
		-- Colour-stop loop instead of the Mythical rainbow cycle: each entry
		-- tweens to the next, and the last wraps back to the first.
		TweenColors = {
			Color3.fromRGB(255, 255, 255),
			Color3.fromRGB(0, 236, 255),
			Color3.fromRGB(0, 45, 255),
			Color3.fromRGB(0, 236, 255),
		},
		TweenPeriod = 4,
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
		local progress = (((tonumber(timeSeconds) or 0) / period) % 1) * #colors
		local index = math.floor(progress) + 1
		local from = colors[index]
		local to = colors[index % #colors + 1]
		-- Cosine-ease each segment so stops don't produce visible kinks.
		local alpha = 0.5 - 0.5 * math.cos((progress - (index - 1)) * math.pi)
		return from:Lerp(to, alpha)
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
