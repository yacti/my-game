local Workspace = game:GetService("Workspace")

local Onboarding = {}

Onboarding.AttributeName = "Onboarding"

Onboarding.Stages = {
	RollAppleTreeSeed = "RollAppleTreeSeed",
	BuyAppleTreeSeed = "BuyAppleTreeSeed",
	PlantAppleTreeSeed = "PlantAppleTreeSeed",
	ShakeAppleTree = "ShakeAppleTree",
	CollectApple = "CollectApple",
	FeedPetApple = "FeedPetApple",
	RollPumpkinSeed = "RollPumpkinSeed",
	BuyPumpkinSeed = "BuyPumpkinSeed",
	PlantPumpkinSeed = "PlantPumpkinSeed",
	HarvestPumpkin = "HarvestPumpkin",
	FeedPetPumpkin = "FeedPetPumpkin",
	ExpandFarm = "ExpandFarm",
	FinalNote = "FinalNote",
	Complete = "Complete",
}

Onboarding.ProgressKeys = {
	CurrencySupplementsGranted = "CurrencySupplementsGranted",
	TreeClickCount = "TreeClickCount",
	TreeDroppedSlots = "TreeDroppedSlots",
	TreeFruitTarget = "TreeFruitTarget",
	TreeFruitCollected = "TreeFruitCollected",
}

Onboarding.Seeds = {
	Pumpkin = "PumpkinSeed",
	AppleTree = "AppleTreeSeed",
}

Onboarding.FeedTypes = {
	Pumpkin = "PumpkinPatch",
	AppleTree = "AppleTree",
}

Onboarding.FoodIds = {
	Pumpkin = "Pumpkin",
	Apple = "Apple",
}

Onboarding.TreeClicksRequired = 8
Onboarding.ExpandFarmGrid = {
	X = 2,
	Z = 1,
}
Onboarding.FinalNoteDisplaySeconds = 8
Onboarding.FinalNoteFadeSeconds = 0.45
Onboarding.CurrencySupplements = {
	[Onboarding.Stages.BuyPumpkinSeed] = 100,
	[Onboarding.Stages.ExpandFarm] = 25,
}

local HIDDEN_DURING_ACTIVE_TUTORIAL = {
	Hud = {
		"RollButtons",
		"SkipTimeButtons",
		"RebirthButton",
		"EventButton",
		"TopBar",
	},
	LocalPromptKinds = {
		"GridPartUnlock",
	},
}

local ORDERED_STAGES = {
	Onboarding.Stages.RollAppleTreeSeed,
	Onboarding.Stages.BuyAppleTreeSeed,
	Onboarding.Stages.PlantAppleTreeSeed,
	Onboarding.Stages.ShakeAppleTree,
	Onboarding.Stages.CollectApple,
	Onboarding.Stages.FeedPetApple,
	Onboarding.Stages.RollPumpkinSeed,
	Onboarding.Stages.BuyPumpkinSeed,
	Onboarding.Stages.PlantPumpkinSeed,
	Onboarding.Stages.HarvestPumpkin,
	Onboarding.Stages.FeedPetPumpkin,
	Onboarding.Stages.ExpandFarm,
	Onboarding.Stages.FinalNote,
	Onboarding.Stages.Complete,
}

local STAGE_TEXT = {
	[Onboarding.Stages.RollAppleTreeSeed] = "Press the button!",
	[Onboarding.Stages.BuyAppleTreeSeed] = "Buy the seed!",
	[Onboarding.Stages.PlantAppleTreeSeed] = "Plant the Apple Tree!",
	[Onboarding.Stages.ShakeAppleTree] = "Shake tree!",
	[Onboarding.Stages.CollectApple] = "Collect all the fruit!",
	[Onboarding.Stages.FeedPetApple] = "Feed your pet!",
	[Onboarding.Stages.RollPumpkinSeed] = "Press the button",
	[Onboarding.Stages.BuyPumpkinSeed] = "Buy the seed!",
	[Onboarding.Stages.PlantPumpkinSeed] = "Plant the Pumpkin Seed!",
	[Onboarding.Stages.HarvestPumpkin] = "Harvest your Pumpkin!",
	[Onboarding.Stages.FeedPetPumpkin] = "Feed your pet",
	[Onboarding.Stages.ExpandFarm] = "Expand your farm",
	[Onboarding.Stages.FinalNote] = "Roll for rare seeds, feed your pets and Build a Pet Farm",
	[Onboarding.Stages.Complete] = "",
}

local STAGE_RICH_TEXT = {
	[Onboarding.Stages.FinalNote] = 'Roll for rare seeds, feed your pets and <font color="#FFD84D">Build a Pet Farm</font>',
}

local NEXT_STAGE = {}
local VALID_STAGES = {}
for index, stage in ipairs(ORDERED_STAGES) do
	VALID_STAGES[stage] = true
	NEXT_STAGE[stage] = ORDERED_STAGES[index + 1]
end

function Onboarding.FirstStage()
	return ORDERED_STAGES[1]
end

function Onboarding.OrderedStages()
	return table.clone(ORDERED_STAGES)
end

function Onboarding.IsStage(stage)
	return VALID_STAGES[stage] == true
end

function Onboarding.IsComplete(stage)
	return stage == Onboarding.Stages.Complete
end

function Onboarding.IsActive(stage)
	return Onboarding.IsStage(stage) and not Onboarding.IsComplete(stage)
end

function Onboarding.NextStage(stage)
	return NEXT_STAGE[stage]
end

function Onboarding.TextFor(stage)
	return STAGE_TEXT[stage] or ""
end

function Onboarding.RichTextFor(stage)
	return STAGE_RICH_TEXT[stage] or Onboarding.TextFor(stage)
end

