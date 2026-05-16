local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local State = require(Shared:WaitForChild("State"))

local FADE_SECONDS = 0.18
local ANIMATOR_WAIT_SECONDS = 5
local DEFAULT_WALK_SPEED = 8
local BOX_CORNER_SIGNS = { -1, 1 }

local PetAnimations = {}
local attached = {}
local cleanup

local function localToWorldOnFloorTop(floor, lx, lz, pivotFloorOffset, lry)
	local localCF = CFrame.new(lx, floor.Size.Y / 2 + pivotFloorOffset, lz)
		* CFrame.Angles(0, lry or 0, 0)
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

local function renderPet(record)
	local pet = record.pet
	if not pet.Parent then
		cleanup(pet)
		return
	end

	local floor = floorForPet(pet)
	if not floor then return end

	local startTime = segmentNumber(pet, State.Pet.SegmentStartTime)
	local duration = segmentNumber(pet, State.Pet.SegmentDuration)
	local startLX = segmentNumber(pet, State.Pet.SegmentStartLX)
	local startLZ = segmentNumber(pet, State.Pet.SegmentStartLZ)
	local startLRY = segmentNumber(pet, State.Pet.SegmentStartLRY)
	local targetLX = segmentNumber(pet, State.Pet.SegmentTargetLX)
	local targetLZ = segmentNumber(pet, State.Pet.SegmentTargetLZ)
	local targetLRY = segmentNumber(pet, State.Pet.SegmentTargetLRY)
	if startTime == nil or duration == nil
		or startLX == nil or startLZ == nil or startLRY == nil
		or targetLX == nil or targetLZ == nil or targetLRY == nil then
		return
	end

	local alpha = 1
	if duration > 0 then
		alpha = math.clamp((Workspace:GetServerTimeNow() - startTime) / duration, 0, 1)
	end

	local lx = startLX + (targetLX - startLX) * alpha
	local lz = startLZ + (targetLZ - startLZ) * alpha
	local lry = startLRY + (targetLRY - startLRY) * alpha
	pet:PivotTo(localToWorldOnFloorTop(floor, lx, lz, modelPivotFloorOffset(pet), lry))
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
	RunService.RenderStepped:Connect(function()
		for _, record in pairs(attached) do
			renderPet(record)
		end
	end)
end

return PetAnimations
