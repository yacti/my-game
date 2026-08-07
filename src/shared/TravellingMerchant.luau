-- The Travelling Merchant: a scheduled world event (GameEvents.Ids.Merchant)
-- that parks a carriage in the map for ten minutes every hour. Players walk
-- into the MerchantShop volume, the TravellingMerchant menu opens, and three
-- offers are shown -- one drawn from each of three independent pools. A trade
-- costs items out of the player's inventory; a per-slot DevProduct grants the
-- reward outright without taking anything.
--
-- The template (NPC + carriage + trigger part) is authored in place under
-- ReplicatedStorage.Assets.GameEvents, so the runtime clone into Workspace.Map
-- keeps its authored CFrames and needs no spawn marker -- the same arrangement
-- MrAlienEvent uses.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Assets = require(script.Parent:WaitForChild("Assets"))
local RewardIcons = require(script.Parent:WaitForChild("RewardIcons"))

local TravellingMerchant = {}

-- Master switch: false retires the merchant -- the scheduler stops producing
-- records and the server refuses trades -- without tearing out the feature or
-- player progress.
TravellingMerchant.Enabled = true

-- Instance names, all authored in Studio.
TravellingMerchant.AssetsFolderName = Assets.Names.GameEvents
TravellingMerchant.TemplateName = "MerchantEvent"
TravellingMerchant.MapFolderName = "Map"
TravellingMerchant.ShopPartName = "MerchantShop"
TravellingMerchant.CarriageName = "carriage"
TravellingMerchant.NpcName = "R6"
TravellingMerchant.BillboardName = "TravellingMerchantUI"
TravellingMerchant.BillboardFrameName = "Frame"
TravellingMerchant.BillboardTimerName = "LeavingIn"

-- ReplicatedStorage.UI.Menu.TravellingMerchant.
TravellingMerchant.PanelName = "TravellingMerchant"
TravellingMerchant.OfferTemplateName = "OfferTemplate"

-- Handed to SeedPackShopController.EnqueueReveal so a pack won from the
-- merchant reopens the merchant panel afterwards rather than the Robux shop.
TravellingMerchant.RevealSourceSection = "TravellingMerchant"

TravellingMerchant.RewardKinds = {
	Seed = "Seed",
	SeedPack = "SeedPack",
	GrowSkip = "GrowSkip",
	DurianTicket = "DurianTicket",
	Cash = "Cash",
}

local Kinds = TravellingMerchant.RewardKinds

