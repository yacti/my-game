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
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
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

local Notifications = require(script.Parent:WaitForChild("Notifications"))
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
local SKIP_SIGN_NAME = MailboxConfig.SkipTimeSignName
local SKIP_SIGN_DISTANCE = MailboxConfig.SkipTimeSignInteractionDistance
local DOOR_NAME = MailboxConfig.DoorName
local EDIT_MODE_ATTR = "EditMode"
local DOOR_OPEN_ANGLE = math.rad(78)
local DOOR_OPEN_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local DOOR_CLOSE_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local PROMPT_TIMEOUT_SECONDS = 20
local SKIP_30M_GRADIENT_DEGREES_PER_SECOND = 18
local SIGN_PRESS_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SIGN_PRESS_SCALE = 0.94

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
local pendingRecord = nil
local promptToken = 0

local activeDoor = nil
local activeDoorClosedPivot = nil
local activeDoorOpen = false
local activeDoorTweenToken = 0
local tutorialActive = false
-- Deliberately strong tables: weak-keyed Instance entries can be collected
-- between proximity ticks (nothing else holds the part userdata), which
-- both drops the hidden flag and lets the next hide pass re-capture
-- CanCollide=false as the "authored" value. Entries are removed on restore
-- and the refresh pass prunes destroyed stations, so growth is bounded.
local stationHiddenStates = {}
local stationOriginalCanCollide = {}

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

local function skipSignForPlot(plot)
	local signs = plot and plot:FindFirstChild(SIGNS_FOLDER_NAME)
	local sign = signs and signs:FindFirstChild(SKIP_SIGN_NAME)
	return sign
end

local function skipSignGui(sign)
	return sign and sign:FindFirstChildWhichIsA("SurfaceGui", true) or nil
end

local function skipSignButtonsFrame(sign)
	local gui = skipSignGui(sign)
	local frame = gui and gui:FindFirstChild("SkipTimeButtons")
	return frame and frame:IsA("GuiObject") and frame or nil
end

-- Which purchase station this player's experiment variant uses. nil / any
-- unknown attribute value falls back to the "mailbox" control.
local function stationVariant()
	if player:GetAttribute(State.Player.SkipTimeStation) == "sign" then
		return "sign"
	end
	return "mailbox"
end

local function isNearSkipSign(sign)
	if not (sign and sign.Parent) then
		return false
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = root and root:IsA("BasePart") and StationFocus.InstancePosition(sign) or nil
	return position ~= nil and (root.Position - position).Magnitude <= SKIP_SIGN_DISTANCE
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

local function forEachStationPart(station, callback)
	if not station then
		return
	end
	if station:IsA("BasePart") then
		callback(station)
	end
	for _, descendant in ipairs(station:GetDescendants()) do
		if descendant:IsA("BasePart") then
			callback(descendant)
		end
	end
end

-- Hidden stations must not block movement either. Authored CanCollide values
-- are mixed (decor parts are already non-collidable), so remember each part's
-- original and restore exactly that on reveal.
local function applyStationHidden(station, hidden)
	forEachStationPart(station, function(part)
		if hidden then
			part.LocalTransparencyModifier = 1
			if stationOriginalCanCollide[part] == nil then
				stationOriginalCanCollide[part] = part.CanCollide
			end
			part.CanCollide = false
		else
			part.LocalTransparencyModifier = 0
			local original = stationOriginalCanCollide[part]
			if original ~= nil then
				part.CanCollide = original
				stationOriginalCanCollide[part] = nil
			end
		end
	end)
end

local function setStationHidden(station, hidden)
	if not station then
		return
	end
	local currentlyHidden = stationHiddenStates[station] == true
	if currentlyHidden == hidden then
		if hidden then
			-- Reapply so parts that streamed in after the hide are covered.
			applyStationHidden(station, true)
		end
		return
	end
	applyStationHidden(station, hidden)
	stationHiddenStates[station] = hidden and true or nil
end

local function setSkipSignGuiEnabled(sign, enabled)
	local gui = skipSignGui(sign)
	if gui and gui.Enabled ~= enabled then
		gui.Enabled = enabled
	end
end

