local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local CloudController = {}

local WAIT_SECONDS = 10
local LOCAL_FOLDER_NAME = "__LocalClouds"
local CLOUDS_PER_LANE = 15
local MOVE_SPEED = 5
local FADE_SECONDS = 10
local MIN_SCALE = 1
local MAX_SCALE = 2
local DEFAULT_UPDATE_HZ = 10
local LANE_NAMES = { "Clouds", "Clouds0", "Clouds1" }

local rng = Random.new()
local cloudFolder = nil
local heartbeatConnection = nil
local updateAccumulator = 0
local speedMultiplier = 1
local updateHz = DEFAULT_UPDATE_HZ
local transparencyOverride = nil
local activeLanes = nil

local function warnCloud(message)
	warn("[CloudController] " .. message)
end

local function loadLane(map, laneName)
	local lane = map and map:WaitForChild(laneName, WAIT_SECONDS)
	local start = lane and lane:WaitForChild("CloudStart", WAIT_SECONDS)
	local finish = lane and lane:WaitForChild("CloudEnd", WAIT_SECONDS)
	if not (start and start:IsA("BasePart")) then
		warnCloud("Missing Workspace.Map." .. laneName .. ".CloudStart BasePart; clouds disabled")
		return nil
	end
	if not (finish and finish:IsA("BasePart")) then
		warnCloud("Missing Workspace.Map." .. laneName .. ".CloudEnd BasePart; clouds disabled")
		return nil
	end
	return { start = start, finish = finish, active = {} }
end

