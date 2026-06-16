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
	Nickname  = "PetNickname",
	NicknameColor = "PetNicknameColor",
	Rarity    = "Rarity",
	WalkSpeed = "PetWalkSpeed",
	MotionState = "PetMotionState",
	SegmentData = "PetSegmentData",
	SegmentWalkSpeed = "PetSegmentWalkSpeed",
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
	OfflineProgressPending = "OfflineProgressPending",
	SeedPacksAllowed = "SeedPacksAllowed",
}

State.ServerLuck = {
	Multiplier = "ServerLuckMultiplier",
	EndsAt = "ServerLuckEndsAt",
}

State.UpdateEvent = {
	EventId = "UpdateEventId",
}

State.Tool = {
	Guid = "ToolGuid",
	Rarity = "Rarity",
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
	Rarity = "ItemRarity", -- display-only feed-machine rarity; roll odds use RollChanceN
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
	XP              = "XP",              -- Tree multiplier; Patch XP per growth interval
	XPMultiplier    = "XPMultiplier",    -- Processor/JamBarrel multiplier applied to deposited food XP
	MaxQueue        = "MaxQueue",        -- Processor: queue capacity

	-- Server-published runtime state (clients can read for UI).
	QueueCount = "QueueCount", -- Processor
	ReadyCount = "ReadyCount", -- Processor
	QueueReadyAt = "QueueReadyAt", -- Processor/JamBarrel: wall-clock time when full queue is ready
}

State.Food = {
	Id      = "FoodId",   -- exact template key, e.g. Pumpkin1
	Type    = "FoodType", -- broad group/category, e.g. Fruit
	XP      = "XP",
	StealReservationId = "FoodStealReservationId",
	StealReservationExpiresAt = "FoodStealReservationExpiresAt",
	-- Patch slot growth anchor (server clock, Workspace:GetServerTimeNow()).
	-- Slot XP is derived: XP + floor((now - GrowthStart) / GrowRate) * patchXP.
	-- Absent while a slot is frozen (offline progress pending) or respawning.
	GrowthStart = "FoodGrowthStart",
	JamProducerFeedType = "JamProducerFeedType",
	JamSourceFoodId = "JamSourceFoodId",
}

State.Seed = {
	Id = "SeedID",
	Phase = "SeedPhase",
	GrowEndAt = "SeedGrowEndAt",
	TargetDisplayName = "SeedTargetDisplayName",
}

State.Cosmetic = {
	Id = "CosmeticID",
	Index = "CosmeticIndex",
	Rarity = "Rarity",
}

State.TreeClicker = {
	GroundPile = "TreeClickerGroundPile",
	SlotIndex  = "TreeClickerSlotIndex",
	LocalVisual = "TreeClickerLocalVisual",
}

return State
