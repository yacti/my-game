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
	SeedLiftDuration = 0.5,
	SeedShakeDuration = 0.55,
	SeedShakeDegrees = 12,
	SeedExpandedScaleMultiplier = 2,
	SeedPopInScaleMultiplier = 0.82,
	SeedPopInDuration = 0.12,
	SeedPopOutDuration = 0.32,
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

function RollConfig.RollVisualDuration()
	local seedDuration = RollConfig.Reveal.SeedLiftDuration
		+ RollConfig.Reveal.SeedShakeDuration
		+ RollConfig.Reveal.SeedPopInDuration
		+ RollConfig.Reveal.SeedPopOutDuration
	local miscDuration = RollConfig.Reveal.MiscFadeInDuration + RollConfig.Reveal.MiscLiftDuration
	return RollConfig.Crate.FallDuration + math.max(seedDuration, miscDuration)
end

return RollConfig
