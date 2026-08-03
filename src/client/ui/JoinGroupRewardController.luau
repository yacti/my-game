local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GroupReward = require(Shared:WaitForChild("GroupReward"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Notifications = require(script.Parent:WaitForChild("Notifications"))
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
local promptOpen = false

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

-- The stand's Collect prompt is server-owned, but PromptJoinAsync has no server
-- counterpart: it only ever prompts its own local player. So a non-member's
-- trigger comes back to us as a request to open Roblox's native join modal, and
-- the answer goes back for the server to verify and act on.
local function promptJoinGroup(joinedRemote)
	if promptOpen then
		return
	end
	promptOpen = true
	local ok, status = pcall(function()
		return GroupService:PromptJoinAsync(GroupReward.GroupId)
	end)
	promptOpen = false

	if not ok then
		warn("[JoinGroupRewardController] PromptJoinAsync failed: " .. tostring(status))
		Notifications.show({
			text = GroupReward.JoinPromptFailedMessage,
			kind = NotificationConfig.Kinds.Error,
		})
		return
	end

	if status == Enum.GroupMembershipStatus.Joined or status == Enum.GroupMembershipStatus.AlreadyMember then
		-- Only an intent: the server re-checks membership against the web
		-- endpoint before it grants anything.
		joinedRemote:FireServer()
	elseif status == Enum.GroupMembershipStatus.JoinRequestPending then
		Notifications.show({
			text = GroupReward.JoinPendingMessage,
			kind = NotificationConfig.Kinds.Info,
		})
	else
		-- None: they closed the modal, or they are not eligible to join.
		Notifications.show({
			text = GroupReward.NotInGroupMessage,
			kind = NotificationConfig.Kinds.Error,
		})
	end
end

function JoinGroupRewardController.start()
	if started then
		return
	end
	started = true

	local joinedRemote = Remotes.get(Remotes.Names.JoinGroupRewardRequest)
	RuntimeGuard.Connect(Remotes.get(Remotes.Names.JoinGroupPrompt).OnClientEvent, "JoinGroupRewardController.JoinPrompt", function()
		promptJoinGroup(joinedRemote)
	end)

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
