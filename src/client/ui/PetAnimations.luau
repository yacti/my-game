local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local State = require(Shared:WaitForChild("State"))

local FADE_SECONDS = 0.18
local ANIMATOR_WAIT_SECONDS = 5
local DEFAULT_WALK_SPEED = 8
local FEED_REACTION_TILT_RADIANS = math.rad(15)
local FEED_REACTION_TWEEN_SECONDS = 0.2
local TURN_TWEEN_SECONDS = 0.2
local BOX_CORNER_SIGNS = { -1, 1 }

local PetAnimations = {}
local attached = {}
local cleanup

local function localToWorldOnFloorTop(floor, lx, lz, pivotFloorOffset, lry, roll)
	local localCF = CFrame.new(lx, floor.Size.Y / 2 + pivotFloorOffset, lz)
		* CFrame.Angles(0, lry or 0, 0)
		* CFrame.Angles(0, 0, roll or 0)
	return floor.CFrame * localCF
end

local function modelPivotFloorOffset(model)
	local pivot = model:GetPivot()
	local boundsCF, boundsSize = model:GetBoundingBox()
	local halfBounds = Vector3.new(boundsSize.X / 2, boundsSize.Y / 2, boundsSize.Z / 2)
	local lowestLocalY = math.huge

	for _, sx in ipairs(BOX_CORNER_SIGNS) do
		for _, sy in ipairs(BOX_CORNER_SIGNS) do
			for _, sz in ipairs(BOX_CORNER_SIGNS) do
				local worldCorner = boundsCF:PointToWorldSpace(Vector3.new(
					sx * halfBounds.X,
					sy * halfBounds.Y,
					sz * halfBounds.Z
				))
				local pivotCorner = pivot:PointToObjectSpace(worldCorner)
				lowestLocalY = math.min(lowestLocalY, pivotCorner.Y)
			end
		end
	end

	if lowestLocalY == math.huge then return 0 end
	return math.max(-lowestLocalY, 0)
end

local function floorForPet(pet)
	local plot = pet.Parent
	local floor = plot and plot:FindFirstChild("Floor") or nil
	return floor and floor:IsA("BasePart") and floor or nil
end

local function segmentNumber(pet, key)
	local value = pet:GetAttribute(key)
	return type(value) == "number" and value or nil
end

