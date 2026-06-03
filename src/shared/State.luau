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
	EvolutionSeq = "PetEvolutionSeq",
	EvolutionOldPetId = "PetEvolutionOldPetId",
	EvolutionOldScale = "PetEvolutionOldScale",
	EvolutionPivot = "PetEvolutionPivot",
	EvolutionPaused = "PetEvolutionPaused", -- client-local presentation pause
}

State.Player = {
	AssignedPlotName = "AssignedPlotName",
}

State.Tool = {
	Guid = "ToolGuid",
}

State.Grid = {
	Unlocked = "GridUnlocked",
	Purchasable = "GridPurchasable",
	Visible = "GridVisible",
	Frontier = "GridFrontier",
	Price = "GridPrice",
}

State.Feed = {
	Type  = "FeedType",
	Index = "FeedIndex",
	Class = "FeedClass", -- broad behavior class, e.g. Patch, Processor, Tree
	Rarity = "Rarity", -- display-only rarity; roll odds use RollChanceN
	RollChanceN = "RollChanceN", -- roll odds denominator, e.g. 50 means base weight 1/50
	Price = "Price",
	Plot  = "Plot",

	-- Per-template tunables. Each FeedMachine template under
	-- ReplicatedStorage.Assets.FeedMachines.<Class>.<DisplayName> may set any of these
	-- as attributes; per-class modules read them with sensible defaults.
	FoodType        = "FoodType",        -- Processor: accepted food group/category
	FoodDrop        = "FoodDrop",        -- Tree/Patch: exact food id produced by the machine
	GrowRate        = "GrowRate",        -- Patch: seconds per XP interval
	ProcessDuration = "ProcessDuration", -- Processor: seconds to process each item
	XP              = "XP",              -- Processor/Tree multiplier; Patch XP per growth interval
	MaxQueue        = "MaxQueue",        -- Processor: queue capacity

	-- Server-published runtime state (clients can read for UI).
	QueueCount = "QueueCount", -- Processor
	ReadyCount = "ReadyCount", -- Processor
}

State.Food = {
	Id      = "FoodId",   -- exact template key, e.g. Pumpkin1
	Type    = "FoodType", -- broad group/category, e.g. Fruit
	XP      = "XP",
}

State.Seed = {
	Id = "SeedID",
	Phase = "SeedPhase",
	GrowEndAt = "SeedGrowEndAt",
	TargetDisplayName = "SeedTargetDisplayName",
}

State.TreeClicker = {
	GroundFolder = "TreeClickerGroundPiles",
	GroundPile = "TreeClickerGroundPile",
	SlotIndex  = "TreeClickerSlotIndex",
}

return State
