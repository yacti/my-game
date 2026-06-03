-- Preloads the next pet visual in the progression so evolution swaps do not
-- hitch when a new model and animation set appears on the client.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PetModels = Assets.WaitFor(Assets.Names.PetModels)

local PetPreloader = {}

local preloaded = {}
local inFlight = {}
local watchedPets = {}
local watchedPlots = {}

local function isPet(instance)
	return instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil
end

local function animationFor(animationId, name)
	if type(animationId) ~= "string" or animationId == "" then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = animationId
	return animation
end

local function addPreloadTarget(targets, seen, target)
	if target == nil or seen[target] then
		return
	end
	seen[target] = true
	targets[#targets + 1] = target
end

local function addContentId(targets, seen, contentId)
	if type(contentId) ~= "string" or contentId == "" then
		return
	end
	addPreloadTarget(targets, seen, contentId)
end

local function readProperty(instance, propertyName)
	local ok, value = pcall(function()
		return instance[propertyName]
	end)
	return ok and value or nil
end

local function collectTemplatePreloadTargets(template)
	local targets = {}
	local seen = {}

	addPreloadTarget(targets, seen, template)
	for _, descendant in ipairs(template:GetDescendants()) do
		addPreloadTarget(targets, seen, descendant)

		if descendant:IsA("MeshPart") then
			addContentId(targets, seen, readProperty(descendant, "MeshId"))
			addContentId(targets, seen, readProperty(descendant, "TextureID"))
		elseif descendant:IsA("SpecialMesh") then
			addContentId(targets, seen, readProperty(descendant, "MeshId"))
			addContentId(targets, seen, readProperty(descendant, "TextureId"))
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			addContentId(targets, seen, readProperty(descendant, "Texture"))
		elseif descendant:IsA("SurfaceAppearance") then
			addContentId(targets, seen, readProperty(descendant, "ColorMap"))
			addContentId(targets, seen, readProperty(descendant, "NormalMap"))
			addContentId(targets, seen, readProperty(descendant, "MetalnessMap"))
			addContentId(targets, seen, readProperty(descendant, "RoughnessMap"))
		elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			addContentId(targets, seen, readProperty(descendant, "Image"))
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") or descendant:IsA("Beam") then
			addContentId(targets, seen, readProperty(descendant, "Texture"))
		end
	end

	return targets, seen
end

local function preloadPetId(petId)
	if type(petId) ~= "string" or petId == "" or preloaded[petId] or inFlight[petId] then
		return
	end

	local visual = PetCatalog.VisualForPetId(petId)
	local modelName = visual and visual.ModelName
	local template = type(modelName) == "string" and PetModels:FindFirstChild(modelName) or nil
	if not template then
		return
	end

	inFlight[petId] = true
	task.spawn(function()
		local preloadTargets, seenPreloadTargets = collectTemplatePreloadTargets(template)
		local animations = {}
		local idleAnimation = animationFor(visual.IdleAnimationId, petId .. "IdlePreload")
		local walkAnimation = animationFor(visual.WalkAnimationId, petId .. "WalkPreload")

		if idleAnimation then
			animations[#animations + 1] = idleAnimation
		end
		if walkAnimation then
			animations[#animations + 1] = walkAnimation
		end

		for _, animation in ipairs(animations) do
			addPreloadTarget(preloadTargets, seenPreloadTargets, animation)
		end

		local ok, err = pcall(function()
			ContentProvider:PreloadAsync(preloadTargets)
		end)

		for _, animation in ipairs(animations) do
			animation:Destroy()
		end

		inFlight[petId] = nil
		if ok then
			preloaded[petId] = true
		else
			warn(string.format("[PetPreloader] Failed to preload %s: %s", petId, tostring(err)))
		end
	end)
end

local function preloadNextForPet(pet)
	local petId = pet:GetAttribute(State.Pet.Id)
	local nextPetId = PetCatalog.NextPetId(petId)
	if nextPetId then
		preloadPetId(nextPetId)
	end
end

local function watchPet(pet)
	if watchedPets[pet] then return end
	watchedPets[pet] = true

	preloadNextForPet(pet)

	local idConnection = RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.Id), "PetPreloader.PetIdChanged", function()
		preloadNextForPet(pet)
	end)

	RuntimeGuard.Connect(pet.Destroying, "PetPreloader.PetDestroying", function()
		watchedPets[pet] = nil
		idConnection:Disconnect()
	end)
end

local function watchPlot(plot)
	if watchedPlots[plot] then return end
	watchedPlots[plot] = true

	for _, child in ipairs(plot:GetChildren()) do
		if isPet(child) then
			watchPet(child)
		end
	end

	RuntimeGuard.Connect(plot.ChildAdded, "PetPreloader.PlotChildAdded", function(child)
		if isPet(child) then
			watchPet(child)
		end
	end)

	RuntimeGuard.Connect(plot.Destroying, "PetPreloader.PlotDestroying", function()
		watchedPlots[plot] = nil
	end)
end

local function isPlot(instance)
	return (instance:IsA("Model") or instance:IsA("Folder")) and instance.Name:match("^Plot%d") ~= nil
end

local function watchWorkspace()
	local function onWorkspaceChild(child)
		if isPlot(child) then
			watchPlot(child)
		elseif child.Name == "Plots" then
			for _, plot in ipairs(child:GetChildren()) do
				watchPlot(plot)
			end
			RuntimeGuard.Connect(child.ChildAdded, "PetPreloader.PlotsChildAdded", watchPlot)
		end
	end

	for _, child in ipairs(Workspace:GetChildren()) do
		onWorkspaceChild(child)
	end
	RuntimeGuard.Connect(Workspace.ChildAdded, "PetPreloader.WorkspaceChildAdded", onWorkspaceChild)
end

function PetPreloader.start()
	watchWorkspace()
end

return PetPreloader
