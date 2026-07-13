local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local ResponsiveUi = {}

-- All UI thickness values are authored against a 2100x900 viewport. Template
-- strokes are baked to StrokeSizingMode.ScaledSize (engine scales them with the
-- parent's shortest axis), so this module only converts stragglers created at
-- runtime with FixedSize pixel thickness.
local DESIGN_VIEWPORT = Vector2.new(2100, 900)
local BASE_THICKNESS_ATTR = "ResponsiveUiBaseThickness"
local DESIGN_PX_ATTR = "ResponsiveUiDesignPx"
local IGNORE_ATTR = "ResponsiveUiIgnore"

local rootRecords = {}
local cleanupRoot = nil

local function disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

local function isConvertibleStroke(instance)
	return instance
		and instance:IsA("UIStroke")
		and instance:GetAttribute(IGNORE_ATTR) ~= true
		and instance.StrokeSizingMode == Enum.StrokeSizingMode.FixedSize
end

-- The parent's shortest axis as it would measure on the design viewport. Root
-- insets (topbar etc.) are constant pixels, so the design-time root rect is the
-- design viewport minus the same inset the root currently experiences.
local function designShortAxis(record, guiObject)
	local root = record.root
	local rootAbs = root.AbsoluteSize
	if rootAbs.X <= 0 or rootAbs.Y <= 0 then
		return nil
	end

	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or rootAbs
	local inset = viewport - rootAbs
	local designRoot = DESIGN_VIEWPORT - inset
	if designRoot.X <= 0 or designRoot.Y <= 0 then
		return nil
	end

	local abs = guiObject.AbsoluteSize
	if abs.X <= 0 or abs.Y <= 0 then
		return nil
	end
	return math.min(abs.X * designRoot.X / rootAbs.X, abs.Y * designRoot.Y / rootAbs.Y)
end

local function convertStroke(record, stroke)
	if not isConvertibleStroke(stroke) then
		return true
	end
	local parent = stroke.Parent
	if not (parent and parent:IsA("GuiObject") and parent:IsDescendantOf(record.root)) then
		return true
	end

	local shortAxis = designShortAxis(record, parent)
	if not shortAxis then
		return false
	end

	local basePx = stroke:GetAttribute(BASE_THICKNESS_ATTR)
	if type(basePx) ~= "number" then
		basePx = stroke.Thickness
	end
	stroke:SetAttribute(DESIGN_PX_ATTR, basePx)
	if basePx <= 0 then
		stroke.Thickness = 0
	else
		stroke.Thickness = basePx / shortAxis
	end
	stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
	return true
end

-- Layout may not have resolved yet (parent just built, sizes still zero); retry
-- once the parent's AbsoluteSize settles.
local function convertWhenMeasurable(record, stroke)
	if convertStroke(record, stroke) then
		return
	end

	local parent = stroke.Parent
	local retryConnection
	retryConnection = RuntimeGuard.Connect(
		parent:GetPropertyChangedSignal("AbsoluteSize"),
		"ResponsiveUi.StrokeParentResized",
		function()
			if convertStroke(record, stroke) then
				disconnect(retryConnection)
				record.pendingConnections[stroke] = nil
			end
		end
	)
	record.pendingConnections[stroke] = retryConnection
end

local function convertDescendants(record)
	if not (record.root and record.root.Parent) then
		return
	end
	if record.root:IsA("UIStroke") then
		convertWhenMeasurable(record, record.root)
	end
	for _, descendant in ipairs(record.root:GetDescendants()) do
		if descendant:IsA("UIStroke") then
			convertWhenMeasurable(record, descendant)
		end
	end
end

cleanupRoot = function(root)
	local record = rootRecords[root]
	if not record then
		return
	end

	for _, connection in ipairs(record.connections) do
		disconnect(connection)
	end
	for _, connection in pairs(record.pendingConnections) do
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
		pendingConnections = {},
	}
	rootRecords[root] = record

	record.connections[#record.connections + 1] = RuntimeGuard.Connect(
		root.DescendantAdded,
		"ResponsiveUi.DescendantAdded",
		function(descendant)
			if descendant:IsA("UIStroke") then
				task.defer(function()
					if rootRecords[root] and descendant:IsDescendantOf(root) then
						convertWhenMeasurable(record, descendant)
					end
				end)
			end
		end
	)
	record.connections[#record.connections + 1] = RuntimeGuard.Connect(root.Destroying, "ResponsiveUi.RootDestroying", function()
		cleanupRoot(root)
	end)

	convertDescendants(record)
end

return ResponsiveUi
