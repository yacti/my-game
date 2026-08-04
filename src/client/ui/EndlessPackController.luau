-- Endless Pack claim track inside the RobuxShop panel
-- (RobuxShop.SFHolder.EndlessPack). Renders a sliding window of upcoming
-- track items into the Items horizontal ScrollingFrame by cloning the
-- authored Template card; only the first card (the next claimable position)
-- is actionable. Free items fire EndlessPackClaimRequest; paid items get the
-- authoritative product id back via "purchase-required" and prompt the Robux
-- purchase, whose receipt advances the replicated EndlessPackProgress field
-- and triggers a window rebuild. Seed pack claims reuse the standard
-- SeedPackShopController pack-opening reveal. The Timer countdown is
-- visual-only and loops like the starter pack cycle. The section is always
-- visible: no tutorial/offline gating, and no paid-random-items policy gate
-- (the Robux products are deterministic money packs; randomness only exists
-- in free claims).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local ConfettiEffect = require(script.Parent:WaitForChild("ConfettiEffect"))
local FeedDisplayModel = require(script.Parent:WaitForChild("FeedDisplayModel"))
local MenuGui = require(script.Parent:WaitForChild("MenuGui"))
local PackIconDisplay = require(script.Parent:WaitForChild("PackIconDisplay"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SeedPackShopController = require(script.Parent:WaitForChild("SeedPackShopController"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local EndlessPackController = {}

local PANEL_NAME = "RobuxShop"
local SECTION_NAME = "EndlessPack"
local RUNTIME_CARD_NAME = "__EndlessPackItem"
-- First claimable card plus the upcoming preview cards. Scrolling is
-- disabled, so this only needs to fill the visible strip (~5 cards).
local WINDOW_SIZE = 6
local PROMPT_TIMEOUT_SECONDS = 15

local SEED_PREVIEW_OPTIONS = {
	targetMaxDimension = 6,
	zoom = 1.8,
	colorSaturation = 2.5,
	colorBrightness = 1.55,
	lightColor = Color3.fromRGB(255, 255, 255),
}

local Kinds = ShopBalance.EndlessPackKinds

local player = Players.LocalPlayer
local productPriceById = {}
local nextRequestId = 0
local pendingRequestId = nil
local pendingProductId = nil
local promptToken = 0

local claimRequestRemote = Remotes.get(Remotes.Names.EndlessPackClaimRequest)
local claimResultRemote = Remotes.get(Remotes.Names.EndlessPackClaimResult)

local function child(parent, name, className)
	local found = parent and parent:FindFirstChild(name)
	if found and (not className or found:IsA(className)) then
		return found
	end
	return nil
end

local function findDescendant(root, name, className)
	for _, item in ipairs(root and root:GetDescendants() or {}) do
		if item.Name == name and (not className or item:IsA(className)) then
			return item
		end
	end
	return nil
end

local function setTextStack(root, text)
	UiEffects.SetTextStack(root, tostring(text or ""))
end

local function isProfileReady()
	return PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
end

local function progress()
	return math.max(math.floor(tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.EndlessPackProgress)) or 0), 0)
end

local function robuxText(productId)
	productId = tonumber(productId) or 0
	return productPriceById[productId] or NumberFormatter.Robux(0)
end

-- All track product prices are fetched once at controller start so Robux
-- buttons show real prices as soon as the shop is opened; onLoaded fires per
-- resolved product so already-rendered cards can refresh.
local function prefetchProductPrices(onLoaded)
	for _, productId in ipairs(ShopBalance.EndlessPack.Products or {}) do
		productId = tonumber(productId) or 0
		if productId > 0 and productPriceById[productId] == nil then
			RuntimeGuard.Spawn("EndlessPackController.ProductInfo", function()
				local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, productId, Enum.InfoType.Product)
				if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
					productPriceById[productId] = NumberFormatter.Robux(info.PriceInRobux)
					if onLoaded then
						onLoaded()
					end
				end
			end)
		end
	end
end

local function formatCycleTimer()
	local pack = ShopBalance.EndlessPack
	local cycleSeconds = math.max(math.floor(tonumber(pack and pack.CycleSeconds) or 0), 0)
	if cycleSeconds <= 0 then
		return "0h 0m 0s left"
	end
	local remaining = cycleSeconds - (os.time() % cycleSeconds)
	if remaining <= 0 or remaining > cycleSeconds then
		remaining = cycleSeconds
	end
	local hours = math.floor(remaining / 3600)
	local minutes = math.floor((remaining % 3600) / 60)
	local seconds = remaining % 60
	return string.format("%dh %dm %ds left", hours, minutes, seconds)
end

local function renderCardIcon(card, item)
	local icon = findDescendant(card, "Icon", "ViewportFrame")
	local iconImage = findDescendant(card, "IconImage", "ImageLabel")
	local flatIcon = item.Icon

	if iconImage then
		iconImage.Visible = flatIcon ~= nil
		iconImage.Image = flatIcon or ""
	end
	if icon then
		icon.Visible = flatIcon == nil
		if flatIcon == nil then
			if item.Kind == Kinds.SeedPack or item.Kind == Kinds.EpicSeedPack then
				PackIconDisplay.RenderViewport(icon, item.PackId)
			elseif item.Kind == Kinds.SeedGrant then
				local template, previewOptions = FeedDisplayModel.SeedPreview(item.SeedId, SEED_PREVIEW_OPTIONS)
				ViewportPreview.Render(icon, template, previewOptions)
			end
		end
	end
end

function EndlessPackController.start()
	local panel = MenuGui.GetFrame(PANEL_NAME, "EndlessPackController")
	if not panel then
		return
	end

	local holder = findDescendant(panel, "SFHolder", "ScrollingFrame")
	local section = holder and child(holder, SECTION_NAME, "GuiObject")
	if not section then
		warn("[EndlessPackController] Missing RobuxShop.SFHolder.EndlessPack section")
		return
	end

	local timerLabel = findDescendant(section, "Timer", "TextLabel")
	local items = findDescendant(section, "Items", "ScrollingFrame")
	local template = items and child(items, "Template", "GuiObject")
	if not (items and template) then
		warn("[EndlessPackController] EndlessPack section missing Items ScrollingFrame with Template card")
		return
	end

	template.Visible = false
	-- The canvas must follow the runtime card count. Only the X axis may be
	-- automatic: card Size scale is canvas-relative on non-automatic axes, so
	-- zeroing the authored CanvasSize Y would collapse card heights
	-- (verified empirically in Studio). The strip is a fixed window onto the
	-- track: players never scroll it and no scrollbar shows.
	items.AutomaticCanvasSize = Enum.AutomaticSize.X
	items.ScrollingDirection = Enum.ScrollingDirection.X
	items.ScrollingEnabled = false
	items.ScrollBarThickness = 0

	setTextStack(findDescendant(section, "Title", "TextLabel"), ShopBalance.EndlessPack.DisplayName)

	local rebuild
	-- Paid price labels currently on screen, refreshed when a prefetched
	-- product price resolves after the cards were already rendered.
	local paidPriceLabels = {}

	local function refreshPrices()
		for _, entry in ipairs(paidPriceLabels) do
			if entry.priceLabel.Parent then
				setTextStack(entry.priceLabel, robuxText(entry.productId))
			end
		end
	end

	local function requestClaim(position)
		if pendingRequestId ~= nil
			or pendingProductId ~= nil
			or not isProfileReady() then
			return
		end
		nextRequestId += 1
		pendingRequestId = nextRequestId
		rebuild()
		claimRequestRemote:FireServer(pendingRequestId, position)
	end

	local function bindCard(card, item, isFirst)
		local buyButton = findDescendant(card, "Buy", "GuiButton")
		local priceLabel = buyButton and findDescendant(buyButton, "Price", "TextLabel")
		renderCardIcon(card, item)
		if not buyButton then
			warn("[EndlessPackController] EndlessPack card template missing Buy GuiButton")
			return
		end

		if item.Paid then
			setTextStack(priceLabel, robuxText(item.ProductId))
			if priceLabel then
				paidPriceLabels[#paidPriceLabels + 1] = {
					priceLabel = priceLabel,
					productId = item.ProductId,
				}
			end
		else
			setTextStack(priceLabel, "FREE")
		end

		-- Cards keep their authored look at all times (no transparency
		-- dimming); upcoming cards are simply inert until they become first.
		if isFirst then
			-- Clones inherit the authored template's already-bound flag, which
			-- would make BindButton a no-op; clear it so the live card gets
			-- real hover/press effects.
			buyButton:SetAttribute("UiEffectsButtonBound", nil)
			UiEffects.BindButton(buyButton)
			RuntimeGuard.Connect(buyButton.Activated, "EndlessPackController.Claim." .. tostring(item.Position), function()
				requestClaim(item.Position)
			end)
		else
			buyButton.Active = false
			buyButton.AutoButtonColor = false
		end
	end

	rebuild = function()
		table.clear(paidPriceLabels)
		for _, existing in ipairs(items:GetChildren()) do
			if existing.Name == RUNTIME_CARD_NAME then
				existing:Destroy()
			end
		end

		local nextPosition = progress() + 1
		for offset = 0, WINDOW_SIZE - 1 do
			local position = nextPosition + offset
			local item = ShopBalance.EndlessPackItemForPosition(position)
			if not item then
				break
			end
			local card = template:Clone()
			card.Name = RUNTIME_CARD_NAME
			card.LayoutOrder = offset
			card.Visible = true
			bindCard(card, item, offset == 0)
			card.Parent = items
		end
		items.CanvasPosition = Vector2.new(0, items.CanvasPosition.Y)
	end

	RuntimeGuard.Connect(claimResultRemote.OnClientEvent, "EndlessPackController.ClaimResult", function(payload)
		if type(payload) ~= "table" or payload.requestId ~= pendingRequestId then
			return
		end
		pendingRequestId = nil

		if payload.code == "purchase-required" then
			local productId = tonumber(payload.productId) or 0
			if productId > 0 then
				promptToken += 1
				local token = promptToken
				pendingProductId = productId
				RuntimeGuard.Run("EndlessPackController.PromptProductPurchase", function()
					MarketplaceService:PromptProductPurchase(player, productId)
				end)
				task.delay(PROMPT_TIMEOUT_SECONDS, function()
					if pendingProductId == productId and promptToken == token then
						pendingProductId = nil
						rebuild()
					end
				end)
			end
			rebuild()
			return
		end

		rebuild()
		if payload.success == true and type(payload.reveal) == "table" then
			SeedPackShopController.EnqueueReveal(payload.reveal)
		end
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "EndlessPackController.PromptFinished", function(userId, productId)
		if userId ~= player.UserId or productId ~= pendingProductId then
			return
		end
		promptToken += 1
		pendingProductId = nil
		-- The receipt advances EndlessPackProgress, which rebuilds via the
		-- observer; rebuild here as well so a cancelled prompt re-enables the
		-- Buy button immediately.
		rebuild()
	end)

	-- Every redeem (free claim or paid purchase) celebrates with the same
	-- confetti burst Server Luck uses. Watching the replicated progress field
	-- covers receipt-driven paid advances too. Seed pack redeems are skipped
	-- here because their pack-opening reveal already emits the identical
	-- burst when the player opens the pack.
	PlayerStateStore.Observe(PlayerStateStore.Fields.EndlessPackProgress, function(newValue, oldValue)
		local newProgress = math.floor(tonumber(newValue) or 0)
		local oldProgress = math.floor(tonumber(oldValue) or -1)
		if oldValue ~= nil and newProgress > oldProgress and oldProgress >= 0 then
			for position = oldProgress + 1, newProgress do
				local item = ShopBalance.EndlessPackItemForPosition(position)
				local kind = item and item.Kind
				if kind ~= Kinds.SeedPack and kind ~= Kinds.EpicSeedPack then
					ConfettiEffect.Emit()
					break
				end
			end
		end
		rebuild()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, rebuild)

	local lastTimerSecond = -1
	RuntimeGuard.Connect(RunService.Heartbeat, "EndlessPackController.Timer", function()
		if not (timerLabel and panel.Visible) then
			return
		end
		local currentSecond = os.time()
		if currentSecond == lastTimerSecond then
			return
		end
		lastTimerSecond = currentSecond
		setTextStack(timerLabel, formatCycleTimer())
	end)
	if timerLabel then
		setTextStack(timerLabel, formatCycleTimer())
	end

	prefetchProductPrices(refreshPrices)
	rebuild()
end

return EndlessPackController
