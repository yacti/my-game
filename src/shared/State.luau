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
	EvolutionPathPetIds = "PetEvolutionPathPetIds",
	EvolutionPaused = "PetEvolutionPaused", -- client-local presentation pause
}

State.Player = {
	AssignedPlotName = "AssignedPlotName",
	OfflineProgressPending = "OfflineProgressPending",
	AFKRejoinPending = "AFKRejoinPending",
	SeedPacksAllowed = "SeedPacksAllowed",
	-- true while the profile's inventory is authoritative and the live
	-- backpack is not (session start / death, until re-materialization
	-- completes). Inventory-serializing writers must not run while set.
	InventoryRestorePending = "InventoryRestorePending",
	-- Client-visible mirror of profile onboarding (true while active, nil
	-- when complete) so other clients can hide cross-player interactions;
	-- never authority, the server re-resolves the profile.
	OnboardingActive = "OnboardingActive",
}

State.ServerLuck = {
	Multiplier = "ServerLuckMultiplier",
	EndsAt = "ServerLuckEndsAt",
}

-- Global admin luck boost (set through the live-events control plane);
-- additive on top of crate/player/server luck. Attributes on ReplicatedStorage.
State.AdminLuck = {
	Multiplier = "AdminLuckMultiplier",
	EndsAt = "AdminLuckEndsAt",
}

State.AdminPanel = {
	-- Player attribute set only by AdminPanelService (server command bar);
	-- clients read it to show/hide the owner admin panel. Never authority:
	-- every panel command is re-validated server-side.
	Enabled = "AdminPanelEnabled",
}

State.UpdateEvent = {
	EventId = "UpdateEventId",
}

State.GameEvent = {
	NextWeatherEventId = "NextWeatherEventId",
	NextWeatherStartsAt = "NextWeatherStartsAt",
	Revision = "GameEventRevision",
	EventId = "EventId",
	Layer = "Layer",
	Source = "Source",
	StartsAt = "StartsAt",
	EndsAt = "EndsAt",
	Priority = "Priority",
	DisplayPriority = "DisplayPriority",
	DisplayFrame = "DisplayFrame",
}

State.AdminMessage = {
	PresetId = "PresetId",
	Text = "Text",
	StartsAt = "StartsAt",
	EndsAt = "EndsAt",
}

State.UpdateLog = {
	Id = "UpdateLogId",
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
	MutationIds = "MutationIds",
	PrimaryMutationId = "PrimaryMutationId",
	StealReservationId = "FoodStealReservationId",
	StealReservationExpiresAt = "FoodStealReservationExpiresAt",
	-- Patch slot growth anchor (server clock, Workspace:GetServerTimeNow()).
	-- Slot XP is derived: XP + floor((now - GrowthStart) / GrowRate) * patchXP.
	-- Absent while a slot is frozen (offline progress pending) or respawning.
	GrowthStart = "FoodGrowthStart",
	-- Patch slot respawn anchor (wall clock, os.time()) published on SlotAnchor.
	RespawnAt = "FoodRespawnAt",
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
	CanOverlapFeed = "CanOverlapFeed",
}

State.TreeClicker = {
	GroundPile = "TreeClickerGroundPile",
	SlotIndex  = "TreeClickerSlotIndex",
	LocalVisual = "TreeClickerLocalVisual",
}

return State
