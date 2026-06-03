local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
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
local State = require(Shared:WaitForChild("State"))

local AssetValidator = {}

local REQUIRED_ROOTS = {
	"PetModels",
	"FeedMachines",
	"Food",
	"Crates",
	"Seeds",
	"FeedMachineTool",
	"SeedTool",
	"Shovel",
	"Misc",
	"VFX",
	"Remotes",
}

-- Stable FeedType values that must exist somewhere under FeedMachines.
-- Template/model names are visual only and are intentionally not validated here.
local REQUIRED_FEEDS = {
	"Processor1",
	"AppleTree",
	"CherryTree",
	"PumpkinPatch",
}

local REQUIRED_TOOLS = {
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

local DEPRECATED_FEED_ATTRIBUTES = {
	XPMultiplier = State.Feed.XP,
}

local SEED_OWNED_FEED_ATTRIBUTES = {
	Seeds.Attributes.RollChanceN,
	Seeds.Attributes.Price,
	Seeds.Attributes.Rarity,
	Seeds.Attributes.GrowTime,
}

local EDIT_SELECTION_HITBOX_NAME = "EditSelectionHitbox"
local TEMPLATE_SIZE_TOLERANCE = 0.01

local DEPRECATED_FOOD_ATTRIBUTES = {
	MaxXP = State.Food.XP,
}

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

local function nearlyEqual(a, b, tolerance)
	return math.abs(a - b) <= tolerance
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
	local petModels = child(ReplicatedStorage, "PetModels", "Folder", errors)
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

local function validateFeedTemplateIdentity(root, errors)
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

			for attributeName, replacement in pairs(DEPRECATED_FEED_ATTRIBUTES) do
				if template:GetAttribute(attributeName) ~= nil then
					add(errors, string.format(
						"%s has deprecated feed attribute %s; use %s",
						template:GetFullName(),
						attributeName,
						replacement
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
			if feedClass == "Patch" then
				validatePatchEditSelectionHitbox(template, errors)
			end

			local growRate = template:GetAttribute(State.Feed.GrowRate)
			if growRate ~= nil and (type(growRate) ~= "number" or growRate <= 0) then
				add(errors, string.format("%s has invalid %s %q", template:GetFullName(), State.Feed.GrowRate, tostring(growRate)))
			end
		end
	end
end

local function validateFeedTemplates(errors)
	local root = child(ReplicatedStorage, "FeedMachines", "Folder", errors)
	if not root then return end

	validateFeedTemplateIdentity(root, errors)

	for _, feedType in ipairs(REQUIRED_FEEDS) do
		local template = FeedMachines.GetTemplate(feedType)
		if not template then
			add(errors, "Missing feed machine template " .. feedType)
		elseif template:IsA("Model") and not template.PrimaryPart then
			add(errors, template:GetFullName() .. " missing PrimaryPart")
		end
	end
end

local function validateSeeds(errors)
	local root = child(ReplicatedStorage, "Seeds", "Folder", errors)
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
		if not RollChances.BaseWeightForChance(rollChanceN) then
			add(errors, string.format("%s has invalid %s %q", template:GetFullName(), Seeds.Attributes.RollChanceN, tostring(rollChanceN)))
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
		add(errors, "ReplicatedStorage.Seeds must contain at least one seed template")
	end
end

local function validateMisc(errors)
	local misc = child(ReplicatedStorage, "Misc", "Folder", errors)
	if not misc then return end

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
		if not RollChances.BaseWeightForChance(rollChanceN) then
			add(errors, string.format("%s has invalid %s %q", template:GetFullName(), RollRewards.Attributes.RollChanceN, tostring(rollChanceN)))
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

	local sapling = child(misc, "Sapling", "Model", errors)
	if sapling then
		if not hasBasePart(sapling) then
			add(errors, sapling:GetFullName() .. " has no BasePart descendants")
		end
	end

	local brick = child(misc, "Brick", nil, errors)
	if brick then
		validateMiscRollTemplate(brick, "Brick")
	end

	local seenByMiscId = {}
	for _, template in ipairs(misc:GetDescendants()) do
		if not RollRewards.IsTemplate(template) or RollRewards.HasTemplateAncestor(misc, template) then
			continue
		end
		if template == brick then
			local miscId = template:GetAttribute(RollRewards.Attributes.MiscId)
			if type(miscId) == "string" and miscId ~= "" then
				seenByMiscId[miscId] = template
			end
			continue
		end
		local miscId = template:GetAttribute(RollRewards.Attributes.MiscId)
		if miscId == nil then
			continue
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
end

local function validateVfx(errors)
	local vfx = child(ReplicatedStorage, "VFX", "Folder", errors)
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
	local crates = child(ReplicatedStorage, "Crates", "Folder", errors)
	if not crates then return end

	RollChances.Validate(errors)
	for _, crateId in ipairs(RollChances.CrateIds()) do
		local config = RollChances.GetCrate(crateId)
		local template = child(crates, config.TemplateName, nil, errors)
		validateCrateTemplate(template, errors)
	end
end

local function validateRebirthUi(errors)
	local ui = child(ReplicatedStorage, "UI", "Folder", errors)
	if not ui then return end

	local rebirthGui = child(ui, "Rebirth", "ScreenGui", errors)
	if not rebirthGui then return end

	descendant(rebirthGui, "Panel", "GuiObject", errors)
	descendant(rebirthGui, "CloseButton", "GuiButton", errors)
	descendant(rebirthGui, "RebirthButton", "GuiButton", errors)
	descendant(rebirthGui, "SkipButton", "GuiButton", errors)
	descendant(rebirthGui, "TierLabel", "TextLabel", errors)
	descendant(rebirthGui, "PriceLabel", "TextLabel", errors)
	descendant(rebirthGui, "CashLabel", "TextLabel", errors)
	local progressBar = descendant(rebirthGui, "ProgressBar", "GuiObject", errors)
	if progressBar then
		descendant(progressBar, "Fill", "GuiObject", errors)
	end
	local rewardList = descendant(rebirthGui, "RewardList", "GuiObject", errors)
	if rewardList then
		descendant(rewardList, "RewardTemplate", "GuiObject", errors)
	end
end

local function validateBillboardTemplate(ui, name, labelName, errors)
	local billboard = child(ui, name, "BillboardGui", errors)
	if billboard and labelName then
		descendant(billboard, labelName, "TextLabel", errors)
	end
	return billboard
end

local function validatePromptTemplates(ui, errors)
	local generic = ui:FindFirstChild("LocalPrompt")
	if generic then
		if not generic:IsA("ProximityPrompt") then
			add(errors, string.format("%s is %s, expected ProximityPrompt", generic:GetFullName(), generic.ClassName))
		end
	else
		local templates = child(ui, "PromptTemplates", "Folder", errors)
		if not templates then return end

		for _, kind in ipairs(PROMPT_TEMPLATE_KINDS) do
			child(templates, kind, "ProximityPrompt", errors)
		end
	end
end

local function validateHudCurrency(hud, errors)
	local currency = hud:FindFirstChild("Currency")
	local amount = currency and currency:FindFirstChild("Amount")
	if amount and amount:IsA("TextLabel") then return end
	if descendant(hud, "CurrencyLabel", "TextLabel", {}) then return end
	add(errors, string.format("Missing %s.Currency.Amount or descendant CurrencyLabel TextLabel", hud:GetFullName()))
end

local function validateRollLuckHud(hud, errors)
	local frame = child(hud, "RollLuckFrame", "GuiObject", errors)
	if not frame then return end

	descendant(frame, "LuckLabel", "TextLabel", errors)
	descendant(frame, "UpgradeButton", "GuiButton", errors)
	descendant(frame, "ErrorLabel", "TextLabel", errors)
end

local function validateRollDropAreaHud(hud, errors)
	local frame = child(hud, "RollDropAreaFrame", "GuiObject", errors)
	if not frame then return end

	descendant(frame, "DropAreaLabel", "TextLabel", errors)
	descendant(frame, "UpgradeButton", "GuiButton", errors)
	descendant(frame, "ErrorLabel", "TextLabel", errors)
end

local function validateRollBillboards(ui, errors)
	local folder = child(ui, "RollBillboardGUI", "Folder", errors)
	if not folder then return end

	local seed = child(folder, "Seed", "BillboardGui", errors)
	if seed then
		descendant(seed, "NameLabel", "TextLabel", errors)
		descendant(seed, "PriceLabel", "TextLabel", errors)
		descendant(seed, "ChanceLabel", "TextLabel", errors)
		descendant(seed, "RarityLabel", "TextLabel", errors)
	end

	local misc = child(folder, "Misc", "BillboardGui", errors)
	if misc then
		descendant(misc, "NameLabel", "TextLabel", errors)
		descendant(misc, "PriceLabel", "TextLabel", errors)
	end
end

local function validateFeedEditUi(ui, hud, errors)
	if hud then
		descendant(hud, "EditModeButton", "GuiButton", errors)
	end

	local placementEdit = child(ui, "PlacementEdit", "BillboardGui", errors)
	if not placementEdit then return end

	local options = child(placementEdit, "options", "GuiObject", errors)
	if options then
		child(options, "confirm", "GuiButton", errors)
		child(options, "move", "GuiButton", errors)
		child(options, "rotate", "GuiButton", errors)
	end
	child(placementEdit, "tip", "TextLabel", errors)
end

local function validateYesNoWarningUi(ui, errors)
	local warning = child(ui, "YesNoWarning", "GuiObject", errors)
	if not warning then return end

	descendant(warning, "Description", "TextLabel", errors)
	descendant(warning, "Item", "TextLabel", errors)
	descendant(warning, "Yes", "GuiButton", errors)
	descendant(warning, "No", "GuiButton", errors)
	descendant(warning, "CloseButton", "GuiButton", errors)
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
			if type(reward) ~= "table" or reward.kind ~= "FeedMachine" then
				add(errors, string.format("%s.Rewards[%d] has unsupported kind", source, index))
				continue
			end
			local amount = reward.amount
			if type(amount) ~= "number" or amount < 1 or amount % 1 ~= 0 then
				add(errors, string.format("%s.Rewards[%d] has invalid amount", source, index))
			end
			if type(reward.feedType) ~= "string" or not FeedMachines.GetTemplate(reward.feedType) then
				add(errors, string.format("%s.Rewards[%d] has unknown feedType %q", source, index, tostring(reward.feedType)))
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
	local foodRoot = child(ReplicatedStorage, "Food", "Folder", errors)

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
		end
	end
end

local function validateUi(errors)
	local ui = child(ReplicatedStorage, "UI", "Folder", errors)
	if not ui then return end

	local hud = child(ui, "HUD", "ScreenGui", errors)
	if hud then
		validateHudCurrency(hud, errors)
		validateRollLuckHud(hud, errors)
		validateRollDropAreaHud(hud, errors)
		descendant(hud, "RebirthOpenButton", "GuiButton", errors)
		local notifications = child(hud, "Notifications", "GuiObject", errors)
		if notifications then
			child(notifications, "NotificationTemplate", "TextLabel", errors)
			child(notifications, "UIListLayout", "UIListLayout", errors)
		end
	end

	validateBillboardTemplate(ui, "PetMoneyBillboard", "MoneyLabel", errors)
	local petXP = validateBillboardTemplate(ui, "PetXPBillboard", nil, errors)
	if petXP then
		local background = child(petXP, "Background", "GuiObject", errors)
		if background then
			child(background, "Fill", "GuiObject", errors)
		end
	end
	validateBillboardTemplate(ui, "ToolStatsBillboard", "StatsLabel", errors)
	validateBillboardTemplate(ui, "SlotXPBillboard", "XPLabel", errors)
	validateBillboardTemplate(ui, "TreeGroundXPBillboard", "XPLabel", errors)
	local growingSeed = validateBillboardTemplate(ui, "GrowingSeedBillboard", "TitleLabel", errors)
	if growingSeed then
		descendant(growingSeed, "TimeLabel", "TextLabel", errors)
	end
	validateRollBillboards(ui, errors)

	validateFeedEditUi(ui, hud, errors)
	validateYesNoWarningUi(ui, errors)

	validatePromptTemplates(ui, errors)
end

local function validateRemotes(errors)
	local ok, err = pcall(function()
		Remotes.validateAll()
	end)
	if not ok then add(errors, tostring(err)) end
end

local function validatePlots(errors)
	local plotsFolder = Workspace:FindFirstChild("Plots")
	local foundPlot = false
	local rootPlots = {}

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

	local function validatePlot(plot)
		foundPlot = true
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

	local function validatePlotList(plots, sourceName)
		local seenNames = {}
		for _, plot in ipairs(plots) do
			if not plot:IsA("Model") then
				add(errors, string.format("%s is %s, expected Model plot", plot:GetFullName(), plot.ClassName))
				continue
			end
			if not plot.Name:match("^Plot%d+$") then
				add(errors, string.format("%s has invalid plot name; expected Plot<number>", plot:GetFullName()))
			end
			local previous = seenNames[plot.Name]
			if previous then
				add(errors, string.format("Duplicate plot name %s in %s: %s and %s", plot.Name, sourceName, previous:GetFullName(), plot:GetFullName()))
			else
				seenNames[plot.Name] = plot
			end
			validatePlot(plot)
		end
	end

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

function AssetValidator.validate()
	local errors = {}
	local warnings = {}

	for _, name in ipairs(REQUIRED_ROOTS) do
		child(ReplicatedStorage, name, nil, errors)
	end
	for _, toolName in ipairs(REQUIRED_TOOLS) do
		validateTool(ReplicatedStorage:FindFirstChild(toolName), errors)
	end

	validateRemotes(errors)
	validatePetCatalog(errors)
	validateFeedTemplates(errors)
	validateSeeds(errors)
	validateMisc(errors)
	validateVfx(errors)
	validateCrates(errors)
	validateRebirthBalance(errors)
	validateRollLuckBalance(errors)
	validateRollDropAreaBalance(errors)
	validateFoodTemplates(errors)
	validateUi(warnings)
	validateRebirthUi(warnings)
	validatePlots(errors)

	if #warnings > 0 then
		warn("[AssetValidator] Studio UI asset warnings:\n- " .. table.concat(warnings, "\n- "))
	end
	if #errors > 0 then
		error("[AssetValidator] Startup asset validation failed:\n- " .. table.concat(errors, "\n- "))
	end
end

return AssetValidator
