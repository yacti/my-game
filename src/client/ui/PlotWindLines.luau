local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PlotWindLines = {}

local DEFAULT_DIRECTION = Vector3.new(-1, 0, 0)
local DEFAULT_SPAWN_RATE = 28
local DEFAULT_SPEED = 95
local DEFAULT_TRAIL_MAX_LENGTH = 34
local DEFAULT_WIDTH = 0.45
local DEFAULT_MIN_HEIGHT = 7
local DEFAULT_MAX_HEIGHT = 34
local DEFAULT_EDGE_PADDING = 18
local DEFAULT_LEAD_DISTANCE = 36
local DEFAULT_TAIL_DISTANCE = 36
local DEFAULT_LIFETIME = 3
local DEFAULT_VIEW_MIN_DISTANCE = 18
local DEFAULT_VIEW_MAX_DISTANCE = 70
local DEFAULT_VIEW_HORIZONTAL_SPREAD = 55
local DEFAULT_VIEW_VERTICAL_SPREAD = 28
local DEFAULT_TRANSPARENCY = 0.7
local ATTACHMENT_OFFSET = Vector3.new(0, 0.1, 0)
local MAX_SPAWNS_PER_STEP = 4

local rng = Random.new()

local Emitter = {}
Emitter.__index = Emitter

local function expandBounds(bounds, position)
	if not bounds.min then
		bounds.min = position
		bounds.max = position
		return
	end
	bounds.min = Vector3.new(
		math.min(bounds.min.X, position.X),
		math.min(bounds.min.Y, position.Y),
		math.min(bounds.min.Z, position.Z)
	)
	bounds.max = Vector3.new(
		math.max(bounds.max.X, position.X),
		math.max(bounds.max.Y, position.Y),
		math.max(bounds.max.Z, position.Z)
	)
end

local function expandCFrameBounds(bounds, cframe, size)
	local half = size * 0.5
	for _, x in ipairs({ -half.X, half.X }) do
		for _, y in ipairs({ -half.Y, half.Y }) do
			for _, z in ipairs({ -half.Z, half.Z }) do
				expandBounds(bounds, (cframe * CFrame.new(x, y, z)).Position)
			end
		end
	end
end

local function boundsFromPart(part)
	local bounds = {}
	expandCFrameBounds(bounds, part.CFrame, part.Size)
	return bounds.min, bounds.max
end

local function boundsFromRoot(root)
	local floor = root:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") then
		return boundsFromPart(floor)
	end

	local bounds = {}
	if root:IsA("Model") then
		local ok, cframe, size = pcall(function()
			return root:GetBoundingBox()
		end)
		if ok and cframe and size then
			expandCFrameBounds(bounds, cframe, size)
		end
	end

	if not bounds.min then
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("BasePart") then
				expandCFrameBounds(bounds, descendant.CFrame, descendant.Size)
			end
		end
	end

	return bounds.min, bounds.max
end

local function transparencyForAlpha(baseTransparency, alpha)
	local visibleAmount = math.clamp(alpha, 0, 1)
	local value = 1 - ((1 - baseTransparency) * visibleAmount)
	return NumberSequence.new(math.clamp(value, 0, 1))
end

local function randomInRange(minimum, maximum)
	if maximum <= minimum then
		return minimum
	end
	return rng:NextNumber(minimum, maximum)
end

local function destroyWindLine(windLine)
	if windLine.attachment0 then
		windLine.attachment0:Destroy()
	end
	if windLine.attachment1 then
		windLine.attachment1:Destroy()
	end
	if windLine.trail then
		windLine.trail:Destroy()
	end
end

function Emitter:SetIntensity(alpha)
	self.intensity = math.clamp(tonumber(alpha) or 0, 0, 1)
	local transparency = transparencyForAlpha(self.baseTransparency, self.intensity)
	for _, windLine in ipairs(self.lines) do
		if windLine.trail and windLine.trail.Parent then
			windLine.trail.Transparency = transparency
		end
	end
end

function Emitter:GetIntensity()
	return self.intensity
end

function Emitter:SamplePosition()
	local camera = Workspace.CurrentCamera
	if camera then
		local cameraCFrame = camera.CFrame
		local position = (
			cameraCFrame
			* CFrame.new(
				randomInRange(-self.viewHorizontalSpread, self.viewHorizontalSpread),
				randomInRange(-self.viewVerticalSpread, self.viewVerticalSpread),
				-randomInRange(self.viewMinDistance, self.viewMaxDistance)
			)
		).Position

		return position
	end

	local minBounds = self.minBounds
	local maxBounds = self.maxBounds
	if not (minBounds and maxBounds) then
		return nil
	end
	local x = maxBounds.X + self.leadDistance
	local y = maxBounds.Y + randomInRange(self.minHeight, self.maxHeight)
	local z = randomInRange(minBounds.Z - self.edgePadding, maxBounds.Z + self.edgePadding)
	return Vector3.new(x, y, z)
end

function Emitter:CreateWindLine()
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not terrain then
		return
	end

	local attachment0 = Instance.new("Attachment")
	local attachment1 = Instance.new("Attachment")
	local position = self:SamplePosition()
	if not position then
		attachment0:Destroy()
		attachment1:Destroy()
		return
	end
	attachment0.WorldPosition = position
	attachment1.WorldPosition = position + ATTACHMENT_OFFSET
	attachment0.Parent = terrain
	attachment1.Parent = terrain

	local trail = Instance.new("Trail")
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.MaxLength = self.trailMaxLength
	trail.MinLength = 0.1
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, self.width * 0.3),
		NumberSequenceKeypoint.new(0.2, self.width),
		NumberSequenceKeypoint.new(0.8, self.width),
		NumberSequenceKeypoint.new(1, self.width * 0.3),
	})
	trail.Transparency = transparencyForAlpha(self.baseTransparency, self.intensity)
	trail.Parent = attachment0

	self.lines[#self.lines + 1] = {
		attachment0 = attachment0,
		attachment1 = attachment1,
		trail = trail,
		lifetime = self.lifetime + rng:NextNumber(-0.35, 0.35),
		position = position,
		direction = self.direction,
		speed = self.speed + rng:NextNumber(-8, 8),
		startedAt = os.clock(),
		seed = rng:NextNumber(0, 100),
	}
