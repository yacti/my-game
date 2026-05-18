local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local State = require(Shared:WaitForChild("State"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))

local UPDATE_INTERVAL = 0.2
local TARGET_EPSILON = 0.05
local POST_FEED_IDLE_SECONDS = 2
local TURN_TWEEN_SECONDS = 0.2

local registry = {}
local heartbeatConnection = nil
local accumulator = 0

local PetMotionService = {}

local function randomBetween(rng, minValue, maxValue)
	return rng:NextNumber(minValue, maxValue)
end

local function clamp(value, minValue, maxValue)
	return math.clamp(value, minValue, maxValue)
end

local function shortestAngleDelta(fromAngle, toAngle)
	return math.atan2(math.sin(toAngle - fromAngle), math.cos(toAngle - fromAngle))
end

local function packNumber(value)
	return string.format("%.17g", value)
end

local function packSegmentData(state)
	return table.concat({
		packNumber(state.motionSeq),
		packNumber(state.startTime),
		packNumber(state.duration),
		packNumber(state.startLX),
		packNumber(state.startLZ),
		packNumber(state.startLRY),
		packNumber(state.targetLX),
		packNumber(state.targetLZ),
		packNumber(state.targetLRY),
	}, ",")
end

local function floorForState(state)
	local plot = state.plot
	return plot and PlotService.GetFloor(plot) or nil
end

local function currentFloorLocal(state, floor)
	local pivot = PetMotionService.GetLogicalPivot(state.pet)
	local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, pivot)
	return lx, lz, lry
end

local function durationFor(state, minKey, maxKey)
	local visual = state.visual
	local minSeconds = visual[minKey] or 2
	local maxSeconds = visual[maxKey] or minSeconds
	if maxSeconds < minSeconds then
		maxSeconds = minSeconds
	end
	return randomBetween(state.rng, minSeconds, maxSeconds)
end

local function walkSpeedFor(state)
	local walkSpeed = state.pet:GetAttribute(State.Pet.WalkSpeed)
	if type(walkSpeed) == "number" and walkSpeed > 0 then
		return walkSpeed
	end
	return PetCatalog.WalkSpeedForPetId(state.pet:GetAttribute(State.Pet.Id))
end

local function chooseTargetInsideFloor(state, floor)
	local minX, maxX, minZ, maxZ = PlotService.PetFloorLocalBounds(floor, state.pet)
	local lx, lz = currentFloorLocal(state, floor)
	local duration = durationFor(state, "MinWalkSeconds", "MaxWalkSeconds")
	local walkSpeed = walkSpeedFor(state)
	local distance = walkSpeed * duration

	local angle = state.rng:NextNumber(0, math.pi * 2)
	local targetLX = lx + math.cos(angle) * distance
	local targetLZ = lz + math.sin(angle) * distance
	targetLX = clamp(targetLX, minX, maxX)
	targetLZ = clamp(targetLZ, minZ, maxZ)

	if (Vector2.new(targetLX - lx, targetLZ - lz)).Magnitude <= TARGET_EPSILON then
		targetLX = randomBetween(state.rng, minX, maxX)
		targetLZ = randomBetween(state.rng, minZ, maxZ)
	end

	return targetLX, targetLZ, duration, walkSpeed
end

local function publishSegment(state, motionState, startLX, startLZ, startLRY, targetLX, targetLZ, targetLRY, duration, walkSpeed)
	state.motionState = motionState
	state.startTime = workspace:GetServerTimeNow()
	state.duration = duration
	state.walkSpeed = walkSpeed or 0
	state.startLX = startLX
	state.startLZ = startLZ
	state.startLRY = startLRY
	state.targetLX = targetLX
	state.targetLZ = targetLZ
	state.targetLRY = targetLRY
	state.motionSeq += 1

	local pet = state.pet
	pet:SetAttribute(State.Pet.SegmentWalkSpeed, state.walkSpeed)
	pet:SetAttribute(State.Pet.SegmentStartTime, state.startTime)
	pet:SetAttribute(State.Pet.SegmentDuration, duration)
	pet:SetAttribute(State.Pet.SegmentStartLX, startLX)
	pet:SetAttribute(State.Pet.SegmentStartLZ, startLZ)
	pet:SetAttribute(State.Pet.SegmentStartLRY, startLRY)
	pet:SetAttribute(State.Pet.SegmentTargetLX, targetLX)
	pet:SetAttribute(State.Pet.SegmentTargetLZ, targetLZ)
	pet:SetAttribute(State.Pet.SegmentTargetLRY, targetLRY)
	pet:SetAttribute(State.Pet.MotionState, motionState)
	pet:SetAttribute(State.Pet.MotionSeq, state.motionSeq)
	pet:SetAttribute(State.Pet.SegmentData, packSegmentData(state))
