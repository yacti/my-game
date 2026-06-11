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
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local RollController = require(script.Parent:WaitForChild("RollController"))

local OnboardingController = {}

local ARROW_HEIGHT = 6
local SEED_PREVIEW_ARROW_HEIGHT = 9.5
local PLANT_ARROW_HEIGHT = 22
local PLANT_ARROW_SCALE = 2
local ARROW_BOB_HEIGHT = 0.75
local ARROW_BOB_PERIOD = 1.15
local ARROW_FOLLOW_SPEED = 7
local ARROW_Z_ROTATION_SPEED = math.rad(180)
local CLICKER_POP_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICKER_SETTLE_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FINAL_NOTE_FADE_TWEEN = TweenInfo.new(Onboarding.FinalNoteFadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local player = Players.LocalPlayer

local started = false
local currentStage = Onboarding.Stages.Complete
local currentProgress = {}
local mainArrow = nil
local mainBaseCFrame = nil
local mainTargetCFrame = nil
local mainTargetScale = 1
local mainArrowDefaultScale = 1
local mainArrowAppliedScale = nil
local mainArrowStartTime = 0
local fruitArrows = {}
local templateRotation = CFrame.new()
local clickerBillboard = nil
local clickerBaseSize = nil
local lastClickCount = 0
local warnedMissingArrow = false
local warnedMissingClicker = false
local finalNoteToken = 0
local finalNoteTweens = {}
local finalNoteTransparency = setmetatable({}, { __mode = "k" })
local targetCache = nil

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

local function progressRatio(value, maximum)
	maximum = tonumber(maximum) or 0
	if maximum <= 0 then
		return 0
	end
	return math.clamp((tonumber(value) or 0) / maximum, 0, 1)
end

local function tutorialBarProgress(stage)
	if stage == Onboarding.Stages.MakeCurrency then
		return true, progressRatio(
			PlayerStateStore.Get(PlayerStateStore.Fields.Currency),
			Onboarding.CurrencyRequired
		)
	end
	if stage == Onboarding.Stages.GatherPumpkinXP then
		return true, progressRatio(
			currentProgress[Onboarding.ProgressKeys.PumpkinXPGained],
			Onboarding.PumpkinXPRequired
		)
	end
	return false, 0
end

local function updateHudProgressBar(stage)
	local frame = hudOnboardingFrame()
	if not frame then
		return
	end
	local bar, fill = onboardingProgressBar(frame)
	local visible, progress = tutorialBarProgress(stage or currentStage)
	if bar then
		bar.Visible = visible
	end
	if fill then
		fill.Size = UDim2.new(progress, 0, 1, 0)
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
	updateHudProgressBar(stage)
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
		mainArrowDefaultScale = mainArrow:GetScale()
		mainArrowAppliedScale = nil
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
	mainTargetScale = 1
	mainArrowDefaultScale = 1
	mainArrowAppliedScale = nil
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
	if currentStage == Onboarding.Stages.RollPumpkinSeed or currentStage == Onboarding.Stages.RollAppleTreeSeed then
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
	if currentStage == Onboarding.Stages.PlantPumpkinSeed or currentStage == Onboarding.Stages.PlantAppleTreeSeed then
		local center = starterAreaCenter()
		return center and {
			position = center,
			arrowHeight = PLANT_ARROW_HEIGHT,
			arrowScale = PLANT_ARROW_SCALE,
		} or nil
	end
	if currentStage == Onboarding.Stages.HarvestPumpkin then
		return pumpkinTarget()
	end
	if currentStage == Onboarding.Stages.ExpandFarm then
		return expandFarmTarget()
	end
	if currentStage == Onboarding.Stages.FeedPetPumpkin or currentStage == Onboarding.Stages.FeedPetApple then
		return petTarget()
	end
	return nil
end

local function targetWorldPosition(target)
	if type(target) == "table" and typeof(target.position) == "Vector3" then
		return target.position
	end
	-- Table targets may track a live instance instead of a static position so
	-- per-stage arrowHeight/arrowScale overrides still follow a moving target.
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

local function arrowScaleForTarget(target)
	local scale = type(target) == "table" and tonumber(target.arrowScale) or 1
	return math.max(scale or 1, 0.1)
end

local function applyMainArrowScale(scale)
	if not mainArrow then
		return
	end
	scale = math.max(tonumber(scale) or 1, 0.1)
	if mainArrowAppliedScale == scale then
		return
	end
	mainArrowAppliedScale = scale
	pcall(function()
		mainArrow:ScaleTo(mainArrowDefaultScale * scale)
	end)
end

local function updateMainTarget()
	if currentStage == Onboarding.Stages.CollectApple
		or currentStage == Onboarding.Stages.ShakeAppleTree
		or currentStage == Onboarding.Stages.MakeCurrency
		or currentStage == Onboarding.Stages.GatherPumpkinXP
		or not Onboarding.IsActive(currentStage) then
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
		mainTargetScale = arrowScaleForTarget(target)
		applyMainArrowScale(mainTargetScale)
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

local function destroyClicker()
	if clickerBillboard then
		clickerBillboard:Destroy()
		clickerBillboard = nil
	end
	clickerBaseSize = nil
	lastClickCount = 0
end

local function ensureClicker()
	local primary = treePrimary()
	if currentStage ~= Onboarding.Stages.ShakeAppleTree or not primary then
		destroyClicker()
		return
	end
	if clickerBillboard and clickerBillboard.Parent then
		clickerBillboard.Adornee = primary
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
	clickerBillboard.Adornee = primary
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
	PlayerStateStore.Observe(PlayerStateStore.Fields.Currency, function()
		updateHudProgressBar(currentStage)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "OnboardingController.AssignedPlotChanged", function()
		disconnectTargetCache()
		ensureTargetCache()
	end)
	RuntimeGuard.Connect(RunService.RenderStepped, "OnboardingController.RenderStepped", step)
end

return OnboardingController
