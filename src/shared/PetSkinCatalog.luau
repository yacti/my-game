local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(script.Parent:WaitForChild("Assets"))
local Rarities = require(script.Parent:WaitForChild("Rarities"))
local State = require(script.Parent:WaitForChild("State"))

local PetSkinCatalog = {}

-- World skins keep each template's authored model scale as pet scale factor 1;
-- PlotService applies the normal pet XP curve on top. ToolMaxDimension and
-- ViewportScaleMultiplier are presentation-only and do not affect world pets.
-- Skin audio stays on the existing animal/evolution sound path. SoundId is
-- used for catalog-owned apply audio; SoundPetId reuses an authored animal
-- sound for skin application, ambient calls, and evolution bursts.
local DEFINITIONS = {
	PufferfishSkin = {
		Rarity = Rarities.Epic,
		Weight = 55,
		IdleAnimationId = "rbxassetid://92235400477279",
		WalkAnimationId = "rbxassetid://119044259165915",
		SoundId = "rbxassetid://18982723119",
		ToolMaxDimension = 1.5,
		WorldYawDegrees = 0,
		ToolYawDegrees = 0,
		ViewportYawDegrees = 0,
		ViewportScaleMultiplier = 1,
	},
	PegasusSkin = {
		Rarity = Rarities.Legendary,
		Weight = 39,
		IdleAnimationId = "rbxassetid://108556268538405",
		WalkAnimationId = "rbxassetid://122231535526772",
		SoundPetId = "Pet53", -- Reuse the authored Unicorn animal sound exactly.
		ToolMaxDimension = 1.5,
		WorldYawDegrees = 0,
		ToolYawDegrees = 0,
		ViewportYawDegrees = 0,
		ViewportScaleMultiplier = 1.5,
	},
	KrakenSkin = {
		Rarity = Rarities.Mythical,
		Weight = 5,
		IdleAnimationId = "rbxassetid://117896877859252",
		WalkAnimationId = "rbxassetid://100712438640875",
		SoundId = "rbxassetid://129818780095953",
		ToolMaxDimension = 1.5,
		WorldYawDegrees = 0,
		ToolYawDegrees = 0,
		ViewportYawDegrees = 0,
		ViewportScaleMultiplier = 1.25,
	},
	DragonSkin = {
		Rarity = Rarities.Secret,
		Weight = 1,
		IdleAnimationId = "rbxassetid://108556268538405",
		WalkAnimationId = "rbxassetid://122231535526772",
		SoundId = "rbxassetid://122225901664901",
		ToolMaxDimension = 1.5,
		WorldYawDegrees = 0,
		ToolYawDegrees = 0,
		ViewportYawDegrees = 0,
		ViewportScaleMultiplier = 2,
	},
}

local ORDER = { "PufferfishSkin", "PegasusSkin", "KrakenSkin", "DragonSkin" }

local function copyDefinition(petSkinId, definition)
	if not definition then
		return nil
	end
	local copy = table.clone(definition)
	copy.Id = petSkinId
	return copy
end

function PetSkinCatalog.Get(petSkinId)
	return copyDefinition(petSkinId, DEFINITIONS[petSkinId])
end

