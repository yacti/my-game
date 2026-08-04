-- Single entry point for resolving RemoteEvents/RemoteFunctions so code never
-- types remote names as raw strings in more than one place. Remote instances
-- are declared in default.project.json and synced by Rojo; this module only
-- validates and resolves them so Studio-only duplicates fail loudly.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}
local cache = {}
local folder

Remotes.Names = {
	ProcessorDepositEffect = "ProcessorDepositEffect",
	TreeClickerEffect = "TreeClickerEffect",
	ThunderstormEffect = "ThunderstormEffect",
	TornadoEffect = "TornadoEffect",
	AlienEventEffect = "AlienEventEffect",
	TreeClickerRequest = "TreeClickerRequest",
	GridUnlockEffect = "GridUnlockEffect",
	AnimalAmbientSound = "AnimalAmbientSound",
	PetBillboardFeedEffect = "PetBillboardFeedEffect",
	CrateRollEffect = "CrateRollEffect",
	CrateRollPurchaseRequest = "CrateRollPurchaseRequest",
	CrateRollPurchaseResult = "CrateRollPurchaseResult",
	CrateRollOfferSyncRequest = "CrateRollOfferSyncRequest",
	AutoRollRequest = "AutoRollRequest",
	AutoRollState = "AutoRollState",
	AFKRejoinRequest = "AFKRejoinRequest",
	AFKRejoinRestore = "AFKRejoinRestore",
	RollLuckUpgradeRequest = "RollLuckUpgradeRequest",
	RollLuckUpgradeResult = "RollLuckUpgradeResult",
	RollDropAreaUpgradeRequest = "RollDropAreaUpgradeRequest",
	RollDropAreaUpgradeResult = "RollDropAreaUpgradeResult",
	GearShopPurchaseRequest = "GearShopPurchaseRequest",
	GearShopPurchaseResult = "GearShopPurchaseResult",
	CosmeticShopPurchaseRequest = "CosmeticShopPurchaseRequest",
	CosmeticShopPurchaseResult = "CosmeticShopPurchaseResult",
	SeedPackPurchaseResult = "SeedPackPurchaseResult",
	ApplyPetSkinRequest = "ApplyPetSkinRequest",
	ApplyPetSkinResult = "ApplyPetSkinResult",
	DurianPackRollRequest = "DurianPackRollRequest",
	DurianPackRollResult = "DurianPackRollResult",
	EndlessPackClaimRequest = "EndlessPackClaimRequest",
	EndlessPackClaimResult = "EndlessPackClaimResult",
	StarterPackPurchaseRequest = "StarterPackPurchaseRequest",
	StarterPackPurchaseResult = "StarterPackPurchaseResult",
	StarterPackPromptDismissRequest = "StarterPackPromptDismissRequest",
	FoodStealRequest = "FoodStealRequest",
	FoodStealResult = "FoodStealResult",
	FoodStealCancel = "FoodStealCancel",
	GrowSkipRequest = "GrowSkipRequest",
	GrowSkipResult = "GrowSkipResult",
	-- Client intent only, and deliberately argument-free: the server resolves
	-- the nearest pinata within reach itself. "Tap anywhere on screen" means
	-- the client cannot raycast a target on mobile, so accepting one would add
	-- a forgeable field for no benefit.
	PinataSwingRequest = "PinataSwingRequest",
	CollectAllRequest = "CollectAllRequest",
	CollectAllResult = "CollectAllResult",
	ServerLuckPurchaseRequest = "ServerLuckPurchaseRequest",
	ServerLuckPurchaseResult = "ServerLuckPurchaseResult",
	ServerLuckBoosted = "ServerLuckBoosted",
	AdminPanelCommandRequest = "AdminPanelCommandRequest",
	AdminPanelCommandResult = "AdminPanelCommandResult",
	-- Server -> client: one global leaderboard snapshot (board id + payload),
	-- fired on every refresh and on request. Client -> server: argument-free
	-- "send me the current boards", so a joiner does not stare at an empty
	-- board until the next 30s refresh.
	LeaderboardSync = "LeaderboardSync",
	LeaderboardSyncRequest = "LeaderboardSyncRequest",
	PlayerNotification = "PlayerNotification",
	UpdateLogClosed = "UpdateLogClosed",
	EventRsvpPromptRequest = "EventRsvpPromptRequest",
	EventRsvpPromptResult = "EventRsvpPromptResult",
	-- Server -> client: the collector is not in the group, so the client opens
	-- the native community join modal. Client -> server: argument-free "I just
	-- joined, collect now"; the server re-verifies membership itself and only
	-- honours it after it asked for that prompt.
	JoinGroupPrompt = "JoinGroupPrompt",
	JoinGroupRewardRequest = "JoinGroupRewardRequest",
	MediaRewardRedeemRequest = "MediaRewardRedeemRequest",
	MediaRewardRedeemResult = "MediaRewardRedeemResult",
	HomeTeleportRequest = "HomeTeleportRequest",
	EventTeleportRequest = "EventTeleportRequest",
	PlaceCosmetic = "PlaceCosmetic",
	PlaceCosmeticResult = "PlaceCosmeticResult",
	PlaceFeedMachine = "PlaceFeedMachine",
	PlaceFeedMachineResult = "PlaceFeedMachineResult",
	FeedEditModeRequest = "FeedEditModeRequest",
	FeedMoveRequest = "FeedMoveRequest",
	FeedMoveResult = "FeedMoveResult",
	ShovelDeleteRequest = "ShovelDeleteRequest",
	ShovelDeleteResult = "ShovelDeleteResult",
	JoinBackShowcaseRequest = "JoinBackShowcaseRequest",
	InventoryDeleteRequest = "InventoryDeleteRequest",
	InventoryDeleteResult = "InventoryDeleteResult",
	InventoryFavouriteRequest = "InventoryFavouriteRequest",
	InventoryFavouriteResult = "InventoryFavouriteResult",
	PromptInteract = "PromptInteract",
	PromptInteractEffect = "PromptInteractEffect",
	RebirthRequest = "RebirthRequest",
	RebirthResult = "RebirthResult",
	GiftRequest = "GiftRequest",
	GiftResult = "GiftResult",
	StormChaserDepositRequest = "StormChaserDepositRequest",
	StormChaserDepositResult = "StormChaserDepositResult",
	BeeEventEffect = "BeeEventEffect",
	BeeDepositRequest = "BeeDepositRequest",
	BeeDepositResult = "BeeDepositResult",
	AlienDepositRequest = "AlienDepositRequest",
	AlienDepositResult = "AlienDepositResult",
	PlayerSettingsUpdateRequest = "PlayerSettingsUpdateRequest",
	RollBroadcastEffect = "RollBroadcastEffect",
	SprinkleEventEffect = "SprinkleEventEffect",
	MerchantTradeRequest = "MerchantTradeRequest",
	MerchantTradeResult = "MerchantTradeResult",
}

