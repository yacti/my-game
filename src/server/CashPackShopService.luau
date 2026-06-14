local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = script.Parent
local CurrencyService = require(Server:WaitForChild("CurrencyService"))
local NotificationService = require(Server:WaitForChild("NotificationService"))
local OfflineProgressService = require(Server:WaitForChild("OfflineProgressService"))
local PetIncomeService = require(Server:WaitForChild("PetIncomeService"))
local PlayerDataService = require(Server:WaitForChild("PlayerDataService"))
local ReceiptService = require(Server:WaitForChild("ReceiptService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormatter = require(Shared:WaitForChild("NumberFormatter"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))
local ShopBalance = require(Shared:WaitForChild("ShopBalance"))

local CashPackShopService = {}

local started = false
local locks = {}

local function userKey(player)
	return player and player.UserId or nil
end

local function balance(profile)
	return math.max(math.floor(tonumber(profile and profile.Data and profile.Data.Currency) or 0), 0)
end

local function saveProfile(profile)
	local ok = pcall(function()
		profile:Save()
	end)
	return ok
end

function CashPackShopService.HandlesProductId(productId)
	return ShopBalance.CashPackForProductId(productId) ~= nil
end

function CashPackShopService.ProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and PlayerDataService.GetProfile(player)
	local pack = ShopBalance.CashPackForProductId(receiptInfo.ProductId)
	local purchaseId = ReceiptService.Key(receiptInfo.PurchaseId)
	if not (player and profile and pack and purchaseId) then
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
	local previousCurrency = balance(profile)
	local payout = 0

	local ok, err = pcall(function()
		local hourlyIncome = PetIncomeService.Refresh(player)
		payout = ShopBalance.CashPackPayout(pack, hourlyIncome)
		if payout <= 0 then
			resultCode = "income-unavailable"
			return
		end

		local _, addCode = CurrencyService.Add(player, profile, payout, true)
		if addCode == "busy" then
			resultCode = "currency-busy"
			return
		end

		ReceiptService.MarkProcessed(profile, purchaseId)
		if not saveProfile(profile) then
			ReceiptService.ClearProcessed(profile, purchaseId)
			CurrencyService.SetBalanceForServer(player, profile, previousCurrency, true)
			resultCode = "save-failed"
			return
		end

		granted = true
		resultCode = "ok"
	end)
	locks[key] = nil

	if not ok then
		warn("[CashPackShopService] Receipt grant failed: " .. tostring(err))
		ReceiptService.ClearProcessed(profile, purchaseId)
		CurrencyService.SetBalanceForServer(player, profile, previousCurrency, true)
		resultCode = "server-error"
	end

	CurrencyService.Publish(player, profile)
	if granted then
		NotificationService.Success(player, string.format(
			"Purchased %s: +%s!",
			pack.DisplayName or "Cash Pack",
			NumberFormatter.Currency(payout)
		))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	NotificationService.Error(player, "Could not grant your cash pack yet.")
	warn("[CashPackShopService] Receipt grant failed: " .. tostring(resultCode))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function CashPackShopService.Start()
	if started then
		return
	end
	started = true

	RuntimeGuard.Connect(Players.PlayerRemoving, "CashPackShopService.PlayerRemoving", function(player)
		local key = userKey(player)
		if key then
			locks[key] = nil
		end
	end)
end

return CashPackShopService
