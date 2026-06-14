local ContextActionService = game:GetService("ContextActionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local ConfettiEffect = require(script.Parent:WaitForChild("ConfettiEffect"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local HoverOver = require(script.Parent:WaitForChild("HoverOver"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SoundEffects = require(script.Parent:WaitForChild("SoundEffects"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local SeedPackShopController = {}

local ROBUX_PANEL_NAME = "RobuxShop"
local ROLL_PANEL_NAME = "PackRollFrame"
local SHOP_MENU_GROUP = "Shop"
local SEED_PACKS_NAME = "SeedPacks"
local PACK_HOLDER_TEMPLATE_NAME = "PackHolder"
local RUNTIME_PACK_HOLDER_NAME = "__SeedPackRollHolder"
local RUNTIME_SLICE_NAME = "__SeedPackSlice"
local CONSOLE_OPEN_KEYCODE = Enum.KeyCode.ButtonX
local FALLBACK_CONSOLE_OPEN_ICON = "rbxasset://textures/ui/Controls/xboxX.png"
local SLICE_CAMERA_SINK_ACTION = "SeedPackShopController.SliceCameraSink"
local SLICE_CAMERA_SINK_PRIORITY = Enum.ContextActionPriority.High.Value + 20

local PACK_REWARD_PREVIEW_OPTIONS = {
	targetMaxDimension = 6,
	zoom = 1.8,
}
local REVEAL_PREVIEW_OPTIONS = {
	targetMaxDimension = 4,
	zoom = 1.65,
}

local SLICE_THICKNESS_MULTIPLIER = 1.35
local SLICE_MIN_DRAG_DISTANCE = 18
local SLICE_FADE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PACK_FADE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REWARD_POP_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FTUE_DRAG_TWEEN = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FTUE_FADE_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FTUE_RESTART_DELAY = 0.18

local player = Players.LocalPlayer
local activeReveal = nil
local revealQueue = {}
local holderStates = {}
local dragging = false
local activeInput = nil
local activeInputType = nil
local dragStartPosition = nil
local lastPosition = nil
local activeSlice = nil
local pendingSliced = {}
local packOpenFtueCompleted = false
local activeFtueDrag = nil
local ftueToken = 0
local cameraSinkBound = false
local productPriceById = {}

local function isSeedPacksAllowed()
	return player:GetAttribute(State.Player.SeedPacksAllowed) == true
end

local function hasConnectedController()
	if UserInputService.GamepadEnabled then
		return true
	end
	local ok, gamepads = pcall(UserInputService.GetConnectedGamepads, UserInputService)
	return ok and type(gamepads) == "table" and #gamepads > 0
end

local function consoleOpenIconImage()
	local ok, image = pcall(UserInputService.GetImageForKeyCode, UserInputService, CONSOLE_OPEN_KEYCODE)
	if ok and type(image) == "string" and image ~= "" then
		return image
	end
	return FALLBACK_CONSOLE_OPEN_ICON
end

local function findDescendant(root, name, className)
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and (not className or descendant:IsA(className)) then
			return descendant
		end
	end
	return nil
end

local function screenPositionFrom(value)
	local valueType = typeof(value)
	if valueType == "Vector2" then
		return value
	elseif valueType == "Vector3" then
		return Vector2.new(value.X, value.Y)
	elseif valueType == "Instance" and value:IsA("InputObject") then
		return screenPositionFrom(value.Position)
	end
	return nil
end

local function pointerPosition(input)
	local inputPosition = screenPositionFrom(input)
	if inputPosition then
		return inputPosition
	end
	return UserInputService:GetMouseLocation()
end

local function isPressInput(input)
	return input
		and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
end

local function sortedGuiChildren(parent, name)
	local children = {}
	for _, child in ipairs(parent and parent:GetChildren() or {}) do
		if child.Name == name and child:IsA("GuiObject") then
			children[#children + 1] = child
		end
	end
	table.sort(children, function(left, right)
		if left.LayoutOrder ~= right.LayoutOrder then
			return left.LayoutOrder < right.LayoutOrder
		end
		if left.Position.X.Scale ~= right.Position.X.Scale then
			return left.Position.X.Scale < right.Position.X.Scale
		end
		return left.Position.X.Offset < right.Position.X.Offset
	end)
	return children
end

local function setTextStack(root, text)
	UiEffects.SetTextStack(root, tostring(text or ""))
end

local function robuxText(productId, onLoaded)
	productId = tonumber(productId) or 0
	if productId <= 0 then
		return "Robux"
	end
	if productPriceById[productId] then
		return productPriceById[productId]
	end

	productPriceById[productId] = "Robux"
	RuntimeGuard.Spawn("SeedPackShopController.ProductInfo", function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, productId, Enum.InfoType.Product)
		if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
			productPriceById[productId] = NumberFormatter.Format(info.PriceInRobux)
			if onLoaded then
				onLoaded()
			end
		end
	end)
	return productPriceById[productId]
end

local function releaseSliceCameraSink()
	if not cameraSinkBound then
		return
	end
	ContextActionService:UnbindAction(SLICE_CAMERA_SINK_ACTION)
	cameraSinkBound = false
end

local function bindSliceCameraSink()
	if cameraSinkBound then
		return
	end
	cameraSinkBound = true
	ContextActionService:BindActionAtPriority(
		SLICE_CAMERA_SINK_ACTION,
		function(_, _, inputObject)
			if dragging and activeInputType == Enum.UserInputType.Touch and inputObject == activeInput then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		SLICE_CAMERA_SINK_PRIORITY,
		Enum.UserInputType.Touch
	)
end

local function resetDragState()
	dragging = false
	activeInput = nil
	activeInputType = nil
	dragStartPosition = nil
	lastPosition = nil
	releaseSliceCameraSink()
end

local function setRarityLabel(label, rarity)
	if not label then
		return
	end
	local value = type(rarity) == "string" and rarity ~= "" and rarity or Rarities.Common
	setTextStack(label, value)
	label.TextColor3 = Rarities.ColorFor(value) or Rarities.ColorFor(Rarities.Common)
end

local function currentMenu()
	local panel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	return panel and panel:FindFirstAncestorOfClass("ScreenGui") or nil
end

local function seedPacksFrame()
	local panel = MenuGui.GetFrame(ROBUX_PANEL_NAME, "SeedPackShopController")
	local holder = panel and findDescendant(panel, "SFHolder", "ScrollingFrame")
	local seedPacks = holder and holder:FindFirstChild(SEED_PACKS_NAME)
	if seedPacks and seedPacks:IsA("GuiObject") then
		return seedPacks, holder
	end
	return nil, holder
end

local function applySeedPacksVisibility()
	local seedPacks = seedPacksFrame()
	if seedPacks then
		seedPacks.Visible = isSeedPacksAllowed()
	end
end

local function packFrame(packId)
	local seedPacks = seedPacksFrame()
	local frame = seedPacks and seedPacks:FindFirstChild(packId)
	return frame and frame:IsA("GuiObject") and frame or nil
end

local function packImage(packId)
	local frame = packFrame(packId)
	local iconHolder = frame and frame:FindFirstChild("IconHolder")
	local icon = iconHolder and iconHolder:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		return icon.Image
	end
	local packButton = frame and frame:FindFirstChild("Pack")
	if packButton and packButton:IsA("ImageButton") then
		return packButton.Image
	end
	return ""
end

local function renderRewardSlot(slot, reward, pack)
	local icon = findDescendant(slot, "Icon", "ViewportFrame")
	local chance = findDescendant(slot, "Chance", "TextLabel")
	local seedId = reward and reward.SeedId
	local rarity = Seeds.RarityFor(seedId)
	local displayName = Seeds.DisplayNameFor(seedId)
	ViewportPreview.Render(icon, Seeds.GetTemplate(seedId), PACK_REWARD_PREVIEW_OPTIONS)
	if chance then
		setTextStack(chance, ShopBalance.ChanceText(pack, reward))
	end
	HoverOver.Bind(slot, function()
		return {
			name = displayName,
			rarity = rarity,
		}
	end)
end

local function renderPackCard(pack)
	local frame = packFrame(pack.PackId)
	if not frame then
		warn("[SeedPackShopController] Missing SeedPacks." .. tostring(pack.PackId))
		return nil
	end

	local title = frame:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		setTextStack(title, pack.DisplayName)
	end

	local items = frame:FindFirstChild("Items")
	local slots = sortedGuiChildren(items, "Template")
	for index, reward in ipairs(pack.Rewards or {}) do
		if slots[index] then
			renderRewardSlot(slots[index], reward, pack)
		end
	end

	local buyButton = frame:FindFirstChild("BuyButton")
	local buyThree = frame:FindFirstChild("BuyThree")
	local buyButtonPrice = buyButton and findDescendant(buyButton, "Price", "TextLabel")
	if buyButton and buyButton:IsA("GuiButton") then
		UiEffects.BindButton(buyButton)
		if not buyButtonPrice then
			warn("[SeedPackShopController] Missing SeedPacks." .. tostring(pack.PackId) .. ".BuyButton.Price")
		end
	end
	if buyThree and buyThree:IsA("GuiButton") then
		UiEffects.BindButton(buyThree)
	end

	return {
		pack = pack,
		buyButton = buyButton and buyButton:IsA("GuiButton") and buyButton or nil,
		buyThree = buyThree and buyThree:IsA("GuiButton") and buyThree or nil,
		buyButtonPrice = buyButtonPrice,
	}
end

local function promptProduct(productId)
	productId = tonumber(productId) or 0
	if productId <= 0 then
		return
	end
	if not isSeedPacksAllowed() then
		return
	end
	if PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
		return
	end
	RuntimeGuard.Run("SeedPackShopController.PromptProductPurchase", function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
end

local function renderRows(rows)
	applySeedPacksVisibility()
	local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true and isSeedPacksAllowed()
	for _, row in ipairs(rows) do
		local buyOneProductId = tonumber(row.pack.DevProductId) or 0
		local buyThreeProductId = tonumber(row.pack.BuyThreeDevProductId) or 0
		if row.buyButton then
			setTextStack(row.buyButtonPrice, robuxText(buyOneProductId, function()
				renderRows(rows)
			end))
			UiEffects.SetButtonEnabled(row.buyButton, ready and buyOneProductId > 0)
		end
		if row.buyThree then
			UiEffects.SetButtonEnabled(row.buyThree, ready and buyThreeProductId > 0)
		end
	end
end

local function hideSiblingPanels(panel)
	local menu = currentMenu()
	if not menu then
		return
	end
	for _, child in ipairs(menu:GetChildren()) do
		if child:IsA("GuiObject") and child ~= panel then
			child.Visible = false
		end
	end
end

local function clearRuntimeHolders(itemRollHolder)
	for _, child in ipairs(itemRollHolder:GetChildren()) do
		if child.Name == RUNTIME_PACK_HOLDER_NAME then
			child:Destroy()
		end
	end
end

local function clearRuntimeSlices(panel)
	activeSlice = nil
	for _, child in ipairs(panel:GetChildren()) do
		if child.Name == RUNTIME_SLICE_NAME then
			child:Destroy()
		end
	end
end

local function setRewardVisible(holder, visible)
	for _, name in ipairs({ "Result", "RayResult", "ItemName", "Rarity", "Chance" }) do
		local child = holder:FindFirstChild(name)
		if child and child:IsA("GuiObject") then
			child.Visible = visible
		end
	end
end

local function setConsoleHintVisible(panel, visible)
	local show = visible == true and hasConnectedController()
	local openHint = panel and panel:FindFirstChild("OpenHint")
	if openHint and openHint:IsA("GuiObject") then
		openHint.Visible = show
	end

	local consoleIcon = panel and panel:FindFirstChild("ConsoleIcon")
	if consoleIcon and consoleIcon:IsA("ImageLabel") then
		consoleIcon.Image = consoleOpenIconImage()
		consoleIcon.Visible = show
	end
end

local function hideFtueDrag(holder)
	local drag = holder and holder:FindFirstChild("FTUEDrag")
	if drag and drag:IsA("ImageLabel") then
		drag.Visible = false
		drag.ImageTransparency = 0
	end
end

local function configureHolder(holder, payload, result)
	holder.Visible = true
	holder.Name = RUNTIME_PACK_HOLDER_NAME

	local packButton = holder:FindFirstChild("Pack")
	if packButton and packButton:IsA("ImageButton") then
		packButton.Visible = true
		packButton.Active = false
		packButton.Image = packImage(payload.packId)
		packButton.ImageTransparency = 0
	end

	setRewardVisible(holder, false)
	hideFtueDrag(holder)
	local resultViewport = holder:FindFirstChild("Result")
	if resultViewport and resultViewport:IsA("ViewportFrame") then
		ViewportPreview.Render(resultViewport, Seeds.GetTemplate(result.seedId), REVEAL_PREVIEW_OPTIONS)
	end

	setTextStack(holder:FindFirstChild("ItemName"), result.displayName or Seeds.DisplayNameFor(result.seedId))
	setRarityLabel(holder:FindFirstChild("Rarity"), result.rarity)
	setTextStack(holder:FindFirstChild("Chance"), result.chanceText or "")
end

local function buildReveal(payload)
	local panel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	if not panel then
		return false
	end
	local itemRollHolder = panel:FindFirstChild("ItemRollHolder")
	local template = itemRollHolder and itemRollHolder:FindFirstChild(PACK_HOLDER_TEMPLATE_NAME)
	local continueButton = panel:FindFirstChild("ContinueButton")
	local sliceTemplate = panel:FindFirstChild("Slice")
	if not (itemRollHolder and itemRollHolder:IsA("GuiObject") and template and template:IsA("GuiObject")) then
		warn("[SeedPackShopController] PackRollFrame missing ItemRollHolder.PackHolder")
		return false
	end

	clearRuntimeHolders(itemRollHolder)
	clearRuntimeSlices(panel)
	holderStates = {}
	pendingSliced = {}
	ftueToken += 1
	activeFtueDrag = nil
	resetDragState()
	template.Visible = false
	if sliceTemplate and sliceTemplate:IsA("GuiObject") then
		sliceTemplate.Visible = false
	end
	if continueButton and continueButton:IsA("GuiButton") then
		continueButton.Visible = false
	end
	setConsoleHintVisible(panel, true)

	for index, result in ipairs(payload.results or {}) do
		local holder = template:Clone()
		configureHolder(holder, payload, result)
		holder.LayoutOrder = index
		holder.Parent = itemRollHolder
		holderStates[#holderStates + 1] = {
			holder = holder,
			pack = holder:FindFirstChild("Pack"),
			opened = false,
		}
	end

	return #holderStates > 0
end

local function allOpened()
	if #holderStates == 0 then
		return false
	end
	for _, state in ipairs(holderStates) do
		if not state.opened then
			return false
		end
	end
	return true
end

local function refreshConsoleHint()
	local panel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	setConsoleHintVisible(panel, activeReveal ~= nil and not allOpened())
end

local function showContinue()
	local panel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	local continueButton = panel and panel:FindFirstChild("ContinueButton")
	if continueButton and continueButton:IsA("GuiButton") then
		continueButton.Visible = true
	end
	setConsoleHintVisible(panel, false)
end

local function popReward(holder)
	local result = holder:FindFirstChild("Result")
	if result and result:IsA("GuiObject") then
		local scale = result:FindFirstChild("SeedPackRevealScale")
		if not scale then
			scale = Instance.new("UIScale")
			scale.Name = "SeedPackRevealScale"
			scale.Parent = result
		end
		scale.Scale = 0.2
		TweenService:Create(scale, REWARD_POP_TWEEN, {
			Scale = 1,
		}):Play()
	end
end

local function stopFtueCue(markCompleted)
	ftueToken += 1
	if markCompleted then
		packOpenFtueCompleted = true
	end
	if activeFtueDrag and activeFtueDrag.Parent then
		activeFtueDrag.Visible = false
		activeFtueDrag.ImageTransparency = 0
		activeFtueDrag.Rotation = 0
	end
	activeFtueDrag = nil
	for _, state in ipairs(holderStates) do
		hideFtueDrag(state.holder)
	end
end

local function openHolder(state)
	if not state or state.opened then
		return
	end
	stopFtueCue(true)
	state.opened = true
	local holder = state.holder
	local pack = state.pack
	if not (holder and holder.Parent) then
		return
	end

	local function reveal()
		if pack and pack.Parent then
			pack.Visible = false
		end
		setRewardVisible(holder, true)
		popReward(holder)
		if allOpened() then
			showContinue()
		end
	end

	if pack and pack:IsA("ImageButton") then
		local tween = TweenService:Create(pack, PACK_FADE_TWEEN, {
			ImageTransparency = 1,
		})
		RuntimeGuard.Connect(tween.Completed, "SeedPackShopController.PackFadeCompleted", reveal)
		tween:Play()
	else
		reveal()
	end
end

local function ftuePathFor(state, drag)
	local holder = state and state.holder
	local pack = state and state.pack
	if not (holder and pack and drag and holder:IsA("GuiObject") and pack:IsA("GuiObject") and drag:IsA("GuiObject")) then
		return nil
	end
	local holderPosition = holder.AbsolutePosition
	local packPosition = pack.AbsolutePosition - holderPosition
	local packSize = pack.AbsoluteSize
	local center = packPosition + (packSize * 0.5)
	local halfSpan = math.max(math.min(packSize.X, packSize.Y) * 0.42, 16)
	local startPoint = center - Vector2.new(halfSpan, halfSpan)
	local endPoint = center + Vector2.new(halfSpan, halfSpan)
	return UDim2.fromOffset(startPoint.X, startPoint.Y), UDim2.fromOffset(endPoint.X, endPoint.Y)
end

local function startFtueCue()
	if packOpenFtueCompleted or activeFtueDrag or hasConnectedController() then
		return
	end
	local targetState = nil
	for _, state in ipairs(holderStates) do
		if not state.opened and state.holder and state.holder.Parent then
			targetState = state
			break
		end
	end
	if not targetState then
		return
	end

	local drag = targetState.holder:FindFirstChild("FTUEDrag")
	if not (drag and drag:IsA("ImageLabel")) then
		return
	end

	ftueToken += 1
	local token = ftueToken
	activeFtueDrag = drag
	drag.AnchorPoint = Vector2.new(0.5, 0.5)
	drag.Rotation = 0
	drag.Visible = true

	local function playLoop()
		if token ~= ftueToken or packOpenFtueCompleted or targetState.opened or not (drag and drag.Parent) then
			return
		end
		local startPosition, endPosition = ftuePathFor(targetState, drag)
		if not (startPosition and endPosition) then
			return
		end
		drag.Position = startPosition
		drag.ImageTransparency = 0
		local moveTween = TweenService:Create(drag, FTUE_DRAG_TWEEN, {
			Position = endPosition,
		})
		RuntimeGuard.Connect(moveTween.Completed, "SeedPackShopController.FtueDragMoveCompleted", function()
			if token ~= ftueToken or packOpenFtueCompleted or targetState.opened or not (drag and drag.Parent) then
				return
			end
			local fadeTween = TweenService:Create(drag, FTUE_FADE_TWEEN, {
				ImageTransparency = 1,
			})
			RuntimeGuard.Connect(fadeTween.Completed, "SeedPackShopController.FtueDragFadeCompleted", function()
				if token ~= ftueToken or packOpenFtueCompleted or targetState.opened or not (drag and drag.Parent) then
					return
				end
				task.delay(FTUE_RESTART_DELAY, playLoop)
			end)
			fadeTween:Play()
		end)
		moveTween:Play()
	end

	playLoop()
end

local function rectFor(guiObject)
	if not (guiObject and guiObject:IsA("GuiObject")) then
		return nil
	end
	local pos = guiObject.AbsolutePosition
	local size = guiObject.AbsoluteSize
	return {
		left = pos.X,
		right = pos.X + size.X,
		top = pos.Y,
		bottom = pos.Y + size.Y,
	}
end

local function pointInRect(point, rect)
	return rect
		and point.X >= rect.left
		and point.X <= rect.right
		and point.Y >= rect.top
		and point.Y <= rect.bottom
end

local function orientation(a, b, c)
	local value = (b.Y - a.Y) * (c.X - b.X) - (b.X - a.X) * (c.Y - b.Y)
	if math.abs(value) < 0.001 then
		return 0
	end
	return value > 0 and 1 or 2
end

local function onSegment(a, b, c)
	return b.X <= math.max(a.X, c.X)
		and b.X >= math.min(a.X, c.X)
		and b.Y <= math.max(a.Y, c.Y)
		and b.Y >= math.min(a.Y, c.Y)
end

local function segmentsIntersect(a, b, c, d)
	local o1 = orientation(a, b, c)
	local o2 = orientation(a, b, d)
	local o3 = orientation(c, d, a)
	local o4 = orientation(c, d, b)
	if o1 ~= o2 and o3 ~= o4 then
		return true
	end
	return (o1 == 0 and onSegment(a, c, b))
		or (o2 == 0 and onSegment(a, d, b))
		or (o3 == 0 and onSegment(c, a, d))
		or (o4 == 0 and onSegment(c, b, d))
end

local function segmentIntersectsRect(a, b, rect)
	if not rect then
		return false
	end
	if pointInRect(a, rect) or pointInRect(b, rect) then
		return true
	end
	local topLeft = Vector2.new(rect.left, rect.top)
	local topRight = Vector2.new(rect.right, rect.top)
	local bottomLeft = Vector2.new(rect.left, rect.bottom)
	local bottomRight = Vector2.new(rect.right, rect.bottom)
	return segmentsIntersect(a, b, topLeft, topRight)
		or segmentsIntersect(a, b, topRight, bottomRight)
		or segmentsIntersect(a, b, bottomRight, bottomLeft)
		or segmentsIntersect(a, b, bottomLeft, topLeft)
end

local function markIntersectedHolders(fromPosition, toPosition)
	for _, state in ipairs(holderStates) do
		if not state.opened and state.pack and segmentIntersectsRect(fromPosition, toPosition, rectFor(state.pack)) then
			pendingSliced[state] = true
		end
	end
end

local function tweenSliceAway(slice)
	if not (slice and slice.Parent) then
		return
	end
	TweenService:Create(slice, SLICE_FADE_TWEEN, {
		BackgroundTransparency = 1,
	}):Play()
	local background = slice:FindFirstChild("Background")
	if background and background:IsA("ImageLabel") then
		TweenService:Create(background, SLICE_FADE_TWEEN, {
			ImageTransparency = 1,
		}):Play()
	end
	task.delay(SLICE_FADE_TWEEN.Time, function()
		if slice and slice.Parent then
			slice:Destroy()
		end
	end)
end

local function updateSliceFrame(slice, startPosition, endPosition)
	if not (slice and slice.Parent and startPosition and endPosition) then
		return
	end
	local panel = slice.Parent
	if not panel:IsA("GuiObject") then
		return
	end
	local delta = endPosition - startPosition
	local distance = math.max(delta.Magnitude, 1)
	local panelPosition = panel.AbsolutePosition
	local midpoint = (startPosition + endPosition) * 0.5
	slice.Position = UDim2.fromOffset(midpoint.X - panelPosition.X, midpoint.Y - panelPosition.Y)
	slice.Size = UDim2.new(0, distance, slice.Size.Y.Scale, slice.Size.Y.Offset)
	slice.Rotation = math.deg(math.atan2(delta.Y, delta.X))
end

local function createSliceFrame(startPosition, endPosition)
	local panel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	local template = panel and panel:FindFirstChild("Slice")
	if not (panel and template and template:IsA("GuiObject")) then
		return nil
	end

	local slice = template:Clone()
	slice.Name = RUNTIME_SLICE_NAME
	slice.AnchorPoint = Vector2.new(0.5, 0.5)
	slice.Visible = true
	slice.ZIndex = math.max(slice.ZIndex, 50)
	slice.Parent = panel
	slice.Size = UDim2.new(
		0,
		1,
		template.Size.Y.Scale * SLICE_THICKNESS_MULTIPLIER,
		template.Size.Y.Offset * SLICE_THICKNESS_MULTIPLIER
	)
	local background = slice:FindFirstChild("Background")
	if background and background:IsA("GuiObject") then
		background.AnchorPoint = Vector2.new(0.5, 0.5)
		background.Position = UDim2.fromScale(0.5, 0.5)
		background.Size = UDim2.fromScale(1, 1)
		background.Rotation = 0
	end
	for _, descendant in ipairs(slice:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = math.max(descendant.ZIndex, slice.ZIndex + 1)
		end
	end
	updateSliceFrame(slice, startPosition, endPosition or startPosition)
	return slice
end

local function finishDrag(endPosition)
	if not dragging then
		return
	end
	local startPosition = dragStartPosition
	local slice = activeSlice
	activeSlice = nil
	resetDragState()

	if not (startPosition and endPosition) or (endPosition - startPosition).Magnitude < SLICE_MIN_DRAG_DISTANCE then
		pendingSliced = {}
		tweenSliceAway(slice)
		return
	end
	updateSliceFrame(slice, startPosition, endPosition)
	for state in pairs(pendingSliced) do
		openHolder(state)
	end
	pendingSliced = {}
	tweenSliceAway(slice)
end

local function beginDrag(input)
	if not activeReveal or allOpened() then
		return
	end
	local position = pointerPosition(input)
	if not position then
		return
	end
	dragging = true
	activeInput = input
	activeInputType = input.UserInputType
	dragStartPosition = position
	lastPosition = position
	activeSlice = createSliceFrame(position, position)
	pendingSliced = {}
	if activeInputType == Enum.UserInputType.Touch then
		bindSliceCameraSink()
	end
end

local function continueDrag(input)
	if not dragging then
		return
	end
	if activeInputType == Enum.UserInputType.Touch and input ~= activeInput then
		return
	end
	if activeInputType == Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.MouseMovement then
		return
	end

	local position = pointerPosition(input)
	if not (position and lastPosition) then
		return
	end
	markIntersectedHolders(lastPosition, position)
	updateSliceFrame(activeSlice, dragStartPosition, position)
	lastPosition = position
end

local function endDrag(input)
	if not dragging then
		return
	end
	if activeInputType == Enum.UserInputType.Touch and input ~= activeInput then
		return
	end
	if activeInputType == Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	finishDrag(pointerPosition(input))
end

local function openAllWithKeybind()
	if not activeReveal or allOpened() then
		return
	end
	local left, top, right, bottom = nil, nil, nil, nil
	for _, state in ipairs(holderStates) do
		if not state.opened and state.pack then
			local rect = rectFor(state.pack)
			if rect then
				left = left and math.min(left, rect.left) or rect.left
				top = top and math.min(top, rect.top) or rect.top
				right = right and math.max(right, rect.right) or rect.right
				bottom = bottom and math.max(bottom, rect.bottom) or rect.bottom
			end
			openHolder(state)
		end
	end
	if left and top and right and bottom then
		local slice = createSliceFrame(Vector2.new(left, top), Vector2.new(right, bottom))
		task.delay(0.25, function()
			tweenSliceAway(slice)
		end)
	end
end

local function scrollToSeedPacks()
	local seedPacks, holder = seedPacksFrame()
	if not (seedPacks and holder and holder:IsA("ScrollingFrame")) then
		return
	end
	task.defer(function()
		if not (seedPacks.Parent and holder.Parent) then
			return
		end
		local relativeY = seedPacks.AbsolutePosition.Y - holder.AbsolutePosition.Y
		local targetY = holder.CanvasPosition.Y + relativeY
		local maxY = math.max(holder.AbsoluteCanvasSize.Y - holder.AbsoluteWindowSize.Y, 0)
		holder.CanvasPosition = Vector2.new(holder.CanvasPosition.X, math.clamp(targetY, 0, maxY))
	end)
end

local function showNextReveal()
	local nextPayload = table.remove(revealQueue, 1)
	if not nextPayload then
		activeReveal = nil
		MenuGui.OpenPanel(ROBUX_PANEL_NAME)
		scrollToSeedPacks()
		return
	end
	activeReveal = nextPayload
	if buildReveal(nextPayload) then
		MenuGui.OpenPanel(ROLL_PANEL_NAME)
		task.delay(0.3, startFtueCue)
	else
		showNextReveal()
	end
end

local function enqueueReveal(payload)
	if type(payload) ~= "table" or payload.action ~= "reveal" or type(payload.results) ~= "table" then
		return
	end
	ConfettiEffect.Emit()
	SoundEffects.Play(SoundEffects.Names.RollReveal)
	revealQueue[#revealQueue + 1] = payload
	if not activeReveal then
		showNextReveal()
	end
end

function SeedPackShopController.start()
	local robuxPanel = MenuGui.GetFrame(ROBUX_PANEL_NAME, "SeedPackShopController")
	local rollPanel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	if not (robuxPanel and rollPanel) then
		return
	end

	applySeedPacksVisibility()

	local rows = {}
	for _, pack in ipairs(ShopBalance.AllSeedPacks()) do
		local row = renderPackCard(pack)
		if row then
			rows[#rows + 1] = row
			if row.buyButton then
				RuntimeGuard.Connect(row.buyButton.Activated, "SeedPackShopController.BuyOne." .. pack.PackId, function()
					promptProduct(pack.DevProductId)
				end)
			end
			if row.buyThree then
				RuntimeGuard.Connect(row.buyThree.Activated, "SeedPackShopController.BuyThree." .. pack.PackId, function()
					promptProduct(pack.BuyThreeDevProductId)
				end)
			end
		end
	end

	local rollPanelState = UiEffects.PreparePanel(rollPanel)
	local rollOpen = false
	MenuGui.RegisterPanel(ROLL_PANEL_NAME, {
		group = SHOP_MENU_GROUP,
		open = function()
			rollOpen = true
			hideSiblingPanels(rollPanel)
			UiEffects.PlayOpen(rollPanel, rollPanelState)
		end,
		close = function(switching)
			rollOpen = false
			resetDragState()
			if switching then
				rollPanel.Visible = false
				rollPanel.Position = rollPanelState.closedPosition
				rollPanel.Size = rollPanelState.closedSize
				return
			end
			UiEffects.PlayClose(rollPanel, rollPanelState)
		end,
		refresh = function()
			if rollOpen then
				hideSiblingPanels(rollPanel)
			end
		end,
	})

	local continueButton = rollPanel:FindFirstChild("ContinueButton")
	if continueButton and continueButton:IsA("GuiButton") then
		UiEffects.BindButton(continueButton)
		RuntimeGuard.Connect(continueButton.Activated, "SeedPackShopController.Continue", function()
			if not allOpened() then
				return
			end
			showNextReveal()
		end)
	end

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.SeedPackPurchaseResult).OnClientEvent, "SeedPackShopController.Result", enqueueReveal)
	RuntimeGuard.Connect(UserInputService.InputBegan, "SeedPackShopController.InputBegan", function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.X or input.KeyCode == CONSOLE_OPEN_KEYCODE then
			openAllWithKeybind()
		elseif isPressInput(input) then
			beginDrag(input)
		end
	end)
	RuntimeGuard.Connect(UserInputService.InputChanged, "SeedPackShopController.InputChanged", continueDrag)
	RuntimeGuard.Connect(UserInputService.InputEnded, "SeedPackShopController.InputEnded", endDrag)
	RuntimeGuard.Connect(UserInputService.GamepadConnected, "SeedPackShopController.GamepadConnected", function()
		stopFtueCue(false)
		refreshConsoleHint()
	end)
	RuntimeGuard.Connect(UserInputService.GamepadDisconnected, "SeedPackShopController.GamepadDisconnected", refreshConsoleHint)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, function()
		renderRows(rows)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.SeedPacksAllowed), "SeedPackShopController.SeedPacksAllowed", function()
		renderRows(rows)
	end)
	renderRows(rows)
end

return SeedPackShopController
