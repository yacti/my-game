return {
	FeedType = "CherryTree",
	WarnPrefix = "CherryTree",

	-- Reuses the current clicker food chain. Cherry-specific food ids can be
	-- swapped in here later without changing the shared tree-clicker logic.
	Chain = {
		"Food1_Clicker",
		"Food2_Clicker",
		"Food3_Clicker",
		"Food4_Clicker",
		"Food5_Clicker",
		"Food6_Clicker",
		"Food7_Clicker",
		"Food8_Clicker",
		"Food9_Clicker",
		"Food10_Clicker",
	},

	DefaultMaxClicksPerSecond = 5,
	SlotRespawn = 1,
	DropEffectDuration = 0.45,
	EffectRadius = 75,
}
