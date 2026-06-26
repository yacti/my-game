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
	"BirdBackingTrack",
	"Wind",
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

local EXPECTED_COMMON_SEED_ROLL_CHANCES = {
	AppleTreeSeed = 2,
	PumpkinSeed = 3,
	CabbageSeed = 16,
	PotatoSeed = 28,
	OrangeTreeSeed = 45,
	WatermelonSeed = 75,
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
		if not hasDescendantOfClass(lightning, "Highlight") then
			add(errors, lightning:GetFullName() .. " must contain a Highlight for mutation visuals")
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

	for _, model in ipairs(petModels:GetChildren()) do
		if not model:IsA("Model") then
			continue
		end

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
			if feedClass == "Patch" and feedXP == nil then
				add(errors, string.format("%s missing required %s attribute", template:GetFullName(), State.Feed.XP))
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
			if feedClass == "Patch" then
				validatePatchEditSelectionHitbox(template, errors)
			elseif feedClass == "Tree" then
				validateTreeClickTarget(template, errors, warnings)
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

		local foodType = jamBarrel:GetAttribute(State.Feed.FoodType)
		if type(foodType) ~= "string" or foodType == "" then
			add(errors, string.format("%s missing valid %s", jamBarrel:GetFullName(), State.Feed.FoodType))
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
		end

		local rollChanceN = template:GetAttribute(Seeds.Attributes.RollChanceN)
		local rollProbability = RollChances.BaseWeightForChance(rollChanceN)
		if not rollProbability then
			add(errors, string.format("%s has invalid %s %q", template:GetFullName(), Seeds.Attributes.RollChanceN, tostring(rollChanceN)))
		else
			explicitRollProbability += rollProbability
			local expectedChanceN = type(seedId) == "string" and EXPECTED_COMMON_SEED_ROLL_CHANCES[seedId] or nil
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
	local buyButtons = descendant(template, "BuyBtns", "GuiObject", errors)
	if buyButtons then
		local cashButton = descendant(buyButtons, "CashBtn", "GuiButton", errors)
		if cashButton then
			descendant(cashButton, "Price", "TextLabel", errors)
			descendant(cashButton, "CannotAfford", "ImageLabel", errors)
		end
		local robuxButton = descendant(buyButtons, "RobuxBtn", "GuiButton", errors)
		if robuxButton then
			descendant(robuxButton, "Price", "TextLabel", errors)
		end
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
	descendant(panel, "SFHolder", "ScrollingFrame", errors)
end

local function validateSeedPackCard(card, source, errors)
	descendant(card, "Title", "TextLabel", errors)
	descendant(card, "BuyButton", "GuiButton", errors)
	descendant(card, "BuyThree", "GuiButton", errors)
	local iconHolder = descendant(card, "IconHolder", "GuiObject", errors)
	if iconHolder then
		child(iconHolder, "Icon", "ImageLabel", errors)
	end

	local items = child(card, "Items", "GuiObject", errors)
	if not items then
		return
	end
	local templates = {}
	for _, item in ipairs(items:GetChildren()) do
		if item.Name == "Template" and item:IsA("GuiObject") then
			templates[#templates + 1] = item
		end
	end
	if #templates ~= 3 then
		add(errors, source .. ".Items must contain exactly three Template GuiObjects")
	end
	for index, template in ipairs(templates) do
		local templateSource = source .. ".Items.Template[" .. tostring(index) .. "]"
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
	if not seedPacks then return end

	for _, pack in ipairs(ShopBalance.AllSeedPacks()) do
		local card = child(seedPacks, pack.PackId, "GuiObject", errors)
		if card then
			validateSeedPackCard(card, "ReplicatedStorage.UI.Menu.RobuxShop.SFHolder.SeedPacks." .. tostring(pack.PackId), errors)
		end
	end
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
	local price = buyButton and child(buyButton, "Price", "TextLabel", warnings)
	if price then
		descendant(price, "Price", "TextLabel", warnings)
	end
end

local function validateCashPackShopCard(card, warnings)
	descendant(card, "Amount", "TextLabel", warnings)
	local buyButton = child(card, "BuyButton", "GuiButton", warnings)
	local price = buyButton and child(buyButton, "Price", "TextLabel", warnings)
	if price then
		descendant(price, "Price", "TextLabel", warnings)
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
	local starterPack = ShopBalance.GetStarterPack()
	local expectedTemplates = #(starterPack and starterPack.Rewards or {})
	local hasCashReward = false
	for _, reward in ipairs(starterPack and starterPack.Rewards or {}) do
		if reward.Kind == ShopBalance.StarterPackRewardKinds.Cash then
			hasCashReward = true
			break
		end
	end

	local panel = child(menu, "RobuxShop", "GuiObject", warnings)
	if not panel then return end
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", warnings)
	local featured = holder and child(holder, "Featured", "GuiObject", warnings)
	local card = featured and child(featured, "StarterPack", "GuiObject", warnings)
	if not card then return end

	local buyButton = child(card, "BuyButton", "GuiButton", warnings)
	local price = buyButton and child(buyButton, "Price", "TextLabel", warnings)
	if price then
		descendant(price, "Price", "TextLabel", warnings)
	end
	child(card, "Sold", "ImageLabel", warnings)

	local items = child(card, "Items", "GuiObject", warnings)
	if not items then
		return
	end
	local templates = {}
	for _, item in ipairs(items:GetChildren()) do
		if item.Name == "Template" and item:IsA("GuiObject") then
			templates[#templates + 1] = item
		end
	end
	if #templates ~= expectedTemplates then
		add(warnings, string.format(
			"ReplicatedStorage.UI.Menu.RobuxShop.SFHolder.Featured.StarterPack.Items must contain exactly %d Template GuiObjects",
			expectedTemplates
		))
	end
	for index, template in ipairs(templates) do
		local source = "ReplicatedStorage.UI.Menu.RobuxShop.SFHolder.Featured.StarterPack.Items.Template[" .. tostring(index) .. "]"
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

local function validateGamePassShopCard(card, warnings)
	local buyButton = child(card, "BuyButton", "GuiButton", warnings)
	local price = buyButton and child(buyButton, "Price", "TextLabel", warnings)
	if price then
		descendant(price, "Price", "TextLabel", warnings)
	end
	child(card, "Sold", "ImageLabel", warnings)
end

local function validateGamePassShopUi(menu, warnings)
	local panel = child(menu, "RobuxShop", "GuiObject", warnings)
	if not panel then return end
	local holder = descendant(panel, "SFHolder", "ScrollingFrame", warnings)
	local featured = holder and child(holder, "Featured", "GuiObject", warnings)
	local gamepasses = holder and child(holder, "Gamepasses", "GuiObject", warnings)

	for _, pass in ipairs(ShopBalance.AllGamePasses()) do
		if type(pass.FeaturedCardName) == "string" and pass.FeaturedCardName ~= "" then
			local featuredCard = featured and child(featured, pass.FeaturedCardName, "GuiObject", warnings)
			if featuredCard then
				validateGamePassShopCard(featuredCard, warnings)
			end
		end

		local gamepassesCard = gamepasses and child(gamepasses, pass.ShopCardName, "GuiObject", warnings)
		if gamepassesCard then
			validateGamePassShopCard(gamepassesCard, warnings)
		end
	end
end

local function validatePackRollFrameUi(menu, errors)
	local panel = child(menu, "PackRollFrame", "GuiObject", errors)
	if not panel then return end

	local itemRollHolder = child(panel, "ItemRollHolder", "GuiObject", errors)
	child(panel, "ContinueButton", "GuiButton", errors)
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
	child(packHolder, "Pack", "ImageButton", errors)
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

local function validateAutoRollSettingsUi(menu, errors)
	local panel = child(menu, "AutoRollSettings", "GuiObject", errors)
	if not panel then return end

	descendant(panel, "CloseButton", "GuiButton", errors)
	local list = child(panel, "List", "ScrollingFrame", errors)
	if not list then return end
	child(list, "UIListLayout", "UIListLayout", errors)
	local template = child(list, "Template", "GuiObject", errors)
	if not template then return end
	child(template, "Icon", "ImageLabel", errors)
	child(template, "SettingName", "TextLabel", errors)
	child(template, "Background", "GuiObject", errors)
	local toggle = child(template, "ToggleButton", "GuiButton", errors)
	if toggle then
		child(toggle, "On", "ImageLabel", errors)
		child(toggle, "Off", "ImageLabel", errors)
		descendant(toggle, "StatusTxt", "TextLabel", errors)
	end
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
	local starterPack = ShopBalance.GetStarterPack()
	if starterPack then
		for rewardIndex, reward in ipairs(starterPack.Rewards or {}) do
			local rewardSource = "ShopBalance.StarterPack.Rewards[" .. tostring(rewardIndex) .. "]"
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
		addProductIdSource(seenProducts, pack.DevProductId, "ShopBalance.SeedPacks[" .. tostring(index) .. "].DevProductId", errors)
		addProductIdSource(seenProducts, pack.BuyThreeDevProductId, "ShopBalance.SeedPacks[" .. tostring(index) .. "].BuyThreeDevProductId", errors)
	end
	for index, pack in ipairs(ShopBalance.AllCashPacks()) do
		addProductIdSource(seenProducts, pack.DevProductId, "ShopBalance.CashPacks[" .. tostring(index) .. "].DevProductId", errors)
	end
	local starterPack = ShopBalance.GetStarterPack()
	if starterPack then
		addProductIdSource(seenProducts, starterPack.DevProductId, "ShopBalance.StarterPack.DevProductId", errors)
	end
	local foodSteal = ShopBalance.GetFoodSteal()
	if foodSteal then
		addProductIdSource(seenProducts, foodSteal.DevProductId, "ShopBalance.FoodSteal.DevProductId", errors)
	end
	local growSkip = ShopBalance.GetGrowSkip()
	if growSkip then
		addProductIdSource(seenProducts, growSkip.DevProductId, "ShopBalance.GrowSkip.DevProductId", errors)
	end
	for index, step in ipairs(ShopBalance.AllServerLuckSteps()) do
		addProductIdSource(seenProducts, step.DevProductId, "ShopBalance.ServerLuck.Steps[" .. tostring(index) .. "].DevProductId", errors)
	end
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
		local rollButtons = child(hud, "RollButtons", "GuiObject", errors)
		if rollButtons then
			validateRollLuckHud(rollButtons, errors)
			validateRollDropAreaHud(rollButtons, errors)
			validateAutoRollHud(rollButtons, errors)
		end
		local leftButtons = child(hud, "LeftButtons", "GuiObject", errors)
		if leftButtons then
			child(leftButtons, "RebirthButton", "GuiButton", errors)
			child(leftButtons, "ShopButton", "GuiButton", errors)
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
		validatePackRollFrameUi(menu, errors)
		validateYesNoWarningUi(menu, errors)
		validateUpdateLogUi(menu, warnings)
		validateAutoRollSettingsUi(menu, errors)
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
	validateReplica(errors)
	for _, toolName in ipairs(REQUIRED_TOOLS) do
		validateTool(assetRoot and assetRoot:FindFirstChild(toolName), errors)
	end

	validateRemotes(errors)
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
	validateShopProductIds(errors)
	validateCosmeticToolContract(errors)
	validateFoodTemplates(errors)
	validateUi(warnings, warnings)
	validateRobuxShopPart(warnings)
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
