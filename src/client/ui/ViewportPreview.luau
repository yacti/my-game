local RunService = game:GetService("RunService")

local ViewportPreview = {}

local PREVIEW_SCALE = 1.25
local PET_TARGET_MAX_DIMENSION = 5
local PET_VIEWPORT_ZOOM = 2.2
local ROTATION_SECONDS = 12
local VIEWPORT_AMBIENT = Color3.fromRGB(255, 255, 255)
local VIEWPORT_LIGHT_COLOR = Color3.fromRGB(185, 185, 185)
local VIEWPORT_LIGHT_DIRECTION = Vector3.new(-1, -1, -1)
local TAU = math.pi * 2
local rotationConnections = setmetatable({}, { __mode = "k" })

local function disconnect(viewport)
	local connection = rotationConnections[viewport]
	if connection then
		connection:Disconnect()
		rotationConnections[viewport] = nil
	end
end

local function clear(viewport)
	disconnect(viewport)
	for _, child in ipairs(viewport:GetChildren()) do
		child:Destroy()
	end
	viewport.CurrentCamera = nil
end

local function anchor(instance)
	if instance:IsA("BasePart") then
		instance.Anchored = true
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
end

local function boostedColor(color, saturationMultiplier, brightnessMultiplier)
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(
		h,
		math.clamp(s * saturationMultiplier, 0, 1),
		math.clamp(v * brightnessMultiplier, 0, 1)
	)
end

local function boostedColorSequence(sequence, saturationMultiplier, brightnessMultiplier)
	local keypoints = {}
	for _, keypoint in ipairs(sequence.Keypoints) do
		keypoints[#keypoints + 1] = ColorSequenceKeypoint.new(
			keypoint.Time,
			boostedColor(keypoint.Value, saturationMultiplier, brightnessMultiplier)
		)
	end
	return ColorSequence.new(keypoints)
end

