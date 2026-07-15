-- Locally hides the owning player's pets while edit mode is active when the
-- profile-backed setting is enabled. Original visual properties are preserved
-- and kept current while hidden so evolution/VFX changes restore correctly.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerSettings = require(Shared:WaitForChild("PlayerSettings"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local EditModePetVisibilityController = {}

local EDIT_MODE_ATTR = "EditMode"
local EVOLUTION_EFFECT_NAME = "PetEvolutionEffect"

EditModePetVisibilityController.HiddenAttribute = "__EditModePetHidden"

local player = Players.LocalPlayer
local started = false
local activePlot = nil
local plotConnections = {}
local petRecords = {}

local function isPet(instance)
	return instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil
end

local function isPetVisual(instance)
	return isPet(instance) or (instance:IsA("Model") and instance.Name == EVOLUTION_EFFECT_NAME)
end

local function hiddenProperty(instance)
	if instance:IsA("BasePart") then
		return "LocalTransparencyModifier", 1
	end
	if instance:IsA("Decal") or instance:IsA("Texture") then
		return "Transparency", 1
	end
	if instance:IsA("BillboardGui")
		or instance:IsA("SurfaceGui")
		or instance:IsA("ParticleEmitter")
		or instance:IsA("Trail")
		or instance:IsA("Beam")
		or instance:IsA("Highlight")
		or instance:IsA("Light") then
		return "Enabled", false
	end
	return nil, nil
end

local function restoreEntry(record, instance)
	local entry = record.entries[instance]
	if not entry then
		return
	end
	record.entries[instance] = nil
	if entry.connection then
		entry.connection:Disconnect()
	end
	if instance.Parent then
		instance[entry.property] = entry.value
	end
end

local function hideInstance(record, instance)
	if record.entries[instance] then
		return
	end

	local property, hiddenValue = hiddenProperty(instance)
	if not property then
		return
	end

	local entry = {
		property = property,
		hiddenValue = hiddenValue,
		value = instance[property],
		connection = nil,
		applying = false,
	}
	record.entries[instance] = entry
	entry.connection = RuntimeGuard.Connect(
		instance:GetPropertyChangedSignal(property),
		"EditModePetVisibilityController.HiddenPropertyChanged",
		function()
			if entry.applying or not record.hidden or not instance.Parent then
				return
			end
			local nextValue = instance[property]
			if nextValue == entry.hiddenValue then
				return
			end
			-- Remember the latest value another presentation system intended,
			-- then keep this viewer's pet hidden until edit mode ends.
			entry.value = nextValue
			entry.applying = true
			instance[property] = entry.hiddenValue
			entry.applying = false
		end
	)
	entry.applying = true
	instance[property] = hiddenValue
	entry.applying = false
end

local function hidePet(record)
	if record.hidden then
		return
	end
	record.hidden = true
	if record.isPet then
		record.pet:SetAttribute(EditModePetVisibilityController.HiddenAttribute, true)
	end
	for _, descendant in ipairs(record.pet:GetDescendants()) do
		hideInstance(record, descendant)
	end
end

local function showPet(record)
	if not record.hidden then
		return
	end
	record.hidden = false
	local instances = {}
	for instance in pairs(record.entries) do
		instances[#instances + 1] = instance
	end
	for _, instance in ipairs(instances) do
		restoreEntry(record, instance)
	end
	if record.isPet and record.pet.Parent then
		record.pet:SetAttribute(EditModePetVisibilityController.HiddenAttribute, nil)
	end
end

local function shouldHidePets()
	local settings = PlayerStateStore.Get(PlayerStateStore.Fields.PlayerSettings)
	return player:GetAttribute(EDIT_MODE_ATTR) == true
		and PlayerSettings.Get(settings, PlayerSettings.Keys.HidePetsInEditMode)
end

local function refreshPet(record, hide)
	if hide then
		hidePet(record)
	else
		showPet(record)
	end
end

local function refreshAllPets()
	local hide = shouldHidePets()
	for pet, record in pairs(petRecords) do
		if activePlot and pet.Parent and pet:IsDescendantOf(activePlot) then
			refreshPet(record, hide)
		else
			showPet(record)
			petRecords[pet] = nil
		end
	end
end

local function unbindPet(pet, restore)
	local record = petRecords[pet]
	if not record then
		return
	end
	petRecords[pet] = nil
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	if restore then
		showPet(record)
	else
		for _, entry in pairs(record.entries) do
			if entry.connection then
				entry.connection:Disconnect()
			end
		end
		table.clear(record.entries)
	end
end

local function bindPet(pet)
	if petRecords[pet] then
		return
	end
	local record = {
		pet = pet,
		isPet = isPet(pet),
		hidden = false,
		entries = {},
		connections = {},
	}
	petRecords[pet] = record
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(
		pet.DescendantAdded,
		"EditModePetVisibilityController.PetDescendantAdded",
		function(descendant)
			if record.hidden then
				hideInstance(record, descendant)
			end
		end
	)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(
		pet.DescendantRemoving,
		"EditModePetVisibilityController.PetDescendantRemoving",
		function(descendant)
			restoreEntry(record, descendant)
		end
	)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(
		pet.Destroying,
		"EditModePetVisibilityController.PetDestroying",
		function()
			unbindPet(pet, false)
		end
	)
	refreshPet(record, shouldHidePets())
end

local function disconnectPlot()
	for _, connection in ipairs(plotConnections) do
		connection:Disconnect()
	end
	table.clear(plotConnections)
	local pets = {}
	for pet in pairs(petRecords) do
		pets[#pets + 1] = pet
	end
	for _, pet in ipairs(pets) do
		unbindPet(pet, true)
	end
	activePlot = nil
end

local function syncPlot()
	local plot = PlotResolver.ResolveForPlayer(player)
	if plot == activePlot then
		refreshAllPets()
		return
	end
	disconnectPlot()
	activePlot = plot
	if not activePlot then
		return
	end

	for _, child in ipairs(activePlot:GetChildren()) do
		if isPetVisual(child) then
			bindPet(child)
		end
	end
	plotConnections[#plotConnections + 1] = RuntimeGuard.Connect(
		activePlot.ChildAdded,
		"EditModePetVisibilityController.PlotChildAdded",
		function(child)
			if isPetVisual(child) then
				bindPet(child)
			end
		end
	)
	plotConnections[#plotConnections + 1] = RuntimeGuard.Connect(
		activePlot.ChildRemoved,
		"EditModePetVisibilityController.PlotChildRemoved",
		function(child)
			if petRecords[child] then
				unbindPet(child, child.Parent ~= nil)
			end
		end
	)
end

function EditModePetVisibilityController.start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(
		player:GetAttributeChangedSignal(EDIT_MODE_ATTR),
		"EditModePetVisibilityController.EditModeChanged",
		refreshAllPets
	)
	RuntimeGuard.Connect(
		player:GetAttributeChangedSignal(State.Player.AssignedPlotName),
		"EditModePetVisibilityController.AssignedPlotChanged",
		syncPlot
	)
	RuntimeGuard.Connect(
		player:GetPropertyChangedSignal("RespawnLocation"),
		"EditModePetVisibilityController.RespawnLocationChanged",
		syncPlot
	)
	PlayerStateStore.Observe(PlayerStateStore.Fields.PlayerSettings, refreshAllPets)
	syncPlot()
end

return EditModePetVisibilityController
