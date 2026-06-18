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
	TreeClickerRequest = "TreeClickerRequest",
	PlotWindEffect = "PlotWindEffect",
	GridUnlockEffect = "GridUnlockEffect",
	AnimalAmbientSound = "AnimalAmbientSound",
	CrateRollEffect = "CrateRollEffect",
	CrateRollPurchaseRequest = "CrateRollPurchaseRequest",
	CrateRollPurchaseResult = "CrateRollPurchaseResult",
	AutoRollRequest = "AutoRollRequest",
	AutoRollState = "AutoRollState",
	RollLuckUpgradeRequest = "RollLuckUpgradeRequest",
	RollLuckUpgradeResult = "RollLuckUpgradeResult",
	RollDropAreaUpgradeRequest = "RollDropAreaUpgradeRequest",
	RollDropAreaUpgradeResult = "RollDropAreaUpgradeResult",
	GearShopPurchaseRequest = "GearShopPurchaseRequest",
	GearShopPurchaseResult = "GearShopPurchaseResult",
	CosmeticShopPurchaseRequest = "CosmeticShopPurchaseRequest",
	CosmeticShopPurchaseResult = "CosmeticShopPurchaseResult",
	SeedPackPurchaseResult = "SeedPackPurchaseResult",
	StarterPackPurchaseRequest = "StarterPackPurchaseRequest",
	StarterPackPurchaseResult = "StarterPackPurchaseResult",
	FoodStealRequest = "FoodStealRequest",
	FoodStealResult = "FoodStealResult",
	FoodStealCancel = "FoodStealCancel",
	GrowSkipRequest = "GrowSkipRequest",
	GrowSkipResult = "GrowSkipResult",
	ServerLuckPurchaseRequest = "ServerLuckPurchaseRequest",
	ServerLuckPurchaseResult = "ServerLuckPurchaseResult",
	ServerLuckBoosted = "ServerLuckBoosted",
	PlayerNotification = "PlayerNotification",
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
	PromptInteract = "PromptInteract",
	RebirthRequest = "RebirthRequest",
	RebirthResult = "RebirthResult",
}

local Definitions = {
	[Remotes.Names.ProcessorDepositEffect] = "RemoteEvent",
	[Remotes.Names.TreeClickerEffect] = "RemoteEvent",
	[Remotes.Names.TreeClickerRequest] = "RemoteEvent",
	[Remotes.Names.PlotWindEffect] = "RemoteEvent",
	[Remotes.Names.GridUnlockEffect] = "RemoteEvent",
	[Remotes.Names.AnimalAmbientSound] = "RemoteEvent",
	[Remotes.Names.CrateRollEffect] = "RemoteEvent",
	[Remotes.Names.CrateRollPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.CrateRollPurchaseResult] = "RemoteEvent",
	[Remotes.Names.AutoRollRequest] = "RemoteEvent",
	[Remotes.Names.AutoRollState] = "RemoteEvent",
	[Remotes.Names.RollLuckUpgradeRequest] = "RemoteEvent",
	[Remotes.Names.RollLuckUpgradeResult] = "RemoteEvent",
	[Remotes.Names.RollDropAreaUpgradeRequest] = "RemoteEvent",
	[Remotes.Names.RollDropAreaUpgradeResult] = "RemoteEvent",
	[Remotes.Names.GearShopPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.GearShopPurchaseResult] = "RemoteEvent",
	[Remotes.Names.CosmeticShopPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.CosmeticShopPurchaseResult] = "RemoteEvent",
	[Remotes.Names.SeedPackPurchaseResult] = "RemoteEvent",
	[Remotes.Names.StarterPackPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.StarterPackPurchaseResult] = "RemoteEvent",
	[Remotes.Names.FoodStealRequest] = "RemoteEvent",
	[Remotes.Names.FoodStealResult] = "RemoteEvent",
	[Remotes.Names.FoodStealCancel] = "RemoteEvent",
	[Remotes.Names.GrowSkipRequest] = "RemoteEvent",
	[Remotes.Names.GrowSkipResult] = "RemoteEvent",
	[Remotes.Names.ServerLuckPurchaseRequest] = "RemoteEvent",
	[Remotes.Names.ServerLuckPurchaseResult] = "RemoteEvent",
	[Remotes.Names.ServerLuckBoosted] = "RemoteEvent",
	[Remotes.Names.PlayerNotification] = "RemoteEvent",
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
	[Remotes.Names.PromptInteract] = "RemoteEvent",
	[Remotes.Names.RebirthRequest] = "RemoteEvent",
	[Remotes.Names.RebirthResult] = "RemoteEvent",
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
		cache[name] = existing
		return existing
	end

	error(string.format("Missing remote %q in ReplicatedStorage.Remotes; declare it in default.project.json", name))
end

function Remotes.validateAll()
	for name in pairs(Definitions) do
		ensure(name)
	end
end

return Remotes
