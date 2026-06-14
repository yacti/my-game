local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local ResponsiveUi = {}

local BASE_SHORT_SIDE = 853
local MIN_DIVISOR = 1
local MAX_DIVISOR = 3
local BASE_THICKNESS_ATTR = "ResponsiveUiBaseThickness"
local IGNORE_ATTR = "ResponsiveUiIgnore"

local rootRecords = {}
local currentCamera = nil
local cameraViewportConnection = nil
local cameraChangedConnection = nil
local cleanupRoot = nil

local function disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

local function viewportSize()
	local camera = Workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(BASE_SHORT_SIDE, BASE_SHORT_SIDE)
end

local function strokeDivisorFor(viewport)
	local shortSide = math.min(viewport.X, viewport.Y)
	if type(shortSide) ~= "number" or shortSide <= 0 then
		return MIN_DIVISOR
	end

	local rawDivisor = BASE_SHORT_SIDE / shortSide
	return math.clamp(math.round(rawDivisor * 2) / 2, MIN_DIVISOR, MAX_DIVISOR)
end

local function isScalableStroke(instance)
	return instance
		and instance:IsA("UIStroke")
		and instance:GetAttribute(IGNORE_ATTR) ~= true
		and instance.StrokeSizingMode == Enum.StrokeSizingMode.FixedSize
end

local function applyStroke(stroke, divisor)
	if not isScalableStroke(stroke) then
		return
	end

	local baseThickness = stroke:GetAttribute(BASE_THICKNESS_ATTR)
	if type(baseThickness) ~= "number" then
		baseThickness = stroke.Thickness
		stroke:SetAttribute(BASE_THICKNESS_ATTR, baseThickness)
	end

	if baseThickness <= 0 then
		stroke.Thickness = 0
	else
		stroke.Thickness = math.max(1, baseThickness / divisor)
	end
end

local function updateRoot(record)
	if not (record.root and record.root.Parent) then
		return
	end

	local divisor = strokeDivisorFor(viewportSize())
	if isScalableStroke(record.root) then
		applyStroke(record.root, divisor)
	end
	for _, descendant in ipairs(record.root:GetDescendants()) do
		if descendant:IsA("UIStroke") then
			applyStroke(descendant, divisor)
		end
	end
end

local function updateAll()
	for root, record in pairs(rootRecords) do
		if root.Parent then
			updateRoot(record)
		else
			cleanupRoot(root)
		end
	end
end

local function bindCurrentCamera()
	local camera = Workspace.CurrentCamera
	if currentCamera == camera and cameraViewportConnection then
		return
	end

	disconnect(cameraViewportConnection)
	cameraViewportConnection = nil
	currentCamera = camera

	if currentCamera then
		cameraViewportConnection = RuntimeGuard.Connect(
			currentCamera:GetPropertyChangedSignal("ViewportSize"),
			"ResponsiveUi.CameraViewportSize",
			updateAll
		)
	end

	updateAll()
end

local function ensureCameraWatcher()
	if not cameraChangedConnection then
		cameraChangedConnection = RuntimeGuard.Connect(
			Workspace:GetPropertyChangedSignal("CurrentCamera"),
			"ResponsiveUi.CurrentCameraChanged",
			bindCurrentCamera
		)
	end
	bindCurrentCamera()
end

cleanupRoot = function(root)
	local record = rootRecords[root]
	if not record then
		return
	end

	for _, connection in ipairs(record.connections) do
		disconnect(connection)
	end
	rootRecords[root] = nil
end

function ResponsiveUi.BindRoot(root)
	if not root or rootRecords[root] then
		return
	end

	local record = {
		root = root,
		connections = {},
	}
	rootRecords[root] = record

	record.connections[#record.connections + 1] = RuntimeGuard.Connect(
		root.DescendantAdded,
		"ResponsiveUi.DescendantAdded",
		function(descendant)
			if descendant:IsA("UIStroke") then
				applyStroke(descendant, strokeDivisorFor(viewportSize()))
			end
		end
	)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(root.Destroying, "ResponsiveUi.RootDestroying", function()
		cleanupRoot(root)
	end)

	ensureCameraWatcher()
	updateRoot(record)
end

return ResponsiveUi
