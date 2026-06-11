local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetCatalog = require(Shared:WaitForChild("PetCatalog"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))
local PlotGridService = require(script.Parent:WaitForChild("PlotGridService"))

local UPDATE_INTERVAL = 0.2
local TARGET_EPSILON = 0.05
local POST_FEED_IDLE_SECONDS = 2
local TURN_TWEEN_SECONDS = 0.2
local MIN_WALK_SEGMENT_SECONDS = 0.3
local WALK_SPEED_VARIATION = 0.08
local NAVIGATION_WARN_INTERVAL = 10
local ROUTE_REFRESH_MIN_IDLE_SECONDS = 0.15
local ROUTE_REFRESH_STAGGER_SECONDS = 0.85

local registry = {}
local heartbeatConnection = nil
local accumulator = 0
local petNavigation = nil
local petNavigationChecked = false
local lastNavigationWarn = {
	missing = -math.huge,
	failed = -math.huge,
}

local PetMotionService = {}

local function randomBetween(rng, minValue, maxValue)
	return rng:NextNumber(minValue, maxValue)
end

local function shortestAngleDelta(fromAngle, toAngle)
	return math.atan2(math.sin(toAngle - fromAngle), math.cos(toAngle - fromAngle))
end

local function packNumber(value)
	return string.format("%.17g", value)
end

local function packSegmentData(state)
	local nextLX = type(state.nextLX) == "number" and state.nextLX or state.targetLX
	local nextLZ = type(state.nextLZ) == "number" and state.nextLZ or state.targetLZ
	local cornerRadius = type(state.cornerRadius) == "number" and state.cornerRadius or 0

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
		packNumber(nextLX),
		packNumber(nextLZ),
		packNumber(cornerRadius),
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

local function nearestPetFit(state, floor, lx, lz)
	local paddingX, paddingZ = PlotService.PetFootprintPadding(floor, state.pet)
	local fitLX, fitLZ
	if type(lx) == "number" and type(lz) == "number" then
		fitLX, fitLZ = PlotGridService.NearestUnlockedPoint(state.plot, lx, lz, paddingX, paddingZ)
	end
	if type(fitLX) ~= "number" or type(fitLZ) ~= "number"
		or not PlotGridService.IsWalkableFootprint(state.plot, fitLX, fitLZ, paddingX, paddingZ) then
		fitLX, fitLZ = PlotGridService.FirstUnlockedPoint(state.plot, paddingX, paddingZ)
	end
	if PlotGridService.IsWalkableFootprint(state.plot, fitLX, fitLZ, paddingX, paddingZ) then
		return fitLX, fitLZ
	end
	if type(lx) == "number" and type(lz) == "number" then
		return lx, lz
	end

	fitLX, fitLZ = PlotGridService.FirstUnlockedPoint(state.plot, 0, 0)
	if type(fitLX) == "number" and type(fitLZ) == "number" then
		return fitLX, fitLZ
	end
	return 0, 0
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

local function warnNavigation(kind, message)
	local now = os.clock()
	if now - (lastNavigationWarn[kind] or -math.huge) < NAVIGATION_WARN_INTERVAL then
		return
	end
	lastNavigationWarn[kind] = now
	warn(message)
end

local function navigation()
	if petNavigationChecked then
		return petNavigation
	end

	local module = script.Parent:FindFirstChild("PetNavigation")
	if not module then
		warnNavigation("missing", "[PetMotionService] PetNavigation unavailable; using straight pet wander until it syncs")
		return nil
	end

	local ok, result = pcall(require, module)
	if not ok then
		warnNavigation("failed", "[PetMotionService] Failed to load PetNavigation: " .. tostring(result))
		return nil
	end

	petNavigation = result
	petNavigationChecked = true
	return petNavigation
end

