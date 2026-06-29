local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AFKRejoinConfig = require(Shared:WaitForChild("AFKRejoinConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local AFKRejoinController = {}

local LOADING_SCREEN_NAME = "LoadingScreen"

local started = false
local requestedThisIdle = false
local cameraRestoreToken = 0

local function characterHumanoid(player)
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function restoreCharacterCamera(player)
	local camera = Workspace.CurrentCamera
	if camera then
		local humanoid = characterHumanoid(player)
		if humanoid then
			camera.CameraSubject = humanoid
		end
		camera.CameraType = Enum.CameraType.Custom
	end
end

local function setZoomRange(player, minDistance, maxDistance)
	if minDistance > maxDistance then
		minDistance, maxDistance = maxDistance, minDistance
	end

	if minDistance < player.CameraMinZoomDistance then
		player.CameraMinZoomDistance = minDistance
		player.CameraMaxZoomDistance = maxDistance
	else
		player.CameraMaxZoomDistance = maxDistance
		player.CameraMinZoomDistance = minDistance
	end
end

local function beginTemporaryZoomRestore(player, zoomDistance)
	zoomDistance = tonumber(zoomDistance)
	if not AFKRejoinConfig.IsFiniteNumber(zoomDistance) then
		return nil
	end
	zoomDistance = math.clamp(
		zoomDistance,
		AFKRejoinConfig.MinCameraZoomDistance,
		AFKRejoinConfig.MaxCameraZoomDistance
	)

	local previousMin = player.CameraMinZoomDistance
	local previousMax = player.CameraMaxZoomDistance
	local applied = pcall(setZoomRange, player, zoomDistance, zoomDistance)
	if not applied then
		return nil
	end

	return function()
		if player.Parent then
			pcall(setZoomRange, player, previousMin, previousMax)
		end
	end
end

local function cancelCameraRestore()
	cameraRestoreToken += 1
end

local function floorForPlayer(player)
	local plot = PlotResolver.ResolveForPlayer(player)
	local floor = plot and plot:FindFirstChild("Floor")
	return floor and floor:IsA("BasePart") and floor or nil
end

local function cameraTypeName(camera)
	local cameraType = camera and camera.CameraType
	return cameraType and cameraType.Name or "Custom"
end

local function buildCameraPayload(player)
	local camera = Workspace.CurrentCamera
	local floor = floorForPlayer(player)
	if not (camera and floor) then
		return nil
	end

	local localCFrame = AFKRejoinConfig.CFrameToArray(floor.CFrame:ToObjectSpace(camera.CFrame))
	local localFocus = AFKRejoinConfig.CFrameToArray(floor.CFrame:ToObjectSpace(camera.Focus))
	if not (localCFrame and localFocus) then
		return nil
	end

	return {
		localCFrame = localCFrame,
		localFocus = localFocus,
		fieldOfView = camera.FieldOfView,
		cameraType = cameraTypeName(camera),
		zoomDistance = (camera.CFrame.Position - camera.Focus.Position).Magnitude,
	}
end

local function waitForFloor(player)
	local deadline = os.clock() + AFKRejoinConfig.CameraRestoreFloorWaitSeconds
	local floor = floorForPlayer(player)
	while not floor and os.clock() < deadline do
		task.wait(0.1)
		floor = floorForPlayer(player)
	end
	return floor
end

local function waitForLoadingScreenDismissed(player)
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 5)
	if not playerGui then
		return false
	end

	local deadline = os.clock() + AFKRejoinConfig.LoadingScreenDismissWaitSeconds
	while playerGui:FindFirstChild(LOADING_SCREEN_NAME) and os.clock() < deadline do
		task.wait(0.1)
	end

	return playerGui:FindFirstChild(LOADING_SCREEN_NAME) == nil
end

local function restoreCamera(player, payload)
	local cameraPayload = AFKRejoinConfig.SanitizeCameraPayload(payload)
	if not cameraPayload then
		return
	end

	if not waitForLoadingScreenDismissed(player) then
		return
	end

	local floor = waitForFloor(player)
	if not floor then
		return
	end

	local localCFrame = AFKRejoinConfig.CFrameFromArray(cameraPayload.localCFrame, AFKRejoinConfig.MaxLocalPositionAbs)
	local localFocus = AFKRejoinConfig.CFrameFromArray(cameraPayload.localFocus, AFKRejoinConfig.MaxLocalPositionAbs)
	if not (localCFrame and localFocus) then
		return
	end

	local targetCFrame = floor.CFrame * localCFrame
	local targetFocus = floor.CFrame * localFocus
	local token = cameraRestoreToken + 1
	cameraRestoreToken = token
	local restoreZoomLimits = beginTemporaryZoomRestore(player, cameraPayload.zoomDistance)

	local function cleanupZoomLimits()
		if restoreZoomLimits then
			restoreZoomLimits()
			restoreZoomLimits = nil
		end
	end

	for _ = 1, AFKRejoinConfig.CameraRestoreFrames do
		if cameraRestoreToken ~= token then
			cleanupZoomLimits()
			return
		end
		local camera = Workspace.CurrentCamera
		if camera then
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = targetCFrame
			camera.Focus = targetFocus
			camera.FieldOfView = cameraPayload.fieldOfView
		end
		RunService.RenderStepped:Wait()
	end

	if cameraRestoreToken ~= token then
		cleanupZoomLimits()
		return
	end

	local camera = Workspace.CurrentCamera
	if camera then
		camera.CFrame = targetCFrame
		camera.Focus = targetFocus
		camera.FieldOfView = cameraPayload.fieldOfView
	end
	restoreCharacterCamera(player)

	for _ = 1, AFKRejoinConfig.CameraZoomRestoreFrames do
		if cameraRestoreToken ~= token then
			cleanupZoomLimits()
			return
		end
		local currentCamera = Workspace.CurrentCamera
		if currentCamera then
			currentCamera.FieldOfView = cameraPayload.fieldOfView
		end
		RunService.RenderStepped:Wait()
	end

	cleanupZoomLimits()
end

function AFKRejoinController.start()
	if started then
		return
	end
	started = true

	local player = Players.LocalPlayer
	local requestRemote = Remotes.get(Remotes.Names.AFKRejoinRequest)
	local restoreRemote = Remotes.get(Remotes.Names.AFKRejoinRestore)

	RuntimeGuard.Connect(UserInputService.InputBegan, "AFKRejoinController.InputBegan", function()
		requestedThisIdle = false
		cancelCameraRestore()
	end)
	RuntimeGuard.Connect(UserInputService.InputChanged, "AFKRejoinController.InputChanged", function()
		requestedThisIdle = false
		cancelCameraRestore()
	end)
	RuntimeGuard.Connect(player.Idled, "AFKRejoinController.Idled", function(idleSeconds)
		if requestedThisIdle or (tonumber(idleSeconds) or 0) < AFKRejoinConfig.IdleSeconds then
			return
		end
		requestedThisIdle = true
		requestRemote:FireServer(buildCameraPayload(player))
	end)

	RuntimeGuard.Connect(restoreRemote.OnClientEvent, "AFKRejoinController.Restore", function(payload)
		RuntimeGuard.Spawn("AFKRejoinController.RestoreCamera", restoreCamera, player, payload)
	end)
end

return AFKRejoinController