end

local function beginIdle(state)
	local floor = floorForState(state)
	if not floor then return end

	local lx, lz, lry = currentFloorLocal(state, floor)
	PlotService.SeatPetOnFloor(state.pet, floor, lx, lz, lry)
	publishSegment(
		state,
		PetCatalog.MotionStates.Idle,
		lx,
		lz,
		lry,
		lx,
		lz,
		lry,
		durationFor(state, "MinIdleSeconds", "MaxIdleSeconds"),
		0
	)
end

local function beginWalk(state)
	local floor = floorForState(state)
	if not floor then
		return
	end

	local startLX, startLZ, startLRY = currentFloorLocal(state, floor)
	local targetLX, targetLZ, duration, walkSpeed = chooseTargetInsideFloor(state, floor)
	local dx = targetLX - startLX
	local dz = targetLZ - startLZ
	local targetLRY = math.atan2(-dx, -dz)
	publishSegment(state, PetCatalog.MotionStates.Walk, startLX, startLZ, startLRY, targetLX, targetLZ, targetLRY, duration, walkSpeed)
end

local function unregister(pet)
	local state = registry[pet]
	if not state then return end

	if state.destroyingConnection then
		state.destroyingConnection:Disconnect()
	end
	registry[pet] = nil

	if next(registry) == nil and heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
		accumulator = 0
	end
end

local function tickPet(state, dt)
	local pet = state.pet
	if not pet.Parent then
		unregister(pet)
		return
	end

	local floor = floorForState(state)
	if not floor then return end

	local now = workspace:GetServerTimeNow()
	if state.feedIdleUntil and now >= state.feedIdleUntil then
		state.feedIdleUntil = nil
	end

	if state.startTime == nil then
		if state.feedIdleUntil then
			return
		end
		beginWalk(state)
		return
	end

	if state.feedIdleUntil then
		return
	end

	local elapsed = now - state.startTime
	if elapsed < (state.duration or 0) then
		return
	end

	PlotService.SeatPetOnFloor(pet, floor, state.targetLX or state.startLX or 0, state.targetLZ or state.startLZ or 0, state.targetLRY or state.startLRY or 0)
	if state.motionState == PetCatalog.MotionStates.Walk then
		beginIdle(state)
	else
		beginWalk(state)
	end
end

local function tickAll(dt)
	for _, state in pairs(registry) do
		tickPet(state, dt)
	end
end

local function ensureHeartbeat()
	if heartbeatConnection then return end

	heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		while accumulator >= UPDATE_INTERVAL do
			accumulator -= UPDATE_INTERVAL
			tickAll(UPDATE_INTERVAL)
		end
	end)
end

function PetMotionService.Register(plot, pet)
	if not (plot and pet and pet:IsA("Model")) then return end

	unregister(pet)

	local petId = pet:GetAttribute(State.Pet.Id)
	local visual = PetCatalog.VisualForPetId(petId)
	if not visual then
		warn("[PetMotionService] No pet visual config for " .. tostring(petId))
		return
	end

	local seed = math.floor(os.clock() * 1000000)
		+ (pet:GetAttribute(State.Pet.Index) or 0) * 7919
		+ math.random(1, 1000000)
	local state = {
		pet = pet,
		plot = plot,
		visual = visual,
		rng = Random.new(seed),
		motionState = nil,
		motionSeq = 0,
		walkSpeed = 0,
		startTime = nil,
		duration = 0,
		startLX = nil,
		startLZ = nil,
		startLRY = nil,
		targetLX = nil,
		targetLZ = nil,
		targetLRY = nil,
		feedIdleUntil = nil,
		destroyingConnection = nil,
	}

	state.destroyingConnection = pet.Destroying:Connect(function()
		unregister(pet)
	end)
	registry[pet] = state
	beginWalk(state)
	ensureHeartbeat()