local Definitions = {
	[Remotes.Names.ProcessorDepositEffect] = "RemoteEvent",
	[Remotes.Names.TreeClickerEffect] = "RemoteEvent",
	[Remotes.Names.ThunderstormEffect] = "RemoteEvent",
	[Remotes.Names.TornadoEffect] = "RemoteEvent",
	[Remotes.Names.AlienEventEffect] = "RemoteEvent",
	[Remotes.Names.TreeClickerRequest] = "RemoteEvent",
	[Remotes.Names.GridUnlockEffect] = "RemoteEvent",
	[Remotes.Names.AnimalAmbientSound] = "RemoteEvent",
	[Remotes.Names.PetBillboardFeedEffect] = "RemoteEvent",
	[Remotes.Names.CrateRollEffect] = "RemoteEvent",
	[Remotes.Names.CrateRollPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.CrateRollPurchaseResult] = "RemoteEvent",
	[Remotes.Names.CrateRollOfferSyncRequest] = "RemoteEvent",
	[Remotes.Names.AutoRollRequest] = "RemoteEvent",
	[Remotes.Names.AutoRollState] = "RemoteEvent",
	[Remotes.Names.AFKRejoinRequest] = "RemoteEvent",
	[Remotes.Names.AFKRejoinRestore] = "RemoteEvent",
	[Remotes.Names.RollLuckUpgradeRequest] = "RemoteEvent",
	[Remotes.Names.RollLuckUpgradeResult] = "RemoteEvent",
	[Remotes.Names.RollDropAreaUpgradeRequest] = "RemoteEvent",
	[Remotes.Names.RollDropAreaUpgradeResult] = "RemoteEvent",
	[Remotes.Names.GearShopPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.GearShopPurchaseResult] = "RemoteEvent",
	[Remotes.Names.CosmeticShopPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.CosmeticShopPurchaseResult] = "RemoteEvent",
	[Remotes.Names.SeedPackPurchaseResult] = "RemoteEvent",
	[Remotes.Names.ApplyPetSkinRequest] = "RemoteEvent",
	[Remotes.Names.ApplyPetSkinResult] = "RemoteEvent",
	[Remotes.Names.DurianPackRollRequest] = "RemoteEvent",
	[Remotes.Names.DurianPackRollResult] = "RemoteEvent",
	[Remotes.Names.EndlessPackClaimRequest] = "RemoteEvent",
	[Remotes.Names.EndlessPackClaimResult] = "RemoteEvent",
	[Remotes.Names.StarterPackPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.StarterPackPurchaseResult] = "RemoteEvent",
	[Remotes.Names.StarterPackPromptDismissRequest] = "RemoteEvent",
	[Remotes.Names.FoodStealRequest] = "RemoteEvent",
	[Remotes.Names.FoodStealResult] = "RemoteEvent",
	[Remotes.Names.FoodStealCancel] = "RemoteEvent",
	[Remotes.Names.GrowSkipRequest] = "RemoteEvent",
	[Remotes.Names.GrowSkipResult] = "RemoteEvent",
	[Remotes.Names.PinataSwingRequest] = "RemoteEvent",
	[Remotes.Names.CollectAllRequest] = "RemoteEvent",
	[Remotes.Names.CollectAllResult] = "RemoteEvent",
	[Remotes.Names.ServerLuckPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.ServerLuckPurchaseResult] = "RemoteEvent",
	[Remotes.Names.ServerLuckBoosted] = "RemoteEvent",
	[Remotes.Names.AdminPanelCommandRequest] = "RemoteEvent",
	[Remotes.Names.AdminPanelCommandResult] = "RemoteEvent",
	[Remotes.Names.LeaderboardSync] = "RemoteEvent",
	[Remotes.Names.LeaderboardSyncRequest] = "RemoteEvent",
	[Remotes.Names.PlayerNotification] = "RemoteEvent",
	[Remotes.Names.UpdateLogClosed] = "RemoteEvent",
	[Remotes.Names.EventRsvpPromptRequest] = "RemoteEvent",
	[Remotes.Names.EventRsvpPromptResult] = "RemoteEvent",
	[Remotes.Names.JoinGroupPrompt] = "RemoteEvent",
	[Remotes.Names.JoinGroupRewardRequest] = "RemoteEvent",
	[Remotes.Names.MediaRewardRedeemRequest] = "RemoteEvent",
	[Remotes.Names.MediaRewardRedeemResult] = "RemoteEvent",
	[Remotes.Names.HomeTeleportRequest] = "RemoteEvent",
	[Remotes.Names.EventTeleportRequest] = "RemoteEvent",
	[Remotes.Names.PlaceCosmetic] = "RemoteEvent",
	[Remotes.Names.PlaceCosmeticResult] = "RemoteEvent",
	[Remotes.Names.PlaceFeedMachine] = "RemoteEvent",
	[Remotes.Names.PlaceFeedMachineResult] = "RemoteEvent",
	[Remotes.Names.FeedEditModeRequest] = "RemoteEvent",
	[Remotes.Names.FeedMoveRequest] = "RemoteEvent",
	[Remotes.Names.FeedMoveResult] = "RemoteEvent",
	[Remotes.Names.ShovelDeleteRequest] = "RemoteEvent",
	[Remotes.Names.ShovelDeleteResult] = "RemoteEvent",
	[Remotes.Names.JoinBackShowcaseRequest] = "RemoteEvent",
	[Remotes.Names.InventoryDeleteRequest] = "RemoteEvent",
	[Remotes.Names.InventoryDeleteResult] = "RemoteEvent",
	[Remotes.Names.InventoryFavouriteRequest] = "RemoteEvent",
	[Remotes.Names.InventoryFavouriteResult] = "RemoteEvent",
	[Remotes.Names.PromptInteract] = "RemoteEvent",
	[Remotes.Names.PromptInteractEffect] = "RemoteEvent",
	[Remotes.Names.RebirthRequest] = "RemoteEvent",
	[Remotes.Names.RebirthResult] = "RemoteEvent",
	[Remotes.Names.GiftRequest] = "RemoteEvent",
	[Remotes.Names.GiftResult] = "RemoteEvent",
	[Remotes.Names.StormChaserDepositRequest] = "RemoteEvent",
	[Remotes.Names.StormChaserDepositResult] = "RemoteEvent",
	[Remotes.Names.BeeEventEffect] = "RemoteEvent",
	[Remotes.Names.BeeDepositRequest] = "RemoteEvent",
	[Remotes.Names.BeeDepositResult] = "RemoteEvent",
	[Remotes.Names.AlienDepositRequest] = "RemoteEvent",
	[Remotes.Names.AlienDepositResult] = "RemoteEvent",
	[Remotes.Names.PlayerSettingsUpdateRequest] = "RemoteEvent",
	[Remotes.Names.RollBroadcastEffect] = "RemoteEvent",
	[Remotes.Names.SprinkleEventEffect] = "RemoteEvent",
	[Remotes.Names.MerchantTradeRequest] = "RemoteEvent",
	[Remotes.Names.MerchantTradeResult] = "RemoteEvent",
}

