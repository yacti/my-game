local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local State = require(Shared:WaitForChild("State"))

local BillboardGuiTemplates = require(script.Parent:WaitForChild("BillboardGuiTemplates"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local RollController = require(script.Parent:WaitForChild("RollController"))

local OnboardingController = {}

local ARROW_HEIGHT = 6
local PLANT_ARROW_HEIGHT = 10
local PLANT_ARROW_SCALE = 2
local ARROW_BOB_HEIGHT = 0.75
local ARROW_BOB_PERIOD = 1.15
local ARROW_FOLLOW_SPEED = 7
local ARROW_Z_ROTATION_SPEED = math.rad(180)
local CLICKER_POP_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICKER_SETTLE_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

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

local function setHudText(stage)
	local frame = hudOnboardingFrame()
	if not frame then
		return
	end
	local active = Onboarding.IsActive(stage)
	frame.Visible = active
	local label = frame:FindFirstChild("OnboardingText")
	if label and label:IsA("TextLabel") then
		label.Text = Onboarding.TextFor(stage)
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
	local currentPlot = plot()
	if not currentPlot then
		return nil
	end
	for _, descendant in ipairs(currentPlot:GetDescendants()) do
		if (descendant:IsA("BasePart") or descendant:IsA("Model"))
			and descendant:GetAttribute(State.Feed.Type) == feedType
			and descendant:GetAttribute(State.Feed.Index) ~= nil then
			return descendant
		end
	end
	return nil
end

local function isGrowingSeedFeed(instance)
	return instance ~= nil and instance:GetAttribute(State.Seed.Phase) == "GrowingSeed"
end

local function pumpkinTarget()
	local machine = feedMachine(Onboarding.FeedTypes.Pumpkin)
	if not machine then
		return nil
	end
	for _, descendant in ipairs(machine:GetDescendants()) do
		if (descendant:IsA("BasePart") or descendant:IsA("Model"))
			and descendant:GetAttribute(State.Food.Id) == Onboarding.FoodIds.Pumpkin then
			return descendant
		end
	end
	return machine
end

local function petTarget()
	local currentPlot = plot()
	if not currentPlot then
		return nil
	end
	for _, descendant in ipairs(currentPlot:GetDescendants()) do
		if descendant:IsA("Model") and descendant:GetAttribute(State.Pet.Index) ~= nil then
			return descendant
		end
	end
	return nil
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
	for _, descendant in ipairs(tree:GetDescendants()) do
		if (descendant:IsA("BasePart") or descendant:IsA("Model"))
			and descendant:GetAttribute(State.TreeClicker.GroundPile) == true
			and descendant:GetAttribute(State.Food.Id) == Onboarding.FoodIds.Apple then
			fruits[#fruits + 1] = descendant
		end
	end
	return fruits
end

local function singleArrowTarget()
	if currentStage == Onboarding.Stages.RollPumpkinSeed or currentStage == Onboarding.Stages.RollAppleTreeSeed then
		return rollButton()
	end
	if currentStage == Onboarding.Stages.BuyPumpkinSeed then
		return RollController.GetActiveTutorialReveal(Onboarding.Seeds.Pumpkin)
	end
	if currentStage == Onboarding.Stages.BuyAppleTreeSeed then
		return RollController.GetActiveTutorialReveal(Onboarding.Seeds.AppleTree)
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
	if currentStage == Onboarding.Stages.FeedPetPumpkin or currentStage == Onboarding.Stages.FeedPetApple then
		return petTarget()
	end
	return nil
end

local function targetWorldPosition(target)
	if type(target) == "table" and typeof(target.position) == "Vector3" then
		return target.position
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
	if currentStage == Onboarding.Stages.CollectApple or currentStage == Onboarding.Stages.ShakeAppleTree or not Onboarding.IsActive(currentStage) then
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
	RuntimeGuard.Connect(RunService.RenderStepped, "OnboardingController.RenderStepped", step)
end

return OnboardingController
