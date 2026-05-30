local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RebirthBalance = require(Shared:WaitForChild("RebirthBalance"))

local TelemetryService = require(script.Parent:WaitForChild("TelemetryService"))

local ReceiptService = {}

local started = false
local rebirthService = nil

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

local function processReceipt(receiptInfo)
	if rebirthService and RebirthBalance.TierForSkipProductId(receiptInfo.ProductId) then
		return rebirthService.ProcessSkipReceipt(receiptInfo)
	end

	TelemetryService.Warn("receipt_unhandled", {
		playerId = receiptInfo.PlayerId,
		productId = receiptInfo.ProductId,
		purchaseId = tostring(receiptInfo.PurchaseId),
	})
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function ReceiptService.Start(config)
	if started then
		return
	end
	started = true

	config = config or {}
	rebirthService = config.rebirthService
	MarketplaceService.ProcessReceipt = processReceipt
end

return ReceiptService
