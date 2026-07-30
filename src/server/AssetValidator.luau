local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local CosmeticShopBalance = require(Shared:WaitForChild("CosmeticShopBalance"))
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local Food = require(Shared:WaitForChild("Food"))
local GearShopBalance = require(Shared:WaitForChild("GearShopBalance"))
local GroupReward = require(Shared:WaitForChild("GroupReward"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local PlayerState = require(Shared:WaitForChild("PlayerState"))
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local RebirthBalance = require(Shared:WaitForChild("RebirthBalance"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RollChances = require(Shared:WaitForChild("RollChances"))
local RollDropAreaBalance = require(Shared:WaitForChild("RollDropAreaBalance"))
local RollLuckBalance = require(Shared:WaitForChild("RollLuckBalance"))
local RollRewards = require(Shared:WaitForChild("RollRewards"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local Shovel = require(Shared:WaitForChild("Shovel"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))
local StormChaser = require(Shared:WaitForChild("StormChaser"))
local BeeEvent = require(Shared:WaitForChild("BeeEvent"))
local AlienStand = require(Shared:WaitForChild("AlienStand"))
local Leaderboards = require(Shared:WaitForChild("Leaderboards"))
local Pinata = require(Shared:WaitForChild("Pinata"))

local AssetValidator = {}

local REQUIRED_ASSET_ROOTS = {
	"Cosmetics",
	"CosmeticTool",
	"PetModels",
	"FeedMachines",
	"Food",
	"Crates",
	"Seeds",
	"FeedMachineTool",
	"SeedTool",
	"Shovel",
	"Misc",
	"Mutations",
	"VFX",
}

local REQUIRED_REPLICATED_ROOTS = {
	"Remotes",
	"Sounds",
}

local REQUIRED_CLIENT_SOUNDS = {
	"UiOpen",
	"UiClose",
	"UiButtonClick",
	"Error",
	"FruitPop",
	"TreeShaken",
	"PetFed",
	"MoneyCollected",
	"FoodStolen",
	"ConfettiSound",
	"Drumroll",
	"RollButtonClick",
	"CrateBreak",
	"RollReveal",
	"MailboxOpen",
	"MailboxClose",
	"BirdBackingTrack",
	"Wind",
	"BeeBuzz",
}

local MUSIC_TRACK_VOLUME = 0.1

local REQUIRED_MUSIC_TRACKS = {
	Track1 = "rbxassetid://9045766377",
	Track2 = "rbxassetid://113447576287930",
	Track3 = "rbxassetid://9045766074",
	Track4 = "rbxassetid://1848028342",
	Track5 = "rbxassetid://87625732497001",
	Track6 = "rbxassetid://77930513126039",
	Track7 = "rbxassetid://78221801465342",
	Track8 = "rbxassetid://138751599898649",
	Track9 = "rbxassetid://140080440452815",
	Track10 = "rbxassetid://137331770642824",
	Track11 = "rbxassetid://9045765295",
}

local REQUIRED_REPLICA_SHARED_MODULES = {
	"Maid",
	"RateLimit",
	"Remote",
	"Signal",
}

-- Stable FeedType values that must exist somewhere under FeedMachines.
-- Template/model names are visual only and are intentionally not validated here.
local REQUIRED_FEEDS = {
	"Processor1",
	"AppleTree",
	"CherryTree",
	"JamBarrel",
	"PumpkinPatch",
	"LycheeTree",
	"CoconutTree",
	"AgavePatch",
	"GoldenmelonPatch",
	"GoldenCactus",
	"GoldenFigTree",
	"GoldenDragonfruitTree",
	"GoldshroomPatch",
}

local REQUIRED_TOOLS = {
	"CosmeticTool",
	"FeedMachineTool",
	"SeedTool",
	"Shovel",
}

local PROMPT_TEMPLATE_KINDS = {
	"PetFeed",
	"FeedMachine",
	"PatchHarvest",
	"TreeGroundPickup",
	"GridPartUnlock",
	"CrateRoll",
}

local DISALLOWED_FEED_PRICE_ATTRIBUTES = {
	"ShopPrice",
	"ShopRobuxPrice",
	"RollPrice",
	"PurchasePrice",
}

local EXPECTED_SEED_ROLL_CHANCES = {
	AppleTreeSeed = 2,
	PumpkinSeed = 3,
	CabbageSeed = 16,
	PotatoSeed = 28,
	OrangeTreeSeed = 45,
	WatermelonSeed = 75,
	PlumTreeSeed = 256,
	CornSeed = 427,
	CherryTreeSeed = 512,
	MushroomSeed = 640,
	BananaTreeSeed = 853,
	CactusSeed = 1200,
	PineappleSeed = 1707,
	FigTreeSeed = 2560,
	PurpleShroomSeed = 32000,
	BloodOrangeTreeSeed = 42667,
	GlowshroomSeed = 64000,
	DragonfruitTreeSeed = 85333,
	GoldenmelonSeed = 250000,
	GoldenAppleTreeSeed = 1000000,
	DurianTreeSeed = 2500000,
	GoldenCactusSeed = 5000000,
	GoldenFigTreeSeed = 7500000,
	GoldenDragonfruitSeed = 15000000,
	GoldshroomSeed = 25000000,
}
local EXPECTED_SEED_GROW_TIMES = {
	AppleTreeSeed = 3,
	PumpkinSeed = 3,
	CabbageSeed = 3,
	PotatoSeed = 3,
	OrangeTreeSeed = 60,
	WatermelonSeed = 3,
	PlumTreeSeed = 120,
	CornSeed = 3,
	CherryTreeSeed = 420,
	MushroomSeed = 3,
	BananaTreeSeed = 900,
	CactusSeed = 1200,
	PineappleSeed = 3,
	FigTreeSeed = 3600,
	PurpleShroomSeed = 3,
	BloodOrangeTreeSeed = 5400,
	GlowshroomSeed = 3,
	DragonfruitTreeSeed = 12600,
	GoldenAppleTreeSeed = 16200,
	DurianTreeSeed = 21600,
	GoldenmelonSeed = 3,
	GoldenCactusSeed = 28800,
	GoldenFigTreeSeed = 36000,
	GoldenDragonfruitSeed = 43200,
	GoldshroomSeed = 3,
}
local EXPECTED_SEED_EXPLICIT_PROBABILITY = 0.979932
local SEED_PROBABILITY_TOLERANCE = 0.0005
local PROBABILITY_EPSILON = 1e-9

local SEED_OWNED_FEED_ATTRIBUTES = {
	Seeds.Attributes.RollChanceN,
	Seeds.Attributes.Price,
	Seeds.Attributes.Rarity,
	Seeds.Attributes.GrowTime,
}

local EDIT_SELECTION_HITBOX_NAME = "EditSelectionHitbox"
local TREE_CLICK_TARGET_NAME = "LeafShake"
local PLOT_NAME_PATTERN = "^Plot(%d+)$"
local TEMPLATE_SIZE_TOLERANCE = 0.01

local DEPRECATED_FOOD_ATTRIBUTES = {
	MaxXP = State.Food.XP,
}

local JAM_BARREL_FEED_TYPE = "JamBarrel"
local JAM_JAR_TEMPLATE_NAME = "JamJar"
local JAM_FILL_NAME = "Fill"

local function add(errors, message)
	errors[#errors + 1] = message
end

local function child(parent, name, className, errors)
	local instance = parent and parent:FindFirstChild(name)
	if not instance then
		add(errors, string.format("Missing %s.%s", parent and parent:GetFullName() or "nil", name))
		return nil
	end
	if className and not instance:IsA(className) then
		add(errors, string.format("%s is %s, expected %s", instance:GetFullName(), instance.ClassName, className))
		return nil
	end
	return instance
end

local function assetChild(name, className, errors)
	local assetRoot = child(ReplicatedStorage, Assets.FolderName, "Folder", errors)
	if not assetRoot then
		return nil
	end
	return child(assetRoot, name, className, errors)
end

local function descendant(parent, name, className, errors)
	if not parent then return nil end
	for _, instance in ipairs(parent:GetDescendants()) do
		if instance.Name == name and (not className or instance:IsA(className)) then
			return instance
		end
	end
	add(errors, string.format("Missing descendant %s.%s", parent:GetFullName(), name))
	return nil
end

local function validateReplica(errors)
	child(ServerScriptService, "ReplicaServer", "ModuleScript", errors)
	child(ReplicatedStorage, "ReplicaClient", "ModuleScript", errors)
	local replicaShared = child(ReplicatedStorage, "ReplicaShared", "Folder", errors)
	for _, moduleName in ipairs(REQUIRED_REPLICA_SHARED_MODULES) do
		child(replicaShared, moduleName, "ModuleScript", errors)
	end
end

local function validateClientSounds(errors)
	local sounds = ReplicatedStorage:FindFirstChild("Sounds")
	if not sounds then
		return
	end
	if not sounds:IsA("Folder") then
		add(errors, string.format("%s is %s, expected Folder", sounds:GetFullName(), sounds.ClassName))
		return
	end

	for _, soundName in ipairs(REQUIRED_CLIENT_SOUNDS) do
		local sound = child(sounds, soundName, "Sound", errors)
		if sound and not sound.SoundId:match("^rbxassetid://%d+$") then
			add(errors, string.format("%s has invalid SoundId %q", sound:GetFullName(), sound.SoundId))
		end
	end
end

local function hasDescendantOfClass(root, className)
	if not root then
		return false
	end
	for _, instance in ipairs(root:GetDescendants()) do
		if instance:IsA(className) then
			return true
		end
	end
	return false
end

local function validateLightingPreset(lightingRoot, presetName, errors)
	local preset = child(lightingRoot, presetName, "Folder", errors)
	if not preset then
		return
	end

	local settingsModule = child(preset, "LightingSettings", "ModuleScript", errors)
	if settingsModule then
		local ok, settings = pcall(require, settingsModule)
		if not ok or type(settings) ~= "table" then
			add(errors, settingsModule:GetFullName() .. " must return a table")
		elseif settings.Lighting ~= nil and type(settings.Lighting) ~= "table" then
			add(errors, settingsModule:GetFullName() .. ".Lighting must be a table when present")
		end
	end

	local hasLightingChild = false
	for _, instance in ipairs(preset:GetChildren()) do
		if instance:IsA("Atmosphere")
			or instance:IsA("Sky")
			or instance:IsA("BloomEffect")
			or instance:IsA("ColorCorrectionEffect")
			or instance:IsA("SunRaysEffect") then
			hasLightingChild = true
			break
		end
	end
	if not hasLightingChild then
		add(errors, preset:GetFullName() .. " must contain at least one supported Lighting child")
	end
end

local function validateThunderstormAssets(errors, warnings)
	local lightingRoot = child(ReplicatedStorage, "Lighting", "Folder", errors)
	if lightingRoot then
		validateLightingPreset(lightingRoot, "Default", errors)
		validateLightingPreset(lightingRoot, "Storm", errors)
	end

	local misc = assetChild(Assets.Names.Misc, "Folder", errors)
	local rain = child(misc, "Rain", "BasePart", errors)
	if rain and not hasDescendantOfClass(rain, "ParticleEmitter") then
		add(errors, rain:GetFullName() .. " must contain a ParticleEmitter")
	end
	child(misc, "ThunderCloud", "BasePart", errors)
	local strike = child(misc, "LightningStrike", "BasePart", errors)
	if strike then
		child(strike, "StrikeAttachment", "Attachment", errors)
	end

	local mutations = assetChild(Assets.Names.Mutations, "Folder", errors)
	local lightning = child(mutations, "Lightning", nil, errors)
	if lightning then
		local xpMultiplier = Mutations.XPMultiplier(Mutations.Ids.Lightning)
		if type(xpMultiplier) ~= "number" or xpMultiplier <= 0 or xpMultiplier ~= xpMultiplier or math.abs(xpMultiplier) == math.huge then
			add(errors, string.format("%s has invalid configured %s %q", lightning:GetFullName(), State.Feed.XPMultiplier, tostring(xpMultiplier)))
		end
		if not hasDescendantOfClass(lightning, "ParticleEmitter") then
			add(errors, lightning:GetFullName() .. " must contain a ParticleEmitter for mutation visuals")
		end
	end

	local sounds = ReplicatedStorage:FindFirstChild("Sounds")
	local thunderSound = sounds and sounds:FindFirstChild("ThunderStrike")
	if thunderSound then
		if not thunderSound:IsA("Sound") then
			add(errors, string.format("%s is %s, expected Sound", thunderSound:GetFullName(), thunderSound.ClassName))
		elseif not thunderSound.SoundId:match("^rbxassetid://%d+$") then
			add(errors, string.format("%s has invalid SoundId %q", thunderSound:GetFullName(), thunderSound.SoundId))
		end
	else
		add(warnings, "Missing ReplicatedStorage.Sounds.ThunderStrike; clients will use the local thunder asset-id fallback")
	end

	local map = Workspace:FindFirstChild("Map")
	if not map then
		add(errors, "Missing Workspace.Map")
	else
		child(map, "CENTER", "BasePart", errors)
	end
end

local function validateAlienEventAssets(errors)
	local lightingRoot = child(ReplicatedStorage, "Lighting", "Folder", errors)
	if lightingRoot then
		validateLightingPreset(lightingRoot, "Alien", errors)
	end

	local misc = assetChild(Assets.Names.Misc, "Folder", errors)
	local ufo = child(misc, "UFOEvent", "Model", errors)
	if ufo then
		local beam = child(ufo, "Beam", "BasePart", errors)
		if beam and not hasDescendantOfClass(beam, "ParticleEmitter") then
			add(errors, beam:GetFullName() .. " must contain a ParticleEmitter for alien zap VFX")
		end
	end

	local assetRoot = child(ReplicatedStorage, Assets.FolderName, "Folder", errors)
	local eventVfx = assetRoot and child(assetRoot, "EventVFX", "Folder", errors)
	local alienEvent = eventVfx and child(eventVfx, "AlienEvent", "Folder", errors)
	if alienEvent then
		local alienBeamCount = 0
		for _, instance in ipairs(alienEvent:GetChildren()) do
			if instance.Name == "AlienBeam" and (instance:IsA("Model") or instance:IsA("BasePart")) then
				alienBeamCount += 1
			end
		end
		if alienBeamCount == 0 then
			add(errors, alienEvent:GetFullName() .. " must contain at least one AlienBeam Model or BasePart")
		end
		local starBlock = child(alienEvent, "StarBlock", "BasePart", errors)
		if starBlock and not hasDescendantOfClass(starBlock, "ParticleEmitter") then
			add(errors, starBlock:GetFullName() .. " must contain a ParticleEmitter")
		end
		local ufoProps = child(alienEvent, "UFOProps", "Model", errors)
		if ufoProps and not hasDescendantOfClass(ufoProps, "BasePart") then
			add(errors, ufoProps:GetFullName() .. " must contain a BasePart")
		end
	end

	local mutations = assetChild(Assets.Names.Mutations, "Folder", errors)
	local alien = child(mutations, "Alien", nil, errors)
	if alien then
		local xpMultiplier = Mutations.XPMultiplier(Mutations.Ids.Alien)
		if type(xpMultiplier) ~= "number" or xpMultiplier <= 0 or xpMultiplier ~= xpMultiplier or math.abs(xpMultiplier) == math.huge then
			add(errors, string.format("%s has invalid configured %s %q", alien:GetFullName(), State.Feed.XPMultiplier, tostring(xpMultiplier)))
		end
		if not hasDescendantOfClass(alien, "ParticleEmitter") then
			add(errors, alien:GetFullName() .. " must contain a ParticleEmitter for mutation visuals")
		end
	end
end

local function validateTornadoAssets(errors)
	local lightingRoot = child(ReplicatedStorage, "Lighting", "Folder", errors)
	if lightingRoot then
		validateLightingPreset(lightingRoot, "Tornado", errors)
	end

	local misc = assetChild(Assets.Names.Misc, "Folder", errors)
	local funnel = child(misc, "Tornado", "Model", errors)
	if funnel and not hasDescendantOfClass(funnel, "BasePart") then
		add(errors, funnel:GetFullName() .. " must contain a BasePart")
	end
	local cloud = child(misc, "TornadoCloud", "Model", errors)
	if cloud and not hasDescendantOfClass(cloud, "BasePart") then
		add(errors, cloud:GetFullName() .. " must contain a BasePart")
	end

	local mutations = assetChild(Assets.Names.Mutations, "Folder", errors)
	local twisted = child(mutations, "Twisted", nil, errors)
	if twisted then
		local xpMultiplier = Mutations.XPMultiplier(Mutations.Ids.Twisted)
		if type(xpMultiplier) ~= "number" or xpMultiplier <= 0 or xpMultiplier ~= xpMultiplier or math.abs(xpMultiplier) == math.huge then
			add(errors, string.format("%s has invalid configured %s %q", twisted:GetFullName(), State.Feed.XPMultiplier, tostring(xpMultiplier)))
		end
		if not hasDescendantOfClass(twisted, "ParticleEmitter") then
			add(errors, twisted:GetFullName() .. " must contain a ParticleEmitter for mutation visuals")
		end
	end

	-- ReplicatedStorage.Sounds.Wind (tornado audio) is already enforced via
	-- REQUIRED_CLIENT_SOUNDS.
end

local function validateTsunamiAssets(errors)
	local lightingRoot = child(ReplicatedStorage, "Lighting", "Folder", errors)
	if lightingRoot then
		validateLightingPreset(lightingRoot, "Tsunami", errors)
	end

	local misc = assetChild(Assets.Names.Misc, "Folder", errors)
	local wave = child(misc, "Tsunami", "Model", errors)
	if wave then
		child(wave, "TsunamiMesh", "BasePart", errors)
		child(wave, "TouchPart", "BasePart", errors)
		child(wave, "TsunamiEnd", "BasePart", errors)
	end

	local assetRoot = child(ReplicatedStorage, Assets.FolderName, "Folder", errors)
	local eventVfx = assetRoot and child(assetRoot, "EventVFX", "Folder", errors)
	local tsunamiEvent = eventVfx and child(eventVfx, "TsunamiEvent", "Folder", errors)
	if tsunamiEvent then
		local bubbles = child(tsunamiEvent, "Bubbles", "BasePart", errors)
		if bubbles and not hasDescendantOfClass(bubbles, "ParticleEmitter") then
			add(errors, bubbles:GetFullName() .. " must contain a ParticleEmitter")
		end
	end

	local mutations = assetChild(Assets.Names.Mutations, "Folder", errors)
	local aqua = child(mutations, "Aqua", nil, errors)
	if aqua then
		local xpMultiplier = Mutations.XPMultiplier(Mutations.Ids.Aqua)
		if type(xpMultiplier) ~= "number" or xpMultiplier <= 0 or xpMultiplier ~= xpMultiplier or math.abs(xpMultiplier) == math.huge then
			add(errors, string.format("%s has invalid configured %s %q", aqua:GetFullName(), State.Feed.XPMultiplier, tostring(xpMultiplier)))
		end
		if not hasDescendantOfClass(aqua, "ParticleEmitter") then
			add(errors, aqua:GetFullName() .. " must contain a ParticleEmitter for mutation visuals")
		end
	end
end

local function validateEarthquakeAssets(errors)
	local lightingRoot = child(ReplicatedStorage, "Lighting", "Folder", errors)
	if lightingRoot then
		validateLightingPreset(lightingRoot, "Earthquake", errors)
	end

	local assetRoot = child(ReplicatedStorage, Assets.FolderName, "Folder", errors)
	local eventVfx = assetRoot and child(assetRoot, "EventVFX", "Folder", errors)
	local earthquakeEvent = eventVfx and child(eventVfx, "EarthquakeEvent", "Folder", errors)
	if earthquakeEvent and not hasDescendantOfClass(earthquakeEvent, "ParticleEmitter") then
		add(errors, earthquakeEvent:GetFullName() .. " must contain a ParticleEmitter")
	end

	local mutations = assetChild(Assets.Names.Mutations, "Folder", errors)
	local shaken = child(mutations, "Shaken", nil, errors)
	if shaken then
		local xpMultiplier = Mutations.XPMultiplier(Mutations.Ids.Shaken)
		if type(xpMultiplier) ~= "number" or xpMultiplier <= 0 or xpMultiplier ~= xpMultiplier or math.abs(xpMultiplier) == math.huge then
			add(errors, string.format("%s has invalid configured %s %q", shaken:GetFullName(), State.Feed.XPMultiplier, tostring(xpMultiplier)))
		end
		if not hasDescendantOfClass(shaken, "ParticleEmitter") then
			add(errors, shaken:GetFullName() .. " must contain a ParticleEmitter for mutation visuals")
		end
	end
end

local function validateMusicPlaylist(errors)
	local soundRoot = ReplicatedStorage:FindFirstChild("Sounds")
	if not soundRoot then
		return
	end
	local playlist = soundRoot:FindFirstChild("MusicPlaylist")
	if not playlist then
		add(errors, "Missing " .. soundRoot:GetFullName() .. ".MusicPlaylist")
		return
	end
	if not playlist:IsA("Folder") then
		add(errors, string.format("%s is %s, expected Folder", playlist:GetFullName(), playlist.ClassName))
		return
	end

	for trackName, soundId in pairs(REQUIRED_MUSIC_TRACKS) do
		local track = child(playlist, trackName, "Sound", errors)
		if track then
			if track.SoundId ~= soundId then
				add(errors, string.format("%s has SoundId %q, expected %q", track:GetFullName(), track.SoundId, soundId))
			end
			if math.abs(track.Volume - MUSIC_TRACK_VOLUME) > 0.001 then
				add(errors, string.format("%s has Volume %s, expected %.2f", track:GetFullName(), tostring(track.Volume), MUSIC_TRACK_VOLUME))
			end
		end
	end
end

local function validateAnimalAmbientSounds(errors)
	local soundRoot = ReplicatedStorage:FindFirstChild("Sounds")
	if not soundRoot then
		return
	end
	local sounds = soundRoot:FindFirstChild("AnimalAmbientSounds")
	if not sounds then
		add(errors, "Missing " .. soundRoot:GetFullName() .. ".AnimalAmbientSounds")
		return
	end
	if not sounds:IsA("Folder") then
		add(errors, string.format("%s is %s, expected Folder", sounds:GetFullName(), sounds.ClassName))
		return
	end

	for _, instance in ipairs(sounds:GetChildren()) do
		if not instance:IsA("Sound") then
			add(errors, string.format("%s is %s, expected Sound", instance:GetFullName(), instance.ClassName))
		elseif not instance.Name:match("^Pet%d+$") then
			add(errors, string.format("%s must be named by PetID, e.g. Pet1", instance:GetFullName()))
		elseif not instance.SoundId:match("^rbxassetid://%d+$") then
			add(errors, string.format("%s has invalid SoundId %q", instance:GetFullName(), instance.SoundId))
		end
	end
end

local function nearlyEqual(a, b, tolerance)
	return math.abs(a - b) <= tolerance
end

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validateTool(tool, errors)
	if not tool then return end
	child(tool, "Handle", "BasePart", errors)
	if tool.Name == Shovel.ToolName then
		local toolKind = tool:GetAttribute(Shovel.ToolKindAttribute)
		if toolKind ~= Shovel.ToolKind then
			add(errors, string.format("%s missing %s=%q", tool:GetFullName(), Shovel.ToolKindAttribute, Shovel.ToolKind))
		end
	end
end

local function validateAnimationId(source, key, animationId, errors)
	if type(animationId) ~= "string" or not animationId:match("^rbxassetid://%d+$") then
		add(errors, string.format("%s has invalid %s %q", source, key, tostring(animationId)))
	end
end

local function validatePetVisual(model, visual, errors)
	if not model.PrimaryPart then
		add(errors, model:GetFullName() .. " missing PrimaryPart")
	end
	if not model:FindFirstChildWhichIsA("Animator", true) then
		add(errors, model:GetFullName() .. " missing Animator")
	end

	local hasPart = false
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			hasPart = true
		elseif descendant:IsA("ProximityPrompt") then
			add(errors, model:GetFullName() .. " contains baked ProximityPrompt " .. descendant:GetFullName())
		end
	end
	if not hasPart then
		add(errors, model:GetFullName() .. " has no BasePart descendants")
	end

	validateAnimationId(model:GetFullName(), "IdleAnimationId", visual.IdleAnimationId, errors)
	validateAnimationId(model:GetFullName(), "WalkAnimationId", visual.WalkAnimationId, errors)
end

local function validatePetCatalog(errors)
	local petModels = assetChild(Assets.Names.PetModels, "Folder", errors)
	if not petModels then return end

	local seenPetIds = {}
	local seenOrders = {}
	local definitions = {}

	local catalogModels = {}
	for _, child in ipairs(petModels:GetChildren()) do
		if child:IsA("Model") then
			catalogModels[#catalogModels + 1] = child
		elseif child:IsA("Folder") then
			for _, model in ipairs(child:GetChildren()) do
				if model:IsA("Model") then
					catalogModels[#catalogModels + 1] = model
				end
			end
		end
	end

	for _, model in ipairs(catalogModels) do

		local petId = model:GetAttribute(State.Pet.Id)
		if type(petId) ~= "string" or petId == "" then
			add(errors, model:GetFullName() .. " missing " .. State.Pet.Id .. " attribute")
			continue
		end
		if seenPetIds[petId] then
			add(errors, string.format("Duplicate %s %q on %s and %s", State.Pet.Id, petId, seenPetIds[petId]:GetFullName(), model:GetFullName()))
		else
			seenPetIds[petId] = model
		end

		local definition = PetCatalog.GetDefinition(petId)
		if not definition then
			add(errors, "Missing pet catalog definition " .. petId)
			continue
		end
		definitions[#definitions + 1] = definition

		if type(definition.WalkSpeed) ~= "number" or definition.WalkSpeed <= 0 then
			add(errors, "Pet catalog definition " .. petId .. " has invalid " .. State.Pet.WalkSpeed)
		end
		if type(definition.Order) ~= "number" or definition.Order < 1 or definition.Order % 1 ~= 0 then
			add(errors, "Pet catalog definition " .. petId .. " has invalid " .. State.Pet.Order)
		elseif seenOrders[definition.Order] then
			add(errors, string.format("Duplicate %s %d on %s and %s", State.Pet.Order, definition.Order, seenOrders[definition.Order], petId))
		else
			seenOrders[definition.Order] = petId
		end
		local rarity = model:GetAttribute(State.Pet.Rarity)
		if rarity ~= nil and not Rarities.IsValid(rarity) then
			add(errors, string.format("%s has unknown %s %q", model:GetFullName(), State.Pet.Rarity, tostring(rarity)))
		end

		validatePetVisual(model, definition.Visual, errors)
	end

	table.sort(definitions, function(a, b)
		return (a.Order or math.huge) < (b.Order or math.huge)
	end)
	local orderOneCount = 0
	for index, definition in ipairs(definitions) do
		if definition.Order == 1 then
			orderOneCount += 1
		end
		local hasNext = definitions[index + 1] ~= nil
		if hasNext and (type(definition.MaxXP) ~= "number" or definition.MaxXP <= 0) then
			add(errors, "Pet catalog definition " .. definition.Id .. " has invalid " .. State.Pet.MaxXP)
		end
	end
	if orderOneCount ~= 1 then
		add(errors, string.format("Expected exactly one Order 1 pet for rebirth reset, found %d", orderOneCount))
	end
end

local function validatePatchEditSelectionHitbox(template, errors)
	if not template:IsA("Model") then
		add(errors, template:GetFullName() .. " Patch feed template must be a Model")
		return
	end

	local dirt = template:FindFirstChild("Dirt")
	if not (dirt and dirt:IsA("BasePart")) then
		add(errors, template:GetFullName() .. " missing Dirt BasePart")
		return
	end

	local baseFood = template:FindFirstChild("BaseFood")
	if not (baseFood and baseFood:IsA("BasePart")) then
		add(errors, template:GetFullName() .. " missing BaseFood BasePart")
		return
	end

	if dirt.CanCollide ~= false then
		add(errors, dirt:GetFullName() .. " must have CanCollide=false")
	end
	if dirt.CanQuery ~= false then
		add(errors, dirt:GetFullName() .. " must have CanQuery=false; use " .. EDIT_SELECTION_HITBOX_NAME .. " for placement/edit queries")
	end
	if dirt.CanTouch ~= false then
		add(errors, dirt:GetFullName() .. " must have CanTouch=false")
	end

	if baseFood.CanCollide ~= false then
		add(errors, baseFood:GetFullName() .. " must have CanCollide=false")
	end
	if baseFood.CanQuery ~= false then
		add(errors, baseFood:GetFullName() .. " must have CanQuery=false")
	end
	if baseFood.CanTouch ~= false then
		add(errors, baseFood:GetFullName() .. " must have CanTouch=false")
	end
	if baseFood.Transparency < 1 then
		add(errors, baseFood:GetFullName() .. " must be fully transparent")
	end

	local hitbox = template:FindFirstChild(EDIT_SELECTION_HITBOX_NAME)
	if not (hitbox and hitbox:IsA("BasePart")) then
		add(errors, string.format("%s missing %s BasePart", template:GetFullName(), EDIT_SELECTION_HITBOX_NAME))
		return
	end

	if hitbox.CanQuery ~= true then
		add(errors, hitbox:GetFullName() .. " must have CanQuery=true")
	end
	if hitbox.CanCollide ~= false then
		add(errors, hitbox:GetFullName() .. " must have CanCollide=false")
	end
	if hitbox.Transparency < 1 then
		add(errors, hitbox:GetFullName() .. " must be fully transparent")
	end

	if not nearlyEqual(hitbox.Size.X, dirt.Size.X, TEMPLATE_SIZE_TOLERANCE)
		or not nearlyEqual(hitbox.Size.Z, dirt.Size.Z, TEMPLATE_SIZE_TOLERANCE) then
		add(errors, string.format("%s must match Dirt X/Z size", hitbox:GetFullName()))
	end

	local baseFoodTop = baseFood.CFrame:PointToWorldSpace(Vector3.new(0, baseFood.Size.Y / 2, 0))
	local expectedHeight = math.max(dirt.CFrame:PointToObjectSpace(baseFoodTop).Y + dirt.Size.Y / 2, 0.1)
	if not nearlyEqual(hitbox.Size.Y, expectedHeight, TEMPLATE_SIZE_TOLERANCE) then
		add(errors, string.format("%s height must reach top of BaseFood", hitbox:GetFullName()))
	end
end

local function validateTreeClickTarget(template, errors, warnings)
	if not template:IsA("Model") then
		add(errors, template:GetFullName() .. " uses FeedClass=Tree but is not a Model")
		return
	end

	local target = template:FindFirstChild(TREE_CLICK_TARGET_NAME, true)
	if not target then
		add(warnings or errors, template:GetFullName() .. " missing " .. TREE_CLICK_TARGET_NAME .. " BasePart; tree clicks will fall back to PrimaryPart")
		return
	end
	if not target:IsA("BasePart") then
		add(errors, string.format("%s is %s, expected BasePart", target:GetFullName(), target.ClassName))
		return
	end

	if target.CanQuery ~= true then
		add(errors, target:GetFullName() .. " must have CanQuery=true for tree click raycasts")
	end
	if target.CanCollide ~= false then
		add(errors, target:GetFullName() .. " must have CanCollide=false")
	end
end

local function validateScarecrowTemplate(template, feedType, errors, warnings)
	if not template:IsA("Model") then
		add(errors, template:GetFullName() .. " must be a Model")
	elseif not template.PrimaryPart then
		add(errors, template:GetFullName() .. " missing PrimaryPart")
	end

	local jumpSeconds = template:GetAttribute(State.Feed.JumpSeconds)
	if type(jumpSeconds) ~= "number" or jumpSeconds <= 0 then
		add(errors, string.format("%s has invalid %s %q", template:GetFullName(), State.Feed.JumpSeconds, tostring(jumpSeconds)))
	end
	local jumpRadius = template:GetAttribute(State.Feed.JumpRadius)
	if type(jumpRadius) ~= "number" or jumpRadius <= 0 then
		add(errors, string.format("%s has invalid %s %q", template:GetFullName(), State.Feed.JumpRadius, tostring(jumpRadius)))
	end

	-- Template Price must mirror the gear-shop source of truth exactly.
	local price = template:GetAttribute(Seeds.Attributes.Price)
	local shopItem = type(feedType) == "string" and GearShopBalance.Get(feedType) or nil
	if type(price) ~= "number" or price <= 0 or price % 1 ~= 0 then
		add(errors, string.format("%s has invalid %s %q", template:GetFullName(), Seeds.Attributes.Price, tostring(price)))
	elseif shopItem and price ~= GearShopBalance.Price(shopItem) then
		add(errors, string.format(
			"%s %s %d does not match GearShopBalance price %d",
			template:GetFullName(),
			Seeds.Attributes.Price,
			price,
			GearShopBalance.Price(shopItem)
		))
	end

	if not template:FindFirstChild("PumpkinHead", true) then
		add(warnings, template:GetFullName() .. " has no PumpkinHead; the jump bob will animate the body only")
	end
end

local function validateFeedTemplateIdentity(root, errors, warnings)
	local seenByFeedType = {}
	for _, classFolder in ipairs(root:GetChildren()) do
		if not classFolder:IsA("Folder") then
			continue
		end
		for _, template in ipairs(classFolder:GetChildren()) do
			if not (template:IsA("BasePart") or template:IsA("Model")) then
				continue
			end

			local feedType = template:GetAttribute(State.Feed.Type)
			if type(feedType) ~= "string" or feedType == "" then
				add(errors, template:GetFullName() .. " missing " .. State.Feed.Type .. " attribute")
			elseif seenByFeedType[feedType] then
				add(errors, string.format(
					"Duplicate %s %q on %s and %s",
					State.Feed.Type,
					feedType,
					seenByFeedType[feedType]:GetFullName(),
					template:GetFullName()
				))
			else
				seenByFeedType[feedType] = template
			end

			local feedClass = template:GetAttribute(State.Feed.Class)
			if type(feedClass) ~= "string" or feedClass == "" then
				feedClass = classFolder.Name
			end
			if not FeedMachines.IsClass(feedClass) then
				add(errors, string.format("%s has unknown %s %q", template:GetFullName(), State.Feed.Class, tostring(feedClass)))
			end

			for _, attributeName in ipairs(SEED_OWNED_FEED_ATTRIBUTES) do
				-- Scarecrows are gear-shop items; their template Price is a
				-- display copy cross-checked against GearShopBalance below.
				if feedClass == "Scarecrow" and attributeName == Seeds.Attributes.Price then
					continue
				end
				if template:GetAttribute(attributeName) ~= nil then
					add(errors, string.format(
						"%s has seed-owned attribute %s; move it to the matching seed template",
						template:GetFullName(),
						attributeName
					))
				end
			end

			for _, attributeName in ipairs(DISALLOWED_FEED_PRICE_ATTRIBUTES) do
				if template:GetAttribute(attributeName) ~= nil then
					add(errors, string.format(
						"%s has deprecated price attribute %s; use seed %s only",
						template:GetFullName(),
						attributeName,
						Seeds.Attributes.Price
					))
				end
			end

			local feedXP = template:GetAttribute(State.Feed.XP)
			if feedXP ~= nil and (type(feedXP) ~= "number" or feedXP <= 0) then
				add(errors, string.format("%s has invalid %s %q", template:GetFullName(), State.Feed.XP, tostring(feedXP)))
			end
			local percentageOfBest = template:GetAttribute(State.Feed.PercentageOfBest)
			if percentageOfBest ~= nil and (type(percentageOfBest) ~= "number" or percentageOfBest <= 0) then
				add(errors, string.format("%s has invalid %s %q", template:GetFullName(), State.Feed.PercentageOfBest, tostring(percentageOfBest)))
			end
			if percentageOfBest ~= nil and feedClass ~= "Tree" and feedClass ~= "Patch" then
				add(errors, string.format("%s has %s attribute; only Tree/Patch machines support dynamic XP", template:GetFullName(), State.Feed.PercentageOfBest))
			end
			if percentageOfBest ~= nil and feedXP ~= nil then
				add(errors, string.format("%s has both %s and %s; set exactly one", template:GetFullName(), State.Feed.XP, State.Feed.PercentageOfBest))
			end
			if feedClass == "Patch" and feedXP == nil and percentageOfBest == nil then
				add(errors, string.format("%s missing required %s (or %s) attribute", template:GetFullName(), State.Feed.XP, State.Feed.PercentageOfBest))
			end
			if (feedClass == "Processor" or feedClass == "JamBarrel") and feedXP ~= nil then
				add(errors, string.format("%s has processor multiplier attribute %s; use %s", template:GetFullName(), State.Feed.XP, State.Feed.XPMultiplier))
			end
			local xpMultiplier = template:GetAttribute(State.Feed.XPMultiplier)
			if xpMultiplier ~= nil and (type(xpMultiplier) ~= "number" or xpMultiplier <= 0) then
				add(errors, string.format("%s has invalid %s %q", template:GetFullName(), State.Feed.XPMultiplier, tostring(xpMultiplier)))
			end
			if (feedClass == "Processor" or feedClass == "JamBarrel") and xpMultiplier == nil then
				add(errors, string.format("%s missing required %s attribute", template:GetFullName(), State.Feed.XPMultiplier))
			end
			if feedClass == "JamBarrel" and template:GetAttribute(State.Feed.FoodType) ~= nil then
				add(errors, string.format(
					"%s has %s attribute; jam barrels are hard-coded to accept any food",
					template:GetFullName(),
					State.Feed.FoodType
				))
			end
			if feedClass == "Patch" then
				validatePatchEditSelectionHitbox(template, errors)
			elseif feedClass == "Tree" then
				validateTreeClickTarget(template, errors, warnings)
			elseif feedClass == "Scarecrow" then
				validateScarecrowTemplate(template, feedType, errors, warnings)
			end

			local growRate = template:GetAttribute(State.Feed.GrowRate)
			if growRate ~= nil and (type(growRate) ~= "number" or growRate <= 0) then
				add(errors, string.format("%s has invalid %s %q", template:GetFullName(), State.Feed.GrowRate, tostring(growRate)))
			end
		end
	end
end

local function validateFeedTemplates(errors, warnings)
	local root = assetChild(Assets.Names.FeedMachines, "Folder", errors)
	if not root then return end

	validateFeedTemplateIdentity(root, errors, warnings)

	for _, feedType in ipairs(REQUIRED_FEEDS) do
		local template = FeedMachines.GetTemplate(feedType)
		if not template then
			add(errors, "Missing feed machine template " .. feedType)
		elseif template:IsA("Model") and not template.PrimaryPart then
			add(errors, template:GetFullName() .. " missing PrimaryPart")
		end
	end

	local jamBarrel = FeedMachines.GetTemplate(JAM_BARREL_FEED_TYPE)
	if jamBarrel then
		local feedClass = FeedMachines.GetClass(JAM_BARREL_FEED_TYPE)
		if feedClass ~= "JamBarrel" then
			add(errors, string.format("%s must use %s=%q", jamBarrel:GetFullName(), State.Feed.Class, "JamBarrel"))
		end

		local duration = jamBarrel:GetAttribute(State.Feed.ProcessDuration)
		if type(duration) ~= "number" or duration <= 0 then
			add(errors, string.format("%s has invalid %s %q", jamBarrel:GetFullName(), State.Feed.ProcessDuration, tostring(duration)))
		end

		local xpMultiplier = jamBarrel:GetAttribute(State.Feed.XPMultiplier)
		if type(xpMultiplier) ~= "number" or xpMultiplier <= 0 then
			add(errors, string.format("%s has invalid %s %q", jamBarrel:GetFullName(), State.Feed.XPMultiplier, tostring(xpMultiplier)))
		end

		local maxQueue = jamBarrel:GetAttribute(State.Feed.MaxQueue)
		if type(maxQueue) ~= "number" or maxQueue <= 0 then
			add(errors, string.format("%s has invalid %s %q", jamBarrel:GetFullName(), State.Feed.MaxQueue, tostring(maxQueue)))
		end
	end
end

local function validateSeeds(errors)
	local root = assetChild(Assets.Names.Seeds, "Folder", errors)
	if not root then return end

	local function hasSeedTemplateAncestor(instance)
		local parent = instance.Parent
		while parent and parent ~= root do
			if parent:IsA("BasePart") or parent:IsA("Model") then
				return true
			end
			parent = parent.Parent
		end
		return false
	end

	local seenBySeedId = {}
	local count = 0
	local explicitRollProbability = 0
	for _, template in ipairs(root:GetDescendants()) do
		if not (template:IsA("BasePart") or template:IsA("Model")) or hasSeedTemplateAncestor(template) then
			continue
		end
		count += 1

		local seedId = template:GetAttribute(Seeds.Attributes.Id)
		if type(seedId) ~= "string" or seedId == "" then
			add(errors, template:GetFullName() .. " missing " .. Seeds.Attributes.Id .. " attribute")
		elseif seenBySeedId[seedId] then
			add(errors, string.format(
				"Duplicate %s %q on %s and %s",
				Seeds.Attributes.Id,
				seedId,
				seenBySeedId[seedId]:GetFullName(),
				template:GetFullName()
			))
		else
			seenBySeedId[seedId] = template
		end

		for _, deprecated in ipairs({ "FoodID", "FoodId" }) do
			if template:GetAttribute(deprecated) ~= nil then
				add(errors, string.format("%s has deprecated seed attribute %s; use %s", template:GetFullName(), deprecated, Seeds.Attributes.FeedType))
			end
		end

		local feedType = template:GetAttribute(Seeds.Attributes.FeedType)
		local feedClass = type(feedType) == "string" and FeedMachines.GetClass(feedType) or nil
		if type(feedType) ~= "string" or feedType == "" then
			add(errors, template:GetFullName() .. " missing " .. Seeds.Attributes.FeedType .. " attribute")
		elseif not FeedMachines.GetTemplate(feedType) then
			add(errors, string.format("%s has unknown %s %q", template:GetFullName(), Seeds.Attributes.FeedType, tostring(feedType)))
		elseif feedClass ~= "Patch" and feedClass ~= "Tree" then
			add(errors, string.format("%s resolves to unsupported roll seed class %q", template:GetFullName(), tostring(feedClass)))
		end

		local growTime = template:GetAttribute(Seeds.Attributes.GrowTime)
		if type(growTime) ~= "number" or growTime <= 0 then
			add(errors, string.format("%s has invalid %s %q", template:GetFullName(), Seeds.Attributes.GrowTime, tostring(growTime)))
		else
			local expectedGrowTime = type(seedId) == "string" and EXPECTED_SEED_GROW_TIMES[seedId] or nil
			if expectedGrowTime ~= nil and growTime ~= expectedGrowTime then
				add(errors, string.format(
					"%s has %s=%s, expected %d seconds from the balance sheet",
					template:GetFullName(),
					Seeds.Attributes.GrowTime,
					tostring(growTime),
					expectedGrowTime
				))
			end
		end

		local isEventOnly = template:GetAttribute(Seeds.Attributes.EventOnly) == true
		local rollChanceN = template:GetAttribute(Seeds.Attributes.RollChanceN)
		local rollProbability = RollChances.BaseWeightForChance(rollChanceN)
		if isEventOnly then
			-- Event-exclusive seeds never enter the roll pool; they may omit
			-- RollChanceN and must not count toward the roll probability sum.
			if rollChanceN ~= nil then
				add(errors, string.format("%s is %s but has %s set", template:GetFullName(), Seeds.Attributes.EventOnly, Seeds.Attributes.RollChanceN))
			end
		elseif not rollProbability then
			add(errors, string.format("%s has invalid %s %q", template:GetFullName(), Seeds.Attributes.RollChanceN, tostring(rollChanceN)))
		else
			explicitRollProbability += rollProbability
			local expectedChanceN = type(seedId) == "string" and EXPECTED_SEED_ROLL_CHANCES[seedId] or nil
			if expectedChanceN ~= nil and rollChanceN ~= expectedChanceN then
				add(errors, string.format(
					"%s has %s=%s, expected %d for planned roll odds",
					template:GetFullName(),
					Seeds.Attributes.RollChanceN,
					tostring(rollChanceN),
					expectedChanceN
				))
			end
		end

		local price = template:GetAttribute(Seeds.Attributes.Price)
		if type(price) ~= "number" or price < 0 or price ~= math.floor(price) then
			add(errors, string.format("%s has invalid %s %q", template:GetFullName(), Seeds.Attributes.Price, tostring(price)))
		end

		local rarity = template:GetAttribute(Seeds.Attributes.Rarity)
		if rarity ~= nil and not Rarities.IsValid(rarity) then
			add(errors, string.format("%s has unknown %s %q", template:GetFullName(), Seeds.Attributes.Rarity, tostring(rarity)))
		end

		if template:IsA("Model") and not template.PrimaryPart then
			add(errors, template:GetFullName() .. " missing PrimaryPart")
		end
	end

	if count == 0 then
		add(errors, "ReplicatedStorage.Assets.Seeds must contain at least one seed template")
	end
	if explicitRollProbability > 1 + PROBABILITY_EPSILON then
		add(errors, string.format("Seed roll explicit probability is %.4f%%, expected at most 100%%", explicitRollProbability * 100))
	end
	if math.abs(explicitRollProbability - EXPECTED_SEED_EXPLICIT_PROBABILITY) > SEED_PROBABILITY_TOLERANCE then
		add(errors, string.format(
			"Seed roll explicit probability is %.4f%%, expected about %.4f%% before fallback",
			explicitRollProbability * 100,
			EXPECTED_SEED_EXPLICIT_PROBABILITY * 100
		))
	end
	local fallbackProbability = math.max(1 - explicitRollProbability, 0)
	local expectedFallbackProbability = 1 - EXPECTED_SEED_EXPLICIT_PROBABILITY
	if math.abs(fallbackProbability - expectedFallbackProbability) > SEED_PROBABILITY_TOLERANCE then
		add(errors, string.format(
			"Seed roll fallback probability is %.4f%%, expected about %.4f%%",
			fallbackProbability * 100,
			expectedFallbackProbability * 100
		))
	end
	for _, fallback in ipairs(RollChances.SeedFallback) do
		if type(fallback.seedId) == "string" and fallback.seedId ~= "" and not seenBySeedId[fallback.seedId] then
			add(errors, string.format("RollChances SeedFallback seed %q does not resolve to an active seed template", fallback.seedId))
		end
		if not isFiniteNumber(fallback.weight) or fallback.weight <= 0 then
			add(errors, string.format("RollChances SeedFallback seed %q has invalid weight %q", tostring(fallback.seedId), tostring(fallback.weight)))
		end
	end
end

local function validateCosmetics(errors, warnings)
	local root = assetChild(Assets.Names.Cosmetics, "Folder", errors)
	if not root then return end

	local function hasCosmeticTemplateAncestor(instance)
		local parent = instance.Parent
		while parent and parent ~= root do
			if parent:IsA("BasePart") or parent:IsA("Model") then
				return true
			end
			parent = parent.Parent
		end
		return false
	end

	local function hasBasePart(template)
		if template:IsA("BasePart") then
			return true
		end
		for _, descendant in ipairs(template:GetDescendants()) do
			if descendant:IsA("BasePart") then
				return true
			end
		end
		return false
	end

	local seenByCosmeticId = {}
	local count = 0
	for _, template in ipairs(root:GetDescendants()) do
		if not (template:IsA("BasePart") or template:IsA("Model")) or hasCosmeticTemplateAncestor(template) then
			continue
		end
		count += 1

		local cosmeticId = template:GetAttribute(Cosmetics.Attributes.Id)
		if type(cosmeticId) ~= "string" or cosmeticId == "" then
			add(warnings or errors, template:GetFullName() .. " missing " .. Cosmetics.Attributes.Id .. " attribute; using template name fallback")
		elseif seenByCosmeticId[cosmeticId] then
			add(errors, string.format(
				"Duplicate %s %q on %s and %s",
				Cosmetics.Attributes.Id,
				cosmeticId,
				seenByCosmeticId[cosmeticId]:GetFullName(),
				template:GetFullName()
			))
		else
			seenByCosmeticId[cosmeticId] = template
		end

		if not hasBasePart(template) then
			add(errors, template:GetFullName() .. " has no BasePart descendants")
		end
		if template:IsA("Model") and not template.PrimaryPart then
			add(errors, template:GetFullName() .. " missing PrimaryPart")
		end

		local rarity = template:GetAttribute(Cosmetics.Attributes.Rarity)
		if rarity ~= nil and not Rarities.IsValid(rarity) then
			add(errors, string.format("%s has unknown %s %q", template:GetFullName(), Cosmetics.Attributes.Rarity, tostring(rarity)))
		end
		local description = template:GetAttribute(Cosmetics.Attributes.Description)
		if type(description) ~= "string" then
			add(warnings or errors, template:GetFullName() .. " missing string " .. Cosmetics.Attributes.Description .. " attribute")
		end
		local canOverlapFeed = template:GetAttribute(Cosmetics.Attributes.CanOverlapFeed)
		if canOverlapFeed ~= nil and type(canOverlapFeed) ~= "boolean" then
			add(errors, template:GetFullName() .. " has non-boolean " .. Cosmetics.Attributes.CanOverlapFeed .. " attribute")
		end
	end

	if count == 0 then
		add(errors, "ReplicatedStorage.Assets.Cosmetics must contain at least one cosmetic template")
	end
end

local function validateMisc(errors)
	local misc = assetChild(Assets.Names.Misc, "Folder", errors)
	if not misc then return end
	local explicitRollProbability = 0

	local function hasBasePart(template)
		if template:IsA("BasePart") then
			return true
		end
		for _, descendant in ipairs(template:GetDescendants()) do
			if descendant:IsA("BasePart") then
				return true
			end
		end
		return false
	end

	local function validateMiscRollTemplate(template, expectedId)
		if not RollRewards.IsTemplate(template) then
			add(errors, string.format("%s is %s, expected BasePart or Model", template:GetFullName(), template.ClassName))
			return
		end
		if not hasBasePart(template) then
			add(errors, template:GetFullName() .. " has no BasePart descendants")
		end

		local miscId = template:GetAttribute(RollRewards.Attributes.MiscId)
		if type(miscId) ~= "string" or miscId == "" then
			add(errors, template:GetFullName() .. " missing " .. RollRewards.Attributes.MiscId .. " attribute")
		elseif expectedId and miscId ~= expectedId then
			add(errors, string.format("%s has %s=%q, expected %q", template:GetFullName(), RollRewards.Attributes.MiscId, miscId, expectedId))
		end

		local rollChanceN = template:GetAttribute(RollRewards.Attributes.RollChanceN)
		local rollProbability = RollChances.BaseWeightForChance(rollChanceN)
		if not rollProbability then
			add(errors, string.format("%s has invalid %s %q", template:GetFullName(), RollRewards.Attributes.RollChanceN, tostring(rollChanceN)))
		else
			explicitRollProbability += rollProbability
		end

		local price = template:GetAttribute(RollRewards.Attributes.Price)
		if type(price) ~= "number" or price < 0 or price ~= math.floor(price) then
			add(errors, string.format("%s has invalid %s %q", template:GetFullName(), RollRewards.Attributes.Price, tostring(price)))
		end

		local rarity = template:GetAttribute(RollRewards.Attributes.Rarity)
		if rarity ~= nil and not Rarities.IsValid(rarity) then
			add(errors, string.format("%s has unknown %s %q", template:GetFullName(), RollRewards.Attributes.Rarity, tostring(rarity)))
		end
	end

	local function validateNonRollMiscTemplate(template)
		if not RollRewards.IsTemplate(template) then
			add(errors, string.format("%s is %s, expected BasePart or Model", template:GetFullName(), template.ClassName))
			return
		end
		if not hasBasePart(template) then
			add(errors, template:GetFullName() .. " has no BasePart descendants")
		end

		for _, attributeName in ipairs({
			RollRewards.Attributes.MiscId,
			RollRewards.Attributes.RollChanceN,
			RollRewards.Attributes.Price,
		}) do
			if template:GetAttribute(attributeName) ~= nil then
				add(errors, string.format("%s must not have %s while excluded from misc rolls", template:GetFullName(), attributeName))
			end
		end
	end

	local sapling = child(misc, "Sapling", "Model", errors)
	if sapling then
		if not hasBasePart(sapling) then
			add(errors, sapling:GetFullName() .. " has no BasePart descendants")
		end
	end

	local jamJar = child(misc, JAM_JAR_TEMPLATE_NAME, "Model", errors)
	if jamJar then
		if not jamJar.PrimaryPart then
			add(errors, jamJar:GetFullName() .. " missing PrimaryPart")
		end
		if not hasBasePart(jamJar) then
			add(errors, jamJar:GetFullName() .. " has no BasePart descendants")
		end
		descendant(jamJar, JAM_FILL_NAME, "BasePart", errors)
	end

	local brick = child(misc, "Brick", nil, errors)
	if brick then
		validateNonRollMiscTemplate(brick)
	end

	local seenByMiscId = {}
	for _, template in ipairs(misc:GetDescendants()) do
		if not RollRewards.IsTemplate(template) or RollRewards.HasTemplateAncestor(misc, template) then
			continue
		end
		if template == brick then
			continue
		end
		local miscId = template:GetAttribute(RollRewards.Attributes.MiscId)
		if miscId == nil then
			continue
		end
		if miscId == "Brick" then
			add(errors, string.format(
				"%s uses excluded %s %q",
				template:GetFullName(),
				RollRewards.Attributes.MiscId,
				miscId
			))
		end
		validateMiscRollTemplate(template, nil)
		if type(miscId) == "string" and miscId ~= "" then
			if seenByMiscId[miscId] then
				add(errors, string.format(
					"Duplicate %s %q on %s and %s",
					RollRewards.Attributes.MiscId,
					miscId,
					seenByMiscId[miscId]:GetFullName(),
					template:GetFullName()
				))
			else
				seenByMiscId[miscId] = template
			end
		end
	end
	if explicitRollProbability > 1 + PROBABILITY_EPSILON then
		add(errors, string.format("Misc roll explicit probability is %.4f%%, expected at most 100%%", explicitRollProbability * 100))
	end
end

local function validateVfx(errors)
	local vfx = assetChild(Assets.Names.VFX, "Folder", errors)
	if not vfx then return end

	local rarityParticle = child(vfx, "RarityParticle", nil, errors)
	if rarityParticle and not rarityParticle:IsA("ParticleEmitter") and not rarityParticle:FindFirstChildWhichIsA("ParticleEmitter", true) then
		add(errors, rarityParticle:GetFullName() .. " must be a ParticleEmitter or contain one")
	end
end

local function validateCrateTemplate(template, errors)
	if not template then return end
	if not (template:IsA("BasePart") or template:IsA("Model")) then
		add(errors, template:GetFullName() .. " is " .. template.ClassName .. ", expected BasePart or Model")
		return
	end

	local hasPart = template:IsA("BasePart")
	if template:IsA("Model") then
		for _, descendant in ipairs(template:GetDescendants()) do
			if descendant:IsA("BasePart") then
				hasPart = true
				break
			end
		end
	end
	if not hasPart then
		add(errors, template:GetFullName() .. " has no BasePart descendants")
	end
end

local function validateCrates(errors)
	local crates = assetChild(Assets.Names.Crates, "Folder", errors)
	if not crates then return end

	RollChances.Validate(errors)
	for _, crateId in ipairs(RollChances.CrateIds()) do
		local config = RollChances.GetCrate(crateId)
		local template = child(crates, config.TemplateName, nil, errors)
		validateCrateTemplate(template, errors)
	end

	local adminFolder = child(crates, "AdminParty", "Folder", errors)
	for _, crateId in ipairs(RollChances.AdminCrateIds()) do
		local config = RollChances.GetAdminCrate(crateId)
		local template = adminFolder and child(adminFolder, config.TemplateName, nil, errors)
		validateCrateTemplate(template, errors)
	end
end

local function validateRebirthUi(menu, errors)
	local rebirthFrame = child(menu, "Rebirth", "GuiObject", errors)
	if not rebirthFrame then return end

	descendant(rebirthFrame, "Panel", "GuiObject", errors)
	descendant(rebirthFrame, "CloseButton", "GuiButton", errors)
	descendant(rebirthFrame, "RebirthButton", "GuiButton", errors)
	local skipButton = descendant(rebirthFrame, "SkipButton", "GuiButton", errors)
	if skipButton then
		descendant(skipButton, "Price", "TextLabel", errors)
	end
	descendant(rebirthFrame, "TierLabel", "TextLabel", errors)
	descendant(rebirthFrame, "CashLabel", "TextLabel", errors)
	local progressBar = descendant(rebirthFrame, "ProgressBar", "GuiObject", errors)
	if progressBar then
		descendant(progressBar, "Fill", "GuiObject", errors)
	end
	local rewardList = descendant(rebirthFrame, "RewardList", "GuiObject", errors)
	if rewardList then
		local rewardTemplate = descendant(rewardList, "RewardTemplate", "GuiObject", errors)
		if rewardTemplate then
			descendant(rewardTemplate, "ItemIcon", "GuiObject", errors)
		end
		local petHolder = descendant(rewardList, "PetHolder", "GuiObject", errors)
		if petHolder then
			descendant(petHolder, "PetIcon", "ViewportFrame", errors)
		end
	end
end

local function validateShopUi(menu, uiName, requireRarity, errors)
	local panel = child(menu, uiName, "GuiObject", errors)
	if not panel then return end

	descendant(panel, "CloseButton", "GuiButton", errors)
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", errors)
	local template = holder and child(holder, "Template", "GuiObject", errors)
	if not template then return end

	descendant(template, "Name", "TextLabel", errors)
	if requireRarity then
		descendant(template, "Rarity", "TextLabel", errors)
	end
	descendant(template, "Description", "TextLabel", errors)
	descendant(template, "ItemIcon", "ViewportFrame", errors)
	descendant(template, "isLocked", "GuiObject", errors)
	-- Buy buttons may sit directly on the row (GearShop, cash-only) or inside a
	-- BuyBtns container (CosmeticShop); RobuxBtn is optional either way.
	local cashButton = descendant(template, "CashBtn", "GuiButton", errors)
	if cashButton then
		descendant(cashButton, "Price", "TextLabel", errors)
		descendant(cashButton, "CannotAfford", "ImageLabel", errors)
	end
	local robuxButton = template:FindFirstChild("RobuxBtn", true)
	if robuxButton and robuxButton:IsA("GuiButton") then
		descendant(robuxButton, "Price", "TextLabel", errors)
	end
end

local function validateGearShopUi(menu, errors)
	validateShopUi(menu, "GearShop", true, errors)
end

local function validateCosmeticShopUi(menu, errors)
	validateShopUi(menu, "CosmeticShop", false, errors)
end

local function validateRobuxShopUi(menu, errors)
	local panel = child(menu, "RobuxShop", "GuiObject", errors)
	if not panel then return end

	descendant(panel, "CloseButton", "GuiButton", errors)
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", errors)
	local header = descendant(panel, "Header", "GuiObject", errors)
	if header then
		descendant(header, "Featured", "GuiButton", errors)
		descendant(header, "Packs", "GuiButton", errors)
		descendant(header, "Cash", "GuiButton", errors)
	end
	if holder then
		child(holder, "Featured", "GuiObject", errors)
		child(holder, "SeedPacks", "GuiObject", errors)
		child(holder, "CashPacks", "GuiObject", errors)
		child(holder, "EndlessPack", "GuiObject", errors)
	end
end

local function seedPackButtonNameCandidates(quantity)
	if quantity == 1 then
		return { "BuyOne", "BuyButton", "Buy1" }
	elseif quantity == 3 then
		return { "BuyThree", "Buy3" }
	end
	return { "Buy" .. tostring(quantity) }
end

local function namedDescendant(root, name, className)
	if not root then
		return nil
	end
	for _, instance in ipairs(root:GetDescendants()) do
		if instance.Name == name and (not className or instance:IsA(className)) then
			return instance
		end
	end
	return nil
end

local function seedPackRewardSlots(items, extraTemplateNames)
	local templates = {}
	for _, item in ipairs(items and items:GetChildren() or {}) do
		if item:IsA("GuiObject") then
			local valid = item.Name == "Template"
				or (extraTemplateNames and extraTemplateNames[item.Name] == true)
			if valid then
				templates[#templates + 1] = item
			end
		end
	end
	table.sort(templates, function(left, right)
		if left.LayoutOrder ~= right.LayoutOrder then
			return left.LayoutOrder < right.LayoutOrder
		end
		if left.Position.X.Scale ~= right.Position.X.Scale then
			return left.Position.X.Scale < right.Position.X.Scale
		end
		return left.Position.X.Offset < right.Position.X.Offset
	end)
	return templates
end

local function validateSeedPackProductButton(card, product, source, errors)
	local quantity = math.max(math.floor(tonumber(product and product.Quantity) or 0), 0)
	local found = nil
	for _, name in ipairs(seedPackButtonNameCandidates(quantity)) do
		local candidate = card and card:FindFirstChild(name, true)
		if candidate then
			if candidate:IsA("GuiButton") then
				found = candidate
				break
			end
			add(errors, string.format("%s.%s is %s, expected GuiButton", source, name, candidate.ClassName))
		end
	end
	if not found then
		add(errors, string.format("%s is missing quantity %d buy button", source, quantity))
		return
	end
	descendant(found, "Price", "TextLabel", errors)
end

local function validateSeedPackCard(card, pack, source, errors)
	descendant(card, "Title", "TextLabel", errors)
	for _, product in ipairs(ShopBalance.AllSeedPackProducts(pack)) do
		validateSeedPackProductButton(card, product, source, errors)
	end

	-- Pack icons are 3D viewports rendered from Assets.Misc.SeedPacks models
	-- (directly on the card or inside IconHolder).
	local packIcon = namedDescendant(card, "PackIcon", "ViewportFrame")
	if not packIcon then
		add(errors, source .. " must contain a PackIcon ViewportFrame")
	end

	local items = child(card, "Items", "GuiObject", errors)
	if not items then
		return
	end
	local templates = seedPackRewardSlots(items)
	local expectedTemplates = #(pack.Rewards or {})
	if #templates ~= expectedTemplates then
		add(errors, string.format("%s.Items must contain exactly %d configured reward GuiObjects", source, expectedTemplates))
	end
	for index, template in ipairs(templates) do
		local templateSource = source .. ".Items." .. template.Name .. "[" .. tostring(index) .. "]"
		descendant(template, "Icon", "ViewportFrame", errors)
		descendant(template, "Chance", "TextLabel", errors)
		if not template.Visible then
			add(errors, templateSource .. " should be visible in the Studio-authored card")
		end
	end
end

local function validateSeedPacksUi(menu, errors)
	local panel = child(menu, "RobuxShop", "GuiObject", errors)
	if not panel then return end
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", errors)
	local seedPacks = holder and child(holder, "SeedPacks", "GuiObject", errors)
	if not holder then return end

	for _, pack in ipairs(ShopBalance.AllSeedPacks()) do
		local card = child(seedPacks, pack.PackId, "GuiObject", errors)
		if card then
			validateSeedPackCard(card, pack, "ReplicatedStorage.UI.Menu.RobuxShop.SFHolder.SeedPacks." .. tostring(pack.PackId), errors)
		end
	end
end

-- EndlessPackController clones Items.Template into the runtime claim-track
-- cards, so the template must carry the icon/buy structure the controller
-- renders into.
local function validateEndlessPackShopUi(menu, errors)
	local panel = child(menu, "RobuxShop", "GuiObject", errors)
	if not panel then return end
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", errors)
	local section = holder and child(holder, "EndlessPack", "GuiObject", errors)
	if not section then return end

	descendant(section, "Title", "TextLabel", errors)
	descendant(section, "Timer", "TextLabel", errors)
	local items = descendant(section, "Items", "ScrollingFrame", errors)
	if not items then return end
	child(items, "UIListLayout", "UIListLayout", errors)
	local template = child(items, "Template", "GuiObject", errors)
	if not template then return end
	descendant(template, "Icon", "ViewportFrame", errors)
	descendant(template, "IconImage", "ImageLabel", errors)
	local buyButton = descendant(template, "Buy", "GuiButton", errors)
	if buyButton then
		descendant(buyButton, "Price", "TextLabel", errors)
	end
end

local DURIAN_EXTRA_TEMPLATE_NAMES = {
	MythicalTemplate = true,
	SecretTemplate = true,
}

-- Standalone Durian Pack UI (opened from HUD.DurianPack, not the RobuxShop).
local function validateDurianPackUi(menu, errors)
	local panel = child(menu, "DurianPackHolder", "GuiObject", errors)
	if not panel then return end
	local source = "ReplicatedStorage.UI.Menu.DurianPackHolder"
	local pack = ShopBalance.GetDurianPack()

	descendant(panel, "CloseButton", "GuiButton", errors)

	local durianFrame = child(panel, "DurianPack", "GuiObject", errors)
	if durianFrame then
		child(durianFrame, "Title", "TextLabel", errors)
		child(durianFrame, "RollPity", "TextLabel", errors)
		child(durianFrame, "Timer", "TextLabel", errors)
		local ticketHolder = child(durianFrame, "TicketHolder", "GuiObject", errors)
		if ticketHolder then
			descendant(ticketHolder, "TicketAmount", "TextLabel", errors)
		end
		for _, rollCount in ipairs(pack and pack.RollCounts or {}) do
			child(durianFrame, "Roll" .. tostring(rollCount), "GuiButton", errors)
		end
		local items = child(durianFrame, "Items", "GuiObject", errors)
		if items then
			local templates = seedPackRewardSlots(items, DURIAN_EXTRA_TEMPLATE_NAMES)
			local expectedTemplates = #(pack and pack.Rewards or {})
			if #templates ~= expectedTemplates then
				add(errors, string.format(
					"%s.DurianPack.Items must contain exactly %d configured reward GuiObjects",
					source,
					expectedTemplates
				))
			end
			for _, template in ipairs(templates) do
				descendant(template, "Icon", "ViewportFrame", errors)
				descendant(template, "Name", "TextLabel", errors)
				descendant(template, "Chance", "TextLabel", errors)
			end
		end
	end

	local buyRolls = child(panel, "BuyRolls", "GuiObject", errors)
	local buyHolder = buyRolls and descendant(buyRolls, "SFHolder", "ScrollingFrame", errors)
	local offerTemplate = buyHolder and child(buyHolder, "Template", "GuiObject", errors)
	if offerTemplate then
		child(offerTemplate, "TicketAmount", "TextLabel", errors)
		child(offerTemplate, "ExtraTickets", "TextLabel", errors)
		local buyButton = child(offerTemplate, "Buy", "GuiButton", errors)
		if buyButton then
			descendant(buyButton, "Price", "TextLabel", errors)
		end
	end
end

local function validateDurianPackHud(hud, errors)
	local entry = child(hud, "DurianPack", "GuiObject", errors)
	if not entry then return end
	child(entry, "Click", "GuiButton", errors)
	child(entry, "DurianPackHolder", "ViewportFrame", errors)
end

local function validateServerLuckShopUi(menu, warnings)
	local panel = child(menu, "RobuxShop", "GuiObject", warnings)
	if not panel then return end
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", warnings)
	local featured = holder and child(holder, "Featured", "GuiObject", warnings)
	local card = featured and child(featured, "ServerLuck", "GuiObject", warnings)
	if not card then return end

	local luckValues = child(card, "LuckValues", "GuiObject", warnings)
	if luckValues then
		local currentLuck = child(luckValues, "CurrentLuck", "TextLabel", warnings)
		if currentLuck then
			descendant(currentLuck, "CurrentLuck", "TextLabel", warnings)
		end
		local nextLuck = child(luckValues, "NextLuck", "TextLabel", warnings)
		if nextLuck then
			descendant(nextLuck, "NextLuck", "TextLabel", warnings)
		end
	end
	local iconHolder = child(card, "IconHolder", "GuiObject", warnings)
	local timer = iconHolder and child(iconHolder, "Timer", "TextLabel", warnings)
	if timer then
		descendant(timer, "Timer", "TextLabel", warnings)
	end
	local buyButton = child(card, "BuyButton", "GuiButton", warnings)
	if buyButton then
		child(buyButton, "Price", "TextLabel", warnings)
	end
end

local function validateCashPackShopCard(card, warnings)
	descendant(card, "Amount", "TextLabel", warnings)
	local buyButton = child(card, "BuyButton", "GuiButton", warnings)
	if buyButton then
		child(buyButton, "Price", "TextLabel", warnings)
	end
end

local function validateCashPacksShopUi(menu, warnings)
	local panel = child(menu, "RobuxShop", "GuiObject", warnings)
	if not panel then return end
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", warnings)
	local cashPacks = holder and child(holder, "CashPacks", "GuiObject", warnings)
	if not cashPacks then return end

	for _, pack in ipairs(ShopBalance.AllCashPacks()) do
		local card = child(cashPacks, pack.PackId, "GuiObject", warnings)
		if card then
			validateCashPackShopCard(card, warnings)
		end
	end
end

local function validateStarterPackShopUi(menu, warnings)
	local panel = child(menu, "RobuxShop", "GuiObject", warnings)
	if not panel then return end
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", warnings)
	local featured = holder and child(holder, "Featured", "GuiObject", warnings)
	if not featured then return end

	for _, starterPack in ipairs(ShopBalance.AllStarterPacks()) do
		local sourcePrefix = "ReplicatedStorage.UI.Menu.RobuxShop.SFHolder.Featured." .. tostring(starterPack.PackId)
		local expectedTemplates = #(starterPack.Rewards or {})
		local hasCashReward = false
		for _, reward in ipairs(starterPack.Rewards or {}) do
			if reward.Kind == ShopBalance.StarterPackRewardKinds.Cash then
				hasCashReward = true
				break
			end
		end

		local card = child(featured, starterPack.PackId, "GuiObject", warnings)
		if card then
			local buyButton = child(card, "BuyButton", "GuiButton", warnings)
			if buyButton then
				child(buyButton, "Price", "TextLabel", warnings)
			end
			child(card, "Sold", "GuiObject", warnings)
			descendant(card, "Name", "TextLabel", warnings)
			descendant(card, "Timer", "TextLabel", warnings)

			local items = child(card, "Items", "GuiObject", warnings)
			if items then
				local templates = {}
				for _, item in ipairs(items:GetChildren()) do
					if item.Name == "Template" and item:IsA("GuiObject") then
						templates[#templates + 1] = item
					end
				end
				if #templates ~= expectedTemplates then
					add(warnings, string.format(
						"%s.Items must contain exactly %d Template GuiObjects",
						sourcePrefix,
						expectedTemplates
					))
				end
				for index, template in ipairs(templates) do
					local source = sourcePrefix .. ".Items.Template[" .. tostring(index) .. "]"
					descendant(template, "Icon", "ViewportFrame", warnings)
					if hasCashReward then
						descendant(template, "IconImage", "ImageLabel", warnings)
					end
					descendant(template, "Name", "TextLabel", warnings)
					descendant(template, "Amount", "TextLabel", warnings)
					if not template.Visible then
						add(warnings, source .. " should be visible in the Studio-authored card")
					end
				end
			end
		end
	end
end

-- Contract for the plot starter pack world prompt (StarterPackPromptController):
-- offer billboard card, the prompt model with its billboard attachment, and
-- the per-plot anchor pad.
local function validateStarterPackPromptAssets(billboardFolder, warnings)
	local maxRewards = 0
	for _, starterPack in ipairs(ShopBalance.AllStarterPacks()) do
		maxRewards = math.max(maxRewards, #(starterPack.Rewards or {}))
	end

	local offer = billboardFolder and child(billboardFolder, "StarterPackOffer", "BillboardGui", warnings)
	if offer then
		local sourcePrefix = "ReplicatedStorage.UI.BillboardGUIs.StarterPackOffer"
		local card = child(offer, "StarterPack", "GuiObject", warnings)
		if card then
			descendant(card, "Name", "TextLabel", warnings)
			descendant(card, "Timer", "TextLabel", warnings)
			descendant(card, "Price", "TextLabel", warnings)
			local closeButton = card:FindFirstChild("CloseButton")
			if not (closeButton and closeButton:IsA("GuiButton")) then
				add(warnings, sourcePrefix .. ".StarterPack.CloseButton GuiButton is required")
			end
			local items = child(card, "Items", "GuiObject", warnings)
			if items then
				local templates = 0
				for _, item in ipairs(items:GetChildren()) do
					if item.Name == "Template" and item:IsA("GuiObject") then
						templates += 1
					end
				end
				if templates < maxRewards then
					add(warnings, string.format(
						"%s.StarterPack.Items needs at least %d Template GuiObjects (largest pack reward count)",
						sourcePrefix,
						maxRewards
					))
				end
			end
		end
	end

	local misc = Assets.Find(Assets.Names.Misc)
	for _, starterPack in ipairs(ShopBalance.AllStarterPacks()) do
		local modelName = tostring(starterPack.PackId) .. "Prompt"
		local model = misc and misc:FindFirstChild(modelName)
		if not (model and model:IsA("Model") and model.PrimaryPart) then
			add(warnings, "ReplicatedStorage.Assets.Misc." .. modelName .. " Model with a PrimaryPart is required")
		elseif not model:FindFirstChild("UIAttachment", true) then
			add(warnings, "ReplicatedStorage.Assets.Misc." .. modelName .. " is missing a UIAttachment Attachment")
		end
	end

	local plotTemplate = misc and misc:FindFirstChild("PlotTemplate")
	local signs = plotTemplate and plotTemplate:FindFirstChild("Signs")
	local signPart = signs and signs:FindFirstChild("PlotStarterPackPrompt")
	if not (signPart and signPart:IsA("BasePart")) then
		add(warnings, "ReplicatedStorage.Assets.Misc.PlotTemplate.Signs.PlotStarterPackPrompt BasePart is required")
	elseif not signPart.Anchored then
		-- Unanchored loose parts fall out of the cloned plot at boot and the
		-- prompt silently never finds its anchor pad.
		add(warnings, signPart:GetFullName() .. " must be Anchored")
	end
end

local function validateGamePassShopCard(card, warnings)
	local buyButton = child(card, "BuyButton", "GuiButton", warnings)
	if buyButton then
		child(buyButton, "Price", "TextLabel", warnings)
	end
	child(card, "Sold", "ImageLabel", warnings)
end

local function validateGamePassShopUi(menu, warnings)
	local panel = child(menu, "RobuxShop", "GuiObject", warnings)
	if not panel then return end
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", warnings)
	local featured = holder and holder:FindFirstChild("Featured")
	local gamepasses = holder and holder:FindFirstChild("Gamepasses")
	if featured and not featured:IsA("GuiObject") then
		add(warnings, string.format("%s is %s, expected GuiObject", featured:GetFullName(), featured.ClassName))
		featured = nil
	end
	if gamepasses and not gamepasses:IsA("GuiObject") then
		add(warnings, string.format("%s is %s, expected GuiObject", gamepasses:GetFullName(), gamepasses.ClassName))
		gamepasses = nil
	end

	for _, pass in ipairs(ShopBalance.AllGamePasses()) do
		if type(pass.FeaturedCardName) == "string" and pass.FeaturedCardName ~= "" then
			local featuredCard = featured and featured:FindFirstChild(pass.FeaturedCardName)
			if featuredCard then
				if featuredCard:IsA("GuiObject") then
					validateGamePassShopCard(featuredCard, warnings)
				else
					add(warnings, string.format("%s is %s, expected GuiObject", featuredCard:GetFullName(), featuredCard.ClassName))
				end
			end
		end

		local gamepassesCard = gamepasses and gamepasses:FindFirstChild(pass.ShopCardName)
		if gamepassesCard then
			if gamepassesCard:IsA("GuiObject") then
				validateGamePassShopCard(gamepassesCard, warnings)
			else
				add(warnings, string.format("%s is %s, expected GuiObject", gamepassesCard:GetFullName(), gamepassesCard.ClassName))
			end
		end
	end
end

local function validatePackRollFrameUi(menu, errors)
	local panel = child(menu, "PackRollFrame", "GuiObject", errors)
	if not panel then return end

	local itemRollHolder = child(panel, "ItemRollHolder", "GuiObject", errors)
	child(panel, "Continue", "GuiButton", errors)
	child(panel, "Slice", "GuiObject", errors)
	child(panel, "OpenHint", "TextLabel", errors)
	child(panel, "ConsoleIcon", "ImageLabel", errors)
	local packHolder = itemRollHolder and child(itemRollHolder, "PackHolder", "GuiObject", errors)
	if not packHolder then
		return
	end

	child(packHolder, "Result", "ViewportFrame", errors)
	child(packHolder, "RayResult", "ImageLabel", errors)
	child(packHolder, "ItemName", "TextLabel", errors)
	child(packHolder, "Rarity", "TextLabel", errors)
	child(packHolder, "Chance", "TextLabel", errors)
	local packButton = child(packHolder, "Pack", "ImageButton", errors)
	if packButton then
		child(packButton, "PackIcon", "ViewportFrame", errors)
	end
	child(packHolder, "FTUEDrag", "ImageLabel", errors)
end

local function validateBillboardTemplate(billboardFolder, name, labelName, errors)
	local billboard = child(billboardFolder, name, "BillboardGui", errors)
	if billboard and labelName then
		descendant(billboard, labelName, "TextLabel", errors)
	end
	return billboard
end

local function validatePetMoneyBillboard(billboardFolder, errors)
	local billboard = validateBillboardTemplate(billboardFolder, "PetMoneyBillboard", nil, errors)
	if not billboard then return end

	local stats = child(billboard, "Stats", "GuiObject", errors)
	if stats then
		child(stats, "Money", "TextLabel", errors)
		child(stats, "MoneyRateLabel", "TextLabel", errors)
		child(stats, "NameLabel", "TextLabel", errors)
		child(stats, "NicknameLabel", "TextLabel", errors)
	end

	local xp = child(billboard, "XP", "GuiObject", errors)
	if xp then
		child(xp, "Fill", "GuiObject", errors)
	end
end

local function validateItemAddedDisplayBillboard(billboardFolder, errors)
	local billboard = validateBillboardTemplate(billboardFolder, "ItemAddedDisplay", nil, errors)
	if not billboard then return end

	local main = child(billboard, "main", "GuiObject", errors)
	if not main then return end

	child(main, "UIListLayout", "UIListLayout", errors)
	child(main, "UIPadding", "UIPadding", errors)

	local item = child(main, "item", "TextLabel", errors)
	if item then
		child(item, "UIStroke", "UIStroke", errors)
		child(item, "UIGradient", "UIGradient", errors)
		if item.Visible ~= false then
			add(errors, item:GetFullName() .. " should be hidden template text (Visible=false)")
		end
	end
end

local function validatePromptTemplates(ui, errors)
	local function validatePromptTemplate(prompt)
		if prompt and prompt:IsA("ProximityPrompt") and prompt.Style ~= Enum.ProximityPromptStyle.Custom then
			add(errors, prompt:GetFullName() .. " should use Style=Custom for ProximityPromptCustomizer")
		end
	end

	local generic = ui:FindFirstChild("LocalPrompt")
	if generic then
		if not generic:IsA("ProximityPrompt") then
			add(errors, string.format("%s is %s, expected ProximityPrompt", generic:GetFullName(), generic.ClassName))
		else
			validatePromptTemplate(generic)
		end
	else
		local templates = child(ui, "PromptTemplates", "Folder", errors)
		if not templates then return end

		for _, kind in ipairs(PROMPT_TEMPLATE_KINDS) do
			validatePromptTemplate(child(templates, kind, "ProximityPrompt", errors))
		end
	end
end

local function validateProximityPromptCustomizerUi(ui, errors)
	local customizer = child(ui, "ProximityPromptCustomizer", "Folder", errors)
	local defaultTheme = child(customizer, "Default", "BillboardGui", errors)
	if not defaultTheme then return end
	if defaultTheme.Enabled ~= false then
		add(errors, defaultTheme:GetFullName() .. " should be disabled template UI (Enabled=false)")
	end

	child(defaultTheme, "TextButton", "TextButton", errors)
	local frame = child(defaultTheme, "PromptFrame", "GuiObject", errors)
	if not frame then return end

	local inputFrame = child(frame, "InputFrame", "Frame", errors)
	child(frame, "ActionText", "TextLabel", errors)
	child(frame, "Background", "GuiObject", errors)

	local inputInner = child(inputFrame, "Frame", "Frame", errors)
	child(inputInner, "UIScale", "UIScale", errors)
	child(inputInner, "ButtonFrame", "GuiObject", errors)
	child(inputInner, "ButtonImage", "ImageLabel", errors)
	child(inputInner, "ButtonTextImage", "ImageLabel", errors)
	child(inputInner, "ButtonText", "TextLabel", errors)

	local progressBar = child(inputInner, "ProgressBar", "Frame", errors)
	local leftGradient = child(progressBar, "LeftGradient", "Frame", errors)
	local rightGradient = child(progressBar, "RightGradient", "Frame", errors)
	child(progressBar, "Progress", "NumberValue", errors)
	child(child(leftGradient, "ProgressBarImage", "ImageLabel", errors), "UIGradient", "UIGradient", errors)
	child(child(rightGradient, "ProgressBarImage", "ImageLabel", errors), "UIGradient", "UIGradient", errors)
end

local function validateHudCurrency(hud, errors)
	local currency = child(hud, "Currency", "GuiObject", errors)
	if not currency then return end
	child(currency, "CurrencyLabel", "TextLabel", errors)
	child(currency, "FriendBoost", "TextLabel", errors)
	child(currency, "InviteFriends", "GuiButton", errors)
end

local function validateHoverOverHud(hud, warnings)
	local hoverOver = child(hud, "HoverOver", "GuiObject", warnings)
	if not hoverOver then return end

	local holder = child(hoverOver, "Holder", "GuiObject", warnings)
	if not holder then return end

	child(holder, "ItemName", "TextLabel", warnings)
	child(holder, "Rarity", "TextLabel", warnings)
	child(holder, "XP", "TextLabel", warnings)
end

local function validateJoinBackShowcaseUi(hud, warnings)
	local textFrame = hud:FindFirstChild("JoinBackText")
	if not (textFrame and textFrame:IsA("GuiObject")) then
		add(warnings, "Missing ReplicatedStorage.UI.HUD.JoinBackText GuiObject")
	else
		local textLabel = textFrame:FindFirstChild("JoinBackText", true)
		if not (textLabel and textLabel:IsA("TextLabel")) then
			add(warnings, "Missing ReplicatedStorage.UI.HUD.JoinBackText.JoinBackText TextLabel")
		end
	end

	local flash = hud:FindFirstChild("JoinBackFlash")
	if not (flash and flash:IsA("GuiObject")) then
		add(warnings, "Missing ReplicatedStorage.UI.HUD.JoinBackFlash GuiObject")
	end
end

local function validateServerLuckHud(hud, warnings)
	local buffs = child(hud, "Buffs", "GuiObject", warnings)
	local serverLuck = buffs and child(buffs, "ServerLuck", "GuiObject", warnings)
	if not serverLuck then return end

	child(serverLuck, "Timer", "TextLabel", warnings)
	child(serverLuck, "Multiplier", "TextLabel", warnings)
	local icon = child(serverLuck, "Icon", "ImageLabel", warnings)
	if icon then
		child(icon, "Crown", "ImageLabel", warnings)
	end
end

local function validateTopBarEventHud(hud, warnings)
	local topBar = child(hud, "TopBar", "GuiObject", warnings)
	if not topBar then return end

	local home = topBar:FindFirstChild("Home", true)
	if not home then
		add(warnings, "Missing descendant " .. topBar:GetFullName() .. ".Home")
	elseif not home:IsA("GuiButton") and not home:FindFirstChildWhichIsA("GuiButton", true) then
		add(warnings, home:GetFullName() .. " must be a GuiButton or contain a nested GuiButton")
	end

	local currentEvent = child(topBar, "CurrentEvent", "GuiObject", warnings)
	if currentEvent then
		child(currentEvent, "Sunny", "GuiObject", warnings)
		child(currentEvent, "Windy", "GuiObject", warnings)
		child(currentEvent, "Stormy", "GuiObject", warnings)
		child(currentEvent, "Tornado", "GuiObject", warnings)
		child(currentEvent, "Tsunami", "GuiObject", warnings)
		child(currentEvent, "Earthquake", "GuiObject", warnings)
		child(currentEvent, "Alien", "GuiObject", warnings)
	end

	local eventTimer = child(topBar, "EventTimer", "GuiObject", warnings)
	if eventTimer then
		child(eventTimer, "Timer", "TextLabel", warnings)
		child(eventTimer, "Title", "TextLabel", warnings)
	end

	child(topBar, "CurrentEventTimer", "TextLabel", warnings)
end

local function validateUpdateTimerHud(hud, warnings)
	local updateTimer = child(hud, "UpdateTimer", "GuiObject", warnings)
	if not updateTimer then return end

	child(updateTimer, "Tap", "GuiButton", warnings)
	local holder = child(updateTimer, "Holder", "GuiObject", warnings)
	if not holder then return end

	child(holder, "NotifyButton", "GuiButton", warnings)
	child(holder, "UpdateTimer", "TextLabel", warnings)
end

local function validateVipHud(hud, warnings)
	local buffs = child(hud, "Buffs", "GuiObject", warnings)
	local vip = buffs and child(buffs, "VIP", "GuiObject", warnings)
	if not vip then return end

	child(vip, "Icon", "ImageLabel", warnings)
end

local function validateAutoPromptButton(hud, errors)
	local button = child(hud, "AutoPromptButton", "ImageButton", errors)
	if not button then return end
	if button.Visible ~= false then
		add(errors, button:GetFullName() .. " should be hidden template UI (Visible=false)")
	end
	if button.Image ~= "" then
		add(errors, button:GetFullName() .. " should use a neutral rounded background, not an image glyph")
	end
	child(button, "Icon", "ImageLabel", errors)
	child(button, "UIAspectRatioConstraint", "UIAspectRatioConstraint", errors)
	child(button, "UICorner", "UICorner", errors)
	if button:GetAttribute("FeedIconText") ~= nil or button:GetAttribute("CollectIconText") ~= nil then
		add(errors, button:GetFullName() .. " should use image attributes instead of text icon attributes")
	end
	if button:GetAttribute("FeedIconImage") ~= "rbxassetid://119576309332002" then
		add(errors, button:GetFullName() .. " missing FeedIconImage rbxassetid://119576309332002")
	end
	if button:GetAttribute("CollectIconImage") ~= "rbxasset://textures/ui/Controls/TouchTapIcon.png" then
		add(errors, button:GetFullName() .. " missing CollectIconImage TouchTapIcon.png")
	end
end

local function validateRollUpgradeButton(frame, errors)
	local button = descendant(frame, "UpgradeButton", "GuiButton", errors)
	if button and not button:IsA("TextButton") then
		descendant(button, "Price", "TextLabel", errors)
		descendant(button, "CannotAfford", "ImageLabel", errors)
	end
end

local function validateRollLuckHud(rollButtons, errors)
	local frame = child(rollButtons, "UpgradeLuckFrame", "GuiObject", errors)
	if not frame then return end

	descendant(frame, "LuckLabel", "TextLabel", errors)
	validateRollUpgradeButton(frame, errors)
	descendant(frame, "ErrorLabel", "TextLabel", errors)
end

local function validateRollDropAreaHud(rollButtons, errors)
	local frame = child(rollButtons, "RollDropAreaFrame", "GuiObject", errors)
	if not frame then return end

	descendant(frame, "LuckLabel", "TextLabel", errors)
	validateRollUpgradeButton(frame, errors)
	descendant(frame, "ErrorLabel", "TextLabel", errors)
end

local function validateAutoRollHud(rollButtons, errors)
	local frame = child(rollButtons, "AutoRoll", "GuiObject", errors)
	if not frame then return end

	child(frame, "Toggle", "ImageButton", errors)
	child(frame, "Settings", "ImageButton", errors)
	descendant(frame, "TitleLabel", "TextLabel", errors)
end

local function validateSkipTimeButtonCard(skipButtons, cardName, errors, options)
	options = type(options) == "table" and options or {}
	local card = child(skipButtons, cardName, "GuiObject", errors)
	if not card then return end

	descendant(card, "TitleLabel", "TextLabel", errors)
	if options.skipAmount == true then
		descendant(card, "SkipAmount", "TextLabel", errors)
	end
	if options.fruitsLabel == true then
		descendant(card, "FruitsLabel", "TextLabel", errors)
	end
	descendant(card, "ErrorLabel", "TextLabel", errors)
	if options.hitbox == true then
		descendant(card, "Hitbox", "GuiButton", errors)
	end
	local buyButton = descendant(card, "BuyButton", "GuiButton", errors)
	if buyButton then
		descendant(buyButton, "Price", "TextLabel", errors)
	end
end

local function validateSkipTimeButtonsHud(hud, errors)
	local skipButtons = child(hud, "SkipTimeButtons", "GuiObject", errors)
	if not skipButtons then return end

	validateSkipTimeButtonCard(skipButtons, "Skip5m", errors, { skipAmount = true })
	validateSkipTimeButtonCard(skipButtons, "Skip30m", errors, { skipAmount = true })
	validateSkipTimeButtonCard(skipButtons, "CollectAll", errors, { fruitsLabel = true })
end

local function validateAutoRollSettingsUi(menu, errors)
	local panel = child(menu, "AutoRollSettings", "GuiObject", errors)
	if not panel then return end

	descendant(panel, "CloseButton", "GuiButton", errors)
	local list = child(panel, "List", "ScrollingFrame", errors)
	if not list then return end
	child(list, "UIListLayout", "UIListLayout", errors)
	local template = child(list, "Template", "GuiObject", errors)
	if not template then return end
	child(template, "SettingName", "TextLabel", errors)
	child(template, "Background", "GuiObject", errors)
	child(template, "On", "GuiButton", errors)
	child(template, "Off", "GuiButton", errors)
end

local function validateSettingsUi(menu, errors)
	local panel = child(menu, "Settings", "GuiObject", errors)
	if not panel then return end

	descendant(panel, "CloseButton", "GuiButton", errors)
	local list = child(panel, "List", "ScrollingFrame", errors)
	if not list then return end
	child(list, "UIListLayout", "UIListLayout", errors)
	local template = child(list, "Template", "GuiObject", errors)
	if not template then return end
	child(template, "SettingName", "TextLabel", errors)
	child(template, "Background", "GuiObject", errors)
	child(template, "On", "GuiButton", errors)
	child(template, "Off", "GuiButton", errors)
end

local function validateRollBillboards(billboardFolder, errors)
	local function validateTemplate(templateName, labelNames)
		local billboard = child(billboardFolder, templateName, "BillboardGui", errors)
		if not billboard then
			return
		end

		local card = child(billboard, "Card", "GuiObject", errors)
		if not card then
			return
		end

		for _, labelName in ipairs(labelNames) do
			child(card, labelName, "TextLabel", errors)
		end
	end

	validateTemplate("SeedRoll", { "NameLabel", "PriceLabel", "ChanceLabel", "RarityLabel" })
	validateTemplate("MiscRoll", { "NameLabel", "PriceLabel" })
end

local function validateFeedEditUi(ui, hud, billboardFolder, errors)
	if hud then
		descendant(hud, "ExitEditMode", "GuiButton", errors)
	end

	if not billboardFolder then return end
	local placementEdit = child(billboardFolder, "PlacementEdit", "BillboardGui", errors)
	if not placementEdit then return end

	local options = child(placementEdit, "options", "GuiObject", errors)
	if options then
		child(options, "confirm", "GuiButton", errors)
		child(options, "move", "GuiButton", errors)
		child(options, "rotate", "GuiButton", errors)
	end
	child(placementEdit, "tip", "TextLabel", errors)
end

local function validateYesNoWarningUi(menu, errors)
	local warning = child(menu, "YesNoWarning", "GuiObject", errors)
	if not warning then return end

	descendant(warning, "Description", "TextLabel", errors)
	descendant(warning, "Item", "TextLabel", errors)
	descendant(warning, "Yes", "GuiButton", errors)
	descendant(warning, "No", "GuiButton", errors)
	descendant(warning, "CloseButton", "GuiButton", errors)
end

local function validateUpdateLogUi(menu, warnings)
	local updateLog = child(menu, "UpdateLog", "GuiObject", warnings)
	if not updateLog then return end

	descendant(updateLog, "CloseButton", "GuiButton", warnings)
	local updateId = updateLog:GetAttribute(State.UpdateLog.Id)
	if type(updateId) ~= "string" or updateId == "" then
		add(warnings, updateLog:GetFullName() .. " must define a non-empty " .. State.UpdateLog.Id .. " attribute")
	end

	local holder = descendant(updateLog, "SFHolder", "ScrollingFrame", warnings)
	if not holder then return end

	if holder.ScrollingDirection ~= Enum.ScrollingDirection.Y then
		add(warnings, holder:GetFullName() .. " must scroll vertically (ScrollingDirection=Y)")
	end
	if holder.AutomaticCanvasSize ~= Enum.AutomaticSize.Y and holder.CanvasSize.Y.Scale <= 1 and holder.CanvasSize.Y.Offset <= 0 then
		add(warnings, holder:GetFullName() .. " must size its canvas via AutomaticCanvasSize=Y or an explicit CanvasSize")
	end
	if not holder:FindFirstChildOfClass("UIListLayout") then
		add(warnings, holder:GetFullName() .. " must contain a UIListLayout to order update entries")
	end
	if not holder:FindFirstChildWhichIsA("TextLabel") then
		add(warnings, holder:GetFullName() .. " must contain at least one TextLabel update entry")
	end
end

local function validateOnboardingPresentation(ui, hud, billboardFolder, warnings)
	local onboarding = hud and child(hud, "Onboarding", "Frame", warnings)
	if onboarding then
		child(onboarding, "OnboardingText", "TextLabel", warnings)
		local bar = child(onboarding, "Bar", "GuiObject", warnings)
		if bar then
			child(bar, "Fill", "GuiObject", warnings)
		end
	end

	if billboardFolder then
		validateBillboardTemplate(billboardFolder, "ClickerOnboarding", nil, warnings)
	end

	local misc = Assets.Find(Assets.Names.Misc)
	local arrow = misc and misc:FindFirstChild("OnboardingArrow")
	if not arrow then
		add(warnings, "Missing ReplicatedStorage.Assets.Misc.OnboardingArrow")
	elseif not arrow:IsA("Model") then
		add(warnings, string.format("%s is %s, expected Model", arrow:GetFullName(), arrow.ClassName))
	elseif not arrow:FindFirstChildWhichIsA("BasePart", true) then
		add(warnings, arrow:GetFullName() .. " has no BasePart descendants")
	end
end

local function validateRebirthBalance(errors)
	local seenProducts = {}
	local tiers = RebirthBalance.Tiers
	if type(tiers) ~= "table" then
		add(errors, "RebirthBalance.Tiers must be a table")
		return
	end

	for tierNumber, tier in pairs(tiers) do
		local source = "RebirthBalance.Tiers[" .. tostring(tierNumber) .. "]"
		if type(tierNumber) ~= "number" or tierNumber < 1 or tierNumber % 1 ~= 0 then
			add(errors, source .. " has invalid tier number")
		end
		if type(tier) ~= "table" then
			add(errors, source .. " must be a table")
			continue
		end
		if type(tier.Price) ~= "number" or tier.Price <= 0 then
			add(errors, source .. " has invalid Price")
		end

		local skipProductId = tonumber(tier.SkipProductId) or 0
		if skipProductId < 0 or skipProductId % 1 ~= 0 then
			add(errors, source .. " has invalid SkipProductId")
		elseif skipProductId > 0 then
			if seenProducts[skipProductId] then
				add(errors, string.format("Duplicate rebirth SkipProductId %d on tier %s and tier %s", skipProductId, tostring(seenProducts[skipProductId]), tostring(tierNumber)))
			else
				seenProducts[skipProductId] = tierNumber
			end
		end

		for index, reward in ipairs(tier.PetRewards or {}) do
			local petId = type(reward) == "table" and reward.petId or nil
			local amount = type(reward) == "table" and reward.amount or nil
			if type(petId) ~= "string" or not PetCatalog.GetDefinition(petId) then
				add(errors, string.format("%s.PetRewards[%d] has unknown petId %q", source, index, tostring(petId)))
			end
			if type(amount) ~= "number" or amount < 1 or amount % 1 ~= 0 then
				add(errors, string.format("%s.PetRewards[%d] has invalid amount", source, index))
			end
		end

		for index, reward in ipairs(tier.Rewards or {}) do
			if type(reward) ~= "table" then
				add(errors, string.format("%s.Rewards[%d] has unsupported kind", source, index))
				continue
			end
			local amount = reward.amount
			if type(amount) ~= "number" or amount < 1 or amount % 1 ~= 0 then
				add(errors, string.format("%s.Rewards[%d] has invalid amount", source, index))
			end
			if reward.kind == "FeedMachine" then
				if type(reward.feedType) ~= "string" or not FeedMachines.GetTemplate(reward.feedType) then
					add(errors, string.format("%s.Rewards[%d] has unknown feedType %q", source, index, tostring(reward.feedType)))
				end
			elseif reward.kind == "Seed" then
				if type(reward.seedId) ~= "string" or not Seeds.GetTemplate(reward.seedId) then
					add(errors, string.format("%s.Rewards[%d] has unknown seedId %q", source, index, tostring(reward.seedId)))
				end
			else
				add(errors, string.format("%s.Rewards[%d] has unsupported kind %q", source, index, tostring(reward.kind)))
			end
		end
	end
end

local function validateRollLuckBalance(errors)
	RollLuckBalance.Validate(errors)
end

local function validateRollDropAreaBalance(errors)
	RollDropAreaBalance.Validate(errors)
end

local function validateGearShopBalance(errors)
	GearShopBalance.Validate(errors)
	for index, item in ipairs(GearShopBalance.All()) do
		local source = "GearShopBalance.Items[" .. tostring(index) .. "]"
		if item.Kind == GearShopBalance.Kinds.FeedMachine and not FeedMachines.GetTemplate(item.FeedType) then
			add(errors, source .. " has unknown FeedType " .. tostring(item.FeedType))
		end
		if item.Rarity ~= nil and not Rarities.IsValid(item.Rarity) then
			add(errors, source .. " has invalid Rarity " .. tostring(item.Rarity))
		end
	end
end

local function validateCosmeticShopBalance(errors)
	CosmeticShopBalance.Validate(errors)
	for index, item in ipairs(CosmeticShopBalance.All()) do
		local source = "CosmeticShopBalance.Items[" .. tostring(index) .. "]"
		if not Cosmetics.GetTemplate(item.ItemID) then
			add(errors, source .. " has unknown ItemID " .. tostring(item.ItemID))
		end
	end
end

local function validateShopBalance(errors)
	ShopBalance.Validate(errors)
	for packIndex, pack in ipairs(ShopBalance.AllSeedPacks()) do
		local source = "ShopBalance.SeedPacks[" .. tostring(packIndex) .. "]"
		for rewardIndex, reward in ipairs(pack.Rewards or {}) do
			local rewardSource = source .. ".Rewards[" .. tostring(rewardIndex) .. "]"
			if not Seeds.GetTemplate(reward.SeedId) then
				add(errors, rewardSource .. " has unknown SeedId " .. tostring(reward.SeedId))
			end
		end
	end
	local durianPack = ShopBalance.GetDurianPack()
	for rewardIndex, reward in ipairs(durianPack and durianPack.Rewards or {}) do
		if not Seeds.GetTemplate(reward.SeedId) then
			add(errors, "ShopBalance.DurianPack.Rewards[" .. tostring(rewardIndex) .. "] has unknown SeedId " .. tostring(reward.SeedId))
		end
	end
	local endlessPack = ShopBalance.GetEndlessPack()
	for index, seedId in ipairs(endlessPack and endlessPack.SeedSchedule or {}) do
		if not Seeds.GetTemplate(seedId) then
			add(errors, "ShopBalance.EndlessPack.SeedSchedule[" .. tostring(index) .. "] has unknown SeedId " .. tostring(seedId))
		end
	end
	for index, seedId in ipairs(endlessPack and endlessPack.SeedRotation or {}) do
		if not Seeds.GetTemplate(seedId) then
			add(errors, "ShopBalance.EndlessPack.SeedRotation[" .. tostring(index) .. "] has unknown SeedId " .. tostring(seedId))
		end
	end
	for packIndex, starterPack in ipairs(ShopBalance.AllStarterPacks()) do
		for rewardIndex, reward in ipairs(starterPack.Rewards or {}) do
			local rewardSource = "ShopBalance.StarterPacks[" .. tostring(packIndex) .. "].Rewards[" .. tostring(rewardIndex) .. "]"
			if reward.Kind == ShopBalance.StarterPackRewardKinds.Seed and not Seeds.GetTemplate(reward.SeedId) then
				add(errors, rewardSource .. " has unknown SeedId " .. tostring(reward.SeedId))
			end
			if reward.Kind == ShopBalance.StarterPackRewardKinds.FeedMachine
				and not FeedMachines.GetTemplate(reward.FeedType) then
				add(errors, rewardSource .. " has unknown FeedType " .. tostring(reward.FeedType))
			end
		end
	end
end

local function validateCosmeticToolContract(errors)
	local tool = Assets.Find(Assets.Names.CosmeticTool)
	if not tool then
		return
	end
	if not tool:IsA("Tool") then
		add(errors, string.format("%s is %s, expected Tool", tool:GetFullName(), tool.ClassName))
	end
end

local function addProductIdSource(seenProducts, productId, source, errors)
	productId = tonumber(productId) or 0
	if productId <= 0 or productId % 1 ~= 0 then
		return
	end
	local previous = seenProducts[productId]
	if previous then
		add(errors, string.format("Duplicate developer product id %d on %s and %s", productId, previous, source))
	else
		seenProducts[productId] = source
	end
end

local function validateShopProductIds(errors)
	local seenProducts = {}
	for tierNumber, tier in pairs(RebirthBalance.Tiers or {}) do
		if type(tier) == "table" then
			addProductIdSource(seenProducts, tier.SkipProductId, "RebirthBalance.Tiers[" .. tostring(tierNumber) .. "].SkipProductId", errors)
		end
	end
	for index, item in ipairs(GearShopBalance.All()) do
		addProductIdSource(seenProducts, item.DevProductId, "GearShopBalance.Items[" .. tostring(index) .. "].DevProductId", errors)
	end
	for index, item in ipairs(CosmeticShopBalance.All()) do
		addProductIdSource(seenProducts, item.DevProductId, "CosmeticShopBalance.Items[" .. tostring(index) .. "].DevProductId", errors)
	end
	for index, pack in ipairs(ShopBalance.AllSeedPacks()) do
		for productIndex, product in ipairs(ShopBalance.AllSeedPackProducts(pack)) do
			addProductIdSource(
				seenProducts,
				product.DevProductId,
				"ShopBalance.SeedPacks[" .. tostring(index) .. "].Products[" .. tostring(productIndex) .. "].DevProductId",
				errors
			)
		end
	end
	local durianConfig = ShopBalance.DurianPack
	if type(durianConfig) == "table" then
		for index, product in ipairs(durianConfig.TicketProducts or {}) do
			addProductIdSource(
				seenProducts,
				product.DevProductId,
				"ShopBalance.DurianPack.TicketProducts[" .. tostring(index) .. "].DevProductId",
				errors
			)
		end
		for index, product in ipairs(durianConfig.LegacyTicketProducts or {}) do
			addProductIdSource(
				seenProducts,
				product.DevProductId,
				"ShopBalance.DurianPack.LegacyTicketProducts[" .. tostring(index) .. "].DevProductId",
				errors
			)
		end
	end
	local endlessPack = ShopBalance.GetEndlessPack()
	for index, endlessProductId in ipairs(endlessPack and endlessPack.Products or {}) do
		addProductIdSource(seenProducts, endlessProductId, "ShopBalance.EndlessPack.Products[" .. tostring(index) .. "]", errors)
	end
	for index, pack in ipairs(ShopBalance.AllCashPacks()) do
		addProductIdSource(seenProducts, pack.DevProductId, "ShopBalance.CashPacks[" .. tostring(index) .. "].DevProductId", errors)
	end
	for index, starterPack in ipairs(ShopBalance.AllStarterPacks()) do
		addProductIdSource(seenProducts, starterPack.DevProductId, "ShopBalance.StarterPacks[" .. tostring(index) .. "].DevProductId", errors)
	end
	local foodSteal = ShopBalance.GetFoodSteal()
	if foodSteal then
		addProductIdSource(seenProducts, foodSteal.DevProductId, "ShopBalance.FoodSteal.DevProductId", errors)
		for _, rarity in ipairs(Rarities.Order) do
			local tierProductId = foodSteal.TierDevProductIds and foodSteal.TierDevProductIds[rarity]
			if tierProductId then
				addProductIdSource(
					seenProducts,
					tierProductId,
					"ShopBalance.FoodSteal.TierDevProductIds." .. rarity,
					errors
				)
			end
		end
	end
	local collectAll = ShopBalance.GetCollectAll()
	if collectAll then
		addProductIdSource(seenProducts, collectAll.DevProductId, "ShopBalance.CollectAll.DevProductId", errors)
	end
	for _, product in ipairs(ShopBalance.AllGrowSkipProducts()) do
		addProductIdSource(seenProducts, product.DevProductId, "ShopBalance.GrowSkip." .. tostring(product.SkipId) .. ".DevProductId", errors)
	end
	for index, step in ipairs(ShopBalance.AllServerLuckSteps()) do
		addProductIdSource(seenProducts, step.DevProductId, "ShopBalance.ServerLuck.Steps[" .. tostring(index) .. "].DevProductId", errors)
	end
	return seenProducts
end

-- Deferred audit: every configured product id must be a developer product of
-- THIS experience. Prompting another experience's product opens a purchase
-- dialog whose UI never mounts (invisible, and it swallows every later
-- purchase prompt), which presents as "all monetisation is broken" — exactly
-- what a dev place published as a separate experience runs into.
local function auditExperienceProducts(seenProducts)
	local ownProducts = {}
	local ok = pcall(function()
		local pages = MarketplaceService:GetDeveloperProductsAsync()
		while true do
			for _, item in ipairs(pages:GetCurrentPage()) do
				ownProducts[tonumber(item.ProductId)] = true
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
	if not ok then
		return -- offline Studio / API unavailable; nothing trustworthy to report
	end

	local missing = {}
	for productId, source in pairs(seenProducts) do
		if not ownProducts[productId] then
			missing[#missing + 1] = string.format("%s (%d)", source, productId)
		end
	end
	if #missing == 0 then
		return
	end
	table.sort(missing)
	warn(string.format(
		"[AssetValidator] %d configured developer product id(s) are not registered in this experience; "
			.. "purchase prompts for them open a blank dialog and block all later prompts. "
			.. "This place must belong to the same experience as its products. First offenders:\n- %s",
		#missing,
		table.concat(missing, "\n- ", 1, math.min(#missing, 8))
	))
end

local function addRequiredFoodId(requiredFoodIds, sourcesByFoodId, foodId, source, errors)
	if type(foodId) ~= "string" or foodId == "" then
		add(errors, string.format("%s has invalid food id %q", source, tostring(foodId)))
		return
	end

	if not sourcesByFoodId[foodId] then
		sourcesByFoodId[foodId] = {}
		requiredFoodIds[#requiredFoodIds + 1] = foodId
	end
	table.insert(sourcesByFoodId[foodId], source)
end

local function collectFoodDropIds(requiredFoodIds, sourcesByFoodId, errors)
	for _, feedType in ipairs(FeedMachines.AllFeedTypes()) do
		local feedClass = FeedMachines.GetClass(feedType)
		if feedClass == "Tree" or feedClass == "Patch" then
			local template = FeedMachines.GetTemplate(feedType)
			if not template then continue end

			addRequiredFoodId(
				requiredFoodIds,
				sourcesByFoodId,
				template:GetAttribute(State.Feed.FoodDrop),
				string.format("%s %s", feedType, State.Feed.FoodDrop),
				errors
			)
		end
	end
end

local function collectRequiredFoodIds(errors)
	local requiredFoodIds = {}
	local sourcesByFoodId = {}

	collectFoodDropIds(requiredFoodIds, sourcesByFoodId, errors)

	table.sort(requiredFoodIds)
	return requiredFoodIds, sourcesByFoodId
end

local function sourceList(sources)
	return sources and table.concat(sources, ", ") or "unknown source"
end

local function validateFoodTemplates(errors)
	local foodRoot = assetChild(Assets.Names.Food, "Folder", errors)

	local requiredFoodIds, sourcesByFoodId = collectRequiredFoodIds(errors)

	for _, foodId in ipairs(requiredFoodIds) do
		local template = Food.GetTemplate(foodId)
		if not template then
			add(errors, string.format("Missing food template %s (required by %s)", foodId, sourceList(sourcesByFoodId[foodId])))
		elseif template:IsA("Model") and not template.PrimaryPart then
			add(errors, template:GetFullName() .. " missing PrimaryPart")
		end
		if template and not (template:IsA("BasePart") or template:IsA("Model")) then
			add(errors, template:GetFullName() .. " is " .. template.ClassName .. ", expected BasePart or Model")
		end
		if template then
			local templateFoodId = template:GetAttribute(State.Food.Id)
			if type(templateFoodId) ~= "string" then
				add(errors, template:GetFullName() .. " missing " .. State.Food.Id .. " attribute")
			elseif templateFoodId ~= foodId then
				add(errors, string.format(
					"%s has %s=%q, expected %q",
					template:GetFullName(),
					State.Food.Id,
					templateFoodId,
					foodId
				))
			end
		end
		if template and type(template:GetAttribute(State.Food.Type)) ~= "string" then
			add(errors, template:GetFullName() .. " missing " .. State.Food.Type .. " attribute")
		end
	end

	if foodRoot then
		for _, template in ipairs(foodRoot:GetDescendants()) do
			if not (template:IsA("BasePart") or template:IsA("Model")) then
				continue
			end
			for attributeName, replacement in pairs(DEPRECATED_FOOD_ATTRIBUTES) do
				if template:GetAttribute(attributeName) ~= nil then
					add(errors, string.format(
						"%s has deprecated food attribute %s; use %s",
						template:GetFullName(),
						attributeName,
						replacement
					))
				end
			end
			local rarity = template:GetAttribute("Rarity")
			if rarity ~= nil and not Rarities.IsValid(rarity) then
				add(errors, string.format("%s has unknown Rarity %q", template:GetFullName(), tostring(rarity)))
			end
		end
	end
end

local function validateUi(errors, warnings)
	local ui = child(ReplicatedStorage, "UI", "Folder", errors)
	if not ui then return end

	local hud = child(ui, "HUD", "ScreenGui", errors)
	if hud then
		validateHudCurrency(hud, errors)
		validateHoverOverHud(hud, warnings)
		validateJoinBackShowcaseUi(hud, warnings)
		validateServerLuckHud(hud, warnings)
		validateTopBarEventHud(hud, warnings)
		validateUpdateTimerHud(hud, warnings)
		validateVipHud(hud, warnings)
		validateAutoPromptButton(hud, errors)
		validateDurianPackHud(hud, errors)
		local rollButtons = child(hud, "RollButtons", "GuiObject", errors)
		if rollButtons then
			validateRollLuckHud(rollButtons, errors)
			validateRollDropAreaHud(rollButtons, errors)
			validateAutoRollHud(rollButtons, errors)
		end
		validateSkipTimeButtonsHud(hud, errors)
		local leftButtons = child(hud, "LeftButtons", "GuiObject", errors)
		if leftButtons then
			child(leftButtons, "RebirthButton", "GuiButton", errors)
			child(leftButtons, "ShopButton", "GuiButton", errors)
			local eventButton = child(leftButtons, "EventButton", "GuiButton", errors)
			if eventButton then
				child(eventButton, "Alert", "GuiObject", errors)
				child(eventButton, "Icon", "GuiObject", errors)
				-- Swapped in for Icon while Mr Alien's stand is up.
				child(eventButton, "AlienIcon", "GuiObject", errors)
			end
		end
		local notifications = child(hud, "Notifications", "GuiObject", errors)
		if notifications then
			child(notifications, "NotificationTemplate", "TextLabel", errors)
			child(notifications, "UIListLayout", "UIListLayout", errors)
		end
	end

	local menu = child(ui, "Menu", "ScreenGui", errors)
	if menu then
		validateRebirthUi(menu, errors)
		validateGearShopUi(menu, errors)
		validateCosmeticShopUi(menu, errors)
		validateRobuxShopUi(menu, errors)
		validateServerLuckShopUi(menu, warnings)
		validateCashPacksShopUi(menu, warnings)
		validateStarterPackShopUi(menu, warnings)
		validateGamePassShopUi(menu, warnings)
		validateSeedPacksUi(menu, errors)
		validateEndlessPackShopUi(menu, errors)
		validateDurianPackUi(menu, errors)
		validatePackRollFrameUi(menu, errors)
		validateYesNoWarningUi(menu, errors)
		validateUpdateLogUi(menu, warnings)
		validateAutoRollSettingsUi(menu, errors)
		validateSettingsUi(menu, errors)
	end

	local billboardFolder = child(ui, "BillboardGUIs", "Folder", errors)
	if billboardFolder then
		validatePetMoneyBillboard(billboardFolder, errors)
		validateItemAddedDisplayBillboard(billboardFolder, errors)
		validateBillboardTemplate(billboardFolder, "XPBillboard", "XPLabel", errors)
		local timer = validateBillboardTemplate(billboardFolder, "TimerBillboard", "TitleLabel", errors)
		if timer then
			descendant(timer, "TimeLabel", "TextLabel", errors)
		end
		validateRollBillboards(billboardFolder, errors)
		validateStarterPackPromptAssets(billboardFolder, warnings)
	end

	validateFeedEditUi(ui, hud, billboardFolder, errors)
	validateOnboardingPresentation(ui, hud, billboardFolder, errors)

	validatePromptTemplates(ui, errors)
	validateProximityPromptCustomizerUi(ui, errors)
end

local function validateRobuxShopPart(warnings)
	local map = child(Workspace, "Map", nil, warnings)
	if not map then return end
	local shopParts = child(map, "ShopParts", nil, warnings)
	if not shopParts then return end
	child(shopParts, "RobuxShop", "BasePart", warnings)
end

local function validateEventTeleportPart(warnings)
	local map = child(Workspace, "Map", nil, warnings)
	if not map then return end
	local eventFolder = child(map, BeeEvent.MapFolderName, nil, warnings)
	if not eventFolder then return end
	child(eventFolder, BeeEvent.TeleportPartName, "BasePart", warnings)
end

-- Bee event templates: mutation visuals, the swarm bee model, the lighting
-- preset, and the tier reward seeds.
local function validateBeeAssets(errors)
	local lightingRoot = child(ReplicatedStorage, "Lighting", "Folder", errors)
	if lightingRoot then
		validateLightingPreset(lightingRoot, "Bees", errors)
	end

	local mutations = assetChild(Assets.Names.Mutations, "Folder", errors)
	local pollinated = child(mutations, BeeEvent.MutationId, nil, errors)
	if pollinated then
		local xpMultiplier = Mutations.XPMultiplier(Mutations.Ids.Pollinated)
		if type(xpMultiplier) ~= "number" or xpMultiplier <= 0 or xpMultiplier ~= xpMultiplier or math.abs(xpMultiplier) == math.huge then
			add(errors, string.format("%s has invalid configured %s %q", pollinated:GetFullName(), State.Feed.XPMultiplier, tostring(xpMultiplier)))
		end
		if not hasDescendantOfClass(pollinated, "ParticleEmitter") then
			add(errors, pollinated:GetFullName() .. " must contain a ParticleEmitter for mutation visuals")
		end
	end

	local misc = assetChild(Assets.Names.Misc, "Folder", errors)
	local bee = child(misc, BeeEvent.BeeTemplateName, "Model", errors)
	if bee then
		if not bee.PrimaryPart then
			add(errors, bee:GetFullName() .. " must have a PrimaryPart for swarm flight pivots")
		end
		local animated = child(bee, "Animated", "Folder", errors)
		if animated then
			child(animated, "Wing1", "BasePart", errors)
			child(animated, "Wing2", "BasePart", errors)
		end
	end

	for _, tier in ipairs(BeeEvent.Tiers) do
		if not Seeds.GetTemplate(tier.rewardSeedId) then
			add(errors, string.format("Missing Bee event reward seed template for SeedID %q", tostring(tier.rewardSeedId)))
		end
	end
end

-- The Honeycomb camp is Studio-authored world structure; missing pieces warn
-- and degrade (No-Fallback UI Policy) rather than blocking startup.
-- Deliberately warn-and-skip rather than hard-fail, unlike the other non-UI
-- gameplay assets (see AGENTS.md "No-Fallback UI Policy"): pinatas are an
-- admin-only, ephemeral toy with no persistence, so a missing template should
-- disable the feature, not brick startup on a live server. PinataService.Spawn
-- returns a code the admin panel surfaces as a toast.
local function validatePinataAssets(warnings)
	local misc = assetChild(Assets.Names.Misc, "Folder", warnings)
	if misc then
		for _, variantId in ipairs(Pinata.VariantIds) do
			local config = Pinata.VariantConfig(variantId)
			local model = child(misc, config.ModelName, "Model", warnings)
			if model and not model.PrimaryPart then
				add(warnings, model:GetFullName() .. " has no PrimaryPart; pinata spawns will fall back to an arbitrary part")
			end
		end

		local stick = child(misc, Pinata.StickModelName, "Model", warnings)
		if stick then
			-- The weld anchor. Never derive a pivot from a PrimaryPart-less Model.
			if not stick.PrimaryPart then
				add(warnings, stick:GetFullName() .. " needs PrimaryPart set (expected " .. Pinata.StickHandleName .. ") for the hand weld")
			end
			for _, attributeName in ipairs(Pinata.SwingAnimationAttributes) do
				validateAnimationId(stick:GetFullName(), attributeName, stick:GetAttribute(attributeName), warnings)
			end
		end

		local rewards = child(misc, Pinata.RewardsFolderName, "Folder", warnings)
		if rewards then
			local seen = {}
			for _, variantId in ipairs(Pinata.VariantIds) do
				for _, entry in ipairs(Pinata.VariantConfig(variantId).Pool) do
					if not seen[entry.Id] then
						seen[entry.Id] = true
						child(rewards, entry.Id, "BasePart", warnings)
					end
				end
			end
		end
	end

	-- Break confetti burst.
	local vfx = assetChild(Assets.Names.VFX, "Folder", warnings)
	local confetti = vfx and child(vfx, Pinata.BreakVfxName, "BasePart", warnings)
	if confetti and not confetti:FindFirstChildWhichIsA("ParticleEmitter", true) then
		add(warnings, confetti:GetFullName() .. " has no ParticleEmitter; pinata break confetti will be empty")
	end

	local ui = ReplicatedStorage:FindFirstChild("UI")
	local billboards = ui and child(ui, "BillboardGUIs", "Folder", warnings)
	local board = billboards and child(billboards, Pinata.BillboardTemplateName, "BillboardGui", warnings)
	local healthFrame = board and child(board, "Health", "GuiObject", warnings)
	if healthFrame then
		child(healthFrame, "Fill", "GuiObject", warnings)
		child(healthFrame, "Health", "TextLabel", warnings)
	end

	local map = Workspace:FindFirstChild("Map")
	local spawnFolder = map and child(map, Pinata.SpawnFolderName, "Folder", warnings)
	if spawnFolder then
		-- The floor slab lives in this folder and must NOT be counted as a
		-- spawn marker; its top surface is the plane every pinata rests on.
		child(spawnFolder, Pinata.FloorPartName, "BasePart", warnings)
		if #Pinata.SpawnMarkers() == 0 then
			add(warnings, spawnFolder:GetFullName() .. " has no BasePart spawn markers; pinatas cannot spawn")
		end
	end
end

local function validateBeeCamp(warnings)
	local map = child(Workspace, "Map", nil, warnings)
	if not map then return end
	local eventFolder = child(map, BeeEvent.MapFolderName, nil, warnings)
	if not eventFolder then return end

	local hive = child(eventFolder, BeeEvent.HiveModelName, nil, warnings)
	local hiveMesh = hive and child(hive, BeeEvent.HiveMeshName, "BasePart", warnings)
	if hiveMesh then
		for index = 1, BeeEvent.BeeCount do
			child(hiveMesh, BeeEvent.BeeSpawnPrefix .. tostring(index), "Attachment", warnings)
		end
		local timerGui = child(hiveMesh, BeeEvent.HiveTimerGuiName, "BillboardGui", warnings)
		local timerFrame = timerGui and child(timerGui, "Frame", "GuiObject", warnings)
		if timerFrame then
			child(timerFrame, "Timer", "TextLabel", warnings)
		end
	end

	local activeFolder = child(eventFolder, BeeEvent.ActiveFolderName, nil, warnings)
	if not activeFolder then return end
	child(activeFolder, BeeEvent.EventInactiveName, nil, warnings)
	local jar = child(activeFolder, BeeEvent.JarName, nil, warnings)
	local glass = jar and child(jar, BeeEvent.JarGlassName, "BasePart", warnings)
	if jar then
		child(jar, "Fill", "BasePart", warnings)
	end
	if glass then
		local billboard = descendant(glass, BeeEvent.JarBillboardName, "BillboardGui", warnings)
		if billboard then
			descendant(billboard, "Amount", "TextLabel", warnings)
		end
	end
	local beekeeper = child(activeFolder, BeeEvent.BeekeeperName, nil, warnings)
	local rig = beekeeper and child(beekeeper, BeeEvent.BeekeeperName, "Model", warnings)
	local torso = rig and child(rig, "Torso", "BasePart", warnings)
	if torso then
		local dialogue = child(torso, BeeEvent.BeekeeperDialogueGuiName, "BillboardGui", warnings)
		local dialogueFrame = dialogue and child(dialogue, "Frame", "GuiObject", warnings)
		if dialogueFrame then
			child(dialogueFrame, "Dialogue", "TextLabel", warnings)
		end
	end
end

-- Mr Alien's stand template. It lives in ReplicatedStorage (not the map) and
-- is cloned into Workspace.Map only while an operator has the stand up, so a
-- broken template warns rather than failing startup: the rest of the game does
-- not depend on it.
local function validateLeaderboards(warnings)
	local folder = child(Workspace, Leaderboards.FolderName, "Folder", warnings)
	if not folder then
		return
	end

	for _, board in ipairs(Leaderboards.Boards) do
		local model = child(folder, board.ModelName, "Model", warnings)
		if model then
			-- StreamingEnabled is on and these are fixed world POIs: without
			-- Persistent they stream out for distant players and the client
			-- controller's cached references go dead.
			if model.ModelStreamingMode ~= Enum.ModelStreamingMode.Persistent then
				add(warnings, string.format(
					"%s is %s, expected Persistent; the board will stream out for distant players",
					model:GetFullName(),
					tostring(model.ModelStreamingMode)
				))
			end

			local gui = descendant(model, "LeaderboardGui", "SurfaceGui", warnings)
			if gui then
				child(gui, "Header", "TextLabel", warnings)
				child(gui, "Subheader", "TextLabel", warnings)
				local frame = child(gui, "LeaderboardFrame", "ScrollingFrame", warnings)
				if frame then
					local templateNames = { Leaderboards.RowTemplateName }
					for _, podium in ipairs(Leaderboards.PodiumTemplateNames) do
						templateNames[#templateNames + 1] = podium
					end
					for _, name in ipairs(templateNames) do
						local template = child(frame, name, "Frame", warnings)
						if template then
							child(template, "NameLabel", "TextLabel", warnings)
							child(template, "ValueLabel", "TextLabel", warnings)
							child(template, "PlayerImageLabel", "ImageLabel", warnings)
							local placement = child(template, "Placement", "Frame", warnings)
							if placement then
								child(placement, "RankLabel", "TextLabel", warnings)
							end
						end
					end
				end
			end

			local yourStat = descendant(model, "YourStat", "SurfaceGui", warnings)
			if yourStat then
				child(yourStat, "Label", "TextLabel", warnings)
				child(yourStat, "LocalScoreLabel", "TextLabel", warnings)
			end
		end
	end
end

local function validateAlienStand(warnings)
	if not AlienStand.Enabled then
		return
	end
	local assetRoot = child(ReplicatedStorage, Assets.FolderName, "Folder", warnings)
	local adminEvents = assetRoot and child(assetRoot, AlienStand.AssetsFolderName, nil, warnings)
	local template = adminEvents and child(adminEvents, AlienStand.TemplateName, nil, warnings)
	if not template then
		return
	end

	child(template, AlienStand.PlatformName, "Model", warnings)
	child(template, AlienStand.UfoName, "Model", warnings)
	child(template, AlienStand.TeleportPartName, "BasePart", warnings)

	local rig = child(template, AlienStand.NpcName, "Model", warnings)
	if rig then
		child(rig, "Humanoid", "Humanoid", warnings)
		-- Only the root is anchored; the rest of the rig hangs off Motor6Ds so
		-- the idle track and the neck tilt still animate.
		local root = child(rig, "HumanoidRootPart", "BasePart", warnings)
		if root and not root.Anchored then
			add(warnings, root:GetFullName() .. " is not anchored; Mr Alien will fall through his platform")
		end
		local torso = child(rig, "Torso", "BasePart", warnings)
		if torso then
			child(torso, "Neck", "Motor6D", warnings)
			local dialogue = child(torso, AlienStand.NpcDialogueGuiName, "BillboardGui", warnings)
			local dialogueFrame = dialogue and child(dialogue, "Frame", "GuiObject", warnings)
			if dialogueFrame then
				child(dialogueFrame, "Dialogue", "TextLabel", warnings)
			end
		end
	end

	local crate = child(template, AlienStand.CrateName, "Model", warnings)
	if crate then
		local body = child(crate, AlienStand.CrateBodyName, "BasePart", warnings)
		child(crate, AlienStand.CrateFillName, "BasePart", warnings)
		if body then
			local billboard = descendant(body, AlienStand.CrateBillboardName, "BillboardGui", warnings)
			if billboard then
				descendant(billboard, "Amount", "TextLabel", warnings)
			end
		end
	end

	for _, tier in ipairs(AlienStand.Tiers) do
		if not Seeds.GetTemplate(tier.rewardSeedId) then
			add(warnings, "AlienStand tier reward has unknown seed id " .. tostring(tier.rewardSeedId))
		end
	end
end

local function validateGroupReward(errors)
	if type(GroupReward.GroupId) ~= "number" or GroupReward.GroupId <= 0 or GroupReward.GroupId % 1 ~= 0 then
		add(errors, "GroupReward.GroupId must be a positive integer group id")
	end

	local reward = GroupReward.Reward
	if type(reward) ~= "table" then
		add(errors, "GroupReward.Reward must be a table")
	else
		if reward.Type ~= GroupReward.RewardTypes.Seed then
			add(errors, "GroupReward.Reward.Type must be " .. tostring(GroupReward.RewardTypes.Seed))
		end
		if type(reward.Id) ~= "string" or not Seeds.GetTemplate(reward.Id) then
			add(errors, "GroupReward.Reward.Id has unknown seed id " .. tostring(reward.Id))
		end
		if type(reward.Quantity) ~= "number" or reward.Quantity < 1 or reward.Quantity % 1 ~= 0 then
			add(errors, "GroupReward.Reward.Quantity must be a positive integer")
		end
	end

	local model = child(Workspace, GroupReward.ModelName, "Model", errors)
	local touchPart = model and child(model, GroupReward.TouchPartName, "BasePart", errors)
	if touchPart and touchPart.Transparency < 1 then
		add(errors, touchPart:GetFullName() .. " should remain invisible; it is only the prompt target")
	end
	local visual = model and model:FindFirstChild(GroupReward.VisualName, true)
	if not visual then
		add(errors, "Missing reward visual Workspace." .. tostring(GroupReward.ModelName) .. "." .. tostring(GroupReward.VisualName))
	elseif not (visual:IsA("BasePart") or visual:IsA("Model")) then
		add(errors, string.format("%s is %s, expected BasePart or Model", visual:GetFullName(), visual.ClassName))
	end
end

local function validateRemotes(errors)
	local ok, err = pcall(function()
		Remotes.validateAll()
	end)
	if not ok then add(errors, tostring(err)) end
end

local function validatePlayerStateContract(errors)
	if PlayerState.Fields.StarterPackPurchased ~= "StarterPackPurchased" then
		add(errors, "PlayerState.Fields.StarterPackPurchased must remain the legacy starter-pack boolean")
	end
	if PlayerState.Fields.StarterPackPurchases ~= "StarterPackPurchases" then
		add(errors, "PlayerState.Fields.StarterPackPurchases is required for per-pack starter ownership")
	end
end

local function validatePlots(errors, warnings)
	local plotsFolder = Workspace:FindFirstChild("Plots")
	local foundPlot = false
	local rootPlots = {}
	local misc = Assets.Find(Assets.Names.Misc)
	local plotTemplate = misc and child(misc, "PlotTemplate", "Model", errors) or nil
	local loadingPadsFolder = child(Workspace, "PlotTemplates", "Folder", errors)

	for _, instance in ipairs(Workspace:GetChildren()) do
		if instance.Name:match("^Plot%d+$") then
			rootPlots[#rootPlots + 1] = instance
		end
	end

	if plotsFolder and not plotsFolder:IsA("Folder") then
		add(errors, string.format("%s is %s, expected Folder", plotsFolder:GetFullName(), plotsFolder.ClassName))
		plotsFolder = nil
	end

	local function validateGridPart(plot, floor, part, folderName, seenCoords)
		if not part:IsA("BasePart") then
			add(errors, string.format("%s.%s contains %s %s, expected BasePart GridPart", plot:GetFullName(), folderName, part.ClassName, part.Name))
			return
		end

		local gridX = PlotGrid.NormalizeInteger(part:GetAttribute(PlotGrid.Attributes.X))
		local gridZ = PlotGrid.NormalizeInteger(part:GetAttribute(PlotGrid.Attributes.Z))
		if not gridX or not gridZ then
			add(errors, part:GetFullName() .. " missing integer GridX/GridZ attributes")
			return
		end
		local key = PlotGrid.CoordKey(gridX, gridZ)
		if seenCoords[key] then
			add(errors, string.format("Duplicate GridX/GridZ %s on %s and %s", key, seenCoords[key]:GetFullName(), part:GetFullName()))
		else
			seenCoords[key] = part
		end

		if folderName == PlotGrid.Folders.Unlockable then
			local price = PlotGrid.NormalizeNonNegativeNumber(part:GetAttribute(PlotGrid.Attributes.UnlockPrice))
			if not price or price <= 0 then
				add(errors, part:GetFullName() .. " missing positive UnlockPrice attribute")
			end
			child(part, "VacantGrid", "Model", errors)
		end

		if floor then
			local localPosition = floor.CFrame:PointToObjectSpace(part.Position)
			if math.abs(localPosition.Y) > math.max(floor.Size.Y, part.Size.Y) + 0.05 then
				add(errors, part:GetFullName() .. " is not coplanar with Floor coordinate frame")
			end
			local upDot = math.abs(part.CFrame.UpVector:Dot(floor.CFrame.UpVector))
			if upDot < 0.999 then
				add(errors, part:GetFullName() .. " is not aligned with Floor up axis")
			end
		end

		for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
			local fence = part:FindFirstChild("Fence" .. tostring(sideNumber))
			if folderName == PlotGrid.Folders.Unlockable and (not fence or not (fence:IsA("Model") or fence:IsA("BasePart"))) then
				add(errors, string.format("Missing %s.Fence%d Model/BasePart", part:GetFullName(), sideNumber))
			end
		end

		for cornerName in pairs(PlotGrid.Corners) do
			local corner = part:FindFirstChild(cornerName)
			if folderName == PlotGrid.Folders.Unlockable and (not corner or not corner:IsA("BasePart")) then
				add(errors, string.format("Missing %s.%s BasePart", part:GetFullName(), cornerName))
			end
		end
	end

	local function validatePlotShape(plot)
		local floor = plot:FindFirstChild("Floor")
		if floor and not floor:IsA("BasePart") then
			add(errors, string.format("%s is %s, expected optional BasePart Floor", floor:GetFullName(), floor.ClassName))
			floor = nil
		end
		child(plot, "SpawnLocation", "SpawnLocation", errors)

		if floor then
			if floor.Transparency < 1 or floor.CanCollide or floor.CanTouch or floor.CanQuery then
				add(errors, floor:GetFullName() .. " must be an invisible non-colliding coordinate frame")
			end
		end

		local seenCoords = {}
		for _, folderName in ipairs({ PlotGrid.Folders.Starter, PlotGrid.Folders.Unlockable }) do
			local folder = child(plot, folderName, "Folder", errors)
			if folder then
				local gridCount = 0
				for _, instance in ipairs(folder:GetChildren()) do
					if instance:IsA("BasePart") then
						gridCount += 1
						validateGridPart(plot, floor, instance, folderName, seenCoords)
					end
				end
				if gridCount == 0 then
					add(errors, folder:GetFullName() .. " must contain at least one GridPart BasePart")
				end
			end
		end

		local gridAreas = plot:FindFirstChild(PlotGrid.Folders.Unlockable)
		local sourceFence = false
		if gridAreas then
			for _, instance in ipairs(gridAreas:GetChildren()) do
				if instance:IsA("BasePart") and instance:FindFirstChild("Fence1") and instance:FindFirstChild("CornerFence1_2") then
					sourceFence = true
					break
				end
			end
		end
		if not sourceFence then
			add(errors, plot:GetFullName() .. " needs at least one GridAreas GridPart with fence/corner source assets")
		end

		local rollArea = child(plot, "RollArea", "Folder", errors)
		local buttonFolder = rollArea and child(rollArea, "Button", "Folder", errors)
		if buttonFolder then
			child(buttonFolder, "Button", "BasePart", errors)
			for index = 1, RollDropAreaBalance.TotalPads do
				local dropArea = child(buttonFolder, "DropArea" .. tostring(index), "Model", errors)
				if dropArea then
					child(dropArea, "CrateFloor", "BasePart", errors)
				end
			end
		end

		local adminParty = child(plot, "AdminParty", "Folder", errors)
		local adminDropArea = adminParty and child(adminParty, "AdminPartyDropArea", "Model", errors)
		if adminDropArea then
			child(adminDropArea, "CrateFloor", "BasePart", errors)
		end

		local signs = child(plot, "Signs", "Folder", errors)
		if signs then
			local playerSign = child(signs, "PlayerSign", "Model", errors)
			if playerSign then
				local playerNameGui = descendant(playerSign, "PlayerName", "SurfaceGui", errors)
				local playerInfo = playerNameGui and child(playerNameGui, "PlayerInfo", "GuiObject", errors)
				if playerInfo then
					child(playerInfo, "Name", "TextLabel", errors)
					child(playerInfo, "Farm", "TextLabel", errors)
				end

				local earnRateGui = descendant(playerSign, "EarnRate", "SurfaceGui", errors)
				local earnRateFrame = earnRateGui and child(earnRateGui, "EarnRate", "GuiObject", errors)
				if earnRateFrame then
					child(earnRateFrame, "EarnRate", "TextLabel", errors)
				end
			end

			local mailbox = child(signs, "Mailbox", "Model", errors)
			if mailbox then
				child(mailbox, "Door", "BasePart", errors)
			end

			local skipSign = child(signs, "SkipTimeSign", "Model", errors)
			if skipSign then
				if not skipSign:FindFirstChildWhichIsA("BasePart", true) then
					add(errors, skipSign:GetFullName() .. " needs at least one BasePart")
				end
				local signGui = descendant(skipSign, "SurfaceGui", "SurfaceGui", errors)
				local signButtons = signGui and child(signGui, "SkipTimeButtons", "GuiObject", errors)
				if signButtons then
					validateSkipTimeButtonCard(signButtons, "Skip5m", errors, { skipAmount = true, hitbox = true })
					validateSkipTimeButtonCard(signButtons, "Skip30m", errors, { skipAmount = true, hitbox = true })
					validateSkipTimeButtonCard(signButtons, "CollectAll", errors, { fruitsLabel = true, hitbox = true })
				end
			end
		end
	end

	local function validateLoadingPads(folder)
		if not folder then return end

		local seenByNumber = {}
		local padCount = 0
		for _, pad in ipairs(folder:GetChildren()) do
			if not pad:IsA("BasePart") then
				add(errors, string.format("%s is %s, expected numbered BasePart plot loading pad", pad:GetFullName(), pad.ClassName))
				continue
			end

			local plotNumber = tonumber(pad.Name:match(PLOT_NAME_PATTERN))
			if not plotNumber then
				add(errors, pad:GetFullName() .. " must be named Plot<number>")
				continue
			end

			padCount += 1
			if seenByNumber[plotNumber] then
				add(errors, string.format(
					"Duplicate plot loading pad number %d on %s and %s",
					plotNumber,
					seenByNumber[plotNumber]:GetFullName(),
					pad:GetFullName()
				))
			else
				seenByNumber[plotNumber] = pad
			end
		end

		if padCount == 0 then
			add(errors, folder:GetFullName() .. " must contain at least one numbered plot loading pad")
			return
		end
		for index = 1, padCount do
			if not seenByNumber[index] then
				add(errors, string.format("%s loading pads must be numbered contiguously from Plot1; missing Plot%d", folder:GetFullName(), index))
			end
		end
	end

	local function validatePlotList(plots, sourceName)
		local seenNames = {}
		for _, plot in ipairs(plots) do
			if not plot:IsA("Model") then
				add(errors, string.format("%s is %s, expected Model plot", plot:GetFullName(), plot.ClassName))
				continue
			end
			if not plot.Name:match(PLOT_NAME_PATTERN) then
				add(errors, string.format("%s has invalid plot name; expected Plot<number>", plot:GetFullName()))
			end
			local previous = seenNames[plot.Name]
			if previous then
				add(errors, string.format("Duplicate plot name %s in %s: %s and %s", plot.Name, sourceName, previous:GetFullName(), plot:GetFullName()))
			else
				seenNames[plot.Name] = plot
			end
			foundPlot = true
			validatePlotShape(plot)
		end
	end

	if plotTemplate then
		validatePlotShape(plotTemplate)
	end
	validateLoadingPads(loadingPadsFolder)

	if plotsFolder then
		if #rootPlots > 0 then
			add(errors, "Found both Workspace.Plots and root Workspace.Plot# models; use one plot layout so client plot resolution is unambiguous")
		end
		validatePlotList(plotsFolder:GetChildren(), "Workspace.Plots")
	else
		validatePlotList(rootPlots, "Workspace")
	end

	if not foundPlot then
		add(errors, "No plots found in Workspace.Plots or Workspace.Plot#")
	end
end

local function validateLoadingScreenSource(warnings)
	local loadingScreen = ReplicatedFirst:FindFirstChild("LoadingScreen")
	if not (loadingScreen and loadingScreen:IsA("ScreenGui")) then
		add(warnings, "Missing ReplicatedFirst.LoadingScreen ScreenGui for join-back showcase timing")
	end

	local loader = ReplicatedFirst:FindFirstChild("LoadingScreenLoader")
	if not (loader and loader:IsA("LocalScript")) then
		add(warnings, "Missing ReplicatedFirst.LoadingScreenLoader LocalScript for join-back showcase timing")
	end
end

function AssetValidator.validate()
	local errors = {}
	local warnings = {}

	local assetRoot = child(ReplicatedStorage, Assets.FolderName, "Folder", errors)
	for _, name in ipairs(REQUIRED_ASSET_ROOTS) do
		if assetRoot then
			child(assetRoot, name, nil, errors)
		end
	end
	for _, name in ipairs(REQUIRED_REPLICATED_ROOTS) do
		child(ReplicatedStorage, name, nil, errors)
	end
	validateClientSounds(errors)
	validateMusicPlaylist(errors)
	validateAnimalAmbientSounds(errors)
	validateThunderstormAssets(errors, warnings)
	validateAlienEventAssets(errors)
	validateTornadoAssets(errors)
	validateTsunamiAssets(errors)
	validateEarthquakeAssets(errors)
	validateBeeAssets(errors)
	validateReplica(errors)
	for _, toolName in ipairs(REQUIRED_TOOLS) do
		validateTool(assetRoot and assetRoot:FindFirstChild(toolName), errors)
	end

	validateRemotes(errors)
	validatePlayerStateContract(errors)
	validatePetCatalog(errors)
	validateFeedTemplates(errors, warnings)
	validateSeeds(errors)
	validateCosmetics(errors, warnings)
	validateMisc(errors)
	validateVfx(errors)
	validateCrates(errors)
	validateRebirthBalance(errors)
	validateRollLuckBalance(errors)
	validateRollDropAreaBalance(errors)
	validateGearShopBalance(errors)
	validateCosmeticShopBalance(errors)
	validateShopBalance(errors)
	local seenProducts = validateShopProductIds(errors)
	task.spawn(auditExperienceProducts, seenProducts)
	validateCosmeticToolContract(errors)
	validateFoodTemplates(errors)
	validateUi(warnings, warnings)
	validateRobuxShopPart(warnings)
	validateEventTeleportPart(warnings)
	validateBeeCamp(warnings)
	validateLeaderboards(warnings)
	validateAlienStand(warnings)
	validatePinataAssets(warnings)
	validateLoadingScreenSource(warnings)
	validateGroupReward(errors)
	validatePlots(errors, warnings)

	if #warnings > 0 then
		warn("[AssetValidator] Studio asset warnings:\n- " .. table.concat(warnings, "\n- "))
	end
	if #errors > 0 then
		error("[AssetValidator] Startup asset validation failed:\n- " .. table.concat(errors, "\n- "))
	end
end

return AssetValidator
