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
	IsGolden  = "IsGolden",
	-- Display-only source blurb for Exclusive pets, e.g. "Bee Event"; shown in
	-- the Index info panel. Same attribute name as State.Feed.
	ExclusiveDescription = "ExclusiveDescription",
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
	-- Client-visible mirror of the acceptGifts setting (true while gifts are
	-- refused, nil while accepted) so giver clients can hide gift prompts;
	-- never authority, GiftService re-resolves the profile.
	AcceptGiftsDisabled = "AcceptGiftsDisabled",
	-- Experiment variant for the skip-time purchase station ("mailbox" or
	-- "sign"), resolved per player by SkipTimeStationService from the
	-- SkipTimeStation config key. nil / unset means the "mailbox" control.
	SkipTimeStation = "SkipTimeStation",
	-- Experiment variant for food-steal pricing ("normal" or "tiered"),
	-- resolved per player by StealSettingService from the StealSetting config
	-- key. nil / unset means the "normal" control.
	StealSetting = "StealSetting",
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

-- Admin-spawned pinatas. Server writes these onto the live pinata Model (and
-- onto each dropped PhysicalRewards part) in Workspace; clients read them to
-- render the health bar, the phase-locked drop-in, and their own drop icons.
-- HP is server-wide truth and is never mutated client-side.
State.Pinata = {
	Id = "PinataId",
	Variant = "PinataVariant",
	Hp = "PinataHp",
	MaxHp = "PinataMaxHp",
	-- Workspace:GetServerTimeNow() at spawn. The drop animation is derived from
	-- this rather than from ChildAdded, so stream-in never replays the fall.
	DropAt = "PinataDropAt",
	ExpiresAt = "PinataExpiresAt",
	-- Per-drop: which player it belongs to, which reward it is, where it burst
	-- from, and when it landed (clients animate the arc from these).
	DropOwner = "PinataDropOwner",
	DropReward = "PinataDropReward",
	DropOrigin = "PinataDropOrigin",
	DropSpawnedAt = "PinataDropSpawnedAt",
}

State.UpdateEvent = {
	EventId = "UpdateEventId",
	TimerTextMode = "UpdateTimerTextMode",
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
	Favourite = "ToolFavourite",
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
	-- Display-only source blurb for Exclusive machines, e.g. "Bee Event";
	-- shown in the Index info panel.
	ExclusiveDescription = "ExclusiveDescription",
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
	PercentageOfBest = "PercentageOfBest", -- Tree/Patch: resolved XP = pct x best same-class static machine XP on the plot (min 1); replaces XP on the template
	XPMultiplier    = "XPMultiplier",    -- Processor/JamBarrel multiplier applied to deposited food XP
	MaxQueue        = "MaxQueue",        -- Processor: queue capacity
	JumpSeconds     = "JumpSeconds",     -- Scarecrow: seconds between jumps (global clock boundary)
	JumpRadius      = "JumpRadius",      -- Scarecrow: tree-shake radius in studs

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