local function readSegmentData(pet)
	local packed = pet:GetAttribute(State.Pet.SegmentData)
	if type(packed) ~= "string" or packed == "" then
		return nil
	end

	local values = {}
	for part in string.gmatch(packed, "[^,]+") do
		values[#values + 1] = tonumber(part)
	end

	if #values ~= 9 then
		return nil
	end
	for _, value in ipairs(values) do
		if value == nil then
			return nil
		end
	end

	return {
		packed = packed,
		seq = values[1],
		startTime = values[2],
		duration = values[3],
		startLX = values[4],
		startLZ = values[5],
		startLRY = values[6],
		targetLX = values[7],
		targetLZ = values[8],
		targetLRY = values[9],
	}
end

local function readLegacySegment(pet)
	local seq = segmentNumber(pet, State.Pet.MotionSeq)
	local startTime = segmentNumber(pet, State.Pet.SegmentStartTime)
	local duration = segmentNumber(pet, State.Pet.SegmentDuration)
	local startLX = segmentNumber(pet, State.Pet.SegmentStartLX)
	local startLZ = segmentNumber(pet, State.Pet.SegmentStartLZ)
	local startLRY = segmentNumber(pet, State.Pet.SegmentStartLRY)
	local targetLX = segmentNumber(pet, State.Pet.SegmentTargetLX)
	local targetLZ = segmentNumber(pet, State.Pet.SegmentTargetLZ)
	local targetLRY = segmentNumber(pet, State.Pet.SegmentTargetLRY)
	if seq == nil or startTime == nil or duration == nil
		or startLX == nil or startLZ == nil or startLRY == nil
		or targetLX == nil or targetLZ == nil or targetLRY == nil then
		return nil
	end

	return {
		packed = nil,
		seq = seq,
		startTime = startTime,
		duration = duration,
		startLX = startLX,
		startLZ = startLZ,
		startLRY = startLRY,
		targetLX = targetLX,
		targetLZ = targetLZ,
		targetLRY = targetLRY,
	}
end

local function shortestAngleDelta(fromAngle, toAngle)
	return math.atan2(math.sin(toAngle - fromAngle), math.cos(toAngle - fromAngle))
end

local function normalizeAngle(angle)
	return math.atan2(math.sin(angle), math.cos(angle))
end

local function applySegment(record, segment)
	local currentLRY = normalizeAngle(record.visualLRY or segment.startLRY)
	record.segment = segment
	record.turnStartLRY = currentLRY
	record.turnTargetLRY = normalizeAngle(segment.targetLRY)
	record.turnStartClock = os.clock()
end

local function feedReactionTargetRoll(pet)
	local startTime = segmentNumber(pet, State.Pet.FeedReactionStartTime)
	local duration = segmentNumber(pet, State.Pet.FeedReactionDuration)
	local direction = segmentNumber(pet, State.Pet.FeedReactionDirection)
	if startTime == nil or duration == nil or duration <= 0 or direction == nil then
		return 0
	end

	local elapsed = Workspace:GetServerTimeNow() - startTime
	if elapsed < 0 then
		return 0
	end

	if elapsed > duration then
		return 0
	end

	return FEED_REACTION_TILT_RADIANS * math.clamp(direction, -1, 1)
end

local function renderPet(record, dt)
	local pet = record.pet
	if not pet.Parent then
		cleanup(pet)
		return
	end

	local floor = floorForPet(pet)
	if not floor then return end

	local packed = pet:GetAttribute(State.Pet.SegmentData)
	if type(packed) == "string" and packed ~= "" and (not record.segment or record.segment.packed ~= packed) then
		local segment = readSegmentData(pet)
		if segment then
			applySegment(record, segment)
		end
	elseif packed == nil then
		local seq = segmentNumber(pet, State.Pet.MotionSeq)
		if seq ~= nil and (not record.segment or record.segment.seq ~= seq) then
			local segment = readLegacySegment(pet)
			if segment then
				applySegment(record, segment)
			end
		end
	end

	local segment = record.segment
	if not segment then
		return
	end

	local elapsed = Workspace:GetServerTimeNow() - segment.startTime
	local alpha = 1
	if segment.duration > 0 then
		alpha = math.clamp(elapsed / segment.duration, 0, 1)
	end

	local turnElapsed = record.turnStartClock and (os.clock() - record.turnStartClock) or TURN_TWEEN_SECONDS
	local turnAlpha = TURN_TWEEN_SECONDS > 0 and math.clamp(turnElapsed / TURN_TWEEN_SECONDS, 0, 1) or 1
	local lx = segment.startLX + (segment.targetLX - segment.startLX) * alpha
	local lz = segment.startLZ + (segment.targetLZ - segment.startLZ) * alpha
	local turnStartLRY = record.turnStartLRY or segment.startLRY
	local turnTargetLRY = record.turnTargetLRY or segment.targetLRY
	local lry = normalizeAngle(turnStartLRY + shortestAngleDelta(turnStartLRY, turnTargetLRY) * turnAlpha)
	record.visualLRY = lry
	local targetRoll = feedReactionTargetRoll(pet)
	local rollAlpha = FEED_REACTION_TWEEN_SECONDS > 0
		and (1 - math.exp(-(dt or 0) / FEED_REACTION_TWEEN_SECONDS))
		or 1
	record.roll += (targetRoll - record.roll) * math.clamp(rollAlpha, 0, 1)
	if math.abs(record.roll - targetRoll) < 0.001 then
		record.roll = targetRoll
	end

	pet:PivotTo(localToWorldOnFloorTop(floor, lx, lz, modelPivotFloorOffset(pet), lry, record.roll))
end

local function isPet(instance)
	return instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil
end

local function findAnimator(pet)
	return pet:FindFirstChildWhichIsA("Animator", true)
end

local function waitForAnimator(pet)
	local deadline = os.clock() + ANIMATOR_WAIT_SECONDS
	while pet.Parent and os.clock() < deadline do
		local animator = findAnimator(pet)
		if animator then return animator end
		task.wait(0.1)
	end
	return nil
end

local function loadTrack(animator, animationId, name)
	if type(animationId) ~= "string" or animationId == "" then
		return nil, nil
	end

	local animation = Instance.new("Animation")
	animation.Name = name .. "Animation"
	animation.AnimationId = animationId

	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		animation:Destroy()
		warn(string.format("[PetAnimations] Failed to load %s animation %s: %s", name, animationId, tostring(trackOrError)))
		return nil, nil
	end

	local track = trackOrError
	track.Looped = true
	return track, animation
end

function cleanup(pet)
	local record = attached[pet]
	if not record then return end

	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	for _, track in pairs(record.tracks) do
		pcall(function()
			track:Stop(0)
			track:Destroy()
		end)
	end
	for _, animation in pairs(record.animations) do
		animation:Destroy()
	end

	attached[pet] = nil
end

local function playState(record, motionState)
	local desiredName = motionState == PetCatalog.MotionStates.Walk and "Walk" or "Idle"
	if record.current == desiredName then return end

	local desiredTrack = record.tracks[desiredName]
	local otherTrack = record.tracks[desiredName == "Walk" and "Idle" or "Walk"]

	if desiredTrack then
		desiredTrack:Play(FADE_SECONDS)
	end
	if otherTrack and otherTrack.IsPlaying then
		otherTrack:Stop(FADE_SECONDS)
	end

	record.current = desiredName
end

local function updateWalkAnimationSpeed(record)
	local walkTrack = record.tracks.Walk
	if not walkTrack then return end

	local walkSpeed = record.pet:GetAttribute(State.Pet.SegmentWalkSpeed)
	if type(walkSpeed) ~= "number" or walkSpeed <= 0 then
		walkSpeed = DEFAULT_WALK_SPEED
	end

	walkTrack:AdjustSpeed(walkSpeed / DEFAULT_WALK_SPEED)
end

local function bindPet(pet)
	if attached[pet] then return end

	local record = {
		pet = pet,
		connections = {},
		tracks = {},
		animations = {},
		current = nil,
		roll = 0,
		segment = nil,
		visualLRY = nil,
		turnStartLRY = nil,
		turnTargetLRY = nil,
		turnStartClock = nil,
	}
	attached[pet] = record

	task.spawn(function()
		if not pet.Parent then
			cleanup(pet)
			return
		end

		local animator = waitForAnimator(pet)
		if not animator then
			warn("[PetAnimations] Pet missing Animator: " .. pet:GetFullName())
			cleanup(pet)
			return
		end

		local petId = pet:GetAttribute(State.Pet.Id)
		local visual = PetCatalog.VisualForPetId(petId)
		if not visual then
			warn("[PetAnimations] No animation config for pet id: " .. tostring(petId))
			cleanup(pet)
			return
		end

		local idleTrack, idleAnimation = loadTrack(animator, visual.IdleAnimationId, "Idle")
		local walkTrack, walkAnimation = loadTrack(animator, visual.WalkAnimationId, "Walk")
		if idleTrack then
			record.tracks.Idle = idleTrack
			record.animations.Idle = idleAnimation
		end
		if walkTrack then
			record.tracks.Walk = walkTrack
			record.animations.Walk = walkAnimation
		end

		record.connections[#record.connections + 1] = pet:GetAttributeChangedSignal(State.Pet.MotionState):Connect(function()
			playState(record, pet:GetAttribute(State.Pet.MotionState))
		end)
		record.connections[#record.connections + 1] = pet:GetAttributeChangedSignal(State.Pet.SegmentWalkSpeed):Connect(function()
			updateWalkAnimationSpeed(record)
		end)
		record.connections[#record.connections + 1] = pet.Destroying:Connect(function()
			cleanup(pet)
		end)

		updateWalkAnimationSpeed(record)
		playState(record, pet:GetAttribute(State.Pet.MotionState))
	end)
end

local function watchPlot(plot)
	for _, child in ipairs(plot:GetChildren()) do
		if isPet(child) then bindPet(child) end
	end
	plot.ChildAdded:Connect(function(child)
		if isPet(child) then bindPet(child) end
	end)
end

local function isPlot(instance)
	return (instance:IsA("Model") or instance:IsA("Folder")) and instance.Name:match("^Plot%d") ~= nil
end

local function watchWorkspace()
	local function onWorkspaceChild(child)
		if isPlot(child) then
			watchPlot(child)
		elseif child.Name == "Plots" then
			for _, plot in ipairs(child:GetChildren()) do
				watchPlot(plot)
			end
			child.ChildAdded:Connect(watchPlot)
		end
	end

	for _, child in ipairs(Workspace:GetChildren()) do
		onWorkspaceChild(child)
	end
	Workspace.ChildAdded:Connect(onWorkspaceChild)
end

function PetAnimations.start()
	watchWorkspace()
	RunService.RenderStepped:Connect(function(dt)
		for _, record in pairs(attached) do
			renderPet(record, dt)
		end
	end)
end

return PetAnimations
