local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RebirthBalance = require(Shared:WaitForChild("RebirthBalance"))
local RuntimeGuard = require(Shared:WaitForChild("RuntimeGuard"))

local TelemetryService = require(script.Parent:WaitForChild("TelemetryService"))

local ReceiptService = {}

local started = false
local rebirthService = nil
local gearShopService = nil
local cosmeticShopService = nil
local seedPackShopService = nil
local serverLuckService = nil

function ReceiptService.Key(purchaseId)
	if purchaseId == nil then
		return nil
	end
	return tostring(purchaseId)
end

function ReceiptService.Ensure(profile)
	local receipts = profile.Data.ProcessedReceipts
	if type(receipts) ~= "table" then
		receipts = {}
		profile.Data.ProcessedReceipts = receipts
	end
	return receipts
end

function ReceiptService.HasProcessed(profile, purchaseId)
	local key = ReceiptService.Key(purchaseId)
	if not key then
		return false
	end
	return ReceiptService.Ensure(profile)[key] == true
end

function ReceiptService.MarkProcessed(profile, purchaseId)
	local key = ReceiptService.Key(purchaseId)
	if not key then
		return false
	end
	ReceiptService.Ensure(profile)[key] = true
	return true
end

function ReceiptService.ClearProcessed(profile, purchaseId)
	local key = ReceiptService.Key(purchaseId)
	if not key then
		return
	end
	ReceiptService.Ensure(profile)[key] = nil
end

local function processReceiptTransaction(receiptInfo)
	if rebirthService and RebirthBalance.TierForSkipProductId(receiptInfo.ProductId) then
		return rebirthService.ProcessSkipReceipt(receiptInfo)
	end
	if gearShopService
		and type(gearShopService.HandlesProductId) == "function"
		and type(gearShopService.ProcessReceipt) == "function"
		and gearShopService.HandlesProductId(receiptInfo.ProductId) then
		return gearShopService.ProcessReceipt(receiptInfo)
	end
	if cosmeticShopService
		and type(cosmeticShopService.HandlesProductId) == "function"
		and type(cosmeticShopService.ProcessReceipt) == "function"
		and cosmeticShopService.HandlesProductId(receiptInfo.ProductId) then
		return cosmeticShopService.ProcessReceipt(receiptInfo)
	end
	if seedPackShopService
		and type(seedPackShopService.HandlesProductId) == "function"
		and type(seedPackShopService.ProcessReceipt) == "function"
		and seedPackShopService.HandlesProductId(receiptInfo.ProductId) then
		return seedPackShopService.ProcessReceipt(receiptInfo)
	end
	if serverLuckService
		and type(serverLuckService.HandlesProductId) == "function"
		and type(serverLuckService.ProcessReceipt) == "function"
		and serverLuckService.HandlesProductId(receiptInfo.ProductId) then
		return serverLuckService.ProcessReceipt(receiptInfo)
	end

	TelemetryService.Warn("receipt_unhandled", {
		playerId = receiptInfo.PlayerId,
		productId = receiptInfo.ProductId,
		purchaseId = tostring(receiptInfo.PurchaseId),
	})
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function processReceipt(receiptInfo)
	local ok, decision = RuntimeGuard.Run("ReceiptService.ProcessReceipt", processReceiptTransaction, receiptInfo)
	if ok and decision ~= nil then
		return decision
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function ReceiptService.Start(config)
	if started then
		return
	end
	started = true

	config = config or {}
	rebirthService = config.rebirthService
	gearShopService = config.gearShopService
	cosmeticShopService = config.cosmeticShopService
	seedPackShopService = config.seedPackShopService
	serverLuckService = config.serverLuckService
	MarketplaceService.ProcessReceipt = processReceipt
end

return ReceiptService
