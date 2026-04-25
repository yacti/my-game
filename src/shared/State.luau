-- Attribute keys that the server writes onto replicated Instances and that
-- clients read to drive UI. Centralized so renames touch one file.
local State = {}

State.Pet = {
	Index     = "PetIndex",
	Type      = "PetType",
	XP        = "XP",
	Money     = "Money",
	MoneyRate = "MoneyRate",
}

State.Feed = {
	Type  = "FeedType",
	Index = "FeedIndex",
	Class = "FeedClass",
	Plot  = "Plot",

	-- Per-template tunables. Each FeedMachine template under
	-- ReplicatedStorage.FeedMachines.<Class>.<Name> may set any of these
	-- as attributes; per-class modules read them with sensible defaults.
	FoodType        = "FoodType",        -- all classes: which food to produce/accept
	MaxFood         = "MaxFood",         -- Clicker, Timed: cap of unpicked food on the floor
	ClickCooldown   = "ClickCooldown",   -- Clicker: seconds between clicks
	SpawnInterval   = "SpawnInterval",   -- Timed: seconds between spawns
	ProcessDuration = "ProcessDuration", -- Processor: seconds to process each item
	XPMultiplier    = "XPMultiplier",    -- Processor: multiplier on dispensed food XP
	MaxQueue        = "MaxQueue",        -- Processor: queue capacity

	-- Server-published runtime state (clients can read for UI).
	QueueCount = "QueueCount", -- Processor
	ReadyCount = "ReadyCount", -- Processor
}

State.Food = {
	Type = "FoodType",
	XP   = "XP",
}

return State