local function refreshMailboxVisibility()
	local ownedPlot = ownPlot()
	local seen = {}
	local variant = stationVariant()
	forEachRuntimePlot(function(plot)
		local hidden = plot ~= ownedPlot or tutorialActive
		local mailbox = mailboxForPlot(plot)
		if mailbox then
			seen[mailbox] = true
			setStationHidden(mailbox, hidden or variant ~= "mailbox")
		end
		local sign = skipSignForPlot(plot)
		if sign then
			seen[sign] = true
			local signHidden = hidden or variant ~= "sign"
			-- LocalTransparencyModifier hides the sign parts but not its
			-- SurfaceGui, so toggle the gui alongside.
			setStationHidden(sign, signHidden)
			setSkipSignGuiEnabled(sign, not signHidden)
		end
	end)
	for station in pairs(stationHiddenStates) do
		if not seen[station] or station.Parent == nil then
			applyStationHidden(station, false)
			stationHiddenStates[station] = nil
		end
	end
end

local function profileReady()
	return PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
end

local function requestBlocked()
	return pendingRequestId ~= nil or pendingProductId ~= nil
end

local function canUseStation()
	return not tutorialActive
		and profileReady()
		and player:GetAttribute(State.Player.OfflineProgressPending) ~= true
		and player:GetAttribute(EDIT_MODE_ATTR) ~= true
end

local function canUseMailbox(mailbox)
	return mailbox ~= nil
		and stationVariant() == "mailbox"
		and canUseStation()
		and StationFocus.IsMailboxActive()
end

local function canUseSkipSign(sign)
	return sign ~= nil
		and sign.Parent ~= nil
		and stationVariant() == "sign"
		and canUseStation()
		and isNearSkipSign(sign)
end

local function codeToMessage(code, record)
	if code == "too-far" then
		if record and record.station == "sign" then
			return "Move closer to the sign."
		end
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

local function bindCard(frame, buttonName)
	if not (frame and frame:IsA("GuiObject")) then
		return nil
	end
	buttonName = buttonName or "BuyButton"
	local buyButton = findDescendant(frame, buttonName, "GuiButton")
	if not buyButton then
		warn("[SkipTimeButtonsController] Missing " .. frame:GetFullName() .. "." .. buttonName)
		return nil
	end
	if buttonName == "Hitbox" then
		-- World-gui card: a press-shrink UIScale moves the hitbox under the
		-- cursor mid-press, which cancels the engine click (Activated never
		-- fires). Color feedback is invisible on the transparent hitbox anyway;
		-- bindSignPressEffect tints the card art instead.
		UiEffects.BindButton(buyButton, { pressScale = false, colorTween = false })
		-- The decorative BuyButton sits above the full-card hitbox and would
		-- swallow taps (nothing binds it); let input fall through.
		local decorative = findDescendant(frame, "BuyButton", "GuiButton")
		if decorative then
			decorative.Active = false
			decorative.Selectable = false
			decorative.AutoButtonColor = false
		end
	else
		UiEffects.BindButton(buyButton)
	end
	return {
		frame = frame,
		buyButton = buyButton,
		priceLabel = findDescendant(frame, "Price", "TextLabel"),
		skipAmountLabel = findDescendant(frame, "SkipAmount", "TextLabel"),
		fruitsLabel = findDescendant(frame, "FruitsLabel", "TextLabel"),
		errorLabel = findDescendant(frame, "ErrorLabel", "TextLabel"),
	}
end