local function getFolder()
	if folder then return folder end

	local matches = {}
	for _, child in ipairs(ReplicatedStorage:GetChildren()) do
		if child.Name == "Remotes" then
			table.insert(matches, child)
		end
	end

	assert(#matches == 1, string.format("Expected exactly one ReplicatedStorage.Remotes folder, found %d", #matches))
	assert(matches[1]:IsA("Folder"), string.format("ReplicatedStorage.Remotes is a %s", matches[1].ClassName))
	folder = matches[1]
	return folder
end

-- Two children sharing a remote name is not a cosmetic duplicate: name lookups
-- return whichever copy sorts first, and that order is resolved per DataModel.
-- Server and client can therefore bind opposite instances, so every request
-- vanishes into a remote nobody listens on and the caller only sees a timeout.
local function assertUnique(name)
	local matches = 0
	for _, child in ipairs(getFolder():GetChildren()) do
		if child.Name == name then
			matches += 1
		end
	end
	assert(matches == 1, string.format(
		"Expected exactly one ReplicatedStorage.Remotes.%s, found %d;"
			.. " delete the extra copies so client and server bind the same instance",
		name,
		matches
	))
end

function Remotes.get(name)
	assert(Definitions[name], string.format("Unknown remote %q", tostring(name)))

	local remote = cache[name]
	if not remote then
		remote = getFolder():WaitForChild(name)
		assert(remote.ClassName == Definitions[name], string.format(
			"%s exists but is a %s, expected %s",
			name,
			remote.ClassName,
			Definitions[name]
		))
		assertUnique(name)
		cache[name] = remote
	end
	return remote
end

local function ensure(name)
	local remote = cache[name]
	if remote then return remote end

	local existing = getFolder():FindFirstChild(name)
	if existing then
		assert(existing.ClassName == Definitions[name], string.format(
			"%s exists but is a %s, expected %s",
			name,
			existing.ClassName,
			Definitions[name]
		))
		assertUnique(name)
		cache[name] = existing
		return existing
	end

	error(string.format("Missing remote %q in ReplicatedStorage.Remotes; declare it in default.project.json", name))
end

-- Reported in one pass rather than through ensure(), so a place file carrying
-- several duplicated remotes names all of them instead of one per boot.
local function assertNoDuplicates()
	local counts = {}
	for _, child in ipairs(getFolder():GetChildren()) do
		counts[child.Name] = (counts[child.Name] or 0) + 1
	end

	local duplicates = {}
	for name, count in pairs(counts) do
		if count > 1 then
			table.insert(duplicates, string.format("%s (x%d)", name, count))
		end
	end
	table.sort(duplicates)

	assert(#duplicates == 0, string.format(
		"Duplicate remotes in ReplicatedStorage.Remotes: %s;"
			.. " name lookups resolve per DataModel, so client and server can bind opposite copies."
			.. " Delete the extras in Studio and re-sync Rojo",
		table.concat(duplicates, ", ")
	))
end

function Remotes.validateAll()
	assertNoDuplicates()
	for name in pairs(Definitions) do
		ensure(name)
	end
end

return Remotes
