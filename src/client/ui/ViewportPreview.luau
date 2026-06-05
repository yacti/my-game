local RunService = game:GetService("RunService")

local ViewportPreview = {}

local PREVIEW_SCALE = 1.25
local PET_TARGET_MAX_DIMENSION = 5
local PET_VIEWPORT_ZOOM = 2.2
local ROTATION_SECONDS = 12
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
	anchor(clone)
	options = type(options) == "table" and options or {}
	scalePreview(clone, options.targetMaxDimension)
	clone.Parent = world
	local size = centerAtOrigin(clone)
	local rig = makeRotationRig(world, clone)

	local camera = Instance.new("Camera")
	local radius = math.max(size.X, size.Y, size.Z, 1)
	local zoom = math.max(tonumber(options.zoom) or 1, 0.01)
	local distance = (radius * 1.25 + 2.5) / zoom
	camera.CFrame = CFrame.new(Vector3.new(distance, distance * 0.45, distance), Vector3.new())
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.Ambient = Color3.fromRGB(180, 180, 180)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.35)
	startRotation(viewport, rig)
	return true
end

ViewportPreview.PET_TARGET_MAX_DIMENSION = PET_TARGET_MAX_DIMENSION
ViewportPreview.PET_VIEWPORT_ZOOM = PET_VIEWPORT_ZOOM

return ViewportPreview
