-- Client-only pet evolution presentation. The server marks the evolved pet with
-- one-shot cue attributes; this module renders the local effect for the owner.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local Balance = require(Shared:WaitForChild("Balance"))
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local PetSkinCatalog = require(Shared:WaitForChild("PetSkinCatalog"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local State = require(Shared:WaitForChild("State"))
local ConfettiEffect = require(script.Parent:WaitForChild("ConfettiEffect"))
local CameraFovZoom = require(script.Parent:WaitForChild("CameraFovZoom"))
local EditModePetVisibilityController = require(script.Parent:WaitForChild("EditModePetVisibilityController"))
local MotionSickness = require(script.Parent:WaitForChild("MotionSickness"))
local Notifications = require(script.Parent:WaitForChild("Notifications"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))

local PetEvolutionEffects = {}

local CHARGE_SECONDS = 1.25
local WHITEOUT_SECONDS = 0.18
local MORPH_SECONDS = 0.28
local REVEAL_SECONDS = 0.18
local UI_HIDE_SECONDS = 0.14
local CAMERA_ZOOM_FOV = 8
local CAMERA_OUT_SECONDS = 0.14
local PREVIEW_DURATION_SCALE = 0.5

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
local evolutionBusyPets = setmetatable({}, { __mode = "k" })
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

local function firstBasePart(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

local function finitePositiveNumber(value)
	return type(value) == "number" and value > 0 and value == value and value ~= math.huge
end

local function maturePreviewScaleForPetId(petId, fallbackScale)
	local visual = PetCatalog.VisualForPetId(petId)
	local models = petModels()
	local template = visual and models and PetCatalog.TemplateForPetId(petId)
	if template and template:IsA("Model") then
		local baseScale = template:GetScale()
		if finitePositiveNumber(baseScale) then
			return baseScale * Balance.MAX_SCALE
		end
	end
	return fallbackScale
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
	return CameraFovZoom.Zoom(CAMERA_ZOOM_FOV, CAMERA_IN_TWEEN, CAMERA_OUT_TWEEN)
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

local function cloneOldVisual(petId, petSkinId)
	local visual = PetCatalog.VisualForPetId(petId)
	local models = petModels()
	local template = type(petSkinId) == "string" and PetSkinCatalog.TemplateFor(petSkinId)
		or (visual and models and PetCatalog.TemplateForPetId(petId))
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

local function flashAmount(elapsed, chargeSeconds)
	local alpha = math.clamp(elapsed / chargeSeconds, 0, 1)
	local normalizedElapsed = alpha * CHARGE_SECONDS
	local cycles = FLASH_START_HZ * normalizedElapsed + 0.5 * (FLASH_END_HZ - FLASH_START_HZ) * alpha * normalizedElapsed
	return (math.sin(cycles * math.pi * 2 - math.pi / 2) + 1) * 0.5
end

local function playCharge(effect, pivot, baseScale, pet, options)
	options = type(options) == "table" and options or {}
	local durationScale = math.max(tonumber(options.durationScale) or 1, 0.01)
	local chargeSeconds = CHARGE_SECONDS * durationScale
	local whiteoutSeconds = WHITEOUT_SECONDS * durationScale
	local highlight = addWhiteout(effect)
	local random = Random.new()
	local startedAt = os.clock()

	while effect.Parent and (not pet or pet.Parent) do
		local elapsed = os.clock() - startedAt
		local alpha = math.clamp(elapsed / chargeSeconds, 0, 1)
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local allowsShake = MotionSickness.AllowsShakeEffects()
		local shake = if allowsShake then SHAKE_START + (SHAKE_END - SHAKE_START) * eased else 0
		local rotation = if allowsShake then SHAKE_ROTATION * eased else 0
		local flash = flashAmount(elapsed, chargeSeconds)

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
		TweenService:Create(highlight, TweenInfo.new(whiteoutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			FillTransparency = 0,
			OutlineTransparency = 0,
		}):Play()
		task.wait(whiteoutSeconds)
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

local function stopSound(sound, stopped)
	if not (sound and sound.Parent) then
		return true
	end
	if stopped == true then
		return true
	end
	sound:Stop()
	sound:Destroy()
	return true
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

-- No Parent guard here: restoring a momentarily unparented (or even destroyed)
-- instance is a harmless property write, while skipping one would strand its
-- snapshot — a hidden label left at TextTransparency 1 forever.
local function restoreInstance(instance, entry)
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
	if hidden.connection then hidden.connection:Disconnect() end

	-- Restore even while the pet is momentarily unparented (streaming, server
	-- reparenting): skipping would leave every hidden label invisible forever.
	for instance, entry in pairs(hidden.state) do
		restoreInstance(instance, entry)
	end

	if pet.Parent then
		pet:ScaleTo(hidden.targetScale)
		local highlight = addWhiteout(pet, 0, 0)
		TweenService:Create(highlight, REVEAL_TWEEN, { FillTransparency = 1, OutlineTransparency = 1 }):Play()
		task.delay(REVEAL_SECONDS, function()
			if highlight.Parent then highlight:Destroy() end
		end)
	end
	task.delay(REVEAL_SECONDS, function()
		pet:SetAttribute(State.Pet.EvolutionPaused, hidden.previousPause)
	end)
end

local function petDisplayName(petId)
	local definition = PetCatalog.GetDefinition(petId)
	local visual = definition and definition.Visual
	return (visual and visual.ModelName) or petId
end

local function petLevel(petId)
	local definition = PetCatalog.GetDefinition(petId)
	local order = definition and definition.Order
	return type(order) == "number" and math.max(math.floor(order), 1) or nil
end

local function skinPetDisplayName(petSkinId)
	return PetSkinCatalog.NameFor(petSkinId):gsub("%s+Skin$", "")
end

local function showEvolutionNotification(oldPetId, pet, cueKind, targetSkinId)
	if cueKind == "PetSkinApply" then
		Notifications.show({
			text = PetSkinCatalog.NameFor(targetSkinId) .. " applied!",
			kind = NotificationConfig.Kinds.Success,
		})
		return
	end
	local newPetId = pet:GetAttribute(State.Pet.Id)
	if type(newPetId) ~= "string" or newPetId == "" or newPetId == oldPetId then
		return
	end

	local petSkinId = pet:GetAttribute(State.Pet.SkinId)
	if type(petSkinId) == "string" and PetSkinCatalog.Get(petSkinId) then
		local oldLevel = petLevel(oldPetId)
		local newLevel = petLevel(newPetId)
		if oldLevel and newLevel then
			Notifications.show({
				text = string.format(
					"Your %s has levelled up from level %d to %d!",
					skinPetDisplayName(petSkinId),
					oldLevel,
					newLevel
				),
				kind = NotificationConfig.Kinds.Success,
			})
			return
		end
	end

	Notifications.show({
		text = string.format("Your %s evolved into a %s!", petDisplayName(oldPetId), petDisplayName(newPetId)),
		kind = NotificationConfig.Kinds.Success,
	})
end

local function appendPathPetId(path, petId)
	if type(petId) ~= "string" or petId == "" then
		return
	end
	if path[#path] ~= petId then
		path[#path + 1] = petId
	end
end

local function fallbackEvolutionPath(oldPetId, finalPetId)
	local path = {}
	appendPathPetId(path, oldPetId)
	appendPathPetId(path, finalPetId)
	return path
end

local function decodeEvolutionPath(pet, oldPetId)
	local finalPetId = pet:GetAttribute(State.Pet.Id)
	local encoded = pet:GetAttribute(State.Pet.EvolutionPathPetIds)
	if type(encoded) ~= "string" or encoded == "" then
		return fallbackEvolutionPath(oldPetId, finalPetId)
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(encoded)
	end)
	if not ok or type(decoded) ~= "table" then
		warn("[PetEvolutionEffects] Invalid pet evolution path payload")
		return fallbackEvolutionPath(oldPetId, finalPetId)
	end

	local path = {}
	for index = 1, #decoded do
		appendPathPetId(path, decoded[index])
	end
	if #path == 0 then
		return fallbackEvolutionPath(oldPetId, finalPetId)
	end

	if path[1] ~= oldPetId then
		table.insert(path, 1, oldPetId)
	end
	appendPathPetId(path, finalPetId)
	return path
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

	return seq,
		oldPetId,
		oldScale,
		pivot,
		decodeEvolutionPath(pet, oldPetId),
		pet:GetAttribute(State.Pet.EvolutionCueKind),
		pet:GetAttribute(State.Pet.EvolutionOldSkinId),
		pet:GetAttribute(State.Pet.EvolutionTargetSkinId)
end

local function playPreviewSound(petId, pet)
	local soundParent = pet.PrimaryPart or firstBasePart(pet)
	if not soundParent then
		return
	end
	SoundEffects.PlayAnimal(petId, {
		parent = soundParent,
	})
end

local function playPetSkinSound(petSkinId, pet)
	local definition = type(petSkinId) == "string" and PetSkinCatalog.Get(petSkinId) or nil
	if not definition then
		return
	end

	local soundParent = pet.PrimaryPart or firstBasePart(pet)
	if not soundParent then
		return
	end
	local options = { parent = soundParent }
	if type(definition.SoundId) == "string" then
		SoundEffects.PlayAsset(definition.SoundId, options)
	end
end

local function createEffectForPetId(petId, scale, pivot, parent, petSkinId)
	local effect = cloneOldVisual(petId, petSkinId)
	if not effect then
		warn("[PetEvolutionEffects] Missing visual for evolution preview: " .. tostring(petSkinId or petId))
		return nil
	end

	effect:ScaleTo(scale)
	effect.Parent = parent or Workspace
	effect:PivotTo(pivot)
	return effect
end

local function playIntermediatePreview(effect, petId, scale, pivot, pet)
	playPreviewSound(petId, pet)
	local highlight = playCharge(effect, pivot, scale, pet, {
		durationScale = PREVIEW_DURATION_SCALE,
	})
	return highlight
end

local function playForPet(pet)
	if not isOwnPet(pet) then return end
	-- Defer the cinematic while edit-mode visibility owns the pet. The cue
	-- remains unread and the hidden attribute's change signal replays it after
	-- the controller restores the pet's original visual properties.
	if pet:GetAttribute(EditModePetVisibilityController.HiddenAttribute) == true then return end
	-- Serialize cinematics per pet: a second cue arriving mid-cinematic would
	-- snapshot the already-hidden label transparencies as the "originals" to
	-- restore, leaving the billboard permanently invisible. The active
	-- cinematic replays the latest cue once it finishes (see bottom of the
	-- spawned task); the seq attribute itself acts as the queue.
	if evolutionBusyPets[pet] then return end

	local seq, oldPetId, oldScale, pivot, pathPetIds, cueKind, oldSkinId, targetSkinId = readCue(pet)
	if not seq then return end

	local effect = createEffectForPetId(oldPetId, oldScale, pivot, pet.Parent or Workspace, oldSkinId)
	if not effect then return end

	playedSeqByPet[pet] = seq
	evolutionBusyPets[pet] = true
	local restoreCamera = playCameraZoom()
	local hiddenPet = hidePet(pet, pivot)

	task.spawn(function()
		local drumroll = nil
		local drumrollStopped = false
		local ok, err = pcall(function()
			drumroll = SoundEffects.Play(SoundEffects.Names.Drumroll)
			if drumroll then
				drumroll.Looped = true
			end
			local highlight = playCharge(effect, pivot, oldScale, pet)
			if not oldSkinId then
				for index = 2, math.max(#pathPetIds - 1, 1) do
					local previewPetId = pathPetIds[index]
					if not pet.Parent then
						break
					end

					local previewScale = maturePreviewScaleForPetId(previewPetId, oldScale)
					local previewEffect = createEffectForPetId(previewPetId, previewScale, pivot, pet.Parent or Workspace)
					if previewEffect then
						if effect.Parent then effect:Destroy() end
						effect = previewEffect
						highlight = playIntermediatePreview(effect, previewPetId, previewScale, pivot, pet)
					end
				end
			end
			if pet.Parent then
				morphEffectToNewPet(effect, pet, pivot, highlight)
				-- Celebration lands with the morph reveal, right as
				-- restoreCamera tweens the FOV back out below.
				drumrollStopped = stopSound(drumroll, drumrollStopped)
				if cueKind == "PetSkinApply" then
					playPetSkinSound(targetSkinId, pet)
				end
				ConfettiEffect.Emit()
				showEvolutionNotification(oldPetId, pet, cueKind, targetSkinId)
			end
		end)
		drumrollStopped = stopSound(drumroll, drumrollStopped)
		restoreCamera()
		if effect.Parent then effect:Destroy() end
		restorePet(pet, hiddenPet)
		if not ok then
			warn("[PetEvolutionEffects] Evolution effect failed: " .. tostring(err))
		end
		-- Hold the busy flag through the reveal tween so a queued cue cannot
		-- snapshot half-restored transparency values, then play any cue that
		-- arrived mid-cinematic (readCue no-ops when the seq already played).
		task.wait(REVEAL_SECONDS)
		evolutionBusyPets[pet] = nil
		if pet.Parent then
			playForPet(pet)
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
	RuntimeGuard.Connect(
		pet:GetAttributeChangedSignal(EditModePetVisibilityController.HiddenAttribute),
		"PetEvolutionEffects.EditModePetHiddenChanged",
		function()
			if pet:GetAttribute(EditModePetVisibilityController.HiddenAttribute) ~= true then
				playForPet(pet)
			end
		end
	)
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