-- One pool per offer slot. Exactly one entry per pool is live at a time, and
-- the same three are live on every server for a given hour (see OffersFor).
--
-- offerId is the durable key: it is what the profile records as claimed and
-- what the client sends back, so renaming one resets nothing but does orphan
-- any in-flight claim for that hour. Keep them stable.
--
TravellingMerchant.Pools = {
	{ -- Offer 1
		{
			offerId = "AppleCash30m",
			request = { foodId = "Apple", amount = 18 },
			reward = {
				kind = Kinds.Cash,
				hoursOfIncome = 0.5,
				baseReward = 2500,
				icon = RewardIcons.Cash,
			},
		},
		{
			offerId = "CherryMushroomSeed",
			request = { foodId = "Cherry", amount = 27 },
			reward = { kind = Kinds.Seed, seedId = "MushroomSeed", amount = 1 },
		},
		{
			offerId = "PotatoWatermelonSeeds",
			request = { foodId = "Potato", amount = 9 },
			reward = { kind = Kinds.Seed, seedId = "WatermelonSeed", amount = 3 },
		},
		{
			offerId = "MushroomSkip5m",
			request = { foodId = "Mushroom", amount = 4 },
			reward = { kind = Kinds.GrowSkip, skipId = "Skip5m", amount = 1 },
		},
		{
			offerId = "CornSeedPack",
			request = { foodId = "Corn", amount = 5 },
			reward = { kind = Kinds.SeedPack, packId = "SeedPack", amount = 1 },
		},
		{
			offerId = "CabbageCash30m",
			request = { foodId = "Cabbage", amount = 3 },
			reward = {
				kind = Kinds.Cash,
				hoursOfIncome = 0.5,
				baseReward = 2500,
				icon = RewardIcons.Cash,
			},
		},
		{
			offerId = "OrangeCherryTreeSeed",
			request = { foodId = "Orange", amount = 8 },
			reward = { kind = Kinds.Seed, seedId = "CherryTreeSeed", amount = 1 },
		},
	},
	{ -- Offer 2
		{
			offerId = "BananaPineappleSeed",
			request = { foodId = "Banana", amount = 8 },
			reward = { kind = Kinds.Seed, seedId = "PineappleSeed", amount = 1 },
		},
		{
			offerId = "FigPurpleShroomSeed",
			request = { foodId = "Fig", amount = 19 },
			reward = { kind = Kinds.Seed, seedId = "PurpleShroomSeed", amount = 1 },
		},
		{
			offerId = "BloodOrangePurpleShroomSeed",
			request = { foodId = "BloodOrange", amount = 5 },
			reward = { kind = Kinds.Seed, seedId = "PurpleShroomSeed", amount = 1 },
		},
		{
			offerId = "PricklyPearCactusSeed",
			request = { foodId = "PricklyPear", amount = 4 },
			reward = { kind = Kinds.Seed, seedId = "CactusSeed", amount = 1 },
		},
		{
			offerId = "PurpleShroomBloodOrangeTreeSeed",
			request = { foodId = "PurpleShroom", amount = 12 },
			reward = { kind = Kinds.Seed, seedId = "BloodOrangeTreeSeed", amount = 1 },
		},
		{
			offerId = "FigDoubleSkip5m",
			request = { foodId = "Fig", amount = 22 },
			reward = { kind = Kinds.GrowSkip, skipId = "Skip5m", amount = 2 },
		},
		{
			offerId = "PricklyPearCash90m",
			request = { foodId = "PricklyPear", amount = 10 },
			reward = {
				kind = Kinds.Cash,
				hoursOfIncome = 1.5,
				baseReward = 7500,
				icon = RewardIcons.CashLarge,
			},
		},
		{
			offerId = "BloodOrangeEpicSeedPack",
			request = { foodId = "BloodOrange", amount = 12 },
			reward = { kind = Kinds.SeedPack, packId = "EpicSeedPack", amount = 1 },
		},
		{
			offerId = "PurpleShroomSkip30m",
			request = { foodId = "PurpleShroom", amount = 10 },
			reward = { kind = Kinds.GrowSkip, skipId = "Skip30m", amount = 1 },
		},
	},
	{ -- Offer 3
		{
			offerId = "GlowshroomTripleSkip5m",
			request = { foodId = "Glowshroom", amount = 6 },
			reward = { kind = Kinds.GrowSkip, skipId = "Skip5m", amount = 3 },
		},
		{
			offerId = "GoldshroomSecretSeedPack",
			request = { foodId = "Goldshroom", amount = 3 },
			reward = { kind = Kinds.SeedPack, packId = "SecretSeedPack", amount = 1 },
		},
		{
			offerId = "GoldenPricklyPearGoldenAppleTreeSeed",
			request = { foodId = "GoldenPricklyPear", amount = 12 },
			reward = { kind = Kinds.Seed, seedId = "GoldenAppleTreeSeed", amount = 1 },
		},
		{
			offerId = "DragonfruitGlowshroomSeed",
			request = { foodId = "Dragonfruit", amount = 52 },
			reward = { kind = Kinds.Seed, seedId = "GlowshroomSeed", amount = 1 },
		},
		{
			offerId = "GoldenFigSkip30m",
			request = { foodId = "GoldenFig", amount = 43 },
			reward = { kind = Kinds.GrowSkip, skipId = "Skip30m", amount = 1 },
		},
		{
			offerId = "DurianEpicSeedPack",
			request = { foodId = "Durian", amount = 19 },
			reward = { kind = Kinds.SeedPack, packId = "EpicSeedPack", amount = 1 },
		},
		{
			offerId = "GlowshroomCash90m",
			request = { foodId = "Glowshroom", amount = 23 },
			reward = {
				kind = Kinds.Cash,
				hoursOfIncome = 1.5,
				baseReward = 7500,
				icon = RewardIcons.CashLarge,
			},
		},
		{
			offerId = "GoldenmelonCash90m",
			request = { foodId = "Goldenmelon", amount = 8 },
			reward = {
				kind = Kinds.Cash,
				hoursOfIncome = 1.5,
				baseReward = 7500,
				icon = RewardIcons.CashLarge,
			},
		},
	},
}

