local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GrowingVisuals = require(Shared:WaitForChild("GrowingVisuals"))
local Inventory = require(Shared:WaitForChild("Inventory"))
local MailboxConfig = require(Shared:WaitForChild("MailboxConfig"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local PatchGrowth = require(Shared:WaitForChild("PatchGrowth"))
local PatchScale = require(Shared:WaitForChild("PatchScale"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local PlotResolver = require(script.Parent:WaitForChild("PlotResolver"))
local ResponsiveHud = require(script.Parent:WaitForChild("ResponsiveHud"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local StationFocus = require(script.Parent:WaitForChild("StationFocus"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))

local SkipTimeButtonsController = {}

local HUD_WAIT_SECONDS = 10
local PROXIMITY_CHECK_SECONDS = 0.1
local PREVIEW_RECOMPUTE_SECONDS = 0.5
local SIGNS_FOLDER_NAME = MailboxConfig.SignsFolderName
local MAILBOX_NAME = MailboxConfig.MailboxName
local DOOR_NAME = MailboxConfig.DoorName
local EDIT_MODE_ATTR = "EditMode"
local DOOR_OPEN_ANGLE = math.rad(78)
local DOOR_OPEN_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DOOR_CLOSE_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local PROMPT_TIMEOUT_SECONDS = 20
local SKIP_30M_GRADIENT_DEGREES_PER_SECOND = 18

local SKIP_IDS = { "Skip5m", "Skip30m" }

local player = Players.LocalPlayer
local growSkipRequestRemote = Remotes.get(Remotes.Names.GrowSkipRequest)
local growSkipResultRemote = Remotes.get(Remotes.Names.GrowSkipResult)
local collectAllRequestRemote = Remotes.get(Remotes.Names.CollectAllRequest)
local collectAllResultRemote = Remotes.get(Remotes.Names.CollectAllResult)

local productPriceById = {}
local nextRequestId = 0
local pendingRequestId = nil
local pendingProductId = nil
local pendingKind = nil
local promptToken = 0

local activeDoor = nil
local activeDoorClosedPivot = nil
local activeDoorOpen = false
local activeDoorTweenToken = 0
local tutorialActive = false
local mailboxHiddenStates = setmetatable({}, { __mode = "k" })

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function robuxText(productId, onLoaded)
	productId = int(productId, 0)
	if productId <= 0 then
		return NumberFormatter.Robux(0)
	end
	if productPriceById[productId] then
		return productPriceById[productId]
	end

	productPriceById[productId] = NumberFormatter.Robux(0)
	RuntimeGuard.Spawn("SkipTimeButtonsController.ProductInfo", function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, productId, Enum.InfoType.Product)
		if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
			productPriceById[productId] = NumberFormatter.Robux(info.PriceInRobux)
			if onLoaded then
				onLoaded()
			end
		end
	end)
	return productPriceById[productId]
end

local function findDescendant(root, name, className)
	for _, descendant in ipairs(root and root:GetDescendants() or {}) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

local function firstBasePart(instance)
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function ownPlot()
	return PlotResolver.ResolveForPlayer(player)
end

local function mailboxForPlot(plot)
	local signs = plot and plot:FindFirstChild(SIGNS_FOLDER_NAME)
	local mailbox = signs and signs:FindFirstChild(MAILBOX_NAME)
	return mailbox
end

local function isPlotCandidate(instance)
	return instance ~= nil
		and (instance:IsA("Model") or instance:IsA("Folder"))
		and instance.Name:match("^Plot%d+$") ~= nil
end

local function forEachRuntimePlot(callback)
	local plotsFolder = Workspace:FindFirstChild("Plots")
	local root = plotsFolder or Workspace
	for _, child in ipairs(root:GetChildren()) do
		if isPlotCandidate(child) then
			callback(child)
		end
	end
end

local function doorForMailbox(mailbox)
	local door = mailbox and mailbox:FindFirstChild(DOOR_NAME)
	if door and (door:IsA("BasePart") or door:IsA("Model")) then
		return door
	end
	return nil
end

local function isGrowingSeedRoot(instance)
	return instance ~= nil
		and (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.Seed.Phase) == "GrowingSeed"
end

local function isMaturePatchRoot(instance)
	return instance ~= nil
		and (instance:IsA("BasePart") or instance:IsA("Model"))
		and instance:GetAttribute(State.Feed.Class) == "Patch"
		and instance:GetAttribute(State.Seed.Phase) ~= "GrowingSeed"
end

local function plotHasEligibleGrowth(plot)
	if not plot then
		return false
	end
	if isGrowingSeedRoot(plot) or isMaturePatchRoot(plot) then
		return true
	end
	for _, descendant in ipairs(plot:GetDescendants()) do
		if isGrowingSeedRoot(descendant) or isMaturePatchRoot(descendant) then
			return true
		end
	end
	return false
end

local function formatAddedXP(value)
	return NumberFormatter.Format(math.max(math.floor(tonumber(value) or 0), 0)) .. "xp"
end

local function isActiveReservation(instance)
	local reservationId = instance and instance:GetAttribute(State.Food.StealReservationId)
	if type(reservationId) ~= "string" or reservationId == "" then
		return false
	end
	local expiresAt = tonumber(instance:GetAttribute(State.Food.StealReservationExpiresAt))
	return expiresAt == nil or expiresAt > os.time()
end

local function isTopFoodInstance(instance, root)
	if not (instance and (instance:IsA("BasePart") or instance:IsA("Model"))) then
		return false
	end
	if instance:GetAttribute(State.Food.Id) == nil then
		return false
	end
	local current = instance.Parent
	while current and current ~= root do
		if (current:IsA("BasePart") or current:IsA("Model")) and current:GetAttribute(State.Food.Id) ~= nil then
			return false
		end
		current = current.Parent
	end
	return true
end

local function forEachTopFood(root, callback)
	if not root then
		return
	end
	if isTopFoodInstance(root, root) then
		callback(root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if isTopFoodInstance(descendant, root) then
			callback(descendant)
		end
	end
end

local function templatePatchSlotCount(template)
	if not template then
		return 0
	end
	local count = 0
	for _, child in ipairs(template:GetChildren()) do
		if child:IsA("BasePart") and child.Name == "BaseFood" then
			count += 1
		end
	end
	return count
end

local function addedPatchXPForSeconds(source, seconds, slotCount)
	seconds = math.max(tonumber(seconds) or 0, 0)
	slotCount = math.max(math.floor(tonumber(slotCount) or 0), 0)
	if not (source and seconds > 0 and slotCount > 0) then
		return 0
	end
	local growRate = PatchGrowth.NormalizeGrowRate(source:GetAttribute(State.Feed.GrowRate))
	local patchXP = PatchScale.NormalizePatchXP(source:GetAttribute(State.Feed.XP))
	return math.floor(seconds / growRate) * patchXP * slotCount
end

local function respawningPatchAddedXP(machine, seconds)
	local total = 0
	for _, descendant in ipairs(machine:GetDescendants()) do
		local respawnAt = tonumber(descendant:GetAttribute(State.Food.RespawnAt))
		if respawnAt then
			local leftoverSeconds = seconds - math.max(respawnAt - os.time(), 0)
			if leftoverSeconds > 0 then
				total += addedPatchXPForSeconds(machine, leftoverSeconds, 1)
			end
		end
	end
	return total
end

local function maturePatchAddedXP(machine, seconds)
	local now = Workspace:GetServerTimeNow()
	local total = respawningPatchAddedXP(machine, seconds)
	forEachTopFood(machine, function(food)
		local before = PatchGrowth.ComputeXPForFood(food, machine, now)
		local after = PatchGrowth.ComputeXPForFood(food, machine, now + seconds)
		total += math.max(math.floor(after) - math.floor(before), 0)
	end)
	return total
end

local function growingPatchSeedAddedXP(seedRoot, seconds)
	if not isGrowingSeedRoot(seedRoot) then
		return 0
	end
	local seedId = seedRoot:GetAttribute(State.Seed.Id)
	local feedType = seedRoot:GetAttribute(State.Feed.Type) or Seeds.FeedTypeFor(seedId)
	if GrowingVisuals.FeedClassFor(feedType) ~= "Patch" then
		return 0
	end
	local growEndAt = tonumber(seedRoot:GetAttribute(State.Seed.GrowEndAt))
	if not growEndAt then
		return 0
	end
	local leftoverSeconds = seconds - math.max(growEndAt - os.time(), 0)
	if leftoverSeconds <= 0 then
		return 0
	end
	local template = GrowingVisuals.FeedTemplateFor(feedType)
	return addedPatchXPForSeconds(template, leftoverSeconds, templatePatchSlotCount(template))
end

local function skipAddedPatchXP(plot, seconds)
	if not plot then
		return 0
	end
	local total = 0
	local function add(instance)
		if isMaturePatchRoot(instance) then
			total += maturePatchAddedXP(instance, seconds)
		elseif isGrowingSeedRoot(instance) then
			total += growingPatchSeedAddedXP(instance, seconds)
		end
	end
	add(plot)
	for _, descendant in ipairs(plot:GetDescendants()) do
		add(descendant)
	end
	return total
end

local function readyPatchFruitCount(machine)
	local count = 0
	forEachTopFood(machine, function(food)
		if not isActiveReservation(food) then
			count += 1
		end
	end)
	return count
end

local function readyTreeGroundFruitCount(plot)
	local count = 0
	for _, descendant in ipairs(plot:GetDescendants()) do
		if descendant:GetAttribute(State.TreeClicker.GroundPile) == true
			and descendant:GetAttribute(State.Food.Id) ~= nil
			and not isActiveReservation(descendant) then
			count += 1
		end
	end
	return count
end

local function readyCollectAllFruitCount(plot)
	if not plot then
		return 0
	end
	local count = readyTreeGroundFruitCount(plot)
	local function addPatch(instance)
		if isMaturePatchRoot(instance) then
			count += readyPatchFruitCount(instance)
		end
	end
	addPatch(plot)
	for _, descendant in ipairs(plot:GetDescendants()) do
		addPatch(descendant)
	end
	local remainingSlots = Inventory.RemainingSlots(player, Inventory.COLLECT_ALL_MAX_ITEMS)
	return math.min(count, remainingSlots)
end

local function applyMailboxLocalTransparency(mailbox, transparency)
	if not mailbox then
		return
	end
	for _, descendant in ipairs(mailbox:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = transparency
		end
	end
	if mailbox:IsA("BasePart") then
		mailbox.LocalTransparencyModifier = transparency
	end
end

local function setMailboxHidden(mailbox, hidden)
	if not mailbox then
		return
	end
	local currentlyHidden = mailboxHiddenStates[mailbox] == true
	if currentlyHidden == hidden then
		if hidden then
			applyMailboxLocalTransparency(mailbox, 1)
		end
		return
	end
	applyMailboxLocalTransparency(mailbox, hidden and 1 or 0)
	mailboxHiddenStates[mailbox] = hidden and true or nil
end

local function refreshMailboxVisibility()
	local ownedPlot = ownPlot()
	local seen = {}
	forEachRuntimePlot(function(plot)
		local mailbox = mailboxForPlot(plot)
		if mailbox then
			seen[mailbox] = true
			setMailboxHidden(mailbox, plot ~= ownedPlot or tutorialActive)
		end
	end)
	for mailbox in pairs(mailboxHiddenStates) do
		if not seen[mailbox] or mailbox.Parent == nil then
			applyMailboxLocalTransparency(mailbox, 0)
			mailboxHiddenStates[mailbox] = nil
		end
	end
end

local function profileReady()
	return PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
end

local function requestBlocked()
	return pendingRequestId ~= nil or pendingProductId ~= nil
end

local function canUseMailbox(mailbox)
	return mailbox ~= nil
		and not tutorialActive
		and profileReady()
		and player:GetAttribute(State.Player.OfflineProgressPending) ~= true
		and player:GetAttribute(EDIT_MODE_ATTR) ~= true
		and StationFocus.IsMailboxActive()
end

local function codeToMessage(code)
	if code == "too-far" then
		return "Move closer to the mailbox."
	end
	if code == "profile-not-ready" or code == "no-profile" then
		return "Save data is still loading."
	end
	if code == "offline-progress" then
		return "Finish loading offline progress first."
	end
	if code == "edit-mode" then
		return "Exit edit mode first."
	end
	if code == "no-growth" then
		return "Nothing is growing right now."
	end
	if code == "no-food" then
		return "No food is ready to collect."
	end
	if code == "inventory-full" then
		return "Inventory full (1500 max)."
	end
	if code == "pending-purchase" then
		return "Finish your current purchase first."
	end
	if code == "busy" or code == "rate-limited" then
		return "Try again in a moment."
	end
	return "Could not start purchase."
end

local function bindCard(frame)
	if not (frame and frame:IsA("GuiObject")) then
		return nil
	end
	local buyButton = findDescendant(frame, "BuyButton", "GuiButton")
	if not buyButton then
		warn("[SkipTimeButtonsController] Missing " .. frame:GetFullName() .. ".BuyButton")
		return nil
	end
	UiEffects.BindButton(buyButton)
	return {
		frame = frame,
		buyButton = buyButton,
		priceLabel = findDescendant(buyButton, "Price", "TextLabel"),
		skipAmountLabel = findDescendant(frame, "SkipAmount", "TextLabel"),
		fruitsLabel = findDescendant(frame, "FruitsLabel", "TextLabel"),
		errorLabel = findDescendant(frame, "ErrorLabel", "TextLabel"),
	}
end

local function bindSlowGradientRotation(guiObject)
	local gradients = {}
	for _, descendant in ipairs(guiObject and guiObject:GetDescendants() or {}) do
		if descendant:IsA("UIGradient") then
			gradients[#gradients + 1] = descendant
		end
	end
	if #gradients == 0 then
		return
	end

	local rotation = gradients[1].Rotation
	local connection
	connection = RuntimeGuard.Connect(RunService.RenderStepped, "SkipTimeButtonsController.Skip30mGradient", function(deltaTime)
		if not (guiObject and guiObject.Parent) then
			if connection then
				connection:Disconnect()
				connection = nil
			end
			return
		end
		rotation = (rotation + deltaTime * SKIP_30M_GRADIENT_DEGREES_PER_SECOND) % 360
		for index = #gradients, 1, -1 do
			local gradient = gradients[index]
			if gradient and gradient.Parent then
				gradient.Rotation = rotation
			else
				table.remove(gradients, index)
			end
		end
	end)
end

local function setError(record, text)
	if not (record and record.errorLabel) then
		return
	end
	record.errorLabel.Text = text or ""
	record.errorLabel.Visible = text ~= nil and text ~= ""
end

local function clearErrors(records)
	for _, record in ipairs(records) do
		setError(record, nil)
	end
end

local MYTHICAL_TEXT_TWEEN_SECONDS = 0.35
local MYTHICAL_TEXT_TWEEN = TweenInfo.new(MYTHICAL_TEXT_TWEEN_SECONDS, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)

local function applyTextColorStack(root, color, instant)
	if not (root and color) then
		return
	end
	local function apply(label)
		if not (label:IsA("TextLabel") or label:IsA("TextButton")) then
			return
		end
		if instant then
			label.TextColor3 = color
			return
		end
		TweenService:Create(label, MYTHICAL_TEXT_TWEEN, {
			TextColor3 = color,
		}):Play()
	end
	apply(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("UIGradient") then
			descendant:Destroy()
		else
			apply(descendant)
		end
	end
end

local function ensureMythicalTextTween(label)
	if not label then
		return
	end
	for _, descendant in ipairs(label:GetDescendants()) do
		if descendant:IsA("UIGradient") then
			descendant:Destroy()
		end
	end
	local function refresh(instant)
		if not (label and label.Parent) then
			return false
		end
		applyTextColorStack(label, Rarities.ColorFor(Rarities.Mythical, os.clock()), instant == true)
		return true
	end
	refresh(true)
	RuntimeGuard.Spawn("SkipTimeButtonsController.MythicalSkipAmount", function()
		while label.Parent do
			task.wait(MYTHICAL_TEXT_TWEEN_SECONDS)
			if not refresh(false) then
				break
			end
		end
	end)
end

local function targetPivotForDoor(closedPivot, open)
	if open then
		return closedPivot * CFrame.Angles(0, 0, DOOR_OPEN_ANGLE)
	end
	return closedPivot
end

local function animateDoor(door, open)
	if not (door and door.Parent) then
		return
	end
	if activeDoor ~= door then
		activeDoor = door
		activeDoorClosedPivot = door:GetPivot()
		activeDoorOpen = false
	end
	if activeDoorOpen == open then
		return
	end
	activeDoorOpen = open
	activeDoorTweenToken += 1
	local token = activeDoorTweenToken
	local closedPivot = activeDoorClosedPivot or door:GetPivot()
	local value = Instance.new("CFrameValue")
	value.Value = door:GetPivot()
	local changedConnection = RuntimeGuard.Connect(value.Changed, "SkipTimeButtonsController.DoorTweenChanged", function()
		if token == activeDoorTweenToken and door.Parent then
			door:PivotTo(value.Value)
		end
	end)
	local tween = TweenService:Create(value, open and DOOR_OPEN_TWEEN or DOOR_CLOSE_TWEEN, {
		Value = targetPivotForDoor(closedPivot, open),
	})
	RuntimeGuard.Connect(tween.Completed, "SkipTimeButtonsController.DoorTweenCompleted", function()
		changedConnection:Disconnect()
		if token == activeDoorTweenToken and door.Parent then
			door:PivotTo(targetPivotForDoor(closedPivot, open))
		end
		value:Destroy()
	end)
	tween:Play()

	local soundParent = firstBasePart(door)
	SoundEffects.Play(open and SoundEffects.Names.MailboxOpen or SoundEffects.Names.MailboxClose, {
		parent = soundParent,
		range = 35,
		rollOffMinDistance = 4,
	})
end

local function nextNegativeRequestId()
	nextRequestId -= 1
	return nextRequestId
end

function SkipTimeButtonsController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild("HUD", HUD_WAIT_SECONDS)
	if not hud then
		warn("[SkipTimeButtonsController] Missing PlayerGui.HUD")
		return
	end

	local skipButtons = hud:WaitForChild("SkipTimeButtons", HUD_WAIT_SECONDS)
	if not (skipButtons and skipButtons:IsA("GuiObject")) then
		warn("[SkipTimeButtonsController] Missing HUD.SkipTimeButtons")
		return
	end

	local panelState = UiEffects.PreparePanel(skipButtons)
	ResponsiveHud.RegisterBottomShiftPanel(hud, "SkipTimeButtons", skipButtons, panelState, {
		bottomChildNames = { "Skip5m", "Skip30m", "CollectAll" },
		matchOpenPositionTo = "RollButtons",
	})
	local records = {}
	local recordsBySkipId = {}
	local collectAllRecord = nil
	local isOpen = false
	local transitionToken = 0
	local lastPreviewAt = -math.huge
	local collectAllPreviewFrozen = false
	local cachedCollectAllCount = 0
	local cachedSkipXPById = {}
	local render

	local function markPreviewDirty()
		lastPreviewAt = -math.huge
	end

	local function thawCollectAllPreview()
		if collectAllPreviewFrozen then
			collectAllPreviewFrozen = false
			markPreviewDirty()
		end
	end

	for _, skipId in ipairs(SKIP_IDS) do
		local config = ShopBalance.GrowSkipForSkipId(skipId)
		local frame = skipButtons:FindFirstChild(skipId)
		local record = bindCard(frame)
		if record then
			record.kind = "skip"
			record.skipId = skipId
			record.productId = int(config and config.DevProductId, 0)
			record.durationSeconds = int(config and config.DurationSeconds, 0)
			records[#records + 1] = record
			recordsBySkipId[skipId] = record
		end
	end
	if recordsBySkipId.Skip30m then
		ensureMythicalTextTween(recordsBySkipId.Skip30m.skipAmountLabel)
		bindSlowGradientRotation(recordsBySkipId.Skip30m.buyButton)
	end

	do
		local config = ShopBalance.GetCollectAll()
		local record = bindCard(skipButtons:FindFirstChild("CollectAll"))
		if record then
			record.kind = "collect-all"
			record.productId = int(config and config.DevProductId, 0)
			records[#records + 1] = record
			collectAllRecord = record
		end
	end

	if #records == 0 then
		warn("[SkipTimeButtonsController] HUD.SkipTimeButtons has no bindable buttons")
		return
	end

	local function openPanel()
		if isOpen then
			return
		end
		isOpen = true
		transitionToken += 1
		markPreviewDirty()
		UiEffects.PlayOpen(skipButtons, panelState, {
			silent = true,
		})
	end

	local function closePanel()
		if not isOpen then
			return
		end
		isOpen = false
		transitionToken += 1
		markPreviewDirty()
		local token = transitionToken
		UiEffects.PlayClose(
			skipButtons,
			panelState,
			function()
				if transitionToken == token and not isOpen then
					skipButtons.Visible = false
				end
			end,
			{
				silent = true,
			}
		)
	end

	local function currentMailbox()
		return mailboxForPlot(ownPlot())
	end

	local function applyTutorialState(state)
		state = Onboarding.SanitizeState(state, Onboarding.CompleteState())
		tutorialActive = Onboarding.IsActive(state.Stage)
		refreshMailboxVisibility()
		render()
	end

	local function refreshPreviewCache(plot)
		if not isOpen or requestBlocked() or collectAllPreviewFrozen then
			return
		end
		local clock = os.clock()
		if clock - lastPreviewAt < PREVIEW_RECOMPUTE_SECONDS then
			return
		end
		lastPreviewAt = clock
		cachedCollectAllCount = readyCollectAllFruitCount(plot)
		for _, record in ipairs(records) do
			if record.kind == "skip" then
				cachedSkipXPById[record.skipId] = skipAddedPatchXP(plot, record.durationSeconds)
			end
		end
	end

	render = function()
		local plot = ownPlot()
		refreshPreviewCache(plot)
		for _, record in ipairs(records) do
			if record.priceLabel then
				UiEffects.SetTextStack(record.priceLabel, robuxText(record.productId, render))
			end
			if record.kind == "skip" then
				if isOpen and record.skipAmountLabel then
					UiEffects.SetTextStack(record.skipAmountLabel, formatAddedXP(cachedSkipXPById[record.skipId] or 0))
				end
			elseif isOpen and record.kind == "collect-all" and record.fruitsLabel then
				local suffix = cachedCollectAllCount == 1 and " fruit" or " fruits"
				UiEffects.SetTextStack(record.fruitsLabel, NumberFormatter.Format(cachedCollectAllCount) .. suffix)
			end
		end
	end

	local function requestSkip(skipId)
		local record = recordsBySkipId[skipId]
		local mailbox = currentMailbox()
		local plot = ownPlot()
		clearErrors(records)
		if requestBlocked() then
			setError(record, codeToMessage("pending-purchase"))
			render()
			return
		end
		if not (record and record.productId > 0) then
			setError(record, codeToMessage(nil))
			render()
			return
		end
		if not canUseMailbox(mailbox) then
			setError(record, codeToMessage("too-far"))
			render()
			return
		end
		if not plotHasEligibleGrowth(plot) then
			setError(record, codeToMessage("no-growth"))
			render()
			return
		end
		pendingRequestId = nextNegativeRequestId()
		pendingKind = "skip"
		growSkipRequestRemote:FireServer(pendingRequestId, mailbox, skipId)
		render()
	end

	local function requestCollectAll()
		local mailbox = currentMailbox()
		local plot = ownPlot()
		clearErrors(records)
		if requestBlocked() then
			setError(collectAllRecord, codeToMessage("pending-purchase"))
			render()
			return
		end
		if not (collectAllRecord and collectAllRecord.productId > 0) then
			setError(collectAllRecord, codeToMessage(nil))
			render()
			return
		end
		if not canUseMailbox(mailbox) then
			setError(collectAllRecord, codeToMessage("too-far"))
			render()
			return
		end
		local readyCount = readyCollectAllFruitCount(plot)
		if readyCount <= 0 then
			cachedCollectAllCount = 0
			setError(collectAllRecord, codeToMessage("no-food"))
			render()
			return
		end
		cachedCollectAllCount = readyCount
		pendingRequestId = nextNegativeRequestId()
		pendingKind = "collect-all"
		collectAllPreviewFrozen = true
		collectAllRequestRemote:FireServer(pendingRequestId, mailbox)
		render()
	end

	for skipId, record in pairs(recordsBySkipId) do
		RuntimeGuard.Connect(record.buyButton.Activated, "SkipTimeButtonsController." .. skipId, function()
			requestSkip(skipId)
		end)
	end
	if collectAllRecord then
		RuntimeGuard.Connect(collectAllRecord.buyButton.Activated, "SkipTimeButtonsController.CollectAll", requestCollectAll)
	end

	RuntimeGuard.Connect(growSkipResultRemote.OnClientEvent, "SkipTimeButtonsController.GrowSkipResult", function(payload)
		if pendingKind ~= "skip" or type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		local skipId = payload.skipId
		local record = type(skipId) == "string" and recordsBySkipId[skipId] or nil
		if not record then
			record = records[1]
		end
		pendingRequestId = nil
		local productId = int(payload.productId, 0)
		if payload.success == true and productId > 0 and type(payload.reservationId) == "string" then
			pendingProductId = productId
			promptToken += 1
			local token = promptToken
			RuntimeGuard.Run("SkipTimeButtonsController.PromptGrowSkip", function()
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
			task.delay(PROMPT_TIMEOUT_SECONDS, function()
				if pendingProductId == productId and promptToken == token then
					pendingProductId = nil
					pendingKind = nil
					render()
				end
			end)
		else
			pendingKind = nil
			setError(record, codeToMessage(payload.code))
		end
		markPreviewDirty()
		render()
	end)

	RuntimeGuard.Connect(collectAllResultRemote.OnClientEvent, "SkipTimeButtonsController.CollectAllResult", function(payload)
		if pendingKind ~= "collect-all" or type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		local productId = int(payload.productId, 0)
		if payload.success == true and productId > 0 and type(payload.reservationId) == "string" then
			pendingProductId = productId
			promptToken += 1
			local token = promptToken
			RuntimeGuard.Run("SkipTimeButtonsController.PromptCollectAll", function()
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
			task.delay(PROMPT_TIMEOUT_SECONDS, function()
				if pendingProductId == productId and promptToken == token then
					pendingProductId = nil
					pendingKind = nil
					render()
				end
			end)
		else
			pendingKind = nil
			setError(collectAllRecord, codeToMessage(payload.code))
			thawCollectAllPreview()
		end
		markPreviewDirty()
		render()
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "SkipTimeButtonsController.PromptFinished", function(userId, productId, wasPurchased)
		if userId ~= player.UserId or productId ~= pendingProductId then
			return
		end
		local finishedKind = pendingKind
		promptToken += 1
		pendingProductId = nil
		pendingKind = nil
		if finishedKind == "collect-all" and wasPurchased ~= true then
			thawCollectAllPreview()
		end
		render()
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.FoodInventory, function(_value, oldValue)
		if oldValue ~= nil then
			thawCollectAllPreview()
			render()
		end
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, applyTutorialState)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.AssignedPlotName), "SkipTimeButtonsController.AssignedPlotChanged", function()
		refreshMailboxVisibility()
		render()
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.OfflineProgressPending), "SkipTimeButtonsController.OfflineProgressChanged", render)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(EDIT_MODE_ATTR), "SkipTimeButtonsController.EditModeChanged", render)

	RuntimeGuard.Spawn("SkipTimeButtonsController.ProximityLoop", function()
		while skipButtons.Parent do
			RuntimeGuard.Run("SkipTimeButtonsController.ProximityTick", function()
				local mailbox = currentMailbox()
				refreshMailboxVisibility()
				local near = mailbox ~= nil and not tutorialActive and StationFocus.IsMailboxActive()
				local door = doorForMailbox(mailbox)
				if near then
					openPanel()
					if door then
						animateDoor(door, true)
					end
				else
					closePanel()
					clearErrors(records)
					if activeDoor and activeDoor.Parent and activeDoorOpen then
						animateDoor(activeDoor, false)
					elseif door and activeDoor ~= door then
						activeDoor = door
						activeDoorClosedPivot = door:GetPivot()
						activeDoorOpen = false
					end
				end
				render()
			end)
			task.wait(PROXIMITY_CHECK_SECONDS)
		end
	end)

	refreshMailboxVisibility()
	render()
end

return SkipTimeButtonsController