local function chooseFallbackTargetInsideFloor(state, floor)
	local minX, maxX, minZ, maxZ = PlotService.PetFloorLocalBounds(floor, state.pet, state.plot)
	if minX >= maxX or minZ >= maxZ then
		return nil, nil, nil, nil
	end
	local lx, lz = currentFloorLocal(state, floor)
	local duration = durationFor(state, "MinWalkSeconds", "MaxWalkSeconds")
	local walkSpeed = walkSpeedFor(state)
	local distance = walkSpeed * duration
	local paddingX, paddingZ = PlotService.PetFootprintPadding(floor, state.pet)

	local angle = state.rng:NextNumber(0, math.pi * 2)
	local targetLX = lx + math.cos(angle) * distance
	local targetLZ = lz + math.sin(angle) * distance
	targetLX = math.clamp(targetLX, minX, maxX)
	targetLZ = math.clamp(targetLZ, minZ, maxZ)
	targetLX, targetLZ = PlotGridService.NearestUnlockedPoint(state.plot, targetLX, targetLZ, paddingX, paddingZ)

	if (Vector2.new(targetLX - lx, targetLZ - lz)).Magnitude <= TARGET_EPSILON then
		targetLX, targetLZ = PlotGridService.RandomUnlockedPoint(state.plot, state.rng, paddingX, paddingZ)
		if not targetLX or not targetLZ then
			targetLX, targetLZ = PlotGridService.FirstUnlockedPoint(state.plot, paddingX, paddingZ)
		end
	end

	return targetLX, targetLZ, duration, walkSpeed
end

local function clearRoute(state)
	state.route = nil
	state.routeIndex = nil
	state.routeDestination = nil
end

local function segmentDistance(startLX, startLZ, targetLX, targetLZ)
	return (Vector2.new(targetLX - startLX, targetLZ - startLZ)).Magnitude
end

local function publishSegment(state, motionState, startLX, startLZ, startLRY, targetLX, targetLZ, targetLRY, duration, walkSpeed, nextLX, nextLZ, cornerRadius)
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
	state.nextLX = nextLX
	state.nextLZ = nextLZ
	state.cornerRadius = cornerRadius
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
	pet:SetAttribute(State.Pet.SegmentNextLX, nextLX)
	pet:SetAttribute(State.Pet.SegmentNextLZ, nextLZ)
	pet:SetAttribute(State.Pet.SegmentCornerRadius, cornerRadius)
	pet:SetAttribute(State.Pet.MotionState, motionState)
	pet:SetAttribute(State.Pet.MotionSeq, state.motionSeq)
	pet:SetAttribute(State.Pet.SegmentData, packSegmentData(state))
end