local function applyColorBoost(instance, options)
	local saturationMultiplier = math.max(tonumber(options.colorSaturation) or 1, 0)
	local brightnessMultiplier = math.max(tonumber(options.colorBrightness) or 1, 0)
	if saturationMultiplier == 1 and brightnessMultiplier == 1 then
		return
	end

	local function apply(item)
		if item:IsA("BasePart") then
			item.Color = boostedColor(item.Color, saturationMultiplier, brightnessMultiplier)
		elseif item:IsA("Decal") then
			item.Color3 = boostedColor(item.Color3, saturationMultiplier, brightnessMultiplier)
		elseif item:IsA("ParticleEmitter") or item:IsA("Beam") or item:IsA("Trail") then
			item.Color = boostedColorSequence(item.Color, saturationMultiplier, brightnessMultiplier)
		end
	end

	apply(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		apply(descendant)
	end
end

local function boundsSize(instance)
	if instance:IsA("Model") then
		local _, size = instance:GetBoundingBox()
		return size
	elseif instance:IsA("BasePart") then
		return instance.Size
	end
	return Vector3.new(0, 0, 0)
end

local function maxDimension(size)
	return math.max(size.X, size.Y, size.Z)
end

local function scalePreview(instance, targetMaxDimension)
	local target = tonumber(targetMaxDimension)
	if type(target) == "number" and target > 0 then
		local currentMax = maxDimension(boundsSize(instance))
		if currentMax > 0 then
			local factor = target / currentMax
			if instance:IsA("Model") then
				instance:ScaleTo(instance:GetScale() * factor)
			elseif instance:IsA("BasePart") then
				instance.Size *= factor
			end
		end
		return
	end

	if instance:IsA("Model") then
		instance:ScaleTo(instance:GetScale() * PREVIEW_SCALE)
	elseif instance:IsA("BasePart") then
		instance.Size *= PREVIEW_SCALE
	end
end

local function pivotPreview(instance, cframe)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function translatePreview(instance, offset)
	if instance:IsA("Model") then
		instance:PivotTo(instance:GetPivot() + offset)
	elseif instance:IsA("BasePart") then
		instance.CFrame += offset
	end
end

local function centerAtOrigin(instance)
	if instance:IsA("Model") then
		local boundsCF, boundsSize = instance:GetBoundingBox()
		local centerOffset = -boundsCF.Position
		instance:PivotTo(instance:GetPivot() + centerOffset)
		return boundsSize
	elseif instance:IsA("BasePart") then
		instance.CFrame = CFrame.new()
		return instance.Size
	end
	return Vector3.new(4, 4, 4)
end

local function makeRotationRig(world, clone)
	local rig = Instance.new("Model")
	rig.Name = "ViewportRig"
	rig.Parent = world

	local center = Instance.new("Part")
	center.Name = "ViewportCenter"
	center.Anchored = true
	center.CanCollide = false
	center.CanQuery = false
	center.CanTouch = false
	center.Transparency = 1
	center.Size = Vector3.new(0.05, 0.05, 0.05)
	center.CFrame = CFrame.new()
	center.Parent = rig
	rig.PrimaryPart = center

	clone.Parent = rig
	rig:PivotTo(CFrame.new())
	return rig
end

local function startRotation(viewport, instance)
	local angle = 0
	rotationConnections[viewport] = RunService.RenderStepped:Connect(function(deltaTime)
		if not (viewport.Parent and instance.Parent) then
			disconnect(viewport)
			return
		end

		angle = (angle + (tonumber(deltaTime) or 0) * TAU / ROTATION_SECONDS) % TAU
		pivotPreview(instance, CFrame.Angles(0, angle, 0))
	end)
end

function ViewportPreview.Render(viewport, template, options)
	if not (viewport and viewport:IsA("ViewportFrame")) then
		return false
	end
	clear(viewport)
	if not (template and (template:IsA("Model") or template:IsA("BasePart"))) then
		return false
	end

	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local clone = template:Clone()
	options = type(options) == "table" and options or {}
	anchor(clone)
	if options.alignPivot then
		-- Strip the template's stored world rotation so every model faces its
		-- own pivot forward (-Z) before yaw/camera framing; templates are saved
		-- with inconsistent rotations.
		pivotPreview(clone, CFrame.new(clone:GetPivot().Position))
	end
	applyColorBoost(clone, options)
	scalePreview(clone, options.targetMaxDimension)
	clone.Parent = world
	local size = centerAtOrigin(clone)
	-- verticalOffset: studs to lift the model above the camera's aim point,
	-- which raises the preview in the frame (negative drops it). Applied after
	-- centering so the turntable still spins around the model's own axis.
	local verticalOffset = tonumber(options.verticalOffset) or 0
	if verticalOffset ~= 0 then
		translatePreview(clone, Vector3.new(0, verticalOffset, 0))
	end
	local rig = makeRotationRig(world, clone)

	local camera = Instance.new("Camera")
	local radius = math.max(size.X, size.Y, size.Z, 1)
	local zoom = math.max(tonumber(options.zoom) or 1, 0.01)
	local distance = (radius * 1.25 + 2.5) / zoom
	-- cameraHeightFactor: camera elevation as a fraction of its distance
	-- (default looks slightly down; 0 = level with the model).
	local heightFactor = tonumber(options.cameraHeightFactor) or 0.45
	camera.CFrame = CFrame.new(Vector3.new(distance, distance * heightFactor, distance), Vector3.new())
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.Ambient = typeof(options.ambient) == "Color3" and options.ambient or VIEWPORT_AMBIENT
	viewport.LightColor = typeof(options.lightColor) == "Color3" and options.lightColor or VIEWPORT_LIGHT_COLOR
	viewport.LightDirection = typeof(options.lightDirection) == "Vector3" and options.lightDirection or VIEWPORT_LIGHT_DIRECTION
	if options.rotate == false then
		-- Static preview: hold a fixed orientation (yawDegrees) instead of the
		-- default turntable spin.
		pivotPreview(rig, CFrame.Angles(0, math.rad(tonumber(options.yawDegrees) or 0), 0))
	else
		startRotation(viewport, rig)
	end
	return true
end

ViewportPreview.PET_TARGET_MAX_DIMENSION = PET_TARGET_MAX_DIMENSION
ViewportPreview.PET_VIEWPORT_ZOOM = PET_VIEWPORT_ZOOM

return ViewportPreview
