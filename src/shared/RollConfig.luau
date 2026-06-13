local RollConfig = {}

RollConfig.Crate = {
	StartHeight = 20,
	FallDuration = 2.55,
	SwayAmplitude = 1.35,
	TiltDegrees = 8,
	ImpactChunkCount = 14,
	ImpactChunkSize = Vector3.new(1, 1, 1),
	ImpactChunkLifetime = 0.75,
	ImpactChunkFadeDuration = 0.25,
	ImpactChunkMinSpread = 1.5,
	ImpactChunkMaxSpread = 6.5,
	ImpactChunkMinSpeed = 10,
	ImpactChunkMaxSpeed = 18,
	BreakFadeDuration = 0.12,
}

RollConfig.Reveal = {
	SeedDefaultScale = 1.02,
	SeedLiftHeight = 2,
	SeedShakeDegrees = 12,
	SeedPreviewCountOptions = { 1, 2, 3, 4 },
	SeedPreviewDuration = 0.75,
	SeedRevealFadeDuration = 0.2,
	SeedRareTeaseChance = 0.05,
	SeedRareTeaseWeights = {
		Legendary = 50,
		Mythical = 30,
		Secret = 20,
	},
	SeedExpandedScaleMultiplier = 2,
	MiscStartScale = 0.1,
	MiscDefaultScale = 1,
	MiscFadeInDuration = 0.25,
	MiscLiftHeight = 2,
	MiscLiftDuration = 0.45,
	IdleBobHeight = 0.35,
	IdleBobPeriod = 2,
	IdleRotationDegreesPerSecond = 35,
	ActiveVfxDistance = 60,
	LocalParticleLifetime = 15,
	BuyPromptDistance = 10,
	OfferAnchorTopOffset = 0.55,
}

RollConfig.Button = {
	InteractionDistance = 8,
	PressDuration = 0.08,
	ReleaseDuration = 0.16,
	UnavailableColor = Color3.fromRGB(220, 45, 45),
}

function RollConfig.MaxSeedPreviewCount()
	local maxCount = 0
	for _, count in ipairs(RollConfig.Reveal.SeedPreviewCountOptions or {}) do
		count = tonumber(count)
		if type(count) == "number" and count == count and math.abs(count) < math.huge then
			maxCount = math.max(maxCount, math.floor(count))
		end
	end
	return maxCount
end

function RollConfig.SeedPreviewTotalDuration(previewCount)
	previewCount = tonumber(previewCount)
	if type(previewCount) ~= "number" or previewCount ~= previewCount or math.abs(previewCount) == math.huge then
		previewCount = RollConfig.MaxSeedPreviewCount()
	end
	previewCount = math.max(math.floor(previewCount), 0)
	return previewCount * RollConfig.Reveal.SeedPreviewDuration
end

function RollConfig.SeedRollVisualDuration(previewCount)
	local seedDuration = RollConfig.SeedPreviewTotalDuration(previewCount)
		+ RollConfig.Reveal.SeedPreviewDuration
		+ RollConfig.Reveal.SeedRevealFadeDuration
	return RollConfig.Crate.FallDuration + seedDuration
end

function RollConfig.MiscRollVisualDuration()
	local miscDuration = RollConfig.Reveal.MiscFadeInDuration + RollConfig.Reveal.MiscLiftDuration
	return RollConfig.Crate.FallDuration + miscDuration
end

function RollConfig.RollVisualDurationForOffers(offers)
	local seedPreviewCount = nil
	if type(offers) == "table" then
		for _, offer in ipairs(offers) do
			if type(offer) == "table" and offer.category == "Seed" then
				local previewCount = type(offer.previewSeeds) == "table" and #offer.previewSeeds or RollConfig.MaxSeedPreviewCount()
				seedPreviewCount = math.max(seedPreviewCount or 0, previewCount)
			end
		end
	end
	if seedPreviewCount ~= nil then
		return RollConfig.SeedRollVisualDuration(seedPreviewCount)
	end
	return RollConfig.MiscRollVisualDuration()
end

function RollConfig.RollVisualDuration()
	return math.max(RollConfig.SeedRollVisualDuration(RollConfig.MaxSeedPreviewCount()), RollConfig.MiscRollVisualDuration())
end

return RollConfig
