local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Server = script.Parent
local FeedMachines = require(Server:WaitForChild("feedMachines"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared:WaitForChild("Balance"))
local Food = require(Shared:WaitForChild("Food"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local State = require(Shared:WaitForChild("State"))

local AssetValidator = {}

local REQUIRED_ROOTS = {
	"Pets",
	"FeedMachines",
	"Food",
	"UI",
	"FeedMachineTool",
	"EditTool",
	"Remotes",
}

local REQUIRED_FEEDS = {
	"Clicker1",
	"Processor1",
	"AppleTree",
	"CherryTree",
	"PumpkinPatch",
}

local REQUIRED_UI = {
	"HUD",
	"PetMoneyBillboard",
	"PetXPBillboard",
}

local REQUIRED_TOOLS = {
	"FeedMachineTool",
	"EditTool",
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

local function validateTool(tool, errors)
	if not tool then return end
	child(tool, "Handle", "BasePart", errors)
end

local function validatePetTemplates(errors)
	local pets = child(ReplicatedStorage, "Pets", "Folder", errors)
	if not pets then return end

	for level = 1, Balance.MAX_PET_LEVEL do
		local petName = "Pet" .. level
		local pet = child(pets, petName, "Model", errors)
		if pet then
			if not pet.PrimaryPart then
				add(errors, pet:GetFullName() .. " missing PrimaryPart")
			end
			if pet:GetAttribute(State.Pet.MoneyRate) == nil then
				add(errors, pet:GetFullName() .. " missing " .. State.Pet.MoneyRate .. " attribute")
			end
			for _, descendant in ipairs(pet:GetDescendants()) do
				if descendant:IsA("ProximityPrompt") then
					add(errors, pet:GetFullName() .. " contains baked ProximityPrompt " .. descendant:GetFullName())
				end
			end
		end
	end
end

local function validateFeedTemplates(errors)
	local root = child(ReplicatedStorage, "FeedMachines", "Folder", errors)
	if not root then return end

	for _, feedType in ipairs(REQUIRED_FEEDS) do
		local template = FeedMachines.GetTemplate(feedType)
		if not template then
			add(errors, "Missing feed machine template " .. feedType)
		elseif template:IsA("Model") and not template.PrimaryPart then
			add(errors, template:GetFullName() .. " missing PrimaryPart")
		end
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

local function collectBalanceChainFoodIds(requiredFoodIds, sourcesByFoodId, errors)
	local feedMachinesFolder = Server:FindFirstChild("feedMachines")
	if not feedMachinesFolder then return end

	for _, module in ipairs(feedMachinesFolder:GetDescendants()) do
		if module:IsA("ModuleScript") and module.Name:match("Balance$") then
			local ok, balance = pcall(require, module)
			if not ok then
				add(errors, string.format("Failed to load balance module %s: %s", module:GetFullName(), tostring(balance)))
				continue
			end

			if type(balance) == "table" and balance.Chain ~= nil then
				local feedType = type(balance.FeedType) == "string" and balance.FeedType or module.Name
				if type(balance.Chain) ~= "table" or #balance.Chain == 0 then
					add(errors, string.format("%s has empty or invalid Chain", module:GetFullName()))
					continue
				end

				for index, foodId in ipairs(balance.Chain) do
					addRequiredFoodId(
						requiredFoodIds,
						sourcesByFoodId,
						foodId,
						string.format("%s Chain[%d]", feedType, index),
						errors
					)
				end
			end
		end
	end
end

local function collectClickerFoodIds(requiredFoodIds, sourcesByFoodId, errors)
	for _, feedType in ipairs(FeedMachines.AllFeedTypes()) do
		if FeedMachines.GetClass(feedType) == "Clicker" then
			local template = FeedMachines.GetTemplate(feedType)
			if not template then continue end

			local foodId = template:GetAttribute(State.Feed.FoodType)
			if type(foodId) ~= "string" or foodId == "" then
				foodId = "Apple"
			end
			addRequiredFoodId(
				requiredFoodIds,
				sourcesByFoodId,
				foodId,
				string.format("%s clicker output", feedType),
				errors
			)
		end
	end
end

local function collectRequiredFoodIds(errors)
	local requiredFoodIds = {}
	local sourcesByFoodId = {}

	collectBalanceChainFoodIds(requiredFoodIds, sourcesByFoodId, errors)
	collectClickerFoodIds(requiredFoodIds, sourcesByFoodId, errors)

	table.sort(requiredFoodIds)
	return requiredFoodIds, sourcesByFoodId
end

local function sourceList(sources)
	return sources and table.concat(sources, ", ") or "unknown source"
end

local function validateFoodTemplates(errors)
	child(ReplicatedStorage, "Food", "Folder", errors)

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
end

local function validateUi(errors)
	local ui = child(ReplicatedStorage, "UI", "Folder", errors)
	if not ui then return end
	for _, name in ipairs(REQUIRED_UI) do
		child(ui, name, nil, errors)
	end

	local hud = child(ui, "HUD", "ScreenGui", errors)
	if hud then
		local notifications = child(hud, "Notifications", "GuiObject", errors)
		if notifications then
			child(notifications, "NotificationTemplate", "TextLabel", errors)
			child(notifications, "UIListLayout", "UIListLayout", errors)
		end
	end
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

	local function validatePlot(plot)
		foundPlot = true
		child(plot, "Floor", "BasePart", errors)
		child(plot, "SpawnLocation", "SpawnLocation", errors)
	end

	if plotsFolder then
		for _, plot in ipairs(plotsFolder:GetChildren()) do
			validatePlot(plot)
		end
	else
		for _, instance in ipairs(Workspace:GetChildren()) do
			if instance.Name:match("^Plot%d") then
				validatePlot(instance)
			end
		end
	end

	if not foundPlot then
		add(errors, "No plots found in Workspace.Plots or Workspace.Plot#")
	end
end

function AssetValidator.validate()
	local errors = {}

	for _, name in ipairs(REQUIRED_ROOTS) do
		child(ReplicatedStorage, name, nil, errors)
	end
	for _, toolName in ipairs(REQUIRED_TOOLS) do
		validateTool(ReplicatedStorage:FindFirstChild(toolName), errors)
	end

	validateRemotes(errors)
	validatePetTemplates(errors)
	validateFeedTemplates(errors)
	validateFoodTemplates(errors)
	validateUi(errors)
	validatePlots(errors)

	if #errors > 0 then
		error("[AssetValidator] Startup asset validation failed:\n- " .. table.concat(errors, "\n- "))
	end
end

return AssetValidator
