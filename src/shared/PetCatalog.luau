local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(script.Parent:WaitForChild("Assets"))
local State = require(script.Parent:WaitForChild("State"))

local PetCatalog = {}

PetCatalog.MotionStates = {
	Idle = "Idle",
	Walk = "Walk",
}

local DEFAULT_IDLE_ANIMATION_ID = "rbxassetid://122268596727742"
local DEFAULT_WALK_ANIMATION_ID = "rbxassetid://96926700690285"

local function petModelsFolder()
	return Assets.Find(Assets.Names.PetModels)
end

local function numericAttribute(model, attributeName, defaultValue)
	local value = model:GetAttribute(attributeName)
	return type(value) == "number" and value or defaultValue
end

local function stringAttribute(model, attributeName, defaultValue)
	local value = model:GetAttribute(attributeName)
	return type(value) == "string" and value ~= "" and value or defaultValue
end

local function petModelDefinition(model)
	local petId = stringAttribute(model, State.Pet.Id, nil)
	if not petId then return nil end

	return {
		Id = petId,
		Order = numericAttribute(model, State.Pet.Order, nil),
		MaxXP = numericAttribute(model, State.Pet.MaxXP, nil),
		WalkSpeed = numericAttribute(model, State.Pet.WalkSpeed, 7),
		Visual = {
			ModelName = model.Name,
			IdleAnimationId = stringAttribute(model, "IdleAnimationId", DEFAULT_IDLE_ANIMATION_ID),
			WalkAnimationId = stringAttribute(model, "WalkAnimationId", DEFAULT_WALK_ANIMATION_ID),
			MinWalkSeconds = numericAttribute(model, "MinWalkSeconds", 2),
			MaxWalkSeconds = numericAttribute(model, "MaxWalkSeconds", 5),
			MinIdleSeconds = numericAttribute(model, "MinIdleSeconds", 2),
			MaxIdleSeconds = numericAttribute(model, "MaxIdleSeconds", 5),
		},
	}
end

local function allDefinitions()
	local definitions = {}
	local folder = petModelsFolder()
	if not folder then return definitions end

	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			local definition = petModelDefinition(model)
			if definition then
				definitions[#definitions + 1] = definition
			end
		end
	end

	table.sort(definitions, function(a, b)
		local ao = type(a.Order) == "number" and a.Order or math.huge
		local bo = type(b.Order) == "number" and b.Order or math.huge
		if ao == bo then
			return a.Id < b.Id
		end
		return ao < bo
	end)

	return definitions
end

function PetCatalog.GetDefinition(petId)
	for _, definition in ipairs(allDefinitions()) do
		if definition.Id == petId then
			return definition
		end
	end
	return nil
end

function PetCatalog.AllPetIds()
	local petIds = {}
	for _, definition in ipairs(allDefinitions()) do
		petIds[#petIds + 1] = definition.Id
	end
	return petIds
end

function PetCatalog.VisualForPetId(petId)
	local definition = PetCatalog.GetDefinition(petId)
	return definition and definition.Visual or nil
end

function PetCatalog.WalkSpeedForPetId(petId)
	local definition = PetCatalog.GetDefinition(petId)
	local walkSpeed = definition and definition.WalkSpeed
	return type(walkSpeed) == "number" and walkSpeed > 0 and walkSpeed or 7
end

function PetCatalog.MaxXPForPetId(petId)
	local definition = PetCatalog.GetDefinition(petId)
	return definition and definition.MaxXP or nil
end

function PetCatalog.NextPetId(petId)
	local definitions = allDefinitions()
	for index, definition in ipairs(definitions) do
		if definition.Id == petId then
			local nextDefinition = definitions[index + 1]
			return nextDefinition and nextDefinition.Id or nil
		end
	end
	return nil
end

return PetCatalog
