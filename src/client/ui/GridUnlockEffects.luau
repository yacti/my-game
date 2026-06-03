local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local GridUnlockEffect = Remotes.get(Remotes.Names.GridUnlockEffect)

local GridUnlockEffects = {}

local FLOOR_FADE_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FENCE_FADE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FENCE_DROP_TWEEN = TweenInfo.new(0.72, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
local FENCE_DROP_HEIGHT = 3.25
local FENCE_STAGGER_SECONDS = 0.035
local VISIBILITY_POLL_ATTEMPTS = 8
local VISIBILITY_POLL_INTERVAL = 0.05

local activeTweens = setmetatable({}, { __mode = "k" })

local function cancelTweens(instance)
	local tweens = activeTweens[instance]
	if not tweens then return end

	for _, tween in ipairs(tweens) do
		tween:Cancel()
	end
	activeTweens[instance] = nil
end

local function trackTween(instance, tween)
	activeTweens[instance] = activeTweens[instance] or {}
	table.insert(activeTweens[instance], tween)
	tween.Completed:Connect(function()
		local tweens = activeTweens[instance]
		if not tweens then return end

		for index, existing in ipairs(tweens) do
			if existing == tween then
				table.remove(tweens, index)
				break
			end
		end
		if #tweens == 0 then
			activeTweens[instance] = nil
		end
	end)
end

local function tween(instance, tweenInfo, properties)
	local created = TweenService:Create(instance, tweenInfo, properties)
	trackTween(instance, created)
	created:Play()
	return created
end

local function hasVisiblePart(instance)
	if instance:IsA("BasePart") then
		return instance.Transparency < 1
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Transparency < 1 then
			return true
		end
	end
	return false
end

local function addUnique(list, seen, instance)
	if not instance or seen[instance] then return end
	seen[instance] = true
	list[#list + 1] = instance
end

local function collectFenceRoots(gridPart)
	local roots = {}
	local seen = {}

	for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
		local fence = gridPart:FindFirstChild("Fence" .. tostring(sideNumber))
		if fence and hasVisiblePart(fence) then
			addUnique(roots, seen, fence)
		end
	end

	for cornerName in pairs(PlotGrid.Corners) do
		local corner = gridPart:FindFirstChild(cornerName)
		if corner and hasVisiblePart(corner) then
			addUnique(roots, seen, corner)
		end
	end

	return roots
end

local function collectDescendants(root, className)
	local results = {}
	local seen = {}
	if root:IsA(className) then
		addUnique(results, seen, root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA(className) then
			addUnique(results, seen, descendant)
		end
	end
	return results
end

local function fadeVisual(instance, tweenInfo)
	if instance.Parent == nil then return end

	local finalTransparency = instance.Transparency
	if finalTransparency >= 1 then return end

	cancelTweens(instance)
	instance.Transparency = 1
	tween(instance, tweenInfo, {
		Transparency = finalTransparency,
	})
end

local function animateFloor(gridPart)
	fadeVisual(gridPart, FLOOR_FADE_TWEEN)
end

local function animateFencePart(part, delaySeconds)
	if part.Parent == nil then return end

	local finalCFrame = part.CFrame
	local finalTransparency = part.Transparency
	if finalTransparency >= 1 then return end

	cancelTweens(part)
	part.CFrame = finalCFrame + Vector3.new(0, FENCE_DROP_HEIGHT, 0)
	part.Transparency = 1

	task.delay(delaySeconds, function()
		RuntimeGuard.Run("GridUnlockEffects.AnimateFencePartDelayed", function()
			if part.Parent == nil then return end
			tween(part, FENCE_DROP_TWEEN, {
				CFrame = finalCFrame,
			})
			tween(part, FENCE_FADE_TWEEN, {
				Transparency = finalTransparency,
			})
		end)
	end)
end

local function animateFenceVisuals(root, delaySeconds)
	for _, visual in ipairs(collectDescendants(root, "Decal")) do
		task.delay(delaySeconds, function()
			RuntimeGuard.Run("GridUnlockEffects.FadeDecalDelayed", fadeVisual, visual, FENCE_FADE_TWEEN)
		end)
	end
	for _, visual in ipairs(collectDescendants(root, "Texture")) do
		task.delay(delaySeconds, function()
			RuntimeGuard.Run("GridUnlockEffects.FadeTextureDelayed", fadeVisual, visual, FENCE_FADE_TWEEN)
		end)
	end
end

local function animateFenceRoots(roots)
	for index, root in ipairs(roots) do
		local delaySeconds = (index - 1) * FENCE_STAGGER_SECONDS
		for _, part in ipairs(collectDescendants(root, "BasePart")) do
			animateFencePart(part, delaySeconds)
		end
		animateFenceVisuals(root, delaySeconds)
	end
end

local function waitForFloorVisible(gridPart)
	for _ = 1, VISIBILITY_POLL_ATTEMPTS do
		if not (gridPart and gridPart.Parent) then
			return false
		end
		if gridPart.Transparency < 1 then
			return true
		end
		task.wait(VISIBILITY_POLL_INTERVAL)
	end
	return gridPart ~= nil and gridPart.Parent ~= nil and gridPart.Transparency < 1
end

local function waitForFenceRoots(gridPart)
	for _ = 1, VISIBILITY_POLL_ATTEMPTS do
		if not (gridPart and gridPart.Parent) then
			return {}
		end

		local roots = collectFenceRoots(gridPart)
		if #roots > 0 then
			return roots
		end
		task.wait(VISIBILITY_POLL_INTERVAL)
	end
	return gridPart and gridPart.Parent and collectFenceRoots(gridPart) or {}
end

local function playUnlockEffect(gridPart)
	if not (gridPart and gridPart:IsA("BasePart") and gridPart:IsDescendantOf(Workspace)) then
		return
	end
	if not PlotGrid.IsUnlockableGridPart(gridPart) then
		return
	end

	if waitForFloorVisible(gridPart) then
		animateFloor(gridPart)
	end
	animateFenceRoots(waitForFenceRoots(gridPart))
end

function GridUnlockEffects.start()
	RuntimeGuard.Connect(GridUnlockEffect.OnClientEvent, "GridUnlockEffects.Event", function(gridPart)
		RuntimeGuard.Spawn("GridUnlockEffects.Play", playUnlockEffect, gridPart)
	end)
end

return GridUnlockEffects
