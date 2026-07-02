local ContextActionService = game:GetService("ContextActionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
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
local FEATURED_SECTION_NAME = "Featured"
local SEED_PACKS_NAME = "SeedPacks"
local CASH_PACKS_NAME = "CashPacks"
local PACK_HOLDER_TEMPLATE_NAME = "PackHolder"
local RUNTIME_PACK_HOLDER_NAME = "__SeedPackRollHolder"
local RUNTIME_SLICE_NAME = "__SeedPackSlice"
local CONSOLE_OPEN_KEYCODE = Enum.KeyCode.ButtonX
local FALLBACK_CONSOLE_OPEN_ICON = "rbxasset://textures/ui/Controls/xboxX.png"
local SLICE_CAMERA_SINK_ACTION = "SeedPackShopController.SliceCameraSink"
local SLICE_CAMERA_SINK_PRIORITY = Enum.ContextActionPriority.High.Value + 20
local MAX_REVEAL_BATCH_SIZE = 3
local ADVANCE_INPUT_GRACE_SECONDS = 0.12
local RAINBOW_ROTATION_DEGREES_PER_SECOND = 90

local PACK_REWARD_PREVIEW_OPTIONS = {
	targetMaxDimension = 6,
	zoom = 1.8,
	colorSaturation = 2.5,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}
-- 3D pack icons: static, dead-on front, no turntable spin.
local PACK_ICON_NAME = "PackIcon"
local SEED_PACKS_FOLDER_NAME = "SeedPacks"
local PACK_ICON_PREVIEW_OPTIONS = {
	rotate = false,
	yawDegrees = -135,
	zoom = 2.43,
	cameraHeightFactor = 0,
	colorSaturation = 1.2,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}
-- Main/Highlight rarity colour animation (SeedPack stays authored/static).
-- Epic/Secret: Highlight tracks Main's colour a beat behind, darkened to keep
-- the authored shading relationship (Highlight is ~61% of Main's brightness).
-- Durian's rainbow runs synced on both parts (shading only, no time offset).
local PACK_COLOR_PERIOD_SECONDS = 4
local PACK_HIGHLIGHT_PHASE_SECONDS = 0.75
local PACK_HIGHLIGHT_SHADE = 100 / 163
local PACK_ANIMATION_BRIGHTNESS = 1.55
local PACK_COLOR_ANIMATIONS = {
	EpicSeedPack = { from = Color3.fromRGB(197, 47, 216), to = Color3.fromRGB(56, 0, 198) },
	SecretSeedPack = { from = Color3.fromRGB(255, 255, 255), to = Color3.fromRGB(0, 0, 0) },
	DurianPack = { rainbow = true },
}
local REVEAL_PREVIEW_OPTIONS = {
	targetMaxDimension = 4,
	zoom = 1.65,
	colorSaturation = 2.5,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}

local SLICE_THICKNESS_MULTIPLIER = 1.35
local SLICE_MIN_DRAG_DISTANCE = 18
local SLICE_FADE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PACK_FADE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REWARD_POP_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SHOP_SCROLL_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
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
local awaitingAdvance = false
local advanceReadyAt = 0
local lastRevealSourceSection = SEED_PACKS_NAME
local rainbowGradients = {}
local rainbowConnection = nil
local shopScrollTween = nil

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

local function setTextStack(root, text)
	UiEffects.SetTextStack(root, tostring(text or ""))
end

local function robuxText(productId, onLoaded)
	productId = tonumber(productId) or 0
	if productId <= 0 then
		return NumberFormatter.Robux(0)
	end
	if productPriceById[productId] then
		return productPriceById[productId]
	end

	productPriceById[productId] = NumberFormatter.Robux(0)
	RuntimeGuard.Spawn("SeedPackShopController.ProductInfo", function()
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

local function shopFrames()
	local panel = MenuGui.GetFrame(ROBUX_PANEL_NAME, "SeedPackShopController")
	local holder = panel and findDescendant(panel, "SFHolder", "ScrollingFrame")
	local featured = holder and holder:FindFirstChild(FEATURED_SECTION_NAME)
	local seedPacks = holder and holder:FindFirstChild(SEED_PACKS_NAME)
	local cashPacks = holder and holder:FindFirstChild(CASH_PACKS_NAME)
	return panel,
		holder,
		featured and featured:IsA("GuiObject") and featured or nil,
		seedPacks and seedPacks:IsA("GuiObject") and seedPacks or nil,
		cashPacks and cashPacks:IsA("GuiObject") and cashPacks or nil
end

local function shopSection(sectionName)
	local _, holder, featured, seedPacks, cashPacks = shopFrames()
	if sectionName == FEATURED_SECTION_NAME then
		return featured, holder
	elseif sectionName == SEED_PACKS_NAME then
		return seedPacks, holder
	elseif sectionName == CASH_PACKS_NAME then
		return cashPacks, holder
	end
	return nil, holder
end

local function applySeedPacksVisibility(rows)
	local _, _, _, seedPacks = shopFrames()
	local allowed = isSeedPacksAllowed()
	if seedPacks then
		seedPacks.Visible = allowed
	end
	for _, row in ipairs(rows or {}) do
		if row.frame and row.pack and row.pack.Featured == true then
			row.frame.Visible = allowed
		end
	end
end

local function packFrameForPack(pack)
	local section = pack and pack.Featured == true and shopSection(FEATURED_SECTION_NAME) or shopSection(SEED_PACKS_NAME)
	local frame = section and section:FindFirstChild(pack and pack.PackId or "")
	return frame and frame:IsA("GuiObject") and frame or nil
end

local function packModelFor(packId)
	local misc = Assets.Find("Misc")
	local packsFolder = misc and misc:FindFirstChild(SEED_PACKS_FOLDER_NAME)
	local model = packsFolder and type(packId) == "string" and packsFolder:FindFirstChild(packId) or nil
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

-- One shared heartbeat animates Main/Highlight in every live pack-icon
-- viewport clone; it exists only while animated entries do, and prunes
-- entries whose clones were destroyed (viewport re-render or UI teardown).
local animatedPackEntries = {}
local packAnimationConnection = nil

local function stopPackAnimationIfIdle()
	if packAnimationConnection and next(animatedPackEntries) == nil then
		packAnimationConnection:Disconnect()
		packAnimationConnection = nil
	end
end

local function packAnimationColor(animation, timeSeconds)
	local color
	if animation.rainbow then
		color = Rarities.RainbowColorAt(timeSeconds)
	else
		local alpha = 0.5 + 0.5 * math.sin(timeSeconds * math.pi * 2 / PACK_COLOR_PERIOD_SECONDS)
		color = animation.from:Lerp(animation.to, alpha)
	end
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, s, math.clamp(v * PACK_ANIMATION_BRIGHTNESS, 0, 1))
end

local function shadedColor(color)
	return Color3.new(
		color.R * PACK_HIGHLIGHT_SHADE,
		color.G * PACK_HIGHLIGHT_SHADE,
		color.B * PACK_HIGHLIGHT_SHADE
	)
end

local function ensurePackAnimationLoop()
	if packAnimationConnection then
		return
	end
	packAnimationConnection = RuntimeGuard.Connect(RunService.Heartbeat, "SeedPackShopController.PackColors", function()
		local now = os.clock()
		for entry in pairs(animatedPackEntries) do
			if not (entry.main.Parent and (not entry.highlight or entry.highlight.Parent)) then
				animatedPackEntries[entry] = nil
			else
				entry.main.Color = packAnimationColor(entry.animation, now)
				if entry.highlight then
					-- Rainbow packs run both parts in sync; the others trail
					-- the Highlight a beat behind. Shading applies to both.
					local highlightTime = entry.animation.rainbow and now or now - PACK_HIGHLIGHT_PHASE_SECONDS
					entry.highlight.Color = shadedColor(packAnimationColor(entry.animation, highlightTime))
				end
			end
		end
		stopPackAnimationIfIdle()
	end)
end

local function registerPackAnimation(viewport, packId)
	local animation = PACK_COLOR_ANIMATIONS[packId]
	if not animation then
		return
	end
	local world = viewport:FindFirstChildOfClass("WorldModel")
	local main = world and world:FindFirstChild("Main", true)
	local highlight = world and world:FindFirstChild("Highlight", true)
	if not (main and main:IsA("BasePart")) then
		return
	end
	animatedPackEntries[{
		main = main,
		highlight = highlight and highlight:IsA("BasePart") and highlight or nil,
		animation = animation,
	}] = true
	ensurePackAnimationLoop()
end

local function renderPackIcon(container, packId)
	local icon = findDescendant(container, PACK_ICON_NAME, "ViewportFrame")
	if not icon then
		warn("[SeedPackShopController] Missing " .. PACK_ICON_NAME .. " ViewportFrame for pack " .. tostring(packId))
		return
	end
	icon.ImageTransparency = 0
	local rendered = ViewportPreview.Render(icon, packModelFor(packId), PACK_ICON_PREVIEW_OPTIONS)
	if rendered then
		registerPackAnimation(icon, packId)
	else
		warn("[SeedPackShopController] Missing SeedPacks model for pack " .. tostring(packId))
	end
end

local function renderRewardSlot(slot, reward, pack)
	if not (slot and slot:IsA("GuiObject")) then
		return
	end
	slot.Visible = reward ~= nil
	if not reward then
		local icon = findDescendant(slot, "Icon", "ViewportFrame")
		if icon then
			ViewportPreview.Render(icon, nil, PACK_REWARD_PREVIEW_OPTIONS)
		end
		setTextStack(findDescendant(slot, "Name", "TextLabel"), "")
		setTextStack(findDescendant(slot, "Chance", "TextLabel"), "")
		return
	end
	local icon = findDescendant(slot, "Icon", "ViewportFrame")
	local nameLabel = findDescendant(slot, "Name", "TextLabel")
	local chance = findDescendant(slot, "Chance", "TextLabel")
	local seedId = reward.SeedId
	local rarity = Seeds.RarityFor(seedId)
	local displayName = Seeds.DisplayNameFor(seedId)
	if icon then
		ViewportPreview.Render(icon, Seeds.GetTemplate(seedId), PACK_REWARD_PREVIEW_OPTIONS)
	end
	if chance then
		setTextStack(chance, ShopBalance.ChanceText(pack, reward))
	end
	setTextStack(nameLabel, displayName)
	HoverOver.Bind(slot, function()
		return {
			name = displayName,
			rarity = rarity,
		}
	end)
end

local function rewardSlots(pack, items)
	local slots = {}
	if not items then
		return slots
	end
	for _, item in ipairs(items:GetChildren()) do
		if item:IsA("GuiObject") then
			local isTemplate = item.Name == "Template"
				or (pack and pack.PackId == "DurianPack" and (item.Name == "MythicalTemplate" or item.Name == "SecretTemplate"))
			if isTemplate then
				slots[#slots + 1] = item
			end
		end
	end
	table.sort(slots, function(left, right)
		if left.LayoutOrder ~= right.LayoutOrder then
			return left.LayoutOrder < right.LayoutOrder
		end
		if left.Position.X.Scale ~= right.Position.X.Scale then
			return left.Position.X.Scale < right.Position.X.Scale
		end
		return left.Position.X.Offset < right.Position.X.Offset
	end)
	return slots
end

local function buttonNameCandidates(quantity, featured)
	if quantity == 1 then
		return featured and { "Buy1", "BuyOne", "BuyButton" } or { "BuyOne", "BuyButton", "Buy1" }
	elseif quantity == 3 then
		return featured and { "Buy3", "BuyThree" } or { "BuyThree", "Buy3" }
	elseif quantity == 10 then
		return { "Buy10" }
	elseif quantity == 50 then
		return { "Buy50" }
	end
	return { "Buy" .. tostring(quantity) }
end

local function findProductButton(frame, pack, product)
	for _, buttonName in ipairs(buttonNameCandidates(tonumber(product and product.Quantity) or 0, pack and pack.Featured == true)) do
		local direct = frame and frame:FindFirstChild(buttonName)
		if direct and direct:IsA("GuiButton") then
			return direct
		end
		local descendant = findDescendant(frame, buttonName, "GuiButton")
		if descendant then
			return descendant
		end
	end
	return nil
end

local function renderPackCard(pack)
	local frame = packFrameForPack(pack)
	if not frame then
		local sectionName = pack.Featured == true and FEATURED_SECTION_NAME or SEED_PACKS_NAME
		warn("[SeedPackShopController] Missing " .. sectionName .. "." .. tostring(pack.PackId))
		return nil
	end

	local title = frame:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		setTextStack(title, pack.DisplayName)
	end
	local nameLabel = frame:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		setTextStack(nameLabel, pack.DisplayName)
	end

	renderPackIcon(frame, pack.PackId)

	local items = frame:FindFirstChild("Items")
	local slots = rewardSlots(pack, items)
	for index, slot in ipairs(slots) do
		renderRewardSlot(slot, (pack.Rewards or {})[index], pack)
	end

	local productButtons = {}
	for _, product in ipairs(ShopBalance.AllSeedPackProducts(pack)) do
		local button = findProductButton(frame, pack, product)
		if button then
			UiEffects.BindButton(button)
			productButtons[#productButtons + 1] = {
				button = button,
				priceLabel = findDescendant(button, "Price", "TextLabel"),
				product = product,
			}
		else
			warn(string.format(
				"[SeedPackShopController] Missing %s.%s quantity %d buy button",
				pack.Featured == true and FEATURED_SECTION_NAME or SEED_PACKS_NAME,
				tostring(pack.PackId),
				tonumber(product.Quantity) or 0
			))
		end
	end

	return {
		pack = pack,
		frame = frame,
		productButtons = productButtons,
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
	applySeedPacksVisibility(rows)
	local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true and isSeedPacksAllowed()
	for _, row in ipairs(rows) do
		for _, productButton in ipairs(row.productButtons or {}) do
			local productId = tonumber(productButton.product and productButton.product.DevProductId) or 0
			local quantity = tonumber(productButton.product and productButton.product.Quantity) or 0
			if quantity == 3 and row.pack and row.pack.PackId ~= "DurianPack" then
				setTextStack(productButton.priceLabel, "x3")
			else
				setTextStack(productButton.priceLabel, robuxText(productId, function()
					renderRows(rows)
				end))
			end
			UiEffects.SetButtonEnabled(productButton.button, ready and productId > 0)
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
		if show then
			setTextStack(openHint, "Press X to open")
		end
		openHint.Visible = show
	end

	local consoleIcon = panel and panel:FindFirstChild("ConsoleIcon")
	if consoleIcon and consoleIcon:IsA("ImageLabel") then
		consoleIcon.Image = consoleOpenIconImage()
		consoleIcon.Visible = show
	end
end

local function setAdvanceHintVisible(panel, visible)
	local show = visible == true
	local hasController = hasConnectedController()
	local openHint = panel and panel:FindFirstChild("OpenHint")
	if openHint and openHint:IsA("GuiObject") then
		setTextStack(openHint, hasController and "Press X to continue" or "Click anywhere to continue")
		openHint.Visible = show
	end

	local consoleIcon = panel and panel:FindFirstChild("ConsoleIcon")
	if consoleIcon and consoleIcon:IsA("ImageLabel") then
		consoleIcon.Image = consoleOpenIconImage()
		consoleIcon.Visible = show and hasController
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
		packButton.ImageTransparency = 0
		renderPackIcon(packButton, payload.packId)
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
	awaitingAdvance = false
	advanceReadyAt = 0
	ftueToken += 1
	activeFtueDrag = nil
	resetDragState()
	template.Visible = false
	if sliceTemplate and sliceTemplate:IsA("GuiObject") then
		sliceTemplate.Visible = false
	end
	if continueButton and continueButton:IsA("GuiButton") then
		continueButton.Visible = false
		continueButton.Active = false
	end
	setAdvanceHintVisible(panel, false)
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
	if awaitingAdvance then
		setAdvanceHintVisible(panel, true)
	else
		setConsoleHintVisible(panel, activeReveal ~= nil and not allOpened())
	end
end

local function showAdvancePrompt()
	local panel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	local continueButton = panel and panel:FindFirstChild("ContinueButton")
	if continueButton and continueButton:IsA("GuiButton") then
		continueButton.Visible = false
		continueButton.Active = false
	end
	awaitingAdvance = true
	advanceReadyAt = os.clock() + ADVANCE_INPUT_GRACE_SECONDS
	resetDragState()
	setAdvanceHintVisible(panel, true)
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
			showAdvancePrompt()
		end
	end

	if pack and pack:IsA("ImageButton") then
		-- Fade the 3D pack icon with the button: ViewportFrame content does
		-- not follow the parent ImageButton's ImageTransparency.
		local icon = pack:FindFirstChild(PACK_ICON_NAME)
		if icon and icon:IsA("ViewportFrame") then
			TweenService:Create(icon, PACK_FADE_TWEEN, {
				ImageTransparency = 1,
			}):Play()
		end
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
	if not activeReveal or awaitingAdvance or allOpened() then
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

local showNextReveal

local function advanceReveal()
	if not awaitingAdvance or os.clock() < advanceReadyAt then
		return
	end
	awaitingAdvance = false
	advanceReadyAt = 0
	local panel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	setAdvanceHintVisible(panel, false)
	showNextReveal()
end

local function scrollToShopSection(sectionName)
	local section, holder = shopSection(sectionName)
	if not (holder and holder:IsA("ScrollingFrame")) then
		return
	end
	task.defer(function()
		if not holder.Parent then
			return
		end
		local targetY = 0
		if sectionName ~= FEATURED_SECTION_NAME then
			if not (section and section.Parent) then
				return
			end
			local relativeY = section.AbsolutePosition.Y - holder.AbsolutePosition.Y
			targetY = holder.CanvasPosition.Y + relativeY
		end
		local maxY = math.max(holder.AbsoluteCanvasSize.Y - holder.AbsoluteWindowSize.Y, 0)
		if shopScrollTween then
			shopScrollTween:Cancel()
			shopScrollTween = nil
		end
		shopScrollTween = TweenService:Create(holder, SHOP_SCROLL_TWEEN, {
			CanvasPosition = Vector2.new(holder.CanvasPosition.X, math.clamp(targetY, 0, maxY)),
		})
		local tween = shopScrollTween
		RuntimeGuard.Connect(tween.Completed, "SeedPackShopController.ShopScrollCompleted", function()
			if shopScrollTween == tween then
				shopScrollTween = nil
			end
		end)
		tween:Play()
	end)
end

function showNextReveal()
	local nextPayload = table.remove(revealQueue, 1)
	if not nextPayload then
		activeReveal = nil
		awaitingAdvance = false
		MenuGui.OpenPanel(ROBUX_PANEL_NAME)
		scrollToShopSection(lastRevealSourceSection or SEED_PACKS_NAME)
		return
	end
	activeReveal = nextPayload
	lastRevealSourceSection = nextPayload.sourceSection or SEED_PACKS_NAME
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
	local results = payload.results
	for batchStart = 1, #results, MAX_REVEAL_BATCH_SIZE do
		local batch = {}
		local batchEnd = math.min(batchStart + MAX_REVEAL_BATCH_SIZE - 1, #results)
		for index = batchStart, batchEnd do
			batch[#batch + 1] = results[index]
		end
		revealQueue[#revealQueue + 1] = {
			action = payload.action,
			packId = payload.packId,
			sourceSection = payload.sourceSection,
			results = batch,
		}
	end
	if not activeReveal then
		showNextReveal()
	end
end

local function bindHeaderScrollButtons()
	local panel = MenuGui.GetFrame(ROBUX_PANEL_NAME, "SeedPackShopController")
	local header = panel and findDescendant(panel, "Header", "GuiObject")
	local bindings = {
		Featured = FEATURED_SECTION_NAME,
		Packs = SEED_PACKS_NAME,
		Cash = CASH_PACKS_NAME,
	}
	for buttonName, sectionName in pairs(bindings) do
		local button = header and findDescendant(header, buttonName, "GuiButton")
		if button then
			UiEffects.BindButton(button)
			RuntimeGuard.Connect(button.Activated, "SeedPackShopController.Header." .. buttonName, function()
				scrollToShopSection(sectionName)
			end)
		else
			warn("[SeedPackShopController] Missing RobuxShop Header." .. buttonName)
		end
	end
end

local function refreshRainbowGradients()
	rainbowGradients = {}
	local frame = nil
	local _, _, featured = shopFrames()
	local candidate = featured and featured:FindFirstChild("DurianPack")
	if candidate and candidate:IsA("GuiObject") then
		frame = candidate
	end
	if not frame then
		return
	end
	for _, descendant in ipairs(frame:GetDescendants()) do
		if descendant.Name == "RainbowStroke" and descendant:IsA("UIGradient") then
			rainbowGradients[#rainbowGradients + 1] = descendant
		end
	end
end

local function stopRainbowRotation()
	if rainbowConnection then
		rainbowConnection:Disconnect()
		rainbowConnection = nil
	end
end

local function startRainbowRotation()
	if rainbowConnection then
		return
	end
	refreshRainbowGradients()
	if #rainbowGradients == 0 then
		return
	end
	rainbowConnection = RuntimeGuard.Connect(RunService.RenderStepped, "SeedPackShopController.DurianRainbow", function()
		local panel = MenuGui.GetFrame(ROBUX_PANEL_NAME, "SeedPackShopController")
		if not (panel and panel.Parent and panel.Visible) then
			stopRainbowRotation()
			return
		end
		local rotation = (os.clock() * RAINBOW_ROTATION_DEGREES_PER_SECOND) % 360
		for index = #rainbowGradients, 1, -1 do
			local gradient = rainbowGradients[index]
			if gradient and gradient.Parent then
				gradient.Rotation = rotation
			else
				table.remove(rainbowGradients, index)
			end
		end
		if #rainbowGradients == 0 then
			stopRainbowRotation()
		end
	end)
end

local function refreshRainbowRotation()
	local panel = MenuGui.GetFrame(ROBUX_PANEL_NAME, "SeedPackShopController")
	if panel and panel.Visible then
		startRainbowRotation()
	else
		stopRainbowRotation()
	end
end

function SeedPackShopController.start()
	local robuxPanel = MenuGui.GetFrame(ROBUX_PANEL_NAME, "SeedPackShopController")
	local rollPanel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	if not (robuxPanel and rollPanel) then
		return
	end

	applySeedPacksVisibility()
	bindHeaderScrollButtons()

	local rows = {}
	for _, pack in ipairs(ShopBalance.AllSeedPacks()) do
		local row = renderPackCard(pack)
		if row then
			rows[#rows + 1] = row
			for _, productButton in ipairs(row.productButtons or {}) do
				local product = productButton.product
				RuntimeGuard.Connect(productButton.button.Activated, string.format(
					"SeedPackShopController.Buy.%s.%s",
					tostring(pack.PackId),
					tostring(product and product.Quantity)
				), function()
					promptProduct(product and product.DevProductId)
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
		continueButton.Visible = false
		continueButton.Active = false
	end

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.SeedPackPurchaseResult).OnClientEvent, "SeedPackShopController.Result", enqueueReveal)
	RuntimeGuard.Connect(UserInputService.InputBegan, "SeedPackShopController.InputBegan", function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.X or input.KeyCode == CONSOLE_OPEN_KEYCODE then
			if awaitingAdvance then
				advanceReveal()
			else
				openAllWithKeybind()
			end
		elseif isPressInput(input) then
			if awaitingAdvance then
				advanceReveal()
			else
				beginDrag(input)
			end
		end
	end)
	RuntimeGuard.Connect(UserInputService.InputChanged, "SeedPackShopController.InputChanged", continueDrag)
	RuntimeGuard.Connect(UserInputService.InputEnded, "SeedPackShopController.InputEnded", endDrag)
	RuntimeGuard.Connect(UserInputService.GamepadConnected, "SeedPackShopController.GamepadConnected", function()
		stopFtueCue(false)
		refreshConsoleHint()
	end)
	RuntimeGuard.Connect(UserInputService.GamepadDisconnected, "SeedPackShopController.GamepadDisconnected", refreshConsoleHint)
	RuntimeGuard.Connect(robuxPanel:GetPropertyChangedSignal("Visible"), "SeedPackShopController.RobuxVisible", refreshRainbowRotation)
	RuntimeGuard.Connect(robuxPanel.Destroying, "SeedPackShopController.RobuxDestroying", stopRainbowRotation)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, function()
		renderRows(rows)
	end)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.SeedPacksAllowed), "SeedPackShopController.SeedPacksAllowed", function()
		renderRows(rows)
	end)
	renderRows(rows)
	refreshRainbowRotation()
end

return SeedPackShopController