local function beginIdle(state)
	local floor = floorForState(state)
	if not floor then return end

	local lx, lz, lry = currentFloorLocal(state, floor)
	lx, lz = nearestPetFit(state, floor, lx, lz)
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
	local nav = navigation()
	if not nav then
		local targetLX, targetLZ, duration, walkSpeed = chooseFallbackTargetInsideFloor(state, floor)
		if not targetLX or not targetLZ then
			beginIdle(state)
			return
		end
		local dx = targetLX - startLX
		local dz = targetLZ - startLZ
		local targetLRY = math.atan2(-dx, -dz)
		publishSegment(state, PetCatalog.MotionStates.Walk, startLX, startLZ, startLRY, targetLX, targetLZ, targetLRY, duration, walkSpeed)
		return
	end

	local waypoint
	for _ = 1, 2 do
		if not state.route or not state.routeIndex or state.routeIndex > #state.route then
			local planned = nav.PlanWander(state.plot, floor, state.pet, startLX, startLZ, state.rng)
			if not planned or not planned.route or #planned.route == 0 then
				clearRoute(state)
				beginIdle(state)
				return
			end

			state.route = planned.route
			state.routeIndex = 1
			state.routeDestination = planned.route[#planned.route]
			if planned.recoveredStart then
				startLX = planned.startLX
				startLZ = planned.startLZ
				PlotService.SeatPetOnFloor(state.pet, floor, startLX, startLZ, startLRY)
			end
		end

		waypoint = state.route[state.routeIndex]
		if waypoint and nav.LegIsClear(state.plot, floor, state.pet, startLX, startLZ, waypoint.lx, waypoint.lz) then
			break
		end

		clearRoute(state)
		waypoint = nil
	end

	if not waypoint then
		beginIdle(state)
		return
	end

	local distance = segmentDistance(startLX, startLZ, waypoint.lx, waypoint.lz)
	if distance <= TARGET_EPSILON then
		state.routeIndex += 1
		beginWalk(state)
		return
	end

	state.routeIndex += 1
	local walkSpeed = walkSpeedFor(state)
	local segmentWalkSpeed = walkSpeed * state.rng:NextNumber(1 - WALK_SPEED_VARIATION, 1 + WALK_SPEED_VARIATION)
	local duration = math.max(distance / segmentWalkSpeed, MIN_WALK_SEGMENT_SECONDS)
	local dx = waypoint.lx - startLX
	local dz = waypoint.lz - startLZ
	local targetLRY = math.atan2(-dx, -dz)
	publishSegment(
		state,
		PetCatalog.MotionStates.Walk,
		startLX,
		startLZ,
		startLRY,
		waypoint.lx,
		waypoint.lz,
		targetLRY,
		duration,
		segmentWalkSpeed,
		waypoint.nextLX,
		waypoint.nextLZ,
		waypoint.cornerRadius
	)
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
		if state.route and state.routeIndex and state.routeIndex <= #state.route then
			beginWalk(state)
		else
			clearRoute(state)
			beginIdle(state)
		end
	else
		beginWalk(state)
	end
end

local function tickAll(dt)
	for _, state in pairs(registry) do
		RuntimeGuard.Run("PetMotionService.TickPet", tickPet, state, dt)
	end
end

local function ensureHeartbeat()
	if heartbeatConnection then return end

	heartbeatConnection = RuntimeGuard.Connect(RunService.Heartbeat, "PetMotionService.Heartbeat", function(dt)
		-- Clamp so a long frame spike cannot queue dozens of catch-up ticks
		-- that all replay in the next frame and amplify the spike.
		accumulator = math.min(accumulator + dt, UPDATE_INTERVAL)
		if accumulator >= UPDATE_INTERVAL then
			accumulator = 0
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
		route = nil,
		routeIndex = nil,
		routeDestination = nil,
		nextLX = nil,
		nextLZ = nil,
		cornerRadius = nil,
		feedIdleUntil = nil,
		destroyingConnection = nil,
	}

	state.destroyingConnection = RuntimeGuard.Connect(pet.Destroying, "PetMotionService.PetDestroying", function()
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
	lx, lz = nearestPetFit(state, floor, lx, lz)
	PlotService.SeatPetOnFloor(pet, floor, lx, lz, lry)
	state.feedIdleUntil = nil
	clearRoute(state)
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

function PetMotionService.HoldAfterFeed(pet, faceLX, faceLZ, holdSeconds)
	local state = registry[pet]
	if not state then return end

	local floor = floorForState(state)
	if not floor then return end

	local now = workspace:GetServerTimeNow()
	state.feedIdleUntil = now + (holdSeconds or POST_FEED_IDLE_SECONDS)
	clearRoute(state)

	local lx, lz, lry = currentFloorLocal(state, floor)
	lx, lz = nearestPetFit(state, floor, lx, lz)
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

function PetMotionService.RefreshPlotRoutes(plot)
	for pet, state in pairs(registry) do
		if state.plot == plot and pet.Parent then
			local floor = floorForState(state)
			if floor then
				local lx, lz, lry = currentFloorLocal(state, floor)
				lx, lz = nearestPetFit(state, floor, lx, lz)
				PlotService.SeatPetOnFloor(pet, floor, lx, lz, lry)
				clearRoute(state)
				if not state.feedIdleUntil then
					local delay = ROUTE_REFRESH_MIN_IDLE_SECONDS
						+ state.rng:NextNumber(0, ROUTE_REFRESH_STAGGER_SECONDS)
					publishSegment(
						state,
						PetCatalog.MotionStates.Idle,
						lx,
						lz,
						lry,
						lx,
						lz,
						lry,
						delay,
						0
					)
				else
					state.startLX = lx
					state.startLZ = lz
					state.startLRY = lry
					state.targetLX = lx
					state.targetLZ = lz
					state.targetLRY = lry
					state.startTime = workspace:GetServerTimeNow()
					state.duration = 0
				end
			end
		end
	end
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