TravellingMerchant.OfferSlots = #TravellingMerchant.Pools

local offersById = {}
for _, pool in ipairs(TravellingMerchant.Pools) do
	for _, offer in ipairs(pool) do
		offersById[offer.offerId] = offer
	end
end

-- Every offerId that exists in any pool, live this hour or not. Used when
-- loading a profile so a claim for a retired offer is dropped instead of
-- sitting in the save forever.
function TravellingMerchant.IsKnownOfferId(offerId)
	return type(offerId) == "string" and offersById[offerId] ~= nil
end

-- Offer selection is global: every server rolls the same three offers for a
-- given hour, with no messaging between them.
--
-- That works because the merchant is a cadence-scheduled event, so every server
-- independently derives the same startsAt from the synced server clock. Hashing
-- that one number is therefore enough to agree. The hash must stay a pure
-- function of startsAt -- no Random.new(os.time()), no os.clock(), nothing that
-- reads machine state -- or servers silently disagree and players compare
-- different offers.
--
-- MINSTD (Lehmer) with a salt per slot so the three pools draw independently.
-- Every intermediate product stays under 2^53, so this is exact in doubles on
-- every client and server rather than drifting on rounding.
local HASH_MODULUS = 2147483647
local HASH_MULTIPLIER = 16807
local SLOT_SALT = 104729

local function mix(value)
	value = (value * 92821 + 48271) % HASH_MODULUS
	return (value * HASH_MULTIPLIER) % HASH_MODULUS
end

local function slotIndexFor(startsAt)
	startsAt = tonumber(startsAt)
	if startsAt == nil or startsAt ~= startsAt or startsAt == math.huge or startsAt == -math.huge then
		return 0
	end
	-- Cadence is hourly, so the hour index is the identity of a visit. Kept
	-- modest and non-negative so the products above stay exact.
	return math.max(math.floor(startsAt / 3600), 0)
end

-- Returns the array of live offers, one per slot, in slot order. Pure: the same
-- startsAt always yields the same offers.
function TravellingMerchant.OffersFor(startsAt)
	local slotIndex = slotIndexFor(startsAt)
	local offers = {}
	for poolIndex, pool in ipairs(TravellingMerchant.Pools) do
		local size = #pool
		if size > 0 then
			local roll = mix(slotIndex + poolIndex * SLOT_SALT)
			offers[poolIndex] = pool[(roll % size) + 1]
		end
	end
	return offers
end

-- Resolves an offerId against a specific hour's roll. Returns nil when the id
-- is unknown or belongs to a different hour, which is what stops a client
-- replaying last hour's cheaper offer.
function TravellingMerchant.OfferFor(startsAt, offerId)
	if type(offerId) ~= "string" or offerId == "" then
		return nil
	end
	for slot, offer in ipairs(TravellingMerchant.OffersFor(startsAt)) do
		if offer.offerId == offerId then
			return offer, slot
		end
	end
	return nil
end

function TravellingMerchant.FindTemplate()
	local assets = ReplicatedStorage:FindFirstChild(Assets.FolderName)
	local gameEvents = assets and assets:FindFirstChild(TravellingMerchant.AssetsFolderName)
	return gameEvents and gameEvents:FindFirstChild(TravellingMerchant.TemplateName) or nil
end

function TravellingMerchant.FindMapFolder()
	return Workspace:FindFirstChild(TravellingMerchant.MapFolderName)
end

-- The presence of this folder IS "the merchant is here": the server clones it
-- in when the event starts and destroys it when the event ends.
function TravellingMerchant.FindRuntimeFolder()
	local map = TravellingMerchant.FindMapFolder()
	return map and map:FindFirstChild(TravellingMerchant.TemplateName) or nil
end

function TravellingMerchant.FindShopPart(runtimeFolder)
	runtimeFolder = runtimeFolder or TravellingMerchant.FindRuntimeFolder()
	local part = runtimeFolder and runtimeFolder:FindFirstChild(TravellingMerchant.ShopPartName)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

return TravellingMerchant