function Onboarding.UsesRichText(stage)
	return STAGE_RICH_TEXT[stage] ~= nil
end

function Onboarding.CurrencySupplementFor(stage)
	return Onboarding.CurrencySupplements[stage] or 0
end

function Onboarding.HiddenDuringActiveTutorial()
	return {
		Hud = table.clone(HIDDEN_DURING_ACTIVE_TUTORIAL.Hud),
		LocalPromptKinds = table.clone(HIDDEN_DURING_ACTIVE_TUTORIAL.LocalPromptKinds),
	}
end

local function listContains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

function Onboarding.ShouldHideHudDuringActiveTutorial(name)
	return listContains(HIDDEN_DURING_ACTIVE_TUTORIAL.Hud, name)
end

function Onboarding.ShouldHidePromptKindDuringActiveTutorial(kind)
	return listContains(HIDDEN_DURING_ACTIVE_TUTORIAL.LocalPromptKinds, kind)
end

function Onboarding.IsExpandFarmGridCoordinate(x, z)
	x = tonumber(x)
	z = tonumber(z)
	if type(x) ~= "number" or x ~= x or math.abs(x) == math.huge then
		return false
	end
	if type(z) ~= "number" or z ~= z or math.abs(z) == math.huge then
		return false
	end
	return math.floor(x) == Onboarding.ExpandFarmGrid.X
		and math.floor(z) == Onboarding.ExpandFarmGrid.Z
end

function Onboarding.IsEnabled()
	local value = Workspace:GetAttribute(Onboarding.AttributeName)
	if typeof(value) == "boolean" then
		return value
	end
	return true
end

function Onboarding.DefaultState()
	if not Onboarding.IsEnabled() then
		return Onboarding.CompleteState()
	end
	return {
		Stage = Onboarding.FirstStage(),
		Progress = {},
	}
end

function Onboarding.CompleteState()
	return {
		Stage = Onboarding.Stages.Complete,
		Progress = {},
	}
end

local function sanitizeCount(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function sanitizeSlotMap(value)
	local clean = {}
	if type(value) ~= "table" then
		return clean
	end
	for rawSlot, dropped in pairs(value) do
		local slotIndex = tonumber(rawSlot)
		if type(slotIndex) == "number"
			and slotIndex == slotIndex
			and slotIndex >= 1
			and dropped == true then
			clean[tostring(math.floor(slotIndex))] = true
		end
	end
	return clean
end

local function countSlotMap(value)
	local count = 0
	if type(value) ~= "table" then
		return count
	end
	for _, dropped in pairs(value) do
		if dropped == true then
			count += 1
		end
	end
	return count
end

local function sanitizeCurrencySupplementMap(value)
	local clean = {}
	if type(value) ~= "table" then
		return clean
	end
	for stage, granted in pairs(value) do
		if granted == true and Onboarding.CurrencySupplementFor(stage) > 0 then
			clean[stage] = true
		end
	end
	return clean
end

function Onboarding.SanitizeProgress(progress)
	local clean = {}
	if type(progress) ~= "table" then
		progress = {}
	end

	clean[Onboarding.ProgressKeys.CurrencySupplementsGranted] =
		sanitizeCurrencySupplementMap(progress[Onboarding.ProgressKeys.CurrencySupplementsGranted])
	clean[Onboarding.ProgressKeys.TreeDroppedSlots] = sanitizeSlotMap(progress[Onboarding.ProgressKeys.TreeDroppedSlots])
	clean[Onboarding.ProgressKeys.TreeClickCount] = math.min(
		math.max(
			sanitizeCount(progress[Onboarding.ProgressKeys.TreeClickCount]),
			countSlotMap(clean[Onboarding.ProgressKeys.TreeDroppedSlots])
		),
		Onboarding.TreeClicksRequired
	)
	clean[Onboarding.ProgressKeys.TreeFruitTarget] = sanitizeCount(progress[Onboarding.ProgressKeys.TreeFruitTarget])
	clean[Onboarding.ProgressKeys.TreeFruitCollected] = sanitizeCount(progress[Onboarding.ProgressKeys.TreeFruitCollected])
	return clean
end

-- Stage ids stored in saved profiles before a rename/removal; without these
-- aliases, SanitizeState would treat old ids as invalid and skip to Complete.
local LEGACY_STAGE_ALIASES = {
	MakeCurrency500 = Onboarding.Stages.RollPumpkinSeed,
	MakeCurrency = Onboarding.Stages.RollPumpkinSeed,
	GatherPumpkinXP = Onboarding.Stages.HarvestPumpkin,
}

function Onboarding.SanitizeState(value, fallback)
	local state = type(value) == "table" and value or fallback
	if type(state) ~= "table" then
		state = Onboarding.CompleteState()
	end

	local stage = state.Stage
	if type(stage) == "string" and LEGACY_STAGE_ALIASES[stage] ~= nil then
		stage = LEGACY_STAGE_ALIASES[stage]
	end
	if type(stage) ~= "string" or not Onboarding.IsStage(stage) then
		stage = fallback and fallback.Stage or Onboarding.Stages.Complete
	end
	if type(stage) ~= "string" or not Onboarding.IsStage(stage) then
		stage = Onboarding.Stages.Complete
	end

	local progress = Onboarding.SanitizeProgress(state.Progress)
	if stage ~= Onboarding.Stages.ShakeAppleTree and stage ~= Onboarding.Stages.CollectApple then
		progress[Onboarding.ProgressKeys.TreeClickCount] = 0
		progress[Onboarding.ProgressKeys.TreeDroppedSlots] = {}
		progress[Onboarding.ProgressKeys.TreeFruitTarget] = 0
		progress[Onboarding.ProgressKeys.TreeFruitCollected] = 0
	end

	return {
		Stage = stage,
		Progress = progress,
	}
end

return Onboarding
