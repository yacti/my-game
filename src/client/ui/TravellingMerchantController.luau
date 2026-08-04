-- The Travelling Merchant menu: three offer cards, opened by standing in the
-- carriage's MerchantShop volume.
--
-- Which three offers are live is NOT replicated. The server stamps the visit's
-- startsAt on the runtime folder and both sides run the same pure
-- TravellingMerchant.OffersFor over it, so the client derives the identical
-- three with no remote. What IS replicated is the player's claims, which are
-- per-player and cannot be derived.
--
-- Card rendering follows the EndlessPack convention: every slot carries both an
-- ImageLabel and a ViewportFrame in the same rect, and exactly one is visible.
-- Rewards with a 3D model (seeds, packs) use the viewport; rewards without one
-- (cash, timeskips, tickets) use the flat icon from RewardIcons.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Food = require(Shared:WaitForChild("Food"))
local GameEvents = require(Shared:WaitForChild("GameEvents"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Onboarding = require(Shared:WaitForChild("Onboarding"))
local PartVolume = require(Shared:WaitForChild("PartVolume"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RewardIcons = require(Shared:WaitForChild("RewardIcons"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))
local TravellingMerchant = require(Shared:WaitForChild("TravellingMerchant"))

local ConfettiEffect = require(script.Parent:WaitForChild("ConfettiEffect"))
local FeedDisplayModel = require(script.Parent:WaitForChild("FeedDisplayModel"))
local HoverOver = require(script.Parent:WaitForChild("HoverOver"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PackIconDisplay = require(script.Parent:WaitForChild("PackIconDisplay"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SeedPackShopController = require(script.Parent:WaitForChild("SeedPackShopController"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local TravellingMerchantController = {}

local DEBUG_NAME = "TravellingMerchantController"
local MENU_GROUP = "Shop"
local PROXIMITY_SECONDS = 0.1
-- A countdown that only ever shows whole seconds does not need a render step.
local BILLBOARD_SECONDS = 0.25
-- Match the authored placeholder text on the carriage billboard and the panel
-- header respectively.
local BILLBOARD_PREFIX = "Leaving in: "
local PANEL_TIMER_PREFIX = "Leaves in: "

-- Merchant cards frame by projected silhouette rather than the shared reward
-- zoom. The offer pools mix shapes freely -- a single mushroom against a fruited
-- tree against a seed pack -- and a fixed zoom either clips the chunky ones or
-- leaves the slim ones marooned in empty space. fitPadding solves for the
-- closest the camera can sit without any of the model leaving frame, so every
-- one of them fills its card to the same margin whatever its proportions.
--
-- Note this normalises the model's OUTLINE, which is the most it can do from
-- here: PricklyPear spends a third of its footprint on thin spikes, so its
-- fruit still reads smaller than a Plum's. Fixing that means editing the model
-- or adding a per-food scale override, not changing the framing.
--
-- Built from the shared options so the lighting and colour boost still match
-- every other reward card in the game; only the framing differs.
local MERCHANT_PREVIEW_OPTIONS = {}
for key, value in pairs(FeedDisplayModel.REWARD_PREVIEW_OPTIONS) do
	MERCHANT_PREVIEW_OPTIONS[key] = value
end
-- 6% clear of every edge.
MERCHANT_PREVIEW_OPTIONS.fitPadding = 1.06
-- zoom is what fitPadding replaces; leaving it would just be misleading.
MERCHANT_PREVIEW_OPTIONS.zoom = nil

local Kinds = TravellingMerchant.RewardKinds

local player = Players.LocalPlayer
local started = false
local productPriceById = {}

local function int(value, minimum)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return minimum or 0
	end
	return math.max(math.floor(value), minimum or 0)
end

local function findDescendant(root, name, className)
	if not root then
		return nil
	end
	local direct = root:FindFirstChild(name)
	if direct and (not className or direct:IsA(className)) then
		return direct
	end
	for _, item in ipairs(root:GetDescendants()) do
		if item.Name == name and (not className or item:IsA(className)) then
			return item
		end
	end
	return nil
end

-- Cached because GetProductInfo is a web call and three cards would otherwise
-- refetch on every render. Mirrors ShopPanelController.robuxText.
local function robuxText(productId, onLoaded)
	productId = int(productId, 0)
	if productId <= 0 then
		return NumberFormatter.Robux(0)
	end
	local cached = productPriceById[productId]
	if cached then
		return cached
	end

	productPriceById[productId] = NumberFormatter.Robux(0)
	RuntimeGuard.Spawn(DEBUG_NAME .. ".ProductInfo", function()
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

---------------------------------------------------------------------------
-- Gates (client mirror of the server's eligibility rules)
---------------------------------------------------------------------------

-- Mirrors EventEligibility server-side. Without this the panel would auto-open
-- on a tutorial player who then cannot trade -- and the tutorial is the default
-- state in a fresh Play Solo, so it is the case most likely to be hit.
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

local function canTrade()
	return not isTutorialActive() and not isOfflineProgressPending()
end

---------------------------------------------------------------------------
-- Live visit
---------------------------------------------------------------------------

local function runtimeFolder()
	return TravellingMerchant.FindRuntimeFolder()
end

local function visitStartsAt(folder)
	folder = folder or runtimeFolder()
	if not folder then
		return nil
	end
	return tonumber(folder:GetAttribute(State.Merchant.StartsAt))
end

local function visitInstanceId(folder)
	folder = folder or runtimeFolder()
	if not folder then
		return nil
	end
	local instanceId = folder:GetAttribute(State.Merchant.InstanceId)
	return type(instanceId) == "string" and instanceId or nil
end

local function claimedSet()
	local stored = PlayerStateStore.Get(PlayerStateStore.Fields.TravellingMerchant)
	if type(stored) ~= "table" or type(stored.Claimed) ~= "table" then
		return {}
	end
	-- Claims from a previous visit are stale. The server wipes them lazily on
	-- the next trade, so the client must not show them as claimed in the
	-- meantime or all three cards would look spent on arrival.
	local instanceId = visitInstanceId()
	if instanceId == nil or stored.InstanceId ~= instanceId then
		return {}
	end
	return stored.Claimed
end

local function hourlyIncome()
	return math.max(tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.HourlyPetIncome)) or 0, 0)
end

---------------------------------------------------------------------------
-- Offer display
---------------------------------------------------------------------------

local function cashPayoutFor(reward)
	return ShopBalance.CashPackPayout({
		HoursOfIncome = reward.hoursOfIncome,
		BaseReward = reward.baseReward,
	}, hourlyIncome())
end

-- The amount label means QUANTITY and nothing else -- "x3", "x10". A duration
-- ("5m") or a cash value ("$6.25K") is not a quantity, so those rewards leave it
-- off entirely rather than borrowing the slot; the hover carries that detail
-- instead. Returning nil hides the label.
--
-- Keeping the slot free is what lets a future "2x 5 minute skip" read as "x2"
-- without colliding with the duration.
local function quantityText(amount)
	amount = math.max(int(amount, 1), 1)
	return "x" .. tostring(amount)
end

-- What to show for a reward: a flat icon or a viewport model, the amount text on
-- the card, and the hover payload. `subtitle` drives the hover's second line for
-- rewards that have no rarity (see HoverOver.normalizedPayload).
local function rewardDisplay(reward)
	if reward.kind == Kinds.Seed then
		local template, previewOptions = FeedDisplayModel.SeedPreview(
			reward.seedId, MERCHANT_PREVIEW_OPTIONS)
		return {
			viewportTemplate = template,
			viewportOptions = previewOptions,
			amountText = quantityText(reward.amount),
			hover = {
				name = Seeds.DisplayNameFor(reward.seedId) or reward.seedId,
				rarity = Seeds.RarityFor(reward.seedId),
			},
		}
	end

	if reward.kind == Kinds.SeedPack then
		local pack = ShopBalance.SeedPackForPackId(reward.packId)
		return {
			packId = reward.packId,
			amountText = quantityText(reward.amount),
			hover = {
				name = pack and pack.DisplayName or "Seed Pack",
				rarity = pack and pack.Rarity or nil,
			},
		}
	end

	if reward.kind == Kinds.GrowSkip then
		local skip = ShopBalance.GrowSkipForSkipId(reward.skipId)
		local count = math.max(int(reward.amount, 1), 1)
		return {
			icon = RewardIcons.GrowSkip,
			-- No label for a single skip: the duration belongs in the hover, not
			-- the quantity slot. Grant more than one and it correctly reads
			-- "x2".
			amountText = count > 1 and quantityText(count) or nil,
			hover = {
				name = skip and skip.DisplayName or "Timeskip",
				subtitle = "Reward",
			},
		}
	end

	if reward.kind == Kinds.DurianTicket then
		return {
			icon = RewardIcons.DurianTicket,
			amountText = quantityText(reward.amount),
			hover = { name = "Durian Ticket", subtitle = "Reward" },
		}
	end

	if reward.kind == Kinds.Cash then
		-- Recomputed on every render rather than cached: the payout scales with
		-- pet income, which changes while the panel is open.
		local payout = cashPayoutFor(reward)
		return {
			icon = RewardIcons.Cash,
			-- A cash value is not a quantity; the hover shows the amount.
			amountText = nil,
			hover = {
				name = "Cash",
				subtitle = NumberFormatter.Currency(payout),
				subtitleColor = RewardIcons.CashTextColor,
			},
		}
	end

	return { hover = { name = "Reward" } }
end

local function requestDisplay(request)
	return {
		viewportTemplate = Food.GetTemplate(request.foodId),
		viewportOptions = MERCHANT_PREVIEW_OPTIONS,
		amountText = "x" .. tostring(math.max(int(request.amount, 1), 1)),
		hover = {
			name = Food.DisplayNameFor(request.foodId) or request.foodId,
			rarity = Food.RarityFor(request.foodId),
		},
	}
end

---------------------------------------------------------------------------
-- Controller
---------------------------------------------------------------------------

function TravellingMerchantController.start()
	if started then
		return
	end
	started = true

	if not TravellingMerchant.Enabled then
		return
	end

	local panelName = TravellingMerchant.PanelName
	local panel = MenuGui.GetFrame(panelName, DEBUG_NAME)
	if not panel then
		return
	end

	local gui = panel:FindFirstAncestorOfClass("ScreenGui")
	-- Menu.TravellingMerchant is a full-screen transparent wrapper around the
	-- actual card, unlike GearShop/Settings which ARE the card. Animating the
	-- wrapper would shrink the card toward the screen's top-left corner instead
	-- of its own centre, so the wrapper only ever toggles visibility and the
	-- inner Panel is what tweens.
	local card = panel:FindFirstChild("Panel")
	local closeButton = findDescendant(panel, "CloseButton", "GuiButton")
	local tradeList = findDescendant(panel, "TradeList", "GuiObject")
	local template = tradeList and tradeList:FindFirstChild(TravellingMerchant.OfferTemplateName)
	if not (card and card:IsA("GuiObject") and closeButton and tradeList and template and template:IsA("GuiObject")) then
		warn("[" .. DEBUG_NAME .. "] Travelling Merchant UI missing required instances")
		panel.Visible = false
		return
	end

	-- The header holds TWO TextLabels both authored as "TierLabel": the title
	-- ("Travelling Merchant", which carries a nested Title label for its shadow
	-- stack) and a countdown ("Leaves in: ..."), which has no such child. Pick
	-- by structure, since the names collide and the text is what we replace.
	--
	-- Direct children only. Descendants would also walk INTO the title's stack
	-- and match its nested Title label, which has no Title child of its own --
	-- and writing the countdown there overwrites the panel's heading.
	local headerTimerLabel = nil
	local header = findDescendant(panel, "Header", "GuiObject")
	for _, item in ipairs(header and header:GetChildren() or {}) do
		if item:IsA("TextLabel") and not item:FindFirstChild("Title") then
			headerTimerLabel = item
			break
		end
	end
	if not headerTimerLabel then
		warn("[" .. DEBUG_NAME .. "] Header countdown label not found; panel timer will not update")
	end

	local requestRemote = Remotes.get(Remotes.Names.MerchantTradeRequest)
	local resultRemote = Remotes.get(Remotes.Names.MerchantTradeResult)

	UiEffects.BindAllButtons(panel)
	local panelState = UiEffects.PreparePanel(card)
	panel.Visible = false
	template.Visible = false

	local open = false
	local manuallyClosed = false
	local pendingRequestId = nil
	local nextRequestId = 0
	local transitionToken = 0
	-- Which visit the cards were last built for. A change means rebuild rather
	-- than re-render, because the offers themselves changed.
	local builtStartsAt = nil
	local cards = {}

	local render

	local function clearCards()
		for _, card in ipairs(cards) do
			-- Render(nil) tears the viewport's rig down; leaving it would keep a
			-- turntable connection alive for a carriage that has left.
			if card.viewportRequest then
				ViewportPreview.Render(card.viewportRequest, nil)
			end
			if card.viewportReward then
				ViewportPreview.Render(card.viewportReward, nil)
			end
			for _, unbind in ipairs(card.unbinds) do
				unbind()
			end
			card.gui:Destroy()
		end
		table.clear(cards)
		builtStartsAt = nil
	end

	-- Sets whichever of the icon/viewport pair applies and hides the other.
	local function applyVisual(iconLabel, viewport, display)
		if iconLabel then
			iconLabel.Visible = display.icon ~= nil
			iconLabel.Image = display.icon or ""
		end
		if viewport then
			local usesViewport = display.icon == nil
			viewport.Visible = usesViewport
			if not usesViewport then
				return
			end
			if display.packId then
				-- Same fit as the food and seeds. The pack keeps its own yaw,
				-- lighting and colour animation; only the framing is
				-- overridden, because the authored pack model is tall enough to
				-- clip this card at PackIconDisplay's default zoom.
				PackIconDisplay.RenderViewport(viewport, display.packId, {
					fitPadding = MERCHANT_PREVIEW_OPTIONS.fitPadding,
				})
			else
				ViewportPreview.Render(viewport, display.viewportTemplate, display.viewportOptions)
			end
		end
	end

	local function buildCards(startsAt)
		clearCards()
		builtStartsAt = startsAt

		for slot, offer in ipairs(TravellingMerchant.OffersFor(startsAt)) do
			local cardGui = template:Clone()
			cardGui.Name = "Offer_" .. tostring(slot)
			cardGui.LayoutOrder = slot
			cardGui.Visible = true
			cardGui.Parent = tradeList
			UiEffects.BindAllButtons(cardGui)

			local iconRequest = findDescendant(cardGui, "IconRequest", "ImageLabel")
			local iconReward = findDescendant(cardGui, "IconReward", "ImageLabel")
			local viewportRequest = findDescendant(cardGui, "ViewportRequest", "ViewportFrame")
			local viewportReward = findDescendant(cardGui, "ViewportReward", "ViewportFrame")
			local tradeButton = findDescendant(cardGui, "TradeButton", "GuiButton")
			local skipButton = findDescendant(cardGui, "SkipButton", "GuiButton")

			local request = requestDisplay(offer.request)
			local reward = rewardDisplay(offer.reward)

			-- Rendered once at build time, not per render pass: rebuilding a
			-- viewport every frame would rebuild the rig and restart its spin.
			applyVisual(iconRequest, viewportRequest, request)
			applyVisual(iconReward, viewportReward, reward)

			UiEffects.SetTextStack(findDescendant(cardGui, "Price", "TextLabel"), "Offer " .. tostring(slot))
			UiEffects.SetTextStack(findDescendant(cardGui, "RequestAmount", "TextLabel"), request.amountText)

			local card = {
				gui = cardGui,
				slot = slot,
				offer = offer,
				reward = offer.reward,
				request = offer.request,
				rewardAmountLabel = findDescendant(cardGui, "RewardAmount", "TextLabel"),
				claimedOverlay = findDescendant(cardGui, "Claimed", "GuiObject"),
				tradeButton = tradeButton,
				tradeLabel = tradeButton and findDescendant(tradeButton, "Price", "TextLabel"),
				skipButton = skipButton,
				skipLabel = skipButton and findDescendant(skipButton, "Price", "TextLabel"),
				viewportRequest = viewportRequest,
				viewportReward = viewportReward,
				unbinds = {},
			}

			-- Bound to both halves of each pair so the hover works whichever one
			-- ends up visible.
			for _, holder in ipairs({ iconRequest, viewportRequest }) do
				if holder then
					card.unbinds[#card.unbinds + 1] = HoverOver.Bind(holder, request.hover)
				end
			end
			for _, holder in ipairs({ iconReward, viewportReward }) do
				if holder then
					-- A function, not a table: the cash payout moves with pet
					-- income, so the hover must read it at hover time.
					card.unbinds[#card.unbinds + 1] = HoverOver.Bind(holder, function()
						return rewardDisplay(card.reward).hover
					end)
				end
			end

			if tradeButton then
				RuntimeGuard.Connect(tradeButton.Activated, DEBUG_NAME .. ".Trade", function()
					if pendingRequestId ~= nil or not canTrade() then
						return
					end
					if claimedSet()[card.offer.offerId] == true then
						return
					end
					nextRequestId += 1
					pendingRequestId = nextRequestId
					render()
					requestRemote:FireServer(pendingRequestId, card.offer.offerId, "trade")
				end)
			end

			if skipButton then
				RuntimeGuard.Connect(skipButton.Activated, DEBUG_NAME .. ".Skip", function()
					if pendingRequestId ~= nil or not canTrade() then
						return
					end
					if claimedSet()[card.offer.offerId] == true then
						return
					end
					local skip = ShopBalance.MerchantSkipForSlot(card.slot)
					if not skip or int(skip.DevProductId, 0) <= 0 then
						return
					end
					nextRequestId += 1
					pendingRequestId = nextRequestId
					render()
					requestRemote:FireServer(pendingRequestId, card.offer.offerId, "skip")
				end)
			end

			cards[#cards + 1] = card
		end
	end

	render = function()
		local startsAt = visitStartsAt()
		if startsAt == nil then
			clearCards()
			return
		end
		if builtStartsAt ~= startsAt then
			buildCards(startsAt)
		end

		local claimed = claimedSet()
		local tradable = canTrade()

		for _, card in ipairs(cards) do
			local isClaimed = claimed[card.offer.offerId] == true

			-- nil amountText means this reward has no quantity worth stating
			-- (a duration, a cash value), so the label is hidden rather than
			-- filled with something that is not a count.
			if card.rewardAmountLabel then
				local amountText = rewardDisplay(card.reward).amountText
				card.rewardAmountLabel.Visible = amountText ~= nil
				if amountText then
					UiEffects.SetTextStack(card.rewardAmountLabel, amountText)
				end
			end

			if card.claimedOverlay then
				card.claimedOverlay.Visible = isClaimed
			end

			-- Buttons are never dimmed for "claimed" or for a shortfall. The
			-- Claimed scrim already covers the whole card and says everything a
			-- greyed-out button would, and a shortfall is answered with a toast
			-- on press. Only a genuinely inert state (mid-request, or gated by
			-- tutorial/offline) dims them.
			local buttonsLive = tradable and pendingRequestId == nil

			if card.tradeButton then
				UiEffects.SetTextStack(card.tradeLabel, "Trade")
				UiEffects.SetButtonEnabled(card.tradeButton, buttonsLive)
			end

			if card.skipButton then
				local skip = ShopBalance.MerchantSkipForSlot(card.slot)
				local productId = skip and int(skip.DevProductId, 0) or 0
				-- Hidden entirely while the product id is still a placeholder,
				-- so an unconfigured slot reads as "trade only" rather than a
				-- button that does nothing.
				card.skipButton.Visible = productId > 0
				if productId > 0 then
					UiEffects.SetTextStack(card.skipLabel, robuxText(productId, render))
					UiEffects.SetButtonEnabled(card.skipButton, buttonsLive)
				end
			end
		end
	end

	local function showPanel()
		if open then
			render()
			return
		end
		open = true
		transitionToken += 1
		render()
		panel.Visible = true
		UiEffects.PlayOpen(card, panelState)
	end

	local function hidePanel(switching)
		if not open and not panel.Visible then
			return
		end
		open = false
		transitionToken += 1
		local token = transitionToken
		if switching then
			-- Panel switches skip the tween entirely, so both layers go down at
			-- once rather than leaving the wrapper up over the next panel.
			panel.Visible = false
			card.Visible = false
			card.Position = panelState.closedPosition
			card.Size = panelState.closedSize
			return
		end
		UiEffects.PlayClose(card, panelState, function()
			if token == transitionToken and not open then
				panel.Visible = false
			end
		end)
	end

	MenuGui.RegisterPanel(panelName, {
		group = MENU_GROUP,
		open = showPanel,
		close = hidePanel,
		refresh = render,
	})

	RuntimeGuard.Connect(closeButton.Activated, DEBUG_NAME .. ".Close", function()
		manuallyClosed = true
		MenuGui.ClosePanel(panelName)
	end)

	RuntimeGuard.Connect(resultRemote.OnClientEvent, DEBUG_NAME .. ".Result", function(payload)
		if type(payload) ~= "table" then
			return
		end

		-- A skip grant arrives with no requestId (the receipt, not the request),
		-- so clear any pending state on either shape.
		if payload.requestId == nil or payload.requestId == pendingRequestId then
			pendingRequestId = nil
		end

		if payload.success and payload.code == "prompt" then
			local productId = int(payload.productId, 0)
			if productId > 0 then
				MarketplaceService:PromptProductPurchase(player, productId)
			end
			-- The purchase is still outstanding; the receipt result reopens the
			-- buttons, and PromptProductPurchaseFinished clears it server-side
			-- if the player declines.
			pendingRequestId = nil
		end

		-- Confetti on a claimed reward, whether it was traded for or skipped
		-- with Robux. Skipped for a seed pack: that hands off to the pack
		-- reveal, which fires its own confetti when the pack is opened, and two
		-- bursts for one reward reads as a bug.
		if payload.success and (payload.code == "traded" or payload.code == "skipped") then
			if type(payload.reveal) ~= "table" then
				ConfettiEffect.Emit()
			end
		end

		if type(payload.reveal) == "table" then
			SeedPackShopController.EnqueueReveal(payload.reveal)
		end

		render()
	end)

	-- No FoodInventory observer: nothing on a card depends on how much the
	-- player is holding any more, and food counts churn constantly while
	-- farming, so observing it would re-render the panel for nothing.
	PlayerStateStore.Observe(PlayerStateStore.Fields.TravellingMerchant, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.HourlyPetIncome, render)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Onboarding, render)
	RuntimeGuard.Connect(
		player:GetAttributeChangedSignal(State.Player.OfflineProgressPending),
		DEBUG_NAME .. ".OfflinePending",
		render
	)

	-- Proximity auto-open. Mirrors ShopPanelController, including the
	-- manuallyClosed latch so closing the panel while still standing inside does
	-- not immediately reopen it.
	RuntimeGuard.Spawn(DEBUG_NAME .. ".Proximity", function()
		while gui and gui.Parent do
			local shopPart = TravellingMerchant.FindShopPart()
			-- A pack reveal is a modal ceremony that lives in the same "Shop"
			-- menu group, so the group clause below would happily reopen this
			-- panel over it on the very next poll -- and the player standing at
			-- the stall would never get to open the pack they just traded for.
			if SeedPackShopController.IsRevealActive() then
				task.wait(PROXIMITY_SECONDS)
				continue
			end
			if shopPart and canTrade() and PartVolume.ContainsPlayer(shopPart, player) then
				local activePanel = MenuGui.ActivePanel()
				if not manuallyClosed
					and (activePanel == nil or activePanel == panelName or MenuGui.ActivePanelGroup() == MENU_GROUP) then
					MenuGui.OpenPanel(panelName)
				end
			else
				manuallyClosed = false
				if MenuGui.IsOpen(panelName) then
					MenuGui.ClosePanel(panelName)
				end
			end
			task.wait(PROXIMITY_SECONDS)
		end
	end)

	-- Watches the visit: drives the carriage countdown, and rebuilds or clears
	-- the cards when the merchant arrives or leaves.
	--
	-- The rebuild has to live here rather than in an observer. Nothing the
	-- client subscribes to fires when the carriage is cloned into the map, so
	-- without this poll the cards would only ever appear if something else
	-- happened to call render() during the visit.
	RuntimeGuard.Spawn(DEBUG_NAME .. ".Visit", function()
		while true do
			local folder = runtimeFolder()
			local startsAt = visitStartsAt(folder)
			if startsAt ~= builtStartsAt then
				render()
				if startsAt == nil and MenuGui.IsOpen(panelName) then
					-- He left with the panel open.
					MenuGui.ClosePanel(panelName)
				end
			end

			if folder then
				local endsAt = tonumber(folder:GetAttribute(State.Merchant.EndsAt))
				if endsAt then
					local remaining = GameEvents.FormatDuration(
						math.max(endsAt - workspace:GetServerTimeNow(), 0))
					-- Both timers keep their authored prefixes; they read as
					-- sentences, not bare clocks.
					local label = findDescendant(folder, TravellingMerchant.BillboardTimerName, "TextLabel")
					if label then
						UiEffects.SetTextStack(label, BILLBOARD_PREFIX .. remaining)
					end
					if headerTimerLabel then
						UiEffects.SetTextStack(headerTimerLabel, PANEL_TIMER_PREFIX .. remaining)
					end
				end
			end
			task.wait(BILLBOARD_SECONDS)
		end
	end)

	render()
end

return TravellingMerchantController