end

function PetMotionService.RefreshPet(pet)
	local state = registry[pet]
	if not state then return end

	local floor = floorForState(state)
	if not floor then return end

	local lx, lz, lry = PlotService.WorldPivotToFloorLocal(floor, pet:GetPivot())
	PlotService.SeatPetOnFloor(pet, floor, lx, lz, lry)
	state.feedIdleUntil = nil
	state.startLX = lx
	state.startLZ = lz
	state.startLRY = lry
	state.targetLX = lx
	state.targetLZ = lz
	state.targetLRY = lry
	state.startTime = workspace:GetServerTimeNow()
	state.duration = 0
	beginWalk(state)
end

function PetMotionService.HoldAfterFeed(pet, faceLX, faceLZ)
	local state = registry[pet]
	if not state then return end

	local floor = floorForState(state)
	if not floor then return end

	local now = workspace:GetServerTimeNow()
	state.feedIdleUntil = now + POST_FEED_IDLE_SECONDS

	local lx, lz, lry = currentFloorLocal(state, floor)
	local targetLRY = lry
	if type(faceLX) == "number" and type(faceLZ) == "number" then
		local dx = faceLX - lx
		local dz = faceLZ - lz
		if math.abs(dx) + math.abs(dz) >= 0.001 then
			targetLRY = math.atan2(-dx, -dz)
		end
	end

	PlotService.SeatPetOnFloor(pet, floor, lx, lz, lry)
	publishSegment(
		state,
		PetCatalog.MotionStates.Idle,
		lx,
		lz,
		lry,
		lx,
		lz,
		targetLRY,
		TURN_TWEEN_SECONDS,
		0
	)
end

function PetMotionService.GetLogicalPivot(pet)
	local state = registry[pet]
	if not state then
		return pet:GetPivot()
	end

	local floor = floorForState(state)
	if not floor then
		return pet:GetPivot()
	end

	local startLX = state.startLX
	local startLZ = state.startLZ
	local startLRY = state.startLRY
	local targetLX = state.targetLX
	local targetLZ = state.targetLZ
	local targetLRY = state.targetLRY
	if startLX == nil or startLZ == nil or startLRY == nil
		or targetLX == nil or targetLZ == nil or targetLRY == nil then
		return pet:GetPivot()
	end

	local duration = state.duration or 0
	local alpha = 1
	if duration > 0 and state.startTime then
		alpha = math.clamp((workspace:GetServerTimeNow() - state.startTime) / duration, 0, 1)
	end

	local lx = startLX + (targetLX - startLX) * alpha
	local lz = startLZ + (targetLZ - startLZ) * alpha
	local turnAlpha = 1
	if state.startTime then
		turnAlpha = math.clamp((workspace:GetServerTimeNow() - state.startTime) / TURN_TWEEN_SECONDS, 0, 1)
	end
	local lry = startLRY + shortestAngleDelta(startLRY, targetLRY) * turnAlpha
	return PlotService.LocalToWorldOnFloorTop(floor, lx, lz, PlotService.PetPivotFloorOffset(pet), lry)
end

function PetMotionService.GetLogicalPosition(pet)
	return PetMotionService.GetLogicalPivot(pet).Position
end

function PetMotionService.UnregisterPlot(plot)
	local petsToRemove = {}
	for pet, state in pairs(registry) do
		if state.plot == plot then
			petsToRemove[#petsToRemove + 1] = pet
		end
	end
	for _, pet in ipairs(petsToRemove) do
		unregister(pet)
	end
end

return PetMotionService