end

function Emitter:Step()
	local now = os.clock()
	if self.intensity > 0 then
		local spawnInterval = 1 / math.max(self.spawnRate * self.intensity, 1)
		local spawned = 0
		while now >= self.nextSpawnAt and spawned < MAX_SPAWNS_PER_STEP do
			self:CreateWindLine()
			self.nextSpawnAt += spawnInterval
			spawned += 1
		end
	else
		self.nextSpawnAt = now + (1 / self.spawnRate)
	end

	local index = 1
	while index <= #self.lines do
		local windLine = self.lines[index]
		local aliveTime = now - windLine.startedAt
		if aliveTime >= windLine.lifetime or not (windLine.attachment0.Parent and windLine.attachment1.Parent) then
			destroyWindLine(windLine)
			local length = #self.lines
			self.lines[index] = self.lines[length]
			self.lines[length] = nil
			continue
		end

		local lifetimeAlpha = aliveTime / windLine.lifetime
		local seededClock = (now + windLine.seed) * (windLine.speed * 0.2)
		local basePosition = (
			CFrame.new(windLine.position, windLine.position + windLine.direction)
			* CFrame.new(0, 0, windLine.speed * -aliveTime)
		).Position
		local drift = Vector3.new(
			math.sin(seededClock) * 0.75,
			math.sin(seededClock * 0.9) * 1.15,
			math.sin(seededClock * 1.1) * 0.75
		)
		windLine.attachment0.WorldPosition = basePosition + drift
		windLine.attachment1.WorldPosition = windLine.attachment0.WorldPosition + ATTACHMENT_OFFSET
		windLine.trail.MaxLength = self.trailMaxLength * (1 - lifetimeAlpha)

		index += 1
	end
end

function Emitter:Stop()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end

	for _, windLine in ipairs(self.lines) do
		destroyWindLine(windLine)
	end
	table.clear(self.lines)
end

function PlotWindLines.Start(plot, settings)
	settings = settings or {}
	if typeof(plot) ~= "Instance" then
		return nil
	end

	local minBounds, maxBounds = boundsFromRoot(plot)
	if not (Workspace.CurrentCamera or (minBounds and maxBounds)) then
		return nil
	end

	local direction = settings.direction or DEFAULT_DIRECTION
	if direction.Magnitude <= 0 then
		direction = DEFAULT_DIRECTION
	end
	direction = direction.Unit

	local speed = math.max(tonumber(settings.speed) or DEFAULT_SPEED, 1)
	local leadDistance = math.max(tonumber(settings.leadDistance) or DEFAULT_LEAD_DISTANCE, 0)
	local tailDistance = math.max(tonumber(settings.tailDistance) or DEFAULT_TAIL_DISTANCE, 0)
	local lifetime = tonumber(settings.lifetime)
	if not lifetime and minBounds and maxBounds and not Workspace.CurrentCamera then
		local travelDistance = (maxBounds.X - minBounds.X) + leadDistance + tailDistance
		lifetime = travelDistance / speed
	end

	local emitter = setmetatable({
		minBounds = minBounds,
		maxBounds = maxBounds,
		direction = direction,
		speed = speed,
		lifetime = math.max(lifetime or DEFAULT_LIFETIME, 1.5),
		spawnRate = math.max(tonumber(settings.spawnRate) or DEFAULT_SPAWN_RATE, 1),
		trailMaxLength = math.max(tonumber(settings.trailMaxLength) or DEFAULT_TRAIL_MAX_LENGTH, 1),
		width = math.max(tonumber(settings.width) or DEFAULT_WIDTH, 0.05),
		minHeight = math.max(tonumber(settings.minHeight) or DEFAULT_MIN_HEIGHT, 0),
		maxHeight = math.max(tonumber(settings.maxHeight) or DEFAULT_MAX_HEIGHT, 0),
		edgePadding = math.max(tonumber(settings.edgePadding) or DEFAULT_EDGE_PADDING, 0),
		leadDistance = leadDistance,
		viewMinDistance = math.max(tonumber(settings.viewMinDistance) or DEFAULT_VIEW_MIN_DISTANCE, 0),
		viewMaxDistance = math.max(tonumber(settings.viewMaxDistance) or DEFAULT_VIEW_MAX_DISTANCE, 0),
		viewHorizontalSpread = math.max(tonumber(settings.viewHorizontalSpread) or DEFAULT_VIEW_HORIZONTAL_SPREAD, 0),
		viewVerticalSpread = math.max(tonumber(settings.viewVerticalSpread) or DEFAULT_VIEW_VERTICAL_SPREAD, 0),
		baseTransparency = math.clamp(tonumber(settings.baseTransparency) or DEFAULT_TRANSPARENCY, 0, 1),
		intensity = 0,
		nextSpawnAt = os.clock(),
		lines = table.create(64),
		connection = nil,
	}, Emitter)

	emitter.connection = RunService.Heartbeat:Connect(function()
		emitter:Step()
	end)

	return emitter
end

return PlotWindLines
