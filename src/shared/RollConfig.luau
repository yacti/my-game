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
}

RollConfig.Reveal = {
	InitialScale = 0.2,
	FinalScale = 0.34,
	FlickerCount = 7,
	FlickerStartDuration = 0.2,
	FlickerEndDuration = 0.4,
	FlickerStartScale = 0.08,
	FlickerEndScale = 0.22,
	PopDuration = 0.45,
	BuyPromptDistance = 10,
	BillboardMaxDistance = 25,
	OfferAnchorTopOffset = 0.55,
}

RollConfig.Button = {
	PressDuration = 0.08,
	ReleaseDuration = 0.16,
	UnavailableColor = Color3.fromRGB(220, 45, 45),
}

function RollConfig.FlickerStepDuration(index, count)
	count = math.max(math.floor(tonumber(count) or RollConfig.Reveal.FlickerCount), 1)
	index = math.clamp(math.floor(tonumber(index) or 1), 1, count)

	local progress = count > 1 and (index - 1) / (count - 1) or 1
	return RollConfig.Reveal.FlickerStartDuration
		+ (RollConfig.Reveal.FlickerEndDuration - RollConfig.Reveal.FlickerStartDuration) * (progress ^ 1.7)
end

function RollConfig.RollVisualDuration()
	local duration = RollConfig.Crate.FallDuration
	for index = 1, RollConfig.Reveal.FlickerCount do
		duration += RollConfig.FlickerStepDuration(index, RollConfig.Reveal.FlickerCount)
	end
	duration += RollConfig.Reveal.PopDuration
	return duration
end

return RollConfig
