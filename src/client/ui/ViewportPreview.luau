local RunService = game:GetService("RunService")

local ViewportPreview = {}

local PREVIEW_SCALE = 1.25
local PET_TARGET_MAX_DIMENSION = 5
local PET_VIEWPORT_ZOOM = 2.2
local ROTATION_SECONDS = 12
local DEFAULT_SWAY_PERIOD_SECONDS = 2.6
local VIEWPORT_AMBIENT = Color3.fromRGB(255, 255, 255)
local VIEWPORT_LIGHT_COLOR = Color3.fromRGB(185, 185, 185)
local VIEWPORT_LIGHT_DIRECTION = Vector3.new(-1, -1, -1)
local TAU = math.pi * 2
local previewRecords = setmetatable({}, { __mode = "k" })

local function disconnect(viewport)
	local record = previewRecords[viewport]
	if record then
		if record.motion then
			record.motion:Disconnect()
		end
		if record.track then
			pcall(function()
				record.track:Stop(0)
				record.track:Destroy()
			end)
		end
		if record.animation then
			record.animation:Destroy()
		end
		previewRecords[viewport] = nil
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

local function multiplyPresentationScale(instance, multiplier)
	multiplier = math.max(tonumber(multiplier) or 1, 0.01)
	if multiplier == 1 then
		return
	end
	if instance:IsA("Model") then
		instance:ScaleTo(instance:GetScale() * multiplier)
	elseif instance:IsA("BasePart") then
		instance.Size *= multiplier
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

local function startRotation(viewport, instance, yawDegrees)
	local angle = math.rad(tonumber(yawDegrees) or 0)
	local record = previewRecords[viewport] or {}
	previewRecords[viewport] = record
	record.motion = RunService.RenderStepped:Connect(function(deltaTime)
		if not (viewport.Parent and instance.Parent) then
			disconnect(viewport)
			return
		end

		angle = (angle + (tonumber(deltaTime) or 0) * TAU / ROTATION_SECONDS) % TAU
		pivotPreview(instance, CFrame.Angles(0, angle, 0))
	end)
end

local function startSway(viewport, instance, yawDegrees, swayDegrees, periodSeconds)
	local baseAngle = math.rad(tonumber(yawDegrees) or 0)
	local amplitude = math.rad(math.abs(tonumber(swayDegrees) or 0))
	local period = math.max(tonumber(periodSeconds) or DEFAULT_SWAY_PERIOD_SECONDS, 0.1)
	local elapsed = 0
	pivotPreview(instance, CFrame.Angles(0, baseAngle, 0))

	local record = previewRecords[viewport] or {}
	previewRecords[viewport] = record
	record.motion = RunService.RenderStepped:Connect(function(deltaTime)
		if not (viewport.Parent and instance.Parent) then
			disconnect(viewport)
			return
		end

		elapsed += tonumber(deltaTime) or 0
		local angle = baseAngle + math.sin(elapsed * TAU / period) * amplitude
		pivotPreview(instance, CFrame.Angles(0, angle, 0))
	end)
end

local function startIdleAnimation(viewport, instance, animationId)
	if type(animationId) ~= "string" or not animationId:match("^rbxassetid://%d+$") then
		return
	end
	local animator = instance:FindFirstChildWhichIsA("Animator", true)
	if not animator then
		return
	end
	local animation = Instance.new("Animation")
	animation.Name = "ViewportIdleAnimation"
	animation.AnimationId = animationId
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		animation:Destroy()
		warn("[ViewportPreview] Failed to load idle animation " .. animationId .. ": " .. tostring(track))
		return
	end
	track.Looped = true
	track:Play(0)
	local record = previewRecords[viewport] or {}
	previewRecords[viewport] = record
	record.animation = animation
	record.track = track
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
	multiplyPresentationScale(clone, options.presentationScale)
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
	startIdleAnimation(viewport, clone, options.idleAnimationId)

	local camera = Instance.new("Camera")
	local radius = math.max(size.X, size.Y, size.Z, 1)
	local zoom = math.max(tonumber(options.zoom) or 1, 0.01)
	local distance = (radius * 1.25 + 2.5) / zoom

	-- fitPadding: frame by the model's bounding SPHERE instead of the zoom
	-- heuristic above, so the model is as large as it can be without ever
	-- touching an edge. fitPadding is the margin (1.06 = 6% clear).
	--
	-- Worth the separate path because the zoom heuristic only accounts for the
	-- largest AXIS, while the camera sits on a diagonal and the model spins --
	-- so what actually has to fit is the diagonal, and a chunky model clips at
	-- a zoom that framed a slim one perfectly. A sphere is rotation-invariant,
	-- which makes this both clip-proof and genuinely normalising: every model
	-- subtends the same angle, so a mushroom and a fruit tree render the same
	-- on-screen size regardless of their real proportions.
	--
	-- Opt-in, so every existing caller keeps the framing it was tuned against.
	-- cameraHeightFactor: camera elevation as a fraction of its distance
	-- (default looks slightly down; 0 = level with the model).
	local heightFactor = tonumber(options.cameraHeightFactor) or 0.45

	local fitPadding = tonumber(options.fitPadding)
	if fitPadding and fitPadding > 0 then
		local sphereRadius = math.max(size.Magnitude * 0.5, 0.01)
		local halfFov = math.rad(camera.FieldOfView) * 0.5
		-- FieldOfView is vertical; a viewport taller than it is wide has a
		-- narrower horizontal field, and that is then the binding constraint.
		-- AbsoluteSize is 0 while the panel is still hidden, in which case
		-- assuming square is the safe read (it can only over-shrink, and only
		-- for a viewport that is wider than tall).
		local absolute = viewport.AbsoluteSize
		local aspect = (absolute.Y > 0) and (absolute.X / absolute.Y) or 1
		if aspect < 1 then
			halfFov = math.atan(math.tan(halfFov) * aspect)
		end
		local eyeDistance = sphereRadius / math.sin(halfFov) * fitPadding
		-- `distance` is a per-axis COMPONENT, not the eye distance: the camera
		-- is placed at (d, d*heightFactor, d), which sits sqrt(2 + h^2) times
		-- further out than d. Solve for the component that lands the eye at
		-- eyeDistance, or the model renders about a third smaller than asked.
		distance = eyeDistance / math.sqrt(2 + heightFactor * heightFactor)
	end
	camera.CFrame = CFrame.new(Vector3.new(distance, distance * heightFactor, distance), Vector3.new())
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.Ambient = typeof(options.ambient) == "Color3" and options.ambient or VIEWPORT_AMBIENT
	viewport.LightColor = typeof(options.lightColor) == "Color3" and options.lightColor or VIEWPORT_LIGHT_COLOR
	viewport.LightDirection = typeof(options.lightDirection) == "Vector3" and options.lightDirection or VIEWPORT_LIGHT_DIRECTION
	if type(options.swayDegrees) == "number" and options.swayDegrees ~= 0 then
		startSway(viewport, rig, options.yawDegrees, options.swayDegrees, options.swayPeriodSeconds)
	elseif options.rotate == false then
		-- Static preview: hold a fixed orientation (yawDegrees) instead of the
		-- default turntable spin.
		pivotPreview(rig, CFrame.Angles(0, math.rad(tonumber(options.yawDegrees) or 0), 0))
	else
		startRotation(viewport, rig, options.yawDegrees)
	end
	return true
end

ViewportPreview.PET_TARGET_MAX_DIMENSION = PET_TARGET_MAX_DIMENSION
ViewportPreview.PET_VIEWPORT_ZOOM = PET_VIEWPORT_ZOOM

return ViewportPreview
