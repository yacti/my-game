-- Client input bridge for tree clicks. Server tree setup remains authoritative:
-- this controller only resolves an owner-plot tree from the click ray and sends
-- the same shake intent that enters Trees.luau's ClickDetector path.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
local TREE_CLICK_TARGET_NAME = "LeafShake"

local player = Players.LocalPlayer
local TreeClickerRequest = Remotes.get(Remotes.Names.TreeClickerRequest)

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

local function screenPositionForClickInput(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y)
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

local function triggerTreeShakeFromInput(input)
	if isOfflineProgressPending() or FeedPlacement.IsPlacementActive() or isEditMode() then
		return
	end

	local tree = treeFromInput(input)
	if not tree then
		return
	end

	local rootPosition = playerRootPosition()
	local primary = tree.PrimaryPart
	local treePosition = primary and primary.Position or nil
	if not (rootPosition and treePosition) then
		return
	end
	if (treePosition - rootPosition).Magnitude > TREE_SHAKE_CLICK_DISTANCE then
		return
	end

	TreeClickerRequest:FireServer(tree)
end

function TreeClickController.start()
	RuntimeGuard.Connect(UserInputService.InputBegan, "TreeClickController.InputBegan", function(input, gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if not equippedTool() then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if PlacementInput.IsInteractiveGuiAt(input.Position) then
			return
		end
		RuntimeGuard.Run("TreeClickController.TriggerTreeShake", triggerTreeShakeFromInput, input)
	end)
end

return TreeClickController
