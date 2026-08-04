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
local SPIN_SAMPLES = 48
local SWAY_SAMPLES = 16
local previewRecords = setmetatable({}, { __mode = "k" })

local function disconnect(viewport)
	local record = previewRecords[viewport]
	if record then
		if record.motion then
			record.motion:Disconnect()
		end
		if record.resize then
			record.resize:Disconnect()
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

-- Every corner of every VISIBLE part, in rig space, plus the vertical centre of
-- that set. Fully transparent parts are skipped deliberately: collision shells and
-- hitboxes inflate GetBoundingBox while rendering nothing, and framing a box that
-- is partly invisible is exactly what makes a model come out too small.
local function visibleSilhouette(instance)
	local corners = {}
	local lowest, highest = math.huge, -math.huge

	local function collect(part)
		if not (part:IsA("BasePart") and part.Transparency < 1) then
			return
		end
		local half = part.Size * 0.5
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local corner = part.CFrame * Vector3.new(half.X * x, half.Y * y, half.Z * z)
					corners[#corners + 1] = corner
					lowest = math.min(lowest, corner.Y)
					highest = math.max(highest, corner.Y)
				end
			end
		end
	end

	collect(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		collect(descendant)
	end
	if #corners == 0 then
		return nil, 0
	end
	return corners, (lowest + highest) * 0.5
end

-- AbsoluteSize is 0 until the panel has been laid out once, so assume square
-- there; only the ratio matters to the fit, never the pixel size.
local function viewportAspect(viewport)
	local absolute = viewport.AbsoluteSize
	if absolute.X > 0 and absolute.Y > 0 then
		return absolute.X / absolute.Y
	end
	return 1
end

-- The yaws a preview will actually be held at, which is what the fit has to
-- clear. A turntable passes through all of them, a sway only covers its arc, and
-- a static preview only ever shows one -- fitting a static preview to a full
-- turntable would shrink it to clear angles it never reaches. Mirrors the
-- motion branch at the end of Render.
local function fitYaws(options)
	local base = math.rad(tonumber(options.yawDegrees) or 0)

	if type(options.swayDegrees) == "number" and options.swayDegrees ~= 0 then
		local amplitude = math.rad(math.abs(options.swayDegrees))
		local yaws = {}
		for step = 0, SWAY_SAMPLES do
			yaws[#yaws + 1] = base - amplitude + (amplitude * 2) * step / SWAY_SAMPLES
		end
		return yaws
	end

	if options.rotate == false then
		return { base }
	end

	local yaws = {}
	for step = 0, SPIN_SAMPLES - 1 do
		yaws[#yaws + 1] = step * TAU / SPIN_SAMPLES
	end
	return yaws
end

-- Smallest eye distance that keeps every silhouette corner inside the frame at
-- every yaw the preview reaches. Solved rather than estimated: a corner at
-- camera space (x, y, z) is inside when |x| <= tanX * (eye - z), so it sets a
-- lower bound of z + |x| * padding / tanX (and the same in y), and the answer is
-- the largest bound over every corner and yaw. The model then touches the
-- padding bound on at least one axis, which is as large as it can get without
-- clipping.
local function fitCameraCFrame(camera, corners, yaws, centreY, heightFactor, padding, aspect)
	-- FieldOfView is vertical; the horizontal field follows the viewport's aspect.
	local tanY = math.tan(math.rad(camera.FieldOfView) * 0.5)
	local tanX = tanY * aspect

	local aim = Vector3.new(0, centreY, 0)
	local direction = Vector3.new(1, heightFactor, 1).Unit
	local basis = CFrame.lookAt(aim + direction, aim)

	local eye, nearest = 0, -math.huge
	for _, yaw in ipairs(yaws) do
		local spin = CFrame.Angles(0, yaw, 0)
		for _, corner in ipairs(corners) do
			local view = basis:VectorToObjectSpace(spin * corner - aim)
			nearest = math.max(nearest, view.Z)
			eye = math.max(
				eye,
				view.Z + math.abs(view.X) * padding / tanX,
				view.Z + math.abs(view.Y) * padding / tanY
			)
		end
	end

	-- Never let the camera land inside or on the model.
	eye = math.max(eye, nearest + 0.1, 0.5)
	return CFrame.lookAt(aim + direction * eye, aim)
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

	-- fitPadding: frame by the model's actual projected silhouette instead of the
	-- zoom heuristic above, so it renders as large as it can without touching an
	-- edge. fitPadding is the margin (1.06 = 6% clear).
	--
	-- Worth the separate path because the zoom heuristic only accounts for the
	-- largest AXIS, so a chunky model clips at a zoom that framed a slim one
	-- perfectly. Fitting the silhouette rather than a bounding sphere matters
	-- just as much: a sphere circumscribes the model with room to spare, and how
	-- much room depends on the model's proportions, so sphere-fitting leaves a
	-- flat wide model filling barely 40% of the frame's height while a compact
	-- one fills 60%. Solving the projection instead puts every model hard against
	-- the padding bound.
	--
	-- Opt-in, so every existing caller keeps the framing it was tuned against.
	-- cameraHeightFactor: camera elevation as a fraction of its distance
	-- (default looks slightly down; 0 = level with the model).
	local heightFactor = tonumber(options.cameraHeightFactor) or 0.45

	local fitPadding = tonumber(options.fitPadding)
	local corners, centreY, yaws
	if fitPadding and fitPadding > 0 then
		corners, centreY = visibleSilhouette(clone)
		yaws = fitYaws(options)
	end

	if corners then
		-- The solve only depends on the aspect ratio, so re-run it when that
		-- moves and ignore uniform resizes. It has to be re-run at all because
		-- AbsoluteSize reads 0 while the panel has never been opened, and cards
		-- are built on the merchant's arrival rather than on first open.
		local fittedAspect
		local function refit()
			local aspect = viewportAspect(viewport)
			if fittedAspect and math.abs(aspect - fittedAspect) < 0.001 then
				return
			end
			fittedAspect = aspect
			camera.CFrame = fitCameraCFrame(camera, corners, yaws, centreY, heightFactor, fitPadding, aspect)
		end
		refit()
		local record = previewRecords[viewport] or {}
		previewRecords[viewport] = record
		record.resize = viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	else
		camera.CFrame = CFrame.new(Vector3.new(distance, distance * heightFactor, distance), Vector3.new())
	end
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
