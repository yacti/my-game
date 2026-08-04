local PlayerState = {}

PlayerState.Token = "PlayerState"

PlayerState.Fields = {
	ProfileReady = "ProfileReady",
	Currency = "Currency",
	-- Replicated for the TopRolls board's YourStat label, which must update the
	-- moment a roll lands rather than waiting on the 30s board refresh.
	LifetimeCrateRolls = "LifetimeCrateRolls",
	Rebirths = "Rebirths",
	RollLuckLevel = "RollLuckLevel",
	RollDropAreaLevel = "RollDropAreaLevel",
	AutoRollSettings = "AutoRollSettings",
	PlayerSettings = "PlayerSettings",
	CosmeticInventory = "CosmeticInventory",
	PetSkinInventory = "PetSkinInventory",
	FeedInventory = "FeedInventory",
	SeedInventory = "SeedInventory",
	FoodInventory = "FoodInventory",
	UnlockedGridKeys = "UnlockedGridKeys",
	Onboarding = "Onboarding",
	StarterPackPurchased = "StarterPackPurchased",
	DurianTickets = "DurianTickets",
	DurianPackPity = "DurianPackPity",
	EndlessPackProgress = "EndlessPackProgress",
	StormChaser = "StormChaser",
	BeeEvent = "BeeEvent",
	AlienStand = "AlienStand",
	TravellingMerchant = "TravellingMerchant",
	StarterPackPurchases = "StarterPackPurchases",
	StarterPackPromptDismissed = "StarterPackPromptDismissed",
	GamePassOwnership = "GamePassOwnership",
	VipOwned = "VipOwned",
	FriendBoostPercent = "FriendBoostPercent",
	HourlyPetIncome = "HourlyPetIncome",
	JoinBackShowcase = "JoinBackShowcase",
	JoinGroupRewardCollected = "JoinGroupRewardCollected",
	MediaRewardCollected = "MediaRewardCollected",
	LastSeenUpdateLogId = "LastSeenUpdateLogId",
	LastPromptedEventId = "LastPromptedEventId",
	Discovered = "Discovered",
}

return PlayerState