-- The sign hitbox is invisible, so UiEffects' color feedback on the button
-- itself never shows; press-scale the card art instead. The hitbox must NOT
-- move while pressed — shifting it under the cursor mid-press cancels the
-- engine click and Activated never fires — so the visual children are wrapped
-- in a frame and only that wrapper scales.
local function bindSignPressEffect(record)
	local visuals = record.frame:FindFirstChild("SignVisuals")
	if not visuals then
		visuals = Instance.new("Frame")
		visuals.Name = "SignVisuals"
		visuals.BackgroundTransparency = 1
		visuals.Size = UDim2.fromScale(1, 1)
		visuals.Parent = record.frame
		for _, child in ipairs(record.frame:GetChildren()) do
			if child ~= visuals and child ~= record.buyButton and child:IsA("GuiObject") then
				child.Parent = visuals
			end
		end
	end
	local scale = visuals:FindFirstChild("SignPressScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "SignPressScale"
		scale.Parent = visuals
	end
	local function setPressed(active)
		TweenService:Create(scale, SIGN_PRESS_TWEEN, {
			Scale = active and SIGN_PRESS_SCALE or 1,
		}):Play()
	end
	RuntimeGuard.Connect(record.buyButton.MouseButton1Down, "SkipTimeButtonsController.SignPressDown", function()
		setPressed(true)
	end)
	RuntimeGuard.Connect(record.buyButton.MouseButton1Up, "SkipTimeButtonsController.SignPressUp", function()
		setPressed(false)
	end)
	RuntimeGuard.Connect(record.buyButton.MouseLeave, "SkipTimeButtonsController.SignPressLeave", function()
		setPressed(false)
	end)
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
	if not record then
		return
	end
	-- Sign cards surface errors as regular toasts instead of on-sign labels;
	-- there is nothing to clear, so nil/empty is a no-op for them.
	if record.station == "sign" then
		if text ~= nil and text ~= "" then
			Notifications.show({
				text = text,
				kind = NotificationConfig.Kinds.Error,
			})
		end
		return
	end
	if not record.errorLabel then
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
	local signRecords = {}
	local boundSign = nil
	local signActive = false
	local isOpen = false
	local transitionToken = 0
	local lastPreviewAt = -math.huge
	local collectAllPreviewFrozen = false
	local cachedCollectAllCount = 0
	local cachedSkipXPById = {}
	local render
	local requestSkip
	local requestCollectAll

	local function forEachRecord(callback)
		for _, record in ipairs(records) do
			callback(record)
		end
		for _, record in ipairs(signRecords) do
			callback(record)
		end
	end

	local function clearAllErrors()
		forEachRecord(function(record)
			setError(record, nil)
		end)
	end

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
		if not (isOpen or signActive) or requestBlocked() or collectAllPreviewFrozen then
			return
		end
		local clock = os.clock()
		if clock - lastPreviewAt < PREVIEW_RECOMPUTE_SECONDS then
			return
		end
		lastPreviewAt = clock
		cachedCollectAllCount = readyCollectAllFruitCount(plot)
		for _, skipId in ipairs(SKIP_IDS) do
			local config = ShopBalance.GrowSkipForSkipId(skipId)
			cachedSkipXPById[skipId] = skipAddedPatchXP(plot, int(config and config.DurationSeconds, 0))
		end
	end

	render = function()
		local plot = ownPlot()
		refreshPreviewCache(plot)
		forEachRecord(function(record)
			local previewActive = if record.station == "sign" then signActive else isOpen
			if record.priceLabel then
				UiEffects.SetTextStack(record.priceLabel, robuxText(record.productId, render))
			end
			if record.kind == "skip" then
				if previewActive and record.skipAmountLabel then
					UiEffects.SetTextStack(record.skipAmountLabel, formatAddedXP(cachedSkipXPById[record.skipId] or 0))
				end
			elseif previewActive and record.kind == "collect-all" and record.fruitsLabel then
				local suffix = cachedCollectAllCount == 1 and " fruit" or " fruits"
				UiEffects.SetTextStack(record.fruitsLabel, NumberFormatter.Format(cachedCollectAllCount) .. suffix)
			end
		end)
	end

	-- The remote target doubles as the station the server distance-checks:
	-- the mailbox for HUD cards, the sign itself for sign cards.
	local function stationTargetFor(record)
		if record.station == "sign" then
			local sign = boundSign
			return canUseSkipSign(sign) and sign or nil
		end
		local mailbox = currentMailbox()
		return canUseMailbox(mailbox) and mailbox or nil
	end

	requestSkip = function(record)
		local plot = ownPlot()
		clearAllErrors()
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
		local target = stationTargetFor(record)
		if not target then
			setError(record, codeToMessage("too-far", record))
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
		pendingRecord = record
		growSkipRequestRemote:FireServer(pendingRequestId, target, record.skipId)
		render()
	end

	requestCollectAll = function(record)
		local plot = ownPlot()
		clearAllErrors()
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
		local target = stationTargetFor(record)
		if not target then
			setError(record, codeToMessage("too-far", record))
			render()
			return
		end
		local readyCount = readyCollectAllFruitCount(plot)
		if readyCount <= 0 then
			cachedCollectAllCount = 0
			setError(record, codeToMessage("no-food"))
			render()
			return
		end
		cachedCollectAllCount = readyCount
		pendingRequestId = nextNegativeRequestId()
		pendingKind = "collect-all"
		pendingRecord = record
		collectAllPreviewFrozen = true
		collectAllRequestRemote:FireServer(pendingRequestId, target)
		render()
	end

	for skipId, record in pairs(recordsBySkipId) do
		RuntimeGuard.Connect(record.buyButton.Activated, "SkipTimeButtonsController." .. skipId, function()
			requestSkip(record)
		end)
	end
	if collectAllRecord then
		RuntimeGuard.Connect(collectAllRecord.buyButton.Activated, "SkipTimeButtonsController.CollectAll", function()
			requestCollectAll(collectAllRecord)
		end)
	end

	local function bindSignCards(sign)
		signRecords = {}
		boundSign = sign
		if not sign then
			return
		end
		local frame = skipSignButtonsFrame(sign)
		if not frame then
			warn("[SkipTimeButtonsController] " .. sign:GetFullName() .. " is missing SurfaceGui.SkipTimeButtons")
			return
		end
		for _, skipId in ipairs(SKIP_IDS) do
			local config = ShopBalance.GrowSkipForSkipId(skipId)
			local record = bindCard(frame:FindFirstChild(skipId), "Hitbox")
			if record then
				record.kind = "skip"
				record.station = "sign"
				record.skipId = skipId
				record.productId = int(config and config.DevProductId, 0)
				record.durationSeconds = int(config and config.DurationSeconds, 0)
				signRecords[#signRecords + 1] = record
				bindSignPressEffect(record)
				RuntimeGuard.Connect(record.buyButton.Activated, "SkipTimeButtonsController.Sign" .. skipId, function()
					requestSkip(record)
				end)
				if skipId == "Skip30m" then
					ensureMythicalTextTween(record.skipAmountLabel)
					bindSlowGradientRotation(findDescendant(record.frame, "BuyButton", "GuiButton"))
				end
			end
		end
		do
			local config = ShopBalance.GetCollectAll()
			local record = bindCard(frame:FindFirstChild("CollectAll"), "Hitbox")
			if record then
				record.kind = "collect-all"
				record.station = "sign"
				record.productId = int(config and config.DevProductId, 0)
				signRecords[#signRecords + 1] = record
				bindSignPressEffect(record)
				RuntimeGuard.Connect(record.buyButton.Activated, "SkipTimeButtonsController.SignCollectAll", function()
					requestCollectAll(record)
				end)
			end
		end
	end

	local function ensureSignBound()
		local sign = skipSignForPlot(ownPlot())
		if sign == boundSign and (sign == nil or sign.Parent ~= nil) then
			return
		end
		bindSignCards(sign and sign.Parent and sign or nil)
	end

	RuntimeGuard.Connect(growSkipResultRemote.OnClientEvent, "SkipTimeButtonsController.GrowSkipResult", function(payload)
		if pendingKind ~= "skip" or type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		local skipId = payload.skipId
		local record = pendingRecord
		if not record then
			record = type(skipId) == "string" and recordsBySkipId[skipId] or nil
		end
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
					pendingRecord = nil
					render()
				end
			end)
		else
			pendingKind = nil
			pendingRecord = nil
			setError(record, codeToMessage(payload.code, record))
		end
		markPreviewDirty()
		render()
	end)

	RuntimeGuard.Connect(collectAllResultRemote.OnClientEvent, "SkipTimeButtonsController.CollectAllResult", function(payload)
		if pendingKind ~= "collect-all" or type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		local record = pendingRecord or collectAllRecord
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
					pendingRecord = nil
					render()
				end
			end)
		else
			pendingKind = nil
			pendingRecord = nil
			setError(record, codeToMessage(payload.code, record))
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
		pendingRecord = nil
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
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.SkipTimeStation), "SkipTimeButtonsController.StationVariantChanged", function()
		markPreviewDirty()
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
				ensureSignBound()
				local variant = stationVariant()
				signActive = variant == "sign"
					and boundSign ~= nil
					and not tutorialActive
					and isNearSkipSign(boundSign)
				if not signActive then
					clearErrors(signRecords)
				end
				local near = variant == "mailbox"
					and mailbox ~= nil
					and not tutorialActive
					and StationFocus.IsMailboxActive()
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
