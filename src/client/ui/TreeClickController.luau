-- Client input bridge for tree clicks. Server tree setup remains authoritative:
-- this controller only resolves an owner-plot tree from the click ray and sends
-- the same shake intent that enters Trees.luau's ClickDetector path.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local FeedPlacement = require(script.Parent:WaitForChild("FeedPlacement"))
local PlacementInput = require(script.Parent:WaitForChild("PlacementInput"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))

local TreeClickController = {}

local TREE_SHAKE_CLICK_DISTANCE = 24
local TREE_SHAKE_RAY_DISTANCE = 500
local TREE_SHAKE_HOLD_INTERVAL = 0.2
local TREE_CLICK_TARGET_NAME = "LeafShake"
local TREE_SHAKE_GAMEPAD_KEYCODE = Enum.KeyCode.ButtonR2

local player = Players.LocalPlayer
local TreeClickerRequest = Remotes.get(Remotes.Names.TreeClickerRequest)
local activeTreeHold = nil

local function isEditMode()
	return player:GetAttribute("EditMode") == true
end

local function isOfflineProgressPending()
	return player:GetAttribute(State.Player.OfflineProgressPending) == true
end

local function playerRootPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function equippedTool()
	local character = player.Character
	return character and character:FindFirstChildWhichIsA("Tool") or nil
end

local function getPlot()
	return PlotResolver.ResolveForPlayer(player)
end

local function feedMachineClass(machine)
	local feedClass = machine:GetAttribute(State.Feed.Class)
	if type(feedClass) == "string" and feedClass ~= "" then
		return feedClass
	end
	return nil
end

local function leafShakePart(tree)
	local part = tree and tree:FindFirstChild(TREE_CLICK_TARGET_NAME, true)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function isTreeClickTargetHit(tree, hit)
	local leafShake = leafShakePart(tree)
	if leafShake and (hit == leafShake or hit:IsDescendantOf(leafShake)) then
		return true
	end

	local primary = tree.PrimaryPart
	return primary ~= nil and (hit == primary or hit:IsDescendantOf(primary))
end

local function treeFromHit(instance, plot)
	local current = instance
	while current and current ~= plot do
		if current:IsA("Model") and feedMachineClass(current) == "Tree" then
			if isTreeClickTargetHit(current, instance) then
				return current
			end
			return nil
		end
		current = current.Parent
	end
	return nil
end

local function isGamepadTreeShakeInput(input)
	return input.KeyCode == TREE_SHAKE_GAMEPAD_KEYCODE
		and PlacementInput.IsGamepadInputType(input.UserInputType)
end

local function screenPositionForClickInput(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y)
	end
	if isGamepadTreeShakeInput(input) then
		return UserInputService:GetMouseLocation()
	end
	return nil
end

local function treeFromInput(input)
	local screenPosition = screenPositionForClickInput(input)
	local camera = Workspace.CurrentCamera
	local plot = getPlot()
	if not (screenPosition and camera and plot) then
		return nil
	end

	local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { plot }
	params.IgnoreWater = true

	local result = Workspace:Raycast(ray.Origin, ray.Direction * TREE_SHAKE_RAY_DISTANCE, params)
	return result and treeFromHit(result.Instance, plot) or nil
end

local function canShakeTree(tree)
	if isOfflineProgressPending() or FeedPlacement.IsPlacementActive() or isEditMode() then
		return false
	end
	if not (tree and tree:IsA("Model") and tree.Parent ~= nil) then
		return false
	end

	local plot = getPlot()
	if not (plot and tree:IsDescendantOf(plot)) then
		return false
	end

	local rootPosition = playerRootPosition()
	local primary = tree.PrimaryPart
	local treePosition = primary and primary.Position or nil
	if not (rootPosition and treePosition) then
		return false
	end
	if (treePosition - rootPosition).Magnitude > TREE_SHAKE_CLICK_DISTANCE then
		return false
	end

	return true
end

local function triggerTreeShake(tree)
	if not canShakeTree(tree) then
		return false
	end

	TreeClickerRequest:FireServer(tree)
	return true
end

local function triggerTreeShakeFromInput(input)
	return triggerTreeShake(treeFromInput(input))
end

local function isTreeShakeGuiBlocked(input)
	local screenPosition = screenPositionForClickInput(input)
	return screenPosition ~= nil and PlacementInput.IsInteractiveGuiAt(screenPosition)
end

local function beginTreeHold(input)
	if activeTreeHold ~= nil then
		return
	end
	if not isGamepadTreeShakeInput(input) then
		return
	end
	if UserInputService:GetFocusedTextBox() ~= nil or isTreeShakeGuiBlocked(input) then
		return
	end

	local tree = treeFromInput(input)
	if not triggerTreeShake(tree) then
		return
	end

	activeTreeHold = {
		inputType = input.UserInputType,
		keyCode = input.KeyCode,
		nextActionAt = os.clock() + TREE_SHAKE_HOLD_INTERVAL,
		tree = tree,
	}
end

local function endTreeHold(input)
	if activeTreeHold == nil then
		return
	end
	if input.UserInputType ~= activeTreeHold.inputType or input.KeyCode ~= activeTreeHold.keyCode then
		return
	end
	activeTreeHold = nil
end

local function isTreeHoldInputStillDown()
	if activeTreeHold == nil then
		return false
	end
	local ok, isDown = pcall(function()
		return UserInputService:IsGamepadButtonDown(activeTreeHold.inputType, activeTreeHold.keyCode)
	end)
	return ok and isDown == true
end

local function stepTreeHold()
	if activeTreeHold == nil then
		return
	end
	if not isTreeHoldInputStillDown() then
		activeTreeHold = nil
		return
	end

	local now = os.clock()
	if now < activeTreeHold.nextActionAt then
		return
	end
	if triggerTreeShake(activeTreeHold.tree) then
		activeTreeHold.nextActionAt = now + TREE_SHAKE_HOLD_INTERVAL
	else
		activeTreeHold = nil
	end
end

function TreeClickController.start()
	RuntimeGuard.Connect(UserInputService.InputBegan, "TreeClickController.InputBegan", function(input, gameProcessed)
		if isGamepadTreeShakeInput(input) then
			RuntimeGuard.Run("TreeClickController.BeginTreeHold", beginTreeHold, input)
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if not equippedTool() then
			return
		end
		if gameProcessed then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if isTreeShakeGuiBlocked(input) then
			return
		end
		RuntimeGuard.Run("TreeClickController.TriggerTreeShake", triggerTreeShakeFromInput, input)
	end)
	RuntimeGuard.Connect(UserInputService.InputEnded, "TreeClickController.InputEnded", function(input)
		RuntimeGuard.Run("TreeClickController.EndTreeHold", endTreeHold, input)
	end)
	RuntimeGuard.Connect(RunService.Heartbeat, "TreeClickController.Heartbeat", function()
		RuntimeGuard.Run("TreeClickController.StepTreeHold", stepTreeHold)
	end)
end

return TreeClickController
