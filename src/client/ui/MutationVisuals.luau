local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local Mutations = require(Shared:WaitForChild("Mutations"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local AppleTreeSlotVisuals = require(script.Parent:WaitForChild("AppleTreeSlotVisuals"))
local PlotScope = require(script.Parent:WaitForChild("PlotScope"))

local MutationVisuals = {}

local FOLDER_NAME = "__MutationVisuals"
local OVERLAY_NAME = "ForceFieldOverlay"
-- Shell thickness per face, as a fraction of the food's overall extent. Kept
-- additive rather than a Size multiplier: multiplying gives an elongated part
-- (a sunflower stalk block) a thick sleeve on its long axis and a hairline on
-- the short ones, which reads as a lopsided, one-axis stretch. The ratio is the
-- additive equivalent of a 1.05 Size multiplier on a roughly cubic food; the
-- ceiling is what stops a maxed sunflower from wearing a jelly coat, since that
-- same percentage of an 8x food is a far thicker shell than it is of an apple.
local OVERLAY_MARGIN_RATIO = 0.025
local OVERLAY_MARGIN_MIN = 0.025
local OVERLAY_MARGIN_MAX = 0.3
local OVERLAY_COLOR = Color3.fromRGB(107, 206, 255)
local OVERLAY_TRANSPARENCY = 0.25
local MAX_VISUAL_DISTANCE = 80
local SCOPE_RANGE = MAX_VISUAL_DISTANCE
local REFRESH_SECONDS = 0.3
local GRADIENT_CYCLE_SECONDS = 2
local DEFAULT_EFFECT_REFERENCE_EXTENT = 4
local MIN_EFFECT_SCALE = 0.2
local MAX_EFFECT_SCALE = 1.5
local EFFECT_SCALE_MULTIPLIER = 1.5
local EFFECT_EXTENT_EPSILON = 0.01
local VISIBLE_TRANSPARENCY_CUTOFF = 0.98

local player = Players.LocalPlayer
local tracked = {}

local function isTreeGroundCandidate(instance)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance.Name:match("^BaseFoodGround%d+$") ~= nil
		and instance:GetAttribute(State.TreeClicker.LocalVisual) ~= true
end

local function isFoodCandidate(instance)
	if instance:IsA("Tool") then
		return instance:GetAttribute(State.Food.Id) ~= nil
			or instance:GetAttribute(State.Food.MutationIds) ~= nil
	end
	return isTreeGroundCandidate(instance) or ((instance:IsA("BasePart") or instance:IsA("Model"))
		and (
			instance:GetAttribute(State.Food.Id) ~= nil
			or instance:GetAttribute(State.Food.MutationIds) ~= nil
			or instance:GetAttribute(State.TreeClicker.GroundPile) == true
		)
		and instance:GetAttribute(State.TreeClicker.LocalVisual) ~= true)
end

local function firstBasePart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	if instance:IsA("Tool") then
		return instance:FindFirstChild("Handle") or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function hostFor(target)
	if target:IsA("Tool") then
		return target
	end
	if target:GetAttribute(State.TreeClicker.GroundPile) == true then
		return AppleTreeSlotVisuals.GroundVisualForMarker(target) or target
	end
	return target
end

local function visualFolder(record, host)
	if record.folder and record.folder.Parent == host then
		return record.folder
	end
	if record.folder then
		record.folder:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = host
	record.folder = folder
	return folder
end

local function clearRecord(record)
	if record.folder then
		record.folder:Destroy()
		record.folder = nil
	end
	for _, instance in ipairs(record.extras or {}) do
		if instance.Parent then
			instance:Destroy()
		end
	end
	record.extras = {}
	record.scaledEmitters = {}
	record.effectExtent = nil
	record.renderKey = nil
	record.host = nil
	record.overlayParts = nil
	record.overlayColors = nil
	record.overlayPairs = nil
end

local function playerPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function inVisualRange(targetPart)
	local position = playerPosition()
	if not position then
		return false
	end
	return (targetPart.Position - position).Magnitude <= MAX_VISUAL_DISTANCE
end

local function scaledNumberSequence(sequence, scale)
	local keypoints = table.create(#sequence.Keypoints)
	for index, keypoint in ipairs(sequence.Keypoints) do
		keypoints[index] = NumberSequenceKeypoint.new(
			keypoint.Time,
			keypoint.Value * scale,
			keypoint.Envelope * scale
		)
	end
	return NumberSequence.new(keypoints)
end

local function finitePositiveNumber(value)
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function instanceScale(instance)
	local ok, scale = pcall(function()
		return instance:GetScale()
	end)
	return ok and finitePositiveNumber(scale) and scale or nil
end

local function maxDimension(size)
	return math.max(size.X, size.Y, size.Z)
end

-- Derived from the food's extent rather than fixed, so an 8x sunflower gets a
-- proportionally thicker shell instead of a hairline and a seedling does not
-- get a jelly coat. Clamped at both ends to keep the extremes sane.
local function overlayMarginFor(extent)
	if not finitePositiveNumber(extent) then
		extent = DEFAULT_EFFECT_REFERENCE_EXTENT
	end
	return math.clamp(extent * OVERLAY_MARGIN_RATIO, OVERLAY_MARGIN_MIN, OVERLAY_MARGIN_MAX)
end

local function overlayPartSize(sourcePart, margin)
	return sourcePart.Size + Vector3.one * (margin * 2)
end

local function visualExtent(instance)
	if not instance then
		return nil
	end

	if instance:IsA("BasePart") then
		local extent = maxDimension(instance.Size)
		return finitePositiveNumber(extent) and extent or nil
	end

	if instance:IsA("Model") then
		local ok, _, size = pcall(function()
			return instance:GetBoundingBox()
		end)
		if ok and typeof(size) == "Vector3" then
			local extent = maxDimension(size)
			return finitePositiveNumber(extent) and extent or nil
		end
	end

	if instance:IsA("Tool") then
		local ok, _, size = pcall(function()
			return instance:GetBoundingBox()
		end)
		if ok and typeof(size) == "Vector3" then
			local extent = maxDimension(size)
			if finitePositiveNumber(extent) then
				return extent
			end
		end

		local part = firstBasePart(instance)
		if part then
			return visualExtent(part)
		end
	end

	return nil
end

local function persistedToolExtent(tool)
	if not (tool and tool:IsA("Tool")) then
		return nil
	end

	local scale = instanceScale(tool)
	if not scale then
		return nil
	end

	local foodId = Food.IdOf(tool)
	local template = foodId and Food.GetTemplate(foodId)
	local baseExtent = visualExtent(template)
	if not baseExtent then
		return nil
	end

	return baseExtent * scale
end

local function targetEffectExtent(target, host)
	if target:IsA("Tool") then
		return persistedToolExtent(target) or visualExtent(target) or visualExtent(host) or DEFAULT_EFFECT_REFERENCE_EXTENT
	end

	return visualExtent(host) or visualExtent(target) or DEFAULT_EFFECT_REFERENCE_EXTENT
end

local function templateReferenceExtent(template)
	return visualExtent(template) or DEFAULT_EFFECT_REFERENCE_EXTENT
end

local function isUnderVisualFolder(instance)
	local current = instance
	while current do
		if current.Name == FOLDER_NAME then
			return true
		end
		current = current.Parent
	end
	return false
end

local function sourcePartsForOverlay(source)
	if source:IsA("BasePart") then
		return source.Transparency < VISIBLE_TRANSPARENCY_CUTOFF and { source } or {}
	end

	local parts = {}
	for _, descendant in ipairs(source:GetDescendants()) do
		if descendant:IsA("BasePart")
			and descendant.Transparency < VISIBLE_TRANSPARENCY_CUTOFF
			and not isUnderVisualFolder(descendant) then
			parts[#parts + 1] = descendant
		end
	end
	return parts
end

-- Structural only (part count), deliberately not sizes: growing patch fruit is
-- rescaled every XP tick by PatchSlotVisuals, and keying the render on extent
-- made each tick tear down and rebuild the emitters, visibly wiping all live
-- particles. Size changes are tracked in place by applyEffectScale instead.
local function overlayGeometrySignature(source)
	return tostring(#sourcePartsForOverlay(source))
end

local function setLocalMutationVisual(instance)
	instance:SetAttribute(State.TreeClicker.LocalVisual, true)
	instance:SetAttribute(State.Food.Id, nil)
	instance:SetAttribute(State.Food.Type, nil)
	instance:SetAttribute(State.Food.XP, nil)
	instance:SetAttribute(State.Food.MutationIds, nil)
	instance:SetAttribute(State.Food.PrimaryMutationId, nil)
	instance:SetAttribute(State.TreeClicker.GroundPile, nil)
end

local function stripOverlayPartDescendant(descendant)
	if descendant:IsA("SpecialMesh") then
		descendant.TextureId = ""
		return
	end
	if descendant:IsA("Decal")
		or descendant:IsA("Texture")
		or descendant:IsA("SurfaceAppearance")
		-- Client-local billboards (tool XP badges, fruit pile XP) ride inside
		-- the cloned host and would render as frozen duplicates.
		or descendant:IsA("BillboardGui")
		or descendant:IsA("SurfaceGui")
		or descendant:IsA("ParticleEmitter")
		or descendant:IsA("Beam")
		or descendant:IsA("Trail")
		or descendant:IsA("Fire")
		or descendant:IsA("Smoke")
		or descendant:IsA("Sparkles")
		or descendant:IsA("PointLight")
		or descendant:IsA("SpotLight")
		or descendant:IsA("SurfaceLight")
		or descendant:IsA("Highlight")
		or descendant:IsA("ClickDetector")
		or descendant:IsA("ProximityPrompt")
		or descendant:IsA("Attachment")
		or descendant:IsA("WeldConstraint")
		or descendant:IsA("Constraint")
		or descendant:IsA("JointInstance")
		or descendant:IsA("Script")
		or descendant:IsA("LocalScript")
		or descendant:IsA("ModuleScript") then
		descendant:Destroy()
	end
end

local function configureOverlayPart(part, color)
	setLocalMutationVisual(part)
	part.Material = Enum.Material.ForceField
	part.Color = color
	part.Transparency = OVERLAY_TRANSPARENCY
	part.CastShadow = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = false

	if part:IsA("MeshPart") then
		part.TextureID = ""
	end

	for _, descendant in ipairs(part:GetDescendants()) do
		stripOverlayPartDescendant(descendant)
	end
end

local function cloneForOverlay(source)
	local ok, clone = pcall(function()
		return source:Clone()
	end)
	if not ok or not clone then
		return nil
	end

	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant.Name == FOLDER_NAME then
			descendant:Destroy()
		end
	end
	return clone
end

-- Every overlay part is outset about its own centre and left on the source's
-- own CFrame. Scaling the clone about the model pivot instead (ScaleTo, or the
-- equivalent by hand) displaced each part by its distance from that pivot, so
-- on a tall multi-part food at high scale the shell visibly came apart from the
-- geometry. Sitting the clone exactly on the source also makes the weld offset
-- zero, so the shell can never drift as the food moves or grows.
local function fitOverlayPart(sourcePart, clonePart, margin)
	clonePart.CFrame = sourcePart.CFrame
	clonePart.Size = overlayPartSize(sourcePart, margin)

	-- A SpecialMesh set to FileMesh renders from Scale alone and ignores the
	-- part Size we just grew, so it needs the equivalent multiplier (the part
	-- size stands in for the mesh's own bounds). Every other MeshType renders
	-- as Size * Scale, where the Size outset above is already the whole job --
	-- touching Scale as well used to double-apply it.
	local mesh = clonePart:FindFirstChildWhichIsA("SpecialMesh")
	if mesh and mesh.MeshType == Enum.MeshType.FileMesh then
		local extent = maxDimension(sourcePart.Size)
		if finitePositiveNumber(extent) then
			mesh.Scale *= 1 + (margin * 2) / extent
		end
	end
end

local function overlayColorFor(primaryMutationId)
	local color = Mutations.DisplayColors and Mutations.DisplayColors[primaryMutationId]
	if typeof(color) == "Color3" then
		return color
	end

	color = Mutations.DisplayColor(primaryMutationId)
	if typeof(color) == "Color3" then
		return color
	end

	return OVERLAY_COLOR
end

local function createForceFieldOverlay(source, folder, primaryMutationId, margin)
	local sourceParts = sourcePartsForOverlay(source)
	if #sourceParts == 0 then
		return nil
	end

	local clone = cloneForOverlay(source)
	if not clone then
		return nil
	end

	local cloneParts = sourcePartsForOverlay(clone)
	if #cloneParts ~= #sourceParts then
		clone:Destroy()
		return nil
	end

	local overlay = Instance.new("Model")
	overlay.Name = OVERLAY_NAME
	setLocalMutationVisual(overlay)
	overlay.Parent = folder

	local color = overlayColorFor(primaryMutationId)
	local overlayPairs = table.create(#cloneParts)
	for index, clonePart in ipairs(cloneParts) do
		local sourcePart = sourceParts[index]
		fitOverlayPart(sourcePart, clonePart, margin)
		configureOverlayPart(clonePart, color)
		clonePart.Name = sourcePart.Name .. "_MutationOverlay"
		clonePart.Parent = overlay

		local weld = Instance.new("WeldConstraint")
		weld.Name = "MutationOverlayWeld"
		weld.Part0 = sourcePart
		weld.Part1 = clonePart
		weld.Parent = clonePart
		overlayPairs[index] = { source = sourcePart, clone = clonePart }
	end

	if not clone:IsA("BasePart") then
		clone:Destroy()
	end
	return overlay, overlayPairs
end

local function registerScalableEmitters(record, root, referenceExtent)
	referenceExtent = finitePositiveNumber(referenceExtent) and referenceExtent or DEFAULT_EFFECT_REFERENCE_EXTENT
	local function addEmitter(emitter)
		record.scaledEmitters[#record.scaledEmitters + 1] = {
			emitter = emitter,
			size = emitter.Size,
			speed = emitter.Speed,
			acceleration = emitter.Acceleration,
			referenceExtent = referenceExtent,
		}
	end

	if root:IsA("ParticleEmitter") then
		addEmitter(root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			addEmitter(descendant)
		end
	end
end

-- Re-derives every shell size from its source, and is the sole authority on it.
-- Both host kinds need this: BasePart hosts resize via Size tweens the welded
-- clone does not follow, and Model hosts growing via ScaleTo multiply the clone
-- sizes, which would compound the additive margin. Only Size is touched --
-- the clone sits at zero weld offset, so it tracks position for free, and
-- resizing about a part's centre leaves its origin (and that offset) alone.
local function syncOverlayPartSizes(record, extent)
	local overlayPairs = record.overlayPairs
	if not overlayPairs then
		return
	end
	local margin = overlayMarginFor(extent)
	for index = #overlayPairs, 1, -1 do
		local entry = overlayPairs[index]
		if entry.source.Parent and entry.clone.Parent then
			local desired = overlayPartSize(entry.source, margin)
			if (entry.clone.Size - desired).Magnitude > EFFECT_EXTENT_EPSILON then
				entry.clone.Size = desired
			end
		else
			table.remove(overlayPairs, index)
		end
	end
end

local function applyEffectScale(record)
	local extent = targetEffectExtent(record.target, record.host)
	if record.effectExtent and math.abs(record.effectExtent - extent) < EFFECT_EXTENT_EPSILON then
		return
	end
	record.effectExtent = extent

	syncOverlayPartSizes(record, extent)

	for index = #record.scaledEmitters, 1, -1 do
		local entry = record.scaledEmitters[index]
		local emitter = entry.emitter
		if emitter and emitter.Parent then
			local referenceExtent = finitePositiveNumber(entry.referenceExtent)
				and entry.referenceExtent
				or DEFAULT_EFFECT_REFERENCE_EXTENT
			local scale = math.clamp(extent / referenceExtent, MIN_EFFECT_SCALE, MAX_EFFECT_SCALE) * EFFECT_SCALE_MULTIPLIER
			emitter.Size = scaledNumberSequence(entry.size, scale)
			-- ScaleTo on a growing host also multiplies emitter Speed and
			-- Acceleration; pin them to the template values the effect was
			-- tuned with.
			emitter.Speed = entry.speed
			emitter.Acceleration = entry.acceleration
		else
			table.remove(record.scaledEmitters, index)
		end
	end
end

local function enablePersistentParticles(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
		end
	end
end

local function isInsideTemplatePart(descendant, template)
	local current = descendant.Parent
	while current and current ~= template do
		if current:IsA("BasePart") then
			return true
		end
		current = current.Parent
	end
	return false
end

-- Template parts (e.g. Aqua's drip pad) become a surface effect sized to the
-- food: X/Z stretched to the primary part's footprint, seated flush on top.
local function clonePartVisual(descendant, folder, targetPart)
	local part = descendant:Clone()
	setLocalMutationVisual(part)
	part.Size = Vector3.new(targetPart.Size.X, part.Size.Y, targetPart.Size.Z)
	part.CFrame = targetPart.CFrame * CFrame.new(0, (targetPart.Size.Y + part.Size.Y) / 2, 0)
	part.Anchored = targetPart.Anchored
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false

	local weld = Instance.new("WeldConstraint")
	weld.Name = "MutationPartWeld"
	weld.Part0 = targetPart
	weld.Part1 = part
	weld.Parent = part

	part.Parent = folder
	return part
end

local function cloneVisualDescendant(descendant, host, folder, targetPart)
	if descendant:IsA("BasePart") and targetPart then
		return clonePartVisual(descendant, folder, targetPart)
	end
	if descendant:IsA("Attachment") and targetPart then
		local attachment = descendant:Clone()
		attachment.Parent = targetPart
		return attachment
	end
	if descendant:IsA("ParticleEmitter") and targetPart and not descendant.Parent:IsA("Attachment") then
		local attachment = Instance.new("Attachment")
		attachment.Name = descendant.Name .. "Attachment"
		attachment.Parent = targetPart
		descendant:Clone().Parent = attachment
		return attachment
	end
	return nil
end

local function render(record)
	local target = record.target
	if not target then
		return false
	end

	local mutationIds = Mutations.FromInstance(target)
	local primaryMutationId = Mutations.PrimaryFromInstance(target)
	local host = hostFor(target)
	local targetPart = firstBasePart(host)
	local key = table.concat(mutationIds, ",")
		.. "|"
		.. tostring(primaryMutationId)
		.. "|"
		.. tostring(host)
		.. "|"
		.. tostring(targetPart)
		.. "|"
		.. overlayGeometrySignature(host)
	if not target:IsDescendantOf(Workspace) then
		clearRecord(record)
		record.renderKey = "not-in-world|" .. tostring(host)
		record.host = host
		return target.Parent ~= nil
	end
	if #mutationIds == 0 or not targetPart then
		clearRecord(record)
		record.renderKey = key
		record.host = host
		return true
	end
	if not inVisualRange(targetPart) then
		clearRecord(record)
		record.renderKey = "out-of-range|" .. tostring(host)
		record.host = host
		return true
	end
	if record.renderKey == key and record.host == host then
		applyEffectScale(record)
		return true
	end

	clearRecord(record)

	local folder = visualFolder(record, host)
	local margin = overlayMarginFor(targetEffectExtent(target, host))
	local overlay, overlayPairs = createForceFieldOverlay(host, folder, primaryMutationId, margin)
	record.overlayPairs = overlayPairs
	if overlay and #mutationIds >= 2 then
		local overlayParts = {}
		for _, part in ipairs(overlay:GetChildren()) do
			if part:IsA("BasePart") then
				overlayParts[#overlayParts + 1] = part
			end
		end
		local overlayColors = table.create(#mutationIds)
		for index, mutationId in ipairs(mutationIds) do
			overlayColors[index] = overlayColorFor(mutationId)
		end
		record.overlayParts = overlayParts
		record.overlayColors = overlayColors
	end
	for _, mutationId in ipairs(mutationIds) do
		local template = Mutations.Template(mutationId)
		if template then
			local referenceExtent = templateReferenceExtent(template)
			for _, descendant in ipairs(template:GetDescendants()) do
				-- Descendants of a template part ride along with its clone.
				if not isInsideTemplatePart(descendant, template) then
					local clone = cloneVisualDescendant(descendant, host, folder, targetPart)
					if clone then
						clone.Name = mutationId .. "_" .. clone.Name
						record.extras[#record.extras + 1] = clone
						registerScalableEmitters(record, clone, referenceExtent)
						enablePersistentParticles(clone)
					end
				end
			end
		end
	end
	record.renderKey = key
	record.host = host
	applyEffectScale(record)
	return true
end

local function cleanup(target)
	local record = tracked[target]
	if not record then
		return
	end
	for _, conn in ipairs(record.connections) do
		conn:Disconnect()
	end
	clearRecord(record)
	tracked[target] = nil
end

local function track(target)
	if tracked[target] or not isFoodCandidate(target) then
		return
	end
	local record = {
		target = target,
		connections = {},
		extras = {},
		scaledEmitters = {},
		effectExtent = nil,
		folder = nil,
		renderKey = nil,
		host = nil,
		overlayPairs = nil,
	}
	tracked[target] = record
	table.insert(record.connections, RuntimeGuard.Connect(target:GetAttributeChangedSignal(State.Food.MutationIds), "MutationVisuals.MutationChanged", function()
		render(record)
	end))
	table.insert(record.connections, RuntimeGuard.Connect(target.AncestryChanged, "MutationVisuals.AncestryChanged", function()
		if target.Parent == nil then
			cleanup(target)
		else
			render(record)
		end
	end))
	render(record)
end

local function scanRoot(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if isFoodCandidate(descendant) then
			track(descendant)
		end
	end
end

local function watchContainer(container, label)
	if not container then
		return nil
	end
	scanRoot(container)
	return RuntimeGuard.Connect(container.DescendantAdded, label .. ".DescendantAdded", function(descendant)
		if isFoodCandidate(descendant) then
			track(descendant)
		end
	end)
end

function MutationVisuals.start()
	PlotScope.Bind({
		label = "MutationVisuals",
		nearbyRange = SCOPE_RANGE,
		onPlotAdded = function(plot)
			scanRoot(plot)
			local conn = RuntimeGuard.Connect(plot.DescendantAdded, "MutationVisuals.DescendantAdded", function(descendant)
				if isFoodCandidate(descendant) then
					track(descendant)
				end
			end)
			return function()
				if conn then
					conn:Disconnect()
				end
				for target in pairs(tracked) do
					if target:IsDescendantOf(plot) then
						cleanup(target)
					end
				end
			end
		end,
	})

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		watchContainer(backpack, "MutationVisuals.Backpack")
	end

	local characterConnection = nil
	local function bindCharacter(character)
		if characterConnection then
			characterConnection:Disconnect()
			characterConnection = nil
		end
		characterConnection = watchContainer(character, "MutationVisuals.Character")
	end
	if player.Character then
		bindCharacter(player.Character)
	end
	RuntimeGuard.Connect(player.CharacterAdded, "MutationVisuals.CharacterAdded", bindCharacter)

	local elapsed = 0
	RuntimeGuard.Connect(RunService.Heartbeat, "MutationVisuals.Refresh", function(dt)
		elapsed += dt
		if elapsed < REFRESH_SECONDS then
			return
		end
		elapsed = 0
		for target, record in pairs(tracked) do
			if not render(record) then
				cleanup(target)
			end
		end
	end)

	-- Stacked-mutation overlays cycle between their mutation colors like an
	-- alternating gradient; single-mutation overlays keep their static color.
	RuntimeGuard.Connect(RunService.Heartbeat, "MutationVisuals.OverlayGradient", function()
		local phase = os.clock() / GRADIENT_CYCLE_SECONDS
		for _, record in pairs(tracked) do
			local colors = record.overlayColors
			local parts = record.overlayParts
			if colors and parts then
				local count = #colors
				local fromIndex = math.floor(phase) % count + 1
				local toIndex = fromIndex % count + 1
				local alpha = phase % 1
				alpha = alpha * alpha * (3 - 2 * alpha)
				local color = colors[fromIndex]:Lerp(colors[toIndex], alpha)
				for index = #parts, 1, -1 do
					local part = parts[index]
					if part.Parent then
						part.Color = color
					else
						table.remove(parts, index)
					end
				end
			end
		end
	end)
end

function MutationVisuals.VisibleMutatedCrops()
	local crops = {}
	for target in pairs(tracked) do
		if not target:IsA("Tool") and target:IsDescendantOf(Workspace) then
			local mutationIds = Mutations.FromInstance(target)
			if #mutationIds > 0 then
				local part = firstBasePart(hostFor(target))
				if part then
					crops[#crops + 1] = {
						target = target,
						part = part,
						mutationIds = mutationIds,
					}
				end
			end
		end
	end
	return crops
end

return MutationVisuals
