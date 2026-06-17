local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GroupReward = require(Shared:WaitForChild("GroupReward"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))

local JoinGroupRewardController = {}

local WAIT_SECONDS = 10
local ROTATION_RADIANS_PER_SECOND = math.rad(18)

local started = false
local model = nil
local visual = nil
local renderConnection = nil
local destroyingConnection = nil
local stateConnection = nil

local function findVisual()
	if visual and visual.Parent then
		return visual
	end
	visual = model and model:FindFirstChild(GroupReward.VisualName, true) or nil
	return visual
end

local function rotateVisual(deltaTime)
	local target = findVisual()
	if not target then
		return
	end
	local delta = CFrame.Angles(0, ROTATION_RADIANS_PER_SECOND * deltaTime, 0)
	if target:IsA("BasePart") then
		target.CFrame = target.CFrame * delta
	elseif target:IsA("Model") then
		target:PivotTo(target:GetPivot() * delta)
	end
end

local function disconnect()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if destroyingConnection then
		destroyingConnection:Disconnect()
		destroyingConnection = nil
	end
	if stateConnection then
		stateConnection:Disconnect()
		stateConnection = nil
	end
end

local function destroyRewardModel()
	local target = model
	model = nil
	visual = nil
	if target and target.Parent then
		target:Destroy()
	end
	disconnect()
end

function JoinGroupRewardController.start()
	if started then
		return
	end
	started = true

	local found = Workspace:WaitForChild(GroupReward.ModelName, WAIT_SECONDS)
	if not (found and found:IsA("Model")) then
		warn("[JoinGroupRewardController] Missing Workspace." .. GroupReward.ModelName .. " Model")
		return
	end
	model = found
	visual = findVisual()

	destroyingConnection = RuntimeGuard.Connect(model.Destroying, "JoinGroupRewardController.Destroying", disconnect)
	stateConnection = PlayerStateStore.Observe(PlayerStateStore.Fields.JoinGroupRewardCollected, function(value)
		if value == true then
			destroyRewardModel()
		end
	end)
	if PlayerStateStore.Get(PlayerStateStore.Fields.JoinGroupRewardCollected) == true then
		destroyRewardModel()
		return
	end

	renderConnection = RuntimeGuard.Connect(RunService.RenderStepped, "JoinGroupRewardController.Rotate", function(deltaTime)
		if not (model and model.Parent) then
			disconnect()
			return
		end
		rotateVisual(deltaTime)
	end)
end

return JoinGroupRewardController
