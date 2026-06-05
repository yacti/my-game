local RunService = game:GetService("RunService")

local ViewportPreview = {}

local PREVIEW_SCALE = 1.25
local ROTATION_SECONDS = 12
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

local function scalePreview(instance)
	if instance:IsA("Model") then
		instance:ScaleTo(PREVIEW_SCALE)
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

local function startRotation(viewport, instance)
	local startedAt = os.clock()
	rotationConnections[viewport] = RunService.RenderStepped:Connect(function()
		if not (viewport.Parent and instance.Parent) then
			disconnect(viewport)
			return
		end

		local alpha = ((os.clock() - startedAt) / ROTATION_SECONDS) % 1
		pivotPreview(instance, CFrame.Angles(0, alpha * math.pi * 2, 0))
	end)
end

function ViewportPreview.Render(viewport, template)
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
	scalePreview(clone)
	clone.Parent = world

	local size = Vector3.new(4, 4, 4)
	if clone:IsA("Model") then
		local _, bounds = clone:GetBoundingBox()
		size = bounds
	elseif clone:IsA("BasePart") then
		size = clone.Size
	end
	pivotPreview(clone, CFrame.new())

	local camera = Instance.new("Camera")
	local radius = math.max(size.X, size.Y, size.Z, 1)
	local distance = radius * 1.25 + 2.5
	camera.CFrame = CFrame.new(Vector3.new(distance, distance * 0.45, distance), Vector3.new())
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.Ambient = Color3.fromRGB(180, 180, 180)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.35)
	startRotation(viewport, clone)
	return true
end

return ViewportPreview
