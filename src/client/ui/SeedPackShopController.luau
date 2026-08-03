local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local PetSkinCatalog = require(Shared:WaitForChild("PetSkinCatalog"))
local Rarities = require(Shared:WaitForChild("Rarities"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local ConfettiEffect = require(script.Parent:WaitForChild("ConfettiEffect"))
local FeedDisplayModel = require(script.Parent:WaitForChild("FeedDisplayModel"))
local FeedXPText = require(script.Parent:WaitForChild("FeedXPText"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local HoverOver = require(script.Parent:WaitForChild("HoverOver"))
local PackIconDisplay = require(script.Parent:WaitForChild("PackIconDisplay"))
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
local ENDLESS_PACK_NAME = "EndlessPack"
local PET_SKIN_CARD_NAME = "CosmeticPack"
local PACK_HOLDER_TEMPLATE_NAME = "PackHolder"
local CONTINUE_BUTTON_NAME = "Continue"
local RUNTIME_PACK_HOLDER_NAME = "__SeedPackRollHolder"
local RUNTIME_SLICE_NAME = "__SeedPackSlice"
local CONSOLE_OPEN_KEYCODE = Enum.KeyCode.ButtonX
local FALLBACK_CONSOLE_OPEN_ICON = "rbxasset://textures/ui/Controls/xboxX.png"
local CATCHER_GUI_NAME = "PackRollInputCatcher"
local CATCHER_BUTTON_NAME = "Catcher"
local MAX_REVEAL_BATCH_SIZE = 3
local ADVANCE_INPUT_GRACE_SECONDS = 0.12
local DURIAN_REVEAL_SOURCE_SECTION = "DurianPack"
local DURIAN_PANEL_NAME = "DurianPackHolder"

local PACK_REWARD_PREVIEW_OPTIONS = {
	targetMaxDimension = 6,
	zoom = 1.8,
	colorSaturation = 2.5,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}
local REVEAL_PREVIEW_OPTIONS = {
	targetMaxDimension = 4,
	zoom = 1.65,
	colorSaturation = 2.5,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}
local PET_SKIN_PREVIEW_OPTIONS = {
	targetMaxDimension = ViewportPreview.PET_TARGET_MAX_DIMENSION,
	zoom = ViewportPreview.PET_VIEWPORT_ZOOM,
	alignPivot = true,
	presentationScale = 2,
}
local PACK_CARD_ICON_OPTIONS = {
	swayDegrees = 18,
	swayPeriodSeconds = 4.5,
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
local catcherButton = nil
local productPriceById = {}
local awaitingAdvance = false
local advanceReadyAt = 0
local lastRevealSourceSection = SEED_PACKS_NAME
local shopScrollTween = nil

local PRODUCT_PRICE_LOADING_TEXT = "..."
local PRODUCT_PRICE_UNAVAILABLE_TEXT = "Unavailable"

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
		return PRODUCT_PRICE_UNAVAILABLE_TEXT, false
	end
	local cached = productPriceById[productId]
	if cached then
		return cached.text, cached.state == "ready"
	end

	productPriceById[productId] = {
		state = "loading",
		text = PRODUCT_PRICE_LOADING_TEXT,
	}
	RuntimeGuard.Spawn("SeedPackShopController.ProductInfo", function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, productId, Enum.InfoType.Product)
		local price = ok and type(info) == "table" and tonumber(info.PriceInRobux) or nil
		if price and price > 0 then
			productPriceById[productId] = {
				state = "ready",
				text = NumberFormatter.Robux(price),
			}
		else
			productPriceById[productId] = {
				state = "failed",
				text = PRODUCT_PRICE_UNAVAILABLE_TEXT,
			}
		end
		if onLoaded then
			onLoaded()
		end
	end)
	return PRODUCT_PRICE_LOADING_TEXT, false
end

-- Toggles the reveal press catcher (created in start). Hiding it, rather than
-- disabling its ScreenGui, keeps WorksOfflineController's blanket
-- ScreenGui.Enabled save/restore from ever handing back a live screen-wide sink.
local function setCatcherActive(active)
	if catcherButton and catcherButton.Parent then
		catcherButton.Visible = active == true
	end
end

local function resetDragState()
	dragging = false
	activeInput = nil
	activeInputType = nil
	dragStartPosition = nil
	lastPosition = nil
end

local function setRarityLabel(label, rarity)
	if not label then
		return
	end
	local value = type(rarity) == "string" and rarity ~= "" and rarity or Rarities.Common
	setTextStack(label, value)
	label.TextColor3 = Rarities.TextColorFor(value) or Rarities.TextColorFor(Rarities.Common)
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
	local endlessPack = holder and holder:FindFirstChild(ENDLESS_PACK_NAME)
	return panel,
		holder,
		featured and featured:IsA("GuiObject") and featured or nil,
		seedPacks and seedPacks:IsA("GuiObject") and seedPacks or nil,
		cashPacks and cashPacks:IsA("GuiObject") and cashPacks or nil,
		endlessPack and endlessPack:IsA("GuiObject") and endlessPack or nil
end

local function shopSection(sectionName)
	local _, holder, featured, seedPacks, cashPacks, endlessPack = shopFrames()
	if sectionName == FEATURED_SECTION_NAME then
		return featured, holder
	elseif sectionName == SEED_PACKS_NAME then
		return seedPacks, holder
	elseif sectionName == CASH_PACKS_NAME then
		return cashPacks, holder
	elseif sectionName == ENDLESS_PACK_NAME then
		return endlessPack, holder
	end
	return nil, holder
end

local function applySeedPacksVisibility()
	local _, _, _, seedPacks = shopFrames()
	if seedPacks then
		seedPacks.Visible = isSeedPacksAllowed()
	end
end

local function packFrameForPack(pack)
	local section = shopSection(SEED_PACKS_NAME)
	local frame = section and section:FindFirstChild(pack and pack.PackId or "")
	return frame and frame:IsA("GuiObject") and frame or nil
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
		ViewportPreview.Render(icon, FeedDisplayModel.SeedPreview(seedId, PACK_REWARD_PREVIEW_OPTIONS))
	end
	if chance then
		setTextStack(chance, ShopBalance.ChanceText(pack, reward))
	end
	setTextStack(nameLabel, displayName)
	HoverOver.Bind(slot, function()
		return {
			name = displayName,
			rarity = rarity,
			xp = FeedXPText.ForSeed(seedId),
		}
	end)
end

local function rewardSlots(items)
	local slots = {}
	if not items then
		return slots
	end
	for _, item in ipairs(items:GetChildren()) do
		if item:IsA("GuiObject") and item.Name == "Template" then
			slots[#slots + 1] = item
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

local function petSkinRewardSlots(items)
	local slots = {}
	local validNames = {
		EpicTemplate = true,
		LegendaryTemplate = true,
		MythicalTemplate = true,
		SecretTemplate = true,
	}
	for _, item in ipairs(items and items:GetChildren() or {}) do
		if item:IsA("GuiObject") and validNames[item.Name] then
			slots[#slots + 1] = item
		end
	end
	table.sort(slots, function(left, right)
		if left.LayoutOrder ~= right.LayoutOrder then
			return left.LayoutOrder < right.LayoutOrder
		end
		return left.Name < right.Name
	end)
	return slots
end

local function buttonNameCandidates(quantity)
	if quantity == 1 then
		return { "BuyOne", "BuyButton", "Buy1" }
	elseif quantity == 3 then
		return { "BuyThree", "Buy3" }
	end
	return { "Buy" .. tostring(quantity) }
end

local function findProductButton(frame, product)
	for _, buttonName in ipairs(buttonNameCandidates(tonumber(product and product.Quantity) or 0)) do
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
		warn("[SeedPackShopController] Missing " .. SEED_PACKS_NAME .. "." .. tostring(pack.PackId))
		return nil
	end

	local packRarityColor = Rarities.TextColorFor(pack.Rarity)
	local title = frame:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		setTextStack(title, pack.DisplayName)
		if packRarityColor then
			title.TextColor3 = packRarityColor
		end
	end
	local nameLabel = frame:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		setTextStack(nameLabel, pack.DisplayName)
		if packRarityColor then
			nameLabel.TextColor3 = packRarityColor
		end
	end

	PackIconDisplay.Render(frame, pack.PackId, PACK_CARD_ICON_OPTIONS)

	local items = frame:FindFirstChild("Items")
	local slots = rewardSlots(items)
	for index, slot in ipairs(slots) do
		renderRewardSlot(slot, (pack.Rewards or {})[index], pack)
	end

	local productButtons = {}
	for _, product in ipairs(ShopBalance.AllSeedPackProducts(pack)) do
		local button = findProductButton(frame, product)
		if button then
			UiEffects.BindButton(button)
			productButtons[#productButtons + 1] = {
				button = button,
				priceLabel = findDescendant(button, "Price", "TextLabel"),
				amountLabel = findDescendant(button, "Amount", "TextLabel"),
				product = product,
			}
		else
			warn(string.format(
				"[SeedPackShopController] Missing %s.%s quantity %d buy button",
				SEED_PACKS_NAME,
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

local function petSkinPackFrame()
	local featured = shopSection(FEATURED_SECTION_NAME)
	local frame = featured and featured:FindFirstChild(PET_SKIN_CARD_NAME)
	return frame and frame:IsA("GuiObject") and frame or nil
end

local function renderPetSkinReward(slot, definition, visible)
	if not (slot and definition) then
		return
	end
	local icon = findDescendant(slot, "Icon", "ViewportFrame")
	local chance = findDescendant(slot, "Chance", "TextLabel")
	local nameLabel = findDescendant(slot, "Name", "TextLabel")
	local template = visible and PetSkinCatalog.TemplateFor(definition.Id) or nil
	if icon then
		local options = table.clone(PET_SKIN_PREVIEW_OPTIONS)
		options.idleAnimationId = definition.WalkAnimationId
		options.presentationScale *= definition.ViewportScaleMultiplier
		options.yawDegrees = definition.ViewportYawDegrees
		ViewportPreview.Render(icon, template, options)
	end
	if chance then
		setTextStack(chance, PetSkinCatalog.ChanceText(definition.Id))
	end
	if nameLabel then
		setTextStack(nameLabel, PetSkinCatalog.NameFor(definition.Id))
	end
	HoverOver.Bind(slot, function()
		return {
			name = PetSkinCatalog.NameFor(definition.Id),
			rarity = definition.Rarity,
		}
	end)
end

local function renderPetSkinPackPreviews(frame, pack, visible)
	if visible then
		PackIconDisplay.Render(frame, pack.PackId, PACK_CARD_ICON_OPTIONS)
	else
		local packIcon = findDescendant(frame, "PackIcon", "ViewportFrame")
		if packIcon then
			ViewportPreview.Render(packIcon, nil)
		end
	end
	local slots = petSkinRewardSlots(frame:FindFirstChild("Items"))
	for index, definition in ipairs(PetSkinCatalog.All()) do
		if slots[index] then
			renderPetSkinReward(slots[index], definition, visible)
		end
	end
end

local function renderPetSkinPackCard(visible)
	local frame = petSkinPackFrame()
	local pack = ShopBalance.GetPetSkinPack()
	if not (frame and pack) then
		warn("[SeedPackShopController] Missing Featured.CosmeticPack Pet Skin Pack card")
		return nil
	end
	local allowed = isSeedPacksAllowed()
	frame.Visible = allowed
	visible = visible and allowed
	renderPetSkinPackPreviews(frame, pack, visible)

	local productButtons = {}
	for _, product in ipairs(ShopBalance.AllPetSkinPackProducts()) do
		local button = findProductButton(frame, product)
		if button then
			UiEffects.BindButton(button)
			productButtons[#productButtons + 1] = {
				button = button,
				priceLabel = findDescendant(button, "Price", "TextLabel"),
				amountLabel = findDescendant(button, "Amount", "TextLabel"),
				product = product,
			}
		else
			warn("[SeedPackShopController] Missing Pet Skin Pack Buy" .. tostring(product.Quantity) .. " button")
		end
	end
	return { pack = pack, frame = frame, productButtons = productButtons, isPetSkinPack = true }
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
	local allowed = isSeedPacksAllowed()
	local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true and allowed
	for _, row in ipairs(rows) do
		if row.isPetSkinPack then
			row.frame.Visible = allowed
			local panel = row.frame:FindFirstAncestor(ROBUX_PANEL_NAME)
			renderPetSkinPackPreviews(row.frame, row.pack, allowed and panel ~= nil and panel.Visible)
		end
		for _, productButton in ipairs(row.productButtons or {}) do
			local productId = tonumber(productButton.product and productButton.product.DevProductId) or 0
			local quantity = tonumber(productButton.product and productButton.product.Quantity) or 0
			local priceText, priceReady = robuxText(productId, function()
				renderRows(rows)
			end)
			setTextStack(productButton.priceLabel, priceText)
			if row.isPetSkinPack then
				if quantity == 12 then
					setTextStack(productButton.amountLabel, "x12")
				end
			elseif quantity == 3 then
				setTextStack(productButton.amountLabel, "x3")
			end
			UiEffects.SetButtonEnabled(productButton.button, ready and productId > 0 and priceReady)
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
		PackIconDisplay.Render(packButton, payload.packId)
	end

	setRewardVisible(holder, false)
	hideFtueDrag(holder)
	local resultViewport = holder:FindFirstChild("Result")
	if resultViewport and resultViewport:IsA("ViewportFrame") then
		if result.kind == "PetSkin" then
			local definition = PetSkinCatalog.Get(result.petSkinId)
			local options = table.clone(REVEAL_PREVIEW_OPTIONS)
			options.alignPivot = true
			options.presentationScale = PET_SKIN_PREVIEW_OPTIONS.presentationScale
				* (definition and definition.ViewportScaleMultiplier or 1)
			options.idleAnimationId = definition and definition.WalkAnimationId or nil
			options.yawDegrees = definition and definition.ViewportYawDegrees or nil
			ViewportPreview.Render(resultViewport, PetSkinCatalog.TemplateFor(result.petSkinId), options)
		else
			ViewportPreview.Render(resultViewport, FeedDisplayModel.SeedPreview(result.seedId, REVEAL_PREVIEW_OPTIONS))
		end
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
	local continueButton = panel:FindFirstChild(CONTINUE_BUTTON_NAME)
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
	local continueButton = panel and panel:FindFirstChild(CONTINUE_BUTTON_NAME)
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
		local icon = pack:FindFirstChild("PackIcon")
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
		setCatcherActive(false)
		-- Durian Pack rolls return to the standalone Durian panel; shop
		-- purchases return to the RobuxShop at their source section.
		if lastRevealSourceSection == DURIAN_REVEAL_SOURCE_SECTION then
			MenuGui.OpenPanel(DURIAN_PANEL_NAME)
			return
		end
		MenuGui.OpenPanel(ROBUX_PANEL_NAME)
		scrollToShopSection(lastRevealSourceSection or SEED_PACKS_NAME)
		return
	end
	activeReveal = nextPayload
	lastRevealSourceSection = nextPayload.sourceSection or SEED_PACKS_NAME
	if buildReveal(nextPayload) then
		MenuGui.OpenPanel(ROLL_PANEL_NAME)
		setCatcherActive(true)
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

-- Other controllers (the Durian Pack) reuse the pack-opening reveal flow by
-- handing their server payloads here; payload.sourceSection decides which
-- panel reopens once every reveal batch is finished.
function SeedPackShopController.EnqueueReveal(payload)
	enqueueReveal(payload)
end

-- Every reveal press is routed through a screen-sized Active button so the
-- camera never sees it. The pack buttons are deliberately inactive (see
-- configureHolder) so a swipe reaches this controller instead of being eaten by
-- the button, which also means the default camera registers the finger as an
-- unsunk pan touch and rotates the world behind the blurred menu for the whole
-- drag. PlayerModule caches that sunk flag when the touch *begins*
-- (CameraInput's touches[input] = sunk), so nothing bound mid-drag can take it
-- back: the press has to land on an Active GuiObject in the first place. The
-- catcher lives one DisplayOrder below the Menu, so menu buttons still win the
-- hit test and only presses nothing else claimed -- pack swipes, tap-anywhere
-- to continue -- are sunk here. It is only visible while a reveal is on screen,
-- so it also blocks walking for those few seconds, which is what a modal
-- reveal wants anyway.
local function onRevealPress(input)
	if not (isPressInput(input) and activeReveal) then
		return
	end
	if awaitingAdvance then
		advanceReveal()
	else
		beginDrag(input)
	end
end

local function ensureCatcher()
	if catcherButton and catcherButton.Parent then
		return
	end

	local menu = currentMenu()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not (menu and playerGui) then
		return
	end

	local gui = playerGui:FindFirstChild(CATCHER_GUI_NAME)
	if not (gui and gui:IsA("ScreenGui")) then
		gui = Instance.new("ScreenGui")
		gui.Name = CATCHER_GUI_NAME
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = menu.DisplayOrder - 1
		gui.Parent = playerGui
	end

	local button = gui:FindFirstChild(CATCHER_BUTTON_NAME)
	if not (button and button:IsA("TextButton")) then
		button = Instance.new("TextButton")
		button.Name = CATCHER_BUTTON_NAME
		button.Size = UDim2.fromScale(1, 1)
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Selectable = false
		button.Text = ""
		button.Visible = false
		button.Parent = gui
		RuntimeGuard.Connect(button.InputBegan, "SeedPackShopController.CatcherInputBegan", onRevealPress)
	end

	catcherButton = button
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

function SeedPackShopController.start()
	local robuxPanel = MenuGui.GetFrame(ROBUX_PANEL_NAME, "SeedPackShopController")
	local rollPanel = MenuGui.GetFrame(ROLL_PANEL_NAME, "SeedPackShopController")
	if not (robuxPanel and rollPanel) then
		return
	end

	applySeedPacksVisibility()
	bindHeaderScrollButtons()
	ensureCatcher()

	local rows = {}
	local petSkinRow = renderPetSkinPackCard(robuxPanel.Visible)
	if petSkinRow then
		rows[#rows + 1] = petSkinRow
		for _, productButton in ipairs(petSkinRow.productButtons) do
			local product = productButton.product
			RuntimeGuard.Connect(productButton.button.Activated, "SeedPackShopController.Buy.PetSkinPack." .. tostring(product.Quantity), function()
				promptProduct(product.DevProductId)
			end)
		end
	end
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
	RuntimeGuard.Connect(robuxPanel:GetPropertyChangedSignal("Visible"), "SeedPackShopController.PetSkinViewportVisibility", function()
		renderPetSkinPackCard(robuxPanel.Visible)
	end)

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
			setCatcherActive(false)
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

	local continueButton = rollPanel:FindFirstChild(CONTINUE_BUTTON_NAME)
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
			-- Fallback for the rare run where the catcher could not be created:
			-- while it is up these presses arrive gameProcessed and stop above.
			onRevealPress(input)
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
