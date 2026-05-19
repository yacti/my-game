-- Attribute keys that the server writes onto replicated Instances and that
-- clients read to drive UI. Centralized so renames touch one file.
local State = {}

State.Pet = {
	Index     = "PetIndex",
	Id        = "PetID",
	XP        = "XP",
	MaxXP     = "MaxXP",
	Order     = "Order",
	Money     = "Money",
	MoneyRate = "MoneyRate",
	WalkSpeed = "PetWalkSpeed",
	MotionState = "PetMotionState",
	MotionSeq = "PetMotionSeq",
	SegmentData = "PetSegmentData",
	SegmentWalkSpeed = "PetSegmentWalkSpeed",
	SegmentStartTime = "PetSegmentStartTime",
	SegmentDuration = "PetSegmentDuration",
	SegmentStartLX = "PetSegmentStartLX",
	SegmentStartLZ = "PetSegmentStartLZ",
	SegmentStartLRY = "PetSegmentStartLRY",
	SegmentTargetLX = "PetSegmentTargetLX",
	SegmentTargetLZ = "PetSegmentTargetLZ",
	SegmentTargetLRY = "PetSegmentTargetLRY",
	SegmentNextLX = "PetSegmentNextLX",
	SegmentNextLZ = "PetSegmentNextLZ",
	SegmentCornerRadius = "PetSegmentCornerRadius",
	FeedReactionSeq = "PetFeedReactionSeq",
	FeedReactionStartTime = "PetFeedReactionStartTime",
	FeedReactionDuration = "PetFeedReactionDuration",
	FeedReactionDirection = "PetFeedReactionDirection",
	FeedReactionFaceLX = "PetFeedReactionFaceLX",
	FeedReactionFaceLZ = "PetFeedReactionFaceLZ",
	VisualBaseScale = "PetVisualBaseScale",
}

State.Player = {
	AssignedPlotName = "AssignedPlotName",
	PlotSize = "PlotSize",
}

State.Feed = {
	Type  = "FeedType",
	Index = "FeedIndex",
	Class = "FeedClass", -- broad behavior class, e.g. Clicker, Patch, Processor, Tree
	Plot  = "Plot",

	-- Per-template tunables. Each FeedMachine template under
	-- ReplicatedStorage.FeedMachines.<Class>.<DisplayName> may set any of these
	-- as attributes; per-class modules read them with sensible defaults.
	FoodType        = "FoodType",        -- class-specific: produced food id or accepted food group
	FoodDrop        = "FoodDrop",        -- Tree: food id dropped by each accepted click
	MaxFood         = "MaxFood",         -- Clicker: cap of unpicked food on the floor
	ClickCooldown   = "ClickCooldown",   -- Clicker: seconds between clicks
	MaxClicksPerSecond = "MaxClicksPerSecond", -- AppleTree: accepted clicks per second cap
	ProcessDuration = "ProcessDuration", -- Processor: seconds to process each item
	XPMultiplier    = "XPMultiplier",    -- Processor/AppleTree: multiplier on produced XP
	MaxQueue        = "MaxQueue",        -- Processor: queue capacity

	-- Shop tunables. Templates with InShop=true and all three required shop
	-- attributes are listed in the Market catalog.
	InShop         = "InShop",
	ShopPrice      = "ShopPrice",
	ShopRarityRate = "ShopRarityRate", -- percent chance from 0..100
	ShopStockRange = "ShopStockRange", -- NumberRange, per-player allowance per offer
	ShopRobuxProductId = "ShopRobuxProductId",
	ShopRobuxPrice     = "ShopRobuxPrice",

	-- Server-published runtime state (clients can read for UI).
	QueueCount = "QueueCount", -- Processor
	ReadyCount = "ReadyCount", -- Processor
}

State.Food = {
	Id   = "FoodId",   -- exact template key, e.g. Food1_Clicker
	Type = "FoodType", -- broad group/category, e.g. Fruit
	XP   = "XP",
}

State.TreeClicker = {
	GroundFolder = "TreeClickerGroundPiles",
	GroundPile = "TreeClickerGroundPile",
	SlotIndex  = "TreeClickerSlotIndex",
}

return State
