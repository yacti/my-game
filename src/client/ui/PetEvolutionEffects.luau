-- Client-only pet evolution presentation. The server marks the evolved pet with
-- one-shot cue attributes; this module renders the local effect for the owner.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local PetEvolutionEffects = {}

local CHARGE_SECONDS = 1.25
local WHITEOUT_SECONDS = 0.18
local MORPH_SECONDS = 0.28
local REVEAL_SECONDS = 0.18
local UI_HIDE_SECONDS = 0.14
local CAMERA_ZOOM_FOV = 8
local CAMERA_OUT_SECONDS = 0.14

local FLASH_START_HZ = 1
local FLASH_END_HZ = 5
local CHARGE_SCALE = 1.35
local SHAKE_START = 0.04
local SHAKE_END = 0.34
local SHAKE_ROTATION = math.rad(5)

local UI_HIDE_TWEEN = TweenInfo.new(UI_HIDE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REVEAL_TWEEN = TweenInfo.new(REVEAL_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MORPH_TWEEN = TweenInfo.new(MORPH_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local CAMERA_IN_TWEEN = TweenInfo.new(CHARGE_SECONDS + WHITEOUT_SECONDS + MORPH_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CAMERA_OUT_TWEEN = TweenInfo.new(CAMERA_OUT_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local player = Players.LocalPlayer
local watchedPlots = setmetatable({}, { __mode = "k" })
local watchedPets = setmetatable({}, { __mode = "k" })
local playedSeqByPet = setmetatable({}, { __mode = "k" })
local activeCameraZooms = 0
local cameraBaseFov = nil
local cameraZoomTween = nil
local warnedMissingPetModels = false

local function petModels()
	local folder = Assets.Find(Assets.Names.PetModels)
	if not folder and not warnedMissingPetModels then
		warn("[PetEvolutionEffects] Missing ReplicatedStorage.Assets.PetModels; pet evolution effects disabled")
		warnedMissingPetModels = true
	end
	return folder
end

local function assignedPlot()
	return PlotResolver.ResolveForPlayer(player)
end

local function isOwnPet(pet)
	local plot = assignedPlot()
	return plot ~= nil and pet:IsDescendantOf(plot)
end

local function tweenScale(model, fromScale, toScale, tweenInfo, pivot)
	local value = Instance.new("NumberValue")
	value.Value = fromScale
	model:ScaleTo(fromScale)
	if pivot then model:PivotTo(pivot) end

	local connection = value.Changed:Connect(function(scale)
		if not model.Parent then return end
		model:ScaleTo(scale)
		if pivot then model:PivotTo(pivot) end
	end)

	local tween = TweenService:Create(value, tweenInfo, { Value = toScale })
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if model.Parent then
			model:ScaleTo(toScale)
			if pivot then model:PivotTo(pivot) end
		end
	end)
	tween:Play()
	return tween
end

local function playCameraZoom()
	local camera = Workspace.CurrentCamera
	if not camera then return function() end end

	if activeCameraZooms == 0 then
		cameraBaseFov = camera.FieldOfView
	end
	activeCameraZooms += 1

	if cameraZoomTween and cameraZoomTween.PlaybackState == Enum.PlaybackState.Playing then
		cameraZoomTween:Cancel()
	end
	cameraZoomTween = TweenService:Create(camera, CAMERA_IN_TWEEN, {
		FieldOfView = math.max((cameraBaseFov or camera.FieldOfView) - CAMERA_ZOOM_FOV, 40),
	})
	cameraZoomTween:Play()

	local restored = false
	return function()
		if restored then return end
		restored = true

		activeCameraZooms = math.max(activeCameraZooms - 1, 0)
		if activeCameraZooms > 0 then
			return
		end

		if cameraZoomTween and cameraZoomTween.PlaybackState == Enum.PlaybackState.Playing then
			cameraZoomTween:Cancel()
			cameraZoomTween = nil
		end
		local currentCamera = Workspace.CurrentCamera
		local targetFov = cameraBaseFov
		cameraBaseFov = nil
		if currentCamera then
			TweenService:Create(currentCamera, CAMERA_OUT_TWEEN, { FieldOfView = targetFov or 70 }):Play()
		end
	end
end

local function addWhiteout(model, fillTransparency, outlineTransparency)
	local highlight = Instance.new("Highlight")
	highlight.Name = "EvolutionWhiteout"
	highlight.Adornee = model
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = fillTransparency or 1
	highlight.OutlineTransparency = outlineTransparency or 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model
	return highlight
end

local function cloneOldVisual(petId)
	local visual = PetCatalog.VisualForPetId(petId)
	local models = petModels()
	local template = visual and models and models:FindFirstChild(visual.ModelName)
	if not (template and template:IsA("Model")) then return nil end

	local clone = template:Clone()
	clone.Name = "PetEvolutionEffect"
	clone:SetAttribute(State.Pet.Index, nil)
	clone:SetAttribute(State.Pet.Id, nil)

	local hasPart = false
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			hasPart = true
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.LocalTransparencyModifier = 0
		elseif descendant:IsA("ProximityPrompt")
			or descendant:IsA("ClickDetector")
			or descendant:IsA("Script")
			or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end

	if not hasPart then
		clone:Destroy()
		return nil
	end
	return clone
end

local function flashAmount(elapsed)
	local alpha = math.clamp(elapsed / CHARGE_SECONDS, 0, 1)
	local cycles = FLASH_START_HZ * elapsed + 0.5 * (FLASH_END_HZ - FLASH_START_HZ) * alpha * elapsed
	return (math.sin(cycles * math.pi * 2 - math.pi / 2) + 1) * 0.5
end

local function playCharge(effect, pivot, baseScale, pet)
	local highlight = addWhiteout(effect)
	local random = Random.new()
	local startedAt = os.clock()

	while effect.Parent and (not pet or pet.Parent) do
		local elapsed = os.clock() - startedAt
		local alpha = math.clamp(elapsed / CHARGE_SECONDS, 0, 1)
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local shake = SHAKE_START + (SHAKE_END - SHAKE_START) * eased
		local rotation = SHAKE_ROTATION * eased
		local flash = flashAmount(elapsed)

		effect:ScaleTo(baseScale * (1 + (CHARGE_SCALE - 1) * eased))
		effect:PivotTo(pivot
			* CFrame.new(
				random:NextNumber(-shake, shake),
				random:NextNumber(-shake, shake) * 0.35,
				random:NextNumber(-shake, shake)
			)
			* CFrame.Angles(
				random:NextNumber(-rotation, rotation),
				random:NextNumber(-rotation, rotation),
				random:NextNumber(-rotation, rotation)
			))

		highlight.FillTransparency = 1 - flash
		highlight.OutlineTransparency = 1 - flash * 0.75

		if alpha >= 1 then break end
		RunService.RenderStepped:Wait()
	end

	if effect.Parent and (not pet or pet.Parent) then
		TweenService:Create(highlight, TweenInfo.new(WHITEOUT_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			FillTransparency = 0,
			OutlineTransparency = 0,
		}):Play()
		task.wait(WHITEOUT_SECONDS)
	end
	return highlight
end

local function maxBoundsSize(model)
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

local function morphEffectToNewPet(effect, newPet, pivot, highlight)
	local effectSize = maxBoundsSize(effect)
	local newPetSize = maxBoundsSize(newPet)
	local targetScale = effectSize > 0 and effect:GetScale() * (newPetSize / effectSize) or effect:GetScale()

	tweenScale(effect, effect:GetScale(), targetScale, MORPH_TWEEN, pivot)
	for _, descendant in ipairs(effect:GetDescendants()) do
		if descendant:IsA("BasePart") then
			TweenService:Create(descendant, MORPH_TWEEN, { LocalTransparencyModifier = 1 }):Play()
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			TweenService:Create(descendant, MORPH_TWEEN, { Transparency = 1 }):Play()
		end
	end
	if highlight then
		TweenService:Create(highlight, MORPH_TWEEN, { FillTransparency = 1, OutlineTransparency = 1 }):Play()
	end
	task.wait(MORPH_SECONDS)
end

local function remember(hidden, instance, kind, values)
	if hidden.state[instance] then return false end
	hidden.state[instance] = { kind = kind, values = values }
	return true
end

local function hideGuiObject(instance, hidden)
	local props = { BackgroundTransparency = instance.BackgroundTransparency }
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		props.TextTransparency = instance.TextTransparency
		props.TextStrokeTransparency = instance.TextStrokeTransparency
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		props.ImageTransparency = instance.ImageTransparency
	end
	if not remember(hidden, instance, "tweenProps", props) then return end

	local hiddenProps = {}
	for prop in pairs(props) do
		hiddenProps[prop] = 1
	end
	TweenService:Create(instance, UI_HIDE_TWEEN, hiddenProps):Play()
end

local function hideInstance(instance, hidden)
	if hidden.state[instance] then return end

	if instance:IsA("BasePart") then
		remember(hidden, instance, "localTransparency", instance.LocalTransparencyModifier)
		instance.LocalTransparencyModifier = 1
	elseif instance:IsA("Decal") or instance:IsA("Texture") then
		remember(hidden, instance, "transparency", instance.Transparency)
		instance.Transparency = 1
	elseif instance:IsA("BillboardGui") or instance:IsA("SurfaceGui") then
		if remember(hidden, instance, "enabled", instance.Enabled) then
			instance.Enabled = true
			for _, descendant in ipairs(instance:GetDescendants()) do
				hideInstance(descendant, hidden)
			end
		end
	elseif instance:IsA("GuiObject") then
		hideGuiObject(instance, hidden)
	elseif instance:IsA("UIStroke") then
		if remember(hidden, instance, "tweenProps", { Transparency = instance.Transparency }) then
			TweenService:Create(instance, UI_HIDE_TWEEN, { Transparency = 1 }):Play()
		end
	elseif instance:IsA("ProximityPrompt") then
		remember(hidden, instance, "prompt", instance.Enabled)
		instance.Enabled = false
	end
end

local function hidePet(pet, pivot)
	local hidden = {
		state = {},
		previousPause = pet:GetAttribute(State.Pet.EvolutionPaused),
		targetScale = pet:GetScale(),
	}
	pet:SetAttribute(State.Pet.EvolutionPaused, true)

	for _, descendant in ipairs(pet:GetDescendants()) do
		hideInstance(descendant, hidden)
	end
	hidden.connection = pet.DescendantAdded:Connect(function(descendant)
		hideInstance(descendant, hidden)
	end)
	return hidden
end

local function restoreInstance(instance, entry)
	if not instance.Parent then return end

	if entry.kind == "localTransparency" then
		instance.LocalTransparencyModifier = 1
		TweenService:Create(instance, REVEAL_TWEEN, { LocalTransparencyModifier = entry.values }):Play()
	elseif entry.kind == "transparency" then
		instance.Transparency = 1
		TweenService:Create(instance, REVEAL_TWEEN, { Transparency = entry.values }):Play()
	elseif entry.kind == "tweenProps" then
		TweenService:Create(instance, REVEAL_TWEEN, entry.values):Play()
	elseif entry.kind == "enabled" then
		instance.Enabled = true
		if entry.values == false then
			task.delay(REVEAL_SECONDS, function()
				if instance.Parent then instance.Enabled = false end
			end)
		end
	elseif entry.kind == "prompt" then
		task.delay(REVEAL_SECONDS, function()
			if instance.Parent then instance.Enabled = entry.values end
		end)
	end
end

local function restorePet(pet, hidden)
	if not pet.Parent then return end
	if hidden.connection then hidden.connection:Disconnect() end

	pet:ScaleTo(hidden.targetScale)
	local highlight = addWhiteout(pet, 0, 0)
	for instance, entry in pairs(hidden.state) do
		restoreInstance(instance, entry)
	end

	TweenService:Create(highlight, REVEAL_TWEEN, { FillTransparency = 1, OutlineTransparency = 1 }):Play()
	task.delay(REVEAL_SECONDS, function()
		if highlight.Parent then highlight:Destroy() end
		if pet.Parent then
			pet:SetAttribute(State.Pet.EvolutionPaused, hidden.previousPause)
		end
	end)
end

local function readCue(pet)
	local seq = pet:GetAttribute(State.Pet.EvolutionSeq)
	if type(seq) ~= "number" or playedSeqByPet[pet] == seq then return nil end

	local oldPetId = pet:GetAttribute(State.Pet.EvolutionOldPetId)
	local oldScale = pet:GetAttribute(State.Pet.EvolutionOldScale)
	local pivot = pet:GetAttribute(State.Pet.EvolutionPivot)
	if type(oldPetId) ~= "string" or type(oldScale) ~= "number" or typeof(pivot) ~= "CFrame" then
		return nil
	end

	return seq, oldPetId, oldScale, pivot
end

local function playForPet(pet)
	if not isOwnPet(pet) then return end

	local seq, oldPetId, oldScale, pivot = readCue(pet)
	if not seq then return end

	local effect = cloneOldVisual(oldPetId)
	if not effect then return end

	playedSeqByPet[pet] = seq
	local restoreCamera = playCameraZoom()
	local hiddenPet = hidePet(pet, pivot)
	effect:ScaleTo(oldScale)
	effect.Parent = pet.Parent or Workspace
	effect:PivotTo(pivot)

	task.spawn(function()
		local ok, err = pcall(function()
			local highlight = playCharge(effect, pivot, oldScale, pet)
			if pet.Parent then
				morphEffectToNewPet(effect, pet, pivot, highlight)
			end
		end)
		restoreCamera()
		if effect.Parent then effect:Destroy() end
		restorePet(pet, hiddenPet)
		if not ok then
			warn("[PetEvolutionEffects] Evolution effect failed: " .. tostring(err))
		end
	end)
end

local function bindPet(pet)
	if watchedPets[pet] then return end
	watchedPets[pet] = true

	playForPet(pet)
	RuntimeGuard.Connect(pet:GetAttributeChangedSignal(State.Pet.EvolutionSeq), "PetEvolutionEffects.EvolutionSeqChanged", function()
		playForPet(pet)
	end)
	RuntimeGuard.Connect(pet.Destroying, "PetEvolutionEffects.PetDestroying", function()
		watchedPets[pet] = nil
		playedSeqByPet[pet] = nil
	end)
end

local function watchPlot(plot)
	if watchedPlots[plot] then return end
	watchedPlots[plot] = true

	for _, child in ipairs(plot:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(State.Pet.Index) ~= nil then bindPet(child) end
	end
	RuntimeGuard.Connect(plot.ChildAdded, "PetEvolutionEffects.PlotChildAdded", function(child)
		if child:IsA("Model") and child:GetAttribute(State.Pet.Index) ~= nil then bindPet(child) end
	end)
end

local function watchWorkspace()
	local function watchChild(child)
		if (child:IsA("Model") or child:IsA("Folder")) and child.Name:match("^Plot%d") then
			watchPlot(child)
		elseif child.Name == "Plots" then
			for _, plot in ipairs(child:GetChildren()) do watchPlot(plot) end
			RuntimeGuard.Connect(child.ChildAdded, "PetEvolutionEffects.PlotsChildAdded", watchPlot)
		end
	end

	for _, child in ipairs(Workspace:GetChildren()) do watchChild(child) end
	RuntimeGuard.Connect(Workspace.ChildAdded, "PetEvolutionEffects.WorkspaceChildAdded", watchChild)
end

function PetEvolutionEffects.start()
	watchWorkspace()
	local function replayOwnedPets()
		for pet in pairs(watchedPets) do
			if pet.Parent then playForPet(pet) end
		end
	end
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "PetEvolutionEffects.AssignedPlotChanged", replayOwnedPets)
	RuntimeGuard.Connect(player:GetPropertyChangedSignal("RespawnLocation"), "PetEvolutionEffects.RespawnLocationChanged", replayOwnedPets)
end

return PetEvolutionEffects
