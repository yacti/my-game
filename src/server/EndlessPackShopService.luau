-- Endless Pack: an infinite sequential claim track in the RobuxShop (see
-- ShopBalance.EndlessPack). Free items (seed packs, direct seeds, grow skips,
-- free money packs) are claimed one at a time through EndlessPackClaimRequest;
-- every 3rd item is a Robux gate whose dev-product receipt (routed by
-- ReceiptService) advances the track. A receipt that does not match the next
-- claimable item (duplicate purchase, or a straggler receipt on the recycled
-- shop-era Durian roll products) still pays out its money value without
-- advancing, so purchases are never left unprocessable and the track can never
-- skip. Progress lives in profile.Data.EndlessPackProgress and never resets.
--
-- The track is deliberately NOT gated by tutorial/offline-catch-up state or
-- by the SeedPacksAllowed paid-random-items policy flag: every Robux product
-- here is a deterministic money pack (randomness only exists in FREE seed
-- pack claims), so PolicyService.ArePaidRandomItemsRestricted does not apply.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local DiscoveryService = require(Server:WaitForChild("DiscoveryService"))
local GrowSkipService = require(Server:WaitForChild("GrowSkipService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PetIncomeService = require(Server:WaitForChild("PetIncomeService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local PlayerReplicaService = require(Server:WaitForChild("PlayerReplicaService"))
local PlotService = require(Server:WaitForChild("PlotService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))
local SeedTools = require(Server:WaitForChild("SeedTools"))
local ToolGrantService = require(Server:WaitForChild("ToolGrantService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local Seeds = require(Shared:WaitForChild("Seeds"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))
local State = require(Shared:WaitForChild("State"))

local EndlessPackShopService = {}

local REQUEST_RATE_SECONDS = 0.5

local started = false
local locks = {}
local lastRequest = {}
local rng = Random.new()
local snapshotProfileState = nil

local claimRequestRemote = Remotes.get(Remotes.Names.EndlessPackClaimRequest)
local claimResultRemote = Remotes.get(Remotes.Names.EndlessPackClaimResult)

local Kinds = ShopBalance.EndlessPackKinds

local function userKey(player)
	return player and player.UserId or nil
end

local function int(value)
	value = tonumber(value)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return math.max(math.floor(value), 0)
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

local function isGameplayBlocked(player)
	return OfflineProgressService.IsPending(player)
		or (player and player:GetAttribute(State.Player.InventoryRestorePending) == true)
end

local function progressOf(profile)
	return int(profile and profile.Data and profile.Data.EndlessPackProgress)
end

local function isMoneyKind(kind)
	return kind == Kinds.Money1 or kind == Kinds.Money2
end

local function seedPackForPackId(packId)
	for _, pack in ipairs(ShopBalance.AllSeedPacks()) do
		if pack.PackId == packId then
			return pack
		end
	end
	return nil
end

local function destroyPrepared(prepared)
	if type(prepared) ~= "table" then
		return
	end
	for _, tool in ipairs(prepared.tools or {}) do
		if tool then
			tool:Destroy()
		end
	end
end

local function rollbackPrepared(profile, prepared)
	if type(prepared) ~= "table" then
		return
	end
	local inventory = profile and profile.Data and profile.Data.SeedInventory
	if type(inventory) == "table" then
		for seedId, amount in pairs(prepared.counts or {}) do
			inventory[seedId] = math.max(int(inventory[seedId]) - int(amount), 0)
			if inventory[seedId] <= 0 then
				inventory[seedId] = nil
			end
		end
	end
	destroyPrepared(prepared)
end

local function prepareSeeds(seedIds)
	local prepared = {
		tools = {},
		counts = {},
	}
	for _, seedId in ipairs(seedIds) do
		local seedGrant, code = SeedTools.PrepareGrant(seedId, 1)
		if not seedGrant then
			destroyPrepared(prepared)
			return nil, code or "grant-failed"
		end
		for _, tool in ipairs(seedGrant.tools or {}) do
			prepared.tools[#prepared.tools + 1] = tool
		end
		prepared.counts[seedId] = (prepared.counts[seedId] or 0) + 1
	end
	return prepared, "ok"
end

local function grantPrepared(player, profile, prepared)
	if not player:FindFirstChildOfClass("Backpack") then
		destroyPrepared(prepared)
		return false, "no-backpack"
	end

	local granted, code = ToolGrantService.GrantTools(player, prepared.tools, {
		autoEquip = false,
		ignoreInventoryCap = true,
	})
	if not granted then
		destroyPrepared(prepared)
		return false, code or "grant-failed"
	end

	profile.Data.SeedInventory = profile.Data.SeedInventory or {}
	for seedId, amount in pairs(prepared.counts) do
		profile.Data.SeedInventory[seedId] = int(profile.Data.SeedInventory[seedId]) + int(amount)
		DiscoveryService.MarkSeed(player, profile, seedId)
	end
	return true, "ok"
end

local function revealPayload(packId, rewards)
	local results = {}
	for _, reward in ipairs(rewards) do
		results[#results + 1] = {
			seedId = reward.SeedId,
			displayName = Seeds.DisplayNameFor(reward.SeedId),
			rarity = Seeds.RarityFor(reward.SeedId),
			chanceText = reward.ChanceText,
		}
	end
	return {
		action = "reveal",
		packId = packId,
		sourceSection = "EndlessPack",
		results = results,
	}
end

local function fireClaimResult(player, requestId, success, code, payload)
	payload = payload or {}
	payload.requestId = requestId
	payload.success = success == true
	payload.code = code
	claimResultRemote:FireClient(player, payload)
end

-- Grants the free item at the next claimable position. Returns
-- granted, resultCode, reveal, prepared; the caller owns rollback on error.
local function grantFreeItem(player, profile, item)
	if isMoneyKind(item.Kind) then
		local hourlyIncome = PetIncomeService.Refresh(player)
		local payout = ShopBalance.EndlessPackMoneyPayout(item.Kind, hourlyIncome)
		if payout <= 0 then
			return false, "income-unavailable", nil, nil
		end
		local _, addCode = CurrencyService.Add(player, profile, payout, true)
		if addCode == "busy" then
			return false, "currency-busy", nil, nil
		end
		NotificationService.Success(player, "Endless Pack: +" .. NumberFormatter.Currency(payout) .. "!")
		return true, "ok", nil, nil
	end

	if item.Kind == Kinds.SeedPack or item.Kind == Kinds.EpicSeedPack then
		local pack = seedPackForPackId(item.PackId)
		local reward = pack and ShopBalance.RollSeedPackReward(pack, rng)
		if not reward then
			return false, "roll-failed", nil, nil
		end
		if not Seeds.GetTemplate(reward.SeedId) then
			return false, "no-template", nil, nil
		end
		local prepared, prepareCode = prepareSeeds({ reward.SeedId })
		if not prepared then
			return false, prepareCode, nil, nil
		end
		local granted, grantCode = grantPrepared(player, profile, prepared)
		if not granted then
			return false, grantCode, nil, nil
		end
		return true, "ok", revealPayload(item.PackId, { reward }), prepared
	end

	if item.Kind == Kinds.SeedGrant then
		if not (item.SeedId and Seeds.GetTemplate(item.SeedId)) then
			return false, "no-template", nil, nil
		end
		local prepared, prepareCode = prepareSeeds({ item.SeedId })
		if not prepared then
			return false, prepareCode, nil, nil
		end
		local granted, grantCode = grantPrepared(player, profile, prepared)
		if not granted then
			return false, grantCode, nil, nil
		end
		NotificationService.Success(player, "Endless Pack: +1 " .. Seeds.DisplayNameFor(item.SeedId) .. "!")
		return true, "ok", nil, prepared
	end

	if item.Kind == Kinds.GrowSkip then
		-- Best-effort: the skip applies to whatever is currently growing;
		-- nothing growing (or edit mode) still counts as claimed.
		local plot = PlotService.GetPlayerPlot(player)
		local result, skipCode = nil, "no-plot"
		if plot then
			result, skipCode = GrowSkipService.ApplyFreePlotTimeSkip(player, plot, item.SkipSeconds)
		end
		if result then
			NotificationService.Success(player, "Endless Pack: skipped "
				.. math.floor(int(item.SkipSeconds) / 60) .. "m of growing time!")
			if type(snapshotProfileState) == "function" then
				pcall(snapshotProfileState, player, plot, profile)
			end
		else
			NotificationService.Info(player, "Endless Pack: growth skip claimed (nothing was growing)")
			if skipCode ~= "no-growth" and skipCode ~= "edit-mode" and skipCode ~= "no-plot" then
				warn("[EndlessPackShopService] Grow skip no-op: " .. tostring(skipCode))
			end
		end
		return true, "ok", nil, nil
	end

	return false, "invalid-kind", nil, nil
end

local function handleClaimRequest(player, requestId, expectedPosition)
	requestId = tonumber(requestId)
	if type(requestId) ~= "number" or requestId ~= requestId or math.abs(requestId) == math.huge then
		return
	end

	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		fireClaimResult(player, requestId, false, "no-profile")
		return
	end
	if isGameplayBlocked(player) then
		fireClaimResult(player, requestId, false, "busy", { progress = progressOf(profile) })
		return
	end

	local key = userKey(player)
	if not key or locks[key] then
		fireClaimResult(player, requestId, false, "busy", { progress = progressOf(profile) })
		return
	end
	local now = os.clock()
	if lastRequest[key] and now - lastRequest[key] < REQUEST_RATE_SECONDS then
		fireClaimResult(player, requestId, false, "rate-limited", { progress = progressOf(profile) })
		return
	end
	lastRequest[key] = now

	local progress = progressOf(profile)
	local nextPosition = progress + 1
	expectedPosition = tonumber(expectedPosition)
	if expectedPosition ~= nil and expectedPosition ~= nextPosition then
		fireClaimResult(player, requestId, false, "stale", { progress = progress })
		return
	end

	local item = ShopBalance.EndlessPackItemForPosition(nextPosition)
	if not item then
		fireClaimResult(player, requestId, false, "invalid-position", { progress = progress })
		return
	end
	if item.Paid then
		-- Robux gate: no mutation here; the receipt advances the track.
		fireClaimResult(player, requestId, true, "purchase-required", {
			progress = progress,
			position = nextPosition,
			productId = item.ProductId,
		})
		return
	end

	locks[key] = true
	local granted = false
	local resultCode = "server-error"
	local reveal = nil
	local prepared = nil

	local ok, err = pcall(function()
		granted, resultCode, reveal, prepared = grantFreeItem(player, profile, item)
		if granted then
			profile.Data.EndlessPackProgress = nextPosition
		end
	end)
	locks[key] = nil

	if not ok then
		warn("[EndlessPackShopService] Claim grant failed: " .. tostring(err))
		if granted then
			profile.Data.EndlessPackProgress = progress
			rollbackPrepared(profile, prepared)
		else
			destroyPrepared(prepared)
		end
		PlayerReplicaService.PublishInventories(player, profile)
		PlayerReplicaService.PublishEndlessPack(player, profile)
		fireClaimResult(player, requestId, false, "server-error", { progress = progressOf(profile) })
		return
	end

	if isMoneyKind(item.Kind) then
		CurrencyService.Publish(player, profile)
	end
	PlayerReplicaService.PublishInventories(player, profile)
	PlayerReplicaService.PublishEndlessPack(player, profile)

	if granted then
		fireClaimResult(player, requestId, true, "ok", {
			progress = progressOf(profile),
			reveal = reveal,
		})
		return
	end

	if resultCode == "no-backpack" then
		NotificationService.Error(player, "Could not claim from the Endless Pack yet. Please rejoin and try again")
	elseif resultCode ~= "inventory-full" then
		-- ToolGrantService emits the rate-limited inventory full notification.
		NotificationService.Error(player, "Could not claim from the Endless Pack yet")
	end
	fireClaimResult(player, requestId, false, resultCode, { progress = progressOf(profile) })
	warn("[EndlessPackShopService] Claim grant failed: " .. tostring(resultCode))
end

function EndlessPackShopService.HandlesProductId(productId)
	return ShopBalance.EndlessPackPaidItemForProductId(productId) ~= nil
end

function EndlessPackShopService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local product = ShopBalance.EndlessPackPaidItemForProductId(receiptInfo.ProductId)
	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not (player and profile and product and purchaseId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if ReceiptService.HasProcessed(profile, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if OfflineProgressService.IsPending(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local key = userKey(player)
	if not key or locks[key] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	locks[key] = true
	local granted = false
	local resultCode = "server-error"
	local previousProgress = progressOf(profile)
	local previousCurrency = int(profile.Data.Currency)
	local payout = 0
	local advanced = false

	local ok, err = pcall(function()
		-- Only an exact product match on the next claimable (paid) item
		-- advances the track; anything else (duplicate purchase, legacy
		-- shop-era Durian receipt) still pays out its own money value.
		local nextItem = ShopBalance.EndlessPackItemForPosition(previousProgress + 1)
		advanced = nextItem ~= nil
			and nextItem.Paid == true
			and int(nextItem.ProductId) == int(receiptInfo.ProductId)
		local kind = advanced and nextItem.Kind or product.Kind

		local hourlyIncome = PetIncomeService.Refresh(player)
		payout = ShopBalance.EndlessPackMoneyPayout(kind, hourlyIncome)
		if payout <= 0 then
			resultCode = "income-unavailable"
			return
		end

		local _, addCode = CurrencyService.Add(player, profile, payout, true)
		if addCode == "busy" then
			resultCode = "currency-busy"
			return
		end

		if advanced then
			profile.Data.EndlessPackProgress = previousProgress + 1
		end

		ReceiptService.MarkProcessed(profile, purchaseId)
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			CurrencyService.SetBalanceForServer(player, profile, previousCurrency, true)
			profile.Data.EndlessPackProgress = previousProgress
			resultCode = "save-failed"
			return
		end

		granted = true
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		warn("[EndlessPackShopService] Receipt grant failed: " .. tostring(err))
		ReceiptService.ClearProcessed(profile, purchaseId)
		CurrencyService.SetBalanceForServer(player, profile, previousCurrency, true)
		profile.Data.EndlessPackProgress = previousProgress
		granted = false
		resultCode = "server-error"
	end

	CurrencyService.Publish(player, profile)
	PlayerReplicaService.PublishEndlessPack(player, profile)

	if granted then
		NotificationService.Success(player, string.format(
			"Endless Pack%s: +%s!",
			advanced and "" or " purchase",
			NumberFormatter.Currency(payout)
		))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	NotificationService.Error(player, "Could not grant your Endless Pack purchase yet")
	warn("[EndlessPackShopService] Receipt grant failed: " .. tostring(resultCode))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function EndlessPackShopService.Start(config)
	if started then
		return
	end
	started = true
	config = type(config) == "table" and config or nil
	snapshotProfileState = config and config.snapshotProfileState or nil

	RuntimeGuard.Connect(claimRequestRemote.OnServerEvent, "EndlessPackShopService.ClaimRequest", handleClaimRequest)
	RuntimeGuard.Connect(Players.PlayerRemoving, "EndlessPackShopService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
			lastRequest[key] = nil
		end
	end)
end

return EndlessPackShopService
