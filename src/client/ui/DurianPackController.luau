-- Standalone Durian Pack UI: the HUD.DurianPack entry opens the Studio-owned
-- Menu.DurianPackHolder panel. Players buy Durian Tickets (Robux dev
-- products) from the BuyRolls list and spend them on Roll1/Roll3/Roll10
-- ticket rolls; the server owns tickets, pity, and rewards, and roll results
-- reuse the SeedPackShopController pack-opening reveal. The Timer countdown
-- is visual-only and loops like the starter pack cycle.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local FeedDisplayModel = require(script.Parent:WaitForChild("FeedDisplayModel"))
local FeedXPText = require(script.Parent:WaitForChild("FeedXPText"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local HoverOver = require(script.Parent:WaitForChild("HoverOver"))
local Notifications = require(script.Parent:WaitForChild("Notifications"))
local PackIconDisplay = require(script.Parent:WaitForChild("PackIconDisplay"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SeedPackShopController = require(script.Parent:WaitForChild("SeedPackShopController"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local DurianPackController = {}

local PANEL_NAME = "DurianPackHolder"
local SHOP_MENU_GROUP = "Shop"
local HUD_NAME = "HUD"
local HUD_ENTRY_NAME = "DurianPack"
-- On touch devices the authored HUD entry sits slightly too high; nudge it down.
local HUD_ENTRY_TOUCH_Y_OFFSET_PIXELS = 6
local HUD_WAIT_SECONDS = 10
local RUNTIME_TICKET_OFFER_NAME = "__DurianTicketOffer"
local RAINBOW_ROTATION_DEGREES_PER_SECOND = 90
local GROUND_BOB_INTERVAL_SECONDS = 3
local GROUND_BOB_OFFSET_SCALE = 0.035
-- reverses = true bobs the durian up and settles it back on the ground.
local GROUND_BOB_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true)

local REWARD_PREVIEW_OPTIONS = {
	targetMaxDimension = 6,
	zoom = 1.8,
	colorSaturation = 2.5,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}

local player = Players.LocalPlayer
local productPriceById = {}
local nextRequestId = 0
local pendingRequestId = nil

local rollRequestRemote = Remotes.get(Remotes.Names.DurianPackRollRequest)
local rollResultRemote = Remotes.get(Remotes.Names.DurianPackRollResult)

local function isDurianPackAllowed()
	return player:GetAttribute(State.Player.SeedPacksAllowed) == true
end

local function isTutorialActive()
	local state = Onboarding.SanitizeState(
		PlayerStateStore.Get(PlayerStateStore.Fields.Onboarding),
		Onboarding.CompleteState()
	)
	return Onboarding.IsActive(state.Stage)
end

local function isOfflineProgressPending()
	return player:GetAttribute(State.Player.OfflineProgressPending) == true
end

-- The HUD entry (and with it the whole feature) stays hidden while paid
-- random items are restricted, during the onboarding tutorial, and during the
-- offline-growth catch-up phase right after rejoining.
local function isHudEntryVisible()
	return isDurianPackAllowed() and not isTutorialActive() and not isOfflineProgressPending()
end

local function isProfileReady()
	return PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
end

local function ticketBalance()
	return math.max(math.floor(tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.DurianTickets)) or 0), 0)
end

local function pityCount()
	return math.max(math.floor(tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.DurianPackPity)) or 0), 0)
end

local function setTextStack(root, text)
	UiEffects.SetTextStack(root, tostring(text or ""))
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

local function robuxText(productId, onLoaded)
	productId = tonumber(productId) or 0
	if productId <= 0 then
		return NumberFormatter.Robux(0)
	end
	if productPriceById[productId] then
		return productPriceById[productId]
	end

	productPriceById[productId] = NumberFormatter.Robux(0)
	RuntimeGuard.Spawn("DurianPackController.ProductInfo", function()
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

local function formatCycleTimer(pack)
	local cycleSeconds = math.max(math.floor(tonumber(pack and pack.CycleSeconds) or 0), 0)
	if cycleSeconds <= 0 then
		return "Limited time!"
	end
	local remaining = cycleSeconds - (os.time() % cycleSeconds)
	if remaining <= 0 or remaining > cycleSeconds then
		remaining = cycleSeconds
	end
	local days = math.floor(remaining / 86400)
	local hours = math.floor((remaining % 86400) / 3600)
	return string.format("Limited time! %dd %02dhr", days, hours)
end

-- The four reward slots are Template x2 plus MythicalTemplate/SecretTemplate
-- (rainbow-stroked cards for the top rarities), ordered by authored layout.
local function rewardSlots(items)
	local slots = {}
	for _, item in ipairs(items and items:GetChildren() or {}) do
		if item:IsA("GuiObject")
			and (item.Name == "Template" or item.Name == "MythicalTemplate" or item.Name == "SecretTemplate") then
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

local function renderRewardSlot(slot, reward, pack)
	if not (slot and slot:IsA("GuiObject")) then
		return
	end
	slot.Visible = reward ~= nil
	if not reward then
		return
	end
	local seedId = reward.SeedId
	local displayName = Seeds.DisplayNameFor(seedId)
	local icon = findDescendant(slot, "Icon", "ViewportFrame")
	if icon then
		ViewportPreview.Render(icon, FeedDisplayModel.SeedPreview(seedId, REWARD_PREVIEW_OPTIONS))
	end
	setTextStack(findDescendant(slot, "Name", "TextLabel"), displayName)
	setTextStack(findDescendant(slot, "Chance", "TextLabel"), ShopBalance.ChanceText(pack, reward))
	HoverOver.Bind(slot, function()
		return {
			name = displayName,
			rarity = Seeds.RarityFor(seedId),
			xp = FeedXPText.ForSeed(seedId),
		}
	end)
end

local function promptTicketProduct(productId)
	productId = tonumber(productId) or 0
	if productId <= 0 or not (isDurianPackAllowed() and isProfileReady()) then
		return
	end
	RuntimeGuard.Run("DurianPackController.PromptProductPurchase", function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
end

local function buildTicketOffers(buyRolls, pack)
	local holder = buyRolls and findDescendant(buyRolls, "SFHolder", "ScrollingFrame")
	local template = holder and holder:FindFirstChild("Template")
	if not (holder and template and template:IsA("GuiObject")) then
		warn("[DurianPackController] DurianPackHolder.BuyRolls missing SFHolder.Template")
		return
	end

	template.Visible = false
	for _, child in ipairs(holder:GetChildren()) do
		if child.Name == RUNTIME_TICKET_OFFER_NAME then
			child:Destroy()
		end
	end

	for index, product in ipairs(pack.TicketProducts or {}) do
		local offer = template:Clone()
		offer.Name = RUNTIME_TICKET_OFFER_NAME
		offer.LayoutOrder = index
		offer.Visible = true

		setTextStack(offer:FindFirstChild("TicketAmount"), NumberFormatter.Integer(product.Tickets))
		local extraTickets = offer:FindFirstChild("ExtraTickets")
		if extraTickets and extraTickets:IsA("TextLabel") then
			extraTickets.Visible = product.ExtraTickets > 0
			setTextStack(extraTickets, product.ExtraTickets > 0 and ("+" .. tostring(product.ExtraTickets)) or "")
		end

		local buyButton = offer:FindFirstChild("Buy")
		if buyButton and buyButton:IsA("GuiButton") then
			local priceLabel = findDescendant(buyButton, "Price", "TextLabel")
			local function renderPrice()
				setTextStack(priceLabel, robuxText(product.DevProductId, function()
					setTextStack(priceLabel, robuxText(product.DevProductId))
				end))
			end
			renderPrice()
			UiEffects.BindButton(buyButton)
			RuntimeGuard.Connect(buyButton.Activated, "DurianPackController.BuyTickets." .. tostring(product.Tickets), function()
				promptTicketProduct(product.DevProductId)
			end)
		else
			warn("[DurianPackController] Durian ticket offer template missing Buy GuiButton")
		end

		offer.Parent = holder
	end
end

function DurianPackController.start()
	local panel = MenuGui.GetFrame(PANEL_NAME, "DurianPackController")
	if not panel then
		return
	end

	local pack = ShopBalance.GetDurianPack()
	local durianFrame = panel:FindFirstChild("DurianPack")
	if not (durianFrame and durianFrame:IsA("GuiObject")) then
		warn("[DurianPackController] DurianPackHolder missing DurianPack frame")
		return
	end

	setTextStack(durianFrame:FindFirstChild("Title"), pack.DisplayName)

	local slots = rewardSlots(durianFrame:FindFirstChild("Items"))
	for index, slot in ipairs(slots) do
		renderRewardSlot(slot, (pack.Rewards or {})[index], pack)
	end

	buildTicketOffers(panel:FindFirstChild("BuyRolls"), pack)

	local timerLabel = durianFrame:FindFirstChild("Timer")
	local pityLabel = durianFrame:FindFirstChild("RollPity")
	local ticketAmountLabel = findDescendant(durianFrame:FindFirstChild("TicketHolder"), "TicketAmount", "TextLabel")

	for _, rollCount in ipairs(pack.RollCounts or {}) do
		local button = durianFrame:FindFirstChild("Roll" .. tostring(rollCount))
		if button and button:IsA("GuiButton") then
			UiEffects.BindButton(button)
			RuntimeGuard.Connect(button.Activated, "DurianPackController.Roll." .. tostring(rollCount), function()
				if pendingRequestId ~= nil or not (isDurianPackAllowed() and isProfileReady()) then
					return
				end
				if ticketBalance() < rollCount then
					Notifications.show({
						text = "No durian tickets!",
						kind = NotificationConfig.Kinds.Error,
					})
					return
				end
				nextRequestId += 1
				pendingRequestId = nextRequestId
				rollRequestRemote:FireServer(pendingRequestId, rollCount)
			end)
		else
			warn("[DurianPackController] DurianPackHolder.DurianPack missing Roll" .. tostring(rollCount) .. " GuiButton")
		end
	end

	local function render()
		local tickets = ticketBalance()
		setTextStack(ticketAmountLabel, NumberFormatter.Integer(tickets))
		if pityLabel then
			setTextStack(pityLabel, string.format(
				"Guaranteed Durian after %d rolls (%d/%d)",
				pack.PityRollCount,
				math.min(pityCount(), pack.PityRollCount),
				pack.PityRollCount
			))
		end
		if timerLabel then
			setTextStack(timerLabel, formatCycleTimer(pack))
		end
		-- Roll buttons stay fully opaque even without tickets; pressing one
		-- with no tickets shows the error toast from the Activated handler.
	end

	-- Panel-open-only presentation: RainbowStroke gradients spin on the top
	-- rarity reward cards, the grounded durians bob every few seconds, and
	-- the visual countdown ticks. All connections stop when the panel closes.
	local rainbowGradients = {}
	for _, descendant in ipairs(panel:GetDescendants()) do
		if descendant.Name == "RainbowStroke" and descendant:IsA("UIGradient") then
			rainbowGradients[#rainbowGradients + 1] = descendant
		end
	end
	local groundImages = {}
	local backgroundImages = durianFrame:FindFirstChild("BackgroundImages")
	for _, child in ipairs(backgroundImages and backgroundImages:GetChildren() or {}) do
		if child.Name == "DurianGround" and child:IsA("GuiObject") then
			groundImages[#groundImages + 1] = {
				image = child,
				basePosition = child.Position,
			}
		end
	end

	local rainbowConnection = nil
	local pulseConnection = nil
	local nextBobAt = 0
	local lastTimerSecond = -1

	local function stopPanelEffects()
		if rainbowConnection then
			rainbowConnection:Disconnect()
			rainbowConnection = nil
		end
		if pulseConnection then
			pulseConnection:Disconnect()
			pulseConnection = nil
		end
	end

	local function bobGroundDurians()
		for _, entry in ipairs(groundImages) do
			if entry.image.Parent then
				entry.image.Position = entry.basePosition
				TweenService:Create(entry.image, GROUND_BOB_TWEEN, {
					Position = entry.basePosition - UDim2.fromScale(0, GROUND_BOB_OFFSET_SCALE),
				}):Play()
			end
		end
	end

	local function startPanelEffects()
		if not rainbowConnection and #rainbowGradients > 0 then
			rainbowConnection = RuntimeGuard.Connect(RunService.RenderStepped, "DurianPackController.Rainbow", function()
				local rotation = (os.clock() * RAINBOW_ROTATION_DEGREES_PER_SECOND) % 360
				for index = #rainbowGradients, 1, -1 do
					local gradient = rainbowGradients[index]
					if gradient and gradient.Parent then
						gradient.Rotation = rotation
					else
						table.remove(rainbowGradients, index)
					end
				end
				if #rainbowGradients == 0 and rainbowConnection then
					rainbowConnection:Disconnect()
					rainbowConnection = nil
				end
			end)
		end
		if not pulseConnection then
			nextBobAt = os.clock() + GROUND_BOB_INTERVAL_SECONDS
			lastTimerSecond = -1
			pulseConnection = RuntimeGuard.Connect(RunService.Heartbeat, "DurianPackController.Pulse", function()
				local now = os.clock()
				if now >= nextBobAt then
					nextBobAt = now + GROUND_BOB_INTERVAL_SECONDS
					bobGroundDurians()
				end
				local currentSecond = os.time()
				if currentSecond ~= lastTimerSecond then
					lastTimerSecond = currentSecond
					if timerLabel then
						setTextStack(timerLabel, formatCycleTimer(pack))
					end
				end
			end)
		end
	end

	local panelState = UiEffects.PreparePanel(panel)
	MenuGui.RegisterPanel(PANEL_NAME, {
		group = SHOP_MENU_GROUP,
		open = function()
			render()
			UiEffects.PlayOpen(panel, panelState)
			startPanelEffects()
		end,
		close = function(switching)
			stopPanelEffects()
			if switching then
				panel.Visible = false
				panel.Position = panelState.closedPosition
				panel.Size = panelState.closedSize
				return
			end
			UiEffects.PlayClose(panel, panelState)
		end,
		refresh = render,
	})
	RuntimeGuard.Connect(panel.Destroying, "DurianPackController.PanelDestroying", stopPanelEffects)

	local closeButton = panel:FindFirstChild("CloseButton")
	if closeButton and closeButton:IsA("GuiButton") then
		UiEffects.BindButton(closeButton)
		RuntimeGuard.Connect(closeButton.Activated, "DurianPackController.Close", function()
			MenuGui.ClosePanel(PANEL_NAME)
		end)
	else
		warn("[DurianPackController] DurianPackHolder missing CloseButton GuiButton")
	end

	-- HUD entry: the DurianPack frame shows the 3D pack model and opens the
	-- panel. Hidden while paid random items are restricted, the tutorial is
	-- active, or offline growth is still being applied after a rejoin.
	local hudEntry = nil
	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild(HUD_NAME, HUD_WAIT_SECONDS)
	if hud then
		hudEntry = hud:FindFirstChild(HUD_ENTRY_NAME)
	end
	if hudEntry and hudEntry:IsA("GuiObject") then
		if UserInputService.TouchEnabled then
			hudEntry.Position += UDim2.fromOffset(0, HUD_ENTRY_TOUCH_Y_OFFSET_PIXELS)
		end
		local hudViewport = hudEntry:FindFirstChild(PANEL_NAME)
		if hudViewport and hudViewport:IsA("ViewportFrame") then
			PackIconDisplay.RenderViewport(hudViewport, pack.PackId)
		else
			warn("[DurianPackController] HUD.DurianPack missing DurianPackHolder ViewportFrame")
		end
		local clickButton = hudEntry:FindFirstChild("Click")
		if clickButton and clickButton:IsA("GuiButton") then
			UiEffects.BindButton(clickButton)
			RuntimeGuard.Connect(clickButton.Activated, "DurianPackController.HudOpen", function()
				MenuGui.OpenPanel(PANEL_NAME)
			end)
		else
			warn("[DurianPackController] HUD.DurianPack missing Click GuiButton")
		end
	else
		warn("[DurianPackController] Missing HUD.DurianPack GuiObject")
	end

	local function applyHudVisibility()
		local visible = isHudEntryVisible()
		if hudEntry then
			hudEntry.Visible = visible
		end
		if not visible and MenuGui.IsOpen(PANEL_NAME) then
			MenuGui.ClosePanel(PANEL_NAME)
		end
		render()
	end

	RuntimeGuard.Connect(rollResultRemote.OnClientEvent, "DurianPackController.RollResult", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil
		render()
		if payload.success == true and type(payload.reveal) == "table" then
			SeedPackShopController.EnqueueReveal(payload.reveal)
		end
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.DurianTickets, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.DurianPackPity, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, applyHudVisibility)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.SeedPacksAllowed), "DurianPackController.Allowed", applyHudVisibility)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.OfflineProgressPending), "DurianPackController.OfflinePending", applyHudVisibility)
	applyHudVisibility()
end

return DurianPackController