function PetSkinCatalog.All()
	local definitions = {}
	for _, petSkinId in ipairs(ORDER) do
		definitions[#definitions + 1] = copyDefinition(petSkinId, DEFINITIONS[petSkinId])
	end
	return definitions
end

function PetSkinCatalog.TemplateFor(petSkinId)
	if not DEFINITIONS[petSkinId] then
		return nil
	end
	local root = Assets.Find(Assets.Names.PetSkins)
	if not root then
		return nil
	end
	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(State.PetSkin.Id) == petSkinId then
			return child
		end
	end
	return nil
end

function PetSkinCatalog.NameFor(petSkinId)
	local template = PetSkinCatalog.TemplateFor(petSkinId)
	return template and template.Name or petSkinId
end

function PetSkinCatalog.RarityFor(petSkinId)
	local definition = DEFINITIONS[petSkinId]
	return definition and definition.Rarity or nil
end

function PetSkinCatalog.TotalWeight()
	local total = 0
	for _, definition in pairs(DEFINITIONS) do
		total += definition.Weight
	end
	return total
end

function PetSkinCatalog.ChanceText(petSkinId)
	local definition = DEFINITIONS[petSkinId]
	local total = PetSkinCatalog.TotalWeight()
	if not definition or total <= 0 then
		return "0%"
	end
	return string.format("%d%%", math.floor((definition.Weight / total) * 100 + 0.5))
end

function PetSkinCatalog.Roll(random)
	local total = PetSkinCatalog.TotalWeight()
	if total <= 0 then
		return nil
	end
	local roll = (random or Random.new()):NextNumber(0, total)
	local cumulative = 0
	for _, petSkinId in ipairs(ORDER) do
		cumulative += DEFINITIONS[petSkinId].Weight
		if roll <= cumulative then
			return copyDefinition(petSkinId, DEFINITIONS[petSkinId])
		end
	end
	local petSkinId = ORDER[#ORDER]
	return copyDefinition(petSkinId, DEFINITIONS[petSkinId])
end

function PetSkinCatalog.Validate(errors)
	errors = errors or {}
	local seenTemplates = {}
	for _, definition in ipairs(PetSkinCatalog.All()) do
		local source = "PetSkinCatalog." .. definition.Id
		local template = PetSkinCatalog.TemplateFor(definition.Id)
		if not template then
			errors[#errors + 1] = source .. " has no Studio template"
			continue
		end
		seenTemplates[template] = true
		if template:GetAttribute(State.PetSkin.Rarity) ~= definition.Rarity then
			errors[#errors + 1] = source .. " template rarity does not match the catalog"
		end
		if template.Name:gsub("%s+", "") ~= definition.Id then
			errors[#errors + 1] = source .. " template name must be the user-facing form of its PetSkinID"
		end
		if not template.PrimaryPart then
			errors[#errors + 1] = template:GetFullName() .. " missing PrimaryPart"
		end
		if not template:FindFirstChildWhichIsA("Animator", true) then
			errors[#errors + 1] = template:GetFullName() .. " missing Animator"
		end
		for _, key in ipairs({ "IdleAnimationId", "WalkAnimationId" }) do
			if type(definition[key]) ~= "string" or not definition[key]:match("^rbxassetid://%d+$") then
				errors[#errors + 1] = source .. " has invalid " .. key
			end
		end
		if definition.SoundId ~= nil
			and (type(definition.SoundId) ~= "string" or not definition.SoundId:match("^rbxassetid://%d+$")) then
			errors[#errors + 1] = source .. " has invalid SoundId"
		end
		if definition.SoundPetId ~= nil and (type(definition.SoundPetId) ~= "string" or definition.SoundPetId == "") then
			errors[#errors + 1] = source .. " has invalid SoundPetId"
		end
		if type(definition.SoundPetId) == "string" then
			local sounds = ReplicatedStorage:FindFirstChild("Sounds")
			local animalSounds = sounds and sounds:FindFirstChild("AnimalAmbientSounds")
			local referencedSound = animalSounds and animalSounds:FindFirstChild(definition.SoundPetId)
			if not (referencedSound and referencedSound:IsA("Sound")) then
				errors[#errors + 1] = source .. " references missing animal sound " .. definition.SoundPetId
			end
		end
		if definition.SoundId ~= nil and definition.SoundPetId ~= nil then
			errors[#errors + 1] = source .. " must use SoundId or SoundPetId, not both"
		end
		if type(definition.ViewportScaleMultiplier) ~= "number" or definition.ViewportScaleMultiplier <= 0 then
			errors[#errors + 1] = source .. " has invalid ViewportScaleMultiplier"
		end
	end

	local root = Assets.Find(Assets.Names.PetSkins)
	for _, template in ipairs(root and root:GetChildren() or {}) do
		if template:IsA("Model") and not seenTemplates[template] then
			errors[#errors + 1] = template:GetFullName() .. " is not configured in PetSkinCatalog"
		end
	end
	return errors
end

return PetSkinCatalog