local function loadAssets()
	local map = Workspace:WaitForChild("Map", WAIT_SECONDS)
	local misc = Assets.WaitFor(Assets.Names.Misc, WAIT_SECONDS)
	local templatesFolder = misc and misc:WaitForChild("Clouds", WAIT_SECONDS)
	if not templatesFolder then
		warnCloud("Missing ReplicatedStorage.Assets.Misc.Clouds; clouds disabled")
		return nil
	end

	local templates = {}
	for _, child in ipairs(templatesFolder:GetChildren()) do
		if child:IsA("BasePart") then
			templates[#templates + 1] = child
		end
	end
	if #templates == 0 then
		warnCloud("ReplicatedStorage.Assets.Misc.Clouds has no BasePart templates; clouds disabled")
		return nil
	end

	local lanes = {}
	for _, laneName in ipairs(LANE_NAMES) do
		local lane = loadLane(map, laneName)
		if not lane then
			return nil
		end
		lanes[#lanes + 1] = lane
	end
	return { lanes = lanes, templates = templates }
end

local function getCloudFolder()
	if cloudFolder and cloudFolder.Parent then
		return cloudFolder
	end
	cloudFolder = Instance.new("Folder")
	cloudFolder.Name = LOCAL_FOLDER_NAME
	cloudFolder.Parent = Workspace
	return cloudFolder
end

local function prepareCloud(part)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function targetTransparency(cloud)
	if type(transparencyOverride) == "number" then
		return transparencyOverride
	end
	if cloud.fadingOut then
		return 1
	end
	return cloud.defaultTransparency or 0
end

local function tweenCloudTransparency(cloud, transparency, seconds)
	if cloud.transparencyTween then
		cloud.transparencyTween:Cancel()
		cloud.transparencyTween = nil
	end
	seconds = math.max(tonumber(seconds) or FADE_SECONDS, 0)
	if seconds <= 0 then
		cloud.part.Transparency = transparency
		return
	end
	local tween = TweenService:Create(
		cloud.part,
		TweenInfo.new(seconds, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ Transparency = transparency }
	)
	cloud.transparencyTween = tween
	tween.Completed:Connect(function()
		if cloud.transparencyTween == tween then
			cloud.transparencyTween = nil
		end
	end)
	tween:Play()
end

local function retargetActiveClouds(seconds)
	for _, lane in ipairs(activeLanes or {}) do
		for _, cloud in ipairs(lane.active) do
			if cloud.part and cloud.part.Parent then
				tweenCloudTransparency(cloud, targetTransparency(cloud), seconds)
			end
		end
	end
end

local function sampleHorizontal(part)
	local halfSize = part.Size * 0.5
	return part.CFrame:PointToWorldSpace(Vector3.new(
		rng:NextNumber(-halfSize.X, halfSize.X),
		0,
		rng:NextNumber(-halfSize.Z, halfSize.Z)
	))
end

local function samplePath(lane)
	local startPoint = sampleHorizontal(lane.start)
	local endPoint = sampleHorizontal(lane.finish)
	local halfHeight = lane.start.Size.Y * 0.5
	local y = rng:NextNumber(lane.start.Position.Y - halfHeight, lane.start.Position.Y + halfHeight)
	return Vector3.new(startPoint.X, y, startPoint.Z), Vector3.new(endPoint.X, y, endPoint.Z)
end

local function spawnCloud(assets, lane, seeded)
	local cloud = assets.templates[rng:NextInteger(1, #assets.templates)]:Clone()
	local defaultTransparency = cloud.Transparency
	local startPosition, endPosition = samplePath(lane)
	local distance = (endPosition - startPosition).Magnitude
	if distance <= 0 then
		cloud:Destroy()
		return false
	end

	local duration = distance / MOVE_SPEED
	local maxSeedProgress = math.max(0, 1 - FADE_SECONDS / duration)
	local progress = seeded and rng:NextNumber(0, maxSeedProgress) or 0
	local rotation = cloud.CFrame - cloud.Position
	local position = startPosition:Lerp(endPosition, progress)

	prepareCloud(cloud)
	cloud.Size *= rng:NextNumber(MIN_SCALE, MAX_SCALE)
	cloud.CFrame = CFrame.new(position) * rotation
	cloud.Parent = getCloudFolder()
	local record = {
		part = cloud,
		defaultTransparency = defaultTransparency,
		startPosition = startPosition,
		endPosition = endPosition,
		rotation = rotation,
		duration = duration,
		elapsed = duration * progress,
		fadingOut = false,
		transparencyTween = nil,
	}
	if seeded then
		cloud.Transparency = targetTransparency(record)
	else
		cloud.Transparency = 1
		tweenCloudTransparency(record, targetTransparency(record), FADE_SECONDS)
	end

	lane.active[#lane.active + 1] = record
	return true
end

local function updateLane(assets, lane, deltaTime)
	local adjustedDeltaTime = deltaTime * speedMultiplier
	for index = #lane.active, 1, -1 do
		local cloud = lane.active[index]
		if not cloud.part.Parent then
			table.remove(lane.active, index)
			continue
		end

		cloud.elapsed += adjustedDeltaTime
		local progress = math.clamp(cloud.elapsed / cloud.duration, 0, 1)
		cloud.part.CFrame = CFrame.new(cloud.startPosition:Lerp(cloud.endPosition, progress)) * cloud.rotation

		if not cloud.fadingOut and cloud.duration - cloud.elapsed <= FADE_SECONDS then
			cloud.fadingOut = true
			tweenCloudTransparency(cloud, targetTransparency(cloud), FADE_SECONDS)
		end
		if progress >= 1 then
			cloud.part:Destroy()
			table.remove(lane.active, index)
		end
	end

	while #lane.active < CLOUDS_PER_LANE do
		if not spawnCloud(assets, lane, false) then
			break
		end
	end
end

function CloudController.GetSpeedMultiplier()
	return speedMultiplier
end

function CloudController.SetSpeedMultiplier(multiplier)
	speedMultiplier = math.max(tonumber(multiplier) or 1, 0)
end

function CloudController.GetUpdateHz()
	return updateHz
end

function CloudController.SetUpdateHz(hz)
	updateHz = math.max(tonumber(hz) or DEFAULT_UPDATE_HZ, 1)
end

function CloudController.SetTransparencyOverride(transparency, seconds)
	if transparency == nil or transparency == false then
		transparencyOverride = nil
	else
		transparencyOverride = math.clamp(tonumber(transparency) or 0, 0, 1)
	end
	retargetActiveClouds(seconds)
end

function CloudController.start()
	if heartbeatConnection then
		return
	end

	RuntimeGuard.Spawn("CloudController.Start", function()
		local assets = loadAssets()
		if not assets then
			return
		end

		getCloudFolder()
		activeLanes = assets.lanes
		for _, lane in ipairs(assets.lanes) do
			for _ = 1, CLOUDS_PER_LANE do
				spawnCloud(assets, lane, true)
			end
		end

		heartbeatConnection = RuntimeGuard.Connect(RunService.Heartbeat, "CloudController.Heartbeat", function(deltaTime)
			updateAccumulator += deltaTime
			local updateInterval = 1 / updateHz
			if updateAccumulator < updateInterval then
				return
			end

			local stepTime = updateAccumulator
			updateAccumulator = 0
			for _, lane in ipairs(assets.lanes) do
				RuntimeGuard.Run("CloudController.UpdateLane", updateLane, assets, lane, stepTime)
			end
		end)
	end)
end

return CloudController
