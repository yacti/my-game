local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local PlotGrid = require(Shared:WaitForChild("PlotGrid"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local FeedPlacement = require(script.Parent:WaitForChild("FeedPlacement"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local RollController = require(script.Parent:WaitForChild("RollController"))

local OnboardingController = {}

local ARROW_HEIGHT = 6
local SEED_PREVIEW_ARROW_HEIGHT = 9.5
local PET_ARROW_HEIGHT = 9
local ARROW_BOB_HEIGHT = 0.75
local ARROW_BOB_PERIOD = 1.15
local ARROW_FOLLOW_SPEED = 7
local ARROW_Z_ROTATION_SPEED = math.rad(180)
local CLICKER_POP_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICKER_SETTLE_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLICKER_GROUND_OFFSET_Y = 2
local PATCH_SPOT_SIZE = 4
local PATCH_SPOT_QUERY_HEIGHT = 4
local PATCH_SPOT_QUERY_INSET = 0.05
local PATCH_SPOT_STEP = 2
local PLANT_FRONT_INSET = 4
local FINAL_NOTE_FADE_TWEEN = TweenInfo.new(Onboarding.FinalNoteFadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Stages with no floating arrow: clicker billboard stages and seed placement
-- stages where the target is already clear.
local NO_MAIN_ARROW_STAGES = {
	[Onboarding.Stages.CollectApple] = true,
	[Onboarding.Stages.ShakeAppleTree] = true,
	[Onboarding.Stages.PlantAppleTreeSeed] = true,
	[Onboarding.Stages.PlantPumpkinSeed] = true,
}

local player = Players.LocalPlayer

local started = false
local currentStage = Onboarding.Stages.Complete
local currentProgress = {}
local mainArrow = nil
local mainBaseCFrame = nil
local mainTargetCFrame = nil
local mainArrowStartTime = 0
local fruitArrows = {}
local templateRotation = CFrame.new()
local clickerBillboard = nil
local clickerAnchor = nil
local clickerBaseSize = nil
local lastClickCount = 0
local patchSpotCache = nil
local warnedMissingArrow = false
local warnedMissingClicker = false
local finalNoteToken = 0
local finalNoteTweens = {}
local finalNoteTransparency = setmetatable({}, { __mode = "k" })
local targetCache = nil
local plotFloor = nil

local function playerGui()
	return player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui")
end

local function hudOnboardingFrame()
	local gui = playerGui():FindFirstChild("HUD")
	local frame = gui and gui:FindFirstChild("Onboarding")
	if frame and frame:IsA("Frame") then
		return frame
	end
	return nil
end

local function onboardingProgressBar(frame)
	if not frame then
		return nil, nil
	end
	local bar = frame:FindFirstChild("Bar")
	if not (bar and bar:IsA("GuiObject")) then
		return nil, nil
	end
	local fill = bar:FindFirstChild("Fill")
	if not (fill and fill:IsA("GuiObject")) then
		return bar, nil
	end
	return bar, fill
end

local function updateHudProgressBar()
	local frame = hudOnboardingFrame()
	if not frame then
		return
	end
	local bar, fill = onboardingProgressBar(frame)
	if bar then
		bar.Visible = false
	end
	if fill then
		fill.Size = UDim2.new(0, 0, 1, 0)
	end
end

local function cancelFinalNoteTweens()
	for _, tween in ipairs(finalNoteTweens) do
		tween:Cancel()
	end
	finalNoteTweens = {}
end

local function transparencyProperties(instance)
	local properties = {}
	if instance:IsA("GuiObject") then
		properties.BackgroundTransparency = instance.BackgroundTransparency
	end
	if instance:IsA("TextLabel") or instance:IsA("TextButton") then
		properties.TextTransparency = instance.TextTransparency
		properties.TextStrokeTransparency = instance.TextStrokeTransparency
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		properties.ImageTransparency = instance.ImageTransparency
	end
	if instance:IsA("UIStroke") then
		properties.Transparency = instance.Transparency
	end
	return next(properties) and properties or nil
end

local function eachTransparencyTarget(root, callback)
	callback(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		callback(descendant)
	end
end

local function captureFinalNoteTransparency(frame)
	eachTransparencyTarget(frame, function(instance)
		if finalNoteTransparency[instance] == nil then
			finalNoteTransparency[instance] = transparencyProperties(instance)
		end
	end)
end

local function restoreFinalNoteTransparency(frame)
	cancelFinalNoteTweens()
	eachTransparencyTarget(frame, function(instance)
		local properties = finalNoteTransparency[instance]
		if not properties then
			return
		end
		for propertyName, value in pairs(properties) do
			instance[propertyName] = value
		end
	end)
end

local function fadeFinalNote(frame, token)
	if not (frame and frame.Parent and token == finalNoteToken and currentStage == Onboarding.Stages.FinalNote) then
		return
	end

	local remaining = 0
	local function onTweenComplete(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed then
			return
		end
		remaining -= 1
		if remaining <= 0 and token == finalNoteToken and currentStage == Onboarding.Stages.FinalNote and frame.Parent then
			frame.Visible = false
		end
	end

	eachTransparencyTarget(frame, function(instance)
		local baseProperties = finalNoteTransparency[instance]
		if not baseProperties then
			return
		end

		local targetProperties = {}
		for propertyName in pairs(baseProperties) do
			targetProperties[propertyName] = 1
		end

		remaining += 1
		local fade = TweenService:Create(instance, FINAL_NOTE_FADE_TWEEN, targetProperties)
		finalNoteTweens[#finalNoteTweens + 1] = fade
		RuntimeGuard.Connect(fade.Completed, "OnboardingController.FinalNoteFadeCompleted", onTweenComplete)
		fade:Play()
	end)

	if remaining == 0 then
		frame.Visible = false
	end
end

local function scheduleFinalNoteFade(frame)
	local token = finalNoteToken
	task.delay(Onboarding.FinalNoteDisplaySeconds, function()
		fadeFinalNote(frame, token)
	end)
end

local function setHudText(stage)
	local frame = hudOnboardingFrame()
	if not frame then
		return
	end
	local active = Onboarding.IsActive(stage)
	finalNoteToken += 1
	if stage == Onboarding.Stages.FinalNote then
		captureFinalNoteTransparency(frame)
		restoreFinalNoteTransparency(frame)
	else
		restoreFinalNoteTransparency(frame)
	end
	frame.Visible = active
	local label = frame:FindFirstChild("OnboardingText")
	if label and label:IsA("TextLabel") then
		label.RichText = Onboarding.UsesRichText(stage)
		label.Text = Onboarding.RichTextFor(stage)
	end
	updateHudProgressBar()
	if stage == Onboarding.Stages.FinalNote then
		scheduleFinalNoteFade(frame)
	end
end

local function arrowTemplate()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local misc = assets and assets:FindFirstChild("Misc")
	local template = misc and misc:FindFirstChild("OnboardingArrow")
	if template and template:IsA("Model") then
		return template
	end
	if not warnedMissingArrow then
		warn("[OnboardingController] Missing ReplicatedStorage.Assets.Misc.OnboardingArrow Model")
		warnedMissingArrow = true
	end
	return nil
end

local function prepareArrow(arrow)
	for _, descendant in ipairs(arrow:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
end

local function cloneArrow(name)
	local template = arrowTemplate()
	if not template then
		return nil
	end
	local pivot = template:GetPivot()
	templateRotation = pivot - pivot.Position
	local clone = template:Clone()
	clone.Name = name or "__OnboardingArrow"
	prepareArrow(clone)
	clone.Parent = workspace
	return clone
end

local function ensureMainArrow()
	if mainArrow and mainArrow.Parent then
		return mainArrow
	end
	mainArrow = cloneArrow("__OnboardingArrow")
	if mainArrow then
		local pivot = mainArrow:GetPivot()
		templateRotation = pivot - pivot.Position
		mainBaseCFrame = nil
		mainTargetCFrame = nil
		mainArrowStartTime = os.clock()
	end
	return mainArrow
end

local function destroyMainArrow()
	if mainArrow then
		mainArrow:Destroy()
		mainArrow = nil
	end
	mainBaseCFrame = nil
	mainTargetCFrame = nil
	mainArrowStartTime = 0
end

local function destroyFruitArrows()
	for target, record in pairs(fruitArrows) do
		if record.arrow then
			record.arrow:Destroy()
		end
		fruitArrows[target] = nil
	end
end

local function plot()
	return PlotResolver.ResolveForPlayer(player)
end

local function disconnectTargetCache()
	if not targetCache then return end
	for _, conn in ipairs(targetCache.conns) do
		conn:Disconnect()
	end
	targetCache = nil
end

local function isCachedFeed(instance)
	local feedType = instance and instance:GetAttribute(State.Feed.Type)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and type(feedType) == "string"
		and feedType ~= ""
		and instance:GetAttribute(State.Feed.Index) ~= nil
end

local function isCachedPet(instance)
	return instance and instance:IsA("Model") and instance:GetAttribute(State.Pet.Index) ~= nil
end

local function isAppleGroundFruit(instance)
	return (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.TreeClicker.GroundPile) == true
		and instance:GetAttribute(State.Food.Id) == Onboarding.FoodIds.Apple
		and instance:GetAttribute(State.TreeClicker.LocalVisual) ~= true
end

local function removeArrayValue(array, value)
	for index = #array, 1, -1 do
		if array[index] == value then
			table.remove(array, index)
		end
	end
end

local function watchGroundCandidate(cache, instance)
	if cache.groundCandidateConns[instance] then return end
	if not (instance:IsA("BasePart") or instance:IsA("Model")) then return end
	local name = instance.Name
	if name:match("^BaseFoodGround%d+$") == nil and instance:GetAttribute(State.TreeClicker.GroundPile) ~= true then
		return
	end

	local function refresh()
		if isAppleGroundFruit(instance) then
			if not table.find(cache.appleGroundFruits, instance) then
				cache.appleGroundFruits[#cache.appleGroundFruits + 1] = instance
			end
		else
			removeArrayValue(cache.appleGroundFruits, instance)
		end
	end

	local conns = {}
	conns[#conns + 1] = RuntimeGuard.Connect(instance:GetAttributeChangedSignal(State.TreeClicker.GroundPile), "OnboardingController.GroundPileChanged", refresh)
	conns[#conns + 1] = RuntimeGuard.Connect(instance:GetAttributeChangedSignal(State.Food.Id), "OnboardingController.GroundFoodChanged", refresh)
	conns[#conns + 1] = RuntimeGuard.Connect(instance.AncestryChanged, "OnboardingController.GroundAncestryChanged", function()
		if not instance:IsDescendantOf(cache.plot) then
			removeArrayValue(cache.appleGroundFruits, instance)
			for _, conn in ipairs(conns) do
				conn:Disconnect()
			end
			cache.groundCandidateConns[instance] = nil
		end
	end)
	cache.groundCandidateConns[instance] = conns
	for _, conn in ipairs(conns) do
		cache.conns[#cache.conns + 1] = conn
	end
	refresh()
end

local function addTargetCandidate(cache, instance)
	if isCachedFeed(instance) then
		cache.feedByType[instance:GetAttribute(State.Feed.Type)] = instance
	end
	if isCachedPet(instance) and not cache.firstPet then
		cache.firstPet = instance
	end
	if instance:IsA("BasePart") or instance:IsA("Model") then
		local parent = instance.Parent
		local machine = parent and parent.Parent
		if machine and machine:GetAttribute(State.Feed.Type) == Onboarding.FeedTypes.Pumpkin
			and instance:GetAttribute(State.Food.Id) == Onboarding.FoodIds.Pumpkin then
			cache.pumpkinTarget = instance
		end
		watchGroundCandidate(cache, instance)
	end
end

local function removeTargetCandidate(cache, instance)
	for feedType, feed in pairs(cache.feedByType) do
		if feed == instance then
			cache.feedByType[feedType] = nil
		end
	end
	if cache.firstPet == instance then
		cache.firstPet = nil
	end
	if cache.pumpkinTarget == instance then
		cache.pumpkinTarget = nil
	end
	removeArrayValue(cache.appleGroundFruits, instance)
end

local function ensureTargetCache()
	local currentPlot = plot()
	if targetCache and targetCache.plot == currentPlot then
		return targetCache
	end
	disconnectTargetCache()
	if not currentPlot then return nil end

	local cache = {
		plot = currentPlot,
		feedByType = {},
		firstPet = nil,
		pumpkinTarget = nil,
		appleGroundFruits = {},
		groundCandidateConns = {},
		conns = {},
	}
	targetCache = cache
	for _, descendant in ipairs(currentPlot:GetDescendants()) do
		addTargetCandidate(cache, descendant)
	end
	cache.conns[#cache.conns + 1] = RuntimeGuard.Connect(currentPlot.DescendantAdded, "OnboardingController.PlotDescendantAdded", function(descendant)
		addTargetCandidate(cache, descendant)
	end)
	cache.conns[#cache.conns + 1] = RuntimeGuard.Connect(currentPlot.DescendantRemoving, "OnboardingController.PlotDescendantRemoving", function(descendant)
		removeTargetCandidate(cache, descendant)
	end)
	return cache
end

local function firstBasePart(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function instanceWorldCenter(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		local cframe = instance:GetBoundingBox()
		return cframe.Position
	end
	local part = firstBasePart(instance)
	return part and part.Position or nil
end

local function instancePosition(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

local function isVisibleTarget(instance)
	if instance:IsA("BasePart") then
		return instance.Transparency < 1
	end
	if instance:IsA("Model") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.Transparency < 1 then
				return true
			end
		end
	end
	return false
end

local function playerRootPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root.Position or nil
end

local function gridPartAt(currentPlot, x, z)
	if not currentPlot then return nil end
	for _, folderName in ipairs({ PlotGrid.Folders.Starter, PlotGrid.Folders.Unlockable }) do
		local folder = currentPlot:FindFirstChild(folderName)
		if folder then
			for _, child in ipairs(folder:GetChildren()) do
				if child:IsA("BasePart")
					and PlotGrid.NormalizeInteger(child:GetAttribute(PlotGrid.Attributes.X)) == x
					and PlotGrid.NormalizeInteger(child:GetAttribute(PlotGrid.Attributes.Z)) == z then
					return child
				end
			end
		end
	end
	return nil
end

local function addVisibleFenceCandidate(candidates, fence)
	if fence and (fence:IsA("BasePart") or fence:IsA("Model")) and isVisibleTarget(fence) then
		candidates[#candidates + 1] = fence
	end
end

local function visibleFencesForGridPart(gridPart)
	local candidates = {}
	if not PlotGrid.IsUnlockableGridPart(gridPart) then
		return candidates
	end

	for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
		addVisibleFenceCandidate(candidates, gridPart:FindFirstChild("Fence" .. tostring(sideNumber)))
	end

	local currentPlot = gridPart.Parent and gridPart.Parent.Parent or nil
	local x = PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.X))
	local z = PlotGrid.NormalizeInteger(gridPart:GetAttribute(PlotGrid.Attributes.Z))
	if not x or not z then
		return candidates
	end

	for _, sideNumber in ipairs(PlotGrid.SideNumbers) do
		local side = PlotGrid.SideByNumber[sideNumber]
		local neighbor = gridPartAt(currentPlot, x + side.dx, z + side.dz)
		local fence = neighbor and neighbor:FindFirstChild("Fence" .. tostring(side.opposite)) or nil
		addVisibleFenceCandidate(candidates, fence)
	end

	return candidates
end

local function nearestVisibleFenceForGridPart(gridPart)
	local candidates = visibleFencesForGridPart(gridPart)
	if #candidates == 0 then return nil end

	local rootPosition = playerRootPosition()
	if not rootPosition then
		return candidates[1]
	end

	local bestFence = candidates[1]
	local bestDistance = math.huge
	for _, fence in ipairs(candidates) do
		local center = instanceWorldCenter(fence)
		local distance = center and (center - rootPosition).Magnitude or math.huge
		if distance < bestDistance then
			bestFence = fence
			bestDistance = distance
		end
	end
	return bestFence
end

local function rollButton()
	local currentPlot = plot()
	local rollArea = currentPlot and currentPlot:FindFirstChild("RollArea")
	local buttonFolder = rollArea and rollArea:FindFirstChild("Button")
	local button = buttonFolder and buttonFolder:FindFirstChild("Button")
	return button and button:IsA("BasePart") and button or nil
end

local function isRollButtonStage(stage)
	return stage == Onboarding.Stages.RollAppleTreeSeed
		or stage == Onboarding.Stages.RollPumpkinSeed
end

local function starterAreaCenter()
	local currentPlot = plot()
	local starterArea = currentPlot and currentPlot:FindFirstChild("StarterArea")
	if not starterArea then
		return nil
	end

	local sum = Vector3.zero
	local count = 0
	for _, child in ipairs(starterArea:GetChildren()) do
		if child:IsA("BasePart") then
			sum += child.Position
			count += 1
		end
	end
	if count == 0 then
		return nil
	end
	return sum / count
end

local function starterAreaFrontPosition()
	local floor, currentPlot = plotFloor()
	local starterArea = currentPlot and currentPlot:FindFirstChild("StarterArea")
	if not (floor and starterArea) then
		return nil
	end

	local minX, maxX = math.huge, -math.huge
	local minZ = math.huge
	local count = 0
	for _, child in ipairs(starterArea:GetChildren()) do
		if child:IsA("BasePart") then
			local half = child.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					local world = child.CFrame:PointToWorldSpace(Vector3.new(sx * half.X, 0, sz * half.Z))
					local localPoint = floor.CFrame:PointToObjectSpace(world)
					minX = math.min(minX, localPoint.X)
					maxX = math.max(maxX, localPoint.X)
					minZ = math.min(minZ, localPoint.Z)
				end
			end
			count += 1
		end
	end
	if count == 0 then
		return nil
	end

	return floor.CFrame:PointToWorldSpace(Vector3.new((minX + maxX) / 2, floor.Size.Y / 2, minZ + PLANT_FRONT_INSET))
end

local function feedMachine(feedType)
	local cache = ensureTargetCache()
	local machine = cache and cache.feedByType[feedType] or nil
	return machine and machine.Parent and machine or nil
end

local function isGrowingSeedFeed(instance)
	return instance ~= nil and instance:GetAttribute(State.Seed.Phase) == "GrowingSeed"
end

local function pumpkinTarget()
	local machine = feedMachine(Onboarding.FeedTypes.Pumpkin)
	if not machine then
		return nil
	end
	local cache = ensureTargetCache()
	local target = cache and cache.pumpkinTarget or nil
	return target and target.Parent and target or machine
end

local function petTarget()
	local cache = ensureTargetCache()
	local target = cache and cache.firstPet or nil
	return target and target.Parent and target or nil
end

local function expandFarmTarget()
	local targetGrid = Onboarding.ExpandFarmGrid
	local gridPart = gridPartAt(plot(), targetGrid.X, targetGrid.Z)
	if not gridPart then
		return nil
	end
	local fence = nearestVisibleFenceForGridPart(gridPart)
	local position = instanceWorldCenter(fence or gridPart)
	return position and {
		position = position,
	} or nil
end

local function appleTree()
	local tree = feedMachine(Onboarding.FeedTypes.AppleTree)
	if isGrowingSeedFeed(tree) then
		return nil
	end
	return tree
end

local function treePrimary()
	local tree = appleTree()
	return tree and tree:IsA("Model") and tree.PrimaryPart or firstBasePart(tree)
end

local function appleGroundFruits()
	local tree = appleTree()
	local fruits = {}
	if not tree then
		return fruits
	end
	local cache = ensureTargetCache()
	for _, fruit in ipairs(cache and cache.appleGroundFruits or {}) do
		if fruit.Parent and fruit:IsDescendantOf(tree) and isAppleGroundFruit(fruit) then
			fruits[#fruits + 1] = fruit
		end
	end
	return fruits
end

local function singleArrowTarget()
	if isRollButtonStage(currentStage) then
		return rollButton()
	end
	if currentStage == Onboarding.Stages.BuyPumpkinSeed then
		local reveal = RollController.GetActiveTutorialReveal(Onboarding.Seeds.Pumpkin)
		return reveal and { instance = reveal, arrowHeight = SEED_PREVIEW_ARROW_HEIGHT } or nil
	end
	if currentStage == Onboarding.Stages.BuyAppleTreeSeed then
		local reveal = RollController.GetActiveTutorialReveal(Onboarding.Seeds.AppleTree)
		return reveal and { instance = reveal, arrowHeight = SEED_PREVIEW_ARROW_HEIGHT } or nil
	end
	if currentStage == Onboarding.Stages.HarvestPumpkin then
		return pumpkinTarget()
	end
	if currentStage == Onboarding.Stages.ExpandFarm then
		return expandFarmTarget()
	end
	if currentStage == Onboarding.Stages.FeedPetPumpkin or currentStage == Onboarding.Stages.FeedPetApple then
		local pet = petTarget()
		return pet and { instance = pet, arrowHeight = PET_ARROW_HEIGHT } or nil
	end
	return nil
end

local function targetWorldPosition(target)
	if type(target) == "table" and typeof(target.position) == "Vector3" then
		return target.position
	end
	-- Table targets may track a live instance instead of a static position so
	-- per-stage arrowHeight overrides still follow a moving target.
	if type(target) == "table" then
		target = target.instance
		if target == nil then
			return nil
		end
	end
	local position = instancePosition(target)
	if position then
		return position
	end
	local part = firstBasePart(target)
	return part and part.Position or nil
end

local function cframeAbove(position, height)
	return CFrame.new(position + Vector3.new(0, height or ARROW_HEIGHT, 0)) * templateRotation
end

local function arrowHeightForTarget(target)
	return type(target) == "table" and tonumber(target.arrowHeight) or ARROW_HEIGHT
end

local function updateMainTarget()
	if NO_MAIN_ARROW_STAGES[currentStage] or not Onboarding.IsActive(currentStage) then
		destroyMainArrow()
		return
	end

	local target = singleArrowTarget()
	local position = targetWorldPosition(target)
	if not position then
		destroyMainArrow()
		return
	end

	if ensureMainArrow() then
		mainTargetCFrame = cframeAbove(position, arrowHeightForTarget(target))
		if not mainBaseCFrame then
			mainBaseCFrame = mainTargetCFrame
		end
	end
end

local function updateFruitTargets()
	if currentStage ~= Onboarding.Stages.CollectApple then
		destroyFruitArrows()
		return
	end

	local seen = {}
	for _, fruit in ipairs(appleGroundFruits()) do
		seen[fruit] = true
		local record = fruitArrows[fruit]
		if not record then
			local arrow = cloneArrow("__OnboardingFruitArrow")
			if arrow then
				record = {
					arrow = arrow,
					baseCFrame = nil,
					targetCFrame = nil,
					startTime = os.clock(),
				}
				fruitArrows[fruit] = record
			end
		end
		if record then
			local position = targetWorldPosition(fruit)
			if position then
				record.targetCFrame = cframeAbove(position)
				record.baseCFrame = record.baseCFrame or record.targetCFrame
			end
		end
	end

	for fruit, record in pairs(fruitArrows) do
		if not seen[fruit] or not fruit.Parent then
			if record.arrow then
				record.arrow:Destroy()
			end
			fruitArrows[fruit] = nil
		end
	end
end

plotFloor = function()
	local currentPlot = plot()
	local floor = currentPlot and currentPlot:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") then
		return floor, currentPlot
	end
	return nil, currentPlot
end

local function unlockedGridParts(currentPlot)
	local parts = {}
	if not currentPlot then return parts end
	for _, folderName in ipairs({ PlotGrid.Folders.Starter, PlotGrid.Folders.Unlockable }) do
		local folder = currentPlot:FindFirstChild(folderName)
		if folder then
			for _, child in ipairs(folder:GetChildren()) do
				if child:IsA("BasePart") and child:GetAttribute(State.Grid.Unlocked) == true then
					parts[#parts + 1] = child
				end
			end
		end
	end
	return parts
end

local function placeableHitboxRootFromPart(currentPlot, part)
	local current = part
	while current and current ~= currentPlot do
		local feedType = current:GetAttribute(State.Feed.Type)
		if type(feedType) == "string" and feedType ~= "" and current:GetAttribute(State.Feed.Index) then
			if current:IsA("BasePart") then return current end
			if current:IsA("Model") then return current end
			return nil
		end
		local cosmeticId = current:GetAttribute(State.Cosmetic.Id)
		if type(cosmeticId) == "string" and cosmeticId ~= "" and current:GetAttribute(State.Cosmetic.Index) then
			if current:IsA("BasePart") then return current end
			if current:IsA("Model") then return current end
			return nil
		end
		current = current.Parent
	end
	return nil
end

local function patchSpotOccupied(currentPlot, floor, lx, lz)
	local boxCFrame = floor.CFrame * CFrame.new(lx, floor.Size.Y / 2 + PATCH_SPOT_QUERY_HEIGHT / 2, lz)
	local boxSize = Vector3.new(
		PATCH_SPOT_SIZE - PATCH_SPOT_QUERY_INSET,
		PATCH_SPOT_QUERY_HEIGHT,
		PATCH_SPOT_SIZE - PATCH_SPOT_QUERY_INSET
	)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { currentPlot }
	for _, part in ipairs(workspace:GetPartBoundsInBox(boxCFrame, boxSize, params)) do
		if placeableHitboxRootFromPart(currentPlot, part) then
			return true
		end
	end
	return false
end

local function findFreePatchSpot(currentPlot, floor)
	local half = PATCH_SPOT_SIZE / 2
	-- Candidates are integer floor-local points (matching FeedPlacement's 1-stud
	-- snap) whose footprint fits inside a single unlocked grid part, so any
	-- hinted spot is a genuinely placeable cell.
	local candidates = {}
	for _, gridPart in ipairs(unlockedGridParts(currentPlot)) do
		local center = floor.CFrame:PointToObjectSpace(gridPart.Position)
		local minX = math.ceil(center.X - gridPart.Size.X / 2 + half)
		local maxX = math.floor(center.X + gridPart.Size.X / 2 - half)
		local minZ = math.ceil(center.Z - gridPart.Size.Z / 2 + half)
		local maxZ = math.floor(center.Z + gridPart.Size.Z / 2 - half)
		for lx = minX, maxX, PATCH_SPOT_STEP do
			for lz = minZ, maxZ, PATCH_SPOT_STEP do
				candidates[#candidates + 1] = { lx = lx, lz = lz }
			end
		end
	end

	local targetWorld = starterAreaFrontPosition() or starterAreaCenter()
	local targetLocal = targetWorld and floor.CFrame:PointToObjectSpace(targetWorld) or Vector3.zero
	table.sort(candidates, function(a, b)
		local distanceA = (a.lx - targetLocal.X) ^ 2 + (a.lz - targetLocal.Z) ^ 2
		local distanceB = (b.lx - targetLocal.X) ^ 2 + (b.lz - targetLocal.Z) ^ 2
		if distanceA ~= distanceB then
			return distanceA < distanceB
		end
		if a.lx ~= b.lx then
			return a.lx < b.lx
		end
		return a.lz < b.lz
	end)

	for _, candidate in ipairs(candidates) do
		if not patchSpotOccupied(currentPlot, floor, candidate.lx, candidate.lz) then
			return floor.CFrame:PointToWorldSpace(Vector3.new(candidate.lx, floor.Size.Y / 2, candidate.lz))
		end
	end
	return nil
end

local function freePatchSpotPosition()
	local floor, currentPlot = plotFloor()
	if not (floor and currentPlot) then
		return nil
	end
	if patchSpotCache and patchSpotCache.plot == currentPlot then
		return patchSpotCache.position or nil
	end
	local position = findFreePatchSpot(currentPlot, floor)
	patchSpotCache = { plot = currentPlot, position = position or false }
	return position
end

-- Projects the target onto the floor's top plane so the billboard floats a
-- consistent CLICKER_GROUND_OFFSET_Y above the ground regardless of whether
-- the input Y came from a grid-part center or the floor surface.
local function clickerFloorAnchor(worldPosition)
	local floor = plotFloor()
	if not floor then
		return nil
	end
	if not (clickerAnchor and clickerAnchor.Parent == floor) then
		if clickerAnchor then
			clickerAnchor:Destroy()
		end
		clickerAnchor = Instance.new("Attachment")
		clickerAnchor.Name = "__OnboardingClickerAnchor"
		clickerAnchor.Parent = floor
	end
	local floorLocal = floor.CFrame:PointToObjectSpace(worldPosition)
	clickerAnchor.WorldPosition = floor.CFrame:PointToWorldSpace(
		Vector3.new(floorLocal.X, floor.Size.Y / 2 + CLICKER_GROUND_OFFSET_Y, floorLocal.Z)
	)
	return clickerAnchor
end

-- The roll button carries a Studio-authored TutorialClicker Attachment marking
-- where the billboard should sit; fall back to the button part if absent.
local function rollClickerAdornee()
	local button = rollButton()
	if not button then
		return nil
	end
	local attachment = button:FindFirstChild("TutorialClicker")
	if attachment and attachment:IsA("Attachment") then
		return attachment
	end
	return button
end

local function clickerTarget()
	if currentStage == Onboarding.Stages.ShakeAppleTree then
		local primary = treePrimary()
		return primary and { adornee = primary, alwaysOnTop = true } or nil
	end
	if currentStage == Onboarding.Stages.RollAppleTreeSeed or currentStage == Onboarding.Stages.RollPumpkinSeed then
		local adornee = rollClickerAdornee()
		return adornee and { adornee = adornee } or nil
	end
	if currentStage == Onboarding.Stages.PlantAppleTreeSeed or currentStage == Onboarding.Stages.PlantPumpkinSeed then
		if FeedPlacement.HasActiveSelection() then
			return nil
		end
		local position
		if currentStage == Onboarding.Stages.PlantPumpkinSeed then
			position = freePatchSpotPosition() or starterAreaFrontPosition() or starterAreaCenter()
		else
			position = starterAreaFrontPosition() or starterAreaCenter()
		end
		local anchor = position and clickerFloorAnchor(position)
		return anchor and { adornee = anchor } or nil
	end
	return nil
end

local function destroyClicker()
	if clickerBillboard then
		clickerBillboard:Destroy()
		clickerBillboard = nil
	end
	if clickerAnchor then
		clickerAnchor:Destroy()
		clickerAnchor = nil
	end
	clickerBaseSize = nil
	lastClickCount = 0
end

local function ensureClicker()
	local target = clickerTarget()
	if not target then
		destroyClicker()
		return
	end
	if clickerBillboard and clickerBillboard.Parent then
		clickerBillboard.Adornee = target.adornee
		clickerBillboard.AlwaysOnTop = target.alwaysOnTop == true
		return
	end

	local template = BillboardGuiTemplates.Find("ClickerOnboarding")
	if not (template and template:IsA("BillboardGui")) then
		if not warnedMissingClicker then
			warn("[OnboardingController] Missing " .. BillboardGuiTemplates.Path("ClickerOnboarding") .. " BillboardGui")
			warnedMissingClicker = true
		end
		return
	end

	clickerBillboard = template:Clone()
	clickerBillboard.Name = "__OnboardingClicker"
	clickerBillboard.Adornee = target.adornee
	clickerBillboard.AlwaysOnTop = target.alwaysOnTop == true
	clickerBillboard.StudsOffset = Vector3.zero
	clickerBillboard.StudsOffsetWorldSpace = Vector3.zero
	clickerBillboard.Parent = playerGui()
	clickerBaseSize = clickerBillboard.Size
end

local function playClickerPop()
	if not (clickerBillboard and clickerBaseSize) then
		return
	end
	clickerBillboard.Size = UDim2.new(
		clickerBaseSize.X.Scale * 0.82,
		clickerBaseSize.X.Offset,
		clickerBaseSize.Y.Scale * 0.82,
		clickerBaseSize.Y.Offset
	)
	local grow = TweenService:Create(clickerBillboard, CLICKER_POP_TWEEN, { Size = clickerBaseSize })
	grow:Play()
	local connection
	connection = RuntimeGuard.Connect(grow.Completed, "OnboardingController.ClickerGrowCompleted", function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		if clickerBillboard then
			TweenService:Create(clickerBillboard, CLICKER_SETTLE_TWEEN, { Size = clickerBaseSize }):Play()
		end
	end)
end

local function updateClicker()
	ensureClicker()
	if currentStage ~= Onboarding.Stages.ShakeAppleTree then
		return
	end
	local clickCount = tonumber(currentProgress[Onboarding.ProgressKeys.TreeClickCount]) or 0
	if clickCount > lastClickCount then
		playClickerPop()
	end
	lastClickCount = clickCount
end

local function zSpin(startTime)
	local elapsed = os.clock() - (startTime or 0)
	return CFrame.Angles(0, 0, elapsed * ARROW_Z_ROTATION_SPEED)
end

local function pivotArrow(record, dt)
	if not (record.arrow and record.arrow.Parent and record.targetCFrame) then
		return
	end
	local alpha = math.clamp(dt * ARROW_FOLLOW_SPEED, 0, 1)
	record.baseCFrame = (record.baseCFrame or record.targetCFrame):Lerp(record.targetCFrame, alpha)
	local elapsed = os.clock() - (record.startTime or 0)
	local bob = math.sin((elapsed / ARROW_BOB_PERIOD) * math.pi * 2) * ARROW_BOB_HEIGHT
	record.arrow:PivotTo((record.baseCFrame + Vector3.new(0, bob, 0)) * zSpin(record.startTime))
end

local function step(dt)
	updateMainTarget()
	updateFruitTargets()
	updateClicker()

	if mainArrow and mainTargetCFrame then
		local alpha = math.clamp(dt * ARROW_FOLLOW_SPEED, 0, 1)
		mainBaseCFrame = (mainBaseCFrame or mainTargetCFrame):Lerp(mainTargetCFrame, alpha)
		local elapsed = os.clock() - mainArrowStartTime
		local bob = math.sin((elapsed / ARROW_BOB_PERIOD) * math.pi * 2) * ARROW_BOB_HEIGHT
		mainArrow:PivotTo((mainBaseCFrame + Vector3.new(0, bob, 0)) * zSpin(mainArrowStartTime))
	end

	for _, record in pairs(fruitArrows) do
		pivotArrow(record, dt)
	end
end

local function applyState(state)
	state = Onboarding.SanitizeState(state, Onboarding.CompleteState())
	if state.Stage ~= currentStage then
		patchSpotCache = nil
	end
	currentStage = state.Stage
	currentProgress = state.Progress or {}
	ensureTargetCache()
	setHudText(currentStage)
	if not Onboarding.IsActive(currentStage) then
		destroyMainArrow()
		destroyFruitArrows()
		destroyClicker()
	end
end

function OnboardingController.start()
	if started then
		return
	end
	started = true

	applyState(PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding))
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, function(state)
		applyState(state)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "OnboardingController.AssignedPlotChanged", function()
		disconnectTargetCache()
		ensureTargetCache()
	end)
	RuntimeGuard.Connect(RunService.RenderStepped, "OnboardingController.RenderStepped", step)
end

return OnboardingController
