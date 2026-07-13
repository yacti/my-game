local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Assets = require(Shared:WaitForChild("Assets"))
local NotificationConfig = require(Shared:WaitForChild("Notifications"))
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
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
local Notifications = require(script.Parent:WaitForChild("Notifications"))
local PackIconDisplay = require(script.Parent:WaitForChild("PackIconDisplay"))
local PlayerStateStore = require(script.Parent:WaitForChild("PlayerStateStore"))
local SeedPackShopController = require(script.Parent:WaitForChild("SeedPackShopController"))
local UiEffects = require(script.Parent:WaitForChild("UiEffects"))
local ViewportPreview = require(script.Parent:WaitForChild("ViewportPreview"))

local StarterPackController = {}

local PANEL_NAME = "RobuxShop"
local PREVIEW_OPTIONS = {
	targetMaxDimension = 6,
	zoom = 1.8,
}
local SEED_PREVIEW_OPTIONS = {
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
local pendingRequestPackId = nil
local feedTemplateByType = nil

local function child(parent, name, className)
	local found = parent and parent:FindFirstChild(name)
	if found and (not className or found:IsA(className)) then
		return found
	end
	return nil
end

local function descendant(parent, name, className)
	for _, item in ipairs(parent and parent:GetDescendants() or {}) do
		if item.Name == name and (not className or item:IsA(className)) then
			return item
		end
	end
	return nil
end

local function sortedGuiChildren(parent, name)
	local children = {}
	for _, item in ipairs(parent and parent:GetChildren() or {}) do
		if item.Name == name and item:IsA("GuiObject") then
			children[#children + 1] = item
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

local function findShopCards()
	local panel = MenuGui.GetFrame(PANEL_NAME, "StarterPackController")
	if not panel then
		return {}
	end
	local sfHolder = panel:FindFirstChild("SFHolder", true)
	local featured = sfHolder and sfHolder:FindFirstChild("Featured")
	if not (featured and featured:IsA("GuiObject")) then
		warn("[StarterPackController] Missing RobuxShop.SFHolder.Featured")
		return {}
	end
	local records = {}
	for _, pack in ipairs(ShopBalance.AllStarterPacks()) do
		local card = featured:FindFirstChild(pack.PackId)
		if card and card:IsA("GuiObject") then
			records[#records + 1] = {
				pack = pack,
				card = card,
				source = "RobuxShop.SFHolder.Featured." .. tostring(pack.PackId),
			}
		else
			warn("[StarterPackController] Missing RobuxShop.SFHolder.Featured." .. tostring(pack.PackId))
		end
	end
	return records
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
	RuntimeGuard.Spawn("StarterPackController.ProductInfo", function()
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

local function buildFeedIndex()
	local result = {}
	local root = Assets.Find(Assets.Names.FeedMachines)
	if not root then
		return result
	end
	for _, instance in ipairs(root:GetDescendants()) do
		if instance:IsA("BasePart") or instance:IsA("Model") then
			local feedType = instance:GetAttribute(State.Feed.Type)
			if type(feedType) == "string" and feedType ~= "" and not result[feedType] then
				result[feedType] = instance
			end
		end
	end
	return result
end

local function feedTemplateFor(feedType)
	if not feedTemplateByType then
		feedTemplateByType = buildFeedIndex()
	end
	return feedTemplateByType[feedType]
end

local function rewardDisplayInfo(reward)
	if reward and reward.Kind == ShopBalance.StarterPackRewardKinds.Cash then
		return nil, NumberFormatter.CurrencyExact(reward.Amount), nil
	end
	if reward and reward.Kind == ShopBalance.StarterPackRewardKinds.SeedPack then
		local seedPack = ShopBalance.SeedPackForPackId(reward.PackId)
		return nil, seedPack and seedPack.DisplayName or tostring(reward.PackId), nil
	end
	if reward and reward.Kind == ShopBalance.StarterPackRewardKinds.FeedMachine then
		local feedType = reward.FeedType
		local template = feedTemplateFor(feedType)
		local rarity = template and template:GetAttribute(State.Feed.Rarity) or nil
		return template, template and template.Name or feedType, rarity
	end

	local seedId = reward and reward.SeedId
	local template, previewOptions = FeedDisplayModel.SeedPreview(seedId, SEED_PREVIEW_OPTIONS)
	return template, Seeds.DisplayNameFor(seedId), Seeds.RarityFor(seedId), previewOptions
end

local function renderRewardSlot(slot, reward)
	local icon = descendant(slot, "Icon", "ViewportFrame")
	local iconImage = child(slot, "IconImage", "ImageLabel") or descendant(slot, "IconImage", "ImageLabel")
	local nameLabel = child(slot, "Name", "TextLabel") or descendant(slot, "Name", "TextLabel")
	local amountLabel = child(slot, "Amount", "TextLabel") or descendant(slot, "Amount", "TextLabel")
	local amount = math.max(math.floor(tonumber(reward and reward.Amount) or 0), 0)
	local template, displayName, rarity, seedPreviewOptions = rewardDisplayInfo(reward)
	local isCash = reward ~= nil and reward.Kind == ShopBalance.StarterPackRewardKinds.Cash
	local isSeedPack = reward ~= nil and reward.Kind == ShopBalance.StarterPackRewardKinds.SeedPack

	slot.Visible = reward ~= nil
	if icon then
		icon.Visible = not isCash
		if isSeedPack then
			PackIconDisplay.RenderViewport(icon, reward.PackId)
		else
			local previewOptions = reward and reward.Kind == ShopBalance.StarterPackRewardKinds.Seed and seedPreviewOptions or PREVIEW_OPTIONS
			ViewportPreview.Render(icon, template, previewOptions)
		end
	end
	if iconImage then
		iconImage.Visible = isCash
		iconImage.Image = isCash and ShopBalance.CashRewardIcon or ""
	end
	setTextStack(nameLabel, displayName)
	if amountLabel then
		local showAmount = not isCash and amount > 1
		amountLabel.Visible = showAmount
		setTextStack(amountLabel, showAmount and string.format("(%s)", NumberFormatter.Integer(amount)) or "")
	end
	HoverOver.Bind(slot, function()
		local xp = nil
		if reward and reward.Kind == ShopBalance.StarterPackRewardKinds.Seed then
			xp = FeedXPText.ForSeed(reward.SeedId)
		elseif reward and reward.Kind == ShopBalance.StarterPackRewardKinds.FeedMachine then
			xp = FeedXPText.ForFeedType(reward.FeedType)
		end
		return {
			name = displayName,
			rarity = rarity,
			xp = xp,
		}
	end)
end

local function formatCycleTimer()
	local cycleSeconds = math.max(math.floor(tonumber(ShopBalance.StarterPackCycleSeconds) or 0), 0)
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

local function starterPackPurchases()
	local purchases = PlayerStateStore.Get(PlayerStateStore.Fields.StarterPackPurchases)
	return type(purchases) == "table" and purchases or {}
end

local function isPackOwned(pack)
	local purchases = starterPackPurchases()
	if purchases[pack.PackId] ~= nil then
		return purchases[pack.PackId] == true
	end
	return pack.PackId == "StarterPack" and PlayerStateStore.Get(PlayerStateStore.Fields.StarterPackPurchased) == true
end

local function activeStarterPackId()
	local rebirths = math.max(math.floor(tonumber(PlayerStateStore.Get(PlayerStateStore.Fields.Rebirths)) or 0), 0)
	local pack = ShopBalance.StarterPackForRebirths(rebirths)
	return pack and pack.PackId or nil
end

-- Paid-random-items policy: restricted players see (and are granted) the
-- deterministic cash fallback in place of the random seed pack roll.
local function isSeedPacksAllowed()
	return player:GetAttribute(State.Player.SeedPacksAllowed) == true
end

local function rewardsForPack(pack)
	return ShopBalance.StarterPackRewardsForPolicy(pack, isSeedPacksAllowed())
end

local renderAllRef = nil
local requestRemote = Remotes.get(Remotes.Names.StarterPackPurchaseRequest)
-- Product id of the Robux dialog we last opened, until the engine reports it
-- closed. While set, the engine silently drops new PromptProductPurchase
-- calls, so surface that instead of appearing dead (closing our own UI does
-- not close the engine dialog).
local openPurchaseDialogProductId = nil

-- Starts the preflight -> PromptProductPurchase flow for a pack; shared by the
-- shop card buy button and the plot StarterPackPromptController. Returns
-- false when a purchase is already pending or the pack is not buyable.
function StarterPackController.RequestPurchase(packId)
	local pack = ShopBalance.StarterPackForPackId(packId)
	if openPurchaseDialogProductId ~= nil then
		Notifications.show({
			text = "Finish or cancel the open Robux purchase first",
			kind = NotificationConfig.Kinds.Error,
		})
		return false
	end
	if not pack
		or pendingRequestId ~= nil
		or isPackOwned(pack)
		or activeStarterPackId() ~= pack.PackId
		or PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) ~= true then
		return false
	end
	nextRequestId += 1
	pendingRequestId = nextRequestId
	pendingRequestPackId = pack.PackId
	if renderAllRef then
		renderAllRef()
	end
	requestRemote:FireServer(pendingRequestId, pack.PackId)
	return true
end

-- Renders one reward card slot (Icon/IconImage/Name/Amount template); also
-- used by StarterPackPromptController for the world offer billboard.
function StarterPackController.RenderRewardSlot(slot, reward)
	renderRewardSlot(slot, reward)
end

function StarterPackController.FormatCycleTimer()
	return formatCycleTimer()
end

-- Cached Robux price text for a dev product; onLoaded fires once the real
-- price arrives from MarketplaceService (the first call returns a 0 placeholder).
function StarterPackController.RobuxPriceText(productId, onLoaded)
	return robuxText(productId, onLoaded)
end

function StarterPackController.RewardsForPack(pack)
	return rewardsForPack(pack)
end

local function bindCard(record)
	local card = record.card
	local pack = record.pack
	local packRewards = pack and pack.Rewards or {}
	local buyButton = child(card, "BuyButton", "GuiButton")
	local priceLabel = buyButton and descendant(buyButton, "Price", "TextLabel")
	local title = child(card, "Name", "TextLabel")
	local sold = child(card, "Sold", "GuiObject")
	local timer = child(card, "Timer", "TextLabel")
	local items = child(card, "Items", "GuiObject")
	local slots = sortedGuiChildren(items, "Template")
	if not (pack and buyButton and priceLabel and sold and items and #slots >= #packRewards) then
		warn("[StarterPackController] " .. tostring(record.source) .. " is missing required named instances")
		return nil
	end

	UiEffects.BindButton(buyButton)
	setTextStack(title, pack.DisplayName or "Starter Pack")

	local function applySlots()
		local rewards = rewardsForPack(pack)
		for index, slot in ipairs(slots) do
			renderRewardSlot(slot, rewards[index])
		end
	end
	applySlots()

	local function render()
		local active = activeStarterPackId() == pack.PackId
		local owned = isPackOwned(pack)
		local ready = PlayerStateStore.Get(PlayerStateStore.Fields.ProfileReady) == true
		local productId = tonumber(pack.DevProductId) or 0

		card.Visible = active
		sold.Visible = owned
		buyButton.Visible = true
		if timer then
			setTextStack(timer, formatCycleTimer())
		end
		setTextStack(priceLabel, robuxText(productId, render))
		UiEffects.SetButtonEnabled(buyButton, active and ready and not owned and productId > 0 and pendingRequestId == nil)
	end

	RuntimeGuard.Connect(buyButton.Activated, "StarterPackController.Buy." .. tostring(pack.PackId), function()
		StarterPackController.RequestPurchase(pack.PackId)
	end)
	return render, applySlots
end

function StarterPackController.start()
	local renderers = {}
	local slotAppliers = {}
	local renderAll
	renderAll = function()
		for _, render in ipairs(renderers) do
			render()
		end
	end
	renderAllRef = renderAll

	for _, record in ipairs(findShopCards()) do
		local render, applySlots = bindCard(record)
		if render then
			renderers[#renderers + 1] = render
			slotAppliers[#slotAppliers + 1] = applySlots
		end
	end
	if #renderers == 0 then
		return
	end

	RuntimeGuard.Connect(Remotes.get(Remotes.Names.StarterPackPurchaseResult).OnClientEvent, "StarterPackController.PurchaseResult", function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.action == "reveal" then
			-- Seed pack rewards rolled by the receipt grant play the standard
			-- pack-opening reveal, then return to the Featured shop section.
			SeedPackShopController.EnqueueReveal(payload)
			return
		end
		if payload.requestId ~= pendingRequestId then
			return
		end
		local requestPackId = pendingRequestPackId
		pendingRequestId = nil
		pendingRequestPackId = nil
		renderAll()
		local productId = tonumber(payload.productId) or 0
		if payload.success == true and productId > 0 then
			RuntimeGuard.Run("StarterPackController.PromptProductPurchase", function()
				openPurchaseDialogProductId = productId
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
		elseif payload.packId ~= nil and payload.packId ~= requestPackId then
			renderAll()
		end
	end)

	RuntimeGuard.Connect(MarketplaceService.PromptProductPurchaseFinished, "StarterPackController.PurchaseFinished", function(userId, productId)
		if userId == player.UserId and productId == openPurchaseDialogProductId then
			openPurchaseDialogProductId = nil
			renderAll()
		end
	end)

	PlayerStateStore.Observe(PlayerStateStore.Fields.ProfileReady, renderAll)
	PlayerStateStore.Observe(PlayerStateStore.Fields.Rebirths, renderAll)
	RuntimeGuard.Connect(player:GetAttributeChangedSignal(State.Player.SeedPacksAllowed), "StarterPackController.SeedPacksAllowed", function()
		-- Policy resolves asynchronously after join; swap seed pack slots for
		-- their cash fallback (or back) once it lands.
		for _, applySlots in ipairs(slotAppliers) do
			applySlots()
		end
		renderAll()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.StarterPackPurchased, function(purchased, previousPurchased)
		if purchased == true and previousPurchased == false then
			ConfettiEffect.Emit()
		end
		renderAll()
	end)
	PlayerStateStore.Observe(PlayerStateStore.Fields.StarterPackPurchases, function(purchases, previousPurchases)
		if type(purchases) == "table" and type(previousPurchases) == "table" then
			for packId, purchased in pairs(purchases) do
				local wasPurchased = previousPurchases[packId] == true
				if packId ~= "StarterPack" and purchased == true and not wasPurchased then
					ConfettiEffect.Emit()
					break
				end
			end
		end
		renderAll()
	end)

	local lastTimerSecond = -1
	RuntimeGuard.Connect(RunService.Heartbeat, "StarterPackController.Timer", function()
		local currentSecond = os.time()
		if currentSecond == lastTimerSecond then
			return
		end
		lastTimerSecond = currentSecond
		renderAll()
	end)

	renderAll()
end

return StarterPackController
